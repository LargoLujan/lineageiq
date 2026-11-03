# NB_Discover_Executions
#
# Fuente para un notebook Python de Fabric -- séptimo paso del pipeline de
# descubrimiento nativo, después de NB_Confirm_Source_Object_Types (ver
# docs/105_fabric_native_discovery_setup.md). Cada bloque "# %%" es una
# celda -- pégalas en orden.
#
# Réplica fiel de scripts/06_discover_executions.ps1: historial de
# ejecuciones (Job Scheduler de Fabric) y horarios programados, para los
# mismos tipos de item que el original (DataPipeline, Notebook,
# SemanticModel, CopyJob, Dataflow, Eventstream, Reflex, KQLQueryset,
# KQLDashboard, UserDataFunction) -- SemanticModel vía la API de Power BI
# (historial/horario de refresco), el resto vía el Job Scheduler de
# Fabric. Sin IA/LLM, solo llamadas REST directas, igual que el original.
#
# Escribe en dbo.bronze_executions -- mismas 24 columnas que index/
# executions.csv ya usa, así que backend/scripts/11_build_lineage_
# explorer_fast.py (adaptado en NB_Build_Lineage_Explorer) puede leerla
# sin cambios de esquema.
#
# Es la ÚNICA entrada que 11_build_lineage_explorer_fast.py exige que
# exista (junto con workspaces/items/dependencies) -- sin esto, el
# ensamblador final del grafo no arranca en absoluto.
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

import time
import requests

FABRIC_API_BASE_URL = "https://api.fabric.microsoft.com/v1"
POWER_BI_API_BASE_URL = "https://api.powerbi.com/v1.0/myorg"

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

REQUEST_DELAY_SECONDS = 0.35
RETRY_COUNT = 5
POWER_BI_REFRESH_HISTORY_TOP = 60

# Mismo conjunto que $ExecutionItemTypes en 06_discover_executions.ps1.
EXECUTION_ITEM_TYPES = {
    "DataPipeline", "Notebook", "SemanticModel", "CopyJob", "Dataflow",
    "Eventstream", "Reflex", "KQLQueryset", "KQLDashboard", "UserDataFunction",
}

# Mismo mapeo que Get-CandidateScheduleJobTypes en el original -- job types
# a probar por tipo de item cuando no hay ninguno conocido todavía por un
# job instance real.
CANDIDATE_SCHEDULE_JOB_TYPES = {
    "DataPipeline": ["Execute", "DefaultJob"],
    "Notebook": ["RunNotebook", "Execute", "DefaultJob"],
    "CopyJob": ["Execute", "DefaultJob"],
    "Dataflow": ["Refresh", "DefaultJob"],
    "Eventstream": ["DefaultJob"],
    "Reflex": ["DefaultJob"],
    "KQLQueryset": ["DefaultJob"],
    "KQLDashboard": ["DefaultJob"],
    "UserDataFunction": ["DefaultJob"],
}

