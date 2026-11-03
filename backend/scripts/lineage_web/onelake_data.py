"""Optional live-from-OneLake serving for the big generated JSON payloads
the frontend fetches under /data/* (lineage-explorer.json, object-impact.
json, notebook-super-lineage.json, graph-map-index.json, graph-map-index-
objects.json -- confirmed by grepping app.js/graph-map-data.js for every
`./data/*.json` fetch call; semantic-lineage.json, also under data/, has
no browser consumer and is deliberately not part of this list).

These files are published to a Fabric Lakehouse's OneLake Files area by
backend/scripts/72_publish_web_data_to_onelake.py, run locally (same
cadence as today's builds -- the JSON-BUILDING logic itself stays local,
only where the finished file lives changes). When enabled
(admin_settings.json -> onelake_data.mode == "onelake"), handler.py's
_serve_static asks this module for a local path instead of reading
frontend/semantic-lineage/data/<file> directly; this module downloads
from OneLake at most once per _CACHE_TTL_SECONDS, caches the raw bytes
under ONELAKE_CACHE_DIR, and pre-gzips a "<file>.gz" sibling next to it so
the EXISTING pregzipped-sibling fast path in _serve_static picks it up
for free -- nothing else about how a static file is served changes.

Off by default (onelake_data.mode == "local_files"); a fetch failure with
no usable cache yet returns None, and the caller falls back to the local
file (present or not -- a 404 either way is no worse than before this
existed). A stale cache is served (with a logged warning) in preference
to a hard failure once at least one successful fetch has happened, same
"degrade, don't break" philosophy as warehouse.py/fabric_pipeline.py.
"""
import gzip
import json
import threading
import time

from .admin_settings import _load_admin_settings
from .paths import ONELAKE_CACHE_DIR

# The two build_graph_map_index-produced files carry per-node
# is_certified/certified_note/certified_by fields (admin panel's
# "Certificaciones" tab) that the LOCAL build script bakes in from
# admin_settings.json's certified_items, but the Fabric-native
# NB_Build_Graph_Map.py deliberately can't (it has no access to that
# local, per-deployment file -- see its own comment). Merged in here
# instead, once per cache refresh rather than per request, so a
# certification takes effect the moment it's saved on the admin panel
# without needing to re-run the whole discovery pipeline.
_CERTIFIABLE_FILENAMES = {"graph-map-index.json", "graph-map-index-objects.json"}

# The only files this project's frontend actually loads -- see the module
# docstring. Anything else under /data/ is served from local disk
# regardless of onelake_data.mode.
PUBLISHED_FILENAMES = {
    "lineage-explorer.json",
    "object-impact.json",
    "notebook-super-lineage.json",
    "graph-map-index.json",
    "graph-map-index-objects.json",
}

_CACHE_TTL_SECONDS = 300
_ONELAKE_ACCOUNT_URL = "https://onelake.dfs.fabric.microsoft.com"

_cache_lock = threading.Lock()
_last_fetch_at = {}  # filename -> epoch seconds of last successful download


class OneLakeDataError(RuntimeError):
    pass


class OneLakeDataNotConfiguredError(OneLakeDataError):
    pass


def _onelake_settings():
    settings = _load_admin_settings()
    return settings, (settings.get("onelake_data") or {})


def is_onelake_data_enabled():
    _settings, config = _onelake_settings()
    return (config.get("mode") or "local_files").strip() == "onelake"


def _fields_present(config):
    # Only the destination itself is strictly required -- the service
    # principal is optional (see _credential's fallback below), for
    # tenants where nobody has permission to create a new Entra app
    # registration.
    return bool(config.get("workspace_name") and config.get("lakehouse_name"))


def _sp_fields_present(config):
    return bool(config.get("sp_client_id") and config.get("sp_client_secret_ref"))


class _ServiceSessionCredential:
    """A minimal azure-core TokenCredential backed by the persisted
    delegated "service session" (see service_session.py, added
    2026-07-24) -- lets DataLakeServiceClient use it exactly like any
    other azure-identity credential, no Entra app registration needed.
    Real token expiry isn't surfaced by acquire_service_token, so this
    always reports a short 5-minute one -- forces the SDK to ask again
    soon rather than risk handing out something past its real expiry;
    harmless, since the underlying MSAL silent-acquire this calls into is
    already cheap and internally cached against the persisted session."""

    def __init__(self, settings):
        self._settings = settings

    def get_token(self, *scopes, **_kwargs):
        from azure.core.credentials import AccessToken

        from .service_session import acquire_service_token
        token = acquire_service_token(self._settings, list(scopes))
        if not token:
            raise OneLakeDataError("No delegated service session token available.")
        return AccessToken(token, int(time.time()) + 300)


