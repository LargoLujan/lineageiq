# Phase 31 - D6 package: the cleanup-plan category for operationally risky
# items (frequent failures, unstable/long durations) -- packages them into
# a queue plus a manual stabilization decision template. Purely local.
# Writes: $OutputQueuePath, $OutputFailureQueuePath, $OutputDurationQueuePath,
# $OutputExecutionEvidencePath, $OutputSummaryPath, $OutputDecisionTemplatePath,
# $OutputReadonlyTargetsPath, $OutputDocPath.
param(
    [string]$OrchestrationV2PlanPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_plan.csv"),
    [string]$CleanupQueuePath = (Join-Path $PSScriptRoot "../../analysis/likely_conflict_cleanup_queue.csv"),
    [string]$FailureHotspotsPath = (Join-Path $PSScriptRoot "../../analysis/failure_hotspots.csv"),
    [string]$ExecutionDurationByItemPath = (Join-Path $PSScriptRoot "../../analysis/execution_duration_by_item.csv"),
    [string]$ExecutionsPath = (Join-Path $PSScriptRoot "../../index/executions.csv"),
    [string]$OutputQueuePath = (Join-Path $PSScriptRoot "../../analysis/d6_failure_duration_queue.csv"),
    [string]$OutputFailureQueuePath = (Join-Path $PSScriptRoot "../../analysis/d6_failure_hotspot_queue.csv"),
    [string]$OutputDurationQueuePath = (Join-Path $PSScriptRoot "../../analysis/d6_duration_stabilization_queue.csv"),
    [string]$OutputExecutionEvidencePath = (Join-Path $PSScriptRoot "../../analysis/d6_execution_evidence.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d6_failure_duration_summary.csv"),
    [string]$OutputDecisionTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d6_stabilization_decision_template.csv"),
    [string]$OutputReadonlyTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d6_readonly_operational_review_targets.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/28_d6_failure_duration_stabilization.md")
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

function Get-MapValue {
    param([hashtable]$Map, [string]$Key)
    $normalized = Normalize-Key -Value $Key
    if ($normalized -and $Map.ContainsKey($normalized)) { return $Map[$normalized] }
    return $null
}

function Get-PriorityBand {
    param([int]$PriorityScore)
    if ($PriorityScore -ge 100) { return "critical" }
    if ($PriorityScore -ge 85) { return "high" }
    if ($PriorityScore -ge 70) { return "medium" }
    return "low"
}

function Get-StabilizationType {
    param([string]$V2Status, [string]$RiskFlags, [string]$DurationSource)
    $hasFailure = $V2Status -eq "hold_failure_stabilization"
    $hasDefaultDuration = ($RiskFlags -like "*duration_defaulted*" -or $DurationSource -eq "default_by_role")
    if ($hasFailure -and $hasDefaultDuration) { return "failure_and_duration" }
    if ($hasFailure) { return "failure_hotspot" }
    if ($hasDefaultDuration) { return "duration_defaulted" }
    return "duration_review"
}

function Get-DecisionReadiness {
    param([string]$StabilizationType, [double]$FailureRate, [string]$DurationSource, [object]$DurationEvidence)
    if ($StabilizationType -like "failure*") {
        if ($DurationSource -eq "default_by_role") { return "failure_and_duration_review" }
        return "failure_review"
    }
    if ($DurationSource -eq "default_by_role") {
        if ($null -ne $DurationEvidence) { return "duration_observed_but_plan_defaulted" }
        return "duration_estimate_required"
    }
    if ($FailureRate -gt 0) { return "failure_review" }
    return "manual_duration_review"
}

function Get-RecommendedAction {
    param([string]$StabilizationType, [string]$PlanAction, [string]$DurationSource, [object]$DurationEvidence)
    if ($PlanAction) { return $PlanAction }
    if ($StabilizationType -eq "failure_and_duration") {
        return "Review recent failures with the owner, decide whether the item belongs in the master orchestration, and replace the default duration with observed or approved evidence."
    }
    if ($StabilizationType -eq "failure_hotspot") {
        return "Stabilize failed runs before optimizing schedule, dependency order, or parallelism."
    }
    if ($DurationSource -eq "default_by_role" -and $null -ne $DurationEvidence) {
        return "Use observed execution history to replace the default duration estimate, then rebuild orchestration waves."
    }
    if ($DurationSource -eq "default_by_role") {
        return "Capture owner-approved duration or run-history evidence before using this item in timing optimization."
    }
    return "Review operational timing and keep this row blocked until failure/duration evidence is accepted."
}

function Escape-MdCell {
    param([string]$Value)
    if (-not $Value) { return "" }
    return (($Value -replace "\|", "/") -replace "`r?`n", " ").Trim()
}

foreach ($path in @($OrchestrationV2PlanPath, $CleanupQueuePath, $FailureHotspotsPath, $ExecutionDurationByItemPath, $ExecutionsPath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$planRows = @(Import-Csv -Path $OrchestrationV2PlanPath)
$cleanupRows = @(Import-Csv -Path $CleanupQueuePath)
$failureRows = @(Import-Csv -Path $FailureHotspotsPath)
$durationRows = @(Import-Csv -Path $ExecutionDurationByItemPath)
$executionRows = @(Import-Csv -Path $ExecutionsPath)

$d6CleanupByQualifiedName = @{}
foreach ($row in ($cleanupRows | Where-Object { $_.phase_id -eq "D6" })) {
    Set-FirstMapValue -Map $d6CleanupByQualifiedName -Key (Get-FieldValue -Object $row -Names @("item_qualified_name")) -Value $row
}

$failureByQualifiedName = @{}
foreach ($row in $failureRows) {
    Set-FirstMapValue -Map $failureByQualifiedName -Key (Get-FieldValue -Object $row -Names @("qualified_name", "item_qualified_name")) -Value $row
}

$durationByQualifiedName = @{}
foreach ($row in $durationRows) {
    Set-FirstMapValue -Map $durationByQualifiedName -Key (Get-FieldValue -Object $row -Names @("qualified_name", "item_qualified_name")) -Value $row
}

$candidateRows = @($planRows | Where-Object {
    $_.v2_status -eq "hold_failure_stabilization" -or $_.original_risk_flags -like "*duration_defaulted*"
})

$queueRows = [System.Collections.Generic.List[object]]::new()
$failureQueueRows = [System.Collections.Generic.List[object]]::new()
$durationQueueRows = [System.Collections.Generic.List[object]]::new()
$decisionRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()
$d6IdByQualifiedName = @{}
$sequence = 0

foreach ($row in ($candidateRows | Sort-Object @{ Expression = {
    $cleanup = Get-MapValue -Map $d6CleanupByQualifiedName -Key (Get-FieldValue -Object $_ -Names @("qualified_name"))
    Convert-ToInt (Get-FieldValue -Object $cleanup -Names @("priority_score"))
}; Descending = $true }, workspace_name, item_type, item_name)) {
    $sequence += 1
    $d6Id = "D6I{0:D5}" -f $sequence
    $qualifiedName = Get-FieldValue -Object $row -Names @("qualified_name")
    $normalizedQualifiedName = Normalize-Key -Value $qualifiedName
    $d6IdByQualifiedName[$normalizedQualifiedName] = $d6Id
    $cleanup = Get-MapValue -Map $d6CleanupByQualifiedName -Key $qualifiedName
    $failure = Get-MapValue -Map $failureByQualifiedName -Key $qualifiedName
    $duration = Get-MapValue -Map $durationByQualifiedName -Key $qualifiedName

    $failedCount = Convert-ToInt (Get-FieldValue -Object $row -Names @("failed_count"))
    $runCount = Convert-ToInt (Get-FieldValue -Object $row -Names @("run_count"))
    $failureRate = 0.0
    if ($runCount -gt 0) { $failureRate = [math]::Round($failedCount / $runCount, 4) }
    $failureRateFromHotspot = Convert-ToDouble (Get-FieldValue -Object $failure -Names @("failure_rate"))
    if ($failureRateFromHotspot -gt 0) { $failureRate = $failureRateFromHotspot }

    $durationSource = Get-FieldValue -Object $row -Names @("duration_source")
    $estimatedDuration = Convert-ToDouble (Get-FieldValue -Object $row -Names @("estimated_duration_seconds"))
    $observedAverage = Convert-ToDouble (Get-FieldValue -Object $duration -Names @("avg_duration_seconds"))
    $observedMax = Convert-ToDouble (Get-FieldValue -Object $duration -Names @("max_duration_seconds"))
    $observedCompleted = Convert-ToInt (Get-FieldValue -Object $duration -Names @("completed_count"))
    $stabilizationType = Get-StabilizationType -V2Status (Get-FieldValue -Object $row -Names @("v2_status")) -RiskFlags (Get-FieldValue -Object $row -Names @("original_risk_flags")) -DurationSource $durationSource
    $decisionReadiness = Get-DecisionReadiness -StabilizationType $stabilizationType -FailureRate $failureRate -DurationSource $durationSource -DurationEvidence $duration
    $priorityScore = Convert-ToInt (Get-FieldValue -Object $cleanup -Names @("priority_score"))
    if ($priorityScore -eq 0) {
        $priorityScore = 70 + $failedCount + [math]::Round($estimatedDuration / 600)
        if ($durationSource -eq "default_by_role") { $priorityScore += 10 }
        if ($stabilizationType -like "failure*") { $priorityScore += 15 }
    }
    $recommendedAction = Get-RecommendedAction -StabilizationType $stabilizationType -PlanAction (Get-FieldValue -Object $row -Names @("v2_recommended_next_action")) -DurationSource $durationSource -DurationEvidence $duration

    $queueRows.Add([pscustomobject]@{
        d6_id = $d6Id
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        stabilization_type = $stabilizationType
        decision_readiness = $decisionReadiness
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        item_type = Get-FieldValue -Object $row -Names @("item_type")
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        item_qualified_name = $qualifiedName
        v2_status = Get-FieldValue -Object $row -Names @("v2_status")
        original_risk_flags = Get-FieldValue -Object $row -Names @("original_risk_flags")
        duration_source = $durationSource
        estimated_duration_seconds = $estimatedDuration
        observed_completed_count = $observedCompleted
        observed_avg_duration_seconds = $observedAverage
        observed_max_duration_seconds = $observedMax
        run_count = $runCount
        failed_count = $failedCount
        failure_rate = $failureRate
        enabled_schedules = Convert-ToInt (Get-FieldValue -Object $row -Names @("enabled_schedules"))
        disabled_schedules = Convert-ToInt (Get-FieldValue -Object $row -Names @("disabled_schedules"))
        scheduled_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("scheduled_count"))
        manual_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("manual_count"))
        schedule_times = Get-FieldValue -Object $row -Names @("schedule_times")
        predecessor_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("predecessor_count"))
        successor_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("successor_count"))
        cleanup_blocker_type = Get-FieldValue -Object $cleanup -Names @("blocker_type")
        recommended_next_action = Limit-Text -Text $recommendedAction
        d6_gate_to_close = "Record a reviewed stabilization decision: failure stabilized or accepted, duration observed or owner-approved, or item explicitly excluded/blocked."
    }) | Out-Null

    if ($null -ne $failure) {
        $failureQueueRows.Add([pscustomobject]@{
            d6_failure_id = "D6F{0:D5}" -f ($failureQueueRows.Count + 1)
            d6_id = $d6Id
            priority_score = $priorityScore
            priority_band = Get-PriorityBand -PriorityScore $priorityScore
            workspace_name = Get-FieldValue -Object $failure -Names @("workspace_name")
            item_type = Get-FieldValue -Object $failure -Names @("item_type")
            item_name = Get-FieldValue -Object $failure -Names @("item_name")
            item_qualified_name = $qualifiedName
            job_type = Get-FieldValue -Object $failure -Names @("job_type")
            run_count = Convert-ToInt (Get-FieldValue -Object $failure -Names @("run_count"))
            completed_count = Convert-ToInt (Get-FieldValue -Object $failure -Names @("completed_count"))
            failed_count = Convert-ToInt (Get-FieldValue -Object $failure -Names @("failed_count"))
            failure_rate = Convert-ToDouble (Get-FieldValue -Object $failure -Names @("failure_rate"))
            avg_duration_seconds = Convert-ToDouble (Get-FieldValue -Object $failure -Names @("avg_duration_seconds"))
            max_duration_seconds = Convert-ToDouble (Get-FieldValue -Object $failure -Names @("max_duration_seconds"))
            latest_start_time = Get-FieldValue -Object $failure -Names @("latest_start_time")
            latest_end_time = Get-FieldValue -Object $failure -Names @("latest_end_time")
            last_status = Get-FieldValue -Object $failure -Names @("last_status")
            recommendation_hint = Get-FieldValue -Object $failure -Names @("recommendation_hint")
            d6_gate_to_close = "Failure hotspot reviewed and either stabilized, excluded from orchestration, or accepted with owner evidence."
        }) | Out-Null
    }

    $durationEvidenceStatus = "no_observed_duration"
    if ($durationSource -eq "observed_avg") { $durationEvidenceStatus = "plan_uses_observed_average" }
    elseif ($durationSource -eq "default_by_role" -and $observedCompleted -gt 0) { $durationEvidenceStatus = "observed_history_available_but_plan_defaulted" }
    elseif ($durationSource -eq "default_by_role") { $durationEvidenceStatus = "owner_estimate_or_new_history_required" }

    $durationQueueRows.Add([pscustomobject]@{
        d6_duration_id = "D6D{0:D5}" -f ($durationQueueRows.Count + 1)
        d6_id = $d6Id
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        item_type = Get-FieldValue -Object $row -Names @("item_type")
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        item_qualified_name = $qualifiedName
        duration_source = $durationSource
        current_estimated_duration_seconds = $estimatedDuration
        duration_evidence_status = $durationEvidenceStatus
        observed_run_count = Convert-ToInt (Get-FieldValue -Object $duration -Names @("run_count"))
        observed_completed_count = $observedCompleted
        observed_failed_count = Convert-ToInt (Get-FieldValue -Object $duration -Names @("failed_count"))
        observed_avg_duration_seconds = $observedAverage
        observed_max_duration_seconds = $observedMax
        latest_start_time = Get-FieldValue -Object $duration -Names @("latest_start_time")
        latest_end_time = Get-FieldValue -Object $duration -Names @("latest_end_time")
        last_status = Get-FieldValue -Object $duration -Names @("last_status")
        recommended_next_action = Limit-Text -Text $recommendedAction
        d6_gate_to_close = "Duration estimate has observed run history or owner-approved evidence and orchestration waves are rebuilt."
    }) | Out-Null

    $decisionRows.Add([pscustomobject]@{
        d6_id = $d6Id
        item_qualified_name = $qualifiedName
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        item_type = Get-FieldValue -Object $row -Names @("item_type")
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        stabilization_type = $stabilizationType
        decision_readiness = $decisionReadiness
        current_v2_status = Get-FieldValue -Object $row -Names @("v2_status")
        current_duration_source = $durationSource
        current_estimated_duration_seconds = $estimatedDuration
        current_failure_rate = $failureRate
        proposed_failure_status = ""
        proposed_duration_seconds = ""
        proposed_duration_source = ""
        proposed_schedule_action = ""
        include_in_master_plan = ""
        blocked_reason = ""
        owner = ""
        confirmation_source = ""
        confirmation_evidence = ""
        reviewer = ""
        reviewed_at = ""
        notes = "D6 template row. Use statuses such as failure_stabilized, failure_accepted, duration_observed, duration_owner_estimate, excluded_from_master_plan, or blocked_pending_owner."
    }) | Out-Null

    $readonlyRows.Add([pscustomobject]@{
        d6_id = $d6Id
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        item_qualified_name = $qualifiedName
        stabilization_type = $stabilizationType
        decision_readiness = $decisionReadiness
        readonly_method = "Review execution history, failure reason, schedule state, duration evidence, owner guidance, and deployment environment before selecting a D6 decision."
        template_path = $OutputDecisionTemplatePath
        notes = "Read-only/manual review target. Do not update schedules, triggers, retries, or orchestration rules from this package alone."
    }) | Out-Null
}

