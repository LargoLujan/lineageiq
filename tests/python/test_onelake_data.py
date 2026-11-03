"""Unit tests for lineage_web/onelake_data.py (2026-07-24): the optional
live-from-OneLake serving path for the big generated JSON payloads.

Every network/SDK call is monkeypatched -- these tests must never touch a
real Azure account or the real analysis/onelake_cache/ directory, same
isolation discipline as test_fabric_pipeline_scan.py (see that file's own
docstring for why this matters: a prior throwaway smoke-test script that
skipped this once triggered a real production side effect).

Run with: pytest tests/python/test_onelake_data.py
"""
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import onelake_data  # noqa: E402

INERT_SETTINGS = {
    "tenant_id": "tenant-x",
    "onelake_data": {
        "mode": "onelake",
        "workspace_name": "WS1",
        "lakehouse_name": "LH_WebData",
        "sp_tenant_id": "tenant-x",
        "sp_client_id": "client-x",
        "sp_client_secret_ref": "TEST_ONELAKE_SECRET_REF",
    },
}


def setup_function():
    with onelake_data._cache_lock:
        onelake_data._last_fetch_at.clear()


def test_is_onelake_data_enabled_false_by_default(monkeypatch):
    monkeypatch.setattr(onelake_data, "_load_admin_settings", lambda: {"onelake_data": {}})
    assert onelake_data.is_onelake_data_enabled() is False


def test_is_onelake_data_enabled_true_when_configured(monkeypatch):
    monkeypatch.setattr(onelake_data, "_load_admin_settings", lambda: INERT_SETTINGS)
    assert onelake_data.is_onelake_data_enabled() is True


def test_fetch_cached_path_rejects_unknown_filename(monkeypatch, tmp_path):
    monkeypatch.setattr(onelake_data, "ONELAKE_CACHE_DIR", tmp_path)
    assert onelake_data.fetch_cached_path("not-a-real-file.json") is None


def test_fetch_cached_path_downloads_and_writes_cache_plus_gz(monkeypatch, tmp_path):
    monkeypatch.setattr(onelake_data, "ONELAKE_CACHE_DIR", tmp_path)
    monkeypatch.setattr(onelake_data, "_load_admin_settings", lambda: INERT_SETTINGS)
    calls = []

    def fake_download(filename):
        calls.append(filename)
        return b'{"hello": "world"}' * 200  # comfortably over the 1024-byte gzip threshold

    monkeypatch.setattr(onelake_data, "_download", fake_download)

    result = onelake_data.fetch_cached_path("object-impact.json")
    assert result == tmp_path / "object-impact.json"
    assert result.is_file()
    assert result.with_name(result.name + ".gz").is_file()
    assert calls == ["object-impact.json"]

    # Second call within the TTL window must NOT re-download.
    onelake_data.fetch_cached_path("object-impact.json")
    assert calls == ["object-impact.json"]


def test_fetch_cached_path_returns_none_on_failure_with_no_prior_cache(monkeypatch, tmp_path):
    monkeypatch.setattr(onelake_data, "ONELAKE_CACHE_DIR", tmp_path)
    monkeypatch.setattr(onelake_data, "_load_admin_settings", lambda: INERT_SETTINGS)
    monkeypatch.setattr(onelake_data, "_download", lambda filename: (_ for _ in ()).throw(onelake_data.OneLakeDataError("boom")))

    assert onelake_data.fetch_cached_path("lineage-explorer.json") is None


def test_fetch_cached_path_serves_stale_cache_on_refresh_failure(monkeypatch, tmp_path):
    monkeypatch.setattr(onelake_data, "ONELAKE_CACHE_DIR", tmp_path)
    monkeypatch.setattr(onelake_data, "_load_admin_settings", lambda: INERT_SETTINGS)
    monkeypatch.setattr(onelake_data, "_download", lambda filename: b"first successful fetch" * 100)

    first = onelake_data.fetch_cached_path("graph-map-index.json")
    assert first is not None

    # Force the TTL to have expired so the next call attempts a real refresh.
    with onelake_data._cache_lock:
        onelake_data._last_fetch_at["graph-map-index.json"] = time.time() - onelake_data._CACHE_TTL_SECONDS - 1

    def fail(filename):
        raise onelake_data.OneLakeDataError("network down")

    monkeypatch.setattr(onelake_data, "_download", fail)
    second = onelake_data.fetch_cached_path("graph-map-index.json")
    assert second == first  # stale cache still served, not None


