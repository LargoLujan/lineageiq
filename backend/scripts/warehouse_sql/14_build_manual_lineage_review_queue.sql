-- Warehouse-native translation of backend/scripts/14_build_manual_lineage_
-- review_queue.ps1 (SQL migration). Reads
-- dbo.bronze_items/dependencies/semantic_model_view_candidates/item_
-- object_lineage_candidates/pipeline_object_lineage_candidates/manual_
-- lineage_object_evidence/execution_duration_by_item, plus 07's already-
-- validated dbo.silver_critical_path_candidates/silver_failure_hotspots
-- (chaining off SQL, not Phase 7's CSVs). Purely local, no recursion.
--
-- Locale gotcha: same Convert-ToDouble comma-decimal bug found in 07/13/
-- 24 also existed in this script's own Convert-ToDouble (fixed in the
-- .ps1 too). REPLACE(col, ',', '.') before every TRY_CAST(...AS FLOAT)
-- on avg/max_duration_seconds here for the same reason.
--
-- item_qualified_name/qualified_name matching uses LOWER(LTRIM(RTRIM
-- (...))) throughout -- the original keys plain PowerShell hashtables
-- (@{}) by these values, which are case-insensitive by default, unlike
-- the Warehouse's case-sensitive binary collation (same class of gap
-- found in 05_build_graph.sql).
CREATE OR ALTER PROCEDURE dbo.sp_build_manual_lineage_review_queue
AS
BEGIN

