# Phase 16 - Deployment pipeline discovery: lists every Fabric deployment
# pipeline, its stages, and (with -IncludeStageItems) which items sit in
# each stage, then groups workspaces by shared pipeline membership.
# Read-only.
# Writes: $OutputPipelinePath/$OutputStagePath/$OutputStageItemPath,
# $OutputGroupPath, $OutputGapPath.
param(
    [string]$WorkspaceIndexPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$OutputPipelinePath = (Join-Path $PSScriptRoot "../../index/deployment_pipelines.csv"),
    [string]$OutputStagePath = (Join-Path $PSScriptRoot "../../index/deployment_pipeline_stages.csv"),
    [string]$OutputStageItemPath = (Join-Path $PSScriptRoot "../../index/deployment_pipeline_stage_items.csv"),
    [string]$OutputGroupPath = (Join-Path $PSScriptRoot "../../analysis/deployment_pipeline_workspace_groups.csv"),
    [string]$OutputGapPath = (Join-Path $PSScriptRoot "../../analysis/deployment_pipeline_discovery_gaps.csv"),
    [string]$AzCommand = "az",
    [string]$FabricApiBaseUrl = "https://api.fabric.microsoft.com/v1",
    [int]$RetryCount = 5,
    [int]$RequestDelayMilliseconds = 300,
    [switch]$IncludeStageItems
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$pipelineColumns = @(
    "deployment_pipeline_id",
    "deployment_pipeline_name",
    "description",
    "source_system",
    "status",
    "evidence",
    "notes"
)

$stageColumns = @(
    "deployment_pipeline_id",
    "deployment_pipeline_name",
    "stage_id",
    "stage_order",
    "stage_name",
    "stage_description",
    "workspace_id",
    "workspace_name",
    "is_public",
    "source_system",
    "status",
    "evidence",
    "notes"
)

$stageItemColumns = @(
    "deployment_pipeline_id",
    "deployment_pipeline_name",
    "stage_id",
    "stage_order",
    "stage_name",
    "workspace_id",
    "workspace_name",
    "item_id",
    "item_name",
    "item_type",
    "last_deployment_time",
    "source_item_id",
    "target_item_id",
    "source_system",
    "status",
    "evidence",
    "notes"
)

$groupColumns = @(
    "deployment_pipeline_id",
    "deployment_pipeline_name",
    "description",
    "stage_count",
    "assigned_stage_count",
    "indexed_workspace_count",
    "stage_summary",
    "workspace_names",
    "status",
    "evidence",
    "notes"
)

$gapColumns = @(
    "scope",
    "deployment_pipeline_id",
    "deployment_pipeline_name",
    "stage_id",
    "stage_name",
    "status_code",
    "error",
    "api_path",
    "notes"
)

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

function Invoke-FabricGet {
    param(
        [string]$Path,
        [hashtable]$Headers
    )

    $uri = if ($Path.StartsWith("http")) {
        $Path
    }
    else {
        "$($FabricApiBaseUrl.TrimEnd('/'))/$($Path.TrimStart('/'))"
    }

    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        try {
            $payload = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers
            if ($RequestDelayMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $RequestDelayMilliseconds
            }
            return [pscustomobject]@{
                succeeded = $true
                status_code = 200
                payload = $payload
                error = ""
                uri = $uri
            }
        }
        catch {
            $statusCode = ""
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($statusCode -eq 429 -and $attempt -lt $RetryCount) {
                $delaySeconds = [math]::Min(90, [math]::Pow(2, $attempt + 1))
                Start-Sleep -Seconds $delaySeconds
                continue
            }

            return [pscustomobject]@{
                succeeded = $false
                status_code = $statusCode
                payload = $null
                error = $_.Exception.Message
                uri = $uri
            }
        }
    }
}

function Get-PagedFabricValues {
    param(
        [string]$Path,
        [hashtable]$Headers,
        [string]$ValueProperty = "value"
    )

    $values = @()
    $nextPath = $Path
    while ($nextPath) {
        $result = Invoke-FabricGet -Path $nextPath -Headers $Headers
        if (-not $result.succeeded) {
            return [pscustomobject]@{
                succeeded = $false
                values = @()
                error = $result.error
                status_code = $result.status_code
                uri = $result.uri
            }
        }

        if ($result.payload.PSObject.Properties.Name -contains $ValueProperty) {
            $values += @($result.payload.$ValueProperty)
        }

        if ($result.payload.PSObject.Properties.Name -contains "continuationUri" -and $result.payload.continuationUri) {
            $nextPath = [string]$result.payload.continuationUri
        }
        else {
            $nextPath = ""
        }
    }

    return [pscustomobject]@{
        succeeded = $true
        values = $values
        error = ""
        status_code = 200
        uri = "$($FabricApiBaseUrl.TrimEnd('/'))/$($Path.TrimStart('/'))"
    }
}

