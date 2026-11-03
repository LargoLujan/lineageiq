# Phase 28 - D3 package: the cleanup-plan category for object-level lineage
# candidates still resting on "likely" evidence -- packages them into an
# item/object queue plus a manual confirmation template. Purely local.
# Writes: $OutputItemQueuePath, $OutputObjectQueuePath, $OutputSummaryPath,
# $OutputTemplatePath, $OutputReadonlyTargetsPath, $OutputDocPath.
param(
    [string]$ObjectReadWriteClassificationPath = (Join-Path $PSScriptRoot "../../analysis/object_read_write_classification.csv"),
    [string]$CleanupQueuePath = (Join-Path $PSScriptRoot "../../analysis/likely_conflict_cleanup_queue.csv"),
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$OrchestrationV2PlanPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_plan.csv"),
    [string]$OutputItemQueuePath = (Join-Path $PSScriptRoot "../../analysis/d3_likely_object_lineage_item_queue.csv"),
    [string]$OutputObjectQueuePath = (Join-Path $PSScriptRoot "../../analysis/d3_likely_object_lineage_object_queue.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d3_likely_object_lineage_summary.csv"),
    [string]$OutputTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d3_object_lineage_confirmation_template.csv"),
    [string]$OutputReadonlyTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d3_readonly_object_lineage_targets.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/25_d3_likely_object_lineage_confirmation.md")
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

function Set-FirstMapValue {
    param(
        [hashtable]$Map,
        [string]$Key,
        [object]$Value
    )
    $normalized = Normalize-Key -Value $Key
    if ($normalized -and -not $Map.ContainsKey($normalized)) {
        $Map[$normalized] = $Value
    }
}

function Get-MapValue {
    param(
        [hashtable]$Map,
        [string]$Key
    )
    $normalized = Normalize-Key -Value $Key
    if ($normalized -and $Map.ContainsKey($normalized)) {
        return $Map[$normalized]
    }
    return $null
}

function Get-PriorityBand {
    param([int]$PriorityScore)
    if ($PriorityScore -ge 1000) { return "critical" }
    if ($PriorityScore -ge 250) { return "high" }
    if ($PriorityScore -ge 100) { return "medium" }
    return "low"
}

function Get-RecommendedMethod {
    param([string]$ItemType, [string]$OperationType, [string]$ObjectType)
    $operation = if ($OperationType) { $OperationType } else { "operation" }
    switch ($ItemType) {
        "SemanticModel" { return "Confirm the semantic model source object from TMDL, Power Query/M, partitions, model expressions, or owner-approved source mapping." }
        "Notebook" { return "Confirm the notebook $operation reference from code, SQL cells, Spark read/write calls, default lakehouse metadata, Azure DevOps, or owner evidence." }
        "CopyJob" { return "Confirm the CopyJob $operation reference from source/sink mapping and connection metadata." }
        "DataPipeline" { return "Confirm the pipeline $operation reference from activities, invoked items, inherited lineage, copy source/sink mappings, and owner evidence." }
        default { return "Confirm object lineage from item definition, code, metadata, or owner-approved evidence." }
    }
}

function Get-ReadonlyMethod {
    param([string]$ItemType, [string]$OperationType, [string]$ObjectType)
    $objectTypeHint = if ($ObjectType) { $ObjectType } else { "object" }
    switch ($ItemType) {
        "SemanticModel" { return "Read model/TMDL/Power Query metadata and verify the exact source $objectTypeHint and usage." }
        "Notebook" { return "Read notebook code and verify whether this $objectTypeHint is actually read, written, or executed." }
        "CopyJob" { return "Read CopyJob definition and verify source/sink object mapping." }
        "DataPipeline" { return "Read pipeline activities and invoked item lineage, then verify direct or inherited object usage." }
        default { return "Read item metadata and verify exact object usage." }
    }
}

function Escape-MdCell {
    param([string]$Value)
    if (-not $Value) { return "" }
    return (($Value -replace "\|", "/") -replace "`r?`n", " ").Trim()
}

foreach ($path in @($ObjectReadWriteClassificationPath, $CleanupQueuePath, $ItemsPath, $OrchestrationV2PlanPath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$readWriteRows = @(Import-Csv -Path $ObjectReadWriteClassificationPath)
$cleanupRows = @(Import-Csv -Path $CleanupQueuePath)
$itemRows = @(Import-Csv -Path $ItemsPath)
$v2PlanRows = @(Import-Csv -Path $OrchestrationV2PlanPath)

$itemsByQualifiedName = @{}
foreach ($row in $itemRows) {
    Set-FirstMapValue -Map $itemsByQualifiedName -Key (Get-FieldValue -Object $row -Names @("qualified_name", "item_qualified_name")) -Value $row
}

$v2ByQualifiedName = @{}
foreach ($row in $v2PlanRows) {
    Set-FirstMapValue -Map $v2ByQualifiedName -Key (Get-FieldValue -Object $row -Names @("qualified_name", "item_qualified_name")) -Value $row
}

$d3CleanupRows = @($cleanupRows | Where-Object { $_.phase_id -eq "D3" })
$d3CleanupByItem = @{}
foreach ($row in $d3CleanupRows) {
    Set-FirstMapValue -Map $d3CleanupByItem -Key (Get-FieldValue -Object $row -Names @("item_qualified_name", "qualified_name")) -Value $row
}

$needsConfirmationRows = @($readWriteRows | Where-Object { $_.scheduling_readiness -eq "needs_lineage_confirmation" })
$objectRowsByItem = @{}
foreach ($row in $needsConfirmationRows) {
    $itemKey = Normalize-Key -Value (Get-FieldValue -Object $row -Names @("item_qualified_name"))
    if (-not $itemKey) { continue }
    if (-not $objectRowsByItem.ContainsKey($itemKey)) {
        $objectRowsByItem[$itemKey] = [System.Collections.Generic.List[object]]::new()
    }
    $objectRowsByItem[$itemKey].Add($row) | Out-Null
}

$objectQueueRows = [System.Collections.Generic.List[object]]::new()
$templateRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()
$sequence = 0

foreach ($row in $needsConfirmationRows) {
    $sequence += 1
    $qualifiedName = Get-FieldValue -Object $row -Names @("item_qualified_name")
    $item = Get-MapValue -Map $itemsByQualifiedName -Key $qualifiedName
    $cleanup = Get-MapValue -Map $d3CleanupByItem -Key $qualifiedName
    $v2 = Get-MapValue -Map $v2ByQualifiedName -Key $qualifiedName

    $basePriority = Convert-ToInt (Get-FieldValue -Object $cleanup -Names @("priority_score"))
    if ($basePriority -eq 0) { $basePriority = Convert-ToInt (Get-FieldValue -Object $row -Names @("hardening_priority_score")) }
    if ($basePriority -eq 0) { $basePriority = 70 }

    $operationType = Get-FieldValue -Object $row -Names @("operation_type")
    $priorityScore = $basePriority
    if ($operationType -eq "write") { $priorityScore += 10 }
    elseif ($operationType -eq "execute") { $priorityScore += 15 }
    if ((Get-FieldValue -Object $item -Names @("workspace_environment")) -eq "PRO") { $priorityScore += 5 }

    $itemType = Get-FieldValue -Object $row -Names @("item_type")
    $objectType = Get-FieldValue -Object $row -Names @("object_type")
    $rowId = "D3O{0:D6}" -f $sequence
    $recommendedMethod = Get-RecommendedMethod -ItemType $itemType -OperationType $operationType -ObjectType $objectType
    $readonlyMethod = Get-ReadonlyMethod -ItemType $itemType -OperationType $operationType -ObjectType $objectType

    $objectQueueRows.Add([pscustomobject]@{
        row_id = $rowId
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $item -Names @("workspace_environment")
        item_type = $itemType
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        item_qualified_name = $qualifiedName
        technical_id = Get-FieldValue -Object $item -Names @("technical_id")
        source_type = Get-FieldValue -Object $row -Names @("source_type")
        source_server = Get-FieldValue -Object $row -Names @("source_server")
        source_database = Get-FieldValue -Object $row -Names @("source_database")
        schema_name = Get-FieldValue -Object $row -Names @("schema_name")
        object_name = Get-FieldValue -Object $row -Names @("object_name")
        object_display_name = Get-FieldValue -Object $row -Names @("object_display_name")
        object_key = Get-FieldValue -Object $row -Names @("object_key")
        object_type = $objectType
        raw_object_type = Get-FieldValue -Object $row -Names @("raw_object_type")
        object_type_status = Get-FieldValue -Object $row -Names @("object_type_status")
        object_type_confidence = Get-FieldValue -Object $row -Names @("object_type_confidence")
        source_label = Get-FieldValue -Object $row -Names @("source_label")
        source_qualified_name = Get-FieldValue -Object $row -Names @("source_qualified_name")
        semantic_table = Get-FieldValue -Object $row -Names @("semantic_table")
        usage_type = Get-FieldValue -Object $row -Names @("usage_type")
        usage_type_normalized = Get-FieldValue -Object $row -Names @("usage_type_normalized")
        operation_type = $operationType
        lineage_confidence = Get-FieldValue -Object $row -Names @("lineage_confidence")
        hardening_status = Get-FieldValue -Object $row -Names @("hardening_status")
        hardening_issue_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("hardening_issue_count"))
        hardening_issue_types = Get-FieldValue -Object $row -Names @("hardening_issue_types")
        preferred_confirmation_sources = Get-FieldValue -Object $row -Names @("preferred_confirmation_sources")
        hardening_next_actions = Limit-Text -Text (Get-FieldValue -Object $row -Names @("hardening_next_actions")) -MaxLength 900
        orchestration_risk_flags = Get-FieldValue -Object $row -Names @("orchestration_risk_flags")
        orchestration_parallel_readiness = Get-FieldValue -Object $row -Names @("orchestration_parallel_readiness")
        scheduling_readiness = Get-FieldValue -Object $row -Names @("scheduling_readiness")
        v2_status = Get-FieldValue -Object $v2 -Names @("v2_status")
        v2_recommended_next_action = Limit-Text -Text (Get-FieldValue -Object $v2 -Names @("v2_recommended_next_action")) -MaxLength 700
        evidence = Limit-Text -Text (Get-FieldValue -Object $row -Names @("evidence")) -MaxLength 1200
        recommended_method = $recommendedMethod
        readonly_method = $readonlyMethod
        d3_gate_to_close = "Confirm, reject, or explicitly block this object-level read/write/execute relationship with evidence."
    }) | Out-Null

    $templateRows.Add([pscustomobject]@{
        row_id = $rowId
        item_qualified_name = $qualifiedName
        item_type = $itemType
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        current_operation_type = $operationType
        current_source_type = Get-FieldValue -Object $row -Names @("source_type")
        current_source_server = Get-FieldValue -Object $row -Names @("source_server")
        current_source_database = Get-FieldValue -Object $row -Names @("source_database")
        current_schema_name = Get-FieldValue -Object $row -Names @("schema_name")
        current_object_name = Get-FieldValue -Object $row -Names @("object_name")
        current_object_display_name = Get-FieldValue -Object $row -Names @("object_display_name")
        current_object_type = $objectType
        current_lineage_confidence = Get-FieldValue -Object $row -Names @("lineage_confidence")
        current_evidence = Limit-Text -Text (Get-FieldValue -Object $row -Names @("evidence")) -MaxLength 1000
        proposed_status = ""
        confirmed_operation_type = $operationType
        confirmed_source_type = ""
        confirmed_source_server = ""
        confirmed_source_database = ""
        confirmed_schema_name = ""
        confirmed_object_name = ""
        confirmed_object_type = ""
        confirmation_source = ""
        confirmation_evidence = ""
        reviewer = ""
        reviewed_at = ""
        notes = "D3 template row. Set proposed_status to confirmed, rejected, or blocked before applying any future evidence update."
    }) | Out-Null

    $readonlyRows.Add([pscustomobject]@{
        row_id = $rowId
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        item_type = $itemType
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        item_qualified_name = $qualifiedName
        operation_type = $operationType
        object_display_name = Get-FieldValue -Object $row -Names @("object_display_name")
        object_type = $objectType
        lineage_confidence = Get-FieldValue -Object $row -Names @("lineage_confidence")
        readonly_method = $readonlyMethod
        preferred_confirmation_sources = Get-FieldValue -Object $row -Names @("preferred_confirmation_sources")
        template_path = $OutputTemplatePath
        notes = "Read-only/manual confirmation target. Do not modify Fabric or evidence indexes from this package alone."
    }) | Out-Null
}

$itemQueueRows = [System.Collections.Generic.List[object]]::new()
foreach ($cleanup in $d3CleanupRows) {
    $qualifiedName = Get-FieldValue -Object $cleanup -Names @("item_qualified_name", "qualified_name")
    $item = Get-MapValue -Map $itemsByQualifiedName -Key $qualifiedName
    $v2 = Get-MapValue -Map $v2ByQualifiedName -Key $qualifiedName
    $itemKey = Normalize-Key -Value $qualifiedName
    $objectRows = @()
    if ($itemKey -and $objectRowsByItem.ContainsKey($itemKey)) {
        $objectRows = @($objectRowsByItem[$itemKey])
    }

    $sampleObjects = @($objectRows | Select-Object -First 10 | ForEach-Object {
        (Get-FieldValue -Object $_ -Names @("operation_type")) + ": " + (Get-FieldValue -Object $_ -Names @("object_display_name"))
    })
    $operationTypes = ((@($objectRows | Group-Object operation_type | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join "; ")
    $sourceTypes = ((@($objectRows | Group-Object source_type | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join "; ")
    $objectTypeStatuses = ((@($objectRows | Group-Object object_type_status | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join "; ")

    $itemQueueRows.Add([pscustomobject]@{
        priority_score = Convert-ToInt (Get-FieldValue -Object $cleanup -Names @("priority_score"))
        priority_band = Get-PriorityBand -PriorityScore (Convert-ToInt (Get-FieldValue -Object $cleanup -Names @("priority_score")))
        workspace_name = Get-FieldValue -Object $cleanup -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $item -Names @("workspace_environment")
        item_type = Get-FieldValue -Object $cleanup -Names @("item_type")
        item_name = Get-FieldValue -Object $cleanup -Names @("item_name")
        item_qualified_name = $qualifiedName
        technical_id = Get-FieldValue -Object $item -Names @("technical_id")
        likely_object_lineage_row_count = $objectRows.Count
        blocker_count = Convert-ToInt (Get-FieldValue -Object $cleanup -Names @("blocker_count"))
        operation_types = $operationTypes
        source_types = $sourceTypes
        object_type_statuses = $objectTypeStatuses
        sample_objects = Limit-Text -Text ($sampleObjects -join "; ") -MaxLength 1200
        v2_status = Get-FieldValue -Object $v2 -Names @("v2_status")
        v2_needs_lineage_confirmation_count = Convert-ToInt (Get-FieldValue -Object $v2 -Names @("needs_lineage_confirmation_count"))
        v2_needs_object_type_confirmation_count = Convert-ToInt (Get-FieldValue -Object $v2 -Names @("needs_object_type_confirmation_count"))
        v2_recommended_next_action = Limit-Text -Text (Get-FieldValue -Object $v2 -Names @("v2_recommended_next_action")) -MaxLength 700
        recommended_method = "Confirm or reject every likely object-level read/write/execute row before this item becomes an operational sequencing rule."
        object_queue_path = $OutputObjectQueuePath
        template_path = $OutputTemplatePath
    }) | Out-Null
}

$itemColumns = @(
    "priority_score", "priority_band", "workspace_name", "workspace_environment", "item_type", "item_name",
    "item_qualified_name", "technical_id", "likely_object_lineage_row_count", "blocker_count", "operation_types",
    "source_types", "object_type_statuses", "sample_objects", "v2_status", "v2_needs_lineage_confirmation_count",
    "v2_needs_object_type_confirmation_count", "v2_recommended_next_action", "recommended_method",
    "object_queue_path", "template_path"
)

$objectColumns = @(
    "row_id", "priority_score", "priority_band", "workspace_name", "workspace_environment", "item_type",
    "item_name", "item_qualified_name", "technical_id", "source_type", "source_server", "source_database",
    "schema_name", "object_name", "object_display_name", "object_key", "object_type", "raw_object_type",
    "object_type_status", "object_type_confidence", "source_label", "source_qualified_name", "semantic_table",
    "usage_type", "usage_type_normalized", "operation_type", "lineage_confidence", "hardening_status",
    "hardening_issue_count", "hardening_issue_types", "preferred_confirmation_sources", "hardening_next_actions",
    "orchestration_risk_flags", "orchestration_parallel_readiness", "scheduling_readiness", "v2_status",
    "v2_recommended_next_action", "evidence", "recommended_method", "readonly_method", "d3_gate_to_close"
)

$templateColumns = @(
    "row_id", "item_qualified_name", "item_type", "item_name", "current_operation_type",
    "current_source_type", "current_source_server", "current_source_database", "current_schema_name",
    "current_object_name", "current_object_display_name", "current_object_type", "current_lineage_confidence",
    "current_evidence", "proposed_status", "confirmed_operation_type", "confirmed_source_type",
    "confirmed_source_server", "confirmed_source_database", "confirmed_schema_name", "confirmed_object_name",
    "confirmed_object_type", "confirmation_source", "confirmation_evidence", "reviewer", "reviewed_at", "notes"
)

$readonlyColumns = @(
    "row_id", "priority_score", "priority_band", "workspace_name", "item_type", "item_name",
    "item_qualified_name", "operation_type", "object_display_name", "object_type", "lineage_confidence",
    "readonly_method", "preferred_confirmation_sources", "template_path", "notes"
)

$itemQueueSorted = @($itemQueueRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, workspace_name, item_type, item_name)
$objectQueueSorted = @($objectQueueRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, item_qualified_name, object_display_name, operation_type)
$templateSorted = @($templateRows | Sort-Object row_id)
$readonlySorted = @($readonlyRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, row_id)

Export-Rows -Rows $itemQueueSorted -Columns $itemColumns -Path $OutputItemQueuePath
Export-Rows -Rows $objectQueueSorted -Columns $objectColumns -Path $OutputObjectQueuePath
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
    if ($count -gt 0) {
        $maxPriority = (@($GroupRows | ForEach-Object { [int]$_.priority_score } | Measure-Object -Maximum).Maximum)
    }
    $Rows.Add([pscustomobject]@{
        summary_scope = $SummaryScope
        group_key = $GroupKey
        row_count = $count
        high_or_critical_count = $highCount
        max_priority_score = $maxPriority
        notes = $Notes
    }) | Out-Null
}

Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D3 item blockers" -GroupRows @($itemQueueRows) -Notes "Items from analysis/likely_conflict_cleanup_queue.csv phase D3."
Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D3 likely object-lineage rows" -GroupRows @($objectQueueRows) -Notes "Object read/write/execute rows from analysis/object_read_write_classification.csv needing lineage confirmation."
foreach ($group in ($objectQueueRows | Group-Object item_type | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "item_type_objects" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D3 object rows grouped by item type."
}
foreach ($group in ($objectQueueRows | Group-Object operation_type | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "operation_type" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D3 object rows grouped by read/write/execute operation."
}
foreach ($group in ($objectQueueRows | Group-Object source_type | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "source_type" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D3 object rows grouped by source type."
}
foreach ($group in ($objectQueueRows | Group-Object hardening_issue_types | Sort-Object Count -Descending | Select-Object -First 12)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "hardening_issue_types" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "Most common D3 evidence blockers."
}
foreach ($group in ($objectQueueRows | Group-Object priority_band | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "priority_band_objects" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D3 object rows grouped by priority band."
}

Export-Rows -Rows @($summaryRows) -Columns @("summary_scope", "group_key", "row_count", "high_or_critical_count", "max_priority_score", "notes") -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$generatedAt = (Get-Date).ToString("s")
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D3 Likely Object-Lineage Confirmation Package") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated: $generatedAt") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D3 focuses on object-level read/write/execute rows that are currently likely and need confirmation before they can be used as orchestration rules. The package is local-only and does not modify Fabric, Power BI, SQL, OneLake, schedules, deployment pipelines, repositories, or evidence indexes.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Current Baseline") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- D3 item blocker rows: $($itemQueueRows.Count)") | Out-Null
$doc.Add("- D3 likely object-lineage rows: $($objectQueueRows.Count)") | Out-Null
$doc.Add("- Confirmation template rows: $($templateRows.Count)") | Out-Null
$doc.Add("- Read-only/manual target rows: $($readonlyRows.Count)") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Operation Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($objectQueueRows | Group-Object operation_type | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Item-Type Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($objectQueueRows | Group-Object item_type | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Source-Type Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($objectQueueRows | Group-Object source_type | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Top Priority Items") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("| Priority | Workspace | Type | Item | Rows | Operations |") | Out-Null
$doc.Add("| --- | --- | --- | --- | --- | --- |") | Out-Null
foreach ($row in ($itemQueueSorted | Select-Object -First 15)) {
    $doc.Add("| $($row.priority_score) | $(Escape-MdCell $row.workspace_name) | $(Escape-MdCell $row.item_type) | $(Escape-MdCell $row.item_name) | $($row.likely_object_lineage_row_count) | $(Escape-MdCell $row.operation_types) |") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- analysis/d3_likely_object_lineage_item_queue.csv") | Out-Null
$doc.Add("- analysis/d3_likely_object_lineage_object_queue.csv") | Out-Null
$doc.Add("- analysis/d3_likely_object_lineage_summary.csv") | Out-Null
$doc.Add("- analysis/d3_object_lineage_confirmation_template.csv") | Out-Null
$doc.Add("- analysis/d3_readonly_object_lineage_targets.csv") | Out-Null
$doc.Add("- docs/25_d3_likely_object_lineage_confirmation.md") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## How To Close D3 Rows") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('1. Work `analysis/d3_likely_object_lineage_item_queue.csv` first to pick the highest-impact item.') | Out-Null
$doc.Add('2. Work the matching rows in `analysis/d3_likely_object_lineage_object_queue.csv`.') | Out-Null
$doc.Add('3. Use `analysis/d3_object_lineage_confirmation_template.csv` to mark each object row as confirmed, rejected, or blocked.') | Out-Null
$doc.Add("4. Confirm object lineage from generated parser evidence, Azure DevOps, SharePoint, OneLake, read-only Fabric/Power BI/SQL metadata, or owner-approved evidence.") | Out-Null
$doc.Add('5. Exact object type cleanup remains D4 if the object is confirmed but still typed as `table_or_view` or `native_query_object`.') | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Suggested Rebuild After Approved Evidence") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('```powershell') | Out-Null
$doc.Add("pwsh -NoLogo -File backend/scripts/99_refresh_lineage_project.ps1 -Mode local-artifacts -SkipStandalone") | Out-Null
$doc.Add('```') | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Gate") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D3 is closed only when high-priority likely object-lineage rows are confirmed, rejected, or explicitly blocked with evidence. This package is evidence preparation and does not approve orchestration rules.") | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D3 likely object-lineage confirmation package completed."
Write-Host "Item blocker rows: $($itemQueueRows.Count)"
Write-Host "Likely object-lineage rows: $($objectQueueRows.Count)"
Write-Host "Output: $OutputObjectQueuePath"
