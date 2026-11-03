# NB_Extract_Control_Framework_Lineage
#
# Fuente para un notebook Python de Fabric -- Fase C del "escaneo profundo"
# (ver docs/105_fabric_native_discovery_setup.md para el patron general).
# Cada bloque "# %%" es una celda -- pegalas en orden.
#
# Replica fiel de scripts/70_extract_control_framework_lineage.py: en
# muchos tenants buena parte de los notebooks/copyjobs son
# "metadata-driven" -- su codigo
# no nombra ninguna tabla destino (el parseo estatico de NB_Discover_
# Object_Lineage da "Destino pendiente"), porque que se carga donde se
# decide en tiempo de ejecucion desde un esquema "control" de cada
# lakehouse. Pero ese mismo framework REGISTRA cada ejecucion en
# control.TableStatus con la tabla origen completa, la tabla destino
# completa y el nombre del notebook ejecutor (ExecutedBy =
# "NB_Load_OrderList_2026/07/14-06:57:25") -- evidencia de linaje en
# tiempo de ejecucion, mas fuerte que cualquier parseo de codigo.
#
# Depende de que haya corrido antes NB_Extract_SQL_Endpoint_Catalog (Fase
# A) -- lee dbo.bronze_sql_endpoint_object_catalog para encontrar que
# bases de datos exponen un esquema "control" con tabla de estado, y
# dbo.bronze_items para resolver el nombre del notebook ejecutor al item
# real.
#
# Escribe dbo.bronze_control_framework_lineage_candidates (mismas 17
# columnas que dbo.bronze_item_object_lineage_candidates, a proposito --
# es una fuente ADICIONAL de candidatos, no un reemplazo; ver la nota del
# script original sobre "--control-framework-candidates-path") y dbo.
# bronze_control_framework_lineage_gaps.
#
# Self-contained a proposito (no usa %run) -- mismo criterio que el resto
# de notebooks "Extract"/"Discover" de este proyecto.

# %% [markdown]
# ## Configuracion
# Mismos valores que en NB_Discover_Workspaces_Items -- copia aqui los que
# ya rellenaste alli.

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

import re
import struct
import time
from collections import defaultdict

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"

ONELAKE_WORKSPACE_NAME = "<tu-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<tu-lakehouse-onelake>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"

WAREHOUSE_SQL_ENDPOINT = "<tu-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<NombreDelWarehouse>"

CATALOG_CONNECT_TIMEOUT_SECONDS = 15
DB_TOKEN_REFRESH_SECONDS = 1200

# %% [markdown]
# ## Parametros
# Marca esta celda como celda de parametros en Fabric. El pipeline la
# sobreescribe con el mismo WorkspaceNameFilter que recibe
# NB_Discover_Workspaces_Items. Vacio = tenant completo.
#
# Nota (igual que NB_Extract_Object_Column_Catalog): el filtro es por el
# workspace DUENO del endpoint de control, no por el notebook resuelto.

# %%
WorkspaceNameFilter = ""

# %% [markdown]
# ## Autenticacion: token propio de cuenta de servicio (MSAL)

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

# %% [markdown]
# ## Warehouse (pyodbc, mismo patron que NB_Discover_Workspaces_Items) +
# conexion generica a cualquier SQL endpoint del tenant

# %%
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
            f"pyodbc.drivers() (saw: {pyodbc.drivers()}) -- this Fabric "
            "Spark environment may need a custom Environment item with "
            "the driver installed via a startup script."
        )
    return available[0]


def connect_warehouse():
    db_token = acquire_token("https://database.windows.net/.default")
    conn_str = (
        f"DRIVER={{{pick_odbc_driver()}}};SERVER={WAREHOUSE_SQL_ENDPOINT};"
        f"DATABASE={WAREHOUSE_DATABASE_NAME};Encrypt=yes"
    )
    return pyodbc.connect(conn_str, attrs_before={1256: token_struct(db_token)}, timeout=30)


class _DbTokenProvider:
    def __init__(self):
        self.token = None
        self.acquired_at = 0.0

    def get(self, force_refresh=False):
        now = time.time()
        if force_refresh or self.token is None or (now - self.acquired_at) > DB_TOKEN_REFRESH_SECONDS:
            self.token = acquire_token("https://database.windows.net/.default")
            self.acquired_at = now
        return self.token


