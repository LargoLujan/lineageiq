# Phase 63 - Object column catalog extraction: for every SQL/Fabric
# database already referenced by item/pipeline/semantic-model candidates
# or the confirmed SQL endpoint catalog, connects (AAD auth) and reads
# sys.columns to catalog every object's actual column list -- the deepest
# level of detail the impact/reverse-search UI can show per object.
# Writes: $OutputCatalogPath, $OutputStatusPath, $OutputSummaryPath, $OutputDocPath.
param(
    [string]$ItemObjectLineageCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/item_object_lineage_candidates.csv"),
    [string]$PipelineObjectLineageCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/pipeline_object_lineage_candidates.csv"),
    [string]$ViewCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_view_candidates.csv"),
    [string]$SqlEndpointCatalogPath = (Join-Path $PSScriptRoot "../../analysis/sql_endpoint_object_catalog.csv"),
    [string]$DeepCatalogColumnsPath = (Join-Path $PSScriptRoot "../../analysis/sql_server_deep_catalog_columns.csv"),
    [string]$OutputCatalogPath = (Join-Path $PSScriptRoot "../../analysis/object_column_catalog.csv"),
    [string]$OutputStatusPath = (Join-Path $PSScriptRoot "../../analysis/object_column_catalog_status.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/object_column_catalog_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/46_object_column_catalog.md"),
    [string]$AzCommand = "az",
    [string]$WorkspaceNameFilter = "",
    [int]$MaxTargets = 0,
    [int]$ConnectTimeoutSeconds = 12,
    [int]$CommandTimeoutSeconds = 90,
    [switch]$TrustServerCertificate
)

# Read-only sys.columns catalog for every SQL/Fabric database this project already
# references (from item/pipeline/semantic-model candidates and the confirmed SQL
# endpoint catalog), so table/view detail panels can show real column name + type
# alongside server/database/schema/table. Uses Azure CLI AAD tokens by default; for
# external SQL Server hosts that only accept SQL login (not AAD), falls back to the
# same optional SQL_METADATA_USER/PASSWORD env vars already used by scripts 20 and
# 48 -- allow-listed by SQL_METADATA_HOST, never read from a file, never logged.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

function Export-Rows {
    param(
        [object[]]$Rows,
        [string[]]$Columns,
        [string]$Path
    )
    Ensure-ParentDirectory -Path $Path
    if ($Rows.Count -gt 0) {
        $Rows | Select-Object -Property $Columns | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
    }
    else {
        ('"' + ($Columns -join '","') + '"') | Set-Content -Path $Path -Encoding UTF8
    }
}

function Get-FieldValue {
    param([object]$Object, [string[]]$Names)
    if ($null -eq $Object) { return "" }
    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            $value = $Object.$name
            if ($null -ne $value) { return [string]$value }
        }
    }
    return ""
}

function Normalize-Key {
    param([string]$Value)
    if (-not $Value) { return "" }
    return (($Value.Trim()).ToLowerInvariant() -replace "\s+", " ")
}

function Normalize-ServerHost {
    param([string]$Value)
    if (-not $Value) { return "" }
    $clean = $Value.Trim().ToLowerInvariant()
    $clean = $clean -replace "^tcp:", ""
    if ($clean.Contains(",")) {
        $clean = $clean.Split(",")[0]
    }
    elseif (($clean -split ":").Count -eq 2) {
        $clean = $clean.Split(":")[0]
    }
    return $clean.Trim()
}

function New-TargetKey {
    param([string]$SourceServer, [string]$SourceDatabase)
    return "$(Normalize-ServerHost $SourceServer)|$(Normalize-Key $SourceDatabase)"
}

function Add-Target {
    param(
        [hashtable]$Map,
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$WorkspaceName
    )
    $server = Normalize-ServerHost $SourceServer
    $database = ($SourceDatabase | ForEach-Object { $_.Trim() })
    if (-not $server -or -not $database) { return }
    $key = New-TargetKey -SourceServer $server -SourceDatabase $database
    if (-not $Map.ContainsKey($key)) {
        $Map[$key] = [pscustomobject]@{
            source_server = $server
            source_database = $database
            workspaces = [System.Collections.Generic.List[string]]::new()
        }
    }
    if ($WorkspaceName -and ($Map[$key].workspaces -notcontains $WorkspaceName)) {
        $Map[$key].workspaces.Add($WorkspaceName) | Out-Null
    }
}

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

