# Phase 48 - SQL Server deep catalog: an optional, more thorough companion
# to Phase 20/34 -- connects to each server in $SourceServers (AAD auth)
# and catalogs every database's tables/views/columns/dependencies/row
# counts (each individually toggleable via -Skip* switches), for cases
# where the lighter Phase 20/34 catalogs aren't detailed enough.
# Writes: $OutputPrefix-prefixed CSVs under $OutputDirectory, $OutputDocPath.
param(
    [string]$SourceServers = "",
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "../../analysis"),
    [string]$OutputPrefix = "sql_server_deep_catalog",
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/44_sql_server_deep_catalog.md"),
    [int]$ConnectTimeoutSeconds = 12,
    [int]$CommandTimeoutSeconds = 120,
    [switch]$TrustServerCertificate,
    [switch]$IncludeSystemDatabases,
    [switch]$SkipColumns,
    [switch]$SkipDependencies,
    [switch]$SkipRowCounts
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

function Get-EnvironmentValue {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if ($value) { return $value }
    }
    return ""
}

function Normalize-ServerHost {
    param([string]$Value)
    if (-not $Value) { return "" }
    $clean = $Value.Trim()
    $clean = $clean -replace "^tcp:", ""
    if ($clean.Contains(",")) {
        $clean = $clean.Split(",")[0]
    }
    elseif (($clean -split ":").Count -eq 2) {
        $clean = $clean.Split(":")[0]
    }
    return $clean.Trim()
}

