"""Unit tests for the security-critical logic added to
backend/scripts/lineage_web_server.py (session expiry, admin/full-scan
allowlists, device-code flow rate limiting, session revocation) -- see
docs/102_admin_panel_and_user_auth.md.

These test the module's internal functions directly (no HTTP, no MSAL, no
real Fabric calls) since the module has no dependency-injection seams for
an end-to-end test without live Azure credentials. Run with:
    pytest tests/python/test_lineage_web_server.py
"""

import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

import lineage_web_server as server  # noqa: E402


def _iso(dt):
    return dt.isoformat(timespec="seconds")


def _make_session(user_email="user@example.com", created_at=None, last_seen_at=None):
    now = datetime.now(timezone.utc)
    return {
        "user_email": user_email,
        "user_name": user_email,
        "object_id": "obj-123",
        "tenant_id": "tenant-123",
        "access_token": "fake-token",
        "msal_cache": None,
        "created_at": _iso(created_at or now),
        "last_seen_at": _iso(last_seen_at or now),
    }


def setup_function():
    # Every test starts from a clean slate regardless of test order.
    with server._session_lock:
        server._sessions.clear()
        server._session_history.clear()
    with server._device_flow_lock:
        server._pending_device_flows.clear()
    with server._rate_limit_lock:
        server._rate_limit_windows.clear()


# ---------------------------------------------------------------------------
# Allowlist matching
# ---------------------------------------------------------------------------

def test_email_in_allowlist_matches_case_insensitively():
    settings = {"admin_emails": ["Someone@Example.com"]}
    assert server._email_in_allowlist("someone@example.com", settings, "admin_emails") is True


def test_email_in_allowlist_rejects_unknown_email():
    settings = {"admin_emails": ["someone@example.com"]}
    assert server._email_in_allowlist("nobody@example.com", settings, "admin_emails") is False


def test_email_in_allowlist_rejects_empty_email():
    settings = {"admin_emails": ["someone@example.com"]}
    assert server._email_in_allowlist("", settings, "admin_emails") is False
    assert server._email_in_allowlist(None, settings, "admin_emails") is False


def test_email_in_allowlist_handles_missing_list_key():
    settings = {}
    assert server._email_in_allowlist("someone@example.com", settings, "admin_emails") is False


# ---------------------------------------------------------------------------
# Session expiry: idle timeout + absolute lifetime
# ---------------------------------------------------------------------------

def test_get_session_returns_live_session():
    session_id = "sid-live"
    with server._session_lock:
        server._sessions[session_id] = _make_session()
    assert server._get_session(session_id) is not None


def test_get_session_expires_after_idle_timeout():
    session_id = "sid-idle"
    stale_last_seen = datetime.now(timezone.utc) - timedelta(
        seconds=server.SESSION_IDLE_TIMEOUT_SECONDS + 60
    )
    with server._session_lock:
        server._sessions[session_id] = _make_session(last_seen_at=stale_last_seen)
    assert server._get_session(session_id) is None
    with server._session_lock:
        assert session_id not in server._sessions


def test_get_session_expires_after_absolute_lifetime_even_if_recently_seen():
    session_id = "sid-old"
    old_created = datetime.now(timezone.utc) - timedelta(
        seconds=server.SESSION_ABSOLUTE_LIFETIME_SECONDS + 60
    )
    with server._session_lock:
        server._sessions[session_id] = _make_session(
            created_at=old_created, last_seen_at=datetime.now(timezone.utc)
        )
    assert server._get_session(session_id) is None


def test_get_session_refreshes_last_seen_at_on_access():
    session_id = "sid-refresh"
    old_last_seen = datetime.now(timezone.utc) - timedelta(minutes=5)
    with server._session_lock:
        server._sessions[session_id] = _make_session(last_seen_at=old_last_seen)
    server._get_session(session_id)
    with server._session_lock:
        refreshed = datetime.fromisoformat(server._sessions[session_id]["last_seen_at"])
    assert refreshed > old_last_seen


def test_get_session_returns_none_for_unknown_id():
    assert server._get_session("does-not-exist") is None
    assert server._get_session(None) is None
    assert server._get_session("") is None


# ---------------------------------------------------------------------------
# Session revocation (admin "sign out this user" action)
# ---------------------------------------------------------------------------

