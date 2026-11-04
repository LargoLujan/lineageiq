# Phase 11 - Lineage explorer JSON build: the single biggest consumer of
# every prior phase's output. Merges workspaces/items/dependencies/
# executions/analysis/view-candidates/object-lineage-candidates/deployment
# pipelines into one JSON tree per item type ("mode") for the web
# explorer's UI. Delegates to the much faster
# backend/scripts/11_build_lineage_explorer_fast.py (a Python reimplementation)
# when python is available, falling back to this PowerShell version
# otherwise -- keep both in sync if the shape changes.
# Writes: $OutputJsonPath (frontend/semantic-lineage/data/lineage-explorer.json),
# $GapPath, $ManifestPath.
param(
    [string]$WorkspacesPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$DependenciesPath = (Join-Path $PSScriptRoot "../../index/dependencies.csv"),
    [string]$ExecutionsPath = (Join-Path $PSScriptRoot "../../index/executions.csv"),
    [string]$ItemAnalysisPath = (Join-Path $PSScriptRoot "../../index/item_analysis.csv"),
    [string]$ViewCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_view_candidates.csv"),
    [string]$ManualObjectEvidencePath = (Join-Path $PSScriptRoot "../../index/manual_lineage_object_evidence.csv"),
    [string]$ItemObjectLineageCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/item_object_lineage_candidates.csv"),
    [string]$PipelineObjectLineageCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/pipeline_object_lineage_candidates.csv"),
    [string]$PipelineActivityLineagePath = (Join-Path $PSScriptRoot "../../analysis/pipeline_activity_lineage.csv"),
    [string]$NotebookSuperLineageObjectsPath = (Join-Path $PSScriptRoot "../../analysis/notebook_super_lineage_objects.csv"),
    [string]$NotebookSuperLineageFlowsPath = (Join-Path $PSScriptRoot "../../analysis/notebook_super_lineage_flows.csv"),
    [string]$ObjectTypeOverridesPath = (Join-Path $PSScriptRoot "../../index/source_object_type_overrides.csv"),
    [string]$ObjectTypeMetadataEvidencePath = (Join-Path $PSScriptRoot "../../analysis/source_object_type_metadata_evidence.csv"),
    [string]$SqlEndpointCatalogPath = (Join-Path $PSScriptRoot "../../analysis/sql_endpoint_object_catalog.csv"),
    [string]$ObjectColumnCatalogPath = (Join-Path $PSScriptRoot "../../analysis/object_column_catalog.csv"),
    [string]$SharePointObjectTypeEvidencePath = "",
    [string]$DeploymentPipelinesPath = (Join-Path $PSScriptRoot "../../index/deployment_pipelines.csv"),
    [string]$DeploymentPipelineStagesPath = (Join-Path $PSScriptRoot "../../index/deployment_pipeline_stages.csv"),
    [string]$DeploymentPipelineGroupsPath = (Join-Path $PSScriptRoot "../../analysis/deployment_pipeline_workspace_groups.csv"),
    [string]$MigrationMapPath = (Join-Path $PSScriptRoot "../../config/source_migration_map.csv"),
    [string]$OutputJsonPath = (Join-Path $PSScriptRoot "../../frontend/semantic-lineage/data/lineage-explorer.json"),
    [string]$GapPath = (Join-Path $PSScriptRoot "../../analysis/lineage_explorer_gaps.csv"),
    [string]$ManifestPath = (Join-Path $PSScriptRoot "../../analysis/lineage_refresh_manifest.json"),
    [string]$RunLogDirectory = "runs",
    [string]$VisualValidationResultPath = (Join-Path $PSScriptRoot "../../analysis/visual-validation/playwright-results.json"),
    [string]$CriticalPathPath = (Join-Path $PSScriptRoot "../../analysis/critical_path_candidates.csv"),
    [string]$FailureHotspotsPath = (Join-Path $PSScriptRoot "../../analysis/failure_hotspots.csv"),
    [string]$ScheduleReviewPath = (Join-Path $PSScriptRoot "../../analysis/schedule_review_candidates.csv"),
    [string]$ParallelismCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/parallelism_candidates.csv"),
    [string]$OrchestrationGroupCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/orchestration_group_candidates.csv"),
    [string]$GitConnectionsPath = (Join-Path $PSScriptRoot "../../index/workspace_git_connections.csv"),
    [string]$ScanHistoryPath = (Join-Path $PSScriptRoot "../../analysis/single_workspace_scan/history.csv"),
    [string]$RoleAssignmentsPath = (Join-Path $PSScriptRoot "../../index/workspace_role_assignments.csv")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$fastScriptPath = (Join-Path $PSScriptRoot "11_build_lineage_explorer_fast.py")
$pythonCommand = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $pythonCommand) {
    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
}
if ((Test-Path $fastScriptPath) -and $pythonCommand) {
    & $pythonCommand.Source $fastScriptPath `
        --workspaces-path $WorkspacesPath `
        --items-path $ItemsPath `
        --dependencies-path $DependenciesPath `
        --executions-path $ExecutionsPath `
        --item-analysis-path $ItemAnalysisPath `
        --view-candidates-path $ViewCandidatesPath `
        --manual-object-evidence-path $ManualObjectEvidencePath `
        --item-object-lineage-candidates-path $ItemObjectLineageCandidatesPath `
        --pipeline-object-lineage-candidates-path $PipelineObjectLineageCandidatesPath `
        --pipeline-activity-lineage-path $PipelineActivityLineagePath `
        --notebook-super-lineage-objects-path $NotebookSuperLineageObjectsPath `
        --notebook-super-lineage-flows-path $NotebookSuperLineageFlowsPath `
        --object-type-overrides-path $ObjectTypeOverridesPath `
        --object-type-metadata-evidence-path $ObjectTypeMetadataEvidencePath `
        --sql-endpoint-catalog-path $SqlEndpointCatalogPath `
        --object-column-catalog-path $ObjectColumnCatalogPath `
        --sharepoint-object-type-evidence-path $SharePointObjectTypeEvidencePath `
        --deployment-pipelines-path $DeploymentPipelinesPath `
        --deployment-pipeline-stages-path $DeploymentPipelineStagesPath `
        --deployment-pipeline-groups-path $DeploymentPipelineGroupsPath `
        --migration-map-path $MigrationMapPath `
        --output-json-path $OutputJsonPath `
        --gap-path $GapPath `
        --manifest-path $ManifestPath `
        --run-log-directory $RunLogDirectory `
        --visual-validation-result-path $VisualValidationResultPath `
        --critical-path-path $CriticalPathPath `
        --failure-hotspots-path $FailureHotspotsPath `
        --schedule-review-path $ScheduleReviewPath `
        --parallelism-candidates-path $ParallelismCandidatesPath `
        --orchestration-group-candidates-path $OrchestrationGroupCandidatesPath `
        --git-connections-path $GitConnectionsPath `
        --scan-history-path $ScanHistoryPath `
        --role-assignments-path $RoleAssignmentsPath
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

function Get-RelativePathText {
    param([string]$Path)
    if (-not $Path) { return "" }
    $normalized = $Path -replace "\\", "/"
    $cwd = (Get-Location).Path -replace "\\", "/"
    if ($normalized.StartsWith("$cwd/")) {
        return $normalized.Substring($cwd.Length + 1)
    }
    return $normalized
}

function Get-FileFreshness {
    param([string[]]$Paths)
    $now = Get-Date
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $Paths) {
        if (Test-Path $path) {
            $item = Get-Item $path
            $lineCount = 0
            if (-not $item.PSIsContainer) {
                try { $lineCount = @(Get-Content -Path $path -ErrorAction Stop).Count } catch { $lineCount = 0 }
            }
            $rows.Add([pscustomobject]@{
                path = Get-RelativePathText -Path $path
                exists = $true
                bytes = if ($item.PSIsContainer) { 0 } else { $item.Length }
                lines = $lineCount
                modified_at = $item.LastWriteTime.ToString("s")
                age_hours = [math]::Round(($now - $item.LastWriteTime).TotalHours, 2)
            }) | Out-Null
        }
        else {
            $rows.Add([pscustomobject]@{
                path = Get-RelativePathText -Path $path
                exists = $false
                bytes = 0
                lines = 0
                modified_at = ""
                age_hours = $null
            }) | Out-Null
        }
    }
    return @($rows.ToArray())
}

