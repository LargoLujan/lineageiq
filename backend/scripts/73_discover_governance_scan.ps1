# Phase 73 - Governance scan: Microsoft Fabric/Power BI Admin "Scanner API"
# (PostWorkspaceInfo -> GetScanStatus -> GetScanResult), the only tenant-wide
# source (without being owner of every dataset) for: sensitivity label,
# endorsement (Promoted/Certified/Master Data), tags, and semantic model RLS
# roles (name + DAX filter expression + assigned members). Everything else
# this project already discovers per-item; this one needs a real Microsoft
# API because no equivalent metadata lives inside getDefinition/connections.
#
# Read-only. Checked against Microsoft Learn plus a live, scoped test
# against a dev workspace -- see the auth section below for what that test
# found.
#
# IMPORTANT -- this is a DIFFERENT API surface than the rest of the project:
#   - Host: api.powerbi.com (classic Power BI Admin REST API), NOT
#     api.fabric.microsoft.com. Every other script in this repo only ever
#     talks to the Fabric host.
#   - Token audience: https://analysis.windows.net/powerbi/api (NOT
#     https://api.fabric.microsoft.com -- a different resource entirely,
#     even though both eventually reach the same backend for some calls).
#   - Observed in a live test: a delegated
#     Azure CLI token for that audience works fine for ordinary Power BI API
#     calls (GET /v1.0/myorg/groups succeeded and listed every workspace) but
#     PostWorkspaceInfo returned 401 (not 403) even though the same account
#     already works as a Fabric Administrator against api.fabric.microsoft.com's
#     own /v1/admin/workspaces (that one returns a clean 403 for a genuine
#     non-admin, per fabric_api.py's _fetch_all_tenant_workspaces docstring
#     -- so this ISN'T "you're not an admin", something more specific to
#     this legacy Power BI Admin API surface is blocking the call). Leading
#     hypothesis, not yet confirmed by a tenant admin: the Microsoft Entra
#     "Power BI Administrator" role (distinct from "Fabric Administrator")
#     may need to be assigned separately for this specific API family, and/or
#     Admin Portal -> Tenant settings -> Admin API settings may restrict
#     which accounts/security groups can call Admin APIs at all. This script
#     detects and reports that condition clearly (see Add-GovernanceStatus
#     calls below) instead of failing silently or with a generic error --
#     re-run this script once someone with Admin Portal access has checked/
#     adjusted the above; nothing else needs to change.
#
# AUTH MODE: supports a service principal instead of a
# named person's delegated session, which is the actually-recommended path
# for unattended/non-nominal scanning -- confirmed against Microsoft Learn's
# "Enable service principal authentication for admin APIs": PostWorkspaceInfo/
# GetScanStatus/GetScanResult/GetModifiedWorkspaces are explicitly listed as
# supported for service principal auth under "read-only admin APIs", and
# critically this path needs NO "Power BI Administrator" (or any other)
# Entra directory role on anyone -- access is granted by tenant setting +
# security group membership instead. Defaults to auto-loading the SP already
# configured for this project's Warehouse writes (config/lakehouse_target.json,
# same sp_tenant_id/sp_client_id/sp_client_secret_ref fields admin_settings.py
# already writes there) so "use the SP we already have" needs zero extra
# flags -- falls back to the signed-in delegated Azure CLI session (the
# original behavior, still fully supported) when no SP is
# configured or its token acquisition fails. Setup a tenant admin still has
# to do once, by hand (this script cannot grant its own access):
#   1. Confirm the app has NO admin-consent-required Power BI permissions
#      set on it (Entra ID -> Enterprise applications -> the app ->
#      Permissions -- must be empty of "Application" type Power BI grants).
#   2. Add the app as a member of a Microsoft Entra Security Group (create
#      one if needed).
#   3. Fabric admin portal -> Tenant settings -> Admin API settings ->
#      "Service principals can access read-only admin APIs" -> Enabled ->
#      Specific security groups -> that group -> Apply.
#
# Writes: $OutputSensitivityPath, $OutputEndorsementPath, $OutputTagsPath,
# $OutputRlsRolesPath, $OutputStatusPath, $OutputSummaryPath, $OutputDocPath.
param(
    [string]$WorkspacesPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$OutputSensitivityPath = (Join-Path $PSScriptRoot "../../analysis/governance_sensitivity_labels.csv"),
    [string]$OutputEndorsementPath = (Join-Path $PSScriptRoot "../../analysis/governance_endorsement.csv"),
    [string]$OutputTagsPath = (Join-Path $PSScriptRoot "../../analysis/governance_tags.csv"),
    [string]$OutputRlsRolesPath = (Join-Path $PSScriptRoot "../../analysis/governance_rls_roles.csv"),
    [string]$OutputStatusPath = (Join-Path $PSScriptRoot "../../analysis/governance_scan_status.csv"),
    [string]$OutputSummaryPath = (Join-Path $PSScriptRoot "../../analysis/governance_scan_summary.csv"),
    [string]$OutputDocPath = (Join-Path $PSScriptRoot "../../docs/73_governance_scan.md"),
    [string]$AzCommand = "az",
    [string]$PowerBiApiBaseUrl = "https://api.powerbi.com/v1.0/myorg",
    [string]$PowerBiTokenResource = "https://analysis.windows.net/powerbi/api",
    [string]$GraphApiBaseUrl = "https://graph.microsoft.com/beta",
    [string]$GraphTokenResource = "https://graph.microsoft.com",
    # Service principal auth (preferred -- see the big comment block above).
    # Left empty = auto-load from $LakehouseTargetConfigPath; explicit values
    # here always win over that file. -SkipServicePrincipal forces the old
    # delegated-only behavior even if a SP is configured, for comparison/
    # troubleshooting.
    [string]$SpTenantId = "",
    [string]$SpClientId = "",
    [string]$SpClientSecretEnvVar = "",
    [string]$LakehouseTargetConfigPath = (Join-Path $PSScriptRoot "../../config/lakehouse_target.json"),
    [switch]$SkipServicePrincipal,
    # Opt-in: needs "Enhance admin APIs responses with detailed metadata" /
    # "...with DAX and mashup expressions" enabled in Admin Portal -> Tenant
    # settings -> Admin API settings first (the second depends on the
    # first) -- see Set-up-metadata-scanning docs. Requesting these without
    # that setting enabled has not been confirmed live either way; kept
    # opt-in so a first run against a freshly-unblocked tenant starts with
    # the safer default and an operator can add -IncludeDatasetSchema once
    # that setting is confirmed on.
    [switch]$IncludeDatasetSchema,
    [int]$MaxWorkspacesPerBatch = 100,
    [int]$MaxScanStatusPolls = 40,
    [int]$ScanStatusPollDelaySeconds = 5,
    [switch]$SkipSensitivityLabelNames
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

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
            if ($null -ne $value) { return $value }
        }
    }
    return $null
}

