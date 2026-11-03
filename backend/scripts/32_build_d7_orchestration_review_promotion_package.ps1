# Phase 32 - D7 package: the cleanup-plan category for reviewing and
# promoting the orchestration v2 plan itself (e.g. non-prod workspace
# candidates, wave-by-wave promotion decisions) -- packages a queue plus a
# manual promotion decision template. Purely local.
# Writes: $OutputQueuePath, $OutputCandidatePath, $OutputWavePath,
# $OutputSummaryPath, $OutputDecisionTemplatePath,
# $OutputReadonlyTargetsPath, $OutputDocPath.
param(
    [string]$OrchestrationV2PlanPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_plan.csv"),
    [string]$OrchestrationV2WavesPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_waves.csv"),
    [string]$CleanupQueuePath = (Join-Path $PSScriptRoot "../../analysis/likely_conflict_cleanup_queue.csv"),
    [string]$D6QueuePath = (Join-Path $PSScriptRoot "../../analysis/d6_failure_duration_queue.csv"),
    [string]$ScheduleReviewPath = (Join-Path $PSScriptRoot "../../analysis/schedule_review_candidates.csv"),
    [string]$ManualExecutionPath = (Join-Path $PSScriptRoot "../../analysis/manual_execution_candidates.csv"),
    [string]$OrchestrationGroupPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_group_candidates.csv"),
    [string]$WorkspacesPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$DeploymentPipelineGroupsPath = (Join-Path $PSScriptRoot "../../analysis/deployment_pipeline_workspace_groups.csv"),
    [string]$OutputQueuePath = (Join-Path $PSScriptRoot "../../analysis/d7_orchestration_review_queue.csv"),
    [string]$OutputCandidatePath = (Join-Path $PSScriptRoot "../../analysis/d7_nonprod_candidate_queue.csv"),
    [string]$OutputWavePath = (Join-Path $PSScriptRoot "../../analysis/d7_wave_promotion_queue.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d7_orchestration_review_summary.csv"),
    [string]$OutputDecisionTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d7_promotion_decision_template.csv"),
    [string]$OutputReadonlyTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d7_readonly_promotion_targets.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/29_d7_orchestration_review_promotion.md")
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

function Import-OptionalCsv {
    param([string]$Path)
    if (Test-Path $Path) { return @(Import-Csv -Path $Path) }
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
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    try { return [int][double]$Value } catch { return 0 }
}

function Convert-ToDouble {
    param([object]$Value)
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return 0.0
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

function Set-FirstMapValue {
    param([hashtable]$Map, [string]$Key, [object]$Value)
    $normalized = Normalize-Key -Value $Key
    if ($normalized -and -not $Map.ContainsKey($normalized)) {
        $Map[$normalized] = $Value
    }
}

function Add-MapListValue {
    param([hashtable]$Map, [string]$Key, [object]$Value)
    $normalized = Normalize-Key -Value $Key
    if (-not $normalized) { return }
    if (-not $Map.ContainsKey($normalized)) {
        $Map[$normalized] = [System.Collections.Generic.List[object]]::new()
    }
    $Map[$normalized].Add($Value) | Out-Null
}

function Get-MapValue {
    param([hashtable]$Map, [string]$Key)
    $normalized = Normalize-Key -Value $Key
    if ($normalized -and $Map.ContainsKey($normalized)) { return $Map[$normalized] }
    return $null
}

function Get-PriorityBand {
    param([int]$PriorityScore)
    if ($PriorityScore -ge 85) { return "critical" }
    if ($PriorityScore -ge 75) { return "high" }
    if ($PriorityScore -ge 65) { return "medium" }
    return "low"
}

function Get-PromotionPath {
    param([string]$ActionType, [string]$Role)
    switch ($ActionType) {
        "check_source_readiness" { return "source_readiness_check" }
        "run_standalone_process" { return "standalone_process_candidate" }
        "run_existing_orchestrator_or_refactor_branches" { return "existing_orchestrator_candidate" }
        "child_activity_inside_existing_orchestrator" { return "contained_child_activity_review" }
        "refresh_semantic_model_after_upstream_readiness" { return "semantic_refresh_candidate" }
        "validate_report_after_model_refresh" { return "consumption_validation_check" }
        "review_governance_or_unsupported_item" { return "governance_or_manual_check" }
        default {
            if ($Role -eq "source_readiness") { return "source_readiness_check" }
            if ($Role -eq "data_process") { return "data_process_review" }
            if ($Role -eq "semantic_refresh") { return "semantic_refresh_candidate" }
            if ($Role -eq "consumption_validation") { return "consumption_validation_check" }
            return "manual_orchestration_review"
        }
    }
}

function Get-CandidateScope {
    param([string]$PromotionPath)
    switch ($PromotionPath) {
        "source_readiness_check" { return "master_pipeline_check" }
        "standalone_process_candidate" { return "nonprod_run_candidate" }
        "existing_orchestrator_candidate" { return "nonprod_orchestrator_candidate" }
        "contained_child_activity_review" { return "existing_orchestrator_child_review" }
        "semantic_refresh_candidate" { return "semantic_refresh_candidate" }
        "consumption_validation_check" { return "post_refresh_validation_check" }
        "governance_or_manual_check" { return "manual_governance_check" }
        default { return "manual_review" }
    }
}

function Get-PromotionReadiness {
    param(
        [string]$PromotionPath,
        [string]$DurationSource,
        [object]$D6Row,
        [string]$RiskFlags
    )
    if ($null -ne $D6Row) { return "blocked_pending_d6_stabilization" }
    if ($PromotionPath -eq "source_readiness_check") { return "source_readiness_review" }
    if ($RiskFlags -like "*has_likely_dependency_evidence*") { return "blocked_pending_dependency_confirmation" }
    if ($RiskFlags -like "*notebook_read_write_validation_required*") { return "blocked_pending_read_write_validation" }
    if ($PromotionPath -eq "governance_or_manual_check") { return "manual_governance_review" }
    if ($PromotionPath -eq "contained_child_activity_review") { return "existing_orchestrator_review" }
    if ($DurationSource -eq "default_by_role") { return "blocked_pending_duration_evidence" }
    return "ready_for_owner_review"
}

function Get-RecommendedAction {
    param([string]$PromotionPath, [string]$PlanAction, [string]$PromotionReadiness)
    if ($PromotionReadiness -eq "blocked_pending_d6_stabilization") {
        return "Resolve D6 failure/duration stabilization before promoting this row into a non-production orchestration design."
    }
    if ($PlanAction) { return $PlanAction }
    switch ($PromotionPath) {
        "source_readiness_check" { return "Confirm source readiness check semantics and owner before adding this as a master pipeline precondition." }
        "standalone_process_candidate" { return "Review owner, dependencies, duration, and non-production scope before adding this item as a runnable process step." }
        "existing_orchestrator_candidate" { return "Review whether the existing orchestrator should remain the executable boundary or be refactored into explicit branches." }
        "contained_child_activity_review" { return "Keep as child activity unless the owner approves explicit orchestration outside the existing parent." }
        "semantic_refresh_candidate" { return "Review upstream readiness and model refresh ownership before adding this as a semantic refresh step." }
        "consumption_validation_check" { return "Confirm report/consumption validation expectations after model refresh before adding it as a check." }
        "governance_or_manual_check" { return "Keep as governance/manual check unless a supported automated action is approved." }
        default { return "Record approved D7 action before promotion." }
    }
}

function Escape-MdCell {
    param([string]$Value)
    if (-not $Value) { return "" }
    return (($Value -replace "\|", "/") -replace "`r?`n", " ").Trim()
}

foreach ($path in @($OrchestrationV2PlanPath, $OrchestrationV2WavesPath, $CleanupQueuePath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$planRows = @(Import-Csv -Path $OrchestrationV2PlanPath)
$waveRows = @(Import-Csv -Path $OrchestrationV2WavesPath)
$cleanupRows = @(Import-Csv -Path $CleanupQueuePath)
$d6Rows = Import-OptionalCsv -Path $D6QueuePath
$scheduleRows = Import-OptionalCsv -Path $ScheduleReviewPath
$manualRows = Import-OptionalCsv -Path $ManualExecutionPath
$fanoutRows = Import-OptionalCsv -Path $OrchestrationGroupPath
$workspaceRows = Import-OptionalCsv -Path $WorkspacesPath
$deploymentGroupRows = Import-OptionalCsv -Path $DeploymentPipelineGroupsPath

$d7CleanupByQualifiedName = @{}
foreach ($row in ($cleanupRows | Where-Object { $_.phase_id -eq "D7" })) {
    Set-FirstMapValue -Map $d7CleanupByQualifiedName -Key (Get-FieldValue -Object $row -Names @("item_qualified_name")) -Value $row
}

$d6ByQualifiedName = @{}
foreach ($row in $d6Rows) {
    Set-FirstMapValue -Map $d6ByQualifiedName -Key (Get-FieldValue -Object $row -Names @("item_qualified_name")) -Value $row
}

$scheduleByQualifiedName = @{}
foreach ($row in $scheduleRows) {
    Set-FirstMapValue -Map $scheduleByQualifiedName -Key (Get-FieldValue -Object $row -Names @("qualified_name", "item_qualified_name")) -Value $row
}

$manualByQualifiedName = @{}
foreach ($row in $manualRows) {
    Set-FirstMapValue -Map $manualByQualifiedName -Key (Get-FieldValue -Object $row -Names @("qualified_name", "item_qualified_name")) -Value $row
}

$fanoutByQualifiedName = @{}
foreach ($row in $fanoutRows) {
    Set-FirstMapValue -Map $fanoutByQualifiedName -Key (Get-FieldValue -Object $row -Names @("source_qualified_name", "qualified_name", "item_qualified_name")) -Value $row
}

$workspaceByName = @{}
foreach ($row in $workspaceRows) {
    Set-FirstMapValue -Map $workspaceByName -Key (Get-FieldValue -Object $row -Names @("workspace_name")) -Value $row
}

$deploymentGroupsByWorkspace = @{}
foreach ($row in $deploymentGroupRows) {
    $names = (Get-FieldValue -Object $row -Names @("workspace_names")) -split ";"
    foreach ($name in $names) {
        $trimmed = $name.Trim()
        if ($trimmed) { Add-MapListValue -Map $deploymentGroupsByWorkspace -Key $trimmed -Value $row }
    }
}

$candidateRows = @($planRows | Where-Object { $_.v2_status -eq "needs_orchestration_review" })
$queueRows = [System.Collections.Generic.List[object]]::new()
$candidateOutputRows = [System.Collections.Generic.List[object]]::new()
$decisionRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()
$sequence = 0

foreach ($row in ($candidateRows | Sort-Object @{ Expression = {
    $cleanup = Get-MapValue -Map $d7CleanupByQualifiedName -Key (Get-FieldValue -Object $_ -Names @("qualified_name"))
    Convert-ToInt (Get-FieldValue -Object $cleanup -Names @("priority_score"))
}; Descending = $true }, v2_wave_index, workspace_name, item_type, item_name)) {
    $sequence += 1
    $d7Id = "D7I{0:D5}" -f $sequence
    $qualifiedName = Get-FieldValue -Object $row -Names @("qualified_name")
    $cleanup = Get-MapValue -Map $d7CleanupByQualifiedName -Key $qualifiedName
    $d6 = Get-MapValue -Map $d6ByQualifiedName -Key $qualifiedName
    $schedule = Get-MapValue -Map $scheduleByQualifiedName -Key $qualifiedName
    $manual = Get-MapValue -Map $manualByQualifiedName -Key $qualifiedName
    $fanout = Get-MapValue -Map $fanoutByQualifiedName -Key $qualifiedName
    $workspace = Get-MapValue -Map $workspaceByName -Key (Get-FieldValue -Object $row -Names @("workspace_name"))
    $deploymentGroups = Get-MapValue -Map $deploymentGroupsByWorkspace -Key (Get-FieldValue -Object $row -Names @("workspace_name"))

    $promotionPath = Get-PromotionPath -ActionType (Get-FieldValue -Object $row -Names @("action_type")) -Role (Get-FieldValue -Object $row -Names @("orchestration_role"))
    $candidateScope = Get-CandidateScope -PromotionPath $promotionPath
    $durationSource = Get-FieldValue -Object $row -Names @("duration_source")
    $riskFlags = Get-FieldValue -Object $row -Names @("original_risk_flags")
    $promotionReadiness = Get-PromotionReadiness -PromotionPath $promotionPath -DurationSource $durationSource -D6Row $d6 -RiskFlags $riskFlags
    $priorityScore = Convert-ToInt (Get-FieldValue -Object $cleanup -Names @("priority_score"))
    if ($priorityScore -eq 0) {
        $priorityScore = 60 + (Convert-ToInt (Get-FieldValue -Object $row -Names @("successor_count"))) + (Convert-ToInt (Get-FieldValue -Object $row -Names @("enabled_schedules")))
        if ($riskFlags -like "*critical_path_candidate*") { $priorityScore += 10 }
        if ($riskFlags -like "*repeated_manual_candidate*") { $priorityScore += 8 }
        if ($riskFlags -like "*schedule_review_required*") { $priorityScore += 5 }
        if ($riskFlags -like "*covered_by_existing_orchestrator*") { $priorityScore += 3 }
    }

    $deploymentPipelineNames = ""
    if ($null -ne $deploymentGroups) {
        $deploymentPipelineNames = ((@($deploymentGroups) | ForEach-Object { Get-FieldValue -Object $_ -Names @("deployment_pipeline_name") } | Where-Object { $_ }) -join "; ")
    }

    $scheduleSignal = ""
    if ($null -ne $schedule) {
        $scheduleSignal = "schedule_review_candidate"
    }
    elseif ((Convert-ToInt (Get-FieldValue -Object $row -Names @("enabled_schedules"))) -gt 0 -or (Convert-ToInt (Get-FieldValue -Object $row -Names @("disabled_schedules"))) -gt 0) {
        $scheduleSignal = "has_schedule_metadata"
    }

    $manualSignal = if ($null -ne $manual) { "repeated_manual_candidate" } else { "" }
    $fanoutSignal = if ($null -ne $fanout) { "fanout_orchestrator_candidate" } else { "" }
    $recommendedAction = Get-RecommendedAction -PromotionPath $promotionPath -PlanAction (Get-FieldValue -Object $row -Names @("v2_recommended_next_action")) -PromotionReadiness $promotionReadiness

    $queueObject = [pscustomobject]@{
        d7_id = $d7Id
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        promotion_path = $promotionPath
        candidate_scope = $candidateScope
        promotion_readiness = $promotionReadiness
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $workspace -Names @("environment")
        workspace_type = Get-FieldValue -Object $workspace -Names @("workspace_type")
        capacity_name = Get-FieldValue -Object $workspace -Names @("capacity_name")
        deployment_pipelines = $deploymentPipelineNames
        item_type = Get-FieldValue -Object $row -Names @("item_type")
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        item_qualified_name = $qualifiedName
        v2_wave_index = Convert-ToInt (Get-FieldValue -Object $row -Names @("v2_wave_index"))
        proposed_stage = Get-FieldValue -Object $row -Names @("proposed_stage")
        orchestration_role = Get-FieldValue -Object $row -Names @("orchestration_role")
        action_type = Get-FieldValue -Object $row -Names @("action_type")
        is_master_action = Get-FieldValue -Object $row -Names @("is_master_action")
        estimated_duration_seconds = Convert-ToDouble (Get-FieldValue -Object $row -Names @("estimated_duration_seconds"))
        duration_source = $durationSource
        predecessor_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("predecessor_count"))
        successor_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("successor_count"))
        run_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("run_count"))
        failed_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("failed_count"))
        manual_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("manual_count"))
        scheduled_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("scheduled_count"))
        enabled_schedules = Convert-ToInt (Get-FieldValue -Object $row -Names @("enabled_schedules"))
        disabled_schedules = Convert-ToInt (Get-FieldValue -Object $row -Names @("disabled_schedules"))
        schedule_times = Get-FieldValue -Object $row -Names @("schedule_times")
        schedule_signal = $scheduleSignal
        repeated_manual_signal = $manualSignal
        fanout_signal = $fanoutSignal
        d6_blocker_id = Get-FieldValue -Object $d6 -Names @("d6_id")
        d6_stabilization_type = Get-FieldValue -Object $d6 -Names @("stabilization_type")
        d6_decision_readiness = Get-FieldValue -Object $d6 -Names @("decision_readiness")
        original_risk_flags = $riskFlags
        human_validation_required = Get-FieldValue -Object $row -Names @("original_human_validation_required")
        recommended_next_action = Limit-Text -Text $recommendedAction
        d7_gate_to_promote = "Record an approved D7 decision: nonprod_run, source_check, semantic_refresh, consumption_check, keep_manual, keep_child_activity, exclude, or blocked."
    }
    $queueRows.Add($queueObject) | Out-Null

    if ($candidateScope -ne "manual_governance_check") {
        $candidateStatus = "candidate_after_owner_review"
        if ($promotionReadiness -like "blocked*") { $candidateStatus = $promotionReadiness }
        $candidateOutputRows.Add([pscustomobject]@{
            d7_candidate_id = "D7C{0:D5}" -f ($candidateOutputRows.Count + 1)
            d7_id = $d7Id
            candidate_status = $candidateStatus
            candidate_scope = $candidateScope
            promotion_path = $promotionPath
            priority_score = $priorityScore
            priority_band = Get-PriorityBand -PriorityScore $priorityScore
            workspace_name = $queueObject.workspace_name
            workspace_environment = $queueObject.workspace_environment
            item_type = $queueObject.item_type
            item_name = $queueObject.item_name
            item_qualified_name = $qualifiedName
            v2_wave_index = $queueObject.v2_wave_index
            proposed_stage = $queueObject.proposed_stage
            action_type = $queueObject.action_type
            estimated_duration_seconds = $queueObject.estimated_duration_seconds
            duration_source = $durationSource
            predecessor_count = $queueObject.predecessor_count
            successor_count = $queueObject.successor_count
            schedule_signal = $scheduleSignal
            repeated_manual_signal = $manualSignal
            fanout_signal = $fanoutSignal
            d6_blocker_id = $queueObject.d6_blocker_id
            recommended_next_action = $recommendedAction
            nonprod_gate = "Owner approves scope, D1-D6 blockers are resolved or accepted, and this candidate is tested outside production before any operational change."
        }) | Out-Null
    }

    $decisionRows.Add([pscustomobject]@{
        d7_id = $d7Id
        item_qualified_name = $qualifiedName
        workspace_name = $queueObject.workspace_name
        workspace_environment = $queueObject.workspace_environment
        item_type = $queueObject.item_type
        item_name = $queueObject.item_name
        promotion_path = $promotionPath
        candidate_scope = $candidateScope
        promotion_readiness = $promotionReadiness
        current_action_type = $queueObject.action_type
        current_v2_wave_index = $queueObject.v2_wave_index
        current_duration_source = $durationSource
        proposed_d7_decision = ""
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
        notes = "D7 template row. Use decisions such as nonprod_run, source_check, semantic_refresh, consumption_check, keep_manual, keep_child_activity, exclude, or blocked."
    }) | Out-Null

    $readonlyRows.Add([pscustomobject]@{
        d7_id = $d7Id
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        item_qualified_name = $qualifiedName
        promotion_path = $promotionPath
        candidate_scope = $candidateScope
        promotion_readiness = $promotionReadiness
        readonly_method = "Review workspace environment, owner, schedules, duration evidence, deployment pipeline membership, upstream/downstream dependencies, and D1-D6 blockers before selecting a D7 decision."
        template_path = $OutputDecisionTemplatePath
        notes = "Read-only/manual review target. Do not create or edit Fabric pipelines, schedules, triggers, or repos from this package alone."
    }) | Out-Null
}

