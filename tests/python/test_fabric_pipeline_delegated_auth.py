"""Unit tests for the delegated-session auth path added to
backend/scripts/lineage_web/fabric_pipeline.py: a signed-in
user's own device-code session can now drive the Fabric Job Scheduler
calls (trigger/poll/cancel), reusing auth.py's existing MSAL token cache
mechanism -- no Entra app registration needed, unlike the pre-existing
service-principal-only path. Useful for tenants with no app
registration and nobody with permission to create one.

Every Fabric/MSAL/network touchpoint is monkeypatched -- no real HTTP call,
no real token acquisition. See test_fabric_pipeline_scan.py's own
docstring for the broader isolation discipline this project follows.

Run with: pytest tests/python/test_fabric_pipeline_delegated_auth.py
"""
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import auth, fabric_pipeline  # noqa: E402

PIPELINE_NO_SP = {"workspace_id": "ws-1", "pipeline_item_id": "pl-1"}
PIPELINE_WITH_SP = {
    "workspace_id": "ws-1", "pipeline_item_id": "pl-1",
    "sp_tenant_id": "tenant-x", "sp_client_id": "client-x", "sp_client_secret_ref": "TEST_SECRET_REF",
}
FAKE_SESSION = {"session_id": "sess-1", "user_email": "a@x.com", "msal_cache": "serialized-cache"}


def setup_function():
    fabric_pipeline._token_cache["access_token"] = ""
    fabric_pipeline._token_cache["expires_at"] = 0.0


@pytest.fixture(autouse=True)
def _isolate_admin_settings(monkeypatch):
    # test_connection() (unlike every other function in this module) reads
    # _load_admin_settings() directly rather than through the already-
    # mocked _pipeline_settings() -- without this, a test that doesn't
    # separately monkeypatch it touches the real config/admin_settings.json
    # on disk, creating it (and config/lakehouse_target.json) as a side
    # effect of running the suite.
    monkeypatch.setattr(fabric_pipeline, "_load_admin_settings", lambda: {"tenant_id": "tenant-x"})


# ---------------------------------------------------------------------------
# _fields_present / _sp_fields_present
# ---------------------------------------------------------------------------

def test_fields_present_true_without_service_principal():
    assert fabric_pipeline._fields_present(PIPELINE_NO_SP) is True


def test_fields_present_false_without_workspace_or_pipeline_id():
    assert fabric_pipeline._fields_present({"workspace_id": "ws-1"}) is False
    assert fabric_pipeline._fields_present({}) is False


def test_sp_fields_present_reflects_only_sp_fields():
    assert fabric_pipeline._sp_fields_present(PIPELINE_NO_SP) is False
    assert fabric_pipeline._sp_fields_present(PIPELINE_WITH_SP) is True


# ---------------------------------------------------------------------------
# _acquire_delegated_fabric_token
# ---------------------------------------------------------------------------

def test_acquire_delegated_token_empty_without_session():
    assert fabric_pipeline._acquire_delegated_fabric_token(None, {}) == ""


def test_acquire_delegated_token_returns_token_on_success(monkeypatch):
    calls = []

    def fake_acquire_scoped_token(session, settings, scopes):
        calls.append((session, scopes))
        return "delegated-token-abc"

    monkeypatch.setattr(auth, "_acquire_scoped_token", fake_acquire_scoped_token)
    token = fabric_pipeline._acquire_delegated_fabric_token(FAKE_SESSION, {"tenant_id": "tenant-x"})
    assert token == "delegated-token-abc"
    assert calls == [(FAKE_SESSION, ["https://api.fabric.microsoft.com/.default"])]


def test_acquire_delegated_token_empty_when_silent_acquisition_fails(monkeypatch):
    monkeypatch.setattr(auth, "_acquire_scoped_token", lambda session, settings, scopes: None)
    assert fabric_pipeline._acquire_delegated_fabric_token(FAKE_SESSION, {}) == ""


# ---------------------------------------------------------------------------
# _get_token
# ---------------------------------------------------------------------------

def test_get_token_prefers_delegated_session_over_sp(monkeypatch):
    monkeypatch.setattr(fabric_pipeline, "_acquire_delegated_fabric_token", lambda session, settings: "delegated-token")
    sp_calls = []
    monkeypatch.setattr(fabric_pipeline, "_acquire_sp_fabric_token", lambda settings, pipeline: sp_calls.append(1) or "sp-token")

    token = fabric_pipeline._get_token({}, PIPELINE_WITH_SP, session=FAKE_SESSION)
    assert token == "delegated-token"
    assert sp_calls == []  # SP path never touched -- delegated succeeded first


def test_get_token_falls_back_to_sp_when_delegated_unavailable(monkeypatch):
    monkeypatch.setattr(fabric_pipeline, "_acquire_delegated_fabric_token", lambda session, settings: "")
    monkeypatch.setattr(fabric_pipeline, "_acquire_sp_fabric_token", lambda settings, pipeline: "sp-token")

    token = fabric_pipeline._get_token({}, PIPELINE_WITH_SP, session=FAKE_SESSION)
    assert token == "sp-token"


