"""Purview-inspired data-quality rule engine (part of the Purview-parity
feature set).

Evaluates admin-defined rules against dbo.bronze_column_profile -- the
exact table NB_Discover_Column_Profile.py already writes for the Column
Profile detail view (GET /api/column-profile). No new scan, no new
Fabric permission, no new notebook: this is a pure aggregation over data
already collected, same "live-Warehouse read, aggregate in Python"
pattern as purview_insights.py's own overview functions (in fact this
module deliberately mirrors that one's shape so the two read the same
way in the admin panel).

Deliberately a small, fixed rule vocabulary (3 types) rather than a
general expression language -- matches exactly what bronze_column_profile
carries (null_percentage, distinct_count, row_count), and keeps rule
authoring in the admin panel a plain form (metric + threshold), not a DSL
someone has to learn. Purview's own Data Quality feature has a richer
rule set (custom SQL-like expressions); this is the 80% case for a much
smaller admin-curated list, same tradeoff certified_items/tags already
make elsewhere in this project.
"""
from . import warehouse
from .catalog import _norm

RULE_TYPES = {
    "null_percentage_max": {
        "es": "% de nulos como máximo",
        "en": "Null % at most",
        "scope": "column",
        "unit": "%",
    },
    "distinct_count_min": {
        "es": "Valores distintos como mínimo",
        "en": "Distinct values at least",
        "scope": "column",
        "unit": "",
    },
    "row_count_min": {
        "es": "Filas como mínimo",
        "en": "Rows at least",
        "scope": "table",
        "unit": "",
    },
}


def _profile_rows():
    try:
        return warehouse.query_bronze_table("bronze_column_profile")
    except warehouse.WarehouseError as exc:
        print(f"[data_quality] Warehouse read of dbo.bronze_column_profile failed: {exc}")
        return []


def _table_key(workspace_name, lakehouse_name, table_name):
    return (_norm(workspace_name), _norm(lakehouse_name), _norm(table_name))


def _index_profile_rows(rows):
    """table_key -> list of its column rows, and (table_key, column_name)
    -> that one column's row -- built once per evaluation, not once per
    rule, so a rule set with many rules against the same table doesn't
    re-scan the full profile table per rule."""
    by_table = {}
    by_column = {}
    for row in rows:
        table_key = _table_key(row.get("workspace_name", ""), row.get("lakehouse_name", ""), row.get("table_name", ""))
        by_table.setdefault(table_key, []).append(row)
        by_column[(table_key, _norm(row.get("column_name", "")))] = row
    return by_table, by_column


def _evaluate_rule(rule, by_table, by_column):
    rule_type = rule.get("rule_type", "")
    meta = RULE_TYPES.get(rule_type)
    table_key = _table_key(rule.get("workspace_name", ""), rule.get("lakehouse_name", ""), rule.get("table_name", ""))
    threshold = rule.get("threshold")

    result = {
        "id": rule.get("id", ""),
        "rule_type": rule_type,
        "workspace_name": rule.get("workspace_name", ""),
        "lakehouse_name": rule.get("lakehouse_name", ""),
        "table_name": rule.get("table_name", ""),
        "column_name": rule.get("column_name", ""),
        "threshold": threshold,
        "note": rule.get("note", ""),
    }

    if not meta:
        return {**result, "status": "invalid_rule", "actual_value": None, "message": f"Tipo de regla desconocido: {rule_type!r}."}

    if meta["scope"] == "column":
        column_row = by_column.get((table_key, _norm(rule.get("column_name", ""))))
        if column_row is None:
            return {**result, "status": "not_profiled", "actual_value": None, "message": "This column has not been profiled yet (NB_Discover_Column_Profile.py has not seen it)."}
        if rule_type == "null_percentage_max":
            actual = float(column_row.get("null_percentage") or 0.0)
            passed = actual <= float(threshold)
        else:  # distinct_count_min
            distinct = column_row.get("distinct_count")
            actual = int(distinct) if distinct not in (None, "") else None
            passed = actual is not None and actual >= float(threshold)
    else:  # table scope: row_count_min -- row_count is replicated on every
        # column row of the same table (bronze_column_profile is one row
        # per column, not per table), so any matching row carries it.
        table_rows = by_table.get(table_key) or []
        if not table_rows:
            return {**result, "status": "not_profiled", "actual_value": None, "message": "This table has not been profiled yet (NB_Discover_Column_Profile.py has not seen it)."}
        actual = int(table_rows[0].get("row_count") or 0)
        passed = actual >= float(threshold)

    status = "passed" if passed else "failed"
    return {**result, "status": status, "actual_value": actual, "message": ""}


def _get_data_quality_overview(settings):
    rules = settings.get("data_quality_rules") or []
    if not rules:
        return {"found": False, "reason": "No data-quality rules are defined yet -- create them in the admin panel (Data quality tab)."}

    rows = _profile_rows()
    by_table, by_column = _index_profile_rows(rows)
    evaluated = [_evaluate_rule(rule, by_table, by_column) for rule in rules]

    passed_count = sum(1 for r in evaluated if r["status"] == "passed")
    failed_count = sum(1 for r in evaluated if r["status"] == "failed")
    not_profiled_count = sum(1 for r in evaluated if r["status"] == "not_profiled")
    # Coverage gaps (not_profiled) are excluded from the pass rate -- an
    # unprofiled table isn't a quality FAILURE, it's a scanning gap, and
    # folding it into the denominator would make "profile fewer tables"
    # look like an improvement, which is backwards.
    scored = passed_count + failed_count

    return {
        "found": True,
        "rule_count": len(evaluated),
        "passed_count": passed_count,
        "failed_count": failed_count,
        "not_profiled_count": not_profiled_count,
        "pass_rate": round(100.0 * passed_count / scored, 1) if scored else None,
        "rules": evaluated,
    }


def _get_data_quality_for_table(settings, workspace_name, lakehouse_name, table_name):
    """Same evaluation, scoped to the rules that target one table -- for
    surfacing a pass/fail strip next to that table's existing Column
    Profile detail view (GET /api/column-profile), not just the tenant-
    wide admin overview above."""
    table_key = _table_key(workspace_name, lakehouse_name, table_name)
    rules = [
        rule for rule in (settings.get("data_quality_rules") or [])
        if _table_key(rule.get("workspace_name", ""), rule.get("lakehouse_name", ""), rule.get("table_name", "")) == table_key
    ]
    if not rules:
        return {"found": False, "rules": []}

    rows = _profile_rows()
    by_table, by_column = _index_profile_rows(rows)
    evaluated = [_evaluate_rule(rule, by_table, by_column) for rule in rules]
    return {"found": True, "rule_count": len(evaluated), "rules": evaluated}
