-- Warehouse-native translation of backend/scripts/44_build_d6_closure_control.ps1
-- (SQL migration). Reads dbo.bronze_d6_failure_duration_queue,
-- dbo.bronze_d6_failure_hotspot_queue, dbo.bronze_d6_duration_stabilization_queue,
-- dbo.bronze_d6_execution_evidence.
--
-- Like D5: no synthetic ID assigned to control rows (d6_id passed through
-- from the source queue). failure/duration target tables EXPAND to one row
-- per failure/duration record (not one per D6 item) -- a real one-to-many
-- fan-out, unlike D1-D4's one-row-per-source-row shape.
CREATE OR ALTER PROCEDURE dbo.sp_build_d6_closure_control
AS
BEGIN

IF OBJECT_ID('tempdb..#d6_control') IS NOT NULL DROP TABLE #d6_control;
IF OBJECT_ID('dbo.silver_d6_closure_control_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_closure_control_queue;
IF OBJECT_ID('dbo.silver_d6_failure_stabilization_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_failure_stabilization_targets;
IF OBJECT_ID('dbo.silver_d6_duration_evidence_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_duration_evidence_targets;
IF OBJECT_ID('dbo.silver_d6_observed_duration_candidates', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_observed_duration_candidates;
IF OBJECT_ID('dbo.silver_d6_owner_estimate_required_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_owner_estimate_required_queue;
IF OBJECT_ID('dbo.silver_d6_operational_decision_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_operational_decision_template;
IF OBJECT_ID('dbo.silver_d6_external_readonly_action_plan', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_external_readonly_action_plan;
IF OBJECT_ID('dbo.silver_d6_closure_control_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d6_closure_control_summary;

;WITH failure_ids_distinct AS (SELECT DISTINCT d6_id, d6_failure_id FROM dbo.bronze_d6_failure_hotspot_queue WHERE d6_failure_id <> ''),
failure_ids_ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY d6_id ORDER BY d6_failure_id) AS rn FROM failure_ids_distinct),
failure_ids_agg AS (SELECT d6_id, STRING_AGG(d6_failure_id, '; ') WITHIN GROUP (ORDER BY d6_failure_id) AS failure_target_ids FROM failure_ids_ranked WHERE rn <= 30 GROUP BY d6_id),
duration_ids_distinct AS (SELECT DISTINCT d6_id, d6_duration_id FROM dbo.bronze_d6_duration_stabilization_queue WHERE d6_duration_id <> ''),
duration_ids_ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY d6_id ORDER BY d6_duration_id) AS rn FROM duration_ids_distinct),
duration_ids_agg AS (SELECT d6_id, STRING_AGG(d6_duration_id, '; ') WITHIN GROUP (ORDER BY d6_duration_id) AS duration_target_ids FROM duration_ids_ranked WHERE rn <= 30 GROUP BY d6_id),
exec_count AS (SELECT d6_id, COUNT(*) AS execution_evidence_count FROM dbo.bronze_d6_execution_evidence GROUP BY d6_id),
status_counts AS (SELECT d6_id, status AS val, COUNT(*) AS cnt FROM dbo.bronze_d6_execution_evidence WHERE status <> '' GROUP BY d6_id, status),
status_capped AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY d6_id ORDER BY cnt DESC, val) AS crn FROM status_counts),
status_split AS (SELECT d6_id, STRING_AGG(val + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY cnt DESC, val) AS execution_status_split FROM status_capped WHERE crn <= 30 GROUP BY d6_id),
jobtype_distinct AS (SELECT DISTINCT d6_id, job_type FROM dbo.bronze_d6_execution_evidence WHERE job_type <> ''),
jobtype_ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY d6_id ORDER BY job_type) AS rn FROM jobtype_distinct),
jobtype_agg AS (SELECT d6_id, STRING_AGG(job_type, '; ') WITHIN GROUP (ORDER BY job_type) AS execution_job_types FROM jobtype_ranked WHERE rn <= 10 GROUP BY d6_id),
trigtype_distinct AS (SELECT DISTINCT d6_id, trigger_type FROM dbo.bronze_d6_execution_evidence WHERE trigger_type <> ''),
trigtype_ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY d6_id ORDER BY trigger_type) AS rn FROM trigtype_distinct),
trigtype_agg AS (SELECT d6_id, STRING_AGG(trigger_type, '; ') WITHIN GROUP (ORDER BY trigger_type) AS execution_trigger_types FROM trigtype_ranked WHERE rn <= 10 GROUP BY d6_id),
failreason_distinct AS (SELECT DISTINCT d6_id, failure_reason FROM dbo.bronze_d6_execution_evidence WHERE failure_reason <> ''),
failreason_ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY d6_id ORDER BY failure_reason) AS rn FROM failreason_distinct),
failreason_agg AS (SELECT d6_id, STRING_AGG(failure_reason, '; ') WITHIN GROUP (ORDER BY failure_reason) AS failure_reason_sample FROM failreason_ranked WHERE rn <= 4 GROUP BY d6_id),
classified AS (
    SELECT
        r.*,
        CASE
            WHEN r.stabilization_type = 'failure_and_duration' THEN 'failure_and_duration_review_required'
            WHEN r.stabilization_type = 'failure_hotspot' THEN 'failure_stabilization_review_required'
            WHEN r.duration_source = 'default_by_role' AND ISNULL(TRY_CAST(r.observed_completed_count AS FLOAT), 0) > 0 THEN 'observed_duration_candidate'
            WHEN r.duration_source = 'default_by_role' THEN 'owner_duration_estimate_required'
            ELSE 'manual_duration_review_required'
        END AS closure_opportunity,
        ISNULL(fia.failure_target_ids, '') AS failure_target_ids,
        ISNULL(dia.duration_target_ids, '') AS duration_target_ids,
        ISNULL(ec.execution_evidence_count, 0) AS execution_evidence_count,
        ISNULL(ss.execution_status_split, '') AS execution_status_split,
        ISNULL(jt.execution_job_types, '') AS execution_job_types,
        ISNULL(tt.execution_trigger_types, '') AS execution_trigger_types,
        CASE WHEN LEN(ISNULL(fr.failure_reason_sample,'')) > 1200 THEN LEFT(fr.failure_reason_sample, 1197) + '...' ELSE ISNULL(fr.failure_reason_sample,'') END AS failure_reason_sample
    FROM dbo.bronze_d6_failure_duration_queue r
    LEFT JOIN failure_ids_agg fia ON fia.d6_id = r.d6_id
    LEFT JOIN duration_ids_agg dia ON dia.d6_id = r.d6_id
    LEFT JOIN exec_count ec ON ec.d6_id = r.d6_id
    LEFT JOIN status_split ss ON ss.d6_id = r.d6_id
    LEFT JOIN jobtype_agg jt ON jt.d6_id = r.d6_id
    LEFT JOIN trigtype_agg tt ON tt.d6_id = r.d6_id
    LEFT JOIN failreason_agg fr ON fr.d6_id = r.d6_id
)
SELECT
    d6_id, priority_score, priority_band, closure_opportunity, stabilization_type,
    decision_readiness, workspace_name, item_type, item_name, item_qualified_name,
    v2_status, original_risk_flags, duration_source, estimated_duration_seconds,
    observed_completed_count, observed_avg_duration_seconds, observed_max_duration_seconds,
    run_count, failed_count, failure_rate, enabled_schedules, disabled_schedules,
    scheduled_count, manual_count, predecessor_count, successor_count,
    failure_target_ids, duration_target_ids, execution_evidence_count, execution_status_split,
    execution_job_types, execution_trigger_types, failure_reason_sample,
    CASE closure_opportunity
        WHEN 'failure_and_duration_review_required' THEN 'Review failed executions first, then record failure_stabilized or failure_accepted plus duration_observed or duration_owner_estimate before orchestration promotion.'
        WHEN 'failure_stabilization_review_required' THEN 'Review failed-run evidence and decide failure_stabilized, failure_accepted, excluded_from_master_plan, or blocked_pending_owner.'
        WHEN 'observed_duration_candidate' THEN 'Use local completed-run evidence to propose duration_observed, preferably with owner acceptance for high-priority rows.'
        WHEN 'owner_duration_estimate_required' THEN 'Request owner-approved duration or wait for new successful run history before using this row in orchestration timing.'
        ELSE 'Review timing evidence manually and record an explicit D6 decision before promotion.'
    END AS recommended_d6_decision,
    CASE closure_opportunity
        WHEN 'failure_and_duration_review_required' THEN 'Inspect local failed-run evidence, owner notes, and recent successful runs if available; do not optimize schedule until both failure and duration are accepted.'
        WHEN 'failure_stabilization_review_required' THEN 'Inspect failure trend, latest status, schedule intent, retry behavior, and owner evidence before accepting or excluding the item.'
        WHEN 'observed_duration_candidate' THEN 'Inspect completed-run history and decide whether observed average, max, or owner-approved percentile should replace the default duration.'
        WHEN 'owner_duration_estimate_required' THEN 'Ask the owner for expected duration or capture a successful non-production/production run; keep default duration marked weak until then.'
        ELSE 'Review local execution evidence and owner evidence before selecting a D6 decision.'
    END AS readonly_action,
    'analysis/d6_operational_decision_template.csv' AS decision_template_path
