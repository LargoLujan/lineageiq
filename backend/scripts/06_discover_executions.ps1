# Phase 6 - Execution discovery: queries Fabric job-instance history and
# Power BI refresh schedules for the item types in $ExecutionItemTypes
# (pipelines, notebooks, semantic models, etc.), and derives per-item
# duration/timing summaries and gaps where scheduling info couldn't be
# resolved. Read-only.
# Reads: $ItemsPath. Writes: $OutputPath, $ExecutionSummaryPath,
# $DurationByItemPath, $QueryGapsPath.
param(
    [string]$WorkspaceIndexPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "../../index/executions.csv"),
    [string]$ExecutionSummaryPath = (Join-Path $PSScriptRoot "../../analysis/execution_timing_summary.csv"),
    [string]$DurationByItemPath = (Join-Path $PSScriptRoot "../../analysis/execution_duration_by_item.csv"),
    [string]$QueryGapsPath = (Join-Path $PSScriptRoot "../../analysis/execution_query_gaps.csv"),
    [string]$UnresolvedPath = (Join-Path $PSScriptRoot "../../index/unresolved.md"),
    [string]$AzCommand = "az",
    [string]$FabricApiBaseUrl = "https://api.fabric.microsoft.com/v1",
    [string]$PowerBiApiBaseUrl = "https://api.powerbi.com/v1.0/myorg",
    [string[]]$ExecutionItemTypes = @(
        "DataPipeline",
        "Notebook",
        "SemanticModel",
        "CopyJob",
        "Dataflow",
        "Eventstream",
        "Reflex",
        "KQLQueryset",
        "KQLDashboard",
        "UserDataFunction"
    ),
    [int]$RetryCount = 5,
    [int]$RequestDelayMilliseconds = 1300,
    [int]$MaxItems = 0,
    [int]$PowerBiRefreshHistoryTop = 60,
    [int]$ProgressInterval = 25,
    [bool]$ProbeCandidateSchedules = $true,
    [bool]$UsePowerBiForSemanticModels = $true,
    [switch]$IncludeAllItems,
    [switch]$SkipJobInstances,
    [switch]$SkipSchedules,
    [string]$WorkspaceNameFilter = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$executionColumns = @(
    "record_type",
    "workspace_name",
    "item_name",
    "item_type",
    "qualified_name",
    "job_type",
    "trigger_type",
    "schedule_id",
    "schedule_enabled",
    "scheduled_time",
    "schedule_timezone",
    "schedule_frequency",
    "schedule_config",
    "job_instance_id",
    "root_activity_id",
    "start_time",
    "end_time",
    "duration_seconds",
    "status",
    "failure_reason",
    "source_system",
    "evidence",
    "technical_id",
    "notes"
)

