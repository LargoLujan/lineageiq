# Phase 70 - Control-framework runtime lineage wrapper: delegates to
# backend/scripts/70_extract_control_framework_lineage.py. There is no
# PowerShell fallback -- the runtime-log read needs pyodbc AAD SQL
# connections that only the python implementation has.
param(
    [string]$AzCommand = "az"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = (Join-Path $PSScriptRoot "70_extract_control_framework_lineage.py")
# Deliberately try `python` BEFORE `python3`: on this machine python3 is the
# Windows Store 3.13 without pyodbc, while python is the 3.12 install that
# has pyodbc + ODBC Driver 17 (see project notes on multiple Pythons).
$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCommand) {
    $pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
}
if (-not $pythonCommand) {
    throw "python is required for 70_extract_control_framework_lineage.py (pyodbc)."
}
& $pythonCommand.Source $scriptPath --az-command $AzCommand
exit $LASTEXITCODE
