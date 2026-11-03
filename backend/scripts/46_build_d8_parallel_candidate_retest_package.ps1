# Phase 46 - D8 package: the final cleanup-plan category -- re-tests
# parallelism candidates against everything closed out by D1/D3/D4/D5,
# since a candidate that looked safe to parallelize earlier may no longer
# be once its evidence gaps are filled. Packages a retest queue plus
# non-prod test candidates and a manual decision template.
# Writes: $OutputRetestQueuePath, $OutputItemEvidencePath,
# $OutputObjectEvidencePath, $OutputMissingObjectTargetsPath,
# $OutputReadWriteTargetsPath, $OutputNonprodCandidatesPath,
# $OutputDecisionTemplatePath, $OutputReadonlyPlanPath, $OutputSummaryPath,
# $OutputDocPath.
param(
    [string]$ParallelCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_parallel_candidates.csv"),
    [string]$CleanupQueuePath = (Join-Path $PSScriptRoot "../../analysis/likely_conflict_cleanup_queue.csv"),
    [string]$ObjectReadWritePath = (Join-Path $PSScriptRoot "../../analysis/object_read_write_classification.csv"),
    [string]$D1ClosurePath = (Join-Path $PSScriptRoot "../../analysis/d1_closure_control_queue.csv"),
    [string]$D3ItemClosurePath = (Join-Path $PSScriptRoot "../../analysis/d3_item_closure_control_queue.csv"),
    [string]$D4SourceQueuePath = (Join-Path $PSScriptRoot "../../analysis/d4_exact_object_type_source_queue.csv"),
    [string]$D5ClosurePath = (Join-Path $PSScriptRoot "../../analysis/d5_closure_control_queue.csv"),
    [string]$D5ParticipantPath = (Join-Path $PSScriptRoot "../../analysis/d5_conflict_participant_review.csv"),
    [string]$OutputRetestQueuePath = (Join-Path $PSScriptRoot "../../analysis/d8_parallel_candidate_retest_queue.csv"),
    [string]$OutputItemEvidencePath = (Join-Path $PSScriptRoot "../../analysis/d8_candidate_item_evidence.csv"),
    [string]$OutputObjectEvidencePath = (Join-Path $PSScriptRoot "../../analysis/d8_candidate_object_evidence.csv"),
    [string]$OutputMissingObjectTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d8_missing_object_evidence_targets.csv"),
    [string]$OutputReadWriteTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d8_read_write_validation_targets.csv"),
    [string]$OutputNonprodCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/d8_nonprod_parallel_test_candidates.csv"),
    [string]$OutputDecisionTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d8_parallel_retest_decision_template.csv"),
    [string]$OutputReadonlyPlanPath = (Join-Path $PSScriptRoot "../../analysis/d8_external_readonly_action_plan.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d8_parallel_candidate_retest_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/42_d8_parallel_candidate_retest.md")
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

function Add-UniqueListValue {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )
    if ($Value -and -not $List.Contains($Value)) {
        $List.Add($Value) | Out-Null
    }
}

function Join-Unique {
    param([string[]]$Values, [int]$MaxValues = 40)
    return ((@(
        $Values |
            Where-Object { $_ } |
            Sort-Object -Unique |
            Select-Object -First $MaxValues
    )) -join "; ")
}

function Expand-JoinedValues {
    param([string[]]$Values)
    $expanded = [System.Collections.Generic.List[string]]::new()
    foreach ($value in $Values) {
        if (-not $value) { continue }
        foreach ($part in ([string]$value -split ";")) {
            $clean = $part.Trim()
            if ($clean) { $expanded.Add($clean) | Out-Null }
        }
    }
    return @($expanded)
}

function Get-PairKey {
    param([string]$CandidateA, [string]$CandidateB)
    $values = @((Normalize-Key -Value $CandidateA), (Normalize-Key -Value $CandidateB)) | Sort-Object
    return ($values -join " <-> ")
}

function Build-ObjectKey {
    param([object]$Row)
    $sourceType = Normalize-Key -Value (Get-FieldValue -Object $Row -Names @("source_type"))
    $sourceServer = Normalize-Key -Value (Get-FieldValue -Object $Row -Names @("source_server"))
    $sourceDatabase = Normalize-Key -Value (Get-FieldValue -Object $Row -Names @("source_database"))
    $schemaName = Normalize-Key -Value (Get-FieldValue -Object $Row -Names @("schema_name"))
    $objectName = Normalize-Key -Value (Get-FieldValue -Object $Row -Names @("object_name"))
    return "$sourceType|$sourceServer|$sourceDatabase|$schemaName|$objectName"
}

