# Phase 22 - Evidence hardening queue: combines every prior phase's
# unconfirmed/likely edges, coverage gaps, and metadata gaps into one
# prioritized queue of what would most improve overall lineage confidence
# if manually confirmed next. Purely local, no API calls.
# Writes: $OutputQueuePath, $OutputSummaryPath, $OutputDocPath.
param(
    [string]$DependenciesPath = (Join-Path $PSScriptRoot "../../index/dependencies.csv"),
    [string]$GraphEdgesPath = (Join-Path $PSScriptRoot "../../graph/edges.csv"),
    [string]$ObjectImpactPath = (Join-Path $PSScriptRoot "../../analysis/object_impact_index.csv"),
    [string]$ObjectImpactSummaryPath = (Join-Path $PSScriptRoot "../../analysis/object_impact_summary.csv"),
    [string]$ObjectTypeResolutionQueuePath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_resolution_queue.csv"),
    [string]$MetadataGapsPath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_metadata_gaps.csv"),
    [string]$ObjectCoveragePath = (Join-Path $PSScriptRoot "../../analysis/object_level_lineage_coverage.csv"),
    [string]$ManualReviewQueuePath = (Join-Path $PSScriptRoot "../../analysis/manual_lineage_review_queue.csv"),
    [string]$IdealExecutionPlanPath = (Join-Path $PSScriptRoot "../../analysis/ideal_execution_plan.csv"),
    [string]$OutputQueuePath = (Join-Path $PSScriptRoot "../../analysis/evidence_hardening_queue.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/evidence_hardening_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/19_evidence_hardening.md")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$script:ExactObjectTypes = @("table", "view", "stored_procedure", "file", "shortcut", "query")

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
    return 0
}

function Get-WorkspaceFromQualifiedName {
    param([string]$QualifiedName)
    if (-not $QualifiedName) { return "" }
    return ($QualifiedName -split " / ")[0]
}

function Test-ExactObjectType {
    param([string]$Value)
    return (Normalize-Key $Value) -in $script:ExactObjectTypes
}

function Get-PreferredSource {
    param([string]$IssueType, [string]$SourceType)
    if ($IssueType -in @("missing_object_level_lineage", "weak_object_lineage_confidence")) {
        return "Azure DevOps repository or Fabric item definition; SharePoint/OneLake owner evidence if code is not available."
    }
    if ($IssueType -in @("source_object_type_pending", "metadata_access_gap", "ambiguous_object_type")) {
        if ((Normalize-Key $SourceType) -like "*sql*") {
            return "Read-only SQL/Fabric metadata (sys.objects) or owner-approved object catalog evidence."
        }
        return "Fabric metadata, OneLake path inspection, or owner-approved catalog evidence."
    }
    if ($IssueType -eq "weak_relationship_confidence") {
        return "Fabric definition/model binding evidence first; Azure DevOps or SharePoint design evidence second."
    }
    if ($IssueType -eq "orchestration_evidence_blocker") {
        return "Confirmed object-level read/write evidence plus execution history before scheduling."
    }
    return "Local index first, then Azure DevOps, SharePoint, OneLake, and read-only Fabric APIs."
}

function New-QueueKey {
    param(
        [string]$EvidenceArea,
        [string]$IssueType,
        [string]$QualifiedName,
        [string]$ObjectKey,
        [string]$FromName,
        [string]$ToName
    )
    return @($EvidenceArea, $IssueType, $QualifiedName, $ObjectKey, $FromName, $ToName | ForEach-Object { Normalize-Key $_ }) -join "|"
}

