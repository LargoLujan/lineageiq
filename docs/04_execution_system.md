# Phased Execution System

## Purpose

Map Microsoft Fabric progressively without losing control of scope, evidence, or dependencies.

The project must move in this order:

1. Confirm tooling and access paths.
2. Discover layers.
3. Discover workspaces.
4. Discover items inside each workspace.
5. Analyze each item.
6. Build dependencies.
7. Build graph and visual diagram.
8. Review executions and durations.
9. Propose optimized orchestration.

## Scripts By Phase

The numbered scripts in `backend/scripts/` implement these phases. `backend/scripts/99_refresh_lineage_project.ps1` runs them in dependency order (see the README, "Discovery Scripts").

| Phase | Script |
| --- | --- |
| 0.5 Tooling preflight | `00_preflight_tools.ps1` |
| A Layer discovery, B Workspace discovery | `01_discover_workspaces.ps1`, `02_normalize_workspaces.ps1` |
| C Item discovery | `03_discover_items.ps1` |
| D Item analysis | `04_analyze_items.ps1` |
| E Graph and diagram | `05_build_graph.ps1` |
| F Execution timing | `06_discover_executions.ps1` |
| G Optimization | `07_optimize_orchestration.ps1` |

Later numbered scripts add object-level lineage, the explorer payloads and the other outputs; `backend/scripts/README.md` lists them all. LineageIQ maps lineage at object level, not column level.

## Operating Principles

- Do not jump directly into optimization.
- Do not assume dependencies without evidence.
- Do not use technical IDs as the visible identity.
- Keep names real and readable.
- Record every uncertainty in `index/unresolved.md`.
- Keep each step read-only against Fabric unless a change has been proposed and approved.

## Phase A: Layer Discovery

Goal:
Understand the environment layer by layer.

Recommended layers:
- Tenant or account scope.
- Fabric domains.
- Capacities.
- Workspaces.
- Items.
- Data objects.
- Executions.

Output:
- `index/discovery_layers.csv`
- `index/workspaces.csv`

## Phase 0.5: Tooling Preflight

Goal:
Confirm that Fabric CLI, Azure CLI, Fabric REST API patterns, and local reference projects are available.

Output:
- `index/tooling_inventory.csv`

Rules:
- Do not authenticate.
- Do not query Fabric.
- Do not read secret values.
- Reuse existing local reference projects (for example your own Fabric deployment tooling) when available.

## Phase B: Workspace Discovery

Goal:
List all accessible workspaces and classify them.

Capture:
- Workspace name.
- Capacity.
- Domain.
- Owner or technical contact.
- Purpose if known.
- Source evidence.

Output:
- `index/workspaces.csv`

## Phase C: Item Discovery

Goal:
List all items inside each workspace.

Capture:
- Item name.
- Item type.
- Qualified name.
- Source system.
- Technical ID as metadata.

Output:
- `index/items.csv`

## Phase D: Item Analysis

Goal:
Inspect each item to understand what it reads, writes, executes, refreshes, or serves.

Analyze by item type:

- Notebook:
  - Input tables, files, shortcuts, APIs, or SQL sources.
  - Output tables, files, or warehouses.
  - Called notebooks or libraries.

- Pipeline:
  - Activities.
  - Called notebooks.
  - Called pipelines.
  - Refresh activities.
  - Parameters.

- Lakehouse:
  - Tables.
  - Files.
  - Shortcuts.
  - SQL endpoint usage.

- Warehouse:
  - Tables.
  - Views.
  - Stored procedures.
  - Downstream semantic models.

- Semantic Model:
  - Source tables.
  - Refresh mode.
  - Refresh schedule.
  - Reports using it.

- Report:
  - Semantic model used.
  - Workspace location.

Output:
- `index/item_analysis.csv`
- `index/dependencies.csv`

## Phase E: Graph And Diagram

Goal:
Convert evidence into graph-ready files and a readable diagram.

Outputs:
- `graph/nodes.csv`
- `graph/edges.csv`
- `diagrams/current_dependency_map.mmd`

Rule:
The graph CSVs are the canonical structure. Mermaid is the first visual layer.

## Phase F: Execution Timing

Goal:
Understand when each process starts, how long it takes, and what finishes before downstream work starts.

Capture:
- Trigger type.
- Schedule.
- Start time.
- End time.
- Duration.
- Status.
- Evidence.

Output:
- `index/executions.csv`

## Phase G: Optimization

Goal:
Design one or more improved orchestration pipelines.

Check:
- Critical path.
- Idle windows.
- Safe parallelism.
- Unsafe parallelism.
- Missing refreshes.
- SQL endpoint refresh needs.
- Semantic model refresh needs.
- Downstream reports and model dependencies.

Output:
- `analysis/orchestration_recommendations.csv`
- Human step-by-step change plan.

## End Of Each Working Session

Refresh any affected index or graph files, then note:
- Evidence used.
- Open gaps.
- Risks.
- Next step.