$workspaceById = @{}
$workspaceByName = @{}
if (Test-Path $WorkspaceIndexPath) {
    foreach ($workspace in @(Import-Csv -Path $WorkspaceIndexPath)) {
        $workspaceId = Get-FieldValue -Object $workspace -Names @("technical_id", "workspace_id")
        $workspaceName = Get-FieldValue -Object $workspace -Names @("workspace_name")
        if ($workspaceId -and -not $workspaceById.ContainsKey((Normalize-Key $workspaceId))) {
            $workspaceById[(Normalize-Key $workspaceId)] = $workspace
        }
        if ($workspaceName -and -not $workspaceByName.ContainsKey((Normalize-Key $workspaceName))) {
            $workspaceByName[(Normalize-Key $workspaceName)] = $workspace
        }
    }
}

$token = Get-FreshAzureCliToken -Resource "https://api.fabric.microsoft.com" -AzCommand $AzCommand
$headers = @{
    Authorization = "Bearer $token"
    "Content-Type" = "application/json"
}

$pipelineRows = [System.Collections.Generic.List[object]]::new()
$stageRows = [System.Collections.Generic.List[object]]::new()
$stageItemRows = [System.Collections.Generic.List[object]]::new()
$gapRows = [System.Collections.Generic.List[object]]::new()

$pipelineResult = Get-PagedFabricValues -Path "deploymentPipelines" -Headers $headers
if (-not $pipelineResult.succeeded) {
    $gapRows.Add([pscustomobject]@{
        scope = "deployment_pipelines"
        deployment_pipeline_id = ""
        deployment_pipeline_name = ""
        stage_id = ""
        stage_name = ""
        status_code = $pipelineResult.status_code
        error = $pipelineResult.error
        api_path = $pipelineResult.uri
        notes = "Could not list deployment pipelines."
    }) | Out-Null
    # Deliberately does NOT overwrite index/deployment_pipelines.csv (or the
    # stage/stage-item/group files) with an empty result here -- a listing
    # call that failed outright (transient error, or this run's identity
    # simply can't see any pipelines) has nothing real to replace previously
    # good data with. Only the gap file, which records the failure itself,
    # gets written. This exact unconditional-wipe
    # pattern (here AND at the normal-completion write below, now fixed
    # with a retain-by-id merge instead) is what silently destroyed real
    # deployment pipeline data down to 2 rows during a user-scoped scan
    # whose own regular-API access to /deploymentPipelines was narrower
    # than the shared session's had been.
    Export-Rows -Rows @($gapRows.ToArray()) -Columns $gapColumns -Path $OutputGapPath
    throw "Deployment pipeline discovery failed: $($pipelineResult.status_code) $($pipelineResult.error)"
}

