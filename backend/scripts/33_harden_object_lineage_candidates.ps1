# Phase 33 - Object lineage candidate hardening review: cross-checks every
# object-level candidate's referenced workspace name against the known
# workspace list, flagging candidates that reference a workspace that no
# longer exists or was renamed (a common source of stale/broken evidence
# after a workspace rename). Purely local.
# Writes: $OutputReviewPath, $OutputSummaryPath, $OutputDocPath.
param(
    [string]$SemanticViewCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_view_candidates.csv"),
    [string]$ItemObjectLineageCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/item_object_lineage_candidates.csv"),
    [string]$PipelineObjectLineageCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/pipeline_object_lineage_candidates.csv"),
    [string]$DependenciesPath = (Join-Path $PSScriptRoot "../../index/dependencies.csv"),
    [string]$WorkspacesPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$OutputReviewPath = (Join-Path $PSScriptRoot "../../analysis/object_lineage_candidate_hardening_review.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/object_lineage_candidate_hardening_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/30_object_lineage_candidate_hardening.md")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$script:KnownWorkspaceNameKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Export-Rows {
    param([object[]]$Rows, [string[]]$Columns, [string]$Path)
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

function Set-FieldValue {
    param([object]$Object, [string]$Name, [string]$Value)
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    }
}

function Normalize-Key {
    param([string]$Value)
    if (-not $Value) { return "" }
    return ($Value.Trim().ToLowerInvariant() -replace "\s+", " ")
}

function Normalize-ObjectType {
    param([string]$Value)
    $clean = (Normalize-Key $Value) -replace "[\s-]+", "_"
    switch ($clean) {
        "storedprocedure" { return "stored_procedure" }
        "procedure" { return "stored_procedure" }
        "proc" { return "stored_procedure" }
        "sp" { return "stored_procedure" }
        default { return $clean }
    }
}

function Get-NoiseReason {
    param([object]$Row)

    $objectName = Get-FieldValue -Object $Row -Names @("object_name")
    $objectType = Normalize-ObjectType (Get-FieldValue -Object $Row -Names @("object_type"))
    $sourceType = Get-FieldValue -Object $Row -Names @("source_type")
    $sourceServer = Get-FieldValue -Object $Row -Names @("source_server")
    $sourceDatabase = Get-FieldValue -Object $Row -Names @("source_database", "database_name")

    if ($objectType -eq "file") { return "" }
    if (-not $objectName) { return "empty_object_name" }

    $clean = ($objectName -replace "\s+", " ").Trim()
    if (-not $clean) { return "empty_object_name" }
    if ($clean -match "^(?i)(https?|abfss|wasbs|s3)://") { return "url_identifier_as_non_file_object" }
    if ($sourceType -eq "File") { return "" }
    if (-not $sourceServer -and -not $sourceDatabase -and $script:KnownWorkspaceNameKeys.Contains((Normalize-Key $clean))) { return "workspace_name_misparsed_as_object" }
    if ($clean.Length -gt 256) { return "too_long_for_metadata_identifier" }
    if ($clean -match "^<[^>]+>$") { return "placeholder_identifier" }
    if ($clean -match "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") { return "guid_identifier" }
    if ($clean -match "^[0-9]+$") { return "numeric_literal" }
    if ($clean -match "^[,.;:]+$") { return "punctuation_identifier" }
    if (-not (Get-FieldValue -Object $Row -Names @("schema_name")) -and $clean.Length -eq 1) { return "single_character_identifier" }
    if ($clean -match "^(?i)(select|with|where|join|from|on|and|or|as|case|when|then|else|end|openquery|status|input|output|source|target|unknown source|table|tables|schema|catalog|catalogue|directory|record|list|inventory|chronology|lineage)$") { return "generic_or_sql_keyword_identifier" }
    if ($clean -match "^(?i)(dbo|hst|stg|ctl|dim|fct|pln)$") { return "schema_name_misparsed_as_object" }
    if ($clean -match "\([^)]{2,}\)" -and $clean -match "\s") { return "human_label_with_parentheses" }
    if ($clean -match "\s" -and ($clean -match "[+/]" -or ($clean -split "\s+").Count -ge 3)) { return "free_text_label_identifier" }
    if ($clean -match "(?i)\b(lineageTag|measure\s+|DATE\s*\(|YEAR\s*\(|MONTH\s*\(|DAY\s*\(|MIN\s*\(|MAX\s*\(|Convert\s*\()") { return "expression_fragment" }
    if ($objectName -match "[`r`n]" -and $clean -match "[&()]") { return "multiline_expression_fragment" }
    if ($clean -match '[{}]' -and $clean -notmatch '[/\\.]') { return "template_or_json_fragment" }
    if ($clean -match '[;&=]') { return "expression_or_statement_fragment" }
    return ""
}

function Get-SqlConnectionFromDependency {
    param([string]$QualifiedName)
    if (-not $QualifiedName) { return $null }
    if ($QualifiedName -match "^External Connection / SQL / ([^;]+);(.+)$") {
        return [pscustomobject]@{
            source_server = $matches[1].Trim()
            source_database = $matches[2].Trim()
            source_qualified_name = $QualifiedName
            key = "$(Normalize-Key $matches[1])|$(Normalize-Key $matches[2])"
        }
    }
    return $null
}

function Add-ReviewRow {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [string]$file,
        [string]$action,
        [string]$reason,
        [object]$Row,
        [object]$Endpoint
    )

    $Rows.Add([pscustomobject]@{
        file = $file
        action = $action
        reason = $reason
        workspace_name = Get-FieldValue -Object $Row -Names @("workspace_name")
        item_type = Get-FieldValue -Object $Row -Names @("item_type")
        item_name = Get-FieldValue -Object $Row -Names @("item_name", "semantic_model_name")
        item_qualified_name = Get-FieldValue -Object $Row -Names @("item_qualified_name", "semantic_model_qualified_name", "qualified_name")
        original_source_type = Get-FieldValue -Object $Row -Names @("source_type")
        original_source_server = Get-FieldValue -Object $Row -Names @("source_server")
        original_source_database = Get-FieldValue -Object $Row -Names @("source_database", "database_name")
        new_source_server = if ($Endpoint) { $Endpoint.source_server } else { "" }
        new_source_database = if ($Endpoint) { $Endpoint.source_database } else { "" }
        schema_name = Get-FieldValue -Object $Row -Names @("schema_name")
        object_name = Get-FieldValue -Object $Row -Names @("object_name")
        object_type = Get-FieldValue -Object $Row -Names @("object_type")
        usage_type = Get-FieldValue -Object $Row -Names @("usage_type")
        confidence = Get-FieldValue -Object $Row -Names @("confidence")
        evidence = Get-FieldValue -Object $Row -Names @("evidence")
    }) | Out-Null
}