function Add-QueueRow {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [string]$EvidenceArea,
        [string]$IssueType,
        [int]$PriorityScore,
        [string]$WorkspaceName = "",
        [string]$WorkspaceEnvironment = "",
        [string]$ItemType = "",
        [string]$ItemName = "",
        [string]$ItemQualifiedName = "",
        [string]$SourceType = "",
        [string]$SourceServer = "",
        [string]$SourceDatabase = "",
        [string]$SchemaName = "",
        [string]$ObjectName = "",
        [string]$ObjectType = "",
        [string]$UsageType = "",
        [string]$RelationshipType = "",
        [string]$FromQualifiedName = "",
        [string]$ToQualifiedName = "",
        [string]$CurrentConfidence = "",
        [string]$EvidenceSource = "",
        [string]$EvidenceText = "",
        [string]$BlockerReason = "",
        [string]$NextAction = ""
    )

    $objectKey = @($SourceType, $SourceServer, $SourceDatabase, $SchemaName, $ObjectName | ForEach-Object { Normalize-Key $_ }) -join "|"
    $key = New-QueueKey -EvidenceArea $EvidenceArea -IssueType $IssueType -QualifiedName $ItemQualifiedName -ObjectKey $objectKey -FromName $FromQualifiedName -ToName $ToQualifiedName
    if ($Seen.ContainsKey($key)) { return }
    $Seen[$key] = $true

    $preferredSource = Get-PreferredSource -IssueType $IssueType -SourceType $SourceType
    $Rows.Add([pscustomobject]@{
        evidence_area = $EvidenceArea
        issue_type = $IssueType
        priority_score = $PriorityScore
        hardening_status = "pending_confirmation"
        workspace_name = $WorkspaceName
        workspace_environment = $WorkspaceEnvironment
        item_type = $ItemType
        item_name = $ItemName
        item_qualified_name = $ItemQualifiedName
        source_type = $SourceType
        source_server = $SourceServer
        source_database = $SourceDatabase
        schema_name = $SchemaName
        object_name = $ObjectName
        object_type = $ObjectType
        usage_type = $UsageType
        relationship_type = $RelationshipType
        from_qualified_name = $FromQualifiedName
        to_qualified_name = $ToQualifiedName
        current_confidence = $CurrentConfidence
        evidence_source = $EvidenceSource
        evidence_text = $EvidenceText
        blocker_reason = $BlockerReason
        preferred_confirmation_source = $preferredSource
        next_action = $NextAction
    }) | Out-Null
}

$dependencies = Import-OptionalCsv -Path $DependenciesPath
$graphEdges = Import-OptionalCsv -Path $GraphEdgesPath
$impactRows = Import-OptionalCsv -Path $ObjectImpactPath
$impactSummaryRows = Import-OptionalCsv -Path $ObjectImpactSummaryPath
$typeQueueRows = Import-OptionalCsv -Path $ObjectTypeResolutionQueuePath
$metadataGapRows = Import-OptionalCsv -Path $MetadataGapsPath
$coverageRows = Import-OptionalCsv -Path $ObjectCoveragePath
$manualReviewRows = Import-OptionalCsv -Path $ManualReviewQueuePath
$idealRows = Import-OptionalCsv -Path $IdealExecutionPlanPath

$impactByObjectKey = @{}
foreach ($row in $impactSummaryRows) {
    $key = Get-FieldValue -Object $row -Names @("object_key")
    if ($key -and -not $impactByObjectKey.ContainsKey($key)) { $impactByObjectKey[$key] = $row }
}

$manualReviewByItem = @{}
foreach ($row in $manualReviewRows) {
    $itemKey = Get-FieldValue -Object $row -Names @("item_qualified_name")
    if ($itemKey -and -not $manualReviewByItem.ContainsKey($itemKey)) { $manualReviewByItem[$itemKey] = $row }
}

$rows = [System.Collections.Generic.List[object]]::new()
$seen = @{}

foreach ($edge in $dependencies) {
    $confidence = Get-FieldValue -Object $edge -Names @("confidence")
    if ((Normalize-Key $confidence) -eq "confirmed") { continue }
    $relationship = Get-FieldValue -Object $edge -Names @("relationship_type")
    $fromName = Get-FieldValue -Object $edge -Names @("from_qualified_name")
    $toName = Get-FieldValue -Object $edge -Names @("to_qualified_name")
    $priority = 70
    if ($relationship -in @("executes", "refreshes", "depends_on")) { $priority += 20 }
    Add-QueueRow -Rows $rows -Seen $seen `
        -EvidenceArea "dependency_edge" `
        -IssueType "weak_relationship_confidence" `
        -PriorityScore $priority `
        -WorkspaceName (Get-WorkspaceFromQualifiedName -QualifiedName $fromName) `
        -RelationshipType $relationship `
        -FromQualifiedName $fromName `
        -ToQualifiedName $toName `
        -CurrentConfidence $confidence `
        -EvidenceSource (Get-FieldValue -Object $edge -Names @("source_system")) `
        -EvidenceText (Get-FieldValue -Object $edge -Names @("evidence")) `
        -BlockerReason "Relationship confidence is not confirmed." `
        -NextAction "Confirm this dependency from definition/model binding evidence or approved owner documentation before using it as an operational sequencing rule."
}

