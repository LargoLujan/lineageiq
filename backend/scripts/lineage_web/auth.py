"""Auth: Entra ID device-code sign-in + sessions.

Split out of lineage_web_server.py -- pure code motion,
no logic changed from the original.
"""
import secrets
import threading
import time
from datetime import datetime, timezone

from .admin_settings import _email_in_allowlist, _load_admin_settings
from .constants import (
    AZURE_CLI_FALLBACK_CLIENT_ID,
    DEVICE_FLOW_STALE_SECONDS,
    FABRIC_TOKEN_SCOPES,
    MAX_PENDING_DEVICE_FLOWS_PER_IP,
    MAX_SESSION_HISTORY_ENTRIES,
    SESSION_ABSOLUTE_LIFETIME_SECONDS,
    SESSION_IDLE_TIMEOUT_SECONDS,
)
from . import warehouse
from .fabric_api import _fetch_all_tenant_workspaces, _fetch_my_workspaces
from .state import (
    _api_key_last_used,
    _api_key_last_used_lock,
    _device_flow_lock,
    _pending_device_flows,
    _session_history,
    _session_lock,
    _sessions,
)
from .utils import _hash_api_key, _now_iso

# Persisted counterpart to _session_history (state.py) --
# process-memory-only history explained "no one ever connects" once this
# server started restarting/redeploying often enough to matter. Same
# append-only pattern as collaboration.py's node_comments/node_favorites.
SESSION_HISTORY_COLUMNS = [
    "user_email", "user_name", "object_id", "tenant_id", "ip_address", "user_agent",
    "created_at", "last_seen_at", "ended_at", "end_reason", "is_fabric_tenant_admin",
]
_SESSION_HISTORY_TABLE_DDL = (
    "CREATE TABLE dbo.session_history ("
    "[user_email] VARCHAR(320), [user_name] VARCHAR(400), [object_id] VARCHAR(64), "
    "[tenant_id] VARCHAR(64), [ip_address] VARCHAR(64), [user_agent] VARCHAR(500), "
    "[created_at] VARCHAR(64), [last_seen_at] VARCHAR(64), [ended_at] VARCHAR(64), "
    "[end_reason] VARCHAR(32), [is_fabric_tenant_admin] VARCHAR(8))"
)


def _build_msal_app(settings, serialized_cache=None):
    import msal

    client_id = settings.get("entra_client_id") or AZURE_CLI_FALLBACK_CLIENT_ID
    tenant_id = settings.get("tenant_id")
    authority = f"https://login.microsoftonline.com/{tenant_id}"
    cache = msal.SerializableTokenCache()
    if serialized_cache:
        cache.deserialize(serialized_cache)
    return msal.PublicClientApplication(client_id, authority=authority, token_cache=cache), cache


def _run_device_flow_background(flow_id, app, cache, flow):
    try:
        result = app.acquire_token_by_device_flow(flow)  # blocks until done, denied, or expired
    except Exception as exc:  # noqa: BLE001 - any MSAL/network failure must reach the polling client, not crash a daemon thread silently
        with _device_flow_lock:
            pending = _pending_device_flows.get(flow_id)
            if pending is not None:
                pending["status"] = "error"
                pending["error"] = str(exc)
        return

    with _device_flow_lock:
        pending = _pending_device_flows.get(flow_id)
        if pending is None:
            return
        if result and "access_token" in result:
            pending["status"] = "done"
            pending["result"] = result
            # The token CACHE (not just this one result) is what lets a
            # later request silently mint tokens for OTHER scopes (SQL,
            # OneLake) using the same underlying refresh token, without
            # prompting the user again -- see _acquire_scoped_token.
            pending["cache"] = cache.serialize()
        else:
            pending["status"] = "error"
            pending["error"] = (result or {}).get("error_description") or "Sign-in was not completed."


def _prune_stale_device_flows():
    # A flow that's started but never polled to completion (closed tab,
    # abandoned sign-in) would otherwise leak a dict entry and a blocked
    # background thread forever -- MSAL's own device codes expire in ~15
    # minutes regardless, so anything older than that is definitely dead.
    now = time.monotonic()
    with _device_flow_lock:
        stale_ids = [
            flow_id for flow_id, pending in _pending_device_flows.items()
            if now - pending.get("created_monotonic", now) > DEVICE_FLOW_STALE_SECONDS
        ]
        for flow_id in stale_ids:
            del _pending_device_flows[flow_id]