function Get-ClosureOpportunity {
    param([string]$CandidateStatus)
    switch ($CandidateStatus) {
        "blocked_missing_object_evidence" { return "blocked_pending_d1_object_evidence" }
        "blocked_read_write_evidence" { return "blocked_pending_d3_d4_d5_read_write_validation" }
        "blocked_direct_dependency" { return "blocked_direct_dependency" }
        "blocked_shared_object_write" { return "blocked_pending_d5_write_serialization" }
        "candidate_shared_reads_only" { return "nonprod_parallel_retest_candidate_shared_reads" }
        "parallel_candidate_no_shared_objects" { return "nonprod_parallel_retest_candidate_no_shared_objects" }
        default { return "manual_parallel_retest_review_required" }
    }
}

function Get-RetestStatus {
    param([string]$ClosureOpportunity)
    if ($ClosureOpportunity -like "blocked_*") { return "blocked" }
    if ($ClosureOpportunity -like "nonprod_parallel_retest_candidate*") { return "ready_for_owner_nonprod_retest_review" }
    return "manual_review_required"
}

function Get-RecommendedDecision {
    param([string]$ClosureOpportunity)
    switch ($ClosureOpportunity) {
        "blocked_pending_d1_object_evidence" { return "Keep blocked until both candidate items have object-level evidence or an explicit D1 accepted decision." }
        "blocked_pending_d3_d4_d5_read_write_validation" { return "Keep blocked until lineage confidence, exact object type, and write/serialization guard evidence are reviewed." }
        "blocked_direct_dependency" { return "Reject or keep serial unless the direct dependency is proven false and dependency evidence is updated." }
        "blocked_pending_d5_write_serialization" { return "Keep blocked until shared write objects have a reviewed D5 serialization decision." }
        "nonprod_parallel_retest_candidate_shared_reads" { return "Review owner and run a controlled non-production parallel test only if shared objects are read-only and all guards remain clean." }
        "nonprod_parallel_retest_candidate_no_shared_objects" { return "Review owner and run a controlled non-production parallel test only after confirming no hidden shared state." }
        default { return "Review the pair manually before selecting a D8 decision." }
    }
}

function Get-ReadonlyAction {
    param([string]$ClosureOpportunity)
    switch ($ClosureOpportunity) {
        "blocked_pending_d1_object_evidence" { return "Review linked D1 item targets and capture object-level lineage for both candidate items before retesting parallelism." }
        "blocked_pending_d3_d4_d5_read_write_validation" { return "Review D3 lineage, D4 exact object type, D5 conflict/guard evidence, and item code definitions before approving any parallel test." }
        "blocked_direct_dependency" { return "Review dependency evidence in read-only mode and keep the pair serial unless the dependency is rejected with evidence." }
        "blocked_pending_d5_write_serialization" { return "Review shared write objects and D5 serialization decisions before any parallel retest." }
        "nonprod_parallel_retest_candidate_shared_reads" { return "Prepare an owner-approved non-production test with run isolation, timing capture, and rollback/abort criteria." }
        "nonprod_parallel_retest_candidate_no_shared_objects" { return "Prepare an owner-approved non-production test and verify there is no unindexed shared state." }
        default { return "Review local evidence and owner evidence before selecting a D8 decision." }
    }
}

if (-not (Test-Path $ParallelCandidatesPath)) {
    throw "Required input not found: $ParallelCandidatesPath"
}

$parallelRows = @(Import-Csv -Path $ParallelCandidatesPath)
$cleanupRows = Import-OptionalCsv -Path $CleanupQueuePath
$rwRows = Import-OptionalCsv -Path $ObjectReadWritePath
$d1Rows = Import-OptionalCsv -Path $D1ClosurePath
$d3ItemRows = Import-OptionalCsv -Path $D3ItemClosurePath
$d4Rows = Import-OptionalCsv -Path $D4SourceQueuePath
$d5Rows = Import-OptionalCsv -Path $D5ClosurePath
$d5ParticipantRows = Import-OptionalCsv -Path $D5ParticipantPath