def connect_sql_endpoint(server, database, token_provider, trust_server_certificate=False):
    conn_str = (
        f"DRIVER={{{pick_odbc_driver()}}};SERVER=tcp:{server},1433;"
        f"DATABASE={database};Encrypt=yes;"
        f"TrustServerCertificate={'yes' if trust_server_certificate else 'no'}"
    )
    return pyodbc.connect(
        conn_str,
        attrs_before={1256: token_struct(token_provider.get())},
        timeout=CATALOG_CONNECT_TIMEOUT_SECONDS,
    )


def truncate_value(value, max_len=7990):
    text = "" if value is None else str(value)
    if len(text) > max_len:
        return text[:7950] + " ...[truncated]"
    return text


def replace_table(connection, table_name, columns, rows):
    cursor = connection.cursor()
    column_defs = ", ".join(f"[{c}] VARCHAR(8000)" for c in columns)
    cursor.execute(f"IF OBJECT_ID('dbo.{table_name}', 'U') IS NOT NULL DROP TABLE dbo.{table_name};")
    cursor.execute(f"CREATE TABLE dbo.{table_name} ({column_defs});")
    connection.commit()
    if rows:
        placeholders = ", ".join("?" for _ in columns)
        insert_sql = f"INSERT INTO dbo.{table_name} ({', '.join(f'[{c}]' for c in columns)}) VALUES ({placeholders})"
        cursor.fast_executemany = True
        cursor.executemany(insert_sql, [[truncate_value(row.get(c, "")) for c in columns] for row in rows])
        connection.commit()
    print(f"[warehouse] dbo.{table_name}: {len(rows)} row(s) written.")


def normalize_key(value):
    if not value:
        return ""
    return re.sub(r"\s+", " ", str(value).strip().lower())

# %% [markdown]
# ## Parseo del framework de control (igual que el script local)

# %%
STATUS_TABLE_NAMES = {"tablestatus", "status"}
EXECUTED_BY_SUFFIX = re.compile(r"[_ ]\d{4}/\d{2}/\d{2}[- ]\d{2}:\d{2}(:\d{2})?$")
GUID_PATTERN = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")

CANDIDATE_COLUMNS = [
    "workspace_name", "workspace_environment", "item_type", "item_name", "item_qualified_name",
    "source_type", "source_name", "source_qualified_name", "source_server", "source_database",
    "schema_name", "object_name", "object_type", "usage_type", "confidence", "definition_path", "evidence",
]
GAP_COLUMNS = ["source_server", "source_database", "control_table", "reason"]


def parse_full_table(value):
    parts = [p.strip() for p in str(value or "").split(".") if p.strip()]
    if len(parts) >= 3:
        return parts[0], parts[1], ".".join(parts[2:])
    if len(parts) == 2:
        return "", parts[0], parts[1]
    if len(parts) == 1:
        return "", "", parts[0]
    return "", "", ""


def notebook_name_from_executed_by(value):
    clean = str(value or "").strip()
    if not clean:
        return ""
    return EXECUTED_BY_SUFFIX.sub("", clean).strip("_ ").strip()


def discover_control_targets(connection, filter_set):
    cursor = connection.cursor()
    try:
        cursor.execute(
            "SELECT source_server, source_database, workspace_name, schema_name, object_name "
            "FROM dbo.bronze_sql_endpoint_object_catalog"
        )
    except pyodbc.Error:
        connection.rollback()
        print("[targets] dbo.bronze_sql_endpoint_object_catalog not found yet -- run NB_Extract_SQL_Endpoint_Catalog first.")
        return {}

    targets = {}
    for source_server, source_database, workspace_name, schema_name, object_name in cursor.fetchall():
        if normalize_key(schema_name) != "control":
            continue
        if normalize_key(object_name) not in STATUS_TABLE_NAMES:
            continue
        if filter_set and normalize_key(workspace_name) not in filter_set:
            continue
        key = (source_server, source_database, workspace_name)
        targets.setdefault(key, set()).add(object_name)
    return targets


