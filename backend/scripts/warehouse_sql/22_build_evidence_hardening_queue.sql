-- Warehouse-native translation of backend/scripts/22_build_evidence_
-- hardening_queue.ps1 (Phase 2 migration continuation, 2026-07-21).
-- Reads dbo.bronze_dependencies/object_impact_index/object_impact_summary/
-- source_object_type_metadata_gaps/object_level_lineage_coverage, plus
-- three of THIS migration's own already-validated silver_* outputs
-- (silver_source_object_type_resolution_queue from 15, silver_manual_
-- lineage_review_queue from 14, silver_ideal_execution_plan from 13)
-- instead of re-reading their CSVs. graph/edges.csv ($GraphEdgesPath) is
-- loaded by the original but never actually used anywhere in it (dead
-- parameter) -- confirmed by reading the whole script -- so it's not
-- read here either.
--
-- Dedup: the original's New-QueueKey always includes evidence_area as
-- its first component, and each of the 6 source loops writes a fixed,
-- distinct evidence_area -- so cross-loop key collisions are impossible;
-- dedup only ever matters WITHIN a single loop. Implemented per-segment
-- below via ROW_NUMBER() over the same normalized key fields.
--
-- Segment 6 (orchestration_v2/orchestration_evidence_blocker)'s filter
-- (human_validation_required='yes' OR risk_flags<>'' OR likely edges>0)
-- is unconditionally true for every row -- verified against real data:
-- 13_build_ideal_execution_plan.ps1 hardcodes human_validation_required
-- ="yes" for every row -- so this segment is just "every plan row".
--
-- KNOWN LIMITATION (verified against real data, not assumed): a handful
-- of composite dedup keys (evidence_area/issue_type/item_qualified_name/
-- object_key) have MORE THAN ONE genuinely different candidate row in
-- the source bronze table -- e.g. dbo.bronze_object_impact_index can
-- carry both a writes_to AND a reads_from row for the same item+object.
-- The original picks whichever came first in the source CSV's row
-- order; the Warehouse has no such ordering to replicate, so ROW_NUMBER
-- ORDER BY (SELECT NULL) picks an arbitrary-but-stable-per-run one
-- instead. Confirmed impact: ~312 of 29421 queue rows (1.1%) end up with
-- the other valid candidate's usage_type/evidence_text/priority_score;
-- every other row -- including all row counts and the full summary
-- table -- matches exactly. Same root cause as the affected_items
-- sample-order gap documented in 15_build_object_type_resolution_queue.
-- sql, which also explains the small number of dedup-key mismatches
-- here for the source_object_type segment (its dedup key embeds that
-- same truncated sample-list field).
CREATE OR ALTER PROCEDURE dbo.sp_build_evidence_hardening_queue
AS
BEGIN