$cleanupByPair = @{}
foreach ($row in ($cleanupRows | Where-Object { $_.phase_id -eq "D8" })) {
    $pairText = Get-FieldValue -Object $row -Names @("item_qualified_name")
    $parts = $pairText -split " <-> ", 2
    if ($parts.Count -eq 2) {
        $pairKey = Get-PairKey -CandidateA $parts[0] -CandidateB $parts[1]
        if ($pairKey -and -not $cleanupByPair.ContainsKey($pairKey)) { $cleanupByPair[$pairKey] = $row }
    }
}

$rwByItem = @{}
foreach ($row in $rwRows) {
    Add-ListMapValue -Map $rwByItem -Key (Normalize-Key -Value (Get-FieldValue -Object $row -Names @("item_qualified_name"))) -Value $row
}

$d1ByItem = @{}
foreach ($row in $d1Rows) {
    Add-ListMapValue -Map $d1ByItem -Key (Normalize-Key -Value (Get-FieldValue -Object $row -Names @("item_qualified_name"))) -Value $row
}

$d3ByItem = @{}
foreach ($row in $d3ItemRows) {
    Add-ListMapValue -Map $d3ByItem -Key (Normalize-Key -Value (Get-FieldValue -Object $row -Names @("item_qualified_name"))) -Value $row
}

$d4ByObjectKey = @{}
foreach ($row in $d4Rows) {
    Add-ListMapValue -Map $d4ByObjectKey -Key (Build-ObjectKey -Row $row) -Value $row
}

$d5ByObjectKey = @{}
foreach ($row in $d5Rows) {
    Add-ListMapValue -Map $d5ByObjectKey -Key (Normalize-Key -Value (Get-FieldValue -Object $row -Names @("object_key"))) -Value $row
}

$d5ParticipantsByItem = @{}
foreach ($row in $d5ParticipantRows) {
    Add-ListMapValue -Map $d5ParticipantsByItem -Key (Normalize-Key -Value (Get-FieldValue -Object $row -Names @("item_qualified_name"))) -Value $row
}

function Get-ItemStats {
    param(
        [string]$ItemQualifiedName,
        [hashtable]$RwByItem,
        [hashtable]$D1ByItem,
        [hashtable]$D3ByItem,
        [hashtable]$D4ByObjectKey,
        [hashtable]$D5ByObjectKey,
        [hashtable]$D5ParticipantsByItem
    )

    $itemKey = Normalize-Key -Value $ItemQualifiedName
    $objects = if ($RwByItem.ContainsKey($itemKey)) { @($RwByItem[$itemKey]) } else { @() }
    $d1Targets = if ($D1ByItem.ContainsKey($itemKey)) { @($D1ByItem[$itemKey]) } else { @() }
    $d3Targets = if ($D3ByItem.ContainsKey($itemKey)) { @($D3ByItem[$itemKey]) } else { @() }
    $d5ItemParticipants = if ($D5ParticipantsByItem.ContainsKey($itemKey)) { @($D5ParticipantsByItem[$itemKey]) } else { @() }
    $d4Ids = [System.Collections.Generic.List[string]]::new()
    $d5ConflictIds = [System.Collections.Generic.List[string]]::new()
    $objectKeys = [System.Collections.Generic.List[string]]::new()

    $readCount = 0
    $writeCount = 0
    $executeCount = 0
    $unknownCount = 0
    $lineageBlockerCount = 0
    $objectTypeBlockerCount = 0
    $missingOperationCount = 0

    foreach ($object in $objects) {
        $operation = Get-FieldValue -Object $object -Names @("operation_type")
        switch ($operation) {
            "read" { $readCount += 1 }
            "write" { $writeCount += 1 }
            "execute" { $executeCount += 1 }
            default { $unknownCount += 1 }
        }
        if ($operation -eq "unknown" -or -not $operation) { $missingOperationCount += 1 }
        $schedulingReadiness = Get-FieldValue -Object $object -Names @("scheduling_readiness")
        $hardeningStatus = Get-FieldValue -Object $object -Names @("hardening_status")
        $lineageConfidence = Get-FieldValue -Object $object -Names @("lineage_confidence")
        if ($schedulingReadiness -eq "needs_lineage_confirmation" -or $hardeningStatus -eq "pending_confirmation" -or $lineageConfidence -eq "likely") {
            $lineageBlockerCount += 1
        }
        $objectTypeStatus = Get-FieldValue -Object $object -Names @("object_type_status")
        if ($objectTypeStatus -eq "ambiguous" -or $objectTypeStatus -eq "unknown" -or $objectTypeStatus -eq "pending") {
            $objectTypeBlockerCount += 1
        }
        $objectKey = Get-FieldValue -Object $object -Names @("object_key")
        Add-UniqueListValue -List $objectKeys -Value $objectKey
        $normalizedObjectKey = Normalize-Key -Value $objectKey
        if ($D4ByObjectKey.ContainsKey($normalizedObjectKey)) {
            foreach ($d4 in @($D4ByObjectKey[$normalizedObjectKey])) {
                Add-UniqueListValue -List $d4Ids -Value (Get-FieldValue -Object $d4 -Names @("source_id"))
            }
        }
        if ($D5ByObjectKey.ContainsKey($normalizedObjectKey)) {
            foreach ($d5 in @($D5ByObjectKey[$normalizedObjectKey])) {
                Add-UniqueListValue -List $d5ConflictIds -Value (Get-FieldValue -Object $d5 -Names @("conflict_id"))
            }
        }
    }

    foreach ($participant in $d5ItemParticipants) {
        Add-UniqueListValue -List $d5ConflictIds -Value (Get-FieldValue -Object $participant -Names @("conflict_id"))
    }

    return [pscustomobject]@{
        item_qualified_name = $ItemQualifiedName
        object_rows = $objects
        object_row_count = @($objects).Count
        read_count = $readCount
        write_count = $writeCount
        execute_count = $executeCount
        unknown_operation_count = $unknownCount
        lineage_blocker_count = $lineageBlockerCount
        object_type_blocker_count = $objectTypeBlockerCount
        missing_operation_count = $missingOperationCount
        linked_d1_ids = Join-Unique -Values @($d1Targets | ForEach-Object { Get-FieldValue -Object $_ -Names @("d1_id") })
        linked_d3_item_review_ids = Join-Unique -Values @($d3Targets | ForEach-Object { Get-FieldValue -Object $_ -Names @("item_review_id") })
        linked_d4_source_ids = Join-Unique -Values @($d4Ids)
        linked_d5_conflict_ids = Join-Unique -Values @($d5ConflictIds)
        object_key_sample = Limit-Text -Text (Join-Unique -Values @($objectKeys) -MaxValues 8) -MaxLength 900
    }
}

