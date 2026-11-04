"""Per-user Microsoft Graph calls (the signed-in user's own profile photo),
kept separate from fabric_api.py since that module is specifically Fabric
REST, not Graph.

No new Entra app registration needed: auth._acquire_scoped_token silently
mints a Microsoft Graph token from the SAME account already signed in via
the Azure CLI public client id (AZURE_CLI_FALLBACK_CLIENT_ID), reusing its
broad pre-consented delegated permissions -- the same mechanism
fabric_pipeline.py and scan_manager.py already use to get a SQL/Fabric
token without a second sign-in prompt. If that tenant hasn't consented
User.Read (or the account has no photo set), acquisition/fetch just fails
and the caller falls back to showing initials -- never treated as fatal.
"""
import json
import time
import urllib.error
import urllib.parse
import urllib.request

from .auth import _acquire_scoped_token
from .state import (
    _profile_photo_cache,
    _profile_photo_lock,
    _tenant_name_cache,
    _tenant_name_lock,
    _user_profile_cache,
    _user_profile_lock,
)

GRAPH_TOKEN_SCOPES = ["https://graph.microsoft.com/.default"]
_PHOTO_CACHE_TTL_SECONDS = 3600
_TENANT_NAME_CACHE_TTL_SECONDS = 21600
_USER_PROFILE_CACHE_TTL_SECONDS = 21600


