-- Warehouse-native translation of backend/scripts/47_build_deep_
-- evidence_sweep_plan.ps1 (Phase 2 migration continuation, 2026-07-21).
-- Reads dbo.bronze_items, dbo.bronze_dependencies, dbo.silver_object_
-- read_write_classification (23), dbo.bronze_semantic_model_view_
-- candidates, dbo.bronze_semantic_model_definition_gaps, dbo.bronze_
-- item_object_lineage_gaps, dbo.silver_d1_closure_control_queue,
-- dbo.silver_d3_item_closure_control_queue, dbo.silver_d4_exact_
-- object_type_source_queue (29), dbo.silver_d8_parallel_candidate_
-- retest_queue (46), dbo.bronze_source_object_type_metadata_evidence,
-- dbo.bronze_sql_endpoint_object_catalog.
-- NOT migrated: local_definition_paths always exports blank here. The
-- original scans the LOCAL FILESYSTEM (.tmp/, _fabric_exports/ for
-- notebook-content.ipynb) for that field -- a machine-local, point-in-
-- time directory listing with no equivalent in warehouse data, and
-- fundamentally out of reach for a server-side stored procedure.
-- D4/metadata/catalog object-key matching replicates the original's
-- dual exact+wildcard (server/db/schema/object regardless of type)
-- hashtable lookup, INCLUDING its double-count quirk on linked_d4_
-- source_ids' count (an exact-type match is counted via both the exact
-- key and the wildcard key, since the exact-matching row is also
-- indexed under its own wildcard key) -- faithfully reproduced since
-- it's a deterministic property of the original algorithm, not a
-- locale/environment accident like the bugs fixed in 25/31.
-- sql_object_metadata_queue's target ordering has no reproducible
-- source (built from a plain hashtable's .Keys enumeration order in the
-- original, never sorted) -- tie-broken by LOWER() here per this
-- migration's established convention.
-- Real bug found and fixed during validation (2026-07-21): Get-FieldValue
-- -Names @("A","B") only falls back to B when A's PROPERTY is missing or
-- null -- for CSV-sourced rows every column always exists (blank string,
-- never null), so whenever BOTH A and B are real columns of the SAME
-- source table (schema_name/metadata_schema_name, object_name/metadata_
-- object_name, notes/error, raw_object_type/object_type, object_type/
-- metadata_type_desc), the original ALWAYS uses A verbatim and NEVER
-- falls back to B, even when A is blank. The first draft of this
-- procedure mistranslated these as ISNULL(NULLIF(a,''), b) (fallback on
-- blank), which is wrong; confirmed by direct query (a metadata-evidence
-- row with schema_name='' but metadata_schema_name='dbo' matched PS's
-- blank-schema query key exactly, but my ISNULL/NULLIF version silently
-- substituted 'dbo' and missed the match). Fixed to plain ISNULL(a,'').
-- Validated 2026-07-21 (post-fix): notebook/semantic/sql-metadata queues
-- all 0 missing/extra vs the fresh local baseline; metadata_status and
-- existing_metadata_types diffs went to 0 after the fix above. Remaining
-- diffs are the session's already-documented classes: opaque D1/D3/D8 ID
-- text (content-linkage confirmed correct), first-occurrence-among-
-- duplicate-candidate-rows casing (e.g. object_name 'CONVOCATORIA' vs
-- 'convocatoria', same class as script 38), and punctuation-driven
-- culture-vs-ordinal sort order for "sample" list fields. The 279-row
-- likely_resolution_targets table's 34 missing/extra rows are a
-- downstream artifact of that same tie-break class landing exactly on
-- the TOP-80/TOP-120 cutoff boundary -- confirmed directly: 15+ SQL
-- metadata candidates share the identical priority_score (127) at the
-- TOP-120 cutoff.
CREATE OR ALTER PROCEDURE dbo.sp_build_deep_evidence_sweep_plan
AS
BEGIN