$retestRows = [System.Collections.Generic.List[object]]::new()
$itemEvidenceRows = [System.Collections.Generic.List[object]]::new()
$objectEvidenceRows = [System.Collections.Generic.List[object]]::new()
$missingObjectRows = [System.Collections.Generic.List[object]]::new()
$readWriteRows = [System.Collections.Generic.List[object]]::new()
$nonprodRows = [System.Collections.Generic.List[object]]::new()
$decisionRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()

$sequence = 0
foreach ($row in ($parallelRows | Sort-Object @{ Expression = { Convert-ToInt (Get-FieldValue -Object $_ -Names @("shared_write_object_count")) }; Descending = $true }, @{ Expression = { Convert-ToDouble (Get-FieldValue -Object $_ -Names @("expected_parallel_window_seconds")) }; Descending = $true }, workspace_name)) {
    $sequence += 1
    $d8Id = "D8P{0:D5}" -f $sequence
    $candidateA = Get-FieldValue -Object $row -Names @("candidate_a")
    $candidateB = Get-FieldValue -Object $row -Names @("candidate_b")
    $pairKey = Get-PairKey -CandidateA $candidateA -CandidateB $candidateB
    $cleanup = if ($cleanupByPair.ContainsKey($pairKey)) { $cleanupByPair[$pairKey] } else { $null }
    $candidateStatus = Get-FieldValue -Object $row -Names @("candidate_status")
    $closureOpportunity = Get-ClosureOpportunity -CandidateStatus $candidateStatus
    $retestStatus = Get-RetestStatus -ClosureOpportunity $closureOpportunity
    $recommendedDecision = Get-RecommendedDecision -ClosureOpportunity $closureOpportunity
    $readonlyAction = Get-ReadonlyAction -ClosureOpportunity $closureOpportunity
    $aStats = Get-ItemStats -ItemQualifiedName $candidateA -RwByItem $rwByItem -D1ByItem $d1ByItem -D3ByItem $d3ByItem -D4ByObjectKey $d4ByObjectKey -D5ByObjectKey $d5ByObjectKey -D5ParticipantsByItem $d5ParticipantsByItem
    $bStats = Get-ItemStats -ItemQualifiedName $candidateB -RwByItem $rwByItem -D1ByItem $d1ByItem -D3ByItem $d3ByItem -D4ByObjectKey $d4ByObjectKey -D5ByObjectKey $d5ByObjectKey -D5ParticipantsByItem $d5ParticipantsByItem
    $linkedD1Ids = Join-Unique -Values (Expand-JoinedValues -Values @($aStats.linked_d1_ids, $bStats.linked_d1_ids))
    $linkedD3Ids = Join-Unique -Values (Expand-JoinedValues -Values @($aStats.linked_d3_item_review_ids, $bStats.linked_d3_item_review_ids))
    $linkedD4Ids = Join-Unique -Values (Expand-JoinedValues -Values @($aStats.linked_d4_source_ids, $bStats.linked_d4_source_ids))
    $linkedD5Ids = Join-Unique -Values (Expand-JoinedValues -Values @($aStats.linked_d5_conflict_ids, $bStats.linked_d5_conflict_ids))
    $priorityScore = Get-FieldValue -Object $cleanup -Names @("priority_score")
    if (-not $priorityScore) {
        $priorityScore = 50 + ((Convert-ToInt (Get-FieldValue -Object $row -Names @("shared_write_object_count"))) * 10) + ((Convert-ToInt (Get-FieldValue -Object $row -Names @("shared_object_count"))) * 2)
    }
    $priorityBand = if ((Convert-ToInt $priorityScore) -ge 85) { "critical" } elseif ((Convert-ToInt $priorityScore) -ge 75) { "high" } elseif ((Convert-ToInt $priorityScore) -ge 60) { "medium" } else { "low" }
    $blockingPhaseSummary = Join-Unique -Values @(
        $(if ($linkedD1Ids) { "D1 object evidence" }),
        $(if ($linkedD3Ids) { "D3 lineage confirmation" }),
        $(if ($linkedD4Ids) { "D4 exact object type" }),
        $(if ($linkedD5Ids) { "D5 write/conflict guard" })
    )
    if (-not $blockingPhaseSummary -and $retestStatus -eq "blocked") { $blockingPhaseSummary = "manual blocker review" }
    if (-not $blockingPhaseSummary) { $blockingPhaseSummary = "owner non-production approval" }

    $retestRow = [pscustomobject]@{
        d8_id = $d8Id
        priority_score = [string]$priorityScore
        priority_band = $priorityBand
        retest_status = $retestStatus
        closure_opportunity = $closureOpportunity
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        candidate_status = $candidateStatus
        candidate_a = $candidateA
        candidate_b = $candidateB
        item_type_a = Get-FieldValue -Object $row -Names @("item_type_a")
        item_type_b = Get-FieldValue -Object $row -Names @("item_type_b")
        expected_parallel_window_seconds = Get-FieldValue -Object $row -Names @("expected_parallel_window_seconds")
        direct_dependency_exists = Get-FieldValue -Object $row -Names @("direct_dependency_exists")
        shared_object_count = Get-FieldValue -Object $row -Names @("shared_object_count")
        shared_write_object_count = Get-FieldValue -Object $row -Names @("shared_write_object_count")
        candidate_a_object_rows = $aStats.object_row_count
        candidate_a_read_count = Get-FieldValue -Object $row -Names @("candidate_a_read_count")
        candidate_a_write_count = Get-FieldValue -Object $row -Names @("candidate_a_write_count")
        candidate_a_blocker_count = Get-FieldValue -Object $row -Names @("candidate_a_blocker_count")
        candidate_b_object_rows = $bStats.object_row_count
        candidate_b_read_count = Get-FieldValue -Object $row -Names @("candidate_b_read_count")
        candidate_b_write_count = Get-FieldValue -Object $row -Names @("candidate_b_write_count")
        candidate_b_blocker_count = Get-FieldValue -Object $row -Names @("candidate_b_blocker_count")
        sample_shared_objects = Get-FieldValue -Object $row -Names @("sample_shared_objects")
        linked_d1_ids = $linkedD1Ids
        linked_d3_item_review_ids = $linkedD3Ids
        linked_d4_source_ids = $linkedD4Ids
        linked_d5_conflict_ids = $linkedD5Ids
        blocking_phase_summary = $blockingPhaseSummary
        recommended_d8_decision = $recommendedDecision
        readonly_action = $readonlyAction
        decision_template_path = $OutputDecisionTemplatePath
    }
    $retestRows.Add($retestRow) | Out-Null

    if ($closureOpportunity -eq "blocked_pending_d1_object_evidence") { $missingObjectRows.Add($retestRow) | Out-Null }
    if ($closureOpportunity -eq "blocked_pending_d3_d4_d5_read_write_validation") { $readWriteRows.Add($retestRow) | Out-Null }
    if ($retestStatus -eq "ready_for_owner_nonprod_retest_review") { $nonprodRows.Add($retestRow) | Out-Null }

    foreach ($side in @("A", "B")) {
        $stats = if ($side -eq "A") { $aStats } else { $bStats }
        $itemType = if ($side -eq "A") { Get-FieldValue -Object $row -Names @("item_type_a") } else { Get-FieldValue -Object $row -Names @("item_type_b") }
        $itemEvidenceRows.Add([pscustomobject]@{
            d8_id = $d8Id
            side = $side
            item_qualified_name = $stats.item_qualified_name
            item_type = $itemType
            object_row_count = $stats.object_row_count
            read_count = $stats.read_count
            write_count = $stats.write_count
            execute_count = $stats.execute_count
            unknown_operation_count = $stats.unknown_operation_count
            lineage_blocker_count = $stats.lineage_blocker_count
            object_type_blocker_count = $stats.object_type_blocker_count
            missing_operation_count = $stats.missing_operation_count
            linked_d1_ids = $stats.linked_d1_ids
            linked_d3_item_review_ids = $stats.linked_d3_item_review_ids
            linked_d4_source_ids = $stats.linked_d4_source_ids
            linked_d5_conflict_ids = $stats.linked_d5_conflict_ids
            object_key_sample = $stats.object_key_sample
        }) | Out-Null

        foreach ($object in @($stats.object_rows)) {
            $objectKey = Get-FieldValue -Object $object -Names @("object_key")
            $normalizedObjectKey = Normalize-Key -Value $objectKey
            $d4Ids = @()
            if ($d4ByObjectKey.ContainsKey($normalizedObjectKey)) {
                $d4Ids = @($d4ByObjectKey[$normalizedObjectKey] | ForEach-Object { Get-FieldValue -Object $_ -Names @("source_id") })
            }
            $d5Ids = @()
            if ($d5ByObjectKey.ContainsKey($normalizedObjectKey)) {
                $d5Ids = @($d5ByObjectKey[$normalizedObjectKey] | ForEach-Object { Get-FieldValue -Object $_ -Names @("conflict_id") })
            }
            $objectEvidenceRows.Add([pscustomobject]@{
                d8_id = $d8Id
                side = $side
                item_qualified_name = $stats.item_qualified_name
                object_key = $objectKey
                object_display_name = Get-FieldValue -Object $object -Names @("object_display_name")
                operation_type = Get-FieldValue -Object $object -Names @("operation_type")
                usage_type = Get-FieldValue -Object $object -Names @("usage_type")
                source_type = Get-FieldValue -Object $object -Names @("source_type")
                object_type = Get-FieldValue -Object $object -Names @("object_type")
                object_type_status = Get-FieldValue -Object $object -Names @("object_type_status")
                lineage_confidence = Get-FieldValue -Object $object -Names @("lineage_confidence")
                hardening_status = Get-FieldValue -Object $object -Names @("hardening_status")
                hardening_issue_types = Get-FieldValue -Object $object -Names @("hardening_issue_types")
                orchestration_parallel_readiness = Get-FieldValue -Object $object -Names @("orchestration_parallel_readiness")
                scheduling_readiness = Get-FieldValue -Object $object -Names @("scheduling_readiness")
                linked_d4_source_ids = Join-Unique -Values $d4Ids
                linked_d5_conflict_ids = Join-Unique -Values $d5Ids
                evidence = Limit-Text -Text (Get-FieldValue -Object $object -Names @("evidence")) -MaxLength 900
            }) | Out-Null
        }
    }

    $allowedDecisions = "approve_nonprod_parallel_test; keep_serial; serialize_then_parallel; reject_parallel_candidate; blocked_pending_d1; blocked_pending_d3_d4; blocked_pending_d5; blocked_pending_owner; manual_review_required"
    $decisionRows.Add([pscustomobject]@{
        d8_id = $d8Id
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        candidate_a = $candidateA
        candidate_b = $candidateB
        candidate_status = $candidateStatus
        closure_opportunity = $closureOpportunity
        retest_status = $retestStatus
        proposed_d8_decision = ""
        allowed_decisions = $allowedDecisions
        proposed_nonprod_test_scope = ""
        proposed_parallel_guard = ""
        proposed_serialization_rule = ""
        proposed_abort_criteria = ""
        owner = ""
        confirmation_source = ""
        confirmation_evidence = ""
        reviewer = ""
        reviewed_at = ""
        next_action = $recommendedDecision
        notes = "Fill this row before treating D8 as closed. Do not run or schedule parallel execution from this package alone."
    }) | Out-Null

    $readonlyRows.Add([pscustomobject]@{
        d8_id = $d8Id
        priority_score = [string]$priorityScore
        priority_band = $priorityBand
        retest_status = $retestStatus
        closure_opportunity = $closureOpportunity
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        candidate_a = $candidateA
        candidate_b = $candidateB
        human_readonly_action = $readonlyAction
        linked_d1_ids = $linkedD1Ids
        linked_d3_item_review_ids = $linkedD3Ids
        linked_d4_source_ids = $linkedD4Ids
        linked_d5_conflict_ids = $linkedD5Ids
        decision_template_path = $OutputDecisionTemplatePath
        notes = "Read-only/manual D8 action. Last operational step remains human approval and execution outside this repo."
    }) | Out-Null
}

