"""Unit tests for backend/scripts/lineage_web/purview_insights.py (Tanda A,
2026-07-09) -- access audit, capacity insight, changes digest. All three
are pure aggregation over CSV rows, so _read_csv_rows is monkeypatched to
return synthetic data rather than touching real files, matching how
test_lineage_web_server.py tests similar CSV-driven logic.

2026-08-14: _get_access_audit/_get_capacity_insight/_get_changes_digest
now read via _warehouse_or_local() (imported from catalog.py) instead of
calling this module's own _read_csv_rows directly, so the local-fallback
behavior these tests exercise has to be faked at that seam instead --
_warehouse_or_local internally uses catalog.py's OWN _read_csv_rows, a
different function object than purview_insights.m._read_csv_rows, so
patching the latter alone no longer intercepts anything for those three.
_patch_csv below fakes m._warehouse_or_local(table_name, local_path)
itself, keyed by local_path exactly like before (table_name is ignored,
same as a real local-file fallback would ignore it). _execution_duration_
rows() is the one exception -- its local fallback still calls this
module's own _read_csv_rows directly (there's no matching Warehouse table
shape to alias it through _warehouse_or_local), so that one part of
_patch_csv is unchanged. Every test also forces warehouse reads off
(is_warehouse_read_enabled=False) so nothing here ever depends on
whatever admin_settings.json/the real Warehouse actually contain.

Run with:
    pytest tests/python/test_purview_insights.py
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import purview_insights as m  # noqa: E402


def _patch_csv(monkeypatch, by_path):
    monkeypatch.setattr(m.warehouse, "is_warehouse_read_enabled", lambda: False)

    def fake_read_csv_rows(path):
        return by_path.get(path, [])
    monkeypatch.setattr(m, "_read_csv_rows", fake_read_csv_rows)

    def fake_warehouse_or_local(table_name, local_path):
        return by_path.get(local_path, [])
    monkeypatch.setattr(m, "_warehouse_or_local", fake_warehouse_or_local)


# --- _get_access_audit ---

def test_access_audit_reports_not_found_when_csv_missing(monkeypatch):
    _patch_csv(monkeypatch, {})
    result = m._get_access_audit()
    assert result["found"] is False


def test_access_audit_groups_by_workspace_and_ignores_non_discovered_rows(monkeypatch):
    rows = [
        {"workspace_name": "WS1", "principal_name": "Alice", "principal_type": "User", "role": "Admin", "status": "discovered"},
        {"workspace_name": "WS1", "principal_name": "Bob", "principal_type": "User", "role": "Member", "status": "discovered"},
        {"workspace_name": "WS2", "principal_name": "Alice", "principal_type": "User", "role": "Admin", "status": "discovered"},
        {"workspace_name": "WS3", "principal_name": "", "principal_type": "", "role": "", "status": "no_assignments"},
    ]
    _patch_csv(monkeypatch, {m.WORKSPACE_ROLE_ASSIGNMENTS_PATH: rows})
    result = m._get_access_audit()
    assert result["found"] is True
    assert result["workspace_count"] == 2
    assert result["assignment_count"] == 3


def test_access_audit_ranks_tenant_wide_admins_by_workspace_count(monkeypatch):
    rows = [
        {"workspace_name": "WS1", "principal_name": "Alice", "principal_type": "User", "role": "Admin", "status": "discovered"},
        {"workspace_name": "WS2", "principal_name": "Alice", "principal_type": "User", "role": "Admin", "status": "discovered"},
        {"workspace_name": "WS3", "principal_name": "Alice", "principal_type": "User", "role": "Admin", "status": "discovered"},
        {"workspace_name": "WS1", "principal_name": "Bob", "principal_type": "User", "role": "Admin", "status": "discovered"},
        {"workspace_name": "WS2", "principal_name": "Bob", "principal_type": "User", "role": "Member", "status": "discovered"},
    ]
    _patch_csv(monkeypatch, {m.WORKSPACE_ROLE_ASSIGNMENTS_PATH: rows})
    result = m._get_access_audit()
    top = result["tenant_wide_admins"][0]
    assert top["principal_name"] == "Alice"
    assert top["admin_workspace_count"] == 3
    # Bob is Admin in only WS1 (Member elsewhere doesn't count)
    bob = next(e for e in result["tenant_wide_admins"] if e["principal_name"] == "Bob")
    assert bob["admin_workspace_count"] == 1


def test_access_audit_reports_the_true_admin_count_even_when_the_list_is_capped(monkeypatch):
    # tenant_wide_admins itself is capped to the top 25 -- total_count
    # must reflect the real number so the admin panel can show "+N more"
    # instead of silently dropping them (2026-08-18 admin-panel audit
    # finding).
    rows = [
        {"workspace_name": f"WS{i}", "principal_name": f"Admin{i}", "principal_type": "User", "role": "Admin", "status": "discovered"}
        for i in range(30)
    ]
    _patch_csv(monkeypatch, {m.WORKSPACE_ROLE_ASSIGNMENTS_PATH: rows})
    result = m._get_access_audit()
    assert len(result["tenant_wide_admins"]) == 25
    assert result["tenant_wide_admin_total_count"] == 30


# --- _get_capacity_insight ---

def test_capacity_insight_falls_back_to_capacity_id_when_name_missing(monkeypatch):
    workspace_rows = [
        {"workspace_name": "WS1", "capacity_name": "", "capacity_id": "cap-123", "capacity_region": "West Europe"},
        {"workspace_name": "WS2", "capacity_name": "Prod Capacity", "capacity_id": "cap-456", "capacity_region": "West Europe"},
        {"workspace_name": "WS3", "capacity_name": "", "capacity_id": "", "capacity_region": ""},
    ]
    _patch_csv(monkeypatch, {
        m.WORKSPACE_INDEX_PATH: workspace_rows,
        m.ITEMS_INDEX_PATH: [],
        m.EXECUTION_DURATION_BY_ITEM_PATH: [],
    })
    result = m._get_capacity_insight()
    labels = {c["capacity_label"] for c in result["capacities"]}
    assert "cap-123 (West Europe)" in labels
    assert "Prod Capacity" in labels
    assert "(sin capacidad asignada)" in labels


def test_capacity_insight_counts_items_and_executions_per_capacity(monkeypatch):
    workspace_rows = [{"workspace_name": "WS1", "capacity_name": "Cap A", "capacity_id": "", "capacity_region": ""}]
    item_rows = [
        {"workspace_name": "WS1", "qualified_name": "WS1/Report/A"},
        {"workspace_name": "WS1", "qualified_name": "WS1/Report/B"},
    ]
    execution_rows = [{"workspace_name": "WS1", "run_count": "5", "failed_count": "2"}]
    _patch_csv(monkeypatch, {
        m.WORKSPACE_INDEX_PATH: workspace_rows,
        m.ITEMS_INDEX_PATH: item_rows,
        m.EXECUTION_DURATION_BY_ITEM_PATH: execution_rows,
    })
    result = m._get_capacity_insight()
    cap_a = next(c for c in result["capacities"] if c["capacity_label"] == "Cap A")
    assert cap_a["item_count"] == 2
    assert cap_a["execution_count"] == 5
    assert cap_a["failed_count"] == 2


# --- _get_changes_digest ---

def test_changes_digest_reports_not_found_when_history_missing(monkeypatch):
    _patch_csv(monkeypatch, {})
    result = m._get_changes_digest()
    assert result["found"] is False


def test_sensitivity_overview_reports_not_found_when_object_graph_missing(monkeypatch, tmp_path):
    monkeypatch.setattr(m.onelake_data, "fetch_cached_path", lambda filename: None)
    monkeypatch.setattr(m, "GRAPH_MAP_INDEX_OBJECTS_PATH", tmp_path / "does-not-exist.json")
    result = m._get_sensitivity_overview()
    assert result["found"] is False


def test_sensitivity_overview_aggregates_by_category(monkeypatch, tmp_path):
    import json

    monkeypatch.setattr(m.onelake_data, "fetch_cached_path", lambda filename: None)
    payload = {
        "nodes": [
            {"data": {"id": "object::1", "label": "Table A", "source_server": "srv1", "source_database": "db1", "sensitivity_categories": ["email", "phone"]}},
            {"data": {"id": "object::2", "label": "Table B", "source_server": "srv1", "source_database": "db1", "sensitivity_categories": ["email"]}},
            {"data": {"id": "object::3", "label": "Table C", "source_server": "srv1", "source_database": "db1", "sensitivity_categories": []}},
        ]
    }
    fake_path = tmp_path / "graph-map-index-objects.json"
    fake_path.write_text(json.dumps(payload), encoding="utf-8")
    monkeypatch.setattr(m, "GRAPH_MAP_INDEX_OBJECTS_PATH", fake_path)

    result = m._get_sensitivity_overview()
    assert result["found"] is True
    assert result["total_object_count"] == 3
    assert result["flagged_object_count"] == 2
    email_bucket = next(c for c in result["categories"] if c["category"] == "email")
    assert email_bucket["object_count"] == 2
    assert email_bucket["label_es"] == "Email"
    phone_bucket = next(c for c in result["categories"] if c["category"] == "phone")
    assert phone_bucket["object_count"] == 1


# --- _get_sensitivity_overview's live-Warehouse path (2026-08-30) --
# dbo.bronze_object_column_catalog classified by column name, joined
# against dbo.bronze_sql_endpoint_object_catalog for workspace_name/
# source_server/source_database, same alias join catalog.py's own
# object-alias resolution already uses (database|schema|object_name, no
# server). ---

def _column_row(source_server, source_database, schema_name, object_name, column_id, column_name):
    return {
        "source_server": source_server, "source_database": source_database, "schema_name": schema_name,
        "object_name": object_name, "column_id": str(column_id), "column_name": column_name,
        "data_type": "varchar", "max_length": "50", "precision": "", "scale": "",
        "is_nullable": "1", "is_identity": "0", "is_computed": "0", "captured_at": "2026-08-30T00:00:00Z",
    }


def _sql_catalog_row(workspace_name, source_server, source_database, schema_name, object_name):
    return {
        "object_key": "k", "object_display_name": f"{source_database} / {schema_name}.{object_name}",
        "source_type": "SQL", "source_server": source_server, "source_database": source_database,
        "schema_name": schema_name, "object_name": object_name, "object_type": "table_or_view",
        "workspace_name": workspace_name, "catalog_status": "confirmed",
    }


def test_sensitivity_overview_uses_warehouse_when_enabled(monkeypatch):
    monkeypatch.setattr(m.warehouse, "is_warehouse_read_enabled", lambda: True)
    column_rows = [
        _column_row("srv1", "CoreDB", "dbo", "Customers", 1, "email_address"),
        _column_row("srv1", "CoreDB", "dbo", "Customers", 2, "full_name"),
        _column_row("srv1", "CoreDB", "dbo", "Orders", 1, "order_id"),  # no sensitive columns
    ]
    sql_catalog_rows = [_sql_catalog_row("WS1", "srv1", "CoreDB", "dbo", "Customers")]

    def fake_query(table_name, use_cache=True):
        if table_name == "bronze_object_column_catalog":
            return column_rows
        if table_name == "bronze_sql_endpoint_object_catalog":
            return sql_catalog_rows
        return []
    monkeypatch.setattr(m.warehouse, "query_bronze_table", fake_query)

    result = m._get_sensitivity_overview()
    assert result["found"] is True
    assert result["total_object_count"] == 2
    assert result["flagged_object_count"] == 1
    email_bucket = next(c for c in result["categories"] if c["category"] == "email")
    assert email_bucket["object_count"] == 1
    sample = email_bucket["samples"][0]
    assert sample["workspace_name"] == "WS1"
    assert sample["source_server"] == "srv1"
    assert sample["source_database"] == "CoreDB"
    assert sample["label"] == "CoreDB.dbo.Customers"
    person_bucket = next(c for c in result["categories"] if c["category"] == "person_name")
    assert person_bucket["samples"][0]["workspace_name"] == "WS1"


# --- Roadmap Fase 2 (2026-08-31): admin-defined custom sensitivity
# categories, threaded through via settings["custom_sensitivity_categories"]
# -- see sensitivity_classifier.py's own tests for the classifier-level
# behavior (shadowing, invalid regex, etc.); these confirm the threading
# from _get_sensitivity_overview's settings arg actually reaches it. ---

def test_sensitivity_overview_applies_a_custom_category_when_settings_provided(monkeypatch):
    monkeypatch.setattr(m.warehouse, "is_warehouse_read_enabled", lambda: True)
    column_rows = [_column_row("srv1", "CoreDB", "dbo", "Customers", 1, "internal_customer_ref")]
    sql_catalog_rows = [_sql_catalog_row("WS1", "srv1", "CoreDB", "dbo", "Customers")]

    def fake_query(table_name, use_cache=True):
        if table_name == "bronze_object_column_catalog":
            return column_rows
        if table_name == "bronze_sql_endpoint_object_catalog":
            return sql_catalog_rows
        return []
    monkeypatch.setattr(m.warehouse, "query_bronze_table", fake_query)

    settings = {
        "custom_sensitivity_categories": [
            {"key": "internal_ref", "label_es": "Referencia interna", "label_en": "Internal reference",
             "patterns": [r"internal_customer_ref"], "risk": "low"},
        ]
    }
    result = m._get_sensitivity_overview(settings=settings)
    assert result["found"] is True
    custom_bucket = next(c for c in result["categories"] if c["category"] == "internal_ref")
    assert custom_bucket["object_count"] == 1
    assert custom_bucket["label_es"] == "Referencia interna"


def test_sensitivity_overview_ignores_custom_categories_when_settings_omitted(monkeypatch):
    monkeypatch.setattr(m.warehouse, "is_warehouse_read_enabled", lambda: True)
    column_rows = [_column_row("srv1", "CoreDB", "dbo", "Customers", 1, "internal_customer_ref")]
    sql_catalog_rows = [_sql_catalog_row("WS1", "srv1", "CoreDB", "dbo", "Customers")]

    def fake_query(table_name, use_cache=True):
        if table_name == "bronze_object_column_catalog":
            return column_rows
        if table_name == "bronze_sql_endpoint_object_catalog":
            return sql_catalog_rows
        return []
    monkeypatch.setattr(m.warehouse, "query_bronze_table", fake_query)

    result = m._get_sensitivity_overview()
    assert result["flagged_object_count"] == 0


def test_sensitivity_overview_leaves_ambiguous_alias_unresolved_without_server(monkeypatch):
    # Two different real sources sharing the same database|schema|object_name
    # alias, and the querying (column-catalog) row carries NO source_server
    # at all -- the server-aware key can't be tried, so this must fall back
    # to the original server-less alias and stay unresolved (a dash) rather
    # than guess, same "record gaps, don't fabricate" convention as
    # everything else here.
    monkeypatch.setattr(m.warehouse, "is_warehouse_read_enabled", lambda: True)
    column_rows = [_column_row("", "CoreDB", "dbo", "Customers", 1, "email_address")]
    sql_catalog_rows = [
        _sql_catalog_row("WS1", "srv1", "CoreDB", "dbo", "Customers"),
        _sql_catalog_row("WS2", "srv2", "CoreDB", "dbo", "Customers"),
    ]

    def fake_query(table_name, use_cache=True):
        if table_name == "bronze_object_column_catalog":
            return column_rows
        if table_name == "bronze_sql_endpoint_object_catalog":
            return sql_catalog_rows
        return []
    monkeypatch.setattr(m.warehouse, "query_bronze_table", fake_query)

    result = m._get_sensitivity_overview()
    email_bucket = next(c for c in result["categories"] if c["category"] == "email")
    assert email_bucket["samples"][0]["workspace_name"] == ""


def test_sensitivity_overview_leaves_ambiguous_alias_unresolved_even_with_matching_server(monkeypatch):
    # Two catalog rows share not just the database|schema|object_name alias
    # but also the SAME source_server (a genuinely duplicated/misconfigured
    # catalog, not a real Dev/Pro pair) -- the server-aware key is ALSO
    # ambiguous here (2 matches), so this must still stay unresolved rather
    # than arbitrarily picking one of the two.
    monkeypatch.setattr(m.warehouse, "is_warehouse_read_enabled", lambda: True)
    column_rows = [_column_row("srv1", "CoreDB", "dbo", "Customers", 1, "email_address")]
    sql_catalog_rows = [
        _sql_catalog_row("WS1", "srv1", "CoreDB", "dbo", "Customers"),
        _sql_catalog_row("WS2", "srv1", "CoreDB", "dbo", "Customers"),
    ]

    def fake_query(table_name, use_cache=True):
        if table_name == "bronze_object_column_catalog":
            return column_rows
        if table_name == "bronze_sql_endpoint_object_catalog":
            return sql_catalog_rows
        return []
    monkeypatch.setattr(m.warehouse, "query_bronze_table", fake_query)

    result = m._get_sensitivity_overview()
    email_bucket = next(c for c in result["categories"] if c["category"] == "email")
    assert email_bucket["samples"][0]["workspace_name"] == ""


# --- _get_privacy_coverage_map (Roadmap Fase 5, 2026-08-31) -- the same
# classification, pivoted per-object instead of per-category, so a table
# with several sensitive columns of different categories appears exactly
# once, not once per category. ---

def test_privacy_coverage_map_reports_not_found_when_catalog_empty(monkeypatch):
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: [])
    result = m._get_privacy_coverage_map(use_cache=False)
    assert result["found"] is False


def test_privacy_coverage_map_lists_each_object_once_with_every_matched_category(monkeypatch):
    # A single object with THREE distinct sensitive columns (email, Grade,
    # employer) -- the per-category tab would show this table 3 times;
    # the coverage map must show it exactly once with all 3 categories.
    column_rows = [
        _column_row("srv1", "CoreDB", "dbo", "Customers", 1, "email_address"),
        _column_row("srv1", "CoreDB", "dbo", "Customers", 2, "Grade"),
        _column_row("srv1", "CoreDB", "dbo", "Customers", 3, "Employer"),
    ]
    sql_catalog_rows = [_sql_catalog_row("WS1", "srv1", "CoreDB", "dbo", "Customers")]

    def fake_query(table_name, use_cache=True):
        if table_name == "bronze_object_column_catalog":
            return column_rows
        if table_name == "bronze_sql_endpoint_object_catalog":
            return sql_catalog_rows
        return []
    monkeypatch.setattr(m.warehouse, "query_bronze_table", fake_query)

    result = m._get_privacy_coverage_map(use_cache=False)
    assert result["found"] is True
    assert result["flagged_object_count"] == 1
    obj = result["objects"][0]
    assert obj["workspace_name"] == "WS1"
    assert obj["category_count"] == 3
    matched_keys = {c["category"] for c in obj["categories"]}
    assert matched_keys == {"email", "academic_record", "employment"}


def test_privacy_coverage_map_max_risk_is_the_highest_among_matched_categories(monkeypatch):
    # gender (low) + disciplinary_record (very_high) on the same object --
    # max_risk must reflect the worst one, not the first/last found.
    column_rows = [
        _column_row("srv1", "CoreDB", "dbo", "Customers", 1, "Sexo"),
        _column_row("srv1", "CoreDB", "dbo", "Customers", 2, "SANCIONES_ETICAS"),
    ]
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: column_rows if table_name == "bronze_object_column_catalog" else [])

    result = m._get_privacy_coverage_map(use_cache=False)
    assert result["objects"][0]["max_risk"] == "very_high"


def test_privacy_coverage_map_sorts_highest_risk_objects_first(monkeypatch):
    column_rows = [
        _column_row("srv1", "DB", "dbo", "LowRiskTable", 1, "Sexo"),
        _column_row("srv1", "DB", "dbo", "HighRiskTable", 1, "SANCIONES_ETICAS"),
    ]
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: column_rows if table_name == "bronze_object_column_catalog" else [])

    result = m._get_privacy_coverage_map(use_cache=False)
    labels_in_order = [obj["label"] for obj in result["objects"]]
    assert "HighRiskTable" in labels_in_order[0]


def test_privacy_coverage_map_category_counts_are_deduplicated_per_object(monkeypatch):
    # Two different objects both flagged for "email" -- category_counts
    # must count 2 objects, not 2 column-level hits from the same object.
    column_rows = [
        _column_row("srv1", "DB", "dbo", "TableA", 1, "email_address"),
        _column_row("srv1", "DB", "dbo", "TableB", 1, "email_address"),
    ]
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: column_rows if table_name == "bronze_object_column_catalog" else [])

    result = m._get_privacy_coverage_map(use_cache=False)
    email_count = next(c for c in result["category_counts"] if c["category"] == "email")
    assert email_count["object_count"] == 2


def test_privacy_coverage_map_applies_custom_categories(monkeypatch):
    column_rows = [_column_row("srv1", "DB", "dbo", "TableA", 1, "internal_customer_ref")]
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: column_rows if table_name == "bronze_object_column_catalog" else [])

    settings = {"custom_sensitivity_categories": [
        {"key": "internal_ref", "label_es": "Referencia interna", "patterns": [r"internal_customer_ref"], "risk": "low"},
    ]}
    result = m._get_privacy_coverage_map(settings=settings, use_cache=False)
    assert result["flagged_object_count"] == 1
    assert result["objects"][0]["categories"][0]["category"] == "internal_ref"


def test_privacy_coverage_map_use_cache_true_returns_stale_result_within_ttl(monkeypatch):
    """2026-09-01 502 hardening: use_cache=True must serve the cached result
    (not recompute) for a repeat call within the TTL, even if the underlying
    Warehouse rows change between calls -- this is what actually protects a
    slow classification pass from being redone on every "Todas las tablas"
    click. Directly manipulates the module-level cache dict/lock instead of
    sleeping, so the test doesn't depend on wall-clock timing."""
    settings = {"custom_sensitivity_categories": []}
    cache_key = m.json.dumps([], sort_keys=True, default=str)
    m._privacy_coverage_cache.clear()

    first_rows = [_column_row("srv1", "DB", "dbo", "TableA", 1, "internal_customer_ref")]
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: first_rows if table_name == "bronze_object_column_catalog" else [])
    first = m._get_privacy_coverage_map(settings=settings, use_cache=True)
    assert first["found"] is True

    def fail_if_called(table_name, use_cache=True):
        raise AssertionError("Warehouse should not be re-queried on a cache hit")
    monkeypatch.setattr(m.warehouse, "query_bronze_table", fail_if_called)

    second = m._get_privacy_coverage_map(settings=settings, use_cache=True)
    assert second is first
    m._privacy_coverage_cache.pop(cache_key, None)


