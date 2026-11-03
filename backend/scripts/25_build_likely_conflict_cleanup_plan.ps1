# Phase 25 - Likely-conflict cleanup plan: takes Phase 24's detected object
# conflicts plus everything still resting on "likely" (unconfirmed)
# evidence and turns them into a phased human cleanup plan (this is the
# script that spawned the whole D1-D8 confirmation-package family below:
# each Dn script is one phase of this plan, broken out on its own so
# progress on one category doesn't block the others). Purely local.
# Writes: $OutputPhasePlanPath, $OutputQueuePath, $OutputSummaryPath, $OutputDocPath.
param(
    [string]$OrchestrationV2PlanPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_plan.csv"),
    [string]$OrchestrationV2ConflictsPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_object_conflicts.csv"),
    [string]$OrchestrationV2ParallelPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_parallel_candidates.csv"),
    [string]$EvidenceHardeningQueuePath = (Join-Path $PSScriptRoot "../../analysis/evidence_hardening_queue.csv"),
    [string]$EvidenceHardeningSummaryPath = (Join-Path $PSScriptRoot "../../analysis/evidence_hardening_summary.csv"),
    [string]$ReadWriteClassificationPath = (Join-Path $PSScriptRoot "../../analysis/object_read_write_classification.csv"),
    [string]$SourceObjectTypeQueuePath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_resolution_queue.csv"),
    [string]$ManualLineageReviewQueuePath = (Join-Path $PSScriptRoot "../../analysis/manual_lineage_review_queue.csv"),
    [string]$OutputPhasePlanPath = (Join-Path $PSScriptRoot "../../analysis/likely_conflict_cleanup_phase_plan.csv"),
    [string]$OutputQueuePath = (Join-Path $PSScriptRoot "../../analysis/likely_conflict_cleanup_queue.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/likely_conflict_cleanup_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/22_likely_conflict_cleanup_plan.md")
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

function Convert-ToInt {
    param([object]$Value)
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    try { return [int][double]$Value } catch { return 0 }
}

function Convert-ToDouble {
    param([object]$Value)
    # [double]$Value (a bare cast) parses via invariant culture, which
    # treats "," as a thousands separator -- same comma-decimal bug found
    # and fixed in 07/13/14/24's identical functions. TryParse's 2-arg
    # overload uses CurrentCulture instead, matching how these strings
    # (from orchestration_v2_plan.csv's estimated_duration_seconds) were
    # written.
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

function Normalize-Key {
    param([string]$Value)
    if (-not $Value) { return "" }
    return ($Value.ToLowerInvariant() -replace "\s+", " ").Trim()
}

function Add-Phase {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [string]$PhaseId,
        [string]$PhaseName,
        [int]$CurrentCount,
        [string]$PrimaryInputs,
        [string]$Goal,
        [string]$Method,
        [string]$ExpectedOutput,
        [string]$GateToClose,
        [string]$HumanAction
    )
    $Rows.Add([pscustomobject]@{
        phase_id = $PhaseId
        phase_name = $PhaseName
        current_count = $CurrentCount
        primary_inputs = $PrimaryInputs
        goal = $Goal
        method = $Method
        expected_output = $ExpectedOutput
        gate_to_close = $GateToClose
        human_action = $HumanAction
    }) | Out-Null
}

function Add-QueueRow {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [string]$PhaseId,
        [string]$PhaseName,
        [int]$PriorityScore,
        [string]$BlockerType,
        [int]$BlockerCount,
        [string]$WorkspaceName = "",
        [string]$ItemType = "",
        [string]$ItemName = "",
        [string]$ItemQualifiedName = "",
        [string]$ObjectKey = "",
        [string]$ObjectDisplayName = "",
        [string]$EvidenceSource = "",
        [string]$RecommendedAction = "",
        [string]$GateToClose = ""
    )
    $Rows.Add([pscustomobject]@{
        phase_id = $PhaseId
        phase_name = $PhaseName
        priority_score = $PriorityScore
        blocker_type = $BlockerType
        blocker_count = $BlockerCount
        workspace_name = $WorkspaceName
        item_type = $ItemType
        item_name = $ItemName
        item_qualified_name = Limit-Text -Text $ItemQualifiedName -MaxLength 500
        object_key = Limit-Text -Text $ObjectKey -MaxLength 500
        object_display_name = Limit-Text -Text $ObjectDisplayName -MaxLength 300
        evidence_source = $EvidenceSource
        recommended_action = Limit-Text -Text $RecommendedAction -MaxLength 700
        gate_to_close = Limit-Text -Text $GateToClose -MaxLength 500
    }) | Out-Null
}