$summaryRows = [System.Collections.Generic.List[object]]::new()
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D8 retest rows"; row_count = @($retestRows).Count; notes = "One row per parallel candidate pair." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Candidate item evidence rows"; row_count = @($itemEvidenceRows).Count; notes = "Two item-side rows per D8 pair." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Candidate object evidence rows"; row_count = @($objectEvidenceRows).Count; notes = "Object-level evidence rows linked to D8 candidate items." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Missing object evidence targets"; row_count = @($missingObjectRows).Count; notes = "Pairs blocked by missing D1 object evidence." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Read/write validation targets"; row_count = @($readWriteRows).Count; notes = "Pairs blocked by D3/D4/D5 read/write validation." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Non-production parallel test candidates"; row_count = @($nonprodRows).Count; notes = "Pairs currently ready for owner-approved non-production retest." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D8 decision rows"; row_count = @($decisionRows).Count; notes = "One decision row per D8 pair." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "External read-only action rows"; row_count = @($readonlyRows).Count; notes = "One read-only/manual action per D8 pair." }) | Out-Null
foreach ($group in @($retestRows | Group-Object closure_opportunity | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "closure_opportunity"; group_key = $group.Name; row_count = $group.Count; notes = "D8 pairs grouped by closure path." }) | Out-Null
}
foreach ($group in @($retestRows | Group-Object candidate_status | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "candidate_status"; group_key = $group.Name; row_count = $group.Count; notes = "D8 pairs grouped by current v2 parallel status." }) | Out-Null
}
foreach ($group in @($retestRows | Group-Object workspace_name | Sort-Object @{ Expression = "Count"; Descending = $true }, Name | Select-Object -First 20)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "workspace"; group_key = $group.Name; row_count = $group.Count; notes = "Top workspaces by D8 candidate count." }) | Out-Null
}

