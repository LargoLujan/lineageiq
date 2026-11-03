# Phase 17 - Object impact index: inverts the lineage explorer's item-level
# graph into a per-source-object index (which items read/write each
# table/view, transitively), used by the web UI's Impact feature to answer
# "what breaks if I change this object." Delegates to the faster
# backend/scripts/17_build_object_impact_index_fast.py when python is available,
# falling back to this PowerShell version otherwise -- keep both in sync.
# Writes: $OutputImpactPath/$OutputImpactSummaryPath, coverage CSVs, doc.
param(
    [string]$ExplorerDataPath = (Join-Path $PSScriptRoot "../../frontend/semantic-lineage/data/lineage-explorer.json"),
    [string]$ObjectTypeResolutionQueuePath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_resolution_queue.csv"),
    [string]$OutputImpactPath = (Join-Path $PSScriptRoot "../../analysis/object_impact_index.csv"),
    [string]$OutputImpactSummaryPath = (Join-Path $PSScriptRoot "../../analysis/object_impact_summary.csv"),
    [string]$OutputCoveragePath = (Join-Path $PSScriptRoot "../../analysis/object_level_lineage_coverage.csv"),
    [string]$OutputCoverageSummaryPath = (Join-Path $PSScriptRoot "../../analysis/object_level_lineage_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/16_object_level_lineage_and_impact.md")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$fastScriptPath = (Join-Path $PSScriptRoot "17_build_object_impact_index_fast.py")
$pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $pythonCommand) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
}
if ((Test-Path $fastScriptPath) -and $pythonCommand) {
    & $pythonCommand.Source $fastScriptPath `
        --explorer-data-path $ExplorerDataPath `
        --object-type-resolution-queue-path $ObjectTypeResolutionQueuePath `
        --output-impact-path $OutputImpactPath `
        --output-impact-summary-path $OutputImpactSummaryPath `
        --output-coverage-path $OutputCoveragePath `
        --output-coverage-summary-path $OutputCoverageSummaryPath `
        --output-doc-path $OutputDocPath
    exit $LASTEXITCODE
}

function Normalize-Key {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return ($Value.Trim().ToLowerInvariant() -replace "\s+", " ")
}

function Get-Text {
    param([object]$Value)
    if ($null -eq $Value) { return "" }
    return [string]$Value
}

function Get-FieldObject {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Get-FieldValue {
    param([object]$Object, [string]$Name)
    return Get-Text (Get-FieldObject -Object $Object -Name $Name)
}

function Test-ExactObjectType {
    param([string]$ObjectType)
    return (Normalize-ObjectType $ObjectType) -in @("table", "view", "stored_procedure", "file", "shortcut", "query")
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

function New-ObjectKey {
    param(
        [string]$SourceType,
        [string]$Server,
        [string]$Database,
        [string]$Schema,
        [string]$ObjectName
    )
    return @($SourceType, $Server, $Database, $Schema, $ObjectName | ForEach-Object { Normalize-Key $_ }) -join "|"
}

function Get-GapReason {
    param(
        [string]$ItemType,
        [int]$SourceCount,
        [int]$ObjectCount
    )

    if ($ObjectCount -gt 0) { return "object_level_present" }
    if ($ItemType -eq "Notebook") { return "notebook_definition_extraction_required" }
    if ($ItemType -eq "CopyJob") { return "copyjob_mapping_extraction_required" }
    if ($ItemType -eq "SemanticModel" -and $SourceCount -gt 0) { return "tmdl_object_extraction_required_or_incomplete" }
    if ($ItemType -eq "SemanticModel") { return "semantic_model_source_dependency_missing" }
    if ($SourceCount -gt 0) { return "source_known_object_missing" }
    return "source_dependency_missing"
}

function Get-NextAction {
    param([string]$GapReason)
    switch ($GapReason) {
        "object_level_present" { return "Ready for reverse impact search with current evidence." }
        "notebook_definition_extraction_required" { return "Read notebook definition/code and parse lakehouse, Spark SQL, JDBC/ODBC, table, view, stored procedure, path, and notebook-call references." }
        "copyjob_mapping_extraction_required" { return "Read CopyJob definition/source-destination mappings and extract source and target tables, views, stored procedures, files, or folders." }
        "tmdl_object_extraction_required_or_incomplete" { return "Read or re-read semantic model TMDL/Power Query and extract every Schema/Item/native query object reference." }
        "semantic_model_source_dependency_missing" { return "Read semantic model connections and TMDL to identify source systems before object extraction." }
        "source_known_object_missing" { return "Inspect item definition or owner evidence to attach object-level references to the known source." }
        default { return "Discover item dependencies first, then extract object-level lineage." }
    }
}

if (-not (Test-Path $ExplorerDataPath)) {
    throw "Explorer data file not found: $ExplorerDataPath"
}

function New-ResolutionKey {
    param(
        [string]$SourceType,
        [string]$Server,
        [string]$Database,
        [string]$Schema,
        [string]$ObjectName
    )
    $typePart = if ($SourceType) { Normalize-Key $SourceType } else { "*" }
    return @(
        $typePart
        Normalize-Key $Server
        Normalize-Key $Database
        Normalize-Key $Schema
        Normalize-Key $ObjectName
    ) -join "|"
}

function Get-ObjectTypeResolution {
    param(
        [hashtable]$Index,
        [string]$SourceType,
        [string]$Server,
        [string]$Database,
        [string]$Schema,
        [string]$ObjectName
    )

    foreach ($key in @(
        (New-ResolutionKey -SourceType $SourceType -Server $Server -Database $Database -Schema $Schema -ObjectName $ObjectName),
        (New-ResolutionKey -SourceType "" -Server $Server -Database $Database -Schema $Schema -ObjectName $ObjectName)
    ) | Select-Object -Unique) {
        if ($Index.ContainsKey($key)) { return $Index[$key] }
    }
    return $null
}

$typeResolutionByObject = @{}
if (Test-Path $ObjectTypeResolutionQueuePath) {
    foreach ($row in @(Import-Csv -Path $ObjectTypeResolutionQueuePath)) {
        $status = Get-FieldValue -Object $row -Name "status"
        $resolvedType = Normalize-ObjectType (Get-FieldValue -Object $row -Name "resolved_object_type")
        if ((Normalize-Key $status) -ne "resolved" -or -not (Test-ExactObjectType $resolvedType)) { continue }

        $resolution = [pscustomobject]@{
            object_type = $resolvedType
            object_type_source = Get-FieldValue -Object $row -Name "resolver_source"
            object_type_confidence = Get-FieldValue -Object $row -Name "resolver_confidence"
            evidence = Get-FieldValue -Object $row -Name "resolver_evidence"
        }

        foreach ($key in @(
            (New-ResolutionKey -SourceType (Get-FieldValue -Object $row -Name "source_type") -Server (Get-FieldValue -Object $row -Name "source_server") -Database (Get-FieldValue -Object $row -Name "source_database") -Schema (Get-FieldValue -Object $row -Name "schema_name") -ObjectName (Get-FieldValue -Object $row -Name "object_name")),
            (New-ResolutionKey -SourceType "" -Server (Get-FieldValue -Object $row -Name "source_server") -Database (Get-FieldValue -Object $row -Name "source_database") -Schema (Get-FieldValue -Object $row -Name "schema_name") -ObjectName (Get-FieldValue -Object $row -Name "object_name"))
        ) | Select-Object -Unique) {
            if ($key -and -not $typeResolutionByObject.ContainsKey($key)) {
                $typeResolutionByObject[$key] = $resolution
            }
        }
    }
}

$payload = Get-Content -Path $ExplorerDataPath -Raw | ConvertFrom-Json -Depth 100
$impactRows = [System.Collections.Generic.List[object]]::new()
$coverageRows = [System.Collections.Generic.List[object]]::new()
$modes = @("semantic", "notebooks", "copyjobs", "pipelines")

foreach ($workspace in @(Get-FieldObject -Object $payload -Name "workspaces")) {
    foreach ($mode in $modes) {
        foreach ($item in @(Get-FieldObject -Object $workspace -Name $mode)) {
            if (-not $item) { continue }
            $sources = @(Get-FieldObject -Object $item -Name "sources")
            $objects = [System.Collections.Generic.List[object]]::new()
            $resolvedObjectTypesForItem = [System.Collections.Generic.List[string]]::new()
            foreach ($source in $sources) {
                foreach ($object in @(Get-FieldObject -Object $source -Name "objects")) {
                    if (-not $object) { continue }
                    $schema = Get-FieldValue -Object $object -Name "schema"
                    $objectName = Get-FieldValue -Object $object -Name "object_name"
                    $objectServer = Get-FieldValue -Object $object -Name "server"
                    $objectDatabase = Get-FieldValue -Object $object -Name "database"
                    $objectSourceType = Get-FieldValue -Object $object -Name "source_type"
                    $server = if ($objectServer) { $objectServer } else { Get-FieldValue -Object $source -Name "server" }
                    $database = if ($objectDatabase) { $objectDatabase } else { Get-FieldValue -Object $source -Name "database" }
                    $sourceType = if ($objectSourceType) { $objectSourceType } else { Get-FieldValue -Object $source -Name "source_type" }
                    $originalObjectType = Get-FieldValue -Object $object -Name "type"
                    $rawObjectType = Get-FieldValue -Object $object -Name "raw_object_type"
                    $objectType = $originalObjectType
                    $objectTypeSource = Get-FieldValue -Object $object -Name "object_type_source"
                    $objectTypeConfidence = Get-FieldValue -Object $object -Name "object_type_confidence"
                    $resolution = Get-ObjectTypeResolution -Index $typeResolutionByObject -SourceType $sourceType -Server $server -Database $database -Schema $schema -ObjectName $objectName
                    if ($resolution) {
                        $objectType = $resolution.object_type
                        if (-not $rawObjectType) { $rawObjectType = $originalObjectType }
                        $objectTypeSource = $resolution.object_type_source
                        $objectTypeConfidence = $resolution.object_type_confidence
                    }
                    $objectKey = New-ObjectKey -SourceType $sourceType -Server $server -Database $database -Schema $schema -ObjectName $objectName
                    $objectDisplayName = @($database, $(if ($schema) { "$schema.$objectName" } else { $objectName })) | Where-Object { $_ } | Select-Object -First 2
                    $display = ($objectDisplayName -join " / ")
                    $evidence = Get-FieldValue -Object $object -Name "evidence"
                    if ($resolution -and $resolution.evidence) {
                        $evidence = (($evidence + " Exact object type resolved from $($resolution.object_type_source): $($resolution.evidence)") -replace "\s+", " ").Trim()
                    }
                    $impactRows.Add([pscustomobject]@{
                        object_key = $objectKey
                        object_display_name = $display
                        source_type = $sourceType
                        source_server = $server
                        source_database = $database
                        schema_name = $schema
                        object_name = $objectName
                        object_type = $objectType
                        raw_object_type = $rawObjectType
                        object_type_source = $objectTypeSource
                        object_type_confidence = $objectTypeConfidence
                        item_workspace_name = Get-FieldValue -Object $workspace -Name "name"
                        item_type = Get-FieldValue -Object $item -Name "item_type"
                        item_name = Get-FieldValue -Object $item -Name "label"
                        item_qualified_name = Get-FieldValue -Object $item -Name "qualified_name"
                        mode = $mode
                        source_label = Get-FieldValue -Object $source -Name "label"
                        source_qualified_name = Get-FieldValue -Object $source -Name "qualified_name"
                        semantic_table = Get-FieldValue -Object $object -Name "semantic_table"
                        usage_type = Get-FieldValue -Object $object -Name "usage_type"
                        confidence = Get-FieldValue -Object $object -Name "confidence"
                        evidence = $evidence
                    }) | Out-Null
                    $objects.Add($object) | Out-Null
                    $resolvedObjectTypesForItem.Add($objectType) | Out-Null
                }
            }

            $objectCount = $objects.Count
            $exactCount = @($resolvedObjectTypesForItem | Where-Object { Test-ExactObjectType (Get-Text $_) }).Count
            $ambiguousCount = $objectCount - $exactCount
            $gapReason = Get-GapReason -ItemType (Get-FieldValue -Object $item -Name "item_type") -SourceCount $sources.Count -ObjectCount $objectCount
            $coverageRows.Add([pscustomobject]@{
                workspace_name = Get-FieldValue -Object $workspace -Name "name"
                workspace_environment = Get-FieldValue -Object $workspace -Name "environment"
                item_type = Get-FieldValue -Object $item -Name "item_type"
                item_name = Get-FieldValue -Object $item -Name "label"
                item_qualified_name = Get-FieldValue -Object $item -Name "qualified_name"
                source_count = $sources.Count
                object_count = $objectCount
                exact_object_count = $exactCount
                ambiguous_object_count = $ambiguousCount
                coverage_status = if ($objectCount -gt 0) { "object_level_present" } elseif ($sources.Count -gt 0) { "source_only" } else { "no_source" }
                gap_reason = $gapReason
                next_action = Get-NextAction -GapReason $gapReason
            }) | Out-Null
        }
    }
}

$impactSummaryRows = [System.Collections.Generic.List[object]]::new()
foreach ($group in ($impactRows | Group-Object -Property object_key)) {
    $first = $group.Group[0]
    $affectedItems = @($group.Group | Select-Object -ExpandProperty item_qualified_name -Unique | Sort-Object)
    $itemTypes = @($group.Group | Select-Object -ExpandProperty item_type -Unique | Sort-Object)
    $impactSummaryRows.Add([pscustomobject]@{
        object_key = $first.object_key
        object_display_name = $first.object_display_name
        source_type = $first.source_type
        source_server = $first.source_server
        source_database = $first.source_database
        schema_name = $first.schema_name
        object_name = $first.object_name
        object_type_values = (@($group.Group | Select-Object -ExpandProperty object_type -Unique | Where-Object { $_ }) -join "; ")
        object_type_sources = (@($group.Group | Select-Object -ExpandProperty object_type_source -Unique | Where-Object { $_ }) -join "; ")
        affected_item_count = $affectedItems.Count
        semantic_model_count = @($group.Group | Where-Object { $_.item_type -eq "SemanticModel" } | Select-Object -ExpandProperty item_qualified_name -Unique).Count
        notebook_count = @($group.Group | Where-Object { $_.item_type -eq "Notebook" } | Select-Object -ExpandProperty item_qualified_name -Unique).Count
        copyjob_count = @($group.Group | Where-Object { $_.item_type -eq "CopyJob" } | Select-Object -ExpandProperty item_qualified_name -Unique).Count
        pipeline_count = @($group.Group | Where-Object { $_.item_type -eq "DataPipeline" } | Select-Object -ExpandProperty item_qualified_name -Unique).Count
        affected_item_types = ($itemTypes -join "; ")
        affected_items_sample = (@($affectedItems | Select-Object -First 12) -join "; ")
    }) | Out-Null
}

$coverageSummaryRows = [System.Collections.Generic.List[object]]::new()
foreach ($group in ($coverageRows | Group-Object -Property item_type)) {
    $rows = @($group.Group)
    $coverageSummaryRows.Add([pscustomobject]@{
        item_type = $group.Name
        item_count = $rows.Count
        with_sources = @($rows | Where-Object { [int]$_.source_count -gt 0 }).Count
        with_object_level_lineage = @($rows | Where-Object { [int]$_.object_count -gt 0 }).Count
        without_object_level_lineage = @($rows | Where-Object { [int]$_.object_count -eq 0 }).Count
        object_references = (@($rows | Measure-Object -Property object_count -Sum).Sum)
        exact_object_references = (@($rows | Measure-Object -Property exact_object_count -Sum).Sum)
        ambiguous_object_references = (@($rows | Measure-Object -Property ambiguous_object_count -Sum).Sum)
    }) | Out-Null
}

Ensure-ParentDirectory -Path $OutputImpactPath
Ensure-ParentDirectory -Path $OutputImpactSummaryPath
Ensure-ParentDirectory -Path $OutputCoveragePath
Ensure-ParentDirectory -Path $OutputCoverageSummaryPath
Ensure-ParentDirectory -Path $OutputDocPath

$impactRows | Sort-Object source_type, source_server, source_database, schema_name, object_name, item_type, item_name | Export-Csv -Path $OutputImpactPath -NoTypeInformation -Encoding UTF8
$impactSummaryRows | Sort-Object @{ Expression = "affected_item_count"; Descending = $true }, source_database, schema_name, object_name | Export-Csv -Path $OutputImpactSummaryPath -NoTypeInformation -Encoding UTF8
$coverageRows | Sort-Object item_type, workspace_name, item_name | Export-Csv -Path $OutputCoveragePath -NoTypeInformation -Encoding UTF8
$coverageSummaryRows | Sort-Object item_type | Export-Csv -Path $OutputCoverageSummaryPath -NoTypeInformation -Encoding UTF8

$totalItems = $coverageRows.Count
$withObjectLevel = @($coverageRows | Where-Object { [int]$_.object_count -gt 0 }).Count
$withoutObjectLevel = $totalItems - $withObjectLevel
$uniqueObjects = $impactSummaryRows.Count
$objectReferences = $impactRows.Count
$exactReferences = @($impactRows | Where-Object { Test-ExactObjectType $_.object_type }).Count

$docLines = [System.Collections.Generic.List[string]]::new()
$docLines.Add("# Object-Level Lineage And Reverse Impact") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Generated at: $((Get-Date).ToString("s"))") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Purpose") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Provide the local index needed to answer reverse-impact questions such as: if a SQL/Fabric table, view, stored procedure, file, or query changes, which semantic models, notebooks, CopyJobs, pipelines, and reports can be affected.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Current Coverage") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- Items inspected in the explorer payload: $totalItems.") | Out-Null
$docLines.Add("- Items with object-level lineage today: $withObjectLevel.") | Out-Null
$docLines.Add("- Items without object-level lineage today: $withoutObjectLevel.") | Out-Null
$docLines.Add("- Unique source objects currently indexed: $uniqueObjects.") | Out-Null
$docLines.Add("- Object references currently indexed: $objectReferences.") | Out-Null
$docLines.Add("- Exact table/view/stored-procedure/file/query references: $exactReferences.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Coverage By Item Type") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("| Item type | Items | With sources | With objects | Without objects | Object refs | Exact refs | Ambiguous refs |") | Out-Null
$docLines.Add("|---|---:|---:|---:|---:|---:|---:|---:|") | Out-Null
foreach ($row in ($coverageSummaryRows | Sort-Object item_type)) {
    $docLines.Add("| $($row.item_type) | $($row.item_count) | $($row.with_sources) | $($row.with_object_level_lineage) | $($row.without_object_level_lineage) | $($row.object_references) | $($row.exact_object_references) | $($row.ambiguous_object_references) |") | Out-Null
}
$docLines.Add("") | Out-Null
$docLines.Add("## Outputs") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- ${OutputImpactPath}: one row per object-to-item impact edge.") | Out-Null
$docLines.Add("- ${OutputImpactSummaryPath}: one row per source object with affected item counts and samples.") | Out-Null
$docLines.Add("- ${OutputCoveragePath}: one row per item showing whether object-level lineage is present.") | Out-Null
$docLines.Add("- ${OutputCoverageSummaryPath}: item-type coverage totals.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Remaining Gaps") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("1. Semantic models: TMDL extraction is complete for all accessible models. Remaining missing rows are models whose definition export is denied or items with source-only evidence.") | Out-Null
$docLines.Add("2. Notebooks: read-only definition extraction is complete for accessible notebook definitions. Remaining gaps are notebooks with no parseable object candidates or definition conversion/access failures.") | Out-Null
$docLines.Add("3. CopyJobs: read-only definition extraction is complete for accessible CopyJob definitions. Remaining gaps are CopyJobs with no parseable object candidates.") | Out-Null
$docLines.Add("4. DataPipelines: pipeline object-level source/write lineage still needs a later focused extraction from pipeline activities and nested item calls.") | Out-Null
$docLines.Add('5. Exact object types: resolve table_or_view and native_query_object rows through SQL/Fabric metadata or owner evidence, then record approved types in index/source_object_type_overrides.csv.') | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Safety") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("This script is local-only. It reads the generated explorer JSON and writes CSV/documentation outputs. It does not query or modify Fabric.") | Out-Null
$docLines | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "Object impact index built."
Write-Host "Unique objects: $uniqueObjects"
Write-Host "Object impact rows: $objectReferences"
Write-Host "Items with object-level lineage: $withObjectLevel / $totalItems"
Write-Host "Output: $OutputImpactPath"
