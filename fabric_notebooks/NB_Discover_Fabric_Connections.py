# NB_Discover_Fabric_Connections
#
# Fuente para un notebook Python de Fabric -- Fase A del "escaneo profundo"
# (ver docs/105_fabric_native_discovery_setup.md para el patron general).
# Cada bloque "# %%" es una celda -- pegalas en orden.
#
# Replica fiel de scripts/69_discover_fabric_connections.ps1: lista las
# conexiones del tenant que el llamador puede ver (GET /v1/connections) y
# resuelve el DESTINO REAL de cada una (connectionDetails.path -- para
# conexiones SQL, "servidor;base de datos"). Los items solo llevan el
# NOMBRE de la conexion (ej. "LH_Sample_Silver_Cloud"), nunca el
# servidor -- sin este catalogo, el linaje trata esa etiqueta como si
# fuera la base de datos y nunca se puede confirmar el origen real. Esto
# es lo que permite a NB_Extract_SQL_Endpoint_Catalog (Fase A, el otro
# notebook nuevo) encontrar el servidor real de cada SQLEndpoint/Warehouse
# sin depender de que el nombre de la conexion ya parezca "servidor;bd".
#
# Tenant-completo, sin WorkspaceNameFilter -- las conexiones no pertenecen
# a un workspace concreto, por eso este notebook (a diferencia de los
# "Discover") no tiene celda de parametros, igual que los notebooks
# "Build".
#
# Escribe dbo.bronze_fabric_connections del Warehouse configurado --
# mismas 7 columnas que scripts/69_discover_fabric_connections.ps1 ya
# escribe en index/fabric_connections.csv, asi backend/scripts/lineage_web/
# warehouse.py (lectura en vivo) no necesita saber cual de los dos caminos
# rellenó la tabla la última vez.
#
# Self-contained a proposito (no usa %run sobre NB_Discover_Workspaces_
# Items) -- mismo criterio que el resto de notebooks "Discover" de este
# proyecto: copias pequeñas de los helpers de auth/conexion en vez de un
# import compartido.

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

FABRIC_API_BASE_URL = "https://api.fabric.microsoft.com/v1"

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"

ONELAKE_WORKSPACE_NAME = "<tu-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<tu-lakehouse-onelake>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"

WAREHOUSE_SQL_ENDPOINT = "<tu-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<NombreDelWarehouse>"

