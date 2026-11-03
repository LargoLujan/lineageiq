# Phase 3 - Item inventory: for every workspace in $WorkspaceIndexPath,
# lists every Fabric item (Report, SemanticModel, Notebook, Lakehouse,
# DataPipeline, etc.) it contains, including tags. Read-only.
# Writes: $OutputPath (one row per item across the whole tenant/scope).
param(
    [string]$WorkspaceIndexPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$NodesPath = (Join-Path $PSScriptRoot "../../graph/nodes.csv"),
    [string]$UnresolvedPath = (Join-Path $PSScriptRoot "../../index/unresolved.md"),
    [string]$AzCommand = "az",
    [string]$FabricApiBaseUrl = "https://api.fabric.microsoft.com/v1",
    [int]$RetryCount = 5,
    [int]$RequestDelayMilliseconds = 400,
    [switch]$OnlyFailed,
    [string]$WorkspaceNameFilter = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$itemColumns = @(
    "workspace_name",
    "workspace_environment",
    "item_type",
    "item_name",
    "qualified_name",
    "folder_id",
    "description",
    "default_identity",
    "sensitivity_label",
    "tags",
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

function Normalize-Key {
    param([string]$Value)

    if (-not $Value) {
        return ""
    }

    return (($Value.Trim()).ToLowerInvariant() -replace "\s+", " ")
}

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

function Convert-PrincipalToText {
    param([object]$Principal)

    if ($null -eq $Principal) {
        return ""
    }

    $displayName = Get-FieldValue -Object $Principal -Names @("displayName")
    $principalType = Get-FieldValue -Object $Principal -Names @("type")

    if ($Principal.PSObject.Properties.Name -contains "userDetails") {
        $upn = Get-FieldValue -Object $Principal.userDetails -Names @("userPrincipalName")
        if ($upn) {
            return "$displayName <$upn>"
        }
    }

    if ($principalType) {
        return "$displayName ($principalType)"
    }

    return $displayName
}

function Convert-SensitivityLabelToText {
    param([object]$SensitivityLabel)

    if ($null -eq $SensitivityLabel) {
        return ""
    }

    $displayName = Get-FieldValue -Object $SensitivityLabel -Names @("displayName", "name")
    $labelId = Get-FieldValue -Object $SensitivityLabel -Names @("id")

    if ($displayName -and $labelId) {
        return "$displayName ($labelId)"
    }
    if ($displayName) {
        return $displayName
    }
    return $labelId
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

    $matchingWorkspaceCount = @($workspaceRows | Where-Object { $workspaceFilterSet.ContainsKey((Normalize-Key (Get-FieldValue -Object $_ -Names @("workspace_name")))) }).Count
    if ($matchingWorkspaceCount -eq 0) {
        throw "WorkspaceNameFilter '$WorkspaceNameFilter' did not match any row in $WorkspaceIndexPath."
    }
}

$previousItemRows = @()
if (($OnlyFailed -or $workspaceFilterSet) -and (Test-Path $OutputPath)) {
    $previousItemRows = @(Import-Csv -Path $OutputPath)
}

$previousSuccessfulWorkspaceNames = @{}
foreach ($item in $previousItemRows | Where-Object { $_.status -eq "discovered" }) {
    $previousSuccessfulWorkspaceNames[$item.workspace_name] = $true
}

$token = Get-FreshAzureCliToken -Resource "https://api.fabric.microsoft.com" -AzCommand $AzCommand
$headers = @{
    Authorization = "Bearer $token"
    "Content-Type" = "application/json"
}

$itemRows = @()
$workspaceFailures = @()
$emptyWorkspaceCount = 0

foreach ($workspace in ($workspaceRows | Sort-Object -Property workspace_name)) {
    $headers.Authorization = "Bearer $(Get-FreshAzureCliToken -Resource 'https://api.fabric.microsoft.com' -AzCommand $AzCommand)"
    $workspaceName = Get-FieldValue -Object $workspace -Names @("workspace_name")
    $workspaceId = Get-FieldValue -Object $workspace -Names @("technical_id")
    $workspaceEnvironment = Get-FieldValue -Object $workspace -Names @("environment")

    $retainFromPrevious = $false
    if ($OnlyFailed -and $previousSuccessfulWorkspaceNames.ContainsKey($workspaceName)) {
        $retainFromPrevious = $true
    }
    if ($workspaceFilterSet -and -not $workspaceFilterSet.ContainsKey((Normalize-Key $workspaceName))) {
        $retainFromPrevious = $true
    }

    if ($retainFromPrevious) {
        $itemRows += @($previousItemRows | Where-Object { $_.workspace_name -eq $workspaceName })
        continue
    }

    $result = Get-PagedFabricValues `
        -Path "workspaces/$workspaceId/items?include=DefaultIdentity" `
        -Headers $headers

    if (-not $result.succeeded) {
        $workspaceFailures += [pscustomobject]@{
            workspace_name = $workspaceName
            status_code = $result.status_code
            error = $result.error
        }

        $itemRows += [pscustomobject]@{
            workspace_name = $workspaceName
            workspace_environment = $workspaceEnvironment
            item_type = ""
            item_name = ""
            qualified_name = $workspaceName
            folder_id = ""
            description = ""
            default_identity = ""
            sensitivity_label = ""
            source_system = "Fabric REST API via Azure CLI"
            technical_id = ""
            status = "workspace_items_unavailable"
            notes = "Item list failed: $($result.status_code) $($result.error)"
        }
        continue
    }

    $items = @($result.values)
    if ($items.Count -eq 0) {
        $emptyWorkspaceCount += 1
    }

    foreach ($item in $items) {
        $itemName = Get-FieldValue -Object $item -Names @("displayName", "name")
        $itemType = Get-FieldValue -Object $item -Names @("type")
        $itemId = Get-FieldValue -Object $item -Names @("id")
        $folderId = Get-FieldValue -Object $item -Names @("folderId")
        $description = Get-FieldValue -Object $item -Names @("description")
        $defaultIdentityObject = $null
        if ($item.PSObject.Properties.Name -contains "defaultIdentity") {
            $defaultIdentityObject = $item.defaultIdentity
        }

        $sensitivityLabelObject = $null
        if ($item.PSObject.Properties.Name -contains "sensitivityLabel") {
            $sensitivityLabelObject = $item.sensitivityLabel
        }

        # Already present on the same items-list response the rest of this
        # loop reads -- no extra API call. Unused tenant-wide as of 2026-07
        # (every item checked came back empty), but free to capture now so
        # it's already flowing the moment someone starts tagging items.
        $tagsText = ""
        if ($item.PSObject.Properties.Name -contains "tags" -and $item.tags) {
            $tagsText = ((@($item.tags) | ForEach-Object { Get-FieldValue -Object $_ -Names @("displayName") }) | Where-Object { $_ }) -join "; "
        }

        $defaultIdentity = Convert-PrincipalToText -Principal $defaultIdentityObject
        $sensitivityLabel = Convert-SensitivityLabelToText -SensitivityLabel $sensitivityLabelObject
        $qualifiedName = "$workspaceName / $itemType / $itemName"

        $itemRows += [pscustomobject]@{
            workspace_name = $workspaceName
            workspace_environment = $workspaceEnvironment
            item_type = $itemType
            item_name = $itemName
            qualified_name = $qualifiedName
            folder_id = $folderId
            description = $description
            default_identity = $defaultIdentity
            sensitivity_label = $sensitivityLabel
            tags = $tagsText
            source_system = "Fabric REST API via Azure CLI"
            technical_id = $itemId
            status = "discovered"
            notes = ""
        }
    }
}

$duplicateQualifiedNames = @(
    $itemRows |
        Where-Object { $_.status -eq "discovered" } |
        Group-Object -Property qualified_name |
        Where-Object { $_.Count -gt 1 }
)

if ($duplicateQualifiedNames.Count -gt 0) {
    foreach ($group in $duplicateQualifiedNames) {
        foreach ($row in $group.Group) {
            $row.notes = (($row.notes, "Duplicate qualified name in workspace/type/name; technical_id disambiguates metadata only.") -join " ").Trim()
        }
    }
}

Ensure-ParentDirectory -Path $OutputPath
$itemRows |
    Select-Object -Property $itemColumns |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

$workspaceNodeRows = @()
if (Test-Path $NodesPath) {
    $workspaceNodeRows = @(
        Import-Csv -Path $NodesPath |
            Where-Object { $_.item_type -eq "Workspace" }
    )
}

$itemNodeRows = @(
    $itemRows |
        Where-Object { $_.status -eq "discovered" } |
        ForEach-Object {
            [pscustomobject]@{
                qualified_name = $_.qualified_name
                display_name = $_.item_name
                workspace_name = $_.workspace_name
                item_type = $_.item_type
                object_type = "Item"
                source_system = $_.source_system
                technical_id = $_.technical_id
                status = $_.status
                notes = "Environment: $($_.workspace_environment); Folder ID: $($_.folder_id)"
            }
        }
)

Ensure-ParentDirectory -Path $NodesPath
@($workspaceNodeRows + $itemNodeRows) |
    Select-Object -Property $nodeColumns |
    Export-Csv -Path $NodesPath -NoTypeInformation -Encoding UTF8

$openGaps = @()
if ($workspaceFailures.Count -gt 0) {
    $failedNames = (($workspaceFailures | Select-Object -First 20 | ForEach-Object { "$($_.workspace_name) [$($_.status_code)]" }) -join "; ")
    $openGaps += "Item listing unavailable for $($workspaceFailures.Count) workspaces. First failures: $failedNames"
}
if ($duplicateQualifiedNames.Count -gt 0) {
    $openGaps += "Duplicate item qualified names found: $($duplicateQualifiedNames.Count)."
}

if ($openGaps.Count -gt 0) {
    Set-UnresolvedEntry `
        -Title "Phase 3 item inventory gaps" `
        -Status "open" `
        -Evidence ($openGaps -join " ") `
        -NextStep "Retry failed workspaces with backend/scripts/03_discover_items.ps1 -OnlyFailed, or resolve duplicate item names during graph review."
}
else {
    Set-UnresolvedEntry `
        -Title "Phase 3 item inventory gaps" `
        -Status "resolved" `
        -Evidence "Item inventory completed for all workspaces without duplicate qualified names." `
        -NextStep "User reviews Phase 3 output and approves Phase 4."
}

$discoveredCount = @($itemRows | Where-Object { $_.status -eq "discovered" }).Count

Write-Host "Phase 3 item inventory completed."
if ($workspaceFilterSet) {
    Write-Host "Workspace filter: $WorkspaceNameFilter (other workspaces retained unchanged from $OutputPath)"
}
Write-Host "Workspaces scanned: $($workspaceRows.Count)"
Write-Host "Items discovered: $discoveredCount"
Write-Host "Empty workspaces: $emptyWorkspaceCount"
Write-Host "Workspace item-list failures: $($workspaceFailures.Count)"
Write-Host "Duplicate qualified names: $($duplicateQualifiedNames.Count)"
Write-Host "Output: $OutputPath"
Write-Host "Nodes: $NodesPath"
