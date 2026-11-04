#!/usr/bin/env python3
"""MCP server exposing this project's lineage catalog to AI agents.

list_workspaces/search_items/get_item_lineage/get_object_impact/
get_notebook_code now delegate to lineage_web/catalog.py's own query
functions -- the same ones backend/scripts/lineage_web_server.py's HTTP
handler calls -- instead of reading index/*.csv directly. This matters
because catalog.py reads live from the Warehouse (dbo.bronze_workspaces/
bronze_items/bronze_dependencies/...) whenever
lakehouse.web_read_mode == "warehouse" (the default), falling back to the
local CSV/JSON snapshot only when that's not configured or a live read fails -- while a plain local
read (what every tool here did before this change, and what the remaining
tools below still do) silently answers from whatever that snapshot last
captured, which on a dev machine can be weeks stale (e.g.
index/workspaces.csv having far fewer rows than the tenant really has). The
remaining tools (get_related_elements, get_objects_for_item,
get_workspace_roles, get_execution_stats, get_failure_hotspots,
get_schedules, get_scan_status) have no Warehouse-backed equivalent in
catalog.py yet and still read their local artifacts directly -- no network
calls, no Fabric credentials, no web server required for those. Meant to be
launched as a local subprocess by an MCP client (Claude Code/Desktop) over
stdio, so it needs no authentication of its own for READS: the client
already controls who can start it.

The write tools (trigger_scan/trigger_full_scan/stop_scan) call
straight into backend/scripts/lineage_web/scan_manager.py's own functions
(the same ones backend/scripts/lineage_web_server.py's HTTP handler calls) --
still local-only, no HTTP round trip, but a scan is a real action with real
side effects, so it is NOT implicitly trusted just because this process was
started locally the way reads are. Each write tool takes an optional
api_key parameter, validated against config/admin_settings.json's api_keys
list the exact same way a Fabric pipeline's X-Api-Key header is
-- so triggering/stopping a scan from an AI agent requires the same
deliberate, admin-issued credential a remote automation caller would need,
not a new, quieter bypass. Omitting api_key falls through to the same
sign-in-required/allow_anonymous_scans rule the REST API already enforces.

mcp_server_remote.py is a second server that instead calls the
secured REST API over HTTP, so the same tool surface also works for a
remote/shared setup -- this file stays as the simple, always-available
local option, and both keep the same tool signatures (the implementation
is a direct function call here and an HTTP request there).

Run directly for a smoke test: `python3 backend/scripts/mcp_server.py` (stdio mode,
waits for an MCP client). Register with Claude Code via `claude mcp add
fabric-lineage -- python3 <path-to-this-file>` (see README).
"""

from __future__ import annotations

import csv
import json
from pathlib import Path
from typing import Any

from mcp.server.fastmcp import FastMCP

from lineage_web import catalog, data_quality, purview_insights
from lineage_web.admin_settings import _load_admin_settings
from lineage_web.auth import _valid_api_key
from lineage_web.scan_manager import _queue_snapshot, _start_full_scan, _start_scan, _stop_scan

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
INDEX_DIR = REPO_ROOT / "index"
DATA_DIR = REPO_ROOT / "frontend" / "semantic-lineage" / "data"
SCAN_STATE_DIR = REPO_ROOT / "analysis" / "single_workspace_scan"

mcp = FastMCP("fabric-lineage")

_SCAN_ERROR_STATUS = {
    "sign_in_required": "This action requires a valid api_key (ask an admin to create one via the admin panel's API Keys tab), or an admin must enable allow_anonymous_scans.",
    "az_session_invalid": "The shared Azure CLI session on the server machine is missing or expired.",
    "scan_already_running": "A scan is already running.",
    "queue_full": "The scan queue is full; try again once earlier requests finish.",
    "workspace_not_found": "That workspace name does not exist in index/workspaces.csv.",
    "workspace_index_missing": "index/workspaces.csv does not exist -- run backend/scripts/01_discover_workspaces.ps1 first.",
    "spawn_failed": "Could not start the scan process.",
    "workspace_discovery_failed": "Could not determine accessible workspaces.",
    "no_accessible_workspaces": "No accessible Fabric workspaces.",
    "no_scan_running": "No scan is currently running.",
    "not_permitted": "Not permitted to stop this scan.",
}


