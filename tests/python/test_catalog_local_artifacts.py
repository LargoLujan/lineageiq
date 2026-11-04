"""Unit tests for catalog.py's 6 local-artifact catalog reads ported from
mcp_server.py's local-only MCP tools:
_get_related_elements, _get_objects_for_item, _get_workspace_roles,
_get_execution_stats, _get_failure_hotspots, _get_schedules. Query
semantics mirror mcp_server.py's originals exactly -- these tests assert
the same behavior, just reached through catalog.py (and therefore the
REST API / remote MCP server) instead of only a local stdio MCP process.

Run with: pytest tests/python/test_catalog_local_artifacts.py
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import catalog  # noqa: E402


def _item(qualified_name, item_name, item_type="Notebook", workspace_name="WS1"):
    return {"qualified_name": qualified_name, "item_name": item_name, "item_type": item_type, "workspace_name": workspace_name}


# --- _get_related_elements --------------------------------------------

def test_related_elements_returns_not_found_for_no_match(monkeypatch):
    monkeypatch.setattr(catalog, "_item_rows", lambda: [_item("WS1 / Notebook / A", "A")])
    result = catalog._get_related_elements("zzz")
    assert result == {"found": False, "candidates": []}


def test_related_elements_returns_candidates_when_ambiguous(monkeypatch):
    monkeypatch.setattr(catalog, "_item_rows", lambda: [
        _item("WS1 / Notebook / Alpha", "Alpha"),
        _item("WS1 / Report / Alpha", "Alpha", item_type="Report"),
    ])
    result = catalog._get_related_elements("Alpha")
    assert result["found"] is False
    assert result["reason"] == "ambiguous_query"
    assert len(result["candidates"]) == 2


def test_related_elements_traverses_upstream_and_downstream(monkeypatch):
    monkeypatch.setattr(catalog, "_relationship_index_cache", None)
    monkeypatch.setattr(catalog, "_item_rows", lambda: [_item("WS1 / Notebook / B", "B")])
    monkeypatch.setattr(catalog, "_dependency_rows", lambda: [
        {"from_qualified_name": "WS1 / Notebook / B", "to_qualified_name": "WS1 / Lakehouse / Src", "relationship_type": "reads_from", "confidence": "confirmed"},
        {"from_qualified_name": "WS1 / Report / Rep", "to_qualified_name": "WS1 / Notebook / B", "relationship_type": "uses_model", "confidence": "likely"},
    ])
    monkeypatch.setattr(catalog, "_item_link_fields", lambda qn: {"technical_id": "", "workspace_id": "", "fabric_url": ""})

    result = catalog._get_related_elements("WS1 / Notebook / B")
    assert result["found"] is True
    assert [row["qualified_name"] for row in result["upstream"]] == ["WS1 / Lakehouse / Src"]
    assert [row["qualified_name"] for row in result["downstream"]] == ["WS1 / Report / Rep"]


def test_related_elements_direction_filters_which_side_is_computed(monkeypatch):
    monkeypatch.setattr(catalog, "_relationship_index_cache", None)
    monkeypatch.setattr(catalog, "_item_rows", lambda: [_item("WS1 / Notebook / B", "B")])
    monkeypatch.setattr(catalog, "_dependency_rows", lambda: [
        {"from_qualified_name": "WS1 / Notebook / B", "to_qualified_name": "WS1 / Lakehouse / Src", "relationship_type": "reads_from", "confidence": "confirmed"},
    ])
    monkeypatch.setattr(catalog, "_item_link_fields", lambda qn: {"technical_id": "", "workspace_id": "", "fabric_url": ""})

    result = catalog._get_related_elements("WS1 / Notebook / B", direction="upstream")
    assert "upstream" in result
    assert "downstream" not in result


# --- _get_objects_for_item ----------------------------------------------

def test_objects_for_item_returns_reason_when_index_missing(monkeypatch):
    monkeypatch.setattr(catalog, "_item_rows", lambda: [_item("WS1 / Notebook / B", "B")])
    monkeypatch.setattr(catalog, "_read_json_file", lambda path: None)
    result = catalog._get_objects_for_item("WS1 / Notebook / B")
    assert result["found"] is False
    assert "graph-map-index-objects.json" in result["reason"]


def test_objects_for_item_returns_matching_objects(monkeypatch):
    monkeypatch.setattr(catalog, "_item_rows", lambda: [_item("WS1 / Notebook / B", "B")])
    graph = {
        "by_item_id": {"WS1 / Notebook / B": [0]},
        "nodes": [{"data": {"id": "obj1", "label": "dbo.Customers", "source_type": "SQL", "source_server": "sqlsrv", "source_database": "CoreDB", "column_count": 5}}],
        "edges": [{"data": {"source": "obj1", "relationship_type": "reads_from", "confidence": "confirmed"}}],
    }
    monkeypatch.setattr(catalog, "_read_json_file", lambda path: graph)
    result = catalog._get_objects_for_item("WS1 / Notebook / B")
    assert result["found"] is True
    assert result["object_count"] == 1
    assert result["objects"][0]["object_display_name"] == "dbo.Customers"


# --- _get_workspace_roles -------------------------------------------------

def test_workspace_roles_returns_reason_when_no_rows(monkeypatch):
    monkeypatch.setattr(catalog, "_read_csv_rows", lambda path: [])
    result = catalog._get_workspace_roles("WS1")
    assert result["found"] is False
    assert "workspace_role_assignments.csv" in result["reason"]


def test_workspace_roles_matches_exact_then_excludes_removed_status(monkeypatch):
    rows = [
        {"workspace_name": "Sales_Contoso_Pro", "principal_name": "alice@x.com", "principal_type": "User", "role": "Admin", "status": "discovered"},
        {"workspace_name": "Sales_Contoso_Pro", "principal_name": "removed@x.com", "principal_type": "User", "role": "Member", "status": "removed"},
    ]
    monkeypatch.setattr(catalog, "_read_csv_rows", lambda path: rows)
    result = catalog._get_workspace_roles("sales_contoso_pro")
    assert result["found"] is True
    assert result["assignment_count"] == 1
    assert result["assignments"][0]["principal_name"] == "alice@x.com"


# --- _get_execution_stats -------------------------------------------------

def test_execution_stats_returns_not_found_when_no_rows(monkeypatch):
    monkeypatch.setattr(catalog, "_read_csv_rows", lambda path: [])
    result = catalog._get_execution_stats("orders")
    assert result["found"] is False


def test_execution_stats_filters_by_item_name_and_respects_limit(monkeypatch):
    rows = [
        {"workspace_name": "WS1", "item_name": "NB_Load_Orders", "item_type": "Notebook", "job_type": "RunNotebook", "run_count": "10", "failed_count": "1"},
        {"workspace_name": "WS1", "item_name": "NB_Load_Orders_V2", "item_type": "Notebook", "job_type": "RunNotebook", "run_count": "5", "failed_count": "0"},
        {"workspace_name": "WS1", "item_name": "PL_Refresh", "item_type": "DataPipeline", "job_type": "Pipeline", "run_count": "3", "failed_count": "0"},
    ]
    monkeypatch.setattr(catalog, "_read_csv_rows", lambda path: rows)
    result = catalog._get_execution_stats("orders", limit=1)
    assert result["found"] is True
    assert result["total_matches"] == 2
    assert len(result["items"]) == 1


# --- _get_failure_hotspots -------------------------------------------------

def test_failure_hotspots_respects_limit_and_field_order(monkeypatch):
    rows = [
        {"workspace_name": "WS1", "item_name": "A", "item_type": "Notebook", "job_type": "RunNotebook", "run_count": "10", "failed_count": "9", "failure_rate": "0.9"},
        {"workspace_name": "WS1", "item_name": "B", "item_type": "Notebook", "job_type": "RunNotebook", "run_count": "10", "failed_count": "1", "failure_rate": "0.1"},
    ]
    monkeypatch.setattr(catalog, "_read_csv_rows", lambda path: rows)
    result = catalog._get_failure_hotspots(limit=1)
    assert len(result) == 1
    assert result[0]["item_name"] == "A"


# --- _get_schedules -------------------------------------------------

def test_schedules_returns_not_found_when_no_rows(monkeypatch):
    monkeypatch.setattr(catalog, "_read_csv_rows", lambda path: [])
    result = catalog._get_schedules()
    assert result["found"] is False


def test_schedules_filters_by_query_and_workspace(monkeypatch):
    rows = [
        {"workspace_name": "Sales_Contoso_Pro", "item_name": "PL_Refresh_Orders", "item_type": "DataPipeline", "enabled_schedules": "1"},
        {"workspace_name": "Marketing_Contoso_Pro", "item_name": "PL_Refresh_Leads", "item_type": "DataPipeline", "enabled_schedules": "1"},
    ]
    monkeypatch.setattr(catalog, "_read_csv_rows", lambda path: rows)
    result = catalog._get_schedules(query="refresh", workspace_name="sales")
    assert result["found"] is True
    assert result["total_matches"] == 1
    assert result["items"][0]["item_name"] == "PL_Refresh_Orders"
