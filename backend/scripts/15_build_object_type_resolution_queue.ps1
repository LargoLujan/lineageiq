# Phase 15 - Object type resolution queue: for every source object
# candidate found so far (table/view/stored_procedure/file/shortcut/
# query), resolves its exact type by checking, in priority order: manual
# overrides, manual evidence, SQL-endpoint/SharePoint metadata evidence --
# and queues whatever's still ambiguous for manual classification. Purely
# local, no API calls.
# Writes: $OutputQueuePath, $OutputSummaryPath, $OutputDocPath.
param(
    [string]$ViewCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_view_candidates.csv"),
    [string]$ItemObjectLineageCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/item_object_lineage_candidates.csv"),
    [string]$PipelineObjectLineageCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/pipeline_object_lineage_candidates.csv"),
    [string]$ManualObjectEvidencePath = (Join-Path $PSScriptRoot "../../index/manual_lineage_object_evidence.csv"),
    [string]$ObjectTypeOverridesPath = (Join-Path $PSScriptRoot "../../index/source_object_type_overrides.csv"),
    [string]$ObjectTypeMetadataEvidencePath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_metadata_evidence.csv"),
    [string]$SqlEndpointCatalogPath = (Join-Path $PSScriptRoot "../../analysis/sql_endpoint_object_catalog.csv"),
    [string]$SharePointObjectTypeEvidencePath = "",
    [string]$OutputQueuePath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_resolution_queue.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_resolution_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/15_object_type_resolution.md")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$script:ExactObjectTypes = @("table", "view", "stored_procedure", "file", "shortcut", "query")
$script:OverrideResolvers = @{}
$script:ManualResolvers = @{}
$script:MetadataResolvers = @{}
$script:SharePointResolvers = @{}

function Ensure-CsvHeader {
    param([string]$Path, [string[]]$Columns)
    Ensure-ParentDirectory -Path $Path
    if (-not (Test-Path $Path)) {
        ('"' + ($Columns -join '","') + '"') | Set-Content -Path $Path -Encoding UTF8
    }
}

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
    return ($Value.ToLowerInvariant() -replace "\s+", " ").Trim()
}

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

    foreach ($key in @(
        (New-ObjectTypeKey -SourceType $sourceType -SourceServer $sourceServer -SourceDatabase $sourceDatabase -SchemaName $schemaName -ObjectName $objectName),
        (New-ObjectTypeKey -SourceType "" -SourceServer $sourceServer -SourceDatabase $sourceDatabase -SchemaName $schemaName -ObjectName $objectName)
    ) | Select-Object -Unique) {
        if ($Map.ContainsKey($key) -and $Map[$key].object_type -ne $normalizedType) {
            $Map[$key] = [pscustomobject]@{
                object_type = "unknown"
                source = "${Source}_conflict"
                confidence = "unknown"
                evidence = "Conflicting object type evidence for this source object."
                reviewer = ""
                reviewed_at = ""
            }
            continue
        }

        $Map[$key] = [pscustomobject]@{
            object_type = $normalizedType
            source = $Source
            confidence = Get-FieldValue -Object $Row -Names @("confidence", "object_type_confidence")
            evidence = Get-FieldValue -Object $Row -Names @("evidence")
            reviewer = Get-FieldValue -Object $Row -Names @("reviewer")
            reviewed_at = Get-FieldValue -Object $Row -Names @("reviewed_at")
        }
    }
}

function Get-ObjectTypeResolution {
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
        if ($script:OverrideResolvers.ContainsKey($key) -and (Test-ExactObjectType $script:OverrideResolvers[$key].object_type)) {
            return $script:OverrideResolvers[$key]
        }
    }

    foreach ($key in $keys) {
        if ($script:ManualResolvers.ContainsKey($key) -and (Test-ExactObjectType $script:ManualResolvers[$key].object_type)) {
            return $script:ManualResolvers[$key]
        }
    }

    foreach ($key in $keys) {
        if ($script:MetadataResolvers.ContainsKey($key) -and (Test-ExactObjectType $script:MetadataResolvers[$key].object_type)) {
            return $script:MetadataResolvers[$key]
        }
    }

    foreach ($key in $keys) {
        if ($script:SharePointResolvers.ContainsKey($key) -and (Test-ExactObjectType $script:SharePointResolvers[$key].object_type)) {
            return $script:SharePointResolvers[$key]
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
        reviewer = ""
        reviewed_at = ""
    }
}

