# Phase 12 - Visual validation: serves the web explorer locally on $Port
# and drives it with Playwright to catch rendering regressions (console
# errors, broken panels) before trusting a rebuilt explorer.json. Requires
# Node/Playwright installed; -SkipNpmInstall assumes dependencies already
# exist (faster repeat runs).
# Writes: screenshots/report under $OutputDirectory.
param(
    [int]$Port = 8765,
    [switch]$SkipNpmInstall,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot "../../analysis/visual-validation")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Require-Command {
    param(
        [string]$Name,
        [string]$InstallHint
    )
    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "$Name is not available. $InstallHint"
    }
    return $command
}

function Ensure-Directory {
    param([string]$Path)
    if ($Path -and -not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

$node = Require-Command -Name "node" -InstallHint "Rebuild the project container after the Dockerfile update, or install Node.js in the active local runtime."
$npm = Require-Command -Name "npm" -InstallHint "Rebuild the project container after the Dockerfile update, or install npm in the active local runtime."

Ensure-Directory -Path $OutputDirectory

if (-not (Test-Path (Join-Path $PSScriptRoot "../../frontend/semantic-lineage/standalone.html"))) {
    throw "Standalone HTML not found. Run backend/scripts/10_build_semantic_lineage_standalone.ps1 first."
}

if (-not (Test-Path "node_modules/@playwright/test")) {
    if ($SkipNpmInstall) {
        throw "node_modules/@playwright/test is missing and -SkipNpmInstall was set."
    }
    Write-Host "Installing npm dependencies for visual validation..."
    & $npm.Source install
    if ($LASTEXITCODE -ne 0) {
        throw "npm install failed with exit code $LASTEXITCODE"
    }
}

$chromiumCandidates = @(@(
    $env:PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH,
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
    "/usr/bin/google-chrome"
) | Where-Object { $_ -and (Test-Path $_) })

if ($chromiumCandidates.Count -gt 0) {
    $env:PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH = $chromiumCandidates[0]
}
else {
    Write-Host "No system Chromium found. Playwright will use its managed browser if installed."
}

$env:LINEAGE_VISUAL_PORT = [string]$Port
$env:PLAYWRIGHT_JSON_OUTPUT_NAME = Join-Path $OutputDirectory "playwright-results.json"

Write-Host "Node: $(& $node.Source --version)"
Write-Host "npm: $(& $npm.Source --version)"
if ($env:PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH) {
    Write-Host "Chromium: $env:PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH"
}
Write-Host "Visual validation port: $Port"

& npx playwright test --config=playwright.config.js
if ($LASTEXITCODE -ne 0) {
    throw "Playwright visual validation failed with exit code $LASTEXITCODE"
}

Write-Host "Visual validation completed."
Write-Host "Output: $OutputDirectory"
