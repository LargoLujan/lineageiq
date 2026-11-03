# NB_Discover_Column_Sensitivity
#
# Fuente para un notebook Python de Fabric -- roadmap Fase 2
# ("sensibilidad por contenido real"), 2026-08-17, rediseñado 2026-08-25
# (panel admin, petición explícita: filtrar SIEMPRE por nombre de columna
# antes de tocar contenido real, y guardar ejemplos reales -- no solo un
# porcentaje -- para que un admin pueda juzgar a simple vista). Mismo
# alcance nativo de Fabric que NB_Discover_Column_Profile.py (mismos
# workspaces donde la SP ya tiene rol de datos, cero permisos nuevos)
# -- ver docs/108_column_sensitivity_native_scope.md.
#
# Paso 0 (nuevo, obligatorio): antes de tocar el contenido de una columna,
# su NOMBRE tiene que coincidir con el clasificador por nombre (mismos
# patrones que backend/scripts/lineage_web/sensitivity_classifier.py,
# copiados aquí porque este notebook es self-contained a propósito, igual
# que el resto de notebooks "Discover"/"Extract" de este proyecto -- ver
# CONTENT_PATTERN_CATEGORIES abajo). Esto evita muestrear TODAS las
# columnas de texto del alcance (podía ser lento y no aportaba nada en las
# columnas que ya sabíamos, por el nombre, que no eran candidatas) --
# ahora solo se sampean las columnas que ya pasaron ese primer filtro.
#
# POLÍTICA DE PRIVACIDAD DE LOS VALORES DE MUESTRA: algunos responsables
# de datos prefieren guardar hasta SAMPLE_VALUES_TO_STORE valores de
# ejemplo reales
# (truncados) por columna, en su propia tabla separada
# (dbo.bronze_column_sensitivity_samples), para que el panel admin (solo
# accesible a administradores, ver handler.py's _require_admin) pudiera
# mostrarlos y confirmar de un vistazo si de verdad era un dato sensible
# -- especialmente útil para categorías sin patrón de contenido fiable
# (nombre/dirección/fecha de nacimiento/género/salud). Es una decisión
# de política legítima, pero es de quien opera CADA instalación, no algo que
# este proyecto deba activar por defecto para cualquiera que lo clone --
# ver STORE_REAL_SAMPLE_VALUES arriba (False por defecto en este repo).
# Con el flag en False (el default), este notebook mantiene la garantía
# original: ningún valor real de celda sale nunca de esta sesión de
# Spark, solo un porcentaje/conteo. dbo.bronze_column_sensitivity_content
# NUNCA lleva un valor real, con el flag en el estado que sea -- esa
# tabla mantiene su propia garantía siempre intacta.

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
import urllib.error
import urllib.request

FABRIC_API_BASE_URL = "https://api.fabric.microsoft.com/v1"

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"
ONELAKE_WORKSPACE_NAME = "<tu-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<tu-lakehouse-onelake>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"
WAREHOUSE_SQL_ENDPOINT = "<tu-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<NombreDelWarehouse>"

# Mismo alcance Fase 1 que NB_Discover_Column_Profile.py -- ver ese
# notebook y docs/108 para el porqué.
TARGET_WORKSPACE_NAMES = [
    "Contoso-Sales_Prod",
    "Fabrikam-Ops_Dev",
    "Fabrikam-Ops_Prod",
]

MAX_TABLES_PER_LAKEHOUSE = 200
SAMPLE_SIZE = 500  # filas no-nulas muestreadas por columna, no toda la tabla (2026-08-25: subido de 200 a 500, petición explícita)

# APAGADO POR DEFECTO A PROPÓSITO (2026-08-27, saneado para publicación
# open source -- ver H-01 en la auditoría de este repo): guardar valores
# reales de celda, aunque truncados, en dbo.bronze_column_sensitivity_
# samples es una decisión de política de privacidad que cada responsable
# de datos debe tomar explícitamente para SU tenant (ver "POLÍTICA DE
# PRIVACIDAD" arriba) -- no algo que un fork de este proyecto
# deba heredar por defecto sin haber tomado esa misma decisión él mismo.
# Con esto en False (el default), el notebook vuelve a la garantía
# original: ningún valor de celda real sale nunca de esta sesión de
# Spark, solo el porcentaje/conteo de coincidencia. Ponlo a True solo tras
# una decisión explícita y documentada de quien opera ESTA instalación.
STORE_REAL_SAMPLE_VALUES = False
SAMPLE_VALUES_TO_STORE = 20  # de esas SAMPLE_SIZE filas, cuántas se guardan como ejemplo real en bronze_column_sensitivity_samples -- solo aplica si STORE_REAL_SAMPLE_VALUES es True
MAX_SAMPLE_VALUE_LENGTH = 120  # trunca cada ejemplo guardado -- ver un valor de 120 caracteres ya basta para juzgar, no hace falta el campo entero
MIN_MATCH_PERCENTAGE_TO_KEEP = 0.0  # DIAGNOSTICO 2026-08-17: temporalmente en 0 para ver si hay senal alguna antes de decidir el umbral final -- sigue sin decidirse; sube esto en tu propio fork en cuanto tengas señal real de qué porcentaje separa ruido de coincidencias genuinas

