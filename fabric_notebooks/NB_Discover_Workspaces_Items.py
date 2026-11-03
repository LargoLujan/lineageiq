# NB_Discover_Workspaces_Items
#
# Fuente para un notebook Python de Fabric. Fabric no se puede crear/editar
# de forma remota desde este repositorio, así que este archivo se pega a
# mano en un notebook nuevo (ver docs/105_fabric_native_discovery_setup.md
# para el paso a paso completo: Key Vault, cuenta de servicio, Data
# Pipeline). Cada bloque delimitado por "# %%" es una celda independiente
# -- pégalas en el mismo orden. La celda "## Parámetros" debe marcarse
# como celda de parámetros (icono "..." de la celda -> "Alternar celda de
# parámetros" en la barra de Fabric) para que el pipeline pueda pasarle
# WorkspaceNameFilter en cada ejecución.
#
# Qué hace, en dos pasadas:
#   1. Descubrimiento de workspaces (equivalente a scripts/01_discover_
#      workspaces.ps1 + scripts/02_normalize_workspaces.ps1 combinados):
#      API admin de Fabric (tenant completo) o, si la cuenta de servicio no
#      es admin, la API normal (solo lo que esa identidad puede ver) +
#      detalle por workspace (capacidad, dominio, admins).
#   2. Inventario de items (equivalente a scripts/03_discover_items.ps1):
#      un GET paginado por workspace, con el mismo WorkspaceNameFilter que
#      ya usan scan_single_workspace.ps1/99_refresh_lineage_project.ps1 --
#      si viene relleno, solo se re-descubren esos workspaces y el resto se
#      mantiene tal cual estaba en el Warehouse.
#
# Escribe directo en dbo.bronze_workspaces / dbo.bronze_items del Warehouse
# configurado -- MISMAS 17 y 14 columnas respectivamente que ya escribe
# scripts/67_upload_bronze_to_warehouse.ps1 desde local, así que
# backend/scripts/lineage_web/warehouse.py (lectura en vivo) no necesita
# saber cuál de los dos caminos rellenó la tabla la última vez.
#
# Por qué login MSAL propio y no notebookutils.credentials.getToken: bajo
# cuenta de servicio, ese helper nativo solo da alcance limitado (Dataset/
# Lakehouse/Notebook/Workspace.ReadWrite.All -- no cubre listar todos los
# workspaces del tenant ni leer metadatos de capacidad/dominio). Confirmado
# 2026-07-24 contra la documentación de NotebookUtils credentials. Por eso
# este notebook hace su propio login de cliente confidencial (idéntico
# patrón que backend/scripts/lineage_web/warehouse.py y
# scripts/67_upload_bronze_to_warehouse.ps1), usando un secreto leído de
# Azure Key Vault, nunca escrito en el propio notebook.

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

import re
import struct
import time
import requests

FABRIC_API_BASE_URL = "https://api.fabric.microsoft.com/v1"

# -- Cuenta de servicio: la misma que uses en admin_settings.json ->
# lakehouse.sp_* / discovery_pipeline.sp_* (puede ser la misma app
# registration para las tres cosas -- Warehouse, disparo del pipeline, y
# este notebook -- o una distinta, tu elección). Necesita, como mínimo, el
# rol "Fabric Administrator" en Entra ID para que el paso de descubrimiento
# de workspaces vea el tenant completo (ver docs/105).
SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"

# -- Ya no se lee de Key Vault (bloqueado: falta rol "Key Vault Secrets
# User" para el SP y nadie disponible para concederlo) NI de un parámetro
# del pipeline (probado 2026-08-12: un fallo de conversión de tipo de
# Fabric al pasar SpClientSecret como parámetro filtró el valor en texto
# plano dentro del propio failureReason del job -- nunca más por ahí). En
# vez de eso, un fichero privado en el área Files del propio Lakehouse del
# workspace, leído con notebookutils.fs.head() -- gobernado por el rol de
# Fabric del SP sobre ESTE workspace (Contributor, ya concedido), no por
# RBAC de Azure sobre un recurso aparte. Nunca sale en logs/historial de
# ejecuciones porque es una simple lectura de fichero dentro del propio
# código del notebook, no un valor que Fabric serialice en ningún sitio.
ONELAKE_WORKSPACE_NAME = "<tu-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<tu-lakehouse-onelake>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"

