-- Warehouse-native translation of backend/scripts/42_build_d4_closure_control.ps1
-- (Phase 1 migration, 2026-07-21). Reads dbo.bronze_d4_exact_object_type_source_queue
-- and dbo.bronze_d4_exact_object_type_impact_queue.
--
-- Single-level like D1: one control row per ambiguous source object, with
-- the SAME row structure re-used (filtered) into four narrower output
-- tables (impacted / metadata-retry / missing-target / native-query).
CREATE OR ALTER PROCEDURE dbo.sp_build_d4_closure_control
AS
BEGIN

IF OBJECT_ID('tempdb..#d4_control') IS NOT NULL DROP TABLE #d4_control;
IF OBJECT_ID('dbo.silver_d4_closure_control_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_closure_control_queue;
IF OBJECT_ID('dbo.silver_d4_impacted_source_object_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_impacted_source_object_targets;
IF OBJECT_ID('dbo.silver_d4_metadata_retry_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_metadata_retry_targets;
IF OBJECT_ID('dbo.silver_d4_missing_metadata_target_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_missing_metadata_target_queue;
IF OBJECT_ID('dbo.silver_d4_native_query_review_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_native_query_review_targets;
IF OBJECT_ID('dbo.silver_d4_object_type_decision_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_object_type_decision_template;
IF OBJECT_ID('dbo.silver_d4_external_readonly_action_plan', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_external_readonly_action_plan;
IF OBJECT_ID('dbo.silver_d4_closure_control_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_closure_control_summary;

;WITH impact_counts AS (
    SELECT source_id, COUNT(*) AS impact_row_count FROM dbo.bronze_d4_exact_object_type_impact_queue GROUP BY source_id
),
op_counts AS (SELECT source_id, operation_type AS val, COUNT(*) AS cnt FROM dbo.bronze_d4_exact_object_type_impact_queue WHERE operation_type <> '' GROUP BY source_id, operation_type),
op_counts_capped AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY source_id ORDER BY cnt DESC, val) AS crn FROM op_counts),
op_split AS (SELECT source_id, STRING_AGG(val + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY cnt DESC, val) AS operation_split FROM op_counts_capped WHERE crn <= 30 GROUP BY source_id),
it_counts AS (SELECT source_id, item_type AS val, COUNT(*) AS cnt FROM dbo.bronze_d4_exact_object_type_impact_queue WHERE item_type <> '' GROUP BY source_id, item_type),
it_counts_capped AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY source_id ORDER BY cnt DESC, val) AS crn FROM it_counts),
it_split AS (SELECT source_id, STRING_AGG(val + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY cnt DESC, val) AS impact_item_type_split FROM it_counts_capped WHERE crn <= 30 GROUP BY source_id),
classified AS (
    SELECT
        -- Explicit column list, not s.* -- the source queue's OWN raw
        -- impact_row_count/operation_types/impact_item_types fields are
        -- never read by the original script (it always recomputes them
        -- fresh from the impact queue instead), and s.* would collide with
        -- the recomputed aliases of the same name below.
        s.source_id, s.priority_score, s.priority_band, s.source_type, s.source_server,
        s.source_database, s.schema_name, s.object_name, s.raw_object_type,
        s.current_resolved_object_type, s.resolver_source, s.resolver_confidence,
        s.affected_item_count, s.semantic_model_count, s.metadata_gap_reason,
        s.metadata_error, s.workspaces, s.affected_items_sample,
        CASE
            WHEN s.metadata_gap_reason = 'object_name_found_in_multiple_schemas' THEN 'multiple_schema_disambiguation_required'
            WHEN s.metadata_gap_reason = 'object_not_found' THEN 'object_not_found_owner_review'
            WHEN s.metadata_gap_reason = 'metadata_query_failed' THEN 'metadata_retry_or_owner_catalog_required'
            WHEN s.metadata_gap_reason = 'missing_metadata_target' OR s.source_server = '' OR s.source_database = '' THEN 'missing_metadata_target_mapping_required'
            WHEN s.raw_object_type = 'native_query_object' THEN 'native_query_definition_review_required'
            WHEN s.metadata_gap_reason = '' THEN 'no_gap_record_manual_review_required'
            ELSE 'manual_exact_type_review_required'
        END AS closure_opportunity,
        ISNULL(ic.impact_row_count, 0) AS impact_row_count,
        ISNULL(ops.operation_split, '') AS operation_split,
        ISNULL(its.impact_item_type_split, '') AS impact_item_type_split
    FROM dbo.bronze_d4_exact_object_type_source_queue s
    LEFT JOIN impact_counts ic ON ic.source_id = s.source_id
    LEFT JOIN op_split ops ON ops.source_id = s.source_id
    LEFT JOIN it_split its ON its.source_id = s.source_id
)
SELECT
    'D4C' + RIGHT('0000' + CAST(ROW_NUMBER() OVER (ORDER BY ISNULL(TRY_CAST(priority_score AS FLOAT), 0) DESC, source_id) AS VARCHAR(10)), 4) AS d4_id,
    source_id, CAST(ISNULL(TRY_CAST(priority_score AS FLOAT), 0) AS INT) AS priority_score, priority_band,
    CASE WHEN impact_row_count > 0 THEN 'direct_d4_impact' ELSE 'catalog_or_future_impact' END AS impact_priority,
    closure_opportunity, source_type, source_server, source_database, schema_name, object_name,
    raw_object_type, current_resolved_object_type, resolver_source, resolver_confidence,
    impact_row_count,
    ISNULL(TRY_CAST(affected_item_count AS INT), 0) AS affected_item_count,
    ISNULL(TRY_CAST(semantic_model_count AS INT), 0) AS semantic_model_count,
    operation_split, impact_item_type_split, metadata_gap_reason,
    CASE WHEN LEN(metadata_error) > 900 THEN LEFT(metadata_error, 897) + '...' ELSE metadata_error END AS metadata_error,
    CASE WHEN LEN(workspaces) > 900 THEN LEFT(workspaces, 897) + '...' ELSE workspaces END AS workspaces,
    CASE WHEN LEN(affected_items_sample) > 900 THEN LEFT(affected_items_sample, 897) + '...' ELSE affected_items_sample END AS affected_items_sample,
    'table; view; stored_procedure; file; shortcut; query; function; schema' AS allowed_exact_types,
    CASE closure_opportunity
        WHEN 'metadata_retry_or_owner_catalog_required' THEN 'Retry read-only metadata where access/network is available, or use owner-approved catalog evidence.'
        WHEN 'missing_metadata_target_mapping_required' THEN 'Resolve the missing server/database/lakehouse target from definitions, connections, OneLake paths, or owner evidence before exact type resolution.'
        WHEN 'object_not_found_owner_review' THEN 'Ask owner/catalog to confirm whether the object was renamed, deleted, generated dynamically, or wrongly parsed.'
        WHEN 'multiple_schema_disambiguation_required' THEN 'Resolve the schema explicitly from query/model definition or owner-approved catalog evidence.'
        WHEN 'native_query_definition_review_required' THEN 'Review native query text and map the reference to table, view, stored_procedure, file, shortcut, or query.'
        ELSE 'Review manually and close with resolved, rejected, access_denied, not_available, dynamic_reference, or manual_review_required.'
    END AS recommended_d4_decision,
    CASE closure_opportunity
        WHEN 'metadata_retry_or_owner_catalog_required' THEN 'Run the approved read-only metadata extractor for the target endpoint/database, or capture owner-approved catalog evidence.'
        WHEN 'missing_metadata_target_mapping_required' THEN 'Inspect local definitions, connections, OneLake paths, or owner evidence to identify the missing metadata target.'
        WHEN 'object_not_found_owner_review' THEN 'Review source catalog/owner evidence to decide whether the object is not available, renamed, dynamic, or a parser false positive.'
        WHEN 'multiple_schema_disambiguation_required' THEN 'Inspect source query/model definition to choose the correct schema among metadata matches.'
        WHEN 'native_query_definition_review_required' THEN 'Read native query/model expression text and classify the referenced object kind.'
        ELSE 'Read available local/owner evidence and record the exact object type or explicit closure status.'
    END AS readonly_action,
    'analysis/d4_object_type_decision_template.csv' AS decision_template_path
INTO #d4_control
FROM classified;

SELECT * INTO dbo.silver_d4_closure_control_queue FROM #d4_control;
SELECT * INTO dbo.silver_d4_impacted_source_object_targets FROM #d4_control WHERE impact_row_count > 0;
SELECT * INTO dbo.silver_d4_metadata_retry_targets FROM #d4_control WHERE closure_opportunity = 'metadata_retry_or_owner_catalog_required';
SELECT * INTO dbo.silver_d4_missing_metadata_target_queue FROM #d4_control WHERE closure_opportunity = 'missing_metadata_target_mapping_required';
SELECT * INTO dbo.silver_d4_native_query_review_targets FROM #d4_control WHERE raw_object_type = 'native_query_object';

SELECT
    d4_id, source_id, source_type, source_server, source_database, schema_name, object_name,
    raw_object_type, current_resolved_object_type, closure_opportunity,
    '' AS proposed_status,
    'resolved; rejected; access_denied; not_available; dynamic_reference; manual_review_required; multiple_matches' AS allowed_statuses,
    '' AS confirmed_object_type, allowed_exact_types,
    '' AS confirmation_source, '' AS confirmation_evidence, '' AS reviewer, '' AS reviewed_at,
    recommended_d4_decision AS next_action,
    'Fill this row before treating D4 as closed for the source object. Do not apply overrides without human approval.' AS notes
INTO dbo.silver_d4_object_type_decision_template
FROM #d4_control;

SELECT
    d4_id, source_id, priority_score, priority_band, impact_priority, closure_opportunity,
    source_type, source_server, source_database, schema_name, object_name, raw_object_type,
    readonly_action AS human_readonly_action,
    CASE WHEN closure_opportunity = 'metadata_retry_or_owner_catalog_required' THEN 'pwsh -NoLogo -File backend/scripts/20_extract_source_object_type_metadata.ps1 -AzCommand az -TrustServerCertificate' ELSE '' END AS suggested_readonly_command,
    'analysis/d4_object_type_decision_template.csv' AS decision_template_path,
    'Read-only/manual D4 action. Do not query external metadata or apply object type overrides without human approval.' AS notes
INTO dbo.silver_d4_external_readonly_action_plan
FROM #d4_control;

SELECT summary_scope, group_key, row_count, notes INTO dbo.silver_d4_closure_control_summary FROM (
    SELECT 'total' AS summary_scope, 'D4 closure control rows' AS group_key, COUNT(*) AS row_count, 'One row per ambiguous source object.' AS notes FROM dbo.silver_d4_closure_control_queue
    UNION ALL
    SELECT 'total', 'Directly impacted source objects', COUNT(*), 'Source objects with current D4 impacted object rows.' FROM dbo.silver_d4_impacted_source_object_targets
    UNION ALL
    SELECT 'total', 'Metadata retry targets', COUNT(*), 'Targets where read-only metadata query failed and can be retried or replaced by owner catalog evidence.' FROM dbo.silver_d4_metadata_retry_targets
    UNION ALL
    SELECT 'total', 'Missing metadata target rows', COUNT(*), 'Rows missing usable server/database/lakehouse metadata target.' FROM dbo.silver_d4_missing_metadata_target_queue
    UNION ALL
    SELECT 'total', 'Native query review targets', COUNT(*), 'Rows with raw object type native_query_object.' FROM dbo.silver_d4_native_query_review_targets
    UNION ALL
    SELECT 'total', 'D4 decision rows', COUNT(*), 'One decision row per ambiguous source object.' FROM dbo.silver_d4_object_type_decision_template
    UNION ALL
    SELECT 'total', 'External read-only action rows', COUNT(*), 'One read-only/manual action row per ambiguous source object.' FROM dbo.silver_d4_external_readonly_action_plan
    UNION ALL
    SELECT 'closure_opportunity', closure_opportunity, COUNT(*), 'D4 rows grouped by closure path.' FROM dbo.silver_d4_closure_control_queue GROUP BY closure_opportunity
    UNION ALL
    SELECT 'raw_object_type', raw_object_type, COUNT(*), 'D4 rows grouped by raw ambiguous object type.' FROM dbo.silver_d4_closure_control_queue GROUP BY raw_object_type
    UNION ALL
    SELECT 'impact_priority', impact_priority, COUNT(*), 'D4 rows grouped by direct impact status.' FROM dbo.silver_d4_closure_control_queue GROUP BY impact_priority
) x;

DROP TABLE #d4_control;

END