# Mismas claves/categoría/patrones que backend/scripts/lineage_web/
# sensitivity_classifier.py's SENSITIVITY_CATEGORIES -- copiados aquí a
# propósito (notebook self-contained, no puede importar ese módulo) para
# el Paso 0 nuevo: filtrar por NOMBRE antes de sampear contenido. Mantener
# en sync a mano si sensitivity_classifier.py cambia sus patrones.
NAME_PATTERNS = {
    "email": re.compile(r"e-?mail", re.IGNORECASE),
    "phone": re.compile(r"telefono|\bphone\b|movil(?!idad)", re.IGNORECASE),
    "national_id": re.compile(r"\bdni\b|\bnif\b|\bnie\b|passport|pasaporte|\bssn\b", re.IGNORECASE),
    "person_name": re.compile(r"apellido|surname|last_?name|first_?name|full_?name", re.IGNORECASE),
    "address": re.compile(r"direccion|\baddress\b|domicilio", re.IGNORECASE),
    "birth_date": re.compile(r"nacimiento|\bbirth", re.IGNORECASE),
    "financial": re.compile(r"\biban\b|bank_?account|credit_?card|tarjeta|\bsalary\b|salario|sueldo|card_?number", re.IGNORECASE),
    "health": re.compile(r"\bhealth\b|\bsalud\b|medical|diagnostico|discapacidad|disability", re.IGNORECASE),
    "gender": re.compile(r"\bgender\b|\bsexo\b", re.IGNORECASE),
}


def classify_column_name(column_name):
    return [key for key, pattern in NAME_PATTERNS.items() if pattern.search(column_name or "")]


# Solo las categorías con un formato reconocible por regex se pueden
# CONFIRMAR automáticamente por contenido -- person_name/address/
# birth_date/gender/health no tienen un patrón de contenido fiable, así
# que para esas match_percentage/match_count quedan en blanco (no "0%",
# que sugeriría que se comprobó y no coincidió) y la confirmación depende
# de que un admin revise los SAMPLE_VALUES_TO_STORE ejemplos guardados.
CONTENT_PATTERNS = {
    "email": re.compile(r"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"),
    "phone": re.compile(r"^\+?[0-9][0-9\s\-()]{6,14}[0-9]$"),
    # DNI espanol: 8 digitos + letra. NIE: X/Y/Z + 7 digitos + letra.
    "national_id": re.compile(r"^(?:[0-9]{8}[A-Za-z]|[XYZxyz][0-9]{7}[A-Za-z])$"),
    # IBAN (2 letras + 2 digitos + hasta 30 alfanumericos) o tarjeta
    # (13-19 digitos, con o sin separadores) -- checksum real (Luhn/IBAN
    # mod-97) no implementado en esta primera version; heuristico, mismo
    # espiritu "digno de revision humana" que sensitivity_classifier.py.
    "financial": re.compile(r"^(?:[A-Za-z]{2}[0-9]{2}[A-Za-z0-9]{10,30}|(?:[0-9][ \-]?){13,19})$"),
}

# Solo columnas capaces de contener un valor por fila -- ver el
# comentario de salvaguarda de privacidad arriba (dbo.bronze_column_
# sensitivity_content sigue sin llevar NUNCA un valor real). NUNCA anadir
# aqui un campo tipo "sample_value"/"example"/"evidence_raw" -- esos
# viven en SAMPLE_COLUMNS/bronze_column_sensitivity_samples, aparte.
SENSITIVITY_COLUMNS = [
    "workspace_name", "lakehouse_name", "table_name", "column_name", "data_type",
    "category", "sample_size", "match_count", "match_percentage", "checked_at",
]