def _start_device_flow(client_ip, user_agent=""):
    _prune_stale_device_flows()
    with _device_flow_lock:
        pending_from_ip = sum(1 for pending in _pending_device_flows.values() if pending.get("client_ip") == client_ip)
    if pending_from_ip >= MAX_PENDING_DEVICE_FLOWS_PER_IP:
        return None, {
            "error": "too_many_pending_flows",
            "message": "Too many sign-in attempts already in progress from this address. Finish or wait for one to expire, then try again.",
        }

    settings = _load_admin_settings()
    try:
        app, cache = _build_msal_app(settings)
        flow = app.initiate_device_flow(scopes=FABRIC_TOKEN_SCOPES)
    except Exception as exc:  # noqa: BLE001 - surfaces as a normal error response, not a 500 stack trace
        return None, {"error": "device_flow_failed", "message": str(exc)}

    if "user_code" not in flow:
        return None, {"error": "device_flow_failed", "message": flow.get("error_description") or "Could not start device-code sign-in."}

    flow_id = secrets.token_urlsafe(16)
    with _device_flow_lock:
        _pending_device_flows[flow_id] = {
            "status": "pending",
            "user_code": flow["user_code"],
            "verification_uri": flow.get("verification_uri") or flow.get("verification_url"),
            "message": flow.get("message"),
            "result": None,
            "cache": None,
            "error": None,
            "client_ip": client_ip,
            "user_agent": user_agent,
            "created_monotonic": time.monotonic(),
        }

    threading.Thread(target=_run_device_flow_background, args=(flow_id, app, cache, flow), daemon=True).start()

    return {
        "flow_id": flow_id,
        "user_code": flow["user_code"],
        "verification_uri": flow.get("verification_uri") or flow.get("verification_url"),
        "message": flow.get("message"),
    }, None


def _create_session_from_token_result(result, serialized_cache, client_ip="", user_agent=""):
    claims = result.get("id_token_claims") or {}
    user_email = (claims.get("preferred_username") or claims.get("email") or claims.get("upn") or "").strip()
    user_name = claims.get("name") or user_email

    # Checked once, right at sign-in, rather than only reactively at scan
    # time: a real Fabric tenant admin (Entra ID "Fabric Administrator"
    # role) gets a fundamentally different, MORE AUTHORITATIVE scan (every
    # tenant workspace, full-replace semantics -- missing means genuinely
    # gone) than a regular signed-in user (their own accessible subset
    # only, existing rows outside that subset retained rather than wiped,
    # since their narrower view says nothing about whether something
    # outside it still exists). The web UI surfaces this via /api/auth/me
    # so it can be shown before the user ever clicks a scan button, not
    # just discovered as a side effect of one. Costs one real admin-API
    # call at login (the same one _start_full_scan repeats fresh at
    # scan-start, since a session can live for hours and this could go
    # stale) -- negligible next to the device-code sign-in flow it's part
    # of, which already takes at least as long for the user to complete.
    _tenant_workspaces, _admin_error = _fetch_all_tenant_workspaces(result.get("access_token"))
    is_fabric_tenant_admin = _admin_error is None

    session_id = secrets.token_urlsafe(32)
    with _session_lock:
        _sessions[session_id] = {
            # Lets code that only holds the session dict (e.g. a queued scan
            # request, see scan_manager._enqueue_locked) re-resolve the LIVE
            # session later via _get_session(session_id) instead of holding
            # a snapshot that would silently outlive a logout/expiry. Never
            # forwarded to a client response -- see _list_sessions_for_admin
            # and /api/auth/me, both of which build their own explicit dict
            # rather than returning this one -- it IS the bearer credential.
            "session_id": session_id,
            "user_email": user_email,
            "user_name": user_name,
            # Same claims Azure CLI's own device-code sign-in resolves from
            "object_id": claims.get("oid") or "",
            "tenant_id": claims.get("tid") or "",
            "access_token": result.get("access_token"),
            "msal_cache": serialized_cache,
            "is_fabric_tenant_admin": is_fabric_tenant_admin,
            "ip_address": client_ip,
            "user_agent": user_agent,
            "created_at": _now_iso(),
            "last_seen_at": _now_iso(),
        }
    return session_id, user_email, user_name


