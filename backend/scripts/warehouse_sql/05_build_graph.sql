-- Warehouse-native translation of backend/scripts/05_build_graph.ps1
-- (SQL migration). Reads dbo.bronze_workspaces,
-- dbo.bronze_items, dbo.bronze_dependencies, dbo.bronze_item_analysis, and
-- dbo.bronze_graph_nodes (05's own prior output, mirrored to bronze, for
-- ExternalConnection retention across runs). No recursion needed -- this
-- script only assembles/dedupes nodes+edges and computes degree counts,
-- all plain set operations. The Mermaid diagram and index/unresolved.md
-- entry stay app-layer (not data).
CREATE OR ALTER PROCEDURE dbo.sp_build_graph
AS
BEGIN

IF OBJECT_ID('dbo.silver_graph_nodes', 'U') IS NOT NULL DROP TABLE dbo.silver_graph_nodes;
IF OBJECT_ID('dbo.silver_graph_edges', 'U') IS NOT NULL DROP TABLE dbo.silver_graph_edges;
IF OBJECT_ID('dbo.silver_graph_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_graph_summary;
IF OBJECT_ID('dbo.silver_graph_validation', 'U') IS NOT NULL DROP TABLE dbo.silver_graph_validation;
IF OBJECT_ID('dbo.silver_top_graph_nodes', 'U') IS NOT NULL DROP TABLE dbo.silver_top_graph_nodes;

;WITH workspace_nodes AS (
    SELECT 1 AS prio, workspace_name AS qualified_name, workspace_name AS display_name, workspace_name AS ws_name,
        'Workspace' AS item_type, 'Workspace' AS object_type, source_system, technical_id, status,
        'Environment: ' + environment + '; Normalized name: ' + normalized_workspace_name AS notes
    FROM dbo.bronze_workspaces
    WHERE workspace_name <> ''
),
item_nodes AS (
    SELECT 2 AS prio, qualified_name, item_name AS display_name, workspace_name AS ws_name,
        item_type, 'Item' AS object_type, source_system, technical_id, status,
        'Environment: ' + workspace_environment + '; Folder ID: ' + folder_id AS notes
    FROM dbo.bronze_items
    WHERE status = 'discovered' AND qualified_name <> ''
),
existing_external_nodes AS (
    SELECT 3 AS prio, qualified_name, display_name, workspace_name AS ws_name, item_type, object_type,
        source_system, technical_id, status, notes
    FROM dbo.bronze_graph_nodes
    WHERE item_type = 'ExternalConnection' AND qualified_name <> ''
),
dependency_endpoints AS (
    SELECT from_qualified_name AS endpoint FROM dbo.bronze_dependencies WHERE from_qualified_name LIKE 'External Connection / %'
    UNION
    SELECT to_qualified_name FROM dbo.bronze_dependencies WHERE to_qualified_name LIKE 'External Connection / %'
),
derived_external_nodes AS (
    SELECT 4 AS prio, endpoint AS qualified_name,
        RIGHT(endpoint, CHARINDEX(' / ', REVERSE(endpoint)) - 1) AS display_name,
        'External' AS ws_name, 'ExternalConnection' AS item_type, 'ExternalConnection' AS object_type,
        'Local graph build from indexed dependencies' AS source_system, '' AS technical_id, 'inferred' AS status,
        'Created from dependency endpoint during Phase 5 graph build.' AS notes
    FROM dependency_endpoints
),
all_node_candidates AS (
    SELECT * FROM workspace_nodes
    UNION ALL SELECT * FROM item_nodes
    UNION ALL SELECT * FROM existing_external_nodes
    UNION ALL SELECT * FROM derived_external_nodes
),
node_ranked AS (
    -- PARTITION BY LOWER(...), not the raw column: PowerShell's $NodeMap is
    -- a plain hashtable, whose default string-key comparer is ordinal
    -- CASE-INSENSITIVE -- unlike Fabric Warehouse's own default database
    -- collation (Latin1_General_100_BIN2_UTF8, confirmed live:
    -- 'abc' = 'ABC' is false), which is case-SENSITIVE binary. Without this,
    -- two qualified_names differing only by case (a real one exists in this
    -- tenant's data, e.g. mixed-case vs all-lowercase variants of the same
    -- database name) silently produce ONE MORE node here than the real
    -- PowerShell output. Applies
    -- everywhere below that mirrors a PowerShell hashtable/dictionary key.
    SELECT *, ROW_NUMBER() OVER (PARTITION BY LOWER(qualified_name) ORDER BY prio) AS rn
    FROM all_node_candidates
)
SELECT
    qualified_name, display_name, ws_name AS workspace_name, item_type, object_type, source_system,
    technical_id, status,
    CASE WHEN LEN(notes) > 800 THEN LEFT(notes, 797) + '...' ELSE notes END AS notes
INTO dbo.silver_graph_nodes
FROM node_ranked
WHERE rn = 1;

;WITH contains_edges AS (
    SELECT 1 AS prio, workspace_name AS from_qualified_name, qualified_name AS to_qualified_name, 'contains' AS relationship_type,
        'Local graph build from indexed inventory' AS source_system,
        'Workspace contains item in index/items.csv.' AS evidence, 'confirmed' AS confidence,
        'Structural containment edge added in Phase 5.' AS notes
    FROM dbo.bronze_items
    WHERE status = 'discovered' AND workspace_name <> '' AND qualified_name <> ''
),
dep_edges AS (
    SELECT 2 AS prio, from_qualified_name, to_qualified_name, relationship_type, source_system, evidence, confidence, notes
    FROM dbo.bronze_dependencies
    WHERE from_qualified_name <> '' AND to_qualified_name <> '' AND relationship_type <> ''
),
all_edges AS (
    SELECT * FROM contains_edges
    UNION ALL SELECT * FROM dep_edges
),
edge_ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY LOWER(from_qualified_name), LOWER(to_qualified_name), LOWER(relationship_type) ORDER BY prio) AS rn
    FROM all_edges
)
SELECT
    from_qualified_name, to_qualified_name, relationship_type, source_system,
    CASE WHEN LEN(evidence) > 800 THEN LEFT(evidence, 797) + '...' ELSE evidence END AS evidence,
    confidence,
    CASE WHEN LEN(notes) > 800 THEN LEFT(notes, 797) + '...' ELSE notes END AS notes
