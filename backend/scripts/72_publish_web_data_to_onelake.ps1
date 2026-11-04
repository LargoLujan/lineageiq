# Phase 72 - Publish web data to OneLake: a thin PowerShell wrapper around
# backend/scripts/72_publish_web_data_to_onelake.py, which uploads the big
# generated JSON payloads the frontend loads (lineage-explorer.json and
# friends -- see that script's own docstring) into a Fabric Lakehouse's
# OneLake Files area, so lineage_web_server.py can serve them live
# (admin_settings.json -> onelake_data.mode = "onelake") instead of from
# this machine's local disk. See docs/106_onelake_web_data_publish.md.
#
# PythonCommand defaults to "python", not "python3" (unlike
# 64_upload_bronze_to_onelake.ps1's own wrapper) -- confirmed live
# that only the "python" install on this project's machines has
# azure-identity/azure-storage-file-datalake installed (see project notes
# on multiple Python installs); override if your machine differs.
param(
    [string]$PythonCommand = "python",
    [string]$AdminSettingsPath = (Join-Path $PSScriptRoot "../../config/admin_settings.json"),
    [string]$Only = "",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = (Join-Path $PSScriptRoot "72_publish_web_data_to_onelake.py")
if (-not (Test-Path $scriptPath)) {
    throw "Required script not found: $scriptPath"
}

$pyArgs = @("--admin-settings", $AdminSettingsPath)
if ($Only) { $pyArgs += @("--only", $Only) }
if ($DryRun) { $pyArgs += "--dry-run" }

& $PythonCommand $scriptPath @pyArgs
if ($LASTEXITCODE -ne 0) {
    throw "$scriptPath exited with code $LASTEXITCODE"
}
