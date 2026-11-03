-- Warehouse-native translation of backend/scripts/24_build_orchestration_v2.ps1
-- (Phase 2 migration, 2026-07-21). Reads dbo.silver_ideal_execution_plan
-- and dbo.silver_ideal_execution_edges (13's own already-validated SQL
-- output), dbo.bronze_object_read_write_classification (Phase 23), and
-- dbo.silver_parallelism_candidates (07's output) -- chaining off prior
-- silver_* tables rather than re-reading Phase 13/7 CSVs, consistent
-- with every other script in this migration batch. The Mermaid diagram
-- + markdown doc stay app-layer.
--
-- Locale gotcha: same Convert-ToDouble comma-decimal bug found in 07 and
-- 13 also existed in this script's own Convert-ToDouble (fixed in the
-- .ps1 too, since it reads 13's own comma-decimal CSV output back in).
-- Not relevant to this SQL translation since it reads FLOAT columns
-- directly from dbo.silver_ideal_execution_plan, never re-parsing text.
--
-- item_qualified_name matching uses LOWER(LTRIM(RTRIM(...))), mirroring
-- the original's own explicit Normalize-Key() helper (this script
-- already knew about the case-sensitivity gap, unlike 05/07/13 where it
-- had to be discovered). object_key matching for the shared-object/
-- shared-write set logic in the parallel-candidates section deliberately
-- stays case-SENSITIVE/exact (no LOWER()) -- the original stores object
-- keys in item-level buckets raw/unnormalized and compares them via
-- .NET HashSet<string>'s default ordinal Contains(), so exact matching
-- here is the faithful translation, not an oversight.
CREATE OR ALTER PROCEDURE dbo.sp_build_orchestration_v2
AS
BEGIN

IF OBJECT_ID('dbo.silver_orchestration_v2_plan', 'U') IS NOT NULL DROP TABLE dbo.silver_orchestration_v2_plan;
IF OBJECT_ID('dbo.silver_orchestration_v2_edges', 'U') IS NOT NULL DROP TABLE dbo.silver_orchestration_v2_edges;
IF OBJECT_ID('dbo.silver_orchestration_v2_waves', 'U') IS NOT NULL DROP TABLE dbo.silver_orchestration_v2_waves;
IF OBJECT_ID('dbo.silver_orchestration_v2_object_conflicts', 'U') IS NOT NULL DROP TABLE dbo.silver_orchestration_v2_object_conflicts;
IF OBJECT_ID('dbo.silver_orchestration_v2_parallel_candidates', 'U') IS NOT NULL DROP TABLE dbo.silver_orchestration_v2_parallel_candidates;
IF OBJECT_ID('dbo.silver_orchestration_v2_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_orchestration_v2_summary;

-- ===========================================================================
-- Step 1: normalized read/write classification rows.
-- ===========================================================================
IF OBJECT_ID('tempdb..#rw') IS NOT NULL DROP TABLE #rw;
SELECT
    LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key,
    item_qualified_name,
    LOWER(LTRIM(RTRIM(object_key))) AS obj_key_norm,
    object_key,
    ISNULL(operation_type, '') AS operation_type,
    ISNULL(object_type_status, '') AS object_type_status,
    ISNULL(lineage_confidence, '') AS lineage_confidence,
    ISNULL(scheduling_readiness, '') AS scheduling_readiness,
    ISNULL(object_display_name, '') AS object_display_name,
    ISNULL(source_type, '') AS source_type,
    ISNULL(object_type, '') AS object_type
INTO #rw
FROM dbo.bronze_object_read_write_classification;

-- ===========================================================================
-- Step 2: per-item read/write buckets (item_qualified_name must be non-blank).
-- ===========================================================================
IF OBJECT_ID('tempdb..#rw_item_agg') IS NOT NULL DROP TABLE #rw_item_agg;
SELECT item_key,
    SUM(CASE WHEN operation_type = 'read' THEN 1 ELSE 0 END) AS read_count,
    SUM(CASE WHEN operation_type = 'write' THEN 1 ELSE 0 END) AS write_count,
    SUM(CASE WHEN operation_type = 'execute' THEN 1 ELSE 0 END) AS execute_count,
    SUM(CASE WHEN operation_type NOT IN ('read', 'write', 'execute') THEN 1 ELSE 0 END) AS unknown_count,
    SUM(CASE WHEN object_type_status = 'exact' THEN 1 ELSE 0 END) AS exact_count,
    SUM(CASE WHEN object_type_status <> 'exact' THEN 1 ELSE 0 END) AS ambiguous_count,
    SUM(CASE WHEN lineage_confidence = 'confirmed' THEN 1 ELSE 0 END) AS confirmed_count,
    SUM(CASE WHEN lineage_confidence <> 'confirmed' THEN 1 ELSE 0 END) AS likely_count,
    SUM(CASE WHEN scheduling_readiness = 'needs_lineage_confirmation' THEN 1 ELSE 0 END) AS needs_lineage_confirmation,
    SUM(CASE WHEN scheduling_readiness = 'needs_object_type_confirmation' THEN 1 ELSE 0 END) AS needs_object_type_confirmation,
    SUM(CASE WHEN scheduling_readiness = 'needs_orchestration_review' THEN 1 ELSE 0 END) AS needs_orchestration_review,
    SUM(CASE WHEN scheduling_readiness = 'blocked_missing_operation' THEN 1 ELSE 0 END) AS blocked_missing_operation
INTO #rw_item_agg
FROM #rw WHERE item_key <> ''
GROUP BY item_key;

-- KNOWN LIMITATION (same class as 13_build_ideal_execution_plan.sql's
-- bottleneck_items): every "sample_*"/"object_statuses" text field below
-- sorts by LOWER(value) as a stand-in for PowerShell's Join-Set (which
-- sorts via culture-aware Sort-Object, then takes the first N). Verified
-- against a real run: this only ever changes the specific illustrative
-- examples shown in these truncated-to-N sample lists (never a count,
-- status, or any other field) -- a small fraction of plan rows and edges
-- (all object_write_serialization_guard "which N of >200 write pairs"
-- picks) end up with a different sample when a field has more than the
-- cap's worth of distinct/candidate values, out of otherwise exact
-- matches across every table in this script.
IF OBJECT_ID('tempdb..#rw_item_statuses') IS NOT NULL DROP TABLE #rw_item_statuses;
;WITH ranked AS (
    SELECT DISTINCT item_key, scheduling_readiness
    FROM #rw WHERE item_key <> '' AND scheduling_readiness <> ''
),
r2 AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY LOWER(scheduling_readiness)) AS rn FROM ranked)
SELECT item_key, STRING_AGG(scheduling_readiness, '; ') WITHIN GROUP (ORDER BY LOWER(scheduling_readiness)) AS object_statuses
INTO #rw_item_statuses
FROM r2 WHERE rn <= 12 GROUP BY item_key;