function Get-SqlCredentialSettings {
    $user = Get-EnvironmentValue -Names @("FABRIC_LINEAGE_SQL_METADATA_USER", "SQL_METADATA_USER")
    $password = Get-EnvironmentValue -Names @("FABRIC_LINEAGE_SQL_METADATA_PASSWORD", "SQL_METADATA_PASSWORD")
    $portRaw = Get-EnvironmentValue -Names @("FABRIC_LINEAGE_SQL_METADATA_PORT", "SQL_METADATA_PORT")

    if (-not $user -or -not $password) {
        throw "SQL metadata credentials are not loaded. Set SQL_METADATA_USER and SQL_METADATA_PASSWORD, or FABRIC_LINEAGE_SQL_METADATA_USER and FABRIC_LINEAGE_SQL_METADATA_PASSWORD, in the current shell. Do not write secrets to repo files."
    }

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

function New-SqlConnection {
    param(
        [string]$Server,
        [string]$Database,
        [object]$CredentialSettings,
        [bool]$TrustServerCertificate,
        [int]$ConnectTimeoutSeconds
    )

    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder["Data Source"] = "tcp:$Server,$($CredentialSettings.Port)"
    $builder["Initial Catalog"] = $Database
    $builder["User ID"] = $CredentialSettings.User
    $builder["Password"] = $CredentialSettings.Password
    $builder["Encrypt"] = $true
    $builder["TrustServerCertificate"] = if ($TrustServerCertificate) { "True" } else { "False" }
    $builder["Connect Timeout"] = $ConnectTimeoutSeconds
    $builder["Application Name"] = "FabricLineageDeepCatalog"
    return [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
}

function Invoke-SqlRows {
    param(
        [string]$Server,
        [string]$Database,
        [object]$CredentialSettings,
        [string]$CommandText,
        [bool]$TrustServerCertificate,
        [int]$ConnectTimeoutSeconds,
        [int]$CommandTimeoutSeconds
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $connection = New-SqlConnection -Server $Server -Database $Database -CredentialSettings $CredentialSettings -TrustServerCertificate $TrustServerCertificate -ConnectTimeoutSeconds $ConnectTimeoutSeconds
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        $command.CommandTimeout = $CommandTimeoutSeconds
        $command.CommandText = $CommandText
        $reader = $command.ExecuteReader()
        try {
            $fieldNames = for ($i = 0; $i -lt $reader.FieldCount; $i++) { $reader.GetName($i) }
            while ($reader.Read()) {
                $row = [ordered]@{}
                foreach ($name in $fieldNames) {
                    $value = $reader[$name]
                    $row[$name] = if ($value -is [DBNull]) { "" } else { $value }
                }
                $rows.Add([pscustomobject]$row) | Out-Null
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

function New-GapRow {
    param([string]$Server, [string]$Database, [string]$Step, [string]$ErrorMessage)
    return [pscustomobject]@{
        source_server = $Server
        source_database = $Database
        step = $Step
        error = $ErrorMessage
        captured_at = (Get-Date).ToString("s")
        next_step = "Validate read-only SQL metadata permissions, database visibility, and network access for this target."
    }
}

$hostSetting = if ($SourceServers) { $SourceServers } else { Get-EnvironmentValue -Names @("FABRIC_LINEAGE_SQL_METADATA_HOST", "SQL_METADATA_HOST") }
if (-not $hostSetting) {
    throw "No SQL Server targets were supplied. Pass -SourceServers or set SQL_METADATA_HOST/FABRIC_LINEAGE_SQL_METADATA_HOST."
}

$servers = @(
    $hostSetting -split "[;,]" |
        ForEach-Object { Normalize-ServerHost -Value $_ } |
        Where-Object { $_ } |
        Sort-Object -Unique
)

$credentials = Get-SqlCredentialSettings
$trust = [bool]$TrustServerCertificate
$capturedAt = (Get-Date).ToString("s")

$databaseRows = [System.Collections.Generic.List[object]]::new()
$objectRows = [System.Collections.Generic.List[object]]::new()
$columnRows = [System.Collections.Generic.List[object]]::new()
$dependencyRows = [System.Collections.Generic.List[object]]::new()
$gapRows = [System.Collections.Generic.List[object]]::new()

$databaseQuery = @"
select
    name as database_name,
    database_id,
    create_date,
    compatibility_level,
    collation_name,
    state_desc,
    user_access_desc,
    recovery_model_desc,
    containment_desc,
    is_read_only
from sys.databases
where state_desc = 'ONLINE'
  and ($(if ($IncludeSystemDatabases) { "1" } else { "0" }) = 1 or database_id > 4)
order by name;
"@

$rowCountSelect = if ($SkipRowCounts) {
    "cast(null as bigint) as row_count"
}
else {
    "isnull(rc.row_count, 0) as row_count"
}

$rowCountJoin = if ($SkipRowCounts) {
    ""
}
else {
@"
left join (
    select object_id, sum(row_count) as row_count
    from sys.dm_db_partition_stats
    where index_id in (0, 1)
    group by object_id
) rc on o.object_id = rc.object_id
"@
}

$objectQuery = @"
select
    db_name() as database_name,
    s.name as schema_name,
    o.name as object_name,
    o.object_id,
    case
        when o.type in ('U', 'ET') then 'table'
        when o.type = 'V' then 'view'
        when o.type in ('P', 'PC', 'X', 'RF') then 'stored_procedure'
        when o.type in ('FN', 'IF', 'TF', 'FS', 'FT') then 'function'
        when o.type = 'SN' then 'synonym'
        else lower(o.type_desc)
    end as object_type,
    o.type as type_code,
    o.type_desc,
    o.create_date,
    o.modify_date,
    $rowCountSelect,
    syn.base_object_name as synonym_base_object_name,
    case when m.object_id is null then 0 else 1 end as has_sql_module,
    case when m.object_id is null then null else len(convert(nvarchar(max), m.definition)) end as definition_length,
    case when m.object_id is null then null else sys.fn_varbintohexstr(hashbytes('SHA2_256', convert(nvarchar(max), m.definition))) end as definition_sha256
from sys.objects o
inner join sys.schemas s on o.schema_id = s.schema_id
left join sys.synonyms syn on o.object_id = syn.object_id
left join sys.sql_modules m on o.object_id = m.object_id
$rowCountJoin
where isnull(o.is_ms_shipped, 0) = 0
  and o.type in ('U', 'ET', 'V', 'P', 'PC', 'X', 'RF', 'FN', 'IF', 'TF', 'FS', 'FT', 'SN')
order by s.name, o.name;
"@

$columnQuery = @"
select
    db_name() as database_name,
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

$dependencyQuery = @"
select
    db_name() as database_name,
    schema_name(o.schema_id) as referencing_schema_name,
    o.name as referencing_object_name,
    o.type_desc as referencing_type_desc,
    d.referenced_server_name,
    d.referenced_database_name,
    d.referenced_schema_name,
    d.referenced_entity_name,
    d.referenced_id,
    d.referenced_class_desc,
    d.is_caller_dependent,
    d.is_ambiguous
from sys.sql_expression_dependencies d
left join sys.objects o on d.referencing_id = o.object_id
where o.object_id is null or isnull(o.is_ms_shipped, 0) = 0
order by referencing_schema_name, referencing_object_name, referenced_database_name, referenced_schema_name, referenced_entity_name;
"@

foreach ($server in $servers) {
    Write-Host "Enumerating databases: $server"
    $serverDatabases = @()
    try {
        $serverDatabases = @(Invoke-SqlRows -Server $server -Database "master" -CredentialSettings $credentials -CommandText $databaseQuery -TrustServerCertificate $trust -ConnectTimeoutSeconds $ConnectTimeoutSeconds -CommandTimeoutSeconds $CommandTimeoutSeconds)
    }
    catch {
        $gapRows.Add((New-GapRow -Server $server -Database "master" -Step "database_inventory" -ErrorMessage $_.Exception.Message)) | Out-Null
        continue
    }

    foreach ($db in $serverDatabases) {
        $databaseRows.Add([pscustomobject]@{
            source_server = $server
            database_name = [string]$db.database_name
            database_id = $db.database_id
            create_date = $db.create_date
            compatibility_level = $db.compatibility_level
            collation_name = $db.collation_name
            state_desc = $db.state_desc
            user_access_desc = $db.user_access_desc
            recovery_model_desc = $db.recovery_model_desc
            containment_desc = $db.containment_desc
            is_read_only = $db.is_read_only
            captured_at = $capturedAt
        }) | Out-Null
    }

    foreach ($db in $serverDatabases) {
        $databaseName = [string]$db.database_name
        Write-Host "Cataloging: $server / $databaseName"

        try {
            foreach ($row in @(Invoke-SqlRows -Server $server -Database $databaseName -CredentialSettings $credentials -CommandText $objectQuery -TrustServerCertificate $trust -ConnectTimeoutSeconds $ConnectTimeoutSeconds -CommandTimeoutSeconds $CommandTimeoutSeconds)) {
                $objectRows.Add([pscustomobject]@{
                    source_server = $server
                    database_name = $databaseName
                    schema_name = $row.schema_name
                    object_name = $row.object_name
                    object_id = $row.object_id
                    object_type = $row.object_type
                    type_code = $row.type_code
                    type_desc = $row.type_desc
                    create_date = $row.create_date
                    modify_date = $row.modify_date
                    row_count = $row.row_count
                    synonym_base_object_name = $row.synonym_base_object_name
                    has_sql_module = $row.has_sql_module
                    definition_length = $row.definition_length
                    definition_sha256 = $row.definition_sha256
                    captured_at = $capturedAt
                }) | Out-Null
            }
        }
        catch {
            $gapRows.Add((New-GapRow -Server $server -Database $databaseName -Step "object_inventory" -ErrorMessage $_.Exception.Message)) | Out-Null
            continue
        }

        if (-not $SkipColumns) {
            try {
                foreach ($row in @(Invoke-SqlRows -Server $server -Database $databaseName -CredentialSettings $credentials -CommandText $columnQuery -TrustServerCertificate $trust -ConnectTimeoutSeconds $ConnectTimeoutSeconds -CommandTimeoutSeconds $CommandTimeoutSeconds)) {
                    $columnRows.Add([pscustomobject]@{
                        source_server = $server
                        database_name = $databaseName
                        schema_name = $row.schema_name
                        object_name = $row.object_name
                        column_id = $row.column_id
                        column_name = $row.column_name
                        data_type = $row.data_type
                        max_length = $row.max_length
                        precision = $row.precision
                        scale = $row.scale
                        is_nullable = $row.is_nullable
                        is_identity = $row.is_identity
                        is_computed = $row.is_computed
                        captured_at = $capturedAt
                    }) | Out-Null
                }
            }
            catch {
                $gapRows.Add((New-GapRow -Server $server -Database $databaseName -Step "column_inventory" -ErrorMessage $_.Exception.Message)) | Out-Null
            }
        }

        if (-not $SkipDependencies) {
            try {
                foreach ($row in @(Invoke-SqlRows -Server $server -Database $databaseName -CredentialSettings $credentials -CommandText $dependencyQuery -TrustServerCertificate $trust -ConnectTimeoutSeconds $ConnectTimeoutSeconds -CommandTimeoutSeconds $CommandTimeoutSeconds)) {
                    $dependencyRows.Add([pscustomobject]@{
                        source_server = $server
                        database_name = $databaseName
                        referencing_schema_name = $row.referencing_schema_name
                        referencing_object_name = $row.referencing_object_name
                        referencing_type_desc = $row.referencing_type_desc
                        referenced_server_name = $row.referenced_server_name
                        referenced_database_name = $row.referenced_database_name
                        referenced_schema_name = $row.referenced_schema_name
                        referenced_entity_name = $row.referenced_entity_name
                        referenced_id = $row.referenced_id
                        referenced_class_desc = $row.referenced_class_desc
                        is_caller_dependent = $row.is_caller_dependent
                        is_ambiguous = $row.is_ambiguous
                        captured_at = $capturedAt
                    }) | Out-Null
                }
            }
            catch {
                $gapRows.Add((New-GapRow -Server $server -Database $databaseName -Step "dependency_inventory" -ErrorMessage $_.Exception.Message)) | Out-Null
            }
        }
    }
}

$databasePath = Join-Path $OutputDirectory "$OutputPrefix`_databases.csv"
$objectPath = Join-Path $OutputDirectory "$OutputPrefix`_objects.csv"
$columnPath = Join-Path $OutputDirectory "$OutputPrefix`_columns.csv"
$dependencyPath = Join-Path $OutputDirectory "$OutputPrefix`_dependencies.csv"
$gapPath = Join-Path $OutputDirectory "$OutputPrefix`_gaps.csv"
$summaryPath = Join-Path $OutputDirectory "$OutputPrefix`_summary.csv"

$databaseColumns = @("source_server", "database_name", "database_id", "create_date", "compatibility_level", "collation_name", "state_desc", "user_access_desc", "recovery_model_desc", "containment_desc", "is_read_only", "captured_at")
$objectColumns = @("source_server", "database_name", "schema_name", "object_name", "object_id", "object_type", "type_code", "type_desc", "create_date", "modify_date", "row_count", "synonym_base_object_name", "has_sql_module", "definition_length", "definition_sha256", "captured_at")
$columnColumns = @("source_server", "database_name", "schema_name", "object_name", "column_id", "column_name", "data_type", "max_length", "precision", "scale", "is_nullable", "is_identity", "is_computed", "captured_at")
$dependencyColumns = @("source_server", "database_name", "referencing_schema_name", "referencing_object_name", "referencing_type_desc", "referenced_server_name", "referenced_database_name", "referenced_schema_name", "referenced_entity_name", "referenced_id", "referenced_class_desc", "is_caller_dependent", "is_ambiguous", "captured_at")
$gapColumns = @("source_server", "source_database", "step", "error", "captured_at", "next_step")

Export-Rows -Rows @($databaseRows) -Columns $databaseColumns -Path $databasePath
Export-Rows -Rows @($objectRows) -Columns $objectColumns -Path $objectPath
Export-Rows -Rows @($columnRows) -Columns $columnColumns -Path $columnPath
Export-Rows -Rows @($dependencyRows) -Columns $dependencyColumns -Path $dependencyPath
Export-Rows -Rows @($gapRows) -Columns $gapColumns -Path $gapPath

$summaryRows = [System.Collections.Generic.List[object]]::new()
$summaryRows.Add([pscustomobject]@{ metric = "servers_requested"; value = $servers.Count; notes = ($servers -join "; ") }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "databases_visible"; value = $databaseRows.Count; notes = "" }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "objects_captured"; value = $objectRows.Count; notes = "Tables, views, stored procedures, functions, synonyms, and external tables visible to the login." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "columns_captured"; value = $columnRows.Count; notes = if ($SkipColumns) { "Skipped by parameter." } else { "" } }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "dependencies_captured"; value = $dependencyRows.Count; notes = if ($SkipDependencies) { "Skipped by parameter." } else { "" } }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "gap_rows"; value = $gapRows.Count; notes = "" }) | Out-Null
foreach ($group in @($objectRows | Group-Object object_type | Sort-Object Count -Descending)) {
    $summaryRows.Add([pscustomobject]@{ metric = "objects:$($group.Name)"; value = $group.Count; notes = "" }) | Out-Null
}
foreach ($group in @($gapRows | Group-Object step | Sort-Object Count -Descending)) {
    $summaryRows.Add([pscustomobject]@{ metric = "gaps:$($group.Name)"; value = $group.Count; notes = "" }) | Out-Null
}
Export-Rows -Rows @($summaryRows) -Columns @("metric", "value", "notes") -Path $summaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$doc = @(
    "# SQL Server Deep Catalog",
    "",
    "Generated at: $capturedAt",
    "",
    "## Purpose",
    "",
    "Read-only inventory of SQL Server databases, objects, columns, and SQL expression dependencies visible through the approved metadata login.",
    "",
    "## Current Summary",
    "",
    "- Servers requested: $($servers.Count).",
    "- Databases visible: $($databaseRows.Count).",
    "- Objects captured: $($objectRows.Count).",
    "- Columns captured: $($columnRows.Count).",
    "- Dependencies captured: $($dependencyRows.Count).",
    "- Gap rows: $($gapRows.Count).",
    "",
    "## Outputs",
    "",
    "- $databasePath",
    "- $objectPath",
    "- $columnPath",
    "- $dependencyPath",
    "- $gapPath",
    "- $summaryPath",
    "",
    "## Safety",
    "",
    "This script only performs read-only metadata queries. It does not create, update, delete, trigger, deploy, or modify SQL/Fabric objects. Module definitions are not exported; only length and SHA-256 hash are captured for change tracking."
) -join [Environment]::NewLine
Set-Content -Path $OutputDocPath -Value $doc -Encoding UTF8

Write-Host "SQL Server deep catalog extraction completed."
Write-Host "Databases: $($databaseRows.Count)"
Write-Host "Objects: $($objectRows.Count)"
Write-Host "Columns: $($columnRows.Count)"
Write-Host "Dependencies: $($dependencyRows.Count)"
Write-Host "Gaps: $($gapRows.Count)"
Write-Host "Summary: $summaryPath"
