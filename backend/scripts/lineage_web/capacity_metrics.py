"""Live reads against the Microsoft Fabric Capacity Metrics app's own
semantic model -- the ONE place real CU (Capacity Unit) consumption
actually lives. Confirmed: neither the Fabric REST API nor
anything this project already scans (bronze_workspaces, bronze_items, ...)
ever carries CU usage -- see purview_insights._get_capacity_insight's own
"CU (mes)" column, which has always shown "No disponible" with a tooltip
saying exactly this. The Capacity Metrics app is a first-party template
app (installed from Fabric's "Apps" catalog, or the admin portal), not
something `fab`/the Fabric REST API can provision -- see app.js's
renderAdminCapacityMetricsConfigCard for the manual install-help steps
this module can't automate away.

Auth mirrors fabric_pipeline.py's `_get_token` exactly (delegated session
token first, service-principal client-credentials fallback), just against
the Power BI resource (`https://analysis.windows.net/powerbi/api/.default`)
instead of the Fabric API resource -- executeQueries (DAX over REST) is a
Power BI API, not a Fabric API, even though the dataset itself lives in a
Fabric workspace.
"""
import json
import threading
import time
import urllib.error
import urllib.request

POWERBI_API_BASE_URL = "https://api.powerbi.com/v1.0/myorg"
POWERBI_TOKEN_SCOPES = ["https://analysis.windows.net/powerbi/api/.default"]

_TOKEN_LIFETIME_ASSUMPTION_SECONDS = 55 * 60
_TOKEN_REFRESH_MARGIN_SECONDS = 5 * 60
_token_lock = threading.Lock()
_token_cache = {"access_token": "", "expires_at": 0.0}


class CapacityMetricsError(Exception):
    pass


def _fields_present(config):
    return bool((config or {}).get("workspace_id") and (config or {}).get("dataset_id"))


def _sp_fields_present(config):
    return bool((config or {}).get("sp_client_id") and (config or {}).get("sp_client_secret_ref"))


def _acquire_delegated_powerbi_token(session, settings):
    """Same "reuse the signed-in admin's own MSAL cache, no re-prompt"
    trick as fabric_pipeline._acquire_delegated_fabric_token -- just a
    different resource scope. Returns "" (never raises) on any failure;
    callers fall back to the service-principal path, same degrade-not-
    crash contract as every other scoped-token acquisition in this
    project."""
    if not session:
        return ""
    from .auth import _acquire_scoped_token
    token = _acquire_scoped_token(session, settings, POWERBI_TOKEN_SCOPES)
    return token or ""


def _acquire_sp_powerbi_token(settings, config):
    import os

    try:
        import msal
    except ImportError as exc:  # pragma: no cover - msal is a pinned dependency
        raise CapacityMetricsError("msal is not installed -- run `pip install -r requirements-web.txt`.") from exc

    tenant_id = config.get("sp_tenant_id") or settings.get("tenant_id") or ""
    client_id = config.get("sp_client_id") or ""
    secret_ref = config.get("sp_client_secret_ref") or ""
    client_secret = os.environ.get(secret_ref, "") if secret_ref else ""
    if not (tenant_id and client_id and client_secret):
        raise CapacityMetricsError(
            "Service principal isn't fully configured -- tenant/client id or the "
            f"{secret_ref or '<sp_client_secret_ref>'} environment variable is missing."
        )
    app = msal.ConfidentialClientApplication(
        client_id,
        authority=f"https://login.microsoftonline.com/{tenant_id}",
        client_credential=client_secret,
    )
    result = app.acquire_token_for_client(scopes=POWERBI_TOKEN_SCOPES)
    if not result or "access_token" not in result:
        description = (result or {}).get("error_description", "no access_token returned")
        raise CapacityMetricsError(f"Could not acquire a Power BI token: {description}")
    return result["access_token"]


