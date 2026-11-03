-- Warehouse-native translation of backend/scripts/15_build_object_type_
-- resolution_queue.ps1 (Phase 2 migration continuation, 2026-07-21).
-- Reads dbo.bronze_semantic_model_view_candidates/item_object_lineage_
-- candidates/pipeline_object_lineage_candidates/manual_lineage_object_
-- evidence/source_object_type_overrides/source_object_type_metadata_
-- evidence/sql_endpoint_object_catalog. No SharePoint evidence source
-- exists yet in this project ($SharePointObjectTypeEvidencePath
-- defaults to "" in the original, so that tier is always empty --
-- reproduced here as a permanently-empty tier for the same reason).
--
-- Resolver priority chain: override > manual_review > (metadata_readonly
-- + sql_endpoint_catalog, same tier, metadata_readonly processed first)
-- > sharepoint_catalog; within each tier, an exact source_type match is
-- tried before a source_type-agnostic ("*") match. A tier registers BOTH
-- key variants per qualifying row; if two different object_types land on
-- the same (key, tier) pair, that entry becomes a conflict ('unknown',
-- excluded from matching) instead of silently picking one.
--
-- Column-name gotcha (found by reading the original's Get-FieldValue
-- calls against each source file's real header, not assumed): source_
-- object_type_metadata_evidence.csv's resolver name column is literally
-- named "resolver", not "reviewer" -- and sql_endpoint_object_catalog.csv
-- has no reviewer-ish column at all. Get-FieldValue only matches exact
-- column names, so both sources' resolver rows always get reviewer=''.
-- Reproduced verbatim (not "fixed") per this migration's faithful-
-- translation rule.
--
-- Normalize-Key/New-ObjectTypeKey matching uses LOWER(LTRIM(RTRIM(...)))
-- throughout, mirroring the original's own explicit Normalize-Key.
CREATE OR ALTER PROCEDURE dbo.sp_build_object_type_resolution_queue
AS
BEGIN

IF OBJECT_ID('dbo.silver_source_object_type_resolution_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_source_object_type_resolution_queue;
IF OBJECT_ID('dbo.silver_source_object_type_resolution_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_source_object_type_resolution_summary;

-- index/source_object_type_overrides.csv is a human-filled template,
-- currently header-only -- same "not yet uploaded" situation as
-- 14_build_manual_lineage_review_queue.sql's manual evidence table.
IF OBJECT_ID('dbo.bronze_source_object_type_overrides', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.bronze_source_object_type_overrides (
        source_type VARCHAR(100), source_server VARCHAR(400), source_database VARCHAR(400), schema_name VARCHAR(200),
        object_name VARCHAR(400), object_type VARCHAR(100), confidence VARCHAR(100), evidence VARCHAR(2000),
        reviewer VARCHAR(200), reviewed_at VARCHAR(100), notes VARCHAR(2000)
    );
END
IF OBJECT_ID('dbo.bronze_manual_lineage_object_evidence', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.bronze_manual_lineage_object_evidence (
        workspace_name VARCHAR(400), item_type VARCHAR(100), item_name VARCHAR(400), item_qualified_name VARCHAR(500),
        source_type VARCHAR(100), source_name VARCHAR(400), source_qualified_name VARCHAR(500), source_server VARCHAR(400),
        source_database VARCHAR(400), schema_name VARCHAR(200), object_name VARCHAR(400), object_type VARCHAR(100),
        usage_type VARCHAR(100), confidence VARCHAR(100), evidence VARCHAR(2000), reviewer VARCHAR(200), reviewed_at VARCHAR(100), notes VARCHAR(2000)
    );
END

-- ===========================================================================
-- Step 2: resolver evidence rows from all 4 tiers, each row registered
-- under BOTH its exact-source-type key and the source-type-agnostic
-- ("*") key -- only rows with an exact resolved object_type and at least
-- one of server/database/object qualify.
-- ===========================================================================
IF OBJECT_ID('tempdb..#resolver_src') IS NOT NULL DROP TABLE #resolver_src;
SELECT tier_priority, sub_order, source_label, key_exact, key_wild, object_type_norm, confidence, evidence, reviewer, reviewed_at
INTO #resolver_src
FROM (
    SELECT
        1 AS tier_priority, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS sub_order, 'override' AS source_label,
        LOWER(LTRIM(RTRIM(ISNULL(source_type,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(object_name,'')))) AS key_exact,
        '*|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(object_name,'')))) AS key_wild,
        no.object_type_norm, ISNULL(confidence,'') AS confidence, ISNULL(evidence,'') AS evidence, ISNULL(reviewer,'') AS reviewer, ISNULL(reviewed_at,'') AS reviewed_at
    FROM dbo.bronze_source_object_type_overrides r
    CROSS APPLY (
        SELECT CASE LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_'))
            WHEN 'storedprocedure' THEN 'stored_procedure'
            WHEN 'procedure' THEN 'stored_procedure'
            WHEN 'proc' THEN 'stored_procedure'
            WHEN 'sp' THEN 'stored_procedure'
            WHEN 'tbl' THEN 'table'
            ELSE LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_'))
        END AS object_type_norm
    ) no
    WHERE (ISNULL(source_server,'') <> '' OR ISNULL(source_database,'') <> '' OR ISNULL(object_name,'') <> '')
        AND no.object_type_norm IN ('table','view','stored_procedure','file','shortcut','query')

    UNION ALL
    SELECT
        3, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 'manual_review',
        LOWER(LTRIM(RTRIM(ISNULL(source_type,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(object_name,'')))),
        '*|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(object_name,'')))),
        no.object_type_norm, ISNULL(confidence,''), ISNULL(evidence,''), ISNULL(reviewer,''), ISNULL(reviewed_at,'')
    FROM dbo.bronze_manual_lineage_object_evidence r
    CROSS APPLY (
        SELECT CASE LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_'))
            WHEN 'storedprocedure' THEN 'stored_procedure'
            WHEN 'procedure' THEN 'stored_procedure'
            WHEN 'proc' THEN 'stored_procedure'
            WHEN 'sp' THEN 'stored_procedure'
            WHEN 'tbl' THEN 'table'
            ELSE LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_'))
        END AS object_type_norm
    ) no
    WHERE object_name <> ''
        AND (ISNULL(source_server,'') <> '' OR ISNULL(source_database,'') <> '' OR ISNULL(object_name,'') <> '')
        AND no.object_type_norm IN ('table','view','stored_procedure','file','shortcut','query')

    UNION ALL
    -- metadata_readonly: note reviewer always '' (no "reviewer" column in this file, see header comment)
    SELECT
        5, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 'metadata_readonly',
        LOWER(LTRIM(RTRIM(ISNULL(source_type,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(object_name,'')))),
        '*|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(object_name,'')))),
        no.object_type_norm, ISNULL(confidence,''), ISNULL(evidence,''), '', ISNULL(reviewed_at,'')
    FROM dbo.bronze_source_object_type_metadata_evidence r
    CROSS APPLY (
        SELECT CASE LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_'))
            WHEN 'storedprocedure' THEN 'stored_procedure'
            WHEN 'procedure' THEN 'stored_procedure'
            WHEN 'proc' THEN 'stored_procedure'
            WHEN 'sp' THEN 'stored_procedure'
            WHEN 'tbl' THEN 'table'
            ELSE LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_'))
        END AS object_type_norm
    ) no
    WHERE object_name <> ''
        AND (ISNULL(source_server,'') <> '' OR ISNULL(source_database,'') <> '' OR ISNULL(object_name,'') <> '')
        AND no.object_type_norm IN ('table','view','stored_procedure','file','shortcut','query')

    UNION ALL
    -- sql_endpoint_catalog: same tier as metadata_readonly, processed
    -- after it (higher sub_order); reviewer always '' (no such column);
    -- confidence falls back to object_type_confidence (no "confidence"
    -- column in this file).
    SELECT
        5, 1000000 + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), 'sql_endpoint_catalog',
        LOWER(LTRIM(RTRIM(ISNULL(source_type,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(object_name,'')))),
        '*|' + LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(object_name,'')))),
        no.object_type_norm, ISNULL(object_type_confidence,''), ISNULL(evidence,''), '', ISNULL(reviewed_at,'')
    FROM dbo.bronze_sql_endpoint_object_catalog r
    CROSS APPLY (
        SELECT CASE LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_'))
            WHEN 'storedprocedure' THEN 'stored_procedure'
            WHEN 'procedure' THEN 'stored_procedure'
            WHEN 'proc' THEN 'stored_procedure'
            WHEN 'sp' THEN 'stored_procedure'
            WHEN 'tbl' THEN 'table'
            ELSE LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_'))
        END AS object_type_norm
    ) no
    WHERE object_name <> '' AND (catalog_status = '' OR catalog_status = 'confirmed')
        AND (ISNULL(source_server,'') <> '' OR ISNULL(source_database,'') <> '' OR ISNULL(object_name,'') <> '')
        AND no.object_type_norm IN ('table','view','stored_procedure','file','shortcut','query')
) u;

-- Each source row contributes to BOTH its exact key and the wildcard key
-- (deduped when source_type was already blank, so both keys are equal).
IF OBJECT_ID('tempdb..#resolver_expanded') IS NOT NULL DROP TABLE #resolver_expanded;
SELECT DISTINCT key_text, tier_priority, sub_order, source_label, object_type_norm, confidence, evidence, reviewer, reviewed_at
INTO #resolver_expanded
FROM (
    SELECT key_exact AS key_text, tier_priority, sub_order, source_label, object_type_norm, confidence, evidence, reviewer, reviewed_at FROM #resolver_src
    UNION ALL
    SELECT key_wild, tier_priority, sub_order, source_label, object_type_norm, confidence, evidence, reviewer, reviewed_at FROM #resolver_src
) u;

-- Conflict check: same (key_text, tier) with 2+ distinct object_types
-- becomes 'unknown' and is excluded below (never matches a lookup).
IF OBJECT_ID('tempdb..#resolver_pool') IS NOT NULL DROP TABLE #resolver_pool;
;WITH agg AS (
    SELECT key_text, tier_priority, COUNT(DISTINCT object_type_norm) AS distinct_types
    FROM #resolver_expanded GROUP BY key_text, tier_priority
),
ranked AS (
    SELECT e.*, ROW_NUMBER() OVER (PARTITION BY e.key_text, e.tier_priority ORDER BY e.sub_order DESC) AS rn
    FROM #resolver_expanded e
)
SELECT r.key_text, r.tier_priority, r.object_type_norm, r.source_label, r.confidence, r.evidence, r.reviewer, r.reviewed_at
INTO #resolver_pool
FROM ranked r
JOIN agg a ON a.key_text = r.key_text AND a.tier_priority = r.tier_priority
WHERE r.rn = 1 AND a.distinct_types = 1;

-- ===========================================================================
-- Step 3: ambiguous candidate groups (table_or_view / native_query_object)
-- from semantic-model view candidates + item/pipeline object candidates.
-- ===========================================================================
IF OBJECT_ID('tempdb..#candidates') IS NOT NULL DROP TABLE #candidates;
SELECT source_type, source_server, source_database, schema_name, object_name, raw_object_type,
    workspace_name, model_name, item_type_val, semantic_table, definition_path, confidence
INTO #candidates
FROM (
    SELECT 'SQL' AS source_type, source_server, ISNULL(database_name, '') AS source_database, schema_name, object_name,
        no.object_type_norm AS raw_object_type,
        workspace_name, semantic_model_qualified_name AS model_name, 'SemanticModel' AS item_type_val,
        semantic_table, definition_path, confidence
    FROM dbo.bronze_semantic_model_view_candidates c
    CROSS APPLY (
        SELECT CASE LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_'))
            WHEN 'storedprocedure' THEN 'stored_procedure'
            WHEN 'procedure' THEN 'stored_procedure'
            WHEN 'proc' THEN 'stored_procedure'
            WHEN 'sp' THEN 'stored_procedure'
            WHEN 'tbl' THEN 'table'
            ELSE LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_'))
        END AS object_type_norm
    ) no
    WHERE object_name <> '' AND no.object_type_norm IN ('table_or_view', 'native_query_object')

    UNION ALL
    SELECT source_type, source_server, ISNULL(source_database, '') AS source_database, schema_name, object_name,
        no.object_type_norm,
        workspace_name, item_qualified_name, item_type,
        '' AS semantic_table, definition_path, confidence
    FROM dbo.bronze_item_object_lineage_candidates c
    CROSS APPLY (
        SELECT CASE LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_'))
            WHEN 'storedprocedure' THEN 'stored_procedure'
            WHEN 'procedure' THEN 'stored_procedure'
            WHEN 'proc' THEN 'stored_procedure'
            WHEN 'sp' THEN 'stored_procedure'
            WHEN 'tbl' THEN 'table'
            ELSE LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_'))
        END AS object_type_norm
    ) no
    WHERE object_name <> '' AND no.object_type_norm IN ('table_or_view', 'native_query_object')

    UNION ALL
    SELECT source_type, source_server, ISNULL(source_database, '') AS source_database, schema_name, object_name,
        no.object_type_norm,
        workspace_name, item_qualified_name, item_type,
        '' AS semantic_table, definition_path, confidence
    FROM dbo.bronze_pipeline_object_lineage_candidates c
    CROSS APPLY (
        SELECT CASE LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_'))
            WHEN 'storedprocedure' THEN 'stored_procedure'
            WHEN 'procedure' THEN 'stored_procedure'
            WHEN 'proc' THEN 'stored_procedure'
            WHEN 'sp' THEN 'stored_procedure'
            WHEN 'tbl' THEN 'table'
            ELSE LOWER(REPLACE(REPLACE(LTRIM(RTRIM(ISNULL(object_type,''))), ' ', '_'), '-', '_'))
        END AS object_type_norm
    ) no
    WHERE object_name <> '' AND no.object_type_norm IN ('table_or_view', 'native_query_object')
) u;

IF OBJECT_ID('tempdb..#groups') IS NOT NULL DROP TABLE #groups;
SELECT
    LOWER(LTRIM(RTRIM(source_type))) + '|' + LOWER(LTRIM(RTRIM(source_server))) + '|' + LOWER(LTRIM(RTRIM(source_database))) + '|' + LOWER(LTRIM(RTRIM(schema_name))) + '|' + LOWER(LTRIM(RTRIM(object_name))) + '|' + raw_object_type AS group_key,
    -- exact/wild lookup keys built from the GROUP's own representative
    -- source_type/server/database/schema/object (any member row's --
    -- they're identical case-INSENSITIVELY within a group by
    -- construction, since group_key itself is built from the LOWER()'d
    -- values; MAX() picks a display casing deterministically when
    -- source rows disagree on casing for "the same" server/database/
    -- object, same known limitation as the group_key collation gap
    -- elsewhere in this migration -- the original instead keeps
    -- whichever casing was on the LAST-processed source row, which
    -- needs file row order this Warehouse table doesn't carry).
    MAX(source_type) AS group_source_type, MAX(source_server) AS group_source_server, MAX(source_database) AS group_source_database,
    MAX(schema_name) AS group_schema_name, MAX(object_name) AS group_object_name, raw_object_type,
    COUNT(*) AS candidate_count
INTO #groups
FROM #candidates
GROUP BY LOWER(LTRIM(RTRIM(source_type))) + '|' + LOWER(LTRIM(RTRIM(source_server))) + '|' + LOWER(LTRIM(RTRIM(source_database))) + '|' + LOWER(LTRIM(RTRIM(schema_name))) + '|' + LOWER(LTRIM(RTRIM(object_name))) + '|' + raw_object_type, raw_object_type;

IF OBJECT_ID('tempdb..#group_sets') IS NOT NULL DROP TABLE #group_sets;
;WITH ws AS (
    SELECT g.group_key, ROW_NUMBER() OVER (PARTITION BY g.group_key ORDER BY LOWER(v.val)) AS rn, v.val
    FROM #groups g
    CROSS APPLY (SELECT DISTINCT workspace_name AS val FROM #candidates c2 WHERE LOWER(LTRIM(RTRIM(c2.source_type))) + '|' + LOWER(LTRIM(RTRIM(c2.source_server))) + '|' + LOWER(LTRIM(RTRIM(c2.source_database))) + '|' + LOWER(LTRIM(RTRIM(c2.schema_name))) + '|' + LOWER(LTRIM(RTRIM(c2.object_name))) + '|' + c2.raw_object_type = g.group_key AND c2.workspace_name <> '') v
),
ws_agg AS (SELECT group_key, STRING_AGG(val, '; ') WITHIN GROUP (ORDER BY LOWER(val)) AS workspaces FROM ws GROUP BY group_key),
md AS (
    SELECT DISTINCT g.group_key, v.val
    FROM #groups g
    CROSS APPLY (SELECT DISTINCT model_name AS val FROM #candidates c2 WHERE LOWER(LTRIM(RTRIM(c2.source_type))) + '|' + LOWER(LTRIM(RTRIM(c2.source_server))) + '|' + LOWER(LTRIM(RTRIM(c2.source_database))) + '|' + LOWER(LTRIM(RTRIM(c2.schema_name))) + '|' + LOWER(LTRIM(RTRIM(c2.object_name))) + '|' + c2.raw_object_type = g.group_key AND c2.model_name <> '') v
),
md_ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY group_key ORDER BY LOWER(val)) AS rn FROM md),
md_count AS (SELECT group_key, COUNT(*) AS model_count FROM md GROUP BY group_key),
md_agg AS (SELECT group_key, STRING_AGG(val, '; ') WITHIN GROUP (ORDER BY rn) AS models FROM md_ranked WHERE rn <= 12 GROUP BY group_key),
it AS (
    SELECT DISTINCT g.group_key, v.val
    FROM #groups g
    CROSS APPLY (SELECT DISTINCT item_type_val AS val FROM #candidates c2 WHERE LOWER(LTRIM(RTRIM(c2.source_type))) + '|' + LOWER(LTRIM(RTRIM(c2.source_server))) + '|' + LOWER(LTRIM(RTRIM(c2.source_database))) + '|' + LOWER(LTRIM(RTRIM(c2.schema_name))) + '|' + LOWER(LTRIM(RTRIM(c2.object_name))) + '|' + c2.raw_object_type = g.group_key AND c2.item_type_val <> '') v
),
it_agg AS (SELECT group_key, STRING_AGG(val, '; ') WITHIN GROUP (ORDER BY LOWER(val)) AS item_types FROM it GROUP BY group_key),
st AS (
    SELECT DISTINCT g.group_key, v.val, ROW_NUMBER() OVER (PARTITION BY g.group_key ORDER BY LOWER(v.val)) AS rn
    FROM #groups g
    CROSS APPLY (SELECT DISTINCT semantic_table AS val FROM #candidates c2 WHERE LOWER(LTRIM(RTRIM(c2.source_type))) + '|' + LOWER(LTRIM(RTRIM(c2.source_server))) + '|' + LOWER(LTRIM(RTRIM(c2.source_database))) + '|' + LOWER(LTRIM(RTRIM(c2.schema_name))) + '|' + LOWER(LTRIM(RTRIM(c2.object_name))) + '|' + c2.raw_object_type = g.group_key AND c2.semantic_table <> '') v
),
st_agg AS (SELECT group_key, STRING_AGG(val, '; ') WITHIN GROUP (ORDER BY rn) AS semantic_tables FROM st WHERE rn <= 20 GROUP BY group_key),
dp AS (
    SELECT DISTINCT g.group_key, v.val, ROW_NUMBER() OVER (PARTITION BY g.group_key ORDER BY LOWER(v.val)) AS rn
    FROM #groups g
    CROSS APPLY (SELECT DISTINCT definition_path AS val FROM #candidates c2 WHERE LOWER(LTRIM(RTRIM(c2.source_type))) + '|' + LOWER(LTRIM(RTRIM(c2.source_server))) + '|' + LOWER(LTRIM(RTRIM(c2.source_database))) + '|' + LOWER(LTRIM(RTRIM(c2.schema_name))) + '|' + LOWER(LTRIM(RTRIM(c2.object_name))) + '|' + c2.raw_object_type = g.group_key AND c2.definition_path <> '') v
),
dp_agg AS (SELECT group_key, STRING_AGG(val, '; ') WITHIN GROUP (ORDER BY rn) AS definition_paths FROM dp WHERE rn <= 20 GROUP BY group_key),
cf AS (
    SELECT DISTINCT g.group_key, v.val
    FROM #groups g
    CROSS APPLY (SELECT DISTINCT confidence AS val FROM #candidates c2 WHERE LOWER(LTRIM(RTRIM(c2.source_type))) + '|' + LOWER(LTRIM(RTRIM(c2.source_server))) + '|' + LOWER(LTRIM(RTRIM(c2.source_database))) + '|' + LOWER(LTRIM(RTRIM(c2.schema_name))) + '|' + LOWER(LTRIM(RTRIM(c2.object_name))) + '|' + c2.raw_object_type = g.group_key AND c2.confidence <> '') v
),
cf_agg AS (SELECT group_key, STRING_AGG(val, '; ') WITHIN GROUP (ORDER BY LOWER(val)) AS confidences FROM cf GROUP BY group_key)
SELECT g.*,
    ISNULL(ws_agg.workspaces, '') AS workspaces,
    ISNULL(md_agg.models, '') AS models,
    ISNULL(md_count.model_count, 0) AS model_count,
    ISNULL(it_agg.item_types, '') AS item_types,
    ISNULL(st_agg.semantic_tables, '') AS semantic_tables,
    ISNULL(dp_agg.definition_paths, '') AS definition_paths,
    ISNULL(cf_agg.confidences, '') AS confidences
INTO #group_sets
FROM #groups g
LEFT JOIN ws_agg ON ws_agg.group_key = g.group_key
LEFT JOIN md_agg ON md_agg.group_key = g.group_key
LEFT JOIN md_count ON md_count.group_key = g.group_key
LEFT JOIN it_agg ON it_agg.group_key = g.group_key
LEFT JOIN st_agg ON st_agg.group_key = g.group_key
LEFT JOIN dp_agg ON dp_agg.group_key = g.group_key
LEFT JOIN cf_agg ON cf_agg.group_key = g.group_key;

-- ===========================================================================
-- Step 4: resolve each group against the resolver pool (exact-type key
-- first, then wildcard key, in tier-priority order), or fall back.
-- ===========================================================================
IF OBJECT_ID('tempdb..#resolved') IS NOT NULL DROP TABLE #resolved;
;WITH lookup AS (
    SELECT gs.group_key,
        LOWER(LTRIM(RTRIM(gs.group_source_type))) + '|' + LOWER(LTRIM(RTRIM(gs.group_source_server))) + '|' + LOWER(LTRIM(RTRIM(gs.group_source_database))) + '|' + LOWER(LTRIM(RTRIM(gs.group_schema_name))) + '|' + LOWER(LTRIM(RTRIM(gs.group_object_name))) AS exact_key,
        '*|' + LOWER(LTRIM(RTRIM(gs.group_source_server))) + '|' + LOWER(LTRIM(RTRIM(gs.group_source_database))) + '|' + LOWER(LTRIM(RTRIM(gs.group_schema_name))) + '|' + LOWER(LTRIM(RTRIM(gs.group_object_name))) AS wild_key
    FROM #group_sets gs
),
matches AS (
    SELECT l.group_key, p.object_type_norm, p.source_label, p.confidence, p.evidence, p.reviewer, p.reviewed_at,
        p.tier_priority, CASE WHEN p.key_text = l.exact_key THEN 0 ELSE 1 END AS key_rank
    FROM lookup l
    JOIN #resolver_pool p ON p.key_text IN (l.exact_key, l.wild_key)
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY group_key ORDER BY tier_priority, key_rank) AS rn
    FROM matches
)
SELECT gs.*,
    CASE WHEN r.group_key IS NOT NULL THEN 1 ELSE 0 END AS resolved,
    r.object_type_norm AS resolved_object_type_raw,
    CASE WHEN r.group_key IS NOT NULL THEN r.source_label
         WHEN gs.raw_object_type = 'table_or_view' THEN 'tmdl_lookup_pending'
         ELSE 'native_query_pending' END AS resolver_source,
    CASE WHEN r.group_key IS NOT NULL THEN r.confidence
         WHEN gs.raw_object_type = 'table_or_view' THEN 'confirmed'
         ELSE 'likely' END AS resolver_confidence,
    CASE WHEN r.group_key IS NOT NULL THEN r.evidence
         WHEN gs.raw_object_type = 'table_or_view' THEN 'TMDL Schema/Item confirms the object name but not whether the SQL object is a table or view.'
         ELSE 'Native query parsing found an object reference, but the exact SQL object type requires metadata review.' END AS resolver_evidence
INTO #resolved
FROM #group_sets gs
LEFT JOIN ranked r ON r.group_key = gs.group_key AND r.rn = 1;

-- ===========================================================================
-- Step 5: final queue + summary.
-- ===========================================================================
SELECT
    CASE WHEN resolved = 1 THEN 'resolved' ELSE 'needs_metadata_review' END AS status,
    (model_count * 10) + candidate_count
        + CASE WHEN resolved = 0 THEN 50 ELSE 0 END
        + CASE WHEN raw_object_type = 'table_or_view' THEN 20 ELSE 0 END AS priority_score,
    group_source_type AS source_type, group_source_server AS source_server, group_source_database AS source_database,
    group_schema_name AS schema_name, group_object_name AS object_name, raw_object_type,
    CASE WHEN resolved = 1 THEN resolved_object_type_raw ELSE '' END AS resolved_object_type,
    resolver_source, resolver_confidence, resolver_evidence,
    model_count AS semantic_model_count, model_count AS affected_item_count, item_types AS affected_item_types,
    candidate_count, workspaces, models AS semantic_models, models AS affected_items, semantic_tables, definition_paths, confidences AS confidence,
    CASE
        WHEN resolved = 1 THEN 'No action needed unless the resolution evidence changes.'
        WHEN raw_object_type = 'table_or_view' THEN 'Confirm from SQL/Fabric metadata whether this object is a table or a view; capture metadata evidence automatically or add an approved manual override.'
        ELSE 'Review the native query or source metadata, confirm table/view/stored_procedure, then capture metadata evidence or add an approved manual override.'
    END AS next_step
INTO dbo.silver_source_object_type_resolution_queue
FROM #resolved;

SELECT status, raw_object_type, resolver_source, COUNT(*) AS object_count, SUM(candidate_count) AS candidate_count,
    (SELECT COUNT(DISTINCT val) FROM (
        SELECT value AS val FROM dbo.silver_source_object_type_resolution_queue q2
        CROSS APPLY STRING_SPLIT(q2.semantic_models, ';') s
        WHERE q2.status = q.status AND q2.raw_object_type = q.raw_object_type AND q2.resolver_source = q.resolver_source AND LTRIM(RTRIM(value)) <> ''
    ) x) AS semantic_model_count
INTO dbo.silver_source_object_type_resolution_summary
FROM dbo.silver_source_object_type_resolution_queue q
GROUP BY status, raw_object_type, resolver_source;

END
