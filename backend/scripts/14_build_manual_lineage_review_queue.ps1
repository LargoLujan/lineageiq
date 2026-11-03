# Phase 14 - Manual lineage review queue: surfaces the items/edges with
# the weakest evidence (no confirmed dependency, no definition-based
# candidate, failure hotspots) as a prioritized queue for a human to
# manually confirm or correct. Purely local, no API calls.
# Writes: $OutputQueuePath, $OutputSummaryPath.
param(
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$DependenciesPath = (Join-Path $PSScriptRoot "../../index/dependencies.csv"),
    [string]$ViewCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_view_candidates.csv"),
    [string]$ItemObjectLineageCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/item_object_lineage_candidates.csv"),
    [string]$PipelineObjectLineageCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/pipeline_object_lineage_candidates.csv"),
    [string]$ManualObjectEvidencePath = (Join-Path $PSScriptRoot "../../index/manual_lineage_object_evidence.csv"),
    [string]$DurationByItemPath = (Join-Path $PSScriptRoot "../../analysis/execution_duration_by_item.csv"),
    [string]$CriticalPathPath = (Join-Path $PSScriptRoot "../../analysis/critical_path_candidates.csv"),
    [string]$FailureHotspotsPath = (Join-Path $PSScriptRoot "../../analysis/failure_hotspots.csv"),
    [string]$OutputQueuePath = (Join-Path $PSScriptRoot "../../analysis/manual_lineage_review_queue.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/manual_lineage_review_summary.csv")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

function Get-FieldValue {
    param(
        [object]$Object,
        [string[]]$Names
    )

    if ($null -eq $Object) { return "" }
    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            $value = $Object.$name
            if ($null -ne $value) { return [string]$value }
        }
    }
    return ""
}

function Convert-ToDouble {
    param([object]$Value)
    if ($null -eq $Value -or [string]$Value -eq "") { return 0.0 }
    # [double]$Value (a bare cast) parses via invariant culture, which
    # treats "," as a thousands separator -- same comma-decimal bug found
    # and fixed in 07/13/24's identical functions. TryParse's 2-arg
    # overload uses CurrentCulture instead, matching how these strings
    # (from analysis/execution_duration_by_item.csv) were written.
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return 0.0
}

function Convert-ToInt {
    param([object]$Value)
    if ($null -eq $Value -or [string]$Value -eq "") { return 0 }
    try { return [int][double]$Value } catch { return 0 }
}

foreach ($path in @($ItemsPath, $DependenciesPath)) {
    if (-not (Test-Path $path)) { throw "Required input not found: $path" }
}

$items = @(Import-Csv -Path $ItemsPath | Where-Object { $_.status -eq "discovered" })
$dependencies = @(Import-Csv -Path $DependenciesPath)
$viewCandidates = if (Test-Path $ViewCandidatesPath) { @(Import-Csv -Path $ViewCandidatesPath | Where-Object { $_.object_name }) } else { @() }
$itemObjectCandidates = if (Test-Path $ItemObjectLineageCandidatesPath) { @(Import-Csv -Path $ItemObjectLineageCandidatesPath | Where-Object { $_.item_qualified_name -and $_.object_name }) } else { @() }
$pipelineObjectCandidates = if (Test-Path $PipelineObjectLineageCandidatesPath) { @(Import-Csv -Path $PipelineObjectLineageCandidatesPath | Where-Object { $_.item_qualified_name -and $_.object_name }) } else { @() }
$itemObjectCandidates = @($itemObjectCandidates + $pipelineObjectCandidates)
$manualRows = if (Test-Path $ManualObjectEvidencePath) { @(Import-Csv -Path $ManualObjectEvidencePath | Where-Object { $_.item_qualified_name -and $_.object_name }) } else { @() }
$durationRows = if (Test-Path $DurationByItemPath) { @(Import-Csv -Path $DurationByItemPath) } else { @() }
$criticalRows = if (Test-Path $CriticalPathPath) { @(Import-Csv -Path $CriticalPathPath) } else { @() }
$failureRows = if (Test-Path $FailureHotspotsPath) { @(Import-Csv -Path $FailureHotspotsPath) } else { @() }

