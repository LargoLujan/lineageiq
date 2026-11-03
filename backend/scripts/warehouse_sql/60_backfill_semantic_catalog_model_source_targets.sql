-- Warehouse-native translation of backend/scripts/60_backfill_semantic_catalog_model_source_targets.py
-- (Phase 1 migration, 2026-07-21). Chains off dbo.silver_semantic_model_view_candidates_v59
-- (59's output) plus dbo.bronze_semantic_model_datamart_dependencies,
-- dbo.bronze_sql_server_deep_catalog_objects, and
-- dbo.bronze_sql_endpoint_object_catalog. Unlike 58/59, this one can also
-- backfill a blank schema_name (not just server/database) when the match
-- uniquely determines it.
CREATE OR ALTER PROCEDURE dbo.sp_backfill_semantic_catalog_model_source_targets
AS
BEGIN

IF OBJECT_ID('dbo.silver_semantic_model_view_candidates_v60', 'U') IS NOT NULL DROP TABLE dbo.silver_semantic_model_view_candidates_v60;
IF OBJECT_ID('dbo.silver_d4_semantic_catalog_model_target_backfill', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_semantic_catalog_model_target_backfill;
IF OBJECT_ID('dbo.silver_d4_semantic_catalog_model_target_backfill_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_semantic_catalog_model_target_backfill_summary;

;WITH base AS (
    SELECT *,
        CASE WHEN evidence LIKE '%semantic_catalog_model_source_target_backfill%' THEN 1 ELSE 0 END AS already_backfilled,
        CASE WHEN source_server = '' AND database_name = '' AND object_name <> '' THEN 1 ELSE 0 END AS missing_target
    FROM dbo.silver_semantic_model_view_candidates_v59
),
model_targets AS (
    -- model_name lowered too -- see 59's identical fix / 05_build_graph.sql's
    -- header comment for why (Fabric Warehouse's default collation is
    -- case-sensitive binary, unlike a PowerShell hashtable key).
    SELECT DISTINCT LOWER(LTRIM(RTRIM(semantic_model_qualified_name))) AS model_name,
        LOWER(LTRIM(RTRIM(source_server))) AS norm_server,
        LOWER(LTRIM(RTRIM(datamart_name))) AS norm_database
    FROM dbo.bronze_semantic_model_datamart_dependencies
    WHERE LOWER(LTRIM(RTRIM(confidence))) = 'confirmed' AND (source_server <> '' OR datamart_name <> '')
),
sql_catalog AS (
    SELECT 'sql_server_deep_catalog_objects' AS c_catalog, source_server AS c_server, database_name AS c_database,
        schema_name AS c_schema, object_name AS c_object, object_type AS c_type, type_code AS c_type_code, type_desc AS c_type_desc
    FROM dbo.bronze_sql_server_deep_catalog_objects
    WHERE object_name <> '' AND database_name <> ''
),
fabric_catalog AS (
    SELECT 'sql_endpoint_object_catalog' AS c_catalog, source_server AS c_server, source_database AS c_database,
        schema_name AS c_schema, object_name AS c_object, object_type AS c_type, metadata_type_code AS c_type_code, metadata_type_desc AS c_type_desc
    FROM dbo.bronze_sql_endpoint_object_catalog
    WHERE object_name <> '' AND (source_server <> '' OR source_database <> '') AND (catalog_status = '' OR catalog_status = 'confirmed')
),
catalog_all AS (
    SELECT * FROM sql_catalog
    UNION ALL
    SELECT * FROM fabric_catalog
),
candidate_matches AS (
    SELECT
        b.*, ca.c_catalog, ca.c_server, ca.c_database, ca.c_schema, ca.c_object, ca.c_type, ca.c_type_code, ca.c_type_desc,
        CASE WHEN b.schema_name <> '' THEN 'strict_with_schema' ELSE 'strict_unique_schema' END AS match_mode,
        LOWER(LTRIM(RTRIM(ca.c_server))) + '|' + LOWER(LTRIM(RTRIM(ca.c_database))) + '|' + LOWER(LTRIM(RTRIM(ca.c_schema))) + '|' + LOWER(LTRIM(RTRIM(ca.c_object))) + '|' + LOWER(LTRIM(RTRIM(ca.c_type))) AS catalog_identity
    FROM base b
    JOIN model_targets mt ON mt.model_name = LOWER(LTRIM(RTRIM(b.semantic_model_qualified_name)))
    JOIN catalog_all ca
        ON LOWER(LTRIM(RTRIM(ca.c_server))) = mt.norm_server
       AND LOWER(LTRIM(RTRIM(ca.c_database))) = mt.norm_database
       AND LOWER(LTRIM(RTRIM(ca.c_object))) = LOWER(LTRIM(RTRIM(b.object_name)))
       AND (b.schema_name = '' OR LOWER(LTRIM(RTRIM(ca.c_schema))) = LOWER(LTRIM(RTRIM(b.schema_name))))
    WHERE b.already_backfilled = 0 AND b.missing_target = 1
),
identity_counts AS (
    SELECT semantic_model_qualified_name, schema_name, object_name, COUNT(DISTINCT catalog_identity) AS distinct_identities
    FROM candidate_matches
    GROUP BY semantic_model_qualified_name, schema_name, object_name
),
match_ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY semantic_model_qualified_name, schema_name, object_name ORDER BY (SELECT NULL)) AS rn
    FROM candidate_matches
),
resolved AS (
    SELECT
        b.*,
        ISNULL(ic.distinct_identities, 0) AS distinct_identities,
        mr.c_catalog AS m_catalog, mr.c_server AS m_server, mr.c_database AS m_database, mr.c_schema AS m_schema,
        mr.c_type AS m_type, mr.c_type_code AS m_type_code, mr.c_type_desc AS m_type_desc, mr.match_mode AS m_match_mode
    FROM base b
    LEFT JOIN identity_counts ic ON ic.semantic_model_qualified_name = b.semantic_model_qualified_name AND ic.schema_name = b.schema_name AND ic.object_name = b.object_name
    LEFT JOIN match_ranked mr ON mr.semantic_model_qualified_name = b.semantic_model_qualified_name AND mr.schema_name = b.schema_name AND mr.object_name = b.object_name AND mr.rn = 1
),
decided AS (
    SELECT *,
        CASE WHEN already_backfilled = 0 AND missing_target = 1 AND distinct_identities = 1 THEN 1 ELSE 0 END AS will_backfill
    FROM resolved
)
SELECT
    workspace_name, workspace_environment, semantic_model_name, semantic_model_qualified_name, semantic_table,
    CASE WHEN will_backfill = 1 THEN m_server ELSE source_server END AS source_server,
    CASE WHEN will_backfill = 1 THEN m_database ELSE database_name END AS database_name,
    CASE WHEN will_backfill = 1 AND schema_name = '' AND ISNULL(m_schema, '') <> '' THEN m_schema ELSE schema_name END AS schema_name,
    schema_name AS schema_name_before,
    object_name, object_type, definition_path, confidence,
    CASE
        WHEN will_backfill = 1 THEN
            CASE WHEN evidence = ''
                THEN 'Source endpoint backfilled by semantic_catalog_model_source_target_backfill using ' + ISNULL(m_catalog,'') + ' because ' + ISNULL(m_schema,'') + '.' + object_name + ' exists in ' + ISNULL(m_server,'') + '/' + ISNULL(m_database,'') + ' and that target is a confirmed source dependency of the same semantic model.'
                ELSE evidence + ' Source endpoint backfilled by semantic_catalog_model_source_target_backfill using ' + ISNULL(m_catalog,'') + ' because ' + ISNULL(m_schema,'') + '.' + object_name + ' exists in ' + ISNULL(m_server,'') + '/' + ISNULL(m_database,'') + ' and that target is a confirmed source dependency of the same semantic model.'
            END
        ELSE evidence
    END AS evidence,
    already_backfilled, will_backfill, m_catalog, m_server, m_database, m_schema, m_type, m_type_code, m_type_desc, m_match_mode
INTO #d60_out
FROM decided;

SELECT
    workspace_name, workspace_environment, semantic_model_name, semantic_model_qualified_name,
    semantic_table, source_server, database_name, schema_name, object_name, object_type,
    definition_path, confidence, evidence
INTO dbo.silver_semantic_model_view_candidates_v60
FROM #d60_out;

SELECT
    semantic_model_qualified_name, workspace_name, workspace_environment, semantic_model_name, semantic_table,
    schema_name_before,
    object_name, object_type,
    CASE WHEN already_backfilled = 1 THEN source_server ELSE ISNULL(m_server,'') END AS backfilled_source_server,
    CASE WHEN already_backfilled = 1 THEN database_name ELSE ISNULL(m_database,'') END AS backfilled_database_name,
    CASE WHEN already_backfilled = 1 THEN schema_name ELSE ISNULL(m_schema,'') END AS backfilled_schema_name,
    CASE WHEN already_backfilled = 1 THEN '' ELSE ISNULL(m_type,'') END AS catalog_object_type,
    CASE WHEN already_backfilled = 1 THEN '' ELSE ISNULL(m_catalog,'') END AS catalog_source,
    CASE WHEN already_backfilled = 1 THEN '' ELSE ISNULL(m_type_code,'') END AS catalog_type_code,
    CASE WHEN already_backfilled = 1 THEN '' ELSE ISNULL(m_type_desc,'') END AS catalog_type_desc,
    CASE WHEN already_backfilled = 1 THEN 'retained' ELSE ISNULL(m_match_mode,'') END AS match_mode,
    definition_path,
    CASE WHEN already_backfilled = 1 THEN 'retained_existing_backfill' ELSE 'applied' END AS status,
    evidence
INTO dbo.silver_d4_semantic_catalog_model_target_backfill
FROM #d60_out
WHERE already_backfilled = 1 OR will_backfill = 1;

SELECT scope, value, count, notes INTO dbo.silver_d4_semantic_catalog_model_target_backfill_summary FROM (
    SELECT 'total' AS scope, 'input_rows' AS value, CAST(COUNT(*) AS VARCHAR(20)) AS count, 'analysis/semantic_model_view_candidates.csv' AS notes FROM #d60_out
    UNION ALL
    SELECT 'total', 'changed_rows', CAST(SUM(CASE WHEN will_backfill = 1 THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Rows backfilled in this run.' FROM #d60_out
    UNION ALL
    SELECT 'total', 'backfill_rows_emitted_or_retained', CAST(COUNT(*) AS VARCHAR(20)), 'analysis/d4_semantic_catalog_model_target_backfill.csv' FROM dbo.silver_d4_semantic_catalog_model_target_backfill
    UNION ALL
    SELECT 'status', status, CAST(COUNT(*) AS VARCHAR(20)), 'Backfill row status.' FROM dbo.silver_d4_semantic_catalog_model_target_backfill GROUP BY status
    UNION ALL
    SELECT 'match_mode', match_mode, CAST(COUNT(*) AS VARCHAR(20)), 'Strict match mode.' FROM dbo.silver_d4_semantic_catalog_model_target_backfill WHERE match_mode <> '' GROUP BY match_mode
    UNION ALL
    SELECT 'target', backfilled_source_server + '/' + backfilled_database_name, CAST(COUNT(*) AS VARCHAR(20)), 'Backfilled rows by target.' FROM dbo.silver_d4_semantic_catalog_model_target_backfill WHERE backfilled_source_server <> '' OR backfilled_database_name <> '' GROUP BY backfilled_source_server + '/' + backfilled_database_name
    UNION ALL
    SELECT 'workspace', workspace_name, CAST(COUNT(*) AS VARCHAR(20)), 'Backfilled rows by workspace.' FROM dbo.silver_d4_semantic_catalog_model_target_backfill WHERE workspace_name <> '' GROUP BY workspace_name
) x;

DROP TABLE #d60_out;

END
