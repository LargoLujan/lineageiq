"""Unit tests for lineage_web/service_session.py (2026-07-24): the
persisted delegated "service session" warehouse.py/onelake_data.py fall
back to when no service principal is configured, so live reads still
work on a host with nobody signed in right now (e.g. Render) without
needing a real Entra app registration.

Every test redirects SERVICE_SESSION_PATH to tmp_path -- never touches
the real config/service_session.json -- and monkeypatches auth.
_build_msal_app so no real MSAL/network call ever happens.

Run with: pytest tests/python/test_service_session.py
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import service_session  # noqa: E402

FAKE_SESSION = {"session_id": "sess-1", "user_email": "admin@x.com", "msal_cache": "serialized-cache-blob"}


def _isolate(monkeypatch, tmp_path):
    monkeypatch.setattr(service_session, "SERVICE_SESSION_PATH", tmp_path / "service_session.json")


# ---------------------------------------------------------------------------
# designate
# ---------------------------------------------------------------------------

def test_designate_noop_when_not_admin(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    service_session.designate(FAKE_SESSION, is_admin=False)
    assert service_session.has_service_session() is False


def test_designate_noop_when_no_session(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    service_session.designate(None, is_admin=True)
    assert service_session.has_service_session() is False


def test_designate_noop_when_session_has_no_cache(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    service_session.designate({"user_email": "a@x.com"}, is_admin=True)
    assert service_session.has_service_session() is False


def test_designate_persists_admin_session(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    service_session.designate(FAKE_SESSION, is_admin=True)
    assert service_session.has_service_session() is True
    loaded = service_session._load()
    assert loaded["user_email"] == "admin@x.com"
    assert loaded["msal_cache"] == "serialized-cache-blob"


def test_designate_overwrites_previous_session(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    service_session.designate(FAKE_SESSION, is_admin=True)
    service_session.designate({"user_email": "other-admin@x.com", "msal_cache": "newer-cache"}, is_admin=True)
    loaded = service_session._load()
    assert loaded["user_email"] == "other-admin@x.com"
    assert loaded["msal_cache"] == "newer-cache"


# ---------------------------------------------------------------------------
# has_service_session / _load resilience
# ---------------------------------------------------------------------------

def test_has_service_session_false_when_file_missing(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    assert service_session.has_service_session() is False


def test_load_ignores_corrupt_json(monkeypatch, tmp_path):
    path = tmp_path / "service_session.json"
    path.write_text("{not valid json", encoding="utf-8")
    monkeypatch.setattr(service_session, "SERVICE_SESSION_PATH", path)
    assert service_session._load() is None
    assert service_session.has_service_session() is False


# ---------------------------------------------------------------------------
# acquire_service_token
# ---------------------------------------------------------------------------

class _FakeCache:
    def __init__(self, changed, serialized="reserialized-cache"):
        self.has_state_changed = changed
        self._serialized = serialized

    def serialize(self):
        return self._serialized


class _FakeAccount:
    pass


class _FakeMsalApp:
    def __init__(self, silent_result):
        self._silent_result = silent_result

    def get_accounts(self):
        return [_FakeAccount()]

    def acquire_token_silent(self, scopes, account):
        return self._silent_result


def test_acquire_service_token_empty_when_nothing_designated(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    assert service_session.acquire_service_token({}, ["scope"]) == ""


def test_acquire_service_token_returns_token_on_success(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    service_session.designate(FAKE_SESSION, is_admin=True)

    fake_app = _FakeMsalApp({"access_token": "tok-123"})
    fake_cache = _FakeCache(changed=False)
    monkeypatch.setattr("lineage_web.auth._build_msal_app", lambda settings, serialized_cache=None: (fake_app, fake_cache))

    token = service_session.acquire_service_token({"tenant_id": "tenant-x"}, ["https://database.windows.net/.default"])
    assert token == "tok-123"


def test_acquire_service_token_reperists_cache_when_state_changed(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    service_session.designate(FAKE_SESSION, is_admin=True)

    fake_app = _FakeMsalApp({"access_token": "tok-rotated"})
    fake_cache = _FakeCache(changed=True, serialized="rotated-refresh-token-cache")
    monkeypatch.setattr("lineage_web.auth._build_msal_app", lambda settings, serialized_cache=None: (fake_app, fake_cache))

    token = service_session.acquire_service_token({}, ["scope"])
    assert token == "tok-rotated"
    reloaded = service_session._load()
    assert reloaded["msal_cache"] == "rotated-refresh-token-cache"


def test_acquire_service_token_empty_when_silent_acquisition_fails(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    service_session.designate(FAKE_SESSION, is_admin=True)

    fake_app = _FakeMsalApp(None)  # MSAL returns nothing usable
    fake_cache = _FakeCache(changed=False)
    monkeypatch.setattr("lineage_web.auth._build_msal_app", lambda settings, serialized_cache=None: (fake_app, fake_cache))

    assert service_session.acquire_service_token({}, ["scope"]) == ""


def test_acquire_service_token_empty_on_unexpected_exception(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    service_session.designate(FAKE_SESSION, is_admin=True)

    def raise_error(settings, serialized_cache=None):
        raise RuntimeError("network down")

    monkeypatch.setattr("lineage_web.auth._build_msal_app", raise_error)
    assert service_session.acquire_service_token({}, ["scope"]) == ""