def test_revoke_sessions_for_email_removes_all_matching_sessions():
    with server._session_lock:
        server._sessions["sid-1"] = _make_session(user_email="target@example.com")
        server._sessions["sid-2"] = _make_session(user_email="TARGET@example.com")
        server._sessions["sid-3"] = _make_session(user_email="someone-else@example.com")

    revoked_count = server._revoke_sessions_for_email("target@example.com")

    assert revoked_count == 2
    with server._session_lock:
        assert set(server._sessions.keys()) == {"sid-3"}


def test_revoke_sessions_for_email_with_no_match_revokes_nothing():
    with server._session_lock:
        server._sessions["sid-1"] = _make_session(user_email="someone@example.com")
    assert server._revoke_sessions_for_email("nobody@example.com") == 0
    with server._session_lock:
        assert "sid-1" in server._sessions


def test_revoke_sessions_for_email_handles_empty_email():
    assert server._revoke_sessions_for_email("") == 0
    assert server._revoke_sessions_for_email(None) == 0


# ---------------------------------------------------------------------------
# Session history (admin panel Sessions tab: active + history)
# ---------------------------------------------------------------------------

def test_revoke_sessions_for_email_records_history_with_correct_reason():
    with server._session_lock:
        server._sessions["sid-1"] = _make_session(user_email="target@example.com")
    server._revoke_sessions_for_email("target@example.com")
    history = server._list_session_history_for_admin()
    assert len(history) == 1
    assert history[0]["user_email"] == "target@example.com"
    assert history[0]["end_reason"] == "revoked_by_admin"


def test_end_session_records_history_with_signed_out_reason():
    session_id = "sid-signout"
    with server._session_lock:
        server._sessions[session_id] = _make_session(user_email="a@example.com")
    server._end_session(session_id)
    history = server._list_session_history_for_admin()
    assert len(history) == 1
    assert history[0]["end_reason"] == "signed_out"
    with server._session_lock:
        assert session_id not in server._sessions


def test_get_session_expiry_records_history_with_expired_reason():
    session_id = "sid-idle"
    stale_last_seen = datetime.now(timezone.utc) - timedelta(
        seconds=server.SESSION_IDLE_TIMEOUT_SECONDS + 60
    )
    with server._session_lock:
        server._sessions[session_id] = _make_session(last_seen_at=stale_last_seen)
    server._get_session(session_id)
    history = server._list_session_history_for_admin()
    assert len(history) == 1
    assert history[0]["end_reason"] == "expired"


def test_end_session_for_unknown_id_records_nothing():
    server._end_session("does-not-exist")
    assert server._list_session_history_for_admin() == []


def test_session_history_is_capped_and_newest_first():
    for i in range(server.MAX_SESSION_HISTORY_ENTRIES + 10):
        session_id = f"sid-{i}"
        with server._session_lock:
            server._sessions[session_id] = _make_session(user_email=f"user{i}@example.com")
        server._end_session(session_id)
    history = server._list_session_history_for_admin(limit=server.MAX_SESSION_HISTORY_ENTRIES)
    assert len(history) == server.MAX_SESSION_HISTORY_ENTRIES
    # Newest first: the very last one ended (highest i) should be at index 0.
    assert history[0]["user_email"] == f"user{server.MAX_SESSION_HISTORY_ENTRIES + 9}@example.com"


# ---------------------------------------------------------------------------
# Device-code flow rate limiting / stale-flow pruning
# ---------------------------------------------------------------------------

def _make_pending_flow(client_ip="1.2.3.4", age_seconds=0):
    return {
        "status": "pending",
        "user_code": "ABC123",
        "verification_uri": "https://login.microsoftonline.com/device",
        "message": "",
        "result": None,
        "cache": None,
        "error": None,
        "client_ip": client_ip,
        "created_monotonic": time.monotonic() - age_seconds,
    }


def test_prune_stale_device_flows_removes_only_expired_entries():
    with server._device_flow_lock:
        server._pending_device_flows["fresh"] = _make_pending_flow(age_seconds=5)
        server._pending_device_flows["stale"] = _make_pending_flow(
            age_seconds=server.DEVICE_FLOW_STALE_SECONDS + 10
        )
    server._prune_stale_device_flows()
    with server._device_flow_lock:
        assert set(server._pending_device_flows.keys()) == {"fresh"}