$statusRows = [System.Collections.Generic.List[object]]::new()
function Add-GovernanceStatus {
    param([string]$Check, [string]$Status, [string]$Detail, [string]$Fix = "")
    $statusRows.Add([pscustomobject]@{ check = $Check; status = $Status; detail = $Detail; fix = $Fix; checked_at = (Get-Date).ToString("s") }) | Out-Null
    Write-Host "[$Status] $Check -- $Detail"
}

$sensitivityRows = [System.Collections.Generic.List[object]]::new()
$endorsementRows = [System.Collections.Generic.List[object]]::new()
$tagRows = [System.Collections.Generic.List[object]]::new()
$rlsRoleRows = [System.Collections.Generic.List[object]]::new()

# Plain OAuth2 client-credentials call against Entra's v2.0 token endpoint --
# same shape as 67_upload_bronze_to_warehouse.ps1's own copy (this project's
# established convention: small per-script token helpers, not a shared
# import). $Scope needs the `/.default` suffix (app-only tokens, not the
# delegated `Resource` string Get-AzureCliToken uses).
function Get-ServicePrincipalAccessToken {
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret, [string]$Scope)
    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = $Scope
        grant_type    = "client_credentials"
    }
    $response = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body $body -ContentType "application/x-www-form-urlencoded"
    if (-not $response.access_token) {
        throw "Entra returned no access_token for this service principal/scope."
    }
    return [string]$response.access_token
}

