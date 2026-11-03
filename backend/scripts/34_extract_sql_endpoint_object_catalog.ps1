# Phase 34 - SQL endpoint object catalog extraction: connects to each
# Lakehouse/Warehouse's SQL analytics endpoint directly (AAD auth via `az`)
# and queries INFORMATION_SCHEMA to catalog its real tables/views, giving
# object-level lineage a confirmed catalog to match candidates against
# instead of relying on name guesses alone.
# Writes: $OutputCatalogPath, $OutputStatusPath, $OutputSummaryPath, $OutputDocPath.
param(
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$DependenciesPath = (Join-Path $PSScriptRoot "../../index/dependencies.csv"),
    [string]$OutputCatalogPath = (Join-Path $PSScriptRoot "../../analysis/sql_endpoint_object_catalog.csv"),
    [string]$OutputStatusPath = (Join-Path $PSScriptRoot "../../analysis/sql_endpoint_object_catalog_status.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/sql_endpoint_object_catalog_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/31_sql_endpoint_object_catalog.md"),
    [string]$UnresolvedPath = (Join-Path $PSScriptRoot "../../index/unresolved.md"),
    [string]$AzCommand = "az",
    [string]$WorkspaceNameFilter = "",
    [string]$ItemNameFilter = "",
    [int]$MaxTargets = 0,
    [int]$ConnectTimeoutSeconds = 12,
    [int]$CommandTimeoutSeconds = 90,
    [switch]$TrustServerCertificate,
    [switch]$DisableWorkspaceSeedHosts
)

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

