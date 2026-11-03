"""Unit tests for mcp_server_remote.py (Tanda 6, F.2; extended 2026-08-18
with get_business_glossary/get_column_profile/get_column_sensitivity, then
again the same day with get_related_elements/get_objects_for_item/
get_workspace_roles/get_execution_stats/get_failure_hotspots/
get_schedules): the HTTP-backed MCP server that calls the deployed REST
API instead of reading local files. Every test here mocks
urllib.request.urlopen -- this must never make a real network call, same
isolation discipline as the rest of this project's tests.

Run with:
    pytest tests/python/test_mcp_server_remote.py
"""
import io
import json
import sys
import urllib.error
from pathlib import Path
from unittest.mock import MagicMock, patch

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

import mcp_server_remote as m  # noqa: E402


def _fake_response(payload):
    body = json.dumps(payload).encode("utf-8")
    mock_resp = MagicMock()
    mock_resp.read.return_value = body
    mock_resp.__enter__.return_value = mock_resp
    mock_resp.__exit__.return_value = False
    return mock_resp


def test_request_sends_api_key_header_only_when_provided(monkeypatch):
    monkeypatch.setattr(m, "BASE_URL", "https://example.test")
    captured = {}

    def fake_urlopen(req, timeout=None):
        captured["header"] = req.get_header("X-api-key")
        captured["url"] = req.full_url
        return _fake_response({"ok": True})

    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        result = m._request("GET", "/api/workspaces", params={"name_contains": "sales"}, api_key="secret-key")
    assert result == {"ok": True}
    assert captured["header"] == "secret-key"
    assert captured["url"] == "https://example.test/api/workspaces?name_contains=sales"

    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        m._request("GET", "/api/status")
    assert captured["header"] is None


def test_request_omits_empty_params(monkeypatch):
    monkeypatch.setattr(m, "BASE_URL", "https://example.test")
    captured = {}

    def fake_urlopen(req, timeout=None):
        captured["url"] = req.full_url
        return _fake_response({"ok": True})

    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        m._request("GET", "/api/items", params={"query": "x", "item_type": "", "limit": 20})
    assert "item_type" not in captured["url"]
    assert "query=x" in captured["url"]


def test_request_sends_json_body_for_post(monkeypatch):
    monkeypatch.setattr(m, "BASE_URL", "https://example.test")
    captured = {}

    def fake_urlopen(req, timeout=None):
        captured["body"] = json.loads(req.data.decode("utf-8"))
        captured["content_type"] = req.get_header("Content-type")
        return _fake_response({"status": "started", "scan_id": "abc"})

    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        result = m._request("POST", "/api/scan", body={"workspace": "WS1"}, api_key="k")
    assert result == {"status": "started", "scan_id": "abc"}
    assert captured["body"] == {"workspace": "WS1"}
    assert captured["content_type"] == "application/json"


def test_request_returns_json_error_body_on_http_error(monkeypatch):
    monkeypatch.setattr(m, "BASE_URL", "https://example.test")

    def fake_urlopen(req, timeout=None):
        fp = io.BytesIO(b'{"error": "not_signed_in"}')
        raise urllib.error.HTTPError(req.full_url, 401, "Unauthorized", {}, fp)

    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        result = m._request("GET", "/api/workspaces")
    assert result == {"error": "not_signed_in"}


def test_request_falls_back_to_generic_error_on_non_json_error_body(monkeypatch):
    monkeypatch.setattr(m, "BASE_URL", "https://example.test")

    def fake_urlopen(req, timeout=None):
        fp = io.BytesIO(b"<html>502 Bad Gateway</html>")
        raise urllib.error.HTTPError(req.full_url, 502, "Bad Gateway", {}, fp)

    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        result = m._request("GET", "/api/workspaces")
    assert result["error"] == "http_error"
    assert "502" in result["message"]


def test_request_returns_structured_error_on_connection_failure(monkeypatch):
    monkeypatch.setattr(m, "BASE_URL", "https://unreachable.test")

    def fake_urlopen(req, timeout=None):
        raise urllib.error.URLError("Name or service not known")

    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        result = m._request("GET", "/api/workspaces")
    assert result["error"] == "connection_failed"


def test_list_workspaces_unwraps_the_workspaces_key(monkeypatch):
    with patch.object(m, "_request", return_value={"workspaces": [{"workspace_name": "WS1"}], "count": 1}) as mock_request:
        result = m.list_workspaces("sales", api_key="k")
    assert result == [{"workspace_name": "WS1"}]
    mock_request.assert_called_once_with("GET", "/api/workspaces", params={"name_contains": "sales"}, api_key="k")


def test_search_items_unwraps_the_items_key(monkeypatch):
    with patch.object(m, "_request", return_value={"total_matches": 1, "items": [{"item_name": "X"}]}):
        result = m.search_items("x")
    assert result == [{"item_name": "X"}]