IF OBJECT_ID('dbo.silver_manual_lineage_review_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_manual_lineage_review_queue;
IF OBJECT_ID('dbo.silver_manual_lineage_review_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_manual_lineage_review_summary;

-- index/manual_lineage_object_evidence.csv is a human-filled template,
-- currently header-only (0 data rows) -- 67_upload_bronze_to_warehouse.
-- ps1 skips uploading genuinely empty CSVs, so the bronze table doesn't
-- exist yet. Create it empty (matching the CSV header) so the rest of
-- this procedure runs unconditionally; once a human adds real rows and
-- 67 re-runs, its own DROP+CREATE-on-first-upload logic replaces this
-- placeholder with the real table, no conflict.
IF OBJECT_ID('dbo.bronze_manual_lineage_object_evidence', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.bronze_manual_lineage_object_evidence (
        workspace_name VARCHAR(400), item_type VARCHAR(100), item_name VARCHAR(400), item_qualified_name VARCHAR(500),
        source_type VARCHAR(100), source_name VARCHAR(400), source_qualified_name VARCHAR(500), source_server VARCHAR(400),
        source_database VARCHAR(400), schema_name VARCHAR(200), object_name VARCHAR(400), object_type VARCHAR(100),
        usage_type VARCHAR(100), confidence VARCHAR(100), evidence VARCHAR(2000), reviewer VARCHAR(200), reviewed_at VARCHAR(100), notes VARCHAR(2000)
    );
END

IF OBJECT_ID('tempdb..#source_deps') IS NOT NULL DROP TABLE #source_deps;
SELECT LOWER(LTRIM(RTRIM(from_qualified_name))) AS item_key,
    COUNT(*) AS source_count,
    (SELECT STRING_AGG(v.to_q, '; ') WITHIN GROUP (ORDER BY LOWER(v.to_q))
     FROM (SELECT DISTINCT to_qualified_name AS to_q FROM dbo.bronze_dependencies d2
           WHERE d2.relationship_type = 'depends_on' AND LOWER(LTRIM(RTRIM(d2.from_qualified_name))) = LOWER(LTRIM(RTRIM(d1.from_qualified_name)))) v
    ) AS source_dependencies
INTO #source_deps
FROM dbo.bronze_dependencies d1
WHERE relationship_type = 'depends_on' AND from_qualified_name <> ''
GROUP BY LOWER(LTRIM(RTRIM(from_qualified_name)));

IF OBJECT_ID('tempdb..#auto_objects') IS NOT NULL DROP TABLE #auto_objects;
SELECT item_key, SUM(cnt) AS auto_object_count
INTO #auto_objects
FROM (
    SELECT LOWER(LTRIM(RTRIM(semantic_model_qualified_name))) AS item_key, COUNT(*) AS cnt
    FROM dbo.bronze_semantic_model_view_candidates
    WHERE semantic_model_qualified_name <> '' AND object_name <> ''
    GROUP BY LOWER(LTRIM(RTRIM(semantic_model_qualified_name)))
    UNION ALL
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, COUNT(*) AS cnt
    FROM dbo.bronze_item_object_lineage_candidates
    WHERE item_qualified_name <> '' AND object_name <> ''
    GROUP BY LOWER(LTRIM(RTRIM(item_qualified_name)))
    UNION ALL
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, COUNT(*) AS cnt
    FROM dbo.bronze_pipeline_object_lineage_candidates
    WHERE item_qualified_name <> '' AND object_name <> ''
    GROUP BY LOWER(LTRIM(RTRIM(item_qualified_name)))
) u
GROUP BY item_key;

IF OBJECT_ID('tempdb..#manual_objects') IS NOT NULL DROP TABLE #manual_objects;
SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, COUNT(*) AS manual_object_count
INTO #manual_objects
FROM dbo.bronze_manual_lineage_object_evidence
WHERE item_qualified_name <> '' AND object_name <> ''
GROUP BY LOWER(LTRIM(RTRIM(item_qualified_name)));

IF OBJECT_ID('tempdb..#duration_final') IS NOT NULL DROP TABLE #duration_final;
SELECT item_key, avg_duration_seconds, max_duration_seconds, failed_count
INTO #duration_final
FROM (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key,
        ISNULL(TRY_CAST(REPLACE(avg_duration_seconds, ',', '.') AS FLOAT), 0) AS avg_duration_seconds,
        ISNULL(TRY_CAST(REPLACE(max_duration_seconds, ',', '.') AS FLOAT), 0) AS max_duration_seconds,
        ISNULL(TRY_CAST(failed_count AS INT), 0) AS failed_count,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_execution_duration_by_item
    WHERE qualified_name <> ''
) x
WHERE rn = 1;

IF OBJECT_ID('tempdb..#critical_set') IS NOT NULL DROP TABLE #critical_set;
SELECT DISTINCT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key INTO #critical_set FROM dbo.silver_critical_path_candidates;
IF OBJECT_ID('tempdb..#failure_set') IS NOT NULL DROP TABLE #failure_set;
SELECT DISTINCT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key INTO #failure_set FROM dbo.silver_failure_hotspots;

IF OBJECT_ID('tempdb..#queue') IS NOT NULL DROP TABLE #queue;
SELECT
    it.workspace_name, it.workspace_environment, it.item_type, it.item_name, it.qualified_name AS item_qualified_name,
    ISNULL(sd.source_count, 0) AS source_dependency_count,
    ISNULL(sd.source_dependencies, '') AS source_dependencies,
    ISNULL(ao.auto_object_count, 0) AS auto_object_evidence_count,
    ISNULL(mo.manual_object_count, 0) AS manual_object_evidence_count,
    ISNULL(ao.auto_object_count, 0) + ISNULL(mo.manual_object_count, 0) AS total_object_evidence_count,
    ISNULL(du.avg_duration_seconds, 0) AS avg_duration_seconds,
    ISNULL(du.max_duration_seconds, 0) AS max_duration_seconds,
    ISNULL(du.failed_count, 0) AS failed_count,
    CASE WHEN cs.item_key IS NOT NULL THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_critical_path_candidate,
    CASE WHEN fs.item_key IS NOT NULL THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS is_failure_hotspot,
    -- Deliberately the repo-relative path, not a faithful copy of the
    -- original's $ManualObjectEvidencePath -- that resolves (via
    -- PSScriptRoot) to an absolute local filesystem path specific to
    -- whichever machine ran the .ps1, which is meaningless from inside
    -- the Warehouse and wouldn't be reproducible across machines anyway.
    'index/manual_lineage_object_evidence.csv' AS manual_template_path,
    CASE
        WHEN ISNULL(mo.manual_object_count, 0) > 0 THEN 'manual_object_evidence_present'
        WHEN ISNULL(ao.auto_object_count, 0) > 0 THEN 'auto_object_evidence_present'
        WHEN ISNULL(sd.source_count, 0) > 0 THEN 'source_known_object_missing'
        ELSE 'source_missing_manual_review_required'
    END AS review_status,
    (
        CASE it.item_type WHEN 'Notebook' THEN 50 WHEN 'DataPipeline' THEN 50 WHEN 'CopyJob' THEN 45 WHEN 'SemanticModel' THEN 35 ELSE 0 END
        + CASE WHEN ISNULL(sd.source_count, 0) = 0 THEN 40 WHEN ISNULL(ao.auto_object_count, 0) + ISNULL(mo.manual_object_count, 0) = 0 THEN 30 ELSE 0 END
        + CASE WHEN cs.item_key IS NOT NULL THEN 20 ELSE 0 END
        + CASE WHEN fs.item_key IS NOT NULL THEN 20 ELSE 0 END
        + CASE WHEN it.workspace_environment = 'PRO' THEN 10 ELSE 0 END
        + CASE WHEN ISNULL(du.max_duration_seconds, 0) >= 1800 THEN 10 ELSE 0 END
        + CASE WHEN ISNULL(ao.auto_object_count, 0) + ISNULL(mo.manual_object_count, 0) > 0 THEN -20 ELSE 0 END
    ) AS priority_score,
    CASE it.item_type
        WHEN 'SemanticModel' THEN 'Open semantic model definition/Power Query/TMDL and record each SQL/Fabric table, view, or stored procedure used.'
        WHEN 'Notebook' THEN 'Open notebook, inspect default lakehouse and code cells for spark/sql/jdbc/odbc/table references, then record every table, view, or stored procedure used.'
        WHEN 'CopyJob' THEN 'Open CopyJob source/destination settings and mappings, then record source and target tables/views/files where available.'
        WHEN 'DataPipeline' THEN 'Open DataPipeline activities, inspect invoked items and copy/source/sink settings, then record each direct or inherited table, view, file, or stored procedure.'
        ELSE 'Review item manually and record object-level lineage evidence.'
    END AS review_action
INTO #queue
FROM dbo.bronze_items it
LEFT JOIN #source_deps sd ON sd.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN #auto_objects ao ON ao.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN #manual_objects mo ON mo.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN #duration_final du ON du.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN #critical_set cs ON cs.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN #failure_set fs ON fs.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
WHERE it.status = 'discovered' AND it.item_type IN ('SemanticModel', 'Notebook', 'CopyJob', 'DataPipeline');

SELECT
    CASE WHEN priority_score >= 90 THEN 'high' WHEN priority_score >= 60 THEN 'medium' ELSE 'low' END AS priority,
    priority_score, review_status, workspace_name, workspace_environment, item_type, item_name, item_qualified_name,
    source_dependency_count, source_dependencies, auto_object_evidence_count, manual_object_evidence_count,
    total_object_evidence_count, avg_duration_seconds, max_duration_seconds, failed_count,
    is_critical_path_candidate, is_failure_hotspot, manual_template_path, review_action
INTO dbo.silver_manual_lineage_review_queue
FROM #queue;

SELECT item_type, review_status, priority, COUNT(*) AS item_count
INTO dbo.silver_manual_lineage_review_summary
FROM dbo.silver_manual_lineage_review_queue
GROUP BY item_type, review_status, priority;

END
