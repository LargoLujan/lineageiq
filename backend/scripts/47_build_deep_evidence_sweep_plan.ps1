# Phase 47 - Deep evidence sweep plan ("E1"): the phase after D1-D8 --
# takes everything still unresolved once the whole D-family has closed out
# what it can, and plans one final sweep: notebooks needing manual code
# review, semantic models needing manual review, SQL objects needing
# metadata, and remaining likely-evidence targets.
# Writes: $OutputScopeSummaryPath, $OutputNotebookQueuePath,
# $OutputSemanticQueuePath, $OutputSqlMetadataQueuePath,
# $OutputLikelyTargetsPath, $OutputReadonlyPlanPath, $OutputDocPath.
param(
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$DependenciesPath = (Join-Path $PSScriptRoot "../../index/dependencies.csv"),
    [string]$ObjectReadWritePath = (Join-Path $PSScriptRoot "../../analysis/object_read_write_classification.csv"),
    [string]$SemanticCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_view_candidates.csv"),
    [string]$SemanticGapsPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_definition_gaps.csv"),
    [string]$ItemObjectGapsPath = (Join-Path $PSScriptRoot "../../analysis/item_object_lineage_gaps.csv"),
    [string]$D1ClosurePath = (Join-Path $PSScriptRoot "../../analysis/d1_closure_control_queue.csv"),
    [string]$D3ItemClosurePath = (Join-Path $PSScriptRoot "../../analysis/d3_item_closure_control_queue.csv"),
    [string]$D4SourceQueuePath = (Join-Path $PSScriptRoot "../../analysis/d4_exact_object_type_source_queue.csv"),
    [string]$D8RetestPath = (Join-Path $PSScriptRoot "../../analysis/d8_parallel_candidate_retest_queue.csv"),
    [string]$SourceMetadataEvidencePath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_metadata_evidence.csv"),
    [string]$SqlEndpointCatalogPath = (Join-Path $PSScriptRoot "../../analysis/sql_endpoint_object_catalog.csv"),
    [string]$OutputScopeSummaryPath = (Join-Path $PSScriptRoot "../../analysis/e1_deep_evidence_scope_summary.csv"),
    [string]$OutputNotebookQueuePath = (Join-Path $PSScriptRoot "../../analysis/e1_notebook_code_review_queue.csv"),
    [string]$OutputSemanticQueuePath = (Join-Path $PSScriptRoot "../../analysis/e1_semantic_model_review_queue.csv"),
    [string]$OutputSqlMetadataQueuePath = (Join-Path $PSScriptRoot "../../analysis/e1_sql_object_metadata_queue.csv"),
    [string]$OutputLikelyTargetsPath = (Join-Path $PSScriptRoot "../../analysis/e1_likely_resolution_targets.csv"),
    [string]$OutputReadonlyPlanPath = (Join-Path $PSScriptRoot "../../analysis/e1_external_readonly_action_plan.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/43_deep_evidence_sweep_plan.md")
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

function Normalize-Key {
    param([string]$Value)
    if (-not $Value) { return "" }
    return ($Value.ToLowerInvariant() -replace "\s+", " ").Trim()
}

function Normalize-Name {
    param([string]$Value)
    if (-not $Value) { return "" }
    return (($Value.ToLowerInvariant() -replace "\.notebook$", "") -replace "[^a-z0-9]+", " ").Trim()
}

function Limit-Text {
    param([string]$Text, [int]$MaxLength = 900)
    if (-not $Text) { return "" }
    $clean = ($Text -replace "\s+", " ").Trim()
    if ($clean.Length -le $MaxLength) { return $clean }
    return $clean.Substring(0, $MaxLength - 3) + "..."
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

function Add-Unique {
    param([System.Collections.Generic.List[string]]$List, [string]$Value)
    if ($Value -and -not $List.Contains($Value)) {
        $List.Add($Value) | Out-Null
    }
}

function Join-Unique {
    param([string[]]$Values, [int]$MaxValues = 25)
    return ((@(
        $Values |
            Where-Object { $_ } |
            Sort-Object -Unique |
            Select-Object -First $MaxValues
    )) -join "; ")
}

function Build-ObjectKeyFromParts {
    param(
        [string]$SourceType,
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$SchemaName,
        [string]$ObjectName
    )
    return ((Normalize-Key $SourceType) + "|" + (Normalize-Key $SourceServer) + "|" + (Normalize-Key $SourceDatabase) + "|" + (Normalize-Key $SchemaName) + "|" + (Normalize-Key $ObjectName))
}

function Build-WildcardObjectKeyFromParts {
    param(
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$SchemaName,
        [string]$ObjectName
    )
    return ("*|" + (Normalize-Key $SourceServer) + "|" + (Normalize-Key $SourceDatabase) + "|" + (Normalize-Key $SchemaName) + "|" + (Normalize-Key $ObjectName))
}

function Get-ObjectEvidenceRows {
    param(
        [hashtable]$Map,
        [string[]]$Keys
    )
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($lookupKey in @($Keys | Where-Object { $_ } | Select-Object -Unique)) {
        if ($Map.ContainsKey($lookupKey)) {
            foreach ($row in @($Map[$lookupKey])) { $rows.Add($row) | Out-Null }
        }
    }
    return @($rows)
}

function Get-PriorityBand {
    param([int]$PriorityScore)
    if ($PriorityScore -ge 85) { return "critical" }
    if ($PriorityScore -ge 75) { return "high" }
    if ($PriorityScore -ge 60) { return "medium" }
    return "low"
}

if (-not (Test-Path $ItemsPath)) { throw "Required input not found: $ItemsPath" }

$items = @(Import-Csv -Path $ItemsPath)
$dependencies = Import-OptionalCsv -Path $DependenciesPath
$rwRows = Import-OptionalCsv -Path $ObjectReadWritePath
$semanticRows = Import-OptionalCsv -Path $SemanticCandidatesPath
$semanticGaps = Import-OptionalCsv -Path $SemanticGapsPath
$itemObjectGaps = Import-OptionalCsv -Path $ItemObjectGapsPath
$d1Rows = Import-OptionalCsv -Path $D1ClosurePath
$d3ItemRows = Import-OptionalCsv -Path $D3ItemClosurePath
$d4Rows = Import-OptionalCsv -Path $D4SourceQueuePath
$d8Rows = Import-OptionalCsv -Path $D8RetestPath
$metadataEvidenceRows = Import-OptionalCsv -Path $SourceMetadataEvidencePath
$sqlCatalogRows = Import-OptionalCsv -Path $SqlEndpointCatalogPath

$rwByItem = @{}
foreach ($row in $rwRows) {
    Add-ListMapValue -Map $rwByItem -Key (Normalize-Key (Get-FieldValue -Object $row -Names @("item_qualified_name"))) -Value $row
}

$d1ByItem = @{}
foreach ($row in $d1Rows) {
    Add-ListMapValue -Map $d1ByItem -Key (Normalize-Key (Get-FieldValue -Object $row -Names @("item_qualified_name"))) -Value $row
}

$d3ByItem = @{}
foreach ($row in $d3ItemRows) {
    Add-ListMapValue -Map $d3ByItem -Key (Normalize-Key (Get-FieldValue -Object $row -Names @("item_qualified_name"))) -Value $row
}

$gapByItem = @{}
foreach ($row in $itemObjectGaps) {
    Add-ListMapValue -Map $gapByItem -Key (Normalize-Key (Get-FieldValue -Object $row -Names @("item_qualified_name"))) -Value $row
}

$d8ByItem = @{}
foreach ($row in $d8Rows) {
    Add-ListMapValue -Map $d8ByItem -Key (Normalize-Key (Get-FieldValue -Object $row -Names @("candidate_a"))) -Value $row
    Add-ListMapValue -Map $d8ByItem -Key (Normalize-Key (Get-FieldValue -Object $row -Names @("candidate_b"))) -Value $row
}

$semanticRowsByModel = @{}
foreach ($row in $semanticRows) {
    Add-ListMapValue -Map $semanticRowsByModel -Key (Normalize-Key (Get-FieldValue -Object $row -Names @("semantic_model_qualified_name"))) -Value $row
}

$semanticGapByModel = @{}
foreach ($row in $semanticGaps) {
    Add-ListMapValue -Map $semanticGapByModel -Key (Normalize-Key (Get-FieldValue -Object $row -Names @("semantic_model_qualified_name"))) -Value $row
}

$d4ByObjectKey = @{}
foreach ($row in $d4Rows) {
    $objectKey = Build-ObjectKeyFromParts `
        -SourceType (Get-FieldValue -Object $row -Names @("source_type")) `
        -SourceServer (Get-FieldValue -Object $row -Names @("source_server")) `
        -SourceDatabase (Get-FieldValue -Object $row -Names @("source_database")) `
        -SchemaName (Get-FieldValue -Object $row -Names @("schema_name")) `
        -ObjectName (Get-FieldValue -Object $row -Names @("object_name"))
    Add-ListMapValue -Map $d4ByObjectKey -Key $objectKey -Value $row
    $wildcardKey = Build-WildcardObjectKeyFromParts `
        -SourceServer (Get-FieldValue -Object $row -Names @("source_server")) `
        -SourceDatabase (Get-FieldValue -Object $row -Names @("source_database")) `
        -SchemaName (Get-FieldValue -Object $row -Names @("schema_name")) `
        -ObjectName (Get-FieldValue -Object $row -Names @("object_name"))
    Add-ListMapValue -Map $d4ByObjectKey -Key $wildcardKey -Value $row
}

$metadataEvidenceByObjectKey = @{}
foreach ($row in $metadataEvidenceRows) {
    $objectKey = Build-ObjectKeyFromParts `
        -SourceType (Get-FieldValue -Object $row -Names @("source_type")) `
        -SourceServer (Get-FieldValue -Object $row -Names @("source_server")) `
        -SourceDatabase (Get-FieldValue -Object $row -Names @("source_database")) `
        -SchemaName (Get-FieldValue -Object $row -Names @("schema_name", "metadata_schema_name")) `
        -ObjectName (Get-FieldValue -Object $row -Names @("object_name", "metadata_object_name"))
    Add-ListMapValue -Map $metadataEvidenceByObjectKey -Key $objectKey -Value $row
    $wildcardKey = Build-WildcardObjectKeyFromParts `
        -SourceServer (Get-FieldValue -Object $row -Names @("source_server")) `
        -SourceDatabase (Get-FieldValue -Object $row -Names @("source_database")) `
        -SchemaName (Get-FieldValue -Object $row -Names @("schema_name", "metadata_schema_name")) `
        -ObjectName (Get-FieldValue -Object $row -Names @("object_name", "metadata_object_name"))
    Add-ListMapValue -Map $metadataEvidenceByObjectKey -Key $wildcardKey -Value $row
}

$sqlCatalogByObjectKey = @{}
foreach ($row in $sqlCatalogRows) {
    Add-ListMapValue -Map $sqlCatalogByObjectKey -Key (Normalize-Key (Get-FieldValue -Object $row -Names @("object_key"))) -Value $row
    $objectKey = Build-ObjectKeyFromParts `
        -SourceType (Get-FieldValue -Object $row -Names @("source_type")) `
        -SourceServer (Get-FieldValue -Object $row -Names @("source_server")) `
        -SourceDatabase (Get-FieldValue -Object $row -Names @("source_database")) `
        -SchemaName (Get-FieldValue -Object $row -Names @("schema_name")) `
        -ObjectName (Get-FieldValue -Object $row -Names @("object_name"))
    Add-ListMapValue -Map $sqlCatalogByObjectKey -Key $objectKey -Value $row
    $wildcardKey = Build-WildcardObjectKeyFromParts `
        -SourceServer (Get-FieldValue -Object $row -Names @("source_server")) `
        -SourceDatabase (Get-FieldValue -Object $row -Names @("source_database")) `
        -SchemaName (Get-FieldValue -Object $row -Names @("schema_name")) `
        -ObjectName (Get-FieldValue -Object $row -Names @("object_name"))
    Add-ListMapValue -Map $sqlCatalogByObjectKey -Key $wildcardKey -Value $row
}

$localNotebookDefsByName = @{}
foreach ($path in @(".tmp", "_fabric_exports")) {
    if (-not (Test-Path $path)) { continue }
    foreach ($file in @(Get-ChildItem -Path $path -Recurse -File -Filter "notebook-content.ipynb" -ErrorAction SilentlyContinue)) {
        $parentName = Split-Path -Leaf (Split-Path -Parent $file.FullName)
        $nameKey = Normalize-Name -Value $parentName
        Add-ListMapValue -Map $localNotebookDefsByName -Key $nameKey -Value $file.FullName
    }
}

$notebookQueue = [System.Collections.Generic.List[object]]::new()
foreach ($item in ($items | Where-Object { $_.item_type -eq "Notebook" } | Sort-Object workspace_name, item_name)) {
    $qualifiedName = Get-FieldValue -Object $item -Names @("qualified_name")
    $itemKey = Normalize-Key $qualifiedName
    $nameKey = Normalize-Name -Value (Get-FieldValue -Object $item -Names @("item_name"))
    $objects = if ($rwByItem.ContainsKey($itemKey)) { @($rwByItem[$itemKey]) } else { @() }
    $d1Targets = if ($d1ByItem.ContainsKey($itemKey)) { @($d1ByItem[$itemKey]) } else { @() }
    $d3Targets = if ($d3ByItem.ContainsKey($itemKey)) { @($d3ByItem[$itemKey]) } else { @() }
    $gapTargets = if ($gapByItem.ContainsKey($itemKey)) { @($gapByItem[$itemKey]) } else { @() }
    $d8Targets = if ($d8ByItem.ContainsKey($itemKey)) { @($d8ByItem[$itemKey]) } else { @() }
    $localDefs = if ($localNotebookDefsByName.ContainsKey($nameKey)) { @($localNotebookDefsByName[$nameKey]) } else { @() }
    $likelyObjectRows = @($objects | Where-Object { (Get-FieldValue -Object $_ -Names @("lineage_confidence")) -eq "likely" })
    $ambiguousObjects = @($objects | Where-Object { (Get-FieldValue -Object $_ -Names @("object_type_status")) -eq "ambiguous" })
    $writeRows = @($objects | Where-Object { (Get-FieldValue -Object $_ -Names @("operation_type")) -eq "write" })
    $unknownRows = @($objects | Where-Object { (Get-FieldValue -Object $_ -Names @("operation_type")) -eq "unknown" -or -not (Get-FieldValue -Object $_ -Names @("operation_type")) })
    $priority = (@($d1Targets).Count * 40) + (@($d3Targets).Count * 20) + (@($d8Targets).Count * 10) + (@($writeRows).Count * 2) + (@($unknownRows).Count * 5)
    $priorityBand = Get-PriorityBand -PriorityScore $priority
    $reviewStatus = if (@($d1Targets).Count -gt 0) { "needs_full_code_review_for_missing_objects" } elseif (@($likelyObjectRows).Count -gt 0 -or @($ambiguousObjects).Count -gt 0) { "needs_code_confirmation" } else { "covered_by_current_local_evidence" }

    $notebookQueue.Add([pscustomobject]@{
        item_qualified_name = $qualifiedName
        workspace_name = Get-FieldValue -Object $item -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $item -Names @("workspace_environment")
        item_name = Get-FieldValue -Object $item -Names @("item_name")
        priority_score = $priority
        priority_band = $priorityBand
        review_status = $reviewStatus
        object_row_count = @($objects).Count
        likely_object_rows = @($likelyObjectRows).Count
        ambiguous_object_rows = @($ambiguousObjects).Count
        write_object_rows = @($writeRows).Count
        unknown_operation_rows = @($unknownRows).Count
        linked_d1_ids = Join-Unique -Values @($d1Targets | ForEach-Object { Get-FieldValue -Object $_ -Names @("d1_id") })
        linked_d3_item_review_ids = Join-Unique -Values @($d3Targets | ForEach-Object { Get-FieldValue -Object $_ -Names @("item_review_id") })
        linked_d8_ids = Join-Unique -Values @($d8Targets | ForEach-Object { Get-FieldValue -Object $_ -Names @("d8_id") })
        local_definition_paths = Limit-Text -Text (Join-Unique -Values @($localDefs) -MaxValues 8) -MaxLength 1400
        gap_notes = Limit-Text -Text (Join-Unique -Values @($gapTargets | ForEach-Object { Get-FieldValue -Object $_ -Names @("notes", "error") }) -MaxValues 4) -MaxLength 900
        recommended_action = "Export/read the notebook definition, parse SQL/Spark/OneLake/JDBC references, classify reads/writes/executes, and update manual lineage evidence or parser rules."
    }) | Out-Null
}

$semanticQueue = [System.Collections.Generic.List[object]]::new()
foreach ($item in ($items | Where-Object { $_.item_type -eq "SemanticModel" } | Sort-Object workspace_name, item_name)) {
    $qualifiedName = Get-FieldValue -Object $item -Names @("qualified_name")
    $itemKey = Normalize-Key $qualifiedName
    $sources = if ($semanticRowsByModel.ContainsKey($itemKey)) { @($semanticRowsByModel[$itemKey]) } else { @() }
    $d3Targets = if ($d3ByItem.ContainsKey($itemKey)) { @($d3ByItem[$itemKey]) } else { @() }
    $gaps = if ($semanticGapByModel.ContainsKey($itemKey)) { @($semanticGapByModel[$itemKey]) } else { @() }
    $confirmed = @($sources | Where-Object { (Get-FieldValue -Object $_ -Names @("confidence")) -eq "confirmed" })
    $likely = @($sources | Where-Object { (Get-FieldValue -Object $_ -Names @("confidence")) -eq "likely" })
    $native = @($sources | Where-Object { (Get-FieldValue -Object $_ -Names @("object_type")) -eq "native_query_object" })
    $sp = @($sources | Where-Object { (Get-FieldValue -Object $_ -Names @("object_type")) -eq "stored_procedure" })
    $tableView = @($sources | Where-Object { (Get-FieldValue -Object $_ -Names @("object_type")) -eq "table_or_view" })
    $priority = (@($likely).Count * 5) + (@($native).Count * 4) + (@($sp).Count * 3) + (@($gaps).Count * 50) + (@($d3Targets).Count * 20)
    $priorityBand = Get-PriorityBand -PriorityScore $priority
    $reviewStatus = if (@($gaps).Count -gt 0) { "definition_export_blocked" } elseif (@($likely).Count -gt 0 -or @($native).Count -gt 0) { "needs_tmdl_m_query_review" } else { "covered_by_current_tmdl_evidence" }

    $semanticQueue.Add([pscustomobject]@{
        semantic_model_qualified_name = $qualifiedName
        workspace_name = Get-FieldValue -Object $item -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $item -Names @("workspace_environment")
        semantic_model_name = Get-FieldValue -Object $item -Names @("item_name")
        priority_score = $priority
        priority_band = $priorityBand
        review_status = $reviewStatus
        source_candidate_count = @($sources).Count
        confirmed_source_count = @($confirmed).Count
        likely_source_count = @($likely).Count
        native_query_count = @($native).Count
        stored_procedure_count = @($sp).Count
        table_or_view_count = @($tableView).Count
        linked_d3_item_review_ids = Join-Unique -Values @($d3Targets | ForEach-Object { Get-FieldValue -Object $_ -Names @("item_review_id") })
        definition_gap_status = Limit-Text -Text (Join-Unique -Values @($gaps | ForEach-Object { Get-FieldValue -Object $_ -Names @("notes", "error") }) -MaxValues 4) -MaxLength 900
        recommended_action = "Review exported TMDL/M expressions table by table, confirm native queries and stored procedures, and resolve table/view/SP type through SQL metadata."
    }) | Out-Null
}

$sqlAgg = @{}
foreach ($row in $rwRows) {
    $lineageConfidence = Get-FieldValue -Object $row -Names @("lineage_confidence")
    $objectTypeStatus = Get-FieldValue -Object $row -Names @("object_type_status")
    $operation = Get-FieldValue -Object $row -Names @("operation_type")
    if ($lineageConfidence -ne "likely" -and $objectTypeStatus -ne "ambiguous" -and $operation -ne "unknown") { continue }
    $objectKey = Build-ObjectKeyFromParts `
        -SourceType (Get-FieldValue -Object $row -Names @("source_type")) `
        -SourceServer (Get-FieldValue -Object $row -Names @("source_server")) `
        -SourceDatabase (Get-FieldValue -Object $row -Names @("source_database")) `
        -SchemaName (Get-FieldValue -Object $row -Names @("schema_name")) `
        -ObjectName (Get-FieldValue -Object $row -Names @("object_name"))
    if ($objectKey -eq "||||") {
        $objectKey = Normalize-Key (Get-FieldValue -Object $row -Names @("object_key"))
    }
    $normalizedObjectKey = Normalize-Key $objectKey
    if (-not $sqlAgg.ContainsKey($normalizedObjectKey)) {
        $sqlAgg[$normalizedObjectKey] = [ordered]@{
            object_key = $objectKey
            source_type = Get-FieldValue -Object $row -Names @("source_type")
            source_server = Get-FieldValue -Object $row -Names @("source_server")
            source_database = Get-FieldValue -Object $row -Names @("source_database")
            schema_name = Get-FieldValue -Object $row -Names @("schema_name")
            object_name = Get-FieldValue -Object $row -Names @("object_name")
            object_display_name = Get-FieldValue -Object $row -Names @("object_display_name")
            raw_object_type = Get-FieldValue -Object $row -Names @("raw_object_type", "object_type")
            impacted_items = [System.Collections.Generic.List[string]]::new()
            operations = [System.Collections.Generic.List[string]]::new()
            item_types = [System.Collections.Generic.List[string]]::new()
            likely_count = 0
            ambiguous_count = 0
            unknown_operation_count = 0
        }
    }
    $agg = $sqlAgg[$normalizedObjectKey]
    Add-Unique -List $agg.impacted_items -Value (Get-FieldValue -Object $row -Names @("item_qualified_name"))
    Add-Unique -List $agg.operations -Value $operation
    Add-Unique -List $agg.item_types -Value (Get-FieldValue -Object $row -Names @("item_type"))
    if ($lineageConfidence -eq "likely") { $agg.likely_count += 1 }
    if ($objectTypeStatus -eq "ambiguous") { $agg.ambiguous_count += 1 }
    if ($operation -eq "unknown" -or -not $operation) { $agg.unknown_operation_count += 1 }
}

$sqlQueue = [System.Collections.Generic.List[object]]::new()
foreach ($key in $sqlAgg.Keys) {
    $agg = $sqlAgg[$key]
    $lookupKeys = @(
        $key,
        (Build-WildcardObjectKeyFromParts -SourceServer $agg.source_server -SourceDatabase $agg.source_database -SchemaName $agg.schema_name -ObjectName $agg.object_name)
    ) | Select-Object -Unique
    $d4Targets = Get-ObjectEvidenceRows -Map $d4ByObjectKey -Keys $lookupKeys
    $metadataEvidence = Get-ObjectEvidenceRows -Map $metadataEvidenceByObjectKey -Keys $lookupKeys
    $catalogEvidence = Get-ObjectEvidenceRows -Map $sqlCatalogByObjectKey -Keys $lookupKeys
    $priority = ($agg.likely_count * 2) + ($agg.ambiguous_count * 3) + ($agg.unknown_operation_count * 10) + (@($d4Targets).Count * 8)
    $metadataStatus = if (@($metadataEvidence).Count -gt 0 -or @($catalogEvidence).Count -gt 0) { "metadata_evidence_available" } elseif (@($d4Targets).Count -gt 0) { "metadata_needed_for_d4" } else { "owner_or_definition_confirmation_needed" }
    $sqlQueue.Add([pscustomobject]@{
        object_key = $agg.object_key
        priority_score = $priority
        priority_band = Get-PriorityBand -PriorityScore $priority
        metadata_status = $metadataStatus
        source_type = $agg.source_type
        source_server = $agg.source_server
        source_database = $agg.source_database
        schema_name = $agg.schema_name
        object_name = $agg.object_name
        object_display_name = $agg.object_display_name
        raw_object_type = $agg.raw_object_type
        likely_reference_count = $agg.likely_count
        ambiguous_type_count = $agg.ambiguous_count
        unknown_operation_count = $agg.unknown_operation_count
        impacted_item_count = @($agg.impacted_items).Count
        operation_types = Join-Unique -Values @($agg.operations)
        impacted_item_types = Join-Unique -Values @($agg.item_types)
        linked_d4_source_ids = Join-Unique -Values @($d4Targets | ForEach-Object { Get-FieldValue -Object $_ -Names @("source_id") })
        existing_metadata_types = Join-Unique -Values @(
            @($metadataEvidence | ForEach-Object { Get-FieldValue -Object $_ -Names @("object_type", "metadata_type_desc") }) +
            @($catalogEvidence | ForEach-Object { Get-FieldValue -Object $_ -Names @("object_type", "metadata_type_desc") })
        )
        impacted_items_sample = Limit-Text -Text (Join-Unique -Values @($agg.impacted_items) -MaxValues 10) -MaxLength 1200
        recommended_action = "Resolve exact SQL/Fabric object type using sys.objects, INFORMATION_SCHEMA, Fabric SQL endpoint catalog, OneLake metadata, or owner-approved catalog evidence."
    }) | Out-Null
}

$likelyTargets = [System.Collections.Generic.List[object]]::new()
foreach ($row in ($notebookQueue | Where-Object { $_.review_status -ne "covered_by_current_local_evidence" } | Sort-Object @{ Expression = { Convert-ToInt $_.priority_score }; Descending = $true } | Select-Object -First 80)) {
    $likelyTargets.Add([pscustomobject]@{
        target_type = "notebook_code_review"
        priority_score = $row.priority_score
        priority_band = $row.priority_band
        target_name = $row.item_qualified_name
        blocker_summary = "likely=$($row.likely_object_rows); ambiguous=$($row.ambiguous_object_rows); D1=$($row.linked_d1_ids); D3=$($row.linked_d3_item_review_ids); D8=$($row.linked_d8_ids)"
        recommended_action = $row.recommended_action
        queue_path = $OutputNotebookQueuePath
    }) | Out-Null
}
foreach ($row in ($semanticQueue | Where-Object { $_.review_status -ne "covered_by_current_tmdl_evidence" } | Sort-Object @{ Expression = { Convert-ToInt $_.priority_score }; Descending = $true } | Select-Object -First 80)) {
    $likelyTargets.Add([pscustomobject]@{
        target_type = "semantic_model_tmdl_review"
        priority_score = $row.priority_score
        priority_band = $row.priority_band
        target_name = $row.semantic_model_qualified_name
        blocker_summary = "likely=$($row.likely_source_count); native=$($row.native_query_count); stored_procedure=$($row.stored_procedure_count); D3=$($row.linked_d3_item_review_ids)"
        recommended_action = $row.recommended_action
        queue_path = $OutputSemanticQueuePath
    }) | Out-Null
}
foreach ($row in ($sqlQueue | Sort-Object @{ Expression = { Convert-ToInt $_.priority_score }; Descending = $true } | Select-Object -First 120)) {
    $likelyTargets.Add([pscustomobject]@{
        target_type = "sql_object_metadata_resolution"
        priority_score = $row.priority_score
        priority_band = $row.priority_band
        target_name = $row.object_display_name
        blocker_summary = "likely=$($row.likely_reference_count); ambiguous=$($row.ambiguous_type_count); unknown_operation=$($row.unknown_operation_count); D4=$($row.linked_d4_source_ids)"
        recommended_action = $row.recommended_action
        queue_path = $OutputSqlMetadataQueuePath
    }) | Out-Null
}

$readonlyPlan = [System.Collections.Generic.List[object]]::new()
$readonlyPlan.Add([pscustomobject]@{
    action_id = "E1A01"
    action_scope = "notebook_definitions"
    target_count = @($notebookQueue | Where-Object { $_.review_status -ne "covered_by_current_local_evidence" }).Count
    proposed_local_or_readonly_command = "pwsh -NoLogo -File backend/scripts/18_extract_item_object_lineage.ps1 -AzCommand az"
    writes_external_system = "no"
    requires_human_execution_or_approval = "yes"
    expected_output = "analysis/item_object_lineage_candidates.csv; analysis/item_object_lineage_gaps.csv; index/manual_lineage_object_evidence.csv updates only after review"
    notes = "Read notebook definitions/code and extract SQL, Spark, OneLake, JDBC/ODBC, table, view, stored procedure, file, and notebook-call references."
}) | Out-Null
$readonlyPlan.Add([pscustomobject]@{
    action_id = "E1A02"
    action_scope = "pipeline_and_copyjob_definitions"
    target_count = (@($items | Where-Object { $_.item_type -in @("DataPipeline", "CopyJob") }).Count)
    proposed_local_or_readonly_command = "pwsh -NoLogo -File backend/scripts/19_extract_pipeline_object_lineage.ps1 -AzCommand az"
    writes_external_system = "no"
    requires_human_execution_or_approval = "yes"
    expected_output = "analysis/pipeline_object_lineage_candidates.csv; analysis/pipeline_activity_lineage.csv; analysis/pipeline_object_lineage_gaps.csv"
    notes = "Read pipeline and CopyJob definitions and distinguish direct versus inherited child lineage."
}) | Out-Null
$readonlyPlan.Add([pscustomobject]@{
    action_id = "E1A03"
    action_scope = "semantic_model_tmdl"
    target_count = @($semanticQueue | Where-Object { $_.review_status -ne "covered_by_current_tmdl_evidence" }).Count
    proposed_local_or_readonly_command = "pwsh -NoLogo -File backend/scripts/09_enrich_semantic_model_views.ps1 -AzCommand az -MaxModels 400; pwsh -NoLogo -File backend/scripts/08_build_semantic_lineage.ps1"
    writes_external_system = "no"
    requires_human_execution_or_approval = "yes"
    expected_output = "analysis/semantic_model_view_candidates.csv; analysis/semantic_model_definition_gaps.csv"
    notes = "Export/read TMDL model definitions, then review M expressions, native queries, stored procedures, and table/view references."
}) | Out-Null
$readonlyPlan.Add([pscustomobject]@{
    action_id = "E1A04"
    action_scope = "sql_and_fabric_object_metadata"
    target_count = @($sqlQueue | Where-Object { $_.metadata_status -ne "metadata_evidence_available" }).Count
    proposed_local_or_readonly_command = "pwsh -NoLogo -File backend/scripts/20_extract_source_object_type_metadata.ps1 -AzCommand az -TrustServerCertificate; pwsh -NoLogo -File backend/scripts/34_extract_sql_endpoint_object_catalog.ps1 -AzCommand az -TrustServerCertificate"
    writes_external_system = "no"
    requires_human_execution_or_approval = "yes"
    expected_output = "analysis/source_object_type_metadata_evidence.csv; analysis/sql_endpoint_object_catalog.csv"
    notes = "Read sys.objects/INFORMATION_SCHEMA/Fabric SQL endpoint catalogs to resolve table, view, stored procedure, function, file, or query type."
}) | Out-Null

$scopeRows = [System.Collections.Generic.List[object]]::new()
$scopeRows.Add([pscustomobject]@{ scope = "current likely dependencies"; metric = "dependency_edges_likely"; value = @($dependencies | Where-Object { $_.confidence -eq "likely" }).Count; notes = "D2 confirmation target." }) | Out-Null
$scopeRows.Add([pscustomobject]@{ scope = "current likely object lineage"; metric = "object_rows_likely"; value = @($rwRows | Where-Object { $_.lineage_confidence -eq "likely" }).Count; notes = "D3 confirmation target." }) | Out-Null
$scopeRows.Add([pscustomobject]@{ scope = "current ambiguous object types"; metric = "object_type_ambiguous"; value = @($rwRows | Where-Object { $_.object_type_status -eq "ambiguous" }).Count; notes = "D4 exact object type target." }) | Out-Null
$scopeRows.Add([pscustomobject]@{ scope = "notebooks"; metric = "notebook_items"; value = @($notebookQueue).Count; notes = "Notebook-by-notebook review scope." }) | Out-Null
$scopeRows.Add([pscustomobject]@{ scope = "notebooks"; metric = "notebooks_requiring_review"; value = @($notebookQueue | Where-Object { $_.review_status -ne "covered_by_current_local_evidence" }).Count; notes = "Code review queue." }) | Out-Null
$scopeRows.Add([pscustomobject]@{ scope = "semantic models"; metric = "semantic_model_items"; value = @($semanticQueue).Count; notes = "Semantic model review scope." }) | Out-Null
$scopeRows.Add([pscustomobject]@{ scope = "semantic models"; metric = "semantic_models_requiring_review"; value = @($semanticQueue | Where-Object { $_.review_status -ne "covered_by_current_tmdl_evidence" }).Count; notes = "TMDL/M review queue." }) | Out-Null
$scopeRows.Add([pscustomobject]@{ scope = "sql metadata"; metric = "sql_object_metadata_targets"; value = @($sqlQueue).Count; notes = "Unique source object metadata targets." }) | Out-Null
$scopeRows.Add([pscustomobject]@{ scope = "sql metadata"; metric = "metadata_targets_without_evidence"; value = @($sqlQueue | Where-Object { $_.metadata_status -ne "metadata_evidence_available" }).Count; notes = "Read-only metadata or owner catalog needed." }) | Out-Null
$scopeRows.Add([pscustomobject]@{ scope = "resolution"; metric = "high_priority_resolution_targets"; value = @($likelyTargets).Count; notes = "Combined first-pass worklist across notebook, semantic, and SQL metadata queues." }) | Out-Null

$notebookColumns = @("item_qualified_name", "workspace_name", "workspace_environment", "item_name", "priority_score", "priority_band", "review_status", "object_row_count", "likely_object_rows", "ambiguous_object_rows", "write_object_rows", "unknown_operation_rows", "linked_d1_ids", "linked_d3_item_review_ids", "linked_d8_ids", "local_definition_paths", "gap_notes", "recommended_action")
$semanticColumns = @("semantic_model_qualified_name", "workspace_name", "workspace_environment", "semantic_model_name", "priority_score", "priority_band", "review_status", "source_candidate_count", "confirmed_source_count", "likely_source_count", "native_query_count", "stored_procedure_count", "table_or_view_count", "linked_d3_item_review_ids", "definition_gap_status", "recommended_action")
$sqlColumns = @("object_key", "priority_score", "priority_band", "metadata_status", "source_type", "source_server", "source_database", "schema_name", "object_name", "object_display_name", "raw_object_type", "likely_reference_count", "ambiguous_type_count", "unknown_operation_count", "impacted_item_count", "operation_types", "impacted_item_types", "linked_d4_source_ids", "existing_metadata_types", "impacted_items_sample", "recommended_action")
$targetColumns = @("target_type", "priority_score", "priority_band", "target_name", "blocker_summary", "recommended_action", "queue_path")
$readonlyColumns = @("action_id", "action_scope", "target_count", "proposed_local_or_readonly_command", "writes_external_system", "requires_human_execution_or_approval", "expected_output", "notes")
$scopeColumns = @("scope", "metric", "value", "notes")

Export-Rows -Rows @($scopeRows) -Columns $scopeColumns -Path $OutputScopeSummaryPath
Export-Rows -Rows @($notebookQueue | Sort-Object @{ Expression = { Convert-ToInt $_.priority_score }; Descending = $true }, workspace_name, item_name) -Columns $notebookColumns -Path $OutputNotebookQueuePath
Export-Rows -Rows @($semanticQueue | Sort-Object @{ Expression = { Convert-ToInt $_.priority_score }; Descending = $true }, workspace_name, semantic_model_name) -Columns $semanticColumns -Path $OutputSemanticQueuePath
Export-Rows -Rows @($sqlQueue | Sort-Object @{ Expression = { Convert-ToInt $_.priority_score }; Descending = $true }, source_server, source_database, schema_name, object_name) -Columns $sqlColumns -Path $OutputSqlMetadataQueuePath
Export-Rows -Rows @($likelyTargets | Sort-Object @{ Expression = { Convert-ToInt $_.priority_score }; Descending = $true }, target_type, target_name) -Columns $targetColumns -Path $OutputLikelyTargetsPath
Export-Rows -Rows @($readonlyPlan) -Columns $readonlyColumns -Path $OutputReadonlyPlanPath

Ensure-ParentDirectory -Path $OutputDocPath
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# E1 Deep Evidence Sweep Plan") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated by backend/scripts/47_build_deep_evidence_sweep_plan.ps1 from local project artifacts only.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Verdict") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("D1-D8 organized the open gaps and made the blockers explicit, but they did not automatically convert likely evidence into confirmed evidence. The remaining cleanup requires a deep technical sweep across notebook code, semantic model TMDL/M expressions, and SQL/Fabric object metadata.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- $OutputScopeSummaryPath") | Out-Null
$doc.Add("- $OutputNotebookQueuePath") | Out-Null
$doc.Add("- $OutputSemanticQueuePath") | Out-Null
$doc.Add("- $OutputSqlMetadataQueuePath") | Out-Null
$doc.Add("- $OutputLikelyTargetsPath") | Out-Null
$doc.Add("- $OutputReadonlyPlanPath") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Scope Summary") | Out-Null
$doc.Add("") | Out-Null
foreach ($row in @($scopeRows)) {
    $doc.Add("- $($row.scope) / $($row.metric): $($row.value)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Operating Rule") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- Review notebooks notebook-by-notebook and capture exact databases, schemas, tables, views, stored procedures, files, and called notebooks.") | Out-Null
$doc.Add("- Review semantic models table-by-table from TMDL/M expressions, especially native queries and stored procedure calls.") | Out-Null
$doc.Add("- Resolve SQL/Fabric objects through read-only metadata or owner-approved catalogs before promoting object types or read/write rules.") | Out-Null
$doc.Add("- Do not update Fabric, schedules, triggers, pipelines, repositories, or source systems from this plan.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Next Human Step") | Out-Null
$doc.Add("") | Out-Null
$doc.Add('Approve the read-only E1 extraction actions in `analysis/e1_external_readonly_action_plan.csv`, starting with notebook definitions and SQL/Fabric object metadata.') | Out-Null
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "E1 deep evidence sweep plan built."
Write-Host "Notebooks queued: $(@($notebookQueue).Count)"
Write-Host "Semantic models queued: $(@($semanticQueue).Count)"
Write-Host "SQL metadata targets: $(@($sqlQueue).Count)"
Write-Host "High-priority likely resolution targets: $(@($likelyTargets).Count)"
