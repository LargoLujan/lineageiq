# NB_Discover_Fabric_Connections
#
# Source for a Fabric Python notebook -- first step of the "deep scan"
# (see docs/105_fabric_native_discovery_setup.md for the general pattern).
# Each "# %%" block is a cell -- paste them in order.
#
# Faithful replica of scripts/69_discover_fabric_connections.ps1: lists the
# tenant connections the caller can see (GET /v1/connections) and
# resolves the REAL TARGET of each one (connectionDetails.path -- for
# SQL connections, "server;database"). Items only carry the
# NAME of the connection (e.g. "LH_Sample_Silver_Cloud"), never the
# server -- without this catalog, lineage treats that label as if it
# were the database and the real source can never be confirmed. This
# is what allows NB_Extract_SQL_Endpoint_Catalog (the other
# new notebook) to find the real server of each SQLEndpoint/Warehouse
# without depending on the connection name already looking like "server;db".
#
# Tenant-wide, without WorkspaceNameFilter -- connections do not belong
# to a specific workspace, which is why this notebook (unlike the
# "Discover" ones) has no parameters cell, same as the "Build"
# notebooks.
#
# Writes dbo.bronze_fabric_connections of the configured Warehouse --
# the same 7 columns that scripts/69_discover_fabric_connections.ps1 already
# writes to index/fabric_connections.csv, so backend/scripts/lineage_web/
# warehouse.py (live read) does not need to know which of the two paths
# filled the table last time.
#
# Self-contained on purpose (it does not use %run on NB_Discover_Workspaces_
# Items) -- same criterion as the rest of the "Discover" notebooks of this
# project: small copies of the auth/connection helpers instead of a shared
# import.

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

FABRIC_API_BASE_URL = "https://api.fabric.microsoft.com/v1"

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"

ONELAKE_WORKSPACE_NAME = "<your-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<your-onelake-lakehouse>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"

WAREHOUSE_SQL_ENDPOINT = "<your-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<WarehouseName>"

REQUEST_DELAY_SECONDS = 0.35
RETRY_COUNT = 5

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
    runs under the identity of the PIPELINE OWNER (confirmed
    by official Microsoft documentation -- "Run Notebooks in Pipelines
    with Service Principal or Workspace Identity": "Pipeline Activity
    notebooks execute under the security context of the pipeline owner").
    If the owner of PL_Discover_Workspaces_Items (its creatorPrincipal,
    queryable via API) is a user with their own access to many more
    workspaces and connections than the SP -- the usual case when the SP only
    has a role in a few workspaces --, the notebook sees all that
    scope. notebookutils.credentials.getToken('pbi') inherits
    that user identity automatically, with no secret or extra
    configuration. If for whatever reason the notebook ran under the SP (activity with
    explicit SPN, or standalone execution outside a pipeline), this
    getToken still works but with the SP's more limited scope
    (Lakehouse/Notebook/Workspace.ReadWrite.All) -- which is why the SP's MSAL login
    is kept as a fallback if notebookutils is not available or
    fails."""
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
# ## Warehouse (pyodbc, same pattern as NB_Discover_Workspaces_Items)

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
    """Decodes (without verifying the signature -- only for diagnostics, never to
    authorize anything) the JWT payload to see which identity
    getToken('pbi') really returned. Fabric does not expose a notebook's print()
    via API (as NB_Discover_Workspaces_Items already saw with its
    TEMPORARY DIAGNOSTIC block), so the only way to confirm the theory of
    "it inherits the pipeline owner" is to write this to a file in
    OneLake and read it afterwards from outside."""
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