function Get-EnvironmentValue {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { return $value }
    }
    return ""
}

# Some external SQL Server hosts (e.g. on-prem/Azure SQL Server, as opposed to
# Fabric SQL analytics endpoints) only accept SQL login, not the caller's AAD
# token. When set, these env vars opt a specific allow-listed host into SQL
# auth -- same mechanism already used by scripts 20 and 48. Never read from a
# file in this repo and never logged; the operator sets them in their own
# shell only.
function Get-SqlMetadataPasswordAuth {
    param([string]$SourceServer)
    $hostSetting = Get-EnvironmentValue -Names @("FABRIC_LINEAGE_SQL_METADATA_HOST", "SQL_METADATA_HOST")
    $user = Get-EnvironmentValue -Names @("FABRIC_LINEAGE_SQL_METADATA_USER", "SQL_METADATA_USER")
    $password = Get-EnvironmentValue -Names @("FABRIC_LINEAGE_SQL_METADATA_PASSWORD", "SQL_METADATA_PASSWORD")
    $portRaw = Get-EnvironmentValue -Names @("FABRIC_LINEAGE_SQL_METADATA_PORT", "SQL_METADATA_PORT")

    if (-not $hostSetting -or -not $user -or -not $password) { return $null }

    $sourceHost = Normalize-ServerHost -Value $SourceServer
    $allowedHosts = @(
        $hostSetting -split "[;,]" |
            ForEach-Object { Normalize-ServerHost -Value $_ } |
            Where-Object { $_ }
    )
    if ($sourceHost -notin $allowedHosts) { return $null }

    $port = 1433
    if ($portRaw) {
        $parsedPort = 0
        if ([int]::TryParse($portRaw, [ref]$parsedPort) -and $parsedPort -gt 0) {
            $port = $parsedPort
        }
    }

    return [pscustomobject]@{
        User = $user
        Password = $password
        Port = $port
    }
}

function Invoke-ColumnCatalogQuery {
    param(
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$AccessToken,
        [int]$ConnectTimeoutSeconds,
        [int]$CommandTimeoutSeconds,
        [bool]$TrustServerCertificate
    )

    $sqlAuth = Get-SqlMetadataPasswordAuth -SourceServer $SourceServer
    $port = if ($null -ne $sqlAuth) { $sqlAuth.Port } else { 1433 }
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder["Data Source"] = "tcp:$SourceServer,$port"
    $builder["Initial Catalog"] = $SourceDatabase
    $builder["Encrypt"] = $true
    $builder["TrustServerCertificate"] = if ($TrustServerCertificate) { "True" } else { "False" }
    $builder["Connect Timeout"] = $ConnectTimeoutSeconds
    if ($null -ne $sqlAuth) {
        $builder["User ID"] = $sqlAuth.User
        $builder["Password"] = $sqlAuth.Password
    }

    $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
    if ($null -eq $sqlAuth) {
        $connection.AccessToken = $AccessToken
    }
    $rows = [System.Collections.Generic.List[object]]::new()

    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandTimeout = $CommandTimeoutSeconds
        $command.CommandText = @"
select
    s.name as schema_name,
    o.name as object_name,
    c.column_id,
    c.name as column_name,
    t.name as data_type,
    c.max_length,
    c.precision,
    c.scale,
    c.is_nullable,
    c.is_identity,
    c.is_computed
from sys.columns c
inner join sys.objects o on c.object_id = o.object_id
inner join sys.schemas s on o.schema_id = s.schema_id
inner join sys.types t on c.user_type_id = t.user_type_id
where isnull(o.is_ms_shipped, 0) = 0
  and o.type in ('U', 'ET', 'V')
order by s.name, o.name, c.column_id;
"@

        $reader = $command.ExecuteReader()
        try {
            while ($reader.Read()) {
                $rows.Add([pscustomobject]@{
                    schema_name = [string]$reader["schema_name"]
                    object_name = [string]$reader["object_name"]
                    column_id = [string]$reader["column_id"]
                    column_name = [string]$reader["column_name"]
                    data_type = [string]$reader["data_type"]
                    max_length = [string]$reader["max_length"]
                    precision = [string]$reader["precision"]
                    scale = [string]$reader["scale"]
                    is_nullable = [string]$reader["is_nullable"]
                    is_identity = [string]$reader["is_identity"]
                    is_computed = [string]$reader["is_computed"]
                }) | Out-Null
            }
        }
        finally {
            $reader.Close()
        }
    }
    finally {
        $connection.Dispose()
    }

    return $rows
}

