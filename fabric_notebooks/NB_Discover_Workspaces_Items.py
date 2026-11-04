# NB_Discover_Workspaces_Items
#
# Source for a Fabric Python notebook. Fabric cannot be created/edited
# remotely from this repository, so this file is pasted by hand into a
# new notebook (see docs/105_fabric_native_discovery_setup.md
# for the complete walkthrough: Key Vault, service account, Data
# Pipeline). Each block delimited by "# %%" is an independent cell
# -- paste them in the same order. The "## Parameters" cell must be marked
# as a parameters cell (cell "..." icon -> "Toggle parameter
# cell" in the Fabric toolbar) so that the pipeline can pass it
# WorkspaceNameFilter on each run.
#
# What it does, in two passes:
#   1. Workspace discovery (equivalent to scripts/01_discover_
#      workspaces.ps1 + scripts/02_normalize_workspaces.ps1 combined):
#      Fabric admin API (whole tenant) or, if the service account is not
#      an admin, the regular API (only what that identity can see) +
#      per-workspace detail (capacity, domain, admins).
#   2. Item inventory (equivalent to scripts/03_discover_items.ps1):
#      one paginated GET per workspace, with the same WorkspaceNameFilter that
#      scan_single_workspace.ps1/99_refresh_lineage_project.ps1 already use --
#      if filled in, only those workspaces are rediscovered and the rest
#      is kept as it was in the Warehouse.
#
# Writes directly to dbo.bronze_workspaces / dbo.bronze_items of the configured
# Warehouse -- the SAME 17 and 14 columns respectively that
# scripts/67_upload_bronze_to_warehouse.ps1 already writes from local, so
# backend/scripts/lineage_web/warehouse.py (live read) does not need to
# know which of the two paths filled the table last time.
#
# Why its own MSAL login and not notebookutils.credentials.getToken: under a
# service account, that native helper only gives limited scope (Dataset/
# Lakehouse/Notebook/Workspace.ReadWrite.All -- it does not cover listing all the
# tenant's workspaces or reading capacity/domain metadata). Confirmed
# 2026-07-24 against the NotebookUtils credentials documentation. That is why
# this notebook does its own confidential client login (same
# pattern as backend/scripts/lineage_web/warehouse.py and
# scripts/67_upload_bronze_to_warehouse.ps1), using a secret read from
# Azure Key Vault, never written in the notebook itself.

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

# -- Service account: the same one you use in admin_settings.json ->
# lakehouse.sp_* / discovery_pipeline.sp_* (it can be the same app
# registration for all three things -- Warehouse, pipeline trigger, and
# this notebook -- or a different one, your choice). It needs, at a minimum, the
# "Fabric Administrator" role in Entra ID so that the workspace discovery
# step sees the whole tenant (see docs/105).
SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"

# -- No longer read from Key Vault (blocked: the "Key Vault Secrets
# User" role is missing for the SP and nobody was available to grant it) NOR from a pipeline
# parameter (tested 2026-08-12: a Fabric type conversion failure when passing
# SpClientSecret as a parameter leaked the value in plain text
# inside the job's own failureReason -- never again that way). Instead,
# a private file in the Files area of the workspace's own Lakehouse,
# read with notebookutils.fs.head() -- governed by the SP's Fabric role on
# THIS workspace (Contributor, already granted), not by Azure
# RBAC on a separate resource. It never shows up in logs/run history
# because it is a plain file read inside the notebook's own
# code, not a value that Fabric serializes anywhere.
ONELAKE_WORKSPACE_NAME = "<your-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<your-onelake-lakehouse>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"

# -- Write Warehouse: same item as admin_settings.json ->
# lakehouse.sql_endpoint_connection_string / lakehouse_name.
WAREHOUSE_SQL_ENDPOINT = "<your-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<WarehouseName>"

REQUEST_DELAY_SECONDS = 0.35
RETRY_COUNT = 5

# %% [markdown]
# ## Parameters
# Mark this cell as a parameters cell in Fabric (see the file
# header). The pipeline overrides it with the real WorkspaceNameFilter on
# each run -- see fabric_pipeline.trigger_pipeline_run in
# backend/scripts/lineage_web/fabric_pipeline.py, which sends this same
# parameter name. Empty = whole tenant.

# %%
WorkspaceNameFilter = ""

# %% [markdown]
# ## Authentication: own service account token (MSAL)

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
# ## Fabric REST helpers (pagination + retry on 429) -- same
# behavior as Invoke-FabricGet/Get-PagedFabricValues in
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
# ## Step 1 -- Workspace discovery (01 + 02 combined)

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
# ## Step 1b -- Role assignments via admin API (whole tenant, with a limit
# of 200 requests/hour)
#
# `workspaces/{id}/roleAssignments` (self-scoped, used further down until
# now) only sees the workspaces where the SP itself has an explicit role --
# confirmed live (2026-08-14): almost all workspaces returned
# "InsufficientPrivileges". `admin/workspaces/{id}/users` is the real
# admin equivalent (same pattern that already fixed items
# discovery with admin/items), but unlike that one,
# this API IS limited to 200 requests/hour and has no
# "whole tenant in one call" variant -- it has to be called once per
# workspace. In a large tenant that is hours for this step alone (18s
# minimum between calls so as not to exceed 200/h) -- on purpose: full
# tenant coverage is prioritized over speed, same as the
# local process, which also takes hours.

# %%
ROLE_ASSIGNMENT_MIN_SECONDS_BETWEEN_CALLS = 3600 / 190  # margin below 200/h
ROLE_ASSIGNMENT_TOKEN_REFRESH_SECONDS = 1200  # proactive refresh every 20 min


