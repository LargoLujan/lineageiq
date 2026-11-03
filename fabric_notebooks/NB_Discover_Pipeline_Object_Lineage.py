# NB_Discover_Pipeline_Object_Lineage
#
# Fuente para un notebook Python de Fabric -- cuarto paso del pipeline de
# descubrimiento nativo (ver docs/105_fabric_native_discovery_setup.md).
# Cada bloque "# %%" es una celda -- pégalas en orden.
#
# Réplica fiel de scripts/19_extract_pipeline_object_lineage.ps1: para cada
# DataPipeline, descarga su getDefinition, camina el grafo de actividades
# (Copy/lookups/stored-procedure activities, etc.), atribuye a la pipeline
# los objetos que cada actividad lee/escribe (dataset tables, ubicaciones
# de archivo, queries SQL embebidas, nombres de procedimiento almacenado),
# detecta qué actividades invocan OTRO item de Fabric (TridentNotebook ->
# notebookId, InvokeCopyJob -> copyJobId, InvokePipeline -> pipelineId), y
# propaga (hasta 8 pasadas, igual que el original) los objetos ya conocidos
# de esos items invocados hacia la propia pipeline -- así una pipeline que
# solo "orquesta" (llama a un notebook, llama a otra pipeline) hereda el
# linaje real de lo que de verdad toca, no queda vacía.
#
# Escribe en dbo.bronze_pipeline_object_lineage_candidates (20 columnas) y
# dbo.bronze_pipeline_activity_lineage (11 columnas) -- mismas tablas que
# scripts/67_upload_bronze_to_warehouse.ps1 ya sube desde local.
#
# Nota de fidelidad: el original SIEMPRE marca confidence="likely" al
# copiar una fila a la salida final vía Copy-InheritedRow, incluso para
# las filas "directas" que se calcularon como "confirmed" un paso antes
# (Add-DatasetCandidates/Add-SqlCandidates) -- no es un error de este
# port, es el comportamiento real del script original, replicado tal cual.
#
# Depende de que dbo.bronze_item_object_lineage_candidates ya exista
# (escrito por NB_Discover_Object_Lineage) para la herencia de objetos de
# items invocados -- si esa tabla no existe todavía, la herencia
# simplemente no encuentra nada que heredar (no falla).
#
# Deliberadamente NO incluida la herencia desde notebook_super_lineage_
# objects.csv (analysis/*, viene de scripts/52_build_notebook_super_
# lineage.py, un parser de código de notebook bastante más profundo que
# el genérico de NB_Discover_Object_Lineage/18) -- ese notebook de origen
# no está portado todavía, así que una pipeline que invoca un Notebook
# solo hereda lo que 18/NB_Discover_Object_Lineage ya le vio a ese
# notebook (patrones genéricos), no el análisis AST más profundo de 52.
#
# Self-contained a propósito, mismo criterio que los notebooks anteriores.

# %% [markdown]
# ## Configuración

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
# Ya no se lee de Key Vault (bloqueado) NI de un parámetro del pipeline
# (probado 2026-08-12: filtró el valor en texto plano al fallar la
# conversión de tipo -- nunca más por ahí). Fichero privado en el área
# Files del Lakehouse del workspace, leído con notebookutils.fs.head() --
# gobernado por el rol de Fabric del SP sobre este workspace, no por RBAC
# de Azure sobre un recurso aparte.
ONELAKE_WORKSPACE_NAME = "<tu-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<tu-lakehouse-onelake>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"
WAREHOUSE_SQL_ENDPOINT = "<tu-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<NombreDelWarehouse>"

REQUEST_DELAY_SECONDS = 0.25
RETRY_COUNT = 5
MAX_OPERATION_POLLS = 20
MAX_OPERATION_DELAY_SECONDS = 15

