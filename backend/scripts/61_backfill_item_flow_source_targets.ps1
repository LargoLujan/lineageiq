# Phase 61 - Thin PowerShell wrapper around
# backend/scripts/61_backfill_item_flow_source_targets.py (see that file's
# docstring): fills missing item object source targets when the notebook
# super-lineage/flow catalog points to one unique source endpoint for the
# same item/object/usage side. Dry-run by default; -Apply writes changes.
param(
    [string]$PythonCommand = "python3",
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "61_backfill_item_flow_source_targets.py"
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