class _HeaderProvider:
    """Authorization headers with proactive token refresh (every
    ROLE_ASSIGNMENT_TOKEN_REFRESH_SECONDS) and reactive refresh (on demand, if
    fabric_get_with_refresh sees a 401) -- a ~3 hour loop far exceeds
    the normal lifetime of a token (~60-90 min); proactive
    refresh alone is not enough if the real expiry clock does not match
    exactly the assumed one, hence the 401 -> immediate refresh
    as well (same lesson that was already applied for long scans via
    PowerShell)."""

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
# per-workspace fallback below still using a single static token from Step
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
    """One call to admin/workspaces/{id}/users per workspace, spaced out
    so as not to exceed the 200 requests/hour imposed by the API itself.
    Returns role_assignment_rows with the shape that
    ROLE_ASSIGNMENT_COLUMNS expects, plus admin_principals_by_workspace (workspace_
    name -> the same "Name <upn>; Name2 <upn2>" text that admins_to_text
    used to produce) so the caller can fill in owner/
    admin_principals of bronze_workspaces without a second
    redundant call per workspace."""
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
            # Normalized to the same flat shape {"principal":...,
            # "role":...} that workspaces/{id}/roleAssignments returned, so
            # admins_to_text() (unchanged) keeps working as is.
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

        # owner/admin_principals are no longer resolved here -- see Step 1b:
        # the whole-tenant fetch (admin/workspaces/{id}/users) goes in a
        # separate pass after discover_workspaces() because it has its own
        # limit of 200 requests/hour and must not be mixed with the
        # per-workspace calls of this function. The caller fills in
        # both fields with fetch_all_role_assignments_admin().
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
# ## Step 2 -- Item inventory (03)

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
# ## Step 3 -- Write to the Warehouse (dbo.bronze_workspaces / dbo.bronze_items)
# Full replacement of each table on every run (unlike
# scripts/67_upload_bronze_to_warehouse.ps1, which only does an incremental
# MERGE) -- simpler for this first version, and with usual metadata
# volumes (workspace and item rows, not business data)
# the cost of a DROP+CREATE+INSERT is just as small.

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
# so purview_insights.py's _get_access_audit() (admin panel's "Access audit"
# tab) reads the same shape regardless of which one produced it.
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

# Items first, while fabric_headers (acquired above, without refresh)
# is still fresh. discover_items() used this same static token,
# and in a scheduled run Step 1b below -- which takes hours --
# ran BEFORE this, so by the time discover_items() started the
# token had been expired for hours: all workspaces came out
# "workspace_items_unavailable" in
# bronze_items (0 real rows, 0 SemanticModel), which in turn made
# NB_Discover_Semantic_Model_Lineage fail further down the pipeline
# ("No discovered SemanticModel rows in dbo.bronze_items"). Fixed by
# reversing the order: everything that depends on the static token above
# (workspaces + items) is resolved and WRITTEN before starting Step 1b,
# which does have its own token refresh (_HeaderProvider) and can therefore
# afford to take hours without this same problem.
#
# The previous reordering was NOT enough -- that same run
# still gave "TokenExpired" in bronze_items
# (all rows "workspace_items_unavailable"). Real cause: admin/items
# failed transiently that time, which made the WHOLE tenant fall to the
# slow per-workspace fallback (one sequential call per workspace,
# plain fabric_get_paged, without refresh) -- with rate-limit
# retries that alone can also exceed the lifetime of a token.
# discover_items() now receives a _HeaderProvider (same mechanism as
# Step 1b) and uses fabric_get_paged_with_refresh in both its calls
# (admin/items and the per-workspace fallback), so it no longer matters how long
# the fallback takes -- it refreshes itself, same as Step 1b.
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
    # owner/admin_principals are still "" at this point (Step 1b hasn't run
    # yet) -- this first write exists so bronze_workspaces/bronze_items are
    # never left stale/empty if the notebook is killed during the ~3h Step
    # 1b that follows; the second write below overwrites bronze_workspaces
    # with owner/admin_principals filled in once Step 1b finishes.
    replace_table(connection, "bronze_workspaces", WORKSPACE_COLUMNS, workspace_rows)
    replace_table(connection, "bronze_items", ITEM_COLUMNS, new_item_rows + retained_item_rows)
finally:
    connection.close()

# Step 1b -- whole tenant, ~18s between calls (200/h) => hours in a large
# tenant. Deliberate: see the Step 1b note further up. It goes at the
# end, after workspaces/items are already written with the fresh token
# from above, precisely so that this multi-hour wait does not
# ruin the rest of the notebook (see the comment further up).
role_header_provider = _HeaderProvider("https://api.fabric.microsoft.com/.default")
role_assignment_rows, admin_principals_by_workspace = fetch_all_role_assignments_admin(workspace_rows, role_header_provider)
for workspace in workspace_rows:
    admin_principals = admin_principals_by_workspace.get(workspace["workspace_name"], "")
    workspace["owner"] = admin_principals
    workspace["admin_principals"] = admin_principals
print(f"Role assignments discovered: {len(role_assignment_rows)}")

# Reconnect with a fresh database token -- the connection above
# would also have been open for ~3h by now and cannot be trusted to be reused.
connection = connect_warehouse()
try:
    replace_table(connection, "bronze_workspaces", WORKSPACE_COLUMNS, workspace_rows)
    replace_table(connection, "bronze_workspace_role_assignments", ROLE_ASSIGNMENT_COLUMNS, role_assignment_rows)
finally:
    connection.close()

print("Done.")
