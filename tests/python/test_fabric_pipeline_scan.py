"""Unit tests for the optional Fabric-pipeline scan trigger (2026-07-24):
backend/scripts/lineage_web/fabric_pipeline.py and the discovery_pipeline
branch it adds to scan_manager.py's _start_scan/_start_full_scan/_stop_scan.

Every Fabric/subprocess/disk touchpoint is monkeypatched or redirected to
tmp_path -- these tests must never spawn a real process or read/write the
real admin_settings.json / analysis/single_workspace_scan/* (a manual
smoke test that skipped this discipline once triggered a real
67_upload_bronze_to_warehouse.ps1 run against a real Warehouse; see
docs/101's "Lectura en vivo" section).

Run with: pytest tests/python/test_fabric_pipeline_scan.py
"""
import sys
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import fabric_pipeline, scan_manager  # noqa: E402
from lineage_web.state import _scan_lock, _scan_queue, _scan_state  # noqa: E402

INERT_SETTINGS = {
    "tenant_id": "tenant-x",
    "admin_emails": [],
    "full_scan_emails": [],
    "lakehouse": {"auto_upload_after_scan": False},
    "notifications": {"subscribers": []},
    "discovery_pipeline": {
        "mode": "fabric_pipeline",
        "workspace_id": "ws-1",
        "pipeline_item_id": "pl-1",
        "sp_tenant_id": "tenant-x",
        "sp_client_id": "client-x",
        "sp_client_secret_ref": "TEST_SECRET_REF",
    },
}


def _wait_until_not_running(timeout_seconds=5):
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        with _scan_lock:
            if _scan_state["status"] != "running":
                return
        time.sleep(0.02)
    raise AssertionError("scan did not leave 'running' state in time")


def setup_function(monkeypatch=None):
    with _scan_lock:
        _scan_state.update({
            "status": "idle", "workspace": None, "pid": None, "scan_id": None,
            "started_at": None, "ended_at": None, "duration_seconds": None,
            "exit_code": None, "log_path": None, "last_error": None,
            "cancel_requested": False, "started_by_email": None,
            "is_tenant_admin_scan": False, "workspace_count": None,
            "fabric_job_instance_id": None,
        })
        _scan_queue.clear()
    fabric_pipeline._token_cache["access_token"] = ""
    fabric_pipeline._token_cache["expires_at"] = 0.0


def _isolate(monkeypatch, tmp_path):
    """Every test calls this first: inert settings (no real subprocess/
    email side effects), scan state files redirected under tmp_path, and
    a fake workspace index so _start_scan's own validation passes."""
    monkeypatch.setattr(scan_manager, "_load_admin_settings", lambda: INERT_SETTINGS)
    monkeypatch.setattr(fabric_pipeline, "_load_admin_settings", lambda: INERT_SETTINGS)
    monkeypatch.setattr(scan_manager, "_read_workspaces", lambda: [{"workspace_name": "TestWorkspace"}])
    monkeypatch.setattr(scan_manager, "STATE_PATH", tmp_path / "state.json")
    monkeypatch.setattr(scan_manager, "STATE_DIR", tmp_path)
    monkeypatch.setattr(scan_manager, "HISTORY_PATH", tmp_path / "history.csv")
    monkeypatch.setattr(scan_manager, "QUEUE_PATH", tmp_path / "queue.json")
    monkeypatch.setattr(scan_manager, "_FABRIC_PIPELINE_POLL_INTERVAL_SECONDS", 0.02)


# ---------------------------------------------------------------------------
# is_fabric_pipeline_mode / configuration gating
# ---------------------------------------------------------------------------

def test_is_fabric_pipeline_mode_false_by_default(monkeypatch):
    monkeypatch.setattr(fabric_pipeline, "_load_admin_settings", lambda: {"discovery_pipeline": {}})
    assert fabric_pipeline.is_fabric_pipeline_mode() is False


def test_is_fabric_pipeline_mode_true_when_configured(monkeypatch):
    monkeypatch.setattr(fabric_pipeline, "_load_admin_settings", lambda: INERT_SETTINGS)
    assert fabric_pipeline.is_fabric_pipeline_mode() is True


def test_trigger_pipeline_run_raises_when_not_configured(monkeypatch):
    monkeypatch.setattr(fabric_pipeline, "_load_admin_settings", lambda: {"discovery_pipeline": {"mode": "fabric_pipeline"}})
    try:
        fabric_pipeline.trigger_pipeline_run("SomeWorkspace")
        assert False, "should have raised"
    except fabric_pipeline.FabricPipelineNotConfiguredError:
        pass


