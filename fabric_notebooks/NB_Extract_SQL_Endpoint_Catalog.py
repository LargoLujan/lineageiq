# NB_Extract_SQL_Endpoint_Catalog
#
# Fuente para un notebook Python de Fabric -- Fase A del "escaneo profundo"
# (ver docs/105_fabric_native_discovery_setup.md para el patron general).
# Cada bloque "# %%" es una celda -- pegalas en orden.
#
# Replica fiel de scripts/34_extract_sql_endpoint_object_catalog.ps1: se
# conecta al SQL analytics endpoint de cada Lakehouse/Warehouse (auth AAD,
# Fabric-a-Fabric, sin gateway) y consulta sys.objects/sys.schemas para
# catalogar sus tablas/vistas/procedimientos REALES -- esto es lo que
# confirma si un candidato de linaje es de verdad una tabla, una vista o
# un SP, en vez de quedarse en un nombre adivinado por regex.
#
# 2026-08-19: mejora deliberada sobre el script local original. La version
# local resuelve servidor/base de datos parseando el STRING de
# to_qualified_name en dependencies.csv ("External Connection / SQL /
# <label>"), que solo funciona si <label> ya tiene forma "servidor;bd" --
# en la practica casi nunca, porque connection_qualified_name() prefiere
# el DISPLAY NAME de la conexion sobre su path real (ver NB_Discover_
# Dependencies.py). En vez de repetir esa fragilidad, este notebook lee
# directo de dbo.bronze_fabric_connections (NB_Discover_Fabric_Connections,
# el otro notebook nuevo de esta Fase A) -- ese catalogo ya resuelve
# connectionDetails.path a servidor;bd real para cada conexion del tenant,
# asi que solo hace falta cruzar por nombre de base de datos, sin parsear
# ninguna etiqueta. Debe correr DESPUES de NB_Discover_Fabric_Connections
# en el pipeline.
#
# Escribe dbo.bronze_sql_endpoint_object_catalog y dbo.bronze_sql_endpoint_
# object_catalog_status -- mismas columnas que scripts/34_extract_sql_
# endpoint_object_catalog.ps1 ya escribe en analysis/sql_endpoint_object_
# catalog.csv / _status.csv.
#
# Self-contained a proposito (no usa %run) -- mismo criterio que el resto
# de notebooks "Discover"/"Extract" de este proyecto.

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
import requests
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeoutError

FABRIC_API_BASE_URL = "https://api.fabric.microsoft.com/v1"

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"

ONELAKE_WORKSPACE_NAME = "<tu-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<tu-lakehouse-onelake>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"

WAREHOUSE_SQL_ENDPOINT = "<tu-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<NombreDelWarehouse>"

CATALOG_CONNECT_TIMEOUT_SECONDS = 12
CATALOG_COMMAND_TIMEOUT_SECONDS = 90
DB_TOKEN_REFRESH_SECONDS = 1200  # refresco proactivo cada 20min, mismo margen que Fase 1b de NB_Discover_Workspaces_Items

# 2026-08-20: aplicado por precaucion, en paralelo al fix real de
# NB_Extract_Object_Column_Catalog.py, que SI se llego a colgar horas en
# una corrida a escala de tenant pese a estos mismos
# timeouts -- indicio de que el driver ODBC no los respeta del todo para
# ciertos fallos de red en el runtime Linux/Spark de Fabric. Este notebook
# no fallo esa misma noche, pero comparte el mismo patron de conexion por
# objetivo, asi que lleva el mismo watchdog de reloj real.
CATALOG_TARGET_WALL_CLOCK_TIMEOUT_SECONDS = 45

# %% [markdown]
# ## Parametros
# Marca esta celda como celda de parametros en Fabric. El pipeline la
# sobreescribe con el mismo WorkspaceNameFilter que recibe
# NB_Discover_Workspaces_Items. Vacio = tenant completo.

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


