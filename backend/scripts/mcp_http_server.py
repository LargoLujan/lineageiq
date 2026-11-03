#!/usr/bin/env python3
"""MCP server exposed over the standard "Streamable HTTP" remote transport
(2026-08-24) -- the piece mcp_server.py (local, stdio) and
mcp_server_remote.py (stdio, but calling a remote REST API) were both
missing: something a HOSTED AI product (ChatGPT Connectors, Claude's
remote-connector settings, or any other MCP-compliant client that only
knows how to reach a URL, not spawn a local process) can actually add by
URL. Local/stdio-only was never going to work for those -- a consumer AI
product's servers can't launch a subprocess on someone's laptop.

Runs as its own subprocess, spawned by lineage_web_server.py's main() and
bound to 127.0.0.1 only (see _spawn_mcp_http_server there) -- never
reachable directly. lineage_web/handler.py reverse-proxies any request
under /mcp on the PUBLIC port straight through to this internal one, so
the whole thing is reachable at exactly one clean, already-public URL
(https://<the same host the web viewer is on>/mcp) with no second port to
open on a tunnel/firewall/Render service.

Same 18 read/write tools as mcp_server_remote.py, same REST-API-over-HTTP
implementation (BASE_URL, stdlib urllib) -- the one real design
difference: NO per-tool api_key parameter. A remote HTTP MCP surface is
naturally a persistent, authenticated CONNECTION (the client sends
Authorization: Bearer <key> on every request, exactly like any other
Bearer-token API), so the key belongs at that layer, not as something the
calling LLM has to remember to pass into every single tool call. See
_ApiKeyAuthMiddleware below: it validates the incoming key against this
project's existing admin-issued API keys (config/admin_settings.json,
the exact same list POST /api/admin/api-keys writes to and the REST API
itself checks) BEFORE any MCP request is even parsed, and stashes the
validated raw key in a contextvar every tool implementation reads to
authenticate its own downstream call to the REST API. No OAuth: this
project has no authorization server to issue tokens from, and FastMCP's
own token_verifier/AuthSettings plumbing is built specifically for
verifying tokens issued by a real separate OAuth IdP -- forcing that on
for a single self-issued static key would need standing up a fake OAuth
server for no real benefit. A static Bearer key is a well-understood,
widely-supported simpler alternative for exactly this shape of
deployment (see docs/110_mcp_remote_setup.md for the honest tradeoff and
per-client registration notes).

Run directly for a smoke test:
    FABRIC_LINEAGE_API_BASE_URL=http://127.0.0.1:8765 python3 backend/scripts/mcp_http_server.py --port 8766
Then POST a JSON-RPC "initialize" message to http://127.0.0.1:8766/mcp
with an Authorization: Bearer <a real admin-issued key> header.
"""

from __future__ import annotations

import argparse
import contextvars
import functools
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from mcp.server.fastmcp import FastMCP

from lineage_web.admin_settings import _load_admin_settings
from lineage_web.auth import _valid_api_key

BASE_URL = (os.environ.get("FABRIC_LINEAGE_API_BASE_URL") or "http://127.0.0.1:8765").rstrip("/")

mcp = FastMCP("fabric-lineage-http")

# Set by _ApiKeyAuthMiddleware for the lifetime of one HTTP request, read by
# every tool below when it makes its own downstream REST API call --
# contextvars are per-asyncio-Task, so concurrent requests on the shared
# Starlette/uvicorn event loop never see each other's key (verified
# 2026-08-24 against Starlette's own request-scoped Task model).
_current_api_key: contextvars.ContextVar[str] = contextvars.ContextVar("current_api_key", default="")
# The validated key's own NAME (not the raw key -- never logged/stored),
# for _tracked_tool's usage-analytics event below. Set alongside
# _current_api_key by the same middleware.
_current_key_name: contextvars.ContextVar[str] = contextvars.ContextVar("current_key_name", default="")


