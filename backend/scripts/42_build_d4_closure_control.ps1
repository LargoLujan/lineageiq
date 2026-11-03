# Phase 42 - D4 closure control: tracks which D4 (exact object type,
# Phase 29) queue items have since been resolved via metadata evidence,
# closing them out and re-deriving what still needs a metadata retry,
# native-query review, or is still missing entirely. Purely local.
# Writes: $OutputControlQueuePath, $OutputImpactedTargetsPath,
# $OutputMetadataRetryPath, $OutputMissingTargetPath, $OutputNativeQueryPath,
# $OutputDecisionTemplatePath, $OutputReadonlyPlanPath, $OutputSummaryPath,
# $OutputDocPath.
param(
    [string]$D4SourceQueuePath = (Join-Path $PSScriptRoot "../../analysis/d4_exact_object_type_source_queue.csv"),
    [string]$D4ImpactQueuePath = (Join-Path $PSScriptRoot "../../analysis/d4_exact_object_type_impact_queue.csv"),
    [string]$OutputControlQueuePath = (Join-Path $PSScriptRoot "../../analysis/d4_closure_control_queue.csv"),
    [string]$OutputImpactedTargetsPath = (Join-Path $PSScriptRoot "../../analysis/d4_impacted_source_object_targets.csv"),
    [string]$OutputMetadataRetryPath = (Join-Path $PSScriptRoot "../../analysis/d4_metadata_retry_targets.csv"),
    [string]$OutputMissingTargetPath = (Join-Path $PSScriptRoot "../../analysis/d4_missing_metadata_target_queue.csv"),
    [string]$OutputNativeQueryPath = (Join-Path $PSScriptRoot "../../analysis/d4_native_query_review_targets.csv"),
    [string]$OutputDecisionTemplatePath = (Join-Path $PSScriptRoot "../../analysis/d4_object_type_decision_template.csv"),
    [string]$OutputReadonlyPlanPath = (Join-Path $PSScriptRoot "../../analysis/d4_external_readonly_action_plan.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/d4_closure_control_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/38_d4_closure_control.md")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

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
    param([string]$Text, [int]$MaxLength = 900)
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
    if ($PriorityScore -ge 300) { return "critical" }
    if ($PriorityScore -ge 200) { return "high" }
    if ($PriorityScore -ge 100) { return "medium" }
    return "low"
}

function Get-UniqueJoined {
    param([object[]]$Rows, [string]$ColumnName, [int]$MaxValues = 15)
    $values = @(
        $Rows |
            ForEach-Object { Get-FieldValue -Object $_ -Names @($ColumnName) } |
            Where-Object { $_ } |
            Sort-Object -Unique |
            Select-Object -First $MaxValues
    )
    return ($values -join "; ")
}

function Get-GroupCounts {
    param([object[]]$Rows, [string]$ColumnName)
    return ((@(
        $Rows |
            Group-Object $ColumnName |
            Sort-Object @{ Expression = "Count"; Descending = $true }, Name |
            ForEach-Object { "$($_.Name)=$($_.Count)" }
    )) -join "; ")
}

function Get-ClosureOpportunity {
    param(
        [string]$RawObjectType,
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$MetadataGapReason
    )

    if ($MetadataGapReason -eq "object_name_found_in_multiple_schemas") {
        return "multiple_schema_disambiguation_required"
    }
    if ($MetadataGapReason -eq "object_not_found") {
        return "object_not_found_owner_review"
    }
    if ($MetadataGapReason -eq "metadata_query_failed") {
        return "metadata_retry_or_owner_catalog_required"
    }
    if ($MetadataGapReason -eq "missing_metadata_target" -or -not $SourceServer -or -not $SourceDatabase) {
        return "missing_metadata_target_mapping_required"
    }
    if ($RawObjectType -eq "native_query_object") {
        return "native_query_definition_review_required"
    }
    if (-not $MetadataGapReason) {
        return "no_gap_record_manual_review_required"
    }
    return "manual_exact_type_review_required"
}

