"""Unit tests for lineage_web/admin_settings.py's _migrate_users_from_flat_
lists -- backfills the "Usuarios permitidos" table's `users`
list from admin_emails/full_scan_emails for any real installation that had
those flat lists populated before the "users" table existed. Written after
a real production config/admin_settings.json lost its "Usuarios
permitidos" display (the flat lists were untouched, but the new table had
nothing to read until this migration existed).

Every test redirects ADMIN_SETTINGS_PATH/LAKEHOUSE_TARGET_PATH to
tmp_path -- never touches the real config/admin_settings.json.
"""
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import admin_settings  # noqa: E402


def _isolate(monkeypatch, tmp_path):
    monkeypatch.setattr(admin_settings, "ADMIN_SETTINGS_PATH", tmp_path / "admin_settings.json")
    monkeypatch.setattr(admin_settings, "LAKEHOUSE_TARGET_PATH", tmp_path / "lakehouse_target.json")


# ---------------------------------------------------------------------------
# _migrate_users_from_flat_lists (pure function)
# ---------------------------------------------------------------------------

def test_migrate_users_builds_users_from_both_lists():
    settings = {
        "admin_emails": ["admin@x.com", "shared@x.com"],
        "full_scan_emails": ["scanner@x.com", "shared@x.com"],
        "users": [],
    }
    migrated, changed = admin_settings._migrate_users_from_flat_lists(settings)
    assert changed is True
    by_email = {u["email"]: u for u in migrated["users"]}
    assert set(by_email) == {"admin@x.com", "shared@x.com", "scanner@x.com"}
    assert by_email["admin@x.com"]["is_admin"] is True
    assert by_email["admin@x.com"]["can_full_scan"] is False
    assert by_email["shared@x.com"]["is_admin"] is True
    assert by_email["shared@x.com"]["can_full_scan"] is True
    assert by_email["scanner@x.com"]["is_admin"] is False
    assert by_email["scanner@x.com"]["can_full_scan"] is True
    assert all(u["can_install"] is False for u in migrated["users"])
    assert all(u["full_name"] == "" and u["job_title"] == "" for u in migrated["users"])


def test_migrate_users_case_insensitive_dedupe_keeps_first_seen_casing():
    settings = {
        "admin_emails": ["Jane.Doe@example.com"],
        "full_scan_emails": ["jane.doe@example.com"],
        "users": [],
    }
    migrated, changed = admin_settings._migrate_users_from_flat_lists(settings)
    assert changed is True
    assert len(migrated["users"]) == 1
    entry = migrated["users"][0]
    assert entry["email"] == "Jane.Doe@example.com"  # first-seen casing (admin_emails wins)
    assert entry["is_admin"] is True
    assert entry["can_full_scan"] is True


def test_migrate_users_no_op_when_users_already_populated():
    settings = {"admin_emails": ["admin@x.com"], "full_scan_emails": [], "users": [{"email": "existing@x.com"}]}
    migrated, changed = admin_settings._migrate_users_from_flat_lists(settings)
    assert changed is False
    assert migrated["users"] == [{"email": "existing@x.com"}]  # untouched


def test_migrate_users_no_op_when_both_lists_empty():
    settings = {"admin_emails": [], "full_scan_emails": [], "users": []}
    migrated, changed = admin_settings._migrate_users_from_flat_lists(settings)
    assert changed is False
    assert migrated["users"] == []


# ---------------------------------------------------------------------------
# _load_admin_settings integration
# ---------------------------------------------------------------------------

def test_load_migrates_and_persists_users_from_a_real_saved_file(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    settings = admin_settings._default_admin_settings()
    settings["admin_emails"] = ["admin.one@example.com", "admin.two@example.com"]
    settings["full_scan_emails"] = ["admin.one@example.com", "admin.two@example.com"]
    admin_settings._write_admin_settings(settings)

    loaded = admin_settings._load_admin_settings()

    emails = {u["email"] for u in loaded["users"]}
    assert emails == {"admin.one@example.com", "admin.two@example.com"}
    assert all(u["is_admin"] and u["can_full_scan"] for u in loaded["users"])
    # The whole point: this must be PERSISTED (unlike env-seeded emails)
    # since it was derived from data that was already really on disk.
    on_disk = json.loads((tmp_path / "admin_settings.json").read_text(encoding="utf-8"))
    assert {u["email"] for u in on_disk["users"]} == emails


def test_load_does_not_persist_users_derived_from_env_seeded_emails(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    monkeypatch.setenv("ADMIN_EMAILS", "env-admin@x.com")
    monkeypatch.setenv("FULL_SCAN_EMAILS", "env-admin@x.com")

    loaded = admin_settings._load_admin_settings()

    # In-memory, this request's response DOES show the env-seeded user...
    assert any(u["email"] == "env-admin@x.com" for u in loaded["users"])
    # ...but nothing about it (or the emails themselves) is on disk, same
    # "never persist an env seed" contract _seed_emails_from_env already has.
    on_disk = (tmp_path / "admin_settings.json").read_text(encoding="utf-8")
    assert "env-admin@x.com" not in on_disk
