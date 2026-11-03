# NB_Discover_Dependencies
#
# Fuente para un notebook Python de Fabric -- segundo paso del pipeline de
# descubrimiento nativo, después de NB_Discover_Workspaces_Items (ver
# docs/105_fabric_native_discovery_setup.md para el paso a paso completo:
# Key Vault, cuenta de servicio, Data Pipeline con las dos actividades
# encadenadas). Cada bloque "# %%" es una celda -- pégalas en orden.
#
# Réplica fiel de scripts/04_analyze_items.ps1 (Fase 4), la ÚNICA fase que
# escribe index/dependencies.csv hoy (confirmado 2026-07-24 revisando los
# ~30 scripts que hacen match con "dependencies.csv": todos los demás solo
# LEEN ese archivo para construir artefactos derivados -- grafo,
# orquestación, JSON del explorador, tablas bronze). Extrae, por cada item:
#   - Conexiones externas confirmadas (API de conexiones).
#   - Coincidencias de GUID dentro de las partes decodificadas de
#     getDefinition (pipelines, CopyJobs, Dataflows, Eventstreams, Reflex,
#     GraphQL, KQL, funciones de usuario, librerías de variables, Report/
#     PaginatedReport) -- confirmado, no heurística.
#   - Emparejamiento Lakehouse<->SQL endpoint vía la propia API de detalle
#     del Lakehouse (sqlEndpointProperties.id), y atajos de OneLake.
#   - Dos heurísticas por nombre (report/modelo semántico, SQL endpoint/
#     lakehouse) cuando no hay coincidencia exacta por GUID.
#
# Deliberadamente NO incluido (mismo alcance que 04, que tampoco lo hace):
# linaje derivado de parsear el CÓDIGO de un notebook o el TMDL de un
# modelo semántico -- eso vive en scripts 09/16/18/19/51-54, una pieza
# bastante más grande, no portada todavía. Node.js: si algún día se porta,
# es un tercer notebook aparte, no una extensión de este.
#
# Self-contained a propósito (no usa %run sobre NB_Discover_Workspaces_
# Items): ese notebook termina con su propia celda "Ejecutar" que ya
# escribe en el Warehouse -- traerla via %run la re-ejecutaría entera cada
# vez. Duplica un puñado de helpers pequeños (token/conexión) en vez de
# depender de eso, mismo criterio que ya usa este proyecto en local (ver
# el comentario de Get-ServicePrincipalAccessToken en
# scripts/67_upload_bronze_to_warehouse.ps1: copias pequeñas por script,
# no un import compartido).

# %% [markdown]
# ## Configuración
# Mismos valores que en NB_Discover_Workspaces_Items -- copia aquí los que
# ya rellenaste allí.

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

# Mismo alcance máximo por defecto que 04_analyze_items.ps1 (política de
# profundidad máxima, cadencia semanal, no interactiva). Notebook y
# SemanticModel NO están aquí a propósito -- ver cabecera del archivo.
DEFINITION_ITEM_TYPES = {
    "DataPipeline", "CopyJob", "Dataflow", "Eventstream", "Reflex",
    "GraphQLApi", "KQLQueryset", "KQLDashboard", "UserDataFunction",
    "VariableLibrary", "Report", "PaginatedReport",
}