foreach ($pipeline in @($pipelineResult.values | Sort-Object displayName)) {
    $pipelineId = Get-FieldValue -Object $pipeline -Names @("id")
    $pipelineName = Get-FieldValue -Object $pipeline -Names @("displayName", "name")
    $description = Get-FieldValue -Object $pipeline -Names @("description")

    $pipelineRows.Add([pscustomobject]@{
        deployment_pipeline_id = $pipelineId
        deployment_pipeline_name = $pipelineName
        description = $description
        source_system = "Fabric REST API via Azure CLI"
        status = "discovered"
        evidence = "GET /v1/deploymentPipelines"
        notes = "Read-only deployment pipeline metadata."
    }) | Out-Null

    $stagePath = "deploymentPipelines/$pipelineId/stages"
    $stageResult = Get-PagedFabricValues -Path $stagePath -Headers $headers
    if (-not $stageResult.succeeded) {
        $gapRows.Add([pscustomobject]@{
            scope = "deployment_pipeline_stages"
            deployment_pipeline_id = $pipelineId
            deployment_pipeline_name = $pipelineName
            stage_id = ""
            stage_name = ""
            status_code = $stageResult.status_code
            error = $stageResult.error
            api_path = $stageResult.uri
            notes = "Could not list stages for deployment pipeline."
        }) | Out-Null
        continue
    }

    foreach ($stage in @($stageResult.values | Sort-Object order)) {
        $stageId = Get-FieldValue -Object $stage -Names @("id")
        $stageOrder = Get-FieldValue -Object $stage -Names @("order")
        $stageName = Get-FieldValue -Object $stage -Names @("displayName", "name")
        $stageDescription = Get-FieldValue -Object $stage -Names @("description")
        $workspaceId = Get-FieldValue -Object $stage -Names @("workspaceId")
        $workspaceName = Get-FieldValue -Object $stage -Names @("workspaceName")
        $isPublic = Get-FieldValue -Object $stage -Names @("isPublic")
        $matchedWorkspace = $false
        if ($workspaceId -and $workspaceById.ContainsKey((Normalize-Key $workspaceId))) { $matchedWorkspace = $true }
        if (-not $matchedWorkspace -and $workspaceName -and $workspaceByName.ContainsKey((Normalize-Key $workspaceName))) { $matchedWorkspace = $true }

        $stageRows.Add([pscustomobject]@{
            deployment_pipeline_id = $pipelineId
            deployment_pipeline_name = $pipelineName
            stage_id = $stageId
            stage_order = $stageOrder
            stage_name = $stageName
            stage_description = $stageDescription
            workspace_id = $workspaceId
            workspace_name = $workspaceName
            is_public = $isPublic
            source_system = "Fabric REST API via Azure CLI"
            status = if ($workspaceId -or $workspaceName) { "assigned" } else { "unassigned" }
            evidence = "GET /v1/deploymentPipelines/$pipelineId/stages"
            notes = if ($matchedWorkspace) { "Assigned workspace matched local workspace index." } elseif ($workspaceId -or $workspaceName) { "Assigned workspace was returned by pipeline API but is not in local workspace index." } else { "Stage has no assigned workspace." }
        }) | Out-Null

        if ($IncludeStageItems -and $stageId -and ($workspaceId -or $workspaceName)) {
            $stageItemPath = "deploymentPipelines/$pipelineId/stages/$stageId/items"
            $stageItemResult = Get-PagedFabricValues -Path $stageItemPath -Headers $headers
            if (-not $stageItemResult.succeeded) {
                $gapRows.Add([pscustomobject]@{
                    scope = "deployment_pipeline_stage_items"
                    deployment_pipeline_id = $pipelineId
                    deployment_pipeline_name = $pipelineName
                    stage_id = $stageId
                    stage_name = $stageName
                    status_code = $stageItemResult.status_code
                    error = $stageItemResult.error
                    api_path = $stageItemResult.uri
                    notes = "Could not list stage items. This can require contributor access to the assigned stage workspace."
                }) | Out-Null
                continue
            }

            foreach ($item in @($stageItemResult.values | Sort-Object itemType, itemDisplayName)) {
                $stageItemRows.Add([pscustomobject]@{
                    deployment_pipeline_id = $pipelineId
                    deployment_pipeline_name = $pipelineName
                    stage_id = $stageId
                    stage_order = $stageOrder
                    stage_name = $stageName
                    workspace_id = $workspaceId
                    workspace_name = $workspaceName
                    item_id = Get-FieldValue -Object $item -Names @("itemId", "id")
                    item_name = Get-FieldValue -Object $item -Names @("itemDisplayName", "displayName", "name")
                    item_type = Get-FieldValue -Object $item -Names @("itemType", "type")
                    last_deployment_time = Get-FieldValue -Object $item -Names @("lastDeploymentTime")
                    source_item_id = Get-FieldValue -Object $item -Names @("sourceItemId")
                    target_item_id = Get-FieldValue -Object $item -Names @("targetItemId")
                    source_system = "Fabric REST API via Azure CLI"
                    status = "discovered"
                    evidence = "GET /v1/deploymentPipelines/$pipelineId/stages/$stageId/items"
                    notes = "Read-only deployment pipeline stage item metadata."
                }) | Out-Null
            }
        }
    }
}

