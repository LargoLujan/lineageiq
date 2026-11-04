# NB_Confirm_Source_Object_Types
#
# Source for a Fabric Python notebook -- sixth, optional step of the
# native discovery pipeline (see docs/105_fabric_native_discovery_
# setup.md). Each "# %%" block is a cell -- paste them in order.
#
# Faithful replica of scripts/20_extract_source_object_type_metadata.ps1: for
# each "ambiguous" candidate object (`table_or_view`/`native_query_object`,
# i.e. it is not known for sure whether it is a table, view or stored
# procedure) collected in dbo.bronze_semantic_model_view_candidates +
# dbo.bronze_item_object_lineage_candidates + dbo.bronze_pipeline_object_
# lineage_candidates, it REALLY connects to the external SQL server where
# that object lives and queries sys.objects/sys.schemas to resolve the
# exact type with certainty -- read-only, it never writes anything to the source.
#
# IMPORTANT WARNING, different from all the previous notebooks: this
# is the ONLY step of the whole native pipeline that leaves Fabric towards a
# SQL server that is NOT a Fabric one. Notebooks 1-5 only call the Fabric API
# or the Warehouse itself -- both, by definition, reachable
# from a Fabric notebook. This one, in contrast, needs the Fabric runtime
# to have a network route to every external SQL server that appears in
# the candidates (VNet Data Gateway, the capacity's outbound IP
# allowed in the server firewall, etc.) -- an infrastructure question of
# your tenant that this code neither solves nor verifies.
# If a server is not reachable, that specific target simply ends up
# as a "gap" (just as the original script does if the connection fails),
# without breaking the rest of the notebook -- but if NO server is reachable,
# this whole step contributes nothing until that connectivity is resolved
# (Fabric Data Gateway, or keep this particular step running
# locally with scripts/20_extract_source_object_type_metadata.ps1 instead of
# here).
#
# Writes to dbo.bronze_source_object_type_metadata_evidence (22 columns)
# and dbo.bronze_source_object_type_metadata_gaps (12 columns) -- the same
# tables that scripts/67_upload_bronze_to_warehouse.ps1 already uploads from local.
#
# Authentication to the external server: per server, SQL username/password
# (password in Key Vault, like the service account secret)
# or the service account's own AAD token (only works if that
# server trusts Entra ID and the service account has a login there)
# -- see EXTERNAL_SOURCES in the configuration cell.
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

import re
import struct
import time
from datetime import datetime, timezone

FABRIC_API_BASE_URL = "https://api.fabric.microsoft.com/v1"

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"
# The service account's own secret is no longer read from Key Vault
# (blocked) NOR from a pipeline parameter (tested: it leaked
# the value in plain text when the type conversion failed -- never again
# that way). Private file in the Files area of the workspace Lakehouse,
# read with notebookutils.fs.head(). AKV_ENDPOINT is kept only for the
# optional use of EXTERNAL_SOURCES (auth_mode "sql_auth" further down), which
# still reads its own password from Key Vault if that list is ever
# filled in.
AKV_ENDPOINT = "https://<your-key-vault>.vault.azure.net/"
ONELAKE_WORKSPACE_NAME = "<your-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<your-onelake-lakehouse>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"
WAREHOUSE_SQL_ENDPOINT = "<your-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<WarehouseName>"

# One record per external SQL server you want to resolve here. auth_mode
# "sql_auth" reads the password from Key Vault (akv_secret_name); "aad_token"
# reuses the service account's own token -- only works if
# that server trusts Entra ID and the service account has access.
EXTERNAL_SOURCES = [
    # {"host": "<sql-server-host>", "port": 1433, "auth_mode": "sql_auth", "user": "readonly_user", "akv_secret_name": "sql-readonly-password"},
]

CONNECT_TIMEOUT_SECONDS = 12
COMMAND_TIMEOUT_SECONDS = 60
AMBIGUOUS_TYPES = {"table_or_view", "native_query_object"}

EVIDENCE_COLUMNS = [
    "source_type", "source_server", "source_database", "schema_name", "object_name", "object_type",
    "confidence", "evidence", "resolver", "reviewed_at", "metadata_server", "metadata_database",
    "metadata_schema_name", "metadata_object_name", "metadata_type_code", "metadata_type_desc",
    "raw_object_type", "candidate_count", "impacted_item_count", "impacted_item_types",
    "impacted_items_sample", "notes",
]
GAP_COLUMNS = [
    "source_type", "source_server", "source_database", "schema_name", "object_name", "raw_object_type",
    "gap_reason", "error", "candidate_count", "impacted_item_count", "impacted_items_sample", "next_step",
]

