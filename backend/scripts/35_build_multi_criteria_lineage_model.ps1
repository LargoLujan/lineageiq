# Phase 35 - Multi-criteria lineage model: an earlier, superseded explorer
# JSON build that writes to archive/lineage-explorer/ (not the actively-used
# frontend/semantic-lineage/ that Phase 11/the web server serve today). Kept
# for its multi-criteria (dependency + execution + governance) merge logic
# but not part of the current live pipeline's output path.
# Writes: $OutputJsonPath (archive/lineage-explorer/data/lineage-explorer.json),
# $GapPath, $DocPath.
param(
    [string]$WorkspacesPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$DependenciesPath = (Join-Path $PSScriptRoot "../../index/dependencies.csv"),
    [string]$ExecutionsPath = (Join-Path $PSScriptRoot "../../index/executions.csv"),
    [string]$SemanticDependenciesPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_datamart_dependencies.csv"),
    [string]$SemanticReportsPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_report_dependencies.csv"),
    [string]$ReadWritePath = (Join-Path $PSScriptRoot "../../analysis/object_read_write_classification.csv"),
    [string]$IdealPlanPath = (Join-Path $PSScriptRoot "../../analysis/ideal_execution_plan.csv"),
    [string]$OrchestrationV2Path = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_plan.csv"),
    [string]$DeploymentPipelinesPath = (Join-Path $PSScriptRoot "../../index/deployment_pipelines.csv"),
    [string]$DeploymentPipelineStagesPath = (Join-Path $PSScriptRoot "../../index/deployment_pipeline_stages.csv"),
    [string]$OutputJsonPath = (Join-Path $PSScriptRoot "../../archive/lineage-explorer/data/lineage-explorer.json"),
    [string]$GapPath = (Join-Path $PSScriptRoot "../../analysis/lineage_explorer_gaps.csv"),
    [string]$DocPath = (Join-Path $PSScriptRoot "../../docs/12_multi_criteria_lineage.md")
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
    return (($Value.ToLowerInvariant() -replace "\s+", " ").Trim())
}

function Add-MapCount {
    param([hashtable]$Map, [string]$Key, [int]$Amount = 1)
    $clean = if ($Key) { $Key } else { "unknown" }
    if (-not $Map.ContainsKey($clean)) { $Map[$clean] = 0 }
    $Map[$clean] += $Amount
}

function Convert-CountMap {
    param([hashtable]$Map)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($key in ($Map.Keys | Sort-Object)) {
        $rows.Add([pscustomobject]@{
            key = $key
            count = [int]$Map[$key]
        }) | Out-Null
    }
    return @($rows.ToArray())
}

function New-HashSet {
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    return ,$set
}

function Add-SetValue {
    param([System.Collections.Generic.HashSet[string]]$Set, [string]$Value)
    if ($Value) { $Set.Add($Value) | Out-Null }
}

function Get-SetValues {
    param([System.Collections.Generic.HashSet[string]]$Set)
    if ($null -eq $Set) { return @() }
    $values = [System.Collections.Generic.List[string]]::new()
    foreach ($value in $Set) {
        if ($value) { $values.Add([string]$value) | Out-Null }
    }
    return @($values.ToArray() | Sort-Object)
}

function Get-ItemCriteria {
    param([string]$ItemType)
    $criteria = [System.Collections.Generic.List[string]]::new()
    switch ($ItemType) {
        "SemanticModel" {
            $criteria.Add("semantic_models_and_reports") | Out-Null
            $criteria.Add("operational_flow") | Out-Null
        }
        "Report" {
            $criteria.Add("semantic_models_and_reports") | Out-Null
        }
        "PaginatedReport" {
            $criteria.Add("semantic_models_and_reports") | Out-Null
        }
        "Notebook" {
            $criteria.Add("copyjobs_notebooks") | Out-Null
            $criteria.Add("operational_flow") | Out-Null
        }
        "CopyJob" {
            $criteria.Add("copyjobs_notebooks") | Out-Null
            $criteria.Add("operational_flow") | Out-Null
        }
        "DataPipeline" {
            $criteria.Add("operational_flow") | Out-Null
        }
        "Dataflow" {
            $criteria.Add("operational_flow") | Out-Null
        }
        "Lakehouse" {
            $criteria.Add("source_and_storage") | Out-Null
        }
        "SQLEndpoint" {
            $criteria.Add("source_and_storage") | Out-Null
        }
        "Warehouse" {
            $criteria.Add("source_and_storage") | Out-Null
        }
    }
    return @($criteria.ToArray())
}

function New-SourceObjectKey {
    param([object]$Row)
    $key = Get-FieldValue -Object $Row -Names @("object_key")
    if ($key) { return $key }
    $parts = @(
        (Get-FieldValue -Object $Row -Names @("source_type")),
        (Get-FieldValue -Object $Row -Names @("source_server")),
        (Get-FieldValue -Object $Row -Names @("source_database")),
        (Get-FieldValue -Object $Row -Names @("schema_name")),
        (Get-FieldValue -Object $Row -Names @("object_name"))
    )
    return (($parts | ForEach-Object { Normalize-Key $_ }) -join "|")
}