function Get-RecommendedDecision {
    param([string]$ClosureOpportunity)
    switch ($ClosureOpportunity) {
        "metadata_retry_or_owner_catalog_required" { return "Retry read-only metadata where access/network is available, or use owner-approved catalog evidence." }
        "missing_metadata_target_mapping_required" { return "Resolve the missing server/database/lakehouse target from definitions, connections, OneLake paths, or owner evidence before exact type resolution." }
        "object_not_found_owner_review" { return "Ask owner/catalog to confirm whether the object was renamed, deleted, generated dynamically, or wrongly parsed." }
        "multiple_schema_disambiguation_required" { return "Resolve the schema explicitly from query/model definition or owner-approved catalog evidence." }
        "native_query_definition_review_required" { return "Review native query text and map the reference to table, view, stored_procedure, file, shortcut, or query." }
        default { return "Review manually and close with resolved, rejected, access_denied, not_available, dynamic_reference, or manual_review_required." }
    }
}

function Get-ReadonlyAction {
    param([string]$ClosureOpportunity)
    switch ($ClosureOpportunity) {
        "metadata_retry_or_owner_catalog_required" { return "Run the approved read-only metadata extractor for the target endpoint/database, or capture owner-approved catalog evidence." }
        "missing_metadata_target_mapping_required" { return "Inspect local definitions, connections, OneLake paths, or owner evidence to identify the missing metadata target." }
        "object_not_found_owner_review" { return "Review source catalog/owner evidence to decide whether the object is not available, renamed, dynamic, or a parser false positive." }
        "multiple_schema_disambiguation_required" { return "Inspect source query/model definition to choose the correct schema among metadata matches." }
        "native_query_definition_review_required" { return "Read native query/model expression text and classify the referenced object kind." }
        default { return "Read available local/owner evidence and record the exact object type or explicit closure status." }
    }
}

if (-not (Test-Path $D4SourceQueuePath)) {
    throw "Required input not found: $D4SourceQueuePath"
}

$sourceRows = @(Import-Csv -Path $D4SourceQueuePath)
$impactRows = if ((Test-Path $D4ImpactQueuePath) -and ((Get-Item $D4ImpactQueuePath).Length -gt 0)) { @(Import-Csv -Path $D4ImpactQueuePath) } else { @() }

$impactsBySourceId = @{}
foreach ($impact in $impactRows) {
    Add-ListMapValue -Map $impactsBySourceId -Key (Get-FieldValue -Object $impact -Names @("source_id")) -Value $impact
}

$controlRows = [System.Collections.Generic.List[object]]::new()
$impactedRows = [System.Collections.Generic.List[object]]::new()
$metadataRetryRows = [System.Collections.Generic.List[object]]::new()
$missingTargetRows = [System.Collections.Generic.List[object]]::new()
$nativeQueryRows = [System.Collections.Generic.List[object]]::new()
$decisionRows = [System.Collections.Generic.List[object]]::new()
$readonlyRows = [System.Collections.Generic.List[object]]::new()