def load_notebook_index(connection):
    cursor = connection.cursor()
    cursor.execute(
        "SELECT workspace_name, workspace_environment, item_type, item_name, qualified_name, technical_id "
        "FROM dbo.bronze_items WHERE status = 'discovered'"
    )
    notebooks_by_name = defaultdict(list)
    items_by_technical_id = {}
    for workspace_name, workspace_environment, item_type, item_name, qualified_name, technical_id in cursor.fetchall():
        row = {
            "workspace_name": workspace_name, "workspace_environment": workspace_environment,
            "item_type": item_type, "item_name": item_name, "qualified_name": qualified_name,
        }
        if item_type == "Notebook":
            notebooks_by_name[normalize_key(item_name)].append(row)
        tech_id = normalize_key(technical_id)
        if tech_id:
            items_by_technical_id[tech_id] = row

    # ExecutedBy in a newer control-framework generation can be something
    # other than the notebook's own item GUID
    # at all -- it's the Job Scheduler RUN instance id (per Microsoft Learn,
    # "NotebookUtils runtime context": notebookutils.runtime.context
    # ['currentRunId'], documented specifically for this "capture execution
    # metadata for... lineage tracking" use case). Cross-checked against
    # dbo.bronze_executions.job_instance_id (already discovered by
    # NB_Discover_Executions): only part of the gap GUIDs match -- the rest
    # are simply runs bronze_executions hasn't captured yet for that
    # workspace, not a resolution failure.
    try:
        # 2026-08-19 fix: bronze_executions (see EXECUTION_COLUMNS in
        # NB_Discover_Executions.py) has no workspace_environment column at
        # all -- the first version of this query selected it anyway, the
        # resulting pyodbc.Error was swallowed by the except below exactly
        # like a genuinely-missing-table would be, and this whole
        # resolution path silently no-opped (no gap resolved even when real
        # matches existed). workspace_environment
        # is looked up from items_by_technical_id's own workspace instead,
        # a few lines below, when it's actually needed.
        cursor.execute("SELECT job_instance_id, workspace_name, item_type, item_name, qualified_name FROM dbo.bronze_executions WHERE job_instance_id <> ''")
        items_by_job_instance_id = {}
        for job_instance_id, workspace_name, item_type, item_name, qualified_name in cursor.fetchall():
            key = normalize_key(job_instance_id)
            if key:
                items_by_job_instance_id[key] = {
                    "workspace_name": workspace_name, "workspace_environment": "",
                    "item_type": item_type, "item_name": item_name, "qualified_name": qualified_name,
                }
    except pyodbc.Error:
        connection.rollback()
        print("[targets] dbo.bronze_executions not found yet -- ExecutedBy run-id resolution will be skipped.")
        items_by_job_instance_id = {}

    return notebooks_by_name, items_by_technical_id, items_by_job_instance_id

# %% [markdown]
# ## Ejecutar

# %%
filter_set = {n.strip().lower() for n in re.split(r"[;,]", WorkspaceNameFilter or "") if n.strip()}

warehouse_connection = connect_warehouse()
try:
    targets = discover_control_targets(warehouse_connection, filter_set)
    notebooks_by_name, items_by_technical_id, items_by_job_instance_id = load_notebook_index(warehouse_connection)
    print(f"Job instance ids available for ExecutedBy run-id resolution: {len(items_by_job_instance_id)}")
finally:
    warehouse_connection.close()
print(f"Control status tables found in the SQL endpoint catalog: {len(targets)} database(s)")

out_rows = []
gap_rows = []
token_provider = _DbTokenProvider()

