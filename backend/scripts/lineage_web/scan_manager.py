"""Scan trigger: workspace/full-tenant scan lifecycle, diffing, history, notifications.

Split out of lineage_web_server.py -- pure code motion,
no logic changed from the original.
"""
import html
import json
import os
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime

from . import fabric_pipeline, warehouse
from .admin_settings import _email_in_allowlist, _load_admin_settings, _reserved_secret_env_var_name
from .auth import _acquire_scoped_token, _get_session
from .constants import (
    DEPENDENCY_DIFF_TRACKED_FIELDS,
    DIFF_TRACKED_FIELDS,
    EXECUTIONS_SCAN_LABEL,
    FABRIC_TOKEN_SCOPES,
    FULL_SCAN_LABEL,
    HISTORY_FIELDS,
    MAX_QUEUED_SCANS,
    NOTIFICATION_TEXT,
    ONELAKE_PUBLISH_LABEL,
    WAREHOUSE_UPLOAD_LABEL,
)
from .fabric_api import _fetch_all_tenant_workspaces, _fetch_my_workspaces
from .paths import (
    DEPENDENCY_HISTORY_FIELDS,
    DIFF_DIR,
    EXECUTIONS_SCAN_SCRIPT_PATH,
    FULL_SCAN_SCRIPT_PATH,
    HISTORY_PATH,
    ITEM_HISTORY_FIELDS,
    ITEM_HISTORY_PATH,
    ITEMS_INDEX_PATH,
    LOG_DIR,
    ONELAKE_PUBLISH_SCRIPT_PATH,
    PROGRESS_PATH,
    QUEUE_PATH,
    REPO_ROOT,
    SCAN_SCRIPT_PATH,
    STATE_DIR,
    STATE_PATH,
    WAREHOUSE_UPLOAD_SCRIPT_PATH,
    WORKSPACE_INDEX_PATH,
)
from .state import _scan_lock, _scan_queue, _scan_state
from .utils import (
    _duration_seconds_between,
    _is_pid_alive,
    _kill_process_tree,
    _now_iso,
    _now_iso_to_epoch,
    _relative_to_repo,
    _resolve_az_command,
    _resolve_pwsh_command,
    _slugify,
)


def _read_progress():
    if not PROGRESS_PATH.exists():
        return None
    try:
        with open(PROGRESS_PATH, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (json.JSONDecodeError, OSError):
        return None


def _write_scan_state():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(STATE_PATH, "w", encoding="utf-8") as handle:
        json.dump(_scan_state, handle, indent=2)


def _load_scan_state_from_disk():
    if STATE_PATH.exists():
        try:
            with open(STATE_PATH, "r", encoding="utf-8") as handle:
                loaded = json.load(handle)
            _scan_state.update(loaded)
        except (json.JSONDecodeError, OSError):
            pass


def _write_scan_queue():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(QUEUE_PATH, "w", encoding="utf-8") as handle:
        json.dump(_scan_queue, handle, indent=2)


def _load_scan_queue_from_disk():
    if QUEUE_PATH.exists():
        try:
            with open(QUEUE_PATH, "r", encoding="utf-8") as handle:
                loaded = json.load(handle)
            if isinstance(loaded, list):
                _scan_queue[:] = loaded
        except (json.JSONDecodeError, OSError):
            pass


def _queue_entry_workspace_label(entry):
    if entry["kind"] == "scan":
        return entry["workspace_name"]
    if entry["kind"] == "executions_scan":
        return EXECUTIONS_SCAN_LABEL
    if entry["kind"] == "warehouse_upload":
        return WAREHOUSE_UPLOAD_LABEL
    if entry["kind"] == "onelake_publish":
        return ONELAKE_PUBLISH_LABEL
    return FULL_SCAN_LABEL


def _queue_snapshot():
    """Sanitized view of the pending queue for /api/status and MCP callers
    -- never session_id or api_key_name, matching how _scan_state's own
    started_by_email is already the only identity fact those callers see."""
    with _scan_lock:
        return [
            {
                "queue_id": entry["queue_id"],
                "kind": entry["kind"],
                "workspace": _queue_entry_workspace_label(entry),
                "requested_by_email": entry["requested_by_email"],
                "requested_at": entry["requested_at"],
                "position": position,
            }
            for position, entry in enumerate(_scan_queue, start=1)
        ]


def _enqueue_locked(kind, workspace_name, session, api_key_name, system_triggered=False):
    """Appends a new queue entry. Must be called with _scan_lock already
    held (every caller is already inside a `with _scan_lock:` block that
    just found a scan running) -- returns the entry plus its 1-based
    position. Does NOT call _write_scan_queue(); callers do that themselves
    once, after this returns, matching how _scan_state's own callers write
    it once per transition rather than on every individual field set.
    system_triggered marks an entry the server queued on its own (see
    _maybe_trigger_warehouse_upload) rather than in response to an actual
    HTTP request -- _dequeue_and_start_next reads it back to skip the
    caller-identity permission check that would otherwise reject a
    session-less, API-key-less entry."""
    entry = {
        "queue_id": secrets.token_urlsafe(8),
        "kind": kind,
        "workspace_name": workspace_name,
        "session_id": session.get("session_id") if session else None,
        "api_key_name": api_key_name,
        "requested_by_email": session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else "system" if system_triggered else "anonymous"),
        "requested_at": _now_iso(),
        "system_triggered": system_triggered,
    }
    _scan_queue.append(entry)
    return entry, len(_scan_queue)


def _record_queue_entry_failure(entry, error_code, message):
    """A queued request that can no longer be started once its turn comes
    (its session signed out while it waited, most likely) still deserves a
    history.csv row -- otherwise it would just silently vanish from the
    queue with no record anywhere that it was ever there or why it never
    ran, unlike every other scan outcome this file records."""
    now = _now_iso()
    scope_label = _queue_entry_workspace_label(entry)
    with _scan_lock:
        _scan_state["status"] = "failed"
        _scan_state["workspace"] = scope_label
        _scan_state["pid"] = None
        _scan_state["scan_id"] = entry["requested_at"]
        _scan_state["started_at"] = entry["requested_at"]
        _scan_state["ended_at"] = now
        _scan_state["duration_seconds"] = 0
        _scan_state["exit_code"] = None
        _scan_state["log_path"] = None
        _scan_state["last_error"] = f"{error_code}: {message}" if message else error_code
        _scan_state["cancel_requested"] = False
        _scan_state["started_by_email"] = entry["requested_by_email"]
        _write_scan_state()
    _append_history_row(scope_label, entry["requested_at"], now, 0, "failed")


def _dequeue_and_start_next():
    """Called once a scan's state has been finalized to a terminal status
    (succeeded/failed/cancelled), from every place that can make that
    transition happen: normal completion (_wait_for_process /
    _wait_for_full_scan_process) and the two server-restart recovery paths
    (_recover_scan_state_on_startup, _watch_pid_until_exit) -- a queued
    request left behind by a restart would otherwise wait forever for a
    scan that will never again finish from this process's point of view.
    Re-runs the normal _start_scan/_start_full_scan entry points rather
    than duplicating their spawn logic, so a popped entry gets exactly the
    same validation (and a freshly-reacquired token, since _acquire_scoped_
    token is called fresh inside _build_scan_subprocess_env / _start_full_
    scan's own workspace lookup, not the possibly stale one captured at
    enqueue time) as a brand new request would. Recurses past any entry
    that fails outright (e.g. a session that expired while queued) so one
    bad entry doesn't block everyone behind it."""
    with _scan_lock:
        if not _scan_queue or _scan_state.get("status") == "running":
            return
        entry = _scan_queue.pop(0)
        _write_scan_queue()

    session = _get_session(entry["session_id"]) if entry.get("session_id") else None
    if entry.get("session_id") and session is None:
        _record_queue_entry_failure(
            entry, "session_expired",
            "Session expired or was signed out while this request was waiting in the queue. Sign in again and re-queue it.",
        )
        _dequeue_and_start_next()
        return

    # If a brand new request raced this one for the just-freed slot and won
    # (the narrow window between the pop above and the claim inside
    # _start_scan/_start_full_scan below), neither of those functions
    # returns an error for that -- they see "running" again and simply
    # re-queue this entry at the back, same as any other busy-server
    # request. So the only outcome worth recording here as a real failure
    # is an actual validation error (bad workspace, expired az session,
    # spawn_failed, ...).
    if entry["kind"] == "full_scan":
        _result, error = _start_full_scan(session, api_key_name=entry.get("api_key_name"))
    elif entry["kind"] == "executions_scan":
        _result, error = _start_executions_scan(session, api_key_name=entry.get("api_key_name"))
    elif entry["kind"] == "warehouse_upload":
        _result, error = _start_warehouse_upload(session, api_key_name=entry.get("api_key_name"), system_triggered=entry.get("system_triggered", False))
    elif entry["kind"] == "onelake_publish":
        _result, error = _start_onelake_publish(session, api_key_name=entry.get("api_key_name"), system_triggered=entry.get("system_triggered", False))
    else:
        _result, error = _start_scan(entry["workspace_name"], session, api_key_name=entry.get("api_key_name"))

    if error:
        _record_queue_entry_failure(entry, error["error"], error.get("message", ""))
        _dequeue_and_start_next()


def _recover_scan_state_on_startup():
    workspace = None
    started_at_iso = None
    ended_at_iso = None
    status = None
    with _scan_lock:
        if _scan_state.get("status") == "running":
            fabric_job_instance_id = _scan_state.get("fabric_job_instance_id")
            pid = _scan_state.get("pid")
            if fabric_job_instance_id:
                # A Fabric-pipeline scan has no local process at all (pid is
                # always None for this kind of run) -- the pipeline itself
                # keeps running in Fabric's own capacity regardless of this
                # server's uptime (e.g. a free-tier host that spins down
                # after 15 minutes of no inbound traffic). Treating "pid not
                # alive" as "scan failed" here would be actively wrong: it
                # would mark a scan that's still running -- or already
                # finished successfully -- in Fabric as failed, the moment
                # anyone's next visit wakes this process back up. Re-attach
                # to the real job instead of guessing: resume the exact same
                # poll loop a freshly-triggered run would use, with no
                # session (falls back to the configured service principal,
                # same as a scan triggered by someone no longer signed in --
                # see fabric_pipeline.py's own docstring). started_at is
                # reused as the wall-clock origin for duration, same as a
                # fresh trigger passes time.time() under that same name.
                started_at_iso = _scan_state.get("started_at")
                started_epoch = _now_iso_to_epoch(started_at_iso) if started_at_iso else time.time()
                threading.Thread(
                    target=_wait_for_fabric_pipeline_job,
                    args=(fabric_job_instance_id, _scan_state.get("workspace"), started_at_iso, started_epoch),
                    kwargs={"session": None},
                    daemon=True,
                ).start()
            elif not _is_pid_alive(pid):
                was_cancelled = bool(_scan_state.get("cancel_requested"))
                status = "cancelled" if was_cancelled else "failed"
                ended_at_iso = _now_iso()
                _scan_state["status"] = status
                _scan_state["ended_at"] = ended_at_iso
                if not was_cancelled:
                    _scan_state["last_error"] = (
                        "The scan process was no longer running when the server restarted "
                        "(server restart during an in-progress scan). Check the log file "
                        "for how far it got."
                    )
                workspace = _scan_state.get("workspace")
                started_at_iso = _scan_state.get("started_at")
                _write_scan_state()
            else:
                threading.Thread(target=_watch_pid_until_exit, args=(pid,), daemon=True).start()
    # A scan that was still "running" per the state file but whose process
    # is already gone by the time the server comes back up (it died, or was
    # killed, entirely while nothing was watching it) still needs a
    # history.csv row -- otherwise a stop/crash that happens to straddle a
    # server restart would be the one case that silently never gets
    # recorded anywhere. Not reached for the fabric_job_instance_id branch
    # above -- _wait_for_fabric_pipeline_job writes its own history row
    # once the resumed poll loop reaches a real terminal status.
    if workspace and started_at_iso and ended_at_iso:
        _append_history_row(workspace, started_at_iso, ended_at_iso, _duration_seconds_between(started_at_iso, ended_at_iso), status)
        _dequeue_and_start_next()


def _watch_pid_until_exit(pid):
    while _is_pid_alive(pid):
        time.sleep(2)
    workspace = None
    started_at_iso = None
    ended_at_iso = None
    status = None
    with _scan_lock:
        if _scan_state.get("status") == "running" and _scan_state.get("pid") == pid:
            was_cancelled = bool(_scan_state.get("cancel_requested"))
            status = "cancelled" if was_cancelled else "failed"
            ended_at_iso = _now_iso()
            _scan_state["status"] = status
            _scan_state["ended_at"] = ended_at_iso
            _scan_state["exit_code"] = None
            _scan_state["last_error"] = "Stopped by user request." if was_cancelled else (
                "The scan process exited, but its real exit code could not be recovered "
                "because the server restarted while it was running. Check the log file "
                "to see whether it actually finished successfully."
            )
            workspace = _scan_state.get("workspace")
            started_at_iso = _scan_state.get("started_at")
            _write_scan_state()
    if workspace and started_at_iso and ended_at_iso:
        _append_history_row(workspace, started_at_iso, ended_at_iso, _duration_seconds_between(started_at_iso, ended_at_iso), status)
        _dequeue_and_start_next()


