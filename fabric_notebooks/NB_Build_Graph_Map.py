# NB_Build_Graph_Map
#
# Source for a Fabric Python notebook -- tenth step of the native discovery
# pipeline, after NB_Build_Object_Impact (see docs/
# 105_fabric_native_discovery_setup.md). Each "# %%" block is a cell
# -- paste them in order.
#
# Faithful port of backend/scripts/build_graph_map_index.py -- the ALGORITHM
# is exactly the same, without rewriting a single line of that logic;
# the only thing that changes is the I/O layer:
#   - index/workspaces.csv, index/items.csv, index/dependencies.csv are now
#     queries against the Warehouse (bronze_workspaces/bronze_items/
#     bronze_dependencies, which already exist).
#   - object-impact.json and lineage-explorer.json are read from OneLake
#     (the two previous pipeline steps already publish them) instead of
#     local disk.
#   - analysis/execution_duration_by_item.csv does not exist as its own
#     bronze table -- the same aggregation is rebuilt (one entry per
#     qualified_name, run_count/failed_count/last status) directly
#     over the raw rows of bronze_executions (record_type=
#     "job_instance"), without going through the intermediate CSV.
#   - config/admin_settings.json's certified_items (the web admin panel's
#     "Certifications") is not reachable from Fabric -- it is a
#     local/Render-deployment setting, not part of the discovery pipeline.
#     It degrades to an empty list (no certification badges); if full
#     parity is wanted there, the right place for the improvement would be
#     for the web app to merge its certified_items onto the JSON at
#     serving time, not here.
#   - lineage_web.sensitivity_classifier.classify_columns has no I/O of
#     its own (regex only) -- copied as-is, unchanged.
#   - graph-map-index.json and graph-map-index-objects.json are written to
#     OneLake (Files/generated/) instead of local disk.
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

import json
import math
import re
import struct
from collections import defaultdict
from datetime import datetime, timezone

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"
WAREHOUSE_SQL_ENDPOINT = "<your-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<WarehouseName>"

ONELAKE_WORKSPACE_NAME = "<your-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<your-onelake-lakehouse>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"

OBJECT_IMPACT_ONELAKE_PATH = "Files/generated/object-impact.json"
EXPLORER_ONELAKE_PATH = "Files/generated/lineage-explorer.json"
ITEM_OUTPUT_ONELAKE_PATH = "Files/generated/graph-map-index.json"
OBJECT_OUTPUT_ONELAKE_PATH = "Files/generated/graph-map-index-objects.json"

