# Phase 56 - Thin PowerShell wrapper around
# backend/scripts/56_build_workspace_catalog_type_evidence.py (see that file's
# docstring): a narrower, workspace-scoped fallback for D4 object-type
# gaps -- confirms type only when a workspace's own SQL endpoint catalog
# rows agree on one physical type. -MergeMetadata folds the result
# directly into the metadata evidence file instead of just reporting it.
param(
    [string]$PythonCommand = "python3",
    [switch]$MergeMetadata
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = (Join-Path $PSScriptRoot "56_build_workspace_catalog_type_evidence.py")
if (-not (Test-Path $scriptPath)) {
    throw "Required script not found: $scriptPath"
}

$arguments = @($scriptPath)
if ($MergeMetadata) {
    $arguments += "--merge-metadata"
}

& $PythonCommand @arguments
if ($LASTEXITCODE -ne 0) {
    throw "$scriptPath exited with code $LASTEXITCODE"
}