foreach ($coverage in $coverageRows) {
    if ((Convert-ToInt (Get-FieldValue -Object $coverage -Names @("object_count"))) -gt 0) { continue }
    $itemQualifiedName = Get-FieldValue -Object $coverage -Names @("item_qualified_name")
    $manual = if ($manualReviewByItem.ContainsKey($itemQualifiedName)) { $manualReviewByItem[$itemQualifiedName] } else { $null }
    $priority = if ($manual) { Convert-ToInt (Get-FieldValue -Object $manual -Names @("priority_score")) } else { 80 }
    Add-QueueRow -Rows $rows -Seen $seen `
        -EvidenceArea "object_level_lineage" `
        -IssueType "missing_object_level_lineage" `
        -PriorityScore $priority `
        -WorkspaceName (Get-FieldValue -Object $coverage -Names @("workspace_name")) `
        -WorkspaceEnvironment (Get-FieldValue -Object $coverage -Names @("workspace_environment")) `
        -ItemType (Get-FieldValue -Object $coverage -Names @("item_type")) `
        -ItemName (Get-FieldValue -Object $coverage -Names @("item_name")) `
        -ItemQualifiedName $itemQualifiedName `
        -CurrentConfidence "unknown" `
        -EvidenceSource $ObjectCoveragePath `
        -EvidenceText (Get-FieldValue -Object $coverage -Names @("gap_reason")) `
        -BlockerReason "Item has no object-level lineage, so reverse-impact and safe orchestration cannot be complete." `
        -NextAction (Get-FieldValue -Object $coverage -Names @("next_action"))
}

foreach ($typeRow in $typeQueueRows) {
    $status = Get-FieldValue -Object $typeRow -Names @("status")
    $resolvedType = Get-FieldValue -Object $typeRow -Names @("resolved_object_type")
    if ((Normalize-Key $status) -eq "resolved" -and (Test-ExactObjectType $resolvedType)) { continue }
    $priority = Convert-ToInt (Get-FieldValue -Object $typeRow -Names @("priority_score"))
    Add-QueueRow -Rows $rows -Seen $seen `
        -EvidenceArea "source_object_type" `
        -IssueType "source_object_type_pending" `
        -PriorityScore $priority `
        -WorkspaceName (Get-FieldValue -Object $typeRow -Names @("workspaces")) `
        -ItemType (Get-FieldValue -Object $typeRow -Names @("affected_item_types")) `
        -ItemQualifiedName (Get-FieldValue -Object $typeRow -Names @("affected_items")) `
        -SourceType (Get-FieldValue -Object $typeRow -Names @("source_type")) `
        -SourceServer (Get-FieldValue -Object $typeRow -Names @("source_server")) `
        -SourceDatabase (Get-FieldValue -Object $typeRow -Names @("source_database")) `
        -SchemaName (Get-FieldValue -Object $typeRow -Names @("schema_name")) `
        -ObjectName (Get-FieldValue -Object $typeRow -Names @("object_name")) `
        -ObjectType (Get-FieldValue -Object $typeRow -Names @("raw_object_type")) `
        -CurrentConfidence (Get-FieldValue -Object $typeRow -Names @("confidence")) `
        -EvidenceSource (Get-FieldValue -Object $typeRow -Names @("resolver_source")) `
        -EvidenceText (Get-FieldValue -Object $typeRow -Names @("resolver_evidence")) `
        -BlockerReason "Exact physical object type is not confirmed." `
        -NextAction (Get-FieldValue -Object $typeRow -Names @("next_step"))
}

