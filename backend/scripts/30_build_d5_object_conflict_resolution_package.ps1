# Phase 30 - D5 package: the cleanup-plan category for object write
# conflicts (Phase 24) -- packages each conflict's participants and
# candidate guard edges into a queue plus a manual decision template for
# choosing how to resolve each one. Purely local.
# Writes: $OutputConflictQueuePath, $OutputGuardEdgeQueuePath,
# $OutputParticipantsPath, $OutputSummaryPath, $OutputDecisionTemplatePath,
# $OutputReadonlyTargetsPath, $OutputDocPath.
param(
    [string]$ObjectConflictsPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_object_conflicts.csv"),
    [string]$OrchestrationV2EdgesPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_edges.csv"),
    [string]$OrchestrationV2PlanPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_plan.csv"),
    [string]$ObjectReadWriteClassificationPath = (Join-Path $PSScriptRoot "../../analysis/object_read_write_classification.csv"),
    [string]$CleanupQueuePath = (Join-Path $PSScriptRoot "../../analysis/likely_conflict_cleanup_queue.csv"),
    [string]$OutputConflictQueuePath = (Join-Path $PSScriptRoot "../../analysis/d5_object_conflict_queue.csv"),
    [string]$OutputGuardEdgeQueuePath = (Join-Path $PSScriptRoot "../../analysis/d5_object_guard_edge_queue.csv"),
    [string]$OutputParticipantsPath = (Join-Path $PSScriptRoot "../../analysis/d5_object_conflict_participants.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d5_object_conflict_summary.csv"),
    [string]$OutputDecisionTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d5_object_conflict_decision_template.csv"),
    [string]$OutputReadonlyTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d5_readonly_conflict_review_targets.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/27_d5_object_conflict_resolution.md")
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
    param([hashtable]$Map, [string]$Key)
    $normalized = Normalize-Key -Value $Key
    if ($normalized -and $Map.ContainsKey($normalized)) { return $Map[$normalized] }
    return $null
}

function Get-PriorityBand {
    param([int]$PriorityScore)
    if ($PriorityScore -ge 200) { return "critical" }
    if ($PriorityScore -ge 130) { return "high" }
    if ($PriorityScore -ge 90) { return "medium" }
    return "low"
}

function Get-DecisionReadiness {
    param([string]$ObjectReadiness, [string]$ConflictTypes)
    if ($ObjectReadiness -eq "blocked_until_lineage_and_type_confirmed") {
        return "blocked_by_d3_d4_evidence"
    }
    if ($ConflictTypes -like "*execute_dependency_review*") { return "execute_order_review" }
    if ($ConflictTypes -like "*writer_reader_ordering*") { return "writer_before_reader_review" }
    if ($ConflictTypes -like "*multiple_writers*") { return "writer_order_review" }
    return "manual_conflict_review"
}

function Get-DecisionOptions {
    param([string]$DecisionReadiness)
    switch ($DecisionReadiness) {
        "blocked_by_d3_d4_evidence" { return "blocked_until_d3_d4_confirmed; then decide writer_order, writer_before_reader, safe_parallel, or false_conflict" }
        "execute_order_review" { return "serialize_execute_after_writers; confirm_invocation_dependency; blocked; false_conflict" }
        "writer_before_reader_review" { return "writer_before_reader; safe_parallel_readers_after_writer; blocked; false_conflict" }
        "writer_order_review" { return "serialize_writers; partitioned_writes_safe_parallel; blocked; false_conflict" }
        default { return "serialize; safe_parallel; blocked; false_conflict" }
    }
}

function Escape-MdCell {
    param([string]$Value)
    if (-not $Value) { return "" }
    return (($Value -replace "\|", "/") -replace "`r?`n", " ").Trim()
}