$executionEvidenceRows = [System.Collections.Generic.List[object]]::new()
$executionSequence = 0
$d6QualifiedNames = @{}
foreach ($row in $queueRows) {
    $normalizedQualifiedName = Normalize-Key -Value $row.item_qualified_name
    if ($normalizedQualifiedName) { $d6QualifiedNames[$normalizedQualifiedName] = $row.d6_id }
}
foreach ($row in $executionRows) {
    $qualifiedName = Get-FieldValue -Object $row -Names @("qualified_name", "item_qualified_name")
    $normalized = Normalize-Key -Value $qualifiedName
    if (-not $normalized -or -not $d6QualifiedNames.ContainsKey($normalized)) { continue }
    $executionSequence += 1
    $executionEvidenceRows.Add([pscustomobject]@{
        d6_execution_id = "D6E{0:D6}" -f $executionSequence
        d6_id = $d6QualifiedNames[$normalized]
        item_qualified_name = $qualifiedName
        record_type = Get-FieldValue -Object $row -Names @("record_type")
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        item_type = Get-FieldValue -Object $row -Names @("item_type")
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        job_type = Get-FieldValue -Object $row -Names @("job_type")
        trigger_type = Get-FieldValue -Object $row -Names @("trigger_type")
        schedule_enabled = Get-FieldValue -Object $row -Names @("schedule_enabled")
        scheduled_time = Get-FieldValue -Object $row -Names @("scheduled_time")
        schedule_timezone = Get-FieldValue -Object $row -Names @("schedule_timezone")
        start_time = Get-FieldValue -Object $row -Names @("start_time")
        end_time = Get-FieldValue -Object $row -Names @("end_time")
        duration_seconds = Get-FieldValue -Object $row -Names @("duration_seconds")
        status = Get-FieldValue -Object $row -Names @("status")
        failure_reason = Limit-Text -Text (Get-FieldValue -Object $row -Names @("failure_reason")) -MaxLength 1200
        source_system = Get-FieldValue -Object $row -Names @("source_system")
        evidence = Limit-Text -Text (Get-FieldValue -Object $row -Names @("evidence")) -MaxLength 1200
    }) | Out-Null
}

