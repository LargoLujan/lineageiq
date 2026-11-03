# Phase 8 - Semantic lineage build: derives the semantic-model <->
# datamart/source dependency view (which models read which
# tables/views/datamarts, and which reports depend on which models) by
# combining item/dependency data with view-candidate evidence from
# enrichment/extraction phases. Purely local -- no API calls.
# Writes: $OutputDependencyPath/$OutputReportPath/$OutputDatamartSummaryPath/
# $OutputModelSummaryPath, a JSON for the web explorer, a doc, and a diagram.
param(
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$DependenciesPath = (Join-Path $PSScriptRoot "../../index/dependencies.csv"),
    [string]$ExecutionsPath = (Join-Path $PSScriptRoot "../../index/executions.csv"),
    [string]$ViewCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_view_candidates.csv"),
    [string]$ManualObjectEvidencePath = (Join-Path $PSScriptRoot "../../index/manual_lineage_object_evidence.csv"),
    [string]$ObjectTypeOverridesPath = (Join-Path $PSScriptRoot "../../index/source_object_type_overrides.csv"),
    [string]$ObjectTypeMetadataEvidencePath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_metadata_evidence.csv"),
    [string]$SharePointObjectTypeEvidencePath = "",
    [string]$MigrationMapPath = (Join-Path $PSScriptRoot "../../config/source_migration_map.csv"),
    [string]$OutputDependencyPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_datamart_dependencies.csv"),
    [string]$OutputReportPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_report_dependencies.csv"),
    [string]$OutputDatamartSummaryPath = (Join-Path $PSScriptRoot "../../analysis/semantic_datamart_summary.csv"),
    [string]$OutputModelSummaryPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_lineage_summary.csv"),
    [string]$OutputJsonPath = (Join-Path $PSScriptRoot "../../frontend/semantic-lineage/data/semantic-lineage.json"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/10_semantic_model_datamart_lineage.md"),
    [string]$OutputMermaidPath = (Join-Path $PSScriptRoot "../../diagrams/semantic_model_datamart_tree.mmd"),
    [string]$UnresolvedPath = (Join-Path $PSScriptRoot "../../index/unresolved.md"),
    [int]$MaxMermaidDatamarts = 14,
    [int]$MaxMermaidModelsPerDatamart = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

function Get-FieldValue {
    param(
        [object]$Object,
        [string[]]$Names
    )

    if ($null -eq $Object) {
        return ""
    }

    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            $value = $Object.$name
            if ($null -ne $value) {
                return [string]$value
            }
        }
    }

    return ""
}

function Limit-Text {
    param(
        [string]$Text,
        [int]$MaxLength = 500
    )

    if (-not $Text) {
        return ""
    }

    $clean = ($Text -replace "\s+", " ").Trim()
    if ($clean.Length -le $MaxLength) {
        return $clean
    }

    return $clean.Substring(0, $MaxLength - 3) + "..."
}

function Normalize-Key {
    param([string]$Value)

    if (-not $Value) {
        return ""
    }

    return ($Value.ToLowerInvariant() -replace "\s+", " ").Trim()
}

$script:ExactObjectTypes = @("table", "view", "stored_procedure", "file", "shortcut", "query")
$script:ObjectTypeOverrideMap = @{}
$script:ManualObjectTypeMap = @{}
$script:MetadataObjectTypeMap = @{}
$script:SharePointObjectTypeMap = @{}

function Normalize-ObjectType {
    param([string]$Value)

    $clean = (Normalize-Key $Value) -replace "[\s-]+", "_"
    switch ($clean) {
        "storedprocedure" { return "stored_procedure" }
        "stored_procedure" { return "stored_procedure" }
        "procedure" { return "stored_procedure" }
        "proc" { return "stored_procedure" }
        "sp" { return "stored_procedure" }
        "tbl" { return "table" }
        default { return $clean }
    }
}

function Test-ExactObjectType {
    param([string]$Value)
    return ((Normalize-ObjectType $Value) -in $script:ExactObjectTypes)
}

function New-ObjectTypeKey {
    param(
        [string]$SourceType,
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$SchemaName,
        [string]$ObjectName
    )

    $typePart = if ($SourceType) { Normalize-Key $SourceType } else { "*" }
    return "$typePart|$(Normalize-Key $SourceServer)|$(Normalize-Key $SourceDatabase)|$(Normalize-Key $SchemaName)|$(Normalize-Key $ObjectName)"
}

function Add-ObjectTypeResolver {
    param(
        [hashtable]$Map,
        [string]$Source,
        [object]$Row,
        [string]$ObjectType
    )

    $sourceType = Get-FieldValue -Object $Row -Names @("source_type", "source_system")
    $sourceServer = Get-FieldValue -Object $Row -Names @("source_server", "server")
    $sourceDatabase = Get-FieldValue -Object $Row -Names @("source_database", "database_name", "database")
    $schemaName = Get-FieldValue -Object $Row -Names @("schema_name", "source_schema")
    $objectName = Get-FieldValue -Object $Row -Names @("object_name", "source_object")
    $normalizedType = Normalize-ObjectType $ObjectType

    if (-not ($sourceServer -or $sourceDatabase -or $objectName) -or -not (Test-ExactObjectType $normalizedType)) {
        return
    }

    $key = New-ObjectTypeKey -SourceType $sourceType -SourceServer $sourceServer -SourceDatabase $sourceDatabase -SchemaName $schemaName -ObjectName $objectName
    if ($Map.ContainsKey($key) -and $Map[$key].object_type -ne $normalizedType) {
        $Map[$key] = [pscustomobject]@{
            object_type = "unknown"
            source = "${Source}_conflict"
            confidence = "unknown"
            evidence = "Conflicting object type evidence for this source object."
        }
        return
    }

    $Map[$key] = [pscustomobject]@{
        object_type = $normalizedType
        source = $Source
        confidence = Get-FieldValue -Object $Row -Names @("confidence")
        evidence = Get-FieldValue -Object $Row -Names @("evidence")
    }
}