# %% [markdown]
# ## Parameters
# Mark this cell as a parameters cell in Fabric.

# %%
WorkspaceNameFilter = ""

# %% [markdown]
# ## Authentication and Warehouse (same pattern as the previous notebooks)

# %%
def get_secret(secret_name):
    return notebookutils.credentials.getSecret(AKV_ENDPOINT, secret_name)


def get_sp_client_secret():
    onelake_path = (
        f"abfss://{ONELAKE_WORKSPACE_NAME}@onelake.dfs.fabric.microsoft.com/"
        f"{ONELAKE_LAKEHOUSE_NAME}.Lakehouse/{SP_SECRET_ONELAKE_PATH}"
    )
    return notebookutils.fs.head(onelake_path, 200).strip()


def acquire_token(scope):
    app = msal.ConfidentialClientApplication(
        SP_CLIENT_ID,
        authority=f"https://login.microsoftonline.com/{SP_TENANT_ID}",
        client_credential=get_sp_client_secret(),
    )
    result = app.acquire_token_for_client(scopes=[scope])
    if not result or "access_token" not in result:
        description = (result or {}).get("error_description", "no access_token returned")
        raise RuntimeError(f"Could not acquire a token for {scope}: {description}")
    return result["access_token"]


def token_struct(token):
    raw = token.encode("utf-16-le")
    return struct.pack(f"<I{len(raw)}s", len(raw), raw)


def pick_odbc_driver():
    # Fabric's managed Spark runtime doesn't always ship the same ODBC
    # driver major version as a local dev machine (confirmed live:
    # "ODBC Driver 17 for SQL Server" -- file not found).
    # Picks whichever "ODBC Driver NN for SQL Server" is actually
    # installed, newest major version first, instead of a fixed guess.
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
    return text[:7950] + " ...[truncated]" if len(text) > max_len else text


def normalize_key(value):
    return re.sub(r"\s+", " ", (value or "").strip().lower())


def normalize_server_host(value):
    if not value:
        return ""
    clean = value.strip().lower()
    clean = re.sub(r"^tcp:", "", clean)
    if "," in clean:
        clean = clean.split(",", 1)[0]
    elif clean.count(":") == 1:
        clean = clean.split(":", 1)[0]
    return clean.strip()


# %% [markdown]
# ## Connection to the external SQL server (Invoke-ObjectMetadataQuery)

# %%
def find_external_source(server):
    server_host = normalize_server_host(server)
    for source in EXTERNAL_SOURCES:
        if normalize_server_host(source.get("host", "")) == server_host:
            return source
    return None


def query_object_metadata(source_server, source_database):
    source = find_external_source(source_server)
    port = (source or {}).get("port", 1433)
    conn_str = (
        f"DRIVER={{{pick_odbc_driver()}}};SERVER=tcp:{source_server},{port};"
        f"DATABASE={source_database};Encrypt=yes;Connect Timeout={CONNECT_TIMEOUT_SECONDS}"
    )
    if source and source.get("auth_mode") == "sql_auth":
        password = get_secret(source["akv_secret_name"])
        conn_str += f";UID={source['user']};PWD={password}"
        connection = pyodbc.connect(conn_str, timeout=CONNECT_TIMEOUT_SECONDS)
    else:
        token = acquire_token("https://database.windows.net/.default")
        connection = pyodbc.connect(conn_str, attrs_before={1256: token_struct(token)}, timeout=CONNECT_TIMEOUT_SECONDS)

    try:
        cursor = connection.cursor()
        cursor.execute(
            """
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
                o.type_desc as type_desc
            from sys.objects o
            inner join sys.schemas s on o.schema_id = s.schema_id
            where isnull(o.is_ms_shipped, 0) = 0
              and o.type in ('U', 'ET', 'V', 'P', 'PC', 'X', 'RF')
            order by s.name, o.name
            """
        )
        return [
            {"schema_name": r[0], "object_name": r[1], "object_type": r[2], "type_code": str(r[3]).strip(), "type_desc": r[4]}
            for r in cursor.fetchall()
        ]
    finally:
        connection.close()


# %% [markdown]
# ## Aggregation of ambiguous candidates (Add-Candidate / New-CandidateKey / New-TargetKey)

