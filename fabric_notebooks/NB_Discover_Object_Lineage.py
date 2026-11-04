# NB_Discover_Object_Lineage
#
# Source for a Fabric Python notebook -- third step of the native
# discovery pipeline, after NB_Discover_Workspaces_Items and
# NB_Discover_Dependencies (see docs/105_fabric_native_discovery_setup.md).
# Each "# %%" block is a cell -- paste them in order.
#
# Faithful replica of scripts/18_extract_item_object_lineage.ps1: unlike
# NB_Discover_Dependencies (item<->item lineage by GUID match), this one
# extracts item->EXTERNAL OBJECT lineage (which table/view/
# stored procedure/file each Notebook, CopyJob,
# Dataflow, Eventstream, KQLQueryset, Reflex, UserDataFunction, GraphQLApi
# or DataAgent reads or writes), by really parsing the text/JSON content of each
# definition type -- no AI/LLM, only regular expressions and structured
# JSON traversals (same as the original: see its header and the
# comments of each type-specific parser).
#
# Writes to dbo.bronze_item_object_lineage_candidates -- the same table and
# columns (17) that scripts/67_upload_bronze_to_warehouse.ps1 already uploads from
# analysis/item_object_lineage_candidates.csv.
#
# Deliberately NOT included (same scope as 18): confirming the exact
# TYPE of each object against a real external SQL catalog
# (scripts/20_extract_source_object_type_metadata.ps1 and related) -- those
# candidates stay as "likely"/"table_or_view" unconfirmed, same as
# locally until someone reviews them or the external catalog cross-checks them.
# This is reachable in principle (same mechanics: open a SQL connection
# with pyodbc, as warehouse.py already does), but it requires the external SQL server
# to be reachable over the network from the Fabric runtime (VNet/gateway/
# firewall rules) -- a tenant infrastructure question, not a code one,
# so it has not been attempted here.
#
# Self-contained on purpose, same criterion as NB_Discover_Dependencies.

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

import json
import re
import struct
import time
import requests

FABRIC_API_BASE_URL = "https://api.fabric.microsoft.com/v1"

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"
# No longer read from Key Vault (blocked) NOR from a pipeline parameter
# (tested: it leaked the value in plain text when the
# type conversion failed -- never again that way). Private file in the
# Files area of the workspace Lakehouse, read with notebookutils.fs.head() --
# governed by the SP's Fabric role on this workspace, not by Azure RBAC
# on a separate resource.
ONELAKE_WORKSPACE_NAME = "<your-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<your-onelake-lakehouse>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"
WAREHOUSE_SQL_ENDPOINT = "<your-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<WarehouseName>"

REQUEST_DELAY_SECONDS = 0.25
RETRY_COUNT = 5
MAX_OPERATION_POLLS = 20
MAX_OPERATION_DELAY_SECONDS = 15

# Same set as $ItemTypes in 18_extract_item_object_lineage.ps1.
# Warehouse and VariableLibrary are excluded on purpose -- see the header of
# that script: Warehouse has no definition format to read, and
# VariableLibrary has no object lineage of its own.
ITEM_TYPES = {
    "Notebook", "CopyJob", "Dataflow", "Eventstream", "KQLQueryset",
    "Reflex", "UserDataFunction", "GraphQLApi", "DataAgent",
}

CANDIDATE_COLUMNS = [
    "workspace_name", "workspace_environment", "item_type", "item_name", "item_qualified_name",
    "source_type", "source_name", "source_qualified_name", "source_server", "source_database",
    "schema_name", "object_name", "object_type", "usage_type", "confidence", "definition_path", "evidence",
]

# %% [markdown]
# ## Parameters
# Mark this cell as a parameters cell in Fabric.

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


def limit_text(text, max_length=1200):
    if not text:
        return ""
    clean = re.sub(r"\s+", " ", text).strip()
    return clean if len(clean) <= max_length else clean[: max_length - 3] + "..."


def normalize_key(value):
    return re.sub(r"\s+", " ", (value or "").strip().lower())


# %% [markdown]
# ## Fabric REST: pagination, retry, and the same getDefinition LRO polling

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