def test_privacy_coverage_map_use_cache_false_always_recomputes(monkeypatch):
    """Companion to the cache-hit test above: use_cache=False (what every
    other test in this file passes) must bypass the module-level cache
    entirely, both on read and on write, so tests never leak state into
    each other via this cache."""
    settings = {"custom_sensitivity_categories": []}
    cache_key = m.json.dumps([], sort_keys=True, default=str)
    m._privacy_coverage_cache.clear()

    rows = [_column_row("srv1", "DB", "dbo", "TableA", 1, "internal_customer_ref")]
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: rows if table_name == "bronze_object_column_catalog" else [])
    m._get_privacy_coverage_map(settings=settings, use_cache=False)
    assert cache_key not in m._privacy_coverage_cache

    calls = {"count": 0}
    def counting_read(table_name, use_cache=True):
        if table_name == "bronze_object_column_catalog":
            calls["count"] += 1
            return rows
        return []
    monkeypatch.setattr(m.warehouse, "query_bronze_table", counting_read)
    m._get_privacy_coverage_map(settings=settings, use_cache=False)
    m._get_privacy_coverage_map(settings=settings, use_cache=False)
    assert calls["count"] == 2


# --- _get_privacy_framework_map (Roadmap Fase 6, 2026-08-31) -- same
# classification grouped by legal framework (GDPR/FERPA/CCPA) first, then
# category, plus admin-logged external systems folded in per category. ---

