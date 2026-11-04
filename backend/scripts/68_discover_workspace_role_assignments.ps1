param(
    [string]$WorkspaceIndexPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "../../index/workspace_role_assignments.csv"),
    [string]$AzCommand = "az",
    [string]$FabricApiBaseUrl = "https://api.fabric.microsoft.com/v1",
    [int]$RetryCount = 5,
    [int]$RequestDelayMilliseconds = 250,
    [string]$WorkspaceNameFilter = ""
)

# Phase 68 - Workspace role assignment discovery.
# Discovers who has access to each workspace and at what role (Admin/
# Member/Contributor/Viewer) via GET /v1/workspaces/{id}/roleAssignments --
# a governance view of access, not just a lineage one (docs/102_admin_
# panel_and_user_auth.md). Also lets the frontend show "your own
# role here" by matching a principal id against the signed-in session's
# own object_id (see /api/auth/me's object_id field). Read-only.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$columns = @(
    "workspace_name",
    "principal_id",
    "principal_name",
    "principal_email",
    "principal_type",
    "role",
    "status",
    "evidence"
)

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

function Normalize-Key {
    param([string]$Value)
    if (-not $Value) { return "" }
    return ($Value.ToLowerInvariant() -replace "\s+", " ").Trim()
}

function Get-WorkspaceRoleAssignments {
    param([string]$WorkspaceId, [hashtable]$Headers)

    $uri = "$($FabricApiBaseUrl.TrimEnd('/'))/workspaces/$WorkspaceId/roleAssignments"
    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        try {
            $payload = Invoke-RestMethod -Method Get -Uri $uri -Headers $Headers
            if ($RequestDelayMilliseconds -gt 0) { Start-Sleep -Milliseconds $RequestDelayMilliseconds }
            return [pscustomobject]@{ succeeded = $true; values = @($payload.value); error = "" }
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
            return [pscustomobject]@{ succeeded = $false; values = @(); error = $_.Exception.Message }
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
        continue
    }

    $result = Get-WorkspaceRoleAssignments -WorkspaceId $workspaceId -Headers $headers
    if (-not $result.succeeded) {
        $errorCount++
        $rows.Add([pscustomobject]@{
            workspace_name = $workspaceName; principal_id = ""; principal_name = ""; principal_email = ""
            principal_type = ""; role = ""; status = "error"; evidence = $result.error
        }) | Out-Null
        continue
    }
    if ($result.values.Count -eq 0) {
        $rows.Add([pscustomobject]@{
            workspace_name = $workspaceName; principal_id = ""; principal_name = ""; principal_email = ""
            principal_type = ""; role = ""; status = "no_assignments"; evidence = "Fabric roleAssignments API returned zero entries."
        }) | Out-Null
        continue
    }
    foreach ($assignment in $result.values) {
        $principal = $assignment.principal
        # userDetails.userPrincipalName only exists for type == "User" (Fabric's
        # own Principal schema -- Group/ServicePrincipal have no email concept).
        $email = if ($principal -and $principal.type -eq "User" -and $principal.userDetails) {
            [string]$principal.userDetails.userPrincipalName
        } else { "" }
        $rows.Add([pscustomobject]@{
            workspace_name = $workspaceName
            principal_id = if ($principal) { [string]$principal.id } else { "" }
            principal_name = if ($principal) { [string]$principal.displayName } else { "" }
            principal_email = $email
            principal_type = if ($principal) { [string]$principal.type } else { "" }
            role = [string]$assignment.role
            status = "discovered"
            evidence = "Fabric roleAssignments API."
        }) | Out-Null
    }
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
    Write-Host "Workspace filter active: retained $($retainedRows.Count) previously discovered row(s) outside this scan's scope."
}

Export-Rows -Path $OutputPath -Rows ($rows | Sort-Object -Property workspace_name, principal_name) -Columns $columns

Write-Host "Workspace role assignment discovery complete."
Write-Host "Workspaces checked: $($targetWorkspaces.Count)"
Write-Host "Role assignment rows: $($rows.Count)"
if ($errorCount -gt 0) {
    Write-Host "Errors: $errorCount (see status=error rows in $OutputPath)"
}
Write-Host "Output: $OutputPath"
