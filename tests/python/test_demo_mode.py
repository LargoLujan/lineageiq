"""Demo mode (LINEAGE_DEMO_MODE=1) end to end over real HTTP.

Demo mode exists so the README quick start (backend/scripts/
generate_demo_data.py plus the web server) opens the synthetic "Contoso"
tenant without a Microsoft sign-in. These tests pin its security boundary
against a real ThreadingHTTPServer running LineageWebHandler on an
ephemeral 127.0.0.1 port:

- /api/auth/me reports demo_mode on both its 401 (no session) and its 200
  (signed in), and is still a 401 without a session in demo mode;
- /data/* reads are public only in demo mode;
- every admin, API-key, scan and session-only write route still refuses an
  anonymous caller in demo mode, exactly as without it.

Admin settings are redirected to a temp file and the web root to a temp
folder, so nothing here touches the repository's config/ or data/ folders,
and no route reached here makes a network call.
"""

import http.client
import json
import sys
import threading
from datetime import datetime, timezone
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

import lineage_web_server as server  # noqa: E402
from lineage_web import admin_settings, handler  # noqa: E402

SETTINGS = {
    "tenant_id": "",
    "admin_emails": [],
    "full_scan_emails": [],
    "users": [],
    "allow_anonymous_scans": False,
    "onelake_data": {"mode": "local_files"},
}


