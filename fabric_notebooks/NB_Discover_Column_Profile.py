# NB_Discover_Column_Profile
#
# Source for a Fabric Python notebook -- column statistical profiling.
# Replica of the already established native discovery pipeline (see
# docs/105_fabric_native_discovery_setup.md), but read-only against Fabric
# Lakehouses instead of against the Fabric API -- first version, scope
# deliberately limited to the workspaces where this service principal
# ALREADY has a data role (Contributor/Member/Viewer) today, without granting
# anything new.
#
# Unlike profiling against external SQL (blocked -- see
# docs/105), this connects to Lakehouses
# 100% inside Fabric via their own SQL analytics endpoint -- the same
# network route that connect_warehouse() already uses in all the existing
# "Discover" notebooks, without any Data Gateway or external connectivity
# in between.
#
# Read-only: aggregate SELECTs (COUNT/MIN/MAX/COUNT DISTINCT) per
# column, never individual row values -- see NB_Discover_Column_
# Sensitivity.py (the next piece of the pipeline) for the case that does
# need to look at real content, with its own safeguards.
#
# Writes to dbo.bronze_column_profile (replace-only, like the
# rest of the pipeline).

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

import struct
import time
import urllib.error
import urllib.request
import json

FABRIC_API_BASE_URL = "https://api.fabric.microsoft.com/v1"

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"
ONELAKE_WORKSPACE_NAME = "<your-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<your-onelake-lakehouse>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"
WAREHOUSE_SQL_ENDPOINT = "<your-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<WarehouseName>"

# Current scope: only workspaces where the SP already has a data role,
# confirmed live against dbo.bronze_workspace_
# role_assignments -- zero new permissions granted for this first
# pass. Extending this list is a governance decision for the user,
# not a code change.
TARGET_WORKSPACE_NAMES = [
    "Datamart-Sales_Contoso_Pro",
    "DigitalAnalytics-Sample_Contoso_Dev",
    "DigitalAnalytics-Sample_Contoso_Pro",
]

MAX_TABLES_PER_LAKEHOUSE = 200  # defensive cap, not an expected limit
PROFILE_COLUMNS = [
    "workspace_name", "lakehouse_name", "table_name", "column_name", "data_type",
    "row_count", "null_count", "null_percentage", "distinct_count",
    "min_value", "max_value", "profiled_at", "status", "notes",
]

# %% [markdown]
# ## Authentication (same pattern as the discovery notebooks)

# %%
def get_sp_client_secret():
    onelake_path = (
        f"abfss://{ONELAKE_WORKSPACE_NAME}@onelake.dfs.fabric.microsoft.com/"
        f"{ONELAKE_LAKEHOUSE_NAME}.Lakehouse/{SP_SECRET_ONELAKE_PATH}"
    )
    return notebookutils.fs.head(onelake_path, 200).strip()


_client_secret_cache = None


def acquire_token(scope):
    global _client_secret_cache
    if _client_secret_cache is None:
        _client_secret_cache = get_sp_client_secret()
    app = msal.ConfidentialClientApplication(
        SP_CLIENT_ID,
        authority=f"https://login.microsoftonline.com/{SP_TENANT_ID}",
        client_credential=_client_secret_cache,
    )
    result = app.acquire_token_for_client(scopes=[scope])
    if not result or "access_token" not in result:
        raise RuntimeError(f"Could not acquire a token for {scope}: {(result or {}).get('error_description', '')}")
    return result["access_token"]


def token_struct(token):
    raw = token.encode("utf-16-le")
    return struct.pack(f"<I{len(raw)}s", len(raw), raw)


def pick_odbc_driver():
    available = sorted((d for d in pyodbc.drivers() if "ODBC Driver" in d and "SQL Server" in d), reverse=True)
    if not available:
        raise RuntimeError(f"No ODBC driver found (saw: {pyodbc.drivers()})")
    return available[0]


def connect_warehouse():
    db_token = acquire_token("https://database.windows.net/.default")
    conn_str = f"DRIVER={{{pick_odbc_driver()}}};SERVER={WAREHOUSE_SQL_ENDPOINT};DATABASE={WAREHOUSE_DATABASE_NAME};Encrypt=yes"
    return pyodbc.connect(conn_str, attrs_before={1256: token_struct(db_token)}, timeout=30)


def fabric_get(path):
    token = acquire_token("https://api.fabric.microsoft.com/.default")
    req = urllib.request.Request(f"{FABRIC_API_BASE_URL}/{path.lstrip('/')}", method="GET")
    req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))

# %% [markdown]
# ## Step 1: resolve workspace_id + lakehouses + their SQL endpoint, from
# the already discovered catalog itself (dbo.bronze_items/bronze_workspaces)