function New-GapRow {
    param(
        [string]$Id,
        [string]$Area,
        [string]$Severity,
        [string]$Scope,
        [int]$AffectedCount,
        [string]$Evidence,
        [string]$RecommendedAction
    )
    return [pscustomobject]@{
        gap_id = $Id
        phase = "Phase 9"
        area = $Area
        severity = $Severity
        scope = $Scope
        affected_count = $AffectedCount
        evidence = $Evidence
        recommended_action = $RecommendedAction
    }
}

Ensure-ParentDirectory -Path $OutputJsonPath
Ensure-ParentDirectory -Path $GapPath
Ensure-ParentDirectory -Path $DocPath

$workspaces = @(Import-OptionalCsv -Path $WorkspacesPath)
$items = @(Import-OptionalCsv -Path $ItemsPath | Where-Object { -not $_.status -or $_.status -eq "discovered" })
$dependencies = @(Import-OptionalCsv -Path $DependenciesPath)
$executions = @(Import-OptionalCsv -Path $ExecutionsPath)
$semanticDependencies = @(Import-OptionalCsv -Path $SemanticDependenciesPath)
$semanticReports = @(Import-OptionalCsv -Path $SemanticReportsPath)
$readWriteRows = @(Import-OptionalCsv -Path $ReadWritePath)
$idealPlanRows = @(Import-OptionalCsv -Path $IdealPlanPath)
$orchestrationRows = @(Import-OptionalCsv -Path $OrchestrationV2Path)
$deploymentPipelines = @(Import-OptionalCsv -Path $DeploymentPipelinesPath)
$deploymentStages = @(Import-OptionalCsv -Path $DeploymentPipelineStagesPath)

$workspaceByName = @{}
foreach ($workspace in $workspaces) {
    $name = Get-FieldValue -Object $workspace -Names @("workspace_name")
    if ($name) { $workspaceByName[(Normalize-Key $name)] = $workspace }
}

$itemByQualifiedName = @{}
foreach ($item in $items) {
    $qualifiedName = Get-FieldValue -Object $item -Names @("qualified_name")
    if ($qualifiedName) { $itemByQualifiedName[$qualifiedName] = $item }
}

$deploymentStageByWorkspaceName = @{}
foreach ($stage in $deploymentStages) {
    $workspaceName = Get-FieldValue -Object $stage -Names @("workspace_name")
    if (-not $workspaceName) { continue }
    if (-not $deploymentStageByWorkspaceName.ContainsKey((Normalize-Key $workspaceName))) {
        $deploymentStageByWorkspaceName[(Normalize-Key $workspaceName)] = [System.Collections.Generic.List[object]]::new()
    }
    $deploymentStageByWorkspaceName[(Normalize-Key $workspaceName)].Add([pscustomobject]@{
        deployment_pipeline_id = Get-FieldValue -Object $stage -Names @("deployment_pipeline_id")
        deployment_pipeline_name = Get-FieldValue -Object $stage -Names @("deployment_pipeline_name")
        stage_id = Get-FieldValue -Object $stage -Names @("stage_id")
        stage_order = Get-FieldValue -Object $stage -Names @("stage_order")
        stage_name = Get-FieldValue -Object $stage -Names @("stage_name")
        evidence = Get-FieldValue -Object $stage -Names @("evidence")
    }) | Out-Null
}

$dependencyStats = @{}
foreach ($item in $items) {
    $qualifiedName = Get-FieldValue -Object $item -Names @("qualified_name")
    if (-not $qualifiedName) { continue }
    $dependencyStats[$qualifiedName] = @{
        incoming = 0
        outgoing = 0
        confirmed = 0
        likely = 0
        relationship_types = @{}
    }
}

foreach ($dependency in $dependencies) {
    $from = Get-FieldValue -Object $dependency -Names @("from_qualified_name")
    $to = Get-FieldValue -Object $dependency -Names @("to_qualified_name")
    $relationship = Get-FieldValue -Object $dependency -Names @("relationship_type")
    $confidence = Get-FieldValue -Object $dependency -Names @("confidence")
    if ($from -and $dependencyStats.ContainsKey($from)) {
        $dependencyStats[$from].outgoing++
        Add-MapCount -Map $dependencyStats[$from].relationship_types -Key $relationship
        if ($confidence -eq "confirmed") { $dependencyStats[$from].confirmed++ }
        elseif ($confidence -eq "likely") { $dependencyStats[$from].likely++ }
    }
    if ($to -and $dependencyStats.ContainsKey($to)) {
        $dependencyStats[$to].incoming++
        Add-MapCount -Map $dependencyStats[$to].relationship_types -Key $relationship
        if ($confidence -eq "confirmed") { $dependencyStats[$to].confirmed++ }
        elseif ($confidence -eq "likely") { $dependencyStats[$to].likely++ }
    }
}

