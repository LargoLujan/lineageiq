-- Warehouse-native translation of backend/scripts/46_build_d8_parallel_
-- candidate_retest_package.ps1 (Phase 2 migration continuation,
-- 2026-07-21). Reads dbo.silver_orchestration_v2_parallel_candidates
-- (24), dbo.silver_likely_conflict_cleanup_queue (25, phase D8),
-- dbo.silver_object_read_write_classification (23), dbo.silver_d1_
-- closure_control_queue, dbo.silver_d3_item_closure_control_queue,
-- dbo.silver_d4_exact_object_type_source_queue (29), dbo.silver_d5_
-- closure_control_queue, dbo.silver_d5_conflict_participant_review.
-- d8_id ("D8P00001", ...) is assigned in the SAME sorted order used for
-- final export (shared_write_object_count DESC, expected_parallel_
-- window_seconds DESC, workspace_name), matching the original since it
-- also assigns IDs after sorting, not in file order. All linked-ID list
-- fields (linked_d1_ids, ..., object_key_sample) go through the
-- original's Join-Unique (case-insensitive sort+dedupe, alphabetical),
-- so no file-row-order concern applies to those -- replicated here via
-- DISTINCT + STRING_AGG ordered by LOWER().
-- IMPORTANT VALIDATION NOTE (2026-07-21): dbo.silver_orchestration_v2_
-- parallel_candidates is currently EMPTY in this project (0 rows, both
-- in the live Warehouse table and in a freshly regenerated local
-- analysis/orchestration_v2_parallel_candidates.csv), so this procedure
-- could only be validated structurally: deploy succeeds, all 5 non-
-- template output tables' column lists match the original's CSV headers
-- exactly in name and order, and the summary table matches the PS
-- baseline exactly (8/8 rows, all row_count=0). The actual per-pair
-- join/aggregation logic (pair-key symmetry, D1/D3/D4/D5 linkage,
-- priority scoring) has NOT been exercised against real data and should
-- be re-validated field-by-field the next time orchestration v2 produces
-- parallel candidates again.
CREATE OR ALTER PROCEDURE dbo.sp_build_d8_parallel_candidate_retest_package
AS
BEGIN

