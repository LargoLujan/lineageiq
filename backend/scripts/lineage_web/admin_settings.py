"""Admin settings: load/save/merge config/admin_settings.json.

Split out of lineage_web_server.py (D.3, 2026-07-08) -- pure code motion,
no logic changed from the original.
"""
import json
import os
import threading

from .constants import DEFAULT_ADMIN_SETTINGS
from .paths import ADMIN_SETTINGS_PATH, LAKEHOUSE_TARGET_PATH
from .utils import _hash_api_key

# Guards the actual file I/O in _load_admin_settings/_write_admin_settings
# (2026-08-26 security audit finding: the write used to be a direct
# open(..., "w"), so a crash/restart mid-write could leave a torn/corrupt
# JSON file, and two threads writing at once could interleave). Does NOT
# cover the full read-mutate-write span of each handler.py route (that
# would need every admin route rewritten around a single held lock, a much
# bigger change) -- this narrows the race to "two concurrent admin edits,
# one clobbers the other's change" (a rare, low-impact lost-update), while
# fully closing off file corruption, which is the outcome that actually
# breaks the whole admin panel until someone repairs the file by hand.
_settings_io_lock = threading.Lock()

# Added 2026-08-11: lets a deploy seed admin_emails/full_scan_emails from
# the hosting platform's own env-var secret store (Render's Environment
# tab) instead of a real name/email list ever being committed to a git
# repo -- same "env var, never a file" convention this project already
# uses for every other secret (sp_client_secret_ref). Deliberately only a
# SEED (applied when the file's own list is still empty), not a hard
# override: an admin's later edit via the panel (saved to this same file)
# is respected for the life of that running process; it only reverts to
# the env var baseline after a restart wipes the deploy's ephemeral disk
# back to the baked-in (empty) file -- a known limitation of the free/
# low-tier hosting this was built for, not something this seed makes
# worse.
def _emails_from_env(var_name):
    raw = os.environ.get(var_name, "")
    return [email.strip() for email in raw.split(",") if email.strip()]


def _default_admin_settings():
    import copy

    return copy.deepcopy(DEFAULT_ADMIN_SETTINGS)


def _merge_admin_settings(defaults, loaded):
    """A plain dict.update() is shallow: a saved "notifications" (or
    "lakehouse") object that's missing a key -- e.g. the very first time a
    subscriber saves their own preferences, before anyone has ever touched
    the SMTP fields -- permanently wipes that key's default back to nothing
    on every future load, since the whole sub-dict gets replaced instead of
    filled in. One level deep is enough here: every nested value in
    DEFAULT_ADMIN_SETTINGS is either a plain value or a flat dict (never a
    dict-of-dicts), except external_sources/subscribers, which are lists of
    independent records the caller always writes back in full anyway."""
    merged = dict(defaults)
    for key, value in loaded.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = {**merged[key], **value}
        else:
            merged[key] = value
    return merged


def _seed_emails_from_env(settings):
    if not settings.get("admin_emails"):
        seeded = _emails_from_env("ADMIN_EMAILS")
        if seeded:
            settings["admin_emails"] = seeded
    if not settings.get("full_scan_emails"):
        seeded = _emails_from_env("FULL_SCAN_EMAILS")
        if seeded:
            settings["full_scan_emails"] = seeded
    return settings


def _migrate_users_from_flat_lists(settings):
    """One-time upgrade for any real installation from before Fase 3
    (2026-08-24): admin_emails/full_scan_emails existed as flat lists long
    before the "Usuarios permitidos" table did, and _merge_admin_settings
    has no way to know a brand-new "users" key should be backfilled from
    them instead of starting empty -- without this, upgrading silently
    "loses" every admin the tab used to show (the flat lists themselves
    are untouched on disk and _email_in_allowlist keeps working off them
    regardless, but the new table renders "Vacío." until this runs once).
    Case-insensitive de-dupe across both lists (a real tenant's file can
    end up with e.g. "Jane.Doe@example.com" and "jane.doe@example.com" as
    the same person, just inconsistent casing from manual edits over
    time) -- first-seen casing is kept as the display value. Returns (settings, changed)
    so the caller only re-writes the file when there was actually
    something to migrate, same pattern as _migrate_api_keys."""
    if settings.get("users"):
        return settings, False
    admin_emails = settings.get("admin_emails") or []
    full_scan_emails = settings.get("full_scan_emails") or []
    if not admin_emails and not full_scan_emails:
        return settings, False
    admin_set = {e.strip().lower() for e in admin_emails if e.strip()}
    full_scan_set = {e.strip().lower() for e in full_scan_emails if e.strip()}
    seen = {}
    for email in list(admin_emails) + list(full_scan_emails):
        normalized = email.strip().lower()
        if not normalized or normalized in seen:
            continue
        seen[normalized] = email.strip()
    settings["users"] = [
        {
            "email": original, "full_name": "", "job_title": "",
            "is_admin": normalized in admin_set, "can_full_scan": normalized in full_scan_set,
            "can_install": False,
        }
        for normalized, original in seen.items()
    ]
    return settings, True


def _migrate_api_keys(settings):
    """One-time upgrade of any legacy {"key": <raw>} entry (created before
    2026-08-17) to {"key_hash", "key_preview"} -- see auth.py's
    _valid_api_key_name. A key already in use keeps working: the raw value
    its owner already has still hashes to the same key_hash. Returns
    (settings, changed) so the caller only re-writes the file when there
    was actually something to migrate."""
    api_keys = settings.get("api_keys") or []
    if not any("key" in entry for entry in api_keys):
        return settings, False
    settings["api_keys"] = [
        {
            "name": entry.get("name", ""),
            "key_hash": _hash_api_key(entry["key"]),
            "key_preview": "..." + entry["key"][-4:],
            "created_at": entry.get("created_at", ""),
        }
        if "key" in entry else entry
        for entry in api_keys
    ]
    return settings, True


