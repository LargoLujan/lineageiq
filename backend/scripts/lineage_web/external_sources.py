"""External (non-Fabric) source + Lakehouse connection tests.

Split out of lineage_web_server.py (D.3, 2026-07-08) -- pure code motion,
no logic changed from the original.
"""
import json
import subprocess

from .admin_settings import _load_admin_settings, _reserved_secret_env_var_name, _write_admin_settings
from .paths import REPO_ROOT, TEST_EXTERNAL_SOURCE_SCRIPT_PATH
from .utils import _now_iso, _resolve_pwsh_command
from . import catalog

# Mirrors fabric_notebooks/NB_Build_Graph_Map.py's FABRIC_INTERNAL_SOURCE_
# TYPES exactly -- kept in sync deliberately (same reasoning as mcp_server.
# py's _fabric_item_url comment): both need the same "is this row actually
# an external, non-Fabric origin" answer, one to draw the graph-map's
# ExternalOrigin nodes, one to power the admin panel's "detected but not
# configured yet" card below.
FABRIC_INTERNAL_SOURCE_TYPES = {
    "Fabric", "FabricOrSQL", "Lakehouse", "LakehouseTable", "FabricDataPipelines",
    "FabricSqlEndpointMetadata", "CapacityMetricsCES", "UsageMetricsDataConnector",
}


def _test_external_source(source, session=None):
    # Checked before even resolving pwsh, both so this doesn't depend on
    # pwsh being on PATH to unit-test and so the specific reserved-secret
    # message wins over the generic "pwsh not found" one when both would
    # otherwise apply.
    password_ref = str(source.get("password_ref") or "").strip()
    reserved = _reserved_secret_env_var_name(_load_admin_settings())
    if password_ref and reserved and password_ref == reserved:
        return {
            "ok": False,
            "message": f"'{password_ref}' is reserved for the Warehouse service-principal secret and can't be used as a data-source password reference.",
        }

    pwsh_path = _resolve_pwsh_command()
    if not pwsh_path:
        return {"ok": False, "message": "PowerShell ('pwsh') was not found on PATH."}

    args = [
        pwsh_path, "-NoLogo", "-File", str(TEST_EXTERNAL_SOURCE_SCRIPT_PATH),
        "-EngineType", str(source.get("type") or "sql_server"),
        "-SourceHost", str(source.get("host") or ""),
        "-AuthMode", str(source.get("auth_mode") or "sql_auth"),
        "-User", str(source.get("user") or ""),
        "-PasswordEnvVar", str(source.get("password_ref") or ""),
        # Same default already used everywhere else this pipeline connects
        # to an external/on-prem SQL Server (see 20_extract_source_object_
        # type_metadata.ps1, 34_extract_sql_endpoint_object_catalog.ps1):
        # these servers commonly present an internally-issued certificate
        # the client machine doesn't have in its trust store, which would
        # otherwise fail every test with a TLS trust error before even
        # reaching real credential validation.
        "-TrustServerCertificate",
    ]
    if source.get("port"):
        args += ["-Port", str(source["port"])]
    if source.get("database"):
        args += ["-Database", str(source["database"])]
    if source.get("service_name"):
        args += ["-ServiceName", str(source["service_name"])]
    if source.get("file_path"):
        args += ["-FilePath", str(source["file_path"])]
    if source.get("site_url"):
        args += ["-SiteUrl", str(source["site_url"])]

    try:
        result = subprocess.run(args, cwd=str(REPO_ROOT), capture_output=True, text=True, timeout=30, env=_test_subprocess_env(session))
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "message": f"Could not run the connection test: {exc}"}

    try:
        return json.loads(result.stdout.strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError):
        return {"ok": False, "message": (result.stderr or result.stdout or "Unknown error running the connection test.").strip()}


def _external_source_identifier(source):
    """Best short label for a source in a list/notification -- whichever
    of these fields the source's type actually uses first, since not
    every engine has a host (Snowflake has account, BigQuery has
    project_id, SQLite has file_path -- see EXTERNAL_SOURCE_TYPES in
    app.js for the full per-type field list)."""
    return (
        source.get("name")
        or source.get("host")
        or source.get("account")
        or source.get("project_id")
        or source.get("file_path")
        or (source.get("type") or "").replace("_", " ")
        or "?"
    )