EXECUTION_COLUMNS = [
    "record_type", "workspace_name", "item_name", "item_type", "qualified_name",
    "job_type", "trigger_type", "schedule_id", "schedule_enabled", "scheduled_time",
    "schedule_timezone", "schedule_frequency", "schedule_config", "job_instance_id",
    "root_activity_id", "start_time", "end_time", "duration_seconds", "status",
    "failure_reason", "source_system", "evidence", "technical_id", "notes",
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
    import struct

    raw = token.encode("utf-16-le")
    return struct.pack(f"<I{len(raw)}s", len(raw), raw)


def pick_odbc_driver():
    # Ver la misma nota en NB_Discover_Workspaces_Items.py -- Fabric no
    # siempre trae "ODBC Driver 17 for SQL Server" instalado.
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
        # 2026-08-21: mismo fix ya aplicado en NB_Extract_Object_Column_Catalog
        # (2026-08-20) -- row-by-row executemany (incluso con
        # fast_executemany=True) no consigue el acelerón de bulk-copy contra
        # Fabric Warehouse (motor analitico distribuido, no transaccional):
        # cada set de parametros paga overhead real de round-trip/compilacion
        # por sentencia. Confirmado como la causa real de que este notebook
        # pareciera "50x mas lento de lo esperado" -- el bucle de descubrimiento
        # por item termina en segundos, pero preserved_job_rows conserva miles
        # de filas historicas fuera del filtro actual y el INSERT fila a fila
        # de esas miles de filas es lo que se comia el tiempo. Batches VALUES
        # multi-fila convierten miles de sentencias en decenas. batch_size=60
        # (no 100 como en Object_Column_Catalog) porque esta tabla tiene 24
        # columnas, no 14 -- 60*24=1440 parametros, bajo el limite ~2100 de
        # SQL Server.
        batch_size = 60
        placeholders_one_row = "(" + ", ".join("?" for _ in columns) + ")"
        column_list = ", ".join(f"[{c}]" for c in columns)
        for batch_start in range(0, len(rows), batch_size):
            batch = rows[batch_start:batch_start + batch_size]
            values_sql = ", ".join(placeholders_one_row for _ in batch)
            insert_sql = f"INSERT INTO dbo.{table_name} ({column_list}) VALUES {values_sql}"
            params = [truncate_value(row.get(c, "")) for row in batch for c in columns]
            cursor.execute(insert_sql, params)
        connection.commit()
    print(f"[warehouse] dbo.{table_name}: {len(rows)} row(s) written.")


def read_existing_table(connection, table_name, columns):
    cursor = connection.cursor()
    try:
        cursor.execute(f"SELECT {', '.join(columns)} FROM dbo.{table_name}")
    except pyodbc.Error:
        connection.rollback()
        return []  # first-ever run -- table doesn't exist yet
    return [dict(zip(columns, row)) for row in cursor.fetchall()]


# %% [markdown]
# ## Helpers Fabric / Power BI REST (paginación + reintento en 429)

# %%
def api_get(path, headers, base_url, retry_count=RETRY_COUNT):
    url = path if path.startswith("http") else f"{base_url}/{path.lstrip('/')}"
    for attempt in range(retry_count + 1):
        try:
            response = requests.get(url, headers=headers, timeout=120)
        except requests.exceptions.RequestException as exc:
            if attempt < retry_count:
                time.sleep(min(90, 2 ** (attempt + 1)))
                continue
            return {"ok": False, "status_code": None, "error": f"{type(exc).__name__}: {exc}", "payload": None}
        if response.status_code in (429, 503, 504) and attempt < retry_count:
            retry_after = response.headers.get("Retry-After")
            delay = int(retry_after) if retry_after and retry_after.isdigit() else min(90, 2 ** (attempt + 1))
            time.sleep(delay)
            continue
        if response.status_code >= 400:
            return {"ok": False, "status_code": response.status_code, "error": response.text[:500], "payload": None}
        if REQUEST_DELAY_SECONDS:
            time.sleep(REQUEST_DELAY_SECONDS)
        return {"ok": True, "status_code": response.status_code, "error": "", "payload": response.json()}
    return {"ok": False, "status_code": None, "error": "retries exhausted", "payload": None}


def api_get_paged(path, headers, base_url):
    values = []
    next_path = path
    while next_path:
        result = api_get(next_path, headers, base_url)
        if not result["ok"]:
            return {"ok": False, "values": [], "error": result["error"], "status_code": result["status_code"]}
        payload = result["payload"] or {}
        values.extend(payload.get("value") or [])
        continuation_token = payload.get("continuationToken")
        next_path = payload.get("continuationUri") or (
            f"{path}{'&' if '?' in path else '?'}continuationToken={continuation_token}" if continuation_token else None
        )
    return {"ok": True, "values": values, "error": "", "status_code": 200}


def field(obj, *names):
    if not obj:
        return ""
    for name in names:
        value = obj.get(name)
        if value is not None:
            return str(value)
    return ""


def duration_seconds(start_time, end_time):
    from datetime import datetime

    if not start_time or not end_time:
        return ""
    try:
        start = datetime.fromisoformat(start_time.replace("Z", "+00:00"))
        end = datetime.fromisoformat(end_time.replace("Z", "+00:00"))
        return round((end - start).total_seconds(), 3)
    except ValueError:
        return ""


def compact_json(value, max_len=1200):
    import json

    if value is None:
        return ""
    try:
        text = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    except (TypeError, ValueError):
        text = str(value)
    return text if len(text) <= max_len else text[: max_len - 3] + "..."


# %% [markdown]
# ## Descubrimiento: job instances + schedules por item

# %%
def discover_for_semantic_model(item, workspace_id, item_id, pbi_headers, rows):
    refreshes_path = f"groups/{workspace_id}/datasets/{item_id}/refreshes?$top={POWER_BI_REFRESH_HISTORY_TOP}"
    refresh_result = api_get_paged(refreshes_path, pbi_headers, POWER_BI_API_BASE_URL)
    if refresh_result["ok"]:
        for refresh in refresh_result["values"]:
            start_time = field(refresh, "startTime")
            end_time = field(refresh, "endTime")
            failure_reason = field(refresh, "serviceExceptionJson")
            if not failure_reason and refresh.get("refreshAttempts"):
                failure_reason = compact_json(refresh["refreshAttempts"])
            rows.append({
                "record_type": "job_instance", "workspace_name": item["workspace_name"],
                "item_name": item["item_name"], "item_type": item["item_type"], "qualified_name": item["qualified_name"],
                "job_type": "SemanticModelRefresh", "trigger_type": field(refresh, "refreshType"),
                "schedule_id": "", "schedule_enabled": "", "scheduled_time": "", "schedule_timezone": "",
                "schedule_frequency": "", "schedule_config": "",
                "job_instance_id": field(refresh, "requestId"), "root_activity_id": field(refresh, "requestId"),
                "start_time": start_time, "end_time": end_time, "duration_seconds": duration_seconds(start_time, end_time),
                "status": field(refresh, "status"), "failure_reason": failure_reason,
                "source_system": "Power BI REST API (notebook service principal)",
                "evidence": "Power BI dataset refresh history API.", "technical_id": item_id, "notes": "Semantic model refresh history.",
            })

    schedule_result = api_get(f"groups/{workspace_id}/datasets/{item_id}/refreshSchedule", pbi_headers, POWER_BI_API_BASE_URL)
    if schedule_result["ok"] and schedule_result["payload"]:
        schedule = schedule_result["payload"]
        days = ",".join(schedule.get("days") or [])
        times = ",".join(schedule.get("times") or [])
        rows.append({
            "record_type": "schedule", "workspace_name": item["workspace_name"],
            "item_name": item["item_name"], "item_type": item["item_type"], "qualified_name": item["qualified_name"],
            "job_type": "SemanticModelRefresh", "trigger_type": "Scheduled",
            "schedule_id": "", "schedule_enabled": field(schedule, "enabled"), "scheduled_time": times,
            "schedule_timezone": field(schedule, "localTimeZoneId"),
            "schedule_frequency": f"days={days}; times={times}", "schedule_config": compact_json(schedule),
            "job_instance_id": "", "root_activity_id": "", "start_time": "", "end_time": "", "duration_seconds": "",
            "status": "Enabled" if field(schedule, "enabled") == "True" else "Disabled", "failure_reason": "",
            "source_system": "Power BI REST API (notebook service principal)",
            "evidence": "Power BI dataset refresh schedule API.", "technical_id": item_id, "notes": "Semantic model refresh schedule.",
        })


def discover_for_fabric_item(item, workspace_id, item_id, fabric_headers, rows):
    known_job_types = []
    instances_result = api_get_paged(f"workspaces/{workspace_id}/items/{item_id}/jobs/instances", fabric_headers, FABRIC_API_BASE_URL)
    if instances_result["ok"]:
        for instance in instances_result["values"]:
            job_type = field(instance, "jobType")
            if job_type and job_type not in known_job_types:
                known_job_types.append(job_type)
            start_time = field(instance, "startTimeUtc")
            end_time = field(instance, "endTimeUtc")
            failure_reason = compact_json(instance["failureReason"]) if instance.get("failureReason") else ""
            rows.append({
                "record_type": "job_instance", "workspace_name": item["workspace_name"],
                "item_name": item["item_name"], "item_type": item["item_type"], "qualified_name": item["qualified_name"],
                "job_type": job_type, "trigger_type": field(instance, "invokeType"),
                "schedule_id": "", "schedule_enabled": "", "scheduled_time": "", "schedule_timezone": "",
                "schedule_frequency": "", "schedule_config": "",
                "job_instance_id": field(instance, "id"), "root_activity_id": field(instance, "rootActivityId"),
                "start_time": start_time, "end_time": end_time, "duration_seconds": duration_seconds(start_time, end_time),
                "status": field(instance, "status"), "failure_reason": failure_reason,
                "source_system": "Fabric REST API (notebook service principal)",
                "evidence": "Job Scheduler list item job instances API.", "technical_id": item_id, "notes": "",
            })

    candidate_job_types = list(known_job_types)
    for guess in CANDIDATE_SCHEDULE_JOB_TYPES.get(item["item_type"], ["DefaultJob"]):
        if guess not in candidate_job_types:
            candidate_job_types.append(guess)

    for job_type in candidate_job_types:
        schedules_result = api_get_paged(f"workspaces/{workspace_id}/items/{item_id}/jobs/{job_type}/schedules", fabric_headers, FABRIC_API_BASE_URL)
        if not schedules_result["ok"]:
            continue
        for schedule in schedules_result["values"]:
            configuration = schedule.get("configuration") or {}
            rows.append({
                "record_type": "schedule", "workspace_name": item["workspace_name"],
                "item_name": item["item_name"], "item_type": item["item_type"], "qualified_name": item["qualified_name"],
                "job_type": job_type, "trigger_type": "Scheduled",
                "schedule_id": field(schedule, "id"), "schedule_enabled": field(schedule, "enabled"),
                "scheduled_time": field(configuration, "startDateTime"), "schedule_timezone": field(configuration, "localTimeZoneId"),
                "schedule_frequency": f"type={field(configuration, 'type')}; interval={field(configuration, 'interval')}",
                "schedule_config": compact_json(configuration),
                "job_instance_id": "", "root_activity_id": "", "start_time": "", "end_time": "", "duration_seconds": "",
                "status": "Enabled" if field(schedule, "enabled") == "True" else "Disabled", "failure_reason": "",
                "source_system": "Fabric REST API (notebook service principal)",
                "evidence": "Job Scheduler list item schedules API.", "technical_id": item_id,
                "notes": f"Schedule owner: {compact_json(schedule.get('owner'))}",
            })


# %% [markdown]
# ## Ejecutar

# %%
fabric_token = acquire_token("https://api.fabric.microsoft.com/.default")
fabric_headers = {"Authorization": f"Bearer {fabric_token}", "Content-Type": "application/json"}
pbi_token = acquire_token("https://analysis.windows.net/powerbi/api/.default")
pbi_headers = {"Authorization": f"Bearer {pbi_token}", "Content-Type": "application/json"}

connection = connect_warehouse()
try:
    item_cursor = connection.cursor()
    item_cursor.execute(
        "SELECT workspace_name, item_type, item_name, qualified_name, technical_id FROM dbo.bronze_items WHERE status = 'discovered'"
    )
    all_items = [
        {"workspace_name": r[0], "item_type": r[1], "item_name": r[2], "qualified_name": r[3], "technical_id": r[4]}
        for r in item_cursor.fetchall()
    ]
    workspace_cursor = connection.cursor()
    workspace_cursor.execute("SELECT workspace_name, technical_id FROM dbo.bronze_workspaces")
    workspace_id_by_name = {r[0]: r[1] for r in workspace_cursor.fetchall()}

    filter_set = {n.strip().lower() for n in WorkspaceNameFilter.replace(",", ";").split(";") if n.strip()}
    target_items = [
        item for item in all_items
        if item["item_type"] in EXECUTION_ITEM_TYPES
        and (not filter_set or item["workspace_name"].strip().lower() in filter_set)
    ]
    print(f"Target items: {len(target_items)} ({'filtered: ' + WorkspaceNameFilter if filter_set else 'full tenant'})")

    new_rows = []
    for index, item in enumerate(target_items, start=1):
        if index % 50 == 0:
            print(f"Processed {index} / {len(target_items)} execution-timing target items...")
        workspace_id = workspace_id_by_name.get(item["workspace_name"], "")
        item_id = item["technical_id"]
        if not workspace_id or not item_id:
            continue
        if item["item_type"] == "SemanticModel":
            discover_for_semantic_model(item, workspace_id, item_id, pbi_headers, new_rows)
        else:
            discover_for_fabric_item(item, workspace_id, item_id, fabric_headers, new_rows)

    print(f"New execution/schedule rows discovered: {len(new_rows)}")

    # Ver la nota de 06_discover_executions.ps1 (líneas 847-888): las APIs
    # de Fabric/Power BI solo devuelven una ventana reciente acotada, así
    # que un job_instance real puede desaparecer de esa ventana sin que
    # haya dejado de haber pasado -- se preserva lo que ya había en el
    # Warehouse y no vino en esta pasada, en vez de perderlo en cada
    # reescaneo. Las filas de tipo "schedule" describen configuración
    # ACTUAL y sí se reemplazan por completo, igual que el original.
    # Reconectar con un token de base de datos fresco -- la conexion de
    # arriba lleva abierta desde antes del bucle por item (potencialmente
    # cientos/miles de llamadas a la API de Fabric/Power BI con
    # reintentos), el mismo patron que ya causo un fallo real de
    # conexion ("TCP Provider: Error code 0x20") en NB_Discover_
    # Dependencies.py -- mismo fix aplicado aqui preventivamente.
    connection.close()
    connection = connect_warehouse()
    existing_rows = read_existing_table(connection, "bronze_executions", EXECUTION_COLUMNS)
    existing_job_rows = [r for r in existing_rows if r.get("record_type") == "job_instance"]
    seen_job_keys = {(r["qualified_name"], r["job_instance_id"]) for r in new_rows if r.get("record_type") == "job_instance"}
    preserved_job_rows = [
        r for r in existing_job_rows
        if (r.get("qualified_name"), r.get("job_instance_id")) not in seen_job_keys
        # Fuera del alcance del filtro actual: se conserva tal cual sin
        # tocar (igual que bronze_items en el notebook de workspaces/items).
        or (filter_set and (r.get("workspace_name") or "").strip().lower() not in filter_set)
    ]
    if preserved_job_rows:
        print(f"Preserving {len(preserved_job_rows)} existing job_instance row(s) not covered by this run's fetch window.")

    if filter_set:
        # Los schedules SÍ son configuración actual -- pero solo se han
        # vuelto a consultar para los workspaces dentro del filtro, así que
        # los de fuera del filtro también se conservan tal cual.
        existing_schedule_rows_outside_filter = [
            r for r in existing_rows
            if r.get("record_type") == "schedule" and (r.get("workspace_name") or "").strip().lower() not in filter_set
        ]
    else:
        existing_schedule_rows_outside_filter = []

    final_rows = new_rows + preserved_job_rows + existing_schedule_rows_outside_filter
    replace_table(connection, "bronze_executions", EXECUTION_COLUMNS, final_rows)
finally:
    connection.close()

print("Done.")
