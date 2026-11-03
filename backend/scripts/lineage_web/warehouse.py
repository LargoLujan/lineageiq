"""Optional live read path for catalog.py.

67_upload_bronze_to_warehouse.ps1 already mirrors index/workspaces.csv,
index/items.csv and index/dependencies.csv into dbo.bronze_workspaces/
items/dependencies inside the admin's configured Fabric Warehouse after
every scan (when lakehouse.auto_upload_after_scan is on). This module lets
catalog.py query those same tables directly instead of the local CSVs --
so a web server process running anywhere (not just the machine that ran
the scan) can see data as fresh as the last successful upload, without a
redeploy or local file copy.

Off by default (lakehouse.web_read_mode == "local_files", see
constants.DEFAULT_ADMIN_SETTINGS); nothing here runs unless an admin
opts in from the panel's Lakehouse tab. Two ways to authenticate, tried
in this order: (1) a fixed service-principal identity (lakehouse.sp_*,
auth_mode="service_principal") when fully configured -- an admin's
deliberate, most predictable choice, matching the Warehouse *write*
side's own auth_mode; (2) the persisted delegated "service session" (see
service_session.py, added 2026-07-24) -- whichever admin most recently
signed in, reused here for tenants with no Entra app registration and
nobody with permission to create one. Either way this is one shared
identity for the server process's own reads, never the visitor's own
token -- every caller of this module has already cleared handler.py's own
"signed in or valid API key" gate (see handler.py's module docstring),
this is only about what THIS SERVER uses to reach the Warehouse itself.
"""
import os
import struct
import threading
import time

from .admin_settings import _load_admin_settings

# Tokens for this resource are typically valid ~60-90 minutes; refreshing a
# bit early avoids ever handing pyodbc an expired one. Not persisted across
# restarts, same as every other in-memory token/session in this package.
_TOKEN_REFRESH_MARGIN_SECONDS = 300
_TOKEN_LIFETIME_ASSUMPTION_SECONDS = 3000
_TABLE_CACHE_TTL_SECONDS = 30

_token_lock = threading.Lock()
_token_cache = {"access_token": "", "expires_at": 0.0}
_table_cache_lock = threading.Lock()
_table_cache = {}  # table_name -> (rows, fetched_at)


class WarehouseError(RuntimeError):
    """Base for every error this module raises; catalog.py catches this one
    type and falls back to local_files behavior rather than failing the
    request."""


class WarehouseNotConfiguredError(WarehouseError):
    pass


class WarehouseQueryError(WarehouseError):
    pass


def _lakehouse_settings(settings=None):
    settings = settings or _load_admin_settings()
    return settings, (settings.get("lakehouse") or {})


def is_warehouse_read_enabled():
    _settings, lakehouse = _lakehouse_settings()
    return (lakehouse.get("web_read_mode") or "local_files").strip() == "warehouse"


def _destination_fields_present(lakehouse):
    return bool(lakehouse.get("sql_endpoint_connection_string") and lakehouse.get("lakehouse_name"))


def _sp_fields_present(lakehouse):
    return bool(
        lakehouse.get("auth_mode") == "service_principal"
        and lakehouse.get("sp_client_id")
        and lakehouse.get("sp_client_secret_ref")
        and _destination_fields_present(lakehouse)
    )


def _acquire_sp_database_token(settings, lakehouse):
    try:
        import msal
    except ImportError as exc:  # pragma: no cover - msal is a pinned dependency
        raise WarehouseQueryError("msal is not installed -- run `pip install -r requirements-web.txt`.") from exc

    tenant_id = lakehouse.get("sp_tenant_id") or settings.get("tenant_id") or ""
    client_id = lakehouse.get("sp_client_id") or ""
    secret_ref = lakehouse.get("sp_client_secret_ref") or ""
    client_secret = os.environ.get(secret_ref, "") if secret_ref else ""
    if not (tenant_id and client_id and client_secret):
        raise WarehouseNotConfiguredError(
            "Service principal isn't fully configured -- tenant/client id or the "
            f"{secret_ref or '<sp_client_secret_ref>'} environment variable is missing."
        )

    app = msal.ConfidentialClientApplication(
        client_id,
        authority=f"https://login.microsoftonline.com/{tenant_id}",
        client_credential=client_secret,
    )
    result = app.acquire_token_for_client(scopes=["https://database.windows.net/.default"])
    if not result or "access_token" not in result:
        description = (result or {}).get("error_description", "no access_token returned")
        raise WarehouseQueryError(f"Could not acquire a Warehouse database token: {description}")
    return result["access_token"]


