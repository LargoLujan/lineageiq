# Phase 38 - Deep object lineage enrichment: merges read/write
# classification, manual review, metadata evidence, and the SQL endpoint
# catalog into one consolidated per-item/per-source-object enrichment view
# (feeds the D1-D8 closure family and the older archive/lineage-explorer/
# frontend's deep-object-lineage view).
# Writes: $OutputItemPath, $OutputSourceObjectPath, $OutputGapPath,
# $OutputJsonPath, $DocPath.
param(
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$ReadWritePath = (Join-Path $PSScriptRoot "../../analysis/object_read_write_classification.csv"),
    [string]$ObjectCoveragePath = (Join-Path $PSScriptRoot "../../analysis/object_level_lineage_coverage.csv"),
    [string]$ManualReviewQueuePath = (Join-Path $PSScriptRoot "../../analysis/manual_lineage_review_queue.csv"),
    [string]$MetadataEvidencePath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_metadata_evidence.csv"),
    [string]$MetadataGapsPath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_metadata_gaps.csv"),
    [string]$SqlEndpointCatalogPath = (Join-Path $PSScriptRoot "../../analysis/sql_endpoint_object_catalog.csv"),
    [string]$LineageModelPath = (Join-Path $PSScriptRoot "../../archive/lineage-explorer/data/lineage-explorer.json"),
    [string]$OutputItemPath = (Join-Path $PSScriptRoot "../../analysis/deep_object_lineage_item_enrichment.csv"),
    [string]$OutputSourceObjectPath = (Join-Path $PSScriptRoot "../../analysis/deep_object_lineage_source_objects.csv"),
    [string]$OutputGapPath = (Join-Path $PSScriptRoot "../../analysis/deep_object_lineage_gaps.csv"),
    [string]$OutputJsonPath = (Join-Path $PSScriptRoot "../../archive/lineage-explorer/data/deep-object-lineage.json"),
    [string]$DocPath = (Join-Path $PSScriptRoot "../../docs/33_deep_object_lineage_enrichment.md")
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

function Convert-ToInt {
    param([object]$Value)
    if ($null -eq $Value) { return 0 }
    $text = ([string]$Value).Trim()
    if (-not $text) { return 0 }
    $number = 0
    if ([int]::TryParse($text, [ref]$number)) { return $number }
    return 0
}

function Normalize-Key {
    param([string]$Value)
    if (-not $Value) { return "" }
    return (($Value.ToLowerInvariant() -replace "\s+", " ").Trim())
}

function New-StringSet {
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    return ,$set
}

function Add-ToSet {
    param(
        [System.Collections.Generic.HashSet[string]]$Set,
        [string]$Value
    )
    if ($Value) { $null = $Set.Add($Value) }
}

function Join-Set {
    param([object]$Set)
    if ($null -eq $Set) { return "" }
    if ($Set -is [string]) {
        if ($Set) { return $Set }
        return ""
    }
    $values = @($Set)
    if (@($values).Count -eq 0) { return "" }
    return (($values | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique) -join "; ")
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

function Add-Gap {
    param(
        [System.Collections.Generic.List[object]]$Gaps,
        [string]$GapId,
        [string]$Area,
        [string]$Severity,
        [int]$AffectedCount,
        [string]$Evidence,
        [string]$RecommendedAction
    )
    if ($AffectedCount -le 0) { return }
    $Gaps.Add([pscustomobject]@{
        gap_id = $GapId
        phase = "Phase 12"
        area = $Area
        severity = $Severity
        affected_count = $AffectedCount
        evidence = $Evidence
        recommended_action = $RecommendedAction
    }) | Out-Null
}

function Get-DeepLineageStatus {
    param(
        [string]$CoverageStatus,
        [int]$AmbiguousObjectReferences,
        [int]$LikelyLineageRows,
        [int]$UnknownOperations
    )
    if ($CoverageStatus -eq "no_source") { return "source_missing" }
    if ($CoverageStatus -eq "source_only") { return "object_missing" }
    if ($UnknownOperations -gt 0) { return "blocked_unknown_operation" }
    if ($AmbiguousObjectReferences -gt 0) { return "needs_object_type_resolution" }
    if ($LikelyLineageRows -gt 0) { return "needs_lineage_confirmation" }
    return "ready_confirmed"
}

function Get-DefaultAction {
    param(
        [string]$Status,
        [string]$CoverageAction
    )
    switch ($Status) {
        "source_missing" { return "Identify the source system/object from local definitions, Azure DevOps, SharePoint, OneLake, or owner evidence before sequencing this item." }
        "object_missing" { return "Record table, view, stored procedure, file, or lakehouse object evidence in index/manual_lineage_object_evidence.csv." }
        "blocked_unknown_operation" { return "Confirm whether the object interaction is read, write, execute, or informational before using it for orchestration." }
        "needs_object_type_resolution" { return "Resolve ambiguous table_or_view/native_query_object rows through metadata evidence or approved manual overrides." }
        "needs_lineage_confirmation" { return "Confirm likely object-level lineage before treating it as a hard dependency." }
        default {
            if ($CoverageAction) { return $CoverageAction }
            return "Ready for review with current evidence."
        }
    }
}

function New-ItemAggregate {
    param(
        [string]$WorkspaceName,
        [string]$Environment,
        [string]$ItemType,
        [string]$ItemName,
        [string]$ItemQualifiedName
    )
    return [pscustomobject]@{
        workspace_name = $WorkspaceName
        environment = $Environment
        item_type = $ItemType
        item_name = $ItemName
        item_qualified_name = $ItemQualifiedName
        source_count = 0
        unique_object_count = 0
        object_reference_count = 0
        exact_object_count = 0
        ambiguous_object_count = 0
        exact_object_reference_count = 0
        ambiguous_object_reference_count = 0
        confirmed_lineage_rows = 0
        likely_lineage_rows = 0
        read_count = 0
        write_count = 0
        execute_count = 0
        unknown_count = 0
        coverage_status = ""
        review_status = ""
        priority_score = 0
        gap_reason = ""
        next_action = ""
        deep_lineage_status = ""
        evidence = ""
    }
}

function New-SourceAggregate {
    param(
        [string]$ObjectKey,
        [object]$Row
    )
    return [pscustomobject]@{
        object_key = $ObjectKey
        source_type = Get-FieldValue -Object $Row -Names @("source_type")
        source_server = Get-FieldValue -Object $Row -Names @("source_server")
        source_database = Get-FieldValue -Object $Row -Names @("source_database")
        schema_name = Get-FieldValue -Object $Row -Names @("schema_name")
        object_name = Get-FieldValue -Object $Row -Names @("object_name")
        object_display_name = Get-FieldValue -Object $Row -Names @("object_display_name")
        object_type = Get-FieldValue -Object $Row -Names @("object_type")
        raw_object_type = Get-FieldValue -Object $Row -Names @("raw_object_type")
        object_type_status = Get-FieldValue -Object $Row -Names @("object_type_status")
        object_type_confidence = Get-FieldValue -Object $Row -Names @("object_type_confidence")
        read_count = 0
        write_count = 0
        execute_count = 0
        unknown_count = 0
        confirmed_lineage_rows = 0
        likely_lineage_rows = 0
        exact_reference_count = 0
        ambiguous_reference_count = 0
        affected_items = New-StringSet
        affected_workspaces = New-StringSet
        affected_item_types = New-StringSet
        evidence_samples = New-StringSet
    }
}

$items = @(Import-OptionalCsv -Path $ItemsPath | Where-Object { -not (Get-FieldValue -Object $_ -Names @("status")) -or (Get-FieldValue -Object $_ -Names @("status")) -eq "discovered" })
$readWriteRows = @(Import-OptionalCsv -Path $ReadWritePath)
$coverageRows = @(Import-OptionalCsv -Path $ObjectCoveragePath)
$manualRows = @(Import-OptionalCsv -Path $ManualReviewQueuePath)
$metadataEvidenceRows = @(Import-OptionalCsv -Path $MetadataEvidencePath)
$metadataGapRows = @(Import-OptionalCsv -Path $MetadataGapsPath)
$sqlCatalogRows = @(Import-OptionalCsv -Path $SqlEndpointCatalogPath)

$itemsByQualifiedName = @{}
foreach ($item in $items) {
    $qualifiedName = Get-FieldValue -Object $item -Names @("qualified_name", "item_qualified_name")
    if ($qualifiedName) { $itemsByQualifiedName[$qualifiedName] = $item }
}

$reviewByItem = @{}
foreach ($row in $manualRows) {
    $qualifiedName = Get-FieldValue -Object $row -Names @("item_qualified_name")
    if ($qualifiedName -and -not $reviewByItem.ContainsKey($qualifiedName)) {
        $reviewByItem[$qualifiedName] = $row
    }
}

$itemAgg = @{}
foreach ($coverage in $coverageRows) {
    $qualifiedName = Get-FieldValue -Object $coverage -Names @("item_qualified_name")
    if (-not $qualifiedName) { continue }
    $row = New-ItemAggregate `
        -WorkspaceName (Get-FieldValue -Object $coverage -Names @("workspace_name")) `
        -Environment (Get-FieldValue -Object $coverage -Names @("workspace_environment", "environment")) `
        -ItemType (Get-FieldValue -Object $coverage -Names @("item_type")) `
        -ItemName (Get-FieldValue -Object $coverage -Names @("item_name")) `
        -ItemQualifiedName $qualifiedName
    $row.source_count = Convert-ToInt (Get-FieldValue -Object $coverage -Names @("source_count"))
    $row.unique_object_count = Convert-ToInt (Get-FieldValue -Object $coverage -Names @("object_count"))
    $row.exact_object_count = Convert-ToInt (Get-FieldValue -Object $coverage -Names @("exact_object_count"))
    $row.ambiguous_object_count = Convert-ToInt (Get-FieldValue -Object $coverage -Names @("ambiguous_object_count"))
    $row.coverage_status = Get-FieldValue -Object $coverage -Names @("coverage_status")
    $row.gap_reason = Get-FieldValue -Object $coverage -Names @("gap_reason")
    $row.next_action = Get-FieldValue -Object $coverage -Names @("next_action")
    $row.evidence = "analysis/object_level_lineage_coverage.csv"
    if ($reviewByItem.ContainsKey($qualifiedName)) {
        $review = $reviewByItem[$qualifiedName]
        $row.review_status = Get-FieldValue -Object $review -Names @("review_status")
        $row.priority_score = Convert-ToInt (Get-FieldValue -Object $review -Names @("priority_score"))
        $reviewAction = Get-FieldValue -Object $review -Names @("review_action")
        if ($reviewAction) { $row.next_action = $reviewAction }
    }
    $itemAgg[$qualifiedName] = $row
}

$sourceAgg = @{}
foreach ($row in $readWriteRows) {
    $qualifiedName = Get-FieldValue -Object $row -Names @("item_qualified_name")
    if (-not $qualifiedName) { continue }
    if (-not $itemAgg.ContainsKey($qualifiedName)) {
        $indexed = $null
        if ($itemsByQualifiedName.ContainsKey($qualifiedName)) { $indexed = $itemsByQualifiedName[$qualifiedName] }
        $itemAgg[$qualifiedName] = New-ItemAggregate `
            -WorkspaceName (Get-FieldValue -Object $row -Names @("workspace_name")) `
            -Environment (Get-FieldValue -Object $indexed -Names @("workspace_environment")) `
            -ItemType (Get-FieldValue -Object $row -Names @("item_type")) `
            -ItemName (Get-FieldValue -Object $row -Names @("item_name")) `
            -ItemQualifiedName $qualifiedName
        $itemAgg[$qualifiedName].coverage_status = "object_level_present"
        $itemAgg[$qualifiedName].evidence = "analysis/object_read_write_classification.csv"
    }

    $agg = $itemAgg[$qualifiedName]
    $agg.object_reference_count++
    $operation = Normalize-Key (Get-FieldValue -Object $row -Names @("operation_type"))
    switch ($operation) {
        "read" { $agg.read_count++ }
        "write" { $agg.write_count++ }
        "execute" { $agg.execute_count++ }
        default { $agg.unknown_count++ }
    }

    $lineageConfidence = Normalize-Key (Get-FieldValue -Object $row -Names @("lineage_confidence"))
    if ($lineageConfidence -eq "confirmed") { $agg.confirmed_lineage_rows++ }
    elseif ($lineageConfidence -eq "likely") { $agg.likely_lineage_rows++ }

    $objectTypeStatus = Normalize-Key (Get-FieldValue -Object $row -Names @("object_type_status"))
    if ($objectTypeStatus -eq "exact") { $agg.exact_object_reference_count++ }
    elseif ($objectTypeStatus -eq "ambiguous") { $agg.ambiguous_object_reference_count++ }

    $objectKey = Get-FieldValue -Object $row -Names @("object_key")
    if (-not $objectKey) {
        $objectKey = "{0}|{1}|{2}|{3}|{4}" -f `
            (Get-FieldValue -Object $row -Names @("source_type")),
            (Get-FieldValue -Object $row -Names @("source_server")),
            (Get-FieldValue -Object $row -Names @("source_database")),
            (Get-FieldValue -Object $row -Names @("schema_name")),
            (Get-FieldValue -Object $row -Names @("object_name"))
    }
    if (-not $sourceAgg.ContainsKey($objectKey)) {
        $sourceAgg[$objectKey] = New-SourceAggregate -ObjectKey $objectKey -Row $row
    }
    $source = $sourceAgg[$objectKey]
    switch ($operation) {
        "read" { $source.read_count++ }
        "write" { $source.write_count++ }
        "execute" { $source.execute_count++ }
        default { $source.unknown_count++ }
    }
    if ($lineageConfidence -eq "confirmed") { $source.confirmed_lineage_rows++ }
    elseif ($lineageConfidence -eq "likely") { $source.likely_lineage_rows++ }
    if ($objectTypeStatus -eq "exact") { $source.exact_reference_count++ }
    elseif ($objectTypeStatus -eq "ambiguous") { $source.ambiguous_reference_count++ }
    Add-ToSet -Set $source.affected_items -Value $qualifiedName
    Add-ToSet -Set $source.affected_workspaces -Value (Get-FieldValue -Object $row -Names @("workspace_name"))
    Add-ToSet -Set $source.affected_item_types -Value (Get-FieldValue -Object $row -Names @("item_type"))
    Add-ToSet -Set $source.evidence_samples -Value (Get-FieldValue -Object $row -Names @("evidence"))
}

$itemRows = [System.Collections.Generic.List[object]]::new()
foreach ($key in ($itemAgg.Keys | Sort-Object)) {
    $row = $itemAgg[$key]
    $row.deep_lineage_status = Get-DeepLineageStatus `
        -CoverageStatus $row.coverage_status `
        -AmbiguousObjectReferences $row.ambiguous_object_reference_count `
        -LikelyLineageRows $row.likely_lineage_rows `
        -UnknownOperations $row.unknown_count
    if (-not $row.next_action) {
        $row.next_action = Get-DefaultAction -Status $row.deep_lineage_status -CoverageAction ""
    }
    else {
        $row.next_action = Get-DefaultAction -Status $row.deep_lineage_status -CoverageAction $row.next_action
    }
    if (-not $row.review_status -and $reviewByItem.ContainsKey($key)) {
        $row.review_status = Get-FieldValue -Object $reviewByItem[$key] -Names @("review_status")
    }
    $itemRows.Add([pscustomobject]@{
        workspace_name = $row.workspace_name
        environment = $row.environment
        item_type = $row.item_type
        item_name = $row.item_name
        item_qualified_name = $row.item_qualified_name
        source_count = $row.source_count
        unique_object_count = $row.unique_object_count
        object_reference_count = $row.object_reference_count
        exact_object_count = $row.exact_object_count
        ambiguous_object_count = $row.ambiguous_object_count
        exact_object_reference_count = $row.exact_object_reference_count
        ambiguous_object_reference_count = $row.ambiguous_object_reference_count
        confirmed_lineage_rows = $row.confirmed_lineage_rows
        likely_lineage_rows = $row.likely_lineage_rows
        read_count = $row.read_count
        write_count = $row.write_count
        execute_count = $row.execute_count
        unknown_count = $row.unknown_count
        coverage_status = $row.coverage_status
        review_status = $row.review_status
        priority_score = $row.priority_score
        gap_reason = $row.gap_reason
        deep_lineage_status = $row.deep_lineage_status
        next_action = $row.next_action
        evidence = $row.evidence
    }) | Out-Null
}

$sourceRows = [System.Collections.Generic.List[object]]::new()
foreach ($key in ($sourceAgg.Keys | Sort-Object)) {
    $source = $sourceAgg[$key]
    $sourceRows.Add([pscustomobject]@{
        object_key = $source.object_key
        source_type = $source.source_type
        source_server = $source.source_server
        source_database = $source.source_database
        schema_name = $source.schema_name
        object_name = $source.object_name
        object_display_name = $source.object_display_name
        object_type = $source.object_type
        raw_object_type = $source.raw_object_type
        object_type_status = $source.object_type_status
        object_type_confidence = $source.object_type_confidence
        read_count = $source.read_count
        write_count = $source.write_count
        execute_count = $source.execute_count
        unknown_count = $source.unknown_count
        confirmed_lineage_rows = $source.confirmed_lineage_rows
        likely_lineage_rows = $source.likely_lineage_rows
        exact_reference_count = $source.exact_reference_count
        ambiguous_reference_count = $source.ambiguous_reference_count
        affected_item_count = $source.affected_items.Count
        affected_workspace_count = $source.affected_workspaces.Count
        affected_item_types = Join-Set -Set $source.affected_item_types
        affected_workspaces = Join-Set -Set $source.affected_workspaces
        exactness_status = if ($source.ambiguous_reference_count -gt 0) { "needs_object_type_resolution" } else { "exact" }
        evidence = (Join-Set -Set $source.evidence_samples)
    }) | Out-Null
}

$gaps = [System.Collections.Generic.List[object]]::new()
$sourceMissingCount = @($manualRows | Where-Object { (Get-FieldValue -Object $_ -Names @("review_status")) -eq "source_missing_manual_review_required" }).Count
$sourceKnownObjectMissingCount = @($manualRows | Where-Object { (Get-FieldValue -Object $_ -Names @("review_status")) -eq "source_known_object_missing" }).Count
$ambiguousRows = @($readWriteRows | Where-Object { (Normalize-Key (Get-FieldValue -Object $_ -Names @("object_type_status"))) -eq "ambiguous" })
$ambiguousUnique = @($ambiguousRows | ForEach-Object { Get-FieldValue -Object $_ -Names @("object_key") } | Where-Object { $_ } | Sort-Object -Unique).Count
$likelyRows = @($readWriteRows | Where-Object { (Normalize-Key (Get-FieldValue -Object $_ -Names @("lineage_confidence"))) -eq "likely" }).Count
$unknownOperations = @($readWriteRows | Where-Object {
    $operation = Normalize-Key (Get-FieldValue -Object $_ -Names @("operation_type"))
    $operation -notin @("read", "write", "execute")
}).Count
$copyJobAmbiguous = @($readWriteRows | Where-Object { (Get-FieldValue -Object $_ -Names @("item_type")) -eq "CopyJob" -and (Normalize-Key (Get-FieldValue -Object $_ -Names @("object_type_status"))) -eq "ambiguous" }).Count

Add-Gap -Gaps $gaps -GapId "phase12_source_missing_manual_review" -Area "object_lineage" -Severity "high" -AffectedCount $sourceMissingCount -Evidence "manual review queue items without a source dependency" -RecommendedAction "Inspect definitions and source settings, then record source/object evidence in index/manual_lineage_object_evidence.csv."
Add-Gap -Gaps $gaps -GapId "phase12_source_known_object_missing" -Area "object_lineage" -Severity "high" -AffectedCount $sourceKnownObjectMissingCount -Evidence "manual review queue items with source dependencies but no object evidence" -RecommendedAction "Review item definitions and record the exact table, view, stored procedure, file, or lakehouse object evidence."
Add-Gap -Gaps $gaps -GapId "phase12_ambiguous_object_types" -Area "object_type_resolution" -Severity "high" -AffectedCount @($ambiguousRows).Count -Evidence "$ambiguousUnique unique source objects still have ambiguous physical type references." -RecommendedAction "Resolve through read-only metadata, owner-approved catalog evidence, or index/source_object_type_overrides.csv."
Add-Gap -Gaps $gaps -GapId "phase12_likely_lineage_rows" -Area "dependency_confidence" -Severity "high" -AffectedCount $likelyRows -Evidence "object lineage rows remain likely instead of confirmed" -RecommendedAction "Confirm likely rows before using them as hard sequencing or change-impact dependencies."
Add-Gap -Gaps $gaps -GapId "phase12_metadata_access_gaps" -Area "metadata_access" -Severity "medium" -AffectedCount @($metadataGapRows).Count -Evidence "analysis/source_object_type_metadata_gaps.csv" -RecommendedAction "Validate endpoint access or capture owner-approved catalog evidence for unresolved metadata targets."
Add-Gap -Gaps $gaps -GapId "phase12_unknown_operations" -Area "read_write_classification" -Severity "medium" -AffectedCount $unknownOperations -Evidence "object read/write classification rows with unknown operation type" -RecommendedAction "Confirm the operation as read, write, execute, or informational before orchestration use."
Add-Gap -Gaps $gaps -GapId "phase12_copyjob_exact_type_gap" -Area "copyjob_lineage" -Severity "high" -AffectedCount $copyJobAmbiguous -Evidence "CopyJob object rows are present but physical table/view types are unresolved." -RecommendedAction "Resolve CopyJob source/sink object types through metadata or approved manual review."

$coverageObjectPresent = @($coverageRows | Where-Object { (Get-FieldValue -Object $_ -Names @("coverage_status")) -eq "object_level_present" }).Count
$coverageSourceOnly = @($coverageRows | Where-Object { (Get-FieldValue -Object $_ -Names @("coverage_status")) -eq "source_only" }).Count
$coverageNoSource = @($coverageRows | Where-Object { (Get-FieldValue -Object $_ -Names @("coverage_status")) -eq "no_source" }).Count
$exactRows = @($readWriteRows | Where-Object { (Normalize-Key (Get-FieldValue -Object $_ -Names @("object_type_status"))) -eq "exact" }).Count
$confirmedRows = @($readWriteRows | Where-Object { (Normalize-Key (Get-FieldValue -Object $_ -Names @("lineage_confidence"))) -eq "confirmed" }).Count

$summary = [pscustomobject]@{
    generated_at = (Get-Date).ToString("s")
    item_count = @($itemRows).Count
    source_object_count = @($sourceRows).Count
    object_reference_count = @($readWriteRows).Count
    object_level_present_items = $coverageObjectPresent
    source_only_items = $coverageSourceOnly
    no_source_items = $coverageNoSource
    exact_object_reference_count = $exactRows
    ambiguous_object_reference_count = @($ambiguousRows).Count
    confirmed_lineage_rows = $confirmedRows
    likely_lineage_rows = $likelyRows
    metadata_evidence_rows = @($metadataEvidenceRows).Count
    metadata_gap_rows = @($metadataGapRows).Count
    sql_endpoint_catalog_rows = @($sqlCatalogRows).Count
    gap_count = @($gaps).Count
}

$itemColumns = @(
    "workspace_name", "environment", "item_type", "item_name", "item_qualified_name",
    "source_count", "unique_object_count", "object_reference_count",
    "exact_object_count", "ambiguous_object_count",
    "exact_object_reference_count", "ambiguous_object_reference_count",
    "confirmed_lineage_rows", "likely_lineage_rows",
    "read_count", "write_count", "execute_count", "unknown_count",
    "coverage_status", "review_status", "priority_score", "gap_reason",
    "deep_lineage_status", "next_action", "evidence"
)
$sourceColumns = @(
    "object_key", "source_type", "source_server", "source_database", "schema_name", "object_name",
    "object_display_name", "object_type", "raw_object_type", "object_type_status", "object_type_confidence",
    "read_count", "write_count", "execute_count", "unknown_count",
    "confirmed_lineage_rows", "likely_lineage_rows",
    "exact_reference_count", "ambiguous_reference_count",
    "affected_item_count", "affected_workspace_count", "affected_item_types", "affected_workspaces",
    "exactness_status", "evidence"
)
$gapColumns = @("gap_id", "phase", "area", "severity", "affected_count", "evidence", "recommended_action")

Export-Rows -Rows @($itemRows) -Columns $itemColumns -Path $OutputItemPath
Export-Rows -Rows @($sourceRows) -Columns $sourceColumns -Path $OutputSourceObjectPath
Export-Rows -Rows @($gaps) -Columns $gapColumns -Path $OutputGapPath

$jsonModel = [pscustomobject]@{
    schema_version = "phase12.deep-object-lineage.v1"
    generated_at = $summary.generated_at
    summary = $summary
    items = @($itemRows)
    source_objects = @($sourceRows)
    gaps = @($gaps)
    source_artifacts = @(
        $ReadWritePath,
        $ObjectCoveragePath,
        $ManualReviewQueuePath,
        $MetadataEvidencePath,
        $MetadataGapsPath,
        $SqlEndpointCatalogPath
    )
}
Ensure-ParentDirectory -Path $OutputJsonPath
$jsonModel | ConvertTo-Json -Depth 30 | Set-Content -Path $OutputJsonPath -Encoding UTF8

if (Test-Path $LineageModelPath) {
    $lineageModel = Get-Content -Path $LineageModelPath -Raw | ConvertFrom-Json
    $itemByName = @{}
    foreach ($row in $itemRows) {
        $itemByName[$row.item_qualified_name] = $row
    }
    foreach ($item in @($lineageModel.items)) {
        $qualifiedName = Get-FieldValue -Object $item -Names @("qualified_name")
        if (-not $qualifiedName -or -not $itemByName.ContainsKey($qualifiedName)) { continue }
        $row = $itemByName[$qualifiedName]
        $deep = [pscustomobject]@{
            status = $row.deep_lineage_status
            coverage_status = $row.coverage_status
            review_status = $row.review_status
            source_count = $row.source_count
            unique_object_count = $row.unique_object_count
            object_reference_count = $row.object_reference_count
            exact_object_count = $row.exact_object_count
            ambiguous_object_count = $row.ambiguous_object_count
            exact_object_reference_count = $row.exact_object_reference_count
            ambiguous_object_reference_count = $row.ambiguous_object_reference_count
            confirmed_lineage_rows = $row.confirmed_lineage_rows
            likely_lineage_rows = $row.likely_lineage_rows
            read_count = $row.read_count
            write_count = $row.write_count
            execute_count = $row.execute_count
            unknown_count = $row.unknown_count
            gap_reason = $row.gap_reason
            next_action = $row.next_action
            evidence = $row.evidence
        }
        $item | Add-Member -Force -NotePropertyName "deep_lineage" -NotePropertyValue $deep
    }
    $lineageModel | Add-Member -Force -NotePropertyName "phase12_deep_object_lineage" -NotePropertyValue ([pscustomobject]@{
        summary = $summary
        gaps = @($gaps)
        artifact = $OutputJsonPath
    })
    $lineageModel | ConvertTo-Json -Depth 40 | Set-Content -Path $LineageModelPath -Encoding UTF8
}

Ensure-ParentDirectory -Path $DocPath
$docLines = [System.Collections.Generic.List[string]]::new()
$docLines.Add("# Phase 12 Deep Object Lineage Enrichment") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Generated by backend/scripts/38_build_deep_object_lineage_enrichment.ps1 from local project artifacts only.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Outputs") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- $OutputItemPath") | Out-Null
$docLines.Add("- $OutputSourceObjectPath") | Out-Null
$docLines.Add("- $OutputGapPath") | Out-Null
$docLines.Add("- $OutputJsonPath") | Out-Null
$docLines.Add("- $LineageModelPath updated with per-item deep_lineage metadata") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Summary") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- Items enriched: $($summary.item_count)") | Out-Null
$docLines.Add("- Unique source objects: $($summary.source_object_count)") | Out-Null
$docLines.Add("- Object reference rows: $($summary.object_reference_count)") | Out-Null
$docLines.Add("- Items with object-level evidence: $($summary.object_level_present_items)") | Out-Null
$docLines.Add("- Items with source but missing object evidence: $($summary.source_only_items)") | Out-Null
$docLines.Add("- Items missing source evidence: $($summary.no_source_items)") | Out-Null
$docLines.Add("- Exact object reference rows: $($summary.exact_object_reference_count)") | Out-Null
$docLines.Add("- Ambiguous object reference rows: $($summary.ambiguous_object_reference_count)") | Out-Null
$docLines.Add("- Confirmed lineage rows: $($summary.confirmed_lineage_rows)") | Out-Null
$docLines.Add("- Likely lineage rows: $($summary.likely_lineage_rows)") | Out-Null
$docLines.Add("- Metadata evidence rows: $($summary.metadata_evidence_rows)") | Out-Null
$docLines.Add("- Metadata gap rows: $($summary.metadata_gap_rows)") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Gap Themes") | Out-Null
$docLines.Add("") | Out-Null
foreach ($gap in @($gaps)) {
    $docLines.Add("- $($gap.gap_id): $($gap.affected_count) affected rows/items; $($gap.recommended_action)") | Out-Null
}
$docLines.Add("") | Out-Null
$docLines.Add("## Decisions") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- No external Fabric, Azure DevOps, SharePoint, SQL, schedule, deployment, or workspace change was made.") | Out-Null
$docLines.Add("- Ambiguous table/view/native-query rows remain unresolved until metadata, manual override, or owner-approved catalog evidence exists.") | Out-Null
$docLines.Add("- Likely object-level rows remain visible for review but must not be used as hard orchestration dependencies.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Next Human Step") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Review the Phase 12 gaps, complete the high-priority manual lineage and object type confirmations, then approve the final review/finalization phase.") | Out-Null
$docLines | Set-Content -Path $DocPath -Encoding UTF8

Write-Host "Deep object lineage enrichment complete."
Write-Host "Items: $($summary.item_count)"
Write-Host "Source objects: $($summary.source_object_count)"
Write-Host "Object references: $($summary.object_reference_count)"
Write-Host "Gaps: $($summary.gap_count)"