CANDIDATE_COLUMNS = [
    "workspace_name", "workspace_environment", "item_type", "item_name", "item_qualified_name",
    "source_type", "source_name", "source_qualified_name", "source_server", "source_database",
    "schema_name", "object_name", "object_type", "usage_type", "confidence", "definition_path",
    "evidence", "activity_name", "activity_type", "invoked_item_qualified_name",
]
ACTIVITY_COLUMNS = [
    "workspace_name", "workspace_environment", "pipeline_name", "pipeline_qualified_name",
    "activity_name", "activity_type", "depends_on_activity", "dependency_conditions",
    "invoked_item_qualified_name", "invoked_item_type", "parameters",
]

# %% [markdown]
# ## Parámetros
# Marca esta celda como celda de parámetros en Fabric.

# %%
WorkspaceNameFilter = ""

# %% [markdown]
# ## Autenticación y Warehouse (mismo patrón que los notebooks anteriores)

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


def normalize_key(value):
    return re.sub(r"\s+", " ", (value or "").strip().lower())


# %% [markdown]
# ## Fabric REST: getDefinition con sondeo LRO (igual que los notebooks anteriores)

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


def get_item_definition(workspace_id, item_id, headers):
    response = fabric_request("POST", f"workspaces/{workspace_id}/items/{item_id}/getDefinition", headers)
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
# ## Split-ObjectIdentifier (variante de 19: sin manejo de Files/Tables/Lakehouse/Warehouse como "file")

# %%
# Mismo fix que NB_Discover_Object_Lineage -- URLs externas (formularios
# SaaS, CRM, sitios de SharePoint...) colapsaban en un unico
# nodo generico "File" en el grafo porque source_database quedaba vacio.
# Este notebook no tenia filtro de URLs de ruido, asi que endpoints de
# autenticacion/infra genericos (login.microsoftonline.com,
# graph.microsoft.com...) tambien contaminaban el grafo -- anadido aqui
# igual que alla, para que ambos notebooks se comporten igual.
_NOISE_URLS = re.compile(
    r"(?i:^https?://(?:developer\.microsoft\.com|[^/]+\.vault\.azure\.net|[^/]*pkgs\.dev\.azure\.com|"
    r"analysis\.windows\.net|api\.fabric\.microsoft\.com|storage\.azure\.com|"
    r"login\.microsoftonline\.com|login\.windows\.net|graph\.microsoft\.com|"
    r"[^/]+\.database\.windows\.net|management\.azure\.com|api\.powerbi\.com)(?:/|$))"
)
_ONELAKE_HOST_PATTERN = re.compile(r"(?i:onelake\.(?:dfs|blob)\.fabric\.microsoft\.com$)")


def extract_url_host(url):
    match = re.match(r"(?i:^\w+://([^/]+))", url)
    if not match:
        return ""
    host = match.group(1)
    if "@" in host:
        host = host.split("@", 1)[1]
    return host.lower()


def split_object_identifier(identifier):
    if not identifier:
        return None
    clean = re.sub(r"[`\[\]\"']", "", identifier).strip()
    clean = re.sub(r"\\+", "/", clean).strip("/")
    if not clean:
        return None
    if re.search(r"(?i:\bimport\b)", clean):
        return None
    if re.match(r"(?i:^(select|with|where|join|from|on|and|or|as|delta|overwrite|append|parquet|csv|json|text|true|false|none|null|default)$)", clean):
        return None
    if re.match(r"(?i:^(http|https|abfss|wasbs|s3)://)", clean):
        if _NOISE_URLS.match(clean):
            return None
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


# %% [markdown]
# ## Recorrido genérico de JSON: Get-NodeListByProperty / Get-StringValuesByProperty

# %%
def get_node_list_by_property(node, property_name):
    results = []

    def walk(current):
        if current is None or isinstance(current, str):
            return
        if isinstance(current, list):
            for child in current:
                walk(child)
            return
        if isinstance(current, dict):
            for key, value in current.items():
                if key.lower() == property_name.lower():
                    results.append(value)
                walk(value)

    walk(node)
    return results


