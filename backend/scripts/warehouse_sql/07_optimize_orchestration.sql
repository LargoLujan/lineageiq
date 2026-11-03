-- Warehouse-native translation of backend/scripts/07_optimize_orchestration.ps1
-- (Phase 2 migration, 2026-07-21). Reads dbo.bronze_dependencies,
-- dbo.bronze_executions, dbo.bronze_execution_duration_by_item. No
-- recursion needed -- thresholds, aggregation, and a bounded (top-8 per
-- workspace) pairwise self-join for parallel candidates. The human-
-- readable action-plan markdown stays app-layer (not data).
--
-- The original script's final "phase7_governance" recommendation is a
-- fixed summary sentence rather than computed counts -- reproduced
-- verbatim here, per this migration's own rule of faithful translation
-- (see 39_d1_closure_control.sql and friends: never "fix" the original's
-- behavior without being asked to).
--
-- Locale gotcha (found live during validation): analysis/execution_
-- duration_by_item.csv's avg/max_duration_seconds are written by
-- PowerShell using the machine's current culture (es-ES on this host),
-- so fractional values land as "1630,5" not "1630.5". TRY_CAST fails
-- silently on the comma and collapses everything to 0/NULL, which
-- zeroed out every critical-path candidate on first deploy. Fixed by
-- REPLACE(col, ',', '.') before every TRY_CAST(...AS FLOAT) on these
-- two columns. No thousands-grouping in the source values, so a blind
-- comma->period replace is safe here.
CREATE OR ALTER PROCEDURE dbo.sp_optimize_orchestration
AS
BEGIN

IF OBJECT_ID('dbo.silver_critical_path_candidates', 'U') IS NOT NULL DROP TABLE dbo.silver_critical_path_candidates;
IF OBJECT_ID('dbo.silver_failure_hotspots', 'U') IS NOT NULL DROP TABLE dbo.silver_failure_hotspots;
IF OBJECT_ID('dbo.silver_manual_execution_candidates', 'U') IS NOT NULL DROP TABLE dbo.silver_manual_execution_candidates;
IF OBJECT_ID('dbo.silver_schedule_review_candidates', 'U') IS NOT NULL DROP TABLE dbo.silver_schedule_review_candidates;
IF OBJECT_ID('dbo.silver_orchestration_group_candidates', 'U') IS NOT NULL DROP TABLE dbo.silver_orchestration_group_candidates;
IF OBJECT_ID('dbo.silver_parallelism_candidates', 'U') IS NOT NULL DROP TABLE dbo.silver_parallelism_candidates;
IF OBJECT_ID('dbo.silver_orchestration_recommendations', 'U') IS NOT NULL DROP TABLE dbo.silver_orchestration_recommendations;

-- Critical path candidates -----------------------------------------------
SELECT
    ROW_NUMBER() OVER (ORDER BY ISNULL(TRY_CAST(REPLACE(max_duration_seconds, ',', '.') AS FLOAT), 0) DESC, ISNULL(TRY_CAST(REPLACE(avg_duration_seconds, ',', '.') AS FLOAT), 0) DESC) AS rank,
    workspace_name, item_name, item_type, qualified_name, job_type,
    ISNULL(TRY_CAST(run_count AS INT), 0) AS run_count,
    ISNULL(TRY_CAST(completed_count AS INT), 0) AS completed_count,
    ISNULL(TRY_CAST(failed_count AS INT), 0) AS failed_count,
    ISNULL(TRY_CAST(scheduled_count AS INT), 0) AS scheduled_count,
    ISNULL(TRY_CAST(manual_count AS INT), 0) AS manual_count,
    ISNULL(TRY_CAST(REPLACE(avg_duration_seconds, ',', '.') AS FLOAT), 0) AS avg_duration_seconds,
    ISNULL(TRY_CAST(REPLACE(max_duration_seconds, ',', '.') AS FLOAT), 0) AS max_duration_seconds,
    (SELECT COUNT(*) FROM dbo.bronze_dependencies d WHERE d.from_qualified_name = e.qualified_name) AS outgoing_dependencies,
    (SELECT COUNT(*) FROM dbo.bronze_dependencies d WHERE d.to_qualified_name = e.qualified_name) AS incoming_dependencies,
    'Review as critical-path candidate because runtime exceeds threshold.' AS recommendation_hint