INTO #d6_control
FROM classified;

SELECT * INTO dbo.silver_d6_closure_control_queue FROM #d6_control;

SELECT
    f.d6_failure_id, f.d6_id, f.priority_score, f.priority_band, c.closure_opportunity,
    f.workspace_name, f.item_type, f.item_name, f.item_qualified_name, f.job_type,
    f.run_count, f.completed_count, f.failed_count, f.failure_rate, f.avg_duration_seconds,
    f.max_duration_seconds, f.latest_start_time, f.latest_end_time, f.last_status,
    c.recommended_d6_decision AS recommended_failure_decision,
    'analysis/d6_operational_decision_template.csv' AS decision_template_path
INTO dbo.silver_d6_failure_stabilization_targets
FROM dbo.bronze_d6_failure_hotspot_queue f
JOIN #d6_control c ON c.d6_id = f.d6_id;

SELECT
    d.d6_duration_id, d.d6_id, d.priority_score, d.priority_band, c.closure_opportunity,
    d.workspace_name, d.item_type, d.item_name, d.item_qualified_name, d.duration_source,
    d.current_estimated_duration_seconds, d.duration_evidence_status, d.observed_run_count,
    d.observed_completed_count, d.observed_failed_count, d.observed_avg_duration_seconds,
    d.observed_max_duration_seconds, d.latest_start_time, d.latest_end_time, d.last_status,
    c.recommended_d6_decision AS recommended_duration_decision,
    'analysis/d6_operational_decision_template.csv' AS decision_template_path