def get_string_values_by_property(node, property_names):
    lowered_names = {n.lower() for n in property_names}
    results = []

    def walk(current):
        if current is None or isinstance(current, str):
            return
        if isinstance(current, list):
            for child in current:
                walk(child)
            return
        if isinstance(current, dict):
            for key, value in current.items():
                if key.lower() in lowered_names and isinstance(value, str) and value:
                    results.append({"name": key, "value": value})
                walk(value)

    walk(node)
    return results


# %% [markdown]
# ## Registro de candidatos (Add-CandidateRow)

# %%
_GUID_ONLY = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def add_candidate_row(rows, seen, pipeline_item, source_type, source_name, source_qualified_name,
                       source_server, source_database, schema_name, object_name, object_type,
                       usage_type, confidence, definition_path, evidence, activity_name, activity_type,
                       invoked_item_qualified_name):
    if not object_name:
        return
    clean_object_name = object_name.strip()
    if re.match(r"^,$", clean_object_name):
        return
    if re.match(r"^\{[^}]+\}$", clean_object_name):
        return
    if _GUID_ONLY.match(clean_object_name):
        return
    if re.match(r"(?i:^(status)$)", clean_object_name):
        return

    key = "|".join(normalize_key(v) for v in (
        pipeline_item["qualified_name"], source_type, source_qualified_name, source_server,
        source_database, schema_name, clean_object_name, object_type, usage_type,
        activity_name, invoked_item_qualified_name,
    ))
    if key in seen:
        return
    seen.add(key)

    rows.append({
        "workspace_name": pipeline_item["workspace_name"],
        "workspace_environment": pipeline_item.get("workspace_environment", ""),
        "item_type": pipeline_item["item_type"],
        "item_name": pipeline_item["item_name"],
        "item_qualified_name": pipeline_item["qualified_name"],
        "source_type": source_type or "FabricOrSQL",
        "source_name": source_name or source_database or source_type,
        "source_qualified_name": source_qualified_name or "",
        "source_server": source_server or "",
        "source_database": source_database or "",
        "schema_name": schema_name or "",
        "object_name": clean_object_name,
        "object_type": object_type or "table_or_view",
        "usage_type": usage_type or "unknown",
        "confidence": confidence or "likely",
        "definition_path": definition_path or "",
        "evidence": limit_text(evidence, 1200),
        "activity_name": activity_name or "",
        "activity_type": activity_type or "",
        "invoked_item_qualified_name": invoked_item_qualified_name or "",
    })


# %% [markdown]
# ## LinkedService / dataset / SQL / stored-procedure parsers (Add-DatasetCandidates / Add-SqlCandidates / Resolve-LinkedService)

# %%
_SQL_KEYWORD_PATTERN = re.compile(
    r'(?is)\b(from|join|into|update|merge\s+into|delete\s+from|exec(?:ute)?|call)\s+'
    r'((?:\[[^\]]+\]|"[^"]+"|`[^`]+`|[A-Za-z_][A-Za-z0-9_$#-]*)(?:\s*\.\s*(?:\[[^\]]+\]|"[^"]+"|`[^`]+`|[A-Za-z_][A-Za-z0-9_$#-]*)){0,2})'
)


