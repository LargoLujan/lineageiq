# Phase 69 - Fabric connections discovery: lists the tenant connections the
# caller can see (GET /v1/connections) and records each one's REAL target
# (connectionDetails.path -- for SQL connections "server;database"). Items'
# own connection references often carry only the connection DISPLAY NAME
# (e.g. "LH_ContosoTicketing_Silver") with no server at all, which makes the
# lineage treat a label as if it were a database and prevents tying the read
# back to the actual Fabric lakehouse behind it -- this catalog is what lets
# 11_build_lineage_explorer_fast.py resolve those labels to host;database.
# Writes: $OutputPath.
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "../../index/fabric_connections.csv"),
    [string]$AzCommand = "az",
    [string]$FabricApiBaseUrl = "https://api.fabric.microsoft.com/v1",
    [int]$RetryCount = 4,
    [int]$RequestDelayMilliseconds = 250
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$token = Get-FreshAzureCliToken -Resource "https://api.fabric.microsoft.com" -AzCommand $AzCommand
$headers = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

$rows = [System.Collections.Generic.List[object]]::new()
$path = "connections"
while ($path) {
    $response = Invoke-FabricWebRequestCore -Method Get -Path $path -Headers $headers `
        -BaseUrl $FabricApiBaseUrl -RetryCount $RetryCount `
        -RequestDelayMilliseconds $RequestDelayMilliseconds -AzCommand $AzCommand
    if (-not $response.succeeded) {
        throw "Fabric connections request failed (HTTP $($response.status_code)): $($response.error)"
    }
    $payload = Convert-JsonContent -Content $response.content
    foreach ($connection in @($payload.value)) {
        $details = $connection.connectionDetails
        $detailPath = if ($details -and ($details.PSObject.Properties.Name -contains "path")) { [string]$details.path } else { "" }
        $detailType = if ($details -and ($details.PSObject.Properties.Name -contains "type")) { [string]$details.type } else { "" }
        $server = ""
        $database = ""
        if ($detailPath -match ";") {
            $segments = $detailPath.Split(";", 2)
            $server = $segments[0]
            $database = $segments[1]
        }
        $rows.Add([pscustomobject]@{
            connection_id = [string]$connection.id
            display_name = [string]$connection.displayName
            connectivity_type = if ($connection.PSObject.Properties.Name -contains "connectivityType") { [string]$connection.connectivityType } else { "" }
            detail_type = $detailType
            detail_path = $detailPath
            source_server = $server
            source_database = $database
        }) | Out-Null
    }
    $continuation = if ($payload.PSObject.Properties.Name -contains "continuationToken" -and $payload.continuationToken) { [string]$payload.continuationToken } else { "" }
    $path = if ($continuation) { "connections?continuationToken=$([uri]::EscapeDataString($continuation))" } else { "" }
}

Ensure-ParentDirectory -Path $OutputPath
if ($rows.Count -gt 0) {
    $rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
}
else {
    '"connection_id","display_name","connectivity_type","detail_type","detail_path","source_server","source_database"' | Set-Content -Path $OutputPath -Encoding UTF8
}

Write-Host "Fabric connections discovery completed."
Write-Host "Connections: $($rows.Count)"
Write-Host "Output: $OutputPath"