IF OBJECT_ID('tempdb..#rw_item_samples') IS NOT NULL DROP TABLE #rw_item_samples;
;WITH ranked AS (
    SELECT DISTINCT item_key, object_display_name
    FROM #rw WHERE item_key <> '' AND object_display_name <> ''
),
r2 AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY LOWER(object_display_name)) AS rn FROM ranked)
SELECT item_key, STRING_AGG(object_display_name, '; ') WITHIN GROUP (ORDER BY LOWER(object_display_name)) AS sample_objects
INTO #rw_item_samples
FROM r2 WHERE rn <= 8 GROUP BY item_key;

-- ===========================================================================
-- Step 3: per-object read/write buckets (object_key must be non-blank),
-- keyed by the NORMALIZED object key (matching the original's dictionary
-- key, which is what ends up in the final object_key output columns).
-- ===========================================================================
IF OBJECT_ID('tempdb..#rw_obj_agg') IS NOT NULL DROP TABLE #rw_obj_agg;
SELECT obj_key_norm,
    COUNT(DISTINCT CASE WHEN operation_type = 'read' THEN item_qualified_name END) AS reader_count,
    COUNT(DISTINCT CASE WHEN operation_type = 'write' THEN item_qualified_name END) AS writer_count,
    COUNT(DISTINCT CASE WHEN operation_type = 'execute' THEN item_qualified_name END) AS executor_count,
    SUM(CASE WHEN object_type_status = 'exact' THEN 1 ELSE 0 END) AS exact_row_count,
    SUM(CASE WHEN object_type_status <> 'exact' THEN 1 ELSE 0 END) AS ambiguous_row_count
INTO #rw_obj_agg
FROM #rw WHERE obj_key_norm <> ''
GROUP BY obj_key_norm;