IF OBJECT_ID('dbo.silver_d8_parallel_candidate_retest_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d8_parallel_candidate_retest_queue;
IF OBJECT_ID('dbo.silver_d8_candidate_item_evidence', 'U') IS NOT NULL DROP TABLE dbo.silver_d8_candidate_item_evidence;
IF OBJECT_ID('dbo.silver_d8_candidate_object_evidence', 'U') IS NOT NULL DROP TABLE dbo.silver_d8_candidate_object_evidence;
IF OBJECT_ID('dbo.silver_d8_missing_object_evidence_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d8_missing_object_evidence_targets;
IF OBJECT_ID('dbo.silver_d8_read_write_validation_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_d8_read_write_validation_targets;
IF OBJECT_ID('dbo.silver_d8_nonprod_parallel_test_candidates', 'U') IS NOT NULL DROP TABLE dbo.silver_d8_nonprod_parallel_test_candidates;
IF OBJECT_ID('dbo.silver_d8_parallel_retest_decision_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d8_parallel_retest_decision_template;
IF OBJECT_ID('dbo.silver_d8_external_readonly_action_plan', 'U') IS NOT NULL DROP TABLE dbo.silver_d8_external_readonly_action_plan;
IF OBJECT_ID('dbo.silver_d8_parallel_candidate_retest_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d8_parallel_candidate_retest_summary;

-- ===========================================================================
-- D8 cleanup priority lookup, keyed by an order-independent pair key.
-- ===========================================================================
IF OBJECT_ID('tempdb..#cleanup_pair') IS NOT NULL DROP TABLE #cleanup_pair;
;WITH d8c AS (
    SELECT item_qualified_name, priority_score,
        CHARINDEX(' <-> ', item_qualified_name) AS sep_pos
    FROM dbo.silver_likely_conflict_cleanup_queue WHERE phase_id = 'D8'
),
parsed AS (
    SELECT priority_score,
        LOWER(LTRIM(RTRIM(LEFT(item_qualified_name, sep_pos - 1)))) AS a_norm,
        LOWER(LTRIM(RTRIM(SUBSTRING(item_qualified_name, sep_pos + 5, LEN(item_qualified_name))))) AS b_norm
    FROM d8c WHERE sep_pos > 0
),
keyed AS (
    SELECT priority_score,
        (CASE WHEN a_norm <= b_norm THEN a_norm ELSE b_norm END) + ' <-> ' + (CASE WHEN a_norm <= b_norm THEN b_norm ELSE a_norm END) AS pair_key
    FROM parsed
)
SELECT pair_key, priority_score
INTO #cleanup_pair
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY pair_key ORDER BY (SELECT NULL)) AS rn FROM keyed
) x WHERE rn = 1;

-- ===========================================================================
-- Read/write rows, normalized per-item and per-object-key.
-- ===========================================================================
IF OBJECT_ID('tempdb..#rw') IS NOT NULL DROP TABLE #rw;
SELECT
    LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, item_qualified_name,
    LOWER(LTRIM(RTRIM(ISNULL(object_key,'')))) AS object_key_norm, ISNULL(object_key,'') AS object_key,
    ISNULL(object_display_name,'') AS object_display_name, ISNULL(operation_type,'') AS operation_type,
    LOWER(LTRIM(RTRIM(ISNULL(operation_type,'')))) AS operation_norm,
    ISNULL(usage_type,'') AS usage_type, ISNULL(source_type,'') AS source_type, ISNULL(object_type,'') AS object_type,
    ISNULL(object_type_status,'') AS object_type_status, LOWER(LTRIM(RTRIM(ISNULL(object_type_status,'')))) AS object_type_status_norm,
    ISNULL(lineage_confidence,'') AS lineage_confidence, LOWER(LTRIM(RTRIM(ISNULL(lineage_confidence,'')))) AS lineage_confidence_norm,
    ISNULL(hardening_status,'') AS hardening_status, LOWER(LTRIM(RTRIM(ISNULL(hardening_status,'')))) AS hardening_status_norm,
    ISNULL(hardening_issue_types,'') AS hardening_issue_types,
    ISNULL(orchestration_parallel_readiness,'') AS orchestration_parallel_readiness,
    ISNULL(scheduling_readiness,'') AS scheduling_readiness, LOWER(LTRIM(RTRIM(ISNULL(scheduling_readiness,'')))) AS scheduling_readiness_norm,
    ISNULL(evidence,'') AS evidence
INTO #rw
FROM dbo.silver_object_read_write_classification
WHERE ISNULL(item_qualified_name,'') <> '';

IF OBJECT_ID('tempdb..#item_rw_counts') IS NOT NULL DROP TABLE #item_rw_counts;
SELECT item_key,
    COUNT(*) AS object_row_count,
    SUM(CASE WHEN operation_norm = 'read' THEN 1 ELSE 0 END) AS read_count,
    SUM(CASE WHEN operation_norm = 'write' THEN 1 ELSE 0 END) AS write_count,
    SUM(CASE WHEN operation_norm = 'execute' THEN 1 ELSE 0 END) AS execute_count,
    SUM(CASE WHEN operation_norm NOT IN ('read','write','execute') THEN 1 ELSE 0 END) AS unknown_operation_count,
    SUM(CASE WHEN operation_norm = 'unknown' OR operation_norm = '' THEN 1 ELSE 0 END) AS missing_operation_count,
    SUM(CASE WHEN scheduling_readiness_norm = 'needs_lineage_confirmation' OR hardening_status_norm = 'pending_confirmation' OR lineage_confidence_norm = 'likely' THEN 1 ELSE 0 END) AS lineage_blocker_count,
    SUM(CASE WHEN object_type_status_norm IN ('ambiguous','unknown','pending') THEN 1 ELSE 0 END) AS object_type_blocker_count
INTO #item_rw_counts
FROM #rw
GROUP BY item_key;

IF OBJECT_ID('tempdb..#item_object_key_sample') IS NOT NULL DROP TABLE #item_object_key_sample;
;WITH d AS (SELECT DISTINCT item_key, object_key FROM #rw WHERE object_key <> ''),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY LOWER(object_key)) AS rn FROM d)
SELECT item_key, LEFT(STRING_AGG(object_key, '; ') WITHIN GROUP (ORDER BY rn), 900) AS object_key_sample
INTO #item_object_key_sample FROM r WHERE rn <= 8 GROUP BY item_key;

-- ===========================================================================
-- D1/D3 links: item-level tables, direct join by item_qualified_name.
-- ===========================================================================
IF OBJECT_ID('tempdb..#item_d1_agg') IS NOT NULL DROP TABLE #item_d1_agg;
;WITH d AS (SELECT DISTINCT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, d1_id FROM dbo.silver_d1_closure_control_queue WHERE ISNULL(d1_id,'') <> ''),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY LOWER(d1_id)) AS rn FROM d)
SELECT item_key, STRING_AGG(d1_id, '; ') WITHIN GROUP (ORDER BY rn) AS linked_d1_ids
INTO #item_d1_agg FROM r GROUP BY item_key;

IF OBJECT_ID('tempdb..#item_d3_agg') IS NOT NULL DROP TABLE #item_d3_agg;
;WITH d AS (SELECT DISTINCT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, item_review_id FROM dbo.silver_d3_item_closure_control_queue WHERE ISNULL(item_review_id,'') <> ''),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY LOWER(item_review_id)) AS rn FROM d)
SELECT item_key, STRING_AGG(item_review_id, '; ') WITHIN GROUP (ORDER BY rn) AS linked_d3_item_review_ids
INTO #item_d3_agg FROM r GROUP BY item_key;

