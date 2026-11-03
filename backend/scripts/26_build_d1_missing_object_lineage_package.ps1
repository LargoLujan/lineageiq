# Phase 26 - D1 package: the first of Phase 25's cleanup-plan categories --
# items with genuinely missing object-level lineage (no candidate at all,
# not just an unconfirmed one). Packages them into a queue plus a manual
# evidence template a human can fill in and feed back via
# index/manual_lineage_object_evidence.csv. Purely local.
# Writes: $OutputQueuePath, $OutputSummaryPath, $OutputTemplatePath,
# $OutputReadonlyTargetsPath, $OutputDocPath.
param(
    [string]$CleanupQueuePath = (Join-Path $PSScriptRoot "../../analysis/likely_conflict_cleanup_queue.csv"),
    [string]$CoveragePath = (Join-Path $PSScriptRoot "../../analysis/object_level_lineage_coverage.csv"),
    [string]$ManualReviewQueuePath = (Join-Path $PSScriptRoot "../../analysis/manual_lineage_review_queue.csv"),
    [string]$ItemDefinitionGapsPath = (Join-Path $PSScriptRoot "../../analysis/item_object_lineage_gaps.csv"),
    [string]$PipelineDefinitionGapsPath = (Join-Path $PSScriptRoot "../../analysis/pipeline_object_lineage_gaps.csv"),
    [string]$SemanticDefinitionGapsPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_definition_gaps.csv"),
    [string]$SemanticCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_view_candidates.csv"),
    [string]$OrchestrationV2PlanPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_plan.csv"),
    [string]$OrchestrationV2ParallelPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_parallel_candidates.csv"),
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$OutputQueuePath = (Join-Path $PSScriptRoot "../../analysis/d1_missing_object_lineage_queue.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d1_missing_object_lineage_summary.csv"),
    [string]$OutputTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d1_manual_lineage_evidence_template.csv"),
    [string]$OutputReadonlyTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d1_readonly_target_items.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/23_d1_missing_object_lineage.md")
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
    param(
        [hashtable]$Map,
        [string]$Key
    )
    $normalized = Normalize-Key -Value $Key
    if ($normalized -and $Map.ContainsKey($normalized)) {
        return $Map[$normalized]
    }
    return $null
}

function Get-PriorityBand {
    param([int]$PriorityScore)
    if ($PriorityScore -ge 130) { return "critical" }
    if ($PriorityScore -ge 100) { return "high" }
    if ($PriorityScore -ge 70) { return "medium" }
    return "low"
}

function Get-RecommendedMethod {
    param([string]$ItemType)
    switch ($ItemType) {
        "Notebook" { return "Inspect notebook code/default lakehouse, then record exact read/write/execute objects." }
        "CopyJob" { return "Inspect CopyJob source and sink mappings, then record exact source and destination objects." }
        "DataPipeline" { return "Inspect pipeline activities, invoked items, copy source/sink mappings, and inherited lineage." }
        "SemanticModel" { return "Inspect TMDL, Power Query/M expressions, model partitions, or owner-approved source mapping." }
        default { return "Inspect item definition/code and record exact object-level evidence." }
    }
}

function Get-RecommendedScript {
    param([string]$ItemType)
    switch ($ItemType) {
        "Notebook" { return "backend/scripts/18_extract_item_object_lineage.ps1" }
        "CopyJob" { return "backend/scripts/18_extract_item_object_lineage.ps1" }
        "DataPipeline" { return "backend/scripts/19_extract_pipeline_object_lineage.ps1" }
        "SemanticModel" { return "backend/scripts/09_enrich_semantic_model_views.ps1" }
        default { return "" }
    }
}

function Get-RecommendedCommand {
    param([string]$ItemType)
    switch ($ItemType) {
        "Notebook" { return "pwsh -NoLogo -File backend/scripts/18_extract_item_object_lineage.ps1 -AzCommand az" }
        "CopyJob" { return "pwsh -NoLogo -File backend/scripts/18_extract_item_object_lineage.ps1 -AzCommand az" }
        "DataPipeline" { return "pwsh -NoLogo -File backend/scripts/19_extract_pipeline_object_lineage.ps1 -AzCommand az" }
        "SemanticModel" { return "pwsh -NoLogo -File backend/scripts/09_enrich_semantic_model_views.ps1 -AzCommand az -MaxModels 120" }
        default { return "" }
    }
}

