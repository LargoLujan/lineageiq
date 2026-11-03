# Phase 23 - Object read/write classification: for every item-object edge
# in the impact index, classifies it as read/write/both based on the
# relationship type and evidence already gathered, feeding orchestration
# v2's object-conflict detection (Phase 24). Purely local, no API calls.
# Writes: $OutputClassificationPath, $OutputSummaryPath, $OutputDocPath.
param(
    [string]$ObjectImpactPath = (Join-Path $PSScriptRoot "../../analysis/object_impact_index.csv"),
    [string]$EvidenceHardeningQueuePath = (Join-Path $PSScriptRoot "../../analysis/evidence_hardening_queue.csv"),
    [string]$IdealExecutionPlanPath = (Join-Path $PSScriptRoot "../../analysis/ideal_execution_plan.csv"),
    [string]$OutputClassificationPath = (Join-Path $PSScriptRoot "../../analysis/object_read_write_classification.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/object_read_write_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/20_object_read_write_classification.md")
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

function Split-MultiValue {
    param([string]$Value)
    if (-not $Value) { return @() }
    return @($Value -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-ObjectKey {
    param([object]$Row)
    $sourceType = Normalize-Key (Get-FieldValue -Object $Row -Names @("source_type"))
    $sourceServer = Normalize-Key (Get-FieldValue -Object $Row -Names @("source_server"))
    $sourceDatabase = Normalize-Key (Get-FieldValue -Object $Row -Names @("source_database"))
    $schemaName = Normalize-Key (Get-FieldValue -Object $Row -Names @("schema_name"))
    $objectName = Normalize-Key (Get-FieldValue -Object $Row -Names @("object_name"))
    return @($sourceType, $sourceServer, $sourceDatabase, $schemaName, $objectName) -join "|"
}

function New-HardeningBucket {
    return @{
        issue_types = [System.Collections.Generic.HashSet[string]]::new()
        evidence_areas = [System.Collections.Generic.HashSet[string]]::new()
        preferred_sources = [System.Collections.Generic.HashSet[string]]::new()
        next_actions = [System.Collections.Generic.HashSet[string]]::new()
        max_priority = 0
    }
}

function Add-HardeningRowToBucket {
    param(
        [hashtable]$Bucket,
        [object]$Row
    )
    $issueType = Get-FieldValue -Object $Row -Names @("issue_type")
    $evidenceArea = Get-FieldValue -Object $Row -Names @("evidence_area")
    $preferredSource = Get-FieldValue -Object $Row -Names @("preferred_confirmation_source")
    $nextAction = Get-FieldValue -Object $Row -Names @("next_action")
    if ($issueType) { $Bucket.issue_types.Add($issueType) | Out-Null }
    if ($evidenceArea) { $Bucket.evidence_areas.Add($evidenceArea) | Out-Null }
    if ($preferredSource) { $Bucket.preferred_sources.Add($preferredSource) | Out-Null }
    if ($nextAction) { $Bucket.next_actions.Add($nextAction) | Out-Null }
    $priority = Convert-ToInt (Get-FieldValue -Object $Row -Names @("priority_score"))
    if ($priority -gt $Bucket.max_priority) { $Bucket.max_priority = $priority }
}

function Merge-HardeningBucket {
    param(
        [hashtable]$Target,
        [hashtable]$Source
    )
    if ($null -eq $Source) { return }
    foreach ($value in $Source.issue_types) { $Target.issue_types.Add($value) | Out-Null }
    foreach ($value in $Source.evidence_areas) { $Target.evidence_areas.Add($value) | Out-Null }
    foreach ($value in $Source.preferred_sources) { $Target.preferred_sources.Add($value) | Out-Null }
    foreach ($value in $Source.next_actions) { $Target.next_actions.Add($value) | Out-Null }
    if ($Source.max_priority -gt $Target.max_priority) { $Target.max_priority = $Source.max_priority }
}

function Add-HardeningRowToIndex {
    param(
        [hashtable]$Index,
        [string]$Key,
        [object]$Row
    )
    $normalized = Normalize-Key $Key
    if (-not $normalized) { return }
    if (-not $Index.ContainsKey($normalized)) {
        $Index[$normalized] = New-HardeningBucket
    }
    Add-HardeningRowToBucket -Bucket $Index[$normalized] -Row $Row
}

function Get-NormalizedUsageType {
    param([string]$ItemType, [string]$UsageType)
    $usage = Normalize-Key $UsageType
    $item = Normalize-Key $ItemType

    if (-not $usage -and $item -eq "semanticmodel") { return "reads_from" }
    if ($usage -in @("read", "reads", "source", "input")) { return "reads_from" }
    if ($usage -in @("write", "writes", "sink", "output")) { return "writes_to" }
    if ($usage -in @("execute", "exec", "invokes", "invoke")) { return "executes" }
    if ($usage -in @("reads_from", "writes_to", "executes")) { return $usage }
    if (-not $usage) { return "unknown" }
    return $usage
}

function Get-OperationType {
    param([string]$UsageType)
    $usage = Normalize-Key $UsageType
    if ($usage -eq "reads_from") { return "read" }
    if ($usage -eq "writes_to") { return "write" }
    if ($usage -eq "executes") { return "execute" }
    return "unknown"
}

function Get-ObjectTypeStatus {
    param([string]$ObjectType)
    $objectTypeKey = Normalize-Key $ObjectType
    if (-not $objectTypeKey) { return "missing" }
    if ($objectTypeKey -in $script:ExactObjectTypes) { return "exact" }
    return "ambiguous"
}

function Get-HardeningAggregate {
    param(
        [hashtable]$Bucket,
        [string]$OperationType,
        [string]$Confidence,
        [string]$ObjectTypeStatus,
        [string]$PlanHumanValidation,
        [string]$PlanRiskFlags,
        [string]$PlanParallelReadiness
    )

    if ($null -eq $Bucket) { $Bucket = New-HardeningBucket }

    $issueTypeList = @($Bucket.issue_types | Sort-Object)
    $evidenceAreaList = @($Bucket.evidence_areas | Sort-Object)
    $preferredSourceList = @($Bucket.preferred_sources | Sort-Object | Select-Object -First 3)
    $nextActionList = @($Bucket.next_actions | Sort-Object | Select-Object -First 3)

    $confidenceKey = Normalize-Key $Confidence
    $planHumanKey = Normalize-Key $PlanHumanValidation
    $readiness = "unknown"
    $recommendedAction = "Review this row before operational use."

    if ($OperationType -eq "unknown") {
        $readiness = "blocked_missing_operation"
        $recommendedAction = "Confirm whether this item reads from, writes to, or executes the referenced object before scheduling."
    }
    elseif ($confidenceKey -ne "confirmed") {
        $readiness = "needs_lineage_confirmation"
        $recommendedAction = "Confirm object-level lineage from local definitions, Azure DevOps, SharePoint, OneLake, or read-only Fabric metadata before using it as a sequencing rule."
    }
    elseif ($ObjectTypeStatus -ne "exact") {
        $readiness = "needs_object_type_confirmation"
        $recommendedAction = "Confirm exact object type: table, view, stored procedure, file, shortcut, or query."
    }
    elseif ($issueTypeList -contains "orchestration_evidence_blocker" -or $planHumanKey -eq "yes") {
        $readiness = "needs_orchestration_review"
        $recommendedAction = "Keep this row as advisory until orchestration risks, dependency confidence, and execution history are reviewed."
    }
    elseif ($issueTypeList.Count -gt 0) {
        $readiness = "blocked_by_evidence_hardening"
        $recommendedAction = "Resolve the attached evidence-hardening issue before promoting this row into orchestration v2."
    }
    elseif ($OperationType -eq "read") {
        $readiness = "read_ready_candidate"
        $recommendedAction = "Candidate input dependency for orchestration v2 once item-level scheduling is reviewed."
    }
    elseif ($OperationType -eq "write") {
        $readiness = "write_serialization_required"
        $recommendedAction = "Serialize writers and downstream readers for this object; validate write conflicts before parallel execution."
    }
    elseif ($OperationType -eq "execute") {
        $readiness = "execute_sequence_required"
        $recommendedAction = "Use as an execution-order dependency candidate after invoked item behavior is confirmed."
    }

    return [pscustomobject]@{
        issue_types = ($issueTypeList -join "; ")
        evidence_areas = ($evidenceAreaList -join "; ")
        hardening_issue_count = $issueTypeList.Count
        hardening_priority_score = $Bucket.max_priority
        preferred_confirmation_sources = ($preferredSourceList -join " | ")
        hardening_next_actions = ($nextActionList -join " | ")
        hardening_status = if ($issueTypeList.Count -gt 0) { "pending_confirmation" } else { "clear" }
        scheduling_readiness = $readiness
        recommended_next_action = $recommendedAction
        orchestration_risk_flags = $PlanRiskFlags
        orchestration_human_validation_required = $PlanHumanValidation
        orchestration_parallel_readiness = $PlanParallelReadiness
    }
}

$impactRows = Import-OptionalCsv -Path $ObjectImpactPath
$hardeningRows = Import-OptionalCsv -Path $EvidenceHardeningQueuePath
$planRows = Import-OptionalCsv -Path $IdealExecutionPlanPath

Write-Host "Loaded impact rows: $($impactRows.Count)"
Write-Host "Loaded hardening rows: $($hardeningRows.Count)"
Write-Host "Loaded ideal execution plan rows: $($planRows.Count)"

$hardeningByObject = @{}
$hardeningByItemObject = @{}

foreach ($row in $hardeningRows) {
    $objectKey = Get-ObjectKey -Row $row
    $issueType = Normalize-Key (Get-FieldValue -Object $row -Names @("issue_type"))
    $objectLevelIssue = $issueType -in @("source_object_type_pending", "metadata_access_gap", "ambiguous_object_type")
    if ($objectLevelIssue -and $objectKey -and $objectKey -notmatch "^\|+\s*$") {
        Add-HardeningRowToIndex -Index $hardeningByObject -Key $objectKey -Row $row
        continue
    }

    $itemValues = Split-MultiValue (Get-FieldValue -Object $row -Names @("item_qualified_name"))
    foreach ($itemValue in $itemValues) {
        $itemKey = Normalize-Key $itemValue
        if ($itemKey) {
            if ($objectKey -and $objectKey -notmatch "^\|+\s*$") {
                Add-HardeningRowToIndex -Index $hardeningByItemObject -Key "$itemKey|$objectKey" -Row $row
            }
        }
    }
}

Write-Host "Hardening indexes built. Object keys: $($hardeningByObject.Count). Item-object keys: $($hardeningByItemObject.Count)."

$planByQualifiedName = @{}
foreach ($row in $planRows) {
    $qualifiedName = Normalize-Key (Get-FieldValue -Object $row -Names @("qualified_name", "item_qualified_name"))
    if ($qualifiedName -and -not $planByQualifiedName.ContainsKey($qualifiedName)) {
        $planByQualifiedName[$qualifiedName] = $row
    }
}

$classificationRows = [System.Collections.Generic.List[object]]::new()
$processedImpactRows = 0

foreach ($row in $impactRows) {
    $processedImpactRows++
    if (($processedImpactRows % 5000) -eq 0) {
        Write-Host "Classified impact rows: $processedImpactRows / $($impactRows.Count)"
    }

    $itemQualifiedName = Get-FieldValue -Object $row -Names @("item_qualified_name")
    $itemKey = Normalize-Key $itemQualifiedName
    $objectKey = Get-ObjectKey -Row $row
    $combinedKey = "$itemKey|$objectKey"
    $relatedHardening = New-HardeningBucket

    foreach ($lookup in @($combinedKey, $objectKey)) {
        $index = if ($lookup -eq $combinedKey) { $hardeningByItemObject } else { $hardeningByObject }
        $lookupKey = Normalize-Key $lookup
        if ($lookupKey -and $index.ContainsKey($lookupKey)) {
            Merge-HardeningBucket -Target $relatedHardening -Source $index[$lookupKey]
        }
    }

    $itemType = Get-FieldValue -Object $row -Names @("item_type")
    $usageType = Get-NormalizedUsageType -ItemType $itemType -UsageType (Get-FieldValue -Object $row -Names @("usage_type"))
    $operationType = Get-OperationType -UsageType $usageType
    $objectType = Get-FieldValue -Object $row -Names @("object_type")
    $objectTypeStatus = Get-ObjectTypeStatus -ObjectType $objectType
    $confidence = Get-FieldValue -Object $row -Names @("confidence")
    $planRow = if ($itemKey -and $planByQualifiedName.ContainsKey($itemKey)) { $planByQualifiedName[$itemKey] } else { $null }

    $aggregate = Get-HardeningAggregate `
        -Bucket $relatedHardening `
        -OperationType $operationType `
        -Confidence $confidence `
        -ObjectTypeStatus $objectTypeStatus `
        -PlanHumanValidation (Get-FieldValue -Object $planRow -Names @("human_validation_required")) `
        -PlanRiskFlags (Get-FieldValue -Object $planRow -Names @("risk_flags")) `
        -PlanParallelReadiness (Get-FieldValue -Object $planRow -Names @("parallel_readiness"))

    $classificationRows.Add([pscustomobject]@{
        workspace_name = Get-FieldValue -Object $row -Names @("item_workspace_name", "workspace_name")
        item_type = $itemType
        item_name = Get-FieldValue -Object $row -Names @("item_name")
        item_qualified_name = $itemQualifiedName
        source_type = Get-FieldValue -Object $row -Names @("source_type")
        source_server = Get-FieldValue -Object $row -Names @("source_server")
        source_database = Get-FieldValue -Object $row -Names @("source_database")
        schema_name = Get-FieldValue -Object $row -Names @("schema_name")
        object_name = Get-FieldValue -Object $row -Names @("object_name")
        object_display_name = Get-FieldValue -Object $row -Names @("object_display_name")
        object_key = Get-FieldValue -Object $row -Names @("object_key")
        object_type = $objectType
        raw_object_type = Get-FieldValue -Object $row -Names @("raw_object_type")
        object_type_status = $objectTypeStatus
        object_type_source = Get-FieldValue -Object $row -Names @("object_type_source")
        object_type_confidence = Get-FieldValue -Object $row -Names @("object_type_confidence")
        source_label = Get-FieldValue -Object $row -Names @("source_label")
        source_qualified_name = Get-FieldValue -Object $row -Names @("source_qualified_name")
        semantic_table = Get-FieldValue -Object $row -Names @("semantic_table")
        usage_type = Get-FieldValue -Object $row -Names @("usage_type")
        usage_type_normalized = $usageType
        operation_type = $operationType
        lineage_confidence = $confidence
        hardening_status = $aggregate.hardening_status
        hardening_issue_count = $aggregate.hardening_issue_count
        hardening_issue_types = $aggregate.issue_types
        hardening_evidence_areas = $aggregate.evidence_areas
        hardening_priority_score = $aggregate.hardening_priority_score
        preferred_confirmation_sources = $aggregate.preferred_confirmation_sources
        hardening_next_actions = $aggregate.hardening_next_actions
        orchestration_risk_flags = $aggregate.orchestration_risk_flags
        orchestration_human_validation_required = $aggregate.orchestration_human_validation_required
        orchestration_parallel_readiness = $aggregate.orchestration_parallel_readiness
        scheduling_readiness = $aggregate.scheduling_readiness
        recommended_next_action = $aggregate.recommended_next_action
        evidence = Get-FieldValue -Object $row -Names @("evidence")
    }) | Out-Null
}

$classificationColumns = @(
    "workspace_name",
    "item_type",
    "item_name",
    "item_qualified_name",
    "source_type",
    "source_server",
    "source_database",
    "schema_name",
    "object_name",
    "object_display_name",
    "object_key",
    "object_type",
    "raw_object_type",
    "object_type_status",
    "object_type_source",
    "object_type_confidence",
    "source_label",
    "source_qualified_name",
    "semantic_table",
    "usage_type",
    "usage_type_normalized",
    "operation_type",
    "lineage_confidence",
    "hardening_status",
    "hardening_issue_count",
    "hardening_issue_types",
    "hardening_evidence_areas",
    "hardening_priority_score",
    "preferred_confirmation_sources",
    "hardening_next_actions",
    "orchestration_risk_flags",
    "orchestration_human_validation_required",
    "orchestration_parallel_readiness",
    "scheduling_readiness",
    "recommended_next_action",
    "evidence"
)

Export-Rows -Rows @($classificationRows) -Columns $classificationColumns -Path $OutputClassificationPath

$summaryRows = [System.Collections.Generic.List[object]]::new()
$summaryGroups = $classificationRows | Group-Object item_type, operation_type, scheduling_readiness, lineage_confidence, object_type_status
foreach ($group in $summaryGroups) {
    $sample = $group.Group[0]
    $uniqueItems = [System.Collections.Generic.HashSet[string]]::new()
    $uniqueObjects = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($row in $group.Group) {
        $uniqueItems.Add((Normalize-Key $row.item_qualified_name)) | Out-Null
        $uniqueObjects.Add((Normalize-Key $row.object_key)) | Out-Null
    }
    $summaryRows.Add([pscustomobject]@{
        summary_scope = "item_operation_readiness"
        item_type = $sample.item_type
        operation_type = $sample.operation_type
        scheduling_readiness = $sample.scheduling_readiness
        lineage_confidence = $sample.lineage_confidence
        object_type_status = $sample.object_type_status
        row_count = $group.Count
        unique_item_count = $uniqueItems.Count
        unique_object_count = $uniqueObjects.Count
    }) | Out-Null
}

$summaryColumns = @(
    "summary_scope",
    "item_type",
    "operation_type",
    "scheduling_readiness",
    "lineage_confidence",
    "object_type_status",
    "row_count",
    "unique_item_count",
    "unique_object_count"
)

Export-Rows -Rows @($summaryRows | Sort-Object item_type, operation_type, scheduling_readiness, lineage_confidence, object_type_status) -Columns $summaryColumns -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath

$totalRows = $classificationRows.Count
$uniqueItemTotal = [System.Collections.Generic.HashSet[string]]::new()
$uniqueObjectTotal = [System.Collections.Generic.HashSet[string]]::new()
foreach ($row in $classificationRows) {
    $uniqueItemTotal.Add((Normalize-Key $row.item_qualified_name)) | Out-Null
    $uniqueObjectTotal.Add((Normalize-Key $row.object_key)) | Out-Null
}

$operationCounts = $classificationRows | Group-Object operation_type | Sort-Object Count -Descending
$readinessCounts = $classificationRows | Group-Object scheduling_readiness | Sort-Object Count -Descending
$itemCounts = $classificationRows | Group-Object item_type | Sort-Object Count -Descending
$objectStatusCounts = $classificationRows | Group-Object object_type_status | Sort-Object Count -Descending

$docLines = [System.Collections.Generic.List[string]]::new()
$docLines.Add("# Object Read/Write Classification") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Generated: $((Get-Date).ToString("s"))") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Purpose") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Phase B converts object-level lineage into operational read, write, execute, and unknown classifications. It is local-only and proposal-only; it does not modify Fabric, SQL, OneLake, Power BI, or schedules.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Inputs") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- analysis/object_impact_index.csv") | Out-Null
$docLines.Add("- analysis/evidence_hardening_queue.csv") | Out-Null
$docLines.Add("- analysis/ideal_execution_plan.csv") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Outputs") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- analysis/object_read_write_classification.csv") | Out-Null
$docLines.Add("- analysis/object_read_write_summary.csv") | Out-Null
$docLines.Add("- docs/20_object_read_write_classification.md") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Totals") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- Classification rows: $totalRows") | Out-Null
$docLines.Add("- Unique impacted items: $($uniqueItemTotal.Count)") | Out-Null
$docLines.Add("- Unique source objects: $($uniqueObjectTotal.Count)") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Operation Counts") | Out-Null
$docLines.Add("") | Out-Null
foreach ($group in $operationCounts) {
    $docLines.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$docLines.Add("") | Out-Null
$docLines.Add("## Item Counts") | Out-Null
$docLines.Add("") | Out-Null
foreach ($group in $itemCounts) {
    $docLines.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$docLines.Add("") | Out-Null
$docLines.Add("## Object Type Status") | Out-Null
$docLines.Add("") | Out-Null
foreach ($group in $objectStatusCounts) {
    $docLines.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$docLines.Add("") | Out-Null
$docLines.Add("## Scheduling Readiness") | Out-Null
$docLines.Add("") | Out-Null
foreach ($group in $readinessCounts) {
    $docLines.Add("- $($group.Name): $($group.Count)") | Out-Null
}
$docLines.Add("") | Out-Null
$docLines.Add("## Rules") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- Semantic model rows with empty usage are normalized to reads_from because semantic models consume source objects.") | Out-Null
$docLines.Add("- Rows with likely lineage remain needs_lineage_confirmation.") | Out-Null
$docLines.Add("- Rows typed as table_or_view or native_query_object remain needs_object_type_confirmation.") | Out-Null
$docLines.Add("- Write rows are not parallel-safe by default; they require serialization against other writers and downstream readers.") | Out-Null
$docLines.Add("- Execute rows are sequencing candidates only after invoked item behavior is confirmed.") | Out-Null
$docLines.Add("- Rows tied to ideal-plan human validation remain advisory until reviewed.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Gate") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Do not use this classification as an automatic operational plan. Phase C must consume only confirmed, exact, reviewed rows or explicitly carry blockers forward as unsafe/needs-review constraints.") | Out-Null

$docLines | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "Object read/write classification completed."
Write-Host "Rows: $totalRows"
Write-Host "Unique items: $($uniqueItemTotal.Count)"
Write-Host "Unique source objects: $($uniqueObjectTotal.Count)"
Write-Host "Output: $OutputClassificationPath"