-- ===========================================================================
-- D4/D5 links: object-key-level tables, joined through #rw's object_key.
-- ===========================================================================
IF OBJECT_ID('tempdb..#d4_source') IS NOT NULL DROP TABLE #d4_source;
SELECT source_id,
    LOWER(LTRIM(RTRIM(source_type))) + '|' + LOWER(LTRIM(RTRIM(source_server))) + '|' + LOWER(LTRIM(RTRIM(source_database))) + '|' +
        LOWER(LTRIM(RTRIM(schema_name))) + '|' + LOWER(LTRIM(RTRIM(object_name))) AS object_key_norm
INTO #d4_source
FROM dbo.silver_d4_exact_object_type_source_queue;

IF OBJECT_ID('tempdb..#rw_d4') IS NOT NULL DROP TABLE #rw_d4;
SELECT DISTINCT rw.item_key, rw.object_key_norm AS rw_object_key, d4.source_id
INTO #rw_d4
FROM #rw rw
INNER JOIN #d4_source d4 ON d4.object_key_norm = rw.object_key_norm
WHERE rw.object_key_norm <> '';

IF OBJECT_ID('tempdb..#item_d4_agg') IS NOT NULL DROP TABLE #item_d4_agg;
;WITH d AS (SELECT DISTINCT item_key, source_id FROM #rw_d4),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY LOWER(source_id)) AS rn FROM d)
SELECT item_key, STRING_AGG(source_id, '; ') WITHIN GROUP (ORDER BY rn) AS linked_d4_source_ids
INTO #item_d4_agg FROM r GROUP BY item_key;

IF OBJECT_ID('tempdb..#object_d4_agg') IS NOT NULL DROP TABLE #object_d4_agg;
;WITH d AS (SELECT DISTINCT rw_object_key, source_id FROM #rw_d4),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY rw_object_key ORDER BY LOWER(source_id)) AS rn FROM d)
SELECT rw_object_key, STRING_AGG(source_id, '; ') WITHIN GROUP (ORDER BY rn) AS linked_d4_source_ids
INTO #object_d4_agg FROM r GROUP BY rw_object_key;

IF OBJECT_ID('tempdb..#d5_source') IS NOT NULL DROP TABLE #d5_source;
SELECT conflict_id, LOWER(LTRIM(RTRIM(object_key))) AS object_key_norm
INTO #d5_source
FROM dbo.silver_d5_closure_control_queue;

IF OBJECT_ID('tempdb..#rw_d5') IS NOT NULL DROP TABLE #rw_d5;
SELECT DISTINCT rw.item_key, rw.object_key_norm AS rw_object_key, d5.conflict_id
INTO #rw_d5
FROM #rw rw
INNER JOIN #d5_source d5 ON d5.object_key_norm = rw.object_key_norm
WHERE rw.object_key_norm <> '';

IF OBJECT_ID('tempdb..#participant_d5') IS NOT NULL DROP TABLE #participant_d5;
SELECT DISTINCT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, conflict_id
INTO #participant_d5
FROM dbo.silver_d5_conflict_participant_review
WHERE ISNULL(conflict_id,'') <> '';

IF OBJECT_ID('tempdb..#item_d5_all') IS NOT NULL DROP TABLE #item_d5_all;
SELECT item_key, conflict_id
INTO #item_d5_all
FROM #rw_d5
UNION
SELECT item_key, conflict_id FROM #participant_d5;

IF OBJECT_ID('tempdb..#item_d5_agg') IS NOT NULL DROP TABLE #item_d5_agg;
;WITH r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY LOWER(conflict_id)) AS rn FROM #item_d5_all)
SELECT item_key, STRING_AGG(conflict_id, '; ') WITHIN GROUP (ORDER BY rn) AS linked_d5_conflict_ids
INTO #item_d5_agg FROM r GROUP BY item_key;

IF OBJECT_ID('tempdb..#object_d5_agg') IS NOT NULL DROP TABLE #object_d5_agg;
;WITH d AS (SELECT DISTINCT rw_object_key, conflict_id FROM #rw_d5),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY rw_object_key ORDER BY LOWER(conflict_id)) AS rn FROM d)
SELECT rw_object_key, STRING_AGG(conflict_id, '; ') WITHIN GROUP (ORDER BY rn) AS linked_d5_conflict_ids
INTO #object_d5_agg FROM r GROUP BY rw_object_key;

-- ===========================================================================
-- Per-item stats (combines all the above into one row per item).
-- ===========================================================================
IF OBJECT_ID('tempdb..#item_stats') IS NOT NULL DROP TABLE #item_stats;
SELECT
    c.item_key, ISNULL(c.object_row_count,0) AS object_row_count, ISNULL(c.read_count,0) AS read_count,
    ISNULL(c.write_count,0) AS write_count, ISNULL(c.execute_count,0) AS execute_count,
    ISNULL(c.unknown_operation_count,0) AS unknown_operation_count, ISNULL(c.lineage_blocker_count,0) AS lineage_blocker_count,
    ISNULL(c.object_type_blocker_count,0) AS object_type_blocker_count, ISNULL(c.missing_operation_count,0) AS missing_operation_count,
    ISNULL(d1.linked_d1_ids,'') AS linked_d1_ids, ISNULL(d3.linked_d3_item_review_ids,'') AS linked_d3_item_review_ids,
    ISNULL(d4.linked_d4_source_ids,'') AS linked_d4_source_ids, ISNULL(d5.linked_d5_conflict_ids,'') AS linked_d5_conflict_ids,
    ISNULL(oks.object_key_sample,'') AS object_key_sample
INTO #item_stats
FROM #item_rw_counts c
LEFT JOIN #item_d1_agg d1 ON d1.item_key = c.item_key
LEFT JOIN #item_d3_agg d3 ON d3.item_key = c.item_key
LEFT JOIN #item_d4_agg d4 ON d4.item_key = c.item_key
LEFT JOIN #item_d5_agg d5 ON d5.item_key = c.item_key
LEFT JOIN #item_object_key_sample oks ON oks.item_key = c.item_key;

-- ===========================================================================
-- Main retest queue.
-- ===========================================================================
IF OBJECT_ID('tempdb..#pairs') IS NOT NULL DROP TABLE #pairs;
SELECT
    'D8P' + RIGHT('0000' + CAST(ROW_NUMBER() OVER (ORDER BY ISNULL(shared_write_object_count,0) DESC, ISNULL(expected_parallel_window_seconds,0) DESC, LOWER(workspace_name)) AS VARCHAR(10)), 5) AS d8_id,
    workspace_name, candidate_a, candidate_b,
    LOWER(LTRIM(RTRIM(candidate_a))) AS a_key, LOWER(LTRIM(RTRIM(candidate_b))) AS b_key,
    item_type_a, item_type_b, expected_parallel_window_seconds, direct_dependency_exists,
    ISNULL(shared_object_count,0) AS shared_object_count, ISNULL(shared_write_object_count,0) AS shared_write_object_count,
    candidate_status, ISNULL(candidate_a_read_count,0) AS candidate_a_read_count, ISNULL(candidate_a_write_count,0) AS candidate_a_write_count,
    ISNULL(candidate_a_blocker_count,0) AS candidate_a_blocker_count, ISNULL(candidate_b_read_count,0) AS candidate_b_read_count,
    ISNULL(candidate_b_write_count,0) AS candidate_b_write_count, ISNULL(candidate_b_blocker_count,0) AS candidate_b_blocker_count,
    sample_shared_objects,
    (CASE WHEN LOWER(LTRIM(RTRIM(candidate_a))) <= LOWER(LTRIM(RTRIM(candidate_b)))
          THEN LOWER(LTRIM(RTRIM(candidate_a))) + ' <-> ' + LOWER(LTRIM(RTRIM(candidate_b)))
          ELSE LOWER(LTRIM(RTRIM(candidate_b))) + ' <-> ' + LOWER(LTRIM(RTRIM(candidate_a)))
     END) AS pair_key
INTO #pairs
FROM dbo.silver_orchestration_v2_parallel_candidates;

IF OBJECT_ID('tempdb..#pairs_final') IS NOT NULL DROP TABLE #pairs_final;
SELECT
    p.*,
    (CASE p.candidate_status
        WHEN 'blocked_missing_object_evidence' THEN 'blocked_pending_d1_object_evidence'
        WHEN 'blocked_read_write_evidence' THEN 'blocked_pending_d3_d4_d5_read_write_validation'
        WHEN 'blocked_direct_dependency' THEN 'blocked_direct_dependency'
        WHEN 'blocked_shared_object_write' THEN 'blocked_pending_d5_write_serialization'
        WHEN 'candidate_shared_reads_only' THEN 'nonprod_parallel_retest_candidate_shared_reads'
        WHEN 'parallel_candidate_no_shared_objects' THEN 'nonprod_parallel_retest_candidate_no_shared_objects'
        ELSE 'manual_parallel_retest_review_required' END) AS closure_opportunity,
    ISNULL(cp.priority_score, 0) AS cleanup_priority_score,
    CASE WHEN cp.pair_key IS NOT NULL THEN 1 ELSE 0 END AS has_cleanup_match,
    ISNULL(astat.object_row_count,0) AS a_object_row_count, ISNULL(bstat.object_row_count,0) AS b_object_row_count,
    ISNULL(astat.linked_d1_ids,'') AS a_linked_d1_ids, ISNULL(bstat.linked_d1_ids,'') AS b_linked_d1_ids,
    ISNULL(astat.linked_d3_item_review_ids,'') AS a_linked_d3_ids, ISNULL(bstat.linked_d3_item_review_ids,'') AS b_linked_d3_ids,
    ISNULL(astat.linked_d4_source_ids,'') AS a_linked_d4_ids, ISNULL(bstat.linked_d4_source_ids,'') AS b_linked_d4_ids,
    ISNULL(astat.linked_d5_conflict_ids,'') AS a_linked_d5_ids, ISNULL(bstat.linked_d5_conflict_ids,'') AS b_linked_d5_ids
INTO #pairs_final
FROM #pairs p
LEFT JOIN #cleanup_pair cp ON cp.pair_key = p.pair_key
LEFT JOIN #item_stats astat ON astat.item_key = p.a_key
LEFT JOIN #item_stats bstat ON bstat.item_key = p.b_key;

-- Combine A+B linked-id sets (case-insensitive dedupe+sort, same as the
-- original's re-split/Join-Unique of both sides' already-joined lists).
IF OBJECT_ID('tempdb..#pair_link_src') IS NOT NULL DROP TABLE #pair_link_src;
SELECT d8_id, 'd1' AS kind, LTRIM(RTRIM(v.value)) AS id_value
INTO #pair_link_src
FROM #pairs_final CROSS APPLY STRING_SPLIT(a_linked_d1_ids + ';' + b_linked_d1_ids, ';') v WHERE LTRIM(RTRIM(v.value)) <> ''
UNION ALL
SELECT d8_id, 'd3', LTRIM(RTRIM(v.value)) FROM #pairs_final CROSS APPLY STRING_SPLIT(a_linked_d3_ids + ';' + b_linked_d3_ids, ';') v WHERE LTRIM(RTRIM(v.value)) <> ''
UNION ALL
SELECT d8_id, 'd4', LTRIM(RTRIM(v.value)) FROM #pairs_final CROSS APPLY STRING_SPLIT(a_linked_d4_ids + ';' + b_linked_d4_ids, ';') v WHERE LTRIM(RTRIM(v.value)) <> ''
UNION ALL
SELECT d8_id, 'd5', LTRIM(RTRIM(v.value)) FROM #pairs_final CROSS APPLY STRING_SPLIT(a_linked_d5_ids + ';' + b_linked_d5_ids, ';') v WHERE LTRIM(RTRIM(v.value)) <> '';

IF OBJECT_ID('tempdb..#pair_link_agg') IS NOT NULL DROP TABLE #pair_link_agg;
;WITH d AS (SELECT DISTINCT d8_id, kind, id_value FROM #pair_link_src),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY d8_id, kind ORDER BY LOWER(id_value)) AS rn FROM d)
SELECT d8_id, kind, STRING_AGG(id_value, '; ') WITHIN GROUP (ORDER BY rn) AS ids
INTO #pair_link_agg FROM r GROUP BY d8_id, kind;

IF OBJECT_ID('tempdb..#pairs_linked') IS NOT NULL DROP TABLE #pairs_linked;
SELECT
    pf.*,
    ISNULL(l1.ids,'') AS linked_d1_ids, ISNULL(l3.ids,'') AS linked_d3_item_review_ids,
    ISNULL(l4.ids,'') AS linked_d4_source_ids, ISNULL(l5.ids,'') AS linked_d5_conflict_ids
INTO #pairs_linked
FROM #pairs_final pf
LEFT JOIN #pair_link_agg l1 ON l1.d8_id = pf.d8_id AND l1.kind = 'd1'
LEFT JOIN #pair_link_agg l3 ON l3.d8_id = pf.d8_id AND l3.kind = 'd3'
LEFT JOIN #pair_link_agg l4 ON l4.d8_id = pf.d8_id AND l4.kind = 'd4'
LEFT JOIN #pair_link_agg l5 ON l5.d8_id = pf.d8_id AND l5.kind = 'd5';

IF OBJECT_ID('tempdb..#pairs_priced') IS NOT NULL DROP TABLE #pairs_priced;
SELECT *,
    (CASE WHEN has_cleanup_match = 1 THEN cleanup_priority_score ELSE 50 + (shared_write_object_count * 10) + (shared_object_count * 2) END) AS priority_score,
    (CASE WHEN closure_opportunity LIKE 'blocked_%' THEN 'blocked'
          WHEN closure_opportunity LIKE 'nonprod_parallel_retest_candidate%' THEN 'ready_for_owner_nonprod_retest_review'
          ELSE 'manual_review_required' END) AS retest_status
INTO #pairs_priced
FROM #pairs_linked;

SELECT
    d8_id, priority_score,
    (CASE WHEN priority_score >= 85 THEN 'critical' WHEN priority_score >= 75 THEN 'high' WHEN priority_score >= 60 THEN 'medium' ELSE 'low' END) AS priority_band,
    retest_status, closure_opportunity, workspace_name, candidate_status, candidate_a, candidate_b, item_type_a, item_type_b,
    expected_parallel_window_seconds, direct_dependency_exists, shared_object_count, shared_write_object_count,
    a_object_row_count AS candidate_a_object_rows, candidate_a_read_count, candidate_a_write_count, candidate_a_blocker_count,
    b_object_row_count AS candidate_b_object_rows, candidate_b_read_count, candidate_b_write_count, candidate_b_blocker_count,
    sample_shared_objects, linked_d1_ids, linked_d3_item_review_ids, linked_d4_source_ids, linked_d5_conflict_ids,
    (CASE WHEN phase_summary.summary <> '' THEN phase_summary.summary
          WHEN retest_status = 'blocked' THEN 'manual blocker review'
          ELSE 'owner non-production approval' END) AS blocking_phase_summary,
    (CASE closure_opportunity
        WHEN 'blocked_pending_d1_object_evidence' THEN 'Keep blocked until both candidate items have object-level evidence or an explicit D1 accepted decision.'
        WHEN 'blocked_pending_d3_d4_d5_read_write_validation' THEN 'Keep blocked until lineage confidence, exact object type, and write/serialization guard evidence are reviewed.'
        WHEN 'blocked_direct_dependency' THEN 'Reject or keep serial unless the direct dependency is proven false and dependency evidence is updated.'
        WHEN 'blocked_pending_d5_write_serialization' THEN 'Keep blocked until shared write objects have a reviewed D5 serialization decision.'
        WHEN 'nonprod_parallel_retest_candidate_shared_reads' THEN 'Review owner and run a controlled non-production parallel test only if shared objects are read-only and all guards remain clean.'
        WHEN 'nonprod_parallel_retest_candidate_no_shared_objects' THEN 'Review owner and run a controlled non-production parallel test only after confirming no hidden shared state.'
        ELSE 'Review the pair manually before selecting a D8 decision.' END) AS recommended_d8_decision,
    (CASE closure_opportunity
        WHEN 'blocked_pending_d1_object_evidence' THEN 'Review linked D1 item targets and capture object-level lineage for both candidate items before retesting parallelism.'
        WHEN 'blocked_pending_d3_d4_d5_read_write_validation' THEN 'Review D3 lineage, D4 exact object type, D5 conflict/guard evidence, and item code definitions before approving any parallel test.'
        WHEN 'blocked_direct_dependency' THEN 'Review dependency evidence in read-only mode and keep the pair serial unless the dependency is rejected with evidence.'
        WHEN 'blocked_pending_d5_write_serialization' THEN 'Review shared write objects and D5 serialization decisions before any parallel retest.'
        WHEN 'nonprod_parallel_retest_candidate_shared_reads' THEN 'Prepare an owner-approved non-production test with run isolation, timing capture, and rollback/abort criteria.'
        WHEN 'nonprod_parallel_retest_candidate_no_shared_objects' THEN 'Prepare an owner-approved non-production test and verify there is no unindexed shared state.'
        ELSE 'Review local evidence and owner evidence before selecting a D8 decision.' END) AS readonly_action,
    'analysis/d8_parallel_retest_decision_template.csv' AS decision_template_path
INTO dbo.silver_d8_parallel_candidate_retest_queue
FROM #pairs_priced
CROSS APPLY (SELECT
    STUFF(
        ISNULL(CASE WHEN linked_d1_ids <> '' THEN '; D1 object evidence' END, '') +
        ISNULL(CASE WHEN linked_d3_item_review_ids <> '' THEN '; D3 lineage confirmation' END, '') +
        ISNULL(CASE WHEN linked_d4_source_ids <> '' THEN '; D4 exact object type' END, '') +
        ISNULL(CASE WHEN linked_d5_conflict_ids <> '' THEN '; D5 write/conflict guard' END, ''),
        1, 2, ''
    ) AS summary
) phase_summary;

SELECT * INTO dbo.silver_d8_missing_object_evidence_targets FROM dbo.silver_d8_parallel_candidate_retest_queue WHERE closure_opportunity = 'blocked_pending_d1_object_evidence';
SELECT * INTO dbo.silver_d8_read_write_validation_targets FROM dbo.silver_d8_parallel_candidate_retest_queue WHERE closure_opportunity = 'blocked_pending_d3_d4_d5_read_write_validation';
SELECT * INTO dbo.silver_d8_nonprod_parallel_test_candidates FROM dbo.silver_d8_parallel_candidate_retest_queue WHERE retest_status = 'ready_for_owner_nonprod_retest_review';

SELECT
    d8_id, workspace_name, candidate_a, candidate_b, candidate_status, closure_opportunity, retest_status,
    '' AS proposed_d8_decision,
    'approve_nonprod_parallel_test; keep_serial; serialize_then_parallel; reject_parallel_candidate; blocked_pending_d1; blocked_pending_d3_d4; blocked_pending_d5; blocked_pending_owner; manual_review_required' AS allowed_decisions,
    '' AS proposed_nonprod_test_scope, '' AS proposed_parallel_guard, '' AS proposed_serialization_rule, '' AS proposed_abort_criteria,
    '' AS owner, '' AS confirmation_source, '' AS confirmation_evidence, '' AS reviewer, '' AS reviewed_at,
    recommended_d8_decision AS next_action,
    'Fill this row before treating D8 as closed. Do not run or schedule parallel execution from this package alone.' AS notes
INTO dbo.silver_d8_parallel_retest_decision_template
FROM dbo.silver_d8_parallel_candidate_retest_queue;

SELECT
    d8_id, priority_score, priority_band, retest_status, closure_opportunity, workspace_name, candidate_a, candidate_b,
    readonly_action AS human_readonly_action, linked_d1_ids, linked_d3_item_review_ids, linked_d4_source_ids, linked_d5_conflict_ids,
    decision_template_path,
    'Read-only/manual D8 action. Last operational step remains human approval and execution outside this repo.' AS notes
INTO dbo.silver_d8_external_readonly_action_plan
FROM dbo.silver_d8_parallel_candidate_retest_queue;

-- ===========================================================================
-- Item and object evidence rows.
-- ===========================================================================
IF OBJECT_ID('tempdb..#item_evidence_pre') IS NOT NULL DROP TABLE #item_evidence_pre;
SELECT
    d8_id, 'A' AS side, candidate_a AS item_qualified_name, item_type_a AS item_type, a_key AS item_key,
    a_object_row_count AS object_row_count, a_linked_d1_ids AS linked_d1_ids, a_linked_d3_ids AS linked_d3_item_review_ids,
    a_linked_d4_ids AS linked_d4_source_ids, a_linked_d5_ids AS linked_d5_conflict_ids
INTO #item_evidence_pre
FROM #pairs_priced
UNION ALL
SELECT
    d8_id, 'B', candidate_b, item_type_b, b_key,
    b_object_row_count, b_linked_d1_ids, b_linked_d3_ids, b_linked_d4_ids, b_linked_d5_ids
FROM #pairs_priced;

SELECT
    ep.d8_id, ep.side, ep.item_qualified_name, ep.item_type, ep.object_row_count,
    ISNULL(s.read_count,0) AS read_count, ISNULL(s.write_count,0) AS write_count, ISNULL(s.execute_count,0) AS execute_count,
    ISNULL(s.unknown_operation_count,0) AS unknown_operation_count, ISNULL(s.lineage_blocker_count,0) AS lineage_blocker_count,
    ISNULL(s.object_type_blocker_count,0) AS object_type_blocker_count, ISNULL(s.missing_operation_count,0) AS missing_operation_count,
    ep.linked_d1_ids, ep.linked_d3_item_review_ids, ep.linked_d4_source_ids, ep.linked_d5_conflict_ids,
    ISNULL(s.object_key_sample,'') AS object_key_sample
INTO dbo.silver_d8_candidate_item_evidence
FROM #item_evidence_pre ep
LEFT JOIN #item_stats s ON s.item_key = ep.item_key;

SELECT
    ep.d8_id, ep.side, ep.item_qualified_name, rw.object_key, rw.object_display_name, rw.operation_type, rw.usage_type,
    rw.source_type, rw.object_type, rw.object_type_status, rw.lineage_confidence, rw.hardening_status, rw.hardening_issue_types,
    rw.orchestration_parallel_readiness, rw.scheduling_readiness,
    ISNULL(od4.linked_d4_source_ids,'') AS linked_d4_source_ids, ISNULL(od5.linked_d5_conflict_ids,'') AS linked_d5_conflict_ids,
    LEFT(LTRIM(RTRIM(rw.evidence)), 900) AS evidence
INTO dbo.silver_d8_candidate_object_evidence
FROM #item_evidence_pre ep
INNER JOIN #rw rw ON rw.item_key = ep.item_key
LEFT JOIN #object_d4_agg od4 ON od4.rw_object_key = rw.object_key_norm
LEFT JOIN #object_d5_agg od5 ON od5.rw_object_key = rw.object_key_norm;

-- ===========================================================================
-- Summary.
-- ===========================================================================
SELECT summary_scope, group_key, row_count, notes
INTO dbo.silver_d8_parallel_candidate_retest_summary
FROM (
    SELECT 'total' AS summary_scope, 'D8 retest rows' AS group_key, COUNT(*) AS row_count, 'One row per parallel candidate pair.' AS notes FROM dbo.silver_d8_parallel_candidate_retest_queue
    UNION ALL
    SELECT 'total', 'Candidate item evidence rows', COUNT(*), 'Two item-side rows per D8 pair.' FROM dbo.silver_d8_candidate_item_evidence
    UNION ALL
    SELECT 'total', 'Candidate object evidence rows', COUNT(*), 'Object-level evidence rows linked to D8 candidate items.' FROM dbo.silver_d8_candidate_object_evidence
    UNION ALL
    SELECT 'total', 'Missing object evidence targets', COUNT(*), 'Pairs blocked by missing D1 object evidence.' FROM dbo.silver_d8_missing_object_evidence_targets
    UNION ALL
    SELECT 'total', 'Read/write validation targets', COUNT(*), 'Pairs blocked by D3/D4/D5 read/write validation.' FROM dbo.silver_d8_read_write_validation_targets
    UNION ALL
    SELECT 'total', 'Non-production parallel test candidates', COUNT(*), 'Pairs currently ready for owner-approved non-production retest.' FROM dbo.silver_d8_nonprod_parallel_test_candidates
    UNION ALL
    SELECT 'total', 'D8 decision rows', COUNT(*), 'One decision row per D8 pair.' FROM dbo.silver_d8_parallel_retest_decision_template
    UNION ALL
    SELECT 'total', 'External read-only action rows', COUNT(*), 'One read-only/manual action per D8 pair.' FROM dbo.silver_d8_external_readonly_action_plan
    UNION ALL
    SELECT 'closure_opportunity', closure_opportunity, COUNT(*), 'D8 pairs grouped by closure path.' FROM dbo.silver_d8_parallel_candidate_retest_queue GROUP BY closure_opportunity
    UNION ALL
    SELECT 'candidate_status', candidate_status, COUNT(*), 'D8 pairs grouped by current v2 parallel status.' FROM dbo.silver_d8_parallel_candidate_retest_queue GROUP BY candidate_status
    UNION ALL
    SELECT TOP 20 'workspace', workspace_name, COUNT(*), 'Top workspaces by D8 candidate count.'
    FROM dbo.silver_d8_parallel_candidate_retest_queue GROUP BY workspace_name ORDER BY COUNT(*) DESC, LOWER(workspace_name)
) s;

END
