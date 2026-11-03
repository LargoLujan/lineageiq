# NB_Harden_Object_Lineage_Candidates
#
# Fuente para un notebook Python de Fabric -- Fase D del "escaneo profundo"
# (ver docs/105_fabric_native_discovery_setup.md para el patron general).
# Cada bloque "# %%" es una celda -- pegalas en orden.
#
# Replica fiel de scripts/33_harden_object_lineage_candidates.ps1: limpia
# ruido obvio del parser (nombre de workspace mal interpretado como objeto,
# URL de storage, GUID, palabra clave SQL genérica, fragmento de
# expresión...) de los candidatos de linaje a nivel de objeto, y rellena
# servidor/base de datos cuando el item tiene EXACTAMENTE una dependencia
# SQL confirmada en otro sitio. A diferencia de los demas notebooks de este
# proyecto, este es puramente local (Warehouse -> Warehouse) -- no llama a
# ninguna API de Fabric ni conecta a ningun SQL endpoint externo, solo lee
# y reescribe sus propias tablas bronze.
#
# Motivado directamente por lo visto en la prueba en vivo de NB_Extract_
# Object_Column_Catalog (Fase B, 2026-08-19): 2 de 4 fallos fueron un
# nombre de workspace ("digitalanalytics-sample_contoso_pro") tratado como
# si fuera un servidor SQL real -- exactamente el tipo de ruido que este
# notebook existe para eliminar.
#
# Reescribe EN SITIO (tras limpiar/rellenar): dbo.bronze_item_object_
# lineage_candidates, dbo.bronze_pipeline_object_lineage_candidates, dbo.
# bronze_semantic_model_view_candidates. Escribe ademas dbo.bronze_object_
# lineage_candidate_hardening_review (un review row por cada fila tocada)
# y dbo.bronze_object_lineage_candidate_hardening_summary.
#
# Debe correr DESPUES de NB_Discover_Dependencies, NB_Discover_Object_
# Lineage, NB_Discover_Pipeline_Object_Lineage y NB_Discover_Semantic_
# Model_Lineage -- limpia lo que esos cuatro ya escribieron.
#
# Sin celda de parametros -- a diferencia de los notebooks "Discover"/
# "Extract", este limpia SIEMPRE las 3 tablas enteras (igual que el script
# local, que tampoco tiene filtro de workspace): un candidato ruidoso en un
# workspace no incluido en un rescan concreto seguiria siendo ruido, no
# tiene sentido dejarlo sin limpiar.

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

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"

ONELAKE_WORKSPACE_NAME = "<tu-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<tu-lakehouse-onelake>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"

WAREHOUSE_SQL_ENDPOINT = "<tu-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<NombreDelWarehouse>"

# %% [markdown]
# ## Autenticacion + Warehouse (mismo patron que los demas notebooks)

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


def normalize_key(value):
    if not value:
        return ""
    return re.sub(r"\s+", " ", str(value).strip().lower())

# %% [markdown]
# ## Deteccion de ruido (replica de Get-NoiseReason) + emparejamiento SQL
# unico por item (replica de Get-UniqueEndpointForRow / Test-HasMultipleSqlEndpoints)

# %%
_OBJECT_TYPE_ALIASES = {"storedprocedure": "stored_procedure", "procedure": "stored_procedure", "proc": "stored_procedure", "sp": "stored_procedure"}
_GENERIC_KEYWORDS = {
    "select", "with", "where", "join", "from", "on", "and", "or", "as", "case", "when", "then", "else", "end",
    "openquery", "status", "input", "output", "source", "target", "unknown source", "table", "tables", "schema",
    "catalog", "catalogue", "directory", "record", "list", "inventory", "chronology", "lineage",
}
_SCHEMA_LIKE = {"dbo", "hst", "stg", "ctl", "dim", "fct", "pln"}
# 2026-08-19 fix: Python's re (unlike PowerShell's regex engine) requires an
# inline (?i) flag to be the very first thing in the pattern -- confirmed
# live, every single row failed the whole notebook with "global flags not
# at the start of the expression" because ^ came before (?i) here. Using
# the re.IGNORECASE compile flag instead sidesteps the ordering rule
# entirely.
_URL_PREFIX = re.compile(r"^(https?|abfss|wasbs|s3)://", re.IGNORECASE)
_PLACEHOLDER = re.compile(r"^<[^>]+>$")
_GUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
_NUMERIC = re.compile(r"^[0-9]+$")
_PUNCTUATION = re.compile(r"^[,.;:]+$")
_EXPRESSION_KEYWORDS = re.compile(r"(?i)\b(lineageTag|measure\s+|DATE\s*\(|YEAR\s*\(|MONTH\s*\(|DAY\s*\(|MIN\s*\(|MAX\s*\(|Convert\s*\()")


