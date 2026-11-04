# Phase 4 - Item analysis: the deepest, slowest, most valuable pass in the
# whole pipeline. For every item, calls the Fabric Connections API and (per
# $DefinitionItemTypes) the getDefinition API, decodes definition parts for
# embedded GUIDs/table references, and registers dependency edges with a
# confidence level (confirmed/likely) and evidence. Also runs the
# Lakehouse<->SQLEndpoint confirmed-pairing lookup and OneLake shortcut
# discovery. Policy is maximum depth by default (see $DefinitionItemTypes
# below) since this runs on a weekly cadence, not interactively --
# -SkipReportDefinitions exists only for a quick local test run.
# Reads: $ItemsPath. Writes: $OutputPath, $DependenciesPath, graph nodes/edges.
param(
    [string]$WorkspaceIndexPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "../../index/item_analysis.csv"),
    [string]$DependenciesPath = (Join-Path $PSScriptRoot "../../index/dependencies.csv"),
    [string]$VariableLibraryCatalogPath = (Join-Path $PSScriptRoot "../../analysis/variable_library_catalog.csv"),
    [string]$NodesPath = (Join-Path $PSScriptRoot "../../graph/nodes.csv"),
    [string]$EdgesPath = (Join-Path $PSScriptRoot "../../graph/edges.csv"),
    [string]$UnresolvedPath = (Join-Path $PSScriptRoot "../../index/unresolved.md"),
    [string]$AzCommand = "az",
    [string]$FabricApiBaseUrl = "https://api.fabric.microsoft.com/v1",
    [int]$RetryCount = 5,
    [int]$RequestDelayMilliseconds = 250,
    [int]$MaxOperationPolls = 20,
    [int]$MaxOperationDelaySeconds = 15,
    [int]$MaxItems = 0,
    [string[]]$DefinitionItemTypes = @(
        "DataPipeline",
        "CopyJob",
        "Dataflow",
        "Eventstream",
        "Reflex",
        "GraphQLApi",
        "KQLQueryset",
        "KQLDashboard",
        "UserDataFunction",
        "VariableLibrary",
        # Report/PaginatedReport definitions are async (LRO, ~15-20s per item
        # once capped by MaxOperationDelaySeconds) and there are ~915
        # Reports + ~71 PaginatedReports tenant-wide, so this does add real
        # time to a full scan -- accepted deliberately (weekly cadence, not
        # per-request) in exchange for a real, definition-verified
        # "confirmed" edge (via the generic decoded-GUID match below) for
        # every report whose definition.pbir/RDL embeds its semantic
        # model's id, replacing the name-based pairing heuristic entirely
        # instead of only for the reports this happens to catch.
        "Report",
        "PaginatedReport"
    ),
    [int]$ProgressInterval = 25,
    [switch]$SkipConnections,
    [switch]$SkipDefinitions,
    # Opt-out, not opt-in: the project's policy is maximum depth by
    # default (weekly scan cadence, not interactive), so Report/
    # PaginatedReport definitions are in $DefinitionItemTypes above unless
    # this is explicitly set for a quick/local test run.
    [switch]$SkipReportDefinitions,
    [string]$WorkspaceNameFilter = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

if ($SkipReportDefinitions) {
    $DefinitionItemTypes = @($DefinitionItemTypes | Where-Object { $_ -ne "Report" -and $_ -ne "PaginatedReport" })
}

$analysisColumns = @(
    "workspace_name",
    "item_type",
    "item_name",
    "qualified_name",
    "analysis_status",
    "reads_from",
    "writes_to",
    "executes",
    "refreshes",
    "serves",
    "source_system",
    "evidence",
    "confidence",
    "notes"
)

$dependencyColumns = @(
    "from_qualified_name",
    "to_qualified_name",
    "relationship_type",
    "source_system",
    "evidence",
    "confidence",
    "notes"
)

# A VariableLibrary's definition was already being fetched and
# decoded (it's in $DefinitionItemTypes below) purely to regex-scan it for
# embedded item-id GUIDs like every other definition type -- the actual
# variables (name/type/value) inside got thrown away afterwards. Real
# schema confirmed live against 2 tenant items (variables.json:
# name/note/type/value, value shaped per type -- {itemId,workspaceId} for
# ItemReference, a plain scalar otherwise; settings.json: valueSetsOrder;
# valueSets/<Name>.json: name + variableOverrides). No new API call needed.
$variableLibraryColumns = @(
    "workspace_name",
    "item_name",
    "qualified_name",
    "variable_name",
    "variable_type",
    "value_set_name",
    "variable_value",
    "resolved_item_qualified_name",
    "variable_note",
    "captured_at"
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

function Limit-Text {
    param(
        [string]$Text,
        [int]$MaxLength = 300
    )

    if (-not $Text) {
        return ""
    }

    $clean = ($Text -replace "\s+", " ").Trim()
    if ($clean.Length -le $MaxLength) {
        return $clean
    }

    return $clean.Substring(0, $MaxLength - 3) + "..."
}

function Add-UniqueListValue {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Value
    )

    if ($Value -and -not $List.Contains($Value)) {
        $List.Add($Value) | Out-Null
    }
}

function Convert-ListToText {
    param([System.Collections.Generic.List[string]]$List)

    if ($null -eq $List -or $List.Count -eq 0) {
        return ""
    }

    return (@($List | Sort-Object -Unique) -join "; ")
}

function Get-FabricErrorText {
    param([object]$Response)

    $payload = Convert-JsonContent -Content $Response.content
    if ($payload) {
        $code = Get-FieldValue -Object $payload -Names @("errorCode", "code")
        $message = Get-FieldValue -Object $payload -Names @("message")
        if ($code -or $message) {
            return (Limit-Text -Text "$code $message" -MaxLength 500)
        }
    }

    return Limit-Text -Text $Response.content -MaxLength 500
}

# Thin wrapper: the real retry/refresh logic lives once in
# Invoke-FabricWebRequestCore (LineageCommon.psm1), including the reactive
# 401-refresh-and-retry that keeps long tenant-wide runs healthy (see that
# function's header comment). This just forwards this script's own
# -BaseUrl/-RetryCount/-RequestDelayMilliseconds/-AzCommand so none of the
# call sites below needed to change.
function Invoke-FabricWebRequest {
    param(
        [ValidateSet("Get", "Post")]
        [string]$Method,
        [string]$Path,
        [hashtable]$Headers
    )

    return Invoke-FabricWebRequestCore -Method $Method -Path $Path -Headers $Headers `
        -BaseUrl $FabricApiBaseUrl -RetryCount $RetryCount `
        -RequestDelayMilliseconds $RequestDelayMilliseconds -AzCommand $AzCommand
}

