# Phase 45 - D7 closure control: tracks which D7 (orchestration review/
# promotion, Phase 32) queue items have since been approved, but first
# checks whether each is still blocked on D6 (operational stability must
# be confirmed before promoting a wave) before considering it
# owner-approval-ready. Purely local.
# Writes: $OutputControlQueuePath, $OutputBlockedByD6Path,
# $OutputReadWriteTargetsPath, $OutputSourceReadinessTargetsPath,
# $OutputOwnerReadyTargetsPath, $OutputWaveClosurePath,
# $OutputDecisionTemplatePath, $OutputReadonlyPlanPath, $OutputSummaryPath,
# $OutputDocPath.
param(
    [string]$D7QueuePath = (Join-Path $PSScriptRoot "../../analysis/d7_orchestration_review_queue.csv"),
    [string]$D7CandidatePath = (Join-Path $PSScriptRoot "../../analysis/d7_nonprod_candidate_queue.csv"),
    [string]$D7WavePath = (Join-Path $PSScriptRoot "../../analysis/d7_wave_promotion_queue.csv"),
    [string]$D6ClosurePath = (Join-Path $PSScriptRoot "../../analysis/d6_closure_control_queue.csv"),
    [string]$OutputControlQueuePath = (Join-Path $PSScriptRoot "../../analysis/d7_closure_control_queue.csv"),
    [string]$OutputBlockedByD6Path = (Join-Path $PSScriptRoot "../../analysis/d7_blocked_by_d6_queue.csv"),
    [string]$OutputReadWriteTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d7_read_write_validation_targets.csv"),
    [string]$OutputSourceReadinessTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d7_source_readiness_targets.csv"),
    [string]$OutputOwnerReadyTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d7_owner_approval_ready_targets.csv"),
    [string]$OutputWaveClosurePath = (Join-Path $PSScriptRoot "../../analysis/d7_wave_closure_control.csv"),
    [string]$OutputDecisionTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d7_operational_decision_template.csv"),
    [string]$OutputReadonlyPlanPath = (Join-Path $PSScriptRoot "../../analysis/d7_external_readonly_action_plan.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d7_closure_control_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/41_d7_closure_control.md")
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

function Convert-ToDouble {
    param([object]$Value)
    $number = 0.0
    if ([double]::TryParse([string]$Value, [ref]$number)) { return $number }
    return 0.0
}

function Limit-Text {
    param([string]$Text, [int]$MaxLength = 900)
    if (-not $Text) { return "" }
    $clean = ($Text -replace "\s+", " ").Trim()
    if ($clean.Length -le $MaxLength) { return $clean }
    return $clean.Substring(0, $MaxLength - 3) + "..."
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

function Get-ClosureOpportunity {
    param([string]$PromotionReadiness, [string]$PromotionPath)

    switch ($PromotionReadiness) {
        "blocked_pending_d6_stabilization" { return "blocked_pending_d6_closure" }
        "blocked_pending_read_write_validation" { return "blocked_pending_read_write_validation" }
        "source_readiness_review" { return "source_readiness_review_required" }
        "ready_for_owner_review" { return "owner_promotion_approval_ready" }
        "manual_governance_review" { return "manual_governance_review_required" }
        "existing_orchestrator_review" { return "existing_orchestrator_review_required" }
        "blocked_pending_duration_evidence" { return "blocked_pending_duration_evidence" }
        "blocked_pending_dependency_confirmation" { return "blocked_pending_dependency_confirmation" }
        default {
            if ($PromotionPath -eq "governance_or_manual_check") { return "manual_governance_review_required" }
            if ($PromotionPath -eq "contained_child_activity_review") { return "existing_orchestrator_review_required" }
            return "manual_promotion_review_required"
        }
    }
}

function Get-RecommendedDecision {
    param([string]$ClosureOpportunity, [string]$PromotionPath)

    switch ($ClosureOpportunity) {
        "blocked_pending_d6_closure" { return "Keep blocked until linked D6 failure/duration row is stabilized, owner-accepted, excluded, or explicitly blocked." }
        "blocked_pending_read_write_validation" { return "Keep blocked until read/write validation and conflict guard evidence are reviewed." }
        "source_readiness_review_required" { return "Decide source_check or blocked after owner confirms the source readiness semantics and timing." }
        "owner_promotion_approval_ready" {
            switch ($PromotionPath) {
                "standalone_process_candidate" { return "Approve nonprod_run only after owner confirms scope, dependencies, duration, and rollback expectations." }
                "semantic_refresh_candidate" { return "Approve semantic_refresh only after upstream readiness and model owner validation." }
                "consumption_validation_check" { return "Approve consumption_check only after expected report or consumer validation is clear." }
                "existing_orchestrator_candidate" { return "Decide existing_orchestrator, nonprod_run, keep_manual, or blocked after owner review." }
                default { return "Approve the D7 action only after owner validation and explicit non-production scope." }
            }
        }
        "manual_governance_review_required" { return "Keep manual or exclude unless a supported automated action and owner are identified." }
        "existing_orchestrator_review_required" { return "Keep child activity unless the owner approves refactoring outside the existing orchestrator." }
        default { return "Record an explicit D7 decision before any non-production design promotion." }
    }
}

function Get-ReadonlyAction {
    param([string]$ClosureOpportunity)

    switch ($ClosureOpportunity) {
        "blocked_pending_d6_closure" { return "Review linked D6 closure row first; do not promote this D7 row while failure or duration evidence remains unresolved." }
        "blocked_pending_read_write_validation" { return "Review read/write classification, object conflicts, and guard edges before approving any run or parallel step." }
        "source_readiness_review_required" { return "Confirm source owner, availability window, freshness signal, and whether the check is manual or automatable." }
        "owner_promotion_approval_ready" { return "Review owner, environment, dependencies, duration, schedules, and non-production blast radius before selecting a D7 decision." }
        "manual_governance_review_required" { return "Review governance/manual constraints and decide keep_manual, exclude, blocked, or a supported automation path." }
        "existing_orchestrator_review_required" { return "Review parent orchestrator behavior and decide keep_child_activity, existing_orchestrator, exclude, or blocked." }
        default { return "Review local evidence and owner evidence before selecting a D7 decision." }
    }
}

function Get-WaveClosureStatus {
    param([object[]]$Rows)

    $blockedRows = @($Rows | Where-Object { $_.closure_opportunity -like "blocked_*" })
    if (@($blockedRows).Count -gt 0) { return "blocked_pending_row_closure" }
    $sourceRows = @($Rows | Where-Object { $_.closure_opportunity -eq "source_readiness_review_required" })
    if (@($sourceRows).Count -gt 0) { return "source_readiness_wave_review" }
    $ownerRows = @($Rows | Where-Object { $_.closure_opportunity -eq "owner_promotion_approval_ready" })
    if (@($ownerRows).Count -eq @($Rows).Count -and @($Rows).Count -gt 0) { return "ready_for_owner_wave_review" }
    return "manual_wave_review_required"
}

function Get-WaveRecommendedAction {
    param([string]$WaveClosureStatus)

    switch ($WaveClosureStatus) {
        "blocked_pending_row_closure" { return "Do not promote this wave; close blocked D7 rows and upstream D1-D6 blockers first." }
        "source_readiness_wave_review" { return "Review source checks and owner semantics before this wave enters non-production design." }
        "ready_for_owner_wave_review" { return "Wave can be reviewed for scoped non-production design after owner approvals are recorded." }
        default { return "Review wave rows manually and record explicit decisions before promotion." }
    }
}

if (-not (Test-Path $D7QueuePath)) {
    throw "Required input not found: $D7QueuePath"
}

$d7Rows = @(Import-Csv -Path $D7QueuePath)
$candidateRows = Import-OptionalCsv -Path $D7CandidatePath
$waveRows = Import-OptionalCsv -Path $D7WavePath
$d6ClosureRows = Import-OptionalCsv -Path $D6ClosurePath

$candidateByD7 = @{}
foreach ($row in $candidateRows) {
    $d7Id = Get-FieldValue -Object $row -Names @("d7_id")
    if ($d7Id -and -not $candidateByD7.ContainsKey($d7Id)) { $candidateByD7[$d7Id] = $row }
}

$d6ById = @{}
foreach ($row in $d6ClosureRows) {
    $d6Id = Get-FieldValue -Object $row -Names @("d6_id")
    if ($d6Id -and -not $d6ById.ContainsKey($d6Id)) { $d6ById[$d6Id] = $row }
}

$controlRows = [System.Collections.Generic.List[object]]::new()
$blockedByD6Rows = [System.Collections.Generic.List[object]]::new()
$readWriteRows = [System.Collections.Generic.List[object]]::new()
$sourceReadinessRows = [System.Collections.Generic.List[object]]::new()
$ownerReadyRows = [System.Collections.Generic.List[object]]::new()
$decisionRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()

foreach ($row in ($d7Rows | Sort-Object @{ Expression = { Convert-ToInt (Get-FieldValue -Object $_ -Names @("priority_score")) }; Descending = $true }, d7_id)) {
    $d7Id = Get-FieldValue -Object $row -Names @("d7_id")
    $candidate = if ($candidateByD7.ContainsKey($d7Id)) { $candidateByD7[$d7Id] } else { $null }
    $d6BlockerId = Get-FieldValue -Object $row -Names @("d6_blocker_id")
    $d6Blocker = if ($d6BlockerId -and $d6ById.ContainsKey($d6BlockerId)) { $d6ById[$d6BlockerId] } else { $null }
    $promotionReadiness = Get-FieldValue -Object $row -Names @("promotion_readiness")
    $promotionPath = Get-FieldValue -Object $row -Names @("promotion_path")
    $closureOpportunity = Get-ClosureOpportunity -PromotionReadiness $promotionReadiness -PromotionPath $promotionPath
    $recommendedDecision = Get-RecommendedDecision -ClosureOpportunity $closureOpportunity -PromotionPath $promotionPath
    $readonlyAction = Get-ReadonlyAction -ClosureOpportunity $closureOpportunity
    $allowedDecisions = "nonprod_run; source_check; semantic_refresh; consumption_check; existing_orchestrator; keep_manual; keep_child_activity; exclude; blocked; manual_review_required"

    $controlRow = [pscustomobject]@{
        d7_id = $d7Id
        priority_score = Get-FieldValue -Object $row -Names @("priority_score")
        priority_band = Get-FieldValue -Object $row -Names @("priority_band")
        closure_opportunity = $closureOpportunity
        promotion_path = $promotionPath
        candidate_scope = Get-FieldValue -Object $row -Names @("candidate_scope")
        promotion_readiness = $promotionReadiness
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $row -Names @("workspace_environment")
        workspace_type = Get-FieldValue -Object $row -Names @("workspace_type")
        deployment_pipelines = Get-FieldValue -Object $row -Names @("deployment_pipelines")
        item_type = Get-FieldValue -Object $row -Names @("item_type")
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        item_qualified_name = Get-FieldValue -Object $row -Names @("item_qualified_name")
        v2_wave_index = Get-FieldValue -Object $row -Names @("v2_wave_index")
        proposed_stage = Get-FieldValue -Object $row -Names @("proposed_stage")
        orchestration_role = Get-FieldValue -Object $row -Names @("orchestration_role")
        action_type = Get-FieldValue -Object $row -Names @("action_type")
        is_master_action = Get-FieldValue -Object $row -Names @("is_master_action")
        estimated_duration_seconds = Get-FieldValue -Object $row -Names @("estimated_duration_seconds")
        duration_source = Get-FieldValue -Object $row -Names @("duration_source")
        predecessor_count = Get-FieldValue -Object $row -Names @("predecessor_count")
        successor_count = Get-FieldValue -Object $row -Names @("successor_count")
        run_count = Get-FieldValue -Object $row -Names @("run_count")
        failed_count = Get-FieldValue -Object $row -Names @("failed_count")
        manual_count = Get-FieldValue -Object $row -Names @("manual_count")
        scheduled_count = Get-FieldValue -Object $row -Names @("scheduled_count")
        enabled_schedules = Get-FieldValue -Object $row -Names @("enabled_schedules")
        disabled_schedules = Get-FieldValue -Object $row -Names @("disabled_schedules")
        schedule_signal = Get-FieldValue -Object $row -Names @("schedule_signal")
        repeated_manual_signal = Get-FieldValue -Object $row -Names @("repeated_manual_signal")
        fanout_signal = Get-FieldValue -Object $row -Names @("fanout_signal")
        d6_blocker_id = $d6BlockerId
        d6_closure_opportunity = Get-FieldValue -Object $d6Blocker -Names @("closure_opportunity")
        d6_decision_readiness = Get-FieldValue -Object $row -Names @("d6_decision_readiness")
        d6_failure_rate = Get-FieldValue -Object $d6Blocker -Names @("failure_rate")
        original_risk_flags = Get-FieldValue -Object $row -Names @("original_risk_flags")
        human_validation_required = Get-FieldValue -Object $row -Names @("human_validation_required")
        candidate_status = Get-FieldValue -Object $candidate -Names @("candidate_status")
        nonprod_gate = Get-FieldValue -Object $candidate -Names @("nonprod_gate")
        recommended_d7_decision = $recommendedDecision
        readonly_action = $readonlyAction
        decision_template_path = $OutputDecisionTemplatePath
    }
    $controlRows.Add($controlRow) | Out-Null

    switch ($closureOpportunity) {
        "blocked_pending_d6_closure" { $blockedByD6Rows.Add($controlRow) | Out-Null }
        "blocked_pending_read_write_validation" { $readWriteRows.Add($controlRow) | Out-Null }
        "source_readiness_review_required" { $sourceReadinessRows.Add($controlRow) | Out-Null }
        "owner_promotion_approval_ready" { $ownerReadyRows.Add($controlRow) | Out-Null }
    }

    $decisionRows.Add([pscustomobject]@{
        d7_id = $d7Id
        item_qualified_name = Get-FieldValue -Object $row -Names @("item_qualified_name")
        promotion_path = $promotionPath
        candidate_scope = Get-FieldValue -Object $row -Names @("candidate_scope")
        promotion_readiness = $promotionReadiness
        closure_opportunity = $closureOpportunity
        current_action_type = Get-FieldValue -Object $row -Names @("action_type")
        current_v2_wave_index = Get-FieldValue -Object $row -Names @("v2_wave_index")
        current_duration_source = Get-FieldValue -Object $row -Names @("duration_source")
        linked_d6_blocker_id = $d6BlockerId
        proposed_d7_decision = ""
        allowed_decisions = $allowedDecisions
        proposed_nonprod_scope = ""
        proposed_wave = ""
        proposed_schedule_handling = ""
        proposed_owner_validation = ""
        include_in_master_pipeline_design = ""
        blocked_reason = ""
        owner = ""
        confirmation_source = ""
        confirmation_evidence = ""
        reviewer = ""
        reviewed_at = ""
        next_action = $recommendedDecision
        notes = "Fill this row before treating D7 as closed. Do not create, modify, trigger, schedule, deploy, or refactor Fabric assets from this package alone."
    }) | Out-Null

    $readonlyRows.Add([pscustomobject]@{
        d7_id = $d7Id
        priority_score = Get-FieldValue -Object $row -Names @("priority_score")
        priority_band = Get-FieldValue -Object $row -Names @("priority_band")
        closure_opportunity = $closureOpportunity
        item_qualified_name = Get-FieldValue -Object $row -Names @("item_qualified_name")
        promotion_path = $promotionPath
        candidate_scope = Get-FieldValue -Object $row -Names @("candidate_scope")
        promotion_readiness = $promotionReadiness
        human_readonly_action = $readonlyAction
        linked_d6_blocker_id = $d6BlockerId
        linked_d6_closure_opportunity = Get-FieldValue -Object $d6Blocker -Names @("closure_opportunity")
        decision_template_path = $OutputDecisionTemplatePath
        notes = "Read-only/manual D7 action. Last operational step remains human approval and execution outside this repo."
    }) | Out-Null
}

$controlByWave = @{}
foreach ($row in $controlRows) {
    Add-ListMapValue -Map $controlByWave -Key (Get-FieldValue -Object $row -Names @("v2_wave_index")) -Value $row
}

$waveClosureRows = [System.Collections.Generic.List[object]]::new()
foreach ($wave in ($waveRows | Sort-Object @{ Expression = { Convert-ToInt (Get-FieldValue -Object $_ -Names @("v2_wave_index")) } })) {
    $waveIndex = Get-FieldValue -Object $wave -Names @("v2_wave_index")
    $rows = if ($controlByWave.ContainsKey($waveIndex)) { @($controlByWave[$waveIndex]) } else { @() }
    $waveClosureStatus = Get-WaveClosureStatus -Rows $rows
    $waveClosureRows.Add([pscustomobject]@{
        d7_wave_id = Get-FieldValue -Object $wave -Names @("d7_wave_id")
        v2_wave_index = $waveIndex
        d7_row_count = @($rows).Count
        nonprod_candidate_count = Get-FieldValue -Object $wave -Names @("nonprod_candidate_count")
        blocked_candidate_count = @($rows | Where-Object { $_.closure_opportunity -like "blocked_*" }).Count
        source_readiness_count = @($rows | Where-Object { $_.closure_opportunity -eq "source_readiness_review_required" }).Count
        owner_ready_count = @($rows | Where-Object { $_.closure_opportunity -eq "owner_promotion_approval_ready" }).Count
        closure_opportunity_split = Get-GroupCounts -Rows $rows -ColumnName "closure_opportunity"
        promotion_paths = Get-FieldValue -Object $wave -Names @("promotion_paths")
        candidate_scopes = Get-FieldValue -Object $wave -Names @("candidate_scopes")
        readiness_breakdown = Get-FieldValue -Object $wave -Names @("readiness_breakdown")
        source_wave_node_count = Get-FieldValue -Object $wave -Names @("source_wave_node_count")
        wave_closure_status = $waveClosureStatus
        recommended_wave_action = Get-WaveRecommendedAction -WaveClosureStatus $waveClosureStatus
        d7_gate_to_promote = Get-FieldValue -Object $wave -Names @("d7_gate_to_promote")
    }) | Out-Null
}

$summaryRows = [System.Collections.Generic.List[object]]::new()
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D7 closure control rows"; row_count = @($controlRows).Count; notes = "One row per D7 orchestration review item." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Blocked by D6 rows"; row_count = @($blockedByD6Rows).Count; notes = "Rows blocked until linked D6 stabilization closes or is accepted." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Read/write validation rows"; row_count = @($readWriteRows).Count; notes = "Rows blocked by read/write validation before promotion." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Source readiness rows"; row_count = @($sourceReadinessRows).Count; notes = "Rows requiring source readiness semantics and owner review." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Owner approval ready rows"; row_count = @($ownerReadyRows).Count; notes = "Rows ready for explicit owner approval and scoped non-production design." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Wave closure rows"; row_count = @($waveClosureRows).Count; notes = "One row per D7 wave." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D7 decision rows"; row_count = @($decisionRows).Count; notes = "One decision row per D7 item." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "External read-only action rows"; row_count = @($readonlyRows).Count; notes = "One read-only/manual action per D7 item." }) | Out-Null
foreach ($group in @($controlRows | Group-Object closure_opportunity | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "closure_opportunity"; group_key = $group.Name; row_count = $group.Count; notes = "D7 items grouped by closure path." }) | Out-Null
}
foreach ($group in @($controlRows | Group-Object promotion_path | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "promotion_path"; group_key = $group.Name; row_count = $group.Count; notes = "D7 items grouped by promotion path." }) | Out-Null
}
foreach ($group in @($controlRows | Group-Object promotion_readiness | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "promotion_readiness"; group_key = $group.Name; row_count = $group.Count; notes = "D7 items grouped by promotion readiness." }) | Out-Null
}
foreach ($group in @($controlRows | Group-Object item_type | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "item_type"; group_key = $group.Name; row_count = $group.Count; notes = "D7 items grouped by item type." }) | Out-Null
}
foreach ($group in @($waveClosureRows | Group-Object wave_closure_status | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "wave_closure_status"; group_key = $group.Name; row_count = $group.Count; notes = "D7 waves grouped by closure status." }) | Out-Null
}