INTO dbo.silver_graph_edges
FROM edge_ranked
WHERE rn = 1;

;WITH outgoing_counts AS (
    SELECT LOWER(from_qualified_name) AS qualified_name_key, COUNT(*) AS outgoing FROM dbo.silver_graph_edges GROUP BY LOWER(from_qualified_name)
),
incoming_counts AS (
    SELECT LOWER(to_qualified_name) AS qualified_name_key, COUNT(*) AS incoming FROM dbo.silver_graph_edges GROUP BY LOWER(to_qualified_name)
),
degrees AS (
    SELECT n.qualified_name, n.display_name, n.workspace_name, n.item_type, n.object_type,
        ISNULL(ic.incoming, 0) AS incoming_edges, ISNULL(oc.outgoing, 0) AS outgoing_edges
    FROM dbo.silver_graph_nodes n
    LEFT JOIN incoming_counts ic ON ic.qualified_name_key = LOWER(n.qualified_name)
    LEFT JOIN outgoing_counts oc ON oc.qualified_name_key = LOWER(n.qualified_name)
)
SELECT qualified_name, display_name, workspace_name, item_type, object_type, incoming_edges, outgoing_edges,
    incoming_edges + outgoing_edges AS total_edges
INTO dbo.silver_top_graph_nodes_full
FROM degrees;