function Resolve-SourceObjectType {
    param(
        [string]$SourceType,
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$SchemaName,
        [string]$ObjectName,
        [string]$RawObjectType
    )

    $keys = @(
        (New-ObjectTypeKey -SourceType $SourceType -SourceServer $SourceServer -SourceDatabase $SourceDatabase -SchemaName $SchemaName -ObjectName $ObjectName),
        (New-ObjectTypeKey -SourceType "" -SourceServer $SourceServer -SourceDatabase $SourceDatabase -SchemaName $SchemaName -ObjectName $ObjectName)
    ) | Select-Object -Unique

    foreach ($key in $keys) {
        if ($script:ObjectTypeOverrideMap.ContainsKey($key) -and (Test-ExactObjectType $script:ObjectTypeOverrideMap[$key].object_type)) {
            return $script:ObjectTypeOverrideMap[$key]
        }
    }

    foreach ($key in $keys) {
        if ($script:ManualObjectTypeMap.ContainsKey($key) -and (Test-ExactObjectType $script:ManualObjectTypeMap[$key].object_type)) {
            return $script:ManualObjectTypeMap[$key]
        }
    }

    foreach ($key in $keys) {
        if ($script:MetadataObjectTypeMap.ContainsKey($key) -and (Test-ExactObjectType $script:MetadataObjectTypeMap[$key].object_type)) {
            return $script:MetadataObjectTypeMap[$key]
        }
    }

    foreach ($key in $keys) {
        if ($script:SharePointObjectTypeMap.ContainsKey($key) -and (Test-ExactObjectType $script:SharePointObjectTypeMap[$key].object_type)) {
            return $script:SharePointObjectTypeMap[$key]
        }
    }

    $normalizedRaw = Normalize-ObjectType $RawObjectType
    return [pscustomobject]@{
        object_type = $normalizedRaw
        source = if ($normalizedRaw -eq "table_or_view") { "tmdl_lookup_pending" } elseif ($normalizedRaw -eq "native_query_object") { "native_query_pending" } else { "automatic_candidate" }
        confidence = if ($normalizedRaw -eq "table_or_view") { "confirmed" } elseif ($normalizedRaw -eq "native_query_object") { "likely" } else { "" }
        evidence = if ($normalizedRaw -eq "table_or_view") {
            "TMDL Schema/Item confirms the object name but not whether the SQL object is a table or view."
        } elseif ($normalizedRaw -eq "native_query_object") {
            "Native query parsing found an object reference, but the exact SQL object type requires metadata review."
        } else {
            ""
        }
    }
}

function Get-ExternalConnectionParts {
    param([string]$QualifiedName)

    $parts = $QualifiedName -split " / ", 3
    $sourceType = if ($parts.Count -ge 2) { $parts[1] } else { "Unknown" }
    $connectionText = if ($parts.Count -ge 3) { $parts[2] } else { $QualifiedName }
    $server = ""
    $datamart = ""
    $viewOrObject = ""

    if ($connectionText.Contains(";")) {
        $connectionParts = $connectionText -split ";"
        $server = $connectionParts[0]
        if ($connectionParts.Count -ge 2) {
            $datamart = $connectionParts[1]
        }
        if ($connectionParts.Count -ge 3) {
            $viewOrObject = ($connectionParts[2..($connectionParts.Count - 1)] -join ";")
        }
    }
    elseif ($sourceType -eq "SharePoint") {
        $server = $connectionText
        $datamart = "SharePoint"
    }
    else {
        $datamart = $connectionText
    }

    return [pscustomobject]@{
        source_type = $sourceType
        source_server = $server
        datamart_name = $datamart
        view_or_object = $viewOrObject
        connection_label = $connectionText
    }
}

function New-JsonNode {
    param(
        [string]$Id,
        [string]$Label,
        [string]$Type,
        [hashtable]$Properties
    )

    return [pscustomobject]@{
        id = $Id
        label = $Label
        type = $Type
        properties = $Properties
    }
}

function New-JsonEdge {
    param(
        [string]$Source,
        [string]$Target,
        [string]$Type,
        [string]$Confidence,
        [string]$Evidence
    )

    return [pscustomobject]@{
        source = $Source
        target = $Target
        type = $Type
        confidence = $Confidence
        evidence = $Evidence
    }
}

function Add-JsonEdgeUnique {
    param(
        [System.Collections.Generic.List[object]]$Edges,
        [hashtable]$Seen,
        [string]$Source,
        [string]$Target,
        [string]$Type,
        [string]$Confidence,
        [string]$Evidence
    )

    $key = "$Source|$Target|$Type|$Confidence"
    if ($Seen.ContainsKey($key)) {
        return
    }

    $Seen[$key] = $true
    $Edges.Add((New-JsonEdge -Source $Source -Target $Target -Type $Type -Confidence $Confidence -Evidence $Evidence)) | Out-Null
}