$sequence = 0
foreach ($source in ($sourceRows | Sort-Object @{ Expression = { Convert-ToInt (Get-FieldValue -Object $_ -Names @("priority_score")) }; Descending = $true }, source_id)) {
    $sequence++
    $d4Id = "D4C{0:0000}" -f $sequence
    $sourceId = Get-FieldValue -Object $source -Names @("source_id")
    $rawObjectType = Get-FieldValue -Object $source -Names @("raw_object_type")
    $sourceServer = Get-FieldValue -Object $source -Names @("source_server")
    $sourceDatabase = Get-FieldValue -Object $source -Names @("source_database")
    $metadataGapReason = Get-FieldValue -Object $source -Names @("metadata_gap_reason")
    $impactForSource = if ($impactsBySourceId.ContainsKey($sourceId)) { @($impactsBySourceId[$sourceId]) } else { @() }
    $priorityScore = Convert-ToInt (Get-FieldValue -Object $source -Names @("priority_score"))
    $closureOpportunity = Get-ClosureOpportunity `
        -RawObjectType $rawObjectType `
        -SourceServer $sourceServer `
        -SourceDatabase $sourceDatabase `
        -MetadataGapReason $metadataGapReason
    $recommendedDecision = Get-RecommendedDecision -ClosureOpportunity $closureOpportunity
    $readonlyAction = Get-ReadonlyAction -ClosureOpportunity $closureOpportunity
    $impactPriority = if (@($impactForSource).Count -gt 0) { "direct_d4_impact" } else { "catalog_or_future_impact" }
    $allowedTypes = "table; view; stored_procedure; file; shortcut; query; function; schema"
    $allowedStatuses = "resolved; rejected; access_denied; not_available; dynamic_reference; manual_review_required; multiple_matches"

    $controlRow = [pscustomobject]@{
        d4_id = $d4Id
        source_id = $sourceId
        priority_score = $priorityScore
        priority_band = Get-FieldValue -Object $source -Names @("priority_band")
        impact_priority = $impactPriority
        closure_opportunity = $closureOpportunity
        source_type = Get-FieldValue -Object $source -Names @("source_type")
        source_server = $sourceServer
        source_database = $sourceDatabase
        schema_name = Get-FieldValue -Object $source -Names @("schema_name")
        object_name = Get-FieldValue -Object $source -Names @("object_name")
        raw_object_type = $rawObjectType
        current_resolved_object_type = Get-FieldValue -Object $source -Names @("current_resolved_object_type")
        resolver_source = Get-FieldValue -Object $source -Names @("resolver_source")
        resolver_confidence = Get-FieldValue -Object $source -Names @("resolver_confidence")
        impact_row_count = @($impactForSource).Count
        affected_item_count = Convert-ToInt (Get-FieldValue -Object $source -Names @("affected_item_count"))
        semantic_model_count = Convert-ToInt (Get-FieldValue -Object $source -Names @("semantic_model_count"))
        operation_split = Get-GroupCounts -Rows $impactForSource -ColumnName "operation_type"
        impact_item_type_split = Get-GroupCounts -Rows $impactForSource -ColumnName "item_type"
        metadata_gap_reason = $metadataGapReason
        metadata_error = Limit-Text -Text (Get-FieldValue -Object $source -Names @("metadata_error")) -MaxLength 900
        workspaces = Limit-Text -Text (Get-FieldValue -Object $source -Names @("workspaces")) -MaxLength 900
        affected_items_sample = Limit-Text -Text (Get-FieldValue -Object $source -Names @("affected_items_sample")) -MaxLength 900
        allowed_exact_types = $allowedTypes
        recommended_d4_decision = $recommendedDecision
        readonly_action = $readonlyAction
        decision_template_path = $OutputDecisionTemplatePath
    }
    $controlRows.Add($controlRow) | Out-Null

    if (@($impactForSource).Count -gt 0) { $impactedRows.Add($controlRow) | Out-Null }
    if ($closureOpportunity -eq "metadata_retry_or_owner_catalog_required") { $metadataRetryRows.Add($controlRow) | Out-Null }
    if ($closureOpportunity -eq "missing_metadata_target_mapping_required") { $missingTargetRows.Add($controlRow) | Out-Null }
    if ($rawObjectType -eq "native_query_object") { $nativeQueryRows.Add($controlRow) | Out-Null }

    $decisionRows.Add([pscustomobject]@{
        d4_id = $d4Id
        source_id = $sourceId
        source_type = Get-FieldValue -Object $source -Names @("source_type")
        source_server = $sourceServer
        source_database = $sourceDatabase
        schema_name = Get-FieldValue -Object $source -Names @("schema_name")
        object_name = Get-FieldValue -Object $source -Names @("object_name")
        raw_object_type = $rawObjectType
        current_resolved_object_type = Get-FieldValue -Object $source -Names @("current_resolved_object_type")
        closure_opportunity = $closureOpportunity
        proposed_status = ""
        allowed_statuses = $allowedStatuses
        confirmed_object_type = ""
        allowed_exact_types = $allowedTypes
        confirmation_source = ""
        confirmation_evidence = ""
        reviewer = ""
        reviewed_at = ""
        next_action = $recommendedDecision
        notes = "Fill this row before treating D4 as closed for the source object. Do not apply overrides without human approval."
    }) | Out-Null

    $readonlyRows.Add([pscustomobject]@{
        d4_id = $d4Id
        source_id = $sourceId
        priority_score = $priorityScore
        priority_band = Get-FieldValue -Object $source -Names @("priority_band")
        impact_priority = $impactPriority
        closure_opportunity = $closureOpportunity
        source_type = Get-FieldValue -Object $source -Names @("source_type")
        source_server = $sourceServer
        source_database = $sourceDatabase
        schema_name = Get-FieldValue -Object $source -Names @("schema_name")
        object_name = Get-FieldValue -Object $source -Names @("object_name")
        raw_object_type = $rawObjectType
        human_readonly_action = $readonlyAction
        suggested_readonly_command = if ($closureOpportunity -eq "metadata_retry_or_owner_catalog_required") { "pwsh -NoLogo -File backend/scripts/20_extract_source_object_type_metadata.ps1 -AzCommand az -TrustServerCertificate" } else { "" }
        decision_template_path = $OutputDecisionTemplatePath
        notes = "Read-only/manual D4 action. Do not query external metadata or apply object type overrides without human approval."
    }) | Out-Null
}

