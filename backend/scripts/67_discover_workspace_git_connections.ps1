param(
    [string]$WorkspaceIndexPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "../../index/workspace_git_connections.csv"),
    [string]$AzCommand = "az",
    [string]$FabricApiBaseUrl = "https://api.fabric.microsoft.com/v1",
    [int]$RetryCount = 5,
    [int]$RequestDelayMilliseconds = 250,
    [string]$WorkspaceNameFilter = ""
)

# Phase 67 - Workspace Git connection discovery.
# Discovers each workspace's Azure DevOps/GitHub Git connection (see the
# admin panel's workspace detail: "connected repo" + the workspace index's
# sync icon, docs/102_admin_panel_and_user_auth.md). Read-only:
# GET /v1/workspaces/{id}/git/connection never modifies anything in Fabric.
#
# gitSyncDetails.lastSyncTime is when FABRIC itself last pulled from the
# connected branch -- comparing that against our own last successful scan
# of this workspace (from analysis/single_workspace_scan/history.csv) is
# what drives the sync icon: if Fabric synced from git more recently than
# we last scanned, our data may be missing whatever changed in that sync.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$columns = @(
    "workspace_name",
    "git_connected",
    "git_provider_type",
    "organization_name",
    "project_name",
    "repository_name",
    "branch_name",
    "directory_name",
    "last_sync_time",
    "head_commit",
    "status",
    "evidence"
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

function Get-WorkspaceGitConnection {
    param([string]$WorkspaceId, [hashtable]$Headers)

    $uri = "$($FabricApiBaseUrl.TrimEnd('/'))/workspaces/$WorkspaceId/git/connection"
    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        try {
            $payload = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers
            if ($RequestDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $RequestDelayMilliseconds }
            return [pscustomobject]@{ succeeded = $true; payload = $payload; error = "" }
        }
        catch {
            $statusCode = ""
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            if ($statusCode -eq 429 -and $attempt -lt $RetryCount) {
                Start-Sleep -Seconds ([math]::Min(60, [math]::Pow(2, $attempt + 1)))
                continue
            }
            if ($statusCode -eq 404 -or $statusCode -eq 400) {
                # A workspace type Fabric doesn't support Git for (e.g. a
                # personal "My workspace") -- not an error, just "no connection".
                # Same shape as a real "not connected" response (gitProviderDetails/
                # gitSyncDetails both null) so callers never have to special-case this.
                return [pscustomobject]@{
                    succeeded = $true
                    payload = [pscustomobject]@{
                        gitConnectionState = "NotSupported"
                        gitProviderDetails = $null
                        gitSyncDetails = $null
                    }
                    error = ""
                }
            }
            return [pscustomobject]@{ succeeded = $false; payload = $null; error = $_.Exception.Message }
        }
    }
}

$workspaceRows = @(Import-Csv -Path $WorkspaceIndexPath)
if ($workspaceRows.Count -eq 0) {
    throw "Workspace index has no rows: $WorkspaceIndexPath"
}

$workspaceFilterSet = $null
if ($WorkspaceNameFilter) {
    $workspaceFilterSet = @{}
    foreach ($name in ($WorkspaceNameFilter -split "[;,]" | ForEach-Object { Normalize-Key $_ } | Where-Object { $_ })) {
        $workspaceFilterSet[$name] = $true
    }
}

$targetWorkspaces = if ($workspaceFilterSet) {
    @($workspaceRows | Where-Object { $workspaceFilterSet.ContainsKey((Normalize-Key (Get-FieldValue -Object $_ -Names @("workspace_name")))) })
}
else {
    $workspaceRows
}

$token = Get-FreshAzureCliToken -Resource "https://api.fabric.microsoft.com" -AzCommand $AzCommand
$headers = @{ Authorization = "Bearer $token" }