# Resolve which SP to use, if any: explicit params win, otherwise fall back
# to whatever this project's Warehouse-write SP already has configured (see
# the big param-block comment above for why that's a sensible default, not
# a surprising cross-purpose reuse).
$resolvedSpTenantId = $SpTenantId
$resolvedSpClientId = $SpClientId
$resolvedSpClientSecretEnvVar = $SpClientSecretEnvVar
if (-not $SkipServicePrincipal -and (-not $resolvedSpClientId) -and (Test-Path $LakehouseTargetConfigPath)) {
    try {
        $lakehouseConfig = Get-Content -Path $LakehouseTargetConfigPath -Raw | ConvertFrom-Json
        if ($lakehouseConfig.auth_mode -eq "service_principal" -and $lakehouseConfig.sp_client_id) {
            $resolvedSpTenantId = $lakehouseConfig.sp_tenant_id
            $resolvedSpClientId = $lakehouseConfig.sp_client_id
            $resolvedSpClientSecretEnvVar = $lakehouseConfig.sp_client_secret_ref
        }
    }
    catch {
        # Malformed/missing config file -- not fatal, just means no SP auto-detected; falls through to delegated auth below.
    }
}
$resolvedSpClientSecret = if ($resolvedSpClientSecretEnvVar) { [Environment]::GetEnvironmentVariable($resolvedSpClientSecretEnvVar) } else { "" }
$useServicePrincipal = -not $SkipServicePrincipal -and $resolvedSpTenantId -and $resolvedSpClientId -and $resolvedSpClientSecret

# ---------------------------------------------------------------------------
# Step 1 -- auth
# ---------------------------------------------------------------------------
$powerBiToken = $null
$authMode = if ($useServicePrincipal) { "service_principal" } else { "delegated" }

if ($useServicePrincipal) {
    try {
        $powerBiToken = Get-ServicePrincipalAccessToken -TenantId $resolvedSpTenantId -ClientId $resolvedSpClientId -ClientSecret $resolvedSpClientSecret -Scope "$PowerBiTokenResource/.default"
        Add-GovernanceStatus -Check "auth_token" -Status "ok" -Detail "Acquired a service-principal token for $PowerBiTokenResource (client id $resolvedSpClientId)."
    }
    catch {
        Add-GovernanceStatus -Check "auth_token" -Status "blocked" -Detail "Service-principal token acquisition failed: $($_.Exception.Message)" `
            -Fix "Check: (1) the app has no admin-consent-required Power BI permissions set on it (Entra ID -> Enterprise applications -> the app -> Permissions must be empty of Application-type Power BI grants); (2) the app is a member of the Security Group allow-listed under Fabric admin portal -> Tenant settings -> Admin API settings -> 'Service principals can access read-only admin APIs'; (3) the client secret named by the '$resolvedSpClientSecretEnvVar' environment variable hasn't expired."
    }
}
else {
    try {
        $powerBiToken = Get-AzureCliToken -Resource $PowerBiTokenResource -AzCommand $AzCommand
        Add-GovernanceStatus -Check "auth_token" -Status "ok" -Detail "Acquired a delegated Azure CLI token for $PowerBiTokenResource (no service principal configured in $LakehouseTargetConfigPath -- see -SpTenantId/-SpClientId/-SpClientSecretEnvVar to use one instead)."
    }
    catch {
        Add-GovernanceStatus -Check "auth_token" -Status "error" -Detail "Could not acquire a token: $($_.Exception.Message)" `
            -Fix "Run 'az login' (or 'az account get-access-token --resource $PowerBiTokenResource' directly) and confirm it succeeds before re-running this script."
    }
}

$powerBiHeaders = if ($powerBiToken) { @{ Authorization = "Bearer $powerBiToken"; "Content-Type" = "application/json" } } else { $null }