$sourceDepsByItem = @{}
foreach ($dep in ($dependencies | Where-Object { $_.relationship_type -eq "depends_on" })) {
    if (-not $sourceDepsByItem.ContainsKey($dep.from_qualified_name)) {
        $sourceDepsByItem[$dep.from_qualified_name] = [System.Collections.Generic.List[object]]::new()
    }
    $sourceDepsByItem[$dep.from_qualified_name].Add($dep) | Out-Null
}

$autoObjectCountByItem = @{}
foreach ($row in $viewCandidates) {
    $itemName = Get-FieldValue -Object $row -Names @("semantic_model_qualified_name")
    if (-not $itemName) { continue }
    if (-not $autoObjectCountByItem.ContainsKey($itemName)) { $autoObjectCountByItem[$itemName] = 0 }
    $autoObjectCountByItem[$itemName] += 1
}
foreach ($row in $itemObjectCandidates) {
    $itemName = Get-FieldValue -Object $row -Names @("item_qualified_name")
    if (-not $itemName) { continue }
    if (-not $autoObjectCountByItem.ContainsKey($itemName)) { $autoObjectCountByItem[$itemName] = 0 }
    $autoObjectCountByItem[$itemName] += 1
}

$manualObjectCountByItem = @{}
foreach ($row in $manualRows) {
    $itemName = Get-FieldValue -Object $row -Names @("item_qualified_name")
    if (-not $itemName) { continue }
    if (-not $manualObjectCountByItem.ContainsKey($itemName)) { $manualObjectCountByItem[$itemName] = 0 }
    $manualObjectCountByItem[$itemName] += 1
}

$durationByItem = @{}
foreach ($row in $durationRows) {
    $name = Get-FieldValue -Object $row -Names @("qualified_name")
    if ($name -and -not $durationByItem.ContainsKey($name)) { $durationByItem[$name] = $row }
}

$criticalByItem = @{}
foreach ($row in $criticalRows) {
    $name = Get-FieldValue -Object $row -Names @("qualified_name")
    if ($name) { $criticalByItem[$name] = $true }
}

$failureByItem = @{}
foreach ($row in $failureRows) {
    $name = Get-FieldValue -Object $row -Names @("qualified_name")
    if ($name) { $failureByItem[$name] = $true }
}

$targetTypes = @("SemanticModel", "Notebook", "CopyJob", "DataPipeline")
$queueRows = [System.Collections.Generic.List[object]]::new()

