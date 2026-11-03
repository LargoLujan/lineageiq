# NB_Backfill_Object_Source_Targets
#
# Fuente para un notebook Python de Fabric -- puerto pragmatico de
# scripts/58_backfill_semantic_sibling_source_targets.py y una adaptacion
# de scripts/61_backfill_item_flow_source_targets.py (ver docs/105_fabric_
# native_discovery_setup.md para el patron general). Cada bloque "# %%" es
# una celda -- pegalas en orden.
#
# 2026-08-19: de los 4 scripts locales 58-61, solo este alcance es viable
# hoy con datos 100% disponibles en Fabric-native:
#   - 58 (backfill entre modelos semanticos "hermanos"): autonomo, sin
#     dependencias externas -- portado fiel.
#   - 59/60 (backfill via metadata/catalogo externo + semantic_model_
#     datamart_dependencies.csv): NECESITAN scripts 08 (constructor base
#     de semantic_model_datamart_dependencies, no portado) y/o el catalogo
#     SQL externo (script 48, bloqueado por falta de ruta de red -- ver
#     docs/105, verificado 2026-08-17). Portarlos tal cual hoy produciria
#     cero backfills reales -- NO portados, documentado como gap explicito
#     en vez de codigo muerto.
#   - 61 (backfill via flow catalog de notebooks + catalogo SQL): su
#     entrada principal (notebook_lineage_flow_catalog.csv, script 53) NO
#     esta portada tampoco, pero su segunda via de evidencia (el catalogo
#     SQL de Fabric ya confirmado, dbo.bronze_sql_endpoint_object_catalog,
#     Fase A) SI esta disponible -- adaptado aqui como "backfill vía
#     catalogo confirmado" para bronze_item_object_lineage_candidates y
#     bronze_pipeline_object_lineage_candidates: si una fila candidata no
#     tiene servidor/bd pero su (schema, objeto) coincide con EXACTAMENTE
#     un target en el catalogo SQL confirmado, se rellena desde ahi.
#
# Depende de que hayan corrido antes: NB_Extract_SQL_Endpoint_Catalog
# (Fase A), NB_Discover_Object_Lineage, NB_Discover_Pipeline_Object_
# Lineage, NB_Discover_Semantic_Model_Lineage. Reescribe EN SITIO: dbo.
# bronze_semantic_model_view_candidates, dbo.bronze_item_object_lineage_
# candidates, dbo.bronze_pipeline_object_lineage_candidates. Escribe
# ademas dbo.bronze_source_target_backfill_summary con el desglose.
#
# Sin celda de parametros -- igual que NB_Harden_Object_Lineage_
# Candidates, corre siempre sobre las 3 tablas enteras.

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
from collections import Counter, defaultdict

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


MARKER_58 = "semantic_sibling_source_target_backfill"
MARKER_61 = "confirmed_catalog_source_target_backfill"

# %% [markdown]
# ## Paso 1 (script 58): backfill entre modelos semanticos "hermanos"
# Misma logica exacta que el script local: si una fila candidata de
# modelo semantico no tiene servidor/bd pero otra fila con el MISMO
# nombre de modelo, tabla semantica, esquema, objeto y tipo de objeto SI
# lo tiene (y solo hay un valor unico entre esos "hermanos"), se rellena.

# %%
def semantic_candidate_key(row):
    return (
        normalize_key(row.get("semantic_model_name", "")),
        normalize_key(row.get("semantic_table", "")),
        normalize_key(row.get("schema_name", "")),
        normalize_key(row.get("object_name", "")),
        normalize_key(row.get("object_type", "")),
    )


def backfill_semantic_siblings(rows):
    siblings_by_key = defaultdict(list)
    for row in rows:
        if row.get("source_server") and row.get("database_name") and row.get("object_name"):
            siblings_by_key[semantic_candidate_key(row)].append(row)

    changed = 0
    for row in rows:
        evidence = row.get("evidence", "") or ""
        if MARKER_58 in evidence:
            continue
        missing_target = not row.get("source_server") and not row.get("database_name") and row.get("object_name")
        if not missing_target:
            continue
        siblings = siblings_by_key.get(semantic_candidate_key(row), [])
        unique_targets = {(normalize_key(s.get("source_server", "")), normalize_key(s.get("database_name", ""))) for s in siblings}
        if len(unique_targets) != 1:
            continue
        sibling = siblings[0]
        row["source_server"] = sibling.get("source_server", "")
        row["database_name"] = sibling.get("database_name", "")
        addition = (
            f"Source endpoint backfilled by {MARKER_58} from sibling semantic model "
            f"'{sibling.get('semantic_model_qualified_name', '')}' with the same semantic model name, "
            "semantic table, schema, object name, and raw object type."
        )
        row["evidence"] = (evidence + " " + addition).strip() if evidence else addition
        changed += 1
    return changed

# %% [markdown]
# ## Paso 2 (adaptado de script 61): backfill de candidatos item/pipeline
# via el catalogo SQL ya confirmado (Fase A). Si una fila candidata no
# tiene servidor/bd pero su (esquema, objeto) coincide con EXACTAMENTE un
# target del catalogo confirmado, se rellena desde ahi.