def _tracked_tool(fn):
    """Wraps a plain function in @mcp.tool() (same as calling mcp.tool()(fn)
    directly) plus a best-effort usage-analytics event -- see analytics.
    record_usage_event's own 2026-08-25 comment on why "mcp_tool_call"
    reuses bronze_usage_events' existing 5 columns rather than a new table.
    Recorded BEFORE the tool body runs, not after: this is "did an agent
    ask for this", not "did it succeed" -- a downstream REST call failing
    doesn't make the tool call itself less real usage to have visibility
    into. Never lets a tracking failure break the actual tool call, same
    contract record_usage_event already documents for its own callers.

    functools.wraps (not a hand-rolled __name__/__doc__ copy) matters here
    specifically because it sets __wrapped__, which inspect.signature()
    follows automatically -- FastMCP's own @mcp.tool() introspects the
    wrapped function's signature to build each tool's JSON schema, so a
    wrapper that lost the real (typed, defaulted) parameter list would
    make every tool below appear to take arbitrary **kwargs instead of its
    real arguments."""
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        try:
            from lineage_web.analytics import record_usage_event
            key_name = _current_key_name.get() or "?"
            record_usage_event("mcp_tool_call", fn.__name__, "mcp_tool", {"user_email": f"mcp:{key_name}"})
        except Exception:  # noqa: BLE001 - analytics must never break a real tool call
            pass
        return fn(*args, **kwargs)
    return mcp.tool()(wrapper)