SELECT TOP 100 qualified_name, display_name, workspace_name, item_type, object_type, incoming_edges, outgoing_edges, total_edges
INTO dbo.silver_top_graph_nodes
FROM dbo.silver_top_graph_nodes_full
ORDER BY total_edges DESC, outgoing_edges DESC, incoming_edges DESC;

SELECT e.* INTO #missing_source FROM dbo.silver_graph_edges e
LEFT JOIN dbo.silver_graph_nodes n ON LOWER(n.qualified_name) = LOWER(e.from_qualified_name)
WHERE n.qualified_name IS NULL;

SELECT e.* INTO #missing_target FROM dbo.silver_graph_edges e
LEFT JOIN dbo.silver_graph_nodes n ON LOWER(n.qualified_name) = LOWER(e.to_qualified_name)
WHERE n.qualified_name IS NULL;

-- Always 0 by construction (dbo.silver_graph_nodes was already deduped
-- case-insensitively above) -- kept as a real query, not hardcoded, so it
-- still catches a genuine regression if that dedup step is ever changed.
-- MAX(qualified_name), not the bare column: SQL Server requires every
-- non-grouped SELECT column to be wrapped in an aggregate when GROUP BY
-- uses an expression (LOWER(...)) rather than the raw column itself.
SELECT MAX(qualified_name) AS qualified_name, COUNT(*) AS cnt INTO #dup_nodes FROM dbo.silver_graph_nodes GROUP BY LOWER(qualified_name) HAVING COUNT(*) > 1;

SELECT MAX(from_qualified_name) AS from_qualified_name, MAX(to_qualified_name) AS to_qualified_name, MAX(relationship_type) AS relationship_type, COUNT(*) AS cnt INTO #dup_edges
FROM dbo.silver_graph_edges GROUP BY LOWER(from_qualified_name), LOWER(to_qualified_name), LOWER(relationship_type) HAVING COUNT(*) > 1;

SELECT qualified_name INTO #isolated FROM dbo.silver_top_graph_nodes_full WHERE incoming_edges = 0 AND outgoing_edges = 0;

SELECT metric, value, notes INTO dbo.silver_graph_summary FROM (
    SELECT 'workspace_nodes' AS metric, CAST(COUNT(*) AS VARCHAR(20)) AS value, '' AS notes FROM dbo.silver_graph_nodes WHERE item_type = 'Workspace'
    UNION ALL SELECT 'item_nodes', CAST(COUNT(*) AS VARCHAR(20)), '' FROM dbo.silver_graph_nodes WHERE object_type = 'Item'
    UNION ALL SELECT 'external_connection_nodes', CAST(COUNT(*) AS VARCHAR(20)), '' FROM dbo.silver_graph_nodes WHERE item_type = 'ExternalConnection'
    UNION ALL SELECT 'total_nodes', CAST(COUNT(*) AS VARCHAR(20)), '' FROM dbo.silver_graph_nodes
    UNION ALL SELECT 'contains_edges', CAST(COUNT(*) AS VARCHAR(20)), '' FROM dbo.silver_graph_edges WHERE relationship_type = 'contains'
    UNION ALL SELECT 'dependency_edges', CAST(COUNT(*) AS VARCHAR(20)), '' FROM dbo.silver_graph_edges WHERE relationship_type <> 'contains'
    UNION ALL SELECT 'total_edges', CAST(COUNT(*) AS VARCHAR(20)), '' FROM dbo.silver_graph_edges
    UNION ALL SELECT 'confirmed_dependency_edges', CAST(COUNT(*) AS VARCHAR(20)), '' FROM dbo.silver_graph_edges WHERE relationship_type <> 'contains' AND confidence = 'confirmed'
    UNION ALL SELECT 'likely_dependency_edges', CAST(COUNT(*) AS VARCHAR(20)), '' FROM dbo.silver_graph_edges WHERE relationship_type <> 'contains' AND confidence = 'likely'
    UNION ALL SELECT 'missing_source_edges', CAST(COUNT(*) AS VARCHAR(20)), '' FROM #missing_source
    UNION ALL SELECT 'missing_target_edges', CAST(COUNT(*) AS VARCHAR(20)), '' FROM #missing_target
    UNION ALL SELECT 'duplicate_node_names', CAST(COUNT(*) AS VARCHAR(20)), '' FROM #dup_nodes
    UNION ALL SELECT 'duplicate_edge_keys', CAST(COUNT(*) AS VARCHAR(20)), '' FROM #dup_edges
    UNION ALL SELECT 'isolated_nodes', CAST(COUNT(*) AS VARCHAR(20)), 'Nodes with zero incoming and zero outgoing edges after structural contains edges.' FROM #isolated
) s;