INTO dbo.silver_d6_duration_evidence_targets
FROM dbo.bronze_d6_duration_stabilization_queue d
JOIN #d6_control c ON c.d6_id = d.d6_id;

SELECT * INTO dbo.silver_d6_observed_duration_candidates FROM dbo.silver_d6_duration_evidence_targets
WHERE duration_source = 'default_by_role' AND ISNULL(TRY_CAST(observed_completed_count AS FLOAT), 0) > 0;

SELECT * INTO dbo.silver_d6_owner_estimate_required_queue FROM dbo.silver_d6_duration_evidence_targets
WHERE duration_source = 'default_by_role' AND ISNULL(TRY_CAST(observed_completed_count AS FLOAT), 0) = 0;

SELECT
    d6_id, item_qualified_name, stabilization_type, closure_opportunity,
    CASE WHEN closure_opportunity IN ('failure_and_duration_review_required', 'failure_stabilization_review_required') THEN 'failure_stabilized_or_failure_accepted' ELSE '' END AS proposed_failure_status,
    '' AS proposed_duration_seconds,
    CASE
        WHEN closure_opportunity = 'observed_duration_candidate' THEN 'duration_observed'
        WHEN duration_source = 'default_by_role' THEN 'duration_owner_estimate'
        ELSE ''
    END AS proposed_duration_source,
    '' AS proposed_schedule_action, '' AS include_in_master_plan, '' AS blocked_reason, '' AS owner,
    '' AS confirmation_source, '' AS confirmation_evidence, '' AS reviewer, '' AS reviewed_at,
    'failure_stabilized; failure_accepted; duration_observed; duration_owner_estimate; excluded_from_master_plan; blocked_pending_owner; manual_review_required' AS allowed_decisions,
    recommended_d6_decision AS next_action,
    'Fill this row before treating D6 as closed. Do not use failure holds or weak default durations as hard orchestration rules without reviewed evidence.' AS notes
