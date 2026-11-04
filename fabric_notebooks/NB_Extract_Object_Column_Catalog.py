# NB_Extract_Object_Column_Catalog
#
# Source for a Fabric Python notebook -- part of the "deep scan"
# (see docs/105_fabric_native_discovery_setup.md for the general pattern).
# Each "# %%" block is a cell -- paste them in order.
#
# Faithful replica of scripts/63_extract_object_column_catalog.ps1: for each
# SQL/Fabric database that this project already references (via item/pipeline/
# semantic-model candidates or the confirmed catalog of SQL
# endpoints), it connects and reads sys.columns -- the deepest level of detail
# that the impact panel can show per object (name/type/nullable of
# each column of each table/view).
#
# Depends on these having run before in the pipeline: NB_Discover_Object_
# Lineage, NB_Discover_Pipeline_Object_Lineage, NB_Discover_Semantic_Model_
# Lineage, NB_Extract_SQL_Endpoint_Catalog -- it reads their 4 bronze
# tables to build the list of server;db targets, just as the
# local script reads its 4 equivalent CSVs.
#
# Writes dbo.bronze_object_column_catalog and dbo.bronze_object_column_
# catalog_status -- the same columns that scripts/63_extract_object_column_
# catalog.ps1 already writes to analysis/object_column_catalog.csv / _status.csv.
#
# Not included (on purpose, same as the local script): the fallback to
# sql_server_deep_catalog_columns.csv (script 48, external servers with
# SQL login instead of AAD) -- that script is not ported yet and depends
# on network connectivity that was already confirmed not to exist today (see
# docs/105).
#
# Self-contained on purpose (it does not use %run) -- same criterion as the rest
# of the "Extract"/"Discover" notebooks of this project.

# %% [markdown]
# ## Configuration
# Same values as in NB_Discover_Workspaces_Items -- copy here the ones you
# already filled in there.

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

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"

ONELAKE_WORKSPACE_NAME = "<your-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<your-onelake-lakehouse>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"

WAREHOUSE_SQL_ENDPOINT = "<your-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<WarehouseName>"

CATALOG_CONNECT_TIMEOUT_SECONDS = 12
CATALOG_COMMAND_TIMEOUT_SECONDS = 90
DB_TOKEN_REFRESH_SECONDS = 1200

# %% [markdown]
# ## Parameters
# Mark this cell as a parameters cell in Fabric. The pipeline
# overrides it with the same WorkspaceNameFilter that
# NB_Discover_Workspaces_Items receives. Empty = whole tenant.
#
# Note (same as the local script): the filter here is by server;db, not
# by item -- a target is included if ANY of the workspaces that
# reference it matches the filter.

# %%
WorkspaceNameFilter = ""

# %% [markdown]
# ## Authentication: own service account token (MSAL)

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
# ## Warehouse (pyodbc, same pattern as NB_Discover_Workspaces_Items) +
# generic connection to any SQL endpoint in the tenant

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


def normalize_server_host(value):
    if not value:
        return ""
    clean = str(value).strip().lower()
    if clean.startswith("tcp:"):
        clean = clean[4:]
    if "," in clean:
        clean = clean.split(",", 1)[0]
    elif clean.count(":") == 1:
        clean = clean.split(":", 1)[0]
    return clean.strip()

# %% [markdown]
# ## Discover targets (union of server;db from the 4 bronze tables that
# already reference a SQL/Fabric database)

# %%
COLUMN_QUERY_SQL = """
select
    s.name as schema_name,
    o.name as object_name,
    c.column_id,
    c.name as column_name,
    t.name as data_type,
    c.max_length,
    c.precision,
    c.scale,
    c.is_nullable,
    c.is_identity,
    c.is_computed
from sys.columns c
inner join sys.objects o on c.object_id = o.object_id
inner join sys.schemas s on o.schema_id = s.schema_id
inner join sys.types t on c.user_type_id = t.user_type_id
where isnull(o.is_ms_shipped, 0) = 0
  and o.type in ('U', 'ET', 'V')
order by s.name, o.name, c.column_id
"""