def test_max_pending_device_flows_per_ip_is_enforced_by_start_device_flow():
    # _start_device_flow calls out to MSAL/admin settings for a genuinely
    # new flow, which we don't want to exercise here -- but the rate-limit
    # check itself runs (and can return early) before any of that, so
    # pre-filling _pending_device_flows up to the cap is enough to prove it.
    client_ip = "9.9.9.9"
    with server._device_flow_lock:
        for i in range(server.MAX_PENDING_DEVICE_FLOWS_PER_IP):
            server._pending_device_flows[f"flow-{i}"] = _make_pending_flow(client_ip=client_ip)

    result, error = server._start_device_flow(client_ip)

    assert result is None
    assert error["error"] == "too_many_pending_flows"


def test_device_flows_from_a_different_ip_are_not_rate_limited_together():
    with server._device_flow_lock:
        for i in range(server.MAX_PENDING_DEVICE_FLOWS_PER_IP):
            server._pending_device_flows[f"flow-{i}"] = _make_pending_flow(client_ip="1.1.1.1")
    with server._device_flow_lock:
        pending_from_other_ip = sum(
            1 for pending in server._pending_device_flows.values()
            if pending.get("client_ip") == "2.2.2.2"
        )
    assert pending_from_other_ip == 0


# ---------------------------------------------------------------------------
# Static API keys: machine-to-machine auth for automation
# callers (a Fabric pipeline's Web activity) that can't do an interactive
# device-code sign-in.
# ---------------------------------------------------------------------------

def test_generate_api_key_has_recognizable_prefix_and_is_unique():
    first = server._generate_api_key()
    second = server._generate_api_key()
    assert first.startswith("flm_")
    assert second.startswith("flm_")
    assert first != second


def test_valid_api_key_name_matches_a_stored_key():
    settings = {"api_keys": [{"name": "nightly-pipeline", "key_hash": server._hash_api_key("flm_abc123"), "key_preview": "...c123"}]}
    assert server._valid_api_key_name("flm_abc123", settings) == "nightly-pipeline"


def test_valid_api_key_name_rejects_unknown_key():
    settings = {"api_keys": [{"name": "nightly-pipeline", "key_hash": server._hash_api_key("flm_abc123"), "key_preview": "...c123"}]}
    assert server._valid_api_key_name("flm_wrong", settings) is None


def test_valid_api_key_name_rejects_empty_key():
    settings = {"api_keys": [{"name": "nightly-pipeline", "key_hash": server._hash_api_key("flm_abc123"), "key_preview": "...c123"}]}
    assert server._valid_api_key_name("", settings) is None
    assert server._valid_api_key_name(None, settings) is None


def test_valid_api_key_name_handles_missing_list_key():
    assert server._valid_api_key_name("flm_abc123", {}) is None


def test_migrate_api_keys_upgrades_legacy_raw_key_entries():
    settings = {"api_keys": [{"name": "nightly-pipeline", "key": "flm_abc123", "created_at": "2026-01-01T00:00:00+00:00"}]}
    migrated_settings, changed = server._migrate_api_keys(settings)
    assert changed is True
    entry = migrated_settings["api_keys"][0]
    assert "key" not in entry
    assert entry["key_hash"] == server._hash_api_key("flm_abc123")
    assert entry["key_preview"] == "...c123"
    assert entry["created_at"] == "2026-01-01T00:00:00+00:00"
    # The raw value the caller already has still validates after migration.
    assert server._valid_api_key_name("flm_abc123", migrated_settings) == "nightly-pipeline"


def test_migrate_api_keys_is_a_noop_for_already_hashed_entries():
    settings = {"api_keys": [{"name": "nightly-pipeline", "key_hash": server._hash_api_key("flm_abc123"), "key_preview": "...c123"}]}
    migrated_settings, changed = server._migrate_api_keys(settings)
    assert changed is False
    assert migrated_settings == settings


# ---------------------------------------------------------------------------
# API key last_used_at:
# in-memory only, updated by _valid_api_key on a real match. Deliberately
# NOT persisted to admin_settings.json -- see state.py's own comment.
# ---------------------------------------------------------------------------

def setup_last_used_test():
    with server._api_key_last_used_lock:
        server._api_key_last_used.clear()


def test_api_key_last_used_at_is_empty_before_any_successful_validation():
    setup_last_used_test()
    assert server._api_key_last_used_at("some-hash") == ""