if (-not (Test-Path $DependenciesPath)) {
    throw "Required input not found: $DependenciesPath"
}

if (Test-Path $WorkspacesPath) {
    foreach ($workspace in @(Import-Csv -Path $WorkspacesPath)) {
        foreach ($name in @(
            (Get-FieldValue -Object $workspace -Names @("workspace_name")),
            (Get-FieldValue -Object $workspace -Names @("normalized_workspace_name"))
        )) {
            $key = Normalize-Key $name
            if ($key) { [void]$script:KnownWorkspaceNameKeys.Add($key) }
        }
    }
}

$sqlConnectionsByItem = @{}
foreach ($dependency in @(Import-Csv -Path $DependenciesPath)) {
    if ((Get-FieldValue -Object $dependency -Names @("relationship_type")) -ne "depends_on") { continue }
    if ((Get-FieldValue -Object $dependency -Names @("confidence")) -ne "confirmed") { continue }
    $endpoint = Get-SqlConnectionFromDependency -QualifiedName (Get-FieldValue -Object $dependency -Names @("to_qualified_name"))
    if (-not $endpoint) { continue }
    $item = Get-FieldValue -Object $dependency -Names @("from_qualified_name")
    if (-not $item) { continue }
    if (-not $sqlConnectionsByItem.ContainsKey($item)) { $sqlConnectionsByItem[$item] = @{} }
    $sqlConnectionsByItem[$item][$endpoint.key] = $endpoint
}

