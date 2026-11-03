# Phase 43 - D5 closure control: tracks which D5 (object conflict, Phase
# 30) queue items have since been resolved, but first checks whether each
# is still blocked on D3/D4 (source-object type/lineage must be confirmed
# before a conflict resolution is trustworthy) before considering it
# actionable. Purely local.
# Writes: $OutputControlQueuePath, $OutputBlockedQueuePath,
# $OutputSerializationTargetsPath, $OutputGuardDecisionQueuePath,
# $OutputParticipantReviewPath, $OutputDecisionTemplatePath,
# $OutputReadonlyPlanPath, $OutputSummaryPath, $OutputDocPath.
param(
    [string]$D5ConflictQueuePath = (Join-Path $PSScriptRoot "../../analysis/d5_object_conflict_queue.csv"),
    [string]$D5GuardEdgeQueuePath = (Join-Path $PSScriptRoot "../../analysis/d5_object_guard_edge_queue.csv"),
    [string]$D5ParticipantsPath = (Join-Path $PSScriptRoot "../../analysis/d5_object_conflict_participants.csv"),
    [string]$D3SourceObjectTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d3_source_object_review_targets.csv"),
    [string]$D4ImpactQueuePath = (Join-Path $PSScriptRoot "../../analysis/d4_exact_object_type_impact_queue.csv"),
    [string]$OutputControlQueuePath = (Join-Path $PSScriptRoot "../../analysis/d5_closure_control_queue.csv"),
    [string]$OutputBlockedQueuePath = (Join-Path $PSScriptRoot "../../analysis/d5_blocked_by_d3_d4_queue.csv"),
    [string]$OutputSerializationTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d5_serialization_review_targets.csv"),
    [string]$OutputGuardDecisionQueuePath = (Join-Path $PSScriptRoot "../../analysis/d5_guard_edge_decision_queue.csv"),
    [string]$OutputParticipantReviewPath = (Join-Path $PSScriptRoot "../../analysis/d5_conflict_participant_review.csv"),
    [string]$OutputDecisionTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d5_conflict_resolution_decision_template.csv"),
    [string]$OutputReadonlyPlanPath = (Join-Path $PSScriptRoot "../../analysis/d5_external_readonly_action_plan.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d5_closure_control_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/39_d5_closure_control.md")
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

function Get-GroupCounts {
    param([object[]]$Rows, [string]$ColumnName)
    return ((@(
        $Rows |
            Group-Object $ColumnName |
            Sort-Object @{ Expression = "Count"; Descending = $true }, Name |
            ForEach-Object { "$($_.Name)=$($_.Count)" }
    )) -join "; ")
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

function Get-D3TargetKey {
    param([string]$ObjectKey, [string]$OperationType)
    return ((Normalize-Key -Value $ObjectKey) + "|" + (Normalize-Key -Value $OperationType))
}

function Get-ClosureOpportunity {
    param([string]$DecisionReadiness)
    switch ($DecisionReadiness) {
        "blocked_by_d3_d4_evidence" { return "blocked_pending_d3_d4_closure" }
        "writer_order_review" { return "writer_serialization_review_required" }
        "writer_before_reader_review" { return "writer_before_reader_review_required" }
        "execute_order_review" { return "execute_order_review_required" }
        default { return "manual_conflict_review_required" }
    }
}

function Get-RecommendedDecision {
    param([string]$ClosureOpportunity)
    switch ($ClosureOpportunity) {
        "blocked_pending_d3_d4_closure" { return "Keep guard edges blocked until D3 lineage and D4 exact type are confirmed or explicitly accepted." }
        "writer_serialization_review_required" { return "Review writers and decide serialize_writers, partitioned_writes_safe_parallel, false_conflict, or blocked." }
        "writer_before_reader_review_required" { return "Review reader/writer timing and decide writer_before_reader, safe_parallel_readers_after_writer, false_conflict, or blocked." }
        "execute_order_review_required" { return "Review execute dependencies and decide execute_after_writers, confirm_invocation_dependency, false_conflict, or blocked." }
        default { return "Review participants and guard edges manually before selecting a conflict decision." }
    }
}

function Get-ReadonlyAction {
    param([string]$ClosureOpportunity)
    switch ($ClosureOpportunity) {
        "blocked_pending_d3_d4_closure" { return "Review linked D3/D4 targets; do not decide serialization until object lineage and exact type evidence are closed or explicitly accepted." }
        "writer_serialization_review_required" { return "Inspect writer item definitions, target partitions, full/incremental behavior, and run history to decide writer serialization." }
        "writer_before_reader_review_required" { return "Inspect reader dependencies and writer completion timing to decide writer-before-reader guard rules." }
        "execute_order_review_required" { return "Inspect execute/invocation definitions and whether execution already implies the required ordering." }
        default { return "Review participants, guards, definitions, execution evidence, and owner evidence before selecting the conflict decision." }
    }
}

if (-not (Test-Path $D5ConflictQueuePath)) {
    throw "Required input not found: $D5ConflictQueuePath"
}

$conflictRows = @(Import-Csv -Path $D5ConflictQueuePath)
$guardRows = Import-OptionalCsv -Path $D5GuardEdgeQueuePath
$participantRows = Import-OptionalCsv -Path $D5ParticipantsPath
$d3TargetRows = Import-OptionalCsv -Path $D3SourceObjectTargetsPath
$d4ImpactRows = Import-OptionalCsv -Path $D4ImpactQueuePath

$guardsByConflict = @{}
foreach ($row in $guardRows) {
    Add-ListMapValue -Map $guardsByConflict -Key (Get-FieldValue -Object $row -Names @("conflict_id")) -Value $row
}

$participantsByConflict = @{}
foreach ($row in $participantRows) {
    Add-ListMapValue -Map $participantsByConflict -Key (Get-FieldValue -Object $row -Names @("conflict_id")) -Value $row
}

$d3TargetByObjectOperation = @{}
foreach ($row in $d3TargetRows) {
    $key = Get-D3TargetKey `
        -ObjectKey (Get-FieldValue -Object $row -Names @("object_key")) `
        -OperationType (Get-FieldValue -Object $row -Names @("operation_type"))
    if ($key -and -not $d3TargetByObjectOperation.ContainsKey($key)) {
        $d3TargetByObjectOperation[$key] = Get-FieldValue -Object $row -Names @("source_review_target_id")
    }
}

$d4SourceIdsByObject = @{}
foreach ($row in $d4ImpactRows) {
    Add-ListMapValue -Map $d4SourceIdsByObject -Key (Normalize-Key -Value (Get-FieldValue -Object $row -Names @("object_key"))) -Value (Get-FieldValue -Object $row -Names @("source_id"))
}

$controlRows = [System.Collections.Generic.List[object]]::new()
$blockedRows = [System.Collections.Generic.List[object]]::new()
$serializationRows = [System.Collections.Generic.List[object]]::new()
$decisionRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()
$guardDecisionRows = [System.Collections.Generic.List[object]]::new()
$participantReviewRows = [System.Collections.Generic.List[object]]::new()

foreach ($conflict in ($conflictRows | Sort-Object @{ Expression = { Convert-ToInt (Get-FieldValue -Object $_ -Names @("priority_score")) }; Descending = $true }, conflict_id)) {
    $conflictId = Get-FieldValue -Object $conflict -Names @("conflict_id")
    $objectKey = Get-FieldValue -Object $conflict -Names @("object_key")
    $normalizedObjectKey = Normalize-Key -Value $objectKey
    $guards = if ($guardsByConflict.ContainsKey($conflictId)) { @($guardsByConflict[$conflictId]) } else { @() }
    $participants = if ($participantsByConflict.ContainsKey($conflictId)) { @($participantsByConflict[$conflictId]) } else { @() }

    $d3TargetIds = [System.Collections.Generic.List[string]]::new()
    foreach ($participant in $participants) {
        $targetKey = Get-D3TargetKey `
            -ObjectKey (Get-FieldValue -Object $participant -Names @("object_key")) `
            -OperationType (Get-FieldValue -Object $participant -Names @("operation_type"))
        if ($d3TargetByObjectOperation.ContainsKey($targetKey)) {
            $d3TargetIds.Add($d3TargetByObjectOperation[$targetKey]) | Out-Null
        }
    }
    $d4SourceIds = @()
    if ($normalizedObjectKey -and $d4SourceIdsByObject.ContainsKey($normalizedObjectKey)) {
        $d4SourceIds = @($d4SourceIdsByObject[$normalizedObjectKey] | Where-Object { $_ } | Sort-Object -Unique)
    }

    $decisionReadiness = Get-FieldValue -Object $conflict -Names @("decision_readiness")
    $closureOpportunity = Get-ClosureOpportunity -DecisionReadiness $decisionReadiness
    $recommendedDecision = Get-RecommendedDecision -ClosureOpportunity $closureOpportunity
    $readonlyAction = Get-ReadonlyAction -ClosureOpportunity $closureOpportunity
    $allowedDecisions = "blocked_pending_d3_d4; serialize_writers; writer_before_reader; execute_after_writers; safe_parallel_partitioned; false_conflict; manual_review_required"
    $d3TargetIdText = Limit-Text -Text ((@($d3TargetIds | Sort-Object -Unique)) -join "; ") -MaxLength 1200
    $d4SourceIdText = Limit-Text -Text ($d4SourceIds -join "; ") -MaxLength 700

    $controlRow = [pscustomobject]@{
        conflict_id = $conflictId
        priority_score = Get-FieldValue -Object $conflict -Names @("priority_score")
        priority_band = Get-FieldValue -Object $conflict -Names @("priority_band")
        closure_opportunity = $closureOpportunity
        object_key = $objectKey
        object_display_name = Get-FieldValue -Object $conflict -Names @("object_display_name")
        source_types = Get-FieldValue -Object $conflict -Names @("source_types")
        object_types = Get-FieldValue -Object $conflict -Names @("object_types")
        reader_count = Get-FieldValue -Object $conflict -Names @("reader_count")
        writer_count = Get-FieldValue -Object $conflict -Names @("writer_count")
        executor_count = Get-FieldValue -Object $conflict -Names @("executor_count")
        exact_row_count = Get-FieldValue -Object $conflict -Names @("exact_row_count")
        ambiguous_row_count = Get-FieldValue -Object $conflict -Names @("ambiguous_row_count")
        conflict_types = Get-FieldValue -Object $conflict -Names @("conflict_types")
        object_readiness = Get-FieldValue -Object $conflict -Names @("object_readiness")
        decision_readiness = $decisionReadiness
        guard_edge_count = @($guards).Count
        guard_edge_types = Get-GroupCounts -Rows $guards -ColumnName "v2_relationship_type"
        participant_row_count = @($participants).Count
        participant_operations = Get-GroupCounts -Rows $participants -ColumnName "operation_type"
        participant_item_types = Get-GroupCounts -Rows $participants -ColumnName "item_type"
        linked_d3_source_targets = $d3TargetIdText
        linked_d4_source_ids = $d4SourceIdText
        recommended_d5_decision = $recommendedDecision
        readonly_action = $readonlyAction
        decision_template_path = $OutputDecisionTemplatePath
    }
    $controlRows.Add($controlRow) | Out-Null
    if ($closureOpportunity -eq "blocked_pending_d3_d4_closure") { $blockedRows.Add($controlRow) | Out-Null } else { $serializationRows.Add($controlRow) | Out-Null }

    $decisionRows.Add([pscustomobject]@{
        conflict_id = $conflictId
        object_key = $objectKey
        object_display_name = Get-FieldValue -Object $conflict -Names @("object_display_name")
        closure_opportunity = $closureOpportunity
        conflict_types = Get-FieldValue -Object $conflict -Names @("conflict_types")
        object_readiness = Get-FieldValue -Object $conflict -Names @("object_readiness")
        decision_readiness = $decisionReadiness
        proposed_decision = ""
        allowed_decisions = $allowedDecisions
        proposed_writer_order = ""
        proposed_reader_rule = ""
        proposed_execute_rule = ""
        safe_parallel_groups = ""
        blocked_reason = ""
        confirmation_source = ""
        confirmation_evidence = ""
        reviewer = ""
        reviewed_at = ""
        next_action = $recommendedDecision
        notes = "Fill this row before treating D5 as closed. Do not relax guard edges or promote parallelism without D3/D4 evidence and a reviewed decision."
    }) | Out-Null

    $readonlyRows.Add([pscustomobject]@{
        conflict_id = $conflictId
        priority_score = Get-FieldValue -Object $conflict -Names @("priority_score")
        priority_band = Get-FieldValue -Object $conflict -Names @("priority_band")
        closure_opportunity = $closureOpportunity
        object_display_name = Get-FieldValue -Object $conflict -Names @("object_display_name")
        conflict_types = Get-FieldValue -Object $conflict -Names @("conflict_types")
        object_readiness = Get-FieldValue -Object $conflict -Names @("object_readiness")
        decision_readiness = $decisionReadiness
        human_readonly_action = $readonlyAction
        linked_d3_source_targets = $d3TargetIdText
        linked_d4_source_ids = $d4SourceIdText
        decision_template_path = $OutputDecisionTemplatePath
        notes = "Read-only/manual D5 action. Do not update schedules, guard edges, or orchestration rules from this package alone."
    }) | Out-Null
}

foreach ($guard in $guardRows) {
    $conflictId = Get-FieldValue -Object $guard -Names @("conflict_id")
    $matching = @($controlRows | Where-Object { $_.conflict_id -eq $conflictId } | Select-Object -First 1)
    $closureOpportunity = if (@($matching).Count -gt 0) { $matching[0].closure_opportunity } else { "" }
    $guardDecisionRows.Add([pscustomobject]@{
        guard_id = Get-FieldValue -Object $guard -Names @("guard_id")
        conflict_id = $conflictId
        closure_opportunity = $closureOpportunity
        object_key = Get-FieldValue -Object $guard -Names @("object_key")
        upstream_qualified_name = Get-FieldValue -Object $guard -Names @("upstream_qualified_name")
        downstream_qualified_name = Get-FieldValue -Object $guard -Names @("downstream_qualified_name")
        v2_relationship_type = Get-FieldValue -Object $guard -Names @("v2_relationship_type")
        edge_status = Get-FieldValue -Object $guard -Names @("edge_status")
        confidence = Get-FieldValue -Object $guard -Names @("confidence")
        proposed_guard_action = ""
        allowed_guard_actions = "keep_guard; modify_guard; remove_false_conflict_guard; blocked_pending_d3_d4; manual_review_required"
        decision_template_path = $OutputDecisionTemplatePath
        notes = "Guard edge action must follow the conflict-level D5 decision."
    }) | Out-Null
}

foreach ($participant in $participantRows) {
    $targetKey = Get-D3TargetKey `
        -ObjectKey (Get-FieldValue -Object $participant -Names @("object_key")) `
        -OperationType (Get-FieldValue -Object $participant -Names @("operation_type"))
    $linkedD3Target = if ($d3TargetByObjectOperation.ContainsKey($targetKey)) { $d3TargetByObjectOperation[$targetKey] } else { "" }
    $objectKey = Get-FieldValue -Object $participant -Names @("object_key")
    $linkedD4Ids = @()
    $normalizedObjectKey = Normalize-Key -Value $objectKey
    if ($normalizedObjectKey -and $d4SourceIdsByObject.ContainsKey($normalizedObjectKey)) {
        $linkedD4Ids = @($d4SourceIdsByObject[$normalizedObjectKey] | Where-Object { $_ } | Sort-Object -Unique)
    }
    $participantReviewRows.Add([pscustomobject]@{
        participant_id = Get-FieldValue -Object $participant -Names @("participant_id")
        conflict_id = Get-FieldValue -Object $participant -Names @("conflict_id")
        object_key = $objectKey
        object_display_name = Get-FieldValue -Object $participant -Names @("object_display_name")
        item_qualified_name = Get-FieldValue -Object $participant -Names @("item_qualified_name")
        item_type = Get-FieldValue -Object $participant -Names @("item_type")
        operation_type = Get-FieldValue -Object $participant -Names @("operation_type")
        object_type = Get-FieldValue -Object $participant -Names @("object_type")
        object_type_status = Get-FieldValue -Object $participant -Names @("object_type_status")
        lineage_confidence = Get-FieldValue -Object $participant -Names @("lineage_confidence")
        scheduling_readiness = Get-FieldValue -Object $participant -Names @("scheduling_readiness")
        orchestration_parallel_readiness = Get-FieldValue -Object $participant -Names @("orchestration_parallel_readiness")
        linked_d3_source_target = $linkedD3Target
        linked_d4_source_ids = Limit-Text -Text ($linkedD4Ids -join "; ") -MaxLength 700
        evidence = Get-FieldValue -Object $participant -Names @("evidence")
    }) | Out-Null
}

$summaryRows = [System.Collections.Generic.List[object]]::new()
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D5 closure control rows"; row_count = @($controlRows).Count; notes = "One row per object conflict." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Blocked by D3/D4 rows"; row_count = @($blockedRows).Count; notes = "Conflicts not ready for serialization decisions until evidence closes." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Serialization review targets"; row_count = @($serializationRows).Count; notes = "Conflicts ready for D5 ordering/parallelism review." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Guard edge decision rows"; row_count = @($guardDecisionRows).Count; notes = "One row per object guard edge." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Participant review rows"; row_count = @($participantReviewRows).Count; notes = "One row per conflict participant." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D5 decision rows"; row_count = @($decisionRows).Count; notes = "One decision row per conflict." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "External read-only action rows"; row_count = @($readonlyRows).Count; notes = "One read-only/manual action per conflict." }) | Out-Null
foreach ($group in @($controlRows | Group-Object closure_opportunity | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "closure_opportunity"; group_key = $group.Name; row_count = $group.Count; notes = "D5 conflicts grouped by closure path." }) | Out-Null
}
foreach ($group in @($controlRows | Group-Object decision_readiness | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "decision_readiness"; group_key = $group.Name; row_count = $group.Count; notes = "D5 conflicts grouped by decision readiness." }) | Out-Null
}
foreach ($group in @($guardDecisionRows | Group-Object v2_relationship_type | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "guard_type"; group_key = $group.Name; row_count = $group.Count; notes = "Guard edges grouped by type." }) | Out-Null
}