IF OBJECT_ID('dbo.silver_e1_deep_evidence_scope_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_e1_deep_evidence_scope_summary;
IF OBJECT_ID('dbo.silver_e1_notebook_code_review_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_e1_notebook_code_review_queue;
IF OBJECT_ID('dbo.silver_e1_semantic_model_review_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_e1_semantic_model_review_queue;
IF OBJECT_ID('dbo.silver_e1_sql_object_metadata_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_e1_sql_object_metadata_queue;
IF OBJECT_ID('dbo.silver_e1_likely_resolution_targets', 'U') IS NOT NULL DROP TABLE dbo.silver_e1_likely_resolution_targets;
IF OBJECT_ID('dbo.silver_e1_external_readonly_action_plan', 'U') IS NOT NULL DROP TABLE dbo.silver_e1_external_readonly_action_plan;

IF OBJECT_ID('tempdb..#rw') IS NOT NULL DROP TABLE #rw;
SELECT
    LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, item_qualified_name, item_type, ISNULL(operation_type,'') AS operation_type,
    LOWER(LTRIM(RTRIM(ISNULL(operation_type,'')))) AS operation_norm,
    LOWER(LTRIM(RTRIM(ISNULL(lineage_confidence,'')))) AS lineage_confidence_norm,
    LOWER(LTRIM(RTRIM(ISNULL(object_type_status,'')))) AS object_type_status_norm,
    ISNULL(object_key,'') AS object_key,
    LOWER(LTRIM(RTRIM(ISNULL(source_type,'')))) AS source_type_norm, LOWER(LTRIM(RTRIM(ISNULL(source_server,'')))) AS source_server_norm,
    LOWER(LTRIM(RTRIM(ISNULL(source_database,'')))) AS source_database_norm, LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) AS schema_name_norm,
    LOWER(LTRIM(RTRIM(ISNULL(object_name,'')))) AS object_name_norm,
    ISNULL(source_type,'') AS source_type, ISNULL(source_server,'') AS source_server, ISNULL(source_database,'') AS source_database,
    ISNULL(schema_name,'') AS schema_name, ISNULL(object_name,'') AS object_name, ISNULL(object_display_name,'') AS object_display_name,
    ISNULL(raw_object_type,'') AS raw_object_type_disp
INTO #rw
FROM dbo.silver_object_read_write_classification
WHERE ISNULL(item_qualified_name,'') <> '';

-- ===========================================================================
-- Notebook queue.
-- ===========================================================================
IF OBJECT_ID('tempdb..#item_rw_agg') IS NOT NULL DROP TABLE #item_rw_agg;
SELECT item_key, COUNT(*) AS object_row_count,
    SUM(CASE WHEN lineage_confidence_norm = 'likely' THEN 1 ELSE 0 END) AS likely_object_rows,
    SUM(CASE WHEN object_type_status_norm = 'ambiguous' THEN 1 ELSE 0 END) AS ambiguous_object_rows,
    SUM(CASE WHEN operation_norm = 'write' THEN 1 ELSE 0 END) AS write_object_rows,
    SUM(CASE WHEN operation_norm = 'unknown' OR operation_norm = '' THEN 1 ELSE 0 END) AS unknown_operation_rows
INTO #item_rw_agg
FROM #rw
GROUP BY item_key;

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

IF OBJECT_ID('tempdb..#item_d8_pairs') IS NOT NULL DROP TABLE #item_d8_pairs;
SELECT LOWER(LTRIM(RTRIM(candidate_a))) AS item_key, d8_id INTO #item_d8_pairs FROM dbo.silver_d8_parallel_candidate_retest_queue WHERE ISNULL(candidate_a,'') <> ''
UNION
SELECT LOWER(LTRIM(RTRIM(candidate_b))), d8_id FROM dbo.silver_d8_parallel_candidate_retest_queue WHERE ISNULL(candidate_b,'') <> '';

IF OBJECT_ID('tempdb..#item_d8_agg') IS NOT NULL DROP TABLE #item_d8_agg;
;WITH r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY LOWER(d8_id)) AS rn FROM #item_d8_pairs)
SELECT item_key, STRING_AGG(d8_id, '; ') WITHIN GROUP (ORDER BY rn) AS linked_d8_ids
INTO #item_d8_agg FROM r GROUP BY item_key;

IF OBJECT_ID('tempdb..#item_gap_agg') IS NOT NULL DROP TABLE #item_gap_agg;
;WITH d AS (SELECT DISTINCT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, ISNULL(notes,'') AS note_val FROM dbo.bronze_item_object_lineage_gaps),
d2 AS (SELECT item_key, note_val FROM d WHERE note_val <> ''),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY item_key ORDER BY LOWER(note_val)) AS rn FROM d2)
SELECT item_key, LEFT(STRING_AGG(note_val, '; ') WITHIN GROUP (ORDER BY rn), 900) AS gap_notes
INTO #item_gap_agg FROM r WHERE rn <= 4 GROUP BY item_key;

SELECT
    it.qualified_name AS item_qualified_name, it.workspace_name, ISNULL(it.workspace_environment,'') AS workspace_environment, it.item_name,
    (ISNULL(d1.cnt,0) * 40) + (ISNULL(d3.cnt,0) * 20) + (ISNULL(d8.cnt,0) * 10) + (ISNULL(rw.write_object_rows,0) * 2) + (ISNULL(rw.unknown_operation_rows,0) * 5) AS priority_score,
    (CASE WHEN (ISNULL(d1.cnt,0) * 40) + (ISNULL(d3.cnt,0) * 20) + (ISNULL(d8.cnt,0) * 10) + (ISNULL(rw.write_object_rows,0) * 2) + (ISNULL(rw.unknown_operation_rows,0) * 5) >= 85 THEN 'critical'
          WHEN (ISNULL(d1.cnt,0) * 40) + (ISNULL(d3.cnt,0) * 20) + (ISNULL(d8.cnt,0) * 10) + (ISNULL(rw.write_object_rows,0) * 2) + (ISNULL(rw.unknown_operation_rows,0) * 5) >= 75 THEN 'high'
          WHEN (ISNULL(d1.cnt,0) * 40) + (ISNULL(d3.cnt,0) * 20) + (ISNULL(d8.cnt,0) * 10) + (ISNULL(rw.write_object_rows,0) * 2) + (ISNULL(rw.unknown_operation_rows,0) * 5) >= 60 THEN 'medium'
          ELSE 'low' END) AS priority_band,
    (CASE WHEN ISNULL(d1.cnt,0) > 0 THEN 'needs_full_code_review_for_missing_objects'
          WHEN ISNULL(rw.likely_object_rows,0) > 0 OR ISNULL(rw.ambiguous_object_rows,0) > 0 THEN 'needs_code_confirmation'
          ELSE 'covered_by_current_local_evidence' END) AS review_status,
    ISNULL(rw.object_row_count,0) AS object_row_count, ISNULL(rw.likely_object_rows,0) AS likely_object_rows,
    ISNULL(rw.ambiguous_object_rows,0) AS ambiguous_object_rows, ISNULL(rw.write_object_rows,0) AS write_object_rows,
    ISNULL(rw.unknown_operation_rows,0) AS unknown_operation_rows,
    ISNULL(d1a.linked_d1_ids,'') AS linked_d1_ids, ISNULL(d3a.linked_d3_item_review_ids,'') AS linked_d3_item_review_ids,
    ISNULL(d8a.linked_d8_ids,'') AS linked_d8_ids,
    '' AS local_definition_paths,
    ISNULL(ga.gap_notes,'') AS gap_notes,
    'Export/read the notebook definition, parse SQL/Spark/OneLake/JDBC references, classify reads/writes/executes, and update manual lineage evidence or parser rules.' AS recommended_action