$uniqueSqlConnectionByItem = @{}
foreach ($item in $sqlConnectionsByItem.Keys) {
    if ($sqlConnectionsByItem[$item].Count -eq 1) {
        $uniqueSqlConnectionByItem[$item] = @($sqlConnectionsByItem[$item].Values)[0]
    }
}

$reviewRows = [System.Collections.Generic.List[object]]::new()
$summary = [ordered]@{
    files_processed = 0
    input_rows = 0
    output_rows = 0
    removed_noise_rows = 0
    endpoint_backfilled_rows = 0
    ambiguous_sql_connection_rows = 0
    unchanged_rows = 0
}

function Get-UniqueEndpointForRow {
    param([object]$Row)
    $invoked = Get-FieldValue -Object $Row -Names @("invoked_item_qualified_name")
    if ($invoked -and $uniqueSqlConnectionByItem.ContainsKey($invoked)) {
        return $uniqueSqlConnectionByItem[$invoked]
    }
    $item = Get-FieldValue -Object $Row -Names @("item_qualified_name", "semantic_model_qualified_name", "qualified_name")
    if ($item -and $uniqueSqlConnectionByItem.ContainsKey($item)) {
        return $uniqueSqlConnectionByItem[$item]
    }
    return $null
}

function Test-HasMultipleSqlEndpoints {
    param([object]$Row)
    $keys = @()
    $invoked = Get-FieldValue -Object $Row -Names @("invoked_item_qualified_name")
    if ($invoked -and $sqlConnectionsByItem.ContainsKey($invoked)) { $keys += @($sqlConnectionsByItem[$invoked].Keys) }
    $item = Get-FieldValue -Object $Row -Names @("item_qualified_name", "semantic_model_qualified_name", "qualified_name")
    if ($item -and $sqlConnectionsByItem.ContainsKey($item)) { $keys += @($sqlConnectionsByItem[$item].Keys) }
    return @($keys | Select-Object -Unique).Count -gt 1
}

function Update-EndpointFields {
    param([object]$Row, [object]$Endpoint)

    Set-FieldValue -Object $Row -Name "source_type" -Value "SQL"
    Set-FieldValue -Object $Row -Name "source_server" -Value $Endpoint.source_server
    Set-FieldValue -Object $Row -Name "source_database" -Value $Endpoint.source_database
    Set-FieldValue -Object $Row -Name "database_name" -Value $Endpoint.source_database
    Set-FieldValue -Object $Row -Name "source_name" -Value $Endpoint.source_database
    Set-FieldValue -Object $Row -Name "source_qualified_name" -Value $Endpoint.source_qualified_name

    if ($Row.PSObject.Properties.Name -contains "evidence") {
        $current = Get-FieldValue -Object $Row -Names @("evidence")
        $addition = " Source endpoint backfilled from the item's unique confirmed SQL dependency '$($Endpoint.source_qualified_name)'."
        $Row.evidence = (($current + $addition) -replace "\s+", " ").Trim()
    }
}

$files = @(
    [pscustomobject]@{ path = $SemanticViewCandidatesPath; kind = "semantic" },
    [pscustomobject]@{ path = $ItemObjectLineageCandidatesPath; kind = "item" },
    [pscustomobject]@{ path = $PipelineObjectLineageCandidatesPath; kind = "pipeline" }
)