# -- Warehouse de escritura: mismo elemento que admin_settings.json ->
# lakehouse.sql_endpoint_connection_string / lakehouse_name.
WAREHOUSE_SQL_ENDPOINT = "<tu-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<NombreDelWarehouse>"

REQUEST_DELAY_SECONDS = 0.35
RETRY_COUNT = 5

# %% [markdown]
# ## Parámetros
# Marca esta celda como celda de parámetros en Fabric (ver cabecera del
# archivo). El pipeline la sobreescribe con el WorkspaceNameFilter real en
# cada ejecución -- ver fabric_pipeline.trigger_pipeline_run en
# backend/scripts/lineage_web/fabric_pipeline.py, que envía este mismo
# nombre de parámetro. Vacío = tenant completo.

# %%
WorkspaceNameFilter = ""

# %% [markdown]
# ## Autenticación: token propio de cuenta de servicio (MSAL)

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


# %% [markdown]
# ## Helpers Fabric REST (paginación + reintento en 429) -- mismo
# comportamiento que Invoke-FabricGet/Get-PagedFabricValues en
# scripts/01_discover_workspaces.ps1 / 02_normalize_workspaces.ps1 /
# 03_discover_items.ps1.

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
            return {"ok": False, "values": [], "error": result["error"], "status_code": result["status_code"]}
        payload = result["payload"] or {}
        for key in (value_key, "domains", "workspaces"):
            if key in payload:
                values.extend(payload[key])
                break
        next_path = payload.get("continuationUri") or None
    return {"ok": True, "values": values, "error": "", "status_code": 200}


def field(obj, *names):
    if not obj:
        return ""
    for name in names:
        value = obj.get(name)
        if value is not None:
            return str(value)
    return ""


# %% [markdown]
# ## Fase 1 -- Descubrimiento de workspaces (01 + 02 combinados)

# %%
ENV_RULES = [
    re.compile(r"\[(DEV|QA|PROD|PRO|PRE|UAT)\]\s*$"),
    re.compile(r"[_\-\s](DEV|QA|PROD|PRO|PRE|UAT)\s*$"),
    re.compile(r"[_\-](?:Contoso_)?(Dev|Pro|Pre|Qa)\s*$"),
]
NAME_STRIP_PATTERNS = [
    re.compile(r"\s*\[(DEV|QA|PROD|PRO|PRE|UAT)\]\s*$"),
    re.compile(r"[_\-\s](DEV|QA|PROD|PRO|PRE|UAT)\s*$"),
    re.compile(r"[_\-]Contoso_(Dev|Pro|Pre|Qa)\s*$"),
    re.compile(r"[_\-](Dev|Pro|Pre|Qa)\s*$"),
]


def environment_from_name(name):
    for pattern in ENV_RULES:
        match = pattern.search(name or "")
        if match:
            return match.group(1).upper()
    return "UNKNOWN"


def normalized_workspace_name(name):
    result = name or ""
    for pattern in NAME_STRIP_PATTERNS:
        result = pattern.sub("", result)
    return result.strip()


def admins_to_text(role_assignments):
    admins = []
    for assignment in role_assignments:
        if field(assignment, "role") != "Admin":
            continue
        principal = assignment.get("principal") or {}
        display_name = field(principal, "displayName")
        principal_type = field(principal, "type")
        upn = field(principal.get("userDetails") or {}, "userPrincipalName")
        if upn:
            admins.append(f"{display_name} <{upn}>")
        elif principal_type:
            admins.append(f"{display_name} ({principal_type})")
        elif display_name:
            admins.append(display_name)
    return "; ".join(sorted(set(a for a in admins if a)))