$targetMap = @{}

if (Test-Path $ItemObjectLineageCandidatesPath) {
    foreach ($row in @(Import-Csv -Path $ItemObjectLineageCandidatesPath)) {
        Add-Target -Map $targetMap -SourceServer (Get-FieldValue -Object $row -Names @("source_server")) -SourceDatabase (Get-FieldValue -Object $row -Names @("source_database", "database_name")) -WorkspaceName (Get-FieldValue -Object $row -Names @("workspace_name"))
    }
}
if (Test-Path $PipelineObjectLineageCandidatesPath) {
    foreach ($row in @(Import-Csv -Path $PipelineObjectLineageCandidatesPath)) {
        Add-Target -Map $targetMap -SourceServer (Get-FieldValue -Object $row -Names @("source_server")) -SourceDatabase (Get-FieldValue -Object $row -Names @("source_database", "database_name")) -WorkspaceName (Get-FieldValue -Object $row -Names @("workspace_name"))
    }
}
if (Test-Path $ViewCandidatesPath) {
    foreach ($row in @(Import-Csv -Path $ViewCandidatesPath)) {
        Add-Target -Map $targetMap -SourceServer (Get-FieldValue -Object $row -Names @("source_server")) -SourceDatabase (Get-FieldValue -Object $row -Names @("database_name", "source_database")) -WorkspaceName (Get-FieldValue -Object $row -Names @("workspace_name"))
    }
}
if (Test-Path $SqlEndpointCatalogPath) {
    foreach ($row in @(Import-Csv -Path $SqlEndpointCatalogPath)) {
        Add-Target -Map $targetMap -SourceServer (Get-FieldValue -Object $row -Names @("source_server")) -SourceDatabase (Get-FieldValue -Object $row -Names @("source_database")) -WorkspaceName (Get-FieldValue -Object $row -Names @("workspace_name"))
    }
}

$targets = @($targetMap.Values | Sort-Object source_server, source_database)

$workspaceFilterSet = $null
if ($WorkspaceNameFilter) {
    $workspaceFilterSet = @{}
    foreach ($name in ($WorkspaceNameFilter -split "[;,]" | ForEach-Object { Normalize-Key $_ } | Where-Object { $_ })) {
        $workspaceFilterSet[$name] = $true
    }
    $targets = @(
        $targets | Where-Object {
            $groupWorkspaces = @($_.workspaces.ToArray() | ForEach-Object { Normalize-Key $_ })
            @($groupWorkspaces | Where-Object { $workspaceFilterSet.ContainsKey($_) }).Count -gt 0
        }
    )
}

if ($MaxTargets -gt 0) {
    $targets = @($targets | Select-Object -First $MaxTargets)
}

$queriedTargetKeys = @{}
foreach ($target in $targets) {
    $queriedTargetKeys[(New-TargetKey -SourceServer $target.source_server -SourceDatabase $target.source_database)] = $true
}

$catalogRows = [System.Collections.Generic.List[object]]::new()
$statusRows = [System.Collections.Generic.List[object]]::new()
$capturedAt = (Get-Date).ToString("s")

$accessToken = ""
if ($targets.Count -gt 0) {
    $accessToken = Get-DatabaseAccessToken -AzCommand $AzCommand
}

