-- Warehouse-native translation of backend/scripts/41_build_d3_closure_control.ps1
-- (SQL migration). Reads dbo.bronze_d3_likely_object_lineage_object_queue
-- (the biggest D-family input so far) and
-- dbo.bronze_d3_likely_object_lineage_item_queue.
--
-- Three levels, unlike D1 (one level) and D2 (two levels): per-object-row
-- control rows, per-item review batches, and per-source-object cross-item
-- review targets -- each with its own grouping and its own "value=count;
-- value=count" style aggregation (Get-GroupCounts in the original).
-- Every such aggregation gets its OWN isolated CTE chain (never combined
-- with a different-ordered STRING_AGG in the same GROUP BY) -- Fabric
-- Warehouse rejects that combination (confirmed live building D2).
CREATE OR ALTER PROCEDURE dbo.sp_build_d3_closure_control
AS
BEGIN

IF OBJECT_ID('tempdb..#d3_objects') IS NOT NULL DROP TABLE #d3_objects;
IF OBJECT_ID('tempdb..#d3_source_targets') IS NOT NULL DROP TABLE #d3_source_targets;
IF OBJECT_ID('tempdb..#d3_items') IS NOT NULL DROP TABLE #d3_items;
IF OBJECT_ID('dbo.silver_d3_closure_control_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d3_closure_control_queue;
IF OBJECT_ID('dbo.silver_d3_item_closure_control_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d3_item_closure_control_queue;
IF OBJECT_ID('dbo.silver_d3_source_object_review_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d3_source_object_review_targets;
IF OBJECT_ID('dbo.silver_d3_lineage_decision_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d3_lineage_decision_template;
IF OBJECT_ID('dbo.silver_d3_external_readonly_action_plan', 'U') IS NOT NULL DROP TABLE dbo.silver_d3_external_readonly_action_plan;
IF OBJECT_ID('dbo.silver_d3_closure_control_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d3_closure_control_summary;

SELECT
    o.*,
    LOWER(LTRIM(RTRIM(o.item_qualified_name))) AS item_key,
    LOWER(LTRIM(RTRIM(o.operation_type))) + '|' + LOWER(LTRIM(RTRIM(
        CASE WHEN o.object_key <> '' THEN o.object_key
             ELSE o.source_type + '|' + o.source_server + '|' + o.source_database + '|' + o.schema_name + '|' + o.object_name END
    ))) AS source_key
INTO #d3_objects
FROM dbo.bronze_d3_likely_object_lineage_object_queue o;

-- Source-object review targets (D3S) -----------------------------------
;WITH grp AS (
    SELECT source_key, MAX(ISNULL(TRY_CAST(priority_score AS FLOAT), 0)) AS max_priority, COUNT(*) AS row_count
    FROM #d3_objects GROUP BY source_key
),
first_row AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY source_key ORDER BY (SELECT NULL)) AS rn FROM #d3_objects
),
-- Every GroupCounts-style aggregation caps at the 30 most frequent
-- (value, count) pairs before STRING_AGG runs: Fabric Warehouse's
-- STRING_AGG hard-errors past 8000 bytes rather than truncating (real
-- error on a source-object group with many distinct
-- hardening_issue_types combinations), so truncation has to happen on the
-- INPUT row count, not on the aggregated string afterward. 30 is well
-- past what the original's 700/900-char Limit-Text would keep anyway for
-- all but pathological groups.
item_counts AS (
    SELECT source_key, item_type AS val, COUNT(*) AS cnt FROM #d3_objects WHERE item_type <> '' GROUP BY source_key, item_type
),
item_counts_capped AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY source_key ORDER BY cnt DESC, val) AS crn FROM item_counts
),
item_split AS (
    SELECT source_key, STRING_AGG(val + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY cnt DESC, val) AS item_type_split
    FROM item_counts_capped WHERE crn <= 30 GROUP BY source_key
),
conf_counts AS (
    SELECT source_key, lineage_confidence AS val, COUNT(*) AS cnt FROM #d3_objects WHERE lineage_confidence <> '' GROUP BY source_key, lineage_confidence
),
conf_counts_capped AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY source_key ORDER BY cnt DESC, val) AS crn FROM conf_counts
),
conf_split AS (
    SELECT source_key, STRING_AGG(val + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY cnt DESC, val) AS lineage_confidence_split
    FROM conf_counts_capped WHERE crn <= 30 GROUP BY source_key
),
issue_counts AS (
    SELECT source_key, hardening_issue_types AS val, COUNT(*) AS cnt FROM #d3_objects WHERE hardening_issue_types <> '' GROUP BY source_key, hardening_issue_types
),
issue_counts_capped AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY source_key ORDER BY cnt DESC, val) AS crn FROM issue_counts
),
issue_split AS (
    SELECT source_key, STRING_AGG(val + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY cnt DESC, val) AS hardening_issue_types
    FROM issue_counts_capped WHERE crn <= 30 GROUP BY source_key
),
item_names_distinct AS (
    SELECT DISTINCT source_key, item_qualified_name FROM #d3_objects WHERE item_qualified_name <> ''
),
item_names_ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY source_key ORDER BY item_qualified_name) AS rn FROM item_names_distinct
),
sample_items_agg AS (
    SELECT source_key, STRING_AGG(item_qualified_name, '; ') WITHIN GROUP (ORDER BY item_qualified_name) AS sample_items
    FROM item_names_ranked WHERE rn <= 12 GROUP BY source_key
)
SELECT
    'D3S' + RIGHT('0000' + CAST(ROW_NUMBER() OVER (ORDER BY g.max_priority DESC, g.row_count DESC, g.source_key) AS VARCHAR(10)), 4) AS source_review_target_id,
    g.source_key,
    CAST(g.max_priority AS INT) AS priority_score,
    CASE WHEN g.max_priority >= 1000 THEN 'critical' WHEN g.max_priority >= 250 THEN 'high' WHEN g.max_priority >= 100 THEN 'medium' ELSE 'low' END AS priority_band,
    g.row_count,
    (SELECT COUNT(DISTINCT item_qualified_name) FROM #d3_objects o2 WHERE o2.source_key = g.source_key AND o2.item_qualified_name <> '') AS impacted_item_count,
    fr.operation_type, fr.source_type, fr.source_server, fr.source_database, fr.schema_name,
    fr.object_name, fr.object_display_name, fr.object_key, fr.object_type AS current_object_type, fr.object_type_status,
    ISNULL(isp.item_type_split, '') AS item_type_split,
    ISNULL(cs.lineage_confidence_split, '') AS lineage_confidence_split,
    CASE WHEN LEN(ISNULL(iss.hardening_issue_types,'')) > 700 THEN LEFT(iss.hardening_issue_types, 697) + '...' ELSE ISNULL(iss.hardening_issue_types,'') END AS hardening_issue_types,
    CASE WHEN LEN(ISNULL(si.sample_items,'')) > 1200 THEN LEFT(si.sample_items, 1197) + '...' ELSE ISNULL(si.sample_items,'') END AS sample_items,
    '' AS proposed_status,
    'confirmed; rejected; access_denied; not_available; dynamic_reference; manual_review_required' AS allowed_statuses,
    '' AS confirmation_source, '' AS confirmation_evidence, '' AS reviewer, '' AS reviewed_at,
    'Cross-item source-object target. Use this to batch owner/catalog review; row-level item decisions still live in the D3 decision template.' AS notes
INTO #d3_source_targets
FROM grp g
JOIN first_row fr ON fr.source_key = g.source_key AND fr.rn = 1
LEFT JOIN item_split isp ON isp.source_key = g.source_key
LEFT JOIN conf_split cs ON cs.source_key = g.source_key
LEFT JOIN issue_split iss ON iss.source_key = g.source_key
LEFT JOIN sample_items_agg si ON si.source_key = g.source_key;

SELECT
    source_review_target_id, priority_score, priority_band, row_count, impacted_item_count,
    operation_type, source_type, source_server, source_database, schema_name, object_name,
    object_display_name, object_key, current_object_type, object_type_status,
    item_type_split, lineage_confidence_split, hardening_issue_types, sample_items,
    proposed_status, allowed_statuses, confirmation_source, confirmation_evidence,
    reviewer, reviewed_at, notes
INTO dbo.silver_d3_source_object_review_targets
FROM #d3_source_targets;

-- Item-level review batches (D3I) ---------------------------------------
;WITH items AS (
    SELECT it.*, LOWER(LTRIM(RTRIM(it.item_qualified_name))) AS item_key
    FROM dbo.bronze_d3_likely_object_lineage_item_queue it
),
item_priority AS (
    SELECT i.item_key, i.item_qualified_name, i.item_type, i.workspace_name, i.workspace_environment, i.item_name,
        CASE WHEN ISNULL(TRY_CAST(i.priority_score AS FLOAT), 0) = 0 AND EXISTS (SELECT 1 FROM #d3_objects o WHERE o.item_key = i.item_key)
             THEN ISNULL((SELECT MAX(TRY_CAST(o2.priority_score AS FLOAT)) FROM #d3_objects o2 WHERE o2.item_key = i.item_key), 0)
             ELSE ISNULL(TRY_CAST(i.priority_score AS FLOAT), 0)
        END AS priority_score
    FROM items i
),
row_counts AS (
    SELECT item_key, COUNT(*) AS likely_object_lineage_row_count FROM #d3_objects GROUP BY item_key
),
op_counts AS (SELECT item_key, operation_type AS val, COUNT(*) AS cnt FROM #d3_objects WHERE operation_type <> '' GROUP BY item_key, operation_type),
op_counts_capped AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY cnt DESC, val) AS crn FROM op_counts),
op_split AS (SELECT item_key, STRING_AGG(val + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY cnt DESC, val) AS operation_split FROM op_counts_capped WHERE crn <= 30 GROUP BY item_key),
st_counts AS (SELECT item_key, source_type AS val, COUNT(*) AS cnt FROM #d3_objects WHERE source_type <> '' GROUP BY item_key, source_type),
st_counts_capped AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY cnt DESC, val) AS crn FROM st_counts),
st_split AS (SELECT item_key, STRING_AGG(val + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY cnt DESC, val) AS source_type_split FROM st_counts_capped WHERE crn <= 30 GROUP BY item_key),
ots_counts AS (SELECT item_key, object_type_status AS val, COUNT(*) AS cnt FROM #d3_objects WHERE object_type_status <> '' GROUP BY item_key, object_type_status),
ots_counts_capped AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY cnt DESC, val) AS crn FROM ots_counts),
ots_split AS (SELECT item_key, STRING_AGG(val + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY cnt DESC, val) AS object_type_status_split FROM ots_counts_capped WHERE crn <= 30 GROUP BY item_key),
issue_counts2 AS (SELECT item_key, hardening_issue_types AS val, COUNT(*) AS cnt FROM #d3_objects WHERE hardening_issue_types <> '' GROUP BY item_key, hardening_issue_types),
issue_counts2_capped AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY cnt DESC, val) AS crn FROM issue_counts2),
issue_split2 AS (SELECT item_key, STRING_AGG(val + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY cnt DESC, val) AS hardening_issue_types FROM issue_counts2_capped WHERE crn <= 30 GROUP BY item_key),
target_ids_distinct AS (
    SELECT DISTINCT o.item_key, st.source_review_target_id
    FROM #d3_objects o JOIN #d3_source_targets st ON st.source_key = o.source_key
),
-- True count comes from the UNCAPPED distinct set (an item can genuinely
-- reference hundreds of source targets, e.g. one DataPipeline with over
-- a thousand object rows) -- only the STRING_AGG'd display string is capped at 12,
-- same as sample_items/sample_objects below. Missing this cap here (while
-- having it everywhere else) was the actual cause of the first STRING_AGG
-- 8000-byte overflow, not the hardening_issue_types groups.
target_ids_count AS (SELECT item_key, COUNT(*) AS source_review_target_count FROM target_ids_distinct GROUP BY item_key),
target_ids_ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY source_review_target_id) AS rn FROM target_ids_distinct),
target_ids_display AS (SELECT item_key, STRING_AGG(source_review_target_id, '; ') WITHIN GROUP (ORDER BY source_review_target_id) AS source_review_target_ids FROM target_ids_ranked WHERE rn <= 12 GROUP BY item_key),
target_ids_agg AS (SELECT c.item_key, d.source_review_target_ids, c.source_review_target_count FROM target_ids_count c LEFT JOIN target_ids_display d ON d.item_key = c.item_key),
obj_names_distinct AS (SELECT DISTINCT item_key, object_display_name FROM #d3_objects WHERE object_display_name <> ''),
obj_names_ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY object_display_name) AS rn FROM obj_names_distinct),
sample_objects_agg AS (SELECT item_key, STRING_AGG(object_display_name, '; ') WITHIN GROUP (ORDER BY object_display_name) AS sample_objects FROM obj_names_ranked WHERE rn <= 12 GROUP BY item_key)
SELECT
    'D3I' + RIGHT('0000' + CAST(ROW_NUMBER() OVER (ORDER BY ip.priority_score DESC, ip.item_qualified_name) AS VARCHAR(10)), 4) AS item_review_id,
    CAST(ip.priority_score AS INT) AS priority_score,
    CASE WHEN ip.priority_score >= 1000 THEN 'critical' WHEN ip.priority_score >= 250 THEN 'high' WHEN ip.priority_score >= 100 THEN 'medium' ELSE 'low' END AS priority_band,
    CASE ip.item_type
        WHEN 'SemanticModel' THEN 'semantic_model_source_mapping_review'
        WHEN 'Notebook' THEN 'notebook_code_reference_review'
        WHEN 'CopyJob' THEN 'copyjob_source_sink_mapping_review'
        WHEN 'DataPipeline' THEN 'pipeline_inherited_lineage_review'
        ELSE CASE WHEN ISNULL(isp2.hardening_issue_types, '') LIKE '%weak_object_lineage_confidence%' OR ISNULL(isp2.hardening_issue_types, '') LIKE '%weak_lineage%' THEN 'manual_lineage_review_required' ELSE 'manual_review_required' END
    END AS closure_opportunity,
    ip.workspace_name, ip.workspace_environment, ip.item_type, ip.item_name, ip.item_qualified_name,
    ISNULL(rc.likely_object_lineage_row_count, 0) AS likely_object_lineage_row_count,
    ISNULL(ta.source_review_target_count, 0) AS source_review_target_count,
    ISNULL(ops.operation_split, '') AS operation_split,
    ISNULL(sts.source_type_split, '') AS source_type_split,
    ISNULL(otss.object_type_status_split, '') AS object_type_status_split,
    CASE WHEN LEN(ISNULL(isp2.hardening_issue_types,'')) > 900 THEN LEFT(isp2.hardening_issue_types, 897) + '...' ELSE ISNULL(isp2.hardening_issue_types,'') END AS hardening_issue_types,
    CASE WHEN LEN(ISNULL(ta.source_review_target_ids,'')) > 1200 THEN LEFT(ta.source_review_target_ids, 1197) + '...' ELSE ISNULL(ta.source_review_target_ids,'') END AS source_review_target_ids,
    CASE WHEN LEN(ISNULL(so.sample_objects,'')) > 1200 THEN LEFT(so.sample_objects, 1197) + '...' ELSE ISNULL(so.sample_objects,'') END AS sample_objects,
    CASE
        WHEN ip.item_type = 'SemanticModel' THEN 'Confirm the model source from TMDL, Power Query/M, partitions, model expressions, or owner-approved mapping.'
        WHEN ip.item_type = 'Notebook' THEN 'Confirm the object reference from notebook code, SQL cells, Spark read/write calls, default lakehouse metadata, Azure DevOps, or owner evidence.'
        WHEN ip.item_type = 'CopyJob' THEN 'Confirm CopyJob source/sink mapping from the generated definition, connection metadata, or owner-approved mapping.'
        WHEN ip.item_type = 'DataPipeline' THEN 'Confirm whether the pipeline row is inherited from invoked child lineage or a direct pipeline source/sink; then close explicitly.'
        ELSE 'Review manually and close with confirmed, rejected, access_denied, not_available, dynamic_reference, or manual_review_required.'
    END AS recommended_d3_decision,
    'yes' AS needs_external_readonly,
    'analysis/d3_lineage_decision_template.csv' AS decision_template_path,
    CASE
        WHEN ip.item_type = 'SemanticModel' THEN 'Read semantic model definition/TMDL and validate all likely source-object rows for this model before recording decisions.'
        WHEN ip.item_type = 'Notebook' THEN 'Read notebook code and validate all likely object references and operations for this notebook.'
        WHEN ip.item_type = 'CopyJob' THEN 'Read CopyJob definition and validate source/sink object mappings and operations.'
        WHEN ip.item_type = 'DataPipeline' THEN 'Read pipeline activities and invoked item lineage; validate whether object rows are direct, inherited, or unsupported.'
        ELSE 'Read the item definition or owner-approved evidence and record decisions in the D3 template.'
    END AS human_readonly_action