INTO dbo.silver_critical_path_candidates
FROM dbo.bronze_execution_duration_by_item e
WHERE ISNULL(TRY_CAST(REPLACE(max_duration_seconds, ',', '.') AS FLOAT), 0) >= 3600 OR ISNULL(TRY_CAST(REPLACE(avg_duration_seconds, ',', '.') AS FLOAT), 0) >= 1800;

-- Failure hotspots ---------------------------------------------------------
SELECT
    ROW_NUMBER() OVER (ORDER BY failed_count DESC, failure_rate DESC, max_duration_seconds DESC) AS rank,
    workspace_name, item_name, item_type, qualified_name, job_type, run_count, completed_count,
    failed_count, failure_rate, avg_duration_seconds, max_duration_seconds,
    latest_start_time, latest_end_time, last_status,
    'Stabilize before optimizing schedule or parallelism.' AS recommendation_hint
INTO dbo.silver_failure_hotspots
FROM (
    SELECT
        workspace_name, item_name, item_type, qualified_name, job_type,
        CASE WHEN ISNULL(TRY_CAST(run_count AS INT), 0) < 1 THEN 1 ELSE TRY_CAST(run_count AS INT) END AS run_count,
        ISNULL(TRY_CAST(completed_count AS INT), 0) AS completed_count,
        ISNULL(TRY_CAST(failed_count AS INT), 0) AS failed_count,
        -- CAST to FLOAT (not left as the implicit DECIMAL that "1.0 * int"
        -- produces) so CAST(...AS VARCHAR) below matches PowerShell's
        -- [math]::Round($failedCount / $runCount, 4) double formatting --
        -- "1", "0.8" -- instead of padding to "1.000000000000".
        ROUND(CAST(ISNULL(TRY_CAST(failed_count AS INT), 0) AS FLOAT) / (CASE WHEN ISNULL(TRY_CAST(run_count AS INT), 0) < 1 THEN 1 ELSE TRY_CAST(run_count AS INT) END), 4) AS failure_rate,
        ISNULL(TRY_CAST(REPLACE(avg_duration_seconds, ',', '.') AS FLOAT), 0) AS avg_duration_seconds,
        ISNULL(TRY_CAST(REPLACE(max_duration_seconds, ',', '.') AS FLOAT), 0) AS max_duration_seconds,
        latest_start_time, latest_end_time, last_status
    FROM dbo.bronze_execution_duration_by_item
    WHERE ISNULL(TRY_CAST(failed_count AS INT), 0) >= 3
) f;

-- Manual execution candidates ----------------------------------------------
SELECT
    ROW_NUMBER() OVER (ORDER BY manual_count DESC, max_duration_seconds DESC) AS rank,
    workspace_name, item_name, item_type, qualified_name, job_type, run_count, manual_count,
    scheduled_count, failed_count, avg_duration_seconds, max_duration_seconds,
    ISNULL(sc.enabled, 0) AS enabled_schedules,
    'Repeated manual execution candidate for controlled orchestration or schedule.' AS recommendation_hint
INTO dbo.silver_manual_execution_candidates
FROM (
    SELECT workspace_name, item_name, item_type, qualified_name, job_type,
        ISNULL(TRY_CAST(run_count AS INT), 0) AS run_count,
        ISNULL(TRY_CAST(manual_count AS INT), 0) AS manual_count,
        ISNULL(TRY_CAST(scheduled_count AS INT), 0) AS scheduled_count,
        ISNULL(TRY_CAST(failed_count AS INT), 0) AS failed_count,
        ISNULL(TRY_CAST(REPLACE(avg_duration_seconds, ',', '.') AS FLOAT), 0) AS avg_duration_seconds,
        ISNULL(TRY_CAST(REPLACE(max_duration_seconds, ',', '.') AS FLOAT), 0) AS max_duration_seconds
    FROM dbo.bronze_execution_duration_by_item
    WHERE ISNULL(TRY_CAST(manual_count AS INT), 0) >= 10 AND ISNULL(TRY_CAST(scheduled_count AS INT), 0) = 0
) m
LEFT JOIN (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS qn, SUM(CASE WHEN schedule_enabled = 'True' THEN 1 ELSE 0 END) AS enabled
    FROM dbo.bronze_executions WHERE record_type = 'schedule' AND qualified_name <> '' GROUP BY LOWER(LTRIM(RTRIM(qualified_name)))
) sc ON sc.qn = LOWER(LTRIM(RTRIM(m.qualified_name)));

