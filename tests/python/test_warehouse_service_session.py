"""Unit tests for the persisted-service-session fallback added to
lineage_web/warehouse.py (2026-07-24) -- live Warehouse reads no longer
strictly require a service principal; the persisted delegated "service
session" (see service_session.py) is tried as a middle tier between the
SP path and failing outright.

Every MSAL/pyodbc/network touchpoint is monkeypatched -- no real
connection is ever attempted.

Run with: pytest tests/python/test_warehouse_service_session.py
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import warehouse  # noqa: E402

LAKEHOUSE_NO_SP = {
    "auth_mode": "user_session",
    "sql_endpoint_connection_string": "server.datawarehouse.fabric.microsoft.com",
    "lakehouse_name": "WH_Test",
}
LAKEHOUSE_WITH_SP = {
    "auth_mode": "service_principal",
    "sql_endpoint_connection_string": "server.datawarehouse.fabric.microsoft.com",
    "lakehouse_name": "WH_Test",
    "sp_tenant_id": "tenant-x", "sp_client_id": "client-x", "sp_client_secret_ref": "TEST_WH_SECRET_REF",
}


def setup_function():
    warehouse._token_cache["access_token"] = ""
    warehouse._token_cache["expires_at"] = 0.0


# ---------------------------------------------------------------------------
# _destination_fields_present / _sp_fields_present
# ---------------------------------------------------------------------------

def test_destination_fields_present_ignores_auth_mode():
    assert warehouse._destination_fields_present(LAKEHOUSE_NO_SP) is True
    assert warehouse._destination_fields_present({}) is False


def test_sp_fields_present_requires_service_principal_mode():
    assert warehouse._sp_fields_present(LAKEHOUSE_NO_SP) is False
    assert warehouse._sp_fields_present(LAKEHOUSE_WITH_SP) is True


# ---------------------------------------------------------------------------
# _get_cached_token
# ---------------------------------------------------------------------------

def test_get_cached_token_uses_sp_when_configured(monkeypatch):
    monkeypatch.setattr(warehouse, "_acquire_sp_database_token", lambda settings, lakehouse: "sp-token")
    delegated_calls = []
    monkeypatch.setattr("lineage_web.service_session.acquire_service_token", lambda settings, scopes: delegated_calls.append(1))

    token = warehouse._get_cached_token({}, LAKEHOUSE_WITH_SP)
    assert token == "sp-token"
    assert delegated_calls == []  # service-session path never touched -- SP took priority


def test_get_cached_token_falls_back_to_service_session_when_no_sp(monkeypatch):
    calls = []

    def fake_acquire(settings, scopes):
        calls.append(scopes)
        return "delegated-token"

    monkeypatch.setattr("lineage_web.service_session.acquire_service_token", fake_acquire)
    token = warehouse._get_cached_token({}, LAKEHOUSE_NO_SP)
    assert token == "delegated-token"
    assert calls == [["https://database.windows.net/.default"]]


def test_get_cached_token_raises_not_configured_when_nothing_works(monkeypatch):
    monkeypatch.setattr("lineage_web.service_session.acquire_service_token", lambda settings, scopes: "")
    try:
        warehouse._get_cached_token({}, LAKEHOUSE_NO_SP)
        assert False, "should have raised"
    except warehouse.WarehouseNotConfiguredError:
        pass


def test_get_cached_token_caches_sp_token_across_calls(monkeypatch):
    calls = []
    monkeypatch.setattr(warehouse, "_acquire_sp_database_token", lambda settings, lakehouse: calls.append(1) or "sp-token")

    token1 = warehouse._get_cached_token({}, LAKEHOUSE_WITH_SP)
    token2 = warehouse._get_cached_token({}, LAKEHOUSE_WITH_SP)
    assert token1 == token2 == "sp-token"
    assert len(calls) == 1  # second call served from _token_cache


# ---------------------------------------------------------------------------
# query_bronze_table's own gating (destination-only, not SP-only anymore)
# ---------------------------------------------------------------------------

def test_query_bronze_table_raises_not_configured_when_destination_missing(monkeypatch):
    monkeypatch.setattr(warehouse, "_lakehouse_settings", lambda: ({}, {}))
    try:
        warehouse.query_bronze_table("bronze_workspaces", use_cache=False)
        assert False, "should have raised"
    except warehouse.WarehouseNotConfiguredError:
        pass


def test_query_bronze_table_attempts_connect_when_only_destination_present(monkeypatch):
    # No SP, no service session either -- should get PAST the early gate
    # (destination is present) and fail inside _connect/_get_cached_token
    # instead, proving the gate itself no longer requires SP fields.
    monkeypatch.setattr(warehouse, "_lakehouse_settings", lambda: ({}, LAKEHOUSE_NO_SP))
    monkeypatch.setattr("lineage_web.service_session.acquire_service_token", lambda settings, scopes: "")
    try:
        warehouse.query_bronze_table("bronze_workspaces", use_cache=False)
        assert False, "should have raised"
    except warehouse.WarehouseNotConfiguredError as exc:
        # Raised from deep inside _get_cached_token (via _connect), not the
        # early destination-only gate -- confirms the gate was passed.
        assert "delegated service session" in str(exc)