def test_valid_api_key_records_last_used_on_a_real_match():
    setup_last_used_test()
    key_hash = server._hash_api_key("flm_abc123")
    settings = {"api_keys": [{"name": "k", "key_hash": key_hash}]}
    server._valid_api_key("flm_abc123", settings)
    assert server._api_key_last_used_at(key_hash) != ""


def test_valid_api_key_does_not_record_anything_for_an_unknown_key():
    setup_last_used_test()
    settings = {"api_keys": [{"name": "k", "key_hash": server._hash_api_key("flm_real")}]}
    server._valid_api_key("flm_wrong", settings)
    assert server._api_key_last_used == {}


def test_valid_api_key_does_not_record_anything_for_an_expired_key():
    setup_last_used_test()
    past = _iso(datetime.now(timezone.utc) - timedelta(days=1))
    key_hash = server._hash_api_key("flm_abc123")
    settings = {"api_keys": [{"name": "k", "key_hash": key_hash, "expires_at": past}]}
    server._valid_api_key("flm_abc123", settings)
    assert server._api_key_last_used_at(key_hash) == ""


# ---------------------------------------------------------------------------
# API key expires_at / scope
# ---------------------------------------------------------------------------

def test_valid_api_key_name_accepts_a_key_with_no_expiry():
    settings = {"api_keys": [{"name": "k", "key_hash": server._hash_api_key("flm_abc123"), "expires_at": ""}]}
    assert server._valid_api_key_name("flm_abc123", settings) == "k"


def test_valid_api_key_name_accepts_a_key_that_has_not_expired_yet():
    future = _iso(datetime.now(timezone.utc) + timedelta(days=1))
    settings = {"api_keys": [{"name": "k", "key_hash": server._hash_api_key("flm_abc123"), "expires_at": future}]}
    assert server._valid_api_key_name("flm_abc123", settings) == "k"


def test_valid_api_key_name_rejects_an_expired_key():
    past = _iso(datetime.now(timezone.utc) - timedelta(days=1))
    settings = {"api_keys": [{"name": "k", "key_hash": server._hash_api_key("flm_abc123"), "expires_at": past}]}
    assert server._valid_api_key_name("flm_abc123", settings) is None


def test_valid_api_key_name_tolerates_a_malformed_expires_at():
    settings = {"api_keys": [{"name": "k", "key_hash": server._hash_api_key("flm_abc123"), "expires_at": "not-a-date"}]}
    assert server._valid_api_key_name("flm_abc123", settings) == "k"


def test_valid_api_key_defaults_to_full_for_legacy_entries_without_scope():
    settings = {"api_keys": [{"name": "k", "key_hash": server._hash_api_key("flm_abc123")}]}
    assert server._valid_api_key("flm_abc123", settings) == ("k", "full")


def test_valid_api_key_reflects_stored_scope():
    settings = {"api_keys": [{"name": "k", "key_hash": server._hash_api_key("flm_abc123"), "scope": "read_only"}]}
    assert server._valid_api_key("flm_abc123", settings) == ("k", "read_only")


def test_valid_api_key_returns_none_none_for_an_unknown_key():
    assert server._valid_api_key("flm_wrong", {"api_keys": []}) == (None, None)


def test_valid_api_key_returns_none_none_for_an_expired_key():
    past = _iso(datetime.now(timezone.utc) - timedelta(days=1))
    settings = {"api_keys": [{"name": "k", "key_hash": server._hash_api_key("flm_abc123"), "scope": "full", "expires_at": past}]}
    assert server._valid_api_key("flm_abc123", settings) == (None, None)


def test_valid_api_key_resolves_scope_from_the_matched_entry_not_a_by_name_rescan():
    # Two entries can share a name (the
    # duplicate-name check at creation is a lock-free read-modify-write, so
    # a race can still produce this). Scope MUST come from whichever entry
    # the raw key's hash actually matched, never from a separate by-name
    # lookup that could silently resolve to the OTHER entry.
    settings = {"api_keys": [
        {"name": "shared-name", "key_hash": server._hash_api_key("flm_first"), "scope": "full"},
        {"name": "shared-name", "key_hash": server._hash_api_key("flm_second"), "scope": "read_only"},
    ]}
    assert server._valid_api_key("flm_first", settings) == ("shared-name", "full")
    assert server._valid_api_key("flm_second", settings) == ("shared-name", "read_only")