$summaryRows = [System.Collections.Generic.List[object]]::new()
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D4 closure control rows"; row_count = @($controlRows).Count; notes = "One row per ambiguous source object." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Directly impacted source objects"; row_count = @($impactedRows).Count; notes = "Source objects with current D4 impacted object rows." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Metadata retry targets"; row_count = @($metadataRetryRows).Count; notes = "Targets where read-only metadata query failed and can be retried or replaced by owner catalog evidence." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Missing metadata target rows"; row_count = @($missingTargetRows).Count; notes = "Rows missing usable server/database/lakehouse metadata target." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "Native query review targets"; row_count = @($nativeQueryRows).Count; notes = "Rows with raw object type native_query_object." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "D4 decision rows"; row_count = @($decisionRows).Count; notes = "One decision row per ambiguous source object." }) | Out-Null
$summaryRows.Add([pscustomobject]@{ summary_scope = "total"; group_key = "External read-only action rows"; row_count = @($readonlyRows).Count; notes = "One read-only/manual action row per ambiguous source object." }) | Out-Null
foreach ($group in @($controlRows | Group-Object closure_opportunity | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "closure_opportunity"; group_key = $group.Name; row_count = $group.Count; notes = "D4 rows grouped by closure path." }) | Out-Null
}
foreach ($group in @($controlRows | Group-Object raw_object_type | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "raw_object_type"; group_key = $group.Name; row_count = $group.Count; notes = "D4 rows grouped by raw ambiguous object type." }) | Out-Null
}
foreach ($group in @($controlRows | Group-Object impact_priority | Sort-Object Name)) {
    $summaryRows.Add([pscustomobject]@{ summary_scope = "impact_priority"; group_key = $group.Name; row_count = $group.Count; notes = "D4 rows grouped by direct impact status." }) | Out-Null
}

