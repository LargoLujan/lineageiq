-- Warehouse-native translation of backend/scripts/43_build_d5_closure_control.ps1
-- (Phase 1 migration, 2026-07-21). Reads dbo.bronze_d5_object_conflict_queue,
-- dbo.bronze_d5_object_guard_edge_queue, dbo.bronze_d5_object_conflict_participants,
-- dbo.bronze_d4_exact_object_type_impact_queue, AND
-- dbo.silver_d3_source_object_review_targets -- the first cross-D-phase
-- dependency: this procedure must run AFTER dbo.sp_build_d3_closure_control
-- has populated that silver table at least once.
CREATE OR ALTER PROCEDURE dbo.sp_build_d5_closure_control
AS
BEGIN

IF OBJECT_ID('tempdb..#d5_control') IS NOT NULL DROP TABLE #d5_control;
IF OBJECT_ID('dbo.silver_d5_closure_control_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d5_closure_control_queue;
IF OBJECT_ID('dbo.silver_d5_blocked_by_d3_d4_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d5_blocked_by_d3_d4_queue;
IF OBJECT_ID('dbo.silver_d5_serialization_review_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d5_serialization_review_targets;
IF OBJECT_ID('dbo.silver_d5_guard_edge_decision_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d5_guard_edge_decision_queue;
IF OBJECT_ID('dbo.silver_d5_conflict_participant_review', 'U') IS NOT NULL DROP TABLE dbo.silver_d5_conflict_participant_review;
IF OBJECT_ID('dbo.silver_d5_conflict_resolution_decision_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d5_conflict_resolution_decision_template;
IF OBJECT_ID('dbo.silver_d5_external_readonly_action_plan', 'U') IS NOT NULL DROP TABLE dbo.silver_d5_external_readonly_action_plan;
IF OBJECT_ID('dbo.silver_d5_closure_control_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d5_closure_control_summary;

;WITH d3_ranked AS (
    SELECT
        LOWER(LTRIM(RTRIM(object_key))) + '|' + LOWER(LTRIM(RTRIM(operation_type))) AS target_key,
        source_review_target_id,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(object_key))) + '|' + LOWER(LTRIM(RTRIM(operation_type))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_d3_source_object_review_targets
    WHERE object_key <> ''
)
SELECT target_key, source_review_target_id INTO #d3_lookup FROM d3_ranked WHERE rn = 1;

SELECT DISTINCT LOWER(LTRIM(RTRIM(object_key))) AS object_key_norm, source_id
INTO #d4_lookup
FROM dbo.bronze_d4_exact_object_type_impact_queue
WHERE object_key <> '' AND source_id <> '';

-- Per-conflict aggregates: guard/participant counts and GroupCounts splits
-- (each isolated in its own CTE chain -- see D2/D3 for why).
;WITH guard_agg AS (
    SELECT conflict_id, COUNT(*) AS guard_edge_count FROM dbo.bronze_d5_object_guard_edge_queue GROUP BY conflict_id
),
guard_type_counts AS (SELECT conflict_id, v2_relationship_type AS val, COUNT(*) AS cnt FROM dbo.bronze_d5_object_guard_edge_queue WHERE v2_relationship_type <> '' GROUP BY conflict_id, v2_relationship_type),
guard_type_capped AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY conflict_id ORDER BY cnt DESC, val) AS crn FROM guard_type_counts),
guard_type_split AS (SELECT conflict_id, STRING_AGG(val + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY cnt DESC, val) AS guard_edge_types FROM guard_type_capped WHERE crn <= 30 GROUP BY conflict_id),
part_agg AS (
    SELECT conflict_id, COUNT(*) AS participant_row_count FROM dbo.bronze_d5_object_conflict_participants GROUP BY conflict_id
),
part_op_counts AS (SELECT conflict_id, operation_type AS val, COUNT(*) AS cnt FROM dbo.bronze_d5_object_conflict_participants WHERE operation_type <> '' GROUP BY conflict_id, operation_type),
part_op_capped AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY conflict_id ORDER BY cnt DESC, val) AS crn FROM part_op_counts),
part_op_split AS (SELECT conflict_id, STRING_AGG(val + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY cnt DESC, val) AS participant_operations FROM part_op_capped WHERE crn <= 30 GROUP BY conflict_id),
part_it_counts AS (SELECT conflict_id, item_type AS val, COUNT(*) AS cnt FROM dbo.bronze_d5_object_conflict_participants WHERE item_type <> '' GROUP BY conflict_id, item_type),
part_it_capped AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY conflict_id ORDER BY cnt DESC, val) AS crn FROM part_it_counts),
part_it_split AS (SELECT conflict_id, STRING_AGG(val + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY cnt DESC, val) AS participant_item_types FROM part_it_capped WHERE crn <= 30 GROUP BY conflict_id),
-- d3 targets linked via EACH participant's own (object_key, operation_type)
part_d3 AS (
    SELECT DISTINCT p.conflict_id, l.source_review_target_id
    FROM dbo.bronze_d5_object_conflict_participants p
    JOIN #d3_lookup l ON l.target_key = LOWER(LTRIM(RTRIM(p.object_key))) + '|' + LOWER(LTRIM(RTRIM(p.operation_type)))
),
part_d3_ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY conflict_id ORDER BY source_review_target_id) AS rn FROM part_d3),
part_d3_agg AS (SELECT conflict_id, STRING_AGG(source_review_target_id, '; ') WITHIN GROUP (ORDER BY source_review_target_id) AS linked_d3_source_targets FROM part_d3_ranked WHERE rn <= 30 GROUP BY conflict_id),
-- d4 sources linked via the CONFLICT's own object_key (not participants')
conflict_d4 AS (
    SELECT DISTINCT c.conflict_id, d4.source_id
    FROM dbo.bronze_d5_object_conflict_queue c
    JOIN #d4_lookup d4 ON d4.object_key_norm = LOWER(LTRIM(RTRIM(c.object_key)))
),
conflict_d4_ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY conflict_id ORDER BY source_id) AS rn FROM conflict_d4),
conflict_d4_agg AS (SELECT conflict_id, STRING_AGG(source_id, '; ') WITHIN GROUP (ORDER BY source_id) AS linked_d4_source_ids FROM conflict_d4_ranked WHERE rn <= 30 GROUP BY conflict_id)
SELECT
    c.conflict_id,
    c.priority_score, c.priority_band, c.object_key, c.object_display_name, c.source_types,
    c.object_types, c.reader_count, c.writer_count, c.executor_count, c.exact_row_count,
    c.ambiguous_row_count, c.conflict_types, c.object_readiness, c.decision_readiness,
    ISNULL(ga.guard_edge_count, 0) AS guard_edge_count,
    ISNULL(gts.guard_edge_types, '') AS guard_edge_types,
    ISNULL(pa.participant_row_count, 0) AS participant_row_count,
    ISNULL(pos.participant_operations, '') AS participant_operations,
    ISNULL(pis.participant_item_types, '') AS participant_item_types,
    CASE WHEN LEN(ISNULL(pd3.linked_d3_source_targets,'')) > 1200 THEN LEFT(pd3.linked_d3_source_targets, 1197) + '...' ELSE ISNULL(pd3.linked_d3_source_targets,'') END AS linked_d3_source_targets,
    CASE WHEN LEN(ISNULL(cd4.linked_d4_source_ids,'')) > 700 THEN LEFT(cd4.linked_d4_source_ids, 697) + '...' ELSE ISNULL(cd4.linked_d4_source_ids,'') END AS linked_d4_source_ids,
    CASE c.decision_readiness
        WHEN 'blocked_by_d3_d4_evidence' THEN 'blocked_pending_d3_d4_closure'
        WHEN 'writer_order_review' THEN 'writer_serialization_review_required'
        WHEN 'writer_before_reader_review' THEN 'writer_before_reader_review_required'
        WHEN 'execute_order_review' THEN 'execute_order_review_required'
        ELSE 'manual_conflict_review_required'
    END AS closure_opportunity
