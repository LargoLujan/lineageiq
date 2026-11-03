# Phase 7 - Orchestration optimization: analyzes dependencies + execution
# timing to flag long-running items, failure hotspots, candidates for
# parallelization, and a critical path -- producing both machine-readable
# CSVs and a human-readable action plan. Purely local, no API calls.
# Reads: $DependenciesPath/$ExecutionsPath/$DurationByItemPath.
# Writes: $OutputPath + critical-path/failure/parallelism/schedule CSVs and
# $HumanActionPlanPath.
param(
    [string]$DependenciesPath = (Join-Path $PSScriptRoot "../../index/dependencies.csv"),
    [string]$ExecutionsPath = (Join-Path $PSScriptRoot "../../index/executions.csv"),
    [string]$DurationByItemPath = (Join-Path $PSScriptRoot "../../analysis/execution_duration_by_item.csv"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_recommendations.csv"),
    [string]$CriticalPathPath = (Join-Path $PSScriptRoot "../../analysis/critical_path_candidates.csv"),
    [string]$FailureHotspotsPath = (Join-Path $PSScriptRoot "../../analysis/failure_hotspots.csv"),
    [string]$ManualCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/manual_execution_candidates.csv"),
    [string]$ScheduleReviewPath = (Join-Path $PSScriptRoot "../../analysis/schedule_review_candidates.csv"),
    [string]$OrchestrationGroupsPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_group_candidates.csv"),
    [string]$ParallelCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/parallelism_candidates.csv"),
    [string]$HumanActionPlanPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_human_action_plan.md"),
    [string]$UnresolvedPath = (Join-Path $PSScriptRoot "../../index/unresolved.md"),
    [double]$LongRunMaxSeconds = 3600,
    [double]$LongRunAverageSeconds = 1800,
    [int]$MinManualRuns = 10,
    [int]$MinFailureCount = 3,
    [int]$MinExecuteFanOut = 3,
    [int]$MaxRecommendationsPerCategory = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$recommendationColumns = @(
    "recommendation_id",
    "scope_name",
    "recommendation_type",
    "current_state",
    "proposed_state",
    "expected_benefit",
    "risk",
    "evidence",
    "next_human_step",
    "status"
)

function Get-FieldValue {
    param(
        [object]$Object,
        [string[]]$Names
    )

    if ($null -eq $Object) {
        return ""
    }

    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            $value = $Object.$name
            if ($null -ne $value) {
                return [string]$value
            }
        }
    }

    return ""
}

function Convert-ToInt {
    param([object]$Value)

    if ($null -eq $Value -or [string]$Value -eq "") {
        return 0
    }

    try {
        return [int][double]$Value
    }
    catch {
        return 0
    }
}

function Convert-ToDouble {
    param([object]$Value)

    if ($null -eq $Value -or [string]$Value -eq "") {
        return 0.0
    }

    # [double]$Value (a bare cast) parses via invariant culture, which
    # treats "," as a thousands separator -- so a comma-decimal string
    # like "634,667" (written elsewhere on this es-ES machine) silently
    # becomes 634667 instead of 634.667, a ~1000x inflation that was
    # pushing unrelated items over the critical-path threshold. TryParse's
    # 2-arg overload uses CurrentCulture instead, matching how these
    # strings were written in the first place (see the identical, already-
    # correct pattern in 31_build_d6_failure_duration_stabilization_package.ps1).
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [ref]$parsed)) {
        return $parsed
    }
    return 0.0
}

function Limit-Text {
    param(
        [string]$Text,
        [int]$MaxLength = 700
    )

    if (-not $Text) {
        return ""
    }

    $clean = ($Text -replace "\s+", " ").Trim()
    if ($clean.Length -le $MaxLength) {
        return $clean
    }

    return $clean.Substring(0, $MaxLength - 3) + "..."
}

function Add-Recommendation {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [string]$ScopeName,
        [string]$RecommendationType,
        [string]$CurrentState,
        [string]$ProposedState,
        [string]$ExpectedBenefit,
        [string]$Risk,
        [string]$Evidence,
        [string]$NextHumanStep,
        [string]$Status = "draft_human_review"
    )

    $id = "REC-{0:D3}" -f ($Rows.Count + 1)
    $Rows.Add([pscustomobject]@{
        recommendation_id = $id
        scope_name = Limit-Text -Text $ScopeName -MaxLength 260
        recommendation_type = $RecommendationType
        current_state = Limit-Text -Text $CurrentState -MaxLength 900
        proposed_state = Limit-Text -Text $ProposedState -MaxLength 900
        expected_benefit = Limit-Text -Text $ExpectedBenefit -MaxLength 700
        risk = Limit-Text -Text $Risk -MaxLength 700
        evidence = Limit-Text -Text $Evidence -MaxLength 900
        next_human_step = Limit-Text -Text $NextHumanStep -MaxLength 700
        status = $Status
    }) | Out-Null
}