def _summarize_pending_external_sources(settings):
    """External sources with connection trouble, for the notifications
    badge/panel. Two distinct reasons, kept separate rather than lumped
    into one bucket:
      - "pending": no Fabric Connection assigned at all yet.
      - "broken": a connection IS assigned, but the last time someone
        pressed "Probar conexión (vía Fabric)" it came back Offline (see
        handler.py's /api/admin/fabric-connections/test, which persists
        fabric_connection_last_test_status/_at onto the source).
    Both are returned, but the caller (handler.py's notifications-summary
    route) deliberately only surfaces "broken" as an alert (fixed
    2026-08-26). "pending" is optional config -- it only gates the "Probar
    conexión" button and has zero effect on scan discovery -- so treating
    it as an alert was a false alarm; the Sources tab's own "Pendientes de
    conexión" card already shows it accurately, with that caveat.
    Pure config read, no live Fabric call of its own -- that live test is
    a long-running operation (up to ~60s), far too slow to run on every
    page load just to populate a badge; this only reads whatever the last
    ON-DEMAND test already recorded."""
    sources = settings.get("external_sources") or []
    pending = []
    broken = []
    for index, source in enumerate(sources):
        entry = {
            "index": index,
            "type": source.get("type") or "",
            "identifier": _external_source_identifier(source),
        }
        if not source.get("fabric_connection_id"):
            pending.append(entry)
        elif source.get("fabric_connection_last_test_status") == "Offline":
            broken.append({**entry, "tested_at": source.get("fabric_connection_last_test_at") or ""})
    return {
        "pending": pending,
        "pending_count": len(pending),
        "broken": broken,
        "broken_count": len(broken),
        "total_count": len(sources),
    }


def _get_detected_external_origins():
    """Distinct external (non-Fabric) hosts a completed scan actually found
    referenced by real dependencies -- lets the Sources tab offer "here's
    what to configure" instead of a blank form the admin has to guess a
    hostname for (2026-08-24 Fase 4). Reuses catalog.py's own object-
    lineage-candidate rows (bronze_item_object_lineage_candidates + bronze_
    pipeline_object_lineage_candidates, the same data _get_object_impact
    already searches) rather than re-reading anything -- those rows already
    carry source_type/source_server/source_database per object. Warehouse-
    only (returns found=False otherwise, same as every other Warehouse-
    dependent insight in this project) since there's no local-CSV mirror of
    these two bronze tables to fall back to."""
    rows = catalog._object_impact_candidate_rows()
    if rows is None:
        return {
            "found": False,
            "reason": "Necesita que 'Almacén de escritura' -> modo de lectura esté en Warehouse y que ya se haya hecho un escaneo completo.",
        }
    origins = {}
    for row in rows:
        source_type = row.get("source_type", "")
        server = (row.get("source_server", "") or "").strip()
        if not server or source_type in FABRIC_INTERNAL_SOURCE_TYPES:
            continue
        key = (source_type, server.casefold())
        entry = origins.setdefault(key, {"source_type": source_type, "host": server, "databases": set(), "object_count": 0})
        database = row.get("source_database", "")
        if database:
            entry["databases"].add(database)
        entry["object_count"] += 1
    results = sorted(
        (
            {
                "source_type": origin["source_type"],
                "host": origin["host"],
                "databases": sorted(origin["databases"]),
                "object_count": origin["object_count"],
            }
            for origin in origins.values()
        ),
        key=lambda origin: -origin["object_count"],
    )
    return {"found": True, "origins": results, "origin_count": len(results)}


