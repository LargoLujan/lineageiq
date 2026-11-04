# Phase 1 - Workspace discovery: lists every Fabric workspace the
# authenticated identity (fab CLI or az CLI/user token) can see and writes
# one normalized row per workspace. Read-only -- queries Fabric only, never
# modifies anything.
# Writes: $OutputPath (workspace_name, capacity, region, etc.).
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$DiscoveryLayersPath = (Join-Path $PSScriptRoot "../../index/discovery_layers.csv"),
    [string]$UnresolvedPath = (Join-Path $PSScriptRoot "../../index/unresolved.md"),
    [ValidateSet("auto", "fabric-cli", "azure-cli")]
    [string]$AuthMethod = "auto",
    [string]$FabCommand = "fab",
    [string]$AzCommand = "az",
    [string]$FabricApiBaseUrl = "https://api.fabric.microsoft.com/v1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

# Read-only discovery. This script queries Fabric workspaces and writes local CSV evidence only.
$workspaceColumns = @(
    "workspace_name",
    "capacity_name",
    "domain_name",
    "owner",
    "source_system",
    "technical_id",
    "status",
    "notes"
)

$layerColumns = @(
    "layer_name",
    "scope_name",
    "source_system",
    "status",
    "evidence",
    "notes"
)

function Get-FieldValue {
    param(
        [object]$Object,
        [string[]]$Names
    )

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

function Write-CsvRows {
    param(
        [string]$Path,
        [object[]]$Rows,
        [string[]]$Columns
    )

    Ensure-ParentDirectory -Path $Path

    if ($Rows.Count -eq 0) {
        ($Columns -join ",") | Set-Content -Path $Path -Encoding UTF8
        return
    }

    $Rows |
        Select-Object -Property $Columns |
        Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

function Upsert-DiscoveryLayer {
    param(
        [string]$SourceSystem,
        [string]$Status,
        [string]$Evidence,
        [string]$Notes
    )

    Ensure-ParentDirectory -Path $DiscoveryLayersPath

    $existingRows = @()
    if (Test-Path $DiscoveryLayersPath) {
        $existingRows = @(Import-Csv -Path $DiscoveryLayersPath)
    }

    $existingRows = @(
        $existingRows |
            Where-Object {
                $_.layer_name -ne "Fabric workspaces" -or
                $_.scope_name -ne "Tenant accessible workspaces"
            }
    )

    $existingRows += [pscustomobject]@{
        layer_name = "Fabric workspaces"
        scope_name = "Tenant accessible workspaces"
        source_system = $SourceSystem
        status = $Status
        evidence = $Evidence
        notes = $Notes
    }

    Write-CsvRows -Path $DiscoveryLayersPath -Rows $existingRows -Columns $layerColumns
}

function Add-UnresolvedItem {
    param(
        [string]$Title,
        [string]$Status,
        [string]$Evidence,
        [string]$NextStep
    )

    Ensure-ParentDirectory -Path $UnresolvedPath

    if (-not (Test-Path $UnresolvedPath)) {
        "# Unresolved Items`n`n## Open Questions`n" |
            Set-Content -Path $UnresolvedPath -Encoding UTF8
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
        $updated = [regex]::Replace($current, $pattern, $entry)
        Set-Content -Path $UnresolvedPath -Value $updated -Encoding UTF8
        return
    }

    Add-Content -Path $UnresolvedPath -Value $entry -Encoding UTF8
}

function Get-FabricApiErrorSummary {
    param([string]$ApiText)

    try {
        $errorPayload = $ApiText | ConvertFrom-Json
        $errorCode = Get-FieldValue -Object $errorPayload.result -Names @("error_code", "code")
        $errorMessage = Get-FieldValue -Object $errorPayload.result -Names @("message")

        if ($errorCode -or $errorMessage) {
            return ("$errorCode`: $errorMessage").Trim(": ")
        }
    }
    catch {
        # Fall through to plain text normalization.
    }

    return (($ApiText -replace "\s+", " ").Trim())
}

function Stop-WithDiscoveryBlocker {
    param(
        [string]$SourceSystem,
        [string]$Status,
        [string]$Evidence,
        [string]$Notes,
        [string]$NextStep
    )

    Upsert-DiscoveryLayer `
        -SourceSystem $SourceSystem `
        -Status $Status `
        -Evidence $Evidence `
        -Notes $Notes
    Add-UnresolvedItem `
        -Title "Phase 1 workspace discovery blocked" `
        -Status $Status `
        -Evidence $Evidence `
        -NextStep $NextStep

    Write-Host "Phase 1 workspace discovery did not run to completion."
    Write-Host $Notes
    exit 3
}

function Invoke-FabricCliWorkspaceDiscovery {
    try {
        $fabPath = (Get-Command $FabCommand -ErrorAction Stop).Source
    }
    catch {
        return [pscustomobject]@{
            succeeded = $false
            source_system = "Fabric CLI API"
            evidence = "$FabCommand not found in PATH"
            notes = "Fabric CLI is not available in the active runtime."
            payload = $null
        }
    }

    $statusOutput = & $fabPath auth status 2>&1
    $statusText = ($statusOutput | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $statusText -notmatch "Logged In:\s*True") {
        return [pscustomobject]@{
            succeeded = $false
            source_system = "Fabric CLI API"
            evidence = "fab auth status did not show an active login"
            notes = "Fabric CLI is available but no non-interactive Fabric token is active in this runtime."
            payload = $null
        }
    }

    $apiOutput = & $fabPath api -X get workspaces --output_format json 2>&1
    $apiExitCode = $LASTEXITCODE
    $apiText = ($apiOutput | Out-String).Trim()

    if ($apiExitCode -ne 0) {
        $errorSummary = Get-FabricApiErrorSummary -ApiText $apiText
        return [pscustomobject]@{
            succeeded = $false
            source_system = "Fabric CLI API"
            evidence = "fab api -X get workspaces failed: $errorSummary"
            notes = "Fabric CLI is available but the active runtime does not have a valid Fabric token."
            payload = $null
        }
    }

    try {
        $envelope = $apiText | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{
            succeeded = $false
            source_system = "Fabric CLI API"
            evidence = "Fabric CLI returned non-JSON workspace output."
            notes = "The workspace response could not be parsed safely."
            payload = $null
        }
    }

    # `fab api -X get ... --output_format json` wraps the real REST
    # response several levels deep: {result: {data: [{status_code, text:
    # {value: [...]}}]}} -- NOT a bare {value: [...]} the way the plain
    # Azure CLI bearer-token call below returns it. Passing $envelope
    # through as-is (what this function did before) meant $envelope had
    # neither a .value property nor was itself an array, so the caller's
    # own fallback silently treated the single wrapper OBJECT as "one
    # workspace" with no displayName/id -- producing exactly one garbage
    # "Unknown workspace" row. Found the hard way: `fab`
    # turned out to have a real, valid cached login on this machine (no
    # previous run had ever exercised this path, since it always failed
    # the auth-status check before), and this silently wiped
    # index/workspaces.csv down to that single fake row.
    $firstResult = $null
    if ($envelope.PSObject.Properties.Name -contains "result" -and $envelope.result.PSObject.Properties.Name -contains "data") {
        $firstResult = @($envelope.result.data) | Select-Object -First 1
    }
    if (-not $firstResult -or $firstResult.status_code -ne 200 -or -not $firstResult.text -or -not ($firstResult.text.PSObject.Properties.Name -contains "value")) {
        return [pscustomobject]@{
            succeeded = $false
            source_system = "Fabric CLI API"
            evidence = "fab api -X get workspaces returned an unexpected response shape (expected result.data[0].text.value)."
            notes = "Fabric CLI's own wrapper envelope didn't contain a real workspace list -- falling back to the Azure CLI bearer-token path instead of trusting a single placeholder row."
            payload = $null
        }
    }

    return [pscustomobject]@{
        succeeded = $true
        source_system = "Fabric CLI API"
        evidence = "fab api -X get workspaces"
        notes = "Workspace discovery completed through Fabric CLI."
        payload = $firstResult.text
    }
}

function Invoke-FabricAdminWorkspaceDiscovery {
    # Tried first: a genuine Fabric tenant admin (Entra ID "Fabric
    # Administrator" role) can list literally every workspace in the
    # tenant via the admin API, regardless of per-workspace role. Without
    # this, an admin's full scan only ever discovered the workspaces they
    # personally hold a role in (via
    # the regular /workspaces endpoint in Invoke-AzureCliWorkspaceDiscovery
    # below), never the full tenant their admin-scoped session had already
    # proven it could see (via the web server's own separate check at
    # scan-start time -- see _fetch_all_tenant_workspaces in lineage_web/
    # fabric_api.py, which computes -WorkspaceNameFilter but never reaches
    # this script, since workspace discovery has no filter to apply yet).
    # Same token resolution as Invoke-AzureCliWorkspaceDiscovery (env var
    # from a signed-in web app user first, `az` CLI session otherwise) --
    # a 403 here (everyone who isn't a tenant admin, i.e. almost everyone,
    # including every plain terminal `az login` session) falls straight
    # through to that existing function, unchanged for them.
    if ($env:FABRIC_LINEAGE_USER_TOKEN) {
        $accessToken = $env:FABRIC_LINEAGE_USER_TOKEN
        $tokenExitCode = 0
    }
    else {
        try {
            $azPath = (Get-Command $AzCommand -ErrorAction Stop).Source
        }
        catch {
            return [pscustomobject]@{
                succeeded = $false
                source_system = "Fabric Admin REST API"
                evidence = "$AzCommand not found in PATH"
                notes = "Azure CLI is not available in the active runtime."
                payload = $null
            }
        }

        $tokenOutput = & $azPath account get-access-token `
            --resource "https://api.fabric.microsoft.com" `
            --query "accessToken" `
            -o tsv 2>&1
        $tokenExitCode = $LASTEXITCODE
        $accessToken = ($tokenOutput | Out-String).Trim()
    }

    if ($tokenExitCode -ne 0 -or -not $accessToken) {
        return [pscustomobject]@{
            succeeded = $false
            source_system = "Fabric Admin REST API"
            evidence = "Could not acquire a Fabric access token."
            notes = ""
            payload = $null
        }
    }

    try {
        $headers = @{
            Authorization = "Bearer $accessToken"
            "Content-Type" = "application/json"
        }
        # type=Workspace excludes every user's PersonalGroup ("My
        # workspace"); state=Active excludes Orphaned/Deleted/Removing --
        # both filtered server-side so nothing downstream has to.
        $allWorkspaces = [System.Collections.Generic.List[object]]::new()
        $continuationToken = $null
        do {
            $uri = "$($FabricApiBaseUrl.TrimEnd('/'))/admin/workspaces?type=Workspace&state=Active"
            if ($continuationToken) {
                $uri += "&continuationToken=$([Uri]::EscapeDataString($continuationToken))"
            }
            $page = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
            foreach ($workspace in @($page.workspaces)) {
                $allWorkspaces.Add($workspace) | Out-Null
            }
            $continuationToken = $page.continuationToken
        } while ($continuationToken)

        return [pscustomobject]@{
            succeeded = $true
            source_system = "Fabric Admin REST API via Azure CLI"
            evidence = "GET $($FabricApiBaseUrl.TrimEnd('/'))/admin/workspaces (paginated, type=Workspace&state=Active)"
            notes = "Tenant-wide workspace discovery via the Fabric Administrator admin API -- covers every workspace in the tenant, not just ones this identity has a direct role in."
            # Reshaped to {value: [...]} so it flows through the exact same
            # $workspaces/$rows construction below as every other discovery
            # path -- Get-FieldValue already accepts both the admin
            # response's field names (name/id) and the regular endpoint's
            # (displayName/workspaceId), so no separate mapping is needed.
            payload = [pscustomobject]@{ value = $allWorkspaces.ToArray() }
        }
    }
    catch {
        return [pscustomobject]@{
            succeeded = $false
            source_system = "Fabric Admin REST API via Azure CLI"
            evidence = "GET $($FabricApiBaseUrl.TrimEnd('/'))/admin/workspaces failed: $($_.Exception.Message)"
            notes = "Not a Fabric tenant admin, or the admin API call failed for another reason -- falling back to the regular per-identity workspace list."
            payload = $null
        }
    }
}

function Invoke-AzureCliWorkspaceDiscovery {
    # A signed-in web-app user's own delegated token, if the process that
    # spawned this script set one (see FABRIC_LINEAGE_USER_TOKEN in
    # lineage_web_server.py) -- skips the `az` shell-out entirely and falls
    # back to it when run standalone from a terminal, exactly as before.
    if ($env:FABRIC_LINEAGE_USER_TOKEN) {
        $accessToken = $env:FABRIC_LINEAGE_USER_TOKEN
        $tokenExitCode = 0
    }
    else {
        try {
            $azPath = (Get-Command $AzCommand -ErrorAction Stop).Source
        }
        catch {
            return [pscustomobject]@{
                succeeded = $false
                source_system = "Fabric REST API via Azure CLI"
                evidence = "$AzCommand not found in PATH"
                notes = "Azure CLI is not available in the active runtime."
                payload = $null
            }
        }

        $tokenOutput = & $azPath account get-access-token `
            --resource "https://api.fabric.microsoft.com" `
            --query "accessToken" `
            -o tsv 2>&1
        $tokenExitCode = $LASTEXITCODE
        $accessToken = ($tokenOutput | Out-String).Trim()
    }

    if ($tokenExitCode -ne 0 -or -not $accessToken) {
        $tokenError = (($tokenOutput | Out-String) -replace "\s+", " ").Trim()
        return [pscustomobject]@{
            succeeded = $false
            source_system = "Fabric REST API via Azure CLI"
            evidence = "az account get-access-token --resource https://api.fabric.microsoft.com failed: $tokenError"
            notes = "Azure CLI is available but is not authenticated for Fabric REST token acquisition."
            payload = $null
        }
    }

    try {
        $headers = @{
            Authorization = "Bearer $accessToken"
            "Content-Type" = "application/json"
        }
        $uri = "$($FabricApiBaseUrl.TrimEnd('/'))/workspaces"
        $payload = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers

        return [pscustomobject]@{
            succeeded = $true
            source_system = "Fabric REST API via Azure CLI"
            evidence = "az account get-access-token --resource https://api.fabric.microsoft.com; GET $uri"
            notes = "Workspace discovery completed through Fabric REST using an Azure CLI bearer token."
            payload = $payload
        }
    }
    catch {
        return [pscustomobject]@{
            succeeded = $false
            source_system = "Fabric REST API via Azure CLI"
            evidence = "GET $($FabricApiBaseUrl.TrimEnd('/'))/workspaces failed: $($_.Exception.Message)"
            notes = "Azure CLI returned a token but Fabric REST workspace discovery failed."
            payload = $null
        }
    }
}

$attempts = @()

# Tried before anything else: a tenant admin gets literally every
# workspace this way, a superset of what either path below could ever
# return for them. Everyone else (a 403) falls straight through.
if ($AuthMethod -in @("auto", "azure-cli")) {
    $attempts += Invoke-FabricAdminWorkspaceDiscovery
}

if (($attempts.Count -eq 0 -or -not $attempts[-1].succeeded) -and $AuthMethod -in @("auto", "fabric-cli")) {
    $attempts += Invoke-FabricCliWorkspaceDiscovery
}

if ($AuthMethod -in @("auto", "azure-cli") -and ($attempts.Count -eq 0 -or -not $attempts[-1].succeeded)) {
    $attempts += Invoke-AzureCliWorkspaceDiscovery
}

$successfulAttempt = @($attempts | Where-Object { $_.succeeded } | Select-Object -First 1)

if ($successfulAttempt.Count -eq 0) {
    $evidence = (($attempts | ForEach-Object { $_.evidence }) -join "; ")
    $notes = (($attempts | ForEach-Object { $_.notes } | Select-Object -Unique) -join " ")

    Stop-WithDiscoveryBlocker `
        -SourceSystem "Fabric discovery authentication" `
        -Status "blocked" `
        -Evidence $evidence `
        -Notes $notes `
        -NextStep "Run az login --use-device-code --tenant <your-tenant-id> --allow-no-subscriptions, then rerun backend/scripts/01_discover_workspaces.ps1. If a service principal is approved later, use fab auth login -u <client_id> -p <secret> --tenant <tenant_id>."
}

$payload = $successfulAttempt[0].payload
$sourceSystem = $successfulAttempt[0].source_system
$evidenceText = $successfulAttempt[0].evidence
$sourceNotes = $successfulAttempt[0].notes

$workspaces = @()
if ($payload.PSObject.Properties.Name -contains "value") {
    $workspaces = @($payload.value)
}
elseif ($payload -is [array]) {
    $workspaces = @($payload)
}
else {
    $workspaces = @($payload)
}

$rows = @(
    $workspaces |
        ForEach-Object {
            $workspaceName = Get-FieldValue -Object $_ -Names @("displayName", "name")
            $technicalId = Get-FieldValue -Object $_ -Names @("id", "workspaceId")
            $capacityName = Get-FieldValue -Object $_ -Names @("capacityName", "capacityDisplayName")
            $capacityId = Get-FieldValue -Object $_ -Names @("capacityId")
            $domainName = Get-FieldValue -Object $_ -Names @("domainName", "domain")
            $workspaceType = Get-FieldValue -Object $_ -Names @("type")

            if (-not $workspaceName) {
                $workspaceName = "Unknown workspace $technicalId".Trim()
            }

            $notes = @()
            if ($workspaceType) {
                $notes += "Type: $workspaceType"
            }
            if ($capacityId -and -not $capacityName) {
                $notes += "Capacity ID captured; capacity name not returned by workspaces endpoint."
            }

            [pscustomobject]@{
                workspace_name = $workspaceName
                capacity_name = $capacityName
                domain_name = $domainName
                owner = ""
                source_system = $sourceSystem
                technical_id = $technicalId
                status = "discovered"
                notes = ($notes -join " ")
            }
        } |
        Sort-Object -Property workspace_name
)

# This script's whole job is "list every workspace the calling identity can
# see" -- there is no -WorkspaceNameFilter to scope it the way most other
# scan steps support, because the accessible set IS what it's discovering.
# When that identity is a signed-in user's own delegated token
# (FABRIC_LINEAGE_USER_TOKEN, set by lineage_web_server.py -- see
# docs/102_admin_panel_and_user_auth.md) rather than the shared, typically
# tenant-wide `az` CLI session, $rows above only reflects what THAT PERSON
# can see -- writing it out as-is would silently delete every other
# workspace nobody else's session happens to be scanning right now, which
# is exactly the "don't touch what I can't see" invariant the federated
# scanning model depends on (deliberately: several different non-admin
# people each scanning their own slice should be able to build up the full
# picture together, none of them deleting anyone else's contribution).
# Retain every previously known workspace this run didn't (re)discover;
# only ever add or refresh rows, never drop one just because this
# particular identity lacks access to it.
#
# EXCEPT when $sourceSystem shows the run came through the admin API
# (Invoke-FabricAdminWorkspaceDiscovery above, a genuine Fabric tenant
# admin) -- that result IS the full tenant ground truth already, not one
# person's partial slice, so a workspace missing from it really is gone
# (deleted/archived), and retaining it anyway would wrongly keep it alive
# forever. Skipping retention here is deliberately NOT the same thing as
# a general "merge" strategy -- see 16_discover_deployment_pipelines.ps1's
# own comment on why a plain retain-if-not-rediscovered merge was reverted
# there specifically (it can hide a real deletion indefinitely); this
# block only ever retains for a run that has already, structurally, no
# way to know about workspaces outside its own real access -- never as a
# generic "keep old data just in case" default.
$isAdminAuthoritative = $sourceSystem -eq "Fabric Admin REST API via Azure CLI"
if ($env:FABRIC_LINEAGE_USER_TOKEN -and -not $isAdminAuthoritative -and (Test-Path $OutputPath)) {
    $discoveredNames = @{}
    foreach ($row in $rows) { $discoveredNames[$row.workspace_name.Trim().ToLowerInvariant()] = $true }
    $retainedRows = @(
        Import-Csv -Path $OutputPath |
            Where-Object { -not $discoveredNames.ContainsKey($_.workspace_name.Trim().ToLowerInvariant()) }
    )
    $rows = @($rows) + $retainedRows
    Write-Host "Signed-in user scope: retained $($retainedRows.Count) previously known workspace(s) outside this identity's own access."
}
elseif ($isAdminAuthoritative) {
    Write-Host "Tenant admin scope: full replace, no retention (this result is the complete tenant picture)."
}

Write-CsvRows -Path $OutputPath -Rows ($rows | Sort-Object -Property workspace_name) -Columns $workspaceColumns
Upsert-DiscoveryLayer `
    -SourceSystem $sourceSystem `
    -Status "complete" `
    -Evidence $evidenceText `
    -Notes "$sourceNotes Discovered $($rows.Count) accessible Fabric workspaces."

Write-Host "Phase 1 workspace discovery completed."
Write-Host "Workspaces discovered: $($rows.Count)"
Write-Host "Output: $OutputPath"
