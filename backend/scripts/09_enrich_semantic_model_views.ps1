# Phase 9 - Semantic model view enrichment: fetches each semantic model's
# TMDL definition (getDefinition?format=TMDL, an async LRO) and decodes it
# to find real source table/view/native-query candidates behind each model,
# feeding Phase 8's lineage view with confirmed table-level detail instead
# of just model-to-model edges. $MaxModels ranks by source/report count
# for a full-tenant run; -WorkspaceNameFilter processes one workspace's
# models in full instead (used by the per-workspace scan button).
# Writes: $OutputPath (view candidates) + $GapPath (definitions unavailable).
param(
    [string]$WorkspaceIndexPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$ModelSummaryPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_lineage_summary.csv"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_view_candidates.csv"),
    [string]$GapPath = (Join-Path $PSScriptRoot "../../analysis/semantic_model_definition_gaps.csv"),
    [string]$UnresolvedPath = (Join-Path $PSScriptRoot "../../index/unresolved.md"),
    [string]$AzCommand = "az",
    [string]$FabricApiBaseUrl = "https://api.fabric.microsoft.com/v1",
    [int]$MaxModels = 80,
    [int]$RetryCount = 5,
    [int]$RequestDelayMilliseconds = 350,
    [int]$MaxOperationPolls = 12,
    [int]$MaxOperationDelaySeconds = 8,
    [int]$ProgressInterval = 10,
    # When set, only enrich SemanticModel items belonging to this workspace
    # (all of them, ignoring MaxModels/the global source_count/report_count
    # ranking, which assumes a full-tenant run) and preserve every other
    # workspace's previously-enriched rows in $OutputPath/$GapPath instead
    # of overwriting them. Lets the manual per-workspace scan button reach
    # real table/view object detail for that workspace's models without
    # requiring $ModelSummaryPath (script 08's output, a full-refresh-only
    # prerequisite) to exist first.
    [string]$WorkspaceNameFilter = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

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
    # the cached token is stale, so the reactive 401-retry below is now a
    # backstop rather than the only defense.
    $token = Get-FreshAzureCliToken -Resource "https://api.fabric.microsoft.com" -AzCommand $AzCommand
    return @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }
}

# Thin wrapper: the real retry/refresh logic (including the reactive
# 401-refresh-and-retry -- see that function's header comment) lives once in
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

function Get-SemanticModelDefinition {
    param([string]$WorkspaceId, [string]$ModelId, [hashtable]$Headers)

    $path = "workspaces/$WorkspaceId/semanticModels/$ModelId/getDefinition?format=TMDL"
    $response = Invoke-FabricWebRequest -Method Post -Path $path -Headers $Headers
    if ($response.status_code -eq 200) {
        return [pscustomobject]@{ succeeded = $true; payload = (Convert-JsonContent -Content $response.content); status_code = 200; error = "" }
    }
    if ($response.status_code -ne 202) {
        return [pscustomobject]@{ succeeded = $false; payload = $null; status_code = $response.status_code; error = (Get-FabricErrorText -Response $response) }
    }

    $operationId = Get-HeaderValue -Headers $response.headers -Name "x-ms-operation-id"
    if (-not $operationId) {
        $location = Get-HeaderValue -Headers $response.headers -Name "Location"
        $match = [regex]::Match($location, "[0-9a-fA-F-]{36}")
        if ($match.Success) { $operationId = $match.Value }
    }
    if (-not $operationId) {
        return [pscustomobject]@{ succeeded = $false; payload = $null; status_code = 202; error = "LRO accepted but no operation id was returned." }
    }

    for ($poll = 1; $poll -le $MaxOperationPolls; $poll++) {
        $retryAfter = Get-HeaderValue -Headers $response.headers -Name "Retry-After"
        $delaySeconds = if ($retryAfter -match "^\d+$") { [int]$retryAfter } else { 2 }
        Start-Sleep -Seconds ([math]::Min($delaySeconds, $MaxOperationDelaySeconds))

        $stateResponse = Invoke-FabricWebRequest -Method Get -Path "operations/$operationId" -Headers $Headers
        if (-not $stateResponse.succeeded) {
            return [pscustomobject]@{ succeeded = $false; payload = $null; status_code = $stateResponse.status_code; error = (Get-FabricErrorText -Response $stateResponse) }
        }
        $statePayload = Convert-JsonContent -Content $stateResponse.content
        $status = Get-FieldValue -Object $statePayload -Names @("status")
        if ($status -eq "Succeeded") {
            $resultResponse = Invoke-FabricWebRequest -Method Get -Path "operations/$operationId/result" -Headers $Headers
            if ($resultResponse.succeeded) {
                return [pscustomobject]@{ succeeded = $true; payload = (Convert-JsonContent -Content $resultResponse.content); status_code = $resultResponse.status_code; error = "" }
            }
            return [pscustomobject]@{ succeeded = $false; payload = $null; status_code = $resultResponse.status_code; error = (Get-FabricErrorText -Response $resultResponse) }
        }
        if ($status -eq "Failed") {
            return [pscustomobject]@{ succeeded = $false; payload = $null; status_code = $stateResponse.status_code; error = "LRO failed. $(Get-FabricErrorText -Response $stateResponse)" }
        }
        $response = $stateResponse
    }
    return [pscustomobject]@{ succeeded = $false; payload = $null; status_code = 202; error = "LRO did not complete after $MaxOperationPolls polls." }
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
            $parts += [pscustomobject]@{ path = $path; text = $text }
        }
        catch {
            $parts += [pscustomobject]@{ path = $path; text = "" }
        }
    }
    return $parts
}

