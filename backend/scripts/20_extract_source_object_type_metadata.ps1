# Phase 20 - Source object type metadata extraction: for source objects
# whose exact type (table/view/stored_procedure) is still ambiguous,
# connects directly to the external SQL Server (credentials from the
# SQL_METADATA_* environment variables, see .env) and queries
# INFORMATION_SCHEMA/sys catalog views to resolve it with certainty. The
# only phase here that reaches outside Fabric into a non-Fabric data source.
# Writes: $OutputEvidencePath, $OutputGapsPath, $OutputSummaryPath, $OutputDocPath.
param(
    [string]$ViewCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_view_candidates.csv"),
    [string]$ItemObjectLineageCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/item_object_lineage_candidates.csv"),
    [string]$PipelineObjectLineageCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/pipeline_object_lineage_candidates.csv"),
    [string]$OutputEvidencePath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_metadata_evidence.csv"),
    [string]$OutputGapsPath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_metadata_gaps.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_metadata_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/17_source_object_type_metadata.md"),
    [string]$UnresolvedPath = (Join-Path $PSScriptRoot "../../index/unresolved.md"),
    [string]$AzCommand = "az",
    [string]$SourceServerFilter = "",
    [string]$SourceDatabaseFilter = "",
    [int]$MaxTargets = 0,
    [int]$ConnectTimeoutSeconds = 12,
    [int]$CommandTimeoutSeconds = 60,
    [switch]$TrustServerCertificate,
    [string]$WorkspaceNameFilter = "",
    [string]$AdminSettingsPath = (Join-Path $PSScriptRoot "../../config/admin_settings.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$script:AmbiguousTypes = @("table_or_view", "native_query_object")

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

function Normalize-ObjectType {
    param([string]$Value)
    $clean = (Normalize-Key $Value) -replace "[\s-]+", "_"
    switch ($clean) {
        "storedprocedure" { return "stored_procedure" }
        "procedure" { return "stored_procedure" }
        "proc" { return "stored_procedure" }
        "sp" { return "stored_procedure" }
        "tbl" { return "table" }
        default { return $clean }
    }
}

function Test-CandidateObjectName {
    param([string]$ObjectName)
    if (-not $ObjectName) { return $false }
    $clean = $ObjectName.Trim()
    if ($clean.Length -gt 256) { return $false }
    if ($clean -match "^(https?|abfss|s3|wasbs?)://") { return $false }
    if ($clean -match "[{}]") { return $false }
    if ($clean -match "^[,.;:]+$") { return $false }
    return $true
}

function New-CandidateKey {
    param(
        [string]$SourceType,
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$SchemaName,
        [string]$ObjectName,
        [string]$RawObjectType
    )

    return "$(Normalize-Key $SourceType)|$(Normalize-Key $SourceServer)|$(Normalize-Key $SourceDatabase)|$(Normalize-Key $SchemaName)|$(Normalize-Key $ObjectName)|$(Normalize-Key $RawObjectType)"
}

function New-TargetKey {
    param([string]$SourceServer, [string]$SourceDatabase)
    return "$(Normalize-Key $SourceServer)|$(Normalize-Key $SourceDatabase)"
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

function Get-AdminExternalSourceAuth {
    param([string]$SourceServer)

    # config/admin_settings.json's external_sources list (managed from the
    # admin panel's "Orígenes externos" tab) is checked first -- it supports
    # any number of named non-Fabric connections, each with its own
    # password_ref environment variable, unlike the single legacy env-var
    # slot below. Falls through to that legacy mechanism untouched if the
    # settings file doesn't exist or has no matching entry, so nothing that
    # relied on the old env vars breaks.
    if (-not (Test-Path $AdminSettingsPath)) { return $null }
    try {
        $settings = Get-Content -Path $AdminSettingsPath -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
    $sources = @($settings.external_sources)
    if ($sources.Count -eq 0) { return $null }

    $sourceHost = Normalize-ServerHost -Value $SourceServer
    $match = $sources | Where-Object { (Normalize-ServerHost -Value $_.host) -eq $sourceHost } | Select-Object -First 1
    if (-not $match -or $match.auth_mode -ne "sql_auth") { return $null }

    $password = if ($match.password_ref) { [System.Environment]::GetEnvironmentVariable($match.password_ref) } else { $null }
    if (-not $match.user -or -not $password) { return $null }

    $port = 1433
    if ($match.port) {
        $parsedPort = 0
        if ([int]::TryParse([string]$match.port, [ref]$parsedPort) -and $parsedPort -gt 0) { $port = $parsedPort }
    }

    return [pscustomobject]@{
        User = $match.user
        Password = $password
        Port = $port
    }
}

function Get-SqlMetadataPasswordAuth {
    param([string]$SourceServer)

    $adminAuth = Get-AdminExternalSourceAuth -SourceServer $SourceServer
    if ($null -ne $adminAuth) { return $adminAuth }

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

function Add-ListValue {
    param([System.Collections.Generic.List[string]]$List, [string]$Value)
    if ($Value) { $List.Add($Value) | Out-Null }
}

function Add-Candidate {
    param(
        [hashtable]$Map,
        [string]$WorkspaceName,
        [string]$ItemType,
        [string]$ItemQualifiedName,
        [string]$SourceType,
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$SchemaName,
        [string]$ObjectName,
        [string]$RawObjectType,
        [string]$Evidence
    )

    $rawType = Normalize-ObjectType $RawObjectType
    if ($rawType -notin $script:AmbiguousTypes) { return }
    if (-not (Test-CandidateObjectName $ObjectName)) { return }

    $key = New-CandidateKey -SourceType $SourceType -SourceServer $SourceServer -SourceDatabase $SourceDatabase -SchemaName $SchemaName -ObjectName $ObjectName -RawObjectType $rawType
    if (-not $Map.ContainsKey($key)) {
        $Map[$key] = [pscustomobject]@{
            source_type = $SourceType
            source_server = $SourceServer
            source_database = $SourceDatabase
            schema_name = $SchemaName
            object_name = $ObjectName
            raw_object_type = $rawType
            candidate_count = 0
            workspaces = [System.Collections.Generic.List[string]]::new()
            item_types = [System.Collections.Generic.List[string]]::new()
            items = [System.Collections.Generic.List[string]]::new()
            evidence_samples = [System.Collections.Generic.List[string]]::new()
        }
    }

    $candidate = $Map[$key]
    $candidate.candidate_count += 1
    Add-ListValue -List $candidate.workspaces -Value $WorkspaceName
    Add-ListValue -List $candidate.item_types -Value $ItemType
    Add-ListValue -List $candidate.items -Value $ItemQualifiedName
    Add-ListValue -List $candidate.evidence_samples -Value $Evidence
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

function Invoke-ObjectMetadataQuery {
    param(
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$AccessToken,
        [int]$ConnectTimeoutSeconds,
        [int]$CommandTimeoutSeconds,
        [bool]$TrustServerCertificate
    )

    $trustValue = if ($TrustServerCertificate) { "True" } else { "False" }
    $sqlAuth = Get-SqlMetadataPasswordAuth -SourceServer $SourceServer
    $port = if ($null -ne $sqlAuth) { $sqlAuth.Port } else { 1433 }
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder["Data Source"] = "tcp:$SourceServer,$port"
    $builder["Initial Catalog"] = $SourceDatabase
    $builder["Encrypt"] = $true
    $builder["TrustServerCertificate"] = $trustValue
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
    case
        when o.type in ('U', 'ET') then 'table'
        when o.type = 'V' then 'view'
        when o.type in ('P', 'PC', 'X', 'RF') then 'stored_procedure'
        else lower(o.type_desc)
    end as object_type,
    o.type as type_code,
    o.type_desc as type_desc
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

$candidateMap = @{}

if (Test-Path $ViewCandidatesPath) {
    foreach ($row in @(Import-Csv -Path $ViewCandidatesPath | Where-Object { $_.object_name })) {
        Add-Candidate `
            -Map $candidateMap `
            -WorkspaceName (Get-FieldValue -Object $row -Names @("workspace_name")) `
            -ItemType "SemanticModel" `
            -ItemQualifiedName (Get-FieldValue -Object $row -Names @("semantic_model_qualified_name", "item_qualified_name")) `
            -SourceType "SQL" `
            -SourceServer (Get-FieldValue -Object $row -Names @("source_server")) `
            -SourceDatabase (Get-FieldValue -Object $row -Names @("database_name", "source_database")) `
            -SchemaName (Get-FieldValue -Object $row -Names @("schema_name")) `
            -ObjectName (Get-FieldValue -Object $row -Names @("object_name")) `
            -RawObjectType (Get-FieldValue -Object $row -Names @("object_type")) `
            -Evidence (Get-FieldValue -Object $row -Names @("evidence"))
    }
}

foreach ($path in @($ItemObjectLineageCandidatesPath, $PipelineObjectLineageCandidatesPath)) {
    if (-not (Test-Path $path)) { continue }
    foreach ($row in @(Import-Csv -Path $path | Where-Object { $_.object_name })) {
        Add-Candidate `
            -Map $candidateMap `
            -WorkspaceName (Get-FieldValue -Object $row -Names @("workspace_name")) `
            -ItemType (Get-FieldValue -Object $row -Names @("item_type")) `
            -ItemQualifiedName (Get-FieldValue -Object $row -Names @("item_qualified_name", "qualified_name")) `
            -SourceType (Get-FieldValue -Object $row -Names @("source_type")) `
            -SourceServer (Get-FieldValue -Object $row -Names @("source_server")) `
            -SourceDatabase (Get-FieldValue -Object $row -Names @("source_database", "database_name")) `
            -SchemaName (Get-FieldValue -Object $row -Names @("schema_name")) `
            -ObjectName (Get-FieldValue -Object $row -Names @("object_name")) `
            -RawObjectType (Get-FieldValue -Object $row -Names @("object_type")) `
            -Evidence (Get-FieldValue -Object $row -Names @("evidence"))
    }
}

$candidates = @($candidateMap.Values)
$targetGroups = @(
    $candidates |
        Where-Object { $_.source_server -and $_.source_database } |
        Group-Object { New-TargetKey -SourceServer $_.source_server -SourceDatabase $_.source_database } |
        ForEach-Object {
            $first = $_.Group[0]
            [pscustomobject]@{
                target_key = $_.Name
                source_server = $first.source_server
                source_database = $first.source_database
                candidate_count = ($_.Group | Measure-Object -Property candidate_count -Sum).Sum
                unique_object_count = @($_.Group).Count
                candidates = @($_.Group)
            }
        } |
        Sort-Object @{ Expression = "candidate_count"; Descending = $true }, source_server, source_database
)

if ($SourceServerFilter) {
    $serverFilters = @(
        $SourceServerFilter -split "[;,]" |
            ForEach-Object { Normalize-ServerHost -Value $_ } |
            Where-Object { $_ }
    )
    $targetGroups = @($targetGroups | Where-Object { (Normalize-ServerHost -Value $_.source_server) -in $serverFilters })
}

if ($SourceDatabaseFilter) {
    $databaseFilters = @(
        $SourceDatabaseFilter -split "[;,]" |
            ForEach-Object { Normalize-Key -Value $_ } |
            Where-Object { $_ }
    )
    $targetGroups = @($targetGroups | Where-Object { (Normalize-Key -Value $_.source_database) -in $databaseFilters })
}

if ($MaxTargets -gt 0) {
    $targetGroups = @($targetGroups | Select-Object -First $MaxTargets)
}

# When a workspace filter is active, the local candidate map above still aggregates evidence
# from ALL workspaces (a source object can be shared by many workspaces, so candidate_count /
# impacted_item_count must stay correct). Only the network-querying loop below is scoped down
# to targets that at least one item in the filtered workspace(s) actually references; targets
# outside that scope keep their previously recorded evidence/gap rows untouched (see retention
# below, after the query loop).
$workspaceFilterSet = $null
if ($WorkspaceNameFilter) {
    $workspaceFilterSet = @{}
    foreach ($name in ($WorkspaceNameFilter -split "[;,]" | ForEach-Object { Normalize-Key $_ } | Where-Object { $_ })) {
        $workspaceFilterSet[$name] = $true
    }
    $targetGroups = @(
        $targetGroups | Where-Object {
            $groupWorkspaces = @($_.candidates | ForEach-Object { $_.workspaces.ToArray() } | ForEach-Object { Normalize-Key $_ })
            @($groupWorkspaces | Where-Object { $workspaceFilterSet.ContainsKey($_) }).Count -gt 0
        }
    )
}

$queriedTargetKeys = @{}
foreach ($target in $targetGroups) {
    $queriedTargetKeys[(New-TargetKey -SourceServer $target.source_server -SourceDatabase $target.source_database)] = $true
}

$evidenceRows = [System.Collections.Generic.List[object]]::new()
$gapRows = [System.Collections.Generic.List[object]]::new()
$targetStatusRows = [System.Collections.Generic.List[object]]::new()

foreach ($candidate in @($candidates | Where-Object { -not $_.source_server -or -not $_.source_database })) {
    $gapRows.Add([pscustomobject]@{
        source_type = $candidate.source_type
        source_server = $candidate.source_server
        source_database = $candidate.source_database
        schema_name = $candidate.schema_name
        object_name = $candidate.object_name
        raw_object_type = $candidate.raw_object_type
        gap_reason = "missing_metadata_target"
        error = "Source server or database is missing, so no SQL/Fabric metadata query can be built."
        candidate_count = $candidate.candidate_count
        impacted_item_count = @($candidate.items.ToArray() | Sort-Object -Unique).Count
        impacted_items_sample = (@($candidate.items.ToArray() | Sort-Object -Unique | Select-Object -First 12) -join "; ")
        next_step = "Resolve the source endpoint/database from Fabric item connections, code, owner evidence, or manual review."
    }) | Out-Null
}

$accessToken = ""
if ($targetGroups.Count -gt 0) {
    $accessToken = Get-DatabaseAccessToken -AzCommand $AzCommand
}

foreach ($target in $targetGroups) {
    Write-Host "Querying metadata: $($target.source_server) / $($target.source_database) ($($target.unique_object_count) objects)"
    $metadataRows = @()
    $targetStatus = "metadata_query_succeeded"
    $targetError = ""

    try {
        $metadataRows = @(Invoke-ObjectMetadataQuery `
            -SourceServer $target.source_server `
            -SourceDatabase $target.source_database `
            -AccessToken $accessToken `
            -ConnectTimeoutSeconds $ConnectTimeoutSeconds `
            -CommandTimeoutSeconds $CommandTimeoutSeconds `
            -TrustServerCertificate ([bool]$TrustServerCertificate))
    }
    catch {
        $targetStatus = "metadata_query_failed"
        $targetError = $_.Exception.Message
    }

    $targetStatusRows.Add([pscustomobject]@{
        source_server = $target.source_server
        source_database = $target.source_database
        status = $targetStatus
        object_count = $target.unique_object_count
        candidate_count = $target.candidate_count
        metadata_rows = @($metadataRows).Count
        error = $targetError
    }) | Out-Null

    if ($targetStatus -ne "metadata_query_succeeded") {
        foreach ($candidate in @($target.candidates)) {
            $gapRows.Add([pscustomobject]@{
                source_type = $candidate.source_type
                source_server = $candidate.source_server
                source_database = $candidate.source_database
                schema_name = $candidate.schema_name
                object_name = $candidate.object_name
                raw_object_type = $candidate.raw_object_type
                gap_reason = "metadata_query_failed"
                error = $targetError
                candidate_count = $candidate.candidate_count
                impacted_item_count = @($candidate.items.ToArray() | Sort-Object -Unique).Count
                impacted_items_sample = (@($candidate.items.ToArray() | Sort-Object -Unique | Select-Object -First 12) -join "; ")
                next_step = "Validate read-only metadata access for this SQL/Fabric endpoint or resolve the type through owner/manual evidence."
            }) | Out-Null
        }
        continue
    }

    $bySchemaAndName = @{}
    $byName = @{}
    foreach ($meta in $metadataRows) {
        $schemaKey = "$(Normalize-Key $meta.schema_name)|$(Normalize-Key $meta.object_name)"
        if (-not $bySchemaAndName.ContainsKey($schemaKey)) {
            $bySchemaAndName[$schemaKey] = [System.Collections.Generic.List[object]]::new()
        }
        $bySchemaAndName[$schemaKey].Add($meta) | Out-Null

        $nameKey = Normalize-Key $meta.object_name
        if (-not $byName.ContainsKey($nameKey)) {
            $byName[$nameKey] = [System.Collections.Generic.List[object]]::new()
        }
        $byName[$nameKey].Add($meta) | Out-Null
    }

    foreach ($candidate in @($target.candidates)) {
        $match = $null
        $gapReason = ""
        $gapError = ""
        $candidateSchema = Normalize-Key $candidate.schema_name
        $candidateName = Normalize-Key $candidate.object_name

        if ($candidateSchema) {
            $lookupKey = "$candidateSchema|$candidateName"
            if ($bySchemaAndName.ContainsKey($lookupKey)) {
                $matches = @($bySchemaAndName[$lookupKey].ToArray())
                $match = $matches[0]
            }
            elseif ($byName.ContainsKey($candidateName)) {
                $gapReason = "object_not_found_with_schema"
                $gapError = "Object name exists in metadata, but not under schema '$($candidate.schema_name)'."
            }
            else {
                $gapReason = "object_not_found"
                $gapError = "Object was not found in sys.objects for this target."
            }
        }
        elseif ($byName.ContainsKey($candidateName)) {
            $matches = @($byName[$candidateName].ToArray())
            $schemas = @($matches | Select-Object -ExpandProperty schema_name -Unique)
            if ($schemas.Count -eq 1) {
                $match = $matches[0]
            }
            else {
                $gapReason = "object_name_found_in_multiple_schemas"
                $gapError = "Object name was found in multiple schemas: $($schemas -join ', ')."
            }
        }
        else {
            $gapReason = "object_not_found"
            $gapError = "Object was not found in sys.objects for this target."
        }

        if ($match) {
            $metadataSchema = [string]$match.schema_name
            $schemaForResolver = if ($candidate.schema_name) { $candidate.schema_name } else { "" }
            $evidenceRows.Add([pscustomobject]@{
                source_type = $candidate.source_type
                source_server = $candidate.source_server
                source_database = $candidate.source_database
                schema_name = $schemaForResolver
                object_name = $candidate.object_name
                object_type = Normalize-ObjectType ([string]$match.object_type)
                confidence = "confirmed"
                evidence = "Read-only metadata query against $($candidate.source_server)/$($candidate.source_database) found $metadataSchema.$($match.object_name) as $($match.type_desc)."
                resolver = "sql_fabric_metadata"
                reviewed_at = (Get-Date).ToString("s")
                metadata_server = $target.source_server
                metadata_database = $target.source_database
                metadata_schema_name = $metadataSchema
                metadata_object_name = [string]$match.object_name
                metadata_type_code = [string]$match.type_code
                metadata_type_desc = [string]$match.type_desc
                raw_object_type = $candidate.raw_object_type
                candidate_count = $candidate.candidate_count
                impacted_item_count = @($candidate.items.ToArray() | Sort-Object -Unique).Count
                impacted_item_types = (@($candidate.item_types.ToArray() | Sort-Object -Unique) -join "; ")
                impacted_items_sample = (@($candidate.items.ToArray() | Sort-Object -Unique | Select-Object -First 12) -join "; ")
                notes = if ($candidate.schema_name) { "Exact schema/object metadata match." } else { "Object name uniquely matched metadata schema '$metadataSchema'." }
            }) | Out-Null
        }
        else {
            $gapRows.Add([pscustomobject]@{
                source_type = $candidate.source_type
                source_server = $candidate.source_server
                source_database = $candidate.source_database
                schema_name = $candidate.schema_name
                object_name = $candidate.object_name
                raw_object_type = $candidate.raw_object_type
                gap_reason = $gapReason
                error = $gapError
                candidate_count = $candidate.candidate_count
                impacted_item_count = @($candidate.items.ToArray() | Sort-Object -Unique).Count
                impacted_items_sample = (@($candidate.items.ToArray() | Sort-Object -Unique | Select-Object -First 12) -join "; ")
                next_step = "Confirm the exact source object name/schema from SQL/Fabric metadata, code, or owner review."
            }) | Out-Null
        }
    }
}

if ($workspaceFilterSet) {
    if (Test-Path $OutputEvidencePath) {
        foreach ($row in @(Import-Csv -Path $OutputEvidencePath | Where-Object { -not $queriedTargetKeys.ContainsKey((New-TargetKey -SourceServer $_.source_server -SourceDatabase $_.source_database)) })) {
            $evidenceRows.Add($row) | Out-Null
        }
    }
    if (Test-Path $OutputGapsPath) {
        foreach ($row in @(Import-Csv -Path $OutputGapsPath | Where-Object { $_.gap_reason -ne "missing_metadata_target" -and -not $queriedTargetKeys.ContainsKey((New-TargetKey -SourceServer $_.source_server -SourceDatabase $_.source_database)) })) {
            $gapRows.Add($row) | Out-Null
        }
    }
}

$evidenceColumns = @(
    "source_type", "source_server", "source_database", "schema_name", "object_name", "object_type",
    "confidence", "evidence", "resolver", "reviewed_at", "metadata_server", "metadata_database",
    "metadata_schema_name", "metadata_object_name", "metadata_type_code", "metadata_type_desc",
    "raw_object_type", "candidate_count", "impacted_item_count", "impacted_item_types",
    "impacted_items_sample", "notes"
)
$gapColumns = @(
    "source_type", "source_server", "source_database", "schema_name", "object_name", "raw_object_type",
    "gap_reason", "error", "candidate_count", "impacted_item_count", "impacted_items_sample", "next_step"
)

$evidenceRows = @($evidenceRows | Sort-Object source_server, source_database, schema_name, object_name, source_type -Unique)
$gapRows = @($gapRows | Sort-Object gap_reason, source_server, source_database, schema_name, object_name, source_type -Unique)

Export-Rows -Rows $evidenceRows -Columns $evidenceColumns -Path $OutputEvidencePath
Export-Rows -Rows $gapRows -Columns $gapColumns -Path $OutputGapsPath

$summaryRows = [System.Collections.Generic.List[object]]::new()
$summaryRows.Add([pscustomobject]@{ metric = "ambiguous_unique_candidates"; value = $candidates.Count; notes = "Grouped ambiguous table_or_view/native_query_object source objects from semantic models, notebooks, CopyJobs, and DataPipelines." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "metadata_targets_attempted"; value = $targetGroups.Count; notes = "Unique source_server/source_database targets queried through read-only SQL metadata." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "metadata_targets_succeeded"; value = @($targetStatusRows | Where-Object { $_.status -eq "metadata_query_succeeded" }).Count; notes = "" }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "metadata_targets_failed"; value = @($targetStatusRows | Where-Object { $_.status -ne "metadata_query_succeeded" }).Count; notes = "" }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "metadata_evidence_rows"; value = $evidenceRows.Count; notes = "Rows usable as exact object-type resolver evidence." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "metadata_gap_rows"; value = $gapRows.Count; notes = "Rows still requiring metadata access, schema/name correction, or owner/manual review." }) | Out-Null
foreach ($group in @($gapRows | Group-Object gap_reason | Sort-Object Count -Descending)) {
    $summaryRows.Add([pscustomobject]@{ metric = "gap:$($group.Name)"; value = $group.Count; notes = "" }) | Out-Null
}
foreach ($group in @($evidenceRows | Group-Object object_type | Sort-Object Count -Descending)) {
    $summaryRows.Add([pscustomobject]@{ metric = "resolved:$($group.Name)"; value = $group.Count; notes = "" }) | Out-Null
}
Export-Rows -Rows $summaryRows -Columns @("metric", "value", "notes") -Path $OutputSummaryPath

$docLines = [System.Collections.Generic.List[string]]::new()
$docLines.Add("# Source Object Type Metadata Extraction") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Generated at: $(Get-Date -Format s)") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Purpose") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add('Resolve ambiguous `table_or_view` and `native_query_object` rows to exact `table`, `view`, or `stored_procedure` using read-only SQL/Fabric metadata queries against `sys.objects`.') | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Current Summary") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- Ambiguous unique candidates considered: $($candidates.Count).") | Out-Null
$docLines.Add("- Metadata targets attempted: $($targetGroups.Count).") | Out-Null
$docLines.Add("- Metadata targets succeeded: $(@($targetStatusRows | Where-Object { $_.status -eq 'metadata_query_succeeded' }).Count).") | Out-Null
$docLines.Add("- Metadata targets failed: $(@($targetStatusRows | Where-Object { $_.status -ne 'metadata_query_succeeded' }).Count).") | Out-Null
$docLines.Add("- Metadata evidence rows: $($evidenceRows.Count).") | Out-Null
$docLines.Add("- Metadata gap rows: $($gapRows.Count).") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Outputs") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- ``$OutputEvidencePath``") | Out-Null
$docLines.Add("- ``$OutputGapsPath``") | Out-Null
$docLines.Add("- ``$OutputSummaryPath``") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Safety") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add('This extractor only performs read-only metadata queries. It does not create, update, delete, trigger, or deploy Fabric or SQL objects. Manual overrides remain separate in `index/source_object_type_overrides.csv`.') | Out-Null
Ensure-ParentDirectory -Path $OutputDocPath
$docLines | Set-Content -Path $OutputDocPath -Encoding UTF8

Update-UnresolvedSection `
    -Path $UnresolvedPath `
    -Key "source-object-type-metadata-extraction-gaps" `
    -Title "Source object type metadata extraction gaps" `
    -Status "partial" `
    -Evidence "Read-only metadata extraction considered $($candidates.Count) ambiguous unique source objects, attempted $($targetGroups.Count) SQL/Fabric metadata targets, resolved $($evidenceRows.Count) exact object-type rows, and left $($gapRows.Count) gap rows." `
    -NextStep "Review $OutputGapsPath for missing endpoints, failed metadata access, and schema/name mismatches; use SQL/Fabric metadata access or owner evidence for unresolved rows."

Write-Host "Source object type metadata extraction completed."
if ($workspaceFilterSet) {
    Write-Host "Workspace filter: $WorkspaceNameFilter (only targets referenced by this workspace were (re)queried; other targets retained unchanged from $OutputEvidencePath / $OutputGapsPath)"
}
Write-Host "Ambiguous candidates: $($candidates.Count)"
Write-Host "Targets attempted: $($targetGroups.Count)"
Write-Host "Evidence rows: $($evidenceRows.Count)"
Write-Host "Gap rows: $($gapRows.Count)"
Write-Host "Evidence: $OutputEvidencePath"