@pytest.fixture
def web(tmp_path, monkeypatch):
    settings_path = tmp_path / "admin_settings.json"
    settings_path.write_text(json.dumps(SETTINGS), encoding="utf-8")
    monkeypatch.setattr(admin_settings, "ADMIN_SETTINGS_PATH", settings_path)
    monkeypatch.setattr(admin_settings, "LAKEHOUSE_TARGET_PATH", tmp_path / "lakehouse_target.json")

    web_root = tmp_path / "web"
    (web_root / "data").mkdir(parents=True)
    (web_root / "index.html").write_text("<!doctype html><title>test</title>", encoding="utf-8")
    (web_root / "data" / "lineage-explorer.json").write_text('{"workspaces": []}', encoding="utf-8")
    monkeypatch.setattr(handler.LineageWebHandler, "root", web_root)
    monkeypatch.setattr(handler.LineageWebHandler, "mcp_http_port", None)
    monkeypatch.delenv("LINEAGE_DEMO_MODE", raising=False)

    with server._session_lock:
        server._sessions.clear()
    with server._rate_limit_lock:
        server._rate_limit_windows.clear()

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler.LineageWebHandler)
    # A short poll interval keeps shutdown() (once per test) from adding the
    # default 0.5 s each.
    thread = threading.Thread(target=httpd.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
    thread.start()
    try:
        yield {"port": httpd.server_address[1], "settings_path": settings_path}
    finally:
        httpd.shutdown()
        httpd.server_close()
        with server._session_lock:
            server._sessions.clear()


def _request(port, method, path, body=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        payload = None if body is None else json.dumps(body).encode("utf-8")
        request_headers = dict(headers or {})
        if payload is not None:
            request_headers["Content-Type"] = "application/json"
        connection.request(method, path, body=payload, headers=request_headers)
        response = connection.getresponse()
        raw = response.read()
        try:
            data = json.loads(raw.decode("utf-8")) if raw else None
        except (UnicodeDecodeError, json.JSONDecodeError):
            data = raw
        return response.status, data
    finally:
        connection.close()


def _add_session(session_id, user_email="viewer@example.com"):
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    with server._session_lock:
        server._sessions[session_id] = {
            "user_email": user_email,
            "user_name": "Viewer",
            "object_id": "obj-1",
            "tenant_id": "tenant-1",
            "access_token": "fake-token",
            "msal_cache": None,
            "created_at": now,
            "last_seen_at": now,
        }
    return {"Cookie": f"{server.SESSION_COOKIE_NAME}={session_id}"}


# ---------------------------------------------------------------------------
# The env flag itself
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("value", ["1", "true", "TRUE", "yes", " Yes "])
def test_demo_mode_enabled_for_explicit_opt_in_values(monkeypatch, value):
    monkeypatch.setenv("LINEAGE_DEMO_MODE", value)
    assert handler._demo_mode_enabled() is True


@pytest.mark.parametrize("value", ["", "0", "false", "no", "off", "demo"])
def test_demo_mode_disabled_for_anything_else(monkeypatch, value):
    monkeypatch.setenv("LINEAGE_DEMO_MODE", value)
    assert handler._demo_mode_enabled() is False


def test_demo_mode_disabled_when_unset(monkeypatch):
    monkeypatch.delenv("LINEAGE_DEMO_MODE", raising=False)
    assert handler._demo_mode_enabled() is False


# ---------------------------------------------------------------------------
# /api/auth/me: what the frontend's init() uses to decide on the sign-in gate
# ---------------------------------------------------------------------------

def test_auth_me_without_session_is_401_and_not_demo_by_default(web):
    status, body = _request(web["port"], "GET", "/api/auth/me")
    assert status == 401
    assert body == {"error": "not_signed_in", "demo_mode": False}


def test_auth_me_without_session_is_still_401_in_demo_mode_but_reports_it(web, monkeypatch):
    monkeypatch.setenv("LINEAGE_DEMO_MODE", "1")
    status, body = _request(web["port"], "GET", "/api/auth/me")
    assert status == 401
    assert body == {"error": "not_signed_in", "demo_mode": True}


@pytest.mark.parametrize("demo_env, expected", [(None, False), ("1", True)])
def test_auth_me_with_session_reports_identity_and_demo_flag(web, monkeypatch, demo_env, expected):
    if demo_env is not None:
        monkeypatch.setenv("LINEAGE_DEMO_MODE", demo_env)
    headers = _add_session("sid-demo-test")
    status, body = _request(web["port"], "GET", "/api/auth/me", headers=headers)
    assert status == 200
    assert body["user_email"] == "viewer@example.com"
    assert body["demo_mode"] is expected
    assert body["is_admin"] is False


# ---------------------------------------------------------------------------
# Reads: /data/* is public only in demo mode
# ---------------------------------------------------------------------------

def test_data_files_require_sign_in_without_demo_mode(web):
    status, _body = _request(web["port"], "GET", "/data/lineage-explorer.json")
    assert status == 401


def test_data_files_are_readable_anonymously_in_demo_mode(web, monkeypatch):
    monkeypatch.setenv("LINEAGE_DEMO_MODE", "1")
    status, body = _request(web["port"], "GET", "/data/lineage-explorer.json")
    assert status == 200
    assert body == {"workspaces": []}


# ---------------------------------------------------------------------------
# Writes, admin and session-only routes: demo mode changes nothing
# ---------------------------------------------------------------------------

BLOCKED_IN_DEMO_MODE = [
    ("GET", "/api/admin/settings", None),
    ("POST", "/api/admin/settings", {"tenant_id": "t", "admin_emails": ["attacker@example.com"], "allow_anonymous_scans": True}),
    ("GET", "/api/admin/api-keys", None),
    ("POST", "/api/admin/api-keys", {"name": "demo-key", "scope": "full"}),
    ("POST", "/api/admin/api-keys/revoke", {"name": "demo-key"}),
    ("GET", "/api/admin/sessions", None),
    ("POST", "/api/scan", {"workspace": "Contoso-Sales_Prod"}),
    ("POST", "/api/scan-full", {}),
    ("POST", "/api/scan-executions", {}),
    ("POST", "/api/admin/warehouse-upload", {}),
    ("POST", "/api/admin/onelake-publish", {}),
    ("GET", "/api/workspaces/mine", None),
    ("POST", "/api/node-comments", {"qualified_name": "x", "comment_text": "y"}),
    ("POST", "/api/analytics/event", {"event_type": "select", "qualified_name": "x"}),
]


@pytest.mark.parametrize("method, path, body", BLOCKED_IN_DEMO_MODE)
def test_demo_mode_keeps_admin_scan_and_session_routes_blocked(web, monkeypatch, method, path, body):
    status_without_demo, _ = _request(web["port"], method, path, body=body)
    monkeypatch.setenv("LINEAGE_DEMO_MODE", "1")
    status_in_demo, _ = _request(web["port"], method, path, body=body)
    assert status_in_demo == 401
    assert status_in_demo == status_without_demo


def test_demo_mode_never_writes_admin_settings(web, monkeypatch):
    monkeypatch.setenv("LINEAGE_DEMO_MODE", "1")
    before = web["settings_path"].read_bytes()
    for method, path, body in BLOCKED_IN_DEMO_MODE:
        if method == "POST":
            _request(web["port"], method, path, body=body)
    assert web["settings_path"].read_bytes() == before
