# Phase 36 - Standalone HTML build for the same superseded
# archive/lineage-explorer/ frontend Phase 35 builds (see that script's
# header) -- not the actively-served frontend/semantic-lineage/ explorer.
# Reads: $IndexPath/$StylesPath/$ScriptPath/$DataPath. Writes: $OutputPath.
param(
    [string]$IndexPath = (Join-Path $PSScriptRoot "../../archive/lineage-explorer/index.html"),
    [string]$StylesPath = (Join-Path $PSScriptRoot "../../archive/lineage-explorer/styles.css"),
    [string]$ScriptPath = (Join-Path $PSScriptRoot "../../archive/lineage-explorer/app.js"),
    [string]$DataPath = (Join-Path $PSScriptRoot "../../archive/lineage-explorer/data/lineage-explorer.json"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "../../archive/lineage-explorer/standalone.html")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

foreach ($path in @($IndexPath, $StylesPath, $ScriptPath, $DataPath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$html = Get-Content -Path $IndexPath -Raw
$css = Get-Content -Path $StylesPath -Raw
$js = Get-Content -Path $ScriptPath -Raw
$json = Get-Content -Path $DataPath -Raw

$safeCss = $css -replace "</style", "<\/style"
$safeJs = $js -replace "</script", "<\/script"
$safeJson = $json -replace "</script", "<\/script"

$html = [regex]::Replace(
    $html,
    '<link rel="stylesheet" href="\./styles\.css[^"]*" />',
    "<style>`n$safeCss`n</style>"
)

$embeddedScript = @"
<script>
window.LINEAGE_MULTI_CRITERIA_DATA = $safeJson;
</script>
<script>
$safeJs
</script>
"@

$html = [regex]::Replace(
    $html,
    '<script src="\./app\.js[^"]*"></script>',
    [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $embeddedScript }
)

$parent = Split-Path -Parent $OutputPath
if ($parent -and -not (Test-Path $parent)) {
    New-Item -ItemType Directory -Path $parent | Out-Null
}

Set-Content -Path $OutputPath -Value $html -Encoding UTF8
Write-Host "Standalone multi-criteria lineage explorer built: $OutputPath"