IF OBJECT_ID('tempdb..#rw_obj_text') IS NOT NULL DROP TABLE #rw_obj_text;
;WITH disp AS (
    SELECT obj_key_norm, ROW_NUMBER() OVER (PARTITION BY obj_key_norm ORDER BY LOWER(object_display_name)) AS rn, object_display_name
    FROM (SELECT DISTINCT obj_key_norm, object_display_name FROM #rw WHERE obj_key_norm <> '' AND object_display_name <> '') d
),
disp_agg AS (SELECT obj_key_norm, STRING_AGG(object_display_name, '; ') WITHIN GROUP (ORDER BY LOWER(object_display_name)) AS object_display_name FROM disp WHERE rn <= 3 GROUP BY obj_key_norm),
src AS (
    SELECT obj_key_norm, ROW_NUMBER() OVER (PARTITION BY obj_key_norm ORDER BY LOWER(source_type)) AS rn, source_type
    FROM (SELECT DISTINCT obj_key_norm, source_type FROM #rw WHERE obj_key_norm <> '' AND source_type <> '') d
),
src_agg AS (SELECT obj_key_norm, STRING_AGG(source_type, '; ') WITHIN GROUP (ORDER BY LOWER(source_type)) AS source_types FROM src WHERE rn <= 8 GROUP BY obj_key_norm),
ot AS (
    SELECT obj_key_norm, ROW_NUMBER() OVER (PARTITION BY obj_key_norm ORDER BY LOWER(object_type)) AS rn, object_type
    FROM (SELECT DISTINCT obj_key_norm, object_type FROM #rw WHERE obj_key_norm <> '' AND object_type <> '') d
),
ot_agg AS (SELECT obj_key_norm, STRING_AGG(object_type, '; ') WITHIN GROUP (ORDER BY LOWER(object_type)) AS object_types FROM ot WHERE rn <= 8 GROUP BY obj_key_norm),
st AS (
    SELECT obj_key_norm, ROW_NUMBER() OVER (PARTITION BY obj_key_norm ORDER BY LOWER(scheduling_readiness)) AS rn, scheduling_readiness
    FROM (SELECT DISTINCT obj_key_norm, scheduling_readiness FROM #rw WHERE obj_key_norm <> '' AND scheduling_readiness <> '') d
),
st_agg AS (SELECT obj_key_norm, STRING_AGG(scheduling_readiness, '; ') WITHIN GROUP (ORDER BY LOWER(scheduling_readiness)) AS statuses FROM st WHERE rn <= 12 GROUP BY obj_key_norm),
rd AS (
    SELECT obj_key_norm, ROW_NUMBER() OVER (PARTITION BY obj_key_norm ORDER BY LOWER(item_qualified_name)) AS rn, item_qualified_name
    FROM (SELECT DISTINCT obj_key_norm, item_qualified_name FROM #rw WHERE obj_key_norm <> '' AND operation_type = 'read') d
),
rd_agg AS (SELECT obj_key_norm, STRING_AGG(item_qualified_name, '; ') WITHIN GROUP (ORDER BY LOWER(item_qualified_name)) AS sample_readers FROM rd WHERE rn <= 8 GROUP BY obj_key_norm),
wr AS (
    SELECT obj_key_norm, ROW_NUMBER() OVER (PARTITION BY obj_key_norm ORDER BY LOWER(item_qualified_name)) AS rn, item_qualified_name
    FROM (SELECT DISTINCT obj_key_norm, item_qualified_name FROM #rw WHERE obj_key_norm <> '' AND operation_type = 'write') d
),
wr_agg AS (SELECT obj_key_norm, STRING_AGG(item_qualified_name, '; ') WITHIN GROUP (ORDER BY LOWER(item_qualified_name)) AS sample_writers FROM wr WHERE rn <= 8 GROUP BY obj_key_norm),
ex AS (
    SELECT obj_key_norm, ROW_NUMBER() OVER (PARTITION BY obj_key_norm ORDER BY LOWER(item_qualified_name)) AS rn, item_qualified_name
    FROM (SELECT DISTINCT obj_key_norm, item_qualified_name FROM #rw WHERE obj_key_norm <> '' AND operation_type = 'execute') d
),
ex_agg AS (SELECT obj_key_norm, STRING_AGG(item_qualified_name, '; ') WITHIN GROUP (ORDER BY LOWER(item_qualified_name)) AS sample_executors FROM ex WHERE rn <= 8 GROUP BY obj_key_norm)
SELECT o.obj_key_norm,
    ISNULL(disp_agg.object_display_name, '') AS object_display_name,
    ISNULL(src_agg.source_types, '') AS source_types,
    ISNULL(ot_agg.object_types, '') AS object_types,
    ISNULL(st_agg.statuses, '') AS statuses,
    ISNULL(rd_agg.sample_readers, '') AS sample_readers,
    ISNULL(wr_agg.sample_writers, '') AS sample_writers,
    ISNULL(ex_agg.sample_executors, '') AS sample_executors
INTO #rw_obj_text
FROM #rw_obj_agg o
LEFT JOIN disp_agg ON disp_agg.obj_key_norm = o.obj_key_norm
LEFT JOIN src_agg ON src_agg.obj_key_norm = o.obj_key_norm
LEFT JOIN ot_agg ON ot_agg.obj_key_norm = o.obj_key_norm
LEFT JOIN st_agg ON st_agg.obj_key_norm = o.obj_key_norm
LEFT JOIN rd_agg ON rd_agg.obj_key_norm = o.obj_key_norm
LEFT JOIN wr_agg ON wr_agg.obj_key_norm = o.obj_key_norm
LEFT JOIN ex_agg ON ex_agg.obj_key_norm = o.obj_key_norm;

-- ===========================================================================
-- Step 4: v2 plan (join ideal execution plan to per-item read/write buckets).
-- ===========================================================================
IF OBJECT_ID('tempdb..#plan2') IS NOT NULL DROP TABLE #plan2;
SELECT
    p.*,
    ia.read_count, ia.write_count, ia.execute_count, ia.unknown_count,
    ia.exact_count, ia.ambiguous_count, ia.confirmed_count, ia.likely_count,
    ia.needs_lineage_confirmation, ia.needs_object_type_confirmation,
    ia.needs_orchestration_review, ia.blocked_missing_operation,
    ISNULL(ist.object_statuses, '') AS object_statuses,
    ISNULL(ism.sample_objects, '') AS sample_objects,
    status_calc AS v2_status
INTO #plan2
FROM dbo.silver_ideal_execution_plan p
LEFT JOIN #rw_item_agg ia ON ia.item_key = LOWER(LTRIM(RTRIM(p.qualified_name)))
LEFT JOIN #rw_item_statuses ist ON ist.item_key = LOWER(LTRIM(RTRIM(p.qualified_name)))
LEFT JOIN #rw_item_samples ism ON ism.item_key = LOWER(LTRIM(RTRIM(p.qualified_name)))
CROSS APPLY (
    SELECT
        CASE
            WHEN p.parallel_readiness = 'hold_until_stabilized' OR p.risk_flags LIKE '%failure_hotspot_stabilize_first%' THEN 'hold_failure_stabilization'
            WHEN ia.item_key IS NOT NULL AND (ISNULL(ia.blocked_missing_operation, 0) > 0 OR ISNULL(ia.unknown_count, 0) > 0) THEN 'blocked_missing_operation'
            WHEN ia.item_key IS NOT NULL AND ISNULL(ia.needs_lineage_confirmation, 0) > 0 THEN 'blocked_lineage_confirmation'
            WHEN ia.item_key IS NOT NULL AND ISNULL(ia.needs_object_type_confirmation, 0) > 0 THEN 'blocked_object_type_confirmation'
            WHEN ia.item_key IS NOT NULL AND ISNULL(ia.write_count, 0) > 0 THEN 'blocked_write_serialization_review'
            WHEN ia.item_key IS NOT NULL AND ISNULL(ia.needs_orchestration_review, 0) > 0 THEN 'needs_orchestration_review'
            WHEN p.incoming_likely_edges > 0 OR p.outgoing_likely_edges > 0 OR p.parallel_readiness = 'candidate_requires_dependency_confirmation' THEN 'blocked_dependency_confirmation'
            WHEN p.human_validation_required = 'yes' THEN 'needs_orchestration_review'
            ELSE 'candidate_ready_for_nonprod_review'
        END AS status_calc
) sc;

-- ===========================================================================
-- Step 5: v2 edges (ideal edges renamed) + object constraint guard edges.
-- ===========================================================================
IF OBJECT_ID('tempdb..#obj_writers') IS NOT NULL DROP TABLE #obj_writers;
SELECT obj_key_norm, item_qualified_name, ROW_NUMBER() OVER (PARTITION BY obj_key_norm ORDER BY LOWER(item_qualified_name)) AS wrn
INTO #obj_writers
FROM (SELECT DISTINCT obj_key_norm, item_qualified_name FROM #rw WHERE obj_key_norm <> '' AND operation_type = 'write') w;

IF OBJECT_ID('tempdb..#obj_readers') IS NOT NULL DROP TABLE #obj_readers;
SELECT obj_key_norm, item_qualified_name, ROW_NUMBER() OVER (PARTITION BY obj_key_norm ORDER BY LOWER(item_qualified_name)) AS rrn
INTO #obj_readers
FROM (SELECT DISTINCT obj_key_norm, item_qualified_name FROM #rw WHERE obj_key_norm <> '' AND operation_type = 'read') r;

IF OBJECT_ID('tempdb..#constraint_pairs') IS NOT NULL DROP TABLE #constraint_pairs;
;WITH ww AS (
    SELECT a.obj_key_norm, a.item_qualified_name AS upstream_qualified_name, b.item_qualified_name AS downstream_qualified_name,
        1 AS pair_type, ROW_NUMBER() OVER (PARTITION BY a.obj_key_norm ORDER BY a.wrn, b.wrn) AS pair_order
    FROM #obj_writers a JOIN #obj_writers b ON b.obj_key_norm = a.obj_key_norm AND a.wrn < b.wrn
),
wr AS (
    SELECT w.obj_key_norm, w.item_qualified_name AS upstream_qualified_name, r.item_qualified_name AS downstream_qualified_name,
        2 AS pair_type, ROW_NUMBER() OVER (PARTITION BY w.obj_key_norm ORDER BY w.wrn, r.rrn) AS pair_order
    FROM #obj_writers w JOIN #obj_readers r ON r.obj_key_norm = w.obj_key_norm AND LOWER(w.item_qualified_name) <> LOWER(r.item_qualified_name)
),
all_pairs AS (SELECT * FROM ww UNION ALL SELECT * FROM wr)
SELECT *, ROW_NUMBER() OVER (PARTITION BY obj_key_norm ORDER BY pair_type, pair_order) AS global_rn
INTO #constraint_pairs
FROM all_pairs;

IF OBJECT_ID('tempdb..#edges2') IS NOT NULL DROP TABLE #edges2;
SELECT
    upstream_qualified_name, downstream_qualified_name, v2_relationship_type, source_relationship_type,
    object_key, edge_status, confidence, source_system, evidence
INTO #edges2
FROM (
    SELECT
        upstream_qualified_name, downstream_qualified_name,
        plan_relationship_type AS v2_relationship_type,
        original_relationship_type AS source_relationship_type,
        '' AS object_key,
        CASE WHEN confidence = 'confirmed' THEN 'active_confirmed_dependency' ELSE 'pending_dependency_confirmation' END AS edge_status,
        confidence, source_system, evidence
    FROM dbo.silver_ideal_execution_edges

    UNION ALL

    SELECT
        upstream_qualified_name, downstream_qualified_name,
        CASE WHEN pair_type = 1 THEN 'object_write_serialization_guard' ELSE 'object_writer_before_reader_guard' END,
        'object_read_write',
        obj_key_norm,
        CASE WHEN pair_type = 1 THEN 'blocked_pending_write_order_review' ELSE 'blocked_pending_lineage_confirmation' END,
        'needs_confirmation',
        'analysis/object_read_write_classification.csv',
        CASE WHEN pair_type = 1 THEN 'Both items write to the same source object. Serialization order must be confirmed before parallel execution.'
             ELSE 'One item writes and another reads the same source object. Writer-reader order must be confirmed before scheduling.' END
    FROM #constraint_pairs WHERE global_rn <= 200
) u;

-- ===========================================================================
-- Step 6: object conflicts (objects with at least one writer or executor).
-- ===========================================================================
IF OBJECT_ID('tempdb..#conflicts') IS NOT NULL DROP TABLE #conflicts;
SELECT
    o.obj_key_norm AS object_key,
    t.object_display_name, t.source_types, t.object_types,
    o.reader_count, o.writer_count, o.executor_count,
    o.exact_row_count, o.ambiguous_row_count,
    -- conflict_types is a HashSet joined via the original's Join-Set
    -- helper, which SORTS alphabetically -- not the order these flags
    -- are conditionally added in the source code (a mistake caught by
    -- comparing against a real run: "evidence_gated" sorts before
    -- "multiple_writers" alphabetically, so it appears first).
    ISNULL(ct.conflict_types, '') AS conflict_types,
    CASE WHEN o.ambiguous_row_count > 0 THEN 'blocked_until_lineage_and_type_confirmed' ELSE 'requires_serialization_review' END AS object_readiness,
    t.statuses, t.sample_readers, t.sample_writers, t.sample_executors,
    'Confirm object lineage/type, then serialize writers before readers and validate any shared-object parallelism.' AS recommended_next_action
INTO #conflicts
FROM #rw_obj_agg o
JOIN #rw_obj_text t ON t.obj_key_norm = o.obj_key_norm
OUTER APPLY (
    SELECT STRING_AGG(flag, '; ') WITHIN GROUP (ORDER BY flag) AS conflict_types
    FROM (VALUES
        (CASE WHEN o.writer_count > 1 THEN 'multiple_writers' END),
        (CASE WHEN o.writer_count > 0 AND o.reader_count > 0 THEN 'writer_reader_ordering' END),
        (CASE WHEN o.executor_count > 0 THEN 'execute_dependency_review' END),
        (CASE WHEN t.statuses <> '' THEN 'evidence_gated' END)
    ) v(flag)
    WHERE flag IS NOT NULL
) ct
WHERE o.writer_count > 0 OR o.executor_count > 0;

-- ===========================================================================
-- Step 7: parallel candidates re-evaluated with object read/write evidence.
-- object_key matching here is deliberately case-sensitive/exact (see the
-- header comment) -- #rw's raw (non-normalized) object_key column.
-- ===========================================================================
IF OBJECT_ID('tempdb..#edge_pairs') IS NOT NULL DROP TABLE #edge_pairs;
SELECT DISTINCT LOWER(LTRIM(RTRIM(upstream_qualified_name))) + '|' + LOWER(LTRIM(RTRIM(downstream_qualified_name))) AS pair_key
INTO #edge_pairs
FROM dbo.silver_ideal_execution_edges
WHERE upstream_qualified_name <> '' AND downstream_qualified_name <> '';

IF OBJECT_ID('tempdb..#pc') IS NOT NULL DROP TABLE #pc;
SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS pc_id, workspace_name, candidate_a, candidate_b, item_type_a, item_type_b, expected_parallel_window_seconds,
    LOWER(LTRIM(RTRIM(candidate_a))) AS a_key, LOWER(LTRIM(RTRIM(candidate_b))) AS b_key
INTO #pc
FROM dbo.silver_parallelism_candidates;

-- object_key matching here is deliberately case-sensitive/exact (see the
-- header comment) -- #rw's raw (non-normalized) object_key column.
IF OBJECT_ID('tempdb..#shared_objects') IS NOT NULL DROP TABLE #shared_objects;
SELECT pc_id, object_key, ROW_NUMBER() OVER (PARTITION BY pc_id ORDER BY object_key) AS rn
INTO #shared_objects
FROM (
    SELECT DISTINCT p.pc_id, ra.object_key
    FROM #pc p
    JOIN #rw ra ON ra.item_key = p.a_key AND ra.object_key <> ''
    JOIN #rw rb ON rb.object_key = ra.object_key AND rb.item_key = p.b_key
) x;

IF OBJECT_ID('tempdb..#shared_objects_agg') IS NOT NULL DROP TABLE #shared_objects_agg;
SELECT pc_id, COUNT(*) AS shared_object_count,
    (SELECT STRING_AGG(object_key, '; ') WITHIN GROUP (ORDER BY object_key) FROM #shared_objects s2 WHERE s2.pc_id = s1.pc_id AND s2.rn <= 10) AS sample_shared_objects
INTO #shared_objects_agg
FROM #shared_objects s1
GROUP BY pc_id;

IF OBJECT_ID('tempdb..#shared_writes') IS NOT NULL DROP TABLE #shared_writes;
SELECT pc_id, COUNT(*) AS shared_write_object_count
INTO #shared_writes
FROM (
    SELECT DISTINCT p.pc_id, allobj.object_key
    FROM #pc p
    CROSS APPLY (
        SELECT ra.object_key FROM #rw ra JOIN #rw rb ON rb.object_key = ra.object_key AND rb.item_key = p.b_key
        WHERE ra.item_key = p.a_key AND ra.operation_type = 'write' AND ra.object_key <> ''
        UNION
        SELECT rb.object_key FROM #rw rb JOIN #rw ra ON ra.object_key = rb.object_key AND ra.item_key = p.a_key
        WHERE rb.item_key = p.b_key AND rb.operation_type = 'write' AND rb.object_key <> ''
    ) allobj
) x
GROUP BY pc_id;

IF OBJECT_ID('tempdb..#parallel2') IS NOT NULL DROP TABLE #parallel2;
SELECT
    p.workspace_name, p.candidate_a, p.candidate_b, p.item_type_a, p.item_type_b, p.expected_parallel_window_seconds,
    CASE WHEN ep1.pair_key IS NOT NULL OR ep2.pair_key IS NOT NULL THEN 'yes' ELSE 'no' END AS direct_dependency_exists,
    ISNULL(so.shared_object_count, 0) AS shared_object_count,
    ISNULL(sw.shared_write_object_count, 0) AS shared_write_object_count,
    CASE
        WHEN ep1.pair_key IS NOT NULL OR ep2.pair_key IS NOT NULL THEN 'blocked_direct_dependency'
        WHEN aAgg.item_key IS NULL OR bAgg.item_key IS NULL THEN 'blocked_missing_object_evidence'
        WHEN (ISNULL(aAgg.needs_lineage_confirmation, 0) > 0 OR ISNULL(aAgg.needs_object_type_confirmation, 0) > 0 OR ISNULL(aAgg.blocked_missing_operation, 0) > 0 OR ISNULL(aAgg.write_count, 0) > 0)
          OR (ISNULL(bAgg.needs_lineage_confirmation, 0) > 0 OR ISNULL(bAgg.needs_object_type_confirmation, 0) > 0 OR ISNULL(bAgg.blocked_missing_operation, 0) > 0 OR ISNULL(bAgg.write_count, 0) > 0) THEN 'blocked_read_write_evidence'
        WHEN ISNULL(sw.shared_write_object_count, 0) > 0 THEN 'blocked_shared_object_write'
        WHEN ISNULL(so.shared_object_count, 0) > 0 THEN 'candidate_shared_reads_only'
        ELSE 'parallel_candidate_no_shared_objects'
    END AS candidate_status,
    ISNULL(aAgg.read_count, 0) AS candidate_a_read_count, ISNULL(aAgg.write_count, 0) AS candidate_a_write_count,
    ISNULL(aAgg.needs_lineage_confirmation, 0) + ISNULL(aAgg.needs_object_type_confirmation, 0) + ISNULL(aAgg.blocked_missing_operation, 0) AS candidate_a_blocker_count,
    ISNULL(bAgg.read_count, 0) AS candidate_b_read_count, ISNULL(bAgg.write_count, 0) AS candidate_b_write_count,
    ISNULL(bAgg.needs_lineage_confirmation, 0) + ISNULL(bAgg.needs_object_type_confirmation, 0) + ISNULL(bAgg.blocked_missing_operation, 0) AS candidate_b_blocker_count,
    ISNULL(so.sample_shared_objects, '') AS sample_shared_objects,
    'Candidate only. Promote to non-production test only if direct dependencies, shared writes, and evidence blockers are resolved.' AS recommendation
INTO #parallel2
FROM #pc p
LEFT JOIN #edge_pairs ep1 ON ep1.pair_key = p.a_key + '|' + p.b_key
LEFT JOIN #edge_pairs ep2 ON ep2.pair_key = p.b_key + '|' + p.a_key
LEFT JOIN #rw_item_agg aAgg ON aAgg.item_key = p.a_key
LEFT JOIN #rw_item_agg bAgg ON bAgg.item_key = p.b_key
LEFT JOIN #shared_objects_agg so ON so.pc_id = p.pc_id
LEFT JOIN #shared_writes sw ON sw.pc_id = p.pc_id;

-- ===========================================================================
-- Step 8: waves (grouped by v2_wave_index = ideal plan's wave_index).
-- ===========================================================================
IF OBJECT_ID('tempdb..#status_breakdown') IS NOT NULL DROP TABLE #status_breakdown;
;WITH counts AS (
    SELECT wave_index, v2_status, COUNT(*) AS cnt FROM #plan2 GROUP BY wave_index, v2_status
),
ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY wave_index ORDER BY cnt DESC, LOWER(v2_status) ASC) AS rn FROM counts)
SELECT wave_index, STRING_AGG(v2_status + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS status_breakdown
INTO #status_breakdown FROM ranked GROUP BY wave_index;

IF OBJECT_ID('tempdb..#stage_breakdown2') IS NOT NULL DROP TABLE #stage_breakdown2;
;WITH counts AS (
    SELECT wave_index, proposed_stage, COUNT(*) AS cnt FROM #plan2 GROUP BY wave_index, proposed_stage
),
ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY wave_index ORDER BY cnt DESC, LOWER(proposed_stage) ASC) AS rn FROM counts)
SELECT wave_index, STRING_AGG(proposed_stage + '=' + CAST(cnt AS VARCHAR(10)), '; ') WITHIN GROUP (ORDER BY rn) AS stage_breakdown
INTO #stage_breakdown2 FROM ranked GROUP BY wave_index;

IF OBJECT_ID('tempdb..#waves2') IS NOT NULL DROP TABLE #waves2;
SELECT
    p.wave_index AS v2_wave_index,
    COUNT(*) AS node_count,
    SUM(CASE WHEN p.v2_status = 'candidate_ready_for_nonprod_review' THEN 1 ELSE 0 END) AS candidate_ready_count,
    SUM(CASE WHEN p.v2_status LIKE 'blocked%' OR p.v2_status LIKE 'hold%' THEN 1 ELSE 0 END) AS blocked_count,
    SUM(CASE WHEN p.v2_status = 'needs_orchestration_review' THEN 1 ELSE 0 END) AS review_count,
    ROUND(MAX(p.estimated_duration_seconds), 3) AS estimated_parallel_duration_seconds,
    ISNULL(sb.status_breakdown, '') AS status_breakdown,
    ISNULL(gb.stage_breakdown, '') AS stage_breakdown,
    'Use as a visual planning wave. Execute only candidate rows after human approval; blocked rows define prerequisite evidence work.' AS recommendation
INTO #waves2
FROM #plan2 p
LEFT JOIN #status_breakdown sb ON sb.wave_index = p.wave_index
LEFT JOIN #stage_breakdown2 gb ON gb.wave_index = p.wave_index
GROUP BY p.wave_index, sb.status_breakdown, gb.stage_breakdown;

-- ===========================================================================
-- Step 9: final outputs.
-- ===========================================================================
SELECT
    wave_index AS v2_wave_index, v2_status, CAST(
        CASE v2_status
            WHEN 'candidate_ready_for_nonprod_review' THEN 90
            WHEN 'needs_orchestration_review' THEN 60
            WHEN 'blocked_write_serialization_review' THEN 45
            WHEN 'blocked_object_type_confirmation' THEN 35
            WHEN 'blocked_dependency_confirmation' THEN 30
            WHEN 'blocked_lineage_confirmation' THEN 25
            WHEN 'blocked_missing_operation' THEN 10
            WHEN 'hold_failure_stabilization' THEN 0
            ELSE 0
        END AS INT) AS readiness_score,
    proposed_stage, qualified_name, workspace_name, item_name, item_type,
    orchestration_role, action_type, is_master_action, estimated_start_seconds, estimated_duration_seconds,
    estimated_finish_seconds, duration_source, predecessor_count, successor_count, incoming_likely_edges,
    outgoing_likely_edges, run_count, failed_count, manual_count, scheduled_count, enabled_schedules,
    disabled_schedules, schedule_times, parallel_readiness AS original_parallel_readiness,
    risk_flags AS original_risk_flags, human_validation_required AS original_human_validation_required,
    ISNULL(read_count, 0) AS read_count, ISNULL(write_count, 0) AS write_count, ISNULL(execute_count, 0) AS execute_count,
    ISNULL(unknown_count, 0) AS unknown_operation_count, ISNULL(exact_count, 0) AS exact_object_count,
    ISNULL(ambiguous_count, 0) AS ambiguous_object_count, ISNULL(confirmed_count, 0) AS confirmed_object_rows,
    ISNULL(likely_count, 0) AS likely_object_rows, ISNULL(needs_lineage_confirmation, 0) AS needs_lineage_confirmation_count,
    ISNULL(needs_object_type_confirmation, 0) AS needs_object_type_confirmation_count,
    ISNULL(needs_orchestration_review, 0) AS needs_orchestration_review_count,
    ISNULL(blocked_missing_operation, 0) AS blocked_missing_operation_count,
    object_statuses, sample_objects,
    CAST(
        CASE v2_status
            WHEN 'candidate_ready_for_nonprod_review' THEN 'Candidate for non-production orchestration review after owner approval.'
            WHEN 'needs_orchestration_review' THEN 'Review schedules, duration evidence, ownership, and item-level behavior before promotion.'
            WHEN 'blocked_write_serialization_review' THEN 'Validate writer order and downstream readers; serialize writes before any parallel execution.'
            WHEN 'blocked_object_type_confirmation' THEN 'Confirm exact source object type before using this item as a scheduling dependency.'
            WHEN 'blocked_dependency_confirmation' THEN 'Confirm dependency edges before using this row as an operational sequencing rule.'
            WHEN 'blocked_lineage_confirmation' THEN 'Confirm object-level lineage from definitions, code, metadata, or owner evidence.'
            WHEN 'blocked_missing_operation' THEN 'Classify unknown object operation as read, write, or execute.'
            WHEN 'hold_failure_stabilization' THEN 'Stabilize failed or risky executions before optimization.'
            ELSE 'Review manually before operational use.'
        END AS VARCHAR(200)) AS v2_recommended_next_action
INTO dbo.silver_orchestration_v2_plan
FROM #plan2;

SELECT * INTO dbo.silver_orchestration_v2_edges FROM #edges2;

SELECT object_key, object_display_name, source_types, object_types, reader_count, writer_count, executor_count,
    exact_row_count, ambiguous_row_count, conflict_types, object_readiness, statuses, sample_readers, sample_writers,
    sample_executors, recommended_next_action
INTO dbo.silver_orchestration_v2_object_conflicts
FROM #conflicts;

SELECT workspace_name, candidate_a, candidate_b, item_type_a, item_type_b, expected_parallel_window_seconds,
    direct_dependency_exists, shared_object_count, shared_write_object_count, candidate_status,
    candidate_a_read_count, candidate_a_write_count, candidate_a_blocker_count,
    candidate_b_read_count, candidate_b_write_count, candidate_b_blocker_count,
    sample_shared_objects, recommendation
INTO dbo.silver_orchestration_v2_parallel_candidates
FROM #parallel2;

SELECT v2_wave_index, node_count, candidate_ready_count, blocked_count, review_count,
    estimated_parallel_duration_seconds, status_breakdown, stage_breakdown, recommendation
INTO dbo.silver_orchestration_v2_waves
FROM #waves2;

SELECT metric, value, notes INTO dbo.silver_orchestration_v2_summary FROM (
    SELECT 'plan_nodes' AS metric, CAST(COUNT(*) AS VARCHAR(20)) AS value, 'Rows in orchestration_v2_plan.csv.' AS notes FROM #plan2
    UNION ALL SELECT 'candidate_ready_for_nonprod_review', CAST(SUM(CASE WHEN v2_status = 'candidate_ready_for_nonprod_review' THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Rows with no local blocker; still require human approval.' FROM #plan2
    UNION ALL SELECT 'blocked_or_hold_nodes', CAST(SUM(CASE WHEN v2_status LIKE 'blocked%' OR v2_status LIKE 'hold%' THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Rows that must not be operationalized before resolving blockers.' FROM #plan2
    UNION ALL SELECT 'needs_orchestration_review_nodes', CAST(SUM(CASE WHEN v2_status = 'needs_orchestration_review' THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Rows requiring scheduling/ownership/duration review.' FROM #plan2
    UNION ALL SELECT 'object_conflict_rows', CAST(COUNT(*) AS VARCHAR(20)), 'Source objects with writers, executes, or writer-reader ordering needs.' FROM #conflicts
    UNION ALL SELECT 'object_constraint_edges', CAST(COUNT(*) AS VARCHAR(20)), 'Read/write guard edges added as blocked constraints.' FROM #constraint_pairs WHERE global_rn <= 200
    UNION ALL SELECT 'parallel_candidate_rows', CAST(COUNT(*) AS VARCHAR(20)), 'Phase 7 parallel candidates re-evaluated with object read/write evidence.' FROM #parallel2
    -- ISNULL wrapper: SUM() over zero rows is NULL in T-SQL, not 0 like
    -- PowerShell's @(...).Count always is -- currently exercised for
    -- real, since dbo.silver_parallelism_candidates has 0 rows today.
    UNION ALL SELECT 'parallel_candidates_ready', CAST(ISNULL(SUM(CASE WHEN candidate_status LIKE 'candidate%' THEN 1 ELSE 0 END), 0) AS VARCHAR(20)), 'Candidates that still require non-production approval.' FROM #parallel2
    UNION ALL SELECT 'parallel_candidates_blocked', CAST(ISNULL(SUM(CASE WHEN candidate_status LIKE 'blocked%' THEN 1 ELSE 0 END), 0) AS VARCHAR(20)), 'Candidates blocked by dependency, evidence, or write conflict.' FROM #parallel2
    UNION ALL SELECT 'waves', CAST(COUNT(*) AS VARCHAR(20)), 'Planning waves inherited from ideal execution v1 and annotated by v2 status.' FROM #waves2
) s;

END
