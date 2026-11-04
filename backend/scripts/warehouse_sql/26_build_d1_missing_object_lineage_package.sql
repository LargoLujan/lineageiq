-- Warehouse-native translation of backend/scripts/26_build_d1_missing_
-- object_lineage_package.ps1 (SQL migration). Reads dbo.silver_likely_conflict_cleanup_queue (25), dbo.bronze_
-- object_level_lineage_coverage, dbo.silver_manual_lineage_review_queue
-- (14), dbo.bronze_item_object_lineage_gaps/pipeline_object_lineage_
-- gaps/semantic_model_definition_gaps/semantic_model_view_candidates,
-- dbo.silver_orchestration_v2_plan/parallel_candidates (24), dbo.bronze_
-- items. First-match-per-item lookups (Set-FirstMapValue) mirror plain
-- PowerShell hashtables' case-insensitive default via LOWER(LTRIM(RTRIM
-- (...))) + ROW_NUMBER-first-row-wins.
CREATE OR ALTER PROCEDURE dbo.sp_build_d1_missing_object_lineage_package
AS
BEGIN

IF OBJECT_ID('dbo.silver_d1_missing_object_lineage_queue', 'U') IS NOT NULL DROP TABLE dbo.silver_d1_missing_object_lineage_queue;
IF OBJECT_ID('dbo.silver_d1_missing_object_lineage_summary', 'U') IS NOT NULL DROP TABLE dbo.silver_d1_missing_object_lineage_summary;
IF OBJECT_ID('dbo.silver_d1_manual_lineage_evidence_template', 'U') IS NOT NULL DROP TABLE dbo.silver_d1_manual_lineage_evidence_template;
IF OBJECT_ID('dbo.silver_d1_readonly_target_items', 'U') IS NOT NULL DROP TABLE dbo.silver_d1_readonly_target_items;

IF OBJECT_ID('tempdb..#d1_rows') IS NOT NULL DROP TABLE #d1_rows;
SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS row_id,
    ISNULL(TRY_CAST(priority_score AS INT), 0) AS priority_score,
    workspace_name, item_type, item_name, item_qualified_name,
    LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key
INTO #d1_rows
FROM dbo.silver_likely_conflict_cleanup_queue
WHERE phase_id = 'D1' OR blocker_type = 'missing_object_level_lineage';

IF OBJECT_ID('tempdb..#coverage_first') IS NOT NULL DROP TABLE #coverage_first;
SELECT item_key, workspace_environment, coverage_status, gap_reason, next_action
INTO #coverage_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, workspace_environment, coverage_status, gap_reason, next_action,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(item_qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_object_level_lineage_coverage WHERE item_qualified_name <> ''
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#manual_first') IS NOT NULL DROP TABLE #manual_first;
SELECT item_key, workspace_environment, source_dependency_count, source_dependencies, auto_object_evidence_count,
    manual_object_evidence_count, total_object_evidence_count, avg_duration_seconds, max_duration_seconds, failed_count,
    is_critical_path_candidate, is_failure_hotspot
