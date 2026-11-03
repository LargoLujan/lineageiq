"""Read-only queries over the existing index/*.csv and data/*.json lineage
artifacts, exposed over HTTP (Tanda 5, E.2). This is the same data
mcp_server.py's tools already read directly off disk for a local MCP
client; the query semantics here (substring matching, exact-name
disambiguation) are deliberately copied from there rather than reinvented,
so a remote caller and a local AI agent answer the same question the same
way. Tanda 6, F.2 is expected to eventually make mcp_server.py call these
endpoints instead of reading the files itself, at which point this becomes
the single implementation both surfaces share.
"""
import csv
import json

from . import warehouse
from .paths import (
    DEPENDENCIES_INDEX_PATH,
    EXECUTION_DURATION_BY_ITEM_PATH,
    FAILURE_HOTSPOTS_PATH,
    GRAPH_MAP_INDEX_OBJECTS_PATH,
    ITEMS_INDEX_PATH,
    NOTEBOOK_DEFINITIONS_DIR,
    NOTEBOOK_SUPER_LINEAGE_PATH,
    OBJECT_IMPACT_PATH,
    REPO_ROOT,
    SCHEDULE_REVIEW_CANDIDATES_PATH,
    WORKSPACE_INDEX_PATH,
    WORKSPACE_ROLE_ASSIGNMENTS_PATH,
)


