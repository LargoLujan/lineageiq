-- Warehouse-native translation of backend/scripts/38_build_deep_object_
-- lineage_enrichment.ps1 (Phase 2 migration continuation, 2026-07-21).
-- Reads dbo.bronze_items, dbo.silver_object_read_write_classification
-- (23), dbo.bronze_object_level_lineage_coverage, dbo.silver_manual_
-- lineage_review_queue (14), dbo.bronze_source_object_type_metadata_
-- evidence/_gaps, dbo.bronze_sql_endpoint_object_catalog (row count
-- only, no join). Only the item/source-object/gap CSV outputs are
-- migrated -- the original script's other two writes (deep-object-
-- lineage.json, and patching archive/lineage-explorer's already-
-- superseded lineage-explorer.json, which itself is script 35's
-- excluded output) are app-layer/archive-only and out of scope, same
-- exclusion rationale as script 35 and the second half of script 08.
-- Validated 2026-07-21: 0 new bugs. Item enrichment (every row), gaps
-- (every row), and summary (all 13 fields) matched exactly. Source objects
-- (every row, 0 missing/extra) carried only two already-documented
-- residual classes from earlier in this migration: (1) affected_
-- workspaces list order differs on 18 rows -- PowerShell's Sort-Object
-- treats punctuation (e.g. "_" vs "-") differently from this file's
-- LOWER()-ordinal STRING_AGG ordering, a punctuation-driven variant of
-- the session's established culture-vs-ordinal sort-order limitation;
-- (2) up to 67 rows differ in first-occurrence descriptive fields
-- (raw_object_type, object_name casing, ...) when an object_key has
-- multiple genuinely different candidate rows in bronze_object_read_
-- write_classification and no file-row-order column exists to pick the
-- true first one -- confirmed via direct query (5 candidate rows for
-- object_key 'FabricOrSQL||||customer', PS keeps the first-in-file one).
CREATE OR ALTER PROCEDURE dbo.sp_build_deep_object_lineage_enrichment
AS
BEGIN

IF OBJECT_ID('dbo.silver_deep_object_lineage_item_enrichment', 'U') IS NOT NULL DROP TABLE dbo.silver_deep_object_lineage_item_enrichment;
IF OBJECT_ID('dbo.silver_deep_object_lineage_source_objects', 'U') IS NOT NULL DROP TABLE dbo.silver_deep_object_lineage_source_objects;
IF OBJECT_ID('dbo.silver_deep_object_lineage_gaps', 'U') IS NOT NULL DROP TABLE dbo.silver_deep_object_lineage_gaps;
IF OBJECT_ID('dbo.silver_deep_object_lineage_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_deep_object_lineage_summary;

IF OBJECT_ID('tempdb..#items_first') IS NOT NULL DROP TABLE #items_first;
SELECT item_key, workspace_environment
INTO #items_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key, workspace_environment,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_items WHERE qualified_name <> '' AND (ISNULL(status,'') = '' OR status = 'discovered')
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#review_first') IS NOT NULL DROP TABLE #review_first;
SELECT item_key, review_status, priority_score, review_action
INTO #review_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, review_status, priority_score, ISNULL(review_action,'') AS review_action,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(item_qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_manual_lineage_review_queue
) x WHERE rn = 1;

-- ===========================================================================
-- Read/write rows: per-item counts (used regardless of coverage origin)
-- and per-object-key aggregation.
-- ===========================================================================
IF OBJECT_ID('tempdb..#rw') IS NOT NULL DROP TABLE #rw;
SELECT
    LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, item_qualified_name, workspace_name, item_type, item_name,
    LOWER(LTRIM(RTRIM(ISNULL(NULLIF(object_key,''), ISNULL(source_type,'') + '|' + ISNULL(source_server,'') + '|' + ISNULL(source_database,'') + '|' + ISNULL(schema_name,'') + '|' + ISNULL(object_name,''))))) AS object_key_norm,
    ISNULL(NULLIF(object_key,''), ISNULL(source_type,'') + '|' + ISNULL(source_server,'') + '|' + ISNULL(source_database,'') + '|' + ISNULL(schema_name,'') + '|' + ISNULL(object_name,'')) AS object_key,
    ISNULL(source_type,'') AS source_type, ISNULL(source_server,'') AS source_server, ISNULL(source_database,'') AS source_database,
    ISNULL(schema_name,'') AS schema_name, ISNULL(object_name,'') AS object_name, ISNULL(object_display_name,'') AS object_display_name,
    ISNULL(object_type,'') AS object_type, ISNULL(raw_object_type,'') AS raw_object_type,
    ISNULL(object_type_status,'') AS object_type_status,
    LOWER(LTRIM(RTRIM(ISNULL(object_type_status,'')))) AS object_type_status_norm,
    ISNULL(object_type_confidence,'') AS object_type_confidence,
    LOWER(LTRIM(RTRIM(ISNULL(operation_type,'')))) AS operation_norm,
    LOWER(LTRIM(RTRIM(ISNULL(lineage_confidence,'')))) AS lineage_confidence_norm,
    ISNULL(evidence,'') AS evidence