INPUT_TABLE_BY_ARG = {
    "workspaces_path": "bronze_workspaces",
    "items_path": "bronze_items",
    "dependencies_path": "bronze_dependencies",
    "executions_path": "bronze_executions",
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
    """Kept the name (every read_csv(...) call site ported below stays
    unchanged) -- reads a Warehouse bronze table, not a CSV file. A table
    that doesn't exist yet degrades to [], same as a missing CSV file did
    originally."""
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
    # max_bytes you pass it (confirmed live) -- it's a preview
    # API, not a full-read one. spark.read.text(..., wholetext=True) reads
    # the whole file as a single row with no such cap.
    content = spark.read.text(abfss_path, wholetext=True).collect()[0][0]
    return json.loads(content)


def write_json(onelake_relative_path, payload):
    abfss_path = (
        f"abfss://{ONELAKE_WORKSPACE_NAME}@onelake.dfs.fabric.microsoft.com/"
        f"{ONELAKE_LAKEHOUSE_NAME}.Lakehouse/{onelake_relative_path}"
    )
    notebookutils.fs.put(abfss_path, json.dumps(payload, ensure_ascii=False, separators=(",", ":")), True)


# %% [markdown]
# ## Sensitivity classifier (faithful port of lineage_web/sensitivity_classifier.py, no I/O of its own)

# %%
SENSITIVITY_CATEGORIES = {
    "email": {"es": "Email", "en": "Email", "patterns": [r"e-?mail"]},
    "phone": {
        "es": "Teléfono", "en": "Phone",
        "patterns": [r"telefono", r"\bphone\b", r"movil(?!idad)"],
    },
    "national_id": {
        "es": "Identificación nacional", "en": "National ID",
        "patterns": [r"\bdni\b", r"\bnif\b", r"\bnie\b", r"passport", r"pasaporte", r"\bssn\b"],
    },
    "person_name": {
        "es": "Nombre / apellidos", "en": "Person name",
        "patterns": [r"apellido", r"surname", r"last_?name", r"first_?name", r"full_?name"],
    },
    "address": {
        "es": "Dirección postal", "en": "Postal address",
        "patterns": [r"direccion", r"\baddress\b", r"domicilio"],
    },
    "birth_date": {"es": "Fecha de nacimiento", "en": "Birth date", "patterns": [r"nacimiento", r"\bbirth"]},
    "financial": {
        "es": "Datos financieros", "en": "Financial data",
        "patterns": [r"\biban\b", r"bank_?account", r"credit_?card", r"tarjeta", r"\bsalary\b", r"salario", r"sueldo", r"card_?number"],
    },
    "health": {
        "es": "Datos de salud", "en": "Health data",
        "patterns": [r"\bhealth\b", r"\bsalud\b", r"medical", r"diagnostico", r"discapacidad", r"disability"],
    },
    "gender": {"es": "Género", "en": "Gender", "patterns": [r"\bgender\b", r"\bsexo\b"]},
}
_COMPILED_SENSITIVITY = {
    key: re.compile("|".join(meta["patterns"]), re.IGNORECASE) for key, meta in SENSITIVITY_CATEGORIES.items()
}


def classify_column_name(column_name):
    if not column_name:
        return []
    return [key for key, pattern in _COMPILED_SENSITIVITY.items() if pattern.search(column_name)]


def classify_columns(column_names):
    categories = set()
    for name in column_names:
        categories.update(classify_column_name(name))
    return categories


# %% [markdown]
# ## Faithful port of backend/scripts/build_graph_map_index.py

# %%
ITEM_TYPE_LAYER = {
    "SemanticModel": "semantic", "Report": "reporting", "PaginatedReport": "reporting",
    "Dashboard": "reporting", "SQLEndpoint": "storage", "Lakehouse": "storage", "Warehouse": "storage",
    "VariableLibrary": "orchestration", "Environment": "orchestration", "DataPipeline": "orchestration",
    "CopyJob": "orchestration", "Dataflow": "orchestration", "Notebook": "orchestration",
    "Eventstream": "orchestration", "KQLQueryset": "orchestration", "KQLDashboard": "reporting",
    "Reflex": "orchestration", "GraphQLApi": "orchestration", "UserDataFunction": "orchestration",
    "DataAgent": "orchestration",
}

SOURCE_TYPE_LAYER = {
    "SQL": "external", "ExternalAPI": "external", "File": "external", "NotebookStaticData": "external",
    "Fabric": "storage", "FabricOrSQL": "storage", "Lakehouse": "storage", "LakehouseTable": "storage",
}

RELATIONSHIP_LABELS = {
    "reads_from": {"es": "Lee de", "en": "Reads from"},
    "writes_to": {"es": "Escribe en", "en": "Writes to"},
    "depends_on": {"es": "Depende de", "en": "Depends on"},
    "triggers": {"es": "Dispara", "en": "Triggers"},
    "executes": {"es": "Ejecuta", "en": "Executes"},
    "transforms": {"es": "Transforma", "en": "Transforms"},
    "loads_into": {"es": "Carga en", "en": "Loads into"},
    "feeds": {"es": "Alimenta a", "en": "Feeds"},
    "uses": {"es": "Usa", "en": "Uses"},
    "uses_connection": {"es": "Usa la conexión", "en": "Uses connection"},
    "publishes_to": {"es": "Publica en", "en": "Publishes to"},
    "refreshes": {"es": "Actualiza", "en": "Refreshes"},
    "serves_report": {"es": "Sirve al informe", "en": "Serves report"},
    "uses_model": {"es": "Usa el modelo", "en": "Uses model"},
    "implied_data_usage": {"es": "Usa datos de (inferido)", "en": "Uses data from (inferred)"},
    "unknown": {"es": "Relación desconocida", "en": "Unknown relation"},
    "external_feed": {"es": "Alimenta desde el exterior", "en": "Feeds from external source"},
}

FABRIC_INTERNAL_SOURCE_TYPES = {
    "Fabric", "FabricOrSQL", "Lakehouse", "LakehouseTable", "FabricDataPipelines",
    "FabricSqlEndpointMetadata", "CapacityMetricsCES", "UsageMetricsDataConnector",
}


def is_external_origin_source_type(source_type):
    return bool(source_type) and source_type not in FABRIC_INTERNAL_SOURCE_TYPES and source_type not in ITEM_TYPE_LAYER


ITEM_NODE_SIZE = 14.0
_STORAGE_SIZE_RANGE = (18.0, 40.0)
_WORKSPACE_SIZE_RANGE = (44.0, 90.0)
_OBJECT_SIZE_RANGE = (7.0, 12.0)


def _clamp(value, lo, hi):
    return max(lo, min(hi, value))


def workspace_node_size(item_count):
    lo, hi = _WORKSPACE_SIZE_RANGE
    return round(_clamp(lo + 3.5 * math.sqrt(max(item_count, 0)), lo, hi), 1)


def storage_node_size(table_count):
    lo, hi = _STORAGE_SIZE_RANGE
    return round(_clamp(lo + 3.2 * math.sqrt(max(table_count, 0)), lo, hi), 1)


def object_node_size(column_count):
    lo, hi = _OBJECT_SIZE_RANGE
    return round(_clamp(lo + 0.6 * math.sqrt(max(column_count, 0)), lo, hi), 1)


def relationship_label(relationship_type):
    key = (relationship_type or "").strip() or "unknown"
    return RELATIONSHIP_LABELS.get(key, RELATIONSHIP_LABELS["unknown"])


def lakehouse_tier(item_name):
    lower = (item_name or "").casefold()
    for tier in ("bronze", "silver", "gold"):
        if tier in lower:
            return tier
    return ""


def item_layer(item_type, item_name):
    if item_type in ("Lakehouse", "Warehouse"):
        tier = lakehouse_tier(item_name)
        if tier:
            return tier
    return ITEM_TYPE_LAYER.get(item_type, "orchestration")


def build_workspace_nodes(workspace_rows, item_counts_by_workspace):
    nodes = []
    known_ids = set()
    workspace_technical_id_by_name = {}
    for row in workspace_rows:
        name = row.get("workspace_name", "")
        if not name:
            continue
        workspace_id = "workspace::" + name
        technical_id = row.get("technical_id", "")
        item_count = item_counts_by_workspace.get(name, 0)
        nodes.append({
            "data": {
                "id": workspace_id, "label": name, "node_type": "Workspace", "layer": "workspace",
                "workspace_name": name, "environment": row.get("environment", ""),
                "capacity_name": row.get("capacity_name", ""), "technical_id": technical_id,
                "item_count": item_count, "size": workspace_node_size(item_count),
            }
        })
        known_ids.add(workspace_id)
        if technical_id:
            workspace_technical_id_by_name[name] = technical_id
    return nodes, known_ids, workspace_technical_id_by_name


STALE_AFTER_DAYS = 30


def _parse_execution_timestamp(value):
    if not value:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        return datetime.strptime(text, "%m/%d/%Y %H:%M:%S")
    except ValueError:
        pass
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).replace(tzinfo=None)
    except ValueError:
        return None


