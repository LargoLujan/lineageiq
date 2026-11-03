# Phase 99 - Main orchestrator: runs every numbered phase script (00
# through 68, plus the notebook/pipeline/impact chain) in dependency order
# for a single full refresh. $Mode gates how much of the pipeline runs
# ("local-artifacts" = local-only rebuilds, "read-only-inventory"/
# "full-read-only" = also make live Fabric API calls). -WorkspaceNameFilter
# forwards to every step that supports it, so a single-workspace run
# reaches the exact same max scan depth as a tenant-wide one (see each
# step's own filter handling) while leaving every other workspace's rows
# untouched. This is what both the "Escaneo completo" web button and any
# scheduled weekly run invoke.
param(
    [ValidateSet("local-artifacts", "read-only-inventory", "full-read-only")]
    [string]$Mode = "local-artifacts",
    [ValidateSet("auto", "fabric-cli", "azure-cli")]
    [string]$AuthMethod = "azure-cli",
    [string]$AzCommand = "az",
    [switch]$RunTmdlEnrichment,
    [int]$MaxTmdlModels = 80,
    [switch]$SkipOptimization,
    [switch]$SkipStandalone,
    [switch]$RunVisualValidation,
    [string]$ManifestPath = (Join-Path $PSScriptRoot "../../analysis/lineage_refresh_manifest.json"),
    [string]$RunLogDirectory = (Join-Path $PSScriptRoot "../../runs"),
    [string]$ProgressPath = (Join-Path $PSScriptRoot "../../analysis/single_workspace_scan/progress.json"),
    [switch]$PublishBronze,
    [string]$LakehouseConfig = (Join-Path $PSScriptRoot "../../config/lakehouse_target.json"),
    # Opt-in, off by default: publishes the just-rebuilt big JSON payloads
    # (lineage-explorer.json and friends) to OneLake Files, so a web
    # server reading them live (onelake_data.mode = "onelake") sees this
    # run's fresh data -- see docs/106_onelake_web_data_publish.md. A
    # completely different destination than -PublishBronze (a Lakehouse's
    # Files area, not the Warehouse's SQL tables), independent switch on
    # purpose.
    [switch]$PublishWebData,
    [string]$AdminSettingsPath = (Join-Path $PSScriptRoot "../../config/admin_settings.json"),
    # Forwarded to backend/scripts/04_analyze_items.ps1's own -SkipReportDefinitions
    # switch. Default policy for this project is maximum scan depth (this
    # orchestrator runs weekly, not interactively), so Report/PaginatedReport
    # definition fetches are ON by default there; this only exists to skip
    # them for a quick/local test run.
    [switch]$SkipReportDefinitions,
    [string]$WorkspaceNameFilter = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# D.0 (2026-07-08 revision pass): every child-script path this orchestrator
# invokes below was a bare "backend/scripts/xxx.ps1" string, resolved against
# whatever the caller's current directory happened to be rather than this
# script's own location -- worked only by convention (always invoked from
# the repo root), broke silently otherwise. $script:RepoRoot anchors every
# such reference below to this file's real location instead.
$script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

# Mirrors the exact same $Mode/$SkipOptimization/$SkipStandalone/
# $RunTmdlEnrichment/$RunVisualValidation branching used below to run the
# real steps, just to get a step COUNT instead of running them -- this is
# what turns "step 42 just started" into a percentage for the progress bar.
# It only drifts from reality if a step is added/removed/re-gated below
# without updating this block too; a plain count of Invoke-LineageStep
# calls could not replace this because that count varies by which flags a
# given run actually passed (this script gets invoked with many different
# -Mode/flag combinations across the project, not just one fixed shape).
$script:TotalSteps = 0
if ($Mode -in @("read-only-inventory", "full-read-only")) {
    # 20 = the 18 pre-existing steps in that branch (the old value of 17 had
    # drifted by one) + Fabric connections discovery (69) + control-framework
    # runtime lineage extraction (70), both added 2026-07-17.
    $script:TotalSteps += 20
}
else {
    $script:TotalSteps += 1
    if (Test-Path (Join-Path $PSScriptRoot "../../analysis/notebook_definition_download_manifest.csv")) {
        $script:TotalSteps += 3
    }
}
$script:TotalSteps += 1
if ($Mode -eq "full-read-only") { $script:TotalSteps += 1 }
if (-not $SkipOptimization) { $script:TotalSteps += 2 }
$script:TotalSteps += 6
if ($RunTmdlEnrichment) { $script:TotalSteps += 6 }
$script:TotalSteps += 40
if (-not $SkipOptimization) { $script:TotalSteps += 1 }
$script:TotalSteps += 3
if (-not $SkipStandalone) { $script:TotalSteps += 2 }
if ($RunVisualValidation) { $script:TotalSteps += 1 }
if ($PublishBronze) { $script:TotalSteps += 1 }
if ($PublishWebData) { $script:TotalSteps += 1 }

function Write-ScanProgress {
    param([string]$CurrentStepName, [string]$Phase = "running")

    $progress = [pscustomobject]@{
        scan_kind = "full"
        workspace = "__full_scan__"
        completed_steps = $script:StepResults.Count
        total_steps = $script:TotalSteps
        current_step_name = $CurrentStepName
        phase = $Phase
        updated_at = (Get-Date).ToString("o")
        # Every step completed so far -- lineage_web_server.py reads this to
        # work out step_count/degraded_step_count/failed_step for the
        # history.csv row it writes once this process exits, including when
        # it was force-killed mid-step by a stop request.
        steps = @($script:StepResults)
    }
    $parent = Split-Path -Parent $ProgressPath
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
    $progress | ConvertTo-Json -Depth 6 | Set-Content -Path $ProgressPath -Encoding UTF8
}

function Ensure-Directory {
    param([string]$Path)
    if ($Path -and -not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Invoke-LineageStep {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    # A bare relative $ScriptPath (the normal case -- every call site below
    # passes "backend/scripts/xxx.ps1") resolves against $script:RepoRoot, not
    # $PWD; an already-absolute path (or one some future caller resolved
    # itself) passes through unchanged.
    $resolvedScriptPath = if ([System.IO.Path]::IsPathRooted($ScriptPath)) { $ScriptPath } else { Join-Path $script:RepoRoot $ScriptPath }
    if (-not (Test-Path $resolvedScriptPath)) {
        throw "Required script not found: $resolvedScriptPath"
    }

    Write-Host ""
    Write-Host "==> $Name"
    Write-ScanProgress -CurrentStepName $Name
    $started = Get-Date
    $status = "completed"
    $errorText = ""

    try {
        & pwsh -NoLogo -File $resolvedScriptPath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$ScriptPath exited with code $LASTEXITCODE"
        }
    }
    catch {
        $status = "failed"
        $errorText = $_.Exception.Message
        throw
    }
    finally {
        $ended = Get-Date
        $script:StepResults.Add([pscustomobject]@{
            name = $Name
            script = $ScriptPath
            arguments = ($Arguments -join " ")
            status = $status
            started_at = $started.ToString("s")
            ended_at = $ended.ToString("s")
            duration_seconds = [math]::Round(($ended - $started).TotalSeconds, 3)
            error = $errorText
        }) | Out-Null
    }
}

function Get-FileSummary {
    param([string[]]$Paths)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $Paths) {
        if (Test-Path $path) {
            $item = Get-Item $path
            $lineCount = 0
            if (-not $item.PSIsContainer) {
                try {
                    $lineCount = [System.Linq.Enumerable]::Count([System.IO.File]::ReadLines((Resolve-Path $path).Path))
                }
                catch {
                    $lineCount = 0
                }
            }
            $rows.Add([pscustomobject]@{
                path = $path
                exists = $true
                bytes = if ($item.PSIsContainer) { 0 } else { $item.Length }
                lines = $lineCount
                modified_at = $item.LastWriteTime.ToString("s")
            }) | Out-Null
        }
        else {
            $rows.Add([pscustomobject]@{
                path = $path
                exists = $false
                bytes = 0
                lines = 0
                modified_at = ""
            }) | Out-Null
        }
    }
    return $rows
}

$startedAt = Get-Date
$StepResults = [System.Collections.Generic.List[object]]::new()
Ensure-ParentDirectory -Path $ManifestPath
Ensure-Directory -Path $RunLogDirectory

$runStamp = $startedAt.ToString("yyyyMMdd_HHmmss")
$runLogPath = Join-Path $RunLogDirectory "lineage_refresh_$runStamp.md"

$readOnlyNote = "This orchestrator only runs local scripts and read-only Fabric/Power BI API discovery scripts. It does not create, update, or delete Fabric items."
Write-Host $readOnlyNote
Write-Host "Mode: $Mode"

# Scopes every sub-step below that supports -WorkspaceNameFilter to just
# these workspaces when set (see docs/102_admin_panel_and_user_auth.md) --
# each of those steps already retains every other workspace's existing rows
# unchanged, so a signed-in user's "full scan" only ever refreshes what
# their own Fabric access covers, never the whole tenant on their behalf.
# Empty (the default, and the only value ever used from a terminal) means
# every step below runs completely unscoped, exactly as before.
$wsFilterArgs = if ($WorkspaceNameFilter) { @("-WorkspaceNameFilter", $WorkspaceNameFilter) } else { @() }
$reportDefinitionArgs = if ($SkipReportDefinitions) { @("-SkipReportDefinitions") } else { @() }
if ($WorkspaceNameFilter) {
    Write-Host "Workspace filter: $WorkspaceNameFilter"
}

try {
    if ($Mode -in @("read-only-inventory", "full-read-only")) {
        Invoke-LineageStep -Name "Phase 0.5 tooling preflight" -ScriptPath "backend/scripts/00_preflight_tools.ps1"
        Invoke-LineageStep -Name "Phase 1 workspace discovery" -ScriptPath "backend/scripts/01_discover_workspaces.ps1" -Arguments @("-AuthMethod", $AuthMethod, "-AzCommand", $AzCommand)
        Invoke-LineageStep -Name "Phase 2 workspace normalization" -ScriptPath "backend/scripts/02_normalize_workspaces.ps1" -Arguments @("-AzCommand", $AzCommand)
        Invoke-LineageStep -Name "Fabric connections discovery" -ScriptPath "backend/scripts/69_discover_fabric_connections.ps1" -Arguments @("-AzCommand", $AzCommand)
        Invoke-LineageStep -Name "Deployment pipeline discovery" -ScriptPath "backend/scripts/16_discover_deployment_pipelines.ps1" -Arguments @("-AzCommand", $AzCommand, "-IncludeStageItems")
        Invoke-LineageStep -Name "Workspace Git connection discovery" -ScriptPath "backend/scripts/67_discover_workspace_git_connections.ps1" -Arguments (@("-AzCommand", $AzCommand) + $wsFilterArgs)
        Invoke-LineageStep -Name "Workspace role assignment discovery" -ScriptPath "backend/scripts/68_discover_workspace_role_assignments.ps1" -Arguments (@("-AzCommand", $AzCommand) + $wsFilterArgs)
        Invoke-LineageStep -Name "Phase 3 item inventory" -ScriptPath "backend/scripts/03_discover_items.ps1" -Arguments (@("-AzCommand", $AzCommand) + $wsFilterArgs)
        Invoke-LineageStep -Name "Phase 4 item analysis" -ScriptPath "backend/scripts/04_analyze_items.ps1" -Arguments (@("-AzCommand", $AzCommand) + $wsFilterArgs + $reportDefinitionArgs)
        Invoke-LineageStep -Name "Object-level notebook, CopyJob, and Dataflow extraction" -ScriptPath "backend/scripts/18_extract_item_object_lineage.ps1" -Arguments (@("-AzCommand", $AzCommand) + $wsFilterArgs)
        Invoke-LineageStep -Name "Notebook definition download" -ScriptPath "backend/scripts/51_download_notebook_definitions.ps1" -Arguments (@("-AzCommand", $AzCommand) + $wsFilterArgs)
        Invoke-LineageStep -Name "Notebook super-lineage extraction" -ScriptPath "backend/scripts/52_build_notebook_super_lineage.ps1" -Arguments $wsFilterArgs
        Invoke-LineageStep -Name "Notebook lineage review batch rebuild" -ScriptPath "backend/scripts/53_build_notebook_lineage_review_batches.ps1"
        Invoke-LineageStep -Name "Notebook code deep review rebuild" -ScriptPath "backend/scripts/54_build_notebook_code_deep_review.ps1"
        Invoke-LineageStep -Name "Object-level DataPipeline activity extraction" -ScriptPath "backend/scripts/19_extract_pipeline_object_lineage.ps1" -Arguments (@("-AzCommand", $AzCommand) + $wsFilterArgs)
        Invoke-LineageStep -Name "Object lineage candidate hardening" -ScriptPath "backend/scripts/33_harden_object_lineage_candidates.ps1"
        Invoke-LineageStep -Name "Source object type metadata extraction" -ScriptPath "backend/scripts/20_extract_source_object_type_metadata.ps1" -Arguments (@("-AzCommand", $AzCommand, "-TrustServerCertificate") + $wsFilterArgs)
        Invoke-LineageStep -Name "SQL endpoint object catalog extraction" -ScriptPath "backend/scripts/34_extract_sql_endpoint_object_catalog.ps1" -Arguments (@("-AzCommand", $AzCommand, "-TrustServerCertificate") + $wsFilterArgs)
        Invoke-LineageStep -Name "Control-framework runtime lineage extraction" -ScriptPath "backend/scripts/70_extract_control_framework_lineage.ps1" -Arguments @("-AzCommand", $AzCommand)
        Invoke-LineageStep -Name "Object column catalog extraction" -ScriptPath "backend/scripts/63_extract_object_column_catalog.ps1" -Arguments (@("-AzCommand", $AzCommand, "-TrustServerCertificate") + $wsFilterArgs)
    }
    else {
        Invoke-LineageStep -Name "Object lineage candidate hardening" -ScriptPath "backend/scripts/33_harden_object_lineage_candidates.ps1"
        if (Test-Path (Join-Path $PSScriptRoot "../../analysis/notebook_definition_download_manifest.csv")) {
            Invoke-LineageStep -Name "Notebook super-lineage extraction" -ScriptPath "backend/scripts/52_build_notebook_super_lineage.ps1"
            Invoke-LineageStep -Name "Notebook lineage review batch rebuild" -ScriptPath "backend/scripts/53_build_notebook_lineage_review_batches.ps1"
            Invoke-LineageStep -Name "Notebook code deep review rebuild" -ScriptPath "backend/scripts/54_build_notebook_code_deep_review.ps1"
        }
    }

    Invoke-LineageStep -Name "Phase 5 graph rebuild" -ScriptPath "backend/scripts/05_build_graph.ps1"

    if ($Mode -eq "full-read-only") {
        Invoke-LineageStep -Name "Phase 6 execution timing refresh" -ScriptPath "backend/scripts/06_discover_executions.ps1" -Arguments (@("-AzCommand", $AzCommand, "-ProbeCandidateSchedules:`$false") + $wsFilterArgs)
    }

    if (-not $SkipOptimization) {
        Invoke-LineageStep -Name "Phase 7 orchestration recommendation rebuild" -ScriptPath "backend/scripts/07_optimize_orchestration.ps1"
        Invoke-LineageStep -Name "Phase 13 ideal execution plan rebuild" -ScriptPath "backend/scripts/13_build_ideal_execution_plan.ps1"
    }

    Invoke-LineageStep -Name "Manual lineage review queue rebuild" -ScriptPath "backend/scripts/14_build_manual_lineage_review_queue.ps1"
    Invoke-LineageStep -Name "D4 semantic sibling source target backfill" -ScriptPath "backend/scripts/58_backfill_semantic_sibling_source_targets.ps1" -Arguments @("-Apply")
    Invoke-LineageStep -Name "D4 semantic metadata/model source target backfill" -ScriptPath "backend/scripts/59_backfill_semantic_metadata_model_source_targets.ps1" -Arguments @("-Apply")
    Invoke-LineageStep -Name "D4 semantic catalog/model source target backfill" -ScriptPath "backend/scripts/60_backfill_semantic_catalog_model_source_targets.ps1" -Arguments @("-Apply")
    Invoke-LineageStep -Name "D4 item flow source target backfill" -ScriptPath "backend/scripts/61_backfill_item_flow_source_targets.ps1" -Arguments @("-Apply")
    Invoke-LineageStep -Name "Source object type resolution queue rebuild" -ScriptPath "backend/scripts/15_build_object_type_resolution_queue.ps1"

    if ($RunTmdlEnrichment) {
        Invoke-LineageStep -Name "Phase 8 TMDL semantic object enrichment" -ScriptPath "backend/scripts/09_enrich_semantic_model_views.ps1" -Arguments @("-AzCommand", $AzCommand, "-MaxModels", [string]$MaxTmdlModels)
        Invoke-LineageStep -Name "D4 semantic sibling source target backfill after TMDL enrichment" -ScriptPath "backend/scripts/58_backfill_semantic_sibling_source_targets.ps1" -Arguments @("-Apply")
        Invoke-LineageStep -Name "D4 semantic metadata/model source target backfill after TMDL enrichment" -ScriptPath "backend/scripts/59_backfill_semantic_metadata_model_source_targets.ps1" -Arguments @("-Apply")
        Invoke-LineageStep -Name "D4 semantic catalog/model source target backfill after TMDL enrichment" -ScriptPath "backend/scripts/60_backfill_semantic_catalog_model_source_targets.ps1" -Arguments @("-Apply")
        Invoke-LineageStep -Name "D4 item flow source target backfill after TMDL enrichment" -ScriptPath "backend/scripts/61_backfill_item_flow_source_targets.ps1" -Arguments @("-Apply")
        Invoke-LineageStep -Name "Source object type resolution queue rebuild after semantic source target backfills" -ScriptPath "backend/scripts/15_build_object_type_resolution_queue.ps1"
    }

    Invoke-LineageStep -Name "Phase 8 semantic lineage package rebuild" -ScriptPath "backend/scripts/08_build_semantic_lineage.ps1"
    Invoke-LineageStep -Name "Workspace lineage explorer data rebuild" -ScriptPath "backend/scripts/11_build_lineage_explorer.ps1"
    Invoke-LineageStep -Name "Object impact index rebuild" -ScriptPath "backend/scripts/17_build_object_impact_index.ps1"
    Invoke-LineageStep -Name "Reverse impact package rebuild" -ScriptPath "backend/scripts/21_build_reverse_impact_package.ps1"
    # Graph Map Mode's own index (graph-map-index.json/graph-map-index-
    # objects.json) -- reads object-impact.json/lineage-explorer.json just
    # rebuilt above as input, so it must run after both, not before. Was
    # never actually wired into this orchestrator before 2026-07-24 despite
    # the -PublishWebData comment below assuming it was.
    Invoke-LineageStep -Name "Graph Map index rebuild" -ScriptPath "backend/scripts/build_graph_map_index.ps1"
    Invoke-LineageStep -Name "Fabric placeholder/path normalization" -ScriptPath "backend/scripts/62_normalize_fabric_placeholder_paths.ps1"
    Invoke-LineageStep -Name "Evidence hardening queue rebuild" -ScriptPath "backend/scripts/22_build_evidence_hardening_queue.ps1"
    Invoke-LineageStep -Name "Object read/write classification rebuild" -ScriptPath "backend/scripts/23_build_object_read_write_classification.ps1"
    Invoke-LineageStep -Name "Orchestration optimization v2 rebuild" -ScriptPath "backend/scripts/24_build_orchestration_v2.ps1"
    Invoke-LineageStep -Name "Likely/conflict cleanup plan rebuild" -ScriptPath "backend/scripts/25_build_likely_conflict_cleanup_plan.ps1"
    Invoke-LineageStep -Name "D1 missing object-level lineage package rebuild" -ScriptPath "backend/scripts/26_build_d1_missing_object_lineage_package.ps1"
    Invoke-LineageStep -Name "D1 closure control rebuild" -ScriptPath "backend/scripts/39_build_d1_closure_control.ps1"
    Invoke-LineageStep -Name "D2 likely dependency confirmation package rebuild" -ScriptPath "backend/scripts/27_build_d2_likely_dependency_confirmation_package.ps1"
    Invoke-LineageStep -Name "D2 closure control rebuild" -ScriptPath "backend/scripts/40_build_d2_closure_control.ps1"
    Invoke-LineageStep -Name "D3 likely object-lineage confirmation package rebuild" -ScriptPath "backend/scripts/28_build_d3_likely_object_lineage_confirmation_package.ps1"
    Invoke-LineageStep -Name "D3 closure control rebuild" -ScriptPath "backend/scripts/41_build_d3_closure_control.ps1"
    Invoke-LineageStep -Name "D4 exact object-type confirmation package rebuild" -ScriptPath "backend/scripts/29_build_d4_exact_object_type_confirmation_package.ps1"
    Invoke-LineageStep -Name "D4 closure control rebuild" -ScriptPath "backend/scripts/42_build_d4_closure_control.ps1"
    Invoke-LineageStep -Name "D4 workspace catalog type backfill" -ScriptPath "backend/scripts/56_build_workspace_catalog_type_evidence.ps1" -Arguments @("-MergeMetadata")
    Invoke-LineageStep -Name "D4 semantic metadata/model source target backfill after workspace catalog" -ScriptPath "backend/scripts/59_backfill_semantic_metadata_model_source_targets.ps1" -Arguments @("-Apply")
    Invoke-LineageStep -Name "D4 semantic catalog/model source target backfill after workspace catalog" -ScriptPath "backend/scripts/60_backfill_semantic_catalog_model_source_targets.ps1" -Arguments @("-Apply")
    Invoke-LineageStep -Name "D4 item flow source target backfill after workspace catalog" -ScriptPath "backend/scripts/61_backfill_item_flow_source_targets.ps1" -Arguments @("-Apply")
    Invoke-LineageStep -Name "Source object type resolution queue rebuild after D4 backfill" -ScriptPath "backend/scripts/15_build_object_type_resolution_queue.ps1"
    Invoke-LineageStep -Name "Evidence hardening queue rebuild after D4 backfill" -ScriptPath "backend/scripts/22_build_evidence_hardening_queue.ps1"
    Invoke-LineageStep -Name "Object read/write classification rebuild after D4 backfill" -ScriptPath "backend/scripts/23_build_object_read_write_classification.ps1"
    Invoke-LineageStep -Name "Orchestration optimization v2 rebuild after D4 backfill" -ScriptPath "backend/scripts/24_build_orchestration_v2.ps1"
    Invoke-LineageStep -Name "Likely/conflict cleanup plan rebuild after D4 backfill" -ScriptPath "backend/scripts/25_build_likely_conflict_cleanup_plan.ps1"
    Invoke-LineageStep -Name "D4 exact object-type confirmation package rebuild after backfill" -ScriptPath "backend/scripts/29_build_d4_exact_object_type_confirmation_package.ps1"
    Invoke-LineageStep -Name "D4 closure control rebuild after backfill" -ScriptPath "backend/scripts/42_build_d4_closure_control.ps1"
    Invoke-LineageStep -Name "E2 unresolved object-type gap classification rebuild" -ScriptPath "backend/scripts/50_classify_unresolved_object_type_gaps.ps1"
    Invoke-LineageStep -Name "D4 next evidence gate plan rebuild" -ScriptPath "backend/scripts/57_build_d4_next_evidence_gate_plan.ps1"
    Invoke-LineageStep -Name "D5 object conflict resolution package rebuild" -ScriptPath "backend/scripts/30_build_d5_object_conflict_resolution_package.ps1"
    Invoke-LineageStep -Name "D5 closure control rebuild" -ScriptPath "backend/scripts/43_build_d5_closure_control.ps1"
    Invoke-LineageStep -Name "D6 failure and duration stabilization package rebuild" -ScriptPath "backend/scripts/31_build_d6_failure_duration_stabilization_package.ps1"
    Invoke-LineageStep -Name "D6 closure control rebuild" -ScriptPath "backend/scripts/44_build_d6_closure_control.ps1"
    Invoke-LineageStep -Name "D7 orchestration review promotion package rebuild" -ScriptPath "backend/scripts/32_build_d7_orchestration_review_promotion_package.ps1"
    Invoke-LineageStep -Name "D7 closure control rebuild" -ScriptPath "backend/scripts/45_build_d7_closure_control.ps1"
    Invoke-LineageStep -Name "D8 parallel candidate retest package rebuild" -ScriptPath "backend/scripts/46_build_d8_parallel_candidate_retest_package.ps1"
    Invoke-LineageStep -Name "E1 deep evidence sweep plan rebuild" -ScriptPath "backend/scripts/47_build_deep_evidence_sweep_plan.ps1"
    Invoke-LineageStep -Name "Phase 12 deep object lineage enrichment rebuild" -ScriptPath "backend/scripts/38_build_deep_object_lineage_enrichment.ps1"

    if (-not $SkipOptimization) {
        Invoke-LineageStep -Name "Phase 13 ideal execution plan rebuild with Phase 12 gates" -ScriptPath "backend/scripts/13_build_ideal_execution_plan.ps1"
    }

    Invoke-LineageStep -Name "Phase 9 multi-criteria explorer model rebuild" -ScriptPath "backend/scripts/35_build_multi_criteria_lineage_model.ps1"
    $governanceArgs = if ($Mode -eq "local-artifacts") { @() } else { @("-UseReadOnlyApis", "-AzCommand", $AzCommand) }
    Invoke-LineageStep -Name "Phase 11 workspace governance enrichment rebuild" -ScriptPath "backend/scripts/37_build_workspace_governance_devops_enrichment.ps1" -Arguments $governanceArgs
    Invoke-LineageStep -Name "Phase 12 deep object lineage explorer injection" -ScriptPath "backend/scripts/38_build_deep_object_lineage_enrichment.ps1"

    if (-not $SkipStandalone) {
        Invoke-LineageStep -Name "Standalone lineage explorer rebuild" -ScriptPath "backend/scripts/10_build_semantic_lineage_standalone.ps1"
        Invoke-LineageStep -Name "Standalone multi-criteria explorer rebuild" -ScriptPath "backend/scripts/36_build_multi_criteria_lineage_standalone.ps1"
    }

    if ($RunVisualValidation) {
        Invoke-LineageStep -Name "Browser visual validation" -ScriptPath "backend/scripts/12_validate_lineage_visual.ps1"
    }

    # Opt-in, off by default: uploads the current CSVs into the project's
    # own Fabric Lakehouse as a dated Bronze partition (see
    # docs/101_medallion_lakehouse_provisioning.md) -- never the tenant
    # workspaces this run just scanned. Invoke-LineageStep in this script
    # has no -ContinueOnFailure of its own (any failing step here normally
    # aborts the whole multi-hour run), so this step gets its own try/catch
    # instead: a Lakehouse upload problem (e.g. the config still has no
    # workspace/lakehouse filled in) must never throw away hours of real
    # tenant scanning work.
    if ($PublishBronze) {
        try {
            Invoke-LineageStep -Name "Bronze upload to OneLake (64)" -ScriptPath "backend/scripts/64_upload_bronze_to_onelake.ps1" -Arguments @("-LakehouseConfig", $LakehouseConfig)
        }
        catch {
            Write-Host "Bronze upload degraded (continuing): $($_.Exception.Message)"
        }
    }

    # Same "never throw away hours of real scanning work over a publish
    # problem" reasoning as -PublishBronze above -- own try/catch, runs
    # last so it publishes whatever this run just rebuilt (11/21/52/
    # build_graph_map_index.py all already ran earlier in this same
    # pipeline).
    if ($PublishWebData) {
        try {
            Invoke-LineageStep -Name "Web data publish to OneLake (72)" -ScriptPath "backend/scripts/72_publish_web_data_to_onelake.ps1" -Arguments @("-AdminSettingsPath", $AdminSettingsPath)
        }
        catch {
            Write-Host "Web data publish degraded (continuing): $($_.Exception.Message)"
        }
    }
}
finally {
    $endedAt = Get-Date
    $importantFiles = @(
        "index/workspaces.csv",
        "index/items.csv",
        "index/item_analysis.csv",
        "index/dependencies.csv",
        "index/executions.csv",
        "graph/nodes.csv",
        "graph/edges.csv",
        "analysis/orchestration_recommendations.csv",
        "analysis/ideal_execution_plan.csv",
        "analysis/ideal_execution_edges.csv",
        "analysis/ideal_execution_waves.csv",
        "analysis/ideal_execution_summary.csv",
        "diagrams/ideal_execution_pipeline.mmd",
        "docs/13_ideal_execution_pipeline_design.md",
        "analysis/workspace_governance_enrichment.csv",
        "analysis/workspace_governance_principals.csv",
        "analysis/workspace_deployment_pipeline_membership.csv",
        "analysis/workspace_devops_link_candidates.csv",
        "analysis/workspace_governance_devops_gaps.csv",
        "archive/lineage-explorer/data/workspace-governance.json",
        "analysis/deep_object_lineage_item_enrichment.csv",
        "analysis/deep_object_lineage_source_objects.csv",
        "analysis/deep_object_lineage_gaps.csv",
        "archive/lineage-explorer/data/deep-object-lineage.json",
        "docs/33_deep_object_lineage_enrichment.md",
        "archive/lineage-explorer/data/lineage-explorer.json",
        "archive/lineage-explorer/standalone.html",
        "index/manual_lineage_object_evidence.csv",
        "analysis/manual_lineage_review_queue.csv",
        "analysis/manual_lineage_review_summary.csv",
        "docs/14_manual_lineage_review.md",
        "index/source_object_type_overrides.csv",
        "analysis/object_lineage_candidate_hardening_review.csv",
        "analysis/object_lineage_candidate_hardening_summary.csv",
        "docs/30_object_lineage_candidate_hardening.md",
        "analysis/source_object_type_metadata_evidence.csv",
        "analysis/source_object_type_metadata_gaps.csv",
        "analysis/source_object_type_metadata_summary.csv",
        "docs/17_source_object_type_metadata.md",
        "analysis/source_object_type_resolution_queue.csv",
        "analysis/source_object_type_resolution_summary.csv",
        "docs/15_object_type_resolution.md",
        "analysis/sql_endpoint_object_catalog.csv",
        "analysis/sql_endpoint_object_catalog_status.csv",
        "analysis/sql_endpoint_object_catalog_summary.csv",
        "docs/31_sql_endpoint_object_catalog.md",
        "analysis/object_impact_index.csv",
        "analysis/object_impact_summary.csv",
        "frontend/semantic-lineage/data/object-impact.json",
        "docs/18_reverse_impact_search.md",
        "analysis/evidence_hardening_queue.csv",
        "analysis/evidence_hardening_summary.csv",
        "docs/19_evidence_hardening.md",
        "analysis/object_read_write_classification.csv",
        "analysis/object_read_write_summary.csv",
        "docs/20_object_read_write_classification.md",
        "analysis/orchestration_v2_plan.csv",
        "analysis/orchestration_v2_edges.csv",
        "analysis/orchestration_v2_waves.csv",
        "analysis/orchestration_v2_object_conflicts.csv",
        "analysis/orchestration_v2_parallel_candidates.csv",
        "analysis/orchestration_v2_summary.csv",
        "diagrams/orchestration_v2_pipeline.mmd",
        "docs/21_orchestration_v2_design.md",
        "analysis/likely_conflict_cleanup_phase_plan.csv",
        "analysis/likely_conflict_cleanup_queue.csv",
        "analysis/likely_conflict_cleanup_summary.csv",
        "docs/22_likely_conflict_cleanup_plan.md",
        "analysis/d1_missing_object_lineage_queue.csv",
        "analysis/d1_missing_object_lineage_summary.csv",
        "analysis/d1_manual_lineage_evidence_template.csv",
        "analysis/d1_readonly_target_items.csv",
        "analysis/d1_closure_control_queue.csv",
        "analysis/d1_inherited_pipeline_lineage_candidates.csv",
        "analysis/d1_closure_decision_template.csv",
        "analysis/d1_external_readonly_action_plan.csv",
        "analysis/d1_closure_control_summary.csv",
        "docs/35_d1_closure_control.md",
        "docs/23_d1_missing_object_lineage.md",
        "analysis/d2_likely_dependency_item_queue.csv",
        "analysis/d2_likely_dependency_edge_queue.csv",
        "analysis/d2_likely_dependency_summary.csv",
        "analysis/d2_dependency_confirmation_template.csv",
        "analysis/d2_readonly_confirmation_targets.csv",
        "analysis/d2_closure_control_queue.csv",
        "analysis/d2_report_model_binding_candidates.csv",
        "analysis/d2_sqlendpoint_lakehouse_candidates.csv",
        "analysis/d2_dependency_decision_template.csv",
        "analysis/d2_external_readonly_action_plan.csv",
        "analysis/d2_closure_control_summary.csv",
        "docs/24_d2_likely_dependency_confirmation.md",
        "docs/36_d2_closure_control.md",
        "analysis/d3_likely_object_lineage_item_queue.csv",
        "analysis/d3_likely_object_lineage_object_queue.csv",
        "analysis/d3_likely_object_lineage_summary.csv",
        "analysis/d3_object_lineage_confirmation_template.csv",
        "analysis/d3_readonly_object_lineage_targets.csv",
        "analysis/d3_closure_control_queue.csv",
        "analysis/d3_item_closure_control_queue.csv",
        "analysis/d3_source_object_review_targets.csv",
        "analysis/d3_lineage_decision_template.csv",
        "analysis/d3_external_readonly_action_plan.csv",
        "analysis/d3_closure_control_summary.csv",
        "docs/25_d3_likely_object_lineage_confirmation.md",
        "docs/37_d3_closure_control.md",
        "analysis/d4_exact_object_type_source_queue.csv",
        "analysis/d4_exact_object_type_impact_queue.csv",
        "analysis/d4_exact_object_type_summary.csv",
        "analysis/d4_object_type_confirmation_template.csv",
        "analysis/d4_readonly_object_type_targets.csv",
        "analysis/d4_closure_control_queue.csv",
        "analysis/d4_impacted_source_object_targets.csv",
        "analysis/d4_metadata_retry_targets.csv",
        "analysis/d4_missing_metadata_target_queue.csv",
        "analysis/d4_native_query_review_targets.csv",
        "analysis/d4_object_type_decision_template.csv",
        "analysis/d4_external_readonly_action_plan.csv",
        "analysis/d4_closure_control_summary.csv",
        "docs/26_d4_exact_object_type_confirmation.md",
        "docs/38_d4_closure_control.md",
        "analysis/d4_workspace_catalog_type_evidence.csv",
        "analysis/d4_workspace_catalog_type_diagnosis.csv",
        "analysis/d4_workspace_catalog_type_summary.csv",
        "docs/49_d4_workspace_catalog_type_backfill.md",
        "analysis/d4_semantic_sibling_target_backfill.csv",
        "analysis/d4_semantic_sibling_target_backfill_summary.csv",
        "docs/51_d4_semantic_sibling_target_backfill.md",
        "analysis/d4_semantic_metadata_model_target_backfill.csv",
        "analysis/d4_semantic_metadata_model_target_backfill_summary.csv",
        "docs/52_d4_semantic_metadata_model_target_backfill.md",
        "analysis/d4_semantic_catalog_model_target_backfill.csv",
        "analysis/d4_semantic_catalog_model_target_backfill_summary.csv",
        "docs/53_d4_semantic_catalog_model_target_backfill.md",
        "analysis/d4_item_flow_source_target_backfill.csv",
        "analysis/d4_item_flow_source_target_backfill_summary.csv",
        "docs/54_d4_item_flow_source_target_backfill.md",
        "analysis/e2_unresolved_object_type_gap_classification.csv",
        "analysis/e2_unresolved_object_type_gap_summary.csv",
        "analysis/e2_unresolved_object_type_gap_segment_summary.csv",
        "docs/44_unresolved_object_type_gap_classification.md",
        "analysis/d4_next_evidence_gate_plan.csv",
        "analysis/d4_next_evidence_gate_summary.csv",
        "analysis/d4_object_not_found_next_queue.csv",
        "analysis/d4_metadata_access_next_queue.csv",
        "analysis/d4_source_target_backfill_next_queue.csv",
        "docs/50_d4_next_evidence_gate_plan.md",
        "analysis/d5_object_conflict_queue.csv",
        "analysis/d5_object_guard_edge_queue.csv",
        "analysis/d5_object_conflict_participants.csv",
        "analysis/d5_object_conflict_summary.csv",
        "analysis/d5_object_conflict_decision_template.csv",
        "analysis/d5_readonly_conflict_review_targets.csv",
        "analysis/d5_closure_control_queue.csv",
        "analysis/d5_blocked_by_d3_d4_queue.csv",
        "analysis/d5_serialization_review_targets.csv",
        "analysis/d5_guard_edge_decision_queue.csv",
        "analysis/d5_conflict_participant_review.csv",
        "analysis/d5_conflict_resolution_decision_template.csv",
        "analysis/d5_external_readonly_action_plan.csv",
        "analysis/d5_closure_control_summary.csv",
        "docs/27_d5_object_conflict_resolution.md",
        "docs/39_d5_closure_control.md",
        "analysis/d6_failure_duration_queue.csv",
        "analysis/d6_failure_hotspot_queue.csv",
        "analysis/d6_duration_stabilization_queue.csv",
        "analysis/d6_execution_evidence.csv",
        "analysis/d6_failure_duration_summary.csv",
        "analysis/d6_stabilization_decision_template.csv",
        "analysis/d6_readonly_operational_review_targets.csv",
        "analysis/d6_closure_control_queue.csv",
        "analysis/d6_failure_stabilization_targets.csv",
        "analysis/d6_duration_evidence_targets.csv",
        "analysis/d6_observed_duration_candidates.csv",
        "analysis/d6_owner_estimate_required_queue.csv",
        "analysis/d6_operational_decision_template.csv",
        "analysis/d6_external_readonly_action_plan.csv",
        "analysis/d6_closure_control_summary.csv",
        "docs/28_d6_failure_duration_stabilization.md",
        "docs/40_d6_closure_control.md",
        "analysis/d7_orchestration_review_queue.csv",
        "analysis/d7_nonprod_candidate_queue.csv",
        "analysis/d7_wave_promotion_queue.csv",
        "analysis/d7_orchestration_review_summary.csv",
        "analysis/d7_promotion_decision_template.csv",
        "analysis/d7_readonly_promotion_targets.csv",
        "analysis/d7_closure_control_queue.csv",
        "analysis/d7_blocked_by_d6_queue.csv",
        "analysis/d7_read_write_validation_targets.csv",
        "analysis/d7_source_readiness_targets.csv",
        "analysis/d7_owner_approval_ready_targets.csv",
        "analysis/d7_wave_closure_control.csv",
        "analysis/d7_operational_decision_template.csv",
        "analysis/d7_external_readonly_action_plan.csv",
        "analysis/d7_closure_control_summary.csv",
        "docs/29_d7_orchestration_review_promotion.md",
        "docs/41_d7_closure_control.md",
        "analysis/d8_parallel_candidate_retest_queue.csv",
        "analysis/d8_candidate_item_evidence.csv",
        "analysis/d8_candidate_object_evidence.csv",
        "analysis/d8_missing_object_evidence_targets.csv",
        "analysis/d8_read_write_validation_targets.csv",
        "analysis/d8_nonprod_parallel_test_candidates.csv",
        "analysis/d8_parallel_retest_decision_template.csv",
        "analysis/d8_external_readonly_action_plan.csv",
        "analysis/d8_parallel_candidate_retest_summary.csv",
        "docs/42_d8_parallel_candidate_retest.md",
        "analysis/e1_deep_evidence_scope_summary.csv",
        "analysis/e1_notebook_code_review_queue.csv",
        "analysis/e1_semantic_model_review_queue.csv",
        "analysis/e1_sql_object_metadata_queue.csv",
        "analysis/e1_likely_resolution_targets.csv",
        "analysis/e1_external_readonly_action_plan.csv",
        "docs/43_deep_evidence_sweep_plan.md",
        "analysis/object_level_lineage_coverage.csv",
        "analysis/object_level_lineage_summary.csv",
        "docs/16_object_level_lineage_and_impact.md",
        "analysis/item_object_lineage_candidates.csv",
        "analysis/item_object_lineage_gaps.csv",
        "analysis/notebook_definition_download_manifest.csv",
        "analysis/notebook_super_lineage_objects.csv",
        "analysis/notebook_super_lineage_flows.csv",
        "analysis/notebook_super_lineage_gaps.csv",
        "analysis/notebook_super_lineage_summary.csv",
        "docs/45_notebook_super_lineage.md",
        "analysis/notebook_lineage_review_summary.csv",
        "analysis/notebook_lineage_touchpoints.csv",
        "analysis/notebook_lineage_flow_catalog.csv",
        "analysis/notebook_lineage_review_batches.csv",
        "docs/46_notebook_lineage_review_batches.md",
        "analysis/notebook_code_deep_review.csv",
        "analysis/notebook_code_deep_review_summary.csv",
        "docs/47_notebook_code_deep_review.md",
        "analysis/pipeline_object_lineage_candidates.csv",
        "analysis/pipeline_activity_lineage.csv",
        "analysis/pipeline_object_lineage_gaps.csv",
        "index/deployment_pipelines.csv",
        "index/deployment_pipeline_stages.csv",
        "index/deployment_pipeline_stage_items.csv",
        "analysis/deployment_pipeline_workspace_groups.csv",
        "analysis/deployment_pipeline_discovery_gaps.csv",
        "analysis/semantic_model_datamart_dependencies.csv",
        "analysis/semantic_model_view_candidates.csv",
        "frontend/semantic-lineage/data/semantic-lineage.json",
        "frontend/semantic-lineage/data/lineage-explorer.json",
        "analysis/lineage_explorer_gaps.csv",
        "frontend/semantic-lineage/standalone.html",
        "analysis/visual-validation/playwright-results.json",
        "config/source_migration_map.csv"
    )

    $manifest = [pscustomobject]@{
        generated_at = $endedAt.ToString("s")
        mode = $Mode
        auth_method = $AuthMethod
        run_tmdl_enrichment = [bool]$RunTmdlEnrichment
        max_tmdl_models = $MaxTmdlModels
        skip_report_definitions = [bool]$SkipReportDefinitions
        skip_optimization = [bool]$SkipOptimization
        skip_standalone = [bool]$SkipStandalone
        run_visual_validation = [bool]$RunVisualValidation
        read_only_note = $readOnlyNote
        started_at = $startedAt.ToString("s")
        ended_at = $endedAt.ToString("s")
        duration_seconds = [math]::Round(($endedAt - $startedAt).TotalSeconds, 3)
        steps = $StepResults
        files = @(Get-FileSummary -Paths ($importantFiles | ForEach-Object { Join-Path $script:RepoRoot $_ }))
    }

    $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $ManifestPath -Encoding UTF8

    $logLines = [System.Collections.Generic.List[string]]::new()
    $logLines.Add("# Lineage Refresh Run - $($startedAt.ToString("s"))") | Out-Null
    $logLines.Add("") | Out-Null
    $logLines.Add("- Mode: ``$Mode``") | Out-Null
    $logLines.Add("- Auth method: ``$AuthMethod``") | Out-Null
    $logLines.Add("- Started: $($startedAt.ToString("s"))") | Out-Null
    $logLines.Add("- Ended: $($endedAt.ToString("s"))") | Out-Null
    $logLines.Add("- Duration seconds: $([math]::Round(($endedAt - $startedAt).TotalSeconds, 3))") | Out-Null
    $logLines.Add("- Manifest: ``$ManifestPath``") | Out-Null
    $logLines.Add("") | Out-Null
    $logLines.Add("## Steps") | Out-Null
    foreach ($step in $StepResults) {
        $logLines.Add("- $($step.status): $($step.name) ($($step.duration_seconds)s)") | Out-Null
    }
    $logLines.Add("") | Out-Null
    $logLines.Add("## Note") | Out-Null
    $logLines.Add($readOnlyNote) | Out-Null
    $logLines | Set-Content -Path $runLogPath -Encoding UTF8

    Write-Host ""
    Write-Host "Refresh manifest: $ManifestPath"
    Write-Host "Run log: $runLogPath"

    if (-not $SkipStandalone) {
        Write-Host ""
        Write-Host "Embedding latest refresh metadata into standalone explorer"
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "11_build_lineage_explorer.ps1") -ManifestPath $ManifestPath -RunLogDirectory $RunLogDirectory
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild lineage explorer data with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "21_build_reverse_impact_package.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild reverse impact package with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "62_normalize_fabric_placeholder_paths.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to normalize Fabric placeholders with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "22_build_evidence_hardening_queue.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild evidence hardening queue with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "23_build_object_read_write_classification.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild object read/write classification with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "24_build_orchestration_v2.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild orchestration optimization v2 with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "25_build_likely_conflict_cleanup_plan.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild likely/conflict cleanup plan with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "26_build_d1_missing_object_lineage_package.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D1 missing object-level lineage package with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "39_build_d1_closure_control.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D1 closure control with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "27_build_d2_likely_dependency_confirmation_package.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D2 likely dependency confirmation package with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "40_build_d2_closure_control.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D2 closure control with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "28_build_d3_likely_object_lineage_confirmation_package.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D3 likely object-lineage confirmation package with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "41_build_d3_closure_control.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D3 closure control with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "29_build_d4_exact_object_type_confirmation_package.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D4 exact object-type confirmation package with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "42_build_d4_closure_control.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D4 closure control with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "50_classify_unresolved_object_type_gaps.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild E2 unresolved object-type gap classification with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "57_build_d4_next_evidence_gate_plan.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D4 next evidence gate plan with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "30_build_d5_object_conflict_resolution_package.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D5 object conflict resolution package with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "43_build_d5_closure_control.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D5 closure control with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "31_build_d6_failure_duration_stabilization_package.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D6 failure and duration stabilization package with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "44_build_d6_closure_control.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D6 closure control with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "32_build_d7_orchestration_review_promotion_package.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D7 orchestration review promotion package with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "45_build_d7_closure_control.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D7 closure control with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "46_build_d8_parallel_candidate_retest_package.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild D8 parallel candidate retest package with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "47_build_deep_evidence_sweep_plan.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild E1 deep evidence sweep plan with latest refresh metadata."
        }
        & pwsh -NoLogo -File (Join-Path $PSScriptRoot "10_build_semantic_lineage_standalone.ps1")
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to rebuild standalone lineage explorer with latest refresh metadata."
        }
    }

    # Whether this run succeeded or an exception is about to propagate past
    # this finally block, mark it no longer "on" a specific step -- the
    # trigger server already determines real success/failure from this
    # process's exit code (see _wait_for_full_scan_process in
    # lineage_web_server.py), so this is only about the live step display.
    Write-ScanProgress -CurrentStepName "" -Phase "done"
}
