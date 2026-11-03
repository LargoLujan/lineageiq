-- Warehouse-native translation of backend/scripts/25_build_likely_
-- conflict_cleanup_plan.ps1 (Phase 2 migration continuation, 2026-07-21).
-- Reads only THIS migration's own already-validated silver_* outputs:
-- silver_orchestration_v2_plan/object_conflicts/parallel_candidates (24),
-- silver_evidence_hardening_queue (22), silver_object_read_write_
-- classification (23), silver_source_object_type_resolution_queue (15).
-- manual_lineage_review_queue.csv and evidence_hardening_summary.csv are
-- loaded by the original but never referenced afterward (dead params,
-- confirmed by reading the whole script) -- not read here either.
--
-- item_qualified_name matching uses LOWER(LTRIM(RTRIM(...))), mirroring
-- PowerShell's Group-Object default case-insensitive equality.
-- Validated: phase plan and summary tables match exactly; the queue
-- table matches exactly except the D3 segment's illustrative object_
-- display_name "sample" (MIN() picks a different one of an item's
-- several unconfirmed objects than the original's file-order-dependent
-- first-row pick -- same class as 15/22/23's documented sample-pick
-- gaps) and a handful of casing-collision item_qualified_name/object_key
-- values already documented in 05/13/15's silver_* sources this chains
-- off. D4's per-row (not deduped) rows were double-checked directly
-- against real data and match exactly, including cases where the same
-- object_key legitimately appears twice (once per raw_object_type).
CREATE OR ALTER PROCEDURE dbo.sp_build_likely_conflict_cleanup_plan
AS
BEGIN

