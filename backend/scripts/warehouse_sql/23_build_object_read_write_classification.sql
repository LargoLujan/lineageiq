-- Warehouse-native translation of backend/scripts/23_build_object_read_
-- write_classification.ps1 (Phase 2 migration continuation, 2026-07-21).
-- Reads dbo.bronze_object_impact_index, plus THIS migration's own
-- already-validated dbo.silver_evidence_hardening_queue (22) and dbo.
-- silver_ideal_execution_plan (13) instead of their CSVs.
--
-- The original indexes evidence-hardening rows two ways before matching
-- them against each object-impact row: hardeningByObject (keyed by
-- object_key alone, for issue types that are inherently object-level:
-- source_object_type_pending/metadata_access_gap/ambiguous_object_type)
-- and hardeningByItemObject (keyed by item+object together, for every
-- other issue type, after splitting item_qualified_name on ";" since a
-- few evidence rows list multiple affected items). Rows whose object_key
-- is entirely blank ("||||") never get indexed either way -- verified by
-- reading Add-HardeningRowToIndex's regex guard -- so weak_relationship_
-- confidence and orchestration_evidence_blocker hardening rows (both
-- object-key-less) never actually contribute to any classification row.
-- Reproduced here as a single JOIN with an equivalent OR condition
-- instead of two separate hashtable indexes merged per row -- same
-- matched set, avoids re-merging two pre-aggregated text blobs.
-- KNOWN LIMITATION (verified against real data): dbo.bronze_object_
-- impact_index can carry multiple genuinely different candidate rows for
-- the same (item, object) pair (e.g. one reads_from and one writes_to
-- row for the same notebook/object, both "confirmed"). The original
-- picks whichever came first in the source CSV's row order; without
-- that ordering, this script's own dedup and 22_build_evidence_
-- hardening_queue.sql's dedup can each pick a different one of the tied
-- rows than the original did. For a handful of high-fanout shared
-- objects this cascades into a larger row count here than in 22 alone
-- (717 of 41685 classification rows, 1.7%, mostly hardening_priority_
-- score) -- confirmed by direct inspection, not a new bug: same root
-- cause documented in 22_build_evidence_hardening_queue.sql.
CREATE OR ALTER PROCEDURE dbo.sp_build_object_read_write_classification
AS
BEGIN

