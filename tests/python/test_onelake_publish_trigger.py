"""Unit tests for the OneLake web-data auto-publish mechanism:
_maybe_trigger_onelake_publish/_start_onelake_publish/_wait_for_onelake_
publish_process in backend/scripts/lineage_web/scan_manager.py -- the
publish-side counterpart to the existing Warehouse auto-upload trigger.

Same discipline as test_fabric_pipeline_scan.py's own docstring: every
Fabric/subprocess/disk touchpoint is monkeypatched or redirected to
tmp_path, and _start_onelake_publish is never exercised all the way to its
real subprocess.Popen call (that spawn is verified live instead, same as
_start_scan/_start_full_scan/_start_warehouse_upload already are -- see
test_scan_queue.py's docstring).

Run with: pytest tests/python/test_onelake_publish_trigger.py
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import scan_manager as sm  # noqa: E402

ONELAKE_CONFIGURED_SETTINGS = {
    "full_scan_emails": ["allowed@example.com"],
    "allow_anonymous_scans": False,
    "onelake_data": {
        "mode": "onelake",
        "workspace_name": "WS-Test",
        "lakehouse_name": "LH-Test",
        "auto_publish_after_scan": True,
    },
}


def setup_function():
    with sm._scan_lock:
        sm._scan_queue.clear()
        sm._scan_state.clear()
        sm._scan_state.update({
            "status": "idle", "workspace": None, "pid": None, "scan_id": None,
            "started_at": None, "ended_at": None, "duration_seconds": None,
            "exit_code": None, "log_path": None, "last_error": None,
            "cancel_requested": False, "started_by_email": None,
        })


# ---------------------------------------------------------------------------
# _maybe_trigger_onelake_publish
# ---------------------------------------------------------------------------

def test_maybe_trigger_noop_when_auto_publish_off(monkeypatch):
    settings = {"onelake_data": {**ONELAKE_CONFIGURED_SETTINGS["onelake_data"], "auto_publish_after_scan": False}}
    monkeypatch.setattr(sm, "_load_admin_settings", lambda: settings)
    sm._maybe_trigger_onelake_publish()
    assert sm._scan_queue == []


def test_maybe_trigger_noop_when_not_configured(monkeypatch):
    settings = {"onelake_data": {"auto_publish_after_scan": True, "workspace_name": "", "lakehouse_name": ""}}
    monkeypatch.setattr(sm, "_load_admin_settings", lambda: settings)
    sm._maybe_trigger_onelake_publish()
    assert sm._scan_queue == []


def test_maybe_trigger_enqueues_system_triggered_entry(monkeypatch):
    monkeypatch.setattr(sm, "_load_admin_settings", lambda: ONELAKE_CONFIGURED_SETTINGS)
    sm._maybe_trigger_onelake_publish()
    assert len(sm._scan_queue) == 1
    entry = sm._scan_queue[0]
    assert entry["kind"] == "onelake_publish"
    assert entry["system_triggered"] is True
    assert entry["requested_by_email"] == "system"


def test_maybe_trigger_noop_when_scan_already_running(monkeypatch):
    monkeypatch.setattr(sm, "_load_admin_settings", lambda: ONELAKE_CONFIGURED_SETTINGS)
    with sm._scan_lock:
        sm._scan_state["status"] = "running"
    sm._maybe_trigger_onelake_publish()
    assert sm._scan_queue == []


def test_maybe_trigger_noop_when_queue_full(monkeypatch):
    monkeypatch.setattr(sm, "_load_admin_settings", lambda: ONELAKE_CONFIGURED_SETTINGS)
    monkeypatch.setattr(sm, "MAX_QUEUED_SCANS", 1)
    with sm._scan_lock:
        sm._enqueue_locked("scan", "SomeWorkspace", None, "key-a")
    sm._maybe_trigger_onelake_publish()
    assert len(sm._scan_queue) == 1  # unchanged -- already at the (lowered) cap


# ---------------------------------------------------------------------------
# _start_onelake_publish -- permission gate only, never reaches subprocess
# ---------------------------------------------------------------------------

def test_start_onelake_publish_requires_sign_in_when_anonymous_disabled(monkeypatch):
    monkeypatch.setattr(sm, "_load_admin_settings", lambda: {"allow_anonymous_scans": False})
    result, error = sm._start_onelake_publish(session=None, api_key_name=None)
    assert result is None
    assert error["error"] == "sign_in_required"


def test_start_onelake_publish_rejects_email_outside_full_scan_allowlist(monkeypatch):
    monkeypatch.setattr(sm, "_load_admin_settings", lambda: {"full_scan_emails": ["someone-else@example.com"]})
    result, error = sm._start_onelake_publish(session={"user_email": "outsider@example.com", "session_id": "s1"}, api_key_name=None)
    assert result is None
    assert error["error"] == "not_permitted"


def test_start_onelake_publish_system_triggered_skips_permission_check(monkeypatch, tmp_path):
    monkeypatch.setattr(sm, "_load_admin_settings", lambda: {"full_scan_emails": []})
    monkeypatch.setattr(sm, "_resolve_pwsh_command", lambda: "pwsh")
    monkeypatch.setattr(sm, "STATE_PATH", tmp_path / "state.json")
    monkeypatch.setattr(sm, "STATE_DIR", tmp_path)
    monkeypatch.setattr(sm, "QUEUE_PATH", tmp_path / "queue.json")
    # A scan is already "running" so this stops at the queued branch, well
    # before ever reaching subprocess.Popen -- exercises the permission
    # bypass without spawning anything real.
    with sm._scan_lock:
        sm._scan_state["status"] = "running"
    result, error = sm._start_onelake_publish(session=None, api_key_name=None, system_triggered=True)
    assert error is None
    assert result["status"] == "queued"
    assert result["workspace"] == sm.ONELAKE_PUBLISH_LABEL


def test_start_onelake_publish_queues_when_scan_already_running(monkeypatch, tmp_path):
    monkeypatch.setattr(sm, "_load_admin_settings", lambda: {"full_scan_emails": ["allowed@example.com"]})
    monkeypatch.setattr(sm, "_resolve_pwsh_command", lambda: "pwsh")
    monkeypatch.setattr(sm, "STATE_PATH", tmp_path / "state.json")
    monkeypatch.setattr(sm, "STATE_DIR", tmp_path)
    monkeypatch.setattr(sm, "QUEUE_PATH", tmp_path / "queue.json")
    with sm._scan_lock:
        sm._scan_state["status"] = "running"
    result, error = sm._start_onelake_publish(session={"user_email": "allowed@example.com", "session_id": "s1"}, api_key_name=None)
    assert error is None
    assert result["status"] == "queued"
    assert len(sm._scan_queue) == 1
    assert sm._scan_queue[0]["kind"] == "onelake_publish"


def test_start_onelake_publish_spawn_failed_when_pwsh_missing(monkeypatch):
    monkeypatch.setattr(sm, "_load_admin_settings", lambda: {"full_scan_emails": ["allowed@example.com"]})
    monkeypatch.setattr(sm, "_resolve_pwsh_command", lambda: None)
    result, error = sm._start_onelake_publish(session={"user_email": "allowed@example.com", "session_id": "s1"}, api_key_name=None)
    assert result is None
    assert error["error"] == "spawn_failed"


# ---------------------------------------------------------------------------
# _wait_for_onelake_publish_process
# ---------------------------------------------------------------------------

class _FakeProc:
    def __init__(self, exit_code):
        self._exit_code = exit_code

    def wait(self):
        return self._exit_code


def test_wait_for_onelake_publish_process_succeeds(monkeypatch, tmp_path):
    monkeypatch.setattr(sm, "STATE_PATH", tmp_path / "state.json")
    monkeypatch.setattr(sm, "STATE_DIR", tmp_path)
    monkeypatch.setattr(sm, "HISTORY_PATH", tmp_path / "history.csv")
    dequeue_calls = []
    monkeypatch.setattr(sm, "_dequeue_and_start_next", lambda: dequeue_calls.append(1))
    with sm._scan_lock:
        sm._scan_state["cancel_requested"] = False
    sm._wait_for_onelake_publish_process(_FakeProc(0), sm._now_iso(), sm.time.time())
    assert sm._scan_state["status"] == "succeeded"
    assert sm._scan_state["exit_code"] == 0
    assert dequeue_calls == [1]
    history_text = (tmp_path / "history.csv").read_text(encoding="utf-8")
    assert sm.ONELAKE_PUBLISH_LABEL in history_text
    assert "succeeded" in history_text


def test_wait_for_onelake_publish_process_records_failure(monkeypatch, tmp_path):
    monkeypatch.setattr(sm, "STATE_PATH", tmp_path / "state.json")
    monkeypatch.setattr(sm, "STATE_DIR", tmp_path)
    monkeypatch.setattr(sm, "HISTORY_PATH", tmp_path / "history.csv")
    monkeypatch.setattr(sm, "_dequeue_and_start_next", lambda: None)
    with sm._scan_lock:
        sm._scan_state["cancel_requested"] = False
    sm._wait_for_onelake_publish_process(_FakeProc(1), sm._now_iso(), sm.time.time())
    assert sm._scan_state["status"] == "failed"
    assert "72_publish_web_data_to_onelake.ps1" in sm._scan_state["last_error"]


def test_wait_for_onelake_publish_process_respects_cancel_requested(monkeypatch, tmp_path):
    monkeypatch.setattr(sm, "STATE_PATH", tmp_path / "state.json")
    monkeypatch.setattr(sm, "STATE_DIR", tmp_path)
    monkeypatch.setattr(sm, "HISTORY_PATH", tmp_path / "history.csv")
    monkeypatch.setattr(sm, "_dequeue_and_start_next", lambda: None)
    with sm._scan_lock:
        sm._scan_state["cancel_requested"] = True
    sm._wait_for_onelake_publish_process(_FakeProc(1), sm._now_iso(), sm.time.time())
    assert sm._scan_state["status"] == "cancelled"


# ---------------------------------------------------------------------------
# _queue_entry_workspace_label
# ---------------------------------------------------------------------------

def test_queue_entry_workspace_label_for_onelake_publish():
    assert sm._queue_entry_workspace_label({"kind": "onelake_publish"}) == sm.ONELAKE_PUBLISH_LABEL


# ---------------------------------------------------------------------------
# _wait_for_process (single-workspace scan) -- this scan
# kind's own local rebuild steps (11/17/21/build_graph_map_index.ps1, see
# scan_single_workspace.ps1) refresh all 5 big JSON files too, same as a
# full scan, so it must trigger OneLake publish on success exactly like
# _wait_for_full_scan_process already does.
# ---------------------------------------------------------------------------

def _isolate_wait_for_process(monkeypatch, tmp_path):
    monkeypatch.setattr(sm, "STATE_PATH", tmp_path / "state.json")
    monkeypatch.setattr(sm, "STATE_DIR", tmp_path)
    monkeypatch.setattr(sm, "HISTORY_PATH", tmp_path / "history.csv")
    monkeypatch.setattr(sm, "PROGRESS_PATH", tmp_path / "progress.json")
    monkeypatch.setattr(sm, "_load_admin_settings", lambda: {})
    monkeypatch.setattr(sm, "_dequeue_and_start_next", lambda: None)


def test_wait_for_process_triggers_both_uploads_on_success(monkeypatch, tmp_path):
    _isolate_wait_for_process(monkeypatch, tmp_path)
    warehouse_calls = []
    onelake_calls = []
    monkeypatch.setattr(sm, "_maybe_trigger_warehouse_upload", lambda: warehouse_calls.append(1))
    monkeypatch.setattr(sm, "_maybe_trigger_onelake_publish", lambda: onelake_calls.append(1))

    sm._wait_for_process(_FakeProc(0), "WS1", sm._now_iso(), sm.time.time())

    assert warehouse_calls == [1]
    assert onelake_calls == [1]
    assert sm._scan_state["status"] == "succeeded"


def test_wait_for_process_skips_both_uploads_on_failure(monkeypatch, tmp_path):
    _isolate_wait_for_process(monkeypatch, tmp_path)
    warehouse_calls = []
    onelake_calls = []
    monkeypatch.setattr(sm, "_maybe_trigger_warehouse_upload", lambda: warehouse_calls.append(1))
    monkeypatch.setattr(sm, "_maybe_trigger_onelake_publish", lambda: onelake_calls.append(1))

    sm._wait_for_process(_FakeProc(1), "WS1", sm._now_iso(), sm.time.time())

    assert warehouse_calls == []
    assert onelake_calls == []
    assert sm._scan_state["status"] == "failed"