foreach ($gap in $metadataGapRows) {
    $priority = 90 + (Convert-ToInt (Get-FieldValue -Object $gap -Names @("impacted_item_count")))
    Add-QueueRow -Rows $rows -Seen $seen `
        -EvidenceArea "metadata_access" `
        -IssueType "metadata_access_gap" `
        -PriorityScore $priority `
        -ItemQualifiedName (Get-FieldValue -Object $gap -Names @("impacted_items_sample")) `
        -SourceType (Get-FieldValue -Object $gap -Names @("source_type")) `
        -SourceServer (Get-FieldValue -Object $gap -Names @("source_server")) `
        -SourceDatabase (Get-FieldValue -Object $gap -Names @("source_database")) `
        -SchemaName (Get-FieldValue -Object $gap -Names @("schema_name")) `
        -ObjectName (Get-FieldValue -Object $gap -Names @("object_name")) `
        -ObjectType (Get-FieldValue -Object $gap -Names @("raw_object_type")) `
        -CurrentConfidence "unknown" `
        -EvidenceSource $MetadataGapsPath `
        -EvidenceText (Get-FieldValue -Object $gap -Names @("error")) `
        -BlockerReason (Get-FieldValue -Object $gap -Names @("gap_reason")) `
        -NextAction (Get-FieldValue -Object $gap -Names @("next_step"))
}

foreach ($impact in $impactRows) {
    $confidence = Get-FieldValue -Object $impact -Names @("confidence")
    $objectType = Get-FieldValue -Object $impact -Names @("object_type")
    $objectTypeConfidence = Get-FieldValue -Object $impact -Names @("object_type_confidence")
    $weakLineage = (Normalize-Key $confidence) -ne "confirmed"
    $ambiguousType = -not (Test-ExactObjectType $objectType)
    if (-not ($weakLineage -or $ambiguousType -or ((Normalize-Key $objectTypeConfidence) -ne "confirmed"))) { continue }
    $objectKey = Get-FieldValue -Object $impact -Names @("object_key")
    $impactSummary = if ($impactByObjectKey.ContainsKey($objectKey)) { $impactByObjectKey[$objectKey] } else { $null }
    $affectedCount = if ($impactSummary) { Convert-ToInt (Get-FieldValue -Object $impactSummary -Names @("affected_item_count")) } else { 0 }
    $issueType = if ($weakLineage -and $ambiguousType) { "weak_lineage_and_ambiguous_type" } elseif ($weakLineage) { "weak_object_lineage_confidence" } else { "ambiguous_object_type" }
    $priority = 40 + [math]::Min($affectedCount, 120)
    if ((Get-FieldValue -Object $impact -Names @("usage_type")) -eq "writes_to") { $priority += 25 }
    Add-QueueRow -Rows $rows -Seen $seen `
        -EvidenceArea "object_impact" `
        -IssueType $issueType `
        -PriorityScore $priority `
        -WorkspaceName (Get-FieldValue -Object $impact -Names @("item_workspace_name")) `
        -ItemType (Get-FieldValue -Object $impact -Names @("item_type")) `
        -ItemName (Get-FieldValue -Object $impact -Names @("item_name")) `
        -ItemQualifiedName (Get-FieldValue -Object $impact -Names @("item_qualified_name")) `
        -SourceType (Get-FieldValue -Object $impact -Names @("source_type")) `
        -SourceServer (Get-FieldValue -Object $impact -Names @("source_server")) `
        -SourceDatabase (Get-FieldValue -Object $impact -Names @("source_database")) `
        -SchemaName (Get-FieldValue -Object $impact -Names @("schema_name")) `
        -ObjectName (Get-FieldValue -Object $impact -Names @("object_name")) `
        -ObjectType $objectType `
        -UsageType (Get-FieldValue -Object $impact -Names @("usage_type")) `
        -CurrentConfidence $confidence `
        -EvidenceSource (Get-FieldValue -Object $impact -Names @("object_type_source")) `
        -EvidenceText (Get-FieldValue -Object $impact -Names @("evidence")) `
        -BlockerReason "Reverse-impact evidence is not fully confirmed for lineage and/or exact object type." `
        -NextAction "Confirm the object reference and exact object type from code/definition plus metadata or owner evidence before using this dependency for change impact or scheduling."
}

foreach ($plan in $idealRows) {
    $humanRequired = (Normalize-Key (Get-FieldValue -Object $plan -Names @("human_validation_required"))) -eq "yes"
    $riskFlags = Get-FieldValue -Object $plan -Names @("risk_flags")
    $hasLikely = (Convert-ToInt (Get-FieldValue -Object $plan -Names @("incoming_likely_edges"))) -gt 0 -or (Convert-ToInt (Get-FieldValue -Object $plan -Names @("outgoing_likely_edges"))) -gt 0
    if (-not ($humanRequired -or $riskFlags -or $hasLikely)) { continue }
    $priority = 75
    if ($riskFlags -match "likely") { $priority += 20 }
    if ($riskFlags -match "failure") { $priority += 20 }
    Add-QueueRow -Rows $rows -Seen $seen `
        -EvidenceArea "orchestration_v2" `
        -IssueType "orchestration_evidence_blocker" `
        -PriorityScore $priority `
        -WorkspaceName (Get-FieldValue -Object $plan -Names @("workspace_name")) `
        -ItemType (Get-FieldValue -Object $plan -Names @("item_type")) `
        -ItemName (Get-FieldValue -Object $plan -Names @("item_name")) `
        -ItemQualifiedName (Get-FieldValue -Object $plan -Names @("qualified_name")) `
        -CurrentConfidence "needs_review" `
        -EvidenceSource $IdealExecutionPlanPath `
        -EvidenceText (Get-FieldValue -Object $plan -Names @("recommendation")) `
        -BlockerReason $riskFlags `
        -NextAction "Resolve dependency confidence and object-level read/write evidence before promoting this row into orchestration v2."
}