def build_execution_health_index(job_instance_rows):
    """Same aggregation contract as the original (one entry per item
    qualified_name, aggregated across every job_type), computed directly
    from raw bronze_executions job_instance rows instead of from a
    pre-aggregated execution_duration_by_item.csv -- no bronze table for
    that aggregation exists yet, and this produces the same numbers
    without needing one."""
    health = {}
    for row in job_instance_rows:
        if row.get("record_type") != "job_instance":
            continue
        qualified_name = row.get("qualified_name", "")
        if not qualified_name:
            continue
        entry = health.setdefault(
            qualified_name, {"run_count": 0, "failed_count": 0, "latest_start": None, "last_status": ""}
        )
        entry["run_count"] += 1
        if row.get("status") == "Failed":
            entry["failed_count"] += 1
        latest_start = _parse_execution_timestamp(row.get("start_time", ""))
        if latest_start and (entry["latest_start"] is None or latest_start > entry["latest_start"]):
            entry["latest_start"] = latest_start
            entry["last_status"] = row.get("status", "")
    return health


def health_fields_for(qualified_name, execution_health, now):
    entry = execution_health.get(qualified_name)
    if not entry or not entry["run_count"]:
        return {}
    latest_start = entry["latest_start"]
    days_since_last_run = (now.replace(tzinfo=None) - latest_start).days if latest_start else None
    return {
        "exec_run_count": entry["run_count"],
        "exec_failed_count": entry["failed_count"],
        "exec_last_status": entry["last_status"],
        "exec_latest_start_time": latest_start.strftime("%Y-%m-%d %H:%M") if latest_start else "",
        "exec_is_stale": bool(days_since_last_run is not None and days_since_last_run > STALE_AFTER_DAYS),
    }