function Set-UnresolvedEntry {
    param(
        [string]$Title,
        [string]$Status,
        [string]$Evidence,
        [string]$NextStep
    )

    Ensure-ParentDirectory -Path $UnresolvedPath
    if (-not (Test-Path $UnresolvedPath)) {
        "# Unresolved Items`n`n## Open Questions`n" | Set-Content -Path $UnresolvedPath -Encoding UTF8
    }

    $today = Get-Date -Format "yyyy-MM-dd"
    $markerName = (($Title.ToLowerInvariant() -replace "[^a-z0-9]+", "-").Trim("-"))
    $startMarker = "<!-- unresolved:${markerName}:start -->"
    $endMarker = "<!-- unresolved:${markerName}:end -->"
    $entry = @"

$startMarker

## $today - $Title

- Status: $Status
- Evidence: $Evidence
- Next step: $NextStep

$endMarker
"@

    $current = Get-Content -Path $UnresolvedPath -Raw
    $pattern = "(?s)$([regex]::Escape($startMarker)).*?$([regex]::Escape($endMarker))"

    if ($current -match $pattern) {
        Set-Content -Path $UnresolvedPath -Value ([regex]::Replace($current, $pattern, $entry)) -Encoding UTF8
    }
    else {
        Add-Content -Path $UnresolvedPath -Value $entry -Encoding UTF8
    }
}

