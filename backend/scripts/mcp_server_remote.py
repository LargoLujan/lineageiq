#!/usr/bin/env python3
"""MCP server exposing this project's lineage catalog to AI agents over the
secured REST API -- a second server alongside mcp_server.py,
not a replacement for it (see mcp_server.py's own docstring: it stays as
"the simple, always-available local option"). Use this one instead when the
MCP client and the running lineage_web_server.py aren't the same machine
(or the same filesystem checkout), e.g. a colleague pointing their own
Claude Code at a shared/deployed instance rather than a local clone with a
fresh scan already on disk.

Every tool has the exact same name and signature as mcp_server.py's, plus an
optional trailing api_key param on the read tools that call the REST API's
catalog routes -- those now require a signed-in session or a valid API
key (see docs/102_admin_panel_and_user_auth.md), which has no
equivalent in mcp_server.py's direct-file-access tools since there's no HTTP
request to authenticate there. An agent already configured against the local
server doesn't need reconfiguring to switch to this one, or vice versa, as
long as it wasn't relying on positional args past the pre-existing ones.
The one other honest difference: this server's list_workspaces returns
whatever GET /api/workspaces returns
(workspace_name/environment/capacity_region/status), while the local
server's list_workspaces reads index/workspaces.csv directly and also
includes capacity_name/domain_name/owner -- REST /api/workspaces predates
this MCP catalog and already has its own established consumer (the web
viewer's scan-trigger dropdown), so narrowing its response to match here
would be the wrong fix; this is documented, not silently inconsistent.

api_key is a per-CALL argument, not a server-startup/env-var identity
(so the whole company can use it): this server can be run
once, pointed at the deployed instance, and reused by any number of
colleagues/agents, each supplying their own admin-issued key on every
call -- rather than baking one fixed identity into how the process was
launched. This matters so that any authenticated agent can
connect: the server itself grants nothing; the REST API is what
checks the key on every single request, the exact same way it already
checks a Fabric pipeline's X-Api-Key header.

Also included alongside the three read tools above: get_business_
glossary, get_column_profile, get_column_sensitivity -- covering the
catalog surfaces this server didn't expose yet (the admin-curated
glossary, and the two Fabric-native column enrichment tables).

Added later the same day: get_related_elements, get_objects_for_item,
get_workspace_roles, get_execution_stats, get_failure_hotspots,
get_schedules -- the 6 tools that used to be local-only in mcp_server.py
(reading index/*.csv/analysis/*.csv/graph-map-index-objects.json
directly), now that catalog.py has REST-exposed equivalents (see
routes.py). Every tool this server exposes now matches mcp_server.py's
full tool surface (minus get_scan_queue, which has no REST route since
the scan queue is already visible inside get_scan_status's own "queue"
field here).

No local file access, no direct import of lineage_web -- every tool is a
plain HTTP call (stdlib urllib, no extra dependency) to a
lineage_web_server.py instance's /api/* surface, whose base URL comes from
--base-url or the FABRIC_LINEAGE_API_BASE_URL env var (defaults to
http://127.0.0.1:8765, i.e. talking to a locally-running server over HTTP
instead of reading its files directly -- useful on its own for verifying
this server's behavior matches mcp_server.py's).

Run directly for a smoke test: `python3 backend/scripts/mcp_server_remote.py
--base-url http://127.0.0.1:8765` (stdio mode, waits for an MCP client).
Register with Claude Code via `claude mcp add fabric-lineage-remote --
python3 <path-to-this-file> --base-url <url>` (see README).
"""

from __future__ import annotations

import argparse
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from mcp.server.fastmcp import FastMCP

BASE_URL = (os.environ.get("FABRIC_LINEAGE_API_BASE_URL") or "http://127.0.0.1:8765").rstrip("/")

mcp = FastMCP("fabric-lineage-remote")