function Get-TableNameFromPath {
    param([string]$Path)
    if (-not $Path) { return "" }
    $file = Split-Path -Leaf $Path
    return ($file -replace "\.tmdl$", "")
}

function Normalize-NativeIdentifierPart {
    param([string]$Value)
    if (-not $Value) { return "" }
    $clean = $Value.Trim()
    if ($clean -match '^#"(.*)"$') { $clean = $matches[1] }
    $clean = $clean -replace '^[\[\]"`]+', ''
    $clean = $clean -replace '[\[\]"`]+$', ''
    return $clean.Trim()
}

function Test-NativeSqlParseScope {
    param(
        [string]$DefinitionPath,
        [string]$Text
    )
    if (-not $Text) { return $false }
    if ($DefinitionPath -match '^definition/cultures/') { return $false }
    return ($Text -match '(?is)\b(Sql\.Database|Value\.NativeQuery|Odbc\.Query|OleDb\.Query|OleDb\.DataSource|Query\s*=|CommandText\s*=|select\s+.+?\s+from|with\s+\w+\s+as)\b')
}

function Test-NativeMatchContext {
    param(
        [string]$Text,
        [int]$Index
    )
    $start = [math]::Max(0, $Index - 350)
    $length = [math]::Min(350, $Index - $start)
    $context = $Text.Substring($start, $length)
    return ($context -match '(?is)(select\s+|with\s+\w+\s+as|value\.nativequery|query\s*=|commandtext\s*=|exec(?:ute)?\s+|call\s+)')
}

function Test-NativeObjectCandidate {
    param(
        [string]$ObjectName,
        [string]$SchemaName
    )
    if (-not $ObjectName) { return $false }
    $clean = $ObjectName.Trim()
    if (-not $clean -or $clean.Length -lt 2) { return $false }
    if ($clean -match '#') { return $false }

    $lower = $clean.ToLowerInvariant()
    $blocked = @(
        "a", "an", "and", "as", "by", "case", "call", "cast", "else", "end", "exec", "execute",
        "for", "formula", "from", "full", "if", "in", "inner", "join", "left", "meeting",
        "on", "or", "outer", "real", "received", "red", "right", "scatterplot", "select",
        "supplementary", "the", "then", "when", "where", "with"
    )
    if ($lower -in $blocked) { return $false }
    if (-not $SchemaName -and $clean -cmatch '^[a-z]{1,3}$') { return $false }
    return $true
}