function Get-LatestRunLog {
    param([string]$Directory)
    if (-not (Test-Path $Directory)) { return $null }
    $latest = @(Get-ChildItem -Path $Directory -Filter "lineage_refresh_*.md" -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($latest.Count -eq 0) { return $null }
    return $latest[0]
}

function Get-RefreshMetadata {
    $manifest = $null
    if (Test-Path $ManifestPath) {
        try { $manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json } catch { $manifest = $null }
    }
    $visual = $null
    if (Test-Path $VisualValidationResultPath) {
        try {
            $visualJson = Get-Content -Path $VisualValidationResultPath -Raw | ConvertFrom-Json
            $visual = [pscustomobject]@{
                result_path = Get-RelativePathText -Path $VisualValidationResultPath
                start_time = $visualJson.stats.startTime
                duration_seconds = if ($visualJson.stats.duration) { [math]::Round(([double]$visualJson.stats.duration) / 1000, 2) } else { $null }
                expected = $visualJson.stats.expected
                skipped = $visualJson.stats.skipped
                unexpected = $visualJson.stats.unexpected
                flaky = $visualJson.stats.flaky
            }
        }
        catch { $visual = $null }
    }
    $latestLog = Get-LatestRunLog -Directory $RunLogDirectory
    $steps = if ($manifest -and $manifest.steps) { @($manifest.steps) } else { @() }
    $failedSteps = @($steps | Where-Object { $_.status -ne "completed" })
    $artifactPaths = @(
        "index/workspaces.csv",
        "index/items.csv",
        "index/dependencies.csv",
        "index/executions.csv",
        "graph/nodes.csv",
        "graph/edges.csv",
        "analysis/orchestration_recommendations.csv",
        "index/manual_lineage_object_evidence.csv",
        "analysis/manual_lineage_review_queue.csv",
        "analysis/item_object_lineage_candidates.csv",
        "analysis/item_object_lineage_gaps.csv",
        "analysis/notebook_definition_download_manifest.csv",
        "analysis/notebook_super_lineage_objects.csv",
        "analysis/notebook_super_lineage_flows.csv",
        "analysis/notebook_super_lineage_gaps.csv",
        "analysis/notebook_super_lineage_summary.csv",
        "docs/45_notebook_super_lineage.md",
        "analysis/pipeline_object_lineage_candidates.csv",
        "analysis/pipeline_activity_lineage.csv",
        "analysis/pipeline_object_lineage_gaps.csv",
        "index/source_object_type_overrides.csv",
        "analysis/source_object_type_metadata_evidence.csv",
        "analysis/source_object_type_metadata_gaps.csv",
        "analysis/sql_endpoint_object_catalog.csv",
        "analysis/source_object_type_resolution_queue.csv",
        "analysis/source_object_type_resolution_summary.csv",
        "index/deployment_pipelines.csv",
        "index/deployment_pipeline_stages.csv",
        "analysis/deployment_pipeline_workspace_groups.csv",
        "frontend/semantic-lineage/data/lineage-explorer.json",
        "frontend/semantic-lineage/standalone.html",
        "analysis/visual-validation/playwright-results.json",
        "config/source_migration_map.csv"
    )
    return [pscustomobject]@{
        status_generated_at = (Get-Date).ToString("s")
        manifest_path = Get-RelativePathText -Path $ManifestPath
        manifest_found = [bool]$manifest
        latest_run_log = if ($latestLog) { Get-RelativePathText -Path $latestLog.FullName } else { "" }
        latest_run_mode = if ($manifest) { $manifest.mode } else { "" }
        latest_run_auth_method = if ($manifest) { $manifest.auth_method } else { "" }
        latest_run_started_at = if ($manifest) { $manifest.started_at } else { "" }
        latest_run_ended_at = if ($manifest) { $manifest.ended_at } else { "" }
        latest_run_duration_seconds = if ($manifest) { $manifest.duration_seconds } else { $null }
        latest_run_visual_validation = if ($manifest) { [bool]$manifest.run_visual_validation } else { $false }
        latest_run_status = if (-not $manifest) { "unknown" } elseif ($failedSteps.Count -gt 0) { "failed" } else { "completed" }
        step_count = $steps.Count
        failed_step_count = $failedSteps.Count
        visual_validation = $visual
        artifacts = @(Get-FileFreshness -Paths ($artifactPaths | ForEach-Object { Join-Path $PSScriptRoot "../../$_" }))
        commands = @(
            [pscustomobject]@{
                id = "local-artifacts"
                command = "pwsh -NoLogo -File backend/scripts/99_refresh_lineage_project.ps1 -Mode local-artifacts"
                external_systems = "None"
            },
            [pscustomobject]@{
                id = "local-artifacts-visual"
                command = "pwsh -NoLogo -File backend/scripts/99_refresh_lineage_project.ps1 -Mode local-artifacts -RunVisualValidation"
                external_systems = "None"
            },
            [pscustomobject]@{
                id = "read-only-inventory"
                command = "pwsh -NoLogo -File backend/scripts/99_refresh_lineage_project.ps1 -Mode read-only-inventory -AuthMethod azure-cli"
                external_systems = "Fabric REST read-only"
            },
            [pscustomobject]@{
                id = "full-read-only"
                command = "pwsh -NoLogo -File backend/scripts/99_refresh_lineage_project.ps1 -Mode full-read-only -AuthMethod azure-cli"
                external_systems = "Fabric REST and Power BI REST read-only"
            },
            [pscustomobject]@{
                id = "full-read-only-tmdl"
                command = "pwsh -NoLogo -File backend/scripts/99_refresh_lineage_project.ps1 -Mode full-read-only -AuthMethod azure-cli -RunTmdlEnrichment -MaxTmdlModels 120"
                external_systems = "Fabric REST and Power BI REST read-only"
            }
        )
        safety_note = "The static HTML does not execute commands or modify Fabric. Final approval and execution are human-controlled."
    }
}

function Normalize-Key {
    param([string]$Value)
    if (-not $Value) { return "" }
    return ($Value.ToLowerInvariant() -replace "\s+", " ").Trim()
}

$script:ExactObjectTypes = @("table", "view", "stored_procedure", "file", "shortcut", "query")
$script:ObjectTypeOverrideMap = @{}
$script:ManualObjectTypeMap = @{}
$script:MetadataObjectTypeMap = @{}
$script:SharePointObjectTypeMap = @{}

function Normalize-ObjectType {
    param([string]$Value)
    $clean = (Normalize-Key $Value) -replace "[\s-]+", "_"
    switch ($clean) {
        "storedprocedure" { return "stored_procedure" }
        "stored_procedure" { return "stored_procedure" }
        "procedure" { return "stored_procedure" }
        "proc" { return "stored_procedure" }
        "sp" { return "stored_procedure" }
        "tbl" { return "table" }
        default { return $clean }
    }
}

function Test-ExactObjectType {
    param([string]$Value)
    return ((Normalize-ObjectType $Value) -in $script:ExactObjectTypes)
}

# Illustrative example: adapt this list to the business systems that
# appear in the workspace/item names of your own tenant, to normalize
# them to their "pretty" form.
$script:FabricTokenWords = @{
    ADVENTUREWORKS = "AdventureWorks"
    BRONZE = "Bronze"
    CONTOSOHR = "ContosoHR"
    DATAMART = "Datamart"
    ECOMMERCE = "eCommerce"
    FABRIKAMCRM = "FabrikamCRM"
    FINANCE = "Finance"
    GESTION = "Gestion"
    GOLD = "Gold"
    NORTHWINDERP = "NorthwindERP"
    OPERATIONS = "Operations"
    SALES = "Sales"
    SILVER = "Silver"
    STAGING = "Staging"
    SURVEY = "Survey"
}
$script:FabricTokenAcronyms = @("API", "BI", "CRM", "ERP", "FT", "HR", "ID", "IT", "LH", "QA", "SQL")

function Convert-FabricTokenPart {
    param([string]$Value)
    $upper = ($Value ?? "").ToUpperInvariant()
    if (-not $upper) { return "" }
    if ($script:FabricTokenWords.ContainsKey($upper)) { return $script:FabricTokenWords[$upper] }
    if ($script:FabricTokenAcronyms -contains $upper) { return $upper }
    if ($Value -ceq $upper) {
        return (Get-Culture).TextInfo.ToTitleCase($Value.ToLowerInvariant())
    }
    return $Value
}

function Convert-FabricPathTokenToName {
    param([string]$Token)
    $clean = (($Token ?? "") -replace "[{}]", "")
    $clean = ($clean -replace "_+", "_").Trim("_")
    if (-not $clean) { return "Unresolved_Lakehouse" }
    foreach ($suffix in @("_TABLES_PATH", "_TABLE_PATH", "_FILES_PATH", "_FILE_PATH", "_ABFSS_PATH", "_ONELAKE_PATH", "_PATH")) {
        if ($clean.ToUpperInvariant().EndsWith($suffix)) {
            $clean = $clean.Substring(0, $clean.Length - $suffix.Length)
            break
        }
    }
    $parts = @($clean -split "_" | Where-Object { $_ })
    if ($parts.Count -gt 0 -and $parts[0].ToUpperInvariant() -eq "LH") {
        $body = @($parts | Select-Object -Skip 1 | ForEach-Object { Convert-FabricTokenPart -Value $_ }) -join "_"
        if ($body) { return "LH_$body" }
        return "LH_Unresolved"
    }
    $rendered = @($parts | ForEach-Object { Convert-FabricTokenPart -Value $_ }) -join "_"
    if ($rendered) { return $rendered }
    return "Unresolved_Lakehouse"
}

function Convert-FabricPlaceholderObject {
    param(
        [string]$SourceType,
        [string]$SourceDatabase,
        [string]$SchemaName,
        [string]$ObjectName,
        [string]$Label
    )
    $candidate = ""
    foreach ($value in @($ObjectName, $Label)) {
        if ($value -and $value -match '^\{[A-Za-z0-9_]+\}/') {
            $candidate = $value
            break
        }
    }
    if (-not $candidate -or $candidate -notmatch '^\{(?<token>[A-Za-z0-9_]+)\}/(?<path>.+)$') {
        return [pscustomobject]@{
            changed = $false
            source_type = $SourceType
            source_database = $SourceDatabase
            schema_name = $SchemaName
            object_name = $ObjectName
            label = $Label
            display = if ($Label) { $Label } elseif ($SchemaName -and $ObjectName) { "$SchemaName.$ObjectName" } else { $ObjectName }
        }
    }

    $lakehouseName = Convert-FabricPathTokenToName -Token $Matches.token
    $pathParts = @(
        $Matches.path.Trim("/") -split "/" |
            ForEach-Object { ($_ -replace '^[\s`"''\[\]]+', '') -replace '[\s`"''\[\]]+$', '' } |
            Where-Object { $_ }
    )
    if ($pathParts.Count -eq 0) {
        return [pscustomobject]@{
            changed = $false
            source_type = $SourceType
            source_database = $SourceDatabase
            schema_name = $SchemaName
            object_name = $ObjectName
            label = $Label
            display = if ($Label) { $Label } elseif ($SchemaName -and $ObjectName) { "$SchemaName.$ObjectName" } else { $ObjectName }
        }
    }

    if ($pathParts[0].ToLowerInvariant() -eq "files") {
        $fileObject = if ($pathParts.Count -gt 1) { @($pathParts | Select-Object -Skip 1) -join "/" } else { "Files" }
        $fileDisplay = if ($fileObject -eq "Files") { "$lakehouseName/Files" } else { "$lakehouseName/Files/$fileObject" }
        return [pscustomobject]@{
            changed = $true
            source_type = "File"
            source_database = $lakehouseName
            schema_name = ""
            object_name = $fileObject
            label = $fileDisplay
            display = $fileDisplay
        }
    }

    if ($pathParts[0].ToLowerInvariant() -eq "tables") {
        $pathParts = @($pathParts | Select-Object -Skip 1)
    }
    if ($pathParts.Count -ge 2) {
        $normalizedSchema = $pathParts[$pathParts.Count - 2]
        $normalizedObject = $pathParts[$pathParts.Count - 1]
    }
    else {
        $normalizedSchema = ""
        $normalizedObject = $pathParts[0]
    }
    $display = @($lakehouseName, $normalizedSchema, $normalizedObject) | Where-Object { $_ }
    $display = $display -join "."
    $label = if ($normalizedSchema) { "$normalizedSchema.$normalizedObject" } else { $normalizedObject }
    return [pscustomobject]@{
        changed = $true
        source_type = "LakehouseTable"
        source_database = $lakehouseName
        schema_name = $normalizedSchema
        object_name = $normalizedObject
        label = $label
        display = $display
    }
}

function New-ObjectTypeKey {
    param(
        [string]$SourceType,
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$SchemaName,
        [string]$ObjectName
    )

    $typePart = if ($SourceType) { Normalize-Key $SourceType } else { "*" }
    return "$typePart|$(Normalize-Key $SourceServer)|$(Normalize-Key $SourceDatabase)|$(Normalize-Key $SchemaName)|$(Normalize-Key $ObjectName)"
}

function Add-ObjectTypeResolver {
    param(
        [hashtable]$Map,
        [string]$Source,
        [object]$Row,
        [string]$ObjectType
    )

    $sourceType = Get-FieldValue -Object $Row -Names @("source_type", "source_system")
    $sourceServer = Get-FieldValue -Object $Row -Names @("source_server", "server")
    $sourceDatabase = Get-FieldValue -Object $Row -Names @("source_database", "database_name", "database")
    $schemaName = Get-FieldValue -Object $Row -Names @("schema_name", "source_schema")
    $objectName = Get-FieldValue -Object $Row -Names @("object_name", "source_object")
    $placeholder = Convert-FabricPlaceholderObject -SourceType $sourceType -SourceDatabase $sourceDatabase -SchemaName $schemaName -ObjectName $objectName -Label ""
    if ($placeholder.changed) {
        $sourceType = $placeholder.source_type
        $sourceDatabase = $placeholder.source_database
        $schemaName = $placeholder.schema_name
        $objectName = $placeholder.object_name
    }
    $normalizedType = Normalize-ObjectType $ObjectType

    if (-not ($sourceServer -or $sourceDatabase -or $objectName) -or -not (Test-ExactObjectType $normalizedType)) {
        return
    }

    foreach ($key in @(
        (New-ObjectTypeKey -SourceType $sourceType -SourceServer $sourceServer -SourceDatabase $sourceDatabase -SchemaName $schemaName -ObjectName $objectName),
        (New-ObjectTypeKey -SourceType "" -SourceServer $sourceServer -SourceDatabase $sourceDatabase -SchemaName $schemaName -ObjectName $objectName)
    ) | Select-Object -Unique) {
        if ($Map.ContainsKey($key) -and $Map[$key].object_type -ne $normalizedType) {
            $Map[$key] = [pscustomobject]@{
                object_type = "unknown"
                source = "${Source}_conflict"
                confidence = "unknown"
                evidence = "Conflicting object type evidence for this source object."
            }
            continue
        }

        $Map[$key] = [pscustomobject]@{
            object_type = $normalizedType
            source = $Source
            confidence = Get-FieldValue -Object $Row -Names @("confidence", "object_type_confidence")
            evidence = Get-FieldValue -Object $Row -Names @("evidence")
        }
    }
}

function Resolve-SourceObjectType {
    param(
        [string]$SourceType,
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$SchemaName,
        [string]$ObjectName,
        [string]$RawObjectType
    )

    $keys = @(
        (New-ObjectTypeKey -SourceType $SourceType -SourceServer $SourceServer -SourceDatabase $SourceDatabase -SchemaName $SchemaName -ObjectName $ObjectName),
        (New-ObjectTypeKey -SourceType "" -SourceServer $SourceServer -SourceDatabase $SourceDatabase -SchemaName $SchemaName -ObjectName $ObjectName)
    ) | Select-Object -Unique

    foreach ($key in $keys) {
        if ($script:ObjectTypeOverrideMap.ContainsKey($key) -and (Test-ExactObjectType $script:ObjectTypeOverrideMap[$key].object_type)) {
            return $script:ObjectTypeOverrideMap[$key]
        }
    }

    foreach ($key in $keys) {
        if ($script:ManualObjectTypeMap.ContainsKey($key) -and (Test-ExactObjectType $script:ManualObjectTypeMap[$key].object_type)) {
            return $script:ManualObjectTypeMap[$key]
        }
    }

    foreach ($key in $keys) {
        if ($script:MetadataObjectTypeMap.ContainsKey($key) -and (Test-ExactObjectType $script:MetadataObjectTypeMap[$key].object_type)) {
            return $script:MetadataObjectTypeMap[$key]
        }
    }

    foreach ($key in $keys) {
        if ($script:SharePointObjectTypeMap.ContainsKey($key) -and (Test-ExactObjectType $script:SharePointObjectTypeMap[$key].object_type)) {
            return $script:SharePointObjectTypeMap[$key]
        }
    }

    $normalizedRaw = Normalize-ObjectType $RawObjectType
    return [pscustomobject]@{
        object_type = $normalizedRaw
        source = if ($normalizedRaw -eq "table_or_view") { "tmdl_lookup_pending" } elseif ($normalizedRaw -eq "native_query_object") { "native_query_pending" } else { "automatic_candidate" }
        confidence = if ($normalizedRaw -eq "table_or_view") { "confirmed" } elseif ($normalizedRaw -eq "native_query_object") { "likely" } else { "" }
        evidence = if ($normalizedRaw -eq "table_or_view") {
            "TMDL Schema/Item confirms the object name but not whether the SQL object is a table or view."
        } elseif ($normalizedRaw -eq "native_query_object") {
            "Native query parsing found an object reference, but the exact SQL object type requires metadata review."
        } else {
            ""
        }
    }
}

function Get-ItemNameFromQualifiedName {
    param([string]$QualifiedName)
    if (-not $QualifiedName) { return "" }
    return (($QualifiedName -split " / ") | Select-Object -Last 1)
}

function Get-ItemTypeFromQualifiedName {
    param([string]$QualifiedName)
    $parts = $QualifiedName -split " / "
    if ($parts.Count -ge 3) { return $parts[1] }
    return ""
}

function Get-WorkspaceNameFromQualifiedName {
    param([string]$QualifiedName)
    if (-not $QualifiedName -or $QualifiedName.StartsWith("External Connection /")) { return "" }
    $parts = $QualifiedName -split " / "
    if ($parts.Count -ge 3) { return $parts[0] }
    return ""
}

function Get-ExternalConnectionParts {
    param([string]$QualifiedName)
    $parts = $QualifiedName -split " / ", 3
    $sourceType = if ($parts.Count -ge 2) { $parts[1] } else { "Unknown" }
    $connectionText = if ($parts.Count -ge 3) { $parts[2] } else { $QualifiedName }
    $server = ""
    $database = ""
    $objectName = ""

    if ($connectionText.Contains(";")) {
        $connectionParts = $connectionText -split ";"
        $server = $connectionParts[0]
        if ($connectionParts.Count -ge 2) { $database = $connectionParts[1] }
        if ($connectionParts.Count -ge 3) { $objectName = ($connectionParts[2..($connectionParts.Count - 1)] -join ";") }
    }
    elseif ($sourceType -eq "SharePoint") {
        $server = $connectionText
        $database = "SharePoint"
    }
    else {
        $database = $connectionText
    }

    return [pscustomobject]@{
        source_type = $sourceType
        source_server = $server
        source_database = $database
        source_object = $objectName
        label = if ($database) { $database } else { $connectionText }
    }
}

# No real Fabric notebook/pipeline/CopyJob run takes 24+ hours -- a value
# that large is corrupted instrumentation (e.g. a stored duration of several
# weeks against start/end timestamps showing the run actually took
# minutes), not a real long-running job. Drop it before it reaches an
# average -- a single such row can drag a whole tenant's Planning
# "critical path" to hundreds of hours.
$script:MaxRealisticDurationSeconds = 24 * 60 * 60

function Get-MedianSeconds {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $count = $sorted.Count
    $mid = [math]::Floor($count / 2)
    if ($count % 2 -eq 0) {
        return [math]::Round((([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2), 2)
    }
    return [math]::Round([double]$sorted[$mid], 2)
}

function New-ExecutionSummary {
    param([object[]]$Rows)
    $scheduleRows = @($Rows | Where-Object { $_.record_type -eq "schedule" })
    $jobRows = @($Rows | Where-Object { $_.record_type -eq "job_instance" })
    $completedDurations = @(
        $jobRows |
            Where-Object { $_.duration_seconds -match "^\d+(\.\d+)?$" -and $_.status -eq "Completed" } |
            ForEach-Object { [double]$_.duration_seconds } |
            Where-Object { $_ -gt 0 -and $_ -lt $script:MaxRealisticDurationSeconds }
    )
    $avgDuration = if ($completedDurations.Count -gt 0) { [math]::Round(($completedDurations | Measure-Object -Average).Average, 2) } else { $null }
    $medianDuration = Get-MedianSeconds -Values $completedDurations
    $latest = @($jobRows | Where-Object { $_.start_time } | Sort-Object start_time -Descending | Select-Object -First 1)

    return [pscustomobject]@{
        schedules = $scheduleRows.Count
        enabled_schedules = @($scheduleRows | Where-Object { $_.schedule_enabled -eq "True" }).Count
        disabled_schedules = @($scheduleRows | Where-Object { $_.schedule_enabled -eq "False" }).Count
        scheduled_times = (@($scheduleRows | Select-Object -ExpandProperty scheduled_time -Unique | Where-Object { $_ }) -join "; ")
        schedule_frequency = (@($scheduleRows | Select-Object -ExpandProperty schedule_frequency -Unique | Where-Object { $_ }) -join "; ")
        runs = $jobRows.Count
        completed_runs = @($jobRows | Where-Object { $_.status -eq "Completed" }).Count
        failed_runs = @($jobRows | Where-Object { $_.status -eq "Failed" }).Count
        avg_duration_seconds = $avgDuration
        median_duration_seconds = $medianDuration
        latest_start = if ($latest.Count -gt 0) { $latest[0].start_time } else { "" }
        latest_status = if ($latest.Count -gt 0) { $latest[0].status } else { "" }
    }
}

function Get-MigrationInfo {
    param([string]$SourceType, [string]$Server, [string]$Database, [object[]]$MigrationRows)
    $matches = @(
        $MigrationRows |
            Where-Object {
                $candidateServer = Get-FieldValue -Object $_ -Names @("source_server")
                $candidateDatabase = Get-FieldValue -Object $_ -Names @("source_database")
                $candidateSystem = Get-FieldValue -Object $_ -Names @("source_system")
                (Normalize-Key $candidateServer) -eq (Normalize-Key $Server) -and
                (Normalize-Key $candidateDatabase) -eq (Normalize-Key $Database) -and
                ((-not $candidateSystem) -or (Normalize-Key $candidateSystem) -eq (Normalize-Key $SourceType))
            }
    )
    $equivalents = @(
        $matches |
            ForEach-Object {
                (@($_.fabric_workspace, $_.fabric_item_type, $_.fabric_item_name, $_.fabric_object_name) | Where-Object { $_ }) -join " / "
            } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    return [pscustomobject]@{
        count = $matches.Count
        status = (@($matches | Select-Object -ExpandProperty mapping_status -Unique | Where-Object { $_ }) -join "; ")
        confidence = (@($matches | Select-Object -ExpandProperty confidence -Unique | Where-Object { $_ }) -join "; ")
        fabric_equivalent = ($equivalents -join "; ")
    }
}

function New-SourceNode {
    param(
        [object]$Dependency,
        [hashtable]$ItemByQualifiedName,
        [object[]]$ObjectRows,
        [object[]]$MigrationRows
    )
    $target = $Dependency.to_qualified_name
    $sourceType = ""
    $server = ""
    $database = ""
    $label = ""
    $itemType = ""
    $workspaceName = ""

    if ($target.StartsWith("External Connection /")) {
        $parts = Get-ExternalConnectionParts -QualifiedName $target
        $sourceType = $parts.source_type
        $server = $parts.source_server
        $database = $parts.source_database
        $label = $parts.label
        $itemType = "External"
    }
    elseif ($ItemByQualifiedName.ContainsKey($target)) {
        $targetItem = $ItemByQualifiedName[$target]
        $itemType = $targetItem.item_type
        $label = $targetItem.item_name
        $sourceType = if ($itemType -in @("Lakehouse", "Warehouse", "SQLEndpoint")) { "Fabric" } else { $itemType }
        $server = $targetItem.workspace_name
        $database = $targetItem.item_name
        $workspaceName = $targetItem.workspace_name
    }
    else {
        $label = Get-ItemNameFromQualifiedName -QualifiedName $target
        $itemType = Get-ItemTypeFromQualifiedName -QualifiedName $target
        $sourceType = if ($itemType) { $itemType } else { "Unknown" }
        $database = $label
        $workspaceName = Get-WorkspaceNameFromQualifiedName -QualifiedName $target
    }

    $migration = Get-MigrationInfo -SourceType $sourceType -Server $server -Database $database -MigrationRows $MigrationRows
    return [pscustomobject]@{
        id = "source:$((Normalize-Key "$sourceType|$server|$database|$label").GetHashCode())"
        label = $label
        type = "source"
        source_type = $sourceType
        item_type = $itemType
        workspace_name = $workspaceName
        qualified_name = $target
        server = $server
        database = $database
        confidence = $Dependency.confidence
        evidence = $Dependency.evidence
        migration = $migration
        objects = $ObjectRows
    }
}

foreach ($path in @($WorkspacesPath, $ItemsPath, $DependenciesPath, $ExecutionsPath)) {
    if (-not (Test-Path $path)) { throw "Required input not found: $path" }
}

$workspaces = @(Import-Csv -Path $WorkspacesPath)
$items = @(Import-Csv -Path $ItemsPath | Where-Object { $_.status -eq "discovered" })
$dependencies = @(Import-Csv -Path $DependenciesPath)
$executions = @(Import-Csv -Path $ExecutionsPath)
$analysisRows = if (Test-Path $ItemAnalysisPath) { @(Import-Csv -Path $ItemAnalysisPath) } else { @() }
$viewCandidates = if (Test-Path $ViewCandidatesPath) { @(Import-Csv -Path $ViewCandidatesPath | Where-Object { $_.object_name }) } else { @() }
$manualObjectEvidenceRows = if (Test-Path $ManualObjectEvidencePath) { @(Import-Csv -Path $ManualObjectEvidencePath | Where-Object { $_.item_qualified_name -and $_.object_name }) } else { @() }
$itemObjectCandidateRows = if (Test-Path $ItemObjectLineageCandidatesPath) { @(Import-Csv -Path $ItemObjectLineageCandidatesPath | Where-Object { $_.item_qualified_name -and $_.object_name }) } else { @() }
$pipelineObjectCandidateRows = if (Test-Path $PipelineObjectLineageCandidatesPath) { @(Import-Csv -Path $PipelineObjectLineageCandidatesPath | Where-Object { $_.item_qualified_name -and $_.object_name }) } else { @() }
$itemObjectCandidateRows = @($itemObjectCandidateRows + $pipelineObjectCandidateRows)
$pipelineActivityLineageRows = if (Test-Path $PipelineActivityLineagePath) { @(Import-Csv -Path $PipelineActivityLineagePath | Where-Object { $_.pipeline_qualified_name -and $_.invoked_item_qualified_name }) } else { @() }
# Unfiltered (includes activities that do not themselves invoke an item, such
# as Fail/IfCondition/Wait control-flow activities) so the Succeeded/Failed/
# Completed dependsOn chain between two *invoking* activities can be walked
# even when a non-invoking activity sits in between them.
$pipelineActivityAllRows = if (Test-Path $PipelineActivityLineagePath) { @(Import-Csv -Path $PipelineActivityLineagePath | Where-Object { $_.pipeline_qualified_name -and $_.activity_name }) } else { @() }
$notebookSuperLineageObjectRows = if (Test-Path $NotebookSuperLineageObjectsPath) { @(Import-Csv -Path $NotebookSuperLineageObjectsPath | Where-Object { $_.item_qualified_name -and ($_.object_display_name -or $_.object_name) }) } else { @() }
$notebookSuperLineageFlowRows = if (Test-Path $NotebookSuperLineageFlowsPath) { @(Import-Csv -Path $NotebookSuperLineageFlowsPath | Where-Object { $_.item_qualified_name -and $_.source_object -and $_.target_object }) } else { @() }
$objectTypeOverrideRows = if (Test-Path $ObjectTypeOverridesPath) { @(Import-Csv -Path $ObjectTypeOverridesPath | Where-Object { $_.object_name -and $_.object_type }) } else { @() }
$objectTypeMetadataEvidenceRows = if (Test-Path $ObjectTypeMetadataEvidencePath) { @(Import-Csv -Path $ObjectTypeMetadataEvidencePath | Where-Object { $_.object_name -and $_.object_type }) } else { @() }
$sqlEndpointCatalogRows = if (Test-Path $SqlEndpointCatalogPath) { @(Import-Csv -Path $SqlEndpointCatalogPath | Where-Object { $_.object_name -and $_.object_type -and ((Get-FieldValue -Object $_ -Names @("catalog_status")) -in @("", "confirmed")) }) } else { @() }
$objectColumnCatalogRows = if (Test-Path $ObjectColumnCatalogPath) { @(Import-Csv -Path $ObjectColumnCatalogPath | Where-Object { $_.object_name -and $_.column_name }) } else { @() }

# Table/view detail panels show real column composition (name + type) when a
# read-only sys.columns catalog row exists for the object's server/database/
# schema/object_name. Objects with an unresolved schema (common for native-query
# parsed candidates) fall back to a schema-agnostic name match, but only when
# that name is unambiguous across schemas in that database -- otherwise the
# column list is left off rather than guessing the wrong table's columns.
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

function Get-ColumnsForObjectRow {
    param([object]$ObjectRow)
    $server = Get-FieldValue -Object $ObjectRow -Names @("server")
    $database = Get-FieldValue -Object $ObjectRow -Names @("database")
    $schema = Get-FieldValue -Object $ObjectRow -Names @("schema")
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

function Add-ColumnsToSourceObjects {
    param([object[]]$Sources)
    foreach ($sourceNode in @($Sources)) {
        foreach ($objectRow in @($sourceNode.objects)) {
            $columns = @(Get-ColumnsForObjectRow -ObjectRow $objectRow)
            if ($columns.Count -gt 0) {
                $objectRow | Add-Member -Force -NotePropertyName "columns" -NotePropertyValue $columns
            }
        }
    }
}

$sharePointObjectTypeRows = if ($SharePointObjectTypeEvidencePath -and (Test-Path $SharePointObjectTypeEvidencePath)) { @(Import-Csv -Path $SharePointObjectTypeEvidencePath | Where-Object { $_.object_name -and $_.object_type }) } else { @() }
$deploymentPipelineRows = if (Test-Path $DeploymentPipelinesPath) { @(Import-Csv -Path $DeploymentPipelinesPath | Where-Object { $_.deployment_pipeline_id }) } else { @() }
$deploymentPipelineStageRows = if (Test-Path $DeploymentPipelineStagesPath) { @(Import-Csv -Path $DeploymentPipelineStagesPath | Where-Object { $_.deployment_pipeline_id -and $_.stage_id }) } else { @() }
$deploymentPipelineGroupRows = if (Test-Path $DeploymentPipelineGroupsPath) { @(Import-Csv -Path $DeploymentPipelineGroupsPath | Where-Object { $_.deployment_pipeline_id }) } else { @() }
foreach ($row in $objectTypeOverrideRows) {
    Add-ObjectTypeResolver -Map $script:ObjectTypeOverrideMap -Source "override" -Row $row -ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
}
foreach ($row in $manualObjectEvidenceRows) {
    Add-ObjectTypeResolver -Map $script:ManualObjectTypeMap -Source "manual_review" -Row $row -ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
}
foreach ($row in $objectTypeMetadataEvidenceRows) {
    Add-ObjectTypeResolver -Map $script:MetadataObjectTypeMap -Source "metadata_readonly" -Row $row -ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
}
foreach ($row in $sqlEndpointCatalogRows) {
    Add-ObjectTypeResolver -Map $script:MetadataObjectTypeMap -Source "sql_endpoint_catalog" -Row $row -ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
}
foreach ($row in $sharePointObjectTypeRows) {
    Add-ObjectTypeResolver -Map $script:SharePointObjectTypeMap -Source "sharepoint_catalog" -Row $row -ObjectType (Get-FieldValue -Object $row -Names @("object_type"))
}

$objectsByModel = @{}
$objectsBySource = @{}
$manualObjectsByItem = @{}
$notebookSuperObjectsByItem = @{}
$notebookSuperFlowsByItem = @{}

foreach ($row in $notebookSuperLineageObjectRows) {
    if (-not $notebookSuperObjectsByItem.ContainsKey($row.item_qualified_name)) {
        $notebookSuperObjectsByItem[$row.item_qualified_name] = [System.Collections.Generic.List[object]]::new()
    }
    $notebookSuperObjectsByItem[$row.item_qualified_name].Add($row) | Out-Null
}

foreach ($row in $notebookSuperLineageFlowRows) {
    if (-not $notebookSuperFlowsByItem.ContainsKey($row.item_qualified_name)) {
        $notebookSuperFlowsByItem[$row.item_qualified_name] = [System.Collections.Generic.List[object]]::new()
    }
    $notebookSuperFlowsByItem[$row.item_qualified_name].Add($row) | Out-Null
}

foreach ($row in $itemObjectCandidateRows) {
    $itemQualifiedName = Get-FieldValue -Object $row -Names @("item_qualified_name", "qualified_name")
    if (-not $itemQualifiedName) { continue }

    $sourceServer = Get-FieldValue -Object $row -Names @("source_server", "server")
    $sourceDatabase = Get-FieldValue -Object $row -Names @("source_database", "database_name", "database")
    $sourceName = Get-FieldValue -Object $row -Names @("source_name", "source_label")
    $objectName = Get-FieldValue -Object $row -Names @("object_name", "source_object")
    $schemaName = Get-FieldValue -Object $row -Names @("schema_name", "source_schema")
    $sourceType = Get-FieldValue -Object $row -Names @("source_type")
    $placeholder = Convert-FabricPlaceholderObject -SourceType $sourceType -SourceDatabase $sourceDatabase -SchemaName $schemaName -ObjectName $objectName -Label ""
    if ($placeholder.changed) {
        $sourceType = $placeholder.source_type
        $sourceDatabase = $placeholder.source_database
        $schemaName = $placeholder.schema_name
        $objectName = $placeholder.object_name
        if (-not $sourceName) { $sourceName = $sourceDatabase }
    }
    $objectType = Get-FieldValue -Object $row -Names @("object_type")
    $confidence = Get-FieldValue -Object $row -Names @("confidence")
    if (-not $objectType) { $objectType = "native_query_object" }
    if (-not $confidence) { $confidence = "likely" }

    $typeResolution = Resolve-SourceObjectType -SourceType $sourceType -SourceServer $sourceServer -SourceDatabase $sourceDatabase -SchemaName $schemaName -ObjectName $objectName -RawObjectType $objectType
    if ((Test-ExactObjectType $objectType) -and $typeResolution.source -notin @("override", "manual_review")) {
        $typeResolution = [pscustomobject]@{
            object_type = Normalize-ObjectType $objectType
            source = "definition_extraction"
            confidence = $confidence
            evidence = Get-FieldValue -Object $row -Names @("evidence")
        }
    }
    $objectTypeEvidence = if ($typeResolution.evidence) { $typeResolution.evidence } else { "" }

    $objectNode = [pscustomobject]@{
        label = if ($schemaName) { "$schemaName.$objectName" } else { $objectName }
        type = $typeResolution.object_type
        raw_object_type = $objectType
        object_type_source = $typeResolution.source
        object_type_confidence = $typeResolution.confidence
        object_type_evidence = $objectTypeEvidence
        schema = $schemaName
        object_name = $objectName
        semantic_table = Get-FieldValue -Object $row -Names @("semantic_table", "logical_table")
        database = $sourceDatabase
        server = $sourceServer
        source_name = $sourceName
        source_type = $sourceType
        source_qualified_name = Get-FieldValue -Object $row -Names @("source_qualified_name")
        usage_type = Get-FieldValue -Object $row -Names @("usage_type")
        confidence = $confidence
        evidence = (@((Get-FieldValue -Object $row -Names @("evidence")), $(if ($objectTypeEvidence) { "Object type: $objectTypeEvidence" } else { "" })) | Where-Object { $_ }) -join " "
        definition_path = Get-FieldValue -Object $row -Names @("definition_path")
        activity_name = Get-FieldValue -Object $row -Names @("activity_name")
        activity_type = Get-FieldValue -Object $row -Names @("activity_type")
        invoked_item_qualified_name = Get-FieldValue -Object $row -Names @("invoked_item_qualified_name")
        evidence_origin = "definition_extraction"
    }

    if (-not $objectsByModel.ContainsKey($itemQualifiedName)) {
        $objectsByModel[$itemQualifiedName] = [System.Collections.Generic.List[object]]::new()
    }
    $objectsByModel[$itemQualifiedName].Add($objectNode) | Out-Null

    if (-not $manualObjectsByItem.ContainsKey($itemQualifiedName)) {
        $manualObjectsByItem[$itemQualifiedName] = [System.Collections.Generic.List[object]]::new()
    }
    $manualObjectsByItem[$itemQualifiedName].Add($objectNode) | Out-Null

    $sourceKey = Normalize-Key "$sourceServer|$sourceDatabase"
    if ($sourceKey -and -not $objectsBySource.ContainsKey($sourceKey)) {
        $objectsBySource[$sourceKey] = [System.Collections.Generic.List[object]]::new()
    }
    if ($sourceKey) {
        $objectsBySource[$sourceKey].Add($objectNode) | Out-Null
    }
}
$migrationRows = if (Test-Path $MigrationMapPath) { @(Import-Csv -Path $MigrationMapPath | Where-Object { $_.source_server -or $_.fabric_item_name }) } else { @() }
$criticalRows = if (Test-Path $CriticalPathPath) { @(Import-Csv -Path $CriticalPathPath) } else { @() }
$failureRows = if (Test-Path $FailureHotspotsPath) { @(Import-Csv -Path $FailureHotspotsPath) } else { @() }
$scheduleReviewRows = if (Test-Path $ScheduleReviewPath) { @(Import-Csv -Path $ScheduleReviewPath) } else { @() }
$parallelRows = if (Test-Path $ParallelismCandidatesPath) { @(Import-Csv -Path $ParallelismCandidatesPath) } else { @() }
$orchestrationGroupRows = if (Test-Path $OrchestrationGroupCandidatesPath) { @(Import-Csv -Path $OrchestrationGroupCandidatesPath) } else { @() }

$itemByQualifiedName = @{}
foreach ($item in $items) { $itemByQualifiedName[$item.qualified_name] = $item }

$analysisByQualifiedName = @{}
foreach ($row in $analysisRows) {
    if ($row.qualified_name -and -not $analysisByQualifiedName.ContainsKey($row.qualified_name)) {
        $analysisByQualifiedName[$row.qualified_name] = $row
    }
}

$criticalByQualifiedName = @{}
foreach ($row in $criticalRows) {
    if ($row.qualified_name -and -not $criticalByQualifiedName.ContainsKey($row.qualified_name)) {
        $criticalByQualifiedName[$row.qualified_name] = $row
    }
}

$failureByQualifiedName = @{}
foreach ($row in $failureRows) {
    if ($row.qualified_name -and -not $failureByQualifiedName.ContainsKey($row.qualified_name)) {
        $failureByQualifiedName[$row.qualified_name] = $row
    }
}

$scheduleReviewByQualifiedName = @{}
foreach ($row in $scheduleReviewRows) {
    if ($row.qualified_name -and -not $scheduleReviewByQualifiedName.ContainsKey($row.qualified_name)) {
        $scheduleReviewByQualifiedName[$row.qualified_name] = $row
    }
}

$orchestrationGroupByQualifiedName = @{}
foreach ($row in $orchestrationGroupRows) {
    if ($row.source_qualified_name -and -not $orchestrationGroupByQualifiedName.ContainsKey($row.source_qualified_name)) {
        $orchestrationGroupByQualifiedName[$row.source_qualified_name] = $row
    }
}

$parallelCountsByQualifiedName = @{}
foreach ($row in $parallelRows) {
    foreach ($name in @($row.candidate_a, $row.candidate_b)) {
        if (-not $name) { continue }
        if (-not $parallelCountsByQualifiedName.ContainsKey($name)) {
            $parallelCountsByQualifiedName[$name] = 0
        }
        $parallelCountsByQualifiedName[$name] += 1
    }
}

$workspaceById = @{}
$workspaceByName = @{}
foreach ($workspace in $workspaces) {
    $workspaceId = Get-FieldValue -Object $workspace -Names @("technical_id", "workspace_id")
    $workspaceName = Get-FieldValue -Object $workspace -Names @("workspace_name")
    if ($workspaceId -and -not $workspaceById.ContainsKey((Normalize-Key $workspaceId))) {
        $workspaceById[(Normalize-Key $workspaceId)] = $workspace
    }
    if ($workspaceName -and -not $workspaceByName.ContainsKey((Normalize-Key $workspaceName))) {
        $workspaceByName[(Normalize-Key $workspaceName)] = $workspace
    }
}

$pipelineById = @{}
foreach ($pipeline in $deploymentPipelineRows) {
    $pipelineId = Get-FieldValue -Object $pipeline -Names @("deployment_pipeline_id")
    if ($pipelineId -and -not $pipelineById.ContainsKey($pipelineId)) {
        $pipelineById[$pipelineId] = $pipeline
    }
}

$deploymentStageByWorkspaceName = @{}
foreach ($stage in $deploymentPipelineStageRows) {
    $pipelineId = Get-FieldValue -Object $stage -Names @("deployment_pipeline_id")
    $workspaceId = Get-FieldValue -Object $stage -Names @("workspace_id")
    $workspaceName = Get-FieldValue -Object $stage -Names @("workspace_name")
    $localWorkspaceName = ""
    if ($workspaceId -and $workspaceById.ContainsKey((Normalize-Key $workspaceId))) {
        $localWorkspaceName = Get-FieldValue -Object $workspaceById[(Normalize-Key $workspaceId)] -Names @("workspace_name")
    }
    elseif ($workspaceName -and $workspaceByName.ContainsKey((Normalize-Key $workspaceName))) {
        $localWorkspaceName = Get-FieldValue -Object $workspaceByName[(Normalize-Key $workspaceName)] -Names @("workspace_name")
    }
    if (-not $localWorkspaceName) { continue }

    $pipeline = if ($pipelineById.ContainsKey($pipelineId)) { $pipelineById[$pipelineId] } else { $null }
    $deploymentStageByWorkspaceName[$localWorkspaceName] = [pscustomobject]@{
        deployment_pipeline_id = $pipelineId
        deployment_pipeline_name = Get-FieldValue -Object $stage -Names @("deployment_pipeline_name")
        deployment_pipeline_description = if ($pipeline) { Get-FieldValue -Object $pipeline -Names @("description") } else { "" }
        stage_id = Get-FieldValue -Object $stage -Names @("stage_id")
        stage_order = Get-FieldValue -Object $stage -Names @("stage_order")
        stage_name = Get-FieldValue -Object $stage -Names @("stage_name")
        stage_description = Get-FieldValue -Object $stage -Names @("stage_description")
        stage_workspace_id = $workspaceId
        stage_workspace_name = if ($workspaceName) { $workspaceName } else { $localWorkspaceName }
        is_public = Get-FieldValue -Object $stage -Names @("is_public")
        status = Get-FieldValue -Object $stage -Names @("status")
        evidence = Get-FieldValue -Object $stage -Names @("evidence")
    }
}

$dependenciesByFrom = @{}
foreach ($dep in $dependencies) {
    if (-not $dependenciesByFrom.ContainsKey($dep.from_qualified_name)) {
        $dependenciesByFrom[$dep.from_qualified_name] = [System.Collections.Generic.List[object]]::new()
    }
    $dependenciesByFrom[$dep.from_qualified_name].Add($dep) | Out-Null
}

# "pipeline_qualified_name|invoked_item_qualified_name" -> list of {activity_name, activity_type, parameters}.
# A pipeline can invoke the same notebook from more than one activity with
# different parameters each time, so this is a list, not a single value.
# pipeline_activity_lineage.csv has one row per (activity, dependsOn) pair, so
# the same activity can appear multiple times here - dedupe by
# (activity_name, parameters JSON) so it only shows up once per distinct invocation.
$activitiesByPipelineAndTarget = @{}
$seenActivityInvocations = @{}
foreach ($row in $pipelineActivityLineageRows) {
    $rawParameters = Get-FieldValue -Object $row -Names @("parameters")
    if (-not $rawParameters) { continue }
    $parsedParameters = $null
    try { $parsedParameters = $rawParameters | ConvertFrom-Json } catch { $parsedParameters = $null }
    if (-not $parsedParameters) { continue }
    $key = "$($row.pipeline_qualified_name)|$($row.invoked_item_qualified_name)"
    $activityName = Get-FieldValue -Object $row -Names @("activity_name")
    $dedupeKey = "$key|$activityName|$rawParameters"
    if ($seenActivityInvocations.ContainsKey($dedupeKey)) { continue }
    $seenActivityInvocations[$dedupeKey] = $true
    if (-not $activitiesByPipelineAndTarget.ContainsKey($key)) {
        $activitiesByPipelineAndTarget[$key] = [System.Collections.Generic.List[object]]::new()
    }
    $activitiesByPipelineAndTarget[$key].Add([pscustomobject]@{
        activity_name = $activityName
        activity_type = Get-FieldValue -Object $row -Names @("activity_type")
        parameters = $parsedParameters
    }) | Out-Null
}

# Real Fabric/ADF pipeline activities declare dependsOn with dependencyConditions
# (Succeeded/Failed/Completed/Skipped) between activities in the SAME pipeline.
# Resolve that into direct item-to-item edges (e.g. "Notebook A" -> "CopyJob B")
# so the Planning view can color arrows the same way the pipeline canvas does,
# instead of only inferring order from read/write table overlap. Some
# activities in between (Fail/IfCondition/Wait/...) do not themselves invoke
# an item, so walk backward through the dependsOn chain (bounded depth) to
# find the nearest invoking ancestor(s).
$activityInvokesByPipeline = @{}
$activityDependsOnByPipeline = @{}
foreach ($row in $pipelineActivityAllRows) {
    $pipelineKey = $row.pipeline_qualified_name
    if (-not $activityInvokesByPipeline.ContainsKey($pipelineKey)) {
        $activityInvokesByPipeline[$pipelineKey] = @{}
        $activityDependsOnByPipeline[$pipelineKey] = @{}
    }
    $activityName = Get-FieldValue -Object $row -Names @("activity_name")
    if (-not $activityName) { continue }
    $invokedItem = Get-FieldValue -Object $row -Names @("invoked_item_qualified_name")
    if ($invokedItem -and -not $activityInvokesByPipeline[$pipelineKey].ContainsKey($activityName)) {
        $activityInvokesByPipeline[$pipelineKey][$activityName] = $invokedItem
    }
    $dependsOnActivity = Get-FieldValue -Object $row -Names @("depends_on_activity")
    if ($dependsOnActivity) {
        if (-not $activityDependsOnByPipeline[$pipelineKey].ContainsKey($activityName)) {
            $activityDependsOnByPipeline[$pipelineKey][$activityName] = [System.Collections.Generic.List[object]]::new()
        }
        $rawConditions = Get-FieldValue -Object $row -Names @("dependency_conditions")
        $activityDependsOnByPipeline[$pipelineKey][$activityName].Add([pscustomobject]@{
            depends_on_activity = $dependsOnActivity
            conditions = @($rawConditions -split ";" | Where-Object { $_ })
        }) | Out-Null
    }
}

function Resolve-PlanningEdgeCondition {
    param([string[]]$ConditionChain)
    if ($ConditionChain -contains "Failed") { return "failed" }
    if ($ConditionChain.Count -eq 0) { return "completed" }
    if (@($ConditionChain | Where-Object { $_ -and $_ -ne "Succeeded" }).Count -eq 0) { return "succeeded" }
    return "completed"
}

$pipelineActivityDependencyEdges = [System.Collections.Generic.List[object]]::new()
$activityWalkMaxDepth = 6
foreach ($pipelineKey in $activityInvokesByPipeline.Keys) {
    $invokes = $activityInvokesByPipeline[$pipelineKey]
    $dependsOnMap = $activityDependsOnByPipeline[$pipelineKey]
    $seenEdges = @{}
    foreach ($activityName in $invokes.Keys) {
        $toItem = $invokes[$activityName]
        $queue = [System.Collections.Generic.Queue[object]]::new()
        if ($dependsOnMap.ContainsKey($activityName)) {
            foreach ($dep in $dependsOnMap[$activityName]) {
                $queue.Enqueue([pscustomobject]@{ Activity = $dep.depends_on_activity; Chain = @($dep.conditions); Depth = 1 })
            }
        }
        $visited = @{}
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            if ($current.Depth -gt $activityWalkMaxDepth) { continue }
            if ($visited.ContainsKey($current.Activity)) { continue }
            $visited[$current.Activity] = $true
            if ($invokes.ContainsKey($current.Activity) -and $invokes[$current.Activity] -ne $toItem) {
                $fromItem = $invokes[$current.Activity]
                $condition = Resolve-PlanningEdgeCondition -ConditionChain $current.Chain
                $edgeKey = "$fromItem|$toItem|$condition"
                if (-not $seenEdges.ContainsKey($edgeKey)) {
                    $seenEdges[$edgeKey] = $true
                    $pipelineActivityDependencyEdges.Add([pscustomobject]@{
                        pipeline_qualified_name = $pipelineKey
                        from_item_qualified_name = $fromItem
                        to_item_qualified_name = $toItem
                        condition = $condition
                    }) | Out-Null
                }
                continue
            }
            if ($dependsOnMap.ContainsKey($current.Activity)) {
                foreach ($dep in $dependsOnMap[$current.Activity]) {
                    $queue.Enqueue([pscustomobject]@{ Activity = $dep.depends_on_activity; Chain = @($current.Chain + @($dep.conditions)); Depth = $current.Depth + 1 })
                }
            }
        }
    }
}

$executionsByQualifiedName = @{}
foreach ($row in $executions) {
    if (-not $executionsByQualifiedName.ContainsKey($row.qualified_name)) {
        $executionsByQualifiedName[$row.qualified_name] = [System.Collections.Generic.List[object]]::new()
    }
    $executionsByQualifiedName[$row.qualified_name].Add($row) | Out-Null
}

foreach ($row in $viewCandidates) {
    $sourceType = "SQL"
    $sourceServer = Get-FieldValue -Object $row -Names @("source_server")
    $sourceDatabase = Get-FieldValue -Object $row -Names @("database_name", "source_database")
    $schemaName = Get-FieldValue -Object $row -Names @("schema_name")
    $objectName = Get-FieldValue -Object $row -Names @("object_name")
    $rawObjectType = Get-FieldValue -Object $row -Names @("object_type")
    $typeResolution = Resolve-SourceObjectType -SourceType $sourceType -SourceServer $sourceServer -SourceDatabase $sourceDatabase -SchemaName $schemaName -ObjectName $objectName -RawObjectType $rawObjectType
    $candidateEvidence = Get-FieldValue -Object $row -Names @("evidence")
    $objectTypeEvidence = if ($typeResolution.evidence) { $typeResolution.evidence } else { "" }
    $objectNode = [pscustomobject]@{
        label = if ($schemaName) { "$schemaName.$objectName" } elseif ($objectName) { $objectName } else { $sourceDatabase }
        type = $typeResolution.object_type
        raw_object_type = $rawObjectType
        object_type_source = $typeResolution.source
        object_type_confidence = $typeResolution.confidence
        object_type_evidence = $objectTypeEvidence
        schema = $schemaName
        object_name = $objectName
        semantic_table = Get-FieldValue -Object $row -Names @("semantic_table")
        database = $sourceDatabase
        server = $sourceServer
        source_type = $sourceType
        confidence = Get-FieldValue -Object $row -Names @("confidence")
        evidence = (@($candidateEvidence, $(if ($objectTypeEvidence) { "Object type: $objectTypeEvidence" } else { "" })) | Where-Object { $_ }) -join " "
    }
    if (-not $objectsByModel.ContainsKey($row.semantic_model_qualified_name)) {
        $objectsByModel[$row.semantic_model_qualified_name] = [System.Collections.Generic.List[object]]::new()
    }
    $objectsByModel[$row.semantic_model_qualified_name].Add($objectNode) | Out-Null

    $sourceKey = Normalize-Key "$sourceServer|$sourceDatabase"
    if ($sourceKey -and -not $objectsBySource.ContainsKey($sourceKey)) {
        $objectsBySource[$sourceKey] = [System.Collections.Generic.List[object]]::new()
    }
    if ($sourceKey) {
        $objectsBySource[$sourceKey].Add($objectNode) | Out-Null
    }
}

foreach ($row in $manualObjectEvidenceRows) {
    $itemQualifiedName = Get-FieldValue -Object $row -Names @("item_qualified_name", "qualified_name")
    if (-not $itemQualifiedName) { continue }

    $sourceServer = Get-FieldValue -Object $row -Names @("source_server", "server")
    $sourceDatabase = Get-FieldValue -Object $row -Names @("source_database", "database_name", "database")
    $sourceName = Get-FieldValue -Object $row -Names @("source_name", "source_label")
    $objectName = Get-FieldValue -Object $row -Names @("object_name", "source_object")
    $schemaName = Get-FieldValue -Object $row -Names @("schema_name", "source_schema")
    $sourceType = Get-FieldValue -Object $row -Names @("source_type")
    $placeholder = Convert-FabricPlaceholderObject -SourceType $sourceType -SourceDatabase $sourceDatabase -SchemaName $schemaName -ObjectName $objectName -Label ""
    if ($placeholder.changed) {
        $sourceType = $placeholder.source_type
        $sourceDatabase = $placeholder.source_database
        $schemaName = $placeholder.schema_name
        $objectName = $placeholder.object_name
        if (-not $sourceName) { $sourceName = $sourceDatabase }
    }
    $objectType = Get-FieldValue -Object $row -Names @("object_type")
    $confidence = Get-FieldValue -Object $row -Names @("confidence")
    if (-not $objectType) { $objectType = "manual_object" }
    if (-not $confidence) { $confidence = "confirmed" }
    $typeResolution = Resolve-SourceObjectType -SourceType $sourceType -SourceServer $sourceServer -SourceDatabase $sourceDatabase -SchemaName $schemaName -ObjectName $objectName -RawObjectType $objectType
    if ((Test-ExactObjectType $objectType) -and $typeResolution.source -notin @("override")) {
        $typeResolution = [pscustomobject]@{
            object_type = Normalize-ObjectType $objectType
            source = "manual_review"
            confidence = $confidence
            evidence = Get-FieldValue -Object $row -Names @("evidence")
        }
    }
    $objectTypeEvidence = if ($typeResolution.evidence) { $typeResolution.evidence } else { "" }

    $objectNode = [pscustomobject]@{
        label = if ($schemaName) { "$schemaName.$objectName" } else { $objectName }
        type = $typeResolution.object_type
        raw_object_type = $objectType
        object_type_source = $typeResolution.source
        object_type_confidence = $typeResolution.confidence
        object_type_evidence = $objectTypeEvidence
        schema = $schemaName
        object_name = $objectName
        semantic_table = Get-FieldValue -Object $row -Names @("semantic_table", "logical_table")
        database = $sourceDatabase
        server = $sourceServer
        source_name = $sourceName
        source_type = $sourceType
        source_qualified_name = Get-FieldValue -Object $row -Names @("source_qualified_name")
        usage_type = Get-FieldValue -Object $row -Names @("usage_type")
        confidence = $confidence
        evidence = (@((Get-FieldValue -Object $row -Names @("evidence")), $(if ($objectTypeEvidence) { "Object type: $objectTypeEvidence" } else { "" })) | Where-Object { $_ }) -join " "
        reviewer = Get-FieldValue -Object $row -Names @("reviewer")
        reviewed_at = Get-FieldValue -Object $row -Names @("reviewed_at")
        notes = Get-FieldValue -Object $row -Names @("notes")
        evidence_origin = "manual_review"
    }

    if (-not $objectsByModel.ContainsKey($itemQualifiedName)) {
        $objectsByModel[$itemQualifiedName] = [System.Collections.Generic.List[object]]::new()
    }
    $objectsByModel[$itemQualifiedName].Add($objectNode) | Out-Null

    if (-not $manualObjectsByItem.ContainsKey($itemQualifiedName)) {
        $manualObjectsByItem[$itemQualifiedName] = [System.Collections.Generic.List[object]]::new()
    }
    $manualObjectsByItem[$itemQualifiedName].Add($objectNode) | Out-Null

    $sourceKey = Normalize-Key "$sourceServer|$sourceDatabase"
    if ($sourceKey -and -not $objectsBySource.ContainsKey($sourceKey)) {
        $objectsBySource[$sourceKey] = [System.Collections.Generic.List[object]]::new()
    }
    if ($sourceKey) {
        $objectsBySource[$sourceKey].Add($objectNode) | Out-Null
    }
}

function Get-UniqueObjects {
    param([object[]]$Objects)
    $seen = @{}
    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($object in @($Objects)) {
        if (-not $object) { continue }
        $key = Normalize-Key "$($object.server)|$($object.database)|$($object.type)|$($object.schema)|$($object.object_name)|$($object.label)"
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $result.Add($object) | Out-Null
        }
    }
    return @($result.ToArray())
}

function Get-SourcePartsForDependency {
    param([object]$Dependency)
    $target = $Dependency.to_qualified_name
    if ($target.StartsWith("External Connection /")) {
        return Get-ExternalConnectionParts -QualifiedName $target
    }
    if ($itemByQualifiedName.ContainsKey($target)) {
        $targetItem = $itemByQualifiedName[$target]
        return [pscustomobject]@{
            source_type = $targetItem.item_type
            source_server = $targetItem.workspace_name
            source_database = $targetItem.item_name
            source_object = ""
            label = $targetItem.item_name
        }
    }
    return [pscustomobject]@{
        source_type = Get-ItemTypeFromQualifiedName -QualifiedName $target
        source_server = Get-WorkspaceNameFromQualifiedName -QualifiedName $target
        source_database = Get-ItemNameFromQualifiedName -QualifiedName $target
        source_object = ""
        label = Get-ItemNameFromQualifiedName -QualifiedName $target
    }
}

function Get-CandidateObjectsForDependency {
    param([object]$Dependency, [object[]]$ModelObjects)
    $parts = Get-SourcePartsForDependency -Dependency $Dependency
    $localObjects = @()
    if ($ModelObjects.Count -gt 0) {
        # Fabric's connections API often reports an "External Connection"
        # qualified name with just a database (e.g. "SQL / CONTOSO_SALES_DW",
        # no ";server" segment -- see Get-ExternalConnectionParts), so
        # $parts.source_server ends up empty even though the semantic
        # model's own TMDL definition (parsed into $ModelObjects) does know
        # the real server. Requiring server equality in that case rejected
        # every real object candidate on an empty-vs-populated mismatch, so
        # a source dependency's "objects" list came back empty even when
        # the TMDL enrichment step had already found the real tables. Only
        # require server to match when *both* sides actually have one.
        $localObjects = @($ModelObjects | Where-Object {
            (Normalize-Key $_.database) -eq (Normalize-Key $parts.source_database) -and
            ((-not $_.server) -or (-not $parts.source_server) -or (Normalize-Key $_.server) -eq (Normalize-Key $parts.source_server))
        })
    }
    $globalObjects = @()
    $sourceKey = Normalize-Key "$($parts.source_server)|$($parts.source_database)"
    if ($sourceKey -and $objectsBySource.ContainsKey($sourceKey)) {
        $globalObjects = @($objectsBySource[$sourceKey].ToArray())
    }
    return @(Get-UniqueObjects -Objects @($localObjects + $globalObjects))
}

function Get-ManualSourceTarget {
    param([object]$Object)

    if ($Object.source_qualified_name) {
        return [string]$Object.source_qualified_name
    }

    $sourceType = if ($Object.source_type) { [string]$Object.source_type } else { "Manual" }
    if ($Object.server -and $Object.database) {
        return "External Connection / $sourceType / $($Object.server);$($Object.database)"
    }
    if ($Object.source_name) {
        return "External Connection / $sourceType / $($Object.source_name)"
    }
    if ($Object.database) {
        return "External Connection / $sourceType / $($Object.database)"
    }
    return "External Connection / Manual / Reviewed source"
}

function Get-ManualSourceNodesForItem {
    param(
        [object]$Item,
        [object[]]$ManualObjects,
        [object[]]$ExistingSourceDeps
    )

    if ($ManualObjects.Count -eq 0) { return @() }

    $existingTargets = @{}
    $existingSourceKeys = @{}
    foreach ($dep in @($ExistingSourceDeps)) {
        if ($dep.to_qualified_name) {
            $existingTargets[(Normalize-Key $dep.to_qualified_name)] = $true
        }
        $parts = Get-SourcePartsForDependency -Dependency $dep
        $sourceKey = Normalize-Key "$($parts.source_server)|$($parts.source_database)"
        if ($sourceKey) { $existingSourceKeys[$sourceKey] = $true }
    }

    $groups = @{}
    foreach ($object in @($ManualObjects)) {
        $target = Get-ManualSourceTarget -Object $object
        $sourceKey = Normalize-Key "$($object.server)|$($object.database)"
        if ($existingTargets.ContainsKey((Normalize-Key $target)) -or ($sourceKey -and $existingSourceKeys.ContainsKey($sourceKey))) {
            continue
        }

        $groupKey = Normalize-Key "$target|$sourceKey|$($object.source_name)"
        if (-not $groups.ContainsKey($groupKey)) {
            $groups[$groupKey] = [System.Collections.Generic.List[object]]::new()
        }
        $groups[$groupKey].Add($object) | Out-Null
    }

    $nodes = [System.Collections.Generic.List[object]]::new()
    foreach ($key in ($groups.Keys | Sort-Object)) {
        $objects = @(Get-UniqueObjects -Objects @($groups[$key].ToArray()))
        if ($objects.Count -eq 0) { continue }

        $target = Get-ManualSourceTarget -Object $objects[0]
        $confidenceValues = @($objects | ForEach-Object { $_.confidence } | Where-Object { $_ } | Select-Object -Unique)
        $confidence = if ($confidenceValues -contains "unknown") { "unknown" } elseif ($confidenceValues -contains "likely") { "likely" } else { "confirmed" }
        $evidenceText = @(
            $objects |
                ForEach-Object {
                    if ($_.evidence) { $_.evidence } else { "Manual review evidence for $($_.label)." }
                } |
                Select-Object -Unique
        ) -join "; "

        $dependency = [pscustomobject]@{
            to_qualified_name = $target
            confidence = $confidence
            evidence = "Manual lineage review for $($Item.qualified_name): $evidenceText"
        }
        $nodes.Add((New-SourceNode -Dependency $dependency -ItemByQualifiedName $itemByQualifiedName -ObjectRows $objects -MigrationRows $migrationRows)) | Out-Null
    }

    return @($nodes.ToArray())
}

function Convert-NotebookLineageConfidence {
    param([object]$Row)
    $confidence = Get-FieldValue -Object $Row -Names @("confidence")
    $unresolved = Get-FieldValue -Object $Row -Names @("unresolved_variables")
    if ($unresolved) { return "likely" }
    if ($confidence -eq "parsed") { return "confirmed" }
    if ($confidence -in @("confirmed", "likely", "unknown")) { return $confidence }
    return "likely"
}

function Get-NotebookUsageType {
    param([string]$Direction)
    if ($Direction -eq "write") { return "writes_to" }
    if ($Direction -eq "execute") { return "executes" }
    return "reads_from"
}

function Get-NotebookObjectType {
    param([object]$Row)
    $sourceType = Get-FieldValue -Object $Row -Names @("source_type")
    $direction = Get-FieldValue -Object $Row -Names @("direction")
    $objectName = Get-FieldValue -Object $Row -Names @("object_name")
    if ($sourceType -eq "File") { return "file" }
    if ($direction -eq "execute") { return "stored_procedure" }
    if ($objectName -eq "*") { return "schema" }
    if ($sourceType -eq "LakehouseTable") { return "table" }
    return "table_or_view"
}

function New-NotebookSuperLineageObjectNode {
    param([object]$Row)
    $schemaName = Get-FieldValue -Object $Row -Names @("schema_name")
    $objectName = Get-FieldValue -Object $Row -Names @("object_name")
    $display = Get-FieldValue -Object $Row -Names @("object_display_name")
    $sourceType = Get-FieldValue -Object $Row -Names @("source_type")
    $sourceDatabase = Get-FieldValue -Object $Row -Names @("source_database")
    $placeholder = Convert-FabricPlaceholderObject -SourceType $sourceType -SourceDatabase $sourceDatabase -SchemaName $schemaName -ObjectName $objectName -Label $display
    if ($placeholder.changed) {
        $sourceType = $placeholder.source_type
        $sourceDatabase = $placeholder.source_database
        $schemaName = $placeholder.schema_name
        $objectName = $placeholder.object_name
        $display = $placeholder.display
    }
    $label = if ($schemaName -and $objectName) { "$schemaName.$objectName" } elseif ($objectName) { $objectName } else { $display }
    $confidence = Convert-NotebookLineageConfidence -Row $Row
    $direction = Get-FieldValue -Object $Row -Names @("direction")
    $nodeType = if ($sourceType -eq "File") {
        "file"
    }
    elseif ($direction -eq "execute") {
        "stored_procedure"
    }
    elseif ($objectName -eq "*") {
        "schema"
    }
    elseif ($sourceType -eq "LakehouseTable") {
        "table"
    }
    else {
        Get-NotebookObjectType -Row $Row
    }
    $evidence = @(
        "Notebook code static parse."
        Get-FieldValue -Object $Row -Names @("evidence")
        $(if ((Get-FieldValue -Object $Row -Names @("unresolved_variables"))) { "Unresolved variables: $(Get-FieldValue -Object $Row -Names @("unresolved_variables"))" } else { "" })
    ) | Where-Object { $_ }
    return [pscustomobject]@{
        label = $label
        type = $nodeType
        raw_object_type = $sourceType
        object_type_source = "notebook_static_parse"
        object_type_confidence = $confidence
        object_type_evidence = "Notebook definition parsed locally."
        schema = $schemaName
        object_name = $objectName
        semantic_table = ""
        database = $sourceDatabase
        server = ""
        source_name = $sourceDatabase
        source_type = $sourceType
        source_qualified_name = ""
        usage_type = Get-NotebookUsageType -Direction $direction
        confidence = $confidence
        evidence = ($evidence -join " ")
        definition_path = Get-FieldValue -Object $Row -Names @("definition_path")
        activity_name = Get-FieldValue -Object $Row -Names @("dataframe")
        activity_type = Get-FieldValue -Object $Row -Names @("operation")
        evidence_origin = "notebook_super_lineage"
    }
}

function Get-NotebookSourceLabel {
    param([object]$Item, [string]$Direction, [string]$SourceType, [string]$Database)
    if ($Database) { return $Database }
    if ($Direction -eq "write") { return "Destino pendiente" }
    if ($Direction -eq "execute") { return "Objetos ejecutados" }
    if ($SourceType -eq "File") { return "Archivos" }
    return "Origen pendiente"
}

function New-NotebookSuperLineageSources {
    param([object]$Item)
    if ($Item.item_type -ne "Notebook") { return @() }
    if (-not $notebookSuperObjectsByItem.ContainsKey($Item.qualified_name)) { return @() }

    $groups = @{}
    foreach ($row in @($notebookSuperObjectsByItem[$Item.qualified_name].ToArray())) {
        $direction = Get-FieldValue -Object $row -Names @("direction")
        $sourceType = Get-FieldValue -Object $row -Names @("source_type")
        $database = Get-FieldValue -Object $row -Names @("source_database")
        $key = Normalize-Key "$direction|$sourceType|$database"
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [System.Collections.Generic.List[object]]::new()
        }
        $groups[$key].Add($row) | Out-Null
    }

    $nodes = [System.Collections.Generic.List[object]]::new()
    foreach ($key in ($groups.Keys | Sort-Object)) {
        $rows = @($groups[$key].ToArray())
        if ($rows.Count -eq 0) { continue }
        $first = $rows[0]
        $direction = Get-FieldValue -Object $first -Names @("direction")
        $sourceType = Get-FieldValue -Object $first -Names @("source_type")
        $database = Get-FieldValue -Object $first -Names @("source_database")
        $objects = @(Get-UniqueObjects -Objects @($rows | ForEach-Object { New-NotebookSuperLineageObjectNode -Row $_ }))
        $confidenceValues = @($objects | ForEach-Object { $_.confidence } | Where-Object { $_ } | Select-Object -Unique)
        $confidence = if ($confidenceValues -contains "unknown") { "unknown" } elseif ($confidenceValues -contains "likely") { "likely" } else { "confirmed" }
        $label = Get-NotebookSourceLabel -Item $Item -Direction $direction -SourceType $sourceType -Database $database
        $nodes.Add([pscustomobject]@{
            id = "notebook-source:$((Normalize-Key "$($Item.qualified_name)|$direction|$sourceType|$database").GetHashCode())"
            label = $label
            type = "source"
            source_type = if ($sourceType) { $sourceType } else { "NotebookParse" }
            item_type = "NotebookObjectLineage"
            workspace_name = $Item.workspace_name
            qualified_name = "$($Item.qualified_name) / $direction / $label"
            server = if ($database) { $Item.workspace_name } else { "" }
            database = if ($database) { $database } else { "" }
            confidence = $confidence
            evidence = "Notebook source/destination objects parsed from downloaded definition. Direction: $direction."
            planning_role = if ($direction -eq "write") { "output" } else { "input" }
            objects = $objects
        }) | Out-Null
    }
    return @($nodes.ToArray())
}

function Get-NotebookSuperLineageSummary {
    param([object]$Item)
    if ($Item.item_type -ne "Notebook") { return $null }
    $objectRows = @()
    if ($notebookSuperObjectsByItem.ContainsKey($Item.qualified_name)) {
        $objectRows = @($notebookSuperObjectsByItem[$Item.qualified_name].ToArray())
    }
    $flowRows = @()
    if ($notebookSuperFlowsByItem.ContainsKey($Item.qualified_name)) {
        $flowRows = @($notebookSuperFlowsByItem[$Item.qualified_name].ToArray())
    }
    if ($objectRows.Count -eq 0 -and $flowRows.Count -eq 0) { return $null }
    return [pscustomobject]@{
        object_count = $objectRows.Count
        source_count = (@($objectRows | Where-Object { $_.direction -eq "read" })).Count
        destination_count = (@($objectRows | Where-Object { $_.direction -eq "write" })).Count
        execute_count = (@($objectRows | Where-Object { $_.direction -eq "execute" })).Count
        flow_count = $flowRows.Count
    }
}

function Get-PlanningInfo {
    param([object]$Item)
    $qualifiedName = $Item.qualified_name
    $critical = if ($criticalByQualifiedName.ContainsKey($qualifiedName)) { $criticalByQualifiedName[$qualifiedName] } else { $null }
    $failure = if ($failureByQualifiedName.ContainsKey($qualifiedName)) { $failureByQualifiedName[$qualifiedName] } else { $null }
    $scheduleReview = if ($scheduleReviewByQualifiedName.ContainsKey($qualifiedName)) { $scheduleReviewByQualifiedName[$qualifiedName] } else { $null }
    $group = if ($orchestrationGroupByQualifiedName.ContainsKey($qualifiedName)) { $orchestrationGroupByQualifiedName[$qualifiedName] } else { $null }
    $parallelCount = if ($parallelCountsByQualifiedName.ContainsKey($qualifiedName)) { $parallelCountsByQualifiedName[$qualifiedName] } else { 0 }
    $hints = [System.Collections.Generic.List[string]]::new()
    if ($critical -and $critical.recommendation_hint) { $hints.Add($critical.recommendation_hint) | Out-Null }
    if ($failure -and $failure.recommendation_hint) { $hints.Add($failure.recommendation_hint) | Out-Null }
    if ($scheduleReview -and $scheduleReview.recommendation_hint) { $hints.Add($scheduleReview.recommendation_hint) | Out-Null }
    if ($group -and $group.recommendation_hint) { $hints.Add($group.recommendation_hint) | Out-Null }
    if ($parallelCount -gt 0) { $hints.Add("Candidate parallel execution exists; validate reads/writes before parallel execution.") | Out-Null }

    return [pscustomobject]@{
        critical_path = [bool]$critical
        critical_rank = if ($critical) { $critical.rank } else { "" }
        failure_hotspot = [bool]$failure
        failure_rank = if ($failure) { $failure.rank } else { "" }
        failure_rate = if ($failure) { $failure.failure_rate } else { "" }
        schedule_review = [bool]$scheduleReview
        enabled_schedules = if ($scheduleReview) { $scheduleReview.enabled_schedules } else { "" }
        disabled_schedules = if ($scheduleReview) { $scheduleReview.disabled_schedules } else { "" }
        parallel_candidate_count = $parallelCount
        orchestration_group = [bool]$group
        executes_count = if ($group) { $group.executes_count } else { "" }
        recommendation_hint = (@($hints.ToArray()) | Select-Object -Unique) -join " | "
    }
}

function New-ItemNode {
    param([object]$Item)
    $analysis = if ($analysisByQualifiedName.ContainsKey($Item.qualified_name)) { $analysisByQualifiedName[$Item.qualified_name] } else { $null }
    $executionRows = @()
    if ($executionsByQualifiedName.ContainsKey($Item.qualified_name)) {
        $executionRows = @($executionsByQualifiedName[$Item.qualified_name].ToArray())
    }
    $deps = @()
    if ($dependenciesByFrom.ContainsKey($Item.qualified_name)) {
        $deps = @($dependenciesByFrom[$Item.qualified_name].ToArray())
    }
    $sourceDeps = @($deps | Where-Object { $_.relationship_type -eq "depends_on" })
    $executeDeps = @($deps | Where-Object { $_.relationship_type -eq "executes" })
    $reportDeps = @($deps | Where-Object { $_.relationship_type -eq "serves_report" })
    $modelDeps = @($deps | Where-Object { $_.relationship_type -eq "uses_model" })

    $objects = @()
    if ($objectsByModel.ContainsKey($Item.qualified_name)) {
        $objects = @($objectsByModel[$Item.qualified_name].ToArray())
    }
    $manualObjects = @()
    if ($manualObjectsByItem.ContainsKey($Item.qualified_name)) {
        $manualObjects = @($manualObjectsByItem[$Item.qualified_name].ToArray())
    }
    $manualSourceNodes = @(Get-ManualSourceNodesForItem -Item $Item -ManualObjects $manualObjects -ExistingSourceDeps $sourceDeps)
    $notebookSuperSourceNodes = @(New-NotebookSuperLineageSources -Item $Item)
    $sources = @(
        $sourceDeps |
            ForEach-Object {
                $candidateObjects = @(Get-CandidateObjectsForDependency -Dependency $_ -ModelObjects $objects)
                New-SourceNode -Dependency $_ -ItemByQualifiedName $itemByQualifiedName -ObjectRows $candidateObjects -MigrationRows $migrationRows
            }
        $manualSourceNodes
        $notebookSuperSourceNodes
    )

    $reports = @(
        $reportDeps |
            Where-Object { $itemByQualifiedName.ContainsKey($_.to_qualified_name) } |
            ForEach-Object {
                $reportItem = $itemByQualifiedName[$_.to_qualified_name]
                [pscustomobject]@{
                    label = $reportItem.item_name
                    item_type = $reportItem.item_type
                    workspace_name = $reportItem.workspace_name
                    qualified_name = $reportItem.qualified_name
                    confidence = $_.confidence
                    evidence = $_.evidence
                }
            }
    )

    $executes = @(
        $executeDeps |
            ForEach-Object {
                $target = $_.to_qualified_name
                $targetItem = if ($itemByQualifiedName.ContainsKey($target)) { $itemByQualifiedName[$target] } else { $null }
                $targetNotebookSources = if ($targetItem -and $targetItem.item_type -eq "Notebook") { @(New-NotebookSuperLineageSources -Item $targetItem) } else { @() }
                $invocationKey = "$($Item.qualified_name)|$target"
                $invocationActivities = if ($activitiesByPipelineAndTarget.ContainsKey($invocationKey)) { @($activitiesByPipelineAndTarget[$invocationKey].ToArray()) } else { @() }
                [pscustomobject]@{
                    label = if ($targetItem) { $targetItem.item_name } else { Get-ItemNameFromQualifiedName -QualifiedName $target }
                    item_type = if ($targetItem) { $targetItem.item_type } else { Get-ItemTypeFromQualifiedName -QualifiedName $target }
                    workspace_name = if ($targetItem) { $targetItem.workspace_name } else { Get-WorkspaceNameFromQualifiedName -QualifiedName $target }
                    qualified_name = $target
                    confidence = $_.confidence
                    evidence = $_.evidence
                    execution = if ($targetItem -and $executionsByQualifiedName.ContainsKey($target)) { New-ExecutionSummary -Rows @($executionsByQualifiedName[$target]) } else { $null }
                    sources = $targetNotebookSources
                    notebook_super_lineage = if ($targetItem) { Get-NotebookSuperLineageSummary -Item $targetItem } else { $null }
                    invocation_activities = $invocationActivities
                }
            }
    )

    $models = @(
        $modelDeps |
            Where-Object { $itemByQualifiedName.ContainsKey($_.to_qualified_name) } |
            ForEach-Object {
                $modelItem = $itemByQualifiedName[$_.to_qualified_name]
                $modelExecutionRows = @()
                if ($executionsByQualifiedName.ContainsKey($modelItem.qualified_name)) {
                    $modelExecutionRows = @($executionsByQualifiedName[$modelItem.qualified_name].ToArray())
                }
                $modelDepsForTarget = @()
                if ($dependenciesByFrom.ContainsKey($modelItem.qualified_name)) {
                    $modelDepsForTarget = @($dependenciesByFrom[$modelItem.qualified_name].ToArray())
                }
                $modelSourceDeps = @($modelDepsForTarget | Where-Object { $_.relationship_type -eq "depends_on" })
                $modelObjects = @()
                if ($objectsByModel.ContainsKey($modelItem.qualified_name)) {
                    $modelObjects = @($objectsByModel[$modelItem.qualified_name].ToArray())
                }
                $modelSources = @(
                    $modelSourceDeps |
                        ForEach-Object {
                            $candidateObjects = @(Get-CandidateObjectsForDependency -Dependency $_ -ModelObjects $modelObjects)
                            New-SourceNode -Dependency $_ -ItemByQualifiedName $itemByQualifiedName -ObjectRows $candidateObjects -MigrationRows $migrationRows
                        }
                )
                [pscustomobject]@{
                    label = $modelItem.item_name
                    item_type = $modelItem.item_type
                    workspace_name = $modelItem.workspace_name
                    environment = $modelItem.workspace_environment
                    qualified_name = $modelItem.qualified_name
                    description = $modelItem.description
                    sensitivity_label = $modelItem.sensitivity_label
                    technical_id = $modelItem.technical_id
                    analysis = if ($analysisByQualifiedName.ContainsKey($modelItem.qualified_name)) {
                        [pscustomobject]@{
                            status = $analysisByQualifiedName[$modelItem.qualified_name].analysis_status
                            notes = $analysisByQualifiedName[$modelItem.qualified_name].notes
                            evidence = $analysisByQualifiedName[$modelItem.qualified_name].evidence
                        }
                    } else { $null }
                    confidence = $_.confidence
                    evidence = $_.evidence
                    execution = New-ExecutionSummary -Rows $modelExecutionRows
                    planning = Get-PlanningInfo -Item $modelItem
                    reports = @()
                    models = @()
                    sources = $modelSources
                    executes = @()
                    dependency_count = $modelDepsForTarget.Count
                }
            }
    )

    return [pscustomobject]@{
        label = $Item.item_name
        item_type = $Item.item_type
        workspace_name = $Item.workspace_name
        environment = $Item.workspace_environment
        qualified_name = $Item.qualified_name
        description = $Item.description
        sensitivity_label = $Item.sensitivity_label
        technical_id = $Item.technical_id
        analysis = if ($analysis) {
            [pscustomobject]@{
                status = $analysis.analysis_status
                notes = $analysis.notes
                evidence = $analysis.evidence
            }
        } else { $null }
        execution = New-ExecutionSummary -Rows $executionRows
        planning = Get-PlanningInfo -Item $Item
        reports = $reports
        models = $models
        sources = $sources
        executes = $executes
        dependency_count = $deps.Count
        notebook_super_lineage = Get-NotebookSuperLineageSummary -Item $Item
    }
}

$workspacePayloads = [System.Collections.Generic.List[object]]::new()
$gaps = [System.Collections.Generic.List[object]]::new()

foreach ($workspace in ($workspaces | Sort-Object workspace_name)) {
    $workspaceItems = @($items | Where-Object { $_.workspace_name -eq $workspace.workspace_name })
    $semanticItems = @($workspaceItems | Where-Object { $_.item_type -eq "SemanticModel" } | Sort-Object item_name)
    $notebookItems = @($workspaceItems | Where-Object { $_.item_type -eq "Notebook" } | Sort-Object item_name)
    $copyJobItems = @($workspaceItems | Where-Object { $_.item_type -eq "CopyJob" } | Sort-Object item_name)
    $pipelineItems = @($workspaceItems | Where-Object { $_.item_type -eq "DataPipeline" } | Sort-Object item_name)
    $allItems = @($workspaceItems | Sort-Object item_type, item_name)
    if ($allItems.Count -eq 0) { continue }
    $deploymentStage = if ($deploymentStageByWorkspaceName.ContainsKey($workspace.workspace_name)) { $deploymentStageByWorkspaceName[$workspace.workspace_name] } else { $null }

    $workspacePayloads.Add([pscustomobject]@{
        name = $workspace.workspace_name
        normalized_name = $workspace.normalized_workspace_name
        environment = $workspace.environment
        workspace_type = $workspace.workspace_type
        capacity_name = $workspace.capacity_name
        capacity_id = $workspace.capacity_id
        domain_name = $workspace.domain_name
        owner = $workspace.owner
        admin_principals = $workspace.admin_principals
        description = $workspace.description
        deployment_pipeline = if ($deploymentStage) {
            [pscustomobject]@{
                has_pipeline = $true
                deployment_pipeline_id = $deploymentStage.deployment_pipeline_id
                deployment_pipeline_name = $deploymentStage.deployment_pipeline_name
                deployment_pipeline_description = $deploymentStage.deployment_pipeline_description
                stage_id = $deploymentStage.stage_id
                stage_order = $deploymentStage.stage_order
                stage_name = $deploymentStage.stage_name
                stage_description = $deploymentStage.stage_description
                stage_workspace_id = $deploymentStage.stage_workspace_id
                stage_workspace_name = $deploymentStage.stage_workspace_name
                is_public = $deploymentStage.is_public
                status = $deploymentStage.status
                evidence = $deploymentStage.evidence
            }
        } else {
            [pscustomobject]@{
                has_pipeline = $false
                deployment_pipeline_id = ""
                deployment_pipeline_name = ""
                deployment_pipeline_description = ""
                stage_id = ""
                stage_order = ""
                stage_name = ""
                stage_description = ""
                stage_workspace_id = ""
                stage_workspace_name = ""
                is_public = ""
                status = ""
                evidence = ""
            }
        }
        counts = [pscustomobject]@{
            semantic = $semanticItems.Count
            notebooks = $notebookItems.Count
            copyjobs = $copyJobItems.Count
            pipelines = $pipelineItems.Count
            all = $allItems.Count
        }
        semantic = @($semanticItems | ForEach-Object { New-ItemNode -Item $_ })
        notebooks = @($notebookItems | ForEach-Object { New-ItemNode -Item $_ })
        copyjobs = @($copyJobItems | ForEach-Object { New-ItemNode -Item $_ })
        pipelines = @($pipelineItems | ForEach-Object { New-ItemNode -Item $_ })
        all = @($allItems | ForEach-Object { New-ItemNode -Item $_ })
    }) | Out-Null
}

if ($columnCatalogByFullKey.Count -gt 0) {
    foreach ($workspacePayload in $workspacePayloads) {
        foreach ($mode in @("semantic", "notebooks", "copyjobs", "pipelines", "all")) {
            foreach ($itemNode in @($workspacePayload.$mode)) {
                Add-ColumnsToSourceObjects -Sources $itemNode.sources
                foreach ($modelNode in @($itemNode.models)) {
                    Add-ColumnsToSourceObjects -Sources $modelNode.sources
                }
                foreach ($executeNode in @($itemNode.executes)) {
                    Add-ColumnsToSourceObjects -Sources $executeNode.sources
                }
            }
        }
    }
}

$sourceTypes = @(
    $workspacePayloads |
        ForEach-Object { @($_.semantic + $_.notebooks + $_.copyjobs + $_.pipelines + $_.all) } |
        ForEach-Object { $_.sources } |
        ForEach-Object { $_.source_type } |
        Where-Object { $_ } |
        Sort-Object -Unique
)

$semanticModelCount = (@($items | Where-Object { $_.item_type -eq "SemanticModel" })).Count
$reportCount = (@($items | Where-Object { $_.item_type -eq "Report" })).Count
$notebookCount = (@($items | Where-Object { $_.item_type -eq "Notebook" })).Count
$copyJobCount = (@($items | Where-Object { $_.item_type -eq "CopyJob" })).Count
$pipelineCount = (@($items | Where-Object { $_.item_type -eq "DataPipeline" })).Count
$manualLineageItemCount = (@($manualObjectEvidenceRows | Select-Object -ExpandProperty item_qualified_name -Unique)).Count
$itemObjectCandidateItemCount = (@($itemObjectCandidateRows | Select-Object -ExpandProperty item_qualified_name -Unique)).Count
$itemTypes = @($items | Select-Object -ExpandProperty item_type -Unique | Sort-Object)
$allItemCount = (@($items)).Count
$criticalCount = (@($criticalRows)).Count
$failureCount = (@($failureRows)).Count
$scheduleReviewCount = (@($scheduleReviewRows)).Count
$orchestrationGroupCount = (@($orchestrationGroupRows)).Count
$parallelCount = (@($parallelRows)).Count
$manualEvidenceCount = (@($manualObjectEvidenceRows)).Count
$itemObjectCandidateCount = (@($itemObjectCandidateRows)).Count
$allObjectNodes = @(
    $objectsByModel.Values |
        ForEach-Object { @($_.ToArray()) }
)
$exactObjectTypeCount = @($allObjectNodes | Where-Object { Test-ExactObjectType $_.type }).Count
$unresolvedTableOrViewCount = @($allObjectNodes | Where-Object { $_.type -eq "table_or_view" }).Count
$nativeQueryObjectCount = @($allObjectNodes | Where-Object { $_.type -eq "native_query_object" }).Count

$deploymentPipelinePayloads = [System.Collections.Generic.List[object]]::new()
foreach ($pipeline in ($deploymentPipelineRows | Sort-Object deployment_pipeline_name)) {
    $pipelineId = Get-FieldValue -Object $pipeline -Names @("deployment_pipeline_id")
    $pipelineStages = @(
        $deploymentPipelineStageRows |
            Where-Object { $_.deployment_pipeline_id -eq $pipelineId } |
            Sort-Object { if ($_.stage_order -match "^-?\d+$") { [int]$_.stage_order } else { 999 } }
    )
    if ($pipelineStages.Count -eq 0) { continue }
    $stagePayloads = [System.Collections.Generic.List[object]]::new()
    foreach ($stage in $pipelineStages) {
        $workspaceId = Get-FieldValue -Object $stage -Names @("workspace_id")
        $workspaceName = Get-FieldValue -Object $stage -Names @("workspace_name")
        $localWorkspaceName = ""
        if ($workspaceId -and $workspaceById.ContainsKey((Normalize-Key $workspaceId))) {
            $localWorkspaceName = Get-FieldValue -Object $workspaceById[(Normalize-Key $workspaceId)] -Names @("workspace_name")
        }
        elseif ($workspaceName -and $workspaceByName.ContainsKey((Normalize-Key $workspaceName))) {
            $localWorkspaceName = Get-FieldValue -Object $workspaceByName[(Normalize-Key $workspaceName)] -Names @("workspace_name")
        }
        $stagePayloads.Add([pscustomobject]@{
            stage_id = Get-FieldValue -Object $stage -Names @("stage_id")
            stage_order = Get-FieldValue -Object $stage -Names @("stage_order")
            stage_name = Get-FieldValue -Object $stage -Names @("stage_name")
            stage_description = Get-FieldValue -Object $stage -Names @("stage_description")
            workspace_id = $workspaceId
            workspace_name = $workspaceName
            local_workspace_name = $localWorkspaceName
            is_public = Get-FieldValue -Object $stage -Names @("is_public")
            status = Get-FieldValue -Object $stage -Names @("status")
            evidence = Get-FieldValue -Object $stage -Names @("evidence")
        }) | Out-Null
    }
    $indexedWorkspaceNames = @($stagePayloads.ToArray() | Select-Object -ExpandProperty local_workspace_name -Unique | Where-Object { $_ })
    $group = @($deploymentPipelineGroupRows | Where-Object { $_.deployment_pipeline_id -eq $pipelineId } | Select-Object -First 1)
    $deploymentPipelinePayloads.Add([pscustomobject]@{
        deployment_pipeline_id = $pipelineId
        deployment_pipeline_name = Get-FieldValue -Object $pipeline -Names @("deployment_pipeline_name")
        description = Get-FieldValue -Object $pipeline -Names @("description")
        stage_count = $pipelineStages.Count
        assigned_stage_count = @($pipelineStages | Where-Object { $_.workspace_id -or $_.workspace_name }).Count
        indexed_workspace_count = $indexedWorkspaceNames.Count
        workspace_names = $indexedWorkspaceNames
        status = if ($group.Count -gt 0) { Get-FieldValue -Object $group[0] -Names @("status") } else { "" }
        evidence = if ($group.Count -gt 0) { Get-FieldValue -Object $group[0] -Names @("evidence") } else { "Fabric deployment pipeline stage metadata." }
        stages = @($stagePayloads.ToArray())
    }) | Out-Null
}

$payload = [pscustomobject]@{
    generated_at = (Get-Date).ToString("s")
    summary = [pscustomobject]@{
        workspaces = $workspacePayloads.Count
        semantic_models = $semanticModelCount
        reports = $reportCount
        notebooks = $notebookCount
        copyjobs = $copyJobCount
        pipelines = $pipelineCount
        all_items = $allItemCount
        item_types = $itemTypes
        critical_path_candidates = $criticalCount
        failure_hotspots = $failureCount
        schedule_review_candidates = $scheduleReviewCount
        orchestration_group_candidates = $orchestrationGroupCount
        parallelism_candidates = $parallelCount
        manual_lineage_evidence_rows = $manualEvidenceCount
        manual_lineage_items = $manualLineageItemCount
        item_object_lineage_candidate_rows = $itemObjectCandidateCount
        item_object_lineage_candidate_items = $itemObjectCandidateItemCount
        pipeline_object_lineage_candidate_rows = @($pipelineObjectCandidateRows).Count
        pipeline_object_lineage_candidate_items = @($pipelineObjectCandidateRows | Select-Object -ExpandProperty item_qualified_name -Unique).Count
        object_type_override_rows = @($objectTypeOverrideRows).Count
        object_type_metadata_evidence_rows = @($objectTypeMetadataEvidenceRows).Count
        sql_endpoint_catalog_rows = @($sqlEndpointCatalogRows).Count
        exact_object_type_nodes = $exactObjectTypeCount
        unresolved_table_or_view_nodes = $unresolvedTableOrViewCount
        native_query_object_nodes = $nativeQueryObjectCount
        deployment_pipelines = $deploymentPipelinePayloads.Count
        deployment_pipeline_stage_workspaces = @($workspacePayloads | Where-Object { $_.deployment_pipeline.has_pipeline }).Count
    }
    modes = @("semantic", "notebooks", "copyjobs", "pipelines", "all")
    filters = [pscustomobject]@{
        source_types = $sourceTypes
        confidence = @("confirmed", "likely", "unknown")
    }
    refresh = Get-RefreshMetadata
    deployment_pipelines = @($deploymentPipelinePayloads.ToArray())
    # Real Succeeded/Failed/Completed item-to-item execution order, resolved
    # from pipeline activity dependsOn chains. Used by the Planning view to
    # color arrows the same way a Fabric pipeline canvas would, instead of
    # only inferring order from read/write table overlap.
    pipeline_activity_dependency_edges = @($pipelineActivityDependencyEdges.ToArray())
    workspaces = $workspacePayloads
}

Write-JsonAtomic -Path $OutputJsonPath -JsonText ($payload | ConvertTo-Json -Depth 30)

Ensure-ParentDirectory -Path $GapPath
$gaps | Export-Csv -Path $GapPath -NoTypeInformation -Encoding UTF8

Write-Host "Lineage explorer data built."
Write-Host "Workspaces: $($workspacePayloads.Count)"
Write-Host "Output: $OutputJsonPath"
