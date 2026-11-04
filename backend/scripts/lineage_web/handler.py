"""HTTP handler: static files + /api/*.

Split out of lineage_web_server.py (D.3, 2026-07-08) -- pure code motion,
no logic changed from the original. Extended since (Tanda 5, E.0-E.3):
static API keys, the catalog/query routes, and per-IP rate limiting +
request metrics.

Reading the actual lineage data -- GET /api/workspaces, /api/items,
/api/item-lineage, /api/objects, /api/notebook-code, and any static file
under /data/ (the large JSON payloads the frontend loads) -- requires a
signed-in session OR a valid API key (2026-07-22), OR LINEAGE_DEMO_MODE=1
in the environment (2026-08-27, see _read_access_allowed) -- opt-in only,
meant for a synthetic demo tenant (backend/scripts/generate_demo_data.py),
never for a deployment pointed at real Fabric data (/api/auth/me reports
it as demo_mode so the web UI can skip its sign-in gate). No further permission
check beyond that beyond "authenticated in the configured tenant": Fabric
workspace permissions are already enforced separately, at scan time (each
user's scan runs under their own delegated token), so a signed-in user
who merely lacks Warehouse/workspace access still sees this read-only
data. Everything else under the web root (index.html, app.js, styles.css,
vendor/) stays public so the sign-in gate itself can render before
authentication.
"""
import json
import mimetypes
import os
import sys
import threading
from datetime import datetime
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import analytics, capacity_metrics, collaboration, fabric_pipeline, graph_profile, onelake_data
from .admin_settings import (
    _default_admin_settings,
    _email_in_allowlist,
    _load_admin_settings,
    _merge_admin_settings,
    _write_admin_settings,
)
from .auth import (
    _acquire_scoped_token,
    _api_key_last_used_at,
    _end_session,
    _generate_api_key,
    _get_session,
    _list_session_history_for_admin,
    _list_sessions_for_admin,
    _poll_device_flow,
    _revoke_sessions_for_email,
    _start_device_flow,
    _valid_api_key,
    _valid_api_key_name,
)
from .catalog import (
    _get_column_profile,
    _get_column_sensitivity,
    _get_execution_stats,
    _get_failure_hotspots,
    _get_item_lineage,
    _get_notebook_code,
    _get_object_impact,
    _get_objects_for_item,
    _get_related_elements,
    _get_schedules,
    _get_workspace_roles,
    _norm,
    _search_items,
)
from .compression import get_compressed_bytes
from .constants import COMPRESSIBLE_SUFFIXES, FABRIC_TOKEN_SCOPES, GUID_PATTERN, MIN_COMPRESS_BYTES, SESSION_COOKIE_NAME
from .data_quality import _get_data_quality_for_table, _get_data_quality_overview
from .external_sources import _get_detected_external_origins, _persist_external_source_test_result, _summarize_pending_external_sources, _test_external_source, _test_lakehouse_connection
from . import installer
from .fabric_api import _fetch_capacities, _fetch_connections, _fetch_data_pipelines_in_workspace, _fetch_lakehouses_in_workspace, _fetch_my_workspaces, _fetch_warehouses_in_workspace, _filter_workspaces_by_min_role, _test_fabric_connection
from .observability import _metrics_snapshot, _record_request
from .openapi_spec import _build_openapi_spec
from .paths import DIFF_DIR, MCP_SERVER_REMOTE_PATH, REPO_ROOT
from .purview_insights import _get_access_audit, _get_capacity_insight, _get_changes_digest, _get_content_sensitivity_overview, _get_governance_scan_overview, _get_privacy_coverage_map, _get_privacy_framework_map, _get_sensitivity_overview
from .rate_limit import _check_rate_limit
from .scan_manager import (
    _build_notification_email,
    _build_teams_message,
    _queue_snapshot,
    _read_history,
    _read_progress,
    _read_workspaces,
    _send_email,
    _send_teams_notification,
    _start_executions_scan,
    _start_full_scan,
    _start_onelake_publish,
    _start_scan,
    _start_warehouse_upload,
    _stop_scan,
)
from .state import _installer_lock, _installer_state, _scan_lock, _scan_state
from .utils import _hash_api_key, _now_iso, _tail_log


# Every real POST body in this API is a small JSON object -- the largest
# legitimate one (business_glossary/external_sources saved via /api/admin/
# settings) is still well under this. See _read_request_body().
MAX_REQUEST_BODY_BYTES = 2 * 1024 * 1024


def _demo_mode_enabled():
    """LINEAGE_DEMO_MODE=1 (or true/yes) in the server's environment -- an
    explicit opt-in for the synthetic demo tenant written by backend/
    scripts/generate_demo_data.py, never for real tenant data. Read on every
    call, so only whoever starts the process can turn it on. Consulted in
    exactly two places: _read_access_allowed (widens READS only) and
    /api/auth/me (reports the flag so the web UI skips its sign-in gate).
    No write route looks at it."""
    return os.environ.get("LINEAGE_DEMO_MODE", "").strip().lower() in ("1", "true", "yes")


def _mask_api_keys(settings):
    """Never let a raw API key value leave this process outside the one
    creation response that returns it (POST /api/admin/api-keys) -- GET/
    POST /api/admin/settings used to echo the whole settings object
    verbatim, api_keys included, defeating the point of the dedicated
    masked GET /api/admin/api-keys endpoint below (2026-08-17 security
    audit: any signed-in admin could read every API key in full from the
    network tab or `adminSettingsCache` in devtools)."""
    masked = dict(settings)
    masked["api_keys"] = [
        {
            "name": entry.get("name", ""),
            "created_at": entry.get("created_at", ""),
            "key_preview": entry.get("key_preview", ""),
            # None of these five are secret -- safe to return in full,
            # unlike key_hash (2026-08-18, admin-panel completeness pass).
            "description": entry.get("description", ""),
            "created_by": entry.get("created_by", ""),
            "expires_at": entry.get("expires_at", ""),
            "scope": entry.get("scope") or "full",
            # In-memory only (see state.py's _api_key_last_used) -- "" if
            # this key hasn't successfully authenticated since this
            # process started.
            "last_used_at": _api_key_last_used_at(entry.get("key_hash", "")),
        }
        for entry in settings.get("api_keys") or []
    ]
    # Small audit trail (2026-08-18) -- see POST /api/admin/api-keys/revoke.
    # Nothing here was ever secret (never held key_hash), so no masking
    # needed, just pass it through.
    masked["revoked_api_keys"] = settings.get("revoked_api_keys") or []
    return masked


def _parse_limit(query, default, maximum):
    raw = (query.get("limit") or [""])[0]
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return max(1, min(value, maximum))


def _parse_max_hops(query, default=2, maximum=6):
    raw = (query.get("max_hops") or [""])[0]
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return max(1, min(value, maximum))


def _parse_sensitivity_sample_limit(query, default=15, maximum=5000):
    # Default stays small for the lightweight card view; the admin panel's
    # detail modal passes a much higher sample_limit to get every hit in
    # one call instead of paginating.
    raw = (query.get("sample_limit") or [""])[0]
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return max(1, min(value, maximum))


def _parse_analytics_days(query, default=30, maximum=365):
    # Backs the Analíticas tab's 7/30/90-day filter (2026-08-25) -- both
    # analytics.get_usage_analytics and get_mcp_usage_analytics already
    # took a `days` kwarg, just never had a caller pass anything but the
    # default until this query param existed.
    raw = (query.get("days") or [""])[0]
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        return default
    return max(1, min(value, maximum))