INTO #d5_control_raw
FROM dbo.bronze_d5_object_conflict_queue c
LEFT JOIN guard_agg ga ON ga.conflict_id = c.conflict_id
LEFT JOIN guard_type_split gts ON gts.conflict_id = c.conflict_id
LEFT JOIN part_agg pa ON pa.conflict_id = c.conflict_id
LEFT JOIN part_op_split pos ON pos.conflict_id = c.conflict_id
LEFT JOIN part_it_split pis ON pis.conflict_id = c.conflict_id
LEFT JOIN part_d3_agg pd3 ON pd3.conflict_id = c.conflict_id
LEFT JOIN conflict_d4_agg cd4 ON cd4.conflict_id = c.conflict_id;

SELECT
    conflict_id, priority_score, priority_band, closure_opportunity, object_key,
    object_display_name, source_types, object_types, reader_count, writer_count,
    executor_count, exact_row_count, ambiguous_row_count, conflict_types, object_readiness,
    decision_readiness, guard_edge_count, guard_edge_types, participant_row_count,
    participant_operations, participant_item_types, linked_d3_source_targets, linked_d4_source_ids,
    CASE closure_opportunity
        WHEN 'blocked_pending_d3_d4_closure' THEN 'Keep guard edges blocked until D3 lineage and D4 exact type are confirmed or explicitly accepted.'
        WHEN 'writer_serialization_review_required' THEN 'Review writers and decide serialize_writers, partitioned_writes_safe_parallel, false_conflict, or blocked.'
        WHEN 'writer_before_reader_review_required' THEN 'Review reader/writer timing and decide writer_before_reader, safe_parallel_readers_after_writer, false_conflict, or blocked.'
        WHEN 'execute_order_review_required' THEN 'Review execute dependencies and decide execute_after_writers, confirm_invocation_dependency, false_conflict, or blocked.'
        ELSE 'Review participants and guard edges manually before selecting a conflict decision.'
    END AS recommended_d5_decision,
    CASE closure_opportunity
        WHEN 'blocked_pending_d3_d4_closure' THEN 'Review linked D3/D4 targets; do not decide serialization until object lineage and exact type evidence are closed or explicitly accepted.'
        WHEN 'writer_serialization_review_required' THEN 'Inspect writer item definitions, target partitions, full/incremental behavior, and run history to decide writer serialization.'
        WHEN 'writer_before_reader_review_required' THEN 'Inspect reader dependencies and writer completion timing to decide writer-before-reader guard rules.'
        WHEN 'execute_order_review_required' THEN 'Inspect execute/invocation definitions and whether execution already implies the required ordering.'
        ELSE 'Review participants, guards, definitions, execution evidence, and owner evidence before selecting the conflict decision.'
    END AS readonly_action,
    'analysis/d5_conflict_resolution_decision_template.csv' AS decision_template_path