def normalize_object_type(value):
    clean = re.sub(r"[\s-]+", "_", normalize_key(value))
    return _OBJECT_TYPE_ALIASES.get(clean, clean)


def get_noise_reason(row, known_workspace_keys):
    object_name = row.get("object_name", "")
    object_type = normalize_object_type(row.get("object_type", ""))
    source_type = row.get("source_type", "")
    source_server = row.get("source_server", "")
    source_database = row.get("source_database") or row.get("database_name", "")

    if object_type == "file":
        return ""
    if not object_name:
        return "empty_object_name"

    clean = re.sub(r"\s+", " ", object_name).strip()
    if not clean:
        return "empty_object_name"
    if _URL_PREFIX.match(clean):
        return "url_identifier_as_non_file_object"
    if source_type == "File":
        return ""
    if not source_server and not source_database and normalize_key(clean) in known_workspace_keys:
        return "workspace_name_misparsed_as_object"
    if len(clean) > 256:
        return "too_long_for_metadata_identifier"
    if _PLACEHOLDER.match(clean):
        return "placeholder_identifier"
    if _GUID.match(clean):
        return "guid_identifier"
    if _NUMERIC.match(clean):
        return "numeric_literal"
    if _PUNCTUATION.match(clean):
        return "punctuation_identifier"
    if not row.get("schema_name", "") and len(clean) == 1:
        return "single_character_identifier"
    if normalize_key(clean) in _GENERIC_KEYWORDS:
        return "generic_or_sql_keyword_identifier"
    if normalize_key(clean) in _SCHEMA_LIKE:
        return "schema_name_misparsed_as_object"
    if re.search(r"\([^)]{2,}\)", clean) and re.search(r"\s", clean):
        return "human_label_with_parentheses"
    if re.search(r"\s", clean) and (re.search(r"[+/]", clean) or len(clean.split()) >= 3):
        return "free_text_label_identifier"
    if _EXPRESSION_KEYWORDS.search(clean):
        return "expression_fragment"
    if re.search(r"[\r\n]", object_name) and re.search(r"[&()]", clean):
        return "multiline_expression_fragment"
    if re.search(r"[{}]", clean) and not re.search(r"[/\\.]", clean):
        return "template_or_json_fragment"
    if re.search(r"[;&=]", clean):
        return "expression_or_statement_fragment"
    return ""


_SQL_CONNECTION_RE = re.compile(r"^External Connection / SQL / ([^;]+);(.+)$")


def sql_connection_from_dependency(qualified_name):
    if not qualified_name:
        return None
    match = _SQL_CONNECTION_RE.match(qualified_name)
    if not match:
        return None
    server, database = match.group(1).strip(), match.group(2).strip()
    return {
        "source_server": server,
        "source_database": database,
        "source_qualified_name": qualified_name,
        "key": f"{normalize_key(server)}|{normalize_key(database)}",
    }


def build_sql_connections_by_item(dependency_rows):
    by_item = {}
    for row in dependency_rows:
        if row.get("relationship_type") != "depends_on" or row.get("confidence") != "confirmed":
            continue
        endpoint = sql_connection_from_dependency(row.get("to_qualified_name", ""))
        if not endpoint:
            continue
        item = row.get("from_qualified_name", "")
        if not item:
            continue
        by_item.setdefault(item, {})[endpoint["key"]] = endpoint
    return by_item


def row_item_keys(row):
    keys = []
    invoked = row.get("invoked_item_qualified_name", "")
    if invoked:
        keys.append(invoked)
    item = row.get("item_qualified_name") or row.get("semantic_model_qualified_name") or row.get("qualified_name", "")
    if item:
        keys.append(item)
    return keys

# %% [markdown]
# ## Procesar una tabla de candidatos (limpiar ruido + rellenar servidor/bd)