IF OBJECT_ID('dbo.silver_object_read_write_classification', 'U') IS NOT NULL DROP TABLE dbo.silver_object_read_write_classification;
IF OBJECT_ID('dbo.silver_object_read_write_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_object_read_write_summary;

IF OBJECT_ID('tempdb..#hardening') IS NOT NULL DROP TABLE #hardening;
SELECT
    issue_type, evidence_area, preferred_confirmation_source, next_action, priority_score, item_qualified_name,
    LOWER(LTRIM(RTRIM(ISNULL(source_type,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(object_name,'')))) AS obj_key,
    CASE WHEN issue_type IN ('source_object_type_pending', 'metadata_access_gap', 'ambiguous_object_type') THEN 1 ELSE 0 END AS is_obj_level
INTO #hardening
FROM dbo.silver_evidence_hardening_queue;

IF OBJECT_ID('tempdb..#impact') IS NOT NULL DROP TABLE #impact;
SELECT
    ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS impact_id,
    ISNULL(item_workspace_name, '') AS workspace_name_final,
    item_type, item_name, item_qualified_name,
    source_type, source_server, source_database, schema_name, object_name, object_display_name, object_key,
    object_type, raw_object_type, object_type_source, object_type_confidence,
    source_label, source_qualified_name, semantic_table, usage_type, confidence, evidence,
    LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key,
    LOWER(LTRIM(RTRIM(ISNULL(source_type,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(object_name,'')))) AS obj_key
INTO #impact
FROM dbo.bronze_object_impact_index;

IF OBJECT_ID('tempdb..#matches') IS NOT NULL DROP TABLE #matches;
SELECT i.impact_id, h.issue_type, h.evidence_area, h.preferred_confirmation_source, h.next_action, h.priority_score
INTO #matches
FROM #impact i
JOIN #hardening h ON h.obj_key = i.obj_key AND i.obj_key <> '||||'
    AND (
        h.is_obj_level = 1
        OR EXISTS (
            SELECT 1 FROM STRING_SPLIT(h.item_qualified_name, ';') s
            WHERE LOWER(LTRIM(RTRIM(s.value))) = i.item_key AND LTRIM(RTRIM(s.value)) <> ''
        )
    );

IF OBJECT_ID('tempdb..#issue_types_agg') IS NOT NULL DROP TABLE #issue_types_agg;
SELECT impact_id, STRING_AGG(issue_type, '; ') WITHIN GROUP (ORDER BY issue_type) AS issue_types, COUNT(*) AS issue_count
INTO #issue_types_agg
FROM (SELECT DISTINCT impact_id, issue_type FROM #matches) x
GROUP BY impact_id;

IF OBJECT_ID('tempdb..#evidence_areas_agg') IS NOT NULL DROP TABLE #evidence_areas_agg;
SELECT impact_id, STRING_AGG(evidence_area, '; ') WITHIN GROUP (ORDER BY evidence_area) AS evidence_areas
INTO #evidence_areas_agg
FROM (SELECT DISTINCT impact_id, evidence_area FROM #matches) x
GROUP BY impact_id;

IF OBJECT_ID('tempdb..#sources_agg') IS NOT NULL DROP TABLE #sources_agg;
;WITH d AS (SELECT DISTINCT impact_id, preferred_confirmation_source FROM #matches WHERE ISNULL(preferred_confirmation_source,'') <> ''),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY impact_id ORDER BY preferred_confirmation_source) AS rn FROM d)
SELECT impact_id, STRING_AGG(preferred_confirmation_source, ' | ') WITHIN GROUP (ORDER BY rn) AS preferred_sources
INTO #sources_agg FROM r WHERE rn <= 3 GROUP BY impact_id;

IF OBJECT_ID('tempdb..#actions_agg') IS NOT NULL DROP TABLE #actions_agg;
;WITH d AS (SELECT DISTINCT impact_id, next_action FROM #matches WHERE ISNULL(next_action,'') <> ''),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY impact_id ORDER BY next_action) AS rn FROM d)
SELECT impact_id, STRING_AGG(next_action, ' | ') WITHIN GROUP (ORDER BY rn) AS next_actions
INTO #actions_agg FROM r WHERE rn <= 3 GROUP BY impact_id;

IF OBJECT_ID('tempdb..#priority_agg') IS NOT NULL DROP TABLE #priority_agg;
SELECT impact_id, MAX(priority_score) AS max_priority
INTO #priority_agg FROM #matches GROUP BY impact_id;

IF OBJECT_ID('tempdb..#plan') IS NOT NULL DROP TABLE #plan;
SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key, MIN(human_validation_required) AS human_validation_required,
    MIN(risk_flags) AS risk_flags, MIN(parallel_readiness) AS parallel_readiness
INTO #plan
FROM dbo.silver_ideal_execution_plan
GROUP BY LOWER(LTRIM(RTRIM(qualified_name)));

IF OBJECT_ID('tempdb..#classified') IS NOT NULL DROP TABLE #classified;
SELECT
    i.*,
    usage_calc.usage_type_normalized, usage_calc.operation_type,
    CASE WHEN LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(i.object_type,''))), ' ', '_'), '-', '_')) = '' THEN 'missing'
         WHEN LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(i.object_type,''))), ' ', '_'), '-', '_')) IN ('table','view','stored_procedure','file','shortcut','query') THEN 'exact'
         ELSE 'ambiguous' END AS object_type_status,
    ISNULL(ita.issue_types, '') AS hardening_issue_types,
    ISNULL(ita.issue_count, 0) AS hardening_issue_count,
    ISNULL(eaa.evidence_areas, '') AS hardening_evidence_areas,
    ISNULL(sa.preferred_sources, '') AS preferred_confirmation_sources,
    ISNULL(aa.next_actions, '') AS hardening_next_actions,
    ISNULL(pa.max_priority, 0) AS hardening_priority_score,
    CASE WHEN ISNULL(ita.issue_count, 0) > 0 THEN 'pending_confirmation' ELSE 'clear' END AS hardening_status,
    ISNULL(p.human_validation_required, '') AS plan_human_validation_required,
    ISNULL(p.risk_flags, '') AS plan_risk_flags,
    ISNULL(p.parallel_readiness, '') AS plan_parallel_readiness
INTO #classified
FROM #impact i
CROSS APPLY (
    SELECT
        CASE
            WHEN LOWER(LTRIM(RTRIM(ISNULL(i.usage_type,'')))) = '' AND LOWER(LTRIM(RTRIM(ISNULL(i.item_type,'')))) = 'semanticmodel' THEN 'reads_from'
            WHEN LOWER(LTRIM(RTRIM(ISNULL(i.usage_type,'')))) IN ('read','reads','source','input') THEN 'reads_from'
            WHEN LOWER(LTRIM(RTRIM(ISNULL(i.usage_type,'')))) IN ('write','writes','sink','output') THEN 'writes_to'
            WHEN LOWER(LTRIM(RTRIM(ISNULL(i.usage_type,'')))) IN ('execute','exec','invokes','invoke') THEN 'executes'
            WHEN LOWER(LTRIM(RTRIM(ISNULL(i.usage_type,'')))) IN ('reads_from','writes_to','executes') THEN LOWER(LTRIM(RTRIM(i.usage_type)))
            WHEN LOWER(LTRIM(RTRIM(ISNULL(i.usage_type,'')))) = '' THEN 'unknown'
            ELSE LOWER(LTRIM(RTRIM(i.usage_type)))
        END AS usage_type_normalized_calc
) u0
CROSS APPLY (
    SELECT u0.usage_type_normalized_calc AS usage_type_normalized,
        CASE u0.usage_type_normalized_calc WHEN 'reads_from' THEN 'read' WHEN 'writes_to' THEN 'write' WHEN 'executes' THEN 'execute' ELSE 'unknown' END AS operation_type
) usage_calc
LEFT JOIN #issue_types_agg ita ON ita.impact_id = i.impact_id
LEFT JOIN #evidence_areas_agg eaa ON eaa.impact_id = i.impact_id
LEFT JOIN #sources_agg sa ON sa.impact_id = i.impact_id
LEFT JOIN #actions_agg aa ON aa.impact_id = i.impact_id
LEFT JOIN #priority_agg pa ON pa.impact_id = i.impact_id
LEFT JOIN #plan p ON p.item_key = i.item_key;