$controlColumns = @(
    "d7_id", "priority_score", "priority_band", "closure_opportunity", "promotion_path",
    "candidate_scope", "promotion_readiness", "workspace_name", "workspace_environment",
    "workspace_type", "deployment_pipelines", "item_type", "item_name", "item_qualified_name",
    "v2_wave_index", "proposed_stage", "orchestration_role", "action_type",
    "is_master_action", "estimated_duration_seconds", "duration_source", "predecessor_count",
    "successor_count", "run_count", "failed_count", "manual_count", "scheduled_count",
    "enabled_schedules", "disabled_schedules", "schedule_signal", "repeated_manual_signal",
    "fanout_signal", "d6_blocker_id", "d6_closure_opportunity", "d6_decision_readiness",
    "d6_failure_rate", "original_risk_flags", "human_validation_required",
    "candidate_status", "nonprod_gate", "recommended_d7_decision", "readonly_action",
    "decision_template_path"
)
$waveColumns = @(
    "d7_wave_id", "v2_wave_index", "d7_row_count", "nonprod_candidate_count",
    "blocked_candidate_count", "source_readiness_count", "owner_ready_count",
    "closure_opportunity_split", "promotion_paths", "candidate_scopes",
    "readiness_breakdown", "source_wave_node_count", "wave_closure_status",
    "recommended_wave_action", "d7_gate_to_promote"
)
$decisionColumns = @(
    "d7_id", "item_qualified_name", "promotion_path", "candidate_scope",
    "promotion_readiness", "closure_opportunity", "current_action_type",
    "current_v2_wave_index", "current_duration_source", "linked_d6_blocker_id",
    "proposed_d7_decision", "allowed_decisions", "proposed_nonprod_scope",
    "proposed_wave", "proposed_schedule_handling", "proposed_owner_validation",
    "include_in_master_pipeline_design", "blocked_reason", "owner",
    "confirmation_source", "confirmation_evidence", "reviewer", "reviewed_at",
    "next_action", "notes"
)
$readonlyColumns = @(
    "d7_id", "priority_score", "priority_band", "closure_opportunity",
    "item_qualified_name", "promotion_path", "candidate_scope", "promotion_readiness",
    "human_readonly_action", "linked_d6_blocker_id", "linked_d6_closure_opportunity",
    "decision_template_path", "notes"
)
$summaryColumns = @("summary_scope", "group_key", "row_count", "notes")

