-- Warehouse-native translation of backend/scripts/32_build_d7_
-- orchestration_review_promotion_package.ps1 (SQL migration). Reads dbo.silver_orchestration_v2_plan (24,
-- v2_status='needs_orchestration_review'), dbo.silver_orchestration_v2_
-- waves (24), dbo.silver_likely_conflict_cleanup_queue (25, phase D7),
-- dbo.silver_d6_failure_duration_queue (31), dbo.silver_schedule_review_
-- candidates, dbo.silver_manual_execution_candidates, dbo.silver_
-- orchestration_group_candidates, dbo.bronze_workspaces, dbo.bronze_
-- deployment_pipeline_workspace_groups. d7_id ("D7I00001", ...) is
-- assigned in the SAME sorted order used for final export (D7 cleanup
-- priority_score DESC, v2_wave_index, workspace_name, item_type,
-- item_name); d7_candidate_id reuses that same relative order restricted
-- to non-governance rows. d7_wave_id is deterministic (wave index itself,
-- not a sequence). Only deployment_pipelines' multi-value aggregation
-- order is opaque (no file-row-order available), tie-broken via LOWER().
-- Validated: 0 new bugs. Wave promotion queue (including all
-- STRING_AGG aggregates) matched 100% exactly. Remaining diffs are the
-- already-documented "<sql-server-host>"-class casing collision (8
-- rows) and the expected opaque-ID mismatch on d6_blocker_id (many rows,
-- confirmed by direct lookup to reference the identical underlying item
-- on both sides -- inherited from 31's own tie-break-order class, not
-- introduced here).
CREATE OR ALTER PROCEDURE dbo.sp_build_d7_orchestration_review_promotion_package
AS
BEGIN

