-- Warehouse-native translation of backend/scripts/29_build_d4_exact_
-- object_type_confirmation_package.ps1 (Phase 2 migration continuation,
-- 2026-07-21). Reads dbo.silver_source_object_type_resolution_queue (15,
-- status='needs_metadata_review'), dbo.silver_object_read_write_
-- classification (23, scheduling_readiness='needs_object_type_
-- confirmation'), dbo.bronze_source_object_type_metadata_gaps,
-- dbo.bronze_source_object_type_metadata_evidence.
-- source_id ("D4S00001", ...) is assigned in the SAME sorted order used
-- for final export (priority_score DESC, source_type, source_database,
-- schema_name, object_name), matching the original script exactly since
-- it also assigns IDs after sorting, not in file order. impact_id
-- ("D4I000001", ...) has no such sort anchor in the original and is
-- treated as an opaque per-row identifier like other D-package row ids
-- in this migration; validation matches impact rows by content.
-- Validated 2026-07-21: 0 new bugs. Impact rows whose source_key has no
-- match in #pending_source fall back to dbo.silver_object_read_write_
-- classification's own hardening_priority_score, which already carries a
-- documented small residual from 22's duplicate-candidate-row
-- class (see 22/23 validation notes) -- confirmed by direct comparison
-- against the fresh local CSV baseline that this cascades unchanged,
-- not a new discrepancy introduced here.
CREATE OR ALTER PROCEDURE dbo.sp_build_d4_exact_object_type_confirmation_package
AS
BEGIN

IF OBJECT_ID('dbo.silver_d4_exact_object_type_source_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_exact_object_type_source_queue;
IF OBJECT_ID('dbo.silver_d4_exact_object_type_impact_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_exact_object_type_impact_queue;
IF OBJECT_ID('dbo.silver_d4_exact_object_type_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_exact_object_type_summary;
IF OBJECT_ID('dbo.silver_d4_object_type_confirmation_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_object_type_confirmation_template;
IF OBJECT_ID('dbo.silver_d4_readonly_object_type_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d4_readonly_object_type_targets;

IF OBJECT_ID('tempdb..#pending_source') IS NOT NULL DROP TABLE #pending_source;
SELECT
    LOWER(LTRIM(RTRIM(source_type))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' +
        LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(object_name))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(raw_object_type,'')))) AS source_key,
    status, priority_score, source_type, source_server, source_database, schema_name, object_name, raw_object_type,
    resolved_object_type, resolver_source, resolver_confidence, semantic_model_count, affected_item_count, affected_item_types,
    candidate_count, ISNULL(workspaces,'') AS workspaces, ISNULL(confidence,'') AS confidence, ISNULL(next_step,'') AS next_step
INTO #pending_source
FROM dbo.silver_source_object_type_resolution_queue
WHERE status = 'needs_metadata_review';

IF OBJECT_ID('tempdb..#gap_first') IS NOT NULL DROP TABLE #gap_first;
SELECT source_key, gap_reason, error
INTO #gap_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(source_type))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' +
        LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(object_name))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(raw_object_type,'')))) AS source_key,
        gap_reason, error,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(source_type))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' +
            LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(object_name))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(raw_object_type,'')))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_source_object_type_metadata_gaps
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#evidence_first') IS NOT NULL DROP TABLE #evidence_first;
SELECT source_key, object_type, confidence
INTO #evidence_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(source_type))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' +
        LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(object_name))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(raw_object_type,'')))) AS source_key,
        object_type, confidence,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(source_type))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' +
            LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(object_name))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(raw_object_type,'')))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_source_object_type_metadata_evidence
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#type_confirmation') IS NOT NULL DROP TABLE #type_confirmation;
SELECT
    ROW_NUMBER() OVER (ORDER BY LOWER(LTRIM(RTRIM(item_qualified_name))), LOWER(LTRIM(RTRIM(ISNULL(object_display_name,'')))), LOWER(LTRIM(RTRIM(ISNULL(operation_type,''))))) AS impact_seq,
    LOWER(LTRIM(RTRIM(source_type))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' +
        LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(object_name))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(raw_object_type,'')))) AS source_key,
    workspace_name, item_type, item_name, item_qualified_name, source_type, source_server, source_database, schema_name, object_name,
    ISNULL(object_display_name,'') AS object_display_name, ISNULL(object_key,'') AS object_key, ISNULL(object_type,'') AS object_type,
    ISNULL(raw_object_type,'') AS raw_object_type, ISNULL(object_type_status,'') AS object_type_status, ISNULL(object_type_confidence,'') AS object_type_confidence,
    ISNULL(operation_type,'') AS operation_type, ISNULL(lineage_confidence,'') AS lineage_confidence, ISNULL(scheduling_readiness,'') AS scheduling_readiness,
    ISNULL(hardening_issue_types,'') AS hardening_issue_types, ISNULL(preferred_confirmation_sources,'') AS preferred_confirmation_sources,
    ISNULL(evidence,'') AS evidence, ISNULL(hardening_priority_score,0) AS hardening_priority_score