def _check_az_session():
    az_path = _resolve_az_command()
    if not az_path:
        return False, "Azure CLI ('az') was not found on PATH."
    try:
        result = subprocess.run(
            [az_path, "account", "get-access-token", "--resource", "https://api.fabric.microsoft.com", "--query", "accessToken", "-o", "tsv"],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f"Could not run 'az account get-access-token': {exc}"

    if result.returncode != 0 or not result.stdout.strip():
        detail = (result.stderr or result.stdout or "").strip()
        return False, f"Azure CLI session is missing or expired. Details: {detail}"

    return True, ""


def _read_workspaces():
    import csv

    if not WORKSPACE_INDEX_PATH.exists():
        return None
    with open(WORKSPACE_INDEX_PATH, "r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        rows = []
        for row in reader:
            workspace_id = row.get("technical_id", "")
            rows.append(
                {
                    "workspace_name": row.get("workspace_name", ""),
                    "environment": row.get("environment", ""),
                    "capacity_region": row.get("capacity_region", ""),
                    "status": row.get("status", ""),
                    "workspace_id": workspace_id,
                    "fabric_url": f"https://app.fabric.microsoft.com/groups/{workspace_id}/list" if workspace_id else "",
                }
            )
    rows.sort(key=lambda item: item["workspace_name"].lower())
    return rows


def _read_history(workspace_filter=None, limit=20):
    import csv

    if not HISTORY_PATH.exists():
        return []
    with open(HISTORY_PATH, "r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        rows = list(reader)
    if workspace_filter:
        rows = [row for row in rows if row.get("workspace_name") == workspace_filter]
    rows.sort(key=lambda row: row.get("started_at", ""), reverse=True)
    return rows[:limit]


def _wait_for_process(proc, workspace, started_at_iso, started_monotonic, before_snapshot=None):
    exit_code = proc.wait()
    duration = round(time.time() - started_monotonic, 3)
    ended_at_iso = _now_iso()
    with _scan_lock:
        was_cancelled = bool(_scan_state.get("cancel_requested"))
        status = "cancelled" if was_cancelled else ("succeeded" if exit_code == 0 else "failed")
        _scan_state["status"] = status
        _scan_state["ended_at"] = ended_at_iso
        _scan_state["duration_seconds"] = duration
        _scan_state["exit_code"] = exit_code
        if was_cancelled:
            _scan_state["last_error"] = "Stopped by user request."
        elif exit_code != 0:
            _scan_state["last_error"] = f"scan_single_workspace.ps1 exited with code {exit_code}. See the log for details."
        _write_scan_state()
    diff = None
    if before_snapshot is not None:
        # A cancelled/failed run may still have gotten partway through --
        # whatever it did write to items.csv before dying is real signal
        # worth surfacing, so the diff is computed regardless of status.
        after_snapshot = _snapshot_items_for_scope([workspace])
        diff = _diff_items(before_snapshot, after_snapshot)
        diff["diff_path"] = _persist_diff(diff, workspace, started_at_iso)
        _append_item_history_rows(diff, workspace, started_at_iso)
    _append_history_row(workspace, started_at_iso, ended_at_iso, duration, status, diff=diff)
    _, _, failed_step, failed_error = _step_detail_from_progress(workspace)
    _send_scan_notification_emails(
        workspace, started_at_iso, ended_at_iso, status, diff,
        _scan_state.get("started_by_email"), failed_step, failed_error or _scan_state.get("last_error") or "",
    )
    if status == "succeeded":
        _maybe_trigger_warehouse_upload()
        # scan_single_workspace.ps1's own local rebuild
        # steps (11/17/21/build_graph_map_index.ps1, right after the Fabric
        # discovery steps) DO refresh all 5 of the big JSON files this
        # publishes -- same as a full scan, just scoped to whatever CSV rows
        # this workspace's discovery steps touched. Safe/correct to trigger
        # here on the same terms as _maybe_trigger_warehouse_upload above.
        _maybe_trigger_onelake_publish()
    _dequeue_and_start_next()


def _build_scan_subprocess_env(session, is_admin_scan=False):
    """A signed-in user's own delegated tokens, handed to the scan process
    as env vars (see FABRIC_LINEAGE_USER_TOKEN / FABRIC_LINEAGE_USER_SQL_
    TOKEN checks added to Get-AzureCliToken/Get-DatabaseAccessToken across
    the scan scripts) -- so that user's OWN Fabric permissions govern what
    the scan can see, instead of the shared `az` CLI session. Returns a
    plain copy of the current environment, unmodified, when there is no
    session (or extra-scope acquisition fails for any reason) -- the
    scripts already fall back to the shared `az` session in that case,
    exactly like before per-user auth existed.

    is_admin_scan (only meaningful for a full scan -- _start_scan never
    passes it) tells the child scripts whether this run's workspace
    discovery is AUTHORITATIVE (a real Fabric tenant admin, freshly
    reverified at scan-start, not just cached from sign-in) -- see
    FABRIC_LINEAGE_USER_IS_ADMIN in 01_discover_workspaces.ps1/16_discover_
    deployment_pipelines.ps1. An authoritative run does a full replace
    (something missing really is gone); a non-admin user's narrower,
    genuinely-partial view must not be allowed to either overwrite broader
    existing data (destroys real coverage) or silently retain-forever
    whatever it can't see (masks real deletions) -- so those scripts skip
    writing entirely when neither the shared `az` session nor a verified
    admin is behind the run. Without that guard, an admin's scan could
    silently reduce deployment pipeline data to a couple of rows via the
    regular (non-admin) per-identity endpoint."""
    env = dict(os.environ)
    if not session:
        return env
    settings = _load_admin_settings()
    fabric_token = _acquire_scoped_token(session, settings, FABRIC_TOKEN_SCOPES)
    if fabric_token:
        env["FABRIC_LINEAGE_USER_TOKEN"] = fabric_token
    if is_admin_scan:
        env["FABRIC_LINEAGE_USER_IS_ADMIN"] = "true"
    sql_token = _acquire_scoped_token(session, settings, ["https://database.windows.net/.default"])
    if sql_token:
        env["FABRIC_LINEAGE_USER_SQL_TOKEN"] = sql_token
    return env


def _release_claimed_slot_after_spawn_failure(scope_label, exc):
    """The claim below marks _scan_state running BEFORE attempting to spawn
    the subprocess, closing the race window a second concurrent request
    could otherwise slip through -- but that means a spawn failure right
    after (log file couldn't be opened, pwsh vanished between the resolve
    check and now) has to explicitly release the claim itself, or the slot
    stays stuck at "running" forever with no process and no thread ever
    watching it to notice."""
    now = _now_iso()
    with _scan_lock:
        _scan_state["status"] = "failed"
        _scan_state["ended_at"] = now
        _scan_state["duration_seconds"] = 0
        _scan_state["last_error"] = f"spawn_failed: {exc}"
        _write_scan_state()
    _append_history_row(scope_label, now, now, 0, "failed")
    _dequeue_and_start_next()


def _start_scan(workspace_name, session=None, api_key_name=None):
    # A signed-in user brings their own delegated token (set as an env var
    # below). A valid API key (a Fabric pipeline or other
    # automation caller) has already proven a real secret credential, which
    # is a fundamentally different trust level than a truly anonymous,
    # credential-less request -- so it goes straight to the shared `az` CLI
    # session below, the same path allow_anonymous_scans opts a browser
    # into, without needing that separate opt-in. With neither a session
    # nor a key, this only proceeds at all if an admin has explicitly
    # opted back into the shared `az` CLI session via allow_anonymous_scans
    # -- default off, so a scan always has a real identity attached to it
    # going forward.
    if not session:
        if not api_key_name:
            settings = _load_admin_settings()
            if not settings.get("allow_anonymous_scans"):
                return None, {
                    "error": "sign_in_required",
                    "message": "Sign in with your Microsoft account (or call with a valid X-Api-Key) to start a scan. An admin can re-enable anonymous scanning from the admin panel if needed.",
                }
        # Pipeline mode doesn't touch the shared `az` CLI session at all (see
        # _start_scan_via_fabric_pipeline below) -- checking it unconditionally
        # here used to fail every API-key/MCP-triggered scan with
        # az_session_invalid on a deploy that has no az/pwsh installed at all
        # (e.g. the Render image), even though pipeline mode never needed it.
        if not fabric_pipeline.is_fabric_pipeline_mode():
            ok, message = _check_az_session()
            if not ok:
                return None, {"error": "az_session_invalid", "message": message}

    workspaces = _read_workspaces()
    if workspaces is None:
        return None, {"error": "workspace_index_missing", "message": "index/workspaces.csv does not exist. Run backend/scripts/01_discover_workspaces.ps1 first."}
    if not any(row["workspace_name"] == workspace_name for row in workspaces):
        return None, {"error": "workspace_not_found", "message": f"Workspace '{workspace_name}' does not exist in index/workspaces.csv."}

    if fabric_pipeline.is_fabric_pipeline_mode():
        return _start_scan_via_fabric_pipeline(workspace_name, session, api_key_name)

    pwsh_path = _resolve_pwsh_command()
    if not pwsh_path:
        return None, {"error": "spawn_failed", "message": "PowerShell ('pwsh') was not found on PATH."}

    with _scan_lock:
        if _scan_state.get("status") == "running":
            if len(_scan_queue) >= MAX_QUEUED_SCANS:
                return None, {
                    "error": "queue_full",
                    "message": f"The scan queue is full ({MAX_QUEUED_SCANS} requests already waiting). Try again once earlier ones finish.",
                }
            entry, position = _enqueue_locked("scan", workspace_name, session, api_key_name)
            _write_scan_queue()
            return {
                "status": "queued", "queue_id": entry["queue_id"], "workspace": workspace_name,
                "position": position, "queued_at": entry["requested_at"],
            }, None
        # Claim the slot immediately, before doing any of the slower work
        # below (spawning the subprocess) -- closes the race window where a
        # second concurrent request could also see "not running" here and
        # start a second scan in parallel. pid/scan_id/started_at/log_path
        # are filled in properly once the subprocess actually exists, once
        # this same block runs again a few lines down.
        _scan_state["status"] = "running"
        _scan_state["workspace"] = workspace_name
        _scan_state["pid"] = None
        _scan_state["started_by_email"] = session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else None)
        _scan_state["is_tenant_admin_scan"] = False
        _scan_state["workspace_count"] = None
        _write_scan_state()

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    log_path = LOG_DIR / f"{timestamp}_{_slugify(workspace_name)}.log"

    # Taken right before the scan process spawns, so the diff computed once
    # it ends reflects only what THIS run changed in this workspace.
    before_snapshot = _snapshot_items_for_scope([workspace_name])

    started_at = _now_iso()
    try:
        log_handle = open(log_path, "w", encoding="utf-8")
        proc = subprocess.Popen(
            [pwsh_path, "-NoLogo", "-File", str(SCAN_SCRIPT_PATH), "-WorkspaceName", workspace_name],
            cwd=str(REPO_ROOT),
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            env=_build_scan_subprocess_env(session),
        )
    except OSError as exc:
        _release_claimed_slot_after_spawn_failure(workspace_name, exc)
        return None, {"error": "spawn_failed", "message": str(exc)}

    with _scan_lock:
        _scan_state["status"] = "running"
        _scan_state["workspace"] = workspace_name
        _scan_state["pid"] = proc.pid
        _scan_state["scan_id"] = started_at
        _scan_state["started_at"] = started_at
        _scan_state["ended_at"] = None
        _scan_state["duration_seconds"] = None
        _scan_state["exit_code"] = None
        _scan_state["log_path"] = _relative_to_repo(log_path)
        _scan_state["last_error"] = None
        _scan_state["cancel_requested"] = False
        _scan_state["started_by_email"] = session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else None)
        _scan_state["is_tenant_admin_scan"] = False
        _scan_state["workspace_count"] = None
        _write_scan_state()

    threading.Thread(target=_wait_for_process, args=(proc, workspace_name, started_at, time.time(), before_snapshot), daemon=True).start()

    return {"status": "started", "scan_id": started_at, "workspace": workspace_name, "started_at": started_at, "log_path": _relative_to_repo(log_path)}, None


def _step_detail_from_progress(workspace_label):
    # The running scan script writes its full step list into progress.json
    # after every step (see Write-ScanProgress in scan_single_workspace.ps1
    # / 99_refresh_lineage_project.ps1), so this is available even when the
    # process was force-killed mid-step and never reached its own
    # completion code -- which is exactly the case (a stop request) this
    # exists to cover.
    progress = _read_progress()
    if not progress or progress.get("workspace") != workspace_label:
        return 0, 0, "", ""
    steps = progress.get("steps") or []
    degraded = sum(1 for step in steps if step.get("status") == "degraded")
    failed = next((step for step in steps if step.get("status") == "failed"), None)
    return len(steps), degraded, (failed.get("name") if failed else ""), (failed.get("error") if failed else "")


def _snapshot_items_for_scope(scope_names):
    """A qualified_name -> tracked-fields snapshot of index/items.csv,
    restricted to scope_names (the workspace(s) a scan is about to touch),
    or every item when scope_names is None (an anonymous full scan, which
    always covers the whole tenant). Taken right before a scan starts and
    again right after it ends so _diff_items can tell what that one scan
    actually changed -- without this, a full items.csv reload would only
    ever show the tenant's current state, never what moved."""
    import csv

    if not ITEMS_INDEX_PATH.exists():
        return {}
    scope_set = set(scope_names) if scope_names is not None else None
    snapshot = {}
    with open(ITEMS_INDEX_PATH, "r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            if scope_set is not None and row.get("workspace_name") not in scope_set:
                continue
            qualified_name = row.get("qualified_name")
            if not qualified_name:
                continue
            snapshot[qualified_name] = {field: row.get(field, "") for field in
                                         ("item_type", "item_name", "workspace_name", *DIFF_TRACKED_FIELDS)}
    return snapshot


def _snapshot_items_for_scope_warehouse(scope_names):
    """Same contract/return shape as _snapshot_items_for_scope(), sourced
    from dbo.bronze_items (live Warehouse) instead of the local items.csv
    -- the counterpart needed for a Fabric-pipeline-triggered scan, whose
    items never touch this machine's disk at all (see
    _wait_for_fabric_pipeline_job's own docstring). Returns {} (same as
    the local version on a missing file) on any Warehouse error, so a
    scan's own success is never blocked by history-tracking being
    unavailable."""
    if not warehouse.is_warehouse_read_enabled():
        return {}
    try:
        rows = warehouse.query_bronze_table("bronze_items", use_cache=False)
    except warehouse.WarehouseError as exc:
        print(f"[scan_manager] Could not snapshot bronze_items for history tracking: {exc}", file=sys.stderr)
        return {}
    scope_set = set(scope_names) if scope_names is not None else None
    snapshot = {}
    for row in rows:
        if scope_set is not None and row.get("workspace_name") not in scope_set:
            continue
        qualified_name = row.get("qualified_name")
        if not qualified_name:
            continue
        snapshot[qualified_name] = {field: row.get(field, "") for field in
                                     ("item_type", "item_name", "workspace_name", *DIFF_TRACKED_FIELDS)}
    return snapshot


def _diff_items(before, after, sample_limit=40):
    """Compares two _snapshot_items_for_scope() results and buckets the
    difference by item_type, the same breakdown requested for the scan log
    ("every item modified in that scan, counted by
    type"). Only a bounded sample of each bucket's qualified names is kept
    here (the rest is still counted) -- the full snapshot dicts themselves
    are not retained anywhere past this call, only this summary."""
    from collections import defaultdict

    added_names = sorted(set(after) - set(before))
    removed_names = sorted(set(before) - set(after))
    modified_names = sorted(
        name for name in (set(before) & set(after))
        if any(before[name].get(field) != after[name].get(field) for field in DIFF_TRACKED_FIELDS)
    )

    by_type = defaultdict(lambda: {"added": 0, "removed": 0, "modified": 0})
    for name in added_names:
        by_type[after[name]["item_type"] or "Unknown"]["added"] += 1
    for name in removed_names:
        by_type[before[name]["item_type"] or "Unknown"]["removed"] += 1
    for name in modified_names:
        by_type[after[name]["item_type"] or "Unknown"]["modified"] += 1

    def rows_for(names, source):
        return [
            {
                "qualified_name": name,
                "item_type": source[name]["item_type"],
                "item_name": source[name]["item_name"],
                "workspace_name": source[name]["workspace_name"],
            }
            for name in names
        ]

    added_rows = rows_for(added_names, after)
    removed_rows = rows_for(removed_names, before)
    modified_rows = rows_for(modified_names, after)

    return {
        "added_count": len(added_names),
        "removed_count": len(removed_names),
        "modified_count": len(modified_names),
        "by_type": {item_type: counts for item_type, counts in by_type.items() if any(counts.values())},
        "added_sample": added_rows[:sample_limit],
        "removed_sample": removed_rows[:sample_limit],
        "modified_sample": modified_rows[:sample_limit],
        # Untruncated versions of the same rows -- only consumed by
        # _append_item_history_rows() below, kept out of the notification
        # email/UI path which only ever reads the *_sample keys above.
        "added_rows": added_rows,
        "removed_rows": removed_rows,
        "modified_rows": modified_rows,
    }


def _dependency_workspace_name(qualified_name):
    # Same "Workspace / Type / Name" convention every qualified_name in
    # this project already follows -- just the first segment.
    return (qualified_name or "").split(" / ", 1)[0]


def _snapshot_dependencies_for_scope_warehouse(scope_names):
    """Same contract as _snapshot_items_for_scope_warehouse, one level
    down the graph (a point-in-time dependency history) -- a "dependency" here is one EDGE (from_qualified_
    name -> to_qualified_name, for a given relationship_type), not a node,
    so the dict key is a 3-tuple instead of a single qualified_name.
    bronze_dependencies has no workspace_name column of its own (an edge
    can span two different workspaces), so scoping checks whether EITHER
    endpoint's own qualified_name starts with a workspace in scope_names."""
    if not warehouse.is_warehouse_read_enabled():
        return {}
    try:
        rows = warehouse.query_bronze_table("bronze_dependencies", use_cache=False)
    except warehouse.WarehouseError as exc:
        print(f"[scan_manager] Could not snapshot bronze_dependencies for history tracking: {exc}", file=sys.stderr)
        return {}
    scope_set = set(scope_names) if scope_names is not None else None
    snapshot = {}
    for row in rows:
        from_qn = row.get("from_qualified_name", "")
        to_qn = row.get("to_qualified_name", "")
        if not from_qn or not to_qn:
            continue
        if scope_set is not None and _dependency_workspace_name(from_qn) not in scope_set and _dependency_workspace_name(to_qn) not in scope_set:
            continue
        relationship_type = row.get("relationship_type", "")
        key = (from_qn, to_qn, relationship_type)
        snapshot[key] = {
            "from_qualified_name": from_qn, "to_qualified_name": to_qn, "relationship_type": relationship_type,
            **{field: row.get(field, "") for field in DEPENDENCY_DIFF_TRACKED_FIELDS},
        }
    return snapshot


def _diff_dependencies(before, after, sample_limit=40):
    """Same mechanics as _diff_items, one level down: "added"/"removed" is
    keyed on the (from, to, relationship_type) edge identity itself, so a
    relationship_type change on the same from/to pair shows up as one
    edge removed + a different one added (a real topology change), not a
    "modified" -- "modified" here only ever means the same edge with a
    different confidence/evidence value."""
    added_keys = sorted(set(after) - set(before))
    removed_keys = sorted(set(before) - set(after))
    modified_keys = sorted(
        key for key in (set(before) & set(after))
        if any(before[key].get(field) != after[key].get(field) for field in DEPENDENCY_DIFF_TRACKED_FIELDS)
    )

    def rows_for(keys, source):
        return [
            {
                "from_qualified_name": source[key]["from_qualified_name"],
                "to_qualified_name": source[key]["to_qualified_name"],
                "relationship_type": source[key]["relationship_type"],
            }
            for key in keys
        ]

    added_rows = rows_for(added_keys, after)
    removed_rows = rows_for(removed_keys, before)
    modified_rows = rows_for(modified_keys, after)

    return {
        "added_count": len(added_keys),
        "removed_count": len(removed_keys),
        "modified_count": len(modified_keys),
        "added_sample": added_rows[:sample_limit],
        "removed_sample": removed_rows[:sample_limit],
        "modified_sample": modified_rows[:sample_limit],
        "added_rows": added_rows,
        "removed_rows": removed_rows,
        "modified_rows": modified_rows,
    }


def _persist_diff(diff, scope_label, started_at_iso):
    """Writes the full diff (including the per-bucket samples, which
    history.csv itself does not carry) to its own JSON file and returns a
    repo-relative path -- history.csv keeps just the headline counts and
    per-type breakdown inline (see _append_history_row) so the log table
    doesn't need a second fetch to show "3 added, 1 removed"."""
    DIFF_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    diff_path = DIFF_DIR / f"{timestamp}_{_slugify(scope_label)}.json"
    with open(diff_path, "w", encoding="utf-8") as handle:
        json.dump(diff, handle, indent=2)
    return _relative_to_repo(diff_path)


def _migrate_item_history_schema_if_needed():
    """One-time upgrade for an item_history.csv written before
    triggered_by_email existed -- same reasoning/shape as
    _migrate_history_schema_if_needed below, for the OTHER history file:
    rewrites the header and pads every existing row with an empty value
    for the new column, so old and new rows share one consistent column
    count."""
    import csv

    with open(ITEM_HISTORY_PATH, "r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.reader(handle)
        rows = list(reader)
    if not rows or rows[0] == list(ITEM_HISTORY_FIELDS):
        return
    migrated_rows = [list(ITEM_HISTORY_FIELDS)]
    for row in rows[1:]:
        padded = row + [""] * (len(ITEM_HISTORY_FIELDS) - len(row))
        migrated_rows.append(padded[: len(ITEM_HISTORY_FIELDS)])
    with open(ITEM_HISTORY_PATH, "w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, quoting=csv.QUOTE_ALL)
        writer.writerows(migrated_rows)


def _append_item_history_rows(diff, scope_label, started_at_iso):
    """Appends one row per added/removed/modified item from this scan's diff
    to ITEM_HISTORY_PATH, which is never truncated or overwritten -- the
    permanent local record described in ITEM_HISTORY_PATH's comment above.
    A no-op when nothing changed, so a quiet scan doesn't pad the file."""
    import csv

    changes = (
        ("added", diff.get("added_rows") or []),
        ("removed", diff.get("removed_rows") or []),
        ("modified", diff.get("modified_rows") or []),
    )
    if not any(rows for _, rows in changes):
        return

    event_date = (started_at_iso or _now_iso())[:10]
    # Same read _append_history_row does a few lines below its own call
    # site -- "who started the scan this diff came from", None/anonymous
    # for a session-less trigger (so the Changes tab can show it too).
    triggered_by_email = _scan_state.get("started_by_email") or ""
    csv_rows = [
        [
            event_date, event_type, row["qualified_name"], row["item_type"],
            row["item_name"], row["workspace_name"], scope_label, started_at_iso, triggered_by_email,
        ]
        for event_type, rows in changes
        for row in rows
    ]

    ITEM_HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    is_new = not ITEM_HISTORY_PATH.exists()
    if not is_new:
        _migrate_item_history_schema_if_needed()
    with open(ITEM_HISTORY_PATH, "a", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, quoting=csv.QUOTE_ALL)
        if is_new:
            writer.writerow(ITEM_HISTORY_FIELDS)
        writer.writerows(csv_rows)


_ITEM_HISTORY_TABLE_DDL = (
    "CREATE TABLE dbo.bronze_item_history ("
    "event_date VARCHAR(20), event_type VARCHAR(20), qualified_name VARCHAR(1000), "
    "item_type VARCHAR(100), item_name VARCHAR(400), workspace_name VARCHAR(400), "
    "scope_label VARCHAR(400), scan_started_at VARCHAR(50), triggered_by_email VARCHAR(320))"
)


def _append_item_history_rows_warehouse(diff, scope_label, started_at_iso):
    """Same trigger/shape as _append_item_history_rows(), for a Fabric-
    pipeline-triggered scan: writes to dbo.bronze_item_history (append-
    only, see warehouse.append_bronze_rows) instead of the local CSV, so
    the "Cambios" admin tab has something to show regardless of which
    machine is running this server. Best-effort -- a Warehouse write
    failure here must never fail the scan itself, it's already succeeded
    by the time this runs."""
    changes = (
        ("added", diff.get("added_rows") or []),
        ("removed", diff.get("removed_rows") or []),
        ("modified", diff.get("modified_rows") or []),
    )
    if not any(rows for _, rows in changes):
        return
    if not warehouse.is_warehouse_read_enabled():
        return

    event_date = (started_at_iso or _now_iso())[:10]
    triggered_by_email = _scan_state.get("started_by_email") or ""
    rows = [
        {
            "event_date": event_date, "event_type": event_type, "qualified_name": row["qualified_name"],
            "item_type": row["item_type"], "item_name": row["item_name"], "workspace_name": row["workspace_name"],
            "scope_label": scope_label, "scan_started_at": started_at_iso, "triggered_by_email": triggered_by_email,
        }
        for event_type, rows in changes
        for row in rows
    ]
    try:
        # triggered_by_email is new -- ALTER the column in for a
        # table that already existed before it did, a no-op otherwise (see
        # ensure_bronze_column's own docstring).
        warehouse.ensure_bronze_column("bronze_item_history", "triggered_by_email", "VARCHAR(320)")
        warehouse.append_bronze_rows("bronze_item_history", list(ITEM_HISTORY_FIELDS), rows, create_table_ddl=_ITEM_HISTORY_TABLE_DDL)
    except warehouse.WarehouseError as exc:
        print(f"[scan_manager] Could not append item-history rows to the Warehouse: {exc}", file=sys.stderr)


_DEPENDENCY_HISTORY_TABLE_DDL = (
    "CREATE TABLE dbo.bronze_dependency_history ("
    "event_date VARCHAR(20), event_type VARCHAR(20), from_qualified_name VARCHAR(1000), "
    "to_qualified_name VARCHAR(1000), relationship_type VARCHAR(100), "
    "scope_label VARCHAR(400), scan_started_at VARCHAR(50))"
)


def _append_dependency_history_rows_warehouse(diff, scope_label, started_at_iso):
    """Same trigger/shape as _append_item_history_rows_warehouse, one
    level down the graph -- writes to dbo.bronze_dependency_history
    instead of dbo.bronze_item_history.
    Best-effort, same reasoning: a Warehouse write failure here must
    never fail the scan itself."""
    changes = (
        ("added", diff.get("added_rows") or []),
        ("removed", diff.get("removed_rows") or []),
        ("modified", diff.get("modified_rows") or []),
    )
    if not any(rows for _, rows in changes):
        return
    if not warehouse.is_warehouse_read_enabled():
        return

    event_date = (started_at_iso or _now_iso())[:10]
    rows = [
        {
            "event_date": event_date, "event_type": event_type,
            "from_qualified_name": row["from_qualified_name"], "to_qualified_name": row["to_qualified_name"],
            "relationship_type": row["relationship_type"], "scope_label": scope_label, "scan_started_at": started_at_iso,
        }
        for event_type, rows in changes
        for row in rows
    ]
    try:
        warehouse.append_bronze_rows("bronze_dependency_history", list(DEPENDENCY_HISTORY_FIELDS), rows, create_table_ddl=_DEPENDENCY_HISTORY_TABLE_DDL)
    except warehouse.WarehouseError as exc:
        print(f"[scan_manager] Could not append dependency-history rows to the Warehouse: {exc}", file=sys.stderr)


def _diff_by_type_table_html(by_type, texts):
    if not by_type:
        return f"<p style=\"color:#647283;font-size:13px;margin:8px 0;\">{html.escape(texts['no_changes'])}</p>"
    rows = []
    for item_type in sorted(by_type.keys()):
        counts = by_type[item_type] or {}
        added, removed, modified = counts.get("added", 0), counts.get("removed", 0), counts.get("modified", 0)
        cell = "padding:6px 10px;border-bottom:1px solid #e2e8f0;"
        rows.append(
            f"<tr><td style=\"{cell}\">{html.escape(item_type)}</td>"
            f"<td style=\"{cell}color:#15803d;font-weight:700;\">{f'+{added}' if added else ''}</td>"
            f"<td style=\"{cell}color:#b91c1c;font-weight:700;\">{f'-{removed}' if removed else ''}</td>"
            f"<td style=\"{cell}color:#b45309;font-weight:700;\">{f'~{modified}' if modified else ''}</td></tr>"
        )
    head = "padding:6px 10px;border-bottom:2px solid #17202a;color:#647283;font-size:11px;text-transform:uppercase;text-align:left;"
    return (
        "<table style=\"border-collapse:collapse;width:100%;font-family:Segoe UI,Arial,sans-serif;font-size:13px;\">"
        f"<thead><tr><th style=\"{head}\">{html.escape(texts['type_col'])}</th>"
        f"<th style=\"{head}\">{html.escape(texts['added_col'])}</th>"
        f"<th style=\"{head}\">{html.escape(texts['removed_col'])}</th>"
        f"<th style=\"{head}\">{html.escape(texts['modified_col'])}</th></tr></thead>"
        f"<tbody>{''.join(rows)}</tbody></table>"
    )


def _build_notification_email(scope_label, started_at_iso, ended_at_iso, status, diff, triggered_by_email, failed_step, error_detail, language):
    texts = NOTIFICATION_TEXT.get(language) or NOTIFICATION_TEXT["es"]
    display_scope = texts["full_scan_label"] if scope_label == FULL_SCAN_LABEL else scope_label
    duration = _duration_seconds_between(started_at_iso, ended_at_iso)
    who = triggered_by_email or texts["anonymous"]
    subject = f"[Fabric Lineage Mapper] {texts['subject'].get(status, status)}: {display_scope}"
    by_type = (diff or {}).get("by_type") or {}

    error_row_html = ""
    error_row_text = ""
    if status != "succeeded" and (failed_step or error_detail):
        detail = " -- ".join(part for part in (failed_step, error_detail) if part)
        error_row_html = f"<p style=\"color:#b91c1c;font-size:13px;\"><strong>{html.escape(texts['error_label'])}:</strong> {html.escape(detail)}</p>"
        error_row_text = f"{texts['error_label']}: {detail}\n"

    html_body = f"""
    <div style="font-family:Segoe UI,Arial,sans-serif;color:#17202a;max-width:640px;">
      <h2 style="margin:0 0 12px;">{html.escape(texts['heading'].get(status, status))}</h2>
      <p style="font-size:13px;margin:4px 0;"><strong>{html.escape(texts['scope_label'])}:</strong> {html.escape(display_scope)}</p>
      <p style="font-size:13px;margin:4px 0;"><strong>{html.escape(texts['triggered_by_label'])}:</strong> {html.escape(who)}</p>
      <p style="font-size:13px;margin:4px 0 12px;"><strong>{html.escape(texts['duration_label'])}:</strong> {duration:.0f}s</p>
      {error_row_html}
      <h3 style="font-size:13px;text-transform:uppercase;color:#647283;margin:16px 0 6px;">{html.escape(texts['changes_heading'])}</h3>
      {_diff_by_type_table_html(by_type, texts)}
      <p style="font-size:11px;color:#94a3b8;margin-top:20px;">{html.escape(texts['footer'])}</p>
    </div>
    """
    type_lines = "\n".join(
        f"  {item_type}: +{c.get('added', 0)} -{c.get('removed', 0)} ~{c.get('modified', 0)}"
        for item_type, c in sorted(by_type.items())
    ) or f"  {texts['no_changes']}"
    text_body = (
        f"{texts['heading'].get(status, status)}\n\n"
        f"{texts['scope_label']}: {display_scope}\n"
        f"{texts['triggered_by_label']}: {who}\n"
        f"{texts['duration_label']}: {duration:.0f}s\n"
        f"{error_row_text}\n"
        f"{texts['changes_heading']}:\n{type_lines}\n\n"
        f"{texts['footer']}"
    )
    return subject, html_body, text_body


def _send_email(settings, to_email, subject, html_body, text_body):
    import smtplib
    from email.mime.multipart import MIMEMultipart
    from email.mime.text import MIMEText

    notif = settings.get("notifications") or {}
    host = (notif.get("smtp_host") or "").strip()
    if not host:
        return False, "SMTP is not configured in the admin panel yet."
    port = int(notif.get("smtp_port") or 587)
    use_tls = notif.get("smtp_use_tls", True)
    user = (notif.get("smtp_user") or "").strip()
    password_ref = (notif.get("smtp_password_ref") or "").strip()
    # See admin_settings._reserved_secret_env_var_name's own docstring --
    # without this, smtp_password_ref pointed at the SP secret's env var
    # would make this "send a test email" path exfiltrate it to whatever
    # smtp_host the same admin typed into the same form.
    reserved = _reserved_secret_env_var_name(settings)
    if password_ref and reserved and password_ref == reserved:
        return False, f"'{password_ref}' is reserved for the Warehouse service-principal secret and can't be used as an SMTP password reference."
    password = os.environ.get(password_ref, "") if password_ref else ""
    from_address = (notif.get("from_address") or user or "fabric-lineage-mapper@localhost").strip()

    message = MIMEMultipart("alternative")
    message["Subject"] = subject
    message["From"] = from_address
    message["To"] = to_email
    message.attach(MIMEText(text_body, "plain", "utf-8"))
    message.attach(MIMEText(html_body, "html", "utf-8"))

    try:
        with smtplib.SMTP(host, port, timeout=15) as server:
            if use_tls:
                server.starttls()
            if user:
                server.login(user, password)
            server.sendmail(from_address, [to_email], message.as_string())
        return True, ""
    except (OSError, smtplib.SMTPException) as exc:
        return False, str(exc)


def _build_teams_message(scope_label, started_at_iso, ended_at_iso, status, diff, triggered_by_email, failed_step, error_detail, language):
    """Same underlying facts as _build_notification_email, packaged as a
    Teams Adaptive Card instead of an email MIME message (a "Teams notifications"
    option -- reuses NOTIFICATION_TEXT/the
    diff shape rather than inventing a second copy of the same strings).
    The envelope ({"type": "message", "attachments": [...]}) is accepted
    by both a legacy Office 365 Connector webhook and the newer Power
    Automate workflow webhook Teams is migrating channels to."""
    texts = NOTIFICATION_TEXT.get(language) or NOTIFICATION_TEXT["es"]
    display_scope = texts["full_scan_label"] if scope_label == FULL_SCAN_LABEL else scope_label
    duration = _duration_seconds_between(started_at_iso, ended_at_iso)
    who = triggered_by_email or texts["anonymous"]
    status_color = {"succeeded": "Good", "failed": "Attention", "cancelled": "Warning"}.get(status, "Default")
    by_type = (diff or {}).get("by_type") or {}

    facts = [
        {"title": texts["scope_label"], "value": display_scope},
        {"title": texts["triggered_by_label"], "value": who},
        {"title": texts["duration_label"], "value": f"{duration:.0f}s"},
    ]
    if status != "succeeded" and (failed_step or error_detail):
        facts.append({"title": texts["error_label"], "value": " -- ".join(part for part in (failed_step, error_detail) if part)})

    change_lines = [
        f"**{item_type}**: +{counts.get('added', 0)} / -{counts.get('removed', 0)} / ~{counts.get('modified', 0)}"
        for item_type, counts in sorted(by_type.items())
    ]
    changes_text = "\n\n".join(change_lines) if change_lines else texts["no_changes"]

    body = [
        {"type": "TextBlock", "text": texts["heading"].get(status, status), "weight": "Bolder", "size": "Medium", "color": status_color, "wrap": True},
        {"type": "FactSet", "facts": facts},
        {"type": "TextBlock", "text": texts["changes_heading"], "weight": "Bolder", "size": "Small", "spacing": "Medium"},
        {"type": "TextBlock", "text": changes_text, "wrap": True, "isSubtle": True},
    ]
    return {
        "type": "message",
        "attachments": [{
            "contentType": "application/vnd.microsoft.card.adaptive",
            "content": {
                "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
                "type": "AdaptiveCard",
                "version": "1.4",
                "body": body,
            },
        }],
    }


_TEAMS_WEBHOOK_HOST_SUFFIXES = (".webhook.office.com", ".logic.azure.com", ".powerautomate.com", ".flow.microsoft.com")


def _is_valid_teams_webhook_url(url):
    """Restricts outbound Teams-notification requests to Microsoft's own
    webhook domains: teams_webhook_url is
    admin-configurable free text with no other constraint, so without this
    an admin could point "send a test notification" at ANY URL --
    including an internal/private address -- making this server an SSRF
    proxy. Covers both the legacy Office 365 Connector host
    (outlook.office.com/webhook/... and *.webhook.office.com) and the
    Power Automate workflow webhook Teams channels are migrating to
    (*.logic.azure.com, *.powerautomate.com, *.flow.microsoft.com) -- see
    _build_teams_message's own comment on why both are accepted."""
    try:
        parsed = urllib.parse.urlparse(url)
    except ValueError:
        return False
    if parsed.scheme != "https" or not parsed.hostname:
        return False
    host = parsed.hostname.lower()
    if host == "outlook.office.com":
        return True
    return any(host.endswith(suffix) for suffix in _TEAMS_WEBHOOK_HOST_SUFFIXES)


def _send_teams_notification(settings, message):
    # Same urllib.request pattern fabric_pipeline.py's _request() already
    # uses for outbound calls -- this project's web server deliberately
    # stays on the stdlib HTTP client rather than adding `requests` as a
    # dependency (see requirements-web.txt).
    notif = settings.get("notifications") or {}
    webhook_url = (notif.get("teams_webhook_url") or "").strip()
    if not webhook_url:
        return False, "No Teams webhook URL configured in the admin panel yet."
    if not _is_valid_teams_webhook_url(webhook_url):
        return False, "This doesn't look like a Microsoft Teams webhook URL (expected https://.../webhook.office.com/... or a Power Automate workflow URL) -- refusing to send a request to it."
    data = json.dumps(message).encode("utf-8")
    req = urllib.request.Request(webhook_url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            return response.status < 300, ""
    except urllib.error.HTTPError as exc:
        return False, f"HTTP {exc.code}: {exc.read().decode('utf-8', errors='replace')[:300]}"
    except urllib.error.URLError as exc:
        return False, str(exc.reason)


def _send_scan_notification_emails(scope_label, started_at_iso, ended_at_iso, status, diff, triggered_by_email, failed_step="", error_detail=""):
    """Fires from the same background thread that already waits on the scan
    subprocess (_wait_for_process / _wait_for_full_scan_process) -- adding a
    few seconds of SMTP/webhook latency there doesn't block the server or
    any other request, unlike doing this on a request-handling thread
    would. Silently a no-op with nothing configured (no SMTP host and no
    Teams webhook, or nobody subscribed to this status) -- notifications
    are opt-in, never a hard requirement for a scan to "finish" from the
    caller's point of view. Despite the name (kept as-is: renaming would
    touch every call site for no behavioral reason), this now also fires
    the Teams webhook, not just email -- both are just channels for the
    same underlying scan-finished event."""
    if status not in ("succeeded", "failed", "cancelled"):
        return
    settings = _load_admin_settings()
    notif = settings.get("notifications") or {}
    subscribers = notif.get("subscribers") or []
    status_flag = {"succeeded": "notify_succeeded", "failed": "notify_failed", "cancelled": "notify_cancelled"}[status]
    interested = [s for s in subscribers if s.get(status_flag) and s.get("email")]
    for subscriber in interested:
        language = subscriber.get("language") if subscriber.get("language") in NOTIFICATION_TEXT else "es"
        subject, html_body, text_body = _build_notification_email(
            scope_label, started_at_iso, ended_at_iso, status, diff, triggered_by_email, failed_step, error_detail, language
        )
        ok, error = _send_email(settings, subscriber["email"], subject, html_body, text_body)
        if not ok:
            print(f"[notifications] Could not email {subscriber['email']}: {error}", file=sys.stderr)

    teams_status_flag = {"succeeded": "teams_notify_succeeded", "failed": "teams_notify_failed", "cancelled": "teams_notify_cancelled"}[status]
    if notif.get("teams_webhook_url") and notif.get(teams_status_flag):
        language = notif.get("teams_language") if notif.get("teams_language") in NOTIFICATION_TEXT else "es"
        message = _build_teams_message(scope_label, started_at_iso, ended_at_iso, status, diff, triggered_by_email, failed_step, error_detail, language)
        ok, error = _send_teams_notification(settings, message)
        if not ok:
            print(f"[notifications] Could not post to Teams: {error}", file=sys.stderr)


def _append_history_row(workspace_name, started_at_iso, ended_at_iso, duration_seconds, status, diff=None):
    # The server is the sole writer of history.csv for BOTH scan kinds --
    # it is the only thing guaranteed to still be running (and able to
    # record what happened) no matter how the child pwsh process ends:
    # normal completion, a genuine failure, or force-killed mid-step by a
    # stop request, which never lets that process reach its own cleanup
    # code to record anything itself.
    import csv

    step_count, degraded_count, failed_step, failed_error = _step_detail_from_progress(workspace_name)
    # _scan_state still reflects the scan this row is closing out --
    # nothing overwrites started_by_email until the NEXT scan starts, so
    # reading it here (rather than threading it through every caller) is
    # safe for every call site (normal completion, failure, a stop
    # request, and startup recovery after an unclean server restart).
    triggered_by_email = _scan_state.get("started_by_email") or ""
    diff = diff or {}
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    is_new = not HISTORY_PATH.exists()
    if not is_new:
        _migrate_history_schema_if_needed()
    with open(HISTORY_PATH, "a", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, quoting=csv.QUOTE_ALL)
        if is_new:
            writer.writerow(HISTORY_FIELDS)
        writer.writerow([
            workspace_name, started_at_iso, ended_at_iso, f"{duration_seconds:.3f}", status,
            str(step_count), str(degraded_count), failed_step, failed_error, triggered_by_email,
            str(diff.get("added_count", "")), str(diff.get("removed_count", "")), str(diff.get("modified_count", "")),
            json.dumps(diff.get("by_type", {})) if diff.get("by_type") is not None else "",
            diff.get("diff_path", ""),
        ])


def _migrate_history_schema_if_needed():
    """One-time upgrade for a history.csv written before triggered_by_email
    existed: rewrites the header (and pads every existing row with an
    empty value for it) so old and new rows share one consistent column
    count, instead of silently producing a file where old rows have 9
    columns and new ones have 10."""
    import csv

    with open(HISTORY_PATH, "r", encoding="utf-8-sig", newline="") as handle:
        reader = csv.reader(handle)
        rows = list(reader)
    if not rows or rows[0] == HISTORY_FIELDS:
        return
    migrated_rows = [HISTORY_FIELDS]
    for row in rows[1:]:
        padded = row + [""] * (len(HISTORY_FIELDS) - len(row))
        migrated_rows.append(padded[: len(HISTORY_FIELDS)])
    with open(HISTORY_PATH, "w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, quoting=csv.QUOTE_ALL)
        writer.writerows(migrated_rows)


def _wait_for_full_scan_process(proc, started_at_iso, started_monotonic, before_snapshot=None, scope_names=None):
    exit_code = proc.wait()
    duration = round(time.time() - started_monotonic, 3)
    ended_at_iso = _now_iso()
    with _scan_lock:
        was_cancelled = bool(_scan_state.get("cancel_requested"))
        status = "cancelled" if was_cancelled else ("succeeded" if exit_code == 0 else "failed")
        _scan_state["status"] = status
        _scan_state["ended_at"] = ended_at_iso
        _scan_state["duration_seconds"] = duration
        _scan_state["exit_code"] = exit_code
        if was_cancelled:
            _scan_state["last_error"] = "Stopped by user request."
        elif exit_code != 0:
            _scan_state["last_error"] = f"99_refresh_lineage_project.ps1 exited with code {exit_code}. See the log for details."
        _write_scan_state()
    diff = None
    if before_snapshot is not None:
        after_snapshot = _snapshot_items_for_scope(scope_names)
        diff = _diff_items(before_snapshot, after_snapshot)
        diff["diff_path"] = _persist_diff(diff, FULL_SCAN_LABEL, started_at_iso)
        _append_item_history_rows(diff, FULL_SCAN_LABEL, started_at_iso)
    _append_history_row(FULL_SCAN_LABEL, started_at_iso, ended_at_iso, duration, status, diff=diff)
    _, _, failed_step, failed_error = _step_detail_from_progress(FULL_SCAN_LABEL)
    _send_scan_notification_emails(
        FULL_SCAN_LABEL, started_at_iso, ended_at_iso, status, diff,
        _scan_state.get("started_by_email"), failed_step, failed_error or _scan_state.get("last_error") or "",
    )
    if status == "succeeded":
        _maybe_trigger_warehouse_upload()
        # This and _wait_for_process (single-workspace scans) are the only
        # two paths that rebuild the big JSON files (99_refresh_lineage_
        # project.ps1 / scan_single_workspace.ps1 both run 11/17/21/build_
        # graph_map_index.ps1 as local rebuild steps). A
        # Fabric-pipeline-triggered scan (_wait_for_fabric_pipeline_job)
        # only populates Warehouse bronze tables, never these local JSON
        # files, so it never calls this -- see _maybe_trigger_onelake_
        # publish's own docstring.
        _maybe_trigger_onelake_publish()
    _dequeue_and_start_next()


def _start_full_scan(session=None, api_key_name=None):
    # A signed-in user's full scan is scoped to whatever workspaces THEY
    # personally can see in Fabric -- never the whole tenant on their
    # behalf. This is a hard requirement, not best-effort: if their own
    # accessible-workspace list can't be determined, refuse to start rather
    # than silently falling back to an unscoped scan (that would be the one
    # case where "no session = scan everything" logic could accidentally
    # let someone touch workspaces they were never granted access to). A
    # valid API key has no per-user Fabric identity to scope to (see
    # _start_scan's comment on why it skips straight to the shared `az`
    # session instead of requiring allow_anonymous_scans) -- it always
    # scans the whole tenant, same as the anonymous fallback below.
    #
    # EXCEPT: a signed-in user who genuinely holds the "Fabric
    # Administrator" Entra ID role (the project's own identity usually
    # does NOT) can call the admin-scoped
    # /v1/admin/workspaces endpoint, which lists literally every workspace
    # in the tenant regardless of per-workspace role -- so for that person,
    # "whatever they personally can see" already IS the whole tenant, no
    # exception to the rule above needed. _fetch_all_tenant_workspaces is
    # tried first; a 403 (everyone who isn't a tenant admin, i.e. almost
    # everyone) falls back silently to the existing _fetch_my_workspaces
    # path below, unchanged. Workspaces the admin still has no real role in
    # will individually come back "partial"/"workspace_items_unavailable"
    # in index/workspaces.csv|items.csv (already-existing per-workspace
    # soft-failure handling in 02_normalize_workspaces.ps1/03_discover_
    # items.ps1), not a crash of the whole run.
    workspace_filter_args = []
    scope_names = None  # None means "the whole tenant" (session-less paths below).
    is_tenant_admin_scan = False
    if session:
        # session["access_token"] is whatever was minted at sign-in, which
        # can easily be over an hour stale by the time someone actually
        # clicks "full scan" (e.g. a user signs in, comes back a couple of
        # hours later, and both discovery calls below fail
        # with workspace_discovery_failed because the raw token had expired
        # -- Entra access tokens are typically only good for ~60-90
        # minutes). _acquire_scoped_token silently mints a FRESH one from
        # the same session's MSAL refresh-token cache, the same way
        # _build_scan_subprocess_env already does for the scan subprocess
        # itself -- falls back to the original (possibly-stale) token only
        # if that refresh itself fails for some reason, rather than hard
        # erroring before even trying the discovery call.
        settings = _load_admin_settings()
        access_token = _acquire_scoped_token(session, settings, FABRIC_TOKEN_SCOPES) or session["access_token"]
        tenant_workspaces, tenant_error = _fetch_all_tenant_workspaces(access_token)
        if tenant_error is None:
            names = [item["workspace_name"] for item in tenant_workspaces if item.get("workspace_name")]
            is_tenant_admin_scan = True
        else:
            my_workspaces, error = _fetch_my_workspaces(access_token)
            if error:
                return None, {"error": "workspace_discovery_failed", "message": f"Could not determine which workspaces you have access to: {error}"}
            names = [item["workspace_name"] for item in my_workspaces if item.get("workspace_name")]
        if not names:
            return None, {"error": "no_accessible_workspaces", "message": "Your Microsoft account has no accessible Fabric workspaces to scan."}
        workspace_filter_args = ["-WorkspaceNameFilter", ";".join(names)]
        scope_names = names
    elif api_key_name:
        # See the matching comment in _start_scan: pipeline mode never
        # touches the shared `az` CLI session, so this must not require it
        # either.
        if not fabric_pipeline.is_fabric_pipeline_mode():
            ok, message = _check_az_session()
            if not ok:
                return None, {"error": "az_session_invalid", "message": message}
    else:
        settings = _load_admin_settings()
        if not settings.get("allow_anonymous_scans"):
            return None, {
                "error": "sign_in_required",
                "message": "Sign in with your Microsoft account (or call with a valid X-Api-Key) to start a full scan. An admin can re-enable anonymous scanning from the admin panel if needed.",
            }
        if not fabric_pipeline.is_fabric_pipeline_mode():
            ok, message = _check_az_session()
            if not ok:
                return None, {"error": "az_session_invalid", "message": message}

    if fabric_pipeline.is_fabric_pipeline_mode():
        workspace_name_filter = ";".join(scope_names) if scope_names is not None else ""
        return _start_full_scan_via_fabric_pipeline(workspace_name_filter, scope_names, is_tenant_admin_scan, session, api_key_name)

    pwsh_path = _resolve_pwsh_command()
    if not pwsh_path:
        return None, {"error": "spawn_failed", "message": "PowerShell ('pwsh') was not found on PATH."}

    with _scan_lock:
        if _scan_state.get("status") == "running":
            if len(_scan_queue) >= MAX_QUEUED_SCANS:
                return None, {
                    "error": "queue_full",
                    "message": f"The scan queue is full ({MAX_QUEUED_SCANS} requests already waiting). Try again once earlier ones finish.",
                }
            entry, position = _enqueue_locked("full_scan", None, session, api_key_name)
            _write_scan_queue()
            return {
                "status": "queued", "queue_id": entry["queue_id"], "workspace": FULL_SCAN_LABEL,
                "position": position, "queued_at": entry["requested_at"],
            }, None
        # Same immediate claim as _start_scan, before the slower spawn work
        # below -- see that function's comment for why.
        _scan_state["status"] = "running"
        _scan_state["workspace"] = FULL_SCAN_LABEL
        _scan_state["pid"] = None
        _scan_state["started_by_email"] = session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else None)
        _scan_state["is_tenant_admin_scan"] = is_tenant_admin_scan
        _scan_state["workspace_count"] = len(scope_names) if scope_names is not None else None
        _write_scan_state()

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    log_path = LOG_DIR / f"{timestamp}_full-scan.log"

    before_snapshot = _snapshot_items_for_scope(scope_names)

    started_at = _now_iso()
    try:
        log_handle = open(log_path, "w", encoding="utf-8")
        # -Mode full-read-only re-scans every workspace in the tenant
        # (several hours on a large tenant) instead of the local-artifacts-only
        # default -- or, for a signed-in user, only the workspaces
        # -WorkspaceNameFilter above scopes it to. -RunTmdlEnrichment is
        # included so a button labeled "full scan" actually resolves real
        # table/view-level detail out of every semantic model's TMDL
        # definition too, not just the coarser connection-level evidence
        # the base pass captures.
        proc = subprocess.Popen(
            [pwsh_path, "-NoLogo", "-File", str(FULL_SCAN_SCRIPT_PATH), "-Mode", "full-read-only", "-RunTmdlEnrichment"] + workspace_filter_args,
            cwd=str(REPO_ROOT),
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            env=_build_scan_subprocess_env(session, is_admin_scan=is_tenant_admin_scan),
        )
    except OSError as exc:
        _release_claimed_slot_after_spawn_failure(FULL_SCAN_LABEL, exc)
        return None, {"error": "spawn_failed", "message": str(exc)}

    with _scan_lock:
        _scan_state["status"] = "running"
        _scan_state["workspace"] = FULL_SCAN_LABEL
        _scan_state["pid"] = proc.pid
        _scan_state["scan_id"] = started_at
        _scan_state["started_at"] = started_at
        _scan_state["ended_at"] = None
        _scan_state["duration_seconds"] = None
        _scan_state["exit_code"] = None
        _scan_state["log_path"] = _relative_to_repo(log_path)
        _scan_state["last_error"] = None
        _scan_state["cancel_requested"] = False
        _scan_state["started_by_email"] = session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else None)
        _scan_state["is_tenant_admin_scan"] = is_tenant_admin_scan
        _scan_state["workspace_count"] = len(scope_names) if scope_names is not None else None
        _write_scan_state()

    threading.Thread(target=_wait_for_full_scan_process, args=(proc, started_at, time.time(), before_snapshot, scope_names), daemon=True).start()

    return {
        "status": "started", "scan_id": started_at, "workspace": FULL_SCAN_LABEL, "started_at": started_at,
        "log_path": _relative_to_repo(log_path), "is_tenant_admin_scan": is_tenant_admin_scan, "workspace_count": len(scope_names),
    }, None


def _wait_for_executions_scan_process(proc, started_at_iso, started_monotonic):
    # No item snapshot/diff here (unlike _wait_for_process/_wait_for_full_
    # scan_process): this scan never touches items.csv, only
    # index/executions.csv and the analysis/execution_* summaries -- an
    # item-level added/removed/modified diff would always read as empty and
    # add nothing but noise to history.csv.
    exit_code = proc.wait()
    duration = round(time.time() - started_monotonic, 3)
    ended_at_iso = _now_iso()
    with _scan_lock:
        was_cancelled = bool(_scan_state.get("cancel_requested"))
        status = "cancelled" if was_cancelled else ("succeeded" if exit_code == 0 else "failed")
        _scan_state["status"] = status
        _scan_state["ended_at"] = ended_at_iso
        _scan_state["duration_seconds"] = duration
        _scan_state["exit_code"] = exit_code
        if was_cancelled:
            _scan_state["last_error"] = "Stopped by user request."
        elif exit_code != 0:
            _scan_state["last_error"] = f"71_scan_production_executions.ps1 exited with code {exit_code}. See the log for details."
        _write_scan_state()
    _append_history_row(EXECUTIONS_SCAN_LABEL, started_at_iso, ended_at_iso, duration, status)
    _dequeue_and_start_next()


def _start_executions_scan(session=None, api_key_name=None):
    """Production-only execution/schedule refresh (pipeline phase 6 alone, via
    71_scan_production_executions.ps1) -- the narrow, faster counterpart to
    a full scan when only duration/schedule/run-history data is needed.
    Unlike _start_scan/_start_full_scan, the workspace scope here is not
    per-caller: the script itself resolves "production" from the local
    index (every workspace without a [DEV]/[QA]/[UAT]/[PRE] suffix -- see
    that script's own header comment for why this is broader than
    isProductionWorkspace() in app.js), so this always runs against the
    same shared `az` CLI session, the same trust bar as a full scan
    (full_scan_emails allowlist for a signed-in caller, since it touches
    tenant-wide production data same as a full scan does)."""
    if not session:
        if not api_key_name:
            settings = _load_admin_settings()
            if not settings.get("allow_anonymous_scans"):
                return None, {
                    "error": "sign_in_required",
                    "message": "Sign in with your Microsoft account (or call with a valid X-Api-Key) to start a production executions scan. An admin can re-enable anonymous scanning from the admin panel if needed.",
                }
    else:
        settings = _load_admin_settings()
        if not _email_in_allowlist(session["user_email"], settings, "full_scan_emails"):
            return None, {"error": "not_permitted", "message": "This account is not allowed to trigger a production executions scan."}

    ok, message = _check_az_session()
    if not ok:
        return None, {"error": "az_session_invalid", "message": message}

    pwsh_path = _resolve_pwsh_command()
    if not pwsh_path:
        return None, {"error": "spawn_failed", "message": "PowerShell ('pwsh') was not found on PATH."}

    with _scan_lock:
        if _scan_state.get("status") == "running":
            if len(_scan_queue) >= MAX_QUEUED_SCANS:
                return None, {
                    "error": "queue_full",
                    "message": f"The scan queue is full ({MAX_QUEUED_SCANS} requests already waiting). Try again once earlier ones finish.",
                }
            entry, position = _enqueue_locked("executions_scan", None, session, api_key_name)
            _write_scan_queue()
            return {
                "status": "queued", "queue_id": entry["queue_id"], "workspace": EXECUTIONS_SCAN_LABEL,
                "position": position, "queued_at": entry["requested_at"],
            }, None
        _scan_state["status"] = "running"
        _scan_state["workspace"] = EXECUTIONS_SCAN_LABEL
        _scan_state["pid"] = None
        _scan_state["started_by_email"] = session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else None)
        _scan_state["is_tenant_admin_scan"] = False
        _scan_state["workspace_count"] = None
        _write_scan_state()

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    log_path = LOG_DIR / f"{timestamp}_production-executions.log"

    started_at = _now_iso()
    try:
        log_handle = open(log_path, "w", encoding="utf-8")
        proc = subprocess.Popen(
            [pwsh_path, "-NoLogo", "-File", str(EXECUTIONS_SCAN_SCRIPT_PATH)],
            cwd=str(REPO_ROOT),
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            env=_build_scan_subprocess_env(session),
        )
    except OSError as exc:
        _release_claimed_slot_after_spawn_failure(EXECUTIONS_SCAN_LABEL, exc)
        return None, {"error": "spawn_failed", "message": str(exc)}

    with _scan_lock:
        _scan_state["status"] = "running"
        _scan_state["workspace"] = EXECUTIONS_SCAN_LABEL
        _scan_state["pid"] = proc.pid
        _scan_state["scan_id"] = started_at
        _scan_state["started_at"] = started_at
        _scan_state["ended_at"] = None
        _scan_state["duration_seconds"] = None
        _scan_state["exit_code"] = None
        _scan_state["log_path"] = _relative_to_repo(log_path)
        _scan_state["last_error"] = None
        _scan_state["cancel_requested"] = False
        _scan_state["started_by_email"] = session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else None)
        _scan_state["is_tenant_admin_scan"] = False
        _scan_state["workspace_count"] = None
        _write_scan_state()

    threading.Thread(target=_wait_for_executions_scan_process, args=(proc, started_at, time.time()), daemon=True).start()

    return {"status": "started", "scan_id": started_at, "workspace": EXECUTIONS_SCAN_LABEL, "started_at": started_at, "log_path": _relative_to_repo(log_path)}, None


def _wait_for_warehouse_upload_process(proc, started_at_iso, started_monotonic):
    # No item snapshot/diff here either (same reasoning as the executions
    # scan) -- this never touches items.csv, it only reads already-scanned
    # local CSVs and pushes them to the configured Warehouse.
    exit_code = proc.wait()
    duration = round(time.time() - started_monotonic, 3)
    ended_at_iso = _now_iso()
    with _scan_lock:
        was_cancelled = bool(_scan_state.get("cancel_requested"))
        status = "cancelled" if was_cancelled else ("succeeded" if exit_code == 0 else "failed")
        _scan_state["status"] = status
        _scan_state["ended_at"] = ended_at_iso
        _scan_state["duration_seconds"] = duration
        _scan_state["exit_code"] = exit_code
        if was_cancelled:
            _scan_state["last_error"] = "Stopped by user request."
        elif exit_code != 0:
            _scan_state["last_error"] = f"67_upload_bronze_to_warehouse.ps1 exited with code {exit_code}. See the log for details."
        _write_scan_state()
    _append_history_row(WAREHOUSE_UPLOAD_LABEL, started_at_iso, ended_at_iso, duration, status)
    _dequeue_and_start_next()


def _start_warehouse_upload(session=None, api_key_name=None, system_triggered=False):
    """Pushes every already-scanned local CSV straight into the write-target
    Warehouse configured on the admin panel's write-target tab (see
    67_upload_bronze_to_warehouse.ps1) -- reads only, no new Fabric REST
    scanning happens here, so the workspace scope is whatever's already on
    disk, not per-caller. Same trust bar as a full scan (full_scan_emails
    allowlist for a signed-in caller): the destination Warehouse can contain
    tenant-wide metadata, same reasoning as _start_executions_scan.

    system_triggered (see _maybe_trigger_warehouse_upload) skips that
    caller-identity check entirely: it's not a substitute credential, it
    marks that there IS no caller here at all -- the server queued this
    itself right after a scan it already authorized finished, gated on the
    admin's own opt-in (auto_upload_after_scan), not on anonymous access."""
    if not system_triggered:
        if not session:
            if not api_key_name:
                settings = _load_admin_settings()
                if not settings.get("allow_anonymous_scans"):
                    return None, {
                        "error": "sign_in_required",
                        "message": "Sign in with your Microsoft account (or call with a valid X-Api-Key) to upload to the write-target Warehouse. An admin can re-enable anonymous scanning from the admin panel if needed.",
                    }
        else:
            settings = _load_admin_settings()
            if not _email_in_allowlist(session["user_email"], settings, "full_scan_emails"):
                return None, {"error": "not_permitted", "message": "This account is not allowed to trigger a Warehouse upload."}

    # Deliberately NO _check_az_session() gate here, unlike the scan starters
    # above: those always run against the shared `az` CLI session by design
    # (see _start_executions_scan's docstring). This operation instead
    # authenticates via the caller's own session token or a configured
    # service principal, entirely inside 67_upload_bronze_to_warehouse.ps1's
    # own Get-DatabaseAccessToken (see admin_settings.py's auth_mode field) --
    # `az` on THIS server machine is only that script's own last-resort
    # fallback, not a precondition for every attempt. Gating on it here blocked
    # every upload (even a fully working session-token or service-principal
    # one) behind whatever `az` happens to be doing on the server, and
    # produced a misleading "Azure CLI session is missing or expired" error
    # for a problem that had nothing to do with Azure CLI (real report).
    # A real missing-token failure still surfaces -- just from
    # the script's own error, in its log, like any other real upload failure.
    pwsh_path = _resolve_pwsh_command()
    if not pwsh_path:
        return None, {"error": "spawn_failed", "message": "PowerShell ('pwsh') was not found on PATH."}

    with _scan_lock:
        if _scan_state.get("status") == "running":
            if len(_scan_queue) >= MAX_QUEUED_SCANS:
                return None, {
                    "error": "queue_full",
                    "message": f"The scan queue is full ({MAX_QUEUED_SCANS} requests already waiting). Try again once earlier ones finish.",
                }
            entry, position = _enqueue_locked("warehouse_upload", None, session, api_key_name, system_triggered=system_triggered)
            _write_scan_queue()
            return {
                "status": "queued", "queue_id": entry["queue_id"], "workspace": WAREHOUSE_UPLOAD_LABEL,
                "position": position, "queued_at": entry["requested_at"],
            }, None
        _scan_state["status"] = "running"
        _scan_state["workspace"] = WAREHOUSE_UPLOAD_LABEL
        _scan_state["pid"] = None
        _scan_state["started_by_email"] = session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else None)
        _scan_state["is_tenant_admin_scan"] = False
        _scan_state["workspace_count"] = None
        _write_scan_state()

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    log_path = LOG_DIR / f"{timestamp}_warehouse-upload.log"

    started_at = _now_iso()
    try:
        log_handle = open(log_path, "w", encoding="utf-8")
        proc = subprocess.Popen(
            [pwsh_path, "-NoLogo", "-File", str(WAREHOUSE_UPLOAD_SCRIPT_PATH)],
            cwd=str(REPO_ROOT),
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            env=_build_scan_subprocess_env(session),
        )
    except OSError as exc:
        _release_claimed_slot_after_spawn_failure(WAREHOUSE_UPLOAD_LABEL, exc)
        return None, {"error": "spawn_failed", "message": str(exc)}

    with _scan_lock:
        _scan_state["status"] = "running"
        _scan_state["workspace"] = WAREHOUSE_UPLOAD_LABEL
        _scan_state["pid"] = proc.pid
        _scan_state["scan_id"] = started_at
        _scan_state["started_at"] = started_at
        _scan_state["ended_at"] = None
        _scan_state["duration_seconds"] = None
        _scan_state["exit_code"] = None
        _scan_state["log_path"] = _relative_to_repo(log_path)
        _scan_state["last_error"] = None
        _scan_state["cancel_requested"] = False
        _scan_state["started_by_email"] = session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else None)
        _scan_state["is_tenant_admin_scan"] = False
        _scan_state["workspace_count"] = None
        _write_scan_state()

    threading.Thread(target=_wait_for_warehouse_upload_process, args=(proc, started_at, time.time()), daemon=True).start()

    return {"status": "started", "scan_id": started_at, "workspace": WAREHOUSE_UPLOAD_LABEL, "started_at": started_at, "log_path": _relative_to_repo(log_path)}, None