def _resolve_api_key_name(api_key: str) -> tuple[str | None, dict[str, Any] | None]:
    """Returns (validated_key_name, error). error is a ready-to-return dict
    when a non-empty api_key was supplied but didn't match any configured
    key -- fails loudly rather than silently falling through to the
    anonymous/session-less path, so a typo'd key doesn't look like "no key
    was given" from the caller's side. Also checked for scope:
    the three write tools below are exactly the
    "trigger/stop a scan" action a "read_only" key must NOT be able to do
    -- handler.py's REST route already enforced this, but this local stdio
    server called _start_scan/_start_full_scan/_stop_scan directly, so a
    read_only key handed to an agent (the admin panel's own recommended
    use for that scope) could still trigger a real tenant-wide scan
    through this path. Same _valid_api_key single-lookup fix as
    handler.py's _resolve_scan_caller."""
    if not api_key:
        return None, None
    settings = _load_admin_settings()
    key_name, scope = _valid_api_key(api_key, settings)
    if key_name is None:
        return None, {"started": False, "error": "invalid_api_key", "message": "That api_key does not match any key configured in the admin panel."}
    if scope != "full":
        return None, {"started": False, "error": "insufficient_scope", "message": "This API key is read-only and cannot trigger or stop scans -- create a key with scope 'full' in the admin panel's API Keys tab for this action."}
    return key_name, None


def _read_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def _read_json(path: Path) -> Any:
    if not path.exists():
        return None
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def _norm(value: str) -> str:
    return (value or "").strip().casefold()


# Fabric's own item-listing REST API has no webUrl-style field (confirmed by
# grepping every real scan artifact this project has ever produced -- zero
# hits), so this is a constructed deep link, same generic, item-type-agnostic
# /groups/{workspaceId}/items/{itemId} shape frontend/semantic-lineage/app.js
# and graph-map.js already use (kept in sync deliberately -- this is the one
# thing in the whole pipeline no automated check can verify, since it needs a
# real, signed-in browser against the real tenant to confirm the destination
# page is actually the intended item, not just a well-formed-looking URL).
_workspace_ids_by_name_cache: dict[str, str] | None = None
_items_by_qualified_name_cache: dict[str, dict[str, str]] | None = None


def _workspace_ids_by_name() -> dict[str, str]:
    global _workspace_ids_by_name_cache
    if _workspace_ids_by_name_cache is None:
        _workspace_ids_by_name_cache = {
            row.get("workspace_name", ""): row.get("technical_id", "")
            for row in _read_csv(INDEX_DIR / "workspaces.csv")
        }
    return _workspace_ids_by_name_cache


def _items_by_qualified_name() -> dict[str, dict[str, str]]:
    global _items_by_qualified_name_cache
    if _items_by_qualified_name_cache is None:
        _items_by_qualified_name_cache = {
            row.get("qualified_name", ""): row for row in _read_csv(INDEX_DIR / "items.csv")
        }
    return _items_by_qualified_name_cache


def _fabric_item_url(item_row: dict[str, str]) -> str:
    item_id = item_row.get("technical_id", "")
    workspace_id = _workspace_ids_by_name().get(item_row.get("workspace_name", ""), "")
    if not item_id or not workspace_id:
        return ""
    return f"https://app.fabric.microsoft.com/groups/{workspace_id}/items/{item_id}?experience=fabric-developer"


def _item_link_fields(qualified_name: str) -> dict[str, str]:
    """technical_id/workspace_id/fabric_url for any item, by qualified_name --
    "" for each when the item or its GUIDs aren't in the index (e.g. a
    workspace recovered as a name-only placeholder after a partial data
    recovery)."""
    item_row = _items_by_qualified_name().get(qualified_name)
    if not item_row:
        return {"technical_id": "", "workspace_id": "", "fabric_url": ""}
    return {
        "technical_id": item_row.get("technical_id", ""),
        "workspace_id": _workspace_ids_by_name().get(item_row.get("workspace_name", ""), ""),
        "fabric_url": _fabric_item_url(item_row),
    }


@mcp.tool()
def list_workspaces(name_contains: str = "") -> list[dict[str, str]]:
    """List Fabric workspaces this project has scanned.

    Args:
        name_contains: Optional case-insensitive substring filter on
            workspace_name. Empty returns every workspace.
    """
    return catalog._list_workspaces(name_contains)


