# Phase 64 - Bronze upload to OneLake: a thin PowerShell wrapper around
# backend/scripts/64_upload_bronze_to_onelake.py, which uploads selected local CSV
# artifacts (per $Entities, or all registered ones) as Delta/Parquet
# "bronze" tables into the project-owned Lakehouse configured in
# $LakehouseConfig, so this project's own output becomes queryable inside
# Fabric itself. -DryRun reports what would upload without writing.
param(
    [string]$PythonCommand = "python3",
    [string]$LakehouseConfig = (Join-Path $PSScriptRoot "../../config/lakehouse_target.json"),
    [string]$SnapshotDate = "",
    [string]$Entities = "",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = (Join-Path $PSScriptRoot "64_upload_bronze_to_onelake.py")
if (-not (Test-Path $scriptPath)) {
    throw "Required script not found: $scriptPath"
}

$pyArgs = @("--lakehouse-config", $LakehouseConfig)
if ($SnapshotDate) { $pyArgs += @("--snapshot-date", $SnapshotDate) }
if ($Entities) { $pyArgs += @("--entities", $Entities) }
if ($DryRun) { $pyArgs += "--dry-run" }

& $PythonCommand $scriptPath @pyArgs
if ($LASTEXITCODE -ne 0) {
    throw "$scriptPath exited with code $LASTEXITCODE"
}
