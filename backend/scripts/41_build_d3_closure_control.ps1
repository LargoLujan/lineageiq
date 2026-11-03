# Phase 41 - D3 closure control: tracks which D3 (likely object lineage,
# Phase 28) queue items have since been confirmed, closing them out and
# re-deriving what's still open for source-object review. Purely local.
# Writes: $OutputControlQueuePath, $OutputItemControlPath,
# $OutputSourceObjectTargetPath, $OutputDecisionTemplatePath,
# $OutputReadonlyPlanPath, $OutputSummaryPath, $OutputDocPath.
param(
    [string]$D3ItemQueuePath = (Join-Path $PSScriptRoot "../../analysis/d3_likely_object_lineage_item_queue.csv"),
    [string]$D3ObjectQueuePath = (Join-Path $PSScriptRoot "../../analysis/d3_likely_object_lineage_object_queue.csv"),
    [string]$OutputControlQueuePath = (Join-Path $PSScriptRoot "../../analysis/d3_closure_control_queue.csv"),
    [string]$OutputItemControlPath = (Join-Path $PSScriptRoot "../../analysis/d3_item_closure_control_queue.csv"),
    [string]$OutputSourceObjectTargetPath = (Join-Path $PSScriptRoot "../../analysis/d3_source_object_review_targets.csv"),
    [string]$OutputDecisionTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d3_lineage_decision_template.csv"),
    [string]$OutputReadonlyPlanPath = (Join-Path $PSScriptRoot "../../analysis/d3_external_readonly_action_plan.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d3_closure_control_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/37_d3_closure_control.md")
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
    if (@($Rows).Count -gt 0) {
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
    $number = 0
    if ([int]::TryParse([string]$Value, [ref]$number)) { return $number }
    try { return [int][double]$Value } catch { return 0 }
}

function Limit-Text {
    param([string]$Text, [int]$MaxLength = 900)
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

function Add-ListMapValue {
    param(
        [hashtable]$Map,
        [string]$Key,
        [object]$Value
    )
    if (-not $Key) { return }
    if (-not $Map.ContainsKey($Key)) {
        $Map[$Key] = [System.Collections.Generic.List[object]]::new()
    }
    $Map[$Key].Add($Value) | Out-Null
}

function Get-PriorityBand {
    param([int]$PriorityScore)
    if ($PriorityScore -ge 1000) { return "critical" }
    if ($PriorityScore -ge 250) { return "high" }
    if ($PriorityScore -ge 100) { return "medium" }
    return "low"
}

function Get-UniqueJoined {
    param([object[]]$Rows, [string]$ColumnName, [int]$MaxValues = 20)
    $values = @(
        $Rows |
            ForEach-Object { Get-FieldValue -Object $_ -Names @($ColumnName) } |
            Where-Object { $_ } |
            Sort-Object -Unique |
            Select-Object -First $MaxValues
    )
    return ($values -join "; ")
}

function Get-GroupCounts {
    param([object[]]$Rows, [string]$ColumnName)
    return ((@(
        $Rows |
            Group-Object $ColumnName |
            Sort-Object @{ Expression = "Count"; Descending = $true }, Name |
            ForEach-Object { "$($_.Name)=$($_.Count)" }
    )) -join "; ")
}

function Get-ClosureOpportunity {
    param([string]$ItemType, [string]$HardeningIssueTypes)
    switch ($ItemType) {
        "SemanticModel" { return "semantic_model_source_mapping_review" }
        "Notebook" { return "notebook_code_reference_review" }
        "CopyJob" { return "copyjob_source_sink_mapping_review" }
        "DataPipeline" { return "pipeline_inherited_lineage_review" }
        default {
            if ($HardeningIssueTypes -match "weak_object_lineage_confidence|weak_lineage") { return "manual_lineage_review_required" }
            return "manual_review_required"
        }
    }
}

function Get-RecommendedDecision {
    param([string]$ClosureOpportunity)
    switch ($ClosureOpportunity) {
        "semantic_model_source_mapping_review" { return "Confirm the model source from TMDL, Power Query/M, partitions, model expressions, or owner-approved mapping." }
        "notebook_code_reference_review" { return "Confirm the object reference from notebook code, SQL cells, Spark read/write calls, default lakehouse metadata, Azure DevOps, or owner evidence." }
        "copyjob_source_sink_mapping_review" { return "Confirm CopyJob source/sink mapping from the generated definition, connection metadata, or owner-approved mapping." }
        "pipeline_inherited_lineage_review" { return "Confirm whether the pipeline row is inherited from invoked child lineage or a direct pipeline source/sink; then close explicitly." }
        default { return "Review manually and close with confirmed, rejected, access_denied, not_available, dynamic_reference, or manual_review_required." }
    }
}

function Get-ReadonlyAction {
    param([string]$ClosureOpportunity)
    switch ($ClosureOpportunity) {
        "semantic_model_source_mapping_review" { return "Read semantic model definition/TMDL and validate all likely source-object rows for this model before recording decisions." }
        "notebook_code_reference_review" { return "Read notebook code and validate all likely object references and operations for this notebook." }
        "copyjob_source_sink_mapping_review" { return "Read CopyJob definition and validate source/sink object mappings and operations." }
        "pipeline_inherited_lineage_review" { return "Read pipeline activities and invoked item lineage; validate whether object rows are direct, inherited, or unsupported." }
        default { return "Read the item definition or owner-approved evidence and record decisions in the D3 template." }
    }
}

function Get-SourceObjectTargetKey {
    param([object]$Row)
    $operationType = Get-FieldValue -Object $Row -Names @("operation_type")
    $objectKey = Get-FieldValue -Object $Row -Names @("object_key")
    if (-not $objectKey) {
        $objectKey = (
            (Get-FieldValue -Object $Row -Names @("source_type")) + "|" +
            (Get-FieldValue -Object $Row -Names @("source_server")) + "|" +
            (Get-FieldValue -Object $Row -Names @("source_database")) + "|" +
            (Get-FieldValue -Object $Row -Names @("schema_name")) + "|" +
            (Get-FieldValue -Object $Row -Names @("object_name"))
        )
    }
    return ((Normalize-Key -Value $operationType) + "|" + (Normalize-Key -Value $objectKey))
}

if (-not (Test-Path $D3ObjectQueuePath)) {
    throw "Required input not found: $D3ObjectQueuePath"
}

$objectRows = @(Import-Csv -Path $D3ObjectQueuePath)
$itemRows = if ((Test-Path $D3ItemQueuePath) -and ((Get-Item $D3ItemQueuePath).Length -gt 0)) { @(Import-Csv -Path $D3ItemQueuePath) } else { @() }

$objectsByItem = @{}
$objectsBySourceTarget = @{}
foreach ($row in $objectRows) {
    Add-ListMapValue -Map $objectsByItem -Key (Normalize-Key -Value (Get-FieldValue -Object $row -Names @("item_qualified_name"))) -Value $row
    Add-ListMapValue -Map $objectsBySourceTarget -Key (Get-SourceObjectTargetKey -Row $row) -Value $row
}

$sourceTargetRows = [System.Collections.Generic.List[object]]::new()
$sourceTargetIdByKey = @{}
$targetIndex = 0

$sourceGroups = @(
    $objectsBySourceTarget.GetEnumerator() |
        ForEach-Object {
            $rows = @($_.Value)
            [pscustomobject]@{
                key = $_.Key
                rows = $rows
                max_priority = (@($rows | ForEach-Object { Convert-ToInt (Get-FieldValue -Object $_ -Names @("priority_score")) } | Measure-Object -Maximum).Maximum)
                row_count = @($rows).Count
            }
        } |
        Sort-Object @{ Expression = { [int]$_.max_priority }; Descending = $true }, @{ Expression = { [int]$_.row_count }; Descending = $true }, key
)

foreach ($group in $sourceGroups) {
    $targetIndex++
    $targetId = "D3S{0:0000}" -f $targetIndex
    $rows = @($group.rows)
    $first = $rows[0]
    $priorityScore = [int]$group.max_priority
    $itemKeys = @($rows | ForEach-Object { Get-FieldValue -Object $_ -Names @("item_qualified_name") } | Where-Object { $_ } | Sort-Object -Unique)
    $sourceTargetIdByKey[$group.key] = $targetId

    $sourceTargetRows.Add([pscustomobject]@{
        source_review_target_id = $targetId
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        row_count = @($rows).Count
        impacted_item_count = @($itemKeys).Count
        operation_type = Get-FieldValue -Object $first -Names @("operation_type")
        source_type = Get-FieldValue -Object $first -Names @("source_type")
        source_server = Get-FieldValue -Object $first -Names @("source_server")
        source_database = Get-FieldValue -Object $first -Names @("source_database")
        schema_name = Get-FieldValue -Object $first -Names @("schema_name")
        object_name = Get-FieldValue -Object $first -Names @("object_name")
        object_display_name = Get-FieldValue -Object $first -Names @("object_display_name")
        object_key = Get-FieldValue -Object $first -Names @("object_key")
        current_object_type = Get-FieldValue -Object $first -Names @("object_type")
        object_type_status = Get-FieldValue -Object $first -Names @("object_type_status")
        item_type_split = Get-GroupCounts -Rows $rows -ColumnName "item_type"
        lineage_confidence_split = Get-GroupCounts -Rows $rows -ColumnName "lineage_confidence"
        hardening_issue_types = Limit-Text -Text (Get-GroupCounts -Rows $rows -ColumnName "hardening_issue_types") -MaxLength 700
        sample_items = Limit-Text -Text (Get-UniqueJoined -Rows $rows -ColumnName "item_qualified_name" -MaxValues 12) -MaxLength 1200
        proposed_status = ""
        allowed_statuses = "confirmed; rejected; access_denied; not_available; dynamic_reference; manual_review_required"
        confirmation_source = ""
        confirmation_evidence = ""
        reviewer = ""
        reviewed_at = ""
        notes = "Cross-item source-object target. Use this to batch owner/catalog review; row-level item decisions still live in the D3 decision template."
    }) | Out-Null
}

$itemControlRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()
$itemIndex = 0

foreach ($item in ($itemRows | Sort-Object @{ Expression = { Convert-ToInt (Get-FieldValue -Object $_ -Names @("priority_score")) }; Descending = $true }, item_qualified_name)) {
    $itemIndex++
    $itemQualified = Get-FieldValue -Object $item -Names @("item_qualified_name")
    $itemKey = Normalize-Key -Value $itemQualified
    $rows = if ($objectsByItem.ContainsKey($itemKey)) { @($objectsByItem[$itemKey]) } else { @() }
    $priorityScore = Convert-ToInt (Get-FieldValue -Object $item -Names @("priority_score"))
    if ($priorityScore -eq 0 -and @($rows).Count -gt 0) {
        $priorityScore = (@($rows | ForEach-Object { Convert-ToInt (Get-FieldValue -Object $_ -Names @("priority_score")) } | Measure-Object -Maximum).Maximum)
    }
    $itemType = Get-FieldValue -Object $item -Names @("item_type")
    $issueTypes = Get-GroupCounts -Rows $rows -ColumnName "hardening_issue_types"
    $closureOpportunity = Get-ClosureOpportunity -ItemType $itemType -HardeningIssueTypes $issueTypes
    $recommendedDecision = Get-RecommendedDecision -ClosureOpportunity $closureOpportunity
    $sourceTargetIds = @(
        $rows |
            ForEach-Object {
                $key = Get-SourceObjectTargetKey -Row $_
                if ($sourceTargetIdByKey.ContainsKey($key)) { $sourceTargetIdByKey[$key] }
            } |
            Sort-Object -Unique
    )

    $itemControlRows.Add([pscustomobject]@{
        item_review_id = "D3I{0:0000}" -f $itemIndex
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        closure_opportunity = $closureOpportunity
        workspace_name = Get-FieldValue -Object $item -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $item -Names @("workspace_environment")
        item_type = $itemType
        item_name = Get-FieldValue -Object $item -Names @("item_name")
        item_qualified_name = $itemQualified
        likely_object_lineage_row_count = @($rows).Count
        source_review_target_count = @($sourceTargetIds).Count
        operation_split = Get-GroupCounts -Rows $rows -ColumnName "operation_type"
        source_type_split = Get-GroupCounts -Rows $rows -ColumnName "source_type"
        object_type_status_split = Get-GroupCounts -Rows $rows -ColumnName "object_type_status"
        hardening_issue_types = Limit-Text -Text $issueTypes -MaxLength 900
        source_review_target_ids = Limit-Text -Text ($sourceTargetIds -join "; ") -MaxLength 1200
        sample_objects = Limit-Text -Text (Get-UniqueJoined -Rows $rows -ColumnName "object_display_name" -MaxValues 12) -MaxLength 1200
        recommended_d3_decision = $recommendedDecision
        needs_external_readonly = "yes"
        decision_template_path = $OutputDecisionTemplatePath
    }) | Out-Null

    $readonlyRows.Add([pscustomobject]@{
        item_review_id = "D3I{0:0000}" -f $itemIndex
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        closure_opportunity = $closureOpportunity
        workspace_name = Get-FieldValue -Object $item -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $item -Names @("workspace_environment")
        item_type = $itemType
        item_name = Get-FieldValue -Object $item -Names @("item_name")
        item_qualified_name = $itemQualified
        likely_object_lineage_row_count = @($rows).Count
        source_review_target_count = @($sourceTargetIds).Count
        human_readonly_action = Get-ReadonlyAction -ClosureOpportunity $closureOpportunity
        decision_template_path = $OutputDecisionTemplatePath
        notes = "Read-only/manual D3 action. Do not modify Fabric or evidence indexes from this package alone."
    }) | Out-Null
}

$controlRows = [System.Collections.Generic.List[object]]::new()
$decisionRows = [System.Collections.Generic.List[object]]::new()
$rowIndex = 0
foreach ($row in ($objectRows | Sort-Object @{ Expression = { Convert-ToInt (Get-FieldValue -Object $_ -Names @("priority_score")) }; Descending = $true }, row_id)) {
    $rowIndex++
    $d3Id = "D3C{0:000000}" -f $rowIndex
    $sourceKey = Get-SourceObjectTargetKey -Row $row
    $targetId = if ($sourceTargetIdByKey.ContainsKey($sourceKey)) { $sourceTargetIdByKey[$sourceKey] } else { "" }
    $closureOpportunity = Get-ClosureOpportunity `
        -ItemType (Get-FieldValue -Object $row -Names @("item_type")) `
        -HardeningIssueTypes (Get-FieldValue -Object $row -Names @("hardening_issue_types"))
    $alsoBlocksD4 = if ((Get-FieldValue -Object $row -Names @("object_type_status")) -eq "ambiguous") { "yes" } else { "no" }

    $controlRows.Add([pscustomobject]@{
        d3_id = $d3Id
        source_review_target_id = $targetId
        row_id = Get-FieldValue -Object $row -Names @("row_id")
        priority_score = Get-FieldValue -Object $row -Names @("priority_score")
        priority_band = Get-FieldValue -Object $row -Names @("priority_band")
        closure_opportunity = $closureOpportunity
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $row -Names @("workspace_environment")
        item_type = Get-FieldValue -Object $row -Names @("item_type")
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        item_qualified_name = Get-FieldValue -Object $row -Names @("item_qualified_name")
        operation_type = Get-FieldValue -Object $row -Names @("operation_type")
        source_type = Get-FieldValue -Object $row -Names @("source_type")
        source_database = Get-FieldValue -Object $row -Names @("source_database")
        schema_name = Get-FieldValue -Object $row -Names @("schema_name")
        object_name = Get-FieldValue -Object $row -Names @("object_name")
        object_display_name = Get-FieldValue -Object $row -Names @("object_display_name")
        object_key = Get-FieldValue -Object $row -Names @("object_key")
        object_type = Get-FieldValue -Object $row -Names @("object_type")
        object_type_status = Get-FieldValue -Object $row -Names @("object_type_status")
        lineage_confidence = Get-FieldValue -Object $row -Names @("lineage_confidence")
        hardening_issue_types = Get-FieldValue -Object $row -Names @("hardening_issue_types")
        also_blocks_d4 = $alsoBlocksD4
        current_evidence = Get-FieldValue -Object $row -Names @("evidence")
        recommended_d3_decision = Get-RecommendedDecision -ClosureOpportunity $closureOpportunity
        decision_template_path = $OutputDecisionTemplatePath
    }) | Out-Null

    $decisionRows.Add([pscustomobject]@{
        d3_id = $d3Id
        source_review_target_id = $targetId
        row_id = Get-FieldValue -Object $row -Names @("row_id")
        item_qualified_name = Get-FieldValue -Object $row -Names @("item_qualified_name")
        item_type = Get-FieldValue -Object $row -Names @("item_type")
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        current_operation_type = Get-FieldValue -Object $row -Names @("operation_type")
        current_source_type = Get-FieldValue -Object $row -Names @("source_type")
        current_source_server = Get-FieldValue -Object $row -Names @("source_server")
        current_source_database = Get-FieldValue -Object $row -Names @("source_database")
        current_schema_name = Get-FieldValue -Object $row -Names @("schema_name")
        current_object_name = Get-FieldValue -Object $row -Names @("object_name")
        current_object_display_name = Get-FieldValue -Object $row -Names @("object_display_name")
        current_object_type = Get-FieldValue -Object $row -Names @("object_type")
        current_lineage_confidence = Get-FieldValue -Object $row -Names @("lineage_confidence")
        closure_opportunity = $closureOpportunity
        proposed_status = ""
        allowed_statuses = "confirmed; rejected; access_denied; not_available; dynamic_reference; manual_review_required"
        confirmed_operation_type = Get-FieldValue -Object $row -Names @("operation_type")
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
        next_gate = if ($alsoBlocksD4 -eq "yes") { "D4 exact object type remains required if lineage is confirmed." } else { "" }
        notes = "Fill this row before treating D3 as closed for this object lineage. Do not use likely lineage as a hard orchestration rule."
    }) | Out-Null
}

$summaryRows = [System.Collections.Generic.List[object]]::new()
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D3 closure control rows"; row_count = @($controlRows).Count; notes = "One row per likely object-level lineage row." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D3 item review targets"; row_count = @($itemControlRows).Count; notes = "One read-only/manual review batch per impacted item." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D3 source-object review targets"; row_count = @($sourceTargetRows).Count; notes = "Cross-item source object plus operation review targets." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D3 decision rows"; row_count = @($decisionRows).Count; notes = "One decision row per likely object-level lineage row." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "External read-only action rows"; row_count = @($readonlyRows).Count; notes = "One read-only/manual action per item review target." }) | Out-Null
foreach ($group in @($controlRows | Group-Object closure_opportunity | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "closure_opportunity"; group_key = $group.Name; row_count = $group.Count; notes = "D3 rows grouped by closure path." }) | Out-Null
}
foreach ($group in @($controlRows | Group-Object operation_type | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "operation_type"; group_key = $group.Name; row_count = $group.Count; notes = "D3 rows grouped by operation type." }) | Out-Null
}
foreach ($group in @($controlRows | Group-Object item_type | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "item_type"; group_key = $group.Name; row_count = $group.Count; notes = "D3 rows grouped by item type." }) | Out-Null
}
foreach ($group in @($controlRows | Group-Object also_blocks_d4 | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "also_blocks_d4"; group_key = $group.Name; row_count = $group.Count; notes = "D3 rows that still need exact object-type cleanup if lineage is confirmed." }) | Out-Null
}

