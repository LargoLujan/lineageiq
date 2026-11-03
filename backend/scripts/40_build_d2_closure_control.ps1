# Phase 40 - D2 closure control: tracks which D2 (likely dependency,
# Phase 27) queue items have since been confirmed (e.g. Report<->Model
# bindings, SQL-endpoint<->Lakehouse pairings), closing them out and
# re-deriving what's still open. Purely local.
# Writes: $OutputControlQueuePath, $OutputReportModelCandidatePath,
# $OutputSqlEndpointLakehouseCandidatePath, $OutputDecisionTemplatePath,
# $OutputReadonlyPlanPath, $OutputSummaryPath, $OutputDocPath.
param(
    [string]$D2EdgeQueuePath = (Join-Path $PSScriptRoot "../../analysis/d2_likely_dependency_edge_queue.csv"),
    [string]$D2ItemQueuePath = (Join-Path $PSScriptRoot "../../analysis/d2_likely_dependency_item_queue.csv"),
    [string]$PipelineActivityPath = (Join-Path $PSScriptRoot "../../analysis/pipeline_activity_lineage.csv"),
    [string]$OutputControlQueuePath = (Join-Path $PSScriptRoot "../../analysis/d2_closure_control_queue.csv"),
    [string]$OutputReportModelCandidatePath = (Join-Path $PSScriptRoot "../../analysis/d2_report_model_binding_candidates.csv"),
    [string]$OutputSqlEndpointLakehouseCandidatePath = (Join-Path $PSScriptRoot "../../analysis/d2_sqlendpoint_lakehouse_candidates.csv"),
    [string]$OutputDecisionTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d2_dependency_decision_template.csv"),
    [string]$OutputReadonlyPlanPath = (Join-Path $PSScriptRoot "../../analysis/d2_external_readonly_action_plan.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d2_closure_control_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/36_d2_closure_control.md")
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

function Get-EdgeKey {
    param([string]$From, [string]$To, [string]$RelationshipType)
    return ((Normalize-Key -Value $From) + "|" + (Normalize-Key -Value $To) + "|" + (Normalize-Key -Value $RelationshipType))
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

function Get-PriorityBand {
    param([int]$PriorityScore)
    if ($PriorityScore -ge 130) { return "critical" }
    if ($PriorityScore -ge 105) { return "high" }
    if ($PriorityScore -ge 80) { return "medium" }
    return "low"
}

function Get-UniqueJoined {
    param([object[]]$Rows, [string]$ColumnName)
    return ((@(
        $Rows |
            ForEach-Object { Get-FieldValue -Object $_ -Names @($ColumnName) } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )) -join "; ")
}

function Test-SqlEndpointLakehousePair {
    param([object[]]$Rows)
    foreach ($row in $Rows) {
        $fromType = Get-FieldValue -Object $row -Names @("from_item_type")
        $toType = Get-FieldValue -Object $row -Names @("to_item_type")
        $relationshipType = Get-FieldValue -Object $row -Names @("relationship_type")
        if ($relationshipType -eq "depends_on" -and $fromType -eq "SQLEndpoint" -and $toType -eq "Lakehouse") {
            return $true
        }
    }
    return $false
}

function Get-ClosureOpportunity {
    param(
        [object[]]$Rows,
        [int]$PipelineActivityEvidenceCount
    )

    $family = Get-FieldValue -Object $Rows[0] -Names @("relationship_family")
    if ($family -eq "report_model_binding") { return "report_model_binding_requires_metadata" }
    if (Test-SqlEndpointLakehousePair -Rows $Rows) { return "sqlendpoint_lakehouse_same_name_candidate" }
    if ($PipelineActivityEvidenceCount -gt 0) { return "pipeline_activity_invocation_candidate" }
    return "manual_dependency_review_required"
}

function Get-RecommendedDecision {
    param([string]$ClosureOpportunity)
    switch ($ClosureOpportunity) {
        "report_model_binding_requires_metadata" { return "Confirm report semantic-model binding from Fabric/Power BI report metadata or report definition; otherwise reject or mark unavailable." }
        "sqlendpoint_lakehouse_same_name_candidate" { return "Confirm from Fabric lakehouse/SQL endpoint metadata that the SQL endpoint belongs to the lakehouse; otherwise reject the name-only dependency." }
        "pipeline_activity_invocation_candidate" { return "Confirm the invoked item reference from DataPipeline activity definition before promoting the dependency." }
        default { return "Review manually and close with confirmed, rejected, access_denied, not_available, dynamic_reference, or manual_review_required." }
    }
}

function Get-HumanReadonlyAction {
    param([string]$ClosureOpportunity)
    switch ($ClosureOpportunity) {
        "report_model_binding_requires_metadata" { return "Read the report metadata/definition and verify the bound semantic model ID, name, and workspace. Record the evidence before any dependency update." }
        "sqlendpoint_lakehouse_same_name_candidate" { return "Read the lakehouse and SQL endpoint metadata. Confirm the endpoint is generated for, or explicitly belongs to, the lakehouse before using it as a dependency rule." }
        "pipeline_activity_invocation_candidate" { return "Read the DataPipeline definition and verify the invoked item reference in the activity payload." }
        default { return "Read the relevant item definitions or owner-approved evidence, then record the decision in the template." }
    }
}

function Get-PairRoleValue {
    param([object[]]$Rows, [string]$ItemType, [string]$FieldPrefix)
    foreach ($row in $Rows) {
        if ((Get-FieldValue -Object $row -Names @("from_item_type")) -eq $ItemType) {
            return Get-FieldValue -Object $row -Names @("from_$FieldPrefix")
        }
        if ((Get-FieldValue -Object $row -Names @("to_item_type")) -eq $ItemType) {
            return Get-FieldValue -Object $row -Names @("to_$FieldPrefix")
        }
    }
    return ""
}

if (-not (Test-Path $D2EdgeQueuePath)) {
    throw "Required input not found: $D2EdgeQueuePath"
}

$edgeRows = @(Import-Csv -Path $D2EdgeQueuePath)
$itemRows = @(Import-OptionalCsv -Path $D2ItemQueuePath)
$activityRows = @(Import-OptionalCsv -Path $PipelineActivityPath)

$activityByEdge = @{}
foreach ($activity in $activityRows) {
    $pipelineQualified = Get-FieldValue -Object $activity -Names @("pipeline_qualified_name")
    $invokedQualified = Get-FieldValue -Object $activity -Names @("invoked_item_qualified_name")
    if (-not $pipelineQualified -or -not $invokedQualified) { continue }
    Add-ListMapValue -Map $activityByEdge -Key (Get-EdgeKey -From $pipelineQualified -To $invokedQualified -RelationshipType "depends_on") -Value $activity
}

$edgesByPair = @{}
foreach ($edge in $edgeRows) {
    $pairKey = Get-FieldValue -Object $edge -Names @("canonical_pair_key")
    if (-not $pairKey) { $pairKey = Get-FieldValue -Object $edge -Names @("edge_key") }
    Add-ListMapValue -Map $edgesByPair -Key $pairKey -Value $edge
}

$reviewTargets = [System.Collections.Generic.List[object]]::new()
$reviewTargetByPair = @{}
$reportModelRows = [System.Collections.Generic.List[object]]::new()
$sqlEndpointLakehouseRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()

$pairIndex = 0
$pairGroups = @(
    $edgesByPair.GetEnumerator() |
        ForEach-Object {
            $groupRows = @($_.Value)
            [pscustomobject]@{
                pair_key = $_.Key
                rows = $groupRows
                max_priority = (@($groupRows | ForEach-Object { Convert-ToInt (Get-FieldValue -Object $_ -Names @("priority_score")) } | Measure-Object -Maximum).Maximum)
            }
        } |
        Sort-Object @{ Expression = { [int]$_.max_priority }; Descending = $true }, pair_key
)

foreach ($group in $pairGroups) {
    $pairIndex++
    $reviewTargetId = "D2R{0:0000}" -f $pairIndex
    $rows = @($group.rows)
    $first = $rows[0]
    $edgeIds = Get-UniqueJoined -Rows $rows -ColumnName "edge_id"
    $edgeKeys = Get-UniqueJoined -Rows $rows -ColumnName "edge_key"
    $relationshipFamily = Get-FieldValue -Object $first -Names @("relationship_family")
    $relationshipTypes = Get-UniqueJoined -Rows $rows -ColumnName "relationship_type"
    $currentEvidence = Limit-Text -Text ((@($rows | ForEach-Object { Get-FieldValue -Object $_ -Names @("current_evidence") } | Where-Object { $_ } | Sort-Object -Unique)) -join "; ") -MaxLength 900
    $priorityScore = [int]$group.max_priority
    $priorityBand = Get-PriorityBand -PriorityScore $priorityScore
    $activityEvidenceRows = @()
    foreach ($row in $rows) {
        $edgeKey = Get-EdgeKey `
            -From (Get-FieldValue -Object $row -Names @("from_qualified_name")) `
            -To (Get-FieldValue -Object $row -Names @("to_qualified_name")) `
            -RelationshipType (Get-FieldValue -Object $row -Names @("relationship_type"))
        if ($activityByEdge.ContainsKey($edgeKey)) {
            $activityEvidenceRows += @($activityByEdge[$edgeKey])
        }
    }

    $closureOpportunity = Get-ClosureOpportunity -Rows $rows -PipelineActivityEvidenceCount @($activityEvidenceRows).Count
    $recommendedDecision = Get-RecommendedDecision -ClosureOpportunity $closureOpportunity
    $humanReadonlyAction = Get-HumanReadonlyAction -ClosureOpportunity $closureOpportunity

    $workspaceName = Get-PairRoleValue -Rows $rows -ItemType "Report" -FieldPrefix "workspace_name"
    if (-not $workspaceName) { $workspaceName = Get-PairRoleValue -Rows $rows -ItemType "SQLEndpoint" -FieldPrefix "workspace_name" }
    if (-not $workspaceName) { $workspaceName = Get-FieldValue -Object $first -Names @("from_workspace_name") }
    $workspaceEnvironment = Get-PairRoleValue -Rows $rows -ItemType "Report" -FieldPrefix "workspace_environment"
    if (-not $workspaceEnvironment) { $workspaceEnvironment = Get-PairRoleValue -Rows $rows -ItemType "SQLEndpoint" -FieldPrefix "workspace_environment" }
    if (-not $workspaceEnvironment) { $workspaceEnvironment = Get-FieldValue -Object $first -Names @("from_workspace_environment") }

    $reportQualified = Get-PairRoleValue -Rows $rows -ItemType "Report" -FieldPrefix "qualified_name"
    $reportName = Get-PairRoleValue -Rows $rows -ItemType "Report" -FieldPrefix "item_name"
    $semanticModelQualified = Get-PairRoleValue -Rows $rows -ItemType "SemanticModel" -FieldPrefix "qualified_name"
    $semanticModelName = Get-PairRoleValue -Rows $rows -ItemType "SemanticModel" -FieldPrefix "item_name"
    $sqlEndpointQualified = Get-PairRoleValue -Rows $rows -ItemType "SQLEndpoint" -FieldPrefix "qualified_name"
    $sqlEndpointName = Get-PairRoleValue -Rows $rows -ItemType "SQLEndpoint" -FieldPrefix "item_name"
    $lakehouseQualified = Get-PairRoleValue -Rows $rows -ItemType "Lakehouse" -FieldPrefix "qualified_name"
    $lakehouseName = Get-PairRoleValue -Rows $rows -ItemType "Lakehouse" -FieldPrefix "item_name"

    $reviewTarget = [pscustomobject]@{
        review_target_id = $reviewTargetId
        priority_score = $priorityScore
        priority_band = $priorityBand
        closure_opportunity = $closureOpportunity
        relationship_family = $relationshipFamily
        relationship_types = $relationshipTypes
        canonical_pair_key = $group.pair_key
        edge_count = @($rows).Count
        edge_ids = $edgeIds
        edge_keys = $edgeKeys
        workspace_name = $workspaceName
        workspace_environment = $workspaceEnvironment
        report_qualified_name = $reportQualified
        semantic_model_qualified_name = $semanticModelQualified
        sql_endpoint_qualified_name = $sqlEndpointQualified
        lakehouse_qualified_name = $lakehouseQualified
        current_evidence = $currentEvidence
        pipeline_activity_evidence_count = @($activityEvidenceRows).Count
        recommended_decision = $recommendedDecision
        human_readonly_action = $humanReadonlyAction
    }

    $reviewTargets.Add($reviewTarget) | Out-Null
    $reviewTargetByPair[$group.pair_key] = $reviewTarget

    if ($closureOpportunity -eq "report_model_binding_requires_metadata") {
        $reportModelRows.Add([pscustomobject]@{
            review_target_id = $reviewTargetId
            priority_score = $priorityScore
            priority_band = $priorityBand
            workspace_name = $workspaceName
            workspace_environment = $workspaceEnvironment
            report_name = $reportName
            report_qualified_name = $reportQualified
            semantic_model_name = $semanticModelName
            semantic_model_qualified_name = $semanticModelQualified
            relationship_types = $relationshipTypes
            edge_count = @($rows).Count
            edge_ids = $edgeIds
            current_evidence = $currentEvidence
            proposed_status = ""
            confirmation_source = ""
            confirmation_evidence = ""
            reviewer = ""
            reviewed_at = ""
            notes = "Confirm report binding metadata before promoting either edge."
        }) | Out-Null
    }
    elseif ($closureOpportunity -eq "sqlendpoint_lakehouse_same_name_candidate") {
        $sqlEndpointLakehouseRows.Add([pscustomobject]@{
            review_target_id = $reviewTargetId
            priority_score = $priorityScore
            priority_band = $priorityBand
            workspace_name = $workspaceName
            workspace_environment = $workspaceEnvironment
            sql_endpoint_name = $sqlEndpointName
            sql_endpoint_qualified_name = $sqlEndpointQualified
            lakehouse_name = $lakehouseName
            lakehouse_qualified_name = $lakehouseQualified
            relationship_types = $relationshipTypes
            edge_count = @($rows).Count
            edge_ids = $edgeIds
            current_evidence = $currentEvidence
            proposed_status = ""
            confirmation_source = ""
            confirmation_evidence = ""
            reviewer = ""
            reviewed_at = ""
            notes = "Confirm this is a platform-generated lakehouse SQL endpoint relationship, not only a same-name heuristic."
        }) | Out-Null
    }

    $readonlyRows.Add([pscustomobject]@{
        review_target_id = $reviewTargetId
        priority_score = $priorityScore
        priority_band = $priorityBand
        closure_opportunity = $closureOpportunity
        relationship_family = $relationshipFamily
        relationship_types = $relationshipTypes
        workspace_name = $workspaceName
        workspace_environment = $workspaceEnvironment
        target_report = $reportQualified
        target_semantic_model = $semanticModelQualified
        target_sql_endpoint = $sqlEndpointQualified
        target_lakehouse = $lakehouseQualified
        edge_count = @($rows).Count
        edge_ids = $edgeIds
        human_readonly_action = $humanReadonlyAction
        decision_template_path = $OutputDecisionTemplatePath
        notes = "Read-only/manual confirmation target. Do not modify Fabric or dependency CSVs from this package alone."
    }) | Out-Null
}

$controlRows = [System.Collections.Generic.List[object]]::new()
$decisionRows = [System.Collections.Generic.List[object]]::new()
$controlIndex = 0
foreach ($edge in ($edgeRows | Sort-Object @{ Expression = { Convert-ToInt (Get-FieldValue -Object $_ -Names @("priority_score")) }; Descending = $true }, edge_id)) {
    $controlIndex++
    $pairKey = Get-FieldValue -Object $edge -Names @("canonical_pair_key")
    if (-not $pairKey) { $pairKey = Get-FieldValue -Object $edge -Names @("edge_key") }
    $target = $reviewTargetByPair[$pairKey]
    $d2Id = "D2C{0:0000}" -f $controlIndex

    $controlRows.Add([pscustomobject]@{
        d2_id = $d2Id
        review_target_id = $target.review_target_id
        edge_id = Get-FieldValue -Object $edge -Names @("edge_id")
        priority_score = Get-FieldValue -Object $edge -Names @("priority_score")
        priority_band = Get-FieldValue -Object $edge -Names @("priority_band")
        closure_opportunity = $target.closure_opportunity
        relationship_family = Get-FieldValue -Object $edge -Names @("relationship_family")
        relationship_type = Get-FieldValue -Object $edge -Names @("relationship_type")
        from_item_type = Get-FieldValue -Object $edge -Names @("from_item_type")
        from_qualified_name = Get-FieldValue -Object $edge -Names @("from_qualified_name")
        to_item_type = Get-FieldValue -Object $edge -Names @("to_item_type")
        to_qualified_name = Get-FieldValue -Object $edge -Names @("to_qualified_name")
        current_confidence = Get-FieldValue -Object $edge -Names @("current_confidence")
        current_evidence = Get-FieldValue -Object $edge -Names @("current_evidence")
        canonical_pair_key = $pairKey
        paired_edge_count = $target.edge_count
        recommended_d2_decision = $target.recommended_decision
        needs_external_readonly = "yes"
        readonly_plan_path = $OutputReadonlyPlanPath
        decision_template_path = $OutputDecisionTemplatePath
    }) | Out-Null

    $decisionRows.Add([pscustomobject]@{
        d2_id = $d2Id
        review_target_id = $target.review_target_id
        edge_id = Get-FieldValue -Object $edge -Names @("edge_id")
        relationship_family = Get-FieldValue -Object $edge -Names @("relationship_family")
        relationship_type = Get-FieldValue -Object $edge -Names @("relationship_type")
        from_qualified_name = Get-FieldValue -Object $edge -Names @("from_qualified_name")
        to_qualified_name = Get-FieldValue -Object $edge -Names @("to_qualified_name")
        current_confidence = Get-FieldValue -Object $edge -Names @("current_confidence")
        closure_opportunity = $target.closure_opportunity
        proposed_status = ""
        allowed_statuses = "confirmed; rejected; access_denied; not_available; dynamic_reference; manual_review_required"
        confirmed_relationship_type = Get-FieldValue -Object $edge -Names @("relationship_type")
        confirmation_source = ""
        confirmation_evidence = ""
        reviewer = ""
        reviewed_at = ""
        next_action = $target.recommended_decision
        notes = "Fill this row before treating the likely dependency as closed. Do not use likely rows as hard orchestration rules."
    }) | Out-Null
}

$summaryRows = [System.Collections.Generic.List[object]]::new()
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D2 closure control rows"; row_count = @($controlRows).Count; notes = "One row per likely dependency edge." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D2 review targets"; row_count = @($reviewTargets).Count; notes = "Canonical review targets after pairing inverse/same-object edges." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Report/model binding review targets"; row_count = @($reportModelRows).Count; notes = "One row per report-semantic model pair." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "SQL endpoint/lakehouse review targets"; row_count = @($sqlEndpointLakehouseRows).Count; notes = "One row per same-name SQL endpoint/lakehouse pair." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "External read-only action rows"; row_count = @($readonlyRows).Count; notes = "One read-only/manual action per review target." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D2 item blocker rows"; row_count = @($itemRows).Count; notes = "Rows from the base D2 item queue." }) | Out-Null
foreach ($group in @($controlRows | Group-Object closure_opportunity | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "closure_opportunity"; group_key = $group.Name; row_count = $group.Count; notes = "D2 edges grouped by closure path." }) | Out-Null
}
foreach ($group in @($controlRows | Group-Object relationship_type | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "relationship_type"; group_key = $group.Name; row_count = $group.Count; notes = "D2 edges grouped by dependency relationship type." }) | Out-Null
}
foreach ($group in @($reviewTargets | Group-Object closure_opportunity | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "review_target_closure_opportunity"; group_key = $group.Name; row_count = $group.Count; notes = "Canonical review targets grouped by closure path." }) | Out-Null
}

$controlColumns = @(
    "d2_id", "review_target_id", "edge_id", "priority_score", "priority_band",
    "closure_opportunity", "relationship_family", "relationship_type",
    "from_item_type", "from_qualified_name", "to_item_type", "to_qualified_name",
    "current_confidence", "current_evidence", "canonical_pair_key", "paired_edge_count",
    "recommended_d2_decision", "needs_external_readonly", "readonly_plan_path",
    "decision_template_path"
)
$reportColumns = @(
    "review_target_id", "priority_score", "priority_band", "workspace_name",
    "workspace_environment", "report_name", "report_qualified_name", "semantic_model_name",
    "semantic_model_qualified_name", "relationship_types", "edge_count", "edge_ids",
    "current_evidence", "proposed_status", "confirmation_source", "confirmation_evidence",
    "reviewer", "reviewed_at", "notes"
)
$sqlColumns = @(
    "review_target_id", "priority_score", "priority_band", "workspace_name",
    "workspace_environment", "sql_endpoint_name", "sql_endpoint_qualified_name",
    "lakehouse_name", "lakehouse_qualified_name", "relationship_types", "edge_count",
    "edge_ids", "current_evidence", "proposed_status", "confirmation_source",
    "confirmation_evidence", "reviewer", "reviewed_at", "notes"
)
$decisionColumns = @(
    "d2_id", "review_target_id", "edge_id", "relationship_family", "relationship_type",
    "from_qualified_name", "to_qualified_name", "current_confidence", "closure_opportunity",
    "proposed_status", "allowed_statuses", "confirmed_relationship_type", "confirmation_source",
    "confirmation_evidence", "reviewer", "reviewed_at", "next_action", "notes"
)
$readonlyColumns = @(
    "review_target_id", "priority_score", "priority_band", "closure_opportunity",
    "relationship_family", "relationship_types", "workspace_name", "workspace_environment",
    "target_report", "target_semantic_model", "target_sql_endpoint", "target_lakehouse",
    "edge_count", "edge_ids", "human_readonly_action", "decision_template_path", "notes"
)
$summaryColumns = @("summary_scope", "group_key", "row_count", "notes")

Export-Rows -Rows @($controlRows) -Columns $controlColumns -Path $OutputControlQueuePath
Export-Rows -Rows @($reportModelRows) -Columns $reportColumns -Path $OutputReportModelCandidatePath
Export-Rows -Rows @($sqlEndpointLakehouseRows) -Columns $sqlColumns -Path $OutputSqlEndpointLakehouseCandidatePath
Export-Rows -Rows @($decisionRows) -Columns $decisionColumns -Path $OutputDecisionTemplatePath
Export-Rows -Rows @($readonlyRows) -Columns $readonlyColumns -Path $OutputReadonlyPlanPath
Export-Rows -Rows @($summaryRows) -Columns $summaryColumns -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D2 Closure Control") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated by backend/scripts/40_build_d2_closure_control.ps1 from local project artifacts only.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Start D2 closure without forcing likely dependency edges into confirmed state. Every D2 edge must be closed as confirmed, rejected, access_denied, not_available, dynamic_reference, or manual_review_required before it can be used as a hard orchestration rule.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- $OutputControlQueuePath") | Out-Null
$doc.Add("- $OutputReportModelCandidatePath") | Out-Null
$doc.Add("- $OutputSqlEndpointLakehouseCandidatePath") | Out-Null
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
$doc.Add("- Report/model edges are reviewed by canonical pair, not as two independent inverse rows.") | Out-Null
$doc.Add("- SQL endpoint/lakehouse rows remain candidates until platform metadata or owner-approved evidence confirms the relationship.") | Out-Null
$doc.Add("- Likely D2 rows stay visible for review but must not be used as hard orchestration dependencies until closed with evidence.") | Out-Null
$doc.Add("- After approved decisions are recorded, rebuild dependencies, graph, orchestration v2, D2, Phase 12, and Phase 13 to measure blocker reduction.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Next Human Step") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('Review `analysis/d2_external_readonly_action_plan.csv`, starting with critical/high SQL endpoint-lakehouse candidates and then report/model binding pairs.') | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D2 closure control built."
Write-Host "Closure control rows: $(@($controlRows).Count)"
Write-Host "Canonical review targets: $(@($reviewTargets).Count)"
Write-Host "Report/model targets: $(@($reportModelRows).Count)"
Write-Host "SQL endpoint/lakehouse targets: $(@($sqlEndpointLakehouseRows).Count)"