-- Schedule review candidates ------------------------------------------------
;WITH schedules AS (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS qn, qualified_name,
        SUM(CASE WHEN schedule_enabled = 'True' THEN 1 ELSE 0 END) AS enabled,
        SUM(CASE WHEN schedule_enabled <> 'True' THEN 1 ELSE 0 END) AS disabled
    FROM dbo.bronze_executions WHERE record_type = 'schedule' AND qualified_name <> ''
    GROUP BY LOWER(LTRIM(RTRIM(qualified_name))), qualified_name
),
schedule_qn_first AS (
    SELECT qn, MIN(qualified_name) AS qualified_name FROM schedules GROUP BY qn
),
times_distinct AS (SELECT DISTINCT LOWER(LTRIM(RTRIM(qualified_name))) AS qn, scheduled_time FROM dbo.bronze_executions WHERE record_type = 'schedule' AND scheduled_time <> ''),
times_agg AS (SELECT qn, STRING_AGG(scheduled_time, '; ') WITHIN GROUP (ORDER BY scheduled_time) AS times FROM times_distinct GROUP BY qn),
zones_distinct AS (SELECT DISTINCT LOWER(LTRIM(RTRIM(qualified_name))) AS qn, schedule_timezone FROM dbo.bronze_executions WHERE record_type = 'schedule' AND schedule_timezone <> ''),
zones_agg AS (SELECT qn, STRING_AGG(schedule_timezone, '; ') WITHIN GROUP (ORDER BY schedule_timezone) AS zones FROM zones_distinct GROUP BY qn),
duration_first AS (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS qn, MIN(qualified_name) AS any_qn
    FROM dbo.bronze_execution_duration_by_item WHERE qualified_name <> '' GROUP BY LOWER(LTRIM(RTRIM(qualified_name)))
)
SELECT
    f.qualified_name,
    -- Fallback matches PowerShell's ($qualifiedName -split " / ")[0] --
    -- first segment before the first " / ", or the whole string if there
    -- is none (CHARINDEX against qualified_name + ' / ' guarantees a hit).
    ISNULL(NULLIF(d.workspace_name, ''), LEFT(f.qualified_name, CHARINDEX(' / ', f.qualified_name + ' / ') - 1)) AS workspace_name,
    -- Fallback matches ($qualifiedName -split " / " | Select-Object -Last 1).
    ISNULL(NULLIF(d.item_name, ''), RIGHT(f.qualified_name, CHARINDEX(' / ', REVERSE(f.qualified_name) + ' / ') - 1)) AS item_name,
    ISNULL(d.item_type, '') AS item_type,
    s.enabled AS enabled_schedules, s.disabled AS disabled_schedules,
    ISNULL(t.times, '') AS schedule_times, ISNULL(z.zones, '') AS schedule_timezones,
    ISNULL(TRY_CAST(d.run_count AS INT), 0) AS run_count,
    ISNULL(TRY_CAST(d.failed_count AS INT), 0) AS failed_count,
    ISNULL(TRY_CAST(REPLACE(d.avg_duration_seconds, ',', '.') AS FLOAT), 0) AS avg_duration_seconds,
    'Review disabled schedules and confirm only intentional schedules are enabled.' AS recommendation_hint
INTO dbo.silver_schedule_review_candidates
FROM schedules s
JOIN schedule_qn_first f ON f.qn = s.qn
LEFT JOIN times_agg t ON t.qn = s.qn
LEFT JOIN zones_agg z ON z.qn = s.qn
LEFT JOIN dbo.bronze_execution_duration_by_item d ON LOWER(LTRIM(RTRIM(d.qualified_name))) = s.qn;