$controlColumns = @(
    "d3_id", "source_review_target_id", "row_id", "priority_score", "priority_band",
    "closure_opportunity", "workspace_name", "workspace_environment", "item_type",
    "item_name", "item_qualified_name", "operation_type", "source_type", "source_database",
    "schema_name", "object_name", "object_display_name", "object_key", "object_type",
    "object_type_status", "lineage_confidence", "hardening_issue_types", "also_blocks_d4",
    "current_evidence", "recommended_d3_decision", "decision_template_path"
)
$itemColumns = @(
    "item_review_id", "priority_score", "priority_band", "closure_opportunity",
    "workspace_name", "workspace_environment", "item_type", "item_name",
    "item_qualified_name", "likely_object_lineage_row_count", "source_review_target_count",
    "operation_split", "source_type_split", "object_type_status_split", "hardening_issue_types",
    "source_review_target_ids", "sample_objects", "recommended_d3_decision",
    "needs_external_readonly", "decision_template_path"
)
$sourceColumns = @(
    "source_review_target_id", "priority_score", "priority_band", "row_count",
    "impacted_item_count", "operation_type", "source_type", "source_server",
    "source_database", "schema_name", "object_name", "object_display_name", "object_key",
    "current_object_type", "object_type_status", "item_type_split", "lineage_confidence_split",
    "hardening_issue_types", "sample_items", "proposed_status", "allowed_statuses",
    "confirmation_source", "confirmation_evidence", "reviewer", "reviewed_at", "notes"
)
$decisionColumns = @(
    "d3_id", "source_review_target_id", "row_id", "item_qualified_name", "item_type",
    "item_name", "current_operation_type", "current_source_type", "current_source_server",
    "current_source_database", "current_schema_name", "current_object_name",
    "current_object_display_name", "current_object_type", "current_lineage_confidence",
    "closure_opportunity", "proposed_status", "allowed_statuses", "confirmed_operation_type",
    "confirmed_source_type", "confirmed_source_server", "confirmed_source_database",
    "confirmed_schema_name", "confirmed_object_name", "confirmed_object_type",
    "confirmation_source", "confirmation_evidence", "reviewer", "reviewed_at",
    "next_gate", "notes"
)
$readonlyColumns = @(
    "item_review_id", "priority_score", "priority_band", "closure_opportunity",
    "workspace_name", "workspace_environment", "item_type", "item_name",
    "item_qualified_name", "likely_object_lineage_row_count", "source_review_target_count",
    "human_readonly_action", "decision_template_path", "notes"
)
$summaryColumns = @("summary_scope", "group_key", "row_count", "notes")

