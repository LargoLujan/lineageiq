# Phase 19 - Pipeline object lineage extraction: fetches each DataPipeline's
# getDefinition and walks its activity graph (Copy/Notebook/Dataflow/etc.
# activities), attributing each activity's source/destination objects to
# the pipeline, and inheriting object candidates from invoked
# items/dataflows already resolved by Phase 18 or notebook super-lineage.
# Writes: $OutputPath (object candidates), $ActivityOutputPath (per-activity
# detail), $GapPath (definitions unavailable).
param(
    [string]$WorkspaceIndexPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$ExistingItemObjectCandidatesPath = (Join-Path $PSScriptRoot "../../analysis/item_object_lineage_candidates.csv"),
    [string]$NotebookSuperLineageObjectsPath = (Join-Path $PSScriptRoot "../../analysis/notebook_super_lineage_objects.csv"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "../../analysis/pipeline_object_lineage_candidates.csv"),
    [string]$ActivityOutputPath = (Join-Path $PSScriptRoot "../../analysis/pipeline_activity_lineage.csv"),
    [string]$GapPath = (Join-Path $PSScriptRoot "../../analysis/pipeline_object_lineage_gaps.csv"),
    [string]$UnresolvedPath = (Join-Path $PSScriptRoot "../../index/unresolved.md"),
    [string]$AzCommand = "az",
    [string]$FabricApiBaseUrl = "https://api.fabric.microsoft.com/v1",
    [int]$MaxItems = 0,
    [int]$RetryCount = 5,
    [int]$RequestDelayMilliseconds = 250,
    [int]$MaxOperationPolls = 20,
    [int]$MaxOperationDelaySeconds = 15,
    [int]$ProgressInterval = 10,
    [string]$WorkspaceNameFilter = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

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

function Get-PropertyValue {
    param([object]$Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
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

function Get-ItemDefinition {
    param([string]$WorkspaceId, [string]$ItemId, [hashtable]$Headers)
    $response = Invoke-FabricWebRequest -Method Post -Path "workspaces/$WorkspaceId/items/$ItemId/getDefinition" -Headers $Headers
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

function Split-ObjectIdentifier {
    param([string]$Identifier)
    $clean = ConvertFrom-JsonStringLiteral -Value $Identifier
    $clean = ($clean -replace '[`\[\]"'']', '').Trim()
    $clean = $clean -replace '\\+', '/'
    $clean = $clean.Trim("/")
    if (-not $clean) { return $null }
    if ($clean -match '(?i)\bimport\b') { return $null }
    if ($clean -match '^(?i)(select|with|where|join|from|on|and|or|as|delta|overwrite|append|parquet|csv|json|text|true|false|none|null|default)$') { return $null }
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

function Get-NodeListByProperty {
    param([object]$Node, [string]$PropertyName)
    $results = [System.Collections.Generic.List[object]]::new()
    function Walk-Node {
        param([object]$Current, [string]$Name, [System.Collections.Generic.List[object]]$Rows)
        if ($null -eq $Current -or $Current -is [string]) { return }
        if ($Current -is [System.Collections.IEnumerable]) {
            foreach ($child in $Current) { Walk-Node -Current $child -Name $Name -Rows $Rows }
            return
        }
        foreach ($prop in @($Current.PSObject.Properties)) {
            if ([string]::Equals($prop.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $Rows.Add($prop.Value) | Out-Null
            }
            Walk-Node -Current $prop.Value -Name $Name -Rows $Rows
        }
    }
    Walk-Node -Current $Node -Name $PropertyName -Rows $results
    return @($results.ToArray())
}

function Get-StringValuesByProperty {
    param([object]$Node, [string[]]$PropertyNames)
    $results = [System.Collections.Generic.List[object]]::new()
    function Walk-Strings {
        param([object]$Current, [string[]]$Names, [System.Collections.Generic.List[object]]$Rows)
        if ($null -eq $Current -or $Current -is [string]) { return }
        if ($Current -is [System.Collections.IEnumerable]) {
            foreach ($child in $Current) { Walk-Strings -Current $child -Names $Names -Rows $Rows }
            return
        }
        foreach ($prop in @($Current.PSObject.Properties)) {
            if (($Names | ForEach-Object { $_.ToLowerInvariant() }) -contains $prop.Name.ToLowerInvariant()) {
                if ($prop.Value -is [string] -and $prop.Value) {
                    $Rows.Add([pscustomobject]@{ name = $prop.Name; value = [string]$prop.Value }) | Out-Null
                }
            }
            Walk-Strings -Current $prop.Value -Names $Names -Rows $Rows
        }
    }
    Walk-Strings -Current $Node -Names $PropertyNames -Rows $results
    return @($results.ToArray())
}

function Add-CandidateRow {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$PipelineItem,
        [string]$SourceType,
        [string]$SourceName,
        [string]$SourceQualifiedName,
        [string]$SourceServer,
        [string]$SourceDatabase,
        [string]$SchemaName,
        [string]$ObjectName,
        [string]$ObjectType,
        [string]$UsageType,
        [string]$Confidence,
        [string]$DefinitionPath,
        [string]$Evidence,
        [string]$ActivityName,
        [string]$ActivityType,
        [string]$InvokedItemQualifiedName
    )
    if (-not $ObjectName) { return }
    $cleanObjectName = $ObjectName.Trim()
    if ($cleanObjectName -match '^,$') { return }
    if ($cleanObjectName -match '^\{[^}]+\}$') { return }
    if ($cleanObjectName -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return }
    if ($cleanObjectName -match '^(?i)(status)$') { return }
    $key = @(
        $PipelineItem.qualified_name,
        $SourceType,
        $SourceQualifiedName,
        $SourceServer,
        $SourceDatabase,
        $SchemaName,
        $cleanObjectName,
        $ObjectType,
        $UsageType,
        $ActivityName,
        $InvokedItemQualifiedName
    ) | ForEach-Object { Normalize-Key $_ }
    $key = $key -join "|"
    if ($Seen.ContainsKey($key)) { return }
    $Seen[$key] = $true

    $Rows.Add([pscustomobject]@{
        workspace_name = $PipelineItem.workspace_name
        workspace_environment = $PipelineItem.workspace_environment
        item_type = $PipelineItem.item_type
        item_name = $PipelineItem.item_name
        item_qualified_name = $PipelineItem.qualified_name
        source_type = if ($SourceType) { $SourceType } else { "FabricOrSQL" }
        source_name = if ($SourceName) { $SourceName } elseif ($SourceDatabase) { $SourceDatabase } else { $SourceType }
        source_qualified_name = $SourceQualifiedName
        source_server = $SourceServer
        source_database = $SourceDatabase
        schema_name = $SchemaName
        object_name = $cleanObjectName
        object_type = if ($ObjectType) { $ObjectType } else { "table_or_view" }
        usage_type = if ($UsageType) { $UsageType } else { "unknown" }
        confidence = if ($Confidence) { $Confidence } else { "likely" }
        definition_path = $DefinitionPath
        evidence = Limit-Text -Text $Evidence -MaxLength 1200
        activity_name = $ActivityName
        activity_type = $ActivityType
        invoked_item_qualified_name = $InvokedItemQualifiedName
    }) | Out-Null
}

function Resolve-LinkedService {
    param([object]$DatasetSettings)
    $linkedService = Get-PropertyValue -Object $DatasetSettings -Name "linkedService"
    $lsName = Get-FieldValue -Object $linkedService -Names @("name")
    $lsProps = Get-PropertyValue -Object $linkedService -Name "properties"
    $lsType = Get-FieldValue -Object $lsProps -Names @("type")
    $lsTypeProps = Get-PropertyValue -Object $lsProps -Name "typeProperties"
    $workspaceId = Get-FieldValue -Object $lsTypeProps -Names @("workspaceId")
    $artifactId = Get-FieldValue -Object $lsTypeProps -Names @("artifactId")
    $server = Get-FieldValue -Object $lsTypeProps -Names @("server", "serverName", "host")
    $database = Get-FieldValue -Object $lsTypeProps -Names @("database", "databaseName")

    $mappedItem = $null
    $mapKey = Normalize-Key "$workspaceId|$artifactId"
    if ($mapKey -and $script:ItemByWorkspaceAndId.ContainsKey($mapKey)) {
        $mappedItem = $script:ItemByWorkspaceAndId[$mapKey]
    }

    if ($mappedItem) {
        return [pscustomobject]@{
            source_type = $mappedItem.item_type
            source_name = $mappedItem.item_name
            source_qualified_name = $mappedItem.qualified_name
            source_server = $mappedItem.workspace_name
            source_database = $mappedItem.item_name
        }
    }

    $sourceType = if ($lsType -match '(?i)Lakehouse|Warehouse|DataWarehouse') { "Fabric" } elseif ($lsType -match '(?i)Sql|SQL|ODBC|Odbc|AzureSql') { "SQL" } elseif ($lsType -match '(?i)S3|Amazon|File|Parquet|Delimited|Blob|ADLS') { "File" } elseif ($lsType) { $lsType } else { "FabricOrSQL" }
    return [pscustomobject]@{
        source_type = $sourceType
        source_name = if ($lsName) { $lsName } else { $database }
        source_qualified_name = ""
        source_server = $server
        source_database = if ($database) { $database } else { $lsName }
    }
}

function Add-SqlCandidates {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$PipelineItem,
        [string]$SqlText,
        [string]$DefinitionPath,
        [string]$EvidencePrefix,
        [string]$ActivityName,
        [string]$ActivityType
    )
    if (-not $SqlText) { return }
    $sql = ConvertFrom-JsonStringLiteral -Value $SqlText
    $matches = [regex]::Matches($sql, '(?is)\b(from|join|into|update|merge\s+into|delete\s+from|exec(?:ute)?|call)\s+((?:\[[^\]]+\]|"[^"]+"|`[^`]+`|[A-Za-z_][A-Za-z0-9_$#-]*)(?:\s*\.\s*(?:\[[^\]]+\]|"[^"]+"|`[^`]+`|[A-Za-z_][A-Za-z0-9_$#-]*)){0,2})')
    foreach ($match in $matches) {
        $verb = ($match.Groups[1].Value -replace '\s+', ' ').ToLowerInvariant()
        $identifier = $match.Groups[2].Value.Trim()
        $parts = Split-ObjectIdentifier -Identifier $identifier
        if (-not $parts) { continue }
        $usage = "reads_from"
        $objectType = "native_query_object"
        if ($verb -match 'into|update|merge|delete') { $usage = "writes_to" }
        elseif ($verb -match 'exec|call') { $usage = "executes"; $objectType = "stored_procedure" }
        Add-CandidateRow -Rows $Rows -Seen $Seen -PipelineItem $PipelineItem -SourceType "SQL" -SourceName "" -SourceQualifiedName "" -SourceServer "" -SourceDatabase $parts.source_database -SchemaName $parts.schema_name -ObjectName $parts.object_name -ObjectType $objectType -UsageType $usage -Confidence "likely" -DefinitionPath $DefinitionPath -Evidence "$EvidencePrefix SQL keyword '$verb' references object." -ActivityName $ActivityName -ActivityType $ActivityType -InvokedItemQualifiedName ""
    }
}

function Add-DatasetCandidates {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$PipelineItem,
        [object]$DatasetSettings,
        [string]$UsageType,
        [string]$DefinitionPath,
        [string]$ActivityName,
        [string]$ActivityType
    )
    if (-not $DatasetSettings) { return }
    $source = Resolve-LinkedService -DatasetSettings $DatasetSettings
    $typeProps = Get-PropertyValue -Object $DatasetSettings -Name "typeProperties"
    $tableValue = Get-FieldValue -Object $typeProps -Names @("table", "tableName", "dbTable")
    if ($tableValue) {
        $parts = Split-ObjectIdentifier -Identifier $tableValue
        if ($parts) {
            $schema = if ($parts.schema_name) { $parts.schema_name } else { Get-FieldValue -Object $typeProps -Names @("schemaName") }
            $sourceDatabase = if ($source.source_database) { $source.source_database } else { $parts.source_database }
            Add-CandidateRow -Rows $Rows -Seen $Seen -PipelineItem $PipelineItem -SourceType $source.source_type -SourceName $source.source_name -SourceQualifiedName $source.source_qualified_name -SourceServer $source.source_server -SourceDatabase $sourceDatabase -SchemaName $schema -ObjectName $parts.object_name -ObjectType "table_or_view" -UsageType $UsageType -Confidence "confirmed" -DefinitionPath $DefinitionPath -Evidence "Pipeline activity '$ActivityName' ($ActivityType) $UsageType dataset table '$tableValue'." -ActivityName $ActivityName -ActivityType $ActivityType -InvokedItemQualifiedName ""
        }
    }

    $location = Get-PropertyValue -Object $typeProps -Name "location"
    if ($location) {
        $folder = Get-FieldValue -Object $location -Names @("folderPath", "path")
        $file = Get-FieldValue -Object $location -Names @("fileName")
        $bucket = Get-FieldValue -Object $location -Names @("bucketName", "container")
        if ($folder -or $file) {
            $objectName = (@($folder, $file) | Where-Object { $_ }) -join "/"
            Add-CandidateRow -Rows $Rows -Seen $Seen -PipelineItem $PipelineItem -SourceType "File" -SourceName $bucket -SourceQualifiedName "" -SourceServer "" -SourceDatabase $bucket -SchemaName "" -ObjectName $objectName -ObjectType "file" -UsageType $UsageType -Confidence "confirmed" -DefinitionPath $DefinitionPath -Evidence "Pipeline activity '$ActivityName' ($ActivityType) $UsageType file location '$objectName'." -ActivityName $ActivityName -ActivityType $ActivityType -InvokedItemQualifiedName ""
        }
    }
}

function Add-DirectActivityCandidates {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$PipelineItem,
        [object]$Activity,
        [string]$DefinitionPath
    )
    $activityName = Get-FieldValue -Object $Activity -Names @("name")
    $activityType = Get-FieldValue -Object $Activity -Names @("type")
    $typeProps = Get-PropertyValue -Object $Activity -Name "typeProperties"
    foreach ($sideName in @("source", "sink")) {
        $side = Get-PropertyValue -Object $typeProps -Name $sideName
        if (-not $side) { continue }
        $usage = if ($sideName -eq "source") { "reads_from" } else { "writes_to" }
        foreach ($datasetSettings in Get-NodeListByProperty -Node $side -PropertyName "datasetSettings") {
            Add-DatasetCandidates -Rows $Rows -Seen $Seen -PipelineItem $PipelineItem -DatasetSettings $datasetSettings -UsageType $usage -DefinitionPath $DefinitionPath -ActivityName $activityName -ActivityType $activityType
        }
        foreach ($query in Get-StringValuesByProperty -Node $side -PropertyNames @("query", "sqlQuery", "sqlReaderQuery", "sourceQuery")) {
            Add-SqlCandidates -Rows $Rows -Seen $Seen -PipelineItem $PipelineItem -SqlText $query.value -DefinitionPath $DefinitionPath -EvidencePrefix "Pipeline activity '$activityName' ($activityType) $usage query property '$($query.name)'." -ActivityName $activityName -ActivityType $activityType
        }
        foreach ($proc in Get-StringValuesByProperty -Node $side -PropertyNames @("storedProcedureName", "sqlWriterStoredProcedureName")) {
            $parts = Split-ObjectIdentifier -Identifier $proc.value
            if ($parts) {
                Add-CandidateRow -Rows $Rows -Seen $Seen -PipelineItem $PipelineItem -SourceType "SQL" -SourceName "" -SourceQualifiedName "" -SourceServer "" -SourceDatabase $parts.source_database -SchemaName $parts.schema_name -ObjectName $parts.object_name -ObjectType "stored_procedure" -UsageType "executes" -Confidence "confirmed" -DefinitionPath $DefinitionPath -Evidence "Pipeline activity '$activityName' ($activityType) stored procedure property '$($proc.name)'." -ActivityName $activityName -ActivityType $activityType -InvokedItemQualifiedName ""
            }
        }
    }
}

function Get-InvokedItem {
    param([object]$Activity)
    $activityType = Get-FieldValue -Object $Activity -Names @("type")
    $typeProps = Get-PropertyValue -Object $Activity -Name "typeProperties"
    $workspaceId = Get-FieldValue -Object $typeProps -Names @("workspaceId")
    $targetId = ""
    if ($activityType -eq "TridentNotebook") { $targetId = Get-FieldValue -Object $typeProps -Names @("notebookId") }
    elseif ($activityType -eq "InvokeCopyJob") { $targetId = Get-FieldValue -Object $typeProps -Names @("copyJobId") }
    elseif ($activityType -eq "InvokePipeline") { $targetId = Get-FieldValue -Object $typeProps -Names @("pipelineId") }
    if (-not $targetId) { return $null }
    $key = Normalize-Key "$workspaceId|$targetId"
    if ($key -and $script:ItemByWorkspaceAndId.ContainsKey($key)) { return $script:ItemByWorkspaceAndId[$key] }
    return $null
}

function Get-ActivityParameters {
    param([object]$Activity)
    $typeProps = Get-PropertyValue -Object $Activity -Name "typeProperties"
    if ($null -eq $typeProps) { return "" }
    # TridentNotebook activities use "parameters"; InvokePipeline uses "baseParameters".
    # Both are { name: { value, type } } - keep only the value, the Fabric-internal
    # "type" tag (string/bool/...) is not useful to a human reading the lineage.
    $paramsObject = Get-PropertyValue -Object $typeProps -Name "parameters"
    if ($null -eq $paramsObject) { $paramsObject = Get-PropertyValue -Object $typeProps -Name "baseParameters" }
    if ($null -eq $paramsObject) { return "" }

    $flat = [ordered]@{}
    foreach ($property in $paramsObject.PSObject.Properties) {
        $entry = $property.Value
        $value = Get-PropertyValue -Object $entry -Name "value"
        if ($null -eq $value -and $entry -isnot [System.Management.Automation.PSCustomObject]) { $value = $entry }
        $flat[$property.Name] = [string]$value
    }
    if ($flat.Count -eq 0) { return "" }
    return ($flat | ConvertTo-Json -Compress -Depth 5)
}

function Copy-InheritedRow {
    param(
        [System.Collections.Generic.List[object]]$Rows,
        [hashtable]$Seen,
        [object]$PipelineItem,
        [object]$SourceRow,
        [object]$Invocation
    )
    Add-CandidateRow -Rows $Rows -Seen $Seen -PipelineItem $PipelineItem `
        -SourceType (Get-FieldValue -Object $SourceRow -Names @("source_type")) `
        -SourceName (Get-FieldValue -Object $SourceRow -Names @("source_name")) `
        -SourceQualifiedName (Get-FieldValue -Object $SourceRow -Names @("source_qualified_name")) `
        -SourceServer (Get-FieldValue -Object $SourceRow -Names @("source_server")) `
        -SourceDatabase (Get-FieldValue -Object $SourceRow -Names @("source_database")) `
        -SchemaName (Get-FieldValue -Object $SourceRow -Names @("schema_name")) `
        -ObjectName (Get-FieldValue -Object $SourceRow -Names @("object_name")) `
        -ObjectType (Get-FieldValue -Object $SourceRow -Names @("object_type")) `
        -UsageType (Get-FieldValue -Object $SourceRow -Names @("usage_type")) `
        -Confidence "likely" `
        -DefinitionPath "pipeline-content.json > $(Get-FieldValue -Object $SourceRow -Names @("definition_path"))" `
        -Evidence "Pipeline activity '$($Invocation.activity_name)' ($($Invocation.activity_type)) invokes '$($Invocation.invoked_item_qualified_name)'; inherited object evidence. $(Get-FieldValue -Object $SourceRow -Names @("evidence"))" `
        -ActivityName $Invocation.activity_name `
        -ActivityType $Invocation.activity_type `
        -InvokedItemQualifiedName $Invocation.invoked_item_qualified_name
}

function Convert-NotebookSuperLineageRow {
    param([object]$Row)
    $direction = (Get-FieldValue -Object $Row -Names @("direction")).ToLowerInvariant()
    $operation = (Get-FieldValue -Object $Row -Names @("operation")).ToLowerInvariant()
    $usageType = "unknown"
    if ($direction -eq "read") { $usageType = "reads_from" }
    elseif ($direction -eq "write") { $usageType = "writes_to" }
    elseif ($direction -eq "execute" -or $operation -match "exec|call|procedure") { $usageType = "executes" }

    $confidence = Get-FieldValue -Object $Row -Names @("confidence")
    if ($confidence -eq "parsed") { $confidence = "confirmed" }
    elseif (-not $confidence) { $confidence = "likely" }

    $objectName = Get-FieldValue -Object $Row -Names @("object_name")
    $objectType = "table_or_view"
    if ($usageType -eq "executes" -or $operation -match "stored|procedure|exec|call") { $objectType = "stored_procedure" }
    elseif ($objectName -match "^(?i)(abfss|https?|wasbs|s3)://|^(?i)(Files|Tables|Lakehouse|Warehouse)/") { $objectType = "file" }

    $evidence = Get-FieldValue -Object $Row -Names @("evidence")
    $unresolved = Get-FieldValue -Object $Row -Names @("unresolved_variables")
    if ($unresolved) { $evidence = "$evidence Unresolved variables: $unresolved" }

    return [pscustomobject]@{
        workspace_name = Get-FieldValue -Object $Row -Names @("workspace_name")
        workspace_environment = Get-FieldValue -Object $Row -Names @("workspace_environment")
        item_type = "Notebook"
        item_name = Get-FieldValue -Object $Row -Names @("notebook_name")
        item_qualified_name = Get-FieldValue -Object $Row -Names @("item_qualified_name")
        source_type = Get-FieldValue -Object $Row -Names @("source_type")
        source_name = Get-FieldValue -Object $Row -Names @("source_database", "source_type")
        source_qualified_name = ""
        source_server = ""
        source_database = Get-FieldValue -Object $Row -Names @("source_database")
        schema_name = Get-FieldValue -Object $Row -Names @("schema_name")
        object_name = $objectName
        object_type = $objectType
        usage_type = $usageType
        confidence = $confidence
        definition_path = Get-FieldValue -Object $Row -Names @("definition_path")
        evidence = "Notebook super-lineage. $evidence"
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
$items = @(Import-Csv -Path $ItemsPath | Where-Object { $_.status -eq "discovered" })
$pipelineItems = @($items | Where-Object { $_.item_type -eq "DataPipeline" })
if ($MaxItems -gt 0) { $pipelineItems = @($pipelineItems | Select-Object -First $MaxItems) }

$workspaceFilterSet = $null
if ($WorkspaceNameFilter) {
    $workspaceFilterSet = @{}
    foreach ($name in ($WorkspaceNameFilter -split "[;,]" | ForEach-Object { Normalize-Key $_ } | Where-Object { $_ })) {
        $workspaceFilterSet[$name] = $true
    }
    $pipelineItems = @($pipelineItems | Where-Object { $workspaceFilterSet.ContainsKey((Normalize-Key $_.workspace_name)) })
}
$existingRows = if (Test-Path $ExistingItemObjectCandidatesPath) { @(Import-Csv -Path $ExistingItemObjectCandidatesPath | Where-Object { $_.item_qualified_name -and $_.object_name }) } else { @() }
$notebookSuperRows = if (Test-Path $NotebookSuperLineageObjectsPath) { @(Import-Csv -Path $NotebookSuperLineageObjectsPath | Where-Object { $_.item_qualified_name -and $_.object_name } | ForEach-Object { Convert-NotebookSuperLineageRow -Row $_ }) } else { @() }
$existingRows = @($existingRows + $notebookSuperRows)

$workspaceIdByName = @{}
foreach ($workspace in $workspaces) {
    $workspaceIdByName[$workspace.workspace_name] = $workspace.technical_id
}

$script:ItemByWorkspaceAndId = @{}
foreach ($item in $items) {
    $workspaceId = if ($workspaceIdByName.ContainsKey($item.workspace_name)) { $workspaceIdByName[$item.workspace_name] } else { "" }
    $key = Normalize-Key "$workspaceId|$($item.technical_id)"
    if ($key) { $script:ItemByWorkspaceAndId[$key] = $item }
}

$existingObjectsByItem = @{}
foreach ($row in $existingRows) {
    $itemName = Get-FieldValue -Object $row -Names @("item_qualified_name")
    if (-not $existingObjectsByItem.ContainsKey($itemName)) {
        $existingObjectsByItem[$itemName] = [System.Collections.Generic.List[object]]::new()
    }
    $existingObjectsByItem[$itemName].Add($row) | Out-Null
}

$headers = New-FabricHeaders
$directRowsByPipeline = @{}
$pipelineInvocationsByItem = @{}
$activityRows = [System.Collections.Generic.List[object]]::new()
$gaps = [System.Collections.Generic.List[object]]::new()

if ($workspaceFilterSet) {
    if (Test-Path $ActivityOutputPath) {
        foreach ($row in @(Import-Csv -Path $ActivityOutputPath | Where-Object { -not $workspaceFilterSet.ContainsKey((Normalize-Key $_.workspace_name)) })) {
            $activityRows.Add($row) | Out-Null
        }
    }
    if (Test-Path $GapPath) {
        foreach ($row in @(Import-Csv -Path $GapPath | Where-Object { -not $workspaceFilterSet.ContainsKey((Normalize-Key $_.workspace_name)) })) {
            $gaps.Add($row) | Out-Null
        }
    }
}

$processed = 0
$successCount = 0
$definitionPartCount = 0
$directCandidateCount = 0

foreach ($pipeline in $pipelineItems) {
    $processed += 1
    if ($ProgressInterval -gt 0 -and ($processed % $ProgressInterval -eq 0)) {
        Write-Host "Processed $processed / $($pipelineItems.Count) pipeline definitions..."
    }
    $workspaceId = if ($workspaceIdByName.ContainsKey($pipeline.workspace_name)) { $workspaceIdByName[$pipeline.workspace_name] } else { "" }
    if (-not $workspaceId) {
        $gaps.Add([pscustomobject]@{ workspace_name = $pipeline.workspace_name; item_type = $pipeline.item_type; item_name = $pipeline.item_name; item_qualified_name = $pipeline.qualified_name; status_code = ""; definition_parts = 0; activity_count = 0; candidate_count = 0; error = "Workspace id missing."; notes = "" }) | Out-Null
        continue
    }
    $result = Get-ItemDefinition -WorkspaceId $workspaceId -ItemId $pipeline.technical_id -Headers $headers
    if (-not $result.succeeded -and [string]$result.status_code -eq "401" -and $result.error -match '(?i)TokenExpired|Access token has expired') {
        $headers = New-FabricHeaders
        $result = Get-ItemDefinition -WorkspaceId $workspaceId -ItemId $pipeline.technical_id -Headers $headers
    }
    if (-not $result.succeeded) {
        $gaps.Add([pscustomobject]@{ workspace_name = $pipeline.workspace_name; item_type = $pipeline.item_type; item_name = $pipeline.item_name; item_qualified_name = $pipeline.qualified_name; status_code = $result.status_code; definition_parts = 0; activity_count = 0; candidate_count = 0; error = $result.error; notes = "Definition unavailable." }) | Out-Null
        continue
    }

    $successCount += 1
    $parts = @(Decode-DefinitionParts -DefinitionPayload $result.payload)
    $definitionPartCount += $parts.Count
    $pipelineRows = [System.Collections.Generic.List[object]]::new()
    $seenDirect = @{}
    $activityCount = 0
    $candidateBefore = $pipelineRows.Count

    foreach ($part in $parts) {
        if ($part.path -ne "pipeline-content.json" -or -not $part.text) { continue }
        $payload = Convert-JsonContent -Content $part.text
        if (-not $payload) { continue }
        $activities = @()
        if ($payload.PSObject.Properties.Name -contains "properties" -and $payload.properties.PSObject.Properties.Name -contains "activities") {
            $activities = @($payload.properties.activities)
        }
        foreach ($activity in $activities) {
            $activityCount += 1
            $activityName = Get-FieldValue -Object $activity -Names @("name")
            $activityType = Get-FieldValue -Object $activity -Names @("type")
            $invokedItem = Get-InvokedItem -Activity $activity
            $activityParameters = Get-ActivityParameters -Activity $activity
            if ($invokedItem) {
                if (-not $pipelineInvocationsByItem.ContainsKey($pipeline.qualified_name)) {
                    $pipelineInvocationsByItem[$pipeline.qualified_name] = [System.Collections.Generic.List[object]]::new()
                }
                $pipelineInvocationsByItem[$pipeline.qualified_name].Add([pscustomobject]@{
                    activity_name = $activityName
                    activity_type = $activityType
                    invoked_item_qualified_name = $invokedItem.qualified_name
                    invoked_item_type = $invokedItem.item_type
                }) | Out-Null
            }

            $dependsOnRows = @(Get-PropertyValue -Object $activity -Name "dependsOn")
            if ($dependsOnRows.Count -eq 0) { $dependsOnRows = @($null) }
            foreach ($dependency in $dependsOnRows) {
                $dependsActivity = if ($dependency) { Get-FieldValue -Object $dependency -Names @("activity") } else { "" }
                $conditions = ""
                if ($dependency -and ($dependency.PSObject.Properties.Name -contains "dependencyConditions")) {
                    $conditions = @($dependency.dependencyConditions) -join ";"
                }
                $activityRows.Add([pscustomobject]@{
                    workspace_name = $pipeline.workspace_name
                    workspace_environment = $pipeline.workspace_environment
                    pipeline_name = $pipeline.item_name
                    pipeline_qualified_name = $pipeline.qualified_name
                    activity_name = $activityName
                    activity_type = $activityType
                    depends_on_activity = $dependsActivity
                    dependency_conditions = $conditions
                    invoked_item_qualified_name = if ($invokedItem) { $invokedItem.qualified_name } else { "" }
                    invoked_item_type = if ($invokedItem) { $invokedItem.item_type } else { "" }
                    parameters = $activityParameters
                }) | Out-Null
            }

            Add-DirectActivityCandidates -Rows $pipelineRows -Seen $seenDirect -PipelineItem $pipeline -Activity $activity -DefinitionPath $part.path
        }
    }

    $directRowsByPipeline[$pipeline.qualified_name] = $pipelineRows
    $directCount = $pipelineRows.Count - $candidateBefore
    $directCandidateCount += $directCount
    if ($activityCount -eq 0 -or ($directCount -eq 0 -and -not $pipelineInvocationsByItem.ContainsKey($pipeline.qualified_name))) {
        $gaps.Add([pscustomobject]@{ workspace_name = $pipeline.workspace_name; item_type = $pipeline.item_type; item_name = $pipeline.item_name; item_qualified_name = $pipeline.qualified_name; status_code = 200; definition_parts = $parts.Count; activity_count = $activityCount; candidate_count = $directCount; error = ""; notes = "Pipeline definition decoded but no direct object candidates or supported invoked items were parsed." }) | Out-Null
    }
}

$outputRows = [System.Collections.Generic.List[object]]::new()
$seenOutput = @{}

if ($workspaceFilterSet -and (Test-Path $OutputPath)) {
    foreach ($row in @(Import-Csv -Path $OutputPath | Where-Object { -not $workspaceFilterSet.ContainsKey((Normalize-Key $_.workspace_name)) })) {
        $outputRows.Add($row) | Out-Null
    }
}

foreach ($pipeline in $pipelineItems) {
    if ($directRowsByPipeline.ContainsKey($pipeline.qualified_name)) {
        foreach ($row in @($directRowsByPipeline[$pipeline.qualified_name].ToArray())) {
            Copy-InheritedRow -Rows $outputRows -Seen $seenOutput -PipelineItem $pipeline -SourceRow $row -Invocation ([pscustomobject]@{ activity_name = Get-FieldValue -Object $row -Names @("activity_name"); activity_type = Get-FieldValue -Object $row -Names @("activity_type"); invoked_item_qualified_name = "" })
        }
    }
}

for ($pass = 1; $pass -le 8; $pass++) {
    $rowsByItem = @{}
    foreach ($row in @($outputRows.ToArray())) {
        $itemName = Get-FieldValue -Object $row -Names @("item_qualified_name")
        if (-not $itemName) { continue }
        if (-not $rowsByItem.ContainsKey($itemName)) {
            $rowsByItem[$itemName] = [System.Collections.Generic.List[object]]::new()
        }
        $rowsByItem[$itemName].Add($row) | Out-Null
    }

    $beforeCount = $outputRows.Count
    foreach ($pipeline in $pipelineItems) {
        if (-not $pipelineInvocationsByItem.ContainsKey($pipeline.qualified_name)) { continue }
        foreach ($invocation in @($pipelineInvocationsByItem[$pipeline.qualified_name].ToArray())) {
            $target = $invocation.invoked_item_qualified_name
            if ($existingObjectsByItem.ContainsKey($target)) {
                foreach ($row in @($existingObjectsByItem[$target].ToArray())) {
                    Copy-InheritedRow -Rows $outputRows -Seen $seenOutput -PipelineItem $pipeline -SourceRow $row -Invocation $invocation
                }
            }
            if ($rowsByItem.ContainsKey($target)) {
                foreach ($row in @($rowsByItem[$target].ToArray())) {
                    Copy-InheritedRow -Rows $outputRows -Seen $seenOutput -PipelineItem $pipeline -SourceRow $row -Invocation $invocation
                }
            }
        }
    }
    if ($outputRows.Count -eq $beforeCount) { break }
}

Ensure-ParentDirectory -Path $OutputPath
$outputRows | Sort-Object workspace_name, item_name, activity_name, source_database, schema_name, object_name | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Ensure-ParentDirectory -Path $ActivityOutputPath
$activityColumns = @(
    "workspace_name", "workspace_environment", "pipeline_name", "pipeline_qualified_name",
    "activity_name", "activity_type", "depends_on_activity", "dependency_conditions",
    "invoked_item_qualified_name", "invoked_item_type", "parameters"
)
$activityRows |
    Select-Object -Property $activityColumns |
    Sort-Object workspace_name, pipeline_name, activity_name, depends_on_activity |
    Export-Csv -Path $ActivityOutputPath -NoTypeInformation -Encoding UTF8

Ensure-ParentDirectory -Path $GapPath
if ($gaps.Count -gt 0) {
    $gaps | Sort-Object workspace_name, item_name | Export-Csv -Path $GapPath -NoTypeInformation -Encoding UTF8
}
else {
    "workspace_name,item_type,item_name,item_qualified_name,status_code,definition_parts,activity_count,candidate_count,error,notes" | Set-Content -Path $GapPath -Encoding UTF8
}

$itemsWithCandidates = @($outputRows | Select-Object -ExpandProperty item_qualified_name -Unique).Count
$invocationCount = 0
foreach ($key in $pipelineInvocationsByItem.Keys) { $invocationCount += $pipelineInvocationsByItem[$key].Count }

Set-UnresolvedEntry `
    -Title "DataPipeline activity object lineage gaps" `
    -Status "open" `
    -Evidence "Processed $($pipelineItems.Count) DataPipeline definitions; $successCount definitions succeeded; parsed $($activityRows.Count) activity rows, $invocationCount supported item invocations, $directCandidateCount direct object candidates, and $($outputRows.Count) direct/inherited object candidates across $itemsWithCandidates pipelines. Gap/no-candidate rows: $($gaps.Count)." `
    -NextStep "Review analysis/pipeline_object_lineage_candidates.csv, analysis/pipeline_activity_lineage.csv, and analysis/pipeline_object_lineage_gaps.csv. Promote exact object types only after metadata or owner evidence."

Write-Host "Pipeline object lineage extraction completed."
if ($workspaceFilterSet) {
    Write-Host "Workspace filter: $WorkspaceNameFilter (other workspaces retained unchanged from $OutputPath / $ActivityOutputPath / $GapPath)"
}
Write-Host "Target pipelines: $($pipelineItems.Count)"
Write-Host "Definitions succeeded: $successCount"
Write-Host "Definition/gap rows: $($gaps.Count)"
Write-Host "Decoded parts: $definitionPartCount"
Write-Host "Activity rows: $($activityRows.Count)"
Write-Host "Supported item invocations: $invocationCount"
Write-Host "Direct object candidates: $directCandidateCount"
Write-Host "Direct/inherited object candidates: $($outputRows.Count)"
Write-Host "Pipelines with candidates: $itemsWithCandidates"
Write-Host "Output: $OutputPath"
Write-Host "Activities: $ActivityOutputPath"
Write-Host "Gaps: $GapPath"