REQUEST_DELAY_SECONDS = 0.35
RETRY_COUNT = 5

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
    explicito corre bajo la identidad del DUENO DEL PIPELINE (confirmado
    por documentacion oficial de Microsoft -- "Run Notebooks in Pipelines
    with Service Principal or Workspace Identity": "Pipeline Activity
    notebooks execute under the security context of the pipeline owner").
    Si el dueno de PL_Discover_Workspaces_Items (su creatorPrincipal,
    consultable via API) es un usuario con acceso propio a muchos mas
    workspaces y conexiones que el SP -- lo habitual cuando el SP solo
    tiene rol en unos pocos workspaces --, el notebook ve todo ese
    alcance. notebookutils.credentials.getToken('pbi') hereda
    esa identidad de usuario automaticamente, sin secreto ni configuracion
    extra. Si por lo que sea el notebook corriera bajo el SP (activity con
    SPN explicito, o ejecucion standalone fuera de un pipeline), este
    getToken sigue funcionando pero con el alcance mas limitado del SP
    (Lakehouse/Notebook/Workspace.ReadWrite.All) -- por eso el login MSAL
    del SP se conserva como respaldo si notebookutils no esta disponible o
    falla."""
    try:
        return notebookutils.credentials.getToken("pbi")
    except Exception as exc:  # noqa: BLE001 - degrade to the SP's own MSAL login rather than fail the whole notebook
        print(f"[auth] notebookutils.credentials.getToken('pbi') failed ({exc}) -- falling back to the service principal's own MSAL login.")
        return acquire_token("https://api.fabric.microsoft.com/.default")

# %% [markdown]
# ## Helpers Fabric REST (paginacion + reintento en 429)

# %%
def fabric_get(path, headers, retry_count=RETRY_COUNT):
    url = path if path.startswith("http") else f"{FABRIC_API_BASE_URL}/{path.lstrip('/')}"
    for attempt in range(retry_count + 1):
        try:
            response = requests.get(url, headers=headers, timeout=120)
        except requests.exceptions.RequestException as exc:
            if attempt < retry_count:
                time.sleep(min(90, 2 ** (attempt + 1)))
                continue
            return {"ok": False, "status_code": None, "error": f"{type(exc).__name__}: {exc}", "payload": None}
        if response.status_code == 429 and attempt < retry_count:
            delay = min(90, 2 ** (attempt + 1))
            time.sleep(delay)
            continue
        if response.status_code >= 400:
            return {"ok": False, "status_code": response.status_code, "error": response.text[:500], "payload": None}
        if REQUEST_DELAY_SECONDS:
            time.sleep(REQUEST_DELAY_SECONDS)
        return {"ok": True, "status_code": response.status_code, "error": "", "payload": response.json()}
    return {"ok": False, "status_code": None, "error": "retries exhausted", "payload": None}


def fabric_get_paged(path, headers, value_key="value"):
    values = []
    next_path = path
    while next_path:
        result = fabric_get(next_path, headers)
        if not result["ok"]:
            return {"ok": False, "error": result["error"], "values": values}
        payload = result["payload"] or {}
        values.extend(payload.get(value_key, []) or [])
        continuation = payload.get("continuationToken", "")
        if not continuation:
            next_path = ""
        else:
            separator = "&" if "?" in path else "?"
            next_path = f"{path}{separator}continuationToken={continuation}"
    return {"ok": True, "error": "", "values": values}


def field(obj, *names):
    if obj is None:
        return ""
    for name in names:
        value = obj.get(name)
        if value is not None:
            return value
    return ""

# %% [markdown]
# ## Warehouse (pyodbc, mismo patron que NB_Discover_Workspaces_Items)

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

# %% [markdown]
# ## Descubrir conexiones

# %%
CONNECTION_COLUMNS = [
    "connection_id", "display_name", "connectivity_type", "detail_type",
    "detail_path", "source_server", "source_database",
]


def discover_connections(headers):
    result = fabric_get_paged("connections", headers)
    if not result["ok"]:
        raise RuntimeError(f"Could not list Fabric connections: {result['error']}")

    rows = []
    for connection in result["values"]:
        details = connection.get("connectionDetails") or {}
        detail_path = str(details.get("path", "") or "")
        detail_type = str(details.get("type", "") or "")
        source_server = ""
        source_database = ""
        if ";" in detail_path:
            server, database = detail_path.split(";", 1)
            source_server = server.strip()
            source_database = database.strip()
        rows.append({
            "connection_id": field(connection, "id"),
            "display_name": field(connection, "displayName"),
            "connectivity_type": field(connection, "connectivityType"),
            "detail_type": detail_type,
            "detail_path": detail_path,
            "source_server": source_server,
            "source_database": source_database,
        })
    return rows

# %% [markdown]
# ## Ejecutar

# %%
def decode_token_claims(token):
    """Decodifica (sin verificar firma -- solo para diagnostico, nunca para
    autorizar nada) el payload JWT para ver que identidad devolvio
    getToken('pbi') de verdad. Fabric no expone el print() de un notebook
    via API (igual que ya vio NB_Discover_Workspaces_Items con su bloque
    DIAGNOSTICO TEMPORAL), asi que la unica forma de confirmar la teoria de
    "hereda al dueno del pipeline" es escribir esto a un fichero en
    OneLake y leerlo despues desde fuera."""
    import base64 as _b64
    import json as _json
    payload_b64 = token.split(".")[1]
    padded = payload_b64 + "=" * (-len(payload_b64) % 4)
    return _json.loads(_b64.urlsafe_b64decode(padded))


def write_debug_json(relative_path, data):
    try:
        import json as _json
        debug_path = (
            f"abfss://{ONELAKE_WORKSPACE_NAME}@onelake.dfs.fabric.microsoft.com/"
            f"{ONELAKE_LAKEHOUSE_NAME}.Lakehouse/Files/{relative_path}"
        )
        notebookutils.fs.put(debug_path, _json.dumps(data, default=str), True)
    except Exception as exc:  # noqa: BLE001 - diagnostics must never break the real run
        print(f"[debug] could not write {relative_path}: {exc}")

# %%
fabric_token = acquire_fabric_api_token()
fabric_headers = {"Authorization": f"Bearer {fabric_token}", "Content-Type": "application/json"}

try:
    claims = decode_token_claims(fabric_token)
except Exception:
    claims = {}
own_workspaces = fabric_get_paged("workspaces", fabric_headers)
write_debug_json("_debug_fabric_connections_identity.json", {
    "upn": claims.get("upn") or claims.get("unique_name") or "",
    "appid": claims.get("appid", ""),
    "idtyp": claims.get("idtyp", ""),
    "aud": claims.get("aud", ""),
    "self_scoped_workspace_count": len(own_workspaces.get("values", [])) if own_workspaces.get("ok") else f"ERROR: {own_workspaces.get('error')}",
})

connection_rows = discover_connections(fabric_headers)
print(f"Connections discovered: {len(connection_rows)}")
resolved_count = sum(1 for r in connection_rows if r["source_server"])
print(f"Connections with a resolved server;database path: {resolved_count}/{len(connection_rows)}")

connection = connect_warehouse()
try:
    replace_table(connection, "bronze_fabric_connections", CONNECTION_COLUMNS, connection_rows)
finally:
    connection.close()

print("Done.")
