# Phase 27 - D2 package: the cleanup-plan category for dependency edges
# still resting on "likely" (name-based heuristic) evidence -- packages
# them into an item/edge queue plus a manual confirmation template.
# Purely local.
# Writes: $OutputItemQueuePath, $OutputEdgeQueuePath, $OutputSummaryPath,
# $OutputTemplatePath, $OutputReadonlyTargetsPath, $OutputDocPath.
param(
    [string]$DependenciesPath = (Join-Path $PSScriptRoot "../../index/dependencies.csv"),
    [string]$CleanupQueuePath = (Join-Path $PSScriptRoot "../../analysis/likely_conflict_cleanup_queue.csv"),
    [string]$EvidenceHardeningQueuePath = (Join-Path $PSScriptRoot "../../analysis/evidence_hardening_queue.csv"),
    [string]$OrchestrationV2PlanPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_v2_plan.csv"),
    [string]$IdealExecutionEdgesPath = (Join-Path $PSScriptRoot "../../analysis/ideal_execution_edges.csv"),
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$OutputItemQueuePath = (Join-Path $PSScriptRoot "../../analysis/d2_likely_dependency_item_queue.csv"),
    [string]$OutputEdgeQueuePath = (Join-Path $PSScriptRoot "../../analysis/d2_likely_dependency_edge_queue.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d2_likely_dependency_summary.csv"),
    [string]$OutputTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d2_dependency_confirmation_template.csv"),
    [string]$OutputReadonlyTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d2_readonly_confirmation_targets.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/24_d2_likely_dependency_confirmation.md")
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

function Get-EdgeKey {
    param([string]$From, [string]$To, [string]$RelationshipType)
    return ((Normalize-Key -Value $From) + "|" + (Normalize-Key -Value $To) + "|" + (Normalize-Key -Value $RelationshipType))
}

function Get-CanonicalPairKey {
    param([string]$From, [string]$To, [string]$RelationshipType)
    $family = Get-RelationshipFamily -RelationshipType $RelationshipType
    $a = Normalize-Key -Value $From
    $b = Normalize-Key -Value $To
    $ordered = @($a, $b) | Sort-Object
    return ($family + "|" + ($ordered -join "|"))
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
    if ($PriorityScore -ge 105) { return "high" }
    if ($PriorityScore -ge 80) { return "medium" }
    return "low"
}

function Get-RelationshipFamily {
    param([string]$RelationshipType)
    switch ($RelationshipType) {
        "uses_model" { return "report_model_binding" }
        "serves_report" { return "report_model_binding" }
        "depends_on" { return "item_dependency" }
        default { return "dependency" }
    }
}

function Get-RecommendedMethod {
    param([string]$RelationshipType)
    switch ($RelationshipType) {
        "uses_model" { return "Confirm the report semantic-model binding from Fabric/Power BI report metadata or report definition." }
        "serves_report" { return "Confirm the inverse semantic-model-to-report relationship by validating the report binding." }
        "depends_on" { return "Confirm the dependency from item definition, activity/code reference, object lineage, Azure DevOps, SharePoint, OneLake, or owner evidence." }
        default { return "Confirm the relationship from direct platform metadata or owner-approved technical evidence." }
    }
}

function Get-PreferredConfirmationSource {
    param([string]$RelationshipType)
    switch ($RelationshipType) {
        "uses_model" { return "Fabric/Power BI report binding metadata or report definition" }
        "serves_report" { return "Fabric/Power BI report binding metadata or report definition" }
        "depends_on" { return "Fabric item definition, Azure DevOps code, SharePoint design docs, OneLake path evidence, or owner-approved evidence" }
        default { return "Direct platform metadata or owner-approved evidence" }
    }
}

function Get-ReadonlyMethod {
    param([string]$RelationshipType)
    switch ($RelationshipType) {
        "uses_model" { return "Read report metadata/definition and verify the bound semantic model ID/name/workspace." }
        "serves_report" { return "Read the related report metadata/definition; confirm it points to this semantic model." }
        "depends_on" { return "Read the upstream/downstream item definitions and compare invoked item, connection, source, sink, or object references." }
        default { return "Read the relevant item metadata and compare relationship evidence." }
    }
}

function Parse-QualifiedName {
    param([string]$QualifiedName)
    $parts = @($QualifiedName -split "\s*/\s*")
    $workspaceName = ""
    $itemType = ""
    $itemName = $QualifiedName
    if ($parts.Count -ge 3) {
        $workspaceName = $parts[0]
        $itemType = $parts[1]
        $itemName = ($parts[2..($parts.Count - 1)] -join " / ")
    }
    return [pscustomobject]@{
        workspace_name = $workspaceName
        item_type = $itemType
        item_name = $itemName
    }
}

function Escape-MdCell {
    param([string]$Value)
    if (-not $Value) { return "" }
    return (($Value -replace "\|", "/") -replace "`r?`n", " ").Trim()
}

foreach ($path in @($DependenciesPath, $CleanupQueuePath, $EvidenceHardeningQueuePath, $OrchestrationV2PlanPath, $ItemsPath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$dependencyRows = @(Import-Csv -Path $DependenciesPath)
$cleanupRows = @(Import-Csv -Path $CleanupQueuePath)
$hardeningRows = @(Import-Csv -Path $EvidenceHardeningQueuePath)
$v2PlanRows = @(Import-Csv -Path $OrchestrationV2PlanPath)
$itemRows = @(Import-Csv -Path $ItemsPath)
$idealEdgeRows = Import-OptionalCsv -Path $IdealExecutionEdgesPath

$itemsByQualifiedName = @{}
foreach ($row in $itemRows) {
    Set-FirstMapValue -Map $itemsByQualifiedName -Key (Get-FieldValue -Object $row -Names @("qualified_name", "item_qualified_name")) -Value $row
}

$v2ByQualifiedName = @{}
foreach ($row in $v2PlanRows) {
    Set-FirstMapValue -Map $v2ByQualifiedName -Key (Get-FieldValue -Object $row -Names @("qualified_name", "item_qualified_name")) -Value $row
}

$d2ItemRows = @($cleanupRows | Where-Object { $_.phase_id -eq "D2" })
$d2ItemByQualifiedName = @{}
foreach ($row in $d2ItemRows) {
    Set-FirstMapValue -Map $d2ItemByQualifiedName -Key (Get-FieldValue -Object $row -Names @("item_qualified_name", "qualified_name")) -Value $row
}

$hardeningByEdge = @{}
foreach ($row in ($hardeningRows | Where-Object { $_.issue_type -eq "weak_relationship_confidence" })) {
    $edgeKey = Get-EdgeKey -From (Get-FieldValue -Object $row -Names @("from_qualified_name")) -To (Get-FieldValue -Object $row -Names @("to_qualified_name")) -RelationshipType (Get-FieldValue -Object $row -Names @("relationship_type"))
    if ($edgeKey -and -not $hardeningByEdge.ContainsKey($edgeKey)) { $hardeningByEdge[$edgeKey] = $row }
}

$idealByEdge = @{}
foreach ($row in $idealEdgeRows) {
    $edgeKey = Get-EdgeKey -From (Get-FieldValue -Object $row -Names @("upstream_qualified_name")) -To (Get-FieldValue -Object $row -Names @("downstream_qualified_name")) -RelationshipType (Get-FieldValue -Object $row -Names @("original_relationship_type"))
    if ($edgeKey -and -not $idealByEdge.ContainsKey($edgeKey)) { $idealByEdge[$edgeKey] = $row }
}

$relatedEdgesByItem = @{}
$likelyEdges = @($dependencyRows | Where-Object { $_.confidence -eq "likely" })
foreach ($row in $likelyEdges) {
    foreach ($qualifiedName in @((Get-FieldValue -Object $row -Names @("from_qualified_name")), (Get-FieldValue -Object $row -Names @("to_qualified_name")))) {
        $key = Normalize-Key -Value $qualifiedName
        if (-not $key) { continue }
        if (-not $relatedEdgesByItem.ContainsKey($key)) {
            $relatedEdgesByItem[$key] = [System.Collections.Generic.List[object]]::new()
        }
        $relatedEdgesByItem[$key].Add($row) | Out-Null
    }
}

$edgeQueueRows = [System.Collections.Generic.List[object]]::new()
$templateRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()
$edgeSequence = 0

foreach ($edge in $likelyEdges) {
    $edgeSequence += 1
    $fromQualified = Get-FieldValue -Object $edge -Names @("from_qualified_name")
    $toQualified = Get-FieldValue -Object $edge -Names @("to_qualified_name")
    $relationshipType = Get-FieldValue -Object $edge -Names @("relationship_type")
    $edgeKey = Get-EdgeKey -From $fromQualified -To $toQualified -RelationshipType $relationshipType
    $canonicalPairKey = Get-CanonicalPairKey -From $fromQualified -To $toQualified -RelationshipType $relationshipType

    $fromItem = Get-MapValue -Map $itemsByQualifiedName -Key $fromQualified
    $toItem = Get-MapValue -Map $itemsByQualifiedName -Key $toQualified
    $fromV2 = Get-MapValue -Map $v2ByQualifiedName -Key $fromQualified
    $toV2 = Get-MapValue -Map $v2ByQualifiedName -Key $toQualified
    $fromD2 = Get-MapValue -Map $d2ItemByQualifiedName -Key $fromQualified
    $toD2 = Get-MapValue -Map $d2ItemByQualifiedName -Key $toQualified

    $fromParsed = Parse-QualifiedName -QualifiedName $fromQualified
    $toParsed = Parse-QualifiedName -QualifiedName $toQualified

    $fromPriority = Convert-ToInt (Get-FieldValue -Object $fromD2 -Names @("priority_score"))
    $toPriority = Convert-ToInt (Get-FieldValue -Object $toD2 -Names @("priority_score"))
    $priorityScore = [math]::Max($fromPriority, $toPriority)
    if ($priorityScore -eq 0) { $priorityScore = 70 }
    if ($relationshipType -eq "depends_on") { $priorityScore += 15 }
    elseif ($relationshipType -in @("uses_model", "serves_report")) { $priorityScore += 5 }
    if ((Get-FieldValue -Object $fromItem -Names @("workspace_environment")) -eq "PRO" -or (Get-FieldValue -Object $toItem -Names @("workspace_environment")) -eq "PRO") {
        $priorityScore += 5
    }

    $hardening = $null
    if ($hardeningByEdge.ContainsKey($edgeKey)) { $hardening = $hardeningByEdge[$edgeKey] }
    $idealEdge = $null
    if ($idealByEdge.ContainsKey($edgeKey)) { $idealEdge = $idealByEdge[$edgeKey] }

    $recommendedMethod = Get-RecommendedMethod -RelationshipType $relationshipType
    $preferredSource = Get-FieldValue -Object $hardening -Names @("preferred_confirmation_source")
    if (-not $preferredSource) { $preferredSource = Get-PreferredConfirmationSource -RelationshipType $relationshipType }
    $readonlyMethod = Get-ReadonlyMethod -RelationshipType $relationshipType

    $fromWorkspaceName = Get-FieldValue -Object $fromItem -Names @("workspace_name")
    if (-not $fromWorkspaceName) { $fromWorkspaceName = $fromParsed.workspace_name }
    $fromWorkspaceEnvironment = Get-FieldValue -Object $fromItem -Names @("workspace_environment")
    $fromItemType = Get-FieldValue -Object $fromItem -Names @("item_type")
    if (-not $fromItemType) { $fromItemType = $fromParsed.item_type }
    $fromItemName = Get-FieldValue -Object $fromItem -Names @("item_name")
    if (-not $fromItemName) { $fromItemName = $fromParsed.item_name }

    $toWorkspaceName = Get-FieldValue -Object $toItem -Names @("workspace_name")
    if (-not $toWorkspaceName) { $toWorkspaceName = $toParsed.workspace_name }
    $toWorkspaceEnvironment = Get-FieldValue -Object $toItem -Names @("workspace_environment")
    $toItemType = Get-FieldValue -Object $toItem -Names @("item_type")
    if (-not $toItemType) { $toItemType = $toParsed.item_type }
    $toItemName = Get-FieldValue -Object $toItem -Names @("item_name")
    if (-not $toItemName) { $toItemName = $toParsed.item_name }

    $edgeId = "D2E{0:D4}" -f $edgeSequence
    $edgeQueueRows.Add([pscustomobject]@{
        edge_id = $edgeId
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        relationship_family = Get-RelationshipFamily -RelationshipType $relationshipType
        relationship_type = $relationshipType
        from_workspace_name = $fromWorkspaceName
        from_workspace_environment = $fromWorkspaceEnvironment
        from_item_type = $fromItemType
        from_item_name = $fromItemName
        from_qualified_name = $fromQualified
        to_workspace_name = $toWorkspaceName
        to_workspace_environment = $toWorkspaceEnvironment
        to_item_type = $toItemType
        to_item_name = $toItemName
        to_qualified_name = $toQualified
        current_confidence = "likely"
        source_system = Get-FieldValue -Object $edge -Names @("source_system")
        current_evidence = Limit-Text -Text (Get-FieldValue -Object $edge -Names @("evidence")) -MaxLength 700
        current_notes = Limit-Text -Text (Get-FieldValue -Object $edge -Names @("notes")) -MaxLength 700
        hardening_priority_score = Convert-ToInt (Get-FieldValue -Object $hardening -Names @("priority_score"))
        hardening_blocker_reason = Limit-Text -Text (Get-FieldValue -Object $hardening -Names @("blocker_reason")) -MaxLength 500
        preferred_confirmation_source = $preferredSource
        ideal_plan_relationship_type = Get-FieldValue -Object $idealEdge -Names @("plan_relationship_type")
        from_v2_status = Get-FieldValue -Object $fromV2 -Names @("v2_status")
        to_v2_status = Get-FieldValue -Object $toV2 -Names @("v2_status")
        from_successor_count = Convert-ToInt (Get-FieldValue -Object $fromV2 -Names @("successor_count"))
        to_successor_count = Convert-ToInt (Get-FieldValue -Object $toV2 -Names @("successor_count"))
        from_incoming_likely_edges = Convert-ToInt (Get-FieldValue -Object $fromV2 -Names @("incoming_likely_edges"))
        from_outgoing_likely_edges = Convert-ToInt (Get-FieldValue -Object $fromV2 -Names @("outgoing_likely_edges"))
        to_incoming_likely_edges = Convert-ToInt (Get-FieldValue -Object $toV2 -Names @("incoming_likely_edges"))
        to_outgoing_likely_edges = Convert-ToInt (Get-FieldValue -Object $toV2 -Names @("outgoing_likely_edges"))
        canonical_pair_key = $canonicalPairKey
        edge_key = $edgeKey
        recommended_method = $recommendedMethod
        d2_gate_to_close = "Confirm, reject, or explicitly block this likely relationship with direct evidence."
    }) | Out-Null

    $templateRows.Add([pscustomobject]@{
        edge_id = $edgeId
        relationship_family = Get-RelationshipFamily -RelationshipType $relationshipType
        relationship_type = $relationshipType
        from_qualified_name = $fromQualified
        to_qualified_name = $toQualified
        current_confidence = "likely"
        current_evidence = Limit-Text -Text (Get-FieldValue -Object $edge -Names @("evidence")) -MaxLength 700
        proposed_status = ""
        confirmed_relationship_type = $relationshipType
        confirmation_source = ""
        confirmation_evidence = ""
        reviewer = ""
        reviewed_at = ""
        notes = "D2 template row. Set proposed_status to confirmed, rejected, or blocked before applying any future dependency update."
    }) | Out-Null

    $readonlyRows.Add([pscustomobject]@{
        edge_id = $edgeId
        priority_score = $priorityScore
        priority_band = Get-PriorityBand -PriorityScore $priorityScore
        relationship_family = Get-RelationshipFamily -RelationshipType $relationshipType
        relationship_type = $relationshipType
        from_qualified_name = $fromQualified
        to_qualified_name = $toQualified
        readonly_method = $readonlyMethod
        preferred_confirmation_source = $preferredSource
        current_evidence = Limit-Text -Text (Get-FieldValue -Object $edge -Names @("evidence")) -MaxLength 700
        template_path = $OutputTemplatePath
        notes = "Read-only/manual confirmation target. Do not modify Fabric or dependency CSVs from this package alone."
    }) | Out-Null
}

$itemQueueRows = [System.Collections.Generic.List[object]]::new()
foreach ($row in $d2ItemRows) {
    $qualifiedName = Get-FieldValue -Object $row -Names @("item_qualified_name", "qualified_name")
    $item = Get-MapValue -Map $itemsByQualifiedName -Key $qualifiedName
    $v2 = Get-MapValue -Map $v2ByQualifiedName -Key $qualifiedName
    $relatedKey = Normalize-Key -Value $qualifiedName
    $relatedEdges = @()
    if ($relatedKey -and $relatedEdgesByItem.ContainsKey($relatedKey)) {
        $relatedEdges = @($relatedEdgesByItem[$relatedKey])
    }
    $incomingEdges = @($relatedEdges | Where-Object { (Get-FieldValue -Object $_ -Names @("to_qualified_name")) -eq $qualifiedName })
    $outgoingEdges = @($relatedEdges | Where-Object { (Get-FieldValue -Object $_ -Names @("from_qualified_name")) -eq $qualifiedName })
    $sampleEdges = @($relatedEdges | Select-Object -First 8 | ForEach-Object {
        (Get-FieldValue -Object $_ -Names @("relationship_type")) + ": " + (Get-FieldValue -Object $_ -Names @("from_qualified_name")) + " -> " + (Get-FieldValue -Object $_ -Names @("to_qualified_name"))
    })

    $itemQueueRows.Add([pscustomobject]@{
        priority_score = Convert-ToInt (Get-FieldValue -Object $row -Names @("priority_score"))
        priority_band = Get-PriorityBand -PriorityScore (Convert-ToInt (Get-FieldValue -Object $row -Names @("priority_score")))
        workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $item -Names @("workspace_environment")
        item_type = Get-FieldValue -Object $row -Names @("item_type")
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        item_qualified_name = $qualifiedName
        technical_id = Get-FieldValue -Object $item -Names @("technical_id")
        related_likely_edge_count = $relatedEdges.Count
        incoming_likely_edge_count = $incomingEdges.Count
        outgoing_likely_edge_count = $outgoingEdges.Count
        relationship_types = ((@($relatedEdges | Group-Object relationship_type | Sort-Object Count -Descending | ForEach-Object { "$($_.Name)=$($_.Count)" })) -join "; ")
        sample_likely_edges = Limit-Text -Text ($sampleEdges -join "; ") -MaxLength 1200
        v2_status = Get-FieldValue -Object $v2 -Names @("v2_status")
        successor_count = Convert-ToInt (Get-FieldValue -Object $v2 -Names @("successor_count"))
        incoming_likely_edges = Convert-ToInt (Get-FieldValue -Object $v2 -Names @("incoming_likely_edges"))
        outgoing_likely_edges = Convert-ToInt (Get-FieldValue -Object $v2 -Names @("outgoing_likely_edges"))
        v2_recommended_next_action = Limit-Text -Text (Get-FieldValue -Object $v2 -Names @("v2_recommended_next_action")) -MaxLength 700
        recommended_method = "Confirm or reject every related likely dependency edge before this item becomes an operational sequencing rule."
        edge_queue_path = $OutputEdgeQueuePath
        template_path = $OutputTemplatePath
    }) | Out-Null
}

$itemColumns = @(
    "priority_score", "priority_band", "workspace_name", "workspace_environment", "item_type", "item_name",
    "item_qualified_name", "technical_id", "related_likely_edge_count", "incoming_likely_edge_count",
    "outgoing_likely_edge_count", "relationship_types", "sample_likely_edges", "v2_status", "successor_count",
    "incoming_likely_edges", "outgoing_likely_edges", "v2_recommended_next_action", "recommended_method",
    "edge_queue_path", "template_path"
)

$edgeColumns = @(
    "edge_id", "priority_score", "priority_band", "relationship_family", "relationship_type",
    "from_workspace_name", "from_workspace_environment", "from_item_type", "from_item_name", "from_qualified_name",
    "to_workspace_name", "to_workspace_environment", "to_item_type", "to_item_name", "to_qualified_name",
    "current_confidence", "source_system", "current_evidence", "current_notes", "hardening_priority_score",
    "hardening_blocker_reason", "preferred_confirmation_source", "ideal_plan_relationship_type",
    "from_v2_status", "to_v2_status", "from_successor_count", "to_successor_count",
    "from_incoming_likely_edges", "from_outgoing_likely_edges", "to_incoming_likely_edges",
    "to_outgoing_likely_edges", "canonical_pair_key", "edge_key", "recommended_method", "d2_gate_to_close"
)

$templateColumns = @(
    "edge_id", "relationship_family", "relationship_type", "from_qualified_name", "to_qualified_name",
    "current_confidence", "current_evidence", "proposed_status", "confirmed_relationship_type",
    "confirmation_source", "confirmation_evidence", "reviewer", "reviewed_at", "notes"
)

$readonlyColumns = @(
    "edge_id", "priority_score", "priority_band", "relationship_family", "relationship_type",
    "from_qualified_name", "to_qualified_name", "readonly_method", "preferred_confirmation_source",
    "current_evidence", "template_path", "notes"
)

$itemQueueSorted = @($itemQueueRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, workspace_name, item_type, item_name)
$edgeQueueSorted = @($edgeQueueRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, relationship_family, from_workspace_name, from_item_name)
$templateSorted = @($templateRows | Sort-Object edge_id)
$readonlySorted = @($readonlyRows | Sort-Object @{ Expression = { [int]$_.priority_score }; Descending = $true }, edge_id)

Export-Rows -Rows $itemQueueSorted -Columns $itemColumns -Path $OutputItemQueuePath
Export-Rows -Rows $edgeQueueSorted -Columns $edgeColumns -Path $OutputEdgeQueuePath
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
    $Rows.Add([pscustomobject]@{
        summary_scope = $SummaryScope
        group_key = $GroupKey
        row_count = $count
        high_or_critical_count = $highCount
        max_priority_score = $maxPriority
        notes = $Notes
    }) | Out-Null
}

Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D2 item blockers" -GroupRows @($itemQueueRows) -Notes "Items from analysis/likely_conflict_cleanup_queue.csv phase D2."
Add-SummaryRow -Rows $summaryRows -SummaryScope "total" -GroupKey "D2 likely dependency edges" -GroupRows @($edgeQueueRows) -Notes "Likely dependency edges from index/dependencies.csv."
foreach ($group in ($edgeQueueRows | Group-Object relationship_type | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "relationship_type" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "Likely edges grouped by relationship type."
}
foreach ($group in ($edgeQueueRows | Group-Object relationship_family | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "relationship_family" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "Likely edges grouped by confirmation family."
}
foreach ($group in ($itemQueueRows | Group-Object item_type | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "item_type" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D2 item blockers grouped by item type."
}
foreach ($group in ($edgeQueueRows | Group-Object priority_band | Sort-Object Count -Descending)) {
    Add-SummaryRow -Rows $summaryRows -SummaryScope "priority_band_edges" -GroupKey $group.Name -GroupRows @($group.Group) -Notes "D2 likely edges grouped by priority band."
}

Export-Rows -Rows @($summaryRows) -Columns @("summary_scope", "group_key", "row_count", "high_or_critical_count", "max_priority_score", "notes") -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$generatedAt = (Get-Date).ToString("s")
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D2 Likely Dependency Confirmation Package") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated: $generatedAt") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D2 focuses on dependency edges that are currently inferred as likely. The package is local-only and does not modify Fabric, Power BI, SQL, OneLake, schedules, deployment pipelines, repositories, or dependency CSVs.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Current Baseline") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- D2 item blocker rows: $($itemQueueRows.Count)") | Out-Null
$doc.Add("- D2 likely dependency edge rows: $($edgeQueueRows.Count)") | Out-Null
$doc.Add("- Confirmation template rows: $($templateRows.Count)") | Out-Null
$doc.Add("- Read-only/manual target rows: $($readonlyRows.Count)") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Relationship Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($edgeQueueRows | Group-Object relationship_type | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Item Blocker Breakdown") | Out-Null
$doc.Add("") | Out-Null
foreach ($group in ($itemQueueRows | Group-Object item_type | Sort-Object Count -Descending)) {
    $doc.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Top Priority Edges") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("| Priority | Relationship | From | To | Confirmation source |") | Out-Null
$doc.Add("| --- | --- | --- | --- | --- |") | Out-Null
foreach ($row in ($edgeQueueSorted | Select-Object -First 15)) {
    $doc.Add("| $($row.priority_score) | $(Escape-MdCell $row.relationship_type) | $(Escape-MdCell $row.from_qualified_name) | $(Escape-MdCell $row.to_qualified_name) | $(Escape-MdCell $row.preferred_confirmation_source) |") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- analysis/d2_likely_dependency_item_queue.csv") | Out-Null
$doc.Add("- analysis/d2_likely_dependency_edge_queue.csv") | Out-Null
$doc.Add("- analysis/d2_likely_dependency_summary.csv") | Out-Null
$doc.Add("- analysis/d2_dependency_confirmation_template.csv") | Out-Null
$doc.Add("- analysis/d2_readonly_confirmation_targets.csv") | Out-Null
$doc.Add("- docs/24_d2_likely_dependency_confirmation.md") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## How To Close D2 Rows") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('1. Work `analysis/d2_likely_dependency_edge_queue.csv` in priority order.') | Out-Null
$doc.Add('2. Use `analysis/d2_dependency_confirmation_template.csv` to mark each edge as confirmed, rejected, or blocked.') | Out-Null
$doc.Add("3. For report/model bindings, confirm from Fabric or Power BI report binding metadata instead of relying on same-name heuristics.") | Out-Null
$doc.Add("4. For item dependencies, confirm from item definition, code, activity invocation, source/sink mapping, object lineage, Azure DevOps, SharePoint, OneLake, or owner-approved evidence.") | Out-Null
$doc.Add("5. Only after human approval should confirmed/rejected evidence be applied to dependency sources and rebuilt through Phases B, C, and D.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Suggested Rebuild After Approved Evidence") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('```powershell') | Out-Null
$doc.Add("pwsh -NoLogo -File backend/scripts/99_refresh_lineage_project.ps1 -Mode local-artifacts -SkipStandalone") | Out-Null
$doc.Add('```') | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Gate") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D2 is closed only when high-priority likely dependency edges are confirmed, rejected, or explicitly blocked with evidence. This package is evidence preparation and does not approve orchestration rules.") | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D2 likely dependency confirmation package completed."
Write-Host "Item blocker rows: $($itemQueueRows.Count)"
Write-Host "Likely dependency edge rows: $($edgeQueueRows.Count)"
Write-Host "Output: $OutputEdgeQueuePath"