INTO #d3_items
FROM item_priority ip
LEFT JOIN row_counts rc ON rc.item_key = ip.item_key
LEFT JOIN op_split ops ON ops.item_key = ip.item_key
LEFT JOIN st_split sts ON sts.item_key = ip.item_key
LEFT JOIN ots_split otss ON otss.item_key = ip.item_key
LEFT JOIN issue_split2 isp2 ON isp2.item_key = ip.item_key
LEFT JOIN target_ids_agg ta ON ta.item_key = ip.item_key
LEFT JOIN sample_objects_agg so ON so.item_key = ip.item_key;

SELECT
    item_review_id, priority_score, priority_band, closure_opportunity, workspace_name,
    workspace_environment, item_type, item_name, item_qualified_name,
    likely_object_lineage_row_count, source_review_target_count, operation_split,
    source_type_split, object_type_status_split, hardening_issue_types,
    source_review_target_ids, sample_objects, recommended_d3_decision,
    needs_external_readonly, decision_template_path
INTO dbo.silver_d3_item_closure_control_queue
FROM #d3_items;

SELECT
    item_review_id, priority_score, priority_band, closure_opportunity, workspace_name,
    workspace_environment, item_type, item_name, item_qualified_name,
    likely_object_lineage_row_count, source_review_target_count, human_readonly_action,
    decision_template_path,
    'Read-only/manual D3 action. Do not modify Fabric or evidence indexes from this package alone.' AS notes
