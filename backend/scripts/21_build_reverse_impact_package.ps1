# Phase 21 - Reverse impact package: packages Phase 17's impact index plus
# the SQL/column catalogs into the final JSON the web UI's Impact search
# consumes directly (per-object writer/reader breakdown, confidence,
# execution/identity, Excel-export-ready rows). Delegates to the faster
# backend/scripts/21_build_reverse_impact_package_fast.py when python is available,
# falling back to this PowerShell version otherwise -- keep both in sync.
# Writes: $OutputJsonPath (frontend/semantic-lineage/data/object-impact.json), doc.
param(
    [string]$ImpactIndexPath = (Join-Path $PSScriptRoot "../../analysis/object_impact_index.csv"),
    [string]$ImpactSummaryPath = (Join-Path $PSScriptRoot "../../analysis/object_impact_summary.csv"),
    [string]$CatalogPath = (Join-Path $PSScriptRoot "../../analysis/sql_endpoint_object_catalog.csv"),
    [string]$ObjectColumnCatalogPath = (Join-Path $PSScriptRoot "../../analysis/object_column_catalog.csv"),
    [string]$ExplorerDataPath = (Join-Path $PSScriptRoot "../../frontend/semantic-lineage/data/lineage-explorer.json"),
    [string]$OutputJsonPath = (Join-Path $PSScriptRoot "../../frontend/semantic-lineage/data/object-impact.json"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/18_reverse_impact_search.md")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$fastScriptPath = (Join-Path $PSScriptRoot "21_build_reverse_impact_package_fast.py")
$pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $pythonCommand) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
}
if ((Test-Path $fastScriptPath) -and $pythonCommand) {
    & $pythonCommand.Source $fastScriptPath `
        --impact-index-path $ImpactIndexPath `
        --impact-summary-path $ImpactSummaryPath `
        --catalog-path $CatalogPath `
        --object-column-catalog-path $ObjectColumnCatalogPath `
        --explorer-data-path $ExplorerDataPath `
        --output-json-path $OutputJsonPath `
        --output-doc-path $OutputDocPath
    exit $LASTEXITCODE
}

function Write-JsonAtomic {
    param([string]$Path, [string]$JsonText)
    # Colleagues load this file directly over the shared tunnel while a scan
    # may be regenerating it. Write to a temp file in the same directory
    # first, then File.Move with overwrite (atomic via MoveFileEx) so a
    # crash mid-write never leaves a truncated file being served.
    Ensure-ParentDirectory -Path $Path
    $tmpPath = "$Path.tmp-$PID"
    try {
        $JsonText | Set-Content -Path $tmpPath -Encoding UTF8
        [System.IO.File]::Move($tmpPath, $Path, $true)
    }
    catch {
        if (Test-Path $tmpPath) { Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue }
        throw
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
    return (($Value.Trim()).ToLowerInvariant() -replace "\s+", " ")
}

function Convert-ToInt {
    param([string]$Value)
    $parsed = 0
    if ([int]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return 0
}

function New-ObjectAliasKey {
    param(
        [string]$SourceDatabase,
        [string]$SchemaName,
        [string]$ObjectName
    )

    return @(
        Normalize-Key $SourceDatabase
        Normalize-Key $SchemaName
        Normalize-Key $ObjectName
    ) -join "|"
}

function Add-UniqueObject {
    param(
        [System.Collections.Generic.List[object]]$List,
        [hashtable]$Seen,
        [string]$Key,
        [object]$Value
    )

    if (-not $Key -or $Seen.ContainsKey($Key)) { return }
    $Seen[$Key] = $true
    $List.Add($Value) | Out-Null
}

foreach ($path in @($ImpactIndexPath, $ImpactSummaryPath, $ExplorerDataPath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$rawImpactRows = @(Import-Csv -Path $ImpactIndexPath | Where-Object { $_.object_key -and $_.item_qualified_name })
$summaryRows = @(Import-Csv -Path $ImpactSummaryPath | Where-Object { $_.object_key })
$catalogRows = @()
if (Test-Path $CatalogPath) {
    $catalogRows = @(Import-Csv -Path $CatalogPath | Where-Object { $_.object_key -and $_.source_database -and $_.schema_name -and $_.object_name })
}
$objectColumnCatalogRows = if (Test-Path $ObjectColumnCatalogPath) { @(Import-Csv -Path $ObjectColumnCatalogPath | Where-Object { $_.object_name -and $_.column_name }) } else { @() }
$columnCatalogByFullKey = @{}
$columnCatalogSchemasByNameKey = @{}
foreach ($columnRow in $objectColumnCatalogRows) {
    $fullKey = "$(Normalize-Key $columnRow.source_server)|$(Normalize-Key $columnRow.source_database)|$(Normalize-Key $columnRow.schema_name)|$(Normalize-Key $columnRow.object_name)"
    if (-not $columnCatalogByFullKey.ContainsKey($fullKey)) {
        $columnCatalogByFullKey[$fullKey] = [System.Collections.Generic.List[object]]::new()
    }
    $columnCatalogByFullKey[$fullKey].Add($columnRow) | Out-Null

    $nameKey = "$(Normalize-Key $columnRow.source_server)|$(Normalize-Key $columnRow.source_database)|$(Normalize-Key $columnRow.object_name)"
    if (-not $columnCatalogSchemasByNameKey.ContainsKey($nameKey)) {
        $columnCatalogSchemasByNameKey[$nameKey] = @{}
    }
    $columnCatalogSchemasByNameKey[$nameKey][(Normalize-Key $columnRow.schema_name)] = $true
}

function Get-ColumnsForImpactObject {
    param([object]$ObjectRow)
    $server = Get-FieldValue -Object $ObjectRow -Names @("source_server")
    $database = Get-FieldValue -Object $ObjectRow -Names @("source_database")
    $schema = Get-FieldValue -Object $ObjectRow -Names @("schema_name")
    $objectName = Get-FieldValue -Object $ObjectRow -Names @("object_name")
    if (-not $server -or -not $database -or -not $objectName) { return @() }

    $fullKey = "$(Normalize-Key $server)|$(Normalize-Key $database)|$(Normalize-Key $schema)|$(Normalize-Key $objectName)"
    if (-not $columnCatalogByFullKey.ContainsKey($fullKey) -and -not $schema) {
        $nameKey = "$(Normalize-Key $server)|$(Normalize-Key $database)|$(Normalize-Key $objectName)"
        if ($columnCatalogSchemasByNameKey.ContainsKey($nameKey) -and $columnCatalogSchemasByNameKey[$nameKey].Keys.Count -eq 1) {
            $onlySchema = @($columnCatalogSchemasByNameKey[$nameKey].Keys)[0]
            $fullKey = "$(Normalize-Key $server)|$(Normalize-Key $database)|$onlySchema|$(Normalize-Key $objectName)"
        }
    }
    if (-not $columnCatalogByFullKey.ContainsKey($fullKey)) { return @() }

    return @(
        $columnCatalogByFullKey[$fullKey].ToArray() |
            Sort-Object { [int](Get-FieldValue -Object $_ -Names @("column_id")) } |
            ForEach-Object {
                [pscustomobject]@{
                    column_name = $_.column_name
                    data_type = $_.data_type
                    max_length = $_.max_length
                    precision = $_.precision
                    scale = $_.scale
                    is_nullable = $_.is_nullable
                }
            }
    )
}

$explorer = Get-Content -Path $ExplorerDataPath -Raw | ConvertFrom-Json

$reportsBySemanticModel = @{}
$itemsByQualifiedName = @{}
foreach ($workspace in @($explorer.workspaces)) {
    foreach ($mode in @("semantic", "notebooks", "copyjobs", "pipelines", "all")) {
        foreach ($item in @($workspace.$mode)) {
            $qualifiedName = Get-FieldValue -Object $item -Names @("qualified_name")
            if ($qualifiedName -and -not $itemsByQualifiedName.ContainsKey($qualifiedName)) {
                $itemsByQualifiedName[$qualifiedName] = $item
            }
        }
    }

    foreach ($model in @($workspace.semantic)) {
        $modelName = Get-FieldValue -Object $model -Names @("qualified_name")
        if (-not $modelName) { continue }
        $reports = [System.Collections.Generic.List[object]]::new()
        $seenReports = @{}
        foreach ($report in @($model.reports)) {
            $reportName = Get-FieldValue -Object $report -Names @("qualified_name")
            Add-UniqueObject -List $reports -Seen $seenReports -Key $reportName -Value ([pscustomobject]@{
                label = Get-FieldValue -Object $report -Names @("label", "item_name")
                item_type = Get-FieldValue -Object $report -Names @("item_type")
                workspace_name = Get-FieldValue -Object $report -Names @("workspace_name")
                qualified_name = $reportName
                confidence = Get-FieldValue -Object $report -Names @("confidence")
                evidence = Get-FieldValue -Object $report -Names @("evidence")
                impact_path = "source_object -> semantic_model -> report"
            })
        }
        $reportsBySemanticModel[$modelName] = $reports.ToArray()
    }
}

$summaryByObjectKey = @{}
foreach ($row in $summaryRows) {
    $summaryByObjectKey[$row.object_key] = $row
}

$catalogByObjectKey = @{}
$catalogByAlias = @{}
foreach ($row in $catalogRows) {
    if (-not $catalogByObjectKey.ContainsKey($row.object_key)) {
        $catalogByObjectKey[$row.object_key] = $row
    }

    $alias = New-ObjectAliasKey -SourceDatabase $row.source_database -SchemaName $row.schema_name -ObjectName $row.object_name
    if (-not $catalogByAlias.ContainsKey($alias)) {
        $catalogByAlias[$alias] = [System.Collections.Generic.List[object]]::new()
    }
    $catalogByAlias[$alias].Add($row) | Out-Null
}

$impactRows = [System.Collections.Generic.List[object]]::new()
foreach ($row in $rawImpactRows) {
    $catalogMatch = $null
    $alias = New-ObjectAliasKey `
        -SourceDatabase (Get-FieldValue -Object $row -Names @("source_database")) `
        -SchemaName (Get-FieldValue -Object $row -Names @("schema_name")) `
        -ObjectName (Get-FieldValue -Object $row -Names @("object_name"))
    if ($catalogByAlias.ContainsKey($alias)) {
        $matches = @($catalogByAlias[$alias].ToArray())
        if ($matches.Count -eq 1) {
            $catalogMatch = $matches[0]
        }
    }

    if ($catalogMatch) {
        $row.object_key = Get-FieldValue -Object $catalogMatch -Names @("object_key")
        $row.object_display_name = Get-FieldValue -Object $catalogMatch -Names @("object_display_name")
        $row.source_type = Get-FieldValue -Object $catalogMatch -Names @("source_type")
        $row.source_server = Get-FieldValue -Object $catalogMatch -Names @("source_server")
        $row.source_database = Get-FieldValue -Object $catalogMatch -Names @("source_database")
        $row.schema_name = Get-FieldValue -Object $catalogMatch -Names @("schema_name")
        $row.object_name = Get-FieldValue -Object $catalogMatch -Names @("object_name")
        $row.object_type = Get-FieldValue -Object $catalogMatch -Names @("object_type")
        $row.raw_object_type = Get-FieldValue -Object $catalogMatch -Names @("raw_object_type", "object_type")
        $row.object_type_source = Get-FieldValue -Object $catalogMatch -Names @("object_type_source")
        $row.object_type_confidence = Get-FieldValue -Object $catalogMatch -Names @("object_type_confidence")
        $row.evidence = ((Get-FieldValue -Object $row -Names @("evidence")) + " Catalog metadata: " + (Get-FieldValue -Object $catalogMatch -Names @("evidence"))).Trim()
    }
    $impactRows.Add($row) | Out-Null
}