for (server, database, owner_workspace), tables in sorted(targets.items()):
    for table in sorted(tables):
        try:
            connection = connect_sql_endpoint(server, database, token_provider)
            cursor = connection.cursor()
            cursor.execute(f"SELECT * FROM control.[{table}]")
            columns = {d[0].lower(): i for i, d in enumerate(cursor.description)}
            # A tenant can have (at least) two control-framework
            # generations (e.g. a control.Status table on a bronze
            # lakehouse). The one script 70
            # was written against uses TargetTable/SourceTable; this one
            # uses a single Entity column (short name, no source table
            # logged at all) and ExecutedBy is a bare GUID with no
            # timestamp suffix (notebook_name_from_executed_by already
            # tolerates that -- the suffix regex just doesn't match,
            # leaving the GUID as-is for GUID_PATTERN to resolve below).
            target_column = "targettable" if "targettable" in columns else ("entity" if "entity" in columns else None)
            if target_column is None or "executedby" not in columns:
                gap_rows.append({"source_server": server, "source_database": database, "control_table": table, "reason": f"columns not usable: {sorted(columns)}"})
                connection.close()
                continue
            latest = {}
            for row in cursor.fetchall():
                notebook = notebook_name_from_executed_by(row[columns["executedby"]])
                target = str(row[columns[target_column]] or "").strip()
                source = str(row[columns["sourcetable"]] or "").strip() if "sourcetable" in columns else ""
                status = str(row[columns["status"]] or "").strip() if "status" in columns else ""
                executed = str(row[columns["executedatutc"]] or "").strip() if "executedatutc" in columns else ""
                if not notebook or not target:
                    continue
                key = (notebook, source, target)
                if key not in latest or executed > latest[key][0]:
                    latest[key] = (executed, status)
            connection.close()
        except Exception as exc:  # noqa: BLE001 - per-endpoint isolation, one bad control schema must not stop the rest
            gap_rows.append({"source_server": server, "source_database": database, "control_table": table, "reason": f"{type(exc).__name__}: {exc}"[:300]})
            continue

        for (notebook, source, target), (executed, status) in latest.items():
            guid_match = GUID_PATTERN.search(notebook)
            if guid_match and items_by_technical_id.get(normalize_key(guid_match.group(0))):
                candidates = [items_by_technical_id[normalize_key(guid_match.group(0))]]
            elif guid_match and items_by_job_instance_id.get(normalize_key(guid_match.group(0))):
                # ExecutedBy was a Job Scheduler run id, not the item's own
                # technical id -- resolved via bronze_executions instead.
                candidates = [items_by_job_instance_id[normalize_key(guid_match.group(0))]]
            else:
                candidates = notebooks_by_name.get(normalize_key(notebook), [])
            same_workspace = [c for c in candidates if c["workspace_name"] == owner_workspace]
            chosen = same_workspace[0] if same_workspace else (candidates[0] if len(candidates) == 1 else None)
            if chosen is None:
                gap_rows.append({
                    "source_server": server, "source_database": database, "control_table": table,
                    "reason": f"notebook '{notebook}' {'ambiguous across workspaces' if candidates else 'not found in items'}",
                })
                continue
            evidence_base = f"control.{table} runtime log on {database} (ExecutedBy={notebook}, last run {executed or 'unknown'}, status {status or 'unknown'})."
            for raw, usage in ((source, "reads_from"), (target, "writes_to")):
                if not raw:
                    continue
                obj_db, obj_schema, obj_name = parse_full_table(raw)
                if not obj_name:
                    continue
                out_rows.append({
                    "workspace_name": chosen["workspace_name"],
                    "workspace_environment": chosen["workspace_environment"],
                    "item_type": chosen["item_type"] or "Notebook",
                    "item_name": chosen["item_name"],
                    "item_qualified_name": chosen["qualified_name"],
                    "source_type": "LakehouseTable",
                    "source_name": obj_db or database,
                    "source_qualified_name": "",
                    "source_server": owner_workspace,
                    "source_database": obj_db or database,
                    "schema_name": obj_schema,
                    "object_name": obj_name,
                    "object_type": "table",
                    "usage_type": usage,
                    "confidence": "confirmed",
                    "definition_path": f"control.{table}@{database}",
                    "evidence": evidence_base,
                })

print(f"Lineage rows: {len(out_rows)}")
print(f"Gaps: {len(gap_rows)}")

connection = connect_warehouse()
try:
    if filter_set:
        cursor = connection.cursor()
        try:
            cursor.execute(f"SELECT {', '.join(CANDIDATE_COLUMNS)} FROM dbo.bronze_control_framework_lineage_candidates")
            retained_rows = [dict(zip(CANDIDATE_COLUMNS, row)) for row in cursor.fetchall() if normalize_key(row[0]) not in filter_set]
        except pyodbc.Error:
            connection.rollback()
            retained_rows = []
        if retained_rows:
            print(f"Retained {len(retained_rows)} existing row(s) for workspaces outside WorkspaceNameFilter.")
        out_rows = out_rows + retained_rows
    replace_table(connection, "bronze_control_framework_lineage_candidates", CANDIDATE_COLUMNS, out_rows)
    replace_table(connection, "bronze_control_framework_lineage_gaps", GAP_COLUMNS, gap_rows)
finally:
    connection.close()

print("Done.")