def build_certification_index(certified_items):
    index = {}
    for entry in certified_items:
        qualified_name = entry.get("qualified_name", "")
        if qualified_name:
            index[qualified_name] = entry
    return index


def build_item_nodes(item_rows, workspace_technical_id_by_name, known_workspace_ids, storage_table_counts,
                      execution_health, now, certification_index):
    nodes = []
    known_ids = set()
    for row in item_rows:
        qualified_name = row.get("qualified_name", "")
        if not qualified_name:
            continue
        item_type = row.get("item_type", "")
        item_name = row.get("item_name", "")
        workspace_name = row.get("workspace_name", "")
        workspace_id = "workspace::" + workspace_name if workspace_name else ""
        table_count = storage_table_counts.get(qualified_name, 0)
        node_data = {
            "id": qualified_name, "label": item_name, "node_type": item_type,
            "layer": item_layer(item_type, item_name), "workspace_name": workspace_name,
            "description": row.get("description", ""), "default_identity": row.get("default_identity", ""),
            "technical_id": row.get("technical_id", ""),
            "workspace_technical_id": workspace_technical_id_by_name.get(workspace_name, ""),
            "table_count": table_count,
            "size": storage_node_size(table_count) if table_count else ITEM_NODE_SIZE,
        }
        node_data.update(health_fields_for(qualified_name, execution_health, now))
        certification = certification_index.get(qualified_name)
        if certification:
            node_data["is_certified"] = True
            node_data["certified_note"] = certification.get("note", "")
            node_data["certified_by"] = certification.get("certified_by", "")
        if workspace_id in known_workspace_ids:
            node_data["parent"] = workspace_id
        nodes.append({"data": node_data})
        known_ids.add(qualified_name)
    return nodes, known_ids


def build_item_edges(dependency_rows, known_ids):
    edges = []
    for index, row in enumerate(dependency_rows):
        source = row.get("from_qualified_name", "")
        target = row.get("to_qualified_name", "")
        if source not in known_ids or target not in known_ids:
            continue
        relationship_type = row.get("relationship_type", "")
        labels = relationship_label(relationship_type)
        edges.append({
            "data": {
                "id": "item-edge::%d" % index, "source": source, "target": target,
                "relationship_type": relationship_type, "label_es": labels["es"], "label_en": labels["en"],
                "confidence": row.get("confidence", ""),
            }
        })
    return edges


def build_object_graph(impact_payload, known_item_ids):
    if not impact_payload:
        return [], []
    nodes = []
    edges = []
    edge_index = 0
    for obj in impact_payload.get("objects", []):
        object_key = obj.get("object_key", "")
        if not object_key:
            continue
        node_id = "object::" + object_key
        source_type = obj.get("source_type", "")
        columns = obj.get("columns", []) or []
        column_count = len(columns)
        sensitivity_categories = sorted(classify_columns(c.get("column_name", "") for c in columns))
        nodes.append({
            "data": {
                "id": node_id, "label": obj.get("object_display_name", ""),
                "node_type": obj.get("object_type_values", "") or "source_object",
                "layer": SOURCE_TYPE_LAYER.get(source_type, "external"), "source_type": source_type,
                "source_server": obj.get("source_server", ""), "source_database": obj.get("source_database", ""),
                "column_count": column_count, "sensitivity_categories": sensitivity_categories,
                "size": object_node_size(column_count),
            }
        })

        for item in obj.get("direct_items", []):
            item_id = item.get("qualified_name", "")
            if item_id not in known_item_ids:
                continue
            relationship_type = item.get("usage_type", "") or "unknown"
            labels = relationship_label(relationship_type)
            edges.append({
                "data": {
                    "id": "object-edge::%d" % edge_index, "source": node_id, "target": item_id,
                    "relationship_type": relationship_type, "label_es": labels["es"], "label_en": labels["en"],
                    "confidence": item.get("confidence", ""),
                }
            })
            edge_index += 1

        for report in obj.get("downstream_reports", []):
            report_id = report.get("qualified_name", "")
            if report_id not in known_item_ids:
                continue
            labels = relationship_label("publishes_to")
            edges.append({
                "data": {
                    "id": "object-edge::%d" % edge_index, "source": node_id, "target": report_id,
                    "relationship_type": "publishes_to", "label_es": labels["es"], "label_en": labels["en"],
                    "confidence": report.get("confidence", ""),
                }
            })
            edge_index += 1

    return nodes, edges