def _get_cached_token(settings, lakehouse):
    if _sp_fields_present(lakehouse):
        with _token_lock:
            now = time.time()
            if _token_cache["access_token"] and now < _token_cache["expires_at"] - _TOKEN_REFRESH_MARGIN_SECONDS:
                return _token_cache["access_token"]
            token = _acquire_sp_database_token(settings, lakehouse)
            _token_cache["access_token"] = token
            _token_cache["expires_at"] = now + _TOKEN_LIFETIME_ASSUMPTION_SECONDS
            return token

    # No service principal configured -- fall back to the persisted
    # delegated "service session" (see service_session.py) rather than
    # failing outright, same reasoning fabric_pipeline.py's own delegated
    # path uses. Not cached here separately: acquire_service_token's own
    # MSAL silent-acquire is already cheap/cached against the persisted
    # cache, and re-persists it if the underlying refresh token rotated.
    from .service_session import acquire_service_token
    token = acquire_service_token(settings, ["https://database.windows.net/.default"])
    if not token:
        raise WarehouseNotConfiguredError(
            "No service principal is configured and no admin has signed in yet to "
            "establish a delegated service session -- see the admin panel's Lakehouse tab."
        )
    return token


def _token_struct(token):
    # Same SQL_COPT_SS_ACCESS_TOKEN (1256) wire format already proven live
    # in 70_extract_control_framework_lineage.py's pyodbc.connect call.
    raw = token.encode("utf-16-le")
    return struct.pack(f"<I{len(raw)}s", len(raw), raw)


def _pick_odbc_driver(pyodbc):
    # A hardcoded "ODBC Driver 17 for SQL Server" broke outright the one
    # other place this project runs pyodbc (Fabric's own notebook Spark
    # runtime only ships Driver 18, not 17 -- see fabric_notebooks/NB_*.py's
    # own pick_odbc_driver()) -- picking whatever is actually installed,
    # newest first, avoids the same class of failure on any given host
    # (this container's own Dockerfile.render installs 18; a local/tunnel
    # run might have 17) instead of guessing a version number ahead of time.
    available = sorted(
        (d for d in pyodbc.drivers() if "ODBC Driver" in d and "SQL Server" in d),
        reverse=True,
    )
    if not available:
        raise WarehouseQueryError(
            "No 'ODBC Driver NN for SQL Server' is installed on this machine "
            f"(pyodbc.drivers() saw: {pyodbc.drivers()})."
        )
    return available[0]


def _escape_odbc_value(value):
    """Braces are the standard ODBC connection-string escape for a value
    that might contain a delimiter-looking character (';', '=', ...) --
    same technique already used for `driver` below, just factored out so
    server/database get it too. A literal '}' inside the value has to be
    doubled per that same convention. server/database here come from
    admin_settings.json (a signed-in admin's own saved config, via POST
    /api/admin/settings), so this is defense-in-depth rather than closing
    a remotely-exploitable hole (2026-08-17 security audit) -- but cheap
    enough that there's no reason not to."""
    return "{" + str(value).replace("}", "}}") + "}"


def _connect(settings, lakehouse):
    try:
        import pyodbc
    except ImportError as exc:
        raise WarehouseQueryError(
            "pyodbc is not installed -- run `pip install -r requirements-web.txt` "
            "(also needs the Microsoft ODBC Driver for SQL Server installed on this machine)."
        ) from exc

    token = _get_cached_token(settings, lakehouse)
    server = lakehouse["sql_endpoint_connection_string"]
    database = lakehouse["lakehouse_name"]
    driver = _pick_odbc_driver(pyodbc)
    conn_str = f"DRIVER={{{driver}}};SERVER={_escape_odbc_value(server)};DATABASE={_escape_odbc_value(database)};Encrypt=yes"
    try:
        return pyodbc.connect(conn_str, attrs_before={1256: _token_struct(token)}, timeout=15)
    except Exception as exc:  # noqa: BLE001 - any connect failure just triggers the caller's local-file fallback
        raise WarehouseQueryError(f"Could not connect to the Warehouse SQL endpoint: {exc}") from exc


def append_bronze_rows(table_name, columns, rows, create_table_ddl=None):
    """Appends rows to a bronze table over the same connection/auth
    query_bronze_table() uses. Unlike the Fabric notebooks' own
    replace_table() (DROP+CREATE+INSERT, the source of truth for every
    OTHER bronze table), this is deliberately append-only and never drops
    anything -- it exists for data this WEB SERVER itself produces (item-
    history diffs computed around a Fabric-pipeline scan, see scan_manager.
    py) that has no notebook of its own to own the table, not for
    re-deriving data a notebook already owns. create_table_ddl (a full
    "CREATE TABLE dbo.<table_name> (...)" statement) runs once, only if
    the table doesn't exist yet -- a no-op on every later call."""
    if not rows:
        return
    settings, lakehouse = _lakehouse_settings()
    if not _destination_fields_present(lakehouse):
        raise WarehouseNotConfiguredError(
            "Live Warehouse writes are enabled but the SQL endpoint/Lakehouse name "
            "aren't fully filled in on the admin panel's Lakehouse tab."
        )

    connection = _connect(settings, lakehouse)
    try:
        cursor = connection.cursor()
        if create_table_ddl:
            cursor.execute(f"IF OBJECT_ID('dbo.{table_name}', 'U') IS NULL BEGIN {create_table_ddl} END")
            connection.commit()
        placeholders = ", ".join("?" for _ in columns)
        insert_sql = f"INSERT INTO dbo.{table_name} ({', '.join(f'[{c}]' for c in columns)}) VALUES ({placeholders})"
        for row in rows:
            cursor.execute(insert_sql, [str(row.get(c, "") or "") for c in columns])
        connection.commit()
    except Exception as exc:  # noqa: BLE001 - surfaced to the caller as a WarehouseError, same contract as query_bronze_table
        raise WarehouseQueryError(f"Append into dbo.{table_name} failed: {exc}") from exc
    finally:
        connection.close()

    with _table_cache_lock:
        _table_cache.pop(table_name, None)