INTO dbo.silver_d3_external_readonly_action_plan
FROM #d3_items;

-- Row-level control + decision rows (D3C) --------------------------------
;WITH ranked AS (
    SELECT o.*, ROW_NUMBER() OVER (ORDER BY ISNULL(TRY_CAST(o.priority_score AS FLOAT), 0) DESC, o.row_id) AS rn
    FROM #d3_objects o
)
SELECT
    'D3C' + RIGHT('000000' + CAST(r.rn AS VARCHAR(10)), 6) AS d3_id,
    ISNULL(st.source_review_target_id, '') AS source_review_target_id,
    r.row_id, r.priority_score, r.priority_band,
    CASE r.item_type
        WHEN 'SemanticModel' THEN 'semantic_model_source_mapping_review'
        WHEN 'Notebook' THEN 'notebook_code_reference_review'
        WHEN 'CopyJob' THEN 'copyjob_source_sink_mapping_review'
        WHEN 'DataPipeline' THEN 'pipeline_inherited_lineage_review'
        ELSE CASE WHEN r.hardening_issue_types LIKE '%weak_object_lineage_confidence%' OR r.hardening_issue_types LIKE '%weak_lineage%' THEN 'manual_lineage_review_required' ELSE 'manual_review_required' END
    END AS closure_opportunity,
    r.workspace_name, r.workspace_environment, r.item_type, r.item_name, r.item_qualified_name,
    r.operation_type, r.source_type, r.source_database, r.schema_name, r.object_name,
    r.object_display_name, r.object_key, r.object_type, r.object_type_status, r.lineage_confidence,
    r.hardening_issue_types,
    CASE WHEN r.object_type_status = 'ambiguous' THEN 'yes' ELSE 'no' END AS also_blocks_d4,
    r.evidence AS current_evidence,
    CASE
        WHEN r.item_type = 'SemanticModel' THEN 'Confirm the model source from TMDL, Power Query/M, partitions, model expressions, or owner-approved mapping.'
        WHEN r.item_type = 'Notebook' THEN 'Confirm the object reference from notebook code, SQL cells, Spark read/write calls, default lakehouse metadata, Azure DevOps, or owner evidence.'
        WHEN r.item_type = 'CopyJob' THEN 'Confirm CopyJob source/sink mapping from the generated definition, connection metadata, or owner-approved mapping.'
        WHEN r.item_type = 'DataPipeline' THEN 'Confirm whether the pipeline row is inherited from invoked child lineage or a direct pipeline source/sink; then close explicitly.'
        ELSE 'Review manually and close with confirmed, rejected, access_denied, not_available, dynamic_reference, or manual_review_required.'
    END AS recommended_d3_decision,
    'analysis/d3_lineage_decision_template.csv' AS decision_template_path
