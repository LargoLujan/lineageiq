"""Unit tests for catalog.py's live-Warehouse object-impact search
(2026-07-24): _get_object_impact should prefer dbo.bronze_item_object_
lineage_candidates + dbo.bronze_pipeline_object_lineage_candidates when
lakehouse.web_read_mode == "warehouse", falling back to the pre-built
object-impact.json otherwise or on any Warehouse failure.

Run with: pytest tests/python/test_catalog_object_impact_warehouse.py
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import catalog, warehouse  # noqa: E402


def _item_row(item_qualified_name, item_name, item_type, workspace_name, object_name,
              schema_name="dbo", source_database="CoreDB", source_server="sqlsrv",
              confidence="confirmed", usage_type="reads_from"):
    return {
        "workspace_name": workspace_name, "workspace_environment": "PRO", "item_type": item_type,
        "item_name": item_name, "item_qualified_name": item_qualified_name,
        "source_type": "SQL", "source_name": source_database, "source_qualified_name": "",
        "source_server": source_server, "source_database": source_database, "schema_name": schema_name,
        "object_name": object_name, "object_type": "table_or_view", "usage_type": usage_type,
        "confidence": confidence, "definition_path": "x", "evidence": "test evidence",
    }


def test_object_impact_falls_back_to_local_when_warehouse_mode_off(monkeypatch):
    monkeypatch.setattr(warehouse, "is_warehouse_read_enabled", lambda: False)
    monkeypatch.setattr(catalog, "_read_json_file", lambda path: None)
    result = catalog._get_object_impact("Customers")
    assert result == {"found": False, "reason": "object-impact.json not built yet -- run the 11 -> 17 -> 21 chain."}


def test_object_impact_uses_warehouse_candidates_when_enabled(monkeypatch):
    monkeypatch.setattr(warehouse, "is_warehouse_read_enabled", lambda: True)

    item_rows = [_item_row("WS1 / Notebook / NB_Load", "NB_Load", "Notebook", "WS1", "Customers")]
    pipeline_rows = [_item_row("WS1 / DataPipeline / PL_Refresh", "PL_Refresh", "DataPipeline", "WS1", "Customers", usage_type="writes_to", confidence="likely")]

    def fake_query(table_name, use_cache=True):
        if table_name == "bronze_item_object_lineage_candidates":
            return item_rows
        if table_name == "bronze_pipeline_object_lineage_candidates":
            return pipeline_rows
        return []  # bronze_items/bronze_workspaces: _item_link_fields tolerates an empty index fine

    monkeypatch.setattr(warehouse, "query_bronze_table", fake_query)

    result = catalog._get_object_impact("Customers")
    assert result["found"] is True
    assert result["total_matches"] == 1
    obj = result["objects"][0]
    assert obj["object_display_name"] == "CoreDB.dbo.Customers"
    assert obj["affected_item_count"] == 2
    assert obj["downstream_report_count"] == 0
    assert obj["column_count"] == 0
    consumer_names = {c["qualified_name"] for c in obj["direct_consumers"]}
    assert consumer_names == {"WS1 / Notebook / NB_Load", "WS1 / DataPipeline / PL_Refresh"}


def test_object_impact_search_is_substring_and_case_insensitive(monkeypatch):
    monkeypatch.setattr(warehouse, "is_warehouse_read_enabled", lambda: True)
    rows = [_item_row("WS1 / Notebook / NB_Load", "NB_Load", "Notebook", "WS1", "OrderList")]
    monkeypatch.setattr(warehouse, "query_bronze_table", lambda table_name, use_cache=True: rows if table_name == "bronze_item_object_lineage_candidates" else [])
    monkeypatch.setattr(catalog, "_workspace_ids_by_name", lambda: {})

    assert catalog._get_object_impact("orderlist")["found"] is True
    assert catalog._get_object_impact("nomatch")["found"] is False


def test_object_impact_falls_back_to_local_on_warehouse_error(monkeypatch):
    monkeypatch.setattr(warehouse, "is_warehouse_read_enabled", lambda: True)

    def raise_error(table_name, use_cache=True):
        raise warehouse.WarehouseQueryError("boom")

    monkeypatch.setattr(warehouse, "query_bronze_table", raise_error)
    monkeypatch.setattr(catalog, "_read_json_file", lambda path: None)

    result = catalog._get_object_impact("Customers")
    assert result == {"found": False, "reason": "object-impact.json not built yet -- run the 11 -> 17 -> 21 chain."}


def test_object_impact_dedupes_same_item_keeping_confirmed_confidence(monkeypatch):
    monkeypatch.setattr(warehouse, "is_warehouse_read_enabled", lambda: True)
    rows = [
        _item_row("WS1 / Notebook / NB_Load", "NB_Load", "Notebook", "WS1", "Customers", confidence="likely", usage_type="reads_from"),
        _item_row("WS1 / Notebook / NB_Load", "NB_Load", "Notebook", "WS1", "Customers", confidence="confirmed", usage_type="writes_to"),
    ]
    monkeypatch.setattr(warehouse, "query_bronze_table", lambda table_name, use_cache=True: rows if table_name == "bronze_item_object_lineage_candidates" else [])
    monkeypatch.setattr(catalog, "_workspace_ids_by_name", lambda: {})

    result = catalog._get_object_impact("Customers")
    obj = result["objects"][0]
    assert obj["affected_item_count"] == 1
    assert obj["direct_consumers"][0]["confidence"] == "confirmed"