function Add-ObjectCandidate {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$Model,
        [string]$DefinitionPath,
        [string]$SemanticTable,
        [string]$Server,
        [string]$Database,
        [string]$Schema,
        [string]$ObjectName,
        [string]$ObjectType,
        [string]$Evidence,
        [string]$Confidence
    )
    if (-not $ObjectName -and -not $Database) { return }
    $key = "$($Model.qualified_name)|$DefinitionPath|$Server|$Database|$Schema|$ObjectName|$ObjectType"
    if ($Seen.ContainsKey($key)) { return }
    $Seen[$key] = $true
    $Rows.Add([pscustomobject]@{
        workspace_name = $Model.workspace_name
        workspace_environment = $Model.workspace_environment
        semantic_model_name = $Model.item_name
        semantic_model_qualified_name = $Model.qualified_name
        semantic_table = $SemanticTable
        source_server = $Server
        database_name = $Database
        schema_name = $Schema
        object_name = $ObjectName
        object_type = $ObjectType
        definition_path = $DefinitionPath
        confidence = $Confidence
        evidence = Limit-Text -Text $Evidence -MaxLength 1200
    }) | Out-Null
}

function Set-UnresolvedEntry {
    param([string]$Title, [string]$Status, [string]$Evidence, [string]$NextStep)
    Ensure-ParentDirectory -Path $UnresolvedPath
    if (-not (Test-Path $UnresolvedPath)) { "# Unresolved Items`n`n## Open Questions`n" | Set-Content -Path $UnresolvedPath -Encoding UTF8 }
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
    } else {
        Add-Content -Path $UnresolvedPath -Value $entry -Encoding UTF8
    }
}

$requiredPaths = if ($WorkspaceNameFilter) { @($WorkspaceIndexPath, $ItemsPath) } else { @($WorkspaceIndexPath, $ItemsPath, $ModelSummaryPath) }
foreach ($path in $requiredPaths) {
    if (-not (Test-Path $path)) { throw "Required input not found: $path" }
}

$workspaces = @(Import-Csv -Path $WorkspaceIndexPath)
$items = @(Import-Csv -Path $ItemsPath | Where-Object { $_.status -eq "discovered" })

$workspaceIdByName = @{}
foreach ($workspace in $workspaces) {
    $workspaceIdByName[$workspace.workspace_name] = $workspace.technical_id
}

$itemByQualifiedName = @{}
foreach ($item in $items) { $itemByQualifiedName[$item.qualified_name] = $item }

if ($WorkspaceNameFilter) {
    # Scoped run: enrich every SemanticModel in this one workspace. There is
    # no need for the global source_count/report_count ranking (that only
    # makes sense when picking a top-N subset across the whole tenant), and
    # $ModelSummaryPath (script 08's output) is not required.
    $targetModels = @(
        $items | Where-Object { $_.item_type -eq "SemanticModel" -and $_.workspace_name -eq $WorkspaceNameFilter }
    )
}
else {
    if (-not (Test-Path $ModelSummaryPath)) { throw "Required input not found: $ModelSummaryPath" }
    $modelSummary = @(Import-Csv -Path $ModelSummaryPath)
    $targetModels = @(
        $modelSummary |
            Sort-Object @{ Expression = { [int]$_.source_count }; Descending = $true }, @{ Expression = { [int]$_.report_count }; Descending = $true }, semantic_model_qualified_name |
            ForEach-Object { if ($itemByQualifiedName.ContainsKey($_.semantic_model_qualified_name)) { $itemByQualifiedName[$_.semantic_model_qualified_name] } }
    )
    if ($MaxModels -gt 0) { $targetModels = @($targetModels | Select-Object -First $MaxModels) }
}

$headers = New-FabricHeaders
$rows = [System.Collections.Generic.List[object]]::new()
$gaps = [System.Collections.Generic.List[object]]::new()
$seen = @{}
$processed = 0
$successCount = 0
$definitionPartCount = 0
# Same graceful-stop pattern as 04_analyze_items.ps1/06_discover_executions.ps1:
# when the az session itself is dead (refresh token past the tenant's 7-day
# Conditional Access cap, AADSTS70043 -- not just an access token due for a
# routine refresh), token acquisition throws. Uncaught, that used to abort
# the whole script before the end-of-script Export-Csv calls, losing every
# model already enriched this run. Stop the loop cleanly instead and fall
# through to the same writes.
$script:sessionDiedAt = $null

