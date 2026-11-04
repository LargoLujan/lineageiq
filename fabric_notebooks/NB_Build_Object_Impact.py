# NB_Build_Object_Impact
#
# Source for a Fabric Python notebook -- ninth step of the native
# discovery pipeline, after NB_Build_Lineage_Explorer (see docs/
# 105_fabric_native_discovery_setup.md). Each "# %%" block is a cell
# -- paste them in order.
#
# Faithful, merged port of backend/scripts/17_build_object_impact_index_
# fast.py (builds the object->item impact rows) + backend/scripts/
# 21_build_reverse_impact_package_fast.py (assembles them into the final JSON)
# -- the ALGORITHM of both is exactly the same, without rewriting a
# single line of that logic; the only thing that changes is the I/O layer:
#   - lineage-explorer.json is read from OneLake (already published by NB_Build_
#     Lineage_Explorer, the previous step) instead of local disk.
#   - read_csv() now queries a bronze table of the Warehouse instead of
#     reading a local CSV (INPUT_TABLE_BY_ARG further down) -- only bronze_
#     pipeline_object_lineage_candidates exists today; the rest degrades to
#     an empty list, same as a missing CSV in the original scripts.
#   - the two original scripts communicated through 4 intermediate
#     CSVs (object_impact_index.csv, object_impact_summary.csv,
#     plus the coverage ones); here they go straight in memory from script 17 to
#     script 21 -- the coverage ones are not generated because nothing in the
#     live web app consumes them (they were just a local informational document).
#   - object-impact.json is written to OneLake (Files/generated/) instead
#     of local disk.
#
# Self-contained on purpose, same criterion as the previous notebooks.

# %% [markdown]
# ## Configuration

# %%
try:
    import msal  # noqa: F401
except ImportError:
    get_ipython().run_line_magic("pip", "install msal")
    import msal

try:
    import pyodbc  # noqa: F401
except ImportError:
    get_ipython().run_line_magic("pip", "install pyodbc")
    import pyodbc

import csv
import io
import json
import os
import re
import struct
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"
WAREHOUSE_SQL_ENDPOINT = "<your-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<WarehouseName>"

# Read/write Lakehouse for the large JSON files -- same item as
# NB_Build_Lineage_Explorer. Our own secret is also read from here
# (SP_SECRET_ONELAKE_PATH): no longer from Key Vault (blocked) nor from a
# pipeline parameter (tested 2026-08-12: it leaked the value in plain
# text when the type conversion failed -- never again that way).
ONELAKE_WORKSPACE_NAME = "<your-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<your-onelake-lakehouse>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"

EXPLORER_ONELAKE_PATH = "Files/generated/lineage-explorer.json"
OUTPUT_ONELAKE_PATH = "Files/generated/object-impact.json"

# Name of the Warehouse bronze table for each logical input that the
# two original scripts accepted as a file path -- "" = no
# equivalent table yet (degrades to an empty list, same as a missing CSV
# in the original scripts).
INPUT_TABLE_BY_ARG = {
    "object_type_resolution_queue_path": "",
    "pipeline_object_lineage_candidates_path": "bronze_pipeline_object_lineage_candidates",
    "sql_server_deep_catalog_path": "",
    "sql_endpoint_catalog_path": "bronze_sql_endpoint_object_catalog",
    "object_column_catalog_path": "bronze_object_column_catalog",
}

# %% [markdown]
# ## Authentication, Warehouse and OneLake (same pattern as the previous notebooks)

# %%
def get_client_secret():
    onelake_path = (
        f"abfss://{ONELAKE_WORKSPACE_NAME}@onelake.dfs.fabric.microsoft.com/"
        f"{ONELAKE_LAKEHOUSE_NAME}.Lakehouse/{SP_SECRET_ONELAKE_PATH}"
    )
    return notebookutils.fs.head(onelake_path, 200).strip()


def build_msal_app():
    return msal.ConfidentialClientApplication(
        SP_CLIENT_ID,
        authority=f"https://login.microsoftonline.com/{SP_TENANT_ID}",
        client_credential=get_client_secret(),
    )


def acquire_token(scope):
    app = build_msal_app()
    result = app.acquire_token_for_client(scopes=[scope])
    if not result or "access_token" not in result:
        description = (result or {}).get("error_description", "no access_token returned")
        raise RuntimeError(f"Could not acquire a token for {scope}: {description}")
    return result["access_token"]