def test_privacy_framework_map_is_always_found_even_without_warehouse_data(monkeypatch):
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: [])
    result = m._get_privacy_framework_map(use_cache=False)
    assert result["found"] is True


def test_privacy_framework_map_groups_a_table_under_every_matching_framework(monkeypatch):
    # A disciplinary-record column matches BOTH gdpr_criminal and ferpa --
    # unlike the coverage map's per-object dedup, the SAME table must
    # appear under both frameworks here, not just one.
    column_rows = [_column_row("srv1", "DB", "dbo", "Customers", 1, "SANCIONES_ETICAS")]
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: column_rows if table_name == "bronze_object_column_catalog" else [])

    result = m._get_privacy_framework_map(use_cache=False)
    frameworks_with_hits = {
        fw["framework"] for fw in result["frameworks"]
        if any(c["category"] == "disciplinary_record" and c["object_count"] == 1 for c in fw["categories"])
    }
    assert frameworks_with_hits == {"gdpr_criminal", "ferpa"}


def test_privacy_framework_map_includes_zero_object_categories_with_external_systems(monkeypatch):
    # "biometric" has no real Fabric hits (see sensitivity_classifier.py's
    # own notes) but an admin-logged external system must still surface it
    # under gdpr_special, with object_count 0 and the system attached.
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: [])
    settings = {"privacy_external_systems": [
        {"category": "biometric", "system_name": "Control de acceso físico", "in_fabric": False, "owner_email": "security@contoso.com"},
    ]}
    result = m._get_privacy_framework_map(settings=settings, use_cache=False)
    gdpr_special = next(fw for fw in result["frameworks"] if fw["framework"] == "gdpr_special")
    biometric = next(c for c in gdpr_special["categories"] if c["category"] == "biometric")
    assert biometric["object_count"] == 0
    assert biometric["external_systems"][0]["system_name"] == "Control de acceso físico"