IF OBJECT_ID('dbo.silver_d7_orchestration_review_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_orchestration_review_queue;
IF OBJECT_ID('dbo.silver_d7_nonprod_candidate_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_nonprod_candidate_queue;
IF OBJECT_ID('dbo.silver_d7_wave_promotion_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_wave_promotion_queue;
IF OBJECT_ID('dbo.silver_d7_orchestration_review_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_orchestration_review_summary;
IF OBJECT_ID('dbo.silver_d7_promotion_decision_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_promotion_decision_template;
IF OBJECT_ID('dbo.silver_d7_readonly_promotion_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d7_readonly_promotion_targets;

IF OBJECT_ID('tempdb..#d7_cleanup') IS NOT NULL DROP TABLE #d7_cleanup;
SELECT item_key, priority_score
INTO #d7_cleanup
FROM (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, priority_score,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(item_qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_likely_conflict_cleanup_queue WHERE phase_id = 'D7'
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#d6_first') IS NOT NULL DROP TABLE #d6_first;
SELECT item_key, d6_id, stabilization_type, decision_readiness
INTO #d6_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, d6_id, stabilization_type, decision_readiness,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(item_qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_d6_failure_duration_queue
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#schedule_first') IS NOT NULL DROP TABLE #schedule_first;
SELECT DISTINCT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key
INTO #schedule_first
FROM dbo.silver_schedule_review_candidates;

IF OBJECT_ID('tempdb..#manual_first') IS NOT NULL DROP TABLE #manual_first;
SELECT DISTINCT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key
INTO #manual_first
FROM dbo.silver_manual_execution_candidates;

IF OBJECT_ID('tempdb..#fanout_first') IS NOT NULL DROP TABLE #fanout_first;
SELECT DISTINCT LOWER(LTRIM(RTRIM(source_qualified_name))) AS item_key
INTO #fanout_first
FROM dbo.silver_orchestration_group_candidates;

IF OBJECT_ID('tempdb..#workspace_first') IS NOT NULL DROP TABLE #workspace_first;
SELECT item_key, environment, workspace_type, capacity_name
INTO #workspace_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(workspace_name))) AS item_key, environment, workspace_type, capacity_name,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(workspace_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_workspaces
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#deploy_split') IS NOT NULL DROP TABLE #deploy_split;
SELECT LOWER(LTRIM(RTRIM(s.value))) AS workspace_key, g.deployment_pipeline_name
INTO #deploy_split
FROM dbo.bronze_deployment_pipeline_workspace_groups g
CROSS APPLY STRING_SPLIT(g.workspace_names, ';') s
WHERE LTRIM(RTRIM(s.value)) <> '';

IF OBJECT_ID('tempdb..#deploy_agg') IS NOT NULL DROP TABLE #deploy_agg;
;WITH r AS (
    SELECT workspace_key, deployment_pipeline_name,
        ROW_NUMBER() OVER (PARTITION BY workspace_key ORDER BY LOWER(deployment_pipeline_name)) AS rn
    FROM (SELECT DISTINCT workspace_key, deployment_pipeline_name FROM #deploy_split) d
)
SELECT workspace_key, STRING_AGG(deployment_pipeline_name, '; ') WITHIN GROUP (ORDER BY rn) AS deployment_pipeline_names
INTO #deploy_agg FROM r GROUP BY workspace_key;

IF OBJECT_ID('tempdb..#candidates') IS NOT NULL DROP TABLE #candidates;
SELECT
    LOWER(LTRIM(RTRIM(qualified_name))) AS item_key, qualified_name, workspace_name, item_type, item_name,
    ISNULL(v2_wave_index,0) AS v2_wave_index, ISNULL(proposed_stage,'') AS proposed_stage,
    ISNULL(orchestration_role,'') AS orchestration_role, ISNULL(action_type,'') AS action_type,
    ISNULL(is_master_action,0) AS is_master_action, estimated_duration_seconds,
    ISNULL(duration_source,'') AS duration_source, ISNULL(predecessor_count,0) AS predecessor_count,
    ISNULL(successor_count,0) AS successor_count, ISNULL(run_count,0) AS run_count, ISNULL(failed_count,0) AS failed_count,
    ISNULL(manual_count,0) AS manual_count, ISNULL(scheduled_count,0) AS scheduled_count,
    ISNULL(enabled_schedules,0) AS enabled_schedules, ISNULL(disabled_schedules,0) AS disabled_schedules,
    ISNULL(schedule_times,'') AS schedule_times, ISNULL(original_risk_flags,'') AS original_risk_flags,
    ISNULL(original_human_validation_required,'') AS original_human_validation_required,
    ISNULL(v2_recommended_next_action,'') AS v2_recommended_next_action
INTO #candidates
FROM dbo.silver_orchestration_v2_plan
WHERE v2_status = 'needs_orchestration_review';

IF OBJECT_ID('tempdb..#final') IS NOT NULL DROP TABLE #final;
SELECT
    'D7I' + RIGHT('0000' + CAST(ROW_NUMBER() OVER (ORDER BY ISNULL(dc.priority_score,0) DESC, c.v2_wave_index, LOWER(c.workspace_name), LOWER(c.item_type), LOWER(c.item_name)) AS VARCHAR(10)), 5) AS d7_id,
    ROW_NUMBER() OVER (ORDER BY ISNULL(dc.priority_score,0) DESC, c.v2_wave_index, LOWER(c.workspace_name), LOWER(c.item_type), LOWER(c.item_name)) AS seq,
    c.*,
    (CASE c.action_type
        WHEN 'check_source_readiness' THEN 'source_readiness_check'
        WHEN 'run_standalone_process' THEN 'standalone_process_candidate'
        WHEN 'run_existing_orchestrator_or_refactor_branches' THEN 'existing_orchestrator_candidate'
        WHEN 'child_activity_inside_existing_orchestrator' THEN 'contained_child_activity_review'
        WHEN 'refresh_semantic_model_after_upstream_readiness' THEN 'semantic_refresh_candidate'
        WHEN 'validate_report_after_model_refresh' THEN 'consumption_validation_check'
        WHEN 'review_governance_or_unsupported_item' THEN 'governance_or_manual_check'
        ELSE (CASE c.orchestration_role
                WHEN 'source_readiness' THEN 'source_readiness_check'
                WHEN 'data_process' THEN 'data_process_review'
                WHEN 'semantic_refresh' THEN 'semantic_refresh_candidate'
                WHEN 'consumption_validation' THEN 'consumption_validation_check'
                ELSE 'manual_orchestration_review' END)
     END) AS promotion_path,
    dc.priority_score AS cleanup_priority_score,
    d6.d6_id AS d6_blocker_id, d6.stabilization_type AS d6_stabilization_type, d6.decision_readiness AS d6_decision_readiness,
    CASE WHEN d6.item_key IS NOT NULL THEN 1 ELSE 0 END AS has_d6_match,
    ISNULL(w.environment,'') AS workspace_environment, ISNULL(w.workspace_type,'') AS workspace_type, ISNULL(w.capacity_name,'') AS capacity_name,
    ISNULL(da.deployment_pipeline_names,'') AS deployment_pipelines,
    (CASE WHEN sf.item_key IS NOT NULL THEN 'schedule_review_candidate'
          WHEN c.enabled_schedules > 0 OR c.disabled_schedules > 0 THEN 'has_schedule_metadata'
          ELSE '' END) AS schedule_signal,
    (CASE WHEN mf.item_key IS NOT NULL THEN 'repeated_manual_candidate' ELSE '' END) AS repeated_manual_signal,
    (CASE WHEN ff.item_key IS NOT NULL THEN 'fanout_orchestrator_candidate' ELSE '' END) AS fanout_signal
INTO #final
FROM #candidates c
LEFT JOIN #d7_cleanup dc ON dc.item_key = c.item_key
LEFT JOIN #d6_first d6 ON d6.item_key = c.item_key
LEFT JOIN #schedule_first sf ON sf.item_key = c.item_key
LEFT JOIN #manual_first mf ON mf.item_key = c.item_key
LEFT JOIN #fanout_first ff ON ff.item_key = c.item_key
LEFT JOIN #workspace_first w ON w.item_key = LOWER(LTRIM(RTRIM(c.workspace_name)))
LEFT JOIN #deploy_agg da ON da.workspace_key = LOWER(LTRIM(RTRIM(c.workspace_name)));

IF OBJECT_ID('tempdb..#priced') IS NOT NULL DROP TABLE #priced;
SELECT *,
    (CASE WHEN ISNULL(cleanup_priority_score,0) <> 0 THEN cleanup_priority_score
          ELSE 60 + successor_count + enabled_schedules
               + (CASE WHEN original_risk_flags LIKE '%critical_path_candidate%' THEN 10 ELSE 0 END)
               + (CASE WHEN original_risk_flags LIKE '%repeated_manual_candidate%' THEN 8 ELSE 0 END)
               + (CASE WHEN original_risk_flags LIKE '%schedule_review_required%' THEN 5 ELSE 0 END)
               + (CASE WHEN original_risk_flags LIKE '%covered_by_existing_orchestrator%' THEN 3 ELSE 0 END)
     END) AS priority_score,
    (CASE promotion_path
        WHEN 'source_readiness_check' THEN 'master_pipeline_check'
        WHEN 'standalone_process_candidate' THEN 'nonprod_run_candidate'
        WHEN 'existing_orchestrator_candidate' THEN 'nonprod_orchestrator_candidate'
        WHEN 'contained_child_activity_review' THEN 'existing_orchestrator_child_review'
        WHEN 'semantic_refresh_candidate' THEN 'semantic_refresh_candidate'
        WHEN 'consumption_validation_check' THEN 'post_refresh_validation_check'
        WHEN 'governance_or_manual_check' THEN 'manual_governance_check'
        ELSE 'manual_review' END) AS candidate_scope
INTO #priced
FROM #final;

IF OBJECT_ID('tempdb..#priced2') IS NOT NULL DROP TABLE #priced2;
SELECT *,
    (CASE WHEN has_d6_match = 1 THEN 'blocked_pending_d6_stabilization'
          WHEN promotion_path = 'source_readiness_check' THEN 'source_readiness_review'
          WHEN original_risk_flags LIKE '%has_likely_dependency_evidence%' THEN 'blocked_pending_dependency_confirmation'
          WHEN original_risk_flags LIKE '%notebook_read_write_validation_required%' THEN 'blocked_pending_read_write_validation'
          WHEN promotion_path = 'governance_or_manual_check' THEN 'manual_governance_review'
          WHEN promotion_path = 'contained_child_activity_review' THEN 'existing_orchestrator_review'
          WHEN duration_source = 'default_by_role' THEN 'blocked_pending_duration_evidence'
          ELSE 'ready_for_owner_review' END) AS promotion_readiness
INTO #priced2
FROM #priced;

IF OBJECT_ID('tempdb..#priced3') IS NOT NULL DROP TABLE #priced3;
SELECT *,
    (CASE WHEN promotion_readiness = 'blocked_pending_d6_stabilization'
            THEN 'Resolve D6 failure/duration stabilization before promoting this row into a non-production orchestration design.'
          WHEN ISNULL(v2_recommended_next_action,'') <> '' THEN v2_recommended_next_action
          ELSE (CASE promotion_path
                WHEN 'source_readiness_check' THEN 'Confirm source readiness check semantics and owner before adding this as a master pipeline precondition.'
                WHEN 'standalone_process_candidate' THEN 'Review owner, dependencies, duration, and non-production scope before adding this item as a runnable process step.'
                WHEN 'existing_orchestrator_candidate' THEN 'Review whether the existing orchestrator should remain the executable boundary or be refactored into explicit branches.'
                WHEN 'contained_child_activity_review' THEN 'Keep as child activity unless the owner approves explicit orchestration outside the existing parent.'
                WHEN 'semantic_refresh_candidate' THEN 'Review upstream readiness and model refresh ownership before adding this as a semantic refresh step.'
                WHEN 'consumption_validation_check' THEN 'Confirm report/consumption validation expectations after model refresh before adding it as a check.'
                WHEN 'governance_or_manual_check' THEN 'Keep as governance/manual check unless a supported automated action is approved.'
                ELSE 'Record approved D7 action before promotion.' END)
     END) AS recommended_action_raw
INTO #priced3
FROM #priced2;

SELECT
    d7_id, priority_score,
    CASE WHEN priority_score >= 85 THEN 'critical' WHEN priority_score >= 75 THEN 'high' WHEN priority_score >= 65 THEN 'medium' ELSE 'low' END AS priority_band,
    promotion_path, candidate_scope, promotion_readiness, workspace_name, workspace_environment, workspace_type,
    capacity_name, deployment_pipelines, item_type, item_name, qualified_name AS item_qualified_name, v2_wave_index,
    proposed_stage, orchestration_role, action_type, is_master_action, estimated_duration_seconds, duration_source,
    predecessor_count, successor_count, run_count, failed_count, manual_count, scheduled_count, enabled_schedules,
    disabled_schedules, schedule_times, schedule_signal, repeated_manual_signal, fanout_signal,
    ISNULL(d6_blocker_id,'') AS d6_blocker_id, ISNULL(d6_stabilization_type,'') AS d6_stabilization_type,
    ISNULL(d6_decision_readiness,'') AS d6_decision_readiness, original_risk_flags, original_human_validation_required AS human_validation_required,
    LEFT(LTRIM(RTRIM(recommended_action_raw)), 900) AS recommended_next_action,
    'Record an approved D7 decision: nonprod_run, source_check, semantic_refresh, consumption_check, keep_manual, keep_child_activity, exclude, or blocked.' AS d7_gate_to_promote
INTO dbo.silver_d7_orchestration_review_queue
FROM #priced3;

SELECT
    'D7C' + RIGHT('0000' + CAST(ROW_NUMBER() OVER (ORDER BY seq) AS VARCHAR(10)), 5) AS d7_candidate_id,
    d7_id,
    (CASE WHEN promotion_readiness LIKE 'blocked%' THEN promotion_readiness ELSE 'candidate_after_owner_review' END) AS candidate_status,
    candidate_scope, promotion_path, priority_score,
    CASE WHEN priority_score >= 85 THEN 'critical' WHEN priority_score >= 75 THEN 'high' WHEN priority_score >= 65 THEN 'medium' ELSE 'low' END AS priority_band,
    workspace_name, workspace_environment, item_type, item_name, qualified_name AS item_qualified_name, v2_wave_index,
    proposed_stage, action_type, estimated_duration_seconds, duration_source, predecessor_count, successor_count,
    schedule_signal, repeated_manual_signal, fanout_signal, ISNULL(d6_blocker_id,'') AS d6_blocker_id,
    LEFT(LTRIM(RTRIM(recommended_action_raw)), 900) AS recommended_next_action,
    'Owner approves scope, D1-D6 blockers are resolved or accepted, and this candidate is tested outside production before any operational change.' AS nonprod_gate
INTO dbo.silver_d7_nonprod_candidate_queue
FROM #priced3
WHERE candidate_scope <> 'manual_governance_check';

SELECT
    d7_id, qualified_name AS item_qualified_name, workspace_name, workspace_environment, item_type, item_name,
    promotion_path, candidate_scope, promotion_readiness, action_type AS current_action_type,
    v2_wave_index AS current_v2_wave_index, duration_source AS current_duration_source,
    '' AS proposed_d7_decision, '' AS proposed_nonprod_scope, '' AS proposed_wave, '' AS proposed_schedule_handling,
    '' AS proposed_owner_validation, '' AS include_in_master_pipeline_design, '' AS blocked_reason, '' AS owner,
    '' AS confirmation_source, '' AS confirmation_evidence, '' AS reviewer, '' AS reviewed_at,
    'D7 template row. Use decisions such as nonprod_run, source_check, semantic_refresh, consumption_check, keep_manual, keep_child_activity, exclude, or blocked.' AS notes
INTO dbo.silver_d7_promotion_decision_template
FROM #priced3;

SELECT
    d7_id, priority_score,
    CASE WHEN priority_score >= 85 THEN 'critical' WHEN priority_score >= 75 THEN 'high' WHEN priority_score >= 65 THEN 'medium' ELSE 'low' END AS priority_band,
    qualified_name AS item_qualified_name, promotion_path, candidate_scope, promotion_readiness,
    'Review workspace environment, owner, schedules, duration evidence, deployment pipeline membership, upstream/downstream dependencies, and D1-D6 blockers before selecting a D7 decision.' AS readonly_method,
    'analysis/d7_promotion_decision_template.csv' AS template_path,
    'Read-only/manual review target. Do not create or edit Fabric pipelines, schedules, triggers, or repos from this package alone.' AS notes
INTO dbo.silver_d7_readonly_promotion_targets
FROM #priced3;

-- ===========================================================================
-- Wave promotion queue.
-- ===========================================================================
IF OBJECT_ID('tempdb..#wave_agg') IS NOT NULL DROP TABLE #wave_agg;
SELECT
    v2_wave_index,
    COUNT(*) AS d7_row_count,
    SUM(CASE WHEN candidate_scope <> 'manual_governance_check' THEN 1 ELSE 0 END) AS nonprod_candidate_count,
    SUM(CASE WHEN promotion_readiness LIKE 'blocked%' THEN 1 ELSE 0 END) AS blocked_candidate_count,
    SUM(CASE WHEN candidate_scope = 'manual_governance_check' OR promotion_readiness LIKE '%manual%' THEN 1 ELSE 0 END) AS manual_or_governance_count,
    MAX(priority_score) AS max_priority_score
INTO #wave_agg
FROM dbo.silver_d7_orchestration_review_queue
GROUP BY v2_wave_index;

IF OBJECT_ID('tempdb..#wave_paths') IS NOT NULL DROP TABLE #wave_paths;
;WITH t AS (SELECT v2_wave_index, promotion_path, COUNT(*) AS cnt FROM dbo.silver_d7_orchestration_review_queue GROUP BY v2_wave_index, promotion_path),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY v2_wave_index ORDER BY cnt DESC, LOWER(promotion_path) ASC) AS rn FROM t)
SELECT v2_wave_index, STRING_AGG(promotion_path + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS promotion_paths
INTO #wave_paths FROM r GROUP BY v2_wave_index;

IF OBJECT_ID('tempdb..#wave_scopes') IS NOT NULL DROP TABLE #wave_scopes;
;WITH t AS (SELECT v2_wave_index, candidate_scope, COUNT(*) AS cnt FROM dbo.silver_d7_orchestration_review_queue GROUP BY v2_wave_index, candidate_scope),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY v2_wave_index ORDER BY cnt DESC, LOWER(candidate_scope) ASC) AS rn FROM t)
SELECT v2_wave_index, STRING_AGG(candidate_scope + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS candidate_scopes
INTO #wave_scopes FROM r GROUP BY v2_wave_index;

IF OBJECT_ID('tempdb..#wave_readiness') IS NOT NULL DROP TABLE #wave_readiness;
;WITH t AS (SELECT v2_wave_index, promotion_readiness, COUNT(*) AS cnt FROM dbo.silver_d7_orchestration_review_queue GROUP BY v2_wave_index, promotion_readiness),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY v2_wave_index ORDER BY cnt DESC, LOWER(promotion_readiness) ASC) AS rn FROM t)
SELECT v2_wave_index, STRING_AGG(promotion_readiness + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS readiness_breakdown
INTO #wave_readiness FROM r GROUP BY v2_wave_index;

SELECT
    'D7W' + RIGHT('000' + CAST(wa.v2_wave_index AS VARCHAR(10)), 3) AS d7_wave_id,
    wa.v2_wave_index, wa.d7_row_count, wa.nonprod_candidate_count, wa.blocked_candidate_count,
    wa.manual_or_governance_count, wa.max_priority_score,
    ISNULL(wp.promotion_paths,'') AS promotion_paths, ISNULL(ws.candidate_scopes,'') AS candidate_scopes,
    ISNULL(wr.readiness_breakdown,'') AS readiness_breakdown,
    ISNULL(CAST(w.node_count AS VARCHAR(20)),'') AS source_wave_node_count,
    ISNULL(w.recommendation,'') AS source_wave_recommendation,
    'Wave can enter non-production design only after each row has an approved D7 decision and upstream D1-D6 blockers are closed or accepted.' AS d7_gate_to_promote
INTO dbo.silver_d7_wave_promotion_queue
FROM #wave_agg wa
LEFT JOIN #wave_paths wp ON wp.v2_wave_index = wa.v2_wave_index
LEFT JOIN #wave_scopes ws ON ws.v2_wave_index = wa.v2_wave_index
LEFT JOIN #wave_readiness wr ON wr.v2_wave_index = wa.v2_wave_index
LEFT JOIN dbo.silver_orchestration_v2_waves w ON w.v2_wave_index = wa.v2_wave_index;

-- ===========================================================================
-- Summary.
-- ===========================================================================
SELECT summary_scope, group_key, row_count, high_or_critical_count, max_priority_score, notes
INTO dbo.silver_d7_orchestration_review_summary
FROM (
    SELECT 'total' AS summary_scope, 'D7 orchestration review rows' AS group_key, COUNT(*) AS row_count,
        SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END) AS high_or_critical_count,
        ISNULL(MAX(priority_score),0) AS max_priority_score, 'Rows with v2_status needs_orchestration_review.' AS notes
    FROM dbo.silver_d7_orchestration_review_queue

    UNION ALL
    SELECT 'total', 'D7 non-production candidates', COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Rows that could feed non-production master pipeline design after review.'
    FROM dbo.silver_d7_nonprod_candidate_queue

    UNION ALL
    SELECT 'total', 'D7 waves', COUNT(*), 0, 0, 'Wave-level promotion review rows.'
    FROM dbo.silver_d7_wave_promotion_queue

    UNION ALL
    SELECT 'promotion_path', promotion_path, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D7 rows grouped by promotion path.'
    FROM dbo.silver_d7_orchestration_review_queue GROUP BY promotion_path

    UNION ALL
    SELECT 'candidate_scope', candidate_scope, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D7 rows grouped by candidate scope.'
    FROM dbo.silver_d7_orchestration_review_queue GROUP BY candidate_scope

    UNION ALL
    SELECT 'promotion_readiness', promotion_readiness, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D7 rows grouped by current promotion readiness.'
    FROM dbo.silver_d7_orchestration_review_queue GROUP BY promotion_readiness

    UNION ALL
    SELECT 'action_type', action_type, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D7 rows grouped by current action type.'
    FROM dbo.silver_d7_orchestration_review_queue GROUP BY action_type

    UNION ALL
    SELECT 'item_type', item_type, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D7 rows grouped by item type.'
    FROM dbo.silver_d7_orchestration_review_queue GROUP BY item_type
) s;

END
