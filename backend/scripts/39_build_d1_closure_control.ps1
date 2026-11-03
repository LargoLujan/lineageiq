# Phase 39 - D1 closure control: tracks which D1 (missing object lineage,
# Phase 26) queue items have since been resolved by manual evidence or
# inherited from pipeline activity lineage, closing them out of the queue
# and re-deriving what's still genuinely open. Purely local.
# Writes: $OutputControlQueuePath, $OutputInheritedCandidatePath,
# $OutputDecisionTemplatePath, $OutputReadonlyPlanPath, $OutputSummaryPath,
# $OutputDocPath.
param(
    [string]$D1QueuePath = (Join-Path $PSScriptRoot "../../analysis/d1_missing_object_lineage_queue.csv"),
    [string]$ObjectReadWritePath = (Join-Path $PSScriptRoot "../../analysis/object_read_write_classification.csv"),
    [string]$PipelineActivityPath = (Join-Path $PSScriptRoot "../../analysis/pipeline_activity_lineage.csv"),
    [string]$OutputControlQueuePath = (Join-Path $PSScriptRoot "../../analysis/d1_closure_control_queue.csv"),
    [string]$OutputInheritedCandidatePath = (Join-Path $PSScriptRoot "../../analysis/d1_inherited_pipeline_lineage_candidates.csv"),
    [string]$OutputDecisionTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d1_closure_decision_template.csv"),
    [string]$OutputReadonlyPlanPath = (Join-Path $PSScriptRoot "../../analysis/d1_external_readonly_action_plan.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d1_closure_control_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/35_d1_closure_control.md")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

function Import-OptionalCsv {
    param([string]$Path)
    if ((Test-Path $Path) -and ((Get-Item $Path).Length -gt 0)) {
        return @(Import-Csv -Path $Path)
    }
    return @()
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
    param([string]$Text, [int]$MaxLength = 700)
    if (-not $Text) { return "" }
    $clean = ($Text -replace "\s+", " ").Trim()
    if ($clean.Length -le $MaxLength) { return $clean }
    return $clean.Substring(0, $MaxLength - 3) + "..."
}

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

function Get-UniqueValues {
    param([object[]]$Rows, [string]$ColumnName)
    return @(
        $Rows |
            ForEach-Object { Get-FieldValue -Object $_ -Names @($ColumnName) } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
}

function Get-ClosureOpportunity {
    param(
        [string]$ItemType,
        [string]$DefinitionStatus,
        [int]$DirectObjectRows,
        [int]$InvokedItemCount,
        [int]$ChildObjectRows
    )

    if ($DirectObjectRows -gt 0) { return "direct_local_object_evidence_present" }
    if ($ItemType -eq "DataPipeline" -and $ChildObjectRows -gt 0) { return "inherited_child_object_evidence_candidate" }
    if ($ItemType -eq "DataPipeline" -and $InvokedItemCount -gt 0) { return "orchestrator_only_or_child_review_required" }
    if ($DefinitionStatus -match "decoded_no_object_candidates|decoded_activities_no_object_candidates|definition_decoded_empty") { return "parser_improvement_or_manual_review_required" }
    if ($DefinitionStatus -match "not_in_.*gap_file|needs_tmdl_or_model_expression_review|semantic_definition_unavailable") { return "read_only_definition_retry_required" }
    if ($ItemType -eq "SemanticModel") { return "semantic_model_source_review_required" }
    return "manual_review_required"
}

function Get-RecommendedD1Decision {
    param([string]$Opportunity)
    switch ($Opportunity) {
        "direct_local_object_evidence_present" { return "Review local object rows, then copy confirmed rows into index/manual_lineage_object_evidence.csv." }
        "inherited_child_object_evidence_candidate" { return "Review invoked child lineage; if parent only orchestrates children, close as orchestrator_only_no_direct_objects or record inherited objects with evidence." }
        "orchestrator_only_or_child_review_required" { return "Review activities; close as orchestrator_only_no_direct_objects when no direct source/sink exists, otherwise inspect invoked child definitions." }
        "parser_improvement_or_manual_review_required" { return "Inspect decoded definition/code manually and improve parser only if a repeatable pattern is found." }
        "read_only_definition_retry_required" { return "Run the recommended read-only definition/catalog extraction after human authentication/approval, then rebuild D1." }
        "semantic_model_source_review_required" { return "Inspect TMDL/model expressions or owner-approved source mapping; record exact objects or close with an explicit reviewed state." }
        default { return "Review manually and close with confirmed, rejected, access_denied, not_available, dynamic_reference, or manual_review_required." }
    }
}

foreach ($required in @($D1QueuePath)) {
    if (-not (Test-Path $required)) {
        throw "Required input not found: $required"
    }
}

$d1Rows = @(Import-Csv -Path $D1QueuePath)
$objectRows = @(Import-OptionalCsv -Path $ObjectReadWritePath)
$activityRows = @(Import-OptionalCsv -Path $PipelineActivityPath)

$objectRowsByItem = @{}
foreach ($row in $objectRows) {
    Add-ListMapValue -Map $objectRowsByItem -Key (Get-FieldValue -Object $row -Names @("item_qualified_name")) -Value $row
}

$activitiesByPipeline = @{}
foreach ($row in $activityRows) {
    Add-ListMapValue -Map $activitiesByPipeline -Key (Get-FieldValue -Object $row -Names @("pipeline_qualified_name")) -Value $row
}

$controlRows = [System.Collections.Generic.List[object]]::new()
$inheritedRows = [System.Collections.Generic.List[object]]::new()
$decisionRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()

$rowIndex = 0
foreach ($row in ($d1Rows | Sort-Object @{ Expression = { Convert-ToInt (Get-FieldValue -Object $_ -Names @("priority_score")) }; Descending = $true }, workspace_name, item_type, item_name)) {
    $rowIndex++
    $d1Id = "D1C{0:0000}" -f $rowIndex
    $qualifiedName = Get-FieldValue -Object $row -Names @("item_qualified_name")
    $itemType = Get-FieldValue -Object $row -Names @("item_type")
    $definitionStatus = Get-FieldValue -Object $row -Names @("definition_lookup_status")
    $directObjectRows = if ($objectRowsByItem.ContainsKey($qualifiedName)) { @($objectRowsByItem[$qualifiedName]).Count } else { 0 }

    $pipelineActivities = if ($activitiesByPipeline.ContainsKey($qualifiedName)) { @($activitiesByPipeline[$qualifiedName]) } else { @() }
    $invokedItems = @(Get-UniqueValues -Rows $pipelineActivities -ColumnName "invoked_item_qualified_name")
    $childItemsWithEvidence = [System.Collections.Generic.List[string]]::new()
    $childObjectRows = 0

    foreach ($child in $invokedItems) {
        if (-not $objectRowsByItem.ContainsKey($child)) { continue }
        $childItemsWithEvidence.Add($child) | Out-Null
        $childObjectRows += @($objectRowsByItem[$child]).Count

        foreach ($objectRow in @($objectRowsByItem[$child])) {
            $activityMatch = @($pipelineActivities | Where-Object { (Get-FieldValue -Object $_ -Names @("invoked_item_qualified_name")) -eq $child } | Select-Object -First 1)
            $inheritedRows.Add([pscustomobject]@{
                d1_id = $d1Id
                parent_workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
                parent_item_type = $itemType
                parent_item_name = Get-FieldValue -Object $row -Names @("item_name")
                parent_item_qualified_name = $qualifiedName
                activity_name = if (@($activityMatch).Count -gt 0) { Get-FieldValue -Object $activityMatch[0] -Names @("activity_name") } else { "" }
                activity_type = if (@($activityMatch).Count -gt 0) { Get-FieldValue -Object $activityMatch[0] -Names @("activity_type") } else { "" }
                invoked_item_qualified_name = $child
                source_type = Get-FieldValue -Object $objectRow -Names @("source_type")
                source_server = Get-FieldValue -Object $objectRow -Names @("source_server")
                source_database = Get-FieldValue -Object $objectRow -Names @("source_database")
                schema_name = Get-FieldValue -Object $objectRow -Names @("schema_name")
                object_name = Get-FieldValue -Object $objectRow -Names @("object_name")
                object_type = Get-FieldValue -Object $objectRow -Names @("object_type")
                operation_type = Get-FieldValue -Object $objectRow -Names @("operation_type")
                lineage_confidence = Get-FieldValue -Object $objectRow -Names @("lineage_confidence")
                proposed_status = ""
                evidence = Limit-Text -Text ("Parent pipeline invokes child with local object evidence. Child evidence: " + (Get-FieldValue -Object $objectRow -Names @("evidence"))) -MaxLength 900
                reviewer = ""
                reviewed_at = ""
                notes = "D1 inherited candidate. Confirm whether the parent pipeline has no additional direct source/sink before promoting or closing."
            }) | Out-Null
        }
    }

    $opportunity = Get-ClosureOpportunity `
        -ItemType $itemType `
        -DefinitionStatus $definitionStatus `
        -DirectObjectRows $directObjectRows `
        -InvokedItemCount @($invokedItems).Count `
        -ChildObjectRows $childObjectRows
    $recommendedDecision = Get-RecommendedD1Decision -Opportunity $opportunity
    $needsExternalRead = if ($opportunity -eq "read_only_definition_retry_required") { "yes" } else { "no" }

    $controlRows.Add([pscustomobject]@{
        d1_id = $d1Id
        priority_score = Get-FieldValue -Object $row -Names @("priority_score")
        priority_band = Get-FieldValue -Object $row -Names @("priority_band")
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $row -Names @("workspace_environment")
        item_type = $itemType
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        item_qualified_name = $qualifiedName
        coverage_status = Get-FieldValue -Object $row -Names @("coverage_status")
        gap_reason = Get-FieldValue -Object $row -Names @("gap_reason")
        definition_lookup_status = $definitionStatus
        v2_status = Get-FieldValue -Object $row -Names @("v2_status")
        failed_count = Get-FieldValue -Object $row -Names @("failed_count")
        direct_object_reference_count = $directObjectRows
        invoked_item_count = @($invokedItems).Count
        invoked_items_with_object_evidence_count = @($childItemsWithEvidence).Count
        inherited_child_object_reference_count = $childObjectRows
        closure_opportunity = $opportunity
        recommended_d1_decision = $recommendedDecision
        needs_external_readonly = $needsExternalRead
        proposed_readonly_command = Get-FieldValue -Object $row -Names @("recommended_command")
        manual_template_path = Get-FieldValue -Object $row -Names @("manual_template_path")
        decision_template_path = $OutputDecisionTemplatePath
        evidence_sources = Get-FieldValue -Object $row -Names @("recommended_evidence_sources")
    }) | Out-Null

    $decisionRows.Add([pscustomobject]@{
        d1_id = $d1Id
        item_qualified_name = $qualifiedName
        item_type = $itemType
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        closure_opportunity = $opportunity
        proposed_status = ""
        allowed_statuses = "confirmed; rejected; access_denied; not_available; dynamic_reference; manual_review_required; orchestrator_only_no_direct_objects"
        confirmed_or_blocked_evidence = ""
        evidence_source = ""
        reviewer = ""
        reviewed_at = ""
        next_action = $recommendedDecision
        notes = "Fill this row before treating D1 as closed for the item. Use analysis/d1_manual_lineage_evidence_template.csv for confirmed object rows."
    }) | Out-Null

    if ($needsExternalRead -eq "yes") {
        $readonlyRows.Add([pscustomobject]@{
            d1_id = $d1Id
            priority_score = Get-FieldValue -Object $row -Names @("priority_score")
            workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
            item_type = $itemType
            item_name = Get-FieldValue -Object $row -Names @("item_name")
            item_qualified_name = $qualifiedName
            definition_lookup_status = $definitionStatus
            proposed_readonly_command = Get-FieldValue -Object $row -Names @("recommended_command")
            target = "Read-only item definition/catalog evidence for D1 closure"
            human_action = "Authenticate/approve read-only execution, run command, review generated evidence, then rebuild D1."
        }) | Out-Null
    }
}

$summaryRows = [System.Collections.Generic.List[object]]::new()
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D1 closure control rows"; row_count = @($controlRows).Count; notes = "One row per D1 item." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Inherited pipeline candidate rows"; row_count = @($inheritedRows).Count; notes = "Object rows inherited from invoked child items, pending human review." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "External read-only action rows"; row_count = @($readonlyRows).Count; notes = "Rows that need read-only Fabric/metadata refresh or owner-approved evidence." }) | Out-Null
foreach ($group in @($controlRows | Group-Object closure_opportunity | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "closure_opportunity"; group_key = $group.Name; row_count = $group.Count; notes = "D1 items grouped by recommended closure path." }) | Out-Null
}
foreach ($group in @($controlRows | Group-Object item_type | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "item_type"; group_key = $group.Name; row_count = $group.Count; notes = "D1 closure rows grouped by item type." }) | Out-Null
}

$controlColumns = @(
    "d1_id", "priority_score", "priority_band", "workspace_name", "workspace_environment",
    "item_type", "item_name", "item_qualified_name", "coverage_status", "gap_reason",
    "definition_lookup_status", "v2_status", "failed_count", "direct_object_reference_count",
    "invoked_item_count", "invoked_items_with_object_evidence_count",
    "inherited_child_object_reference_count", "closure_opportunity", "recommended_d1_decision",
    "needs_external_readonly", "proposed_readonly_command", "manual_template_path",
    "decision_template_path", "evidence_sources"
)
$inheritedColumns = @(
    "d1_id", "parent_workspace_name", "parent_item_type", "parent_item_name",
    "parent_item_qualified_name", "activity_name", "activity_type", "invoked_item_qualified_name",
    "source_type", "source_server", "source_database", "schema_name", "object_name",
    "object_type", "operation_type", "lineage_confidence", "proposed_status", "evidence",
    "reviewer", "reviewed_at", "notes"
)
$decisionColumns = @(
    "d1_id", "item_qualified_name", "item_type", "item_name", "closure_opportunity",
    "proposed_status", "allowed_statuses", "confirmed_or_blocked_evidence",
    "evidence_source", "reviewer", "reviewed_at", "next_action", "notes"
)
$readonlyColumns = @(
    "d1_id", "priority_score", "workspace_name", "item_type", "item_name",
    "item_qualified_name", "definition_lookup_status", "proposed_readonly_command",
    "target", "human_action"
)
$summaryColumns = @("summary_scope", "group_key", "row_count", "notes")

Export-Rows -Rows @($controlRows) -Columns $controlColumns -Path $OutputControlQueuePath
Export-Rows -Rows @($inheritedRows) -Columns $inheritedColumns -Path $OutputInheritedCandidatePath
Export-Rows -Rows @($decisionRows) -Columns $decisionColumns -Path $OutputDecisionTemplatePath
Export-Rows -Rows @($readonlyRows) -Columns $readonlyColumns -Path $OutputReadonlyPlanPath
Export-Rows -Rows @($summaryRows) -Columns $summaryColumns -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D1 Closure Control") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated by backend/scripts/39_build_d1_closure_control.ps1 from local project artifacts only.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Start D1 closure without forcing unsupported confirmations. Every D1 item must be closed as confirmed, rejected, access_denied, not_available, dynamic_reference, manual_review_required, or orchestrator_only_no_direct_objects.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- $OutputControlQueuePath") | Out-Null
$doc.Add("- $OutputInheritedCandidatePath") | Out-Null
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
$doc.Add("- Use inherited pipeline candidates only as review evidence; do not promote them automatically.") | Out-Null
$doc.Add('- Use `analysis/d1_manual_lineage_evidence_template.csv` for confirmed object rows.') | Out-Null
$doc.Add('- Use `analysis/d1_closure_decision_template.csv` when the correct closure is rejected, access denied, not available, dynamic reference, manual review required, or orchestrator-only.') | Out-Null
$doc.Add("- After decisions/evidence are approved, rebuild D1, Phase 12, and Phase 13 to measure blocker reduction.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Next Human Step") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('Review critical/high rows in `analysis/d1_closure_control_queue.csv`, starting with inherited pipeline candidates and read-only definition retry rows.') | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D1 closure control built."
Write-Host "Control rows: $(@($controlRows).Count)"
Write-Host "Inherited candidate rows: $(@($inheritedRows).Count)"
Write-Host "External read-only action rows: $(@($readonlyRows).Count)"