foreach ($model in $targetModels) {
    $processed += 1
    if ($ProgressInterval -gt 0 -and ($processed % $ProgressInterval -eq 0)) {
        Write-Host "Processed $processed / $($targetModels.Count) semantic model definitions..."
    }
    try {
        # Cache-hit cheap when the token is still fresh (Get-FreshAzureCliToken
        # keeps an in-module cache); only actually calls az when stale.
        $headers = New-FabricHeaders
    }
    catch {
        $script:sessionDiedAt = $processed
        Write-Host "Azure session appears to be fully expired (not just due for a routine refresh) after $processed / $($targetModels.Count) models -- stopping here instead of losing this run's progress. Re-authenticate (az login) and re-run to pick up the rest. Error: $($_.Exception.Message)"
        break
    }
    $workspaceId = if ($workspaceIdByName.ContainsKey($model.workspace_name)) { $workspaceIdByName[$model.workspace_name] } else { "" }
    if (-not $workspaceId) {
        $gaps.Add([pscustomobject]@{ workspace_name = $model.workspace_name; semantic_model_name = $model.item_name; semantic_model_qualified_name = $model.qualified_name; status_code = ""; error = "Workspace id missing."; notes = "" }) | Out-Null
        continue
    }
    $result = Get-SemanticModelDefinition -WorkspaceId $workspaceId -ModelId $model.technical_id -Headers $headers
    if (-not $result.succeeded -and [string]$result.status_code -eq "401" -and $result.error -match '(?i)TokenExpired|Access token has expired') {
        try {
            $headers = New-FabricHeaders
        }
        catch {
            $script:sessionDiedAt = $processed
            Write-Host "Azure session appears to be fully expired (not just due for a routine refresh) after $processed / $($targetModels.Count) models -- stopping here instead of losing this run's progress. Re-authenticate (az login) and re-run to pick up the rest. Error: $($_.Exception.Message)"
            break
        }
        $result = Get-SemanticModelDefinition -WorkspaceId $workspaceId -ModelId $model.technical_id -Headers $headers
    }
    if (-not $result.succeeded) {
        $gaps.Add([pscustomobject]@{ workspace_name = $model.workspace_name; semantic_model_name = $model.item_name; semantic_model_qualified_name = $model.qualified_name; status_code = $result.status_code; error = $result.error; notes = "Definition unavailable." }) | Out-Null
        continue
    }
    $successCount += 1
    $parts = @(Decode-DefinitionParts -DefinitionPayload $result.payload)
    $definitionPartCount += $parts.Count

    # Most models declare their connection ONCE, in a shared expression
    # (typically definition/expressions.tmdl -- "Source = Sql.Database(...)"),
    # and every per-table TMDL part (e.g. definition/tables/Union.tmdl) just
    # references that shared expression via Source{[Schema=...,Item=...]}
    # without repeating the Sql.Database(...) call. Parts are processed in
    # whatever order the definition API returned them, which is NOT
    # guaranteed to put expressions.tmdl first -- confirmed live: table parts
    # for "Contoso Operations / SemanticModel / Attendance" were returned
    # before expressions.tmdl. Without this pre-scan, every such table's real
    # object candidate is written with an empty database, which
    # get_candidate_objects_for_dependency (11_build_lineage_explorer_fast.py)
    # then fails to match to the model's actual SQL source dependency and
    # silently drops -- the exact table names never reached the UI even
    # though they were extracted. $modelServer/$modelDatabase is a
    # model-wide fallback used only when a given part has no local match of
    # its own (a part with its own explicit Sql.Database call keeps that).
    $modelServer = ""
    $modelDatabase = ""
    foreach ($part in $parts) {
        if (-not $part.text) { continue }
        $preScanMatch = [regex]::Match($part.text, 'Sql\.Database\(\s*"([^"]+)"\s*,\s*"([^"]+)"', 'IgnoreCase')
        if ($preScanMatch.Success) {
            $modelServer = $preScanMatch.Groups[1].Value
            $modelDatabase = $preScanMatch.Groups[2].Value
            break
        }
    }

    foreach ($part in $parts) {
        if (-not $part.text) { continue }
        $semanticTable = Get-TableNameFromPath -Path $part.path
        $server = ""
        $database = ""
        $sqlMatch = [regex]::Match($part.text, 'Sql\.Database\(\s*"([^"]+)"\s*,\s*"([^"]+)"', 'IgnoreCase')
        if ($sqlMatch.Success) {
            $server = $sqlMatch.Groups[1].Value
            $database = $sqlMatch.Groups[2].Value
            Add-ObjectCandidate -Rows $rows -Seen $seen -Model $model -DefinitionPath $part.path -SemanticTable $semanticTable -Server $server -Database $database -Schema "" -ObjectName "" -ObjectType "database" -Evidence "TMDL part references Sql.Database server/database." -Confidence "confirmed"
        }
        $effectiveServer = if ($server) { $server } else { $modelServer }
        $effectiveDatabase = if ($database) { $database } else { $modelDatabase }
        $schemaItemMatches = [regex]::Matches($part.text, '\[\s*Schema\s*=\s*"([^"]+)"\s*,\s*Item\s*=\s*"([^"]+)"(?<tail>[^\]]*)\]', 'IgnoreCase')
        foreach ($match in $schemaItemMatches) {
            $kind = ""
            $kindMatch = [regex]::Match($match.Groups["tail"].Value, 'Kind\s*=\s*"([^"]+)"', 'IgnoreCase')
            if ($kindMatch.Success) { $kind = $kindMatch.Groups[1].Value.ToLowerInvariant() }
            $objectType = if ($kind -eq "table") { "table" } elseif ($kind -eq "view") { "view" } else { "table_or_view" }
            $evidenceText = if ($kind) { "TMDL M expression contains Source{[Schema=...,Item=...,Kind=$kind]} lookup." } else { "TMDL M expression contains Source{[Schema=...,Item=...]} lookup." }
            if (-not $server -and $modelServer) { $evidenceText += " Server/database inferred from this model's shared connection expression." }
            Add-ObjectCandidate -Rows $rows -Seen $seen -Model $model -DefinitionPath $part.path -SemanticTable $semanticTable -Server $effectiveServer -Database $effectiveDatabase -Schema $match.Groups[1].Value -ObjectName $match.Groups[2].Value -ObjectType $objectType -Evidence $evidenceText -Confidence "confirmed"
        }
        if (Test-NativeSqlParseScope -DefinitionPath $part.path -Text $part.text) {
            $nativeQueryMatches = [regex]::Matches($part.text, '(?is)\b(from|join|exec(?:ute)?|call)\s+((?:\[[^\]]+\]|"[^"]+"|`[^`]+`|[A-Za-z_][A-Za-z0-9_$#-]*)(?:\s*\.\s*(?:\[[^\]]+\]|"[^"]+"|`[^`]+`|[A-Za-z_][A-Za-z0-9_$#-]*)){0,2})')
            foreach ($match in $nativeQueryMatches) {
                if (-not (Test-NativeMatchContext -Text $part.text -Index $match.Index)) { continue }
                $verb = ($match.Groups[1].Value -replace '\s+', ' ').ToLowerInvariant()
                $raw = $match.Groups[2].Value.Trim()
                if (-not $raw -or $raw -match '^\(') { continue }
                $segments = @($raw -split '\.' | ForEach-Object { Normalize-NativeIdentifierPart $_ } | Where-Object { $_ })
                $schema = ""
                $object = ""
                if ($segments.Count -eq 1) {
                    $object = $segments[0]
                } elseif ($segments.Count -ge 2) {
                    $schema = $segments[$segments.Count - 2]
                    $object = $segments[$segments.Count - 1]
                }
                if (Test-NativeObjectCandidate -ObjectName $object -SchemaName $schema) {
                    $nativeObjectType = if ($verb -match 'exec|call') { "stored_procedure" } else { "native_query_object" }
                    $nativeEvidence = if ($nativeObjectType -eq "stored_procedure") { "TMDL M/native query text contains EXEC/CALL stored procedure reference." } else { "TMDL M/native query text contains FROM/JOIN object reference." }
                    Add-ObjectCandidate -Rows $rows -Seen $seen -Model $model -DefinitionPath $part.path -SemanticTable $semanticTable -Server $effectiveServer -Database $effectiveDatabase -Schema $schema -ObjectName $object -ObjectType $nativeObjectType -Evidence $nativeEvidence -Confidence "likely"
                }
            }
        }
    }
}