def _maybe_trigger_warehouse_upload():
    """Called right before the scan-just-finished cleanup's own
    _dequeue_and_start_next() (see _wait_for_process / _wait_for_full_scan_
    process) -- if the admin has both configured a write-target Warehouse
    AND turned on "auto_upload_after_scan" (the admin panel's write-target
    tab sets this automatically the first time "Copiar datos ahora" is run
    manually, per the user's own ask: one manual run, then every scan after
    that keeps it in sync on its own), queues a warehouse_upload exactly
    like any other request that arrives while a scan is running -- at the
    BACK of the real queue, never ahead of an actual user's own pending
    request. Only enqueues; the caller's existing _dequeue_and_start_next()
    call (unconditional, right after this) is what actually starts it --
    whether that's this upload or something a real user queued first."""
    settings = _load_admin_settings()
    lakehouse = settings.get("lakehouse") or {}
    if not lakehouse.get("auto_upload_after_scan"):
        return
    if not lakehouse.get("sql_endpoint_connection_string") or not lakehouse.get("lakehouse_name"):
        return
    with _scan_lock:
        if _scan_state.get("status") == "running":
            return
        if len(_scan_queue) >= MAX_QUEUED_SCANS:
            return
        _enqueue_locked("warehouse_upload", None, None, None, system_triggered=True)
        _write_scan_queue()