$overrideColumns = @("source_type", "source_server", "source_database", "schema_name", "object_name", "object_type", "confidence", "evidence", "reviewer", "reviewed_at", "notes")
Ensure-CsvHeader -Path $ObjectTypeOverridesPath -Columns $overrideColumns

if (-not (Test-Path $ViewCandidatesPath)) {
    throw "Required input not found: $ViewCandidatesPath"
}

$viewCandidates = @(Import-Csv -Path $ViewCandidatesPath | Where-Object { $_.object_name })
$itemObjectCandidateRows = if (Test-Path $ItemObjectLineageCandidatesPath) { @(Import-Csv -Path $ItemObjectLineageCandidatesPath | Where-Object { $_.object_name }) } else { @() }
$pipelineObjectCandidateRows = if (Test-Path $PipelineObjectLineageCandidatesPath) { @(Import-Csv -Path $PipelineObjectLineageCandidatesPath | Where-Object { $_.object_name }) } else { @() }
$manualRows = if (Test-Path $ManualObjectEvidencePath) { @(Import-Csv -Path $ManualObjectEvidencePath | Where-Object { $_.object_name }) } else { @() }
$overrideRows = @(Import-Csv -Path $ObjectTypeOverridesPath | Where-Object { $_.object_name -and $_.object_type })
$metadataRows = if (Test-Path $ObjectTypeMetadataEvidencePath) { @(Import-Csv -Path $ObjectTypeMetadataEvidencePath | Where-Object { $_.object_name -and $_.object_type }) } else { @() }
$catalogRows = if (Test-Path $SqlEndpointCatalogPath) { @(Import-Csv -Path $SqlEndpointCatalogPath | Where-Object { $_.object_name -and $_.object_type -and ((Get-FieldValue -Object $_ -Names @("catalog_status")) -in @("", "confirmed")) }) } else { @() }
$sharePointRows = if ($SharePointObjectTypeEvidencePath -and (Test-Path $SharePointObjectTypeEvidencePath)) { @(Import-Csv -Path $SharePointObjectTypeEvidencePath | Where-Object { $_.object_name -and $_.object_type }) } else { @() }

foreach ($row in $overrideRows) {
    Add-ObjectTypeResolver -Map $script:OverrideResolvers -Source "override" -Row $row -ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
}

foreach ($row in $manualRows) {
    Add-ObjectTypeResolver -Map $script:ManualResolvers -Source "manual_review" -Row $row -ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
}
foreach ($row in $metadataRows) {
    Add-ObjectTypeResolver -Map $script:MetadataResolvers -Source "metadata_readonly" -Row $row -ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
}
foreach ($row in $catalogRows) {
    Add-ObjectTypeResolver -Map $script:MetadataResolvers -Source "sql_endpoint_catalog" -Row $row -ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
}
foreach ($row in $sharePointRows) {
    Add-ObjectTypeResolver -Map $script:SharePointResolvers -Source "sharepoint_catalog" -Row $row -ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
}

$ambiguousTypes = @("table_or_view", "native_query_object")
$groups = @{}