$executionByItem = @{}
foreach ($execution in $executions) {
    $qualifiedName = Get-FieldValue -Object $execution -Names @("qualified_name")
    if (-not $qualifiedName) { continue }
    if (-not $executionByItem.ContainsKey($qualifiedName)) {
        $executionByItem[$qualifiedName] = @{
            run_count = 0
            failed_count = 0
            completed_count = 0
            manual_count = 0
            schedule_count = 0
            enabled_schedules = 0
            disabled_schedules = 0
            latest_start_time = ""
            latest_end_time = ""
            latest_status = ""
            schedule_times = New-HashSet
        }
    }
    $summary = $executionByItem[$qualifiedName]
    $recordType = Get-FieldValue -Object $execution -Names @("record_type")
    $status = Get-FieldValue -Object $execution -Names @("status")
    if ($recordType -eq "job_instance") {
        $summary.run_count++
        if ($status -match "fail|error|cancel" ) { $summary.failed_count++ }
        elseif ($status -match "complete|success|succeed") { $summary.completed_count++ }
        if ((Get-FieldValue -Object $execution -Names @("trigger_type")) -match "manual") { $summary.manual_count++ }
        $start = Get-FieldValue -Object $execution -Names @("start_time")
        if ($start -and $start -gt $summary.latest_start_time) {
            $summary.latest_start_time = $start
            $summary.latest_end_time = Get-FieldValue -Object $execution -Names @("end_time")
            $summary.latest_status = $status
        }
    }
    elseif ($recordType -eq "schedule") {
        $summary.schedule_count++
        if ((Get-FieldValue -Object $execution -Names @("schedule_enabled")) -eq "True") { $summary.enabled_schedules++ }
        else { $summary.disabled_schedules++ }
        Add-SetValue -Set $summary.schedule_times -Value (Get-FieldValue -Object $execution -Names @("scheduled_time"))
    }
}

$semanticSourceCountByModel = @{}
foreach ($row in $semanticDependencies) {
    $model = Get-FieldValue -Object $row -Names @("semantic_model_qualified_name")
    if (-not $model) { continue }
    if (-not $semanticSourceCountByModel.ContainsKey($model)) {
        $semanticSourceCountByModel[$model] = New-HashSet
    }
    Add-SetValue -Set $semanticSourceCountByModel[$model] -Value (Get-FieldValue -Object $row -Names @("source_qualified_name", "connection_label", "datamart_name"))
}

$semanticReportCountByModel = @{}
foreach ($row in $semanticReports) {
    $model = Get-FieldValue -Object $row -Names @("semantic_model_qualified_name")
    if (-not $model) { continue }
    if (-not $semanticReportCountByModel.ContainsKey($model)) {
        $semanticReportCountByModel[$model] = New-HashSet
    }
    Add-SetValue -Set $semanticReportCountByModel[$model] -Value (Get-FieldValue -Object $row -Names @("report_qualified_name"))
}

$idealPlanByItem = @{}
foreach ($row in $idealPlanRows) {
    $qualifiedName = Get-FieldValue -Object $row -Names @("qualified_name")
    if ($qualifiedName -and -not $idealPlanByItem.ContainsKey($qualifiedName)) { $idealPlanByItem[$qualifiedName] = $row }
}

$orchestrationByItem = @{}
foreach ($row in $orchestrationRows) {
    $qualifiedName = Get-FieldValue -Object $row -Names @("qualified_name")
    if ($qualifiedName -and -not $orchestrationByItem.ContainsKey($qualifiedName)) { $orchestrationByItem[$qualifiedName] = $row }
}

$sourceObjectMap = @{}
$sourceObjectEdgeMap = @{}
$objectStatsByItem = @{}