# 2026-08-25: tabla nueva, separada a propósito -- ver el comentario de
# "CAMBIO DE POLÍTICA DE PRIVACIDAD" al principio del notebook. sample_
# values_json es una lista JSON de hasta SAMPLE_VALUES_TO_STORE strings
# truncados a MAX_SAMPLE_VALUE_LENGTH caracteres cada uno -- el único sitio
# de todo este notebook donde un valor de fila real llega al Warehouse.
SAMPLE_COLUMNS = [
    "workspace_name", "lakehouse_name", "table_name", "column_name",
    "categories_matched", "sample_size", "sample_values_json", "checked_at",
]

# %% [markdown]
# ## Parámetros
# Marca esta celda como celda de parámetros en Fabric. El panel admin
# (Sensibilidad -> "Escanear contenido de los seleccionados", 2026-08-24
# Fase 6) la rellena con las tablas que un admin marcó a mano en la lista
# de sensibilidad-por-nombre, para no tener que escanear contenido real de
# TODAS las tablas en TARGET_WORKSPACE_NAMES cada vez -- vacío (por
# defecto) = comportamiento sin cambios, escanea todo lo que ya escaneaba.
# Formato: "workspace::tabla" separadas por ";" (mismo separador que
# WorkspaceNameFilter ya usa en otros notebooks). Granularidad de TABLA,
# no de columna -- la lista de sensibilidad-por-nombre que alimenta esta
# selección solo sabe qué OBJETOS tienen alguna columna sospechosa, no
# cuál columna exactamente (ver purview_insights._get_sensitivity_overview);
# una vez elegida una tabla, sus columnas de texto se muestrean todas,
# igual que el comportamiento sin filtro.

# %%
TargetColumnsFilter = ""

# %%
def _parse_target_columns_filter(raw):
    entries = set()
    for chunk in (raw or "").split(";"):
        parts = chunk.strip().split("::")
        if len(parts) == 2 and all(parts):
            entries.add(tuple(p.strip().casefold() for p in parts))
    return entries


_target_tables = _parse_target_columns_filter(TargetColumnsFilter)
if _target_tables:
    print(f"TargetColumnsFilter active: {len(_target_tables)} table(s) -- everything else in TARGET_WORKSPACE_NAMES is skipped this run.")

# %% [markdown]
# ## Autenticación (mismo patrón que los notebooks de descubrimiento)

# %%
def get_sp_client_secret():
    onelake_path = (
        f"abfss://{ONELAKE_WORKSPACE_NAME}@onelake.dfs.fabric.microsoft.com/"
        f"{ONELAKE_LAKEHOUSE_NAME}.Lakehouse/{SP_SECRET_ONELAKE_PATH}"
    )
    return notebookutils.fs.head(onelake_path, 200).strip()


_client_secret_cache = None


def acquire_token(scope):
    global _client_secret_cache
    if _client_secret_cache is None:
        _client_secret_cache = get_sp_client_secret()
    app = msal.ConfidentialClientApplication(
        SP_CLIENT_ID,
        authority=f"https://login.microsoftonline.com/{SP_TENANT_ID}",
        client_credential=_client_secret_cache,
    )
    result = app.acquire_token_for_client(scopes=[scope])
    if not result or "access_token" not in result:
        raise RuntimeError(f"Could not acquire a token for {scope}: {(result or {}).get('error_description', '')}")
    return result["access_token"]


def token_struct(token):
    raw = token.encode("utf-16-le")
    return struct.pack(f"<I{len(raw)}s", len(raw), raw)


def pick_odbc_driver():
    available = sorted((d for d in pyodbc.drivers() if "ODBC Driver" in d and "SQL Server" in d), reverse=True)
    if not available:
        raise RuntimeError(f"No ODBC driver found (saw: {pyodbc.drivers()})")
    return available[0]


def connect_warehouse():
    db_token = acquire_token("https://database.windows.net/.default")
    conn_str = f"DRIVER={{{pick_odbc_driver()}}};SERVER={WAREHOUSE_SQL_ENDPOINT};DATABASE={WAREHOUSE_DATABASE_NAME};Encrypt=yes"
    return pyodbc.connect(conn_str, attrs_before={1256: token_struct(db_token)}, timeout=30)


def connect_lakehouse(sql_endpoint, database_name):
    db_token = acquire_token("https://database.windows.net/.default")
    conn_str = f"DRIVER={{{pick_odbc_driver()}}};SERVER={sql_endpoint};DATABASE={database_name};Encrypt=yes"
    return pyodbc.connect(conn_str, attrs_before={1256: token_struct(db_token)}, timeout=30)


