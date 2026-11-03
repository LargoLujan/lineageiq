# Phase 60 - Thin PowerShell wrapper around
# backend/scripts/60_backfill_semantic_catalog_model_source_targets.py (see that
# file's docstring): fills missing semantic model source targets using
# only local catalog evidence (confirmed source dependency + a unique
# object match in that model's confirmed target set). Dry-run by default;
# -Apply writes changes.
param(
    [string]$PythonCommand = "python3",
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = (Join-Path $PSScriptRoot "60_backfill_semantic_catalog_model_source_targets.py")
if (-not (Test-Path $scriptPath)) {
    throw "Required script not found: $scriptPath"
}

$arguments = @($scriptPath)
if ($Apply) {
    $arguments += "--apply"
}

& $PythonCommand @arguments
if ($LASTEXITCODE -ne 0) {
    throw "$scriptPath exited with code $LASTEXITCODE"
}