def resolve_linked_service(dataset_settings, item_by_workspace_and_id):
    linked_service = (dataset_settings or {}).get("linkedService") or {}
    ls_name = linked_service.get("name", "")
    ls_props = linked_service.get("properties") or {}
    ls_type = ls_props.get("type", "")
    ls_type_props = ls_props.get("typeProperties") or {}
    workspace_id = ls_type_props.get("workspaceId", "")
    artifact_id = ls_type_props.get("artifactId", "")
    server = ls_type_props.get("server") or ls_type_props.get("serverName") or ls_type_props.get("host", "")
    database = ls_type_props.get("database") or ls_type_props.get("databaseName", "")

    map_key = normalize_key(f"{workspace_id}|{artifact_id}")
    mapped_item = item_by_workspace_and_id.get(map_key) if map_key else None
    if mapped_item:
        return {
            "source_type": mapped_item["item_type"], "source_name": mapped_item["item_name"],
            "source_qualified_name": mapped_item["qualified_name"], "source_server": mapped_item["workspace_name"],
            "source_database": mapped_item["item_name"],
        }

    if re.search(r"(?i:Lakehouse|Warehouse|DataWarehouse)", ls_type):
        source_type = "Fabric"
    elif re.search(r"(?i:Sql|SQL|ODBC|Odbc|AzureSql)", ls_type):
        source_type = "SQL"
    elif re.search(r"(?i:S3|Amazon|File|Parquet|Delimited|Blob|ADLS)", ls_type):
        source_type = "File"
    elif ls_type:
        source_type = ls_type
    else:
        source_type = "FabricOrSQL"
    return {
        "source_type": source_type, "source_name": ls_name or database, "source_qualified_name": "",
        "source_server": server, "source_database": database or ls_name,
    }


def add_sql_candidates(rows, seen, pipeline_item, sql_text, definition_path, evidence_prefix, activity_name, activity_type):
    if not sql_text:
        return
    for match in _SQL_KEYWORD_PATTERN.finditer(sql_text):
        verb = re.sub(r"\s+", " ", match.group(1)).lower()
        identifier = match.group(2).strip()
        parts = split_object_identifier(identifier)
        if not parts:
            continue
        usage, object_type = "reads_from", "native_query_object"
        if re.search(r"into|update|merge|delete", verb):
            usage = "writes_to"
        elif re.search(r"exec|call", verb):
            usage, object_type = "executes", "stored_procedure"
        add_candidate_row(rows, seen, pipeline_item, "SQL", "", "", "", parts["source_database"],
                          parts["schema_name"], parts["object_name"], object_type, usage, "likely",
                          definition_path, f"{evidence_prefix} SQL keyword '{verb}' references object.",
                          activity_name, activity_type, "")


def add_dataset_candidates(rows, seen, pipeline_item, dataset_settings, usage_type, definition_path,
                            activity_name, activity_type, item_by_workspace_and_id):
    if not dataset_settings:
        return
    source = resolve_linked_service(dataset_settings, item_by_workspace_and_id)
    type_props = dataset_settings.get("typeProperties") or {}
    table_value = type_props.get("table") or type_props.get("tableName") or type_props.get("dbTable", "")
    if table_value:
        parts = split_object_identifier(table_value)
        if parts:
            schema = parts["schema_name"] or type_props.get("schemaName", "")
            source_database = source["source_database"] or parts["source_database"]
            add_candidate_row(rows, seen, pipeline_item, source["source_type"], source["source_name"],
                              source["source_qualified_name"], source["source_server"], source_database, schema,
                              parts["object_name"], "table_or_view", usage_type, "confirmed", definition_path,
                              f"Pipeline activity '{activity_name}' ({activity_type}) {usage_type} dataset table '{table_value}'.",
                              activity_name, activity_type, "")

    location = type_props.get("location")
    if location:
        folder = location.get("folderPath") or location.get("path", "")
        file_name = location.get("fileName", "")
        bucket = location.get("bucketName") or location.get("container", "")
        if folder or file_name:
            object_name = "/".join(p for p in (folder, file_name) if p)
            add_candidate_row(rows, seen, pipeline_item, "File", bucket, "", "", bucket, "", object_name, "file",
                              usage_type, "confirmed", definition_path,
                              f"Pipeline activity '{activity_name}' ({activity_type}) {usage_type} file location '{object_name}'.",
                              activity_name, activity_type, "")


