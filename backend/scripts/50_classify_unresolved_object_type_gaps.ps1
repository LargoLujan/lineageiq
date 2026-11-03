# Phase 50 - Unresolved object type gap classification: a thin PowerShell
# wrapper that just invokes backend/scripts/50_classify_unresolved_object_type_gaps.py
# (the actual logic lives there -- a heuristic classifier for whatever
# object-type gaps remain after Phases 15/20/34/48).
param(
    [string]$PythonCommand = "python3"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = (Join-Path $PSScriptRoot "50_classify_unresolved_object_type_gaps.py")
if (-not (Test-Path $scriptPath)) {
    throw "Required script not found: $scriptPath"
}

& $PythonCommand $scriptPath
if ($LASTEXITCODE -ne 0) {
    throw "$scriptPath exited with code $LASTEXITCODE"
}
