# Phase 29 - D4 package: the cleanup-plan category for source objects
# whose exact type (table/view/stored_procedure/etc.) is still unresolved
# after Phase 15/20 -- packages them into a source/impact queue plus a
# manual confirmation template. Purely local.
# Writes: $OutputSourceQueuePath, $OutputImpactQueuePath, $OutputSummaryPath,
# $OutputTemplatePath, $OutputReadonlyTargetsPath, $OutputDocPath.
param(
    [string]$SourceTypeQueuePath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_resolution_queue.csv"),
    [string]$ObjectReadWriteClassificationPath = (Join-Path $PSScriptRoot "../../analysis/object_read_write_classification.csv"),
    [string]$MetadataGapsPath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_metadata_gaps.csv"),
    [string]$MetadataEvidencePath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_metadata_evidence.csv"),
    [string]$OutputSourceQueuePath = (Join-Path $PSScriptRoot "../../analysis/d4_exact_object_type_source_queue.csv"),
    [string]$OutputImpactQueuePath = (Join-Path $PSScriptRoot "../../analysis/d4_exact_object_type_impact_queue.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d4_exact_object_type_summary.csv"),
    [string]$OutputTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d4_object_type_confirmation_template.csv"),
    [string]$OutputReadonlyTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d4_readonly_object_type_targets.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/26_d4_exact_object_type_confirmation.md")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

function Import-OptionalCsv {
    param([string]$Path)
    if (Test-Path $Path) { return @(Import-Csv -Path $Path) }
    return @()
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

function Convert-ToInt {
    param([object]$Value)
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    try { return [int][double]$Value } catch { return 0 }
}

function Limit-Text {
    param([string]$Text, [int]$MaxLength = 700)
    if (-not $Text) { return "" }
    $clean = ($Text -replace "\s+", " ").Trim()
    if ($clean.Length -le $MaxLength) { return $clean }
    return $clean.Substring(0, $MaxLength - 3) + "..."
}

function Normalize-Key {
    param([string]$Value)
    if (-not $Value) { return "" }
    return ($Value.ToLowerInvariant() -replace "\s+", " ").Trim()
}

function Get-SourceKey {
    param([object]$Object)
    $sourceType = Normalize-Key -Value (Get-FieldValue -Object $Object -Names @("source_type"))
    $sourceServer = Normalize-Key -Value (Get-FieldValue -Object $Object -Names @("source_server"))
    $sourceDatabase = Normalize-Key -Value (Get-FieldValue -Object $Object -Names @("source_database"))
    $schemaName = Normalize-Key -Value (Get-FieldValue -Object $Object -Names @("schema_name"))
    $objectName = Normalize-Key -Value (Get-FieldValue -Object $Object -Names @("object_name"))
    $rawObjectType = Normalize-Key -Value (Get-FieldValue -Object $Object -Names @("raw_object_type", "object_type"))
    return @($sourceType, $sourceServer, $sourceDatabase, $schemaName, $objectName, $rawObjectType) -join "|"
}

function Get-PriorityBand {
    param([int]$PriorityScore)
    if ($PriorityScore -ge 300) { return "critical" }
    if ($PriorityScore -ge 200) { return "high" }
    if ($PriorityScore -ge 100) { return "medium" }
    return "low"
}

function Get-RecommendedMethod {
    param([string]$RawObjectType, [string]$SourceType, [string]$SourceServer, [string]$SourceDatabase)
    $hasMetadataTarget = [bool]($SourceServer -and $SourceDatabase)
    if ($RawObjectType -eq "native_query_object") {
        return "Review the native query and confirm whether the referenced object is a table, view, stored_procedure, file, shortcut, or query."
    }
    if ($hasMetadataTarget) {
        return "Use read-only SQL/Fabric metadata such as sys.objects, INFORMATION_SCHEMA, lakehouse metadata, or an owner-approved catalog to resolve exact object type."
    }
    return "Metadata target is incomplete; use Azure DevOps, SharePoint, OneLake, model/query definition, or owner-approved catalog evidence to resolve exact object type."
}

function Get-ReadonlyMethod {
    param([string]$RawObjectType, [string]$SourceType, [string]$SourceServer, [string]$SourceDatabase)
    if ($SourceServer -and $SourceDatabase) {
        return "Read metadata for server/database/schema/object and verify exact type without changing the source system."
    }
    if ($RawObjectType -eq "native_query_object") {
        return "Read the native query text or generated parser evidence and verify what object kind the reference actually points to."
    }
    return "Use local definitions or owner-approved catalog evidence because server/database metadata target is missing."
}

function Escape-MdCell {
    param([string]$Value)
    if (-not $Value) { return "" }
    return (($Value -replace "\|", "/") -replace "`r?`n", " ").Trim()
}

foreach ($path in @($SourceTypeQueuePath, $ObjectReadWriteClassificationPath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$sourceTypeRows = @(Import-Csv -Path $SourceTypeQueuePath)
$readWriteRows = @(Import-Csv -Path $ObjectReadWriteClassificationPath)
$metadataGapRows = Import-OptionalCsv -Path $MetadataGapsPath
$metadataEvidenceRows = Import-OptionalCsv -Path $MetadataEvidencePath

$pendingSourceRows = @($sourceTypeRows | Where-Object { $_.status -eq "needs_metadata_review" })
$typeConfirmationRows = @($readWriteRows | Where-Object { $_.scheduling_readiness -eq "needs_object_type_confirmation" })

$metadataGapByKey = @{}
foreach ($row in $metadataGapRows) {
    $key = Get-SourceKey -Object $row
    if ($key -and -not $metadataGapByKey.ContainsKey($key)) { $metadataGapByKey[$key] = $row }
}

$metadataEvidenceByKey = @{}
foreach ($row in $metadataEvidenceRows) {
    $key = Get-SourceKey -Object $row
    if ($key -and -not $metadataEvidenceByKey.ContainsKey($key)) { $metadataEvidenceByKey[$key] = $row }
}

$sourceRowsByKey = @{}
foreach ($row in $pendingSourceRows) {
    $key = Get-SourceKey -Object $row
    if ($key -and -not $sourceRowsByKey.ContainsKey($key)) { $sourceRowsByKey[$key] = $row }
}

$impactRowsByKey = @{}
foreach ($row in $typeConfirmationRows) {
    $key = Get-SourceKey -Object $row
    if (-not $key) { continue }
    if (-not $impactRowsByKey.ContainsKey($key)) {
        $impactRowsByKey[$key] = [System.Collections.Generic.List[object]]::new()
    }
    $impactRowsByKey[$key].Add($row) | Out-Null
}

$sourceQueueRows = [System.Collections.Generic.List[object]]::new()
$templateRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()
$sourceIdByKey = @{}
$sequence = 0

foreach ($row in ($pendingSourceRows | Sort-Object @{ Expression = { Convert-ToInt (Get-FieldValue -Object $_ -Names @("priority_score")) }; Descending = $true }, source_type, source_database, schema_name, object_name)) {
    $sequence += 1
    $sourceId = "D4S{0:D5}" -f $sequence
    $key = Get-SourceKey -Object $row
    $sourceIdByKey[$key] = $sourceId
    $gap = $null
    if ($metadataGapByKey.ContainsKey($key)) { $gap = $metadataGapByKey[$key] }
    $evidence = $null
    if ($metadataEvidenceByKey.ContainsKey($key)) { $evidence = $metadataEvidenceByKey[$key] }
    $impactRows = @()
    if ($impactRowsByKey.ContainsKey($key)) { $impactRows = @($impactRowsByKey[$key]) }

    $priorityScore = Convert-ToInt (Get-FieldValue -Object $row -Names @("priority_score"))
    $rawObjectType = Get-FieldValue -Object $row -Names @("raw_object_type")
    $sourceType = Get-FieldValue -Object $row -Names @("source_type")
    $sourceServer = Get-FieldValue -Object $row -Names @("source_server")
    $sourceDatabase = Get-FieldValue -Object $row -Names @("source_database")
    $schemaName = Get-FieldValue -Object $row -Names @("schema_name")
    $objectName = Get-FieldValue -Object $row -Names @("object_name")
    $operationTypes = ((@($impactRows | Group-Object operation_type | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join "; ")
    $itemTypes = ((@($impactRows | Group-Object item_type | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join "; ")
    $sampleItems = ((@($impactRows | Select-Object -First 10 | ForEach-Object { Get-FieldValue -Object $_ -Names @("item_qualified_name") })) -join "; ")
    $recommendedMethod = Get-RecommendedMethod -RawObjectType $rawObjectType -SourceType $sourceType -SourceServer $sourceServer -SourceDatabase $sourceDatabase
    $readonlyMethod = Get-ReadonlyMethod -RawObjectType $rawObjectType -SourceType $sourceType -SourceServer $sourceServer -SourceDatabase $sourceDatabase

    $sourceQueueRows.Add([pscustomobject]@{
        source_id = $sourceId
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        status = Get-FieldValue -Object $row -Names @("status")
        source_type = $sourceType
        source_server = $sourceServer
        source_database = $sourceDatabase
        schema_name = $schemaName
        object_name = $objectName
        raw_object_type = $rawObjectType
        current_resolved_object_type = Get-FieldValue -Object $row -Names @("resolved_object_type")
        resolver_source = Get-FieldValue -Object $row -Names @("resolver_source")
        resolver_confidence = Get-FieldValue -Object $row -Names @("resolver_confidence")
        semantic_model_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("semantic_model_count"))
        affected_item_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("affected_item_count"))
        affected_item_types = Get-FieldValue -Object $row -Names @("affected_item_types")
        candidate_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("candidate_count"))
        impact_row_count = $impactRows.Count
        operation_types = $operationTypes
        impact_item_types = $itemTypes
        workspaces = Limit-Text -Text (Get-FieldValue -Object $row -Names @("workspaces")) -MaxLength 1200
        affected_items_sample = Limit-Text -Text $sampleItems -MaxLength 1200
        confidence = Get-FieldValue -Object $row -Names @("confidence")
        metadata_gap_reason = Get-FieldValue -Object $gap -Names @("gap_reason")
        metadata_error = Limit-Text -Text (Get-FieldValue -Object $gap -Names @("error")) -MaxLength 900
        existing_metadata_evidence_type = Get-FieldValue -Object $evidence -Names @("object_type")
        existing_metadata_evidence_confidence = Get-FieldValue -Object $evidence -Names @("confidence")
        next_step = Limit-Text -Text (Get-FieldValue -Object $row -Names @("next_step")) -MaxLength 700
        recommended_method = $recommendedMethod
        readonly_method = $readonlyMethod
        d4_gate_to_close = "Resolve this source object to table, view, stored_procedure, file, shortcut, query, or explicitly blocked with evidence."
    }) | Out-Null

    $templateRows.Add([pscustomobject]@{
        source_id = $sourceId
        source_type = $sourceType
        source_server = $sourceServer
        source_database = $sourceDatabase
        schema_name = $schemaName
        object_name = $objectName
        raw_object_type = $rawObjectType
        current_resolved_object_type = Get-FieldValue -Object $row -Names @("resolved_object_type")
        proposed_status = ""
        confirmed_object_type = ""
        confirmation_source = ""
        confirmation_evidence = ""
        reviewer = ""
        reviewed_at = ""
        notes = "D4 template row. Set proposed_status to resolved or blocked before applying any future object type update."
    }) | Out-Null

    $readonlyRows.Add([pscustomobject]@{
        source_id = $sourceId
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        source_type = $sourceType
        source_server = $sourceServer
        source_database = $sourceDatabase
        schema_name = $schemaName
        object_name = $objectName
        raw_object_type = $rawObjectType
        readonly_method = $readonlyMethod
        suggested_readonly_command = "pwsh -NoLogo -File backend/scripts/20_extract_source_object_type_metadata.ps1 -AzCommand az -TrustServerCertificate"
        metadata_gap_reason = Get-FieldValue -Object $gap -Names @("gap_reason")
        template_path = $OutputTemplatePath
        notes = "Read-only/manual target. Do not query external metadata or apply overrides without human approval."
    }) | Out-Null
}

$impactQueueRows = [System.Collections.Generic.List[object]]::new()
$impactSequence = 0
foreach ($row in $typeConfirmationRows) {
    $impactSequence += 1
    $key = Get-SourceKey -Object $row
    $sourceId = ""
    if ($key -and $sourceIdByKey.ContainsKey($key)) { $sourceId = $sourceIdByKey[$key] }
    $sourceQueueRow = $null
    if ($key -and $sourceRowsByKey.ContainsKey($key)) { $sourceQueueRow = $sourceRowsByKey[$key] }
    $priorityScore = Convert-ToInt (Get-FieldValue -Object $sourceQueueRow -Names @("priority_score"))
    if ($priorityScore -eq 0) { $priorityScore = Convert-ToInt (Get-FieldValue -Object $row -Names @("hardening_priority_score")) }
    if ($priorityScore -eq 0) { $priorityScore = 70 }

    $impactQueueRows.Add([pscustomobject]@{
        impact_id = ("D4I{0:D6}" -f $impactSequence)
        source_id = $sourceId
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        item_type = Get-FieldValue -Object $row -Names @("item_type")
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        item_qualified_name = Get-FieldValue -Object $row -Names @("item_qualified_name")
        source_type = Get-FieldValue -Object $row -Names @("source_type")
        source_server = Get-FieldValue -Object $row -Names @("source_server")
        source_database = Get-FieldValue -Object $row -Names @("source_database")
        schema_name = Get-FieldValue -Object $row -Names @("schema_name")
        object_name = Get-FieldValue -Object $row -Names @("object_name")
        object_display_name = Get-FieldValue -Object $row -Names @("object_display_name")
        object_key = Get-FieldValue -Object $row -Names @("object_key")
        current_object_type = Get-FieldValue -Object $row -Names @("object_type")
        raw_object_type = Get-FieldValue -Object $row -Names @("raw_object_type")
        object_type_status = Get-FieldValue -Object $row -Names @("object_type_status")
        object_type_confidence = Get-FieldValue -Object $row -Names @("object_type_confidence")
        operation_type = Get-FieldValue -Object $row -Names @("operation_type")
        lineage_confidence = Get-FieldValue -Object $row -Names @("lineage_confidence")
        scheduling_readiness = Get-FieldValue -Object $row -Names @("scheduling_readiness")
        hardening_issue_types = Get-FieldValue -Object $row -Names @("hardening_issue_types")
        preferred_confirmation_sources = Get-FieldValue -Object $row -Names @("preferred_confirmation_sources")
        evidence = Limit-Text -Text (Get-FieldValue -Object $row -Names @("evidence")) -MaxLength 1000
        d4_gate_to_close = "Resolve source_id exact object type or explicitly block it with evidence."
    }) | Out-Null
}

$sourceColumns = @(
    "source_id", "priority_score", "priority_band", "status", "source_type", "source_server", "source_database",
    "schema_name", "object_name", "raw_object_type", "current_resolved_object_type", "resolver_source",
    "resolver_confidence", "semantic_model_count", "affected_item_count", "affected_item_types", "candidate_count",
    "impact_row_count", "operation_types", "impact_item_types", "workspaces", "affected_items_sample", "confidence",
    "metadata_gap_reason", "metadata_error", "existing_metadata_evidence_type", "existing_metadata_evidence_confidence",
    "next_step", "recommended_method", "readonly_method", "d4_gate_to_close"
)
$impactColumns = @(
    "impact_id", "source_id", "priority_score", "priority_band", "workspace_name", "item_type", "item_name",
    "item_qualified_name", "source_type", "source_server", "source_database", "schema_name", "object_name",
    "object_display_name", "object_key", "current_object_type", "raw_object_type", "object_type_status",
    "object_type_confidence", "operation_type", "lineage_confidence", "scheduling_readiness", "hardening_issue_types",
    "preferred_confirmation_sources", "evidence", "d4_gate_to_close"
)
$templateColumns = @("source_id", "source_type", "source_server", "source_database", "schema_name", "object_name", "raw_object_type", "current_resolved_object_type", "proposed_status", "confirmed_object_type", "confirmation_source", "confirmation_evidence", "reviewer", "reviewed_at", "notes")
$readonlyColumns = @("source_id", "priority_score", "priority_band", "source_type", "source_server", "source_database", "schema_name", "object_name", "raw_object_type", "readonly_method", "suggested_readonly_command", "metadata_gap_reason", "template_path", "notes")

$sourceSorted = @($sourceQueueRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, source_type, source_database, schema_name, object_name)
$impactSorted = @($impactQueueRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, source_id, item_qualified_name)
$templateSorted = @($templateRows | Sort-Object source_id)
$readonlySorted = @($readonlyRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, source_id)

Export-Rows -Rows $sourceSorted -Columns $sourceColumns -Path $OutputSourceQueuePath
Export-Rows -Rows $impactSorted -Columns $impactColumns -Path $OutputImpactQueuePath
Export-Rows -Rows $templateSorted -Columns $templateColumns -Path $OutputTemplatePath
Export-Rows -Rows $readonlySorted -Columns $readonlyColumns -Path $OutputReadonlyTargetsPath

$summaryRows = [System.Collections.Generic.List[object]]::new()
function Add-SummaryRow {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [string]$SummaryScope,
        [string]$GroupKey,
        [object[]]$GroupRows,
        [string]$Notes
    )
    $count = $GroupRows.Count
    $highCount = @($GroupRows | Where-Object { $_.priority_band -in @("critical", "high") }).Count
    $maxPriority = 0
    if ($count -gt 0) { $maxPriority = (@($GroupRows | ForEach-Object { [int]$_.priority_score } | Measure-Object -Maximum).Maximum) }
    $Rows.Add([pscustomobject]@{
        summary_scope = $SummaryScope
        group_key = $GroupKey
        row_count = $count
        high_or_critical_count = $highCount
        max_priority_score = $maxPriority
        notes = $Notes
    }) | Out-Null
}

Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D4 source objects" -GroupRows @($sourceQueueRows) -Notes "Source objects from analysis/source_object_type_resolution_queue.csv pending exact type."
Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D4 impacted object rows" -GroupRows @($impactQueueRows) -Notes "Object read/write rows needing exact object type confirmation."
foreach ($group in ($sourceQueueRows | Group-Object raw_object_type | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "raw_object_type" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "Pending source objects by ambiguous/raw object type."
}
foreach ($group in ($sourceQueueRows | Group-Object source_type | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "source_type" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "Pending source objects by source type."
}
foreach ($group in ($sourceQueueRows | Group-Object metadata_gap_reason | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "metadata_gap_reason" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "Metadata extraction gap reason for pending source objects."
}
foreach ($group in ($impactQueueRows | Group-Object item_type | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "impact_item_type" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "Impacted rows grouped by item type."
}
foreach ($group in ($sourceQueueRows | Group-Object priority_band | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "priority_band_sources" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "Pending source objects grouped by priority band."
}

Export-Rows -Rows @($summaryRows) -Columns @("summary_scope", "group_key", "row_count", "high_or_critical_count", "max_priority_score", "notes") -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$generatedAt = (Get-Date).ToString("s")
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D4 Exact Object-Type Confirmation Package") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated: $generatedAt") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('D4 focuses on source objects whose exact type is still ambiguous, such as `table_or_view` or `native_query_object`. The package is local-only and does not modify Fabric, Power BI, SQL, OneLake, schedules, deployment pipelines, repositories, object type overrides, or evidence indexes.') | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Current Baseline") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- D4 pending source objects: $($sourceQueueRows.Count)") | Out-Null
$doc.Add("- D4 impacted object rows: $($impactQueueRows.Count)") | Out-Null
$doc.Add("- Confirmation template rows: $($templateRows.Count)") | Out-Null
$doc.Add("- Read-only/manual target rows: $($readonlyRows.Count)") | Out-Null
$doc.Add("- Existing read-only metadata evidence rows: $($metadataEvidenceRows.Count)") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Raw Object-Type Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($sourceQueueRows | Group-Object raw_object_type | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Metadata Gap Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($sourceQueueRows | Group-Object metadata_gap_reason | Sort-Object Count -Descending)) {
    $name = if ($group.Name) { $group.Name } else { "no_gap_record" }
    $doc.Add("- ${name}: $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Top Priority Source Objects") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("| Priority | Source | Database | Schema | Object | Raw type | Impact rows | Metadata gap |") | Out-Null
$doc.Add("| --- | --- | --- | --- | --- | --- | --- | --- |") | Out-Null
foreach ($row in ($sourceSorted | Select-Object -First 15)) {
    $doc.Add("| $($row.priority_score) | $(Escape-MdCell $row.source_type) | $(Escape-MdCell $row.source_database) | $(Escape-MdCell $row.schema_name) | $(Escape-MdCell $row.object_name) | $(Escape-MdCell $row.raw_object_type) | $($row.impact_row_count) | $(Escape-MdCell $row.metadata_gap_reason) |") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- analysis/d4_exact_object_type_source_queue.csv") | Out-Null
$doc.Add("- analysis/d4_exact_object_type_impact_queue.csv") | Out-Null
$doc.Add("- analysis/d4_exact_object_type_summary.csv") | Out-Null
$doc.Add("- analysis/d4_object_type_confirmation_template.csv") | Out-Null
$doc.Add("- analysis/d4_readonly_object_type_targets.csv") | Out-Null
$doc.Add("- docs/26_d4_exact_object_type_confirmation.md") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## How To Close D4 Rows") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('1. Work `analysis/d4_exact_object_type_source_queue.csv` in priority order.') | Out-Null
$doc.Add('2. Use `analysis/d4_object_type_confirmation_template.csv` to mark each source object as resolved or blocked.') | Out-Null
$doc.Add("3. Confirm exact type from read-only SQL/Fabric metadata, Azure DevOps, SharePoint, OneLake, model/query definition, or owner-approved catalog evidence.") | Out-Null
$doc.Add('4. Allowed resolved types should be explicit, such as `table`, `view`, `stored_procedure`, `file`, `shortcut`, or `query`.') | Out-Null
$doc.Add("5. Only after human approval should confirmed evidence be copied into the appropriate override/evidence source and rebuilt through Phases B, C, and D.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Suggested Read-Only Metadata Command") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('```powershell') | Out-Null
$doc.Add("pwsh -NoLogo -File backend/scripts/20_extract_source_object_type_metadata.ps1 -AzCommand az -TrustServerCertificate") | Out-Null
$doc.Add('```') | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Gate") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D4 is closed only when high-priority ambiguous source objects are resolved to exact object types or explicitly blocked with evidence. This package is evidence preparation and does not approve orchestration rules.") | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D4 exact object-type confirmation package completed."
Write-Host "Pending source objects: $($sourceQueueRows.Count)"
Write-Host "Impacted object rows: $($impactQueueRows.Count)"
Write-Host "Output: $OutputSourceQueuePath"