def fabric_get(path):
    token = acquire_token("https://api.fabric.microsoft.com/.default")
    req = urllib.request.Request(f"{FABRIC_API_BASE_URL}/{path.lstrip('/')}", method="GET")
    req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))

# %% [markdown]
# ## Paso 1: resolver workspaces + lakehouses + su SQL endpoint (mismo
# catálogo ya escrito por NB_Discover_Workspaces_Items.py)

# %%
connection = connect_warehouse()
cursor = connection.cursor()

placeholders = ", ".join("?" for _ in TARGET_WORKSPACE_NAMES)
cursor.execute(
    f"SELECT workspace_name, technical_id FROM dbo.bronze_workspaces WHERE workspace_name IN ({placeholders})",
    TARGET_WORKSPACE_NAMES,
)
workspace_id_by_name = {r[0]: r[1] for r in cursor.fetchall()}

cursor.execute(
    f"SELECT workspace_name, item_name, technical_id FROM dbo.bronze_items "
    f"WHERE workspace_name IN ({placeholders}) AND item_type = 'Lakehouse'",
    TARGET_WORKSPACE_NAMES,
)
lakehouses = [{"workspace_name": r[0], "lakehouse_name": r[1], "lakehouse_id": r[2]} for r in cursor.fetchall()]
connection.close()
print(f"Lakehouses in scope: {len(lakehouses)}")

endpoint_resolution_errors = []
for lh in lakehouses:
    workspace_id = workspace_id_by_name.get(lh["workspace_name"], "")
    if not workspace_id or not lh["lakehouse_id"]:
        endpoint_resolution_errors.append({**lh, "reason": "missing_workspace_or_lakehouse_id", "workspace_id": workspace_id})
        continue
    try:
        detail = fabric_get(f"workspaces/{workspace_id}/lakehouses/{lh['lakehouse_id']}")
        sql_props = ((detail.get("properties") or {}).get("sqlEndpointProperties") or {})
        lh["sql_endpoint"] = sql_props.get("connectionString", "")
        lh["database_name"] = lh["lakehouse_name"]
        if not lh["sql_endpoint"]:
            endpoint_resolution_errors.append({**lh, "reason": "no_connection_string_in_response", "raw_sql_props": sql_props})
    except Exception as exc:  # noqa: BLE001
        endpoint_resolution_errors.append({**lh, "reason": f"{type(exc).__name__}: {exc}"})

lakehouses_with_endpoint = [lh for lh in lakehouses if lh.get("sql_endpoint")]
print(f"Lakehouses with a resolved SQL endpoint: {len(lakehouses_with_endpoint)}")

# %% [markdown]
# ## Paso 2: por cada tabla, filtrar columnas de texto por NOMBRE primero
# (Paso 0) y solo entonces muestrear contenido de las que pasaron el filtro

# %%
sensitivity_rows = []
sample_rows = []
gap_rows = []

_TEXT_TYPES = ("varchar", "nvarchar", "char", "nchar", "text", "ntext")