def test_get_item_lineage_passes_through_the_raw_result(monkeypatch):
    with patch.object(m, "_request", return_value={"found": True, "item": {}}) as mock_request:
        result = m.get_item_lineage("WS1 / Report / X", api_key="k")
    assert result == {"found": True, "item": {}}
    mock_request.assert_called_once_with("GET", "/api/item-lineage", params={"qualified_name": "WS1 / Report / X"}, api_key="k")


def test_get_column_profile_delegates_with_all_three_params(monkeypatch):
    with patch.object(m, "_request", return_value={"found": False, "columns": []}) as mock_request:
        m.get_column_profile("WS1", "LH1", "dbo.MyTable", api_key="k")
    mock_request.assert_called_once_with("GET", "/api/column-profile", params={
        "workspace_name": "WS1", "lakehouse_name": "LH1", "table_name": "dbo.MyTable",
    }, api_key="k")


def test_get_column_sensitivity_delegates_with_all_three_params(monkeypatch):
    with patch.object(m, "_request", return_value={"found": False, "columns": []}) as mock_request:
        m.get_column_sensitivity("WS1", "LH1", "dbo.MyTable", api_key="k")
    mock_request.assert_called_once_with("GET", "/api/column-sensitivity", params={
        "workspace_name": "WS1", "lakehouse_name": "LH1", "table_name": "dbo.MyTable",
    }, api_key="k")


def test_get_related_elements_delegates_with_all_params(monkeypatch):
    with patch.object(m, "_request", return_value={"found": True, "qualified_name": "WS1 / Notebook / B"}) as mock_request:
        m.get_related_elements("WS1 / Notebook / B", direction="upstream", max_hops=3, limit=50, api_key="k")
    mock_request.assert_called_once_with("GET", "/api/related-elements", params={
        "qualified_name": "WS1 / Notebook / B", "direction": "upstream", "max_hops": 3, "limit": 50,
    }, api_key="k")


def test_get_objects_for_item_delegates(monkeypatch):
    with patch.object(m, "_request", return_value={"found": True, "objects": []}) as mock_request:
        m.get_objects_for_item("WS1 / Notebook / B", api_key="k")
    mock_request.assert_called_once_with("GET", "/api/objects-for-item", params={"qualified_name": "WS1 / Notebook / B"}, api_key="k")


def test_get_workspace_roles_delegates(monkeypatch):
    with patch.object(m, "_request", return_value={"found": True, "assignments": []}) as mock_request:
        m.get_workspace_roles("WS1", api_key="k")
    mock_request.assert_called_once_with("GET", "/api/workspace-roles", params={"workspace_name": "WS1"}, api_key="k")


def test_get_execution_stats_delegates(monkeypatch):
    with patch.object(m, "_request", return_value={"found": True, "items": []}) as mock_request:
        m.get_execution_stats("orders", limit=5, api_key="k")
    mock_request.assert_called_once_with("GET", "/api/execution-stats", params={"query": "orders", "limit": 5}, api_key="k")


def test_get_failure_hotspots_unwraps_the_hotspots_key(monkeypatch):
    with patch.object(m, "_request", return_value={"hotspots": [{"item_name": "A"}], "count": 1}) as mock_request:
        result = m.get_failure_hotspots(limit=5, api_key="k")
    assert result == [{"item_name": "A"}]
    mock_request.assert_called_once_with("GET", "/api/failure-hotspots", params={"limit": 5}, api_key="k")


def test_get_schedules_delegates(monkeypatch):
    with patch.object(m, "_request", return_value={"found": True, "items": []}) as mock_request:
        m.get_schedules(query="refresh", workspace_name="sales", api_key="k")
    mock_request.assert_called_once_with("GET", "/api/schedules", params={"query": "refresh", "workspace_name": "sales"}, api_key="k")


def test_get_business_glossary_delegates(monkeypatch):
    with patch.object(m, "_request", return_value={"terms": []}) as mock_request:
        result = m.get_business_glossary(api_key="k")
    assert result == {"terms": []}
    mock_request.assert_called_once_with("GET", "/api/business-glossary", api_key="k")


def test_trigger_scan_marks_started_false_on_error(monkeypatch):
    with patch.object(m, "_request", return_value={"error": "invalid_api_key"}):
        result = m.trigger_scan("WS1", api_key="bad")
    assert result["started"] is False
    assert result["error"] == "invalid_api_key"


def test_trigger_scan_marks_started_true_on_success(monkeypatch):
    with patch.object(m, "_request", return_value={"status": "started", "scan_id": "abc"}):
        result = m.trigger_scan("WS1", api_key="k")
    assert result["started"] is True
    assert result["scan_id"] == "abc"
