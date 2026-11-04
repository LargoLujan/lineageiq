"""Unit tests for catalog.py's _get_column_sensitivity:
content-based sensitivity signals for Fabric-native
Lakehouse tables, read from dbo.bronze_column_sensitivity_content. No
local CSV fallback exists for this table (only ever produced by the
Fabric-native NB_Discover_Column_Sensitivity.py notebook), so every test
here mocks warehouse.query_bronze_table directly.

Run with: pytest tests/python/test_catalog_column_sensitivity.py
"""
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import catalog, warehouse  # noqa: E402


def _sensitivity_row(workspace_name, lakehouse_name, table_name, column_name, category,
                      data_type="varchar", sample_size="200", match_count="180", match_percentage="90.0"):
    return {
        "workspace_name": workspace_name, "lakehouse_name": lakehouse_name, "table_name": table_name,
        "column_name": column_name, "data_type": data_type, "category": category,
        "sample_size": sample_size, "match_count": match_count, "match_percentage": match_percentage,
        "checked_at": "2026-08-17T21:00:00Z",
    }


def test_returns_not_found_when_no_rows_match(monkeypatch):
    monkeypatch.setattr(warehouse, "query_bronze_table", lambda table_name, use_cache=True: [
        _sensitivity_row("WS1", "LH1", "dbo.Other", "col1", "email"),
    ])
    result = catalog._get_column_sensitivity("WS1", "LH1", "dbo.MyTable")
    assert result == {"found": False, "columns": []}


def test_groups_multiple_categories_under_the_same_column(monkeypatch):
    rows = [
        _sensitivity_row("WS1", "LH1", "dbo.MyTable", "contact", "email", match_percentage="85.0"),
        _sensitivity_row("WS1", "LH1", "dbo.MyTable", "contact", "phone", match_percentage="10.0"),
        _sensitivity_row("WS1", "LH1", "dbo.MyTable", "national_id_col", "national_id", match_percentage="95.0"),
        _sensitivity_row("WS1", "LH1", "dbo.OtherTable", "unrelated", "email"),
    ]
    monkeypatch.setattr(warehouse, "query_bronze_table", lambda table_name, use_cache=True: rows)
    result = catalog._get_column_sensitivity("ws1", "lh1", "DBO.MYTABLE")
    assert result["found"] is True
    assert result["checked_at"] == "2026-08-17T21:00:00Z"
    assert {c["column_name"] for c in result["columns"]} == {"contact", "national_id_col"}

    contact_col = next(c for c in result["columns"] if c["column_name"] == "contact")
    categories = {c["category"]: c["match_percentage"] for c in contact_col["categories"]}
    assert categories == {"email": 85.0, "phone": 10.0}


def test_degrades_gracefully_on_warehouse_error(monkeypatch):
    def raise_error(table_name, use_cache=True):
        raise warehouse.WarehouseError("boom")
    monkeypatch.setattr(warehouse, "query_bronze_table", raise_error)
    result = catalog._get_column_sensitivity("WS1", "LH1", "dbo.MyTable")
    assert result == {"found": False, "columns": []}
