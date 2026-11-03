-- Warehouse-native translation of backend/scripts/08_build_semantic_lineage.ps1
-- (Phase 2 migration continuation, 2026-07-21). Covers only the 4 CSV data
-- outputs (semantic_model_datamart_dependencies, semantic_model_report_
-- dependencies, semantic_datamart_summary, semantic_model_lineage_summary).
--
-- The original script's larger second half (source-object-type resolver
-- chain, sourceObjectRows, and the interactive JSON graph for frontend/
-- semantic-lineage/data/semantic-lineage.json) is NOT translated here --
-- verified by reading the whole script that $sourceObjectRows is never
-- exported to any CSV; it exists purely to build the JSON explorer
-- payload and the markdown doc's tables, both app-layer per this
-- migration's established rule (same as Mermaid/HTML elsewhere).
--
-- item/model qualified_name matching uses LOWER(LTRIM(RTRIM(...))),
-- mirroring plain PowerShell hashtables' case-insensitive default.
CREATE OR ALTER PROCEDURE dbo.sp_build_semantic_lineage
AS
BEGIN

IF OBJECT_ID('dbo.silver_semantic_model_datamart_dependencies', 'U') IS NOT NULL DROP TABLE dbo.silver_semantic_model_datamart_dependencies;
IF OBJECT_ID('dbo.silver_semantic_model_report_dependencies', 'U') IS NOT NULL DROP TABLE dbo.silver_semantic_model_report_dependencies;
IF OBJECT_ID('dbo.silver_semantic_datamart_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_semantic_datamart_summary;
IF OBJECT_ID('dbo.silver_semantic_model_lineage_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_semantic_model_lineage_summary;

IF OBJECT_ID('tempdb..#models') IS NOT NULL DROP TABLE #models;
SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS model_key, qualified_name, workspace_name, workspace_environment, item_name
INTO #models
FROM dbo.bronze_items
WHERE status = 'discovered' AND item_type = 'SemanticModel';

-- ===========================================================================
-- Schedules and refresh runs per model.
-- ===========================================================================
IF OBJECT_ID('tempdb..#schedule_agg') IS NOT NULL DROP TABLE #schedule_agg;
SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS model_key,
    SUM(CASE WHEN schedule_enabled = 'True' THEN 1 ELSE 0 END) AS enabled_schedules,
    SUM(CASE WHEN schedule_enabled <> 'True' THEN 1 ELSE 0 END) AS disabled_schedules
INTO #schedule_agg
FROM dbo.bronze_executions
WHERE record_type = 'schedule' AND item_type = 'SemanticModel'
GROUP BY LOWER(LTRIM(RTRIM(qualified_name)));

IF OBJECT_ID('tempdb..#refresh_agg') IS NOT NULL DROP TABLE #refresh_agg;
;WITH jobs AS (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS model_key, start_time, status
    FROM dbo.bronze_executions
    WHERE record_type = 'job_instance' AND item_type = 'SemanticModel'
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY model_key ORDER BY CASE WHEN start_time = '' THEN 0 ELSE 1 END DESC, start_time DESC) AS rn
    FROM jobs
)
SELECT model_key,
    COUNT(*) AS refresh_runs,
    SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END) AS refresh_failed,
    SUM(CASE WHEN status = 'Completed' THEN 1 ELSE 0 END) AS refresh_completed,
    MAX(CASE WHEN rn = 1 AND start_time <> '' THEN start_time ELSE NULL END) AS latest_refresh,
    MAX(CASE WHEN rn = 1 AND start_time <> '' THEN status ELSE NULL END) AS latest_refresh_status
INTO #refresh_agg
FROM ranked
GROUP BY model_key;