# %% [markdown]
# ## Fase 1b -- Role assignments vía API admin (tenant completo, con límite
# de 200 peticiones/hora)
#
# `workspaces/{id}/roleAssignments` (self-scoped, usado más abajo hasta
# hoy) solo ve los workspaces donde el propio SP tenga un rol explícito --
# confirmado en vivo (2026-08-14): casi todos los workspaces devolvían
# "InsufficientPrivileges". `admin/workspaces/{id}/users` es el
# equivalente admin de verdad (mismo patrón que ya arregló el
# descubrimiento de items ayer con admin/items), pero a diferencia de esa,
# esta API SÍ está limitada a 200 peticiones/hora y no tiene variante
# "todo el tenant en una llamada" -- hay que llamarla una vez por
# workspace. En un tenant grande eso son horas solo para este paso (18s
# mínimo entre llamadas para no pasarse de 200/h) -- a propósito: se
# prioriza la cobertura completa del tenant sobre la velocidad, igual que
# el proceso local, que también tarda horas.

# %%
ROLE_ASSIGNMENT_MIN_SECONDS_BETWEEN_CALLS = 3600 / 190  # margen bajo 200/h
ROLE_ASSIGNMENT_TOKEN_REFRESH_SECONDS = 1200  # refresco proactivo cada 20min


class _HeaderProvider:
    """Cabeceras Authorization con refresco de token proactivo (cada
    ROLE_ASSIGNMENT_TOKEN_REFRESH_SECONDS) y reactivo (bajo demanda, si
    fabric_get_with_refresh ve un 401) -- un bucle de ~3 horas agota de
    sobra la vida útil normal de un token (~60-90 min); el refresco
    proactivo solo no basta si el reloj de expiración real no coincide
    exactamente con el asumido, de ahí el 401 -> refresco inmediato
    también (misma lección que ya se aplicó para escaneos largos vía
    PowerShell -- ver memoria del proyecto)."""

    def __init__(self, scope):
        self.scope = scope
        self.headers = None
        self.acquired_at = 0.0

    def get(self, force_refresh=False):
        now = time.time()
        if force_refresh or self.headers is None or (now - self.acquired_at) > ROLE_ASSIGNMENT_TOKEN_REFRESH_SECONDS:
            token = acquire_token(self.scope)
            self.headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
            self.acquired_at = now
        return self.headers


def fabric_get_with_refresh(path, header_provider, retry_count=RETRY_COUNT):
    url = path if path.startswith("http") else f"{FABRIC_API_BASE_URL}/{path.lstrip('/')}"
    headers = header_provider.get()
    for attempt in range(retry_count + 1):
        try:
            response = requests.get(url, headers=headers, timeout=120)
        except requests.exceptions.RequestException as exc:
            if attempt < retry_count:
                time.sleep(min(90, 2 ** (attempt + 1)))
                continue
            return {"ok": False, "status_code": None, "error": f"{type(exc).__name__}: {exc}", "payload": None}
        if response.status_code == 401:
            headers = header_provider.get(force_refresh=True)
            continue
        if response.status_code == 429 and attempt < retry_count:
            retry_after = response.headers.get("Retry-After")
            delay = int(retry_after) if retry_after and retry_after.isdigit() else min(90, 2 ** (attempt + 1))
            time.sleep(delay)
            continue
        if response.status_code >= 400:
            return {"ok": False, "status_code": response.status_code, "error": response.text[:500], "payload": None}
        return {"ok": True, "status_code": response.status_code, "error": "", "payload": response.json()}
    return {"ok": False, "status_code": None, "error": "retries exhausted", "payload": None}


# Same continuation-walking loop as fabric_get_paged, but calling
# fabric_get_with_refresh per page instead of the plain, never-refreshing
# fabric_get -- added after a scheduled run showed
# discover_items() failing tenant-wide with "TokenExpired": admin/items
# itself failed transiently that run, which cascaded into the per-workspace-call
# per-workspace fallback below still using a single static token from Fase
# 1's acquisition -- long enough (rate-limit backoff across hundreds of
# calls) to outlive a normal token's lifetime. discover_workspaces() above
# stays on the plain, non-refreshing fabric_get_paged: it's a handful of
# calls, not hundreds, and was never implicated in this failure.
def fabric_get_paged_with_refresh(path, header_provider, value_key="value"):
    values = []
    next_path = path
    while next_path:
        result = fabric_get_with_refresh(next_path, header_provider)
        if not result["ok"]:
            return {"ok": False, "values": values, "error": result["error"], "status_code": result["status_code"]}
        payload = result["payload"] or {}
        for key in (value_key, "domains", "workspaces"):
            if key in payload:
                values.extend(payload[key])
                break
        next_path = payload.get("continuationUri") or None
    return {"ok": True, "values": values, "error": "", "status_code": 200}