def test_privacy_framework_map_omits_frameworks_with_no_matching_category():
    # No Warehouse data, no external systems, no custom categories --
    # every built-in category still HAS a framework (enforced by
    # sensitivity_classifier's own tests), so every framework still
    # appears, just with every category at object_count 0.
    result = m._get_privacy_framework_map(use_cache=False)
    assert len(result["frameworks"]) == len(m.PRIVACY_FRAMEWORKS)


def test_privacy_framework_map_applies_custom_category_with_declared_framework(monkeypatch):
    column_rows = [_column_row("srv1", "DB", "dbo", "TableA", 1, "internal_customer_ref")]
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: column_rows if table_name == "bronze_object_column_catalog" else [])

    settings = {"custom_sensitivity_categories": [
        {"key": "internal_ref", "label_es": "Referencia interna", "patterns": [r"internal_customer_ref"], "risk": "low", "frameworks": ["gdpr"]},
    ]}
    result = m._get_privacy_framework_map(settings=settings, use_cache=False)
    gdpr = next(fw for fw in result["frameworks"] if fw["framework"] == "gdpr")
    internal_ref = next((c for c in gdpr["categories"] if c["category"] == "internal_ref"), None)
    assert internal_ref is not None
    assert internal_ref["object_count"] == 1


def test_privacy_framework_map_custom_category_without_framework_is_absent():
    settings = {"custom_sensitivity_categories": [
        {"key": "internal_ref", "label_es": "Referencia interna", "patterns": [r"x"], "risk": "low"},
    ]}
    result = m._get_privacy_framework_map(settings=settings, use_cache=False)
    for fw in result["frameworks"]:
        assert all(c["category"] != "internal_ref" for c in fw["categories"])