$controlColumns = @(
    "d4_id", "source_id", "priority_score", "priority_band", "impact_priority",
    "closure_opportunity", "source_type", "source_server", "source_database",
    "schema_name", "object_name", "raw_object_type", "current_resolved_object_type",
    "resolver_source", "resolver_confidence", "impact_row_count", "affected_item_count",
    "semantic_model_count", "operation_split", "impact_item_type_split", "metadata_gap_reason",
    "metadata_error", "workspaces", "affected_items_sample", "allowed_exact_types",
    "recommended_d4_decision", "readonly_action", "decision_template_path"
)
$decisionColumns = @(
    "d4_id", "source_id", "source_type", "source_server", "source_database",
    "schema_name", "object_name", "raw_object_type", "current_resolved_object_type",
    "closure_opportunity", "proposed_status", "allowed_statuses", "confirmed_object_type",
    "allowed_exact_types", "confirmation_source", "confirmation_evidence", "reviewer",
    "reviewed_at", "next_action", "notes"
)
$readonlyColumns = @(
    "d4_id", "source_id", "priority_score", "priority_band", "impact_priority",
    "closure_opportunity", "source_type", "source_server", "source_database",
    "schema_name", "object_name", "raw_object_type", "human_readonly_action",
    "suggested_readonly_command", "decision_template_path", "notes"
)
$summaryColumns = @("summary_scope", "group_key", "row_count", "notes")

Export-Rows -Rows @($controlRows) -Columns $controlColumns -Path $OutputControlQueuePath
Export-Rows -Rows @($impactedRows) -Columns $controlColumns -Path $OutputImpactedTargetsPath
Export-Rows -Rows @($metadataRetryRows) -Columns $controlColumns -Path $OutputMetadataRetryPath
Export-Rows -Rows @($missingTargetRows) -Columns $controlColumns -Path $OutputMissingTargetPath
Export-Rows -Rows @($nativeQueryRows) -Columns $controlColumns -Path $OutputNativeQueryPath
Export-Rows -Rows @($decisionRows) -Columns $decisionColumns -Path $OutputDecisionTemplatePath
Export-Rows -Rows @($readonlyRows) -Columns $readonlyColumns -Path $OutputReadonlyPlanPath
Export-Rows -Rows @($summaryRows) -Columns $summaryColumns -Path $OutputSummaryPath

Ensure-ParentDirectory -Path $OutputDocPath
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# D4 Closure Control") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated by backend/scripts/42_build_d4_closure_control.ps1 from local project artifacts only.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Start D4 closure without guessing exact object types. Every ambiguous source object must close as resolved, rejected, access_denied, not_available, dynamic_reference, manual_review_required, or multiple_matches before its type can be used as a hard impact or orchestration rule.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- $OutputControlQueuePath") | Out-Null
$doc.Add("- $OutputImpactedTargetsPath") | Out-Null
$doc.Add("- $OutputMetadataRetryPath") | Out-Null
$doc.Add("- $OutputMissingTargetPath") | Out-Null
$doc.Add("- $OutputNativeQueryPath") | Out-Null
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
$doc.Add("- Prioritize directly impacted source objects first, because they currently block confirmed read/write rows.") | Out-Null
$doc.Add("- Metadata retry rows require human-approved read-only access or owner-approved catalog evidence.") | Out-Null
$doc.Add("- Missing metadata target rows must first resolve the source endpoint/database/lakehouse before exact type can be trusted.") | Out-Null
$doc.Add("- Native query rows require query/model definition review when metadata cannot directly classify the reference.") | Out-Null
$doc.Add("- Do not write object type overrides until the decision template has status, exact type, source, evidence, reviewer, and reviewed date.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Next Human Step") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('Review `analysis/d4_impacted_source_object_targets.csv` first, then `analysis/d4_metadata_retry_targets.csv` for approved read-only metadata retries or owner catalog evidence.') | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "D4 closure control built."
Write-Host "Closure control rows: $(@($controlRows).Count)"
Write-Host "Impacted targets: $(@($impactedRows).Count)"
Write-Host "Metadata retry targets: $(@($metadataRetryRows).Count)"
Write-Host "Missing metadata target rows: $(@($missingTargetRows).Count)"
