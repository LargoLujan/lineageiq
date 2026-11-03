"""Unit tests for backend/scripts/build_graph_map_index.py's pure logic --
CSV/JSON-reading integration (the bulk of the script) is verified live by
actually running it against this project's real index/analysis data (see
docs/conversations/) rather than mocked here, matching how test_mcp_server.py
draws the same line.

Run with:
    pytest tests/python/test_build_graph_map_index.py
"""

from datetime import datetime, timezone

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

import build_graph_map_index as m  # noqa: E402


def test_build_execution_health_index_aggregates_across_job_types():
    rows = [
        {"qualified_name": "A", "run_count": "5", "failed_count": "1", "latest_start_time": "01/01/2026 10:00:00", "last_status": "Completed"},
        {"qualified_name": "A", "run_count": "3", "failed_count": "2", "latest_start_time": "02/01/2026 10:00:00", "last_status": "Failed"},
    ]
    health = m.build_execution_health_index(rows)
    assert health["A"]["run_count"] == 8
    assert health["A"]["failed_count"] == 3
    # the later of the two latest_start_time values wins for last_status
    assert health["A"]["last_status"] == "Failed"


def test_build_execution_health_index_skips_rows_without_qualified_name():
    rows = [{"qualified_name": "", "run_count": "5"}]
    health = m.build_execution_health_index(rows)
    assert health == {}


def test_health_fields_for_marks_recent_run_as_not_stale():
    now = datetime.now(timezone.utc)
    recent = now.replace(tzinfo=None)
    health = {"A": {"run_count": 3, "failed_count": 0, "latest_start": recent, "last_status": "Completed"}}
    fields = m.health_fields_for("A", health, now)
    assert fields["exec_is_stale"] is False
    assert fields["exec_last_status"] == "Completed"


def test_health_fields_for_marks_old_run_as_stale():
    now = datetime.now(timezone.utc)
    old = now.replace(tzinfo=None).replace(year=now.year - 1)
    health = {"A": {"run_count": 3, "failed_count": 3, "latest_start": old, "last_status": "Failed"}}
    fields = m.health_fields_for("A", health, now)
    assert fields["exec_is_stale"] is True


def test_health_fields_for_returns_empty_when_item_never_ran():
    now = datetime.now(timezone.utc)
    fields = m.health_fields_for("unknown-item", {}, now)
    assert fields == {}


def test_build_certification_index_keys_by_qualified_name():
    entries = [
        {"qualified_name": "WS/Report/A", "certified_by": "admin@x.com", "note": "official"},
        {"qualified_name": "WS/Report/B", "certified_by": "admin@x.com", "note": ""},
        {"qualified_name": "", "certified_by": "admin@x.com", "note": "no name, skipped"},
    ]
    index = m.build_certification_index(entries)
    assert set(index.keys()) == {"WS/Report/A", "WS/Report/B"}
    assert index["WS/Report/A"]["note"] == "official"


def test_build_tag_index_groups_multiple_tags_per_qualified_name():
    entries = [
        {"qualified_name": "WS/Report/A", "tag": "Finance"},
        {"qualified_name": "WS/Report/A", "tag": "Deprecated"},
        {"qualified_name": "WS/Report/A", "tag": "Finance"},  # duplicate, not repeated
        {"qualified_name": "WS/Report/B", "tag": "Finance"},
        {"qualified_name": "", "tag": "no name, skipped"},
        {"qualified_name": "WS/Report/C", "tag": "  "},  # blank tag, skipped
    ]
    index = m.build_tag_index(entries)
    assert index["WS/Report/A"] == ["Finance", "Deprecated"]
    assert index["WS/Report/B"] == ["Finance"]
    assert "WS/Report/C" not in index
