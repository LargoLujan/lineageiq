# Phase 44 - D6 closure control: tracks which D6 (failure/duration
# stabilization, Phase 31) queue items have since been stabilized based on
# observed execution evidence, closing them out and flagging what still
# needs an owner's manual duration estimate. Purely local.
# Writes: $OutputControlQueuePath, $OutputFailureTargetsPath,
# $OutputDurationTargetsPath, $OutputObservedDurationCandidatesPath,
# $OutputOwnerEstimateQueuePath, $OutputDecisionTemplatePath,
# $OutputReadonlyPlanPath, $OutputSummaryPath, $OutputDocPath.
param(
    [string]$D6QueuePath = (Join-Path $PSScriptRoot "../../analysis/d6_failure_duration_queue.csv"),
    [string]$D6FailurePath = (Join-Path $PSScriptRoot "../../analysis/d6_failure_hotspot_queue.csv"),
    [string]$D6DurationPath = (Join-Path $PSScriptRoot "../../analysis/d6_duration_stabilization_queue.csv"),
    [string]$D6ExecutionEvidencePath = (Join-Path $PSScriptRoot "../../analysis/d6_execution_evidence.csv"),
    [string]$OutputControlQueuePath = (Join-Path $PSScriptRoot "../../analysis/d6_closure_control_queue.csv"),
    [string]$OutputFailureTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d6_failure_stabilization_targets.csv"),
    [string]$OutputDurationTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d6_duration_evidence_targets.csv"),
    [string]$OutputObservedDurationCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/d6_observed_duration_candidates.csv"),
    [string]$OutputOwnerEstimateQueuePath = (Join-Path $PSScriptRoot "../../analysis/d6_owner_estimate_required_queue.csv"),
    [string]$OutputDecisionTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d6_operational_decision_template.csv"),
    [string]$OutputReadonlyPlanPath = (Join-Path $PSScriptRoot "../../analysis/d6_external_readonly_action_plan.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d6_closure_control_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/40_d6_closure_control.md")
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

function Get-ClosureOpportunity {
    param(
        [string]$StabilizationType,
        [string]$DurationSource,
        [int]$ObservedCompletedCount
    )

    if ($StabilizationType -eq "failure_and_duration") { return "failure_and_duration_review_required" }
    if ($StabilizationType -eq "failure_hotspot") { return "failure_stabilization_review_required" }
    if ($DurationSource -eq "default_by_role" -and $ObservedCompletedCount -gt 0) { return "observed_duration_candidate" }
    if ($DurationSource -eq "default_by_role") { return "owner_duration_estimate_required" }
    return "manual_duration_review_required"
}

function Get-RecommendedDecision {
    param([string]$ClosureOpportunity)

    switch ($ClosureOpportunity) {
        "failure_and_duration_review_required" { return "Review failed executions first, then record failure_stabilized or failure_accepted plus duration_observed or duration_owner_estimate before orchestration promotion." }
        "failure_stabilization_review_required" { return "Review failed-run evidence and decide failure_stabilized, failure_accepted, excluded_from_master_plan, or blocked_pending_owner." }
        "observed_duration_candidate" { return "Use local completed-run evidence to propose duration_observed, preferably with owner acceptance for high-priority rows." }
        "owner_duration_estimate_required" { return "Request owner-approved duration or wait for new successful run history before using this row in orchestration timing." }
        default { return "Review timing evidence manually and record an explicit D6 decision before promotion." }
    }
}

function Get-ReadonlyAction {
    param([string]$ClosureOpportunity)

    switch ($ClosureOpportunity) {
        "failure_and_duration_review_required" { return "Inspect local failed-run evidence, owner notes, and recent successful runs if available; do not optimize schedule until both failure and duration are accepted." }
        "failure_stabilization_review_required" { return "Inspect failure trend, latest status, schedule intent, retry behavior, and owner evidence before accepting or excluding the item." }
        "observed_duration_candidate" { return "Inspect completed-run history and decide whether observed average, max, or owner-approved percentile should replace the default duration." }
        "owner_duration_estimate_required" { return "Ask the owner for expected duration or capture a successful non-production/production run; keep default duration marked weak until then." }
        default { return "Review local execution evidence and owner evidence before selecting a D6 decision." }
    }
}

if (-not (Test-Path $D6QueuePath)) {
    throw "Required input not found: $D6QueuePath"
}

$d6Rows = @(Import-Csv -Path $D6QueuePath)
$failureRows = Import-OptionalCsv -Path $D6FailurePath
$durationRows = Import-OptionalCsv -Path $D6DurationPath
$executionRows = Import-OptionalCsv -Path $D6ExecutionEvidencePath

$failureByD6 = @{}
foreach ($row in $failureRows) {
    Add-ListMapValue -Map $failureByD6 -Key (Get-FieldValue -Object $row -Names @("d6_id")) -Value $row
}

$durationByD6 = @{}
foreach ($row in $durationRows) {
    Add-ListMapValue -Map $durationByD6 -Key (Get-FieldValue -Object $row -Names @("d6_id")) -Value $row
}

$executionByD6 = @{}
foreach ($row in $executionRows) {
    Add-ListMapValue -Map $executionByD6 -Key (Get-FieldValue -Object $row -Names @("d6_id")) -Value $row
}

$controlRows = [System.Collections.Generic.List[object]]::new()
$failureTargets = [System.Collections.Generic.List[object]]::new()
$durationTargets = [System.Collections.Generic.List[object]]::new()
$observedDurationCandidates = [System.Collections.Generic.List[object]]::new()
$ownerEstimateRows = [System.Collections.Generic.List[object]]::new()
$decisionRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()

foreach ($row in ($d6Rows | Sort-Object @{ Expression = { Convert-ToInt (Get-FieldValue -Object $_ -Names @("priority_score")) }; Descending = $true }, d6_id)) {
    $d6Id = Get-FieldValue -Object $row -Names @("d6_id")
    $failures = if ($failureByD6.ContainsKey($d6Id)) { @($failureByD6[$d6Id]) } else { @() }
    $durations = if ($durationByD6.ContainsKey($d6Id)) { @($durationByD6[$d6Id]) } else { @() }
    $executions = if ($executionByD6.ContainsKey($d6Id)) { @($executionByD6[$d6Id]) } else { @() }

    $stabilizationType = Get-FieldValue -Object $row -Names @("stabilization_type")
    $durationSource = Get-FieldValue -Object $row -Names @("duration_source")
    $observedCompleted = Convert-ToInt (Get-FieldValue -Object $row -Names @("observed_completed_count"))
    $closureOpportunity = Get-ClosureOpportunity `
        -StabilizationType $stabilizationType `
        -DurationSource $durationSource `
        -ObservedCompletedCount $observedCompleted
    $recommendedDecision = Get-RecommendedDecision -ClosureOpportunity $closureOpportunity
    $readonlyAction = Get-ReadonlyAction -ClosureOpportunity $closureOpportunity
    $allowedDecisions = "failure_stabilized; failure_accepted; duration_observed; duration_owner_estimate; excluded_from_master_plan; blocked_pending_owner; manual_review_required"
    $failureIds = ($failures | ForEach-Object { Get-FieldValue -Object $_ -Names @("d6_failure_id") } | Where-Object { $_ } | Sort-Object -Unique) -join "; "
    $durationIds = ($durations | ForEach-Object { Get-FieldValue -Object $_ -Names @("d6_duration_id") } | Where-Object { $_ } | Sort-Object -Unique) -join "; "
    $statusSplit = Get-GroupCounts -Rows $executions -ColumnName "status"
    $jobTypes = Get-UniqueJoined -Rows $executions -ColumnName "job_type" -MaxValues 10
    $triggerTypes = Get-UniqueJoined -Rows $executions -ColumnName "trigger_type" -MaxValues 10
    $failureReasons = Limit-Text -Text (Get-UniqueJoined -Rows $executions -ColumnName "failure_reason" -MaxValues 4) -MaxLength 1200

    $controlRow = [pscustomobject]@{
        d6_id = $d6Id
        priority_score = Get-FieldValue -Object $row -Names @("priority_score")
        priority_band = Get-FieldValue -Object $row -Names @("priority_band")
        closure_opportunity = $closureOpportunity
        stabilization_type = $stabilizationType
        decision_readiness = Get-FieldValue -Object $row -Names @("decision_readiness")
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        item_type = Get-FieldValue -Object $row -Names @("item_type")
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        item_qualified_name = Get-FieldValue -Object $row -Names @("item_qualified_name")
        v2_status = Get-FieldValue -Object $row -Names @("v2_status")
        original_risk_flags = Get-FieldValue -Object $row -Names @("original_risk_flags")
        duration_source = $durationSource
        estimated_duration_seconds = Get-FieldValue -Object $row -Names @("estimated_duration_seconds")
        observed_completed_count = $observedCompleted
        observed_avg_duration_seconds = Get-FieldValue -Object $row -Names @("observed_avg_duration_seconds")
        observed_max_duration_seconds = Get-FieldValue -Object $row -Names @("observed_max_duration_seconds")
        run_count = Get-FieldValue -Object $row -Names @("run_count")
        failed_count = Get-FieldValue -Object $row -Names @("failed_count")
        failure_rate = Get-FieldValue -Object $row -Names @("failure_rate")
        enabled_schedules = Get-FieldValue -Object $row -Names @("enabled_schedules")
        disabled_schedules = Get-FieldValue -Object $row -Names @("disabled_schedules")
        scheduled_count = Get-FieldValue -Object $row -Names @("scheduled_count")
        manual_count = Get-FieldValue -Object $row -Names @("manual_count")
        predecessor_count = Get-FieldValue -Object $row -Names @("predecessor_count")
        successor_count = Get-FieldValue -Object $row -Names @("successor_count")
        failure_target_ids = $failureIds
        duration_target_ids = $durationIds
        execution_evidence_count = @($executions).Count
        execution_status_split = $statusSplit
        execution_job_types = $jobTypes
        execution_trigger_types = $triggerTypes
        failure_reason_sample = $failureReasons
        recommended_d6_decision = $recommendedDecision
        readonly_action = $readonlyAction
        decision_template_path = $OutputDecisionTemplatePath
    }
    $controlRows.Add($controlRow) | Out-Null

    foreach ($failure in $failures) {
        $failureTargets.Add([pscustomobject]@{
            d6_failure_id = Get-FieldValue -Object $failure -Names @("d6_failure_id")
            d6_id = $d6Id
            priority_score = Get-FieldValue -Object $failure -Names @("priority_score")
            priority_band = Get-FieldValue -Object $failure -Names @("priority_band")
            closure_opportunity = $closureOpportunity
            workspace_name = Get-FieldValue -Object $failure -Names @("workspace_name")
            item_type = Get-FieldValue -Object $failure -Names @("item_type")
            item_name = Get-FieldValue -Object $failure -Names @("item_name")
            item_qualified_name = Get-FieldValue -Object $failure -Names @("item_qualified_name")
            job_type = Get-FieldValue -Object $failure -Names @("job_type")
            run_count = Get-FieldValue -Object $failure -Names @("run_count")
            completed_count = Get-FieldValue -Object $failure -Names @("completed_count")
            failed_count = Get-FieldValue -Object $failure -Names @("failed_count")
            failure_rate = Get-FieldValue -Object $failure -Names @("failure_rate")
            avg_duration_seconds = Get-FieldValue -Object $failure -Names @("avg_duration_seconds")
            max_duration_seconds = Get-FieldValue -Object $failure -Names @("max_duration_seconds")
            latest_start_time = Get-FieldValue -Object $failure -Names @("latest_start_time")
            latest_end_time = Get-FieldValue -Object $failure -Names @("latest_end_time")
            last_status = Get-FieldValue -Object $failure -Names @("last_status")
            recommended_failure_decision = $recommendedDecision
            decision_template_path = $OutputDecisionTemplatePath
        }) | Out-Null
    }

    foreach ($duration in $durations) {
        $durationEvidenceStatus = Get-FieldValue -Object $duration -Names @("duration_evidence_status")
        $durationRow = [pscustomobject]@{
            d6_duration_id = Get-FieldValue -Object $duration -Names @("d6_duration_id")
            d6_id = $d6Id
            priority_score = Get-FieldValue -Object $duration -Names @("priority_score")
            priority_band = Get-FieldValue -Object $duration -Names @("priority_band")
            closure_opportunity = $closureOpportunity
            workspace_name = Get-FieldValue -Object $duration -Names @("workspace_name")
            item_type = Get-FieldValue -Object $duration -Names @("item_type")
            item_name = Get-FieldValue -Object $duration -Names @("item_name")
            item_qualified_name = Get-FieldValue -Object $duration -Names @("item_qualified_name")
            duration_source = Get-FieldValue -Object $duration -Names @("duration_source")
            current_estimated_duration_seconds = Get-FieldValue -Object $duration -Names @("current_estimated_duration_seconds")
            duration_evidence_status = $durationEvidenceStatus
            observed_run_count = Get-FieldValue -Object $duration -Names @("observed_run_count")
            observed_completed_count = Get-FieldValue -Object $duration -Names @("observed_completed_count")
            observed_failed_count = Get-FieldValue -Object $duration -Names @("observed_failed_count")
            observed_avg_duration_seconds = Get-FieldValue -Object $duration -Names @("observed_avg_duration_seconds")
            observed_max_duration_seconds = Get-FieldValue -Object $duration -Names @("observed_max_duration_seconds")
            latest_start_time = Get-FieldValue -Object $duration -Names @("latest_start_time")
            latest_end_time = Get-FieldValue -Object $duration -Names @("latest_end_time")
            last_status = Get-FieldValue -Object $duration -Names @("last_status")
            recommended_duration_decision = $recommendedDecision
            decision_template_path = $OutputDecisionTemplatePath
        }
        $durationTargets.Add($durationRow) | Out-Null
        $durationCompleted = Convert-ToInt (Get-FieldValue -Object $duration -Names @("observed_completed_count"))
        $durationSourceValue = Get-FieldValue -Object $duration -Names @("duration_source")
        if ($durationSourceValue -eq "default_by_role" -and $durationCompleted -gt 0) {
            $observedDurationCandidates.Add($durationRow) | Out-Null
        }
        elseif ($durationSourceValue -eq "default_by_role") {
            $ownerEstimateRows.Add($durationRow) | Out-Null
        }
    }

    $suggestedFailureDecision = ""
    $suggestedDurationDecision = ""
    if ($closureOpportunity -in @("failure_and_duration_review_required", "failure_stabilization_review_required")) {
        $suggestedFailureDecision = "failure_stabilized_or_failure_accepted"
    }
    if ($closureOpportunity -eq "observed_duration_candidate") {
        $suggestedDurationDecision = "duration_observed"
    }
    elseif ($durationSource -eq "default_by_role") {
        $suggestedDurationDecision = "duration_owner_estimate"
    }

    $decisionRows.Add([pscustomobject]@{
        d6_id = $d6Id
        item_qualified_name = Get-FieldValue -Object $row -Names @("item_qualified_name")
        stabilization_type = $stabilizationType
        closure_opportunity = $closureOpportunity
        proposed_failure_status = $suggestedFailureDecision
        proposed_duration_seconds = ""
        proposed_duration_source = $suggestedDurationDecision
        proposed_schedule_action = ""
        include_in_master_plan = ""
        blocked_reason = ""
        owner = ""
        confirmation_source = ""
        confirmation_evidence = ""
        reviewer = ""
        reviewed_at = ""
        allowed_decisions = $allowedDecisions
        next_action = $recommendedDecision
        notes = "Fill this row before treating D6 as closed. Do not use failure holds or weak default durations as hard orchestration rules without reviewed evidence."
    }) | Out-Null

    $readonlyRows.Add([pscustomobject]@{
        d6_id = $d6Id
        priority_score = Get-FieldValue -Object $row -Names @("priority_score")
        priority_band = Get-FieldValue -Object $row -Names @("priority_band")
        closure_opportunity = $closureOpportunity
        item_qualified_name = Get-FieldValue -Object $row -Names @("item_qualified_name")
        v2_status = Get-FieldValue -Object $row -Names @("v2_status")
        duration_source = $durationSource
        failure_rate = Get-FieldValue -Object $row -Names @("failure_rate")
        human_readonly_action = $readonlyAction
        linked_failure_target_ids = $failureIds
        linked_duration_target_ids = $durationIds
        execution_evidence_count = @($executions).Count
        decision_template_path = $OutputDecisionTemplatePath
        notes = "Read-only/manual D6 action. Do not update schedules, retries, triggers, pipelines, or orchestration rules from this package alone."
    }) | Out-Null
}

$summaryRows = [System.Collections.Generic.List[object]]::new()
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D6 closure control rows"; row_count = @($controlRows).Count; notes = "One row per D6 stabilization item." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Failure stabilization targets"; row_count = @($failureTargets).Count; notes = "Items with failed-run hotspot evidence." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Duration evidence targets"; row_count = @($durationTargets).Count; notes = "Items needing duration evidence decision." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Observed duration candidates"; row_count = @($observedDurationCandidates).Count; notes = "Default-duration rows with completed-run evidence available." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Owner estimate required rows"; row_count = @($ownerEstimateRows).Count; notes = "Default-duration rows without completed-run evidence." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D6 decision rows"; row_count = @($decisionRows).Count; notes = "One decision row per D6 stabilization item." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "External read-only action rows"; row_count = @($readonlyRows).Count; notes = "One read-only/manual action per D6 item." }) | Out-Null
foreach ($group in @($controlRows | Group-Object closure_opportunity | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "closure_opportunity"; group_key = $group.Name; row_count = $group.Count; notes = "D6 items grouped by closure path." }) | Out-Null
}
foreach ($group in @($controlRows | Group-Object stabilization_type | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "stabilization_type"; group_key = $group.Name; row_count = $group.Count; notes = "D6 items grouped by stabilization type." }) | Out-Null
}
foreach ($group in @($controlRows | Group-Object duration_source | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "duration_source"; group_key = $group.Name; row_count = $group.Count; notes = "D6 items grouped by duration source." }) | Out-Null
}
foreach ($group in @($controlRows | Group-Object v2_status | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "v2_status"; group_key = $group.Name; row_count = $group.Count; notes = "D6 items grouped by current orchestration v2 status." }) | Out-Null
}

$controlColumns = @(
    "d6_id", "priority_score", "priority_band", "closure_opportunity", "stabilization_type",
    "decision_readiness", "workspace_name", "item_type", "item_name", "item_qualified_name",
    "v2_status", "original_risk_flags", "duration_source", "estimated_duration_seconds",
    "observed_completed_count", "observed_avg_duration_seconds", "observed_max_duration_seconds",
    "run_count", "failed_count", "failure_rate", "enabled_schedules", "disabled_schedules",
    "scheduled_count", "manual_count", "predecessor_count", "successor_count",
    "failure_target_ids", "duration_target_ids", "execution_evidence_count",
    "execution_status_split", "execution_job_types", "execution_trigger_types",
    "failure_reason_sample", "recommended_d6_decision", "readonly_action", "decision_template_path"
)
$failureColumns = @(
    "d6_failure_id", "d6_id", "priority_score", "priority_band", "closure_opportunity",
    "workspace_name", "item_type", "item_name", "item_qualified_name", "job_type",
    "run_count", "completed_count", "failed_count", "failure_rate", "avg_duration_seconds",
    "max_duration_seconds", "latest_start_time", "latest_end_time", "last_status",
    "recommended_failure_decision", "decision_template_path"
)
$durationColumns = @(
    "d6_duration_id", "d6_id", "priority_score", "priority_band", "closure_opportunity",
    "workspace_name", "item_type", "item_name", "item_qualified_name", "duration_source",
    "current_estimated_duration_seconds", "duration_evidence_status", "observed_run_count",
    "observed_completed_count", "observed_failed_count", "observed_avg_duration_seconds",
    "observed_max_duration_seconds", "latest_start_time", "latest_end_time", "last_status",
    "recommended_duration_decision", "decision_template_path"
)
$decisionColumns = @(
    "d6_id", "item_qualified_name", "stabilization_type", "closure_opportunity",
    "proposed_failure_status", "proposed_duration_seconds", "proposed_duration_source",
    "proposed_schedule_action", "include_in_master_plan", "blocked_reason", "owner",
    "confirmation_source", "confirmation_evidence", "reviewer", "reviewed_at",
    "allowed_decisions", "next_action", "notes"
)
$readonlyColumns = @(
    "d6_id", "priority_score", "priority_band", "closure_opportunity", "item_qualified_name",
    "v2_status", "duration_source", "failure_rate", "human_readonly_action",
    "linked_failure_target_ids", "linked_duration_target_ids", "execution_evidence_count",
    "decision_template_path", "notes"
)
$summaryColumns = @("summary_scope", "group_key", "row_count", "notes")

Export-Rows -Rows @($controlRows) -Columns $controlColumns -Path $OutputControlQueuePath
Export-Rows -Rows @($failureTargets) -Columns $failureColumns -Path $OutputFailureTargetsPath
Export-Rows -Rows @($durationTargets) -Columns $durationColumns -Path $OutputDurationTargetsPath
Export-Rows -Rows @($observedDurationCandidates) -Columns $durationColumns -Path $OutputObservedDurationCandidatesPath
Export-Rows -Rows @($ownerEstimateRows) -Columns $durationColumns -Path $OutputOwnerEstimateQueuePath
Export-Rows -Rows @($decisionRows) -Columns $decisionColumns -Path $OutputDecisionTemplatePath
Export-Rows -Rows @($readonlyRows) -Columns $readonlyColumns -Path $OutputReadonlyPlanPath
Export-Rows -Rows @($summaryRows) -Columns $summaryColumns -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D6 Closure Control") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated by backend/scripts/44_build_d6_closure_control.ps1 from local project artifacts only.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Start D6 closure by separating failed execution stabilization, observed-duration candidates, and owner-estimate rows. This is a local/manual control package and does not approve orchestration timing changes.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- $OutputControlQueuePath") | Out-Null
$doc.Add("- $OutputFailureTargetsPath") | Out-Null
$doc.Add("- $OutputDurationTargetsPath") | Out-Null
$doc.Add("- $OutputObservedDurationCandidatesPath") | Out-Null
$doc.Add("- $OutputOwnerEstimateQueuePath") | Out-Null
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
$doc.Add('- Work failure rows before schedule or duration promotion when `closure_opportunity` is `failure_and_duration_review_required` or `failure_stabilization_review_required`.') | Out-Null
$doc.Add('- Use `analysis/d6_observed_duration_candidates.csv` only as evidence candidates; owner acceptance is still required for high-risk rows.') | Out-Null
$doc.Add('- Keep `analysis/d6_owner_estimate_required_queue.csv` blocked until owner-approved timing evidence or new completed-run history exists.') | Out-Null
$doc.Add("- No Fabric schedules, triggers, retries, pipelines, or orchestration rules are changed by this package.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Next Human Step") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('Review `analysis/d6_failure_stabilization_targets.csv` first, then work `analysis/d6_owner_estimate_required_queue.csv` for owner-approved duration evidence.') | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D6 closure control built."
Write-Host "Closure control rows: $(@($controlRows).Count)"
Write-Host "Failure stabilization targets: $(@($failureTargets).Count)"
Write-Host "Duration evidence targets: $(@($durationTargets).Count)"
Write-Host "Owner estimate required rows: $(@($ownerEstimateRows).Count)"
