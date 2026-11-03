# Phase 52 - Notebook super-lineage: a thin PowerShell wrapper around
# backend/scripts/52_build_notebook_super_lineage.py (the real ~5,500-line static
# analyzer -- see that file's own module docstring), which statically
# parses every downloaded notebook's source (Phase 51's output, matched
# via analysis/notebook_definition_download_manifest.csv) to extract real
# object-level read/write/execute flows without running any notebook code.
param(
    [string]$PythonCommand = "python3",
    [string]$WorkspaceNameFilter = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "52_build_notebook_super_lineage.py"
if (-not (Test-Path $scriptPath)) {
    throw "Required script not found: $scriptPath"
}

$pythonArgs = @($scriptPath)
if ($WorkspaceNameFilter) {
    $pythonArgs += @("--workspace-name-filter", $WorkspaceNameFilter)
}

try {
    & $PythonCommand @pythonArgs
}
catch {
    if ($PythonCommand -eq "python3") {
        & python @pythonArgs
    }
    else {
        throw
    }
}

if ($LASTEXITCODE -ne 0) {
    throw "Notebook super-lineage extractor exited with code $LASTEXITCODE"
}
