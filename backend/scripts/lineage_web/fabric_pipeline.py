"""Optional Fabric-native scan trigger.

Instead of scan_manager.py spawning a local PowerShell process (pwsh +
az CLI) to run the discovery scripts, this module triggers an existing
Fabric Data Pipeline on demand via the Job Scheduler REST API and polls it
for completion -- letting a scan run with zero local PowerShell/az-cli
dependency wherever the web server happens to be hosted. The actual
discovery work happens inside Fabric notebooks the pipeline calls, on the
tenant's own capacity compute (see docs/101_medallion_lakehouse_
provisioning.md).

This is the default scan mode (admin_settings.json ->
discovery_pipeline.mode == "fabric_pipeline"); scan_manager.py's existing
subprocess path (mode "local") is untouched. It needs an admin to have
built the pipeline in Fabric and filled in its workspace/item id.

Two ways to authenticate the Job Scheduler calls, tried in this order
(the delegated path exists for tenants with no Entra app registration
available and nobody with permission to create one): (1) a DELEGATED token from whichever signed-in user's session
triggered this run, reusing auth.py's existing device-code-login/MSAL
cache mechanism (_acquire_scoped_token) with no new Entra app needed --
the same public client id Azure CLI itself already uses and is already
consented in most tenants; (2) a service-principal token
(msal.ConfidentialClientApplication), same reasoning as warehouse.py, for
teams that DO have a real app registration and want fully unattended
operation (e.g. a scheduled trigger with nobody signed in at all -- not a
need this project has today, since there is no cron/scheduled-trigger
feature, only human- or already-running-scan-initiated triggers). A scan
triggered by a signed-in user threads that SAME session through its
entire lifetime, including the background poll loop that can run for
hours -- see scan_manager.py's _wait_for_fabric_pipeline_job -- so the
delegated token silently refreshes via MSAL's own refresh-token cache
exactly like a long `az login` session already does for the local
subprocess path today; it does not require the user's browser tab or
device to stay open or connected.

Endpoints confirmed live against Microsoft Learn's Job Scheduler (Core)
REST API docs:
  - Start: POST /v1/workspaces/{workspaceId}/items/{itemId}/jobs/instances?jobType=Pipeline
    (job instance id comes back as the last path segment of the Location
    response header, not in the body)
  - Poll:  GET  /v1/workspaces/{workspaceId}/items/{itemId}/jobs/instances/{jobInstanceId}
  - Cancel: POST /v1/workspaces/{workspaceId}/items/{itemId}/jobs/instances/{jobInstanceId}/cancel
"""
import json as _json
import threading
import time
import urllib.error
import urllib.request

from .admin_settings import _load_admin_settings

FABRIC_API_BASE = "https://api.fabric.microsoft.com/v1"

# Fabric's own job status vocabulary -> this project's status vocabulary
# (matches _scan_state["status"]/history.csv's existing succeeded/failed/
# cancelled -- see scan_manager.py's _wait_for_process). "Deduped" (Fabric
# collapsed this request into an already-running instance of the same job)
# is treated as a failure here: this project's own _scan_lock is what's
# supposed to prevent that from ever happening in the first place, so
# seeing it means something raced outside this process's control.
TERMINAL_STATUS_MAP = {
    "Completed": "succeeded",
    "Failed": "failed",
    "Cancelled": "cancelled",
    "Deduped": "failed",
}

_TOKEN_REFRESH_MARGIN_SECONDS = 300
_TOKEN_LIFETIME_ASSUMPTION_SECONDS = 3000

_token_lock = threading.Lock()
_token_cache = {"access_token": "", "expires_at": 0.0}


class FabricPipelineError(RuntimeError):
    pass


class FabricPipelineNotConfiguredError(FabricPipelineError):
    pass


def _pipeline_settings():
    settings = _load_admin_settings()
    return settings, (settings.get("discovery_pipeline") or {})


def is_fabric_pipeline_mode():
    _settings, pipeline = _pipeline_settings()
    return (pipeline.get("mode") or "local").strip() == "fabric_pipeline"