function Get-PagedItemConnections {
    param(
        [string]$WorkspaceId,
        [string]$ItemId,
        [hashtable]$Headers
    )

    $values = @()
    $nextPath = "workspaces/$WorkspaceId/items/$ItemId/connections"

    while ($nextPath) {
        $response = Invoke-FabricWebRequest -Method Get -Path $nextPath -Headers $Headers
        if (-not $response.succeeded) {
            return [pscustomobject]@{
                succeeded = $false
                values = @()
                status_code = $response.status_code
                error = if ($response.error) { $response.error } else { Get-FabricErrorText -Response $response }
            }
        }

        $payload = Convert-JsonContent -Content $response.content
        if ($payload -and $payload.PSObject.Properties.Name -contains "value") {
            $values += @($payload.value)
        }

        if ($payload -and $payload.PSObject.Properties.Name -contains "continuationUri" -and $payload.continuationUri) {
            $nextPath = [string]$payload.continuationUri
        }
        elseif ($payload -and $payload.PSObject.Properties.Name -contains "continuationToken" -and $payload.continuationToken) {
            $nextPath = "workspaces/$WorkspaceId/items/$ItemId/connections?continuationToken=$([uri]::EscapeDataString([string]$payload.continuationToken))"
        }
        else {
            $nextPath = ""
        }
    }

    return [pscustomobject]@{
        succeeded = $true
        values = $values
        status_code = 200
        error = ""
    }
}

function Get-DefinitionPath {
    param(
        [string]$WorkspaceId,
        [string]$ItemId,
        [string]$ItemType
    )

    $path = "workspaces/$WorkspaceId/items/$ItemId/getDefinition"
    if ($ItemType -eq "SemanticModel") {
        return "$path`?format=TMDL"
    }
    if ($ItemType -eq "Notebook") {
        return "$path`?format=fabricGitSource"
    }

    return $path
}

function Get-ItemDefinition {
    param(
        [string]$WorkspaceId,
        [string]$ItemId,
        [string]$ItemType,
        [hashtable]$Headers
    )

    $path = Get-DefinitionPath -WorkspaceId $WorkspaceId -ItemId $ItemId -ItemType $ItemType
    $response = Invoke-FabricWebRequest -Method Post -Path $path -Headers $Headers

    if ($response.status_code -eq 200) {
        return [pscustomobject]@{
            succeeded = $true
            payload = (Convert-JsonContent -Content $response.content)
            status_code = 200
            error = ""
            lro = $false
        }
    }

    if ($response.status_code -ne 202) {
        return [pscustomobject]@{
            succeeded = $false
            payload = $null
            status_code = $response.status_code
            error = if ($response.error) { $response.error } else { Get-FabricErrorText -Response $response }
            lro = $false
        }
    }

    $operationId = Get-HeaderValue -Headers $response.headers -Name "x-ms-operation-id"
    if (-not $operationId) {
        $location = Get-HeaderValue -Headers $response.headers -Name "Location"
        $match = [regex]::Match($location, "[0-9a-fA-F-]{36}")
        if ($match.Success) {
            $operationId = $match.Value
        }
    }

    if (-not $operationId) {
        return [pscustomobject]@{
            succeeded = $false
            payload = $null
            status_code = 202
            error = "LRO accepted but no operation id was returned."
            lro = $true
        }
    }

    for ($poll = 1; $poll -le $MaxOperationPolls; $poll++) {
        $retryAfter = Get-HeaderValue -Headers $response.headers -Name "Retry-After"
        $delaySeconds = if ($retryAfter -match "^\d+$") { [int]$retryAfter } else { 2 }
        if ($MaxOperationDelaySeconds -gt 0) {
            $delaySeconds = [math]::Min($delaySeconds, $MaxOperationDelaySeconds)
        }
        Start-Sleep -Seconds $delaySeconds

        $stateResponse = Invoke-FabricWebRequest -Method Get -Path "operations/$operationId" -Headers $Headers
        if (-not $stateResponse.succeeded) {
            return [pscustomobject]@{
                succeeded = $false
                payload = $null
                status_code = $stateResponse.status_code
                error = if ($stateResponse.error) { $stateResponse.error } else { Get-FabricErrorText -Response $stateResponse }
                lro = $true
            }
        }

        $statePayload = Convert-JsonContent -Content $stateResponse.content
        $status = Get-FieldValue -Object $statePayload -Names @("status")

        if ($status -eq "Succeeded") {
            $resultResponse = Invoke-FabricWebRequest -Method Get -Path "operations/$operationId/result" -Headers $Headers
            if ($resultResponse.succeeded) {
                return [pscustomobject]@{
                    succeeded = $true
                    payload = (Convert-JsonContent -Content $resultResponse.content)
                    status_code = $resultResponse.status_code
                    error = ""
                    lro = $true
                }
            }

            return [pscustomobject]@{
                succeeded = $false
                payload = $null
                status_code = $resultResponse.status_code
                error = if ($resultResponse.error) { $resultResponse.error } else { Get-FabricErrorText -Response $resultResponse }
                lro = $true
            }
        }

        if ($status -eq "Failed") {
            $errorText = Get-FabricErrorText -Response $stateResponse
            return [pscustomobject]@{
                succeeded = $false
                payload = $null
                status_code = $stateResponse.status_code
                error = "LRO failed. $errorText"
                lro = $true
            }
        }

        $response = $stateResponse
    }

    return [pscustomobject]@{
        succeeded = $false
        payload = $null
        status_code = 202
        error = "LRO did not complete after $MaxOperationPolls polls."
        lro = $true
    }
}

function Decode-DefinitionParts {
    param([object]$DefinitionPayload)

    $parts = @()
    if (-not $DefinitionPayload) {
        return $parts
    }

    if (-not ($DefinitionPayload.PSObject.Properties.Name -contains "definition")) {
        return $parts
    }

    $definition = $DefinitionPayload.definition
    if (-not ($definition.PSObject.Properties.Name -contains "parts")) {
        return $parts
    }

    foreach ($part in @($definition.parts)) {
        $path = Get-FieldValue -Object $part -Names @("path")
        $payload = Get-FieldValue -Object $part -Names @("payload")
        $payloadType = Get-FieldValue -Object $part -Names @("payloadType")

        if ($payloadType -ne "InlineBase64" -or -not $payload) {
            continue
        }

        try {
            $normalizedPayload = $payload.Trim()
            $padding = $normalizedPayload.Length % 4
            if ($padding -eq 2) {
                $normalizedPayload += "=="
            }
            elseif ($padding -eq 3) {
                $normalizedPayload += "="
            }

            $bytes = [Convert]::FromBase64String($normalizedPayload)
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            $parts += [pscustomobject]@{
                path = $path
                text = $text
                length = $text.Length
            }
        }
        catch {
            $parts += [pscustomobject]@{
                path = $path
                text = ""
                length = 0
            }
        }
    }

    return $parts
}

