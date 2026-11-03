# Phase 5 - Graph build: assembles the tenant-wide dependency graph
# (nodes/edges CSVs + a Mermaid diagram) from workspaces/items/dependencies,
# and produces summary/validation reports (orphans, cycles, top-connected
# nodes). Purely local -- no Fabric API calls, just reads prior phases'
# CSVs and derives the graph.
# Reads: $WorkspacesPath/$ItemsPath/$ItemAnalysisPath/$DependenciesPath.
# Writes: $NodesPath/$EdgesPath, $DiagramPath, graph_summary/validation CSVs.
param(
    [string]$WorkspacesPath = (Join-Path $PSScriptRoot "../../index/workspaces.csv"),
    [string]$ItemsPath = (Join-Path $PSScriptRoot "../../index/items.csv"),
    [string]$ItemAnalysisPath = (Join-Path $PSScriptRoot "../../index/item_analysis.csv"),
    [string]$DependenciesPath = (Join-Path $PSScriptRoot "../../index/dependencies.csv"),
    [string]$NodesPath = (Join-Path $PSScriptRoot "../../graph/nodes.csv"),
    [string]$EdgesPath = (Join-Path $PSScriptRoot "../../graph/edges.csv"),
    [string]$DiagramPath = (Join-Path $PSScriptRoot "../../diagrams/current_dependency_map.mmd"),
    [string]$GraphSummaryPath = (Join-Path $PSScriptRoot "../../analysis/graph_summary.csv"),
    [string]$TopNodesPath = (Join-Path $PSScriptRoot "../../analysis/top_graph_nodes.csv"),
    [string]$ValidationPath = (Join-Path $PSScriptRoot "../../analysis/graph_validation.csv"),
    [string]$UnresolvedPath = (Join-Path $PSScriptRoot "../../index/unresolved.md"),
    [int]$MaxDiagramSources = 12,
    [int]$MaxDiagramExternalConnections = 8
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Import-Module (Join-Path $PSScriptRoot "common/LineageCommon.psm1") -Force -DisableNameChecking

$nodeColumns = @(
    "qualified_name",
    "display_name",
    "workspace_name",
    "item_type",
    "object_type",
    "source_system",
    "technical_id",
    "status",
    "notes"
)

$edgeColumns = @(
    "from_qualified_name",
    "to_qualified_name",
    "relationship_type",
    "source_system",
    "evidence",
    "confidence",
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
        [int]$MaxLength = 300
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

function Sanitize-MermaidId {
    param([string]$Value)

    $hashInput = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [System.Security.Cryptography.SHA1]::Create().ComputeHash($hashInput)
    $suffix = [System.BitConverter]::ToString($hash).Replace("-", "").Substring(0, 10).ToLowerInvariant()
    return "n$suffix"
}

function Escape-MermaidLabel {
    param([string]$Value)

    if (-not $Value) {
        return ""
    }

    return (Limit-Text -Text ($Value.Replace("\", "\\").Replace('"', "'")) -MaxLength 90)
}

function Add-Node {
    param(
        [hashtable]$NodeMap,
        [object]$Node
    )

    $qualifiedName = Get-FieldValue -Object $Node -Names @("qualified_name")
    if (-not $qualifiedName) {
        return
    }

    if (-not $NodeMap.ContainsKey($qualifiedName)) {
        $NodeMap[$qualifiedName] = [pscustomobject]@{
            qualified_name = $qualifiedName
            display_name = Get-FieldValue -Object $Node -Names @("display_name")
            workspace_name = Get-FieldValue -Object $Node -Names @("workspace_name")
            item_type = Get-FieldValue -Object $Node -Names @("item_type")
            object_type = Get-FieldValue -Object $Node -Names @("object_type")
            source_system = Get-FieldValue -Object $Node -Names @("source_system")
            technical_id = Get-FieldValue -Object $Node -Names @("technical_id")
            status = Get-FieldValue -Object $Node -Names @("status")
            notes = Limit-Text -Text (Get-FieldValue -Object $Node -Names @("notes")) -MaxLength 800
        }
    }
}

function Add-Edge {
    param(
        [hashtable]$EdgeMap,
        [object]$Edge
    )

    $from = Get-FieldValue -Object $Edge -Names @("from_qualified_name")
    $to = Get-FieldValue -Object $Edge -Names @("to_qualified_name")
    $relationshipType = Get-FieldValue -Object $Edge -Names @("relationship_type")

    if (-not $from -or -not $to -or -not $relationshipType) {
        return
    }

    $key = "$from|$to|$relationshipType"
    if (-not $EdgeMap.ContainsKey($key)) {
        $EdgeMap[$key] = [pscustomobject]@{
            from_qualified_name = $from
            to_qualified_name = $to
            relationship_type = $relationshipType
            source_system = Get-FieldValue -Object $Edge -Names @("source_system")
            evidence = Limit-Text -Text (Get-FieldValue -Object $Edge -Names @("evidence")) -MaxLength 800
            confidence = Get-FieldValue -Object $Edge -Names @("confidence")
            notes = Limit-Text -Text (Get-FieldValue -Object $Edge -Names @("notes")) -MaxLength 800
        }
    }
}

function New-MetricRow {
    param(
        [string]$Metric,
        [string]$Value,
        [string]$Notes = ""
    )

    return [pscustomobject]@{
        metric = $Metric
        value = $Value
        notes = $Notes
    }
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

foreach ($path in @($WorkspacesPath, $ItemsPath, $DependenciesPath)) {
    if (-not (Test-Path $path)) {
        throw "Required input not found: $path"
    }
}

$workspaceRows = @(Import-Csv -Path $WorkspacesPath)
$itemRows = @(Import-Csv -Path $ItemsPath | Where-Object { $_.status -eq "discovered" })
$itemAnalysisRows = if (Test-Path $ItemAnalysisPath) { @(Import-Csv -Path $ItemAnalysisPath) } else { @() }
$dependencyRows = @(Import-Csv -Path $DependenciesPath)
$existingNodeRows = if (Test-Path $NodesPath) { @(Import-Csv -Path $NodesPath) } else { @() }

$nodeMap = @{}

foreach ($workspace in $workspaceRows) {
    $workspaceName = Get-FieldValue -Object $workspace -Names @("workspace_name")
    if (-not $workspaceName) {
        continue
    }

    Add-Node -NodeMap $nodeMap -Node ([pscustomobject]@{
        qualified_name = $workspaceName
        display_name = $workspaceName
        workspace_name = $workspaceName
        item_type = "Workspace"
        object_type = "Workspace"
        source_system = Get-FieldValue -Object $workspace -Names @("source_system")
        technical_id = Get-FieldValue -Object $workspace -Names @("technical_id")
        status = Get-FieldValue -Object $workspace -Names @("status")
        notes = "Environment: $(Get-FieldValue -Object $workspace -Names @("environment")); Normalized name: $(Get-FieldValue -Object $workspace -Names @("normalized_workspace_name"))"
    })
}

foreach ($item in $itemRows) {
    Add-Node -NodeMap $nodeMap -Node ([pscustomobject]@{
        qualified_name = Get-FieldValue -Object $item -Names @("qualified_name")
        display_name = Get-FieldValue -Object $item -Names @("item_name")
        workspace_name = Get-FieldValue -Object $item -Names @("workspace_name")
        item_type = Get-FieldValue -Object $item -Names @("item_type")
        object_type = "Item"
        source_system = Get-FieldValue -Object $item -Names @("source_system")
        technical_id = Get-FieldValue -Object $item -Names @("technical_id")
        status = Get-FieldValue -Object $item -Names @("status")
        notes = "Environment: $(Get-FieldValue -Object $item -Names @("workspace_environment")); Folder ID: $(Get-FieldValue -Object $item -Names @("folder_id"))"
    })
}

foreach ($node in $existingNodeRows | Where-Object { $_.item_type -eq "ExternalConnection" }) {
    Add-Node -NodeMap $nodeMap -Node $node
}

foreach ($dependency in $dependencyRows) {
    foreach ($endpoint in @(
        (Get-FieldValue -Object $dependency -Names @("from_qualified_name")),
        (Get-FieldValue -Object $dependency -Names @("to_qualified_name"))
    )) {
        if ($endpoint -and $endpoint.StartsWith("External Connection /") -and -not $nodeMap.ContainsKey($endpoint)) {
            $parts = $endpoint -split " / "
            Add-Node -NodeMap $nodeMap -Node ([pscustomobject]@{
                qualified_name = $endpoint
                display_name = ($parts | Select-Object -Last 1)
                workspace_name = "External"
                item_type = "ExternalConnection"
                object_type = "ExternalConnection"
                source_system = "Local graph build from indexed dependencies"
                technical_id = ""
                status = "inferred"
                notes = "Created from dependency endpoint during Phase 5 graph build."
            })
        }
    }
}

$edgeMap = @{}

foreach ($item in $itemRows) {
    $workspaceName = Get-FieldValue -Object $item -Names @("workspace_name")
    $qualifiedName = Get-FieldValue -Object $item -Names @("qualified_name")
    if ($workspaceName -and $qualifiedName) {
        Add-Edge -EdgeMap $edgeMap -Edge ([pscustomobject]@{
            from_qualified_name = $workspaceName
            to_qualified_name = $qualifiedName
            relationship_type = "contains"
            source_system = "Local graph build from indexed inventory"
            evidence = "Workspace contains item in index/items.csv."
            confidence = "confirmed"
            notes = "Structural containment edge added in Phase 5."
        })
    }
}

foreach ($dependency in $dependencyRows) {
    Add-Edge -EdgeMap $edgeMap -Edge $dependency
}

$nodes = @($nodeMap.Values | Sort-Object -Property object_type, workspace_name, item_type, display_name, qualified_name)
$edges = @($edgeMap.Values | Sort-Object -Property relationship_type, from_qualified_name, to_qualified_name)

Ensure-ParentDirectory -Path $NodesPath
$nodes |
    Select-Object -Property $nodeColumns |
    Export-Csv -Path $NodesPath -NoTypeInformation -Encoding UTF8

Ensure-ParentDirectory -Path $EdgesPath
$edges |
    Select-Object -Property $edgeColumns |
    Export-Csv -Path $EdgesPath -NoTypeInformation -Encoding UTF8

$nodeNameSet = @{}
foreach ($node in $nodes) {
    $nodeNameSet[$node.qualified_name] = $true
}

$missingSourceEdges = @($edges | Where-Object { -not $nodeNameSet.ContainsKey($_.from_qualified_name) })
$missingTargetEdges = @($edges | Where-Object { -not $nodeNameSet.ContainsKey($_.to_qualified_name) })
$duplicateNodeGroups = @($nodes | Group-Object -Property qualified_name | Where-Object { $_.Count -gt 1 })
$duplicateEdgeGroups = @($edges | Group-Object -Property from_qualified_name, to_qualified_name, relationship_type | Where-Object { $_.Count -gt 1 })

$incoming = @{}
$outgoing = @{}
foreach ($node in $nodes) {
    $incoming[$node.qualified_name] = 0
    $outgoing[$node.qualified_name] = 0
}
foreach ($edge in $edges) {
    if ($outgoing.ContainsKey($edge.from_qualified_name)) {
        $outgoing[$edge.from_qualified_name] += 1
    }
    if ($incoming.ContainsKey($edge.to_qualified_name)) {
        $incoming[$edge.to_qualified_name] += 1
    }
}

$isolatedNodes = @($nodes | Where-Object { $incoming[$_.qualified_name] -eq 0 -and $outgoing[$_.qualified_name] -eq 0 })
$dependencyEdgeRows = @($edges | Where-Object { $_.relationship_type -ne "contains" })
$containsEdgeRows = @($edges | Where-Object { $_.relationship_type -eq "contains" })
$confirmedEdges = @($dependencyEdgeRows | Where-Object { $_.confidence -eq "confirmed" })
$likelyEdges = @($dependencyEdgeRows | Where-Object { $_.confidence -eq "likely" })
$partialAnalysisRows = @($itemAnalysisRows | Where-Object { $_.analysis_status -eq "partial" })

$summaryRows = @(
    New-MetricRow -Metric "workspace_nodes" -Value ([string]@($nodes | Where-Object { $_.item_type -eq "Workspace" }).Count)
    New-MetricRow -Metric "item_nodes" -Value ([string]@($nodes | Where-Object { $_.object_type -eq "Item" }).Count)
    New-MetricRow -Metric "external_connection_nodes" -Value ([string]@($nodes | Where-Object { $_.item_type -eq "ExternalConnection" }).Count)
    New-MetricRow -Metric "total_nodes" -Value ([string]$nodes.Count)
    New-MetricRow -Metric "contains_edges" -Value ([string]$containsEdgeRows.Count)
    New-MetricRow -Metric "dependency_edges" -Value ([string]$dependencyEdgeRows.Count)
    New-MetricRow -Metric "total_edges" -Value ([string]$edges.Count)
    New-MetricRow -Metric "confirmed_dependency_edges" -Value ([string]$confirmedEdges.Count)
    New-MetricRow -Metric "likely_dependency_edges" -Value ([string]$likelyEdges.Count)
    New-MetricRow -Metric "missing_source_edges" -Value ([string]$missingSourceEdges.Count)
    New-MetricRow -Metric "missing_target_edges" -Value ([string]$missingTargetEdges.Count)
    New-MetricRow -Metric "duplicate_node_names" -Value ([string]$duplicateNodeGroups.Count)
    New-MetricRow -Metric "duplicate_edge_keys" -Value ([string]$duplicateEdgeGroups.Count)
    New-MetricRow -Metric "isolated_nodes" -Value ([string]$isolatedNodes.Count) -Notes "Nodes with zero incoming and zero outgoing edges after structural contains edges."
)

Ensure-ParentDirectory -Path $GraphSummaryPath
$summaryRows | Export-Csv -Path $GraphSummaryPath -NoTypeInformation -Encoding UTF8

$validationRows = @(
    [pscustomobject]@{ check_name = "missing_source_edges"; status = if ($missingSourceEdges.Count -eq 0) { "pass" } else { "fail" }; count = $missingSourceEdges.Count; details = Limit-Text -Text (($missingSourceEdges | Select-Object -First 5 | ForEach-Object { $_.from_qualified_name }) -join "; ") -MaxLength 800 }
    [pscustomobject]@{ check_name = "missing_target_edges"; status = if ($missingTargetEdges.Count -eq 0) { "pass" } else { "fail" }; count = $missingTargetEdges.Count; details = Limit-Text -Text (($missingTargetEdges | Select-Object -First 5 | ForEach-Object { $_.to_qualified_name }) -join "; ") -MaxLength 800 }
    [pscustomobject]@{ check_name = "duplicate_node_names"; status = if ($duplicateNodeGroups.Count -eq 0) { "pass" } else { "fail" }; count = $duplicateNodeGroups.Count; details = Limit-Text -Text (($duplicateNodeGroups | Select-Object -First 5 | ForEach-Object { $_.Name }) -join "; ") -MaxLength 800 }
    [pscustomobject]@{ check_name = "duplicate_edge_keys"; status = if ($duplicateEdgeGroups.Count -eq 0) { "pass" } else { "fail" }; count = $duplicateEdgeGroups.Count; details = Limit-Text -Text (($duplicateEdgeGroups | Select-Object -First 5 | ForEach-Object { $_.Name }) -join "; ") -MaxLength 800 }
    [pscustomobject]@{ check_name = "isolated_nodes"; status = "info"; count = $isolatedNodes.Count; details = Limit-Text -Text (($isolatedNodes | Select-Object -First 5 | ForEach-Object { $_.qualified_name }) -join "; ") -MaxLength 800 }
)

Ensure-ParentDirectory -Path $ValidationPath
$validationRows | Export-Csv -Path $ValidationPath -NoTypeInformation -Encoding UTF8

$topNodeRows = @(
    $nodes |
        ForEach-Object {
            $nodeName = $_.qualified_name
            [pscustomobject]@{
                qualified_name = $nodeName
                display_name = $_.display_name
                workspace_name = $_.workspace_name
                item_type = $_.item_type
                object_type = $_.object_type
                incoming_edges = $incoming[$nodeName]
                outgoing_edges = $outgoing[$nodeName]
                total_edges = $incoming[$nodeName] + $outgoing[$nodeName]
            }
        } |
        Sort-Object -Property total_edges, outgoing_edges, incoming_edges -Descending |
        Select-Object -First 100
)

Ensure-ParentDirectory -Path $TopNodesPath
$topNodeRows | Export-Csv -Path $TopNodesPath -NoTypeInformation -Encoding UTF8

$relationshipCounts = @{}
foreach ($edge in $dependencyEdgeRows) {
    if (-not $relationshipCounts.ContainsKey($edge.relationship_type)) {
        $relationshipCounts[$edge.relationship_type] = 0
    }
    $relationshipCounts[$edge.relationship_type] += 1
}

$topSources = @(
    $dependencyEdgeRows |
        Group-Object -Property from_qualified_name |
        Sort-Object -Property Count -Descending |
        Select-Object -First $MaxDiagramSources
)

$externalTargets = @(
    $dependencyEdgeRows |
        Where-Object { $_.to_qualified_name.StartsWith("External Connection /") } |
        Group-Object -Property to_qualified_name |
        Sort-Object -Property Count -Descending |
        Select-Object -First $MaxDiagramExternalConnections
)

$diagramLines = [System.Collections.Generic.List[string]]::new()
$diagramLines.Add("flowchart LR") | Out-Null
$diagramLines.Add("    %% Phase 5 dependency graph summary. Full graph data is in graph/nodes.csv and graph/edges.csv.") | Out-Null
$diagramLines.Add("") | Out-Null
$diagramLines.Add("    Workspaces[""$($workspaceRows.Count) accessible workspaces""]") | Out-Null
$diagramLines.Add("    Items[""$($itemRows.Count) Fabric items""]") | Out-Null
$diagramLines.Add("    External[""$(@($nodes | Where-Object { $_.item_type -eq "ExternalConnection" }).Count) external connections""]") | Out-Null
$diagramLines.Add("    DependencyEdges[""$($dependencyEdgeRows.Count) dependency edges""]") | Out-Null
$diagramLines.Add("    ContainsEdges[""$($containsEdgeRows.Count) contains edges""]") | Out-Null
$diagramLines.Add("    Confirmed[""$($confirmedEdges.Count) confirmed dependencies""]") | Out-Null
$diagramLines.Add("    Likely[""$($likelyEdges.Count) likely dependencies""]") | Out-Null
$diagramLines.Add("    Gaps[""Open Phase 4 partial rows: $($partialAnalysisRows.Count)""]") | Out-Null
$diagramLines.Add("") | Out-Null
$diagramLines.Add("    Workspaces --> ContainsEdges --> Items") | Out-Null
$diagramLines.Add("    Items --> DependencyEdges") | Out-Null
$diagramLines.Add("    DependencyEdges --> Confirmed") | Out-Null
$diagramLines.Add("    DependencyEdges --> Likely") | Out-Null
$diagramLines.Add("    DependencyEdges --> External") | Out-Null
$diagramLines.Add("    DependencyEdges --> Gaps") | Out-Null
$diagramLines.Add("") | Out-Null

foreach ($relationshipType in ($relationshipCounts.Keys | Sort-Object)) {
    $id = "rel_$($relationshipType -replace '[^A-Za-z0-9_]', '_')"
    $diagramLines.Add("    $id[""$relationshipType`: $($relationshipCounts[$relationshipType])""]") | Out-Null
    $diagramLines.Add("    DependencyEdges --> $id") | Out-Null
}

$diagramLines.Add("") | Out-Null
$diagramLines.Add("    subgraph TopDependencySources[""Top dependency sources""]") | Out-Null
foreach ($group in $topSources) {
    $sourceName = [string]$group.Name
    $sourceId = Sanitize-MermaidId -Value "source:$sourceName"
    $diagramLines.Add("        $sourceId[""$(Escape-MermaidLabel -Value $sourceName) ($($group.Count))""]") | Out-Null
}
$diagramLines.Add("    end") | Out-Null
$diagramLines.Add("    DependencyEdges --> TopDependencySources") | Out-Null

if ($externalTargets.Count -gt 0) {
    $diagramLines.Add("") | Out-Null
    $diagramLines.Add("    subgraph TopExternalTargets[""Top external targets""]") | Out-Null
    foreach ($group in $externalTargets) {
        $targetName = [string]$group.Name
        $targetId = Sanitize-MermaidId -Value "target:$targetName"
        $diagramLines.Add("        $targetId[""$(Escape-MermaidLabel -Value $targetName) ($($group.Count))""]") | Out-Null
    }
    $diagramLines.Add("    end") | Out-Null
    $diagramLines.Add("    External --> TopExternalTargets") | Out-Null
}

Ensure-ParentDirectory -Path $DiagramPath
$diagramLines | Set-Content -Path $DiagramPath -Encoding UTF8

$validationFailures = @($validationRows | Where-Object { $_.status -eq "fail" })
if ($validationFailures.Count -gt 0) {
    Set-UnresolvedEntry `
        -Title "Phase 5 graph validation gaps" `
        -Status "open" `
        -Evidence ("Graph validation found failures: " + (($validationFailures | ForEach-Object { "$($_.check_name)=$($_.count)" }) -join "; ")) `
        -NextStep "Resolve missing or duplicate graph identities before Phase 6 execution timing."
}
else {
    Set-UnresolvedEntry `
        -Title "Phase 5 graph validation gaps" `
        -Status "resolved" `
        -Evidence "Graph validation passed for missing sources, missing targets, duplicate node names, and duplicate edge keys." `
        -NextStep "User reviews Phase 5 outputs and approves Phase 6 execution timing."
}

Write-Host "Phase 5 graph build completed."
Write-Host "Nodes: $($nodes.Count)"
Write-Host "Edges: $($edges.Count)"
Write-Host "Contains edges: $($containsEdgeRows.Count)"
Write-Host "Dependency edges: $($dependencyEdgeRows.Count)"
Write-Host "Confirmed dependency edges: $($confirmedEdges.Count)"
Write-Host "Likely dependency edges: $($likelyEdges.Count)"
Write-Host "Missing source edges: $($missingSourceEdges.Count)"
Write-Host "Missing target edges: $($missingTargetEdges.Count)"
Write-Host "Duplicate node names: $($duplicateNodeGroups.Count)"
Write-Host "Duplicate edge keys: $($duplicateEdgeGroups.Count)"
Write-Host "Summary: $GraphSummaryPath"
Write-Host "Validation: $ValidationPath"
Write-Host "Top nodes: $TopNodesPath"
Write-Host "Diagram: $DiagramPath"