def get_item_definition(workspace_id, item_id, item_type, headers):
    path = f"workspaces/{workspace_id}/items/{item_id}/getDefinition"
    if item_type == "Notebook":
        path += "?format=fabricGitSource"
    response = fabric_request("POST", path, headers)

    if response.status_code == 200:
        return {"ok": True, "payload": response.json(), "error": "", "status_code": 200}
    if response.status_code != 202:
        return {"ok": False, "payload": None, "error": f"{response.status_code} {response.text[:300]}", "status_code": response.status_code}

    operation_id = response.headers.get("x-ms-operation-id")
    if not operation_id:
        match = re.search(r"[0-9a-fA-F-]{36}", response.headers.get("Location", ""))
        operation_id = match.group(0) if match else None
    if not operation_id:
        return {"ok": False, "payload": None, "error": "LRO accepted but no operation id was returned.", "status_code": 202}

    for _poll in range(MAX_OPERATION_POLLS):
        retry_after = response.headers.get("Retry-After")
        delay_seconds = int(retry_after) if (retry_after or "").isdigit() else 2
        time.sleep(min(delay_seconds, MAX_OPERATION_DELAY_SECONDS) if MAX_OPERATION_DELAY_SECONDS else delay_seconds)

        state_response = fabric_request("GET", f"operations/{operation_id}", headers)
        if state_response.status_code >= 400:
            return {"ok": False, "payload": None, "error": f"{state_response.status_code} {state_response.text[:300]}", "status_code": state_response.status_code}
        state_payload = state_response.json()
        status = state_payload.get("status", "")

        if status == "Succeeded":
            result_response = fabric_request("GET", f"operations/{operation_id}/result", headers)
            if result_response.status_code >= 400:
                return {"ok": False, "payload": None, "error": f"{result_response.status_code} {result_response.text[:300]}", "status_code": result_response.status_code}
            return {"ok": True, "payload": result_response.json(), "error": "", "status_code": result_response.status_code}
        if status == "Failed":
            return {"ok": False, "payload": None, "error": f"LRO failed. {state_payload}", "status_code": state_response.status_code}
        response = state_response

    return {"ok": False, "payload": None, "error": f"LRO did not complete after {MAX_OPERATION_POLLS} polls.", "status_code": 202}


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
        except Exception:  # noqa: BLE001 - a single malformed part must not abort the item
            text = ""
        parts.append({"path": part.get("path", ""), "text": text})
    return parts


# %% [markdown]
# ## Object identifier helpers (Split-ObjectIdentifier / Test-ObjectIdentifierNoise / Get-ContextUsage / Find-FirstJsonStringValue)

# %%
_NOISE_WORDS = re.compile(r"^(?i:select|with|where|join|from|on|and|or|as)$")
_NOISE_LITERALS = re.compile(r"^(?i:delta|overwrite|append|parquet|csv|json|text|true|false|none|null|default)$")
_NOISE_URLS = re.compile(
    r"(?i:^https?://(?:developer\.microsoft\.com|[^/]+\.vault\.azure\.net|[^/]*pkgs\.dev\.azure\.com|"
    r"analysis\.windows\.net|api\.fabric\.microsoft\.com|storage\.azure\.com|"
    r"login\.microsoftonline\.com|login\.windows\.net|graph\.microsoft\.com|"
    r"[^/]+\.database\.windows\.net|management\.azure\.com|api\.powerbi\.com)(?:/|$))"
)

# External URLs (SaaS forms, CRM, SharePoint sites...)
# used to collapse into a single generic "File" node in the graph because
# source_database was left empty -- build_graph_map_index groups by
# source_type+server+database, and with all three equal (empty) for
# many different rows, they all fell into the same bucket. Now the
# real host is extracted as source_database, and internal OneLake paths
# (abfss://...@onelake.dfs.fabric.microsoft.com/...) are reclassified
# as "Fabric" instead of "File" -- they are Fabric's own storage, not a real
# external source.
_ONELAKE_HOST_PATTERN = re.compile(r"(?i:onelake\.(?:dfs|blob)\.fabric\.microsoft\.com$)")


def extract_url_host(url):
    match = re.match(r"(?i:^\w+://([^/]+))", url)
    if not match:
        return ""
    host = match.group(1)
    if "@" in host:
        host = host.split("@", 1)[1]
    return host.lower()


def test_object_identifier_noise(value):
    if not value:
        return True
    clean = re.sub(r"\s+", " ", value).strip()
    if not clean:
        return True
    if re.search(r"(?i:\bimport\b)", clean):
        return True
    if _NOISE_WORDS.match(clean) or _NOISE_LITERALS.match(clean):
        return True
    if _NOISE_URLS.match(clean):
        return True
    return False


def split_object_identifier(identifier):
    if not identifier:
        return None
    clean = re.sub(r"[`\[\]\"']", "", identifier).strip()
    clean = re.sub(r"\\+", "/", clean).strip("/")
    if test_object_identifier_noise(clean):
        return None
    if re.match(r"(?i:^(http|https|abfss|wasbs|s3)://)", clean):
        host = extract_url_host(clean)
        if _ONELAKE_HOST_PATTERN.search(host):
            return {"source_database": "", "schema_name": "", "object_name": clean, "source_type": "Fabric", "object_type": "file"}
        return {"source_database": host, "schema_name": "", "object_name": clean, "source_type": "File", "object_type": "file"}
    if re.match(r"(?i:^(Files|Tables|Lakehouse|Warehouse)/(.+)$)", clean):
        return {"source_database": "", "schema_name": "", "object_name": clean, "source_type": "Fabric", "object_type": "file"}
    segments = [s for s in clean.split(".") if s]
    if len(segments) == 1:
        return {"source_database": "", "schema_name": "", "object_name": segments[0], "source_type": "", "object_type": "table_or_view"}
    if len(segments) == 2:
        return {"source_database": "", "schema_name": segments[0], "object_name": segments[1], "source_type": "", "object_type": "table_or_view"}
    return {"source_database": segments[0], "schema_name": segments[-2], "object_name": segments[-1], "source_type": "", "object_type": "table_or_view"}