def test_get_token_no_session_uses_sp_directly(monkeypatch):
    delegated_calls = []
    monkeypatch.setattr(fabric_pipeline, "_acquire_delegated_fabric_token", lambda session, settings: delegated_calls.append(1))
    monkeypatch.setattr(fabric_pipeline, "_acquire_sp_fabric_token", lambda settings, pipeline: "sp-token")

    token = fabric_pipeline._get_token({}, PIPELINE_WITH_SP, session=None)
    assert token == "sp-token"
    assert delegated_calls == []  # never attempted -- no session was given at all


def test_get_token_raises_clear_error_with_no_session_and_no_sp(monkeypatch):
    monkeypatch.setattr(fabric_pipeline, "_acquire_delegated_fabric_token", lambda session, settings: "")
    try:
        fabric_pipeline._get_token({}, PIPELINE_NO_SP, session=FAKE_SESSION)
        assert False, "should have raised"
    except fabric_pipeline.FabricPipelineNotConfiguredError as exc:
        assert "session" in str(exc).lower() or "service principal" in str(exc).lower()


def test_get_token_caches_sp_token_across_calls(monkeypatch):
    sp_calls = []
    monkeypatch.setattr(fabric_pipeline, "_acquire_sp_fabric_token", lambda settings, pipeline: sp_calls.append(1) or "sp-token")

    token1 = fabric_pipeline._get_token({}, PIPELINE_WITH_SP, session=None)
    token2 = fabric_pipeline._get_token({}, PIPELINE_WITH_SP, session=None)
    assert token1 == token2 == "sp-token"
    assert len(sp_calls) == 1  # second call served from _token_cache


# ---------------------------------------------------------------------------
# trigger_pipeline_run / get_job_status / cancel_job thread session through
# ---------------------------------------------------------------------------

def test_trigger_pipeline_run_passes_session_to_get_token(monkeypatch):
    monkeypatch.setattr(fabric_pipeline, "_pipeline_settings", lambda: ({}, PIPELINE_NO_SP))
    seen = {}

    def fake_get_token(settings, pipeline, session=None):
        seen["session"] = session
        return "tok"

    monkeypatch.setattr(fabric_pipeline, "_get_token", fake_get_token)
    monkeypatch.setattr(fabric_pipeline, "_request", lambda method, url, token, json_body=None: (202, {}, "https://x/jobs/instances/job-123"))

    job_id = fabric_pipeline.trigger_pipeline_run("SomeWorkspace", session=FAKE_SESSION)
    assert job_id == "job-123"
    assert seen["session"] is FAKE_SESSION


def test_get_job_status_passes_session_to_get_token(monkeypatch):
    monkeypatch.setattr(fabric_pipeline, "_pipeline_settings", lambda: ({}, PIPELINE_NO_SP))
    seen = {}

    def fake_get_token(settings, pipeline, session=None):
        seen["session"] = session
        return "tok"

    monkeypatch.setattr(fabric_pipeline, "_get_token", fake_get_token)
    monkeypatch.setattr(fabric_pipeline, "_request", lambda method, url, token, json_body=None: (200, {"status": "InProgress"}, ""))

    fabric_pipeline.get_job_status("job-123", session=FAKE_SESSION)
    assert seen["session"] is FAKE_SESSION


def test_cancel_job_passes_session_to_get_token(monkeypatch):
    monkeypatch.setattr(fabric_pipeline, "_pipeline_settings", lambda: ({}, PIPELINE_NO_SP))
    seen = {}

    def fake_get_token(settings, pipeline, session=None):
        seen["session"] = session
        return "tok"

    monkeypatch.setattr(fabric_pipeline, "_get_token", fake_get_token)
    monkeypatch.setattr(fabric_pipeline, "_request", lambda method, url, token, json_body=None: (200, {}, ""))

    fabric_pipeline.cancel_job("job-123", session=FAKE_SESSION)
    assert seen["session"] is FAKE_SESSION


# ---------------------------------------------------------------------------
# test_connection (used to hard-require SP fields, which
# always failed the admin panel's own recommended no-SP configuration.
# It was also rewritten to NOT go through
# _get_token/_token_cache at all -- that module-level cache is shared with
# real scan runs, and a "test" button reusing/poisoning it from possibly-
# unsaved form values was a real bug. It now calls
# _acquire_delegated_fabric_token/_acquire_sp_fabric_token directly.)
# ---------------------------------------------------------------------------

def test_connection_reports_missing_fields_without_acquiring_any_token(monkeypatch):
    calls = []
    monkeypatch.setattr(fabric_pipeline, "_acquire_delegated_fabric_token", lambda session, settings: calls.append(1))
    monkeypatch.setattr(fabric_pipeline, "_acquire_sp_fabric_token", lambda settings, pipeline: calls.append(1))
    result = fabric_pipeline.test_connection({"workspace_id": "ws-1"}, session=FAKE_SESSION)
    assert result["ok"] is False
    assert "workspace" in result["message"].lower() or "pipeline" in result["message"].lower()
    assert calls == []