def fetch_all_role_assignments_admin(workspace_rows, header_provider):
    """Una llamada a admin/workspaces/{id}/users por workspace, espaciada
    para no superar las 200 peticiones/hora que impone la propia API.
    Devuelve role_assignment_rows con la forma que espera
    ROLE_ASSIGNMENT_COLUMNS, más admin_principals_by_workspace (workspace_
    name -> mismo texto "Nombre <upn>; Nombre2 <upn2>" que producía
    admins_to_text) para que el llamador pueda rellenar owner/
    admin_principals de bronze_workspaces sin una segunda llamada
    redundante por workspace."""
    role_assignment_rows = []
    admin_principals_by_workspace = {}
    last_call_at = 0.0
    total = len(workspace_rows)
    for index, workspace in enumerate(workspace_rows):
        workspace_id = workspace.get("technical_id", "")
        workspace_name = workspace.get("workspace_name", "")
        if not workspace_id:
            continue

        elapsed = time.time() - last_call_at
        if elapsed < ROLE_ASSIGNMENT_MIN_SECONDS_BETWEEN_CALLS:
            time.sleep(ROLE_ASSIGNMENT_MIN_SECONDS_BETWEEN_CALLS - elapsed)
        result = fabric_get_with_refresh(f"admin/workspaces/{workspace_id}/users", header_provider)
        last_call_at = time.time()

        if result["ok"]:
            access_details = (result["payload"] or {}).get("accessDetails", [])
            # Normalizado a la misma forma plana {"principal":...,
            # "role":...} que devolvía workspaces/{id}/roleAssignments, así
            # admins_to_text() (sin cambios) sigue funcionando tal cual.
            normalized = [
                {"principal": entry.get("principal"), "role": field(entry.get("workspaceAccessDetails") or {}, "workspaceRole")}
                for entry in access_details
            ]
            admin_principals_by_workspace[workspace_name] = admins_to_text(normalized)
            for assignment in normalized:
                principal = assignment.get("principal") or {}
                role_assignment_rows.append({
                    "workspace_name": workspace_name,
                    "principal_id": field(principal, "id"),
                    "principal_name": field(principal, "displayName"),
                    "principal_type": field(principal, "type"),
                    "role": assignment.get("role", ""),
                    "status": "discovered",
                    "evidence": "Fabric Admin REST API GET admin/workspaces/{id}/users",
                })
        else:
            role_assignment_rows.append({
                "workspace_name": workspace_name, "principal_id": "", "principal_name": "",
                "principal_type": "", "role": "", "status": "unavailable",
                "evidence": f"Role assignments unavailable: {result['error']}",
            })

        if (index + 1) % 50 == 0 or (index + 1) == total:
            print(f"[role assignments] {index + 1}/{total} workspaces processed.")
    return role_assignment_rows, admin_principals_by_workspace