def _find_items(query: str, items: list[dict[str, str]]) -> list[dict[str, str]]:
    needle = _norm(query)
    exact = [row for row in items if _norm(row.get("qualified_name", "")) == needle]
    if exact:
        return exact
    return [
        row
        for row in items
        if needle in _norm(row.get("item_name", "")) or needle in _norm(row.get("qualified_name", ""))
    ]


@mcp.tool()
def search_items(query: str, item_type: str = "", limit: int = 20) -> list[dict[str, str]]:
    """Find items by (partial) name -- e.g. "orders", "NB_Load_CRM", "bi_sales".

    Args:
        query: Case-insensitive substring matched against item_name and
            qualified_name.
        item_type: Optional exact item_type filter (Report, SemanticModel,
            Notebook, DataPipeline, Lakehouse, etc.).
        limit: Max rows to return (most-relevant-first is not computed --
            this is a plain substring filter, refine the query if there
            are too many matches).
    """
    return catalog._search_items(query, item_type, limit)["items"]


@mcp.tool()
def get_item_lineage(qualified_name: str) -> dict[str, Any]:
    """Get one item's metadata plus its direct upstream and downstream dependencies.

    Args:
        qualified_name: Exact "workspace / item_type / item_name" qualified
            name, or a partial item name -- if the match isn't exact and
            unique, this returns candidates instead of lineage so the
            caller can retry with the right qualified_name (use
            search_items to find it first if unsure).
    """
    return catalog._get_item_lineage(qualified_name)


@mcp.tool()
def get_object_impact(query: str, limit: int = 5) -> dict[str, Any]:
    """Find source object(s) (table/view/etc.) by name and report what depends on them.

    Args:
        query: Case-insensitive substring matched against the object's
            display name (e.g. "orders", "DATAMART_SALES").
        limit: Max matching objects to return full detail for.
    """
    return catalog._get_object_impact(query, limit)


# --- Relationship index: a real graph index, not a per-call
# scan -- built once per process from index/dependencies.csv (an item's
# direct upstream/downstream -- small enough to hold
# in memory) so an agent asking "what's related to X, a few hops out" gets
# an O(hops) BFS over a prebuilt adjacency map instead of a fresh linear
# scan of the CSV per call. Cached for the life of this process (typically
# one MCP client session) -- restart the server after a rescan to pick up
# new dependency rows, same as any other tool here already implicitly
# assumes for its underlying CSVs.
_relationship_index_cache: dict[str, Any] | None = None


def _relationship_index() -> dict[str, Any]:
    global _relationship_index_cache
    if _relationship_index_cache is not None:
        return _relationship_index_cache
    deps = _read_csv(INDEX_DIR / "dependencies.csv")
    outgoing: dict[str, list[dict[str, str]]] = {}
    incoming: dict[str, list[dict[str, str]]] = {}
    for row in deps:
        src = row.get("from_qualified_name", "")
        dst = row.get("to_qualified_name", "")
        if not src or not dst:
            continue
        outgoing.setdefault(src, []).append(
            {"qualified_name": dst, "relationship_type": row.get("relationship_type", ""), "confidence": row.get("confidence", "")}
        )
        incoming.setdefault(dst, []).append(
            {"qualified_name": src, "relationship_type": row.get("relationship_type", ""), "confidence": row.get("confidence", "")}
        )
    _relationship_index_cache = {"outgoing": outgoing, "incoming": incoming}
    return _relationship_index_cache


def _traverse_relationship_index(start: str, direction: str, max_hops: int, limit: int) -> list[dict[str, Any]]:
    # "upstream" = what start depends on = start's own outgoing edges (a
    # dependency row is stored from=dependent, to=dependency -- matches the
    # same convention frontend/semantic-lineage/graph-map-data.js's
    # traverse() already documents and uses for the web UI's own upstream/
    # downstream buttons, so an agent's answer matches what a human sees
    # there for the same item).
    index = _relationship_index()
    link_map = index["outgoing"] if direction == "upstream" else index["incoming"]
    visited: dict[str, int] = {start: 0}
    queue: list[tuple[str, int]] = [(start, 0)]
    results: list[dict[str, Any]] = []
    while queue and len(results) < limit:
        current, depth = queue.pop(0)
        if depth >= max_hops:
            continue
        for link in link_map.get(current, []):
            neighbor = link["qualified_name"]
            if neighbor in visited:
                continue
            visited[neighbor] = depth + 1
            results.append(
                {
                    "qualified_name": neighbor,
                    "hops": depth + 1,
                    "relationship_type": link["relationship_type"],
                    "confidence": link["confidence"],
                    "via": current,
                    **_item_link_fields(neighbor),
                }
            )
            queue.append((neighbor, depth + 1))
            if len(results) >= limit:
                break
    return results