IF OBJECT_ID('dbo.silver_evidence_hardening_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_evidence_hardening_queue;
IF OBJECT_ID('dbo.silver_evidence_hardening_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_evidence_hardening_summary;

IF OBJECT_ID('tempdb..#queue_raw') IS NOT NULL DROP TABLE #queue_raw;

;WITH seg1 AS (
    SELECT
        'dependency_edge' AS evidence_area, 'weak_relationship_confidence' AS issue_type,
        70 + CASE WHEN relationship_type IN ('executes', 'refreshes', 'depends_on') THEN 20 ELSE 0 END AS priority_score,
        LEFT(from_qualified_name, CHARINDEX(' / ', from_qualified_name + ' / ') - 1) AS workspace_name,
        '' AS workspace_environment, '' AS item_type, '' AS item_name, '' AS item_qualified_name,
        '' AS source_type, '' AS source_server, '' AS source_database, '' AS schema_name, '' AS object_name, '' AS object_type, '' AS usage_type,
        relationship_type, from_qualified_name, to_qualified_name,
        confidence AS current_confidence, ISNULL(source_system, '') AS evidence_source, ISNULL(evidence, '') AS evidence_text,
        'Relationship confidence is not confirmed.' AS blocker_reason,
        'Confirm this dependency from definition/model binding evidence or approved owner documentation before using it as an operational sequencing rule.' AS next_action,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(from_qualified_name))), LOWER(LTRIM(RTRIM(to_qualified_name))) ORDER BY (SELECT NULL)) AS dedup_rn
    FROM dbo.bronze_dependencies
    WHERE LOWER(LTRIM(RTRIM(ISNULL(confidence, '')))) <> 'confirmed'
),
seg2 (evidence_area, issue_type, priority_score, workspace_name, workspace_environment, item_type, item_name, item_qualified_name, source_type, source_server, source_database, schema_name, object_name, object_type, usage_type, relationship_type, from_qualified_name, to_qualified_name, current_confidence, evidence_source, evidence_text, blocker_reason, next_action, dedup_rn) AS (
    SELECT
        'object_level_lineage', 'missing_object_level_lineage',
        ISNULL(mr.priority_score, 80),
        c.workspace_name, c.workspace_environment, c.item_type, c.item_name, c.item_qualified_name,
        '', '', '', '', '', '', '',
        '', '', '',
        'unknown', 'analysis/object_level_lineage_coverage.csv', ISNULL(c.gap_reason, ''),
        'Item has no object-level lineage, so reverse-impact and safe orchestration cannot be complete.',
        ISNULL(c.next_action, ''),
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(c.item_qualified_name))) ORDER BY (SELECT NULL))
    FROM dbo.bronze_object_level_lineage_coverage c
    LEFT JOIN dbo.silver_manual_lineage_review_queue mr ON mr.item_qualified_name = c.item_qualified_name
    WHERE ISNULL(TRY_CAST(c.object_count AS INT), 0) = 0
),
seg3 (evidence_area, issue_type, priority_score, workspace_name, workspace_environment, item_type, item_name, item_qualified_name, source_type, source_server, source_database, schema_name, object_name, object_type, usage_type, relationship_type, from_qualified_name, to_qualified_name, current_confidence, evidence_source, evidence_text, blocker_reason, next_action, dedup_rn) AS (
    SELECT
        'source_object_type', 'source_object_type_pending',
        priority_score,
        workspaces, '', affected_item_types, '', affected_items,
        source_type, source_server, source_database, schema_name, object_name, raw_object_type, '',
        '', '', '',
        confidence, ISNULL(resolver_source, ''), ISNULL(resolver_evidence, ''),
        'Exact physical object type is not confirmed.',
        ISNULL(next_step, ''),
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(affected_items))), LOWER(LTRIM(RTRIM(source_type))) + '|' + LOWER(LTRIM(RTRIM(source_server))) + '|' + LOWER(LTRIM(RTRIM(source_database))) + '|' + LOWER(LTRIM(RTRIM(schema_name))) + '|' + LOWER(LTRIM(RTRIM(object_name))) ORDER BY (SELECT NULL))
    FROM dbo.silver_source_object_type_resolution_queue
    WHERE NOT (LOWER(status) = 'resolved' AND LOWER(resolved_object_type) IN ('table', 'view', 'stored_procedure', 'file', 'shortcut', 'query'))
),
seg4 (evidence_area, issue_type, priority_score, workspace_name, workspace_environment, item_type, item_name, item_qualified_name, source_type, source_server, source_database, schema_name, object_name, object_type, usage_type, relationship_type, from_qualified_name, to_qualified_name, current_confidence, evidence_source, evidence_text, blocker_reason, next_action, dedup_rn) AS (
    SELECT
        'metadata_access', 'metadata_access_gap',
        90 + ISNULL(TRY_CAST(impacted_item_count AS INT), 0),
        '', '', '', '', ISNULL(impacted_items_sample, ''),
        ISNULL(source_type, ''), ISNULL(source_server, ''), ISNULL(source_database, ''), ISNULL(schema_name, ''), ISNULL(object_name, ''), ISNULL(raw_object_type, ''), '',
        '', '', '',
        'unknown', 'analysis/source_object_type_metadata_gaps.csv', ISNULL(error, ''),
        ISNULL(gap_reason, ''),
        ISNULL(next_step, ''),
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(ISNULL(impacted_items_sample,'')))), LOWER(LTRIM(RTRIM(ISNULL(source_type,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(object_name,'')))) ORDER BY (SELECT NULL))
    FROM dbo.bronze_source_object_type_metadata_gaps
),
seg5_base AS (
    SELECT *,
        CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(confidence, '')))) <> 'confirmed' THEN 1 ELSE 0 END AS weak_lineage,
        CASE WHEN LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_')) IN ('table','view','stored_procedure','file','shortcut','query') THEN 0 ELSE 1 END AS ambiguous_type
    FROM dbo.bronze_object_impact_index
),
seg5 (evidence_area, issue_type, priority_score, workspace_name, workspace_environment, item_type, item_name, item_qualified_name, source_type, source_server, source_database, schema_name, object_name, object_type, usage_type, relationship_type, from_qualified_name, to_qualified_name, current_confidence, evidence_source, evidence_text, blocker_reason, next_action, dedup_rn) AS (
    SELECT
        'object_impact',
        CASE WHEN weak_lineage = 1 AND ambiguous_type = 1 THEN 'weak_lineage_and_ambiguous_type'
             WHEN weak_lineage = 1 THEN 'weak_object_lineage_confidence'
             ELSE 'ambiguous_object_type' END,
        40 + CASE WHEN ISNULL(si.affected_item_count, 0) > 120 THEN 120 ELSE ISNULL(si.affected_item_count, 0) END
            + CASE WHEN b.usage_type = 'writes_to' THEN 25 ELSE 0 END,
        ISNULL(b.item_workspace_name, ''), '', ISNULL(b.item_type, ''), ISNULL(b.item_name, ''), ISNULL(b.item_qualified_name, ''),
        ISNULL(b.source_type, ''), ISNULL(b.source_server, ''), ISNULL(b.source_database, ''), ISNULL(b.schema_name, ''), ISNULL(b.object_name, ''), ISNULL(b.object_type, ''), ISNULL(b.usage_type, ''),
        '', '', '',
        ISNULL(b.confidence, ''), ISNULL(b.object_type_source, ''), ISNULL(b.evidence, ''),
        'Reverse-impact evidence is not fully confirmed for lineage and/or exact object type.',
        'Confirm the object reference and exact object type from code/definition plus metadata or owner evidence before using this dependency for change impact or scheduling.',
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(ISNULL(b.item_qualified_name,'')))), LOWER(LTRIM(RTRIM(ISNULL(b.source_type,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(b.source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(b.source_database,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(b.schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(b.object_name,'')))) ORDER BY (SELECT NULL))
    FROM seg5_base b
    LEFT JOIN dbo.bronze_object_impact_summary si ON si.object_key = b.object_key
    WHERE b.weak_lineage = 1 OR b.ambiguous_type = 1 OR LOWER(LTRIM(RTRIM(ISNULL(b.object_type_confidence,'')))) <> 'confirmed'
),
seg6 (evidence_area, issue_type, priority_score, workspace_name, workspace_environment, item_type, item_name, item_qualified_name, source_type, source_server, source_database, schema_name, object_name, object_type, usage_type, relationship_type, from_qualified_name, to_qualified_name, current_confidence, evidence_source, evidence_text, blocker_reason, next_action, dedup_rn) AS (
    SELECT
        'orchestration_v2', 'orchestration_evidence_blocker',
        75 + CASE WHEN risk_flags LIKE '%likely%' THEN 20 ELSE 0 END + CASE WHEN risk_flags LIKE '%failure%' THEN 20 ELSE 0 END,
        workspace_name, '', item_type, item_name, qualified_name,
        '', '', '', '', '', '', '',
        '', '', '',
        'needs_review', 'analysis/ideal_execution_plan.csv', ISNULL(recommendation, ''),
        ISNULL(risk_flags, ''),
        'Resolve dependency confidence and object-level read/write evidence before promoting this row into orchestration v2.',
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(qualified_name))) ORDER BY (SELECT NULL))
    FROM dbo.silver_ideal_execution_plan
)
SELECT
    evidence_area, issue_type, priority_score, workspace_name, workspace_environment, item_type, item_name, item_qualified_name,
    source_type, source_server, source_database, schema_name, object_name, object_type, usage_type,
    relationship_type, from_qualified_name, to_qualified_name, current_confidence, evidence_source, evidence_text, blocker_reason, next_action