def test_sensitivity_overview_resolves_dev_pro_pair_via_server(monkeypatch):
    # Mirrors a real, confirmed-live case: a Lakehouse exists as a
    # genuinely distinct, individually-resolvable object in a Dev AND a
    # Pro workspace -- same database/schema/object_name, different server
    # (a real Dev/Pro pair). Before this fix the alias mapped to 2 catalog
    # rows and BOTH stayed unresolved; the server-aware key must now
    # resolve each row to its OWN workspace -- not the other one, and not
    # both to the same one.
    monkeypatch.setattr(m.warehouse, "is_warehouse_read_enabled", lambda: True)
    column_rows = [
        _column_row("srv-dev", "LH_Datamart_CRM_Silver", "dbo", "Customers", 1, "email_address"),
        _column_row("srv-pro", "LH_Datamart_CRM_Silver", "dbo", "Customers", 1, "email_address"),
    ]
    sql_catalog_rows = [
        _sql_catalog_row("Datamart-CRM_Contoso_Dev", "srv-dev", "LH_Datamart_CRM_Silver", "dbo", "Customers"),
        _sql_catalog_row("Datamart-CRM_Contoso_Pro", "srv-pro", "LH_Datamart_CRM_Silver", "dbo", "Customers"),
    ]

    def fake_query(table_name, use_cache=True):
        if table_name == "bronze_object_column_catalog":
            return column_rows
        if table_name == "bronze_sql_endpoint_object_catalog":
            return sql_catalog_rows
        return []
    monkeypatch.setattr(m.warehouse, "query_bronze_table", fake_query)

    result = m._get_sensitivity_overview()
    email_bucket = next(c for c in result["categories"] if c["category"] == "email")
    assert email_bucket["object_count"] == 2
    workspace_by_server = {s["source_server"]: s["workspace_name"] for s in email_bucket["samples"]}
    assert workspace_by_server["srv-dev"] == "Datamart-CRM_Contoso_Dev"
    assert workspace_by_server["srv-pro"] == "Datamart-CRM_Contoso_Pro"