foreach ($row in $readWriteRows) {
    $itemQualifiedName = Get-FieldValue -Object $row -Names @("item_qualified_name")
    $objectKey = New-SourceObjectKey -Row $row
    if (-not $objectKey) { continue }

    if (-not $sourceObjectMap.ContainsKey($objectKey)) {
        $sourceObjectMap[$objectKey] = @{
            object_key = $objectKey
            display_name = Get-FieldValue -Object $row -Names @("object_display_name", "object_name")
            source_type = Get-FieldValue -Object $row -Names @("source_type")
            source_server = Get-FieldValue -Object $row -Names @("source_server")
            source_database = Get-FieldValue -Object $row -Names @("source_database")
            schema_name = Get-FieldValue -Object $row -Names @("schema_name")
            object_name = Get-FieldValue -Object $row -Names @("object_name")
            object_type = Get-FieldValue -Object $row -Names @("object_type")
            object_type_status = Get-FieldValue -Object $row -Names @("object_type_status")
            object_type_confidence = Get-FieldValue -Object $row -Names @("object_type_confidence")
            affected_items = New-HashSet
            affected_workspaces = New-HashSet
            operation_counts = @{ read = 0; write = 0; execute = 0; unknown = 0 }
            confidence_counts = @{}
        }
    }

    $sourceObject = $sourceObjectMap[$objectKey]
    Add-SetValue -Set $sourceObject.affected_items -Value $itemQualifiedName
    Add-SetValue -Set $sourceObject.affected_workspaces -Value (Get-FieldValue -Object $row -Names @("workspace_name"))
    $operation = Get-FieldValue -Object $row -Names @("operation_type", "usage_type_normalized")
    if (-not $operation) { $operation = "unknown" }
    if (-not $sourceObject.operation_counts.ContainsKey($operation)) { $sourceObject.operation_counts[$operation] = 0 }
    $sourceObject.operation_counts[$operation]++
    Add-MapCount -Map $sourceObject.confidence_counts -Key (Get-FieldValue -Object $row -Names @("lineage_confidence"))

    if ($itemQualifiedName) {
        if (-not $objectStatsByItem.ContainsKey($itemQualifiedName)) {
            $objectStatsByItem[$itemQualifiedName] = @{
                source_objects = New-HashSet
                read_count = 0
                write_count = 0
                execute_count = 0
                unknown_count = 0
                likely_count = 0
                confirmed_count = 0
            }
        }
        $itemObjectStats = $objectStatsByItem[$itemQualifiedName]
        Add-SetValue -Set $itemObjectStats.source_objects -Value $objectKey
        switch ($operation) {
            "read" { $itemObjectStats.read_count++ }
            "write" { $itemObjectStats.write_count++ }
            "execute" { $itemObjectStats.execute_count++ }
            default { $itemObjectStats.unknown_count++ }
        }
        switch (Get-FieldValue -Object $row -Names @("lineage_confidence")) {
            "confirmed" { $itemObjectStats.confirmed_count++ }
            "likely" { $itemObjectStats.likely_count++ }
        }

        $edgeKey = "$objectKey|$itemQualifiedName|$operation"
        if (-not $sourceObjectEdgeMap.ContainsKey($edgeKey)) {
            $sourceObjectEdgeMap[$edgeKey] = [pscustomobject]@{
                source_object_key = $objectKey
                item_qualified_name = $itemQualifiedName
                workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
                item_name = Get-FieldValue -Object $row -Names @("item_name")
                item_type = Get-FieldValue -Object $row -Names @("item_type")
                operation_type = $operation
                semantic_table = Get-FieldValue -Object $row -Names @("semantic_table")
                lineage_confidence = Get-FieldValue -Object $row -Names @("lineage_confidence")
                hardening_status = Get-FieldValue -Object $row -Names @("hardening_status")
                evidence = Get-FieldValue -Object $row -Names @("evidence")
            }
        }
    }
}

$workspacePayloads = [System.Collections.Generic.List[object]]::new()
$workspaceCriterionCounts = @{}
$itemTypeCounts = @{}

foreach ($workspace in ($workspaces | Sort-Object workspace_name)) {
    $workspaceName = Get-FieldValue -Object $workspace -Names @("workspace_name")
    $workspaceItems = @($items | Where-Object { $_.workspace_name -eq $workspaceName })
    $itemCounts = @{}
    $criteriaSet = New-HashSet
    foreach ($item in $workspaceItems) {
        $itemType = Get-FieldValue -Object $item -Names @("item_type")
        Add-MapCount -Map $itemCounts -Key $itemType
        Add-MapCount -Map $itemTypeCounts -Key $itemType
        foreach ($criterion in @(Get-ItemCriteria -ItemType $itemType)) {
            Add-SetValue -Set $criteriaSet -Value $criterion
        }
    }
    foreach ($criterion in $criteriaSet) { Add-MapCount -Map $workspaceCriterionCounts -Key $criterion }
    $stageKey = Normalize-Key $workspaceName
    $stageRows = if ($deploymentStageByWorkspaceName.ContainsKey($stageKey)) { @($deploymentStageByWorkspaceName[$stageKey].ToArray()) } else { @() }

    $workspacePayloads.Add([pscustomobject]@{
        name = $workspaceName
        normalized_name = Get-FieldValue -Object $workspace -Names @("normalized_workspace_name")
        environment = Get-FieldValue -Object $workspace -Names @("environment")
        workspace_type = Get-FieldValue -Object $workspace -Names @("workspace_type")
        capacity_name = Get-FieldValue -Object $workspace -Names @("capacity_name")
        capacity_id = Get-FieldValue -Object $workspace -Names @("capacity_id")
        capacity_region = Get-FieldValue -Object $workspace -Names @("capacity_region")
        domain_name = Get-FieldValue -Object $workspace -Names @("domain_name")
        owner = Get-FieldValue -Object $workspace -Names @("owner")
        admin_principals = Get-FieldValue -Object $workspace -Names @("admin_principals")
        technical_id = Get-FieldValue -Object $workspace -Names @("technical_id")
        item_count = @($workspaceItems).Count
        item_type_counts = Convert-CountMap -Map $itemCounts
        criteria = @(Get-SetValues -Set $criteriaSet)
        deployment_pipeline = [pscustomobject]@{
            has_pipeline = (@($stageRows).Count -gt 0)
            stages = $stageRows
        }
    }) | Out-Null
}

$itemPayloads = [System.Collections.Generic.List[object]]::new()
$criterionItemCounts = @{}