$gapColumns = @(
    "gap_type",
    "workspace_name",
    "item_name",
    "item_type",
    "qualified_name",
    "job_type",
    "api_path",
    "status_code",
    "error",
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

function Limit-Text {
    param(
        [string]$Text,
        [int]$MaxLength = 500
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

function ConvertTo-CompactJson {
    param(
        [object]$Value,
        [int]$MaxLength = 1200
    )

    if ($null -eq $Value) {
        return ""
    }

    try {
        return Limit-Text -Text ($Value | ConvertTo-Json -Depth 50 -Compress) -MaxLength $MaxLength
    }
    catch {
        return Limit-Text -Text ([string]$Value) -MaxLength $MaxLength
    }
}

function Get-FabricErrorText {
    param([object]$Response)

    $payload = Convert-JsonContent -Content $Response.content
    if ($payload) {
        $code = Get-FieldValue -Object $payload -Names @("errorCode", "code")
        $message = Get-FieldValue -Object $payload -Names @("message")
        if ($code -or $message) {
            return Limit-Text -Text "$code $message" -MaxLength 800
        }
    }

    if ($Response.error) {
        return Limit-Text -Text $Response.error -MaxLength 800
    }

    return Limit-Text -Text $Response.content -MaxLength 800
}

function Resolve-ApiUri {
    param(
        [string]$Path,
        [string]$BaseUrl
    )

    if ($Path.StartsWith("http")) {
        return $Path
    }

    return "$($BaseUrl.TrimEnd('/'))/$($Path.TrimStart('/'))"
}

function Normalize-Key {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return ($Value.Trim().ToLowerInvariant() -replace "\s+", " ")
}

function Invoke-ApiGet {
    param(
        [string]$Path,
        [hashtable]$Headers,
        [string]$BaseUrl
    )

    $uri = Resolve-ApiUri -Path $Path -BaseUrl $BaseUrl

    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        try {
            $response = Invoke-WebRequest -Method Get -Uri $uri -Headers $Headers -SkipHttpErrorCheck
            $statusCode = [int]$response.StatusCode

            if (($statusCode -eq 429 -or $statusCode -eq 503 -or $statusCode -eq 504) -and $attempt -lt $RetryCount) {
                $retryAfter = Get-HeaderValue -Headers $response.Headers -Name "Retry-After"
                $delaySeconds = if ($retryAfter -match "^\d+$") { [int]$retryAfter } else { [math]::Min(90, [math]::Pow(2, $attempt + 1)) }
                Start-Sleep -Seconds $delaySeconds
                continue
            }

            if ($RequestDelayMilliseconds -gt 0) {
                Start-Sleep -Milliseconds $RequestDelayMilliseconds
            }

            return [pscustomobject]@{
                succeeded = ($statusCode -ge 200 -and $statusCode -lt 300)
                status_code = $statusCode
                content = [string]$response.Content
                headers = $response.Headers
                error = ""
                uri = $uri
            }
        }
        catch {
            if ($attempt -lt $RetryCount) {
                $delaySeconds = [math]::Min(90, [math]::Pow(2, $attempt + 1))
                Start-Sleep -Seconds $delaySeconds
                continue
            }

            return [pscustomobject]@{
                succeeded = $false
                status_code = ""
                content = ""
                headers = @{}
                error = $_.Exception.Message
                uri = $uri
            }
        }
    }
}

function Get-PagedApiValues {
    param(
        [string]$Path,
        [hashtable]$Headers,
        [string]$BaseUrl
    )

    $values = @()
    $nextPath = $Path
    $lastResponse = $null

    while ($nextPath) {
        $response = Invoke-ApiGet -Path $nextPath -Headers $Headers -BaseUrl $BaseUrl
        $lastResponse = $response
        if (-not $response.succeeded) {
            return [pscustomobject]@{
                succeeded = $false
                values = @()
                status_code = $response.status_code
                error = Get-FabricErrorText -Response $response
                uri = $response.uri
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
            $separator = if ($Path.Contains("?")) { "&" } else { "?" }
            $nextPath = "$Path$separator`continuationToken=$([uri]::EscapeDataString([string]$payload.continuationToken))"
        }
        else {
            $nextPath = ""
        }
    }

    return [pscustomobject]@{
        succeeded = $true
        values = $values
        status_code = if ($lastResponse) { $lastResponse.status_code } else { 200 }
        error = ""
        uri = Resolve-ApiUri -Path $Path -BaseUrl $BaseUrl
    }
}

function Convert-ToUtcDateTimeOffset {
    param([string]$Value)

    if (-not $Value) {
        return $null
    }

    try {
        $raw = if ($Value.EndsWith("Z") -or $Value -match "[+-]\d\d:\d\d$") { $Value } else { "$Value`Z" }
        return [datetimeoffset]::Parse($raw).ToUniversalTime()
    }
    catch {
        return $null
    }
}

function Get-DurationSeconds {
    param(
        [string]$StartTime,
        [string]$EndTime
    )

    $start = Convert-ToUtcDateTimeOffset -Value $StartTime
    $end = Convert-ToUtcDateTimeOffset -Value $EndTime
    if ($null -eq $start -or $null -eq $end) {
        return ""
    }

    return [math]::Round(($end - $start).TotalSeconds, 3)
}

# The average is a single bad data point away from being meaningless: one
# corrupted duration (e.g. a stored duration of several weeks when the
# run's own start/end timestamps show it actually took minutes) is enough to drag avg_duration_seconds to something
# absurd for every downstream consumer (Planning's critical path, badges).
# The median is not sensitive to a single outlier the way a mean is -- it
# ignores how extreme the extremes are by construction -- which is exactly
# the property needed here. (The mode isn't a good fit for this: durations
# are continuous, so there is essentially never a real "most common value"
# without arbitrary bucketing first.)
function Get-MedianSeconds {
    param([double[]]$Values)
    if (-not $Values -or $Values.Count -eq 0) { return "" }
    $sorted = @($Values | Sort-Object)
    $count = $sorted.Count
    $mid = [math]::Floor($count / 2)
    if ($count % 2 -eq 0) {
        return [math]::Round((([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2), 3)
    }
    return [math]::Round([double]$sorted[$mid], 3)
}

function Get-ScheduleFrequencyText {
    param([object]$Configuration)

    if ($null -eq $Configuration) {
        return ""
    }

    $type = Get-FieldValue -Object $Configuration -Names @("type")
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($type) {
        $parts.Add($type) | Out-Null
    }

    $interval = Get-FieldValue -Object $Configuration -Names @("interval")
    if ($interval) {
        $parts.Add("interval=$interval minutes") | Out-Null
    }

    $times = ""
    if ($Configuration.PSObject.Properties.Name -contains "times" -and $Configuration.times) {
        $times = (@($Configuration.times) -join ",")
        $parts.Add("times=$times") | Out-Null
    }

    if ($Configuration.PSObject.Properties.Name -contains "weekdays" -and $Configuration.weekdays) {
        $parts.Add("weekdays=$(@($Configuration.weekdays) -join ",")") | Out-Null
    }

    $recurrence = Get-FieldValue -Object $Configuration -Names @("recurrence")
    if ($recurrence) {
        $parts.Add("recurrence=$recurrence") | Out-Null
    }

    return ($parts -join "; ")
}

function Get-CandidateScheduleJobTypes {
    param(
        [string]$ItemType,
        [string[]]$KnownJobTypes
    )

    $candidates = [System.Collections.Generic.List[string]]::new()
    foreach ($jobType in $KnownJobTypes) {
        if ($jobType -and -not $candidates.Contains($jobType)) {
            $candidates.Add($jobType) | Out-Null
        }
    }

    if (-not $ProbeCandidateSchedules) {
        return @($candidates)
    }

    $guesses = switch ($ItemType) {
        "DataPipeline" { @("Execute", "DefaultJob") }
        "Notebook" { @("RunNotebook", "Execute", "DefaultJob") }
        "SemanticModel" { @("Refresh", "DefaultJob") }
        "CopyJob" { @("Execute", "DefaultJob") }
        "Dataflow" { @("Refresh", "DefaultJob") }
        "Eventstream" { @("DefaultJob") }
        "Reflex" { @("DefaultJob") }
        "KQLQueryset" { @("DefaultJob") }
        "KQLDashboard" { @("DefaultJob") }
        "UserDataFunction" { @("DefaultJob") }
        default { @("DefaultJob") }
    }

    foreach ($guess in $guesses) {
        if ($guess -and -not $candidates.Contains($guess)) {
            $candidates.Add($guess) | Out-Null
        }
    }

    return @($candidates)
}

function Add-Gap {
    param(
        [System.Collections.Generic.List[object]]$GapRows,
        [string]$GapType,
        [object]$Item,
        [string]$JobType,
        [string]$ApiPath,
        [string]$StatusCode,
        [string]$ErrorText,
        [string]$Notes = ""
    )

    $GapRows.Add([pscustomobject]@{
        gap_type = $GapType
        workspace_name = Get-FieldValue -Object $Item -Names @("workspace_name")
        item_name = Get-FieldValue -Object $Item -Names @("item_name")
        item_type = Get-FieldValue -Object $Item -Names @("item_type")
        qualified_name = Get-FieldValue -Object $Item -Names @("qualified_name")
        job_type = $JobType
        api_path = $ApiPath
        status_code = $StatusCode
        error = Limit-Text -Text $ErrorText -MaxLength 800
        notes = Limit-Text -Text $Notes -MaxLength 500
    }) | Out-Null
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
$allItemRows = @(Import-Csv -Path $ItemsPath | Where-Object { $_.status -eq "discovered" })
$workspaceIdByName = @{}
foreach ($workspace in $workspaceRows) {
    $workspaceName = Get-FieldValue -Object $workspace -Names @("workspace_name")
    $workspaceId = Get-FieldValue -Object $workspace -Names @("technical_id")
    if ($workspaceName -and $workspaceId) {
        $workspaceIdByName[$workspaceName] = $workspaceId
    }
}

$targetItems = if ($IncludeAllItems) {
    @($allItemRows)
}
else {
    @($allItemRows | Where-Object { $ExecutionItemTypes -contains $_.item_type })
}

$workspaceFilterSet = $null
if ($WorkspaceNameFilter) {
    $workspaceFilterSet = @{}
    foreach ($name in ($WorkspaceNameFilter -split "[;,]" | ForEach-Object { Normalize-Key $_ } | Where-Object { $_ })) {
        $workspaceFilterSet[$name] = $true
    }
    $targetItems = @($targetItems | Where-Object { $workspaceFilterSet.ContainsKey((Normalize-Key $_.workspace_name)) })
}

if ($MaxItems -gt 0) {
    $targetItems = @($targetItems | Select-Object -First $MaxItems)
}

if ($targetItems.Count -eq 0) {
    throw "No target items selected for execution timing discovery."
}

$token = Get-FreshAzureCliToken -Resource "https://api.fabric.microsoft.com" -AzCommand $AzCommand
$headers = @{
    Authorization = "Bearer $token"
    "Content-Type" = "application/json"
}

$powerBiHeaders = $null
if ($UsePowerBiForSemanticModels) {
    $powerBiToken = Get-FreshAzureCliToken -Resource "https://analysis.windows.net/powerbi/api" -AzCommand $AzCommand
    $powerBiHeaders = @{
        Authorization = "Bearer $powerBiToken"
        "Content-Type" = "application/json"
    }
}

$executionRows = [System.Collections.Generic.List[object]]::new()
$gapRows = [System.Collections.Generic.List[object]]::new()

# When scoped to specific workspaces, seed the two per-row outputs with
# whatever is already on disk for every OTHER workspace so this run only
# refreshes the filtered slice instead of wiping execution/schedule history
# for the rest of the tenant. Everything computed further down (the
# tenant-wide summary rollup and the per-item duration table) is derived
# from these same lists *after* the seed, so it still reflects the whole
# tenant -- freshly for the filtered workspace(s), last-known for
# everything else -- rather than only the filtered slice.
if ($workspaceFilterSet) {
    if (Test-Path $OutputPath) {
        foreach ($row in @(Import-Csv -Path $OutputPath | Where-Object { -not $workspaceFilterSet.ContainsKey((Normalize-Key $_.workspace_name)) })) {
            $executionRows.Add($row) | Out-Null
        }
    }
    if (Test-Path $QueryGapsPath) {
        foreach ($row in @(Import-Csv -Path $QueryGapsPath | Where-Object { -not $workspaceFilterSet.ContainsKey((Normalize-Key $_.workspace_name)) })) {
            $gapRows.Add($row) | Out-Null
        }
    }
}
$processed = 0
$jobInstanceQuerySuccess = 0
$scheduleQuerySuccess = 0
$jobInstanceCount = 0
$scheduleCount = 0
$itemsWithJobInstances = 0
$itemsWithSchedules = 0
$scheduleQueryAttempts = 0
$script:sessionDiedAt = $null

foreach ($item in ($targetItems | Sort-Object -Property workspace_name, item_type, item_name)) {
    $processed += 1
    if ($ProgressInterval -gt 0 -and ($processed % $ProgressInterval -eq 0)) {
        Write-Host "Processed $processed / $($targetItems.Count) execution-timing target items..."
    }

    # Get-FreshAzureCliToken only actually re-fetches if the cached token is
    # stale (see LineageCommon.psm1) -- cheap to call every iteration, and
    # necessary here now that a full tenant-wide run can take a while.
    # Unguarded, a truly dead session (not just a routine refresh -- e.g. a
    # tenant Conditional Access policy capping refresh-token lifetime)
    # throws here uncaught and used to abort
    # the whole script before it ever reached its Export-Csv calls, losing
    # every item already processed this run, not just the ones still
    # pending (see the same fix in 04_analyze_items.ps1). $executionRows/
    # $gapRows already hold everything gathered up to this point, so
    # stopping cleanly here and falling through to the normal end-of-script
    # writes is enough to keep it.
    try {
        $headers.Authorization = "Bearer $(Get-FreshAzureCliToken -Resource 'https://api.fabric.microsoft.com' -AzCommand $AzCommand)"
        if ($powerBiHeaders) {
            $powerBiHeaders.Authorization = "Bearer $(Get-FreshAzureCliToken -Resource 'https://analysis.windows.net/powerbi/api' -AzCommand $AzCommand)"
        }
    }
    catch {
        $script:sessionDiedAt = $processed
        Write-Host "Azure session appears to be fully expired (not just due for a routine refresh) after $processed / $($targetItems.Count) items -- stopping here instead of losing this run's progress. Re-authenticate (az login) and re-run to pick up the rest. Error: $($_.Exception.Message)"
        break
    }

    $workspaceName = Get-FieldValue -Object $item -Names @("workspace_name")
    $workspaceId = if ($workspaceIdByName.ContainsKey($workspaceName)) { $workspaceIdByName[$workspaceName] } else { "" }
    $itemId = Get-FieldValue -Object $item -Names @("technical_id")
    $itemType = Get-FieldValue -Object $item -Names @("item_type")
    $qualifiedName = Get-FieldValue -Object $item -Names @("qualified_name")
    $knownJobTypes = [System.Collections.Generic.List[string]]::new()
    $itemHadJobInstances = $false
    $itemHadSchedules = $false

    if (-not $workspaceId -or -not $itemId) {
        Add-Gap -GapRows $gapRows -GapType "metadata_missing" -Item $item -JobType "" -ApiPath "" -StatusCode "" -ErrorText "Workspace id or item id missing." -Notes "Execution timing API skipped."
        continue
    }

    if ($UsePowerBiForSemanticModels -and $itemType -eq "SemanticModel") {
        if (-not $SkipJobInstances) {
            $refreshHistoryPath = "groups/$workspaceId/datasets/$itemId/refreshes?`$top=$PowerBiRefreshHistoryTop"
            $refreshResult = Get-PagedApiValues -Path $refreshHistoryPath -Headers $powerBiHeaders -BaseUrl $PowerBiApiBaseUrl
            if ($refreshResult.succeeded) {
                $jobInstanceQuerySuccess += 1
                $refreshes = @($refreshResult.values)
                $jobInstanceCount += $refreshes.Count
                if ($refreshes.Count -gt 0) {
                    $itemHadJobInstances = $true
                    $itemsWithJobInstances += 1
                }

                foreach ($refresh in $refreshes) {
                    $startTime = Get-FieldValue -Object $refresh -Names @("startTime")
                    $endTime = Get-FieldValue -Object $refresh -Names @("endTime")
                    $durationSeconds = Get-DurationSeconds -StartTime $startTime -EndTime $endTime
                    $failureReason = Get-FieldValue -Object $refresh -Names @("serviceExceptionJson")
                    if (-not $failureReason -and $refresh.PSObject.Properties.Name -contains "refreshAttempts") {
                        $failureReason = ConvertTo-CompactJson -Value $refresh.refreshAttempts -MaxLength 1200
                    }

                    $executionRows.Add([pscustomobject]@{
                        record_type = "job_instance"
                        workspace_name = $workspaceName
                        item_name = Get-FieldValue -Object $item -Names @("item_name")
                        item_type = $itemType
                        qualified_name = $qualifiedName
                        job_type = "SemanticModelRefresh"
                        trigger_type = Get-FieldValue -Object $refresh -Names @("refreshType")
                        schedule_id = ""
                        schedule_enabled = ""
                        scheduled_time = ""
                        schedule_timezone = ""
                        schedule_frequency = ""
                        schedule_config = ""
                        job_instance_id = Get-FieldValue -Object $refresh -Names @("requestId")
                        root_activity_id = Get-FieldValue -Object $refresh -Names @("requestId")
                        start_time = $startTime
                        end_time = $endTime
                        duration_seconds = $durationSeconds
                        status = Get-FieldValue -Object $refresh -Names @("status")
                        failure_reason = $failureReason
                        source_system = "Power BI REST API via Azure CLI"
                        evidence = "Power BI dataset refresh history API."
                        technical_id = $itemId
                        notes = "Semantic model refresh history."
                    }) | Out-Null
                }
            }
            else {
                Add-Gap -GapRows $gapRows -GapType "semantic_model_refresh_history_unavailable" -Item $item -JobType "SemanticModelRefresh" -ApiPath $refreshHistoryPath -StatusCode $refreshResult.status_code -ErrorText $refreshResult.error -Notes "Power BI refresh history unavailable for this semantic model."
            }
        }

        if (-not $SkipSchedules) {
            $refreshSchedulePath = "groups/$workspaceId/datasets/$itemId/refreshSchedule"
            $scheduleResponse = Invoke-ApiGet -Path $refreshSchedulePath -Headers $powerBiHeaders -BaseUrl $PowerBiApiBaseUrl
            $scheduleQueryAttempts += 1
            if ($scheduleResponse.succeeded) {
                $scheduleQuerySuccess += 1
                $schedulePayload = Convert-JsonContent -Content $scheduleResponse.content
                if ($schedulePayload) {
                    $scheduleCount += 1
                    $itemsWithSchedules += 1
                    $itemHadSchedules = $true
                    $days = if ($schedulePayload.PSObject.Properties.Name -contains "days" -and $schedulePayload.days) { @($schedulePayload.days) -join "," } else { "" }
                    $times = if ($schedulePayload.PSObject.Properties.Name -contains "times" -and $schedulePayload.times) { @($schedulePayload.times) -join "," } else { "" }
                    $timezone = Get-FieldValue -Object $schedulePayload -Names @("localTimeZoneId")
                    $enabled = Get-FieldValue -Object $schedulePayload -Names @("enabled")

                    $executionRows.Add([pscustomobject]@{
                        record_type = "schedule"
                        workspace_name = $workspaceName
                        item_name = Get-FieldValue -Object $item -Names @("item_name")
                        item_type = $itemType
                        qualified_name = $qualifiedName
                        job_type = "SemanticModelRefresh"
                        trigger_type = "Scheduled"
                        schedule_id = ""
                        schedule_enabled = $enabled
                        scheduled_time = $times
                        schedule_timezone = $timezone
                        schedule_frequency = "days=$days; times=$times"
                        schedule_config = ConvertTo-CompactJson -Value $schedulePayload -MaxLength 1200
                        job_instance_id = ""
                        root_activity_id = ""
                        start_time = ""
                        end_time = ""
                        duration_seconds = ""
                        status = if ($enabled -eq "True") { "Enabled" } else { "Disabled" }
                        failure_reason = ""
                        source_system = "Power BI REST API via Azure CLI"
                        evidence = "Power BI dataset refresh schedule API."
                        technical_id = $itemId
                        notes = "Semantic model refresh schedule."
                    }) | Out-Null
                }
            }
            else {
                Add-Gap -GapRows $gapRows -GapType "semantic_model_refresh_schedule_unavailable" -Item $item -JobType "SemanticModelRefresh" -ApiPath $refreshSchedulePath -StatusCode $scheduleResponse.status_code -ErrorText (Get-FabricErrorText -Response $scheduleResponse) -Notes "Power BI refresh schedule unavailable for this semantic model."
            }
        }

        continue
    }

    if (-not $SkipJobInstances) {
        $instancesPath = "workspaces/$workspaceId/items/$itemId/jobs/instances"
        $instancesResult = Get-PagedApiValues -Path $instancesPath -Headers $headers -BaseUrl $FabricApiBaseUrl
        if ($instancesResult.succeeded) {
            $jobInstanceQuerySuccess += 1
            $instances = @($instancesResult.values)
            $jobInstanceCount += $instances.Count
            if ($instances.Count -gt 0) {
                $itemHadJobInstances = $true
                $itemsWithJobInstances += 1
            }

            foreach ($instance in $instances) {
                $jobType = Get-FieldValue -Object $instance -Names @("jobType")
                if ($jobType -and -not $knownJobTypes.Contains($jobType)) {
                    $knownJobTypes.Add($jobType) | Out-Null
                }

                $startTime = Get-FieldValue -Object $instance -Names @("startTimeUtc")
                $endTime = Get-FieldValue -Object $instance -Names @("endTimeUtc")
                $durationSeconds = Get-DurationSeconds -StartTime $startTime -EndTime $endTime
                $failureReason = ""
                if ($instance.PSObject.Properties.Name -contains "failureReason" -and $instance.failureReason) {
                    $failureReason = ConvertTo-CompactJson -Value $instance.failureReason -MaxLength 1200
                }

                $executionRows.Add([pscustomobject]@{
                    record_type = "job_instance"
                    workspace_name = $workspaceName
                    item_name = Get-FieldValue -Object $item -Names @("item_name")
                    item_type = $itemType
                    qualified_name = $qualifiedName
                    job_type = $jobType
                    trigger_type = Get-FieldValue -Object $instance -Names @("invokeType")
                    schedule_id = ""
                    schedule_enabled = ""
                    scheduled_time = ""
                    schedule_timezone = ""
                    schedule_frequency = ""
                    schedule_config = ""
                    job_instance_id = Get-FieldValue -Object $instance -Names @("id")
                    root_activity_id = Get-FieldValue -Object $instance -Names @("rootActivityId")
                    start_time = $startTime
                    end_time = $endTime
                    duration_seconds = $durationSeconds
                    status = Get-FieldValue -Object $instance -Names @("status")
                    failure_reason = $failureReason
                    source_system = "Fabric REST API via Azure CLI"
                    evidence = "Job Scheduler list item job instances API."
                    technical_id = $itemId
                    notes = ""
                }) | Out-Null
            }
        }
        else {
            Add-Gap -GapRows $gapRows -GapType "job_instances_unavailable" -Item $item -JobType "" -ApiPath $instancesPath -StatusCode $instancesResult.status_code -ErrorText $instancesResult.error -Notes "Job history unavailable or unsupported for this item."
        }
    }

    if (-not $SkipSchedules) {
        $scheduleJobTypes = Get-CandidateScheduleJobTypes -ItemType $itemType -KnownJobTypes @($knownJobTypes)
        foreach ($jobType in $scheduleJobTypes) {
            if (-not $jobType) {
                continue
            }

            $scheduleQueryAttempts += 1
            $schedulesPath = "workspaces/$workspaceId/items/$itemId/jobs/$jobType/schedules"
            $schedulesResult = Get-PagedApiValues -Path $schedulesPath -Headers $headers -BaseUrl $FabricApiBaseUrl
            if ($schedulesResult.succeeded) {
                $scheduleQuerySuccess += 1
                $schedules = @($schedulesResult.values)
                $scheduleCount += $schedules.Count
                if ($schedules.Count -gt 0 -and -not $itemHadSchedules) {
                    $itemsWithSchedules += 1
                    $itemHadSchedules = $true
                }

                foreach ($schedule in $schedules) {
                    $configuration = $null
                    if ($schedule.PSObject.Properties.Name -contains "configuration") {
                        $configuration = $schedule.configuration
                    }

                    $startDateTime = Get-FieldValue -Object $configuration -Names @("startDateTime")
                    $timezone = Get-FieldValue -Object $configuration -Names @("localTimeZoneId")

                    $executionRows.Add([pscustomobject]@{
                        record_type = "schedule"
                        workspace_name = $workspaceName
                        item_name = Get-FieldValue -Object $item -Names @("item_name")
                        item_type = $itemType
                        qualified_name = $qualifiedName
                        job_type = $jobType
                        trigger_type = "Scheduled"
                        schedule_id = Get-FieldValue -Object $schedule -Names @("id")
                        schedule_enabled = Get-FieldValue -Object $schedule -Names @("enabled")
                        scheduled_time = $startDateTime
                        schedule_timezone = $timezone
                        schedule_frequency = Get-ScheduleFrequencyText -Configuration $configuration
                        schedule_config = ConvertTo-CompactJson -Value $configuration -MaxLength 1200
                        job_instance_id = ""
                        root_activity_id = ""
                        start_time = ""
                        end_time = ""
                        duration_seconds = ""
                        status = if ((Get-FieldValue -Object $schedule -Names @("enabled")) -eq "True") { "Enabled" } else { "Disabled" }
                        failure_reason = ""
                        source_system = "Fabric REST API via Azure CLI"
                        evidence = "Job Scheduler list item schedules API."
                        technical_id = $itemId
                        notes = "Schedule owner: $(ConvertTo-CompactJson -Value $schedule.owner -MaxLength 500)"
                    }) | Out-Null
                }
            }
            else {
                Add-Gap -GapRows $gapRows -GapType "schedules_unavailable" -Item $item -JobType $jobType -ApiPath $schedulesPath -StatusCode $schedulesResult.status_code -ErrorText $schedulesResult.error -Notes "Schedule unavailable, unsupported, or invalid job type."
            }
        }
    }
}

# Job-instance rows are immutable historical facts -- a run that already
# completed/failed in the past can never change. Both API sources this
# script queries only ever return a bounded recent window (Power BI's
# refresh history is capped at $PowerBiRefreshHistoryTop; Fabric's job-
# instance list behaves the same way) -- so a later re-scan's fresh fetch
# can genuinely no longer include a real run that DID happen, simply
# because newer runs pushed it out of that window. Until now, this
# script's per-item rows were fully replaced by whatever came back this
# time, silently discarding that older history on every re-run -- exactly
# the "history that already happened can never change, so we should never
# lose what we already know" gap. Merge this run's
# freshly-fetched job_instance rows with whatever the SAME items already
# had on disk, deduped by (qualified_name, job_instance_id): nothing
# already captured is ever dropped, and nothing gets duplicated. Schedule
# rows describe CURRENT config (can genuinely change), so those are left
# as a plain per-item replace, unchanged from before.
if (Test-Path $OutputPath) {
    $scopeSet = @{}
    foreach ($scopeItem in $targetItems) {
        $qn = Get-FieldValue -Object $scopeItem -Names @("qualified_name")
        if ($qn) { $scopeSet[$qn] = $true }
    }
    $existingJobRowsInScope = @(
        Import-Csv -Path $OutputPath |
            Where-Object { $_.record_type -eq "job_instance" -and $scopeSet.ContainsKey($_.qualified_name) }
    )
    if ($existingJobRowsInScope.Count -gt 0) {
        $seenJobKeys = @{}
        foreach ($row in $executionRows) {
            if ($row.record_type -eq "job_instance") {
                $seenJobKeys["$($row.qualified_name)|$($row.job_instance_id)"] = $true
            }
        }
        $preservedRows = @($existingJobRowsInScope | Where-Object {
            -not $seenJobKeys.ContainsKey("$($_.qualified_name)|$($_.job_instance_id)")
        })
        if ($preservedRows.Count -gt 0) {
            Write-Host "Preserving $($preservedRows.Count) job-instance row(s) already on disk that this run's fetch window no longer covers."
            $executionRows = @($executionRows) + @($preservedRows)
        }
    }
}

Ensure-ParentDirectory -Path $OutputPath
$executionRows |
    Select-Object -Property $executionColumns |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Ensure-ParentDirectory -Path $QueryGapsPath
$gapRows |
    Select-Object -Property $gapColumns |
    Export-Csv -Path $QueryGapsPath -NoTypeInformation -Encoding UTF8

$jobRows = @($executionRows | Where-Object { $_.record_type -eq "job_instance" })
$scheduleRows = @($executionRows | Where-Object { $_.record_type -eq "schedule" })
$completedRows = @($jobRows | Where-Object { $_.status -eq "Completed" -and $_.duration_seconds -ne "" })
$failedRows = @($jobRows | Where-Object { $_.status -eq "Failed" })
$scheduledJobRows = @($jobRows | Where-Object { $_.trigger_type -eq "Scheduled" })
$manualJobRows = @($jobRows | Where-Object { $_.trigger_type -eq "Manual" })

$summaryRows = @(
    [pscustomobject]@{ metric = "target_items"; value = $targetItems.Count; notes = "Execution timing target item count." }
    [pscustomobject]@{ metric = "job_instance_query_success"; value = $jobInstanceQuerySuccess; notes = "" }
    [pscustomobject]@{ metric = "items_with_job_instances"; value = $itemsWithJobInstances; notes = "" }
    [pscustomobject]@{ metric = "job_instances"; value = $jobRows.Count; notes = "" }
    [pscustomobject]@{ metric = "completed_job_instances"; value = @($jobRows | Where-Object { $_.status -eq "Completed" }).Count; notes = "" }
    [pscustomobject]@{ metric = "failed_job_instances"; value = $failedRows.Count; notes = "" }
    [pscustomobject]@{ metric = "scheduled_job_instances"; value = $scheduledJobRows.Count; notes = "" }
    [pscustomobject]@{ metric = "manual_job_instances"; value = $manualJobRows.Count; notes = "" }
    [pscustomobject]@{ metric = "schedule_query_attempts"; value = $scheduleQueryAttempts; notes = "" }
    [pscustomobject]@{ metric = "schedule_query_success"; value = $scheduleQuerySuccess; notes = "" }
    [pscustomobject]@{ metric = "items_with_schedules"; value = $itemsWithSchedules; notes = "" }
    [pscustomobject]@{ metric = "schedules"; value = $scheduleRows.Count; notes = "" }
    [pscustomobject]@{ metric = "enabled_schedules"; value = @($scheduleRows | Where-Object { $_.schedule_enabled -eq "True" }).Count; notes = "" }
    [pscustomobject]@{ metric = "disabled_schedules"; value = @($scheduleRows | Where-Object { $_.schedule_enabled -eq "False" }).Count; notes = "" }
    [pscustomobject]@{ metric = "query_gaps"; value = $gapRows.Count; notes = "Rows in analysis/execution_query_gaps.csv." }
)

if ($completedRows.Count -gt 0) {
    $durations = @($completedRows | ForEach-Object { [double]$_.duration_seconds })
    $summaryRows += [pscustomobject]@{ metric = "min_completed_duration_seconds"; value = [math]::Round(($durations | Measure-Object -Minimum).Minimum, 3); notes = "" }
    $summaryRows += [pscustomobject]@{ metric = "avg_completed_duration_seconds"; value = [math]::Round(($durations | Measure-Object -Average).Average, 3); notes = "" }
    $summaryRows += [pscustomobject]@{ metric = "max_completed_duration_seconds"; value = [math]::Round(($durations | Measure-Object -Maximum).Maximum, 3); notes = "" }
}

Ensure-ParentDirectory -Path $ExecutionSummaryPath
$summaryRows | Export-Csv -Path $ExecutionSummaryPath -NoTypeInformation -Encoding UTF8

$durationRows = @(
    $jobRows |
        Group-Object -Property qualified_name, job_type |
        ForEach-Object {
            $groupRows = @($_.Group)
            $first = $groupRows[0]
            $completed = @($groupRows | Where-Object { $_.status -eq "Completed" -and $_.duration_seconds -ne "" })
            $durations = @($completed | ForEach-Object { [double]$_.duration_seconds })
            $latestStart = @($groupRows | Where-Object { $_.start_time } | Sort-Object -Property start_time -Descending | Select-Object -First 1)
            $latestEnd = @($groupRows | Where-Object { $_.end_time } | Sort-Object -Property end_time -Descending | Select-Object -First 1)
            $latestRun = @($groupRows | Where-Object { $_.start_time } | Sort-Object -Property start_time -Descending | Select-Object -First 1)

            [pscustomobject]@{
                workspace_name = $first.workspace_name
                item_name = $first.item_name
                item_type = $first.item_type
                qualified_name = $first.qualified_name
                job_type = $first.job_type
                run_count = $groupRows.Count
                completed_count = $completed.Count
                failed_count = @($groupRows | Where-Object { $_.status -eq "Failed" }).Count
                cancelled_count = @($groupRows | Where-Object { $_.status -eq "Cancelled" }).Count
                scheduled_count = @($groupRows | Where-Object { $_.trigger_type -eq "Scheduled" }).Count
                manual_count = @($groupRows | Where-Object { $_.trigger_type -eq "Manual" }).Count
                latest_start_time = if ($latestStart.Count -gt 0) { $latestStart[0].start_time } else { "" }
                latest_end_time = if ($latestEnd.Count -gt 0) { $latestEnd[0].end_time } else { "" }
                min_duration_seconds = if ($durations.Count -gt 0) { [math]::Round(($durations | Measure-Object -Minimum).Minimum, 3) } else { "" }
                avg_duration_seconds = if ($durations.Count -gt 0) { [math]::Round(($durations | Measure-Object -Average).Average, 3) } else { "" }
                median_duration_seconds = Get-MedianSeconds -Values $durations
                max_duration_seconds = if ($durations.Count -gt 0) { [math]::Round(($durations | Measure-Object -Maximum).Maximum, 3) } else { "" }
                last_status = if ($latestRun.Count -gt 0) { $latestRun[0].status } else { "" }
            }
        } |
        Sort-Object -Property max_duration_seconds, run_count -Descending
)

Ensure-ParentDirectory -Path $DurationByItemPath
$durationRows | Export-Csv -Path $DurationByItemPath -NoTypeInformation -Encoding UTF8

$gapParts = @()
if ($gapRows.Count -gt 0) {
    $gapParts += "$($gapRows.Count) execution timing API gaps recorded."
}
if ($jobRows.Count -eq 0) {
    $gapParts += "No job instances were discovered."
}
if ($scheduleRows.Count -eq 0) {
    $gapParts += "No schedules were discovered."
}

if ($gapParts.Count -gt 0) {
    Set-UnresolvedEntry `
        -Title "Phase 6 execution timing gaps" `
        -Status "open" `
        -Evidence ($gapParts -join " ") `
        -NextStep "Review analysis/execution_query_gaps.csv and decide whether to broaden item types, reduce schedule probing, or use approved alternate sources such as monitoring hub exports."
}
else {
    Set-UnresolvedEntry `
        -Title "Phase 6 execution timing gaps" `
        -Status "resolved" `
        -Evidence "Execution timing discovery completed without query gaps." `
        -NextStep "User reviews Phase 6 outputs and approves Phase 7 orchestration optimization."
}

if ($script:sessionDiedAt) {
    Write-Host "Phase 6 execution timing discovery STOPPED EARLY: Azure session expired after $script:sessionDiedAt / $($targetItems.Count) items. Everything discovered before that point was still written normally below -- re-authenticate and re-run this phase to pick up the remaining items."
}
else {
    Write-Host "Phase 6 execution timing discovery completed."
}
if ($workspaceFilterSet) {
    Write-Host "Workspace filter: $WorkspaceNameFilter (other workspaces retained unchanged from $OutputPath / $QueryGapsPath / $DurationByItemPath / $ExecutionSummaryPath)"
}
Write-Host "Target items: $($targetItems.Count)"
Write-Host "Job instance query successes: $jobInstanceQuerySuccess"
Write-Host "Items with job instances: $itemsWithJobInstances"
Write-Host "Job instances discovered: $($jobRows.Count)"
Write-Host "Completed job instances: $(@($jobRows | Where-Object { $_.status -eq "Completed" }).Count)"
Write-Host "Failed job instances: $($failedRows.Count)"
Write-Host "Scheduled job instances: $($scheduledJobRows.Count)"
Write-Host "Manual job instances: $($manualJobRows.Count)"
Write-Host "Schedule query attempts: $scheduleQueryAttempts"
Write-Host "Schedule query successes: $scheduleQuerySuccess"
Write-Host "Items with schedules: $itemsWithSchedules"
Write-Host "Schedules discovered: $($scheduleRows.Count)"
Write-Host "Query gaps: $($gapRows.Count)"
Write-Host "Output: $OutputPath"
Write-Host "Summary: $ExecutionSummaryPath"
Write-Host "Duration by item: $DurationByItemPath"
Write-Host "Query gaps file: $QueryGapsPath"

if ($script:sessionDiedAt) {
    # Everything gathered up to the stop point was already written above
    # (correctly, not lost) -- this exit code exists only so a caller like
    # 99_refresh_lineage_project.ps1 knows this run was cut short and the
    # tenant isn't fully covered yet, not to signal the data that WAS
    # written is somehow bad.
    exit 1
}