function Sanitize-MermaidId {
    param([string]$Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [System.Security.Cryptography.SHA1]::Create().ComputeHash($bytes)
    return "n$([System.BitConverter]::ToString($hash).Replace('-', '').Substring(0, 10).ToLowerInvariant())"
}

function Escape-MermaidLabel {
    param([string]$Value)

    return (Limit-Text -Text ($Value.Replace('"', "'")) -MaxLength 70)
}

function Set-UnresolvedEntry {
    param(
        [string]$Title,
        [string]$Status,
        [string]$Evidence,
        [string]$NextStep
    )

    Ensure-ParentDirectory -Path $UnresolvedPath
    if (-not (Test-Path $UnresolvedPath)) {
        "# Unresolved Items`n`n## Open Questions`n" | Set-Content -Path $UnresolvedPath -Encoding UTF8
    }

    $today = Get-Date -Format "yyyy-MM-dd"
    $markerName = (($Title.ToLowerInvariant() -replace "[^a-z0-9]+", "-").Trim("-"))
    $startMarker = "<!-- unresolved:${markerName}:start -->"
    $endMarker = "<!-- unresolved:${markerName}:end -->"
    $entry = @"

$startMarker

## $today - $Title

- Status: $Status
- Evidence: $Evidence
- Next step: $NextStep

$endMarker
"@

    $current = Get-Content -Path $UnresolvedPath -Raw
    $pattern = "(?s)$([regex]::Escape($startMarker)).*?$([regex]::Escape($endMarker))"

    if ($current -match $pattern) {
        Set-Content -Path $UnresolvedPath -Value ([regex]::Replace($current, $pattern, $entry)) -Encoding UTF8
    }
    else {
        Add-Content -Path $UnresolvedPath -Value $entry -Encoding UTF8
    }
}

foreach ($path in @($ItemsPath, $DependenciesPath, $ExecutionsPath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$items = @(Import-Csv -Path $ItemsPath | Where-Object { $_.status -eq "discovered" })
$dependencies = @(Import-Csv -Path $DependenciesPath)
$executions = @(Import-Csv -Path $ExecutionsPath)
$viewCandidates = @()
if (Test-Path $ViewCandidatesPath) {
    $viewCandidates = @(Import-Csv -Path $ViewCandidatesPath | Where-Object { $_.object_name })
}
$manualObjectEvidenceRows = @()
if (Test-Path $ManualObjectEvidencePath) {
    $manualObjectEvidenceRows = @(Import-Csv -Path $ManualObjectEvidencePath | Where-Object { $_.object_name -and $_.object_type })
}
$objectTypeOverrideRows = @()
if (Test-Path $ObjectTypeOverridesPath) {
    $objectTypeOverrideRows = @(Import-Csv -Path $ObjectTypeOverridesPath | Where-Object { $_.object_name -and $_.object_type })
}
$objectTypeMetadataEvidenceRows = @()
if (Test-Path $ObjectTypeMetadataEvidencePath) {
    $objectTypeMetadataEvidenceRows = @(Import-Csv -Path $ObjectTypeMetadataEvidencePath | Where-Object { $_.object_name -and $_.object_type })
}
$sharePointObjectTypeRows = @()
if ($SharePointObjectTypeEvidencePath -and (Test-Path $SharePointObjectTypeEvidencePath)) {
    $sharePointObjectTypeRows = @(Import-Csv -Path $SharePointObjectTypeEvidencePath | Where-Object { $_.object_name -and $_.object_type })
}
foreach ($row in $objectTypeOverrideRows) {
    Add-ObjectTypeResolver -Map $script:ObjectTypeOverrideMap -Source "override" -Row $row -ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
}
foreach ($row in $manualObjectEvidenceRows) {
    Add-ObjectTypeResolver -Map $script:ManualObjectTypeMap -Source "manual_review" -Row $row -ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
}
foreach ($row in $objectTypeMetadataEvidenceRows) {
    Add-ObjectTypeResolver -Map $script:MetadataObjectTypeMap -Source "metadata_readonly" -Row $row -ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
}
foreach ($row in $sharePointObjectTypeRows) {
    Add-ObjectTypeResolver -Map $script:SharePointObjectTypeMap -Source "sharepoint_catalog" -Row $row -ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
}
$migrationMapRows = @()
if (Test-Path $MigrationMapPath) {
    $migrationMapRows = @(Import-Csv -Path $MigrationMapPath | Where-Object { $_.source_server -or $_.source_database -or $_.fabric_item_name })
}
$semanticModels = @($items | Where-Object { $_.item_type -eq "SemanticModel" })

$modelByName = @{}
foreach ($model in $semanticModels) {
    $modelByName[$model.qualified_name] = $model
}

$reportsByModel = @{}
$modelSourceRows = [System.Collections.Generic.List[object]]::new()
$modelReportRows = [System.Collections.Generic.List[object]]::new()

$scheduleByModel = @{}
foreach ($schedule in ($executions | Where-Object { $_.record_type -eq "schedule" -and $_.item_type -eq "SemanticModel" })) {
    $modelName = Get-FieldValue -Object $schedule -Names @("qualified_name")
    if (-not $scheduleByModel.ContainsKey($modelName)) {
        $scheduleByModel[$modelName] = [pscustomobject]@{ enabled = 0; disabled = 0; times = [System.Collections.Generic.List[string]]::new() }
    }
    if ((Get-FieldValue -Object $schedule -Names @("schedule_enabled")) -eq "True") {
        $scheduleByModel[$modelName].enabled += 1
    }
    else {
        $scheduleByModel[$modelName].disabled += 1
    }
    $time = Get-FieldValue -Object $schedule -Names @("scheduled_time")
    if ($time -and -not $scheduleByModel[$modelName].times.Contains($time)) {
        $scheduleByModel[$modelName].times.Add($time) | Out-Null
    }
}

$refreshByModel = @{}
foreach ($job in ($executions | Where-Object { $_.record_type -eq "job_instance" -and $_.item_type -eq "SemanticModel" })) {
    $modelName = Get-FieldValue -Object $job -Names @("qualified_name")
    if (-not $refreshByModel.ContainsKey($modelName)) {
        $refreshByModel[$modelName] = [pscustomobject]@{ runs = 0; failed = 0; completed = 0; latest = ""; latest_status = "" }
    }
    $refreshByModel[$modelName].runs += 1
    $status = Get-FieldValue -Object $job -Names @("status")
    if ($status -eq "Failed") { $refreshByModel[$modelName].failed += 1 }
    if ($status -eq "Completed") { $refreshByModel[$modelName].completed += 1 }
    $startTime = Get-FieldValue -Object $job -Names @("start_time")
    if ($startTime -and ($refreshByModel[$modelName].latest -eq "" -or $startTime -gt $refreshByModel[$modelName].latest)) {
        $refreshByModel[$modelName].latest = $startTime
        $refreshByModel[$modelName].latest_status = $status
    }
}

foreach ($dep in $dependencies) {
    $from = Get-FieldValue -Object $dep -Names @("from_qualified_name")
    $to = Get-FieldValue -Object $dep -Names @("to_qualified_name")
    $relationship = Get-FieldValue -Object $dep -Names @("relationship_type")
    $confidence = Get-FieldValue -Object $dep -Names @("confidence")
    $evidence = Get-FieldValue -Object $dep -Names @("evidence")

    if ($relationship -eq "depends_on" -and $modelByName.ContainsKey($from) -and $to.StartsWith("External Connection /")) {
        $model = $modelByName[$from]
        $parts = Get-ExternalConnectionParts -QualifiedName $to
        $modelSourceRows.Add([pscustomobject]@{
            workspace_name = $model.workspace_name
            workspace_environment = $model.workspace_environment
            semantic_model_name = $model.item_name
            semantic_model_qualified_name = $from
            source_type = $parts.source_type
            source_server = $parts.source_server
            datamart_name = $parts.datamart_name
            view_or_object = $parts.view_or_object
            source_qualified_name = $to
            confidence = $confidence
            evidence = $evidence
            connection_label = $parts.connection_label
            refresh_runs = if ($refreshByModel.ContainsKey($from)) { $refreshByModel[$from].runs } else { 0 }
            refresh_failed = if ($refreshByModel.ContainsKey($from)) { $refreshByModel[$from].failed } else { 0 }
            refresh_latest_status = if ($refreshByModel.ContainsKey($from)) { $refreshByModel[$from].latest_status } else { "" }
            enabled_schedules = if ($scheduleByModel.ContainsKey($from)) { $scheduleByModel[$from].enabled } else { 0 }
            disabled_schedules = if ($scheduleByModel.ContainsKey($from)) { $scheduleByModel[$from].disabled } else { 0 }
        }) | Out-Null
    }

    if ($relationship -eq "serves_report" -and $modelByName.ContainsKey($from)) {
        $model = $modelByName[$from]
        $modelReportRows.Add([pscustomobject]@{
            workspace_name = $model.workspace_name
            workspace_environment = $model.workspace_environment
            semantic_model_name = $model.item_name
            semantic_model_qualified_name = $from
            report_qualified_name = $to
            report_name = ($to -split " / " | Select-Object -Last 1)
            confidence = $confidence
            evidence = $evidence
        }) | Out-Null
    }
}

$sourceCountsByModel = @{}
foreach ($row in $modelSourceRows) {
    if (-not $sourceCountsByModel.ContainsKey($row.semantic_model_qualified_name)) {
        $sourceCountsByModel[$row.semantic_model_qualified_name] = 0
    }
    $sourceCountsByModel[$row.semantic_model_qualified_name] += 1
}

$reportCountsByModel = @{}
foreach ($row in $modelReportRows) {
    if (-not $reportCountsByModel.ContainsKey($row.semantic_model_qualified_name)) {
        $reportCountsByModel[$row.semantic_model_qualified_name] = 0
    }
    $reportCountsByModel[$row.semantic_model_qualified_name] += 1
}

$modelSummaryRows = @(
    $semanticModels |
        ForEach-Object {
            $modelName = $_.qualified_name
            [pscustomobject]@{
                workspace_name = $_.workspace_name
                workspace_environment = $_.workspace_environment
                semantic_model_name = $_.item_name
                semantic_model_qualified_name = $modelName
                source_count = if ($sourceCountsByModel.ContainsKey($modelName)) { $sourceCountsByModel[$modelName] } else { 0 }
                report_count = if ($reportCountsByModel.ContainsKey($modelName)) { $reportCountsByModel[$modelName] } else { 0 }
                refresh_runs = if ($refreshByModel.ContainsKey($modelName)) { $refreshByModel[$modelName].runs } else { 0 }
                refresh_failed = if ($refreshByModel.ContainsKey($modelName)) { $refreshByModel[$modelName].failed } else { 0 }
                refresh_completed = if ($refreshByModel.ContainsKey($modelName)) { $refreshByModel[$modelName].completed } else { 0 }
                latest_refresh = if ($refreshByModel.ContainsKey($modelName)) { $refreshByModel[$modelName].latest } else { "" }
                latest_refresh_status = if ($refreshByModel.ContainsKey($modelName)) { $refreshByModel[$modelName].latest_status } else { "" }
                enabled_schedules = if ($scheduleByModel.ContainsKey($modelName)) { $scheduleByModel[$modelName].enabled } else { 0 }
                disabled_schedules = if ($scheduleByModel.ContainsKey($modelName)) { $scheduleByModel[$modelName].disabled } else { 0 }
                lineage_status = if ($sourceCountsByModel.ContainsKey($modelName)) { "source_connection_confirmed" } else { "source_connection_missing" }
            }
        } |
        Sort-Object -Property source_count, report_count -Descending
)

$datamartSummaryRows = @(
    $modelSourceRows |
        Group-Object -Property source_type, source_server, datamart_name |
        ForEach-Object {
            $first = $_.Group[0]
            [pscustomobject]@{
                source_type = $first.source_type
                source_server = $first.source_server
                datamart_name = $first.datamart_name
                semantic_model_count = @($_.Group | Select-Object -ExpandProperty semantic_model_qualified_name -Unique).Count
                dependency_count = $_.Count
                workspaces = (@($_.Group | Select-Object -ExpandProperty workspace_name -Unique | Sort-Object) -join "; ")
                confidence = if (@($_.Group | Where-Object { $_.confidence -ne "confirmed" }).Count -eq 0) { "confirmed" } else { "mixed" }
            }
        } |
        Sort-Object -Property semantic_model_count, dependency_count -Descending
)

$sourceRowsByModel = @{}
foreach ($row in $modelSourceRows) {
    if (-not $sourceRowsByModel.ContainsKey($row.semantic_model_qualified_name)) {
        $sourceRowsByModel[$row.semantic_model_qualified_name] = [System.Collections.Generic.List[object]]::new()
    }
    $sourceRowsByModel[$row.semantic_model_qualified_name].Add($row) | Out-Null
}

$sourceObjectRows = [System.Collections.Generic.List[object]]::new()
$viewCandidatesWithoutSource = 0
foreach ($candidate in $viewCandidates) {
    $modelName = Get-FieldValue -Object $candidate -Names @("semantic_model_qualified_name")
    $objectName = Get-FieldValue -Object $candidate -Names @("object_name")
    if (-not $modelName -or -not $objectName -or -not $modelByName.ContainsKey($modelName)) {
        continue
    }

    $sourceType = "SQL"
    $sourceServer = Get-FieldValue -Object $candidate -Names @("source_server")
    $datamartName = Get-FieldValue -Object $candidate -Names @("database_name")
    if (-not ($sourceServer -and $datamartName)) {
        if ($sourceRowsByModel.ContainsKey($modelName) -and $sourceRowsByModel[$modelName].Count -eq 1) {
            $onlySource = $sourceRowsByModel[$modelName][0]
            $sourceType = $onlySource.source_type
            $sourceServer = $onlySource.source_server
            $datamartName = $onlySource.datamart_name
        }
        else {
            $viewCandidatesWithoutSource += 1
            continue
        }
    }

    $schemaName = Get-FieldValue -Object $candidate -Names @("schema_name")
    $rawObjectType = Get-FieldValue -Object $candidate -Names @("object_type")
    $typeResolution = Resolve-SourceObjectType -SourceType $sourceType -SourceServer $sourceServer -SourceDatabase $datamartName -SchemaName $schemaName -ObjectName $objectName -RawObjectType $rawObjectType
    $objectType = $typeResolution.object_type
    $objectId = "object:" + (Normalize-Key "$sourceType|$sourceServer|$datamartName|$schemaName|$objectName|$objectType")
    $sourceId = "source:" + (Normalize-Key "$sourceType|$sourceServer|$datamartName")
    $modelId = "model:" + (Normalize-Key $modelName)
    $candidateEvidence = Get-FieldValue -Object $candidate -Names @("evidence")
    $objectTypeEvidence = if ($typeResolution.evidence) { $typeResolution.evidence } else { "" }
    $sourceObjectRows.Add([pscustomobject]@{
        object_id = $objectId
        source_id = $sourceId
        model_id = $modelId
        source_type = $sourceType
        source_server = $sourceServer
        datamart_name = $datamartName
        schema_name = $schemaName
        object_name = $objectName
        object_type = $objectType
        raw_object_type = $rawObjectType
        object_type_source = $typeResolution.source
        object_type_confidence = $typeResolution.confidence
        object_type_evidence = $objectTypeEvidence
        semantic_table = Get-FieldValue -Object $candidate -Names @("semantic_table")
        semantic_model_qualified_name = $modelName
        semantic_model_name = Get-FieldValue -Object $candidate -Names @("semantic_model_name")
        workspace_name = Get-FieldValue -Object $candidate -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $candidate -Names @("workspace_environment")
        confidence = Get-FieldValue -Object $candidate -Names @("confidence")
        evidence = (@($candidateEvidence, $(if ($objectTypeEvidence) { "Object type: $objectTypeEvidence" } else { "" })) | Where-Object { $_ }) -join " "
        definition_path = Get-FieldValue -Object $candidate -Names @("definition_path")
    }) | Out-Null
}

Ensure-ParentDirectory -Path $OutputDependencyPath
$modelSourceRows | Export-Csv -Path $OutputDependencyPath -NoTypeInformation -Encoding UTF8

Ensure-ParentDirectory -Path $OutputReportPath
$modelReportRows | Export-Csv -Path $OutputReportPath -NoTypeInformation -Encoding UTF8

Ensure-ParentDirectory -Path $OutputDatamartSummaryPath
$datamartSummaryRows | Export-Csv -Path $OutputDatamartSummaryPath -NoTypeInformation -Encoding UTF8

Ensure-ParentDirectory -Path $OutputModelSummaryPath
$modelSummaryRows | Export-Csv -Path $OutputModelSummaryPath -NoTypeInformation -Encoding UTF8

$jsonNodes = [System.Collections.Generic.List[object]]::new()
$jsonEdges = [System.Collections.Generic.List[object]]::new()
$jsonNodeIds = @{}
$jsonEdgeIds = @{}

foreach ($row in $datamartSummaryRows) {
    $sourceId = "source:" + (Normalize-Key "$($row.source_type)|$($row.source_server)|$($row.datamart_name)")
    if (-not $jsonNodeIds.ContainsKey($sourceId)) {
        $sourceMappings = @(
            $migrationMapRows |
                Where-Object {
                    (Normalize-Key $_.source_server) -eq (Normalize-Key $row.source_server) -and
                    (Normalize-Key $_.source_database) -eq (Normalize-Key $row.datamart_name) -and
                    ((-not $_.source_system) -or (Normalize-Key $_.source_system) -eq (Normalize-Key $row.source_type))
                }
        )
        $fabricEquivalents = @(
            $sourceMappings |
                ForEach-Object {
                    (@($_.fabric_workspace, $_.fabric_item_type, $_.fabric_item_name, $_.fabric_object_name) | Where-Object { $_ }) -join " / "
                } |
                Where-Object { $_ } |
                Sort-Object -Unique
        )
        $jsonNodeIds[$sourceId] = $true
        $jsonNodes.Add((New-JsonNode -Id $sourceId -Label $row.datamart_name -Type "source" -Properties @{
            source_type = $row.source_type
            source_server = $row.source_server
            datamart_name = $row.datamart_name
            semantic_model_count = $row.semantic_model_count
            dependency_count = $row.dependency_count
            migration_mapping_count = $sourceMappings.Count
            migration_status = (@($sourceMappings | Select-Object -ExpandProperty mapping_status -Unique | Where-Object { $_ }) -join "; ")
            migration_confidence = (@($sourceMappings | Select-Object -ExpandProperty confidence -Unique | Where-Object { $_ }) -join "; ")
            fabric_equivalent = ($fabricEquivalents -join "; ")
        })) | Out-Null
    }
}

foreach ($row in ($sourceObjectRows | Group-Object -Property source_id | ForEach-Object { $_.Group[0] })) {
    if (-not $jsonNodeIds.ContainsKey($row.source_id)) {
        $sourceMappings = @(
            $migrationMapRows |
                Where-Object {
                    (Normalize-Key $_.source_server) -eq (Normalize-Key $row.source_server) -and
                    (Normalize-Key $_.source_database) -eq (Normalize-Key $row.datamart_name) -and
                    ((-not $_.source_system) -or (Normalize-Key $_.source_system) -eq (Normalize-Key $row.source_type))
                }
        )
        $fabricEquivalents = @(
            $sourceMappings |
                ForEach-Object {
                    (@($_.fabric_workspace, $_.fabric_item_type, $_.fabric_item_name, $_.fabric_object_name) | Where-Object { $_ }) -join " / "
                } |
                Where-Object { $_ } |
                Sort-Object -Unique
        )
        $jsonNodeIds[$row.source_id] = $true
        $jsonNodes.Add((New-JsonNode -Id $row.source_id -Label $row.datamart_name -Type "source" -Properties @{
            source_type = $row.source_type
            source_server = $row.source_server
            datamart_name = $row.datamart_name
            semantic_model_count = @($sourceObjectRows | Where-Object { $_.source_id -eq $row.source_id } | Select-Object -ExpandProperty semantic_model_qualified_name -Unique).Count
            dependency_count = @($sourceObjectRows | Where-Object { $_.source_id -eq $row.source_id }).Count
            migration_mapping_count = $sourceMappings.Count
            migration_status = (@($sourceMappings | Select-Object -ExpandProperty mapping_status -Unique | Where-Object { $_ }) -join "; ")
            migration_confidence = (@($sourceMappings | Select-Object -ExpandProperty confidence -Unique | Where-Object { $_ }) -join "; ")
            fabric_equivalent = ($fabricEquivalents -join "; ")
        })) | Out-Null
    }
}

foreach ($model in $modelSummaryRows) {
    $modelId = "model:" + (Normalize-Key $model.semantic_model_qualified_name)
    if (-not $jsonNodeIds.ContainsKey($modelId)) {
        $jsonNodeIds[$modelId] = $true
        $jsonNodes.Add((New-JsonNode -Id $modelId -Label $model.semantic_model_name -Type "semanticModel" -Properties @{
            workspace_name = $model.workspace_name
            environment = $model.workspace_environment
            qualified_name = $model.semantic_model_qualified_name
            source_count = $model.source_count
            report_count = $model.report_count
            refresh_failed = $model.refresh_failed
            latest_refresh_status = $model.latest_refresh_status
            enabled_schedules = $model.enabled_schedules
            disabled_schedules = $model.disabled_schedules
            lineage_status = $model.lineage_status
        })) | Out-Null
    }
}

foreach ($objectGroup in ($sourceObjectRows | Group-Object -Property object_id)) {
    $first = $objectGroup.Group[0]
    $objectLabel = if ($first.schema_name) { "$($first.schema_name).$($first.object_name)" } else { $first.object_name }
    if (-not $jsonNodeIds.ContainsKey($first.object_id)) {
        $jsonNodeIds[$first.object_id] = $true
        $jsonNodes.Add((New-JsonNode -Id $first.object_id -Label $objectLabel -Type "sourceObject" -Properties @{
            source_type = $first.source_type
            source_server = $first.source_server
            datamart_name = $first.datamart_name
            schema_name = $first.schema_name
            object_name = $first.object_name
            object_type = $first.object_type
            raw_object_type = $first.raw_object_type
            object_type_source = $first.object_type_source
            object_type_confidence = $first.object_type_confidence
            object_type_evidence = $first.object_type_evidence
            model_count = @($objectGroup.Group | Select-Object -ExpandProperty semantic_model_qualified_name -Unique).Count
            candidate_count = $objectGroup.Count
            confidence = if (@($objectGroup.Group | Where-Object { $_.confidence -ne "confirmed" }).Count -eq 0) { "confirmed" } else { "mixed" }
        })) | Out-Null
    }
}

foreach ($source in $modelSourceRows) {
    $sourceId = "source:" + (Normalize-Key "$($source.source_type)|$($source.source_server)|$($source.datamart_name)")
    $modelId = "model:" + (Normalize-Key $source.semantic_model_qualified_name)
    Add-JsonEdgeUnique -Edges $jsonEdges -Seen $jsonEdgeIds -Source $sourceId -Target $modelId -Type "feeds_model" -Confidence $source.confidence -Evidence $source.evidence
}

foreach ($sourceObject in $sourceObjectRows) {
    Add-JsonEdgeUnique -Edges $jsonEdges -Seen $jsonEdgeIds -Source $sourceObject.source_id -Target $sourceObject.object_id -Type "contains_object" -Confidence $sourceObject.confidence -Evidence $sourceObject.evidence
    Add-JsonEdgeUnique -Edges $jsonEdges -Seen $jsonEdgeIds -Source $sourceObject.object_id -Target $sourceObject.model_id -Type "feeds_model_via_object" -Confidence $sourceObject.confidence -Evidence "Semantic model table '$($sourceObject.semantic_table)' references source object from TMDL path '$($sourceObject.definition_path)'."
}

foreach ($report in $modelReportRows) {
    $reportId = "report:" + (Normalize-Key $report.report_qualified_name)
    if (-not $jsonNodeIds.ContainsKey($reportId)) {
        $jsonNodeIds[$reportId] = $true
        $jsonNodes.Add((New-JsonNode -Id $reportId -Label $report.report_name -Type "report" -Properties @{
            workspace_name = $report.workspace_name
            environment = $report.workspace_environment
            qualified_name = $report.report_qualified_name
        })) | Out-Null
    }
    $modelId = "model:" + (Normalize-Key $report.semantic_model_qualified_name)
    Add-JsonEdgeUnique -Edges $jsonEdges -Seen $jsonEdgeIds -Source $modelId -Target $reportId -Type "serves_report" -Confidence $report.confidence -Evidence $report.evidence
}

$jsonPayload = [pscustomobject]@{
    generated_at = (Get-Date).ToString("s")
    summary = [pscustomobject]@{
        semantic_models = $semanticModels.Count
        source_dependencies = $modelSourceRows.Count
        datamarts = $datamartSummaryRows.Count
        report_dependencies = $modelReportRows.Count
        models_without_source = @($modelSummaryRows | Where-Object { $_.source_count -eq 0 }).Count
        likely_report_edges = @($modelReportRows | Where-Object { $_.confidence -eq "likely" }).Count
        source_objects = @($sourceObjectRows | Select-Object -ExpandProperty object_id -Unique).Count
        source_object_dependencies = $sourceObjectRows.Count
        confirmed_source_object_dependencies = @($sourceObjectRows | Where-Object { $_.confidence -eq "confirmed" }).Count
        likely_source_object_dependencies = @($sourceObjectRows | Where-Object { $_.confidence -eq "likely" }).Count
        exact_source_object_dependencies = @($sourceObjectRows | Where-Object { Test-ExactObjectType $_.object_type }).Count
        unresolved_table_or_view_dependencies = @($sourceObjectRows | Where-Object { $_.object_type -eq "table_or_view" }).Count
        object_type_override_rows = $objectTypeOverrideRows.Count
        manual_object_type_evidence_rows = $manualObjectEvidenceRows.Count
        metadata_object_type_evidence_rows = $objectTypeMetadataEvidenceRows.Count
        view_candidates_without_resolved_source = $viewCandidatesWithoutSource
        models_with_source_objects = @($sourceObjectRows | Select-Object -ExpandProperty semantic_model_qualified_name -Unique).Count
    }
    nodes = $jsonNodes
    edges = $jsonEdges
}

Ensure-ParentDirectory -Path $OutputJsonPath
$jsonPayload | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputJsonPath -Encoding UTF8

$sourceObjectCount = @($sourceObjectRows | Select-Object -ExpandProperty object_id -Unique).Count
$modelsWithSourceObjects = @($sourceObjectRows | Select-Object -ExpandProperty semantic_model_qualified_name -Unique).Count
$confirmedSourceObjectDependencies = @($sourceObjectRows | Where-Object { $_.confidence -eq "confirmed" }).Count
$likelySourceObjectDependencies = @($sourceObjectRows | Where-Object { $_.confidence -eq "likely" }).Count
$exactSourceObjectDependencies = @($sourceObjectRows | Where-Object { Test-ExactObjectType $_.object_type }).Count
$unresolvedTableOrViewDependencies = @($sourceObjectRows | Where-Object { $_.object_type -eq "table_or_view" }).Count
$modelsWithViewCandidates = @($viewCandidates | Select-Object -ExpandProperty semantic_model_qualified_name -Unique).Count
$topSourceObjects = @(
    $sourceObjectRows |
        Group-Object -Property source_type, source_server, datamart_name, schema_name, object_name, object_type |
        ForEach-Object {
            $first = $_.Group[0]
            [pscustomobject]@{
                source_type = $first.source_type
                source_server = $first.source_server
                datamart_name = $first.datamart_name
                schema_name = $first.schema_name
                object_name = $first.object_name
                object_type = $first.object_type
                raw_object_type = (@($_.Group | Select-Object -ExpandProperty raw_object_type -Unique | Where-Object { $_ }) -join "; ")
                object_type_source = (@($_.Group | Select-Object -ExpandProperty object_type_source -Unique | Where-Object { $_ }) -join "; ")
                semantic_model_count = @($_.Group | Select-Object -ExpandProperty semantic_model_qualified_name -Unique).Count
                dependency_count = $_.Count
                confidence = if (@($_.Group | Where-Object { $_.confidence -ne "confirmed" }).Count -eq 0) { "confirmed" } else { "mixed" }
            }
        } |
        Sort-Object -Property semantic_model_count, dependency_count -Descending
)

$docLines = [System.Collections.Generic.List[string]]::new()
$docLines.Add("# Semantic Model Source Lineage") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Current Scope") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- Semantic models indexed: $($semanticModels.Count).") | Out-Null
$docLines.Add("- Confirmed semantic model source dependencies: $($modelSourceRows.Count).") | Out-Null
$docLines.Add("- Datamart/source groups: $($datamartSummaryRows.Count).") | Out-Null
$docLines.Add("- Model-to-report dependencies: $($modelReportRows.Count), currently likely when inferred by same-name pairing.") | Out-Null
$docLines.Add("- Models without source connection evidence: $(@($modelSummaryRows | Where-Object { $_.source_count -eq 0 }).Count).") | Out-Null
$docLines.Add("- Source objects attached to the interactive tree: $sourceObjectCount.") | Out-Null
$docLines.Add("- Source object dependencies attached: $($sourceObjectRows.Count), including $confirmedSourceObjectDependencies confirmed and $likelySourceObjectDependencies likely.") | Out-Null
$docLines.Add("- Exact object-type dependencies resolved as table/view/stored procedure/file/shortcut/query: $exactSourceObjectDependencies.") | Out-Null
$docLines.Add('- Dependencies still shown as `table_or_view` pending SQL/Fabric metadata review: ' + $unresolvedTableOrViewDependencies + '.') | Out-Null
$docLines.Add("- Object-type override rows available: $($objectTypeOverrideRows.Count).") | Out-Null
$docLines.Add("- Object-type metadata evidence rows available: $($objectTypeMetadataEvidenceRows.Count).") | Out-Null
$docLines.Add("- Semantic models with extracted view/table/native-query candidates: $modelsWithViewCandidates.") | Out-Null
$docLines.Add("- View/table candidates not safely attached to a datamart/source: $viewCandidatesWithoutSource.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Evidence Rules") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add('- Datamart/source dependencies are based on confirmed Fabric item connection evidence from `index/dependencies.csv`.') | Out-Null
$docLines.Add('- Report dependencies are kept as `likely` when they come from same-name report/model pairing.') | Out-Null
$docLines.Add('- TMDL `Source{[Schema=...,Item=...]}` lookups confirm object names, but keep `table_or_view` until SQL/Fabric metadata, manual evidence, or an approved override confirms the exact type.') | Out-Null
$docLines.Add('- Exact object types are resolved from `index/source_object_type_overrides.csv` first, then exact manual rows, then read-only metadata rows in `analysis/source_object_type_metadata_evidence.csv`.') | Out-Null
$docLines.Add('- Native-query object dependencies are marked `likely` when inferred from SQL `FROM` or `JOIN` text.') | Out-Null
$docLines.Add("- View-level lineage is partial: the current enrichment covers prioritized semantic models and only attaches candidates when the source/datamart can be resolved safely.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Top Datamart / Source Groups") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("| Source type | Source server | Datamart/source | Semantic models | Dependencies |") | Out-Null
$docLines.Add("|---|---|---:|---:|---:|") | Out-Null
foreach ($row in ($datamartSummaryRows | Select-Object -First 25)) {
    $docLines.Add("| $($row.source_type) | $($row.source_server) | $($row.datamart_name) | $($row.semantic_model_count) | $($row.dependency_count) |") | Out-Null
}
$docLines.Add("") | Out-Null
$docLines.Add("## Top Confirmed Source Objects") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add('Rows still marked `table_or_view` are confirmed object-name references but need metadata review before they can be promoted to `table` or `view`.') | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("| Source type | Datamart/source | Schema | Object | Object type | Raw type | Type source | Semantic models | Dependencies | Confidence |") | Out-Null
$docLines.Add("|---|---|---|---|---|---|---|---:|---:|---|") | Out-Null
foreach ($row in ($topSourceObjects | Where-Object { $_.confidence -eq "confirmed" } | Select-Object -First 25)) {
    $docLines.Add("| $($row.source_type) | $($row.datamart_name) | $($row.schema_name) | $($row.object_name) | $($row.object_type) | $($row.raw_object_type) | $($row.object_type_source) | $($row.semantic_model_count) | $($row.dependency_count) | $($row.confidence) |") | Out-Null
}
$docLines.Add("") | Out-Null
$docLines.Add("## Review Files") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add('- `analysis/semantic_model_datamart_dependencies.csv`') | Out-Null
$docLines.Add('- `analysis/semantic_model_view_candidates.csv`') | Out-Null
$docLines.Add('- `analysis/source_object_type_resolution_queue.csv`') | Out-Null
$docLines.Add('- `analysis/source_object_type_metadata_evidence.csv`') | Out-Null
$docLines.Add('- `analysis/source_object_type_metadata_gaps.csv`') | Out-Null
$docLines.Add('- `index/source_object_type_overrides.csv`') | Out-Null
$docLines.Add('- `analysis/semantic_model_definition_gaps.csv`') | Out-Null
$docLines.Add('- `analysis/semantic_datamart_summary.csv`') | Out-Null
$docLines.Add('- `analysis/semantic_model_lineage_summary.csv`') | Out-Null
$docLines.Add('- `analysis/semantic_model_report_dependencies.csv`') | Out-Null
$docLines.Add('- `diagrams/semantic_model_datamart_tree.mmd`') | Out-Null
$docLines.Add('- `frontend/semantic-lineage/index.html`') | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Next Enrichment") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("1. Extend TMDL enrichment beyond the prioritized semantic models until the remaining models are covered or explicitly out of scope.") | Out-Null
$docLines.Add('2. Continue resolving `table_or_view` rows through SQL/Fabric metadata evidence; use `index/source_object_type_overrides.csv` only for approved manual/owner confirmations.') | Out-Null
$docLines.Add('3. Validate `likely` native-query object references with model owners or source SQL metadata.') | Out-Null
$docLines.Add('4. Promote safe `likely` relationships to `confirmed` only when direct metadata or owner evidence exists.') | Out-Null
$docLines.Add("5. Keep unresolved candidates marked for owner review before orchestration decisions depend on them.") | Out-Null

Ensure-ParentDirectory -Path $OutputDocPath
$docLines | Set-Content -Path $OutputDocPath -Encoding UTF8

$mermaidLines = [System.Collections.Generic.List[string]]::new()
$mermaidLines.Add("flowchart LR") | Out-Null
$mermaidLines.Add("    %% Semantic model to datamart lineage summary. Full interactive view is in frontend/semantic-lineage/.") | Out-Null
$mermaidLines.Add("    Root[`"Semantic lineage: $($semanticModels.Count) models`"]") | Out-Null
$mermaidLines.Add("    Sources[`"$($datamartSummaryRows.Count) datamart/source groups`"]") | Out-Null
$mermaidLines.Add("    SourceDeps[`"$($modelSourceRows.Count) confirmed source dependencies`"]") | Out-Null
$mermaidLines.Add("    Objects[`"$sourceObjectCount source objects from TMDL`"]") | Out-Null
$mermaidLines.Add("    Reports[`"$($modelReportRows.Count) likely model-report dependencies`"]") | Out-Null
$mermaidLines.Add("    Root --> Sources --> SourceDeps") | Out-Null
$mermaidLines.Add("    SourceDeps --> Objects") | Out-Null
$mermaidLines.Add("    Root --> Reports") | Out-Null
$mermaidLines.Add("") | Out-Null
$mermaidLines.Add("    subgraph TopSources[`"Top datamarts / sources`"]") | Out-Null
foreach ($datamart in ($datamartSummaryRows | Select-Object -First $MaxMermaidDatamarts)) {
    $sourceId = Sanitize-MermaidId -Value "source:$($datamart.source_type)|$($datamart.source_server)|$($datamart.datamart_name)"
    $sourceLabel = Escape-MermaidLabel -Value "$($datamart.datamart_name) ($($datamart.semantic_model_count) models)"
    $mermaidLines.Add("        $sourceId[`"$sourceLabel`"]") | Out-Null
    $modelsForDatamart = @(
        $modelSourceRows |
            Where-Object {
                $_.source_type -eq $datamart.source_type -and
                $_.source_server -eq $datamart.source_server -and
                $_.datamart_name -eq $datamart.datamart_name
            } |
            Select-Object -First $MaxMermaidModelsPerDatamart
    )
    foreach ($model in $modelsForDatamart) {
        $modelId = Sanitize-MermaidId -Value "model:$($model.semantic_model_qualified_name)"
        $modelLabel = Escape-MermaidLabel -Value $model.semantic_model_name
        $mermaidLines.Add("        $sourceId --> $modelId[`"$modelLabel`"]") | Out-Null
    }
}
$mermaidLines.Add("    end") | Out-Null
$mermaidLines.Add("    SourceDeps --> TopSources") | Out-Null

Ensure-ParentDirectory -Path $OutputMermaidPath
$mermaidLines | Set-Content -Path $OutputMermaidPath -Encoding UTF8

Set-UnresolvedEntry `
    -Title "Semantic model view-level lineage gaps" `
    -Status "partial" `
    -Evidence "Current semantic lineage has $($modelSourceRows.Count) confirmed datamart/source dependencies. TMDL enrichment attached $sourceObjectCount source objects across $modelsWithSourceObjects semantic models, with $confirmedSourceObjectDependencies confirmed and $likelySourceObjectDependencies likely object-level dependencies. Exact object-type dependencies resolved: $exactSourceObjectDependencies. Remaining table_or_view dependencies needing metadata review: $unresolvedTableOrViewDependencies. $viewCandidatesWithoutSource candidates could not be safely attached to a datamart/source." `
    -NextStep "Use analysis/source_object_type_resolution_queue.csv plus SQL/Fabric metadata or owner review to confirm table/view/stored procedure types, record approved rows in index/source_object_type_overrides.csv, continue TMDL enrichment for remaining semantic models, and promote only directly evidenced relationships to confirmed."

Write-Host "Semantic model lineage package built."
Write-Host "Semantic models: $($semanticModels.Count)"
Write-Host "Confirmed source dependencies: $($modelSourceRows.Count)"
Write-Host "Datamart/source groups: $($datamartSummaryRows.Count)"
Write-Host "Likely model-report dependencies: $($modelReportRows.Count)"
Write-Host "Models without source connection evidence: $(@($modelSummaryRows | Where-Object { $_.source_count -eq 0 }).Count)"
Write-Host "Source objects attached: $sourceObjectCount"
Write-Host "Source object dependencies: $($sourceObjectRows.Count)"
Write-Host "Confirmed source object dependencies: $confirmedSourceObjectDependencies"
Write-Host "Likely source object dependencies: $likelySourceObjectDependencies"
Write-Host "Exact source object dependencies: $exactSourceObjectDependencies"
Write-Host "Unresolved table_or_view dependencies: $unresolvedTableOrViewDependencies"
Write-Host "View candidates without resolved source: $viewCandidatesWithoutSource"
Write-Host "Dependency CSV: $OutputDependencyPath"
Write-Host "Documentation: $OutputDocPath"
Write-Host "Interactive JSON: $OutputJsonPath"