# %%
def normalize_object_type(value):
    clean = re.sub(r"[\s-]+", "_", normalize_key(value))
    return {"storedprocedure": "stored_procedure", "procedure": "stored_procedure", "proc": "stored_procedure", "sp": "stored_procedure", "tbl": "table"}.get(clean, clean)


def is_candidate_object_name_valid(object_name):
    if not object_name:
        return False
    clean = object_name.strip()
    if len(clean) > 256:
        return False
    if re.match(r"(?i:^(https?|abfss|s3|wasbs?)://)", clean):
        return False
    if re.search(r"[{}]", clean):
        return False
    if re.match(r"^[,.;:]+$", clean):
        return False
    return True


def add_candidate(candidate_map, workspace_name, item_type, item_qualified_name, source_type,
                   source_server, source_database, schema_name, object_name, raw_object_type, evidence):
    normalized_type = normalize_object_type(raw_object_type)
    if normalized_type not in AMBIGUOUS_TYPES:
        return
    if not is_candidate_object_name_valid(object_name):
        return
    key = "|".join(normalize_key(v) for v in (source_type, source_server, source_database, schema_name, object_name, normalized_type))
    candidate = candidate_map.setdefault(key, {
        "source_type": source_type, "source_server": source_server, "source_database": source_database,
        "schema_name": schema_name, "object_name": object_name, "raw_object_type": normalized_type,
        "candidate_count": 0, "workspaces": set(), "item_types": set(), "items": set(),
    })
    candidate["candidate_count"] += 1
    if workspace_name:
        candidate["workspaces"].add(workspace_name)
    if item_type:
        candidate["item_types"].add(item_type)
    if item_qualified_name:
        candidate["items"].add(item_qualified_name)


def target_key(source_server, source_database):
    return f"{normalize_key(source_server)}|{normalize_key(source_database)}"


# %% [markdown]
# ## Load ambiguous candidates from the three object lineage tables

# %%
connection = connect_warehouse()
cursor = connection.cursor()

candidate_map = {}


def load_candidates_from(table_name, workspace_key, item_type_key_or_value, item_qn_keys, server_key, database_keys, schema_key, object_key, type_key):
    try:
        cursor.execute(f"SELECT * FROM dbo.{table_name}")
        columns = [c[0] for c in cursor.description]
    except pyodbc.Error:
        connection.rollback()
        print(f"[confirm-object-types] dbo.{table_name} not found -- skipping (run its discovery notebook first for full coverage).")
        return
    for raw in cursor.fetchall():
        row = dict(zip(columns, raw))
        item_qualified_name = next((row.get(k) for k in item_qn_keys if row.get(k)), "")
        source_database = next((row.get(k) for k in database_keys if row.get(k)), "")
        item_type_value = row.get(item_type_key_or_value, item_type_key_or_value) if item_type_key_or_value in columns else item_type_key_or_value
        add_candidate(
            candidate_map, row.get(workspace_key, ""), item_type_value, item_qualified_name, "SQL",
            row.get(server_key, ""), source_database, row.get(schema_key, ""), row.get(object_key, ""),
            row.get(type_key, ""), row.get("evidence", ""),
        )


load_candidates_from("bronze_semantic_model_view_candidates", "workspace_name", "SemanticModel",
                     ("semantic_model_qualified_name",), "source_server", ("database_name", "source_database"),
                     "schema_name", "object_name", "object_type")
load_candidates_from("bronze_item_object_lineage_candidates", "workspace_name", "item_type",
                     ("item_qualified_name",), "source_server", ("source_database",),
                     "schema_name", "object_name", "object_type")
load_candidates_from("bronze_pipeline_object_lineage_candidates", "workspace_name", "item_type",
                     ("item_qualified_name",), "source_server", ("source_database",),
                     "schema_name", "object_name", "object_type")

candidates = list(candidate_map.values())
print(f"Ambiguous unique candidates: {len(candidates)}")

# %% [markdown]
# ## Group by server/database and filter by WorkspaceNameFilter

# %%
targets_by_key = {}
for candidate in candidates:
    if not candidate["source_server"] or not candidate["source_database"]:
        continue
    key = target_key(candidate["source_server"], candidate["source_database"])
    group = targets_by_key.setdefault(key, {"source_server": candidate["source_server"], "source_database": candidate["source_database"], "candidates": []})
    group["candidates"].append(candidate)

target_groups = sorted(targets_by_key.values(), key=lambda g: (-sum(c["candidate_count"] for c in g["candidates"]), g["source_server"], g["source_database"]))