INTO dbo.silver_d3_closure_control_queue
FROM ranked r
LEFT JOIN #d3_source_targets st ON st.source_key = r.source_key;

SELECT
    d3_id, source_review_target_id, row_id, item_qualified_name, item_type, item_name,
    operation_type AS current_operation_type, source_type AS current_source_type,
    '' AS current_source_server, '' AS current_source_database, '' AS current_schema_name,
    '' AS current_object_name, '' AS current_object_display_name, '' AS current_object_type,
    '' AS current_lineage_confidence, closure_opportunity,
    '' AS proposed_status,
    'confirmed; rejected; access_denied; not_available; dynamic_reference; manual_review_required' AS allowed_statuses,
    operation_type AS confirmed_operation_type,
    '' AS confirmed_source_type, '' AS confirmed_source_server, '' AS confirmed_source_database,
    '' AS confirmed_schema_name, '' AS confirmed_object_name, '' AS confirmed_object_type,
    '' AS confirmation_source, '' AS confirmation_evidence, '' AS reviewer, '' AS reviewed_at,
    CASE WHEN also_blocks_d4 = 'yes' THEN 'D4 exact object type remains required if lineage is confirmed.' ELSE '' END AS next_gate,
    'Fill this row before treating D3 as closed for this object lineage. Do not use likely lineage as a hard orchestration rule.' AS notes
