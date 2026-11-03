# Phase 13 - Ideal execution plan: derives a recommended topological
# execution order (waves of items that can run in parallel, respecting
# dependencies) and highlights bottlenecks, producing both a plan CSV and
# an explanatory Mermaid diagram + doc. Purely local, no API calls.
# Reads: $ItemsPath/$DependenciesPath/$DurationByItemPath and Phase 7's
# critical-path/bottleneck outputs.
# Writes: $OutputPlanPath/$OutputEdgesPath/$OutputWavesPath/
# $OutputSummaryPath, $MermaidPath, $DocumentationPath.
param(
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$NodesPath = (Join-Path $PSScriptRoot "../../graph/nodes.csv"),
    [string]$DependenciesPath = (Join-Path $PSScriptRoot "../../index/dependencies.csv"),
    [string]$DurationByItemPath = (Join-Path $PSScriptRoot "../../analysis/execution_duration_by_item.csv"),
    [string]$ExecutionsPath = (Join-Path $PSScriptRoot "../../index/executions.csv"),
    [string]$CriticalPathPath = (Join-Path $PSScriptRoot "../../analysis/critical_path_candidates.csv"),
    [string]$FailureHotspotsPath = (Join-Path $PSScriptRoot "../../analysis/failure_hotspots.csv"),
    [string]$ManualCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/manual_execution_candidates.csv"),
    [string]$ScheduleReviewPath = (Join-Path $PSScriptRoot "../../analysis/schedule_review_candidates.csv"),
    [string]$ParallelCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/parallelism_candidates.csv"),
    [string]$OrchestrationGroupsPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_group_candidates.csv"),
    [string]$DeepObjectLineagePath = (Join-Path $PSScriptRoot "../../analysis/deep_object_lineage_item_enrichment.csv"),
    [string]$OutputPlanPath = (Join-Path $PSScriptRoot "../../analysis/ideal_execution_plan.csv"),
    [string]$OutputEdgesPath = (Join-Path $PSScriptRoot "../../analysis/ideal_execution_edges.csv"),
    [string]$OutputWavesPath = (Join-Path $PSScriptRoot "../../analysis/ideal_execution_waves.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/ideal_execution_summary.csv"),
    [string]$MermaidPath = (Join-Path $PSScriptRoot "../../diagrams/ideal_execution_pipeline.mmd"),
    [string]$DocumentationPath = (Join-Path $PSScriptRoot "../../docs/13_ideal_execution_pipeline_design.md"),
    [int]$DiagramWaveLimit = 12,
    [int]$TopBottleneckLimit = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

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

    try { return [int][double]$Value } catch { return 0 }
}