foreach ($path in @($OrchestrationV2PlanPath, $OrchestrationV2ConflictsPath, $OrchestrationV2ParallelPath, $EvidenceHardeningQueuePath, $ReadWriteClassificationPath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$planRows = @(Import-Csv -Path $OrchestrationV2PlanPath)
$conflictRows = @(Import-Csv -Path $OrchestrationV2ConflictsPath)
$parallelRows = @(Import-Csv -Path $OrchestrationV2ParallelPath)
$hardeningRows = @(Import-Csv -Path $EvidenceHardeningQueuePath)
$hardeningSummaryRows = Import-OptionalCsv -Path $EvidenceHardeningSummaryPath
$readWriteRows = @(Import-Csv -Path $ReadWriteClassificationPath)
$sourceTypeRows = Import-OptionalCsv -Path $SourceObjectTypeQueuePath
$manualReviewRows = Import-OptionalCsv -Path $ManualLineageReviewQueuePath

$planByStatus = @{}
foreach ($group in ($planRows | Group-Object v2_status)) { $planByStatus[$group.Name] = $group.Count }
$parallelByStatus = @{}
foreach ($group in ($parallelRows | Group-Object candidate_status)) { $parallelByStatus[$group.Name] = $group.Count }
$hardeningByIssue = @{}
foreach ($group in ($hardeningRows | Group-Object issue_type)) { $hardeningByIssue[$group.Name] = $group.Count }

$readWriteNeedsLineage = @($readWriteRows | Where-Object { $_.scheduling_readiness -eq "needs_lineage_confirmation" })
$readWriteNeedsType = @($readWriteRows | Where-Object { $_.scheduling_readiness -eq "needs_object_type_confirmation" })
$readWriteNeedsReview = @($readWriteRows | Where-Object { $_.scheduling_readiness -eq "needs_orchestration_review" })

$phaseRows = [System.Collections.Generic.List[object]]::new()

Add-Phase -Rows $phaseRows -PhaseId "D0" -PhaseName "Baseline and priority lock" `
    -CurrentCount $planRows.Count `
    -PrimaryInputs "analysis/orchestration_v2_summary.csv; analysis/orchestration_v2_plan.csv" `
    -Goal "Freeze current blocker metrics and use the queue as the single cleanup entry point." `
    -Method "Run this script after every refresh; compare counts before and after each cleanup phase." `
    -ExpectedOutput "Baseline counts and prioritized cleanup queue." `
    -GateToClose "All downstream phases have current counts and owners." `
    -HumanAction "Review the phase plan and pick the next phase to execute."

Add-Phase -Rows $phaseRows -PhaseId "D1" -PhaseName "Missing object-level evidence" `
    -CurrentCount ((@($hardeningRows | Where-Object { $_.issue_type -eq "missing_object_level_lineage" }).Count) + ((@($parallelRows | Where-Object { $_.candidate_status -eq "blocked_missing_object_evidence" }).Count))) `
    -PrimaryInputs "analysis/manual_lineage_review_queue.csv; analysis/evidence_hardening_queue.csv; analysis/orchestration_v2_parallel_candidates.csv" `
    -Goal "Attach object-level tables/views/stored procedures/files to items with no parseable lineage." `
    -Method "Use Fabric definitions, Azure DevOps code, SharePoint docs, OneLake paths, and owner/manual evidence." `
    -ExpectedOutput "Updated object evidence and fewer blocked_missing_object_evidence rows." `
    -GateToClose "No high-priority executable item remains without object-level lineage." `
    -HumanAction "Approve read-only/manual review of the top queue rows."

Add-Phase -Rows $phaseRows -PhaseId "D2" -PhaseName "Likely dependency confirmation" `
    -CurrentCount ((@($planRows | Where-Object { $_.v2_status -eq "blocked_dependency_confirmation" }).Count) + ((@($hardeningRows | Where-Object { $_.issue_type -eq "weak_relationship_confidence" }).Count))) `
    -PrimaryInputs "index/dependencies.csv; analysis/ideal_execution_edges.csv; analysis/evidence_hardening_queue.csv" `
    -Goal "Promote true dependency edges from likely to confirmed and mark false positives as rejected/manual-blocked." `
    -Method "Check Fabric definition/model binding first; then Azure DevOps, SharePoint design docs, and owner evidence." `
    -ExpectedOutput "Fewer blocked_dependency_confirmation rows and fewer likely dependency edges." `
    -GateToClose "High-impact report-model, execute, refresh, and depends_on likely edges are resolved." `
    -HumanAction "Approve dependency evidence review by priority."

Add-Phase -Rows $phaseRows -PhaseId "D3" -PhaseName "Likely object-lineage confirmation" `
    -CurrentCount $readWriteNeedsLineage.Count `
    -PrimaryInputs "analysis/object_read_write_classification.csv; analysis/evidence_hardening_queue.csv" `
    -Goal "Confirm read/write/execute references extracted from notebooks, CopyJobs, DataPipelines, and semantic model definitions." `
    -Method "Reconcile parser evidence with item definitions, code repositories, owner docs, and source metadata." `
    -ExpectedOutput "Fewer needs_lineage_confirmation rows." `
    -GateToClose "High-duration and high-impact executable items no longer depend on likely object evidence." `
    -HumanAction "Approve item-by-item source/code review."

Add-Phase -Rows $phaseRows -PhaseId "D4" -PhaseName "Exact table view stored procedure typing" `
    -CurrentCount ($readWriteNeedsType.Count + (@($sourceTypeRows | Where-Object { $_.status -eq "needs_metadata_review" }).Count)) `
    -PrimaryInputs "analysis/source_object_type_resolution_queue.csv; analysis/source_object_type_metadata_gaps.csv; analysis/object_read_write_classification.csv" `
    -Goal "Resolve table_or_view and native_query_object into table, view, stored_procedure, file, shortcut, or query." `
    -Method "Use read-only SQL/Fabric sys.objects where access exists, otherwise owner-approved catalog/manual evidence." `
    -ExpectedOutput "Fewer needs_object_type_confirmation and ambiguous object conflict rows." `
    -GateToClose "High-priority ambiguous objects in conflict and impact queues have exact type evidence." `
    -HumanAction "Approve metadata access cleanup or manual catalog evidence capture."

Add-Phase -Rows $phaseRows -PhaseId "D5" -PhaseName "Writer-reader and multi-writer conflict resolution" `
    -CurrentCount $conflictRows.Count `
    -PrimaryInputs "analysis/orchestration_v2_object_conflicts.csv; analysis/orchestration_v2_edges.csv" `
    -Goal "Turn object conflicts into explicit order rules or remove false conflicts after evidence cleanup." `
    -Method "For each shared object, decide writer order, writer-before-reader rules, or safe shared-read parallelism." `
    -ExpectedOutput "Resolved object guard edges and fewer object conflict rows." `
    -GateToClose "No high-impact object has unresolved multi-writer or writer-reader behavior." `
    -HumanAction "Approve serialization decisions for shared objects."

Add-Phase -Rows $phaseRows -PhaseId "D6" -PhaseName "Failure and duration stabilization" `
    -CurrentCount (@($planRows | Where-Object { $_.v2_status -eq "hold_failure_stabilization" -or $_.original_risk_flags -like "*duration_defaulted*" }).Count) `
    -PrimaryInputs "analysis/orchestration_v2_plan.csv; index/executions.csv; analysis/execution_duration_by_item.csv" `
    -Goal "Remove failure holds and replace default durations with observed or owner-approved estimates." `
    -Method "Review failure hotspots, disabled/enabled schedules, run histories, and long/defaulted duration items." `
    -ExpectedOutput "Fewer hold_failure_stabilization rows and better wave estimates." `
    -GateToClose "Failure hotspots are stabilized and high-impact duration defaults are replaced." `
    -HumanAction "Approve operational review with owners before any scheduling change."

Add-Phase -Rows $phaseRows -PhaseId "D7" -PhaseName "Orchestration review promotion" `
    -CurrentCount (@($planRows | Where-Object { $_.v2_status -eq "needs_orchestration_review" }).Count) `
    -PrimaryInputs "analysis/orchestration_v2_plan.csv; analysis/orchestration_v2_waves.csv" `
    -Goal "Promote reviewed rows into non-production orchestration candidates or keep them as manual/governance checks." `
    -Method "Review schedules, owners, environments, deployment pipelines, duration, and upstream/downstream evidence." `
    -ExpectedOutput "A non-prod candidate set for master pipeline design." `
    -GateToClose "Every review row has approved action: run, check, skip, or manual validation." `
    -HumanAction "Approve rows that can move to non-production pipeline design."

Add-Phase -Rows $phaseRows -PhaseId "D8" -PhaseName "Parallel candidate retest" `
    -CurrentCount $parallelRows.Count `
    -PrimaryInputs "analysis/orchestration_v2_parallel_candidates.csv; analysis/object_read_write_classification.csv" `
    -Goal "Re-run parallelism checks after D1-D7 and identify safe non-production test candidates." `
    -Method "Rebuild Phases B and C; accept only candidates without direct dependencies, unresolved evidence, or shared writes." `
    -ExpectedOutput "Non-production parallel test list or documented blockers." `
    -GateToClose "Parallel candidates are either approved for non-prod test or explicitly blocked." `
    -HumanAction "Approve a controlled non-production parallelism test batch."

$queueRows = [System.Collections.Generic.List[object]]::new()

foreach ($row in ($hardeningRows | Where-Object { $_.issue_type -eq "missing_object_level_lineage" })) {
    Add-QueueRow -Rows $queueRows -PhaseId "D1" -PhaseName "Missing object-level evidence" `
        -PriorityScore (Convert-ToInt (Get-FieldValue -Object $row -Names @("priority_score"))) `
        -BlockerType "missing_object_level_lineage" -BlockerCount 1 `
        -WorkspaceName (Get-FieldValue -Object $row -Names @("workspace_name")) `
        -ItemType (Get-FieldValue -Object $row -Names @("item_type")) `
        -ItemName (Get-FieldValue -Object $row -Names @("item_name")) `
        -ItemQualifiedName (Get-FieldValue -Object $row -Names @("item_qualified_name")) `
        -EvidenceSource "analysis/evidence_hardening_queue.csv" `
        -RecommendedAction (Get-FieldValue -Object $row -Names @("next_action")) `
        -GateToClose "Object-level lineage exists for this item."
}

foreach ($row in ($planRows | Where-Object { $_.v2_status -eq "blocked_dependency_confirmation" })) {
    $priority = 100 + (Convert-ToInt (Get-FieldValue -Object $row -Names @("successor_count"))) + (Convert-ToInt (Get-FieldValue -Object $row -Names @("incoming_likely_edges"))) + (Convert-ToInt (Get-FieldValue -Object $row -Names @("outgoing_likely_edges")))
    Add-QueueRow -Rows $queueRows -PhaseId "D2" -PhaseName "Likely dependency confirmation" `
        -PriorityScore $priority `
        -BlockerType "blocked_dependency_confirmation" -BlockerCount ((Convert-ToInt (Get-FieldValue -Object $row -Names @("incoming_likely_edges"))) + (Convert-ToInt (Get-FieldValue -Object $row -Names @("outgoing_likely_edges")))) `
        -WorkspaceName (Get-FieldValue -Object $row -Names @("workspace_name")) `
        -ItemType (Get-FieldValue -Object $row -Names @("item_type")) `
        -ItemName (Get-FieldValue -Object $row -Names @("item_name")) `
        -ItemQualifiedName (Get-FieldValue -Object $row -Names @("qualified_name")) `
        -EvidenceSource "analysis/orchestration_v2_plan.csv" `
        -RecommendedAction "Confirm likely dependency edges around this item from Fabric definitions, model/report binding, Azure DevOps, SharePoint, or owner evidence." `
        -GateToClose "Incoming/outgoing likely dependency count is zero or explicitly rejected."
}

$lineageGroups = $readWriteNeedsLineage | Group-Object item_qualified_name
foreach ($group in $lineageGroups) {
    $sample = $group.Group[0]
    $priority = 90 + $group.Count + (@($group.Group | Where-Object { $_.operation_type -eq "write" }).Count * 5)
    Add-QueueRow -Rows $queueRows -PhaseId "D3" -PhaseName "Likely object-lineage confirmation" `
        -PriorityScore $priority `
        -BlockerType "needs_lineage_confirmation" -BlockerCount $group.Count `
        -WorkspaceName (Get-FieldValue -Object $sample -Names @("workspace_name")) `
        -ItemType (Get-FieldValue -Object $sample -Names @("item_type")) `
        -ItemName (Get-FieldValue -Object $sample -Names @("item_name")) `
        -ItemQualifiedName (Get-FieldValue -Object $sample -Names @("item_qualified_name")) `
        -ObjectDisplayName (Get-FieldValue -Object $sample -Names @("object_display_name")) `
        -EvidenceSource "analysis/object_read_write_classification.csv" `
        -RecommendedAction "Confirm every likely read/write/execute object reference for this item from definition/code/metadata/owner evidence." `
        -GateToClose "All object rows for this item are confirmed or explicitly rejected."
}

foreach ($row in $sourceTypeRows) {
    if ((Get-FieldValue -Object $row -Names @("status")) -ne "needs_metadata_review") { continue }
    $priority = Convert-ToInt (Get-FieldValue -Object $row -Names @("priority_score"))
    $sourceType = Get-FieldValue -Object $row -Names @("source_type")
    $sourceServer = Get-FieldValue -Object $row -Names @("source_server")
    $sourceDatabase = Get-FieldValue -Object $row -Names @("source_database")
    $schemaName = Get-FieldValue -Object $row -Names @("schema_name")
    $objectName = Get-FieldValue -Object $row -Names @("object_name")
    $sourceObjectKey = @($sourceType, $sourceServer, $sourceDatabase, $schemaName, $objectName) -join "|"
    $sourceObjectDisplayName = "$sourceDatabase / $schemaName.$objectName"
    Add-QueueRow -Rows $queueRows -PhaseId "D4" -PhaseName "Exact table view stored procedure typing" `
        -PriorityScore $priority `
        -BlockerType "source_object_type_pending" -BlockerCount (Convert-ToInt (Get-FieldValue -Object $row -Names @("affected_item_count"))) `
        -WorkspaceName (Get-FieldValue -Object $row -Names @("workspaces")) `
        -ItemType (Get-FieldValue -Object $row -Names @("affected_item_types")) `
        -ObjectKey $sourceObjectKey `
        -ObjectDisplayName $sourceObjectDisplayName `
        -EvidenceSource "analysis/source_object_type_resolution_queue.csv" `
        -RecommendedAction (Get-FieldValue -Object $row -Names @("next_step")) `
        -GateToClose "resolved_object_type is exact or owner/manual evidence marks this object as intentionally unresolved."
}

foreach ($row in $conflictRows) {
    $priority = 80 + ((Convert-ToInt (Get-FieldValue -Object $row -Names @("writer_count"))) * 10) + ((Convert-ToInt (Get-FieldValue -Object $row -Names @("reader_count"))) * 3) + ((Convert-ToInt (Get-FieldValue -Object $row -Names @("executor_count"))) * 4)
    Add-QueueRow -Rows $queueRows -PhaseId "D5" -PhaseName "Writer-reader and multi-writer conflict resolution" `
        -PriorityScore $priority `
        -BlockerType (Get-FieldValue -Object $row -Names @("conflict_types")) `
        -BlockerCount ((Convert-ToInt (Get-FieldValue -Object $row -Names @("writer_count"))) + (Convert-ToInt (Get-FieldValue -Object $row -Names @("reader_count"))) + (Convert-ToInt (Get-FieldValue -Object $row -Names @("executor_count")))) `
        -ObjectKey (Get-FieldValue -Object $row -Names @("object_key")) `
        -ObjectDisplayName (Get-FieldValue -Object $row -Names @("object_display_name")) `
        -EvidenceSource "analysis/orchestration_v2_object_conflicts.csv" `
        -RecommendedAction (Get-FieldValue -Object $row -Names @("recommended_next_action")) `
        -GateToClose "Writers/readers are serialized, proven independent, or rejected as false conflict."
}

foreach ($row in ($planRows | Where-Object { $_.v2_status -eq "hold_failure_stabilization" -or $_.original_risk_flags -like "*duration_defaulted*" })) {
    $priority = 70 + (Convert-ToInt (Get-FieldValue -Object $row -Names @("failed_count"))) + [math]::Round((Convert-ToDouble (Get-FieldValue -Object $row -Names @("estimated_duration_seconds"))) / 600)
    Add-QueueRow -Rows $queueRows -PhaseId "D6" -PhaseName "Failure and duration stabilization" `
        -PriorityScore $priority `
        -BlockerType (Get-FieldValue -Object $row -Names @("v2_status")) -BlockerCount 1 `
        -WorkspaceName (Get-FieldValue -Object $row -Names @("workspace_name")) `
        -ItemType (Get-FieldValue -Object $row -Names @("item_type")) `
        -ItemName (Get-FieldValue -Object $row -Names @("item_name")) `
        -ItemQualifiedName (Get-FieldValue -Object $row -Names @("qualified_name")) `
        -EvidenceSource "analysis/orchestration_v2_plan.csv" `
        -RecommendedAction (Get-FieldValue -Object $row -Names @("v2_recommended_next_action")) `
        -GateToClose "Failure hold removed and duration estimate has observed or approved evidence."
}

foreach ($row in ($planRows | Where-Object { $_.v2_status -eq "needs_orchestration_review" })) {
    $priority = 60 + (Convert-ToInt (Get-FieldValue -Object $row -Names @("successor_count"))) + (Convert-ToInt (Get-FieldValue -Object $row -Names @("enabled_schedules")))
    Add-QueueRow -Rows $queueRows -PhaseId "D7" -PhaseName "Orchestration review promotion" `
        -PriorityScore $priority `
        -BlockerType "needs_orchestration_review" -BlockerCount 1 `
        -WorkspaceName (Get-FieldValue -Object $row -Names @("workspace_name")) `
        -ItemType (Get-FieldValue -Object $row -Names @("item_type")) `
        -ItemName (Get-FieldValue -Object $row -Names @("item_name")) `
        -ItemQualifiedName (Get-FieldValue -Object $row -Names @("qualified_name")) `
        -EvidenceSource "analysis/orchestration_v2_plan.csv" `
        -RecommendedAction (Get-FieldValue -Object $row -Names @("v2_recommended_next_action")) `
        -GateToClose "Approved action is recorded: run, check, skip, or manual validation."
}

foreach ($row in $parallelRows) {
    $priority = 50 + (Convert-ToInt (Get-FieldValue -Object $row -Names @("shared_write_object_count")) * 10) + (Convert-ToInt (Get-FieldValue -Object $row -Names @("shared_object_count")) * 2)
    Add-QueueRow -Rows $queueRows -PhaseId "D8" -PhaseName "Parallel candidate retest" `
        -PriorityScore $priority `
        -BlockerType (Get-FieldValue -Object $row -Names @("candidate_status")) -BlockerCount 1 `
        -WorkspaceName (Get-FieldValue -Object $row -Names @("workspace_name")) `
        -ItemType ((Get-FieldValue -Object $row -Names @("item_type_a")) + " / " + (Get-FieldValue -Object $row -Names @("item_type_b"))) `
        -ItemQualifiedName ((Get-FieldValue -Object $row -Names @("candidate_a")) + " <-> " + (Get-FieldValue -Object $row -Names @("candidate_b"))) `
        -ObjectDisplayName (Get-FieldValue -Object $row -Names @("sample_shared_objects")) `
        -EvidenceSource "analysis/orchestration_v2_parallel_candidates.csv" `
        -RecommendedAction (Get-FieldValue -Object $row -Names @("recommendation")) `
        -GateToClose "Candidate is approved for non-prod parallel test or explicitly blocked."
}

$queueColumns = @(
    "phase_id", "phase_name", "priority_score", "blocker_type", "blocker_count", "workspace_name", "item_type", "item_name",
    "item_qualified_name", "object_key", "object_display_name", "evidence_source", "recommended_action", "gate_to_close"
)
$phaseColumns = @("phase_id", "phase_name", "current_count", "primary_inputs", "goal", "method", "expected_output", "gate_to_close", "human_action")

$queueSorted = @($queueRows | Sort-Object @{ Expression = { $_.phase_id }; Ascending = $true }, @{ Expression = { [int]$_.priority_score }; Descending = $true })
Export-Rows -Rows @($phaseRows) -Columns $phaseColumns -Path $OutputPhasePlanPath
Export-Rows -Rows $queueSorted -Columns $queueColumns -Path $OutputQueuePath

$summaryRows = [System.Collections.Generic.List[object]]::new()
foreach ($group in ($queueRows | Group-Object phase_id, phase_name | Sort-Object Name)) {
    $sample = $group.Group[0]
    $summaryRows.Add([pscustomobject]@{
        phase_id = $sample.phase_id
        phase_name = $sample.phase_name
        queue_count = $group.Count
        max_priority_score = (@($group.Group | ForEach-Object { [int]$_.priority_score } | Measure-Object -Maximum).Maximum)
        top_blocker_types = ((@($group.Group | Group-Object blocker_type | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join "; ")
    }) | Out-Null
}
Export-Rows -Rows @($summaryRows) -Columns @("phase_id", "phase_name", "queue_count", "max_priority_score", "top_blocker_types") -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# Likely And Conflict Cleanup Plan") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated: $((Get-Date).ToString("s"))") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("This plan breaks the cleanup of conflicts and likely evidence into human-controlled phases. It is local-only and does not modify Fabric, SQL, OneLake, Power BI, schedules, deployment pipelines, or repositories.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Current Baseline") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- Orchestration v2 plan nodes: $($planRows.Count)") | Out-Null
$doc.Add("- Blocked dependency confirmation rows: $($planByStatus['blocked_dependency_confirmation'])") | Out-Null
$doc.Add("- Blocked lineage confirmation rows: $($planByStatus['blocked_lineage_confirmation'])") | Out-Null
$doc.Add("- Needs orchestration review rows: $($planByStatus['needs_orchestration_review'])") | Out-Null
$doc.Add("- Failure hold rows: $($planByStatus['hold_failure_stabilization'])") | Out-Null
$doc.Add("- Object conflict rows: $($conflictRows.Count)") | Out-Null
$doc.Add("- Parallel candidates blocked: $($parallelRows.Count)") | Out-Null
$doc.Add("- Evidence hardening rows: $($hardeningRows.Count)") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Phase Order") | Out-Null
$doc.Add("") | Out-Null
foreach ($phase in $phaseRows) {
    $doc.Add("- $($phase.phase_id) - $($phase.phase_name): $($phase.current_count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- analysis/likely_conflict_cleanup_phase_plan.csv") | Out-Null
$doc.Add("- analysis/likely_conflict_cleanup_queue.csv") | Out-Null
$doc.Add("- analysis/likely_conflict_cleanup_summary.csv") | Out-Null
$doc.Add("- docs/22_likely_conflict_cleanup_plan.md") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Operating Rule") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Run one phase at a time. After each phase, rebuild Phases B, C, and this cleanup plan, then compare counts. Promote evidence only when it is confirmed by generated local evidence, Azure DevOps, SharePoint, OneLake, read-only Fabric/SQL metadata, or owner-approved manual evidence.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Next Human Step") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Work cleanup packages in order: D1 missing object-level lineage, D2 likely dependency confirmation, D3 likely object-lineage confirmation, D4 exact object-type confirmation, D5 object conflict resolution, D6 failure and duration stabilization, then D7 orchestration review promotion. When packages exist, use docs/23_d1_missing_object_lineage.md, docs/24_d2_likely_dependency_confirmation.md, docs/25_d3_likely_object_lineage_confirmation.md, docs/26_d4_exact_object_type_confirmation.md, docs/27_d5_object_conflict_resolution.md, docs/28_d6_failure_duration_stabilization.md, and docs/29_d7_orchestration_review_promotion.md. Do not move to D8 until high-priority D1-D7 evidence, conflict decisions, failure holds, duration estimates, and promotion decisions are confirmed or explicitly blocked.") | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "Likely/conflict cleanup plan completed."
Write-Host "Phases: $($phaseRows.Count)"
Write-Host "Queue rows: $($queueRows.Count)"
Write-Host "Output: $OutputPhasePlanPath"