DEPENDENCY_COLUMNS = [
    "from_qualified_name", "to_qualified_name", "relationship_type",
    "source_system", "evidence", "confidence", "notes",
]
SOURCE_SYSTEM = "Fabric REST API (notebook service principal)"
GUID_PATTERN = re.compile(r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")

# %% [markdown]
# ## Parámetros
# Marca esta celda como celda de parámetros en Fabric. El pipeline la
# sobreescribe con el mismo WorkspaceNameFilter que recibe
# NB_Discover_Workspaces_Items.

# %%
WorkspaceNameFilter = ""

# %% [markdown]
# ## Autenticación y Warehouse (mismo patrón que NB_Discover_Workspaces_Items)

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


def limit_text(text, max_length=500):
    if not text:
        return ""
    clean = re.sub(r"\s+", " ", text).strip()
    return clean if len(clean) <= max_length else clean[: max_length - 3] + "..."


# %% [markdown]
# ## Helpers Fabric REST: paginación, reintento en 429, y el sondeo LRO de
# getDefinition (equivalente a Invoke-FabricWebRequest/Get-ItemDefinition
# en scripts/04_analyze_items.ps1).

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


def fabric_get_paged(path, headers, value_key="value"):
    values = []
    next_path = path
    while next_path:
        response = fabric_request("GET", next_path, headers)
        if response.status_code >= 400:
            return {"ok": False, "values": [], "error": response.text[:500]}
        payload = response.json() if response.content else {}
        values.extend(payload.get(value_key, []))
        continuation_uri = payload.get("continuationUri")
        continuation_token = payload.get("continuationToken")
        if continuation_uri:
            next_path = continuation_uri
        elif continuation_token:
            next_path = f"{path}?continuationToken={requests.utils.quote(str(continuation_token))}"
        else:
            next_path = None
    return {"ok": True, "values": values, "error": ""}


def get_definition_path(item_type, workspace_id, item_id):
    path = f"workspaces/{workspace_id}/items/{item_id}/getDefinition"
    return path


def get_item_definition(workspace_id, item_id, item_type, headers):
    """Mirrors Get-ItemDefinition in 04_analyze_items.ps1: a synchronous
    200, or a 202-accepted long-running operation polled via
    operations/{id} until Succeeded/Failed/exhausted."""
    path = get_definition_path(item_type, workspace_id, item_id)
    response = fabric_request("POST", path, headers)

    if response.status_code == 200:
        return {"ok": True, "payload": response.json(), "error": ""}
    if response.status_code != 202:
        return {"ok": False, "payload": None, "error": f"{response.status_code} {response.text[:300]}"}

    operation_id = response.headers.get("x-ms-operation-id")
    if not operation_id:
        location = response.headers.get("Location", "")
        match = re.search(r"[0-9a-fA-F-]{36}", location)
        operation_id = match.group(0) if match else None
    if not operation_id:
        return {"ok": False, "payload": None, "error": "LRO accepted but no operation id was returned."}

    for _poll in range(MAX_OPERATION_POLLS):
        retry_after = response.headers.get("Retry-After")
        delay_seconds = int(retry_after) if (retry_after or "").isdigit() else 2
        delay_seconds = min(delay_seconds, MAX_OPERATION_DELAY_SECONDS) if MAX_OPERATION_DELAY_SECONDS else delay_seconds
        time.sleep(delay_seconds)

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
            padded = part["payload"].strip()
            padded += "=" * (-len(padded) % 4)
            text = base64.b64decode(padded).decode("utf-8", errors="replace")
        except Exception:  # noqa: BLE001 - a single malformed part must not abort the item
            text = ""
        parts.append({"path": part.get("path", ""), "text": text})
    return parts


# VariableLibrary definitions were already being fetched and decoded above
# (2026-08-25) purely to regex-scan them for embedded item-id GUIDs like
# every other definition type -- the actual variables (name/type/value)
# inside got thrown away afterwards. Schema confirmed live against 2 real
# tenant items via getDefinition (variables.json: name/note/type/value,
# value shaped per type -- {itemId,workspaceId} for ItemReference, a plain
# scalar otherwise; settings.json: valueSetsOrder; valueSets/<Name>.json:
# name + variableOverrides). Python port of Format-VariableLibraryValue/
# Get-VariableLibraryRows in scripts/04_analyze_items.ps1 -- keep both in
# sync if this logic changes.
import json as _json


def format_variable_library_value(value, variable_type, item_by_id):
    if variable_type == "ItemReference" and isinstance(value, dict):
        ref_item_id = str(value.get("itemId", "")).lower()
        target = item_by_id.get(ref_item_id) if ref_item_id else None
        resolved = target["qualified_name"] if target else ""
        return (resolved if resolved else f"itemId={ref_item_id}"), resolved
    # Scalar types (String, Boolean, Integer, ...) -- Fabric's variable-
    # library schema doesn't document every possible variable_type value,
    # so this branch is deliberately generic: stringify whatever json.loads
    # already gave us.
    return ("" if value is None else str(value)), ""


def get_variable_library_rows(decoded_parts, workspace_name, item_name, qualified_name, item_by_id):
    rows = []
    variables_text = next((p["text"] for p in decoded_parts if p["path"] == "variables.json" and p["text"]), "")
    if not variables_text:
        return rows
    try:
        variables_json = _json.loads(variables_text)
    except ValueError:
        return rows

    variable_type_by_name = {}
    for variable in variables_json.get("variables", []) or []:
        variable_name = variable.get("name", "")
        if not variable_name:
            continue
        variable_type = variable.get("type", "")
        variable_type_by_name[variable_name] = variable_type
        value_text, resolved = format_variable_library_value(variable.get("value"), variable_type, item_by_id)
        rows.append({
            "workspace_name": workspace_name, "item_name": item_name, "qualified_name": qualified_name,
            "variable_name": variable_name, "variable_type": variable_type, "value_set_name": "",
            "variable_value": value_text, "resolved_item_qualified_name": resolved,
            "variable_note": variable.get("note", ""),
        })

    # valueSets/<Name>.json parts -- per-value-set overrides on top of the
    # base variables above. variableOverrides was EMPTY in both real
    # VariableLibrary items spot-checked live (2026-08-25), so the entry
    # shape assumed here ({name, value}, mirroring a base variable) is
    # inferred from variables.json's own schema, NOT confirmed against a
    # populated example. Skips an entry silently rather than guessing
    # further if it doesn't match.
    for part in decoded_parts:
        if not part["path"].startswith("valueSets/") or not part["text"]:
            continue
        try:
            value_set_json = _json.loads(part["text"])
        except ValueError:
            continue
        value_set_name = value_set_json.get("name", "")
        for override in value_set_json.get("variableOverrides", []) or []:
            override_name = override.get("name", "")
            if not override_name:
                continue
            override_type = variable_type_by_name.get(override_name, "")
            value_text, resolved = format_variable_library_value(override.get("value"), override_type, item_by_id)
            rows.append({
                "workspace_name": workspace_name, "item_name": item_name, "qualified_name": qualified_name,
                "variable_name": override_name, "variable_type": override_type, "value_set_name": value_set_name,
                "variable_value": value_text, "resolved_item_qualified_name": resolved, "variable_note": "",
            })
    return rows


VARIABLE_LIBRARY_COLUMNS = [
    "workspace_name", "item_name", "qualified_name", "variable_name", "variable_type",
    "value_set_name", "variable_value", "resolved_item_qualified_name", "variable_note",
]


def get_relationship_type(source_type, target_type):
    if source_type in ("Report", "PaginatedReport", "Exploration") and target_type == "SemanticModel":
        return "uses_model"
    if source_type == "SemanticModel" and target_type in ("Lakehouse", "Warehouse", "SQLEndpoint", "Dataflow"):
        return "reads_from"
    if source_type == "DataPipeline" and target_type in ("Notebook", "DataPipeline", "CopyJob", "SparkJobDefinition", "UserDataFunction"):
        return "executes"
    if source_type == "DataPipeline" and target_type == "SemanticModel":
        return "refreshes"
    if source_type in ("Notebook", "Dataflow") and target_type in ("Lakehouse", "Warehouse", "SQLEndpoint", "SemanticModel"):
        return "reads_from"
    return "depends_on"


def connection_qualified_name(connection):
    connection_id = connection.get("id", "")
    display_name = connection.get("displayName", "")
    details = connection.get("connectionDetails") or {}
    label = display_name or details.get("path", "") or connection_id
    type_name = details.get("type", "") or "Unknown"
    return f"External Connection / {type_name} / {limit_text(label, 180)}"


# %% [markdown]
# ## Registro de dependencias (dedup + acumulación, igual que
# Register-Dependency en 04_analyze_items.ps1)

# %%
dependency_rows = []
dependency_keys = set()
variable_library_rows = []


def register_dependency(from_qn, to_qn, relationship_type, evidence, confidence, notes=""):
    if not from_qn or not to_qn or from_qn == to_qn:
        return
    key = (from_qn, to_qn, relationship_type)
    if key in dependency_keys:
        return
    dependency_keys.add(key)
    dependency_rows.append({
        "from_qualified_name": from_qn,
        "to_qualified_name": to_qn,
        "relationship_type": relationship_type,
        "source_system": SOURCE_SYSTEM,
        "evidence": limit_text(evidence, 500),
        "confidence": confidence,
        "notes": limit_text(notes, 500),
    })


# %% [markdown]
# ## Cargar workspaces + items ya descubiertos (dbo.bronze_workspaces / dbo.bronze_items)

# %%
connection = connect_warehouse()
cursor = connection.cursor()
cursor.execute("SELECT workspace_name, technical_id FROM dbo.bronze_workspaces")
workspace_id_by_name = {row[0]: row[1] for row in cursor.fetchall()}

cursor.execute(
    "SELECT workspace_name, item_type, item_name, qualified_name, technical_id "
    "FROM dbo.bronze_items WHERE status = 'discovered'"
)
item_rows = [
    {"workspace_name": r[0], "item_type": r[1], "item_name": r[2], "qualified_name": r[3], "technical_id": r[4]}
    for r in cursor.fetchall()
]
if not item_rows:
    raise RuntimeError("dbo.bronze_items has no discovered rows -- run NB_Discover_Workspaces_Items first.")

item_by_id = {row["technical_id"].lower(): row for row in item_rows if row["technical_id"]}
items_by_workspace = {}
for row in item_rows:
    items_by_workspace.setdefault(row["workspace_name"], []).append(row)

filter_set = {n.strip().lower() for n in re.split(r"[;,]", WorkspaceNameFilter or "") if n.strip()}
workspace_names_to_process = sorted(
    name for name in items_by_workspace
    if not filter_set or name.strip().lower() in filter_set
)
print(f"Workspaces to process: {len(workspace_names_to_process)} of {len(items_by_workspace)}")

# %% [markdown]
# ## Fase 1 -- Conexiones + getDefinition, por item

# %%
fabric_token = acquire_token("https://api.fabric.microsoft.com/.default")
fabric_headers = {"Authorization": f"Bearer {fabric_token}", "Content-Type": "application/json"}

connection_success_count = 0
definition_success_count = 0
processed_count = 0

for workspace_name in workspace_names_to_process:
    workspace_id = workspace_id_by_name.get(workspace_name, "")
    if not workspace_id:
        continue
    for item in sorted(items_by_workspace[workspace_name], key=lambda r: (r["item_type"], r["item_name"])):
        processed_count += 1
        if processed_count % 50 == 0:
            print(f"Processed {processed_count} items...")
            fabric_token = acquire_token("https://api.fabric.microsoft.com/.default")
            fabric_headers["Authorization"] = f"Bearer {fabric_token}"

        item_type = item["item_type"]
        item_id = item["technical_id"]
        qualified_name = item["qualified_name"]
        if not item_id:
            continue

        connections_result = fabric_get_paged(f"workspaces/{workspace_id}/items/{item_id}/connections", fabric_headers)
        if connections_result["ok"]:
            connection_success_count += 1
            for conn in connections_result["values"]:
                connection_name = connection_qualified_name(conn)
                details_type = (conn.get("connectionDetails") or {}).get("type", "")
                register_dependency(
                    qualified_name, connection_name, "depends_on",
                    f"Fabric item connections API returned a {details_type} connection for this item.",
                    "confirmed", f"Connectivity type: {conn.get('connectivityType', '')}",
                )

        if item_type in DEFINITION_ITEM_TYPES:
            definition_result = get_item_definition(workspace_id, item_id, item_type, fabric_headers)
            if definition_result["ok"]:
                definition_success_count += 1
                decoded_parts = decode_definition_parts(definition_result["payload"])
                if item_type == "VariableLibrary":
                    variable_library_rows.extend(get_variable_library_rows(
                        decoded_parts, workspace_name, item["item_name"], qualified_name, item_by_id,
                    ))
                for part in decoded_parts:
                    if not part["text"]:
                        continue
                    for match in GUID_PATTERN.finditer(part["text"]):
                        matched_id = match.group(0).lower()
                        target_item = item_by_id.get(matched_id)
                        if not target_item or target_item["qualified_name"] == qualified_name:
                            continue
                        relationship_type = get_relationship_type(item_type, target_item["item_type"])
                        register_dependency(
                            qualified_name, target_item["qualified_name"], relationship_type,
                            f"Decoded definition part '{part['path']}' references the target Fabric item id.",
                            "confirmed", "Definition-based relationship.",
                        )
                        if relationship_type == "uses_model":
                            register_dependency(
                                target_item["qualified_name"], qualified_name, "serves_report",
                                f"Decoded definition part '{part['path']}' of the report references this semantic model's item id.",
                                "confirmed", "Inverse of definition-based relationship.",
                            )

print(f"Connections read: {connection_success_count} items. Definitions read: {definition_success_count} items.")

# %% [markdown]
# ## Fase 2 -- Emparejamiento Lakehouse/SQL endpoint, atajos OneLake, heurísticas por nombre

# %%
for workspace_name in workspace_names_to_process:
    workspace_id = workspace_id_by_name.get(workspace_name, "")
    workspace_items = items_by_workspace[workspace_name]
    if not workspace_id:
        continue

    for lakehouse in (i for i in workspace_items if i["item_type"] == "Lakehouse"):
        lakehouse_id = lakehouse["technical_id"]
        if not lakehouse_id:
            continue
        detail_response = fabric_request("GET", f"workspaces/{workspace_id}/lakehouses/{lakehouse_id}", fabric_headers)
        if detail_response.status_code >= 400:
            continue
        sql_endpoint_id = ((detail_response.json().get("properties") or {}).get("sqlEndpointProperties") or {}).get("id", "")
        sql_endpoint_id = (sql_endpoint_id or "").lower()
        sql_endpoint_item = item_by_id.get(sql_endpoint_id)
        if sql_endpoint_item:
            register_dependency(
                sql_endpoint_item["qualified_name"], lakehouse["qualified_name"], "depends_on",
                "Lakehouse detail API sqlEndpointProperties.id confirms the paired SQL endpoint.",
                "confirmed", "Lakehouse API-confirmed SQL endpoint pairing.",
            )

    for host in (i for i in workspace_items if i["item_type"] in ("Lakehouse", "Warehouse")):
        host_id = host["technical_id"]
        if not host_id:
            continue
        shortcuts_response = fabric_request("GET", f"workspaces/{workspace_id}/items/{host_id}/shortcuts", fabric_headers)
        if shortcuts_response.status_code >= 400:
            continue
        for shortcut in (shortcuts_response.json() or {}).get("value", []):
            target = shortcut.get("target") or {}
            if target.get("type") != "OneLake" or "oneLake" not in target:
                continue
            target_item_id = (target["oneLake"].get("itemId") or "").lower()
            target_item = item_by_id.get(target_item_id)
            if not target_item:
                continue
            register_dependency(
                host["qualified_name"], target_item["qualified_name"], "depends_on",
                f"OneLake shortcut '{shortcut.get('path', '')}/{shortcut.get('name', '')}' points to this item's OneLake data.",
                "confirmed", "OneLake shortcut (structural, not name-based or parsed).",
            )

    semantic_models_by_name = {}
    for model in (i for i in workspace_items if i["item_type"] == "SemanticModel"):
        semantic_models_by_name.setdefault(model["item_name"].lower(), []).append(model)
    for report in (i for i in workspace_items if i["item_type"] in ("Report", "PaginatedReport", "Exploration")):
        matches = semantic_models_by_name.get(report["item_name"].lower(), [])
        if len(matches) == 1:
            model = matches[0]
            register_dependency(
                report["qualified_name"], model["qualified_name"], "uses_model",
                "Report and semantic model share the same real name in the same workspace.",
                "likely", "Name-based Fabric pairing heuristic; confirm in Phase 5 if no definition edge exists.",
            )
            register_dependency(
                model["qualified_name"], report["qualified_name"], "serves_report",
                "Semantic model and report share the same real name in the same workspace.",
                "likely", "Inverse of name-based report/model pairing heuristic.",
            )

    # MLExperiment has no getDefinition content of its own (it's MLflow run
    # metadata, not code -- see NB_Discover_Object_Lineage.py's ITEM_TYPES,
    # deliberately excluded there) but Fabric always creates it alongside a
    # same-name Notebook in the same workspace, and that notebook already
    # gets full object-lineage extraction. Point the experiment at it so
    # Inspección has somewhere real to go instead of a dead end.
    notebooks_by_name = {}
    for notebook in (i for i in workspace_items if i["item_type"] == "Notebook"):
        notebooks_by_name.setdefault(notebook["item_name"].lower(), []).append(notebook)
    for experiment in (i for i in workspace_items if i["item_type"] == "MLExperiment"):
        matches = notebooks_by_name.get(experiment["item_name"].lower(), [])
        if len(matches) == 1:
            register_dependency(
                experiment["qualified_name"], matches[0]["qualified_name"], "depends_on",
                "ML experiment and notebook share the same real name in the same workspace.",
                "likely", "Name-based Fabric pairing heuristic -- the notebook, not the experiment, carries real object lineage.",
            )

    lakehouses_by_name = {}
    for lakehouse in (i for i in workspace_items if i["item_type"] == "Lakehouse"):
        lakehouses_by_name.setdefault(lakehouse["item_name"].lower(), []).append(lakehouse)
    for sql_endpoint in (i for i in workspace_items if i["item_type"] == "SQLEndpoint"):
        matches = lakehouses_by_name.get(sql_endpoint["item_name"].lower(), [])
        if len(matches) == 1:
            register_dependency(
                sql_endpoint["qualified_name"], matches[0]["qualified_name"], "depends_on",
                "SQL endpoint and lakehouse share the same real name in the same workspace.",
                "likely", "Name-based lakehouse SQL endpoint pairing heuristic.",
            )

confirmed_count = sum(1 for r in dependency_rows if r["confidence"] == "confirmed")
likely_count = sum(1 for r in dependency_rows if r["confidence"] == "likely")
print(f"Dependencies computed: {len(dependency_rows)} ({confirmed_count} confirmed, {likely_count} likely)")

# %% [markdown]
# ## Escribir en el Warehouse (dbo.bronze_dependencies), conservando lo que
# pertenece a workspaces fuera de WorkspaceNameFilter

# %%
# Reconectar con un token de base de datos fresco -- la conexion de la
# celda "Cargar workspaces + items" lleva abierta desde antes de las Fases
# 1 y 2 (miles de items, cientos/miles de llamadas a la API de Fabric con
# reintentos), potencialmente horas -- exactamente el mismo problema que
# ya causo un fallo real (2026-08-17, sabado programado 21:00 UTC:
# NB_Discover_Dependencies murio con "TCP Provider: Error code 0x20" al
# reutilizar esta misma conexion para escribir) y que NB_Discover_
# Workspaces_Items.py ya resuelve reconectando antes de su propia
# escritura final -- mismo fix, aplicado aqui.
connection.close()
connection = connect_warehouse()
cursor = connection.cursor()


def owning_workspace(qualified_name, item_by_qualified_name):
    item = item_by_qualified_name.get(qualified_name)
    return item["workspace_name"] if item else None


item_by_qualified_name = {row["qualified_name"]: row for row in item_rows}

retained_rows = []
if filter_set:
    try:
        cursor.execute(f"SELECT {', '.join(DEPENDENCY_COLUMNS)} FROM dbo.bronze_dependencies")
        for row in cursor.fetchall():
            existing = dict(zip(DEPENDENCY_COLUMNS, row))
            from_workspace = owning_workspace(existing["from_qualified_name"], item_by_qualified_name)
            owned_by_filtered_workspace = from_workspace and from_workspace.strip().lower() in filter_set
            if not owned_by_filtered_workspace:
                retained_rows.append(existing)
    except pyodbc.Error:
        connection.rollback()  # table doesn't exist yet -- nothing to retain

# Re-dedup across retained + freshly computed rows (a row retained from the
# Warehouse could in theory collide with one just computed, if a target
# outside the filter also got touched some other way -- same key shape as
# register_dependency's own dedup above).
combined_by_key = {}
for row in retained_rows + dependency_rows:
    key = (row["from_qualified_name"], row["to_qualified_name"], row["relationship_type"])
    combined_by_key[key] = row
final_rows = sorted(combined_by_key.values(), key=lambda r: (r["from_qualified_name"], r["relationship_type"], r["to_qualified_name"]))

cursor.execute("IF OBJECT_ID('dbo.bronze_dependencies', 'U') IS NOT NULL DROP TABLE dbo.bronze_dependencies;")
column_defs = ", ".join(f"[{c}] VARCHAR(8000)" for c in DEPENDENCY_COLUMNS)
cursor.execute(f"CREATE TABLE dbo.bronze_dependencies ({column_defs});")
connection.commit()
if final_rows:
    placeholders = ", ".join("?" for _ in DEPENDENCY_COLUMNS)
    insert_sql = f"INSERT INTO dbo.bronze_dependencies ({', '.join(f'[{c}]' for c in DEPENDENCY_COLUMNS)}) VALUES ({placeholders})"
    cursor.fast_executemany = True
    cursor.executemany(insert_sql, [[truncate_value(row.get(c, "")) for c in DEPENDENCY_COLUMNS] for row in final_rows])
    connection.commit()
print(f"dbo.bronze_dependencies: {len(final_rows)} row(s) written ({len(retained_rows)} retained, {len(dependency_rows)} freshly computed).")

# %% [markdown]
# ## Escribir en el Warehouse (dbo.bronze_variable_library_catalog) --
# mismo patron de filtro-preservacion que bronze_dependencies arriba, pero
# cada fila ya trae su propio workspace_name (no hace falta owning_workspace).

# %%
retained_variable_rows = []
if filter_set:
    try:
        cursor.execute(f"SELECT {', '.join(VARIABLE_LIBRARY_COLUMNS)} FROM dbo.bronze_variable_library_catalog")
        for row in cursor.fetchall():
            existing = dict(zip(VARIABLE_LIBRARY_COLUMNS, row))
            if existing["workspace_name"].strip().lower() not in filter_set:
                retained_variable_rows.append(existing)
    except pyodbc.Error:
        connection.rollback()  # table doesn't exist yet -- nothing to retain

final_variable_rows = sorted(
    retained_variable_rows + variable_library_rows,
    key=lambda r: (r["workspace_name"], r["item_name"], r["variable_name"], r["value_set_name"]),
)

cursor.execute("IF OBJECT_ID('dbo.bronze_variable_library_catalog', 'U') IS NOT NULL DROP TABLE dbo.bronze_variable_library_catalog;")
variable_column_defs = ", ".join(f"[{c}] VARCHAR(8000)" for c in VARIABLE_LIBRARY_COLUMNS)
cursor.execute(f"CREATE TABLE dbo.bronze_variable_library_catalog ({variable_column_defs});")
connection.commit()
if final_variable_rows:
    variable_placeholders = ", ".join("?" for _ in VARIABLE_LIBRARY_COLUMNS)
    variable_insert_sql = f"INSERT INTO dbo.bronze_variable_library_catalog ({', '.join(f'[{c}]' for c in VARIABLE_LIBRARY_COLUMNS)}) VALUES ({variable_placeholders})"
    cursor.fast_executemany = True
    cursor.executemany(variable_insert_sql, [[truncate_value(row.get(c, "")) for c in VARIABLE_LIBRARY_COLUMNS] for row in final_variable_rows])
    connection.commit()

connection.close()
print(f"dbo.bronze_variable_library_catalog: {len(final_variable_rows)} row(s) written ({len(retained_variable_rows)} retained, {len(variable_library_rows)} freshly computed).")
print("Done.")