INTO #d5_control
FROM #d5_control_raw;

SELECT * INTO dbo.silver_d5_closure_control_queue FROM #d5_control;
SELECT * INTO dbo.silver_d5_blocked_by_d3_d4_queue FROM #d5_control WHERE closure_opportunity = 'blocked_pending_d3_d4_closure';
SELECT * INTO dbo.silver_d5_serialization_review_targets FROM #d5_control WHERE closure_opportunity <> 'blocked_pending_d3_d4_closure';

SELECT
    g.guard_id, g.conflict_id, ISNULL(ctl.closure_opportunity, '') AS closure_opportunity,
    g.object_key, g.upstream_qualified_name, g.downstream_qualified_name, g.v2_relationship_type,
    g.edge_status, g.confidence,
    '' AS proposed_guard_action,
    'keep_guard; modify_guard; remove_false_conflict_guard; blocked_pending_d3_d4; manual_review_required' AS allowed_guard_actions,
    'analysis/d5_conflict_resolution_decision_template.csv' AS decision_template_path,
    'Guard edge action must follow the conflict-level D5 decision.' AS notes
INTO dbo.silver_d5_guard_edge_decision_queue
FROM dbo.bronze_d5_object_guard_edge_queue g
LEFT JOIN #d5_control ctl ON ctl.conflict_id = g.conflict_id;

;WITH p_d3 AS (
    SELECT p.participant_id, l.source_review_target_id
    FROM dbo.bronze_d5_object_conflict_participants p
    JOIN #d3_lookup l ON l.target_key = LOWER(LTRIM(RTRIM(p.object_key))) + '|' + LOWER(LTRIM(RTRIM(p.operation_type)))
),
p_d3_first AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY participant_id ORDER BY (SELECT NULL)) AS rn FROM p_d3),
p_d4 AS (
    SELECT DISTINCT p.participant_id, d4.source_id
    FROM dbo.bronze_d5_object_conflict_participants p
    JOIN #d4_lookup d4 ON d4.object_key_norm = LOWER(LTRIM(RTRIM(p.object_key)))
),
p_d4_ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY participant_id ORDER BY source_id) AS rn FROM p_d4),
p_d4_agg AS (SELECT participant_id, STRING_AGG(source_id, '; ') WITHIN GROUP (ORDER BY source_id) AS linked_d4_source_ids FROM p_d4_ranked WHERE rn <= 30 GROUP BY participant_id)
SELECT
    p.participant_id, p.conflict_id, p.object_key, p.object_display_name, p.item_qualified_name,
    p.item_type, p.operation_type, p.object_type, p.object_type_status, p.lineage_confidence,
    p.scheduling_readiness, p.orchestration_parallel_readiness,
    ISNULL(pd3.source_review_target_id, '') AS linked_d3_source_target,
    CASE WHEN LEN(ISNULL(pd4.linked_d4_source_ids,'')) > 700 THEN LEFT(pd4.linked_d4_source_ids, 697) + '...' ELSE ISNULL(pd4.linked_d4_source_ids,'') END AS linked_d4_source_ids,
    p.evidence
