# Phase 37 - Workspace governance/DevOps enrichment: derives per-workspace
# governance facts (admin/member principals, deployment pipeline
# membership) and candidate links to Azure DevOps repos (via
# -UseReadOnlyApis to also query workspace Git-connection status live).
# Writes: $OutputGovernancePath, $OutputPrincipalPath, $OutputDeploymentPath,
# $OutputDevOpsPath, $OutputGapPath, $OutputJsonPath, $DocPath.
param(
    [string]$WorkspacesPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$DeploymentPipelinesPath = (Join-Path $PSScriptRoot "../../index/deployment_pipelines.csv"),
    [string]$DeploymentPipelineStagesPath = (Join-Path $PSScriptRoot "../../index/deployment_pipeline_stages.csv"),
    [string]$LineageModelPath = (Join-Path $PSScriptRoot "../../archive/lineage-explorer/data/lineage-explorer.json"),
    [string]$OutputGovernancePath = (Join-Path $PSScriptRoot "../../analysis/workspace_governance_enrichment.csv"),
    [string]$OutputPrincipalPath = (Join-Path $PSScriptRoot "../../analysis/workspace_governance_principals.csv"),
    [string]$OutputDeploymentPath = (Join-Path $PSScriptRoot "../../analysis/workspace_deployment_pipeline_membership.csv"),
    [string]$OutputDevOpsPath = (Join-Path $PSScriptRoot "../../analysis/workspace_devops_link_candidates.csv"),
    [string]$OutputGapPath = (Join-Path $PSScriptRoot "../../analysis/workspace_governance_devops_gaps.csv"),
    [string]$OutputJsonPath = (Join-Path $PSScriptRoot "../../archive/lineage-explorer/data/workspace-governance.json"),
    [string]$DocPath = (Join-Path $PSScriptRoot "../../docs/13_workspace_governance_devops_enrichment.md"),
    [string]$AzCommand = "az",
    [switch]$UseReadOnlyApis
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
    foreach ($name in @($Names)) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property) {
            $value = $property.Value
            if ($null -ne $value) { return [string]$value }
        }
    }
    return ""
}

function Normalize-Key {
    param([string]$Value)
    if (-not $Value) { return "" }
    return (($Value.ToLowerInvariant() -replace "\s+", " ").Trim())
}