def _persist_external_source_test_result(index, source, result):
    """Best-effort: writes last_test_ok/last_test_at/last_test_message onto
    the DISK copy of external_sources[index], not whatever the caller's own
    in-memory list currently holds -- "Probar conexión" has no per-row save
    (only "Save all" exists), so touching the disk copy through the
    caller's possibly-mid-edit list would silently persist unrelated
    unsaved changes elsewhere in the list too (2026-08-18 admin-panel audit
    finding this project already avoided once, see app.js's
    adminExternalSourceTestResultsCache comment). Only writes when the disk
    row at this index still looks like the same source (matched by
    _external_source_identifier) -- covers reordering/insert/delete drift
    between what the caller has open and what's actually saved; silently
    skips persistence otherwise (the caller still sees the test result in
    the response, it just won't survive a reload until they hit Save)."""
    settings = _load_admin_settings()
    sources = settings.get("external_sources") or []
    if index is None or not isinstance(index, int) or index < 0 or index >= len(sources):
        return
    disk_source = sources[index]
    if _external_source_identifier(disk_source) != _external_source_identifier(source):
        return
    disk_source["last_test_ok"] = bool(result.get("ok"))
    disk_source["last_test_at"] = _now_iso()
    disk_source["last_test_message"] = "" if result.get("ok") else (result.get("message") or "")
    _write_admin_settings(settings)


def _test_subprocess_env(session):
    """Without this, both test functions below always inherited the
    SERVER's own bare environment (subprocess.run's default when no `env=`
    is given) -- meaning even a signed-in admin's own AAD-token test always
    fell back to the shared `az` CLI session on the machine running the
    server, and failed outright if that session didn't exist there (real
    report, 2026-07-21: "Could not acquire ... token with 'az account
    get-access-token'" while testing a Warehouse from a signed-in browser
    session that had never touched that machine's own `az login`). Reuses
    the exact same per-session token minting a scan subprocess already
    gets -- a local import to avoid a module-load-order dependency between
    external_sources and scan_manager for what is otherwise a one-line
    reuse."""
    from .scan_manager import _build_scan_subprocess_env
    return _build_scan_subprocess_env(session)


def _test_lakehouse_connection(lakehouse, session=None):
    """Reuses the exact same script -- and the exact same SQL-Server-family
    connection path -- as an external source test: a Fabric Lakehouse's SQL
    analytics endpoint speaks the same wire protocol and takes the same AAD
    token as any azure_sql source (see backend/scripts/34_extract_sql_endpoint_
    object_catalog.ps1, which already connects to Lakehouse SQL endpoints
    this way). Not a fake success/failure -- a real `select 1`."""
    pwsh_path = _resolve_pwsh_command()
    if not pwsh_path:
        return {"ok": False, "message": "PowerShell ('pwsh') was not found on PATH."}
    if not lakehouse.get("sql_endpoint_connection_string") or not lakehouse.get("lakehouse_name"):
        return {"ok": False, "message": "Rellena 'Workspace', 'Lakehouse' y 'SQL endpoint' antes de probar la conexión."}

    args = [
        pwsh_path, "-NoLogo", "-File", str(TEST_EXTERNAL_SOURCE_SCRIPT_PATH),
        "-EngineType", "azure_sql",
        "-SourceHost", str(lakehouse["sql_endpoint_connection_string"]),
        "-Database", str(lakehouse["lakehouse_name"]),
        "-AuthMode", "aad_token",
        "-TrustServerCertificate",
    ]
    # Service-principal (permanent) auth mode, set from the admin panel's
    # write-target tab -- test with the SAME credential the real upload will
    # use, not the signed-in admin's own session, so "Probar conexion"
    # actually verifies what matters once auto_upload_after_scan starts
    # running unattended.
    if lakehouse.get("auth_mode") == "service_principal":
        args += [
            "-SpTenantId", str(lakehouse.get("sp_tenant_id") or ""),
            "-SpClientId", str(lakehouse.get("sp_client_id") or ""),
            "-SpClientSecretEnvVar", str(lakehouse.get("sp_client_secret_ref") or ""),
        ]
    try:
        result = subprocess.run(args, cwd=str(REPO_ROOT), capture_output=True, text=True, timeout=30, env=_test_subprocess_env(session))
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"ok": False, "message": f"Could not run the connection test: {exc}"}

    try:
        return json.loads(result.stdout.strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError):
        return {"ok": False, "message": (result.stderr or result.stdout or "Unknown error running the connection test.").strip()}