Export-Rows -Rows @($controlRows) -Columns $controlColumns -Path $OutputControlQueuePath
Export-Rows -Rows @($blockedByD6Rows) -Columns $controlColumns -Path $OutputBlockedByD6Path
Export-Rows -Rows @($readWriteRows) -Columns $controlColumns -Path $OutputReadWriteTargetsPath
Export-Rows -Rows @($sourceReadinessRows) -Columns $controlColumns -Path $OutputSourceReadinessTargetsPath
Export-Rows -Rows @($ownerReadyRows) -Columns $controlColumns -Path $OutputOwnerReadyTargetsPath
Export-Rows -Rows @($waveClosureRows) -Columns $waveColumns -Path $OutputWaveClosurePath
Export-Rows -Rows @($decisionRows) -Columns $decisionColumns -Path $OutputDecisionTemplatePath
Export-Rows -Rows @($readonlyRows) -Columns $readonlyColumns -Path $OutputReadonlyPlanPath
Export-Rows -Rows @($summaryRows) -Columns $summaryColumns -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D7 Closure Control") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated by backend/scripts/45_build_d7_closure_control.ps1 from local project artifacts only.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Start D7 closure by separating orchestration promotion rows that are blocked by D6, blocked by read/write validation, waiting for source readiness review, or ready for owner approval. This package does not approve, deploy, schedule, trigger, or refactor anything.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- $OutputControlQueuePath") | Out-Null
$doc.Add("- $OutputBlockedByD6Path") | Out-Null
$doc.Add("- $OutputReadWriteTargetsPath") | Out-Null
$doc.Add("- $OutputSourceReadinessTargetsPath") | Out-Null
$doc.Add("- $OutputOwnerReadyTargetsPath") | Out-Null
$doc.Add("- $OutputWaveClosurePath") | Out-Null
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
$doc.Add('- Keep `blocked_pending_d6_closure` rows blocked until linked D6 rows have reviewed stabilization or explicit acceptance.') | Out-Null
$doc.Add('- Keep `blocked_pending_read_write_validation` rows blocked until read/write validation and conflict guard evidence are reviewed.') | Out-Null
$doc.Add('- Use `analysis/d7_owner_approval_ready_targets.csv` as the only current short-list for scoped owner approval, then record decisions in `analysis/d7_operational_decision_template.csv`.') | Out-Null
$doc.Add('- Wave promotion is advisory only; do not move a wave into non-production design until every row has an approved D7 decision.') | Out-Null
$doc.Add('- No Fabric pipelines, schedules, triggers, deployment pipelines, repositories, or orchestration rules are changed by this package.') | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Next Human Step") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('Review `analysis/d7_owner_approval_ready_targets.csv` first for the rows ready for owner approval, then keep `analysis/d7_blocked_by_d6_queue.csv` blocked until D6 decisions are approved.') | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D7 closure control built."
Write-Host "Closure control rows: $(@($controlRows).Count)"
Write-Host "Blocked by D6 rows: $(@($blockedByD6Rows).Count)"
Write-Host "Read/write validation rows: $(@($readWriteRows).Count)"
Write-Host "Owner approval ready rows: $(@($ownerReadyRows).Count)"