class LineageWebHandler(BaseHTTPRequestHandler):
    server_version = "LineageWebServer/2.0"
    # Default HTTP/1.0 closes the TCP connection after every response. For
    # the large payloads served here, browsers sometimes report that
    # connection close as a spurious net::ERR_ABORTED in devtools even
    # though the full body (matching Content-Length) was already delivered.
    # HTTP/1.1 keep-alive avoids the close-right-after-large-body pattern.
    protocol_version = "HTTP/1.1"
    # Without this, a connection that never finishes sending its request
    # line/headers/body (deliberately slow, or just dead) holds its thread
    # forever -- ThreadingHTTPServer hands each connection its own thread
    # with no cap, so enough of these exhaust the process (2026-08-17
    # security audit). socketserver.StreamRequestHandler.setup() applies
    # this automatically via socket.settimeout(); the stdlib's own
    # handle_one_request() already catches the resulting socket.timeout
    # and closes the connection cleanly, so no other change is needed here.
    timeout = 30
    root: Path = Path(".")
    # Set by lineage_web_server.main() once it's spawned (or failed to
    # spawn) the sibling mcp_http_server.py subprocess -- see
    # _spawn_mcp_http_server there and _proxy_to_mcp_http_server below.
    # None means "not running" (never spawned, --no-mcp-http, or the
    # subprocess failed to start), in which case /mcp returns 503 instead
    # of trying to proxy to nothing.
    mcp_http_port: int | None = None

    def log_message(self, format_str, *args):
        sys.stderr.write(f"[{self.log_date_time_string()}] {self.address_string()} {format_str % args}\n")

    def _send_security_headers(self):
        """Defense-in-depth headers this hand-rolled server never sent
        before (2026-08-17 security audit) -- with no framework underneath
        and every bit of HTML built via app.js's own escapeHtml() discipline,
        these are the only backstop if a future escaping bug ever slips
        through. script-src has no 'unsafe-inline': both inline <script>
        blocks that used to live in index.html were moved to theme-init.js/
        three-bridge.js for exactly this reason. style-src keeps
        'unsafe-inline' -- app.js sets `.style.*`/style="" inline in dozens
        of places, rewriting all of that to a stylesheet-only approach is a
        much larger change than this security pass, and inline CSS alone
        can't execute script."""
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; "
            "base-uri 'self'; form-action 'self'; frame-ancestors 'none'",
        )

    def _send_json(self, status_code, payload, set_cookie=None, clear_cookie=False, extra_headers=None):
        self._record_metric(status_code)
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status_code)
        self._send_security_headers()
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        if set_cookie:
            self.send_header("Set-Cookie", self._build_session_cookie(set_cookie))
        elif clear_cookie:
            self.send_header("Set-Cookie", self._build_session_cookie("", expire=True))
        self.end_headers()
        self.wfile.write(body)

    def _build_session_cookie(self, session_id, expire=False):
        cookie = SimpleCookie()
        cookie[SESSION_COOKIE_NAME] = session_id
        morsel = cookie[SESSION_COOKIE_NAME]
        morsel["path"] = "/"
        morsel["httponly"] = True
        morsel["samesite"] = "Lax"
        # This process only ever speaks plain HTTP itself -- Secure used to
        # be hardcoded True on the assumption every real visitor arrives
        # through the Cloudflare tunnel (which does terminate real HTTPS at
        # its edge), but that also silently broke the project's own
        # explicitly-supported direct-HTTP-on-LAN use case: the cookie was
        # set with Secure, then never sent back by the browser over that
        # plain-HTTP connection (2026-08-26 security audit). Reflects
        # _request_scheme() instead -- see its own docstring for why
        # trusting X-Forwarded-Proto from any peer is safe specifically for
        # this purpose.
        morsel["secure"] = self._request_scheme() == "https"
        if expire:
            morsel["max-age"] = 0
        return morsel.OutputString()

    def _request_scheme(self):
        """Best-effort scheme this request actually arrived as, for both
        the session cookie's Secure flag above and the CSRF Origin check
        below. A fronting reverse proxy (cloudflared, Render's edge) sets
        X-Forwarded-Proto to whatever scheme IT was reached on; trusting it
        from any peer (not just the loopback-only trust _client_ip() uses
        for rate-limit IPs) is safe here specifically, because unlike a
        spoofed client IP, a lied-about scheme can only affect the Secure
        flag and Origin check applied to THIS SAME request/response --
        never another visitor's session. Worst case, an HTTP LAN client
        that claims "https" gets a Secure cookie it then can't send back
        over its own HTTP connection: a broken session for itself, not a
        way to attack anyone else's."""
        forwarded = self.headers.get("X-Forwarded-Proto", "").split(",")[0].strip().lower()
        return forwarded if forwarded in ("http", "https") else "http"

    def _has_session_cookie(self):
        cookie_header = self.headers.get("Cookie")
        if not cookie_header:
            return False
        cookie = SimpleCookie()
        cookie.load(cookie_header)
        return SESSION_COOKIE_NAME in cookie

    def _validate_csrf_origin(self):
        """Origin-based CSRF defense (2026-08-26 security audit) for any
        POST that relies on the session cookie. SameSite=Lax already blocks
        the classic cross-site form-POST case (Lax cookies aren't attached
        to cross-site subrequests, only top-level navigations with a "safe"
        method), but doesn't cover older/non-compliant browsers or a
        same-site-but-untrusted subdomain -- a lightweight Origin/Referer
        check closes that without needing a token round-trip or any
        frontend change. Only applies when the session cookie is actually
        present: an API-key caller (X-Api-Key header, never auto-attached
        cross-site by a browser) is already immune to CSRF by construction.
        Returns True if the request should proceed; sends the 403 itself
        and returns False otherwise."""
        if not self._has_session_cookie():
            return True
        origin = self.headers.get("Origin") or self.headers.get("Referer") or ""
        host = self.headers.get("Host", "")
        allowed = (f"http://{host}", f"https://{host}") if host else ()
        if any(origin == allowed_origin or origin.startswith(allowed_origin + "/") for allowed_origin in allowed):
            return True
        self._send_json(403, {
            "error": "csrf_check_failed",
            "message": "This request's Origin/Referer doesn't match this server. If you're calling this API from your own script, use an X-Api-Key instead of a browser session cookie.",
        })
        return False

    # Behind the cloudflared tunnel, self.client_address is the tunnel
    # daemon's local connection to this process (the same for every real
    # visitor, always loopback since cloudflared runs on this same
    # machine) -- Cloudflare forwards the real visitor IP in this header,
    # so rate limiting keys on it when present. Only trusted when the
    # DIRECT peer actually is loopback, though (2026-08-17 security audit):
    # trusting these headers unconditionally let anyone send a made-up
    # Cf-Connecting-Ip/X-Forwarded-For and pick whatever "IP" they wanted,
    # defeating rate limiting entirely -- both for a normal client talking
    # straight to this process (no tunnel in between at all) and for
    # someone who reaches this process's bound port directly instead of
    # through cloudflared (possible since it binds 0.0.0.0, see
    # lineage_web_server.py). self.client_address[0] itself is the one
    # value here the OS/TCP stack guarantees isn't spoofable.
    # NOTE for the Render deployment: Render's own edge proxy isn't
    # loopback from this container's point of view, so X-Forwarded-For
    # is NOT trusted there either with this fix -- every visitor on Render
    # shares one rate-limit bucket (keyed on whatever peer IP Render's
    # proxy presents) instead of being limited individually. Safer than
    # the previous trivially-bypassable behavior, but if per-visitor
    # limiting on Render specifically matters, that needs Render's actual
    # proxy IP range added to _TRUSTED_PROXY_PEERS below.
    _TRUSTED_PROXY_PEERS = {"127.0.0.1", "::1"}

    def _client_ip(self):
        peer = self.client_address[0]
        if peer not in self._TRUSTED_PROXY_PEERS:
            return peer
        forwarded = self.headers.get("Cf-Connecting-Ip")
        if forwarded:
            return forwarded.strip()
        forwarded_for = self.headers.get("X-Forwarded-For")
        if forwarded_for:
            return forwarded_for.split(",")[0].strip()
        return peer

    def _current_session(self):
        cookie_header = self.headers.get("Cookie")
        if not cookie_header:
            return None
        cookie = SimpleCookie()
        cookie.load(cookie_header)
        morsel = cookie.get(SESSION_COOKIE_NAME)
        if not morsel:
            return None
        return _get_session(morsel.value)

    def _resolve_scan_caller(self):
        """Session (if any) plus a validated api_key_name (if any, only
        checked when there's no session) for the scan-control routes.
        Returns a (session, api_key_name) tuple, or None after already
        sending a 401 -- callers do `resolved = self._resolve_scan_caller();
        if resolved is None: return`. Distinguishing "no X-Api-Key header at
        all" from "a header was sent but doesn't match any configured key"
        matters: silently treating a mistyped key the same as no key at all
        (which _start_scan/_start_full_scan/_stop_scan already do, since
        they only see a plain api_key_name-or-None) would surface as a
        confusing sign_in_required to whoever's debugging a failed
        automation call, instead of pointing at the actual problem."""
        session = self._current_session()
        if session:
            return session, None
        raw_key = self.headers.get("X-Api-Key")
        if not raw_key:
            return None, None
        # 2026-08-18: a single _valid_api_key call resolves (name, scope)
        # from the SAME matched entry, in one settings read -- see its own
        # docstring for why a separate by-name scope lookup (the original
        # version of this fix) was wrong: it could resolve to a different
        # entry than the one that actually authenticated if two keys share
        # a name, and re-reading settings a second time opened a window
        # where the key could be revoked in between. A "read_only"-scoped
        # key (the new default for keys created from now on) can read the
        # catalog but not start/stop a scan. Legacy keys with no scope
        # field default to "full", so this doesn't retroactively break an
        # already-deployed automation caller.
        api_key_name, scope = _valid_api_key(raw_key, _load_admin_settings())
        if api_key_name is None:
            self._send_json(401, {"error": "invalid_api_key", "message": "The X-Api-Key header does not match any key configured in the admin panel."})
            return None
        if scope != "full":
            self._send_json(403, {"error": "insufficient_scope", "message": "This API key is read-only and cannot trigger or stop scans -- create a key with scope 'full' in the admin panel's API Keys tab for this action."})
            return None
        return None, api_key_name

    def _api_key_name(self):
        """Machine-to-machine auth for automation callers (Fabric pipeline
        Web activities) that can't do an interactive device-code sign-in --
        see Tanda 5, E.0. Returns the matching key's name, or None if the
        header is absent/invalid."""
        raw_key = self.headers.get("X-Api-Key")
        if not raw_key:
            return None
        settings = _load_admin_settings()
        return _valid_api_key_name(raw_key, settings)

    def _read_access_allowed(self):
        """Gate for every read-only catalog/graph route and /data/* static
        file (2026-08-27): a signed-in session, a valid API key, or --
        opt-in only, LINEAGE_DEMO_MODE=1 in the environment -- unauthenticated.
        Demo mode exists so `docker-compose up` plus `python backend/scripts/
        generate_demo_data.py` (synthetic "Contoso" tenant, see that script's
        own docstring for why it's safe to publish) gives a first-time
        visitor something to click through in minutes, without an Entra app
        registration. It only ever widens READS -- every write path (scan
        triggers, admin settings, API key management) still requires the
        exact same session/API-key check as before; this method is never
        called from any of those. /api/auth/me reports the same flag
        (demo_mode) so the web UI opens straight into the read-only
        explorer instead of the sign-in gate. NEVER set this env var on a
        deployment pointed at a real Fabric tenant's real data -- it makes
        every catalog/lineage read fully public, with no auth at all."""
        session = self._current_session()
        api_key = self._api_key_name()
        if session or api_key:
            return True
        return _demo_mode_enabled()

    def _require_admin(self):
        """Returns the loaded admin settings if the current session's email
        is on admin_emails, else sends the appropriate 401/403 itself and
        returns None -- callers just check `if settings is None: return`."""
        session = self._current_session()
        if not session:
            self._send_json(401, {"error": "not_signed_in"})
            return None
        settings = _load_admin_settings()
        if not _email_in_allowlist(session["user_email"], settings, "admin_emails"):
            self._send_json(403, {"error": "not_admin", "message": "This account is not on the admin allowlist."})
            return None
        return settings

    def _require_admin_or_api_key(self):
        """Same admin-allowlist bar as _require_admin() for a browser
        session -- a signed-in but non-admin session still gets 403, this
        does NOT loosen that rule -- but also accepts any valid API key
        (either scope) as an alternative, same session_or_api_key trust
        bar already used by /api/business-glossary etc.: the local
        mcp_server.py can call purview_insights functions directly without
        going through HTTP at all, but mcp_server_remote.py/
        mcp_http_server.py only ever speak to this REST API, and before
        this they had no way to reach these governance/sensitivity routes
        (_require_admin's session-only check rejects any X-Api-Key caller
        with 401 not_signed_in, key or no key)."""
        session = self._current_session()
        if session:
            settings = _load_admin_settings()
            if not _email_in_allowlist(session["user_email"], settings, "admin_emails"):
                self._send_json(403, {"error": "not_admin", "message": "This account is not on the admin allowlist."})
                return None
            return settings
        if self._api_key_name():
            return _load_admin_settings()
        self._send_json(401, {"error": "not_signed_in"})
        return None

    def _record_metric(self, status_code):
        # Every response path (JSON, static file, plain-text error) funnels
        # through _send_json/_send_error/_serve_static -- hooking metrics
        # here, once, covers all of them without touching each of the ~26
        # route branches individually. Path is stripped of its query
        # string first so e.g. /api/items?query=a and ?query=b count as
        # the same route instead of growing the metrics dict unboundedly.
        _record_request(self.command, urlparse(self.path).path, status_code)

    def _resolve_static_path(self, url_path):
        if url_path in ("", "/"):
            url_path = "/index.html"
        relative = url_path.lstrip("/")
        candidate = (self.root / relative).resolve()
        try:
            candidate.relative_to(self.root.resolve())
        except ValueError:
            return None
        return candidate

    def _serve_static(self, url_path):
        # Everything under /data/ is the real lineage payload (workspace
        # names, item lineage, source objects, notebook code -- the large
        # JSON the frontend loads) -- gate it the same as the catalog-query
        # /api/* routes below: any signed-in tenant account, or a valid API
        # key, no further permission check (Fabric permissions are already
        # enforced separately, at scan time). Everything else under the web
        # root (index.html, app.js, styles.css, vendor/) stays public so the
        # sign-in gate itself can render before authentication.
        if url_path.startswith("/data/") and not self._read_access_allowed():
            self._send_error(401, "Sign in required to read lineage data.")
            return

        # The big generated JSON payloads (lineage-explorer.json and
        # friends) can optionally be served from a Fabric Lakehouse's
        # OneLake Files area instead of this machine's local disk -- see
        # onelake_data.py's own docstring. Any failure (not enabled, not
        # configured, fetch error with no cache yet) falls straight
        # through to the normal local-file path below, unchanged.
        onelake_path = None
        if url_path.startswith("/data/") and onelake_data.is_onelake_data_enabled():
            filename = url_path.rsplit("/", 1)[-1]
            if filename in onelake_data.PUBLISHED_FILENAMES:
                onelake_path = onelake_data.fetch_cached_path(filename)

        path = onelake_path or self._resolve_static_path(url_path)
        if path is None:
            self._send_error(403, "Forbidden")
            return
        if path.is_dir():
            path = path / "index.html"
        if not path.exists() or not path.is_file():
            self._send_error(404, "Not Found")
            return

        content_type, _ = mimetypes.guess_type(str(path))
        content_type = content_type or "application/octet-stream"

        accepts_gzip = "gzip" in self.headers.get("Accept-Encoding", "")
        compressible = path.suffix.lower() in COMPRESSIBLE_SUFFIXES

        # A build-time-prepared "<file>.gz" sibling (see docker/gzip_data.py,
        # used for the resource-constrained hosted deploy -- 512MB RAM/0.1
        # CPU on Render's free tier can't afford reading a large raw JSON
        # file into memory PLUS gzip-compressing it on every request) is
        # served directly, skipping the raw read and compression below
        # entirely. Absent that sibling (the normal local/tunnel case),
        # behavior is unchanged from before.
        pregzipped = path.with_name(path.name + ".gz")
        if accepts_gzip and compressible and pregzipped.is_file():
            body = pregzipped.read_bytes()
            encoding = "gzip"
            # The uncompressed size for X-Uncompressed-Length below -- stat(),
            # not a read, so this path never loads the big raw file at all.
            raw_len = path.stat().st_size
        else:
            raw = path.read_bytes()
            if accepts_gzip and compressible and len(raw) > MIN_COMPRESS_BYTES:
                body = get_compressed_bytes(path, raw)
                encoding = "gzip"
            else:
                body = raw
                encoding = None
            raw_len = len(raw)

        self._record_metric(200)
        self.send_response(200)
        self._send_security_headers()
        self.send_header("Content-Type", content_type)
        if encoding:
            self.send_header("Content-Encoding", encoding)
            # Browsers transparently decompress gzip and report byte-stream
            # progress in decompressed bytes, but Content-Length here is the
            # compressed size actually sent on the wire -- expose the real
            # decompressed size separately so client-side progress bars
            # (see data-loader-worker.js) don't read past 100% early.
            self.send_header("X-Uncompressed-Length", str(raw_len))
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    _MCP_PROXY_DROP_HEADERS = {"host", "content-length", "connection", "transfer-encoding"}

    def _proxy_to_mcp_http_server(self, method, body):
        """Forwards one request under /mcp straight through to the internal
        mcp_http_server.py subprocess (see lineage_web_server._spawn_mcp_
        http_server) on 127.0.0.1 -- the only way that subprocess is ever
        reachable, so the whole remote-MCP surface ends up living at
        exactly one already-public URL (this server's own host + /mcp),
        with no separate port to expose through a tunnel/firewall/Render
        service. Auth (a valid admin-issued API key as an Authorization:
        Bearer header) is enforced by the subprocess itself, not here --
        this is a plain reverse proxy, forwarding headers (including
        Authorization/Mcp-Session-Id) and the body unmodified either way.

        Streams the response back chunk-by-chunk rather than buffering it
        whole: a Streamable HTTP response can be text/event-stream, and a
        naive read-everything-then-respond would defeat the point of that
        (and could hang on a session-keepalive stream that never actually
        closes)."""
        import urllib.error
        import urllib.request

        if not self.mcp_http_port:
            self._send_json(503, {
                "error": "mcp_unavailable",
                "message": "The MCP-over-HTTP subprocess isn't running on this server -- see the startup log, or `pip install -r requirements-mcp.txt` if this is a fresh install.",
            })
            return

        target_url = f"http://127.0.0.1:{self.mcp_http_port}/mcp"
        headers = {name: value for name, value in self.headers.items() if name.lower() not in self._MCP_PROXY_DROP_HEADERS}
        request = urllib.request.Request(target_url, data=body, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                self._record_metric(response.status)
                self.send_response(response.status)
                self._send_security_headers()
                for name, value in response.getheaders():
                    if name.lower() in self._MCP_PROXY_DROP_HEADERS:
                        continue
                    self.send_header(name, value)
                self.end_headers()
                if self.command == "HEAD":
                    return
                while True:
                    chunk = response.read(8192)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except urllib.error.HTTPError as exc:
            error_body = exc.read()
            self._record_metric(exc.code)
            self.send_response(exc.code)
            self._send_security_headers()
            self.send_header("Content-Type", exc.headers.get("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(error_body)))
            self.end_headers()
            self.wfile.write(error_body)
        except urllib.error.URLError as exc:
            self._send_json(502, {"error": "mcp_unreachable", "message": f"Could not reach the MCP subprocess: {exc.reason}"})

    def _read_request_body(self):
        # Must run before ANY early return in do_POST (auth check, 404,
        # etc.) -- with HTTP/1.1 keep-alive (protocol_version above), bytes
        # left unread on the socket don't just vanish, they get parsed as
        # the start of the NEXT request line on the same connection,
        # corrupting it. Reading exactly Content-Length bytes once, up
        # front, regardless of which branch eventually handles the route,
        # keeps every connection-reusing caller (e.g. a Fabric pipeline's
        # Web activity) safe even when a request is rejected immediately.
        #
        # Returns None (instead of bytes) if the declared size was rejected
        # -- callers must check for that and return immediately without
        # trying to read/act on a body. Every real body this API ever
        # handles is a small JSON object (the biggest, business_glossary/
        # external_sources saved via /api/admin/settings, is still tiny);
        # a caller declaring more than MAX_REQUEST_BODY_BYTES gets rejected
        # WITHOUT reading it, so an attacker can't force this process to
        # materialize an arbitrarily large payload in memory just to have
        # it discarded (2026-08-17 security audit). The connection is
        # closed rather than kept alive in that case, since the unread
        # body bytes can't safely be left on the socket either (same
        # corruption risk described above).
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length > MAX_REQUEST_BODY_BYTES:
            self.close_connection = True
            self._send_error(413, "Request body too large.")
            return None
        return self.rfile.read(length) if length > 0 else b""

    def _send_error(self, code, message):
        self._record_metric(code)
        body = message.encode("utf-8")
        self.send_response(code)
        self._send_security_headers()
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)

        if parsed.path.startswith("/api/"):
            allowed, retry_after = _check_rate_limit(self._client_ip())
            if not allowed:
                self._send_json(
                    429,
                    {"error": "rate_limited", "message": f"Too many requests. Retry after {retry_after}s."},
                    extra_headers={"Retry-After": str(retry_after)},
                )
                return

        if parsed.path == "/api/workspaces":
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            workspaces = _read_workspaces()
            if workspaces is None:
                self._send_json(503, {"error": "workspace_index_missing", "message": "index/workspaces.csv does not exist. Run backend/scripts/01_discover_workspaces.ps1 first."})
                return
            name_contains = (query.get("name_contains") or [""])[0]
            if name_contains:
                needle = _norm(name_contains)
                workspaces = [row for row in workspaces if needle in _norm(row.get("workspace_name", ""))]
            self._send_json(200, {"workspaces": workspaces, "count": len(workspaces), "source_path": "index/workspaces.csv"})
            return

        if parsed.path == "/api/me/profile":
            session = self._current_session()
            if not session:
                self._send_json(401, {"error": "not_signed_in"})
                return
            settings = _load_admin_settings()
            self._send_json(200, {
                "tenant_name": graph_profile._fetch_tenant_name(session, settings),
                "photo_status": graph_profile._photo_status_for_user(session.get("user_email")),
                **graph_profile._fetch_profile_info(session, settings),
            })
            return

        if parsed.path == "/api/me/photo":
            session = self._current_session()
            if not session:
                self._send_json(401, {"error": "not_signed_in"})
                return
            content_type, data = graph_profile._fetch_profile_photo(session, _load_admin_settings())
            if not data:
                self._send_error(404, "No photo available.")
                return
            self.send_response(200)
            self._send_security_headers()
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "private, max-age=3600")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
            return

        if parsed.path == "/api/items":
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            query_text = (query.get("query") or [""])[0]
            item_type = (query.get("item_type") or [""])[0]
            limit = _parse_limit(query, default=20, maximum=200)
            self._send_json(200, _search_items(query_text, item_type, limit))
            return

        if parsed.path == "/api/item-lineage":
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            qualified_name = (query.get("qualified_name") or [""])[0]
            if not qualified_name:
                self._send_json(400, {"error": "invalid_request", "message": "?qualified_name= is required."})
                return
            self._send_json(200, _get_item_lineage(qualified_name))
            return

        if parsed.path == "/api/objects":
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            query_text = (query.get("query") or [""])[0]
            if not query_text:
                self._send_json(400, {"error": "invalid_request", "message": "?query= is required."})
                return
            limit = _parse_limit(query, default=5, maximum=50)
            self._send_json(200, _get_object_impact(query_text, limit))
            return

        if parsed.path == "/api/notebook-code":
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            qualified_name = (query.get("qualified_name") or [""])[0]
            if not qualified_name:
                self._send_json(400, {"error": "invalid_request", "message": "?qualified_name= is required."})
                return
            max_chars = _parse_limit({"limit": query.get("max_chars", [])}, default=60000, maximum=1000000)
            self._send_json(200, _get_notebook_code(qualified_name, max_chars))
            return

        if parsed.path == "/api/related-elements":
            # Roadmap Fase 2 (2026-08-18): the 6 catalog reads that used to
            # be local-only (mcp_server.py's stdio tools), same auth level
            # as the sibling catalog routes above -- see catalog.py's own
            # comment on this batch.
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            qualified_name = (query.get("qualified_name") or [""])[0]
            if not qualified_name:
                self._send_json(400, {"error": "invalid_request", "message": "?qualified_name= is required."})
                return
            direction = (query.get("direction") or ["both"])[0]
            if direction not in ("upstream", "downstream", "both"):
                direction = "both"
            max_hops = _parse_max_hops(query)
            limit = _parse_limit(query, default=100, maximum=500)
            self._send_json(200, _get_related_elements(qualified_name, direction, max_hops, limit))
            return

        if parsed.path == "/api/objects-for-item":
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            qualified_name = (query.get("qualified_name") or [""])[0]
            if not qualified_name:
                self._send_json(400, {"error": "invalid_request", "message": "?qualified_name= is required."})
                return
            self._send_json(200, _get_objects_for_item(qualified_name))
            return

        if parsed.path == "/api/workspace-roles":
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            workspace_name = (query.get("workspace_name") or [""])[0]
            if not workspace_name:
                self._send_json(400, {"error": "invalid_request", "message": "?workspace_name= is required."})
                return
            self._send_json(200, _get_workspace_roles(workspace_name))
            return

        if parsed.path == "/api/execution-stats":
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            query_text = (query.get("query") or [""])[0]
            if not query_text:
                self._send_json(400, {"error": "invalid_request", "message": "?query= is required."})
                return
            limit = _parse_limit(query, default=10, maximum=100)
            self._send_json(200, _get_execution_stats(query_text, limit))
            return

        if parsed.path == "/api/failure-hotspots":
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            limit = _parse_limit(query, default=20, maximum=200)
            hotspots = _get_failure_hotspots(limit)
            self._send_json(200, {"hotspots": hotspots, "count": len(hotspots)})
            return

        if parsed.path == "/api/schedules":
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            query_text = (query.get("query") or [""])[0]
            workspace_name = (query.get("workspace_name") or [""])[0]
            self._send_json(200, _get_schedules(query_text, workspace_name))
            return

        if parsed.path == "/api/openapi.json":
            self._send_json(200, _build_openapi_spec())
            return

        if parsed.path == "/api/status":
            with _scan_lock:
                payload = dict(_scan_state)
            # Log lines can contain internal paths/error detail from a
            # workspace the caller may have no real Fabric access to --
            # only expose them to a signed-in session or a valid API key
            # (Tanda 5, E.1 -- an automation caller polling this exact
            # endpoint needs the log tail to make retry/alert decisions),
            # not to anyone who can merely reach the tunnel URL. The step
            # name/progress percentage (below) stays visible to everyone:
            # it drives the progress bar and reveals nothing sensitive on
            # its own.
            caller_authenticated = bool(self._current_session() or self._api_key_name())
            if caller_authenticated:
                payload["log_tail"] = _tail_log(payload.get("log_path"))
            else:
                payload.pop("log_path", None)
                payload["log_tail"] = []
                # started_by_email is a real staff email, last_error is
                # internal failure detail -- same "not to anyone who can
                # merely reach the tunnel URL" bar as log_tail above
                # (2026-08-17 security audit: both used to be public
                # regardless of session).
                payload["started_by_email"] = None
                payload["last_error"] = None
            if payload.get("status") == "running":
                progress = _read_progress()
                if progress and progress.get("workspace") == payload.get("workspace"):
                    payload["progress"] = progress
            # Pending requests (Tanda 10) -- same gating as started_by_email
            # above for requested_by_email; never session_id/api_key_name
            # regardless of caller (see _queue_snapshot's own docstring).
            queue = _queue_snapshot()
            if not caller_authenticated:
                queue = [{**entry, "requested_by_email": None} for entry in queue]
            payload["queue"] = queue
            self._send_json(200, payload)
            return

        if parsed.path == "/api/history":
            workspace_filter = (query.get("workspace") or [None])[0]
            runs = _read_history(workspace_filter=workspace_filter)
            # triggered_by_email is a real staff email, error/failed_step is
            # internal failure detail -- gated behind the same bar as
            # log_tail/started_by_email in /api/status (2026-08-17 security
            # audit). The headline counts + per-type breakdown on every row
            # stay public either way, same as /api/history/diff's own note.
            if not self._read_access_allowed():
                runs = [{**row, "triggered_by_email": "", "error": "", "failed_step": ""} for row in runs]
            self._send_json(200, {"runs": runs, "count": len(runs), "source_path": "analysis/single_workspace_scan/history.csv"})
            return

        if parsed.path == "/api/history/diff":
            # Only a signed-in session sees the actual item names/
            # descriptions this reveals -- same gating as log_tail in
            # /api/status. The headline counts + per-type breakdown on
            # every /api/history row above stay public either way.
            if not self._current_session():
                self._send_json(401, {"error": "not_signed_in"})
                return
            diff_path = (query.get("path") or [None])[0]
            if not diff_path:
                self._send_json(400, {"error": "missing_path", "message": "?path= is required."})
                return
            resolved = (REPO_ROOT / diff_path).resolve()
            if DIFF_DIR.resolve() not in resolved.parents or not resolved.exists():
                self._send_json(404, {"error": "diff_not_found", "message": "No diff file at that path."})
                return
            with open(resolved, "r", encoding="utf-8") as handle:
                self._send_json(200, json.load(handle))
            return

        if parsed.path == "/api/auth/me":
            # demo_mode rides along on BOTH answers so the frontend learns
            # it from the call it already makes at boot: with no session
            # this is still a 401 (nobody is signed in, and every
            # session-only route still refuses), and app.js's init() only
            # skips its sign-in gate when the server itself says demo mode
            # is on. It never grants anything: reads are widened by
            # _read_access_allowed, writes never look at demo mode at all.
            demo_mode = _demo_mode_enabled()
            session = self._current_session()
            if not session:
                self._send_json(401, {"error": "not_signed_in", "demo_mode": demo_mode})
                return
            settings = _load_admin_settings()
            self._send_json(200, {
                "demo_mode": demo_mode,
                "user_email": session["user_email"],
                "user_name": session["user_name"],
                "object_id": session.get("object_id", ""),
                "tenant_id": session.get("tenant_id", ""),
                "created_at": session.get("created_at", ""),
                "is_admin": _email_in_allowlist(session["user_email"], settings, "admin_emails"),
                "can_full_scan": _email_in_allowlist(session["user_email"], settings, "full_scan_emails"),
                # Whether this account holds the Entra ID "Fabric
                # Administrator" role -- unrelated to is_admin above (this
                # project's own admin_emails allowlist). Checked once at
                # sign-in (see auth._create_session_from_token_result);
                # informs the user before they click a scan button that a
                # full scan from them will cover the whole tenant, not just
                # their own accessible workspaces.
                "is_fabric_tenant_admin": bool(session.get("is_fabric_tenant_admin")),
            })
            return

        if parsed.path == "/api/auth/device-status":
            flow_id = (query.get("flow_id") or [None])[0]
            result, error = _poll_device_flow(flow_id)
            if error:
                status_code = {"flow_not_found": 404, "device_flow_failed": 400}.get(error["error"], 500)
                self._send_json(status_code, error)
                return
            if result.get("status") == "done":
                # session_id is the bearer credential -- it goes in the
                # HttpOnly cookie only. Echoing it in the JSON body too (as
                # this used to do, since `result` already carried it for the
                # set_cookie= call below) let any JS on the page read it
                # straight off the fetch() response, defeating HttpOnly
                # (2026-08-26 security audit finding).
                body = {key: value for key, value in result.items() if key != "session_id"}
                self._send_json(200, body, set_cookie=result["session_id"])
                return
            self._send_json(200, result)
            return

        if parsed.path == "/api/admin/settings":
            settings = self._require_admin()
            if settings is None:
                return
            # Never echo external_sources' password_ref target values back --
            # it is only ever a pointer to an env var name, not a secret
            # itself, so this is just being consistent, not withholding data.
            # api_keys IS a secret itself and gets masked -- see _mask_api_keys.
            self._send_json(200, _mask_api_keys(settings))
            return

        if parsed.path == "/api/admin/sessions":
            if self._require_admin() is None:
                return
            self._send_json(200, {"sessions": _list_sessions_for_admin()})
            return

        if parsed.path == "/api/admin/session-history":
            if self._require_admin() is None:
                return
            self._send_json(200, {"sessions": _list_session_history_for_admin()})
            return

        if parsed.path == "/api/admin/metrics":
            if self._require_admin() is None:
                return
            self._send_json(200, _metrics_snapshot())
            return

        if parsed.path == "/api/admin/usage-analytics":
            if self._require_admin() is None:
                return
            days = _parse_analytics_days(query)
            self._send_json(200, analytics.get_usage_analytics(days=days))
            return

        if parsed.path == "/api/admin/mcp-usage-analytics":
            if self._require_admin() is None:
                return
            days = _parse_analytics_days(query)
            self._send_json(200, analytics.get_mcp_usage_analytics(days=days))
            return

        if parsed.path == "/api/admin/access-audit":
            if self._require_admin_or_api_key() is None:
                return
            self._send_json(200, _get_access_audit())
            return

        if parsed.path == "/api/admin/governance-scan":
            if self._require_admin_or_api_key() is None:
                return
            self._send_json(200, _get_governance_scan_overview())
            return

        if parsed.path == "/api/admin/data-quality-overview":
            # Same admin_or_api_key trust bar as the governance/sensitivity
            # routes above -- same reasoning: mcp_server_remote.py/
            # mcp_http_server.py need to reach this too (Roadmap Fase 1).
            settings = self._require_admin_or_api_key()
            if settings is None:
                return
            self._send_json(200, _get_data_quality_overview(settings))
            return

        if parsed.path == "/api/admin/privacy-coverage-map":
            # Roadmap Fase 5 (privacy/data-subject-rights locator): same
            # admin_or_api_key trust bar as the governance/sensitivity
            # routes above.
            settings = self._require_admin_or_api_key()
            if settings is None:
                return
            # Classifies every row of dbo.bronze_object_column_catalog
            # against 20+ categories -- belt-and-suspenders try/except (same
            # pattern as add_comment elsewhere in this file) so an edge case
            # in real production data degrades to a clean 503 instead of a
            # raw traceback/connection reset, which a fetch() on the
            # frontend can't distinguish from "server is completely down".
            try:
                result = _get_privacy_coverage_map(settings)
            except Exception as exc:  # noqa: BLE001 - see comment above
                self._send_json(503, {"error": "privacy_locator_failed", "message": str(exc)})
                return
            self._send_json(200, result)
            return

        if parsed.path == "/api/admin/privacy-framework-map":
            # Roadmap Fase 6 (follow-up to Fase 5): same data grouped by
            # legal framework (GDPR/FERPA/CCPA) first, plus admin-logged
            # external systems -- same admin_or_api_key trust bar as the
            # routes above. Same defensive try/except as privacy-coverage-
            # map just above, same reasoning.
            settings = self._require_admin_or_api_key()
            if settings is None:
                return
            try:
                result = _get_privacy_framework_map(settings)
            except Exception as exc:  # noqa: BLE001 - see privacy-coverage-map's own comment above
                self._send_json(503, {"error": "privacy_locator_failed", "message": str(exc)})
                return
            self._send_json(200, result)
            return

        if parsed.path == "/api/admin/detected-external-sources":
            if self._require_admin() is None:
                return
            self._send_json(200, _get_detected_external_origins())
            return

        if parsed.path == "/api/admin/installer/notebooks":
            if self._require_admin() is None:
                return
            notebooks = installer.available_notebooks()
            self._send_json(200, {
                "notebooks": [
                    {"name": name, "is_core": name in installer.CORE_NOTEBOOK_ORDER}
                    for name in installer.CORE_NOTEBOOK_ORDER + installer.EXTRA_NOTEBOOKS
                    if name in notebooks
                ],
                "variables": installer.scan_tenant_variables(),
                "manual_pipeline_step": installer.MANUAL_PIPELINE_STEP,
                "pipeline_order": installer.CORE_NOTEBOOK_ORDER,
            })
            return

        if parsed.path == "/api/admin/installer/status":
            if self._require_admin() is None:
                return
            with _installer_lock:
                self._send_json(200, dict(_installer_state))
            return

        if parsed.path == "/api/admin/notifications-summary":
            settings = self._require_admin()
            if settings is None:
                return
            # sample_limit=0 (2026-08-18): the notifications badge/panel only
            # need the flagged-column COUNT, not real sample rows -- same
            # underlying bronze_column_sensitivity_content read as the
            # Sensitivity tab's own overview, just without the per-category
            # sample payload this call doesn't use.
            sensitivity = _get_content_sensitivity_overview(sample_limit=0, settings=settings)
            self._send_json(200, {
                "external_sources": _summarize_pending_external_sources(settings),
                "sensitivity": {
                    "found": sensitivity.get("found", False),
                    "flagged_column_count": sensitivity.get("flagged_column_count", 0),
                    "checked_table_count": sensitivity.get("checked_table_count", 0),
                },
            })
            return

        if parsed.path == "/api/admin/fabric-connections":
            if self._require_admin() is None:
                return
            session = self._current_session()
            if not session:
                self._send_json(200, {"connections": []})
                return
            settings = _load_admin_settings()
            access_token = _acquire_scoped_token(session, settings, FABRIC_TOKEN_SCOPES) or session.get("access_token")
            connections, error = _fetch_connections(access_token) if access_token else (None, "not_signed_in")
            self._send_json(200, {"connections": connections or [], "error": error if not connections else None})
            return

        if parsed.path == "/api/admin/tenant-users":
            if self._require_admin() is None:
                return
            session = self._current_session()
            query_text = (query.get("q") or [""])[0]
            results = graph_profile._search_tenant_users(session, _load_admin_settings(), query_text) if session else []
            self._send_json(200, {"users": results})
            return

        if parsed.path == "/api/admin/user-profiles":
            # 2026-08-24: batch-resolve displayName/jobTitle/department for
            # a list of KNOWN emails (?emails=a@x.com,b@x.com) -- used by
            # the "Usuarios por workspace" section to show "puesto" for
            # people who already have a role assignment, as opposed to
            # /api/admin/tenant-users above (a search-as-you-type lookup
            # for ADDING someone new). See graph_profile._fetch_user_
            # profiles for the per-email cache/best-effort behavior.
            if self._require_admin() is None:
                return
            session = self._current_session()
            emails = [e for e in (query.get("emails") or [""])[0].split(",") if e.strip()]
            results = graph_profile._fetch_user_profiles(session, _load_admin_settings(), emails) if session and emails else {}
            self._send_json(200, {"profiles": results})
            return

        if parsed.path == "/api/admin/capacity-insight":
            if self._require_admin() is None:
                return
            result = _get_capacity_insight()
            # Upgrade raw capacity_id labels to real display names via a
            # live Fabric API call (2026-08-18) -- bronze_workspaces never
            # carries a capacity name (see _capacity_label's own docstring
            # in purview_insights.py), so this is the only place one can
            # come from. Also folds in capacities that exist in the tenant
            # but have zero scanned workspaces, so the admin sees ALL of
            # them, not just the ones already represented in scanned data.
            # Best-effort: any failure here (no session token, API error,
            # tenant hasn't consented Capacity.Read.All, ...) just leaves
            # the existing id-only labels in place.
            session = self._current_session()
            settings = _load_admin_settings()
            if session and result.get("found"):
                access_token = _acquire_scoped_token(session, settings, FABRIC_TOKEN_SCOPES) or session.get("access_token")
                live_capacities, _error = _fetch_capacities(access_token) if access_token else (None, None)
                if live_capacities:
                    name_by_id = {c["capacity_id"]: c for c in live_capacities if c.get("capacity_id")}
                    seen_ids = set()
                    for entry in result["capacities"]:
                        candidate_id = (entry.get("capacity_label") or "").split(" ", 1)[0]
                        live = name_by_id.get(candidate_id) if GUID_PATTERN.match(candidate_id) else None
                        if live:
                            entry["capacity_label"] = live["capacity_name"] or entry["capacity_label"]
                            entry["capacity_id"] = candidate_id
                            entry["sku"] = live.get("sku") or ""
                            entry["region"] = live.get("region") or ""
                            entry["state"] = live.get("state") or ""
                            seen_ids.add(candidate_id)
                    for capacity_id, live in name_by_id.items():
                        if capacity_id in seen_ids:
                            continue
                        result["capacities"].append({
                            "capacity_label": live["capacity_name"] or capacity_id,
                            "capacity_id": capacity_id,
                            "sku": live.get("sku") or "",
                            "region": live.get("region") or "",
                            "state": live.get("state") or "",
                            "workspace_count": 0,
                            "item_count": 0,
                            "execution_count": 0,
                            "failed_count": 0,
                        })
                    result["capacities"].sort(key=lambda entry: entry["item_count"], reverse=True)
                    result["capacities_resolved_live"] = True
            # Best-effort real CU column (2026-08-24): only attempted when
            # the admin has actually configured capacity_metrics -- see
            # capacity_metrics.cu_seconds_by_capacity's own docstring for
            # why this is a separate, cheaper query than the full Capacidad
            # tab overview. Matched by capacity_label (the same real
            # display name both this route's live-name resolution above and
            # the Capacity Metrics semantic model use), so this only ever
            # upgrades entries that already got a real name -- an id-only
            # label (no Capacity.Read.All consented) just keeps showing
            # "No disponible", same as before this existed.
            capacity_metrics_config = settings.get("capacity_metrics") if (session and result.get("found")) else None
            if capacity_metrics_config and capacity_metrics._fields_present(capacity_metrics_config):
                cu_by_capacity = capacity_metrics.cu_seconds_by_capacity(capacity_metrics_config, session=session)
                if cu_by_capacity:
                    for entry in result["capacities"]:
                        cu_seconds = cu_by_capacity.get(entry["capacity_label"])
                        if cu_seconds is not None:
                            entry["cu_seconds"] = cu_seconds
            self._send_json(200, result)
            return

        if parsed.path == "/api/admin/capacity-metrics-overview":
            settings = self._require_admin()
            if settings is None:
                return
            config = settings.get("capacity_metrics") or {}
            self._send_json(200, capacity_metrics.get_overview(config, session=self._current_session()))
            return

        if parsed.path == "/api/admin/capacity-metrics/discover":
            settings = self._require_admin()
            if settings is None:
                return
            self._send_json(200, capacity_metrics.discover_installation(self._current_session(), settings))
            return

        if parsed.path == "/api/admin/changes-digest":
            if self._require_admin() is None:
                return
            # ?scan= (2026-08-18) picks one of the response's own
            # available_scans values instead of always the latest scan.
            # ?from=/?to= (2026-08-24, YYYY-MM-DD, either or both) switches
            # to range mode, aggregating every scan in between instead of
            # one -- see _get_changes_digest's own docstring.
            scan_started_at = (query.get("scan") or [None])[0]
            date_from = (query.get("from") or [None])[0]
            date_to = (query.get("to") or [None])[0]
            self._send_json(200, _get_changes_digest(scan_started_at=scan_started_at, date_from=date_from, date_to=date_to))
            return

        if parsed.path == "/api/admin/sensitivity-overview":
            settings = self._require_admin_or_api_key()
            if settings is None:
                return
            self._send_json(200, _get_sensitivity_overview(sample_limit=_parse_sensitivity_sample_limit(query), settings=settings))
            return

        if parsed.path == "/api/admin/content-sensitivity-overview":
            # Roadmap Fase 2 (2026-08-18): the content-VERIFIED counterpart
            # to sensitivity-overview above -- see purview_insights.
            # _get_content_sensitivity_overview's own docstring for why
            # this is a separate route (different underlying table,
            # different confidence level) rather than merging into it.
            settings = self._require_admin_or_api_key()
            if settings is None:
                return
            self._send_json(200, _get_content_sensitivity_overview(sample_limit=_parse_sensitivity_sample_limit(query), settings=settings))
            return

        if parsed.path == "/api/node-comments":
            if not self._current_session():
                self._send_json(401, {"error": "not_signed_in"})
                return
            qualified_name = (query.get("qualified_name") or [""])[0]
            if not qualified_name:
                self._send_json(400, {"error": "invalid_request", "message": "?qualified_name= is required."})
                return
            self._send_json(200, {"comments": collaboration.get_comments(qualified_name)})
            return

        if parsed.path == "/api/column-profile":
            # Session-gated same as /data/* -- this is real production
            # data (null %, distinct counts, safe min/max), not curated
            # metadata. Same "not found means not profiled yet" contract
            # as _get_column_profile itself (roadmap Fase 2, 2026-08-17,
            # scope: only Fabric-native Lakehouse tables the service
            # principal already had a data role in -- see docs/105).
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            workspace_name = (query.get("workspace_name") or [""])[0]
            lakehouse_name = (query.get("lakehouse_name") or [""])[0]
            table_name = (query.get("table_name") or [""])[0]
            if not workspace_name or not lakehouse_name or not table_name:
                self._send_json(400, {"error": "invalid_request", "message": "?workspace_name=&lakehouse_name=&table_name= are all required."})
                return
            self._send_json(200, _get_column_profile(workspace_name, lakehouse_name, table_name))
            return

        if parsed.path == "/api/data-quality":
            # Same auth level and query contract as /api/column-profile --
            # see that endpoint's own comment. Evaluates whatever rules an
            # admin has already defined against this table (Roadmap Fase 1,
            # see data_quality.py's own docstring) -- {found: False} just
            # means "no rule targets this table yet", not an error.
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            workspace_name = (query.get("workspace_name") or [""])[0]
            lakehouse_name = (query.get("lakehouse_name") or [""])[0]
            table_name = (query.get("table_name") or [""])[0]
            if not workspace_name or not lakehouse_name or not table_name:
                self._send_json(400, {"error": "invalid_request", "message": "?workspace_name=&lakehouse_name=&table_name= are all required."})
                return
            self._send_json(200, _get_data_quality_for_table(_load_admin_settings(), workspace_name, lakehouse_name, table_name))
            return

        if parsed.path == "/api/column-sensitivity":
            # Same auth level and query contract as /api/column-profile --
            # see that endpoint's own comment. The underlying table never
            # carries a real cell value (see catalog._get_column_
            # sensitivity's own comment), only match percentages, so this
            # is safe at the same visibility level as the profile data.
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            workspace_name = (query.get("workspace_name") or [""])[0]
            lakehouse_name = (query.get("lakehouse_name") or [""])[0]
            table_name = (query.get("table_name") or [""])[0]
            if not workspace_name or not lakehouse_name or not table_name:
                self._send_json(400, {"error": "invalid_request", "message": "?workspace_name=&lakehouse_name=&table_name= are all required."})
                return
            self._send_json(200, _get_column_sensitivity(workspace_name, lakehouse_name, table_name))
            return

        if parsed.path == "/api/node-favorites/mine":
            session = self._current_session()
            if not session:
                self._send_json(401, {"error": "not_signed_in"})
                return
            self._send_json(200, {"qualified_names": collaboration.get_my_favorites(session["user_email"])})
            return

        if parsed.path == "/api/business-glossary":
            # Session-level, not admin-only -- unlike the admin-curated
            # /api/admin/settings this reads from (lakehouse connection
            # strings, SMTP password_ref, API keys), the business glossary
            # itself is meant for every signed-in user to browse, the same
            # way the existing tool-concept glossary already is. Also
            # accepts an API key (2026-08-18, roadmap "MCP remoto para
            # toda la empresa") -- same read-only catalog data an
            # authenticated agent needs, same trust bar as /api/items etc.
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            settings = _load_admin_settings()
            self._send_json(200, {"terms": settings.get("business_glossary") or []})
            return

        if parsed.path == "/api/data-products":
            # Roadmap Fase 3: same session_or_api_key trust bar as
            # /api/certifications/tags/business-glossary above -- the
            # admin-curated data-product list (name, owner, description,
            # linked qualified_names), Purview-Unified-Catalog-style.
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            settings = _load_admin_settings()
            self._send_json(200, {"data_products": settings.get("data_products") or []})
            return

        if parsed.path == "/api/certifications":
            # Same session_or_api_key trust bar as /api/business-glossary --
            # the admin-curated "certified/official source" list, for any
            # signed-in user (or agent) to browse, not just the admin panel
            # that curates it (2026-08-18: surfaces in the primary detail
            # panel too, not just Graph Map Mode -- see app.js).
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            settings = _load_admin_settings()
            self._send_json(200, {"certifications": settings.get("certified_items") or []})
            return

        if parsed.path == "/api/tags":
            # Same idea as /api/certifications just above -- the admin-
            # curated free-form tags list, distinct from an item's native
            # Fabric tags (data.tags, already in the item payload).
            if not self._read_access_allowed():
                self._send_json(401, {"error": "not_signed_in"})
                return
            settings = _load_admin_settings()
            self._send_json(200, {"tags": settings.get("tags") or []})
            return

        if parsed.path == "/api/admin/api-keys":
            settings = self._require_admin()
            if settings is None:
                return
            # The raw key is only ever returned once, at creation (POST,
            # below) -- everywhere else (including here) only a short
            # preview is shown, so this list can't be used to recover a
            # key that was lost after the creation screen was closed.
            masked = _mask_api_keys(settings)
            self._send_json(200, {"api_keys": masked["api_keys"], "revoked_api_keys": masked["revoked_api_keys"]})
            return

        if parsed.path == "/api/workspaces/mine":
            session = self._current_session()
            if not session:
                self._send_json(401, {"error": "not_signed_in"})
                return
            # The raw token captured at sign-in can go stale (Entra access
            # tokens are typically only good for ~60-90 minutes) well before
            # a session itself expires -- refresh it from the session's MSAL
            # cache first, same fix as _start_full_scan's own discovery
            # calls (e.g. a signed-in user who comes back to the page a
            # couple of hours after signing in).
            settings = _load_admin_settings()
            access_token = _acquire_scoped_token(session, settings, FABRIC_TOKEN_SCOPES) or session["access_token"]
            workspaces, error = _fetch_my_workspaces(access_token)
            if error:
                self._send_json(502, {"error": "fabric_api_error", "message": error})
                return
            # ?min_role=contributor (2026-08-24, the admin panel's
            # individual-workspace-scan picker): narrows down to workspaces
            # where the signed-in user is Admin/Member/Contributor, not
            # merely a Viewer -- see fabric_api._filter_workspaces_by_min_
            # role's own docstring for why this needs one roleAssignments
            # call per workspace (Fabric's plain listing has no role field).
            if (query.get("min_role") or [""])[0] == "contributor":
                workspaces = _filter_workspaces_by_min_role(access_token, workspaces, session["user_email"])
            self._send_json(200, {"workspaces": workspaces, "count": len(workspaces)})
            return

        if parsed.path.startswith("/api/workspaces/") and parsed.path.endswith("/lakehouses"):
            session = self._current_session()
            if not session:
                self._send_json(401, {"error": "not_signed_in"})
                return
            workspace_id = parsed.path[len("/api/workspaces/"):-len("/lakehouses")]
            # Fabric IDs are always GUIDs -- reject anything else before it
            # gets spliced into the Fabric API URL below (defense in depth;
            # FABRIC_API_BASE_URL itself is a hardcoded host, so this can't
            # become cross-host SSRF, but an unvalidated path segment could
            # still call an unintended path under that host).
            if not GUID_PATTERN.match(workspace_id):
                self._send_json(400, {"error": "invalid_request", "message": "workspace id must be a GUID."})
                return
            settings = _load_admin_settings()
            access_token = _acquire_scoped_token(session, settings, FABRIC_TOKEN_SCOPES) or session["access_token"]
            lakehouses, error = _fetch_lakehouses_in_workspace(access_token, workspace_id)
            if error:
                self._send_json(502, {"error": "fabric_api_error", "message": error})
                return
            self._send_json(200, {"lakehouses": lakehouses, "count": len(lakehouses)})
            return

        if parsed.path.startswith("/api/workspaces/") and parsed.path.endswith("/warehouses"):
            session = self._current_session()
            if not session:
                self._send_json(401, {"error": "not_signed_in"})
                return
            workspace_id = parsed.path[len("/api/workspaces/"):-len("/warehouses")]
            if not GUID_PATTERN.match(workspace_id):
                self._send_json(400, {"error": "invalid_request", "message": "workspace id must be a GUID."})
                return
            settings = _load_admin_settings()
            access_token = _acquire_scoped_token(session, settings, FABRIC_TOKEN_SCOPES) or session["access_token"]
            warehouses, error = _fetch_warehouses_in_workspace(access_token, workspace_id)
            if error:
                self._send_json(502, {"error": "fabric_api_error", "message": error})
                return
            self._send_json(200, {"warehouses": warehouses, "count": len(warehouses)})
            return

        if parsed.path.startswith("/api/workspaces/") and parsed.path.endswith("/pipelines"):
            # 2026-08-18, admin-panel completeness pass: same live picker
            # the Lakehouse tab already has, for the Fabric-pipeline tab.
            session = self._current_session()
            if not session:
                self._send_json(401, {"error": "not_signed_in"})
                return
            workspace_id = parsed.path[len("/api/workspaces/"):-len("/pipelines")]
            if not GUID_PATTERN.match(workspace_id):
                self._send_json(400, {"error": "invalid_request", "message": "workspace id must be a GUID."})
                return
            settings = _load_admin_settings()
            access_token = _acquire_scoped_token(session, settings, FABRIC_TOKEN_SCOPES) or session["access_token"]
            pipelines, error = _fetch_data_pipelines_in_workspace(access_token, workspace_id)
            if error:
                self._send_json(502, {"error": "fabric_api_error", "message": error})
                return
            self._send_json(200, {"pipelines": pipelines, "count": len(pipelines)})
            return

        if parsed.path == "/mcp_server_remote.py":
            # 2026-08-24: downloadable straight from this running server so
            # setting up the remote MCP agent needs no local repo checkout
            # ("todo remoto" -- local Fabric/repo access isn't a commercial
            # option) -- just this one file plus `pip install mcp`. Gated
            # on any signed-in session (not admin-only): an already-issued
            # API key is what actually authorizes MCP calls, same as any
            # other X-Api-Key caller: creating that key stays admin-only
            # (POST /api/admin/api-keys), this download does not hand out
            # anything sensitive on its own.
            if not self._current_session():
                self._send_json(401, {"error": "not_signed_in"})
                return
            if not MCP_SERVER_REMOTE_PATH.exists():
                self._send_error(404, "Not Found")
                return
            body = MCP_SERVER_REMOTE_PATH.read_bytes()
            self._record_metric(200)
            self.send_response(200)
            self._send_security_headers()
            self.send_header("Content-Type", "text/x-python; charset=utf-8")
            self.send_header("Content-Disposition", 'attachment; filename="mcp_server_remote.py"')
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)
            return

        if parsed.path == "/mcp":
            self._proxy_to_mcp_http_server("GET", None)
            return

        self._serve_static(parsed.path)

    def do_HEAD(self):
        parsed_path = urlparse(self.path).path
        if parsed_path == "/mcp":
            self._proxy_to_mcp_http_server("HEAD", None)
            return
        self._serve_static(parsed_path)

    def do_DELETE(self):
        # Streamable HTTP's optional explicit session-termination call
        # (2026-08-24) -- the only DELETE this server handles at all, so
        # anything else 404s via the same _serve_static fallback GET/HEAD
        # already use (do_DELETE didn't exist before /mcp needed it).
        parsed = urlparse(self.path)
        if parsed.path == "/mcp":
            self._proxy_to_mcp_http_server("DELETE", None)
            return
        self._send_error(404, "Not Found")

    def do_POST(self):
        parsed = urlparse(self.path)
        raw_body = self._read_request_body()
        if raw_body is None:
            return  # _read_request_body() already sent a 413 and closed the connection

        if parsed.path == "/mcp":
            self._proxy_to_mcp_http_server("POST", raw_body)
            return

        if parsed.path.startswith("/api/"):
            allowed, retry_after = _check_rate_limit(self._client_ip())
            if not allowed:
                self._send_json(
                    429,
                    {"error": "rate_limited", "message": f"Too many requests. Retry after {retry_after}s."},
                    extra_headers={"Retry-After": str(retry_after)},
                )
                return
            if not self._validate_csrf_origin():
                return

        if parsed.path == "/api/auth/device-start":
            result, error = _start_device_flow(self._client_ip(), self.headers.get("User-Agent", ""))
            if error:
                status_code = {"too_many_pending_flows": 429}.get(error["error"], 400)
                self._send_json(status_code, error)
                return
            self._send_json(202, result)
            return

        if parsed.path == "/api/auth/logout":
            cookie_header = self.headers.get("Cookie")
            session_id = None
            if cookie_header:
                cookie = SimpleCookie()
                cookie.load(cookie_header)
                morsel = cookie.get(SESSION_COOKIE_NAME)
                if morsel:
                    session_id = morsel.value
            _end_session(session_id)
            self._send_json(200, {"status": "signed_out"}, clear_cookie=True)
            return

        if parsed.path == "/api/analytics/event":
            # Fire-and-forget from app.js's trackUsageEvent -- never a hard
            # error the caller needs to handle, best-effort like every
            # other write in analytics.py (see record_usage_event's own
            # docstring). Still requires sign-in (this whole app already
            # does, see auth.py) so user_email is real, not anonymous.
            session = self._current_session()
            if not session:
                self._send_json(401, {"error": "not_signed_in"})
                return
            try:
                body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                body = {}
            analytics.record_usage_event(
                str(body.get("event_type", "")), str(body.get("qualified_name", "")), str(body.get("item_type", "")), session,
            )
            self._send_json(200, {"status": "recorded"})
            return

        if parsed.path == "/api/node-comments":
            session = self._current_session()
            if not session:
                self._send_json(401, {"error": "not_signed_in"})
                return
            try:
                body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            qualified_name = str(body.get("qualified_name", "")).strip()
            comment_text = str(body.get("comment_text", "")).strip()
            if not qualified_name or not comment_text:
                self._send_json(400, {"error": "invalid_request", "message": "qualified_name and comment_text are both required."})
                return
            if len(comment_text) > collaboration.MAX_COMMENT_LENGTH:
                self._send_json(400, {"error": "invalid_request", "message": f"Comments are limited to {collaboration.MAX_COMMENT_LENGTH} characters."})
                return
            try:
                row = collaboration.add_comment(qualified_name, session["user_email"], session.get("user_name", ""), comment_text)
            except Exception as exc:  # noqa: BLE001 - WarehouseError and friends, surfaced as a clean 503 instead of a raw traceback
                self._send_json(503, {"error": "warehouse_unavailable", "message": str(exc)})
                return
            self._send_json(201, row)
            return

        if parsed.path == "/api/node-comments/delete":
            session = self._current_session()
            if not session:
                self._send_json(401, {"error": "not_signed_in"})
                return
            try:
                body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            comment_id = str(body.get("comment_id", "")).strip()
            if not comment_id:
                self._send_json(400, {"error": "invalid_request", "message": "comment_id is required."})
                return
            settings = _load_admin_settings()
            is_admin = _email_in_allowlist(session["user_email"], settings, "admin_emails")
            try:
                ok, error_code = collaboration.delete_comment(comment_id, session["user_email"], is_admin)
            except Exception as exc:  # noqa: BLE001
                self._send_json(503, {"error": "warehouse_unavailable", "message": str(exc)})
                return
            if not ok:
                status_code = 403 if error_code == "forbidden" else 404
                self._send_json(status_code, {"error": error_code})
                return
            self._send_json(200, {"status": "deleted"})
            return

        if parsed.path == "/api/node-favorites/toggle":
            session = self._current_session()
            if not session:
                self._send_json(401, {"error": "not_signed_in"})
                return
            try:
                body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            qualified_name = str(body.get("qualified_name", "")).strip()
            if not qualified_name:
                self._send_json(400, {"error": "invalid_request", "message": "qualified_name is required."})
                return
            try:
                favorited = collaboration.toggle_favorite(qualified_name, session["user_email"])
            except Exception as exc:  # noqa: BLE001
                self._send_json(503, {"error": "warehouse_unavailable", "message": str(exc)})
                return
            self._send_json(200, {"favorited": favorited})
            return

        if parsed.path == "/api/admin/settings":
            if self._require_admin() is None:
                return
            try:
                incoming = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            if not incoming.get("tenant_id") or not incoming.get("admin_emails"):
                self._send_json(400, {"error": "invalid_request", "message": "tenant_id and a non-empty admin_emails list are required -- an empty admin allowlist would lock everyone out, including you."})
                return
            # api_keys is managed exclusively through POST/DELETE /api/admin/
            # api-keys[/revoke] -- this generic settings save always echoes
            # the (masked) GET response back as adminSettingsCache client-
            # side, so accepting it here too would let any unrelated save
            # (e.g. toggling allow_anonymous_scans) silently overwrite every
            # real API key with its own masked preview, destroying them.
            incoming.pop("api_keys", None)
            settings = _merge_admin_settings(_default_admin_settings(), incoming)
            _write_admin_settings(settings)
            self._send_json(200, _mask_api_keys(settings))
            return

        if parsed.path == "/api/admin/sessions/revoke":
            settings = self._require_admin()
            if settings is None:
                return
            try:
                body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            revoked_count = _revoke_sessions_for_email(body.get("email"))
            self._send_json(200, {"status": "revoked", "revoked_count": revoked_count})
            return

        if parsed.path == "/api/admin/api-keys":
            settings = self._require_admin()
            if settings is None:
                return
            try:
                body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            name = str(body.get("name", "")).strip()
            if not name:
                self._send_json(400, {"error": "invalid_request", "message": "A non-empty 'name' is required (e.g. 'Fabric pipeline - nightly refresh')."})
                return
            if any(entry.get("name") == name for entry in settings.get("api_keys") or []):
                self._send_json(409, {"error": "duplicate_name", "message": f"An API key named '{name}' already exists. Revoke it first or pick a different name."})
                return
            # 2026-08-18, admin-panel completeness pass: description/scope/
            # expires_at, plus created_by captured server-side (the admin
            # creating it is already known from their own session, no need
            # to ask). scope defaults to "read_only" -- new keys have to be
            # deliberately opted into scan control, unlike every key before
            # this being an implicit skeleton key (see _valid_api_key's own
            # comment on why a legacy/missing scope still means "full").
            # `or ""` (not a plain .get default) so an explicit JSON `null`
            # doesn't become the literal string "None".
            description = str(body.get("description") or "").strip()
            scope = body.get("scope") if body.get("scope") in ("read_only", "full") else "read_only"
            expires_at = str(body.get("expires_at") or "").strip()
            if expires_at:
                # Fail closed at the boundary: an unparseable value stored
                # as-is would silently mean "never expires" while the admin
                # panel still displays it as if it were a real date (2026-
                # 08-18 code review finding) -- reject it here instead.
                try:
                    datetime.fromisoformat(expires_at.replace("Z", "+00:00"))
                except ValueError:
                    self._send_json(400, {"error": "invalid_request", "message": "expires_at must be a valid ISO timestamp (e.g. 2026-12-31T23:59:59+00:00), or omitted for never."})
                    return
            session = self._current_session()
            raw_key = _generate_api_key()
            # Only the hash + a short preview are persisted -- the raw
            # value below is the one and only copy that ever exists
            # outside this function's local variable (2026-08-17 security
            # audit; previously stored in admin_settings.json verbatim).
            settings.setdefault("api_keys", []).append({
                "name": name,
                "key_hash": _hash_api_key(raw_key),
                "key_preview": "..." + raw_key[-4:],
                "created_at": _now_iso(),
                "description": description,
                "created_by": session["user_email"] if session else "",
                "scope": scope,
                "expires_at": expires_at,
            })
            _write_admin_settings(settings)
            # The one and only time the raw key is ever sent back -- the
            # caller must copy it now (into the Fabric pipeline's Web
            # activity header config, or wherever it's consumed).
            self._send_json(201, {"name": name, "key": raw_key, "created_at": settings["api_keys"][-1]["created_at"]})
            return

        if parsed.path == "/api/admin/api-keys/revoke":
            settings = self._require_admin()
            if settings is None:
                return
            try:
                body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            name = str(body.get("name", "")).strip()
            revoked_entries = [entry for entry in settings.get("api_keys") or [] if entry.get("name") == name]
            settings["api_keys"] = [entry for entry in settings.get("api_keys") or [] if entry.get("name") != name]
            revoked = len(revoked_entries)
            if revoked:
                # Small audit trail (2026-08-18, admin-panel completeness
                # pass) instead of a silent hard-delete -- who revoked
                # which key and when. Never key_hash; nothing here was
                # ever a secret. Bounded to the most recent 100 entries so
                # this can't grow unbounded in admin_settings.json.
                session = self._current_session()
                revoked_log = settings.setdefault("revoked_api_keys", [])
                for entry in revoked_entries:
                    revoked_log.append({
                        "name": entry.get("name", ""),
                        "key_preview": entry.get("key_preview", ""),
                        "description": entry.get("description", ""),
                        "revoked_at": _now_iso(),
                        "revoked_by": session["user_email"] if session else "",
                    })
                settings["revoked_api_keys"] = revoked_log[-100:]
                _write_admin_settings(settings)
            self._send_json(200, {"status": "revoked" if revoked else "not_found", "revoked_count": revoked})
            return

        if parsed.path == "/api/admin/external-sources/test":
            if self._require_admin() is None:
                return
            try:
                body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            # index is optional and only present once app.js knows which
            # SAVED row this is (see testExternalSourceConnection) -- a
            # brand-new, never-saved row has no disk counterpart to persist
            # the result onto, and that's fine, see _persist_external_
            # source_test_result's own docstring for why this never touches
            # anything else in the list.
            source = body.get("source") if isinstance(body, dict) and "source" in body else body
            index = body.get("index") if isinstance(body, dict) else None
            result = _test_external_source(source, session=self._current_session())
            if index is not None:
                _persist_external_source_test_result(index, source, result)
            self._send_json(200, result)
            return

        if parsed.path == "/api/admin/installer/start":
            if self._require_admin() is None:
                return
            try:
                config = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            required = ["tenant_id", "client_id", "client_secret", "workspace_name"]
            missing = [key for key in required if not config.get(key)]
            if missing:
                self._send_json(400, {"error": "missing_fields", "message": f"Faltan campos obligatorios: {', '.join(missing)}."})
                return
            with _installer_lock:
                if _installer_state["status"] == "running":
                    self._send_json(409, {"error": "already_running", "message": "Ya hay una instalación en curso."})
                    return
                _installer_state.update({
                    "status": "running", "current_step": None, "message": "",
                    "log": [], "started_at": _now_iso(), "ended_at": None,
                })

            def on_step(step, message, ok):
                with _installer_lock:
                    _installer_state["current_step"] = step
                    _installer_state["message"] = message
                    _installer_state["log"].append({"step": step, "message": message, "ok": bool(ok), "at": _now_iso()})
                    if step in ("done", "error"):
                        _installer_state["status"] = "succeeded" if step == "done" else "failed"
                        _installer_state["ended_at"] = _now_iso()

            def run():
                try:
                    installer.run_install(config, on_step)
                finally:
                    with _installer_lock:
                        if _installer_state["status"] == "running":
                            # run_install returned without ever calling
                            # on_step("done"/"error", ...) -- a step failed
                            # and returned early (see its own early-return
                            # branches); the log already explains why.
                            _installer_state["status"] = "failed"
                            _installer_state["ended_at"] = _now_iso()

            threading.Thread(target=run, daemon=True).start()
            self._send_json(200, {"status": "started"})
            return

        if parsed.path == "/api/admin/sensitivity/scan-selected":
            # Fase 6 (2026-08-24): targeted content-sensitivity scan --
            # triggers the SAME pipeline "escaneo completo" already uses
            # (there is no way to run a single Fabric notebook activity in
            # isolation without the admin having manually added a second
            # pipeline for it, which this project doesn't assume), but
            # passes a TargetColumnsFilter parameter alongside
            # WorkspaceNameFilter -- NB_Discover_Column_Sensitivity.py
            # reads it and restricts its (expensive) real-content sampling
            # to just these columns instead of every text column in its
            # scope. Harmless no-op on a pipeline that hasn't had this
            # parameter added yet (same "silently ignored, not an error"
            # property WorkspaceNameFilter itself has always had).
            if self._require_admin() is None:
                return
            try:
                body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            columns = body.get("columns") or []
            if not columns:
                self._send_json(400, {"error": "no_columns", "message": "Selecciona al menos una tabla."})
                return
            # Table granularity, not column -- see NB_Discover_Column_
            # Sensitivity.py's own "## Parámetros" comment for why (the
            # name-based sensitivity list this selection comes from only
            # knows which OBJECTS have a suspicious column, not which one).
            target_filter = ";".join(
                f"{c.get('workspace_name', '')}::{c.get('table_name', '')}"
                for c in columns
                if c.get("workspace_name") and c.get("table_name")
            )
            try:
                job_instance_id = fabric_pipeline.trigger_pipeline_run(
                    session=self._current_session(), extra_parameters={"TargetColumnsFilter": target_filter},
                )
            except fabric_pipeline.FabricPipelineError as exc:
                self._send_json(502, {"error": "trigger_failed", "message": str(exc)})
                return
            self._send_json(200, {"status": "started", "job_instance_id": job_instance_id, "column_count": len(columns)})
            return

        if parsed.path == "/api/admin/create-workspace":
            if self._require_admin() is None:
                return
            try:
                config = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            required = ["tenant_id", "client_id", "client_secret", "workspace_name"]
            missing = [key for key in required if not config.get(key)]
            if missing:
                self._send_json(400, {"error": "missing_fields", "message": f"Faltan campos obligatorios: {', '.join(missing)}."})
                return
            with _installer_lock:
                if _installer_state["status"] == "running":
                    self._send_json(409, {"error": "already_running", "message": "Ya hay una operación de alta/instalación en curso."})
                    return
                _installer_state.update({
                    "status": "running", "current_step": None, "message": "",
                    "log": [], "started_at": _now_iso(), "ended_at": None,
                })

            def on_step(step, message, ok):
                with _installer_lock:
                    _installer_state["current_step"] = step
                    _installer_state["message"] = message
                    _installer_state["log"].append({"step": step, "message": message, "ok": bool(ok), "at": _now_iso()})
                    if step in ("done", "error"):
                        _installer_state["status"] = "succeeded" if step == "done" else "failed"
                        _installer_state["ended_at"] = _now_iso()

            def run():
                try:
                    installer.create_workspace_and_item(config, on_step)
                finally:
                    with _installer_lock:
                        if _installer_state["status"] == "running":
                            _installer_state["status"] = "failed"
                            _installer_state["ended_at"] = _now_iso()

            threading.Thread(target=run, daemon=True).start()
            self._send_json(200, {"status": "started"})
            return

        if parsed.path == "/api/admin/lakehouse/test":
            settings = self._require_admin()
            if settings is None:
                return
            try:
                lakehouse = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            # Same fallback _mirror_lakehouse_target_config already applies
            # for the real upload: a blank Tenant ID field just means "use
            # the tenant configured in the Tenant tab", not "no tenant".
            if not lakehouse.get("sp_tenant_id"):
                lakehouse["sp_tenant_id"] = settings.get("tenant_id", "")
            self._send_json(200, _test_lakehouse_connection(lakehouse, session=self._current_session()))
            return

        if parsed.path == "/api/admin/discovery-pipeline/test":
            settings = self._require_admin()
            if settings is None:
                return
            try:
                pipeline_config = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            if not pipeline_config.get("sp_tenant_id"):
                pipeline_config["sp_tenant_id"] = settings.get("tenant_id", "")
            self._send_json(200, fabric_pipeline.test_connection(pipeline_config, session=self._current_session()))
            return

        if parsed.path == "/api/admin/fabric-connections/test":
            # Tests THROUGH the assigned gateway (2026-08-18) -- unlike
            # every other "Probar conexión" button here, which always
            # connects directly from wherever this server runs and so can
            # never succeed for an on-premises external source, this asks
            # the gateway itself via Fabric's own testConnection API. See
            # fabric_api._test_fabric_connection's own docstring for the
            # long-running-operation contract this polls through.
            settings = self._require_admin()
            if settings is None:
                return
            try:
                body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            connection_id = (body.get("connection_id") or "").strip()
            source_index = body.get("source_index")
            if not connection_id:
                self._send_json(400, {"error": "invalid_request", "message": "connection_id is required."})
                return
            session = self._current_session()
            access_token = (_acquire_scoped_token(session, settings, FABRIC_TOKEN_SCOPES) if session else None) or (session.get("access_token") if session else None)
            if not access_token:
                self._send_json(200, {"ok": False, "message": "No signed-in Fabric session available to run this test."})
                return
            result, error = _test_fabric_connection(access_token, connection_id)
            if error:
                self._send_json(200, {"ok": False, "message": error})
                return
            # Persisted onto the source (2026-08-18) so the notifications
            # summary can flag a since-broken connection without re-testing
            # live on every page load -- this call alone can take up to a
            # minute, far too slow to run on every /api/admin/notifications-
            # summary fetch.
            sources = settings.get("external_sources") or []
            if isinstance(source_index, int) and 0 <= source_index < len(sources):
                sources[source_index]["fabric_connection_last_test_status"] = result.get("status")
                sources[source_index]["fabric_connection_last_test_at"] = _now_iso()
                _write_admin_settings(settings)
            self._send_json(200, {
                "ok": result.get("status") == "Online",
                "status": result.get("status"),
                "message": "; ".join(e.get("message", "") for e in (result.get("errors") or [])) or None,
            })
            return

        if parsed.path == "/api/admin/onelake/test":
            # 2026-08-18, admin-panel completeness pass: the OneLake tab
            # was the one Setup tab with a credential/connection but no
            # safe test action -- see onelake_data.test_connection's own
            # docstring.
            settings = self._require_admin()
            if settings is None:
                return
            try:
                onelake_config = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            if not onelake_config.get("sp_tenant_id"):
                onelake_config["sp_tenant_id"] = settings.get("tenant_id", "")
            self._send_json(200, onelake_data.test_connection(onelake_config))
            return

        if parsed.path == "/api/admin/capacity-metrics/test":
            settings = self._require_admin()
            if settings is None:
                return
            try:
                capacity_metrics_config = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
                return
            if not capacity_metrics_config.get("sp_tenant_id"):
                capacity_metrics_config["sp_tenant_id"] = settings.get("tenant_id", "")
            self._send_json(200, capacity_metrics.test_connection(capacity_metrics_config, session=self._current_session()))
            return

        if parsed.path == "/api/admin/notifications/test":
            settings = self._require_admin()
            if settings is None:
                return
            session = self._current_session()
            try:
                body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                body = {}
            language = "en" if body.get("language") == "en" else "es"
            # 2026-08-18: test the form's current (possibly unsaved) SMTP
            # values, not only what's already saved -- same "test what
            # you're about to save" contract as the Lakehouse/pipeline/
            # OneLake test buttons. Only overrides fields the caller
            # actually sent; anything omitted falls back to the saved
            # config (this endpoint never writes admin_settings.json).
            smtp_override_keys = ("smtp_host", "smtp_port", "smtp_use_tls", "smtp_user", "smtp_password_ref", "from_address")
            smtp_overrides = {key: body[key] for key in smtp_override_keys if key in body}
            test_settings = settings if not smtp_overrides else {**settings, "notifications": {**(settings.get("notifications") or {}), **smtp_overrides}}
            subject, html_body, text_body = _build_notification_email(
                "Test WS", _now_iso(), _now_iso(), "succeeded",
                {"by_type": {"Report": {"added": 1, "removed": 0, "modified": 0}}},
                session["user_email"], "", "", language,
            )
            test_subject = f"[{'Prueba' if language == 'es' else 'Test'}] {subject}"
            ok, error = _send_email(test_settings, session["user_email"], test_subject, html_body, text_body)
            self._send_json(200, {"ok": ok, "message": error or f"Sent to {session['user_email']}"})
            return

        if parsed.path == "/api/admin/notifications/test-teams":
            settings = self._require_admin()
            if settings is None:
                return
            session = self._current_session()
            try:
                body = json.loads(raw_body.decode("utf-8")) if raw_body else {}
            except (json.JSONDecodeError, UnicodeDecodeError):
                body = {}
            language = "en" if body.get("language") == "en" else "es"
            # Same "test the unsaved form" fix as /api/admin/notifications/test above.
            teams_overrides = {"teams_webhook_url": body["teams_webhook_url"]} if "teams_webhook_url" in body else {}
            test_settings = settings if not teams_overrides else {**settings, "notifications": {**(settings.get("notifications") or {}), **teams_overrides}}
            message = _build_teams_message(
                "Test WS", _now_iso(), _now_iso(), "succeeded",
                {"by_type": {"Report": {"added": 1, "removed": 0, "modified": 0}}},
                session["user_email"], "", "", language,
            )
            ok, error = _send_teams_notification(test_settings, message)
            self._send_json(200, {"ok": ok, "message": error or "Sent to the configured Teams channel."})
            return

        if parsed.path == "/api/scan-full":
            resolved = self._resolve_scan_caller()
            if resolved is None:
                return
            session, api_key_name = resolved
            if session:
                settings = _load_admin_settings()
                if not _email_in_allowlist(session["user_email"], settings, "full_scan_emails"):
                    self._send_json(403, {"error": "not_permitted", "message": "This account is not allowed to trigger a full scan."})
                    return
            # A valid API key is created by an admin specifically to let an
            # automation caller trigger scans (Tanda 5, E.0/E.1) -- there is
            # no per-key email to check against full_scan_emails, so
            # possessing a valid key is itself the authorization, same as
            # an admin already implicitly grants by creating one.
            result, error = _start_full_scan(session, api_key_name=api_key_name)
            if error:
                status_code = {
                    "sign_in_required": 401,
                    "az_session_invalid": 409,
                    "scan_already_running": 409,
                    "queue_full": 429,
                    "spawn_failed": 500,
                    "workspace_discovery_failed": 502,
                    "no_accessible_workspaces": 403,
                }.get(error["error"], 500)
                self._send_json(status_code, error)
                return
            self._send_json(202, result)
            return

        if parsed.path == "/api/scan-executions":
            resolved = self._resolve_scan_caller()
            if resolved is None:
                return
            session, api_key_name = resolved
            result, error = _start_executions_scan(session, api_key_name=api_key_name)
            if error:
                status_code = {
                    "sign_in_required": 401,
                    "not_permitted": 403,
                    "az_session_invalid": 409,
                    "scan_already_running": 409,
                    "queue_full": 429,
                    "spawn_failed": 500,
                }.get(error["error"], 500)
                self._send_json(status_code, error)
                return
            self._send_json(202, result)
            return

        if parsed.path == "/api/admin/warehouse-upload":
            resolved = self._resolve_scan_caller()
            if resolved is None:
                return
            session, api_key_name = resolved
            result, error = _start_warehouse_upload(session, api_key_name=api_key_name)
            if error:
                status_code = {
                    "sign_in_required": 401,
                    "not_permitted": 403,
                    "az_session_invalid": 409,
                    "scan_already_running": 409,
                    "queue_full": 429,
                    "spawn_failed": 500,
                }.get(error["error"], 500)
                self._send_json(status_code, error)
                return
            self._send_json(202, result)
            return

        if parsed.path == "/api/admin/onelake-publish":
            resolved = self._resolve_scan_caller()
            if resolved is None:
                return
            session, api_key_name = resolved
            result, error = _start_onelake_publish(session, api_key_name=api_key_name)
            if error:
                status_code = {
                    "sign_in_required": 401,
                    "not_permitted": 403,
                    "az_session_invalid": 409,
                    "scan_already_running": 409,
                    "queue_full": 429,
                    "spawn_failed": 500,
                }.get(error["error"], 500)
                self._send_json(status_code, error)
                return
            self._send_json(202, result)
            return

        if parsed.path == "/api/scan-stop":
            resolved = self._resolve_scan_caller()
            if resolved is None:
                return
            session, api_key_name = resolved
            result, error = _stop_scan(session, api_key_name=api_key_name)
            if error:
                status_code = {
                    "no_scan_running": 409,
                    "sign_in_required": 401,
                    "not_permitted": 403,
                }.get(error["error"], 500)
                self._send_json(status_code, error)
                return
            self._send_json(202, result)
            return

        if parsed.path != "/api/scan":
            self._send_json(404, {"error": "not_found", "message": f"Unknown route: {self.path}"})
            return

        try:
            payload = json.loads(raw_body.decode("utf-8")) if raw_body else {}
        except (json.JSONDecodeError, UnicodeDecodeError):
            self._send_json(400, {"error": "invalid_request", "message": "The request body must be valid JSON."})
            return

        workspace = str(payload.get("workspace", "")).strip()
        if not workspace:
            self._send_json(400, {"error": "invalid_request", "message": "The body must be JSON with a non-empty 'workspace' field."})
            return

        resolved = self._resolve_scan_caller()
        if resolved is None:
            return
        session, api_key_name = resolved
        result, error = _start_scan(workspace, session, api_key_name=api_key_name)
        if error:
            status_code = {
                "sign_in_required": 401,
                "az_session_invalid": 409,
                "scan_already_running": 409,
                "queue_full": 429,
                "workspace_not_found": 404,
                "workspace_index_missing": 503,
                "spawn_failed": 500,
            }.get(error["error"], 500)
            self._send_json(status_code, error)
            return

        self._send_json(202, result)
