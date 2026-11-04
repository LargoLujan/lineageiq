#!/usr/bin/env python3
"""Server for the shared lineage viewer (frontend/semantic-lineage/), used by
backend/scripts/start_lineage_web.sh both locally and behind the cloudflared tunnel
colleagues use.

Serves static files with on-the-fly gzip compression for compressible types
(on a large tenant the lineage JSON payloads can reach tens of megabytes
or more uncompressed, ~4% of that gzipped; compressed bytes are cached in
memory per (path, mtime) so a large file is only compressed once per data
refresh, not on every request).

Also exposes, under /api/* on the SAME host/port as the static site (so it
works through the same cloudflared tunnel that already exposes the viewer --
a separate server bound only to 127.0.0.1 would be unreachable by anyone
opening the tunnel URL):

- Catalog/data reads: GET /api/workspaces, /api/items, /api/item-lineage,
  /api/objects, /api/notebook-code, and any static file under /data/ (the
  frontend's large JSON payloads). Require a signed-in session or a
  valid API key -- but no further check beyond that: this
  data is read-only, so an authenticated tenant account sees it even
  without Fabric Warehouse/workspace permissions of their own.
- The manual scan trigger: GET /api/status, GET /api/history, POST
  /api/scan (one workspace), POST /api/scan-full (the whole tenant), POST
  /api/scan-stop. Require a signed-in session by default: a real,
  read-only Fabric scan runs with that user's own
  delegated token (see FABRIC_LINEAGE_USER_TOKEN in the scan scripts), and
  only the person who started a scan (or an admin) can stop it. An admin
  can flip allow_anonymous_scans back on in config/admin_settings.json to
  restore the pre-auth behavior (anyone reaching this server triggers a
  scan under the machine's shared `az` CLI session) -- off by default so
  the full_scan_emails/admin allowlists can't be bypassed by simply not
  sending a cookie. Only one scan runs at a time; a second request gets 409
  scan_already_running instead of queuing. GET /api/status folds in
  analysis/single_workspace_scan/progress.json (written by the running scan
  script after every step) while a scan is running, so a client polling
  every few seconds -- what the frontend does, never one long-held request
  -- gets a live step count/name without this server blocking or timing out
  across what can be several hours for a full-tenant run. The log tail in
  that response is only included for signed-in callers.
- Entra ID device-code sign-in: POST /api/auth/device-start (kicks off
  MSAL's device flow, returns a user_code + verification_uri immediately),
  GET /api/auth/device-status?flow_id=... (the frontend polls this --
  exactly the same idiom as scan-progress polling above -- until sign-in
  completes, then this call sets the session cookie), GET /api/auth/me,
  POST /api/auth/logout. See config/admin_settings.json for the tenant/
  client ID this authenticates against (defaults to the Azure CLI's own
  public client ID so real sign-in works before a dedicated Entra App
  Registration exists -- see docs/102_admin_panel_and_user_auth.md).
- Admin-only settings: GET/POST /api/admin/settings, gated by session +
  admin_emails allowlist in config/admin_settings.json -- controls the
  tenant, Lakehouse connection, external (non-Fabric) source registry, and
  who is allowed to see the admin panel / trigger a full scan.
- Per-user workspace discovery: GET /api/workspaces/mine, which calls the
  Fabric REST workspace-list API using the SIGNED-IN user's own delegated
  token (never a shared session), so a colleague only ever sees/scans
  workspaces they actually have access to in Fabric.

Sessions live in memory only (never written to disk, since they hold real
tokens) and are lost on a server restart -- signing in again is the only
consequence. Stdlib only, no new runtime dependency beyond `msal` (already
installed on this machine as a transitive dependency of azure-cli-core).

Split into the backend/scripts/lineage_web/ package below;
this file is now a slim entrypoint that also re-exports every internal name
the existing test suite (tests/python/test_lineage_web_server.py) and any
other direct caller accessed on the old, single-file module -- pure code
motion, no logic changed.
"""

import argparse
import os
import subprocess
import sys
from http.server import ThreadingHTTPServer
from pathlib import Path

