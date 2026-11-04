# NB_Extract_SQL_Endpoint_Catalog
#
# Source for a Fabric Python notebook -- part of the "deep scan"
# (see docs/105_fabric_native_discovery_setup.md for the general pattern).
# Each "# %%" block is a cell -- paste them in order.
#
# Faithful replica of scripts/34_extract_sql_endpoint_object_catalog.ps1: it
# connects to the SQL analytics endpoint of each Lakehouse/Warehouse (AAD auth,
# Fabric-to-Fabric, no gateway) and queries sys.objects/sys.schemas to
# catalog their REAL tables/views/procedures -- this is what
# confirms whether a lineage candidate really is a table, a view or
# an SP, instead of staying with a name guessed by regex.
#
# Deliberate improvement over the original local script. The local version
# resolves server/database by parsing the STRING of
# to_qualified_name in dependencies.csv ("External Connection / SQL /
# <label>"), which only works if <label> already has the "server;db" form --
# in practice almost never, because connection_qualified_name() prefers
# the connection's DISPLAY NAME over its real path (see NB_Discover_
# Dependencies.py). Instead of repeating that fragility, this notebook reads
# directly from dbo.bronze_fabric_connections (NB_Discover_Fabric_Connections,
# the other new notebook of this deep scan) -- that catalog already resolves
# connectionDetails.path to the real server;db for each tenant connection,
# so it is only necessary to match by database name, without parsing
# any label. It must run AFTER NB_Discover_Fabric_Connections
# in the pipeline.
#
# Writes dbo.bronze_sql_endpoint_object_catalog and dbo.bronze_sql_endpoint_
# object_catalog_status -- the same columns that scripts/34_extract_sql_
# endpoint_object_catalog.ps1 already writes to analysis/sql_endpoint_object_
# catalog.csv / _status.csv.
#
# Self-contained on purpose (it does not use %run) -- same criterion as the rest
# of the "Discover"/"Extract" notebooks of this project.

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
import requests
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeoutError

FABRIC_API_BASE_URL = "https://api.fabric.microsoft.com/v1"

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"

ONELAKE_WORKSPACE_NAME = "<your-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<your-onelake-lakehouse>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"

WAREHOUSE_SQL_ENDPOINT = "<your-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<WarehouseName>"

CATALOG_CONNECT_TIMEOUT_SECONDS = 12
CATALOG_COMMAND_TIMEOUT_SECONDS = 90
DB_TOKEN_REFRESH_SECONDS = 1200  # proactive refresh every 20 min, same margin as Step 1b of NB_Discover_Workspaces_Items

# Applied as a precaution, in parallel to the real fix in
# NB_Extract_Object_Column_Catalog.py, which DID hang for hours in
# a tenant-scale run despite these same
# timeouts -- a sign that the ODBC driver does not fully honor them
# for certain network failures in Fabric's Linux/Spark runtime. This notebook
# did not fail that same night, but it shares the same per-target connection
# pattern, so it carries the same wall-clock watchdog.
CATALOG_TARGET_WALL_CLOCK_TIMEOUT_SECONDS = 45

# %% [markdown]
# ## Parameters
# Mark this cell as a parameters cell in Fabric. The pipeline
# overrides it with the same WorkspaceNameFilter that
# NB_Discover_Workspaces_Items receives. Empty = whole tenant.

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