foreach ($item in ($items | Sort-Object workspace_name, item_type, item_name)) {
    $qualifiedName = Get-FieldValue -Object $item -Names @("qualified_name")
    $itemType = Get-FieldValue -Object $item -Names @("item_type")
    $criteria = @(Get-ItemCriteria -ItemType $itemType)
    foreach ($criterion in $criteria) { Add-MapCount -Map $criterionItemCounts -Key $criterion }

    $execution = if ($executionByItem.ContainsKey($qualifiedName)) { $executionByItem[$qualifiedName] } else { $null }
    $dependency = if ($dependencyStats.ContainsKey($qualifiedName)) { $dependencyStats[$qualifiedName] } else { $null }
    $objectStats = if ($objectStatsByItem.ContainsKey($qualifiedName)) { $objectStatsByItem[$qualifiedName] } else { $null }
    $ideal = if ($idealPlanByItem.ContainsKey($qualifiedName)) { $idealPlanByItem[$qualifiedName] } else { $null }
    $v2 = if ($orchestrationByItem.ContainsKey($qualifiedName)) { $orchestrationByItem[$qualifiedName] } else { $null }

    $itemPayloads.Add([pscustomobject]@{
        qualified_name = $qualifiedName
        workspace_name = Get-FieldValue -Object $item -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $item -Names @("workspace_environment")
        item_type = $itemType
        item_name = Get-FieldValue -Object $item -Names @("item_name")
        description = Get-FieldValue -Object $item -Names @("description")
        technical_id = Get-FieldValue -Object $item -Names @("technical_id")
        criteria = $criteria
        dependencies = [pscustomobject]@{
            incoming = if ($dependency) { [int]$dependency.incoming } else { 0 }
            outgoing = if ($dependency) { [int]$dependency.outgoing } else { 0 }
            confirmed = if ($dependency) { [int]$dependency.confirmed } else { 0 }
            likely = if ($dependency) { [int]$dependency.likely } else { 0 }
            relationship_types = if ($dependency) { Convert-CountMap -Map $dependency.relationship_types } else { @() }
        }
        execution = [pscustomobject]@{
            run_count = if ($execution) { [int]$execution.run_count } else { 0 }
            failed_count = if ($execution) { [int]$execution.failed_count } else { 0 }
            completed_count = if ($execution) { [int]$execution.completed_count } else { 0 }
            manual_count = if ($execution) { [int]$execution.manual_count } else { 0 }
            schedule_count = if ($execution) { [int]$execution.schedule_count } else { 0 }
            enabled_schedules = if ($execution) { [int]$execution.enabled_schedules } else { 0 }
            disabled_schedules = if ($execution) { [int]$execution.disabled_schedules } else { 0 }
            latest_start_time = if ($execution) { $execution.latest_start_time } else { "" }
            latest_end_time = if ($execution) { $execution.latest_end_time } else { "" }
            latest_status = if ($execution) { $execution.latest_status } else { "" }
            schedule_times = if ($execution) { @(Get-SetValues -Set $execution.schedule_times) } else { @() }
        }
        semantic_model = [pscustomobject]@{
            source_count = if ($semanticSourceCountByModel.ContainsKey($qualifiedName)) { $semanticSourceCountByModel[$qualifiedName].Count } else { 0 }
            report_count = if ($semanticReportCountByModel.ContainsKey($qualifiedName)) { $semanticReportCountByModel[$qualifiedName].Count } else { 0 }
        }
        source_objects = [pscustomobject]@{
            count = if ($objectStats) { $objectStats.source_objects.Count } else { 0 }
            read_count = if ($objectStats) { [int]$objectStats.read_count } else { 0 }
            write_count = if ($objectStats) { [int]$objectStats.write_count } else { 0 }
            execute_count = if ($objectStats) { [int]$objectStats.execute_count } else { 0 }
            unknown_count = if ($objectStats) { [int]$objectStats.unknown_count } else { 0 }
            confirmed_count = if ($objectStats) { [int]$objectStats.confirmed_count } else { 0 }
            likely_count = if ($objectStats) { [int]$objectStats.likely_count } else { 0 }
        }
        orchestration = [pscustomobject]@{
            ideal_wave_index = if ($ideal) { Get-FieldValue -Object $ideal -Names @("wave_index") } else { "" }
            ideal_stage = if ($ideal) { Get-FieldValue -Object $ideal -Names @("proposed_stage") } else { "" }
            ideal_parallel_group = if ($ideal) { Get-FieldValue -Object $ideal -Names @("parallel_group") } else { "" }
            ideal_parallel_readiness = if ($ideal) { Get-FieldValue -Object $ideal -Names @("parallel_readiness") } else { "" }
            v2_status = if ($v2) { Get-FieldValue -Object $v2 -Names @("v2_status") } else { "" }
            v2_recommended_next_action = if ($v2) { Get-FieldValue -Object $v2 -Names @("v2_recommended_next_action") } else { "" }
        }
    }) | Out-Null
}

