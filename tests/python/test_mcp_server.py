"""Unit tests for mcp_server.py's new write-tool support logic (Tanda 6,
F.1). Only _resolve_api_key_name is covered here: it's pure validation
logic with no subprocess/live Azure dependency. trigger_scan/
trigger_full_scan/stop_scan themselves are not unit tested for the same
reason backend/scripts/lineage_web/scan_manager.py's own _start_scan/
_start_full_scan/_stop_scan aren't (see test_lineage_web_server.py's
docstring) -- they spawn real subprocesses and need a live `az` session,
so they're verified live/manually instead.

Run with:
    pytest tests/python/test_mcp_server.py
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

import mcp_server  # noqa: E402
from lineage_web import catalog  # noqa: E402


# --- catalog.py delegation (2026-08-17, roadmap Fase 2/Tanda 6 F.2) ---
# list_workspaces/search_items/get_item_lineage/get_object_impact/
# get_notebook_code now call straight into catalog.py's own functions (the
# same live-Warehouse-when-enabled path the REST API uses) instead of
# reading index/*.csv directly -- see mcp_server.py's module docstring for
# why. These tests just confirm the wiring, not catalog.py's own logic
# (already covered by test_lineage_web_server.py where applicable).

def test_list_workspaces_delegates_to_catalog(monkeypatch):
    monkeypatch.setattr(catalog, "_list_workspaces", lambda name_contains="": [{"workspace_name": "WS1"}])
    assert mcp_server.list_workspaces("WS1") == [{"workspace_name": "WS1"}]


def test_search_items_delegates_to_catalog_and_unwraps_items(monkeypatch):
    monkeypatch.setattr(catalog, "_search_items", lambda query, item_type="", limit=20: {"total_matches": 1, "items": [{"qualified_name": "A"}]})
    assert mcp_server.search_items("A") == [{"qualified_name": "A"}]


def test_get_item_lineage_delegates_to_catalog(monkeypatch):
    monkeypatch.setattr(catalog, "_get_item_lineage", lambda qualified_name: {"found": True, "item": {"qualified_name": qualified_name}})
    assert mcp_server.get_item_lineage("A") == {"found": True, "item": {"qualified_name": "A"}}


def test_get_object_impact_delegates_to_catalog(monkeypatch):
    monkeypatch.setattr(catalog, "_get_object_impact", lambda query, limit=5: {"found": True, "objects": [], "limit_seen": limit})
    assert mcp_server.get_object_impact("cliente", limit=3) == {"found": True, "objects": [], "limit_seen": 3}


def test_get_notebook_code_delegates_to_catalog(monkeypatch):
    monkeypatch.setattr(catalog, "_get_notebook_code", lambda qualified_name, max_chars: {"found": True, "max_chars_seen": max_chars})
    result = mcp_server.get_notebook_code("NB_Test", max_chars=123)
    assert result == {"found": True, "max_chars_seen": 123}


def test_resolve_api_key_name_with_no_key_falls_through():
    key_name, error = mcp_server._resolve_api_key_name("")
    assert key_name is None
    assert error is None


def test_resolve_api_key_name_with_none_falls_through():
    key_name, error = mcp_server._resolve_api_key_name(None)
    assert key_name is None
    assert error is None


def test_resolve_api_key_name_rejects_an_unknown_key():
    key_name, error = mcp_server._resolve_api_key_name("definitely-not-a-real-key")
    assert key_name is None
    assert error is not None
    assert error["error"] == "invalid_api_key"


# --- scope enforcement (2026-08-18 code review finding): this local stdio
# server's write tools (trigger_scan/trigger_full_scan/stop_scan) call
# _start_scan/_start_full_scan/_stop_scan directly, bypassing handler.py's
# REST-only _resolve_scan_caller entirely -- a "read_only" key (the admin
# panel's own recommended scope for an agent) must still be refused here,
# or the whole point of the scope feature is moot for exactly the local-
# MCP-agent use case it was built for. ---

def test_resolve_api_key_name_accepts_a_full_scope_key(monkeypatch):
    from lineage_web import utils
    key_hash = utils._hash_api_key("flm_full_test")
    monkeypatch.setattr(mcp_server, "_load_admin_settings", lambda: {
        "api_keys": [{"name": "full-key", "key_hash": key_hash, "scope": "full"}]
    })
    key_name, error = mcp_server._resolve_api_key_name("flm_full_test")
    assert key_name == "full-key"
    assert error is None


def test_resolve_api_key_name_rejects_a_read_only_key(monkeypatch):
    from lineage_web import utils
    key_hash = utils._hash_api_key("flm_ro_test")
    monkeypatch.setattr(mcp_server, "_load_admin_settings", lambda: {
        "api_keys": [{"name": "ro-key", "key_hash": key_hash, "scope": "read_only"}]
    })
    key_name, error = mcp_server._resolve_api_key_name("flm_ro_test")
    assert key_name is None
    assert error["error"] == "insufficient_scope"


def test_resolve_api_key_name_accepts_a_legacy_key_with_no_scope_field(monkeypatch):
    from lineage_web import utils
    key_hash = utils._hash_api_key("flm_legacy_test")
    monkeypatch.setattr(mcp_server, "_load_admin_settings", lambda: {
        "api_keys": [{"name": "legacy-key", "key_hash": key_hash}]
    })
    key_name, error = mcp_server._resolve_api_key_name("flm_legacy_test")
    assert key_name == "legacy-key"
    assert error is None


# --- _traverse_relationship_index (2026-07-09, get_related_elements) ---
# Pure BFS logic over a hand-built synthetic index -- unlike
# get_related_elements itself (reads real index/items.csv +
# index/dependencies.csv), this doesn't touch disk, so it's tested here the
# same way _resolve_api_key_name is: in isolation, not live.

def _fake_relationship_index(monkeypatch, outgoing, incoming):
    monkeypatch.setattr(mcp_server, "_relationship_index_cache", {"outgoing": outgoing, "incoming": incoming})


def test_traverse_relationship_index_follows_outgoing_for_upstream(monkeypatch):
    # A -> B -> C (A depends on B, B depends on C)
    outgoing = {
        "A": [{"qualified_name": "B", "relationship_type": "depends_on", "confidence": "high"}],
        "B": [{"qualified_name": "C", "relationship_type": "depends_on", "confidence": "high"}],
    }
    _fake_relationship_index(monkeypatch, outgoing, {})
    result = mcp_server._traverse_relationship_index("A", "upstream", max_hops=2, limit=100)
    ids = {row["qualified_name"] for row in result}
    assert ids == {"B", "C"}
    hops = {row["qualified_name"]: row["hops"] for row in result}
    assert hops["B"] == 1
    assert hops["C"] == 2


def test_traverse_relationship_index_respects_max_hops(monkeypatch):
    outgoing = {
        "A": [{"qualified_name": "B", "relationship_type": "depends_on", "confidence": "high"}],
        "B": [{"qualified_name": "C", "relationship_type": "depends_on", "confidence": "high"}],
    }
    _fake_relationship_index(monkeypatch, outgoing, {})
    result = mcp_server._traverse_relationship_index("A", "upstream", max_hops=1, limit=100)
    ids = {row["qualified_name"] for row in result}
    assert ids == {"B"}


def test_traverse_relationship_index_respects_limit(monkeypatch):
    outgoing = {"A": [{"qualified_name": "N%d" % i, "relationship_type": "depends_on", "confidence": ""} for i in range(10)]}
    _fake_relationship_index(monkeypatch, outgoing, {})
    result = mcp_server._traverse_relationship_index("A", "upstream", max_hops=1, limit=3)
    assert len(result) == 3


def test_traverse_relationship_index_downstream_follows_incoming(monkeypatch):
    # X depends on A (edge A<-X in "incoming" terms) -- downstream of A is X.
    incoming = {"A": [{"qualified_name": "X", "relationship_type": "depends_on", "confidence": "high"}]}
    _fake_relationship_index(monkeypatch, {}, incoming)
    result = mcp_server._traverse_relationship_index("A", "downstream", max_hops=1, limit=100)
    assert [row["qualified_name"] for row in result] == ["X"]


def test_traverse_relationship_index_does_not_revisit_a_cycle(monkeypatch):
    # A -> B -> A (a cycle) must terminate and not double-count A.
    outgoing = {
        "A": [{"qualified_name": "B", "relationship_type": "depends_on", "confidence": ""}],
        "B": [{"qualified_name": "A", "relationship_type": "depends_on", "confidence": ""}],
    }
    _fake_relationship_index(monkeypatch, outgoing, {})
    result = mcp_server._traverse_relationship_index("A", "upstream", max_hops=5, limit=100)
    ids = [row["qualified_name"] for row in result]
    assert ids == ["B"]