def token_struct(token):
    raw = token.encode("utf-16-le")
    return struct.pack(f"<I{len(raw)}s", len(raw), raw)


def pick_odbc_driver():
    available = sorted(
        (d for d in pyodbc.drivers() if "ODBC Driver" in d and "SQL Server" in d),
        reverse=True,
    )
    if not available:
        raise RuntimeError(
            "No 'ODBC Driver NN for SQL Server' found in this runtime's "
            f"pyodbc.drivers() (saw: {pyodbc.drivers()})."
        )
    return available[0]


def connect_warehouse():
    db_token = acquire_token("https://database.windows.net/.default")
    conn_str = (
        f"DRIVER={{{pick_odbc_driver()}}};SERVER={WAREHOUSE_SQL_ENDPOINT};"
        f"DATABASE={WAREHOUSE_DATABASE_NAME};Encrypt=yes"
    )
    return pyodbc.connect(conn_str, attrs_before={1256: token_struct(db_token)}, timeout=30)


WAREHOUSE_CONNECTION = connect_warehouse()


def read_csv(logical_name):
    """Despite the name (kept so every read_csv(args.xxx_path) call site
    ported below stays unchanged), this reads a Warehouse bronze table,
    not a CSV file -- see INPUT_TABLE_BY_ARG. A table that doesn't exist
    yet degrades to [], exactly like a missing CSV file did originally."""
    table_name = INPUT_TABLE_BY_ARG.get(logical_name, "")
    if not table_name:
        return []
    cursor = WAREHOUSE_CONNECTION.cursor()
    try:
        cursor.execute(f"SELECT * FROM dbo.{table_name}")
    except pyodbc.Error:
        WAREHOUSE_CONNECTION.rollback()
        return []
    columns = [c[0] for c in cursor.description]
    return [dict(zip(columns, row)) for row in cursor.fetchall()]


def read_onelake_json(onelake_relative_path):
    abfss_path = (
        f"abfss://{ONELAKE_WORKSPACE_NAME}@onelake.dfs.fabric.microsoft.com/"
        f"{ONELAKE_LAKEHOUSE_NAME}.Lakehouse/{onelake_relative_path}"
    )
    # notebookutils.fs.head() silently truncates well below whatever
    # max_bytes you pass it (confirmed live, 2026-08-12: a 165KB
    # lineage-explorer.json came back cut at ~100KB -- "head" is a preview
    # API, not a full-read one, regardless of its own parameter name).
    # spark.read.text(..., wholetext=True) reads the whole file as a
    # single row with no such cap.
    content = spark.read.text(abfss_path, wholetext=True).collect()[0][0]
    return json.loads(content)


def write_json_atomic(onelake_relative_path, payload):
    abfss_path = (
        f"abfss://{ONELAKE_WORKSPACE_NAME}@onelake.dfs.fabric.microsoft.com/"
        f"{ONELAKE_LAKEHOUSE_NAME}.Lakehouse/{onelake_relative_path}"
    )
    notebookutils.fs.put(abfss_path, json.dumps(payload, ensure_ascii=False), True)


# %% [markdown]
# ## Build the impact rows (faithful port of 17_build_object_impact_index_fast.py)

# %%
EXACT_TYPES = {"table", "view", "stored_procedure", "file", "shortcut", "query"}
MODES = ("semantic", "notebooks", "copyjobs", "pipelines", "dataflows")


def normalize_key(value):
    if value is None:
        return ""
    return re.sub(r"\s+", " ", str(value).strip().lower())


def normalize_object_type(value):
    clean = re.sub(r"[\s-]+", "_", normalize_key(value))
    aliases = {
        "storedprocedure": "stored_procedure",
        "procedure": "stored_procedure",
        "proc": "stored_procedure",
        "sp": "stored_procedure",
        "tbl": "table",
    }
    return aliases.get(clean, clean)


def exact_object_type(value):
    return normalize_object_type(value) in EXACT_TYPES


def text(value):
    if value is None:
        return ""
    return str(value)


def object_key(source_type, server, database, schema, object_name):
    return "|".join(normalize_key(v) for v in (source_type, server, database, schema, object_name))


