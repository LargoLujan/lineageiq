param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceName,
    [string]$WorkspaceIndexPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$AzCommand = "az",
    [switch]$SkipSqlCatalog,
    [string]$ProgressPath = (Join-Path $PSScriptRoot "../../analysis/single_workspace_scan/progress.json"),
    [switch]$PublishBronze,
    [string]$LakehouseConfig = (Join-Path $PSScriptRoot "../../config/lakehouse_target.json")
)

# Rescans a single Fabric workspace instead of the full tenant (a full-tenant scan can take hours).
# Read-only against Fabric. Every discovery/extraction step below retains the CSV rows of all
# other workspaces unchanged (see the -WorkspaceNameFilter patch in each numbered script) and
# only local, no-Fabric-call steps run at the end to rebuild the graph/web artifacts.
#
# Steps 1-2 are mandatory (item inventory and analysis are the foundation of everything else).
# Steps 3-6 are best-effort: a failure there is logged and the scan continues, because missing
# object-level lineage or SQL metadata for one item type should not block the rest of the
# workspace refresh. Steps 7-10 are mandatory local rebuilds so the web viewer reflects the new
# data immediately.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# See the identical fix/comment in
# 99_refresh_lineage_project.ps1's Invoke-LineageStep -- every
# -ScriptPath "backend/scripts/xxx.ps1" below was resolved against $PWD, not this
# file's own location.
$script:RepoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

$script:StepResults = [System.Collections.Generic.List[object]]::new()
# Mirrors the exact Invoke-WorkspaceScanStep call count below for the
# -SkipSqlCatalog value in effect this run (15 with the SQL/column catalog
# steps, 12 without) -- this is what turns "step 8 just started" into a
# percentage for the progress bar. It is a plain count of calls in this
# file, not derived from anything dynamic, so it only drifts if a step is
# added or removed here without updating it too.
# +1 unconditional (69 connections discovery); +1 more in the SQL-catalog
# block (70 control-framework runtime lineage).
$script:TotalSteps = $(if ($SkipSqlCatalog) { 14 } else { 18 }) + $(if ($PublishBronze) { 1 } else { 0 })

function Write-ScanProgress {
    param([string]$CurrentStepName, [string]$Phase = "running")

    $progress = [pscustomobject]@{
        scan_kind = "workspace"
        workspace = $WorkspaceName
        completed_steps = $script:StepResults.Count
        total_steps = $script:TotalSteps
        current_step_name = $CurrentStepName
        phase = $Phase
        updated_at = (Get-Date).ToString("o")
        # Every step completed so far -- the trigger server that spawned
        # this process (the sole writer of history.csv, see
        # lineage_web_server.py) reads this to work out a real
        # step_count/degraded_step_count/failed_step for that row, even
        # when this process gets force-killed mid-step (a stop request
        # never lets this script reach its own finally block to run).
        steps = @($script:StepResults)
    }
    $parent = Split-Path -Parent $ProgressPath
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
    $progress | ConvertTo-Json -Depth 6 | Set-Content -Path $ProgressPath -Encoding UTF8
}