def _slugify(value):
    keep = [c.casefold() if c.isalnum() else "-" for c in value]
    slug = "".join(keep).strip("-")
    while "--" in slug:
        slug = slug.replace("--", "-")
    return slug or "unknown"


def _origin_display_name(source_type, server, database):
    if server and database:
        return "%s (%s)" % (server, database)
    return server or database or source_type


def build_external_origin_graph(explorer_payload, known_item_ids):
    if not explorer_payload:
        return [], []

    labels = relationship_label("external_feed")
    origins = {}
    pairs = set()

    modes = explorer_payload.get("modes") or []
    for workspace in explorer_payload.get("workspaces", []) or []:
        for mode in modes:
            for item in workspace.get(mode) or []:
                if not isinstance(item, dict):
                    continue
                item_id = item.get("qualified_name", "")
                if not item_id or item_id not in known_item_ids:
                    continue
                for source in item.get("sources") or []:
                    source_type = source.get("source_type", "")
                    if not is_external_origin_source_type(source_type):
                        continue
                    server = source.get("server", "") or ""
                    database = source.get("database", "") or ""
                    slug = "origin::" + _slugify(source_type + "-" + server + "-" + database)
                    if slug not in origins:
                        origins[slug] = {"source_type": source_type, "source_server": server, "source_database": database}
                    pairs.add((slug, item_id))

    nodes = []
    for slug, origin in origins.items():
        nodes.append({
            "data": {
                "id": slug,
                "label": _origin_display_name(origin["source_type"], origin["source_server"], origin["source_database"]),
                "node_type": "ExternalOrigin", "layer": "external", "source_type": origin["source_type"],
                "source_server": origin["source_server"], "source_database": origin["source_database"], "size": 26.0,
            }
        })

    edges = []
    for index, (slug, item_id) in enumerate(sorted(pairs)):
        edges.append({
            "data": {
                "id": "origin-edge::%d" % index, "source": slug, "target": item_id,
                "relationship_type": "external_feed", "label_es": labels["es"], "label_en": labels["en"],
                "confidence": "",
            }
        })

    return nodes, edges


def compute_workspace_item_counts(item_rows):
    counts = {}
    for row in item_rows:
        name = row.get("workspace_name", "")
        if name:
            counts[name] = counts.get(name, 0) + 1
    return counts


def compute_storage_table_counts(impact_payload):
    counts = {}
    if not impact_payload:
        return counts
    for obj in impact_payload.get("objects", []):
        owner = obj.get("sql_endpoint_qualified_name", "")
        if owner:
            counts[owner] = counts.get(owner, 0) + 1
    return counts


def build_implied_storage_edges(impact_payload, known_item_ids, existing_pairs, start_index):
    if not impact_payload:
        return []
    labels = relationship_label("implied_data_usage")
    pairs_seen = set()
    edges = []
    edge_index = start_index
    for obj in impact_payload.get("objects", []):
        owner = obj.get("sql_endpoint_qualified_name", "")
        if not owner or owner not in known_item_ids:
            continue
        consumers = list(obj.get("direct_items", [])) + list(obj.get("downstream_reports", []))
        for entry in consumers:
            item_id = entry.get("qualified_name", "")
            if not item_id or item_id == owner or item_id not in known_item_ids:
                continue
            pair = (item_id, owner)
            if pair in pairs_seen or pair in existing_pairs:
                continue
            pairs_seen.add(pair)
            edges.append({
                "data": {
                    "id": "implied-edge::%d" % edge_index, "source": item_id, "target": owner,
                    "relationship_type": "implied_data_usage", "label_es": labels["es"], "label_en": labels["en"],
                    "confidence": "inferred", "is_implied": True,
                }
            })
            edge_index += 1
    return edges