-- Orchestration group candidates (fan-out via 'executes') -------------------
;WITH executes AS (
    SELECT DISTINCT from_qualified_name, to_qualified_name
    FROM dbo.bronze_dependencies WHERE relationship_type = 'executes' AND from_qualified_name <> '' AND to_qualified_name <> ''
),
targets_distinct AS (SELECT DISTINCT from_qualified_name, to_qualified_name FROM executes),
targets_ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY from_qualified_name ORDER BY to_qualified_name) AS rn FROM targets_distinct),
targets_agg AS (
    SELECT from_qualified_name, COUNT(*) AS executes_count,
        STRING_AGG(CASE WHEN rn <= 200 THEN to_qualified_name END, '; ') WITHIN GROUP (ORDER BY to_qualified_name) AS executed_items
    FROM targets_ranked GROUP BY from_qualified_name
)
SELECT
    ta.from_qualified_name AS source_qualified_name,
    -- Same "( -split ' / ')[0]" / "Select-Object -Last 1" fallback as
    -- schedule_review_candidates above, for when there's no execution-
    -- duration match to borrow workspace_name/item_name from.
    ISNULL(NULLIF(d.workspace_name, ''), LEFT(ta.from_qualified_name, CHARINDEX(' / ', ta.from_qualified_name + ' / ') - 1)) AS workspace_name,
    ISNULL(NULLIF(d.item_name, ''), RIGHT(ta.from_qualified_name, CHARINDEX(' / ', REVERSE(ta.from_qualified_name) + ' / ') - 1)) AS item_name,
    ISNULL(d.item_type, '') AS item_type,
    ta.executes_count,
    CASE WHEN LEN(ISNULL(ta.executed_items,'')) > 1600 THEN LEFT(ta.executed_items, 1597) + '...' ELSE ISNULL(ta.executed_items,'') END AS executed_items,
    ISNULL(TRY_CAST(d.run_count AS INT), 0) AS run_count,
    ISNULL(TRY_CAST(d.failed_count AS INT), 0) AS failed_count,
    ISNULL(TRY_CAST(d.scheduled_count AS INT), 0) AS scheduled_count,
    ISNULL(TRY_CAST(d.manual_count AS INT), 0) AS manual_count,
    ISNULL(TRY_CAST(REPLACE(d.avg_duration_seconds, ',', '.') AS FLOAT), 0) AS avg_duration_seconds,
    ISNULL(TRY_CAST(REPLACE(d.max_duration_seconds, ',', '.') AS FLOAT), 0) AS max_duration_seconds,
    'Review fan-out for parallel-safe branches and explicit dependency ordering.' AS recommendation_hint
INTO dbo.silver_orchestration_group_candidates
FROM targets_agg ta
LEFT JOIN dbo.bronze_execution_duration_by_item d ON LOWER(LTRIM(RTRIM(d.qualified_name))) = LOWER(LTRIM(RTRIM(ta.from_qualified_name)))
WHERE ta.executes_count >= 3;

-- Parallelism candidates: bounded pairwise self-join ------------------------
;WITH manual_zero_fail AS (
    SELECT workspace_name, qualified_name, item_type, manual_count, max_duration_seconds
    FROM dbo.silver_manual_execution_candidates WHERE failed_count = 0
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY workspace_name ORDER BY max_duration_seconds DESC) AS rn
    FROM manual_zero_fail
),
top8 AS (SELECT * FROM ranked WHERE rn <= 8),
pairs AS (
    SELECT a.workspace_name, a.qualified_name AS candidate_a, b.qualified_name AS candidate_b,
        a.item_type AS item_type_a, b.item_type AS item_type_b,
        a.manual_count AS manual_count_a, b.manual_count AS manual_count_b,
        a.max_duration_seconds AS max_duration_a_seconds, b.max_duration_seconds AS max_duration_b_seconds
    FROM top8 a
    JOIN top8 b ON b.workspace_name = a.workspace_name AND a.rn < b.rn
),
pairs_no_dep AS (
    SELECT p.* FROM pairs p
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.bronze_dependencies d
        WHERE (d.from_qualified_name = p.candidate_a AND d.to_qualified_name = p.candidate_b)
           OR (d.from_qualified_name = p.candidate_b AND d.to_qualified_name = p.candidate_a)
    )
),
final_pairs AS (
    SELECT *, IIF(max_duration_a_seconds < max_duration_b_seconds, max_duration_a_seconds, max_duration_b_seconds) AS expected_parallel_window_seconds
    FROM pairs_no_dep
)
SELECT TOP 100
    workspace_name, candidate_a, candidate_b, item_type_a, item_type_b, manual_count_a, manual_count_b,
    max_duration_a_seconds, max_duration_b_seconds, expected_parallel_window_seconds,
    'No indexed dependency edge exists between these repeated manual jobs in the same workspace.' AS evidence,
    'Candidate only; validate reads/writes before parallel execution.' AS recommendation_hint
INTO dbo.silver_parallelism_candidates
FROM final_pairs
ORDER BY expected_parallel_window_seconds DESC, manual_count_a DESC, manual_count_b DESC;