INTO #type_confirmation
FROM dbo.silver_object_read_write_classification
WHERE scheduling_readiness = 'needs_object_type_confirmation';

IF OBJECT_ID('tempdb..#impact_counts') IS NOT NULL DROP TABLE #impact_counts;
SELECT source_key, COUNT(*) AS impact_row_count
INTO #impact_counts FROM #type_confirmation GROUP BY source_key;

IF OBJECT_ID('tempdb..#op_types_agg') IS NOT NULL DROP TABLE #op_types_agg;
;WITH t AS (SELECT source_key, operation_type, COUNT(*) AS cnt FROM #type_confirmation GROUP BY source_key, operation_type),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY source_key ORDER BY cnt DESC, LOWER(operation_type) ASC) AS rn FROM t)
SELECT source_key, STRING_AGG(operation_type + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS operation_types
INTO #op_types_agg FROM r GROUP BY source_key;

IF OBJECT_ID('tempdb..#item_types_agg') IS NOT NULL DROP TABLE #item_types_agg;
;WITH t AS (SELECT source_key, item_type, COUNT(*) AS cnt FROM #type_confirmation GROUP BY source_key, item_type),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY source_key ORDER BY cnt DESC, LOWER(item_type) ASC) AS rn FROM t)
SELECT source_key, STRING_AGG(item_type + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS impact_item_types
INTO #item_types_agg FROM r GROUP BY source_key;

IF OBJECT_ID('tempdb..#sample_items_agg') IS NOT NULL DROP TABLE #sample_items_agg;
;WITH r AS (
    SELECT source_key, item_qualified_name,
        ROW_NUMBER() OVER (PARTITION BY source_key ORDER BY LOWER(item_qualified_name)) AS rn
    FROM #type_confirmation
)
SELECT source_key, STRING_AGG(item_qualified_name, '; ') WITHIN GROUP (ORDER BY rn) AS sample_items
INTO #sample_items_agg FROM r WHERE rn <= 10 GROUP BY source_key;

IF OBJECT_ID('tempdb..#source_final') IS NOT NULL DROP TABLE #source_final;
SELECT
    'D4S' + RIGHT('0000' + CAST(ROW_NUMBER() OVER (ORDER BY ps.priority_score DESC, LOWER(ps.source_type), LOWER(ISNULL(ps.source_database,'')), LOWER(ISNULL(ps.schema_name,'')), LOWER(ps.object_name)) AS VARCHAR(10)), 5) AS source_id,
    ps.source_key, ps.priority_score, ps.status, ps.source_type, ps.source_server, ps.source_database, ps.schema_name, ps.object_name,
    ps.raw_object_type, ps.resolved_object_type, ps.resolver_source, ps.resolver_confidence, ps.semantic_model_count, ps.affected_item_count,
    ps.affected_item_types, ps.candidate_count, ps.workspaces, ps.confidence, ps.next_step,
    ISNULL(ic.impact_row_count, 0) AS impact_row_count,
    ISNULL(ota.operation_types, '') AS operation_types,
    ISNULL(ita.impact_item_types, '') AS impact_item_types,
    LEFT(ISNULL(sia.sample_items, ''), 1200) AS affected_items_sample,
    ISNULL(gf.gap_reason,'') AS gap_reason, LEFT(LTRIM(RTRIM(ISNULL(gf.error,''))), 900) AS metadata_error,
    ISNULL(ef.object_type,'') AS existing_metadata_evidence_type, ISNULL(ef.confidence,'') AS existing_metadata_evidence_confidence,
    CASE WHEN ps.raw_object_type = 'native_query_object'
            THEN 'Review the native query and confirm whether the referenced object is a table, view, stored_procedure, file, shortcut, or query.'
         WHEN ISNULL(ps.source_server,'') <> '' AND ISNULL(ps.source_database,'') <> ''
            THEN 'Use read-only SQL/Fabric metadata such as sys.objects, INFORMATION_SCHEMA, lakehouse metadata, or an owner-approved catalog to resolve exact object type.'
         ELSE 'Metadata target is incomplete; use Azure DevOps, SharePoint, OneLake, model/query definition, or owner-approved catalog evidence to resolve exact object type.' END AS recommended_method,
    CASE WHEN ISNULL(ps.source_server,'') <> '' AND ISNULL(ps.source_database,'') <> ''
            THEN 'Read metadata for server/database/schema/object and verify exact type without changing the source system.'
         WHEN ps.raw_object_type = 'native_query_object'
            THEN 'Read the native query text or generated parser evidence and verify what object kind the reference actually points to.'
         ELSE 'Use local definitions or owner-approved catalog evidence because server/database metadata target is missing.' END AS readonly_method
INTO #source_final
FROM #pending_source ps
LEFT JOIN #gap_first gf ON gf.source_key = ps.source_key
LEFT JOIN #evidence_first ef ON ef.source_key = ps.source_key
LEFT JOIN #impact_counts ic ON ic.source_key = ps.source_key
LEFT JOIN #op_types_agg ota ON ota.source_key = ps.source_key
LEFT JOIN #item_types_agg ita ON ita.source_key = ps.source_key
LEFT JOIN #sample_items_agg sia ON sia.source_key = ps.source_key;

SELECT
    source_id, priority_score,
    CASE WHEN priority_score >= 300 THEN 'critical' WHEN priority_score >= 200 THEN 'high' WHEN priority_score >= 100 THEN 'medium' ELSE 'low' END AS priority_band,
    status, source_type, source_server, source_database, schema_name, object_name, raw_object_type,
    resolved_object_type AS current_resolved_object_type, resolver_source, resolver_confidence, semantic_model_count, affected_item_count,
    affected_item_types, candidate_count, impact_row_count, operation_types, impact_item_types,
    LEFT(LTRIM(RTRIM(workspaces)), 1200) AS workspaces,
    affected_items_sample, confidence, gap_reason AS metadata_gap_reason, metadata_error,
    existing_metadata_evidence_type, existing_metadata_evidence_confidence,
    LEFT(LTRIM(RTRIM(next_step)), 700) AS next_step,
    recommended_method, readonly_method,
    'Resolve this source object to table, view, stored_procedure, file, shortcut, query, or explicitly blocked with evidence.' AS d4_gate_to_close
INTO dbo.silver_d4_exact_object_type_source_queue
FROM #source_final;

SELECT
    source_id, source_type, source_server, source_database, schema_name, object_name, raw_object_type,
    current_resolved_object_type, '' AS proposed_status, '' AS confirmed_object_type, '' AS confirmation_source,
    '' AS confirmation_evidence, '' AS reviewer, '' AS reviewed_at,
    'D4 template row. Set proposed_status to resolved or blocked before applying any future object type update.' AS notes
INTO dbo.silver_d4_object_type_confirmation_template
FROM dbo.silver_d4_exact_object_type_source_queue;

SELECT
    source_id, priority_score,
    CASE WHEN priority_score >= 300 THEN 'critical' WHEN priority_score >= 200 THEN 'high' WHEN priority_score >= 100 THEN 'medium' ELSE 'low' END AS priority_band,
    source_type, source_server, source_database, schema_name, object_name, raw_object_type, readonly_method,
    'pwsh -NoLogo -File backend/scripts/20_extract_source_object_type_metadata.ps1 -AzCommand az -TrustServerCertificate' AS suggested_readonly_command,
    metadata_gap_reason,
    'analysis/d4_object_type_confirmation_template.csv' AS template_path,
    'Read-only/manual target. Do not query external metadata or apply overrides without human approval.' AS notes
INTO dbo.silver_d4_readonly_object_type_targets
FROM dbo.silver_d4_exact_object_type_source_queue;

-- ===========================================================================
-- Impact queue (one row per type-confirmation object row).
-- ===========================================================================
IF OBJECT_ID('tempdb..#source_rep') IS NOT NULL DROP TABLE #source_rep;
SELECT source_key, source_id, priority_score
INTO #source_rep
FROM (
    SELECT source_key, source_id, priority_score,
        ROW_NUMBER() OVER (PARTITION BY source_key ORDER BY CAST(RIGHT(source_id, 5) AS INT) DESC) AS rn
    FROM #source_final
) x WHERE rn = 1;

SELECT
    'D4I' + RIGHT('00000' + CAST(tc.impact_seq AS VARCHAR(10)), 6) AS impact_id,
    ISNULL(sr.source_id, '') AS source_id,
    (CASE WHEN ISNULL(sr.priority_score,0) <> 0 THEN sr.priority_score
          WHEN ISNULL(tc.hardening_priority_score,0) <> 0 THEN tc.hardening_priority_score
          ELSE 70 END) AS priority_score,
    (CASE WHEN (CASE WHEN ISNULL(sr.priority_score,0) <> 0 THEN sr.priority_score WHEN ISNULL(tc.hardening_priority_score,0) <> 0 THEN tc.hardening_priority_score ELSE 70 END) >= 300 THEN 'critical'
          WHEN (CASE WHEN ISNULL(sr.priority_score,0) <> 0 THEN sr.priority_score WHEN ISNULL(tc.hardening_priority_score,0) <> 0 THEN tc.hardening_priority_score ELSE 70 END) >= 200 THEN 'high'
          WHEN (CASE WHEN ISNULL(sr.priority_score,0) <> 0 THEN sr.priority_score WHEN ISNULL(tc.hardening_priority_score,0) <> 0 THEN tc.hardening_priority_score ELSE 70 END) >= 100 THEN 'medium'
          ELSE 'low' END) AS priority_band,
    tc.workspace_name, tc.item_type, tc.item_name, tc.item_qualified_name, tc.source_type, tc.source_server, tc.source_database,
    tc.schema_name, tc.object_name, tc.object_display_name, tc.object_key, tc.object_type AS current_object_type, tc.raw_object_type,
    tc.object_type_status, tc.object_type_confidence, tc.operation_type, tc.lineage_confidence, tc.scheduling_readiness,
    tc.hardening_issue_types, tc.preferred_confirmation_sources,
    LEFT(LTRIM(RTRIM(tc.evidence)), 1000) AS evidence,
    'Resolve source_id exact object type or explicitly block it with evidence.' AS d4_gate_to_close
INTO dbo.silver_d4_exact_object_type_impact_queue
FROM #type_confirmation tc
LEFT JOIN #source_rep sr ON sr.source_key = tc.source_key;

-- ===========================================================================
-- Summary.
-- ===========================================================================
SELECT summary_scope, group_key, row_count, high_or_critical_count, max_priority_score, notes
INTO dbo.silver_d4_exact_object_type_summary
FROM (
    SELECT 'total' AS summary_scope, 'D4 source objects' AS group_key, COUNT(*) AS row_count,
        SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END) AS high_or_critical_count,
        ISNULL(MAX(priority_score),0) AS max_priority_score,
        'Source objects from analysis/source_object_type_resolution_queue.csv pending exact type.' AS notes
    FROM dbo.silver_d4_exact_object_type_source_queue

    UNION ALL
    SELECT 'total', 'D4 impacted object rows', COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Object read/write rows needing exact object type confirmation.'
    FROM dbo.silver_d4_exact_object_type_impact_queue

    UNION ALL
    SELECT 'raw_object_type', raw_object_type, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Pending source objects by ambiguous/raw object type.'
    FROM dbo.silver_d4_exact_object_type_source_queue GROUP BY raw_object_type

    UNION ALL
    SELECT 'source_type', source_type, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Pending source objects by source type.'
    FROM dbo.silver_d4_exact_object_type_source_queue GROUP BY source_type

    UNION ALL
    SELECT 'metadata_gap_reason', ISNULL(metadata_gap_reason,''), COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Metadata extraction gap reason for pending source objects.'
    FROM dbo.silver_d4_exact_object_type_source_queue GROUP BY ISNULL(metadata_gap_reason,'')

    UNION ALL
    SELECT 'impact_item_type', item_type, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Impacted rows grouped by item type.'
    FROM dbo.silver_d4_exact_object_type_impact_queue GROUP BY item_type

    UNION ALL
    SELECT 'priority_band_sources', priority_band, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Pending source objects grouped by priority band.'
    FROM dbo.silver_d4_exact_object_type_source_queue GROUP BY priority_band
) s;

END