CATALOG_COLUMNS = [
    "source_server", "source_database", "schema_name", "object_name", "column_id",
    "column_name", "data_type", "max_length", "precision", "scale",
    "is_nullable", "is_identity", "is_computed", "captured_at",
]
STATUS_COLUMNS = ["source_server", "source_database", "status", "column_count", "error", "captured_at"]


def _add_target(target_map, source_server, source_database, workspace_name):
    server = normalize_server_host(source_server)
    database = (source_database or "").strip()
    if not server or not database:
        return
    key = f"{server}|{normalize_key(database)}"
    entry = target_map.setdefault(key, {"source_server": server, "source_database": database, "workspaces": set()})
    if workspace_name:
        entry["workspaces"].add(workspace_name)


def discover_targets(connection, filter_set):
    cursor = connection.cursor()
    target_map = {}

    # Fix: confirmed live (pilot run) that
    # bronze_item_object_lineage_candidates/bronze_pipeline_object_lineage_
    # candidates can carry source_type='Fabric' rows that are NOT a SQL
    # database at all -- e.g. a Reflex action referencing another Fabric
    # item (add_reflex_object_candidates in NB_Discover_Object_Lineage
    # deliberately stuffs the WORKSPACE NAME into source_server/source_
    # database for that case, since there's no SQL server involved).
    # Querying those as if they were SQL endpoints fails every time
    # ("Login timeout expired") and wastes a connection attempt per
    # target. Only 'SQL' (or blank, for older candidate rows written
    # before source_type existed) is a real SQL target here -- unlike
    # bronze_sql_endpoint_object_catalog's OWN 'source_type' column,
    # which uses "Fabric" to mean the opposite (a confirmed, queryable
    # Fabric SQL endpoint) -- same label, different table, different
    # meaning, so the exclusion below applies only to the two candidate
    # sources that share the item_object_lineage_candidates shape.
    sources = [
        ("bronze_item_object_lineage_candidates", "source_server", "source_database", "source_type"),
        ("bronze_pipeline_object_lineage_candidates", "source_server", "source_database", "source_type"),
        ("bronze_semantic_model_view_candidates", "source_server", "database_name", None),
        ("bronze_sql_endpoint_object_catalog", "source_server", "source_database", None),
    ]
    for table_name, server_col, database_col, source_type_col in sources:
        select_cols = f"workspace_name, {server_col}, {database_col}" + (f", {source_type_col}" if source_type_col else "")
        try:
            cursor.execute(f"SELECT {select_cols} FROM dbo.{table_name}")
        except pyodbc.Error:
            connection.rollback()
            print(f"[targets] dbo.{table_name} not found yet -- skipping this source.")
            continue
        count_before = len(target_map)
        skipped_non_sql = 0
        for record in cursor.fetchall():
            if source_type_col:
                workspace_name, source_server, source_database, source_type = record
                if source_type and normalize_key(source_type) != "sql":
                    skipped_non_sql += 1
                    continue
            else:
                workspace_name, source_server, source_database = record
            _add_target(target_map, source_server, source_database, workspace_name)
        contributed = len(target_map) - count_before
        skip_note = f" ({skipped_non_sql} non-SQL row(s) skipped)" if skipped_non_sql else ""
        print(f"[targets] dbo.{table_name}: {contributed} new target(s) contributed{skip_note}.")

    targets = sorted(target_map.values(), key=lambda t: (t["source_server"], t["source_database"]))
    if filter_set:
        targets = [
            t for t in targets
            if any(normalize_key(w) in filter_set for w in t["workspaces"])
        ]
    return targets


def new_target_key(source_server, source_database):
    return f"{normalize_server_host(source_server)}|{normalize_key(source_database)}"