def _wait_for_onelake_publish_process(proc, started_at_iso, started_monotonic):
    # No item snapshot/diff here either (same reasoning as the warehouse
    # upload/executions scan) -- this never touches items.csv, it only
    # reads already-built local JSON and pushes it to OneLake.
    exit_code = proc.wait()
    duration = round(time.time() - started_monotonic, 3)
    ended_at_iso = _now_iso()
    with _scan_lock:
        was_cancelled = bool(_scan_state.get("cancel_requested"))
        status = "cancelled" if was_cancelled else ("succeeded" if exit_code == 0 else "failed")
        _scan_state["status"] = status
        _scan_state["ended_at"] = ended_at_iso
        _scan_state["duration_seconds"] = duration
        _scan_state["exit_code"] = exit_code
        if was_cancelled:
            _scan_state["last_error"] = "Stopped by user request."
        elif exit_code != 0:
            _scan_state["last_error"] = f"72_publish_web_data_to_onelake.ps1 exited with code {exit_code}. See the log for details."
        _write_scan_state()
    _append_history_row(ONELAKE_PUBLISH_LABEL, started_at_iso, ended_at_iso, duration, status)
    _dequeue_and_start_next()


def _start_onelake_publish(session=None, api_key_name=None, system_triggered=False):
    """Publishes the already-built big JSON payloads (lineage-explorer.json
    and friends) to the OneLake destination configured on the admin
    panel's OneLake data tab (see 72_publish_web_data_to_onelake.py) --
    reads only already-generated local files, no new Fabric scanning here.
    Same trust bar/system_triggered shape as _start_warehouse_upload."""
    if not system_triggered:
        if not session:
            if not api_key_name:
                settings = _load_admin_settings()
                if not settings.get("allow_anonymous_scans"):
                    return None, {
                        "error": "sign_in_required",
                        "message": "Sign in with your Microsoft account (or call with a valid X-Api-Key) to publish to OneLake. An admin can re-enable anonymous scanning from the admin panel if needed.",
                    }
        else:
            settings = _load_admin_settings()
            if not _email_in_allowlist(session["user_email"], settings, "full_scan_emails"):
                return None, {"error": "not_permitted", "message": "This account is not allowed to trigger a OneLake data publish."}

    pwsh_path = _resolve_pwsh_command()
    if not pwsh_path:
        return None, {"error": "spawn_failed", "message": "PowerShell ('pwsh') was not found on PATH."}

    with _scan_lock:
        if _scan_state.get("status") == "running":
            if len(_scan_queue) >= MAX_QUEUED_SCANS:
                return None, {
                    "error": "queue_full",
                    "message": f"The scan queue is full ({MAX_QUEUED_SCANS} requests already waiting). Try again once earlier ones finish.",
                }
            entry, position = _enqueue_locked("onelake_publish", None, session, api_key_name, system_triggered=system_triggered)
            _write_scan_queue()
            return {
                "status": "queued", "queue_id": entry["queue_id"], "workspace": ONELAKE_PUBLISH_LABEL,
                "position": position, "queued_at": entry["requested_at"],
            }, None
        _scan_state["status"] = "running"
        _scan_state["workspace"] = ONELAKE_PUBLISH_LABEL
        _scan_state["pid"] = None
        _scan_state["started_by_email"] = session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else None)
        _scan_state["is_tenant_admin_scan"] = False
        _scan_state["workspace_count"] = None
        _write_scan_state()

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    log_path = LOG_DIR / f"{timestamp}_onelake-publish.log"

    started_at = _now_iso()
    try:
        log_handle = open(log_path, "w", encoding="utf-8")
        proc = subprocess.Popen(
            [pwsh_path, "-NoLogo", "-File", str(ONELAKE_PUBLISH_SCRIPT_PATH)],
            cwd=str(REPO_ROOT),
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            env=_build_scan_subprocess_env(session),
        )
    except OSError as exc:
        _release_claimed_slot_after_spawn_failure(ONELAKE_PUBLISH_LABEL, exc)
        return None, {"error": "spawn_failed", "message": str(exc)}

    with _scan_lock:
        _scan_state["status"] = "running"
        _scan_state["workspace"] = ONELAKE_PUBLISH_LABEL
        _scan_state["pid"] = proc.pid
        _scan_state["scan_id"] = started_at
        _scan_state["started_at"] = started_at
        _scan_state["ended_at"] = None
        _scan_state["duration_seconds"] = None
        _scan_state["exit_code"] = None
        _scan_state["log_path"] = _relative_to_repo(log_path)
        _scan_state["last_error"] = None
        _scan_state["cancel_requested"] = False
        _scan_state["started_by_email"] = session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else None)
        _scan_state["is_tenant_admin_scan"] = False
        _scan_state["workspace_count"] = None
        _write_scan_state()

    threading.Thread(target=_wait_for_onelake_publish_process, args=(proc, started_at, time.time()), daemon=True).start()

    return {"status": "started", "scan_id": started_at, "workspace": ONELAKE_PUBLISH_LABEL, "started_at": started_at, "log_path": _relative_to_repo(log_path)}, None


