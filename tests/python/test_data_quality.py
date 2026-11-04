"""Unit tests for backend/scripts/lineage_web/data_quality.py
-- pure aggregation over dbo.bronze_column_profile
rows, so warehouse.query_bronze_table is monkeypatched to return
synthetic profile rows rather than touching a real Warehouse, matching
how test_purview_insights.py tests similar aggregation logic.

Run with:
    pytest tests/python/test_data_quality.py
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import data_quality as m  # noqa: E402


def _patch_profile_rows(monkeypatch, rows):
    monkeypatch.setattr(m, "_profile_rows", lambda: rows)


def _rule(rule_type, threshold, workspace_name="WS", lakehouse_name="LH", table_name="dbo.T", column_name=""):
    return {
        "id": "r1",
        "rule_type": rule_type,
        "workspace_name": workspace_name,
        "lakehouse_name": lakehouse_name,
        "table_name": table_name,
        "column_name": column_name,
        "threshold": threshold,
        "note": "",
    }


def _profile_row(column_name, null_percentage=0.0, distinct_count=10, row_count=100, workspace_name="WS", lakehouse_name="LH", table_name="dbo.T"):
    return {
        "workspace_name": workspace_name,
        "lakehouse_name": lakehouse_name,
        "table_name": table_name,
        "column_name": column_name,
        "null_percentage": null_percentage,
        "distinct_count": distinct_count,
        "row_count": row_count,
    }


# --- _get_data_quality_overview ---

def test_overview_reports_not_found_when_no_rules_defined():
    result = m._get_data_quality_overview({"data_quality_rules": []})
    assert result["found"] is False


def test_overview_passes_a_column_rule_within_threshold(monkeypatch):
    _patch_profile_rows(monkeypatch, [_profile_row("email", null_percentage=2.0)])
    rules = [_rule("null_percentage_max", 5.0, column_name="email")]
    result = m._get_data_quality_overview({"data_quality_rules": rules})
    assert result["found"] is True
    assert result["passed_count"] == 1
    assert result["failed_count"] == 0
    assert result["rules"][0]["status"] == "passed"
    assert result["rules"][0]["actual_value"] == 2.0


def test_overview_fails_a_column_rule_over_threshold(monkeypatch):
    _patch_profile_rows(monkeypatch, [_profile_row("email", null_percentage=40.0)])
    rules = [_rule("null_percentage_max", 5.0, column_name="email")]
    result = m._get_data_quality_overview({"data_quality_rules": rules})
    assert result["passed_count"] == 0
    assert result["failed_count"] == 1
    assert result["rules"][0]["status"] == "failed"


def test_overview_evaluates_distinct_count_min(monkeypatch):
    _patch_profile_rows(monkeypatch, [_profile_row("customer_id", distinct_count=5000)])
    rules = [_rule("distinct_count_min", 1000, column_name="customer_id")]
    result = m._get_data_quality_overview({"data_quality_rules": rules})
    assert result["rules"][0]["status"] == "passed"
    assert result["rules"][0]["actual_value"] == 5000


def test_overview_evaluates_row_count_min_as_table_scoped(monkeypatch):
    # row_count is replicated on every column row of the same table -- a
    # table-scoped rule should resolve it from any matching row, without
    # needing a column_name.
    _patch_profile_rows(monkeypatch, [_profile_row("a", row_count=50), _profile_row("b", row_count=50)])
    rules = [_rule("row_count_min", 10)]
    result = m._get_data_quality_overview({"data_quality_rules": rules})
    assert result["rules"][0]["status"] == "passed"
    assert result["rules"][0]["actual_value"] == 50


def test_overview_marks_unprofiled_target_as_not_profiled_not_failed(monkeypatch):
    _patch_profile_rows(monkeypatch, [])
    rules = [_rule("null_percentage_max", 5.0, column_name="email")]
    result = m._get_data_quality_overview({"data_quality_rules": rules})
    assert result["rules"][0]["status"] == "not_profiled"
    assert result["not_profiled_count"] == 1
    assert result["passed_count"] == 0
    assert result["failed_count"] == 0


def test_overview_pass_rate_excludes_not_profiled_rules_from_denominator(monkeypatch):
    # A coverage gap (table never profiled) must not silently improve the
    # pass rate the way folding it into the denominator as a "pass" or a
    # neutral zero would.
    _patch_profile_rows(monkeypatch, [_profile_row("email", null_percentage=1.0)])
    rules = [
        _rule("null_percentage_max", 5.0, column_name="email"),
        _rule("null_percentage_max", 5.0, column_name="does_not_exist"),
    ]
    result = m._get_data_quality_overview({"data_quality_rules": rules})
    assert result["passed_count"] == 1
    assert result["not_profiled_count"] == 1
    assert result["pass_rate"] == 100.0


def test_overview_pass_rate_is_none_when_every_rule_is_unprofiled(monkeypatch):
    _patch_profile_rows(monkeypatch, [])
    rules = [_rule("null_percentage_max", 5.0, column_name="email")]
    result = m._get_data_quality_overview({"data_quality_rules": rules})
    assert result["pass_rate"] is None


def test_overview_flags_unknown_rule_type_as_invalid_rather_than_crashing(monkeypatch):
    _patch_profile_rows(monkeypatch, [])
    rules = [_rule("not_a_real_rule_type", 5.0, column_name="email")]
    result = m._get_data_quality_overview({"data_quality_rules": rules})
    assert result["rules"][0]["status"] == "invalid_rule"


# --- _get_data_quality_for_table ---

def test_for_table_reports_not_found_when_no_rule_targets_it(monkeypatch):
    _patch_profile_rows(monkeypatch, [])
    settings = {"data_quality_rules": [_rule("row_count_min", 10, table_name="dbo.OtherTable")]}
    result = m._get_data_quality_for_table(settings, "WS", "LH", "dbo.T")
    assert result["found"] is False


def test_for_table_only_returns_rules_targeting_that_exact_table(monkeypatch):
    _patch_profile_rows(monkeypatch, [_profile_row("a", row_count=99, table_name="dbo.T")])
    settings = {
        "data_quality_rules": [
            _rule("row_count_min", 10, table_name="dbo.T"),
            _rule("row_count_min", 10, table_name="dbo.OtherTable"),
        ]
    }
    result = m._get_data_quality_for_table(settings, "WS", "LH", "dbo.T")
    assert result["found"] is True
    assert result["rule_count"] == 1
    assert result["rules"][0]["table_name"] == "dbo.T"


def test_for_table_match_is_case_and_whitespace_insensitive(monkeypatch):
    _patch_profile_rows(monkeypatch, [_profile_row("a", row_count=99, table_name="dbo.T", workspace_name="WS", lakehouse_name="LH")])
    settings = {"data_quality_rules": [_rule("row_count_min", 10, workspace_name=" ws ", lakehouse_name=" lh ", table_name=" DBO.T ")]}
    result = m._get_data_quality_for_table(settings, "WS", "LH", "dbo.T")
    assert result["found"] is True
    assert result["rules"][0]["status"] == "passed"