def _get_token(settings, config, session=None):
    """Delegated session token first (see _acquire_delegated_powerbi_token),
    service principal as a cached fallback -- same shape as fabric_pipeline.
    _get_token, module-level cache included so a live overview fetch on
    every admin-panel page load doesn't mint a fresh SP token every time."""
    if session:
        delegated_token = _acquire_delegated_powerbi_token(session, settings)
        if delegated_token:
            return delegated_token

    with _token_lock:
        now = time.time()
        if _token_cache["access_token"] and now < _token_cache["expires_at"] - _TOKEN_REFRESH_MARGIN_SECONDS:
            return _token_cache["access_token"]
        if not _sp_fields_present(config):
            raise CapacityMetricsError(
                "No usable signed-in session and no service principal configured for the Capacity Metrics "
                "connection -- sign in, or fill in a service principal, on the Capacidad tab."
            )
        token = _acquire_sp_powerbi_token(settings, config)
        _token_cache["access_token"] = token
        _token_cache["expires_at"] = now + _TOKEN_LIFETIME_ASSUMPTION_SECONDS
        return token


def _execute_dax(token, workspace_id, dataset_id, dax_query):
    """POST .../groups/{workspace_id}/datasets/{dataset_id}/executeQueries
    -- returns (rows, error). rows is a list of plain dicts with the exact
    column aliases/bracketed names DAX returns (e.g. "Capacities[Capacity
    name]" or "[CU_s_sum]" for an aliased measure); callers strip the
    prefix themselves rather than this function guessing a rename
    convention that might not fit every query shape."""
    url = f"{POWERBI_API_BASE_URL}/groups/{workspace_id}/datasets/{dataset_id}/executeQueries"
    body = json.dumps({
        "queries": [{"query": dax_query}],
        "serializerSettings": {"includeNulls": True},
    }).encode("utf-8")
    request = urllib.request.Request(
        url, data=body, method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        return None, f"Power BI API returned {exc.code}: {detail[:500]}"
    except urllib.error.URLError as exc:
        return None, f"Could not reach the Power BI API: {exc.reason}"
    try:
        return payload["results"][0]["tables"][0]["rows"], None
    except (KeyError, IndexError):
        return [], None


def _strip_bracket_prefix(row):
    """{"Capacities[Capacity name]": "contosof64", "[CU_s_sum]": 123.4} ->
    {"Capacity name": "contosof64", "CU_s_sum": 123.4} -- every DAX
    executeQueries column key is either "Table[Column]" (a real model
    column) or "[Alias]" (a SUMMARIZECOLUMNS-computed one); this project
    only ever needs the trailing bracketed name, never which table it
    came from."""
    cleaned = {}
    for key, value in row.items():
        if "[" in key and key.endswith("]"):
            cleaned[key[key.index("[") + 1:-1]] = value
        else:
            cleaned[key] = value
    return cleaned


def test_connection(config, session=None):
    """Verifies a capacity_metrics config (workspace_id/dataset_id + auth)
    without persisting anything -- same "test the form, not just what's
    saved" contract as fabric_pipeline.test_connection/onelake_data.
    test_connection. Runs the smallest real query that proves both
    connectivity AND that this is genuinely the Capacity Metrics model
    (a real Lakehouse/Warehouse dataset would 400 on Capacities/Items,
    which don't exist outside this specific app's schema)."""
    from .admin_settings import _load_admin_settings

    settings = _load_admin_settings()
    if not _fields_present(config):
        return {"ok": False, "message": "Missing fields: workspace or semantic model."}
    try:
        token = _get_token(settings, config, session=session)
    except CapacityMetricsError as exc:
        return {"ok": False, "message": str(exc)}
    rows, error = _execute_dax(
        token, config["workspace_id"], config["dataset_id"],
        "EVALUATE TOPN(5, SELECTCOLUMNS(Capacities, \"Capacity name\", Capacities[Capacity name], \"SKU\", Capacities[SKU]))",
    )
    if error:
        return {"ok": False, "message": error}
    names = ", ".join(sorted({_strip_bracket_prefix(row).get("Capacity name", "") for row in rows} - {""}))
    return {"ok": True, "message": f"Conecta correctamente. Capacidades visibles: {names or '(ninguna)'}"}


def discover_installation(session, settings):
    """Best-effort auto-discovery of an already-installed Capacity Metrics
    app, for the "Auto-detect" button -- works whether this is
    a brand-new tenant where an admin just finished the manual install, or
    an existing one where it's been there for a year (same UI either way,
    per the admin panel's own capacity-tab help block). Needs the signed-in
    admin's OWN delegated access (never the service principal -- discovery
    is about what THIS PERSON can already see, the same reasoning
    _fetch_my_workspaces uses everywhere else in this project), so returns
    {"found": False, ...} outright with no session, rather than silently
    trying a service-principal path that would answer a different question.

    Filters candidate workspaces by name containing "capacity" (case-
    insensitive) before checking datasets -- a large tenant can have
    hundreds of workspaces, so checking
    every one's datasets one by one would be both slow and mostly pointless
    scanning of workspaces that could never be it. A tenant that renamed
    its Capacity Metrics workspace to something with no "capacity" in the
    name won't be found this way -- the admin can still fill in the
    workspace/dataset by name or id manually, same fallback every other
    picker in this project already has."""
    if not session:
        return {"found": False, "reason": "No active admin session to browse your workspaces."}
    from .auth import _acquire_scoped_token
    from .constants import FABRIC_TOKEN_SCOPES
    from .fabric_api import _fetch_my_workspaces

    fabric_token = _acquire_scoped_token(session, settings, FABRIC_TOKEN_SCOPES) or session.get("access_token")
    if not fabric_token:
        return {"found": False, "reason": "Could not get a Fabric token for your session."}
    workspaces, error = _fetch_my_workspaces(fabric_token)
    if error or not workspaces:
        return {"found": False, "reason": error or "No accessible workspaces were found."}

    powerbi_token = _acquire_delegated_powerbi_token(session, settings)
    if not powerbi_token:
        return {"found": False, "reason": "Could not get a Power BI token for your session."}

    candidates = [w for w in workspaces if "capacity" in w["workspace_name"].lower()]
    for workspace in candidates:
        url = f"{POWERBI_API_BASE_URL}/groups/{workspace['workspace_id']}/datasets"
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {powerbi_token}"})
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except (urllib.error.HTTPError, urllib.error.URLError):
            continue
        for dataset in payload.get("value") or []:
            if "capacity metrics" in (dataset.get("name") or "").lower():
                return {
                    "found": True,
                    "workspace_name": workspace["workspace_name"],
                    "workspace_id": workspace["workspace_id"],
                    "dataset_name": dataset.get("name") or "",
                    "dataset_id": dataset.get("id") or "",
                }
    return {
        "found": False,
        "reason": (
            "None of the workspaces you can access has \"capacity\" in its name and a \"Fabric Capacity Metrics\" "
            "semantic model. If the app is installed under another name, enter the workspace and the "
            "semantic model by hand."
        ),
    }


_TOP_ITEMS_DAX = """
EVALUATE
TOPN(
    {limit},
    SUMMARIZECOLUMNS(
        Capacities[Capacity name],
        Items[Workspace name],
        Items[Item name],
        Items[Item kind],
        Items[Users],
        "CU_s_sum", SUM('Metrics By Item'[CU (s)]),
        "Operations", SUM('Metrics By Item'[Operations]),
        "ThrottlingMin", SUM('Metrics By Item'[Throttling (min)])
    ),
    [CU_s_sum], DESC
)
""".strip()

_CAPACITY_TOTALS_DAX = """
EVALUATE
ADDCOLUMNS(
    Capacities,
    "CU_s_sum", CALCULATE(SUM('Metrics By Item'[CU (s)])),
    "Operations", CALCULATE(SUM('Metrics By Item'[Operations]))
)
""".strip()

_RECENT_USERS_DAX = "EVALUATE TOPN(50, VALUES('Item History User List'[User]))"

# Placeholder rows this project's own manual exploration found
# mixed in among real identities: a genuinely blank user, and the two
# literal strings the app itself uses for a background/system-triggered
# operation with nobody to attribute it to. Not real people -- dropped
# from recent_users rather than shown as if they were.
_NON_USER_PLACEHOLDERS = {"", "system", "user"}


def _clean_user_identity(raw):
    """<euii>alice@contoso.com</euii> -> alice@contoso.com (the "encrypted
    user identifiable information" wrapper Purview/Fabric applies to some
    identity fields when a sensitivity label requires it) -- everything else (real emails, service-
    principal "app:<guid>@<tenant>" strings, bare GUIDs) is passed through
    unchanged for the admin to recognize or not."""
    value = (raw or "").strip()
    if value.startswith("<euii>") and value.endswith("</euii>"):
        value = value[len("<euii>"):-len("</euii>")]
    return value


def get_overview(config, session=None, top_item_limit=30):
    """The actual payload behind the admin panel's Capacidad tab once
    configured: per-capacity name/SKU/region/owners/total CU, the top N
    items by CU consumed (with workspace/kind/operations/throttling), and a
    best-effort recent-users list -- see this module's own docstring for
    why none of this has ever been available anywhere else in this
    project. Degrades to {"found": False, "reason": ...} on any failure
    (not configured, auth failure, DAX error) rather than raising -- same
    contract as every other *_overview/_get_* function admin-panel tabs
    already read from."""
    from .admin_settings import _load_admin_settings

    settings = _load_admin_settings()
    if not _fields_present(config):
        return {"found": False, "reason": "not_configured"}
    try:
        token = _get_token(settings, config, session=session)
    except CapacityMetricsError as exc:
        return {"found": False, "reason": str(exc)}

    capacity_rows, error = _execute_dax(token, config["workspace_id"], config["dataset_id"], _CAPACITY_TOTALS_DAX)
    if error:
        return {"found": False, "reason": error}
    capacities = []
    for row in capacity_rows:
        clean = _strip_bracket_prefix(row)
        capacities.append({
            "capacity_name": clean.get("Capacity name") or "",
            "sku": clean.get("SKU") or "",
            "region": clean.get("Region") or "",
            "state": clean.get("State") or "",
            "owners": clean.get("Owners") or "",
            "cu_seconds": clean.get("CU_s_sum") or 0,
            "operations": clean.get("Operations") or 0,
        })
    capacities.sort(key=lambda c: c["cu_seconds"], reverse=True)

    item_rows, error = _execute_dax(
        token, config["workspace_id"], config["dataset_id"],
        _TOP_ITEMS_DAX.format(limit=max(1, min(top_item_limit, 200))),
    )
    if error:
        return {"found": False, "reason": error}
    top_items = []
    for row in item_rows:
        clean = _strip_bracket_prefix(row)
        top_items.append({
            "capacity_name": clean.get("Capacity name") or "",
            "workspace_name": clean.get("Workspace name") or "",
            "item_name": clean.get("Item name") or "",
            "item_kind": clean.get("Item kind") or "",
            "users": clean.get("Users"),
            "cu_seconds": clean.get("CU_s_sum") or 0,
            "operations": clean.get("Operations") or 0,
            "throttling_minutes": clean.get("ThrottlingMin") or 0,
        })

    recent_users = []
    user_rows, user_error = _execute_dax(token, config["workspace_id"], config["dataset_id"], _RECENT_USERS_DAX)
    if not user_error:
        seen = set()
        for row in user_rows:
            clean = _strip_bracket_prefix(row)
            # The bracketed key case doesn't always match the column's own
            # [Name] property -- confirmed: this specific query
            # comes back as "...[user]" (lowercase) even though INFO.VIEW.
            # COLUMNS() reports the column's Name as "User". DAX/AS column
            # names are inherently case-insensitive; relying on exact JSON
            # key casing here would be fragile, so this checks both.
            identity = _clean_user_identity(clean.get("User") or clean.get("user"))
            if identity.casefold() in _NON_USER_PLACEHOLDERS or identity.casefold() in seen:
                continue
            seen.add(identity.casefold())
            recent_users.append(identity)
        recent_users.sort(key=str.casefold)

    return {
        "found": True,
        "capacities": capacities,
        "top_items": top_items,
        "recent_users": recent_users,
    }


def cu_seconds_by_capacity(config, session=None):
    """Just the {capacity_name: cu_seconds} half of get_overview, for
    handler.py to fold into /api/admin/capacity-insight's existing table
    (replacing its long-standing "No disponible" CU column) without that
    route paying for the top-items/recent-users queries it doesn't use.
    Returns {} on any failure -- same best-effort contract as every other
    live-enrichment merge in that handler (see _fetch_capacities' own
    call site there)."""
    if not _fields_present(config):
        return {}
    from .admin_settings import _load_admin_settings

    settings = _load_admin_settings()
    try:
        token = _get_token(settings, config, session=session)
    except CapacityMetricsError:
        return {}
    rows, error = _execute_dax(token, config["workspace_id"], config["dataset_id"], _CAPACITY_TOTALS_DAX)
    if error:
        return {}
    result = {}
    for row in rows:
        clean = _strip_bracket_prefix(row)
        name = clean.get("Capacity name") or ""
        if name:
            result[name] = clean.get("CU_s_sum") or 0
    return result
