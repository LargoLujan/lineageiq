# NB_Discover_Semantic_Model_Lineage
#
# Source for a Fabric Python notebook -- fifth step of the native
# discovery pipeline (see docs/105_fabric_native_discovery_setup.md).
# Each "# %%" block is a cell -- paste them in order.
#
# Faithful replica of scripts/09_enrich_semantic_model_views.ps1: downloads the
# TMDL of each semantic model (getDefinition?format=TMDL, async LRO) and
# extracts the real tables/views/native queries behind each table of the
# model -- the shared connection (Sql.Database(server, database), almost
# always in a single definition/expressions.tmdl file) plus the
# Schema/Item navigation of each table, and optionally embedded native SQL
# (Value.NativeQuery, Odbc.Query, etc.) when the text really
# looks like it contains a query.
#
# Writes to dbo.bronze_semantic_model_view_candidates (13 columns) --
# the same table that scripts/67_upload_bronze_to_warehouse.ps1 already uploads from
# local.
#
# Deliberate difference from the original, documented:
# - The workspace filter of 09 is a SINGLE exact name (`-eq`, "used
#   by the per-workspace scan button"), not a `;`-separated list
#   like the rest of the notebooks -- it is replicated as is, not
#   "fixed". If WorkspaceNameFilter carries several names, only the first
#   one is used (same behavior that passing a list to the original `-eq`
#   would have given: exact comparison against the whole string, so in
#   practice only an exact match of a single name works).
# - The original's "full tenant" mode prioritizes the MaxModels=80
#   models with the most sources/reports, using analysis/semantic_model_
#   lineage_summary.csv (output of scripts/08_build_semantic_lineage.ps1,
#   already migrated to native SQL in warehouse_sql/08_build_semantic_lineage.sql
#   but with a derived table schema that has not been verified here).
#   This version simplifies: it processes ALL the discovered semantic
#   models, without that ranking (MAX_MODELS = 0 by default = no
#   limit) -- reasonable given that the F-SKU capacity has plenty of
#   headroom; set a number on MAX_MODELS if you prefer to bound a first
#   test run.
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
import requests

FABRIC_API_BASE_URL = "https://api.fabric.microsoft.com/v1"

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"
# No longer read from Key Vault (blocked) NOR from a pipeline parameter
# (tested 2026-08-12: it leaked the value in plain text when the
# type conversion failed -- never again that way). Private file in the
# Files area of the workspace Lakehouse, read with notebookutils.fs.head() --
# governed by the SP's Fabric role on this workspace, not by Azure RBAC
# on a separate resource.
ONELAKE_WORKSPACE_NAME = "<your-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<your-onelake-lakehouse>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"
WAREHOUSE_SQL_ENDPOINT = "<your-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<WarehouseName>"

REQUEST_DELAY_SECONDS = 0.35
RETRY_COUNT = 5
MAX_OPERATION_POLLS = 12
MAX_OPERATION_DELAY_SECONDS = 8
MAX_MODELS = 0  # 0 = no limit; see the header note about the simplified ranking.

CANDIDATE_COLUMNS = [
    "workspace_name", "workspace_environment", "semantic_model_name", "semantic_model_qualified_name",
    "semantic_table", "source_server", "database_name", "schema_name", "object_name", "object_type",
    "definition_path", "confidence", "evidence",
]

# %% [markdown]
# ## Parameters
# Mark this cell as a parameters cell in Fabric. Unlike the
# other notebooks, here WorkspaceNameFilter is A SINGLE exact name (or
# empty to process all the models) -- see the file header.

# %%
WorkspaceNameFilter = ""

# %% [markdown]
# ## Authentication and Warehouse (same pattern as the previous notebooks)

# %%
def get_client_secret():
    onelake_path = (
        f"abfss://{ONELAKE_WORKSPACE_NAME}@onelake.dfs.fabric.microsoft.com/"
        f"{ONELAKE_LAKEHOUSE_NAME}.Lakehouse/{SP_SECRET_ONELAKE_PATH}"
    )
    return notebookutils.fs.head(onelake_path, 200).strip()