INTO dbo.silver_d5_conflict_participant_review
FROM dbo.bronze_d5_object_conflict_participants p
LEFT JOIN p_d3_first pd3 ON pd3.participant_id = p.participant_id AND pd3.rn = 1
LEFT JOIN p_d4_agg pd4 ON pd4.participant_id = p.participant_id;

SELECT
    conflict_id, object_key, object_display_name, closure_opportunity, conflict_types,
    object_readiness, decision_readiness,
    '' AS proposed_decision,
    'blocked_pending_d3_d4; serialize_writers; writer_before_reader; execute_after_writers; safe_parallel_partitioned; false_conflict; manual_review_required' AS allowed_decisions,
    '' AS proposed_writer_order, '' AS proposed_reader_rule, '' AS proposed_execute_rule,
    '' AS safe_parallel_groups, '' AS blocked_reason,
    '' AS confirmation_source, '' AS confirmation_evidence, '' AS reviewer, '' AS reviewed_at,
    recommended_d5_decision AS next_action,
    'Fill this row before treating D5 as closed. Do not relax guard edges or promote parallelism without D3/D4 evidence and a reviewed decision.' AS notes
INTO dbo.silver_d5_conflict_resolution_decision_template
FROM #d5_control;

SELECT
    conflict_id, priority_score, priority_band, closure_opportunity, object_display_name,
    conflict_types, object_readiness, decision_readiness,
    readonly_action AS human_readonly_action, linked_d3_source_targets, linked_d4_source_ids,
    'analysis/d5_conflict_resolution_decision_template.csv' AS decision_template_path,
    'Read-only/manual D5 action. Do not update schedules, guard edges, or orchestration rules from this package alone.' AS notes
INTO dbo.silver_d5_external_readonly_action_plan
FROM #d5_control;

SELECT summary_scope, group_key, row_count, notes INTO dbo.silver_d5_closure_control_summary FROM (
    SELECT 'total' AS summary_scope, 'D5 closure control rows' AS group_key, COUNT(*) AS row_count, 'One row per object conflict.' AS notes FROM dbo.silver_d5_closure_control_queue
    UNION ALL
    SELECT 'total', 'Blocked by D3/D4 rows', COUNT(*), 'Conflicts not ready for serialization decisions until evidence closes.' FROM dbo.silver_d5_blocked_by_d3_d4_queue
    UNION ALL
    SELECT 'total', 'Serialization review targets', COUNT(*), 'Conflicts ready for D5 ordering/parallelism review.' FROM dbo.silver_d5_serialization_review_targets
    UNION ALL
    SELECT 'total', 'Guard edge decision rows', COUNT(*), 'One row per object guard edge.' FROM dbo.silver_d5_guard_edge_decision_queue
    UNION ALL
    SELECT 'total', 'Participant review rows', COUNT(*), 'One row per conflict participant.' FROM dbo.silver_d5_conflict_participant_review
    UNION ALL
    SELECT 'total', 'D5 decision rows', COUNT(*), 'One decision row per conflict.' FROM dbo.silver_d5_conflict_resolution_decision_template
    UNION ALL
    SELECT 'total', 'External read-only action rows', COUNT(*), 'One read-only/manual action per conflict.' FROM dbo.silver_d5_external_readonly_action_plan
    UNION ALL
    SELECT 'closure_opportunity', closure_opportunity, COUNT(*), 'D5 conflicts grouped by closure path.' FROM dbo.silver_d5_closure_control_queue GROUP BY closure_opportunity
    UNION ALL
    SELECT 'decision_readiness', decision_readiness, COUNT(*), 'D5 conflicts grouped by decision readiness.' FROM dbo.silver_d5_closure_control_queue GROUP BY decision_readiness
    UNION ALL
    SELECT 'guard_type', v2_relationship_type, COUNT(*), 'Guard edges grouped by type.' FROM dbo.silver_d5_guard_edge_decision_queue GROUP BY v2_relationship_type
) x;

DROP TABLE #d3_lookup;
DROP TABLE #d4_lookup;
DROP TABLE #d5_control_raw;
DROP TABLE #d5_control;

END