def _credential(settings, config):
    if _sp_fields_present(config):
        import os

        try:
            from azure.identity import ClientSecretCredential
        except ImportError as exc:
            raise OneLakeDataError("azure-identity is not installed -- run `pip install -r requirements-web.txt`.") from exc

        tenant_id = config.get("sp_tenant_id") or settings.get("tenant_id") or ""
        client_id = config.get("sp_client_id") or ""
        secret_ref = config.get("sp_client_secret_ref") or ""
        client_secret = os.environ.get(secret_ref, "") if secret_ref else ""
        if not (tenant_id and client_id and client_secret):
            raise OneLakeDataNotConfiguredError(
                "Service principal fields are filled in but the tenant/client id or the "
                f"{secret_ref or '<sp_client_secret_ref>'} environment variable is missing."
            )
        return ClientSecretCredential(tenant_id, client_id, client_secret)

    # Next: the persisted delegated "service session" (see
    # service_session.py, added 2026-07-24) -- whichever admin most
    # recently signed in, reused for tenants with no Entra app
    # registration and nobody with permission to create one. Works on a
    # host with no `az` CLI at all (e.g. Render), unlike the fallback
    # below -- checked BEFORE it for that reason.
    from .service_session import has_service_session
    if has_service_session():
        return _ServiceSessionCredential(settings)

    # Last resort: the shared `az` CLI session already used throughout
    # this project (67_upload_bronze_to_warehouse.ps1's Get-
    # DatabaseAccessToken, scan_manager._check_az_session, ...). Fine for
    # a server running on a machine that already has `az login` active
    # (this project's normal local + tunnel deployment), but a dead end
    # on a host like Render where no `az` CLI or session ever exists --
    # local/dev use only, in practice.
    try:
        from azure.identity import AzureCliCredential
    except ImportError as exc:
        raise OneLakeDataError("azure-identity is not installed -- run `pip install -r requirements-web.txt`.") from exc
    return AzureCliCredential()


def _download(filename):
    settings, config = _onelake_settings()
    if not _fields_present(config):
        raise OneLakeDataNotConfiguredError(
            "Live OneLake reads are enabled but the workspace/Lakehouse fields aren't "
            "filled in on the admin panel's OneLake data tab."
        )
    try:
        from azure.storage.filedatalake import DataLakeServiceClient
    except ImportError as exc:
        raise OneLakeDataError("azure-storage-file-datalake is not installed -- run `pip install -r requirements-web.txt`.") from exc

    credential = _credential(settings, config)
    service_client = DataLakeServiceClient(account_url=_ONELAKE_ACCOUNT_URL, credential=credential)
    file_system_client = service_client.get_file_system_client(config["workspace_name"])
    file_client = file_system_client.get_file_client(f"{config['lakehouse_name']}.Lakehouse/Files/generated/{filename}")
    try:
        return file_client.download_file().readall()
    except Exception as exc:  # noqa: BLE001 - any SDK/network failure funnels into the same fallback path
        raise OneLakeDataError(f"Could not download '{filename}' from OneLake: {exc}") from exc