def add_direct_activity_candidates(rows, seen, pipeline_item, activity, definition_path, item_by_workspace_and_id):
    activity_name = activity.get("name", "")
    activity_type = activity.get("type", "")
    type_props = activity.get("typeProperties") or {}
    for side_name, usage in (("source", "reads_from"), ("sink", "writes_to")):
        side = type_props.get(side_name)
        if not side:
            continue
        for dataset_settings in get_node_list_by_property(side, "datasetSettings"):
            add_dataset_candidates(rows, seen, pipeline_item, dataset_settings, usage, definition_path,
                                   activity_name, activity_type, item_by_workspace_and_id)
        for query in get_string_values_by_property(side, ["query", "sqlQuery", "sqlReaderQuery", "sourceQuery"]):
            add_sql_candidates(rows, seen, pipeline_item, query["value"], definition_path,
                               f"Pipeline activity '{activity_name}' ({activity_type}) {usage} query property '{query['name']}'.",
                               activity_name, activity_type)
        for proc in get_string_values_by_property(side, ["storedProcedureName", "sqlWriterStoredProcedureName"]):
            parts = split_object_identifier(proc["value"])
            if parts:
                add_candidate_row(rows, seen, pipeline_item, "SQL", "", "", "", parts["source_database"],
                                  parts["schema_name"], parts["object_name"], "stored_procedure", "executes",
                                  "confirmed", definition_path,
                                  f"Pipeline activity '{activity_name}' ({activity_type}) stored procedure property '{proc['name']}'.",
                                  activity_name, activity_type, "")


# %% [markdown]
# ## Invocación de items (Get-InvokedItem) y parámetros de actividad (Get-ActivityParameters)

# %%
def get_invoked_item(activity, item_by_workspace_and_id):
    activity_type = activity.get("type", "")
    type_props = activity.get("typeProperties") or {}
    workspace_id = type_props.get("workspaceId", "")
    target_id = ""
    if activity_type == "TridentNotebook":
        target_id = type_props.get("notebookId", "")
    elif activity_type == "InvokeCopyJob":
        target_id = type_props.get("copyJobId", "")
    elif activity_type == "InvokePipeline":
        target_id = type_props.get("pipelineId", "")
    if not target_id:
        return None
    key = normalize_key(f"{workspace_id}|{target_id}")
    return item_by_workspace_and_id.get(key) if key else None


def get_activity_parameters(activity):
    type_props = activity.get("typeProperties") or {}
    params_object = type_props.get("parameters") or type_props.get("baseParameters")
    if not params_object:
        return ""
    flat = {}
    for name, entry in params_object.items():
        value = entry.get("value") if isinstance(entry, dict) else entry
        flat[name] = "" if value is None else str(value)
    return json.dumps(flat) if flat else ""


# %% [markdown]
# ## Herencia de candidatos (Copy-InheritedRow -- confidence SIEMPRE "likely", fidelidad con el original)

# %%
def copy_inherited_row(rows, seen, pipeline_item, source_row, invocation):
    add_candidate_row(
        rows, seen, pipeline_item,
        source_row.get("source_type", ""), source_row.get("source_name", ""), source_row.get("source_qualified_name", ""),
        source_row.get("source_server", ""), source_row.get("source_database", ""), source_row.get("schema_name", ""),
        source_row.get("object_name", ""), source_row.get("object_type", ""), source_row.get("usage_type", ""),
        "likely", f"pipeline-content.json > {source_row.get('definition_path', '')}",
        f"Pipeline activity '{invocation['activity_name']}' ({invocation['activity_type']}) invokes "
        f"'{invocation['invoked_item_qualified_name']}'; inherited object evidence. {source_row.get('evidence', '')}",
        invocation["activity_name"], invocation["activity_type"], invocation["invoked_item_qualified_name"],
    )


# %% [markdown]
# ## Cargar workspaces + items + candidatos ya conocidos (dbo.bronze_*)

# %%
connection = connect_warehouse()
cursor = connection.cursor()
cursor.execute("SELECT workspace_name, technical_id FROM dbo.bronze_workspaces")
workspace_id_by_name = {row[0]: row[1] for row in cursor.fetchall()}

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