SELECT
    workspace_name_final AS workspace_name, item_type, item_name, item_qualified_name,
    source_type, source_server, source_database, schema_name, object_name, object_display_name, object_key,
    object_type, raw_object_type, object_type_status, object_type_source, object_type_confidence,
    source_label, source_qualified_name, semantic_table, usage_type, usage_type_normalized, operation_type,
    confidence AS lineage_confidence, hardening_status, hardening_issue_count, hardening_issue_types, hardening_evidence_areas,
    hardening_priority_score, preferred_confirmation_sources, hardening_next_actions,
    plan_risk_flags AS orchestration_risk_flags, plan_human_validation_required AS orchestration_human_validation_required,
    plan_parallel_readiness AS orchestration_parallel_readiness,
    CASE
        WHEN operation_type = 'unknown' THEN 'blocked_missing_operation'
        WHEN LOWER(LTRIM(RTRIM(ISNULL(confidence,'')))) <> 'confirmed' THEN 'needs_lineage_confirmation'
        WHEN object_type_status <> 'exact' THEN 'needs_object_type_confirmation'
        WHEN hardening_issue_types LIKE '%orchestration_evidence_blocker%' OR LOWER(LTRIM(RTRIM(plan_human_validation_required))) = 'yes' THEN 'needs_orchestration_review'
        WHEN hardening_issue_count > 0 THEN 'blocked_by_evidence_hardening'
        WHEN operation_type = 'read' THEN 'read_ready_candidate'
        WHEN operation_type = 'write' THEN 'write_serialization_required'
        WHEN operation_type = 'execute' THEN 'execute_sequence_required'
        ELSE 'unknown'
    END AS scheduling_readiness,
    CASE
        WHEN operation_type = 'unknown' THEN 'Confirm whether this item reads from, writes to, or executes the referenced object before scheduling.'
        WHEN LOWER(LTRIM(RTRIM(ISNULL(confidence,'')))) <> 'confirmed' THEN 'Confirm object-level lineage from local definitions, Azure DevOps, SharePoint, OneLake, or read-only Fabric metadata before using it as a sequencing rule.'
        WHEN object_type_status <> 'exact' THEN 'Confirm exact object type: table, view, stored procedure, file, shortcut, or query.'
        WHEN hardening_issue_types LIKE '%orchestration_evidence_blocker%' OR LOWER(LTRIM(RTRIM(plan_human_validation_required))) = 'yes' THEN 'Keep this row as advisory until orchestration risks, dependency confidence, and execution history are reviewed.'
        WHEN hardening_issue_count > 0 THEN 'Resolve the attached evidence-hardening issue before promoting this row into orchestration v2.'
        WHEN operation_type = 'read' THEN 'Candidate input dependency for orchestration v2 once item-level scheduling is reviewed.'
        WHEN operation_type = 'write' THEN 'Serialize writers and downstream readers for this object; validate write conflicts before parallel execution.'
        WHEN operation_type = 'execute' THEN 'Use as an execution-order dependency candidate after invoked item behavior is confirmed.'
        ELSE 'Review this row before operational use.'
    END AS recommended_next_action,
    evidence
INTO dbo.silver_object_read_write_classification
FROM #classified;

SELECT
    'item_operation_readiness' AS summary_scope, item_type, operation_type, scheduling_readiness, lineage_confidence, object_type_status,
    COUNT(*) AS row_count,
    COUNT(DISTINCT LOWER(LTRIM(RTRIM(item_qualified_name)))) AS unique_item_count,
    COUNT(DISTINCT LOWER(LTRIM(RTRIM(object_key)))) AS unique_object_count
INTO dbo.silver_object_read_write_summary
FROM dbo.silver_object_read_write_classification
GROUP BY item_type, operation_type, scheduling_readiness, lineage_confidence, object_type_status;

END