INTO #rw
FROM dbo.silver_object_read_write_classification
WHERE ISNULL(item_qualified_name,'') <> '';

IF OBJECT_ID('tempdb..#rw_item_counts') IS NOT NULL DROP TABLE #rw_item_counts;
SELECT item_key,
    COUNT(*) AS object_reference_count,
    SUM(CASE WHEN operation_norm = 'read' THEN 1 ELSE 0 END) AS read_count,
    SUM(CASE WHEN operation_norm = 'write' THEN 1 ELSE 0 END) AS write_count,
    SUM(CASE WHEN operation_norm = 'execute' THEN 1 ELSE 0 END) AS execute_count,
    SUM(CASE WHEN operation_norm NOT IN ('read','write','execute') THEN 1 ELSE 0 END) AS unknown_count,
    SUM(CASE WHEN lineage_confidence_norm = 'confirmed' THEN 1 ELSE 0 END) AS confirmed_lineage_rows,
    SUM(CASE WHEN lineage_confidence_norm = 'likely' THEN 1 ELSE 0 END) AS likely_lineage_rows,
    SUM(CASE WHEN object_type_status_norm = 'exact' THEN 1 ELSE 0 END) AS exact_object_reference_count,
    SUM(CASE WHEN object_type_status_norm = 'ambiguous' THEN 1 ELSE 0 END) AS ambiguous_object_reference_count
INTO #rw_item_counts
FROM #rw
GROUP BY item_key;

IF OBJECT_ID('tempdb..#rw_item_first') IS NOT NULL DROP TABLE #rw_item_first;
SELECT item_key, item_qualified_name, workspace_name, item_type, item_name
INTO #rw_item_first
FROM (
    SELECT item_key, item_qualified_name, workspace_name, item_type, item_name,
        ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY (SELECT NULL)) AS rn
    FROM #rw
) x WHERE rn = 1;

-- ===========================================================================
-- Coverage rows (last-row-per-item-in-file wins in the original; treated
-- as an arbitrary single representative here since true duplicates would
-- be a data-quality anomaly in a coverage file, not an expected key shape).
-- ===========================================================================
IF OBJECT_ID('tempdb..#coverage_first') IS NOT NULL DROP TABLE #coverage_first;
SELECT item_key, item_qualified_name, workspace_name, workspace_environment, item_type, item_name,
    source_count, object_count, exact_object_count, ambiguous_object_count, coverage_status, gap_reason, next_action
INTO #coverage_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, item_qualified_name, workspace_name,
        ISNULL(workspace_environment,'') AS workspace_environment, item_type, item_name,
        ISNULL(TRY_CAST(source_count AS INT),0) AS source_count, ISNULL(TRY_CAST(object_count AS INT),0) AS object_count,
        ISNULL(TRY_CAST(exact_object_count AS INT),0) AS exact_object_count, ISNULL(TRY_CAST(ambiguous_object_count AS INT),0) AS ambiguous_object_count,
        ISNULL(coverage_status,'') AS coverage_status, ISNULL(gap_reason,'') AS gap_reason, ISNULL(next_action,'') AS next_action,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(item_qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_object_level_lineage_coverage
    WHERE ISNULL(item_qualified_name,'') <> ''
) x WHERE rn = 1;