from lineage_web.admin_settings import (
    _default_admin_settings,
    _email_in_allowlist,
    _load_admin_settings,
    _merge_admin_settings,
    _migrate_api_keys,
    _mirror_lakehouse_target_config,
    _write_admin_settings,
)
from lineage_web.auth import (
    _acquire_scoped_token,
    _api_key_last_used_at,
    _build_msal_app,
    _create_session_from_token_result,
    _end_session,
    _generate_api_key,
    _get_session,
    _list_session_history_for_admin,
    _list_sessions_for_admin,
    _poll_device_flow,
    _prune_stale_device_flows,
    _revoke_sessions_for_email,
    _run_device_flow_background,
    _start_device_flow,
    _valid_api_key,
    _valid_api_key_name,
)
from lineage_web.catalog import (
    _find_items,
    _get_item_lineage,
    _get_object_impact,
    _norm,
    _read_csv_rows,
    _read_json_file,
    _search_items,
)
from lineage_web.compression import get_compressed_bytes
from lineage_web.constants import (
    AZURE_CLI_FALLBACK_CLIENT_ID,
    COMPRESSIBLE_SUFFIXES,
    DEFAULT_ADMIN_SETTINGS,
    DEVICE_FLOW_STALE_SECONDS,
    DIFF_TRACKED_FIELDS,
    FABRIC_API_BASE_URL,
    FABRIC_TOKEN_SCOPES,
    FULL_SCAN_LABEL,
    GUID_PATTERN,
    HISTORY_FIELDS,
    MAX_PENDING_DEVICE_FLOWS_PER_IP,
    MAX_SESSION_HISTORY_ENTRIES,
    MIN_COMPRESS_BYTES,
    NOTIFICATION_TEXT,
    RATE_LIMIT_MAX_REQUESTS_PER_WINDOW,
    RATE_LIMIT_WINDOW_SECONDS,
    SESSION_ABSOLUTE_LIFETIME_SECONDS,
    SESSION_COOKIE_NAME,
    SESSION_IDLE_TIMEOUT_SECONDS,
)
from lineage_web.external_sources import _test_external_source, _test_lakehouse_connection
from lineage_web.fabric_api import _fetch_lakehouses_in_workspace, _fetch_my_workspaces
from lineage_web.handler import LineageWebHandler
from lineage_web.observability import _metrics_snapshot, _record_request
from lineage_web.openapi_spec import _build_openapi_spec
from lineage_web.paths import (
    ADMIN_SETTINGS_PATH,
    DEPENDENCIES_INDEX_PATH,
    DIFF_DIR,
    EXECUTION_DURATION_BY_ITEM_PATH,
    FULL_SCAN_SCRIPT_PATH,
    GRAPH_MAP_INDEX_OBJECTS_PATH,
    HISTORY_PATH,
    ITEM_HISTORY_FIELDS,
    ITEM_HISTORY_PATH,
    ITEMS_INDEX_PATH,
    LAKEHOUSE_TARGET_PATH,
    LOG_DIR,
    OBJECT_IMPACT_PATH,
    PROGRESS_PATH,
    REPO_ROOT,
    SCAN_SCRIPT_PATH,
    STATE_DIR,
    STATE_PATH,
    TEST_EXTERNAL_SOURCE_SCRIPT_PATH,
    WORKSPACE_INDEX_PATH,
    WORKSPACE_ROLE_ASSIGNMENTS_PATH,
)
from lineage_web.purview_insights import (
    _get_access_audit,
    _get_capacity_insight,
    _get_changes_digest,
    _get_sensitivity_overview,
)
from lineage_web.scan_manager import (
    _append_history_row,
    _append_item_history_rows,
    _build_notification_email,
    _build_scan_subprocess_env,
    _check_az_session,
    _diff_by_type_table_html,
    _diff_items,
    _load_scan_queue_from_disk,
    _load_scan_state_from_disk,
    _migrate_history_schema_if_needed,
    _persist_diff,
    _queue_snapshot,
    _read_history,
    _read_progress,
    _read_workspaces,
    _recover_scan_state_on_startup,
    _send_email,
    _send_scan_notification_emails,
    _snapshot_items_for_scope,
    _start_executions_scan,
    _start_full_scan,
    _start_scan,
    _start_warehouse_upload,
    _step_detail_from_progress,
    _stop_scan,
    _wait_for_executions_scan_process,
    _wait_for_full_scan_process,
    _wait_for_process,
    _wait_for_warehouse_upload_process,
    _watch_pid_until_exit,
    _write_scan_queue,
    _write_scan_state,
)
from lineage_web.rate_limit import _check_rate_limit
from lineage_web.routes import ROUTES
from lineage_web.state import (
    _api_key_last_used,
    _api_key_last_used_lock,
    _cache_lock,
    _compressed_cache,
    _device_flow_lock,
    _metrics_lock,
    _metrics_started_at,
    _pending_device_flows,
    _rate_limit_lock,
    _rate_limit_windows,
    _request_counts,
    _scan_lock,
    _scan_queue,
    _scan_state,
    _session_history,
    _session_lock,
    _sessions,
)
from lineage_web.utils import (
    _duration_seconds_between,
    _hash_api_key,
    _is_pid_alive,
    _kill_process_tree,
    _now_iso,
    _relative_to_repo,
    _resolve_az_command,
    _resolve_pwsh_command,
    _slugify,
    _tail_log,
)