def _request(method: str, path: str, params: dict[str, Any] | None = None, body: dict[str, Any] | None = None, api_key: str = "") -> dict[str, Any]:
    url = BASE_URL + path
    query = {k: str(v) for k, v in (params or {}).items() if v not in ("", None)}
    if query:
        url += "?" + urllib.parse.urlencode(query)

    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if api_key:
        req.add_header("X-Api-Key", api_key)

    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        # The REST API always returns a JSON error body even on 4xx/5xx
        # (see handler.py's _send_json) -- surface that structured error to
        # the agent instead of raising, same shape callers already expect
        # from mcp_server.py's local tools on a failure.
        try:
            return json.loads(exc.read().decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return {"error": "http_error", "message": f"{exc.code} {exc.reason}"}
    except urllib.error.URLError as exc:
        return {"error": "connection_failed", "message": f"Could not reach {BASE_URL}: {exc.reason}"}


@mcp.tool()
def list_workspaces(name_contains: str = "", api_key: str = "") -> list[dict[str, str]]:
    """List Fabric workspaces this project has scanned (via the REST API).

    Args:
        name_contains: Optional case-insensitive substring filter on
            workspace_name. Empty returns every workspace.
        api_key: An API key created in the admin panel's "API Keys" tab
            (reads require a signed-in session or a valid key).
    """
    result = _request("GET", "/api/workspaces", params={"name_contains": name_contains}, api_key=api_key)
    return result.get("workspaces", [])


@mcp.tool()
def search_items(query: str, item_type: str = "", limit: int = 20, api_key: str = "") -> list[dict[str, str]]:
    """Find items by (partial) name -- e.g. "orders", "NB_Load_CRM", "bi_sales".

    Args:
        query: Case-insensitive substring matched against item_name and
            qualified_name.
        item_type: Optional exact item_type filter (Report, SemanticModel,
            Notebook, DataPipeline, Lakehouse, etc.).
        limit: Max rows to return.
        api_key: An API key created in the admin panel's "API Keys" tab
            (reads require a signed-in session or a valid key).
    """
    result = _request("GET", "/api/items", params={"query": query, "item_type": item_type, "limit": limit}, api_key=api_key)
    return result.get("items", [])


@mcp.tool()
def get_item_lineage(qualified_name: str, api_key: str = "") -> dict[str, Any]:
    """Get one item's metadata plus its direct upstream and downstream dependencies.

    Args:
        qualified_name: Exact "workspace / item_type / item_name" qualified
            name, or a partial item name -- if the match isn't exact and
            unique, this returns candidates instead of lineage so the
            caller can retry with the right qualified_name (use
            search_items to find it first if unsure).
        api_key: An API key created in the admin panel's "API Keys" tab
            (reads require a signed-in session or a valid key).
    """
    return _request("GET", "/api/item-lineage", params={"qualified_name": qualified_name}, api_key=api_key)


@mcp.tool()
def get_object_impact(query: str, limit: int = 5, api_key: str = "") -> dict[str, Any]:
    """Find source object(s) (table/view/etc.) by name and report what depends on them.

    Args:
        query: Case-insensitive substring matched against the object's
            display name (e.g. "orders", "DATAMART_SALES").
        limit: Max matching objects to return full detail for.
        api_key: An API key created in the admin panel's "API Keys" tab
            (reads require a signed-in session or a valid key).
    """
    return _request("GET", "/api/objects", params={"query": query, "limit": limit}, api_key=api_key)


@mcp.tool()
def get_notebook_code(qualified_name: str, max_chars: int = 60000, api_key: str = "") -> dict[str, Any]:
    """Read a notebook's actual downloaded source code, plus the read/write/
    execute operations already parsed out of it line-by-line -- for
    understanding what a notebook really does instead of only its lineage
    edges (via the REST API).

    Args:
        qualified_name: Exact or partial notebook name (see search_items).
        max_chars: Truncates very large notebooks; check "truncated" in the
            response and narrow the request rather than raising this
            indefinitely.
        api_key: An API key created in the admin panel's "API Keys" tab
            (reads require a signed-in session or a valid key).
    """
    return _request("GET", "/api/notebook-code", params={"qualified_name": qualified_name, "max_chars": max_chars}, api_key=api_key)


@mcp.tool()
def get_business_glossary(api_key: str = "") -> dict[str, Any]:
    """Get the admin-curated business glossary -- real business terms (not
    this tool's own technical concepts) linked to the real qualified_names
    that represent them (via the REST API).

    Args:
        api_key: An API key created in the admin panel's "API Keys" tab
            (reads now require a signed-in session or a valid key).
    """
    return _request("GET", "/api/business-glossary", api_key=api_key)


@mcp.tool()
def get_column_profile(workspace_name: str, lakehouse_name: str, table_name: str, api_key: str = "") -> dict[str, Any]:
    """Get column-level statistics (null %, distinct count, safe min/max --
    never a raw identifying value) for a Fabric-native Lakehouse table, if
    it's been profiled (via the REST API). Coverage is partial by design --
    only Lakehouses in workspaces the service's own
    identity already had a data role in when profiled -- a "found: false"
    response means "not profiled yet", not "doesn't exist".

    Args:
        workspace_name: Exact workspace name.
        lakehouse_name: Exact Lakehouse item name.
        table_name: Exact table name, e.g. "dbo.MyTable".
        api_key: An API key created in the admin panel's "API Keys" tab.
    """
    return _request("GET", "/api/column-profile", params={
        "workspace_name": workspace_name, "lakehouse_name": lakehouse_name, "table_name": table_name,
    }, api_key=api_key)


@mcp.tool()
def get_column_sensitivity(workspace_name: str, lakehouse_name: str, table_name: str, api_key: str = "") -> dict[str, Any]:
    """Get content-based sensitivity signals (email/phone/national_id/
    financial match PERCENTAGES only, never a raw value) for a Fabric-
    native Lakehouse table (via the REST API). Same partial-coverage
    contract as get_column_profile -- "found: false" means "not checked
    yet".

    Args:
        workspace_name: Exact workspace name.
        lakehouse_name: Exact Lakehouse item name.
        table_name: Exact table name, e.g. "dbo.MyTable".
        api_key: An API key created in the admin panel's "API Keys" tab.
    """
    return _request("GET", "/api/column-sensitivity", params={
        "workspace_name": workspace_name, "lakehouse_name": lakehouse_name, "table_name": table_name,
    }, api_key=api_key)


@mcp.tool()
def get_related_elements(qualified_name: str, direction: str = "both", max_hops: int = 2, limit: int = 100, api_key: str = "") -> dict[str, Any]:
    """Find items related to one item within a bounded number of hops, using
    a prebuilt relationship index (via the REST API) -- fast even for a
    highly-connected hub, and doesn't walk the entire reachable graph like
    get_item_lineage's full traversal would for a distant multi-hop
    question.

    Args:
        qualified_name: Exact or partial item name (see search_items).
        direction: "upstream" (what this item depends on), "downstream"
            (what depends on this item), or "both".
        max_hops: How many relationship hops to follow (1 = direct only,
            matching get_item_lineage; 2+ reaches indirect dependencies).
        limit: Max related items to return per direction.
        api_key: An API key created in the admin panel's "API Keys" tab
            (reads require a signed-in session or a valid key).
    """
    return _request("GET", "/api/related-elements", params={
        "qualified_name": qualified_name, "direction": direction, "max_hops": max_hops, "limit": limit,
    }, api_key=api_key)


@mcp.tool()
def get_objects_for_item(qualified_name: str, api_key: str = "") -> dict[str, Any]:
    """Get the full source-object footprint (tables/views/stored procedures/
    files) one item reads or writes (via the REST API) -- the same detail
    Graph Map Mode's "show objects" button reveals.

    Args:
        qualified_name: Exact or partial item name (see search_items).
        api_key: An API key created in the admin panel's "API Keys" tab
            (reads require a signed-in session or a valid key).
    """
    return _request("GET", "/api/objects-for-item", params={"qualified_name": qualified_name}, api_key=api_key)


@mcp.tool()
def get_workspace_roles(workspace_name: str, api_key: str = "") -> dict[str, Any]:
    """List who has access to a workspace and with what role (Admin/Member/
    Contributor/Viewer), from the tenant's real Fabric role assignments
    (via the REST API).

    Args:
        workspace_name: Exact or case-insensitive-substring workspace name.
        api_key: An API key created in the admin panel's "API Keys" tab
            (reads require a signed-in session or a valid key).
    """
    return _request("GET", "/api/workspace-roles", params={"workspace_name": workspace_name}, api_key=api_key)


@mcp.tool()
def get_access_audit(api_key: str = "") -> dict[str, Any]:
    """Who has access to which workspace and with what role, tenant-wide --
    plus a ranked "who is Admin in the most workspaces" view (via the REST
    API). Broader than get_workspace_roles (one workspace at a time).

    Args:
        api_key: An API key created in the admin panel's "API Keys" tab.
            This route requires an admin session or a valid key -- unlike
            the plain catalog reads above, there is no anonymous fallback.
    """
    return _request("GET", "/api/admin/access-audit", api_key=api_key)


@mcp.tool()
def get_governance_scan_overview(api_key: str = "") -> dict[str, Any]:
    """Sensitivity labels, endorsement, tags, and semantic model RLS roles
    from the Fabric/Power BI Admin Scanner API (via the REST API), plus
    the scan's own diagnostic status list. {found: False, reason} if
    never run.

    Args:
        api_key: An API key created in the admin panel's "API Keys" tab.
            This route requires an admin session or a valid key.
    """
    return _request("GET", "/api/admin/governance-scan", api_key=api_key)


@mcp.tool()
def get_sensitivity_overview(sample_limit: int = 15, api_key: str = "") -> dict[str, Any]:
    """Tenant-wide count of catalogued source objects whose columns match a
    sensitivity pattern BY NAME (email, national ID, financial, etc.), by
    category (via the REST API) -- unconfirmed against real values, see
    get_content_sensitivity_overview for the content-verified counterpart.
    Each sample row includes workspace_name for cross-referencing with
    get_workspace_roles to answer "who can see this sensitive data".

    Args:
        sample_limit: Max example object rows to include per category.
        api_key: An API key created in the admin panel's "API Keys" tab.
            This route requires an admin session or a valid key.
    """
    return _request("GET", "/api/admin/sensitivity-overview", params={"sample_limit": sample_limit}, api_key=api_key)


@mcp.tool()
def get_content_sensitivity_overview(sample_limit: int = 15, api_key: str = "") -> dict[str, Any]:
    """Tenant-wide count of columns with a CONTENT-verified sensitivity match
    (regex against a bounded sample of real cell values, never the raw
    values themselves), by category (via the REST API) -- scoped to the
    Fabric-native Lakehouse tables NB_Discover_Column_Sensitivity.py has
    profiled, a subset of the whole tenant.

    Args:
        sample_limit: Max example object/column rows to include per category.
        api_key: An API key created in the admin panel's "API Keys" tab.
            This route requires an admin session or a valid key.
    """
    return _request("GET", "/api/admin/content-sensitivity-overview", params={"sample_limit": sample_limit}, api_key=api_key)


@mcp.tool()
def get_data_quality_overview(api_key: str = "") -> dict[str, Any]:
    """Tenant-wide evaluation of every admin-defined data-quality rule
     against dbo.bronze_column_profile (via the REST API)
    -- pass/fail/not_profiled counts and a pass_rate that excludes
    not_profiled rules from the denominator. {found: False, reason} if no
    rule has been defined yet.

    Args:
        api_key: An API key created in the admin panel's "API Keys" tab.
            This route requires an admin session or a valid key.
    """
    return _request("GET", "/api/admin/data-quality-overview", api_key=api_key)


@mcp.tool()
def get_data_quality_for_table(workspace_name: str, lakehouse_name: str, table_name: str, api_key: str = "") -> dict[str, Any]:
    """Evaluate whatever data-quality rules target one Fabric-native
    Lakehouse table, if any (via the REST API). {found: False} means no
    rule targets this table yet, not that the table is missing.

    Args:
        workspace_name: Exact workspace name.
        lakehouse_name: Exact Lakehouse item name.
        table_name: Exact table name, e.g. "dbo.MyTable".
        api_key: An API key created in the admin panel's "API Keys" tab
            (reads now require a signed-in session or a valid key).
    """
    return _request("GET", "/api/data-quality", params={
        "workspace_name": workspace_name, "lakehouse_name": lakehouse_name, "table_name": table_name,
    }, api_key=api_key)


@mcp.tool()
def get_data_products(api_key: str = "") -> dict[str, Any]:
    """The admin-curated list of Purview-Unified-Catalog-style data products
    (via the REST API): name, owner_email, description,
    and linked qualified_names. Distinct from Fabric's own native
    per-workspace "Domain" field, a different, already-scanned concept.

    Args:
        api_key: An API key created in the admin panel's "API Keys" tab
            (reads now require a signed-in session or a valid key).
    """
    return _request("GET", "/api/data-products", api_key=api_key)


@mcp.tool()
def get_privacy_coverage_map(api_key: str = "") -> dict[str, Any]:
    """Data-subject-rights/privacy locator (via the REST
    API): which Fabric tables contain columns matching a sensitivity
    category (email, biometric, academic record, disciplinary record,
    financial, guardian/family data, etc.), one row per table with EVERY
    matched category attached -- unlike get_sensitivity_overview, which
    repeats the same table once per category. A LOCATOR, never a
    personal-data puller -- it can tell you a table might hold
    disciplinary records, never show a specific person's actual row. Most
    of what a real GDPR/FERPA/CCPA request touches (biometric access
    control, a CRM, a marketing platform) very likely lives outside this
    Fabric tenant entirely.

    Args:
        api_key: An API key created in the admin panel's "API Keys" tab.
            This route requires an admin session or a valid key.
    """
    return _request("GET", "/api/admin/privacy-coverage-map", api_key=api_key)


@mcp.tool()
def get_privacy_framework_map(api_key: str = "") -> dict[str, Any]:
    """Same privacy locator data as get_privacy_coverage_map, grouped by
    legal FRAMEWORK first (GDPR, GDPR special category, GDPR criminal/
    disciplinary, FERPA, CCPA/CPRA), then by category (via the
    REST API) -- for "what data do we have under GDPR" questions.
    A table appears under EVERY framework/category it matches
    (deliberately not deduplicated, unlike the per-object coverage map).
    Also folds in admin-maintained "known systems" per category, so a
    category with zero Fabric matches (biometric, voice recording) can
    still surface a documented external system.

    Args:
        api_key: An API key created in the admin panel's "API Keys" tab.
            This route requires an admin session or a valid key.
    """
    return _request("GET", "/api/admin/privacy-framework-map", api_key=api_key)


@mcp.tool()
def get_execution_stats(query: str, limit: int = 10, api_key: str = "") -> dict[str, Any]:
    """Get run history stats for item(s) matching a name -- run count,
    success/failure/cancelled counts, and min/avg/median/max duration per
    job type (via the REST API).

    Args:
        query: Case-insensitive substring matched against item_name.
        limit: Max matching item+job_type rows to return.
        api_key: An API key created in the admin panel's "API Keys" tab
            (reads require a signed-in session or a valid key).
    """
    return _request("GET", "/api/execution-stats", params={"query": query, "limit": limit}, api_key=api_key)


@mcp.tool()
def get_failure_hotspots(limit: int = 20, api_key: str = "") -> list[dict[str, str]]:
    """List the items with the worst run-failure rates tenant-wide, already
    ranked (via the REST API) -- the direct answer to "what's failing the
    most" without recomputing rates from the raw execution log.

    Args:
        limit: Max items to return, worst-failure-rate first.
        api_key: An API key created in the admin panel's "API Keys" tab
            (reads require a signed-in session or a valid key).
    """
    result = _request("GET", "/api/failure-hotspots", params={"limit": limit}, api_key=api_key)
    return result.get("hotspots", [])


@mcp.tool()
def get_schedules(query: str = "", workspace_name: str = "", api_key: str = "") -> dict[str, Any]:
    """List configured run schedules for items, optionally filtered by item
    name and/or workspace (via the REST API).

    Args:
        query: Optional case-insensitive substring matched against item_name.
        workspace_name: Optional case-insensitive substring matched against
            workspace_name.
        api_key: An API key created in the admin panel's "API Keys" tab
            (reads require a signed-in session or a valid key).
    """
    return _request("GET", "/api/schedules", params={"query": query, "workspace_name": workspace_name}, api_key=api_key)


@mcp.tool()
def get_scan_status() -> dict[str, Any]:
    """Get the status of the most recent (or currently running) Fabric scan,
    including scan_id (compare against trigger_scan/trigger_full_scan's
    result to confirm you're watching the run you started)."""
    return _request("GET", "/api/status")


@mcp.tool()
def trigger_scan(workspace_name: str, api_key: str = "") -> dict[str, Any]:
    """Start a scan of one Fabric workspace via the REST API. Fire-and-forget:
    returns immediately with a scan_id, well before the scan itself finishes
    -- poll get_scan_status() and compare its scan_id to know when THIS scan
    (not a later one someone else started) has ended.

    Args:
        workspace_name: Must exactly match a workspace_name already in
            index/workspaces.csv (see list_workspaces).
        api_key: An API key created in the admin panel's "API Keys" tab.
            Required unless the server has allow_anonymous_scans enabled.
    """
    result = _request("POST", "/api/scan", body={"workspace": workspace_name}, api_key=api_key)
    return {"started": "error" not in result, **result}


@mcp.tool()
def trigger_full_scan(api_key: str = "") -> dict[str, Any]:
    """Start a full tenant scan via the REST API. Fire-and-forget, same
    scan_id contract as trigger_scan -- this can take several hours.

    Args:
        api_key: An API key created in the admin panel's "API Keys" tab.
            Required unless the server has allow_anonymous_scans enabled.
    """
    result = _request("POST", "/api/scan-full", api_key=api_key)
    return {"started": "error" not in result, **result}


@mcp.tool()
def stop_scan(api_key: str = "") -> dict[str, Any]:
    """Stop the currently running scan, if any, via the REST API. A valid
    api_key can stop any scan regardless of who/what started it.

    Args:
        api_key: An API key created in the admin panel's "API Keys" tab.
    """
    result = _request("POST", "/api/scan-stop", api_key=api_key)
    return {"stopped": "error" not in result, **result}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=None, help="Base URL of a running lineage_web_server.py instance (default: FABRIC_LINEAGE_API_BASE_URL env var, or http://127.0.0.1:8765).")
    args, _unknown = parser.parse_known_args()
    if args.base_url:
        BASE_URL = args.base_url.rstrip("/")
    mcp.run(transport="stdio")