def _record_ended_session(session, reason):
    """Appends one row to the bounded in-memory session-history log
    (admin panel Sessions tab) AND to dbo.session_history
    -- the in-memory list alone explained "no one ever
    connects" once this server started restarting/redeploying often
    enough for it to matter (it's process-lifetime only). Every call site
    already holds _session_lock at the point a session gets removed, so
    this doesn't take it itself -- same reasoning as _session_history
    sharing that lock in the first place (see state.py). `reason` is
    "signed_out", "revoked_by_admin", or "expired"."""
    row = {
        "user_email": session.get("user_email", ""),
        "user_name": session.get("user_name", ""),
        "object_id": session.get("object_id", ""),
        "tenant_id": session.get("tenant_id", ""),
        "ip_address": session.get("ip_address", ""),
        "user_agent": session.get("user_agent", ""),
        "created_at": session.get("created_at", ""),
        "last_seen_at": session.get("last_seen_at", ""),
        "ended_at": _now_iso(),
        "end_reason": reason,
        "is_fabric_tenant_admin": bool(session.get("is_fabric_tenant_admin")),
    }
    _session_history.insert(0, row)
    del _session_history[MAX_SESSION_HISTORY_ENTRIES:]
    try:
        warehouse.append_bronze_rows(
            "session_history", SESSION_HISTORY_COLUMNS, [row], create_table_ddl=_SESSION_HISTORY_TABLE_DDL,
        )
    except warehouse.WarehouseError:
        # A session ending (logout, admin revoke, lazy-expiry check) must
        # never fail just because the Warehouse write didn't go through --
        # the in-memory row above already covers this process's own
        # lifetime; a Warehouse hiccup only costs durability, not this
        # request succeeding.
        pass


def _list_sessions_for_admin():
    """Read-only snapshot for the admin panel's Users tab: who is currently
    signed in, the same identity claims Azure CLI itself resolves at sign-in
    (email, name, object id, tenant id), and -- best-effort, since it costs
    one live Fabric API call per session -- how many workspaces they can
    currently see. Never includes access_token/msal_cache; those never
    leave this process."""
    now = datetime.now(timezone.utc)
    with _session_lock:
        expired_ids = [session_id for session_id, session in _sessions.items() if _session_expired(session, now)]
        for session_id in expired_ids:
            _record_ended_session(_sessions[session_id], "expired")
            del _sessions[session_id]
        snapshot = [
            (session_id, dict(session))
            for session_id, session in _sessions.items()
        ]
    rows = []
    for session_id, session in snapshot:
        workspace_count = None
        workspaces, error = _fetch_my_workspaces(session.get("access_token"))
        if not error:
            workspace_count = len(workspaces)
        rows.append({
            # No session_id here: it IS the bearer credential (see
            # _current_session), and revoke already works by email
            # (_revoke_sessions_for_email) -- there is no legitimate reason
            # for this admin-facing response to hand out a value that lets
            # whoever reads it impersonate that session directly.
            "user_email": session.get("user_email", ""),
            "user_name": session.get("user_name", ""),
            "object_id": session.get("object_id", ""),
            "tenant_id": session.get("tenant_id", ""),
            "created_at": session.get("created_at", ""),
            "last_seen_at": session.get("last_seen_at", ""),
            "accessible_workspace_count": workspace_count,
            # Already computed at sign-in (see _create_session_from_token_
            # result above) but never actually surfaced here until now
            #  -- whether a session
            # holds elevated Fabric-tenant-admin scan rights is exactly
            # what an admin auditing active sessions would want to see.
            "is_fabric_tenant_admin": bool(session.get("is_fabric_tenant_admin")),
        })
    rows.sort(key=lambda row: row["last_seen_at"], reverse=True)
    return rows