foreach ($candidate in $viewCandidates) {
    $rawType = Normalize-ObjectType (Get-FieldValue -Object $candidate -Names @("object_type"))
    if ($rawType -notin $ambiguousTypes) { continue }

    $sourceType = "SQL"
    $sourceServer = Get-FieldValue -Object $candidate -Names @("source_server")
    $sourceDatabase = Get-FieldValue -Object $candidate -Names @("database_name", "source_database")
    $schemaName = Get-FieldValue -Object $candidate -Names @("schema_name")
    $objectName = Get-FieldValue -Object $candidate -Names @("object_name")
    if (-not $objectName) { continue }

    $groupKey = New-ObjectTypeKey -SourceType $sourceType -SourceServer $sourceServer -SourceDatabase $sourceDatabase -SchemaName $schemaName -ObjectName $objectName
    $groupKey = "$groupKey|$rawType"
    if (-not $groups.ContainsKey($groupKey)) {
        $groups[$groupKey] = [pscustomobject]@{
            source_type = $sourceType
            source_server = $sourceServer
            source_database = $sourceDatabase
            schema_name = $schemaName
            object_name = $objectName
            raw_object_type = $rawType
            candidate_count = 0
            workspaces = [System.Collections.Generic.List[string]]::new()
            models = [System.Collections.Generic.List[string]]::new()
            item_types = [System.Collections.Generic.List[string]]::new()
            semantic_tables = [System.Collections.Generic.List[string]]::new()
            definition_paths = [System.Collections.Generic.List[string]]::new()
            confidences = [System.Collections.Generic.List[string]]::new()
        }
    }

    $group = $groups[$groupKey]
    $group.candidate_count += 1
    foreach ($value in @(
        (Get-FieldValue -Object $candidate -Names @("workspace_name")),
        (Get-FieldValue -Object $candidate -Names @("semantic_model_qualified_name")),
        (Get-FieldValue -Object $candidate -Names @("semantic_table")),
        (Get-FieldValue -Object $candidate -Names @("definition_path")),
        (Get-FieldValue -Object $candidate -Names @("confidence"))
    )) {
        if (-not $value) { continue }
    }
    $workspaceName = Get-FieldValue -Object $candidate -Names @("workspace_name")
    $modelName = Get-FieldValue -Object $candidate -Names @("semantic_model_qualified_name")
    $semanticTable = Get-FieldValue -Object $candidate -Names @("semantic_table")
    $definitionPath = Get-FieldValue -Object $candidate -Names @("definition_path")
    $confidence = Get-FieldValue -Object $candidate -Names @("confidence")
    if ($workspaceName) { $group.workspaces.Add($workspaceName) | Out-Null }
    if ($modelName) { $group.models.Add($modelName) | Out-Null }
    $group.item_types.Add("SemanticModel") | Out-Null
    if ($semanticTable) { $group.semantic_tables.Add($semanticTable) | Out-Null }
    if ($definitionPath) { $group.definition_paths.Add($definitionPath) | Out-Null }
    if ($confidence) { $group.confidences.Add($confidence) | Out-Null }
}

foreach ($candidate in @($itemObjectCandidateRows + $pipelineObjectCandidateRows)) {
    $rawType = Normalize-ObjectType (Get-FieldValue -Object $candidate -Names @("object_type"))
    if ($rawType -notin $ambiguousTypes) { continue }

    $sourceType = Get-FieldValue -Object $candidate -Names @("source_type")
    $sourceServer = Get-FieldValue -Object $candidate -Names @("source_server", "server")
    $sourceDatabase = Get-FieldValue -Object $candidate -Names @("source_database", "database_name", "database")
    $schemaName = Get-FieldValue -Object $candidate -Names @("schema_name", "source_schema")
    $objectName = Get-FieldValue -Object $candidate -Names @("object_name", "source_object")
    if (-not $objectName) { continue }

    $groupKey = New-ObjectTypeKey -SourceType $sourceType -SourceServer $sourceServer -SourceDatabase $sourceDatabase -SchemaName $schemaName -ObjectName $objectName
    $groupKey = "$groupKey|$rawType"
    if (-not $groups.ContainsKey($groupKey)) {
        $groups[$groupKey] = [pscustomobject]@{
            source_type = $sourceType
            source_server = $sourceServer
            source_database = $sourceDatabase
            schema_name = $schemaName
            object_name = $objectName
            raw_object_type = $rawType
            candidate_count = 0
            workspaces = [System.Collections.Generic.List[string]]::new()
            models = [System.Collections.Generic.List[string]]::new()
            item_types = [System.Collections.Generic.List[string]]::new()
            semantic_tables = [System.Collections.Generic.List[string]]::new()
            definition_paths = [System.Collections.Generic.List[string]]::new()
            confidences = [System.Collections.Generic.List[string]]::new()
        }
    }

    $group = $groups[$groupKey]
    $group.candidate_count += 1
    $workspaceName = Get-FieldValue -Object $candidate -Names @("workspace_name")
    $itemName = Get-FieldValue -Object $candidate -Names @("item_qualified_name", "qualified_name")
    $itemType = Get-FieldValue -Object $candidate -Names @("item_type")
    $semanticTable = Get-FieldValue -Object $candidate -Names @("semantic_table", "logical_table")
    $definitionPath = Get-FieldValue -Object $candidate -Names @("definition_path")
    $confidence = Get-FieldValue -Object $candidate -Names @("confidence")
    if ($workspaceName) { $group.workspaces.Add($workspaceName) | Out-Null }
    if ($itemName) { $group.models.Add($itemName) | Out-Null }
    if ($itemType) { $group.item_types.Add($itemType) | Out-Null }
    if ($semanticTable) { $group.semantic_tables.Add($semanticTable) | Out-Null }
    if ($definitionPath) { $group.definition_paths.Add($definitionPath) | Out-Null }
    if ($confidence) { $group.confidences.Add($confidence) | Out-Null }
}