foreach ($target in $targets) {
    Write-Host "Column catalog query: $($target.source_server) / $($target.source_database)"
    $status = "catalog_query_succeeded"
    $errorText = ""
    $columnRows = @()

    try {
        $columnRows = @(Invoke-ColumnCatalogQuery `
            -SourceServer $target.source_server `
            -SourceDatabase $target.source_database `
            -AccessToken $accessToken `
            -ConnectTimeoutSeconds $ConnectTimeoutSeconds `
            -CommandTimeoutSeconds $CommandTimeoutSeconds `
            -TrustServerCertificate ([bool]$TrustServerCertificate))
    }
    catch {
        $status = "catalog_query_failed"
        $errorText = $_.Exception.Message
    }

    $statusRows.Add([pscustomobject]@{
        source_server = $target.source_server
        source_database = $target.source_database
        status = $status
        column_count = @($columnRows).Count
        error = $errorText
        captured_at = $capturedAt
    }) | Out-Null

    if ($status -ne "catalog_query_succeeded") { continue }

    foreach ($column in $columnRows) {
        $catalogRows.Add([pscustomobject]@{
            source_server = $target.source_server
            source_database = $target.source_database
            schema_name = $column.schema_name
            object_name = $column.object_name
            column_id = $column.column_id
            column_name = $column.column_name
            data_type = $column.data_type
            max_length = $column.max_length
            precision = $column.precision
            scale = $column.scale
            is_nullable = $column.is_nullable
            is_identity = $column.is_identity
            is_computed = $column.is_computed
            captured_at = $capturedAt
        }) | Out-Null
    }
}

# Some servers (e.g. external, on-prem/Azure SQL Server hosts that only accept
# SQL login, not the caller's AAD token) will fail every live query above. For
# those, fall back to whatever a prior sql_server_deep_catalog run (script 48,
# password-authenticated) already captured, rather than leaving the object
# with no column data at all. Only fills gaps -- never overrides a
# successful live result for the same target.
if (Test-Path $DeepCatalogColumnsPath) {
    $liveTargetKeys = @{}
    foreach ($row in $catalogRows) {
        $liveTargetKeys[(New-TargetKey -SourceServer $row.source_server -SourceDatabase $row.source_database)] = $true
    }
    $targetsNeedingFallback = @($targets | Where-Object { -not $liveTargetKeys.ContainsKey((New-TargetKey -SourceServer $_.source_server -SourceDatabase $_.source_database)) })
    if ($targetsNeedingFallback.Count -gt 0) {
        $deepCatalogByTarget = @{}
        foreach ($row in @(Import-Csv -Path $DeepCatalogColumnsPath)) {
            $key = New-TargetKey -SourceServer $row.source_server -SourceDatabase $row.database_name
            if (-not $deepCatalogByTarget.ContainsKey($key)) {
                $deepCatalogByTarget[$key] = [System.Collections.Generic.List[object]]::new()
            }
            $deepCatalogByTarget[$key].Add($row) | Out-Null
        }
        foreach ($target in $targetsNeedingFallback) {
            $targetKey = New-TargetKey -SourceServer $target.source_server -SourceDatabase $target.source_database
            if (-not $deepCatalogByTarget.ContainsKey($targetKey)) { continue }
            $fallbackRows = @($deepCatalogByTarget[$targetKey].ToArray())
            foreach ($column in $fallbackRows) {
                $catalogRows.Add([pscustomobject]@{
                    source_server = $target.source_server
                    source_database = $target.source_database
                    schema_name = $column.schema_name
                    object_name = $column.object_name
                    column_id = $column.column_id
                    column_name = $column.column_name
                    data_type = $column.data_type
                    max_length = $column.max_length
                    precision = $column.precision
                    scale = $column.scale
                    is_nullable = $column.is_nullable
                    is_identity = $column.is_identity
                    is_computed = $column.is_computed
                    captured_at = Get-FieldValue -Object $column -Names @("captured_at")
                }) | Out-Null
            }
            $fallbackStatus = @($statusRows | Where-Object { $_.source_server -eq $target.source_server -and $_.source_database -eq $target.source_database } | Select-Object -First 1)
            if ($fallbackStatus.Count -gt 0 -and $fallbackRows.Count -gt 0) {
                $fallbackStatus[0].status = "catalog_query_failed_used_deep_catalog_fallback"
                $fallbackStatus[0].column_count = $fallbackRows.Count
            }
        }
    }
}