def _fetch_profile_photo(session, settings):
    """Returns (content_type, photo_bytes) -- both None if there is no
    photo to show, which the caller (the /api/me/photo route) treats as a
    plain 404, initials are always an acceptable fallback for the avatar
    itself. Cached in-memory per user for _PHOTO_CACHE_TTL_SECONDS, see
    state.py's _profile_photo_cache docstring for why. Use
    _photo_status_for_user (below) to find out WHY there's no photo -- a
    tenant that hasn't consented Graph for this client id looks identical
    to "no photo set" from here, which was confusing enough live (2026-08-
    18) that it's worth a separate, explicit diagnostic the Perfil panel
    can show instead of a silent fallback nobody can act on."""
    user_email = (session.get("user_email") or "").strip().lower()
    if not user_email:
        return None, None

    now = time.time()
    with _profile_photo_lock:
        cached = _profile_photo_cache.get(user_email)
    if cached and (now - cached["fetched_at"]) < _PHOTO_CACHE_TTL_SECONDS:
        return cached["content_type"], cached["data"]

    token = _acquire_scoped_token(session, settings, GRAPH_TOKEN_SCOPES)
    if not token:
        _store_photo_cache(user_email, None, None, now, "no_graph_token")
        return None, None

    request = urllib.request.Request(
        "https://graph.microsoft.com/v1.0/me/photo/$value",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            content_type = response.headers.get("Content-Type") or "image/jpeg"
            data = response.read()
    except urllib.error.HTTPError as exc:
        # 404 = no photo set (the common, unremarkable case); 403 = this
        # tenant hasn't consented the Graph permission this call needs for
        # the Azure CLI client id -- worth distinguishing since the second
        # one is fixable by a tenant admin and the first one isn't.
        reason = "no_photo_set" if exc.code == 404 else "graph_forbidden" if exc.code == 403 else f"graph_error_{exc.code}"
        _store_photo_cache(user_email, None, None, now, reason)
        return None, None
    except urllib.error.URLError:
        _store_photo_cache(user_email, None, None, now, "network_error")
        return None, None

    _store_photo_cache(user_email, content_type, data, now, "ok")
    return content_type, data


def _photo_status_for_user(user_email):
    """Best-effort diagnostic for the Perfil panel: why isn't there a
    photo showing? Reads whatever _fetch_profile_photo last cached for
    this user -- returns None if it hasn't been called yet this process
    (the frontend always calls /api/me/photo right at sign-in, well before
    a user would open the Perfil panel, so in practice this is populated
    by the time anyone looks)."""
    normalized = (user_email or "").strip().lower()
    if not normalized:
        return None
    with _profile_photo_lock:
        cached = _profile_photo_cache.get(normalized)
    return cached.get("reason") if cached else None


def _store_photo_cache(user_email, content_type, data, fetched_at, reason):
    with _profile_photo_lock:
        _profile_photo_cache[user_email] = {
            "content_type": content_type,
            "data": data,
            "fetched_at": fetched_at,
            "reason": reason,
        }


def _graph_get(token, path_and_query, extra_headers=None):
    """Shared GET-and-parse-JSON helper for the Graph calls below -- returns
    (payload, None) on success or (None, error_message) on failure, never
    raises. Every caller here treats a failure as "this extra info just
    isn't available", not fatal."""
    request = urllib.request.Request(
        f"https://graph.microsoft.com/v1.0/{path_and_query}",
        headers={"Authorization": f"Bearer {token}", **(extra_headers or {})},
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read().decode("utf-8")), None
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        return None, f"Graph API returned {exc.code}: {detail[:200]}"
    except urllib.error.URLError as exc:
        return None, f"Could not reach Microsoft Graph: {exc.reason}"


def _fetch_profile_info(session, settings):
    """The signed-in user's own Graph profile fields beyond what's already
    in the session (name/email) -- job title, department, office, phone --
    all readable under the same basic User.Read permission the photo fetch
    already relies on, no extra consent needed. Returns {} on any failure
    (not cached: this is one cheap call per profile-menu open, unlike the
    photo which is actual binary data worth avoiding refetching)."""
    token = _acquire_scoped_token(session, settings, GRAPH_TOKEN_SCOPES)
    if not token:
        return {}
    fields = "displayName,mail,userPrincipalName,jobTitle,department,officeLocation,mobilePhone,companyName"
    payload, _error = _graph_get(token, f"me?$select={fields}")
    if not payload:
        return {}
    return {
        "display_name": payload.get("displayName") or "",
        "mail": payload.get("mail") or payload.get("userPrincipalName") or "",
        "job_title": payload.get("jobTitle") or "",
        "department": payload.get("department") or "",
        "office_location": payload.get("officeLocation") or "",
        "mobile_phone": payload.get("mobilePhone") or "",
        "company_name": payload.get("companyName") or "",
    }


def _fetch_tenant_name(session, settings):
    """The tenant's real display name (e.g. "Contoso") instead of
    just its GUID -- Graph's /organization endpoint, needs Organization.
    Read.All, which is NOT always pre-consented for the Azure CLI public
    client the way User.Read basics are, so this degrades to None (caller
    falls back to showing the raw tenant id, same as before) far more
    often than the photo/profile-info calls above. Cached tenant-wide for
    _TENANT_NAME_CACHE_TTL_SECONDS since it never varies per user."""
    now = time.time()
    with _tenant_name_lock:
        cached = _tenant_name_cache.get("value")
    if cached and (now - cached["fetched_at"]) < _TENANT_NAME_CACHE_TTL_SECONDS:
        return cached["name"]

    token = _acquire_scoped_token(session, settings, GRAPH_TOKEN_SCOPES)
    name = None
    if token:
        payload, _error = _graph_get(token, "organization?$select=displayName")
        rows = (payload or {}).get("value") or []
        if rows:
            name = rows[0].get("displayName") or None

    with _tenant_name_lock:
        _tenant_name_cache["value"] = {"name": name, "fetched_at": now}
    return name


def _fetch_user_profiles(session, settings, emails):
    """Resolves displayName/jobTitle/department for a list of OTHER users
    by email (admin panel's "Usuarios por workspace") -- needs
    User.ReadBasic.All or User.Read.All delegated, same not-guaranteed-
    pre-consented caveat as _search_tenant_users below (returns {} for any
    email that fails, never raises). One Graph call per email rather than
    Graph's own $batch endpoint -- callers here are always a small,
    already-bounded list (the assignments for ONE workspace group just
    expanded in the UI, not the whole tenant at once), so the extra
    round-trips aren't worth the added complexity of parsing a batch
    response. Cached per-email for _USER_PROFILE_CACHE_TTL_SECONDS (job
    titles rarely change) -- see state.py's _user_profile_cache docstring.
    Returns {lowercased_email: {display_name, job_title, department}},
    omitting any email that couldn't be resolved."""
    now = time.time()
    token = None
    results = {}
    for raw_email in emails or []:
        email = (raw_email or "").strip().lower()
        if not email:
            continue
        with _user_profile_lock:
            cached = _user_profile_cache.get(email)
        if cached and (now - cached["fetched_at"]) < _USER_PROFILE_CACHE_TTL_SECONDS:
            if cached["profile"]:
                results[email] = cached["profile"]
            continue
        if token is None:
            token = _acquire_scoped_token(session, settings, GRAPH_TOKEN_SCOPES) or ""
        profile = None
        if token:
            fields = "displayName,jobTitle,department"
            payload, _error = _graph_get(token, f"users/{urllib.parse.quote(email)}?$select={fields}")
            if payload:
                profile = {
                    "display_name": payload.get("displayName") or "",
                    "job_title": payload.get("jobTitle") or "",
                    "department": payload.get("department") or "",
                }
        with _user_profile_lock:
            _user_profile_cache[email] = {"profile": profile, "fetched_at": now}
        if profile:
            results[email] = profile
    return results


def _search_tenant_users(session, settings, query, limit=15):
    """Typeahead search over the tenant's Entra directory (for
    the admin panel's Users tab) -- lets an admin pick a real person
    instead of typing an email blind. Needs User.Read.All or User.
    ReadBasic.All delegated, which -- like Organization.Read.All above --
    isn't guaranteed to be pre-consented; returns [] on any failure so the
    frontend's existing manual-email-entry fallback is always available
    regardless. $search (not $filter) is what Graph documents for
    substring name/mail matching, and requires the ConsistencyLevel:
    eventual header or it's rejected outright."""
    query = (query or "").strip()
    if not query:
        return []
    token = _acquire_scoped_token(session, settings, GRAPH_TOKEN_SCOPES)
    if not token:
        return []
    search_value = query.replace('"', "'")
    params = {
        "$search": f'"displayName:{search_value}" OR "mail:{search_value}" OR "userPrincipalName:{search_value}"',
        "$select": "displayName,mail,userPrincipalName,jobTitle",
        "$top": str(max(1, min(limit, 25))),
    }
    payload, _error = _graph_get(
        token,
        f"users?{urllib.parse.urlencode(params)}",
        extra_headers={"ConsistencyLevel": "eventual"},
    )
    if not payload:
        return []
    results = []
    for row in payload.get("value") or []:
        email = row.get("mail") or row.get("userPrincipalName") or ""
        if not email:
            continue
        results.append({
            "email": email,
            "display_name": row.get("displayName") or "",
            "job_title": row.get("jobTitle") or "",
        })
    return results