function Get-DefinitionStatus {
    param(
        [string]$ItemType,
        [object]$ItemGap,
        [object]$PipelineGap,
        [object]$SemanticGap,
        [int]$SemanticCandidateCount
    )

    if ($ItemType -eq "Notebook" -or $ItemType -eq "CopyJob") {
        if ($null -eq $ItemGap) { return "not_in_item_definition_gap_file" }
        $statusCode = Get-FieldValue -Object $ItemGap -Names @("status_code")
        $definitionParts = Convert-ToInt (Get-FieldValue -Object $ItemGap -Names @("definition_parts"))
        $candidateCount = Convert-ToInt (Get-FieldValue -Object $ItemGap -Names @("candidate_count"))
        $error = Get-FieldValue -Object $ItemGap -Names @("error")
        if ($statusCode -eq "200" -and $definitionParts -gt 0 -and $candidateCount -eq 0) { return "decoded_no_object_candidates" }
        if ($statusCode -eq "200" -and $definitionParts -eq 0) { return "definition_decoded_empty" }
        if ($error) { return "definition_read_error" }
        return "definition_review_required"
    }

    if ($ItemType -eq "DataPipeline") {
        if ($null -eq $PipelineGap) { return "not_in_pipeline_gap_file" }
        $statusCode = Get-FieldValue -Object $PipelineGap -Names @("status_code")
        $definitionParts = Convert-ToInt (Get-FieldValue -Object $PipelineGap -Names @("definition_parts"))
        $activityCount = Convert-ToInt (Get-FieldValue -Object $PipelineGap -Names @("activity_count"))
        $candidateCount = Convert-ToInt (Get-FieldValue -Object $PipelineGap -Names @("candidate_count"))
        $error = Get-FieldValue -Object $PipelineGap -Names @("error")
        if ($statusCode -eq "200" -and $definitionParts -gt 0 -and $activityCount -gt 0 -and $candidateCount -eq 0) { return "decoded_activities_no_object_candidates" }
        if ($statusCode -eq "200" -and $definitionParts -eq 0) { return "definition_decoded_empty" }
        if ($error) { return "definition_read_error" }
        return "pipeline_definition_review_required"
    }

    if ($ItemType -eq "SemanticModel") {
        if ($SemanticCandidateCount -gt 0) { return "semantic_candidates_exist_but_item_still_blocked" }
        if ($null -ne $SemanticGap) {
            $error = Get-FieldValue -Object $SemanticGap -Names @("error")
            if ($error) { return "semantic_definition_unavailable" }
            return "semantic_definition_gap_recorded"
        }
        return "needs_tmdl_or_model_expression_review"
    }

    return "manual_definition_review_required"
}

function Split-SourceDependencies {
    param([string]$SourceDependencies)
    $sources = [System.Collections.Generic.List[object]]::new()
    if (-not $SourceDependencies) { return @($sources) }

    foreach ($rawDependency in ($SourceDependencies -split "\s*;\s*")) {
        $dependency = $rawDependency.Trim()
        if (-not $dependency) { continue }
        $parts = @($dependency -split "\s*/\s*")
        $sourceType = ""
        $sourceName = ""
        if ($parts.Count -ge 3) {
            if ($parts[0] -eq "External Connection") {
                $sourceType = $parts[0]
                $sourceName = $parts[$parts.Count - 1]
            }
            else {
                $sourceType = $parts[1]
                $sourceName = $parts[$parts.Count - 1]
            }
        }
        elseif ($parts.Count -eq 2) {
            $sourceType = $parts[0]
            $sourceName = $parts[1]
        }
        else {
            $sourceName = $dependency
        }

        $sources.Add([pscustomobject]@{
            source_type = $sourceType
            source_name = $sourceName
            source_qualified_name = $dependency
        }) | Out-Null
    }

    return @($sources)
}

function Escape-MdCell {
    param([string]$Value)
    if (-not $Value) { return "" }
    return (($Value -replace "\|", "/") -replace "`r?`n", " ").Trim()
}

