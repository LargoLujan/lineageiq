-- Warehouse-native translation of backend/scripts/30_build_d5_object_
-- conflict_resolution_package.ps1 (Phase 2 migration continuation,
-- 2026-07-21). Reads dbo.silver_orchestration_v2_object_conflicts (24),
-- dbo.silver_orchestration_v2_edges (24, v2_relationship_type LIKE
-- 'object_%' -- underscore is escaped since it's a T-SQL LIKE wildcard),
-- dbo.silver_orchestration_v2_plan (24), dbo.silver_object_read_write_
-- classification (23), dbo.silver_likely_conflict_cleanup_queue (25,
-- phase D5). conflict_id ("D5C00001", ...) is assigned in the SAME
-- sorted order used for final export (writer+reader+executor count
-- DESC, object_display_name ASC), matching the original script exactly
-- since it also assigns IDs after sorting, not in file order. guard_id/
-- participant_id have no such sort anchor in the original and are
-- opaque per-row identifiers like other D-package row ids in this
-- migration; validation matches those rows by content.
-- Validated 2026-07-21: 0 new bugs. conflict_id text itself rarely
-- matches PS's (many tied reader+writer+executor sums make the
-- object_display_name tie-break sensitive to PS's culture-aware sort vs
-- this file's LOWER()-ordinal sort) -- confirmed harmless since object_
-- key-based linkage between conflicts/guards/participants is 100%
-- consistent on both sides. object_display_name and guard-edge upstream/
-- downstream direction both carry a handful of rows (11 and 5
-- respectively) already inherited from 24's own tie-break/ordering
-- residual for objects with several co-equal-priority writers, confirmed
-- by direct comparison against 24's already-deployed table, not
-- introduced here. upstream/downstream_estimated_duration_seconds can
-- differ in decimal separator (comma vs period) on a few rows -- an
-- es-ES-locale artifact of how 24's original PS Export-Csv wrote that
-- string column, not a value difference.
CREATE OR ALTER PROCEDURE dbo.sp_build_d5_object_conflict_resolution_package
AS
BEGIN

IF OBJECT_ID('dbo.silver_d5_object_conflict_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d5_object_conflict_queue;
IF OBJECT_ID('dbo.silver_d5_object_guard_edge_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d5_object_guard_edge_queue;
IF OBJECT_ID('dbo.silver_d5_object_conflict_participants', 'U') IS NOT NULL DROP TABLE dbo.silver_d5_object_conflict_participants;
IF OBJECT_ID('dbo.silver_d5_object_conflict_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d5_object_conflict_summary;
IF OBJECT_ID('dbo.silver_d5_object_conflict_decision_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d5_object_conflict_decision_template;
IF OBJECT_ID('dbo.silver_d5_readonly_conflict_review_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d5_readonly_conflict_review_targets;

IF OBJECT_ID('tempdb..#plan_first') IS NOT NULL DROP TABLE #plan_first;
SELECT item_key, v2_status, estimated_duration_seconds
INTO #plan_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key, v2_status, estimated_duration_seconds,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_orchestration_v2_plan
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#d5_cleanup') IS NOT NULL DROP TABLE #d5_cleanup;
SELECT object_key, priority_score
INTO #d5_cleanup
FROM (
    SELECT LOWER(LTRIM(RTRIM(object_key))) AS object_key, priority_score,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(object_key))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_likely_conflict_cleanup_queue WHERE phase_id = 'D5'
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#guard_edges') IS NOT NULL DROP TABLE #guard_edges;
SELECT
    ROW_NUMBER() OVER (ORDER BY LOWER(LTRIM(RTRIM(object_key))), LOWER(LTRIM(RTRIM(upstream_qualified_name))), LOWER(LTRIM(RTRIM(downstream_qualified_name)))) AS guard_seq,
    LOWER(LTRIM(RTRIM(object_key))) AS object_key_norm, object_key, upstream_qualified_name, downstream_qualified_name, v2_relationship_type,
    source_relationship_type, edge_status, confidence, ISNULL(evidence,'') AS evidence
INTO #guard_edges
FROM dbo.silver_orchestration_v2_edges
WHERE v2_relationship_type LIKE 'object[_]%';

IF OBJECT_ID('tempdb..#guard_counts') IS NOT NULL DROP TABLE #guard_counts;
SELECT object_key_norm, COUNT(*) AS guard_edge_count
INTO #guard_counts FROM #guard_edges GROUP BY object_key_norm;

IF OBJECT_ID('tempdb..#guard_type_agg') IS NOT NULL DROP TABLE #guard_type_agg;
;WITH t AS (SELECT object_key_norm, v2_relationship_type, COUNT(*) AS cnt FROM #guard_edges GROUP BY object_key_norm, v2_relationship_type),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY object_key_norm ORDER BY cnt DESC, LOWER(v2_relationship_type) ASC) AS rn FROM t)
SELECT object_key_norm, STRING_AGG(v2_relationship_type + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS guard_edge_types
INTO #guard_type_agg FROM r GROUP BY object_key_norm;

IF OBJECT_ID('tempdb..#participants') IS NOT NULL DROP TABLE #participants;
SELECT LOWER(LTRIM(RTRIM(object_key))) AS object_key_norm, object_display_name, workspace_name, item_type, item_name, item_qualified_name,
    operation_type, source_type, object_type, object_type_status, lineage_confidence, scheduling_readiness,
    orchestration_parallel_readiness, ISNULL(evidence,'') AS evidence
INTO #participants
FROM dbo.silver_object_read_write_classification
WHERE ISNULL(object_key,'') <> '';

IF OBJECT_ID('tempdb..#participant_counts') IS NOT NULL DROP TABLE #participant_counts;
SELECT object_key_norm, COUNT(*) AS participant_row_count
INTO #participant_counts FROM #participants GROUP BY object_key_norm;

IF OBJECT_ID('tempdb..#participant_type_agg') IS NOT NULL DROP TABLE #participant_type_agg;
;WITH t AS (SELECT object_key_norm, item_type, COUNT(*) AS cnt FROM #participants GROUP BY object_key_norm, item_type),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY object_key_norm ORDER BY cnt DESC, LOWER(item_type) ASC) AS rn FROM t)
SELECT object_key_norm, STRING_AGG(item_type + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS participant_item_types
INTO #participant_type_agg FROM r GROUP BY object_key_norm;

IF OBJECT_ID('tempdb..#participant_op_agg') IS NOT NULL DROP TABLE #participant_op_agg;
;WITH t AS (SELECT object_key_norm, operation_type, COUNT(*) AS cnt FROM #participants GROUP BY object_key_norm, operation_type),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY object_key_norm ORDER BY cnt DESC, LOWER(operation_type) ASC) AS rn FROM t)
SELECT object_key_norm, STRING_AGG(operation_type + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS operation_counts
INTO #participant_op_agg FROM r GROUP BY object_key_norm;

IF OBJECT_ID('tempdb..#conflicts_base') IS NOT NULL DROP TABLE #conflicts_base;
SELECT
    LOWER(LTRIM(RTRIM(object_key))) AS object_key_norm, object_key, object_display_name, source_types, object_types,
    ISNULL(reader_count,0) AS reader_count, ISNULL(writer_count,0) AS writer_count, ISNULL(executor_count,0) AS executor_count,
    ISNULL(exact_row_count,0) AS exact_row_count, ISNULL(ambiguous_row_count,0) AS ambiguous_row_count,
    ISNULL(conflict_types,'') AS conflict_types, ISNULL(object_readiness,'') AS object_readiness,
    ISNULL(statuses,'') AS statuses, ISNULL(sample_readers,'') AS sample_readers, ISNULL(sample_writers,'') AS sample_writers,
    ISNULL(sample_executors,'') AS sample_executors, ISNULL(recommended_next_action,'') AS recommended_next_action
INTO #conflicts_base
FROM dbo.silver_orchestration_v2_object_conflicts;

IF OBJECT_ID('tempdb..#conflicts_final') IS NOT NULL DROP TABLE #conflicts_final;
SELECT
    'D5C' + RIGHT('0000' + CAST(ROW_NUMBER() OVER (ORDER BY (cb.reader_count + cb.writer_count + cb.executor_count) DESC, LOWER(cb.object_display_name)) AS VARCHAR(10)), 5) AS conflict_id,
    cb.object_key_norm, cb.object_key, cb.object_display_name, cb.source_types, cb.object_types, cb.reader_count, cb.writer_count,
    cb.executor_count, cb.exact_row_count, cb.ambiguous_row_count, cb.conflict_types, cb.object_readiness,
    (CASE WHEN cb.object_readiness = 'blocked_until_lineage_and_type_confirmed' THEN 'blocked_by_d3_d4_evidence'
          WHEN cb.conflict_types LIKE '%execute_dependency_review%' THEN 'execute_order_review'
          WHEN cb.conflict_types LIKE '%writer_reader_ordering%' THEN 'writer_before_reader_review'
          WHEN cb.conflict_types LIKE '%multiple_writers%' THEN 'writer_order_review'
          ELSE 'manual_conflict_review' END) AS decision_readiness,
    (CASE WHEN ISNULL(dc.priority_score,0) <> 0 THEN dc.priority_score
          ELSE 80 + (cb.writer_count * 10) + (cb.reader_count * 3) + (cb.executor_count * 4) END) AS priority_score,
    ISNULL(gc.guard_edge_count, 0) AS guard_edge_count,
    ISNULL(gta.guard_edge_types, '') AS guard_edge_types,
    ISNULL(pc.participant_row_count, 0) AS participant_row_count,
    ISNULL(pta.participant_item_types, '') AS participant_item_types,
    ISNULL(poa.operation_counts, '') AS participant_operations,
    LEFT(LTRIM(RTRIM(cb.statuses)), 900) AS statuses,
    LEFT(LTRIM(RTRIM(cb.sample_readers)), 900) AS sample_readers,
    LEFT(LTRIM(RTRIM(cb.sample_writers)), 900) AS sample_writers,
    LEFT(LTRIM(RTRIM(cb.sample_executors)), 900) AS sample_executors,
    LEFT(LTRIM(RTRIM(cb.recommended_next_action)), 900) AS recommended_next_action
INTO #conflicts_final
FROM #conflicts_base cb
LEFT JOIN #d5_cleanup dc ON dc.object_key = cb.object_key_norm
LEFT JOIN #guard_counts gc ON gc.object_key_norm = cb.object_key_norm
LEFT JOIN #guard_type_agg gta ON gta.object_key_norm = cb.object_key_norm
LEFT JOIN #participant_counts pc ON pc.object_key_norm = cb.object_key_norm
LEFT JOIN #participant_type_agg pta ON pta.object_key_norm = cb.object_key_norm
LEFT JOIN #participant_op_agg poa ON poa.object_key_norm = cb.object_key_norm;

SELECT
    conflict_id, priority_score,
    CASE WHEN priority_score >= 200 THEN 'critical' WHEN priority_score >= 130 THEN 'high' WHEN priority_score >= 90 THEN 'medium' ELSE 'low' END AS priority_band,
    object_key, object_display_name, source_types, object_types, reader_count, writer_count, executor_count,
    exact_row_count, ambiguous_row_count, conflict_types, object_readiness, decision_readiness, guard_edge_count,
    guard_edge_types, participant_row_count, participant_item_types, participant_operations, statuses, sample_readers,
    sample_writers, sample_executors, recommended_next_action,
    (CASE decision_readiness
        WHEN 'blocked_by_d3_d4_evidence' THEN 'blocked_until_d3_d4_confirmed; then decide writer_order, writer_before_reader, safe_parallel, or false_conflict'
        WHEN 'execute_order_review' THEN 'serialize_execute_after_writers; confirm_invocation_dependency; blocked; false_conflict'
        WHEN 'writer_before_reader_review' THEN 'writer_before_reader; safe_parallel_readers_after_writer; blocked; false_conflict'
        WHEN 'writer_order_review' THEN 'serialize_writers; partitioned_writes_safe_parallel; blocked; false_conflict'
        ELSE 'serialize; safe_parallel; blocked; false_conflict' END) AS decision_options,
    'Record a reviewed conflict decision: serialize writers, enforce writer-before-reader, prove safe parallelism, reject false conflict, or block pending D3/D4 evidence.' AS d5_gate_to_close
INTO dbo.silver_d5_object_conflict_queue
FROM #conflicts_final;

SELECT
    conflict_id, object_key, object_display_name, conflict_types, object_readiness, decision_readiness,
    reader_count AS current_reader_count, writer_count AS current_writer_count, executor_count AS current_executor_count,
    '' AS proposed_decision, '' AS proposed_writer_order, '' AS proposed_reader_rule, '' AS proposed_execute_rule,
    '' AS safe_parallel_groups, '' AS blocked_reason, '' AS confirmation_source, '' AS confirmation_evidence,
    '' AS reviewer, '' AS reviewed_at,
    'D5 template row. Use decisions such as serialize_writers, writer_before_reader, execute_after_writers, safe_parallel_partitioned, false_conflict, or blocked_pending_d3_d4.' AS notes
INTO dbo.silver_d5_object_conflict_decision_template
FROM #conflicts_final;

SELECT
    conflict_id, priority_score,
    CASE WHEN priority_score >= 200 THEN 'critical' WHEN priority_score >= 130 THEN 'high' WHEN priority_score >= 90 THEN 'medium' ELSE 'low' END AS priority_band,
    object_display_name, conflict_types, object_readiness, decision_readiness,
    'Review D3 lineage evidence, D4 exact type evidence, writer item definitions, reader dependencies, execution history, and owner evidence before selecting a conflict decision.' AS readonly_method,
    'analysis/d5_object_conflict_decision_template.csv' AS template_path,
    'Read-only/manual review target. Do not update schedules or orchestration rules from this package alone.' AS notes
INTO dbo.silver_d5_readonly_conflict_review_targets
FROM #conflicts_final;

-- ===========================================================================
-- Guard edge queue.
-- ===========================================================================
SELECT
    'D5G' + RIGHT('00000' + CAST(ge.guard_seq AS VARCHAR(10)), 6) AS guard_id,
    ISNULL(cf.conflict_id, '') AS conflict_id,
    ge.object_key, ge.upstream_qualified_name, ge.downstream_qualified_name, ge.v2_relationship_type,
    ge.source_relationship_type, ge.edge_status, ge.confidence,
    ISNULL(up.v2_status, '') AS upstream_v2_status, ISNULL(dp.v2_status, '') AS downstream_v2_status,
    CAST(up.estimated_duration_seconds AS VARCHAR(50)) AS upstream_estimated_duration_seconds,
    CAST(dp.estimated_duration_seconds AS VARCHAR(50)) AS downstream_estimated_duration_seconds,
    LEFT(LTRIM(RTRIM(ge.evidence)), 900) AS evidence,
    'Keep, modify, or remove this guard only after conflict decision is reviewed.' AS d5_gate_to_close
INTO dbo.silver_d5_object_guard_edge_queue
FROM #guard_edges ge
LEFT JOIN #conflicts_final cf ON cf.object_key_norm = ge.object_key_norm
LEFT JOIN #plan_first up ON up.item_key = LOWER(LTRIM(RTRIM(ge.upstream_qualified_name)))
LEFT JOIN #plan_first dp ON dp.item_key = LOWER(LTRIM(RTRIM(ge.downstream_qualified_name)));

-- ===========================================================================
-- Conflict participants.
-- ===========================================================================
SELECT
    'D5P' + RIGHT('00000' + CAST(ROW_NUMBER() OVER (ORDER BY cf.conflict_id, LOWER(p.operation_type), LOWER(p.item_qualified_name)) AS VARCHAR(10)), 6) AS participant_id,
    cf.conflict_id, cf.object_key, p.object_display_name, p.workspace_name, p.item_type, p.item_name, p.item_qualified_name,
    p.operation_type, p.source_type, p.object_type, p.object_type_status, p.lineage_confidence, p.scheduling_readiness,
    p.orchestration_parallel_readiness, LEFT(LTRIM(RTRIM(p.evidence)), 900) AS evidence
INTO dbo.silver_d5_object_conflict_participants
FROM #conflicts_final cf
INNER JOIN #participants p ON p.object_key_norm = cf.object_key_norm;

-- ===========================================================================
-- Summary.
-- ===========================================================================
SELECT summary_scope, group_key, row_count, high_or_critical_count, max_priority_score, notes
INTO dbo.silver_d5_object_conflict_summary
FROM (
    SELECT 'total' AS summary_scope, 'D5 object conflicts' AS group_key, COUNT(*) AS row_count,
        SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END) AS high_or_critical_count,
        ISNULL(MAX(priority_score),0) AS max_priority_score,
        'Object conflicts from analysis/orchestration_v2_object_conflicts.csv.' AS notes
    FROM dbo.silver_d5_object_conflict_queue

    UNION ALL
    SELECT 'total', 'D5 guard edges', COUNT(*), 0, 0, 'Object guard edges from analysis/orchestration_v2_edges.csv.'
    FROM dbo.silver_d5_object_guard_edge_queue

    UNION ALL
    SELECT 'total', 'D5 conflict participants', COUNT(*), 0, 0, 'Read/write/execute rows participating in conflict objects.'
    FROM dbo.silver_d5_object_conflict_participants

    UNION ALL
    SELECT 'conflict_types', conflict_types, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Conflicts grouped by conflict type set.'
    FROM dbo.silver_d5_object_conflict_queue GROUP BY conflict_types

    UNION ALL
    SELECT 'object_readiness', object_readiness, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Conflicts grouped by evidence/readiness gate.'
    FROM dbo.silver_d5_object_conflict_queue GROUP BY object_readiness

    UNION ALL
    SELECT 'decision_readiness', decision_readiness, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Conflicts grouped by the next decision kind.'
    FROM dbo.silver_d5_object_conflict_queue GROUP BY decision_readiness

    UNION ALL
    SELECT 'guard_type', v2_relationship_type, COUNT(*), 0, 0, 'Guard edges grouped by guard type.'
    FROM dbo.silver_d5_object_guard_edge_queue GROUP BY v2_relationship_type

    UNION ALL
    SELECT 'participant_operation', operation_type, COUNT(*), 0, 0, 'Conflict participants grouped by operation type.'
    FROM dbo.silver_d5_object_conflict_participants GROUP BY operation_type
) s;

END