def resolution_key(source_type, server, database, schema, object_name):
    type_part = normalize_key(source_type) if source_type else "*"
    return "|".join(
        (
            type_part,
            normalize_key(server),
            normalize_key(database),
            normalize_key(schema),
            normalize_key(object_name),
        )
    )


def build_resolution_index(logical_name):
    index = {}
    for row in read_csv(logical_name):
        if normalize_key(row.get("status")) != "resolved":
            continue
        resolved_type = normalize_object_type(row.get("resolved_object_type"))
        if not exact_object_type(resolved_type):
            continue
        resolution = {
            "object_type": resolved_type,
            "object_type_source": text(row.get("resolver_source")),
            "object_type_confidence": text(row.get("resolver_confidence")),
            "evidence": text(row.get("resolver_evidence")),
        }
        keys = {
            resolution_key(
                row.get("source_type"), row.get("source_server"), row.get("source_database"),
                row.get("schema_name"), row.get("object_name"),
            ),
            resolution_key(
                "", row.get("source_server"), row.get("source_database"),
                row.get("schema_name"), row.get("object_name"),
            ),
        }
        for key in keys:
            if key and key not in index:
                index[key] = resolution
    return index


def get_resolution(index, source_type, server, database, schema, object_name):
    for key in (
        resolution_key(source_type, server, database, schema, object_name),
        resolution_key("", server, database, schema, object_name),
    ):
        if key in index:
            return index[key]
    return None


def unique_sorted(values):
    return sorted({text(v) for v in values if text(v)})


def seed_catalog_only_summary_rows(by_object, deep_catalog_logical_name, sql_endpoint_catalog_logical_name):
    seeded = []

    for row in read_csv(deep_catalog_logical_name):
        server = text(row.get("source_server"))
        database = text(row.get("database_name"))
        schema = text(row.get("schema_name"))
        object_name = text(row.get("object_name"))
        if not object_name:
            continue
        key = object_key("SQL", server, database, schema, object_name)
        if key in by_object:
            continue
        object_type = normalize_object_type(row.get("object_type"))
        display_tail = f"{schema}.{object_name}" if schema else object_name
        seeded.append({
            "object_key": key,
            "object_display_name": " / ".join(v for v in (database, display_tail) if v),
            "source_type": "SQL", "source_server": server, "source_database": database,
            "schema_name": schema, "object_name": object_name,
            "object_type_values": object_type, "object_type_sources": "sql_server_deep_catalog",
            "affected_item_count": 0, "semantic_model_count": 0, "notebook_count": 0,
            "copyjob_count": 0, "pipeline_count": 0, "dataflow_count": 0,
            "affected_item_types": "", "affected_items_sample": "",
        })
        by_object[key] = True

    for row in read_csv(sql_endpoint_catalog_logical_name):
        object_name = text(row.get("object_name"))
        if not object_name:
            continue
        server = text(row.get("source_server")) or text(row.get("sql_endpoint_name"))
        database = text(row.get("source_database"))
        schema = text(row.get("schema_name"))
        source_type = text(row.get("source_type")) or "Lakehouse"
        key = object_key(source_type, server, database, schema, object_name)
        if key in by_object:
            continue
        display_tail = f"{schema}.{object_name}" if schema else object_name
        seeded.append({
            "object_key": key,
            "object_display_name": text(row.get("object_display_name")) or " / ".join(v for v in (database, display_tail) if v),
            "source_type": source_type, "source_server": server, "source_database": database,
            "schema_name": schema, "object_name": object_name,
            "object_type_values": normalize_object_type(row.get("object_type")),
            "object_type_sources": "sql_endpoint_object_catalog",
            "affected_item_count": 0, "semantic_model_count": 0, "notebook_count": 0,
            "copyjob_count": 0, "pipeline_count": 0, "dataflow_count": 0,
            "affected_item_types": "", "affected_items_sample": "",
        })
        by_object[key] = True

    return seeded