def get_context_usage(text, index, default_usage):
    start = max(0, index - 320)
    context = text[start:start + 640]
    if re.search(r"(?i:sink|destination|target|write|saveAsTable|writeTo|output)", context):
        return "writes_to"
    if re.search(r"(?i:storedProcedure|procedure|exec|call)", context):
        return "executes"
    if re.search(r"(?i:source|input|read|from|join|dbtable|query)", context):
        return "reads_from"
    return default_usage


def find_first_json_string_value(node, names, max_depth=6):
    if max_depth <= 0 or node is None or isinstance(node, str):
        return ""
    if isinstance(node, list):
        for item in node:
            found = find_first_json_string_value(item, names, max_depth - 1)
            if found:
                return found
        return ""
    if isinstance(node, dict):
        for name in names:
            value = node.get(name)
            if isinstance(value, str) and value:
                return value
        for value in node.values():
            found = find_first_json_string_value(value, names, max_depth - 1)
            if found:
                return found
    return ""


# %% [markdown]
# ## Candidate registration (Add-Candidate: dedup + final row)

# %%
def add_candidate(rows, seen, item, object_parts, definition_path, usage_type, object_type,
                   source_type, source_server, source_database, evidence, confidence):
    if not object_parts or not object_parts.get("object_name"):
        return
    final_source_type = source_type or object_parts.get("source_type") or "FabricOrSQL"
    final_database = source_database or object_parts.get("source_database", "")
    final_object_type = object_type or object_parts.get("object_type") or "table_or_view"
    key = "|".join(normalize_key(v) for v in (
        item["qualified_name"], definition_path, final_source_type, source_server,
        final_database, object_parts.get("schema_name", ""), object_parts["object_name"],
        usage_type, final_object_type,
    ))
    if key in seen:
        return
    seen.add(key)
    rows.append({
        "workspace_name": item["workspace_name"],
        "workspace_environment": item.get("workspace_environment", ""),
        "item_type": item["item_type"],
        "item_name": item["item_name"],
        "item_qualified_name": item["qualified_name"],
        "source_type": final_source_type,
        "source_name": final_database or final_source_type,
        "source_qualified_name": "",
        "source_server": source_server or "",
        "source_database": final_database,
        "schema_name": object_parts.get("schema_name", ""),
        "object_name": object_parts["object_name"],
        "object_type": final_object_type,
        "usage_type": usage_type,
        "confidence": confidence,
        "definition_path": definition_path,
        "evidence": limit_text(evidence, 1200),
    })


# %% [markdown]
# ## Generic parsers: text patterns and embedded SQL (Add-StringPatternCandidates / Add-SqlObjectCandidates / Add-EmbeddedSqlCandidates)

# %%
_STRING_PATTERNS = [
    {"regex": r'(?is)\b(?:spark\.read\.table|read\.table|table|saveAsTable|writeTo|DeltaTable\.forName)\s*\(\s*["\']([^"\']+)["\']',
     "value_group": 1, "usage": "reads_from", "type": "table_or_view", "evidence": "Notebook/table API references object."},
    {"regex": r'(?is)\b(?:option|set)\s*\(\s*["\'](?:dbtable|tableName|table|schemaTable)["\']\s*,\s*["\']([^"\']+)["\']',
     "value_group": 1, "usage": "reads_from", "type": "table_or_view", "evidence": "Definition option references table object."},
    {"regex": r'(?is)\b(?:option|set)\s*\(\s*["\'](?:query|sqlQuery)["\']\s*,\s*["\']([^"\']+)["\']',
     "value_group": 1, "usage": "reads_from", "type": "native_query_object", "evidence": "Definition option contains SQL query text."},
    {"regex": r'(?is)["\']((?:abfss|https?|wasbs|s3)://[^"\']+)["\']',
     "value_group": 1, "usage": "reads_from", "type": "file", "evidence": "Definition references external file/path."},
    # "sp" as a bare alternative used to match almost anything containing
    # those letters in sequence ("workSPaceId", "reSPonse") -- table/view/
    # procedure only, same fix already applied in the PowerShell original.
    {"regex": r'(?is)\b([A-Za-z0-9_]*(?:table|view|procedure|stored_procedure)[A-Za-z0-9_]*)\s*=\s*["\']([^"\']+)["\']',
     "value_group": 2, "variable_group": 1, "usage": "reads_from", "type": "table_or_view", "evidence": "Notebook/object variable references object."},
]

_SQL_KEYWORD_PATTERN = re.compile(
    r'(?is)\b(from|join|into|update|merge\s+into|delete\s+from|exec(?:ute)?|call)\s+'
    r'((?:\[[^\]]+\]|"[^"]+"|`[^`]+`|[A-Za-z_][A-Za-z0-9_$#-]*)(?:\s*\.\s*(?:\[[^\]]+\]|"[^"]+"|`[^`]+`|[A-Za-z_][A-Za-z0-9_$#-]*)){0,2})'
)