for lh in lakehouses_with_endpoint:
    try:
        lh_conn = connect_lakehouse(lh["sql_endpoint"], lh["database_name"])
        lh_cursor = lh_conn.cursor()
    except Exception as exc:  # noqa: BLE001
        gap_rows.append({**lh, "gap_reason": "connection_failed", "error": f"{type(exc).__name__}: {exc}"})
        continue

    try:
        lh_cursor.execute(
            "SELECT TABLE_SCHEMA, TABLE_NAME FROM INFORMATION_SCHEMA.TABLES "
            "WHERE TABLE_TYPE = 'BASE TABLE' ORDER BY TABLE_SCHEMA, TABLE_NAME"
        )
        tables = [(r[0], r[1]) for r in lh_cursor.fetchall()][:MAX_TABLES_PER_LAKEHOUSE]
    except Exception as exc:  # noqa: BLE001
        gap_rows.append({**lh, "gap_reason": "list_tables_failed", "error": f"{type(exc).__name__}: {exc}"})
        lh_conn.close()
        continue

    for schema, table in tables:
        if _target_tables and (lh["workspace_name"].casefold(), f"{schema}.{table}".casefold()) not in _target_tables:
            continue
        try:
            lh_cursor.execute(
                "SELECT COLUMN_NAME, DATA_TYPE FROM INFORMATION_SCHEMA.COLUMNS "
                "WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND DATA_TYPE IN ({}) ORDER BY ORDINAL_POSITION".format(
                    ", ".join("?" for _ in _TEXT_TYPES)
                ),
                schema, table, *_TEXT_TYPES,
            )
            text_columns = [{"column_name": r[0], "data_type": r[1]} for r in lh_cursor.fetchall()]
        except Exception as exc:  # noqa: BLE001
            gap_rows.append({
                "workspace_name": lh["workspace_name"], "lakehouse_name": lh["lakehouse_name"],
                "table_name": f"{schema}.{table}", "gap_reason": "list_columns_failed",
                "error": f"{type(exc).__name__}: {exc}",
            })
            continue

        now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        for col in text_columns:
            name = col["column_name"]

            # Paso 0: filtro por NOMBRE primero -- si el nombre de la
            # columna no sugiere ninguna categoría sensible, no se lanza
            # ninguna consulta de contenido para ella. Esto es lo que
            # evita samplear "todas las columnas de texto de golpe".
            name_matched_categories = classify_column_name(name)
            if not name_matched_categories:
                continue

            safe = name.replace("]", "]]")
            try:
                # TABLESAMPLE no aplica bien a tablas pequenas/Delta via
                # el endpoint SQL -- ORDER BY NEWID() con TOP es mas lento
                # en tablas grandes pero funciona de forma consistente,
                # aceptable dado SAMPLE_SIZE acotado.
                lh_cursor.execute(
                    f"SELECT TOP {SAMPLE_SIZE} [{safe}] FROM [{schema}].[{table}] "
                    f"WHERE [{safe}] IS NOT NULL ORDER BY NEWID()"
                )
                sampled_values = [str(r[0]).strip() for r in lh_cursor.fetchall()]
            except Exception as exc:  # noqa: BLE001
                gap_rows.append({
                    "workspace_name": lh["workspace_name"], "lakehouse_name": lh["lakehouse_name"],
                    "table_name": f"{schema}.{table}", "column_name": name,
                    "gap_reason": "sample_query_failed", "error": f"{type(exc).__name__}: {exc}",
                })
                continue

            sample_size = len(sampled_values)
            if sample_size == 0:
                continue

            for category in name_matched_categories:
                pattern = CONTENT_PATTERNS.get(category)
                if pattern is not None:
                    match_count = sum(1 for v in sampled_values if pattern.match(v))
                    match_percentage = round(100.0 * match_count / sample_size, 2)
                    if match_percentage < MIN_MATCH_PERCENTAGE_TO_KEEP:
                        continue
                    match_count_out, match_percentage_out = match_count, match_percentage
                else:
                    # Sin patron de contenido fiable para esta categoria
                    # (person_name/address/birth_date/gender/health) --
                    # queda en blanco (no "0%") para no sugerir que se
                    # comprobo y no coincidio; la confirmacion depende de
                    # que un admin revise los ejemplos guardados abajo.
                    match_count_out, match_percentage_out = "", ""
                sensitivity_rows.append({
                    "workspace_name": lh["workspace_name"], "lakehouse_name": lh["lakehouse_name"],
                    "table_name": f"{schema}.{table}", "column_name": name, "data_type": col["data_type"],
                    "category": category, "sample_size": sample_size, "match_count": match_count_out,
                    "match_percentage": match_percentage_out, "checked_at": now_iso,
                })

            # Ejemplos reales (2026-08-25, ver "CAMBIO DE POLITICA DE
            # PRIVACIDAD" al principio del notebook) -- una fila por
            # columna, no por categoria, con hasta SAMPLE_VALUES_TO_STORE
            # valores truncados. Unico punto de todo el notebook donde un
            # valor de fila real llega al Warehouse -- por eso queda detrás
            # de STORE_REAL_SAMPLE_VALUES (False por defecto, ver arriba).
            if STORE_REAL_SAMPLE_VALUES:
                example_values = [v[:MAX_SAMPLE_VALUE_LENGTH] for v in sampled_values[:SAMPLE_VALUES_TO_STORE]]
                sample_rows.append({
                    "workspace_name": lh["workspace_name"], "lakehouse_name": lh["lakehouse_name"],
                    "table_name": f"{schema}.{table}", "column_name": name,
                    "categories_matched": ",".join(name_matched_categories),
                    "sample_size": sample_size, "sample_values_json": json.dumps(example_values, ensure_ascii=False),
                    "checked_at": now_iso,
                })
            # sampled_values sale de scope aqui -- la siguiente columna
            # empieza una muestra nueva, nada se acumula entre columnas.

    lh_conn.close()