$controlColumns = @(
    "conflict_id", "priority_score", "priority_band", "closure_opportunity", "object_key",
    "object_display_name", "source_types", "object_types", "reader_count", "writer_count",
    "executor_count", "exact_row_count", "ambiguous_row_count", "conflict_types",
    "object_readiness", "decision_readiness", "guard_edge_count", "guard_edge_types",
    "participant_row_count", "participant_operations", "participant_item_types",
    "linked_d3_source_targets", "linked_d4_source_ids", "recommended_d5_decision",
    "readonly_action", "decision_template_path"
)
$guardColumns = @(
    "guard_id", "conflict_id", "closure_opportunity", "object_key", "upstream_qualified_name",
    "downstream_qualified_name", "v2_relationship_type", "edge_status", "confidence",
    "proposed_guard_action", "allowed_guard_actions", "decision_template_path", "notes"
)
$participantColumns = @(
    "participant_id", "conflict_id", "object_key", "object_display_name", "item_qualified_name",
    "item_type", "operation_type", "object_type", "object_type_status", "lineage_confidence",
    "scheduling_readiness", "orchestration_parallel_readiness", "linked_d3_source_target",
    "linked_d4_source_ids", "evidence"
)
$decisionColumns = @(
    "conflict_id", "object_key", "object_display_name", "closure_opportunity", "conflict_types",
    "object_readiness", "decision_readiness", "proposed_decision", "allowed_decisions",
    "proposed_writer_order", "proposed_reader_rule", "proposed_execute_rule",
    "safe_parallel_groups", "blocked_reason", "confirmation_source", "confirmation_evidence",
    "reviewer", "reviewed_at", "next_action", "notes"
)
$readonlyColumns = @(
    "conflict_id", "priority_score", "priority_band", "closure_opportunity", "object_display_name",
    "conflict_types", "object_readiness", "decision_readiness", "human_readonly_action",
    "linked_d3_source_targets", "linked_d4_source_ids", "decision_template_path", "notes"
)
$summaryColumns = @("summary_scope", "group_key", "row_count", "notes")