def ensure_bronze_column(table_name, column_name, column_type="VARCHAR(320)"):
    """One-time schema migration for a bronze table this web server owns
    (append_bronze_rows) that gained a new column after rows already
    existed -- ALTER TABLE ADD, leaving existing rows NULL for it, instead
    of the old/new column-count mismatch a local CSV would need a full
    rewrite to avoid (see scan_manager._migrate_history_schema_if_needed
    for that side of the same problem). Silently a no-op if the table
    doesn't exist yet (append_bronze_rows's own create_table_ddl will
    include the column from the start) or the column already exists --
    never raises, since a caller doing this ahead of a real write must not
    have that write blocked by a migration check that itself failed."""
    settings, lakehouse = _lakehouse_settings()
    if not _destination_fields_present(lakehouse):
        return
    try:
        connection = _connect(settings, lakehouse)
    except Exception:  # noqa: BLE001 - best-effort migration, never blocks the real write that follows
        return
    try:
        cursor = connection.cursor()
        try:
            cursor.execute(f"SELECT TOP 0 [{column_name}] FROM dbo.{table_name}")
            return  # column already exists
        except Exception:  # noqa: BLE001 - column (or table) missing; try to add it below
            connection.rollback()
        try:
            cursor.execute(f"ALTER TABLE dbo.{table_name} ADD [{column_name}] {column_type}")
            connection.commit()
        except Exception:  # noqa: BLE001 - table doesn't exist yet (create_table_ddl handles that) or ALTER genuinely failed either way, the caller's own write is what matters, not this
            connection.rollback()
    finally:
        connection.close()
    with _table_cache_lock:
        _table_cache.pop(table_name, None)


def delete_bronze_rows(table_name, where):
    """Deletes rows from a live-write table (see append_bronze_rows) whose
    columns match every condition in `where` (dict of column -> value,
    ANDed together). table_name and the KEYS of `where` are always
    internal constants a caller hardcodes, never request input -- only
    the VALUES vary per call, and those are always passed parameterized.
    Returns the number of rows deleted. Added for collaboration.py's
    comments/favorites (2026-08-17) -- the first callers that need to
    remove a specific row rather than only ever appending or replacing
    the whole table."""
    settings, lakehouse = _lakehouse_settings()
    if not _destination_fields_present(lakehouse):
        raise WarehouseNotConfiguredError(
            "Live Warehouse writes are enabled but the SQL endpoint/Lakehouse name "
            "aren't fully filled in on the admin panel's Lakehouse tab."
        )

    connection = _connect(settings, lakehouse)
    try:
        cursor = connection.cursor()
        conditions = " AND ".join(f"[{column}] = ?" for column in where)
        cursor.execute(f"DELETE FROM dbo.{table_name} WHERE {conditions}", list(where.values()))
        deleted = cursor.rowcount
        connection.commit()
    except Exception as exc:  # noqa: BLE001 - surfaced to the caller as a WarehouseError, same contract as query_bronze_table
        raise WarehouseQueryError(f"Delete from dbo.{table_name} failed: {exc}") from exc
    finally:
        connection.close()

    with _table_cache_lock:
        _table_cache.pop(table_name, None)
    return deleted


def query_bronze_table(table_name, use_cache=True):
    """Returns the same list[dict[str, str]] shape catalog._read_csv_rows
    gives from the matching index/*.csv, so callers don't need to know
    which source answered. table_name is always one of a fixed set of
    internal constants passed by catalog.py -- never request/user input --
    so the plain f-string below has no injection surface."""
    if use_cache:
        with _table_cache_lock:
            cached = _table_cache.get(table_name)
            if cached and (time.time() - cached[1]) < _TABLE_CACHE_TTL_SECONDS:
                return cached[0]

    settings, lakehouse = _lakehouse_settings()
    if not _destination_fields_present(lakehouse):
        raise WarehouseNotConfiguredError(
            "Live Warehouse reads are enabled but the SQL endpoint/Lakehouse name "
            "aren't fully filled in on the admin panel's Lakehouse tab."
        )

    connection = _connect(settings, lakehouse)
    try:
        cursor = connection.cursor()
        try:
            cursor.execute(f"SELECT * FROM dbo.{table_name}")
        except Exception as exc:  # noqa: BLE001 - e.g. table not uploaded yet -- a clean fallback trigger, not a crash
            raise WarehouseQueryError(f"Query against dbo.{table_name} failed: {exc}") from exc
        columns = [col[0] for col in cursor.description]
        rows = [dict(zip(columns, row)) for row in cursor.fetchall()]
    finally:
        connection.close()

    with _table_cache_lock:
        _table_cache[table_name] = (rows, time.time())
    return rows