foreach ($item in ($items | Where-Object { $_.item_type -in $targetTypes } | Sort-Object workspace_name, item_type, item_name)) {
    $qualifiedName = $item.qualified_name
    $sourceDeps = @(if ($sourceDepsByItem.ContainsKey($qualifiedName)) { $sourceDepsByItem[$qualifiedName].ToArray() })
    $sourceCount = @($sourceDeps).Count
    $autoObjectCount = if ($autoObjectCountByItem.ContainsKey($qualifiedName)) { $autoObjectCountByItem[$qualifiedName] } else { 0 }
    $manualObjectCount = if ($manualObjectCountByItem.ContainsKey($qualifiedName)) { $manualObjectCountByItem[$qualifiedName] } else { 0 }
    $totalObjectCount = $autoObjectCount + $manualObjectCount
    $duration = if ($durationByItem.ContainsKey($qualifiedName)) { $durationByItem[$qualifiedName] } else { $null }
    $avgDuration = if ($duration) { Convert-ToDouble (Get-FieldValue -Object $duration -Names @("avg_duration_seconds")) } else { 0.0 }
    $maxDuration = if ($duration) { Convert-ToDouble (Get-FieldValue -Object $duration -Names @("max_duration_seconds")) } else { 0.0 }
    $failedCount = if ($duration) { Convert-ToInt (Get-FieldValue -Object $duration -Names @("failed_count")) } else { 0 }

    $reviewStatus = if ($manualObjectCount -gt 0) {
        "manual_object_evidence_present"
    }
    elseif ($autoObjectCount -gt 0) {
        "auto_object_evidence_present"
    }
    elseif ($sourceCount -gt 0) {
        "source_known_object_missing"
    }
    else {
        "source_missing_manual_review_required"
    }

    $priorityScore = 0
    switch ($item.item_type) {
        "Notebook" { $priorityScore += 50 }
        "DataPipeline" { $priorityScore += 50 }
        "CopyJob" { $priorityScore += 45 }
        "SemanticModel" { $priorityScore += 35 }
    }
    if ($sourceCount -eq 0) { $priorityScore += 40 }
    elseif ($totalObjectCount -eq 0) { $priorityScore += 30 }
    if ($criticalByItem.ContainsKey($qualifiedName)) { $priorityScore += 20 }
    if ($failureByItem.ContainsKey($qualifiedName)) { $priorityScore += 20 }
    if ($item.workspace_environment -eq "PRO") { $priorityScore += 10 }
    if ($maxDuration -ge 1800) { $priorityScore += 10 }
    if ($totalObjectCount -gt 0) { $priorityScore -= 20 }

    $priority = if ($priorityScore -ge 90) { "high" } elseif ($priorityScore -ge 60) { "medium" } else { "low" }
    $sourceList = @(
        $sourceDeps |
            ForEach-Object { $_.to_qualified_name } |
            Sort-Object -Unique
    ) -join "; "

    $reviewAction = switch ($item.item_type) {
        "SemanticModel" { "Open semantic model definition/Power Query/TMDL and record each SQL/Fabric table, view, or stored procedure used." }
        "Notebook" { "Open notebook, inspect default lakehouse and code cells for spark/sql/jdbc/odbc/table references, then record every table, view, or stored procedure used." }
        "CopyJob" { "Open CopyJob source/destination settings and mappings, then record source and target tables/views/files where available." }
        "DataPipeline" { "Open DataPipeline activities, inspect invoked items and copy/source/sink settings, then record each direct or inherited table, view, file, or stored procedure." }
        default { "Review item manually and record object-level lineage evidence." }
    }

    $queueRows.Add([pscustomobject]@{
        priority = $priority
        priority_score = $priorityScore
        review_status = $reviewStatus
        workspace_name = $item.workspace_name
        workspace_environment = $item.workspace_environment
        item_type = $item.item_type
        item_name = $item.item_name
        item_qualified_name = $qualifiedName
        source_dependency_count = $sourceCount
        source_dependencies = $sourceList
        auto_object_evidence_count = $autoObjectCount
        manual_object_evidence_count = $manualObjectCount
        total_object_evidence_count = $totalObjectCount
        avg_duration_seconds = $avgDuration
        max_duration_seconds = $maxDuration
        failed_count = $failedCount
        is_critical_path_candidate = [bool]$criticalByItem.ContainsKey($qualifiedName)
        is_failure_hotspot = [bool]$failureByItem.ContainsKey($qualifiedName)
        manual_template_path = $ManualObjectEvidencePath
        review_action = $reviewAction
    }) | Out-Null
}

$queueRows = @(
    $queueRows |
        Sort-Object `
            @{ Expression = { if ($_.priority -eq "high") { 3 } elseif ($_.priority -eq "medium") { 2 } else { 1 } }; Descending = $true },
            @{ Expression = { [int]$_.priority_score }; Descending = $true },
            workspace_name,
            item_type,
            item_name
)

Ensure-ParentDirectory -Path $OutputQueuePath
$queueRows | Export-Csv -Path $OutputQueuePath -NoTypeInformation -Encoding UTF8

$summaryRows = @(
    $queueRows |
        Group-Object item_type, review_status, priority |
        Sort-Object Name |
        ForEach-Object {
            $parts = $_.Name -split ", "
            [pscustomobject]@{
                item_type = if ($parts.Count -ge 1) { $parts[0] } else { "" }
                review_status = if ($parts.Count -ge 2) { $parts[1] } else { "" }
                priority = if ($parts.Count -ge 3) { $parts[2] } else { "" }
                item_count = $_.Count
            }
        }
)

Ensure-ParentDirectory -Path $OutputSummaryPath
$summaryRows | Export-Csv -Path $OutputSummaryPath -NoTypeInformation -Encoding UTF8

Write-Host "Manual lineage review queue built."
Write-Host "Items queued: $($queueRows.Count)"
Write-Host "Output: $OutputQueuePath"