filter_set = {n.strip().lower() for n in re.split(r"[;,]", WorkspaceNameFilter or "") if n.strip()}
if filter_set:
    target_groups = [
        g for g in target_groups
        if any(normalize_key(w) in filter_set for c in g["candidates"] for w in c["workspaces"])
    ]
print(f"Metadata targets to query: {len(target_groups)} ({'filtered: ' + WorkspaceNameFilter if filter_set else 'full tenant'})")

# %% [markdown]
# ## Run: query each external server (read-only), resolve the exact type

# %%
def sample_join(values, limit=12):
    return "; ".join(sorted(values)[:limit])


evidence_rows = []
gap_rows = []
queried_target_keys = set()

for candidate in candidates:
    if not candidate["source_server"] or not candidate["source_database"]:
        gap_rows.append({
            "source_type": candidate["source_type"], "source_server": candidate["source_server"],
            "source_database": candidate["source_database"], "schema_name": candidate["schema_name"],
            "object_name": candidate["object_name"], "raw_object_type": candidate["raw_object_type"],
            "gap_reason": "missing_metadata_target", "error": "Source server or database is missing, so no SQL metadata query can be built.",
            "candidate_count": candidate["candidate_count"], "impacted_item_count": len(candidate["items"]),
            "impacted_items_sample": sample_join(candidate["items"]),
            "next_step": "Resolve the source endpoint/database from Fabric item connections, code, owner evidence, or manual review.",
        })

for target in target_groups:
    queried_target_keys.add(target_key(target["source_server"], target["source_database"]))
    print(f"Querying metadata: {target['source_server']} / {target['source_database']} ({len(target['candidates'])} objects)")
    try:
        metadata_rows = query_object_metadata(target["source_server"], target["source_database"])
        target_error = ""
    except Exception as exc:  # noqa: BLE001 - one unreachable target must not abort the rest (see module docstring)
        metadata_rows = None
        target_error = str(exc)

    if metadata_rows is None:
        for candidate in target["candidates"]:
            gap_rows.append({
                "source_type": candidate["source_type"], "source_server": candidate["source_server"],
                "source_database": candidate["source_database"], "schema_name": candidate["schema_name"],
                "object_name": candidate["object_name"], "raw_object_type": candidate["raw_object_type"],
                "gap_reason": "metadata_query_failed", "error": target_error,
                "candidate_count": candidate["candidate_count"], "impacted_item_count": len(candidate["items"]),
                "impacted_items_sample": sample_join(candidate["items"]),
                "next_step": "Validate read-only metadata access (network reachability, credentials) for this SQL endpoint, or resolve the type through owner/manual evidence.",
            })
        continue

    by_schema_and_name = {}
    by_name = {}
    for meta in metadata_rows:
        by_schema_and_name.setdefault(f"{normalize_key(meta['schema_name'])}|{normalize_key(meta['object_name'])}", []).append(meta)
        by_name.setdefault(normalize_key(meta["object_name"]), []).append(meta)

    for candidate in target["candidates"]:
        candidate_schema = normalize_key(candidate["schema_name"])
        candidate_name = normalize_key(candidate["object_name"])
        match, gap_reason, gap_error = None, "", ""

        if candidate_schema:
            lookup_key = f"{candidate_schema}|{candidate_name}"
            if lookup_key in by_schema_and_name:
                match = by_schema_and_name[lookup_key][0]
            elif candidate_name in by_name:
                gap_reason, gap_error = "object_not_found_with_schema", f"Object name exists in metadata, but not under schema '{candidate['schema_name']}'."
            else:
                gap_reason, gap_error = "object_not_found", "Object was not found in sys.objects for this target."
        elif candidate_name in by_name:
            matches = by_name[candidate_name]
            schemas = {m["schema_name"] for m in matches}
            if len(schemas) == 1:
                match = matches[0]
            else:
                gap_reason, gap_error = "object_name_found_in_multiple_schemas", f"Object name was found in multiple schemas: {', '.join(sorted(schemas))}."
        else:
            gap_reason, gap_error = "object_not_found", "Object was not found in sys.objects for this target."

        if match:
            metadata_schema = match["schema_name"]
            evidence_rows.append({
                "source_type": candidate["source_type"], "source_server": candidate["source_server"],
                "source_database": candidate["source_database"], "schema_name": candidate["schema_name"] or "",
                "object_name": candidate["object_name"], "object_type": normalize_object_type(match["object_type"]),
                "confidence": "confirmed",
                "evidence": f"Read-only metadata query against {candidate['source_server']}/{candidate['source_database']} found {metadata_schema}.{match['object_name']} as {match['type_desc']}.",
                "resolver": "sql_metadata_notebook", "reviewed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "metadata_server": target["source_server"], "metadata_database": target["source_database"],
                "metadata_schema_name": metadata_schema, "metadata_object_name": match["object_name"],
                "metadata_type_code": match["type_code"], "metadata_type_desc": match["type_desc"],
                "raw_object_type": candidate["raw_object_type"], "candidate_count": candidate["candidate_count"],
                "impacted_item_count": len(candidate["items"]), "impacted_item_types": sample_join(candidate["item_types"], limit=50),
                "impacted_items_sample": sample_join(candidate["items"]),
                "notes": "Exact schema/object metadata match." if candidate["schema_name"] else f"Object name uniquely matched metadata schema '{metadata_schema}'.",
            })
        else:
            gap_rows.append({
                "source_type": candidate["source_type"], "source_server": candidate["source_server"],
                "source_database": candidate["source_database"], "schema_name": candidate["schema_name"],
                "object_name": candidate["object_name"], "raw_object_type": candidate["raw_object_type"],
                "gap_reason": gap_reason, "error": gap_error,
                "candidate_count": candidate["candidate_count"], "impacted_item_count": len(candidate["items"]),
                "impacted_items_sample": sample_join(candidate["items"]),
                "next_step": "Confirm the exact source object name/schema from SQL metadata, code, or owner review.",
            })