def count_by(items, data_key, field):
    counts = {}
    for item in items:
        value = item[data_key][field]
        counts[value] = counts.get(value, 0) + 1
    return counts


def build_by_item_index(object_edges):
    index = {}
    for position, edge in enumerate(object_edges):
        item_id = edge["data"]["target"]
        index.setdefault(item_id, []).append(position)
    return index


# %% [markdown]
# ## Ejecutar

# %%
now = datetime.now(timezone.utc)
workspace_rows = read_csv("workspaces_path")
item_rows = read_csv("items_path")
dependency_rows = read_csv("dependencies_path")
impact_payload = read_onelake_json(OBJECT_IMPACT_ONELAKE_PATH)
explorer_payload = read_onelake_json(EXPLORER_ONELAKE_PATH)
execution_rows = read_csv("executions_path")

item_counts_by_workspace = compute_workspace_item_counts(item_rows)
storage_table_counts = compute_storage_table_counts(impact_payload)
execution_health = build_execution_health_index(execution_rows)
certification_index = build_certification_index([])  # see note above: not reachable from Fabric

workspace_nodes, known_workspace_ids, workspace_technical_id_by_name = build_workspace_nodes(
    workspace_rows, item_counts_by_workspace
)
item_nodes, known_item_ids = build_item_nodes(
    item_rows, workspace_technical_id_by_name, known_workspace_ids, storage_table_counts,
    execution_health, now, certification_index,
)
item_edges = build_item_edges(dependency_rows, known_item_ids)

existing_pairs = set()
for edge in item_edges:
    s, t = edge["data"]["source"], edge["data"]["target"]
    existing_pairs.add((s, t))
    existing_pairs.add((t, s))
implied_edges = build_implied_storage_edges(impact_payload, known_item_ids, existing_pairs, len(item_edges))
item_edges = item_edges + implied_edges

object_nodes, object_edges = build_object_graph(impact_payload, known_item_ids)
origin_nodes, origin_edges = build_external_origin_graph(explorer_payload, known_item_ids)
item_edges = item_edges + origin_edges

item_level_nodes = workspace_nodes + item_nodes + origin_nodes

connected_ids = set(known_workspace_ids)
for edge in item_edges:
    connected_ids.add(edge["data"]["source"])
    connected_ids.add(edge["data"]["target"])
for node in item_level_nodes:
    node["data"]["is_connected"] = node["data"]["id"] in connected_ids

generated_at = now.isoformat()

item_payload = {
    "generated_at": generated_at,
    "summary": {
        "node_count": len(item_level_nodes), "connected_node_count": len(connected_ids),
        "edge_count": len(item_edges), "node_type_counts": count_by(item_level_nodes, "data", "node_type"),
        "relationship_type_counts": count_by(item_edges, "data", "relationship_type"),
    },
    "nodes": item_level_nodes, "edges": item_edges,
}
write_json(ITEM_OUTPUT_ONELAKE_PATH, item_payload)

object_payload = {
    "generated_at": generated_at,
    "summary": {
        "node_count": len(object_nodes), "edge_count": len(object_edges),
        "node_type_counts": count_by(object_nodes, "data", "node_type"),
        "relationship_type_counts": count_by(object_edges, "data", "relationship_type"),
    },
    "nodes": object_nodes, "edges": object_edges,
    "by_item_id": build_by_item_index(object_edges),
}
write_json(OBJECT_OUTPUT_ONELAKE_PATH, object_payload)

print("Graph Map index built.")
print(f"Item-level: {len(item_level_nodes)} nodes, {len(item_edges)} edges -> {ITEM_OUTPUT_ONELAKE_PATH}")
print(f"Object-level: {len(object_nodes)} nodes, {len(object_edges)} edges -> {OBJECT_OUTPUT_ONELAKE_PATH}")