# %%
def harden_candidate_table(rows, columns, known_workspace_keys, sql_connections_by_item, review_rows, summary, file_label):
    output_rows = []
    summary["files_processed"] += 1
    summary["input_rows"] += len(rows)

    for row in rows:
        noise_reason = get_noise_reason(row, known_workspace_keys)
        if noise_reason:
            review_rows.append(_review_row(file_label, "removed_noise", noise_reason, row, None))
            summary["removed_noise_rows"] += 1
            continue

        object_type = normalize_object_type(row.get("object_type", ""))
        source_server = row.get("source_server", "")
        source_database = row.get("source_database") or row.get("database_name", "")
        can_backfill = (not source_server or not source_database) and object_type in ("table_or_view", "native_query_object", "stored_procedure")

        if can_backfill:
            keys = row_item_keys(row)
            unique_endpoints = []
            has_multiple = False
            for key in keys:
                candidates = sql_connections_by_item.get(key)
                if not candidates:
                    continue
                if len(candidates) == 1:
                    unique_endpoints.append(next(iter(candidates.values())))
                elif len(candidates) > 1:
                    has_multiple = True
            if unique_endpoints:
                endpoint = unique_endpoints[0]
                row["source_type"] = "SQL"
                row["source_server"] = endpoint["source_server"]
                row["source_database"] = endpoint["source_database"]
                if "database_name" in row:
                    row["database_name"] = endpoint["source_database"]
                if "source_name" in row:
                    row["source_name"] = endpoint["source_database"]
                if "source_qualified_name" in row:
                    row["source_qualified_name"] = endpoint["source_qualified_name"]
                if "evidence" in row:
                    addition = f" Source endpoint backfilled from the item's unique confirmed SQL dependency '{endpoint['source_qualified_name']}'."
                    row["evidence"] = re.sub(r"\s+", " ", (row.get("evidence", "") + addition)).strip()
                review_rows.append(_review_row(file_label, "endpoint_backfilled", "unique_confirmed_sql_dependency", row, endpoint))
                summary["endpoint_backfilled_rows"] += 1
            elif has_multiple:
                review_rows.append(_review_row(file_label, "left_unresolved", "multiple_confirmed_sql_dependencies", row, None))
                summary["ambiguous_sql_connection_rows"] += 1
            else:
                summary["unchanged_rows"] += 1
        else:
            summary["unchanged_rows"] += 1

        output_rows.append(row)

    summary["output_rows"] += len(output_rows)
    return output_rows


def _review_row(file_label, action, reason, row, endpoint):
    return {
        "file": file_label,
        "action": action,
        "reason": reason,
        "workspace_name": row.get("workspace_name", ""),
        "item_type": row.get("item_type", ""),
        "item_name": row.get("item_name") or row.get("semantic_model_name", ""),
        "item_qualified_name": row.get("item_qualified_name") or row.get("semantic_model_qualified_name") or row.get("qualified_name", ""),
        "original_source_type": row.get("source_type", ""),
        "original_source_server": row.get("source_server", ""),
        "original_source_database": row.get("source_database") or row.get("database_name", ""),
        "new_source_server": endpoint["source_server"] if endpoint else "",
        "new_source_database": endpoint["source_database"] if endpoint else "",
        "schema_name": row.get("schema_name", ""),
        "object_name": row.get("object_name", ""),
        "object_type": row.get("object_type", ""),
        "usage_type": row.get("usage_type", ""),
        "confidence": row.get("confidence", ""),
        "evidence": row.get("evidence", ""),
    }

# %% [markdown]
# ## Ejecutar

# %%
ITEM_COLUMNS = [
    "workspace_name", "workspace_environment", "item_type", "item_name", "item_qualified_name",
    "source_type", "source_name", "source_qualified_name", "source_server", "source_database",
    "schema_name", "object_name", "object_type", "usage_type", "confidence", "definition_path", "evidence",
]
PIPELINE_COLUMNS = ITEM_COLUMNS + ["activity_name", "activity_type", "invoked_item_qualified_name"]
SEMANTIC_COLUMNS = [
    "workspace_name", "workspace_environment", "semantic_model_name", "semantic_model_qualified_name",
    "semantic_table", "source_server", "database_name", "schema_name", "object_name", "object_type",
    "definition_path", "confidence", "evidence",
]
DEPENDENCY_COLUMNS = ["from_qualified_name", "to_qualified_name", "relationship_type", "source_system", "evidence", "confidence", "notes"]
REVIEW_COLUMNS = [
    "file", "action", "reason", "workspace_name", "item_type", "item_name", "item_qualified_name",
    "original_source_type", "original_source_server", "original_source_database", "new_source_server",
    "new_source_database", "schema_name", "object_name", "object_type", "usage_type", "confidence", "evidence",
]
SUMMARY_COLUMNS = ["metric", "value", "notes"]


