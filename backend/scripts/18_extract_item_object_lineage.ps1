# Phase 18 - Item object lineage extraction: fetches each item's
# getDefinition payload for the types in $ItemTypes (Notebook, CopyJob,
# Dataflow, Eventstream, KQLQueryset, Reflex, UserDataFunction, GraphQLApi,
# DataAgent) and parses each type's structurally different definition
# format for real source/destination table references.
# Writes: $OutputPath (object candidates), $GapPath (definitions unavailable).
param(
    [string]$WorkspaceIndexPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "../../analysis/item_object_lineage_candidates.csv"),
    [string]$GapPath = (Join-Path $PSScriptRoot "../../analysis/item_object_lineage_gaps.csv"),
    [string]$UnresolvedPath = (Join-Path $PSScriptRoot "../../index/unresolved.md"),
    [string]$AzCommand = "az",
    [string]$FabricApiBaseUrl = "https://api.fabric.microsoft.com/v1",
    # Warehouse and VariableLibrary deliberately excluded: Warehouse's
    # getDefinition call returns "OperationNotSupportedForItem" (confirmed
    # live against the tenant -- there is no definition format for it to
    # read), and VariableLibrary's definition is just variable name/value
    # pairs with no source-table lineage of its own to extract.
    [string[]]$ItemTypes = @("Notebook", "CopyJob", "Dataflow", "Eventstream", "KQLQueryset", "Reflex", "UserDataFunction", "GraphQLApi", "DataAgent"),
    [int]$MaxItems = 0,
    [int]$RetryCount = 5,
    [int]$RequestDelayMilliseconds = 250,
    [int]$MaxOperationPolls = 20,
    [int]$MaxOperationDelaySeconds = 15,
    [int]$ProgressInterval = 20,
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

# Get-FieldValue always stringifies its result -- fine for scalar leaves,
# but wrong for a JSON array/object property (e.g. "children", "elements",
# "dataSources"), which would collapse into a useless "System.Object[]"
# string. The structured-definition parsers below (Eventstream, KQL
# queryset, Reflex, GraphQL API, Data Agent) walk real nested JSON, so they
# need the raw value back, not a string.
function Get-JsonProperty {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
    return $null
}

function Normalize-Key {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return ($Value.Trim().ToLowerInvariant() -replace "\s+", " ")
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
    # the cached token is stale -- important here since this script's
    # per-item definition fetches (Report/PaginatedReport especially) can
    # add up to a long-running scan.
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

function Get-DefinitionPath {
    param([string]$WorkspaceId, [string]$ItemId, [string]$ItemType)
    $path = "workspaces/$WorkspaceId/items/$ItemId/getDefinition"
    if ($ItemType -eq "Notebook") { return "$path`?format=fabricGitSource" }
    return $path
}

function Get-ItemDefinition {
    param([string]$WorkspaceId, [string]$ItemId, [string]$ItemType, [hashtable]$Headers)
    $path = Get-DefinitionPath -WorkspaceId $WorkspaceId -ItemId $ItemId -ItemType $ItemType
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
            $parts += [pscustomobject]@{ path = $path; text = $text }
        }
        catch {
            $parts += [pscustomobject]@{ path = $path; text = "" }
        }
    }
    return $parts
}