$finalRows = $rows
$finalGaps = $gaps
if ($WorkspaceNameFilter) {
    # Retain every other workspace's previously-enriched rows -- this run
    # only recomputed $WorkspaceNameFilter's models, so a plain overwrite
    # would silently delete every other workspace's object candidates.
    $retainedRows = if (Test-Path $OutputPath) {
        @(Import-Csv -Path $OutputPath | Where-Object { $_.workspace_name -ne $WorkspaceNameFilter })
    } else { @() }
    # Wrap EACH side in @() before concatenating, not just the result:
    # `@($a + @($b))` still evaluates `$a + ...` first, so if Where-Object
    # (or Import-Csv on a single-row CSV) ever collapses $a down to one bare
    # PSObject instead of an array, `+` tries to call a PSObject method that
    # doesn't exist (op_Addition) instead of concatenating -- seen live: a
    # scoped re-run crashed here once the retained-gaps filter matched
    # exactly one row.
    $finalRows = @($retainedRows) + @($rows)
    $retainedGaps = if (Test-Path $GapPath) {
        @(Import-Csv -Path $GapPath | Where-Object { $_.workspace_name -ne $WorkspaceNameFilter })
    } else { @() }
    $finalGaps = @($retainedGaps) + @($gaps)
}

Ensure-ParentDirectory -Path $OutputPath
$finalRows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Ensure-ParentDirectory -Path $GapPath
if ($finalGaps.Count -gt 0) {
    $finalGaps | Export-Csv -Path $GapPath -NoTypeInformation -Encoding UTF8
}
else {
    "workspace_name,semantic_model_name,semantic_model_qualified_name,status_code,error,notes" | Set-Content -Path $GapPath -Encoding UTF8
}

