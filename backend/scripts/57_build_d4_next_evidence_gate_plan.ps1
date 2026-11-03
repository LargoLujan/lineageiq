# Phase 57 - Thin PowerShell wrapper around
# backend/scripts/57_build_d4_next_evidence_gate_plan.py (see that file's
# docstring): translates E2 root-cause analysis into a concrete next-step
# workstream plan for closing remaining D4 object-type gaps. Read-only --
# does not promote evidence or touch external systems.
param(
    [string]$PythonCommand = "python3"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = (Join-Path $PSScriptRoot "57_build_d4_next_evidence_gate_plan.py")
if (-not (Test-Path $scriptPath)) {
    throw "Required script not found: $scriptPath"
}

& $PythonCommand $scriptPath
if ($LASTEXITCODE -ne 0) {
    throw "$scriptPath exited with code $LASTEXITCODE"
}
