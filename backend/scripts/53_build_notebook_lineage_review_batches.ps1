# Phase 53 - Thin PowerShell wrapper around
# backend/scripts/53_build_notebook_lineage_review_batches.py (see that file's
# docstring): builds per-notebook manual-review batches by reconciling
# Phase 52's super-lineage extract with the downloaded definitions.
param(
    [string]$Python = "python3"
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot

Push-Location $repoRoot
try {
    & $Python "backend/scripts/53_build_notebook_lineage_review_batches.py"
}
finally {
    Pop-Location
}