function Get-AzureCliToken {
    # A signed-in web-app user's own delegated token, if the process that
    # spawned this script set one (see FABRIC_LINEAGE_USER_TOKEN in
    # lineage_web_server.py) -- falls back to the shared `az` CLI session
    # below when run standalone from a terminal, exactly as before.
    if ($env:FABRIC_LINEAGE_USER_TOKEN) {
        return $env:FABRIC_LINEAGE_USER_TOKEN
    }

    try {
        $azPath = (Get-Command $AzCommand -ErrorAction Stop).Source
    }
    catch {
        throw "Azure CLI command '$AzCommand' was not found."
    }

    $tokenOutput = & $azPath account get-access-token `
        --resource "https://api.fabric.microsoft.com" `
        --query "accessToken" `
        -o tsv 2>&1

    if ($LASTEXITCODE -ne 0) {
        $tokenError = (($tokenOutput | Out-String) -replace "\s+", " ").Trim()
        throw "Azure CLI session is missing or expired. Run 'az login' and try again. Details: $tokenError"
    }

    $token = ($tokenOutput | Out-String).Trim()
    if (-not $token) {
        throw "Azure CLI returned an empty Fabric access token. Run 'az login' and try again."
    }

    return $token
}

function Invoke-WorkspaceScanStep {
    param(
        [string]$Name,
        [string]$ScriptPath,
        [string[]]$Arguments = @(),
        [switch]$ContinueOnFailure
    )

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
        $errorText = $_.Exception.Message
        if ($ContinueOnFailure) {
            $status = "degraded"
            Write-Host "Step degraded (continuing): $errorText"
        }
        else {
            $status = "failed"
            throw
        }
    }
    finally {
        $ended = Get-Date
        $script:StepResults.Add([pscustomobject]@{
            name = $Name
            status = $status
            duration_seconds = [math]::Round(($ended - $started).TotalSeconds, 3)
            error = $errorText
        }) | Out-Null
    }
}

function Write-StepSummary {
    Write-Host ""
    Write-Host "==> Step summary"
    foreach ($step in $script:StepResults) {
        $line = "  [$($step.status)] $($step.name) ($($step.duration_seconds)s)"
        if ($step.error) {
            $line = "$line - $($step.error)"
        }
        Write-Host $line
    }
}


if (-not (Test-Path $WorkspaceIndexPath)) {
    throw "Workspace index not found: $WorkspaceIndexPath"
}

$matchingWorkspace = @(Import-Csv -Path $WorkspaceIndexPath | Where-Object { $_.workspace_name -eq $WorkspaceName })
if ($matchingWorkspace.Count -eq 0) {
    throw "Workspace '$WorkspaceName' was not found in $WorkspaceIndexPath. Check the exact name (case-sensitive) in that file."
}

Write-Host "Checking Azure CLI session..."
Get-AzureCliToken | Out-Null
Write-Host "Azure CLI session OK."

$startedAt = Get-Date
$failed = $false

try {
    Invoke-WorkspaceScanStep -Name "Item inventory (03)" `
        -ScriptPath "backend/scripts/03_discover_items.ps1" `
        -Arguments @("-AzCommand", $AzCommand, "-WorkspaceNameFilter", $WorkspaceName)

    Invoke-WorkspaceScanStep -Name "Item analysis (04)" `
        -ScriptPath "backend/scripts/04_analyze_items.ps1" `
        -Arguments @("-AzCommand", $AzCommand, "-WorkspaceNameFilter", $WorkspaceName)

    Invoke-WorkspaceScanStep -Name "Notebook/CopyJob/Dataflow object lineage (18)" `
        -ScriptPath "backend/scripts/18_extract_item_object_lineage.ps1" `
        -Arguments @("-AzCommand", $AzCommand, "-WorkspaceNameFilter", $WorkspaceName) `
        -ContinueOnFailure

    Invoke-WorkspaceScanStep -Name "DataPipeline activity object lineage (19)" `
        -ScriptPath "backend/scripts/19_extract_pipeline_object_lineage.ps1" `
        -Arguments @("-AzCommand", $AzCommand, "-WorkspaceNameFilter", $WorkspaceName) `
        -ContinueOnFailure

    # Step 18 above extracts object candidates from notebook code but does
    # not persist the notebook's own source files to disk in the format the
    # deeper static-parse step (52) needs. Without a fresh download here, 52
    # would keep re-parsing whatever version of the notebook happened to be
    # on disk from the last full project refresh -- silently stale for any
    # workspace only ever touched through this quick-scan button.
    Invoke-WorkspaceScanStep -Name "Notebook definition download (51)" `
        -ScriptPath "backend/scripts/51_download_notebook_definitions.ps1" `
        -Arguments @("-AzCommand", $AzCommand, "-WorkspaceNameFilter", $WorkspaceName, "-MergeManifest") `
        -ContinueOnFailure

    # Local, static code parse of the notebook source just downloaded above:
    # resolves real read/write table candidates (including the "variable
    # part resolved, table name kept" case Notebooks depends on) instead of
    # only the coarse connection-level evidence step 04 captures.
    Invoke-WorkspaceScanStep -Name "Notebook super-lineage extraction (52)" `
        -ScriptPath "backend/scripts/52_build_notebook_super_lineage.ps1" `
        -Arguments @("-WorkspaceNameFilter", $WorkspaceName) `
        -ContinueOnFailure

    # Without this, semantic models never get real table/view-level object
    # detail from a quick scan -- only the coarse SQL connection (server +
    # database) that step 04 already captures generically for every item
    # type. This downloads and parses each semantic model's TMDL/M
    # definition to resolve the actual tables/views/native queries it
    # reads, which is also what lets Planning connect a model to the real
    # upstream notebook/copyjob that writes the same table.
    Invoke-WorkspaceScanStep -Name "Semantic model view enrichment (09)" `
        -ScriptPath "backend/scripts/09_enrich_semantic_model_views.ps1" `
        -Arguments @("-AzCommand", $AzCommand, "-WorkspaceNameFilter", $WorkspaceName) `
        -ContinueOnFailure

    # Job instance history (duration, status, failure reason) and existing
    # schedules for every invokable item in this workspace. The full-tenant
    # refresh disables schedule probing to keep a large-tenant run under
    # control, but a single-workspace quick scan can afford the extra calls
    # for the completeness a quick scan is meant to give: real average/median
    # run duration, real failures, real schedules -- not just structure.
    Invoke-WorkspaceScanStep -Name "Execution timing and schedules (06)" `
        -ScriptPath "backend/scripts/06_discover_executions.ps1" `
        -Arguments @("-AzCommand", $AzCommand, "-WorkspaceNameFilter", $WorkspaceName) `
        -ContinueOnFailure

    # Tenant-level but cheap (one paged API call): keeps the connection
    # display-name -> real host;database catalog fresh so cloud connections
    # ("LH_..._Nube") resolve to their actual lakehouses in this rebuild.
    Invoke-WorkspaceScanStep -Name "Fabric connections discovery (69)" `
        -ScriptPath "backend/scripts/69_discover_fabric_connections.ps1" `
        -Arguments @("-AzCommand", $AzCommand) `
        -ContinueOnFailure

    if (-not $SkipSqlCatalog) {
        Invoke-WorkspaceScanStep -Name "Source object type metadata (20)" `
            -ScriptPath "backend/scripts/20_extract_source_object_type_metadata.ps1" `
            -Arguments @("-AzCommand", $AzCommand, "-TrustServerCertificate", "-WorkspaceNameFilter", $WorkspaceName) `
            -ContinueOnFailure

        Invoke-WorkspaceScanStep -Name "SQL endpoint object catalog (34)" `
            -ScriptPath "backend/scripts/34_extract_sql_endpoint_object_catalog.ps1" `
            -Arguments @("-AzCommand", $AzCommand, "-TrustServerCertificate", "-WorkspaceNameFilter", $WorkspaceName) `
            -ContinueOnFailure

        # Read-only sys.columns catalog (name + data type) for every SQL/Fabric
        # table or view this workspace's items reference, so the detail panel
        # can show real column composition alongside server/database/schema/
        # table instead of just the table name. Uses the same AAD-token auth
        # as steps 20/34 -- no stored SQL password.
        Invoke-WorkspaceScanStep -Name "Object column catalog (63)" `
            -ScriptPath "backend/scripts/63_extract_object_column_catalog.ps1" `
            -Arguments @("-AzCommand", $AzCommand, "-TrustServerCertificate", "-WorkspaceNameFilter", $WorkspaceName) `
            -ContinueOnFailure

        # Runtime lineage from the load framework's own control.TableStatus
        # logs (tenant-level: reads every cataloged control table, ~12
        # databases, a couple of minutes). Not workspace-scoped because the
        # loaders that feed THIS workspace's models usually live in OTHER
        # (datamart) workspaces -- exactly the rows this scan's rebuild
        # needs to draw them.
        Invoke-WorkspaceScanStep -Name "Control-framework runtime lineage (70)" `
            -ScriptPath "backend/scripts/70_extract_control_framework_lineage.ps1" `
            -Arguments @("-AzCommand", $AzCommand) `
            -ContinueOnFailure
    }

    Invoke-WorkspaceScanStep -Name "Graph rebuild (05, local)" -ScriptPath "backend/scripts/05_build_graph.ps1"
    Invoke-WorkspaceScanStep -Name "Lineage explorer data rebuild (11, local)" -ScriptPath "backend/scripts/11_build_lineage_explorer.ps1"
    Invoke-WorkspaceScanStep -Name "Object impact index rebuild (17, local)" -ScriptPath "backend/scripts/17_build_object_impact_index.ps1"
    Invoke-WorkspaceScanStep -Name "Reverse impact package rebuild (21, local)" -ScriptPath "backend/scripts/21_build_reverse_impact_package.ps1"

    # Graph Map Mode's own index (graph-map-index.json/graph-map-index-
    # objects.json) -- reads object-impact.json/lineage-explorer.json just
    # rebuilt above, so it must run after both. Without this step, Graph
    # Map Mode would silently keep showing stale data for a workspace touched
    # only through this button.
    Invoke-WorkspaceScanStep -Name "Graph Map index rebuild (local)" -ScriptPath "backend/scripts/build_graph_map_index.ps1"

    # Opt-in, off by default: uploads the current CSVs into the project's
    # own Fabric Lakehouse as a dated Bronze partition (see
    # docs/101_medallion_lakehouse_provisioning.md). Never touches the
    # tenant workspaces this scan just refreshed -- only the separate,
    # project-owned Lakehouse recorded in $LakehouseConfig. Best-effort:
    # a failure here (e.g. the Lakehouse config still has no
    # workspace/lakehouse filled in) degrades this step but does not fail
    # the scan that just did the real work.
    if ($PublishBronze) {
        Invoke-WorkspaceScanStep -Name "Bronze upload to OneLake (64)" `
            -ScriptPath "backend/scripts/64_upload_bronze_to_onelake.ps1" `
            -Arguments @("-LakehouseConfig", $LakehouseConfig) `
            -ContinueOnFailure
    }
}
catch {
    $failed = $true
    Write-Host ""
    Write-Host "Scan aborted: $($_.Exception.Message)"
}
finally {
    $endedAt = Get-Date
    Write-StepSummary
    Write-Host ""
    Write-Host "Workspace: $WorkspaceName"
    Write-Host "Started: $($startedAt.ToString("s"))"
    Write-Host "Ended: $($endedAt.ToString("s"))"
    Write-Host "Duration seconds: $([math]::Round(($endedAt - $startedAt).TotalSeconds, 3))"

    # history.csv itself is now written by the trigger server that spawned
    # this process (lineage_web_server.py), not here -- that is the only
    # place guaranteed to run regardless of how this script's own process
    # ends (normal completion, or force-killed mid-step by a stop request,
    # which never lets this finally block run at all). The step list this
    # last progress write carries is what the server reads to work out
    # step_count/degraded_step_count/failed_step for that row.
    Write-ScanProgress -CurrentStepName "" -Phase $(if ($failed) { "failed" } else { "done" })
}

if ($failed) {
    exit 1
}
exit 0