@mcp.tool()
def get_related_elements(qualified_name: str, direction: str = "both", max_hops: int = 2, limit: int = 100) -> dict[str, Any]:
    """Find items related to one item within a bounded number of hops, using
    a prebuilt relationship index (fast even for a highly-connected hub --
    doesn't re-scan the full dependency list per call, and doesn't walk the
    entire reachable graph like get_item_lineage's full traversal would for
    a distant multi-hop question).

    Args:
        qualified_name: Exact or partial item name (see search_items).
        direction: "upstream" (what this item depends on), "downstream"
            (what depends on this item), or "both".
        max_hops: How many relationship hops to follow (1 = direct only,
            matching get_item_lineage; 2+ reaches indirect dependencies).
        limit: Max related items to return per direction.
    """
    items = _read_csv(INDEX_DIR / "items.csv")
    matches = _find_items(qualified_name, items)
    if len(matches) == 0:
        return {"found": False, "candidates": []}
    if len(matches) > 1:
        return {
            "found": False,
            "reason": "ambiguous_query",
            "candidates": [
                {"qualified_name": row.get("qualified_name", ""), "item_type": row.get("item_type", "")}
                for row in matches[:25]
            ],
        }

    target = matches[0].get("qualified_name", "")
    result: dict[str, Any] = {"found": True, "qualified_name": target, "max_hops": max_hops, **_item_link_fields(target)}
    if direction in ("upstream", "both"):
        result["upstream"] = _traverse_relationship_index(target, "upstream", max_hops, limit)
    if direction in ("downstream", "both"):
        result["downstream"] = _traverse_relationship_index(target, "downstream", max_hops, limit)
    return result


@mcp.tool()
def get_objects_for_item(qualified_name: str) -> dict[str, Any]:
    """Get the full source-object footprint (tables/views/stored procedures/
    files) one item reads or writes -- the same detail Graph Map Mode's
    "show objects" button reveals, via the same prebuilt by-item index
    (O(1) lookup, not a scan over every object-level edge).

    Args:
        qualified_name: Exact or partial item name (see search_items).
    """
    items = _read_csv(INDEX_DIR / "items.csv")
    matches = _find_items(qualified_name, items)
    if len(matches) == 0:
        return {"found": False, "candidates": []}
    if len(matches) > 1:
        return {
            "found": False,
            "reason": "ambiguous_query",
            "candidates": [
                {"qualified_name": row.get("qualified_name", ""), "item_type": row.get("item_type", "")}
                for row in matches[:25]
            ],
        }

    target = matches[0].get("qualified_name", "")
    object_graph = _read_json(DATA_DIR / "graph-map-index-objects.json")
    if not object_graph:
        return {"found": False, "reason": "graph-map-index-objects.json not built yet -- run backend/scripts/build_graph_map_index.py."}

    edge_indices = object_graph.get("by_item_id", {}).get(target, [])
    nodes_by_id = {n["data"]["id"]: n["data"] for n in object_graph.get("nodes", [])}
    objects = []
    for position in edge_indices:
        edge = object_graph["edges"][position]["data"]
        obj = nodes_by_id.get(edge.get("source", ""))
        if not obj:
            continue
        objects.append(
            {
                "object_display_name": obj.get("label", ""),
                "source_type": obj.get("source_type", ""),
                "source_server": obj.get("source_server", ""),
                "source_database": obj.get("source_database", ""),
                "column_count": obj.get("column_count", 0),
                "relationship_type": edge.get("relationship_type", ""),
                "confidence": edge.get("confidence", ""),
            }
        )

    return {"found": True, "qualified_name": target, "object_count": len(objects), "objects": objects}


# 60k chars is comfortably inside every current agent context window while
# still covering the large majority of real-world notebooks whole
# (most are a few hundred lines); truncation is flagged explicitly rather
# than silently cutting the response so a caller knows to ask for a specific
# range instead of assuming it saw the whole file. Kept here as this tool's
# own default -- the actual lookup (and its own copy of this same limit) now
# lives in catalog._get_notebook_code, see this file's module docstring.
_NOTEBOOK_CODE_MAX_CHARS = 60000