$rows = [System.Collections.Generic.List[object]]::new()
$errorCount = 0
foreach ($workspace in $targetWorkspaces) {
    $headers.Authorization = "Bearer $(Get-FreshAzureCliToken -Resource 'https://api.fabric.microsoft.com' -AzCommand $AzCommand)"
    $workspaceName = Get-FieldValue -Object $workspace -Names @("workspace_name")
    $workspaceId = Get-FieldValue -Object $workspace -Names @("technical_id", "workspace_id")
    if (-not $workspaceId) {
        $rows.Add([pscustomobject]@{
            workspace_name = $workspaceName; git_connected = "false"; git_provider_type = ""
            organization_name = ""; project_name = ""; repository_name = ""; branch_name = ""
            directory_name = ""; last_sync_time = ""; head_commit = ""
            status = "skipped"; evidence = "No technical_id/workspace_id in $WorkspaceIndexPath."
        }) | Out-Null
        continue
    }

    $result = Get-WorkspaceGitConnection -WorkspaceId $workspaceId -Headers $headers
    if (-not $result.succeeded) {
        $errorCount++
        $rows.Add([pscustomobject]@{
            workspace_name = $workspaceName; git_connected = "false"; git_provider_type = ""
            organization_name = ""; project_name = ""; repository_name = ""; branch_name = ""
            directory_name = ""; last_sync_time = ""; head_commit = ""
            status = "error"; evidence = $result.error
        }) | Out-Null
        continue
    }

    $state = [string]$result.payload.gitConnectionState
    $provider = $result.payload.gitProviderDetails
    $sync = $result.payload.gitSyncDetails
    $connected = $state -eq "ConnectedAndInitialized" -or $state -eq "Connected"
    $rows.Add([pscustomobject]@{
        workspace_name = $workspaceName
        git_connected = if ($connected) { "true" } else { "false" }
        git_provider_type = if ($provider) { [string]$provider.gitProviderType } else { "" }
        organization_name = if ($provider) { [string]$provider.organizationName } else { "" }
        project_name = if ($provider) { [string]$provider.projectName } else { "" }
        repository_name = if ($provider) { [string]$provider.repositoryName } else { "" }
        branch_name = if ($provider) { [string]$provider.branchName } else { "" }
        directory_name = if ($provider) { [string]$provider.directoryName } else { "" }
        # Invoke-RestMethod's JSON parser turns an ISO date-like string into
        # a real [datetime], and casting THAT to [string] uses the current
        # culture's format (e.g. US "06/16/2026 05:58:40") instead of ISO --
        # force round-trip ISO explicitly so this compares correctly against
        # every other ISO timestamp already in this project (history.csv,
        # _now_iso() in lineage_web_server.py, etc).
        last_sync_time = if ($sync -and $sync.lastSyncTime) {
            if ($sync.lastSyncTime -is [datetime]) { $sync.lastSyncTime.ToString("o") } else { [string]$sync.lastSyncTime }
        } else { "" }
        head_commit = if ($sync) { [string]$sync.head } else { "" }
        status = $state
        evidence = "Fabric git/connection API."
    }) | Out-Null
}

Ensure-ParentDirectory -Path $OutputPath
if ($workspaceFilterSet -and (Test-Path $OutputPath)) {
    $discoveredNames = @{}
    foreach ($row in $rows) { $discoveredNames[(Normalize-Key $row.workspace_name)] = $true }
    $retainedRows = @(
        Import-Csv -Path $OutputPath |
            Where-Object { -not $discoveredNames.ContainsKey((Normalize-Key $_.workspace_name)) }
    )
    $rows = @($rows) + $retainedRows
    Write-Host "Workspace filter active: retained $($retainedRows.Count) previously discovered workspace(s) outside this scan's scope."
}

Export-Rows -Path $OutputPath -Rows ($rows | Sort-Object -Property workspace_name) -Columns $columns

Write-Host "Workspace Git connection discovery complete."
Write-Host "Workspaces checked: $($targetWorkspaces.Count)"
Write-Host "Git-connected: $(@($rows | Where-Object { $_.git_connected -eq 'true' }).Count)"
if ($errorCount -gt 0) {
    Write-Host "Errors: $errorCount (see status=error rows in $OutputPath)"
}
Write-Host "Output: $OutputPath"