def test_merge_tags_overlays_matching_nodes(monkeypatch):
    import json

    monkeypatch.setattr(onelake_data, "_load_admin_settings", lambda: {
        "tags": [
            {"qualified_name": "WS/Report/A", "tag": "Finance"},
            {"qualified_name": "WS/Report/A", "tag": "Deprecated"},
            {"qualified_name": "WS/Report/B", "tag": ""},  # blank, skipped
        ],
    })
    payload = {"nodes": [
        {"data": {"id": "WS/Report/A"}},
        {"data": {"id": "WS/Report/B"}},
    ]}
    data = json.dumps(payload).encode("utf-8")
    merged = onelake_data._merge_tags(data, "graph-map-index.json")
    result = json.loads(merged)
    tagged = {node["data"]["id"]: node["data"].get("tags") for node in result["nodes"]}
    assert tagged["WS/Report/A"] == ["Finance", "Deprecated"]
    assert tagged["WS/Report/B"] is None


def test_merge_tags_is_a_noop_for_non_certifiable_filenames(monkeypatch):
    monkeypatch.setattr(onelake_data, "_load_admin_settings", lambda: {
        "tags": [{"qualified_name": "WS/Report/A", "tag": "Finance"}],
    })
    data = b'{"nodes": [{"data": {"id": "WS/Report/A"}}]}'
    assert onelake_data._merge_tags(data, "lineage-explorer.json") == data


def test_fields_present_only_requires_destination(monkeypatch):
    # Service principal is optional (see _credential's az-cli fallback,
    # for tenants where nobody has permission to create a new Entra app
    # registration) --
    # only the workspace/Lakehouse destination is strictly required.
    assert onelake_data._fields_present({}) is False
    assert onelake_data._fields_present({"workspace_name": "WS1"}) is False
    assert onelake_data._fields_present({"workspace_name": "WS1", "lakehouse_name": "LH1"}) is True


def test_sp_fields_present_requires_both():
    assert onelake_data._sp_fields_present({}) is False
    assert onelake_data._sp_fields_present({"sp_client_id": "c"}) is False
    assert onelake_data._sp_fields_present({"sp_client_id": "c", "sp_client_secret_ref": "REF"}) is True


def test_download_raises_not_configured_when_destination_missing(monkeypatch):
    monkeypatch.setattr(onelake_data, "_load_admin_settings", lambda: {"onelake_data": {"mode": "onelake"}})
    try:
        onelake_data._download("lineage-explorer.json")
        assert False, "should have raised"
    except onelake_data.OneLakeDataNotConfiguredError:
        pass


def test_credential_falls_back_to_azure_cli_when_no_sp_or_service_session(monkeypatch):
    # The exact scenario hit live: workspace/lakehouse filled in, no SP,
    # and (explicitly forced here, not just ambient) no persisted service
    # session either -- see test_credential_uses_service_session_when_no_sp
    # for the case added 2026-07-24 that this must NOT hit instead.
    config = {"workspace_name": "WS1", "lakehouse_name": "LH1"}
    monkeypatch.setattr("lineage_web.service_session.has_service_session", lambda: False)
    sentinel = object()
    monkeypatch.setattr("azure.identity.AzureCliCredential", lambda: sentinel)
    assert onelake_data._credential({"tenant_id": "tenant-x"}, config) is sentinel


def test_credential_uses_client_secret_when_sp_configured(monkeypatch):
    config = {
        "workspace_name": "WS1", "lakehouse_name": "LH1",
        "sp_tenant_id": "tenant-x", "sp_client_id": "client-x", "sp_client_secret_ref": "TEST_ONELAKE_SECRET_REF",
    }
    monkeypatch.setenv("TEST_ONELAKE_SECRET_REF", "shh")
    calls = []
    monkeypatch.setattr("azure.identity.ClientSecretCredential", lambda tenant, client, secret: calls.append((tenant, client, secret)) or "csc")
    result = onelake_data._credential({"tenant_id": "tenant-x"}, config)
    assert result == "csc"
    assert calls == [("tenant-x", "client-x", "shh")]


