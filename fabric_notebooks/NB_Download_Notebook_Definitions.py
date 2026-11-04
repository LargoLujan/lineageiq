# NB_Download_Notebook_Definitions
#
# Source for a Fabric Python notebook -- eleventh step of the native
# discovery pipeline (see docs/105_fabric_native_discovery_setup.md).
# Each "# %%" block is a cell -- paste them in order.
#
# Faithful port of backend/scripts/51_download_notebook_definitions.ps1 --
# same algorithm (getDefinition API + standard Fabric LRO pattern,
# base64 decoding of each part), with two I/O changes:
#   - It no longer discovers notebooks by reading index/items.csv/workspaces.csv --
#     it reads them from dbo.bronze_items/dbo.bronze_workspaces (already populated by
#     NB_Discover_Workspaces_Items).
#   - It no longer writes each downloaded part as a file on disk under
#     data/notebook_definitions/<workspace>/<item>.Notebook/<part> -- it
#     writes them as rows of dbo.bronze_notebook_definitions (one row per
#     (item, part), with the text already decoded). The next notebook
#     of the pipeline (NB_Build_Notebook_Super_Lineage) consumes them from there
#     through an in-memory "virtual path", instead of walking a real
#     folder hierarchy -- see that notebook for the rationale.
#
# Note: dbo.bronze_notebook_definitions is the ONLY bronze table of this
# project with a VARCHAR(MAX) column (part_text) -- the source code of
# a real notebook exceeds the 8000 characters of the VARCHAR(8000) that the
# rest of the bronze tables use, so this table has its own creator/
# inserter instead of reusing the generic replace_table of the other
# notebooks (and it avoids fast_executemany, which can truncate large VARCHAR(MAX)
# binds when inferring the column size from the first batch).

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

import base64
import re
import struct
import time
from datetime import datetime, timezone

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
DEFINITION_FORMAT = "fabricGitSource"
MAX_OPERATION_POLLS = 30
OPERATION_POLL_DELAY_SECONDS = 3

# %% [markdown]
# ## Parameters
# Mark this cell as a parameters cell in Fabric.

# %%
WorkspaceNameFilter = ""

# %% [markdown]
# ## Authentication (same pattern as the previous notebooks)

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

# %% [markdown]
# ## Fabric REST helpers (paginated GET + POST/LRO for getDefinition)

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
            time.sleep(min(90, 2 ** (attempt + 1)))
            continue
        if response.status_code >= 400:
            return {"ok": False, "status_code": response.status_code, "error": response.text[:500], "payload": None}
        if REQUEST_DELAY_SECONDS:
            time.sleep(REQUEST_DELAY_SECONDS)
        return {"ok": True, "status_code": response.status_code, "error": "", "payload": response.json(), "headers": response.headers}
    return {"ok": False, "status_code": None, "error": "retries exhausted", "payload": None}


def get_definition(workspace_id, item_id, headers):
    """POST .../getDefinition, follow the standard Fabric LRO pattern
    (202 + Location poll -> Succeeded -> GET {location}/result), same
    shape as Invoke-FabricWebRequestCore's handling in LineageCommon.psm1."""
    url = f"{FABRIC_API_BASE_URL}/workspaces/{workspace_id}/items/{item_id}/getDefinition?format={DEFINITION_FORMAT}"
    for attempt in range(RETRY_COUNT + 1):
        response = requests.post(url, headers=headers, timeout=60)
        if response.status_code == 429 and attempt < RETRY_COUNT:
            time.sleep(min(90, 2 ** (attempt + 1)))
            continue
        break
    if response.status_code == 200:
        return {"ok": True, "payload": response.json(), "error": ""}
    if response.status_code != 202:
        return {"ok": False, "payload": None, "error": f"HTTP {response.status_code}: {response.text[:500]}"}

    location = response.headers.get("Location") or response.headers.get("location")
    if not location:
        match = re.search(r"[0-9a-fA-F-]{36}", response.headers.get("x-ms-operation-id", ""))
        if not match:
            return {"ok": False, "payload": None, "error": "202 with no Location/x-ms-operation-id header"}
        location = f"{FABRIC_API_BASE_URL}/operations/{match.group(0)}"

    for _ in range(MAX_OPERATION_POLLS):
        time.sleep(OPERATION_POLL_DELAY_SECONDS)
        op_response = requests.get(location, headers=headers, timeout=30)
        if op_response.status_code >= 400:
            return {"ok": False, "payload": None, "error": f"operation poll HTTP {op_response.status_code}: {op_response.text[:500]}"}
        op_payload = op_response.json()
        status = op_payload.get("status")
        if status == "Succeeded":
            result_response = requests.get(f"{location}/result", headers=headers, timeout=30)
            if result_response.status_code >= 400:
                return {"ok": False, "payload": None, "error": f"operation result HTTP {result_response.status_code}: {result_response.text[:500]}"}
            return {"ok": True, "payload": result_response.json(), "error": ""}
        if status == "Failed":
            return {"ok": False, "payload": None, "error": str(op_payload.get("error", "operation failed"))[:500]}
    return {"ok": False, "payload": None, "error": "operation did not settle within the polling window"}


