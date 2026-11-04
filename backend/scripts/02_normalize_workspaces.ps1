# Phase 2 - Workspace normalization: fills capacity/region gaps left by
# discovery (not every workspace returns full metadata from the list API,
# so this does a per-workspace detail lookup) and standardizes naming.
# Read-only. Reads/updates $WorkspaceIndexPath in place; -OnlyPartial limits
# the pass to workspaces with missing metadata instead of re-checking all.
param(
    [string]$WorkspaceIndexPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$NodesPath = (Join-Path $PSScriptRoot "../../graph/nodes.csv"),
    [string]$UnresolvedPath = (Join-Path $PSScriptRoot "../../index/unresolved.md"),
    [string]$AzCommand = "az",
    [string]$FabricApiBaseUrl = "https://api.fabric.microsoft.com/v1",
    [int]$RetryCount = 4,
    [int]$RequestDelayMilliseconds = 350,
    [switch]$OnlyPartial
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$workspaceColumns = @(
    "workspace_name",
    "normalized_workspace_name",
    "environment",
    "workspace_type",
    "capacity_name",
    "capacity_id",
    "capacity_region",
    "capacity_assignment_progress",
    "domain_name",
    "domain_id",
    "owner",
    "admin_principals",
    "description",
    "source_system",
    "technical_id",
    "status",
    "notes"
)

$nodeColumns = @(
    "qualified_name",
    "display_name",
    "workspace_name",
    "item_type",
    "object_type",
    "source_system",
    "technical_id",
    "status",
    "notes"
)

function Get-FieldValue {
    param(
        [object]$Object,
        [string[]]$Names
    )

    if ($null -eq $Object) {
        return ""
    }

    foreach ($name in $Names) {
        if ($Object.PSObject.Properties.Name -contains $name) {
            $value = $Object.$name
            if ($null -ne $value) {
                return [string]$value
            }
        }
    }

    return ""
}

# NOTE: the example infix "Env_" (e.g. "_Env_Dev") stands for a typical
# workspace naming convention (something like
# "_<Organization>_<Environment>"). Adapt that infix (or drop it) to the
# workspace naming convention of your own tenant.
function Get-EnvironmentFromName {
    param([string]$Name)

    $rules = @(
        @{ Pattern = '\[(DEV|QA|PROD|PRO|PRE|UAT)\]\s*$'; Environment = '$1' },
        @{ Pattern = '[_\-\s](DEV|QA|PROD|PRO|PRE|UAT)\s*$'; Environment = '$1' },
        @{ Pattern = '[_\-](Env_)?(Dev|Pro|Pre|Qa)\s*$'; Environment = '$2' }
    )

    foreach ($rule in $rules) {
        if ($Name -match $rule.Pattern) {
            return $Matches[1].ToUpperInvariant()
        }
    }

    return "UNKNOWN"
}

function Get-NormalizedWorkspaceName {
    param([string]$Name)

    $normalized = $Name
    $normalized = $normalized -replace '\s*\[(DEV|QA|PROD|PRO|PRE|UAT)\]\s*$', ''
    $normalized = $normalized -replace '[_\-\s](DEV|QA|PROD|PRO|PRE|UAT)\s*$', ''
    $normalized = $normalized -replace '[_\-]Env_(Dev|Pro|Pre|Qa)\s*$', ''
    $normalized = $normalized -replace '[_\-](Dev|Pro|Pre|Qa)\s*$', ''
    return $normalized.Trim()
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
                $delaySeconds = [math]::Min(60, [math]::Pow(2, $attempt + 1))
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
        elseif ($result.payload.PSObject.Properties.Name -contains "domains") {
            $values += @($result.payload.domains)
        }
        elseif ($result.payload.PSObject.Properties.Name -contains "workspaces") {
            $values += @($result.payload.workspaces)
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

function Convert-AdminsToText {
    param([object[]]$RoleAssignments)

    $admins = @(
        $RoleAssignments |
            Where-Object { (Get-FieldValue -Object $_ -Names @("role")) -eq "Admin" } |
            ForEach-Object {
                $principal = $_.principal
                $displayName = Get-FieldValue -Object $principal -Names @("displayName")
                $principalType = Get-FieldValue -Object $principal -Names @("type")
                $upn = ""
                if ($principal.PSObject.Properties.Name -contains "userDetails") {
                    $upn = Get-FieldValue -Object $principal.userDetails -Names @("userPrincipalName")
                }

                if ($upn) {
                    "$displayName <$upn>"
                }
                elseif ($principalType) {
                    "$displayName ($principalType)"
                }
                else {
                    $displayName
                }
            } |
            Where-Object { $_ } |
            Sort-Object -Unique
    )

    return ($admins -join "; ")
}

function Set-UnresolvedEntry {
    param(
        [string]$Title,
        [string]$Status,
        [string]$Evidence,
        [string]$NextStep
    )

    Ensure-ParentDirectory -Path $UnresolvedPath
    if (-not (Test-Path $UnresolvedPath)) {
        "# Unresolved Items`n`n## Open Questions`n" | Set-Content -Path $UnresolvedPath -Encoding UTF8
    }

    $today = Get-Date -Format "yyyy-MM-dd"
    $markerName = (($Title.ToLowerInvariant() -replace "[^a-z0-9]+", "-").Trim("-"))
    $startMarker = "<!-- unresolved:${markerName}:start -->"
    $endMarker = "<!-- unresolved:${markerName}:end -->"
    $entry = @"

$startMarker

## $today - $Title

- Status: $Status
- Evidence: $Evidence
- Next step: $NextStep

$endMarker
"@

    $current = Get-Content -Path $UnresolvedPath -Raw
    $pattern = "(?s)$([regex]::Escape($startMarker)).*?$([regex]::Escape($endMarker))"

    if ($current -match $pattern) {
        Set-Content -Path $UnresolvedPath -Value ([regex]::Replace($current, $pattern, $entry)) -Encoding UTF8
    }
    else {
        Add-Content -Path $UnresolvedPath -Value $entry -Encoding UTF8
    }
}

if (-not (Test-Path $WorkspaceIndexPath)) {
    throw "Workspace index not found: $WorkspaceIndexPath"
}

$inputRows = @(Import-Csv -Path $WorkspaceIndexPath)
if ($inputRows.Count -eq 0) {
    throw "Workspace index has no rows: $WorkspaceIndexPath"
}

$token = Get-FreshAzureCliToken -Resource "https://api.fabric.microsoft.com" -AzCommand $AzCommand
$headers = @{
    Authorization = "Bearer $token"
    "Content-Type" = "application/json"
}

$capacityResult = Get-PagedFabricValues -Path "capacities" -Headers $headers
$capacityById = @{}
if ($capacityResult.succeeded) {
    foreach ($capacity in $capacityResult.values) {
        $capacityId = Get-FieldValue -Object $capacity -Names @("id")
        if ($capacityId) {
            $capacityById[$capacityId] = $capacity
        }
    }
}

$domainResult = Get-PagedFabricValues -Path "admin/domains" -Headers $headers -ValueProperty "domains"
$domainById = @{}
if ($domainResult.succeeded) {
    foreach ($domain in $domainResult.values) {
        $domainId = Get-FieldValue -Object $domain -Names @("id")
        if ($domainId) {
            $domainById[$domainId] = $domain
        }
    }
}

$roleAssignmentFailures = 0
$workspaceRows = @()
$nodeRows = @()

foreach ($row in ($inputRows | Sort-Object -Property workspace_name)) {
    $headers.Authorization = "Bearer $(Get-FreshAzureCliToken -Resource 'https://api.fabric.microsoft.com' -AzCommand $AzCommand)"
    if ($OnlyPartial -and (Get-FieldValue -Object $row -Names @("status")) -eq "normalized") {
        $workspaceRows += [pscustomobject]@{
            workspace_name = Get-FieldValue -Object $row -Names @("workspace_name")
            normalized_workspace_name = Get-FieldValue -Object $row -Names @("normalized_workspace_name")
            environment = Get-FieldValue -Object $row -Names @("environment")
            workspace_type = Get-FieldValue -Object $row -Names @("workspace_type")
            capacity_name = Get-FieldValue -Object $row -Names @("capacity_name")
            capacity_id = Get-FieldValue -Object $row -Names @("capacity_id")
            capacity_region = Get-FieldValue -Object $row -Names @("capacity_region")
            capacity_assignment_progress = Get-FieldValue -Object $row -Names @("capacity_assignment_progress")
            domain_name = Get-FieldValue -Object $row -Names @("domain_name")
            domain_id = Get-FieldValue -Object $row -Names @("domain_id")
            owner = Get-FieldValue -Object $row -Names @("owner")
            admin_principals = Get-FieldValue -Object $row -Names @("admin_principals")
            description = Get-FieldValue -Object $row -Names @("description")
            source_system = Get-FieldValue -Object $row -Names @("source_system")
            technical_id = Get-FieldValue -Object $row -Names @("technical_id")
            status = Get-FieldValue -Object $row -Names @("status")
            notes = Get-FieldValue -Object $row -Names @("notes")
        }

        $workspaceNameForNode = Get-FieldValue -Object $row -Names @("workspace_name")
        $nodeRows += [pscustomobject]@{
            qualified_name = $workspaceNameForNode
            display_name = $workspaceNameForNode
            workspace_name = $workspaceNameForNode
            item_type = "Workspace"
            object_type = "Workspace"
            source_system = Get-FieldValue -Object $row -Names @("source_system")
            technical_id = Get-FieldValue -Object $row -Names @("technical_id")
            status = Get-FieldValue -Object $row -Names @("status")
            notes = "Environment: $(Get-FieldValue -Object $row -Names @("environment")); Normalized name: $(Get-FieldValue -Object $row -Names @("normalized_workspace_name"))"
        }
        continue
    }

    $workspaceId = Get-FieldValue -Object $row -Names @("technical_id")
    $workspaceName = Get-FieldValue -Object $row -Names @("workspace_name")
    $detailsResult = Invoke-FabricGet -Path "workspaces/$workspaceId" -Headers $headers
    $details = if ($detailsResult.succeeded) { $detailsResult.payload } else { $null }

    $detailName = Get-FieldValue -Object $details -Names @("displayName", "name")
    if ($detailName) {
        $workspaceName = $detailName
    }

    $workspaceType = Get-FieldValue -Object $details -Names @("type")
    $capacityId = Get-FieldValue -Object $details -Names @("capacityId")
    $domainId = Get-FieldValue -Object $details -Names @("domainId")
    $capacityRegion = Get-FieldValue -Object $details -Names @("capacityRegion")
    $capacityAssignmentProgress = Get-FieldValue -Object $details -Names @("capacityAssignmentProgress")
    $description = Get-FieldValue -Object $details -Names @("description")

    $capacityName = ""
    if ($capacityId -and $capacityById.ContainsKey($capacityId)) {
        $capacityName = Get-FieldValue -Object $capacityById[$capacityId] -Names @("displayName", "name")
        if (-not $capacityRegion) {
            $capacityRegion = Get-FieldValue -Object $capacityById[$capacityId] -Names @("region")
        }
    }

    $domainName = ""
    if ($domainId -and $domainById.ContainsKey($domainId)) {
        $domainName = Get-FieldValue -Object $domainById[$domainId] -Names @("displayName", "name")
    }

    $roleResult = Get-PagedFabricValues -Path "workspaces/$workspaceId/roleAssignments" -Headers $headers
    $adminPrincipals = ""
    if ($roleResult.succeeded) {
        $adminPrincipals = Convert-AdminsToText -RoleAssignments $roleResult.values
    }
    else {
        $roleAssignmentFailures += 1
    }

    $notes = @()
    if (-not $detailsResult.succeeded) {
        $notes += "Workspace detail lookup failed: $($detailsResult.status_code) $($detailsResult.error)"
    }
    if ($capacityId -and -not $capacityName) {
        $notes += "Capacity ID found but capacity name unavailable."
    }
    if ($domainId -and -not $domainName) {
        $notes += "Domain ID found but domain name unavailable."
    }
    if (-not $roleResult.succeeded) {
        $notes += "Role assignments unavailable: $($roleResult.status_code) $($roleResult.error)"
    }

    $environment = Get-EnvironmentFromName -Name $workspaceName
    $normalizedWorkspaceName = Get-NormalizedWorkspaceName -Name $workspaceName
    $status = if ($detailsResult.succeeded) { "normalized" } else { "partial" }

    $workspaceRows += [pscustomobject]@{
        workspace_name = $workspaceName
        normalized_workspace_name = $normalizedWorkspaceName
        environment = $environment
        workspace_type = $workspaceType
        capacity_name = $capacityName
        capacity_id = $capacityId
        capacity_region = $capacityRegion
        capacity_assignment_progress = $capacityAssignmentProgress
        domain_name = $domainName
        domain_id = $domainId
        owner = $adminPrincipals
        admin_principals = $adminPrincipals
        description = $description
        source_system = "Fabric REST API via Azure CLI"
        technical_id = $workspaceId
        status = $status
        notes = ($notes -join " ")
    }

    $nodeRows += [pscustomobject]@{
        qualified_name = $workspaceName
        display_name = $workspaceName
        workspace_name = $workspaceName
        item_type = "Workspace"
        object_type = "Workspace"
        source_system = "Fabric REST API via Azure CLI"
        technical_id = $workspaceId
        status = $status
        notes = "Environment: $environment; Normalized name: $normalizedWorkspaceName"
    }
}

Ensure-ParentDirectory -Path $WorkspaceIndexPath
$workspaceRows |
    Select-Object -Property $workspaceColumns |
    Export-Csv -Path $WorkspaceIndexPath -NoTypeInformation -Encoding UTF8

Ensure-ParentDirectory -Path $NodesPath
$nodeRows |
    Select-Object -Property $nodeColumns |
    Export-Csv -Path $NodesPath -NoTypeInformation -Encoding UTF8

$openGaps = @()
if (-not $capacityResult.succeeded) {
    $openGaps += "Capacity list unavailable: $($capacityResult.status_code) $($capacityResult.error)"
}
if (-not $domainResult.succeeded) {
    $openGaps += "Domain list unavailable: $($domainResult.status_code) $($domainResult.error)"
}

$capacityNameMissingCount = @($workspaceRows | Where-Object { $_.capacity_id -and -not $_.capacity_name }).Count
$roleAssignmentUnavailableCount = @($workspaceRows | Where-Object { $_.notes -match "Role assignments unavailable" }).Count

if ($capacityNameMissingCount -gt 0) {
    $openGaps += "Capacity name unavailable for $capacityNameMissingCount workspaces with a capacity ID."
}
if ($roleAssignmentUnavailableCount -gt 0) {
    $openGaps += "Workspace role assignments unavailable for $roleAssignmentUnavailableCount workspaces."
}

if ($openGaps.Count -gt 0) {
    Set-UnresolvedEntry `
        -Title "Phase 2 workspace metadata gaps" `
        -Status "open" `
        -Evidence ($openGaps -join " ") `
        -NextStep "Use available workspace metadata for Phase 2 review; fill missing domain/capacity/admin fields from admin APIs only if the user approves and permissions are available."
}
else {
    Set-UnresolvedEntry `
        -Title "Phase 2 workspace metadata gaps" `
        -Status "resolved" `
        -Evidence "Workspace detail, capacity, domain, and role assignment metadata completed for all discovered workspaces." `
        -NextStep "User reviews Phase 2 output and approves Phase 3."
}

Write-Host "Phase 2 workspace normalization completed."
Write-Host "Workspaces normalized: $($workspaceRows.Count)"
Write-Host "Workspace nodes written: $($nodeRows.Count)"
Write-Host "Metadata gaps: $($openGaps.Count)"
Write-Host "Output: $WorkspaceIndexPath"
Write-Host "Nodes: $NodesPath"