print(f"Evidence rows: {len(evidence_rows)}. Gap rows: {len(gap_rows)}.")

# %% [markdown]
# ## Write to the Warehouse, keeping targets outside WorkspaceNameFilter
# that were not queried again this time

# %%
# Reconnect with a fresh database token -- the connection above
# has been open since before the loop of read-only queries
# against each distinct external SQL server (with timeouts/retries per
# target), the same pattern that already caused a real connection failure ("TCP
# Provider: Error code 0x20") in NB_Discover_Dependencies.py -- same fix
# applied here preventively. The functions below reference
# `connection`/`cursor` by closure, so it is enough to reassign them before
# calling them.
connection.close()
connection = connect_warehouse()
cursor = connection.cursor()


def retain_outside_queried_targets(table_name, columns, is_gap_table):
    if not filter_set:
        return []
    try:
        cursor.execute(f"SELECT {', '.join(columns)} FROM dbo.{table_name}")
    except pyodbc.Error:
        connection.rollback()
        return []
    retained = []
    for r in cursor.fetchall():
        row = dict(zip(columns, r))
        if is_gap_table and row.get("gap_reason") == "missing_metadata_target":
            continue  # always recomputed fresh above, never worth retaining stale
        if target_key(row.get("source_server", ""), row.get("source_database", "")) not in queried_target_keys:
            retained.append(row)
    return retained


def replace_table(table_name, columns, rows):
    cursor.execute(f"IF OBJECT_ID('dbo.{table_name}', 'U') IS NOT NULL DROP TABLE dbo.{table_name};")
    column_defs = ", ".join(f"[{c}] VARCHAR(8000)" for c in columns)
    cursor.execute(f"CREATE TABLE dbo.{table_name} ({column_defs});")
    connection.commit()
    if rows:
        placeholders = ", ".join("?" for _ in columns)
        insert_sql = f"INSERT INTO dbo.{table_name} ({', '.join(f'[{c}]' for c in columns)}) VALUES ({placeholders})"
        cursor.fast_executemany = True
        cursor.executemany(insert_sql, [[truncate_value(row.get(c, "")) for c in columns] for row in rows])
        connection.commit()
    print(f"dbo.{table_name}: {len(rows)} row(s) written.")


retained_evidence = retain_outside_queried_targets("bronze_source_object_type_metadata_evidence", EVIDENCE_COLUMNS, is_gap_table=False)
retained_gaps = retain_outside_queried_targets("bronze_source_object_type_metadata_gaps", GAP_COLUMNS, is_gap_table=True)

replace_table("bronze_source_object_type_metadata_evidence", EVIDENCE_COLUMNS, retained_evidence + evidence_rows)
replace_table("bronze_source_object_type_metadata_gaps", GAP_COLUMNS, retained_gaps + gap_rows)

connection.close()
print("Done.")
