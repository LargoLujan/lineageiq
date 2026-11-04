"""Unit tests for backend/scripts/lineage_web/fabric_api.py's
_fetch_all_tenant_workspaces (added alongside the "let a real
Fabric tenant admin's full scan cover literally everything" change to
_start_full_scan). Its sibling functions (_fetch_my_workspaces,
_fetch_lakehouses_in_workspace) are simple single-call wrappers verified
live instead, matching how _start_scan/_start_full_scan themselves are
handled (see test_mcp_server.py's docstring) -- but this one has real
pagination logic (continuationToken) worth locking down with a mocked
urllib.request.urlopen rather than trusting by inspection alone.

Run with:
    pytest tests/python/test_fabric_api.py
"""

import json
import sys
import urllib.error
from io import BytesIO
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web.fabric_api import _fetch_all_tenant_workspaces  # noqa: E402


class _FakeResponse:
    def __init__(self, payload):
        self._body = json.dumps(payload).encode("utf-8")

    def __enter__(self):
        return self

    def __exit__(self, *exc_info):
        return False

    def read(self):
        return self._body


def test_fetch_all_tenant_workspaces_single_page_maps_fields():
    page = {
        "workspaces": [
            {"id": "id-1", "name": "Workspace A", "capacityId": "cap-1", "type": "Workspace"},
        ],
        "continuationToken": None,
    }
    with patch("urllib.request.urlopen", return_value=_FakeResponse(page)):
        workspaces, error = _fetch_all_tenant_workspaces("fake-token")
    assert error is None
    assert workspaces == [
        {"workspace_name": "Workspace A", "workspace_id": "id-1", "capacity_id": "cap-1", "type": "Workspace"},
    ]


def test_fetch_all_tenant_workspaces_paginates_until_no_continuation_token():
    page1 = {
        "workspaces": [{"id": "id-1", "name": "B Workspace", "capacityId": "", "type": "Workspace"}],
        "continuationToken": "token-123",
    }
    page2 = {
        "workspaces": [{"id": "id-2", "name": "A Workspace", "capacityId": "", "type": "Workspace"}],
        "continuationToken": None,
    }
    responses = [_FakeResponse(page1), _FakeResponse(page2)]
    with patch("urllib.request.urlopen", side_effect=lambda *a, **k: responses.pop(0)):
        workspaces, error = _fetch_all_tenant_workspaces("fake-token")
    assert error is None
    # Sorted case-insensitively by name -- "A Workspace" before "B Workspace"
    # even though the second page (id-2) arrived after the first (id-1).
    assert [w["workspace_id"] for w in workspaces] == ["id-2", "id-1"]


def test_fetch_all_tenant_workspaces_second_call_carries_continuation_token():
    page1 = {"workspaces": [], "continuationToken": "token-abc"}
    page2 = {"workspaces": [], "continuationToken": None}
    responses = [_FakeResponse(page1), _FakeResponse(page2)]
    captured_urls = []

    def fake_urlopen(request, timeout=None):
        captured_urls.append(request.full_url)
        return responses.pop(0)

    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        _fetch_all_tenant_workspaces("fake-token")
    assert "continuationToken=token-abc" in captured_urls[1]
    assert "continuationToken" not in captured_urls[0]


def test_fetch_all_tenant_workspaces_filters_to_active_workspaces_server_side():
    captured_urls = []

    def fake_urlopen(request, timeout=None):
        captured_urls.append(request.full_url)
        return _FakeResponse({"workspaces": [], "continuationToken": None})

    with patch("urllib.request.urlopen", side_effect=fake_urlopen):
        _fetch_all_tenant_workspaces("fake-token")
    assert "type=Workspace" in captured_urls[0]
    assert "state=Active" in captured_urls[0]


def test_fetch_all_tenant_workspaces_returns_error_on_403():
    http_error = urllib.error.HTTPError(
        url="https://api.fabric.microsoft.com/v1/admin/workspaces", code=403,
        msg="Forbidden", hdrs=None, fp=BytesIO(b'{"error":{"code":"InsufficientScopes"}}'),
    )
    with patch("urllib.request.urlopen", side_effect=http_error):
        workspaces, error = _fetch_all_tenant_workspaces("fake-token")
    assert workspaces is None
    assert "403" in error


def test_fetch_all_tenant_workspaces_empty_workspaces_key_is_not_an_error():
    with patch("urllib.request.urlopen", return_value=_FakeResponse({"continuationToken": None})):
        workspaces, error = _fetch_all_tenant_workspaces("fake-token")
    assert error is None
    assert workspaces == []