def _request(method: str, path: str, params: dict[str, Any] | None = None, body: dict[str, Any] | None = None) -> dict[str, Any]:
    url = BASE_URL + path
    query = {k: str(v) for k, v in (params or {}).items() if v not in ("", None)}
    if query:
        url += "?" + urllib.parse.urlencode(query)

    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    api_key = _current_api_key.get()
    if api_key:
        req.add_header("X-Api-Key", api_key)

    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        try:
            return json.loads(exc.read().decode("utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            return {"error": "http_error", "message": f"{exc.code} {exc.reason}"}
    except urllib.error.URLError as exc:
        return {"error": "connection_failed", "message": f"Could not reach {BASE_URL}: {exc.reason}"}


@_tracked_tool
def list_workspaces(name_contains: str = "") -> list[dict[str, str]]:
    """List Fabric workspaces this project has scanned.

    Args:
        name_contains: Optional case-insensitive substring filter on
            workspace_name. Empty returns every workspace.
    """
    result = _request("GET", "/api/workspaces", params={"name_contains": name_contains})
    return result.get("workspaces", [])


@_tracked_tool
def search_items(query: str, item_type: str = "", limit: int = 20) -> list[dict[str, str]]:
    """Find items by (partial) name -- e.g. "orders", "NB_Load_CRM", "bi_sales".

    Args:
        query: Case-insensitive substring matched against item_name and qualified_name.
        item_type: Optional exact item_type filter (Report, SemanticModel, Notebook, DataPipeline, Lakehouse, etc.).
        limit: Max rows to return.
    """
    result = _request("GET", "/api/items", params={"query": query, "item_type": item_type, "limit": limit})
    return result.get("items", [])


@_tracked_tool
def get_item_lineage(qualified_name: str) -> dict[str, Any]:
    """Get one item's metadata plus its direct upstream and downstream dependencies.

    Args:
        qualified_name: Exact "workspace / item_type / item_name" qualified name, or a
            partial item name -- if the match isn't exact and unique, this returns
            candidates instead of lineage so the caller can retry with the right
            qualified_name (use search_items to find it first if unsure).
    """
    return _request("GET", "/api/item-lineage", params={"qualified_name": qualified_name})


@_tracked_tool
def get_object_impact(query: str, limit: int = 5) -> dict[str, Any]:
    """Find source object(s) (table/view/etc.) by name and report what depends on them.

    Args:
        query: Case-insensitive substring matched against the object's display name.
        limit: Max matching objects to return full detail for.
    """
    return _request("GET", "/api/objects", params={"query": query, "limit": limit})


@_tracked_tool
def get_notebook_code(qualified_name: str, max_chars: int = 60000) -> dict[str, Any]:
    """Read a notebook's actual downloaded source code, plus the read/write/execute
    operations already parsed out of it line-by-line.

    Args:
        qualified_name: Exact or partial notebook name (see search_items).
        max_chars: Truncates very large notebooks; check "truncated" in the response
            and narrow the request rather than raising this indefinitely.
    """
    return _request("GET", "/api/notebook-code", params={"qualified_name": qualified_name, "max_chars": max_chars})


@_tracked_tool
def get_business_glossary() -> dict[str, Any]:
    """Get the admin-curated business glossary -- real business terms linked to the
    real qualified_names that represent them."""
    return _request("GET", "/api/business-glossary")


@_tracked_tool
def get_column_profile(workspace_name: str, lakehouse_name: str, table_name: str) -> dict[str, Any]:
    """Get column-level statistics (null %, distinct count, safe min/max -- never a
    raw identifying value) for a Fabric-native Lakehouse table, if it's been
    profiled. Coverage is partial by design: "found: false" means "not profiled
    yet", not "doesn't exist".

    Args:
        workspace_name: Exact workspace name.
        lakehouse_name: Exact Lakehouse item name.
        table_name: Exact table name, e.g. "dbo.MyTable".
    """
    return _request("GET", "/api/column-profile", params={
        "workspace_name": workspace_name, "lakehouse_name": lakehouse_name, "table_name": table_name,
    })


@_tracked_tool
def get_column_sensitivity(workspace_name: str, lakehouse_name: str, table_name: str) -> dict[str, Any]:
    """Get content-based sensitivity signals (email/phone/national_id/financial match
    PERCENTAGES only, never a raw value) for a Fabric-native Lakehouse table. Same
    partial-coverage contract as get_column_profile.

    Args:
        workspace_name: Exact workspace name.
        lakehouse_name: Exact Lakehouse item name.
        table_name: Exact table name, e.g. "dbo.MyTable".
    """
    return _request("GET", "/api/column-sensitivity", params={
        "workspace_name": workspace_name, "lakehouse_name": lakehouse_name, "table_name": table_name,
    })


@_tracked_tool
def get_related_elements(qualified_name: str, direction: str = "both", max_hops: int = 2, limit: int = 100) -> dict[str, Any]:
    """Find items related to one item within a bounded number of hops, using a
    prebuilt relationship index -- fast even for a highly-connected hub.

    Args:
        qualified_name: Exact or partial item name (see search_items).
        direction: "upstream" (what this item depends on), "downstream" (what
            depends on this item), or "both".
        max_hops: How many relationship hops to follow (1 = direct only, matching
            get_item_lineage; 2+ reaches indirect dependencies).
        limit: Max related items to return per direction.
    """
    return _request("GET", "/api/related-elements", params={
        "qualified_name": qualified_name, "direction": direction, "max_hops": max_hops, "limit": limit,
    })


@_tracked_tool
def get_objects_for_item(qualified_name: str) -> dict[str, Any]:
    """Get the full source-object footprint (tables/views/stored procedures/files)
    one item reads or writes -- the same detail Graph Map Mode's "show objects"
    button reveals.

    Args:
        qualified_name: Exact or partial item name (see search_items).
    """
    return _request("GET", "/api/objects-for-item", params={"qualified_name": qualified_name})


@_tracked_tool
def get_workspace_roles(workspace_name: str) -> dict[str, Any]:
    """List who has access to a workspace and with what role (Admin/Member/
    Contributor/Viewer), from the tenant's real Fabric role assignments.

    Args:
        workspace_name: Exact or case-insensitive-substring workspace name.
    """
    return _request("GET", "/api/workspace-roles", params={"workspace_name": workspace_name})


@_tracked_tool
def get_access_audit() -> dict[str, Any]:
    """Who has access to which workspace and with what role, tenant-wide --
    plus a ranked "who is Admin in the most workspaces" view. Broader than
    get_workspace_roles (one workspace at a time)."""
    return _request("GET", "/api/admin/access-audit")


@_tracked_tool
def get_governance_scan_overview() -> dict[str, Any]:
    """Sensitivity labels, endorsement, tags, and semantic model RLS roles
    from the Fabric/Power BI Admin Scanner API, plus the scan's own
    diagnostic status list. {found: False, reason} if never run."""
    return _request("GET", "/api/admin/governance-scan")


@_tracked_tool
def get_sensitivity_overview(sample_limit: int = 15) -> dict[str, Any]:
    """Tenant-wide count of catalogued source objects whose columns match a
    sensitivity pattern BY NAME (email, national ID, financial, etc.), by
    category -- unconfirmed against real values, see
    get_content_sensitivity_overview for the content-verified counterpart.
    Each sample row includes workspace_name for cross-referencing with
    get_workspace_roles to answer "who can see this sensitive data".

    Args:
        sample_limit: Max example object rows to include per category.
    """
    return _request("GET", "/api/admin/sensitivity-overview", params={"sample_limit": sample_limit})


@_tracked_tool
def get_content_sensitivity_overview(sample_limit: int = 15) -> dict[str, Any]:
    """Tenant-wide count of columns with a CONTENT-verified sensitivity match
    (regex against a bounded sample of real cell values, never the raw
    values themselves), by category -- scoped to the Fabric-native
    Lakehouse tables NB_Discover_Column_Sensitivity.py has profiled, a
    subset of the whole tenant.

    Args:
        sample_limit: Max example object/column rows to include per category.
    """
    return _request("GET", "/api/admin/content-sensitivity-overview", params={"sample_limit": sample_limit})


@_tracked_tool
def get_data_quality_overview() -> dict[str, Any]:
    """Tenant-wide evaluation of every admin-defined data-quality rule
    against dbo.bronze_column_profile -- pass/fail/not_profiled counts
    and a pass_rate that excludes not_profiled rules from the
    denominator. {found: False, reason} if no rule has been defined
    yet."""
    return _request("GET", "/api/admin/data-quality-overview")


@_tracked_tool
def get_data_quality_for_table(workspace_name: str, lakehouse_name: str, table_name: str) -> dict[str, Any]:
    """Evaluate whatever data-quality rules target one Fabric-native
    Lakehouse table, if any. {found: False} means no rule targets this
    table yet, not that the table is missing.

    Args:
        workspace_name: Exact workspace name.
        lakehouse_name: Exact Lakehouse item name.
        table_name: Exact table name, e.g. "dbo.MyTable".
    """
    return _request("GET", "/api/data-quality", params={
        "workspace_name": workspace_name, "lakehouse_name": lakehouse_name, "table_name": table_name,
    })


@_tracked_tool
def get_data_products() -> dict[str, Any]:
    """The admin-curated list of Purview-Unified-Catalog-style data products
    (Roadmap Fase 3): name, owner_email, description, and linked
    qualified_names. Distinct from Fabric's own native per-workspace
    "Domain" field, a different, already-scanned concept."""
    return _request("GET", "/api/data-products")


@_tracked_tool
def get_privacy_coverage_map() -> dict[str, Any]:
    """Data-subject-rights/privacy locator (Roadmap Fase 5): which Fabric
    tables contain columns matching a sensitivity category (email,
    biometric, academic record, disciplinary record, financial, guardian/
    family data, etc.), one row per table with EVERY matched category
    attached -- unlike get_sensitivity_overview, which repeats the same
    table once per category. A LOCATOR, never a personal-data puller --
    it can tell you a table might hold disciplinary records, never show a
    specific person's actual row. Most of what a real GDPR/FERPA/CCPA
    request touches (biometric access control, a CRM, a marketing
    platform) very likely lives outside this Fabric tenant entirely."""
    return _request("GET", "/api/admin/privacy-coverage-map")


@_tracked_tool
def get_privacy_framework_map() -> dict[str, Any]:
    """Same privacy locator data as get_privacy_coverage_map, grouped by
    legal FRAMEWORK first (GDPR, GDPR special category, GDPR criminal/
    disciplinary, FERPA, CCPA/CPRA), then by category (Roadmap Fase 6) --
    for "what data do we have under GDPR" questions. A table appears
    under EVERY framework/category it matches (deliberately not
    deduplicated, unlike the per-object coverage map). Also folds in
    admin-maintained "known systems" per category, so a category with
    zero Fabric matches (biometric, voice recording) can still surface a
    documented external system."""
    return _request("GET", "/api/admin/privacy-framework-map")


@_tracked_tool
def get_execution_stats(query: str, limit: int = 10) -> dict[str, Any]:
    """Get run history stats for item(s) matching a name -- run count,
    success/failure/cancelled counts, and min/avg/median/max duration per job type.

    Args:
        query: Case-insensitive substring matched against item_name.
        limit: Max matching item+job_type rows to return.
    """
    return _request("GET", "/api/execution-stats", params={"query": query, "limit": limit})


@_tracked_tool
def get_failure_hotspots(limit: int = 20) -> list[dict[str, str]]:
    """List the items with the worst run-failure rates tenant-wide, already ranked.

    Args:
        limit: Max items to return, worst-failure-rate first.
    """
    result = _request("GET", "/api/failure-hotspots", params={"limit": limit})
    return result.get("hotspots", [])


@_tracked_tool
def get_schedules(query: str = "", workspace_name: str = "") -> dict[str, Any]:
    """List configured run schedules for items, optionally filtered by item name
    and/or workspace.

    Args:
        query: Optional case-insensitive substring matched against item_name.
        workspace_name: Optional case-insensitive substring matched against workspace_name.
    """
    return _request("GET", "/api/schedules", params={"query": query, "workspace_name": workspace_name})


@_tracked_tool
def get_scan_status() -> dict[str, Any]:
    """Get the status of the most recent (or currently running) Fabric scan,
    including scan_id (compare against trigger_scan/trigger_full_scan's result to
    confirm you're watching the run you started)."""
    return _request("GET", "/api/status")


@_tracked_tool
def trigger_scan(workspace_name: str) -> dict[str, Any]:
    """Start a scan of one Fabric workspace. Fire-and-forget: returns immediately
    with a scan_id, well before the scan itself finishes -- poll get_scan_status()
    and compare its scan_id to know when THIS scan has ended.

    Args:
        workspace_name: Must exactly match a workspace_name already known to this
            project (see list_workspaces).
    """
    result = _request("POST", "/api/scan", body={"workspace": workspace_name})
    return {"started": "error" not in result, **result}


@_tracked_tool
def trigger_full_scan() -> dict[str, Any]:
    """Start a full tenant scan. Fire-and-forget, same scan_id contract as
    trigger_scan -- this can take several hours."""
    result = _request("POST", "/api/scan-full")
    return {"started": "error" not in result, **result}


@_tracked_tool
def stop_scan() -> dict[str, Any]:
    """Stop the currently running scan, if any."""
    result = _request("POST", "/api/scan-stop")
    return {"stopped": "error" not in result, **result}


def _extract_bearer_or_api_key(headers: dict[bytes, bytes]) -> str:
    auth_header = headers.get(b"authorization", b"").decode("latin-1")
    if auth_header.lower().startswith("bearer "):
        candidate = auth_header[len("bearer "):].strip()
        if candidate:
            return candidate
    return headers.get(b"x-api-key", b"").decode("latin-1").strip()


class _ApiKeyAuthMiddleware:
    """Plain ASGI middleware (no Starlette/FastAPI dependency needed) wrapping
    the whole FastMCP Starlette app -- validates BEFORE any MCP/JSON-RPC
    parsing happens, so an invalid or missing key never reaches tool
    routing at all. Non-"http" scopes (lifespan, in particular -- see
    streamable_http_app()'s own `lifespan=lambda app: self.session_manager.
    run()`) pass straight through untouched; intercepting those would
    break the session manager's startup/shutdown.
    """

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        headers = dict(scope.get("headers") or [])
        api_key = _extract_bearer_or_api_key(headers)
        name, _scope_value = _valid_api_key(api_key, _load_admin_settings()) if api_key else (None, None)
        if not name:
            body = json.dumps({
                "error": "invalid_api_key",
                "message": "Send a valid admin-issued API key as 'Authorization: Bearer <key>' (created in the admin panel's API Keys tab).",
            }).encode("utf-8")
            await send({
                "type": "http.response.start",
                "status": 401,
                "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode("latin-1")),
                    (b"www-authenticate", b'Bearer realm="fabric-lineage-mcp"'),
                ],
            })
            await send({"type": "http.response.body", "body": body})
            return

        token = _current_api_key.set(api_key)
        name_token = _current_key_name.set(name)
        try:
            await self.app(scope, receive, send)
        finally:
            _current_api_key.reset(token)
            _current_key_name.reset(name_token)


def build_app():
    """Returns the auth-wrapped ASGI app -- split out from __main__ so a test
    (or an ASGI runner other than uvicorn.run) can import and mount it
    directly instead of only running this file as a script."""
    return _ApiKeyAuthMiddleware(mcp.streamable_http_app())


if __name__ == "__main__":
    import uvicorn

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1", help="Bind host -- keep this 127.0.0.1 (default) unless you have your own reverse proxy/TLS in front; lineage_web_server.py's own /mcp proxy already assumes localhost-only.")
    parser.add_argument("--port", type=int, default=int(os.environ.get("MCP_HTTP_PORT", 8766)))
    args = parser.parse_args()

    # mcp.streamable_http_app() binds host/port from mcp.settings, which
    # only matters for its (unused here) transport_security localhost
    # defaults -- the actual bind address/port for uvicorn.run below is
    # what's really in effect.
    mcp.settings.host = args.host
    mcp.settings.port = args.port

    uvicorn.run(build_app(), host=args.host, port=args.port, log_level="warning")