$sourceObjectPayloads = [System.Collections.Generic.List[object]]::new()
foreach ($key in ($sourceObjectMap.Keys | Sort-Object)) {
    $source = $sourceObjectMap[$key]
    $sourceObjectPayloads.Add([pscustomobject]@{
        object_key = $source.object_key
        display_name = $source.display_name
        source_type = $source.source_type
        source_server = $source.source_server
        source_database = $source.source_database
        schema_name = $source.schema_name
        object_name = $source.object_name
        object_type = $source.object_type
        object_type_status = $source.object_type_status
        object_type_confidence = $source.object_type_confidence
        affected_item_count = $source.affected_items.Count
        affected_workspace_count = $source.affected_workspaces.Count
        affected_workspaces = @(Get-SetValues -Set $source.affected_workspaces)
        operation_counts = Convert-CountMap -Map $source.operation_counts
        confidence_counts = Convert-CountMap -Map $source.confidence_counts
    }) | Out-Null
}

$dependencyPayloads = @(
    $dependencies |
        ForEach-Object {
            [pscustomobject]@{
                from = Get-FieldValue -Object $_ -Names @("from_qualified_name")
                to = Get-FieldValue -Object $_ -Names @("to_qualified_name")
                relationship_type = Get-FieldValue -Object $_ -Names @("relationship_type")
                confidence = Get-FieldValue -Object $_ -Names @("confidence")
                evidence = Get-FieldValue -Object $_ -Names @("evidence")
                source_system = Get-FieldValue -Object $_ -Names @("source_system")
            }
        }
)

$semanticSourceRelationships = @(
    $semanticDependencies |
        ForEach-Object {
            [pscustomobject]@{
                semantic_model_qualified_name = Get-FieldValue -Object $_ -Names @("semantic_model_qualified_name")
                semantic_model_name = Get-FieldValue -Object $_ -Names @("semantic_model_name")
                workspace_name = Get-FieldValue -Object $_ -Names @("workspace_name")
                source_qualified_name = Get-FieldValue -Object $_ -Names @("source_qualified_name")
                source_type = Get-FieldValue -Object $_ -Names @("source_type")
                source_server = Get-FieldValue -Object $_ -Names @("source_server")
                datamart_name = Get-FieldValue -Object $_ -Names @("datamart_name")
                view_or_object = Get-FieldValue -Object $_ -Names @("view_or_object")
                confidence = Get-FieldValue -Object $_ -Names @("confidence")
                evidence = Get-FieldValue -Object $_ -Names @("evidence")
            }
        }
)

$semanticReportRelationships = @(
    $semanticReports |
        ForEach-Object {
            [pscustomobject]@{
                semantic_model_qualified_name = Get-FieldValue -Object $_ -Names @("semantic_model_qualified_name")
                report_qualified_name = Get-FieldValue -Object $_ -Names @("report_qualified_name")
                workspace_name = Get-FieldValue -Object $_ -Names @("workspace_name")
                semantic_model_name = Get-FieldValue -Object $_ -Names @("semantic_model_name")
                report_name = Get-FieldValue -Object $_ -Names @("report_name")
                confidence = Get-FieldValue -Object $_ -Names @("confidence")
                evidence = Get-FieldValue -Object $_ -Names @("evidence")
            }
        }
)

$sourceObjectEdges = @($sourceObjectEdgeMap.Values | Sort-Object source_object_key, item_qualified_name, operation_type)

$criteria = @(
    [pscustomobject]@{
        id = "semantic_models_and_reports"
        label = "Semantic models and reports"
        purpose = "Review workspaces with semantic models, reports, origins, source objects, refresh metadata, deployment stages, and evidence."
        item_types = @("SemanticModel", "Report", "PaginatedReport")
        workspace_count = if ($workspaceCriterionCounts.ContainsKey("semantic_models_and_reports")) { $workspaceCriterionCounts["semantic_models_and_reports"] } else { 0 }
        item_count = if ($criterionItemCounts.ContainsKey("semantic_models_and_reports")) { $criterionItemCounts["semantic_models_and_reports"] } else { 0 }
    },
    [pscustomobject]@{
        id = "copyjobs_notebooks"
        label = "CopyJobs and notebooks"
        purpose = "Review operational data movement and transformation items with source object reads, writes, schedules, durations, and evidence."
        item_types = @("CopyJob", "Notebook")
        workspace_count = if ($workspaceCriterionCounts.ContainsKey("copyjobs_notebooks")) { $workspaceCriterionCounts["copyjobs_notebooks"] } else { 0 }
        item_count = if ($criterionItemCounts.ContainsKey("copyjobs_notebooks")) { $criterionItemCounts["copyjobs_notebooks"] } else { 0 }
    },
    [pscustomobject]@{
        id = "operational_flow"
        label = "Pipelines and operational flow"
        purpose = "Review execution order, ideal waves, schedules, failures, and insertion points for semantic model refresh and report validation."
        item_types = @("DataPipeline", "Notebook", "CopyJob", "SemanticModel", "Dataflow")
        workspace_count = if ($workspaceCriterionCounts.ContainsKey("operational_flow")) { $workspaceCriterionCounts["operational_flow"] } else { 0 }
        item_count = if ($criterionItemCounts.ContainsKey("operational_flow")) { $criterionItemCounts["operational_flow"] } else { 0 }
    },
    [pscustomobject]@{
        id = "source_and_storage"
        label = "Sources and Fabric storage"
        purpose = "Review source systems, Fabric storage items, source objects, operation types, and evidence confidence."
        item_types = @("Lakehouse", "SQLEndpoint", "Warehouse")
        workspace_count = if ($workspaceCriterionCounts.ContainsKey("source_and_storage")) { $workspaceCriterionCounts["source_and_storage"] } else { 0 }
        item_count = if ($criterionItemCounts.ContainsKey("source_and_storage")) { $criterionItemCounts["source_and_storage"] } else { 0 }
    }
)