# %%
connection = connect_warehouse()
cursor = connection.cursor()

placeholders = ", ".join("?" for _ in TARGET_WORKSPACE_NAMES)
cursor.execute(
    f"SELECT workspace_name, technical_id FROM dbo.bronze_workspaces WHERE workspace_name IN ({placeholders})",
    TARGET_WORKSPACE_NAMES,
)
workspace_id_by_name = {r[0]: r[1] for r in cursor.fetchall()}
print(f"Target workspaces resolved: {workspace_id_by_name}")

cursor.execute(
    f"SELECT workspace_name, item_name, technical_id FROM dbo.bronze_items "
    f"WHERE workspace_name IN ({placeholders}) AND item_type = 'Lakehouse'",
    TARGET_WORKSPACE_NAMES,
)
lakehouses = [{"workspace_name": r[0], "lakehouse_name": r[1], "lakehouse_id": r[2]} for r in cursor.fetchall()]
connection.close()
print(f"Lakehouses in scope: {len(lakehouses)}")

# %% [markdown]
# ## Step 2: for each Lakehouse, resolve its SQL endpoint (detail
# API, properties.sqlEndpointProperties.connectionString)

# %%
profile_rows = []
gap_rows = []

for lh in lakehouses:
    workspace_id = workspace_id_by_name.get(lh["workspace_name"], "")
    if not workspace_id or not lh["lakehouse_id"]:
        gap_rows.append({**lh, "gap_reason": "missing_workspace_or_lakehouse_id"})
        continue
    try:
        detail = fabric_get(f"workspaces/{workspace_id}/lakehouses/{lh['lakehouse_id']}")
        sql_props = ((detail.get("properties") or {}).get("sqlEndpointProperties") or {})
        connection_string = sql_props.get("connectionString", "")
        if not connection_string:
            gap_rows.append({**lh, "gap_reason": "no_sql_endpoint_connection_string"})
            continue
        lh["sql_endpoint"] = connection_string
        lh["database_name"] = lh["lakehouse_name"]
    except Exception as exc:  # noqa: BLE001 - one lakehouse's detail lookup must not abort the rest
        gap_rows.append({**lh, "gap_reason": "lakehouse_detail_api_failed", "error": f"{type(exc).__name__}: {exc}"})

lakehouses_with_endpoint = [lh for lh in lakehouses if lh.get("sql_endpoint")]
print(f"Lakehouses with a resolved SQL endpoint: {len(lakehouses_with_endpoint)}")

# %% [markdown]
# ## Step 3: for each Lakehouse, list tables and profile columns
# (read-only aggregates, no individual rows)

# %%
def connect_lakehouse(sql_endpoint, database_name):
    db_token = acquire_token("https://database.windows.net/.default")
    conn_str = f"DRIVER={{{pick_odbc_driver()}}};SERVER={sql_endpoint};DATABASE={database_name};Encrypt=yes"
    return pyodbc.connect(conn_str, attrs_before={1256: token_struct(db_token)}, timeout=30)


# MIN/MAX is only safe to expose for types where the extreme value can't
# itself BE a piece of real personal data -- confirmed live 2026-08-17
# that a string column's MIN/MAX literally returned a real person's first
# name (e.g. "Aaliyah", "Zheng") from dbo.LDAPUsers.FirstName. Numeric/date/time
# extremes are safe aggregates (a number, a timestamp); string/text
# extremes are not, since the "smallest"/"largest" value alphabetically
# is still a real, identifiable row value. Restricted to an explicit
# allow-list rather than a deny-list, so a new/unexpected data_type
# defaults to the safe (no min/max) side.
_MIN_MAX_SAFE_TYPE_PREFIXES = (
    "int", "bigint", "smallint", "tinyint", "bit", "decimal", "numeric",
    "float", "real", "money", "smallmoney",
    "date", "time", "datetime", "smalldatetime",
)


def _min_max_is_safe(data_type):
    return (data_type or "").lower().startswith(_MIN_MAX_SAFE_TYPE_PREFIXES)


def build_profile_query(schema, table, columns):
    # One round trip per table instead of one per column -- COUNT(*) once,
    # then per column: null count (COUNT(*) - COUNT(col)), distinct count,
    # and MIN/MAX only for the safe types above.
    select_parts = ["COUNT_BIG(*) AS row_count"]
    for col in columns:
        name = col["column_name"]
        safe = name.replace("]", "]]")
        select_parts.append(f"COUNT_BIG([{safe}]) AS [null_check__{name}]")
        select_parts.append(f"COUNT_BIG(DISTINCT [{safe}]) AS [distinct__{name}]")
        if _min_max_is_safe(col["data_type"]):
            select_parts.append(f"CAST(MIN([{safe}]) AS NVARCHAR(200)) AS [min__{name}]")
            select_parts.append(f"CAST(MAX([{safe}]) AS NVARCHAR(200)) AS [max__{name}]")
    return f"SELECT {', '.join(select_parts)} FROM [{schema}].[{table}]"


