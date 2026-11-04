-- Warehouse-native translation of backend/scripts/45_build_d7_closure_control.ps1
-- (SQL migration). Reads dbo.bronze_d7_orchestration_review_queue,
-- dbo.bronze_d7_nonprod_candidate_queue,
-- dbo.bronze_d7_wave_promotion_queue, and dbo.silver_d6_closure_control_queue
-- (D6's OWN silver output -- second cross-D-phase dependency; must run
-- after dbo.sp_build_d6_closure_control has populated it).
CREATE OR ALTER PROCEDURE dbo.sp_build_d7_closure_control
AS
BEGIN

IF OBJECT_ID('tempdb..#d7_control') IS NOT NULL DROP TABLE #d7_control;
IF OBJECT_ID('dbo.silver_d7_closure_control_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_closure_control_queue;
IF OBJECT_ID('dbo.silver_d7_blocked_by_d6_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_blocked_by_d6_queue;
IF OBJECT_ID('dbo.silver_d7_read_write_validation_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_read_write_validation_targets;
IF OBJECT_ID('dbo.silver_d7_source_readiness_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_source_readiness_targets;
IF OBJECT_ID('dbo.silver_d7_owner_approval_ready_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_owner_approval_ready_targets;
IF OBJECT_ID('dbo.silver_d7_wave_closure_control', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_wave_closure_control;
IF OBJECT_ID('dbo.silver_d7_operational_decision_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_operational_decision_template;
IF OBJECT_ID('dbo.silver_d7_external_readonly_action_plan', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_external_readonly_action_plan;
IF OBJECT_ID('dbo.silver_d7_closure_control_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_closure_control_summary;

;WITH candidate_first AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY d7_id ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_d7_nonprod_candidate_queue WHERE d7_id <> ''
),
d6_first AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY d6_id ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_d6_closure_control_queue WHERE d6_id <> ''
),
classified AS (
    SELECT
        r.*,
        CASE r.promotion_readiness
            WHEN 'blocked_pending_d6_stabilization' THEN 'blocked_pending_d6_closure'
            WHEN 'blocked_pending_read_write_validation' THEN 'blocked_pending_read_write_validation'
            WHEN 'source_readiness_review' THEN 'source_readiness_review_required'
            WHEN 'ready_for_owner_review' THEN 'owner_promotion_approval_ready'
            WHEN 'manual_governance_review' THEN 'manual_governance_review_required'
            WHEN 'existing_orchestrator_review' THEN 'existing_orchestrator_review_required'
            WHEN 'blocked_pending_duration_evidence' THEN 'blocked_pending_duration_evidence'
            WHEN 'blocked_pending_dependency_confirmation' THEN 'blocked_pending_dependency_confirmation'
            ELSE CASE
                WHEN r.promotion_path = 'governance_or_manual_check' THEN 'manual_governance_review_required'
                WHEN r.promotion_path = 'contained_child_activity_review' THEN 'existing_orchestrator_review_required'
                ELSE 'manual_promotion_review_required'
            END
        END AS closure_opportunity,
        ISNULL(d6.closure_opportunity, '') AS d6_closure_opportunity,
        ISNULL(d6.failure_rate, '') AS d6_failure_rate,
        ISNULL(cand.candidate_status, '') AS candidate_status,
        ISNULL(cand.nonprod_gate, '') AS nonprod_gate
    FROM dbo.bronze_d7_orchestration_review_queue r
    LEFT JOIN candidate_first cand ON cand.d7_id = r.d7_id AND cand.rn = 1
    LEFT JOIN d6_first d6 ON d6.d6_id = r.d6_blocker_id AND d6.rn = 1
)
SELECT
    d7_id, priority_score, priority_band, closure_opportunity, promotion_path, candidate_scope,
    promotion_readiness, workspace_name, workspace_environment, workspace_type,
    deployment_pipelines, item_type, item_name, item_qualified_name, v2_wave_index,
    proposed_stage, orchestration_role, action_type, is_master_action,
    estimated_duration_seconds, duration_source, predecessor_count, successor_count,
    run_count, failed_count, manual_count, scheduled_count, enabled_schedules,
    disabled_schedules, schedule_signal, repeated_manual_signal, fanout_signal,
    d6_blocker_id, d6_closure_opportunity, d6_decision_readiness, d6_failure_rate,
    original_risk_flags, human_validation_required, candidate_status, nonprod_gate,
    CASE closure_opportunity
        WHEN 'blocked_pending_d6_closure' THEN 'Keep blocked until linked D6 failure/duration row is stabilized, owner-accepted, excluded, or explicitly blocked.'
        WHEN 'blocked_pending_read_write_validation' THEN 'Keep blocked until read/write validation and conflict guard evidence are reviewed.'
        WHEN 'source_readiness_review_required' THEN 'Decide source_check or blocked after owner confirms the source readiness semantics and timing.'
        WHEN 'owner_promotion_approval_ready' THEN
            CASE promotion_path
                WHEN 'standalone_process_candidate' THEN 'Approve nonprod_run only after owner confirms scope, dependencies, duration, and rollback expectations.'
                WHEN 'semantic_refresh_candidate' THEN 'Approve semantic_refresh only after upstream readiness and model owner validation.'
                WHEN 'consumption_validation_check' THEN 'Approve consumption_check only after expected report or consumer validation is clear.'
                WHEN 'existing_orchestrator_candidate' THEN 'Decide existing_orchestrator, nonprod_run, keep_manual, or blocked after owner review.'
                ELSE 'Approve the D7 action only after owner validation and explicit non-production scope.'
            END
        WHEN 'manual_governance_review_required' THEN 'Keep manual or exclude unless a supported automated action and owner are identified.'
        WHEN 'existing_orchestrator_review_required' THEN 'Keep child activity unless the owner approves refactoring outside the existing orchestrator.'
        ELSE 'Record an explicit D7 decision before any non-production design promotion.'
    END AS recommended_d7_decision,
    CASE closure_opportunity
        WHEN 'blocked_pending_d6_closure' THEN 'Review linked D6 closure row first; do not promote this D7 row while failure or duration evidence remains unresolved.'
        WHEN 'blocked_pending_read_write_validation' THEN 'Review read/write classification, object conflicts, and guard edges before approving any run or parallel step.'
        WHEN 'source_readiness_review_required' THEN 'Confirm source owner, availability window, freshness signal, and whether the check is manual or automatable.'
        WHEN 'owner_promotion_approval_ready' THEN 'Review owner, environment, dependencies, duration, schedules, and non-production blast radius before selecting a D7 decision.'
        WHEN 'manual_governance_review_required' THEN 'Review governance/manual constraints and decide keep_manual, exclude, blocked, or a supported automation path.'
        WHEN 'existing_orchestrator_review_required' THEN 'Review parent orchestrator behavior and decide keep_child_activity, existing_orchestrator, exclude, or blocked.'
        ELSE 'Review local evidence and owner evidence before selecting a D7 decision.'
    END AS readonly_action,
    'analysis/d7_operational_decision_template.csv' AS decision_template_path
INTO #d7_control
FROM classified;

SELECT * INTO dbo.silver_d7_closure_control_queue FROM #d7_control;
SELECT * INTO dbo.silver_d7_blocked_by_d6_queue FROM #d7_control WHERE closure_opportunity = 'blocked_pending_d6_closure';
SELECT * INTO dbo.silver_d7_read_write_validation_targets FROM #d7_control WHERE closure_opportunity = 'blocked_pending_read_write_validation';
SELECT * INTO dbo.silver_d7_source_readiness_targets FROM #d7_control WHERE closure_opportunity = 'source_readiness_review_required';
SELECT * INTO dbo.silver_d7_owner_approval_ready_targets FROM #d7_control WHERE closure_opportunity = 'owner_promotion_approval_ready';

-- Wave-level rollup: one row per wave, aggregating the control rows whose
-- v2_wave_index matches (a real one-to-many group, mirroring
-- Get-WaveClosureStatus's "any blocked / any source-review / all owner-
-- ready" precedence exactly).
;WITH wave_rows AS (
    SELECT w.d7_wave_id, w.v2_wave_index, w.nonprod_candidate_count, w.promotion_paths,
        w.candidate_scopes, w.readiness_breakdown, w.source_wave_node_count, w.d7_gate_to_promote,
        c.closure_opportunity
    FROM dbo.bronze_d7_wave_promotion_queue w
    LEFT JOIN #d7_control c ON c.v2_wave_index = w.v2_wave_index
),
wave_agg AS (
    SELECT
        d7_wave_id, v2_wave_index, nonprod_candidate_count, promotion_paths, candidate_scopes,
        readiness_breakdown, source_wave_node_count, d7_gate_to_promote,
        COUNT(closure_opportunity) AS d7_row_count,
        SUM(CASE WHEN closure_opportunity LIKE 'blocked_%' THEN 1 ELSE 0 END) AS blocked_candidate_count,
        SUM(CASE WHEN closure_opportunity = 'source_readiness_review_required' THEN 1 ELSE 0 END) AS source_readiness_count,
        SUM(CASE WHEN closure_opportunity = 'owner_promotion_approval_ready' THEN 1 ELSE 0 END) AS owner_ready_count
    FROM wave_rows
    GROUP BY d7_wave_id, v2_wave_index, nonprod_candidate_count, promotion_paths, candidate_scopes, readiness_breakdown, source_wave_node_count, d7_gate_to_promote
),
wave_type_counts AS (SELECT v2_wave_index, closure_opportunity AS val, COUNT(*) AS cnt FROM wave_rows WHERE closure_opportunity IS NOT NULL AND closure_opportunity <> '' GROUP BY v2_wave_index, closure_opportunity),
wave_type_split AS (SELECT v2_wave_index, STRING_AGG(val + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY cnt DESC, val) AS closure_opportunity_split FROM wave_type_counts GROUP BY v2_wave_index)
SELECT
    a.d7_wave_id, a.v2_wave_index, a.d7_row_count, a.nonprod_candidate_count,
    a.blocked_candidate_count, a.source_readiness_count, a.owner_ready_count,
    ISNULL(s.closure_opportunity_split, '') AS closure_opportunity_split,
    a.promotion_paths, a.candidate_scopes, a.readiness_breakdown, a.source_wave_node_count,
    CASE
        WHEN a.blocked_candidate_count > 0 THEN 'blocked_pending_row_closure'
        WHEN a.source_readiness_count > 0 THEN 'source_readiness_wave_review'
        WHEN a.owner_ready_count = a.d7_row_count AND a.d7_row_count > 0 THEN 'ready_for_owner_wave_review'
        ELSE 'manual_wave_review_required'
    END AS wave_closure_status,
    a.d7_gate_to_promote
INTO #d7_wave_pre
FROM wave_agg a
LEFT JOIN wave_type_split s ON s.v2_wave_index = a.v2_wave_index;

SELECT
    d7_wave_id, v2_wave_index, d7_row_count, nonprod_candidate_count, blocked_candidate_count,
    source_readiness_count, owner_ready_count, closure_opportunity_split, promotion_paths,
    candidate_scopes, readiness_breakdown, source_wave_node_count, wave_closure_status,
    CASE wave_closure_status
        WHEN 'blocked_pending_row_closure' THEN 'Do not promote this wave; close blocked D7 rows and upstream D1-D6 blockers first.'
        WHEN 'source_readiness_wave_review' THEN 'Review source checks and owner semantics before this wave enters non-production design.'
        WHEN 'ready_for_owner_wave_review' THEN 'Wave can be reviewed for scoped non-production design after owner approvals are recorded.'
        ELSE 'Review wave rows manually and record explicit decisions before promotion.'
    END AS recommended_wave_action,
    d7_gate_to_promote
INTO dbo.silver_d7_wave_closure_control
FROM #d7_wave_pre;

SELECT
    d7_id, item_qualified_name, promotion_path, candidate_scope, promotion_readiness,
    closure_opportunity, action_type AS current_action_type, v2_wave_index AS current_v2_wave_index,
    duration_source AS current_duration_source, d6_blocker_id AS linked_d6_blocker_id,
    '' AS proposed_d7_decision,
    'nonprod_run; source_check; semantic_refresh; consumption_check; existing_orchestrator; keep_manual; keep_child_activity; exclude; blocked; manual_review_required' AS allowed_decisions,
    '' AS proposed_nonprod_scope, '' AS proposed_wave, '' AS proposed_schedule_handling,
    '' AS proposed_owner_validation, '' AS include_in_master_pipeline_design, '' AS blocked_reason,
    '' AS owner, '' AS confirmation_source, '' AS confirmation_evidence, '' AS reviewer, '' AS reviewed_at,
    recommended_d7_decision AS next_action,
    'Fill this row before treating D7 as closed. Do not create, modify, trigger, schedule, deploy, or refactor Fabric assets from this package alone.' AS notes
INTO dbo.silver_d7_operational_decision_template
FROM #d7_control;

SELECT
    d7_id, priority_score, priority_band, closure_opportunity, item_qualified_name,
    promotion_path, candidate_scope, promotion_readiness, readonly_action AS human_readonly_action,
    d6_blocker_id AS linked_d6_blocker_id, d6_closure_opportunity AS linked_d6_closure_opportunity,
    'analysis/d7_operational_decision_template.csv' AS decision_template_path,
    'Read-only/manual D7 action. Last operational step remains human approval and execution outside this repo.' AS notes
INTO dbo.silver_d7_external_readonly_action_plan
FROM #d7_control;

SELECT summary_scope, group_key, row_count, notes INTO dbo.silver_d7_closure_control_summary FROM (
    SELECT 'total' AS summary_scope, 'D7 closure control rows' AS group_key, COUNT(*) AS row_count, 'One row per D7 orchestration review item.' AS notes FROM dbo.silver_d7_closure_control_queue
    UNION ALL
    SELECT 'total', 'Blocked by D6 rows', COUNT(*), 'Rows blocked until linked D6 stabilization closes or is accepted.' FROM dbo.silver_d7_blocked_by_d6_queue
    UNION ALL
    SELECT 'total', 'Read/write validation rows', COUNT(*), 'Rows blocked by read/write validation before promotion.' FROM dbo.silver_d7_read_write_validation_targets
    UNION ALL
    SELECT 'total', 'Source readiness rows', COUNT(*), 'Rows requiring source readiness semantics and owner review.' FROM dbo.silver_d7_source_readiness_targets
    UNION ALL
    SELECT 'total', 'Owner approval ready rows', COUNT(*), 'Rows ready for explicit owner approval and scoped non-production design.' FROM dbo.silver_d7_owner_approval_ready_targets
    UNION ALL
    SELECT 'total', 'Wave closure rows', COUNT(*), 'One row per D7 wave.' FROM dbo.silver_d7_wave_closure_control
    UNION ALL
    SELECT 'total', 'D7 decision rows', COUNT(*), 'One decision row per D7 item.' FROM dbo.silver_d7_operational_decision_template
    UNION ALL
    SELECT 'total', 'External read-only action rows', COUNT(*), 'One read-only/manual action per D7 item.' FROM dbo.silver_d7_external_readonly_action_plan
    UNION ALL
    SELECT 'closure_opportunity', closure_opportunity, COUNT(*), 'D7 items grouped by closure path.' FROM dbo.silver_d7_closure_control_queue GROUP BY closure_opportunity
    UNION ALL
    SELECT 'promotion_path', promotion_path, COUNT(*), 'D7 items grouped by promotion path.' FROM dbo.silver_d7_closure_control_queue GROUP BY promotion_path
    UNION ALL
    SELECT 'promotion_readiness', promotion_readiness, COUNT(*), 'D7 items grouped by promotion readiness.' FROM dbo.silver_d7_closure_control_queue GROUP BY promotion_readiness
    UNION ALL
    SELECT 'item_type', item_type, COUNT(*), 'D7 items grouped by item type.' FROM dbo.silver_d7_closure_control_queue GROUP BY item_type
    UNION ALL
    SELECT 'wave_closure_status', wave_closure_status, COUNT(*), 'D7 waves grouped by closure status.' FROM dbo.silver_d7_wave_closure_control GROUP BY wave_closure_status
) x;

DROP TABLE #d7_control;
DROP TABLE #d7_wave_pre;

END