Export-Rows -Rows @($controlRows) -Columns $controlColumns -Path $OutputControlQueuePath
Export-Rows -Rows @($itemControlRows) -Columns $itemColumns -Path $OutputItemControlPath
Export-Rows -Rows @($sourceTargetRows) -Columns $sourceColumns -Path $OutputSourceObjectTargetPath
Export-Rows -Rows @($decisionRows) -Columns $decisionColumns -Path $OutputDecisionTemplatePath
Export-Rows -Rows @($readonlyRows) -Columns $readonlyColumns -Path $OutputReadonlyPlanPath
Export-Rows -Rows @($summaryRows) -Columns $summaryColumns -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D3 Closure Control") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated by backend/scripts/41_build_d3_closure_control.ps1 from local project artifacts only.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Start D3 closure without forcing likely object-lineage rows into confirmed state. Every D3 row must close as confirmed, rejected, access_denied, not_available, dynamic_reference, or manual_review_required before it can be used as a hard impact or orchestration rule.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- $OutputControlQueuePath") | Out-Null
$doc.Add("- $OutputItemControlPath") | Out-Null
$doc.Add("- $OutputSourceObjectTargetPath") | Out-Null
$doc.Add("- $OutputDecisionTemplatePath") | Out-Null
$doc.Add("- $OutputReadonlyPlanPath") | Out-Null
$doc.Add("- $OutputSummaryPath") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Summary") | Out-Null
$doc.Add("") | Out-Null
foreach ($summary in @($summaryRows)) {
    $doc.Add("- $($summary.summary_scope) / $($summary.group_key): $($summary.row_count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Operating Rule") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- Use item review targets to validate all likely rows for one Fabric item from one definition/code review pass.") | Out-Null
$doc.Add("- Use source-object targets to batch owner/catalog review across items that mention the same object and operation.") | Out-Null
$doc.Add("- If lineage is confirmed but object type is ambiguous, D4 remains required for exact type resolution.") | Out-Null
$doc.Add("- Likely object-lineage rows stay visible for review but must not be used as hard orchestration rules until closed with evidence.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Next Human Step") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('Review `analysis/d3_item_closure_control_queue.csv`, starting with critical CopyJob/DataPipeline rows and then high-volume semantic model source mapping rows.') | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D3 closure control built."
Write-Host "Closure control rows: $(@($controlRows).Count)"
Write-Host "Item review targets: $(@($itemControlRows).Count)"
Write-Host "Source-object review targets: $(@($sourceTargetRows).Count)"