function New-ObjectKey {
    param(
        [string]$SourceType,
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$SchemaName,
        [string]$ObjectName
    )

    return @(
        Normalize-Key $SourceType
        Normalize-Key $SourceServer
        Normalize-Key $SourceDatabase
        Normalize-Key $SchemaName
        Normalize-Key $ObjectName
    ) -join "|"
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

function Invoke-SqlEndpointCatalogQuery {
    param(
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$AccessToken,
        [int]$ConnectTimeoutSeconds,
        [int]$CommandTimeoutSeconds,
        [bool]$TrustServerCertificate
    )

    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder["Data Source"] = "tcp:$SourceServer,1433"
    $builder["Initial Catalog"] = $SourceDatabase
    $builder["Encrypt"] = $true
    $builder["TrustServerCertificate"] = if ($TrustServerCertificate) { "True" } else { "False" }
    $builder["Connect Timeout"] = $ConnectTimeoutSeconds

    $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
    $connection.AccessToken = $AccessToken
    $rows = [System.Collections.Generic.List[object]]::new()

    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandTimeout = $CommandTimeoutSeconds
        $command.CommandText = @"
select
    s.name as schema_name,
    o.name as object_name,
    case
        when o.type in ('U', 'ET') then 'table'
        when o.type = 'V' then 'view'
        when o.type in ('P', 'PC', 'X', 'RF') then 'stored_procedure'
        else lower(o.type_desc)
    end as object_type,
    o.type as type_code,
    o.type_desc as type_desc,
    convert(varchar(33), o.create_date, 126) as create_date,
    convert(varchar(33), o.modify_date, 126) as modify_date
from sys.objects o
inner join sys.schemas s on o.schema_id = s.schema_id
where
    isnull(o.is_ms_shipped, 0) = 0
    and o.type in ('U', 'ET', 'V', 'P', 'PC', 'X', 'RF')
order by s.name, o.name
"@

        $reader = $command.ExecuteReader()
        try {
            while ($reader.Read()) {
                $rows.Add([pscustomobject]@{
                    schema_name = [string]$reader["schema_name"]
                    object_name = [string]$reader["object_name"]
                    object_type = [string]$reader["object_type"]
                    type_code = [string]$reader["type_code"]
                    type_desc = [string]$reader["type_desc"]
                    create_date = [string]$reader["create_date"]
                    modify_date = [string]$reader["modify_date"]
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

function Add-Target {
    param(
        [hashtable]$Map,
        [object]$Item,
        [string]$SourceServer,
        [string]$ResolutionMethod
    )

    if (-not $SourceServer) { return }
    $database = Get-FieldValue -Object $Item -Names @("item_name")
    $key = "$(Normalize-ServerHost $SourceServer)|$(Normalize-Key $database)"
    if ($Map.ContainsKey($key)) { return }

    $Map[$key] = [pscustomobject]@{
        workspace_name = Get-FieldValue -Object $Item -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $Item -Names @("workspace_environment")
        sql_endpoint_name = $database
        sql_endpoint_qualified_name = Get-FieldValue -Object $Item -Names @("qualified_name")
        sql_endpoint_id = Get-FieldValue -Object $Item -Names @("technical_id")
        source_server = Normalize-ServerHost $SourceServer
        source_database = $database
        endpoint_resolution_method = $ResolutionMethod
    }
}

function Update-UnresolvedSection {
    param(
        [string]$Path,
        [string]$Key,
        [string]$Title,
        [string]$Status,
        [string]$Evidence,
        [string]$NextStep
    )

    Ensure-ParentDirectory -Path $Path
    $start = "<!-- unresolved:${Key}:start -->"
    $end = "<!-- unresolved:${Key}:end -->"
    $section = @(
        $start,
        "",
        "## $(Get-Date -Format 'yyyy-MM-dd') - $Title",
        "",
        "- Status: $Status",
        "- Evidence: $Evidence",
        "- Next step: $NextStep",
        "",
        $end
    ) -join [Environment]::NewLine

    $content = if (Test-Path $Path) { Get-Content -Raw -Path $Path } else { "# Unresolved Items`n" }
    $pattern = [regex]::Escape($start) + "(?s).*?" + [regex]::Escape($end)
    if ([regex]::IsMatch($content, $pattern)) {
        $content = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $section })
    }
    else {
        $content = $content.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $section + [Environment]::NewLine
    }
    Set-Content -Path $Path -Value $content -Encoding UTF8
}

foreach ($path in @($ItemsPath, $DependenciesPath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$items = @(Import-Csv -Path $ItemsPath)
$sqlEndpointItems = @(
    $items |
        Where-Object { (Get-FieldValue -Object $_ -Names @("item_type")) -in @("SQLEndpoint", "Warehouse", "SQLDatabase") }
)

$workspaceFilters = @()
if ($WorkspaceNameFilter) {
    $workspaceFilters = @(
        $WorkspaceNameFilter -split "[;,]" |
            ForEach-Object { Normalize-Key $_ } |
            Where-Object { $_ }
    )
    $sqlEndpointItems = @($sqlEndpointItems | Where-Object { (Normalize-Key (Get-FieldValue -Object $_ -Names @("workspace_name"))) -in $workspaceFilters })
}

if ($ItemNameFilter) {
    $itemFilters = @(
        $ItemNameFilter -split "[;,]" |
            ForEach-Object { Normalize-Key $_ } |
            Where-Object { $_ }
    )
    $sqlEndpointItems = @($sqlEndpointItems | Where-Object { (Normalize-Key (Get-FieldValue -Object $_ -Names @("item_name"))) -in $itemFilters })
}

$itemsByDatabase = @{}
foreach ($item in $sqlEndpointItems) {
    $dbKey = Normalize-Key (Get-FieldValue -Object $item -Names @("item_name"))
    if (-not $itemsByDatabase.ContainsKey($dbKey)) {
        $itemsByDatabase[$dbKey] = [System.Collections.Generic.List[object]]::new()
    }
    $itemsByDatabase[$dbKey].Add($item) | Out-Null
}

$directServerByDatabase = @{}
foreach ($dependency in @(Import-Csv -Path $DependenciesPath)) {
    $target = Get-FieldValue -Object $dependency -Names @("to_qualified_name")
    if ($target -notmatch "^External Connection / SQL / (?<connection>.+)$") { continue }
    $connection = $Matches.connection
    # Warehouse hosts are *.datawarehouse.fabric.microsoft.com; Fabric SQL
    # database (2025 preview) hosts are *.database.fabric.microsoft.com --
    # both accepted here since this indirect discovery pass (parsing
    # connection labels other items' definitions happened to mention) has
    # no per-item-type branch of its own.
    if ($connection -notmatch "(datawarehouse|database)\.fabric\.microsoft\.com") { continue }
    $server = ""
    $database = ""
    if ($connection.Contains(";")) {
        $parts = $connection.Split(";", 2)
        $server = Normalize-ServerHost $parts[0]
        $database = $parts[1].Trim()
    }
    else {
        continue
    }
    if (-not $server -or -not $database) { continue }

    $dbKey = Normalize-Key $database
    if (-not $directServerByDatabase.ContainsKey($dbKey)) {
        $directServerByDatabase[$dbKey] = [System.Collections.Generic.List[string]]::new()
    }
    if ($server -notin @($directServerByDatabase[$dbKey].ToArray())) {
        $directServerByDatabase[$dbKey].Add($server) | Out-Null
    }
}

$targetMap = @{}
foreach ($dbKey in $itemsByDatabase.Keys) {
    if (-not $directServerByDatabase.ContainsKey($dbKey)) { continue }
    foreach ($item in @($itemsByDatabase[$dbKey].ToArray())) {
        foreach ($server in @($directServerByDatabase[$dbKey].ToArray())) {
            Add-Target -Map $targetMap -Item $item -SourceServer $server -ResolutionMethod "confirmed_sql_dependency"
        }
    }
}

if (-not $DisableWorkspaceSeedHosts) {
    $seedServersByWorkspace = @{}
    foreach ($target in @($targetMap.Values)) {
        $workspaceKey = Normalize-Key $target.workspace_name
        if (-not $seedServersByWorkspace.ContainsKey($workspaceKey)) {
            $seedServersByWorkspace[$workspaceKey] = [System.Collections.Generic.List[string]]::new()
        }
        if ($target.source_server -notin @($seedServersByWorkspace[$workspaceKey].ToArray())) {
            $seedServersByWorkspace[$workspaceKey].Add($target.source_server) | Out-Null
        }
    }

    foreach ($item in $sqlEndpointItems) {
        $workspaceKey = Normalize-Key (Get-FieldValue -Object $item -Names @("workspace_name"))
        if (-not $seedServersByWorkspace.ContainsKey($workspaceKey)) { continue }
        foreach ($server in @($seedServersByWorkspace[$workspaceKey].ToArray())) {
            Add-Target -Map $targetMap -Item $item -SourceServer $server -ResolutionMethod "same_workspace_seed_host_probe"
        }
    }
}

$targets = @($targetMap.Values | Sort-Object workspace_name, sql_endpoint_name, endpoint_resolution_method, source_server)
if ($MaxTargets -gt 0) {
    $targets = @($targets | Select-Object -First $MaxTargets)
}

$catalogRows = [System.Collections.Generic.List[object]]::new()
$statusRows = [System.Collections.Generic.List[object]]::new()
$accessToken = ""
if ($targets.Count -gt 0) {
    $accessToken = Get-DatabaseAccessToken -AzCommand $AzCommand
}

foreach ($target in $targets) {
    Write-Host "Catalog query: $($target.workspace_name) / $($target.sql_endpoint_name) via $($target.source_server) [$($target.endpoint_resolution_method)]"
    $metadataRows = @()
    $status = "catalog_query_succeeded"
    $errorText = ""

    try {
        $metadataRows = @(Invoke-SqlEndpointCatalogQuery `
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
        workspace_name = $target.workspace_name
        workspace_environment = $target.workspace_environment
        sql_endpoint_name = $target.sql_endpoint_name
        sql_endpoint_qualified_name = $target.sql_endpoint_qualified_name
        sql_endpoint_id = $target.sql_endpoint_id
        source_server = $target.source_server
        source_database = $target.source_database
        endpoint_resolution_method = $target.endpoint_resolution_method
        status = $status
        object_count = @($metadataRows).Count
        error = $errorText
        reviewed_at = (Get-Date).ToString("s")
    }) | Out-Null

    if ($status -ne "catalog_query_succeeded") { continue }

    foreach ($metadata in $metadataRows) {
        $objectKey = New-ObjectKey -SourceType "Fabric" -SourceServer $target.source_server -SourceDatabase $target.source_database -SchemaName $metadata.schema_name -ObjectName $metadata.object_name
        $catalogRows.Add([pscustomobject]@{
            object_key = $objectKey
            object_display_name = "$($target.source_database) / $($metadata.schema_name).$($metadata.object_name)"
            source_type = "Fabric"
            source_server = $target.source_server
            source_database = $target.source_database
            schema_name = $metadata.schema_name
            object_name = $metadata.object_name
            object_type = $metadata.object_type
            raw_object_type = $metadata.object_type
            object_type_source = "sql_endpoint_catalog"
            object_type_confidence = "confirmed"
            workspace_name = $target.workspace_name
            workspace_environment = $target.workspace_environment
            sql_endpoint_name = $target.sql_endpoint_name
            sql_endpoint_qualified_name = $target.sql_endpoint_qualified_name
            sql_endpoint_id = $target.sql_endpoint_id
            endpoint_resolution_method = $target.endpoint_resolution_method
            catalog_status = "confirmed"
            evidence = "Read-only sys.objects catalog query against Fabric SQL endpoint $($target.source_server)/$($target.source_database) found $($metadata.schema_name).$($metadata.object_name) as $($metadata.type_desc)."
            reviewed_at = (Get-Date).ToString("s")
            metadata_type_code = $metadata.type_code
            metadata_type_desc = $metadata.type_desc
            create_date = $metadata.create_date
            modify_date = $metadata.modify_date
        }) | Out-Null
    }
}

$catalogColumns = @(
    "object_key", "object_display_name", "source_type", "source_server", "source_database",
    "schema_name", "object_name", "object_type", "raw_object_type", "object_type_source",
    "object_type_confidence", "workspace_name", "workspace_environment", "sql_endpoint_name",
    "sql_endpoint_qualified_name", "sql_endpoint_id", "endpoint_resolution_method",
    "catalog_status", "evidence", "reviewed_at", "metadata_type_code", "metadata_type_desc",
    "create_date", "modify_date"
)
$statusColumns = @(
    "workspace_name", "workspace_environment", "sql_endpoint_name", "sql_endpoint_qualified_name",
    "sql_endpoint_id", "source_server", "source_database", "endpoint_resolution_method",
    "status", "object_count", "error", "reviewed_at"
)

if ($workspaceFilters.Count -gt 0) {
    if (Test-Path $OutputCatalogPath) {
        $retainedCatalogRows = @(
            Import-Csv -Path $OutputCatalogPath |
                Where-Object { (Normalize-Key (Get-FieldValue -Object $_ -Names @("workspace_name"))) -notin $workspaceFilters }
        )
        foreach ($row in $retainedCatalogRows) { $catalogRows.Add($row) | Out-Null }
    }
    if (Test-Path $OutputStatusPath) {
        $retainedStatusRows = @(
            Import-Csv -Path $OutputStatusPath |
                Where-Object { (Normalize-Key (Get-FieldValue -Object $_ -Names @("workspace_name"))) -notin $workspaceFilters }
        )
        foreach ($row in $retainedStatusRows) { $statusRows.Add($row) | Out-Null }
    }
}

$catalogRows = @($catalogRows | Sort-Object source_database, schema_name, object_name, source_server -Unique)
$statusRows = @($statusRows | Sort-Object workspace_name, sql_endpoint_name, source_server -Unique)

Export-Rows -Rows $catalogRows -Columns $catalogColumns -Path $OutputCatalogPath
Export-Rows -Rows $statusRows -Columns $statusColumns -Path $OutputStatusPath
if ($workspaceFilters.Count -gt 0) {
    Write-Host "Workspace filter: $WorkspaceNameFilter (other workspaces retained unchanged from $OutputCatalogPath / $OutputStatusPath)"
}

$summaryRows = [System.Collections.Generic.List[object]]::new()
$summaryRows.Add([pscustomobject]@{ metric = "sql_endpoint_items_considered"; value = $sqlEndpointItems.Count; notes = "SQLEndpoint/Warehouse items after optional filters." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "metadata_targets_attempted"; value = $targets.Count; notes = "Unique server/database probes derived from confirmed SQL dependencies plus same-workspace seed hosts." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "metadata_targets_succeeded"; value = @($statusRows | Where-Object { $_.status -eq "catalog_query_succeeded" }).Count; notes = "" }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "metadata_targets_failed"; value = @($statusRows | Where-Object { $_.status -ne "catalog_query_succeeded" }).Count; notes = "" }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "catalog_objects"; value = $catalogRows.Count; notes = "Confirmed table/view/stored-procedure objects from sys.objects." }) | Out-Null
foreach ($group in @($catalogRows | Group-Object source_database | Sort-Object Count -Descending)) {
    $summaryRows.Add([pscustomobject]@{ metric = "database:$($group.Name)"; value = $group.Count; notes = "" }) | Out-Null
}
foreach ($group in @($catalogRows | Group-Object object_type | Sort-Object Count -Descending)) {
    $summaryRows.Add([pscustomobject]@{ metric = "object_type:$($group.Name)"; value = $group.Count; notes = "" }) | Out-Null
}
Export-Rows -Rows $summaryRows -Columns @("metric", "value", "notes") -Path $OutputSummaryPath

$docLines = [System.Collections.Generic.List[string]]::new()
$docLines.Add("# SQL Endpoint Object Catalog") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Generated at: $(Get-Date -Format s)") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Purpose") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Build a local, read-only catalog of Fabric SQL Endpoint and Warehouse objects so reverse-impact filters can show known tables, views, and stored procedures even before an item-level consumer has been detected.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Current Summary") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- SQL endpoint or warehouse items considered: $($sqlEndpointItems.Count).") | Out-Null
$docLines.Add("- Metadata targets attempted: $($targets.Count).") | Out-Null
$docLines.Add("- Metadata targets succeeded: $(@($statusRows | Where-Object { $_.status -eq 'catalog_query_succeeded' }).Count).") | Out-Null
$docLines.Add("- Metadata targets failed: $(@($statusRows | Where-Object { $_.status -ne 'catalog_query_succeeded' }).Count).") | Out-Null
$docLines.Add("- Confirmed catalog objects: $($catalogRows.Count).") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Outputs") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- ``$OutputCatalogPath``") | Out-Null
$docLines.Add("- ``$OutputStatusPath``") | Out-Null
$docLines.Add("- ``$OutputSummaryPath``") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Safety") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("This script only performs read-only `sys.objects` queries. It does not create, update, delete, deploy, refresh, schedule, or trigger Fabric or SQL objects.") | Out-Null
Ensure-ParentDirectory -Path $OutputDocPath
$docLines | Set-Content -Path $OutputDocPath -Encoding UTF8

Update-UnresolvedSection `
    -Path $UnresolvedPath `
    -Key "sql-endpoint-object-catalog-gaps" `
    -Title "SQL endpoint object catalog gaps" `
    -Status "partial" `
    -Evidence "Read-only SQL endpoint catalog extraction attempted $($targets.Count) metadata targets, succeeded on $(@($statusRows | Where-Object { $_.status -eq 'catalog_query_succeeded' }).Count), failed on $(@($statusRows | Where-Object { $_.status -ne 'catalog_query_succeeded' }).Count), and catalogued $($catalogRows.Count) objects." `
    -NextStep "Review $OutputStatusPath for endpoints with unresolved host/database or failed read-only metadata access."

Write-Host "SQL endpoint object catalog extraction completed."
Write-Host "Targets attempted: $($targets.Count)"
Write-Host "Catalog objects: $($catalogRows.Count)"
Write-Host "Catalog: $OutputCatalogPath"