def discover_workspaces(headers):
    admin_result = fabric_get_paged("admin/workspaces?type=Workspace&state=Active", headers)
    if admin_result["ok"]:
        source_system = "Fabric Admin REST API (notebook service principal)"
        raw_workspaces = admin_result["values"]
    else:
        print(f"[workspaces] Admin API unavailable ({admin_result['error']}) -- falling back to the regular /workspaces endpoint (only workspaces this service principal has an explicit role in).")
        regular_result = fabric_get_paged("workspaces", headers)
        if not regular_result["ok"]:
            raise RuntimeError(f"Could not discover any workspace: {regular_result['error']}")
        source_system = "Fabric REST API (notebook service principal)"
        raw_workspaces = regular_result["values"]

    capacities = {c["id"]: c for c in fabric_get_paged("capacities", headers)["values"] if c.get("id")}
    domains_result = fabric_get_paged("admin/domains", headers, value_key="domains")
    domains = {d["id"]: d for d in domains_result["values"] if d.get("id")} if domains_result["ok"] else {}

    rows = []
    for raw in raw_workspaces:
        workspace_id = field(raw, "id", "workspaceId")
        workspace_name = field(raw, "displayName", "name") or f"Unknown workspace {workspace_id}".strip()

        detail_result = fabric_get(f"workspaces/{workspace_id}", headers)
        detail = detail_result["payload"] if detail_result["ok"] else {}
        workspace_type = field(detail, "type")
        capacity_id = field(detail, "capacityId")
        domain_id = field(detail, "domainId")
        capacity_region = field(detail, "capacityRegion")
        capacity_assignment_progress = field(detail, "capacityAssignmentProgress")
        description = field(detail, "description")

        capacity_name = ""
        if capacity_id and capacity_id in capacities:
            capacity_name = field(capacities[capacity_id], "displayName", "name")
            if not capacity_region:
                capacity_region = field(capacities[capacity_id], "region")

        domain_name = field(domains.get(domain_id) or {}, "displayName", "name") if domain_id else ""

        # owner/admin_principals ya no se resuelven aquí -- ver Fase 1b:
        # el fetch tenant-completo (admin/workspaces/{id}/users) va en una
        # pasada aparte tras discover_workspaces() porque tiene su propio
        # límite de 200 peticiones/hora y no debe mezclarse con las
        # llamadas por-workspace de esta función. El llamador rellena
        # ambos campos con fetch_all_role_assignments_admin().
        notes = []
        if not detail_result["ok"]:
            notes.append(f"Workspace detail lookup failed: {detail_result['status_code']} {detail_result['error']}")
        if capacity_id and not capacity_name:
            notes.append("Capacity ID found but capacity name unavailable.")
        if domain_id and not domain_name:
            notes.append("Domain ID found but domain name unavailable.")

        rows.append({
            "workspace_name": workspace_name,
            "normalized_workspace_name": normalized_workspace_name(workspace_name),
            "environment": environment_from_name(workspace_name),
            "workspace_type": workspace_type,
            "capacity_name": capacity_name,
            "capacity_id": capacity_id,
            "capacity_region": capacity_region,
            "capacity_assignment_progress": capacity_assignment_progress,
            "domain_name": domain_name,
            "domain_id": domain_id,
            "owner": "",
            "admin_principals": "",
            "description": description,
            "source_system": source_system,
            "technical_id": workspace_id,
            "status": "normalized" if detail_result["ok"] else "partial",
            "notes": " ".join(notes),
        })
    return sorted(rows, key=lambda r: r["workspace_name"].lower())


# %% [markdown]
# ## Fase 2 -- Inventario de items (03)

# %%
def convert_principal(principal):
    if not principal:
        return ""
    display_name = field(principal, "displayName")
    principal_type = field(principal, "type")
    upn = field(principal.get("userDetails") or {}, "userPrincipalName")
    if upn:
        return f"{display_name} <{upn}>"
    if principal_type:
        return f"{display_name} ({principal_type})"
    return display_name


def convert_sensitivity_label(label):
    if not label:
        return ""
    display_name = field(label, "displayName", "name")
    label_id = field(label, "id")
    if display_name and label_id:
        return f"{display_name} ({label_id})"
    return display_name or label_id