foreach ($path in @($CleanupQueuePath, $CoveragePath, $ManualReviewQueuePath, $ItemsPath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$cleanupRows = @(Import-Csv -Path $CleanupQueuePath)
$coverageRows = @(Import-Csv -Path $CoveragePath)
$manualRows = @(Import-Csv -Path $ManualReviewQueuePath)
$itemRows = @(Import-Csv -Path $ItemsPath)
$itemGapRows = Import-OptionalCsv -Path $ItemDefinitionGapsPath
$pipelineGapRows = Import-OptionalCsv -Path $PipelineDefinitionGapsPath
$semanticGapRows = Import-OptionalCsv -Path $SemanticDefinitionGapsPath
$semanticCandidateRows = Import-OptionalCsv -Path $SemanticCandidatesPath
$v2PlanRows = Import-OptionalCsv -Path $OrchestrationV2PlanPath
$parallelRows = Import-OptionalCsv -Path $OrchestrationV2ParallelPath

$coverageByItem = @{}
foreach ($row in $coverageRows) { Set-FirstMapValue -Map $coverageByItem -Key (Get-FieldValue -Object $row -Names @("item_qualified_name")) -Value $row }

$manualByItem = @{}
foreach ($row in $manualRows) { Set-FirstMapValue -Map $manualByItem -Key (Get-FieldValue -Object $row -Names @("item_qualified_name")) -Value $row }

$itemByQualifiedName = @{}
foreach ($row in $itemRows) { Set-FirstMapValue -Map $itemByQualifiedName -Key (Get-FieldValue -Object $row -Names @("qualified_name", "item_qualified_name")) -Value $row }

$itemGapByItem = @{}
foreach ($row in $itemGapRows) { Set-FirstMapValue -Map $itemGapByItem -Key (Get-FieldValue -Object $row -Names @("item_qualified_name")) -Value $row }

$pipelineGapByItem = @{}
foreach ($row in $pipelineGapRows) { Set-FirstMapValue -Map $pipelineGapByItem -Key (Get-FieldValue -Object $row -Names @("item_qualified_name")) -Value $row }

$semanticGapByItem = @{}
foreach ($row in $semanticGapRows) { Set-FirstMapValue -Map $semanticGapByItem -Key (Get-FieldValue -Object $row -Names @("semantic_model_qualified_name", "item_qualified_name")) -Value $row }

$semanticCandidateCountByItem = @{}
foreach ($group in ($semanticCandidateRows | Group-Object semantic_model_qualified_name)) {
    $semanticCandidateCountByItem[(Normalize-Key -Value $group.Name)] = $group.Count
}

$v2ByItem = @{}
foreach ($row in $v2PlanRows) { Set-FirstMapValue -Map $v2ByItem -Key (Get-FieldValue -Object $row -Names @("qualified_name", "item_qualified_name")) -Value $row }

$parallelBlockerCountByItem = @{}
foreach ($row in ($parallelRows | Where-Object { $_.candidate_status -eq "blocked_missing_object_evidence" })) {
    foreach ($candidate in @((Get-FieldValue -Object $row -Names @("candidate_a")), (Get-FieldValue -Object $row -Names @("candidate_b")))) {
        $key = Normalize-Key -Value $candidate
        if (-not $key) { continue }
        if (-not $parallelBlockerCountByItem.ContainsKey($key)) { $parallelBlockerCountByItem[$key] = 0 }
        $parallelBlockerCountByItem[$key] = [int]$parallelBlockerCountByItem[$key] + 1
    }
}

$d1Rows = @($cleanupRows | Where-Object { $_.phase_id -eq "D1" -or $_.blocker_type -eq "missing_object_level_lineage" })
$queueRows = [System.Collections.Generic.List[object]]::new()
$templateRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()

foreach ($row in $d1Rows) {
    $qualifiedName = Get-FieldValue -Object $row -Names @("item_qualified_name", "qualified_name")
    $workspaceName = Get-FieldValue -Object $row -Names @("workspace_name")
    $itemType = Get-FieldValue -Object $row -Names @("item_type")
    $itemName = Get-FieldValue -Object $row -Names @("item_name")
    $priorityScore = Convert-ToInt (Get-FieldValue -Object $row -Names @("priority_score"))

    $coverage = Get-MapValue -Map $coverageByItem -Key $qualifiedName
    $manual = Get-MapValue -Map $manualByItem -Key $qualifiedName
    $item = Get-MapValue -Map $itemByQualifiedName -Key $qualifiedName
    $itemGap = Get-MapValue -Map $itemGapByItem -Key $qualifiedName
    $pipelineGap = Get-MapValue -Map $pipelineGapByItem -Key $qualifiedName
    $semanticGap = Get-MapValue -Map $semanticGapByItem -Key $qualifiedName
    $v2 = Get-MapValue -Map $v2ByItem -Key $qualifiedName

    $semanticCandidateKey = Normalize-Key -Value $qualifiedName
    $semanticCandidateCount = 0
    if ($semanticCandidateKey -and $semanticCandidateCountByItem.ContainsKey($semanticCandidateKey)) {
        $semanticCandidateCount = [int]$semanticCandidateCountByItem[$semanticCandidateKey]
    }

    $parallelKey = Normalize-Key -Value $qualifiedName
    $parallelBlockerCount = 0
    if ($parallelKey -and $parallelBlockerCountByItem.ContainsKey($parallelKey)) {
        $parallelBlockerCount = [int]$parallelBlockerCountByItem[$parallelKey]
    }

    $workspaceEnvironment = Get-FieldValue -Object $manual -Names @("workspace_environment")
    if (-not $workspaceEnvironment) { $workspaceEnvironment = Get-FieldValue -Object $coverage -Names @("workspace_environment") }
    if (-not $workspaceEnvironment) { $workspaceEnvironment = Get-FieldValue -Object $item -Names @("workspace_environment") }

    $definitionStatus = Get-DefinitionStatus -ItemType $itemType -ItemGap $itemGap -PipelineGap $pipelineGap -SemanticGap $semanticGap -SemanticCandidateCount $semanticCandidateCount
    $recommendedMethod = Get-RecommendedMethod -ItemType $itemType
    $recommendedScript = Get-RecommendedScript -ItemType $itemType
    $recommendedCommand = Get-RecommendedCommand -ItemType $itemType
    $sourceDependencies = Get-FieldValue -Object $manual -Names @("source_dependencies")
    $sourceDependencyCount = Convert-ToInt (Get-FieldValue -Object $manual -Names @("source_dependency_count"))
    $templateSources = @(Split-SourceDependencies -SourceDependencies $sourceDependencies)
    if ($templateSources.Count -eq 0) {
        $templateSources = @([pscustomobject]@{
            source_type = ""
            source_name = ""
            source_qualified_name = ""
        })
    }

    $readonlyGoal = "Read definitions/metadata only, then confirm exact source objects in the manual evidence template."
    if ($definitionStatus -like "decoded*no_object_candidates") {
        $readonlyGoal = "Definition was already decoded but parser found no objects; inspect code/activities or owner evidence and improve parser if pattern repeats."
    }
    elseif ($definitionStatus -like "*unavailable*") {
        $readonlyGoal = "Definition access is unavailable; use Azure DevOps, SharePoint, OneLake, or owner-approved evidence."
    }

    $definitionStatusCode = ""
    $definitionParts = 0
    $definitionActivityCount = 0
    $definitionCandidateCount = 0
    $definitionErrorText = ""
    $definitionNotesText = ""

    if ($itemType -eq "DataPipeline") {
        $definitionStatusCode = Get-FieldValue -Object $pipelineGap -Names @("status_code")
        $definitionParts = Convert-ToInt (Get-FieldValue -Object $pipelineGap -Names @("definition_parts"))
        $definitionActivityCount = Convert-ToInt (Get-FieldValue -Object $pipelineGap -Names @("activity_count"))
        $definitionCandidateCount = Convert-ToInt (Get-FieldValue -Object $pipelineGap -Names @("candidate_count"))
        $definitionErrorText = Get-FieldValue -Object $pipelineGap -Names @("error")
        $definitionNotesText = Get-FieldValue -Object $pipelineGap -Names @("notes")
    }
    elseif ($itemType -eq "SemanticModel") {
        $definitionStatusCode = Get-FieldValue -Object $semanticGap -Names @("status_code")
        $definitionCandidateCount = $semanticCandidateCount
        $definitionErrorText = Get-FieldValue -Object $semanticGap -Names @("error")
        $definitionNotesText = Get-FieldValue -Object $semanticGap -Names @("notes")
    }
    else {
        $definitionStatusCode = Get-FieldValue -Object $itemGap -Names @("status_code")
        $definitionParts = Convert-ToInt (Get-FieldValue -Object $itemGap -Names @("definition_parts"))
        $definitionCandidateCount = Convert-ToInt (Get-FieldValue -Object $itemGap -Names @("candidate_count"))
        $definitionErrorText = Get-FieldValue -Object $itemGap -Names @("error")
        $definitionNotesText = Get-FieldValue -Object $itemGap -Names @("notes")
    }

    $queueRows.Add([pscustomobject]@{
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        workspace_name = $workspaceName
        workspace_environment = $workspaceEnvironment
        item_type = $itemType
        item_name = $itemName
        item_qualified_name = $qualifiedName
        technical_id = Get-FieldValue -Object $item -Names @("technical_id")
        coverage_status = Get-FieldValue -Object $coverage -Names @("coverage_status")
        gap_reason = Get-FieldValue -Object $coverage -Names @("gap_reason", "blocker_reason")
        coverage_next_action = Limit-Text -Text (Get-FieldValue -Object $coverage -Names @("next_action")) -MaxLength 500
        source_dependency_count = $sourceDependencyCount
        source_dependencies = Limit-Text -Text $sourceDependencies -MaxLength 900
        auto_object_evidence_count = Convert-ToInt (Get-FieldValue -Object $manual -Names @("auto_object_evidence_count"))
        manual_object_evidence_count = Convert-ToInt (Get-FieldValue -Object $manual -Names @("manual_object_evidence_count"))
        total_object_evidence_count = Convert-ToInt (Get-FieldValue -Object $manual -Names @("total_object_evidence_count"))
        avg_duration_seconds = Get-FieldValue -Object $manual -Names @("avg_duration_seconds")
        max_duration_seconds = Get-FieldValue -Object $manual -Names @("max_duration_seconds")
        failed_count = Convert-ToInt (Get-FieldValue -Object $manual -Names @("failed_count"))
        is_critical_path_candidate = Get-FieldValue -Object $manual -Names @("is_critical_path_candidate")
        is_failure_hotspot = Get-FieldValue -Object $manual -Names @("is_failure_hotspot")
        v2_status = Get-FieldValue -Object $v2 -Names @("v2_status")
        v2_recommended_next_action = Limit-Text -Text (Get-FieldValue -Object $v2 -Names @("v2_recommended_next_action")) -MaxLength 650
        definition_lookup_status = $definitionStatus
        definition_status_code = $definitionStatusCode
        definition_parts = $definitionParts
        definition_activity_count = $definitionActivityCount
        definition_candidate_count = $definitionCandidateCount
        definition_error = Limit-Text -Text $definitionErrorText -MaxLength 900
        definition_notes = Limit-Text -Text $definitionNotesText -MaxLength 650
        parallel_missing_object_blocker_count = $parallelBlockerCount
        recommended_method = $recommendedMethod
        recommended_script = $recommendedScript
        recommended_command = $recommendedCommand
        recommended_evidence_sources = "Local parser output; Azure DevOps; SharePoint; OneLake; read-only Fabric/Power BI/SQL metadata; owner-approved manual evidence"
        recommended_d1_action = $readonlyGoal
        manual_template_path = $OutputTemplatePath
        manual_template_row_count = $templateSources.Count
        d1_gate_to_close = "Every exact table/view/stored procedure/file/source object used by this item is recorded with confirmed evidence or the item is explicitly blocked."
    }) | Out-Null

    foreach ($source in $templateSources) {
        $templateRows.Add([pscustomobject]@{
            workspace_name = $workspaceName
            item_type = $itemType
            item_name = $itemName
            item_qualified_name = $qualifiedName
            source_type = $source.source_type
            source_name = $source.source_name
            source_qualified_name = $source.source_qualified_name
            source_server = ""
            source_database = ""
            schema_name = ""
            object_name = ""
            object_type = ""
            usage_type = ""
            confidence = ""
            evidence = ""
            reviewer = ""
            reviewed_at = ""
            notes = "D1 template row. Duplicate this row for each confirmed table/view/stored procedure/file if one dependency contains multiple objects."
        }) | Out-Null
    }

    $readonlyRows.Add([pscustomobject]@{
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        workspace_name = $workspaceName
        workspace_environment = $workspaceEnvironment
        item_type = $itemType
        item_name = $itemName
        item_qualified_name = $qualifiedName
        definition_lookup_status = $definitionStatus
        readonly_goal = $readonlyGoal
        recommended_script = $recommendedScript
        recommended_command = $recommendedCommand
        manual_template_path = $OutputTemplatePath
        notes = "Read-only target. Do not modify Fabric or source systems; use results only as evidence for object-level lineage."
    }) | Out-Null
}

$queueColumns = @(
    "priority_score", "priority_band", "workspace_name", "workspace_environment", "item_type", "item_name",
    "item_qualified_name", "technical_id", "coverage_status", "gap_reason", "coverage_next_action",
    "source_dependency_count", "source_dependencies", "auto_object_evidence_count", "manual_object_evidence_count",
    "total_object_evidence_count", "avg_duration_seconds", "max_duration_seconds", "failed_count",
    "is_critical_path_candidate", "is_failure_hotspot", "v2_status", "v2_recommended_next_action",
    "definition_lookup_status", "definition_status_code", "definition_parts", "definition_activity_count",
    "definition_candidate_count", "definition_error", "definition_notes", "parallel_missing_object_blocker_count",
    "recommended_method", "recommended_script", "recommended_command", "recommended_evidence_sources",
    "recommended_d1_action", "manual_template_path", "manual_template_row_count", "d1_gate_to_close"
)

$templateColumns = @(
    "workspace_name", "item_type", "item_name", "item_qualified_name", "source_type", "source_name",
    "source_qualified_name", "source_server", "source_database", "schema_name", "object_name", "object_type",
    "usage_type", "confidence", "evidence", "reviewer", "reviewed_at", "notes"
)

$readonlyColumns = @(
    "priority_score", "priority_band", "workspace_name", "workspace_environment", "item_type", "item_name",
    "item_qualified_name", "definition_lookup_status", "readonly_goal", "recommended_script", "recommended_command",
    "manual_template_path", "notes"
)

$queueSorted = @($queueRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, workspace_name, item_type, item_name)
$templateSorted = @($templateRows | Sort-Object workspace_name, item_type, item_name, source_type, source_name)
$readonlySorted = @($readonlyRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, workspace_name, item_type, item_name)

Export-Rows -Rows $queueSorted -Columns $queueColumns -Path $OutputQueuePath
Export-Rows -Rows $templateSorted -Columns $templateColumns -Path $OutputTemplatePath
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
    $highCount = @($GroupRows | Where-Object { $_.priority_band -in @("critical", "high") }).Count
    $maxPriority = 0
    if ($count -gt 0) {
        $maxPriority = (@($GroupRows | ForEach-Object { [int]$_.priority_score } | Measure-Object -Maximum).Maximum)
    }
    $parallelBlockers = (@($GroupRows | ForEach-Object { [int]$_.parallel_missing_object_blocker_count } | Measure-Object -Sum).Sum)
    if ($null -eq $parallelBlockers) { $parallelBlockers = 0 }
    $Rows.Add([pscustomobject]@{
        summary_scope = $SummaryScope
        group_key = $GroupKey
        queue_count = $count
        high_or_critical_count = $highCount
        max_priority_score = $maxPriority
        related_parallel_blocker_count = [int]$parallelBlockers
        notes = $Notes
    }) | Out-Null
}

Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D1 missing object-level lineage" -GroupRows @($queueRows) -Notes "Item-level queue from analysis/likely_conflict_cleanup_queue.csv phase D1."

foreach ($group in ($queueRows | Group-Object item_type | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "item_type" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D1 rows grouped by Fabric item type."
}
foreach ($group in ($queueRows | Group-Object workspace_environment | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "workspace_environment" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D1 rows grouped by environment."
}
foreach ($group in ($queueRows | Group-Object priority_band | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "priority_band" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D1 rows grouped by priority band."
}
foreach ($group in ($queueRows | Group-Object definition_lookup_status | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "definition_lookup_status" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "Shows whether read-only definition extraction already ran and why object evidence is still missing."
}

Export-Rows -Rows @($summaryRows) -Columns @("summary_scope", "group_key", "queue_count", "high_or_critical_count", "max_priority_score", "related_parallel_blocker_count", "notes") -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$generatedAt = (Get-Date).ToString("s")
$parallelMissingEvidenceCount = (@($parallelRows | Where-Object { $_.candidate_status -eq "blocked_missing_object_evidence" })).Count
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D1 Missing Object-Level Lineage Package") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated: $generatedAt") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D1 focuses on items that still have no usable table/view/stored-procedure/file object lineage. The package is local-only and does not modify Fabric, SQL, OneLake, Power BI, schedules, deployment pipelines, or repositories.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Current Baseline") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- D1 item queue rows: $($queueRows.Count)") | Out-Null
$doc.Add("- Manual evidence template rows: $($templateRows.Count)") | Out-Null
$doc.Add("- Read-only target rows: $($readonlyRows.Count)") | Out-Null
$doc.Add("- Related parallel candidate blockers from missing object evidence: $parallelMissingEvidenceCount") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Item-Type Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($queueRows | Group-Object item_type | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Definition Status Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($queueRows | Group-Object definition_lookup_status | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Top Priority Rows") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("| Priority | Workspace | Type | Item | Definition status | Action |") | Out-Null
$doc.Add("| --- | --- | --- | --- | --- | --- |") | Out-Null
foreach ($row in ($queueSorted | Select-Object -First 15)) {
    $doc.Add("| $($row.priority_score) | $(Escape-MdCell $row.workspace_name) | $(Escape-MdCell $row.item_type) | $(Escape-MdCell $row.item_name) | $(Escape-MdCell $row.definition_lookup_status) | $(Escape-MdCell (Limit-Text -Text $row.recommended_d1_action -MaxLength 160)) |") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- analysis/d1_missing_object_lineage_queue.csv") | Out-Null
$doc.Add("- analysis/d1_missing_object_lineage_summary.csv") | Out-Null
$doc.Add("- analysis/d1_manual_lineage_evidence_template.csv") | Out-Null
$doc.Add("- analysis/d1_readonly_target_items.csv") | Out-Null
$doc.Add("- docs/23_d1_missing_object_lineage.md") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## How To Close D1 Rows") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('1. Work `analysis/d1_missing_object_lineage_queue.csv` in priority order.') | Out-Null
$doc.Add("2. Use generated parser outputs first, then Azure DevOps, SharePoint, OneLake, read-only Fabric/Power BI/SQL metadata, or owner-approved evidence.") | Out-Null
$doc.Add('3. Fill exact objects in `analysis/d1_manual_lineage_evidence_template.csv`; do not copy rows into `index/manual_lineage_object_evidence.csv` until the object name, object type, usage type, confidence, reviewer, and evidence fields are complete.') | Out-Null
$doc.Add('4. After approved evidence is copied into `index/manual_lineage_object_evidence.csv`, rebuild local artifacts and compare D1 counts.') | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Suggested Rebuild") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('```powershell') | Out-Null
$doc.Add("pwsh -NoLogo -File backend/scripts/99_refresh_lineage_project.ps1 -Mode local-artifacts -SkipStandalone") | Out-Null
$doc.Add('```') | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Gate") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D1 is closed only when no high-priority executable item remains without object-level lineage, or when a row is explicitly marked blocked with owner-approved evidence. This package is evidence preparation; it does not approve operational scheduling changes.") | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D1 missing object-level lineage package completed."
Write-Host "Queue rows: $($queueRows.Count)"
Write-Host "Manual evidence template rows: $($templateRows.Count)"
Write-Host "Output: $OutputQueuePath"