$objects = [System.Collections.Generic.List[object]]::new()
$impactGroupsByKey = @{}
foreach ($group in (@($impactRows) | Group-Object object_key)) {
    $impactGroupsByKey[$group.Name] = @($group.Group)
}
$allObjectKeys = @(
    @($impactGroupsByKey.Keys) +
    @($catalogByObjectKey.Keys) |
        Where-Object { $_ } |
        Sort-Object -Unique
)

foreach ($objectKey in $allObjectKeys) {
    $groupRows = @()
    if ($impactGroupsByKey.ContainsKey($objectKey)) {
        $groupRows = @($impactGroupsByKey[$objectKey])
    }
    $catalog = if ($catalogByObjectKey.ContainsKey($objectKey)) { $catalogByObjectKey[$objectKey] } else { $null }
    $first = if ($groupRows.Count -gt 0) { $groupRows[0] } else { $catalog }
    if (-not $first) { continue }
    $summary = if ($summaryByObjectKey.ContainsKey($objectKey)) { $summaryByObjectKey[$objectKey] } else { $null }
    $directItems = [System.Collections.Generic.List[object]]::new()
    $seenDirect = @{}
    $downstreamReports = [System.Collections.Generic.List[object]]::new()
    $seenReports = @{}

    foreach ($row in $groupRows) {
        $itemQualifiedName = Get-FieldValue -Object $row -Names @("item_qualified_name")

        Add-UniqueObject -List $directItems -Seen $seenDirect -Key $itemQualifiedName -Value ([pscustomobject]@{
            label = Get-FieldValue -Object $row -Names @("item_name")
            item_type = Get-FieldValue -Object $row -Names @("item_type")
            workspace_name = Get-FieldValue -Object $row -Names @("item_workspace_name")
            qualified_name = $itemQualifiedName
            mode = Get-FieldValue -Object $row -Names @("mode")
            usage_type = Get-FieldValue -Object $row -Names @("usage_type")
            confidence = Get-FieldValue -Object $row -Names @("confidence")
            source_label = Get-FieldValue -Object $row -Names @("source_label")
            semantic_table = Get-FieldValue -Object $row -Names @("semantic_table")
            evidence = Get-FieldValue -Object $row -Names @("evidence")
            impact_path = "source_object -> item"
        })

        if ((Get-FieldValue -Object $row -Names @("item_type")) -eq "SemanticModel" -and $reportsBySemanticModel.ContainsKey($itemQualifiedName)) {
            foreach ($report in @($reportsBySemanticModel[$itemQualifiedName])) {
                Add-UniqueObject -List $downstreamReports -Seen $seenReports -Key $report.qualified_name -Value $report
            }
        }
    }

    $directArray = @($directItems.ToArray())
    $reportArray = @($downstreamReports.ToArray())
    $allWorkspaces = @(
        @($directArray | ForEach-Object { $_.workspace_name }) +
        @($reportArray | ForEach-Object { $_.workspace_name }) +
        @($(if ($catalog) { Get-FieldValue -Object $catalog -Names @("workspace_name") })) |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    $allItemTypes = @(
        @($directArray | ForEach-Object { $_.item_type }) +
        @($reportArray | ForEach-Object { $_.item_type }) |
            Where-Object { $_ } |
            Sort-Object -Unique
    )

    $objectTypeValues = if ($catalog) { Get-FieldValue -Object $catalog -Names @("object_type") } elseif ($summary) { Get-FieldValue -Object $summary -Names @("object_type_values") } else { Get-FieldValue -Object $first -Names @("object_type") }
    $objectTypeSources = if ($catalog) { Get-FieldValue -Object $catalog -Names @("object_type_source") } elseif ($summary) { Get-FieldValue -Object $summary -Names @("object_type_sources") } else { Get-FieldValue -Object $first -Names @("object_type_source") }
    $affectedItemCount = @($directArray | Select-Object -ExpandProperty qualified_name -Unique).Count
    $downstreamReportCount = @($reportArray | Select-Object -ExpandProperty qualified_name -Unique).Count
    $searchParts = @(
        Get-FieldValue -Object $first -Names @("object_display_name")
        Get-FieldValue -Object $first -Names @("source_type")
        Get-FieldValue -Object $first -Names @("source_server")
        Get-FieldValue -Object $first -Names @("source_database")
        Get-FieldValue -Object $first -Names @("schema_name")
        Get-FieldValue -Object $first -Names @("object_name")
        $objectTypeValues
        Get-FieldValue -Object $catalog -Names @("sql_endpoint_name")
        @($allWorkspaces)
        @($directArray | ForEach-Object { $_.label })
        @($reportArray | ForEach-Object { $_.label })
    ) | ForEach-Object {
        if ($_ -is [array]) { $_ } else { [string]$_ }
    }
    $searchText = ($searchParts | Where-Object { $_ }) -join " "

    $objects.Add([pscustomobject]@{
        object_key = $objectKey
        object_display_name = Get-FieldValue -Object $first -Names @("object_display_name")
        source_type = Get-FieldValue -Object $first -Names @("source_type")
        source_server = Get-FieldValue -Object $first -Names @("source_server")
        source_database = Get-FieldValue -Object $first -Names @("source_database")
        schema_name = Get-FieldValue -Object $first -Names @("schema_name")
        object_name = Get-FieldValue -Object $first -Names @("object_name")
        columns = @(Get-ColumnsForImpactObject -ObjectRow $first)
        object_type_values = $objectTypeValues
        object_type_sources = $objectTypeSources
        affected_item_count = $affectedItemCount
        downstream_report_count = $downstreamReportCount
        total_impact_count = $affectedItemCount + $downstreamReportCount
        semantic_model_count = @($directArray | Where-Object { $_.item_type -eq "SemanticModel" } | Select-Object -ExpandProperty qualified_name -Unique).Count
        notebook_count = @($directArray | Where-Object { $_.item_type -eq "Notebook" } | Select-Object -ExpandProperty qualified_name -Unique).Count
        copyjob_count = @($directArray | Where-Object { $_.item_type -eq "CopyJob" } | Select-Object -ExpandProperty qualified_name -Unique).Count
        pipeline_count = @($directArray | Where-Object { $_.item_type -eq "DataPipeline" } | Select-Object -ExpandProperty qualified_name -Unique).Count
        report_count = $downstreamReportCount
        workspace_count = $allWorkspaces.Count
        workspaces = $allWorkspaces
        affected_item_types = $allItemTypes
        search_text = $searchText.ToLowerInvariant()
        catalog_status = if ($catalog) { Get-FieldValue -Object $catalog -Names @("catalog_status") } else { "" }
        catalog_only = [bool]($catalog -and $affectedItemCount -eq 0 -and $downstreamReportCount -eq 0)
        catalog_workspace_name = if ($catalog) { Get-FieldValue -Object $catalog -Names @("workspace_name") } else { "" }
        sql_endpoint_name = if ($catalog) { Get-FieldValue -Object $catalog -Names @("sql_endpoint_name") } else { "" }
        sql_endpoint_qualified_name = if ($catalog) { Get-FieldValue -Object $catalog -Names @("sql_endpoint_qualified_name") } else { "" }
        endpoint_resolution_method = if ($catalog) { Get-FieldValue -Object $catalog -Names @("endpoint_resolution_method") } else { "" }
        catalog_evidence = if ($catalog) { Get-FieldValue -Object $catalog -Names @("evidence") } else { "" }
        direct_items = @($directArray | Sort-Object item_type, workspace_name, label)
        downstream_reports = @($reportArray | Sort-Object workspace_name, label)
    }) | Out-Null
}

$objects = @(
    $objects |
        Sort-Object `
            @{ Expression = "total_impact_count"; Descending = $true },
            @{ Expression = "affected_item_count"; Descending = $true },
            object_display_name
)

$payload = [pscustomobject]@{
    generated_at = (Get-Date).ToString("s")
    summary = [pscustomobject]@{
        source_objects = $objects.Count
        direct_impact_rows = @($impactRows).Count
        impacted_direct_items = @($impactRows | Select-Object -ExpandProperty item_qualified_name -Unique).Count
        downstream_reports = @($objects | ForEach-Object { $_.downstream_reports } | Select-Object -ExpandProperty qualified_name -Unique).Count
        max_total_impact = if ($objects.Count) { ($objects | Select-Object -First 1).total_impact_count } else { 0 }
        exact_object_type_objects = @($objects | Where-Object { $_.object_type_values -match "(^|; )(table|view|stored_procedure|file|shortcut|query)(;|$)" }).Count
        unresolved_objects = @($objects | Where-Object { $_.object_type_values -match "table_or_view|native_query_object" }).Count
        catalog_objects = @($objects | Where-Object { $_.catalog_status }).Count
        catalog_only_objects = @($objects | Where-Object { $_.catalog_only }).Count
    }
    objects = $objects
}

Write-JsonAtomic -Path $OutputJsonPath -JsonText ($payload | ConvertTo-Json -Depth 20)

$docLines = [System.Collections.Generic.List[string]]::new()
$docLines.Add("# Reverse Impact Search") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Generated at: $($payload.generated_at)") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Purpose") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Provide the visual search baseline for impact questions such as: if a source table, view, stored procedure, file, or query changes, which semantic models, notebooks, CopyJobs, DataPipelines, and downstream reports can be affected.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Current Summary") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- Source objects searchable: $($payload.summary.source_objects).") | Out-Null
$docLines.Add("- Direct impact rows: $($payload.summary.direct_impact_rows).") | Out-Null
$docLines.Add("- Direct impacted items: $($payload.summary.impacted_direct_items).") | Out-Null
$docLines.Add("- Downstream reports attached from semantic models: $($payload.summary.downstream_reports).") | Out-Null
$docLines.Add("- Exact object-type objects: $($payload.summary.exact_object_type_objects).") | Out-Null
$docLines.Add("- Objects still carrying ambiguous type values: $($payload.summary.unresolved_objects).") | Out-Null
$docLines.Add("- SQL endpoint catalog objects included: $($payload.summary.catalog_objects).") | Out-Null
$docLines.Add("- Catalog-only objects without detected direct impact yet: $($payload.summary.catalog_only_objects).") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Outputs") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add('- `frontend/semantic-lineage/data/object-impact.json`') | Out-Null
$docLines.Add('- `analysis/object_impact_index.csv`') | Out-Null
$docLines.Add('- `analysis/object_impact_summary.csv`') | Out-Null
$docLines.Add('- `analysis/sql_endpoint_object_catalog.csv`') | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Safety") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("This package is local-only. It reads generated lineage artifacts and does not query or modify Fabric.") | Out-Null
Ensure-ParentDirectory -Path $OutputDocPath
$docLines | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host "Reverse impact package built."
Write-Host "Source objects: $($payload.summary.source_objects)"
Write-Host "Direct impact rows: $($payload.summary.direct_impact_rows)"
Write-Host "Downstream reports: $($payload.summary.downstream_reports)"
Write-Host "Output: $OutputJsonPath"