INTO dbo.silver_e1_notebook_code_review_queue
FROM dbo.bronze_items it
LEFT JOIN #item_rw_agg rw ON rw.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN (SELECT item_key, COUNT(*) AS cnt FROM (SELECT DISTINCT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, d1_id FROM dbo.silver_d1_closure_control_queue WHERE ISNULL(d1_id,'') <> '') x GROUP BY item_key) d1 ON d1.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN (SELECT item_key, COUNT(*) AS cnt FROM (SELECT DISTINCT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, item_review_id FROM dbo.silver_d3_item_closure_control_queue WHERE ISNULL(item_review_id,'') <> '') x GROUP BY item_key) d3 ON d3.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN (SELECT item_key, COUNT(*) AS cnt FROM (SELECT DISTINCT item_key, d8_id FROM #item_d8_pairs) x GROUP BY item_key) d8 ON d8.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN #item_d1_agg d1a ON d1a.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN #item_d3_agg d3a ON d3a.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN #item_d8_agg d8a ON d8a.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN #item_gap_agg ga ON ga.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
WHERE it.item_type = 'Notebook';

-- ===========================================================================
-- Semantic model queue.
-- ===========================================================================
IF OBJECT_ID('tempdb..#semantic_agg') IS NOT NULL DROP TABLE #semantic_agg;
SELECT LOWER(LTRIM(RTRIM(semantic_model_qualified_name))) AS model_key, COUNT(*) AS source_candidate_count,
    SUM(CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(confidence,'')))) = 'confirmed' THEN 1 ELSE 0 END) AS confirmed_source_count,
    SUM(CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(confidence,'')))) = 'likely' THEN 1 ELSE 0 END) AS likely_source_count,
    SUM(CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(object_type,'')))) = 'native_query_object' THEN 1 ELSE 0 END) AS native_query_count,
    SUM(CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(object_type,'')))) = 'stored_procedure' THEN 1 ELSE 0 END) AS stored_procedure_count,
    SUM(CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(object_type,'')))) = 'table_or_view' THEN 1 ELSE 0 END) AS table_or_view_count
INTO #semantic_agg
FROM dbo.bronze_semantic_model_view_candidates
WHERE ISNULL(semantic_model_qualified_name,'') <> ''
GROUP BY LOWER(LTRIM(RTRIM(semantic_model_qualified_name)));

IF OBJECT_ID('tempdb..#semantic_gap_agg') IS NOT NULL DROP TABLE #semantic_gap_agg;
;WITH d AS (SELECT DISTINCT LOWER(LTRIM(RTRIM(semantic_model_qualified_name))) AS model_key, ISNULL(notes,'') AS note_val FROM dbo.bronze_semantic_model_definition_gaps),
d2 AS (SELECT model_key, note_val FROM d WHERE note_val <> ''),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY model_key ORDER BY LOWER(note_val)) AS rn FROM d2)
SELECT model_key, LEFT(STRING_AGG(note_val, '; ') WITHIN GROUP (ORDER BY rn), 900) AS definition_gap_status, COUNT(*) OVER (PARTITION BY model_key) AS gap_count
INTO #semantic_gap_agg FROM r WHERE rn <= 4 GROUP BY model_key;

IF OBJECT_ID('tempdb..#semantic_gap_count') IS NOT NULL DROP TABLE #semantic_gap_count;
SELECT LOWER(LTRIM(RTRIM(semantic_model_qualified_name))) AS model_key, COUNT(*) AS gap_count
INTO #semantic_gap_count FROM dbo.bronze_semantic_model_definition_gaps GROUP BY LOWER(LTRIM(RTRIM(semantic_model_qualified_name)));