function ConvertFrom-JsonStringLiteral {
    param([string]$Value)
    if (-not $Value) { return "" }
    try { return (ConvertFrom-Json -InputObject "`"$Value`"") } catch { return $Value }
}

function Test-ObjectIdentifierNoise {
    param([string]$Value)
    if (-not $Value) { return $true }
    $clean = ($Value -replace "\s+", " ").Trim()
    if (-not $clean) { return $true }
    if ($clean -match '(?i)\bimport\b') { return $true }
    if ($clean -match '^(?i)(select|with|where|join|from|on|and|or|as)$') { return $true }
    if ($clean -match '^(?i)(delta|overwrite|append|parquet|csv|json|text|true|false|none|null|default)$') { return $true }
    if ($clean -match '^(?i)https?://(?:developer\.microsoft\.com|[^/]+\.vault\.azure\.net|[^/]*pkgs\.dev\.azure\.com|analysis\.windows\.net|api\.fabric\.microsoft\.com|storage\.azure\.com)(?:/|$)') { return $true }
    return $false
}

function Split-ObjectIdentifier {
    param([string]$Identifier)
    $clean = ConvertFrom-JsonStringLiteral -Value $Identifier
    $clean = ($clean -replace '[`\[\]"'']', '').Trim()
    $clean = $clean -replace '\\+', '/'
    $clean = $clean.Trim("/")
    if (Test-ObjectIdentifierNoise -Value $clean) { return $null }
    if ($clean -match '^(?i)(http|https|abfss|wasbs|s3)://') {
        return [pscustomobject]@{ source_database = ""; schema_name = ""; object_name = $clean; source_type = "File"; object_type = "file" }
    }
    if ($clean -match '^(?i)(Files|Tables|Lakehouse|Warehouse)/(.+)$') {
        return [pscustomobject]@{ source_database = ""; schema_name = ""; object_name = $clean; source_type = "Fabric"; object_type = "file" }
    }
    $segments = @($clean -split '\.' | Where-Object { $_ })
    if ($segments.Count -eq 1) {
        return [pscustomobject]@{ source_database = ""; schema_name = ""; object_name = $segments[0]; source_type = ""; object_type = "table_or_view" }
    }
    if ($segments.Count -eq 2) {
        return [pscustomobject]@{ source_database = ""; schema_name = $segments[0]; object_name = $segments[1]; source_type = ""; object_type = "table_or_view" }
    }
    return [pscustomobject]@{ source_database = $segments[0]; schema_name = $segments[$segments.Count - 2]; object_name = $segments[$segments.Count - 1]; source_type = ""; object_type = "table_or_view" }
}

function Get-ContextUsage {
    param([string]$Text, [int]$Index, [string]$DefaultUsage)
    $start = [math]::Max(0, $Index - 320)
    $length = [math]::Min(640, $Text.Length - $start)
    $context = $Text.Substring($start, $length)
    if ($context -match '(?i)(sink|destination|target|write|saveAsTable|writeTo|output)') { return "writes_to" }
    if ($context -match '(?i)(storedProcedure|procedure|exec|call)') { return "executes" }
    if ($context -match '(?i)(source|input|read|from|join|dbtable|query)') { return "reads_from" }
    return $DefaultUsage
}

function Add-Candidate {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$Item,
        [object]$ObjectParts,
        [string]$DefinitionPath,
        [string]$UsageType,
        [string]$ObjectType,
        [string]$SourceType,
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$Evidence,
        [string]$Confidence
    )
    if (-not $ObjectParts -or -not $ObjectParts.object_name) { return }
    $finalSourceType = if ($SourceType) { $SourceType } elseif ($ObjectParts.source_type) { $ObjectParts.source_type } else { "FabricOrSQL" }
    $finalDatabase = if ($SourceDatabase) { $SourceDatabase } else { $ObjectParts.source_database }
    $finalObjectType = if ($ObjectType) { $ObjectType } elseif ($ObjectParts.object_type) { $ObjectParts.object_type } else { "table_or_view" }
    $key = @(
        $Item.qualified_name,
        $DefinitionPath,
        $finalSourceType,
        $SourceServer,
        $finalDatabase,
        $ObjectParts.schema_name,
        $ObjectParts.object_name,
        $UsageType,
        $finalObjectType
    ) | ForEach-Object { Normalize-Key $_ }
    $key = $key -join "|"
    if ($Seen.ContainsKey($key)) { return }
    $Seen[$key] = $true

    $Rows.Add([pscustomobject]@{
        workspace_name = $Item.workspace_name
        workspace_environment = $Item.workspace_environment
        item_type = $Item.item_type
        item_name = $Item.item_name
        item_qualified_name = $Item.qualified_name
        source_type = $finalSourceType
        source_name = if ($finalDatabase) { $finalDatabase } else { $finalSourceType }
        source_qualified_name = ""
        source_server = $SourceServer
        source_database = $finalDatabase
        schema_name = $ObjectParts.schema_name
        object_name = $ObjectParts.object_name
        object_type = $finalObjectType
        usage_type = $UsageType
        confidence = $Confidence
        definition_path = $DefinitionPath
        evidence = Limit-Text -Text $Evidence -MaxLength 1200
    }) | Out-Null
}

function Add-StringPatternCandidates {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$Item,
        [string]$Path,
        [string]$Text
    )
    $patterns = @(
        @{ regex = '(?is)\b(?:spark\.read\.table|read\.table|table|saveAsTable|writeTo|DeltaTable\.forName)\s*\(\s*["'']([^"'']+)["'']'; value_group = 1; usage = "reads_from"; type = "table_or_view"; evidence = "Notebook/table API references object." },
        @{ regex = '(?is)\b(?:option|set)\s*\(\s*["''](?:dbtable|tableName|table|schemaTable)["'']\s*,\s*["'']([^"'']+)["'']'; value_group = 1; usage = "reads_from"; type = "table_or_view"; evidence = "Definition option references table object." },
        @{ regex = '(?is)\b(?:option|set)\s*\(\s*["''](?:query|sqlQuery)["'']\s*,\s*["'']([^"'']+)["'']'; value_group = 1; usage = "reads_from"; type = "native_query_object"; evidence = "Definition option contains SQL query text." },
        @{ regex = '(?is)["'']((?:abfss|https?|wasbs|s3)://[^"'']+)["'']'; value_group = 1; usage = "reads_from"; type = "file"; evidence = "Definition references external file/path." },
        # "sp" used to be a bare alternative here (to catch stored-procedure-
        # named variables), but as a 2-character substring it matched almost
        # anything containing those letters in sequence -- "workSPaceId",
        # "reSPonse", "diSPlay" -- turning unrelated M/JSON keys like
        # `workspaceId = "<guid>"` into fake table candidates. Real stored
        # procedure calls are already caught by Add-SqlObjectCandidates via
        # the exec/call SQL keywords, so this only needs table/view/
        # procedure now.
        @{ regex = '(?is)\b([A-Za-z0-9_]*(?:table|view|procedure|stored_procedure)[A-Za-z0-9_]*)\s*=\s*["'']([^"'']+)["'']'; value_group = 2; variable_group = 1; usage = "reads_from"; type = "table_or_view"; evidence = "Notebook/object variable references object." }
    )
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($Text, $pattern.regex)) {
            $valueGroup = if ($pattern.ContainsKey("value_group")) { [int]$pattern.value_group } else { 1 }
            $value = $match.Groups[$valueGroup].Value
            if ($pattern.type -eq "native_query_object") {
                Add-SqlObjectCandidates -Rows $Rows -Seen $Seen -Item $Item -Path $Path -SqlText $value -DefaultUsage $pattern.usage -Evidence $pattern.evidence
                continue
            }
            $parts = Split-ObjectIdentifier -Identifier $value
            $usage = if ($match.Value -match '(?i)(saveAsTable|writeTo)') { "writes_to" } else { Get-ContextUsage -Text $Text -Index $match.Index -DefaultUsage $pattern.usage }
            $objectType = $pattern.type
            $variableName = if ($pattern.ContainsKey("variable_group")) { $match.Groups[[int]$pattern.variable_group].Value } else { "" }
            if ($pattern.evidence -eq "Notebook/object variable references object." -and $variableName -match '(?i)(procedure|stored_procedure|^sp_|_sp$)') {
                $objectType = "stored_procedure"
            }
            if ($objectType -eq "stored_procedure") { $usage = "executes" }
            Add-Candidate -Rows $Rows -Seen $Seen -Item $Item -ObjectParts $parts -DefinitionPath $Path -UsageType $usage -ObjectType $objectType -SourceType "" -SourceServer "" -SourceDatabase "" -Evidence "$($pattern.evidence) Path '$Path'." -Confidence "likely"
        }
    }
}