def acquire_token(scope):
    app = msal.ConfidentialClientApplication(
        SP_CLIENT_ID,
        authority=f"https://login.microsoftonline.com/{SP_TENANT_ID}",
        client_credential=get_client_secret(),
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
    # driver major version as a local dev machine (confirmed live,
    # 2026-08-11: "ODBC Driver 17 for SQL Server" -- file not found).
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


def limit_text(text, max_length=1200):
    if not text:
        return ""
    clean = re.sub(r"\s+", " ", text).strip()
    return clean if len(clean) <= max_length else clean[: max_length - 3] + "..."


# %% [markdown]
# ## Fabric REST: getDefinition?format=TMDL with LRO polling

# %%
def fabric_request(method, path, headers, retry_count=RETRY_COUNT):
    url = path if path.startswith("http") else f"{FABRIC_API_BASE_URL}/{path.lstrip('/')}"
    for attempt in range(retry_count + 1):
        try:
            response = requests.request(method, url, headers=headers, timeout=120)
        except requests.exceptions.RequestException as exc:
            if attempt < retry_count:
                time.sleep(min(90, 2 ** (attempt + 1)))
                continue
            return {"ok": False, "status_code": None, "error": f"{type(exc).__name__}: {exc}", "payload": None}
        if response.status_code == 429 and attempt < retry_count:
            time.sleep(min(90, 2 ** (attempt + 1)))
            continue
        if REQUEST_DELAY_SECONDS:
            time.sleep(REQUEST_DELAY_SECONDS)
        return response
    return response


def get_semantic_model_definition(workspace_id, model_id, headers):
    path = f"workspaces/{workspace_id}/semanticModels/{model_id}/getDefinition?format=TMDL"
    response = fabric_request("POST", path, headers)
    if response.status_code == 200:
        return {"ok": True, "payload": response.json(), "error": ""}
    if response.status_code != 202:
        return {"ok": False, "payload": None, "error": f"{response.status_code} {response.text[:300]}"}

    operation_id = response.headers.get("x-ms-operation-id")
    if not operation_id:
        match = re.search(r"[0-9a-fA-F-]{36}", response.headers.get("Location", ""))
        operation_id = match.group(0) if match else None
    if not operation_id:
        return {"ok": False, "payload": None, "error": "LRO accepted but no operation id was returned."}

    for _poll in range(MAX_OPERATION_POLLS):
        retry_after = response.headers.get("Retry-After")
        delay_seconds = int(retry_after) if (retry_after or "").isdigit() else 2
        time.sleep(min(delay_seconds, MAX_OPERATION_DELAY_SECONDS) if MAX_OPERATION_DELAY_SECONDS else delay_seconds)

        state_response = fabric_request("GET", f"operations/{operation_id}", headers)
        if state_response.status_code >= 400:
            return {"ok": False, "payload": None, "error": f"{state_response.status_code} {state_response.text[:300]}"}
        state_payload = state_response.json()
        status = state_payload.get("status", "")

        if status == "Succeeded":
            result_response = fabric_request("GET", f"operations/{operation_id}/result", headers)
            if result_response.status_code >= 400:
                return {"ok": False, "payload": None, "error": f"{result_response.status_code} {result_response.text[:300]}"}
            return {"ok": True, "payload": result_response.json(), "error": ""}
        if status == "Failed":
            return {"ok": False, "payload": None, "error": f"LRO failed. {state_payload}"}
        response = state_response

    return {"ok": False, "payload": None, "error": f"LRO did not complete after {MAX_OPERATION_POLLS} polls."}


def decode_definition_parts(definition_payload):
    parts = []
    if not definition_payload:
        return parts
    for part in (definition_payload.get("definition") or {}).get("parts", []):
        if part.get("payloadType") != "InlineBase64" or not part.get("payload"):
            continue
        try:
            import base64
            padded = part["payload"].strip()
            padded += "=" * (-len(padded) % 4)
            text = base64.b64decode(padded).decode("utf-8", errors="replace")
        except Exception:  # noqa: BLE001
            text = ""
        parts.append({"path": part.get("path", ""), "text": text})
    return parts


# %% [markdown]
# ## TMDL parsers: table by path, native query context, noise filters

# %%
def table_name_from_path(path):
    if not path:
        return ""
    file_name = path.rsplit("/", 1)[-1]
    return re.sub(r"\.tmdl$", "", file_name)


def normalize_native_identifier_part(value):
    if not value:
        return ""
    clean = value.strip()
    match = re.match(r'^#"(.*)"$', clean)
    if match:
        clean = match.group(1)
    clean = re.sub(r'^[\[\]"`]+', "", clean)
    clean = re.sub(r'[\[\]"`]+$', "", clean)
    return clean.strip()


def test_native_sql_parse_scope(definition_path, text):
    if not text:
        return False
    if definition_path.startswith("definition/cultures/"):
        return False
    return bool(re.search(
        r"(?is:\b(Sql\.Database|Value\.NativeQuery|Odbc\.Query|OleDb\.Query|OleDb\.DataSource|"
        r"Query\s*=|CommandText\s*=|select\s+.+?\s+from|with\s+\w+\s+as)\b)", text,
    ))


def test_native_match_context(text, index):
    start = max(0, index - 350)
    context = text[start:index]
    return bool(re.search(
        r"(?is:select\s+|with\s+\w+\s+as|value\.nativequery|query\s*=|commandtext\s*=|exec(?:ute)?\s+|call\s+)", context,
    ))


_BLOCKED_NATIVE_WORDS = {
    "a", "an", "and", "as", "by", "case", "call", "cast", "else", "end", "exec", "execute",
    "for", "formula", "from", "full", "if", "in", "inner", "join", "left", "meeting",
    "on", "or", "outer", "real", "received", "red", "right", "scatterplot", "select",
    "supplementary", "the", "then", "when", "where", "with",
}


def test_native_object_candidate(object_name, schema_name):
    if not object_name:
        return False
    clean = object_name.strip()
    if not clean or len(clean) < 2 or "#" in clean:
        return False
    if clean.lower() in _BLOCKED_NATIVE_WORDS:
        return False
    if not schema_name and re.match(r"^[a-z]{1,3}$", clean):  # case-sensitive on purpose, matches -cmatch
        return False
    return True


_SQL_DATABASE_PATTERN = re.compile(r'(?i:Sql\.Database\(\s*"([^"]+)"\s*,\s*"([^"]+)")')
_SCHEMA_ITEM_PATTERN = re.compile(r'(?i:\[\s*Schema\s*=\s*"([^"]+)"\s*,\s*Item\s*=\s*"([^"]+)"(?P<tail>[^\]]*)\])')
_KIND_PATTERN = re.compile(r'(?i:Kind\s*=\s*"([^"]+)")')
_NATIVE_QUERY_PATTERN = re.compile(
    r'(?is)\b(from|join|exec(?:ute)?|call)\s+'
    r'((?:\[[^\]]+\]|"[^"]+"|`[^`]+`|[A-Za-z_][A-Za-z0-9_$#-]*)(?:\s*\.\s*(?:\[[^\]]+\]|"[^"]+"|`[^`]+`|[A-Za-z_][A-Za-z0-9_$#-]*)){0,2})'
)


# %% [markdown]
# ## Candidate registration (Add-ObjectCandidate)

# %%
def add_object_candidate(rows, seen, model, definition_path, semantic_table, server, database,
                          schema, object_name, object_type, evidence, confidence):
    if not object_name and not database:
        return
    key = "|".join((model["qualified_name"], definition_path, server, database, schema, object_name, object_type))
    if key in seen:
        return
    seen.add(key)
    rows.append({
        "workspace_name": model["workspace_name"],
        "workspace_environment": model.get("workspace_environment", ""),
        "semantic_model_name": model["item_name"],
        "semantic_model_qualified_name": model["qualified_name"],
        "semantic_table": semantic_table,
        "source_server": server,
        "database_name": database,
        "schema_name": schema,
        "object_name": object_name,
        "object_type": object_type,
        "definition_path": definition_path,
        "confidence": confidence,
        "evidence": limit_text(evidence, 1200),
    })


def extract_view_candidates_for_model(rows, seen, model, parts):
    # Most models declare their connection ONCE in a shared expression
    # (definition/expressions.tmdl) and every per-table part just
    # references it via Source{[Schema=...,Item=...]} -- parts are NOT
    # guaranteed to arrive in an order that puts expressions.tmdl first,
    # so this pre-scans all parts for the first Sql.Database(...) match to
    # use as a model-wide fallback (only when a given part has no local
    # match of its own), faithfully replicating the original's pre-scan.
    model_server, model_database = "", ""
    for part in parts:
        if not part["text"]:
            continue
        match = _SQL_DATABASE_PATTERN.search(part["text"])
        if match:
            model_server, model_database = match.group(1), match.group(2)
            break

    for part in parts:
        if not part["text"]:
            continue
        semantic_table = table_name_from_path(part["path"])
        server, database = "", ""
        sql_match = _SQL_DATABASE_PATTERN.search(part["text"])
        if sql_match:
            server, database = sql_match.group(1), sql_match.group(2)
            add_object_candidate(rows, seen, model, part["path"], semantic_table, server, database, "", "",
                                 "database", "TMDL part references Sql.Database server/database.", "confirmed")
        effective_server = server or model_server
        effective_database = database or model_database

        for match in _SCHEMA_ITEM_PATTERN.finditer(part["text"]):
            kind_match = _KIND_PATTERN.search(match.group("tail") or "")
            kind = kind_match.group(1).lower() if kind_match else ""
            object_type = "table" if kind == "table" else ("view" if kind == "view" else "table_or_view")
            evidence = f"TMDL M expression contains Source{{[Schema=...,Item=...,Kind={kind}]}} lookup." if kind else "TMDL M expression contains Source{[Schema=...,Item=...]} lookup."
            if not server and model_server:
                evidence += " Server/database inferred from this model's shared connection expression."
            add_object_candidate(rows, seen, model, part["path"], semantic_table, effective_server, effective_database,
                                 match.group(1), match.group(2), object_type, evidence, "confirmed")

        if test_native_sql_parse_scope(part["path"], part["text"]):
            for match in _NATIVE_QUERY_PATTERN.finditer(part["text"]):
                if not test_native_match_context(part["text"], match.start()):
                    continue
                verb = re.sub(r"\s+", " ", match.group(1)).lower()
                raw = match.group(2).strip()
                if not raw or raw.startswith("("):
                    continue
                segments = [normalize_native_identifier_part(s) for s in raw.split(".")]
                segments = [s for s in segments if s]
                schema, object_name = "", ""
                if len(segments) == 1:
                    object_name = segments[0]
                elif len(segments) >= 2:
                    schema, object_name = segments[-2], segments[-1]
                if test_native_object_candidate(object_name, schema):
                    native_object_type = "stored_procedure" if re.search(r"exec|call", verb) else "native_query_object"
                    native_evidence = (
                        "TMDL M/native query text contains EXEC/CALL stored procedure reference."
                        if native_object_type == "stored_procedure"
                        else "TMDL M/native query text contains FROM/JOIN object reference."
                    )
                    add_object_candidate(rows, seen, model, part["path"], semantic_table, effective_server, effective_database,
                                         schema, object_name, native_object_type, native_evidence, "likely")


# %% [markdown]
# ## Cargar workspaces + items (dbo.bronze_workspaces / dbo.bronze_items)

# %%
connection = connect_warehouse()
cursor = connection.cursor()
cursor.execute("SELECT workspace_name, technical_id FROM dbo.bronze_workspaces")
workspace_id_by_name = {row[0]: row[1] for row in cursor.fetchall()}

cursor.execute(
    "SELECT workspace_name, workspace_environment, item_type, item_name, qualified_name, technical_id "
    "FROM dbo.bronze_items WHERE status = 'discovered' AND item_type = 'SemanticModel'"
)
all_models = [
    {"workspace_name": r[0], "workspace_environment": r[1], "item_type": r[2], "item_name": r[3], "qualified_name": r[4], "technical_id": r[5]}
    for r in cursor.fetchall()
]
if not all_models:
    raise RuntimeError("No discovered SemanticModel rows in dbo.bronze_items -- run NB_Discover_Workspaces_Items first.")

# Single-exact-name filter, faithfully matching the original's `-eq`
# (see the module docstring) -- NOT a semicolon-list like every other
# notebook here.
target_workspace_name = (WorkspaceNameFilter or "").strip()
if target_workspace_name:
    target_models = [m for m in all_models if m["workspace_name"] == target_workspace_name]
else:
    target_models = sorted(all_models, key=lambda m: m["qualified_name"])
    if MAX_MODELS > 0:
        target_models = target_models[:MAX_MODELS]
print(f"Target semantic models: {len(target_models)} ({'workspace: ' + target_workspace_name if target_workspace_name else 'full tenant'})")

# %% [markdown]
# ## Run: getDefinition?format=TMDL + parsing, per model

# %%
fabric_token = acquire_token("https://api.fabric.microsoft.com/.default")
fabric_headers = {"Authorization": f"Bearer {fabric_token}", "Content-Type": "application/json"}

rows = []
seen = set()
success_count = 0
processed = 0

for model in target_models:
    processed += 1
    if processed % 10 == 0:
        print(f"Processed {processed} / {len(target_models)} semantic model definitions...")
        fabric_token = acquire_token("https://api.fabric.microsoft.com/.default")
        fabric_headers["Authorization"] = f"Bearer {fabric_token}"

    workspace_id = workspace_id_by_name.get(model["workspace_name"], "")
    if not workspace_id:
        continue
    result = get_semantic_model_definition(workspace_id, model["technical_id"], fabric_headers)
    if not result["ok"]:
        continue
    success_count += 1
    parts = decode_definition_parts(result["payload"])
    try:
        extract_view_candidates_for_model(rows, seen, model, parts)
    except Exception as exc:  # noqa: BLE001 - one malformed model must not abort the whole run
        print(f"[semantic-model-lineage] Skipped '{model['qualified_name']}': {exc}")

print(f"Definitions succeeded: {success_count} / {len(target_models)}. Source candidates: {len(rows)}.")

# %% [markdown]
# ## Write to the Warehouse, keeping what belongs to other workspaces
# when WorkspaceNameFilter has a value

# %%
# Reconnect with a fresh database token -- the connection above
# has been open since before the per-semantic-model loop (the whole
# tenant by default, MAX_MODELS=0 = no limit), the same pattern that
# already caused a real connection failure ("TCP Provider: Error code 0x20") in
# NB_Discover_Dependencies.py -- same fix applied here preventively.
connection.close()
connection = connect_warehouse()
cursor = connection.cursor()

retained_rows = []
if target_workspace_name:
    try:
        cursor.execute(f"SELECT {', '.join(CANDIDATE_COLUMNS)} FROM dbo.bronze_semantic_model_view_candidates")
        retained_rows = [dict(zip(CANDIDATE_COLUMNS, r)) for r in cursor.fetchall() if r[0] != target_workspace_name]
    except pyodbc.Error:
        connection.rollback()  # table doesn't exist yet -- nothing to retain

final_rows = retained_rows + rows

cursor.execute("IF OBJECT_ID('dbo.bronze_semantic_model_view_candidates', 'U') IS NOT NULL DROP TABLE dbo.bronze_semantic_model_view_candidates;")
column_defs = ", ".join(f"[{c}] VARCHAR(8000)" for c in CANDIDATE_COLUMNS)
cursor.execute(f"CREATE TABLE dbo.bronze_semantic_model_view_candidates ({column_defs});")
connection.commit()
if final_rows:
    placeholders = ", ".join("?" for _ in CANDIDATE_COLUMNS)
    insert_sql = f"INSERT INTO dbo.bronze_semantic_model_view_candidates ({', '.join(f'[{c}]' for c in CANDIDATE_COLUMNS)}) VALUES ({placeholders})"
    cursor.fast_executemany = True
    cursor.executemany(insert_sql, [[truncate_value(row.get(c, "")) for c in CANDIDATE_COLUMNS] for row in final_rows])
    connection.commit()

connection.close()
print(f"dbo.bronze_semantic_model_view_candidates: {len(final_rows)} row(s) written ({len(retained_rows)} retained, {len(rows)} freshly computed).")
print("Done.")
