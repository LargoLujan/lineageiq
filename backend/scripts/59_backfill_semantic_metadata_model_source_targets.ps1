# Phase 59 - Thin PowerShell wrapper around
# backend/scripts/59_backfill_semantic_metadata_model_source_targets.py (see that
# file's docstring): fills missing semantic model source targets when
# read-only metadata evidence agrees with a confirmed source dependency of
# the same model. Dry-run by default; -Apply writes changes.
param(
    [string]$PythonCommand = "python3",
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = (Join-Path $PSScriptRoot "59_backfill_semantic_metadata_model_source_targets.py")
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
