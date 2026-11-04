-- Warehouse-native translation of backend/scripts/59_backfill_semantic_metadata_model_source_targets.py
-- (SQL migration). Chains off dbo.silver_semantic_model_view_candidates
-- (58's output -- the real pipeline runs 58 then 59 then 60 then 61 in
-- sequence, each backfilling on top of the previous one's result) plus
-- dbo.bronze_semantic_model_datamart_dependencies and
-- dbo.bronze_source_object_type_metadata_evidence.
--
-- Simplification verified against the Python source: build_model_targets()
-- indexes every confirmed dependency under the SQL/Fabric/FabricOrSQL
-- aliases unconditionally (all three always pass its own RELATIONAL_
-- SOURCE_TYPES check regardless of the row's real source_type), so the
-- 3-way alias loop in matching_model_metadata_targets() is source-type-
-- agnostic in practice -- it only ever really tests "does this (server,
-- database) exist as ANY confirmed dependency of this model". Reproduced
-- here as a plain existence check instead of replicating the redundant
-- triple loop. Likewise build_metadata_by_object()'s `metadata_server(row)
-- or metadata_databases(row)` guard is always true in Python (a non-empty
-- list, even [""], is truthy) -- not a real filter, so it's dropped here too.
CREATE OR ALTER PROCEDURE dbo.sp_backfill_semantic_metadata_model_source_targets
AS
BEGIN

IF OBJECT_ID('dbo.silver_semantic_model_view_candidates_v59', 'U') IS NOT NULL DROP TABLE dbo.silver_semantic_model_view_candidates_v59;
IF OBJECT_ID('dbo.silver_d4_semantic_metadata_model_target_backfill', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_semantic_metadata_model_target_backfill;
IF OBJECT_ID('dbo.silver_d4_semantic_metadata_model_target_backfill_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_semantic_metadata_model_target_backfill_summary;

;WITH base AS (
    SELECT *,
        CASE WHEN evidence LIKE '%semantic_metadata_model_source_target_backfill%' THEN 1 ELSE 0 END AS already_backfilled,
        CASE WHEN source_server = '' AND database_name = '' AND object_name <> '' THEN 1 ELSE 0 END AS missing_target
    FROM dbo.silver_semantic_model_view_candidates
),
model_targets AS (
    -- model_name lowered too: joins against it must be case-insensitive
    -- like every other key here, matching PowerShell's hashtable default
    -- (Fabric Warehouse's own default collation is case-sensitive binary --
    -- see 05_build_graph.sql's header comment for the real case this
    -- caused).
    SELECT DISTINCT LOWER(LTRIM(RTRIM(semantic_model_qualified_name))) AS model_name,
        LOWER(LTRIM(RTRIM(source_server))) AS norm_server,
        LOWER(LTRIM(RTRIM(datamart_name))) AS norm_database
    FROM dbo.bronze_semantic_model_datamart_dependencies
    WHERE LOWER(LTRIM(RTRIM(confidence))) = 'confirmed' AND (source_server <> '' OR datamart_name <> '')
),
model_targets_detail AS (
    SELECT semantic_model_qualified_name AS model_name,
        LOWER(LTRIM(RTRIM(source_server))) AS norm_server,
        LOWER(LTRIM(RTRIM(datamart_name))) AS norm_database,
        source_type,
        ROW_NUMBER() OVER (PARTITION BY semantic_model_qualified_name, LOWER(LTRIM(RTRIM(source_server))), LOWER(LTRIM(RTRIM(datamart_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_semantic_model_datamart_dependencies
    WHERE LOWER(LTRIM(RTRIM(confidence))) = 'confirmed' AND (source_server <> '' OR datamart_name <> '')
),
metadata_filtered AS (
    SELECT *,
        CASE WHEN object_name <> '' THEN object_name ELSE metadata_object_name END AS eff_object,
        CASE WHEN schema_name <> '' THEN schema_name ELSE metadata_schema_name END AS eff_schema,
        LTRIM(RTRIM(CASE WHEN metadata_server <> '' THEN metadata_server ELSE source_server END)) AS eff_server,
        CASE WHEN metadata_database <> '' THEN metadata_database ELSE source_database END AS eff_database_raw
    FROM dbo.bronze_source_object_type_metadata_evidence
    WHERE (LOWER(LTRIM(RTRIM(confidence))) = 'confirmed' OR confidence = '')
),
metadata_valid AS (
    SELECT * FROM metadata_filtered WHERE eff_object <> ''
),
metadata_expanded AS (
    SELECT m.*, LTRIM(RTRIM(s.value)) AS db_value
    FROM metadata_valid m
    CROSS APPLY STRING_SPLIT(m.eff_database_raw, ';') s
),
-- Every candidate x every supporting metadata match, filtered down to
-- ones whose (server, database) is a confirmed dependency of the SAME
-- candidate's model.
candidate_matches AS (
    SELECT
        b.workspace_name, b.workspace_environment, b.semantic_model_name, b.semantic_model_qualified_name,
        b.semantic_table, b.schema_name, b.object_name, b.object_type, b.definition_path, b.confidence AS candidate_confidence,
        b.evidence, b.already_backfilled, b.missing_target,
        LOWER(LTRIM(RTRIM(b.schema_name))) AS b_schema, LOWER(LTRIM(RTRIM(b.object_name))) AS b_object,
        me.eff_server, me.db_value, me.object_type AS metadata_object_type, me.resolver AS metadata_resolver,
        me.metadata_type_code, me.metadata_type_desc
    FROM base b
    JOIN metadata_expanded me
        ON LOWER(LTRIM(RTRIM(me.eff_schema))) = LOWER(LTRIM(RTRIM(b.schema_name)))
       AND LOWER(LTRIM(RTRIM(me.eff_object))) = LOWER(LTRIM(RTRIM(b.object_name)))
    WHERE b.already_backfilled = 0 AND b.missing_target = 1 AND b.schema_name <> ''
),
supported_matches AS (
    SELECT cm.*
    FROM candidate_matches cm
    JOIN model_targets mt
        ON mt.model_name = LOWER(LTRIM(RTRIM(cm.semantic_model_qualified_name)))
       AND mt.norm_server = LOWER(LTRIM(RTRIM(cm.eff_server)))
       AND mt.norm_database = LOWER(LTRIM(RTRIM(cm.db_value)))
),
target_counts AS (
    SELECT semantic_model_qualified_name, schema_name, object_name,
        COUNT(DISTINCT LOWER(eff_server) + '|' + LOWER(db_value)) AS distinct_targets
    FROM supported_matches
    GROUP BY semantic_model_qualified_name, schema_name, object_name
),
supported_ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY semantic_model_qualified_name, schema_name, object_name ORDER BY (SELECT NULL)) AS rn
    FROM supported_matches
),
resolved AS (
    SELECT
        b.*,
        ISNULL(tc.distinct_targets, 0) AS distinct_targets,
        sr.eff_server AS resolved_server,
        sr.db_value AS resolved_database,
        sr.metadata_object_type AS resolved_metadata_object_type,
        sr.metadata_resolver AS resolved_metadata_resolver,
        sr.metadata_type_code AS resolved_metadata_type_code,
        sr.metadata_type_desc AS resolved_metadata_type_desc
    FROM base b
    LEFT JOIN target_counts tc ON tc.semantic_model_qualified_name = b.semantic_model_qualified_name AND tc.schema_name = b.schema_name AND tc.object_name = b.object_name
    LEFT JOIN supported_ranked sr ON sr.semantic_model_qualified_name = b.semantic_model_qualified_name AND sr.schema_name = b.schema_name AND sr.object_name = b.object_name AND sr.rn = 1
),
decided AS (
    SELECT
        *,
        CASE WHEN already_backfilled = 0 AND missing_target = 1 AND schema_name <> '' AND distinct_targets = 1 THEN 1 ELSE 0 END AS will_backfill
    FROM resolved
)
SELECT
    workspace_name, workspace_environment, semantic_model_name, semantic_model_qualified_name,
    semantic_table,
    CASE WHEN will_backfill = 1 THEN resolved_server ELSE source_server END AS source_server,
    CASE WHEN will_backfill = 1 THEN resolved_database ELSE database_name END AS database_name,
    schema_name, object_name, object_type, definition_path, confidence,
    CASE
        WHEN will_backfill = 1 THEN
            CASE WHEN evidence = ''
                THEN 'Source endpoint backfilled by semantic_metadata_model_source_target_backfill because read-only metadata found ' + schema_name + '.' + object_name + ' in ' + resolved_server + '/' + resolved_database + ' and the same semantic model has a confirmed source dependency on that target.'
                ELSE evidence + ' Source endpoint backfilled by semantic_metadata_model_source_target_backfill because read-only metadata found ' + schema_name + '.' + object_name + ' in ' + resolved_server + '/' + resolved_database + ' and the same semantic model has a confirmed source dependency on that target.'
            END
        ELSE evidence
    END AS evidence,
    already_backfilled, will_backfill, resolved_server, resolved_database,
    resolved_metadata_object_type, resolved_metadata_resolver, resolved_metadata_type_code, resolved_metadata_type_desc
INTO #d59_out
FROM decided;

SELECT
    workspace_name, workspace_environment, semantic_model_name, semantic_model_qualified_name,
    semantic_table, source_server, database_name, schema_name, object_name, object_type,
    definition_path, confidence, evidence
INTO dbo.silver_semantic_model_view_candidates_v59
FROM #d59_out;

SELECT
    semantic_model_qualified_name, workspace_name, workspace_environment, semantic_model_name,
    semantic_table, schema_name, object_name, object_type,
    CASE WHEN already_backfilled = 1 THEN source_server ELSE resolved_server END AS backfilled_source_server,
    CASE WHEN already_backfilled = 1 THEN database_name ELSE resolved_database END AS backfilled_database_name,
    CASE WHEN already_backfilled = 1 THEN '' ELSE ISNULL(resolved_metadata_object_type, '') END AS metadata_object_type,
    CASE WHEN already_backfilled = 1 THEN '' ELSE ISNULL(resolved_metadata_resolver, '') END AS metadata_resolver,
    CASE WHEN already_backfilled = 1 THEN '' ELSE ISNULL(resolved_metadata_type_code, '') END AS metadata_type_code,
    CASE WHEN already_backfilled = 1 THEN '' ELSE ISNULL(resolved_metadata_type_desc, '') END AS metadata_type_desc,
    '' AS model_dependency_source_type,
    definition_path,
    CASE WHEN already_backfilled = 1 THEN 'retained_existing_backfill' ELSE 'applied' END AS status,
    evidence
INTO dbo.silver_d4_semantic_metadata_model_target_backfill
FROM #d59_out
WHERE already_backfilled = 1 OR will_backfill = 1;

SELECT scope, value, count, notes INTO dbo.silver_d4_semantic_metadata_model_target_backfill_summary FROM (
    SELECT 'total' AS scope, 'input_rows' AS value, CAST(COUNT(*) AS VARCHAR(20)) AS count, 'analysis/semantic_model_view_candidates.csv' AS notes FROM #d59_out
    UNION ALL
    SELECT 'total', 'changed_rows', CAST(SUM(CASE WHEN will_backfill = 1 THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Rows backfilled in this run.' FROM #d59_out
    UNION ALL
    SELECT 'total', 'backfill_rows_emitted_or_retained', CAST(COUNT(*) AS VARCHAR(20)), 'analysis/d4_semantic_metadata_model_target_backfill.csv' FROM dbo.silver_d4_semantic_metadata_model_target_backfill
    UNION ALL
    SELECT 'status', status, CAST(COUNT(*) AS VARCHAR(20)), 'Backfill row status.' FROM dbo.silver_d4_semantic_metadata_model_target_backfill GROUP BY status
    UNION ALL
    SELECT 'target', backfilled_source_server + '/' + backfilled_database_name, CAST(COUNT(*) AS VARCHAR(20)), 'Backfilled rows by target.' FROM dbo.silver_d4_semantic_metadata_model_target_backfill WHERE backfilled_source_server <> '' OR backfilled_database_name <> '' GROUP BY backfilled_source_server + '/' + backfilled_database_name
    UNION ALL
    SELECT 'workspace', workspace_name, CAST(COUNT(*) AS VARCHAR(20)), 'Backfilled rows by workspace.' FROM dbo.silver_d4_semantic_metadata_model_target_backfill WHERE workspace_name <> '' GROUP BY workspace_name
) x;

DROP TABLE #d59_out;

END