function Format-VariableLibraryValue {
    param([object]$Value, [string]$VariableType, [hashtable]$ItemById)

    if ($VariableType -eq "ItemReference" -and $null -ne $Value) {
        $refItemId = (Get-FieldValue -Object $Value -Names @("itemId")).ToLowerInvariant()
        $resolvedName = ""
        if ($refItemId -and $ItemById.ContainsKey($refItemId)) {
            $resolvedName = Get-FieldValue -Object $ItemById[$refItemId] -Names @("qualified_name")
        }
        return [pscustomobject]@{
            text = if ($resolvedName) { $resolvedName } else { "itemId=$refItemId" }
            resolved = $resolvedName
        }
    }

    # Scalar types (String, Boolean, Integer, ...) -- Fabric's variable-
    # library schema doesn't document every possible $VariableType value,
    # so this branch is deliberately generic: whatever ConvertFrom-Json
    # already gave us, stringified as-is.
    return [pscustomobject]@{ text = [string]$Value; resolved = "" }
}

function Get-VariableLibraryRows {
    param(
        [object[]]$DecodedParts,
        [string]$WorkspaceName,
        [string]$ItemName,
        [string]$QualifiedName,
        [hashtable]$ItemById,
        [string]$CapturedAt
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $variablesPart = @($DecodedParts | Where-Object { $_.path -eq "variables.json" }) | Select-Object -First 1
    if (-not $variablesPart -or -not $variablesPart.text) {
        return $rows
    }

    try {
        $variablesJson = $variablesPart.text | ConvertFrom-Json
    }
    catch {
        return $rows
    }

    $variableTypeByName = @{}
    foreach ($variable in @($variablesJson.variables)) {
        $variableName = Get-FieldValue -Object $variable -Names @("name")
        if (-not $variableName) { continue }
        $variableType = Get-FieldValue -Object $variable -Names @("type")
        $variableTypeByName[$variableName] = $variableType
        $formatted = Format-VariableLibraryValue -Value $variable.value -VariableType $variableType -ItemById $ItemById

        $rows.Add([pscustomobject]@{
            workspace_name = $WorkspaceName
            item_name = $ItemName
            qualified_name = $QualifiedName
            variable_name = $variableName
            variable_type = $variableType
            value_set_name = ""
            variable_value = $formatted.text
            resolved_item_qualified_name = $formatted.resolved
            variable_note = Get-FieldValue -Object $variable -Names @("note")
            captured_at = $CapturedAt
        }) | Out-Null
    }

    # valueSets/<Name>.json parts -- per-value-set overrides on top of the
    # base variables above. variableOverrides was EMPTY in both real
    # VariableLibrary items spot-checked live, so the entry
    # shape assumed here ({name, value}, mirroring a base variable) is
    # inferred from variables.json's own schema, NOT confirmed against a
    # populated example. Skips an entry silently rather than guessing
    # further if it doesn't match.
    foreach ($part in @($DecodedParts | Where-Object { $_.path -like "valueSets/*" })) {
        if (-not $part.text) { continue }
        try {
            $valueSetJson = $part.text | ConvertFrom-Json
        }
        catch {
            continue
        }
        $valueSetName = Get-FieldValue -Object $valueSetJson -Names @("name")
        foreach ($override in @($valueSetJson.variableOverrides)) {
            $overrideName = Get-FieldValue -Object $override -Names @("name")
            if (-not $overrideName) { continue }
            $overrideType = if ($variableTypeByName.ContainsKey($overrideName)) { $variableTypeByName[$overrideName] } else { "" }
            $formatted = Format-VariableLibraryValue -Value $override.value -VariableType $overrideType -ItemById $ItemById
            $rows.Add([pscustomobject]@{
                workspace_name = $WorkspaceName
                item_name = $ItemName
                qualified_name = $QualifiedName
                variable_name = $overrideName
                variable_type = $overrideType
                value_set_name = $valueSetName
                variable_value = $formatted.text
                resolved_item_qualified_name = $formatted.resolved
                variable_note = ""
                captured_at = $CapturedAt
            }) | Out-Null
        }
    }

    return $rows
}

function Get-RelationshipType {
    param(
        [string]$SourceType,
        [string]$TargetType
    )

    if (($SourceType -eq "Report" -or $SourceType -eq "PaginatedReport" -or $SourceType -eq "Exploration") -and $TargetType -eq "SemanticModel") {
        return "uses_model"
    }

    if ($SourceType -eq "SemanticModel" -and ($TargetType -eq "Lakehouse" -or $TargetType -eq "Warehouse" -or $TargetType -eq "SQLEndpoint" -or $TargetType -eq "Dataflow")) {
        return "reads_from"
    }

    if ($SourceType -eq "DataPipeline" -and ($TargetType -eq "Notebook" -or $TargetType -eq "DataPipeline" -or $TargetType -eq "CopyJob" -or $TargetType -eq "SparkJobDefinition" -or $TargetType -eq "UserDataFunction")) {
        return "executes"
    }

    if ($SourceType -eq "DataPipeline" -and $TargetType -eq "SemanticModel") {
        return "refreshes"
    }

    if (($SourceType -eq "Notebook" -or $SourceType -eq "Dataflow") -and ($TargetType -eq "Lakehouse" -or $TargetType -eq "Warehouse" -or $TargetType -eq "SQLEndpoint" -or $TargetType -eq "SemanticModel")) {
        return "reads_from"
    }

    return "depends_on"
}

function Set-AnalysisStatus {
    param(
        [object]$State,
        [string]$Status
    )

    if ($Status -eq "partial") {
        $State.analysis_status = "partial"
        return
    }

    if ($Status -eq "analyzed" -and $State.analysis_status -ne "partial") {
        $State.analysis_status = "analyzed"
    }
}

function Get-ConfidenceText {
    param([System.Collections.Generic.List[string]]$Confidences)

    if ($Confidences.Contains("confirmed")) {
        return "confirmed"
    }
    if ($Confidences.Contains("likely")) {
        return "likely"
    }
    return "unknown"
}

function Register-Dependency {
    param(
        [string]$From,
        [string]$To,
        [string]$RelationshipType,
        [string]$Evidence,
        [ValidateSet("confirmed", "likely", "unknown")]
        [string]$Confidence,
        [string]$Notes = ""
    )

    if (-not $From -or -not $To -or $From -eq $To) {
        return
    }

    $key = "$From|$To|$RelationshipType"
    if (-not $script:dependencyKeys.ContainsKey($key)) {
        $script:dependencyKeys[$key] = $true
        $script:dependencyRows += [pscustomobject]@{
            from_qualified_name = $From
            to_qualified_name = $To
            relationship_type = $RelationshipType
            source_system = "Fabric REST API via Azure CLI"
            evidence = Limit-Text -Text $Evidence -MaxLength 500
            confidence = $Confidence
            notes = Limit-Text -Text $Notes -MaxLength 500
        }
    }

    if ($script:analysisByName.ContainsKey($From)) {
        $state = $script:analysisByName[$From]
        switch ($RelationshipType) {
            "writes_to" { Add-UniqueListValue -List $state.writes_to -Value $To }
            "executes" { Add-UniqueListValue -List $state.executes -Value $To }
            "refreshes" { Add-UniqueListValue -List $state.refreshes -Value $To }
            "serves_report" { Add-UniqueListValue -List $state.serves -Value $To }
            default { Add-UniqueListValue -List $state.reads_from -Value $To }
        }
        Add-UniqueListValue -List $state.evidence -Value $Evidence
        Add-UniqueListValue -List $state.confidences -Value $Confidence
        if ($Notes) {
            Add-UniqueListValue -List $state.notes -Value $Notes
        }
        Set-AnalysisStatus -State $state -Status "analyzed"
    }
}

function Get-ConnectionQualifiedName {
    param([object]$Connection)

    $connectionId = Get-FieldValue -Object $Connection -Names @("id")
    $displayName = Get-FieldValue -Object $Connection -Names @("displayName", "name")
    $detailsType = ""
    $detailsPath = ""

    if ($Connection.PSObject.Properties.Name -contains "connectionDetails") {
        $detailsType = Get-FieldValue -Object $Connection.connectionDetails -Names @("type")
        $detailsPath = Get-FieldValue -Object $Connection.connectionDetails -Names @("path")
    }

    $label = if ($displayName) { $displayName } elseif ($detailsPath) { $detailsPath } else { $connectionId }
    $type = if ($detailsType) { $detailsType } else { "Unknown" }

    return "External Connection / $type / $(Limit-Text -Text $label -MaxLength 180)"
}

function Register-ExternalNode {
    param(
        [string]$QualifiedName,
        [object]$Connection
    )

    if (-not $QualifiedName -or $script:externalNodeKeys.ContainsKey($QualifiedName)) {
        return
    }

    $script:externalNodeKeys[$QualifiedName] = $true
    $displayName = ($QualifiedName -split " / " | Select-Object -Last 1)
    $connectionId = Get-FieldValue -Object $Connection -Names @("id")
    $connectivityType = Get-FieldValue -Object $Connection -Names @("connectivityType")

    $script:externalNodeRows += [pscustomobject]@{
        qualified_name = $QualifiedName
        display_name = $displayName
        workspace_name = "External"
        item_type = "ExternalConnection"
        object_type = "ExternalConnection"
        source_system = "Fabric REST API via Azure CLI"
        technical_id = $connectionId
        status = "discovered"
        notes = "Connectivity type: $connectivityType"
    }
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
if (-not (Test-Path $ItemsPath)) {
    throw "Item inventory not found: $ItemsPath"
}

$workspaceRows = @(Import-Csv -Path $WorkspaceIndexPath)
$itemRows = @(Import-Csv -Path $ItemsPath | Where-Object { $_.status -eq "discovered" })
if ($MaxItems -gt 0) {
    $itemRows = @($itemRows | Select-Object -First $MaxItems)
}

if ($itemRows.Count -eq 0) {
    throw "No discovered items found in $ItemsPath."
}

$workspaceIdByName = @{}
foreach ($workspace in $workspaceRows) {
    $workspaceName = Get-FieldValue -Object $workspace -Names @("workspace_name")
    $workspaceId = Get-FieldValue -Object $workspace -Names @("technical_id")
    if ($workspaceName -and $workspaceId) {
        $workspaceIdByName[$workspaceName] = $workspaceId
    }
}

$script:analysisByName = @{}
$itemById = @{}
$itemsByWorkspaceName = @{}

foreach ($item in $itemRows) {
    $qualifiedName = Get-FieldValue -Object $item -Names @("qualified_name")
    $itemId = (Get-FieldValue -Object $item -Names @("technical_id")).ToLowerInvariant()
    $workspaceName = Get-FieldValue -Object $item -Names @("workspace_name")

    $script:analysisByName[$qualifiedName] = [pscustomobject]@{
        workspace_name = $workspaceName
        item_type = Get-FieldValue -Object $item -Names @("item_type")
        item_name = Get-FieldValue -Object $item -Names @("item_name")
        qualified_name = $qualifiedName
        analysis_status = "metadata_only"
        reads_from = [System.Collections.Generic.List[string]]::new()
        writes_to = [System.Collections.Generic.List[string]]::new()
        executes = [System.Collections.Generic.List[string]]::new()
        refreshes = [System.Collections.Generic.List[string]]::new()
        serves = [System.Collections.Generic.List[string]]::new()
        evidence = [System.Collections.Generic.List[string]]::new()
        confidences = [System.Collections.Generic.List[string]]::new()
        notes = [System.Collections.Generic.List[string]]::new()
    }

    if ($itemId) {
        $itemById[$itemId] = $item
    }

    if (-not $itemsByWorkspaceName.ContainsKey($workspaceName)) {
        $itemsByWorkspaceName[$workspaceName] = [System.Collections.Generic.List[object]]::new()
    }
    $itemsByWorkspaceName[$workspaceName].Add($item) | Out-Null
}

$workspaceFilterSet = $null
if ($WorkspaceNameFilter) {
    $workspaceFilterSet = @{}
    foreach ($name in ($WorkspaceNameFilter -split "[;,]" | ForEach-Object { Normalize-Key $_ } | Where-Object { $_ })) {
        $workspaceFilterSet[$name] = $true
    }

    $matchingWorkspaceNameCount = @($itemsByWorkspaceName.Keys | Where-Object { $workspaceFilterSet.ContainsKey((Normalize-Key $_)) }).Count
    if ($matchingWorkspaceNameCount -eq 0) {
        throw "WorkspaceNameFilter '$WorkspaceNameFilter' did not match any workspace with discovered items in $ItemsPath."
    }
}

# When a workspace filter is active, only the two heavy per-workspace passes below are
# restricted to the filtered workspace(s); $itemsByWorkspaceName above always covers every
# workspace so cross-workspace GUID/name matching keeps working for items outside the filter.
$workspaceNamesToProcess = if ($workspaceFilterSet) {
    @($itemsByWorkspaceName.Keys | Where-Object { $workspaceFilterSet.ContainsKey((Normalize-Key $_)) } | Sort-Object)
}
else {
    @($itemsByWorkspaceName.Keys | Sort-Object)
}

$script:dependencyRows = @()
$script:dependencyKeys = @{}
$script:externalNodeRows = @()
$script:externalNodeKeys = @{}
$script:variableLibraryRows = @()
$capturedAt = (Get-Date).ToString("s")

if ($workspaceFilterSet -and (Test-Path $DependenciesPath)) {
    $ownerWorkspaceByQualifiedName = @{}
    foreach ($item in $itemRows) {
        $ownerWorkspaceByQualifiedName[(Get-FieldValue -Object $item -Names @("qualified_name"))] = Get-FieldValue -Object $item -Names @("workspace_name")
    }

    foreach ($dep in @(Import-Csv -Path $DependenciesPath)) {
        $fromWorkspace = $ownerWorkspaceByQualifiedName[$dep.from_qualified_name]
        $ownedByFilteredWorkspace = $fromWorkspace -and $workspaceFilterSet.ContainsKey((Normalize-Key $fromWorkspace))
        if ($ownedByFilteredWorkspace) {
            # Belongs to a workspace being rescanned now; the loops below will regenerate it.
            continue
        }

        $key = "$($dep.from_qualified_name)|$($dep.to_qualified_name)|$($dep.relationship_type)"
        if (-not $script:dependencyKeys.ContainsKey($key)) {
            $script:dependencyKeys[$key] = $true
            $script:dependencyRows += $dep
        }
    }
}

$connectionFailures = @()
$definitionFailures = @()
$definitionSuccessCount = 0
$connectionSuccessCount = 0
$connectionCount = 0
$definitionPartCount = 0
$processedItemCount = 0

$headers = @{}
if (-not $SkipConnections -or -not $SkipDefinitions) {
    $headers = @{
        Authorization = "Bearer $(Get-FreshAzureCliToken -AzCommand $AzCommand)"
        "Content-Type" = "application/json"
    }
}

# A single access token fetched once at the top of the script used to be
# safe when a full run took under an hour -- now that Report/PaginatedReport
# definitions are fetched by default (~15-20s each, ~986 tenant-wide), a full
# run can take several hours, comfortably past a Fabric/Entra token's
# lifetime. This proactive check (called at the top of every loop that makes
# API calls) is the first line of defense; Invoke-FabricWebRequestCore
# (LineageCommon.psm1) also reacts to an actual 401 TokenExpired directly,
# which is what actually closed the gap -- a tenant-wide run with only this
# proactive check (on its own, at a 20-minute threshold) can still hit
# 401 TokenExpired on a large share of items when the tenant's real token
# lifetime is shorter than 20 minutes in practice.
function Update-TokenIfStale {
    $script:headers = @{
        Authorization = "Bearer $(Get-FreshAzureCliToken -AzCommand $AzCommand -MaxAgeMinutes 10)"
        "Content-Type" = "application/json"
    }
}

$script:sessionDiedAt = $null

:workspaceLoop foreach ($workspaceName in $workspaceNamesToProcess) {
    $workspaceId = if ($workspaceIdByName.ContainsKey($workspaceName)) { $workspaceIdByName[$workspaceName] } else { "" }

    foreach ($item in ($itemsByWorkspaceName[$workspaceName] | Sort-Object -Property item_type, item_name)) {
        $processedItemCount += 1
        # Get-AzureCliToken (LineageCommon.psm1) throws uncaught when the
        # underlying `az`/refresh-token session is truly dead (not just an
        # access token due for a routine refresh) -- e.g. a tenant
        # Conditional Access policy capping refresh-token lifetime
        # (AADSTS70043). Left unguarded, that
        # throw used to propagate straight out of this loop with
        # $ErrorActionPreference = "Stop" already in effect, aborting the
        # whole script before it ever reached its Export-Csv calls at the
        # bottom -- losing every item this run had already analyzed, not
        # just the ones still pending, since nothing gets written until the
        # very end. Every item's analysis state was already pre-seeded
        # before this loop starts (see $script:analysisByName above), so
        # stopping the loop cleanly here and falling through to the normal
        # end-of-script writes is enough to keep everything genuinely
        # completed so far -- no separate checkpoint-write path needed.
        try {
            Update-TokenIfStale
        }
        catch {
            $script:sessionDiedAt = $processedItemCount
            Write-Host "Azure session appears to be fully expired (not just due for a routine refresh) after $processedItemCount / $($itemRows.Count) items -- stopping here instead of losing this run's progress. Re-authenticate (az login) and re-run to pick up the rest. Error: $($_.Exception.Message)"
            break workspaceLoop
        }
        $itemType = Get-FieldValue -Object $item -Names @("item_type")
        $itemId = Get-FieldValue -Object $item -Names @("technical_id")
        $qualifiedName = Get-FieldValue -Object $item -Names @("qualified_name")
        $state = $script:analysisByName[$qualifiedName]

        if ($ProgressInterval -gt 0 -and ($processedItemCount % $ProgressInterval -eq 0)) {
            Write-Host "Processed $processedItemCount / $($itemRows.Count) items..."
        }

        if (-not $workspaceId) {
            Add-UniqueListValue -List $state.notes -Value "Workspace id missing; API analysis skipped."
            Set-AnalysisStatus -State $state -Status "partial"
            continue
        }

        if (-not $SkipConnections) {
            $connectionResult = Get-PagedItemConnections -WorkspaceId $workspaceId -ItemId $itemId -Headers $headers
            if ($connectionResult.succeeded) {
                $connectionSuccessCount += 1
                $connections = @($connectionResult.values)
                $connectionCount += $connections.Count
                Add-UniqueListValue -List $state.evidence -Value "Connections API returned $($connections.Count) connection(s)."
                Add-UniqueListValue -List $state.confidences -Value "confirmed"
                Set-AnalysisStatus -State $state -Status "analyzed"

                foreach ($connection in $connections) {
                    $connectionName = Get-ConnectionQualifiedName -Connection $connection
                    Register-ExternalNode -QualifiedName $connectionName -Connection $connection
                    $connectivityType = Get-FieldValue -Object $connection -Names @("connectivityType")
                    $detailsType = ""
                    if ($connection.PSObject.Properties.Name -contains "connectionDetails") {
                        $detailsType = Get-FieldValue -Object $connection.connectionDetails -Names @("type")
                    }

                    Register-Dependency `
                        -From $qualifiedName `
                        -To $connectionName `
                        -RelationshipType "depends_on" `
                        -Evidence "Fabric item connections API returned a $detailsType connection for this item." `
                        -Confidence "confirmed" `
                        -Notes "Connectivity type: $connectivityType"
                }
            }
            else {
                $connectionFailures += [pscustomobject]@{
                    qualified_name = $qualifiedName
                    status_code = $connectionResult.status_code
                    error = $connectionResult.error
                }
                Add-UniqueListValue -List $state.notes -Value "Connections unavailable: $($connectionResult.status_code) $($connectionResult.error)"
                Set-AnalysisStatus -State $state -Status "partial"
            }
        }

        if (-not $SkipDefinitions -and ($DefinitionItemTypes -contains $itemType)) {
            $definitionResult = Get-ItemDefinition -WorkspaceId $workspaceId -ItemId $itemId -ItemType $itemType -Headers $headers
            if ($definitionResult.succeeded) {
                $definitionSuccessCount += 1
                $decodedParts = @(Decode-DefinitionParts -DefinitionPayload $definitionResult.payload)
                $definitionPartCount += $decodedParts.Count
                Add-UniqueListValue -List $state.evidence -Value "Definition API returned $($decodedParts.Count) decoded part(s)."
                Add-UniqueListValue -List $state.confidences -Value "confirmed"
                Set-AnalysisStatus -State $state -Status "analyzed"

                if ($itemType -eq "VariableLibrary") {
                    $script:variableLibraryRows += @(Get-VariableLibraryRows `
                        -DecodedParts $decodedParts `
                        -WorkspaceName $workspaceName `
                        -ItemName (Get-FieldValue -Object $item -Names @("item_name")) `
                        -QualifiedName $qualifiedName `
                        -ItemById $itemById `
                        -CapturedAt $capturedAt)
                }

                foreach ($part in $decodedParts) {
                    if (-not $part.text) {
                        continue
                    }

                    $guidMatches = [regex]::Matches($part.text, "(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")
                    foreach ($match in $guidMatches) {
                        $matchedId = $match.Value.ToLowerInvariant()
                        if (-not $itemById.ContainsKey($matchedId)) {
                            continue
                        }

                        $targetItem = $itemById[$matchedId]
                        $targetQualifiedName = Get-FieldValue -Object $targetItem -Names @("qualified_name")
                        $targetType = Get-FieldValue -Object $targetItem -Names @("item_type")
                        if ($targetQualifiedName -eq $qualifiedName) {
                            continue
                        }

                        $relationshipType = Get-RelationshipType -SourceType $itemType -TargetType $targetType
                        Register-Dependency `
                            -From $qualifiedName `
                            -To $targetQualifiedName `
                            -RelationshipType $relationshipType `
                            -Evidence "Decoded definition part '$($part.path)' references the target Fabric item id." `
                            -Confidence "confirmed" `
                            -Notes "Definition-based relationship."

                        # A confirmed Report -> SemanticModel "uses_model" edge also confirms
                        # the inverse "serves_report" (Model -> Report) direction -- without
                        # this, that inverse stayed on the old "likely" name-based heuristic
                        # forever, even after the forward direction was definition-verified.
                        if ($relationshipType -eq "uses_model") {
                            Register-Dependency `
                                -From $targetQualifiedName `
                                -To $qualifiedName `
                                -RelationshipType "serves_report" `
                                -Evidence "Decoded definition part '$($part.path)' of the report references this semantic model's item id." `
                                -Confidence "confirmed" `
                                -Notes "Inverse of definition-based relationship."
                        }
                    }
                }
            }
            else {
                $definitionFailures += [pscustomobject]@{
                    qualified_name = $qualifiedName
                    item_type = $itemType
                    status_code = $definitionResult.status_code
                    error = $definitionResult.error
                }
                Add-UniqueListValue -List $state.notes -Value "Definition unavailable: $($definitionResult.status_code) $($definitionResult.error)"
                Set-AnalysisStatus -State $state -Status "partial"
            }
        }
        elseif (-not $SkipDefinitions) {
            Add-UniqueListValue -List $state.notes -Value "Definition API not attempted for item type '$itemType' in this phase."
        }
    }
}

foreach ($workspaceName in $workspaceNamesToProcess) {
    # The main per-item loop above already discovered the session is dead --
    # don't attempt (and re-fail identically on) more API calls with it here.
    if ($script:sessionDiedAt) { break }

    $workspaceItems = @($itemsByWorkspaceName[$workspaceName])
    $workspaceId = if ($workspaceIdByName.ContainsKey($workspaceName)) { $workspaceIdByName[$workspaceName] } else { "" }
    try {
        Update-TokenIfStale
    }
    catch {
        $script:sessionDiedAt = $processedItemCount
        Write-Host "Azure session appears to be fully expired during the Lakehouse/SQLEndpoint pairing pass -- stopping here instead of losing this run's progress. Re-authenticate (az login) and re-run to pick up the rest. Error: $($_.Exception.Message)"
        break
    }

    # A Lakehouse's own detail API returns properties.sqlEndpointProperties.id
    # -- the real item id of its paired SQL endpoint -- so this pairing never
    # needs to be guessed by name at all. One cheap, synchronous GET per
    # Lakehouse (no getDefinition/LRO polling involved), run before the
    # name-based fallback below so a real match wins the dependency-key
    # dedup and the heuristic below becomes a no-op for that pair.
    if ($workspaceId) {
        foreach ($lakehouse in ($workspaceItems | Where-Object { $_.item_type -eq "Lakehouse" })) {
            $lakehouseId = Get-FieldValue -Object $lakehouse -Names @("technical_id")
            if (-not $lakehouseId) {
                continue
            }
            $lakehouseDetailResult = Invoke-FabricWebRequest -Method Get -Path "workspaces/$workspaceId/lakehouses/$lakehouseId" -Headers $headers
            if (-not $lakehouseDetailResult.succeeded) {
                continue
            }
            $lakehouseDetail = Convert-JsonContent -Content $lakehouseDetailResult.content
            if (-not ($lakehouseDetail.PSObject.Properties.Name -contains "properties")) {
                continue
            }
            $lakehouseProps = $lakehouseDetail.properties
            if (-not ($lakehouseProps.PSObject.Properties.Name -contains "sqlEndpointProperties")) {
                continue
            }
            $sqlEndpointId = (Get-FieldValue -Object $lakehouseProps.sqlEndpointProperties -Names @("id")).ToLowerInvariant()
            if (-not $sqlEndpointId -or -not $itemById.ContainsKey($sqlEndpointId)) {
                continue
            }
            $sqlEndpointItem = $itemById[$sqlEndpointId]
            Register-Dependency `
                -From (Get-FieldValue -Object $sqlEndpointItem -Names @("qualified_name")) `
                -To (Get-FieldValue -Object $lakehouse -Names @("qualified_name")) `
                -RelationshipType "depends_on" `
                -Evidence "Lakehouse detail API sqlEndpointProperties.id confirms the paired SQL endpoint." `
                -Confidence "confirmed" `
                -Notes "Lakehouse API-confirmed SQL endpoint pairing."
        }

        # OneLake shortcuts are a structural, first-class dependency that was
        # completely invisible before this: a shortcut makes a table/folder
        # in ANOTHER Lakehouse or Warehouse (often in a different workspace
        # entirely -- e.g. a "hub" Lakehouse that shortcuts in tables from
        # several source Lakehouses) appear as if it were local data, with
        # zero copy and zero prior dependency edge of any kind. One request
        # per Lakehouse/Warehouse; each shortcut whose target is itself a
        # OneLake item (as opposed to external ADLS/S3/etc., which isn't a
        # Fabric item we can resolve) becomes a confirmed "depends_on" edge.
        foreach ($shortcutHost in ($workspaceItems | Where-Object { $_.item_type -eq "Lakehouse" -or $_.item_type -eq "Warehouse" })) {
            $hostId = Get-FieldValue -Object $shortcutHost -Names @("technical_id")
            if (-not $hostId) {
                continue
            }
            $shortcutsResult = Invoke-FabricWebRequest -Method Get -Path "workspaces/$workspaceId/items/$hostId/shortcuts" -Headers $headers
            if (-not $shortcutsResult.succeeded) {
                continue
            }
            $shortcutsPayload = Convert-JsonContent -Content $shortcutsResult.content
            if (-not ($shortcutsPayload.PSObject.Properties.Name -contains "value")) {
                continue
            }
            foreach ($shortcut in @($shortcutsPayload.value)) {
                if (-not ($shortcut.PSObject.Properties.Name -contains "target")) {
                    continue
                }
                $target = $shortcut.target
                $targetType = Get-FieldValue -Object $target -Names @("type")
                if ($targetType -ne "OneLake" -or -not ($target.PSObject.Properties.Name -contains "oneLake")) {
                    continue
                }
                $targetItemId = (Get-FieldValue -Object $target.oneLake -Names @("itemId")).ToLowerInvariant()
                if (-not $targetItemId -or -not $itemById.ContainsKey($targetItemId)) {
                    continue
                }
                $targetItem = $itemById[$targetItemId]
                $shortcutName = Get-FieldValue -Object $shortcut -Names @("name")
                $shortcutPath = Get-FieldValue -Object $shortcut -Names @("path")
                Register-Dependency `
                    -From (Get-FieldValue -Object $shortcutHost -Names @("qualified_name")) `
                    -To (Get-FieldValue -Object $targetItem -Names @("qualified_name")) `
                    -RelationshipType "depends_on" `
                    -Evidence "OneLake shortcut '$shortcutPath/$shortcutName' points to this item's OneLake data." `
                    -Confidence "confirmed" `
                    -Notes "OneLake shortcut (structural, not name-based or parsed)."
            }
        }
    }

    $semanticModelsByName = @{}
    foreach ($model in ($workspaceItems | Where-Object { $_.item_type -eq "SemanticModel" })) {
        $key = (Get-FieldValue -Object $model -Names @("item_name")).ToLowerInvariant()
        if (-not $semanticModelsByName.ContainsKey($key)) {
            $semanticModelsByName[$key] = @()
        }
        $semanticModelsByName[$key] += $model
    }

    foreach ($report in ($workspaceItems | Where-Object { $_.item_type -eq "Report" -or $_.item_type -eq "PaginatedReport" -or $_.item_type -eq "Exploration" })) {
        $key = (Get-FieldValue -Object $report -Names @("item_name")).ToLowerInvariant()
        if ($semanticModelsByName.ContainsKey($key) -and @($semanticModelsByName[$key]).Count -eq 1) {
            $model = @($semanticModelsByName[$key])[0]
            Register-Dependency `
                -From (Get-FieldValue -Object $report -Names @("qualified_name")) `
                -To (Get-FieldValue -Object $model -Names @("qualified_name")) `
                -RelationshipType "uses_model" `
                -Evidence "Report and semantic model share the same real name in the same workspace." `
                -Confidence "likely" `
                -Notes "Name-based Fabric pairing heuristic; confirm in Phase 5 if no definition edge exists."

            Register-Dependency `
                -From (Get-FieldValue -Object $model -Names @("qualified_name")) `
                -To (Get-FieldValue -Object $report -Names @("qualified_name")) `
                -RelationshipType "serves_report" `
                -Evidence "Semantic model and report share the same real name in the same workspace." `
                -Confidence "likely" `
                -Notes "Inverse of name-based report/model pairing heuristic."
        }
    }

    # MLExperiment has no definition content of its own (MLflow run metadata,
    # not code) but Fabric always creates it alongside a same-name Notebook in
    # the same workspace, and that notebook already gets full object-lineage
    # extraction -- point the experiment at it instead of a dead end.
    $notebooksByName = @{}
    foreach ($notebook in ($workspaceItems | Where-Object { $_.item_type -eq "Notebook" })) {
        $key = (Get-FieldValue -Object $notebook -Names @("item_name")).ToLowerInvariant()
        if (-not $notebooksByName.ContainsKey($key)) {
            $notebooksByName[$key] = @()
        }
        $notebooksByName[$key] += $notebook
    }

    foreach ($experiment in ($workspaceItems | Where-Object { $_.item_type -eq "MLExperiment" })) {
        $key = (Get-FieldValue -Object $experiment -Names @("item_name")).ToLowerInvariant()
        if ($notebooksByName.ContainsKey($key) -and @($notebooksByName[$key]).Count -eq 1) {
            $notebook = @($notebooksByName[$key])[0]
            Register-Dependency `
                -From (Get-FieldValue -Object $experiment -Names @("qualified_name")) `
                -To (Get-FieldValue -Object $notebook -Names @("qualified_name")) `
                -RelationshipType "depends_on" `
                -Evidence "ML experiment and notebook share the same real name in the same workspace." `
                -Confidence "likely" `
                -Notes "Name-based Fabric pairing heuristic -- the notebook, not the experiment, carries real object lineage."
        }
    }

    $lakehousesByName = @{}
    foreach ($lakehouse in ($workspaceItems | Where-Object { $_.item_type -eq "Lakehouse" })) {
        $key = (Get-FieldValue -Object $lakehouse -Names @("item_name")).ToLowerInvariant()
        if (-not $lakehousesByName.ContainsKey($key)) {
            $lakehousesByName[$key] = @()
        }
        $lakehousesByName[$key] += $lakehouse
    }

    foreach ($sqlEndpoint in ($workspaceItems | Where-Object { $_.item_type -eq "SQLEndpoint" })) {
        $key = (Get-FieldValue -Object $sqlEndpoint -Names @("item_name")).ToLowerInvariant()
        if ($lakehousesByName.ContainsKey($key) -and @($lakehousesByName[$key]).Count -eq 1) {
            $lakehouse = @($lakehousesByName[$key])[0]
            Register-Dependency `
                -From (Get-FieldValue -Object $sqlEndpoint -Names @("qualified_name")) `
                -To (Get-FieldValue -Object $lakehouse -Names @("qualified_name")) `
                -RelationshipType "depends_on" `
                -Evidence "SQL endpoint and lakehouse share the same real name in the same workspace." `
                -Confidence "likely" `
                -Notes "Name-based lakehouse SQL endpoint pairing heuristic."
        }
    }
}

$previousAnalysisByQualifiedName = @{}
if ($workspaceFilterSet -and (Test-Path $OutputPath)) {
    foreach ($row in @(Import-Csv -Path $OutputPath)) {
        $previousAnalysisByQualifiedName[$row.qualified_name] = $row
    }
}

$analysisRows = @(
    $script:analysisByName.Values |
        Sort-Object -Property workspace_name, item_type, item_name |
        ForEach-Object {
            $inFilter = -not $workspaceFilterSet -or $workspaceFilterSet.ContainsKey((Normalize-Key $_.workspace_name))
            if (-not $inFilter -and $previousAnalysisByQualifiedName.ContainsKey($_.qualified_name)) {
                $previousAnalysisByQualifiedName[$_.qualified_name]
            }
            else {
                [pscustomobject]@{
                    workspace_name = $_.workspace_name
                    item_type = $_.item_type
                    item_name = $_.item_name
                    qualified_name = $_.qualified_name
                    analysis_status = $_.analysis_status
                    reads_from = Convert-ListToText -List $_.reads_from
                    writes_to = Convert-ListToText -List $_.writes_to
                    executes = Convert-ListToText -List $_.executes
                    refreshes = Convert-ListToText -List $_.refreshes
                    serves = Convert-ListToText -List $_.serves
                    source_system = "Fabric REST API via Azure CLI"
                    evidence = Limit-Text -Text (Convert-ListToText -List $_.evidence) -MaxLength 1000
                    confidence = Get-ConfidenceText -Confidences $_.confidences
                    notes = Limit-Text -Text (Convert-ListToText -List $_.notes) -MaxLength 1000
                }
            }
        }
)

Ensure-ParentDirectory -Path $OutputPath
$analysisRows |
    Select-Object -Property $analysisColumns |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Ensure-ParentDirectory -Path $DependenciesPath
$script:dependencyRows |
    Sort-Object -Property from_qualified_name, relationship_type, to_qualified_name |
    Select-Object -Property $dependencyColumns |
    Export-Csv -Path $DependenciesPath -NoTypeInformation -Encoding UTF8

Ensure-ParentDirectory -Path $EdgesPath
$script:dependencyRows |
    Sort-Object -Property from_qualified_name, relationship_type, to_qualified_name |
    Select-Object -Property $dependencyColumns |
    Export-Csv -Path $EdgesPath -NoTypeInformation -Encoding UTF8

# Same workspace-filter preserve pattern as $analysisRows above: a scoped
# re-run (-WorkspaceNameFilter) only re-derives rows for the filtered
# workspace(s); every other workspace's previously captured variables are
# carried over unchanged rather than dropped.
$variableLibraryRowsToWrite = @($script:variableLibraryRows)
if ($workspaceFilterSet -and (Test-Path $VariableLibraryCatalogPath)) {
    $variableLibraryRowsToWrite += @(
        Import-Csv -Path $VariableLibraryCatalogPath |
            Where-Object { -not $workspaceFilterSet.ContainsKey((Normalize-Key $_.workspace_name)) }
    )
}
Ensure-ParentDirectory -Path $VariableLibraryCatalogPath
if ($variableLibraryRowsToWrite.Count -gt 0) {
    $variableLibraryRowsToWrite |
        Sort-Object -Property workspace_name, item_name, variable_name, value_set_name |
        Select-Object -Property $variableLibraryColumns |
        Export-Csv -Path $VariableLibraryCatalogPath -NoTypeInformation -Encoding UTF8
}
else {
    ('"' + ($variableLibraryColumns -join '","') + '"') | Set-Content -Path $VariableLibraryCatalogPath -Encoding UTF8
}

if (Test-Path $NodesPath) {
    $existingNodes = @(Import-Csv -Path $NodesPath)
}
else {
    $existingNodes = @()
}

$existingNodeKeys = @{}
foreach ($node in $existingNodes) {
    $nodeName = Get-FieldValue -Object $node -Names @("qualified_name")
    if ($nodeName) {
        $existingNodeKeys[$nodeName] = $true
    }
}

$newExternalNodes = @(
    $script:externalNodeRows |
        Where-Object { -not $existingNodeKeys.ContainsKey($_.qualified_name) }
)

Ensure-ParentDirectory -Path $NodesPath
@($existingNodes + $newExternalNodes) |
    Select-Object -Property $nodeColumns |
    Export-Csv -Path $NodesPath -NoTypeInformation -Encoding UTF8

$partialCount = @($analysisRows | Where-Object { $_.analysis_status -eq "partial" }).Count
$metadataOnlyCount = @($analysisRows | Where-Object { $_.analysis_status -eq "metadata_only" }).Count
$analyzedCount = @($analysisRows | Where-Object { $_.analysis_status -eq "analyzed" }).Count
$confirmedEdges = @($script:dependencyRows | Where-Object { $_.confidence -eq "confirmed" }).Count
$likelyEdges = @($script:dependencyRows | Where-Object { $_.confidence -eq "likely" }).Count

$gapParts = @()
if ($connectionFailures.Count -gt 0) {
    $gapParts += "Item connections unavailable for $($connectionFailures.Count) items."
}
if ($definitionFailures.Count -gt 0) {
    $gapParts += "Item definitions unavailable for $($definitionFailures.Count) items."
}
if ($metadataOnlyCount -gt 0) {
    $gapParts += "$metadataOnlyCount items remain metadata-only."
}

if ($gapParts.Count -gt 0) {
    Set-UnresolvedEntry `
        -Title "Phase 4 item analysis gaps" `
        -Status "open" `
        -Evidence ($gapParts -join " ") `
        -NextStep "Use generated dependency candidates for Phase 5, then fill remaining gaps from Azure DevOps, SharePoint, OneLake, or approved Fabric/API permissions."
}
else {
    Set-UnresolvedEntry `
        -Title "Phase 4 item analysis gaps" `
        -Status "resolved" `
        -Evidence "All discovered items were technically analyzed without API gaps." `
        -NextStep "User reviews Phase 4 output and approves Phase 5 graph build."
}

if ($script:sessionDiedAt) {
    Write-Host "Phase 4 item analysis STOPPED EARLY: Azure session expired after $script:sessionDiedAt / $($itemRows.Count) items. Everything analyzed before that point was still written normally below -- re-authenticate and re-run this phase to pick up the remaining items."
}
else {
    Write-Host "Phase 4 item analysis completed."
}
if ($workspaceFilterSet) {
    Write-Host "Workspace filter: $WorkspaceNameFilter (other workspaces retained unchanged from $OutputPath)"
}
Write-Host "Items analyzed: $($analysisRows.Count)"
Write-Host "Analyzed rows: $analyzedCount"
Write-Host "Partial rows: $partialCount"
Write-Host "Metadata-only rows: $metadataOnlyCount"
Write-Host "Connections read: $connectionSuccessCount items, $connectionCount connections"
Write-Host "Definitions read: $definitionSuccessCount items, $definitionPartCount decoded parts"
Write-Host "Connection failures: $($connectionFailures.Count)"
Write-Host "Definition failures: $($definitionFailures.Count)"
Write-Host "Dependencies written: $($script:dependencyRows.Count) ($confirmedEdges confirmed, $likelyEdges likely)"
Write-Host "External nodes added: $($newExternalNodes.Count)"
Write-Host "Variable library rows: $($script:variableLibraryRows.Count)"
Write-Host "Output: $OutputPath"
Write-Host "Dependencies: $DependenciesPath"
Write-Host "Edges: $EdgesPath"
Write-Host "Variable library catalog: $VariableLibraryCatalogPath"

if ($script:sessionDiedAt) {
    # Everything gathered up to the stop point was already written above
    # (correctly, not lost) -- this exit code exists only so a caller like
    # 99_refresh_lineage_project.ps1 knows this run was cut short and the
    # tenant isn't fully covered yet, not to signal the data that WAS
    # written is somehow bad.
    exit 1
}
