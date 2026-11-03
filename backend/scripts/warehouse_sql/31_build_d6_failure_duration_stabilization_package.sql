-- Warehouse-native translation of backend/scripts/31_build_d6_failure_
-- duration_stabilization_package.ps1 (Phase 2 migration continuation,
-- 2026-07-21). Reads dbo.silver_orchestration_v2_plan (24, v2_status=
-- 'hold_failure_stabilization' OR original_risk_flags LIKE
-- '%duration_defaulted%'), dbo.silver_likely_conflict_cleanup_queue (25,
-- phase D6), dbo.bronze_failure_hotspots, dbo.bronze_execution_
-- duration_by_item, dbo.bronze_executions.
-- d6_id ("D6I00001", ...) is assigned in the SAME sorted order used for
-- final export (D6 cleanup priority_score DESC, workspace_name,
-- item_type, item_name), matching the original script exactly since it
-- also assigns IDs after sorting, not in file order. d6_failure_id/
-- d6_duration_id reuse that same relative order (the original increments
-- them in the same outer loop, only skipping unmatched rows for the
-- failure queue). d6_execution_id has no such anchor in the original and
-- is an opaque per-row identifier like other D-package row ids in this
-- migration; validation matches those rows by content.
-- Two real bugs found and fixed during validation (2026-07-21):
-- (1) T-SQL ROUND() rounds halves away from zero, unlike PowerShell's
--     [math]::Round() which defaults to banker's rounding (ToEven); since
--     default-by-role durations are often exact multiples of 300s, this
--     hit the /600 tie case for the majority of D6 rows (also fixed in
--     25_build_likely_conflict_cleanup_plan.sql's own D6 segment, which
--     had the identical formula and the identical bug).
-- (2) bronze_failure_hotspots/bronze_execution_duration_by_item store
--     decimal fields as raw es-ES-locale text (comma decimal separator,
--     e.g. "365,667") from the original PS Export-Csv -- a bare
--     TRY_CAST(...AS FLOAT) silently returns NULL for those, wiping the
--     observed duration to 0. Fixed via TRY_CAST(REPLACE(x,',','.') AS
--     FLOAT).
CREATE OR ALTER PROCEDURE dbo.sp_build_d6_failure_duration_stabilization_package
AS
BEGIN