-- Recommendations (global sequential REC-### across all categories) --------
;WITH cat1 AS (
    SELECT 1 AS cat_order, rank AS row_order,
        qualified_name AS scope_name, 'critical_path_candidate' AS recommendation_type,
        'Runtime is high: avg=' + CAST(avg_duration_seconds AS VARCHAR(30)) + 's, max=' + CAST(max_duration_seconds AS VARCHAR(30)) + 's, runs=' + CAST(run_count AS VARCHAR(20)) + ', manual=' + CAST(manual_count AS VARCHAR(20)) + ', scheduled=' + CAST(scheduled_count AS VARCHAR(20)) + '.' AS current_state,
        'Profile this item as part of the critical path. Split independent work, cache reusable data, or move independent child work into parallel branches only after dependency review.' AS proposed_state,
        'Reduces the longest observed execution windows and can shorten downstream idle time.' AS expected_benefit,
        'Parallelizing without code-level read/write validation can create incomplete data or race conditions.' AS risk,
        'analysis/execution_duration_by_item.csv rank ' + CAST(rank AS VARCHAR(20)) + '; incoming dependencies=' + CAST(incoming_dependencies AS VARCHAR(20)) + '; outgoing dependencies=' + CAST(outgoing_dependencies AS VARCHAR(20)) + '.' AS evidence,
        'Open the item in Fabric and review activities/notebook cells/source tables; approve a non-prod timing test before changing production orchestration.' AS next_human_step
    FROM dbo.silver_critical_path_candidates WHERE rank <= 20
),
cat2 (cat_order, row_order, scope_name, recommendation_type, current_state, proposed_state, expected_benefit, risk, evidence, next_human_step) AS (
    SELECT 2, rank, qualified_name, 'stabilize_failure_hotspot',
        'Failures observed: failed=' + CAST(failed_count AS VARCHAR(20)) + ', runs=' + CAST(run_count AS VARCHAR(20)) + ', failure_rate=' + CAST(failure_rate AS VARCHAR(30)) + ', last_status=' + ISNULL(last_status,'') + '.',
        'Stabilize failure causes before adding parallelism or tightening schedule windows.',
        'Improves reliability and prevents optimized orchestration from amplifying known failures.',
        'Changing schedules without fixing failures can increase retries, contention, and downstream stale data.',
        'analysis/failure_hotspots.csv; latest_start=' + ISNULL(latest_start_time,'') + '; latest_end=' + ISNULL(latest_end_time,'') + '.',
        'Review recent failed run details in Fabric Monitoring Hub, identify root cause, then approve retry/error-handling changes if needed.'
    FROM dbo.silver_failure_hotspots WHERE rank <= 20
),
cat3 (cat_order, row_order, scope_name, recommendation_type, current_state, proposed_state, expected_benefit, risk, evidence, next_human_step) AS (
    SELECT 3, rank, qualified_name, 'convert_repeated_manual_to_orchestrated',
        'Repeated manual execution: manual=' + CAST(manual_count AS VARCHAR(20)) + ', scheduled=' + CAST(scheduled_count AS VARCHAR(20)) + ', enabled_schedules=' + CAST(enabled_schedules AS VARCHAR(20)) + ', max_duration=' + CAST(max_duration_seconds AS VARCHAR(30)) + 's.',
        'Evaluate whether this should be called by a controlled orchestration pipeline or scheduled trigger with explicit upstream readiness checks.',
        'Reduces manual intervention and makes execution order auditable.',
        'A schedule without upstream dependency checks can start before source data is ready.',
        'analysis/manual_execution_candidates.csv.',
        'Confirm business owner, expected cadence, and upstream source readiness before proposing a schedule or pipeline activity.'
    FROM dbo.silver_manual_execution_candidates WHERE rank <= 20
),
cat4_base AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY executes_count DESC, max_duration_seconds DESC) AS rn
    FROM dbo.silver_orchestration_group_candidates
),
cat4 (cat_order, row_order, scope_name, recommendation_type, current_state, proposed_state, expected_benefit, risk, evidence, next_human_step) AS (
    SELECT 4, rn, source_qualified_name,
        'review_orchestration_fanout',
        'This orchestration source executes ' + CAST(executes_count AS VARCHAR(20)) + ' downstream items; failures=' + CAST(failed_count AS VARCHAR(20)) + ', max_duration=' + CAST(max_duration_seconds AS VARCHAR(30)) + 's.',
        'Review child activities and classify them as must-run-before, can-run-parallel, or optional/retryable; then design explicit branches.',
        'Can reduce idle time and improve observability of multi-step orchestration.',
        'Some fan-out children may write to shared tables or depend on implicit state not visible in the current graph.',
        'analysis/orchestration_group_candidates.csv; executed_items=' + ISNULL(executed_items,'') + '.',
        'Open pipeline/activity graph and validate child dependencies with the technical owner before changing branch order.'
    FROM cat4_base WHERE rn <= 20
),
cat5 (cat_order, row_order, scope_name, recommendation_type, current_state, proposed_state, expected_benefit, risk, evidence, next_human_step) AS (
    SELECT 5, 1,
        'All Fabric execution targets', 'review_disabled_schedules',
        CAST((SELECT COUNT(*) FROM dbo.silver_schedule_review_candidates WHERE disabled_schedules > 0) AS VARCHAR(20)) + ' items have disabled schedule records; total disabled schedules=' + CAST((SELECT COUNT(*) FROM dbo.bronze_executions WHERE record_type = 'schedule' AND schedule_enabled = 'False') AS VARCHAR(20)) + '.',
        'Confirm disabled schedules are intentional, especially for semantic models serving reports and pipelines with downstream dependencies.',
        'Avoids silent non-refresh and stale downstream reports.',
        'Blindly enabling schedules can duplicate work or conflict with manual/orchestrated runs.',
        'analysis/schedule_review_candidates.csv and index/executions.csv.',
        'Review disabled schedule candidates with workspace owners; only approve enabling when cadence and upstream readiness are confirmed.'
    WHERE (SELECT COUNT(*) FROM dbo.silver_schedule_review_candidates WHERE disabled_schedules > 0) > 0
),
cat6_base AS (SELECT *, ROW_NUMBER() OVER (ORDER BY expected_parallel_window_seconds DESC, manual_count_a DESC, manual_count_b DESC) AS rn FROM dbo.silver_parallelism_candidates),
cat6 (cat_order, row_order, scope_name, recommendation_type, current_state, proposed_state, expected_benefit, risk, evidence, next_human_step) AS (
    SELECT 6, rn, workspace_name, 'candidate_parallel_execution',
        'Two repeated manual jobs in the same workspace have no indexed dependency edge: A=' + candidate_a + '; B=' + candidate_b + '.',
        'Test parallel execution in non-production only after validating that they do not write to the same tables/files or depend on shared mutable state.',
        'Potentially saves up to about ' + CAST(expected_parallel_window_seconds AS VARCHAR(30)) + 's in wall-clock time for this pair.',
        'The graph does not yet include all notebook code-level reads/writes, so this is a candidate, not approval.',
        'analysis/parallelism_candidates.csv.',
        'Inspect both item definitions/code and run a controlled non-prod parallel timing test before production change.'
    FROM cat6_base WHERE rn <= 10
),
cat7 (cat_order, row_order, scope_name, recommendation_type, current_state, proposed_state, expected_benefit, risk, evidence, next_human_step) AS (
    SELECT 7, 1, 'Overall orchestration program', 'phase7_governance',
        'The graph still has likely (unconfirmed) dependencies, Phase 4 item-analysis gaps, and Phase 6 timing gaps.',
        'Use recommendations as a review backlog. Do not apply production orchestration changes until likely dependencies and gaps are reviewed by item owners.',
        'Keeps optimization cost-aware and avoids incomplete downstream data.',
        'Acting on candidate relationships without human review can cause missed refreshes or unsafe parallelism.',
        'index/dependencies.csv, index/unresolved.md, analysis/execution_query_gaps.csv.',
        'Prioritize top critical-path and failure-hotspot rows, then approve a scoped non-prod pilot.'
),
all_recs AS (
    SELECT * FROM cat1 UNION ALL SELECT * FROM cat2 UNION ALL SELECT * FROM cat3 UNION ALL SELECT * FROM cat4
    UNION ALL SELECT * FROM cat5 UNION ALL SELECT * FROM cat6 UNION ALL SELECT * FROM cat7
)
SELECT
    'REC-' + RIGHT('000' + CAST(ROW_NUMBER() OVER (ORDER BY cat_order, row_order) AS VARCHAR(10)), 3) AS recommendation_id,
    LEFT(scope_name, 260) AS scope_name, recommendation_type,
    LEFT(current_state, 900) AS current_state, LEFT(proposed_state, 900) AS proposed_state,
    LEFT(expected_benefit, 700) AS expected_benefit, LEFT(risk, 700) AS risk,
    LEFT(evidence, 900) AS evidence, LEFT(next_human_step, 700) AS next_human_step,
    'draft_human_review' AS status
INTO dbo.silver_orchestration_recommendations
FROM all_recs;

END