for lh in lakehouses_with_endpoint:
    try:
        lh_conn = connect_lakehouse(lh["sql_endpoint"], lh["database_name"])
        lh_cursor = lh_conn.cursor()
    except Exception as exc:  # noqa: BLE001
        gap_rows.append({**lh, "gap_reason": "connection_failed", "error": f"{type(exc).__name__}: {exc}"})
        continue

    try:
        lh_cursor.execute(
            "SELECT TABLE_SCHEMA, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES "
            "WHERE TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_SCHEMA, TABLE_NAME"
        )
        tables = [(r[0], r[1]) for r in lh_cursor.fetchall()][:MAX_TABLES_PER_LAKEHOUSE]
    except Exception as exc:  # noqa: BLE001
        gap_rows.append({**lh, "gap_reason": "list_tables_failed", "error": f"{type(exc).__name__}: {exc}"})
        lh_conn.close()
        continue

    for schema, table in tables:
        try:
            lh_cursor.execute(
                "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS "
                "WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? ORDER BY ORDINAL_POSITION",
                schema, table,
            )
            columns = [{"column_name": r[0], "data_type": r[1]} for r in lh_cursor.fetchall()]
            if not columns:
                continue
            query = build_profile_query(schema, table, columns)
            lh_cursor.execute(query)
            row = lh_cursor.fetchone()
            row_dict = {desc[0]: value for desc, value in zip(lh_cursor.description, row)}
            row_count = row_dict.get("row_count", 0)
            now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            for col in columns:
                name = col["column_name"]
                null_check = row_dict.get(f"null_check__{name}")
                non_null_count = null_check if null_check is not None else 0
                null_count = (row_count or 0) - non_null_count
                profile_rows.append({
                    "workspace_name": lh["workspace_name"], "lakehouse_name": lh["lakehouse_name"],
                    "table_name": f"{schema}.{table}", "column_name": name, "data_type": col["data_type"],
                    "row_count": row_count, "null_count": null_count,
                    "null_percentage": round(100.0 * null_count / row_count, 2) if row_count else 0.0,
                    "distinct_count": row_dict.get(f"distinct__{name}"),
                    "min_value": row_dict.get(f"min__{name}"), "max_value": row_dict.get(f"max__{name}"),
                    "profiled_at": now_iso, "status": "profiled", "notes": "",
                })
        except Exception as exc:  # noqa: BLE001 - one table's profiling failure must not abort the rest
            gap_rows.append({
                "workspace_name": lh["workspace_name"], "lakehouse_name": lh["lakehouse_name"],
                "table_name": f"{schema}.{table}", "gap_reason": "profile_query_failed",
                "error": f"{type(exc).__name__}: {exc}",
            })

    lh_conn.close()

print(f"Profiled columns: {len(profile_rows)}. Gaps: {len(gap_rows)}.")

# %% [markdown]
# ## Write to the Warehouse (full replacement, like the rest
# of the pipeline)

# %%
connection = connect_warehouse()
cursor = connection.cursor()
cursor.execute("IF OBJECT_ID('dbo.bronze_column_profile', 'U') IS NOT NULL DROP TABLE dbo.bronze_column_profile;")
column_defs = ", ".join(f"[{c}] VARCHAR(4000)" for c in PROFILE_COLUMNS)
cursor.execute(f"CREATE TABLE dbo.bronze_column_profile ({column_defs});")
connection.commit()
if profile_rows:
    placeholders_sql = ", ".join("?" for _ in PROFILE_COLUMNS)
    insert_sql = f"INSERT INTO dbo.bronze_column_profile ({', '.join(f'[{c}]' for c in PROFILE_COLUMNS)}) VALUES ({placeholders_sql})"
    cursor.fast_executemany = True
    cursor.executemany(insert_sql, [[str(row.get(c, "") if row.get(c, "") is not None else "") for c in PROFILE_COLUMNS] for row in profile_rows])
    connection.commit()
connection.close()
print(f"dbo.bronze_column_profile: {len(profile_rows)} row(s) written. Gaps (not written, for visibility only): {len(gap_rows)}")
if gap_rows:
    print(json.dumps(gap_rows[:10], indent=2, default=str))
