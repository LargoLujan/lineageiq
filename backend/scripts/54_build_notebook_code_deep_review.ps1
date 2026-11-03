# Phase 54 - Thin PowerShell wrapper around
# backend/scripts/54_build_notebook_code_deep_review.py (see that file's
# docstring): a notebook-level code-read audit proving which local
# definitions were actually read and how strong the resulting evidence is
# (flow-level, touchpoint-only, execute-only, helper/control, or missing).
param(
    [string]$Python = "python3"
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot

Push-Location $repoRoot
try {
    & $Python "backend/scripts/54_build_notebook_code_deep_review.py"
}
finally {
    Pop-Location
}