Export-Rows -Rows @($controlRows) -Columns $controlColumns -Path $OutputControlQueuePath
Export-Rows -Rows @($blockedRows) -Columns $controlColumns -Path $OutputBlockedQueuePath
Export-Rows -Rows @($serializationRows) -Columns $controlColumns -Path $OutputSerializationTargetsPath
Export-Rows -Rows @($guardDecisionRows) -Columns $guardColumns -Path $OutputGuardDecisionQueuePath
Export-Rows -Rows @($participantReviewRows) -Columns $participantColumns -Path $OutputParticipantReviewPath
Export-Rows -Rows @($decisionRows) -Columns $decisionColumns -Path $OutputDecisionTemplatePath
Export-Rows -Rows @($readonlyRows) -Columns $readonlyColumns -Path $OutputReadonlyPlanPath
Export-Rows -Rows @($summaryRows) -Columns $summaryColumns -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D5 Closure Control") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated by backend/scripts/43_build_d5_closure_control.ps1 from local project artifacts only.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Start D5 closure without relaxing guard edges prematurely. Conflicts blocked by D3/D4 remain blocked, while serialization-ready conflicts are separated for writer/order/execute review.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- $OutputControlQueuePath") | Out-Null
$doc.Add("- $OutputBlockedQueuePath") | Out-Null
$doc.Add("- $OutputSerializationTargetsPath") | Out-Null
$doc.Add("- $OutputGuardDecisionQueuePath") | Out-Null
$doc.Add("- $OutputParticipantReviewPath") | Out-Null
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
$doc.Add('- Keep conflicts with `blocked_pending_d3_d4_closure` blocked until linked lineage and exact object-type evidence is closed or explicitly accepted.') | Out-Null
$doc.Add('- Review `analysis/d5_serialization_review_targets.csv` before any guard-edge changes because those are the only D5 rows currently ready for ordering decisions.') | Out-Null
$doc.Add("- Guard edge actions must follow the conflict-level decision; do not remove guard edges independently.") | Out-Null
$doc.Add("- No Fabric schedules, triggers, pipelines, or orchestration rules are changed by this package.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Next Human Step") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('Review `analysis/d5_serialization_review_targets.csv` first, and keep `analysis/d5_blocked_by_d3_d4_queue.csv` blocked until D3/D4 decisions are approved.') | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D5 closure control built."
Write-Host "Closure control rows: $(@($controlRows).Count)"
Write-Host "Blocked by D3/D4 rows: $(@($blockedRows).Count)"
Write-Host "Serialization review targets: $(@($serializationRows).Count)"
Write-Host "Guard edge decision rows: $(@($guardDecisionRows).Count)"