def _maybe_trigger_onelake_publish():
    """Same shape/reasoning as _maybe_trigger_warehouse_upload. Called from
    both _wait_for_process (single-workspace scans) and _wait_for_full_
    scan_process (full scans) -- both local pipelines rebuild all 5 big
    JSON files (see each call site's own comment). Never
    called from _wait_for_fabric_pipeline_job: that path only populates
    Warehouse bronze tables, never these local JSON files. If the admin
    has both configured a OneLake destination AND turned on onelake_data.
    auto_publish_after_scan, queues a onelake_publish exactly like any
    other request that arrives while a scan is running -- at the back of
    the real queue."""
    settings = _load_admin_settings()
    onelake = settings.get("onelake_data") or {}
    if not onelake.get("auto_publish_after_scan"):
        return
    if not onelake.get("workspace_name") or not onelake.get("lakehouse_name"):
        return
    with _scan_lock:
        if _scan_state.get("status") == "running":
            return
        if len(_scan_queue) >= MAX_QUEUED_SCANS:
            return
        _enqueue_locked("onelake_publish", None, None, None, system_triggered=True)
        _write_scan_queue()


def _start_scan_via_fabric_pipeline(workspace_name, session, api_key_name):
    """Mirrors _start_scan's claim/enqueue state machine exactly, but
    starts the work by triggering the configured Fabric Data Pipeline
    (see fabric_pipeline.py) instead of spawning local PowerShell -- kept
    as its own function rather than branching deep inside _start_scan so
    the existing, already-tested local path stays completely untouched."""
    with _scan_lock:
        if _scan_state.get("status") == "running":
            if len(_scan_queue) >= MAX_QUEUED_SCANS:
                return None, {
                    "error": "queue_full",
                    "message": f"The scan queue is full ({MAX_QUEUED_SCANS} requests already waiting). Try again once earlier ones finish.",
                }
            entry, position = _enqueue_locked("scan", workspace_name, session, api_key_name)
            _write_scan_queue()
            return {
                "status": "queued", "queue_id": entry["queue_id"], "workspace": workspace_name,
                "position": position, "queued_at": entry["requested_at"],
            }, None
        _scan_state["status"] = "running"
        _scan_state["workspace"] = workspace_name
        _scan_state["pid"] = None
        _scan_state["fabric_job_instance_id"] = None
        _scan_state["started_by_email"] = session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else None)
        _scan_state["is_tenant_admin_scan"] = False
        _scan_state["workspace_count"] = None
        _write_scan_state()

    started_at = _now_iso()
    before_snapshot = _snapshot_items_for_scope_warehouse([workspace_name])
    before_dependency_snapshot = _snapshot_dependencies_for_scope_warehouse([workspace_name])
    try:
        job_instance_id = fabric_pipeline.trigger_pipeline_run(workspace_name, session=session)
    except fabric_pipeline.FabricPipelineError as exc:
        _release_claimed_slot_after_spawn_failure(workspace_name, exc)
        return None, {"error": "spawn_failed", "message": str(exc)}

    with _scan_lock:
        _scan_state["status"] = "running"
        _scan_state["workspace"] = workspace_name
        _scan_state["pid"] = None
        _scan_state["fabric_job_instance_id"] = job_instance_id
        _scan_state["scan_id"] = started_at
        _scan_state["started_at"] = started_at
        _scan_state["ended_at"] = None
        _scan_state["duration_seconds"] = None
        _scan_state["exit_code"] = None
        _scan_state["log_path"] = None
        _scan_state["last_error"] = None
        _scan_state["cancel_requested"] = False
        _scan_state["started_by_email"] = session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else None)
        _scan_state["is_tenant_admin_scan"] = False
        _scan_state["workspace_count"] = None
        _write_scan_state()

    threading.Thread(
        target=_wait_for_fabric_pipeline_job,
        args=(job_instance_id, workspace_name, started_at, time.time()),
        kwargs={
            "session": session, "before_snapshot": before_snapshot,
            "before_dependency_snapshot": before_dependency_snapshot, "scope_names": [workspace_name],
        },
        daemon=True,
    ).start()

    return {
        "status": "started", "scan_id": started_at, "workspace": workspace_name,
        "started_at": started_at, "log_path": None, "fabric_job_instance_id": job_instance_id,
    }, None


