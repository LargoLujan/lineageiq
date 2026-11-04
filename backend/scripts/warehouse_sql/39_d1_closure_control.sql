-- Warehouse-native translation of backend/scripts/39_build_d1_closure_control.ps1
-- (first step of the local-computation -> Warehouse-SQL migration).
--
-- Reads only bronze tables (dbo.bronze_d1_missing_object_lineage_queue,
-- dbo.bronze_object_read_write_classification, dbo.bronze_pipeline_activity_lineage)
-- and writes five silver_* tables, matching the five CSVs the PowerShell
-- version produces (control queue, inherited candidates, decision template,
-- readonly plan, summary) -- everything except the markdown doc, which stays
-- an app-layer artifact, not data.
--
-- No recursive CTE needed here (unlike the graph/wave scripts) -- this is a
-- straight lookup+classify pass, well within what Fabric Warehouse supports
-- (verified live: CREATE PROCEDURE, plain CTEs, window functions
-- all work; recursive CTEs do not).
CREATE OR ALTER PROCEDURE dbo.sp_build_d1_closure_control
AS
BEGIN

IF OBJECT_ID('dbo.silver_d1_closure_control_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d1_closure_control_queue;
IF OBJECT_ID('dbo.silver_d1_inherited_pipeline_lineage_candidates', 'U') IS NOT NULL DROP TABLE dbo.silver_d1_inherited_pipeline_lineage_candidates;
IF OBJECT_ID('dbo.silver_d1_closure_decision_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d1_closure_decision_template;
IF OBJECT_ID('dbo.silver_d1_external_readonly_action_plan', 'U') IS NOT NULL DROP TABLE dbo.silver_d1_external_readonly_action_plan;
IF OBJECT_ID('dbo.silver_d1_closure_control_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d1_closure_control_summary;

;WITH ranked AS (
    SELECT
        q.*,
        ROW_NUMBER() OVER (
            ORDER BY ISNULL(TRY_CAST(q.priority_score AS FLOAT), 0) DESC, q.workspace_name, q.item_type, q.item_name
        ) AS rn
    FROM dbo.bronze_d1_missing_object_lineage_queue q
),
direct_counts AS (
    SELECT item_qualified_name, COUNT(*) AS direct_object_rows
    FROM dbo.bronze_object_read_write_classification
    WHERE item_qualified_name <> ''
    GROUP BY item_qualified_name
),
invoked AS (
    SELECT DISTINCT pipeline_qualified_name, invoked_item_qualified_name
    FROM dbo.bronze_pipeline_activity_lineage
    WHERE invoked_item_qualified_name <> ''
),
invoked_counts AS (
    SELECT pipeline_qualified_name, COUNT(*) AS invoked_item_count
    FROM invoked
    GROUP BY pipeline_qualified_name
),
child_evidence AS (
    SELECT
        i.pipeline_qualified_name,
        COUNT(DISTINCT i.invoked_item_qualified_name) AS invoked_items_with_object_evidence_count,
        SUM(dc.direct_object_rows) AS inherited_child_object_reference_count
    FROM invoked i
    JOIN direct_counts dc ON dc.item_qualified_name = i.invoked_item_qualified_name
    GROUP BY i.pipeline_qualified_name
),
classified AS (
    SELECT
        'D1C' + RIGHT('0000' + CAST(r.rn AS VARCHAR(10)), 4) AS d1_id,
        r.priority_score, r.priority_band, r.workspace_name, r.workspace_environment,
        r.item_type, r.item_name, r.item_qualified_name, r.coverage_status, r.gap_reason,
        r.definition_lookup_status, r.v2_status, r.failed_count,
        ISNULL(dc.direct_object_rows, 0) AS direct_object_reference_count,
        ISNULL(ic.invoked_item_count, 0) AS invoked_item_count,
        ISNULL(ce.invoked_items_with_object_evidence_count, 0) AS invoked_items_with_object_evidence_count,
        ISNULL(ce.inherited_child_object_reference_count, 0) AS inherited_child_object_reference_count,
        r.recommended_command AS proposed_readonly_command,
        r.manual_template_path,
        r.recommended_evidence_sources AS evidence_sources,
        CASE
            WHEN ISNULL(dc.direct_object_rows, 0) > 0 THEN 'direct_local_object_evidence_present'
            WHEN r.item_type = 'DataPipeline' AND ISNULL(ce.inherited_child_object_reference_count, 0) > 0 THEN 'inherited_child_object_evidence_candidate'
            WHEN r.item_type = 'DataPipeline' AND ISNULL(ic.invoked_item_count, 0) > 0 THEN 'orchestrator_only_or_child_review_required'
            WHEN r.definition_lookup_status LIKE '%decoded_no_object_candidates%'
              OR r.definition_lookup_status LIKE '%decoded_activities_no_object_candidates%'
              OR r.definition_lookup_status LIKE '%definition_decoded_empty%' THEN 'parser_improvement_or_manual_review_required'
            WHEN r.definition_lookup_status LIKE '%not_in_%gap_file%'
              OR r.definition_lookup_status LIKE '%needs_tmdl_or_model_expression_review%'
              OR r.definition_lookup_status LIKE '%semantic_definition_unavailable%' THEN 'read_only_definition_retry_required'
            WHEN r.item_type = 'SemanticModel' THEN 'semantic_model_source_review_required'
            ELSE 'manual_review_required'
        END AS closure_opportunity
    FROM ranked r
    LEFT JOIN direct_counts dc ON dc.item_qualified_name = r.item_qualified_name
    LEFT JOIN invoked_counts ic ON ic.pipeline_qualified_name = r.item_qualified_name
    LEFT JOIN child_evidence ce ON ce.pipeline_qualified_name = r.item_qualified_name
)
SELECT
    d1_id, priority_score, priority_band, workspace_name, workspace_environment,
    item_type, item_name, item_qualified_name, coverage_status, gap_reason,
    definition_lookup_status, v2_status, failed_count,
    direct_object_reference_count, invoked_item_count,
    invoked_items_with_object_evidence_count, inherited_child_object_reference_count,
    closure_opportunity,
    CASE closure_opportunity
        WHEN 'direct_local_object_evidence_present' THEN 'Review local object rows, then copy confirmed rows into index/manual_lineage_object_evidence.csv.'
        WHEN 'inherited_child_object_evidence_candidate' THEN 'Review invoked child lineage; if parent only orchestrates children, close as orchestrator_only_no_direct_objects or record inherited objects with evidence.'
        WHEN 'orchestrator_only_or_child_review_required' THEN 'Review activities; close as orchestrator_only_no_direct_objects when no direct source/sink exists, otherwise inspect invoked child definitions.'
        WHEN 'parser_improvement_or_manual_review_required' THEN 'Inspect decoded definition/code manually and improve parser only if a repeatable pattern is found.'
        WHEN 'read_only_definition_retry_required' THEN 'Run the recommended read-only definition/catalog extraction after human authentication/approval, then rebuild D1.'
        WHEN 'semantic_model_source_review_required' THEN 'Inspect TMDL/model expressions or owner-approved source mapping; record exact objects or close with an explicit reviewed state.'
        ELSE 'Review manually and close with confirmed, rejected, access_denied, not_available, dynamic_reference, or manual_review_required.'
    END AS recommended_d1_decision,
    CASE WHEN closure_opportunity = 'read_only_definition_retry_required' THEN 'yes' ELSE 'no' END AS needs_external_readonly,
    proposed_readonly_command, manual_template_path,
    'analysis/d1_closure_decision_template.csv' AS decision_template_path,
    evidence_sources
INTO dbo.silver_d1_closure_control_queue
FROM classified;

;WITH ranked AS (
    SELECT
        q.*,
        ROW_NUMBER() OVER (
            ORDER BY ISNULL(TRY_CAST(q.priority_score AS FLOAT), 0) DESC, q.workspace_name, q.item_type, q.item_name
        ) AS rn
    FROM dbo.bronze_d1_missing_object_lineage_queue q
),
invoked AS (
    SELECT DISTINCT pipeline_qualified_name, invoked_item_qualified_name
    FROM dbo.bronze_pipeline_activity_lineage
    WHERE invoked_item_qualified_name <> ''
),
first_activity AS (
    SELECT pipeline_qualified_name, invoked_item_qualified_name, activity_name, activity_type,
        ROW_NUMBER() OVER (PARTITION BY pipeline_qualified_name, invoked_item_qualified_name ORDER BY (SELECT NULL)) AS arn
    FROM dbo.bronze_pipeline_activity_lineage
    WHERE invoked_item_qualified_name <> ''
)
SELECT
    'D1C' + RIGHT('0000' + CAST(r.rn AS VARCHAR(10)), 4) AS d1_id,
    r.workspace_name AS parent_workspace_name,
    r.item_type AS parent_item_type,
    r.item_name AS parent_item_name,
    r.item_qualified_name AS parent_item_qualified_name,
    ISNULL(fa.activity_name, '') AS activity_name,
    ISNULL(fa.activity_type, '') AS activity_type,
    i.invoked_item_qualified_name,
    orwc.source_type, orwc.source_server, orwc.source_database, orwc.schema_name,
    orwc.object_name, orwc.object_type, orwc.operation_type, orwc.lineage_confidence,
    '' AS proposed_status,
    CASE
        WHEN LEN('Parent pipeline invokes child with local object evidence. Child evidence: ' + orwc.evidence) > 900
        THEN LEFT('Parent pipeline invokes child with local object evidence. Child evidence: ' + orwc.evidence, 897) + '...'
        ELSE 'Parent pipeline invokes child with local object evidence. Child evidence: ' + orwc.evidence
    END AS evidence,
    '' AS reviewer, '' AS reviewed_at,
    'D1 inherited candidate. Confirm whether the parent pipeline has no additional direct source/sink before promoting or closing.' AS notes
INTO dbo.silver_d1_inherited_pipeline_lineage_candidates
FROM ranked r
JOIN invoked i ON i.pipeline_qualified_name = r.item_qualified_name
JOIN dbo.bronze_object_read_write_classification orwc ON orwc.item_qualified_name = i.invoked_item_qualified_name
LEFT JOIN first_activity fa ON fa.pipeline_qualified_name = i.pipeline_qualified_name AND fa.invoked_item_qualified_name = i.invoked_item_qualified_name AND fa.arn = 1;

SELECT
    d1_id, item_qualified_name, item_type, item_name, closure_opportunity,
    '' AS proposed_status,
    'confirmed; rejected; access_denied; not_available; dynamic_reference; manual_review_required; orchestrator_only_no_direct_objects' AS allowed_statuses,
    '' AS confirmed_or_blocked_evidence, '' AS evidence_source, '' AS reviewer, '' AS reviewed_at,
    recommended_d1_decision AS next_action,
    'Fill this row before treating D1 as closed for the item. Use analysis/d1_manual_lineage_evidence_template.csv for confirmed object rows.' AS notes
INTO dbo.silver_d1_closure_decision_template
FROM dbo.silver_d1_closure_control_queue;

SELECT
    d1_id, priority_score, workspace_name, item_type, item_name, item_qualified_name,
    definition_lookup_status, proposed_readonly_command,
    'Read-only item definition/catalog evidence for D1 closure' AS target,
    'Authenticate/approve read-only execution, run command, review generated evidence, then rebuild D1.' AS human_action
INTO dbo.silver_d1_external_readonly_action_plan
FROM dbo.silver_d1_closure_control_queue
WHERE needs_external_readonly = 'yes';

SELECT summary_scope, group_key, row_count, notes INTO dbo.silver_d1_closure_control_summary FROM (
    SELECT 'total' AS summary_scope, 'D1 closure control rows' AS group_key, COUNT(*) AS row_count, 'One row per D1 item.' AS notes FROM dbo.silver_d1_closure_control_queue
    UNION ALL
    SELECT 'total', 'Inherited pipeline candidate rows', COUNT(*), 'Object rows inherited from invoked child items, pending human review.' FROM dbo.silver_d1_inherited_pipeline_lineage_candidates
    UNION ALL
    SELECT 'total', 'External read-only action rows', COUNT(*), 'Rows that need read-only Fabric/metadata refresh or owner-approved evidence.' FROM dbo.silver_d1_external_readonly_action_plan
    UNION ALL
    SELECT 'closure_opportunity', closure_opportunity, COUNT(*), 'D1 items grouped by recommended closure path.' FROM dbo.silver_d1_closure_control_queue GROUP BY closure_opportunity
    UNION ALL
    SELECT 'item_type', item_type, COUNT(*), 'D1 closure rows grouped by item type.' FROM dbo.silver_d1_closure_control_queue GROUP BY item_type
) x;

END