$queueColumns = @(
    "evidence_area",
    "issue_type",
    "priority_score",
    "hardening_status",
    "workspace_name",
    "workspace_environment",
    "item_type",
    "item_name",
    "item_qualified_name",
    "source_type",
    "source_server",
    "source_database",
    "schema_name",
    "object_name",
    "object_type",
    "usage_type",
    "relationship_type",
    "from_qualified_name",
    "to_qualified_name",
    "current_confidence",
    "evidence_source",
    "evidence_text",
    "blocker_reason",
    "preferred_confirmation_source",
    "next_action"
)

$sortedRows = @($rows | Sort-Object @{ Expression = "priority_score"; Descending = $true }, evidence_area, issue_type, workspace_name, item_name, object_name)
Export-Rows -Rows $sortedRows -Columns $queueColumns -Path $OutputQueuePath

$summaryRows = [System.Collections.Generic.List[object]]::new()
foreach ($group in ($sortedRows | Group-Object evidence_area, issue_type, current_confidence)) {
    $sample = $group.Group | Select-Object -First 1
    $summaryRows.Add([pscustomobject]@{
        evidence_area = $sample.evidence_area
        issue_type = $sample.issue_type
        current_confidence = $sample.current_confidence
        queue_count = $group.Count
        max_priority_score = @($group.Group | Measure-Object -Property priority_score -Maximum).Maximum
        preferred_confirmation_source = $sample.preferred_confirmation_source
    }) | Out-Null
}
$summaryColumns = @("evidence_area", "issue_type", "current_confidence", "queue_count", "max_priority_score", "preferred_confirmation_source")
Export-Rows -Rows @($summaryRows | Sort-Object @{ Expression = "queue_count"; Descending = $true }, evidence_area, issue_type) -Columns $summaryColumns -Path $OutputSummaryPath

$docLines = [System.Collections.Generic.List[string]]::new()
$docLines.Add("# Evidence Hardening") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Generated at: $(Get-Date -Format s)") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Purpose") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Create a single local queue for dependencies, source objects, and orchestration rows that must be confirmed before they are used as operational scheduling or reverse-impact rules.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Summary") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- Queue rows: $($sortedRows.Count).") | Out-Null
$docLines.Add("- Weak dependency edges: $(@($sortedRows | Where-Object { $_.issue_type -eq 'weak_relationship_confidence' }).Count).") | Out-Null
$docLines.Add("- Missing object-level lineage rows: $(@($sortedRows | Where-Object { $_.issue_type -eq 'missing_object_level_lineage' }).Count).") | Out-Null
$docLines.Add("- Pending source object type rows: $(@($sortedRows | Where-Object { $_.issue_type -eq 'source_object_type_pending' }).Count).") | Out-Null
$docLines.Add("- Metadata access gap rows: $(@($sortedRows | Where-Object { $_.issue_type -eq 'metadata_access_gap' }).Count).") | Out-Null
$docLines.Add("- Object impact hardening rows: $(@($sortedRows | Where-Object { $_.evidence_area -eq 'object_impact' }).Count).") | Out-Null
$docLines.Add("- Orchestration blocker rows: $(@($sortedRows | Where-Object { $_.issue_type -eq 'orchestration_evidence_blocker' }).Count).") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Outputs") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add('- `analysis/evidence_hardening_queue.csv`') | Out-Null
$docLines.Add('- `analysis/evidence_hardening_summary.csv`') | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Confirmation Order") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("1. Use local generated evidence first.") | Out-Null
$docLines.Add("2. Use Azure DevOps code/repository evidence as the main technical source when available.") | Out-Null
$docLines.Add("3. Use SharePoint design/owner documentation as secondary evidence.") | Out-Null
$docLines.Add("4. Use local OneLake inspection for files, lakehouse tables, and paths where available.") | Out-Null
$docLines.Add("5. Use read-only Fabric/Power BI/SQL metadata for missing technical evidence.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Safety") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("This phase does not modify Fabric, SQL, repositories, schedules, or deployment pipelines. It creates a review queue and blocks low-confidence rows from becoming operational rules without confirmation.") | Out-Null
Ensure-ParentDirectory -Path $OutputDocPath
$docLines | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "Evidence hardening queue built."
Write-Host "Queue rows: $($sortedRows.Count)"
Write-Host "Summary: $OutputSummaryPath"
Write-Host "Output: $OutputQueuePath"