def test_credential_uses_service_session_when_no_sp_but_one_is_designated(monkeypatch):
    # Added 2026-07-24: the persisted delegated service session (see
    # service_session.py) is tried BEFORE the az-cli fallback, since it
    # also works on a host with no `az` at all (e.g. Render).
    config = {"workspace_name": "WS1", "lakehouse_name": "LH1"}
    monkeypatch.setattr("lineage_web.service_session.has_service_session", lambda: True)
    az_calls = []
    monkeypatch.setattr("azure.identity.AzureCliCredential", lambda: az_calls.append(1))
    result = onelake_data._credential({"tenant_id": "tenant-x"}, config)
    assert isinstance(result, onelake_data._ServiceSessionCredential)
    assert az_calls == []  # az-cli fallback never touched


def test_service_session_credential_get_token_uses_acquire_service_token(monkeypatch):
    calls = []

    def fake_acquire(settings, scopes):
        calls.append((settings, scopes))
        return "delegated-onelake-token"

    monkeypatch.setattr("lineage_web.service_session.acquire_service_token", fake_acquire)
    credential = onelake_data._ServiceSessionCredential({"tenant_id": "tenant-x"})
    access_token = credential.get_token("https://storage.azure.com/.default")
    assert access_token.token == "delegated-onelake-token"
    assert calls == [({"tenant_id": "tenant-x"}, ["https://storage.azure.com/.default"])]


def test_service_session_credential_get_token_raises_when_no_token(monkeypatch):
    monkeypatch.setattr("lineage_web.service_session.acquire_service_token", lambda settings, scopes: "")
    credential = onelake_data._ServiceSessionCredential({})
    try:
        credential.get_token("https://storage.azure.com/.default")
        assert False, "should have raised"
    except onelake_data.OneLakeDataError:
        pass


# ---------------------------------------------------------------------------
# test_connection (2026-08-18, admin-panel completeness pass): the OneLake
# tab's own "Probar conexión" -- resolves the Files directory without
# publishing anything. DataLakeServiceClient is imported inline inside
# test_connection (same lazy-import pattern as _download), so it's
# monkeypatched on the real azure.storage.filedatalake module rather than
# on onelake_data itself.
# ---------------------------------------------------------------------------

def test_connection_reports_missing_fields():
    result = onelake_data.test_connection({})
    assert result["ok"] is False


def test_connection_succeeds_when_the_files_directory_is_reachable(monkeypatch):
    monkeypatch.setattr(onelake_data, "_load_admin_settings", lambda: INERT_SETTINGS)
    monkeypatch.setattr(onelake_data, "_credential", lambda settings, config: object())

    class FakeDirectoryClient:
        def get_directory_properties(self):
            return {}

    class FakeFileSystemClient:
        def get_directory_client(self, path):
            assert path == "LH_WebData.Lakehouse/Files"
            return FakeDirectoryClient()

    class FakeServiceClient:
        def __init__(self, account_url, credential):
            self.account_url = account_url

        def get_file_system_client(self, workspace_name):
            assert workspace_name == "WS1"
            return FakeFileSystemClient()

    import azure.storage.filedatalake as fsdl
    monkeypatch.setattr(fsdl, "DataLakeServiceClient", FakeServiceClient)

    result = onelake_data.test_connection({"workspace_name": "WS1", "lakehouse_name": "LH_WebData"})
    assert result["ok"] is True


def test_connection_reports_failure_on_sdk_exception_instead_of_crashing(monkeypatch):
    monkeypatch.setattr(onelake_data, "_load_admin_settings", lambda: INERT_SETTINGS)
    monkeypatch.setattr(onelake_data, "_credential", lambda settings, config: object())

    class FakeServiceClient:
        def __init__(self, account_url, credential):
            pass

        def get_file_system_client(self, workspace_name):
            raise RuntimeError("workspace not found")

    import azure.storage.filedatalake as fsdl
    monkeypatch.setattr(fsdl, "DataLakeServiceClient", FakeServiceClient)

    result = onelake_data.test_connection({"workspace_name": "WS1", "lakehouse_name": "LH_WebData"})
    assert result["ok"] is False
    assert "workspace not found" in result["message"]


def test_connection_surfaces_a_not_configured_error_from_credential_resolution(monkeypatch):
    monkeypatch.setattr(onelake_data, "_load_admin_settings", lambda: INERT_SETTINGS)

    def raise_not_configured(settings, config):
        raise onelake_data.OneLakeDataNotConfiguredError("Service principal fields are filled in but the client secret is missing.")

    monkeypatch.setattr(onelake_data, "_credential", raise_not_configured)
    result = onelake_data.test_connection({"workspace_name": "WS1", "lakehouse_name": "LH_WebData"})
    assert result["ok"] is False
    assert "client secret" in result["message"]