SELECT
    it.qualified_name AS semantic_model_qualified_name, it.workspace_name, ISNULL(it.workspace_environment,'') AS workspace_environment, it.item_name AS semantic_model_name,
    (ISNULL(sa.likely_source_count,0) * 5) + (ISNULL(sa.native_query_count,0) * 4) + (ISNULL(sa.stored_procedure_count,0) * 3) + (ISNULL(sgc.gap_count,0) * 50) + (ISNULL(d3.cnt,0) * 20) AS priority_score,
    (CASE WHEN (ISNULL(sa.likely_source_count,0) * 5) + (ISNULL(sa.native_query_count,0) * 4) + (ISNULL(sa.stored_procedure_count,0) * 3) + (ISNULL(sgc.gap_count,0) * 50) + (ISNULL(d3.cnt,0) * 20) >= 85 THEN 'critical'
          WHEN (ISNULL(sa.likely_source_count,0) * 5) + (ISNULL(sa.native_query_count,0) * 4) + (ISNULL(sa.stored_procedure_count,0) * 3) + (ISNULL(sgc.gap_count,0) * 50) + (ISNULL(d3.cnt,0) * 20) >= 75 THEN 'high'
          WHEN (ISNULL(sa.likely_source_count,0) * 5) + (ISNULL(sa.native_query_count,0) * 4) + (ISNULL(sa.stored_procedure_count,0) * 3) + (ISNULL(sgc.gap_count,0) * 50) + (ISNULL(d3.cnt,0) * 20) >= 60 THEN 'medium'
          ELSE 'low' END) AS priority_band,
    (CASE WHEN ISNULL(sgc.gap_count,0) > 0 THEN 'definition_export_blocked'
          WHEN ISNULL(sa.likely_source_count,0) > 0 OR ISNULL(sa.native_query_count,0) > 0 THEN 'needs_tmdl_m_query_review'
          ELSE 'covered_by_current_tmdl_evidence' END) AS review_status,
    ISNULL(sa.source_candidate_count,0) AS source_candidate_count, ISNULL(sa.confirmed_source_count,0) AS confirmed_source_count,
    ISNULL(sa.likely_source_count,0) AS likely_source_count, ISNULL(sa.native_query_count,0) AS native_query_count,
    ISNULL(sa.stored_procedure_count,0) AS stored_procedure_count, ISNULL(sa.table_or_view_count,0) AS table_or_view_count,
    ISNULL(d3a.linked_d3_item_review_ids,'') AS linked_d3_item_review_ids,
    ISNULL(sga.definition_gap_status,'') AS definition_gap_status,
    'Review exported TMDL/M expressions table by table, confirm native queries and stored procedures, and resolve table/view/SP type through SQL metadata.' AS recommended_action
INTO dbo.silver_e1_semantic_model_review_queue
FROM dbo.bronze_items it
LEFT JOIN #semantic_agg sa ON sa.model_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN #semantic_gap_count sgc ON sgc.model_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN #semantic_gap_agg sga ON sga.model_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN (SELECT item_key, COUNT(*) AS cnt FROM (SELECT DISTINCT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, item_review_id FROM dbo.silver_d3_item_closure_control_queue WHERE ISNULL(item_review_id,'') <> '') x GROUP BY item_key) d3 ON d3.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
LEFT JOIN #item_d3_agg d3a ON d3a.item_key = LOWER(LTRIM(RTRIM(it.qualified_name)))
WHERE it.item_type = 'SemanticModel';

-- ===========================================================================
-- SQL object metadata queue.
-- ===========================================================================
IF OBJECT_ID('tempdb..#sql_candidates') IS NOT NULL DROP TABLE #sql_candidates;
SELECT
    (CASE WHEN source_type_norm = '' AND source_server_norm = '' AND source_database_norm = '' AND schema_name_norm = '' AND object_name_norm = ''
          THEN LOWER(LTRIM(RTRIM(object_key)))
          ELSE source_type_norm + '|' + source_server_norm + '|' + source_database_norm + '|' + schema_name_norm + '|' + object_name_norm END) AS object_key_norm,
    (CASE WHEN source_type_norm = '' AND source_server_norm = '' AND source_database_norm = '' AND schema_name_norm = '' AND object_name_norm = ''
          THEN LOWER(LTRIM(RTRIM(object_key)))
          ELSE source_type_norm + '|' + source_server_norm + '|' + source_database_norm + '|' + schema_name_norm + '|' + object_name_norm END) AS object_key_disp,
    '*|' + source_server_norm + '|' + source_database_norm + '|' + schema_name_norm + '|' + object_name_norm AS wildcard_key,
    item_key, item_qualified_name, item_type, operation_type, operation_norm, lineage_confidence_norm, object_type_status_norm,
    source_type, source_server, source_database, schema_name, object_name, object_display_name, raw_object_type_disp
INTO #sql_candidates
FROM #rw
WHERE lineage_confidence_norm = 'likely' OR object_type_status_norm = 'ambiguous' OR operation_norm = 'unknown';

IF OBJECT_ID('tempdb..#sql_first') IS NOT NULL DROP TABLE #sql_first;
SELECT object_key_norm, object_key_disp, wildcard_key, source_type, source_server, source_database, schema_name, object_name, object_display_name, raw_object_type_disp
INTO #sql_first
FROM (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY object_key_norm ORDER BY (SELECT NULL)) AS rn FROM #sql_candidates
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#sql_agg') IS NOT NULL DROP TABLE #sql_agg;
SELECT object_key_norm,
    COUNT(DISTINCT item_qualified_name) AS impacted_item_count,
    SUM(CASE WHEN lineage_confidence_norm = 'likely' THEN 1 ELSE 0 END) AS likely_count,
    SUM(CASE WHEN object_type_status_norm = 'ambiguous' THEN 1 ELSE 0 END) AS ambiguous_count,
    SUM(CASE WHEN operation_norm = 'unknown' OR operation_norm = '' THEN 1 ELSE 0 END) AS unknown_operation_count
