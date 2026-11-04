"""Unit tests for backend/scripts/lineage_web/analytics.py (lineage-usage
analytics behind the admin panel's "Analíticas" tab). record_usage_event/get_usage_analytics both go through
warehouse.append_bronze_rows/query_bronze_table -- mocked here rather than
hitting a real Warehouse, same pattern as test_notifications.py's smtplib/
urllib mocks.
"""
import sys
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import analytics  # noqa: E402
from lineage_web import warehouse  # noqa: E402


@patch("lineage_web.analytics.warehouse.append_bronze_rows")
def test_record_usage_event_writes_expected_row(mock_append):
    session = {"user_email": "user@example.com"}
    analytics.record_usage_event("item_view", "WS/Report/MyReport", "Report", session)
    mock_append.assert_called_once()
    table_name, columns, rows = mock_append.call_args[0][:3]
    assert table_name == "bronze_usage_events"
    assert columns == analytics.USAGE_EVENT_COLUMNS
    assert rows[0]["event_type"] == "item_view"
    assert rows[0]["qualified_name"] == "WS/Report/MyReport"
    assert rows[0]["item_type"] == "Report"
    assert rows[0]["user_email"] == "user@example.com"
    assert rows[0]["occurred_at"]


@patch("lineage_web.analytics.warehouse.append_bronze_rows")
def test_record_usage_event_no_session_records_empty_email(mock_append):
    analytics.record_usage_event("item_view", "WS/Report/MyReport", "Report", None)
    _table, _columns, rows = mock_append.call_args[0][:3]
    assert rows[0]["user_email"] == ""


@patch("lineage_web.analytics.warehouse.append_bronze_rows")
def test_record_usage_event_unknown_type_is_dropped_silently(mock_append):
    analytics.record_usage_event("not_a_real_event_type", "WS/Report/X", "Report", {"user_email": "u@example.com"})
    mock_append.assert_not_called()


@patch("lineage_web.analytics.warehouse.append_bronze_rows")
def test_record_usage_event_truncates_long_qualified_name(mock_append):
    long_name = "x" * 5000
    analytics.record_usage_event("item_view", long_name, "Report", {"user_email": "u@example.com"})
    _table, _columns, rows = mock_append.call_args[0][:3]
    assert len(rows[0]["qualified_name"]) == analytics.MAX_QUALIFIED_NAME_LENGTH


@patch("lineage_web.analytics.warehouse.append_bronze_rows")
def test_record_usage_event_never_raises_on_warehouse_error(mock_append):
    mock_append.side_effect = warehouse.WarehouseError("connection failed")
    analytics.record_usage_event("item_view", "WS/Report/X", "Report", {"user_email": "u@example.com"})  # must not raise


@patch("lineage_web.analytics.warehouse.query_bronze_table")
def test_get_usage_analytics_not_found_when_empty(mock_query):
    mock_query.return_value = []
    result = analytics.get_usage_analytics()
    assert result["found"] is False


@patch("lineage_web.analytics.warehouse.query_bronze_table")
def test_get_usage_analytics_not_found_on_warehouse_error(mock_query):
    mock_query.side_effect = warehouse.WarehouseError("down")
    result = analytics.get_usage_analytics()
    assert result["found"] is False
    assert "down" in result["reason"]


@patch("lineage_web.analytics.warehouse.query_bronze_table")
def test_get_usage_analytics_aggregates_top_items_and_users(mock_query):
    mock_query.return_value = [
        {"event_type": "item_view", "qualified_name": "WS/A", "item_type": "Report", "user_email": "u1@example.com", "occurred_at": "2026-08-20T10:00:00"},
        {"event_type": "item_view", "qualified_name": "WS/A", "item_type": "Report", "user_email": "u2@example.com", "occurred_at": "2026-08-20T11:00:00"},
        {"event_type": "item_view", "qualified_name": "WS/B", "item_type": "SemanticModel", "user_email": "u1@example.com", "occurred_at": "2026-08-21T09:00:00"},
    ]
    result = analytics.get_usage_analytics(top_n=5)
    assert result["found"] is True
    assert result["total_event_count"] == 3
    assert result["unique_user_count"] == 2
    assert result["top_items"][0] == {"qualified_name": "WS/A", "item_type": "Report", "view_count": 2}
    assert result["top_items"][1] == {"qualified_name": "WS/B", "item_type": "SemanticModel", "view_count": 1}


@patch("lineage_web.analytics.warehouse.query_bronze_table")
def test_get_usage_analytics_daily_series_sorted_ascending(mock_query):
    mock_query.return_value = [
        {"event_type": "item_view", "qualified_name": "A", "item_type": "Report", "user_email": "u@x.com", "occurred_at": "2026-08-22T10:00:00"},
        {"event_type": "item_view", "qualified_name": "B", "item_type": "Report", "user_email": "u@x.com", "occurred_at": "2026-08-20T10:00:00"},
        {"event_type": "item_view", "qualified_name": "C", "item_type": "Report", "user_email": "u@x.com", "occurred_at": "2026-08-20T15:00:00"},
    ]
    result = analytics.get_usage_analytics()
    assert [d["day"] for d in result["daily_series"]] == ["2026-08-20", "2026-08-22"]
    assert result["daily_series"][0]["count"] == 2


@patch("lineage_web.analytics.warehouse.query_bronze_table")
def test_get_usage_analytics_respects_top_n_limit(mock_query):
    mock_query.return_value = [
        {"event_type": "item_view", "qualified_name": f"WS/Item{i}", "item_type": "Report", "user_email": "u@x.com", "occurred_at": "2026-08-20T10:00:00"}
        for i in range(15)
    ]
    result = analytics.get_usage_analytics(top_n=10)
    assert len(result["top_items"]) == 10