$retestColumns = @(
    "d8_id", "priority_score", "priority_band", "retest_status", "closure_opportunity",
    "workspace_name", "candidate_status", "candidate_a", "candidate_b", "item_type_a",
    "item_type_b", "expected_parallel_window_seconds", "direct_dependency_exists",
    "shared_object_count", "shared_write_object_count", "candidate_a_object_rows",
    "candidate_a_read_count", "candidate_a_write_count", "candidate_a_blocker_count",
    "candidate_b_object_rows", "candidate_b_read_count", "candidate_b_write_count",
    "candidate_b_blocker_count", "sample_shared_objects", "linked_d1_ids",
    "linked_d3_item_review_ids", "linked_d4_source_ids", "linked_d5_conflict_ids",
    "blocking_phase_summary", "recommended_d8_decision", "readonly_action",
    "decision_template_path"
)
$itemColumns = @(
    "d8_id", "side", "item_qualified_name", "item_type", "object_row_count", "read_count",
    "write_count", "execute_count", "unknown_operation_count", "lineage_blocker_count",
    "object_type_blocker_count", "missing_operation_count", "linked_d1_ids",
    "linked_d3_item_review_ids", "linked_d4_source_ids", "linked_d5_conflict_ids",
    "object_key_sample"
)
$objectColumns = @(
    "d8_id", "side", "item_qualified_name", "object_key", "object_display_name",
    "operation_type", "usage_type", "source_type", "object_type", "object_type_status",
    "lineage_confidence", "hardening_status", "hardening_issue_types",
    "orchestration_parallel_readiness", "scheduling_readiness", "linked_d4_source_ids",
    "linked_d5_conflict_ids", "evidence"
)
$decisionColumns = @(
    "d8_id", "workspace_name", "candidate_a", "candidate_b", "candidate_status",
    "closure_opportunity", "retest_status", "proposed_d8_decision", "allowed_decisions",
    "proposed_nonprod_test_scope", "proposed_parallel_guard", "proposed_serialization_rule",
    "proposed_abort_criteria", "owner", "confirmation_source", "confirmation_evidence",
    "reviewer", "reviewed_at", "next_action", "notes"
)
$readonlyColumns = @(
    "d8_id", "priority_score", "priority_band", "retest_status", "closure_opportunity",
    "workspace_name", "candidate_a", "candidate_b", "human_readonly_action",
    "linked_d1_ids", "linked_d3_item_review_ids", "linked_d4_source_ids",
    "linked_d5_conflict_ids", "decision_template_path", "notes"
)
$summaryColumns = @("summary_scope", "group_key", "row_count", "notes")

