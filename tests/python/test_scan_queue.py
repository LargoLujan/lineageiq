"""Unit tests for the scan queue (Tanda 10) added to
backend/scripts/lineage_web/scan_manager.py. _start_scan/_start_full_scan
themselves still aren't unit tested (see test_mcp_server.py's docstring --
they spawn real subprocesses and need a live `az` session, verified live
instead), but the queue mechanics around them (_enqueue_locked,
_queue_snapshot, _write_scan_queue/_load_scan_queue_from_disk,
_record_queue_entry_failure, _dequeue_and_start_next) are pure/file-local
enough to cover directly here. _dequeue_and_start_next's own tests
monkeypatch _start_scan itself so its orchestration (recurse past a failed
entry, stop once one succeeds) is testable without that same live
dependency.

Run with:
    pytest tests/python/test_scan_queue.py
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import scan_manager as sm  # noqa: E402


def setup_function():
    # Every test starts from a clean slate regardless of test order --
    # _scan_queue/_scan_state are shared module-level state.
    with sm._scan_lock:
        sm._scan_queue.clear()
        sm._scan_state.clear()
        sm._scan_state.update({
            "status": "idle", "workspace": None, "pid": None, "scan_id": None,
            "started_at": None, "ended_at": None, "duration_seconds": None,
            "exit_code": None, "log_path": None, "last_error": None,
            "cancel_requested": False, "started_by_email": None,
        })


def _entry(kind="scan", workspace_name="WS1", session_id=None, api_key_name=None, email="user@example.com"):
    return {
        "queue_id": "qid-test", "kind": kind, "workspace_name": workspace_name,
        "session_id": session_id, "api_key_name": api_key_name,
        "requested_by_email": email, "requested_at": "2026-07-10T00:00:00+00:00",
    }


# ---------------------------------------------------------------------------
# _enqueue_locked
# ---------------------------------------------------------------------------

def test_enqueue_locked_appends_and_returns_position():
    with sm._scan_lock:
        entry, position = sm._enqueue_locked("scan", "WS1", None, "some-key")
    assert position == 1
    assert entry["kind"] == "scan"
    assert entry["workspace_name"] == "WS1"
    assert entry["api_key_name"] == "some-key"
    assert entry["session_id"] is None
    assert entry["requested_by_email"] == "api:some-key"
    assert len(sm._scan_queue) == 1


def test_enqueue_locked_uses_session_email_and_id():
    session = {"user_email": "user@example.com", "session_id": "sess-1"}
    with sm._scan_lock:
        entry, _position = sm._enqueue_locked("full_scan", None, session, None)
    assert entry["session_id"] == "sess-1"
    assert entry["requested_by_email"] == "user@example.com"


def test_enqueue_locked_anonymous_when_no_session_or_key():
    with sm._scan_lock:
        entry, _position = sm._enqueue_locked("scan", "WS1", None, None)
    assert entry["requested_by_email"] == "anonymous"
    assert entry["session_id"] is None


# ---------------------------------------------------------------------------
# _queue_snapshot
# ---------------------------------------------------------------------------

def test_queue_snapshot_never_exposes_session_id_or_api_key_name():
    with sm._scan_lock:
        sm._enqueue_locked("scan", "WS1", {"user_email": "a@x.com", "session_id": "secret-session"}, None)
        sm._enqueue_locked("full_scan", None, None, "some-key")
    snapshot = sm._queue_snapshot()
    assert len(snapshot) == 2
    for row in snapshot:
        assert "session_id" not in row
        assert "api_key_name" not in row


def test_queue_snapshot_positions_are_1_based_in_order():
    with sm._scan_lock:
        sm._enqueue_locked("scan", "WS1", None, "key-a")
        sm._enqueue_locked("scan", "WS2", None, "key-b")
    snapshot = sm._queue_snapshot()
    assert [row["position"] for row in snapshot] == [1, 2]
    assert [row["workspace"] for row in snapshot] == ["WS1", "WS2"]


def test_queue_snapshot_full_scan_uses_full_scan_label():
    with sm._scan_lock:
        sm._enqueue_locked("full_scan", None, None, "key-a")
    snapshot = sm._queue_snapshot()
    assert snapshot[0]["workspace"] == sm.FULL_SCAN_LABEL


# ---------------------------------------------------------------------------
# _write_scan_queue / _load_scan_queue_from_disk
# ---------------------------------------------------------------------------

def test_write_and_load_scan_queue_round_trips(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "STATE_DIR", tmp_path)
    monkeypatch.setattr(sm, "QUEUE_PATH", tmp_path / "queue.json")
    with sm._scan_lock:
        sm._enqueue_locked("scan", "WS1", None, "key-a")
    sm._write_scan_queue()

    sm._scan_queue.clear()
    sm._load_scan_queue_from_disk()
    assert len(sm._scan_queue) == 1
    assert sm._scan_queue[0]["workspace_name"] == "WS1"


def test_load_scan_queue_from_disk_ignores_missing_file(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "QUEUE_PATH", tmp_path / "does-not-exist.json")
    sm._scan_queue.clear()
    sm._load_scan_queue_from_disk()  # should not raise
    assert sm._scan_queue == []


def test_load_scan_queue_from_disk_ignores_corrupt_json(tmp_path, monkeypatch):
    queue_path = tmp_path / "queue.json"
    queue_path.write_text("{not valid json", encoding="utf-8")
    monkeypatch.setattr(sm, "QUEUE_PATH", queue_path)
    sm._scan_queue.clear()
    sm._load_scan_queue_from_disk()  # should not raise
    assert sm._scan_queue == []


# ---------------------------------------------------------------------------
# _record_queue_entry_failure
# ---------------------------------------------------------------------------

def test_record_queue_entry_failure_writes_history_and_state(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "STATE_DIR", tmp_path)
    monkeypatch.setattr(sm, "STATE_PATH", tmp_path / "state.json")
    monkeypatch.setattr(sm, "HISTORY_PATH", tmp_path / "history.csv")
    monkeypatch.setattr(sm, "PROGRESS_PATH", tmp_path / "progress.json")

    entry = _entry(workspace_name="WS1", email="a@x.com")
    sm._record_queue_entry_failure(entry, "session_expired", "Session expired.")

    assert sm._scan_state["status"] == "failed"
    assert sm._scan_state["workspace"] == "WS1"
    assert sm._scan_state["started_by_email"] == "a@x.com"
    assert "session_expired" in sm._scan_state["last_error"]
    history_text = (tmp_path / "history.csv").read_text(encoding="utf-8")
    assert "WS1" in history_text
    assert "failed" in history_text


# ---------------------------------------------------------------------------
# _dequeue_and_start_next
# ---------------------------------------------------------------------------

def test_dequeue_and_start_next_noop_when_queue_empty(monkeypatch):
    calls = []
    monkeypatch.setattr(sm, "_start_scan", lambda *a, **k: calls.append(1))
    sm._dequeue_and_start_next()
    assert calls == []


def test_dequeue_and_start_next_noop_when_scan_running(monkeypatch):
    calls = []
    monkeypatch.setattr(sm, "_start_scan", lambda *a, **k: calls.append(1))
    with sm._scan_lock:
        sm._enqueue_locked("scan", "WS1", None, "key-a")
        sm._scan_state["status"] = "running"
    sm._dequeue_and_start_next()
    assert calls == []
    assert len(sm._scan_queue) == 1  # left untouched for a future call


def test_dequeue_and_start_next_records_failure_when_session_expired(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "STATE_DIR", tmp_path)
    monkeypatch.setattr(sm, "QUEUE_PATH", tmp_path / "queue.json")
    monkeypatch.setattr(sm, "STATE_PATH", tmp_path / "state.json")
    monkeypatch.setattr(sm, "HISTORY_PATH", tmp_path / "history.csv")
    monkeypatch.setattr(sm, "PROGRESS_PATH", tmp_path / "progress.json")
    monkeypatch.setattr(sm, "_get_session", lambda session_id: None)
    calls = []
    monkeypatch.setattr(sm, "_start_scan", lambda *a, **k: calls.append(1))

    with sm._scan_lock:
        sm._enqueue_locked("scan", "WS1", {"user_email": "a@x.com", "session_id": "sess-gone"}, None)

    sm._dequeue_and_start_next()

    assert calls == []  # never reached _start_scan -- failed before that
    assert sm._scan_queue == []  # popped
    assert sm._scan_state["status"] == "failed"
    assert "session_expired" in sm._scan_state["last_error"]


def test_dequeue_and_start_next_recurses_past_failed_entry_to_a_startable_one(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "STATE_DIR", tmp_path)
    monkeypatch.setattr(sm, "QUEUE_PATH", tmp_path / "queue.json")
    monkeypatch.setattr(sm, "STATE_PATH", tmp_path / "state.json")
    monkeypatch.setattr(sm, "HISTORY_PATH", tmp_path / "history.csv")
    monkeypatch.setattr(sm, "PROGRESS_PATH", tmp_path / "progress.json")
    monkeypatch.setattr(
        sm, "_get_session",
        lambda session_id: None if session_id == "sess-gone" else {"user_email": "b@x.com", "session_id": session_id},
    )
    calls = []

    def fake_start_scan(workspace_name, session, api_key_name=None):
        calls.append((workspace_name, session, api_key_name))
        return {"status": "started", "workspace": workspace_name}, None

    monkeypatch.setattr(sm, "_start_scan", fake_start_scan)

    with sm._scan_lock:
        sm._enqueue_locked("scan", "WS1", {"user_email": "a@x.com", "session_id": "sess-gone"}, None)
        sm._enqueue_locked("scan", "WS2", {"user_email": "b@x.com", "session_id": "sess-ok"}, None)

    sm._dequeue_and_start_next()

    assert len(calls) == 1
    assert calls[0][0] == "WS2"
    assert sm._scan_queue == []


def test_dequeue_and_start_next_records_failure_from_start_scan_error(tmp_path, monkeypatch):
    monkeypatch.setattr(sm, "STATE_DIR", tmp_path)
    monkeypatch.setattr(sm, "QUEUE_PATH", tmp_path / "queue.json")
    monkeypatch.setattr(sm, "STATE_PATH", tmp_path / "state.json")
    monkeypatch.setattr(sm, "HISTORY_PATH", tmp_path / "history.csv")
    monkeypatch.setattr(sm, "PROGRESS_PATH", tmp_path / "progress.json")
    monkeypatch.setattr(sm, "_get_session", lambda session_id: {"user_email": "a@x.com", "session_id": session_id})
    monkeypatch.setattr(
        sm, "_start_scan",
        lambda *a, **k: (None, {"error": "workspace_not_found", "message": "gone"}),
    )

    with sm._scan_lock:
        sm._enqueue_locked("scan", "WS1", {"user_email": "a@x.com", "session_id": "sess-ok"}, None)

    sm._dequeue_and_start_next()

    assert sm._scan_queue == []
    assert sm._scan_state["status"] == "failed"
    assert "workspace_not_found" in sm._scan_state["last_error"]