def add_sql_object_candidates(rows, seen, item, path, sql_text, default_usage, evidence):
    if not sql_text:
        return
    for match in _SQL_KEYWORD_PATTERN.finditer(sql_text):
        line_start = sql_text.rfind("\n", 0, match.start())
        line_start = 0 if line_start < 0 else line_start + 1
        line_end = sql_text.find("\n", match.start())
        line_end = len(sql_text) if line_end < 0 else line_end
        line = sql_text[line_start:line_end]
        if re.match(r"(?i:^\s*from\s+[A-Za-z0-9_.]+\s+import\b)", line):
            continue

        verb = re.sub(r"\s+", " ", match.group(1)).lower()
        identifier = match.group(2).strip()
        parts = split_object_identifier(identifier)
        if not parts:
            continue
        if re.search(r"into|update|merge|delete", verb):
            usage, object_type = "writes_to", "native_query_object"
        elif re.search(r"exec|call", verb):
            usage, object_type = "executes", "stored_procedure"
        else:
            usage, object_type = "reads_from", "native_query_object"
        add_candidate(rows, seen, item, parts, path, usage, object_type, "", "", "",
                      f"{evidence} SQL keyword '{verb}' references object in '{path}'.", "likely")


def add_string_pattern_candidates(rows, seen, item, path, text):
    for pattern in _STRING_PATTERNS:
        for match in re.finditer(pattern["regex"], text):
            value = match.group(pattern["value_group"])
            if pattern["type"] == "native_query_object":
                add_sql_object_candidates(rows, seen, item, path, value, pattern["usage"], pattern["evidence"])
                continue
            parts = split_object_identifier(value)
            usage = "writes_to" if re.search(r"(?i:saveAsTable|writeTo)", match.group(0)) else get_context_usage(text, match.start(), pattern["usage"])
            object_type = pattern["type"]
            variable_name = match.group(pattern["variable_group"]) if "variable_group" in pattern else ""
            if pattern["evidence"] == "Notebook/object variable references object." and re.search(r"(?i:procedure|stored_procedure|^sp_|_sp$)", variable_name or ""):
                object_type = "stored_procedure"
            if object_type == "stored_procedure":
                usage = "executes"
            add_candidate(rows, seen, item, parts, path, usage, object_type, "", "", "",
                          f"{pattern['evidence']} Path '{path}'.", "likely")


_SQL_STRING_PATTERNS = [
    r'(?is)\b(?:spark|sqlContext|session)\.sql\s*\(\s*(?:"""(.*?)"""|\'\'\'(.*?)\'\'\'|"([^"]+)"|\'([^\']+)\')',
    r'(?is)\b(?:query|sql|sql_text|sql_query|statement)\s*=\s*(?:"""(.*?)"""|\'\'\'(.*?)\'\'\'|"([^"]+)"|\'([^\']+)\')',
    r'(?is)"(?:query|sqlQuery|sourceQuery|sqlStatement)"\s*:\s*"((?:\\.|[^"])*)"',
]


def add_embedded_sql_candidates(rows, seen, item, path, text):
    if not text:
        return
    for pattern in _SQL_STRING_PATTERNS:
        for match in re.finditer(pattern, text):
            value = next((g for g in match.groups() if g), "")
            if value and re.search(r"(?i:\b(select|from|join|exec|execute|call|merge|update|delete|insert\s+into)\b)", value):
                add_sql_object_candidates(rows, seen, item, path, value, "reads_from", "Embedded SQL/query parser")

    lines = re.split(r"\r?\n", text)
    index = 0
    while index < len(lines):
        if not re.match(r"^\s*(?:# MAGIC\s*)?%%?sql\b", lines[index]):
            index += 1
            continue
        buffer = []
        next_index = index + 1
        while next_index < len(lines):
            if re.match(r"^\s*# COMMAND\b", lines[next_index]):
                break
            if re.match(r"(?i:^\s*(?:# MAGIC\s*)?%%?(?:md|python|pyspark|scala|r)\b)", lines[next_index]):
                break
            buffer.append(re.sub(r"^\s*# MAGIC ?", "", lines[next_index]))
            next_index += 1
        sql_block = "\n".join(buffer)
        if re.search(r"(?i:\b(select|from|join|exec|execute|call|merge|update|delete|insert\s+into)\b)", sql_block):
            add_sql_object_candidates(rows, seen, item, path, sql_block, "reads_from", "Notebook SQL magic parser")
        index = next_index


# %% [markdown]
# ## Parser Dataflow (mashup M): Add-MashupObjectCandidates / Get-MashupQueryBlocks

# %%
def get_mashup_query_blocks(text):
    if not text:
        return []
    boundaries = [m.start() for m in re.finditer(r"(?m)^\s*shared\s+", text)]
    if not boundaries:
        return [text]
    blocks = []
    for i, start in enumerate(boundaries):
        end = boundaries[i + 1] if i + 1 < len(boundaries) else len(text)
        blocks.append(text[start:end])
    return blocks