def _start_full_scan_via_fabric_pipeline(workspace_name_filter, scope_names, is_tenant_admin_scan, session, api_key_name):
    """Same relationship to _start_full_scan as _start_scan_via_fabric_
    pipeline has to _start_scan -- scope_names has already been resolved
    (per-user accessible workspaces, or None for the whole tenant) by the
    caller, exactly like the local path; this just starts the pipeline
    run instead of the local subprocess."""
    with _scan_lock:
        if _scan_state.get("status") == "running":
            if len(_scan_queue) >= MAX_QUEUED_SCANS:
                return None, {
                    "error": "queue_full",
                    "message": f"The scan queue is full ({MAX_QUEUED_SCANS} requests already waiting). Try again once earlier ones finish.",
                }
            entry, position = _enqueue_locked("full_scan", None, session, api_key_name)
            _write_scan_queue()
            return {
                "status": "queued", "queue_id": entry["queue_id"], "workspace": FULL_SCAN_LABEL,
                "position": position, "queued_at": entry["requested_at"],
            }, None
        _scan_state["status"] = "running"
        _scan_state["workspace"] = FULL_SCAN_LABEL
        _scan_state["pid"] = None
        _scan_state["fabric_job_instance_id"] = None
        _scan_state["started_by_email"] = session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else None)
        _scan_state["is_tenant_admin_scan"] = is_tenant_admin_scan
        _scan_state["workspace_count"] = len(scope_names) if scope_names is not None else None
        _write_scan_state()

    started_at = _now_iso()
    before_snapshot = _snapshot_items_for_scope_warehouse(scope_names)
    before_dependency_snapshot = _snapshot_dependencies_for_scope_warehouse(scope_names)
    try:
        job_instance_id = fabric_pipeline.trigger_pipeline_run(workspace_name_filter, session=session)
    except fabric_pipeline.FabricPipelineError as exc:
        _release_claimed_slot_after_spawn_failure(FULL_SCAN_LABEL, exc)
        return None, {"error": "spawn_failed", "message": str(exc)}

    with _scan_lock:
        _scan_state["status"] = "running"
        _scan_state["workspace"] = FULL_SCAN_LABEL
        _scan_state["pid"] = None
        _scan_state["fabric_job_instance_id"] = job_instance_id
        _scan_state["scan_id"] = started_at
        _scan_state["started_at"] = started_at
        _scan_state["ended_at"] = None
        _scan_state["duration_seconds"] = None
        _scan_state["exit_code"] = None
        _scan_state["log_path"] = None
        _scan_state["last_error"] = None
        _scan_state["cancel_requested"] = False
        _scan_state["started_by_email"] = session["user_email"] if session else (f"api:{api_key_name}" if api_key_name else None)
        _scan_state["is_tenant_admin_scan"] = is_tenant_admin_scan
        _scan_state["workspace_count"] = len(scope_names) if scope_names is not None else None
        _write_scan_state()

    threading.Thread(
        target=_wait_for_fabric_pipeline_job,
        args=(job_instance_id, FULL_SCAN_LABEL, started_at, time.time()),
        kwargs={
            "session": session, "before_snapshot": before_snapshot,
            "before_dependency_snapshot": before_dependency_snapshot, "scope_names": scope_names,
        },
        daemon=True,
    ).start()

    return {
        "status": "started", "scan_id": started_at, "workspace": FULL_SCAN_LABEL, "started_at": started_at,
        "log_path": None, "is_tenant_admin_scan": is_tenant_admin_scan,
        "workspace_count": len(scope_names) if scope_names is not None else None,
        "fabric_job_instance_id": job_instance_id,
    }, None