@mcp.tool()
def get_notebook_code(qualified_name: str, max_chars: int = _NOTEBOOK_CODE_MAX_CHARS) -> dict[str, Any]:
    """Read a notebook's actual downloaded source code, plus the read/write/
    execute operations already parsed out of it line-by-line -- for
    understanding what a notebook really does instead of only its lineage
    edges (e.g. "this notebook reads table X and writes table Y" doesn't
    show the transformation logic in between; this does).

    Args:
        qualified_name: Exact or partial notebook name (see search_items).
        max_chars: Truncates very large notebooks; check "truncated" in the
            response and narrow the request (e.g. ask about one function/
            cell by name once you know it exists) rather than raising this
            indefinitely.
    """
    return catalog._get_notebook_code(qualified_name, max_chars)


@mcp.tool()
def get_workspace_roles(workspace_name: str) -> dict[str, Any]:
    """List who has access to a workspace and with what role (Admin/Member/
    Contributor/Viewer), from the tenant's real Fabric role assignments
    (backend/scripts/68_discover_workspace_role_assignments.ps1).

    Args:
        workspace_name: Exact or case-insensitive-substring workspace name.
    """
    rows = _read_csv(INDEX_DIR / "workspace_role_assignments.csv")
    if not rows:
        return {"found": False, "reason": "index/workspace_role_assignments.csv not built yet -- run backend/scripts/68_discover_workspace_role_assignments.ps1."}

    needle = _norm(workspace_name)
    exact = [row for row in rows if _norm(row.get("workspace_name", "")) == needle]
    matches = exact or [row for row in rows if needle in _norm(row.get("workspace_name", ""))]
    assignments = [row for row in matches if row.get("status") == "discovered"]

    return {
        "found": len(matches) > 0,
        "workspace_name": matches[0].get("workspace_name", "") if matches else "",
        "assignment_count": len(assignments),
        "assignments": [
            {
                "principal_name": row.get("principal_name", ""),
                "principal_type": row.get("principal_type", ""),
                "role": row.get("role", ""),
            }
            for row in assignments
        ],
    }


# --- Governance/sensitivity tools: delegate straight to purview_insights
# .py's own functions -- same live-Warehouse-first, local-fallback pattern
# the catalog.py-backed tools above already use, no local artifact of
# their own to go stale. Zero-arg reads here need no api_key (same trust
# bar as get_workspace_roles above: starting this local stdio process
# already implies trust) -- the equivalent REST routes (GET /api/admin/
# ...) DO require an admin session or a valid API key, since
# mcp_server_remote.py/mcp_http_server.py have no local-process trust
# boundary to lean on instead (see handler.py's
# _require_admin_or_api_key).
@mcp.tool()
def get_access_audit() -> dict[str, Any]:
    """Who has access to which workspace and with what role, tenant-wide --
    plus a ranked "who is Admin in the most workspaces" view. Broader than
    get_workspace_roles (which is scoped to one workspace at a time): use
    this for "who holds the most access tenant-wide" questions,
    get_workspace_roles for "who can touch this one workspace"."""
    return purview_insights._get_access_audit()


@mcp.tool()
def get_governance_scan_overview() -> dict[str, Any]:
    """Sensitivity labels, endorsement, tags, and semantic model RLS roles
    from the Fabric/Power BI Admin Scanner API, plus the scan's own
    diagnostic status list (what's working, what's blocked, and the exact
    fix). {found: False, reason} if this scan has never been run."""
    return purview_insights._get_governance_scan_overview()


@mcp.tool()
def get_sensitivity_overview(sample_limit: int = 15) -> dict[str, Any]:
    """Tenant-wide count of catalogued source objects whose columns match a
    sensitivity pattern BY NAME (email, national ID, financial, etc.), by
    category -- unconfirmed against real values, see
    get_content_sensitivity_overview for the content-verified counterpart.
    Each sample row includes workspace_name (server-aware match, so a
    same-named table in a Dev and a Pro workspace resolves to the right
    one) for cross-referencing with get_workspace_roles to answer "who can
    see this sensitive data".

    Args:
        sample_limit: Max example object rows to include per category.
    """
    return purview_insights._get_sensitivity_overview(sample_limit=sample_limit, settings=_load_admin_settings())