INTO dbo.silver_d3_lineage_decision_template
FROM dbo.silver_d3_closure_control_queue;

SELECT summary_scope, group_key, row_count, notes INTO dbo.silver_d3_closure_control_summary FROM (
    SELECT 'total' AS summary_scope, 'D3 closure control rows' AS group_key, COUNT(*) AS row_count, 'One row per likely object-level lineage row.' AS notes FROM dbo.silver_d3_closure_control_queue
    UNION ALL
    SELECT 'total', 'D3 item review targets', COUNT(*), 'One read-only/manual review batch per impacted item.' FROM dbo.silver_d3_item_closure_control_queue
    UNION ALL
    SELECT 'total', 'D3 source-object review targets', COUNT(*), 'Cross-item source object plus operation review targets.' FROM dbo.silver_d3_source_object_review_targets
    UNION ALL
    SELECT 'total', 'D3 decision rows', COUNT(*), 'One decision row per likely object-level lineage row.' FROM dbo.silver_d3_lineage_decision_template
    UNION ALL
    SELECT 'total', 'External read-only action rows', COUNT(*), 'One read-only/manual action per item review target.' FROM dbo.silver_d3_external_readonly_action_plan
    UNION ALL
    SELECT 'closure_opportunity', closure_opportunity, COUNT(*), 'D3 rows grouped by closure path.' FROM dbo.silver_d3_closure_control_queue GROUP BY closure_opportunity
    UNION ALL
    SELECT 'operation_type', operation_type, COUNT(*), 'D3 rows grouped by operation type.' FROM dbo.silver_d3_closure_control_queue GROUP BY operation_type
    UNION ALL
    SELECT 'item_type', item_type, COUNT(*), 'D3 rows grouped by item type.' FROM dbo.silver_d3_closure_control_queue GROUP BY item_type
    UNION ALL
    SELECT 'also_blocks_d4', also_blocks_d4, COUNT(*), 'D3 rows that still need exact object-type cleanup if lineage is confirmed.' FROM dbo.silver_d3_closure_control_queue GROUP BY also_blocks_d4
) x;

DROP TABLE #d3_objects;
DROP TABLE #d3_source_targets;
DROP TABLE #d3_items;

END