function Add-SqlObjectCandidates {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$Item,
        [string]$Path,
        [string]$SqlText,
        [string]$DefaultUsage,
        [string]$Evidence
    )
    if (-not $SqlText) { return }
    $sql = ConvertFrom-JsonStringLiteral -Value $SqlText
    $sqlPattern = '(?is)\b(from|join|into|update|merge\s+into|delete\s+from|exec(?:ute)?|call)\s+((?:\[[^\]]+\]|"[^"]+"|`[^`]+`|[A-Za-z_][A-Za-z0-9_$#-]*)(?:\s*\.\s*(?:\[[^\]]+\]|"[^"]+"|`[^`]+`|[A-Za-z_][A-Za-z0-9_$#-]*)){0,2})'
    $matches = [regex]::Matches($sql, $sqlPattern)
    foreach ($match in $matches) {
        $lineStart = $sql.LastIndexOf("`n", [math]::Max(0, $match.Index))
        if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart += 1 }
        $lineEnd = $sql.IndexOf("`n", $match.Index)
        if ($lineEnd -lt 0) { $lineEnd = $sql.Length }
        $line = $sql.Substring($lineStart, $lineEnd - $lineStart)
        if ($line -match '(?i)^\s*from\s+[A-Za-z0-9_.]+\s+import\b') { continue }

        $verb = ($match.Groups[1].Value -replace '\s+', ' ').ToLowerInvariant()
        $identifier = $match.Groups[2].Value.Trim()
        $parts = Split-ObjectIdentifier -Identifier $identifier
        if (-not $parts) { continue }
        $usage = $DefaultUsage
        $objectType = "native_query_object"
        if ($verb -match 'into|update|merge|delete') { $usage = "writes_to" }
        elseif ($verb -match 'exec|call') { $usage = "executes"; $objectType = "stored_procedure" }
        else { $usage = "reads_from" }
        Add-Candidate -Rows $Rows -Seen $Seen -Item $Item -ObjectParts $parts -DefinitionPath $Path -UsageType $usage -ObjectType $objectType -SourceType "" -SourceServer "" -SourceDatabase "" -Evidence "$Evidence SQL keyword '$verb' references object in '$Path'." -Confidence "likely"
    }
}