@mcp.tool()
def get_content_sensitivity_overview(sample_limit: int = 15) -> dict[str, Any]:
    """Tenant-wide count of columns with a CONTENT-verified sensitivity match
    (regex against a bounded sample of real cell values, never the raw
    values themselves), by category -- scoped to the Fabric-native
    Lakehouse tables NB_Discover_Column_Sensitivity.py has profiled, a
    subset of the whole tenant. Same workspace_name disambiguation as
    get_sensitivity_overview.

    Args:
        sample_limit: Max example object/column rows to include per category.
    """
    return purview_insights._get_content_sensitivity_overview(sample_limit=sample_limit, settings=_load_admin_settings())


@mcp.tool()
def get_data_quality_overview() -> dict[str, Any]:
    """Tenant-wide evaluation of every admin-defined data-quality rule
     against dbo.bronze_column_profile -- pass/fail/
    not_profiled counts and a pass_rate that excludes not_profiled rules
    from the denominator (an unprofiled table is a coverage gap, not a
    quality failure). {found: False, reason} if no rule has been defined
    yet in the admin panel's "Calidad de datos" tab."""
    return data_quality._get_data_quality_overview(_load_admin_settings())


@mcp.tool()
def get_data_quality_for_table(workspace_name: str, lakehouse_name: str, table_name: str) -> dict[str, Any]:
    """Evaluate whatever data-quality rules target one Fabric-native
    Lakehouse table, if any. {found: False} means no rule targets this
    table yet, not that the table is missing.

    Args:
        workspace_name: Exact workspace name.
        lakehouse_name: Exact Lakehouse item name.
        table_name: Exact table name, e.g. "dbo.MyTable".
    """
    return data_quality._get_data_quality_for_table(_load_admin_settings(), workspace_name, lakehouse_name, table_name)


@mcp.tool()
def get_data_products() -> dict[str, Any]:
    """The admin-curated list of Purview-Unified-Catalog-style data products:
    name, owner_email, description, and the
    qualified_names linked to each one -- for "what data product does this
    item belong to, and who owns it" questions. Distinct from Fabric's own
    native per-workspace "Domain" field (a different, already-scanned
    concept -- see constants.py's own comment on data_products for why
    this uses different terminology on purpose)."""
    settings = _load_admin_settings()
    return {"data_products": settings.get("data_products") or []}


@mcp.tool()
def get_privacy_coverage_map() -> dict[str, Any]:
    """Data-subject-rights/privacy locator: which Fabric
    tables contain columns matching a sensitivity category (email,
    biometric, academic record, disciplinary record, financial, guardian/
    family data, etc.), one row per table with EVERY matched category
    attached -- unlike get_sensitivity_overview, which repeats the same
    table once per category it matches. Built for "where does this kind of
    data live, so I know where to look" questions (e.g. a GDPR/FERPA/CCPA
    access or objection request) -- this is a LOCATOR, never a
    personal-data puller: it can tell you a table might hold disciplinary
    records, never show a specific person's actual row (this project has
    never read/indexed row-level personal data). Most of what a real
    data-subject-rights request touches -- physical biometric access
    control, a CRM, a marketing platform -- very likely lives outside this
    Fabric tenant entirely; this only ever covers the Fabric-hosted
    slice."""
    return purview_insights._get_privacy_coverage_map(settings=_load_admin_settings())


@mcp.tool()
def get_privacy_framework_map() -> dict[str, Any]:
    """Same privacy locator data as get_privacy_coverage_map, grouped by
    legal FRAMEWORK first (GDPR, GDPR special category, GDPR criminal/
    disciplinary, FERPA, CCPA/CPRA), then by category,
    for "what data do we have under GDPR" / "which categories fall under
    FERPA" questions. A table appears under EVERY framework/category it
    matches (unlike the per-object coverage map, this is deliberately NOT
    deduplicated -- the same table genuinely being both a GDPR
    special-category concern AND a CCPA one is real and worth showing
    under both). Also folds in admin-maintained "known systems" per
    category (config/admin_settings.json's privacy_external_systems), so a
    category with zero Fabric matches (biometric, voice_recording -- see
    sensitivity_classifier.py's own notes on those) can still surface a
    documented external system and its owner/contact."""
    return purview_insights._get_privacy_framework_map(settings=_load_admin_settings())