# ---------------------------------------------------------------------------
# _start_scan routed through the Fabric pipeline
# ---------------------------------------------------------------------------

def test_start_scan_via_fabric_pipeline_succeeds(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    calls = {"trigger": 0, "status": 0}
    statuses = iter(["InProgress", "Completed"])

    def fake_trigger(workspace_name_filter="", session=None):
        calls["trigger"] += 1
        assert workspace_name_filter == "TestWorkspace"
        return "job-abc"

    def fake_status(job_instance_id, session=None):
        calls["status"] += 1
        assert job_instance_id == "job-abc"
        return {"status": next(statuses, "Completed")}

    monkeypatch.setattr(fabric_pipeline, "trigger_pipeline_run", fake_trigger)
    monkeypatch.setattr(fabric_pipeline, "get_job_status", fake_status)

    result, error = scan_manager._start_scan("TestWorkspace", session=None, api_key_name="test-key")
    assert error is None
    assert result["status"] == "started"
    assert result["fabric_job_instance_id"] == "job-abc"

    _wait_until_not_running()
    with _scan_lock:
        final = dict(_scan_state)
    assert final["status"] == "succeeded"
    assert final["pid"] is None
    assert final["fabric_job_instance_id"] == "job-abc"
    assert calls["trigger"] == 1
    assert calls["status"] == 2


def test_start_scan_via_fabric_pipeline_records_failure_reason(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    monkeypatch.setattr(fabric_pipeline, "trigger_pipeline_run", lambda workspace_name_filter="", session=None: "job-fail")
    monkeypatch.setattr(
        fabric_pipeline, "get_job_status",
        lambda job_instance_id, session=None: {"status": "Failed", "failureReason": {"message": "boom"}},
    )

    result, error = scan_manager._start_scan("TestWorkspace", session=None, api_key_name="test-key")
    assert error is None
    _wait_until_not_running()
    with _scan_lock:
        final = dict(_scan_state)
    assert final["status"] == "failed"
    assert final["last_error"] == "boom"


def test_start_scan_via_fabric_pipeline_spawn_failure_releases_slot(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)

    def raise_not_configured(workspace_name_filter="", session=None):
        raise fabric_pipeline.FabricPipelineNotConfiguredError("not configured")

    monkeypatch.setattr(fabric_pipeline, "trigger_pipeline_run", raise_not_configured)

    result, error = scan_manager._start_scan("TestWorkspace", session=None, api_key_name="test-key")
    assert result is None
    assert error["error"] == "spawn_failed"
    with _scan_lock:
        assert _scan_state["status"] == "failed"


def test_stop_scan_on_fabric_pipeline_run_calls_cancel_not_kill_process(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    monkeypatch.setattr(fabric_pipeline, "trigger_pipeline_run", lambda workspace_name_filter="", session=None: "job-stop")
    cancel_calls = []

    def fake_get_status(job_instance_id, session=None):
        # Mirrors real Fabric behavior: cancellation is asynchronous -- the
        # job only reports "Cancelled" on a poll *after* the cancel call
        # was accepted, not immediately.
        return {"status": "Cancelled" if cancel_calls else "InProgress"}

    monkeypatch.setattr(fabric_pipeline, "get_job_status", fake_get_status)
    monkeypatch.setattr(fabric_pipeline, "cancel_job", lambda job_instance_id, session=None: cancel_calls.append(job_instance_id))

    kill_calls = []
    monkeypatch.setattr(scan_manager, "_kill_process_tree", lambda pid: kill_calls.append(pid))

    result, error = scan_manager._start_scan("TestWorkspace", session=None, api_key_name="test-key")
    assert error is None

    stop_result, stop_error = scan_manager._stop_scan(session=None, api_key_name="test-key")
    assert stop_error is None
    assert stop_result["pid"] is None
    assert stop_result["fabric_job_instance_id"] == "job-stop"

    deadline = time.time() + 2
    while not cancel_calls and time.time() < deadline:
        time.sleep(0.02)
    # _stop_scan's own immediate background cancel and the poll loop's own
    # cancel-on-next-poll are intentionally redundant (see scan_manager.py's
    # comment on _cancel_in_background) -- either can win the race, and
    # both firing is harmless, so this only asserts cancel_job was called
    # for the right job at least once, not exactly once.
    assert cancel_calls and set(cancel_calls) == {"job-stop"}
    assert kill_calls == []  # the local-process code path must never run for a Fabric-pipeline scan

    _wait_until_not_running()
    with _scan_lock:
        assert _scan_state["status"] == "cancelled"


def test_local_mode_never_calls_fabric_pipeline(monkeypatch, tmp_path):
    """Default behavior (discovery_pipeline.mode == "local") must not touch
    fabric_pipeline at all -- this is the regression guard for the existing,
    already-shipped local scan path."""
    monkeypatch.setattr(scan_manager, "_load_admin_settings", lambda: {
        "discovery_pipeline": {"mode": "local"}, "allow_anonymous_scans": False,
    })
    monkeypatch.setattr(fabric_pipeline, "_load_admin_settings", lambda: {"discovery_pipeline": {"mode": "local"}})
    monkeypatch.setattr(scan_manager, "_read_workspaces", lambda: [{"workspace_name": "TestWorkspace"}])

    def fail_if_called(*args, **kwargs):
        raise AssertionError("fabric_pipeline.trigger_pipeline_run must not be called in local mode")

    monkeypatch.setattr(fabric_pipeline, "trigger_pipeline_run", fail_if_called)

    # No signed-in session and anonymous scans off -> local path stops at
    # its own permission check, long before ever reaching pwsh/subprocess
    # -- exactly what proves the fabric_pipeline branch was never taken
    # (fail_if_called above would have raised AssertionError otherwise).
    result, error = scan_manager._start_scan("TestWorkspace", session=None, api_key_name=None)
    assert result is None
    assert error["error"] == "sign_in_required"


# ---------------------------------------------------------------------------
# _recover_scan_state_on_startup (2026-08-11): a Fabric-pipeline scan has no
# local process, so it must re-attach to the real job on restart instead of
# assuming "pid not alive" means "failed" -- see the function's own comment
# for why a naive restart would otherwise mislabel a scan that's still
# running (or already succeeded) in Fabric as failed.
# ---------------------------------------------------------------------------

def test_recover_on_startup_resumes_fabric_job_instead_of_marking_failed(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    with _scan_lock:
        _scan_state.update({
            "status": "running", "workspace": "TestWorkspace", "pid": None,
            "fabric_job_instance_id": "job-resume", "started_at": "2026-08-11T10:00:00+00:00",
            "cancel_requested": False,
        })

    monkeypatch.setattr(fabric_pipeline, "get_job_status", lambda job_instance_id, session=None: {"status": "Completed"})

    scan_manager._recover_scan_state_on_startup()
    _wait_until_not_running()

    with _scan_lock:
        final = dict(_scan_state)
    assert final["status"] == "succeeded"
    assert final["fabric_job_instance_id"] == "job-resume"


def test_recover_on_startup_still_polling_fabric_job_stays_running(monkeypatch, tmp_path):
    _isolate(monkeypatch, tmp_path)
    with _scan_lock:
        _scan_state.update({
            "status": "running", "workspace": "TestWorkspace", "pid": None,
            "fabric_job_instance_id": "job-still-going", "started_at": "2026-08-11T10:00:00+00:00",
            "cancel_requested": False,
        })

    poll_calls = []

    def fake_status(job_instance_id, session=None):
        poll_calls.append(job_instance_id)
        return {"status": "InProgress"}

    monkeypatch.setattr(fabric_pipeline, "get_job_status", fake_status)

    scan_manager._recover_scan_state_on_startup()
    deadline = time.time() + 1
    while len(poll_calls) < 2 and time.time() < deadline:
        time.sleep(0.02)

    with _scan_lock:
        assert _scan_state["status"] == "running"
    assert poll_calls  # actually re-polled Fabric, not just left stale


def test_recover_on_startup_local_pid_dead_still_marks_failed(monkeypatch, tmp_path):
    """Regression guard: a local (non-Fabric-pipeline) scan whose process
    died while nothing was watching must still behave exactly as before."""
    _isolate(monkeypatch, tmp_path)
    with _scan_lock:
        _scan_state.update({
            "status": "running", "workspace": "TestWorkspace", "pid": 999999999,
            "fabric_job_instance_id": None, "started_at": "2026-08-11T10:00:00+00:00",
            "cancel_requested": False,
        })

    monkeypatch.setattr(scan_manager, "_is_pid_alive", lambda pid: False)

    scan_manager._recover_scan_state_on_startup()

    with _scan_lock:
        final = dict(_scan_state)
    assert final["status"] == "failed"
    assert "restart" in final["last_error"]
