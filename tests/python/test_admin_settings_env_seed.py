"""Unit tests for lineage_web/admin_settings.py's env-var email seeding:
lets a deploy populate admin_emails/full_scan_emails from
the hosting platform's own env vars (ADMIN_EMAILS/FULL_SCAN_EMAILS)
instead of ever committing a real name/email list to config/
admin_settings.json in a git repo.

Every test redirects ADMIN_SETTINGS_PATH/LAKEHOUSE_TARGET_PATH to
tmp_path -- never touches the real config/admin_settings.json.

Run with: pytest tests/python/test_admin_settings_env_seed.py
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import admin_settings  # noqa: E402


def _isolate(monkeypatch, tmp_path):
    monkeypatch.setattr(admin_settings, "ADMIN_SETTINGS_PATH", tmp_path / "admin_settings.json")
    monkeypatch.setattr(admin_settings, "LAKEHOUSE_TARGET_PATH", tmp_path / "lakehouse_target.json")


# ---------------------------------------------------------------------------
# _emails_from_env
# ---------------------------------------------------------------------------

def test_emails_from_env_splits_and_strips(monkeypatch):
    monkeypatch.setenv("ADMIN_EMAILS", " a@x.com, b@x.com ,,c@x.com")
    assert admin_settings._emails_from_env("ADMIN_EMAILS") == ["a@x.com", "b@x.com", "c@x.com"]


def test_emails_from_env_missing_var_is_empty(monkeypatch):
    monkeypatch.delenv("ADMIN_EMAILS", raising=False)
    assert admin_settings._emails_from_env("ADMIN_EMAILS") == []


# ---------------------------------------------------------------------------
# _load_admin_settings seeding
# ---------------------------------------------------------------------------

def test_load_seeds_empty_lists_from_env_on_first_run(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    monkeypatch.setenv("ADMIN_EMAILS", "admin@x.com")
    monkeypatch.setenv("FULL_SCAN_EMAILS", "scanner@x.com,admin@x.com")

    settings = admin_settings._load_admin_settings()

    assert settings["admin_emails"] == ["admin@x.com"]
    assert settings["full_scan_emails"] == ["scanner@x.com", "admin@x.com"]
    # The seed must never be written back to disk -- otherwise the whole
    # point (no real emails ever committed alongside this file) is moot
    # the moment someone captures the deploy's own filesystem.
    on_disk = (tmp_path / "admin_settings.json").read_text(encoding="utf-8")
    assert "admin@x.com" not in on_disk


def test_load_does_not_override_a_saved_nonempty_list(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    settings = admin_settings._default_admin_settings()
    settings["admin_emails"] = ["real-admin@x.com"]
    admin_settings._write_admin_settings(settings)

    monkeypatch.setenv("ADMIN_EMAILS", "env-admin@x.com")

    loaded = admin_settings._load_admin_settings()
    assert loaded["admin_emails"] == ["real-admin@x.com"]


def test_load_without_env_vars_stays_empty(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    monkeypatch.delenv("ADMIN_EMAILS", raising=False)
    monkeypatch.delenv("FULL_SCAN_EMAILS", raising=False)

    settings = admin_settings._load_admin_settings()
    assert settings["admin_emails"] == []
    assert settings["full_scan_emails"] == []