-- ===========================================================================
-- Model -> external-connection source dependencies (parses the "External
-- Connection / <SourceType> / <server>;<database>;<view>" qualified name).
-- ===========================================================================
IF OBJECT_ID('tempdb..#model_sources') IS NOT NULL DROP TABLE #model_sources;
SELECT
    m.workspace_name, m.workspace_environment, m.item_name AS semantic_model_name,
    m.qualified_name AS semantic_model_qualified_name,
    p.source_type, p.source_server, p.datamart_name, p.view_or_object,
    d.to_qualified_name AS source_qualified_name,
    d.confidence, d.evidence, p.connection_label,
    ISNULL(r.refresh_runs, 0) AS refresh_runs, ISNULL(r.refresh_failed, 0) AS refresh_failed,
    ISNULL(r.latest_refresh_status, '') AS refresh_latest_status,
    ISNULL(s.enabled_schedules, 0) AS enabled_schedules, ISNULL(s.disabled_schedules, 0) AS disabled_schedules
INTO #model_sources
FROM dbo.bronze_dependencies d
JOIN #models m ON m.model_key = LOWER(LTRIM(RTRIM(d.from_qualified_name)))
CROSS APPLY (
    SELECT
        CASE WHEN pos1a > 0 THEN CASE WHEN pos2a > 0 THEN SUBSTRING(d.to_qualified_name, pos1a + 3, pos2a - pos1a - 3) ELSE SUBSTRING(d.to_qualified_name, pos1a + 3, LEN(d.to_qualified_name)) END ELSE 'Unknown' END AS source_type_calc,
        CASE WHEN pos2a > 0 THEN SUBSTRING(d.to_qualified_name, pos2a + 3, LEN(d.to_qualified_name)) ELSE d.to_qualified_name END AS connection_text_calc
    FROM (SELECT CHARINDEX(' / ', d.to_qualified_name) AS pos1a) p0
    CROSS APPLY (SELECT CASE WHEN p0.pos1a > 0 THEN CHARINDEX(' / ', d.to_qualified_name, p0.pos1a + 3) ELSE 0 END AS pos2a) p1
) parts0
CROSS APPLY (
    SELECT parts0.source_type_calc AS source_type, parts0.connection_text_calc AS connection_label,
        CASE WHEN semi1 > 0 THEN LEFT(parts0.connection_text_calc, semi1 - 1)
             WHEN parts0.source_type_calc = 'SharePoint' THEN parts0.connection_text_calc
             ELSE '' END AS source_server,
        CASE WHEN semi1 > 0 AND semi2 > 0 THEN SUBSTRING(parts0.connection_text_calc, semi1 + 1, semi2 - semi1 - 1)
             WHEN semi1 > 0 THEN SUBSTRING(parts0.connection_text_calc, semi1 + 1, LEN(parts0.connection_text_calc))
             WHEN parts0.source_type_calc = 'SharePoint' THEN 'SharePoint'
             ELSE parts0.connection_text_calc END AS datamart_name,
        CASE WHEN semi1 > 0 AND semi2 > 0 THEN SUBSTRING(parts0.connection_text_calc, semi2 + 1, LEN(parts0.connection_text_calc)) ELSE '' END AS view_or_object
    FROM (SELECT CHARINDEX(';', parts0.connection_text_calc) AS semi1) s0
    CROSS APPLY (SELECT CASE WHEN s0.semi1 > 0 THEN CHARINDEX(';', parts0.connection_text_calc, s0.semi1 + 1) ELSE 0 END AS semi2) s1
) p
LEFT JOIN #refresh_agg r ON r.model_key = m.model_key
LEFT JOIN #schedule_agg s ON s.model_key = m.model_key
WHERE d.relationship_type = 'depends_on' AND d.to_qualified_name LIKE 'External Connection / %';

SELECT * INTO dbo.silver_semantic_model_datamart_dependencies FROM #model_sources;

-- ===========================================================================
-- Model -> report dependencies.
-- ===========================================================================
IF OBJECT_ID('tempdb..#model_reports') IS NOT NULL DROP TABLE #model_reports;
SELECT
    m.workspace_name, m.workspace_environment, m.item_name AS semantic_model_name,
    m.qualified_name AS semantic_model_qualified_name,
    d.to_qualified_name AS report_qualified_name,
    RIGHT(d.to_qualified_name, CHARINDEX(' / ', REVERSE(d.to_qualified_name) + ' / ') - 1) AS report_name,
    d.confidence, d.evidence
INTO #model_reports
FROM dbo.bronze_dependencies d
JOIN #models m ON m.model_key = LOWER(LTRIM(RTRIM(d.from_qualified_name)))
WHERE d.relationship_type = 'serves_report';

SELECT * INTO dbo.silver_semantic_model_report_dependencies FROM #model_reports;

-- ===========================================================================
-- Model lineage summary (one row per semantic model).
-- ===========================================================================
IF OBJECT_ID('tempdb..#source_counts') IS NOT NULL DROP TABLE #source_counts;
SELECT LOWER(LTRIM(RTRIM(semantic_model_qualified_name))) AS model_key, COUNT(*) AS source_count
INTO #source_counts FROM #model_sources GROUP BY LOWER(LTRIM(RTRIM(semantic_model_qualified_name)));

IF OBJECT_ID('tempdb..#report_counts') IS NOT NULL DROP TABLE #report_counts;
SELECT LOWER(LTRIM(RTRIM(semantic_model_qualified_name))) AS model_key, COUNT(*) AS report_count
INTO #report_counts FROM #model_reports GROUP BY LOWER(LTRIM(RTRIM(semantic_model_qualified_name)));

SELECT
    m.workspace_name, m.workspace_environment, m.item_name AS semantic_model_name, m.qualified_name AS semantic_model_qualified_name,
    ISNULL(sc.source_count, 0) AS source_count, ISNULL(rc.report_count, 0) AS report_count,
    ISNULL(r.refresh_runs, 0) AS refresh_runs, ISNULL(r.refresh_failed, 0) AS refresh_failed, ISNULL(r.refresh_completed, 0) AS refresh_completed,
    ISNULL(r.latest_refresh, '') AS latest_refresh, ISNULL(r.latest_refresh_status, '') AS latest_refresh_status,
    ISNULL(s.enabled_schedules, 0) AS enabled_schedules, ISNULL(s.disabled_schedules, 0) AS disabled_schedules,
    CASE WHEN sc.model_key IS NOT NULL THEN 'source_connection_confirmed' ELSE 'source_connection_missing' END AS lineage_status
INTO dbo.silver_semantic_model_lineage_summary
FROM #models m
LEFT JOIN #source_counts sc ON sc.model_key = m.model_key
LEFT JOIN #report_counts rc ON rc.model_key = m.model_key
LEFT JOIN #refresh_agg r ON r.model_key = m.model_key
LEFT JOIN #schedule_agg s ON s.model_key = m.model_key;

-- ===========================================================================
-- Datamart/source summary, grouped by LOWER(source_type/server/datamart) --
-- PowerShell's Group-Object uses case-insensitive equality by default,
-- unlike the Warehouse's binary collation (same class of gap found in
-- 05_build_graph.sql: case-sensitive GROUP BY gave more groups here
-- than PowerShell's output did). MAX() picks a
-- deterministic display casing when source rows disagree.
-- ===========================================================================
SELECT
    MAX(source_type) AS source_type, MAX(source_server) AS source_server, MAX(datamart_name) AS datamart_name,
    COUNT(DISTINCT LOWER(LTRIM(RTRIM(semantic_model_qualified_name)))) AS semantic_model_count,
    COUNT(*) AS dependency_count,
    (SELECT STRING_AGG(w, '; ') WITHIN GROUP (ORDER BY LOWER(w)) FROM (SELECT DISTINCT workspace_name AS w FROM #model_sources ms2
        WHERE LOWER(ms2.source_type) = LOWER(ms1.source_type) AND LOWER(ms2.source_server) = LOWER(ms1.source_server) AND LOWER(ms2.datamart_name) = LOWER(ms1.datamart_name) AND ms2.workspace_name <> '') x) AS workspaces,
    CASE WHEN SUM(CASE WHEN confidence <> 'confirmed' THEN 1 ELSE 0 END) = 0 THEN 'confirmed' ELSE 'mixed' END AS confidence
INTO dbo.silver_semantic_datamart_summary
FROM #model_sources ms1
GROUP BY LOWER(source_type), LOWER(source_server), LOWER(datamart_name);

END