$queueRows = [System.Collections.Generic.List[object]]::new()
foreach ($key in ($groups.Keys | Sort-Object)) {
    $group = $groups[$key]
    $resolution = Get-ObjectTypeResolution `
        -SourceType $group.source_type `
        -SourceServer $group.source_server `
        -SourceDatabase $group.source_database `
        -SchemaName $group.schema_name `
        -ObjectName $group.object_name `
        -RawObjectType $group.raw_object_type

    $resolved = Test-ExactObjectType $resolution.object_type
    $modelCount = @($group.models.ToArray() | Sort-Object -Unique).Count
    $affectedItemTypes = (@($group.item_types.ToArray() | Sort-Object -Unique) -join "; ")
    $priorityScore = ($modelCount * 10) + [int]$group.candidate_count
    if (-not $resolved) { $priorityScore += 50 }
    if ($group.raw_object_type -eq "table_or_view") { $priorityScore += 20 }

    $queueRows.Add([pscustomobject]@{
        status = if ($resolved) { "resolved" } else { "needs_metadata_review" }
        priority_score = $priorityScore
        source_type = $group.source_type
        source_server = $group.source_server
        source_database = $group.source_database
        schema_name = $group.schema_name
        object_name = $group.object_name
        raw_object_type = $group.raw_object_type
        resolved_object_type = if ($resolved) { $resolution.object_type } else { "" }
        resolver_source = if ($resolved) { $resolution.source } else { $resolution.source }
        resolver_confidence = $resolution.confidence
        resolver_evidence = $resolution.evidence
        semantic_model_count = $modelCount
        affected_item_count = $modelCount
        affected_item_types = $affectedItemTypes
        candidate_count = $group.candidate_count
        workspaces = (@($group.workspaces.ToArray() | Sort-Object -Unique) -join "; ")
        semantic_models = (@($group.models.ToArray() | Sort-Object -Unique | Select-Object -First 12) -join "; ")
        affected_items = (@($group.models.ToArray() | Sort-Object -Unique | Select-Object -First 12) -join "; ")
        semantic_tables = (@($group.semantic_tables.ToArray() | Sort-Object -Unique | Select-Object -First 20) -join "; ")
        definition_paths = (@($group.definition_paths.ToArray() | Sort-Object -Unique | Select-Object -First 20) -join "; ")
        confidence = (@($group.confidences.ToArray() | Sort-Object -Unique) -join "; ")
        next_step = if ($resolved) {
            "No action needed unless the resolution evidence changes."
        } elseif ($group.raw_object_type -eq "table_or_view") {
            "Confirm from SQL/Fabric metadata whether this object is a table or a view; capture metadata evidence automatically or add an approved manual override."
        } else {
            "Review the native query or source metadata, confirm table/view/stored_procedure, then capture metadata evidence or add an approved manual override."
        }
    }) | Out-Null
}