def _merge_certified_items(data, filename):
    """Overlays admin_settings.json's certified_items onto matching nodes'
    is_certified/certified_note/certified_by fields. Best-effort: any
    parse problem just returns the original bytes unchanged, same
    "degrade, don't break" contract as the rest of this module."""
    if filename not in _CERTIFIABLE_FILENAMES:
        return data
    settings = _load_admin_settings()
    certification_index = {
        entry["qualified_name"]: entry
        for entry in (settings.get("certified_items") or [])
        if entry.get("qualified_name")
    }
    if not certification_index:
        return data
    try:
        payload = json.loads(data)
    except (ValueError, UnicodeDecodeError):
        return data

    changed = False
    for node in payload.get("nodes", []) or []:
        node_data = node.get("data") or {}
        certification = certification_index.get(node_data.get("id", ""))
        if certification:
            node_data["is_certified"] = True
            node_data["certified_note"] = certification.get("note", "")
            node_data["certified_by"] = certification.get("certified_by", "")
            changed = True
    if not changed:
        return data
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _merge_tags(data, filename):
    """Same idea as _merge_certified_items, one field over (roadmap Fase 2,
    2026-08-17: admin_settings.json's free-form tags)."""
    if filename not in _CERTIFIABLE_FILENAMES:
        return data
    settings = _load_admin_settings()
    tag_index = {}
    for entry in settings.get("tags") or []:
        qualified_name = entry.get("qualified_name", "")
        tag = (entry.get("tag") or "").strip()
        if not qualified_name or not tag:
            continue
        bucket = tag_index.setdefault(qualified_name, [])
        if tag not in bucket:
            bucket.append(tag)
    if not tag_index:
        return data
    try:
        payload = json.loads(data)
    except (ValueError, UnicodeDecodeError):
        return data

    changed = False
    for node in payload.get("nodes", []) or []:
        node_data = node.get("data") or {}
        tags = tag_index.get(node_data.get("id", ""))
        if tags:
            node_data["tags"] = tags
            changed = True
    if not changed:
        return data
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def test_connection(config):
    """Verifies an OneLake config (workspace_name/lakehouse_name/sp_*)
    without publishing anything -- unlike fetch_cached_path (which only
    ever reads a FILE that must already have been published), this
    confirms the workspace/Lakehouse Files area itself is reachable with
    the configured credential, even before the first real publish (2026-
    08-18, roadmap admin-panel completeness pass: this was the one Setup
    tab with a credential/connection but no safe "Probar conexión" --
    only a real "Publicar datos ahora"). Same "no side effect, always
    return a JSON verdict" contract as fabric_pipeline.test_connection
    and external_sources._test_lakehouse_connection. Takes the config
    straight from the admin panel's form (possibly unsaved yet), same as
    those two."""
    settings = _load_admin_settings()
    if not _fields_present(config):
        return {"ok": False, "message": "Faltan campos: workspace o Lakehouse."}
    try:
        from azure.storage.filedatalake import DataLakeServiceClient
    except ImportError as exc:
        return {"ok": False, "message": f"azure-storage-file-datalake no está instalado: {exc}"}

    try:
        credential = _credential(settings, config)
        service_client = DataLakeServiceClient(account_url=_ONELAKE_ACCOUNT_URL, credential=credential)
        file_system_client = service_client.get_file_system_client(config["workspace_name"])
        directory_client = file_system_client.get_directory_client(f"{config['lakehouse_name']}.Lakehouse/Files")
        directory_client.get_directory_properties()
    except OneLakeDataError as exc:
        return {"ok": False, "message": str(exc)}
    except Exception as exc:  # noqa: BLE001 - any SDK/network failure (bad workspace/Lakehouse name, no access, ...) must still return a verdict, not crash the request -- same reasoning as fabric_pipeline.test_connection's own broad catch
        return {"ok": False, "message": f"No se pudo verificar: {exc}"}
    return {"ok": True, "message": f"Conecta correctamente con {config['workspace_name']} / {config['lakehouse_name']}.Lakehouse/Files."}


def fetch_cached_path(filename):
    """Returns a local Path to a fresh-enough copy of `filename`, or None
    if it's never been successfully fetched and a fresh attempt also
    fails. Never raises -- every failure mode degrades to "let the caller
    fall back to the local file" instead."""
    if filename not in PUBLISHED_FILENAMES:
        return None

    cache_path = ONELAKE_CACHE_DIR / filename
    with _cache_lock:
        last_fetch = _last_fetch_at.get(filename, 0.0)
        if cache_path.is_file() and (time.time() - last_fetch) < _CACHE_TTL_SECONDS:
            return cache_path

    try:
        data = _download(filename)
    except OneLakeDataError as exc:
        if cache_path.is_file():
            print(f"[onelake_data] Refresh of '{filename}' failed, serving stale cache: {exc}")
            return cache_path
        print(f"[onelake_data] Could not fetch '{filename}' and no cache exists yet: {exc}")
        return None

    data = _merge_certified_items(data, filename)
    data = _merge_tags(data, filename)
    ONELAKE_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    cache_path.write_bytes(data)
    # Pre-gzip the cached copy once per refresh (not per request) -- same
    # sibling convention as docker/gzip_data.py's build-time pass, so
    # handler.py's existing pregzipped-sibling fast path just works.
    if len(data) > 1024:
        gz_path = cache_path.with_name(cache_path.name + ".gz")
        gz_path.write_bytes(gzip.compress(data, compresslevel=6))
    with _cache_lock:
        _last_fetch_at[filename] = time.time()
    return cache_path
