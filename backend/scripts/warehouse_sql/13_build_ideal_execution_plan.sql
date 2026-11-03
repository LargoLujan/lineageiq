-- Warehouse-native translation of backend/scripts/13_build_ideal_execution_plan.ps1
-- (Phase 2 migration, 2026-07-21). Reads dbo.bronze_items, dbo.bronze_
-- graph_nodes, dbo.bronze_dependencies, dbo.bronze_execution_duration_
-- by_item, dbo.bronze_executions, dbo.bronze_deep_object_lineage_item_
-- enrichment, plus 07's own already-validated silver_* outputs (critical
-- path/failure/manual/schedule-review/orchestration-group/parallelism)
-- instead of re-reading Phase 7's CSVs, since those are now SQL-native.
-- The Mermaid diagram + markdown doc stay app-layer (not data), same
-- rule as every other migration in this batch.
--
-- No recursive CTEs available, so the 5-stage topological "wave" sort
-- (Kahn's algorithm per stage, longest-path-in-DAG semantics: a node's
-- local level = 1 + MAX(level of its same-stage predecessors)) is done
-- as an explicit WHILE loop per stage, batching all currently-zero-
-- indegree/unleveled nodes each iteration -- this gives the exact same
-- level values as the original's one-node-at-a-time FIFO queue, since
-- the level of a node is a pure function of the DAG structure (order-
-- independent) once every same-stage predecessor has already been
-- leveled. Cross-stage edges do NOT participate in level computation --
-- only same-stage edges do, matching the original's conservative stage
-- barrier (each node's stage is fixed by its own role, not upstream
-- deps). Same-stage cycles are not expected in practice (a fresh run
-- inspected directly had no row carrying
-- "cycle_or_unresolved_same_stage_dependency"), so the cycle-fallback
-- below is implemented stage-locally (cycleLevel = current max level in
-- THIS stage + 1) rather than the original's incidental global-max-
-- across-all-stages-so-far quirk (a side effect of never resetting its
-- $localLevelByName dict between stages) -- that quirk is untestable
-- with zero real rows exercising it and not worth reproducing exactly.
--
-- Locale gotcha: same Convert-ToDouble comma-decimal bug found and
-- fixed in 07_optimize_orchestration.ps1 also existed in this script's
-- own Convert-ToDouble (now fixed in the .ps1 too) -- REPLACE(col, ',',
-- '.') before every TRY_CAST(...AS FLOAT) on avg/max_duration_seconds
-- here for the same reason.
CREATE OR ALTER PROCEDURE dbo.sp_build_ideal_execution_plan
AS
BEGIN

