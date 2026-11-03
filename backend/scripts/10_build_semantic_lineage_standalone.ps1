# Phase 10 - Standalone HTML build: inlines the web explorer's HTML/CSS/JS
# and JSON data files into one self-contained HTML file that works without
# a running web server (e.g. to email or drop on a share). Purely local
# file concatenation, no API calls.
# Reads: $IndexPath/$StylesPath/$ScriptPath/$DataPath/$ImpactDataPath/
# $NotebookSuperLineageDataPath. Writes: $OutputPath.
param(
    [string]$IndexPath = (Join-Path $PSScriptRoot "../../frontend/semantic-lineage/index.html"),
    [string]$StylesPath = (Join-Path $PSScriptRoot "../../frontend/semantic-lineage/styles.css"),
    [string]$ScriptPath = (Join-Path $PSScriptRoot "../../frontend/semantic-lineage/app.js"),
    [string]$DataPath = (Join-Path $PSScriptRoot "../../frontend/semantic-lineage/data/lineage-explorer.json"),
    [string]$ImpactDataPath = (Join-Path $PSScriptRoot "../../frontend/semantic-lineage/data/object-impact.json"),
    [string]$NotebookSuperLineageDataPath = (Join-Path $PSScriptRoot "../../frontend/semantic-lineage/data/notebook-super-lineage.json"),
    [string]$OutputPath = (Join-Path $PSScriptRoot "../../frontend/semantic-lineage/standalone.html")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

foreach ($path in @($IndexPath, $StylesPath, $ScriptPath, $DataPath, $ImpactDataPath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$html = Get-Content -Path $IndexPath -Raw
$css = Get-Content -Path $StylesPath -Raw
$js = Get-Content -Path $ScriptPath -Raw
$json = Get-Content -Path $DataPath -Raw
$impactJson = Get-Content -Path $ImpactDataPath -Raw
$notebookSuperLineageJson = if (Test-Path $NotebookSuperLineageDataPath) { Get-Content -Path $NotebookSuperLineageDataPath -Raw } else { "null" }

$safeCss = $css -replace "</style", "<\/style"
$safeJs = $js -replace "</script", "<\/script"
$safeJson = $json -replace "</script", "<\/script"
$safeImpactJson = $impactJson -replace "</script", "<\/script"
$safeNotebookSuperLineageJson = $notebookSuperLineageJson -replace "</script", "<\/script"

$html = [regex]::Replace(
    $html,
    '<link rel="stylesheet" href="\./styles\.css[^"]*" />',
    "<style>`n$safeCss`n</style>"
)

$embeddedScript = @"
<script>
window.LINEAGE_EXPLORER_DATA = $safeJson;
window.SEMANTIC_LINEAGE_DATA = window.LINEAGE_EXPLORER_DATA;
window.OBJECT_IMPACT_DATA = $safeImpactJson;
window.NOTEBOOK_SUPER_LINEAGE_DATA = $safeNotebookSuperLineageJson;
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
Write-Host "Standalone lineage explorer file built: $OutputPath"