_FABRIC_PIPELINE_POLL_INTERVAL_SECONDS = 15
_FABRIC_PIPELINE_MAX_CONSECUTIVE_POLL_FAILURES = 20  # ~5 minutes at the interval above


def _wait_for_fabric_pipeline_job(job_instance_id, scope_label, started_at_iso, started_monotonic, session=None, before_snapshot=None, before_dependency_snapshot=None, scope_names=None):
    """Polling counterpart to _wait_for_process/_wait_for_full_scan_process
    for a scan running as a Fabric pipeline instead of a local subprocess.

    session is whatever signed-in user's session (if any) triggered this
    run, captured once by the caller and threaded through every poll/
    cancel call below for this run's entire lifetime -- possibly hours.
    This is just a reference to the same dict stored in _sessions at
    trigger time; a later logout/revoke only removes it from _sessions,
    it does not clear this dict object, so the token cache captured here
    keeps working (silently refreshed via MSAL) for the rest of this run
    even if the user signs out midway. None falls back to the configured
    service principal, unchanged from before this existed.

    Item snapshot/diff: before_snapshot is taken by the
    caller (_start_scan_via_fabric_pipeline / _start_full_scan_via_fabric_
    pipeline) right before triggering the pipeline, via
    _snapshot_items_for_scope_warehouse -- items.csv on THIS machine isn't
    touched by a Fabric-side run at all, so the diff has to be against
    live dbo.bronze_items (lakehouse.web_read_mode == "warehouse"), not a
    local file. Both before_snapshot and scope_names default to None/{}
    so a caller that predates this (or a Warehouse read that failed at
    trigger time) just skips history tracking instead of erroring.

    Dependency snapshot/diff: same idea, one
    level down the graph -- before_dependency_snapshot/_snapshot_
    dependencies_for_scope_warehouse/_diff_dependencies/_append_
    dependency_history_rows_warehouse mirror the item-level ones above
    exactly, tracking edges (from/to/relationship_type) instead of nodes.
    Independent of the item tracking above: either can succeed or skip on
    its own.

    A bounded consecutive-failure counter (rather than looping forever)
    protects against a misconfigured/unreachable Fabric API leaving this
    scan stuck "running" forever and blocking the queue behind it."""
    status = "failed"
    error_message = ""
    cancel_sent = False
    consecutive_poll_failures = 0
    while True:
        with _scan_lock:
            cancel_requested = bool(_scan_state.get("cancel_requested"))
        if cancel_requested and not cancel_sent:
            cancel_sent = True
            try:
                fabric_pipeline.cancel_job(job_instance_id, session=session)
            except fabric_pipeline.FabricPipelineError as exc:
                # Best-effort -- the poll below still catches whatever
                # terminal status Fabric eventually settles on either way.
                print(f"[scan_manager] Could not cancel Fabric job {job_instance_id}: {exc}", file=sys.stderr)

        try:
            payload = fabric_pipeline.get_job_status(job_instance_id, session=session)
            consecutive_poll_failures = 0
        except fabric_pipeline.FabricPipelineError as exc:
            consecutive_poll_failures += 1
            error_message = str(exc)
            if consecutive_poll_failures >= _FABRIC_PIPELINE_MAX_CONSECUTIVE_POLL_FAILURES:
                status = "failed"
                error_message = f"Gave up polling the Fabric pipeline run after {consecutive_poll_failures} failed attempts: {exc}"
                break
            time.sleep(_FABRIC_PIPELINE_POLL_INTERVAL_SECONDS)
            continue

        raw_status = payload.get("status", "")
        if raw_status in fabric_pipeline.TERMINAL_STATUS_MAP:
            status = fabric_pipeline.TERMINAL_STATUS_MAP[raw_status]
            if raw_status in ("Failed", "Deduped"):
                failure = payload.get("failureReason") or {}
                error_message = failure.get("message") or (
                    f"The Fabric pipeline run ended with status '{raw_status}'. "
                    "Check its run history in Fabric for details."
                )
            break
        time.sleep(_FABRIC_PIPELINE_POLL_INTERVAL_SECONDS)

    duration = round(time.time() - started_monotonic, 3)
    ended_at_iso = _now_iso()
    with _scan_lock:
        if bool(_scan_state.get("cancel_requested")) and status != "succeeded":
            status = "cancelled"
            error_message = "Stopped by user request."
        _scan_state["status"] = status
        _scan_state["ended_at"] = ended_at_iso
        _scan_state["duration_seconds"] = duration
        _scan_state["exit_code"] = None
        _scan_state["last_error"] = error_message or None
        _write_scan_state()

    _append_history_row(scope_label, started_at_iso, ended_at_iso, duration, status)
    _send_scan_notification_emails(
        scope_label, started_at_iso, ended_at_iso, status, None,
        _scan_state.get("started_by_email"), "", error_message,
    )
    if status == "succeeded":
        if before_snapshot:
            after_snapshot = _snapshot_items_for_scope_warehouse(scope_names)
            if after_snapshot:
                diff = _diff_items(before_snapshot, after_snapshot)
                _append_item_history_rows_warehouse(diff, scope_label, started_at_iso)
        if before_dependency_snapshot:
            after_dependency_snapshot = _snapshot_dependencies_for_scope_warehouse(scope_names)
            if after_dependency_snapshot:
                dependency_diff = _diff_dependencies(before_dependency_snapshot, after_dependency_snapshot)
                _append_dependency_history_rows_warehouse(dependency_diff, scope_label, started_at_iso)
        _maybe_trigger_warehouse_upload()
    _dequeue_and_start_next()