def build_impact_rows_and_summary(explorer):
    modes = explorer.get("modes") or MODES
    resolution_index = build_resolution_index("object_type_resolution_queue_path")
    impact_rows = []

    for workspace in explorer.get("workspaces", []) or []:
        workspace_name = text(workspace.get("name"))
        for mode in modes:
            for item in workspace.get(mode, []) or []:
                if not item:
                    continue
                sources = item.get("sources", []) or []
                item_type = text(item.get("item_type"))
                item_name = text(item.get("label"))
                item_qualified_name = text(item.get("qualified_name"))

                for source in sources:
                    source_server = text(source.get("server"))
                    source_database = text(source.get("database"))
                    source_type = text(source.get("source_type"))
                    for obj in source.get("objects", []) or []:
                        if not obj:
                            continue
                        schema = text(obj.get("schema"))
                        object_name = text(obj.get("object_name"))
                        server = text(obj.get("server")) or source_server
                        database = text(obj.get("database")) or source_database
                        obj_source_type = text(obj.get("source_type")) or source_type
                        original_object_type = text(obj.get("type"))
                        raw_object_type = text(obj.get("raw_object_type"))
                        object_type = original_object_type
                        object_type_source = text(obj.get("object_type_source"))
                        object_type_confidence = text(obj.get("object_type_confidence"))
                        resolution = get_resolution(resolution_index, obj_source_type, server, database, schema, object_name)
                        if resolution:
                            object_type = resolution["object_type"]
                            if not raw_object_type:
                                raw_object_type = original_object_type
                            object_type_source = resolution["object_type_source"]
                            object_type_confidence = resolution["object_type_confidence"]

                        evidence = text(obj.get("evidence"))
                        if resolution and resolution.get("evidence"):
                            evidence = re.sub(
                                r"\s+", " ",
                                f"{evidence} Exact object type resolved from {resolution['object_type_source']}: {resolution['evidence']}",
                            ).strip()

                        display_tail = f"{schema}.{object_name}" if schema else object_name
                        display_parts = [v for v in (database, display_tail) if v]
                        impact_rows.append({
                            "object_key": object_key(obj_source_type, server, database, schema, object_name),
                            "object_display_name": " / ".join(display_parts[:2]),
                            "source_type": obj_source_type, "source_server": server, "source_database": database,
                            "schema_name": schema, "object_name": object_name,
                            "object_type": object_type, "raw_object_type": raw_object_type,
                            "object_type_source": object_type_source, "object_type_confidence": object_type_confidence,
                            "item_workspace_name": workspace_name, "item_type": item_type, "item_name": item_name,
                            "item_qualified_name": item_qualified_name, "mode": mode,
                            "source_label": text(source.get("label")), "source_qualified_name": text(source.get("qualified_name")),
                            "semantic_table": text(obj.get("semantic_table")), "usage_type": text(obj.get("usage_type")),
                            "confidence": text(obj.get("confidence")), "evidence": evidence,
                        })

    for pipeline_row in read_csv("pipeline_object_lineage_candidates_path"):
        object_name = text(pipeline_row.get("object_name"))
        item_qualified_name = text(pipeline_row.get("item_qualified_name"))
        if not object_name or not item_qualified_name:
            continue
        source_type = text(pipeline_row.get("source_type")) or "FabricOrSQL"
        server = text(pipeline_row.get("source_server"))
        database = text(pipeline_row.get("source_database"))
        schema = text(pipeline_row.get("schema_name"))
        original_object_type = text(pipeline_row.get("object_type")) or "table_or_view"
        object_type = original_object_type
        object_type_source = ""
        object_type_confidence = ""
        resolution = get_resolution(resolution_index, source_type, server, database, schema, object_name)
        if resolution:
            object_type = resolution["object_type"]
            object_type_source = resolution["object_type_source"]
            object_type_confidence = resolution["object_type_confidence"]
        evidence = text(pipeline_row.get("evidence"))
        if resolution and resolution.get("evidence"):
            evidence = re.sub(
                r"\s+", " ",
                f"{evidence} Exact object type resolved from {resolution['object_type_source']}: {resolution['evidence']}",
            ).strip()
        display_tail = f"{schema}.{object_name}" if schema else object_name
        display_parts = [v for v in (database, display_tail) if v]
        impact_rows.append({
            "object_key": object_key(source_type, server, database, schema, object_name),
            "object_display_name": " / ".join(display_parts[:2]),
            "source_type": source_type, "source_server": server, "source_database": database,
            "schema_name": schema, "object_name": object_name,
            "object_type": object_type, "raw_object_type": original_object_type,
            "object_type_source": object_type_source, "object_type_confidence": object_type_confidence,
            "item_workspace_name": text(pipeline_row.get("workspace_name")), "item_type": "DataPipeline",
            "item_name": text(pipeline_row.get("item_name")), "item_qualified_name": item_qualified_name,
            "mode": "pipelines", "source_label": text(pipeline_row.get("source_name")),
            "source_qualified_name": text(pipeline_row.get("source_qualified_name")),
            "semantic_table": "", "usage_type": text(pipeline_row.get("usage_type")),
            "confidence": text(pipeline_row.get("confidence")), "evidence": evidence,
        })

    seen_impact_rows = set()
    deduped_impact_rows = []
    for row in impact_rows:
        key = tuple((name, row.get(name, "")) for name in sorted(row.keys()))
        if key in seen_impact_rows:
            continue
        seen_impact_rows.add(key)
        deduped_impact_rows.append(row)
    impact_rows = deduped_impact_rows

    impact_summary = []
    by_object = defaultdict(list)
    for row in impact_rows:
        by_object[row["object_key"]].append(row)
    for rows in by_object.values():
        first = rows[0]
        affected_items = unique_sorted(row.get("item_qualified_name") for row in rows)
        item_types = unique_sorted(row.get("item_type") for row in rows)
        impact_summary.append({
            "object_key": first["object_key"], "object_display_name": first["object_display_name"],
            "source_type": first["source_type"], "source_server": first["source_server"],
            "source_database": first["source_database"], "schema_name": first["schema_name"],
            "object_name": first["object_name"],
            "object_type_values": "; ".join(unique_sorted(row.get("object_type") for row in rows)),
            "object_type_sources": "; ".join(unique_sorted(row.get("object_type_source") for row in rows)),
            "affected_item_count": len(affected_items),
            "semantic_model_count": len({row["item_qualified_name"] for row in rows if row.get("item_type") == "SemanticModel" and row.get("item_qualified_name")}),
            "notebook_count": len({row["item_qualified_name"] for row in rows if row.get("item_type") == "Notebook" and row.get("item_qualified_name")}),
            "copyjob_count": len({row["item_qualified_name"] for row in rows if row.get("item_type") == "CopyJob" and row.get("item_qualified_name")}),
            "pipeline_count": len({row["item_qualified_name"] for row in rows if row.get("item_type") == "DataPipeline" and row.get("item_qualified_name")}),
            "dataflow_count": len({row["item_qualified_name"] for row in rows if row.get("item_type") == "Dataflow" and row.get("item_qualified_name")}),
            "affected_item_types": "; ".join(item_types),
            "affected_items_sample": "; ".join(affected_items[:12]),
        })

    catalog_only_rows = seed_catalog_only_summary_rows(by_object, "sql_server_deep_catalog_path", "sql_endpoint_catalog_path")
    impact_summary.extend(catalog_only_rows)

    return impact_rows, impact_summary