-- ===========================================================================
-- Union of item keys needing an aggregate row, with base fields sourced
-- from coverage when covered, else from the first matching read/write row.
-- ===========================================================================
IF OBJECT_ID('tempdb..#item_keys') IS NOT NULL DROP TABLE #item_keys;
SELECT item_key INTO #item_keys FROM #coverage_first
UNION
SELECT item_key FROM #rw_item_counts;

IF OBJECT_ID('tempdb..#item_base') IS NOT NULL DROP TABLE #item_base;
SELECT
    k.item_key,
    CASE WHEN cf.item_key IS NOT NULL THEN 1 ELSE 0 END AS is_covered,
    ISNULL(cf.item_qualified_name, rwf.item_qualified_name) AS item_qualified_name,
    ISNULL(cf.workspace_name, rwf.workspace_name) AS workspace_name,
    CASE WHEN cf.item_key IS NOT NULL THEN cf.workspace_environment ELSE ISNULL(it.workspace_environment,'') END AS environment,
    ISNULL(cf.item_type, rwf.item_type) AS item_type,
    ISNULL(cf.item_name, rwf.item_name) AS item_name,
    ISNULL(cf.source_count, 0) AS source_count,
    ISNULL(cf.object_count, 0) AS unique_object_count,
    ISNULL(cf.exact_object_count, 0) AS exact_object_count,
    ISNULL(cf.ambiguous_object_count, 0) AS ambiguous_object_count,
    ISNULL(cf.coverage_status, CASE WHEN cf.item_key IS NULL THEN 'object_level_present' ELSE '' END) AS coverage_status,
    ISNULL(cf.gap_reason, '') AS gap_reason,
    CASE WHEN cf.item_key IS NOT NULL THEN
            (CASE WHEN rv.item_key IS NOT NULL AND rv.review_action <> '' THEN rv.review_action ELSE cf.next_action END)
         ELSE '' END AS next_action_base,
    CASE WHEN cf.item_key IS NOT NULL THEN 'analysis/object_level_lineage_coverage.csv' ELSE 'analysis/object_read_write_classification.csv' END AS evidence,
    ISNULL(rv.review_status, '') AS review_status,
    CASE WHEN cf.item_key IS NOT NULL THEN ISNULL(rv.priority_score, 0) ELSE 0 END AS priority_score
INTO #item_base
FROM #item_keys k
LEFT JOIN #coverage_first cf ON cf.item_key = k.item_key
LEFT JOIN #rw_item_first rwf ON rwf.item_key = k.item_key
LEFT JOIN #items_first it ON it.item_key = k.item_key
LEFT JOIN #review_first rv ON rv.item_key = k.item_key;

IF OBJECT_ID('tempdb..#item_final') IS NOT NULL DROP TABLE #item_final;
SELECT
    b.workspace_name, b.environment, b.item_type, b.item_name, b.item_qualified_name,
    b.source_count, b.unique_object_count,
    ISNULL(c.object_reference_count,0) AS object_reference_count,
    b.exact_object_count, b.ambiguous_object_count,
    ISNULL(c.exact_object_reference_count,0) AS exact_object_reference_count,
    ISNULL(c.ambiguous_object_reference_count,0) AS ambiguous_object_reference_count,
    ISNULL(c.confirmed_lineage_rows,0) AS confirmed_lineage_rows,
    ISNULL(c.likely_lineage_rows,0) AS likely_lineage_rows,
    ISNULL(c.read_count,0) AS read_count, ISNULL(c.write_count,0) AS write_count,
    ISNULL(c.execute_count,0) AS execute_count, ISNULL(c.unknown_count,0) AS unknown_count,
    b.coverage_status, b.review_status, b.priority_score, b.gap_reason, b.next_action_base, b.evidence,
    (CASE WHEN b.coverage_status = 'no_source' THEN 'source_missing'
          WHEN b.coverage_status = 'source_only' THEN 'object_missing'
          WHEN ISNULL(c.unknown_count,0) > 0 THEN 'blocked_unknown_operation'
          WHEN ISNULL(c.ambiguous_object_reference_count,0) > 0 THEN 'needs_object_type_resolution'
          WHEN ISNULL(c.likely_lineage_rows,0) > 0 THEN 'needs_lineage_confirmation'
          ELSE 'ready_confirmed' END) AS deep_lineage_status