IF OBJECT_ID('dbo.silver_likely_conflict_cleanup_phase_plan', 'U') IS NOT NULL DROP TABLE dbo.silver_likely_conflict_cleanup_phase_plan;
IF OBJECT_ID('dbo.silver_likely_conflict_cleanup_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_likely_conflict_cleanup_queue;
IF OBJECT_ID('dbo.silver_likely_conflict_cleanup_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_likely_conflict_cleanup_summary;

-- ===========================================================================
-- Phase plan (9 static rows with computed current_count values).
-- ===========================================================================
SELECT phase_id, phase_name, current_count, primary_inputs, goal, method, expected_output, gate_to_close, human_action
INTO dbo.silver_likely_conflict_cleanup_phase_plan
FROM (
    SELECT 'D0' AS phase_id, 'Baseline and priority lock' AS phase_name,
        (SELECT COUNT(*) FROM dbo.silver_orchestration_v2_plan) AS current_count,
        'analysis/orchestration_v2_summary.csv; analysis/orchestration_v2_plan.csv' AS primary_inputs,
        'Freeze current blocker metrics and use the queue as the single cleanup entry point.' AS goal,
        'Run this script after every refresh; compare counts before and after each cleanup phase.' AS method,
        'Baseline counts and prioritized cleanup queue.' AS expected_output,
        'All downstream phases have current counts and owners.' AS gate_to_close,
        'Review the phase plan and pick the next phase to execute.' AS human_action
    UNION ALL
    SELECT 'D1', 'Missing object-level evidence',
        (SELECT COUNT(*) FROM dbo.silver_evidence_hardening_queue WHERE issue_type = 'missing_object_level_lineage')
            + (SELECT COUNT(*) FROM dbo.silver_orchestration_v2_parallel_candidates WHERE candidate_status = 'blocked_missing_object_evidence'),
        'analysis/manual_lineage_review_queue.csv; analysis/evidence_hardening_queue.csv; analysis/orchestration_v2_parallel_candidates.csv',
        'Attach object-level tables/views/stored procedures/files to items with no parseable lineage.',
        'Use Fabric definitions, Azure DevOps code, SharePoint docs, OneLake paths, and owner/manual evidence.',
        'Updated object evidence and fewer blocked_missing_object_evidence rows.',
        'No high-priority executable item remains without object-level lineage.',
        'Approve read-only/manual review of the top queue rows.'
    UNION ALL
    SELECT 'D2', 'Likely dependency confirmation',
        (SELECT COUNT(*) FROM dbo.silver_orchestration_v2_plan WHERE v2_status = 'blocked_dependency_confirmation')
            + (SELECT COUNT(*) FROM dbo.silver_evidence_hardening_queue WHERE issue_type = 'weak_relationship_confidence'),
        'index/dependencies.csv; analysis/ideal_execution_edges.csv; analysis/evidence_hardening_queue.csv',
        'Promote true dependency edges from likely to confirmed and mark false positives as rejected/manual-blocked.',
        'Check Fabric definition/model binding first; then Azure DevOps, SharePoint design docs, and owner evidence.',
        'Fewer blocked_dependency_confirmation rows and fewer likely dependency edges.',
        'High-impact report-model, execute, refresh, and depends_on likely edges are resolved.',
        'Approve dependency evidence review by priority.'
    UNION ALL
    SELECT 'D3', 'Likely object-lineage confirmation',
        (SELECT COUNT(*) FROM dbo.silver_object_read_write_classification WHERE scheduling_readiness = 'needs_lineage_confirmation'),
        'analysis/object_read_write_classification.csv; analysis/evidence_hardening_queue.csv',
        'Confirm read/write/execute references extracted from notebooks, CopyJobs, DataPipelines, and semantic model definitions.',
        'Reconcile parser evidence with item definitions, code repositories, owner docs, and source metadata.',
        'Fewer needs_lineage_confirmation rows.',
        'High-duration and high-impact executable items no longer depend on likely object evidence.',
        'Approve item-by-item source/code review.'
    UNION ALL
    SELECT 'D4', 'Exact table view stored procedure typing',
        (SELECT COUNT(*) FROM dbo.silver_object_read_write_classification WHERE scheduling_readiness = 'needs_object_type_confirmation')
            + (SELECT COUNT(*) FROM dbo.silver_source_object_type_resolution_queue WHERE status = 'needs_metadata_review'),
        'analysis/source_object_type_resolution_queue.csv; analysis/source_object_type_metadata_gaps.csv; analysis/object_read_write_classification.csv',
        'Resolve table_or_view and native_query_object into table, view, stored_procedure, file, shortcut, or query.',
        'Use read-only SQL/Fabric sys.objects where access exists, otherwise owner-approved catalog/manual evidence.',
        'Fewer needs_object_type_confirmation and ambiguous object conflict rows.',
        'High-priority ambiguous objects in conflict and impact queues have exact type evidence.',
        'Approve metadata access cleanup or manual catalog evidence capture.'
    UNION ALL
    SELECT 'D5', 'Writer-reader and multi-writer conflict resolution',
        (SELECT COUNT(*) FROM dbo.silver_orchestration_v2_object_conflicts),
        'analysis/orchestration_v2_object_conflicts.csv; analysis/orchestration_v2_edges.csv',
        'Turn object conflicts into explicit order rules or remove false conflicts after evidence cleanup.',
        'For each shared object, decide writer order, writer-before-reader rules, or safe shared-read parallelism.',
        'Resolved object guard edges and fewer object conflict rows.',
        'No high-impact object has unresolved multi-writer or writer-reader behavior.',
        'Approve serialization decisions for shared objects.'
    UNION ALL
    SELECT 'D6', 'Failure and duration stabilization',
        (SELECT COUNT(*) FROM dbo.silver_orchestration_v2_plan WHERE v2_status = 'hold_failure_stabilization' OR original_risk_flags LIKE '%duration_defaulted%'),
        'analysis/orchestration_v2_plan.csv; index/executions.csv; analysis/execution_duration_by_item.csv',
        'Remove failure holds and replace default durations with observed or owner-approved estimates.',
        'Review failure hotspots, disabled/enabled schedules, run histories, and long/defaulted duration items.',
        'Fewer hold_failure_stabilization rows and better wave estimates.',
        'Failure hotspots are stabilized and high-impact duration defaults are replaced.',
        'Approve operational review with owners before any scheduling change.'
    UNION ALL
    SELECT 'D7', 'Orchestration review promotion',
        (SELECT COUNT(*) FROM dbo.silver_orchestration_v2_plan WHERE v2_status = 'needs_orchestration_review'),
        'analysis/orchestration_v2_plan.csv; analysis/orchestration_v2_waves.csv',
        'Promote reviewed rows into non-production orchestration candidates or keep them as manual/governance checks.',
        'Review schedules, owners, environments, deployment pipelines, duration, and upstream/downstream evidence.',
        'A non-prod candidate set for master pipeline design.',
        'Every review row has approved action: run, check, skip, or manual validation.',
        'Approve rows that can move to non-production pipeline design.'
    UNION ALL
    SELECT 'D8', 'Parallel candidate retest',
        (SELECT COUNT(*) FROM dbo.silver_orchestration_v2_parallel_candidates),
        'analysis/orchestration_v2_parallel_candidates.csv; analysis/object_read_write_classification.csv',
        'Re-run parallelism checks after D1-D7 and identify safe non-production test candidates.',
        'Rebuild Phases B and C; accept only candidates without direct dependencies, unresolved evidence, or shared writes.',
        'Non-production parallel test list or documented blockers.',
        'Parallel candidates are either approved for non-prod test or explicitly blocked.',
        'Approve a controlled non-production parallelism test batch.'
) x;

-- ===========================================================================
-- Queue (7 segments, one per phase D1-D8 except D0).
-- ===========================================================================
IF OBJECT_ID('tempdb..#queue') IS NOT NULL DROP TABLE #queue;

;WITH d1 (phase_id, phase_name, priority_score, blocker_type, blocker_count, workspace_name, item_type, item_name, item_qualified_name, object_key, object_display_name, evidence_source, recommended_action, gate_to_close) AS (
    SELECT 'D1', 'Missing object-level evidence',
        ISNULL(TRY_CAST(priority_score AS INT), 0), 'missing_object_level_lineage', 1,
        workspace_name, item_type, item_name, LEFT(LTRIM(RTRIM(item_qualified_name)), 500), '', '',
        'analysis/evidence_hardening_queue.csv', LEFT(LTRIM(RTRIM(ISNULL(next_action, ''))), 700),
        'Object-level lineage exists for this item.'
    FROM dbo.silver_evidence_hardening_queue WHERE issue_type = 'missing_object_level_lineage'
),
d2 (phase_id, phase_name, priority_score, blocker_type, blocker_count, workspace_name, item_type, item_name, item_qualified_name, object_key, object_display_name, evidence_source, recommended_action, gate_to_close) AS (
    SELECT 'D2', 'Likely dependency confirmation',
        100 + ISNULL(successor_count, 0) + ISNULL(incoming_likely_edges, 0) + ISNULL(outgoing_likely_edges, 0),
        'blocked_dependency_confirmation', ISNULL(incoming_likely_edges, 0) + ISNULL(outgoing_likely_edges, 0),
        workspace_name, item_type, item_name, LEFT(LTRIM(RTRIM(qualified_name)), 500), '', '',
        'analysis/orchestration_v2_plan.csv',
        'Confirm likely dependency edges around this item from Fabric definitions, model/report binding, Azure DevOps, SharePoint, or owner evidence.',
        'Incoming/outgoing likely dependency count is zero or explicitly rejected.'
    FROM dbo.silver_orchestration_v2_plan WHERE v2_status = 'blocked_dependency_confirmation'
),
d3_grouped AS (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key,
        COUNT(*) AS grp_count,
        SUM(CASE WHEN operation_type = 'write' THEN 1 ELSE 0 END) AS write_count,
        MIN(workspace_name) AS workspace_name, MIN(item_type) AS item_type, MIN(item_name) AS item_name,
        MIN(item_qualified_name) AS item_qualified_name, MIN(ISNULL(object_display_name, '')) AS object_display_name
    FROM dbo.silver_object_read_write_classification
    WHERE scheduling_readiness = 'needs_lineage_confirmation'
    GROUP BY LOWER(LTRIM(RTRIM(item_qualified_name)))
),
d3 (phase_id, phase_name, priority_score, blocker_type, blocker_count, workspace_name, item_type, item_name, item_qualified_name, object_key, object_display_name, evidence_source, recommended_action, gate_to_close) AS (
    SELECT 'D3', 'Likely object-lineage confirmation',
        90 + grp_count + (write_count * 5), 'needs_lineage_confirmation', grp_count,
        workspace_name, item_type, item_name, LEFT(LTRIM(RTRIM(item_qualified_name)), 500), '', LEFT(LTRIM(RTRIM(object_display_name)), 300),
        'analysis/object_read_write_classification.csv',
        'Confirm every likely read/write/execute object reference for this item from definition/code/metadata/owner evidence.',
        'All object rows for this item are confirmed or explicitly rejected.'
    FROM d3_grouped
),
d4 (phase_id, phase_name, priority_score, blocker_type, blocker_count, workspace_name, item_type, item_name, item_qualified_name, object_key, object_display_name, evidence_source, recommended_action, gate_to_close) AS (
    SELECT 'D4', 'Exact table view stored procedure typing',
        ISNULL(priority_score, 0), 'source_object_type_pending', ISNULL(TRY_CAST(affected_item_count AS INT), 0),
        workspaces, affected_item_types, '', '',
        LEFT(LTRIM(RTRIM(source_type + '|' + source_server + '|' + source_database + '|' + schema_name + '|' + object_name)), 500),
        LEFT(LTRIM(RTRIM(source_database + ' / ' + schema_name + '.' + object_name)), 300),
        'analysis/source_object_type_resolution_queue.csv', LEFT(LTRIM(RTRIM(ISNULL(next_step, ''))), 700),
        'resolved_object_type is exact or owner/manual evidence marks this object as intentionally unresolved.'
    FROM dbo.silver_source_object_type_resolution_queue WHERE status = 'needs_metadata_review'
),
d5 (phase_id, phase_name, priority_score, blocker_type, blocker_count, workspace_name, item_type, item_name, item_qualified_name, object_key, object_display_name, evidence_source, recommended_action, gate_to_close) AS (
    SELECT 'D5', 'Writer-reader and multi-writer conflict resolution',
        80 + (ISNULL(writer_count, 0) * 10) + (ISNULL(reader_count, 0) * 3) + (ISNULL(executor_count, 0) * 4),
        conflict_types, ISNULL(writer_count, 0) + ISNULL(reader_count, 0) + ISNULL(executor_count, 0),
        '', '', '', '',
        LEFT(LTRIM(RTRIM(object_key)), 500), LEFT(LTRIM(RTRIM(ISNULL(object_display_name, ''))), 300),
        'analysis/orchestration_v2_object_conflicts.csv', LEFT(LTRIM(RTRIM(ISNULL(recommended_next_action, ''))), 700),
        'Writers/readers are serialized, proven independent, or rejected as false conflict.'
    FROM dbo.silver_orchestration_v2_object_conflicts
),
d6 (phase_id, phase_name, priority_score, blocker_type, blocker_count, workspace_name, item_type, item_name, item_qualified_name, object_key, object_display_name, evidence_source, recommended_action, gate_to_close) AS (
    -- PowerShell's [math]::Round() defaults to MidpointRounding.ToEven (banker's
    -- rounding), unlike T-SQL's ROUND() which rounds halves away from zero. This
    -- matters a lot here: default-by-role durations are often exactly 300/900/etc
    -- seconds, so duration/600 lands exactly on a .5 boundary for most rows.
    -- rnd.rounded replicates ToEven explicitly instead of calling ROUND() directly.
    SELECT 'D6', 'Failure and duration stabilization',
        70 + ISNULL(p.failed_count, 0) + rnd.rounded,
        p.v2_status, 1,
        p.workspace_name, p.item_type, p.item_name, LEFT(LTRIM(RTRIM(p.qualified_name)), 500), '', '',
        'analysis/orchestration_v2_plan.csv', LEFT(LTRIM(RTRIM(ISNULL(p.v2_recommended_next_action, ''))), 700),
        'Failure hold removed and duration estimate has observed or approved evidence.'
    FROM dbo.silver_orchestration_v2_plan p
    CROSS APPLY (SELECT ISNULL(p.estimated_duration_seconds, 0) / 600.0 AS q) qq
    CROSS APPLY (SELECT CASE WHEN qq.q - FLOOR(qq.q) = 0.5
                              THEN CASE WHEN CAST(FLOOR(qq.q) AS BIGINT) % 2 = 0 THEN CAST(FLOOR(qq.q) AS INT) ELSE CAST(FLOOR(qq.q) AS INT) + 1 END
                         ELSE CAST(ROUND(qq.q, 0) AS INT) END AS rounded) rnd
    WHERE p.v2_status = 'hold_failure_stabilization' OR p.original_risk_flags LIKE '%duration_defaulted%'
),
d7 (phase_id, phase_name, priority_score, blocker_type, blocker_count, workspace_name, item_type, item_name, item_qualified_name, object_key, object_display_name, evidence_source, recommended_action, gate_to_close) AS (
    SELECT 'D7', 'Orchestration review promotion',
        60 + ISNULL(successor_count, 0) + ISNULL(enabled_schedules, 0), 'needs_orchestration_review', 1,
        workspace_name, item_type, item_name, LEFT(LTRIM(RTRIM(qualified_name)), 500), '', '',
        'analysis/orchestration_v2_plan.csv', LEFT(LTRIM(RTRIM(ISNULL(v2_recommended_next_action, ''))), 700),
        'Approved action is recorded: run, check, skip, or manual validation.'
    FROM dbo.silver_orchestration_v2_plan WHERE v2_status = 'needs_orchestration_review'
),
d8 (phase_id, phase_name, priority_score, blocker_type, blocker_count, workspace_name, item_type, item_name, item_qualified_name, object_key, object_display_name, evidence_source, recommended_action, gate_to_close) AS (
    SELECT 'D8', 'Parallel candidate retest',
        50 + (ISNULL(shared_write_object_count, 0) * 10) + (ISNULL(shared_object_count, 0) * 2), candidate_status, 1,
        workspace_name, ISNULL(item_type_a, '') + ' / ' + ISNULL(item_type_b, ''), '',
        LEFT(LTRIM(RTRIM(ISNULL(candidate_a, '') + ' <-> ' + ISNULL(candidate_b, ''))), 500), '',
        LEFT(LTRIM(RTRIM(ISNULL(sample_shared_objects, ''))), 300),
        'analysis/orchestration_v2_parallel_candidates.csv', LEFT(LTRIM(RTRIM(ISNULL(recommendation, ''))), 700),
        'Candidate is approved for non-prod parallel test or explicitly blocked.'
    FROM dbo.silver_orchestration_v2_parallel_candidates
)
SELECT * INTO #queue FROM (
    SELECT * FROM d1 UNION ALL SELECT * FROM d2 UNION ALL SELECT * FROM d3 UNION ALL SELECT * FROM d4
    UNION ALL SELECT * FROM d5 UNION ALL SELECT * FROM d6 UNION ALL SELECT * FROM d7 UNION ALL SELECT * FROM d8
) u;