function Add-EmbeddedSqlCandidates {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$Item,
        [string]$Path,
        [string]$Text
    )
    if (-not $Text) { return }

    $sqlStringPatterns = @(
        '(?is)\b(?:spark|sqlContext|session)\.sql\s*\(\s*(?:"""(.*?)"""|''''''(.*?)''''''|"([^"]+)"|''([^'']+)'')',
        '(?is)\b(?:query|sql|sql_text|sql_query|statement)\s*=\s*(?:"""(.*?)"""|''''''(.*?)''''''|"([^"]+)"|''([^'']+)'')',
        '(?is)"(?:query|sqlQuery|sourceQuery|sqlStatement)"\s*:\s*"((?:\\.|[^"])*)"'
    )
    foreach ($pattern in $sqlStringPatterns) {
        foreach ($match in [regex]::Matches($Text, $pattern)) {
            $value = ""
            for ($groupIndex = 1; $groupIndex -lt $match.Groups.Count; $groupIndex++) {
                if ($match.Groups[$groupIndex].Success -and $match.Groups[$groupIndex].Value) {
                    $value = $match.Groups[$groupIndex].Value
                    break
                }
            }
            if ($value -and $value -match '(?i)\b(select|from|join|exec|execute|call|merge|update|delete|insert\s+into)\b') {
                Add-SqlObjectCandidates -Rows $Rows -Seen $Seen -Item $Item -Path $Path -SqlText $value -DefaultUsage "reads_from" -Evidence "Embedded SQL/query parser"
            }
        }
    }

    $lines = @($Text -split "`r?`n")
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -notmatch '^\s*(?:# MAGIC\s*)?%%?sql\b') { continue }
        $buffer = [System.Collections.Generic.List[string]]::new()
        for ($next = $index + 1; $next -lt $lines.Count; $next++) {
            if ($lines[$next] -match '^\s*# COMMAND\b') { break }
            if ($lines[$next] -match '^\s*(?:# MAGIC\s*)?%%?(?:md|python|pyspark|scala|r)\b') { break }
            $buffer.Add(($lines[$next] -replace '^\s*# MAGIC\s?', '')) | Out-Null
        }
        $sqlBlock = ($buffer.ToArray() -join "`n")
        if ($sqlBlock -match '(?i)\b(select|from|join|exec|execute|call|merge|update|delete|insert\s+into)\b') {
            Add-SqlObjectCandidates -Rows $Rows -Seen $Seen -Item $Item -Path $Path -SqlText $sqlBlock -DefaultUsage "reads_from" -Evidence "Notebook SQL magic parser"
        }
    }
}

function Get-MashupQueryBlocks {
    # A Dataflow Gen2 mashup document is a flat sequence of independent
    # `shared <Name> = let ... in ... ;` query definitions, each with its
    # OWN data source connection. Splitting on each "shared" boundary (
    # instead of regexing the whole document at once) is what lets a
    # Sql.Database(...) call be correlated with the specific Schema/Item
    # table navigation that belongs to THAT query, instead of every table
    # name found anywhere in the document losing its database association
    # (see the comment on Add-MashupObjectCandidates below for why that
    # mattered).
    param([string]$Text)
    if (-not $Text) { return @() }
    $boundaries = [regex]::Matches($Text, '(?m)^\s*shared\s+')
    if ($boundaries.Count -eq 0) { return @($Text) }
    $blocks = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $boundaries.Count; $i++) {
        $start = $boundaries[$i].Index
        $end = if ($i + 1 -lt $boundaries.Count) { $boundaries[$i + 1].Index } else { $Text.Length }
        $blocks.Add($Text.Substring($start, $end - $start)) | Out-Null
    }
    return $blocks.ToArray()
}

function Add-MashupObjectCandidates {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$Item,
        [string]$Path,
        [string]$Text
    )
    if (-not $Text) { return }

    foreach ($block in (Get-MashupQueryBlocks -Text $Text)) {
        # SQL source: Power Query M names it the same way a semantic model's
        # Import/DirectQuery partition does (see 09_enrich_semantic_model_
        # views.ps1) -- a Sql.Database(server, database) connector call,
        # then a [Schema="x",Item="y"] navigation step for the actual
        # table/view. Scoped to one query block at a time so the
        # server/database actually belongs to the table found alongside it,
        # instead of every Sql.Database call in the whole document getting
        # flattened into one placeholder "database" row while every table
        # name anywhere lost its database association entirely (previously
        # they fell back to a genericless "FabricOrSQL" grouping in the
        # explorer, unable to drill down like every other source type does).
        $sqlDatabaseMatch = [regex]::Match($block, 'Sql\.Databases?\(\s*"([^"]+)"\s*(?:,\s*"([^"]+)")?', 'IgnoreCase')
        if ($sqlDatabaseMatch.Success -and $sqlDatabaseMatch.Groups[2].Value) {
            $server = $sqlDatabaseMatch.Groups[1].Value
            $database = $sqlDatabaseMatch.Groups[2].Value
            $navMatches = @([regex]::Matches($block, '\[\s*Schema\s*=\s*"([^"]*)"\s*,\s*Item\s*=\s*"([^"]+)"', 'IgnoreCase'))
            if ($navMatches.Count -gt 0) {
                foreach ($navMatch in $navMatches) {
                    $schema = $navMatch.Groups[1].Value
                    $tableName = $navMatch.Groups[2].Value
                    if (Test-ObjectIdentifierNoise -Value $tableName) { continue }
                    $parts = [pscustomobject]@{ source_database = $database; schema_name = $schema; object_name = $tableName; source_type = "SQL"; object_type = "table_or_view" }
                    Add-Candidate -Rows $Rows -Seen $Seen -Item $Item -ObjectParts $parts -DefinitionPath $Path -UsageType "reads_from" -ObjectType "table_or_view" -SourceType "SQL" -SourceServer $server -SourceDatabase $database -Evidence "Dataflow M query reads Schema/Item table via Sql.Database($server, $database) in '$Path'." -Confidence "confirmed"
                }
            }
            else {
                # A connection to the database with no specific table nav
                # found in this block -- record what we do know (the
                # connection) rather than nothing, same as every other
                # source-only item elsewhere in this project.
                $parts = [pscustomobject]@{ source_database = $database; schema_name = ""; object_name = $database; source_type = "SQL"; object_type = "database" }
                Add-Candidate -Rows $Rows -Seen $Seen -Item $Item -ObjectParts $parts -DefinitionPath $Path -UsageType "reads_from" -ObjectType "database" -SourceType "SQL" -SourceServer $server -SourceDatabase $database -Evidence "Dataflow M query references Sql.Database server/database (no specific table navigation found in this query) in '$Path'." -Confidence "confirmed"
            }
            continue
        }

        # Fabric Lakehouse source/destination: Dataflow Gen2's own output
        # (and a Lakehouse used as a read source) is addressed via
        # Lakehouse.Contents() then a workspaceId/lakehouseId/table-id
        # navigation chain -- a completely different shape than the SQL
        # connector above, so it had no handling at all before this and
        # silently produced zero objects for every Lakehouse source or
        # destination. workspaceId/lakehouseId are real Fabric GUIDs, not
        # object identity by themselves -- resolved to their friendly
        # names via $WorkspaceNameById/$LakehouseNameById (built from
        # index/workspaces.csv and index/items.csv) so the drill-down reads
        # like every other source instead of raw GUIDs.
        if ($block -match 'Lakehouse\.Contents\s*\(') {
            $tableMatch = [regex]::Match($block, '\[\s*Id\s*=\s*"([^"]+)"\s*,\s*ItemKind\s*=\s*"Table"', 'IgnoreCase')
            if ($tableMatch.Success) {
                $tableName = $tableMatch.Groups[1].Value
                if (-not (Test-ObjectIdentifierNoise -Value $tableName)) {
                    $workspaceIdMatch = [regex]::Match($block, 'workspaceId\s*=\s*"([^"]+)"', 'IgnoreCase')
                    $lakehouseIdMatch = [regex]::Match($block, 'lakehouseId\s*=\s*"([^"]+)"', 'IgnoreCase')
                    $workspaceId = if ($workspaceIdMatch.Success) { $workspaceIdMatch.Groups[1].Value } else { "" }
                    $lakehouseId = if ($lakehouseIdMatch.Success) { $lakehouseIdMatch.Groups[1].Value } else { "" }
                    $workspaceName = if ($workspaceId -and $WorkspaceNameById.ContainsKey($workspaceId)) { $WorkspaceNameById[$workspaceId] } else { $workspaceId }
                    $lakehouseName = if ($lakehouseId -and $LakehouseNameById.ContainsKey($lakehouseId)) { $LakehouseNameById[$lakehouseId] } else { $lakehouseId }
                    $usage = if ($block -match '(?i)DataDestination') { "writes_to" } else { "reads_from" }
                    $parts = [pscustomobject]@{ source_database = $lakehouseName; schema_name = ""; object_name = $tableName; source_type = "Fabric"; object_type = "table_or_view" }
                    Add-Candidate -Rows $Rows -Seen $Seen -Item $Item -ObjectParts $parts -DefinitionPath $Path -UsageType $usage -ObjectType "table_or_view" -SourceType "Fabric" -SourceServer $workspaceName -SourceDatabase $lakehouseName -Evidence "Dataflow M query navigates to Lakehouse table '$tableName' (workspace '$workspaceName', lakehouse '$lakehouseName') in '$Path'." -Confidence "confirmed"
                }
            }
        }
    }
}

function Add-EventstreamObjectCandidates {
    # eventstream.json is a plain, well-structured JSON document -- no
    # regex heuristics needed, unlike Notebook/CopyJob free-text code.
    # Connector "properties" vary a lot by type (Eventhub, IoT Hub, Azure
    # Blob events, CDC, another Fabric item, ...), so instead of a
    # branch per connector type this just looks for the first recognizable
    # identifier anywhere inside that one source/destination's own
    # properties -- enough to say WHICH external system or Fabric item is
    # on the other end, even for connector types nobody has special-cased.
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$Item,
        [string]$Path,
        [string]$Text
    )
    $payload = Convert-JsonContent -Content $Text
    if (-not $payload) { return }
    foreach ($direction in @(
        @{ key = "sources"; usage = "reads_from" },
        @{ key = "destinations"; usage = "writes_to" }
    )) {
        foreach ($entry in @(Get-JsonProperty -Object $payload -Name $direction.key)) {
            if (-not $entry) { continue }
            $name = Get-FieldValue -Object $entry -Names @("name")
            $connectorType = Get-FieldValue -Object $entry -Names @("type")
            if (-not $name) { continue }
            $identifier = Find-FirstJsonStringValue -Node $entry -Names @("azureResourceId", "databaseItemName", "workspaceId", "connectionId", "server", "eventHubName", "topicName", "consumerGroup")
            $parts = [pscustomobject]@{ source_database = $identifier; schema_name = ""; object_name = $name; source_type = "Eventstream"; object_type = "connection" }
            Add-Candidate -Rows $Rows -Seen $Seen -Item $Item -ObjectParts $parts -DefinitionPath $Path -UsageType $direction.usage -ObjectType "connection" -SourceType "Eventstream" -SourceServer $connectorType -SourceDatabase $identifier -Evidence "Eventstream $($direction.key) '$name' (connector type '$connectorType') in '$Path'." -Confidence "confirmed"
        }
    }
}

function Find-FirstJsonStringValue {
    # Order matters here: a real array/List is ALSO something whose
    # .PSObject.Properties happens to resolve (Length, Count, ...), so
    # checking "does this have properties" before "is this a collection"
    # would silently walk an array's own CLR reflection metadata instead
    # of its elements -- and eventually hit some nested property (e.g.
    # SyncRoot) that isn't a normal PSObject and throws. PSCustomObject
    # (what ConvertFrom-Json produces for a JSON object) is not itself
    # enumerable, so checking IEnumerable first correctly separates the
    # two without misrouting either.
    param([object]$Node, [string[]]$Names, [int]$MaxDepth = 6)
    if ($MaxDepth -le 0 -or $null -eq $Node) { return "" }
    if ($Node -is [string]) { return "" }
    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) {
            $found = Find-FirstJsonStringValue -Node $item -Names $Names -MaxDepth ($MaxDepth - 1)
            if ($found) { return $found }
        }
        return ""
    }
    if ($Node.PSObject -and $Node.PSObject.Properties) {
        foreach ($name in $Names) {
            if ($Node.PSObject.Properties.Name -contains $name) {
                $value = $Node.$name
                if ($value -is [string] -and $value) { return $value }
            }
        }
        foreach ($prop in $Node.PSObject.Properties) {
            $found = Find-FirstJsonStringValue -Node $prop.Value -Names $Names -MaxDepth ($MaxDepth - 1)
            if ($found) { return $found }
        }
    }
    return ""
}

function Add-KqlQuerysetObjectCandidates {
    # RealTimeQueryset.json: queryset.dataSources[] names the real
    # Eventhouse/KQL database this queryset runs against; queryset.tabs[]
    # holds the actual KQL query text, which (like SQL) names its own
    # tables -- just with Kusto's syntax instead of FROM/JOIN (a bare
    # identifier at the start of a query, or after union/join/database()).
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$Item,
        [string]$Path,
        [string]$Text
    )
    $payload = Convert-JsonContent -Content $Text
    $queryset = Get-JsonProperty -Object $payload -Name "queryset"
    if (-not $queryset) { return }
    foreach ($dataSource in @(Get-JsonProperty -Object $queryset -Name "dataSources")) {
        if (-not $dataSource) { continue }
        $databaseName = Get-FieldValue -Object $dataSource -Names @("databaseItemName")
        $clusterUri = Get-FieldValue -Object $dataSource -Names @("clusterUri")
        if (-not $databaseName) { continue }
        $dbParts = [pscustomobject]@{ source_database = $databaseName; schema_name = ""; object_name = $databaseName; source_type = "KQL"; object_type = "database" }
        Add-Candidate -Rows $Rows -Seen $Seen -Item $Item -ObjectParts $dbParts -DefinitionPath $Path -UsageType "reads_from" -ObjectType "database" -SourceType "KQL" -SourceServer $clusterUri -SourceDatabase $databaseName -Evidence "KQL queryset data source '$databaseName' in '$Path'." -Confidence "confirmed"

        foreach ($tab in @(Get-JsonProperty -Object $queryset -Name "tabs")) {
            $content = Get-FieldValue -Object $tab -Names @("content")
            if (-not $content) { continue }
            $tableNames = [System.Collections.Generic.List[string]]::new()
            $baseMatch = [regex]::Match($content, '(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\r?\n\s*\||\|)')
            if ($baseMatch.Success) { $tableNames.Add($baseMatch.Groups[1].Value) | Out-Null }
            foreach ($unionMatch in [regex]::Matches($content, '(?i)\bunion\s+(?:kind\s*=\s*\w+\s+)?([A-Za-z_][A-Za-z0-9_,\s]*)')) {
                foreach ($name in ($unionMatch.Groups[1].Value -split ',')) { $tableNames.Add($name.Trim()) | Out-Null }
            }
            foreach ($joinMatch in [regex]::Matches($content, '(?i)\bjoin\s+(?:kind\s*=\s*\w+\s+)?\(?\s*([A-Za-z_][A-Za-z0-9_]*)')) {
                $tableNames.Add($joinMatch.Groups[1].Value) | Out-Null
            }
            foreach ($crossDbMatch in [regex]::Matches($content, '(?i)database\(\s*"([^"]+)"\s*\)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*)')) {
                $crossDbParts = [pscustomobject]@{ source_database = $crossDbMatch.Groups[1].Value; schema_name = ""; object_name = $crossDbMatch.Groups[2].Value; source_type = "KQL"; object_type = "table_or_view" }
                Add-Candidate -Rows $Rows -Seen $Seen -Item $Item -ObjectParts $crossDbParts -DefinitionPath $Path -UsageType "reads_from" -ObjectType "table_or_view" -SourceType "KQL" -SourceServer $clusterUri -SourceDatabase $crossDbMatch.Groups[1].Value -Evidence "KQL query cross-database reference in '$Path'." -Confidence "confirmed"
            }
            foreach ($tableName in $tableNames) {
                if (Test-ObjectIdentifierNoise -Value $tableName) { continue }
                if ($tableName -match '^(?i)(let|set|print|range|datatable)$') { continue }
                $tParts = [pscustomobject]@{ source_database = $databaseName; schema_name = ""; object_name = $tableName; source_type = "KQL"; object_type = "table_or_view" }
                Add-Candidate -Rows $Rows -Seen $Seen -Item $Item -ObjectParts $tParts -DefinitionPath $Path -UsageType "reads_from" -ObjectType "table_or_view" -SourceType "KQL" -SourceServer $clusterUri -SourceDatabase $databaseName -Evidence "KQL query references table '$tableName' in '$Path'." -Confidence "likely"
            }
        }
    }
}

function Add-ReflexObjectCandidates {
    # ReflexEntities.json (Data Activator) is a flat array of entities.
    # The two shapes worth surfacing: payload.fabricItem (an action that
    # runs another Fabric item -- e.g. a Pipeline) and payload.connection
    # (an event source this Reflex reacts to -- e.g. job-completion events
    # from another workspace/item). Both only carry the target's raw
    # workspaceId/itemId, resolved here via $ItemNameById/$WorkspaceNameById
    # (built from index/items.csv and index/workspaces.csv) so this reads
    # as real names, not GUIDs.
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$Item,
        [string]$Path,
        [string]$Text
    )
    $payload = Convert-JsonContent -Content $Text
    if (-not $payload) { return }
    foreach ($entity in @($payload)) {
        $entityPayload = Get-JsonProperty -Object $entity -Name "payload"
        if (-not $entityPayload) { continue }

        $fabricItem = Get-JsonProperty -Object $entityPayload -Name "fabricItem"
        if ($fabricItem) {
            $itemId = Get-FieldValue -Object $fabricItem -Names @("itemId")
            $workspaceId = Get-FieldValue -Object $fabricItem -Names @("workspaceId")
            $itemType = Get-FieldValue -Object $fabricItem -Names @("itemType")
            $itemName = if ($itemId -and $ItemNameById.ContainsKey($itemId)) { $ItemNameById[$itemId] } else { $itemId }
            $workspaceName = if ($workspaceId -and $WorkspaceNameById.ContainsKey($workspaceId)) { $WorkspaceNameById[$workspaceId] } else { $workspaceId }
            if ($itemName) {
                $parts = [pscustomobject]@{ source_database = $workspaceName; schema_name = ""; object_name = $itemName; source_type = "Fabric"; object_type = "item_reference" }
                Add-Candidate -Rows $Rows -Seen $Seen -Item $Item -ObjectParts $parts -DefinitionPath $Path -UsageType "executes" -ObjectType "item_reference" -SourceType "Fabric" -SourceServer $workspaceName -SourceDatabase $workspaceName -Evidence "Reflex action runs Fabric $itemType '$itemName' (workspace '$workspaceName') in '$Path'." -Confidence "confirmed"
            }
        }

        $connection = Get-JsonProperty -Object $entityPayload -Name "connection"
        if ($connection) {
            $artifactId = Get-FieldValue -Object $connection -Names @("artifactId")
            $workspaceId = Get-FieldValue -Object $connection -Names @("workspaceId")
            $eventGroupType = Get-FieldValue -Object $connection -Names @("eventGroupType")
            $itemName = if ($artifactId -and $ItemNameById.ContainsKey($artifactId)) { $ItemNameById[$artifactId] } else { $artifactId }
            $workspaceName = if ($workspaceId -and $WorkspaceNameById.ContainsKey($workspaceId)) { $WorkspaceNameById[$workspaceId] } else { $workspaceId }
            if ($itemName) {
                $parts = [pscustomobject]@{ source_database = $workspaceName; schema_name = ""; object_name = $itemName; source_type = "Fabric"; object_type = "item_reference" }
                Add-Candidate -Rows $Rows -Seen $Seen -Item $Item -ObjectParts $parts -DefinitionPath $Path -UsageType "reads_from" -ObjectType "item_reference" -SourceType "Fabric" -SourceServer $workspaceName -SourceDatabase $workspaceName -Evidence "Reflex listens for $eventGroupType events from Fabric item '$itemName' (workspace '$workspaceName') in '$Path'." -Confidence "confirmed"
            }
        }
    }
}

function Add-GraphQlApiObjectCandidates {
    # graphql-definition.json is exact and structured: each datasources[]
    # entry names its OWN backing Fabric item (sourceItemId/
    # sourceWorkspaceId/sourceType -- e.g. a Lakehouse's SQL analytics
    # endpoint) and lists every table it exposes (objects[].sourceObject),
    # so this is a direct field read, no heuristics needed at all.
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$Item,
        [string]$Path,
        [string]$Text
    )
    $payload = Convert-JsonContent -Content $Text
    $dataSources = Get-JsonProperty -Object $payload -Name "datasources"
    if (-not $dataSources) { return }
    foreach ($dataSource in @($dataSources)) {
        if (-not $dataSource) { continue }
        $sourceItemId = Get-FieldValue -Object $dataSource -Names @("sourceItemId")
        $sourceWorkspaceId = Get-FieldValue -Object $dataSource -Names @("sourceWorkspaceId")
        $sourceType = Get-FieldValue -Object $dataSource -Names @("sourceType")
        $sourceItemName = if ($sourceItemId -and $ItemNameById.ContainsKey($sourceItemId)) { $ItemNameById[$sourceItemId] } else { $sourceItemId }
        $sourceWorkspaceName = if ($sourceWorkspaceId -and $WorkspaceNameById.ContainsKey($sourceWorkspaceId)) { $WorkspaceNameById[$sourceWorkspaceId] } else { $sourceWorkspaceId }
        foreach ($object in @(Get-JsonProperty -Object $dataSource -Name "objects")) {
            if (-not $object) { continue }
            $sourceObject = Get-FieldValue -Object $object -Names @("sourceObject")
            if (-not $sourceObject -or (Test-ObjectIdentifierNoise -Value $sourceObject)) { continue }
            $objParts = Split-ObjectIdentifier -Identifier $sourceObject
            if (-not $objParts) { continue }
            $objParts.source_database = $sourceItemName
            Add-Candidate -Rows $Rows -Seen $Seen -Item $Item -ObjectParts $objParts -DefinitionPath $Path -UsageType "reads_from" -ObjectType "table_or_view" -SourceType "Fabric" -SourceServer $sourceWorkspaceName -SourceDatabase $sourceItemName -Evidence "GraphQL API exposes $sourceType table '$sourceObject' from '$sourceItemName' (workspace '$sourceWorkspaceName') in '$Path'." -Confidence "confirmed"
        }
    }
}

function Add-DataAgentTableCandidate {
    # Walks one node of the schema/table/column tree in a Data Agent's
    # Files/Config/draft/<source>/datasource.json. Depth in this tree IS
    # the schema/table/column hierarchy (type ends in ".schema"/".table"/
    # ".column"), so this only needs to track which schema name is the
    # current node's nearest ".schema" ancestor as it recurses.
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$Item,
        [string]$Path,
        [object]$Node,
        [string]$SchemaName,
        [string]$SourceDisplayName,
        [string]$WorkspaceName,
        [string]$SourceKind
    )
    $nodeType = Get-FieldValue -Object $Node -Names @("type")
    $nodeName = Get-FieldValue -Object $Node -Names @("display_name")
    if ($nodeType -match '\.table$') {
        if (-not (Test-ObjectIdentifierNoise -Value $nodeName)) {
            $parts = [pscustomobject]@{ source_database = $SourceDisplayName; schema_name = $SchemaName; object_name = $nodeName; source_type = "Fabric"; object_type = "table_or_view" }
            Add-Candidate -Rows $Rows -Seen $Seen -Item $Item -ObjectParts $parts -DefinitionPath $Path -UsageType "reads_from" -ObjectType "table_or_view" -SourceType "Fabric" -SourceServer $WorkspaceName -SourceDatabase $SourceDisplayName -Evidence "Data Agent is configured against $SourceKind table '$nodeName' in '$SourceDisplayName' (workspace '$WorkspaceName')." -Confidence "confirmed"
        }
        return
    }
    $children = Get-JsonProperty -Object $Node -Name "children"
    if (-not $children) { return }
    $nextSchema = if ($nodeType -match '\.schema$') { $nodeName } else { $SchemaName }
    foreach ($child in @($children)) {
        if (-not $child) { continue }
        Add-DataAgentTableCandidate -Rows $Rows -Seen $Seen -Item $Item -Path $Path -Node $child -SchemaName $nextSchema -SourceDisplayName $SourceDisplayName -WorkspaceName $WorkspaceName -SourceKind $SourceKind
    }
}

function Add-DataAgentObjectCandidates {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$Item,
        [string]$Path,
        [string]$Text
    )
    $payload = Convert-JsonContent -Content $Text
    if (-not $payload) { return }
    $displayName = Get-FieldValue -Object $payload -Names @("displayName")
    $workspaceId = Get-FieldValue -Object $payload -Names @("workspaceId")
    $sourceKind = Get-FieldValue -Object $payload -Names @("type")
    if (-not $displayName) { return }
    $workspaceName = if ($workspaceId -and $WorkspaceNameById.ContainsKey($workspaceId)) { $WorkspaceNameById[$workspaceId] } else { $workspaceId }
    foreach ($element in @(Get-JsonProperty -Object $payload -Name "elements")) {
        if (-not $element) { continue }
        Add-DataAgentTableCandidate -Rows $Rows -Seen $Seen -Item $Item -Path $Path -Node $element -SchemaName "" -SourceDisplayName $displayName -WorkspaceName $workspaceName -SourceKind $sourceKind
    }
}

function Extract-ObjectsFromDefinitionText {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$Item,
        [string]$Path,
        [string]$Text
    )
    if (-not $Text) { return }
    if ($Path -eq ".platform") { return }
    Add-StringPatternCandidates -Rows $Rows -Seen $Seen -Item $Item -Path $Path -Text $Text
    Add-EmbeddedSqlCandidates -Rows $Rows -Seen $Seen -Item $Item -Path $Path -Text $Text
    # UserDataFunction's function_app.py is real Python code -- the two
    # generic parsers above already cover it (they are plain text pattern
    # matches, not Notebook-specific), so it needs no dedicated function of
    # its own here, just its item_type added to -ItemTypes below.
    if ($Item.item_type -eq "Dataflow") {
        Add-MashupObjectCandidates -Rows $Rows -Seen $Seen -Item $Item -Path $Path -Text $Text
    }
    if ($Item.item_type -eq "Eventstream" -and $Path -eq "eventstream.json") {
        Add-EventstreamObjectCandidates -Rows $Rows -Seen $Seen -Item $Item -Path $Path -Text $Text
    }
    if ($Item.item_type -eq "KQLQueryset" -and $Path -eq "RealTimeQueryset.json") {
        Add-KqlQuerysetObjectCandidates -Rows $Rows -Seen $Seen -Item $Item -Path $Path -Text $Text
    }
    if ($Item.item_type -eq "Reflex" -and $Path -eq "ReflexEntities.json") {
        Add-ReflexObjectCandidates -Rows $Rows -Seen $Seen -Item $Item -Path $Path -Text $Text
    }
    if ($Item.item_type -eq "GraphQLApi" -and $Path -eq "graphql-definition.json") {
        Add-GraphQlApiObjectCandidates -Rows $Rows -Seen $Seen -Item $Item -Path $Path -Text $Text
    }
    if ($Item.item_type -eq "DataAgent" -and $Path -match "datasource\.json$") {
        Add-DataAgentObjectCandidates -Rows $Rows -Seen $Seen -Item $Item -Path $Path -Text $Text
    }

    foreach ($match in [regex]::Matches($Text, '(?is)"(?:tableName|dbTable|table|storedProcedureName|fileName|folderPath|query|sqlQuery|sourceQuery|sqlStatement)"\s*:\s*"((?:\\.|[^"])*)"')) {
        $keyName = [regex]::Match($match.Value, '"([^"]+)"').Groups[1].Value
        $value = $match.Groups[1].Value
        if ($keyName -match '(?i)query|sql') {
            Add-SqlObjectCandidates -Rows $Rows -Seen $Seen -Item $Item -Path $Path -SqlText $value -DefaultUsage "reads_from" -Evidence "Definition JSON query property parser"
            continue
        }
        $parts = Split-ObjectIdentifier -Identifier $value
        $objectType = if ($keyName -match '(?i)storedProcedure') { "stored_procedure" } elseif ($keyName -match '(?i)file|folder') { "file" } else { "table_or_view" }
        $usage = Get-ContextUsage -Text $Text -Index $match.Index -DefaultUsage "unknown"
        if ($objectType -eq "stored_procedure") { $usage = "executes" }
        Add-Candidate -Rows $Rows -Seen $Seen -Item $Item -ObjectParts $parts -DefinitionPath $Path -UsageType $usage -ObjectType $objectType -SourceType "" -SourceServer "" -SourceDatabase "" -Evidence "Definition property '$keyName' references object in '$Path'." -Confidence "likely"
    }
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

foreach ($path in @($WorkspaceIndexPath, $ItemsPath)) {
    if (-not (Test-Path $path)) { throw "Required input not found: $path" }
}

$workspaces = @(Import-Csv -Path $WorkspaceIndexPath)
$items = @(Import-Csv -Path $ItemsPath | Where-Object { $_.status -eq "discovered" -and $ItemTypes -contains $_.item_type })
if ($MaxItems -gt 0) { $items = @($items | Select-Object -First $MaxItems) }

$workspaceFilterSet = $null
if ($WorkspaceNameFilter) {
    $workspaceFilterSet = @{}
    foreach ($name in ($WorkspaceNameFilter -split "[;,]" | ForEach-Object { Normalize-Key $_ } | Where-Object { $_ })) {
        $workspaceFilterSet[$name] = $true
    }
}

$workspaceIdByName = @{}
foreach ($workspace in $workspaces) {
    $workspaceIdByName[$workspace.workspace_name] = $workspace.technical_id
}

# For Add-MashupObjectCandidates's Lakehouse.Contents() navigation, which
# only carries workspaceId/lakehouseId as raw Fabric GUIDs -- resolved to
# their friendly names so a Dataflow's Lakehouse drill-down reads like
# every other source type instead of showing GUIDs. $items above is
# already filtered to $ItemTypes (Notebook/CopyJob/Dataflow), so Lakehouse
# items need their own, separate, unfiltered read of the same file.
$WorkspaceNameById = @{}
foreach ($workspace in $workspaces) {
    if ($workspace.technical_id) { $WorkspaceNameById[$workspace.technical_id] = $workspace.workspace_name }
}
$LakehouseNameById = @{}
foreach ($lakehouseItem in @(Import-Csv -Path $ItemsPath | Where-Object { $_.item_type -eq "Lakehouse" -and $_.technical_id })) {
    $LakehouseNameById[$lakehouseItem.technical_id] = $lakehouseItem.item_name
}

# Reflex (action targets/event sources) and GraphQL API (its backing SQL
# analytics endpoint item) definitions reference OTHER Fabric items by ID
# only, of any type -- not just Lakehouses -- so this needs every item,
# not a type-filtered subset.
$ItemNameById = @{}
foreach ($anyItem in @(Import-Csv -Path $ItemsPath | Where-Object { $_.technical_id })) {
    $ItemNameById[$anyItem.technical_id] = $anyItem.item_name
}

$headers = New-FabricHeaders
$rows = [System.Collections.Generic.List[object]]::new()
$gaps = [System.Collections.Generic.List[object]]::new()
$seen = @{}
$processed = 0
$successCount = 0
$definitionPartCount = 0

if ($workspaceFilterSet) {
    if (Test-Path $OutputPath) {
        foreach ($row in @(Import-Csv -Path $OutputPath | Where-Object { -not $workspaceFilterSet.ContainsKey((Normalize-Key $_.workspace_name)) })) {
            $rows.Add($row) | Out-Null
        }
    }
    if (Test-Path $GapPath) {
        foreach ($row in @(Import-Csv -Path $GapPath | Where-Object { -not $workspaceFilterSet.ContainsKey((Normalize-Key $_.workspace_name)) })) {
            $gaps.Add($row) | Out-Null
        }
    }
    $items = @($items | Where-Object { $workspaceFilterSet.ContainsKey((Normalize-Key $_.workspace_name)) })
}

foreach ($item in $items) {
    $processed += 1
    if ($ProgressInterval -gt 0 -and ($processed % $ProgressInterval -eq 0)) {
        Write-Host "Processed $processed / $($items.Count) item definitions..."
    }

    $workspaceId = if ($workspaceIdByName.ContainsKey($item.workspace_name)) { $workspaceIdByName[$item.workspace_name] } else { "" }
    if (-not $workspaceId) {
        $gaps.Add([pscustomobject]@{ workspace_name = $item.workspace_name; item_type = $item.item_type; item_name = $item.item_name; item_qualified_name = $item.qualified_name; status_code = ""; definition_parts = 0; candidate_count = 0; error = "Workspace id missing."; notes = "" }) | Out-Null
        continue
    }
    $result = Get-ItemDefinition -WorkspaceId $workspaceId -ItemId $item.technical_id -ItemType $item.item_type -Headers $headers
    if (-not $result.succeeded -and [string]$result.status_code -eq "401" -and $result.error -match '(?i)TokenExpired|Access token has expired') {
        $headers = New-FabricHeaders
        $result = Get-ItemDefinition -WorkspaceId $workspaceId -ItemId $item.technical_id -ItemType $item.item_type -Headers $headers
    }
    if (-not $result.succeeded) {
        $gaps.Add([pscustomobject]@{ workspace_name = $item.workspace_name; item_type = $item.item_type; item_name = $item.item_name; item_qualified_name = $item.qualified_name; status_code = $result.status_code; definition_parts = 0; candidate_count = 0; error = $result.error; notes = "Definition unavailable." }) | Out-Null
        continue
    }
    $successCount += 1
    $beforeCount = $rows.Count
    $parts = @(Decode-DefinitionParts -DefinitionPayload $result.payload)
    $definitionPartCount += $parts.Count
    foreach ($part in $parts) {
        Extract-ObjectsFromDefinitionText -Rows $rows -Seen $seen -Item $item -Path $part.path -Text $part.text
    }
    $candidateCount = $rows.Count - $beforeCount
    if ($candidateCount -eq 0) {
        $gaps.Add([pscustomobject]@{ workspace_name = $item.workspace_name; item_type = $item.item_type; item_name = $item.item_name; item_qualified_name = $item.qualified_name; status_code = 200; definition_parts = $parts.Count; candidate_count = 0; error = ""; notes = "Definition decoded but no object-level table/view/stored-procedure/file candidates were parsed." }) | Out-Null
    }
}

Ensure-ParentDirectory -Path $OutputPath
$rows | Sort-Object item_type, workspace_name, item_name, source_database, schema_name, object_name | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Ensure-ParentDirectory -Path $GapPath
if ($gaps.Count -gt 0) {
    $gaps | Sort-Object item_type, workspace_name, item_name | Export-Csv -Path $GapPath -NoTypeInformation -Encoding UTF8
}
else {
    "workspace_name,item_type,item_name,item_qualified_name,status_code,definition_parts,candidate_count,error,notes" | Set-Content -Path $GapPath -Encoding UTF8
}

$notebookCandidates = @($rows | Where-Object { $_.item_type -eq "Notebook" }).Count
$copyJobCandidates = @($rows | Where-Object { $_.item_type -eq "CopyJob" }).Count
$itemsWithCandidates = @($rows | Select-Object -ExpandProperty item_qualified_name -Unique).Count

Set-UnresolvedEntry `
    -Title "Notebook and CopyJob object lineage extraction gaps" `
    -Status "open" `
    -Evidence "Processed $($items.Count) Notebook/CopyJob item definitions; $successCount definitions succeeded; $($gaps.Count) gaps/no-candidate rows. Parsed $($rows.Count) object candidates across $itemsWithCandidates items: $notebookCandidates notebook candidates and $copyJobCandidates CopyJob candidates." `
    -NextStep "Review analysis/item_object_lineage_candidates.csv and analysis/item_object_lineage_gaps.csv. Promote exact object types only with metadata or owner evidence."

Write-Host "Item object lineage extraction completed."
if ($workspaceFilterSet) {
    Write-Host "Workspace filter: $WorkspaceNameFilter (other workspaces retained unchanged from $OutputPath / $GapPath)"
}
Write-Host "Target items: $($items.Count)"
Write-Host "Definitions succeeded: $successCount"
Write-Host "Definition/gap rows: $($gaps.Count)"
Write-Host "Decoded parts: $definitionPartCount"
Write-Host "Object candidates: $($rows.Count)"
Write-Host "Items with candidates: $itemsWithCandidates"
Write-Host "Output: $OutputPath"
Write-Host "Gaps: $GapPath"