def _load_admin_settings():
    if not ADMIN_SETTINGS_PATH.exists():
        settings = _default_admin_settings()
        _write_admin_settings(settings)
        settings = _seed_emails_from_env(settings)
        # Env-seeded emails are deliberately never persisted (see
        # _seed_emails_from_env's own docstring) -- the users derived from
        # them here follow the same rule, so this migration only writes to
        # settings["users"] in memory for THIS response, never back to disk.
        settings, _users_changed = _migrate_users_from_flat_lists(settings)
        return settings
    try:
        with _settings_io_lock:
            with open(ADMIN_SETTINGS_PATH, "r", encoding="utf-8") as handle:
                loaded = json.load(handle)
    except (json.JSONDecodeError, OSError):
        settings = _seed_emails_from_env(_default_admin_settings())
        settings, _users_changed = _migrate_users_from_flat_lists(settings)
        return settings
    settings = _merge_admin_settings(_default_admin_settings(), loaded)
    settings, api_keys_migrated = _migrate_api_keys(settings)
    # Runs BEFORE env-seeding on purpose: only backfills "users" from
    # admin_emails/full_scan_emails values that were actually already on
    # disk, so what gets persisted here never bakes in an env-var seed
    # that isn't supposed to survive a restart either.
    settings, users_migrated = _migrate_users_from_flat_lists(settings)
    if api_keys_migrated or users_migrated:
        _write_admin_settings(settings)
    return _seed_emails_from_env(settings)


def _write_admin_settings(settings):
    ADMIN_SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = ADMIN_SETTINGS_PATH.with_name(ADMIN_SETTINGS_PATH.name + ".tmp")
    with _settings_io_lock:
        with open(tmp_path, "w", encoding="utf-8") as handle:
            json.dump(settings, handle, indent=2)
        os.replace(tmp_path, ADMIN_SETTINGS_PATH)
    _mirror_lakehouse_target_config(settings)


def _reserved_secret_env_var_name(settings):
    """The one env var name this project's own config treats as its
    highest-privilege secret pointer -- the Warehouse/Fabric service-
    principal client secret (settings.lakehouse.sp_client_secret_ref).
    Read live from settings rather than hardcoded, since that ref name is
    itself admin-configurable, not a fixed string.

    A data-source password_ref / notification smtp_password_ref must never
    be allowed to equal this (2026-08-26 security audit): those two are
    resolved server-side and then handed to wherever the SAME admin points
    the "Probar conexión"/"Enviar prueba" button -- an arbitrary SQL host
    or SMTP server the admin typed into the same form. Without this check,
    pointing password_ref at the SP secret's own env var turns that test
    button into a way to exfiltrate a strictly higher-privilege secret
    than anything a data-source or notification password is meant to be."""
    lakehouse = settings.get("lakehouse") or {}
    return (lakehouse.get("sp_client_secret_ref") or "").strip() or None


def _mirror_lakehouse_target_config(settings):
    """config/admin_settings.json's `lakehouse` block is the one place an
    admin actually edits Lakehouse settings (see the admin panel's
    Lakehouse tab); config/lakehouse_target.json is kept as an
    auto-generated mirror in its own historical flat schema purely so the
    five scripts that already read that file directly (64_upload_bronze_
    to_onelake.py/.ps1, 65_validate_lakehouse_gold_parity.ps1,
    99_refresh_lineage_project.ps1, scan_single_workspace.ps1) don't need
    their own config-reading logic changed -- this keeps the two files
    from ever drifting apart instead of migrating every reader (a much
    larger, harder-to-verify change with no live Lakehouse yet to test
    against)."""
    lakehouse = settings.get("lakehouse") or {}
    mirrored = {
        "tenant_id": settings.get("tenant_id", ""),
        "workspace_name": lakehouse.get("workspace_name", ""),
        "workspace_id": lakehouse.get("workspace_id", ""),
        "lakehouse_name": lakehouse.get("lakehouse_name", ""),
        "lakehouse_id": lakehouse.get("lakehouse_id", ""),
        "capacity_name": lakehouse.get("capacity_name", ""),
        "sql_endpoint_connection_string": lakehouse.get("sql_endpoint_connection_string", ""),
        # Added 2026-07-20 alongside 67_upload_bronze_to_warehouse.ps1 --
        # not read by any of the five scripts this mirror originally
        # existed for, kept here anyway so a Lakehouse/Warehouse pick made
        # in the admin panel is visible to anything reading this file
        # directly, not just admin_settings.json.
        "item_type": lakehouse.get("item_type", "Lakehouse"),
        # Added 2026-07-21 alongside the service-principal (permanent token)
        # auth mode -- 67_upload_bronze_to_warehouse.ps1 reads these three
        # straight off this mirrored file (Set-StrictMode requires the keys
        # to always exist, even empty, so a config saved before this field
        # existed doesn't throw).
        "auth_mode": lakehouse.get("auth_mode", "user_session"),
        "sp_tenant_id": lakehouse.get("sp_tenant_id") or settings.get("tenant_id", ""),
        "sp_client_id": lakehouse.get("sp_client_id", ""),
        "sp_client_secret_ref": lakehouse.get("sp_client_secret_ref", ""),
    }
    LAKEHOUSE_TARGET_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(LAKEHOUSE_TARGET_PATH, "w", encoding="utf-8") as handle:
        json.dump(mirrored, handle, indent=2)


def _email_in_allowlist(email, settings, list_key):
    if not email:
        return False
    allowlist = settings.get(list_key) or []
    normalized = email.strip().lower()
    return any(str(entry).strip().lower() == normalized for entry in allowlist)