def _read_csv_rows(path):
    if not path.exists():
        return []
    with open(path, "r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def _warehouse_or_local(table_name, local_path):
    """Live-Warehouse read when an admin has opted in (lakehouse.
    web_read_mode == "warehouse"), otherwise -- and always on any
    Warehouse failure -- the same local index/*.csv read this project has
    always done. See warehouse.py's own docstring for why this is a fixed
    service-principal identity rather than a per-user token."""
    if warehouse.is_warehouse_read_enabled():
        try:
            return warehouse.query_bronze_table(table_name)
        except warehouse.WarehouseError as exc:
            print(f"[catalog] Warehouse read of dbo.{table_name} failed, falling back to {local_path.name}: {exc}")
    return _read_csv_rows(local_path)


def _workspace_rows():
    return _warehouse_or_local("bronze_workspaces", WORKSPACE_INDEX_PATH)


def _item_rows():
    return _warehouse_or_local("bronze_items", ITEMS_INDEX_PATH)


def _dependency_rows():
    return _warehouse_or_local("bronze_dependencies", DEPENDENCIES_INDEX_PATH)


def _read_json_file(path):
    if not path.exists():
        return None
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _norm(value):
    return (value or "").strip().casefold()


# Same generic, item-type-agnostic /groups/{workspaceId}/items/{itemId} deep
# link mcp_server.py and the web UI (app.js/graph-map.js) construct -- kept
# in sync deliberately, see mcp_server.py's own comment on _fabric_item_url
# for why this is a constructed URL rather than one read straight off the
# Fabric API (which has no webUrl-style field on an item).
_workspace_ids_by_name_cache = None
_items_by_qualified_name_cache = None
_notebook_lineage_rows_by_item_cache = None


def _workspace_ids_by_name():
    global _workspace_ids_by_name_cache
    if _workspace_ids_by_name_cache is None:
        _workspace_ids_by_name_cache = {
            row.get("workspace_name", ""): row.get("technical_id", "")
            for row in _workspace_rows()
        }
    return _workspace_ids_by_name_cache


def _items_by_qualified_name():
    global _items_by_qualified_name_cache
    if _items_by_qualified_name_cache is None:
        _items_by_qualified_name_cache = {
            row.get("qualified_name", ""): row for row in _item_rows()
        }
    return _items_by_qualified_name_cache


def _fabric_workspace_url(workspace_name):
    workspace_id = _workspace_ids_by_name().get(workspace_name, "")
    if not workspace_id:
        return ""
    return f"https://app.fabric.microsoft.com/groups/{workspace_id}/list"


def _fabric_item_url(item_row):
    item_id = item_row.get("technical_id", "")
    workspace_id = _workspace_ids_by_name().get(item_row.get("workspace_name", ""), "")
    if not item_id or not workspace_id:
        return ""
    return f"https://app.fabric.microsoft.com/groups/{workspace_id}/items/{item_id}?experience=fabric-developer"


def _item_link_fields(qualified_name):
    item_row = _items_by_qualified_name().get(qualified_name)
    if not item_row:
        return {"technical_id": "", "workspace_id": "", "fabric_url": ""}
    return {
        "technical_id": item_row.get("technical_id", ""),
        "workspace_id": _workspace_ids_by_name().get(item_row.get("workspace_name", ""), ""),
        "fabric_url": _fabric_item_url(item_row),
    }


# Roadmap Fase 2 (2026-08-17, Tanda 6 F.2 follow-through): mcp_server.py's
# list_workspaces tool used to read index/workspaces.csv directly, the same
# July snapshot every other tool here has already moved off of via
# _warehouse_or_local -- which can be stale (far fewer rows than the tenant really has)
# while auditing what the MCP surface actually answers with. This gives it
# the same live-Warehouse-when-enabled, local-CSV-fallback path as
# everything else in this module.
def _list_workspaces(name_contains=""):
    rows = _workspace_rows()
    needle = _norm(name_contains)
    results = []
    for row in rows:
        if needle and needle not in _norm(row.get("workspace_name", "")):
            continue
        results.append({
            "workspace_name": row.get("workspace_name", ""),
            "environment": row.get("environment", ""),
            "capacity_name": row.get("capacity_name", ""),
            "domain_name": row.get("domain_name", ""),
            "owner": row.get("owner", ""),
            "status": row.get("status", ""),
            "workspace_id": row.get("technical_id", ""),
            "fabric_url": _fabric_workspace_url(row.get("workspace_name", "")),
        })
    return results


# Roadmap Fase 2 (2026-08-17): column-level statistical profiling
# (null %, distinct count, safe min/max) for Fabric-native Lakehouse
# tables -- see fabric_notebooks/NB_Discover_Column_Profile.py. Scoped to
# whichever workspaces the service principal already had a data role in
# at the time (external SQL profiling is blocked on network connectivity,
# see docs/105_fabric_native_discovery_setup.md), so most tables in the
# tenant simply have no rows here yet -- callers must treat "found: False"
# as "not profiled", not "doesn't exist". No local CSV fallback: this
# table is only ever produced by the Fabric-native notebook, there was
# never a local-build equivalent to fall back to.
def _get_column_profile(workspace_name, lakehouse_name, table_name):
    try:
        rows = warehouse.query_bronze_table("bronze_column_profile")
    except warehouse.WarehouseError as exc:
        print(f"[catalog] Warehouse read of dbo.bronze_column_profile failed: {exc}")
        return {"found": False, "columns": []}

    needle_workspace = _norm(workspace_name)
    needle_lakehouse = _norm(lakehouse_name)
    needle_table = _norm(table_name)
    matches = [
        row for row in rows
        if _norm(row.get("workspace_name", "")) == needle_workspace
        and _norm(row.get("lakehouse_name", "")) == needle_lakehouse
        and _norm(row.get("table_name", "")) == needle_table
    ]
    if not matches:
        return {"found": False, "columns": []}

    columns = []
    for row in matches:
        row_count = int(row.get("row_count") or 0)
        null_count = int(row.get("null_count") or 0)
        columns.append({
            "column_name": row.get("column_name", ""),
            "data_type": row.get("data_type", ""),
            "row_count": row_count,
            "null_count": null_count,
            "null_percentage": float(row.get("null_percentage") or 0.0),
            "distinct_count": int(row.get("distinct_count") or 0) if row.get("distinct_count") else None,
            "min_value": row.get("min_value") or None,
            "max_value": row.get("max_value") or None,
        })
    return {
        "found": True,
        "profiled_at": matches[0].get("profiled_at", ""),
        "columns": columns,
    }


# Roadmap Fase 2 (2026-08-17): content-based sensitivity signals (email/
# phone/national_id/financial regex matches against a bounded sample of
# real cell values) -- see fabric_notebooks/NB_Discover_Column_
# Sensitivity.py. Same scope/fallback contract as _get_column_profile
# just above: only the workspaces the SP already had a data role in, no
# local CSV fallback. The underlying table itself never carries a real
# cell value (verified in the notebook's own write path) -- only match
# percentages, so this function can't leak anything the notebook didn't
# already refuse to store.
def _get_column_sensitivity(workspace_name, lakehouse_name, table_name):
    try:
        rows = warehouse.query_bronze_table("bronze_column_sensitivity_content")
    except warehouse.WarehouseError as exc:
        print(f"[catalog] Warehouse read of dbo.bronze_column_sensitivity_content failed: {exc}")
        return {"found": False, "columns": []}

    needle_workspace = _norm(workspace_name)
    needle_lakehouse = _norm(lakehouse_name)
    needle_table = _norm(table_name)
    matches = [
        row for row in rows
        if _norm(row.get("workspace_name", "")) == needle_workspace
        and _norm(row.get("lakehouse_name", "")) == needle_lakehouse
        and _norm(row.get("table_name", "")) == needle_table
    ]
    if not matches:
        return {"found": False, "columns": []}

    by_column = {}
    for row in matches:
        column_name = row.get("column_name", "")
        entry = by_column.setdefault(column_name, {
            "column_name": column_name,
            "data_type": row.get("data_type", ""),
            "categories": [],
        })
        entry["categories"].append({
            "category": row.get("category", ""),
            "sample_size": int(row.get("sample_size") or 0),
            "match_count": int(row.get("match_count") or 0),
            "match_percentage": float(row.get("match_percentage") or 0.0),
        })
    return {
        "found": True,
        "checked_at": matches[0].get("checked_at", ""),
        "columns": list(by_column.values()),
    }


def _find_items(query, items):
    needle = _norm(query)
    exact = [row for row in items if _norm(row.get("qualified_name", "")) == needle]
    if exact:
        return exact
    return [
        row for row in items
        if needle in _norm(row.get("item_name", "")) or needle in _norm(row.get("qualified_name", ""))
    ]


def _search_items(query, item_type="", limit=20):
    items = _item_rows()
    matches = _find_items(query, items)
    if item_type:
        matches = [row for row in matches if row.get("item_type") == item_type]
    return {
        "total_matches": len(matches),
        "items": [
            {
                "qualified_name": row.get("qualified_name", ""),
                "item_name": row.get("item_name", ""),
                "item_type": row.get("item_type", ""),
                "workspace_name": row.get("workspace_name", ""),
                "status": row.get("status", ""),
                "technical_id": row.get("technical_id", ""),
                "fabric_url": _fabric_item_url(row),
            }
            for row in matches[:limit]
        ],
    }


def _get_item_lineage(qualified_name):
    items = _item_rows()
    matches = _find_items(qualified_name, items)
    if len(matches) == 0:
        return {"found": False, "candidates": []}
    if len(matches) > 1:
        return {
            "found": False,
            "reason": "ambiguous_query",
            "candidates": [
                {"qualified_name": row.get("qualified_name", ""), "item_type": row.get("item_type", "")}
                for row in matches[:25]
            ],
        }

    item = matches[0]
    target = item.get("qualified_name", "")
    deps = _dependency_rows()
    upstream = [row for row in deps if row.get("to_qualified_name") == target]
    downstream = [row for row in deps if row.get("from_qualified_name") == target]

    def _edge(row, other_key):
        other_qualified_name = row.get(other_key, "")
        return {
            "qualified_name": other_qualified_name,
            "relationship_type": row.get("relationship_type", ""),
            "confidence": row.get("confidence", ""),
            "evidence": row.get("evidence", ""),
            **_item_link_fields(other_qualified_name),
        }

    return {
        "found": True,
        "item": {
            "qualified_name": target,
            "item_name": item.get("item_name", ""),
            "item_type": item.get("item_type", ""),
            "workspace_name": item.get("workspace_name", ""),
            "description": item.get("description", ""),
            "default_identity": item.get("default_identity", ""),
            "status": item.get("status", ""),
            "technical_id": item.get("technical_id", ""),
            "fabric_url": _fabric_item_url(item),
        },
        "upstream": [_edge(row, "from_qualified_name") for row in upstream],
        "downstream": [_edge(row, "to_qualified_name") for row in downstream],
        "upstream_count": len(upstream),
        "downstream_count": len(downstream),
    }


def _object_impact_candidate_rows():
    """Live-Warehouse alternative to OBJECT_IMPACT_PATH's pre-built JSON:
    dbo.bronze_item_object_lineage_candidates + dbo.bronze_pipeline_
    object_lineage_candidates (see fabric_notebooks/NB_Discover_Object_
    Lineage.py / NB_Discover_Pipeline_Object_Lineage.py) + dbo.bronze_
    control_framework_lineage_candidates (Fase C, NB_Extract_Control_
    Framework_Lineage.py, added 2026-08-19 -- runtime-confirmed lineage
    for the ~37% of notebooks/copyjobs whose code names no target table)
    all share the same 17-column base shape, so a plain concatenation is
    enough. Returns None (never an empty list) when Warehouse reads
    aren't enabled or fail, so the caller can tell "no live data, use the
    local JSON" apart from "live data, but nothing matched this search".
    Deliberately excludes dbo.bronze_semantic_model_view_candidates for
    now -- its schema is semantic-table-centric, not item-centric, and
    would need its own merge shape; a future extension, not started."""
    if not warehouse.is_warehouse_read_enabled():
        return None
    try:
        rows = list(warehouse.query_bronze_table("bronze_item_object_lineage_candidates"))
        rows += warehouse.query_bronze_table("bronze_pipeline_object_lineage_candidates")
        try:
            rows += warehouse.query_bronze_table("bronze_control_framework_lineage_candidates")
        except warehouse.WarehouseError:
            pass  # table doesn't exist yet on a Warehouse that predates Fase C -- item/pipeline candidates alone are still a valid result
        return rows
    except warehouse.WarehouseError as exc:
        print(f"[catalog] Warehouse read of object-lineage candidates failed, falling back to object-impact.json: {exc}")
        return None


def _object_display_name(row):
    return ".".join(part for part in (row.get("source_database", ""), row.get("schema_name", ""), row.get("object_name", "")) if part)


def _object_key(source_server, source_database, schema_name, object_name):
    return tuple(_norm(v) for v in (source_server, source_database, schema_name, object_name))


def _object_columns_by_key():
    """{(server, database, schema, object) -> [column rows]}, from Fase B's
    NB_Extract_Object_Column_Catalog (dbo.bronze_object_column_catalog,
    added 2026-08-19). Distinct from the external-source gateway approach
    rolled back 2026-08-18 -- this covers Fabric-internal SQL endpoints the
    service principal can reach directly, no per-source pipeline needed.
    Row shape (column_name/data_type/max_length/precision/scale/
    is_nullable) matches what app.js's detailColumnRows/columnTypeDisplay
    already render for the object-impact.json path, so the frontend needs
    no changes to pick these up. Empty dict (not an exception) when the
    table doesn't exist yet, same tolerant pattern as every other
    live-Warehouse reader in this module."""
    try:
        rows = warehouse.query_bronze_table("bronze_object_column_catalog")
    except warehouse.WarehouseQueryError:
        return {}
    columns_by_key = {}
    for row in rows:
        key = _object_key(row.get("source_server", ""), row.get("source_database", ""), row.get("schema_name", ""), row.get("object_name", ""))
        columns_by_key.setdefault(key, []).append(row)
    for columns in columns_by_key.values():
        columns.sort(key=lambda c: int(c.get("column_id") or 0))
    return columns_by_key


def _object_type_overrides_by_key():
    """{(server, database, schema, object) -> confirmed object_type}, from
    Fase A's NB_Extract_SQL_Endpoint_Catalog (dbo.bronze_sql_endpoint_
    object_catalog) -- a real sys.objects match beats whatever a regex
    candidate guessed (table_or_view, native_query_object, ...)."""
    try:
        rows = warehouse.query_bronze_table("bronze_sql_endpoint_object_catalog")
    except warehouse.WarehouseQueryError:
        return {}
    overrides = {}
    for row in rows:
        key = _object_key(row.get("source_server", ""), row.get("source_database", ""), row.get("schema_name", ""), row.get("object_name", ""))
        if row.get("object_type"):
            overrides[key] = row["object_type"]
    return overrides


def _get_object_impact_from_warehouse(query, limit, candidate_rows):
    """Same response shape as the object-impact.json path below, built
    live from NB_Discover_Object_Lineage/NB_Discover_Pipeline_Object_
    Lineage's candidate tables instead. columns/column_count and
    object_type_values now enrich from Fase A/B's confirmed catalogs
    (dbo.bronze_sql_endpoint_object_catalog / dbo.bronze_object_column_
    catalog, added 2026-08-19) when a match exists; both fall back to the
    candidate's own guess (empty / whatever the regex parser produced)
    when there's no confirmed catalog row for that object yet -- same
    "record gaps, don't fabricate" convention as the rest of this project.
    downstream_reports remains empty (needs the semantic-model-to-report
    propagation logic in 21_build_reverse_impact_package_fast.py, not
    ported)."""
    columns_by_key = _object_columns_by_key()
    object_type_overrides = _object_type_overrides_by_key()
    needle = _norm(query)
    groups = {}
    for row in candidate_rows:
        if not row.get("object_name"):
            continue
        display_name = _object_display_name(row)
        if needle not in _norm(display_name):
            continue
        key = (row.get("source_server", ""), row.get("source_database", ""), row.get("schema_name", ""), row.get("object_name", ""))
        groups.setdefault(key, {"display_name": display_name, "row": row, "consumers": {}})
        consumers = groups[key]["consumers"]
        item_qn = row.get("item_qualified_name", "")
        if not item_qn:
            continue
        existing = consumers.get(item_qn)
        if not existing or (existing.get("confidence") != "confirmed" and row.get("confidence") == "confirmed"):
            consumers[item_qn] = row

    matched_keys = sorted(groups.keys(), key=lambda k: (-len(groups[k]["consumers"]), _norm(groups[k]["display_name"])))
    results = []
    for key in matched_keys[:limit]:
        group = groups[key]
        first = group["row"]
        consumer_rows = sorted(group["consumers"].values(), key=lambda r: (_norm(r.get("item_type", "")), _norm(r.get("workspace_name", "")), _norm(r.get("item_name", ""))))
        object_key = _object_key(first.get("source_server", ""), first.get("source_database", ""), first.get("schema_name", ""), first.get("object_name", ""))
        columns = columns_by_key.get(object_key, [])
        confirmed_type = object_type_overrides.get(object_key, "")
        results.append({
            "object_display_name": group["display_name"],
            "source_type": first.get("source_type", ""),
            "source_server": first.get("source_server", ""),
            "source_database": first.get("source_database", ""),
            "schema_name": first.get("schema_name", ""),
            "object_name": first.get("object_name", ""),
            "object_type_values": confirmed_type or first.get("object_type", ""),
            "columns": columns,
            "column_count": len(columns),
            "affected_item_count": len(consumer_rows),
            "downstream_report_count": 0,
            "direct_consumers": [
                {
                    "label": row.get("item_name", ""),
                    "item_type": row.get("item_type", ""),
                    "workspace_name": row.get("workspace_name", ""),
                    "qualified_name": row.get("item_qualified_name", ""),
                    "confidence": row.get("confidence", ""),
                    **_item_link_fields(row.get("item_qualified_name", "")),
                }
                for row in consumer_rows
            ],
            "downstream_reports": [],
        })

    return {
        "found": len(results) > 0,
        "total_matches": len(matched_keys),
        "objects": results,
    }


def _get_object_impact(query, limit=5):
    candidate_rows = _object_impact_candidate_rows()
    if candidate_rows is not None:
        return _get_object_impact_from_warehouse(query, limit, candidate_rows)

    payload = _read_json_file(OBJECT_IMPACT_PATH)
    if not payload:
        return {"found": False, "reason": "object-impact.json not built yet -- run the 11 -> 17 -> 21 chain."}

    needle = _norm(query)
    objects = payload.get("objects", [])
    matches = [obj for obj in objects if needle in _norm(obj.get("object_display_name", ""))]

    results = []
    for obj in matches[:limit]:
        results.append({
            "object_display_name": obj.get("object_display_name", ""),
            "source_type": obj.get("source_type", ""),
            "source_server": obj.get("source_server", ""),
            "source_database": obj.get("source_database", ""),
            "schema_name": obj.get("schema_name", ""),
            "object_name": obj.get("object_name", ""),
            "object_type_values": obj.get("object_type_values", ""),
            "columns": obj.get("columns", []),
            "column_count": len(obj.get("columns", [])),
            "affected_item_count": obj.get("affected_item_count", 0),
            "downstream_report_count": obj.get("downstream_report_count", 0),
            "direct_consumers": [
                {
                    "label": item.get("label", ""),
                    "item_type": item.get("item_type", ""),
                    "workspace_name": item.get("workspace_name", ""),
                    "qualified_name": item.get("qualified_name", ""),
                    "confidence": item.get("confidence", ""),
                    **_item_link_fields(item.get("qualified_name", "")),
                }
                for item in obj.get("direct_items", [])
            ],
            "downstream_reports": [
                {
                    "label": report.get("label", ""),
                    "workspace_name": report.get("workspace_name", ""),
                    "qualified_name": report.get("qualified_name", ""),
                    "confidence": report.get("confidence", ""),
                    **_item_link_fields(report.get("qualified_name", "")),
                }
                for report in obj.get("downstream_reports", [])
            ],
        })

    return {
        "found": len(results) > 0,
        "total_matches": len(matches),
        "objects": results,
    }


# See mcp_server.py's get_notebook_code for why this exists (understanding a
# notebook's real transformation logic, not just its lineage edges) and why
# 60k chars (comfortably inside every current agent context window while
# covering the large majority of real-world notebooks).
_NOTEBOOK_CODE_MAX_CHARS = 60000


def _notebook_lineage_rows_by_item():
    global _notebook_lineage_rows_by_item_cache
    if _notebook_lineage_rows_by_item_cache is None:
        payload = _read_json_file(NOTEBOOK_SUPER_LINEAGE_PATH) or {}
        index = {}
        for row in payload.get("objects", []):
            index.setdefault(row.get("item_qualified_name", ""), []).append(row)
        for rows in index.values():
            rows.sort(key=lambda row: int(row.get("line_number") or 0))
        _notebook_lineage_rows_by_item_cache = index
    return _notebook_lineage_rows_by_item_cache


def _get_notebook_code(qualified_name, max_chars=_NOTEBOOK_CODE_MAX_CHARS):
    items = _item_rows()
    matches = [row for row in _find_items(qualified_name, items) if row.get("item_type") == "Notebook"]
    if len(matches) == 0:
        return {"found": False, "candidates": []}
    if len(matches) > 1:
        return {
            "found": False,
            "reason": "ambiguous_query",
            "candidates": [{"qualified_name": row.get("qualified_name", "")} for row in matches[:25]],
        }

    item = matches[0]
    target = item.get("qualified_name", "")
    lineage_rows = _notebook_lineage_rows_by_item().get(target, [])
    definition_path = next((row.get("definition_path", "") for row in lineage_rows if row.get("definition_path")), "")
    if not definition_path:
        definition_path = f"data/notebook_definitions/{item.get('workspace_name', '')}/{item.get('item_name', '')}.Notebook/notebook-content.py"

    # Same .resolve()+containment guard handler.py already applies to
    # /api/history/diff and static-file serving -- definition_path here is
    # either the fallback pattern above (workspace_name/item_name are real
    # Fabric display names, which anyone with item-creation rights in the
    # tenant controls, not just this app's admins) or a value stored in
    # lineage_rows by a scan; neither is a value this endpoint's own
    # caller can set directly, but nothing upstream contains it against
    # NOTEBOOK_DEFINITIONS_DIR either (2026-08-17 security audit).
    code_file = (REPO_ROOT / definition_path.replace("\\", "/")).resolve()
    try:
        code_file.relative_to(NOTEBOOK_DEFINITIONS_DIR.resolve())
    except ValueError:
        code_file = None
    code_available = code_file is not None and code_file.is_file()
    code = ""
    truncated = False
    if code_available:
        code = code_file.read_text(encoding="utf-8", errors="replace")
        if len(code) > max_chars:
            code = code[:max_chars]
            truncated = True

    return {
        "found": True,
        "qualified_name": target,
        "workspace_name": item.get("workspace_name", ""),
        **_item_link_fields(target),
        "code_available": code_available,
        "code": code,
        "truncated": truncated,
        "reason": "" if code_available else "This notebook's definition was never downloaded during a scan -- code isn't available, only the parsed lineage rows below, if any.",
        "parsed_operations": [
            {
                "line_number": row.get("line_number", ""),
                "direction": row.get("direction", ""),
                "operation": row.get("operation", ""),
                "source_type": row.get("source_type", ""),
                "object_display_name": row.get("object_display_name", ""),
                "confidence": row.get("confidence", ""),
                "evidence": row.get("evidence", ""),
            }
            for row in lineage_rows
        ],
    }


# Roadmap Fase 2 (2026-08-18): the 6 tools that were only ever available in
# mcp_server.py's LOCAL (stdio) server -- get_related_elements,
# get_objects_for_item, get_workspace_roles, get_execution_stats,
# get_failure_hotspots, get_schedules -- ported here so they're also
# reachable over HTTP (and therefore from mcp_server_remote.py, for any
# colleague/agent that isn't running this repo locally). Query semantics
# copied verbatim from mcp_server.py's own implementations, same as every
# other function in this module -- a remote caller and a local AI agent
# answer the same question the same way. Like get_workspace_roles/
# get_execution_stats/get_failure_hotspots/get_schedules already did
# locally, these still read their local artifacts directly (no live-
# Warehouse path) -- get_related_elements is the one exception, built on
# _dependency_rows() (already Warehouse-aware) instead of a raw CSV read,
# so it gets that fallback for free.

# A real graph index, not a per-call scan -- built once per process from
# _dependency_rows() (an item's direct upstream/downstream) so "what's
# related to X, a few hops out" is an O(hops) BFS over a prebuilt adjacency
# map instead of a fresh linear scan per call. Cached for the life of this
# process, same convention as _workspace_ids_by_name_cache above --
# restart the server after a rescan to pick up new dependency rows.
_relationship_index_cache = None


def _relationship_index():
    global _relationship_index_cache
    if _relationship_index_cache is not None:
        return _relationship_index_cache
    outgoing = {}
    incoming = {}
    for row in _dependency_rows():
        src = row.get("from_qualified_name", "")
        dst = row.get("to_qualified_name", "")
        if not src or not dst:
            continue
        outgoing.setdefault(src, []).append(
            {"qualified_name": dst, "relationship_type": row.get("relationship_type", ""), "confidence": row.get("confidence", "")}
        )
        incoming.setdefault(dst, []).append(
            {"qualified_name": src, "relationship_type": row.get("relationship_type", ""), "confidence": row.get("confidence", "")}
        )
    _relationship_index_cache = {"outgoing": outgoing, "incoming": incoming}
    return _relationship_index_cache


def _traverse_relationship_index(start, direction, max_hops, limit):
    # "upstream" = what start depends on = start's own outgoing edges (a
    # dependency row is stored from=dependent, to=dependency -- matches the
    # same convention frontend/semantic-lineage/graph-map-data.js's
    # traverse() already documents and uses for the web UI's own upstream/
    # downstream buttons).
    index = _relationship_index()
    link_map = index["outgoing"] if direction == "upstream" else index["incoming"]
    visited = {start: 0}
    queue = [(start, 0)]
    results = []
    while queue and len(results) < limit:
        current, depth = queue.pop(0)
        if depth >= max_hops:
            continue
        for link in link_map.get(current, []):
            neighbor = link["qualified_name"]
            if neighbor in visited:
                continue
            visited[neighbor] = depth + 1
            results.append({
                "qualified_name": neighbor,
                "hops": depth + 1,
                "relationship_type": link["relationship_type"],
                "confidence": link["confidence"],
                "via": current,
                **_item_link_fields(neighbor),
            })
            queue.append((neighbor, depth + 1))
            if len(results) >= limit:
                break
    return results


def _get_related_elements(qualified_name, direction="both", max_hops=2, limit=100):
    items = _item_rows()
    matches = _find_items(qualified_name, items)
    if len(matches) == 0:
        return {"found": False, "candidates": []}
    if len(matches) > 1:
        return {
            "found": False,
            "reason": "ambiguous_query",
            "candidates": [
                {"qualified_name": row.get("qualified_name", ""), "item_type": row.get("item_type", "")}
                for row in matches[:25]
            ],
        }

    target = matches[0].get("qualified_name", "")
    result = {"found": True, "qualified_name": target, "max_hops": max_hops, **_item_link_fields(target)}
    if direction in ("upstream", "both"):
        result["upstream"] = _traverse_relationship_index(target, "upstream", max_hops, limit)
    if direction in ("downstream", "both"):
        result["downstream"] = _traverse_relationship_index(target, "downstream", max_hops, limit)
    return result


def _get_objects_for_item(qualified_name):
    items = _item_rows()
    matches = _find_items(qualified_name, items)
    if len(matches) == 0:
        return {"found": False, "candidates": []}
    if len(matches) > 1:
        return {
            "found": False,
            "reason": "ambiguous_query",
            "candidates": [
                {"qualified_name": row.get("qualified_name", ""), "item_type": row.get("item_type", "")}
                for row in matches[:25]
            ],
        }

    target = matches[0].get("qualified_name", "")
    object_graph = _read_json_file(GRAPH_MAP_INDEX_OBJECTS_PATH)
    if not object_graph:
        return {"found": False, "reason": "graph-map-index-objects.json not built yet -- run backend/scripts/build_graph_map_index.py."}

    edge_indices = object_graph.get("by_item_id", {}).get(target, [])
    nodes_by_id = {n["data"]["id"]: n["data"] for n in object_graph.get("nodes", [])}
    objects = []
    for position in edge_indices:
        edge = object_graph["edges"][position]["data"]
        obj = nodes_by_id.get(edge.get("source", ""))
        if not obj:
            continue
        objects.append({
            "object_display_name": obj.get("label", ""),
            "source_type": obj.get("source_type", ""),
            "source_server": obj.get("source_server", ""),
            "source_database": obj.get("source_database", ""),
            "column_count": obj.get("column_count", 0),
            "relationship_type": edge.get("relationship_type", ""),
            "confidence": edge.get("confidence", ""),
        })

    return {"found": True, "qualified_name": target, "object_count": len(objects), "objects": objects}


def _get_workspace_roles(workspace_name):
    rows = _read_csv_rows(WORKSPACE_ROLE_ASSIGNMENTS_PATH)
    if not rows:
        return {"found": False, "reason": "index/workspace_role_assignments.csv not built yet -- run backend/scripts/68_discover_workspace_role_assignments.ps1."}

    needle = _norm(workspace_name)
    exact = [row for row in rows if _norm(row.get("workspace_name", "")) == needle]
    matches = exact or [row for row in rows if needle in _norm(row.get("workspace_name", ""))]
    assignments = [row for row in matches if row.get("status") == "discovered"]

    return {
        "found": len(matches) > 0,
        "workspace_name": matches[0].get("workspace_name", "") if matches else "",
        "assignment_count": len(assignments),
        "assignments": [
            {
                "principal_name": row.get("principal_name", ""),
                "principal_email": row.get("principal_email", ""),
                "principal_type": row.get("principal_type", ""),
                "role": row.get("role", ""),
            }
            for row in assignments
        ],
    }


def _get_execution_stats(query, limit=10):
    rows = _read_csv_rows(EXECUTION_DURATION_BY_ITEM_PATH)
    if not rows:
        return {"found": False, "reason": "analysis/execution_duration_by_item.csv not built yet -- run backend/scripts/06_discover_executions.ps1."}

    needle = _norm(query)
    matches = [row for row in rows if needle in _norm(row.get("item_name", ""))]
    return {
        "found": len(matches) > 0,
        "total_matches": len(matches),
        "items": [
            {
                "workspace_name": row.get("workspace_name", ""),
                "item_name": row.get("item_name", ""),
                "item_type": row.get("item_type", ""),
                "job_type": row.get("job_type", ""),
                "run_count": row.get("run_count", ""),
                "completed_count": row.get("completed_count", ""),
                "failed_count": row.get("failed_count", ""),
                "cancelled_count": row.get("cancelled_count", ""),
                "scheduled_count": row.get("scheduled_count", ""),
                "manual_count": row.get("manual_count", ""),
                "avg_duration_seconds": row.get("avg_duration_seconds", ""),
                "median_duration_seconds": row.get("median_duration_seconds", ""),
                "max_duration_seconds": row.get("max_duration_seconds", ""),
                "last_status": row.get("last_status", ""),
                "latest_start_time": row.get("latest_start_time", ""),
            }
            for row in matches[:limit]
        ],
    }


def _get_failure_hotspots(limit=20):
    rows = _read_csv_rows(FAILURE_HOTSPOTS_PATH)
    return [
        {
            "workspace_name": row.get("workspace_name", ""),
            "item_name": row.get("item_name", ""),
            "item_type": row.get("item_type", ""),
            "job_type": row.get("job_type", ""),
            "run_count": row.get("run_count", ""),
            "failed_count": row.get("failed_count", ""),
            "failure_rate": row.get("failure_rate", ""),
            "last_status": row.get("last_status", ""),
            "latest_start_time": row.get("latest_start_time", ""),
        }
        for row in rows[:limit]
    ]


def _get_schedules(query="", workspace_name=""):
    rows = _read_csv_rows(SCHEDULE_REVIEW_CANDIDATES_PATH)
    if not rows:
        return {"found": False, "reason": "analysis/schedule_review_candidates.csv not built yet -- run backend/scripts/06_discover_executions.ps1 then 07_optimize_orchestration.ps1."}

    needle = _norm(query)
    workspace_needle = _norm(workspace_name)
    matches = [
        row
        for row in rows
        if (not needle or needle in _norm(row.get("item_name", "")))
        and (not workspace_needle or workspace_needle in _norm(row.get("workspace_name", "")))
    ]
    return {
        "found": len(matches) > 0,
        "total_matches": len(matches),
        "items": [
            {
                "workspace_name": row.get("workspace_name", ""),
                "item_name": row.get("item_name", ""),
                "item_type": row.get("item_type", ""),
                "enabled_schedules": row.get("enabled_schedules", ""),
                "disabled_schedules": row.get("disabled_schedules", ""),
                "schedule_times": row.get("schedule_times", ""),
                "schedule_timezones": row.get("schedule_timezones", ""),
                "run_count": row.get("run_count", ""),
                "failed_count": row.get("failed_count", ""),
                "avg_duration_seconds": row.get("avg_duration_seconds", ""),
            }
            for row in matches
        ],
    }