__all__ = [
    "ADMIN_SETTINGS_PATH",
    "AZURE_CLI_FALLBACK_CLIENT_ID",
    "COMPRESSIBLE_SUFFIXES",
    "DEFAULT_ADMIN_SETTINGS",
    "DEPENDENCIES_INDEX_PATH",
    "DEVICE_FLOW_STALE_SECONDS",
    "DIFF_DIR",
    "DIFF_TRACKED_FIELDS",
    "EXECUTION_DURATION_BY_ITEM_PATH",
    "FABRIC_API_BASE_URL",
    "FABRIC_TOKEN_SCOPES",
    "FULL_SCAN_LABEL",
    "FULL_SCAN_SCRIPT_PATH",
    "GRAPH_MAP_INDEX_OBJECTS_PATH",
    "GUID_PATTERN",
    "HISTORY_FIELDS",
    "HISTORY_PATH",
    "ITEM_HISTORY_FIELDS",
    "ITEM_HISTORY_PATH",
    "ITEMS_INDEX_PATH",
    "LAKEHOUSE_TARGET_PATH",
    "LOG_DIR",
    "LineageWebHandler",
    "MAX_PENDING_DEVICE_FLOWS_PER_IP",
    "MAX_SESSION_HISTORY_ENTRIES",
    "MIN_COMPRESS_BYTES",
    "NOTIFICATION_TEXT",
    "OBJECT_IMPACT_PATH",
    "PROGRESS_PATH",
    "RATE_LIMIT_MAX_REQUESTS_PER_WINDOW",
    "RATE_LIMIT_WINDOW_SECONDS",
    "REPO_ROOT",
    "ROUTES",
    "SCAN_SCRIPT_PATH",
    "SESSION_ABSOLUTE_LIFETIME_SECONDS",
    "SESSION_COOKIE_NAME",
    "SESSION_IDLE_TIMEOUT_SECONDS",
    "STATE_DIR",
    "STATE_PATH",
    "TEST_EXTERNAL_SOURCE_SCRIPT_PATH",
    "WORKSPACE_INDEX_PATH",
    "WORKSPACE_ROLE_ASSIGNMENTS_PATH",
    "_acquire_scoped_token",
    "_api_key_last_used",
    "_api_key_last_used_at",
    "_api_key_last_used_lock",
    "_append_history_row",
    "_append_item_history_rows",
    "_build_msal_app",
    "_build_notification_email",
    "_build_openapi_spec",
    "_build_scan_subprocess_env",
    "_cache_lock",
    "_check_az_session",
    "_check_rate_limit",
    "_compressed_cache",
    "_create_session_from_token_result",
    "_default_admin_settings",
    "_device_flow_lock",
    "_diff_by_type_table_html",
    "_diff_items",
    "_duration_seconds_between",
    "_email_in_allowlist",
    "_end_session",
    "_fetch_lakehouses_in_workspace",
    "_fetch_my_workspaces",
    "_find_items",
    "_generate_api_key",
    "_get_access_audit",
    "_get_capacity_insight",
    "_get_changes_digest",
    "_get_item_lineage",
    "_get_object_impact",
    "_get_sensitivity_overview",
    "_get_session",
    "_hash_api_key",
    "_is_pid_alive",
    "_kill_process_tree",
    "_list_session_history_for_admin",
    "_list_sessions_for_admin",
    "_load_admin_settings",
    "_load_scan_queue_from_disk",
    "_load_scan_state_from_disk",
    "_merge_admin_settings",
    "_migrate_api_keys",
    "_metrics_lock",
    "_metrics_snapshot",
    "_metrics_started_at",
    "_migrate_history_schema_if_needed",
    "_mirror_lakehouse_target_config",
    "_norm",
    "_now_iso",
    "_pending_device_flows",
    "_persist_diff",
    "_poll_device_flow",
    "_prune_stale_device_flows",
    "_queue_snapshot",
    "_rate_limit_lock",
    "_rate_limit_windows",
    "_read_csv_rows",
    "_read_history",
    "_read_json_file",
    "_read_progress",
    "_read_workspaces",
    "_recover_scan_state_on_startup",
    "_record_request",
    "_relative_to_repo",
    "_request_counts",
    "_resolve_az_command",
    "_resolve_pwsh_command",
    "_revoke_sessions_for_email",
    "_run_device_flow_background",
    "_scan_lock",
    "_scan_queue",
    "_scan_state",
    "_search_items",
    "_send_email",
    "_send_scan_notification_emails",
    "_session_history",
    "_session_lock",
    "_sessions",
    "_slugify",
    "_snapshot_items_for_scope",
    "_start_device_flow",
    "_start_executions_scan",
    "_start_full_scan",
    "_start_scan",
    "_start_warehouse_upload",
    "_step_detail_from_progress",
    "_stop_scan",
    "_tail_log",
    "_test_external_source",
    "_test_lakehouse_connection",
    "_valid_api_key",
    "_valid_api_key_name",
    "_wait_for_executions_scan_process",
    "_wait_for_full_scan_process",
    "_wait_for_process",
    "_wait_for_warehouse_upload_process",
    "_watch_pid_until_exit",
    "_write_admin_settings",
    "_write_scan_queue",
    "_write_scan_state",
    "get_compressed_bytes",
    "main",
    "MCP_HTTP_SERVER_SCRIPT",
    "_spawn_mcp_http_server",
]


