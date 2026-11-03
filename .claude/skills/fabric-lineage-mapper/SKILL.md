---
name: fabric-lineage-mapper
description: Map Microsoft Fabric workspaces, items, and object-level dependencies into a read-only lineage graph (Purview-lineage style) using the local consolidated index first, then Azure DevOps, SharePoint, local OneLake, and Fabric/Power BI REST APIs for missing metadata. Use when asked to discover Fabric workspaces, notebooks, lakehouses, warehouses, semantic models, reports, pipelines, SQL endpoints, or to explain/update/troubleshoot the lineage graph, the scheduled refresh, or the lineage-explorer web site in this repo. Scope is lineage visibility only — no data classification, no governance policy, no business glossary.
---

# Fabric Lineage Mapper

## Scope boundary (read this first)

This project has one product: a read-only, Purview-lineage-style map of what is connected to what across the Fabric tenant (workspaces → items → source/target objects), rendered in `site/lineage-explorer/` and `site/semantic-lineage/`.

It is explicitly **not** a governance tool. Do not add or extend:
- Data classification / sensitivity labeling.
- Access policy or permission management.
- Business glossary / term catalog.

`analysis/d1_*` through `analysis/d8_*`, `scripts/24_*`–`scripts/47_*`, and `docs/21_*`–`docs/46_*` are legacy **orchestration-optimization** work (writer/reader conflict resolution, failure/duration stabilization, promotion queues) inherited from an earlier goal in `AGENTS.md` ("optimized orchestration pipelines"). They are not required for lineage visibility and should be treated as optional/frozen unless the user explicitly asks to resume orchestration work. Do not expand this branch of work on your own initiative.

## Rules

- Start with `index/master_index.md` — do not rediscover from scratch when `index/` already has current evidence.
- Source priority: 1) local consolidated index, 2) Azure DevOps, 3) SharePoint, 4) local OneLake, 5) Fabric/Power BI REST APIs.
- Everything here is read-only against Fabric, Azure DevOps, SharePoint, and OneLake. Never create, update, or delete a Fabric item, schedule, or permission from a script. Any operational change must be proposed as text (proposed change, exact location, step-by-step human action) and executed by a human.
- Use real names as the visible graph identity; store technical IDs only as supporting metadata.
- Record gaps in `index/unresolved.md`, progress in `docs/00_work_log.md`, and session summaries in `docs/conversations/YYYY-MM-DD.md` (see `docs/09_conversation_persistence.md`).
- Check `docs/07_phase_gates.md` before treating a phase as advanced; do not advance phases unless the user explicitly asks.
- A full `full-read-only` refresh can take hours on a large tenant. Prefer the narrowest mode that answers the question (`local-artifacts` for visual/regen-only changes).

## Workflow

1. Read `index/master_index.md` and the tail of `docs/00_work_log.md` for current state.
2. Check `runs/` for the most recent `lineage_refresh_*.md` and `analysis/lineage_refresh_manifest.json` to see how stale the graph is before assuming it's current.
3. For a scan/refresh request, run `scripts/99_refresh_lineage_project.ps1` with the narrowest sufficient `-Mode` (see Automation below) instead of invoking individual numbered scripts by hand, unless debugging a single step.
4. For lineage questions ("what feeds X", "what breaks if Y changes"), query the generated artifacts first — `graph/nodes.csv`, `graph/edges.csv`, `site/semantic-lineage/data/lineage-explorer.json`, `analysis/object_impact_index.csv` — rather than re-scanning Fabric.
5. Record new gaps/evidence in the relevant `index/*.csv` and note it in the work log and daily conversation file.

## Automation (unattended refresh — do not depend on an agent session)

The goal is a scheduled refresh that runs without a human or an AI agent in the loop. Today it cannot, for one reason: authentication is `az login` / `fab auth login` under a personal interactive account (`docs/06_tooling_prerequisites.md`), which requires a human to complete a device-code/browser prompt whenever the token expires (an expired Azure token blocks query execution until someone signs in again).

Before recommending a scheduled job, confirm:
- A service principal has been created and approved for Fabric/Power BI REST access (tenant admin must enable "Service principals can use Fabric APIs" and grant workspace access or admin-scan-API access). This is documented as *possible but not implemented* in `docs/06_tooling_prerequisites.md`.
- The scheduler (Windows Task Scheduler, a container with a cron loop, or GitHub Actions self-hosted runner) authenticates via `ClientSecretCredential`/`az login --service-principal`, not device code.
- `scripts/99_refresh_lineage_project.ps1 -Mode <mode> -AuthMethod azure-cli` is the entry point; it already fails loudly (`$ErrorActionPreference = "Stop"`, PowerShell `throw`) and writes `runs/lineage_refresh_<timestamp>.md` plus `analysis/lineage_refresh_manifest.json` on every attempt, including partial failures — use those two files as the automated job's health check, not the exit code alone.

Do not propose running the D1-D8 closure-control cascade (baked into `full-read-only` mode today) as part of a lean scheduled lineage job — it roughly doubles run time for orchestration bookkeeping the user did not ask for. If asked to slim the scheduled job, that cascade block in `scripts/99_refresh_lineage_project.ps1` (the `full-read-only` branch calling `scripts/24_*` through `scripts/47_*`) is the first thing to make optional.

## Tooling

- `docs/06_tooling_prerequisites.md` — auth methods and required CLIs before live discovery.
- `docs/07_phase_gates.md` — current phase status and gate conditions.
- `docs/08_container_runtime.md` — Docker runtime for isolated tooling; also auto-starts the web viewer on port `8765`.
- `docs/12_automation_refresh.md` — refresh modes, cadence, and full output list of `scripts/99_refresh_lineage_project.ps1`.
- `scripts/README.md` — every numbered script, its inputs/outputs, and read-only guarantees.

Optional local reference project (your own Fabric deployment tooling, for REST auth/workspace client patterns): pass it to `00_preflight_tools.ps1` with `-ReferenceProjectPath` or set `FABRIC_LINEAGE_REFERENCE_PROJECT`.

If Azure CLI is not authenticated but Fabric CLI is, use `fab api` for read-only Fabric discovery.

## Visualization

Canonical graph data: `graph/nodes.csv` and `graph/edges.csv`. Mermaid (`diagrams/current_dependency_map.mmd`) is the lightweight visual layer; the real interactive product is `site/lineage-explorer/` and `site/semantic-lineage/` (static HTML/JS reading generated JSON under `site/*/data/`, no backend required — see `scripts/start_lineage_web.sh`). Escalate to NetworkX only for critical-path/cycle analysis, and to Neo4j only if CSV/Mermaid stop scaling.

## Graph Naming

```text
Workspace / Item Type / Item Name
Workspace / Item Type / Item Name / Object Type / Object Name   (for nested data objects)
```

## Relationship Types

`contains`, `reads_from`, `writes_to`, `executes`, `refreshes`, `depends_on`, `uses_model`, `serves_report`, `scheduled_before`, `candidate_parallel`

## Confidence

- `confirmed`: direct evidence exists.
- `likely`: strong indirect evidence exists.
- `unknown`: human review required.

## Required Output

Every analysis or scan must end with: proposed changes, evidence used, open gaps, risks, and the next human step.