$sortedQueueRows = @(
    $queueRows |
        Sort-Object `
            @{ Expression = { if ($_.status -eq "needs_metadata_review") { 0 } else { 1 } } }, `
            @{ Expression = { [int]$_.priority_score }; Descending = $true }, `
            source_server, source_database, schema_name, object_name
)

$queueColumns = @(
    "status", "priority_score", "source_type", "source_server", "source_database", "schema_name", "object_name",
    "raw_object_type", "resolved_object_type", "resolver_source", "resolver_confidence", "resolver_evidence",
    "semantic_model_count", "affected_item_count", "affected_item_types", "candidate_count", "workspaces", "semantic_models", "affected_items", "semantic_tables", "definition_paths",
    "confidence", "next_step"
)
Export-Rows -Rows $sortedQueueRows -Columns $queueColumns -Path $OutputQueuePath

$summaryRows = @(
    $sortedQueueRows |
        Group-Object -Property status, raw_object_type, resolver_source |
        ForEach-Object {
            $first = $_.Group[0]
            [pscustomobject]@{
                status = $first.status
                raw_object_type = $first.raw_object_type
                resolver_source = $first.resolver_source
                object_count = $_.Count
                candidate_count = ($_.Group | Measure-Object -Property candidate_count -Sum).Sum
                semantic_model_count = @($_.Group | ForEach-Object { $_.semantic_models -split "; " } | Where-Object { $_ } | Sort-Object -Unique).Count
            }
        } |
        Sort-Object status, raw_object_type, resolver_source
)

$summaryColumns = @("status", "raw_object_type", "resolver_source", "object_count", "candidate_count", "semantic_model_count")
Export-Rows -Rows $summaryRows -Columns $summaryColumns -Path $OutputSummaryPath

$pendingCount = @($sortedQueueRows | Where-Object { $_.status -eq "needs_metadata_review" }).Count
$resolvedCount = @($sortedQueueRows | Where-Object { $_.status -eq "resolved" }).Count

$docLines = [System.Collections.Generic.List[string]]::new()
$docLines.Add("# Source Object Type Resolution") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Purpose") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add('TMDL, notebook, CopyJob, and DataPipeline extraction can confirm source object names, but they do not always prove whether the SQL/Fabric object is a table, view, or stored procedure. This step keeps the automatic evidence honest and tracks exact-type evidence from approved overrides, manual evidence, and read-only metadata extraction.') | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Current Summary") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- Ambiguous unique source objects queued: $($sortedQueueRows.Count).") | Out-Null
$docLines.Add("- Still needing metadata review: $pendingCount.") | Out-Null
$docLines.Add("- Resolved by override, manual evidence, or read-only metadata: $resolvedCount.") | Out-Null
$docLines.Add("- Override rows available: $($overrideRows.Count).") | Out-Null
$docLines.Add("- Manual exact object-type evidence rows available: $(@($manualRows | Where-Object { Test-ExactObjectType (Get-FieldValue -Object $_ -Names @('object_type')) }).Count).") | Out-Null
$docLines.Add("- Read-only metadata evidence rows available: $($metadataRows.Count).") | Out-Null
$docLines.Add("- SQL endpoint catalog rows available: $($catalogRows.Count).") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Files") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add('- `analysis/source_object_type_resolution_queue.csv`') | Out-Null
$docLines.Add('- `analysis/source_object_type_resolution_summary.csv`') | Out-Null
$docLines.Add('- `analysis/source_object_type_metadata_evidence.csv`') | Out-Null
$docLines.Add('- `analysis/source_object_type_metadata_gaps.csv`') | Out-Null
$docLines.Add('- `analysis/sql_endpoint_object_catalog.csv`') | Out-Null
$docLines.Add('- `index/source_object_type_overrides.csv`') | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Override Rule") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add('Add one row to `index/source_object_type_overrides.csv` only when owner/manual review or code review confirms the exact type and automatic metadata evidence is not enough. Suggested `object_type` values are `table`, `view`, `stored_procedure`, `file`, `shortcut`, `query`, or `unknown`.') | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("The refresh pipeline applies overrides before rebuilding the JSON, standalone HTML, and semantic lineage documentation.") | Out-Null

Ensure-ParentDirectory -Path $OutputDocPath
$docLines | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "Source object type resolution queue built."
Write-Host "Queued objects: $($sortedQueueRows.Count)"
Write-Host "Pending metadata review: $pendingCount"
Write-Host "Resolved: $resolvedCount"
Write-Host "Queue: $OutputQueuePath"
Write-Host "Summary: $OutputSummaryPath"