SELECT * INTO dbo.silver_likely_conflict_cleanup_queue FROM #queue;

-- ===========================================================================
-- Summary (grouped by phase, top-5 blocker types by count).
-- ===========================================================================
IF OBJECT_ID('tempdb..#blocker_counts') IS NOT NULL DROP TABLE #blocker_counts;
SELECT phase_id, blocker_type, COUNT(*) AS cnt
INTO #blocker_counts
FROM #queue GROUP BY phase_id, blocker_type;

IF OBJECT_ID('tempdb..#top_blockers') IS NOT NULL DROP TABLE #top_blockers;
;WITH ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY phase_id ORDER BY cnt DESC, LOWER(blocker_type) ASC) AS rn
    FROM #blocker_counts
)
SELECT phase_id, STRING_AGG(blocker_type + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS top_blocker_types
INTO #top_blockers
FROM ranked WHERE rn <= 5 GROUP BY phase_id;

SELECT q.phase_id, MIN(q.phase_name) AS phase_name, COUNT(*) AS queue_count, MAX(q.priority_score) AS max_priority_score,
    ISNULL(MAX(tb.top_blocker_types), '') AS top_blocker_types
INTO dbo.silver_likely_conflict_cleanup_summary
FROM #queue q
LEFT JOIN #top_blockers tb ON tb.phase_id = q.phase_id
GROUP BY q.phase_id;

END