def decode_part_text(payload_b64):
    padded = payload_b64 + "=" * (-len(payload_b64) % 4)
    return base64.b64decode(padded).decode("utf-8", errors="ignore")


# %% [markdown]
# ## Write to the Warehouse (dbo.bronze_notebook_definitions -- VARCHAR(MAX), without fast_executemany)

# %%
NOTEBOOK_DEFINITION_COLUMNS = [
    "workspace_name", "item_name", "item_qualified_name", "technical_id",
    "part_path", "part_text", "status", "error", "downloaded_at",
]


def replace_notebook_definitions_table(connection, rows):
    cursor = connection.cursor()
    cursor.execute("IF OBJECT_ID('dbo.bronze_notebook_definitions', 'U') IS NOT NULL DROP TABLE dbo.bronze_notebook_definitions;")
    cursor.execute(
        "CREATE TABLE dbo.bronze_notebook_definitions ("
        "workspace_name VARCHAR(400), item_name VARCHAR(400), item_qualified_name VARCHAR(1000), "
        "technical_id VARCHAR(100), part_path VARCHAR(400), part_text VARCHAR(MAX), "
        "status VARCHAR(50), error VARCHAR(2000), downloaded_at VARCHAR(50));"
    )
    connection.commit()
    insert_sql = (
        "INSERT INTO dbo.bronze_notebook_definitions "
        "(workspace_name, item_name, item_qualified_name, technical_id, part_path, part_text, status, error, downloaded_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"
    )
    # Without this, pyodbc silently binds a long part_text value (a real
    # notebook's source code easily exceeds the ~2000-char threshold)
    # using the legacy TEXT/NTEXT DAE wire format, which Fabric Warehouse's
    # default UTF-8 collation (Latin1_General_100_BIN2_UTF8) rejects with
    # "Cannot convert to text/ntext or collate..." (confirmed live)
    # forcing SQL_WVARCHAR on every parameter makes pyodbc
    # use the modern varchar(max)-compatible binding instead.
    input_sizes = [(pyodbc.SQL_WVARCHAR, 0, 0)] * 9
    for row in rows:
        cursor.setinputsizes(input_sizes)
        cursor.execute(
            insert_sql,
            row.get("workspace_name", ""), row.get("item_name", ""), row.get("item_qualified_name", ""),
            row.get("technical_id", ""), row.get("part_path", ""), row.get("part_text", ""),
            row.get("status", ""), row.get("error", "")[:1990], row.get("downloaded_at", ""),
        )
    connection.commit()
    print(f"[warehouse] dbo.bronze_notebook_definitions: {len(rows)} row(s) written.")


def read_existing_definitions_outside_filter(connection, filter_set):
    if not filter_set:
        return []
    cursor = connection.cursor()
    try:
        cursor.execute(f"SELECT {', '.join(NOTEBOOK_DEFINITION_COLUMNS)} FROM dbo.bronze_notebook_definitions")
    except pyodbc.Error:
        connection.rollback()
        return []
    return [
        dict(zip(NOTEBOOK_DEFINITION_COLUMNS, row))
        for row in cursor.fetchall()
        if str(row[0]).strip().lower() not in filter_set
    ]


def read_notebook_items(connection, filter_set):
    cursor = connection.cursor()
    cursor.execute(
        "SELECT workspace_name, item_name, qualified_name, technical_id "
        "FROM dbo.bronze_items WHERE item_type = 'Notebook' AND status = 'discovered'"
    )
    rows = [
        {"workspace_name": r[0], "item_name": r[1], "qualified_name": r[2], "technical_id": r[3]}
        for r in cursor.fetchall()
    ]
    if filter_set:
        rows = [r for r in rows if (r["workspace_name"] or "").strip().lower() in filter_set]
    return rows