$confirmedObjects = @($rows | Where-Object { $_.object_name -and $_.confidence -eq "confirmed" }).Count
$likelyObjects = @($rows | Where-Object { $_.object_name -and $_.confidence -eq "likely" }).Count

Set-UnresolvedEntry `
    -Title "Semantic model definition enrichment gaps" `
    -Status "open" `
    -Evidence "Processed $($targetModels.Count) prioritized semantic models; $successCount definitions succeeded; $($gaps.Count) definitions unavailable. Extracted $($rows.Count) source candidates, including $confirmedObjects confirmed table/view lookups and $likelyObjects likely native-query objects." `
    -NextStep "Review analysis/semantic_model_view_candidates.csv, then continue enrichment for remaining semantic models or confirm table/view names with technical owners."

if ($script:sessionDiedAt) {
    Write-Host "Semantic model definition enrichment STOPPED EARLY: Azure session expired after $script:sessionDiedAt / $($targetModels.Count) models. Everything gathered up to that point was still written below. Re-authenticate (az login) and re-run to cover the rest."
}
else {
    Write-Host "Semantic model definition enrichment completed."
}
Write-Host "Target models: $($targetModels.Count)"
Write-Host "Definitions succeeded: $successCount"
Write-Host "Definition gaps: $($gaps.Count)"
Write-Host "Decoded parts: $definitionPartCount"
Write-Host "Source candidates: $($rows.Count)"
Write-Host "Confirmed table/view lookups: $confirmedObjects"
Write-Host "Likely native-query objects: $likelyObjects"
Write-Host "Output: $OutputPath"
Write-Host "Gaps: $GapPath"

if ($script:sessionDiedAt) {
    # Distinct from a clean completion so a caller (99_refresh or a
    # per-workspace driver loop) knows coverage is incomplete and stops
    # instead of burning through more workspaces with a dead session.
    exit 1
}
