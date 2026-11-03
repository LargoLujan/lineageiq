param(
    [string]$LakehouseConfig = (Join-Path $PSScriptRoot "../../config/lakehouse_target.json"),
    [string]$AzCommand = "az",
    [switch]$TrustServerCertificate,
    [int]$ConnectTimeoutSeconds = 30,
    [int]$CommandTimeoutSeconds = 60
)

# Phase 65 - Lakehouse gold parity validation.
# Read-only parity check between the local CSVs this project already
# produces and the Bronze/Gold Delta tables in the project-owned Lakehouse
# (see docs/101_medallion_lakehouse_provisioning.md). Reuses, unchanged, the
# exact AAD-token SQL connection pattern already proven read-only against
# Fabric SQL endpoints in backend/scripts/34_extract_sql_endpoint_object_catalog.ps1
# -- just pointed at the new Lakehouse's own SQL analytics endpoint instead
# of a scanned tenant's SQL Server.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DatabaseAccessToken {
    param([string]$AzCommand)
    # A signed-in web-app user's own delegated SQL/OneLake token, if the
    # process that spawned this script set one (see
    # FABRIC_LINEAGE_USER_SQL_TOKEN in lineage_web_server.py) -- falls back
    # to the shared `az` CLI session below when run standalone from a
    # terminal, exactly as before.
    if ($env:FABRIC_LINEAGE_USER_SQL_TOKEN) {
        return $env:FABRIC_LINEAGE_USER_SQL_TOKEN
    }
    $token = & $AzCommand account get-access-token --resource "https://database.windows.net/" --query accessToken -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw "Could not acquire Azure SQL/Fabric database token with '$AzCommand account get-access-token'."
    }
    return [string]$token
}

function New-LakehouseSqlConnection {
    param(
        [string]$SqlEndpointConnectionString,
        [string]$LakehouseName,
        [string]$AccessToken,
        [bool]$TrustServerCertificate,
        [int]$ConnectTimeoutSeconds
    )
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder["Data Source"] = "tcp:$SqlEndpointConnectionString,1433"
    $builder["Initial Catalog"] = $LakehouseName
    $builder["Encrypt"] = $true
    $builder["TrustServerCertificate"] = if ($TrustServerCertificate) { "True" } else { "False" }
    $builder["Connect Timeout"] = $ConnectTimeoutSeconds

    $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
    $connection.AccessToken = $AccessToken
    return $connection
}

function Get-TableRowCount {
    param([System.Data.SqlClient.SqlConnection]$Connection, [string]$TableName, [int]$CommandTimeoutSeconds, [string]$WhereClause = "")
    $command = $Connection.CreateCommand()
    $command.CommandTimeout = $CommandTimeoutSeconds
    $sql = "select count(*) as row_count from [$TableName]"
    if ($WhereClause) { $sql += " where $WhereClause" }
    $command.CommandText = $sql
    try {
        return [int64]$command.ExecuteScalar()
    }
    catch {
        return $null
    }
}

function Get-LatestSnapshotDate {
    param([System.Data.SqlClient.SqlConnection]$Connection, [string]$TableName, [int]$CommandTimeoutSeconds)
    $command = $Connection.CreateCommand()
    $command.CommandTimeout = $CommandTimeoutSeconds
    $command.CommandText = "select convert(varchar(10), max(snapshot_date), 23) as latest_date from [$TableName]"
    try {
        $value = $command.ExecuteScalar()
        if ($value -is [DBNull] -or -not $value) { return $null }
        return [string]$value
    }
    catch {
        return $null
    }
}

function Get-LocalCsvRowCount {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    $lineCount = [System.Linq.Enumerable]::Count([System.IO.File]::ReadLines((Resolve-Path $Path).Path))
    return [math]::Max(0, $lineCount - 1)
}

if (-not (Test-Path $LakehouseConfig)) {
    throw "Lakehouse config not found: $LakehouseConfig. See docs/101_medallion_lakehouse_provisioning.md."
}
$config = Get-Content -Path $LakehouseConfig -Raw | ConvertFrom-Json

if (-not $config.lakehouse_name -or -not $config.sql_endpoint_connection_string) {
    Write-Host "Lakehouse config is not filled in yet ($LakehouseConfig) -- nothing to validate against."
    Write-Host "See docs/101_medallion_lakehouse_provisioning.md for what to fill in once the workspace/Lakehouse exist."
    exit 0
}

Write-Host "Checking Azure CLI session..."
$token = Get-DatabaseAccessToken -AzCommand $AzCommand
Write-Host "Azure CLI session OK."