INTO #item_final
FROM #item_base b
LEFT JOIN #rw_item_counts c ON c.item_key = b.item_key;

SELECT
    workspace_name, environment, item_type, item_name, item_qualified_name,
    source_count, unique_object_count, object_reference_count, exact_object_count, ambiguous_object_count,
    exact_object_reference_count, ambiguous_object_reference_count, confirmed_lineage_rows, likely_lineage_rows,
    read_count, write_count, execute_count, unknown_count, coverage_status, review_status, priority_score, gap_reason,
    deep_lineage_status,
    (CASE deep_lineage_status
        WHEN 'source_missing' THEN 'Identify the source system/object from local definitions, Azure DevOps, SharePoint, OneLake, or owner evidence before sequencing this item.'
        WHEN 'object_missing' THEN 'Record table, view, stored procedure, file, or lakehouse object evidence in index/manual_lineage_object_evidence.csv.'
        WHEN 'blocked_unknown_operation' THEN 'Confirm whether the object interaction is read, write, execute, or informational before using it for orchestration.'
        WHEN 'needs_object_type_resolution' THEN 'Resolve ambiguous table_or_view/native_query_object rows through metadata evidence or approved manual overrides.'
        WHEN 'needs_lineage_confirmation' THEN 'Confirm likely object-level lineage before treating it as a hard dependency.'
        ELSE (CASE WHEN next_action_base <> '' THEN next_action_base ELSE 'Ready for review with current evidence.' END)
     END) AS next_action,
    evidence
INTO dbo.silver_deep_object_lineage_item_enrichment
FROM #item_final;

-- ===========================================================================
-- Source object aggregation.
-- ===========================================================================
IF OBJECT_ID('tempdb..#src_first') IS NOT NULL DROP TABLE #src_first;
SELECT object_key_norm, object_key, source_type, source_server, source_database, schema_name, object_name,
    object_display_name, object_type, raw_object_type, object_type_status, object_type_confidence
INTO #src_first
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY object_key_norm ORDER BY (SELECT NULL)) AS rn
    FROM #rw
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#src_counts') IS NOT NULL DROP TABLE #src_counts;
SELECT object_key_norm,
    SUM(CASE WHEN operation_norm = 'read' THEN 1 ELSE 0 END) AS read_count,
    SUM(CASE WHEN operation_norm = 'write' THEN 1 ELSE 0 END) AS write_count,
    SUM(CASE WHEN operation_norm = 'execute' THEN 1 ELSE 0 END) AS execute_count,
    SUM(CASE WHEN operation_norm NOT IN ('read','write','execute') THEN 1 ELSE 0 END) AS unknown_count,
    SUM(CASE WHEN lineage_confidence_norm = 'confirmed' THEN 1 ELSE 0 END) AS confirmed_lineage_rows,
    SUM(CASE WHEN lineage_confidence_norm = 'likely' THEN 1 ELSE 0 END) AS likely_lineage_rows,
    SUM(CASE WHEN object_type_status_norm = 'exact' THEN 1 ELSE 0 END) AS exact_reference_count,
    SUM(CASE WHEN object_type_status_norm = 'ambiguous' THEN 1 ELSE 0 END) AS ambiguous_reference_count,
    COUNT(DISTINCT LOWER(LTRIM(RTRIM(item_qualified_name)))) AS affected_item_count,
    COUNT(DISTINCT LOWER(LTRIM(RTRIM(workspace_name)))) AS affected_workspace_count
INTO #src_counts
FROM #rw
GROUP BY object_key_norm;