$groupRows = [System.Collections.Generic.List[object]]::new()
foreach ($pipelineGroup in @($stageRows.ToArray() | Group-Object deployment_pipeline_id)) {
    $stages = @($pipelineGroup.Group | Sort-Object { if ($_.stage_order -match "^-?\d+$") { [int]$_.stage_order } else { 999 } })
    $first = $stages[0]
    $assignedStages = @($stages | Where-Object { $_.workspace_id -or $_.workspace_name })
    $indexedStages = @(
        $assignedStages |
            Where-Object {
                ($_.workspace_id -and $workspaceById.ContainsKey((Normalize-Key $_.workspace_id))) -or
                ($_.workspace_name -and $workspaceByName.ContainsKey((Normalize-Key $_.workspace_name)))
            }
    )
    $workspaceNames = @(
        $indexedStages |
            ForEach-Object {
                if ($_.workspace_id -and $workspaceById.ContainsKey((Normalize-Key $_.workspace_id))) {
                    Get-FieldValue -Object $workspaceById[(Normalize-Key $_.workspace_id)] -Names @("workspace_name")
                }
                elseif ($_.workspace_name) { $_.workspace_name }
            } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )
    $stageSummary = @(
        $stages |
            ForEach-Object {
                $stageLabel = if ($_.stage_name) { $_.stage_name } else { "Stage $($_.stage_order)" }
                $workspaceLabel = if ($_.workspace_name) { $_.workspace_name } elseif ($_.workspace_id) { $_.workspace_id } else { "unassigned" }
                "$stageLabel=$workspaceLabel"
            }
    ) -join "; "

    $groupRows.Add([pscustomobject]@{
        deployment_pipeline_id = $first.deployment_pipeline_id
        deployment_pipeline_name = $first.deployment_pipeline_name
        description = (@($pipelineRows.ToArray() | Where-Object { $_.deployment_pipeline_id -eq $first.deployment_pipeline_id } | Select-Object -First 1).description)
        stage_count = $stages.Count
        assigned_stage_count = $assignedStages.Count
        indexed_workspace_count = $workspaceNames.Count
        stage_summary = $stageSummary
        workspace_names = ($workspaceNames -join "; ")
        status = if ($workspaceNames.Count -gt 0) { "matched_to_workspace_index" } else { "no_indexed_workspaces" }
        evidence = "Derived from deployment pipeline stage metadata and local workspace index."
        notes = if ($workspaceNames.Count -gt 0) { "Use this group to collapse DEV/QA/PRO stage workspaces in the explorer." } else { "Pipeline has no assigned stage workspace present in local workspace index." }
    }) | Out-Null
}

# GET /v1/deploymentPipelines is a regular (non-admin) endpoint -- it only
# ever returns pipelines the CALLING identity personally has access to. A
# signed-in web app user's own token (FABRIC_LINEAGE_USER_TOKEN) can see a
# genuinely different, unpredictable subset of pipelines than the shared
# `az` session used to -- a tenant admin's own scan could silently reduce
# deployment_pipelines.csv from a larger set down to just a couple of rows
# this way.
#
# The fix is deliberately NOT a retain-if-not-rediscovered merge (tried
# and reverted): merging would have kept a genuinely deleted pipeline
# alive forever, since nothing about a narrower run ever re-confirms a
# deletion either -- exactly the failure mode the user flagged live. There
# is also no admin-scoped equivalent of this endpoint wired up yet (Power
# BI's admin/pipelines lives on a different host, api.powerbi.com, not
# api.fabric.microsoft.com -- a real change, not attempted here without a
# live admin session to verify it against).
#
# So instead: only write these 4 files at all when this run's result is
# actually AUTHORITATIVE -- the shared `az` session (no per-user token, the
# historical default) or a signed-in user FABRIC_LINEAGE_USER_IS_ADMIN
# already confirmed is a real Fabric tenant admin (set by
# lineage_web_server.py right before spawning this process, from a fresh
# per-scan admin check, not just a cached sign-in-time guess). A signed-in
# non-admin user's narrower, genuinely-partial view is not trustworthy
# either way -- neither to overwrite (destroys real coverage) nor to merge
# (masks real deletions) -- so it's simply left untouched, exactly as it
# was before this step ran.
$isAuthoritativeSource = (-not $env:FABRIC_LINEAGE_USER_TOKEN) -or ($env:FABRIC_LINEAGE_USER_IS_ADMIN -eq "true")
if ($isAuthoritativeSource) {
    Export-Rows -Rows @($pipelineRows.ToArray()) -Columns $pipelineColumns -Path $OutputPipelinePath
    Export-Rows -Rows @($stageRows.ToArray()) -Columns $stageColumns -Path $OutputStagePath
    Export-Rows -Rows @($stageItemRows.ToArray()) -Columns $stageItemColumns -Path $OutputStageItemPath
    Export-Rows -Rows @($groupRows.ToArray()) -Columns $groupColumns -Path $OutputGroupPath
}
else {
    Write-Host "Signed-in non-admin scope: this identity's own deployment pipeline visibility is not authoritative -- left index/deployment_pipelines.csv (and stages/stage-items/groups) untouched rather than overwrite or merge it."
}
Export-Rows -Rows @($gapRows.ToArray()) -Columns $gapColumns -Path $OutputGapPath

Write-Host "Deployment pipeline discovery completed."
Write-Host "Deployment pipelines: $($pipelineRows.Count)"
Write-Host "Stages: $($stageRows.Count)"
Write-Host "Workspace groups matched: $(@($groupRows.ToArray() | Where-Object { $_.status -eq 'matched_to_workspace_index' }).Count)"
Write-Host "Stage items: $($stageItemRows.Count)"
Write-Host "Gaps: $($gapRows.Count)"
Write-Host "Output: $OutputPipelinePath"