def test_sensitivity_overview_workspace_name_never_falls_back_to_source_database(monkeypatch):
    # Regression for a real user-reported bug: the admin panel's WORKSPACE
    # column showed the exact same string as the BASE DE DATOS column (a
    # Lakehouse/database name, with an "LH_" infix) instead of the real
    # Fabric workspace name (no "LH_" infix). Investigation found the live
    # resolution logic itself was already correct (workspace_name always
    # comes from catalog_match["workspace_name"], never from source_
    # database) -- this test locks the contract in regardless: even with
    # an unambiguous single match whose source_database name could
    # plausibly be mistaken for a workspace name (an "LH_" infix away from
    # it), the resolved workspace_name must be the catalog row's own
    # workspace_name field, and must never equal source_database.
    monkeypatch.setattr(m.warehouse, "is_warehouse_read_enabled", lambda: True)
    column_rows = [_column_row("srv1", "DP_Retail_LH_SampleStore", "sales", "PERSONA", 1, "email_address")]
    sql_catalog_rows = [
        _sql_catalog_row("DP_Retail_SampleStore", "srv1", "DP_Retail_LH_SampleStore", "sales", "PERSONA"),
    ]

    def fake_query(table_name, use_cache=True):
        if table_name == "bronze_object_column_catalog":
            return column_rows
        if table_name == "bronze_sql_endpoint_object_catalog":
            return sql_catalog_rows
        return []
    monkeypatch.setattr(m.warehouse, "query_bronze_table", fake_query)

    result = m._get_sensitivity_overview()
    email_bucket = next(c for c in result["categories"] if c["category"] == "email")
    sample = email_bucket["samples"][0]
    assert sample["workspace_name"] == "DP_Retail_SampleStore"
    assert sample["source_database"] == "DP_Retail_LH_SampleStore"
    assert sample["workspace_name"] != sample["source_database"]


def test_sensitivity_overview_falls_back_to_local_json_when_column_catalog_empty(monkeypatch, tmp_path):
    monkeypatch.setattr(m.warehouse, "is_warehouse_read_enabled", lambda: True)
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: [])
    monkeypatch.setattr(m.onelake_data, "fetch_cached_path", lambda filename: None)
    monkeypatch.setattr(m, "GRAPH_MAP_INDEX_OBJECTS_PATH", tmp_path / "does-not-exist.json")

    result = m._get_sensitivity_overview()
    assert result["found"] is False


def test_sensitivity_overview_falls_back_to_local_json_on_warehouse_error(monkeypatch, tmp_path):
    monkeypatch.setattr(m.warehouse, "is_warehouse_read_enabled", lambda: True)

    def raise_error(table_name, use_cache=True):
        raise m.warehouse.WarehouseQueryError("boom")
    monkeypatch.setattr(m.warehouse, "query_bronze_table", raise_error)
    monkeypatch.setattr(m.onelake_data, "fetch_cached_path", lambda filename: None)
    monkeypatch.setattr(m, "GRAPH_MAP_INDEX_OBJECTS_PATH", tmp_path / "does-not-exist.json")

    result = m._get_sensitivity_overview()
    assert result["found"] is False


# --- _get_content_sensitivity_overview (2026-08-18, roadmap Fase 2 follow-
# through: the content-verified counterpart to _get_sensitivity_overview
# above) -- no local-CSV fallback, so these mock warehouse.query_bronze_
# table directly, same convention as test_catalog_column_sensitivity.py. ---

def _content_row(workspace_name, lakehouse_name, table_name, column_name, category, match_percentage):
    return {
        "workspace_name": workspace_name, "lakehouse_name": lakehouse_name, "table_name": table_name,
        "column_name": column_name, "data_type": "varchar", "category": category,
        "sample_size": "200", "match_count": "1", "match_percentage": str(match_percentage),
        "checked_at": "2026-08-18T10:00:00Z",
    }


def test_content_sensitivity_overview_reports_not_found_when_no_rows(monkeypatch):
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: [])
    result = m._get_content_sensitivity_overview()
    assert result["found"] is False