item_by_workspace_and_id = {}
for item in all_items:
    workspace_id = workspace_id_by_name.get(item["workspace_name"], "")
    key = normalize_key(f"{workspace_id}|{item['technical_id']}")
    if key:
        item_by_workspace_and_id[key] = item

# See the module docstring: the notebook_super_lineage_objects.csv half of
# 19's original "existingRows" input isn't included here (its source
# script, 52, isn't ported yet) -- only what NB_Discover_Object_Lineage
# already wrote.
existing_objects_by_item = {}
try:
    cursor.execute(f"SELECT {', '.join(CANDIDATE_COLUMNS[:17])} FROM dbo.bronze_item_object_lineage_candidates")
    for r in cursor.fetchall():
        row = dict(zip(CANDIDATE_COLUMNS[:17], r))
        existing_objects_by_item.setdefault(row["item_qualified_name"], []).append(row)
except pyodbc.Error:
    connection.rollback()
    print("[pipeline-object-lineage] dbo.bronze_item_object_lineage_candidates not found -- run NB_Discover_Object_Lineage first for full inheritance. Continuing with direct candidates only.")

pipeline_items = [i for i in all_items if i["item_type"] == "DataPipeline"]
filter_set = {n.strip().lower() for n in re.split(r"[;,]", WorkspaceNameFilter or "") if n.strip()}
if filter_set:
    pipeline_items = [i for i in pipeline_items if i["workspace_name"].strip().lower() in filter_set]
print(f"Target pipelines: {len(pipeline_items)} ({'filtered: ' + WorkspaceNameFilter if filter_set else 'full tenant'})")

# %% [markdown]
# ## Ejecutar: getDefinition + caminar actividades, por pipeline

# %%
fabric_token = acquire_token("https://api.fabric.microsoft.com/.default")
fabric_headers = {"Authorization": f"Bearer {fabric_token}", "Content-Type": "application/json"}

direct_rows_by_pipeline = {}
pipeline_invocations_by_item = {}
activity_rows = []
processed = 0
success_count = 0

for pipeline in pipeline_items:
    processed += 1
    if processed % 10 == 0:
        print(f"Processed {processed} / {len(pipeline_items)} pipeline definitions...")
        fabric_token = acquire_token("https://api.fabric.microsoft.com/.default")
        fabric_headers["Authorization"] = f"Bearer {fabric_token}"

    workspace_id = workspace_id_by_name.get(pipeline["workspace_name"], "")
    if not workspace_id:
        continue
    result = get_item_definition(workspace_id, pipeline["technical_id"], fabric_headers)
    if not result["ok"]:
        continue
    success_count += 1

    pipeline_rows = []
    seen_direct = set()
    for part in decode_definition_parts(result["payload"]):
        if part["path"] != "pipeline-content.json" or not part["text"]:
            continue
        try:
            payload = json.loads(part["text"])
        except json.JSONDecodeError:
            continue
        activities = ((payload.get("properties") or {}).get("activities")) or []
        for activity in activities:
            activity_name = activity.get("name", "")
            activity_type = activity.get("type", "")
            invoked_item = get_invoked_item(activity, item_by_workspace_and_id)
            activity_parameters = get_activity_parameters(activity)
            if invoked_item:
                pipeline_invocations_by_item.setdefault(pipeline["qualified_name"], []).append({
                    "activity_name": activity_name, "activity_type": activity_type,
                    "invoked_item_qualified_name": invoked_item["qualified_name"], "invoked_item_type": invoked_item["item_type"],
                })

            depends_on = activity.get("dependsOn") or [None]
            for dependency in depends_on:
                depends_activity = (dependency or {}).get("activity", "") if dependency else ""
                conditions = ";".join(dependency.get("dependencyConditions", [])) if dependency else ""
                activity_rows.append({
                    "workspace_name": pipeline["workspace_name"], "workspace_environment": pipeline.get("workspace_environment", ""),
                    "pipeline_name": pipeline["item_name"], "pipeline_qualified_name": pipeline["qualified_name"],
                    "activity_name": activity_name, "activity_type": activity_type,
                    "depends_on_activity": depends_activity, "dependency_conditions": conditions,
                    "invoked_item_qualified_name": invoked_item["qualified_name"] if invoked_item else "",
                    "invoked_item_type": invoked_item["item_type"] if invoked_item else "",
                    "parameters": activity_parameters,
                })

            try:
                add_direct_activity_candidates(pipeline_rows, seen_direct, pipeline, activity, part["path"], item_by_workspace_and_id)
            except Exception as exc:  # noqa: BLE001 - one malformed activity must not abort the whole pipeline
                print(f"[pipeline-object-lineage] Skipped activity '{activity_name}' in '{pipeline['qualified_name']}': {exc}")

    direct_rows_by_pipeline[pipeline["qualified_name"]] = pipeline_rows