def query_columns(server, database, token_provider, trust_server_certificate=False):
    connection = connect_sql_endpoint(server, database, token_provider, trust_server_certificate)
    try:
        connection.timeout = CATALOG_COMMAND_TIMEOUT_SECONDS
        cursor = connection.cursor()
        cursor.execute(COLUMN_QUERY_SQL)
        columns = [d[0] for d in cursor.description]
        return [dict(zip(columns, row)) for row in cursor.fetchall()]
    finally:
        connection.close()

# %% [markdown]
# ## Ejecutar

# %%
filter_set = {n.strip().lower() for n in re.split(r"[;,]", WorkspaceNameFilter or "") if n.strip()}

warehouse_connection = connect_warehouse()
try:
    targets = discover_targets(warehouse_connection, filter_set)
finally:
    warehouse_connection.close()
print(f"Metadata targets to probe: {len(targets)}")

catalog_rows = []
status_rows = []
token_provider = _DbTokenProvider()
captured_at = time.strftime("%Y-%m-%dT%H:%M:%S")

for target in targets:
    print(f"Column catalog query: {target['source_server']} / {target['source_database']} (referenced by {len(target['workspaces'])} workspace(s))")
    status = "catalog_query_succeeded"
    error_text = ""
    column_rows = []
    try:
        column_rows = query_columns(target["source_server"], target["source_database"], token_provider)
    except Exception as exc:  # noqa: BLE001 - a single unreachable/inaccessible database must not stop the whole catalog run
        status = "catalog_query_failed"
        error_text = f"{type(exc).__name__}: {exc}"

    status_rows.append({
        "source_server": target["source_server"],
        "source_database": target["source_database"],
        "status": status,
        "column_count": str(len(column_rows)),
        "error": error_text,
        "captured_at": captured_at,
    })

    if status != "catalog_query_succeeded":
        continue

    for column in column_rows:
        catalog_rows.append({
            "source_server": target["source_server"],
            "source_database": target["source_database"],
            "schema_name": column["schema_name"],
            "object_name": column["object_name"],
            "column_id": str(column["column_id"]),
            "column_name": column["column_name"],
            "data_type": column["data_type"],
            "max_length": str(column["max_length"]),
            "precision": str(column["precision"]),
            "scale": str(column["scale"]),
            "is_nullable": str(column["is_nullable"]),
            "is_identity": str(column["is_identity"]),
            "is_computed": str(column["is_computed"]),
            "captured_at": captured_at,
        })

print(f"Column rows found: {len(catalog_rows)}")

connection = connect_warehouse()
try:
    cursor = connection.cursor()
    if filter_set:
        queried_keys = {new_target_key(t["source_server"], t["source_database"]) for t in targets}
        try:
            cursor.execute(f"SELECT {', '.join(CATALOG_COLUMNS)} FROM dbo.bronze_object_column_catalog")
            retained_catalog_rows = [
                dict(zip(CATALOG_COLUMNS, row)) for row in cursor.fetchall()
                if new_target_key(row[0], row[1]) not in queried_keys
            ]
        except pyodbc.Error:
            connection.rollback()
            retained_catalog_rows = []
        try:
            cursor.execute(f"SELECT {', '.join(STATUS_COLUMNS)} FROM dbo.bronze_object_column_catalog_status")
            retained_status_rows = [
                dict(zip(STATUS_COLUMNS, row)) for row in cursor.fetchall()
                if new_target_key(row[0], row[1]) not in queried_keys
            ]
        except pyodbc.Error:
            connection.rollback()
            retained_status_rows = []
        if retained_catalog_rows:
            print(f"Retained {len(retained_catalog_rows)} existing column row(s) for targets outside WorkspaceNameFilter.")
        catalog_rows = catalog_rows + retained_catalog_rows
        status_rows = status_rows + retained_status_rows

    replace_table(connection, "bronze_object_column_catalog", CATALOG_COLUMNS, catalog_rows)
    replace_table(connection, "bronze_object_column_catalog_status", STATUS_COLUMNS, status_rows)
finally:
    connection.close()

print("Done.")
