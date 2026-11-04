"""Persisted delegated "service identity" for unattended reads --
warehouse.py's live Warehouse queries and onelake_data.py's live OneLake
downloads -- when no service principal is configured. An alternative to
requiring a real Entra app registration, extending the same idea
fabric_pipeline.py's delegated-token path already uses for triggering
scans (useful when nobody in the tenant has permission to register a new
app).

The difference from a plain request-scoped session (auth.py's _sessions,
in-memory only, gone on restart): warehouse.py/onelake_data.py need to
serve an ANONYMOUS visitor who never signed in themselves, at any time,
including right after a server restart -- there is no specific request's
"whoever's currently signed in" to reuse the way fabric_pipeline.py reuses
whoever clicked the scan button. This module persists ONE designated
session's MSAL token cache to config/service_session.json (gitignored,
same convention as admin_settings.json/lakehouse_target.json) so it
survives a restart, and re-persists it after every use if MSAL rotated
the underlying refresh token (SerializableTokenCache.has_state_changed) --
auth._acquire_scoped_token does NOT do this re-persist step itself (its
existing callers only ever need a session for its own in-memory lifetime,
never across a restart), so this module has its own light acquisition
logic rather than silently changing that shared helper's contract for
callers that don't need it.

Auto-designated, zero extra UI or clicks: see designate()'s own docstring
-- it piggybacks on an admin's normal sign-in rather than adding a new
step nobody would remember to do.

Real, open risk this does NOT resolve (documented, not silently assumed
away): if the tenant's Conditional Access policies force periodic
re-authentication or block long-lived refresh tokens for this public
client, the persisted session eventually stops refreshing silently and
these two modules degrade to whatever fallback they already had (SP if
configured, local file/stale cache otherwise) -- the same "degrade, don't
break" contract every other piece of this project already follows, not a
new failure mode.
"""
import json
import threading
import time

from .paths import SERVICE_SESSION_PATH

_lock = threading.Lock()


def _load():
    if not SERVICE_SESSION_PATH.exists():
        return None
    try:
        with open(SERVICE_SESSION_PATH, "r", encoding="utf-8") as handle:
            data = json.load(handle)
        return data if isinstance(data, dict) and data.get("msal_cache") else None
    except (json.JSONDecodeError, OSError):
        return None


def _save(data):
    SERVICE_SESSION_PATH.parent.mkdir(parents=True, exist_ok=True)
    with _lock:
        with open(SERVICE_SESSION_PATH, "w", encoding="utf-8") as handle:
            json.dump(data, handle)
        # This file holds a live refresh token for whichever admin most
        # recently signed in -- as sensitive as a password, not an
        # ordinary config file. chmod is a
        # real restriction on the Linux container this runs in on Render;
        # on Windows (local/tunnel dev) it has little practical effect
        # (no POSIX permission bits), but is harmless to call either way.
        try:
            SERVICE_SESSION_PATH.chmod(0o600)
        except OSError:
            pass


def designate(session, is_admin):
    """Call right after a successful sign-in (see auth.py's
    _poll_device_flow) -- if that person is an admin (admin_emails), their
    fresh session's token cache overwrites whatever was persisted before.
    Deliberately restricted to admins: this session's delegated
    permissions end up backing every anonymous visitor's read on the live
    site, so it must carry at least the same trust level the admin panel
    itself already requires, never any signed-in user's. A no-op for a
    non-admin session, or one with no usable cache yet."""
    if not is_admin or not session or not session.get("msal_cache"):
        return
    _save({
        "user_email": session.get("user_email", ""),
        "msal_cache": session["msal_cache"],
        "designated_at": time.time(),
    })


def has_service_session():
    return _load() is not None


def acquire_service_token(settings, scopes):
    """Mints a token for `scopes` off the persisted service session, or
    returns "" if there is none, or acquisition fails for any reason
    (expired refresh token, revoked consent, Conditional Access, msal not
    installed, ...) -- never raises. Callers (warehouse.py, onelake_
    data.py) treat "" exactly like "no delegated session available" and
    fall back to whatever they already fall back to."""
    persisted = _load()
    if not persisted:
        return ""
    try:
        from .auth import _build_msal_app
        app, cache = _build_msal_app(settings, serialized_cache=persisted["msal_cache"])
        accounts = app.get_accounts()
        if not accounts:
            return ""
        result = app.acquire_token_silent(scopes, account=accounts[0])
        if not result or "access_token" not in result:
            return ""
        if cache.has_state_changed:
            persisted["msal_cache"] = cache.serialize()
            persisted["last_refreshed_at"] = time.time()
            _save(persisted)
        return result["access_token"]
    except Exception:  # noqa: BLE001 - any MSAL/network failure just means "no delegated token available"
        return ""
