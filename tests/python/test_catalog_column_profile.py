"""Unit tests for catalog.py's _get_column_profile:
column-level statistical profiling for Fabric-native
Lakehouse tables, read from dbo.bronze_column_profile. No local CSV
fallback exists for this table (it's only ever produced by the
Fabric-native NB_Discover_Column_Profile.py notebook), so every test
here mocks warehouse.query_bronze_table directly.

Run with: pytest tests/python/test_catalog_column_profile.py
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import catalog, warehouse  # noqa: E402


def _profile_row(workspace_name, lakehouse_name, table_name, column_name, data_type,
                  row_count="100", null_count="10", null_percentage="10.0",
                  distinct_count="5", min_value="", max_value=""):
    return {
        "workspace_name": workspace_name, "lakehouse_name": lakehouse_name, "table_name": table_name,
        "column_name": column_name, "data_type": data_type, "row_count": row_count,
        "null_count": null_count, "null_percentage": null_percentage, "distinct_count": distinct_count,
        "min_value": min_value, "max_value": max_value, "profiled_at": "2026-08-17T17:00:00Z",
        "status": "profiled", "notes": "",
    }


def test_returns_not_found_when_no_rows_match(monkeypatch):
    monkeypatch.setattr(warehouse, "query_bronze_table", lambda table_name, use_cache=True: [
        _profile_row("WS1", "LH1", "dbo.Other", "col1", "int"),
    ])
    result = catalog._get_column_profile("WS1", "LH1", "dbo.MyTable")
    assert result == {"found": False, "columns": []}


def test_matches_case_insensitively_and_returns_all_columns_for_the_table(monkeypatch):
    rows = [
        _profile_row("WS1", "LH1", "dbo.MyTable", "id", "int", distinct_count="100", min_value="1", max_value="100"),
        _profile_row("WS1", "LH1", "dbo.MyTable", "name", "varchar", distinct_count="80", min_value="", max_value=""),
        _profile_row("WS1", "LH1", "dbo.OtherTable", "unrelated", "int"),
    ]
    monkeypatch.setattr(warehouse, "query_bronze_table", lambda table_name, use_cache=True: rows)
    result = catalog._get_column_profile("ws1", "lh1", "DBO.MYTABLE")
    assert result["found"] is True
    assert result["profiled_at"] == "2026-08-17T17:00:00Z"
    assert {c["column_name"] for c in result["columns"]} == {"id", "name"}

    id_col = next(c for c in result["columns"] if c["column_name"] == "id")
    assert id_col["min_value"] == "1"
    assert id_col["max_value"] == "100"

    name_col = next(c for c in result["columns"] if c["column_name"] == "name")
    assert name_col["min_value"] is None
    assert name_col["max_value"] is None


def test_degrades_gracefully_on_warehouse_error(monkeypatch):
    def raise_error(table_name, use_cache=True):
        raise warehouse.WarehouseError("boom")
    monkeypatch.setattr(warehouse, "query_bronze_table", raise_error)
    result = catalog._get_column_profile("WS1", "LH1", "dbo.MyTable")
    assert result == {"found": False, "columns": []}
