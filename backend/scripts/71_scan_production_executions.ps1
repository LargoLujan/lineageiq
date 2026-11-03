# Phase 71 - Production-only execution/schedule refresh: the narrow,
# fast counterpart to a full/workspace scan when all that's needed is
# duration/schedule/run-history data (Phase 6), not a full re-discovery of
# items, dependencies, or object lineage.
#
# "Production" here means the tenant's own naming convention: a workspace
# WITHOUT a "[DEV]"/"[QA]"/"[UAT]"/"[PRE]" suffix (e.g. "Contoso Operations"
# is production; "Contoso Operations [DEV]" is not). This is deliberately
# broader than isProductionWorkspace() in app.js (which only catches
# environment=="PRO", a "_pro" name fragment, or an explicit
# deployment-pipeline "Production" stage -- usually a small subset of
# workspaces with almost no semantic models) because THAT definition was
# built for Planning's datamart-ingestion-chain use case, not this one. The
# narrow definition misses bare-named business workspaces such as
# "Contoso Operations" -- exactly the kind of workspace whose
# schedule/duration data this script is for. The broad definition covers
# most workspaces and executable items (mostly semantic models), which is
# what "production" means to a person reading a schedule.
#
# Safe to run daily: 06_discover_executions.ps1 now merges freshly-fetched
# job_instance rows with whatever the SAME items already had on disk
# (deduped by qualified_name + job_instance_id) instead of replacing them,
# so a past run can never be lost just because it aged out of the API's
# "most recent N" window on a later call, and re-running never duplicates
# rows either -- a completed/failed run in the past cannot change, so once
# captured it is kept forever.
param(
    [string]$WorkspaceIndexPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$AzCommand = "az",
    [switch]$DryRun,
    [switch]$SkipExplorerRebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

function Test-NonProductionWorkspaceName {
    param([string]$Name)
    return [regex]::IsMatch(($Name ?? "").Trim(), '\[(dev|qa|uat|pre)\]\s*$', 'IgnoreCase')
}

if (-not (Test-Path $WorkspaceIndexPath)) {
    throw "Required input not found: $WorkspaceIndexPath"
}

$productionWorkspaceNames = @(
    Import-Csv -Path $WorkspaceIndexPath |
        Where-Object { $_.workspace_name -and -not (Test-NonProductionWorkspaceName -Name $_.workspace_name) } |
        Select-Object -ExpandProperty workspace_name
)

if ($productionWorkspaceNames.Count -eq 0) {
    throw "No production workspaces resolved from $WorkspaceIndexPath -- refusing to run an unfiltered (whole-tenant) executions scan by accident."
}

Write-Host "Production workspaces resolved: $($productionWorkspaceNames.Count)"

if ($DryRun) {
    Write-Host "Dry run -- listing workspaces only, not scanning."
    $productionWorkspaceNames | ForEach-Object { Write-Host "  $_" }
    return
}

$filterArg = $productionWorkspaceNames -join ";"
& pwsh -NoLogo -File (Join-Path $PSScriptRoot "06_discover_executions.ps1") `
    -AzCommand $AzCommand -ProbeCandidateSchedules:$false -WorkspaceNameFilter $filterArg
if ($LASTEXITCODE -ne 0) {
    throw "06_discover_executions.ps1 exited with code $LASTEXITCODE."
}

if (-not $SkipExplorerRebuild) {
    # Only the explorer JSON embeds each item's `execution` field (schedule/
    # duration/run counts) -- object impact and the graph are dependency-
    # based and untouched by this data, so rebuilding just this one step is
    # enough for the web/API/MCP to serve the refreshed numbers.
    Write-Host "Rebuilding lineage-explorer.json to serve the refreshed execution data..."
    & pwsh -NoLogo -File (Join-Path $PSScriptRoot "11_build_lineage_explorer.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "11_build_lineage_explorer.ps1 exited with code $LASTEXITCODE."
    }
}

Write-Host "Production execution/schedule refresh completed."