def _list_session_history_for_admin(limit=100):
    """Read-only snapshot of ended sessions for the admin panel's Sessions
    tab, newest first, capped to `limit`. Reads dbo.
    session_history so this survives a server restart --
    falls back to the process-lifetime-only in-memory list (state.py's
    _session_history) only if the Warehouse isn't configured or the read
    fails, same degrade-gracefully contract as every other Warehouse-
    backed view in this project."""
    capped = max(1, min(limit, MAX_SESSION_HISTORY_ENTRIES))
    try:
        rows = warehouse.query_bronze_table("session_history", use_cache=False)
    except warehouse.WarehouseError:
        with _session_lock:
            return list(_session_history[:capped])
    rows.sort(key=lambda row: row.get("ended_at", ""), reverse=True)
    for row in rows:
        row["is_fabric_tenant_admin"] = str(row.get("is_fabric_tenant_admin", "")).strip().lower() == "true"
    return rows[:capped]


def _revoke_sessions_for_email(email):
    normalized = (email or "").strip().lower()
    if not normalized:
        return 0
    with _session_lock:
        matching_ids = [
            session_id for session_id, session in _sessions.items()
            if (session.get("user_email") or "").strip().lower() == normalized
        ]
        for session_id in matching_ids:
            _record_ended_session(_sessions[session_id], "revoked_by_admin")
            del _sessions[session_id]
    return len(matching_ids)


def _acquire_scoped_token(session, settings, scopes):
    """Silently mints a token for a DIFFERENT scope (SQL, OneLake, ...) than
    the one acquired at sign-in, reusing the same underlying refresh token
    already in this session's MSAL cache -- no re-prompt. Returns None if
    that fails for any reason (session too old, scope not consentable,
    etc.); callers fall back to the shared `az` CLI session in that case,
    exactly like before per-user auth existed."""
    cache = session.get("msal_cache")
    if not cache:
        return None
    try:
        app, _cache = _build_msal_app(settings, serialized_cache=cache)
        accounts = app.get_accounts()
        if not accounts:
            return None
        result = app.acquire_token_silent(scopes, account=accounts[0])
        if result and "access_token" in result:
            return result["access_token"]
    except Exception:  # noqa: BLE001 - a failed extra-scope acquisition should degrade, not crash the scan-start path
        return None
    return None


def _poll_device_flow(flow_id):
    with _device_flow_lock:
        pending = _pending_device_flows.get(flow_id)
        if pending is None:
            return None, {"error": "flow_not_found", "message": "Unknown or expired sign-in attempt."}
        status = pending["status"]
        if status == "pending":
            return {"status": "pending", "message": pending.get("message")}, None
        if status == "error":
            error_message = pending["error"]
            del _pending_device_flows[flow_id]
            return None, {"error": "device_flow_failed", "message": error_message}
        result = pending["result"]
        cache = pending["cache"]
        client_ip = pending.get("client_ip", "")
        user_agent = pending.get("user_agent", "")
        del _pending_device_flows[flow_id]

    settings = _load_admin_settings()
    session_id, user_email, user_name = _create_session_from_token_result(result, cache, client_ip, user_agent)
    is_admin = _email_in_allowlist(user_email, settings, "admin_emails")
    if is_admin:
        # Piggybacks on this admin's normal sign-in to (re-)designate the
        # persisted "service session" warehouse.py/onelake_data.py fall
        # back to when no service principal is configured -- see
        # service_session.py's own docstring for why this needs to
        # survive a server restart and a plain in-memory session doesn't.
        # Zero extra step for the admin: this fires every time they sign
        # in anyway, not just the first time.
        from .service_session import designate
        designate(_get_session(session_id), is_admin)
    return {
        "status": "done",
        "session_id": session_id,
        "user_email": user_email,
        "user_name": user_name,
        "is_admin": is_admin,
        "can_full_scan": _email_in_allowlist(user_email, settings, "full_scan_emails"),
    }, None


def _session_expired(session, now):
    """True if `session` is past its absolute lifetime or idle timeout, or
    has an unparseable timestamp (treated as expired rather than trusted).
    Shared by _get_session (which also prunes+refreshes on every real
    request) and _list_sessions_for_admin (the admin panel's
    Users tab used to list every entry in _sessions verbatim, showing a
    session as "active" for however long nothing else happened to touch
    it and trigger _get_session's own prune -- same criteria here so the
    two can't disagree)."""
    try:
        created_at = datetime.fromisoformat(session["created_at"])
        last_seen_at = datetime.fromisoformat(session.get("last_seen_at") or session["created_at"])
    except (TypeError, ValueError, KeyError):
        return True
    return (
        (now - created_at).total_seconds() > SESSION_ABSOLUTE_LIFETIME_SECONDS
        or (now - last_seen_at).total_seconds() > SESSION_IDLE_TIMEOUT_SECONDS
    )