@mcp.tool()
def get_execution_stats(query: str, limit: int = 10) -> dict[str, Any]:
    """Get run history stats for item(s) matching a name -- run count,
    success/failure/cancelled counts, and min/avg/median/max duration per
    job type (backend/scripts/06_discover_executions.ps1's aggregated
    output, not the raw per-run log).

    Args:
        query: Case-insensitive substring matched against item_name.
        limit: Max matching item+job_type rows to return.
    """
    rows = _read_csv(REPO_ROOT / "analysis" / "execution_duration_by_item.csv")
    if not rows:
        return {"found": False, "reason": "analysis/execution_duration_by_item.csv not built yet -- run backend/scripts/06_discover_executions.ps1."}

    needle = _norm(query)
    matches = [row for row in rows if needle in _norm(row.get("item_name", ""))]
    return {
        "found": len(matches) > 0,
        "total_matches": len(matches),
        "items": [
            {
                "workspace_name": row.get("workspace_name", ""),
                "item_name": row.get("item_name", ""),
                "item_type": row.get("item_type", ""),
                "job_type": row.get("job_type", ""),
                "run_count": row.get("run_count", ""),
                "completed_count": row.get("completed_count", ""),
                "failed_count": row.get("failed_count", ""),
                "cancelled_count": row.get("cancelled_count", ""),
                "scheduled_count": row.get("scheduled_count", ""),
                "manual_count": row.get("manual_count", ""),
                "avg_duration_seconds": row.get("avg_duration_seconds", ""),
                "median_duration_seconds": row.get("median_duration_seconds", ""),
                "max_duration_seconds": row.get("max_duration_seconds", ""),
                "last_status": row.get("last_status", ""),
                "latest_start_time": row.get("latest_start_time", ""),
            }
            for row in matches[:limit]
        ],
    }


@mcp.tool()
def get_failure_hotspots(limit: int = 20) -> list[dict[str, str]]:
    """List the items with the worst run-failure rates tenant-wide, already
    ranked (backend/scripts/07_optimize_orchestration.ps1's output) -- the
    direct answer to "what's failing the most" without recomputing rates
    from the raw execution log.

    Args:
        limit: Max items to return, worst-failure-rate first.
    """
    rows = _read_csv(REPO_ROOT / "analysis" / "failure_hotspots.csv")
    return [
        {
            "workspace_name": row.get("workspace_name", ""),
            "item_name": row.get("item_name", ""),
            "item_type": row.get("item_type", ""),
            "job_type": row.get("job_type", ""),
            "run_count": row.get("run_count", ""),
            "failed_count": row.get("failed_count", ""),
            "failure_rate": row.get("failure_rate", ""),
            "last_status": row.get("last_status", ""),
            "latest_start_time": row.get("latest_start_time", ""),
        }
        for row in rows[:limit]
    ]


@mcp.tool()
def get_schedules(query: str = "", workspace_name: str = "") -> dict[str, Any]:
    """List configured run schedules for items, optionally filtered by item
    name and/or workspace (backend/scripts/07_optimize_orchestration.ps1's
    aggregated schedule review, not the raw per-schedule log).

    Args:
        query: Optional case-insensitive substring matched against item_name.
        workspace_name: Optional case-insensitive substring matched against
            workspace_name.
    """
    rows = _read_csv(REPO_ROOT / "analysis" / "schedule_review_candidates.csv")
    if not rows:
        return {"found": False, "reason": "analysis/schedule_review_candidates.csv not built yet -- run backend/scripts/06_discover_executions.ps1 then 07_optimize_orchestration.ps1."}

    needle = _norm(query)
    workspace_needle = _norm(workspace_name)
    matches = [
        row
        for row in rows
        if (not needle or needle in _norm(row.get("item_name", "")))
        and (not workspace_needle or workspace_needle in _norm(row.get("workspace_name", "")))
    ]
    return {
        "found": len(matches) > 0,
        "total_matches": len(matches),
        "items": [
            {
                "workspace_name": row.get("workspace_name", ""),
                "item_name": row.get("item_name", ""),
                "item_type": row.get("item_type", ""),
                "enabled_schedules": row.get("enabled_schedules", ""),
                "disabled_schedules": row.get("disabled_schedules", ""),
                "schedule_times": row.get("schedule_times", ""),
                "schedule_timezones": row.get("schedule_timezones", ""),
                "run_count": row.get("run_count", ""),
                "failed_count": row.get("failed_count", ""),
                "avg_duration_seconds": row.get("avg_duration_seconds", ""),
            }
            for row in matches
        ],
    }