print(f"Sensitivity signals kept (>= {MIN_MATCH_PERCENTAGE_TO_KEEP}% match, or name-matched with no content pattern): {len(sensitivity_rows)}. Columns with stored examples: {len(sample_rows)}. Gaps: {len(gap_rows)}.")

# %% [markdown]
# ## Escribir en el Warehouse (reemplazo completo de ambas tablas).
# Verificacion final de que bronze_column_sensitivity_content -- la tabla
# de porcentajes -- sigue sin llevar nunca un valor de contenido real.

# %%
for row in sensitivity_rows:
    assert set(row.keys()) <= set(SENSITIVITY_COLUMNS), f"Unexpected field on a row about to be written: {row.keys()}"
for row in sample_rows:
    assert set(row.keys()) <= set(SAMPLE_COLUMNS), f"Unexpected field on a sample row about to be written: {row.keys()}"

connection = connect_warehouse()
cursor = connection.cursor()

cursor.execute("IF OBJECT_ID('dbo.bronze_column_sensitivity_content', 'U') IS NOT NULL DROP TABLE dbo.bronze_column_sensitivity_content;")
column_defs = ", ".join(f"[{c}] VARCHAR(200)" for c in SENSITIVITY_COLUMNS)
cursor.execute(f"CREATE TABLE dbo.bronze_column_sensitivity_content ({column_defs});")
connection.commit()
if sensitivity_rows:
    placeholders_sql = ", ".join("?" for _ in SENSITIVITY_COLUMNS)
    insert_sql = f"INSERT INTO dbo.bronze_column_sensitivity_content ({', '.join(f'[{c}]' for c in SENSITIVITY_COLUMNS)}) VALUES ({placeholders_sql})"
    cursor.fast_executemany = True
    cursor.executemany(insert_sql, [[str(row.get(c, "")) for c in SENSITIVITY_COLUMNS] for row in sensitivity_rows])
    connection.commit()
print(f"dbo.bronze_column_sensitivity_content: {len(sensitivity_rows)} row(s) written.")

# sample_values_json can hold up to SAMPLE_VALUES_TO_STORE values of up to
# MAX_SAMPLE_VALUE_LENGTH chars each, JSON-encoded -- VARCHAR(4000) is
# comfortably above the worst case (20 * 120 chars plus JSON overhead).
cursor.execute("IF OBJECT_ID('dbo.bronze_column_sensitivity_samples', 'U') IS NOT NULL DROP TABLE dbo.bronze_column_sensitivity_samples;")
sample_column_defs = ", ".join(
    f"[{c}] VARCHAR(4000)" if c == "sample_values_json" else f"[{c}] VARCHAR(200)" for c in SAMPLE_COLUMNS
)
cursor.execute(f"CREATE TABLE dbo.bronze_column_sensitivity_samples ({sample_column_defs});")
connection.commit()
if sample_rows:
    placeholders_sql = ", ".join("?" for _ in SAMPLE_COLUMNS)
    insert_sql = f"INSERT INTO dbo.bronze_column_sensitivity_samples ({', '.join(f'[{c}]' for c in SAMPLE_COLUMNS)}) VALUES ({placeholders_sql})"
    cursor.fast_executemany = True
    cursor.executemany(insert_sql, [[str(row.get(c, "")) for c in SAMPLE_COLUMNS] for row in sample_rows])
    connection.commit()
print(f"dbo.bronze_column_sensitivity_samples: {len(sample_rows)} row(s) written.")

connection.close()
if gap_rows:
    print(json.dumps(gap_rows[:10], indent=2, default=str))

# DIAGNOSTICO 2026-08-17 (temporal, se retira una vez confirmado el
# umbral final): visibilidad de conteos intermedios via OneLake, porque
# el job status de Fabric no expone stdout.
debug_path = (
    f"abfss://{ONELAKE_WORKSPACE_NAME}@onelake.dfs.fabric.microsoft.com/"
    f"{ONELAKE_LAKEHOUSE_NAME}.Lakehouse/Files/_debug_sensitivity_diagnostics.json"
)
notebookutils.fs.put(debug_path, json.dumps({
    "lakehouses_with_endpoint": len(lakehouses_with_endpoint),
    "endpoint_resolution_errors": endpoint_resolution_errors,
    "gap_count": len(gap_rows),
    "gap_reasons_sample": gap_rows[:10],
    "sensitivity_rows_written": len(sensitivity_rows),
    "sample_rows_written": len(sample_rows),
}, default=str), True)