def _fields_present(pipeline):
    # Service-principal fields are now OPTIONAL: a delegated session token
    # (see _acquire_delegated_fabric_token) can drive every call below on
    # its own. _get_token still falls back to the SP fields here if/when
    # they're filled in and no usable session is available.
    return bool(pipeline.get("workspace_id") and pipeline.get("pipeline_item_id"))


def _sp_fields_present(pipeline):
    return bool(pipeline.get("sp_client_id") and pipeline.get("sp_client_secret_ref"))


def _acquire_delegated_fabric_token(session, settings):
    """Reuses whichever signed-in user's session triggered this run --
    silently mints a Fabric API token off the SAME MSAL token cache/refresh
    token auth.py's device-code sign-in already established, no new Entra
    app registration needed. Returns "" (never raises) when there's no
    session, no cache, or the silent acquisition fails for any reason --
    callers fall back to the service-principal path in that case, exactly
    like local scan scripts already fall back to the shared `az` CLI
    session when no user token is available."""
    if not session:
        return ""
    from .auth import _acquire_scoped_token
    token = _acquire_scoped_token(session, settings, ["https://api.fabric.microsoft.com/.default"])
    return token or ""


def _acquire_sp_fabric_token(settings, pipeline):
    import os

    try:
        import msal
    except ImportError as exc:  # pragma: no cover - msal is a pinned dependency
        raise FabricPipelineError("msal is not installed -- run `pip install -r requirements-web.txt`.") from exc

    tenant_id = pipeline.get("sp_tenant_id") or settings.get("tenant_id") or ""
    client_id = pipeline.get("sp_client_id") or ""
    secret_ref = pipeline.get("sp_client_secret_ref") or ""
    client_secret = os.environ.get(secret_ref, "") if secret_ref else ""
    if not (tenant_id and client_id and client_secret):
        raise FabricPipelineNotConfiguredError(
            "Service principal isn't fully configured -- tenant/client id or the "
            f"{secret_ref or '<sp_client_secret_ref>'} environment variable is missing."
        )
    app = msal.ConfidentialClientApplication(
        client_id,
        authority=f"https://login.microsoftonline.com/{tenant_id}",
        client_credential=client_secret,
    )
    result = app.acquire_token_for_client(scopes=["https://api.fabric.microsoft.com/.default"])
    if not result or "access_token" not in result:
        description = (result or {}).get("error_description", "no access_token returned")
        raise FabricPipelineError(f"Could not acquire a Fabric API token: {description}")
    return result["access_token"]


def _get_token(settings, pipeline, session=None):
    # Delegated-session tokens are NOT run through _token_cache below --
    # MSAL's own acquire_token_silent already caches/refreshes efficiently
    # against the session's own token cache, and different callers can
    # legitimately carry different sessions (unlike the single fixed SP
    # identity), so a shared module-level cache would be actively wrong
    # here. Only reached when the caller actually threaded a session
    # through (trigger_pipeline_run/get_job_status/cancel_job all default
    # to session=None, preserving the original SP-only behavior for
    # anyone who hasn't touched this).
    if session:
        delegated_token = _acquire_delegated_fabric_token(session, settings)
        if delegated_token:
            return delegated_token
        # Falls through to the service-principal path below if the
        # delegated attempt didn't work (no cache, expired, scope not
        # consented, ...) -- same degrade-not-crash contract as
        # auth._acquire_scoped_token itself.

    # Cached across polls of a single (possibly multi-hour) run so a
    # long full-tenant scan doesn't mint a fresh token on every ~15s poll
    # -- refreshed automatically once it's close to expiry, same pattern
    # as warehouse.py's token cache.
    with _token_lock:
        now = time.time()
        if _token_cache["access_token"] and now < _token_cache["expires_at"] - _TOKEN_REFRESH_MARGIN_SECONDS:
            return _token_cache["access_token"]
        if not _sp_fields_present(pipeline):
            raise FabricPipelineNotConfiguredError(
                "No usable signed-in session and no service principal configured on the "
                "admin panel's Fabric pipeline tab -- sign in, or fill in a service principal."
            )
        token = _acquire_sp_fabric_token(settings, pipeline)
        _token_cache["access_token"] = token
        _token_cache["expires_at"] = now + _TOKEN_LIFETIME_ASSUMPTION_SECONDS
        return token