$connection = New-LakehouseSqlConnection `
    -SqlEndpointConnectionString $config.sql_endpoint_connection_string `
    -LakehouseName $config.lakehouse_name `
    -AccessToken $token `
    -TrustServerCertificate:$TrustServerCertificate `
    -ConnectTimeoutSeconds $ConnectTimeoutSeconds

$connection.Open()
Write-Host "Connected to Lakehouse SQL endpoint: $($config.lakehouse_name)"
Write-Host ""

# entity/table -> (local CSV path, Gold table to cross-check, optional Gold WHERE clause).
# Bronze parity is always "does today's partition exist and match"; Gold
# parity is a spot-check against the tables Power BI will actually query.
$checks = @(
    # GoldKind "scd2" tables carry effective_from/effective_to/is_current, not
    # snapshot_date -- only the fact ("fact") tables use snapshot_date, and
    # only those get the latest-snapshot filter applied to their Gold check.
    [pscustomobject]@{ Entity = "workspaces"; LocalPath = "index/workspaces.csv"; BronzeTable = "bronze_workspaces"; GoldTable = "gold_dim_workspace"; GoldKind = "scd2" }
    [pscustomobject]@{ Entity = "items"; LocalPath = "index/items.csv"; BronzeTable = "bronze_items"; GoldTable = "gold_dim_item"; GoldKind = "scd2" }
    [pscustomobject]@{ Entity = "dependencies"; LocalPath = "index/dependencies.csv"; BronzeTable = "bronze_dependencies"; GoldTable = "gold_fact_dependency_edge"; GoldKind = "fact" }
    [pscustomobject]@{ Entity = "executions"; LocalPath = "index/executions.csv"; BronzeTable = "bronze_executions"; GoldTable = ""; GoldKind = "" }
    [pscustomobject]@{ Entity = "object_read_write_classification"; LocalPath = "analysis/object_read_write_classification.csv"; BronzeTable = "bronze_object_read_write_classification"; GoldTable = "gold_fact_object_usage"; GoldKind = "fact" }
    [pscustomobject]@{ Entity = "workspace_governance_principals"; LocalPath = "analysis/workspace_governance_principals.csv"; BronzeTable = "bronze_workspace_governance_principals"; GoldTable = "gold_fact_workspace_principal_role"; GoldKind = "fact" }
)

$results = [System.Collections.Generic.List[object]]::new()
foreach ($check in $checks) {
    $localCount = Get-LocalCsvRowCount -Path (Join-Path $PSScriptRoot "../../$($check.LocalPath)")
    $latestSnapshot = Get-LatestSnapshotDate -Connection $connection -TableName $check.BronzeTable -CommandTimeoutSeconds $CommandTimeoutSeconds
    $bronzeCount = if ($latestSnapshot) {
        Get-TableRowCount -Connection $connection -TableName $check.BronzeTable -CommandTimeoutSeconds $CommandTimeoutSeconds -WhereClause "snapshot_date = '$latestSnapshot'"
    } else { $null }
    $goldWhere = if ($check.GoldKind -eq "scd2") { "is_current = 1" }
        elseif ($check.GoldKind -eq "fact" -and $latestSnapshot) { "snapshot_date = '$latestSnapshot'" }
        else { "" }
    $goldCount = if ($check.GoldTable) { Get-TableRowCount -Connection $connection -TableName $check.GoldTable -CommandTimeoutSeconds $CommandTimeoutSeconds -WhereClause $goldWhere } else { $null }

    $bronzeStatus = if ($null -eq $latestSnapshot) { "table not found" } elseif ($localCount -eq $bronzeCount) { "match ($latestSnapshot)" } else { "MISMATCH (local=$localCount, bronze[$latestSnapshot]=$bronzeCount)" }
    $results.Add([pscustomobject]@{
        entity = $check.Entity
        local_rows = $localCount
        bronze_rows = $bronzeCount
        bronze_status = $bronzeStatus
        gold_table = $check.GoldTable
        gold_rows = $goldCount
    }) | Out-Null
}

$connection.Close()

$results | Format-Table -AutoSize
$mismatches = @($results | Where-Object { $_.bronze_status -like "MISMATCH*" -or $_.bronze_status -eq "table not found" })
if ($mismatches.Count -gt 0) {
    Write-Host ""
    Write-Host "$($mismatches.Count) entities need attention (see table above)."
    exit 1
}

Write-Host ""
Write-Host "All checked entities match between local CSV and Bronze."
exit 0