# ---------------------------------------------------------------------------
# Step 2 -- workspace ids to scan
# ---------------------------------------------------------------------------
$workspaceRows = @(Import-Csv -Path $WorkspacesPath | Where-Object { $_.technical_id })
if ($workspaceRows.Count -eq 0) {
    Add-GovernanceStatus -Check "workspace_list" -Status "error" -Detail "No workspaces with a technical_id found in $WorkspacesPath." `
        -Fix "Run scripts/01_discover_workspaces.ps1 first."
}
else {
    Add-GovernanceStatus -Check "workspace_list" -Status "ok" -Detail "$($workspaceRows.Count) workspace id(s) to scan, from $WorkspacesPath."
}

$workspaceById = @{}
foreach ($row in $workspaceRows) { $workspaceById[$row.technical_id] = $row.workspace_name }

$batches = [System.Collections.Generic.List[object]]::new()
for ($i = 0; $i -lt $workspaceRows.Count; $i += $MaxWorkspacesPerBatch) {
    $end = [Math]::Min($i + $MaxWorkspacesPerBatch, $workspaceRows.Count) - 1
    $batches.Add(@($workspaceRows[$i..$end] | ForEach-Object { $_.technical_id })) | Out-Null
}

# ---------------------------------------------------------------------------
# Step 3 -- run the scan per batch (PostWorkspaceInfo -> GetScanStatus -> GetScanResult)
# ---------------------------------------------------------------------------
function Get-ScannerApiFix {
    param([int]$StatusCode, [bool]$UsingServicePrincipal)
    switch ($StatusCode) {
        401 {
            if ($UsingServicePrincipal) {
                return "HTTP 401 with service-principal auth. Ask a Fabric/Power BI admin to check: (1) the app has no admin-consent-required Power BI permissions set on it (Entra ID -> Enterprise applications -> the app -> Permissions must be empty of Application-type Power BI grants -- this API rejects the call otherwise); (2) the app is a member of the Security Group allow-listed under Fabric admin portal -> Tenant settings -> Admin API settings -> 'Service principals can access read-only admin APIs' -> Enabled -> that group; (3) the client secret hasn't expired."
            }
            return "HTTP 401 on this specific Power BI Admin API (different from an ordinary 403 'not an admin'). Confirmed live 2026-08-26 that a Fabric Administrator account still gets this with delegated auth. Ask someone with Fabric/Power BI Admin Portal access to check: (1) the calling account also holds the Microsoft Entra 'Power BI Administrator' role, not just 'Fabric Administrator' -- these are two distinct roles for this legacy API family; (2) Admin Portal -> Tenant settings -> Admin API settings isn't restricted to a security group the account isn't in. Alternative: switch to service-principal auth (-SpTenantId/-SpClientId/-SpClientSecretEnvVar, or configure config/lakehouse_target.json) -- it needs no directory role at all, just a security-group allow-list."
        }
        403 {
            if ($UsingServicePrincipal) {
                return "HTTP 403: the app is not allow-listed for this API. Fabric admin portal -> Tenant settings -> Admin API settings -> 'Service principals can access read-only admin APIs' -> Enabled -> add the app's Security Group."
            }
            return "HTTP 403: the calling account is not recognized as a Fabric/Power BI admin for this API. Assign the 'Fabric Administrator' or 'Power BI Administrator' Microsoft Entra role."
        }
        429 {
            return "HTTP 429: rate limit hit (PostWorkspaceInfo is capped at 500 calls/hour). Wait and re-run later; this script already backs off on 429/503/504 automatically for a single call, but a tenant already near the cap from other tools needs a longer wait."
        }
        default {
            return "Unexpected HTTP $StatusCode from the Power BI Admin API. Check https://learn.microsoft.com/en-us/rest/api/power-bi/admin/workspace-info-post-workspace-info for current behavior -- this API has changed shape before."
        }
    }
}

$scanApiUsable = $null -ne $powerBiHeaders -and $workspaceRows.Count -gt 0
if ($scanApiUsable) {
    $batchIndex = 0
    $anyBatchSucceeded = $false
    $stoppedEarlyOnAuth = $false
    foreach ($batch in $batches) {
        $batchIndex += 1
        if ($stoppedEarlyOnAuth) { break }

        $queryParams = @("lineage=True", "datasourceDetails=True", "getArtifactUsers=True")
        if ($IncludeDatasetSchema) { $queryParams += @("datasetSchema=True", "datasetExpressions=True") }
        $postPath = "admin/workspaces/getInfo?$($queryParams -join '&')"
        $postBody = (@{ workspaces = $batch } | ConvertTo-Json)

        $postResult = Invoke-FabricWebRequestCore -Method Post -Path $postPath -Headers $powerBiHeaders `
            -BaseUrl $PowerBiApiBaseUrl -TokenResource $PowerBiTokenResource -Body $postBody -AzCommand $AzCommand

        if (-not $postResult.succeeded) {
            $fix = Get-ScannerApiFix -StatusCode $postResult.status_code -UsingServicePrincipal $useServicePrincipal
            Add-GovernanceStatus -Check "scanner_api_post_batch_$batchIndex" -Status "blocked" `
                -Detail "PostWorkspaceInfo failed for batch $batchIndex/$($batches.Count) ($($batch.Count) workspaces): HTTP $($postResult.status_code)." -Fix $fix
            # A 401/403 here is a tenant-wide auth condition, not a per-batch
            # fluke -- retrying every remaining batch would just spam the
            # same failure once per batch across every workspace. Stop after
            # the first one instead of burning rate-limit budget for nothing.
            if ($postResult.status_code -eq 401 -or $postResult.status_code -eq 403) {
                $stoppedEarlyOnAuth = $true
            }
            continue
        }

        $scanId = (($postResult.content | ConvertFrom-Json).id)
        if (-not $scanId) {
            Add-GovernanceStatus -Check "scanner_api_post_batch_$batchIndex" -Status "error" -Detail "PostWorkspaceInfo succeeded but returned no scan id."
            continue
        }

        $pollCount = 0
        $scanStatus = "NotStarted"
        while ($scanStatus -notin @("Succeeded", "Failed") -and $pollCount -lt $MaxScanStatusPolls) {
            Start-Sleep -Seconds $ScanStatusPollDelaySeconds
            $pollCount += 1
            $statusResult = Invoke-FabricWebRequestCore -Method Get -Path "admin/workspaces/scanStatus/$scanId" -Headers $powerBiHeaders `
                -BaseUrl $PowerBiApiBaseUrl -TokenResource $PowerBiTokenResource -AzCommand $AzCommand
            if (-not $statusResult.succeeded) {
                Add-GovernanceStatus -Check "scanner_api_status_batch_$batchIndex" -Status "error" -Detail "GetScanStatus failed: HTTP $($statusResult.status_code)."
                break
            }
            $scanStatus = (($statusResult.content | ConvertFrom-Json).status)
        }

        if ($scanStatus -ne "Succeeded") {
            Add-GovernanceStatus -Check "scanner_api_status_batch_$batchIndex" -Status "error" `
                -Detail "Scan did not reach Succeeded after $pollCount poll(s) (last status: $scanStatus)." `
                -Fix "If this is 'Running' every time, increase -MaxScanStatusPolls / -ScanStatusPollDelaySeconds for a tenant this size."
            continue
        }

        $resultCall = Invoke-FabricWebRequestCore -Method Get -Path "admin/workspaces/scanResult/$scanId" -Headers $powerBiHeaders `
            -BaseUrl $PowerBiApiBaseUrl -TokenResource $PowerBiTokenResource -AzCommand $AzCommand
        if (-not $resultCall.succeeded) {
            Add-GovernanceStatus -Check "scanner_api_result_batch_$batchIndex" -Status "error" -Detail "GetScanResult failed: HTTP $($resultCall.status_code)."
            continue
        }

        $anyBatchSucceeded = $true
        $scanPayload = $resultCall.content | ConvertFrom-Json
        $capturedAt = (Get-Date).ToString("s")

        # Response shape per Microsoft Learn (workspace-info-get-scan-result):
        # { workspaces: [ { id, name, datasets: [...], reports: [...],
        # dashboards: [...], dataflows: [...], ... } ] }. Every artifact-type
        # array is walked generically for the fields common to all of them
        # (sensitivityLabel/endorsementDetails/tags); datasets additionally
        # carry `roles` (RLS). This has NOT been confirmed against a real
        # successful response yet (blocked by the auth issue
        # above) -- if a future run finds the shape differs, fix the field
        # names below, the CSV schema and downstream readers don't need to
        # change.
        foreach ($ws in @($scanPayload.workspaces)) {
            $workspaceName = if ($workspaceById.ContainsKey($ws.id)) { $workspaceById[$ws.id] } else { $ws.name }
            $artifactBuckets = @("datasets", "reports", "dashboards", "dataflows", "datamarts")
            foreach ($bucketName in $artifactBuckets) {
                if (-not ($ws.PSObject.Properties.Name -contains $bucketName)) { continue }
                foreach ($artifact in @($ws.$bucketName)) {
                    $itemName = Get-FieldValue -Object $artifact -Names @("name")
                    $qualifiedName = "$workspaceName / $itemName"

                    $label = Get-FieldValue -Object $artifact -Names @("sensitivityLabel")
                    if ($label -and (Get-FieldValue -Object $label -Names @("labelId"))) {
                        $sensitivityRows.Add([pscustomobject]@{
                            workspace_name = $workspaceName; item_type = $bucketName; item_name = $itemName
                            qualified_name = $qualifiedName; sensitivity_label_id = $label.labelId
                            sensitivity_label_name = ""; captured_at = $capturedAt
                        }) | Out-Null
                    }

                    $endorsement = Get-FieldValue -Object $artifact -Names @("endorsementDetails")
                    if ($endorsement -and (Get-FieldValue -Object $endorsement -Names @("endorsement"))) {
                        $endorsementRows.Add([pscustomobject]@{
                            workspace_name = $workspaceName; item_type = $bucketName; item_name = $itemName
                            qualified_name = $qualifiedName; endorsement = $endorsement.endorsement
                            certified_by = (Get-FieldValue -Object $endorsement -Names @("certifiedBy")); captured_at = $capturedAt
                        }) | Out-Null
                    }

                    foreach ($tag in @(Get-FieldValue -Object $artifact -Names @("tags"))) {
                        $tagName = Get-FieldValue -Object $tag -Names @("displayName", "name")
                        if (-not $tagName) { continue }
                        $tagRows.Add([pscustomobject]@{
                            workspace_name = $workspaceName; item_type = $bucketName; item_name = $itemName
                            qualified_name = $qualifiedName; tag_name = $tagName; captured_at = $capturedAt
                        }) | Out-Null
                    }

                    if ($bucketName -eq "datasets") {
                        foreach ($role in @(Get-FieldValue -Object $artifact -Names @("roles"))) {
                            $roleName = Get-FieldValue -Object $role -Names @("name")
                            $members = @(Get-FieldValue -Object $role -Names @("members"))
                            $tablePermissions = @(Get-FieldValue -Object $role -Names @("tablePermissions"))
                            if ($tablePermissions.Count -eq 0) {
                                $rlsRoleRows.Add([pscustomobject]@{
                                    workspace_name = $workspaceName; item_name = $itemName; qualified_name = $qualifiedName
                                    role_name = $roleName; table_name = ""; filter_expression = ""
                                    member_name = ""; member_type = ""; captured_at = $capturedAt
                                }) | Out-Null
                            }
                            foreach ($tablePermission in $tablePermissions) {
                                $memberList = if ($members.Count -gt 0) { $members } else { @($null) }
                                foreach ($member in $memberList) {
                                    $rlsRoleRows.Add([pscustomobject]@{
                                        workspace_name = $workspaceName; item_name = $itemName; qualified_name = $qualifiedName
                                        role_name = $roleName
                                        table_name = (Get-FieldValue -Object $tablePermission -Names @("name"))
                                        filter_expression = (Get-FieldValue -Object $tablePermission -Names @("filterExpression"))
                                        member_name = (Get-FieldValue -Object $member -Names @("memberName"))
                                        member_type = (Get-FieldValue -Object $member -Names @("memberType"))
                                        captured_at = $capturedAt
                                    }) | Out-Null
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if ($anyBatchSucceeded) {
        Add-GovernanceStatus -Check "scanner_api_overall" -Status "ok" `
            -Detail "$($sensitivityRows.Count) sensitivity label row(s), $($endorsementRows.Count) endorsement row(s), $($tagRows.Count) tag row(s), $($rlsRoleRows.Count) RLS role row(s) captured."
    }
}
else {
    Add-GovernanceStatus -Check "scanner_api_overall" -Status "skipped" -Detail "No token or no workspaces to scan -- see auth_token/workspace_list above."
}

