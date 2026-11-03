# Phase 51 - Notebook definition download: fetches every Notebook's raw
# getDefinition payload (in $DefinitionFormat, default fabricGitSource) and
# writes the decoded .ipynb/source files to disk, feeding
# 52_build_notebook_super_lineage.py's deep static-analysis pass (which
# needs the actual notebook cell source, not just a JSON summary).
# Writes: files under $OutputDirectory, $ManifestPath (one row per notebook).
param(
    [string]$WorkspaceIndexPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "../../data/notebook_definitions"),
    [string]$ManifestPath = (Join-Path $PSScriptRoot "../../analysis/notebook_definition_download_manifest.csv"),
    [string]$AzCommand = "az",
    [string]$FabricApiBaseUrl = "https://api.fabric.microsoft.com/v1",
    [int]$MaxItems = 0,
    [int]$RetryCount = 5,
    [int]$RequestDelayMilliseconds = 250,
    [int]$MaxOperationPolls = 20,
    [int]$MaxOperationDelaySeconds = 15,
    [int]$ProgressInterval = 20,
    [string]$DefinitionFormat = "fabricGitSource",
    [string]$ItemQualifiedName = "",
    [string]$WorkspaceNameFilter = "",
    [switch]$MergeManifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

function Ensure-Directory {
    param([string]$Path)
    if ($Path -and -not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
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

function Limit-Text {
    param([string]$Text, [int]$MaxLength = 900)
    if (-not $Text) { return "" }
    $clean = ($Text -replace "\s+", " ").Trim()
    if ($clean.Length -le $MaxLength) { return $clean }
    return $clean.Substring(0, $MaxLength - 3) + "..."
}

function Get-FabricErrorText {
    param([object]$Response)
    $payload = Convert-JsonContent -Content $Response.content
    if ($payload) {
        $code = Get-FieldValue -Object $payload -Names @("errorCode", "code")
        $message = Get-FieldValue -Object $payload -Names @("message")
        if ($code -or $message) { return Limit-Text -Text "$code $message" }
    }
    if ($Response.error) { return Limit-Text -Text $Response.error }
    return Limit-Text -Text $Response.content
}

function New-FabricHeaders {
    # Get-FreshAzureCliToken (LineageCommon.psm1) proactively refreshes if
    # the cached token is stale; Invoke-FabricWebRequestCore also reacts to
    # an actual 401 TokenExpired directly (see its header comment).
    $token = Get-FreshAzureCliToken -Resource "https://api.fabric.microsoft.com" -AzCommand $AzCommand
    return @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
}

# Thin wrapper: the real retry/refresh logic lives once in
# Invoke-FabricWebRequestCore (LineageCommon.psm1).
function Invoke-FabricWebRequest {
    param(
        [ValidateSet("Get", "Post")][string]$Method,
        [string]$Path,
        [hashtable]$Headers
    )
    return Invoke-FabricWebRequestCore -Method $Method -Path $Path -Headers $Headers `
        -BaseUrl $FabricApiBaseUrl -RetryCount $RetryCount `
        -RequestDelayMilliseconds $RequestDelayMilliseconds -AzCommand $AzCommand
}

function Get-NotebookDefinition {
    param([string]$WorkspaceId, [string]$ItemId, [hashtable]$Headers, [string]$Format = "fabricGitSource")
    $formatSuffix = if ($Format) { "?format=$Format" } else { "" }
    $path = "workspaces/$WorkspaceId/items/$ItemId/getDefinition$formatSuffix"
    $response = Invoke-FabricWebRequest -Method Post -Path $path -Headers $Headers
    if ($response.status_code -eq 200) {
        return [pscustomobject]@{ succeeded = $true; payload = (Convert-JsonContent -Content $response.content); status_code = 200; error = ""; lro = $false }
    }
    if ($response.status_code -ne 202) {
        return [pscustomobject]@{ succeeded = $false; payload = $null; status_code = $response.status_code; error = if ($response.error) { $response.error } else { Get-FabricErrorText -Response $response }; lro = $false }
    }

    $operationId = Get-HeaderValue -Headers $response.headers -Name "x-ms-operation-id"
    if (-not $operationId) {
        $location = Get-HeaderValue -Headers $response.headers -Name "Location"
        $match = [regex]::Match($location, "[0-9a-fA-F-]{36}")
        if ($match.Success) { $operationId = $match.Value }
    }
    if (-not $operationId) {
        return [pscustomobject]@{ succeeded = $false; payload = $null; status_code = 202; error = "LRO accepted but no operation id was returned."; lro = $true }
    }

    for ($poll = 1; $poll -le $MaxOperationPolls; $poll++) {
        $retryAfter = Get-HeaderValue -Headers $response.headers -Name "Retry-After"
        $delaySeconds = if ($retryAfter -match "^\d+$") { [int]$retryAfter } else { 2 }
        Start-Sleep -Seconds ([math]::Min($delaySeconds, $MaxOperationDelaySeconds))
        $stateResponse = Invoke-FabricWebRequest -Method Get -Path "operations/$operationId" -Headers $Headers
        if (-not $stateResponse.succeeded) {
            return [pscustomobject]@{ succeeded = $false; payload = $null; status_code = $stateResponse.status_code; error = (Get-FabricErrorText -Response $stateResponse); lro = $true }
        }
        $statePayload = Convert-JsonContent -Content $stateResponse.content
        $status = Get-FieldValue -Object $statePayload -Names @("status")
        if ($status -eq "Succeeded") {
            $resultResponse = Invoke-FabricWebRequest -Method Get -Path "operations/$operationId/result" -Headers $Headers
            if ($resultResponse.succeeded) {
                return [pscustomobject]@{ succeeded = $true; payload = (Convert-JsonContent -Content $resultResponse.content); status_code = $resultResponse.status_code; error = ""; lro = $true }
            }
            return [pscustomobject]@{ succeeded = $false; payload = $null; status_code = $resultResponse.status_code; error = (Get-FabricErrorText -Response $resultResponse); lro = $true }
        }
        if ($status -eq "Failed") {
            return [pscustomobject]@{ succeeded = $false; payload = $null; status_code = $stateResponse.status_code; error = "LRO failed. $(Get-FabricErrorText -Response $stateResponse)"; lro = $true }
        }
        $response = $stateResponse
    }
    return [pscustomobject]@{ succeeded = $false; payload = $null; status_code = 202; error = "LRO did not complete after $MaxOperationPolls polls."; lro = $true }
}

function Decode-DefinitionParts {
    param([object]$DefinitionPayload)
    $parts = @()
    if (-not $DefinitionPayload -or -not ($DefinitionPayload.PSObject.Properties.Name -contains "definition")) { return $parts }
    $definition = $DefinitionPayload.definition
    if (-not ($definition.PSObject.Properties.Name -contains "parts")) { return $parts }
    foreach ($part in @($definition.parts)) {
        $path = Get-FieldValue -Object $part -Names @("path")
        $payload = Get-FieldValue -Object $part -Names @("payload")
        $payloadType = Get-FieldValue -Object $part -Names @("payloadType")
        if ($payloadType -ne "InlineBase64" -or -not $payload) { continue }
        try {
            $normalizedPayload = $payload.Trim()
            $padding = $normalizedPayload.Length % 4
            if ($padding -eq 2) { $normalizedPayload += "==" }
            elseif ($padding -eq 3) { $normalizedPayload += "=" }
            $bytes = [Convert]::FromBase64String($normalizedPayload)
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            $parts += [pscustomobject]@{ path = $path; text = $text; bytes = $bytes.Length }
        }
        catch {
            $parts += [pscustomobject]@{ path = $path; text = ""; bytes = 0 }
        }
    }
    return $parts
}

function Get-SafePathSegment {
    param([string]$Value)
    if (-not $Value) { return "_blank" }
    $safe = ($Value -replace '[<>:"/\\|?*]', "_").Trim()
    $safe = ($safe -replace "\s+", " ")
    if ($safe.Length -gt 140) { $safe = $safe.Substring(0, 140).Trim() }
    if (-not $safe) { return "_blank" }
    return $safe
}

foreach ($path in @($WorkspaceIndexPath, $ItemsPath)) {
    if (-not (Test-Path $path)) { throw "Required input not found: $path" }
}
Ensure-Directory -Path $OutputDirectory
Ensure-ParentDirectory -Path $ManifestPath

$workspaces = @(Import-Csv -Path $WorkspaceIndexPath)
$items = @(Import-Csv -Path $ItemsPath | Where-Object { $_.status -eq "discovered" -and $_.item_type -eq "Notebook" })
if ($ItemQualifiedName) {
    $items = @($items | Where-Object { $_.qualified_name -eq $ItemQualifiedName })
}
if ($WorkspaceNameFilter) {
    $items = @($items | Where-Object { $_.workspace_name -eq $WorkspaceNameFilter })
}
if ($MaxItems -gt 0) { $items = @($items | Select-Object -First $MaxItems) }

$workspaceIdByName = @{}
foreach ($workspace in $workspaces) {
    $workspaceIdByName[$workspace.workspace_name] = $workspace.technical_id
}

$headers = New-FabricHeaders
$manifestRows = [System.Collections.Generic.List[object]]::new()
$processed = 0
$successCount = 0
$partCount = 0

foreach ($item in $items) {
    $processed += 1
    if ($ProgressInterval -gt 0 -and ($processed % $ProgressInterval -eq 0)) {
        Write-Host "Downloaded $processed / $($items.Count) notebook definitions..."
    }

    $workspaceId = if ($workspaceIdByName.ContainsKey($item.workspace_name)) { $workspaceIdByName[$item.workspace_name] } else { "" }
    $notebookDir = Join-Path $OutputDirectory (Join-Path (Get-SafePathSegment $item.workspace_name) "$(Get-SafePathSegment $item.item_name).Notebook")
    Ensure-Directory -Path $notebookDir

    if (-not $workspaceId) {
        $manifestRows.Add([pscustomobject]@{ workspace_name = $item.workspace_name; item_name = $item.item_name; item_qualified_name = $item.qualified_name; technical_id = $item.technical_id; status = "failed"; status_code = ""; part_count = 0; total_bytes = 0; output_directory = $notebookDir; part_paths = ""; error = "Workspace id missing."; downloaded_at = (Get-Date).ToString("s") }) | Out-Null
        continue
    }

    $result = Get-NotebookDefinition -WorkspaceId $workspaceId -ItemId $item.technical_id -Headers $headers -Format $DefinitionFormat
    if (-not $result.succeeded -and [string]$result.status_code -eq "401" -and $result.error -match '(?i)TokenExpired|Access token has expired') {
        $headers = New-FabricHeaders
        $result = Get-NotebookDefinition -WorkspaceId $workspaceId -ItemId $item.technical_id -Headers $headers -Format $DefinitionFormat
    }
    if (-not $result.succeeded) {
        $manifestRows.Add([pscustomobject]@{ workspace_name = $item.workspace_name; item_name = $item.item_name; item_qualified_name = $item.qualified_name; technical_id = $item.technical_id; status = "failed"; status_code = $result.status_code; part_count = 0; total_bytes = 0; output_directory = $notebookDir; part_paths = ""; error = $result.error; downloaded_at = (Get-Date).ToString("s") }) | Out-Null
        continue
    }

    $parts = @(Decode-DefinitionParts -DefinitionPayload $result.payload)
    $writtenPartPaths = [System.Collections.Generic.List[string]]::new()
    $totalBytes = 0
    foreach ($part in $parts) {
        $relativePath = if ($part.path) { $part.path } else { "part-$($writtenPartPaths.Count + 1).txt" }
        $safeRelativePath = ($relativePath -replace '^[\\/]+', '') -replace '[<>:"|?*]', "_"
        $targetPath = Join-Path $notebookDir $safeRelativePath
        Ensure-ParentDirectory -Path $targetPath
        Set-Content -Path $targetPath -Value $part.text -Encoding UTF8
        $writtenPartPaths.Add($targetPath) | Out-Null
        $totalBytes += [int]$part.bytes
    }

    $successCount += 1
    $partCount += $parts.Count
    $manifestRows.Add([pscustomobject]@{
        workspace_name = $item.workspace_name
        item_name = $item.item_name
        item_qualified_name = $item.qualified_name
        technical_id = $item.technical_id
        status = "downloaded"
        status_code = $result.status_code
        part_count = $parts.Count
        total_bytes = $totalBytes
        output_directory = $notebookDir
        part_paths = ($writtenPartPaths.ToArray() -join "; ")
        error = ""
        downloaded_at = (Get-Date).ToString("s")
    }) | Out-Null
}

$outputManifestRows = @($manifestRows)
if ($MergeManifest -and (Test-Path $ManifestPath)) {
    $updatedItems = @{}
    foreach ($row in $manifestRows) {
        $updatedItems[$row.item_qualified_name] = $true
    }
    $existingRows = @(Import-Csv -Path $ManifestPath | Where-Object { -not $updatedItems.ContainsKey($_.item_qualified_name) })
    $outputManifestRows = @($existingRows + $manifestRows)
}
$outputManifestRows | Export-Csv -Path $ManifestPath -NoTypeInformation -Encoding UTF8

Write-Host "Notebook definition download completed."
Write-Host "Target notebooks: $($items.Count)"
Write-Host "Definitions downloaded: $successCount"
Write-Host "Definition parts written: $partCount"
Write-Host "Output directory: $OutputDirectory"
Write-Host "Manifest: $ManifestPath"