$catalogColumns = @("source_server", "source_database", "schema_name", "object_name", "column_id", "column_name", "data_type", "max_length", "precision", "scale", "is_nullable", "is_identity", "is_computed", "captured_at")
$statusColumns = @("source_server", "source_database", "status", "column_count", "error", "captured_at")

if ($workspaceFilterSet) {
    if (Test-Path $OutputCatalogPath) {
        foreach ($row in @(Import-Csv -Path $OutputCatalogPath | Where-Object { -not $queriedTargetKeys.ContainsKey((New-TargetKey -SourceServer $_.source_server -SourceDatabase $_.source_database)) })) {
            $catalogRows.Add($row) | Out-Null
        }
    }
    if (Test-Path $OutputStatusPath) {
        foreach ($row in @(Import-Csv -Path $OutputStatusPath | Where-Object { -not $queriedTargetKeys.ContainsKey((New-TargetKey -SourceServer $_.source_server -SourceDatabase $_.source_database)) })) {
            $statusRows.Add($row) | Out-Null
        }
    }
}

$catalogRows = @($catalogRows | Sort-Object source_server, source_database, schema_name, object_name, column_id -Unique)
$statusRows = @($statusRows | Sort-Object source_server, source_database -Unique)

Export-Rows -Rows $catalogRows -Columns $catalogColumns -Path $OutputCatalogPath
Export-Rows -Rows $statusRows -Columns $statusColumns -Path $OutputStatusPath
if ($workspaceFilterSet) {
    Write-Host "Workspace filter: $WorkspaceNameFilter (other targets retained unchanged from $OutputCatalogPath / $OutputStatusPath)"
}

$summaryRows = [System.Collections.Generic.List[object]]::new()
$summaryRows.Add([pscustomobject]@{ metric = "targets_attempted"; value = $targets.Count; notes = "Unique source_server/source_database pairs derived from item/pipeline/semantic-model candidates and the confirmed SQL endpoint catalog." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "targets_succeeded"; value = @($statusRows | Where-Object { $_.status -eq "catalog_query_succeeded" }).Count; notes = "" }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "targets_failed"; value = @($statusRows | Where-Object { $_.status -ne "catalog_query_succeeded" }).Count; notes = "" }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "column_rows"; value = $catalogRows.Count; notes = "Confirmed table/view column rows from sys.columns." }) | Out-Null
Export-Rows -Rows $summaryRows -Columns @("metric", "value", "notes") -Path $OutputSummaryPath

$docLines = [System.Collections.Generic.List[string]]::new()
$docLines.Add("# Object Column Catalog") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Generated at: $capturedAt") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Purpose") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Read-only `sys.columns` catalog (name + data type) for every SQL/Fabric table or view already referenced by an item, pipeline, or semantic model in this project, so detail panels can show real column composition alongside server/database/schema/table.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Current Summary") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- Targets attempted: $($targets.Count).") | Out-Null
$docLines.Add("- Targets succeeded: $(@($statusRows | Where-Object { $_.status -eq 'catalog_query_succeeded' }).Count).") | Out-Null
$docLines.Add("- Targets failed: $(@($statusRows | Where-Object { $_.status -ne 'catalog_query_succeeded' }).Count).") | Out-Null
$docLines.Add("- Column rows captured: $($catalogRows.Count).") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Outputs") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- ``$OutputCatalogPath``") | Out-Null
$docLines.Add("- ``$OutputStatusPath``") | Out-Null
$docLines.Add("- ``$OutputSummaryPath``") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Safety") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("This script only performs read-only `sys.columns` queries using the current Azure CLI session's AAD token. It does not create, update, delete, deploy, refresh, schedule, or trigger Fabric or SQL objects, and it never stores a SQL password.") | Out-Null
Ensure-ParentDirectory -Path $OutputDocPath
$docLines | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "Object column catalog extraction completed."
Write-Host "Targets attempted: $($targets.Count)"
Write-Host "Column rows: $($catalogRows.Count)"
Write-Host "Catalog: $OutputCatalogPath"