def discover_items(header_provider, workspace_rows, workspace_name_filter):
    filter_set = {
        name.strip().lower()
        for name in re.split(r"[;,]", workspace_name_filter or "")
        if name.strip()
    }

    workspace_by_id = {w["technical_id"]: w for w in workspace_rows if w.get("technical_id")}
    scoped_workspace_ids = {
        workspace_id
        for workspace_id, w in workspace_by_id.items()
        if not filter_set or w["workspace_name"].strip().lower() in filter_set
    }

    # `workspaces/{id}/items` is role-scoped -- confirmed live (2026-08-13)
    # that on a tenant this SP isn't individually a member of most
    # workspaces of, almost all came back "Unauthorized" even though
    # workspace discovery itself (admin/workspaces) saw the whole tenant
    # fine. `admin/items` is the actual tenant-wide equivalent for items
    # -- same admin-level access, and (bonus) one tenant-wide paginated
    # call series instead of one call per workspace, which also matters
    # because these admin APIs are rate-limited per hour -- one call per
    # workspace on a large tenant would blow through that on its own.
    rows = []
    covered_workspace_ids = set()
    admin_result = fabric_get_paged_with_refresh("admin/items", header_provider, value_key="itemEntities")

    if admin_result["ok"]:
        items_by_workspace = {}
        for item in admin_result["values"]:
            items_by_workspace.setdefault(field(item, "workspaceId"), []).append(item)

        for workspace_id in scoped_workspace_ids:
            workspace = workspace_by_id[workspace_id]
            workspace_name = workspace["workspace_name"]
            workspace_environment = workspace["environment"]
            covered_workspace_ids.add(workspace_id)
            for item in items_by_workspace.get(workspace_id, []):
                item_name = field(item, "displayName", "name")
                item_type = field(item, "type")
                tags = "; ".join(t.get("displayName", "") for t in (item.get("tags") or []) if t.get("displayName"))
                rows.append({
                    "workspace_name": workspace_name,
                    "workspace_environment": workspace_environment,
                    "item_type": item_type,
                    "item_name": item_name,
                    "qualified_name": f"{workspace_name} / {item_type} / {item_name}",
                    "folder_id": field(item, "folderId"),
                    "description": field(item, "description"),
                    "default_identity": convert_principal(item.get("defaultIdentity")),
                    # admin/items doesn't expose sensitivityLabel (only the
                    # regular per-workspace endpoint below does) -- left
                    # blank rather than guessed.
                    "sensitivity_label": "",
                    "tags": tags,
                    "source_system": "Fabric Admin REST API (notebook service principal)",
                    "technical_id": field(item, "id"),
                    "status": "discovered",
                    "notes": "",
                })
    else:
        print(f"[items] Admin API unavailable ({admin_result['error']}) -- falling back to the regular per-workspace endpoint (only workspaces this service principal has an explicit role in) for every workspace.")

    # Whatever the admin call didn't cover (it failed outright, or this
    # SP's admin access doesn't extend to admin/items specifically even
    # though it does to admin/workspaces) falls back to the original
    # role-scoped per-workspace call, same behavior as before this fix.
    remaining_ids = sorted(
        scoped_workspace_ids - covered_workspace_ids,
        key=lambda wid: workspace_by_id[wid]["workspace_name"].lower(),
    )
    for workspace_id in remaining_ids:
        workspace = workspace_by_id[workspace_id]
        workspace_name = workspace["workspace_name"]
        workspace_environment = workspace["environment"]

        result = fabric_get_paged_with_refresh(f"workspaces/{workspace_id}/items?include=DefaultIdentity", header_provider)
        if not result["ok"]:
            rows.append({
                "workspace_name": workspace_name, "workspace_environment": workspace_environment,
                "item_type": "", "item_name": "", "qualified_name": workspace_name, "folder_id": "",
                "description": "", "default_identity": "", "sensitivity_label": "", "tags": "",
                "source_system": "Fabric REST API (notebook service principal)", "technical_id": "",
                "status": "workspace_items_unavailable", "notes": f"Item list failed: {result['error']}",
            })
            continue

        for item in result["values"]:
            item_name = field(item, "displayName", "name")
            item_type = field(item, "type")
            tags = "; ".join(t.get("displayName", "") for t in (item.get("tags") or []) if t.get("displayName"))
            rows.append({
                "workspace_name": workspace_name,
                "workspace_environment": workspace_environment,
                "item_type": item_type,
                "item_name": item_name,
                "qualified_name": f"{workspace_name} / {item_type} / {item_name}",
                "folder_id": field(item, "folderId"),
                "description": field(item, "description"),
                "default_identity": convert_principal(item.get("defaultIdentity")),
                "sensitivity_label": convert_sensitivity_label(item.get("sensitivityLabel")),
                "tags": tags,
                "source_system": "Fabric REST API (notebook service principal)",
                "technical_id": field(item, "id"),
                "status": "discovered",
                "notes": "",
            })
    return rows


