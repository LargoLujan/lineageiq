# Phase 0 - Preflight: verifies the CLI tools this project depends on
# (az, fab, python, node, git, etc.) are installed and resolvable on PATH,
# and reports their detected paths/versions. Purely local and read-only --
# makes no authentication or network calls, so it's safe to run first,
# before any real scan, to catch a missing-tool problem early.
# Writes: $OutputPath (one row per tool: name, expected command, detected
# path, status, notes).
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot "../../index/tooling_inventory.csv"),
    # Optional local checkout of your own Fabric deployment tooling, used
    # only as a reference for REST/auth patterns (presence check only).
    # Override with -ReferenceProjectPath or FABRIC_LINEAGE_REFERENCE_PROJECT.
    [string]$ReferenceProjectPath = $(if ($env:FABRIC_LINEAGE_REFERENCE_PROJECT) { $env:FABRIC_LINEAGE_REFERENCE_PROJECT } else { "C:\path\to\your-deployment-tooling" }),
    # Optional local .env file holding secrets for live runs (presence check
    # only -- never read). Override with -SecretEnvPath or
    # FABRIC_LINEAGE_SECRET_ENV_FILE.
    [string]$SecretEnvPath = $(if ($env:FABRIC_LINEAGE_SECRET_ENV_FILE) { $env:FABRIC_LINEAGE_SECRET_ENV_FILE } else { "C:\path\to\secrets\lineageiq.local.env" })
)

# Local-only preflight.
# This script checks installed commands and known project paths.
# It does not authenticate and does not query external systems.

$rows = @()

function Add-ToolStatus {
    param(
        [string]$ToolName,
        [string]$ExpectedCommand,
        [string]$DetectedPath,
        [string]$Status,
        [string]$Notes
    )

    $script:rows += [pscustomobject]@{
        tool_name = $ToolName
        expected_command = $ExpectedCommand
        detected_path = $DetectedPath
        status = $Status
        notes = $Notes
    }
}

function Resolve-CommandPath {
    param([string]$CommandName)

    $pathValues = @(
        $env:Path,
        [Environment]::GetEnvironmentVariable("Path", "User"),
        [Environment]::GetEnvironmentVariable("Path", "Machine")
    ) -join ";"

    foreach ($dir in ($pathValues -split ";" | Where-Object { $_ })) {
        foreach ($extension in @("", ".exe", ".cmd", ".bat", ".ps1")) {
            $candidate = Join-Path $dir "$CommandName$extension"
            if (Test-Path $candidate) {
                return $candidate
            }
        }
    }

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        return ""
    }
    return $command.Source
}

$azPath = Resolve-CommandPath "az"
Add-ToolStatus `
    -ToolName "Azure CLI" `
    -ExpectedCommand "az" `
    -DetectedPath $azPath `
    -Status $(if ($azPath) { "found" } else { "missing" }) `
    -Notes "Required for Fabric REST, Azure DevOps Entra token, and OneLake storage token."

$fabPath = Resolve-CommandPath "fab"
Add-ToolStatus `
    -ToolName "Fabric CLI" `
    -ExpectedCommand "fab" `
    -DetectedPath $fabPath `
    -Status $(if ($fabPath) { "found" } else { "missing" }) `
    -Notes "Useful for Fabric CLI-specific operations. REST remains primary for discovery."

$fabricPath = Resolve-CommandPath "fabric"
Add-ToolStatus `
    -ToolName "Fabric CLI alternative command" `
    -ExpectedCommand "fabric" `
    -DetectedPath $fabricPath `
    -Status $(if ($fabricPath) { "found" } else { "missing" }) `
    -Notes "Some environments expose Fabric CLI as fabric instead of fab."

$pythonPath = Resolve-CommandPath "python"
Add-ToolStatus `
    -ToolName "Python" `
    -ExpectedCommand "python" `
    -DetectedPath $pythonPath `
    -Status $(if ($pythonPath) { "found" } else { "missing" }) `
    -Notes "Needed for future graph analysis with NetworkX if required."

$referenceProject = $ReferenceProjectPath
Add-ToolStatus `
    -ToolName "Existing Fabric reference project" `
    -ExpectedCommand $referenceProject `
    -DetectedPath $(if (Test-Path $referenceProject) { $referenceProject } else { "" }) `
    -Status $(if (Test-Path $referenceProject) { "found" } else { "missing" }) `
    -Notes "Optional: your own Fabric deployment tooling, used as reference code for Fabric REST, auth, inventory, semantic model, and SQL endpoint patterns."

$secretEnv = $SecretEnvPath
Add-ToolStatus `
    -ToolName "Local secret env reference" `
    -ExpectedCommand $secretEnv `
    -DetectedPath $(if (Test-Path $secretEnv) { $secretEnv } else { "" }) `
    -Status $(if (Test-Path $secretEnv) { "found_not_read" } else { "missing" }) `
    -Notes "Presence only. Values must not be printed or committed."

$rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "Tooling preflight completed."
Write-Host "Output: $OutputPath"