foreach ($path in @($DependenciesPath, $ExecutionsPath, $DurationByItemPath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$dependencyRows = @(Import-Csv -Path $DependenciesPath)
$executionRows = @(Import-Csv -Path $ExecutionsPath)
$durationRows = @(Import-Csv -Path $DurationByItemPath)

$jobRows = @($executionRows | Where-Object { $_.record_type -eq "job_instance" })
$scheduleRows = @($executionRows | Where-Object { $_.record_type -eq "schedule" })

$incomingDeps = @{}
$outgoingDeps = @{}
$executesOut = @{}
$dependencyEndpointSet = @{}

foreach ($dep in $dependencyRows) {
    $from = Get-FieldValue -Object $dep -Names @("from_qualified_name")
    $to = Get-FieldValue -Object $dep -Names @("to_qualified_name")
    $relationship = Get-FieldValue -Object $dep -Names @("relationship_type")
    if (-not $from -or -not $to) {
        continue
    }

    if (-not $outgoingDeps.ContainsKey($from)) { $outgoingDeps[$from] = 0 }
    if (-not $incomingDeps.ContainsKey($to)) { $incomingDeps[$to] = 0 }
    $outgoingDeps[$from] += 1
    $incomingDeps[$to] += 1

    if ($relationship -eq "executes") {
        if (-not $executesOut.ContainsKey($from)) {
            $executesOut[$from] = [System.Collections.Generic.List[string]]::new()
        }
        if (-not $executesOut[$from].Contains($to)) {
            $executesOut[$from].Add($to) | Out-Null
        }
    }

    $dependencyEndpointSet["$from|$to"] = $true
    $dependencyEndpointSet["$to|$from"] = $true
}

$durationByName = @{}
foreach ($row in $durationRows) {
    $qualifiedName = Get-FieldValue -Object $row -Names @("qualified_name")
    if (-not $qualifiedName) {
        continue
    }

    if (-not $durationByName.ContainsKey($qualifiedName)) {
        $durationByName[$qualifiedName] = [System.Collections.Generic.List[object]]::new()
    }
    $durationByName[$qualifiedName].Add($row) | Out-Null
}

$scheduleByName = @{}
foreach ($schedule in $scheduleRows) {
    $qualifiedName = Get-FieldValue -Object $schedule -Names @("qualified_name")
    if (-not $qualifiedName) {
        continue
    }

    if (-not $scheduleByName.ContainsKey($qualifiedName)) {
        $scheduleByName[$qualifiedName] = [pscustomobject]@{
            enabled = 0
            disabled = 0
            times = [System.Collections.Generic.List[string]]::new()
            zones = [System.Collections.Generic.List[string]]::new()
        }
    }

    if ((Get-FieldValue -Object $schedule -Names @("schedule_enabled")) -eq "True") {
        $scheduleByName[$qualifiedName].enabled += 1
    }
    else {
        $scheduleByName[$qualifiedName].disabled += 1
    }

    $timeText = Get-FieldValue -Object $schedule -Names @("scheduled_time")
    if ($timeText -and -not $scheduleByName[$qualifiedName].times.Contains($timeText)) {
        $scheduleByName[$qualifiedName].times.Add($timeText) | Out-Null
    }

    $zoneText = Get-FieldValue -Object $schedule -Names @("schedule_timezone")
    if ($zoneText -and -not $scheduleByName[$qualifiedName].zones.Contains($zoneText)) {
        $scheduleByName[$qualifiedName].zones.Add($zoneText) | Out-Null
    }
}

$criticalRows = @(
    $durationRows |
        Where-Object {
            (Convert-ToDouble $_.max_duration_seconds) -ge $LongRunMaxSeconds -or
            (Convert-ToDouble $_.avg_duration_seconds) -ge $LongRunAverageSeconds
        } |
        ForEach-Object {
            $qualifiedName = Get-FieldValue -Object $_ -Names @("qualified_name")
            [pscustomobject]@{
                workspace_name = $_.workspace_name
                item_name = $_.item_name
                item_type = $_.item_type
                qualified_name = $qualifiedName
                job_type = $_.job_type
                run_count = Convert-ToInt $_.run_count
                completed_count = Convert-ToInt $_.completed_count
                failed_count = Convert-ToInt $_.failed_count
                scheduled_count = Convert-ToInt $_.scheduled_count
                manual_count = Convert-ToInt $_.manual_count
                avg_duration_seconds = Convert-ToDouble $_.avg_duration_seconds
                max_duration_seconds = Convert-ToDouble $_.max_duration_seconds
                outgoing_dependencies = if ($outgoingDeps.ContainsKey($qualifiedName)) { $outgoingDeps[$qualifiedName] } else { 0 }
                incoming_dependencies = if ($incomingDeps.ContainsKey($qualifiedName)) { $incomingDeps[$qualifiedName] } else { 0 }
                enabled_schedules = if ($scheduleByName.ContainsKey($qualifiedName)) { $scheduleByName[$qualifiedName].enabled } else { 0 }
                recommendation_hint = "Review as critical-path candidate because runtime exceeds threshold."
            }
        } |
        Sort-Object -Property max_duration_seconds, avg_duration_seconds -Descending
)

$rank = 0
$criticalRows = @($criticalRows | ForEach-Object { $rank += 1; $_ | Add-Member -NotePropertyName rank -NotePropertyValue $rank -PassThru })

Ensure-ParentDirectory -Path $CriticalPathPath
$criticalRows | Export-Csv -Path $CriticalPathPath -NoTypeInformation -Encoding UTF8

$failureRows = @(
    $durationRows |
        Where-Object { (Convert-ToInt $_.failed_count) -ge $MinFailureCount } |
        ForEach-Object {
            $runCount = [math]::Max(1, (Convert-ToInt $_.run_count))
            $failedCount = Convert-ToInt $_.failed_count
            [pscustomobject]@{
                workspace_name = $_.workspace_name
                item_name = $_.item_name
                item_type = $_.item_type
                qualified_name = $_.qualified_name
                job_type = $_.job_type
                run_count = $runCount
                completed_count = Convert-ToInt $_.completed_count
                failed_count = $failedCount
                failure_rate = [math]::Round($failedCount / $runCount, 4)
                avg_duration_seconds = Convert-ToDouble $_.avg_duration_seconds
                max_duration_seconds = Convert-ToDouble $_.max_duration_seconds
                latest_start_time = $_.latest_start_time
                latest_end_time = $_.latest_end_time
                last_status = $_.last_status
                recommendation_hint = "Stabilize before optimizing schedule or parallelism."
            }
        } |
        Sort-Object -Property failed_count, failure_rate, max_duration_seconds -Descending
)

$rank = 0
$failureRows = @($failureRows | ForEach-Object { $rank += 1; $_ | Add-Member -NotePropertyName rank -NotePropertyValue $rank -PassThru })

Ensure-ParentDirectory -Path $FailureHotspotsPath
$failureRows | Export-Csv -Path $FailureHotspotsPath -NoTypeInformation -Encoding UTF8

$manualRows = @(
    $durationRows |
        Where-Object {
            (Convert-ToInt $_.manual_count) -ge $MinManualRuns -and
            (Convert-ToInt $_.scheduled_count) -eq 0
        } |
        ForEach-Object {
            $qualifiedName = Get-FieldValue -Object $_ -Names @("qualified_name")
            [pscustomobject]@{
                workspace_name = $_.workspace_name
                item_name = $_.item_name
                item_type = $_.item_type
                qualified_name = $qualifiedName
                job_type = $_.job_type
                run_count = Convert-ToInt $_.run_count
                manual_count = Convert-ToInt $_.manual_count
                scheduled_count = Convert-ToInt $_.scheduled_count
                failed_count = Convert-ToInt $_.failed_count
                avg_duration_seconds = Convert-ToDouble $_.avg_duration_seconds
                max_duration_seconds = Convert-ToDouble $_.max_duration_seconds
                enabled_schedules = if ($scheduleByName.ContainsKey($qualifiedName)) { $scheduleByName[$qualifiedName].enabled } else { 0 }
                recommendation_hint = "Repeated manual execution candidate for controlled orchestration or schedule."
            }
        } |
        Sort-Object -Property manual_count, max_duration_seconds -Descending
)

$rank = 0
$manualRows = @($manualRows | ForEach-Object { $rank += 1; $_ | Add-Member -NotePropertyName rank -NotePropertyValue $rank -PassThru })

Ensure-ParentDirectory -Path $ManualCandidatesPath
$manualRows | Export-Csv -Path $ManualCandidatesPath -NoTypeInformation -Encoding UTF8

$scheduleReviewRows = @(
    $scheduleByName.Keys |
        ForEach-Object {
            $qualifiedName = [string]$_
            $duration = if ($durationByName.ContainsKey($qualifiedName)) { @($durationByName[$qualifiedName] | Select-Object -First 1)[0] } else { $null }
            [pscustomobject]@{
                qualified_name = $qualifiedName
                workspace_name = if ($duration) { $duration.workspace_name } else { ($qualifiedName -split " / ")[0] }
                item_name = if ($duration) { $duration.item_name } else { ($qualifiedName -split " / " | Select-Object -Last 1) }
                item_type = if ($duration) { $duration.item_type } else { "" }
                enabled_schedules = $scheduleByName[$qualifiedName].enabled
                disabled_schedules = $scheduleByName[$qualifiedName].disabled
                schedule_times = (@($scheduleByName[$qualifiedName].times) -join "; ")
                schedule_timezones = (@($scheduleByName[$qualifiedName].zones) -join "; ")
                run_count = if ($duration) { Convert-ToInt $duration.run_count } else { 0 }
                failed_count = if ($duration) { Convert-ToInt $duration.failed_count } else { 0 }
                avg_duration_seconds = if ($duration) { Convert-ToDouble $duration.avg_duration_seconds } else { 0 }
                recommendation_hint = "Review disabled schedules and confirm only intentional schedules are enabled."
            }
        } |
        Sort-Object -Property enabled_schedules, disabled_schedules, failed_count -Descending
)

Ensure-ParentDirectory -Path $ScheduleReviewPath
$scheduleReviewRows | Export-Csv -Path $ScheduleReviewPath -NoTypeInformation -Encoding UTF8

$orchestrationRows = @(
    $executesOut.Keys |
        ForEach-Object {
            $qualifiedName = [string]$_
            $duration = if ($durationByName.ContainsKey($qualifiedName)) { @($durationByName[$qualifiedName] | Select-Object -First 1)[0] } else { $null }
            $targets = @($executesOut[$qualifiedName] | Sort-Object)
            [pscustomobject]@{
                source_qualified_name = $qualifiedName
                workspace_name = if ($duration) { $duration.workspace_name } else { ($qualifiedName -split " / ")[0] }
                item_name = if ($duration) { $duration.item_name } else { ($qualifiedName -split " / " | Select-Object -Last 1) }
                item_type = if ($duration) { $duration.item_type } else { "" }
                executes_count = $targets.Count
                executed_items = Limit-Text -Text ($targets -join "; ") -MaxLength 1600
                run_count = if ($duration) { Convert-ToInt $duration.run_count } else { 0 }
                failed_count = if ($duration) { Convert-ToInt $duration.failed_count } else { 0 }
                scheduled_count = if ($duration) { Convert-ToInt $duration.scheduled_count } else { 0 }
                manual_count = if ($duration) { Convert-ToInt $duration.manual_count } else { 0 }
                avg_duration_seconds = if ($duration) { Convert-ToDouble $duration.avg_duration_seconds } else { 0 }
                max_duration_seconds = if ($duration) { Convert-ToDouble $duration.max_duration_seconds } else { 0 }
                recommendation_hint = "Review fan-out for parallel-safe branches and explicit dependency ordering."
            }
        } |
        Where-Object { $_.executes_count -ge $MinExecuteFanOut } |
        Sort-Object -Property executes_count, max_duration_seconds -Descending
)

Ensure-ParentDirectory -Path $OrchestrationGroupsPath
$orchestrationRows | Export-Csv -Path $OrchestrationGroupsPath -NoTypeInformation -Encoding UTF8

$parallelRows = [System.Collections.Generic.List[object]]::new()
$manualByWorkspace = @{}
foreach ($row in $manualRows | Where-Object { $_.failed_count -eq 0 }) {
    if (-not $manualByWorkspace.ContainsKey($row.workspace_name)) {
        $manualByWorkspace[$row.workspace_name] = [System.Collections.Generic.List[object]]::new()
    }
    $manualByWorkspace[$row.workspace_name].Add($row) | Out-Null
}

foreach ($workspaceName in ($manualByWorkspace.Keys | Sort-Object)) {
    $workspaceRows = @($manualByWorkspace[$workspaceName] | Sort-Object -Property max_duration_seconds -Descending | Select-Object -First 8)
    if ($workspaceRows.Count -lt 2) {
        continue
    }

    for ($i = 0; $i -lt $workspaceRows.Count; $i++) {
        for ($j = $i + 1; $j -lt $workspaceRows.Count; $j++) {
            $a = $workspaceRows[$i]
            $b = $workspaceRows[$j]
            $key = "$($a.qualified_name)|$($b.qualified_name)"
            if ($dependencyEndpointSet.ContainsKey($key)) {
                continue
            }

            $parallelRows.Add([pscustomobject]@{
                workspace_name = $workspaceName
                candidate_a = $a.qualified_name
                candidate_b = $b.qualified_name
                item_type_a = $a.item_type
                item_type_b = $b.item_type
                manual_count_a = $a.manual_count
                manual_count_b = $b.manual_count
                max_duration_a_seconds = $a.max_duration_seconds
                max_duration_b_seconds = $b.max_duration_seconds
                expected_parallel_window_seconds = [math]::Min($a.max_duration_seconds, $b.max_duration_seconds)
                evidence = "No indexed dependency edge exists between these repeated manual jobs in the same workspace."
                recommendation_hint = "Candidate only; validate reads/writes before parallel execution."
            }) | Out-Null
        }
    }
}

$parallelRows = @($parallelRows | Sort-Object -Property expected_parallel_window_seconds, manual_count_a, manual_count_b -Descending | Select-Object -First 100)
Ensure-ParentDirectory -Path $ParallelCandidatesPath
$parallelRows | Export-Csv -Path $ParallelCandidatesPath -NoTypeInformation -Encoding UTF8

$recommendations = [System.Collections.Generic.List[object]]::new()

foreach ($row in ($criticalRows | Select-Object -First $MaxRecommendationsPerCategory)) {
    Add-Recommendation `
        -Rows $recommendations `
        -ScopeName $row.qualified_name `
        -RecommendationType "critical_path_candidate" `
        -CurrentState "Runtime is high: avg=$($row.avg_duration_seconds)s, max=$($row.max_duration_seconds)s, runs=$($row.run_count), manual=$($row.manual_count), scheduled=$($row.scheduled_count)." `
        -ProposedState "Profile this item as part of the critical path. Split independent work, cache reusable data, or move independent child work into parallel branches only after dependency review." `
        -ExpectedBenefit "Reduces the longest observed execution windows and can shorten downstream idle time." `
        -Risk "Parallelizing without code-level read/write validation can create incomplete data or race conditions." `
        -Evidence "analysis/execution_duration_by_item.csv rank $($row.rank); incoming dependencies=$($row.incoming_dependencies); outgoing dependencies=$($row.outgoing_dependencies)." `
        -NextHumanStep "Open the item in Fabric and review activities/notebook cells/source tables; approve a non-prod timing test before changing production orchestration."
}

foreach ($row in ($failureRows | Select-Object -First $MaxRecommendationsPerCategory)) {
    Add-Recommendation `
        -Rows $recommendations `
        -ScopeName $row.qualified_name `
        -RecommendationType "stabilize_failure_hotspot" `
        -CurrentState "Failures observed: failed=$($row.failed_count), runs=$($row.run_count), failure_rate=$($row.failure_rate), last_status=$($row.last_status)." `
        -ProposedState "Stabilize failure causes before adding parallelism or tightening schedule windows." `
        -ExpectedBenefit "Improves reliability and prevents optimized orchestration from amplifying known failures." `
        -Risk "Changing schedules without fixing failures can increase retries, contention, and downstream stale data." `
        -Evidence "analysis/failure_hotspots.csv; latest_start=$($row.latest_start_time); latest_end=$($row.latest_end_time)." `
        -NextHumanStep "Review recent failed run details in Fabric Monitoring Hub, identify root cause, then approve retry/error-handling changes if needed."
}

foreach ($row in ($manualRows | Select-Object -First $MaxRecommendationsPerCategory)) {
    Add-Recommendation `
        -Rows $recommendations `
        -ScopeName $row.qualified_name `
        -RecommendationType "convert_repeated_manual_to_orchestrated" `
        -CurrentState "Repeated manual execution: manual=$($row.manual_count), scheduled=$($row.scheduled_count), enabled_schedules=$($row.enabled_schedules), max_duration=$($row.max_duration_seconds)s." `
        -ProposedState "Evaluate whether this should be called by a controlled orchestration pipeline or scheduled trigger with explicit upstream readiness checks." `
        -ExpectedBenefit "Reduces manual intervention and makes execution order auditable." `
        -Risk "A schedule without upstream dependency checks can start before source data is ready." `
        -Evidence "analysis/manual_execution_candidates.csv." `
        -NextHumanStep "Confirm business owner, expected cadence, and upstream source readiness before proposing a schedule or pipeline activity."
}

foreach ($row in ($orchestrationRows | Select-Object -First $MaxRecommendationsPerCategory)) {
    Add-Recommendation `
        -Rows $recommendations `
        -ScopeName $row.source_qualified_name `
        -RecommendationType "review_orchestration_fanout" `
        -CurrentState "This orchestration source executes $($row.executes_count) downstream items; failures=$($row.failed_count), max_duration=$($row.max_duration_seconds)s." `
        -ProposedState "Review child activities and classify them as must-run-before, can-run-parallel, or optional/retryable; then design explicit branches." `
        -ExpectedBenefit "Can reduce idle time and improve observability of multi-step orchestration." `
        -Risk "Some fan-out children may write to shared tables or depend on implicit state not visible in the current graph." `
        -Evidence "analysis/orchestration_group_candidates.csv; executed_items=$($row.executed_items)." `
        -NextHumanStep "Open pipeline/activity graph and validate child dependencies with the technical owner before changing branch order."
}

$disabledSchedules = @($scheduleReviewRows | Where-Object { $_.disabled_schedules -gt 0 })
if ($disabledSchedules.Count -gt 0) {
    Add-Recommendation `
        -Rows $recommendations `
        -ScopeName "All Fabric execution targets" `
        -RecommendationType "review_disabled_schedules" `
        -CurrentState "$($disabledSchedules.Count) items have disabled schedule records; total disabled schedules=$(@($scheduleRows | Where-Object { $_.schedule_enabled -eq "False" }).Count)." `
        -ProposedState "Confirm disabled schedules are intentional, especially for semantic models serving reports and pipelines with downstream dependencies." `
        -ExpectedBenefit "Avoids silent non-refresh and stale downstream reports." `
        -Risk "Blindly enabling schedules can duplicate work or conflict with manual/orchestrated runs." `
        -Evidence "analysis/schedule_review_candidates.csv and index/executions.csv." `
        -NextHumanStep "Review disabled schedule candidates with workspace owners; only approve enabling when cadence and upstream readiness are confirmed."
}

if ($parallelRows.Count -gt 0) {
    foreach ($row in ($parallelRows | Select-Object -First 10)) {
        Add-Recommendation `
            -Rows $recommendations `
            -ScopeName $row.workspace_name `
            -RecommendationType "candidate_parallel_execution" `
            -CurrentState "Two repeated manual jobs in the same workspace have no indexed dependency edge: A=$($row.candidate_a); B=$($row.candidate_b)." `
            -ProposedState "Test parallel execution in non-production only after validating that they do not write to the same tables/files or depend on shared mutable state." `
            -ExpectedBenefit "Potentially saves up to about $($row.expected_parallel_window_seconds)s in wall-clock time for this pair." `
            -Risk "The graph does not yet include all notebook code-level reads/writes, so this is a candidate, not approval." `
            -Evidence "analysis/parallelism_candidates.csv." `
            -NextHumanStep "Inspect both item definitions/code and run a controlled non-prod parallel timing test before production change."
    }
}

Add-Recommendation `
    -Rows $recommendations `
    -ScopeName "Overall orchestration program" `
    -RecommendationType "phase7_governance" `
    -CurrentState "The graph still has likely (unconfirmed) dependencies, Phase 4 item-analysis gaps, and Phase 6 timing gaps." `
    -ProposedState "Use recommendations as a review backlog. Do not apply production orchestration changes until likely dependencies and gaps are reviewed by item owners." `
    -ExpectedBenefit "Keeps optimization cost-aware and avoids incomplete downstream data." `
    -Risk "Acting on candidate relationships without human review can cause missed refreshes or unsafe parallelism." `
    -Evidence "index/dependencies.csv, index/unresolved.md, analysis/execution_query_gaps.csv." `
    -NextHumanStep "Prioritize top critical-path and failure-hotspot rows, then approve a scoped non-prod pilot."

Ensure-ParentDirectory -Path $OutputPath
$recommendations |
    Select-Object -Property $recommendationColumns |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

$humanPlan = @'
# Phase 7 Human Orchestration Change Plan

No external Fabric changes were made by this analysis.

## Review Order

1. Review `analysis/failure_hotspots.csv` and stabilize failing jobs before schedule or parallelism changes.
2. Review `analysis/critical_path_candidates.csv` to identify the longest-running jobs and likely critical path items.
3. Review `analysis/orchestration_group_candidates.csv` for pipelines or variables that already fan out into many downstream activities.
4. Review `analysis/manual_execution_candidates.csv` for repeated manual jobs that may need controlled orchestration.
5. Review `analysis/schedule_review_candidates.csv` to confirm disabled schedules are intentional.
6. Review `analysis/parallelism_candidates.csv` only as candidates; validate code-level reads/writes before any parallel execution.

## Human Approval Steps

1. Select one non-production workspace or one low-risk production workflow.
2. Confirm every dependency for the selected workflow with the workspace owner.
3. Confirm source data readiness, expected cadence, and downstream report/model requirements.
4. Draft the proposed Fabric change in human-readable steps.
5. Obtain human approval.
6. Execute the approved change manually in Fabric.
7. Re-run Phase 6 timing and compare duration/failure metrics.

## Do Not Do Yet

- Do not enable disabled schedules blindly.
- Do not parallelize notebook or pipeline steps without validating writes and shared state.
- Do not optimize workflows with unresolved high failure rates before stabilizing them.
- Do not treat `likely` dependency edges as final proof without owner review.
'@

Ensure-ParentDirectory -Path $HumanActionPlanPath
$humanPlan | Set-Content -Path $HumanActionPlanPath -Encoding UTF8

Set-UnresolvedEntry `
    -Title "Phase 7 optimization review gaps" `
    -Status "open" `
    -Evidence "Recommendations generated, but likely dependencies, Phase 4 item-analysis gaps, and Phase 6 timing gaps require human review before external changes." `
    -NextStep "Review analysis/orchestration_recommendations.csv and approve one scoped non-production pilot before any Fabric changes."

Write-Host "Phase 7 orchestration optimization analysis completed."
Write-Host "Recommendations: $($recommendations.Count)"
Write-Host "Critical path candidates: $($criticalRows.Count)"
Write-Host "Failure hotspots: $($failureRows.Count)"
Write-Host "Manual execution candidates: $($manualRows.Count)"
Write-Host "Schedule review candidates: $($scheduleReviewRows.Count)"
Write-Host "Orchestration group candidates: $($orchestrationRows.Count)"
Write-Host "Parallelism candidates: $($parallelRows.Count)"
Write-Host "Output: $OutputPath"
Write-Host "Human plan: $HumanActionPlanPath"