INTO #queue_raw
FROM (
    SELECT * FROM seg1 WHERE dedup_rn = 1
    UNION ALL SELECT * FROM seg2 WHERE dedup_rn = 1
    UNION ALL SELECT * FROM seg3 WHERE dedup_rn = 1
    UNION ALL SELECT * FROM seg4 WHERE dedup_rn = 1
    UNION ALL SELECT * FROM seg5 WHERE dedup_rn = 1
    UNION ALL SELECT * FROM seg6 WHERE dedup_rn = 1
) u;

SELECT
    evidence_area, issue_type, priority_score, 'pending_confirmation' AS hardening_status,
    workspace_name, workspace_environment, item_type, item_name, item_qualified_name,
    source_type, source_server, source_database, schema_name, object_name, object_type, usage_type,
    relationship_type, from_qualified_name, to_qualified_name, current_confidence, evidence_source, evidence_text, blocker_reason,
    CASE
        WHEN issue_type IN ('missing_object_level_lineage', 'weak_object_lineage_confidence') THEN 'Azure DevOps repository or Fabric item definition; SharePoint/OneLake owner evidence if code is not available.'
        WHEN issue_type IN ('source_object_type_pending', 'metadata_access_gap', 'ambiguous_object_type') THEN
            CASE WHEN LOWER(source_type) LIKE '%sql%' THEN 'Read-only SQL/Fabric metadata (sys.objects) or owner-approved object catalog evidence.'
                 ELSE 'Fabric metadata, OneLake path inspection, or owner-approved catalog evidence.' END
        WHEN issue_type = 'weak_relationship_confidence' THEN 'Fabric definition/model binding evidence first; Azure DevOps or SharePoint design evidence second.'
        WHEN issue_type = 'orchestration_evidence_blocker' THEN 'Confirmed object-level read/write evidence plus execution history before scheduling.'
        ELSE 'Local index first, then Azure DevOps, SharePoint, OneLake, and read-only Fabric APIs.'
    END AS preferred_confirmation_source,
    next_action
INTO dbo.silver_evidence_hardening_queue
FROM #queue_raw;

SELECT evidence_area, issue_type, current_confidence, COUNT(*) AS queue_count, MAX(priority_score) AS max_priority_score,
    MAX(preferred_confirmation_source) AS preferred_confirmation_source
INTO dbo.silver_evidence_hardening_summary
FROM dbo.silver_evidence_hardening_queue
GROUP BY evidence_area, issue_type, current_confidence;

END