IF OBJECT_ID('dbo.silver_ideal_execution_plan', 'U') IS NOT NULL DROP TABLE dbo.silver_ideal_execution_plan;
IF OBJECT_ID('dbo.silver_ideal_execution_edges', 'U') IS NOT NULL DROP TABLE dbo.silver_ideal_execution_edges;
IF OBJECT_ID('dbo.silver_ideal_execution_waves', 'U') IS NOT NULL DROP TABLE dbo.silver_ideal_execution_waves;
IF OBJECT_ID('dbo.silver_ideal_execution_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_ideal_execution_summary;

-- ===========================================================================
-- Step 1: combined metadata (items primary, graph_nodes fallback for names
-- not present in items), one row per LOWER(qualified_name).
-- ===========================================================================
IF OBJECT_ID('tempdb..#items_meta') IS NOT NULL DROP TABLE #items_meta;
SELECT qn, MAX(qualified_name) AS qualified_name, MAX(workspace_name) AS workspace_name,
    MAX(item_type) AS item_type, MAX(item_name) AS item_name
INTO #items_meta
FROM (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS qn, qualified_name, workspace_name, item_type, item_name
    FROM dbo.bronze_items WHERE qualified_name <> ''
) x
GROUP BY qn;

IF OBJECT_ID('tempdb..#nodes_meta') IS NOT NULL DROP TABLE #nodes_meta;
SELECT qn, MAX(qualified_name) AS qualified_name, MAX(workspace_name) AS workspace_name,
    MAX(item_type) AS item_type, MAX(display_name) AS item_name
INTO #nodes_meta
FROM (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS qn, qualified_name, workspace_name, item_type, display_name
    FROM dbo.bronze_graph_nodes WHERE qualified_name <> ''
) x
GROUP BY qn;

IF OBJECT_ID('tempdb..#metadata') IS NOT NULL DROP TABLE #metadata;
SELECT qn, qualified_name, workspace_name, item_type, item_name
INTO #metadata
FROM (
    SELECT * FROM #items_meta
    UNION ALL
    SELECT n.* FROM #nodes_meta n WHERE NOT EXISTS (SELECT 1 FROM #items_meta i WHERE i.qn = n.qn)
) m;

-- ===========================================================================
-- Step 2: duration rows (first-occurrence-per-name wins, matching the
-- original's ContainsKey guard), deep lineage rows (same first-wins rule),
-- schedule aggregates.
-- ===========================================================================
IF OBJECT_ID('tempdb..#duration') IS NOT NULL DROP TABLE #duration;
SELECT qn, qualified_name, avg_duration_seconds, max_duration_seconds, run_count, completed_count, failed_count, manual_count, scheduled_count
INTO #duration
FROM (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS qn, qualified_name,
        ISNULL(TRY_CAST(REPLACE(avg_duration_seconds, ',', '.') AS FLOAT), 0) AS avg_duration_seconds,
        ISNULL(TRY_CAST(REPLACE(max_duration_seconds, ',', '.') AS FLOAT), 0) AS max_duration_seconds,
        ISNULL(TRY_CAST(run_count AS INT), 0) AS run_count,
        ISNULL(TRY_CAST(completed_count AS INT), 0) AS completed_count,
        ISNULL(TRY_CAST(failed_count AS INT), 0) AS failed_count,
        ISNULL(TRY_CAST(manual_count AS INT), 0) AS manual_count,
        ISNULL(TRY_CAST(scheduled_count AS INT), 0) AS scheduled_count,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_execution_duration_by_item
    WHERE qualified_name <> ''
) d
WHERE rn = 1;

IF OBJECT_ID('tempdb..#deep_lineage') IS NOT NULL DROP TABLE #deep_lineage;
SELECT qn, deep_lineage_status, coverage_status, review_status, object_reference_count,
    exact_object_reference_count, ambiguous_object_reference_count, confirmed_lineage_rows,
    likely_lineage_rows, read_count, write_count, execute_count, unknown_count, next_action
INTO #deep_lineage
FROM (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS qn,
        ISNULL(deep_lineage_status, '') AS deep_lineage_status,
        ISNULL(coverage_status, '') AS coverage_status,
        ISNULL(review_status, '') AS review_status,
        ISNULL(TRY_CAST(object_reference_count AS INT), 0) AS object_reference_count,
        ISNULL(TRY_CAST(exact_object_reference_count AS INT), 0) AS exact_object_reference_count,
        ISNULL(TRY_CAST(ambiguous_object_reference_count AS INT), 0) AS ambiguous_object_reference_count,
        ISNULL(TRY_CAST(confirmed_lineage_rows AS INT), 0) AS confirmed_lineage_rows,
        ISNULL(TRY_CAST(likely_lineage_rows AS INT), 0) AS likely_lineage_rows,
        ISNULL(TRY_CAST(read_count AS INT), 0) AS read_count,
        ISNULL(TRY_CAST(write_count AS INT), 0) AS write_count,
        ISNULL(TRY_CAST(execute_count AS INT), 0) AS execute_count,
        ISNULL(TRY_CAST(unknown_count AS INT), 0) AS unknown_count,
        ISNULL(next_action, '') AS next_action,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(item_qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_deep_object_lineage_item_enrichment
    WHERE item_qualified_name <> ''
) d
WHERE rn = 1;

IF OBJECT_ID('tempdb..#schedule_agg') IS NOT NULL DROP TABLE #schedule_agg;
SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS qn,
    SUM(CASE WHEN schedule_enabled = 'True' THEN 1 ELSE 0 END) AS enabled_schedules,
    SUM(CASE WHEN schedule_enabled <> 'True' THEN 1 ELSE 0 END) AS disabled_schedules
INTO #schedule_agg
FROM dbo.bronze_executions
WHERE record_type = 'schedule' AND qualified_name <> ''
GROUP BY LOWER(LTRIM(RTRIM(qualified_name)));

IF OBJECT_ID('tempdb..#schedule_times') IS NOT NULL DROP TABLE #schedule_times;
;WITH times_distinct AS (
    SELECT DISTINCT LOWER(LTRIM(RTRIM(qualified_name))) AS qn, scheduled_time
    FROM dbo.bronze_executions WHERE record_type = 'schedule' AND scheduled_time <> ''
)
SELECT qn, STRING_AGG(scheduled_time, '; ') WITHIN GROUP (ORDER BY scheduled_time) AS schedule_times
INTO #schedule_times
FROM times_distinct GROUP BY qn;

-- ===========================================================================
-- Step 3: plan edges, redirected/renamed per relationship_type, deduped.
-- Chains off 07's already-validated dbo.silver_* outputs (not Phase 7 CSVs)
-- for critical path / failure / manual / schedule-review / fan-out sets.
-- ===========================================================================
IF OBJECT_ID('tempdb..#plan_edges_raw') IS NOT NULL DROP TABLE #plan_edges_raw;
SELECT upstream_qualified_name, downstream_qualified_name, original_relationship_type,
    plan_relationship_type, confidence, source_system, evidence, notes
INTO #plan_edges_raw
FROM (
    SELECT
        CASE relationship_type
            WHEN 'depends_on' THEN to_qualified_name
            WHEN 'uses_model' THEN to_qualified_name
            WHEN 'serves_report' THEN from_qualified_name
            WHEN 'executes' THEN from_qualified_name
        END AS upstream_qualified_name,
        CASE relationship_type
            WHEN 'depends_on' THEN from_qualified_name
            WHEN 'uses_model' THEN from_qualified_name
            WHEN 'serves_report' THEN to_qualified_name
            WHEN 'executes' THEN to_qualified_name
        END AS downstream_qualified_name,
        relationship_type AS original_relationship_type,
        CASE relationship_type
            WHEN 'depends_on' THEN 'upstream_readiness_before_item'
            WHEN 'uses_model' THEN 'model_before_report_validation'
            WHEN 'serves_report' THEN 'model_before_report_validation'
            WHEN 'executes' THEN 'existing_orchestrator_calls_child'
        END AS plan_relationship_type,
        CASE WHEN confidence = '' THEN 'unknown' ELSE confidence END AS confidence,
        LEFT(ISNULL(source_system, ''), 220) AS source_system,
        LEFT(ISNULL(evidence, ''), 500) AS evidence,
        LEFT(ISNULL(notes, ''), 500) AS notes
    FROM dbo.bronze_dependencies
    WHERE relationship_type IN ('depends_on', 'uses_model', 'serves_report', 'executes')
) e
WHERE upstream_qualified_name <> '' AND downstream_qualified_name <> ''
    AND LOWER(LTRIM(RTRIM(upstream_qualified_name))) <> LOWER(LTRIM(RTRIM(downstream_qualified_name)));

-- 'uses_model' and 'serves_report' both redirect to the same plan_
-- relationship_type ('model_before_report_validation'), so whenever
-- dependencies.csv records BOTH directions for the same model/report
-- pair (the report's own uses_model plus the model's mirrored serves_
-- report row -- common in this dataset), they collide on the same dedup
-- key and only one can survive, exactly like the original's file-order-
-- dependent "first Add-PlanEdge call wins". Bronze tables carry no row-
-- order column to replicate that exactly, but direct inspection of
-- index/dependencies.csv shows uses_model precedes its matching serves_
-- report row in the vast majority of cases -- so that's used as the tie-break
-- here instead of an arbitrary one.
IF OBJECT_ID('tempdb..#plan_edges') IS NOT NULL DROP TABLE #plan_edges;
SELECT
    LOWER(LTRIM(RTRIM(upstream_qualified_name))) AS upstream_qn,
    LOWER(LTRIM(RTRIM(downstream_qualified_name))) AS downstream_qn,
    upstream_qualified_name, downstream_qualified_name, original_relationship_type,
    plan_relationship_type, confidence, source_system, evidence, notes
INTO #plan_edges
FROM (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY LOWER(LTRIM(RTRIM(upstream_qualified_name))), LOWER(LTRIM(RTRIM(downstream_qualified_name))), plan_relationship_type, LOWER(confidence)
        ORDER BY CASE original_relationship_type WHEN 'uses_model' THEN 1 WHEN 'serves_report' THEN 2 ELSE 1 END, upstream_qualified_name, downstream_qualified_name
    ) AS rn
    FROM #plan_edges_raw
) x
WHERE rn = 1;

-- ===========================================================================
-- Step 4: node universe = edge endpoints + every duration row + metadata
-- rows whose item_type is an orchestration-relevant type. One row per
-- LOWER(qualified_name); casing priority edges > duration > metadata.
-- ===========================================================================
-- Casing tie-break: the original picks whichever casing Add-Node saw
-- FIRST while scanning dependencies.csv / execution_duration_by_item.csv
-- / metadata top-to-bottom, which needs a row-order column the bronze
-- tables don't carry. Real impact is narrow -- a handful of LOWER()-
-- collision groups, typically "External Connection / SQL /
-- <sql-server-host>..." datamart nodes with inconsistent source casing
-- (same class of issue as a "VenTas"/"Ventas" casing pair found in
-- 05_build_graph.sql) -- so this
-- picks the alphabetically-first casing per source tier instead: stable
-- and reproducible across runs, even though it isn't guaranteed to match
-- the original's file-order-dependent pick for those few names.
IF OBJECT_ID('tempdb..#node_names') IS NOT NULL DROP TABLE #node_names;
SELECT qn, qualified_name
INTO #node_names
FROM (
    SELECT qn, qualified_name, ROW_NUMBER() OVER (PARTITION BY qn ORDER BY prio, qualified_name) AS rn
    FROM (
        SELECT upstream_qn AS qn, upstream_qualified_name AS qualified_name, 1 AS prio FROM #plan_edges
        UNION ALL
        SELECT downstream_qn, downstream_qualified_name, 1 FROM #plan_edges
        UNION ALL
        SELECT qn, qualified_name, 2 FROM #duration
        UNION ALL
        SELECT qn, qualified_name, 3 FROM #metadata
        WHERE item_type IN ('DataPipeline', 'CopyJob', 'Notebook', 'Dataflow', 'SemanticModel', 'Report', 'PaginatedReport', 'Dashboard', 'Lakehouse', 'SQLEndpoint', 'Warehouse')
    ) u
) r
WHERE rn = 1;

-- Get-NameParts equivalent: workspace/item_type/item_name derived purely
-- from splitting qualified_name on " / ", with the "External Connection /
-- *" special case using the LAST segment for item_name.
IF OBJECT_ID('tempdb..#parts') IS NOT NULL DROP TABLE #parts;
SELECT qn, qualified_name,
    CASE WHEN qualified_name LIKE 'External Connection / %' THEN 'External'
         ELSE LEFT(qualified_name, CHARINDEX(' / ', qualified_name + ' / ') - 1) END AS parts_workspace,
    CASE WHEN qualified_name LIKE 'External Connection / %' THEN 'ExternalConnection'
         WHEN pos2 > 0 THEN SUBSTRING(qualified_name, pos1 + 3, pos2 - pos1 - 3)
         ELSE '' END AS parts_item_type,
    CASE WHEN qualified_name LIKE 'External Connection / %' THEN
             CASE WHEN pos2 > 0 THEN RIGHT(qualified_name, CHARINDEX(' / ', REVERSE(qualified_name) + ' / ') - 1) ELSE qualified_name END
         WHEN pos2 > 0 THEN
             CASE WHEN pos3 > 0 THEN SUBSTRING(qualified_name, pos2 + 3, pos3 - pos2 - 3) ELSE SUBSTRING(qualified_name, pos2 + 3, LEN(qualified_name)) END
         ELSE qualified_name END AS parts_item_name
INTO #parts
FROM (
    SELECT qn, qualified_name,
        CHARINDEX(' / ', qualified_name) AS pos1,
        CASE WHEN CHARINDEX(' / ', qualified_name) > 0 THEN CHARINDEX(' / ', qualified_name, CHARINDEX(' / ', qualified_name) + 3) ELSE 0 END AS pos2
    FROM #node_names
) base
CROSS APPLY (SELECT CASE WHEN pos2 > 0 THEN CHARINDEX(' / ', qualified_name, pos2 + 3) ELSE 0 END AS pos3) p3;

-- ===========================================================================
-- Step 5: the main working node table.
-- ===========================================================================
IF OBJECT_ID('tempdb..#nodes') IS NOT NULL DROP TABLE #nodes;
SELECT
    n.qn, n.qualified_name,
    ISNULL(NULLIF(m.workspace_name, ''), p.parts_workspace) AS workspace_name,
    ISNULL(NULLIF(m.item_type, ''), p.parts_item_type) AS item_type,
    ISNULL(NULLIF(m.item_name, ''), p.parts_item_name) AS item_name,
    role.orchestration_role, role.stage_index, role.proposed_stage,
    dur.estimated_duration_seconds, dur.duration_source,
    ISNULL(d.run_count, 0) AS run_count, ISNULL(d.completed_count, 0) AS completed_count,
    ISNULL(d.failed_count, 0) AS failed_count, ISNULL(d.manual_count, 0) AS manual_count,
    ISNULL(d.scheduled_count, 0) AS scheduled_count,
    ISNULL(sa.enabled_schedules, 0) AS enabled_schedules, ISNULL(sa.disabled_schedules, 0) AS disabled_schedules,
    ISNULL(st.schedule_times, '') AS schedule_times,
    ISNULL(dl.deep_lineage_status, '') AS deep_lineage_status,
    ISNULL(dl.coverage_status, '') AS object_coverage_status,
    ISNULL(dl.review_status, '') AS object_review_status,
    ISNULL(dl.object_reference_count, 0) AS object_reference_count,
    ISNULL(dl.exact_object_reference_count, 0) AS exact_object_reference_count,
    ISNULL(dl.ambiguous_object_reference_count, 0) AS ambiguous_object_reference_count,
    ISNULL(dl.confirmed_lineage_rows, 0) AS confirmed_object_lineage_rows,
    ISNULL(dl.likely_lineage_rows, 0) AS likely_object_lineage_rows,
    ISNULL(dl.read_count, 0) AS read_object_count,
    ISNULL(dl.write_count, 0) AS write_object_count,
    ISNULL(dl.execute_count, 0) AS execute_object_count,
    ISNULL(dl.unknown_count, 0) AS unknown_object_count,
    LEFT(ISNULL(dl.next_action, ''), 700) AS object_lineage_next_action,
    CAST(1 AS BIT) AS is_master_action,
    CAST(NULL AS INT) AS topological_level,
    CAST(NULL AS INT) AS wave_index,
    0 AS in_degree,
    CAST(0 AS BIT) AS has_cycle_flag
INTO #nodes
FROM #node_names n
LEFT JOIN #metadata m ON m.qn = n.qn
JOIN #parts p ON p.qn = n.qn
LEFT JOIN #duration d ON d.qn = n.qn
LEFT JOIN #schedule_agg sa ON sa.qn = n.qn
LEFT JOIN #schedule_times st ON st.qn = n.qn
LEFT JOIN #deep_lineage dl ON dl.qn = n.qn
CROSS APPLY (
    SELECT
        CASE WHEN n.qualified_name LIKE 'External Connection / %' THEN 'source_readiness'
             WHEN ISNULL(NULLIF(m.item_type, ''), p.parts_item_type) IN ('Lakehouse', 'SQLEndpoint', 'Warehouse') THEN 'source_readiness'
             WHEN ISNULL(NULLIF(m.item_type, ''), p.parts_item_type) IN ('DataPipeline', 'CopyJob', 'Notebook', 'Dataflow', 'UserDataFunction', 'Eventstream') THEN 'data_process'
             WHEN ISNULL(NULLIF(m.item_type, ''), p.parts_item_type) = 'SemanticModel' THEN 'semantic_refresh'
             WHEN ISNULL(NULLIF(m.item_type, ''), p.parts_item_type) IN ('Report', 'PaginatedReport', 'Dashboard', 'KQLDashboard') THEN 'consumption_validation'
             ELSE 'governance_review' END AS orchestration_role
) role0
CROSS APPLY (
    SELECT role0.orchestration_role AS orchestration_role,
        CASE role0.orchestration_role WHEN 'source_readiness' THEN 0 WHEN 'data_process' THEN 1 WHEN 'semantic_refresh' THEN 2 WHEN 'consumption_validation' THEN 3 ELSE 4 END AS stage_index,
        CASE role0.orchestration_role
            WHEN 'source_readiness' THEN '0_source_readiness'
            WHEN 'data_process' THEN '1_execute_and_transform'
            WHEN 'semantic_refresh' THEN '2_refresh_semantic_models'
            WHEN 'consumption_validation' THEN '3_validate_reports_and_consumption'
            ELSE '4_governance_review' END AS proposed_stage
) role
CROSS APPLY (
    SELECT
        CASE WHEN ISNULL(d.avg_duration_seconds, 0) > 0 THEN ROUND(d.avg_duration_seconds, 3)
             WHEN ISNULL(d.max_duration_seconds, 0) > 0 THEN ROUND(d.max_duration_seconds, 3)
             ELSE ROUND(CASE role.orchestration_role WHEN 'source_readiness' THEN 0.0 WHEN 'data_process' THEN 300.0 WHEN 'semantic_refresh' THEN 300.0 WHEN 'consumption_validation' THEN 30.0 ELSE 60.0 END, 3)
        END AS estimated_duration_seconds,
        CASE WHEN ISNULL(d.avg_duration_seconds, 0) > 0 THEN 'observed_avg'
             WHEN ISNULL(d.max_duration_seconds, 0) > 0 THEN 'observed_max_fallback'
             ELSE 'default_by_role' END AS duration_source
) dur;

-- ===========================================================================
-- Step 6: per-stage topological "wave" levelling (Kahn's algorithm,
-- longest-path semantics, batched by level instead of one node at a time).
-- ===========================================================================
DECLARE @stage INT = 0;
DECLARE @stageOffset INT = 0;
DECLARE @level INT;
DECLARE @maxStageLevel INT;
DECLARE @stageCount INT;

WHILE @stage <= 4
BEGIN
    SELECT @stageCount = COUNT(*) FROM #nodes WHERE stage_index = @stage;

    IF @stageCount > 0
    BEGIN
        ;WITH indeg AS (
            SELECT e.downstream_qn AS qn, COUNT(*) AS cnt
            FROM #plan_edges e
            JOIN #nodes u ON u.qn = e.upstream_qn AND u.stage_index = @stage
            JOIN #nodes d ON d.qn = e.downstream_qn AND d.stage_index = @stage
            GROUP BY e.downstream_qn
        )
        UPDATE n SET in_degree = ISNULL(x.cnt, 0)
        FROM #nodes n LEFT JOIN indeg x ON x.qn = n.qn
        WHERE n.stage_index = @stage;

        SET @level = 0;
        WHILE EXISTS (SELECT 1 FROM #nodes WHERE stage_index = @stage AND topological_level IS NULL AND in_degree = 0)
        BEGIN
            UPDATE #nodes SET topological_level = @level
            WHERE stage_index = @stage AND topological_level IS NULL AND in_degree = 0;

            ;WITH dec AS (
                SELECT e.downstream_qn AS qn, COUNT(*) AS cnt
                FROM #plan_edges e
                JOIN #nodes u ON u.qn = e.upstream_qn AND u.stage_index = @stage AND u.topological_level = @level
                JOIN #nodes dn ON dn.qn = e.downstream_qn AND dn.stage_index = @stage AND dn.topological_level IS NULL
                GROUP BY e.downstream_qn
            )
            UPDATE n SET in_degree = n.in_degree - dec.cnt
            FROM #nodes n JOIN dec ON dec.qn = n.qn;

            SET @level = @level + 1;
        END

        SELECT @maxStageLevel = ISNULL(MAX(topological_level), -1) FROM #nodes WHERE stage_index = @stage;

        UPDATE #nodes SET topological_level = @level, has_cycle_flag = 1
        WHERE stage_index = @stage AND topological_level IS NULL;

        IF EXISTS (SELECT 1 FROM #nodes WHERE stage_index = @stage AND has_cycle_flag = 1)
            SET @maxStageLevel = @level;

        UPDATE #nodes SET wave_index = @stageOffset + topological_level WHERE stage_index = @stage;

        SET @stageOffset = @stageOffset + @maxStageLevel + 1;
    END

    SET @stage = @stage + 1;
END

-- ===========================================================================
-- Step 7: wave timing (max duration per wave, cumulative start times).
-- ===========================================================================
IF OBJECT_ID('tempdb..#wave_timing') IS NOT NULL DROP TABLE #wave_timing;
;WITH wave_base AS (
    SELECT wave_index, MAX(estimated_duration_seconds) AS wave_duration
    FROM #nodes GROUP BY wave_index
)
SELECT wave_index, wave_duration,
    ISNULL(SUM(wave_duration) OVER (ORDER BY wave_index ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS estimated_start_seconds
INTO #wave_timing
FROM wave_base;

-- ===========================================================================
-- Step 8: edge-derived counts (predecessor/successor/likely, executes
-- in/out) and risk-set membership from 07's already-validated silver_*
-- outputs.
-- ===========================================================================
IF OBJECT_ID('tempdb..#pred_count') IS NOT NULL DROP TABLE #pred_count;
SELECT downstream_qn AS qn, COUNT(*) AS predecessor_count INTO #pred_count FROM #plan_edges GROUP BY downstream_qn;
IF OBJECT_ID('tempdb..#succ_count') IS NOT NULL DROP TABLE #succ_count;
SELECT upstream_qn AS qn, COUNT(*) AS successor_count INTO #succ_count FROM #plan_edges GROUP BY upstream_qn;
IF OBJECT_ID('tempdb..#incoming_likely') IS NOT NULL DROP TABLE #incoming_likely;
SELECT downstream_qn AS qn, COUNT(*) AS incoming_likely_edges INTO #incoming_likely FROM #plan_edges WHERE LOWER(confidence) <> 'confirmed' GROUP BY downstream_qn;
IF OBJECT_ID('tempdb..#outgoing_likely') IS NOT NULL DROP TABLE #outgoing_likely;
SELECT upstream_qn AS qn, COUNT(*) AS outgoing_likely_edges INTO #outgoing_likely FROM #plan_edges WHERE LOWER(confidence) <> 'confirmed' GROUP BY upstream_qn;
IF OBJECT_ID('tempdb..#incoming_executes') IS NOT NULL DROP TABLE #incoming_executes;
SELECT downstream_qn AS qn, COUNT(*) AS incoming_executes INTO #incoming_executes FROM #plan_edges WHERE original_relationship_type = 'executes' GROUP BY downstream_qn;
IF OBJECT_ID('tempdb..#outgoing_executes') IS NOT NULL DROP TABLE #outgoing_executes;
SELECT upstream_qn AS qn, COUNT(*) AS outgoing_executes INTO #outgoing_executes FROM #plan_edges WHERE original_relationship_type = 'executes' GROUP BY upstream_qn;

IF OBJECT_ID('tempdb..#critical_set') IS NOT NULL DROP TABLE #critical_set;
SELECT DISTINCT LOWER(LTRIM(RTRIM(qualified_name))) AS qn INTO #critical_set FROM dbo.silver_critical_path_candidates;
IF OBJECT_ID('tempdb..#failure_set') IS NOT NULL DROP TABLE #failure_set;
SELECT DISTINCT LOWER(LTRIM(RTRIM(qualified_name))) AS qn INTO #failure_set FROM dbo.silver_failure_hotspots;
IF OBJECT_ID('tempdb..#manual_set') IS NOT NULL DROP TABLE #manual_set;
SELECT DISTINCT LOWER(LTRIM(RTRIM(qualified_name))) AS qn INTO #manual_set FROM dbo.silver_manual_execution_candidates;
IF OBJECT_ID('tempdb..#schedule_review_set') IS NOT NULL DROP TABLE #schedule_review_set;
SELECT DISTINCT LOWER(LTRIM(RTRIM(qualified_name))) AS qn INTO #schedule_review_set FROM dbo.silver_schedule_review_candidates;
IF OBJECT_ID('tempdb..#fanout_set') IS NOT NULL DROP TABLE #fanout_set;
SELECT DISTINCT LOWER(LTRIM(RTRIM(source_qualified_name))) AS qn INTO #fanout_set FROM dbo.silver_orchestration_group_candidates;

-- ===========================================================================
-- Step 9: derived fields (is_master_action, action_type, parallel_
-- readiness, risk_flags, recommendation) and wave-bottleneck detection.
-- ===========================================================================
IF OBJECT_ID('tempdb..#nodes2') IS NOT NULL DROP TABLE #nodes2;
SELECT
    n.*,
    ISNULL(pc.predecessor_count, 0) AS predecessor_count,
    ISNULL(sc.successor_count, 0) AS successor_count,
    ISNULL(il.incoming_likely_edges, 0) AS incoming_likely_edges,
    ISNULL(ol.outgoing_likely_edges, 0) AS outgoing_likely_edges,
    CASE WHEN ie.qn IS NOT NULL THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END AS is_master_action_final,
    CASE WHEN ie.qn IS NOT NULL THEN 1 ELSE 0 END AS covered_by_orchestrator,
    CASE WHEN oe.qn IS NOT NULL THEN 1 ELSE 0 END AS has_outgoing_executes,
    wt.estimated_start_seconds,
    ROUND(wt.estimated_start_seconds + n.estimated_duration_seconds, 3) AS estimated_finish_seconds,
    CASE WHEN cs.qn IS NOT NULL THEN 1 ELSE 0 END AS in_critical_set,
    CASE WHEN fs.qn IS NOT NULL THEN 1 ELSE 0 END AS in_failure_set,
    CASE WHEN ms.qn IS NOT NULL THEN 1 ELSE 0 END AS in_manual_set,
    CASE WHEN srs.qn IS NOT NULL THEN 1 ELSE 0 END AS in_schedule_review_set,
    CASE WHEN fos.qn IS NOT NULL THEN 1 ELSE 0 END AS in_fanout_set,
    CASE WHEN ABS(n.estimated_duration_seconds - wt.wave_duration) < 0.001 AND wt.wave_duration > 0 AND n.estimated_duration_seconds > 0 THEN 1 ELSE 0 END AS is_wave_bottleneck
INTO #nodes2
FROM #nodes n
LEFT JOIN #pred_count pc ON pc.qn = n.qn
LEFT JOIN #succ_count sc ON sc.qn = n.qn
LEFT JOIN #incoming_likely il ON il.qn = n.qn
LEFT JOIN #outgoing_likely ol ON ol.qn = n.qn
LEFT JOIN #incoming_executes ie ON ie.qn = n.qn
LEFT JOIN #outgoing_executes oe ON oe.qn = n.qn
JOIN #wave_timing wt ON wt.wave_index = n.wave_index
LEFT JOIN #critical_set cs ON cs.qn = n.qn
LEFT JOIN #failure_set fs ON fs.qn = n.qn
LEFT JOIN #manual_set ms ON ms.qn = n.qn
LEFT JOIN #schedule_review_set srs ON srs.qn = n.qn
LEFT JOIN #fanout_set fos ON fos.qn = n.qn;

IF OBJECT_ID('tempdb..#nodes3') IS NOT NULL DROP TABLE #nodes3;
SELECT *,
    action_type_calc AS action_type,
    parallel_readiness_calc AS parallel_readiness,
    risk_flags_calc AS risk_flags,
    recommendation_calc AS recommendation
INTO #nodes3
FROM #nodes2
CROSS APPLY (
    SELECT
        CASE
            WHEN orchestration_role = 'source_readiness' THEN 'check_source_readiness'
            WHEN orchestration_role = 'data_process' AND has_outgoing_executes = 1 THEN 'run_existing_orchestrator_or_refactor_branches'
            WHEN orchestration_role = 'data_process' AND is_master_action_final = 1 THEN 'run_standalone_process'
            WHEN orchestration_role = 'data_process' THEN 'child_activity_inside_existing_orchestrator'
            WHEN orchestration_role = 'semantic_refresh' THEN 'refresh_semantic_model_after_upstream_readiness'
            WHEN orchestration_role = 'consumption_validation' THEN 'validate_report_after_model_refresh'
            ELSE 'review_governance_or_unsupported_item'
        END AS action_type_calc,
        CASE
            WHEN in_failure_set = 1 THEN 'hold_until_stabilized'
            WHEN deep_lineage_status IN ('source_missing', 'object_missing', 'blocked_unknown_operation') THEN 'blocked_pending_deep_object_lineage'
            WHEN ambiguous_object_reference_count > 0 OR likely_object_lineage_rows > 0 THEN 'candidate_requires_object_lineage_confirmation'
            WHEN write_object_count > 0 THEN 'candidate_requires_write_conflict_review'
            WHEN item_type IN ('Notebook', 'CopyJob', 'DataPipeline', 'Dataflow') THEN 'candidate_requires_read_write_validation'
            WHEN incoming_likely_edges > 0 OR outgoing_likely_edges > 0 THEN 'candidate_requires_dependency_confirmation'
            ELSE 'low_graph_risk_candidate'
        END AS parallel_readiness_calc,
        STUFF(
            CASE WHEN has_cycle_flag = 1 THEN '; cycle_or_unresolved_same_stage_dependency' ELSE '' END +
            CASE WHEN in_critical_set = 1 THEN '; critical_path_candidate' ELSE '' END +
            CASE WHEN in_failure_set = 1 THEN '; failure_hotspot_stabilize_first' ELSE '' END +
            CASE WHEN in_manual_set = 1 THEN '; repeated_manual_candidate' ELSE '' END +
            CASE WHEN in_schedule_review_set = 1 THEN '; schedule_review_required' ELSE '' END +
            CASE WHEN in_fanout_set = 1 THEN '; existing_fanout_orchestrator' ELSE '' END +
            CASE WHEN incoming_likely_edges > 0 OR outgoing_likely_edges > 0 THEN '; has_likely_dependency_evidence' ELSE '' END +
            CASE deep_lineage_status
                WHEN 'source_missing' THEN '; phase12_source_missing'
                WHEN 'object_missing' THEN '; phase12_object_missing'
                WHEN 'blocked_unknown_operation' THEN '; phase12_unknown_object_operation'
                WHEN 'needs_object_type_resolution' THEN '; phase12_object_type_resolution_required'
                WHEN 'needs_lineage_confirmation' THEN '; phase12_likely_object_lineage'
                WHEN 'ready_confirmed' THEN '; phase12_object_lineage_confirmed'
                ELSE '' END +
            CASE WHEN write_object_count > 0 THEN '; phase12_write_targets_detected' ELSE '' END +
            CASE WHEN item_type = 'Notebook' AND deep_lineage_status = '' THEN '; notebook_read_write_validation_required' ELSE '' END +
            CASE WHEN duration_source = 'default_by_role' AND orchestration_role <> 'source_readiness' THEN '; duration_defaulted' ELSE '' END +
            CASE WHEN covered_by_orchestrator = 1 THEN '; covered_by_existing_orchestrator' ELSE '' END +
            CASE WHEN is_wave_bottleneck = 1 THEN '; wave_bottleneck' ELSE '' END
        , 1, 2, '') AS risk_flags_calc,
        CASE
            WHEN in_failure_set = 1 THEN 'Stabilize failures before using this node in an optimized production orchestration.'
            WHEN deep_lineage_status IN ('source_missing', 'object_missing', 'blocked_unknown_operation') THEN 'Complete Phase 12 source/object lineage evidence before using this node as an orchestration dependency or parallel candidate.'
            WHEN deep_lineage_status = 'needs_object_type_resolution' THEN 'Resolve ambiguous table/view/native-query object types before approving impact analysis or parallel execution.'
            WHEN deep_lineage_status = 'needs_lineage_confirmation' THEN 'Confirm likely object-level lineage before treating this node as a hard sequencing rule.'
            WHEN write_object_count > 0 THEN 'Review write targets and shared-table/file conflicts before placing this node in a parallel wave.'
            WHEN item_type = 'Notebook' AND deep_lineage_status = '' THEN 'Inspect notebook reads/writes before approving parallel execution or master-pipeline scheduling.'
            WHEN orchestration_role = 'semantic_refresh' THEN 'Refresh after source readiness and upstream process waves selected for the same business flow.'
            WHEN orchestration_role = 'data_process' THEN 'Place in its wave only after confirming upstream readiness, writes, retries, and owner approval.'
            ELSE 'Use as a proposal row for human review; do not deploy automatically.'
        END AS recommendation_calc
) calc;

-- ===========================================================================
-- Step 10: final outputs.
-- ===========================================================================
SELECT
    wave_index, proposed_stage, qualified_name, workspace_name, item_name, item_type,
    orchestration_role, action_type, is_master_action_final AS is_master_action,
    ROUND(estimated_start_seconds, 3) AS estimated_start_seconds,
    estimated_duration_seconds, estimated_finish_seconds, duration_source, topological_level,
    predecessor_count, successor_count, incoming_likely_edges, outgoing_likely_edges,
    deep_lineage_status, object_coverage_status, object_review_status, object_reference_count,
    exact_object_reference_count, ambiguous_object_reference_count, confirmed_object_lineage_rows,
    likely_object_lineage_rows, read_object_count, write_object_count, execute_object_count,
    unknown_object_count, object_lineage_next_action, run_count, completed_count, failed_count,
    manual_count, scheduled_count, enabled_schedules, disabled_schedules, schedule_times,
    ('wave_' + CAST(wave_index AS VARCHAR(10))) AS parallel_group, parallel_readiness, risk_flags,
    'yes' AS human_validation_required, recommendation
INTO dbo.silver_ideal_execution_plan
FROM #nodes3;

SELECT
    upstream_qualified_name, downstream_qualified_name, original_relationship_type,
    plan_relationship_type, confidence, source_system, evidence, notes
INTO dbo.silver_ideal_execution_edges
FROM #plan_edges;

;WITH stage_breakdown_agg AS (
    SELECT wave_index, STRING_AGG(txt, '; ') WITHIN GROUP (ORDER BY txt) AS stage_breakdown
    FROM (
        SELECT wave_index, proposed_stage + '=' + CAST(COUNT(*) AS VARCHAR(10)) AS txt
        FROM #nodes3 GROUP BY wave_index, proposed_stage
    ) x GROUP BY wave_index
),
bottleneck_ranked AS (
    -- Tie-break by LOWER(qualified_name), not the Warehouse's binary-
    -- collation qualified_name -- PowerShell's Sort-Object is stable and
    -- (for ties) preserves $planRows' own earlier culture-aware sort by
    -- qualified_name, which groups by base letter ignoring case, unlike
    -- SQL's default uppercase-before-lowercase ordinal comparison.
    --
    -- KNOWN LIMITATION: most wave-0/1 (source_readiness) and several
    -- other-wave nodes default to duration=0, so for those waves this
    -- tie-break is deciding a top-8 pick among many tied items --
    -- and neither LOWER() nor COLLATE Latin1_General_CI_AS (tried and
    -- rejected; no better a match) reproduces .NET's CurrentCulture
    -- (es-ES) linguistic Sort-Object ordering closely enough for those
    -- large tied groups. Verified against a real run: this only ever
    -- affects silver_ideal_execution_waves.bottleneck_items (an
    -- illustrative "up to 8 examples" sample text field) -- every one of
    -- the plan-node rows and all other wave columns (counts,
    -- timing, stage_breakdown) match the real PowerShell output exactly.
    SELECT wave_index, qualified_name,
        ROW_NUMBER() OVER (PARTITION BY wave_index ORDER BY estimated_duration_seconds DESC, LOWER(qualified_name) ASC) AS rn
    FROM #nodes3
),
bottleneck_agg AS (
    SELECT wave_index, STRING_AGG(qualified_name, '; ') WITHIN GROUP (ORDER BY rn) AS bottleneck_items
    FROM bottleneck_ranked WHERE rn <= 8 GROUP BY wave_index
)
SELECT
    wt.wave_index,
    ROUND(wt.estimated_start_seconds, 3) AS estimated_start_seconds,
    ROUND(wt.wave_duration, 3) AS estimated_parallel_duration_seconds,
    ROUND(wt.estimated_start_seconds + wt.wave_duration, 3) AS estimated_finish_seconds,
    agg.node_count, agg.master_action_count, agg.risk_flag_count, agg.deep_lineage_blocker_count,
    agg.object_lineage_confirmation_count, agg.write_conflict_review_count,
    ISNULL(sb.stage_breakdown, '') AS stage_breakdown,
    LEFT(ISNULL(ba.bottleneck_items, ''), 1600) AS bottleneck_items,
    'Run nodes in this wave in parallel only after human dependency and read/write validation; the longest item controls the wave duration.' AS recommendation
INTO dbo.silver_ideal_execution_waves
FROM #wave_timing wt
CROSS APPLY (
    SELECT COUNT(*) AS node_count,
        SUM(CASE WHEN is_master_action_final = 1 THEN 1 ELSE 0 END) AS master_action_count,
        SUM(CASE WHEN risk_flags <> '' THEN 1 ELSE 0 END) AS risk_flag_count,
        SUM(CASE WHEN parallel_readiness = 'blocked_pending_deep_object_lineage' THEN 1 ELSE 0 END) AS deep_lineage_blocker_count,
        SUM(CASE WHEN parallel_readiness = 'candidate_requires_object_lineage_confirmation' THEN 1 ELSE 0 END) AS object_lineage_confirmation_count,
        SUM(CASE WHEN parallel_readiness = 'candidate_requires_write_conflict_review' THEN 1 ELSE 0 END) AS write_conflict_review_count
    FROM #nodes3 WHERE wave_index = wt.wave_index
) agg
LEFT JOIN stage_breakdown_agg sb ON sb.wave_index = wt.wave_index
LEFT JOIN bottleneck_agg ba ON ba.wave_index = wt.wave_index;

-- Read the LAST wave's own finish time (matching the original's "sort by
-- wave_index, take the last row's estimated_finish_seconds"). CAST(FLOAT
-- AS VARCHAR) truncates to ~6 significant digits by default in T-SQL
-- (unlike .NET's round-trip ToString(), which is what the waves table's
-- native FLOAT column goes through when dumped for comparison) --
-- "2685.167" (7 sig figs) silently became "2685.17" this way. Routing
-- through DECIMAL(18,3) avoids the truncation but pads trailing zeros
-- ("300.000" instead of "300"), which PowerShell's double.ToString()
-- never emits -- so those are stripped back off below.
DECLARE @wallClockDecimalText VARCHAR(30) = (
    SELECT TOP 1 CAST(CAST(ROUND(estimated_start_seconds + wave_duration, 3) AS DECIMAL(18,3)) AS VARCHAR(30))
    FROM #wave_timing ORDER BY wave_index DESC
);
IF @wallClockDecimalText IS NULL SET @wallClockDecimalText = '0';
IF CHARINDEX('.', @wallClockDecimalText) > 0
BEGIN
    SET @wallClockDecimalText = LEFT(@wallClockDecimalText, LEN(@wallClockDecimalText) - PATINDEX('%[^0]%', REVERSE(@wallClockDecimalText)) + 1);
    IF RIGHT(@wallClockDecimalText, 1) = '.' SET @wallClockDecimalText = LEFT(@wallClockDecimalText, LEN(@wallClockDecimalText) - 1);
END

SELECT metric, value, notes INTO dbo.silver_ideal_execution_summary FROM (
    SELECT 'plan_nodes' AS metric, CAST(COUNT(*) AS VARCHAR(20)) AS value, 'Rows in analysis/ideal_execution_plan.csv.' AS notes FROM #nodes3
    UNION ALL SELECT 'master_actions', CAST(SUM(CASE WHEN is_master_action_final = 1 THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Rows that could become master-pipeline checkpoints/actions after approval.' FROM #nodes3
    UNION ALL SELECT 'plan_edges', CAST(COUNT(*) AS VARCHAR(20)), 'Execution-oriented dependency edges.' FROM #plan_edges
    UNION ALL SELECT 'confirmed_edges', CAST(SUM(CASE WHEN confidence = 'confirmed' THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Edges backed by confirmed evidence.' FROM #plan_edges
    UNION ALL SELECT 'candidate_edges', CAST(SUM(CASE WHEN confidence <> 'confirmed' THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Likely/unknown edges requiring confirmation.' FROM #plan_edges
    UNION ALL SELECT 'waves', CAST(COUNT(*) AS VARCHAR(20)), 'Conservative stage-barrier waves.' FROM #wave_timing
    UNION ALL SELECT 'estimated_wall_clock_seconds', @wallClockDecimalText, 'Sum of max duration per wave; planning estimate, not an SLA.' FROM (SELECT 1 AS x) z
    UNION ALL SELECT 'failure_hold_nodes', CAST(SUM(CASE WHEN parallel_readiness = 'hold_until_stabilized' THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Nodes to stabilize before production optimization.' FROM #nodes3
    UNION ALL SELECT 'read_write_validation_nodes', CAST(SUM(CASE WHEN parallel_readiness = 'candidate_requires_read_write_validation' THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Mostly notebooks/pipelines/copy jobs needing code-level validation before parallelism.' FROM #nodes3
    UNION ALL SELECT 'phase12_deep_lineage_nodes', CAST(SUM(CASE WHEN deep_lineage_status <> '' THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Plan nodes with Phase 12 deep object lineage metadata.' FROM #nodes3
    UNION ALL SELECT 'phase12_deep_lineage_blocked_nodes', CAST(SUM(CASE WHEN parallel_readiness = 'blocked_pending_deep_object_lineage' THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Nodes blocked by missing source/object lineage or unknown object operation.' FROM #nodes3
    UNION ALL SELECT 'phase12_object_lineage_confirmation_nodes', CAST(SUM(CASE WHEN parallel_readiness = 'candidate_requires_object_lineage_confirmation' THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Nodes needing object type resolution or likely lineage confirmation.' FROM #nodes3
    UNION ALL SELECT 'phase12_write_conflict_review_nodes', CAST(SUM(CASE WHEN parallel_readiness = 'candidate_requires_write_conflict_review' THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Nodes with write targets that require conflict review before parallelism.' FROM #nodes3
    UNION ALL SELECT 'phase12_write_target_nodes', CAST(SUM(CASE WHEN write_object_count > 0 THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Nodes where Phase 12 detected at least one write target, including nodes already blocked by stronger gates.' FROM #nodes3
    UNION ALL SELECT 'phase12_exact_object_reference_rows', CAST(SUM(exact_object_reference_count) AS VARCHAR(20)), 'Exact object reference rows carried into the execution plan.' FROM #nodes3
    UNION ALL SELECT 'phase12_ambiguous_object_reference_rows', CAST(SUM(ambiguous_object_reference_count) AS VARCHAR(20)), 'Ambiguous object reference rows carried into the execution plan.' FROM #nodes3
    UNION ALL SELECT 'phase12_likely_object_lineage_rows', CAST(SUM(likely_object_lineage_rows) AS VARCHAR(20)), 'Likely object lineage rows carried into the execution plan.' FROM #nodes3
    UNION ALL SELECT 'defaulted_duration_nodes', CAST(SUM(CASE WHEN duration_source = 'default_by_role' THEN 1 ELSE 0 END) AS VARCHAR(20)), 'Rows without observed duration; default duration used.' FROM #nodes3
    UNION ALL SELECT 'parallel_candidate_pairs', CAST((SELECT COUNT(*) FROM dbo.silver_parallelism_candidates) AS VARCHAR(20)), 'Candidate pairs from Phase 7, not approvals.'
) s;

END