def _request(method, url, token, json_body=None):
    data = _json.dumps(json_body).encode("utf-8") if json_body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            body = response.read()
            location = response.headers.get("Location", "")
            payload = _json.loads(body) if body else {}
            return response.status, payload, location
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise FabricPipelineError(f"Fabric API call to {url} failed ({exc.code}): {detail[:500]}") from exc
    except urllib.error.URLError as exc:
        raise FabricPipelineError(f"Could not reach the Fabric API: {exc.reason}") from exc


def trigger_pipeline_run(workspace_name_filter="", session=None, extra_parameters=None):
    """Starts an on-demand run of the configured discovery pipeline,
    passing the same scope a local -WorkspaceNameFilter would ("" for the
    whole tenant, or a semicolon-joined workspace name list). The
    pipeline's own parameter must be named WorkspaceNameFilter for this to
    have any effect on the Fabric side; harmless if the pipeline doesn't
    define it. Returns the new job instance id.

    extra_parameters (targeted sensitivity scan): an
    optional {name: value} dict merged into executionData.parameters
    alongside WorkspaceNameFilter -- e.g. {"TargetColumnsFilter": "..."}
    for NB_Discover_Column_Sensitivity.py's own new parameter (see that
    notebook's "## Parámetros" cell). Same "harmless if undefined on the
    Fabric side" property as WorkspaceNameFilter -- an admin who hasn't
    added this parameter to their real pipeline yet (a manual Fabric step,
    same as every other pipeline-wiring change this project makes) just
    sees it silently ignored, not an error.

    session, when given, is whichever signed-in user's session triggered
    this run -- see _get_token/_acquire_delegated_fabric_token. None (the
    default) preserves the original service-principal-only behavior.

    The pipeline's own notebooks get the SP client secret they need for
    their own Warehouse/Fabric-Admin-API calls from a private OneLake
    Files path (see fabric_notebooks/NB_*.py's get_client_secret()), not
    from a parameter here -- tried that once and a Fabric
    type-conversion error on the SpClientSecret parameter leaked the raw
    value into the job's own failureReason. Never doing that again."""
    settings, pipeline = _pipeline_settings()
    if not _fields_present(pipeline):
        raise FabricPipelineNotConfiguredError(
            "The discovery pipeline isn't fully configured on the admin panel's "
            "Fabric pipeline tab (workspace or pipeline id)."
        )
    token = _get_token(settings, pipeline, session=session)
    url = (
        f"{FABRIC_API_BASE}/workspaces/{pipeline['workspace_id']}/items/{pipeline['pipeline_item_id']}"
        "/jobs/instances?jobType=Pipeline"
    )
    parameters = {"WorkspaceNameFilter": workspace_name_filter or ""}
    parameters.update(extra_parameters or {})
    body = {"executionData": {"parameters": parameters}}
    status, _payload, location = _request("POST", url, token, json_body=body)
    if status not in (200, 202):
        raise FabricPipelineError(f"Unexpected status starting the pipeline run: {status}")
    if not location:
        raise FabricPipelineError("Fabric did not return a job instance location to poll.")
    return location.rstrip("/").rsplit("/", 1)[-1]


def get_job_status(job_instance_id, session=None):
    """Raw Fabric job instance payload (status/startTimeUtc/endTimeUtc/
    failureReason/...) -- callers translate payload["status"] through
    TERMINAL_STATUS_MAP themselves, so this module stays a thin transport
    layer rather than duplicating scan_manager.py's own status vocabulary.
    session: see trigger_pipeline_run's own docstring."""
    settings, pipeline = _pipeline_settings()
    if not _fields_present(pipeline):
        raise FabricPipelineNotConfiguredError("The discovery pipeline is no longer fully configured.")
    token = _get_token(settings, pipeline, session=session)
    url = (
        f"{FABRIC_API_BASE}/workspaces/{pipeline['workspace_id']}/items/{pipeline['pipeline_item_id']}"
        f"/jobs/instances/{job_instance_id}"
    )
    _status, payload, _location = _request("GET", url, token)
    return payload


