# Phase 58 - Thin PowerShell wrapper around
# backend/scripts/58_backfill_semantic_sibling_source_targets.py (see that file's
# docstring): fills missing semantic model source targets only when an
# exact sibling row (same model/table/schema/object/type) already has a
# unique server/database target. Dry-run by default; -Apply writes changes.
param(
    [string]$PythonCommand = "python3",
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = (Join-Path $PSScriptRoot "58_backfill_semantic_sibling_source_targets.py")
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