def test_connection_succeeds_via_delegated_session_with_no_sp_configured(monkeypatch):
    monkeypatch.setattr(fabric_pipeline, "_acquire_delegated_fabric_token", lambda session, settings: "delegated-token")
    monkeypatch.setattr(fabric_pipeline, "_request", lambda method, url, token, json_body=None: (200, {"displayName": "PL_Discover", "type": "DataPipeline"}, ""))

    result = fabric_pipeline.test_connection(PIPELINE_NO_SP, session=FAKE_SESSION)
    assert result["ok"] is True
    assert result["item_name"] == "PL_Discover"
    assert result["item_type"] == "DataPipeline"


def test_connection_succeeds_via_service_principal_when_configured(monkeypatch):
    monkeypatch.setattr(fabric_pipeline, "_acquire_delegated_fabric_token", lambda session, settings: "")
    monkeypatch.setattr(fabric_pipeline, "_acquire_sp_fabric_token", lambda settings, pipeline: "sp-token")
    monkeypatch.setattr(fabric_pipeline, "_request", lambda method, url, token, json_body=None: (200, {"displayName": "PL_Discover", "type": "DataPipeline"}, ""))

    result = fabric_pipeline.test_connection(PIPELINE_WITH_SP, session=None)
    assert result["ok"] is True


def test_connection_never_touches_the_shared_token_cache(monkeypatch):
    # The whole point of that rewrite: a successful test must not
    # leave anything in _token_cache for a real run to pick up later.
    monkeypatch.setattr(fabric_pipeline, "_acquire_delegated_fabric_token", lambda session, settings: "")
    monkeypatch.setattr(fabric_pipeline, "_acquire_sp_fabric_token", lambda settings, pipeline: "sp-token")
    monkeypatch.setattr(fabric_pipeline, "_request", lambda method, url, token, json_body=None: (200, {"displayName": "x", "type": "y"}, ""))

    fabric_pipeline.test_connection(PIPELINE_WITH_SP, session=None)
    assert fabric_pipeline._token_cache["access_token"] == ""


def test_connection_returns_clear_error_with_no_session_and_no_sp(monkeypatch):
    # Real _acquire_delegated_fabric_token (not mocked): no session given
    # at all, so it returns "" without even trying -- and no SP fields.
    # This is exactly the case that used to be misreported as an SP-only
    # failure before that fix.
    result = fabric_pipeline.test_connection(PIPELINE_NO_SP, session=None)
    assert result["ok"] is False
    assert "session" in result["message"].lower() or "service principal" in result["message"].lower()


def test_connection_surfaces_fabric_api_error(monkeypatch):
    monkeypatch.setattr(fabric_pipeline, "_acquire_delegated_fabric_token", lambda session, settings: "tok")

    def raise_error(method, url, token, json_body=None):
        raise fabric_pipeline.FabricPipelineError("Fabric API call failed (404): not found")

    monkeypatch.setattr(fabric_pipeline, "_request", raise_error)
    result = fabric_pipeline.test_connection(PIPELINE_NO_SP, session=FAKE_SESSION)
    assert result["ok"] is False
    assert "404" in result["message"]


def test_connection_reports_a_plain_exception_from_sp_token_acquisition_instead_of_crashing(monkeypatch):
    # MSAL's ConfidentialClientApplication
    # performs authority/OIDC discovery in its constructor and can raise a
    # plain ValueError (e.g. a bad tenant id) instead of a
    # FabricPipelineError -- this must still return a JSON verdict, not
    # propagate and kill the request with no response.
    monkeypatch.setattr(fabric_pipeline, "_acquire_delegated_fabric_token", lambda session, settings: "")

    def raise_value_error(settings, pipeline):
        raise ValueError("Unable to get authority configuration for https://login.microsoftonline.com/bad-tenant/")

    monkeypatch.setattr(fabric_pipeline, "_acquire_sp_fabric_token", raise_value_error)
    result = fabric_pipeline.test_connection(PIPELINE_WITH_SP, session=None)
    assert result["ok"] is False
    assert "authority" in result["message"].lower()


def test_connection_reports_a_plain_exception_from_the_request_call_instead_of_crashing(monkeypatch):
    monkeypatch.setattr(fabric_pipeline, "_acquire_delegated_fabric_token", lambda session, settings: "tok")

    def raise_runtime_error(method, url, token, json_body=None):
        raise RuntimeError("unexpected transport failure")

    monkeypatch.setattr(fabric_pipeline, "_request", raise_runtime_error)
    result = fabric_pipeline.test_connection(PIPELINE_NO_SP, session=FAKE_SESSION)
    assert result["ok"] is False
    assert "unexpected transport failure" in result["message"]