@mcp.tool()
def get_scan_status() -> dict[str, Any]:
    """Get the status of the most recent (or currently running) Fabric scan."""
    state = _read_json(SCAN_STATE_DIR / "state.json") or {}
    progress = _read_json(SCAN_STATE_DIR / "progress.json") or {}
    return {
        "status": state.get("status", "unknown"),
        "scan_id": state.get("scan_id", ""),
        "workspace": state.get("workspace", ""),
        "started_at": state.get("started_at", ""),
        "ended_at": state.get("ended_at", ""),
        "duration_seconds": state.get("duration_seconds"),
        "last_error": state.get("last_error"),
        "started_by_email": state.get("started_by_email", ""),
        "progress": {
            "completed_steps": progress.get("completed_steps"),
            "total_steps": progress.get("total_steps"),
            "current_step_name": progress.get("current_step_name", ""),
            "phase": progress.get("phase", ""),
        },
        # Requests waiting behind the scan above, if any -- see
        # get_scan_queue() for the same list on its own.
        "queue": _queue_snapshot(),
    }


@mcp.tool()
def get_scan_queue() -> list[dict[str, Any]]:
    """List requests waiting for the current scan to finish,
    in the order they'll start. Empty when nothing is queued -- most of the
    time, since a request only queues instead of starting immediately when
    another scan is already running. Each entry's position is 1-based, so
    position 1 is next."""
    return _queue_snapshot()


@mcp.tool()
def trigger_scan(workspace_name: str, api_key: str = "") -> dict[str, Any]:
    """Start a scan of one Fabric workspace. Fire-and-forget: returns
    immediately with a scan_id, well before the scan itself finishes (it can
    take minutes) -- poll get_scan_status() and compare its scan_id to know
    when THIS scan (not a later one someone else started) has ended. If
    another scan is already running, this queues instead of failing --
    check the returned "queued" flag (and "position") rather than assuming
    the scan started immediately.

    Args:
        workspace_name: Must exactly match a workspace_name already in
            index/workspaces.csv (see list_workspaces).
        api_key: An API key created in the admin panel's "API Keys" tab.
            Required unless the server has allow_anonymous_scans enabled.
    """
    key_name, error = _resolve_api_key_name(api_key)
    if error:
        return error
    result, scan_error = _start_scan(workspace_name, session=None, api_key_name=key_name)
    if scan_error:
        return {"started": False, "error": scan_error["error"], "message": _SCAN_ERROR_STATUS.get(scan_error["error"], scan_error.get("message", ""))}
    queued = result.get("status") == "queued"
    return {"started": not queued, "queued": queued, **result}


@mcp.tool()
def trigger_full_scan(api_key: str = "") -> dict[str, Any]:
    """Start a full tenant scan (every workspace this server's shared Azure
    CLI session can see). Fire-and-forget, same scan_id contract as
    trigger_scan -- this can take several hours. If another scan is already
    running, this queues instead of failing -- see trigger_scan's note on
    the "queued"/"position" fields in the response.

    Args:
        api_key: An API key created in the admin panel's "API Keys" tab.
            Required unless the server has allow_anonymous_scans enabled.
    """
    key_name, error = _resolve_api_key_name(api_key)
    if error:
        return error
    result, scan_error = _start_full_scan(session=None, api_key_name=key_name)
    if scan_error:
        return {"started": False, "error": scan_error["error"], "message": _SCAN_ERROR_STATUS.get(scan_error["error"], scan_error.get("message", ""))}
    queued = result.get("status") == "queued"
    return {"started": not queued, "queued": queued, **result}


@mcp.tool()
def stop_scan(api_key: str = "") -> dict[str, Any]:
    """Stop the currently running scan, if any. A valid api_key can stop
    any scan regardless of who/what started it.

    Args:
        api_key: An API key created in the admin panel's "API Keys" tab.
    """
    key_name, error = _resolve_api_key_name(api_key)
    if error:
        return error
    result, scan_error = _stop_scan(session=None, api_key_name=key_name)
    if scan_error:
        return {"stopped": False, "error": scan_error["error"], "message": _SCAN_ERROR_STATUS.get(scan_error["error"], scan_error.get("message", ""))}
    return {"stopped": True, **result}


if __name__ == "__main__":
    mcp.run(transport="stdio")
