-- Warehouse-native translation of backend/scripts/40_build_d2_closure_control.ps1
-- (SQL migration). Reads dbo.bronze_d2_likely_dependency_edge_queue,
-- dbo.bronze_d2_likely_dependency_item_queue, dbo.bronze_pipeline_activity_lineage.
--
-- Two-level structure, unlike D1: edges are first grouped into canonical
-- "review target" pairs (an edge and its inverse/same-object counterpart
-- reviewed together), classified once per pair, then the actual control
-- queue has one row PER EDGE referencing its pair's classification.
--
-- Normalize-Key (lowercase+trim) is approximated without the original's
-- internal-whitespace-collapse (T-SQL has no native regex) -- qualified
-- names/relationship types in this data don't contain internal runs of
-- whitespace, so this is a safe approximation, same tradeoff as D1's
-- Limit-Text.
CREATE OR ALTER PROCEDURE dbo.sp_build_d2_closure_control
AS
BEGIN

IF OBJECT_ID('tempdb..#d2_review_targets') IS NOT NULL DROP TABLE #d2_review_targets;
IF OBJECT_ID('dbo.silver_d2_closure_control_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d2_closure_control_queue;
IF OBJECT_ID('dbo.silver_d2_review_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d2_review_targets;
IF OBJECT_ID('dbo.silver_d2_report_model_binding_candidates', 'U') IS NOT NULL DROP TABLE dbo.silver_d2_report_model_binding_candidates;
IF OBJECT_ID('dbo.silver_d2_sqlendpoint_lakehouse_candidates', 'U') IS NOT NULL DROP TABLE dbo.silver_d2_sqlendpoint_lakehouse_candidates;
IF OBJECT_ID('dbo.silver_d2_dependency_decision_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d2_dependency_decision_template;
IF OBJECT_ID('dbo.silver_d2_external_readonly_action_plan', 'U') IS NOT NULL DROP TABLE dbo.silver_d2_external_readonly_action_plan;
IF OBJECT_ID('dbo.silver_d2_closure_control_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d2_closure_control_summary;

;WITH edges AS (
    SELECT e.*,
        CASE WHEN e.canonical_pair_key <> '' THEN e.canonical_pair_key ELSE e.edge_key END AS pair_key,
        LOWER(LTRIM(RTRIM(e.from_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(e.to_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(e.relationship_type))) AS edge_norm_key
    FROM dbo.bronze_d2_likely_dependency_edge_queue e
),
activity_keys AS (
    SELECT LOWER(LTRIM(RTRIM(pipeline_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(invoked_item_qualified_name))) + '|depends_on' AS act_key
    FROM dbo.bronze_pipeline_activity_lineage
    WHERE pipeline_qualified_name <> '' AND invoked_item_qualified_name <> ''
),
pair_agg AS (
    SELECT
        pair_key,
        MAX(ISNULL(TRY_CAST(priority_score AS FLOAT), 0)) AS max_priority,
        COUNT(*) AS edge_count,
        MAX(CASE WHEN relationship_type = 'depends_on' AND from_item_type = 'SQLEndpoint' AND to_item_type = 'Lakehouse' THEN 1 ELSE 0 END) AS has_sqlendpoint_lakehouse
    FROM edges
    GROUP BY pair_key
),
-- Each STRING_AGG needs its own query scope -- Fabric Warehouse rejects
-- multiple ordered STRING_AGGs sharing a GROUP BY when their ORDER BY
-- columns differ ("mutually incompatible orderings", confirmed live).
-- Also matches Get-UniqueJoined's DISTINCT-then-join
-- semantics exactly (the original combined form would have double-counted
-- a relationship_type shared by both edges in a pair).
distinct_edge_ids AS (SELECT DISTINCT pair_key, edge_id FROM edges WHERE edge_id <> ''),
edge_ids_agg AS (
    SELECT pair_key, STRING_AGG(edge_id, '; ') WITHIN GROUP (ORDER BY edge_id) AS edge_ids
    FROM distinct_edge_ids GROUP BY pair_key
),
distinct_edge_keys AS (SELECT DISTINCT pair_key, edge_key FROM edges WHERE edge_key <> ''),
edge_keys_agg2 AS (
    SELECT pair_key, STRING_AGG(edge_key, '; ') WITHIN GROUP (ORDER BY edge_key) AS edge_keys
    FROM distinct_edge_keys GROUP BY pair_key
),
distinct_reltypes AS (SELECT DISTINCT pair_key, relationship_type FROM edges WHERE relationship_type <> ''),
relationship_types_agg AS (
    SELECT pair_key, STRING_AGG(relationship_type, '; ') WITHIN GROUP (ORDER BY relationship_type) AS relationship_types
    FROM distinct_reltypes GROUP BY pair_key
),
pair_evidence AS (
    SELECT e.pair_key, COUNT(*) AS activity_evidence_count
    FROM edges e
    JOIN activity_keys a ON a.act_key = e.edge_norm_key
    GROUP BY e.pair_key
),
pair_first AS (
    SELECT pair_key, relationship_family, from_workspace_name, from_workspace_environment,
        ROW_NUMBER() OVER (PARTITION BY pair_key ORDER BY (SELECT NULL)) AS rn
    FROM edges
),
sides AS (
    SELECT pair_key, from_item_type AS item_type, from_qualified_name AS qualified_name, from_item_name AS item_name,
        from_workspace_name AS workspace_name, from_workspace_environment AS workspace_environment
    FROM edges WHERE from_item_type <> ''
    UNION ALL
    SELECT pair_key, to_item_type, to_qualified_name, to_item_name, to_workspace_name, to_workspace_environment
    FROM edges WHERE to_item_type <> ''
),
side_ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY pair_key, item_type ORDER BY (SELECT NULL)) AS srn
    FROM sides
),
distinct_evidence AS (
    SELECT DISTINCT pair_key, current_evidence FROM edges WHERE current_evidence <> ''
),
current_evidence_agg AS (
    SELECT pair_key, STRING_AGG(current_evidence, '; ') WITHIN GROUP (ORDER BY current_evidence) AS current_evidence
    FROM distinct_evidence
    GROUP BY pair_key
),
review_targets_base AS (
    SELECT
        pa.pair_key,
        CAST(pa.max_priority AS INT) AS priority_score,
        CASE WHEN pa.max_priority >= 130 THEN 'critical' WHEN pa.max_priority >= 105 THEN 'high' WHEN pa.max_priority >= 80 THEN 'medium' ELSE 'low' END AS priority_band,
        f.relationship_family,
        rta.relationship_types,
        pa.edge_count,
        eia.edge_ids,
        eka.edge_keys,
        ISNULL(rep.workspace_name, ISNULL(sqle.workspace_name, f.from_workspace_name)) AS workspace_name,
        ISNULL(rep.workspace_environment, ISNULL(sqle.workspace_environment, f.from_workspace_environment)) AS workspace_environment,
        ISNULL(rep.qualified_name, '') AS report_qualified_name, ISNULL(rep.item_name, '') AS report_name,
        ISNULL(sm.qualified_name, '') AS semantic_model_qualified_name, ISNULL(sm.item_name, '') AS semantic_model_name,
        ISNULL(sqle.qualified_name, '') AS sql_endpoint_qualified_name, ISNULL(sqle.item_name, '') AS sql_endpoint_name,
        ISNULL(lh.qualified_name, '') AS lakehouse_qualified_name, ISNULL(lh.item_name, '') AS lakehouse_name,
        ISNULL(ce.current_evidence, '') AS current_evidence_raw,
        ISNULL(pe.activity_evidence_count, 0) AS pipeline_activity_evidence_count,
        CASE
            WHEN f.relationship_family = 'report_model_binding' THEN 'report_model_binding_requires_metadata'
            WHEN pa.has_sqlendpoint_lakehouse = 1 THEN 'sqlendpoint_lakehouse_same_name_candidate'
            WHEN ISNULL(pe.activity_evidence_count, 0) > 0 THEN 'pipeline_activity_invocation_candidate'
            ELSE 'manual_dependency_review_required'
        END AS closure_opportunity
    FROM pair_agg pa
    JOIN pair_first f ON f.pair_key = pa.pair_key AND f.rn = 1
    JOIN edge_ids_agg eia ON eia.pair_key = pa.pair_key
    JOIN edge_keys_agg2 eka ON eka.pair_key = pa.pair_key
    JOIN relationship_types_agg rta ON rta.pair_key = pa.pair_key
    LEFT JOIN pair_evidence pe ON pe.pair_key = pa.pair_key
    LEFT JOIN current_evidence_agg ce ON ce.pair_key = pa.pair_key
    LEFT JOIN side_ranked rep ON rep.pair_key = pa.pair_key AND rep.item_type = 'Report' AND rep.srn = 1
    LEFT JOIN side_ranked sm ON sm.pair_key = pa.pair_key AND sm.item_type = 'SemanticModel' AND sm.srn = 1
    LEFT JOIN side_ranked sqle ON sqle.pair_key = pa.pair_key AND sqle.item_type = 'SQLEndpoint' AND sqle.srn = 1
    LEFT JOIN side_ranked lh ON lh.pair_key = pa.pair_key AND lh.item_type = 'Lakehouse' AND lh.srn = 1
)
SELECT
    'D2R' + RIGHT('0000' + CAST(ROW_NUMBER() OVER (ORDER BY priority_score DESC, pair_key) AS VARCHAR(10)), 4) AS review_target_id,
    rt.pair_key, rt.priority_score, rt.priority_band, rt.relationship_family, rt.relationship_types,
    rt.edge_count, rt.edge_ids, rt.edge_keys, rt.workspace_name, rt.workspace_environment,
    rt.report_qualified_name, rt.report_name, rt.semantic_model_qualified_name, rt.semantic_model_name,
    rt.sql_endpoint_qualified_name, rt.sql_endpoint_name, rt.lakehouse_qualified_name, rt.lakehouse_name,
    CASE WHEN LEN(rt.current_evidence_raw) > 900 THEN LEFT(rt.current_evidence_raw, 897) + '...' ELSE rt.current_evidence_raw END AS current_evidence,
    rt.pipeline_activity_evidence_count, rt.closure_opportunity,
    CASE rt.closure_opportunity
        WHEN 'report_model_binding_requires_metadata' THEN 'Confirm report semantic-model binding from Fabric/Power BI report metadata or report definition; otherwise reject or mark unavailable.'
        WHEN 'sqlendpoint_lakehouse_same_name_candidate' THEN 'Confirm from Fabric lakehouse/SQL endpoint metadata that the SQL endpoint belongs to the lakehouse; otherwise reject the name-only dependency.'
        WHEN 'pipeline_activity_invocation_candidate' THEN 'Confirm the invoked item reference from DataPipeline activity definition before promoting the dependency.'
        ELSE 'Review manually and close with confirmed, rejected, access_denied, not_available, dynamic_reference, or manual_review_required.'
    END AS recommended_decision,
    CASE rt.closure_opportunity
        WHEN 'report_model_binding_requires_metadata' THEN 'Read the report metadata/definition and verify the bound semantic model ID, name, and workspace. Record the evidence before any dependency update.'
        WHEN 'sqlendpoint_lakehouse_same_name_candidate' THEN 'Read the lakehouse and SQL endpoint metadata. Confirm the endpoint is generated for, or explicitly belongs to, the lakehouse before using it as a dependency rule.'
        WHEN 'pipeline_activity_invocation_candidate' THEN 'Read the DataPipeline definition and verify the invoked item reference in the activity payload.'
        ELSE 'Read the relevant item definitions or owner-approved evidence, then record the decision in the template.'
    END AS human_readonly_action
INTO #d2_review_targets
FROM review_targets_base rt;

SELECT
    review_target_id, priority_score, priority_band, closure_opportunity, relationship_family,
    relationship_types, pair_key AS canonical_pair_key, edge_count, edge_ids, edge_keys,
    workspace_name, workspace_environment, report_qualified_name, semantic_model_qualified_name,
    sql_endpoint_qualified_name, lakehouse_qualified_name, current_evidence,
    pipeline_activity_evidence_count, recommended_decision, human_readonly_action
INTO dbo.silver_d2_review_targets
FROM #d2_review_targets;

SELECT
    review_target_id, priority_score, priority_band, workspace_name, workspace_environment,
    report_name, report_qualified_name, semantic_model_name, semantic_model_qualified_name,
    relationship_types, edge_count, edge_ids, current_evidence,
    '' AS proposed_status, '' AS confirmation_source, '' AS confirmation_evidence,
    '' AS reviewer, '' AS reviewed_at,
    'Confirm report binding metadata before promoting either edge.' AS notes
INTO dbo.silver_d2_report_model_binding_candidates
FROM #d2_review_targets
WHERE closure_opportunity = 'report_model_binding_requires_metadata';

SELECT
    review_target_id, priority_score, priority_band, workspace_name, workspace_environment,
    sql_endpoint_name, sql_endpoint_qualified_name, lakehouse_name, lakehouse_qualified_name,
    relationship_types, edge_count, edge_ids, current_evidence,
    '' AS proposed_status, '' AS confirmation_source, '' AS confirmation_evidence,
    '' AS reviewer, '' AS reviewed_at,
    'Confirm this is a platform-generated lakehouse SQL endpoint relationship, not only a same-name heuristic.' AS notes
INTO dbo.silver_d2_sqlendpoint_lakehouse_candidates
FROM #d2_review_targets
WHERE closure_opportunity = 'sqlendpoint_lakehouse_same_name_candidate';

SELECT
    review_target_id, priority_score, priority_band, closure_opportunity, relationship_family,
    relationship_types, workspace_name, workspace_environment,
    report_qualified_name AS target_report, semantic_model_qualified_name AS target_semantic_model,
    sql_endpoint_qualified_name AS target_sql_endpoint, lakehouse_qualified_name AS target_lakehouse,
    edge_count, edge_ids, human_readonly_action,
    'analysis/d2_dependency_decision_template.csv' AS decision_template_path,
    'Read-only/manual confirmation target. Do not modify Fabric or dependency CSVs from this package alone.' AS notes
INTO dbo.silver_d2_external_readonly_action_plan
FROM #d2_review_targets;

;WITH edges AS (
    SELECT e.*,
        CASE WHEN e.canonical_pair_key <> '' THEN e.canonical_pair_key ELSE e.edge_key END AS pair_key
    FROM dbo.bronze_d2_likely_dependency_edge_queue e
),
control_base AS (
    SELECT
        ROW_NUMBER() OVER (ORDER BY ISNULL(TRY_CAST(e.priority_score AS FLOAT), 0) DESC, e.edge_id) AS rn,
        e.edge_id, e.priority_score, e.priority_band, e.relationship_family, e.relationship_type,
        e.from_item_type, e.from_qualified_name, e.to_item_type, e.to_qualified_name,
        e.current_confidence, e.current_evidence, e.pair_key,
        rt.review_target_id, rt.closure_opportunity, rt.edge_count AS paired_edge_count,
        rt.recommended_decision
    FROM edges e
    JOIN #d2_review_targets rt ON rt.pair_key = e.pair_key
)
SELECT
    'D2C' + RIGHT('0000' + CAST(rn AS VARCHAR(10)), 4) AS d2_id,
    review_target_id, edge_id, priority_score, priority_band, closure_opportunity,
    relationship_family, relationship_type, from_item_type, from_qualified_name,
    to_item_type, to_qualified_name, current_confidence, current_evidence,
    pair_key AS canonical_pair_key, paired_edge_count,
    recommended_decision AS recommended_d2_decision,
    'yes' AS needs_external_readonly,
    'analysis/d2_external_readonly_action_plan.csv' AS readonly_plan_path,
    'analysis/d2_dependency_decision_template.csv' AS decision_template_path
INTO dbo.silver_d2_closure_control_queue
FROM control_base;

SELECT
    d2_id, review_target_id, edge_id, relationship_family, relationship_type,
    from_qualified_name, to_qualified_name, current_confidence, closure_opportunity,
    '' AS proposed_status,
    'confirmed; rejected; access_denied; not_available; dynamic_reference; manual_review_required' AS allowed_statuses,
    relationship_type AS confirmed_relationship_type,
    '' AS confirmation_source, '' AS confirmation_evidence, '' AS reviewer, '' AS reviewed_at,
    recommended_d2_decision AS next_action,
    'Fill this row before treating the likely dependency as closed. Do not use likely rows as hard orchestration rules.' AS notes
INTO dbo.silver_d2_dependency_decision_template
FROM dbo.silver_d2_closure_control_queue;

SELECT summary_scope, group_key, row_count, notes INTO dbo.silver_d2_closure_control_summary FROM (
    SELECT 'total' AS summary_scope, 'D2 closure control rows' AS group_key, COUNT(*) AS row_count, 'One row per likely dependency edge.' AS notes FROM dbo.silver_d2_closure_control_queue
    UNION ALL
    SELECT 'total', 'D2 review targets', COUNT(*), 'Canonical review targets after pairing inverse/same-object edges.' FROM dbo.silver_d2_review_targets
    UNION ALL
    SELECT 'total', 'Report/model binding review targets', COUNT(*), 'One row per report-semantic model pair.' FROM dbo.silver_d2_report_model_binding_candidates
    UNION ALL
    SELECT 'total', 'SQL endpoint/lakehouse review targets', COUNT(*), 'One row per same-name SQL endpoint/lakehouse pair.' FROM dbo.silver_d2_sqlendpoint_lakehouse_candidates
    UNION ALL
    SELECT 'total', 'External read-only action rows', COUNT(*), 'One read-only/manual action per review target.' FROM dbo.silver_d2_external_readonly_action_plan
    UNION ALL
    SELECT 'total', 'D2 item blocker rows', COUNT(*), 'Rows from the base D2 item queue.' FROM dbo.bronze_d2_likely_dependency_item_queue
    UNION ALL
    SELECT 'closure_opportunity', closure_opportunity, COUNT(*), 'D2 edges grouped by closure path.' FROM dbo.silver_d2_closure_control_queue GROUP BY closure_opportunity
    UNION ALL
    SELECT 'relationship_type', relationship_type, COUNT(*), 'D2 edges grouped by dependency relationship type.' FROM dbo.silver_d2_closure_control_queue GROUP BY relationship_type
    UNION ALL
    SELECT 'review_target_closure_opportunity', closure_opportunity, COUNT(*), 'Canonical review targets grouped by closure path.' FROM dbo.silver_d2_review_targets GROUP BY closure_opportunity
) x;

DROP TABLE #d2_review_targets;

END
