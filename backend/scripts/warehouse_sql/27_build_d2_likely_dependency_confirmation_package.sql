-- Warehouse-native translation of backend/scripts/27_build_d2_likely_
-- dependency_confirmation_package.ps1 (Phase 2 migration continuation,
-- 2026-07-21). Reads dbo.bronze_dependencies, dbo.silver_likely_
-- conflict_cleanup_queue (25), dbo.silver_evidence_hardening_queue (22),
-- dbo.silver_orchestration_v2_plan (24), dbo.silver_ideal_execution_
-- edges (13), dbo.bronze_items. First-match-per-key lookups mirror
-- PowerShell hashtables' case-insensitive default via LOWER(LTRIM(RTRIM
-- (...))) + ROW_NUMBER-first-row-wins. edge_id values ("D2E0001", ...)
-- are assigned by a deterministic sort here, not the original's file
-- row order, since the Warehouse carries no such ordering -- they are
-- opaque per-edge identifiers, not data, so validation matches edges by
-- (from, to, relationship_type) rather than by edge_id text.
CREATE OR ALTER PROCEDURE dbo.sp_build_d2_likely_dependency_confirmation_package
AS
BEGIN

IF OBJECT_ID('dbo.silver_d2_likely_dependency_item_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d2_likely_dependency_item_queue;
IF OBJECT_ID('dbo.silver_d2_likely_dependency_edge_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d2_likely_dependency_edge_queue;
IF OBJECT_ID('dbo.silver_d2_likely_dependency_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d2_likely_dependency_summary;
IF OBJECT_ID('dbo.silver_d2_dependency_confirmation_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d2_dependency_confirmation_template;
IF OBJECT_ID('dbo.silver_d2_readonly_confirmation_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d2_readonly_confirmation_targets;

IF OBJECT_ID('tempdb..#items_first') IS NOT NULL DROP TABLE #items_first;
SELECT item_key, workspace_name, workspace_environment, item_type, item_name, technical_id
INTO #items_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key, workspace_name, workspace_environment, item_type, item_name, technical_id,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_items WHERE qualified_name <> ''
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#v2_first') IS NOT NULL DROP TABLE #v2_first;
SELECT item_key, v2_status, successor_count, incoming_likely_edges, outgoing_likely_edges, v2_recommended_next_action
INTO #v2_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key, v2_status, successor_count, incoming_likely_edges, outgoing_likely_edges, v2_recommended_next_action,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_orchestration_v2_plan
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#d2_items') IS NOT NULL DROP TABLE #d2_items;
SELECT item_key, priority_score, workspace_name, item_type, item_name, item_qualified_name
INTO #d2_items
FROM (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, priority_score, workspace_name, item_type, item_name, item_qualified_name,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(item_qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_likely_conflict_cleanup_queue WHERE phase_id = 'D2'
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#hardening_edge_first') IS NOT NULL DROP TABLE #hardening_edge_first;
SELECT edge_key, priority_score, blocker_reason, preferred_confirmation_source
INTO #hardening_edge_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(from_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(to_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(relationship_type))) AS edge_key,
        priority_score, blocker_reason, preferred_confirmation_source,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(from_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(to_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(relationship_type))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_evidence_hardening_queue WHERE issue_type = 'weak_relationship_confidence'
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#ideal_edge_first') IS NOT NULL DROP TABLE #ideal_edge_first;
SELECT edge_key, plan_relationship_type
INTO #ideal_edge_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(upstream_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(downstream_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(original_relationship_type))) AS edge_key,
        plan_relationship_type,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(upstream_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(downstream_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(original_relationship_type))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_ideal_execution_edges
) x WHERE rn = 1;

-- ===========================================================================
-- Likely edges (the D2 edge queue's primary source).
-- ===========================================================================
IF OBJECT_ID('tempdb..#likely_edges') IS NOT NULL DROP TABLE #likely_edges;
SELECT
    ROW_NUMBER() OVER (ORDER BY LOWER(LTRIM(RTRIM(from_qualified_name))), LOWER(LTRIM(RTRIM(to_qualified_name))), LOWER(LTRIM(RTRIM(relationship_type)))) AS edge_seq,
    from_qualified_name, to_qualified_name, relationship_type,
    LOWER(LTRIM(RTRIM(from_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(to_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(relationship_type))) AS edge_key,
    ISNULL(source_system, '') AS source_system, ISNULL(evidence, '') AS evidence, ISNULL(notes, '') AS notes
INTO #likely_edges
FROM dbo.bronze_dependencies
WHERE confidence = 'likely';

IF OBJECT_ID('tempdb..#edges_enriched') IS NOT NULL DROP TABLE #edges_enriched;
SELECT
    'D2E' + RIGHT('0000' + CAST(le.edge_seq AS VARCHAR(10)), 4) AS edge_id,
    le.from_qualified_name, le.to_qualified_name, le.relationship_type, le.edge_key,
    le.source_system, le.evidence, le.notes,
    CASE le.relationship_type WHEN 'uses_model' THEN 'report_model_binding' WHEN 'serves_report' THEN 'report_model_binding' WHEN 'depends_on' THEN 'item_dependency' ELSE 'dependency' END AS relationship_family,
    LOWER(LTRIM(RTRIM(le.from_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(le.to_qualified_name))) AS canon_unsorted_key,
    -- canonical pair key: family + the two normalized endpoints SORTED alphabetically
    (CASE le.relationship_type WHEN 'uses_model' THEN 'report_model_binding' WHEN 'serves_report' THEN 'report_model_binding' WHEN 'depends_on' THEN 'item_dependency' ELSE 'dependency' END) + '|' +
        (SELECT STRING_AGG(v, '|') WITHIN GROUP (ORDER BY v) FROM (VALUES (LOWER(LTRIM(RTRIM(le.from_qualified_name)))), (LOWER(LTRIM(RTRIM(le.to_qualified_name))))) t(v)) AS canonical_pair_key,
    ISNULL(fi.workspace_name, p_from.parts_workspace) AS from_workspace_name,
    ISNULL(NULLIF(fi.workspace_environment, ''), '') AS from_workspace_environment,
    ISNULL(NULLIF(fi.item_type, ''), p_from.parts_item_type) AS from_item_type,
    ISNULL(NULLIF(fi.item_name, ''), p_from.parts_item_name) AS from_item_name,
    ISNULL(ti.workspace_name, p_to.parts_workspace) AS to_workspace_name,
    ISNULL(NULLIF(ti.workspace_environment, ''), '') AS to_workspace_environment,
    ISNULL(NULLIF(ti.item_type, ''), p_to.parts_item_type) AS to_item_type,
    ISNULL(NULLIF(ti.item_name, ''), p_to.parts_item_name) AS to_item_name,
    ISNULL(fd2.priority_score, 0) AS from_priority, ISNULL(td2.priority_score, 0) AS to_priority,
    fi.workspace_environment AS from_item_env_raw, ti.workspace_environment AS to_item_env_raw,
    ISNULL(he.priority_score, 0) AS hardening_priority_score,
    LEFT(LTRIM(RTRIM(ISNULL(he.blocker_reason, ''))), 500) AS hardening_blocker_reason,
    he.preferred_confirmation_source AS hardening_preferred_source,
    ISNULL(ie.plan_relationship_type, '') AS ideal_plan_relationship_type,
    ISNULL(fv2.v2_status, '') AS from_v2_status, ISNULL(tv2.v2_status, '') AS to_v2_status,
    ISNULL(fv2.successor_count, 0) AS from_successor_count, ISNULL(tv2.successor_count, 0) AS to_successor_count,
    ISNULL(fv2.incoming_likely_edges, 0) AS from_incoming_likely_edges, ISNULL(fv2.outgoing_likely_edges, 0) AS from_outgoing_likely_edges,
    ISNULL(tv2.incoming_likely_edges, 0) AS to_incoming_likely_edges, ISNULL(tv2.outgoing_likely_edges, 0) AS to_outgoing_likely_edges
INTO #edges_enriched
FROM #likely_edges le
LEFT JOIN #items_first fi ON fi.item_key = LOWER(LTRIM(RTRIM(le.from_qualified_name)))
LEFT JOIN #items_first ti ON ti.item_key = LOWER(LTRIM(RTRIM(le.to_qualified_name)))
LEFT JOIN #v2_first fv2 ON fv2.item_key = LOWER(LTRIM(RTRIM(le.from_qualified_name)))
LEFT JOIN #v2_first tv2 ON tv2.item_key = LOWER(LTRIM(RTRIM(le.to_qualified_name)))
LEFT JOIN #d2_items fd2 ON fd2.item_key = LOWER(LTRIM(RTRIM(le.from_qualified_name)))
LEFT JOIN #d2_items td2 ON td2.item_key = LOWER(LTRIM(RTRIM(le.to_qualified_name)))
LEFT JOIN #hardening_edge_first he ON he.edge_key = le.edge_key
LEFT JOIN #ideal_edge_first ie ON ie.edge_key = le.edge_key
CROSS APPLY (
    SELECT
        CASE WHEN pos2 > 0 THEN LEFT(le.from_qualified_name, pos1 - 1) ELSE '' END AS parts_workspace,
        CASE WHEN pos2 > 0 THEN SUBSTRING(le.from_qualified_name, pos1 + 3, pos2 - pos1 - 3) ELSE '' END AS parts_item_type,
        CASE WHEN pos2 > 0 THEN SUBSTRING(le.from_qualified_name, pos2 + 3, LEN(le.from_qualified_name)) ELSE le.from_qualified_name END AS parts_item_name
    FROM (SELECT CHARINDEX(' / ', le.from_qualified_name) AS pos1) a0
    CROSS APPLY (SELECT CASE WHEN a0.pos1 > 0 THEN CHARINDEX(' / ', le.from_qualified_name, a0.pos1 + 3) ELSE 0 END AS pos2) a1
) p_from
CROSS APPLY (
    SELECT
        CASE WHEN pos2 > 0 THEN LEFT(le.to_qualified_name, pos1 - 1) ELSE '' END AS parts_workspace,
        CASE WHEN pos2 > 0 THEN SUBSTRING(le.to_qualified_name, pos1 + 3, pos2 - pos1 - 3) ELSE '' END AS parts_item_type,
        CASE WHEN pos2 > 0 THEN SUBSTRING(le.to_qualified_name, pos2 + 3, LEN(le.to_qualified_name)) ELSE le.to_qualified_name END AS parts_item_name
    FROM (SELECT CHARINDEX(' / ', le.to_qualified_name) AS pos1) b0
    CROSS APPLY (SELECT CASE WHEN b0.pos1 > 0 THEN CHARINDEX(' / ', le.to_qualified_name, b0.pos1 + 3) ELSE 0 END AS pos2) b1
) p_to;

IF OBJECT_ID('tempdb..#edges_final') IS NOT NULL DROP TABLE #edges_final;
SELECT e.*,
    CASE
        WHEN GREATEST(from_priority, to_priority) = 0 THEN 70
        ELSE GREATEST(from_priority, to_priority)
    END
    + CASE WHEN relationship_type = 'depends_on' THEN 15 WHEN relationship_type IN ('uses_model', 'serves_report') THEN 5 ELSE 0 END
    + CASE WHEN from_item_env_raw = 'PRO' OR to_item_env_raw = 'PRO' THEN 5 ELSE 0 END AS priority_score,
    ISNULL(NULLIF(hardening_preferred_source, ''),
        CASE relationship_type
            WHEN 'uses_model' THEN 'Fabric/Power BI report binding metadata or report definition'
            WHEN 'serves_report' THEN 'Fabric/Power BI report binding metadata or report definition'
            WHEN 'depends_on' THEN 'Fabric item definition, Azure DevOps code, SharePoint design docs, OneLake path evidence, or owner-approved evidence'
            ELSE 'Direct platform metadata or owner-approved evidence' END) AS preferred_confirmation_source,
    CASE relationship_type
        WHEN 'uses_model' THEN 'Confirm the report semantic-model binding from Fabric/Power BI report metadata or report definition.'
        WHEN 'serves_report' THEN 'Confirm the inverse semantic-model-to-report relationship by validating the report binding.'
        WHEN 'depends_on' THEN 'Confirm the dependency from item definition, activity/code reference, object lineage, Azure DevOps, SharePoint, OneLake, or owner evidence.'
        ELSE 'Confirm the relationship from direct platform metadata or owner-approved technical evidence.' END AS recommended_method,
    CASE relationship_type
        WHEN 'uses_model' THEN 'Read report metadata/definition and verify the bound semantic model ID/name/workspace.'
        WHEN 'serves_report' THEN 'Read the related report metadata/definition; confirm it points to this semantic model.'
        WHEN 'depends_on' THEN 'Read the upstream/downstream item definitions and compare invoked item, connection, source, sink, or object references.'
        ELSE 'Read the relevant item metadata and compare relationship evidence.' END AS readonly_method
INTO #edges_final
FROM #edges_enriched e;

SELECT
    edge_id,
    priority_score,
    CASE WHEN priority_score >= 130 THEN 'critical' WHEN priority_score >= 105 THEN 'high' WHEN priority_score >= 80 THEN 'medium' ELSE 'low' END AS priority_band,
    relationship_family, relationship_type,
    from_workspace_name, from_workspace_environment, from_item_type, from_item_name, from_qualified_name,
    to_workspace_name, to_workspace_environment, to_item_type, to_item_name, to_qualified_name,
    'likely' AS current_confidence, source_system,
    LEFT(LTRIM(RTRIM(evidence)), 700) AS current_evidence, LEFT(LTRIM(RTRIM(notes)), 700) AS current_notes,
    hardening_priority_score, hardening_blocker_reason, preferred_confirmation_source, ideal_plan_relationship_type,
    from_v2_status, to_v2_status, from_successor_count, to_successor_count,
    from_incoming_likely_edges, from_outgoing_likely_edges, to_incoming_likely_edges, to_outgoing_likely_edges,
    canonical_pair_key, edge_key, recommended_method,
    'Confirm, reject, or explicitly block this likely relationship with direct evidence.' AS d2_gate_to_close
INTO dbo.silver_d2_likely_dependency_edge_queue
FROM #edges_final;

SELECT
    edge_id, relationship_family, relationship_type, from_qualified_name, to_qualified_name,
    'likely' AS current_confidence, LEFT(LTRIM(RTRIM(evidence)), 700) AS current_evidence,
    '' AS proposed_status, relationship_type AS confirmed_relationship_type,
    '' AS confirmation_source, '' AS confirmation_evidence, '' AS reviewer, '' AS reviewed_at,
    'D2 template row. Set proposed_status to confirmed, rejected, or blocked before applying any future dependency update.' AS notes
INTO dbo.silver_d2_dependency_confirmation_template
FROM #edges_final;

SELECT
    edge_id, priority_score,
    CASE WHEN priority_score >= 130 THEN 'critical' WHEN priority_score >= 105 THEN 'high' WHEN priority_score >= 80 THEN 'medium' ELSE 'low' END AS priority_band,
    relationship_family, relationship_type, from_qualified_name, to_qualified_name, readonly_method,
    preferred_confirmation_source, LEFT(LTRIM(RTRIM(evidence)), 700) AS current_evidence,
    'analysis/d2_dependency_confirmation_template.csv' AS template_path,
    'Read-only/manual confirmation target. Do not modify Fabric or dependency CSVs from this package alone.' AS notes
INTO dbo.silver_d2_readonly_confirmation_targets
FROM #edges_final;

-- ===========================================================================
-- Related-edges-per-item index (for the item queue's counts/samples).
-- ===========================================================================
IF OBJECT_ID('tempdb..#related_edges') IS NOT NULL DROP TABLE #related_edges;
SELECT item_key, direction, relationship_type, from_qualified_name, to_qualified_name
INTO #related_edges
FROM (
    SELECT LOWER(LTRIM(RTRIM(from_qualified_name))) AS item_key, 'outgoing' AS direction, relationship_type, from_qualified_name, to_qualified_name FROM #likely_edges
    UNION ALL
    SELECT LOWER(LTRIM(RTRIM(to_qualified_name))), 'incoming', relationship_type, from_qualified_name, to_qualified_name FROM #likely_edges
) u;

IF OBJECT_ID('tempdb..#related_counts') IS NOT NULL DROP TABLE #related_counts;
SELECT item_key, COUNT(*) AS related_count,
    SUM(CASE WHEN direction = 'incoming' THEN 1 ELSE 0 END) AS incoming_count,
    SUM(CASE WHEN direction = 'outgoing' THEN 1 ELSE 0 END) AS outgoing_count
INTO #related_counts
FROM #related_edges GROUP BY item_key;

IF OBJECT_ID('tempdb..#relationship_types_agg') IS NOT NULL DROP TABLE #relationship_types_agg;
;WITH t AS (SELECT item_key, relationship_type, COUNT(*) AS cnt FROM #related_edges GROUP BY item_key, relationship_type),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY cnt DESC, LOWER(relationship_type) ASC) AS rn FROM t)
SELECT item_key, STRING_AGG(relationship_type + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS relationship_types
INTO #relationship_types_agg FROM r GROUP BY item_key;

IF OBJECT_ID('tempdb..#sample_edges_agg') IS NOT NULL DROP TABLE #sample_edges_agg;
;WITH r AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY LOWER(from_qualified_name), LOWER(to_qualified_name), LOWER(relationship_type)) AS rn
    FROM (SELECT DISTINCT item_key, relationship_type, from_qualified_name, to_qualified_name FROM #related_edges) d
)
SELECT item_key, STRING_AGG(relationship_type + ': ' + from_qualified_name + ' -> ' + to_qualified_name, '; ') WITHIN GROUP (ORDER BY rn) AS sample_edges
INTO #sample_edges_agg FROM r WHERE rn <= 8 GROUP BY item_key;

-- ===========================================================================
-- Item queue.
-- ===========================================================================
SELECT
    di.priority_score,
    CASE WHEN di.priority_score >= 130 THEN 'critical' WHEN di.priority_score >= 105 THEN 'high' WHEN di.priority_score >= 80 THEN 'medium' ELSE 'low' END AS priority_band,
    di.workspace_name, ISNULL(it.workspace_environment, '') AS workspace_environment, di.item_type, di.item_name, di.item_qualified_name,
    ISNULL(it.technical_id, '') AS technical_id,
    ISNULL(rc.related_count, 0) AS related_likely_edge_count,
    ISNULL(rc.incoming_count, 0) AS incoming_likely_edge_count,
    ISNULL(rc.outgoing_count, 0) AS outgoing_likely_edge_count,
    ISNULL(rta.relationship_types, '') AS relationship_types,
    LEFT(ISNULL(sea.sample_edges, ''), 1200) AS sample_likely_edges,
    ISNULL(v2.v2_status, '') AS v2_status,
    ISNULL(v2.successor_count, 0) AS successor_count,
    ISNULL(v2.incoming_likely_edges, 0) AS incoming_likely_edges,
    ISNULL(v2.outgoing_likely_edges, 0) AS outgoing_likely_edges,
    LEFT(LTRIM(RTRIM(ISNULL(v2.v2_recommended_next_action, ''))), 700) AS v2_recommended_next_action,
    'Confirm or reject every related likely dependency edge before this item becomes an operational sequencing rule.' AS recommended_method,
    'analysis/d2_likely_dependency_edge_queue.csv' AS edge_queue_path,
    'analysis/d2_dependency_confirmation_template.csv' AS template_path
INTO dbo.silver_d2_likely_dependency_item_queue
FROM #d2_items di
LEFT JOIN #items_first it ON it.item_key = di.item_key
LEFT JOIN #v2_first v2 ON v2.item_key = di.item_key
LEFT JOIN #related_counts rc ON rc.item_key = di.item_key
LEFT JOIN #relationship_types_agg rta ON rta.item_key = di.item_key
LEFT JOIN #sample_edges_agg sea ON sea.item_key = di.item_key;

-- ===========================================================================
-- Summary.
-- ===========================================================================
SELECT summary_scope, group_key, row_count, high_or_critical_count, max_priority_score, notes
INTO dbo.silver_d2_likely_dependency_summary
FROM (
    SELECT 'total' AS summary_scope, 'D2 item blockers' AS group_key, COUNT(*) AS row_count,
        SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END) AS high_or_critical_count,
        ISNULL(MAX(priority_score), 0) AS max_priority_score,
        'Items from analysis/likely_conflict_cleanup_queue.csv phase D2.' AS notes
    FROM dbo.silver_d2_likely_dependency_item_queue

    UNION ALL
    SELECT 'total', 'D2 likely dependency edges', COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Likely dependency edges from index/dependencies.csv.'
    FROM dbo.silver_d2_likely_dependency_edge_queue

    UNION ALL
    SELECT 'relationship_type', relationship_type, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Likely edges grouped by relationship type.'
    FROM dbo.silver_d2_likely_dependency_edge_queue GROUP BY relationship_type

    UNION ALL
    SELECT 'relationship_family', relationship_family, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'Likely edges grouped by confirmation family.'
    FROM dbo.silver_d2_likely_dependency_edge_queue GROUP BY relationship_family

    UNION ALL
    SELECT 'item_type', item_type, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D2 item blockers grouped by item type.'
    FROM dbo.silver_d2_likely_dependency_item_queue GROUP BY item_type

    UNION ALL
    SELECT 'priority_band_edges', priority_band, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), 'D2 likely edges grouped by priority band.'
    FROM dbo.silver_d2_likely_dependency_edge_queue GROUP BY priority_band
) s;

END
