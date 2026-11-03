-- Warehouse-native translation of backend/scripts/28_build_d3_likely_
-- object_lineage_confirmation_package.ps1 (Phase 2 migration continuation,
-- 2026-07-21). Reads dbo.silver_object_read_write_classification (23),
-- dbo.silver_likely_conflict_cleanup_queue (25, phase D3),
-- dbo.silver_orchestration_v2_plan (24), dbo.bronze_items.
-- row_id values ("D3O000001", ...) are assigned by a deterministic sort
-- here, not the original's file row order (the Warehouse carries no such
-- ordering) -- they are opaque per-row identifiers, validation matches
-- rows by (item_qualified_name, object_key, operation_type) instead.
-- Grouped-count text fields (operation_types, source_types, ...) and
-- sample_objects tie-break ties/order via LOWER() instead of PowerShell's
-- Group-Object first-occurrence order, a documented, already-accepted
-- limitation carried from earlier scripts in this migration.
CREATE OR ALTER PROCEDURE dbo.sp_build_d3_likely_object_lineage_confirmation_package
AS
BEGIN

IF OBJECT_ID('dbo.silver_d3_likely_object_lineage_item_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d3_likely_object_lineage_item_queue;
IF OBJECT_ID('dbo.silver_d3_likely_object_lineage_object_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d3_likely_object_lineage_object_queue;
IF OBJECT_ID('dbo.silver_d3_likely_object_lineage_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d3_likely_object_lineage_summary;
IF OBJECT_ID('dbo.silver_d3_object_lineage_confirmation_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d3_object_lineage_confirmation_template;
IF OBJECT_ID('dbo.silver_d3_readonly_object_lineage_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d3_readonly_object_lineage_targets;

IF OBJECT_ID('tempdb..#items_first') IS NOT NULL DROP TABLE #items_first;
SELECT item_key, workspace_environment, technical_id
INTO #items_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key, workspace_environment, technical_id,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_items WHERE qualified_name <> ''
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#v2_first') IS NOT NULL DROP TABLE #v2_first;
SELECT item_key, v2_status, needs_lineage_confirmation_count, needs_object_type_confirmation_count, v2_recommended_next_action
INTO #v2_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key, v2_status, needs_lineage_confirmation_count, needs_object_type_confirmation_count, v2_recommended_next_action,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_orchestration_v2_plan
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#d3_cleanup') IS NOT NULL DROP TABLE #d3_cleanup;
SELECT item_key, priority_score, blocker_count, workspace_name, item_type, item_name, item_qualified_name
INTO #d3_cleanup
FROM (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, priority_score, blocker_count, workspace_name, item_type, item_name, item_qualified_name,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(item_qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_likely_conflict_cleanup_queue WHERE phase_id = 'D3'
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#needs_confirmation') IS NOT NULL DROP TABLE #needs_confirmation;
SELECT
    ROW_NUMBER() OVER (ORDER BY LOWER(LTRIM(RTRIM(item_qualified_name))), LOWER(LTRIM(RTRIM(ISNULL(object_display_name,'')))), LOWER(LTRIM(RTRIM(ISNULL(operation_type,''))))) AS row_seq,
    LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key,
    workspace_name, item_type, item_name, item_qualified_name,
    ISNULL(source_type,'') AS source_type, ISNULL(source_server,'') AS source_server, ISNULL(source_database,'') AS source_database,
    ISNULL(schema_name,'') AS schema_name, ISNULL(object_name,'') AS object_name, ISNULL(object_display_name,'') AS object_display_name,
    ISNULL(object_key,'') AS object_key, ISNULL(object_type,'') AS object_type, ISNULL(raw_object_type,'') AS raw_object_type,
    ISNULL(object_type_status,'') AS object_type_status, ISNULL(object_type_confidence,'') AS object_type_confidence,
    ISNULL(source_label,'') AS source_label, ISNULL(source_qualified_name,'') AS source_qualified_name, ISNULL(semantic_table,'') AS semantic_table,
    ISNULL(usage_type,'') AS usage_type, ISNULL(usage_type_normalized,'') AS usage_type_normalized, ISNULL(operation_type,'') AS operation_type,
    ISNULL(lineage_confidence,'') AS lineage_confidence, ISNULL(hardening_status,'') AS hardening_status,
    ISNULL(hardening_issue_count,0) AS hardening_issue_count, ISNULL(hardening_issue_types,'') AS hardening_issue_types,
    ISNULL(preferred_confirmation_sources,'') AS preferred_confirmation_sources, ISNULL(hardening_next_actions,'') AS hardening_next_actions,
    ISNULL(orchestration_risk_flags,'') AS orchestration_risk_flags, ISNULL(orchestration_parallel_readiness,'') AS orchestration_parallel_readiness,
    ISNULL(scheduling_readiness,'') AS scheduling_readiness, ISNULL(hardening_priority_score,0) AS hardening_priority_score,
    ISNULL(evidence,'') AS evidence
INTO #needs_confirmation
FROM dbo.silver_object_read_write_classification
WHERE scheduling_readiness = 'needs_lineage_confirmation';

IF OBJECT_ID('tempdb..#object_final') IS NOT NULL DROP TABLE #object_final;
SELECT
    'D3O' + RIGHT('00000' + CAST(nc.row_seq AS VARCHAR(10)), 6) AS row_id,
    (CASE WHEN ISNULL(dc.priority_score,0) <> 0 THEN dc.priority_score
          WHEN ISNULL(nc.hardening_priority_score,0) <> 0 THEN nc.hardening_priority_score
          ELSE 70 END)
    + CASE WHEN nc.operation_type = 'write' THEN 10 WHEN nc.operation_type = 'execute' THEN 15 ELSE 0 END
    + CASE WHEN it.workspace_environment = 'PRO' THEN 5 ELSE 0 END AS priority_score,
    nc.workspace_name, ISNULL(it.workspace_environment,'') AS workspace_environment, nc.item_type, nc.item_name, nc.item_qualified_name,
    ISNULL(it.technical_id,'') AS technical_id,
    nc.source_type, nc.source_server, nc.source_database, nc.schema_name, nc.object_name, nc.object_display_name, nc.object_key,
    nc.object_type, nc.raw_object_type, nc.object_type_status, nc.object_type_confidence, nc.source_label, nc.source_qualified_name,
    nc.semantic_table, nc.usage_type, nc.usage_type_normalized, nc.operation_type, nc.lineage_confidence, nc.hardening_status,
    nc.hardening_issue_count, nc.hardening_issue_types, nc.preferred_confirmation_sources,
    LEFT(LTRIM(RTRIM(nc.hardening_next_actions)), 900) AS hardening_next_actions,
    nc.orchestration_risk_flags, nc.orchestration_parallel_readiness, nc.scheduling_readiness,
    ISNULL(v2.v2_status,'') AS v2_status,
    LEFT(LTRIM(RTRIM(ISNULL(v2.v2_recommended_next_action,''))), 700) AS v2_recommended_next_action,
    LEFT(LTRIM(RTRIM(nc.evidence)), 1200) AS evidence,
    (CASE nc.item_type
        WHEN 'SemanticModel' THEN 'Confirm the semantic model source object from TMDL, Power Query/M, partitions, model expressions, or owner-approved source mapping.'
        WHEN 'Notebook' THEN 'Confirm the notebook ' + (CASE WHEN nc.operation_type <> '' THEN nc.operation_type ELSE 'operation' END) + ' reference from code, SQL cells, Spark read/write calls, default lakehouse metadata, Azure DevOps, or owner evidence.'
        WHEN 'CopyJob' THEN 'Confirm the CopyJob ' + (CASE WHEN nc.operation_type <> '' THEN nc.operation_type ELSE 'operation' END) + ' reference from source/sink mapping and connection metadata.'
        WHEN 'DataPipeline' THEN 'Confirm the pipeline ' + (CASE WHEN nc.operation_type <> '' THEN nc.operation_type ELSE 'operation' END) + ' reference from activities, invoked items, inherited lineage, copy source/sink mappings, and owner evidence.'
        ELSE 'Confirm object lineage from item definition, code, metadata, or owner-approved evidence.' END) AS recommended_method,
    (CASE nc.item_type
        WHEN 'SemanticModel' THEN 'Read model/TMDL/Power Query metadata and verify the exact source ' + (CASE WHEN nc.object_type <> '' THEN nc.object_type ELSE 'object' END) + ' and usage.'
        WHEN 'Notebook' THEN 'Read notebook code and verify whether this ' + (CASE WHEN nc.object_type <> '' THEN nc.object_type ELSE 'object' END) + ' is actually read, written, or executed.'
        WHEN 'CopyJob' THEN 'Read CopyJob definition and verify source/sink object mapping.'
        WHEN 'DataPipeline' THEN 'Read pipeline activities and invoked item lineage, then verify direct or inherited object usage.'
        ELSE 'Read item metadata and verify exact object usage.' END) AS readonly_method,
    'Confirm, reject, or explicitly block this object-level read/write/execute relationship with evidence.' AS d3_gate_to_close
INTO #object_final
FROM #needs_confirmation nc
LEFT JOIN #items_first it ON it.item_key = nc.item_key
LEFT JOIN #d3_cleanup dc ON dc.item_key = nc.item_key
LEFT JOIN #v2_first v2 ON v2.item_key = nc.item_key;

SELECT
    row_id, priority_score,
    CASE WHEN priority_score >= 1000 THEN 'critical' WHEN priority_score >= 250 THEN 'high' WHEN priority_score >= 100 THEN 'medium' ELSE 'low' END AS priority_band,
    workspace_name, workspace_environment, item_type, item_name, item_qualified_name, technical_id,
    source_type, source_server, source_database, schema_name, object_name, object_display_name, object_key,
    object_type, raw_object_type, object_type_status, object_type_confidence, source_label, source_qualified_name,
    semantic_table, usage_type, usage_type_normalized, operation_type, lineage_confidence, hardening_status,
    hardening_issue_count, hardening_issue_types, preferred_confirmation_sources, hardening_next_actions,
    orchestration_risk_flags, orchestration_parallel_readiness, scheduling_readiness, v2_status, v2_recommended_next_action,
    evidence, recommended_method, readonly_method, d3_gate_to_close
INTO dbo.silver_d3_likely_object_lineage_object_queue
FROM #object_final;

SELECT
    row_id, item_qualified_name, item_type, item_name, operation_type AS current_operation_type,
    source_type AS current_source_type, source_server AS current_source_server, source_database AS current_source_database,
    schema_name AS current_schema_name, object_name AS current_object_name, object_display_name AS current_object_display_name,
    object_type AS current_object_type, lineage_confidence AS current_lineage_confidence,
    LEFT(LTRIM(RTRIM(evidence)), 1000) AS current_evidence,
    '' AS proposed_status, operation_type AS confirmed_operation_type, '' AS confirmed_source_type, '' AS confirmed_source_server,
    '' AS confirmed_source_database, '' AS confirmed_schema_name, '' AS confirmed_object_name, '' AS confirmed_object_type,
    '' AS confirmation_source, '' AS confirmation_evidence, '' AS reviewer, '' AS reviewed_at,
    'D3 template row. Set proposed_status to confirmed, rejected, or blocked before applying any future evidence update.' AS notes
INTO dbo.silver_d3_object_lineage_confirmation_template
FROM #object_final;

SELECT
    row_id, priority_score,
    CASE WHEN priority_score >= 1000 THEN 'critical' WHEN priority_score >= 250 THEN 'high' WHEN priority_score >= 100 THEN 'medium' ELSE 'low' END AS priority_band,
    workspace_name, item_type, item_name, item_qualified_name, operation_type, object_display_name, object_type, lineage_confidence,
    readonly_method, preferred_confirmation_sources,
    'analysis/d3_object_lineage_confirmation_template.csv' AS template_path,
    'Read-only/manual confirmation target. Do not modify Fabric or evidence indexes from this package alone.' AS notes
INTO dbo.silver_d3_readonly_object_lineage_targets
FROM #object_final;

-- ===========================================================================
-- Item queue (one row per D3 cleanup item, aggregating its object rows).
-- ===========================================================================
IF OBJECT_ID('tempdb..#item_agg_counts') IS NOT NULL DROP TABLE #item_agg_counts;
SELECT item_key, COUNT(*) AS row_count
INTO #item_agg_counts FROM #object_final o
CROSS APPLY (SELECT LOWER(LTRIM(RTRIM(o.item_qualified_name))) AS item_key) k
GROUP BY item_key;

IF OBJECT_ID('tempdb..#op_types_agg') IS NOT NULL DROP TABLE #op_types_agg;
;WITH t AS (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, operation_type, COUNT(*) AS cnt FROM #object_final GROUP BY LOWER(LTRIM(RTRIM(item_qualified_name))), operation_type
),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY cnt DESC, LOWER(operation_type) ASC) AS rn FROM t)
SELECT item_key, STRING_AGG(operation_type + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS operation_types
INTO #op_types_agg FROM r GROUP BY item_key;

IF OBJECT_ID('tempdb..#src_types_agg') IS NOT NULL DROP TABLE #src_types_agg;
;WITH t AS (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, source_type, COUNT(*) AS cnt FROM #object_final GROUP BY LOWER(LTRIM(RTRIM(item_qualified_name))), source_type
),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY cnt DESC, LOWER(source_type) ASC) AS rn FROM t)
SELECT item_key, STRING_AGG(source_type + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS source_types
INTO #src_types_agg FROM r GROUP BY item_key;

IF OBJECT_ID('tempdb..#obj_status_agg') IS NOT NULL DROP TABLE #obj_status_agg;
;WITH t AS (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, object_type_status, COUNT(*) AS cnt FROM #object_final GROUP BY LOWER(LTRIM(RTRIM(item_qualified_name))), object_type_status
),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY cnt DESC, LOWER(object_type_status) ASC) AS rn FROM t)
SELECT item_key, STRING_AGG(object_type_status + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS object_type_statuses
INTO #obj_status_agg FROM r GROUP BY item_key;

IF OBJECT_ID('tempdb..#sample_objects_agg') IS NOT NULL DROP TABLE #sample_objects_agg;
;WITH r AS (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, operation_type, object_display_name,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(item_qualified_name))) ORDER BY LOWER(object_display_name), LOWER(operation_type)) AS rn
    FROM #object_final
)
SELECT item_key, STRING_AGG(operation_type + ': ' + object_display_name, '; ') WITHIN GROUP (ORDER BY rn) AS sample_objects
INTO #sample_objects_agg FROM r WHERE rn <= 10 GROUP BY item_key;

SELECT
    dc.priority_score,
    CASE WHEN dc.priority_score >= 1000 THEN 'critical' WHEN dc.priority_score >= 250 THEN 'high' WHEN dc.priority_score >= 100 THEN 'medium' ELSE 'low' END AS priority_band,
    dc.workspace_name, ISNULL(it.workspace_environment,'') AS workspace_environment, dc.item_type, dc.item_name, dc.item_qualified_name,
    ISNULL(it.technical_id,'') AS technical_id,
    ISNULL(ac.row_count, 0) AS likely_object_lineage_row_count,
    ISNULL(dc.blocker_count, 0) AS blocker_count,
    ISNULL(ota.operation_types, '') AS operation_types,
    ISNULL(sta.source_types, '') AS source_types,
    ISNULL(osa.object_type_statuses, '') AS object_type_statuses,
    LEFT(ISNULL(soa.sample_objects, ''), 1200) AS sample_objects,
    ISNULL(v2.v2_status, '') AS v2_status,
    ISNULL(v2.needs_lineage_confirmation_count, 0) AS v2_needs_lineage_confirmation_count,
    ISNULL(v2.needs_object_type_confirmation_count, 0) AS v2_needs_object_type_confirmation_count,
    LEFT(LTRIM(RTRIM(ISNULL(v2.v2_recommended_next_action,''))), 700) AS v2_recommended_next_action,
    'Confirm or reject every likely object-level read/write/execute row before this item becomes an operational sequencing rule.' AS recommended_method,
    'analysis/d3_likely_object_lineage_object_queue.csv' AS object_queue_path,
    'analysis/d3_object_lineage_confirmation_template.csv' AS template_path
INTO dbo.silver_d3_likely_object_lineage_item_queue
FROM #d3_cleanup dc
LEFT JOIN #items_first it ON it.item_key = dc.item_key
LEFT JOIN #v2_first v2 ON v2.item_key = dc.item_key
LEFT JOIN #item_agg_counts ac ON ac.item_key = dc.item_key
LEFT JOIN #op_types_agg ota ON ota.item_key = dc.item_key
LEFT JOIN #src_types_agg sta ON sta.item_key = dc.item_key
LEFT JOIN #obj_status_agg osa ON osa.item_key = dc.item_key
LEFT JOIN #sample_objects_agg soa ON soa.item_key = dc.item_key;

-- ===========================================================================
-- Summary.
-- ===========================================================================
SELECT summary_scope, group_key, row_count, high_or_critical_count, max_priority_score, notes
INTO dbo.silver_d3_likely_object_lineage_summary
FROM (
    SELECT 'total' AS summary_scope, 'D3 item blockers' AS group_key, COUNT(*) AS row_count,
        SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END) AS high_or_critical_count,
        ISNULL(MAX(priority_score),0) AS max_priority_score,
        'Items from analysis/likely_conflict_cleanup_queue.csv phase D3.' AS notes
    FROM dbo.silver_d3_likely_object_lineage_item_queue

    UNION ALL
    SELECT 'total', 'D3 likely object-lineage rows', COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Object read/write/execute rows from analysis/object_read_write_classification.csv needing lineage confirmation.'
    FROM dbo.silver_d3_likely_object_lineage_object_queue

    UNION ALL
    SELECT 'item_type_objects', item_type, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D3 object rows grouped by item type.'
    FROM dbo.silver_d3_likely_object_lineage_object_queue GROUP BY item_type

    UNION ALL
    SELECT 'operation_type', operation_type, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D3 object rows grouped by read/write/execute operation.'
    FROM dbo.silver_d3_likely_object_lineage_object_queue GROUP BY operation_type

    UNION ALL
    SELECT 'source_type', source_type, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D3 object rows grouped by source type.'
    FROM dbo.silver_d3_likely_object_lineage_object_queue GROUP BY source_type

    UNION ALL
    SELECT TOP 12 'hardening_issue_types', hardening_issue_types, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Most common D3 evidence blockers.'
    FROM dbo.silver_d3_likely_object_lineage_object_queue
    GROUP BY hardening_issue_types
    ORDER BY COUNT(*) DESC, LOWER(hardening_issue_types) ASC

    UNION ALL
    SELECT 'priority_band_objects', priority_band, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D3 object rows grouped by priority band.'
    FROM dbo.silver_d3_likely_object_lineage_object_queue GROUP BY priority_band
) s;

END