print(f"Definitions succeeded: {success_count} / {len(pipeline_items)}. Activity rows: {len(activity_rows)}.")

# %% [markdown]
# ## Fusionar filas directas + propagación por invocación (hasta 8 pasadas, igual que el original)

# %%
output_rows = []
seen_output = set()

for pipeline in pipeline_items:
    for row in direct_rows_by_pipeline.get(pipeline["qualified_name"], []):
        invocation = {"activity_name": row["activity_name"], "activity_type": row["activity_type"], "invoked_item_qualified_name": ""}
        copy_inherited_row(output_rows, seen_output, pipeline, row, invocation)

for _pass_number in range(8):
    rows_by_item = {}
    for row in output_rows:
        rows_by_item.setdefault(row["item_qualified_name"], []).append(row)

    before_count = len(output_rows)
    for pipeline in pipeline_items:
        for invocation in pipeline_invocations_by_item.get(pipeline["qualified_name"], []):
            target = invocation["invoked_item_qualified_name"]
            for row in existing_objects_by_item.get(target, []):
                copy_inherited_row(output_rows, seen_output, pipeline, row, invocation)
            for row in rows_by_item.get(target, []):
                copy_inherited_row(output_rows, seen_output, pipeline, row, invocation)
    if len(output_rows) == before_count:
        break

print(f"Direct/inherited object candidates: {len(output_rows)} across {len({r['item_qualified_name'] for r in output_rows})} pipelines.")

# %% [markdown]
# ## Escribir en el Warehouse, conservando lo que pertenece a workspaces
# fuera de WorkspaceNameFilter (en ambas tablas)

# %%
# Reconectar con un token de base de datos fresco -- la conexion de arriba
# lleva abierta desde antes del bucle por pipeline (todo el tenant, con
# getDefinition + reintentos), el mismo patron que ya causo un fallo real
# de conexion ("TCP Provider: Error code 0x20") en NB_Discover_
# Dependencies.py -- mismo fix aplicado aqui preventivamente. Las
# funciones de abajo referencian `connection`/`cursor` por closure, asi
# que basta con reasignarlas antes de llamarlas.
connection.close()
connection = connect_warehouse()
cursor = connection.cursor()


def retain_outside_filter(table_name, columns):
    if not filter_set:
        return []
    try:
        cursor.execute(f"SELECT {', '.join(columns)} FROM dbo.{table_name}")
        return [dict(zip(columns, r)) for r in cursor.fetchall() if str(r[0]).strip().lower() not in filter_set]
    except pyodbc.Error:
        connection.rollback()
        return []


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


retained_candidates = retain_outside_filter("bronze_pipeline_object_lineage_candidates", CANDIDATE_COLUMNS)
retained_activities = retain_outside_filter("bronze_pipeline_activity_lineage", ACTIVITY_COLUMNS)

replace_table("bronze_pipeline_object_lineage_candidates", CANDIDATE_COLUMNS, retained_candidates + output_rows)
replace_table("bronze_pipeline_activity_lineage", ACTIVITY_COLUMNS, retained_activities + activity_rows)

connection.close()
print("Done.")