IF OBJECT_ID('tempdb..#src_item_types') IS NOT NULL DROP TABLE #src_item_types;
;WITH d AS (SELECT DISTINCT object_key_norm, item_type FROM #rw WHERE ISNULL(item_type,'') <> ''),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY object_key_norm ORDER BY LOWER(item_type)) AS rn FROM d)
SELECT object_key_norm, STRING_AGG(item_type, '; ') WITHIN GROUP (ORDER BY rn) AS affected_item_types
INTO #src_item_types FROM r GROUP BY object_key_norm;

IF OBJECT_ID('tempdb..#src_workspaces') IS NOT NULL DROP TABLE #src_workspaces;
;WITH d AS (SELECT DISTINCT object_key_norm, workspace_name FROM #rw WHERE ISNULL(workspace_name,'') <> ''),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY object_key_norm ORDER BY LOWER(workspace_name)) AS rn FROM d)
SELECT object_key_norm, STRING_AGG(workspace_name, '; ') WITHIN GROUP (ORDER BY rn) AS affected_workspaces
INTO #src_workspaces FROM r GROUP BY object_key_norm;

IF OBJECT_ID('tempdb..#src_evidence') IS NOT NULL DROP TABLE #src_evidence;
;WITH d AS (SELECT DISTINCT object_key_norm, evidence FROM #rw WHERE ISNULL(evidence,'') <> ''),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY object_key_norm ORDER BY LOWER(evidence)) AS rn FROM d)
SELECT object_key_norm, STRING_AGG(evidence, '; ') WITHIN GROUP (ORDER BY rn) AS evidence_samples
INTO #src_evidence FROM r GROUP BY object_key_norm;

SELECT
    sf.object_key, sf.source_type, sf.source_server, sf.source_database, sf.schema_name, sf.object_name,
    sf.object_display_name, sf.object_type, sf.raw_object_type, sf.object_type_status, sf.object_type_confidence,
    ISNULL(sc.read_count,0) AS read_count, ISNULL(sc.write_count,0) AS write_count, ISNULL(sc.execute_count,0) AS execute_count,
    ISNULL(sc.unknown_count,0) AS unknown_count, ISNULL(sc.confirmed_lineage_rows,0) AS confirmed_lineage_rows,
    ISNULL(sc.likely_lineage_rows,0) AS likely_lineage_rows, ISNULL(sc.exact_reference_count,0) AS exact_reference_count,
    ISNULL(sc.ambiguous_reference_count,0) AS ambiguous_reference_count,
    ISNULL(sc.affected_item_count,0) AS affected_item_count, ISNULL(sc.affected_workspace_count,0) AS affected_workspace_count,
    ISNULL(sit.affected_item_types,'') AS affected_item_types, ISNULL(sw.affected_workspaces,'') AS affected_workspaces,
    (CASE WHEN ISNULL(sc.ambiguous_reference_count,0) > 0 THEN 'needs_object_type_resolution' ELSE 'exact' END) AS exactness_status,
    ISNULL(se.evidence_samples,'') AS evidence
INTO dbo.silver_deep_object_lineage_source_objects
FROM #src_first sf
LEFT JOIN #src_counts sc ON sc.object_key_norm = sf.object_key_norm
LEFT JOIN #src_item_types sit ON sit.object_key_norm = sf.object_key_norm
LEFT JOIN #src_workspaces sw ON sw.object_key_norm = sf.object_key_norm
LEFT JOIN #src_evidence se ON se.object_key_norm = sf.object_key_norm;

-- ===========================================================================
-- Gaps.
-- ===========================================================================
DECLARE @sourceMissingCount INT = (SELECT COUNT(*) FROM dbo.silver_manual_lineage_review_queue WHERE review_status = 'source_missing_manual_review_required');
DECLARE @sourceKnownObjectMissingCount INT = (SELECT COUNT(*) FROM dbo.silver_manual_lineage_review_queue WHERE review_status = 'source_known_object_missing');
DECLARE @ambiguousRowCount INT = (SELECT COUNT(*) FROM #rw WHERE object_type_status_norm = 'ambiguous');
DECLARE @ambiguousUniqueCount INT = (SELECT COUNT(DISTINCT object_key) FROM #rw WHERE object_type_status_norm = 'ambiguous' AND object_key <> '');
DECLARE @likelyRowCount INT = (SELECT COUNT(*) FROM #rw WHERE lineage_confidence_norm = 'likely');
DECLARE @metadataGapCount INT = (SELECT COUNT(*) FROM dbo.bronze_source_object_type_metadata_gaps);
DECLARE @unknownOpCount INT = (SELECT COUNT(*) FROM #rw WHERE operation_norm NOT IN ('read','write','execute'));
DECLARE @copyJobAmbiguousCount INT = (SELECT COUNT(*) FROM #rw WHERE item_type = 'CopyJob' AND object_type_status_norm = 'ambiguous');

SELECT gap_id, phase, area, severity, affected_count, evidence, recommended_action
INTO dbo.silver_deep_object_lineage_gaps
FROM (
    SELECT 'phase12_source_missing_manual_review' AS gap_id, 'Phase 12' AS phase, 'object_lineage' AS area, 'high' AS severity,
        @sourceMissingCount AS affected_count, 'manual review queue items without a source dependency' AS evidence,
        'Inspect definitions and source settings, then record source/object evidence in index/manual_lineage_object_evidence.csv.' AS recommended_action
    UNION ALL
    SELECT 'phase12_source_known_object_missing', 'Phase 12', 'object_lineage', 'high', @sourceKnownObjectMissingCount,
        'manual review queue items with source dependencies but no object evidence',
        'Review item definitions and record the exact table, view, stored procedure, file, or lakehouse object evidence.'
    UNION ALL
    SELECT 'phase12_ambiguous_object_types', 'Phase 12', 'object_type_resolution', 'high', @ambiguousRowCount,
        CAST(@ambiguousUniqueCount AS VARCHAR(20)) + ' unique source objects still have ambiguous physical type references.',
        'Resolve through read-only metadata, owner-approved catalog evidence, or index/source_object_type_overrides.csv.'
    UNION ALL
    SELECT 'phase12_likely_lineage_rows', 'Phase 12', 'dependency_confidence', 'high', @likelyRowCount,
        'object lineage rows remain likely instead of confirmed',
        'Confirm likely rows before using them as hard sequencing or change-impact dependencies.'
    UNION ALL
    SELECT 'phase12_metadata_access_gaps', 'Phase 12', 'metadata_access', 'medium', @metadataGapCount,
        'analysis/source_object_type_metadata_gaps.csv',
        'Validate endpoint access or capture owner-approved catalog evidence for unresolved metadata targets.'
    UNION ALL
    SELECT 'phase12_unknown_operations', 'Phase 12', 'read_write_classification', 'medium', @unknownOpCount,
        'object read/write classification rows with unknown operation type',
        'Confirm the operation as read, write, execute, or informational before orchestration use.'
    UNION ALL
    SELECT 'phase12_copyjob_exact_type_gap', 'Phase 12', 'copyjob_lineage', 'high', @copyJobAmbiguousCount,
        'CopyJob object rows are present but physical table/view types are unresolved.',
        'Resolve CopyJob source/sink object types through metadata or approved manual review.'
) g
WHERE affected_count > 0;

-- ===========================================================================
-- Summary.
-- ===========================================================================
SELECT
    (SELECT COUNT(*) FROM dbo.silver_deep_object_lineage_item_enrichment) AS item_count,
    (SELECT COUNT(*) FROM dbo.silver_deep_object_lineage_source_objects) AS source_object_count,
    (SELECT COUNT(*) FROM #rw) AS object_reference_count,
    (SELECT COUNT(*) FROM dbo.bronze_object_level_lineage_coverage WHERE coverage_status = 'object_level_present') AS object_level_present_items,
    (SELECT COUNT(*) FROM dbo.bronze_object_level_lineage_coverage WHERE coverage_status = 'source_only') AS source_only_items,
    (SELECT COUNT(*) FROM dbo.bronze_object_level_lineage_coverage WHERE coverage_status = 'no_source') AS no_source_items,
    (SELECT COUNT(*) FROM #rw WHERE object_type_status_norm = 'exact') AS exact_object_reference_count,
    @ambiguousRowCount AS ambiguous_object_reference_count,
    (SELECT COUNT(*) FROM #rw WHERE lineage_confidence_norm = 'confirmed') AS confirmed_lineage_rows,
    @likelyRowCount AS likely_lineage_rows,
    (SELECT COUNT(*) FROM dbo.bronze_source_object_type_metadata_evidence) AS metadata_evidence_rows,
    @metadataGapCount AS metadata_gap_rows,
    (SELECT COUNT(*) FROM dbo.bronze_sql_endpoint_object_catalog) AS sql_endpoint_catalog_rows,
    (SELECT COUNT(*) FROM dbo.silver_deep_object_lineage_gaps) AS gap_count
INTO dbo.silver_deep_object_lineage_summary;

END
