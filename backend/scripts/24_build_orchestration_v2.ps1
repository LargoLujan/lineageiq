# Phase 24 - Orchestration v2: refines Phase 13's ideal execution plan
# using Phase 23's read/write classification to detect real object-level
# write conflicts (two items writing the same object with no dependency
# between them) that a purely item-level plan would miss, and re-derives
# parallelism candidates accounting for those conflicts. Purely local.
# Writes: $OutputPlanPath/$OutputEdgesPath/$OutputWavesPath/
# $OutputObjectConflictsPath/$OutputParallelPath/$OutputSummaryPath,
# $MermaidPath, $DocumentationPath.
param(
    [string]$IdealPlanPath = (Join-Path $PSScriptRoot "../../analysis/ideal_execution_plan.csv"),
    [string]$IdealEdgesPath = (Join-Path $PSScriptRoot "../../analysis/ideal_execution_edges.csv"),
    [string]$ReadWritePath = (Join-Path $PSScriptRoot "../../analysis/object_read_write_classification.csv"),
    [string]$ParallelCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/parallelism_candidates.csv"),
    [string]$OutputPlanPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_plan.csv"),
    [string]$OutputEdgesPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_edges.csv"),
    [string]$OutputWavesPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_waves.csv"),
    [string]$OutputObjectConflictsPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_object_conflicts.csv"),
    [string]$OutputParallelPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_parallel_candidates.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_summary.csv"),
    [string]$MermaidPath = (Join-Path $PSScriptRoot "../../diagrams/orchestration_v2_pipeline.mmd"),
    [string]$DocumentationPath = (Join-Path $PSScriptRoot "../../docs/21_orchestration_v2_design.md"),
    [int]$MaxObjectConstraintPairsPerObject = 200,
    [int]$DiagramWaveLimit = 12
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

function Import-OptionalCsv {
    param([string]$Path)
    if (Test-Path $Path) { return @(Import-Csv -Path $Path) }
    return @()
}

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

function Normalize-Key {
    param([string]$Value)
    if (-not $Value) { return "" }
    return ($Value.ToLowerInvariant() -replace "\s+", " ").Trim()
}

function Convert-ToInt {
    param([object]$Value)
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    try { return [int][double]$Value } catch { return 0 }
}

function Convert-ToDouble {
    param([object]$Value)
    # [double]$Value (a bare cast) parses via invariant culture, which
    # treats "," as a thousands separator -- so a comma-decimal string
    # like "144,462" (written by 13_build_ideal_execution_plan.ps1's own
    # Export-Csv on this es-ES machine) silently becomes 144462 instead
    # of 144.462. Same bug found and fixed in 07_optimize_orchestration.
    # ps1 and 13_build_ideal_execution_plan.ps1's identical functions.
    # TryParse's 2-arg overload uses CurrentCulture instead, matching how
    # these strings were written in the first place.
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return 0.0
}

function Limit-Text {
    param([string]$Text, [int]$MaxLength = 700)
    if (-not $Text) { return "" }
    $clean = ($Text -replace "\s+", " ").Trim()
    if ($clean.Length -le $MaxLength) { return $clean }
    return $clean.Substring(0, $MaxLength - 3) + "..."
}

function Add-SetValue {
    param(
        [System.Collections.Generic.HashSet[string]]$Set,
        [string]$Value
    )
    if ($Value) { $Set.Add($Value) | Out-Null }
}

function Join-Set {
    param(
        [System.Collections.Generic.HashSet[string]]$Set,
        [int]$Limit = 30
    )
    if ($null -eq $Set) { return "" }
    return (@($Set | Sort-Object | Select-Object -First $Limit) -join "; ")
}

function New-ItemReadWriteBucket {
    return @{
        read_count = 0
        write_count = 0
        execute_count = 0
        unknown_count = 0
        exact_count = 0
        ambiguous_count = 0
        confirmed_count = 0
        likely_count = 0
        needs_lineage_confirmation = 0
        needs_object_type_confirmation = 0
        needs_orchestration_review = 0
        blocked_missing_operation = 0
        other_blocked = 0
        read_objects = [System.Collections.Generic.HashSet[string]]::new()
        write_objects = [System.Collections.Generic.HashSet[string]]::new()
        execute_objects = [System.Collections.Generic.HashSet[string]]::new()
        all_objects = [System.Collections.Generic.HashSet[string]]::new()
        statuses = [System.Collections.Generic.HashSet[string]]::new()
        object_names = [System.Collections.Generic.HashSet[string]]::new()
    }
}

function Get-OrCreateBucket {
    param([hashtable]$Index, [string]$Key)
    $normalized = Normalize-Key $Key
    if (-not $normalized) { return $null }
    if (-not $Index.ContainsKey($normalized)) {
        $Index[$normalized] = New-ItemReadWriteBucket
    }
    return $Index[$normalized]
}

function New-ObjectUsageBucket {
    return @{
        readers = [System.Collections.Generic.HashSet[string]]::new()
        writers = [System.Collections.Generic.HashSet[string]]::new()
        executors = [System.Collections.Generic.HashSet[string]]::new()
        statuses = [System.Collections.Generic.HashSet[string]]::new()
        item_types = [System.Collections.Generic.HashSet[string]]::new()
        display_names = [System.Collections.Generic.HashSet[string]]::new()
        object_types = [System.Collections.Generic.HashSet[string]]::new()
        source_types = [System.Collections.Generic.HashSet[string]]::new()
        exact_count = 0
        ambiguous_count = 0
        row_count = 0
    }
}

function Get-OrCreateObjectBucket {
    param([hashtable]$Index, [string]$Key)
    $normalized = Normalize-Key $Key
    if (-not $normalized) { return $null }
    if (-not $Index.ContainsKey($normalized)) {
        $Index[$normalized] = New-ObjectUsageBucket
    }
    return $Index[$normalized]
}

function Get-ItemV2Status {
    param([object]$PlanRow, [hashtable]$Bucket)

    $riskFlags = Get-FieldValue -Object $PlanRow -Names @("risk_flags")
    $parallelReadiness = Get-FieldValue -Object $PlanRow -Names @("parallel_readiness")
    $humanValidation = Get-FieldValue -Object $PlanRow -Names @("human_validation_required")
    $incomingLikely = Convert-ToInt (Get-FieldValue -Object $PlanRow -Names @("incoming_likely_edges"))
    $outgoingLikely = Convert-ToInt (Get-FieldValue -Object $PlanRow -Names @("outgoing_likely_edges"))

    if ($parallelReadiness -eq "hold_until_stabilized" -or $riskFlags -like "*failure_hotspot_stabilize_first*") {
        return "hold_failure_stabilization"
    }
    if ($null -ne $Bucket) {
        if ($Bucket.blocked_missing_operation -gt 0 -or $Bucket.unknown_count -gt 0) { return "blocked_missing_operation" }
        if ($Bucket.needs_lineage_confirmation -gt 0) { return "blocked_lineage_confirmation" }
        if ($Bucket.needs_object_type_confirmation -gt 0) { return "blocked_object_type_confirmation" }
        if ($Bucket.write_count -gt 0) { return "blocked_write_serialization_review" }
        if ($Bucket.needs_orchestration_review -gt 0) { return "needs_orchestration_review" }
    }
    if ($incomingLikely -gt 0 -or $outgoingLikely -gt 0 -or $parallelReadiness -eq "candidate_requires_dependency_confirmation") {
        return "blocked_dependency_confirmation"
    }
    if ($humanValidation -eq "yes") {
        return "needs_orchestration_review"
    }
    return "candidate_ready_for_nonprod_review"
}

function Get-StatusScore {
    param([string]$Status)
    switch ($Status) {
        "candidate_ready_for_nonprod_review" { return 90 }
        "needs_orchestration_review" { return 60 }
        "blocked_write_serialization_review" { return 45 }
        "blocked_object_type_confirmation" { return 35 }
        "blocked_dependency_confirmation" { return 30 }
        "blocked_lineage_confirmation" { return 25 }
        "blocked_missing_operation" { return 10 }
        "hold_failure_stabilization" { return 0 }
        default { return 0 }
    }
}

function Get-StatusAction {
    param([string]$Status)
    switch ($Status) {
        "candidate_ready_for_nonprod_review" { return "Candidate for non-production orchestration review after owner approval." }
        "needs_orchestration_review" { return "Review schedules, duration evidence, ownership, and item-level behavior before promotion." }
        "blocked_write_serialization_review" { return "Validate writer order and downstream readers; serialize writes before any parallel execution." }
        "blocked_object_type_confirmation" { return "Confirm exact source object type before using this item as a scheduling dependency." }
        "blocked_dependency_confirmation" { return "Confirm dependency edges before using this row as an operational sequencing rule." }
        "blocked_lineage_confirmation" { return "Confirm object-level lineage from definitions, code, metadata, or owner evidence." }
        "blocked_missing_operation" { return "Classify unknown object operation as read, write, or execute." }
        "hold_failure_stabilization" { return "Stabilize failed or risky executions before optimization." }
        default { return "Review manually before operational use." }
    }
}

function Escape-MermaidLabel {
    param([string]$Text)
    if (-not $Text) { return "" }
    return (($Text -replace '"', "'") -replace "\|", "/")
}

foreach ($path in @($IdealPlanPath, $IdealEdgesPath, $ReadWritePath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$planRows = @(Import-Csv -Path $IdealPlanPath)
$idealEdges = @(Import-Csv -Path $IdealEdgesPath)
$readWriteRows = @(Import-Csv -Path $ReadWritePath)
$parallelRows = Import-OptionalCsv -Path $ParallelCandidatesPath

$rwByItem = @{}
$rwByObject = @{}

foreach ($row in $readWriteRows) {
    $itemQualifiedName = Get-FieldValue -Object $row -Names @("item_qualified_name")
    $itemKey = Normalize-Key $itemQualifiedName
    $objectKey = Get-FieldValue -Object $row -Names @("object_key")
    $operation = Get-FieldValue -Object $row -Names @("operation_type")
    $status = Get-FieldValue -Object $row -Names @("scheduling_readiness")
    $objectTypeStatus = Get-FieldValue -Object $row -Names @("object_type_status")
    $confidence = Get-FieldValue -Object $row -Names @("lineage_confidence")
    $objectName = Get-FieldValue -Object $row -Names @("object_display_name")

    $itemBucket = Get-OrCreateBucket -Index $rwByItem -Key $itemQualifiedName
    if ($null -ne $itemBucket) {
        switch ($operation) {
            "read" { $itemBucket.read_count += 1; Add-SetValue -Set $itemBucket.read_objects -Value $objectKey }
            "write" { $itemBucket.write_count += 1; Add-SetValue -Set $itemBucket.write_objects -Value $objectKey }
            "execute" { $itemBucket.execute_count += 1; Add-SetValue -Set $itemBucket.execute_objects -Value $objectKey }
            default { $itemBucket.unknown_count += 1 }
        }
        if ($objectTypeStatus -eq "exact") { $itemBucket.exact_count += 1 } else { $itemBucket.ambiguous_count += 1 }
        if ($confidence -eq "confirmed") { $itemBucket.confirmed_count += 1 } else { $itemBucket.likely_count += 1 }
        switch ($status) {
            "needs_lineage_confirmation" { $itemBucket.needs_lineage_confirmation += 1 }
            "needs_object_type_confirmation" { $itemBucket.needs_object_type_confirmation += 1 }
            "needs_orchestration_review" { $itemBucket.needs_orchestration_review += 1 }
            "blocked_missing_operation" { $itemBucket.blocked_missing_operation += 1 }
            default {
                if ($status -like "blocked*") { $itemBucket.other_blocked += 1 }
            }
        }
        Add-SetValue -Set $itemBucket.statuses -Value $status
        Add-SetValue -Set $itemBucket.all_objects -Value $objectKey
        Add-SetValue -Set $itemBucket.object_names -Value $objectName
    }

    $objectBucket = Get-OrCreateObjectBucket -Index $rwByObject -Key $objectKey
    if ($null -ne $objectBucket) {
        $objectBucket.row_count += 1
        switch ($operation) {
            "read" { Add-SetValue -Set $objectBucket.readers -Value $itemQualifiedName }
            "write" { Add-SetValue -Set $objectBucket.writers -Value $itemQualifiedName }
            "execute" { Add-SetValue -Set $objectBucket.executors -Value $itemQualifiedName }
        }
        if ($objectTypeStatus -eq "exact") { $objectBucket.exact_count += 1 } else { $objectBucket.ambiguous_count += 1 }
        Add-SetValue -Set $objectBucket.statuses -Value $status
        Add-SetValue -Set $objectBucket.item_types -Value (Get-FieldValue -Object $row -Names @("item_type"))
        Add-SetValue -Set $objectBucket.display_names -Value $objectName
        Add-SetValue -Set $objectBucket.object_types -Value (Get-FieldValue -Object $row -Names @("object_type"))
        Add-SetValue -Set $objectBucket.source_types -Value (Get-FieldValue -Object $row -Names @("source_type"))
    }
}

$planOut = [System.Collections.Generic.List[object]]::new()
foreach ($row in $planRows) {
    $qualifiedName = Get-FieldValue -Object $row -Names @("qualified_name")
    $itemKey = Normalize-Key $qualifiedName
    $bucket = if ($itemKey -and $rwByItem.ContainsKey($itemKey)) { $rwByItem[$itemKey] } else { $null }
    $status = Get-ItemV2Status -PlanRow $row -Bucket $bucket
    $score = Get-StatusScore -Status $status

    $planOut.Add([pscustomobject]@{
        v2_wave_index = Get-FieldValue -Object $row -Names @("wave_index")
        v2_status = $status
        readiness_score = $score
        proposed_stage = Get-FieldValue -Object $row -Names @("proposed_stage")
        qualified_name = $qualifiedName
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        item_type = Get-FieldValue -Object $row -Names @("item_type")
        orchestration_role = Get-FieldValue -Object $row -Names @("orchestration_role")
        action_type = Get-FieldValue -Object $row -Names @("action_type")
        is_master_action = Get-FieldValue -Object $row -Names @("is_master_action")
        estimated_start_seconds = Get-FieldValue -Object $row -Names @("estimated_start_seconds")
        estimated_duration_seconds = Get-FieldValue -Object $row -Names @("estimated_duration_seconds")
        estimated_finish_seconds = Get-FieldValue -Object $row -Names @("estimated_finish_seconds")
        duration_source = Get-FieldValue -Object $row -Names @("duration_source")
        predecessor_count = Get-FieldValue -Object $row -Names @("predecessor_count")
        successor_count = Get-FieldValue -Object $row -Names @("successor_count")
        incoming_likely_edges = Get-FieldValue -Object $row -Names @("incoming_likely_edges")
        outgoing_likely_edges = Get-FieldValue -Object $row -Names @("outgoing_likely_edges")
        run_count = Get-FieldValue -Object $row -Names @("run_count")
        failed_count = Get-FieldValue -Object $row -Names @("failed_count")
        manual_count = Get-FieldValue -Object $row -Names @("manual_count")
        scheduled_count = Get-FieldValue -Object $row -Names @("scheduled_count")
        enabled_schedules = Get-FieldValue -Object $row -Names @("enabled_schedules")
        disabled_schedules = Get-FieldValue -Object $row -Names @("disabled_schedules")
        schedule_times = Get-FieldValue -Object $row -Names @("schedule_times")
        original_parallel_readiness = Get-FieldValue -Object $row -Names @("parallel_readiness")
        original_risk_flags = Get-FieldValue -Object $row -Names @("risk_flags")
        original_human_validation_required = Get-FieldValue -Object $row -Names @("human_validation_required")
        read_count = if ($bucket) { $bucket.read_count } else { 0 }
        write_count = if ($bucket) { $bucket.write_count } else { 0 }
        execute_count = if ($bucket) { $bucket.execute_count } else { 0 }
        unknown_operation_count = if ($bucket) { $bucket.unknown_count } else { 0 }
        exact_object_count = if ($bucket) { $bucket.exact_count } else { 0 }
        ambiguous_object_count = if ($bucket) { $bucket.ambiguous_count } else { 0 }
        confirmed_object_rows = if ($bucket) { $bucket.confirmed_count } else { 0 }
        likely_object_rows = if ($bucket) { $bucket.likely_count } else { 0 }
        needs_lineage_confirmation_count = if ($bucket) { $bucket.needs_lineage_confirmation } else { 0 }
        needs_object_type_confirmation_count = if ($bucket) { $bucket.needs_object_type_confirmation } else { 0 }
        needs_orchestration_review_count = if ($bucket) { $bucket.needs_orchestration_review } else { 0 }
        blocked_missing_operation_count = if ($bucket) { $bucket.blocked_missing_operation } else { 0 }
        object_statuses = if ($bucket) { Join-Set -Set $bucket.statuses -Limit 12 } else { "" }
        sample_objects = if ($bucket) { Join-Set -Set $bucket.object_names -Limit 8 } else { "" }
        v2_recommended_next_action = Get-StatusAction -Status $status
    }) | Out-Null
}

$objectConflicts = [System.Collections.Generic.List[object]]::new()
$objectConstraintEdges = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $rwByObject.GetEnumerator()) {
    $objectKey = $entry.Key
    $bucket = $entry.Value
    $readerCount = $bucket.readers.Count
    $writerCount = $bucket.writers.Count
    $executorCount = $bucket.executors.Count
    if ($writerCount -eq 0 -and $executorCount -eq 0) { continue }

    $conflictTypes = [System.Collections.Generic.HashSet[string]]::new()
    if ($writerCount -gt 1) { Add-SetValue -Set $conflictTypes -Value "multiple_writers" }
    if ($writerCount -gt 0 -and $readerCount -gt 0) { Add-SetValue -Set $conflictTypes -Value "writer_reader_ordering" }
    if ($executorCount -gt 0) { Add-SetValue -Set $conflictTypes -Value "execute_dependency_review" }
    if ($bucket.statuses.Count -gt 0) { Add-SetValue -Set $conflictTypes -Value "evidence_gated" }

    $objectStatus = if ($bucket.ambiguous_count -gt 0) { "blocked_until_lineage_and_type_confirmed" } else { "requires_serialization_review" }
    $objectConflicts.Add([pscustomobject]@{
        object_key = $objectKey
        object_display_name = Join-Set -Set $bucket.display_names -Limit 3
        source_types = Join-Set -Set $bucket.source_types -Limit 8
        object_types = Join-Set -Set $bucket.object_types -Limit 8
        reader_count = $readerCount
        writer_count = $writerCount
        executor_count = $executorCount
        exact_row_count = $bucket.exact_count
        ambiguous_row_count = $bucket.ambiguous_count
        conflict_types = Join-Set -Set $conflictTypes -Limit 10
        object_readiness = $objectStatus
        statuses = Join-Set -Set $bucket.statuses -Limit 12
        sample_readers = Join-Set -Set $bucket.readers -Limit 8
        sample_writers = Join-Set -Set $bucket.writers -Limit 8
        sample_executors = Join-Set -Set $bucket.executors -Limit 8
        recommended_next_action = "Confirm object lineage/type, then serialize writers before readers and validate any shared-object parallelism."
    }) | Out-Null

    $pairCount = 0
    $writers = @($bucket.writers | Sort-Object)
    $readers = @($bucket.readers | Sort-Object)
    for ($i = 0; $i -lt $writers.Count; $i++) {
        for ($j = $i + 1; $j -lt $writers.Count; $j++) {
            if ($pairCount -ge $MaxObjectConstraintPairsPerObject) { break }
            $objectConstraintEdges.Add([pscustomobject]@{
                upstream_qualified_name = $writers[$i]
                downstream_qualified_name = $writers[$j]
                v2_relationship_type = "object_write_serialization_guard"
                object_key = $objectKey
                edge_status = "blocked_pending_write_order_review"
                evidence = "Both items write to the same source object. Serialization order must be confirmed before parallel execution."
            }) | Out-Null
            $pairCount++
        }
    }
    foreach ($writer in $writers) {
        foreach ($reader in $readers) {
            if ($pairCount -ge $MaxObjectConstraintPairsPerObject) { break }
            if ($writer -eq $reader) { continue }
            $objectConstraintEdges.Add([pscustomobject]@{
                upstream_qualified_name = $writer
                downstream_qualified_name = $reader
                v2_relationship_type = "object_writer_before_reader_guard"
                object_key = $objectKey
                edge_status = "blocked_pending_lineage_confirmation"
                evidence = "One item writes and another reads the same source object. Writer-reader order must be confirmed before scheduling."
            }) | Out-Null
            $pairCount++
        }
    }
}

$edgeOut = [System.Collections.Generic.List[object]]::new()
foreach ($edge in $idealEdges) {
    $confidence = Get-FieldValue -Object $edge -Names @("confidence")
    $status = if ($confidence -eq "confirmed") { "active_confirmed_dependency" } else { "pending_dependency_confirmation" }
    $edgeOut.Add([pscustomobject]@{
        upstream_qualified_name = Get-FieldValue -Object $edge -Names @("upstream_qualified_name")
        downstream_qualified_name = Get-FieldValue -Object $edge -Names @("downstream_qualified_name")
        v2_relationship_type = Get-FieldValue -Object $edge -Names @("plan_relationship_type")
        source_relationship_type = Get-FieldValue -Object $edge -Names @("original_relationship_type")
        object_key = ""
        edge_status = $status
        confidence = $confidence
        source_system = Get-FieldValue -Object $edge -Names @("source_system")
        evidence = Get-FieldValue -Object $edge -Names @("evidence")
    }) | Out-Null
}

foreach ($edge in $objectConstraintEdges) {
    $edgeOut.Add([pscustomobject]@{
        upstream_qualified_name = $edge.upstream_qualified_name
        downstream_qualified_name = $edge.downstream_qualified_name
        v2_relationship_type = $edge.v2_relationship_type
        source_relationship_type = "object_read_write"
        object_key = $edge.object_key
        edge_status = $edge.edge_status
        confidence = "needs_confirmation"
        source_system = "analysis/object_read_write_classification.csv"
        evidence = $edge.evidence
    }) | Out-Null
}

$edgeSet = [System.Collections.Generic.HashSet[string]]::new()
foreach ($edge in $idealEdges) {
    $from = Normalize-Key (Get-FieldValue -Object $edge -Names @("upstream_qualified_name"))
    $to = Normalize-Key (Get-FieldValue -Object $edge -Names @("downstream_qualified_name"))
    if ($from -and $to) { $edgeSet.Add("$from|$to") | Out-Null }
}

$parallelOut = [System.Collections.Generic.List[object]]::new()
foreach ($row in $parallelRows) {
    $a = Get-FieldValue -Object $row -Names @("candidate_a")
    $b = Get-FieldValue -Object $row -Names @("candidate_b")
    $aKey = Normalize-Key $a
    $bKey = Normalize-Key $b
    $aBucket = if ($rwByItem.ContainsKey($aKey)) { $rwByItem[$aKey] } else { $null }
    $bBucket = if ($rwByItem.ContainsKey($bKey)) { $rwByItem[$bKey] } else { $null }
    $directDependency = $edgeSet.Contains("$aKey|$bKey") -or $edgeSet.Contains("$bKey|$aKey")
    $sharedObjects = [System.Collections.Generic.HashSet[string]]::new()
    $sharedWrites = [System.Collections.Generic.HashSet[string]]::new()

    if ($aBucket -and $bBucket) {
        foreach ($objectKey in $aBucket.all_objects) {
            if ($bBucket.all_objects.Contains($objectKey)) { Add-SetValue -Set $sharedObjects -Value $objectKey }
        }
        foreach ($objectKey in $aBucket.write_objects) {
            if ($bBucket.all_objects.Contains($objectKey)) { Add-SetValue -Set $sharedWrites -Value $objectKey }
        }
        foreach ($objectKey in $bBucket.write_objects) {
            if ($aBucket.all_objects.Contains($objectKey)) { Add-SetValue -Set $sharedWrites -Value $objectKey }
        }
    }

    $aBlocked = $false
    $bBlocked = $false
    foreach ($bucket in @($aBucket, $bBucket)) {
        if ($null -eq $bucket) { continue }
        if ($bucket.needs_lineage_confirmation -gt 0 -or $bucket.needs_object_type_confirmation -gt 0 -or $bucket.blocked_missing_operation -gt 0 -or $bucket.write_count -gt 0) {
            if ($bucket -eq $aBucket) { $aBlocked = $true } else { $bBlocked = $true }
        }
    }

    $status = "parallel_candidate_no_shared_objects"
    if ($directDependency) { $status = "blocked_direct_dependency" }
    elseif ($null -eq $aBucket -or $null -eq $bBucket) { $status = "blocked_missing_object_evidence" }
    elseif ($aBlocked -or $bBlocked) { $status = "blocked_read_write_evidence" }
    elseif ($sharedWrites.Count -gt 0) { $status = "blocked_shared_object_write" }
    elseif ($sharedObjects.Count -gt 0) { $status = "candidate_shared_reads_only" }

    $parallelOut.Add([pscustomobject]@{
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        candidate_a = $a
        candidate_b = $b
        item_type_a = Get-FieldValue -Object $row -Names @("item_type_a")
        item_type_b = Get-FieldValue -Object $row -Names @("item_type_b")
        expected_parallel_window_seconds = Get-FieldValue -Object $row -Names @("expected_parallel_window_seconds")
        direct_dependency_exists = if ($directDependency) { "yes" } else { "no" }
        shared_object_count = $sharedObjects.Count
        shared_write_object_count = $sharedWrites.Count
        candidate_status = $status
        candidate_a_read_count = if ($aBucket) { $aBucket.read_count } else { 0 }
        candidate_a_write_count = if ($aBucket) { $aBucket.write_count } else { 0 }
        candidate_a_blocker_count = if ($aBucket) { $aBucket.needs_lineage_confirmation + $aBucket.needs_object_type_confirmation + $aBucket.blocked_missing_operation } else { 0 }
        candidate_b_read_count = if ($bBucket) { $bBucket.read_count } else { 0 }
        candidate_b_write_count = if ($bBucket) { $bBucket.write_count } else { 0 }
        candidate_b_blocker_count = if ($bBucket) { $bBucket.needs_lineage_confirmation + $bBucket.needs_object_type_confirmation + $bBucket.blocked_missing_operation } else { 0 }
        sample_shared_objects = Join-Set -Set $sharedObjects -Limit 10
        recommendation = "Candidate only. Promote to non-production test only if direct dependencies, shared writes, and evidence blockers are resolved."
    }) | Out-Null
}

$waveOut = [System.Collections.Generic.List[object]]::new()
foreach ($group in ($planOut | Group-Object v2_wave_index | Sort-Object { Convert-ToInt $_.Name })) {
    $nodes = @($group.Group)
    $durationMax = 0.0
    foreach ($node in $nodes) {
        $duration = Convert-ToDouble $node.estimated_duration_seconds
        if ($duration -gt $durationMax) { $durationMax = $duration }
    }
    $statusBreakdown = ($nodes | Group-Object v2_status | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join "; "
    $stageBreakdown = ($nodes | Group-Object proposed_stage | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join "; "
    $candidateCount = @($nodes | Where-Object { $_.v2_status -eq "candidate_ready_for_nonprod_review" }).Count
    $blockedCount = @($nodes | Where-Object { $_.v2_status -like "blocked*" -or $_.v2_status -like "hold*" }).Count
    $reviewCount = @($nodes | Where-Object { $_.v2_status -eq "needs_orchestration_review" }).Count
    $waveOut.Add([pscustomobject]@{
        v2_wave_index = $group.Name
        node_count = $nodes.Count
        candidate_ready_count = $candidateCount
        blocked_count = $blockedCount
        review_count = $reviewCount
        estimated_parallel_duration_seconds = [math]::Round($durationMax, 3)
        status_breakdown = $statusBreakdown
        stage_breakdown = $stageBreakdown
        recommendation = "Use as a visual planning wave. Execute only candidate rows after human approval; blocked rows define prerequisite evidence work."
    }) | Out-Null
}

$planColumns = @(
    "v2_wave_index", "v2_status", "readiness_score", "proposed_stage", "qualified_name", "workspace_name", "item_name", "item_type",
    "orchestration_role", "action_type", "is_master_action", "estimated_start_seconds", "estimated_duration_seconds", "estimated_finish_seconds",
    "duration_source", "predecessor_count", "successor_count", "incoming_likely_edges", "outgoing_likely_edges", "run_count", "failed_count",
    "manual_count", "scheduled_count", "enabled_schedules", "disabled_schedules", "schedule_times", "original_parallel_readiness",
    "original_risk_flags", "original_human_validation_required", "read_count", "write_count", "execute_count", "unknown_operation_count",
    "exact_object_count", "ambiguous_object_count", "confirmed_object_rows", "likely_object_rows", "needs_lineage_confirmation_count",
    "needs_object_type_confirmation_count", "needs_orchestration_review_count", "blocked_missing_operation_count", "object_statuses",
    "sample_objects", "v2_recommended_next_action"
)

$edgeColumns = @("upstream_qualified_name", "downstream_qualified_name", "v2_relationship_type", "source_relationship_type", "object_key", "edge_status", "confidence", "source_system", "evidence")
$waveColumns = @("v2_wave_index", "node_count", "candidate_ready_count", "blocked_count", "review_count", "estimated_parallel_duration_seconds", "status_breakdown", "stage_breakdown", "recommendation")
$conflictColumns = @("object_key", "object_display_name", "source_types", "object_types", "reader_count", "writer_count", "executor_count", "exact_row_count", "ambiguous_row_count", "conflict_types", "object_readiness", "statuses", "sample_readers", "sample_writers", "sample_executors", "recommended_next_action")
$parallelColumns = @("workspace_name", "candidate_a", "candidate_b", "item_type_a", "item_type_b", "expected_parallel_window_seconds", "direct_dependency_exists", "shared_object_count", "shared_write_object_count", "candidate_status", "candidate_a_read_count", "candidate_a_write_count", "candidate_a_blocker_count", "candidate_b_read_count", "candidate_b_write_count", "candidate_b_blocker_count", "sample_shared_objects", "recommendation")

Export-Rows -Rows @($planOut) -Columns $planColumns -Path $OutputPlanPath
Export-Rows -Rows @($edgeOut) -Columns $edgeColumns -Path $OutputEdgesPath
Export-Rows -Rows @($waveOut) -Columns $waveColumns -Path $OutputWavesPath
Export-Rows -Rows @($objectConflicts | Sort-Object writer_count, reader_count -Descending) -Columns $conflictColumns -Path $OutputObjectConflictsPath
Export-Rows -Rows @($parallelOut) -Columns $parallelColumns -Path $OutputParallelPath

$summaryRows = [System.Collections.Generic.List[object]]::new()
function Add-SummaryRow {
    param([string]$Metric, [object]$Value, [string]$Notes)
    $summaryRows.Add([pscustomobject]@{ metric = $Metric; value = [string]$Value; notes = $Notes }) | Out-Null
}

Add-SummaryRow -Metric "plan_nodes" -Value $planOut.Count -Notes "Rows in orchestration_v2_plan.csv."
Add-SummaryRow -Metric "candidate_ready_for_nonprod_review" -Value (@($planOut | Where-Object { $_.v2_status -eq "candidate_ready_for_nonprod_review" }).Count) -Notes "Rows with no local blocker; still require human approval."
Add-SummaryRow -Metric "blocked_or_hold_nodes" -Value (@($planOut | Where-Object { $_.v2_status -like "blocked*" -or $_.v2_status -like "hold*" }).Count) -Notes "Rows that must not be operationalized before resolving blockers."
Add-SummaryRow -Metric "needs_orchestration_review_nodes" -Value (@($planOut | Where-Object { $_.v2_status -eq "needs_orchestration_review" }).Count) -Notes "Rows requiring scheduling/ownership/duration review."
Add-SummaryRow -Metric "object_conflict_rows" -Value $objectConflicts.Count -Notes "Source objects with writers, executes, or writer-reader ordering needs."
Add-SummaryRow -Metric "object_constraint_edges" -Value $objectConstraintEdges.Count -Notes "Read/write guard edges added as blocked constraints."
Add-SummaryRow -Metric "parallel_candidate_rows" -Value $parallelOut.Count -Notes "Phase 7 parallel candidates re-evaluated with object read/write evidence."
Add-SummaryRow -Metric "parallel_candidates_ready" -Value (@($parallelOut | Where-Object { $_.candidate_status -like "candidate*" }).Count) -Notes "Candidates that still require non-production approval."
Add-SummaryRow -Metric "parallel_candidates_blocked" -Value (@($parallelOut | Where-Object { $_.candidate_status -like "blocked*" }).Count) -Notes "Candidates blocked by dependency, evidence, or write conflict."
Add-SummaryRow -Metric "waves" -Value $waveOut.Count -Notes "Planning waves inherited from ideal execution v1 and annotated by v2 status."

Export-Rows -Rows @($summaryRows) -Columns @("metric", "value", "notes") -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $MermaidPath
$mermaid = [System.Collections.Generic.List[string]]::new()
$mermaid.Add("flowchart LR") | Out-Null
$limitedWaves = @($waveOut | Sort-Object { Convert-ToInt $_.v2_wave_index } | Select-Object -First $DiagramWaveLimit)
for ($i = 0; $i -lt $limitedWaves.Count; $i++) {
    $wave = $limitedWaves[$i]
    $nodeId = "w$($wave.v2_wave_index)"
    $label = "Wave $($wave.v2_wave_index)`nNodes $($wave.node_count)`nReady $($wave.candidate_ready_count) / Review $($wave.review_count) / Blocked $($wave.blocked_count)"
    $labelEscaped = Escape-MermaidLabel $label
    $mermaid.Add(('  {0}["{1}"]' -f $nodeId, $labelEscaped)) | Out-Null
    if ($i -gt 0) {
        $prev = "w$($limitedWaves[$i - 1].v2_wave_index)"
        $mermaid.Add("  $prev --> $nodeId") | Out-Null
    }
}
$mermaid.Add("  classDef blocked fill:#fee2e2,stroke:#b91c1c,color:#111827;") | Out-Null
$mermaid.Add("  classDef review fill:#fef3c7,stroke:#b45309,color:#111827;") | Out-Null
$mermaid | Set-Content -Path $MermaidPath -Encoding UTF8

Ensure-ParentDirectory -Path $DocumentationPath
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# Orchestration Optimization v2") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated: $((Get-Date).ToString("s"))") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Phase C annotates the ideal execution plan with object-level read/write evidence, object conflict guards, and parallelism blockers. It is local-only and proposal-only.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- analysis/orchestration_v2_plan.csv") | Out-Null
$doc.Add("- analysis/orchestration_v2_edges.csv") | Out-Null
$doc.Add("- analysis/orchestration_v2_waves.csv") | Out-Null
$doc.Add("- analysis/orchestration_v2_object_conflicts.csv") | Out-Null
$doc.Add("- analysis/orchestration_v2_parallel_candidates.csv") | Out-Null
$doc.Add("- analysis/orchestration_v2_summary.csv") | Out-Null
$doc.Add("- diagrams/orchestration_v2_pipeline.mmd") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Summary") | Out-Null
$doc.Add("") | Out-Null
foreach ($row in $summaryRows) {
    $doc.Add("- $($row.metric): $($row.value)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Rules") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- Confirmed dependency edges stay active; likely dependency edges remain pending confirmation.") | Out-Null
$doc.Add("- Writer-reader and multi-writer object relationships are emitted as guard constraints, not approvals.") | Out-Null
$doc.Add("- Parallel candidates are blocked when object lineage/type is unresolved or when shared writes exist.") | Out-Null
$doc.Add("- Rows marked blocked or hold must not be included in an automatic production pipeline.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Next Human Review") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Review object conflicts first, then unblock read/write evidence for high-duration notebooks, CopyJobs, DataPipelines, and semantic model refreshes. Only after that should a non-production Fabric orchestration pipeline be designed.") | Out-Null
$doc | Set-Content -Path $DocumentationPath -Encoding UTF8

Write-Host "Orchestration optimization v2 completed."
Write-Host "Plan nodes: $($planOut.Count)"
Write-Host "Object conflict rows: $($objectConflicts.Count)"
Write-Host "Parallel candidates: $($parallelOut.Count)"
Write-Host "Output: $OutputPlanPath"