IF OBJECT_ID('dbo.silver_d6_failure_duration_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_failure_duration_queue;
IF OBJECT_ID('dbo.silver_d6_failure_hotspot_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_failure_hotspot_queue;
IF OBJECT_ID('dbo.silver_d6_duration_stabilization_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_duration_stabilization_queue;
IF OBJECT_ID('dbo.silver_d6_execution_evidence', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_execution_evidence;
IF OBJECT_ID('dbo.silver_d6_failure_duration_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_failure_duration_summary;
IF OBJECT_ID('dbo.silver_d6_stabilization_decision_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_stabilization_decision_template;
IF OBJECT_ID('dbo.silver_d6_readonly_operational_review_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_readonly_operational_review_targets;

IF OBJECT_ID('tempdb..#d6_cleanup') IS NOT NULL DROP TABLE #d6_cleanup;
SELECT item_key, priority_score, blocker_type
INTO #d6_cleanup
FROM (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, priority_score, blocker_type,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(item_qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_likely_conflict_cleanup_queue WHERE phase_id = 'D6'
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#failure_first') IS NOT NULL DROP TABLE #failure_first;
SELECT item_key, workspace_name, item_type, item_name, job_type, run_count, completed_count, failed_count,
    failure_rate, avg_duration_seconds, max_duration_seconds, latest_start_time, latest_end_time, last_status, recommendation_hint
INTO #failure_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key, workspace_name, item_type, item_name, job_type,
        TRY_CAST(run_count AS INT) AS run_count, TRY_CAST(completed_count AS INT) AS completed_count, TRY_CAST(failed_count AS INT) AS failed_count,
        TRY_CAST(REPLACE(failure_rate, ',', '.') AS FLOAT) AS failure_rate, TRY_CAST(REPLACE(avg_duration_seconds, ',', '.') AS FLOAT) AS avg_duration_seconds,
        TRY_CAST(REPLACE(max_duration_seconds, ',', '.') AS FLOAT) AS max_duration_seconds, latest_start_time, latest_end_time, last_status, recommendation_hint,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_failure_hotspots
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#duration_first') IS NOT NULL DROP TABLE #duration_first;
SELECT item_key, run_count, completed_count, failed_count, avg_duration_seconds, max_duration_seconds,
    latest_start_time, latest_end_time, last_status
INTO #duration_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key,
        TRY_CAST(run_count AS INT) AS run_count, TRY_CAST(completed_count AS INT) AS completed_count, TRY_CAST(failed_count AS INT) AS failed_count,
        TRY_CAST(REPLACE(avg_duration_seconds, ',', '.') AS FLOAT) AS avg_duration_seconds, TRY_CAST(REPLACE(max_duration_seconds, ',', '.') AS FLOAT) AS max_duration_seconds,
        latest_start_time, latest_end_time, last_status,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_execution_duration_by_item
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#candidates') IS NOT NULL DROP TABLE #candidates;
SELECT
    LOWER(LTRIM(RTRIM(qualified_name))) AS item_key, qualified_name, workspace_name, item_type, item_name, v2_status,
    ISNULL(original_risk_flags,'') AS original_risk_flags, ISNULL(duration_source,'') AS duration_source,
    estimated_duration_seconds, ISNULL(failed_count,0) AS failed_count, ISNULL(run_count,0) AS run_count,
    ISNULL(enabled_schedules,0) AS enabled_schedules, ISNULL(disabled_schedules,0) AS disabled_schedules,
    ISNULL(scheduled_count,0) AS scheduled_count, ISNULL(manual_count,0) AS manual_count, ISNULL(schedule_times,'') AS schedule_times,
    ISNULL(predecessor_count,0) AS predecessor_count, ISNULL(successor_count,0) AS successor_count,
    ISNULL(v2_recommended_next_action,'') AS v2_recommended_next_action
INTO #candidates
FROM dbo.silver_orchestration_v2_plan
WHERE v2_status = 'hold_failure_stabilization' OR ISNULL(original_risk_flags,'') LIKE '%duration_defaulted%';

IF OBJECT_ID('tempdb..#final') IS NOT NULL DROP TABLE #final;
SELECT
    'D6I' + RIGHT('0000' + CAST(ROW_NUMBER() OVER (ORDER BY ISNULL(dc.priority_score,0) DESC, LOWER(c.workspace_name), LOWER(c.item_type), LOWER(c.item_name)) AS VARCHAR(10)), 5) AS d6_id,
    ROW_NUMBER() OVER (ORDER BY ISNULL(dc.priority_score,0) DESC, LOWER(c.workspace_name), LOWER(c.item_type), LOWER(c.item_name)) AS seq,
    c.item_key, c.qualified_name, c.workspace_name, c.item_type, c.item_name, c.v2_status, c.original_risk_flags,
    c.duration_source, c.estimated_duration_seconds AS estimated_duration_seconds_raw,
    c.failed_count, c.run_count, c.enabled_schedules, c.disabled_schedules, c.scheduled_count, c.manual_count,
    c.schedule_times, c.predecessor_count, c.successor_count, c.v2_recommended_next_action,
    dc.priority_score AS cleanup_priority_score, dc.blocker_type AS cleanup_blocker_type,
    ff.workspace_name AS f_workspace_name, ff.item_type AS f_item_type, ff.item_name AS f_item_name, ff.job_type AS f_job_type,
    ff.run_count AS f_run_count, ff.completed_count AS f_completed_count, ff.failed_count AS f_failed_count,
    ff.failure_rate AS f_failure_rate, ff.avg_duration_seconds AS f_avg_duration_seconds, ff.max_duration_seconds AS f_max_duration_seconds,
    ff.latest_start_time AS f_latest_start_time, ff.latest_end_time AS f_latest_end_time, ff.last_status AS f_last_status,
    ff.recommendation_hint AS f_recommendation_hint,
    CASE WHEN ff.item_key IS NOT NULL THEN 1 ELSE 0 END AS has_failure_match,
    df.run_count AS d_run_count, df.completed_count AS d_completed_count, df.failed_count AS d_failed_count,
    df.avg_duration_seconds AS d_avg_duration_seconds, df.max_duration_seconds AS d_max_duration_seconds,
    df.latest_start_time AS d_latest_start_time, df.latest_end_time AS d_latest_end_time, df.last_status AS d_last_status,
    CASE WHEN df.item_key IS NOT NULL THEN 1 ELSE 0 END AS has_duration_match,
    (CASE WHEN c.run_count > 0 THEN ROUND(CAST(c.failed_count AS FLOAT) / c.run_count, 4) ELSE 0.0 END) AS failure_rate_from_plan,
    ISNULL(ff.failure_rate, 0.0) AS failure_rate_from_hotspot
INTO #final
FROM #candidates c
LEFT JOIN #d6_cleanup dc ON dc.item_key = c.item_key
LEFT JOIN #failure_first ff ON ff.item_key = c.item_key
LEFT JOIN #duration_first df ON df.item_key = c.item_key;

IF OBJECT_ID('tempdb..#computed') IS NOT NULL DROP TABLE #computed;
SELECT
    d6_id, seq, item_key, qualified_name, workspace_name, item_type, item_name, v2_status, original_risk_flags,
    duration_source, ISNULL(estimated_duration_seconds_raw, 0.0) AS estimated_duration_seconds,
    failed_count, run_count, enabled_schedules, disabled_schedules, scheduled_count, manual_count, schedule_times,
    predecessor_count, successor_count, v2_recommended_next_action, cleanup_priority_score, cleanup_blocker_type,
    f_workspace_name, f_item_type, f_item_name, f_job_type, f_run_count, f_completed_count, f_failed_count,
    f_failure_rate, f_avg_duration_seconds, f_max_duration_seconds, f_latest_start_time, f_latest_end_time, f_last_status,
    f_recommendation_hint, has_failure_match,
    ISNULL(d_run_count,0) AS d_run_count, ISNULL(d_completed_count,0) AS d_completed_count, ISNULL(d_failed_count,0) AS d_failed_count,
    ISNULL(d_avg_duration_seconds,0.0) AS d_avg_duration_seconds, ISNULL(d_max_duration_seconds,0.0) AS d_max_duration_seconds,
    d_latest_start_time, d_latest_end_time, d_last_status, has_duration_match,
    (CASE WHEN failure_rate_from_hotspot > 0 THEN failure_rate_from_hotspot ELSE failure_rate_from_plan END) AS failure_rate,
    (CASE WHEN v2_status = 'hold_failure_stabilization' AND (original_risk_flags LIKE '%duration_defaulted%' OR duration_source = 'default_by_role') THEN 'failure_and_duration'
          WHEN v2_status = 'hold_failure_stabilization' THEN 'failure_hotspot'
          WHEN original_risk_flags LIKE '%duration_defaulted%' OR duration_source = 'default_by_role' THEN 'duration_defaulted'
          ELSE 'duration_review' END) AS stabilization_type
INTO #computed
FROM #final;

IF OBJECT_ID('tempdb..#priced_base') IS NOT NULL DROP TABLE #priced_base;
-- Banker's rounding (MidpointRounding.ToEven), matching PowerShell's
-- [math]::Round() default -- unlike T-SQL's ROUND() which rounds halves
-- away from zero. Matters here since default-by-role durations are often
-- exact multiples of 300s, landing exactly on a .5 boundary at /600.
SELECT c2.*,
    CASE WHEN (c2.estimated_duration_seconds / 600.0) - FLOOR(c2.estimated_duration_seconds / 600.0) = 0.5
         THEN CASE WHEN CAST(FLOOR(c2.estimated_duration_seconds / 600.0) AS BIGINT) % 2 = 0
                   THEN CAST(FLOOR(c2.estimated_duration_seconds / 600.0) AS INT)
                   ELSE CAST(FLOOR(c2.estimated_duration_seconds / 600.0) AS INT) + 1 END
         ELSE CAST(ROUND(c2.estimated_duration_seconds / 600.0, 0) AS INT) END AS duration_rounded_sixths
INTO #priced_base
FROM #computed c2;

IF OBJECT_ID('tempdb..#priced') IS NOT NULL DROP TABLE #priced;
SELECT *,
    (CASE WHEN ISNULL(cleanup_priority_score,0) <> 0 THEN cleanup_priority_score
          ELSE 70 + failed_count + duration_rounded_sixths
               + (CASE WHEN duration_source = 'default_by_role' THEN 10 ELSE 0 END)
               + (CASE WHEN stabilization_type LIKE 'failure%' THEN 15 ELSE 0 END)
     END) AS priority_score,
    (CASE WHEN stabilization_type LIKE 'failure%' THEN
            (CASE WHEN duration_source = 'default_by_role' THEN 'failure_and_duration_review' ELSE 'failure_review' END)
          WHEN duration_source = 'default_by_role' THEN
            (CASE WHEN has_duration_match = 1 THEN 'duration_observed_but_plan_defaulted' ELSE 'duration_estimate_required' END)
          WHEN failure_rate > 0 THEN 'failure_review'
          ELSE 'manual_duration_review' END) AS decision_readiness,
    (CASE WHEN ISNULL(v2_recommended_next_action,'') <> '' THEN v2_recommended_next_action
          WHEN stabilization_type = 'failure_and_duration' THEN 'Review recent failures with the owner, decide whether the item belongs in the master orchestration, and replace the default duration with observed or approved evidence.'
          WHEN stabilization_type = 'failure_hotspot' THEN 'Stabilize failed runs before optimizing schedule, dependency order, or parallelism.'
          WHEN duration_source = 'default_by_role' AND has_duration_match = 1 THEN 'Use observed execution history to replace the default duration estimate, then rebuild orchestration waves.'
          WHEN duration_source = 'default_by_role' THEN 'Capture owner-approved duration or run-history evidence before using this item in timing optimization.'
          ELSE 'Review operational timing and keep this row blocked until failure/duration evidence is accepted.' END) AS recommended_action_raw
INTO #priced
FROM #priced_base;

SELECT
    d6_id, priority_score,
    CASE WHEN priority_score >= 100 THEN 'critical' WHEN priority_score >= 85 THEN 'high' WHEN priority_score >= 70 THEN 'medium' ELSE 'low' END AS priority_band,
    stabilization_type, decision_readiness, workspace_name, item_type, item_name, qualified_name AS item_qualified_name,
    v2_status, original_risk_flags, duration_source, estimated_duration_seconds,
    ISNULL(d_completed_count,0) AS observed_completed_count, ISNULL(d_avg_duration_seconds,0.0) AS observed_avg_duration_seconds,
    ISNULL(d_max_duration_seconds,0.0) AS observed_max_duration_seconds, run_count, failed_count, failure_rate,
    enabled_schedules, disabled_schedules, scheduled_count, manual_count, schedule_times, predecessor_count, successor_count,
    ISNULL(cleanup_blocker_type,'') AS cleanup_blocker_type,
    LEFT(LTRIM(RTRIM(recommended_action_raw)), 900) AS recommended_next_action,
    'Record a reviewed stabilization decision: failure stabilized or accepted, duration observed or owner-approved, or item explicitly excluded/blocked.' AS d6_gate_to_close
INTO dbo.silver_d6_failure_duration_queue
FROM #priced;

SELECT
    'D6F' + RIGHT('0000' + CAST(ROW_NUMBER() OVER (ORDER BY seq) AS VARCHAR(10)), 5) AS d6_failure_id,
    d6_id, priority_score,
    CASE WHEN priority_score >= 100 THEN 'critical' WHEN priority_score >= 85 THEN 'high' WHEN priority_score >= 70 THEN 'medium' ELSE 'low' END AS priority_band,
    f_workspace_name AS workspace_name, f_item_type AS item_type, f_item_name AS item_name, qualified_name AS item_qualified_name,
    f_job_type AS job_type, ISNULL(f_run_count,0) AS run_count, ISNULL(f_completed_count,0) AS completed_count,
    ISNULL(f_failed_count,0) AS failed_count, ISNULL(f_failure_rate,0.0) AS failure_rate,
    ISNULL(f_avg_duration_seconds,0.0) AS avg_duration_seconds, ISNULL(f_max_duration_seconds,0.0) AS max_duration_seconds,
    f_latest_start_time AS latest_start_time, f_latest_end_time AS latest_end_time, f_last_status AS last_status,
    f_recommendation_hint AS recommendation_hint,
    'Failure hotspot reviewed and either stabilized, excluded from orchestration, or accepted with owner evidence.' AS d6_gate_to_close
INTO dbo.silver_d6_failure_hotspot_queue
FROM #priced
WHERE has_failure_match = 1;

SELECT
    'D6D' + RIGHT('0000' + CAST(ROW_NUMBER() OVER (ORDER BY seq) AS VARCHAR(10)), 5) AS d6_duration_id,
    d6_id, priority_score,
    CASE WHEN priority_score >= 100 THEN 'critical' WHEN priority_score >= 85 THEN 'high' WHEN priority_score >= 70 THEN 'medium' ELSE 'low' END AS priority_band,
    workspace_name, item_type, item_name, qualified_name AS item_qualified_name, duration_source,
    estimated_duration_seconds AS current_estimated_duration_seconds,
    (CASE WHEN duration_source = 'observed_avg' THEN 'plan_uses_observed_average'
          WHEN duration_source = 'default_by_role' AND ISNULL(d_completed_count,0) > 0 THEN 'observed_history_available_but_plan_defaulted'
          WHEN duration_source = 'default_by_role' THEN 'owner_estimate_or_new_history_required'
          ELSE 'no_observed_duration' END) AS duration_evidence_status,
    ISNULL(d_run_count,0) AS observed_run_count, ISNULL(d_completed_count,0) AS observed_completed_count,
    ISNULL(d_failed_count,0) AS observed_failed_count, ISNULL(d_avg_duration_seconds,0.0) AS observed_avg_duration_seconds,
    ISNULL(d_max_duration_seconds,0.0) AS observed_max_duration_seconds,
    d_latest_start_time AS latest_start_time, d_latest_end_time AS latest_end_time, d_last_status AS last_status,
    LEFT(LTRIM(RTRIM(recommended_action_raw)), 900) AS recommended_next_action,
    'Duration estimate has observed run history or owner-approved evidence and orchestration waves are rebuilt.' AS d6_gate_to_close
INTO dbo.silver_d6_duration_stabilization_queue
FROM #priced;

SELECT
    d6_id, qualified_name AS item_qualified_name, workspace_name, item_type, item_name, stabilization_type, decision_readiness,
    v2_status AS current_v2_status, duration_source AS current_duration_source,
    estimated_duration_seconds AS current_estimated_duration_seconds, failure_rate AS current_failure_rate,
    '' AS proposed_failure_status, '' AS proposed_duration_seconds, '' AS proposed_duration_source,
    '' AS proposed_schedule_action, '' AS include_in_master_plan, '' AS blocked_reason, '' AS owner,
    '' AS confirmation_source, '' AS confirmation_evidence, '' AS reviewer, '' AS reviewed_at,
    'D6 template row. Use statuses such as failure_stabilized, failure_accepted, duration_observed, duration_owner_estimate, excluded_from_master_plan, or blocked_pending_owner.' AS notes
INTO dbo.silver_d6_stabilization_decision_template
FROM #priced;

SELECT
    d6_id, priority_score,
    CASE WHEN priority_score >= 100 THEN 'critical' WHEN priority_score >= 85 THEN 'high' WHEN priority_score >= 70 THEN 'medium' ELSE 'low' END AS priority_band,
    qualified_name AS item_qualified_name, stabilization_type, decision_readiness,
    'Review execution history, failure reason, schedule state, duration evidence, owner guidance, and deployment environment before selecting a D6 decision.' AS readonly_method,
    'analysis/d6_stabilization_decision_template.csv' AS template_path,
    'Read-only/manual review target. Do not update schedules, triggers, retries, or orchestration rules from this package alone.' AS notes
INTO dbo.silver_d6_readonly_operational_review_targets
FROM #priced;

-- ===========================================================================
-- Execution evidence.
-- ===========================================================================
IF OBJECT_ID('tempdb..#d6_id_rep') IS NOT NULL DROP TABLE #d6_id_rep;
SELECT item_key, d6_id
INTO #d6_id_rep
FROM (
    SELECT item_key, d6_id, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY seq DESC) AS rn
    FROM #priced
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#executions_matched') IS NOT NULL DROP TABLE #executions_matched;
SELECT
    ROW_NUMBER() OVER (ORDER BY LOWER(LTRIM(RTRIM(e.qualified_name))), LOWER(ISNULL(e.record_type,'')), ISNULL(e.start_time,'')) AS exec_seq,
    dr.d6_id, e.qualified_name AS item_qualified_name, e.record_type, e.workspace_name, e.item_type, e.item_name, e.job_type,
    e.trigger_type, e.schedule_enabled, e.scheduled_time, e.schedule_timezone, e.start_time, e.end_time, e.duration_seconds,
    e.status, ISNULL(e.failure_reason,'') AS failure_reason, e.source_system, ISNULL(e.evidence,'') AS evidence
INTO #executions_matched
FROM dbo.bronze_executions e
INNER JOIN #d6_id_rep dr ON dr.item_key = LOWER(LTRIM(RTRIM(e.qualified_name)));

SELECT
    'D6E' + RIGHT('000000' + CAST(exec_seq AS VARCHAR(10)), 6) AS d6_execution_id,
    d6_id, item_qualified_name, record_type, workspace_name, item_type, item_name, job_type, trigger_type,
    schedule_enabled, scheduled_time, schedule_timezone, start_time, end_time, duration_seconds, status,
    LEFT(LTRIM(RTRIM(failure_reason)), 1200) AS failure_reason, source_system,
    LEFT(LTRIM(RTRIM(evidence)), 1200) AS evidence
INTO dbo.silver_d6_execution_evidence
FROM #executions_matched;

-- ===========================================================================
-- Summary.
-- ===========================================================================
SELECT summary_scope, group_key, row_count, high_or_critical_count, max_priority_score, notes
INTO dbo.silver_d6_failure_duration_summary
FROM (
    SELECT 'total' AS summary_scope, 'D6 stabilization rows' AS group_key, COUNT(*) AS row_count,
        SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END) AS high_or_critical_count,
        ISNULL(MAX(priority_score),0) AS max_priority_score, 'Items requiring failure or duration stabilization.' AS notes
    FROM dbo.silver_d6_failure_duration_queue

    UNION ALL
    SELECT 'total', 'D6 failure hotspot rows', COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Failure hotspots joined from analysis/failure_hotspots.csv.'
    FROM dbo.silver_d6_failure_hotspot_queue

    UNION ALL
    SELECT 'total', 'D6 duration rows', COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Duration evidence rows for D6 items.'
    FROM dbo.silver_d6_duration_stabilization_queue

    UNION ALL
    SELECT 'total', 'D6 execution evidence rows', COUNT(*), 0, 0, 'Execution and schedule evidence rows attached to D6 items.'
    FROM dbo.silver_d6_execution_evidence

    UNION ALL
    SELECT 'stabilization_type', stabilization_type, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D6 rows grouped by stabilization type.'
    FROM dbo.silver_d6_failure_duration_queue GROUP BY stabilization_type

    UNION ALL
    SELECT 'decision_readiness', decision_readiness, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D6 rows grouped by next decision kind.'
    FROM dbo.silver_d6_failure_duration_queue GROUP BY decision_readiness

    UNION ALL
    SELECT 'v2_status', v2_status, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D6 rows grouped by current orchestration v2 status.'
    FROM dbo.silver_d6_failure_duration_queue GROUP BY v2_status

    UNION ALL
    SELECT 'duration_source', duration_source, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D6 rows grouped by duration source.'
    FROM dbo.silver_d6_failure_duration_queue GROUP BY duration_source

    UNION ALL
    SELECT 'item_type', item_type, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D6 rows grouped by item type.'
    FROM dbo.silver_d6_failure_duration_queue GROUP BY item_type
) s;

END