Export-Rows -Rows @($retestRows) -Columns $retestColumns -Path $OutputRetestQueuePath
Export-Rows -Rows @($itemEvidenceRows) -Columns $itemColumns -Path $OutputItemEvidencePath
Export-Rows -Rows @($objectEvidenceRows) -Columns $objectColumns -Path $OutputObjectEvidencePath
Export-Rows -Rows @($missingObjectRows) -Columns $retestColumns -Path $OutputMissingObjectTargetsPath
Export-Rows -Rows @($readWriteRows) -Columns $retestColumns -Path $OutputReadWriteTargetsPath
Export-Rows -Rows @($nonprodRows) -Columns $retestColumns -Path $OutputNonprodCandidatesPath
Export-Rows -Rows @($decisionRows) -Columns $decisionColumns -Path $OutputDecisionTemplatePath
Export-Rows -Rows @($readonlyRows) -Columns $readonlyColumns -Path $OutputReadonlyPlanPath
Export-Rows -Rows @($summaryRows) -Columns $summaryColumns -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D8 Parallel Candidate Retest") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated by backend/scripts/46_build_d8_parallel_candidate_retest_package.ps1 from local project artifacts only.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D8 retests the parallel candidate pairs after D1-D7 evidence gates. It separates missing-object blockers, read/write validation blockers, and any pair ready for owner-approved non-production parallel testing. It does not run, schedule, trigger, deploy, or modify anything.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- $OutputRetestQueuePath") | Out-Null
$doc.Add("- $OutputItemEvidencePath") | Out-Null
$doc.Add("- $OutputObjectEvidencePath") | Out-Null
$doc.Add("- $OutputMissingObjectTargetsPath") | Out-Null
$doc.Add("- $OutputReadWriteTargetsPath") | Out-Null
$doc.Add("- $OutputNonprodCandidatesPath") | Out-Null
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
$doc.Add('- Keep `blocked_pending_d1_object_evidence` rows blocked until both candidate items have reviewed object-level lineage or an explicit accepted D1 decision.') | Out-Null
$doc.Add('- Keep `blocked_pending_d3_d4_d5_read_write_validation` rows blocked until lineage, exact type, and write/serialization evidence are reviewed.') | Out-Null
$doc.Add('- Use `analysis/d8_nonprod_parallel_test_candidates.csv` only for owner-approved non-production test planning; it is empty until evidence gates clear.') | Out-Null
$doc.Add('- No Fabric pipelines, schedules, triggers, deployment pipelines, repositories, or orchestration rules are changed by this package.') | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Next Human Step") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('Work `analysis/d8_missing_object_evidence_targets.csv` through D1 and `analysis/d8_read_write_validation_targets.csv` through D3/D4/D5 before approving any non-production parallel retest.') | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D8 parallel candidate retest package built."
Write-Host "Retest rows: $(@($retestRows).Count)"
Write-Host "Missing object evidence targets: $(@($missingObjectRows).Count)"
Write-Host "Read/write validation targets: $(@($readWriteRows).Count)"
Write-Host "Non-production parallel test candidates: $(@($nonprodRows).Count)"