# ---------------------------------------------------------------------------
# Step 4 -- resolve sensitivity label GUIDs to names via Microsoft Graph
# (separate permission from the Scanner API -- failing here doesn't lose the
# GUIDs already captured above, just leaves sensitivity_label_name blank).
# ---------------------------------------------------------------------------
if (-not $SkipSensitivityLabelNames -and $sensitivityRows.Count -gt 0) {
    try {
        $graphToken = if ($useServicePrincipal) {
            Get-ServicePrincipalAccessToken -TenantId $resolvedSpTenantId -ClientId $resolvedSpClientId -ClientSecret $resolvedSpClientSecret -Scope "$GraphTokenResource/.default"
        } else {
            Get-AzureCliToken -Resource $GraphTokenResource -AzCommand $AzCommand
        }
        $graphHeaders = @{ Authorization = "Bearer $graphToken" }
        $labelResult = Invoke-FabricWebRequestCore -Method Get -Path "security/informationProtection/sensitivityLabels" `
            -Headers $graphHeaders -BaseUrl $GraphApiBaseUrl -TokenResource $GraphTokenResource -AzCommand $AzCommand

        if ($labelResult.succeeded) {
            $labelById = @{}
            foreach ($label in @(($labelResult.content | ConvertFrom-Json).value)) {
                $labelById[$label.id] = $label.name
            }
            $resolvedCount = 0
            foreach ($row in $sensitivityRows) {
                if ($labelById.ContainsKey($row.sensitivity_label_id)) {
                    $row.sensitivity_label_name = $labelById[$row.sensitivity_label_id]
                    $resolvedCount += 1
                }
            }
            Add-GovernanceStatus -Check "graph_sensitivity_label_names" -Status "ok" -Detail "Resolved $resolvedCount/$($sensitivityRows.Count) label id(s) to a name via Microsoft Graph."
        }
        else {
            $fix = if ($labelResult.status_code -eq 401 -or $labelResult.status_code -eq 403) {
                if ($useServicePrincipal) {
                    "Grant the app the Microsoft Graph 'InformationProtectionPolicy.Read.All' APPLICATION permission (not delegated -- this is app-only auth) and get admin consent -- Entra admin center -> App registrations -> the app -> API permissions -> Add a permission -> Microsoft Graph -> Application permissions. Sensitivity label GUIDs are still captured above; only the human-readable name is missing until this is granted."
                } else {
                    "Grant the calling account the Microsoft Graph 'InformationProtectionPolicy.Read' (or '.Read.All') delegated permission and get admin consent -- Entra admin center -> App registrations -> the Azure CLI app -> API permissions. Sensitivity label GUIDs are still captured above; only the human-readable name is missing until this is granted."
                }
            } else {
                "Unexpected HTTP $($labelResult.status_code) from Microsoft Graph -- see https://learn.microsoft.com/en-us/graph/api/informationprotectionpolicy-list-labels"
            }
            Add-GovernanceStatus -Check "graph_sensitivity_label_names" -Status "blocked" -Detail "GET informationProtection/sensitivityLabels failed: HTTP $($labelResult.status_code)." -Fix $fix
        }
    }
    catch {
        Add-GovernanceStatus -Check "graph_sensitivity_label_names" -Status "error" -Detail "Could not call Microsoft Graph: $($_.Exception.Message)"
    }
}
elseif ($SkipSensitivityLabelNames) {
    Add-GovernanceStatus -Check "graph_sensitivity_label_names" -Status "skipped" -Detail "Skipped via -SkipSensitivityLabelNames."
}

# ---------------------------------------------------------------------------
# Write outputs
# ---------------------------------------------------------------------------
Export-Rows -Rows $sensitivityRows -Columns @("workspace_name", "item_type", "item_name", "qualified_name", "sensitivity_label_id", "sensitivity_label_name", "captured_at") -Path $OutputSensitivityPath
Export-Rows -Rows $endorsementRows -Columns @("workspace_name", "item_type", "item_name", "qualified_name", "endorsement", "certified_by", "captured_at") -Path $OutputEndorsementPath
Export-Rows -Rows $tagRows -Columns @("workspace_name", "item_type", "item_name", "qualified_name", "tag_name", "captured_at") -Path $OutputTagsPath
Export-Rows -Rows $rlsRoleRows -Columns @("workspace_name", "item_name", "qualified_name", "role_name", "table_name", "filter_expression", "member_name", "member_type", "captured_at") -Path $OutputRlsRolesPath
Export-Rows -Rows $statusRows -Columns @("check", "status", "detail", "fix", "checked_at") -Path $OutputStatusPath

$summaryRows = [System.Collections.Generic.List[object]]::new()
$summaryRows.Add([pscustomobject]@{ metric = "auth_mode"; value = $authMode; notes = if ($useServicePrincipal) { "client id $resolvedSpClientId" } else { "delegated Azure CLI session" } }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "workspaces_targeted"; value = $workspaceRows.Count; notes = "" }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "sensitivity_label_rows"; value = $sensitivityRows.Count; notes = "" }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "endorsement_rows"; value = $endorsementRows.Count; notes = "" }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "tag_rows"; value = $tagRows.Count; notes = "" }) | Out-Null
$summaryRows.Add([pscustomobject]@{ metric = "rls_role_rows"; value = $rlsRoleRows.Count; notes = "" }) | Out-Null
$blockedChecks = @($statusRows | Where-Object { $_.status -in @("blocked", "error") })
$summaryRows.Add([pscustomobject]@{ metric = "blocked_or_error_checks"; value = $blockedChecks.Count; notes = ($blockedChecks | ForEach-Object { $_.check }) -join "; " }) | Out-Null
Export-Rows -Rows $summaryRows -Columns @("metric", "value", "notes") -Path $OutputSummaryPath

$docLines = [System.Collections.Generic.List[string]]::new()
$docLines.Add("# Governance Scan (Scanner API)") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Generated at: $((Get-Date).ToString('s'))") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Purpose") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Tenant-wide sensitivity label, endorsement, tags, and semantic model RLS roles (name + DAX filter + assigned members), via the Power BI/Fabric Admin Scanner API -- the only source for this that doesn't require being the owner of every single dataset. Read-only.") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Current status") | Out-Null
$docLines.Add("") | Out-Null
foreach ($row in $statusRows) {
    $docLines.Add("- **$($row.check)** [$($row.status)]: $($row.detail)$(if ($row.fix) { " -- Fix: $($row.fix)" })") | Out-Null
}
$docLines.Add("") | Out-Null
$docLines.Add("## Outputs") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("- ``$OutputSensitivityPath``") | Out-Null
$docLines.Add("- ``$OutputEndorsementPath``") | Out-Null
$docLines.Add("- ``$OutputTagsPath``") | Out-Null
$docLines.Add("- ``$OutputRlsRolesPath``") | Out-Null
$docLines.Add("- ``$OutputStatusPath`` (machine-readable version of the status list above -- what the admin panel's Governance tab reads to show a diagnosis instead of a blank/broken section)") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("## Safety") | Out-Null
$docLines.Add("") | Out-Null
$docLines.Add("Read-only against the Power BI Admin API and Microsoft Graph. Never creates, updates, or deletes anything in Fabric, Power BI, or Entra.") | Out-Null
Ensure-ParentDirectory -Path $OutputDocPath
$docLines | Set-Content -Path $OutputDocPath -Encoding UTF8

Write-Host ""
Write-Host "Governance scan completed."
Write-Host "Sensitivity label rows: $($sensitivityRows.Count)"
Write-Host "Endorsement rows: $($endorsementRows.Count)"
Write-Host "Tag rows: $($tagRows.Count)"
Write-Host "RLS role rows: $($rlsRoleRows.Count)"
Write-Host "Blocked/error checks: $($blockedChecks.Count) -- see $OutputStatusPath"
