# Scripts

Scripts in this folder must default to read-only behavior.

## PowerShell/Python pairing convention

Two different `.ps1`/`.py` pairing patterns coexist in this folder. They look
similar but behave differently if Python is missing — know which one you're
editing:

- **PowerShell canonical, Python optional accelerator** (`*_fast.py` suffix):
  `11_build_lineage_explorer`, `17_build_object_impact_index`,
  `21_build_reverse_impact_package`. The `.ps1` file has the full, real
  implementation and is always correct on its own. At the top of the `.ps1`,
  a delegation block checks for a matching `*_fast.py` and a working
  `python3`/`python` on PATH; if both are present it re-execs the Python port
  (same output, much faster on large workspaces) and exits. If Python is
  unavailable, the script silently falls through to the native PowerShell
  implementation below the delegation block. **Changes to logic must be made
  in both files** — there is no automated parity test between them yet
  (tracked as a follow-up).
- **Python canonical, PowerShell is a thin wrapper** (no `_fast` suffix):
  `50_classify_unresolved_object_type_gaps`,
  `52_build_notebook_super_lineage`,
  `53_build_notebook_lineage_review_batches`,
  `54_build_notebook_code_deep_review`,
  `56_build_workspace_catalog_type_evidence`,
  `57_build_d4_next_evidence_gate_plan`,
  `58_backfill_semantic_sibling_source_targets`,
  `59_backfill_semantic_metadata_model_source_targets`,
  `60_backfill_semantic_catalog_model_source_targets`,
  `61_backfill_item_flow_source_targets`,
  `62_normalize_fabric_placeholder_paths`. Here the `.py` file holds the only
  real implementation (typically hundreds of lines); the `.ps1` is a
  15-30 line pass-through that just invokes `python3`/`python` on the `.py`
  file and propagates its exit code. **There is no PowerShell fallback** — if
  neither `python3` nor `python` is on PATH, these steps cannot run at all.
  This is an intentional tradeoff (avoids maintaining two implementations of
  logic that doesn't need PowerShell-specific behavior), not an oversight.

Expected order:

0. `00_preflight_tools.ps1`
1. `01_discover_workspaces.ps1`
2. `02_normalize_workspaces.ps1`
3. `03_discover_items.ps1`
4. `04_analyze_items.ps1`
5. `05_build_graph.ps1`
6. `06_discover_executions.ps1`
7. `07_optimize_orchestration.ps1`
8. `08_build_semantic_lineage.ps1`
9. `09_enrich_semantic_model_views.ps1`
10. `11_build_lineage_explorer.ps1`
11. `10_build_semantic_lineage_standalone.ps1`
12. `12_validate_lineage_visual.ps1`
13. `13_build_ideal_execution_plan.ps1`
14. `14_build_manual_lineage_review_queue.ps1`
15. `15_build_object_type_resolution_queue.ps1`
16. `16_discover_deployment_pipelines.ps1`
17. `17_build_object_impact_index.ps1`
18. `18_extract_item_object_lineage.ps1`
19. `19_extract_pipeline_object_lineage.ps1`
20. `20_extract_source_object_type_metadata.ps1`
21. `21_build_reverse_impact_package.ps1`
22. `22_build_evidence_hardening_queue.ps1`
23. `23_build_object_read_write_classification.ps1`
24. `24_build_orchestration_v2.ps1`
25. `25_build_likely_conflict_cleanup_plan.ps1`
26. `26_build_d1_missing_object_lineage_package.ps1`
27. `27_build_d2_likely_dependency_confirmation_package.ps1`
28. `28_build_d3_likely_object_lineage_confirmation_package.ps1`
29. `29_build_d4_exact_object_type_confirmation_package.ps1`
30. `30_build_d5_object_conflict_resolution_package.ps1`
31. `31_build_d6_failure_duration_stabilization_package.ps1`
32. `32_build_d7_orchestration_review_promotion_package.ps1`
33. `33_harden_object_lineage_candidates.ps1`
34. `34_extract_sql_endpoint_object_catalog.ps1`
99. `99_refresh_lineage_project.ps1`

Do not write to external systems from these scripts.

Phase 1 workspace discovery supports:
- `-AuthMethod auto`: try active Fabric CLI token first, then Azure CLI token.
- `-AuthMethod azure-cli`: use `az account get-access-token --resource https://api.fabric.microsoft.com` and Fabric REST.
- `-AuthMethod fabric-cli`: use `fab api`.

For the project container, prefer:

```powershell
az login --use-device-code --tenant <tenant-id> --allow-no-subscriptions
pwsh -NoLogo -File scripts/01_discover_workspaces.ps1 -AuthMethod azure-cli
```

Phase 2 workspace normalization:

```powershell
pwsh -NoLogo -File scripts/02_normalize_workspaces.ps1
```

If a previous run hit Fabric API throttling, retry only incomplete rows:

```powershell
pwsh -NoLogo -File scripts/02_normalize_workspaces.ps1 -OnlyPartial
```

Phase 3 item inventory:

```powershell
pwsh -NoLogo -File scripts/03_discover_items.ps1
```

If a run is interrupted or throttled, retry only failed workspaces:

```powershell
pwsh -NoLogo -File scripts/03_discover_items.ps1 -OnlyFailed
```

Phase 4 item analysis:

```powershell
pwsh -NoLogo -File scripts/04_analyze_items.ps1
```

The default Phase 4 run reads connections for all discovered items and retrieves item definitions only for lighter technical/orchestration types such as data pipelines, copy jobs, dataflows, eventstreams, Reflex, GraphQL APIs, KQL items, user data functions, and variable libraries. Reports, semantic models, notebooks, lakehouses, warehouses, SQL endpoints, dashboards, and paginated reports remain covered by connections and conservative heuristics unless a deeper approved batch is run.

Variable Library items also get their actual variables (name, type, value, per-value-set overrides) parsed out of the already-fetched definition into `analysis/variable_library_catalog.csv` -- no extra API call. `11_build_lineage_explorer_fast.py` / `NB_Build_Lineage_Explorer.py` attach that as a `variables` list on the item's own node, the same "child rows keyed by qualified_name" pattern as `object_column_catalog.csv`.

For a fully constrained connection-only run:

```powershell
pwsh -NoLogo -File scripts/04_analyze_items.ps1 -SkipDefinitions
```

Phase 5 graph build:

```powershell
pwsh -NoLogo -File scripts/05_build_graph.ps1
```

This is local-only. It rebuilds `graph/nodes.csv`, adds structural `contains` edges plus dependency edges to `graph/edges.csv`, writes graph metrics under `analysis/`, and refreshes the Mermaid summary diagram.

Phase 6 execution timing:

```powershell
pwsh -NoLogo -File scripts/06_discover_executions.ps1 -ProbeCandidateSchedules:$false
```

This reads Fabric Job Scheduler job instances and schedules for executable item types. Semantic model refresh history and refresh schedules are read through Power BI REST because the Fabric Job Scheduler endpoint does not expose those refresh records consistently. The script writes `index/executions.csv`, `analysis/execution_timing_summary.csv`, `analysis/execution_duration_by_item.csv`, and `analysis/execution_query_gaps.csv`.

Phase 7 orchestration optimization:

```powershell
pwsh -NoLogo -File scripts/07_optimize_orchestration.ps1
```

This is local-only. It analyzes dependencies, execution history, schedules, durations, failures, and unresolved gaps. It writes draft human-review recommendations to `analysis/orchestration_recommendations.csv` plus supporting candidate files and `analysis/orchestration_human_action_plan.md`. It does not modify Fabric.

Ideal execution pipeline plan:

```powershell
pwsh -NoLogo -File scripts/13_build_ideal_execution_plan.ps1
```

This is local-only. It converts the visual `Planificacion` proposal into execution-oriented waves using local dependencies, durations, schedules, failure hotspots, critical-path candidates, and candidate parallelism evidence. It writes `analysis/ideal_execution_plan.csv`, `analysis/ideal_execution_edges.csv`, `analysis/ideal_execution_waves.csv`, `analysis/ideal_execution_summary.csv`, `diagrams/ideal_execution_pipeline.mmd`, and `docs/13_ideal_execution_pipeline_design.md`. It does not trigger, schedule, or deploy Fabric items.

Manual lineage review queue:

```powershell
pwsh -NoLogo -File scripts/14_build_manual_lineage_review_queue.ps1
```

This is local-only. It lists semantic models, notebooks, and CopyJobs that need manual object-level review for tables, views, stored procedures, files, and source mappings. Human-reviewed evidence is recorded in `index/manual_lineage_object_evidence.csv` and then shown in the lineage explorer as manual evidence.

Object lineage candidate hardening:

```powershell
pwsh -NoLogo -File scripts/33_harden_object_lineage_candidates.ps1
```

This is local-only. It removes obvious parser noise from semantic model, notebook, CopyJob, and DataPipeline object candidates, and backfills source server/database only when the item has exactly one confirmed SQL dependency in `index/dependencies.csv`. It writes `analysis/object_lineage_candidate_hardening_review.csv`, `analysis/object_lineage_candidate_hardening_summary.csv`, and `docs/30_object_lineage_candidate_hardening.md`.

Source object type resolution queue:

```powershell
pwsh -NoLogo -File scripts/15_build_object_type_resolution_queue.ps1
```

This is local-only. It lists source objects still marked as `table_or_view` or `native_query_object`, applies exact type evidence from `index/source_object_type_overrides.csv`, `index/manual_lineage_object_evidence.csv`, and `analysis/source_object_type_metadata_evidence.csv`, and writes `analysis/source_object_type_resolution_queue.csv`, `analysis/source_object_type_resolution_summary.csv`, and `docs/15_object_type_resolution.md`.

Source object type metadata extraction:

```powershell
pwsh -NoLogo -File scripts/20_extract_source_object_type_metadata.ps1 -AzCommand az -TrustServerCertificate
```

This is read-only. It uses an Azure CLI database token to query SQL/Fabric `sys.objects`, writes exact type evidence to `analysis/source_object_type_metadata_evidence.csv`, and records unresolved access/schema/name gaps in `analysis/source_object_type_metadata_gaps.csv`.

Optional approved SQL auth can be supplied through temporary environment variables for specific SQL Server hosts:

```bash
export SQL_METADATA_HOST="<sql-server-host>"
export SQL_METADATA_USER="<approved-readonly-user>"
read -rs SQL_METADATA_PASSWORD
export SQL_METADATA_PASSWORD
export SQL_METADATA_PORT="1433"
pwsh -NoLogo -File scripts/20_extract_source_object_type_metadata.ps1 -AzCommand az -TrustServerCertificate -SourceServerFilter <sql-server-host>
unset SQL_METADATA_PASSWORD
```

Deployment pipeline discovery:

```powershell
pwsh -NoLogo -File scripts/16_discover_deployment_pipelines.ps1 -AzCommand az
```

This is read-only. It reads Fabric deployment pipelines and stages, matches stage workspaces back to the local workspace index by ID/name, and writes `index/deployment_pipelines.csv`, `index/deployment_pipeline_stages.csv`, `index/deployment_pipeline_stage_items.csv`, `analysis/deployment_pipeline_workspace_groups.csv`, and `analysis/deployment_pipeline_discovery_gaps.csv`.

Object impact index:

```powershell
pwsh -NoLogo -File scripts/17_build_object_impact_index.ps1
```

This is local-only. It reads `frontend/semantic-lineage/data/lineage-explorer.json` and writes the reverse-impact baseline:
- `analysis/object_impact_index.csv`
- `analysis/object_impact_summary.csv`
- `analysis/object_level_lineage_coverage.csv`
- `analysis/object_level_lineage_summary.csv`
- `docs/16_object_level_lineage_and_impact.md`

Reverse-impact visual package:

```powershell
pwsh -NoLogo -File scripts/21_build_reverse_impact_package.ps1
```

This is local-only. It reads the object impact CSVs plus `frontend/semantic-lineage/data/lineage-explorer.json`, attaches downstream reports from semantic models, and writes:
- `frontend/semantic-lineage/data/object-impact.json`
- `docs/18_reverse_impact_search.md`

SQL Endpoint object catalog:

```powershell
pwsh -NoLogo -File scripts/34_extract_sql_endpoint_object_catalog.ps1 -AzCommand az -TrustServerCertificate
```

This is read-only. It resolves Fabric SQL Endpoint/Warehouse targets from confirmed SQL dependencies and same-workspace seed hosts, queries `sys.objects`, and writes confirmed table, view, and stored-procedure catalog rows:
- `analysis/sql_endpoint_object_catalog.csv`
- `analysis/sql_endpoint_object_catalog_status.csv`
- `analysis/sql_endpoint_object_catalog_summary.csv`
- `docs/31_sql_endpoint_object_catalog.md`

When present, the reverse-impact package includes these catalog objects as searchable source objects. Catalog-only rows are shown separately from detected item-level impact.

Evidence hardening queue:

```powershell
pwsh -NoLogo -File scripts/22_build_evidence_hardening_queue.ps1
```

This is local-only. It consolidates weak dependency edges, missing object-level lineage, ambiguous object types, metadata access gaps, reverse-impact weak evidence, and orchestration v2 blockers into:
- `analysis/evidence_hardening_queue.csv`
- `analysis/evidence_hardening_summary.csv`
- `docs/19_evidence_hardening.md`

Object read/write classification:

```powershell
pwsh -NoLogo -File scripts/23_build_object_read_write_classification.ps1
```

This is local-only. It normalizes object-level lineage into read, write, execute, and unknown operations, joins evidence-hardening blockers and ideal-plan review flags, and writes:
- `analysis/object_read_write_classification.csv`
- `analysis/object_read_write_summary.csv`
- `docs/20_object_read_write_classification.md`

Orchestration optimization v2:

```powershell
pwsh -NoLogo -File scripts/24_build_orchestration_v2.ps1
```

This is local-only. It annotates the ideal execution plan with object-level read/write blockers, writer-reader guard constraints, object conflict rows, and re-evaluated parallel candidates. It writes:
- `analysis/orchestration_v2_plan.csv`
- `analysis/orchestration_v2_edges.csv`
- `analysis/orchestration_v2_waves.csv`
- `analysis/orchestration_v2_object_conflicts.csv`
- `analysis/orchestration_v2_parallel_candidates.csv`
- `analysis/orchestration_v2_summary.csv`
- `diagrams/orchestration_v2_pipeline.mmd`
- `docs/21_orchestration_v2_design.md`

Likely/conflict cleanup phase plan:

```powershell
pwsh -NoLogo -File scripts/25_build_likely_conflict_cleanup_plan.ps1
```

This is local-only. It breaks the remaining likely evidence and conflict cleanup into phased work and writes:
- `analysis/likely_conflict_cleanup_phase_plan.csv`
- `analysis/likely_conflict_cleanup_queue.csv`
- `analysis/likely_conflict_cleanup_summary.csv`
- `docs/22_likely_conflict_cleanup_plan.md`

D1 missing object-level lineage package:

```powershell
pwsh -NoLogo -File scripts/26_build_d1_missing_object_lineage_package.ps1
```

This is local-only. It turns D1 into a concrete work package for items that still need table/view/stored-procedure/file evidence and writes:
- `analysis/d1_missing_object_lineage_queue.csv`
- `analysis/d1_missing_object_lineage_summary.csv`
- `analysis/d1_manual_lineage_evidence_template.csv`
- `analysis/d1_readonly_target_items.csv`
- `docs/23_d1_missing_object_lineage.md`

Use the template as a staging file only. Copy rows into `index/manual_lineage_object_evidence.csv` only after exact object name, object type, usage type, confidence, evidence, reviewer, and review date are complete.

D2 likely dependency confirmation package:

```powershell
pwsh -NoLogo -File scripts/27_build_d2_likely_dependency_confirmation_package.ps1
```

This is local-only. It turns D2 into an item-level and edge-level confirmation package for likely dependency edges and writes:
- `analysis/d2_likely_dependency_item_queue.csv`
- `analysis/d2_likely_dependency_edge_queue.csv`
- `analysis/d2_likely_dependency_summary.csv`
- `analysis/d2_dependency_confirmation_template.csv`
- `analysis/d2_readonly_confirmation_targets.csv`
- `docs/24_d2_likely_dependency_confirmation.md`

Use the template as a staging file only. Do not promote `likely` dependencies to `confirmed` or `rejected` until every changed edge has confirmation status, source, evidence, reviewer, and reviewed date.

D3 likely object-lineage confirmation package:

```powershell
pwsh -NoLogo -File scripts/28_build_d3_likely_object_lineage_confirmation_package.ps1
```

This is local-only. It turns D3 into item-level and object-row-level confirmation work for likely read/write/execute lineage and writes:
- `analysis/d3_likely_object_lineage_item_queue.csv`
- `analysis/d3_likely_object_lineage_object_queue.csv`
- `analysis/d3_likely_object_lineage_summary.csv`
- `analysis/d3_object_lineage_confirmation_template.csv`
- `analysis/d3_readonly_object_lineage_targets.csv`
- `docs/25_d3_likely_object_lineage_confirmation.md`

Use the template as a staging file only. Do not promote likely object-lineage rows to confirmed or rejected until proposed status, source, evidence, reviewer, and reviewed date are complete. Exact object type cleanup remains D4 when the lineage is confirmed but the object type is still ambiguous.

D4 exact object-type confirmation package:

```powershell
pwsh -NoLogo -File scripts/29_build_d4_exact_object_type_confirmation_package.ps1
```

This is local-only. It turns D4 into source-object-level and impact-level work for resolving ambiguous source object types such as `table_or_view` and `native_query_object`. It writes:
- `analysis/d4_exact_object_type_source_queue.csv`
- `analysis/d4_exact_object_type_impact_queue.csv`
- `analysis/d4_exact_object_type_summary.csv`
- `analysis/d4_object_type_confirmation_template.csv`
- `analysis/d4_readonly_object_type_targets.csv`
- `docs/26_d4_exact_object_type_confirmation.md`

Use the template as a staging file only. Do not add object type overrides or promote exact types until proposed status, exact type, source, evidence, reviewer, and reviewed date are complete.

D5 object conflict resolution package:

```powershell
pwsh -NoLogo -File scripts/30_build_d5_object_conflict_resolution_package.ps1
```

This is local-only. It turns writer-reader, multi-writer, and execute dependency conflicts from orchestration v2 into conflict queues, guard-edge review rows, participant rows, and a decision template. It writes:
- `analysis/d5_object_conflict_queue.csv`
- `analysis/d5_object_guard_edge_queue.csv`
- `analysis/d5_object_conflict_participants.csv`
- `analysis/d5_object_conflict_summary.csv`
- `analysis/d5_object_conflict_decision_template.csv`
- `analysis/d5_readonly_conflict_review_targets.csv`
- `docs/27_d5_object_conflict_resolution.md`

Use the decision template as a staging file only. Do not remove guard edges, serialize writers, or promote parallelism until D3/D4 evidence is resolved and each conflict has a reviewed decision with evidence.

D6 failure and duration stabilization package:

```powershell
pwsh -NoLogo -File scripts/31_build_d6_failure_duration_stabilization_package.ps1
```

This is local-only. It turns failure holds and default/weak duration evidence into stabilization queues, execution evidence rows, and a decision template. It writes:
- `analysis/d6_failure_duration_queue.csv`
- `analysis/d6_failure_hotspot_queue.csv`
- `analysis/d6_duration_stabilization_queue.csv`
- `analysis/d6_execution_evidence.csv`
- `analysis/d6_failure_duration_summary.csv`
- `analysis/d6_stabilization_decision_template.csv`
- `analysis/d6_readonly_operational_review_targets.csv`
- `docs/28_d6_failure_duration_stabilization.md`

Use the decision template as a staging file only. Do not update schedules, triggers, retries, or orchestration rules until failures are stabilized or explicitly accepted and durations have observed or owner-approved evidence.

D7 orchestration review promotion package:

```powershell
pwsh -NoLogo -File scripts/32_build_d7_orchestration_review_promotion_package.ps1
```

This is local-only. It turns `needs_orchestration_review` rows from orchestration v2 into promotion queues, non-production candidate rows, wave review rows, and a decision template. It writes:
- `analysis/d7_orchestration_review_queue.csv`
- `analysis/d7_nonprod_candidate_queue.csv`
- `analysis/d7_wave_promotion_queue.csv`
- `analysis/d7_orchestration_review_summary.csv`
- `analysis/d7_promotion_decision_template.csv`
- `analysis/d7_readonly_promotion_targets.csv`
- `docs/29_d7_orchestration_review_promotion.md`

Use the decision template as a staging file only. Do not create or edit Fabric pipelines, schedules, triggers, deployment pipelines, or repositories until every selected row has owner approval and D1-D6 blockers are closed or explicitly accepted.

Notebook and CopyJob object extraction:

```powershell
pwsh -NoLogo -File scripts/18_extract_item_object_lineage.ps1 -AzCommand az
```

This is read-only. It reads Fabric item definitions for notebooks and CopyJobs, extracts table/view/stored-procedure/file candidates from decoded definition parts, and writes:
- `analysis/item_object_lineage_candidates.csv`
- `analysis/item_object_lineage_gaps.csv`

Long batches refresh the Azure CLI Fabric token and retry once when Fabric returns a token-expiration response.

DataPipeline activity object extraction:

```powershell
pwsh -NoLogo -File scripts/19_extract_pipeline_object_lineage.ps1 -AzCommand az
```

This is read-only. It reads Fabric DataPipeline definitions, extracts direct Copy activity source/sink object candidates, records activity-level lineage, detects invoked notebooks, CopyJobs, and nested pipelines, and inherits object evidence from those invoked items where local evidence exists. It writes:
- `analysis/pipeline_object_lineage_candidates.csv`
- `analysis/pipeline_activity_lineage.csv`
- `analysis/pipeline_object_lineage_gaps.csv`

Long batches refresh the Azure CLI Fabric token and retry once when Fabric returns a token-expiration response.

Lineage explorer data build:

```powershell
pwsh -NoLogo -File scripts/11_build_lineage_explorer.ps1
```

This is local-only. It builds `frontend/semantic-lineage/data/lineage-explorer.json` from the indexed workspaces, items, dependencies, execution history, semantic object candidates, item object candidates, pipeline activity object candidates, and explicit SQL-to-Fabric migration map. The visual uses this package for the workspace-filtered trees for semantic models, notebooks, CopyJobs, and pipelines.

Master refresh automation:

```powershell
pwsh -NoLogo -File scripts/99_refresh_lineage_project.ps1 -Mode local-artifacts
```

Modes:
- `local-artifacts`: rebuild graph, recommendations, semantic lineage JSON/docs, lineage explorer data, reverse-impact/evidence-hardening packages, and standalone HTML from current local indexes.
- `read-only-inventory`: refresh workspaces, deployment pipelines, items, item analysis, notebook/CopyJob/pipeline object extraction, graph, semantic lineage, lineage explorer data, and standalone through read-only Fabric APIs.
- `full-read-only`: also refresh execution history, schedules, durations, recommendations, and object extraction through read-only Fabric/Power BI APIs.

Optional semantic model TMDL enrichment:

```powershell
pwsh -NoLogo -File scripts/99_refresh_lineage_project.ps1 -Mode full-read-only -AuthMethod azure-cli -RunTmdlEnrichment -MaxTmdlModels 120
```

The master refresh writes:
- `analysis/lineage_refresh_manifest.json`
- `runs/lineage_refresh_YYYYMMDD_HHMMSS.md`

See `docs/12_automation_refresh.md`.

Visual browser validation:

```powershell
pwsh -NoLogo -File scripts/12_validate_lineage_visual.ps1
```

Integrated refresh plus visual validation:

```powershell
pwsh -NoLogo -File scripts/99_refresh_lineage_project.ps1 -Mode local-artifacts -RunVisualValidation
```

This is local-only. It uses Playwright and Chromium to open `frontend/semantic-lineage/standalone.html`, checks that the interactive flow is populated, verifies CopyJobs/filter/planning/reverse-impact interactions, and writes screenshots plus `analysis/visual-validation/playwright-results.json`.
