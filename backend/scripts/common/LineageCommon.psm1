# Shared helpers used across scripts/*.ps1. Only functions verified to be
# byte-identical (modulo whitespace) across every script that previously
# defined its own copy live here. A prior audit found several OTHER
# similarly-named helpers (Get-FieldValue, Normalize-Key, Export-Rows,
# Limit-Text, Convert-ToInt, Import-OptionalCsv) that were deliberately NOT
# centralized: diffing every occurrence turned up real, intentional
# differences between scripts (not just copy-paste drift), so merging them
# here would risk silently changing behavior in scripts that have no
# automated test coverage today. A 2026-07 follow-up audit found a second,
# distinct family that IS safe to centralize (byte-identical logic, only
# formatting differs) -- see Get-AzureCliToken, Invoke-FabricWebRequest,
# Get-HeaderValue, Convert-JsonContent, and Get-PagedFabricValues below.
# Import this module with `Import-Module (Join-Path $PSScriptRoot
# "common/LineageCommon.psm1") -Force` from any script in this directory.

Set-StrictMode -Version Latest

function Ensure-ParentDirectory {
    param([string]$Path)

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
}

# Available for any script to adopt going forward -- NOT retrofitted onto
# the ~50 scripts that already call Write-Host directly today, since that
# would be a much larger, purely-cosmetic change with no test coverage to
# catch a mistake across that many files in one pass (see Fase 2's note
# above about why the riskier helpers weren't centralized either). New
# scripts, and any existing one touched for another reason, should prefer
# this over a bare Write-Host so log lines are at least consistently
# leveled and timestamped from here on.
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("Info", "Warn", "Error")]
        [string]$Level = "Info"
    )
    $timestamp = (Get-Date).ToString("s")
    $line = "[$timestamp] [$Level] $Message"
    switch ($Level) {
        "Warn" { Write-Warning $line }
        "Error" { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}


# --- Second family: byte-identical (modulo formatting) across every script
# that had its own copy -- centralized here in 2026-07. Unlike the helpers
# above, these have no per-script *behavioral* differences, so there is no
# risk of silently changing what a script does by switching it to the
# shared version.
#
# Invoke-FabricWebRequestCore (below) absorbs each script's own
# $RetryCount/$RequestDelayMilliseconds/$FabricApiBaseUrl/$AzCommand as real
# parameters (with the same defaults every script already used) instead of
# reading them implicitly off the caller's scope -- module functions don't
# see a calling script's unqualified variables, only the script scope they
# were themselves defined in. Each script keeps a 3-line local
# Invoke-FabricWebRequest wrapper that forwards its own script-scope
# parameters into the Core call, so none of the ~18 existing call sites
# needed to change.

# A module-scope cache so a long-running script gets automatic token
# refresh for free just by switching to this function, instead of needing
# its own Update-TokenIfStale copy-pasted in (a single token fetched once
# at the top of a multi-hour run expires partway through and silently
# corrupts output with "401 TokenExpired" failures). Keyed by resource so a
# script pulling both a Fabric token and a SQL/Power BI token tracks their
# freshness independently.
$script:AzureCliTokenCache = @{}

function Get-AzureCliToken {
    param(
        [string]$Resource = "https://api.fabric.microsoft.com",
        [string]$AzCommand = "az",
        # Only Get-FreshAzureCliToken (below) needs a cache-bypassing fetch;
        # plain callers just want "a valid token", cached or not.
        [switch]$NoCache
    )

    # A signed-in web-app user's own delegated token, if the process that
    # spawned this script set one (see FABRIC_LINEAGE_USER_TOKEN in
    # lineage_web_server.py) -- falls back to the shared `az` CLI session
    # below when run standalone from a terminal, exactly as before. User
    # tokens are refreshed by the web server itself (not this cache), so
    # this path always returns the env var verbatim.
    if ($env:FABRIC_LINEAGE_USER_TOKEN -and $Resource -eq "https://api.fabric.microsoft.com") {
        return $env:FABRIC_LINEAGE_USER_TOKEN
    }
    if ($env:FABRIC_LINEAGE_USER_SQL_TOKEN -and $Resource -ne "https://api.fabric.microsoft.com") {
        return $env:FABRIC_LINEAGE_USER_SQL_TOKEN
    }

    if (-not $NoCache -and $script:AzureCliTokenCache.ContainsKey($Resource)) {
        return $script:AzureCliTokenCache[$Resource].Token
    }

    try {
        $azPath = (Get-Command $AzCommand -ErrorAction Stop).Source
    }
    catch {
        throw "Azure CLI command '$AzCommand' was not found."
    }

    $tokenOutput = & $azPath account get-access-token `
        --resource $Resource `
        --query "accessToken" `
        -o tsv 2>&1

    if ($LASTEXITCODE -ne 0) {
        $tokenError = (($tokenOutput | Out-String) -replace "\s+", " ").Trim()
        throw "Azure CLI token acquisition failed: $tokenError"
    }

    $token = ($tokenOutput | Out-String).Trim()
    if (-not $token) {
        throw "Azure CLI returned an empty access token for resource '$Resource'."
    }

    $script:AzureCliTokenCache[$Resource] = @{ Token = $token; AcquiredAt = Get-Date }
    return $token
}

# Call this instead of Get-AzureCliToken at the top of any loop that makes
# API calls in a script expected to run more than ~20-30 minutes. Cheap: a
# cache hit is a hashtable lookup, and even a real re-fetch just re-mints an
# access token from the CLI's already-cached refresh token, not a fresh
# interactive sign-in.
function Get-FreshAzureCliToken {
    param(
        [string]$Resource = "https://api.fabric.microsoft.com",
        [string]$AzCommand = "az",
        [int]$MaxAgeMinutes = 20
    )

    $cached = $script:AzureCliTokenCache[$Resource]
    if ($cached -and ((Get-Date) - $cached.AcquiredAt).TotalMinutes -lt $MaxAgeMinutes) {
        return $cached.Token
    }
    return (Get-AzureCliToken -Resource $Resource -AzCommand $AzCommand -NoCache)
}

function Get-HeaderValue {
    param(
        [object]$Headers,
        [string]$Name
    )

    if ($null -eq $Headers) {
        return ""
    }

    foreach ($key in $Headers.Keys) {
        if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return (($Headers[$key] | Select-Object -First 1) | Out-String).Trim()
        }
    }

    return ""
}

function Convert-JsonContent {
    param([string]$Content)

    if (-not $Content) {
        return $null
    }

    try {
        return $Content | ConvertFrom-Json -Depth 100
    }
    catch {
        return $null
    }
}

function Resolve-FabricUri {
    param(
        [string]$Path,
        [string]$BaseUrl = "https://api.fabric.microsoft.com/v1"
    )

    if ($Path.StartsWith("http")) {
        return $Path
    }

    return "$($BaseUrl.TrimEnd('/'))/$($Path.TrimStart('/'))"
}

# The one choke point every Fabric REST call in every script passes through
# -- so it's also the one place a reactive token refresh can fix ALL of
# them at once. A tenant-wide run with only the proactive
# every-20-minutes refresh (Get-FreshAzureCliToken, called at the top of
# each item's loop iteration) can STILL log "401 TokenExpired" on a large
# share of items -- a tenant's real token lifetime can be shorter than
# the 20-minute check assumes, so a large fraction of each window runs on
# an already-expired token. Reacting to the actual 401
# instead of guessing the right interval is correct regardless of the true
# lifetime. $Headers is a hashtable (reference type), so mutating
# $Headers["Authorization"] here also updates the caller's own header
# variable for every subsequent call it makes -- one fix, not just one
# retry.
function Invoke-FabricWebRequestCore {
    param(
        [ValidateSet("Get", "Post")]
        [string]$Method,
        [string]$Path,
        [hashtable]$Headers,
        [string]$BaseUrl = "https://api.fabric.microsoft.com/v1",
        [int]$RetryCount = 5,
        [int]$RequestDelayMilliseconds = 250,
        [string]$AzCommand = "az",
        # Every existing POST caller in this project is "trigger an LRO,
        # empty body" (getDefinition and friends) -- "" stays the default so
        # none of them need to change. The governance scan script (2026-08)
        # is the first caller that needs a real JSON body (the workspace id
        # list for the Scanner API's PostWorkspaceInfo).
        [string]$Body = "",
        # The reactive 401 refresh below used to always re-mint a
        # api.fabric.microsoft.com token regardless of $BaseUrl -- harmless
        # while every caller targeted that same host, but wrong for the
        # governance scan script's Power BI Admin API calls (BaseUrl
        # api.powerbi.com, token audience analysis.windows.net/powerbi/api
        # -- NOT the same string as the host). Defaults preserve every
        # existing caller's behavior unchanged.
        [string]$TokenResource = "https://api.fabric.microsoft.com"
    )

    $uri = Resolve-FabricUri -Path $Path -BaseUrl $BaseUrl

    for ($attempt = 0; $attempt -le $RetryCount; $attempt++) {
        try {
            $requestParams = @{
                Method = $Method
                Uri = $uri
                Headers = $Headers
                SkipHttpErrorCheck = $true
            }

            if ($Method -eq "Post") {
                $requestParams["ContentType"] = "application/json"
                $requestParams["Body"] = $Body
            }

            $response = Invoke-WebRequest @requestParams
            $statusCode = [int]$response.StatusCode

            if ($statusCode -eq 401 -and $attempt -lt $RetryCount -and [string]$response.Content -match '(?i)TokenExpired|Access token has expired') {
                $freshToken = Get-FreshAzureCliToken -Resource $TokenResource -AzCommand $AzCommand -MaxAgeMinutes 0
                $Headers["Authorization"] = "Bearer $freshToken"
                continue
            }

            if (($statusCode -eq 429 -or $statusCode -eq 503 -or $statusCode -eq 504) -and $attempt -lt $RetryCount) {
                $retryAfter = Get-HeaderValue -Headers $response.Headers -Name "Retry-After"
                $delaySeconds = if ($retryAfter -match "^\d+$") {
                    [int]$retryAfter
                }
                else {
                    [math]::Min(90, [math]::Pow(2, $attempt + 1))
                }

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
                Start-Sleep -Seconds ([math]::Min(90, [math]::Pow(2, $attempt + 1)))
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

Export-ModuleMember -Function Ensure-ParentDirectory, Write-Log, Get-AzureCliToken, Get-FreshAzureCliToken, Get-HeaderValue, Convert-JsonContent, Resolve-FabricUri, Invoke-FabricWebRequestCore