;WITH ms_top5 AS (SELECT TOP 5 from_qualified_name FROM #missing_source),
ms_agg AS (SELECT STRING_AGG(from_qualified_name, '; ') WITHIN GROUP (ORDER BY from_qualified_name) AS details FROM ms_top5),
mt_top5 AS (SELECT TOP 5 to_qualified_name FROM #missing_target),
mt_agg AS (SELECT STRING_AGG(to_qualified_name, '; ') WITHIN GROUP (ORDER BY to_qualified_name) AS details FROM mt_top5),
dn_top5 AS (SELECT TOP 5 qualified_name FROM #dup_nodes),
dn_agg AS (SELECT STRING_AGG(qualified_name, '; ') WITHIN GROUP (ORDER BY qualified_name) AS details FROM dn_top5),
de_top5 AS (SELECT TOP 5 from_qualified_name + ', ' + to_qualified_name + ', ' + relationship_type AS grp FROM #dup_edges),
de_agg AS (SELECT STRING_AGG(grp, '; ') WITHIN GROUP (ORDER BY grp) AS details FROM de_top5),
is_top5 AS (SELECT TOP 5 qualified_name FROM #isolated),
is_agg AS (SELECT STRING_AGG(qualified_name, '; ') WITHIN GROUP (ORDER BY qualified_name) AS details FROM is_top5)
SELECT check_name, status, count, details INTO dbo.silver_graph_validation FROM (
    SELECT 'missing_source_edges' AS check_name, CASE WHEN (SELECT COUNT(*) FROM #missing_source) = 0 THEN 'pass' ELSE 'fail' END AS status,
        (SELECT COUNT(*) FROM #missing_source) AS count, ISNULL((SELECT details FROM ms_agg), '') AS details
    UNION ALL
    SELECT 'missing_target_edges', CASE WHEN (SELECT COUNT(*) FROM #missing_target) = 0 THEN 'pass' ELSE 'fail' END,
        (SELECT COUNT(*) FROM #missing_target), ISNULL((SELECT details FROM mt_agg), '')
    UNION ALL
    SELECT 'duplicate_node_names', CASE WHEN (SELECT COUNT(*) FROM #dup_nodes) = 0 THEN 'pass' ELSE 'fail' END,
        (SELECT COUNT(*) FROM #dup_nodes), ISNULL((SELECT details FROM dn_agg), '')
    UNION ALL
    SELECT 'duplicate_edge_keys', CASE WHEN (SELECT COUNT(*) FROM #dup_edges) = 0 THEN 'pass' ELSE 'fail' END,
        (SELECT COUNT(*) FROM #dup_edges), ISNULL((SELECT details FROM de_agg), '')
    UNION ALL
    SELECT 'isolated_nodes', 'info', (SELECT COUNT(*) FROM #isolated), ISNULL((SELECT details FROM is_agg), '')
) v;

DROP TABLE #missing_source;
DROP TABLE #missing_target;
DROP TABLE #dup_nodes;
DROP TABLE #dup_edges;
DROP TABLE #isolated;
DROP TABLE dbo.silver_top_graph_nodes_full;

END