INTO #sql_agg
FROM #sql_candidates
GROUP BY object_key_norm;

IF OBJECT_ID('tempdb..#sql_ops_agg') IS NOT NULL DROP TABLE #sql_ops_agg;
;WITH d AS (SELECT DISTINCT object_key_norm, operation_type FROM #sql_candidates WHERE operation_type <> ''),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY object_key_norm ORDER BY LOWER(operation_type)) AS rn FROM d)
SELECT object_key_norm, STRING_AGG(operation_type, '; ') WITHIN GROUP (ORDER BY rn) AS operation_types
INTO #sql_ops_agg FROM r GROUP BY object_key_norm;

IF OBJECT_ID('tempdb..#sql_types_agg') IS NOT NULL DROP TABLE #sql_types_agg;
;WITH d AS (SELECT DISTINCT object_key_norm, item_type FROM #sql_candidates WHERE ISNULL(item_type,'') <> ''),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY object_key_norm ORDER BY LOWER(item_type)) AS rn FROM d)
SELECT object_key_norm, STRING_AGG(item_type, '; ') WITHIN GROUP (ORDER BY rn) AS impacted_item_types
INTO #sql_types_agg FROM r GROUP BY object_key_norm;

IF OBJECT_ID('tempdb..#sql_items_agg') IS NOT NULL DROP TABLE #sql_items_agg;
;WITH d AS (SELECT DISTINCT object_key_norm, item_qualified_name FROM #sql_candidates WHERE item_qualified_name <> ''),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY object_key_norm ORDER BY LOWER(item_qualified_name)) AS rn FROM d)
SELECT object_key_norm, LEFT(STRING_AGG(item_qualified_name, '; ') WITHIN GROUP (ORDER BY rn), 1200) AS impacted_items_sample
INTO #sql_items_agg FROM r WHERE rn <= 10 GROUP BY object_key_norm;

-- D4/metadata/catalog: exact-key match count + wildcard-key match count
-- (server/db/schema/object regardless of type), summed -- see header note.
IF OBJECT_ID('tempdb..#d4_keyed') IS NOT NULL DROP TABLE #d4_keyed;
SELECT source_id,
    LOWER(LTRIM(RTRIM(source_type))) + '|' + LOWER(LTRIM(RTRIM(source_server))) + '|' + LOWER(LTRIM(RTRIM(source_database))) + '|' + LOWER(LTRIM(RTRIM(schema_name))) + '|' + LOWER(LTRIM(RTRIM(object_name))) AS exact_key,
    LOWER(LTRIM(RTRIM(source_server))) AS server_norm, LOWER(LTRIM(RTRIM(source_database))) AS db_norm,
    LOWER(LTRIM(RTRIM(schema_name))) AS schema_norm, LOWER(LTRIM(RTRIM(object_name))) AS object_norm
INTO #d4_keyed
FROM dbo.silver_d4_exact_object_type_source_queue;

IF OBJECT_ID('tempdb..#d4_match') IS NOT NULL DROP TABLE #d4_match;
SELECT sf.object_key_norm, d4.source_id, 'exact' AS match_kind
INTO #d4_match
FROM #sql_first sf
INNER JOIN #d4_keyed d4 ON d4.exact_key = sf.object_key_norm
UNION ALL
SELECT sf.object_key_norm, d4.source_id, 'wildcard'
FROM #sql_first sf
INNER JOIN #d4_keyed d4 ON d4.server_norm = LOWER(LTRIM(RTRIM(sf.source_server))) AND d4.db_norm = LOWER(LTRIM(RTRIM(sf.source_database)))
    AND d4.schema_norm = LOWER(LTRIM(RTRIM(sf.schema_name))) AND d4.object_norm = LOWER(LTRIM(RTRIM(sf.object_name)));

IF OBJECT_ID('tempdb..#d4_match_agg') IS NOT NULL DROP TABLE #d4_match_agg;
SELECT object_key_norm, COUNT(*) AS d4_target_count
INTO #d4_match_agg FROM #d4_match GROUP BY object_key_norm;

IF OBJECT_ID('tempdb..#d4_ids_agg') IS NOT NULL DROP TABLE #d4_ids_agg;
;WITH d AS (SELECT DISTINCT object_key_norm, source_id FROM #d4_match),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY object_key_norm ORDER BY LOWER(source_id)) AS rn FROM d)
SELECT object_key_norm, STRING_AGG(source_id, '; ') WITHIN GROUP (ORDER BY rn) AS linked_d4_source_ids
INTO #d4_ids_agg FROM r GROUP BY object_key_norm;

IF OBJECT_ID('tempdb..#meta_keyed') IS NOT NULL DROP TABLE #meta_keyed;
SELECT ISNULL(object_type,'') AS type_label,
    LOWER(LTRIM(RTRIM(source_type))) + '|' + LOWER(LTRIM(RTRIM(source_server))) + '|' + LOWER(LTRIM(RTRIM(source_database))) + '|' +
        LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) + '|' + LOWER(LTRIM(RTRIM(ISNULL(object_name,'')))) AS exact_key,
    LOWER(LTRIM(RTRIM(source_server))) AS server_norm, LOWER(LTRIM(RTRIM(source_database))) AS db_norm,
    LOWER(LTRIM(RTRIM(ISNULL(schema_name,'')))) AS schema_norm,
    LOWER(LTRIM(RTRIM(ISNULL(object_name,'')))) AS object_norm
INTO #meta_keyed
FROM dbo.bronze_source_object_type_metadata_evidence;

IF OBJECT_ID('tempdb..#catalog_keyed') IS NOT NULL DROP TABLE #catalog_keyed;
SELECT object_key AS raw_object_key, ISNULL(object_type,'') AS type_label,
    LOWER(LTRIM(RTRIM(source_type))) + '|' + LOWER(LTRIM(RTRIM(source_server))) + '|' + LOWER(LTRIM(RTRIM(source_database))) + '|' + LOWER(LTRIM(RTRIM(schema_name))) + '|' + LOWER(LTRIM(RTRIM(object_name))) AS exact_key,
    LOWER(LTRIM(RTRIM(source_server))) AS server_norm, LOWER(LTRIM(RTRIM(source_database))) AS db_norm,
    LOWER(LTRIM(RTRIM(schema_name))) AS schema_norm, LOWER(LTRIM(RTRIM(object_name))) AS object_norm
INTO #catalog_keyed
FROM dbo.bronze_sql_endpoint_object_catalog;

IF OBJECT_ID('tempdb..#meta_match') IS NOT NULL DROP TABLE #meta_match;
SELECT DISTINCT sf.object_key_norm, m.type_label
INTO #meta_match
FROM #sql_first sf
INNER JOIN #meta_keyed m ON m.exact_key = sf.object_key_norm
    OR (m.server_norm = LOWER(LTRIM(RTRIM(sf.source_server))) AND m.db_norm = LOWER(LTRIM(RTRIM(sf.source_database)))
        AND m.schema_norm = LOWER(LTRIM(RTRIM(sf.schema_name))) AND m.object_norm = LOWER(LTRIM(RTRIM(sf.object_name))));

IF OBJECT_ID('tempdb..#catalog_match') IS NOT NULL DROP TABLE #catalog_match;
SELECT DISTINCT sf.object_key_norm, c.type_label
INTO #catalog_match
FROM #sql_first sf
INNER JOIN #catalog_keyed c ON c.exact_key = sf.object_key_norm
    OR (c.server_norm = LOWER(LTRIM(RTRIM(sf.source_server))) AND c.db_norm = LOWER(LTRIM(RTRIM(sf.source_database)))
        AND c.schema_norm = LOWER(LTRIM(RTRIM(sf.schema_name))) AND c.object_norm = LOWER(LTRIM(RTRIM(sf.object_name))));

IF OBJECT_ID('tempdb..#meta_exists') IS NOT NULL DROP TABLE #meta_exists;
SELECT DISTINCT object_key_norm INTO #meta_exists FROM #meta_match
UNION
SELECT DISTINCT object_key_norm FROM #catalog_match;

IF OBJECT_ID('tempdb..#meta_types_agg') IS NOT NULL DROP TABLE #meta_types_agg;
;WITH d AS (
    SELECT object_key_norm, type_label FROM #meta_match WHERE ISNULL(type_label,'') <> ''
    UNION
    SELECT object_key_norm, type_label FROM #catalog_match WHERE ISNULL(type_label,'') <> ''
),
r AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY object_key_norm ORDER BY LOWER(type_label)) AS rn FROM d)
SELECT object_key_norm, STRING_AGG(type_label, '; ') WITHIN GROUP (ORDER BY rn) AS existing_metadata_types
INTO #meta_types_agg FROM r GROUP BY object_key_norm;

SELECT
    sf.object_key_disp AS object_key,
    (ISNULL(sa.likely_count,0) * 2) + (ISNULL(sa.ambiguous_count,0) * 3) + (ISNULL(sa.unknown_operation_count,0) * 10) + (ISNULL(d4c.d4_target_count,0) * 8) AS priority_score,
    (CASE WHEN (ISNULL(sa.likely_count,0) * 2) + (ISNULL(sa.ambiguous_count,0) * 3) + (ISNULL(sa.unknown_operation_count,0) * 10) + (ISNULL(d4c.d4_target_count,0) * 8) >= 85 THEN 'critical'
          WHEN (ISNULL(sa.likely_count,0) * 2) + (ISNULL(sa.ambiguous_count,0) * 3) + (ISNULL(sa.unknown_operation_count,0) * 10) + (ISNULL(d4c.d4_target_count,0) * 8) >= 75 THEN 'high'
          WHEN (ISNULL(sa.likely_count,0) * 2) + (ISNULL(sa.ambiguous_count,0) * 3) + (ISNULL(sa.unknown_operation_count,0) * 10) + (ISNULL(d4c.d4_target_count,0) * 8) >= 60 THEN 'medium'
          ELSE 'low' END) AS priority_band,
    (CASE WHEN me.object_key_norm IS NOT NULL THEN 'metadata_evidence_available'
          WHEN ISNULL(d4c.d4_target_count,0) > 0 THEN 'metadata_needed_for_d4'
          ELSE 'owner_or_definition_confirmation_needed' END) AS metadata_status,
    sf.source_type, sf.source_server, sf.source_database, sf.schema_name, sf.object_name, sf.object_display_name, sf.raw_object_type_disp AS raw_object_type,
    ISNULL(sa.likely_count,0) AS likely_reference_count, ISNULL(sa.ambiguous_count,0) AS ambiguous_type_count,
    ISNULL(sa.unknown_operation_count,0) AS unknown_operation_count, ISNULL(sa.impacted_item_count,0) AS impacted_item_count,
    ISNULL(oa.operation_types,'') AS operation_types, ISNULL(ta.impacted_item_types,'') AS impacted_item_types,
    ISNULL(d4i.linked_d4_source_ids,'') AS linked_d4_source_ids, ISNULL(mt.existing_metadata_types,'') AS existing_metadata_types,
    ISNULL(ia.impacted_items_sample,'') AS impacted_items_sample,
    'Resolve exact SQL/Fabric object type using sys.objects, INFORMATION_SCHEMA, Fabric SQL endpoint catalog, OneLake metadata, or owner-approved catalog evidence.' AS recommended_action
INTO dbo.silver_e1_sql_object_metadata_queue
FROM #sql_first sf
LEFT JOIN #sql_agg sa ON sa.object_key_norm = sf.object_key_norm
LEFT JOIN #sql_ops_agg oa ON oa.object_key_norm = sf.object_key_norm
LEFT JOIN #sql_types_agg ta ON ta.object_key_norm = sf.object_key_norm
LEFT JOIN #sql_items_agg ia ON ia.object_key_norm = sf.object_key_norm
LEFT JOIN #d4_match_agg d4c ON d4c.object_key_norm = sf.object_key_norm
LEFT JOIN #d4_ids_agg d4i ON d4i.object_key_norm = sf.object_key_norm
LEFT JOIN #meta_exists me ON me.object_key_norm = sf.object_key_norm
LEFT JOIN #meta_types_agg mt ON mt.object_key_norm = sf.object_key_norm;

-- ===========================================================================
-- Likely resolution targets (combined worklist).
-- ===========================================================================
IF OBJECT_ID('tempdb..#targets_notebook') IS NOT NULL DROP TABLE #targets_notebook;
SELECT TOP 80
    'notebook_code_review' AS target_type, priority_score, priority_band, item_qualified_name AS target_name,
    'likely=' + CAST(likely_object_rows AS VARCHAR(10)) + '; ambiguous=' + CAST(ambiguous_object_rows AS VARCHAR(10)) + '; D1=' + linked_d1_ids + '; D3=' + linked_d3_item_review_ids + '; D8=' + linked_d8_ids AS blocker_summary,
    recommended_action, 'analysis/e1_notebook_code_review_queue.csv' AS queue_path
INTO #targets_notebook
FROM dbo.silver_e1_notebook_code_review_queue
WHERE review_status <> 'covered_by_current_local_evidence'
ORDER BY priority_score DESC, LOWER(workspace_name), LOWER(item_name);

IF OBJECT_ID('tempdb..#targets_semantic') IS NOT NULL DROP TABLE #targets_semantic;
SELECT TOP 80
    'semantic_model_tmdl_review' AS target_type, priority_score, priority_band, semantic_model_qualified_name AS target_name,
    'likely=' + CAST(likely_source_count AS VARCHAR(10)) + '; native=' + CAST(native_query_count AS VARCHAR(10)) + '; stored_procedure=' + CAST(stored_procedure_count AS VARCHAR(10)) + '; D3=' + linked_d3_item_review_ids AS blocker_summary,
    recommended_action, 'analysis/e1_semantic_model_review_queue.csv' AS queue_path
INTO #targets_semantic
FROM dbo.silver_e1_semantic_model_review_queue
WHERE review_status <> 'covered_by_current_tmdl_evidence'
ORDER BY priority_score DESC, LOWER(workspace_name), LOWER(semantic_model_name);

IF OBJECT_ID('tempdb..#targets_sql') IS NOT NULL DROP TABLE #targets_sql;
SELECT TOP 120
    'sql_object_metadata_resolution' AS target_type, priority_score, priority_band, object_display_name AS target_name,
    'likely=' + CAST(likely_reference_count AS VARCHAR(10)) + '; ambiguous=' + CAST(ambiguous_type_count AS VARCHAR(10)) + '; unknown_operation=' + CAST(unknown_operation_count AS VARCHAR(10)) + '; D4=' + linked_d4_source_ids AS blocker_summary,
    recommended_action, 'analysis/e1_sql_object_metadata_queue.csv' AS queue_path
INTO #targets_sql
FROM dbo.silver_e1_sql_object_metadata_queue
ORDER BY priority_score DESC, LOWER(object_key);

SELECT * INTO dbo.silver_e1_likely_resolution_targets FROM #targets_notebook
UNION ALL
SELECT * FROM #targets_semantic
UNION ALL
SELECT * FROM #targets_sql;

-- ===========================================================================
-- Scope summary.
-- ===========================================================================
SELECT scope, metric, value, notes
INTO dbo.silver_e1_deep_evidence_scope_summary
FROM (
    SELECT 'current likely dependencies' AS scope, 'dependency_edges_likely' AS metric, (SELECT COUNT(*) FROM dbo.bronze_dependencies WHERE confidence = 'likely') AS value, 'D2 confirmation target.' AS notes
    UNION ALL
    SELECT 'current likely object lineage', 'object_rows_likely', (SELECT COUNT(*) FROM #rw WHERE lineage_confidence_norm = 'likely'), 'D3 confirmation target.'
    UNION ALL
    SELECT 'current ambiguous object types', 'object_type_ambiguous', (SELECT COUNT(*) FROM #rw WHERE object_type_status_norm = 'ambiguous'), 'D4 exact object type target.'
    UNION ALL
    SELECT 'notebooks', 'notebook_items', (SELECT COUNT(*) FROM dbo.silver_e1_notebook_code_review_queue), 'Notebook-by-notebook review scope.'
    UNION ALL
    SELECT 'notebooks', 'notebooks_requiring_review', (SELECT COUNT(*) FROM dbo.silver_e1_notebook_code_review_queue WHERE review_status <> 'covered_by_current_local_evidence'), 'Code review queue.'
    UNION ALL
    SELECT 'semantic models', 'semantic_model_items', (SELECT COUNT(*) FROM dbo.silver_e1_semantic_model_review_queue), 'Semantic model review scope.'
    UNION ALL
    SELECT 'semantic models', 'semantic_models_requiring_review', (SELECT COUNT(*) FROM dbo.silver_e1_semantic_model_review_queue WHERE review_status <> 'covered_by_current_tmdl_evidence'), 'TMDL/M review queue.'
    UNION ALL
    SELECT 'sql metadata', 'sql_object_metadata_targets', (SELECT COUNT(*) FROM dbo.silver_e1_sql_object_metadata_queue), 'Unique source object metadata targets.'
    UNION ALL
    SELECT 'sql metadata', 'metadata_targets_without_evidence', (SELECT COUNT(*) FROM dbo.silver_e1_sql_object_metadata_queue WHERE metadata_status <> 'metadata_evidence_available'), 'Read-only metadata or owner catalog needed.'
    UNION ALL
    SELECT 'resolution', 'high_priority_resolution_targets', (SELECT COUNT(*) FROM dbo.silver_e1_likely_resolution_targets), 'Combined first-pass worklist across notebook, semantic, and SQL metadata queues.'
) s;

-- ===========================================================================
-- External read-only action plan.
-- ===========================================================================
SELECT action_id, action_scope, target_count, proposed_local_or_readonly_command, writes_external_system, requires_human_execution_or_approval, expected_output, notes
INTO dbo.silver_e1_external_readonly_action_plan
FROM (
    SELECT 'E1A01' AS action_id, 'notebook_definitions' AS action_scope,
        (SELECT COUNT(*) FROM dbo.silver_e1_notebook_code_review_queue WHERE review_status <> 'covered_by_current_local_evidence') AS target_count,
        'pwsh -NoLogo -File backend/scripts/18_extract_item_object_lineage.ps1 -AzCommand az' AS proposed_local_or_readonly_command,
        'no' AS writes_external_system, 'yes' AS requires_human_execution_or_approval,
        'analysis/item_object_lineage_candidates.csv; analysis/item_object_lineage_gaps.csv; index/manual_lineage_object_evidence.csv updates only after review' AS expected_output,
        'Read notebook definitions/code and extract SQL, Spark, OneLake, JDBC/ODBC, table, view, stored procedure, file, and notebook-call references.' AS notes
    UNION ALL
    SELECT 'E1A02', 'pipeline_and_copyjob_definitions',
        (SELECT COUNT(*) FROM dbo.bronze_items WHERE item_type IN ('DataPipeline','CopyJob')),
        'pwsh -NoLogo -File backend/scripts/19_extract_pipeline_object_lineage.ps1 -AzCommand az',
        'no', 'yes',
        'analysis/pipeline_object_lineage_candidates.csv; analysis/pipeline_activity_lineage.csv; analysis/pipeline_object_lineage_gaps.csv',
        'Read pipeline and CopyJob definitions and distinguish direct versus inherited child lineage.'
    UNION ALL
    SELECT 'E1A03', 'semantic_model_tmdl',
        (SELECT COUNT(*) FROM dbo.silver_e1_semantic_model_review_queue WHERE review_status <> 'covered_by_current_tmdl_evidence'),
        'pwsh -NoLogo -File backend/scripts/09_enrich_semantic_model_views.ps1 -AzCommand az -MaxModels 400; pwsh -NoLogo -File backend/scripts/08_build_semantic_lineage.ps1',
        'no', 'yes',
        'analysis/semantic_model_view_candidates.csv; analysis/semantic_model_definition_gaps.csv',
        'Export/read TMDL model definitions, then review M expressions, native queries, stored procedures, and table/view references.'
    UNION ALL
    SELECT 'E1A04', 'sql_and_fabric_object_metadata',
        (SELECT COUNT(*) FROM dbo.silver_e1_sql_object_metadata_queue WHERE metadata_status <> 'metadata_evidence_available'),
        'pwsh -NoLogo -File backend/scripts/20_extract_source_object_type_metadata.ps1 -AzCommand az -TrustServerCertificate; pwsh -NoLogo -File backend/scripts/34_extract_sql_endpoint_object_catalog.ps1 -AzCommand az -TrustServerCertificate',
        'no', 'yes',
        'analysis/source_object_type_metadata_evidence.csv; analysis/sql_endpoint_object_catalog.csv',
        'Read sys.objects/INFORMATION_SCHEMA/Fabric SQL endpoint catalogs to resolve table, view, stored procedure, function, file, or query type.'
) s;

END