# %% [markdown]
# ## Assemble the final JSON (faithful port of 21_build_reverse_impact_package_fast.py)

# %%
EXACT_TYPE_PATTERN = re.compile(r"(^|; )(table|view|stored_procedure|file|shortcut|query)(;|$)")
AMBIGUOUS_TYPE_PATTERN = re.compile(r"table_or_view|native_query_object")


def get_field(row, names):
    if row is None:
        return ""
    for name in names:
        if name in row:
            value = row[name]
            if value is not None:
                return str(value)
    return ""


def new_object_alias_key(source_database, schema_name, object_name):
    return "|".join([normalize_key(source_database), normalize_key(schema_name), normalize_key(object_name)])


def build_column_catalog_lookup(column_rows):
    by_full_key = {}
    schemas_by_name_key = {}
    for row in column_rows:
        full_key = (
            normalize_key(row.get("source_server", "")), normalize_key(row.get("source_database", "")),
            normalize_key(row.get("schema_name", "")), normalize_key(row.get("object_name", "")),
        )
        by_full_key.setdefault(full_key, []).append(row)
        name_key = (full_key[0], full_key[1], full_key[3])
        schemas_by_name_key.setdefault(name_key, set()).add(full_key[2])
    return by_full_key, schemas_by_name_key


def get_columns_for_impact_object(object_row, by_full_key, schemas_by_name_key):
    server = get_field(object_row, ["source_server"])
    database = get_field(object_row, ["source_database"])
    schema = get_field(object_row, ["schema_name"])
    object_name = get_field(object_row, ["object_name"])
    if not server or not database or not object_name:
        return []
    full_key = (normalize_key(server), normalize_key(database), normalize_key(schema), normalize_key(object_name))
    if full_key not in by_full_key and not schema:
        name_key = (full_key[0], full_key[1], full_key[3])
        schemas = schemas_by_name_key.get(name_key)
        if schemas and len(schemas) == 1:
            only_schema = next(iter(schemas))
            full_key = (full_key[0], full_key[1], only_schema, full_key[3])
    rows = by_full_key.get(full_key)
    if not rows:
        return []

    def sort_key(row):
        try:
            return int(row.get("column_id", 0) or 0)
        except ValueError:
            return 0

    return [
        {
            "column_name": row.get("column_name", ""), "data_type": row.get("data_type", ""),
            "max_length": row.get("max_length", ""), "precision": row.get("precision", ""),
            "scale": row.get("scale", ""), "is_nullable": row.get("is_nullable", ""),
        }
        for row in sorted(rows, key=sort_key)
    ]