def test_connection(pipeline_config, session=None):
    """Verifies a pipeline config (workspace_id/pipeline_item_id/sp_*)
    without starting a real run -- unlike trigger_pipeline_run, this takes
    the config straight from the admin panel's form (possibly unsaved yet),
    the same shape external_sources._test_lakehouse_connection and
    handler.py's /api/admin/lakehouse/test already use for their own
    "Probar conexión" buttons. Acquires a token the same way a real run
    would -- delegated session first, service principal as fallback -- and
    reads the pipeline item's own metadata (GET .../items/{id}) to confirm
    both the workspace/item ids and the caller's access, with no side
    effect on the Fabric side.

    This used to hard-require the service principal fields
    even though the admin panel's own hint text says they're optional and
    a signed-in session is the recommended way to run scans -- testing
    that exact recommended (no-SP) configuration always reported what
    looked like a failure ("Esta prueba verifica la cuenta de servicio...")
    without ever actually checking the workspace/pipeline ids. session
    (the caller's current signed-in session, if any) is now tried first,
    same fallback order trigger_pipeline_run/get_job_status/cancel_job
    already use via _get_token -- but this function deliberately does NOT
    call _get_token itself: _get_token's
    module-level _token_cache is shared with real scan runs, and this is a
    "test" button that can be clicked with edited-but-unsaved form values,
    a stale cached SP token from an earlier, different config would make
    this report "Conecta correctamente" without checking anything, AND a
    successful test here would poison that shared cache for the next real
    run. Re-acquiring fresh every time keeps this function's own "no side
    effect" promise true."""
    settings = _load_admin_settings()
    if not _fields_present(pipeline_config):
        return {"ok": False, "message": "Faltan campos: workspace o pipeline."}
    token = _acquire_delegated_fabric_token(session, settings) if session else ""
    if not token:
        if not _sp_fields_present(pipeline_config):
            return {"ok": False, "message": "No usable signed-in session and no service principal configured -- sign in, or fill in a service principal, to test this configuration."}
        try:
            token = _acquire_sp_fabric_token(settings, pipeline_config)
        except FabricPipelineError as exc:
            return {"ok": False, "message": str(exc)}
        except Exception as exc:  # noqa: BLE001 - MSAL performs authority/OIDC discovery in its constructor and can raise a plain ValueError (bad tenant id, unreachable host) instead of a FabricPipelineError; a "test" button must always return a JSON verdict, never crash the request with no response
            return {"ok": False, "message": f"No se pudo verificar: {exc}"}

    url = f"{FABRIC_API_BASE}/workspaces/{pipeline_config['workspace_id']}/items/{pipeline_config['pipeline_item_id']}"
    try:
        _status, payload, _location = _request("GET", url, token)
    except FabricPipelineError as exc:
        return {"ok": False, "message": str(exc)}
    except Exception as exc:  # noqa: BLE001 - same "always return a verdict" reasoning as above (e.g. a raw URLError/socket error _request doesn't already wrap)
        return {"ok": False, "message": f"No se pudo verificar: {exc}"}
    item_name = payload.get("displayName", "")
    item_type = payload.get("type", "")
    return {"ok": True, "message": f"Conecta correctamente: {item_type} \"{item_name}\".", "item_name": item_name, "item_type": item_type}


def cancel_job(job_instance_id, session=None):
    settings, pipeline = _pipeline_settings()
    if not _fields_present(pipeline):
        raise FabricPipelineNotConfiguredError("The discovery pipeline is no longer fully configured.")
    token = _get_token(settings, pipeline, session=session)
    url = (
        f"{FABRIC_API_BASE}/workspaces/{pipeline['workspace_id']}/items/{pipeline['pipeline_item_id']}"
        f"/jobs/instances/{job_instance_id}/cancel"
    )
    _request("POST", url, token)