INTO #manual_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, workspace_environment, source_dependency_count, source_dependencies,
        auto_object_evidence_count, manual_object_evidence_count, total_object_evidence_count, avg_duration_seconds, max_duration_seconds,
        failed_count, is_critical_path_candidate, is_failure_hotspot,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(item_qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_manual_lineage_review_queue
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#item_first') IS NOT NULL DROP TABLE #item_first;
SELECT item_key, workspace_environment, technical_id
INTO #item_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key, workspace_environment, technical_id,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_items WHERE qualified_name <> ''
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#item_gap_first') IS NOT NULL DROP TABLE #item_gap_first;
SELECT item_key, status_code, definition_parts, candidate_count, error, notes
INTO #item_gap_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, status_code,
        ISNULL(TRY_CAST(definition_parts AS INT), 0) AS definition_parts,
        ISNULL(TRY_CAST(candidate_count AS INT), 0) AS candidate_count, error, notes,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(item_qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_item_object_lineage_gaps WHERE item_qualified_name <> ''
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#pipeline_gap_first') IS NOT NULL DROP TABLE #pipeline_gap_first;
SELECT item_key, status_code, definition_parts, activity_count, candidate_count, error, notes
INTO #pipeline_gap_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(item_qualified_name))) AS item_key, status_code,
        ISNULL(TRY_CAST(definition_parts AS INT), 0) AS definition_parts,
        ISNULL(TRY_CAST(activity_count AS INT), 0) AS activity_count,
        ISNULL(TRY_CAST(candidate_count AS INT), 0) AS candidate_count, error, notes,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(item_qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_pipeline_object_lineage_gaps WHERE item_qualified_name <> ''
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#semantic_gap_first') IS NOT NULL DROP TABLE #semantic_gap_first;
SELECT item_key, status_code, error, notes
INTO #semantic_gap_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(semantic_model_qualified_name))) AS item_key, status_code, error, notes,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(semantic_model_qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.bronze_semantic_model_definition_gaps WHERE semantic_model_qualified_name <> ''
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#semantic_candidate_counts') IS NOT NULL DROP TABLE #semantic_candidate_counts;
SELECT LOWER(LTRIM(RTRIM(semantic_model_qualified_name))) AS item_key, COUNT(*) AS candidate_count
INTO #semantic_candidate_counts
FROM dbo.bronze_semantic_model_view_candidates
WHERE semantic_model_qualified_name <> ''
GROUP BY LOWER(LTRIM(RTRIM(semantic_model_qualified_name)));

IF OBJECT_ID('tempdb..#v2_first') IS NOT NULL DROP TABLE #v2_first;
SELECT item_key, v2_status, v2_recommended_next_action
INTO #v2_first
FROM (
    SELECT LOWER(LTRIM(RTRIM(qualified_name))) AS item_key, v2_status, v2_recommended_next_action,
        ROW_NUMBER() OVER (PARTITION BY LOWER(LTRIM(RTRIM(qualified_name))) ORDER BY (SELECT NULL)) AS rn
    FROM dbo.silver_orchestration_v2_plan
) x WHERE rn = 1;

IF OBJECT_ID('tempdb..#parallel_blockers') IS NOT NULL DROP TABLE #parallel_blockers;
SELECT item_key, SUM(cnt) AS blocker_count
INTO #parallel_blockers
FROM (
    SELECT LOWER(LTRIM(RTRIM(candidate_a))) AS item_key, COUNT(*) AS cnt FROM dbo.silver_orchestration_v2_parallel_candidates WHERE candidate_status = 'blocked_missing_object_evidence' AND candidate_a <> '' GROUP BY LOWER(LTRIM(RTRIM(candidate_a)))
    UNION ALL
    SELECT LOWER(LTRIM(RTRIM(candidate_b))), COUNT(*) FROM dbo.silver_orchestration_v2_parallel_candidates WHERE candidate_status = 'blocked_missing_object_evidence' AND candidate_b <> '' GROUP BY LOWER(LTRIM(RTRIM(candidate_b)))
) u GROUP BY item_key;

-- ===========================================================================
-- Main enrichment.
-- ===========================================================================
IF OBJECT_ID('tempdb..#enriched') IS NOT NULL DROP TABLE #enriched;
SELECT
    d.row_id, d.priority_score,
    CASE WHEN d.priority_score >= 130 THEN 'critical' WHEN d.priority_score >= 100 THEN 'high' WHEN d.priority_score >= 70 THEN 'medium' ELSE 'low' END AS priority_band,
    d.workspace_name,
    ISNULL(NULLIF(m.workspace_environment, ''), ISNULL(NULLIF(c.workspace_environment, ''), ISNULL(it.workspace_environment, ''))) AS workspace_environment,
    d.item_type, d.item_name, d.item_qualified_name,
    ISNULL(it.technical_id, '') AS technical_id,
    ISNULL(c.coverage_status, '') AS coverage_status,
    ISNULL(NULLIF(c.gap_reason, ''), '') AS gap_reason,
    LEFT(ISNULL(c.next_action, ''), 500) AS coverage_next_action,
    ISNULL(m.source_dependency_count, 0) AS source_dependency_count,
    LEFT(ISNULL(m.source_dependencies, ''), 900) AS source_dependencies,
    ISNULL(m.auto_object_evidence_count, 0) AS auto_object_evidence_count,
    ISNULL(m.manual_object_evidence_count, 0) AS manual_object_evidence_count,
    ISNULL(m.total_object_evidence_count, 0) AS total_object_evidence_count,
    m.avg_duration_seconds, m.max_duration_seconds,
    ISNULL(m.failed_count, 0) AS failed_count,
    m.is_critical_path_candidate, m.is_failure_hotspot,
    ISNULL(v2.v2_status, '') AS v2_status,
    LEFT(ISNULL(v2.v2_recommended_next_action, ''), 650) AS v2_recommended_next_action,
    ISNULL(sc.candidate_count, 0) AS semantic_candidate_count,
    ISNULL(pb.blocker_count, 0) AS parallel_missing_object_blocker_count,
    ig.status_code AS ig_status_code, ig.definition_parts AS ig_definition_parts, ig.candidate_count AS ig_candidate_count, ig.error AS ig_error, ig.notes AS ig_notes,
    pg.status_code AS pg_status_code, pg.definition_parts AS pg_definition_parts, pg.activity_count AS pg_activity_count, pg.candidate_count AS pg_candidate_count, pg.error AS pg_error, pg.notes AS pg_notes,
    sg.status_code AS sg_status_code, sg.error AS sg_error, sg.notes AS sg_notes
INTO #enriched
FROM #d1_rows d
LEFT JOIN #coverage_first c ON c.item_key = d.item_key
LEFT JOIN #manual_first m ON m.item_key = d.item_key
LEFT JOIN #item_first it ON it.item_key = d.item_key
LEFT JOIN #item_gap_first ig ON ig.item_key = d.item_key
LEFT JOIN #pipeline_gap_first pg ON pg.item_key = d.item_key
LEFT JOIN #semantic_gap_first sg ON sg.item_key = d.item_key
LEFT JOIN #semantic_candidate_counts sc ON sc.item_key = d.item_key
LEFT JOIN #v2_first v2 ON v2.item_key = d.item_key
LEFT JOIN #parallel_blockers pb ON pb.item_key = d.item_key;

IF OBJECT_ID('tempdb..#final') IS NOT NULL DROP TABLE #final;
SELECT e.*,
    calc.definition_lookup_status, calc.definition_status_code, calc.definition_parts, calc.definition_activity_count,
    calc.definition_candidate_count, calc.definition_error, calc.definition_notes, calc.recommended_method,
    calc.recommended_script, calc.recommended_command, calc.readonly_goal
INTO #final
FROM #enriched e
CROSS APPLY (
    SELECT
        definition_lookup_status_calc AS definition_lookup_status,
        CASE e.item_type WHEN 'DataPipeline' THEN e.pg_status_code WHEN 'SemanticModel' THEN e.sg_status_code ELSE e.ig_status_code END AS definition_status_code,
        CASE e.item_type WHEN 'DataPipeline' THEN e.pg_definition_parts WHEN 'SemanticModel' THEN 0 ELSE ISNULL(e.ig_definition_parts, 0) END AS definition_parts,
        CASE e.item_type WHEN 'DataPipeline' THEN ISNULL(e.pg_activity_count, 0) ELSE 0 END AS definition_activity_count,
        CASE e.item_type WHEN 'DataPipeline' THEN ISNULL(e.pg_candidate_count, 0) WHEN 'SemanticModel' THEN e.semantic_candidate_count ELSE ISNULL(e.ig_candidate_count, 0) END AS definition_candidate_count,
        LEFT(ISNULL(CASE e.item_type WHEN 'DataPipeline' THEN e.pg_error WHEN 'SemanticModel' THEN e.sg_error ELSE e.ig_error END, ''), 900) AS definition_error,
        LEFT(ISNULL(CASE e.item_type WHEN 'DataPipeline' THEN e.pg_notes WHEN 'SemanticModel' THEN e.sg_notes ELSE e.ig_notes END, ''), 650) AS definition_notes,
        CASE e.item_type
            WHEN 'Notebook' THEN 'Inspect notebook code/default lakehouse, then record exact read/write/execute objects.'
            WHEN 'CopyJob' THEN 'Inspect CopyJob source and sink mappings, then record exact source and destination objects.'
            WHEN 'DataPipeline' THEN 'Inspect pipeline activities, invoked items, copy source/sink mappings, and inherited lineage.'
            WHEN 'SemanticModel' THEN 'Inspect TMDL, Power Query/M expressions, model partitions, or owner-approved source mapping.'
            ELSE 'Inspect item definition/code and record exact object-level evidence.' END AS recommended_method,
        CASE e.item_type
            WHEN 'Notebook' THEN 'backend/scripts/18_extract_item_object_lineage.ps1'
            WHEN 'CopyJob' THEN 'backend/scripts/18_extract_item_object_lineage.ps1'
            WHEN 'DataPipeline' THEN 'backend/scripts/19_extract_pipeline_object_lineage.ps1'
            WHEN 'SemanticModel' THEN 'backend/scripts/09_enrich_semantic_model_views.ps1'
            ELSE '' END AS recommended_script,
        CASE e.item_type
            WHEN 'Notebook' THEN 'pwsh -NoLogo -File backend/scripts/18_extract_item_object_lineage.ps1 -AzCommand az'
            WHEN 'CopyJob' THEN 'pwsh -NoLogo -File backend/scripts/18_extract_item_object_lineage.ps1 -AzCommand az'
            WHEN 'DataPipeline' THEN 'pwsh -NoLogo -File backend/scripts/19_extract_pipeline_object_lineage.ps1 -AzCommand az'
            WHEN 'SemanticModel' THEN 'pwsh -NoLogo -File backend/scripts/09_enrich_semantic_model_views.ps1 -AzCommand az -MaxModels 120'
            ELSE '' END AS recommended_command,
        CASE
            WHEN definition_lookup_status_calc LIKE 'decoded%no_object_candidates' THEN 'Definition was already decoded but parser found no objects; inspect code/activities or owner evidence and improve parser if pattern repeats.'
            WHEN definition_lookup_status_calc LIKE '%unavailable%' THEN 'Definition access is unavailable; use Azure DevOps, SharePoint, OneLake, or owner-approved evidence.'
            ELSE 'Read definitions/metadata only, then confirm exact source objects in the manual evidence template.'
        END AS readonly_goal
    FROM (
        SELECT
            CASE
                WHEN e.item_type IN ('Notebook', 'CopyJob') THEN
                    CASE WHEN e.ig_status_code IS NULL THEN 'not_in_item_definition_gap_file'
                         WHEN e.ig_status_code = '200' AND ISNULL(e.ig_definition_parts,0) > 0 AND ISNULL(e.ig_candidate_count,0) = 0 THEN 'decoded_no_object_candidates'
                         WHEN e.ig_status_code = '200' AND ISNULL(e.ig_definition_parts,0) = 0 THEN 'definition_decoded_empty'
                         WHEN ISNULL(e.ig_error,'') <> '' THEN 'definition_read_error'
                         ELSE 'definition_review_required' END
                WHEN e.item_type = 'DataPipeline' THEN
                    CASE WHEN e.pg_status_code IS NULL THEN 'not_in_pipeline_gap_file'
                         WHEN e.pg_status_code = '200' AND ISNULL(e.pg_definition_parts,0) > 0 AND ISNULL(e.pg_activity_count,0) > 0 AND ISNULL(e.pg_candidate_count,0) = 0 THEN 'decoded_activities_no_object_candidates'
                         WHEN e.pg_status_code = '200' AND ISNULL(e.pg_definition_parts,0) = 0 THEN 'definition_decoded_empty'
                         WHEN ISNULL(e.pg_error,'') <> '' THEN 'definition_read_error'
                         ELSE 'pipeline_definition_review_required' END
                WHEN e.item_type = 'SemanticModel' THEN
                    CASE WHEN e.semantic_candidate_count > 0 THEN 'semantic_candidates_exist_but_item_still_blocked'
                         WHEN e.sg_status_code IS NOT NULL THEN CASE WHEN ISNULL(e.sg_error,'') <> '' THEN 'semantic_definition_unavailable' ELSE 'semantic_definition_gap_recorded' END
                         ELSE 'needs_tmdl_or_model_expression_review' END
                ELSE 'manual_definition_review_required'
            END AS definition_lookup_status_calc
    ) dd
) calc;

-- ===========================================================================
-- Manual evidence template: one row per parsed source dependency (or one
-- blank placeholder row when an item has none). Built BEFORE the queue
-- table so manual_template_row_count can be included directly instead of
-- an ALTER TABLE + UPDATE afterwards.
-- ===========================================================================
IF OBJECT_ID('tempdb..#dep_split') IS NOT NULL DROP TABLE #dep_split;
SELECT ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS dep_id,
    f.row_id, f.workspace_name, f.item_type, f.item_name, f.item_qualified_name, LTRIM(RTRIM(s.value)) AS dependency
INTO #dep_split
FROM #final f
CROSS APPLY STRING_SPLIT(f.source_dependencies, ';') s
WHERE LTRIM(RTRIM(s.value)) <> '';

-- The original splits each dependency on a REGEX "\s*/\s*" -- i.e. every
-- bare "/" (whitespace-absorbing), not just the space-slash-space that
-- separates a Fabric qualified name's own segments. For External
-- Connection / File / SharePoint dependencies whose last segment is
-- itself a path or URL full of bare "/", this matters: found live by
-- comparing against real data (source_name was coming out as the WHOLE
-- path instead of just the filename). STRING_SPLIT(..., '/', 1) with
-- ordinal + per-value TRIM replicates the same split points.
IF OBJECT_ID('tempdb..#dep_parts') IS NOT NULL DROP TABLE #dep_parts;
SELECT ds.dep_id, sp.ordinal, LTRIM(RTRIM(sp.value)) AS part
INTO #dep_parts
FROM #dep_split ds
CROSS APPLY STRING_SPLIT(ds.dependency, '/', 1) sp;

IF OBJECT_ID('tempdb..#dep_parts_agg') IS NOT NULL DROP TABLE #dep_parts_agg;
SELECT dep_id, COUNT(*) AS part_count,
    MAX(CASE WHEN ordinal = 1 THEN part END) AS part0,
    MAX(CASE WHEN ordinal = 2 THEN part END) AS part1,
    MAX(CASE WHEN ordinal = mx.max_ordinal THEN part END) AS last_part
INTO #dep_parts_agg
FROM #dep_parts dp
CROSS APPLY (SELECT MAX(ordinal) AS max_ordinal FROM #dep_parts dp2 WHERE dp2.dep_id = dp.dep_id) mx
GROUP BY dep_id;

IF OBJECT_ID('tempdb..#dep_parsed') IS NOT NULL DROP TABLE #dep_parsed;
SELECT ds.row_id, ds.workspace_name, ds.item_type, ds.item_name, ds.item_qualified_name,
    parsed.source_type, parsed.source_name, ds.dependency AS source_qualified_name
INTO #dep_parsed
FROM #dep_split ds
JOIN #dep_parts_agg pa ON pa.dep_id = ds.dep_id
CROSS APPLY (
    SELECT
        CASE
            WHEN pa.part_count = 1 THEN ''
            WHEN pa.part_count = 2 THEN pa.part0
            WHEN pa.part0 = 'External Connection' THEN 'External Connection'
            ELSE pa.part1
        END AS source_type,
        CASE
            WHEN pa.part_count = 1 THEN ds.dependency
            WHEN pa.part_count = 2 THEN pa.part1
            ELSE pa.last_part
        END AS source_name
) parsed;

IF OBJECT_ID('tempdb..#template_rows') IS NOT NULL DROP TABLE #template_rows;
SELECT row_id, workspace_name, item_type, item_name, item_qualified_name, source_type, source_name, source_qualified_name
INTO #template_rows
FROM (
    SELECT * FROM #dep_parsed
    UNION ALL
    SELECT f.row_id, f.workspace_name, f.item_type, f.item_name, f.item_qualified_name, '', '', ''
    FROM #final f
    WHERE NOT EXISTS (SELECT 1 FROM #dep_parsed dp WHERE dp.row_id = f.row_id)
) u;

SELECT
    workspace_name, item_type, item_name, item_qualified_name, source_type, source_name, source_qualified_name,
    '' AS source_server, '' AS source_database, '' AS schema_name, '' AS object_name, '' AS object_type,
    '' AS usage_type, '' AS confidence, '' AS evidence, '' AS reviewer, '' AS reviewed_at,
    'D1 template row. Duplicate this row for each confirmed table/view/stored procedure/file if one dependency contains multiple objects.' AS notes
INTO dbo.silver_d1_manual_lineage_evidence_template
FROM #template_rows;

IF OBJECT_ID('tempdb..#template_counts') IS NOT NULL DROP TABLE #template_counts;
SELECT row_id, COUNT(*) AS cnt INTO #template_counts FROM #template_rows GROUP BY row_id;

-- ===========================================================================
-- Final queue table.
-- ===========================================================================
SELECT
    f.priority_score, f.priority_band, f.workspace_name, f.workspace_environment, f.item_type, f.item_name, f.item_qualified_name,
    f.technical_id, f.coverage_status, f.gap_reason, f.coverage_next_action, f.source_dependency_count, f.source_dependencies,
    f.auto_object_evidence_count, f.manual_object_evidence_count, f.total_object_evidence_count, f.avg_duration_seconds,
    f.max_duration_seconds, f.failed_count, f.is_critical_path_candidate, f.is_failure_hotspot, f.v2_status, f.v2_recommended_next_action,
    f.definition_lookup_status, f.definition_status_code, f.definition_parts, f.definition_activity_count, f.definition_candidate_count,
    f.definition_error, f.definition_notes, f.parallel_missing_object_blocker_count, f.recommended_method, f.recommended_script,
    f.recommended_command,
    'Local parser output; Azure DevOps; SharePoint; OneLake; read-only Fabric/Power BI/SQL metadata; owner-approved manual evidence' AS recommended_evidence_sources,
    f.readonly_goal AS recommended_d1_action,
    'analysis/d1_manual_lineage_evidence_template.csv' AS manual_template_path,
    ISNULL(tc.cnt, 0) AS manual_template_row_count,
    'Every exact table/view/stored procedure/file/source object used by this item is recorded with confirmed evidence or the item is explicitly blocked.' AS d1_gate_to_close
INTO dbo.silver_d1_missing_object_lineage_queue
FROM #final f
LEFT JOIN #template_counts tc ON tc.row_id = f.row_id;

-- ===========================================================================
-- Read-only target items.
-- ===========================================================================
SELECT
    priority_score, priority_band, workspace_name, workspace_environment, item_type, item_name, item_qualified_name,
    definition_lookup_status, readonly_goal AS readonly_goal, recommended_script, recommended_command,
    'analysis/d1_manual_lineage_evidence_template.csv' AS manual_template_path,
    'Read-only target. Do not modify Fabric or source systems; use results only as evidence for object-level lineage.' AS notes
INTO dbo.silver_d1_readonly_target_items
FROM #final;

-- ===========================================================================
-- Summary.
-- ===========================================================================
SELECT summary_scope, group_key, queue_count, high_or_critical_count, max_priority_score, related_parallel_blocker_count, notes
INTO dbo.silver_d1_missing_object_lineage_summary
FROM (
    SELECT 'total' AS summary_scope, 'D1 missing object-level lineage' AS group_key, COUNT(*) AS queue_count,
        SUM(CASE WHEN priority_band IN ('critical', 'high') THEN 1 ELSE 0 END) AS high_or_critical_count,
        ISNULL(MAX(priority_score), 0) AS max_priority_score,
        ISNULL(SUM(parallel_missing_object_blocker_count), 0) AS related_parallel_blocker_count,
        'Item-level queue from analysis/likely_conflict_cleanup_queue.csv phase D1.' AS notes
    FROM dbo.silver_d1_missing_object_lineage_queue

    UNION ALL
    SELECT 'item_type', item_type, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), ISNULL(SUM(parallel_missing_object_blocker_count),0), 'D1 rows grouped by Fabric item type.'
    FROM dbo.silver_d1_missing_object_lineage_queue GROUP BY item_type

    UNION ALL
    SELECT 'workspace_environment', workspace_environment, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), ISNULL(SUM(parallel_missing_object_blocker_count),0), 'D1 rows grouped by environment.'
    FROM dbo.silver_d1_missing_object_lineage_queue GROUP BY workspace_environment

    UNION ALL
    SELECT 'priority_band', priority_band, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), ISNULL(SUM(parallel_missing_object_blocker_count),0), 'D1 rows grouped by priority band.'
    FROM dbo.silver_d1_missing_object_lineage_queue GROUP BY priority_band

    UNION ALL
    SELECT 'definition_lookup_status', definition_lookup_status, COUNT(*), SUM(CASE WHEN priority_band IN ('critical','high') THEN 1 ELSE 0 END),
        ISNULL(MAX(priority_score),0), ISNULL(SUM(parallel_missing_object_blocker_count),0), 'Shows whether read-only definition extraction already ran and why object evidence is still missing.'
    FROM dbo.silver_d1_missing_object_lineage_queue GROUP BY definition_lookup_status
) s;

END