def acquire_fabric_api_token():
    """2026-08-19: una actividad Notebook sin SPN/Workspace Identity
    explicito corre bajo la identidad del DUENO DEL PIPELINE (documentacion
    oficial de Microsoft, "Run Notebooks in Pipelines with Service
    Principal or Workspace Identity"). Si el dueno del pipeline
    PL_Discover_Workspaces_Items (su creatorPrincipal) tiene acceso a mas
    workspaces que el SP, eso es lo que permite resolver el hostname SQL
    real de un SQLEndpoint/Warehouse en un workspace donde el SP no es
    miembro. Respaldo al login MSAL del SP si notebookutils no
    esta disponible (ej. ejecucion standalone fuera de un pipeline)."""
    try:
        return notebookutils.credentials.getToken("pbi")
    except Exception as exc:  # noqa: BLE001 - degrade to the SP's own MSAL login rather than fail the whole notebook
        print(f"[auth] notebookutils.credentials.getToken('pbi') failed ({exc}) -- falling back to the service principal's own MSAL login.")
        return acquire_token("https://api.fabric.microsoft.com/.default")

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
    """Mismo patron de refresco proactivo que _HeaderProvider en
    NB_Discover_Workspaces_Items, pero para el token crudo que pyodbc
    necesita (attrs_before), no una cabecera HTTP.

    2026-08-19: a proposito NO usa acquire_fabric_api_token()/notebookutils
    aqui -- probado en vivo (fuera de Fabric, mismo mecanismo attrs_before)
    que un token de audiencia api.fabric.microsoft.com falla la
    autenticacion SQL (18456) incluso siendo un token de identidad de
    usuario real con acceso de sobra al workspace: SQL Server exige que el
    campo `aud` del token sea exactamente database.windows.net, y
    notebookutils.credentials.getToken() no ofrece esa audiencia (solo
    storage/pbi/keyvault/kusto). Por eso la consulta SQL en si sigue
    limitada al acceso propio del SP (los workspaces donde ya es
    Contributor) aunque resolve_item_hostnames() de mas arriba ya vea el
    hostname real de muchos mas workspaces gracias a la identidad heredada
    del dueño del pipeline -- resolver el hostname y poder consultarlo son
    dos permisos distintos."""

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
        # 2026-08-21: mismo fix ya validado en NB_Extract_Object_Column_Catalog
        # (2026-08-20) y NB_Discover_Executions (2026-08-21) -- row-by-row
        # executemany (incluso con fast_executemany=True) no consigue el
        # aceleron de bulk-copy contra Fabric Warehouse (motor analitico
        # distribuido, no transaccional): cada set de parametros paga overhead
        # real de round-trip/compilacion por sentencia. Confirmado en vivo:
        # NB_Discover_Executions paso de 98 min a 87s reescribiendo la misma
        # tabla solo con este cambio. batch_size calculado dinamicamente para
        # quedar bajo el limite ~2100 parametros de SQL Server sea cual sea el
        # numero de columnas de esta tabla en concreto.
        batch_size = max(1, 2000 // max(len(columns), 1))
        placeholders_one_row = "(" + ", ".join("?" for _ in columns) + ")"
        column_list = ", ".join(f"[{c}]" for c in columns)
        for batch_start in range(0, len(rows), batch_size):
            batch = rows[batch_start:batch_start + batch_size]
            values_sql = ", ".join(placeholders_one_row for _ in batch)
            insert_sql = f"INSERT INTO dbo.{table_name} ({column_list}) VALUES {values_sql}"
            params = [truncate_value(row.get(c, "")) for row in batch for c in columns]
            # 2026-08-21: sin esto, un valor largo (>~2000 caracteres) en
            # cualquier columna del lote hace que pyodbc caiga al binding
            # legado DAE/text, que la colacion UTF-8 de Fabric Warehouse
            # (Latin1_General_100_BIN2_UTF8) rechaza con el error SQL Server
            # 4189 -- confirmado en vivo (NB_Discover_Pipeline_Object_Lineage,
            # 2026-08-21, escaneo tenant-wide). Mismo bug ya conocido de
            # NB_Download_Notebook_Definitions, aplicado aqui a TODOS los
            # parametros del lote porque no sabemos de antemano cual columna
            # tendra el valor largo.
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
# ## Resolver hostname real por item (API de detalle, identidad heredada)
#
# 2026-08-19: el hostname SQL real de un item NO esta en el item SQLEndpoint
# en si (workspaces/{ws}/sqlEndpoints/{id} solo da id/nombre/descripcion) --
# para un Lakehouse hay que leer el detalle del LAKEHOUSE hermano
# (properties.sqlEndpointProperties.id/.connectionString, emparejado por
# id con el item SQLEndpoint) y para un Warehouse, su propio detalle
# (properties.connectionString). Ambos caminos necesitan acceso real de
# workspace -- por eso usan acquire_fabric_api_token(), que hereda la
# identidad del dueño del pipeline en vez de la del SP. Si ese usuario ve
# muchos mas workspaces que el SP, esto amplia mucho cuantos hostnames se
# resuelven -- aunque, como explica connect_sql_endpoint mas abajo, resolver el
# hostname no garantiza poder CONSULTARLO via SQL (audiencias de token
# distintas, ver docstring de query_catalog).
#
# 2026-08-19 optimizacion: que Lakehouses existen por workspace ya lo sabe
# dbo.bronze_items (item_type='Lakehouse', lo escribe NB_Discover_Workspaces_
# Items, que corre antes en el pipeline) -- no hace falta pedirselo de nuevo
# a la API con GET workspaces/{id}/items?type=Lakehouse dentro del bucle
# (~1 llamada extra por workspace, en un tenant grande). Lo unico que se
# necesitaba de esa respuesta era el `id` de cada Lakehouse, y ese es
# exactamente technical_id en bronze_items (mismo GUID de item que ya usan
# warehouse_ids/sql_endpoint_ids un poco mas abajo). El detalle individual
# GET workspaces/{id}/lakehouses/{lakehouse_id} SI sigue siendo necesario
# -- ese trae properties.sqlEndpointProperties, que no esta en bronze_items.

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
# ## Descubrir objetivos (servidor;bd por cada item SQLEndpoint/Warehouse)

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

# 2026-08-24: three more read-only system-view queries against the same
# already-open SQL endpoint connection, for the admin panel's Data
# Sensitivity detail modal (DDM/RLS/CLS column, previously always "Sin
# detectar" -- no discovery existed for any of the three). All three views
# are documented as available against a Fabric Warehouse/SQL analytics
# endpoint with standard SQL Server T-SQL syntax (see docs/109_column_
# security_discovery.md): Dynamic Data Masking, Row-Level Security, and
# column-level GRANT/DENY permissions respectively. Each is wrapped in its
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

    # 2026-08-19: se pide tambien item_type='Lakehouse' aqui (ademas de
    # SQLEndpoint/Warehouse/SQLDatabase) para que resolve_item_hostnames()
    # pueda emparejar cada SQLEndpoint con su Lakehouse hermano sin tener
    # que pedirle esa lista a la API (GET workspaces/{id}/items?type=
    # Lakehouse) dentro del bucle -- ver comentario detallado en esa
    # funcion.
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
        # 2026-08-19 fix: pyodbc's query-execution timeout lives on the
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
