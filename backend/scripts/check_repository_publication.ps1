# Utility - Repository publication safety check: before making this repo
# public or sharing it, scans every tracked-or-trackable file for patterns
# that should never leave the local machine (secrets/env files, generated
# analysis/CSV output, downloaded Fabric data, conversation logs) and
# reports what would need to stay git-ignored. Purely local, read-only.
param(
    [string]$Root = ".",
    [switch]$SummaryOnly
)

$ErrorActionPreference = "Stop"
$rootPath = (Resolve-Path $Root).Path
$patterns = @(
    @{ Name = "Secrets/env"; Regex = '(^|[\\/])(\.env(\..*)?|.*\.(pem|pfx|p12|key|crt|cer)|secrets?|credentials?|tokens?|auth)([\\/]|$)' },
    @{ Name = "Generated analysis"; Regex = '(^|[\\/])analysis[\\/]' },
    @{ Name = "Run logs"; Regex = '(^|[\\/])runs[\\/]' },
    @{ Name = "Downloaded definitions/data"; Regex = '(^|[\\/])data[\\/]' },
    @{ Name = "Fabric exports/temp"; Regex = '(^|[\\/])(_fabric_exports|\.tmp)[\\/]' },
    @{ Name = "Explorer generated data"; Regex = '(^|[\\/])(frontend|archive)[\\/][^\\/]+[\\/]data[\\/]' },
    @{ Name = "Standalone bundles"; Regex = '(^|[\\/])(frontend|archive)[\\/][^\\/]+[\\/]standalone\.html$' },
    @{ Name = "Conversations"; Regex = '(^|[\\/])docs[\\/]conversations[\\/]' },
    @{ Name = "Operational docs"; Regex = '(^|[\\/])docs[\\/](00_work_log|[1-9][0-9]_|probe_).*\.md$' },
    @{ Name = "Investigation scripts"; Regex = '(^|[\\/])docs[\\/]investigations[\\/]' },
    @{ Name = "Private indexes"; Regex = '(^|[\\/])index[\\/].*\.(csv|md)$' },
    @{ Name = "Generated graph/diagrams"; Regex = '(^|[\\/])(graph[\\/].*\.csv|diagrams[\\/].*\.mmd)$' },
    @{ Name = "Private CSV config"; Regex = '(^|[\\/])config[\\/](?!.*\.example\.csv$).*\.csv$' }
)

$files = Get-ChildItem -Path $rootPath -Recurse -File -Force |
    Where-Object {
        $_.FullName -notmatch '[\\/]\.git[\\/]' -and
        $_.FullName -notmatch '[\\/]node_modules[\\/]'
    }

$matches = foreach ($file in $files) {
    $relative = [System.IO.Path]::GetRelativePath($rootPath, $file.FullName).Replace("\", "/")
    if (
        $relative -eq ".env.example" -or
        $relative.EndsWith("/.gitkeep") -or
        $relative -like "*.example.csv"
    ) {
        continue
    }
    foreach ($pattern in $patterns) {
        if ($relative -match $pattern.Regex) {
            [pscustomobject]@{
                Category = $pattern.Name
                Path = $relative
            }
            break
        }
    }
}

if (-not $matches) {
    Write-Host "No private/generated publication candidates found in the current tree."
    exit 0
}

if ($SummaryOnly) {
    $matches |
        Group-Object Category |
        Sort-Object Name |
        Select-Object @{ Name = "Category"; Expression = { $_.Name } }, Count |
        Format-Table -AutoSize
} else {
    $matches |
        Sort-Object Category, Path |
        Format-Table -AutoSize
}

Write-Host ""
Write-Host "These files are expected to remain local and should be excluded by .gitignore/.dockerignore."
Write-Host "If this is already a Git repository, run git status and remove tracked private files with git rm --cached."