def add_mashup_object_candidates(rows, seen, item, path, text, workspace_name_by_id, lakehouse_name_by_id):
    if not text:
        return
    for block in get_mashup_query_blocks(text):
        sql_database_match = re.search(r'(?i:Sql\.Databases?\(\s*"([^"]+)"\s*(?:,\s*"([^"]+)")?)', block)
        if sql_database_match and sql_database_match.group(2):
            server = sql_database_match.group(1)
            database = sql_database_match.group(2)
            nav_matches = list(re.finditer(r'(?i:\[\s*Schema\s*=\s*"([^"]*)"\s*,\s*Item\s*=\s*"([^"]+)")', block))
            if nav_matches:
                for nav_match in nav_matches:
                    schema, table_name = nav_match.group(1), nav_match.group(2)
                    if test_object_identifier_noise(table_name):
                        continue
                    parts = {"source_database": database, "schema_name": schema, "object_name": table_name, "source_type": "SQL", "object_type": "table_or_view"}
                    add_candidate(rows, seen, item, parts, path, "reads_from", "table_or_view", "SQL", server, database,
                                  f"Dataflow M query reads Schema/Item table via Sql.Database({server}, {database}) in '{path}'.", "confirmed")
            else:
                parts = {"source_database": database, "schema_name": "", "object_name": database, "source_type": "SQL", "object_type": "database"}
                add_candidate(rows, seen, item, parts, path, "reads_from", "database", "SQL", server, database,
                              f"Dataflow M query references Sql.Database server/database (no specific table navigation found in this query) in '{path}'.", "confirmed")
            continue

        if re.search(r"Lakehouse\.Contents\s*\(", block):
            table_match = re.search(r'(?i:\[\s*Id\s*=\s*"([^"]+)"\s*,\s*ItemKind\s*=\s*"Table")', block)
            if table_match:
                table_name = table_match.group(1)
                if not test_object_identifier_noise(table_name):
                    workspace_id_match = re.search(r'(?i:workspaceId\s*=\s*"([^"]+)")', block)
                    lakehouse_id_match = re.search(r'(?i:lakehouseId\s*=\s*"([^"]+)")', block)
                    workspace_id = workspace_id_match.group(1) if workspace_id_match else ""
                    lakehouse_id = lakehouse_id_match.group(1) if lakehouse_id_match else ""
                    workspace_name = workspace_name_by_id.get(workspace_id, workspace_id)
                    lakehouse_name = lakehouse_name_by_id.get(lakehouse_id, lakehouse_id)
                    usage = "writes_to" if re.search(r"(?i:DataDestination)", block) else "reads_from"
                    parts = {"source_database": lakehouse_name, "schema_name": "", "object_name": table_name, "source_type": "Fabric", "object_type": "table_or_view"}
                    add_candidate(rows, seen, item, parts, path, usage, "table_or_view", "Fabric", workspace_name, lakehouse_name,
                                  f"Dataflow M query navigates to Lakehouse table '{table_name}' (workspace '{workspace_name}', lakehouse '{lakehouse_name}') in '{path}'.", "confirmed")


# %% [markdown]
# ## Parsers JSON estructurados: Eventstream / KQL Queryset / Reflex / GraphQL API / Data Agent

# %%
def add_eventstream_object_candidates(rows, seen, item, path, text):
    payload = json.loads(text) if text else None
    if not payload:
        return
    for key, usage in (("sources", "reads_from"), ("destinations", "writes_to")):
        for entry in payload.get(key) or []:
            if not entry:
                continue
            name = entry.get("name", "")
            connector_type = entry.get("type", "")
            if not name:
                continue
            identifier = find_first_json_string_value(entry, ["azureResourceId", "databaseItemName", "workspaceId", "connectionId", "server", "eventHubName", "topicName", "consumerGroup"])
            parts = {"source_database": identifier, "schema_name": "", "object_name": name, "source_type": "Eventstream", "object_type": "connection"}
            add_candidate(rows, seen, item, parts, path, usage, "connection", "Eventstream", connector_type, identifier,
                          f"Eventstream {key} '{name}' (connector type '{connector_type}') in '{path}'.", "confirmed")