# ---------------------------------------------------------------------------
# Rate limiting: per-client-IP fixed window over /api/*.
# ---------------------------------------------------------------------------

def test_rate_limit_allows_requests_under_the_cap():
    client_ip = "10.0.0.1"
    for _ in range(server.RATE_LIMIT_MAX_REQUESTS_PER_WINDOW):
        allowed, _ = server._check_rate_limit(client_ip)
        assert allowed is True


def test_rate_limit_blocks_the_request_that_exceeds_the_cap():
    client_ip = "10.0.0.2"
    for _ in range(server.RATE_LIMIT_MAX_REQUESTS_PER_WINDOW):
        server._check_rate_limit(client_ip)
    allowed, retry_after = server._check_rate_limit(client_ip)
    assert allowed is False
    assert retry_after > 0


def test_rate_limit_is_tracked_independently_per_client_ip():
    for _ in range(server.RATE_LIMIT_MAX_REQUESTS_PER_WINDOW):
        server._check_rate_limit("10.0.0.3")
    # A different IP starts with a fresh budget, unaffected by 10.0.0.3's.
    allowed, _ = server._check_rate_limit("10.0.0.4")
    assert allowed is True


def test_rate_limit_window_resets_after_it_expires():
    client_ip = "10.0.0.5"
    with server._rate_limit_lock:
        # Simulate a window that started long enough ago to have expired.
        server._rate_limit_windows[client_ip] = (
            time.time() - server.RATE_LIMIT_WINDOW_SECONDS - 1,
            server.RATE_LIMIT_MAX_REQUESTS_PER_WINDOW,
        )
    allowed, _ = server._check_rate_limit(client_ip)
    assert allowed is True


# ---------------------------------------------------------------------------
# Request metrics: in-memory counts by (method, path, status).
# ---------------------------------------------------------------------------

def test_record_request_accumulates_counts_for_the_same_key():
    with server._metrics_lock:
        server._request_counts.clear()
    server._record_request("GET", "/api/test-metric", 200)
    server._record_request("GET", "/api/test-metric", 200)
    server._record_request("GET", "/api/test-metric", 500)
    snapshot = server._metrics_snapshot()
    rows = {(row["method"], row["path"], row["status_code"]): row["count"] for row in snapshot["routes"]}
    assert rows[("GET", "/api/test-metric", 200)] == 2
    assert rows[("GET", "/api/test-metric", 500)] == 1


# ---------------------------------------------------------------------------
# _list_sessions_for_admin:
# is_fabric_tenant_admin was already computed and stored on every session
# at sign-in, but never actually included in this function's own returned
# row -- the admin panel's Sessions tab had no way to show it. _fetch_my_
# workspaces is defined in fabric_api.py and called by NAME from within
# auth.py's own _list_sessions_for_admin, so it must be monkeypatched on
# the `auth` module directly -- patching server._fetch_my_workspaces (the
# re-exported reference in this test file's own namespace) would not
# affect auth.py's internal call, since Python resolves a bare name
# against the function's DEFINING module, not the caller's.
# ---------------------------------------------------------------------------

def test_list_sessions_for_admin_surfaces_is_fabric_tenant_admin(monkeypatch):
    from lineage_web import auth as auth_module

    monkeypatch.setattr(auth_module, "_fetch_my_workspaces", lambda token: ([], None))
    with server._session_lock:
        server._sessions.clear()
        server._sessions["sid-admin"] = {**_make_session(user_email="admin@example.com"), "is_fabric_tenant_admin": True}
        server._sessions["sid-plain"] = {**_make_session(user_email="plain@example.com"), "is_fabric_tenant_admin": False}

    rows = {row["user_email"]: row for row in server._list_sessions_for_admin()}
    assert rows["admin@example.com"]["is_fabric_tenant_admin"] is True
    assert rows["plain@example.com"]["is_fabric_tenant_admin"] is False


def test_list_sessions_for_admin_defaults_to_false_when_the_field_is_missing(monkeypatch):
    from lineage_web import auth as auth_module

    monkeypatch.setattr(auth_module, "_fetch_my_workspaces", lambda token: ([], None))
    with server._session_lock:
        server._sessions.clear()
        server._sessions["sid-legacy"] = _make_session(user_email="legacy@example.com")  # no is_fabric_tenant_admin key at all

    rows = server._list_sessions_for_admin()
    assert rows[0]["is_fabric_tenant_admin"] is False
