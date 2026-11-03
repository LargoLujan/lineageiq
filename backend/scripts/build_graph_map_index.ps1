# Graph Map Mode index: a thin PowerShell wrapper around
# backend/scripts/build_graph_map_index.py (see that file's own module
# docstring) -- combines index/items.csv + index/workspaces.csv +
# index/dependencies.csv + the just-rebuilt object-impact.json/
# lineage-explorer.json into graph-map-index.json/graph-map-index-
# objects.json. No -WorkspaceNameFilter: the underlying script takes no
# arguments and always rebuilds from whatever is currently on disk in
# those CSVs/JSON -- same reasoning as 05_build_graph.ps1/
# 11_build_lineage_explorer.ps1/21_build_reverse_impact_package.ps1, which
# is why this step is placed right after those in both
# 99_refresh_lineage_project.ps1 and scan_single_workspace.ps1 (it reads
# object-impact.json and lineage-explorer.json as input, so it must run
# after both are rebuilt, not before).
param(
    [string]$PythonCommand = "python3"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $PSScriptRoot "build_graph_map_index.py"
if (-not (Test-Path $scriptPath)) {
    throw "Required script not found: $scriptPath"
}

try {
    & $PythonCommand $scriptPath
}
catch {
    if ($PythonCommand -eq "python3") {
        & python $scriptPath
    }
    else {
        throw
    }
}

if ($LASTEXITCODE -ne 0) {
    throw "Graph Map index builder exited with code $LASTEXITCODE"
}