def add_kql_queryset_object_candidates(rows, seen, item, path, text):
    payload = json.loads(text) if text else None
    queryset = (payload or {}).get("queryset")
    if not queryset:
        return
    for data_source in queryset.get("dataSources") or []:
        if not data_source:
            continue
        database_name = data_source.get("databaseItemName", "")
        cluster_uri = data_source.get("clusterUri", "")
        if not database_name:
            continue
        db_parts = {"source_database": database_name, "schema_name": "", "object_name": database_name, "source_type": "KQL", "object_type": "database"}
        add_candidate(rows, seen, item, db_parts, path, "reads_from", "database", "KQL", cluster_uri, database_name,
                      f"KQL queryset data source '{database_name}' in '{path}'.", "confirmed")

        for tab in queryset.get("tabs") or []:
            content = tab.get("content", "")
            if not content:
                continue
            table_names = []
            base_match = re.search(r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\r?\n\s*\||\|)", content)
            if base_match:
                table_names.append(base_match.group(1))
            for union_match in re.finditer(r"(?i:\bunion\s+(?:kind\s*=\s*\w+\s+)?([A-Za-z_][A-Za-z0-9_,\s]*))", content):
                table_names.extend(n.strip() for n in union_match.group(1).split(","))
            for join_match in re.finditer(r"(?i:\bjoin\s+(?:kind\s*=\s*\w+\s+)?\(?\s*([A-Za-z_][A-Za-z0-9_]*))", content):
                table_names.append(join_match.group(1))
            for cross_db_match in re.finditer(r'(?i:database\(\s*"([^"]+)"\s*\)\s*\.\s*([A-Za-z_][A-Za-z0-9_]*))', content):
                cross_db_parts = {"source_database": cross_db_match.group(1), "schema_name": "", "object_name": cross_db_match.group(2), "source_type": "KQL", "object_type": "table_or_view"}
                add_candidate(rows, seen, item, cross_db_parts, path, "reads_from", "table_or_view", "KQL", cluster_uri, cross_db_match.group(1),
                              f"KQL query cross-database reference in '{path}'.", "confirmed")
            for table_name in table_names:
                if test_object_identifier_noise(table_name) or re.match(r"(?i:^(let|set|print|range|datatable)$)", table_name):
                    continue
                t_parts = {"source_database": database_name, "schema_name": "", "object_name": table_name, "source_type": "KQL", "object_type": "table_or_view"}
                add_candidate(rows, seen, item, t_parts, path, "reads_from", "table_or_view", "KQL", cluster_uri, database_name,
                              f"KQL query references table '{table_name}' in '{path}'.", "likely")


def add_reflex_object_candidates(rows, seen, item, path, text, item_name_by_id, workspace_name_by_id):
    payload = json.loads(text) if text else None
    if not payload:
        return
    for entity in payload if isinstance(payload, list) else [payload]:
        entity_payload = (entity or {}).get("payload")
        if not entity_payload:
            continue

        fabric_item = entity_payload.get("fabricItem")
        if fabric_item:
            item_id = fabric_item.get("itemId", "")
            workspace_id = fabric_item.get("workspaceId", "")
            item_type = fabric_item.get("itemType", "")
            item_name = item_name_by_id.get(item_id, item_id)
            workspace_name = workspace_name_by_id.get(workspace_id, workspace_id)
            if item_name:
                parts = {"source_database": workspace_name, "schema_name": "", "object_name": item_name, "source_type": "Fabric", "object_type": "item_reference"}
                add_candidate(rows, seen, item, parts, path, "executes", "item_reference", "Fabric", workspace_name, workspace_name,
                              f"Reflex action runs Fabric {item_type} '{item_name}' (workspace '{workspace_name}') in '{path}'.", "confirmed")

        connection = entity_payload.get("connection")
        if connection:
            artifact_id = connection.get("artifactId", "")
            workspace_id = connection.get("workspaceId", "")
            event_group_type = connection.get("eventGroupType", "")
            item_name = item_name_by_id.get(artifact_id, artifact_id)
            workspace_name = workspace_name_by_id.get(workspace_id, workspace_id)
            if item_name:
                parts = {"source_database": workspace_name, "schema_name": "", "object_name": item_name, "source_type": "Fabric", "object_type": "item_reference"}
                add_candidate(rows, seen, item, parts, path, "reads_from", "item_reference", "Fabric", workspace_name, workspace_name,
                              f"Reflex listens for {event_group_type} events from Fabric item '{item_name}' (workspace '{workspace_name}') in '{path}'.", "confirmed")


def add_graphql_api_object_candidates(rows, seen, item, path, text, item_name_by_id, workspace_name_by_id):
    payload = json.loads(text) if text else None
    data_sources = (payload or {}).get("datasources")
    if not data_sources:
        return
    for data_source in data_sources:
        if not data_source:
            continue
        source_item_id = data_source.get("sourceItemId", "")
        source_workspace_id = data_source.get("sourceWorkspaceId", "")
        source_type = data_source.get("sourceType", "")
        source_item_name = item_name_by_id.get(source_item_id, source_item_id)
        source_workspace_name = workspace_name_by_id.get(source_workspace_id, source_workspace_id)
        for obj in data_source.get("objects") or []:
            if not obj:
                continue
            source_object = obj.get("sourceObject", "")
            if not source_object or test_object_identifier_noise(source_object):
                continue
            obj_parts = split_object_identifier(source_object)
            if not obj_parts:
                continue
            obj_parts["source_database"] = source_item_name
            add_candidate(rows, seen, item, obj_parts, path, "reads_from", "table_or_view", "Fabric", source_workspace_name, source_item_name,
                          f"GraphQL API exposes {source_type} table '{source_object}' from '{source_item_name}' (workspace '{source_workspace_name}') in '{path}'.", "confirmed")