def read_table(connection, table_name, columns):
    cursor = connection.cursor()
    try:
        cursor.execute(f"SELECT {', '.join(columns)} FROM dbo.{table_name}")
    except pyodbc.Error:
        connection.rollback()
        print(f"[read] dbo.{table_name} not found yet -- skipping.")
        return []
    return [dict(zip(columns, row)) for row in cursor.fetchall()]


connection = connect_warehouse()
try:
    workspace_rows = read_table(connection, "bronze_workspaces", ["workspace_name", "normalized_workspace_name"])
    known_workspace_keys = set()
    for row in workspace_rows:
        for name in (row.get("workspace_name", ""), row.get("normalized_workspace_name", "")):
            key = normalize_key(name)
            if key:
                known_workspace_keys.add(key)

    dependency_rows = read_table(connection, "bronze_dependencies", DEPENDENCY_COLUMNS)
    sql_connections_by_item = build_sql_connections_by_item(dependency_rows)
    print(f"Items with at least one confirmed SQL dependency: {len(sql_connections_by_item)}")

    item_rows = read_table(connection, "bronze_item_object_lineage_candidates", ITEM_COLUMNS)
    pipeline_rows = read_table(connection, "bronze_pipeline_object_lineage_candidates", PIPELINE_COLUMNS)
    semantic_rows = read_table(connection, "bronze_semantic_model_view_candidates", SEMANTIC_COLUMNS)
finally:
    connection.close()

summary = {
    "files_processed": 0, "input_rows": 0, "output_rows": 0, "removed_noise_rows": 0,
    "endpoint_backfilled_rows": 0, "ambiguous_sql_connection_rows": 0, "unchanged_rows": 0,
}
review_rows = []

hardened_item_rows = harden_candidate_table(item_rows, ITEM_COLUMNS, known_workspace_keys, sql_connections_by_item, review_rows, summary, "bronze_item_object_lineage_candidates") if item_rows else []
hardened_pipeline_rows = harden_candidate_table(pipeline_rows, PIPELINE_COLUMNS, known_workspace_keys, sql_connections_by_item, review_rows, summary, "bronze_pipeline_object_lineage_candidates") if pipeline_rows else []
hardened_semantic_rows = harden_candidate_table(semantic_rows, SEMANTIC_COLUMNS, known_workspace_keys, sql_connections_by_item, review_rows, summary, "bronze_semantic_model_view_candidates") if semantic_rows else []

print(f"Files processed: {summary['files_processed']}")
print(f"Input rows: {summary['input_rows']}")
print(f"Output rows: {summary['output_rows']}")
print(f"Removed noise rows: {summary['removed_noise_rows']}")
print(f"Endpoint backfilled rows: {summary['endpoint_backfilled_rows']}")
print(f"Ambiguous SQL connection rows: {summary['ambiguous_sql_connection_rows']}")

summary_rows = [{"metric": k, "value": str(v), "notes": ""} for k, v in summary.items()]
summary_rows.append({"metric": "items_with_unique_confirmed_sql_dependency", "value": str(len(sql_connections_by_item)), "notes": "Used only for endpoint backfill when a candidate row lacked source server/database."})

connection = connect_warehouse()
try:
    if item_rows:
        replace_table(connection, "bronze_item_object_lineage_candidates", ITEM_COLUMNS, hardened_item_rows)
    if pipeline_rows:
        replace_table(connection, "bronze_pipeline_object_lineage_candidates", PIPELINE_COLUMNS, hardened_pipeline_rows)
    if semantic_rows:
        replace_table(connection, "bronze_semantic_model_view_candidates", SEMANTIC_COLUMNS, hardened_semantic_rows)
    replace_table(connection, "bronze_object_lineage_candidate_hardening_review", REVIEW_COLUMNS, review_rows)
    replace_table(connection, "bronze_object_lineage_candidate_hardening_summary", SUMMARY_COLUMNS, summary_rows)
finally:
    connection.close()

print("Done.")
