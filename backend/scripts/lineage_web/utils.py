"""Generic utilities with no dependency on this server's own shared state.

Split out of lineage_web_server.py -- pure code motion,
no logic changed from the original.
"""
import hashlib
import os
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from .paths import REPO_ROOT


def _now_iso():
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def _hash_api_key(raw_key):
    """One-way hash for API keys at rest (auth.py's _valid_api_key_name,
    admin_settings.py's legacy-entry migration) -- lives here rather than
    in auth.py so admin_settings.py can use it too without a circular
    import (auth.py already imports FROM admin_settings.py). SHA-256 is
    fine here (not bcrypt/argon2/PBKDF2): these are 256-bit
    secrets.token_urlsafe values, not user-chosen passwords, so there's no
    low-entropy-guessing risk a slow/salted KDF would need to defend
    against -- the only thing this hash needs to do is keep the raw key
    itself out of admin_settings.json."""
    return hashlib.sha256(raw_key.encode("utf-8")).hexdigest()


def _slugify(name):
    slug = "".join(ch.lower() if ch.isalnum() else "-" for ch in name)
    while "--" in slug:
        slug = slug.replace("--", "-")
    return slug.strip("-") or "workspace"


def _is_pid_alive(pid):
    if pid is None:
        return False
    if os.name == "nt":
        result = subprocess.run(["tasklist", "/FI", f"PID eq {pid}"], capture_output=True, text=True)
        return str(pid) in result.stdout
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def _kill_process_tree(pid):
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(pid)], capture_output=True, text=True)
        return
    try:
        os.killpg(os.getpgid(pid), 15)
    except (OSError, ProcessLookupError):
        try:
            os.kill(pid, 15)
        except OSError:
            pass


def _duration_seconds_between(started_at_iso, ended_at_iso):
    try:
        started = datetime.fromisoformat(started_at_iso)
        ended = datetime.fromisoformat(ended_at_iso)
        return round((ended - started).total_seconds(), 3)
    except (TypeError, ValueError):
        return 0.0


def _now_iso_to_epoch(iso_string):
    # _now_iso()'s own format, parsed back to the same time.time()-shaped
    # epoch float a fresh scan trigger would pass -- lets a resumed poll
    # loop (see scan_manager._recover_scan_state_on_startup) compute total
    # elapsed duration across a server restart the same way a scan that
    # never restarted would.
    try:
        return datetime.fromisoformat(iso_string).timestamp()
    except (TypeError, ValueError):
        return datetime.now(timezone.utc).timestamp()


def _resolve_az_command():
    return shutil.which("az.cmd") or shutil.which("az")


def _resolve_pwsh_command():
    return shutil.which("pwsh") or shutil.which("pwsh.exe")


def _relative_to_repo(path):
    try:
        return str(path.relative_to(REPO_ROOT)).replace("\\", "/")
    except ValueError:
        return str(path)


def _tail_log(log_path, max_lines=40):
    if not log_path:
        return []
    path = Path(log_path)
    if not path.is_absolute():
        path = REPO_ROOT / log_path
    if not path.exists():
        return []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except OSError:
        return []
    return [line.rstrip("\n") for line in lines[-max_lines:]]