def add_data_agent_table_candidate(rows, seen, item, path, node, schema_name, source_display_name, workspace_name, source_kind):
    node_type = (node or {}).get("type", "")
    node_name = (node or {}).get("display_name", "")
    if node_type.endswith(".table"):
        if not test_object_identifier_noise(node_name):
            parts = {"source_database": source_display_name, "schema_name": schema_name, "object_name": node_name, "source_type": "Fabric", "object_type": "table_or_view"}
            add_candidate(rows, seen, item, parts, path, "reads_from", "table_or_view", "Fabric", workspace_name, source_display_name,
                          f"Data Agent is configured against {source_kind} table '{node_name}' in '{source_display_name}' (workspace '{workspace_name}').", "confirmed")
        return
    children = (node or {}).get("children")
    if not children:
        return
    next_schema = node_name if node_type.endswith(".schema") else schema_name
    for child in children:
        if child:
            add_data_agent_table_candidate(rows, seen, item, path, child, next_schema, source_display_name, workspace_name, source_kind)


def add_data_agent_object_candidates(rows, seen, item, path, text, workspace_name_by_id):
    payload = json.loads(text) if text else None
    if not payload:
        return
    display_name = payload.get("displayName", "")
    workspace_id = payload.get("workspaceId", "")
    source_kind = payload.get("type", "")
    if not display_name:
        return
    workspace_name = workspace_name_by_id.get(workspace_id, workspace_id)
    for element in payload.get("elements") or []:
        if element:
            add_data_agent_table_candidate(rows, seen, item, path, element, "", display_name, workspace_name, source_kind)


# %% [markdown]
# ## Dispatcher (Extract-ObjectsFromDefinitionText)

# %%
_GENERIC_PROPERTY_PATTERN = re.compile(
    r'(?is)"(?:tableName|dbTable|table|storedProcedureName|fileName|folderPath|query|sqlQuery|sourceQuery|sqlStatement)"\s*:\s*"((?:\\.|[^"])*)"'
)
_KEY_NAME_PATTERN = re.compile(r'"([^"]+)"')


def extract_objects_from_definition_text(rows, seen, item, path, text, workspace_name_by_id, lakehouse_name_by_id, item_name_by_id):
    if not text or path == ".platform":
        return
    add_string_pattern_candidates(rows, seen, item, path, text)
    add_embedded_sql_candidates(rows, seen, item, path, text)
    # UserDataFunction's function_app.py is real Python code -- the two
    # generic parsers above already cover it (plain text pattern matches,
    # not Notebook-specific), so no dedicated parser needed for it.
    if item["item_type"] == "Dataflow":
        add_mashup_object_candidates(rows, seen, item, path, text, workspace_name_by_id, lakehouse_name_by_id)
    if item["item_type"] == "Eventstream" and path == "eventstream.json":
        add_eventstream_object_candidates(rows, seen, item, path, text)
    if item["item_type"] == "KQLQueryset" and path == "RealTimeQueryset.json":
        add_kql_queryset_object_candidates(rows, seen, item, path, text)
    if item["item_type"] == "Reflex" and path == "ReflexEntities.json":
        add_reflex_object_candidates(rows, seen, item, path, text, item_name_by_id, workspace_name_by_id)
    if item["item_type"] == "GraphQLApi" and path == "graphql-definition.json":
        add_graphql_api_object_candidates(rows, seen, item, path, text, item_name_by_id, workspace_name_by_id)
    if item["item_type"] == "DataAgent" and path.endswith("datasource.json"):
        add_data_agent_object_candidates(rows, seen, item, path, text, workspace_name_by_id)

    for match in _GENERIC_PROPERTY_PATTERN.finditer(text):
        key_name_match = _KEY_NAME_PATTERN.search(match.group(0))
        key_name = key_name_match.group(1) if key_name_match else ""
        value = match.group(1)
        if re.search(r"(?i:query|sql)", key_name):
            add_sql_object_candidates(rows, seen, item, path, value, "reads_from", "Definition JSON query property parser")
            continue
        parts = split_object_identifier(value)
        object_type = "stored_procedure" if re.search(r"(?i:storedProcedure)", key_name) else ("file" if re.search(r"(?i:file|folder)", key_name) else "table_or_view")
        usage = get_context_usage(text, match.start(), "unknown")
        if object_type == "stored_procedure":
            usage = "executes"
        add_candidate(rows, seen, item, parts, path, usage, object_type, "", "", "",
                      f"Definition property '{key_name}' references object in '{path}'.", "likely")


# %% [markdown]
# ## Cargar workspaces + items (dbo.bronze_workspaces / dbo.bronze_items)

# %%
connection = connect_warehouse()
cursor = connection.cursor()
cursor.execute("SELECT workspace_name, technical_id FROM dbo.bronze_workspaces")
workspace_id_by_name = {row[0]: row[1] for row in cursor.fetchall()}
workspace_name_by_id = {v: k for k, v in workspace_id_by_name.items()}