def _stop_scan(session=None, api_key_name=None):
    with _scan_lock:
        if _scan_state.get("status") != "running":
            return None, {"error": "no_scan_running", "message": "No scan is currently running."}
        started_by_email = _scan_state.get("started_by_email")
        pid = _scan_state.get("pid")
        fabric_job_instance_id = _scan_state.get("fabric_job_instance_id")
        workspace = _scan_state.get("workspace")

    # A scan someone actually signed in to start can only be stopped by that
    # same person, an admin, or any valid API key -- otherwise anyone
    # reaching this server could kill another user's multi-hour scan with a
    # single unauthenticated request. A valid API key can stop ANY scan
    # (not just one it started itself), matching the operational control an
    # admin already has -- the automation caller this exists for needs to
    # be able to clear a stuck prior run regardless of who/what started it.
    # A scan that was itself started anonymously (only possible when an
    # admin has opted into allow_anonymous_scans) keeps the old
    # anyone-can-stop-it behavior, matching how that opt-in already works.
    if started_by_email and not api_key_name:
        caller_email = (session or {}).get("user_email", "")
        is_owner = caller_email.strip().lower() == started_by_email.strip().lower()
        if not is_owner:
            settings = _load_admin_settings()
            if not _email_in_allowlist(caller_email, settings, "admin_emails"):
                return None, {
                    "error": "not_permitted",
                    "message": "Only the person who started this scan, an admin, or a valid API key, can stop it.",
                }

    with _scan_lock:
        if _scan_state.get("status") != "running":
            return None, {"error": "no_scan_running", "message": "No scan is currently running."}
        _scan_state["cancel_requested"] = True
        _write_scan_state()

    if fabric_job_instance_id:
        # A Fabric-pipeline-triggered scan has no local process to kill --
        # ask Fabric to cancel the job instance instead. Off the request
        # thread (this HTTP call can be slow): _wait_for_fabric_pipeline_job
        # already sees cancel_requested on its own next poll and will call
        # cancel_job itself too if this happens to race it, so a failure or
        # duplicate call here is harmless, just belt-and-suspenders for a
        # faster-feeling stop than waiting for the next poll tick.
        def _cancel_in_background():
            try:
                # The STOPPING caller's own session, if any -- a lightweight
                # one-off call, unlike the poll loop's own cancel-on-next-
                # poll (see _wait_for_fabric_pipeline_job) which reuses the
                # ORIGINAL triggering session for the run's whole lifetime.
                # Either succeeding is enough; see that function's own
                # comment on why a duplicate/failed call here is harmless.
                fabric_pipeline.cancel_job(fabric_job_instance_id, session=session)
            except fabric_pipeline.FabricPipelineError as exc:
                print(f"[scan_manager] Could not cancel Fabric job {fabric_job_instance_id}: {exc}", file=sys.stderr)

        threading.Thread(target=_cancel_in_background, daemon=True).start()
        return {"status": "stopping", "workspace": workspace, "pid": None, "fabric_job_instance_id": fabric_job_instance_id}, None

    # Force-kills the whole process tree (the top-level pwsh plus every
    # child pwsh/az/sqlcmd process a step may have spawned) rather than just
    # the top-level PID, which on its own would leave the actual in-progress
    # step running orphaned. The background _wait_for_*_process thread
    # already watching this PID sees cancel_requested and records
    # "cancelled" once proc.wait() returns, so there is nothing further to
    # update here.
    _kill_process_tree(pid)
    return {"status": "stopping", "workspace": workspace, "pid": pid}, None
