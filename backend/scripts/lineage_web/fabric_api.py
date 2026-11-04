"""Per-user Fabric REST calls (the signed-in user's own delegated token, never a shared session).

Split out of lineage_web_server.py -- pure code motion,
no logic changed from the original.
"""
import json

from .constants import FABRIC_API_BASE_URL


def _fetch_my_workspaces(access_token):
    import urllib.error
    import urllib.request

    request = urllib.request.Request(
        f"{FABRIC_API_BASE_URL}/workspaces",
        headers={"Authorization": f"Bearer {access_token}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        return None, f"Fabric API returned {exc.code}: {detail[:300]}"
    except urllib.error.URLError as exc:
        return None, f"Could not reach the Fabric API: {exc.reason}"

    # Same field names 01_discover_workspaces.ps1 already reads from this
    # exact endpoint (displayName/name, id/workspaceId, capacityId, type) --
    # kept consistent so a workspace name here always matches the one that
    # ends up in index/workspaces.csv once actually scanned.
    raw_workspaces = payload.get("value", payload if isinstance(payload, list) else [])
    workspaces = [
        {
            "workspace_name": item.get("displayName") or item.get("name") or "",
            "workspace_id": item.get("id") or item.get("workspaceId") or "",
            "capacity_id": item.get("capacityId") or "",
            "type": item.get("type") or "",
        }
        for item in raw_workspaces
    ]
    workspaces.sort(key=lambda item: item["workspace_name"].lower())
    return workspaces, None


def _fetch_all_tenant_workspaces(access_token):
    """The tenant-wide list, via the Fabric ADMIN API
    (`/v1/admin/workspaces`) instead of the regular delegated one
    `_fetch_my_workspaces` calls -- only succeeds for a signed-in user who
    actually holds the "Fabric Administrator" Entra ID role (confirmed live
    The same call with a non-admin token returns a 403
    InsufficientScopes, which callers should treat as "not an admin, fall
    back to _fetch_my_workspaces" rather than a hard error). Filtered to
    type=Workspace&state=Active server-side -- excludes every user's
    PersonalGroup ("My workspace") entries (which the tenant otherwise has
    one of per person, not a meaningful scan target) and non-Active ones
    (Orphaned/Deleted/Removing), so the caller never has to filter those out
    itself. Paginated via continuationToken, per Microsoft's documented
    contract for this endpoint (up to 10,000 records/page)."""
    import urllib.error
    import urllib.parse
    import urllib.request

    workspaces = []
    continuation_token = None
    while True:
        query = {"type": "Workspace", "state": "Active"}
        if continuation_token:
            query["continuationToken"] = continuation_token
        url = f"{FABRIC_API_BASE_URL}/admin/workspaces?{urllib.parse.urlencode(query)}"
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {access_token}"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
            return None, f"Fabric API returned {exc.code}: {detail[:300]}"
        except urllib.error.URLError as exc:
            return None, f"Could not reach the Fabric API: {exc.reason}"

        # The admin endpoint's own shape: a `workspaces` array (not `value`,
        # unlike the regular /workspaces endpoint _fetch_my_workspaces
        # reads) with a plain `name` field (not `displayName`).
        for item in payload.get("workspaces") or []:
            workspaces.append({
                "workspace_name": item.get("name") or "",
                "workspace_id": item.get("id") or "",
                "capacity_id": item.get("capacityId") or "",
                "type": item.get("type") or "",
            })
        continuation_token = payload.get("continuationToken")
        if not continuation_token:
            break

    workspaces.sort(key=lambda item: item["workspace_name"].lower())
    return workspaces, None


def _fetch_capacities(access_token):
    """The tenant's Fabric capacities with real display names --
    unlike workspace/item listings, capacities DO carry a human name, just
    from a different endpoint (`/v1/capacities`, the CORE api, not
    `/v1/admin/...`) than the one already used elsewhere in this file.
    Needs the delegated `Capacity.Read.All` scope; per Microsoft's own docs
    this returns capacities the signed-in user can access as either admin
    or contributor -- not gated behind the "Fabric Administrator" Entra
    role like _fetch_all_tenant_workspaces is. Callers should treat a
    failure here as "names unavailable", not fatal -- the capacity insight
    tab already has a raw-id fallback label for exactly this case."""
    import urllib.error
    import urllib.parse
    import urllib.request

    capacities = []
    continuation_token = None
    while True:
        query = {"continuationToken": continuation_token} if continuation_token else {}
        url = f"{FABRIC_API_BASE_URL}/capacities" + (f"?{urllib.parse.urlencode(query)}" if query else "")
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {access_token}"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
            return None, f"Fabric API returned {exc.code}: {detail[:300]}"
        except urllib.error.URLError as exc:
            return None, f"Could not reach the Fabric API: {exc.reason}"

        for item in payload.get("value") or []:
            capacities.append({
                "capacity_id": item.get("id") or "",
                "capacity_name": item.get("displayName") or "",
                "sku": item.get("sku") or "",
                "region": item.get("region") or "",
                "state": item.get("state") or "",
            })
        continuation_token = payload.get("continuationToken")
        if not continuation_token:
            break

    capacities.sort(key=lambda item: item["capacity_name"].lower())
    return capacities, None


def _fetch_connections(access_token):
    """Fabric Connections (for assigning a real gateway-backed
    connection to an external source) -- `GET /v1/connections`, needs the
    delegated Connection.Read.All scope. Returned unfiltered by type: this
    project's own EXTERNAL_SOURCE_TYPES labels (sql_server, postgresql,
    snowflake, ...) don't reliably map 1:1 onto Fabric's own connector type
    strings, so filtering here risks hiding the very connection an admin
    is looking for -- the picker shows connectivity_type/connection_type
    as context instead and lets a human pick. Same best-effort contract as
    _fetch_capacities: a failure here just means the picker shows no
    options, never fatal to the page."""
    import urllib.error
    import urllib.parse
    import urllib.request

    connections = []
    continuation_token = None
    while True:
        query = {"continuationToken": continuation_token} if continuation_token else {}
        url = f"{FABRIC_API_BASE_URL}/connections" + (f"?{urllib.parse.urlencode(query)}" if query else "")
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {access_token}"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                payload = json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
            return None, f"Fabric API returned {exc.code}: {detail[:300]}"
        except urllib.error.URLError as exc:
            return None, f"Could not reach the Fabric API: {exc.reason}"

        for item in payload.get("value") or []:
            details = item.get("connectionDetails") or {}
            connections.append({
                "connection_id": item.get("id") or "",
                "connection_name": item.get("displayName") or "",
                "connectivity_type": item.get("connectivityType") or "",
                "connection_type": details.get("type") or "",
                "connection_path": details.get("path") or "",
                "gateway_id": item.get("gatewayId") or "",
            })
        continuation_token = payload.get("continuationToken")
        if not continuation_token:
            break

    connections.sort(key=lambda item: item["connection_name"].lower())
    return connections, None


def _test_fabric_connection(access_token, connection_id):
    """POST /v1/connections/{id}/testConnection -- the only
    documented way to verify an assigned Fabric Connection can actually
    reach its source THROUGH the gateway. This project's older "Probar
    conexión" button always connects directly from wherever this server
    runs, which can never succeed for an on-premises source sitting behind
    a gateway -- that's the whole reason a gateway is needed in the first
    place. This asks the gateway itself, via Fabric, whether IT can reach
    the source.

    Long-running per Fabric's own LRO contract (https://learn.microsoft.com
    /en-us/rest/api/fabric/articles/long-running-operation): a 202 means
    poll the Location URL for {status: Running|Succeeded|Failed} (the
    OPERATION's status), then GET {location}/result once Succeeded for the
    real {status: Online|Offline, errors} payload (the CONNECTION's
    status) -- two different "status" fields at two different stages, easy
    to conflate. Bounded to ~60s total since this runs synchronously inside
    one admin request (ThreadingHTTPServer gives each connection its own
    thread, so blocking here doesn't stall other requests).

    Returns ({"status": "Online"|"Offline", "errors": [...]}, None) on
    success, or (None, error_message) on any failure -- callers should
    show error_message directly, never crash on it."""
    import time
    import urllib.error
    import urllib.request

    def _get(url):
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {access_token}"})
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
            return json.loads(body) if body else {}, response.headers

    url = f"{FABRIC_API_BASE_URL}/connections/{connection_id}/testConnection"
    request = urllib.request.Request(
        url, data=b"", method="POST",
        headers={"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            status_code = response.status
            headers = response.headers
            body = response.read()
            payload = json.loads(body) if body else {}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        return None, f"Fabric API returned {exc.code}: {detail[:300]}"
    except urllib.error.URLError as exc:
        return None, f"Could not reach the Fabric API: {exc.reason}"

    if status_code == 200:
        return payload, None
    if status_code != 202:
        return None, f"Unexpected status from testConnection: {status_code}"

    location = headers.get("Location", "")
    retry_after = int(headers.get("Retry-After") or 5)
    if not location:
        return None, "Fabric did not return an operation location to poll."

    deadline = time.time() + 60
    while time.time() < deadline:
        time.sleep(min(max(retry_after, 1), 5))
        try:
            op_payload, _op_headers = _get(location)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
            return None, f"Fabric API returned {exc.code}: {detail[:300]}"
        except urllib.error.URLError as exc:
            return None, f"Could not reach the Fabric API: {exc.reason}"
        operation_status = op_payload.get("status")
        if operation_status == "Succeeded":
            break
        if operation_status == "Failed":
            error = (op_payload.get("error") or {}).get("message") or "The connection test failed."
            return None, error
    else:
        return None, "Timed out waiting for the connection test to finish."

    try:
        result_payload, _result_headers = _get(f"{location.rstrip('/')}/result")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        return None, f"Fabric API returned {exc.code}: {detail[:300]}"
    except urllib.error.URLError as exc:
        return None, f"Could not reach the Fabric API: {exc.reason}"
    return result_payload, None


def _fetch_paged_items(access_token, workspace_id):
    """GET .../items, following `continuationUri` until it's absent --
    mirrors 03_discover_items.ps1's own Get-PagedFabricValues loop exactly
    (see that script's function of the same shape). The two per-item-type
    picker functions below used to do a single unpaginated request each;
    for any workspace with more items than fit on one page, whatever came
    after page 1 was silently invisible to the admin panel's picker -- a
    real "I don't see the Warehouse I just created" report
    traced back to exactly this."""
    import urllib.request

    items = []
    url = f"{FABRIC_API_BASE_URL}/workspaces/{workspace_id}/items"
    while url:
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {access_token}"})
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
        items.extend(payload.get("value") or [])
        next_uri = payload.get("continuationUri") or None
        # continuationUri isn't guaranteed to be a full URL -- 03_discover_
        # items.ps1's own Invoke-FabricGet defends against both shapes the
        # same way, so this does too.
        if next_uri and not next_uri.startswith("http"):
            next_uri = f"{FABRIC_API_BASE_URL.rstrip('/')}/{next_uri.lstrip('/')}"
        url = next_uri
    return items


def _fetch_items_of_type_in_workspace(access_token, workspace_id, item_type, detail_path_segment, sql_props_key):
    """Shared by _fetch_lakehouses_in_workspace/_fetch_warehouses_in_workspace
    below: same picker pattern either way (see their own docstrings) --
    fetch every item in the workspace (paginated, see _fetch_paged_items),
    filter by `type` CLIENT-side rather than the Fabric API's `?type=...`
    query parameter (03_discover_items.ps1 -- the one script in this
    project that has always reliably discovered every item type across a
    real tenant, Warehouse included, confirmed against index/items.csv --
    never uses that server-side filter either; one less untested assumption
    about what it actually does), then resolve each match's SQL endpoint
    connection string via its own per-item-type detail call."""
    import urllib.error
    import urllib.request

    def _get(url):
        request = urllib.request.Request(url, headers={"Authorization": f"Bearer {access_token}"})
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))

    try:
        all_items = _fetch_paged_items(access_token, workspace_id)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        return None, f"Fabric API returned {exc.code}: {detail[:300]}"
    except urllib.error.URLError as exc:
        return None, f"Could not reach the Fabric API: {exc.reason}"

    matches = []
    for item in all_items:
        if item.get("type") != item_type:
            continue
        item_id = item.get("id") or ""
        sql_endpoint = ""
        try:
            detail = _get(f"{FABRIC_API_BASE_URL}/workspaces/{workspace_id}/{detail_path_segment}/{item_id}")
            props = detail.get("properties") or {}
            # A Lakehouse's sqlEndpointProperties is a nested object
            # ({"connectionString": "..."}); a Warehouse's connectionInfo
            # turned out (real traceback: 'str' object has no
            # attribute 'get') to just BE the connection string itself, no
            # nesting -- handle both shapes rather than assume either.
            raw_sql_props = props.get(sql_props_key)
            if isinstance(raw_sql_props, dict):
                sql_endpoint = raw_sql_props.get("connectionString") or ""
            elif isinstance(raw_sql_props, str):
                sql_endpoint = raw_sql_props
            if not sql_endpoint:
                fallback = props.get("connectionString")
                sql_endpoint = fallback if isinstance(fallback, str) else ""
        except (urllib.error.HTTPError, urllib.error.URLError):
            # Best-effort: still list the item by name even if the detail
            # call fails (e.g. a transient error) -- the admin can always
            # fill the SQL endpoint in by hand as a fallback.
            pass
        except Exception:  # noqa: BLE001 - a shape surprise in the detail
            # response must degrade to "list it, leave the SQL endpoint
            # blank" like a network failure does above, never crash the
            # whole picker (and take every OTHER already-fetched item down
            # with it) over one item's unexpected response shape.
            pass
        matches.append({
            "lakehouse_name": item.get("displayName") or item.get("name") or "",
            "lakehouse_id": item_id,
            "sql_endpoint_connection_string": sql_endpoint,
        })
    matches.sort(key=lambda entry: entry["lakehouse_name"].lower())
    return matches, None


def _fetch_lakehouses_in_workspace(access_token, workspace_id):
    """Powers the admin panel's Lakehouse picker (see docs/102_
    admin_panel_and_user_auth.md): the operator picks a workspace and a
    Lakehouse by NAME, never by pasting an ID by hand -- this resolves the
    real ID (and the SQL analytics endpoint connection string, which only
    the per-Lakehouse detail call returns, not the plain items list) behind
    the scenes from the signed-in user's own Fabric access, the same
    pattern _fetch_my_workspaces already uses for workspaces."""
    return _fetch_items_of_type_in_workspace(access_token, workspace_id, "Lakehouse", "lakehouses", "sqlEndpointProperties")


def _fetch_warehouses_in_workspace(access_token, workspace_id):
    """Same picker pattern as _fetch_lakehouses_in_workspace: a Fabric
    Warehouse's SQL endpoint is the one Fabric item type with a genuinely
    read-write T-SQL endpoint -- a Lakehouse's SQL analytics endpoint is
    query-only, no INSERT/CREATE TABLE -- so this is what the admin panel's
    write-target picker actually needs to list. Returns the
    same {lakehouse_name, lakehouse_id, sql_endpoint_connection_string}
    shape on purpose: it lands in the exact same admin_settings.json
    "lakehouse" fields either way (see renderAdminPanel's write-target tab
    and _mirror_lakehouse_target_config), so nothing downstream needs to
    know or care which item TYPE was picked.

    A Warehouse's own detail response nests its connection string under
    properties.connectionInfo.connectionString rather than a
    sqlEndpointProperties sibling like a Lakehouse -- _fetch_items_of_type_
    in_workspace already falls back to a bare properties.connectionString
    too, in case that assumption is also wrong for some tenant/API version;
    worst case here is just an admin filling the SQL endpoint in by hand,
    same fallback the Lakehouse picker has always had."""
    return _fetch_items_of_type_in_workspace(access_token, workspace_id, "Warehouse", "warehouses", "connectionInfo")


def _fetch_workspace_role_assignments(access_token, workspace_id):
    """GET /v1/workspaces/{id}/roleAssignments -- every principal's role in
    one workspace (Admin/Member/Contributor/Viewer). Needs the caller to
    already have access to that workspace; a workspace the caller can't see
    simply 403s, which callers here treat as "role unknown", not fatal."""
    import urllib.error
    import urllib.request

    url = f"{FABRIC_API_BASE_URL}/workspaces/{workspace_id}/roleAssignments"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {access_token}"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        return None, f"Fabric API returned {exc.code}: {detail[:300]}"
    except urllib.error.URLError as exc:
        return None, f"Could not reach the Fabric API: {exc.reason}"
    return payload.get("value") or [], None


# "Contributor or admin" (the admin panel's individual-scan picker):
# the roles that mean "this person can meaningfully act on this workspace",
# not just look at it -- Viewer is deliberately excluded even though it's
# real access, since triggering a scan of a workspace someone can only view
# isn't the same kind of "yours to manage" the picker is meant to imply.
SCAN_ELIGIBLE_ROLES = {"Admin", "Member", "Contributor"}


def _filter_workspaces_by_min_role(access_token, workspaces, user_email, allowed_roles=None):
    """Narrows `workspaces` (already the caller's OWN accessible list, from
    _fetch_my_workspaces) down to the ones where their own role is in
    `allowed_roles` (default SCAN_ELIGIBLE_ROLES) -- Fabric's plain
    `/v1/workspaces` listing doesn't return the caller's role at all (only
    id/displayName/capacityId/tags, confirmed live), so this
    means one roleAssignments call per workspace to find. Matches by
    userPrincipalName, case-insensitive (Entra UPNs aren't case-sensitive
    in practice and this project already normalizes emails the same way
    elsewhere, e.g. admin_settings._email_in_allowlist). A workspace whose
    roleAssignments call fails for any reason is dropped rather than kept
    -- "can't confirm you can act on this" defaults to not showing it,
    consistent with this project's fail-closed stance on access (see
    constants.DEFAULT_ADMIN_SETTINGS's own comment on tenant_id/admin_emails
    defaulting empty rather than open)."""
    allowed = allowed_roles or SCAN_ELIGIBLE_ROLES
    normalized_email = (user_email or "").strip().lower()
    if not normalized_email:
        return []
    eligible = []
    for workspace in workspaces:
        assignments, _error = _fetch_workspace_role_assignments(access_token, workspace["workspace_id"])
        if not assignments:
            continue
        for assignment in assignments:
            principal = assignment.get("principal") or {}
            upn = ((principal.get("userDetails") or {}).get("userPrincipalName") or "").strip().lower()
            if upn == normalized_email and assignment.get("role") in allowed:
                eligible.append(workspace)
                break
    return eligible


def _fetch_data_pipelines_in_workspace(access_token, workspace_id):
    """Powers the admin panel's Fabric-pipeline tab picker: pick a
    workspace and a Data Pipeline by NAME, same picker UX _fetch_lakehouses_in_workspace/_fetch_
    warehouses_in_workspace already give the Lakehouse tab, instead of
    pasting workspace_id/pipeline_item_id GUIDs copied out of a Fabric URL
    by hand. Unlike a Lakehouse/Warehouse, a Data Pipeline has no SQL
    endpoint to resolve, so this skips _fetch_items_of_type_in_workspace's
    per-item detail call entirely -- just the plain paginated item list,
    filtered by type client-side (same reasoning as that function's own
    docstring: 03_discover_items.ps1, the one script that's always
    reliably discovered every item type, never uses the
    Fabric API's server-side ?type= filter either)."""
    import urllib.error

    try:
        all_items = _fetch_paged_items(access_token, workspace_id)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        return None, f"Fabric API returned {exc.code}: {detail[:300]}"
    except urllib.error.URLError as exc:
        return None, f"Could not reach the Fabric API: {exc.reason}"

    matches = [
        {
            "pipeline_name": item.get("displayName") or item.get("name") or "",
            "pipeline_id": item.get("id") or "",
        }
        for item in all_items
        if item.get("type") == "DataPipeline"
    ]
    matches.sort(key=lambda entry: entry["pipeline_name"].lower())
    return matches, None