function Split-PrincipalText {
    param([string]$Value)
    if (-not $Value) { return @() }
    return @($Value -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Convert-Principal {
    param([string]$Principal)
    $name = $Principal
    $email = ""
    $type = "user_or_unknown"

    if ($Principal -match "^(.*?)\s*<([^>]+)>") {
        $name = $Matches[1].Trim()
        $email = $Matches[2].Trim()
        $type = "user"
    }
    elseif ($Principal -match "\((Group)\)") {
        $name = ($Principal -replace "\s*\(Group\)\s*", "").Trim()
        $type = "group"
    }
    elseif ($Principal -match "\((ServicePrincipal)\)") {
        $name = ($Principal -replace "\s*\(ServicePrincipal\)\s*", "").Trim()
        $type = "service_principal"
    }

    return [pscustomobject]@{
        name = $name
        email = $email
        principal_type = $type
        raw = $Principal
    }
}

function Add-Gap {
    param(
        [System.Collections.Generic.List[object]]$Gaps,
        [string]$GapId,
        [string]$Area,
        [string]$Severity,
        [string]$Scope,
        [int]$AffectedCount,
        [string]$Evidence,
        [string]$RecommendedAction
    )
    $Gaps.Add([pscustomobject]@{
        gap_id = $GapId
        phase = "Phase 11"
        area = $Area
        severity = $Severity
        scope = $Scope
        affected_count = $AffectedCount
        evidence = $Evidence
        recommended_action = $RecommendedAction
    }) | Out-Null
}

function Get-AzureCliTokenResult {
    param([string]$Resource)

    # A signed-in web-app user's own delegated token, if the process that
    # spawned this script set one (see FABRIC_LINEAGE_USER_TOKEN in
    # lineage_web_server.py) -- falls back to the shared `az` CLI session
    # below when run standalone from a terminal, exactly as before. Only
    # applies for the default Fabric resource -- a caller explicitly asking
    # for a different resource still goes through `az`.
    if ($env:FABRIC_LINEAGE_USER_TOKEN -and $Resource -eq "https://api.fabric.microsoft.com") {
        return [pscustomobject]@{
            succeeded = $true
            token = $env:FABRIC_LINEAGE_USER_TOKEN
            error = ""
        }
    }

    try {
        $azPath = (Get-Command $AzCommand -ErrorAction Stop).Source
    }
    catch {
        return [pscustomobject]@{
            succeeded = $false
            token = ""
            error = "Azure CLI command '$AzCommand' was not found."
        }
    }

    $tokenOutput = & $azPath account get-access-token --resource $Resource --query "accessToken" -o tsv --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [pscustomobject]@{
            succeeded = $false
            token = ""
            error = (($tokenOutput | Out-String) -replace "\s+", " ").Trim()
        }
    }

    $token = ($tokenOutput | Out-String).Trim()
    return [pscustomobject]@{
        succeeded = [bool]$token
        token = $token
        error = if ($token) { "" } else { "Azure CLI returned an empty token." }
    }
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

$workspaces = @(Import-OptionalCsv -Path $WorkspacesPath)
$items = @(Import-OptionalCsv -Path $ItemsPath | Where-Object { -not $_.status -or $_.status -eq "discovered" })
$pipelines = @(Import-OptionalCsv -Path $DeploymentPipelinesPath)
$stages = @(Import-OptionalCsv -Path $DeploymentPipelineStagesPath)
$gaps = [System.Collections.Generic.List[object]]::new()

$stagesByWorkspace = @{}
foreach ($stage in $stages) {
    $workspaceName = Get-FieldValue -Object $stage -Names @("workspace_name")
    if (-not $workspaceName) { continue }
    $key = Normalize-Key $workspaceName
    if (-not $stagesByWorkspace.ContainsKey($key)) {
        $stagesByWorkspace[$key] = [System.Collections.Generic.List[object]]::new()
    }
    $stagesByWorkspace[$key].Add($stage) | Out-Null
}

$itemsByWorkspace = @{}
foreach ($item in $items) {
    $workspaceName = Get-FieldValue -Object $item -Names @("workspace_name")
    if (-not $workspaceName) { continue }
    $key = Normalize-Key $workspaceName
    if (-not $itemsByWorkspace.ContainsKey($key)) {
        $itemsByWorkspace[$key] = [System.Collections.Generic.List[object]]::new()
    }
    $itemsByWorkspace[$key].Add($item) | Out-Null
}

$principalRows = [System.Collections.Generic.List[object]]::new()
$principalKeys = @{}

foreach ($workspace in $workspaces) {
    $workspaceName = Get-FieldValue -Object $workspace -Names @("workspace_name")
    foreach ($principalText in (Split-PrincipalText -Value (Get-FieldValue -Object $workspace -Names @("owner")))) {
        $principal = Convert-Principal -Principal $principalText
        $key = "$workspaceName|owner|$($principal.raw)"
        if ($principalKeys.ContainsKey($key)) { continue }
        $principalKeys[$key] = $true
        $principalRows.Add([pscustomobject]@{
            workspace_name = $workspaceName
            environment = Get-FieldValue -Object $workspace -Names @("environment")
            principal_name = $principal.name
            principal_email = $principal.email
            principal_type = $principal.principal_type
            role = "Owner"
            source_field = "owner"
            confidence = "local_index"
            evidence = "index/workspaces.csv owner field"
        }) | Out-Null
    }

    foreach ($principalText in (Split-PrincipalText -Value (Get-FieldValue -Object $workspace -Names @("admin_principals")))) {
        $principal = Convert-Principal -Principal $principalText
        $key = "$workspaceName|admin|$($principal.raw)"
        if ($principalKeys.ContainsKey($key)) { continue }
        $principalKeys[$key] = $true
        $principalRows.Add([pscustomobject]@{
            workspace_name = $workspaceName
            environment = Get-FieldValue -Object $workspace -Names @("environment")
            principal_name = $principal.name
            principal_email = $principal.email
            principal_type = $principal.principal_type
            role = "Admin"
            source_field = "admin_principals"
            confidence = "local_index"
            evidence = "index/workspaces.csv admin_principals field"
        }) | Out-Null
    }
}

$deploymentRows = [System.Collections.Generic.List[object]]::new()
foreach ($stage in $stages) {
    $deploymentRows.Add([pscustomobject]@{
        workspace_name = Get-FieldValue -Object $stage -Names @("workspace_name")
        deployment_pipeline_id = Get-FieldValue -Object $stage -Names @("deployment_pipeline_id")
        deployment_pipeline_name = Get-FieldValue -Object $stage -Names @("deployment_pipeline_name")
        stage_id = Get-FieldValue -Object $stage -Names @("stage_id")
        stage_order = Get-FieldValue -Object $stage -Names @("stage_order")
        stage_name = Get-FieldValue -Object $stage -Names @("stage_name")
        evidence = Get-FieldValue -Object $stage -Names @("evidence")
        status = Get-FieldValue -Object $stage -Names @("status")
    }) | Out-Null
}

$devOpsRows = [System.Collections.Generic.List[object]]::new()
$devOpsCandidateItemTypes = @("Notebook", "CopyJob", "DataPipeline", "Environment", "VariableLibrary")
foreach ($workspace in $workspaces) {
    $workspaceName = Get-FieldValue -Object $workspace -Names @("workspace_name")
    $workspaceKey = Normalize-Key $workspaceName
    $workspaceItems = if ($itemsByWorkspace.ContainsKey($workspaceKey)) { @($itemsByWorkspace[$workspaceKey].ToArray()) } else { @() }
    $technicalItems = @($workspaceItems | Where-Object { $_.item_type -in $devOpsCandidateItemTypes })
    if ($technicalItems.Count -eq 0) { continue }

    $normalized = Get-FieldValue -Object $workspace -Names @("normalized_workspace_name")
    $terms = @($workspaceName, $normalized) | Where-Object { $_ } | Select-Object -Unique
    foreach ($item in $technicalItems) {
        $itemName = Get-FieldValue -Object $item -Names @("item_name")
        $devOpsRows.Add([pscustomobject]@{
            workspace_name = $workspaceName
            environment = Get-FieldValue -Object $workspace -Names @("environment")
            item_type = Get-FieldValue -Object $item -Names @("item_type")
            item_name = $itemName
            item_qualified_name = Get-FieldValue -Object $item -Names @("qualified_name")
            candidate_search_terms = (($terms + $itemName) | Where-Object { $_ } | Select-Object -Unique) -join " | "
            candidate_status = "pending_azure_devops_search"
            confidence = "candidate"
            evidence = "Local item exists and may have source-controlled implementation; Azure DevOps org/project/repo evidence not available locally."
            recommended_action = "Search Azure DevOps read-only for matching project/repo/path before treating this as a confirmed source-code link."
        }) | Out-Null
    }
}

if ($UseReadOnlyApis) {
    $fabricToken = Get-AzureCliTokenResult -Resource "https://api.fabric.microsoft.com"
    if (-not $fabricToken.succeeded) {
        Add-Gap -Gaps $gaps -GapId "phase11_fabric_token_unavailable" -Area "read_only_api_access" -Severity "high" -Scope "fabric_api" -AffectedCount $workspaces.Count -Evidence $fabricToken.error -RecommendedAction "Human runs az login for your tenant, then reruns backend/scripts/37_build_workspace_governance_devops_enrichment.ps1 -UseReadOnlyApis."
    }
}

$governanceRows = [System.Collections.Generic.List[object]]::new()
foreach ($workspace in $workspaces) {
    $workspaceName = Get-FieldValue -Object $workspace -Names @("workspace_name")
    $workspaceKey = Normalize-Key $workspaceName
    $workspacePrincipals = @($principalRows.ToArray() | Where-Object { $_.workspace_name -eq $workspaceName })
    $workspaceStages = if ($stagesByWorkspace.ContainsKey($workspaceKey)) { @($stagesByWorkspace[$workspaceKey].ToArray()) } else { @() }
    $workspaceDevOps = @($devOpsRows.ToArray() | Where-Object { $_.workspace_name -eq $workspaceName })
    $workspaceItems = if ($itemsByWorkspace.ContainsKey($workspaceKey)) { @($itemsByWorkspace[$workspaceKey].ToArray()) } else { @() }
    $deploymentPipelineIds = @($workspaceStages | ForEach-Object { Get-FieldValue -Object $_ -Names @("deployment_pipeline_id") } | Where-Object { $_ } | Select-Object -Unique)
    $deploymentStageNames = @(
        $workspaceStages | ForEach-Object {
            $pipelineName = Get-FieldValue -Object $_ -Names @("deployment_pipeline_name")
            $stageName = Get-FieldValue -Object $_ -Names @("stage_name")
            "$pipelineName / $stageName".Trim(" /")
        } | Where-Object { $_ }
    )

    $userCount = @($workspacePrincipals | Where-Object { $_.principal_type -eq "user" } | Select-Object -ExpandProperty principal_email -Unique | Where-Object { $_ }).Count
    $groupCount = @($workspacePrincipals | Where-Object { $_.principal_type -eq "group" } | Select-Object -ExpandProperty principal_name -Unique | Where-Object { $_ }).Count
    $servicePrincipalCount = @($workspacePrincipals | Where-Object { $_.principal_type -eq "service_principal" } | Select-Object -ExpandProperty principal_name -Unique | Where-Object { $_ }).Count

    $gapFlags = [System.Collections.Generic.List[string]]::new()
    if ((Get-FieldValue -Object $workspace -Names @("capacity_id")) -and -not (Get-FieldValue -Object $workspace -Names @("capacity_name"))) { $gapFlags.Add("capacity_name_missing") | Out-Null }
    if (-not (Get-FieldValue -Object $workspace -Names @("domain_name"))) { $gapFlags.Add("domain_missing") | Out-Null }
    if ($workspacePrincipals.Count -eq 0) { $gapFlags.Add("principals_missing") | Out-Null }
    if ($workspaceDevOps.Count -gt 0) { $gapFlags.Add("devops_link_unconfirmed") | Out-Null }

    $normalizedWorkspaceName = Get-FieldValue -Object $workspace -Names @("normalized_workspace_name")
    $environment = Get-FieldValue -Object $workspace -Names @("environment")
    $workspaceType = Get-FieldValue -Object $workspace -Names @("workspace_type")
    $capacityId = Get-FieldValue -Object $workspace -Names @("capacity_id")
    $capacityName = Get-FieldValue -Object $workspace -Names @("capacity_name")
    $capacityRegion = Get-FieldValue -Object $workspace -Names @("capacity_region")
    $domainName = Get-FieldValue -Object $workspace -Names @("domain_name")
    $principalCount = @($workspacePrincipals).Count
    $itemCount = @($workspaceItems).Count
    $devOpsCandidateCount = @($workspaceDevOps).Count

    $governanceRows.Add([pscustomobject]@{
        workspace_name = $workspaceName
        normalized_workspace_name = $normalizedWorkspaceName
        environment = $environment
        workspace_type = $workspaceType
        capacity_id = $capacityId
        capacity_name = $capacityName
        capacity_region = $capacityRegion
        domain_name = $domainName
        principal_count = $principalCount
        user_count = $userCount
        group_count = $groupCount
        service_principal_count = $servicePrincipalCount
        deployment_pipeline_count = $deploymentPipelineIds.Count
        deployment_stage_names = ($deploymentStageNames -join "; ")
        item_count = $itemCount
        devops_candidate_count = $devOpsCandidateCount
        governance_gap_flags = ($gapFlags.ToArray() -join "; ")
        evidence = "index/workspaces.csv; index/deployment_pipeline_stages.csv; index/items.csv"
    }) | Out-Null
}

$capacityNameMissing = @($governanceRows.ToArray() | Where-Object { $_.capacity_id -and -not $_.capacity_name }).Count
if ($capacityNameMissing -gt 0) {
    Add-Gap -Gaps $gaps -GapId "phase11_capacity_name_missing" -Area "capacity_metadata" -Severity "medium" -Scope "workspaces" -AffectedCount $capacityNameMissing -Evidence "capacity_id present but capacity_name empty in index/workspaces.csv" -RecommendedAction "Refresh Fabric/Power BI capacity metadata after Azure CLI re-authentication or admin permission confirmation."
}

$domainMissing = @($governanceRows.ToArray() | Where-Object { -not $_.domain_name }).Count
if ($domainMissing -gt 0) {
    Add-Gap -Gaps $gaps -GapId "phase11_domain_missing" -Area "workspace_domain" -Severity "low" -Scope "workspaces" -AffectedCount $domainMissing -Evidence "domain_name empty in index/workspaces.csv" -RecommendedAction "Retry read-only domain/admin metadata if tenant permissions allow."
}

$principalsMissing = @($governanceRows.ToArray() | Where-Object { $_.principal_count -eq 0 }).Count
if ($principalsMissing -gt 0) {
    Add-Gap -Gaps $gaps -GapId "phase11_principals_missing" -Area "workspace_access" -Severity "medium" -Scope "workspaces" -AffectedCount $principalsMissing -Evidence "owner/admin_principals empty in index/workspaces.csv" -RecommendedAction "Retry workspace role assignments read-only after Azure CLI re-authentication."
}

if ($devOpsRows.Count -gt 0) {
    Add-Gap -Gaps $gaps -GapId "phase11_devops_links_unconfirmed" -Area "azure_devops" -Severity "medium" -Scope "technical_items" -AffectedCount $devOpsRows.Count -Evidence "No local Azure DevOps org/project/repo evidence found for generated candidate links." -RecommendedAction "Provide Azure DevOps organization/project scope or connector access, then confirm candidates through read-only repo search."
}

$summary = [pscustomobject]@{
    generated_at = (Get-Date).ToString("s")
    phase = "Phase 11"
    source_mode = if ($UseReadOnlyApis) { "local-artifacts-plus-read-only-api-attempt" } else { "local-artifacts" }
    workspace_count = $workspaces.Count
    governance_rows = $governanceRows.Count
    principal_rows = $principalRows.Count
    deployment_memberships = $deploymentRows.Count
    deployment_pipelines = $pipelines.Count
    devops_candidates = $devOpsRows.Count
    gap_count = $gaps.Count
}

Export-Rows -Rows $governanceRows.ToArray() -Columns @(
    "workspace_name", "normalized_workspace_name", "environment", "workspace_type", "capacity_id", "capacity_name", "capacity_region", "domain_name",
    "principal_count", "user_count", "group_count", "service_principal_count", "deployment_pipeline_count", "deployment_stage_names", "item_count",
    "devops_candidate_count", "governance_gap_flags", "evidence"
) -Path $OutputGovernancePath

Export-Rows -Rows $principalRows.ToArray() -Columns @(
    "workspace_name", "environment", "principal_name", "principal_email", "principal_type", "role", "source_field", "confidence", "evidence"
) -Path $OutputPrincipalPath

Export-Rows -Rows $deploymentRows.ToArray() -Columns @(
    "workspace_name", "deployment_pipeline_id", "deployment_pipeline_name", "stage_id", "stage_order", "stage_name", "evidence", "status"
) -Path $OutputDeploymentPath

Export-Rows -Rows $devOpsRows.ToArray() -Columns @(
    "workspace_name", "environment", "item_type", "item_name", "item_qualified_name", "candidate_search_terms", "candidate_status", "confidence", "evidence", "recommended_action"
) -Path $OutputDevOpsPath

Export-Rows -Rows $gaps.ToArray() -Columns @(
    "gap_id", "phase", "area", "severity", "scope", "affected_count", "evidence", "recommended_action"
) -Path $OutputGapPath

$governanceByWorkspace = @{}
foreach ($row in $governanceRows) {
    $governanceByWorkspace[$row.workspace_name] = $row
}

$payload = [pscustomobject]@{
    schema_version = "phase11.workspace_governance_devops.v1"
    generated_at = $summary.generated_at
    summary = $summary
    workspaces = @($governanceRows.ToArray())
    principals = @($principalRows.ToArray())
    deployment_memberships = @($deploymentRows.ToArray())
    devops_candidates = @($devOpsRows.ToArray())
    gaps = @($gaps.ToArray())
}

Ensure-ParentDirectory -Path $OutputJsonPath
$payload | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputJsonPath -Encoding UTF8

if (Test-Path $LineageModelPath) {
    $lineage = Get-Content -Path $LineageModelPath -Raw | ConvertFrom-Json
    foreach ($workspace in @($lineage.workspaces)) {
        $workspaceName = Get-FieldValue -Object $workspace -Names @("name")
        if ($governanceByWorkspace.ContainsKey($workspaceName)) {
            $row = $governanceByWorkspace[$workspaceName]
            $workspace | Add-Member -NotePropertyName "governance" -NotePropertyValue ([pscustomobject]@{
                principal_count = [int]$row.principal_count
                user_count = [int]$row.user_count
                group_count = [int]$row.group_count
                service_principal_count = [int]$row.service_principal_count
                deployment_pipeline_count = [int]$row.deployment_pipeline_count
                deployment_stage_names = $row.deployment_stage_names
                devops_candidate_count = [int]$row.devops_candidate_count
                governance_gap_flags = $row.governance_gap_flags
                evidence = $row.evidence
            }) -Force
        }
    }
    $lineage | Add-Member -NotePropertyName "phase11_governance" -NotePropertyValue ([pscustomobject]@{
        schema_version = $payload.schema_version
        generated_at = $payload.generated_at
        summary = $summary
        gaps = @($gaps.ToArray())
    }) -Force
    $lineage | ConvertTo-Json -Depth 30 | Set-Content -Path $LineageModelPath -Encoding UTF8
}

Ensure-ParentDirectory -Path $DocPath
$doc = [System.Collections.Generic.List[string]]::new()
$doc.Add("# Workspace Governance And DevOps Enrichment") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Generated by backend/scripts/37_build_workspace_governance_devops_enrichment.ps1.") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Outputs") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- analysis/workspace_governance_enrichment.csv") | Out-Null
$doc.Add("- analysis/workspace_governance_principals.csv") | Out-Null
$doc.Add("- analysis/workspace_deployment_pipeline_membership.csv") | Out-Null
$doc.Add("- analysis/workspace_devops_link_candidates.csv") | Out-Null
$doc.Add("- analysis/workspace_governance_devops_gaps.csv") | Out-Null
$doc.Add("- archive/lineage-explorer/data/workspace-governance.json") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Summary") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("- Workspaces: $($summary.workspace_count)") | Out-Null
$doc.Add("- Principal rows: $($summary.principal_rows)") | Out-Null
$doc.Add("- Deployment memberships: $($summary.deployment_memberships)") | Out-Null
$doc.Add("- Deployment pipelines: $($summary.deployment_pipelines)") | Out-Null
$doc.Add("- Azure DevOps link candidates: $($summary.devops_candidates)") | Out-Null
$doc.Add("- Gap themes: $($summary.gap_count)") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("## Access Note") | Out-Null
$doc.Add("") | Out-Null
if ($UseReadOnlyApis) {
    $doc.Add("Read-only API enrichment was requested. Any token or permission failures are recorded in the gap CSV.") | Out-Null
}
else {
    $doc.Add("This run used local artifacts only. Run with -UseReadOnlyApis after human Azure CLI re-authentication to retry Fabric/Power BI metadata enrichment.") | Out-Null
}
$doc.Add("") | Out-Null
$doc.Add("## Next Human Step") | Out-Null
$doc.Add("") | Out-Null
$doc.Add("Review the governance gaps. If live read-only enrichment is needed, run az login for your tenant, then rerun this script with -UseReadOnlyApis.") | Out-Null
$doc | Set-Content -Path $DocPath -Encoding UTF8

Write-Host "Workspace governance enrichment built."
Write-Host "Workspaces: $($summary.workspace_count)"
Write-Host "Principal rows: $($summary.principal_rows)"
Write-Host "Deployment memberships: $($summary.deployment_memberships)"
Write-Host "Azure DevOps candidates: $($summary.devops_candidates)"
Write-Host "Gaps: $($summary.gap_count)"