$gaps = [System.Collections.Generic.List[object]]::new()
$missingCapacity = @($workspaces | Where-Object { $_.capacity_id -and -not $_.capacity_name }).Count
if ($missingCapacity -gt 0) {
    $gaps.Add((New-GapRow -Id "phase9_capacity_names_missing" -Area "workspace_governance" -Severity "medium" -Scope "workspaces" -AffectedCount $missingCapacity -Evidence "index/workspaces.csv capacity_id present but capacity_name empty" -RecommendedAction "Phase 11 should enrich capacity metadata through approved read-only APIs.")) | Out-Null
}
$missingDomains = @($workspaces | Where-Object { -not $_.domain_name }).Count
if ($missingDomains -gt 0) {
    $gaps.Add((New-GapRow -Id "phase9_domains_missing" -Area "workspace_governance" -Severity "low" -Scope "workspaces" -AffectedCount $missingDomains -Evidence "index/workspaces.csv domain_name empty" -RecommendedAction "Phase 11 should retry domain enrichment where permissions allow it.")) | Out-Null
}
$likelyDependencies = @($dependencies | Where-Object { $_.confidence -eq "likely" }).Count
if ($likelyDependencies -gt 0) {
    $gaps.Add((New-GapRow -Id "phase9_likely_dependencies" -Area "dependency_confidence" -Severity "high" -Scope "dependencies" -AffectedCount $likelyDependencies -Evidence "index/dependencies.csv confidence=likely" -RecommendedAction "Confirm or reject likely dependency edges before using them as execution rules.")) | Out-Null
}
$ambiguousObjectTypes = @($sourceObjectPayloads | Where-Object { $_.object_type -in @("table_or_view", "native_query_object") }).Count
if ($ambiguousObjectTypes -gt 0) {
    $gaps.Add((New-GapRow -Id "phase9_ambiguous_source_object_types" -Area "object_lineage" -Severity "high" -Scope "source_objects" -AffectedCount $ambiguousObjectTypes -Evidence "analysis/object_read_write_classification.csv object_type is table_or_view or native_query_object" -RecommendedAction "Phase 12 should enrich object types with read-only SQL/Fabric metadata or owner confirmation.")) | Out-Null
}
$blockedOrchestration = @($orchestrationRows | Where-Object { $_.v2_status -and $_.v2_status -ne "candidate_ready" }).Count
if ($blockedOrchestration -gt 0) {
    $gaps.Add((New-GapRow -Id "phase9_orchestration_blockers" -Area "orchestration_readiness" -Severity "high" -Scope "items" -AffectedCount $blockedOrchestration -Evidence "analysis/orchestration_v2_plan.csv v2_status is not candidate_ready" -RecommendedAction "Resolve lineage, object-type, duration, and review blockers before operationalizing an ideal pipeline.")) | Out-Null
}
$operationalItems = @($items | Where-Object { $_.item_type -in @("Notebook", "CopyJob", "DataPipeline", "SemanticModel", "Dataflow") })
$operationalItemsWithoutExecution = @($operationalItems | Where-Object { -not $executionByItem.ContainsKey($_.qualified_name) }).Count
if ($operationalItemsWithoutExecution -gt 0) {
    $gaps.Add((New-GapRow -Id "phase9_execution_metadata_missing" -Area "execution_metadata" -Severity "medium" -Scope "items" -AffectedCount $operationalItemsWithoutExecution -Evidence "No index/executions.csv row for some operational item qualified names" -RecommendedAction "Refresh full read-only execution history before relying on timing or critical path analysis.")) | Out-Null
}

$summary = [pscustomobject]@{
    generated_at = (Get-Date).ToString("s")
    phase = "Phase 9"
    source_mode = "local-artifacts"
    workspaces = $workspacePayloads.Count
    items = $itemPayloads.Count
    source_objects = $sourceObjectPayloads.Count
    source_object_edges = @($sourceObjectEdges).Count
    dependencies = @($dependencyPayloads).Count
    semantic_source_relationships = @($semanticSourceRelationships).Count
    semantic_report_relationships = @($semanticReportRelationships).Count
    deployment_pipelines = @($deploymentPipelines).Count
    deployment_stages = @($deploymentStages).Count
    gap_count = $gaps.Count
    item_type_counts = Convert-CountMap -Map $itemTypeCounts
}