# %% [markdown]
# ## Fase 3 -- Escribir en el Warehouse (dbo.bronze_workspaces / dbo.bronze_items)
# Reemplazo completo de cada tabla en cada ejecución (a diferencia de
# scripts/67_upload_bronze_to_warehouse.ps1, que solo hace MERGE
# incremental) -- más simple para esta primera versión, y con volúmenes de
# metadatos habituales (filas de workspaces e items, no datos de negocio)
# el coste de un DROP+CREATE+INSERT es igualmente pequeño.

# %%
WORKSPACE_COLUMNS = [
    "workspace_name", "normalized_workspace_name", "environment", "workspace_type",
    "capacity_name", "capacity_id", "capacity_region", "capacity_assignment_progress",
    "domain_name", "domain_id", "owner", "admin_principals", "description",
    "source_system", "technical_id", "status", "notes",
]
ITEM_COLUMNS = [
    "workspace_name", "workspace_environment", "item_type", "item_name", "qualified_name",
    "folder_id", "description", "default_identity", "sensitivity_label", "tags",
    "source_system", "technical_id", "status", "notes",
]
# Same 7 columns backend/scripts/68_discover_workspace_role_assignments.ps1
# used to write to index/workspace_role_assignments.csv -- kept identical
# so purview_insights.py's _get_access_audit() (admin panel's "Auditoría
# de accesos" tab) reads the same shape regardless of which one produced it.
ROLE_ASSIGNMENT_COLUMNS = [
    "workspace_name", "principal_id", "principal_name", "principal_type",
    "role", "status", "evidence",
]


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
    # Driver picked dynamically via pick_odbc_driver() above -- local dev
    # machines and this project's other pyodbc callers (scripts/70_
    # extract_control_framework_lineage.py, backend/scripts/lineage_web/
    # warehouse.py) hardcode "ODBC Driver 17 for SQL Server", but Fabric's
    # managed Spark runtime doesn't ship that version (confirmed live).
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


def read_existing_items_outside_filter(connection, filter_set):
    if not filter_set:
        return []
    cursor = connection.cursor()
    try:
        cursor.execute(f"SELECT {', '.join(ITEM_COLUMNS)} FROM dbo.bronze_items")
    except pyodbc.Error:
        connection.rollback()  # leave the connection usable for the writes that follow
        return []  # table doesn't exist yet (first-ever run) -- nothing to retain
    return [
        dict(zip(ITEM_COLUMNS, row))
        for row in cursor.fetchall()
        if str(row[0]).strip().lower() not in filter_set
    ]


# %% [markdown]
# ## Ejecutar

# %%
fabric_token = acquire_token("https://api.fabric.microsoft.com/.default")
fabric_headers = {"Authorization": f"Bearer {fabric_token}", "Content-Type": "application/json"}

workspace_rows = discover_workspaces(fabric_headers)
print(f"Workspaces discovered: {len(workspace_rows)}")