cursor.execute(
    "SELECT workspace_name, workspace_environment, item_type, item_name, qualified_name, technical_id "
    "FROM dbo.bronze_items WHERE status = 'discovered'"
)
all_items = [
    {"workspace_name": r[0], "workspace_environment": r[1], "item_type": r[2], "item_name": r[3], "qualified_name": r[4], "technical_id": r[5]}
    for r in cursor.fetchall()
]
if not all_items:
    raise RuntimeError("dbo.bronze_items has no discovered rows -- run NB_Discover_Workspaces_Items first.")

lakehouse_name_by_id = {i["technical_id"]: i["item_name"] for i in all_items if i["item_type"] == "Lakehouse" and i["technical_id"]}
item_name_by_id = {i["technical_id"]: i["item_name"] for i in all_items if i["technical_id"]}

target_items = [i for i in all_items if i["item_type"] in ITEM_TYPES]
filter_set = {n.strip().lower() for n in re.split(r"[;,]", WorkspaceNameFilter or "") if n.strip()}
if filter_set:
    target_items = [i for i in target_items if i["workspace_name"].strip().lower() in filter_set]
print(f"Target items: {len(target_items)} ({'filtered: ' + WorkspaceNameFilter if filter_set else 'full tenant'})")

# %% [markdown]
# ## Run: for each item, getDefinition + per-type parsing

# %%
fabric_token = acquire_token("https://api.fabric.microsoft.com/.default")
fabric_headers = {"Authorization": f"Bearer {fabric_token}", "Content-Type": "application/json"}

rows = []
seen = set()
success_count = 0
processed = 0

for item in target_items:
    processed += 1
    if processed % 20 == 0:
        print(f"Processed {processed} / {len(target_items)} item definitions...")
        fabric_token = acquire_token("https://api.fabric.microsoft.com/.default")
        fabric_headers["Authorization"] = f"Bearer {fabric_token}"

    workspace_id = workspace_id_by_name.get(item["workspace_name"], "")
    if not workspace_id or not item["technical_id"]:
        continue

    result = get_item_definition(workspace_id, item["technical_id"], item["item_type"], fabric_headers)
    if not result["ok"]:
        continue
    success_count += 1
    for part in decode_definition_parts(result["payload"]):
        if not part["text"]:
            continue
        try:
            extract_objects_from_definition_text(rows, seen, item, part["path"], part["text"], workspace_name_by_id, lakehouse_name_by_id, item_name_by_id)
        except Exception as exc:  # noqa: BLE001 - one malformed definition part must not abort the whole run
            print(f"[object-lineage] Skipped '{item['qualified_name']}' part '{part['path']}': {exc}")

print(f"Definitions succeeded: {success_count} / {len(target_items)}. Object candidates: {len(rows)}.")

# %% [markdown]
# ## Write to the Warehouse (dbo.bronze_item_object_lineage_candidates),
# keeping what belongs to workspaces outside WorkspaceNameFilter

# %%
# Reconnect with a fresh database token -- the connection above
# has been open since before the per-item loop (the whole tenant, with
# getDefinition + retries), the same pattern that already caused a real
# connection failure ("TCP Provider: Error code 0x20") in NB_Discover_
# Dependencies.py -- same fix applied here preventively.
connection.close()
connection = connect_warehouse()
cursor = connection.cursor()

retained_rows = []
if filter_set:
    try:
        cursor.execute(f"SELECT {', '.join(CANDIDATE_COLUMNS)} FROM dbo.bronze_item_object_lineage_candidates")
        retained_rows = [
            dict(zip(CANDIDATE_COLUMNS, r))
            for r in cursor.fetchall()
            if str(r[0]).strip().lower() not in filter_set
        ]
    except pyodbc.Error:
        connection.rollback()  # table doesn't exist yet -- nothing to retain

final_rows = retained_rows + rows

cursor.execute("IF OBJECT_ID('dbo.bronze_item_object_lineage_candidates', 'U') IS NOT NULL DROP TABLE dbo.bronze_item_object_lineage_candidates;")
column_defs = ", ".join(f"[{c}] VARCHAR(8000)" for c in CANDIDATE_COLUMNS)
cursor.execute(f"CREATE TABLE dbo.bronze_item_object_lineage_candidates ({column_defs});")
connection.commit()
if final_rows:
    placeholders = ", ".join("?" for _ in CANDIDATE_COLUMNS)
    insert_sql = f"INSERT INTO dbo.bronze_item_object_lineage_candidates ({', '.join(f'[{c}]' for c in CANDIDATE_COLUMNS)}) VALUES ({placeholders})"
    cursor.fast_executemany = True
    cursor.executemany(insert_sql, [[truncate_value(row.get(c, "")) for c in CANDIDATE_COLUMNS] for row in final_rows])
    connection.commit()

connection.close()
print(f"dbo.bronze_item_object_lineage_candidates: {len(final_rows)} row(s) written ({len(retained_rows)} retained, {len(rows)} freshly computed).")
print("Done.")