foreach ($path in @($ObjectConflictsPath, $OrchestrationV2EdgesPath, $OrchestrationV2PlanPath, $ObjectReadWriteClassificationPath, $CleanupQueuePath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$conflictRows = @(Import-Csv -Path $ObjectConflictsPath)
$edgeRows = @(Import-Csv -Path $OrchestrationV2EdgesPath)
$planRows = @(Import-Csv -Path $OrchestrationV2PlanPath)
$readWriteRows = @(Import-Csv -Path $ObjectReadWriteClassificationPath)
$cleanupRows = @(Import-Csv -Path $CleanupQueuePath)

$planByQualifiedName = @{}
foreach ($row in $planRows) {
    Set-FirstMapValue -Map $planByQualifiedName -Key (Get-FieldValue -Object $row -Names @("qualified_name", "item_qualified_name")) -Value $row
}

$d5CleanupByObject = @{}
foreach ($row in ($cleanupRows | Where-Object { $_.phase_id -eq "D5" })) {
    Set-FirstMapValue -Map $d5CleanupByObject -Key (Get-FieldValue -Object $row -Names @("object_key")) -Value $row
}

$guardEdges = @($edgeRows | Where-Object { $_.v2_relationship_type -like "object_*" })
$guardEdgesByObject = @{}
foreach ($row in $guardEdges) {
    $key = Normalize-Key -Value (Get-FieldValue -Object $row -Names @("object_key"))
    if (-not $key) { continue }
    if (-not $guardEdgesByObject.ContainsKey($key)) {
        $guardEdgesByObject[$key] = [System.Collections.Generic.List[object]]::new()
    }
    $guardEdgesByObject[$key].Add($row) | Out-Null
}

$participantsByObject = @{}
foreach ($row in $readWriteRows) {
    $key = Normalize-Key -Value (Get-FieldValue -Object $row -Names @("object_key"))
    if (-not $key) { continue }
    if (-not $participantsByObject.ContainsKey($key)) {
        $participantsByObject[$key] = [System.Collections.Generic.List[object]]::new()
    }
    $participantsByObject[$key].Add($row) | Out-Null
}

$conflictQueueRows = [System.Collections.Generic.List[object]]::new()
$decisionRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()
$conflictIdByObject = @{}
$sequence = 0

foreach ($row in ($conflictRows | Sort-Object @{ Expression = { (Convert-ToInt (Get-FieldValue -Object $_ -Names @("writer_count"))) + (Convert-ToInt (Get-FieldValue -Object $_ -Names @("reader_count"))) + (Convert-ToInt (Get-FieldValue -Object $_ -Names @("executor_count"))) }; Descending = $true }, object_display_name)) {
    $sequence += 1
    $conflictId = "D5C{0:D5}" -f $sequence
    $objectKey = Get-FieldValue -Object $row -Names @("object_key")
    $normalizedObjectKey = Normalize-Key -Value $objectKey
    $conflictIdByObject[$normalizedObjectKey] = $conflictId
    $cleanup = Get-MapValue -Map $d5CleanupByObject -Key $objectKey
    $objectGuardEdges = @()
    if ($normalizedObjectKey -and $guardEdgesByObject.ContainsKey($normalizedObjectKey)) { $objectGuardEdges = @($guardEdgesByObject[$normalizedObjectKey]) }
    $participants = @()
    if ($normalizedObjectKey -and $participantsByObject.ContainsKey($normalizedObjectKey)) { $participants = @($participantsByObject[$normalizedObjectKey]) }

    $readerCount = Convert-ToInt (Get-FieldValue -Object $row -Names @("reader_count"))
    $writerCount = Convert-ToInt (Get-FieldValue -Object $row -Names @("writer_count"))
    $executorCount = Convert-ToInt (Get-FieldValue -Object $row -Names @("executor_count"))
    $priorityScore = Convert-ToInt (Get-FieldValue -Object $cleanup -Names @("priority_score"))
    if ($priorityScore -eq 0) {
        $priorityScore = 80 + ($writerCount * 10) + ($readerCount * 3) + ($executorCount * 4)
    }
    $conflictTypes = Get-FieldValue -Object $row -Names @("conflict_types")
    $objectReadiness = Get-FieldValue -Object $row -Names @("object_readiness")
    $decisionReadiness = Get-DecisionReadiness -ObjectReadiness $objectReadiness -ConflictTypes $conflictTypes
    $decisionOptions = Get-DecisionOptions -DecisionReadiness $decisionReadiness
    $edgeTypeCounts = ((@($objectGuardEdges | Group-Object v2_relationship_type | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join "; ")
    $participantTypeCounts = ((@($participants | Group-Object item_type | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join "; ")
    $operationCounts = ((@($participants | Group-Object operation_type | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join "; ")

    $conflictQueueRows.Add([pscustomobject]@{
        conflict_id = $conflictId
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        object_key = $objectKey
        object_display_name = Get-FieldValue -Object $row -Names @("object_display_name")
        source_types = Get-FieldValue -Object $row -Names @("source_types")
        object_types = Get-FieldValue -Object $row -Names @("object_types")
        reader_count = $readerCount
        writer_count = $writerCount
        executor_count = $executorCount
        exact_row_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("exact_row_count"))
        ambiguous_row_count = Convert-ToInt (Get-FieldValue -Object $row -Names @("ambiguous_row_count"))
        conflict_types = $conflictTypes
        object_readiness = $objectReadiness
        decision_readiness = $decisionReadiness
        guard_edge_count = $objectGuardEdges.Count
        guard_edge_types = $edgeTypeCounts
        participant_row_count = $participants.Count
        participant_item_types = $participantTypeCounts
        participant_operations = $operationCounts
        statuses = Limit-Text -Text (Get-FieldValue -Object $row -Names @("statuses")) -MaxLength 900
        sample_readers = Limit-Text -Text (Get-FieldValue -Object $row -Names @("sample_readers")) -MaxLength 900
        sample_writers = Limit-Text -Text (Get-FieldValue -Object $row -Names @("sample_writers")) -MaxLength 900
        sample_executors = Limit-Text -Text (Get-FieldValue -Object $row -Names @("sample_executors")) -MaxLength 900
        recommended_next_action = Limit-Text -Text (Get-FieldValue -Object $row -Names @("recommended_next_action")) -MaxLength 900
        decision_options = $decisionOptions
        d5_gate_to_close = "Record a reviewed conflict decision: serialize writers, enforce writer-before-reader, prove safe parallelism, reject false conflict, or block pending D3/D4 evidence."
    }) | Out-Null

    $decisionRows.Add([pscustomobject]@{
        conflict_id = $conflictId
        object_key = $objectKey
        object_display_name = Get-FieldValue -Object $row -Names @("object_display_name")
        conflict_types = $conflictTypes
        object_readiness = $objectReadiness
        decision_readiness = $decisionReadiness
        current_reader_count = $readerCount
        current_writer_count = $writerCount
        current_executor_count = $executorCount
        proposed_decision = ""
        proposed_writer_order = ""
        proposed_reader_rule = ""
        proposed_execute_rule = ""
        safe_parallel_groups = ""
        blocked_reason = ""
        confirmation_source = ""
        confirmation_evidence = ""
        reviewer = ""
        reviewed_at = ""
        notes = "D5 template row. Use decisions such as serialize_writers, writer_before_reader, execute_after_writers, safe_parallel_partitioned, false_conflict, or blocked_pending_d3_d4."
    }) | Out-Null

    $readonlyRows.Add([pscustomobject]@{
        conflict_id = $conflictId
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        object_display_name = Get-FieldValue -Object $row -Names @("object_display_name")
        conflict_types = $conflictTypes
        object_readiness = $objectReadiness
        decision_readiness = $decisionReadiness
        readonly_method = "Review D3 lineage evidence, D4 exact type evidence, writer item definitions, reader dependencies, execution history, and owner evidence before selecting a conflict decision."
        template_path = $OutputDecisionTemplatePath
        notes = "Read-only/manual review target. Do not update schedules or orchestration rules from this package alone."
    }) | Out-Null
}

$guardQueueRows = [System.Collections.Generic.List[object]]::new()
$guardSequence = 0
foreach ($edge in $guardEdges) {
    $guardSequence += 1
    $objectKey = Get-FieldValue -Object $edge -Names @("object_key")
    $conflictId = ""
    $normalizedObjectKey = Normalize-Key -Value $objectKey
    if ($normalizedObjectKey -and $conflictIdByObject.ContainsKey($normalizedObjectKey)) { $conflictId = $conflictIdByObject[$normalizedObjectKey] }
    $upstream = Get-FieldValue -Object $edge -Names @("upstream_qualified_name")
    $downstream = Get-FieldValue -Object $edge -Names @("downstream_qualified_name")
    $upstreamPlan = Get-MapValue -Map $planByQualifiedName -Key $upstream
    $downstreamPlan = Get-MapValue -Map $planByQualifiedName -Key $downstream

    $guardQueueRows.Add([pscustomobject]@{
        guard_id = ("D5G{0:D6}" -f $guardSequence)
        conflict_id = $conflictId
        object_key = $objectKey
        upstream_qualified_name = $upstream
        downstream_qualified_name = $downstream
        v2_relationship_type = Get-FieldValue -Object $edge -Names @("v2_relationship_type")
        source_relationship_type = Get-FieldValue -Object $edge -Names @("source_relationship_type")
        edge_status = Get-FieldValue -Object $edge -Names @("edge_status")
        confidence = Get-FieldValue -Object $edge -Names @("confidence")
        upstream_v2_status = Get-FieldValue -Object $upstreamPlan -Names @("v2_status")
        downstream_v2_status = Get-FieldValue -Object $downstreamPlan -Names @("v2_status")
        upstream_estimated_duration_seconds = Get-FieldValue -Object $upstreamPlan -Names @("estimated_duration_seconds")
        downstream_estimated_duration_seconds = Get-FieldValue -Object $downstreamPlan -Names @("estimated_duration_seconds")
        evidence = Limit-Text -Text (Get-FieldValue -Object $edge -Names @("evidence")) -MaxLength 900
        d5_gate_to_close = "Keep, modify, or remove this guard only after conflict decision is reviewed."
    }) | Out-Null
}

$participantRows = [System.Collections.Generic.List[object]]::new()
$participantSequence = 0
foreach ($conflict in $conflictRows) {
    $objectKey = Get-FieldValue -Object $conflict -Names @("object_key")
    $normalizedObjectKey = Normalize-Key -Value $objectKey
    $conflictId = ""
    if ($normalizedObjectKey -and $conflictIdByObject.ContainsKey($normalizedObjectKey)) { $conflictId = $conflictIdByObject[$normalizedObjectKey] }
    $participants = @()
    if ($normalizedObjectKey -and $participantsByObject.ContainsKey($normalizedObjectKey)) { $participants = @($participantsByObject[$normalizedObjectKey]) }
    foreach ($participant in $participants) {
        $participantSequence += 1
        $participantRows.Add([pscustomobject]@{
            participant_id = ("D5P{0:D6}" -f $participantSequence)
            conflict_id = $conflictId
            object_key = $objectKey
            object_display_name = Get-FieldValue -Object $participant -Names @("object_display_name")
            workspace_name = Get-FieldValue -Object $participant -Names @("workspace_name")
            item_type = Get-FieldValue -Object $participant -Names @("item_type")
            item_name = Get-FieldValue -Object $participant -Names @("item_name")
            item_qualified_name = Get-FieldValue -Object $participant -Names @("item_qualified_name")
            operation_type = Get-FieldValue -Object $participant -Names @("operation_type")
            source_type = Get-FieldValue -Object $participant -Names @("source_type")
            object_type = Get-FieldValue -Object $participant -Names @("object_type")
            object_type_status = Get-FieldValue -Object $participant -Names @("object_type_status")
            lineage_confidence = Get-FieldValue -Object $participant -Names @("lineage_confidence")
            scheduling_readiness = Get-FieldValue -Object $participant -Names @("scheduling_readiness")
            orchestration_parallel_readiness = Get-FieldValue -Object $participant -Names @("orchestration_parallel_readiness")
            evidence = Limit-Text -Text (Get-FieldValue -Object $participant -Names @("evidence")) -MaxLength 900
        }) | Out-Null
    }
}

$conflictColumns = @(
    "conflict_id", "priority_score", "priority_band", "object_key", "object_display_name", "source_types",
    "object_types", "reader_count", "writer_count", "executor_count", "exact_row_count", "ambiguous_row_count",
    "conflict_types", "object_readiness", "decision_readiness", "guard_edge_count", "guard_edge_types",
    "participant_row_count", "participant_item_types", "participant_operations", "statuses", "sample_readers",
    "sample_writers", "sample_executors", "recommended_next_action", "decision_options", "d5_gate_to_close"
)
$guardColumns = @(
    "guard_id", "conflict_id", "object_key", "upstream_qualified_name", "downstream_qualified_name",
    "v2_relationship_type", "source_relationship_type", "edge_status", "confidence", "upstream_v2_status",
    "downstream_v2_status", "upstream_estimated_duration_seconds", "downstream_estimated_duration_seconds",
    "evidence", "d5_gate_to_close"
)
$participantColumns = @(
    "participant_id", "conflict_id", "object_key", "object_display_name", "workspace_name", "item_type",
    "item_name", "item_qualified_name", "operation_type", "source_type", "object_type", "object_type_status",
    "lineage_confidence", "scheduling_readiness", "orchestration_parallel_readiness", "evidence"
)
$decisionColumns = @(
    "conflict_id", "object_key", "object_display_name", "conflict_types", "object_readiness", "decision_readiness",
    "current_reader_count", "current_writer_count", "current_executor_count", "proposed_decision",
    "proposed_writer_order", "proposed_reader_rule", "proposed_execute_rule", "safe_parallel_groups",
    "blocked_reason", "confirmation_source", "confirmation_evidence", "reviewer", "reviewed_at", "notes"
)
$readonlyColumns = @("conflict_id", "priority_score", "priority_band", "object_display_name", "conflict_types", "object_readiness", "decision_readiness", "readonly_method", "template_path", "notes")

$conflictSorted = @($conflictQueueRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, object_display_name)
$guardSorted = @($guardQueueRows | Sort-Object conflict_id, v2_relationship_type, upstream_qualified_name, downstream_qualified_name)
$participantSorted = @($participantRows | Sort-Object conflict_id, operation_type, item_qualified_name)
$decisionSorted = @($decisionRows | Sort-Object conflict_id)
$readonlySorted = @($readonlyRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, conflict_id)

Export-Rows -Rows $conflictSorted -Columns $conflictColumns -Path $OutputConflictQueuePath
Export-Rows -Rows $guardSorted -Columns $guardColumns -Path $OutputGuardEdgeQueuePath
Export-Rows -Rows $participantSorted -Columns $participantColumns -Path $OutputParticipantsPath
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

Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D5 object conflicts" -GroupRows @($conflictQueueRows) -Notes "Object conflicts from analysis/orchestration_v2_object_conflicts.csv."
Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D5 guard edges" -GroupRows @($guardQueueRows) -Notes "Object guard edges from analysis/orchestration_v2_edges.csv."
Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D5 conflict participants" -GroupRows @($participantRows) -Notes "Read/write/execute rows participating in conflict objects."
foreach ($group in ($conflictQueueRows | Group-Object conflict_types | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "conflict_types" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "Conflicts grouped by conflict type set."
}
foreach ($group in ($conflictQueueRows | Group-Object object_readiness | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "object_readiness" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "Conflicts grouped by evidence/readiness gate."
}
foreach ($group in ($conflictQueueRows | Group-Object decision_readiness | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "decision_readiness" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "Conflicts grouped by the next decision kind."
}
foreach ($group in ($guardQueueRows | Group-Object v2_relationship_type | Sort-Object Count -Descending)) {
    $rows = @($group.Group | ForEach-Object { [pscustomobject]@{ priority_score = 0; priority_band = "low" } })
    Add-SummaryRow -Rows $summaryRows -SummaryScope "guard_type" -GroupKey $group.Name -GroupRows $rows -Notes "Guard edges grouped by guard type."
}
foreach ($group in ($participantRows | Group-Object operation_type | Sort-Object Count -Descending)) {
    $rows = @($group.Group | ForEach-Object { [pscustomobject]@{ priority_score = 0; priority_band = "low" } })
    Add-SummaryRow -Rows $summaryRows -SummaryScope "participant_operation" -GroupKey $group.Name -GroupRows $rows -Notes "Conflict participants grouped by operation type."
}

Export-Rows -Rows @($summaryRows) -Columns @("summary_scope", "group_key", "row_count", "high_or_critical_count", "max_priority_score", "notes") -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$generatedAt = (Get-Date).ToString("s")
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D5 Object Conflict Resolution Package") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated: $generatedAt") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D5 focuses on writer-reader, multi-writer, and execute dependency conflicts detected by orchestration v2. The package is local-only and does not modify Fabric, Power BI, SQL, OneLake, schedules, deployment pipelines, repositories, or orchestration rules.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Current Baseline") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- D5 object conflicts: $($conflictQueueRows.Count)") | Out-Null
$doc.Add("- D5 guard edges: $($guardQueueRows.Count)") | Out-Null
$doc.Add("- D5 conflict participant rows: $($participantRows.Count)") | Out-Null
$doc.Add("- Decision template rows: $($decisionRows.Count)") | Out-Null
$doc.Add("- Read-only/manual target rows: $($readonlyRows.Count)") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Conflict-Type Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($conflictQueueRows | Group-Object conflict_types | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Readiness Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($conflictQueueRows | Group-Object object_readiness | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Top Priority Conflicts") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("| Priority | Object | Readers | Writers | Executes | Readiness | Decision |") | Out-Null
$doc.Add("| --- | --- | --- | --- | --- | --- | --- |") | Out-Null
foreach ($row in ($conflictSorted | Select-Object -First 15)) {
    $doc.Add("| $($row.priority_score) | $(Escape-MdCell $row.object_display_name) | $($row.reader_count) | $($row.writer_count) | $($row.executor_count) | $(Escape-MdCell $row.object_readiness) | $(Escape-MdCell $row.decision_readiness) |") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- analysis/d5_object_conflict_queue.csv") | Out-Null
$doc.Add("- analysis/d5_object_guard_edge_queue.csv") | Out-Null
$doc.Add("- analysis/d5_object_conflict_participants.csv") | Out-Null
$doc.Add("- analysis/d5_object_conflict_summary.csv") | Out-Null
$doc.Add("- analysis/d5_object_conflict_decision_template.csv") | Out-Null
$doc.Add("- analysis/d5_readonly_conflict_review_targets.csv") | Out-Null
$doc.Add("- docs/27_d5_object_conflict_resolution.md") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## How To Close D5 Rows") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('1. Work `analysis/d5_object_conflict_queue.csv` in priority order.') | Out-Null
$doc.Add('2. Use `analysis/d5_object_conflict_participants.csv` to inspect readers, writers, and executors for the conflict object.') | Out-Null
$doc.Add('3. Use `analysis/d5_object_guard_edge_queue.csv` to inspect the blocked guard edges that orchestration v2 currently emits.') | Out-Null
$doc.Add('4. Record decisions in `analysis/d5_object_conflict_decision_template.csv`.') | Out-Null
$doc.Add('5. Valid decisions include `serialize_writers`, `writer_before_reader`, `execute_after_writers`, `safe_parallel_partitioned`, `false_conflict`, or `blocked_pending_d3_d4`.') | Out-Null
$doc.Add("6. Do not remove or relax guard edges until D3 lineage and D4 exact type evidence are confirmed for the object.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Gate") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D5 is closed only when high-priority object conflicts have a reviewed decision with evidence. This package is evidence preparation and does not approve scheduling or orchestration changes.") | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D5 object conflict resolution package completed."
Write-Host "Object conflicts: $($conflictQueueRows.Count)"
Write-Host "Guard edges: $($guardQueueRows.Count)"
Write-Host "Participants: $($participantRows.Count)"
Write-Host "Output: $OutputConflictQueuePath"