function Convert-ToDouble {
    param([object]$Value)

    if ($null -eq $Value -or [string]$Value -eq "") {
        return 0.0
    }

    # [double]$Value (a bare cast) parses via invariant culture, which
    # treats "," as a thousands separator -- so a comma-decimal string
    # like "634,667" (written elsewhere on this es-ES machine, e.g. into
    # analysis/execution_duration_by_item.csv) silently becomes 634667
    # instead of 634.667, a ~1000x inflation. Same bug found and fixed in
    # 07_optimize_orchestration.ps1's identical function. TryParse's 2-arg
    # overload uses CurrentCulture instead, matching how these strings
    # were written in the first place.
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

function Get-CollectionCount {
    param([object]$Value)

    if ($null -eq $Value) {
        return 0
    }

    if ($Value -is [System.Collections.ICollection]) {
        return [int]$Value.Count
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $count = 0
        foreach ($item in $Value) {
            $count++
        }
        return $count
    }

    return 1
}

function Get-NameParts {
    param([string]$QualifiedName)

    $parts = @($QualifiedName -split " / ")
    if ($QualifiedName -like "External Connection / *") {
        return [pscustomobject]@{
            workspace_name = "External"
            item_type = "ExternalConnection"
            item_name = if ($parts.Count -ge 3) { $parts[-1] } else { $QualifiedName }
        }
    }

    return [pscustomobject]@{
        workspace_name = if ($parts.Count -ge 1) { $parts[0] } else { "" }
        item_type = if ($parts.Count -ge 3) { $parts[1] } else { "" }
        item_name = if ($parts.Count -ge 3) { $parts[2] } else { $QualifiedName }
    }
}

function Get-OrchestrationRole {
    param(
        [string]$QualifiedName,
        [string]$ItemType
    )

    if ($QualifiedName -like "External Connection / *") {
        return "source_readiness"
    }

    switch ($ItemType) {
        { $_ -in @("Lakehouse", "SQLEndpoint", "Warehouse") } { return "source_readiness" }
        { $_ -in @("DataPipeline", "CopyJob", "Notebook", "Dataflow", "UserDataFunction", "Eventstream") } { return "data_process" }
        "SemanticModel" { return "semantic_refresh" }
        { $_ -in @("Report", "PaginatedReport", "Dashboard", "KQLDashboard") } { return "consumption_validation" }
        default { return "governance_review" }
    }
}

function Get-StageIndex {
    param([string]$Role)

    switch ($Role) {
        "source_readiness" { return 0 }
        "data_process" { return 1 }
        "semantic_refresh" { return 2 }
        "consumption_validation" { return 3 }
        default { return 4 }
    }
}

function Get-DefaultDuration {
    param([string]$Role)

    switch ($Role) {
        "source_readiness" { return 0.0 }
        "data_process" { return 300.0 }
        "semantic_refresh" { return 300.0 }
        "consumption_validation" { return 30.0 }
        default { return 60.0 }
    }
}

function Get-MermaidId {
    param([string]$Text)

    $hashBytes = [System.Security.Cryptography.SHA1]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
    $hash = ([System.BitConverter]::ToString($hashBytes)).Replace("-", "").Substring(0, 10).ToLowerInvariant()
    return "n_$hash"
}

function Escape-MermaidLabel {
    param([string]$Text)

    if (-not $Text) {
        return ""
    }

    return (($Text -replace '"', "'") -replace "\|", "/")
}

foreach ($path in @($ItemsPath, $NodesPath, $DependenciesPath, $DurationByItemPath, $ExecutionsPath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$items = @(Import-Csv -Path $ItemsPath)
$nodes = @(Import-Csv -Path $NodesPath)
$dependencies = @(Import-Csv -Path $DependenciesPath)
$durations = @(Import-Csv -Path $DurationByItemPath)
$executions = @(Import-Csv -Path $ExecutionsPath)
$criticalRows = if (Test-Path $CriticalPathPath) { @(Import-Csv -Path $CriticalPathPath) } else { @() }
$failureRows = if (Test-Path $FailureHotspotsPath) { @(Import-Csv -Path $FailureHotspotsPath) } else { @() }
$manualRows = if (Test-Path $ManualCandidatesPath) { @(Import-Csv -Path $ManualCandidatesPath) } else { @() }
$scheduleReviewRows = if (Test-Path $ScheduleReviewPath) { @(Import-Csv -Path $ScheduleReviewPath) } else { @() }
$parallelRows = if (Test-Path $ParallelCandidatesPath) { @(Import-Csv -Path $ParallelCandidatesPath) } else { @() }
$orchestrationGroupRows = if (Test-Path $OrchestrationGroupsPath) { @(Import-Csv -Path $OrchestrationGroupsPath) } else { @() }
$deepObjectLineageRows = if (Test-Path $DeepObjectLineagePath) { @(Import-Csv -Path $DeepObjectLineagePath) } else { @() }

$metadataByName = @{}
foreach ($item in $items) {
    $qualifiedName = Get-FieldValue -Object $item -Names @("qualified_name")
    if (-not $qualifiedName) { continue }
    $metadataByName[$qualifiedName] = [pscustomobject]@{
        workspace_name = Get-FieldValue -Object $item -Names @("workspace_name")
        item_type = Get-FieldValue -Object $item -Names @("item_type")
        item_name = Get-FieldValue -Object $item -Names @("item_name")
        source_system = Get-FieldValue -Object $item -Names @("source_system")
        technical_id = Get-FieldValue -Object $item -Names @("technical_id")
    }
}

foreach ($node in $nodes) {
    $qualifiedName = Get-FieldValue -Object $node -Names @("qualified_name")
    if (-not $qualifiedName -or $metadataByName.ContainsKey($qualifiedName)) { continue }
    $parts = Get-NameParts -QualifiedName $qualifiedName
    $metadataByName[$qualifiedName] = [pscustomobject]@{
        workspace_name = Get-FieldValue -Object $node -Names @("workspace_name")
        item_type = Get-FieldValue -Object $node -Names @("item_type")
        item_name = Get-FieldValue -Object $node -Names @("display_name")
        source_system = Get-FieldValue -Object $node -Names @("source_system")
        technical_id = Get-FieldValue -Object $node -Names @("technical_id")
    }
    if (-not $metadataByName[$qualifiedName].workspace_name) { $metadataByName[$qualifiedName].workspace_name = $parts.workspace_name }
    if (-not $metadataByName[$qualifiedName].item_type) { $metadataByName[$qualifiedName].item_type = $parts.item_type }
    if (-not $metadataByName[$qualifiedName].item_name) { $metadataByName[$qualifiedName].item_name = $parts.item_name }
}

$durationByName = @{}
foreach ($row in $durations) {
    $qualifiedName = Get-FieldValue -Object $row -Names @("qualified_name")
    if (-not $qualifiedName -or $durationByName.ContainsKey($qualifiedName)) { continue }
    $durationByName[$qualifiedName] = $row
}

$scheduleByName = @{}
foreach ($row in ($executions | Where-Object { $_.record_type -eq "schedule" })) {
    $qualifiedName = Get-FieldValue -Object $row -Names @("qualified_name")
    if (-not $qualifiedName) { continue }
    if (-not $scheduleByName.ContainsKey($qualifiedName)) {
        $scheduleByName[$qualifiedName] = [pscustomobject]@{
            enabled = 0
            disabled = 0
            times = [System.Collections.Generic.List[string]]::new()
        }
    }
    if ((Get-FieldValue -Object $row -Names @("schedule_enabled")) -eq "True") {
        $scheduleByName[$qualifiedName].enabled += 1
    }
    else {
        $scheduleByName[$qualifiedName].disabled += 1
    }
    $timeText = Get-FieldValue -Object $row -Names @("scheduled_time")
    if ($timeText -and -not $scheduleByName[$qualifiedName].times.Contains($timeText)) {
        $scheduleByName[$qualifiedName].times.Add($timeText) | Out-Null
    }
}

$criticalSet = @{}
foreach ($row in $criticalRows) {
    $name = Get-FieldValue -Object $row -Names @("qualified_name")
    if ($name) { $criticalSet[$name] = $row }
}

$failureSet = @{}
foreach ($row in $failureRows) {
    $name = Get-FieldValue -Object $row -Names @("qualified_name")
    if ($name) { $failureSet[$name] = $row }
}

$manualSet = @{}
foreach ($row in $manualRows) {
    $name = Get-FieldValue -Object $row -Names @("qualified_name")
    if ($name) { $manualSet[$name] = $row }
}

$scheduleReviewSet = @{}
foreach ($row in $scheduleReviewRows) {
    $name = Get-FieldValue -Object $row -Names @("qualified_name")
    if ($name) { $scheduleReviewSet[$name] = $row }
}

$fanoutSet = @{}
foreach ($row in $orchestrationGroupRows) {
    $name = Get-FieldValue -Object $row -Names @("source_qualified_name")
    if ($name) { $fanoutSet[$name] = $row }
}

$deepLineageByName = @{}
foreach ($row in $deepObjectLineageRows) {
    $name = Get-FieldValue -Object $row -Names @("item_qualified_name", "qualified_name")
    if ($name -and -not $deepLineageByName.ContainsKey($name)) {
        $deepLineageByName[$name] = $row
    }
}

$nodeMap = @{}
$incomingEdgeNames = @{}
$outgoingEdgeNames = @{}
$incomingExecutes = @{}
$outgoingExecutes = @{}
$incomingLikely = @{}

function Add-Node {
    param([string]$QualifiedName)

    if (-not $QualifiedName) { return }
    if ($script:nodeMap.ContainsKey($QualifiedName)) { return }

    $metadata = if ($script:metadataByName.ContainsKey($QualifiedName)) { $script:metadataByName[$QualifiedName] } else { $null }
    $parts = Get-NameParts -QualifiedName $QualifiedName
    $workspaceName = if ($metadata) { Get-FieldValue -Object $metadata -Names @("workspace_name") } else { "" }
    $itemType = if ($metadata) { Get-FieldValue -Object $metadata -Names @("item_type") } else { "" }
    $itemName = if ($metadata) { Get-FieldValue -Object $metadata -Names @("item_name") } else { "" }
    if (-not $workspaceName) { $workspaceName = $parts.workspace_name }
    if (-not $itemType) { $itemType = $parts.item_type }
    if (-not $itemName) { $itemName = $parts.item_name }

    $role = Get-OrchestrationRole -QualifiedName $QualifiedName -ItemType $itemType
    $duration = if ($script:durationByName.ContainsKey($QualifiedName)) { $script:durationByName[$QualifiedName] } else { $null }
    $deepLineage = if ($script:deepLineageByName.ContainsKey($QualifiedName)) { $script:deepLineageByName[$QualifiedName] } else { $null }
    $avg = if ($duration) { Convert-ToDouble (Get-FieldValue -Object $duration -Names @("avg_duration_seconds")) } else { 0.0 }
    $max = if ($duration) { Convert-ToDouble (Get-FieldValue -Object $duration -Names @("max_duration_seconds")) } else { 0.0 }
    $estimated = $avg
    $durationSource = "observed_avg"
    if ($estimated -le 0 -and $max -gt 0) {
        $estimated = $max
        $durationSource = "observed_max_fallback"
    }
    elseif ($estimated -le 0) {
        $estimated = Get-DefaultDuration -Role $role
        $durationSource = "default_by_role"
    }

    $script:nodeMap[$QualifiedName] = [ordered]@{
        qualified_name = $QualifiedName
        workspace_name = $workspaceName
        item_name = $itemName
        item_type = $itemType
        orchestration_role = $role
        stage_index = Get-StageIndex -Role $role
        proposed_stage = switch ($role) {
            "source_readiness" { "0_source_readiness" }
            "data_process" { "1_execute_and_transform" }
            "semantic_refresh" { "2_refresh_semantic_models" }
            "consumption_validation" { "3_validate_reports_and_consumption" }
            default { "4_governance_review" }
        }
        estimated_duration_seconds = [math]::Round($estimated, 3)
        duration_source = $durationSource
        run_count = if ($duration) { Convert-ToInt (Get-FieldValue -Object $duration -Names @("run_count")) } else { 0 }
        completed_count = if ($duration) { Convert-ToInt (Get-FieldValue -Object $duration -Names @("completed_count")) } else { 0 }
        failed_count = if ($duration) { Convert-ToInt (Get-FieldValue -Object $duration -Names @("failed_count")) } else { 0 }
        manual_count = if ($duration) { Convert-ToInt (Get-FieldValue -Object $duration -Names @("manual_count")) } else { 0 }
        scheduled_count = if ($duration) { Convert-ToInt (Get-FieldValue -Object $duration -Names @("scheduled_count")) } else { 0 }
        enabled_schedules = if ($script:scheduleByName.ContainsKey($QualifiedName)) { $script:scheduleByName[$QualifiedName].enabled } else { 0 }
        disabled_schedules = if ($script:scheduleByName.ContainsKey($QualifiedName)) { $script:scheduleByName[$QualifiedName].disabled } else { 0 }
        schedule_times = if ($script:scheduleByName.ContainsKey($QualifiedName)) { @($script:scheduleByName[$QualifiedName].times) -join "; " } else { "" }
        topological_level = 0
        wave_index = 0
        estimated_start_seconds = 0.0
        estimated_finish_seconds = 0.0
        predecessor_count = 0
        successor_count = 0
        incoming_likely_edges = 0
        outgoing_likely_edges = 0
        deep_lineage_status = if ($deepLineage) { Get-FieldValue -Object $deepLineage -Names @("deep_lineage_status") } else { "" }
        object_coverage_status = if ($deepLineage) { Get-FieldValue -Object $deepLineage -Names @("coverage_status") } else { "" }
        object_review_status = if ($deepLineage) { Get-FieldValue -Object $deepLineage -Names @("review_status") } else { "" }
        object_reference_count = if ($deepLineage) { Convert-ToInt (Get-FieldValue -Object $deepLineage -Names @("object_reference_count")) } else { 0 }
        exact_object_reference_count = if ($deepLineage) { Convert-ToInt (Get-FieldValue -Object $deepLineage -Names @("exact_object_reference_count")) } else { 0 }
        ambiguous_object_reference_count = if ($deepLineage) { Convert-ToInt (Get-FieldValue -Object $deepLineage -Names @("ambiguous_object_reference_count")) } else { 0 }
        confirmed_object_lineage_rows = if ($deepLineage) { Convert-ToInt (Get-FieldValue -Object $deepLineage -Names @("confirmed_lineage_rows")) } else { 0 }
        likely_object_lineage_rows = if ($deepLineage) { Convert-ToInt (Get-FieldValue -Object $deepLineage -Names @("likely_lineage_rows")) } else { 0 }
        read_object_count = if ($deepLineage) { Convert-ToInt (Get-FieldValue -Object $deepLineage -Names @("read_count")) } else { 0 }
        write_object_count = if ($deepLineage) { Convert-ToInt (Get-FieldValue -Object $deepLineage -Names @("write_count")) } else { 0 }
        execute_object_count = if ($deepLineage) { Convert-ToInt (Get-FieldValue -Object $deepLineage -Names @("execute_count")) } else { 0 }
        unknown_object_count = if ($deepLineage) { Convert-ToInt (Get-FieldValue -Object $deepLineage -Names @("unknown_count")) } else { 0 }
        object_lineage_next_action = if ($deepLineage) { Get-FieldValue -Object $deepLineage -Names @("next_action") } else { "" }
        is_master_action = $true
        action_type = ""
        parallel_group = ""
        parallel_readiness = ""
        risk_flags = ""
        human_validation_required = "yes"
        recommendation = ""
    }
}

$edgeRows = [System.Collections.Generic.List[object]]::new()
$edgeKeySet = @{}

function Add-PlanEdge {
    param(
        [string]$Upstream,
        [string]$Downstream,
        [string]$OriginalRelationship,
        [string]$PlanRelationship,
        [string]$Confidence,
        [string]$Evidence,
        [string]$SourceSystem,
        [string]$Notes
    )

    if (-not $Upstream -or -not $Downstream -or $Upstream -eq $Downstream) {
        return
    }

    Add-Node -QualifiedName $Upstream
    Add-Node -QualifiedName $Downstream

    $key = "$Upstream|$Downstream|$PlanRelationship|$Confidence"
    if ($script:edgeKeySet.ContainsKey($key)) {
        return
    }
    $script:edgeKeySet[$key] = $true

    if (-not $script:outgoingEdgeNames.ContainsKey($Upstream)) { $script:outgoingEdgeNames[$Upstream] = [System.Collections.Generic.List[string]]::new() }
    if (-not $script:incomingEdgeNames.ContainsKey($Downstream)) { $script:incomingEdgeNames[$Downstream] = [System.Collections.Generic.List[string]]::new() }
    $script:outgoingEdgeNames[$Upstream].Add($Downstream) | Out-Null
    $script:incomingEdgeNames[$Downstream].Add($Upstream) | Out-Null

    if ($OriginalRelationship -eq "executes") {
        if (-not $script:outgoingExecutes.ContainsKey($Upstream)) { $script:outgoingExecutes[$Upstream] = 0 }
        if (-not $script:incomingExecutes.ContainsKey($Downstream)) { $script:incomingExecutes[$Downstream] = 0 }
        $script:outgoingExecutes[$Upstream] += 1
        $script:incomingExecutes[$Downstream] += 1
    }

    if ($Confidence -ne "confirmed") {
        if (-not $script:incomingLikely.ContainsKey($Downstream)) { $script:incomingLikely[$Downstream] = 0 }
        $script:incomingLikely[$Downstream] += 1
    }

    $script:edgeRows.Add([pscustomobject]@{
        upstream_qualified_name = $Upstream
        downstream_qualified_name = $Downstream
        original_relationship_type = $OriginalRelationship
        plan_relationship_type = $PlanRelationship
        confidence = if ($Confidence) { $Confidence } else { "unknown" }
        source_system = Limit-Text -Text $SourceSystem -MaxLength 220
        evidence = Limit-Text -Text $Evidence -MaxLength 500
        notes = Limit-Text -Text $Notes -MaxLength 500
    }) | Out-Null
}

foreach ($dep in $dependencies) {
    $from = Get-FieldValue -Object $dep -Names @("from_qualified_name")
    $to = Get-FieldValue -Object $dep -Names @("to_qualified_name")
    $relationship = Get-FieldValue -Object $dep -Names @("relationship_type")
    $confidence = Get-FieldValue -Object $dep -Names @("confidence")
    $sourceSystem = Get-FieldValue -Object $dep -Names @("source_system")
    $evidence = Get-FieldValue -Object $dep -Names @("evidence")
    $notes = Get-FieldValue -Object $dep -Names @("notes")

    switch ($relationship) {
        "depends_on" {
            Add-PlanEdge -Upstream $to -Downstream $from -OriginalRelationship $relationship -PlanRelationship "upstream_readiness_before_item" -Confidence $confidence -Evidence $evidence -SourceSystem $sourceSystem -Notes $notes
        }
        "uses_model" {
            Add-PlanEdge -Upstream $to -Downstream $from -OriginalRelationship $relationship -PlanRelationship "model_before_report_validation" -Confidence $confidence -Evidence $evidence -SourceSystem $sourceSystem -Notes $notes
        }
        "serves_report" {
            Add-PlanEdge -Upstream $from -Downstream $to -OriginalRelationship $relationship -PlanRelationship "model_before_report_validation" -Confidence $confidence -Evidence $evidence -SourceSystem $sourceSystem -Notes $notes
        }
        "executes" {
            Add-PlanEdge -Upstream $from -Downstream $to -OriginalRelationship $relationship -PlanRelationship "existing_orchestrator_calls_child" -Confidence $confidence -Evidence $evidence -SourceSystem $sourceSystem -Notes $notes
        }
    }
}

foreach ($duration in $durations) {
    $name = Get-FieldValue -Object $duration -Names @("qualified_name")
    if ($name) { Add-Node -QualifiedName $name }
}

foreach ($name in $metadataByName.Keys) {
    $metadata = $metadataByName[$name]
    $itemType = Get-FieldValue -Object $metadata -Names @("item_type")
    if ($itemType -in @("DataPipeline", "CopyJob", "Notebook", "Dataflow", "SemanticModel", "Report", "PaginatedReport", "Dashboard", "Lakehouse", "SQLEndpoint", "Warehouse")) {
        Add-Node -QualifiedName $name
    }
}

$stageNames = @("0_source_readiness", "1_execute_and_transform", "2_refresh_semantic_models", "3_validate_reports_and_consumption", "4_governance_review")
$waveByName = @{}
$localLevelByName = @{}
$stageOffset = 0

foreach ($stageIndex in 0..4) {
    $stageNodeNames = @($nodeMap.Keys | Where-Object { [int]$nodeMap[$_].stage_index -eq $stageIndex } | Sort-Object)
    if ($stageNodeNames.Count -eq 0) {
        continue
    }

    $stageSet = @{}
    foreach ($name in $stageNodeNames) { $stageSet[$name] = $true }

    $inDegree = @{}
    $stageOutgoing = @{}
    foreach ($name in $stageNodeNames) {
        $inDegree[$name] = 0
        $stageOutgoing[$name] = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($edge in $edgeRows) {
        $upstream = $edge.upstream_qualified_name
        $downstream = $edge.downstream_qualified_name
        if ($stageSet.ContainsKey($upstream) -and $stageSet.ContainsKey($downstream)) {
            $stageOutgoing[$upstream].Add($downstream) | Out-Null
            $inDegree[$downstream] += 1
        }
    }

    $queue = [System.Collections.Generic.List[string]]::new()
    foreach ($name in ($stageNodeNames | Where-Object { $inDegree[$_] -eq 0 } | Sort-Object)) {
        $queue.Add($name) | Out-Null
        $localLevelByName[$name] = 0
    }

    $visited = @{}
    while ($queue.Count -gt 0) {
        $current = $queue[0]
        $queue.RemoveAt(0)
        if ($visited.ContainsKey($current)) { continue }
        $visited[$current] = $true

        foreach ($child in $stageOutgoing[$current]) {
            $candidateLevel = [int]$localLevelByName[$current] + 1
            if (-not $localLevelByName.ContainsKey($child) -or [int]$localLevelByName[$child] -lt $candidateLevel) {
                $localLevelByName[$child] = $candidateLevel
            }
            $inDegree[$child] -= 1
            if ($inDegree[$child] -eq 0) {
                $queue.Add($child) | Out-Null
            }
        }
    }

    $cycleLevel = 0
    if ($localLevelByName.Count -gt 0) {
        $cycleLevel = [int](@($localLevelByName.Values | Measure-Object -Maximum).Maximum) + 1
    }
    foreach ($name in $stageNodeNames) {
        if (-not $localLevelByName.ContainsKey($name)) {
            $localLevelByName[$name] = $cycleLevel
            $nodeMap[$name].risk_flags = "cycle_or_unresolved_same_stage_dependency"
        }
    }

    $maxStageLevel = 0
    foreach ($name in $stageNodeNames) {
        $level = [int]$localLevelByName[$name]
        $waveByName[$name] = $stageOffset + $level
        $nodeMap[$name].topological_level = $level
        $nodeMap[$name].wave_index = $waveByName[$name]
        if ($level -gt $maxStageLevel) { $maxStageLevel = $level }
    }

    $stageOffset += $maxStageLevel + 1
}

$waveDurations = @{}
foreach ($name in $nodeMap.Keys) {
    $wave = [int]$nodeMap[$name].wave_index
    $duration = [double]$nodeMap[$name].estimated_duration_seconds
    if (-not $waveDurations.ContainsKey($wave) -or [double]$waveDurations[$wave] -lt $duration) {
        $waveDurations[$wave] = $duration
    }
}

$waveStarts = @{}
$elapsed = 0.0
foreach ($wave in ($waveDurations.Keys | Sort-Object { [int]$_ })) {
    $waveStarts[$wave] = $elapsed
    $elapsed += [double]$waveDurations[$wave]
}

$waveMaxNodeNames = @{}
foreach ($wave in ($waveDurations.Keys | Sort-Object { [int]$_ })) {
    $maxDuration = [double]$waveDurations[$wave]
    $waveMaxNodeNames[$wave] = @($nodeMap.Keys | Where-Object { [int]$nodeMap[$_].wave_index -eq [int]$wave -and [math]::Abs([double]$nodeMap[$_].estimated_duration_seconds - $maxDuration) -lt 0.001 })
}

foreach ($name in $nodeMap.Keys) {
    $node = $nodeMap[$name]
    $wave = [int]$node.wave_index
    $node.estimated_start_seconds = [math]::Round([double]$waveStarts[$wave], 3)
    $node.estimated_finish_seconds = [math]::Round([double]$node.estimated_start_seconds + [double]$node.estimated_duration_seconds, 3)
    $node.predecessor_count = if ($incomingEdgeNames.ContainsKey($name)) { $incomingEdgeNames[$name].Count } else { 0 }
    $node.successor_count = if ($outgoingEdgeNames.ContainsKey($name)) { $outgoingEdgeNames[$name].Count } else { 0 }
    $node.incoming_likely_edges = if ($incomingLikely.ContainsKey($name)) { $incomingLikely[$name] } else { 0 }
    $node.outgoing_likely_edges = @($edgeRows | Where-Object { $_.upstream_qualified_name -eq $name -and $_.confidence -ne "confirmed" }).Count

    $flags = [System.Collections.Generic.List[string]]::new()
    if ($node.risk_flags) { $flags.Add($node.risk_flags) | Out-Null }
    if ($criticalSet.ContainsKey($name)) { $flags.Add("critical_path_candidate") | Out-Null }
    if ($failureSet.ContainsKey($name)) { $flags.Add("failure_hotspot_stabilize_first") | Out-Null }
    if ($manualSet.ContainsKey($name)) { $flags.Add("repeated_manual_candidate") | Out-Null }
    if ($scheduleReviewSet.ContainsKey($name)) { $flags.Add("schedule_review_required") | Out-Null }
    if ($fanoutSet.ContainsKey($name)) { $flags.Add("existing_fanout_orchestrator") | Out-Null }
    if ([int]$node.incoming_likely_edges -gt 0 -or [int]$node.outgoing_likely_edges -gt 0) { $flags.Add("has_likely_dependency_evidence") | Out-Null }
    switch ($node.deep_lineage_status) {
        "source_missing" { $flags.Add("phase12_source_missing") | Out-Null }
        "object_missing" { $flags.Add("phase12_object_missing") | Out-Null }
        "blocked_unknown_operation" { $flags.Add("phase12_unknown_object_operation") | Out-Null }
        "needs_object_type_resolution" { $flags.Add("phase12_object_type_resolution_required") | Out-Null }
        "needs_lineage_confirmation" { $flags.Add("phase12_likely_object_lineage") | Out-Null }
        "ready_confirmed" { $flags.Add("phase12_object_lineage_confirmed") | Out-Null }
    }
    if ([int]$node.write_object_count -gt 0) { $flags.Add("phase12_write_targets_detected") | Out-Null }
    if ($node.item_type -eq "Notebook" -and -not $node.deep_lineage_status) { $flags.Add("notebook_read_write_validation_required") | Out-Null }
    if ($node.duration_source -eq "default_by_role" -and $node.orchestration_role -ne "source_readiness") { $flags.Add("duration_defaulted") | Out-Null }

    if ($incomingExecutes.ContainsKey($name)) {
        $node.is_master_action = $false
        $flags.Add("covered_by_existing_orchestrator") | Out-Null
    }

    if ($node.orchestration_role -eq "source_readiness") {
        $node.action_type = "check_source_readiness"
        $node.human_validation_required = "yes"
    }
    elseif ($node.orchestration_role -eq "data_process" -and $outgoingExecutes.ContainsKey($name)) {
        $node.action_type = "run_existing_orchestrator_or_refactor_branches"
    }
    elseif ($node.orchestration_role -eq "data_process") {
        $node.action_type = if ($node.is_master_action) { "run_standalone_process" } else { "child_activity_inside_existing_orchestrator" }
    }
    elseif ($node.orchestration_role -eq "semantic_refresh") {
        $node.action_type = "refresh_semantic_model_after_upstream_readiness"
    }
    elseif ($node.orchestration_role -eq "consumption_validation") {
        $node.action_type = "validate_report_after_model_refresh"
    }
    else {
        $node.action_type = "review_governance_or_unsupported_item"
    }

    $node.parallel_group = "wave_$wave"
    if ($failureSet.ContainsKey($name)) {
        $node.parallel_readiness = "hold_until_stabilized"
    }
    elseif ($node.deep_lineage_status -in @("source_missing", "object_missing", "blocked_unknown_operation")) {
        $node.parallel_readiness = "blocked_pending_deep_object_lineage"
    }
    elseif ([int]$node.ambiguous_object_reference_count -gt 0 -or [int]$node.likely_object_lineage_rows -gt 0) {
        $node.parallel_readiness = "candidate_requires_object_lineage_confirmation"
    }
    elseif ([int]$node.write_object_count -gt 0) {
        $node.parallel_readiness = "candidate_requires_write_conflict_review"
    }
    elseif ($node.item_type -in @("Notebook", "CopyJob", "DataPipeline", "Dataflow")) {
        $node.parallel_readiness = "candidate_requires_read_write_validation"
    }
    elseif ([int]$node.incoming_likely_edges -gt 0 -or [int]$node.outgoing_likely_edges -gt 0) {
        $node.parallel_readiness = "candidate_requires_dependency_confirmation"
    }
    else {
        $node.parallel_readiness = "low_graph_risk_candidate"
    }

    if (@($waveMaxNodeNames[$wave]) -contains $name -and [double]$node.estimated_duration_seconds -gt 0) {
        $flags.Add("wave_bottleneck") | Out-Null
    }

    $node.risk_flags = (@($flags | Select-Object -Unique) -join "; ")

    if ($node.risk_flags -match "failure_hotspot") {
        $node.recommendation = "Stabilize failures before using this node in an optimized production orchestration."
    }
    elseif ($node.risk_flags -match "phase12_source_missing|phase12_object_missing|phase12_unknown_object_operation") {
        $node.recommendation = "Complete Phase 12 source/object lineage evidence before using this node as an orchestration dependency or parallel candidate."
    }
    elseif ($node.risk_flags -match "phase12_object_type_resolution_required") {
        $node.recommendation = "Resolve ambiguous table/view/native-query object types before approving impact analysis or parallel execution."
    }
    elseif ($node.risk_flags -match "phase12_likely_object_lineage") {
        $node.recommendation = "Confirm likely object-level lineage before treating this node as a hard sequencing rule."
    }
    elseif ($node.risk_flags -match "phase12_write_targets_detected") {
        $node.recommendation = "Review write targets and shared-table/file conflicts before placing this node in a parallel wave."
    }
    elseif ($node.risk_flags -match "notebook_read_write") {
        $node.recommendation = "Inspect notebook reads/writes before approving parallel execution or master-pipeline scheduling."
    }
    elseif ($node.orchestration_role -eq "semantic_refresh") {
        $node.recommendation = "Refresh after source readiness and upstream process waves selected for the same business flow."
    }
    elseif ($node.orchestration_role -eq "data_process") {
        $node.recommendation = "Place in its wave only after confirming upstream readiness, writes, retries, and owner approval."
    }
    else {
        $node.recommendation = "Use as a proposal row for human review; do not deploy automatically."
    }
}

$planRows = @(
    $nodeMap.Keys |
        Sort-Object { [int]$nodeMap[$_].wave_index }, { [string]$nodeMap[$_].qualified_name } |
        ForEach-Object {
            $node = $nodeMap[$_]
            [pscustomobject]@{
                wave_index = $node.wave_index
                proposed_stage = $node.proposed_stage
                qualified_name = $node.qualified_name
                workspace_name = $node.workspace_name
                item_name = $node.item_name
                item_type = $node.item_type
                orchestration_role = $node.orchestration_role
                action_type = $node.action_type
                is_master_action = $node.is_master_action
                estimated_start_seconds = $node.estimated_start_seconds
                estimated_duration_seconds = $node.estimated_duration_seconds
                estimated_finish_seconds = $node.estimated_finish_seconds
                duration_source = $node.duration_source
                topological_level = $node.topological_level
                predecessor_count = $node.predecessor_count
                successor_count = $node.successor_count
                incoming_likely_edges = $node.incoming_likely_edges
                outgoing_likely_edges = $node.outgoing_likely_edges
                deep_lineage_status = $node.deep_lineage_status
                object_coverage_status = $node.object_coverage_status
                object_review_status = $node.object_review_status
                object_reference_count = $node.object_reference_count
                exact_object_reference_count = $node.exact_object_reference_count
                ambiguous_object_reference_count = $node.ambiguous_object_reference_count
                confirmed_object_lineage_rows = $node.confirmed_object_lineage_rows
                likely_object_lineage_rows = $node.likely_object_lineage_rows
                read_object_count = $node.read_object_count
                write_object_count = $node.write_object_count
                execute_object_count = $node.execute_object_count
                unknown_object_count = $node.unknown_object_count
                object_lineage_next_action = Limit-Text -Text $node.object_lineage_next_action -MaxLength 700
                run_count = $node.run_count
                completed_count = $node.completed_count
                failed_count = $node.failed_count
                manual_count = $node.manual_count
                scheduled_count = $node.scheduled_count
                enabled_schedules = $node.enabled_schedules
                disabled_schedules = $node.disabled_schedules
                schedule_times = $node.schedule_times
                parallel_group = $node.parallel_group
                parallel_readiness = $node.parallel_readiness
                risk_flags = $node.risk_flags
                human_validation_required = $node.human_validation_required
                recommendation = Limit-Text -Text $node.recommendation -MaxLength 700
            }
        }
)

Ensure-ParentDirectory -Path $OutputPlanPath
$planRows | Export-Csv -Path $OutputPlanPath -NoTypeInformation -Encoding UTF8

Ensure-ParentDirectory -Path $OutputEdgesPath
$edgeRows | Export-Csv -Path $OutputEdgesPath -NoTypeInformation -Encoding UTF8

$waveRows = [System.Collections.Generic.List[object]]::new()
foreach ($wave in ($waveDurations.Keys | Sort-Object { [int]$_ })) {
    $members = @($planRows | Where-Object { [int]$_.wave_index -eq [int]$wave })
    $stageBreakdown = @(
        $members |
            Group-Object proposed_stage |
            Sort-Object Name |
            ForEach-Object { "$($_.Name)=$($_.Count)" }
    ) -join "; "
    $riskCount = @($members | Where-Object { $_.risk_flags }).Count
    $deepBlockedCount = @($members | Where-Object { $_.parallel_readiness -eq "blocked_pending_deep_object_lineage" }).Count
    $objectConfirmationCount = @($members | Where-Object { $_.parallel_readiness -eq "candidate_requires_object_lineage_confirmation" }).Count
    $writeReviewCount = @($members | Where-Object { $_.parallel_readiness -eq "candidate_requires_write_conflict_review" }).Count
    $masterCount = @($members | Where-Object { [string]$_.is_master_action -eq "True" }).Count
    $samples = @(
        $members |
            Sort-Object -Property estimated_duration_seconds -Descending |
            Select-Object -First 8 |
            ForEach-Object { $_.qualified_name }
    ) -join "; "

    $waveRows.Add([pscustomobject]@{
        wave_index = [int]$wave
        estimated_start_seconds = [math]::Round([double]$waveStarts[$wave], 3)
        estimated_parallel_duration_seconds = [math]::Round([double]$waveDurations[$wave], 3)
        estimated_finish_seconds = [math]::Round([double]$waveStarts[$wave] + [double]$waveDurations[$wave], 3)
        node_count = $members.Count
        master_action_count = $masterCount
        risk_flag_count = $riskCount
        deep_lineage_blocker_count = $deepBlockedCount
        object_lineage_confirmation_count = $objectConfirmationCount
        write_conflict_review_count = $writeReviewCount
        stage_breakdown = $stageBreakdown
        bottleneck_items = Limit-Text -Text $samples -MaxLength 1600
        recommendation = "Run nodes in this wave in parallel only after human dependency and read/write validation; the longest item controls the wave duration."
    }) | Out-Null
}

Ensure-ParentDirectory -Path $OutputWavesPath
$waveRows | Export-Csv -Path $OutputWavesPath -NoTypeInformation -Encoding UTF8

$confirmedEdges = @($edgeRows | Where-Object { $_.confidence -eq "confirmed" }).Count
$candidateEdges = @($edgeRows | Where-Object { $_.confidence -ne "confirmed" }).Count
$masterActions = @($planRows | Where-Object { [string]$_.is_master_action -eq "True" }).Count
$defaultedDurations = @($planRows | Where-Object { $_.duration_source -eq "default_by_role" }).Count
$holdNodes = @($planRows | Where-Object { $_.parallel_readiness -eq "hold_until_stabilized" }).Count
$candidateReadWriteNodes = @($planRows | Where-Object { $_.parallel_readiness -eq "candidate_requires_read_write_validation" }).Count
$deepLineageNodes = @($planRows | Where-Object { $_.deep_lineage_status }).Count
$deepLineageBlockedNodes = @($planRows | Where-Object { $_.parallel_readiness -eq "blocked_pending_deep_object_lineage" }).Count
$objectLineageConfirmationNodes = @($planRows | Where-Object { $_.parallel_readiness -eq "candidate_requires_object_lineage_confirmation" }).Count
$writeConflictReviewNodes = @($planRows | Where-Object { $_.parallel_readiness -eq "candidate_requires_write_conflict_review" }).Count
$writeTargetNodes = @($planRows | Where-Object { [int]$_.write_object_count -gt 0 }).Count
$phase12ExactReferenceRows = @($planRows | Measure-Object -Property exact_object_reference_count -Sum).Sum
$phase12AmbiguousReferenceRows = @($planRows | Measure-Object -Property ambiguous_object_reference_count -Sum).Sum
$phase12LikelyLineageRows = @($planRows | Measure-Object -Property likely_object_lineage_rows -Sum).Sum
$planRowCount = Get-CollectionCount -Value $planRows
$edgeRowCount = Get-CollectionCount -Value $edgeRows
$waveRowCount = Get-CollectionCount -Value $waveRows
$parallelRowCount = Get-CollectionCount -Value $parallelRows
$totalEstimated = if ($waveRowCount -gt 0) { [math]::Round(([double](@($waveRows | Sort-Object wave_index | Select-Object -Last 1).estimated_finish_seconds)), 3) } else { 0.0 }

$summaryRows = @(
    [pscustomobject]@{ metric = "plan_nodes"; value = $planRowCount; notes = "Rows in analysis/ideal_execution_plan.csv." },
    [pscustomobject]@{ metric = "master_actions"; value = $masterActions; notes = "Rows that could become master-pipeline checkpoints/actions after approval." },
    [pscustomobject]@{ metric = "plan_edges"; value = $edgeRowCount; notes = "Execution-oriented dependency edges." },
    [pscustomobject]@{ metric = "confirmed_edges"; value = $confirmedEdges; notes = "Edges backed by confirmed evidence." },
    [pscustomobject]@{ metric = "candidate_edges"; value = $candidateEdges; notes = "Likely/unknown edges requiring confirmation." },
    [pscustomobject]@{ metric = "waves"; value = $waveRowCount; notes = "Conservative stage-barrier waves." },
    [pscustomobject]@{ metric = "estimated_wall_clock_seconds"; value = $totalEstimated; notes = "Sum of max duration per wave; planning estimate, not an SLA." },
    [pscustomobject]@{ metric = "failure_hold_nodes"; value = $holdNodes; notes = "Nodes to stabilize before production optimization." },
    [pscustomobject]@{ metric = "read_write_validation_nodes"; value = $candidateReadWriteNodes; notes = "Mostly notebooks/pipelines/copy jobs needing code-level validation before parallelism." },
    [pscustomobject]@{ metric = "phase12_deep_lineage_nodes"; value = $deepLineageNodes; notes = "Plan nodes with Phase 12 deep object lineage metadata." },
    [pscustomobject]@{ metric = "phase12_deep_lineage_blocked_nodes"; value = $deepLineageBlockedNodes; notes = "Nodes blocked by missing source/object lineage or unknown object operation." },
    [pscustomobject]@{ metric = "phase12_object_lineage_confirmation_nodes"; value = $objectLineageConfirmationNodes; notes = "Nodes needing object type resolution or likely lineage confirmation." },
    [pscustomobject]@{ metric = "phase12_write_conflict_review_nodes"; value = $writeConflictReviewNodes; notes = "Nodes with write targets that require conflict review before parallelism." },
    [pscustomobject]@{ metric = "phase12_write_target_nodes"; value = $writeTargetNodes; notes = "Nodes where Phase 12 detected at least one write target, including nodes already blocked by stronger gates." },
    [pscustomobject]@{ metric = "phase12_exact_object_reference_rows"; value = $phase12ExactReferenceRows; notes = "Exact object reference rows carried into the execution plan." },
    [pscustomobject]@{ metric = "phase12_ambiguous_object_reference_rows"; value = $phase12AmbiguousReferenceRows; notes = "Ambiguous object reference rows carried into the execution plan." },
    [pscustomobject]@{ metric = "phase12_likely_object_lineage_rows"; value = $phase12LikelyLineageRows; notes = "Likely object lineage rows carried into the execution plan." },
    [pscustomobject]@{ metric = "defaulted_duration_nodes"; value = $defaultedDurations; notes = "Rows without observed duration; default duration used." },
    [pscustomobject]@{ metric = "parallel_candidate_pairs"; value = $parallelRowCount; notes = "Candidate pairs from Phase 7, not approvals." }
)

Ensure-ParentDirectory -Path $OutputSummaryPath
$summaryRows | Export-Csv -Path $OutputSummaryPath -NoTypeInformation -Encoding UTF8

$mermaidLines = [System.Collections.Generic.List[string]]::new()
$mermaidLines.Add("flowchart LR") | Out-Null
$mermaidLines.Add("  classDef source fill:#ecfdf5,stroke:#10b981,color:#064e3b;") | Out-Null
$mermaidLines.Add("  classDef process fill:#eff6ff,stroke:#2563eb,color:#1e3a8a;") | Out-Null
$mermaidLines.Add("  classDef semantic fill:#fefce8,stroke:#ca8a04,color:#713f12;") | Out-Null
$mermaidLines.Add("  classDef report fill:#fff1f2,stroke:#e11d48,color:#881337;") | Out-Null
$mermaidLines.Add("  classDef risk fill:#fef2f2,stroke:#dc2626,color:#7f1d1d;") | Out-Null
$mermaidLines.Add("") | Out-Null

$diagramWaves = @($waveRows | Sort-Object wave_index | Select-Object -First $DiagramWaveLimit)
foreach ($wave in $diagramWaves) {
    $id = "w$($wave.wave_index)"
    $label = "Wave $($wave.wave_index)<br/>$($wave.node_count) nodes / $($wave.master_action_count) actions<br/>~$([math]::Round([double]$wave.estimated_parallel_duration_seconds))s"
    $mermaidLines.Add("  $id[`"$label`"]") | Out-Null
    if ([int]$wave.risk_flag_count -gt 0) {
        $mermaidLines.Add("  class $id risk;") | Out-Null
    }
}

$diagramWaveCount = Get-CollectionCount -Value $diagramWaves
for ($i = 0; $i -lt $diagramWaveCount - 1; $i++) {
    $from = "w$($diagramWaves[$i].wave_index)"
    $to = "w$($diagramWaves[$i + 1].wave_index)"
    $mermaidLines.Add("  $from --> $to") | Out-Null
}

if ($waveRowCount -gt $DiagramWaveLimit) {
    $lastShown = "w$($diagramWaves[-1].wave_index)"
    $remaining = $waveRowCount - $DiagramWaveLimit
    $remainingLabel = "$remaining more waves in CSV"
    $mermaidLines.Add("  more[`"$remainingLabel`"]") | Out-Null
    $mermaidLines.Add("  $lastShown --> more") | Out-Null
}

$bottleneckRows = @(
    $planRows |
        Where-Object {
            $_.risk_flags -match "failure_hotspot|critical_path_candidate" -or
            $_.risk_flags -match "phase12_source_missing|phase12_object_missing|phase12_unknown_object_operation|phase12_object_type_resolution_required|phase12_likely_object_lineage" -or
            ($_.risk_flags -match "wave_bottleneck" -and $_.duration_source -ne "default_by_role" -and [double]$_.estimated_duration_seconds -gt 0)
        } |
        Sort-Object `
            @{ Expression = { if ($_.risk_flags -match "failure_hotspot") { 4 } elseif ($_.risk_flags -match "phase12_source_missing|phase12_object_missing|phase12_unknown_object_operation") { 3 } elseif ($_.risk_flags -match "critical_path_candidate") { 2 } elseif ($_.risk_flags -match "phase12_object_type_resolution_required|phase12_likely_object_lineage|wave_bottleneck") { 1 } else { 0 } }; Descending = $true },
            @{ Expression = { [double]$_.estimated_duration_seconds }; Descending = $true } |
        Select-Object -First $TopBottleneckLimit
)

if ((Get-CollectionCount -Value $bottleneckRows) -gt 0) {
    $mermaidLines.Add("") | Out-Null
    $mermaidLines.Add("  subgraph Bottlenecks[Top bottlenecks and holds]") | Out-Null
    foreach ($row in $bottleneckRows) {
        $id = Get-MermaidId -Text $row.qualified_name
        $label = Escape-MermaidLabel -Text (Limit-Text -Text "$($row.item_type): $($row.item_name)<br/>Wave $($row.wave_index) / ~$([math]::Round([double]$row.estimated_duration_seconds))s" -MaxLength 120)
        $mermaidLines.Add("    $id[`"$label`"]") | Out-Null
        if ($row.risk_flags -match "failure_hotspot") {
            $mermaidLines.Add("    class $id risk;") | Out-Null
        }
        elseif ($row.orchestration_role -eq "semantic_refresh") {
            $mermaidLines.Add("    class $id semantic;") | Out-Null
        }
        elseif ($row.orchestration_role -eq "consumption_validation") {
            $mermaidLines.Add("    class $id report;") | Out-Null
        }
        else {
            $mermaidLines.Add("    class $id process;") | Out-Null
        }
    }
    $mermaidLines.Add("  end") | Out-Null
}

Ensure-ParentDirectory -Path $MermaidPath
$mermaidLines | Set-Content -Path $MermaidPath -Encoding UTF8

$topBottleneckText = @(
    $planRows |
        Where-Object {
            $_.risk_flags -match "failure_hotspot|critical_path_candidate" -or
            $_.risk_flags -match "phase12_source_missing|phase12_object_missing|phase12_unknown_object_operation|phase12_object_type_resolution_required|phase12_likely_object_lineage" -or
            ($_.risk_flags -match "wave_bottleneck" -and $_.duration_source -ne "default_by_role" -and [double]$_.estimated_duration_seconds -gt 0)
        } |
        Sort-Object `
            @{ Expression = { if ($_.risk_flags -match "failure_hotspot") { 4 } elseif ($_.risk_flags -match "phase12_source_missing|phase12_object_missing|phase12_unknown_object_operation") { 3 } elseif ($_.risk_flags -match "critical_path_candidate") { 2 } elseif ($_.risk_flags -match "phase12_object_type_resolution_required|phase12_likely_object_lineage|wave_bottleneck") { 1 } else { 0 } }; Descending = $true },
            @{ Expression = { [double]$_.estimated_duration_seconds }; Descending = $true } |
        Select-Object -First $TopBottleneckLimit |
        ForEach-Object {
            "- Wave $($_.wave_index): ``$($_.qualified_name)`` ($($_.item_type), ~$([math]::Round([double]$_.estimated_duration_seconds))s, flags: $($_.risk_flags))"
        }
) -join "`n"
if (-not $topBottleneckText) { $topBottleneckText = "- No bottleneck rows were identified." }

$doc = @"
# Ideal Execution Pipeline Design

Generated from local indexed evidence. No external Fabric changes were made.

## Purpose

This document turns the visual 'Planificacion' proposal into a repeatable local optimization algorithm. It is still a proposal for human review, not an automatic production schedule.

## Algorithm

1. Convert dependency edges into execution direction:
   - 'depends_on': upstream source or item must be ready before the dependent item.
   - 'uses_model' and 'serves_report': semantic model refresh/availability comes before report validation.
   - 'executes': existing orchestrator is kept as an orchestration parent and child activities are marked as covered by that orchestrator.
2. Classify nodes into conservative stages:
   - Stage 0: source readiness.
   - Stage 1: executable data processes such as pipelines, CopyJobs, notebooks, dataflows, and functions.
   - Stage 2: semantic model refresh.
   - Stage 3: report and consumption validation.
   - Stage 4: governance review for unsupported or non-operational items.
3. Build same-stage topological waves from confirmed and likely local dependency evidence.
4. Apply a conservative stage barrier so semantic refreshes are proposed after executable process waves and report validation is proposed after semantic refreshes.
5. Estimate each wave by the longest item duration in that wave. Observed average duration is used first, observed max is fallback, and role defaults are used only when no timing evidence exists.
6. Mark risk flags from Phase 7: critical path, failure hotspots, manual candidates, schedule review, fan-out groups, likely dependencies, and read/write validation needs.
7. Apply Phase 12 deep object lineage gates so missing source/object evidence, unknown object operations, ambiguous object types, likely object lineage, and write targets remain human-review blockers before parallel execution.

## Summary

- Plan nodes: $planRowCount
- Master action candidates: $masterActions
- Execution-oriented edges: $edgeRowCount
- Confirmed edges: $confirmedEdges
- Likely/unknown edges: $candidateEdges
- Waves: $waveRowCount
- Estimated wall-clock seconds: $totalEstimated
- Failure hold nodes: $holdNodes
- Read/write validation nodes: $candidateReadWriteNodes
- Phase 12 deep lineage nodes: $deepLineageNodes
- Phase 12 deep lineage blocked nodes: $deepLineageBlockedNodes
- Phase 12 object lineage confirmation nodes: $objectLineageConfirmationNodes
- Phase 12 write conflict review nodes: $writeConflictReviewNodes
- Phase 12 write target nodes: $writeTargetNodes
- Phase 12 exact object reference rows: $phase12ExactReferenceRows
- Phase 12 ambiguous object reference rows: $phase12AmbiguousReferenceRows
- Phase 12 likely object lineage rows: $phase12LikelyLineageRows
- Nodes with defaulted duration: $defaultedDurations
- Phase 7 parallel candidate pairs: $parallelRowCount

## Outputs

- 'analysis/ideal_execution_plan.csv'
- 'analysis/ideal_execution_edges.csv'
- 'analysis/ideal_execution_waves.csv'
- 'analysis/ideal_execution_summary.csv'
- 'diagrams/ideal_execution_pipeline.mmd'
- 'docs/13_ideal_execution_pipeline_design.md'

## Top Bottlenecks And Holds

$topBottleneckText

## Operating Rule

Use this plan as the candidate build order for a future master Fabric orchestration pipeline. Before implementation, a human must confirm:

1. Whether each 'is_master_action=True' row should be represented as a master pipeline activity or only a readiness/validation checkpoint.
2. Whether child items marked 'covered_by_existing_orchestrator' should stay inside the existing pipeline or be refactored into explicit master branches.
3. Whether notebook, CopyJob, and pipeline branches write to shared tables/files.
4. Whether failure hotspots have been stabilized.
5. Whether likely dependencies are accepted by the workspace owner.
6. Whether Phase 12 object lineage gaps are resolved or explicitly accepted for a scoped pilot.

## Human Approval Boundary

The final operational action remains human approval and manual execution in Fabric. This script does not create, update, delete, schedule, deploy, or trigger Fabric items.
"@

Ensure-ParentDirectory -Path $DocumentationPath
$doc | Set-Content -Path $DocumentationPath -Encoding UTF8

Write-Host "Ideal execution plan built."
Write-Host "Plan rows: $planRowCount"
Write-Host "Edges: $edgeRowCount"
Write-Host "Waves: $waveRowCount"
Write-Host "Output: $OutputPlanPath"