def _get_session(session_id):
    if not session_id:
        return None
    now = datetime.now(timezone.utc)
    with _session_lock:
        session = _sessions.get(session_id)
        if session is None:
            return None
        if _session_expired(session, now):
            _record_ended_session(session, "expired")
            _sessions.pop(session_id, None)
            return None
        session["last_seen_at"] = _now_iso()
        return session


def _end_session(session_id):
    if not session_id:
        return
    with _session_lock:
        session = _sessions.pop(session_id, None)
        if session:
            _record_ended_session(session, "signed_out")


def _generate_api_key():
    # "flm_" prefix (Fabric Lineage Mapper) makes a leaked key recognizable
    # in logs/scans, same idea as GitHub's "ghp_"/Stripe's "sk_" prefixes.
    return "flm_" + secrets.token_urlsafe(32)


def _api_key_expired(entry):
    """expires_at (optional -- blank/absent means never) is an
    ISO timestamp, same format _now_iso() produces. A malformed value, or a
    non-string value from a hand-edited config, is treated as not-expired
    rather than raising, so a corrupt field degrades to the old always-
    valid behavior instead of locking out (or crashing a request for)
    every caller of a real key."""
    expires_at = entry.get("expires_at") or ""
    if not expires_at:
        return False
    try:
        expires = datetime.fromisoformat(str(expires_at).replace("Z", "+00:00"))
    except ValueError:
        return False
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=timezone.utc)
    return datetime.now(timezone.utc) >= expires


def _valid_api_key(raw_key, settings):
    """Constant-time lookup so response timing can't be used to narrow down
    a valid key byte-by-byte. Returns (name, scope) from the matched entry,
    or (None, None) -- also (None, None) once its expires_at
    (optional) has passed, treated identically to no match so a caller
    can't distinguish "expired" from "never existed" by response shape.
    Compares key_hash, never the raw key itself -- admin_settings.json
    only ever stores the hash (see
    admin_settings._migrate_api_keys for entries created before this).

    scope is "read_only" or "full" -- missing/legacy entries
    (created before this field existed) default to "full" so an already-
    deployed automation caller (e.g. a Fabric pipeline's Web activity
    triggering scans) doesn't silently lose access on upgrade; new keys
    default to "read_only" at creation instead (see handler.py's POST
    /api/admin/api-keys) so an admin has to consciously opt a new key
    into scan control rather than every key being a skeleton key by
    default. Returning scope from THIS SAME matched entry (not a separate
    by-name re-scan) matters: two entries can share a name (the duplicate-
    name check in POST /api/admin/api-keys is itself a lock-free read-
    modify-write, so a race can still produce one), and a by-name lookup
    would silently resolve to whichever entry happens to come first in
    the list -- possibly not the one the caller actually authenticated
    as."""
    if not raw_key:
        return None, None
    candidate_hash = _hash_api_key(raw_key)
    for entry in settings.get("api_keys") or []:
        if secrets.compare_digest(entry.get("key_hash", ""), candidate_hash):
            if _api_key_expired(entry):
                return None, None
            with _api_key_last_used_lock:
                _api_key_last_used[candidate_hash] = _now_iso()
            return entry.get("name"), (entry.get("scope") or "full")
    return None, None


def _api_key_last_used_at(key_hash):
    """"" (never used yet) or the ISO timestamp of the most recent
    successful validation, in-memory only -- see state.py's own comment
    on _api_key_last_used for why this isn't persisted."""
    with _api_key_last_used_lock:
        return _api_key_last_used.get(key_hash, "")


def _valid_api_key_name(raw_key, settings):
    """Thin wrapper over _valid_api_key for the many read-only call sites
    that only ever needed the name (every _api_key_name()-gated catalog
    route) -- scope only matters for the scan-control routes, which call
    _valid_api_key directly (see handler.py's _resolve_scan_caller and
    mcp_server.py's _resolve_api_key_name) so scope comes from the exact
    entry that authenticated, not a second lookup."""
    name, _scope = _valid_api_key(raw_key, settings)
    return name