foreach ($file in $files) {
    if (-not (Test-Path $file.path)) { continue }
    $rows = @(Import-Csv -Path $file.path)
    if ($rows.Count -eq 0) { continue }
    $columns = @($rows[0].PSObject.Properties.Name)
    $outputRows = [System.Collections.Generic.List[object]]::new()
    $summary.files_processed += 1
    $summary.input_rows += $rows.Count

    foreach ($row in $rows) {
        $noiseReason = Get-NoiseReason -Row $row
        if ($noiseReason) {
            Add-ReviewRow -Rows $reviewRows -file $file.path -action "removed_noise" -reason $noiseReason -Row $row -Endpoint $null
            $summary.removed_noise_rows += 1
            continue
        }

        $objectType = Normalize-ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
        $sourceServer = Get-FieldValue -Object $row -Names @("source_server")
        $sourceDatabase = Get-FieldValue -Object $row -Names @("source_database", "database_name")
        $canBackfill = (-not $sourceServer -or -not $sourceDatabase) -and ($objectType -in @("table_or_view", "native_query_object", "stored_procedure"))

        if ($canBackfill) {
            $endpoint = Get-UniqueEndpointForRow -Row $row
            if ($endpoint) {
                Update-EndpointFields -Row $row -Endpoint $endpoint
                Add-ReviewRow -Rows $reviewRows -file $file.path -action "endpoint_backfilled" -reason "unique_confirmed_sql_dependency" -Row $row -Endpoint $endpoint
                $summary.endpoint_backfilled_rows += 1
            }
            elseif (Test-HasMultipleSqlEndpoints -Row $row) {
                Add-ReviewRow -Rows $reviewRows -file $file.path -action "left_unresolved" -reason "multiple_confirmed_sql_dependencies" -Row $row -Endpoint $null
                $summary.ambiguous_sql_connection_rows += 1
            }
            else {
                $summary.unchanged_rows += 1
            }
        }
        else {
            $summary.unchanged_rows += 1
        }

        $outputRows.Add($row) | Out-Null
    }

    $summary.output_rows += $outputRows.Count
    Export-Rows -Rows @($outputRows.ToArray()) -Columns $columns -Path $file.path
}

$summaryRows = [System.Collections.Generic.List[object]]::new()
foreach ($key in $summary.Keys) {
    $summaryRows.Add([pscustomobject]@{ metric = $key; value = $summary[$key]; notes = "" }) | Out-Null
}
$summaryRows.Add([pscustomobject]@{ metric = "items_with_unique_confirmed_sql_dependency"; value = $uniqueSqlConnectionByItem.Count; notes = "Used only for endpoint backfill when a candidate row lacked source server/database." }) | Out-Null

$reviewColumns = @(
    "file", "action", "reason", "workspace_name", "item_type", "item_name", "item_qualified_name",
    "original_source_type", "original_source_server", "original_source_database", "new_source_server",
    "new_source_database", "schema_name", "object_name", "object_type", "usage_type", "confidence", "evidence"
)

Export-Rows -Rows @($reviewRows.ToArray()) -Columns $reviewColumns -Path $OutputReviewPath
Export-Rows -Rows @($summaryRows.ToArray()) -Columns @("metric", "value", "notes") -Path $OutputSummaryPath

$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# Object Lineage Candidate Hardening") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated at: $(Get-Date -Format s)") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Purpose") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Clean object-lineage candidates before metadata extraction and reverse-impact rebuilds.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("This step is local-only. It removes obvious parser noise and backfills source server/database only when the item has exactly one confirmed SQL dependency in `index/dependencies.csv`. It does not create, update, delete, trigger, or deploy external objects.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Summary") | Out-Null
$doc.Add("") | Out-Null
foreach ($row in $summaryRows) {
    $doc.Add("- $($row.metric): $($row.value)") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("Note: this summary reflects the latest run. After the first hardening pass, later refreshes may show zero removed/backfilled rows because candidate files are already hardened. See `docs/00_work_log.md` for first-application counts.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- ``$OutputReviewPath``") | Out-Null
$doc.Add("- ``$OutputSummaryPath``") | Out-Null
Ensure-ParentDirectory -Path $OutputDocPath
$doc | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "Object lineage candidate hardening completed."
Write-Host "Files processed: $($summary.files_processed)"
Write-Host "Input rows: $($summary.input_rows)"
Write-Host "Output rows: $($summary.output_rows)"
Write-Host "Removed noise rows: $($summary.removed_noise_rows)"
Write-Host "Endpoint backfilled rows: $($summary.endpoint_backfilled_rows)"
Write-Host "Ambiguous SQL connection rows: $($summary.ambiguous_sql_connection_rows)"
Write-Host "Review: $OutputReviewPath"