def ci_lower(value):
    return (value or "").lower()


def unique_ci_preserve_order(values):
    seen = set()
    result = []
    for value in values:
        if not value:
            continue
        key = ci_lower(value)
        if key in seen:
            continue
        seen.add(key)
        result.append(value)
    return result


def add_unique(target_list, seen, key, value):
    if not key or key in seen:
        return
    seen.add(key)
    target_list.append(value)


def build_final_payload(explorer, impact_rows, impact_summary):
    catalog_rows = [
        r for r in read_csv("sql_endpoint_catalog_path")
        if r.get("object_key") and r.get("source_database") and r.get("schema_name") and r.get("object_name")
    ]
    object_column_catalog_rows = [r for r in read_csv("object_column_catalog_path") if r.get("object_name") and r.get("column_name")]
    column_catalog_by_full_key, column_catalog_schemas_by_name_key = build_column_catalog_lookup(object_column_catalog_rows)

    item_by_qn = {}
    for workspace in explorer.get("workspaces", []) or []:
        for item in workspace.get("all", []) or []:
            qn = get_field(item, ["qualified_name"])
            if qn:
                item_by_qn[qn] = item

    def activity_fields(qualified_name):
        matched = item_by_qn.get(qualified_name)
        if not matched:
            return {"execution": None, "default_identity": ""}
        return {"execution": matched.get("execution"), "default_identity": matched.get("default_identity", "")}

    reports_by_semantic_model = {}
    for workspace in explorer.get("workspaces", []) or []:
        for model in workspace.get("semantic", []) or []:
            model_name = get_field(model, ["qualified_name"])
            if not model_name:
                continue
            reports = []
            seen_reports = set()
            for report in model.get("reports", []) or []:
                report_name = get_field(report, ["qualified_name"])
                add_unique(reports, seen_reports, report_name, {
                    "label": get_field(report, ["label", "item_name"]), "item_type": get_field(report, ["item_type"]),
                    "workspace_name": get_field(report, ["workspace_name"]), "qualified_name": report_name,
                    "confidence": get_field(report, ["confidence"]), "evidence": get_field(report, ["evidence"]),
                    "impact_path": "source_object -> semantic_model -> report", **activity_fields(report_name),
                })
            reports_by_semantic_model[model_name] = reports

    summary_by_object_key = {row["object_key"]: row for row in impact_summary}

    catalog_by_object_key = {}
    catalog_by_alias = defaultdict(list)
    for row in catalog_rows:
        if row["object_key"] not in catalog_by_object_key:
            catalog_by_object_key[row["object_key"]] = row
        alias = new_object_alias_key(row.get("source_database"), row.get("schema_name"), row.get("object_name"))
        catalog_by_alias[alias].append(row)

    enriched_impact_rows = []
    for row in impact_rows:
        alias = new_object_alias_key(get_field(row, ["source_database"]), get_field(row, ["schema_name"]), get_field(row, ["object_name"]))
        catalog_matches = catalog_by_alias.get(alias, [])
        catalog_match = catalog_matches[0] if len(catalog_matches) == 1 else None
        if catalog_match:
            row = dict(row)
            row["object_key"] = get_field(catalog_match, ["object_key"])
            row["object_display_name"] = get_field(catalog_match, ["object_display_name"])
            row["source_type"] = get_field(catalog_match, ["source_type"])
            row["source_server"] = get_field(catalog_match, ["source_server"])
            row["source_database"] = get_field(catalog_match, ["source_database"])
            row["schema_name"] = get_field(catalog_match, ["schema_name"])
            row["object_name"] = get_field(catalog_match, ["object_name"])
            row["object_type"] = get_field(catalog_match, ["object_type"])
            row["raw_object_type"] = get_field(catalog_match, ["raw_object_type", "object_type"])
            row["object_type_source"] = get_field(catalog_match, ["object_type_source"])
            row["object_type_confidence"] = get_field(catalog_match, ["object_type_confidence"])
            row["evidence"] = (get_field(row, ["evidence"]) + " Catalog metadata: " + get_field(catalog_match, ["evidence"])).strip()
        enriched_impact_rows.append(row)
    impact_rows = enriched_impact_rows

    impact_groups_by_key = defaultdict(list)
    for row in impact_rows:
        impact_groups_by_key[row["object_key"]].append(row)

    all_object_keys = sorted(
        {k for k in impact_groups_by_key if k} | {k for k in catalog_by_object_key if k} | {k for k in summary_by_object_key if k},
        key=ci_lower,
    )

    objects = []
    for object_key_value in all_object_keys:
        group_rows = impact_groups_by_key.get(object_key_value, [])
        catalog = catalog_by_object_key.get(object_key_value)
        summary = summary_by_object_key.get(object_key_value)
        first = group_rows[0] if group_rows else (catalog or summary)
        if not first:
            continue

        direct_items = []
        seen_direct = set()
        downstream_reports = []
        seen_reports = set()

        for row in group_rows:
            item_qn = get_field(row, ["item_qualified_name"])
            add_unique(direct_items, seen_direct, item_qn, {
                "label": get_field(row, ["item_name"]), "item_type": get_field(row, ["item_type"]),
                "workspace_name": get_field(row, ["item_workspace_name"]), "qualified_name": item_qn,
                "mode": get_field(row, ["mode"]), "usage_type": get_field(row, ["usage_type"]),
                "confidence": get_field(row, ["confidence"]), "source_label": get_field(row, ["source_label"]),
                "semantic_table": get_field(row, ["semantic_table"]), "evidence": get_field(row, ["evidence"]),
                "impact_path": "source_object -> item", **activity_fields(item_qn),
            })
            if get_field(row, ["item_type"]) == "SemanticModel" and item_qn in reports_by_semantic_model:
                for report in reports_by_semantic_model[item_qn]:
                    add_unique(downstream_reports, seen_reports, report["qualified_name"], report)

        all_workspaces = sorted(
            unique_ci_preserve_order(
                [d["workspace_name"] for d in direct_items] + [r["workspace_name"] for r in downstream_reports]
                + ([get_field(catalog, ["workspace_name"])] if catalog else [])
            ),
            key=ci_lower,
        )
        all_item_types = sorted(
            unique_ci_preserve_order([d["item_type"] for d in direct_items] + [r["item_type"] for r in downstream_reports]),
            key=ci_lower,
        )

        if catalog:
            object_type_values = get_field(catalog, ["object_type"])
            object_type_sources = get_field(catalog, ["object_type_source"])
        elif summary:
            object_type_values = get_field(summary, ["object_type_values"])
            object_type_sources = get_field(summary, ["object_type_sources"])
        else:
            object_type_values = get_field(first, ["object_type"])
            object_type_sources = get_field(first, ["object_type_source"])

        affected_item_count = len({d["qualified_name"] for d in direct_items})
        downstream_report_count = len({r["qualified_name"] for r in downstream_reports})

        search_parts = [
            get_field(first, ["object_display_name"]), get_field(first, ["source_type"]),
            get_field(first, ["source_server"]), get_field(first, ["source_database"]),
            get_field(first, ["schema_name"]), get_field(first, ["object_name"]), object_type_values,
            get_field(catalog, ["sql_endpoint_name"]) if catalog else "",
            *all_workspaces, *[d["label"] for d in direct_items], *[r["label"] for r in downstream_reports],
        ]
        search_text = " ".join(p for p in search_parts if p).lower()

        direct_items_sorted = sorted(direct_items, key=lambda d: (ci_lower(d["item_type"]), ci_lower(d["workspace_name"]), ci_lower(d["label"])))
        downstream_reports_sorted = sorted(downstream_reports, key=lambda r: (ci_lower(r["workspace_name"]), ci_lower(r["label"])))

        objects.append({
            "object_key": object_key_value, "object_display_name": get_field(first, ["object_display_name"]),
            "source_type": get_field(first, ["source_type"]), "source_server": get_field(first, ["source_server"]),
            "source_database": get_field(first, ["source_database"]), "schema_name": get_field(first, ["schema_name"]),
            "object_name": get_field(first, ["object_name"]),
            "columns": get_columns_for_impact_object(first, column_catalog_by_full_key, column_catalog_schemas_by_name_key),
            "object_type_values": object_type_values, "object_type_sources": object_type_sources,
            "affected_item_count": affected_item_count, "downstream_report_count": downstream_report_count,
            "total_impact_count": affected_item_count + downstream_report_count,
            "semantic_model_count": len({d["qualified_name"] for d in direct_items if d["item_type"] == "SemanticModel"}),
            "notebook_count": len({d["qualified_name"] for d in direct_items if d["item_type"] == "Notebook"}),
            "copyjob_count": len({d["qualified_name"] for d in direct_items if d["item_type"] == "CopyJob"}),
            "pipeline_count": len({d["qualified_name"] for d in direct_items if d["item_type"] == "DataPipeline"}),
            "dataflow_count": len({d["qualified_name"] for d in direct_items if d["item_type"] == "Dataflow"}),
            "report_count": downstream_report_count, "workspace_count": len(all_workspaces), "workspaces": all_workspaces,
            "affected_item_types": all_item_types, "search_text": search_text,
            "catalog_status": get_field(catalog, ["catalog_status"]) if catalog else "",
            "catalog_only": bool(catalog or summary) and affected_item_count == 0 and downstream_report_count == 0,
            "catalog_workspace_name": get_field(catalog, ["workspace_name"]) if catalog else "",
            "sql_endpoint_name": get_field(catalog, ["sql_endpoint_name"]) if catalog else "",
            "sql_endpoint_qualified_name": get_field(catalog, ["sql_endpoint_qualified_name"]) if catalog else "",
            "endpoint_resolution_method": get_field(catalog, ["endpoint_resolution_method"]) if catalog else "",
            "catalog_evidence": get_field(catalog, ["evidence"]) if catalog else "",
            "direct_items": direct_items_sorted, "downstream_reports": downstream_reports_sorted,
        })

    objects.sort(key=lambda o: (-o["total_impact_count"], -o["affected_item_count"], ci_lower(o["object_display_name"])))

    impacted_direct_items = len({r["item_qualified_name"] for r in impact_rows})
    all_downstream_report_qns = {r["qualified_name"] for o in objects for r in o["downstream_reports"]}

    return {
        "generated_at": datetime.now().replace(microsecond=0).isoformat(),
        "summary": {
            "source_objects": len(objects), "direct_impact_rows": len(impact_rows),
            "impacted_direct_items": impacted_direct_items, "downstream_reports": len(all_downstream_report_qns),
            "max_total_impact": objects[0]["total_impact_count"] if objects else 0,
            "exact_object_type_objects": sum(1 for o in objects if EXACT_TYPE_PATTERN.search(o["object_type_values"] or "")),
            "unresolved_objects": sum(1 for o in objects if AMBIGUOUS_TYPE_PATTERN.search(o["object_type_values"] or "")),
            "catalog_objects": sum(1 for o in objects if o["catalog_status"]),
            "catalog_only_objects": sum(1 for o in objects if o["catalog_only"]),
        },
        "objects": objects,
    }


# %% [markdown]
# ## Ejecutar

# %%
explorer_payload = read_onelake_json(EXPLORER_ONELAKE_PATH)
built_impact_rows, built_impact_summary = build_impact_rows_and_summary(explorer_payload)
final_payload = build_final_payload(explorer_payload, built_impact_rows, built_impact_summary)
write_json_atomic(OUTPUT_ONELAKE_PATH, final_payload)

print("Object impact package built.")
print(f"Source objects: {final_payload['summary']['source_objects']}")
print(f"Direct impact rows: {final_payload['summary']['direct_impact_rows']}")
print(f"Output: {OUTPUT_ONELAKE_PATH}")