MCP_HTTP_SERVER_SCRIPT = Path(__file__).resolve().parent / "mcp_http_server.py"


def _spawn_mcp_http_server(api_base_url, mcp_port):
    """Launches backend/scripts/mcp_http_server.py as a sibling subprocess,
    bound to 127.0.0.1 only -- handler.py's own /mcp proxy is the only
    thing that ever talks to it (see _proxy_to_mcp_http_server there), so
    the whole MCP-over-HTTP surface ends up reachable at exactly one
    already-public URL (https://<this server's own host>/mcp) with no
    second port to open on a tunnel/firewall/Render service.

    Returns the Popen handle, or None if the child couldn't be started at
    all (mcp[cli] not installed -- it's requirements-mcp.txt, a separate
    install step from this server's own requirements-web.txt -- or the
    port is already taken). Never raises: a missing/failed MCP subprocess
    degrades to "that one feature is unavailable" (the /mcp proxy returns
    a clear 503, see handler.py), not a crash of the whole web server."""
    env = {**os.environ, "FABRIC_LINEAGE_API_BASE_URL": api_base_url}
    try:
        process = subprocess.Popen(
            [sys.executable, str(MCP_HTTP_SERVER_SCRIPT), "--host", "127.0.0.1", "--port", str(mcp_port)],
            env=env,
        )
    except OSError as exc:
        print(f"Warning: could not start mcp_http_server.py ({exc}) -- /mcp will return 503. Run `pip install -r requirements-mcp.txt` to enable it.", file=sys.stderr)
        return None
    return process


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    # Render (and most PaaS hosts) assign the listen port via $PORT and
    # expect the process to bind to it -- fall back to the previous fixed
    # default for local/tunnel use where nothing sets that env var.
    parser.add_argument("--port", type=int, default=int(os.environ.get("PORT", 8765)))
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--directory", default=".")
    # The remote MCP surface (see mcp_http_server.py's own
    # docstring for why local/stdio-only was never enough for a hosted AI
    # product's Connectors feature to reach). --mcp-port defaults to one
    # above --port so two local instances (e.g. this server plus a test
    # instance on a different --port) don't collide on the child's port
    # either. --no-mcp-http is the escape hatch for exactly that kind of
    # multi-instance local testing, or a deploy that deliberately doesn't
    # want this surface exposed at all.
    parser.add_argument("--mcp-port", type=int, default=None)
    parser.add_argument("--no-mcp-http", action="store_true")
    args = parser.parse_args()

    LineageWebHandler.root = Path(args.directory).resolve()
    if not LineageWebHandler.root.is_dir():
        print(f"Directory not found: {LineageWebHandler.root}", file=sys.stderr)
        sys.exit(1)

    STATE_DIR.mkdir(parents=True, exist_ok=True)
    _load_scan_state_from_disk()
    _load_scan_queue_from_disk()
    _recover_scan_state_on_startup()

    mcp_process = None
    if args.no_mcp_http:
        LineageWebHandler.mcp_http_port = None
        LineageWebHandler.mcp_http_disabled = True
    else:
        mcp_port = args.mcp_port or (args.port + 1)
        mcp_process = _spawn_mcp_http_server(f"http://127.0.0.1:{args.port}", mcp_port)
        LineageWebHandler.mcp_http_port = mcp_port if mcp_process else None

    httpd = ThreadingHTTPServer((args.bind, args.port), LineageWebHandler)
    print(f"Serving {LineageWebHandler.root} on http://{args.bind}:{args.port} (gzip on the fly for compressible files)")
    print("Scan trigger is live under /api/* on this same port -- signing in is required to start or stop a scan unless allow_anonymous_scans is on in config/admin_settings.json.")
    if LineageWebHandler.mcp_http_port:
        print(f"MCP (remote, Streamable HTTP) is live under /mcp on this same port, proxied to an internal subprocess on 127.0.0.1:{LineageWebHandler.mcp_http_port}.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        if mcp_process:
            mcp_process.terminate()
            try:
                mcp_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                mcp_process.kill()


if __name__ == "__main__":
    main()