# Items primero, mientras fabric_headers (adquirido arriba, sin refresco)
# todavía está fresco. discover_items() usaba este mismo token estático,
# y en una ejecución programada la Fase 1b de abajo -- que tarda horas --
# corría ANTES que esto, así que para cuando discover_items() arrancaba el
# token ya llevaba horas caducado: todos los workspaces salieron
# "workspace_items_unavailable" en
# bronze_items (0 filas reales, 0 SemanticModel), lo que a su vez hizo
# fallar NB_Discover_Semantic_Model_Lineage más abajo en el pipeline
# ("No discovered SemanticModel rows in dbo.bronze_items"). Corregido
# invirtiendo el orden: todo lo que dependa del token estático de arriba
# (workspaces + items) se resuelve y ESCRIBE antes de arrancar la Fase 1b,
# que sí tiene su propio refresco de token (_HeaderProvider) y por eso
# puede permitirse tardar horas sin este mismo problema.
#
# La reordenación anterior NO bastó -- esa misma ejecución
# seguía dando "TokenExpired" en bronze_items
# (all filas "workspace_items_unavailable"). Causa real: admin/items
# falló de forma transitoria esa vez, lo que hizo caer TODO el tenant al
# fallback lento por workspace (una llamada secuencial por workspace,
# fabric_get_paged de toda la vida, sin refresco) -- con reintentos por
# límite de tasa eso solo también puede superar la vida útil de un token.
# discover_items() ahora recibe un _HeaderProvider (mismo mecanismo que
# Fase 1b) y usa fabric_get_paged_with_refresh en sus dos llamadas
# (admin/items y el fallback por workspace), así que ya no importa cuánto
# tarde el fallback -- se refresca solo, igual que Fase 1b.
filter_set = {n.strip().lower() for n in re.split(r"[;,]", WorkspaceNameFilter or "") if n.strip()}
items_header_provider = _HeaderProvider("https://api.fabric.microsoft.com/.default")
new_item_rows = discover_items(items_header_provider, workspace_rows, WorkspaceNameFilter)
print(f"Items discovered ({'filtered: ' + WorkspaceNameFilter if filter_set else 'full tenant'}): {len(new_item_rows)}")

connection = connect_warehouse()
try:
    retained_item_rows = read_existing_items_outside_filter(connection, filter_set)
    if retained_item_rows:
        print(f"Retained {len(retained_item_rows)} existing item row(s) for workspaces outside WorkspaceNameFilter.")
    # An empty WorkspaceNameFilter (full-tenant run) means workspace
    # discovery above already covered the whole tenant, so no retention is
    # needed for bronze_workspaces -- unlike bronze_items, this notebook
    # never does a workspace-scoped run (there is no per-workspace
    # equivalent of 01_discover_workspaces.ps1's own retention logic,
    # since "list every workspace" has no partial mode to begin with).
    # owner/admin_principals are still "" at this point (Fase 1b hasn't run
    # yet) -- this first write exists so bronze_workspaces/bronze_items are
    # never left stale/empty if the notebook is killed during the ~3h Fase
    # 1b that follows; the second write below overwrites bronze_workspaces
    # with owner/admin_principals filled in once Fase 1b finishes.
    replace_table(connection, "bronze_workspaces", WORKSPACE_COLUMNS, workspace_rows)
    replace_table(connection, "bronze_items", ITEM_COLUMNS, new_item_rows + retained_item_rows)
finally:
    connection.close()

# Fase 1b -- tenant completo, ~18s entre llamadas (200/h) => horas en un
# tenant grande. Deliberado: ver la nota de la Fase 1b más arriba. Va al
# final, después de que workspaces/items ya estén escritos con el token
# fresco de arriba, precisamente para no dejar que esta espera de horas
# eche a perder el resto del notebook (ver el comentario más arriba).
role_header_provider = _HeaderProvider("https://api.fabric.microsoft.com/.default")
role_assignment_rows, admin_principals_by_workspace = fetch_all_role_assignments_admin(workspace_rows, role_header_provider)
for workspace in workspace_rows:
    admin_principals = admin_principals_by_workspace.get(workspace["workspace_name"], "")
    workspace["owner"] = admin_principals
    workspace["admin_principals"] = admin_principals
print(f"Role assignments discovered: {len(role_assignment_rows)}")

# Reconectar con un token de base de datos fresco -- la conexión de arriba
# también llevaría ~3h abierta a estas alturas y no es de fiar reutilizarla.
connection = connect_warehouse()
try:
    replace_table(connection, "bronze_workspaces", WORKSPACE_COLUMNS, workspace_rows)
    replace_table(connection, "bronze_workspace_role_assignments", ROLE_ASSIGNMENT_COLUMNS, role_assignment_rows)
finally:
    connection.close()

print("Done.")
