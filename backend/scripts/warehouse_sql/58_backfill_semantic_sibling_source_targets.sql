-- Warehouse-native translation of backend/scripts/58_backfill_semantic_sibling_source_targets.py
-- (Phase 1 migration, 2026-07-21). Unlike D1-D7 (read bronze, write new
-- silver tables), this one is a genuine self-referential UPDATE pattern:
-- the Python original reads AND overwrites analysis/semantic_model_view_
-- candidates.csv in place. Rather than mutate the bronze mirror of that
-- file (bronze is meant to stay a raw, untouched copy -- the NEXT scan's
-- upload would just overwrite any in-place edit anyway), this produces a
-- separate dbo.silver_semantic_model_view_candidates table: the backfilled
-- version, which is what any later step should read once CSVs are
-- eventually retired.
CREATE OR ALTER PROCEDURE dbo.sp_backfill_semantic_sibling_source_targets
AS
BEGIN

IF OBJECT_ID('dbo.silver_semantic_model_view_candidates', 'U') IS NOT NULL DROP TABLE dbo.silver_semantic_model_view_candidates;
IF OBJECT_ID('dbo.silver_d4_semantic_sibling_target_backfill', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_semantic_sibling_target_backfill;
IF OBJECT_ID('dbo.silver_d4_semantic_sibling_target_backfill_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_semantic_sibling_target_backfill_summary;

;WITH base AS (
    SELECT *,
        LOWER(LTRIM(RTRIM(semantic_model_name))) + '|' + LOWER(LTRIM(RTRIM(semantic_table))) + '|' +
        LOWER(LTRIM(RTRIM(schema_name))) + '|' + LOWER(LTRIM(RTRIM(object_name))) + '|' + LOWER(LTRIM(RTRIM(object_type))) AS candidate_key,
        CASE WHEN evidence LIKE '%semantic_sibling_source_target_backfill%' THEN 1 ELSE 0 END AS already_backfilled,
        CASE WHEN source_server = '' AND database_name = '' AND object_name <> '' THEN 1 ELSE 0 END AS missing_target
    FROM dbo.bronze_semantic_model_view_candidates
),
sibling_targets AS (
    SELECT candidate_key, source_server, database_name, semantic_model_qualified_name, workspace_name, workspace_environment
    FROM base
    WHERE source_server <> '' AND database_name <> '' AND object_name <> ''
),
target_counts AS (
    SELECT candidate_key, COUNT(DISTINCT LOWER(source_server) + '|' + LOWER(database_name)) AS distinct_targets
    FROM sibling_targets GROUP BY candidate_key
),
sibling_ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY candidate_key ORDER BY (SELECT NULL)) AS rn FROM sibling_targets
),
decided AS (
    SELECT
        b.*,
        CASE WHEN b.already_backfilled = 0 AND b.missing_target = 1 AND ISNULL(tc.distinct_targets, 0) = 1 THEN 1 ELSE 0 END AS will_backfill,
        sr.source_server AS sibling_source_server,
        sr.database_name AS sibling_database_name,
        sr.semantic_model_qualified_name AS sibling_semantic_model_qualified_name,
        sr.workspace_name AS sibling_workspace_name,
        sr.workspace_environment AS sibling_workspace_environment
    FROM base b
    LEFT JOIN target_counts tc ON tc.candidate_key = b.candidate_key
    LEFT JOIN sibling_ranked sr ON sr.candidate_key = b.candidate_key AND sr.rn = 1
)
SELECT
    workspace_name, workspace_environment, semantic_model_name, semantic_model_qualified_name,
    semantic_table,
    CASE WHEN will_backfill = 1 THEN sibling_source_server ELSE source_server END AS source_server,
    CASE WHEN will_backfill = 1 THEN sibling_database_name ELSE database_name END AS database_name,
    schema_name, object_name, object_type, definition_path, confidence,
    CASE
        WHEN will_backfill = 1 THEN
            CASE WHEN evidence = ''
                THEN 'Source endpoint backfilled by semantic_sibling_source_target_backfill from sibling semantic model ''' + sibling_semantic_model_qualified_name + ''' with the same semantic model name, semantic table, schema, object name, and raw object type.'
                ELSE evidence + ' Source endpoint backfilled by semantic_sibling_source_target_backfill from sibling semantic model ''' + sibling_semantic_model_qualified_name + ''' with the same semantic model name, semantic table, schema, object name, and raw object type.'
            END
        ELSE evidence
    END AS evidence,
    already_backfilled, will_backfill, sibling_semantic_model_qualified_name,
    sibling_workspace_name, sibling_workspace_environment, sibling_source_server, sibling_database_name
INTO #decided_out
FROM decided;

SELECT
    workspace_name, workspace_environment, semantic_model_name, semantic_model_qualified_name,
    semantic_table, source_server, database_name, schema_name, object_name, object_type,
    definition_path, confidence, evidence
INTO dbo.silver_semantic_model_view_candidates
FROM #decided_out;

SELECT
    semantic_model_qualified_name, workspace_name, workspace_environment, semantic_model_name,
    semantic_table, schema_name, object_name, object_type,
    CASE WHEN already_backfilled = 1 THEN source_server ELSE sibling_source_server END AS backfilled_source_server,
    CASE WHEN already_backfilled = 1 THEN database_name ELSE sibling_database_name END AS backfilled_database_name,
    CASE WHEN already_backfilled = 1 THEN '' ELSE sibling_semantic_model_qualified_name END AS sibling_semantic_model_qualified_name,
    CASE WHEN already_backfilled = 1 THEN '' ELSE sibling_workspace_name END AS sibling_workspace_name,
    CASE WHEN already_backfilled = 1 THEN '' ELSE sibling_workspace_environment END AS sibling_workspace_environment,
    definition_path,
    CASE WHEN already_backfilled = 1 THEN 'retained_existing_backfill' ELSE 'applied' END AS status,
    evidence
INTO dbo.silver_d4_semantic_sibling_target_backfill
FROM #decided_out
WHERE already_backfilled = 1 OR will_backfill = 1;

SELECT scope, value, count, notes INTO dbo.silver_d4_semantic_sibling_target_backfill_summary FROM (
    SELECT 'total' AS scope, 'input_rows' AS value, CAST(COUNT(*) AS VARCHAR(20)) AS count, 'analysis/semantic_model_view_candidates.csv' AS notes FROM #decided_out
    UNION ALL
    SELECT 'total', 'changed_rows', CAST(SUM(CASE WHEN will_backfill = 1 THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Rows backfilled in this run.' FROM #decided_out
    UNION ALL
    SELECT 'total', 'backfill_rows_emitted_or_retained', CAST(COUNT(*) AS VARCHAR(20)), 'analysis/d4_semantic_sibling_target_backfill.csv' FROM dbo.silver_d4_semantic_sibling_target_backfill
    UNION ALL
    SELECT 'status', status, CAST(COUNT(*) AS VARCHAR(20)), 'Backfill row status.' FROM dbo.silver_d4_semantic_sibling_target_backfill GROUP BY status
    UNION ALL
    SELECT 'workspace', workspace_name, CAST(COUNT(*) AS VARCHAR(20)), 'Backfilled rows by workspace.' FROM dbo.silver_d4_semantic_sibling_target_backfill WHERE workspace_name <> '' GROUP BY workspace_name
) x;

DROP TABLE #decided_out;

END