# %%
def build_catalog_targets_by_object(catalog_rows):
    targets_by_object = defaultdict(set)
    for row in catalog_rows:
        key = (normalize_key(row.get("schema_name", "")), normalize_key(row.get("object_name", "")))
        server = row.get("source_server", "")
        database = row.get("source_database", "")
        if server and database:
            targets_by_object[key].add((server, database))
    return targets_by_object


def backfill_via_confirmed_catalog(rows, targets_by_object, source_server_field="source_server", source_database_field="source_database"):
    changed = 0
    for row in rows:
        evidence = row.get("evidence", "") or ""
        if MARKER_61 in evidence:
            continue
        missing_target = not row.get(source_server_field) and not row.get(source_database_field) and row.get("object_name")
        if not missing_target:
            continue
        key = (normalize_key(row.get("schema_name", "")), normalize_key(row.get("object_name", "")))
        candidates = targets_by_object.get(key, set())
        if len(candidates) != 1:
            continue
        server, database = next(iter(candidates))
        row[source_server_field] = server
        row[source_database_field] = database
        if "source_type" in row:
            row["source_type"] = "SQL"
        addition = (
            f"Source endpoint backfilled by {MARKER_61} from the confirmed SQL endpoint catalog "
            f"(unique match on schema '{row.get('schema_name', '')}', object '{row.get('object_name', '')}')."
        )
        row["evidence"] = (evidence + " " + addition).strip() if evidence else addition
        changed += 1
    return changed

# %% [markdown]
# ## Ejecutar

# %%
SEMANTIC_COLUMNS = [
    "workspace_name", "workspace_environment", "semantic_model_name", "semantic_model_qualified_name",
    "semantic_table", "source_server", "database_name", "schema_name", "object_name", "object_type",
    "definition_path", "confidence", "evidence",
]
ITEM_COLUMNS = [
    "workspace_name", "workspace_environment", "item_type", "item_name", "item_qualified_name",
    "source_type", "source_name", "source_qualified_name", "source_server", "source_database",
    "schema_name", "object_name", "object_type", "usage_type", "confidence", "definition_path", "evidence",
]
PIPELINE_COLUMNS = ITEM_COLUMNS + ["activity_name", "activity_type", "invoked_item_qualified_name"]
CATALOG_COLUMNS = [
    "object_key", "object_display_name", "source_type", "source_server", "source_database",
    "schema_name", "object_name", "object_type", "raw_object_type", "object_type_source",
    "object_type_confidence", "workspace_name", "workspace_environment", "sql_endpoint_name",
    "sql_endpoint_qualified_name", "sql_endpoint_id", "endpoint_resolution_method",
    "catalog_status", "evidence", "reviewed_at", "metadata_type_code", "metadata_type_desc",
    "create_date", "modify_date",
]
SUMMARY_COLUMNS = ["scope", "value", "count", "notes"]


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
    semantic_rows = read_table(connection, "bronze_semantic_model_view_candidates", SEMANTIC_COLUMNS)
    item_rows = read_table(connection, "bronze_item_object_lineage_candidates", ITEM_COLUMNS)
    pipeline_rows = read_table(connection, "bronze_pipeline_object_lineage_candidates", PIPELINE_COLUMNS)
    catalog_rows = read_table(connection, "bronze_sql_endpoint_object_catalog", CATALOG_COLUMNS)
finally:
    connection.close()

semantic_changed = backfill_semantic_siblings(semantic_rows) if semantic_rows else 0
print(f"Step 1 (semantic siblings): {semantic_changed} row(s) backfilled.")

targets_by_object = build_catalog_targets_by_object(catalog_rows)
print(f"Confirmed catalog objects available for step 2: {len(targets_by_object)} distinct (schema, object) key(s).")

item_changed = backfill_via_confirmed_catalog(item_rows, targets_by_object) if item_rows else 0
pipeline_changed = backfill_via_confirmed_catalog(pipeline_rows, targets_by_object) if pipeline_rows else 0
print(f"Step 2 (confirmed catalog match): {item_changed} item row(s) + {pipeline_changed} pipeline row(s) backfilled.")

summary_rows = [
    {"scope": "step1_semantic_siblings", "value": "rows_changed", "count": str(semantic_changed), "notes": "scripts/58 faithful port"},
    {"scope": "step2_confirmed_catalog", "value": "item_rows_changed", "count": str(item_changed), "notes": "scripts/61 adaptation (fabric-catalog match only)"},
    {"scope": "step2_confirmed_catalog", "value": "pipeline_rows_changed", "count": str(pipeline_changed), "notes": "scripts/61 adaptation (fabric-catalog match only)"},
    {"scope": "not_ported", "value": "scripts_59_60", "count": "0", "notes": "Need script 08 (semantic_model_datamart_dependencies, not ported) and/or script 48 (external SQL deep catalog, network-blocked) -- would produce 0 real backfills today, so not built."},
]

connection = connect_warehouse()
try:
    if semantic_rows:
        replace_table(connection, "bronze_semantic_model_view_candidates", SEMANTIC_COLUMNS, semantic_rows)
    if item_rows:
        replace_table(connection, "bronze_item_object_lineage_candidates", ITEM_COLUMNS, item_rows)
    if pipeline_rows:
        replace_table(connection, "bronze_pipeline_object_lineage_candidates", PIPELINE_COLUMNS, pipeline_rows)
    replace_table(connection, "bronze_source_target_backfill_summary", SUMMARY_COLUMNS, summary_rows)
finally:
    connection.close()

print("Done.")