$queueColumns = @(
    "d6_id", "priority_score", "priority_band", "stabilization_type", "decision_readiness",
    "workspace_name", "item_type", "item_name", "item_qualified_name", "v2_status",
    "original_risk_flags", "duration_source", "estimated_duration_seconds", "observed_completed_count",
    "observed_avg_duration_seconds", "observed_max_duration_seconds", "run_count", "failed_count",
    "failure_rate", "enabled_schedules", "disabled_schedules", "scheduled_count", "manual_count",
    "schedule_times", "predecessor_count", "successor_count", "cleanup_blocker_type",
    "recommended_next_action", "d6_gate_to_close"
)
$failureColumns = @(
    "d6_failure_id", "d6_id", "priority_score", "priority_band", "workspace_name", "item_type",
    "item_name", "item_qualified_name", "job_type", "run_count", "completed_count", "failed_count",
    "failure_rate", "avg_duration_seconds", "max_duration_seconds", "latest_start_time", "latest_end_time",
    "last_status", "recommendation_hint", "d6_gate_to_close"
)
$durationColumns = @(
    "d6_duration_id", "d6_id", "priority_score", "priority_band", "workspace_name", "item_type",
    "item_name", "item_qualified_name", "duration_source", "current_estimated_duration_seconds",
    "duration_evidence_status", "observed_run_count", "observed_completed_count", "observed_failed_count",
    "observed_avg_duration_seconds", "observed_max_duration_seconds", "latest_start_time", "latest_end_time",
    "last_status", "recommended_next_action", "d6_gate_to_close"
)
$executionColumns = @(
    "d6_execution_id", "d6_id", "item_qualified_name", "record_type", "workspace_name", "item_type",
    "item_name", "job_type", "trigger_type", "schedule_enabled", "scheduled_time", "schedule_timezone",
    "start_time", "end_time", "duration_seconds", "status", "failure_reason", "source_system", "evidence"
)
$decisionColumns = @(
    "d6_id", "item_qualified_name", "workspace_name", "item_type", "item_name", "stabilization_type",
    "decision_readiness", "current_v2_status", "current_duration_source", "current_estimated_duration_seconds",
    "current_failure_rate", "proposed_failure_status", "proposed_duration_seconds", "proposed_duration_source",
    "proposed_schedule_action", "include_in_master_plan", "blocked_reason", "owner", "confirmation_source",
    "confirmation_evidence", "reviewer", "reviewed_at", "notes"
)
$readonlyColumns = @("d6_id", "priority_score", "priority_band", "item_qualified_name", "stabilization_type", "decision_readiness", "readonly_method", "template_path", "notes")