def test_content_sensitivity_overview_degrades_gracefully_on_warehouse_error(monkeypatch):
    def raise_error(table_name, use_cache=True):
        raise m.warehouse.WarehouseError("boom")
    monkeypatch.setattr(m.warehouse, "query_bronze_table", raise_error)
    result = m._get_content_sensitivity_overview()
    assert result["found"] is False


def test_content_sensitivity_overview_keeps_zero_percent_matches(monkeypatch):
    # 2026-08-25 redesign: every row here already passed the notebook's own
    # name-based pre-filter (Paso 0), so a 0% content match is still real
    # signal worth showing (with its stored examples), not noise to drop --
    # unlike the pre-redesign behavior this test used to assert.
    rows = [_content_row("WS1", "LH1", "dbo.T", "col1", "email", 0.0)]
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: rows)
    result = m._get_content_sensitivity_overview()
    assert result["found"] is True
    assert result["checked_table_count"] == 1
    assert result["flagged_column_count"] == 1
    email_bucket = next(c for c in result["categories"] if c["category"] == "email")
    assert email_bucket["samples"][0]["match_percentage"] == 0.0
    assert email_bucket["samples"][0]["has_content_pattern"] is True


def test_content_sensitivity_overview_blank_match_percentage_has_no_content_pattern(monkeypatch):
    # A category without a reliable content regex (person_name, etc.) --
    # the notebook writes match_percentage="" for these, never "0%" (which
    # would wrongly suggest a real check found no match).
    row = _content_row("WS1", "LH1", "dbo.T", "last_name", "person_name", "")
    row["match_count"] = ""
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: [row])
    result = m._get_content_sensitivity_overview()
    assert result["found"] is True
    name_bucket = next(c for c in result["categories"] if c["category"] == "person_name")
    sample = name_bucket["samples"][0]
    assert sample["match_percentage"] is None
    assert sample["has_content_pattern"] is False


def test_content_sensitivity_overview_categories_carry_risk_and_recommendation(monkeypatch):
    rows = [_content_row("WS1", "LH1", "dbo.T", "col1", "health", 12.0)]
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: rows)
    result = m._get_content_sensitivity_overview()
    health_bucket = next(c for c in result["categories"] if c["category"] == "health")
    assert health_bucket["risk"] == "very_high"
    assert health_bucket["risk_label_es"] == "Muy alto"
    assert health_bucket["recommendation_es"]
    assert health_bucket["recommendation_en"]


def test_content_sensitivity_overview_sample_includes_stored_example_values(monkeypatch):
    content_rows = [_content_row("WS1", "LH1", "dbo.T", "col1", "email", 90.0)]
    sample_rows = [{
        "workspace_name": "WS1", "lakehouse_name": "LH1", "table_name": "dbo.T", "column_name": "col1",
        "categories_matched": "email", "sample_size": "500",
        "sample_values_json": '["a@example.com", "b@example.com"]', "checked_at": "2026-08-25T10:00:00Z",
    }]

    def fake_query(table_name, use_cache=True):
        if table_name == "bronze_column_sensitivity_samples":
            return sample_rows
        return content_rows
    monkeypatch.setattr(m.warehouse, "query_bronze_table", fake_query)
    result = m._get_content_sensitivity_overview()
    email_bucket = next(c for c in result["categories"] if c["category"] == "email")
    assert email_bucket["samples"][0]["sample_values"] == ["a@example.com", "b@example.com"]


def test_content_sensitivity_overview_aggregates_by_category_deduping_columns(monkeypatch):
    rows = [
        _content_row("WS1", "LH1", "dbo.Users", "email_addr", "email", 82.5),
        _content_row("WS1", "LH1", "dbo.Users", "email_addr", "email", 82.5),  # duplicate row -- same column, counted once
        _content_row("WS1", "LH1", "dbo.Users", "phone", "phone", 40.0),
        _content_row("WS1", "LH1", "dbo.Orders", "billing_email", "email", 15.0),
    ]
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: rows)
    result = m._get_content_sensitivity_overview()
    assert result["found"] is True
    assert result["checked_table_count"] == 2
    email_bucket = next(c for c in result["categories"] if c["category"] == "email")
    assert email_bucket["column_count"] == 2
    assert email_bucket["table_count"] == 2
    assert email_bucket["label_es"] == "Email"
    phone_bucket = next(c for c in result["categories"] if c["category"] == "phone")
    assert phone_bucket["column_count"] == 1
    assert result["flagged_column_count"] == 3


def test_changes_digest_only_includes_the_latest_scan(monkeypatch):
    rows = [
        {"event_date": "2026-07-01", "event_type": "added", "qualified_name": "old-item", "scan_started_at": "2026-07-01T00:00:00Z"},
        {"event_date": "2026-07-09", "event_type": "added", "qualified_name": "new-item-1", "scan_started_at": "2026-07-09T00:00:00Z"},
        {"event_date": "2026-07-09", "event_type": "removed", "qualified_name": "new-item-2", "scan_started_at": "2026-07-09T00:00:00Z"},
        {"event_date": "2026-07-09", "event_type": "modified", "qualified_name": "new-item-3", "scan_started_at": "2026-07-09T00:00:00Z"},
    ]
    _patch_csv(monkeypatch, {m.ITEM_HISTORY_PATH: rows})
    result = m._get_changes_digest()
    assert result["found"] is True
    assert result["latest_scan_started_at"] == "2026-07-09T00:00:00Z"
    assert result["added_count"] == 1
    assert result["removed_count"] == 1
    assert result["modified_count"] == 1
    assert len(result["changes"]) == 3
    assert all(c["qualified_name"] != "old-item" for c in result["changes"])
    assert result["total_count"] == 3