$waveOutputRows = [System.Collections.Generic.List[object]]::new()
foreach ($group in ($queueRows | Group-Object v2_wave_index | Sort-Object { [int]$_.Name })) {
    $wave = $null
    foreach ($candidateWave in $waveRows) {
        if ((Convert-ToInt (Get-FieldValue -Object $candidateWave -Names @("v2_wave_index", "wave_index"))) -eq [int]$group.Name) {
            $wave = $candidateWave
            break
        }
    }
    $candidateCount = @($group.Group | Where-Object { $_.candidate_scope -ne "manual_governance_check" }).Count
    $blockedCount = @($group.Group | Where-Object { $_.promotion_readiness -like "blocked*" }).Count
    $manualCount = @($group.Group | Where-Object { $_.candidate_scope -eq "manual_governance_check" -or $_.promotion_readiness -like "*manual*" }).Count
    $waveOutputRows.Add([pscustomobject]@{
        d7_wave_id = "D7W{0:D3}" -f ([int]$group.Name)
        v2_wave_index = [int]$group.Name
        d7_row_count = $group.Count
        nonprod_candidate_count = $candidateCount
        blocked_candidate_count = $blockedCount
        manual_or_governance_count = $manualCount
        max_priority_score = (@($group.Group | ForEach-Object { [int]$_.priority_score } | Measure-Object -Maximum).Maximum)
        promotion_paths = ((@($group.Group | Group-Object promotion_path | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join "; ")
        candidate_scopes = ((@($group.Group | Group-Object candidate_scope | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join "; ")
        readiness_breakdown = ((@($group.Group | Group-Object promotion_readiness | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join "; ")
        source_wave_node_count = Get-FieldValue -Object $wave -Names @("node_count")
        source_wave_recommendation = Get-FieldValue -Object $wave -Names @("recommendation")
        d7_gate_to_promote = "Wave can enter non-production design only after each row has an approved D7 decision and upstream D1-D6 blockers are closed or accepted."
    }) | Out-Null
}

$queueColumns = @(
    "d7_id", "priority_score", "priority_band", "promotion_path", "candidate_scope", "promotion_readiness",
    "workspace_name", "workspace_environment", "workspace_type", "capacity_name", "deployment_pipelines",
    "item_type", "item_name", "item_qualified_name", "v2_wave_index", "proposed_stage", "orchestration_role",
    "action_type", "is_master_action", "estimated_duration_seconds", "duration_source", "predecessor_count",
    "successor_count", "run_count", "failed_count", "manual_count", "scheduled_count", "enabled_schedules",
    "disabled_schedules", "schedule_times", "schedule_signal", "repeated_manual_signal", "fanout_signal",
    "d6_blocker_id", "d6_stabilization_type", "d6_decision_readiness", "original_risk_flags",
    "human_validation_required", "recommended_next_action", "d7_gate_to_promote"
)
$candidateColumns = @(
    "d7_candidate_id", "d7_id", "candidate_status", "candidate_scope", "promotion_path", "priority_score",
    "priority_band", "workspace_name", "workspace_environment", "item_type", "item_name", "item_qualified_name",
    "v2_wave_index", "proposed_stage", "action_type", "estimated_duration_seconds", "duration_source",
    "predecessor_count", "successor_count", "schedule_signal", "repeated_manual_signal", "fanout_signal",
    "d6_blocker_id", "recommended_next_action", "nonprod_gate"
)
$waveColumns = @(
    "d7_wave_id", "v2_wave_index", "d7_row_count", "nonprod_candidate_count", "blocked_candidate_count",
    "manual_or_governance_count", "max_priority_score", "promotion_paths", "candidate_scopes",
    "readiness_breakdown", "source_wave_node_count", "source_wave_recommendation", "d7_gate_to_promote"
)
$decisionColumns = @(
    "d7_id", "item_qualified_name", "workspace_name", "workspace_environment", "item_type", "item_name",
    "promotion_path", "candidate_scope", "promotion_readiness", "current_action_type", "current_v2_wave_index",
    "current_duration_source", "proposed_d7_decision", "proposed_nonprod_scope", "proposed_wave",
    "proposed_schedule_handling", "proposed_owner_validation", "include_in_master_pipeline_design",
    "blocked_reason", "owner", "confirmation_source", "confirmation_evidence", "reviewer", "reviewed_at", "notes"
)
$readonlyColumns = @("d7_id", "priority_score", "priority_band", "item_qualified_name", "promotion_path", "candidate_scope", "promotion_readiness", "readonly_method", "template_path", "notes")

$queueSorted = @($queueRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, v2_wave_index, workspace_name, item_type, item_name)
$candidateSorted = @($candidateOutputRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, v2_wave_index, workspace_name, item_type, item_name)
$waveSorted = @($waveOutputRows | Sort-Object v2_wave_index)
$decisionSorted = @($decisionRows | Sort-Object d7_id)
$readonlySorted = @($readonlyRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, d7_id)

Export-Rows -Rows $queueSorted -Columns $queueColumns -Path $OutputQueuePath
Export-Rows -Rows $candidateSorted -Columns $candidateColumns -Path $OutputCandidatePath
Export-Rows -Rows $waveSorted -Columns $waveColumns -Path $OutputWavePath
Export-Rows -Rows $decisionSorted -Columns $decisionColumns -Path $OutputDecisionTemplatePath
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
    $highCount = @($GroupRows | Where-Object {
        $band = Get-FieldValue -Object $_ -Names @("priority_band")
        $band -in @("critical", "high")
    }).Count
    $maxPriority = 0
    if ($count -gt 0) {
        $maxPriority = (@($GroupRows | ForEach-Object { Convert-ToInt (Get-FieldValue -Object $_ -Names @("priority_score")) } | Measure-Object -Maximum).Maximum)
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

Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D7 orchestration review rows" -GroupRows @($queueRows) -Notes "Rows with v2_status needs_orchestration_review."
Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D7 non-production candidates" -GroupRows @($candidateOutputRows) -Notes "Rows that could feed non-production master pipeline design after review."
Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D7 waves" -GroupRows @($waveOutputRows) -Notes "Wave-level promotion review rows."
foreach ($group in ($queueRows | Group-Object promotion_path | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "promotion_path" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D7 rows grouped by promotion path."
}
foreach ($group in ($queueRows | Group-Object candidate_scope | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "candidate_scope" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D7 rows grouped by candidate scope."
}
foreach ($group in ($queueRows | Group-Object promotion_readiness | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "promotion_readiness" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D7 rows grouped by current promotion readiness."
}
foreach ($group in ($queueRows | Group-Object action_type | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "action_type" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D7 rows grouped by current action type."
}
foreach ($group in ($queueRows | Group-Object item_type | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "item_type" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D7 rows grouped by item type."
}

Export-Rows -Rows @($summaryRows) -Columns @("summary_scope", "group_key", "row_count", "high_or_critical_count", "max_priority_score", "notes") -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$generatedAt = (Get-Date).ToString("s")
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D7 Orchestration Review Promotion Package") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated: $generatedAt") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D7 turns orchestration v2 rows that need human orchestration review into explicit promotion decisions. The package is local-only and does not create, update, delete, trigger, schedule, deploy, or refactor Fabric items.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Current Baseline") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- D7 orchestration review rows: $($queueRows.Count)") | Out-Null
$doc.Add("- Non-production candidate rows: $($candidateOutputRows.Count)") | Out-Null
$doc.Add("- Wave review rows: $($waveOutputRows.Count)") | Out-Null
$doc.Add("- Decision template rows: $($decisionRows.Count)") | Out-Null
$doc.Add("- Read-only/manual target rows: $($readonlyRows.Count)") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Promotion-Path Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($queueRows | Group-Object promotion_path | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Promotion-Readiness Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($queueRows | Group-Object promotion_readiness | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Top Priority Rows") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("| Priority | Workspace | Type | Item | Path | Readiness | Wave | Duration Source |") | Out-Null
$doc.Add("| --- | --- | --- | --- | --- | --- | --- | --- |") | Out-Null
foreach ($row in ($queueSorted | Select-Object -First 15)) {
    $doc.Add("| $($row.priority_score) | $(Escape-MdCell $row.workspace_name) | $(Escape-MdCell $row.item_type) | $(Escape-MdCell $row.item_name) | $(Escape-MdCell $row.promotion_path) | $(Escape-MdCell $row.promotion_readiness) | $($row.v2_wave_index) | $(Escape-MdCell $row.duration_source) |") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- analysis/d7_orchestration_review_queue.csv") | Out-Null
$doc.Add("- analysis/d7_nonprod_candidate_queue.csv") | Out-Null
$doc.Add("- analysis/d7_wave_promotion_queue.csv") | Out-Null
$doc.Add("- analysis/d7_orchestration_review_summary.csv") | Out-Null
$doc.Add("- analysis/d7_promotion_decision_template.csv") | Out-Null
$doc.Add("- analysis/d7_readonly_promotion_targets.csv") | Out-Null
$doc.Add("- docs/29_d7_orchestration_review_promotion.md") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## How To Close D7 Rows") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('1. Work `analysis/d7_orchestration_review_queue.csv` in priority order.') | Out-Null
$doc.Add('2. Use `analysis/d7_nonprod_candidate_queue.csv` for candidate master-pipeline design rows after D1-D6 blockers are closed or accepted.') | Out-Null
$doc.Add('3. Use `analysis/d7_wave_promotion_queue.csv` to decide which waves can move into non-production design.') | Out-Null
$doc.Add('4. Record reviewed decisions in `analysis/d7_promotion_decision_template.csv`.') | Out-Null
$doc.Add('5. Valid decisions include `nonprod_run`, `source_check`, `semantic_refresh`, `consumption_check`, `keep_manual`, `keep_child_activity`, `exclude`, or `blocked`.') | Out-Null
$doc.Add("6. Do not create or modify Fabric pipelines, schedules, triggers, deployment pipelines, or repositories from this package alone.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Gate") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D7 is closed only when every orchestration review row has an approved action and all selected non-production candidates are free of unresolved D1-D6 blockers or explicitly accepted by the owner. This package is evidence preparation and does not approve operational changes.") | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D7 orchestration review promotion package completed."
Write-Host "Review rows: $($queueRows.Count)"
Write-Host "Non-production candidates: $($candidateOutputRows.Count)"
Write-Host "Wave rows: $($waveOutputRows.Count)"
Write-Host "Output: $OutputQueuePath"