def read_workspace_ids(connection):
    cursor = connection.cursor()
    cursor.execute("SELECT workspace_name, technical_id FROM dbo.bronze_workspaces")
    return {r[0]: r[1] for r in cursor.fetchall()}


# %% [markdown]
# ## Ejecutar

# %%
fabric_token = acquire_token("https://api.fabric.microsoft.com/.default")
fabric_headers = {"Authorization": f"Bearer {fabric_token}"}

filter_set = {n.strip().lower() for n in re.split(r"[;,]", WorkspaceNameFilter or "") if n.strip()}

notebook_items = read_notebook_items(WAREHOUSE_CONNECTION, filter_set)
workspace_ids_by_name = read_workspace_ids(WAREHOUSE_CONNECTION)
now_iso = datetime.now(timezone.utc).replace(microsecond=0).isoformat()

new_rows = []
for item in notebook_items:
    workspace_id = workspace_ids_by_name.get(item["workspace_name"], "")
    if not workspace_id or not item["technical_id"]:
        new_rows.append({
            "workspace_name": item["workspace_name"], "item_name": item["item_name"],
            "item_qualified_name": item["qualified_name"], "technical_id": item["technical_id"],
            "part_path": "", "part_text": "", "status": "failed",
            "error": "Missing workspace technical_id or item technical_id.", "downloaded_at": now_iso,
        })
        continue

    result = get_definition(workspace_id, item["technical_id"], fabric_headers)
    if not result["ok"]:
        new_rows.append({
            "workspace_name": item["workspace_name"], "item_name": item["item_name"],
            "item_qualified_name": item["qualified_name"], "technical_id": item["technical_id"],
            "part_path": "", "part_text": "", "status": "failed",
            "error": result["error"], "downloaded_at": now_iso,
        })
        continue

    parts = ((result["payload"] or {}).get("definition") or {}).get("parts", [])
    if not parts:
        new_rows.append({
            "workspace_name": item["workspace_name"], "item_name": item["item_name"],
            "item_qualified_name": item["qualified_name"], "technical_id": item["technical_id"],
            "part_path": "", "part_text": "", "status": "failed",
            "error": "getDefinition returned no parts.", "downloaded_at": now_iso,
        })
        continue

    for part in parts:
        if part.get("payloadType") != "InlineBase64":
            continue
        try:
            part_text = decode_part_text(part.get("payload", ""))
        except Exception as exc:  # noqa: BLE001 -- one bad part shouldn't drop the whole notebook
            new_rows.append({
                "workspace_name": item["workspace_name"], "item_name": item["item_name"],
                "item_qualified_name": item["qualified_name"], "technical_id": item["technical_id"],
                "part_path": part.get("path", ""), "part_text": "", "status": "failed",
                "error": f"base64 decode error: {exc}", "downloaded_at": now_iso,
            })
            continue
        new_rows.append({
            "workspace_name": item["workspace_name"], "item_name": item["item_name"],
            "item_qualified_name": item["qualified_name"], "technical_id": item["technical_id"],
            "part_path": part.get("path", ""), "part_text": part_text, "status": "downloaded",
            "error": "", "downloaded_at": now_iso,
        })

# Reconnect with a fresh database token -- the connection
# above has been open since before the per-notebook loop (the whole
# tenant, with getDefinition + LRO polling of up to 90s per item), the
# same pattern that already caused a real connection failure ("TCP Provider:
# Error code 0x20") in NB_Discover_Dependencies.py -- same fix applied
# here preventively.
WAREHOUSE_CONNECTION.close()
WAREHOUSE_CONNECTION = connect_warehouse()

existing_rows = read_existing_definitions_outside_filter(WAREHOUSE_CONNECTION, filter_set)
final_rows = existing_rows + new_rows
replace_notebook_definitions_table(WAREHOUSE_CONNECTION, final_rows)

downloaded_items = {r["item_qualified_name"] for r in new_rows if r["status"] == "downloaded"}
failed_items = {r["item_qualified_name"] for r in new_rows if r["status"] == "failed"}
print(f"Notebook definitions downloaded: {len(downloaded_items)} item(s), {len(failed_items)} failed, {len(final_rows)} row(s) total in table.")