def acquire_fabric_api_token():
    """A Notebook activity without an explicit SPN/Workspace Identity
    runs under the identity of the PIPELINE OWNER (official
    Microsoft documentation, "Run Notebooks in Pipelines with Service
    Principal or Workspace Identity"). If the owner of the pipeline
    PL_Discover_Workspaces_Items (its creatorPrincipal) has access to more
    workspaces than the SP, that is what makes it possible to resolve the real SQL
    hostname of a SQLEndpoint/Warehouse in a workspace where the SP is not a
    member. Fallback to the SP's MSAL login if notebookutils is not
    available (e.g. standalone execution outside a pipeline)."""
    try:
        return notebookutils.credentials.getToken("pbi")
    except Exception as exc:  # noqa: BLE001 - degrade to the SP's own MSAL login rather than fail the whole notebook
        print(f"[auth] notebookutils.credentials.getToken('pbi') failed ({exc}) -- falling back to the service principal's own MSAL login.")
        return acquire_token("https://api.fabric.microsoft.com/.default")

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
    """Same proactive refresh pattern as _HeaderProvider in
    NB_Discover_Workspaces_Items, but for the raw token that pyodbc
    needs (attrs_before), not an HTTP header.

    On purpose it does NOT use acquire_fabric_api_token()/notebookutils
    here -- tested live (outside Fabric, same attrs_before mechanism)
    that a token with audience api.fabric.microsoft.com fails SQL
    authentication (18456) even when it is a real user identity token
    with plenty of access to the workspace: SQL Server requires the
    token's `aud` field to be exactly database.windows.net, and
    notebookutils.credentials.getToken() does not offer that audience (only
    storage/pbi/keyvault/kusto). That is why the SQL query itself remains
    limited to the SP's own access (the workspaces where it is already
    Contributor) even though resolve_item_hostnames() further up already sees the
    real hostname of many more workspaces thanks to the identity inherited
    from the pipeline owner -- resolving the hostname and being able to query it are
    two different permissions."""

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
        # Same fix already validated in NB_Extract_Object_Column_Catalog
        # and NB_Discover_Executions -- row-by-row
        # executemany (even with fast_executemany=True) does not get the
        # bulk-copy speedup against Fabric Warehouse (distributed analytical
        # engine, not transactional): each parameter set pays
        # real round-trip/compilation overhead per statement. Confirmed live:
        # NB_Discover_Executions went from 98 min to 87s rewriting the same
        # table with only this change. batch_size is computed dynamically to
        # stay under the ~2100 parameter limit of SQL Server whatever the
        # number of columns of this particular table.
        batch_size = max(1, 2000 // max(len(columns), 1))
        placeholders_one_row = "(" + ", ".join("?" for _ in columns) + ")"
        column_list = ", ".join(f"[{c}]" for c in columns)
        for batch_start in range(0, len(rows), batch_size):
            batch = rows[batch_start:batch_start + batch_size]
            values_sql = ", ".join(placeholders_one_row for _ in batch)
            insert_sql = f"INSERT INTO dbo.{table_name} ({column_list}) VALUES {values_sql}"
            params = [truncate_value(row.get(c, "")) for row in batch for c in columns]
            # Without this, a long value (>~2000 characters) in
            # any column of the batch makes pyodbc fall back to the
            # legacy DAE/text binding, which the UTF-8 collation of Fabric Warehouse
            # (Latin1_General_100_BIN2_UTF8) rejects with SQL Server error
            # 4189 -- confirmed live (NB_Discover_Pipeline_Object_Lineage,
            # tenant-wide scan). Same bug already known from
            # NB_Download_Notebook_Definitions, applied here to ALL the
            # parameters of the batch because we do not know in advance which column
            # will have the long value.
            cursor.setinputsizes([(pyodbc.SQL_WVARCHAR, 0, 0)] * len(params))
            cursor.execute(insert_sql, params)
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
# ## Resolve the real hostname per item (detail API, inherited identity)
#
# The real SQL hostname of an item is NOT in the SQLEndpoint item
# itself (workspaces/{ws}/sqlEndpoints/{id} only gives id/name/description) --
# for a Lakehouse you have to read the detail of the sibling LAKEHOUSE
# (properties.sqlEndpointProperties.id/.connectionString, matched by
# id with the SQLEndpoint item) and for a Warehouse, its own detail
# (properties.connectionString). Both paths need real workspace
# access -- which is why they use acquire_fabric_api_token(), which inherits the
# identity of the pipeline owner instead of the SP's. If that user sees
# many more workspaces than the SP, this greatly widens how many hostnames get
# resolved -- although, as connect_sql_endpoint explains further down, resolving the
# hostname does not guarantee being able to QUERY it via SQL (different token
# audiences, see the query_catalog docstring).
#
# Optimization: which Lakehouses exist per workspace is already known by
# dbo.bronze_items (item_type='Lakehouse', written by NB_Discover_Workspaces_
# Items, which runs earlier in the pipeline) -- there is no need to ask the
# API for it again with GET workspaces/{id}/items?type=Lakehouse inside the loop
# (~1 extra call per workspace, in a large tenant). The only thing
# needed from that response was the `id` of each Lakehouse, and that is
# exactly technical_id in bronze_items (same item GUID that
# warehouse_ids/sql_endpoint_ids already use a little further down). The individual detail
# GET workspaces/{id}/lakehouses/{lakehouse_id} IS still needed
# -- it brings properties.sqlEndpointProperties, which is not in bronze_items.

# %%
def fabric_get_detail(path, headers):
    url = f"{FABRIC_API_BASE_URL}/{path.lstrip('/')}"
    try:
        response = requests.get(url, headers=headers, timeout=60)
    except requests.exceptions.RequestException:
        return None
    if response.status_code >= 400:
        return None
    return response.json()


def resolve_item_hostnames(fabric_headers, sql_endpoint_items, workspace_id_by_name, lakehouse_ids_by_workspace):
    hostname_by_item_id = {}
    items_by_workspace = {}
    for item in sql_endpoint_items:
        items_by_workspace.setdefault(item["workspace_name"], []).append(item)

    for workspace_name, items in items_by_workspace.items():
        workspace_id = workspace_id_by_name.get(workspace_name)
        if not workspace_id:
            continue

        warehouse_ids = {item["technical_id"] for item in items if item["item_type"] == "Warehouse"}
        for warehouse_id in warehouse_ids:
            detail = fabric_get_detail(f"workspaces/{workspace_id}/warehouses/{warehouse_id}", fabric_headers)
            connection_string = (detail or {}).get("properties", {}).get("connectionString", "")
            if connection_string:
                hostname_by_item_id[warehouse_id] = connection_string

        # Fabric SQL database (2025 preview) -- same flat properties.connectionString
        # shape as Warehouse, just a different detail endpoint. Confirmed via
        # Microsoft Learn's "Items - Get SQL Database" REST reference: unlike
        # Lakehouse, it's not nested under sqlEndpointProperties.
        sqldatabase_ids = {item["technical_id"] for item in items if item["item_type"] == "SQLDatabase"}
        for sqldatabase_id in sqldatabase_ids:
            detail = fabric_get_detail(f"workspaces/{workspace_id}/sqlDatabases/{sqldatabase_id}", fabric_headers)
            connection_string = (detail or {}).get("properties", {}).get("connectionString", "")
            if connection_string:
                hostname_by_item_id[sqldatabase_id] = connection_string

        sql_endpoint_ids = {item["technical_id"] for item in items if item["item_type"] == "SQLEndpoint"}
        if not sql_endpoint_ids:
            continue
        lakehouse_ids = lakehouse_ids_by_workspace.get(workspace_name, [])
        for lakehouse_id in lakehouse_ids:
            detail = fabric_get_detail(f"workspaces/{workspace_id}/lakehouses/{lakehouse_id}", fabric_headers)
            sql_endpoint_properties = (detail or {}).get("properties", {}).get("sqlEndpointProperties", {})
            paired_id = sql_endpoint_properties.get("id", "")
            connection_string = sql_endpoint_properties.get("connectionString", "")
            if paired_id in sql_endpoint_ids and connection_string:
                hostname_by_item_id[paired_id] = connection_string

    return hostname_by_item_id

# %% [markdown]
# ## Discover targets (server;db for each SQLEndpoint/Warehouse item)

# %%
CATALOG_QUERY_SQL = """
select
    s.name as schema_name,
    o.name as object_name,
    case
        when o.type in ('U', 'ET') then 'table'
        when o.type = 'V' then 'view'
        when o.type in ('P', 'PC', 'X', 'RF') then 'stored_procedure'
        else lower(o.type_desc)
    end as object_type,
    o.type as type_code,
    o.type_desc as type_desc,
    convert(varchar(33), o.create_date, 126) as create_date,
    convert(varchar(33), o.modify_date, 126) as modify_date
from sys.objects o
inner join sys.schemas s on o.schema_id = s.schema_id
where
    isnull(o.is_ms_shipped, 0) = 0
    and o.type in ('U', 'ET', 'V', 'P', 'PC', 'X', 'RF')
order by s.name, o.name
"""

# Three more read-only system-view queries against the same
# already-open SQL endpoint connection, for the admin panel's Data
# Sensitivity detail modal (DDM/RLS/CLS column, previously always shown as
# "not detected" -- no discovery existed for any of the three). All three views
# are documented as available against a Fabric Warehouse/SQL analytics
# endpoint with standard SQL Server T-SQL syntax: Dynamic Data Masking,
# Row-Level Security, and column-level GRANT/DENY permissions respectively.
# Each is wrapped in its
# own try/except at the call site (query_security_metadata) -- a caller
# without permission to read one of these views (or a target where the
# feature genuinely isn't used) must not abort the whole catalog query for
# that endpoint, same reasoning as the rest of this notebook.
MASKED_COLUMNS_QUERY_SQL = """
select
    s.name as schema_name,
    o.name as object_name,
    c.name as column_name,
    mc.masking_function
from sys.masked_columns mc
inner join sys.columns c on mc.object_id = c.object_id and mc.column_id = c.column_id
inner join sys.objects o on c.object_id = o.object_id
inner join sys.schemas s on o.schema_id = s.schema_id
where isnull(o.is_ms_shipped, 0) = 0
order by s.name, o.name, c.name
"""

ROW_LEVEL_SECURITY_QUERY_SQL = """
select
    s.name as schema_name,
    o.name as object_name,
    pol.name as policy_name,
    pred.predicate_type_desc
from sys.security_predicates pred
inner join sys.security_policies pol on pred.object_id = pol.object_id
inner join sys.objects o on pred.target_object_id = o.object_id
inner join sys.schemas s on o.schema_id = s.schema_id
where isnull(o.is_ms_shipped, 0) = 0 and pol.is_enabled = 1
order by s.name, o.name
"""

COLUMN_PERMISSIONS_QUERY_SQL = """
select
    s.name as schema_name,
    o.name as object_name,
    c.name as column_name,
    dp.name as grantee_name,
    cp.permission_name,
    cp.state_desc
from sys.column_permissions cp
inner join sys.columns c on cp.major_id = c.object_id and cp.minor_id = c.column_id
inner join sys.objects o on cp.major_id = o.object_id
inner join sys.schemas s on o.schema_id = s.schema_id
inner join sys.database_principals dp on cp.grantee_principal_id = dp.principal_id
where isnull(o.is_ms_shipped, 0) = 0
order by s.name, o.name, c.name
"""

COLUMN_SECURITY_COLUMNS = [
    "object_key", "schema_name", "object_name", "column_name", "workspace_name",
    "sql_endpoint_qualified_name", "security_type", "detail", "reviewed_at",
]

ROW_LEVEL_SECURITY_COLUMNS = [
    "object_key", "schema_name", "object_name", "workspace_name",
    "sql_endpoint_qualified_name", "policy_name", "predicate_type", "reviewed_at",
]

CATALOG_COLUMNS = [
    "object_key", "object_display_name", "source_type", "source_server", "source_database",
    "schema_name", "object_name", "object_type", "raw_object_type", "object_type_source",
    "object_type_confidence", "workspace_name", "workspace_environment", "sql_endpoint_name",
    "sql_endpoint_qualified_name", "sql_endpoint_id", "endpoint_resolution_method",
    "catalog_status", "evidence", "reviewed_at", "metadata_type_code", "metadata_type_desc",
    "create_date", "modify_date",
]
STATUS_COLUMNS = [
    "workspace_name", "workspace_environment", "sql_endpoint_name", "sql_endpoint_qualified_name",
    "sql_endpoint_id", "source_server", "source_database", "endpoint_resolution_method",
    "status", "object_count", "error", "reviewed_at",
]


def discover_targets(connection, filter_set, fabric_headers):
    cursor = connection.cursor()
    environment_by_workspace = {}
    workspace_id_by_name = {}
    cursor.execute("SELECT workspace_name, environment, technical_id FROM dbo.bronze_workspaces")
    for row in cursor.fetchall():
        environment_by_workspace[row[0]] = row[1]
        workspace_id_by_name[row[0]] = row[2]

    # item_type='Lakehouse' is also requested here (in addition to
    # SQLEndpoint/Warehouse/SQLDatabase) so that resolve_item_hostnames()
    # can match each SQLEndpoint with its sibling Lakehouse without having
    # to ask the API for that list (GET workspaces/{id}/items?type=
    # Lakehouse) inside the loop -- see the detailed comment in that
    # function.
    cursor.execute(
        "SELECT workspace_name, item_type, item_name, qualified_name, technical_id "
        "FROM dbo.bronze_items WHERE item_type IN ('SQLEndpoint', 'Warehouse', 'SQLDatabase', 'Lakehouse')"
    )
    sql_endpoint_items = []
    lakehouse_ids_by_workspace = {}
    for row_workspace_name, row_item_type, row_item_name, row_qualified_name, row_technical_id in cursor.fetchall():
        if row_item_type == "Lakehouse":
            lakehouse_ids_by_workspace.setdefault(row_workspace_name, []).append(row_technical_id)
            continue
        sql_endpoint_items.append({
            "workspace_name": row_workspace_name, "item_type": row_item_type, "item_name": row_item_name,
            "qualified_name": row_qualified_name, "technical_id": row_technical_id,
            "workspace_environment": environment_by_workspace.get(row_workspace_name, ""),
        })
    if filter_set:
        sql_endpoint_items = [
            item for item in sql_endpoint_items
            if normalize_key(item["workspace_name"]) in filter_set
        ]

    try:
        cursor.execute("SELECT source_server, source_database FROM dbo.bronze_fabric_connections WHERE source_server <> '' AND source_database <> ''")
        connection_rows = cursor.fetchall()
    except pyodbc.Error:
        connection.rollback()
        connection_rows = []
        print("[targets] dbo.bronze_fabric_connections not found yet -- run NB_Discover_Fabric_Connections first. Falling back to same-workspace seed hosts only.")

    server_by_database = {}
    for source_server, source_database in connection_rows:
        db_key = normalize_key(source_database)
        server_by_database.setdefault(db_key, set()).add(normalize_server_host(source_server))

    target_map = {}

    def add_target(item, source_server, resolution_method):
        if not source_server:
            return
        key = f"{normalize_server_host(source_server)}|{normalize_key(item['item_name'])}"
        if key in target_map:
            return
        target_map[key] = {
            "workspace_name": item["workspace_name"],
            "workspace_environment": item["workspace_environment"],
            "sql_endpoint_name": item["item_name"],
            "sql_endpoint_qualified_name": item["qualified_name"],
            "sql_endpoint_id": item["technical_id"],
            "source_server": normalize_server_host(source_server),
            "source_database": item["item_name"],
            "endpoint_resolution_method": resolution_method,
        }

    hostname_by_item_id = resolve_item_hostnames(fabric_headers, sql_endpoint_items, workspace_id_by_name, lakehouse_ids_by_workspace)
    print(f"[targets] Resolved a real hostname via item detail for {len(hostname_by_item_id)}/{len(sql_endpoint_items)} SQLEndpoint/Warehouse/SQLDatabase item(s).")
    for item in sql_endpoint_items:
        hostname = hostname_by_item_id.get(item["technical_id"])
        if hostname:
            add_target(item, hostname, "confirmed_via_item_detail")

    for item in sql_endpoint_items:
        db_key = normalize_key(item["item_name"])
        for server in server_by_database.get(db_key, ()):
            add_target(item, server, "confirmed_via_connections_catalog")

    seed_servers_by_workspace = {}
    for target in target_map.values():
        seed_servers_by_workspace.setdefault(normalize_key(target["workspace_name"]), set()).add(target["source_server"])

    for item in sql_endpoint_items:
        workspace_key = normalize_key(item["workspace_name"])
        for server in seed_servers_by_workspace.get(workspace_key, ()):
            add_target(item, server, "same_workspace_seed_host_probe")

    return sql_endpoint_items, sorted(
        target_map.values(),
        key=lambda t: (t["workspace_name"], t["sql_endpoint_name"], t["endpoint_resolution_method"], t["source_server"]),
    )


def new_object_key(source_server, source_database, schema_name, object_name):
    return "|".join(normalize_key(v) for v in ("Fabric", source_server, source_database, schema_name, object_name))


def _run_optional_query(cursor, connection, sql, query_label):
    # A caller without permission to read one of these system views (or an
    # older/different engine that genuinely lacks it) must not abort the
    # whole catalog query for this endpoint -- same reasoning as the rest
    # of this notebook. Returns [] (not an error) when the query itself
    # can't run; a real, empty result set also returns [].
    try:
        cursor.execute(sql)
        columns = [d[0] for d in cursor.description]
        return [dict(zip(columns, row)) for row in cursor.fetchall()]
    except pyodbc.Error as exc:
        connection.rollback()
        print(f"[security] {query_label} unavailable on this endpoint: {type(exc).__name__}: {exc}")
        return []


def query_catalog(server, database, token_provider, trust_server_certificate=False):
    connection = connect_sql_endpoint(server, database, token_provider, trust_server_certificate)
    try:
        # Fix: pyodbc's query-execution timeout lives on the
        # Connection object, not the Cursor -- `cursor.timeout = ...` raises
        # AttributeError (confirmed live: every single target failed with
        # this exact error before the fix, masking whatever the real
        # per-target reach actually was).
        connection.timeout = CATALOG_COMMAND_TIMEOUT_SECONDS
        cursor = connection.cursor()
        cursor.execute(CATALOG_QUERY_SQL)
        columns = [d[0] for d in cursor.description]
        objects = [dict(zip(columns, row)) for row in cursor.fetchall()]
        masked_columns = _run_optional_query(cursor, connection, MASKED_COLUMNS_QUERY_SQL, "sys.masked_columns (DDM)")
        row_level_security = _run_optional_query(cursor, connection, ROW_LEVEL_SECURITY_QUERY_SQL, "sys.security_predicates (RLS)")
        column_permissions = _run_optional_query(cursor, connection, COLUMN_PERMISSIONS_QUERY_SQL, "sys.column_permissions (CLS)")
        return objects, masked_columns, row_level_security, column_permissions
    finally:
        connection.close()

# %% [markdown]
# ## Ejecutar

# %%
filter_set = {n.strip().lower() for n in re.split(r"[;,]", WorkspaceNameFilter or "") if n.strip()}

fabric_api_token = acquire_fabric_api_token()
fabric_headers = {"Authorization": f"Bearer {fabric_api_token}", "Content-Type": "application/json"}

try:
    import base64 as _b64
    import json as _json
    _payload_b64 = fabric_api_token.split(".")[1]
    _padded = _payload_b64 + "=" * (-len(_payload_b64) % 4)
    _claims = _json.loads(_b64.urlsafe_b64decode(_padded))
    _debug_path = (
        f"abfss://{ONELAKE_WORKSPACE_NAME}@onelake.dfs.fabric.microsoft.com/"
        f"{ONELAKE_LAKEHOUSE_NAME}.Lakehouse/Files/_debug_sql_endpoint_catalog_identity.json"
    )
    notebookutils.fs.put(_debug_path, _json.dumps({
        "upn": _claims.get("upn") or _claims.get("unique_name") or "",
        "appid": _claims.get("appid", ""),
        "idtyp": _claims.get("idtyp", ""),
    }, default=str), True)
except Exception as _debug_exc:  # noqa: BLE001 - diagnostics must never break the real run
    print(f"[debug] could not write identity diagnostics: {_debug_exc}")

warehouse_connection = connect_warehouse()
try:
    sql_endpoint_items, targets = discover_targets(warehouse_connection, filter_set, fabric_headers)
finally:
    warehouse_connection.close()
print(f"SQLEndpoint/Warehouse items considered: {len(sql_endpoint_items)}")
print(f"Metadata targets to probe: {len(targets)}")

catalog_rows = []
status_rows = []
column_security_rows = []
row_level_security_rows = []
token_provider = _DbTokenProvider()

# See CATALOG_TARGET_WALL_CLOCK_TIMEOUT_SECONDS above -- single worker, only
# used to get a hard wall-clock deadline the driver's own timeout can't be
# trusted to enforce, not for concurrency.
watchdog_executor = ThreadPoolExecutor(max_workers=1)

for target in targets:
    print(f"Catalog query: {target['workspace_name']} / {target['sql_endpoint_name']} via {target['source_server']} [{target['endpoint_resolution_method']}]")
    status = "catalog_query_succeeded"
    error_text = ""
    metadata_rows = []
    masked_columns = []
    row_level_security = []
    column_permissions = []
    future = watchdog_executor.submit(query_catalog, target["source_server"], target["source_database"], token_provider)
    try:
        metadata_rows, masked_columns, row_level_security, column_permissions = future.result(timeout=CATALOG_TARGET_WALL_CLOCK_TIMEOUT_SECONDS)
    except FutureTimeoutError:
        status = "catalog_query_failed"
        error_text = (
            f"TimeoutError: exceeded the {CATALOG_TARGET_WALL_CLOCK_TIMEOUT_SECONDS}s "
            "wall-clock watchdog (driver-level timeout was not honored)."
        )
        # Recreate the pool so the loop resumes on a fresh worker instead of
        # queuing behind a thread that may never return -- see the same
        # comment in NB_Extract_Object_Column_Catalog.py.
        watchdog_executor.shutdown(wait=False, cancel_futures=True)
        watchdog_executor = ThreadPoolExecutor(max_workers=1)
    except Exception as exc:  # noqa: BLE001 - a single unreachable/inaccessible endpoint must not stop the whole catalog run
        status = "catalog_query_failed"
        error_text = f"{type(exc).__name__}: {exc}"

    status_rows.append({
        "workspace_name": target["workspace_name"],
        "workspace_environment": target["workspace_environment"],
        "sql_endpoint_name": target["sql_endpoint_name"],
        "sql_endpoint_qualified_name": target["sql_endpoint_qualified_name"],
        "sql_endpoint_id": target["sql_endpoint_id"],
        "source_server": target["source_server"],
        "source_database": target["source_database"],
        "endpoint_resolution_method": target["endpoint_resolution_method"],
        "status": status,
        "object_count": str(len(metadata_rows)),
        "error": error_text,
        "reviewed_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
    })

    if status != "catalog_query_succeeded":
        continue

    reviewed_at = time.strftime("%Y-%m-%dT%H:%M:%S")
    for masked in masked_columns:
        column_security_rows.append({
            "object_key": new_object_key(target["source_server"], target["source_database"], masked["schema_name"], masked["object_name"]),
            "schema_name": masked["schema_name"],
            "object_name": masked["object_name"],
            "column_name": masked["column_name"],
            "workspace_name": target["workspace_name"],
            "sql_endpoint_qualified_name": target["sql_endpoint_qualified_name"],
            "security_type": "ddm",
            "detail": masked["masking_function"],
            "reviewed_at": reviewed_at,
        })
    for permission in column_permissions:
        column_security_rows.append({
            "object_key": new_object_key(target["source_server"], target["source_database"], permission["schema_name"], permission["object_name"]),
            "schema_name": permission["schema_name"],
            "object_name": permission["object_name"],
            "column_name": permission["column_name"],
            "workspace_name": target["workspace_name"],
            "sql_endpoint_qualified_name": target["sql_endpoint_qualified_name"],
            "security_type": "cls",
            "detail": f"{permission['grantee_name']}: {permission['permission_name']} ({permission['state_desc']})",
            "reviewed_at": reviewed_at,
        })
    for policy in row_level_security:
        row_level_security_rows.append({
            "object_key": new_object_key(target["source_server"], target["source_database"], policy["schema_name"], policy["object_name"]),
            "schema_name": policy["schema_name"],
            "object_name": policy["object_name"],
            "workspace_name": target["workspace_name"],
            "sql_endpoint_qualified_name": target["sql_endpoint_qualified_name"],
            "policy_name": policy["policy_name"],
            "predicate_type": policy["predicate_type_desc"],
            "reviewed_at": reviewed_at,
        })

    for metadata in metadata_rows:
        catalog_rows.append({
            "object_key": new_object_key(target["source_server"], target["source_database"], metadata["schema_name"], metadata["object_name"]),
            "object_display_name": f"{target['source_database']} / {metadata['schema_name']}.{metadata['object_name']}",
            "source_type": "Fabric",
            "source_server": target["source_server"],
            "source_database": target["source_database"],
            "schema_name": metadata["schema_name"],
            "object_name": metadata["object_name"],
            "object_type": metadata["object_type"],
            "raw_object_type": metadata["object_type"],
            "object_type_source": "sql_endpoint_catalog",
            "object_type_confidence": "confirmed",
            "workspace_name": target["workspace_name"],
            "workspace_environment": target["workspace_environment"],
            "sql_endpoint_name": target["sql_endpoint_name"],
            "sql_endpoint_qualified_name": target["sql_endpoint_qualified_name"],
            "sql_endpoint_id": target["sql_endpoint_id"],
            "endpoint_resolution_method": target["endpoint_resolution_method"],
            "catalog_status": "confirmed",
            "evidence": f"Read-only sys.objects catalog query against Fabric SQL endpoint {target['source_server']}/{target['source_database']} found {metadata['schema_name']}.{metadata['object_name']} as {metadata['type_desc']}.",
            "reviewed_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "metadata_type_code": str(metadata["type_code"]).strip(),
            "metadata_type_desc": metadata["type_desc"],
            "create_date": metadata["create_date"],
            "modify_date": metadata["modify_date"],
        })

watchdog_executor.shutdown(wait=False, cancel_futures=True)
print(f"Catalog objects found: {len(catalog_rows)}")

connection = connect_warehouse()
try:
    cursor = connection.cursor()
    if filter_set:
        try:
            cursor.execute(f"SELECT {', '.join(CATALOG_COLUMNS)} FROM dbo.bronze_sql_endpoint_object_catalog")
            retained_catalog_rows = [
                dict(zip(CATALOG_COLUMNS, row)) for row in cursor.fetchall()
                if normalize_key(row[CATALOG_COLUMNS.index("workspace_name")]) not in filter_set
            ]
        except pyodbc.Error:
            connection.rollback()
            retained_catalog_rows = []
        try:
            cursor.execute(f"SELECT {', '.join(STATUS_COLUMNS)} FROM dbo.bronze_sql_endpoint_object_catalog_status")
            retained_status_rows = [
                dict(zip(STATUS_COLUMNS, row)) for row in cursor.fetchall()
                if normalize_key(row[STATUS_COLUMNS.index("workspace_name")]) not in filter_set
            ]
        except pyodbc.Error:
            connection.rollback()
            retained_status_rows = []
        if retained_catalog_rows:
            print(f"Retained {len(retained_catalog_rows)} existing catalog row(s) for workspaces outside WorkspaceNameFilter.")
        catalog_rows = catalog_rows + retained_catalog_rows
        status_rows = status_rows + retained_status_rows

        try:
            cursor.execute(f"SELECT {', '.join(COLUMN_SECURITY_COLUMNS)} FROM dbo.bronze_column_security")
            retained_column_security_rows = [
                dict(zip(COLUMN_SECURITY_COLUMNS, row)) for row in cursor.fetchall()
                if normalize_key(row[COLUMN_SECURITY_COLUMNS.index("workspace_name")]) not in filter_set
            ]
        except pyodbc.Error:
            connection.rollback()
            retained_column_security_rows = []
        try:
            cursor.execute(f"SELECT {', '.join(ROW_LEVEL_SECURITY_COLUMNS)} FROM dbo.bronze_row_level_security")
            retained_row_level_security_rows = [
                dict(zip(ROW_LEVEL_SECURITY_COLUMNS, row)) for row in cursor.fetchall()
                if normalize_key(row[ROW_LEVEL_SECURITY_COLUMNS.index("workspace_name")]) not in filter_set
            ]
        except pyodbc.Error:
            connection.rollback()
            retained_row_level_security_rows = []
        column_security_rows = column_security_rows + retained_column_security_rows
        row_level_security_rows = row_level_security_rows + retained_row_level_security_rows

    replace_table(connection, "bronze_sql_endpoint_object_catalog", CATALOG_COLUMNS, catalog_rows)
    replace_table(connection, "bronze_sql_endpoint_object_catalog_status", STATUS_COLUMNS, status_rows)
    replace_table(connection, "bronze_column_security", COLUMN_SECURITY_COLUMNS, column_security_rows)
    replace_table(connection, "bronze_row_level_security", ROW_LEVEL_SECURITY_COLUMNS, row_level_security_rows)
finally:
    connection.close()

print("Done.")