def test_changes_digest_reports_the_true_total_when_the_limit_truncates(monkeypatch):
    rows = [
        {"event_date": "2026-07-09", "event_type": "added", "qualified_name": f"item-{i}", "scan_started_at": "2026-07-09T00:00:00Z"}
        for i in range(5)
    ]
    _patch_csv(monkeypatch, {m.ITEM_HISTORY_PATH: rows})
    result = m._get_changes_digest(limit=2)
    assert len(result["changes"]) == 2
    assert result["total_count"] == 5


# --- _get_changes_digest's scan_started_at param (2026-08-18, admin-panel
# completeness pass: a historical view, not just always "the latest scan") ---

def _history_rows_across_two_scans():
    return [
        {"event_date": "2026-07-01", "event_type": "added", "qualified_name": "old-item", "scan_started_at": "2026-07-01T00:00:00Z"},
        {"event_date": "2026-07-09", "event_type": "removed", "qualified_name": "new-item", "scan_started_at": "2026-07-09T00:00:00Z"},
    ]


def test_changes_digest_defaults_to_the_latest_scan_when_no_param_given(monkeypatch):
    _patch_csv(monkeypatch, {m.ITEM_HISTORY_PATH: _history_rows_across_two_scans()})
    result = m._get_changes_digest()
    assert result["scan_started_at"] == "2026-07-09T00:00:00Z"
    assert result["changes"][0]["qualified_name"] == "new-item"


def test_changes_digest_returns_a_specific_past_scan_when_requested(monkeypatch):
    _patch_csv(monkeypatch, {m.ITEM_HISTORY_PATH: _history_rows_across_two_scans()})
    result = m._get_changes_digest(scan_started_at="2026-07-01T00:00:00Z")
    assert result["scan_started_at"] == "2026-07-01T00:00:00Z"
    assert result["changes"][0]["qualified_name"] == "old-item"
    # latest_scan_started_at still reflects the real latest, regardless of
    # which scan is being VIEWED -- the two are independent.
    assert result["latest_scan_started_at"] == "2026-07-09T00:00:00Z"


def test_changes_digest_falls_back_to_latest_for_an_unknown_scan_value(monkeypatch):
    _patch_csv(monkeypatch, {m.ITEM_HISTORY_PATH: _history_rows_across_two_scans()})
    result = m._get_changes_digest(scan_started_at="2099-01-01T00:00:00Z")
    assert result["scan_started_at"] == "2026-07-09T00:00:00Z"


def test_changes_digest_available_scans_is_sorted_most_recent_first(monkeypatch):
    _patch_csv(monkeypatch, {m.ITEM_HISTORY_PATH: _history_rows_across_two_scans()})
    result = m._get_changes_digest()
    assert result["available_scans"] == ["2026-07-09T00:00:00Z", "2026-07-01T00:00:00Z"]


def test_changes_digest_available_scan_counts_matches_each_scans_row_count(monkeypatch):
    _patch_csv(monkeypatch, {m.ITEM_HISTORY_PATH: _history_rows_across_two_scans()})
    result = m._get_changes_digest()
    assert result["available_scan_counts"] == {
        "2026-07-09T00:00:00Z": 1,
        "2026-07-01T00:00:00Z": 1,
    }


def test_changes_digest_includes_dependency_changes_from_the_same_scan(monkeypatch):
    item_rows = [
        {"event_date": "2026-07-09", "event_type": "added", "qualified_name": "new-item-1", "scan_started_at": "2026-07-09T00:00:00Z"},
    ]
    _patch_csv(monkeypatch, {m.ITEM_HISTORY_PATH: item_rows})
    dependency_rows = [
        # A different (earlier) scan run -- must be excluded, same as the item-history test above.
        {"event_date": "2026-07-01", "event_type": "added", "from_qualified_name": "old-from", "to_qualified_name": "old-to", "relationship_type": "depends_on", "scan_started_at": "2026-07-01T00:00:00Z"},
        {"event_date": "2026-07-09", "event_type": "added", "from_qualified_name": "a", "to_qualified_name": "b", "relationship_type": "depends_on", "scan_started_at": "2026-07-09T00:00:00Z"},
        {"event_date": "2026-07-09", "event_type": "removed", "from_qualified_name": "c", "to_qualified_name": "d", "relationship_type": "writes_to", "scan_started_at": "2026-07-09T00:00:00Z"},
    ]
    monkeypatch.setattr(m.warehouse, "query_bronze_table", lambda table_name, use_cache=True: dependency_rows)
    result = m._get_changes_digest()
    assert result["dependencies"]["added_count"] == 1
    assert result["dependencies"]["removed_count"] == 1
    assert result["dependencies"]["modified_count"] == 0
    assert len(result["dependencies"]["changes"]) == 2
    assert all(c["from_qualified_name"] != "old-from" for c in result["dependencies"]["changes"])


def test_changes_digest_dependencies_degrades_gracefully_on_warehouse_error(monkeypatch):
    item_rows = [
        {"event_date": "2026-07-09", "event_type": "added", "qualified_name": "new-item-1", "scan_started_at": "2026-07-09T00:00:00Z"},
    ]
    _patch_csv(monkeypatch, {m.ITEM_HISTORY_PATH: item_rows})

    def raise_error(table_name, use_cache=True):
        raise m.warehouse.WarehouseError("boom")
    monkeypatch.setattr(m.warehouse, "query_bronze_table", raise_error)
    result = m._get_changes_digest()
    assert result["dependencies"] == {"added_count": 0, "removed_count": 0, "modified_count": 0, "total_count": 0, "changes": []}