$queueSorted = @($queueRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, workspace_name, item_type, item_name)
$failureSorted = @($failureQueueRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, workspace_name, item_type, item_name)
$durationSorted = @($durationQueueRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, duration_evidence_status, workspace_name, item_type, item_name)
$executionSorted = @($executionEvidenceRows | Sort-Object d6_id, record_type, start_time)
$decisionSorted = @($decisionRows | Sort-Object d6_id)
$readonlySorted = @($readonlyRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, d6_id)

Export-Rows -Rows $queueSorted -Columns $queueColumns -Path $OutputQueuePath
Export-Rows -Rows $failureSorted -Columns $failureColumns -Path $OutputFailureQueuePath
Export-Rows -Rows $durationSorted -Columns $durationColumns -Path $OutputDurationQueuePath
Export-Rows -Rows $executionSorted -Columns $executionColumns -Path $OutputExecutionEvidencePath
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

Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D6 stabilization rows" -GroupRows @($queueRows) -Notes "Items requiring failure or duration stabilization."
Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D6 failure hotspot rows" -GroupRows @($failureQueueRows) -Notes "Failure hotspots joined from analysis/failure_hotspots.csv."
Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D6 duration rows" -GroupRows @($durationQueueRows) -Notes "Duration evidence rows for D6 items."
Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D6 execution evidence rows" -GroupRows @($executionEvidenceRows) -Notes "Execution and schedule evidence rows attached to D6 items."
foreach ($group in ($queueRows | Group-Object stabilization_type | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "stabilization_type" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D6 rows grouped by stabilization type."
}
foreach ($group in ($queueRows | Group-Object decision_readiness | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "decision_readiness" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D6 rows grouped by next decision kind."
}
foreach ($group in ($queueRows | Group-Object v2_status | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "v2_status" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D6 rows grouped by current orchestration v2 status."
}
foreach ($group in ($queueRows | Group-Object duration_source | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "duration_source" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D6 rows grouped by duration source."
}
foreach ($group in ($queueRows | Group-Object item_type | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "item_type" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D6 rows grouped by item type."
}

Export-Rows -Rows @($summaryRows) -Columns @("summary_scope", "group_key", "row_count", "high_or_critical_count", "max_priority_score", "notes") -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$generatedAt = (Get-Date).ToString("s")
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D6 Failure And Duration Stabilization Package") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated: $generatedAt") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D6 focuses on failure holds and weak/default duration evidence that make orchestration timing unsafe. The package is local-only and does not modify Fabric, Power BI, SQL, OneLake, schedules, triggers, retries, deployment pipelines, repositories, or orchestration rules.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Current Baseline") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- D6 stabilization rows: $($queueRows.Count)") | Out-Null
$doc.Add("- Failure hotspot rows: $($failureQueueRows.Count)") | Out-Null
$doc.Add("- Duration stabilization rows: $($durationQueueRows.Count)") | Out-Null
$doc.Add("- Execution evidence rows: $($executionEvidenceRows.Count)") | Out-Null
$doc.Add("- Decision template rows: $($decisionRows.Count)") | Out-Null
$doc.Add("- Read-only/manual target rows: $($readonlyRows.Count)") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Stabilization-Type Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($queueRows | Group-Object stabilization_type | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## V2 Status Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($queueRows | Group-Object v2_status | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Duration Source Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($queueRows | Group-Object duration_source | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Top Priority Rows") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("| Priority | Workspace | Type | Item | Stabilization | Runs | Failed | Failure Rate | Duration Source | Estimated Seconds |") | Out-Null
$doc.Add("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |") | Out-Null
foreach ($row in ($queueSorted | Select-Object -First 15)) {
    $doc.Add("| $($row.priority_score) | $(Escape-MdCell $row.workspace_name) | $(Escape-MdCell $row.item_type) | $(Escape-MdCell $row.item_name) | $(Escape-MdCell $row.stabilization_type) | $($row.run_count) | $($row.failed_count) | $($row.failure_rate) | $(Escape-MdCell $row.duration_source) | $($row.estimated_duration_seconds) |") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- analysis/d6_failure_duration_queue.csv") | Out-Null
$doc.Add("- analysis/d6_failure_hotspot_queue.csv") | Out-Null
$doc.Add("- analysis/d6_duration_stabilization_queue.csv") | Out-Null
$doc.Add("- analysis/d6_execution_evidence.csv") | Out-Null
$doc.Add("- analysis/d6_failure_duration_summary.csv") | Out-Null
$doc.Add("- analysis/d6_stabilization_decision_template.csv") | Out-Null
$doc.Add("- analysis/d6_readonly_operational_review_targets.csv") | Out-Null
$doc.Add("- docs/28_d6_failure_duration_stabilization.md") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## How To Close D6 Rows") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('1. Work `analysis/d6_failure_duration_queue.csv` in priority order.') | Out-Null
$doc.Add('2. Use `analysis/d6_failure_hotspot_queue.csv` to inspect failed-run hotspots.') | Out-Null
$doc.Add('3. Use `analysis/d6_duration_stabilization_queue.csv` to replace default durations with observed or owner-approved estimates.') | Out-Null
$doc.Add('4. Use `analysis/d6_execution_evidence.csv` to inspect local execution and schedule evidence for each D6 item.') | Out-Null
$doc.Add('5. Record reviewed decisions in `analysis/d6_stabilization_decision_template.csv`.') | Out-Null
$doc.Add('6. Valid decisions include `failure_stabilized`, `failure_accepted`, `duration_observed`, `duration_owner_estimate`, `excluded_from_master_plan`, or `blocked_pending_owner`.') | Out-Null
$doc.Add("7. Do not update Fabric schedules, triggers, retries, or orchestration rules from this package alone.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Gate") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D6 is closed only when high-priority failure holds are stabilized or explicitly accepted, high-priority default durations have observed or owner-approved evidence, and orchestration waves are rebuilt. This package is evidence preparation and does not approve scheduling or orchestration changes.") | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D6 failure and duration stabilization package completed."
Write-Host "Stabilization rows: $($queueRows.Count)"
Write-Host "Failure hotspot rows: $($failureQueueRows.Count)"
Write-Host "Duration rows: $($durationQueueRows.Count)"
Write-Host "Output: $OutputQueuePath"