INTO dbo.silver_d6_operational_decision_template
FROM #d6_control;

SELECT
    d6_id, priority_score, priority_band, closure_opportunity, item_qualified_name, v2_status,
    duration_source, failure_rate, readonly_action AS human_readonly_action,
    failure_target_ids AS linked_failure_target_ids, duration_target_ids AS linked_duration_target_ids,
    execution_evidence_count,
    'analysis/d6_operational_decision_template.csv' AS decision_template_path,
    'Read-only/manual D6 action. Do not update schedules, retries, triggers, pipelines, or orchestration rules from this package alone.' AS notes
INTO dbo.silver_d6_external_readonly_action_plan
FROM #d6_control;

SELECT summary_scope, group_key, row_count, notes INTO dbo.silver_d6_closure_control_summary FROM (
    SELECT 'total' AS summary_scope, 'D6 closure control rows' AS group_key, COUNT(*) AS row_count, 'One row per D6 stabilization item.' AS notes FROM dbo.silver_d6_closure_control_queue
    UNION ALL
    SELECT 'total', 'Failure stabilization targets', COUNT(*), 'Items with failed-run hotspot evidence.' FROM dbo.silver_d6_failure_stabilization_targets
    UNION ALL
    SELECT 'total', 'Duration evidence targets', COUNT(*), 'Items needing duration evidence decision.' FROM dbo.silver_d6_duration_evidence_targets
    UNION ALL
    SELECT 'total', 'Observed duration candidates', COUNT(*), 'Default-duration rows with completed-run evidence available.' FROM dbo.silver_d6_observed_duration_candidates
    UNION ALL
    SELECT 'total', 'Owner estimate required rows', COUNT(*), 'Default-duration rows without completed-run evidence.' FROM dbo.silver_d6_owner_estimate_required_queue
    UNION ALL
    SELECT 'total', 'D6 decision rows', COUNT(*), 'One decision row per D6 stabilization item.' FROM dbo.silver_d6_operational_decision_template
    UNION ALL
    SELECT 'total', 'External read-only action rows', COUNT(*), 'One read-only/manual action per D6 item.' FROM dbo.silver_d6_external_readonly_action_plan
    UNION ALL
    SELECT 'closure_opportunity', closure_opportunity, COUNT(*), 'D6 items grouped by closure path.' FROM dbo.silver_d6_closure_control_queue GROUP BY closure_opportunity
    UNION ALL
    SELECT 'stabilization_type', stabilization_type, COUNT(*), 'D6 items grouped by stabilization type.' FROM dbo.silver_d6_closure_control_queue GROUP BY stabilization_type
    UNION ALL
    SELECT 'duration_source', duration_source, COUNT(*), 'D6 items grouped by duration source.' FROM dbo.silver_d6_closure_control_queue GROUP BY duration_source
    UNION ALL
    SELECT 'v2_status', v2_status, COUNT(*), 'D6 items grouped by current orchestration v2 status.' FROM dbo.silver_d6_closure_control_queue GROUP BY v2_status
) x;

DROP TABLE #d6_control;

END