$payload = [pscustomobject]@{
    schema_version = "phase9.multi_criteria_lineage.v1"
    generated_at = $summary.generated_at
    summary = $summary
    criteria = $criteria
    workspaces = @($workspacePayloads.ToArray())
    items = @($itemPayloads.ToArray())
    source_objects = @($sourceObjectPayloads.ToArray())
    relationships = [pscustomobject]@{
        dependencies = $dependencyPayloads
        semantic_model_sources = $semanticSourceRelationships
        semantic_model_reports = $semanticReportRelationships
        source_object_edges = $sourceObjectEdges
    }
    deployment_pipelines = @(
        $deploymentPipelines | ForEach-Object {
            [pscustomobject]@{
                deployment_pipeline_id = Get-FieldValue -Object $_ -Names @("deployment_pipeline_id")
                deployment_pipeline_name = Get-FieldValue -Object $_ -Names @("deployment_pipeline_name")
                description = Get-FieldValue -Object $_ -Names @("description")
                status = Get-FieldValue -Object $_ -Names @("status")
                evidence = Get-FieldValue -Object $_ -Names @("evidence")
            }
        }
    )
    orchestration = [pscustomobject]@{
        ideal_execution_plan_nodes = @($idealPlanRows).Count
        orchestration_v2_nodes = @($orchestrationRows).Count
        ideal_waves = @(
            $idealPlanRows |
                Group-Object wave_index |
                Sort-Object { [int]($_.Name -replace "\D", "0") } |
                ForEach-Object {
                    [pscustomobject]@{
                        wave_index = $_.Name
                        item_count = $_.Count
                        stages = @($_.Group | Select-Object -ExpandProperty proposed_stage -Unique | Sort-Object)
                    }
                }
        )
    }
    gaps = @($gaps.ToArray())
    source_artifacts = @(
        $WorkspacesPath,
        $ItemsPath,
        $DependenciesPath,
        $ExecutionsPath,
        $SemanticDependenciesPath,
        $SemanticReportsPath,
        $ReadWritePath,
        $IdealPlanPath,
        $OrchestrationV2Path,
        $DeploymentPipelinesPath,
        $DeploymentPipelineStagesPath
    )
}

$payload | ConvertTo-Json -Depth 30 | Set-Content -Path $OutputJsonPath -Encoding UTF8
$gaps | Export-Csv -Path $GapPath -NoTypeInformation -Encoding UTF8

$docLines = [System.Collections.Generic.List[string]]::new()
$docLines.Add("# Multi-Criteria Lineage Data Model") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Generated by backend/scripts/35_build_multi_criteria_lineage_model.ps1 from local project artifacts only.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Outputs") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- archive/lineage-explorer/data/lineage-explorer.json") | Out-Null
$docLines.Add("- analysis/lineage_explorer_gaps.csv") | Out-Null
$docLines.Add("- docs/12_multi_criteria_lineage.md") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Summary") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- Workspaces: $($summary.workspaces)") | Out-Null
$docLines.Add("- Items: $($summary.items)") | Out-Null
$docLines.Add("- Source objects: $($summary.source_objects)") | Out-Null
$docLines.Add("- Source object edges: $($summary.source_object_edges)") | Out-Null
$docLines.Add("- Dependency edges: $($summary.dependencies)") | Out-Null
$docLines.Add("- Semantic source relationships: $($summary.semantic_source_relationships)") | Out-Null
$docLines.Add("- Semantic report relationships: $($summary.semantic_report_relationships)") | Out-Null
$docLines.Add("- Deployment pipelines: $($summary.deployment_pipelines)") | Out-Null
$docLines.Add("- Gaps: $($summary.gap_count)") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Criteria") | Out-Null
$docLines.Add("") | Out-Null
foreach ($criterion in $criteria) {
    $docLines.Add("- $($criterion.id): $($criterion.item_count) items across $($criterion.workspace_count) workspaces.") | Out-Null
}
$docLines.Add("") | Out-Null
$docLines.Add("## Gap Themes") | Out-Null
$docLines.Add("") | Out-Null
foreach ($gap in $gaps) {
    $docLines.Add("- $($gap.gap_id): $($gap.affected_count) affected $($gap.scope); severity $($gap.severity).") | Out-Null
}
if ($gaps.Count -eq 0) {
    $docLines.Add("- No local Phase 9 gaps were generated.") | Out-Null
}
$docLines.Add("") | Out-Null
$docLines.Add("## Safety") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("This phase did not read or modify Fabric, Azure DevOps, SharePoint, SQL, schedules, deployments, or external systems. It only transformed existing local CSV/JSON evidence into a reusable explorer data model.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Next Human Step") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Review the Phase 9 data model summary and approve Phase 10 when ready to build the interactive corporate explorer UI.") | Out-Null

$docLines | Set-Content -Path $DocPath -Encoding UTF8

Write-Host "Multi-criteria lineage data model built: $OutputJsonPath"
Write-Host "Workspaces: $($summary.workspaces)"
Write-Host "Items: $($summary.items)"
Write-Host "Source objects: $($summary.source_objects)"
Write-Host "Source object edges: $($summary.source_object_edges)"
Write-Host "Gaps: $($summary.gap_count)"
