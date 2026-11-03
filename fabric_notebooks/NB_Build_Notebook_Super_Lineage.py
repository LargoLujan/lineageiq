# NB_Build_Notebook_Super_Lineage
#
# Fuente para un notebook Python de Fabric -- duodécimo y último paso del
# pipeline de descubrimiento nativo (ver docs/105_fabric_native_discovery_
# setup.md). Cada bloque "# %%" es una celda -- pégalas en orden.
#
# Puerto fiel de backend/scripts/52_build_notebook_super_lineage.py -- el
# parser (parse_notebook_code y sus ~40 extractores AST/regex, líneas
# 181-5142 del original) se copia AQUÍ TAL CUAL, sin cambiar una sola
# línea de su lógica: es puro CPU-bound sobre texto de código ya
# descargado, sin E/S propia. Los únicos cambios de E/S:
#   - index/items.csv, index/workspaces.csv, analysis/notebook_definition_
#     download_manifest.csv ya no son ficheros locales -- se leen de
#     dbo.bronze_items / dbo.bronze_workspaces / dbo.bronze_notebook_
#     definitions (esta última la escribe NB_Download_Notebook_Definitions,
#     el paso anterior del pipeline).
#   - analysis/e1_notebook_code_review_queue.csv (cola de revisión manual)
#     no tiene tabla bronze -- degrada a lista vacía, igual que el
#     original cuando el fichero no existe.
#   - El parser original navega una jerarquía real de carpetas en disco
#     (data/notebook_definitions/<workspace>/<item>.Notebook/<part>) para
#     tres cosas: leer el código de cada notebook, resolver directivas
#     "%run <notebook>" buscando notebooks hermanos, y pre-escanear
#     control.EntityConfig. En vez de recrear esa jerarquía en el
#     filesystem efímero del driver Spark, se sustituye la clase `Path`
#     por VPath (celda "Sistema de ficheros virtual" más abajo): un shim
#     mínimo que implementa exactamente los métodos que el parser usa
#     (.exists(), .read_text(), .name, .suffix, .parent, el operador /),
#     respaldado por un diccionario en memoria construido desde
#     bronze_notebook_definitions con la MISMA estructura de rutas
#     virtuales ("<workspace>/<item>.Notebook/<part_path>") que 51/52
#     usaban en disco -- el parser no distingue un VPath de un Path real,
#     así que su código (incluida load_same_workspace_run_includes, la
#     función que resuelve %run) no necesita ni un cambio.
#   - Los 4 CSV intermedios (notebook_super_lineage_objects/flows/gaps/
#     path_aliases.csv) y el doc .md no se escriben -- nada en la web en
#     vivo los sirve (solo notebook-super-lineage.json, confirmado en
#     backend/scripts/lineage_web/onelake_data.py y paths.py). El JSON
#     final se escribe a OneLake vía el mismo patrón atómico ya usado en
#     los notebooks anteriores.
#   - Sin argparse: WorkspaceNameFilter es una celda de parámetros, como
#     en el resto del pipeline. Cuando viene relleno, el comportamiento de
#     "fusionar con lo ya existente" del original se preserva leyendo el
#     notebook-super-lineage.json YA PUBLICADO en OneLake (en vez de los 4
#     CSV) y conservando sus objects/flows/gaps de otros workspaces.

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

import struct
from datetime import datetime, timezone

SP_TENANT_ID = "<tenant-id>"
SP_CLIENT_ID = "<client-id>"
WAREHOUSE_SQL_ENDPOINT = "<tu-warehouse>.datawarehouse.fabric.microsoft.com"
WAREHOUSE_DATABASE_NAME = "<NombreDelWarehouse>"

ONELAKE_WORKSPACE_NAME = "<tu-workspace>"
ONELAKE_LAKEHOUSE_NAME = "<tu-lakehouse-onelake>"
SP_SECRET_ONELAKE_PATH = "Files/_private/sp-client-secret.txt"

OUTPUT_ONELAKE_PATH = "Files/generated/notebook-super-lineage.json"

# %% [markdown]
# ## Parámetros
# Marca esta celda como celda de parámetros en Fabric.

# %%
WorkspaceNameFilter = ""

# %% [markdown]
# ## Autenticación, Warehouse y OneLake (mismo patrón que los notebooks anteriores)

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


WAREHOUSE_CONNECTION = connect_warehouse()


def read_table(table_name):
    cursor = WAREHOUSE_CONNECTION.cursor()
    try:
        cursor.execute(f"SELECT * FROM dbo.{table_name}")
    except pyodbc.Error:
        WAREHOUSE_CONNECTION.rollback()
        return []
    columns = [c[0] for c in cursor.description]
    return [dict(zip(columns, row)) for row in cursor.fetchall()]


def read_onelake_json(onelake_relative_path):
    abfss_path = (
        f"abfss://{ONELAKE_WORKSPACE_NAME}@onelake.dfs.fabric.microsoft.com/"
        f"{ONELAKE_LAKEHOUSE_NAME}.Lakehouse/{onelake_relative_path}"
    )
    # notebookutils.fs.head() silently truncates well below whatever
    # max_bytes you pass it (confirmed live, 2026-08-12) -- it's a preview
    # API, not a full-read one. spark.read.text(..., wholetext=True) reads
    # the whole file as a single row with no such cap.
    try:
        content = spark.read.text(abfss_path, wholetext=True).collect()[0][0]
        return json.loads(content)
    except Exception:
        return None


def write_json_onelake(onelake_relative_path, payload):
    abfss_path = (
        f"abfss://{ONELAKE_WORKSPACE_NAME}@onelake.dfs.fabric.microsoft.com/"
        f"{ONELAKE_LAKEHOUSE_NAME}.Lakehouse/{onelake_relative_path}"
    )
    notebookutils.fs.put(abfss_path, json.dumps(payload, ensure_ascii=False, indent=2), True)


# %% [markdown]
# ## Parser (puerto fiel, sin cambios de lógica, de backend/scripts/52_build_notebook_super_lineage.py)

# %%
#!/usr/bin/env python3
"""Build notebook super-lineage from downloaded Fabric notebook definitions.

The extractor is intentionally conservative. It records direct source/destination
objects and source->destination flows only when code text makes the mapping
visible without executing notebooks.
"""


import argparse
import ast
import csv
import hashlib
import json
import re
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


# Ejemplo ilustrativo: mapa de grupo logico -> tabla de configuracion que
# devuelve un helper get_assignment_config() en los notebooks escaneados.
# Rellena con los nombres de tabla de tu propio entorno.
ASSIGNMENT_CONFIG_TABLES = {
    "regional": "RegionAssignment",
    "definitive": "DefinitiveSectorAssignment",
}
FABRIC_PATH_ALIAS_ROWS: dict[str, dict[str, str]] = {}
# Ejemplo ilustrativo: adapta esta lista a los sistemas de negocio que
# aparecen en los nombres de workspace/item de tu propio tenant, para
# normalizarlos a su forma "bonita".
FABRIC_NAME_WORDS = {
    "ADVENTUREWORKS": "AdventureWorks",
    "BRONZE": "Bronze",
    "CONTOSOHR": "ContosoHR",
    "DATAMART": "Datamart",
    "ECOMMERCE": "eCommerce",
    "FABRIKAMCRM": "FabrikamCRM",
    "FINANCE": "Finance",
    "GESTION": "Gestion",
    "GOLD": "Gold",
    "NORTHWINDERP": "NorthwindERP",
    "OPERATIONS": "Operations",
    "SALES": "Sales",
    "SILVER": "Silver",
    "STAGING": "Staging",
    "SURVEY": "Survey",
}
FABRIC_ACRONYMS = {
    "API",
    "BI",
    "CRM",
    "ERP",
    "FT",
    "HR",
    "ID",
    "IT",
    "LH",
    "QA",
    "SQL",
}


def safe_text(value: object) -> str:
    return "" if value is None else str(value)


def norm(value: str | None) -> str:
    return (value or "").strip().casefold()


def clean_identifier(value: str) -> str:
    value = value.strip().strip("`[]\"'")
    value = re.sub(r"\s+", " ", value)
    value = value.strip(" ,;)")
    return value


def stable_id(*parts: str) -> str:
    raw = "|".join(parts)
    return hashlib.sha1(raw.encode("utf-8", errors="ignore")).hexdigest()[:16]


def split_list(value: str) -> list[str]:
    if not value:
        return []
    return [part.strip() for part in value.split(";") if part.strip()]


def extract_ipynb_text(path: Path) -> tuple[str, str, list[str]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8-sig", errors="ignore"))
    except Exception:
        return path.read_text(encoding="utf-8", errors="ignore"), "", []
    code_parts: list[str] = []
    markdown_parts: list[str] = []
    cell_langs: list[str] = []
    for cell in payload.get("cells", []):
        source = cell.get("source", "")
        if isinstance(source, list):
            text = "".join(source)
        else:
            text = str(source)
        if cell.get("cell_type") == "code":
            code_parts.append(text)
            meta = cell.get("metadata", {}) or {}
            microsoft = meta.get("microsoft", {}) if isinstance(meta, dict) else {}
            if isinstance(microsoft, dict):
                cell_langs.append(str(microsoft.get("language", "")))
        elif cell.get("cell_type") == "markdown":
            markdown_parts.append(text)
    return "\n\n".join(code_parts), "\n\n".join(markdown_parts), cell_langs


def read_notebook_part(path: Path) -> tuple[str, str, list[str]]:
    if path.suffix.lower() == ".ipynb":
        return extract_ipynb_text(path)
    text = path.read_text(encoding="utf-8-sig", errors="ignore")
    return text, "", []


def load_same_workspace_run_includes(code: str, definition_path: Path) -> str:
    parts: list[str] = []
    workspace_dir = definition_path.parent.parent
    if not workspace_dir.exists():
        return ""
    seen: set[Path] = set()

    def visit(source_code: str, depth: int) -> None:
        if depth >= 3:
            return
        for match in re.finditer(r"(?im)^\s*%run\s+([^\s#]+)", source_code):
            notebook_name = match.group(1).strip().strip("\"'")
            if not notebook_name or "/" in notebook_name or "\\" in notebook_name:
                continue
            notebook_dirs = [workspace_dir / f"{notebook_name}.Notebook"]
            fallback_old_dir = workspace_dir / f"{notebook_name}_OLD.Notebook"
            if not notebook_dirs[0].exists() and fallback_old_dir.exists():
                notebook_dirs.append(fallback_old_dir)
            candidates: list[Path] = []
            for notebook_dir in notebook_dirs:
                candidates.extend(
                    [
                        notebook_dir / "notebook-content.py",
                        notebook_dir / "notebook-content.ipynb",
                        notebook_dir / "notebook-content.sql",
                    ]
                )
            for candidate in candidates:
                if candidate.exists() and candidate not in seen:
                    seen.add(candidate)
                    include_code, _include_markdown, _langs = read_notebook_part(candidate)
                    if include_code.strip():
                        parts.append(
                            f"\n# BEGIN STATIC INLINE %run {notebook_name}\n{include_code}\n# END STATIC INLINE %run {notebook_name}\n"
                        )
                        visit(include_code, depth + 1)
                    break

    visit(code, 0)
    return "\n".join(parts)


def uncomment_magic_python(code: str) -> str:
    """Expose Fabric/Databricks Python magic cells while keeping line count stable."""
    output: list[str] = []
    mode = ""
    for line in code.splitlines():
        stripped = line.lstrip()
        indent = line[: len(line) - len(stripped)]
        if stripped.startswith("# MAGIC"):
            content = stripped[len("# MAGIC"):].lstrip()
            marker = content.strip().lower()
            if marker.startswith(("%%pyspark", "%%python", "%python")):
                mode = "python"
                after_marker = re.sub(r"(?is)^\s*%{1,2}(?:pyspark|python)\b", "", content, count=1)
                output.append(indent + (after_marker if after_marker.strip() else "# magic python"))
            elif marker.startswith(("%%sql", "%sql")):
                mode = "sql"
                output.append(indent + "# " + content)
            elif mode == "python":
                output.append(indent + content)
            else:
                output.append(indent + "# " + content)
        else:
            output.append(line)
            if not stripped.startswith("#") and stripped.strip():
                mode = ""
    return "\n".join(output)


def literal_eval_node(node: ast.AST) -> object | None:
    try:
        return ast.literal_eval(node)
    except Exception:
        return None


def offset_for_lineno(code: str, lineno: int) -> int:
    if lineno <= 1:
        return 0
    offset = 0
    for current_lineno, line in enumerate(code.splitlines(keepends=True), start=1):
        if current_lineno >= lineno:
            return offset
        offset += len(line)
    return offset


def template_from_ast(node: ast.AST) -> str | None:
    """Best-effort static template for simple string and f-string assignments."""
    if isinstance(node, ast.Constant) and isinstance(node.value, (str, int, float)):
        return str(node.value)
    if isinstance(node, ast.Name):
        return "{" + node.id + "}"
    if isinstance(node, ast.JoinedStr):
        parts: list[str] = []
        for value in node.values:
            if isinstance(value, ast.Constant):
                parts.append(str(value.value))
            elif isinstance(value, ast.FormattedValue):
                try:
                    parts.append("{" + ast.unparse(value.value) + "}")
                except Exception:
                    return None
            else:
                return None
        return "".join(parts)
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left = template_from_ast(node.left)
        right = template_from_ast(node.right)
        if left is not None and right is not None:
            return left + right
    return None


def clean_code_for_ast(code: str) -> str:
    """Keep line numbers stable while hiding notebook magics from Python AST."""
    cleaned: list[str] = []
    for line in code.splitlines():
        if re.match(r"\s*(%|!)(?!\=)", line):
            cleaned.append("# " + line)
        else:
            cleaned.append(line)
    return "\n".join(cleaned)


def collect_function_parameter_ranges(code: str) -> list[tuple[int, int, set[str]]]:
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return []
    ranges: list[tuple[int, int, set[str]]] = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        params = {arg.arg for arg in node.args.args}
        params.update(arg.arg for arg in node.args.kwonlyargs)
        if node.args.vararg:
            params.add(node.args.vararg.arg)
        if node.args.kwarg:
            params.add(node.args.kwarg.arg)
        start = offset_for_lineno(code, getattr(node, "lineno", 1))
        end_lineno = getattr(node, "end_lineno", None)
        end = offset_for_lineno(code, end_lineno + 1) if end_lineno else len(code)
        ranges.append((start, end, params))
    return ranges


def is_function_parameter_arg(arg: str, ranges: list[tuple[int, int, set[str]]], offset: int) -> bool:
    raw = arg.strip().rstrip(",")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", raw):
        return False
    return any(start <= offset < end and raw in params for start, end, params in ranges)


def collect_parameterized_path_builder_vars(code: str) -> list[tuple[int, int, str]]:
    function_ranges = collect_function_parameter_ranges(code)
    entries: list[tuple[int, int, str]] = []
    for match in re.finditer(r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:build_lh_read_path|build_table_path|build_lakehouse_tables?_path)\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()):
            continue
        var_name, arg_text = match.group(1), match.group(2)
        args = split_top_level_args(arg_text)
        table = keyword_arg(arg_text, "table_name")
        if not table and len(args) >= 3:
            table = args[2]
        if not table or is_empty_literal_arg(table):
            continue
        raw_table = table.strip().rstrip(",")
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", raw_table):
            continue
        for start, end, params in function_ranges:
            if start <= match.start() < end and raw_table in params:
                entries.append((start, end, var_name))
                break
    return entries


def is_parameterized_path_builder_var(arg: str, entries: list[tuple[int, int, str]], offset: int) -> bool:
    raw = arg.strip().rstrip(",")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", raw):
        return False
    return any(start <= offset < end and raw == var_name for start, end, var_name in entries)


def ast_name(node: ast.AST) -> str:
    return node.id if isinstance(node, ast.Name) else ""


def collect_static_dict_temp_view_loops(code: str, constants: dict[str, str]) -> list[dict[str, object]]:
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return []

    table_dicts: dict[str, list[tuple[str, str, int]]] = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.Dict):
            continue
        target_names = [target.id for target in node.targets if isinstance(target, ast.Name)]
        if not target_names:
            continue
        entries: list[tuple[str, str, int]] = []
        for key_node, value_node in zip(node.value.keys, node.value.values):
            view_name = literal_eval_node(key_node) if key_node is not None else None
            if not isinstance(view_name, str):
                continue
            source_identifier = ""
            value = literal_eval_node(value_node)
            if isinstance(value, str):
                base_path = constants.get("base_path", "").rstrip("/")
                source_identifier = f"{base_path}/{value}" if base_path else value
            elif isinstance(value_node, ast.Dict):
                payload: dict[str, str] = {}
                for child_key, child_value in zip(value_node.keys, value_node.values):
                    child_name = literal_eval_node(child_key) if child_key is not None else None
                    child_literal = literal_eval_node(child_value)
                    if isinstance(child_name, str) and isinstance(child_literal, (str, int, float)):
                        payload[child_name] = str(child_literal)
                table = payload.get("table", "")
                workspace = payload.get("workspace") or constants.get("workspace_id", "")
                lakehouse = payload.get("lakehouse") or constants.get("lakehouse_id", "")
                if table and workspace and lakehouse:
                    source_identifier = f"abfss://{workspace}@onelake.dfs.fabric.microsoft.com/{lakehouse}/Tables/{table}"
            if source_identifier:
                entries.append((view_name, source_identifier, offset_for_lineno(code, getattr(key_node, "lineno", getattr(node, "lineno", 1)))))
        if entries:
            for target_name in target_names:
                table_dicts[target_name] = entries

    loops: list[dict[str, object]] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.For):
            continue
        iter_node = node.iter
        if not (
            isinstance(iter_node, ast.Call)
            and isinstance(iter_node.func, ast.Attribute)
            and iter_node.func.attr == "items"
            and isinstance(iter_node.func.value, ast.Name)
        ):
            continue
        dict_name = iter_node.func.value.id
        if dict_name not in table_dicts:
            continue
        if not isinstance(node.target, ast.Tuple) or len(node.target.elts) < 2:
            continue
        view_var = ast_name(node.target.elts[0])
        if not view_var:
            continue
        has_view_create = False
        load_vars: set[str] = set()
        for child in ast.walk(node):
            if (
                isinstance(child, ast.Call)
                and isinstance(child.func, ast.Attribute)
                and child.func.attr == "createOrReplaceTempView"
                and child.args
                and ast_name(child.args[0]) == view_var
            ):
                has_view_create = True
            if (
                isinstance(child, ast.Call)
                and isinstance(child.func, ast.Attribute)
                and child.func.attr == "load"
                and child.args
                and isinstance(child.args[0], ast.Name)
            ):
                load_vars.add(child.args[0].id)
        if not has_view_create or not load_vars:
            continue
        start = offset_for_lineno(code, getattr(node, "lineno", 1))
        end_lineno = getattr(node, "end_lineno", None)
        end = offset_for_lineno(code, end_lineno + 1) if end_lineno else len(code)
        loops.append(
            {
                "start": start,
                "end": end,
                "load_vars": load_vars,
                "entries": table_dicts[dict_name],
            }
        )
    return loops


def collect_static_dict_temp_view_load_vars(code: str, constants: dict[str, str]) -> list[tuple[int, int, str]]:
    entries: list[tuple[int, int, str]] = []
    for loop in collect_static_dict_temp_view_loops(code, constants):
        for var_name in loop["load_vars"]:
            entries.append((int(loop["start"]), int(loop["end"]), str(var_name)))
    return entries


def collect_parameterized_local_assignment_vars(code: str) -> list[tuple[int, int, str]]:
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return []
    entries: list[tuple[int, int, str]] = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        params = set(function_param_names(node))
        if not params:
            continue
        start = offset_for_lineno(code, getattr(node, "lineno", 1))
        end_lineno = getattr(node, "end_lineno", None)
        end = offset_for_lineno(code, end_lineno + 1) if end_lineno else len(code)
        for child in ast.walk(node):
            if not isinstance(child, ast.Assign):
                continue
            template = template_from_ast(child.value)
            if not template or not any("{" + param + "}" in template for param in params):
                continue
            for target in child.targets:
                if isinstance(target, ast.Name):
                    entries.append((start, end, target.id))
    return entries


def collect_loop_var_ranges(code: str, iterable_names: set[str]) -> list[tuple[int, int, str]]:
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return []
    entries: list[tuple[int, int, str]] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.For) or not isinstance(node.iter, ast.Name) or node.iter.id not in iterable_names:
            continue
        targets: list[str] = []
        if isinstance(node.target, ast.Name):
            targets.append(node.target.id)
        elif isinstance(node.target, ast.Tuple):
            targets.extend(ast_name(element) for element in node.target.elts if ast_name(element))
        if not targets:
            continue
        start = offset_for_lineno(code, getattr(node, "lineno", 1))
        end_lineno = getattr(node, "end_lineno", None)
        end = offset_for_lineno(code, end_lineno + 1) if end_lineno else len(code)
        for target in targets:
            entries.append((start, end, target))
    return entries


def literal_string_sequence(node: ast.AST) -> list[str]:
    if not isinstance(node, (ast.List, ast.Tuple, ast.Set)):
        return []
    values: list[str] = []
    for element in node.elts:
        value = literal_eval_node(element)
        if isinstance(value, str):
            values.append(value)
    return values


def assignment_config_tables_for_arg(code: str, arg: str, offset: int) -> list[str]:
    raw = arg.strip().rstrip(",")
    match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)\.output_table_name", raw)
    if not match:
        return []
    cfg_var = match.group(1)
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return []
    tables: list[str] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.For) or not isinstance(node.target, ast.Name):
            continue
        start = offset_for_lineno(code, getattr(node, "lineno", 1))
        end_lineno = getattr(node, "end_lineno", None)
        end = offset_for_lineno(code, end_lineno + 1) if end_lineno else len(code)
        if not (start <= offset < end):
            continue
        groups = [value.casefold() for value in literal_string_sequence(node.iter)]
        if not groups:
            continue
        loop_var = node.target.id
        cfg_vars: set[str] = set()
        for child in ast.walk(node):
            if not isinstance(child, ast.Assign) or not isinstance(child.value, ast.Call):
                continue
            if ast_call_name(child.value.func) != "get_assignment_config":
                continue
            if not child.value.args or ast_name(child.value.args[0]) != loop_var:
                continue
            cfg_vars.update(target.id for target in child.targets if isinstance(target, ast.Name))
        if cfg_var not in cfg_vars:
            continue
        for group in groups:
            table = ASSIGNMENT_CONFIG_TABLES.get(group)
            if table and table not in tables:
                tables.append(table)
    return tables


def collect_assignment_config_path_vars(code: str) -> list[tuple[int, int, str]]:
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return []
    entries: list[tuple[int, int, str]] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.For) or not isinstance(node.target, ast.Name):
            continue
        groups = [value.casefold() for value in literal_string_sequence(node.iter)]
        if not any(group in ASSIGNMENT_CONFIG_TABLES for group in groups):
            continue
        loop_var = node.target.id
        start = offset_for_lineno(code, getattr(node, "lineno", 1))
        end_lineno = getattr(node, "end_lineno", None)
        end = offset_for_lineno(code, end_lineno + 1) if end_lineno else len(code)
        cfg_vars: set[str] = set()
        for child in ast.walk(node):
            if isinstance(child, ast.Assign) and isinstance(child.value, ast.Call):
                if ast_call_name(child.value.func) == "get_assignment_config" and child.value.args and ast_name(child.value.args[0]) == loop_var:
                    cfg_vars.update(target.id for target in child.targets if isinstance(target, ast.Name))
        if not cfg_vars:
            continue
        for child in ast.walk(node):
            if not isinstance(child, ast.Assign) or not isinstance(child.value, ast.Call):
                continue
            if ast_call_name(child.value.func) not in {"build_lh_read_path", "build_table_path", "build_lakehouse_table_path", "build_lakehouse_tables_path"}:
                continue
            has_assignment_table = False
            for keyword in child.value.keywords:
                if keyword.arg != "table_name" or not isinstance(keyword.value, ast.Attribute):
                    continue
                if keyword.value.attr == "output_table_name" and ast_name(keyword.value.value) in cfg_vars:
                    has_assignment_table = True
            if not has_assignment_table:
                continue
            for target in child.targets:
                if isinstance(target, ast.Name):
                    entries.append((start, end, target.id))
    return entries


def collect_call_assignment_vars(code: str, call_names: set[str]) -> list[tuple[int, int, str]]:
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return []
    entries: list[tuple[int, int, str]] = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        start = offset_for_lineno(code, getattr(node, "lineno", 1))
        end_lineno = getattr(node, "end_lineno", None)
        end = offset_for_lineno(code, end_lineno + 1) if end_lineno else len(code)
        for child in ast.walk(node):
            if not isinstance(child, ast.Assign) or not isinstance(child.value, ast.Call):
                continue
            if ast_call_name(child.value.func) not in call_names:
                continue
            for target in child.targets:
                if isinstance(target, ast.Name):
                    entries.append((start, end, target.id))
    return entries


def collect_static_dict_string_keys(code: str, dict_name: str) -> list[tuple[str, int]]:
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return []
    keys: list[tuple[str, int]] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.Dict):
            continue
        if not any(isinstance(target, ast.Name) and target.id == dict_name for target in node.targets):
            continue
        for key_node in node.value.keys:
            key = literal_eval_node(key_node) if key_node is not None else None
            if isinstance(key, str):
                keys.append((key, offset_for_lineno(code, getattr(key_node, "lineno", getattr(node, "lineno", 1)))))
    return keys


def extract_static_endpoint_ingest_writes(code: str, constants: dict[str, str]) -> Iterable[tuple[str, int]]:
    if "ENDPOINTS_CONFIG" not in code or "ingest_entity" not in code:
        return
    lakehouse = constants.get("context.lakehouse") or constants.get("BRONZE_LAKEHOUSE", "")
    schema_info = constants.get("context.schema_info", "dbo")
    schema_hst = constants.get("context.schema_hst", "hst")
    if not lakehouse:
        return
    for entity, offset in collect_static_dict_string_keys(code, "ENDPOINTS_CONFIG"):
        yield f"{lakehouse}.{schema_info}.{entity}", offset
        yield f"{lakehouse}.{schema_hst}.{entity}", offset


def extract_external_api_ingest_flows(code: str, constants: dict[str, str]) -> Iterable[tuple[str, str, str, str, int, str]]:
    """Return source API -> lakehouse target mappings declared by static ingest code.

    This project's original implementation matched a handful of real
    external SaaS vendor API clients from its own tenant (each recognized
    by a distinctive class/constant name in the notebook source, e.g. a
    static ENDPOINTS_CONFIG dict of entity -> {"url": ...} definitions, or a
    hardcoded REST table endpoint) against the dbo/hst Delta targets they
    upsert into. That tenant-specific vendor matching has been removed here
    -- add your own detector following the same shape: look for a
    distinctive marker string in `code`, resolve the lakehouse from
    `constants`, and yield 6-tuples of (source_identifier, target_identifier,
    source_dataframe, target_dataframe, offset, evidence) for each API
    endpoint -> Delta table mapping your own notebooks declare.
    """
    return []


def extract_static_notebook_dataset_flows(code: str, constants: dict[str, str]) -> Iterable[tuple[str, str, str, str, int, str]]:
    if not (
        "SECTOR_TAXONOMY" in code
        and "taxonomy_data" in code
        and "spark.createDataFrame" in code
        and "OUTPUT_TABLE_TAXONOMY" in code
    ):
        return
    schema = constants.get("TAXONOMY_OUT_SCHEMA", "dbo")
    table = constants.get("OUTPUT_TABLE_TAXONOMY", "")
    if not table:
        return
    offset = code.find("SECTOR_TAXONOMY")
    if offset < 0:
        offset = 0
    yield (
        "static://Notebook/SECTOR_TAXONOMY",
        f"{schema}.{table}",
        "SECTOR_TAXONOMY",
        "df_taxonomy",
        offset,
        "Notebook defines SECTOR_TAXONOMY, creates df_taxonomy, and saves it to the declared taxonomy Delta table.",
    )


def extract_static_empty_dataframe_bootstrap_flows(code: str, constants: dict[str, str]) -> Iterable[tuple[str, str, str, str, int, str]]:
    if "createDataFrame" not in code or "saveAsTable" not in code:
        return
    empty_dataframes: dict[str, tuple[str, int]] = {}
    for match in re.finditer(
        r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:spark\.)?createDataFrame\s*\(\s*\[\s*\]\s*,\s*([A-Za-z_][A-Za-z0-9_]*)",
        code,
    ):
        empty_dataframes[match.group(1)] = (match.group(2), match.start())
    if not empty_dataframes:
        return
    seen: set[tuple[str, str]] = set()
    for match in WRITE_VAR_ARG_RE.finditer(code):
        dataframe, operation, target_arg = match.group(1), match.group(2), match.group(3)
        if dataframe not in empty_dataframes or operation != "saveAsTable":
            continue
        schema_name, offset = empty_dataframes[dataframe]
        target_identifier = constants.get(target_arg, "{" + target_arg + "}")
        source_identifier = f"static://Notebook/{schema_name}"
        key = (source_identifier, target_identifier)
        if key in seen:
            continue
        seen.add(key)
        yield (
            source_identifier,
            target_identifier,
            schema_name,
            dataframe,
            offset,
            "Notebook creates an empty DataFrame from an explicit schema and saves it as the declared Delta table.",
        )


def extract_delta_maintenance_log_flows(code: str, constants: dict[str, str]) -> Iterable[tuple[str, str, str, str, int, str]]:
    if not (
        "SHOW TABLES IN" in code
        and "OPTIMIZE" in code
        and "VACUUM" in code
        and "MaintenanceLog" in code
    ):
        return
    lakehouse = constants.get("lakehouse", "")
    schema = constants.get("schema", "")
    if not lakehouse or not schema:
        return
    offset = code.find("SHOW TABLES IN")
    if offset < 0:
        offset = code.find("MaintenanceLog")
    if offset < 0:
        offset = 0
    yield (
        f"{lakehouse}.{schema}.*",
        f"{lakehouse}.control.MaintenanceLog",
        "tables_to_maintain",
        "df_log",
        offset,
        "Notebook enumerates tables in the configured schema, runs OPTIMIZE/VACUUM, and writes operational maintenance results to control.MaintenanceLog.",
    )


STATIC_SQL_IDENTIFIER_RE = r"((?:`[^`]+`|\"[^\"]+\"|[A-Za-z_][A-Za-z0-9_$#-]*)(?:\s*\.\s*(?:`[^`]+`|\"[^\"]+\"|[A-Za-z_][A-Za-z0-9_$#-]*)){0,3})"


def extract_static_sql_seed_flows(code: str, constants: dict[str, str]) -> Iterable[tuple[str, str, str, str, int, str]]:
    if "VALUES" not in code.upper() and "CREATE TABLE" not in code.upper():
        return
    seen: set[tuple[str, str, str]] = set()
    insert_pattern = re.compile(r"(?is)\binsert\s+into\s+" + STATIC_SQL_IDENTIFIER_RE + r"\s*(?:\([^;]*?\))?\s*values\b")
    for match in insert_pattern.finditer(code):
        target_identifier = clean_identifier(match.group(1))
        key = ("static_sql_values_seed", "static://Notebook/sql_VALUES_seed", target_identifier)
        if key in seen:
            continue
        seen.add(key)
        yield (
            "static://Notebook/sql_VALUES_seed",
            target_identifier,
            "sql_VALUES_seed",
            "",
            match.start(),
            "SQL INSERT INTO ... VALUES declares static notebook seed/config rows for the target table.",
        )

    create_pattern = re.compile(r"(?is)\bcreate\s+table\s+if\s+not\s+exists\s+" + STATIC_SQL_IDENTIFIER_RE + r"\s*\(")
    for match in create_pattern.finditer(code):
        target_identifier = clean_identifier(match.group(1))
        key = ("static_sql_ddl_schema", "static://Notebook/sql_DDL_schema", target_identifier)
        if key in seen:
            continue
        seen.add(key)
        yield (
            "static://Notebook/sql_DDL_schema",
            target_identifier,
            "sql_DDL_schema",
            "",
            match.start(),
            "SQL CREATE TABLE IF NOT EXISTS declares a static notebook schema/bootstrap target.",
        )


def extract_control_status_check_reads(code: str, constants: dict[str, str]) -> Iterable[tuple[str, int]]:
    if "check_last_execution_status" not in code:
        return
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return
    seen: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or ast_call_name(node.func) != "check_last_execution_status":
            continue
        workspace_arg = keyword_node(node, "source_workspace_name")
        lakehouse_arg = keyword_node(node, "source_lakehouse_name")
        table_arg = keyword_node(node, "database_table")
        if not workspace_arg or not lakehouse_arg:
            continue
        workspace = template_from_arg_node(workspace_arg)
        lakehouse = template_from_arg_node(lakehouse_arg)
        database_table = template_from_arg_node(table_arg) if table_arg else "control.TableStatus"
        workspace_value, workspace_unresolved = resolve_template(workspace, constants)
        lakehouse_value, lakehouse_unresolved = resolve_template(lakehouse, constants)
        table_value, table_unresolved = resolve_template(database_table, constants)
        if workspace_unresolved or lakehouse_unresolved or table_unresolved:
            continue
        identifier = f"`{workspace_value}`.{lakehouse_value}.{table_value}"
        if identifier in seen:
            continue
        seen.add(identifier)
        yield identifier, offset_for_lineno(code, getattr(node, "lineno", 1))


def bool_constant(constants: dict[str, str], name: str) -> bool:
    return str(constants.get(name, "")).strip().casefold() in {"true", "1", "yes"}


def central_registry_table_from_node(node: ast.AST, constants: dict[str, str]) -> str:
    value = literal_eval_node(node)
    if isinstance(value, str):
        return value
    if isinstance(node, ast.Call):
        function_name = ast_call_name(node.func)
        if function_name == "managed_registry_table_name":
            return "_shortcut_registry_test" if bool_constant(constants, "TEST_MODE") else "_shortcut_registry"
        if function_name == "table_status_table_name":
            return "central_lakehouse_table_status_test" if bool_constant(constants, "TEST_MODE") else "central_lakehouse_table_status"
    if isinstance(node, ast.IfExp):
        branch = node.body if bool_constant(constants, ast.unparse(node.test) if hasattr(ast, "unparse") else "") else node.orelse
        return central_registry_table_from_node(branch, constants)
    return ""


def extract_central_registry_audit_objects(code: str, constants: dict[str, str]) -> Iterable[tuple[str, str, int]]:
    if "write_audit_table" not in code or "AUDIT_LAKEHOUSE_NAME" not in code:
        return
    lakehouse = constants.get("AUDIT_LAKEHOUSE_NAME", "LH_Audit")
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return
    seen: set[tuple[str, str]] = set()
    for table in [
        "_shortcut_registry_test" if bool_constant(constants, "TEST_MODE") else "_shortcut_registry",
        "registry_shortcut_attempts",
    ]:
        identifier = f"{lakehouse}.dbo.{table}"
        key = ("read", identifier)
        if key not in seen:
            seen.add(key)
            yield "read", identifier, 0
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or ast_call_name(node.func) != "write_audit_table" or len(node.args) < 2:
            continue
        table = central_registry_table_from_node(node.args[1], constants)
        if not table:
            continue
        identifier = f"{lakehouse}.dbo.{table}"
        key = ("write", identifier)
        if key in seen:
            continue
        seen.add(key)
        yield "write", identifier, offset_for_lineno(code, getattr(node, "lineno", 1))


def extract_static_dict_temp_view_flows(code: str, constants: dict[str, str]) -> Iterable[tuple[str, str, int]]:
    seen: set[tuple[str, str]] = set()
    for loop in collect_static_dict_temp_view_loops(code, constants):
        for view_name, source_identifier, entry_offset in loop["entries"]:
            key = (source_identifier, view_name)
            if key in seen:
                continue
            seen.add(key)
            yield source_identifier, view_name, int(entry_offset)


def collect_nested_dict_constants(prefix: str, node: ast.AST, constants: dict[str, str]) -> None:
    if not isinstance(node, ast.Dict):
        return
    for key_node, value_node in zip(node.keys, node.values):
        if key_node is None:
            continue
        key = literal_eval_node(key_node)
        if not isinstance(key, str):
            continue
        child_prefix = f"{prefix}.{key}"
        value = literal_eval_node(value_node)
        if isinstance(value, (str, int, float)):
            constants[child_prefix] = str(value)
            continue
        template_value = template_from_ast(value_node)
        if template_value is not None:
            constants[child_prefix] = template_value
            continue
        if isinstance(value_node, ast.Dict):
            collect_nested_dict_constants(child_prefix, value_node, constants)


def collect_constants(code: str) -> dict[str, str]:
    """Walk the notebook's AST for simple top-level assignments (`NAME =
    "literal"`, a list/tuple of literals, an f-string template, or a dict
    literal) and record each as a resolvable constant. This is the first
    and most important resolution pass in parse_notebook_code(): almost
    every other extractor calls resolve_template() against this dict to
    turn a variable reference in code into the real table/path name it
    actually holds."""
    constants: dict[str, str] = {}
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        tree = None
    if tree:
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign):
                value = literal_eval_node(node.value)
                if isinstance(value, (str, int, float)):
                    for target in node.targets:
                        if isinstance(target, ast.Name):
                            constants[target.id] = str(value)
                elif isinstance(value, (list, tuple)) and all(isinstance(x, (str, int, float)) for x in value):
                    for target in node.targets:
                        if isinstance(target, ast.Name):
                            constants[target.id] = ";".join(str(x) for x in value)
                else:
                    template_value = template_from_ast(node.value)
                    if template_value is not None:
                        for target in node.targets:
                            if isinstance(target, ast.Name):
                                constants[target.id] = template_value
                if isinstance(node.value, ast.Dict):
                    for target in node.targets:
                        if isinstance(target, ast.Name):
                            collect_nested_dict_constants(target.id, node.value, constants)
            elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
                value = literal_eval_node(node.value) if node.value is not None else None
                if isinstance(value, (str, int, float)):
                    constants[node.target.id] = str(value)
                elif node.value is not None:
                    template_value = template_from_ast(node.value)
                    if template_value is not None:
                        constants[node.target.id] = template_value

    # Regex fallbacks catch simple constants in notebooks with magic syntax.
    for match in re.finditer(r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:[rRuUfFbB]{0,2})?['\"]([^'\"]+)['\"]", code):
        constants.setdefault(match.group(1), match.group(2))
    for match in re.finditer(r'(?ms)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:[rRuUfFbB]{0,2})?("""|\'\'\')(.*?)(?:\2)', code):
        constants.setdefault(match.group(1), match.group(3))
    for match in re.finditer(r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\[([^\]]+)\]", code):
        values = re.findall(r"['\"]([^'\"]+)['\"]", match.group(2))
        if values:
            constants.setdefault(match.group(1), ";".join(values))
    for match in re.finditer(r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:ProcessContext|IngestionContext)\s*\((.*?)\)", code):
        var_name, arg_text = match.group(1), match.group(2)
        for key in [
            "lakehouse",
            "lakehouse_bronze",
            "lakehouse_silver",
            "lakehouse_gold",
            "schema_info",
            "schema_hst",
            "schema_control",
            "table_control",
        ]:
            value = keyword_arg(arg_text, key)
            if not value:
                continue
            resolved, unresolved = resolve_arg_value(value, constants)
            if resolved and not unresolved:
                constants[f"{var_name}.{key}"] = resolved
    if "get_assignment_config" in code and constants.get("ASSIGNMENT_GROUP"):
        assignment_group = constants["ASSIGNMENT_GROUP"].strip().casefold()
        output_table = ASSIGNMENT_CONFIG_TABLES.get(assignment_group)
        if output_table:
            constants.setdefault("OUTPUT_TABLE_ASSIGNMENT", output_table)
            constants.setdefault("ASSIGNMENT_TABLE", output_table)
    for _ in range(4):
        changed = False
        for key, value in collect_static_constructor_assignments(code, constants).items():
            if key not in constants or constants[key] != value:
                constants[key] = value
                changed = True
        if not changed:
            break
    return constants


def resolve_template(value: str, constants: dict[str, str]) -> tuple[str, str]:
    unresolved: set[str] = set()
    resolved = value

    def replace(match: re.Match[str]) -> str:
        expr = match.group(1).strip()
        if expr in constants:
            return constants[expr]
        key = expr.split(".")[0].split("[")[0].strip()
        if key in constants:
            return constants[key]
        unresolved.add(expr)
        return "{" + expr + "}"

    for _ in range(6):
        unresolved.clear()
        new_value = re.sub(r"\{([^{}]+)\}", replace, resolved)
        if new_value == resolved:
            resolved = new_value
            break
        resolved = new_value
    return resolved, ",".join(sorted(unresolved))


def is_noise_identifier(value: str) -> bool:
    if not value:
        return True
    clean = clean_identifier(value)
    if not clean:
        return True
    if len(clean) == 1:
        return True
    if re.match(r"(?i)^(select|from|join|where|and|or|on|as|with|case|when|then|else|end|if|set|matched|not|exists|true|false|null|none)$", clean):
        return True
    if re.match(r"(?i)^(delta|parquet|csv|json|overwrite|append|ignore|errorifexists)$", clean):
        return True
    if re.search(r"[{}]", clean):
        return False
    return False


def strip_delta_prefix(value: str) -> str:
    clean = value.strip()
    if clean.lower().startswith("delta.`") and clean.endswith("`"):
        return clean[7:-1]
    if clean.lower().startswith("delta."):
        return clean[6:].strip("`")
    return clean


def pretty_fabric_token_part(value: str) -> str:
    upper = value.upper()
    if not upper:
        return ""
    if upper in FABRIC_NAME_WORDS:
        return FABRIC_NAME_WORDS[upper]
    if upper in FABRIC_ACRONYMS:
        return upper
    return value.title() if value.isupper() else value


def fabric_path_token_to_name(token: str) -> str:
    clean = token.strip("{}")
    clean = re.sub(r"_+", "_", clean).strip("_")
    if not clean:
        return "Unresolved_Lakehouse"
    upper = clean.upper()
    for suffix in (
        "_TABLES_PATH",
        "_TABLE_PATH",
        "_FILES_PATH",
        "_FILE_PATH",
        "_ABFSS_PATH",
        "_ONELAKE_PATH",
        "_PATH",
    ):
        if upper.endswith(suffix):
            clean = clean[: -len(suffix)]
            upper = clean.upper()
            break
    parts = [part for part in clean.split("_") if part]
    if parts and parts[0].upper() == "LH":
        body = "_".join(pretty_fabric_token_part(part) for part in parts[1:])
        return f"LH_{body}" if body else "LH_Unresolved"
    rendered = "_".join(pretty_fabric_token_part(part) for part in parts)
    return rendered or "Unresolved_Lakehouse"


def register_fabric_path_alias(
    raw_identifier: str,
    alias_token: str,
    source_type: str,
    source_database: str,
    schema_name: str,
    object_name: str,
    normalized_identifier: str,
    translation_rule: str,
) -> None:
    row = FABRIC_PATH_ALIAS_ROWS.get(raw_identifier)
    if row is None:
        FABRIC_PATH_ALIAS_ROWS[raw_identifier] = {
            "raw_identifier": raw_identifier,
            "normalized_identifier": normalized_identifier,
            "source_type": source_type,
            "source_database": source_database,
            "schema_name": schema_name,
            "object_name": object_name,
            "alias_token": alias_token,
            "translation_rule": translation_rule,
            "usage_count": "1",
        }
        return
    row["usage_count"] = str(int(row.get("usage_count", "0") or "0") + 1)


def fabric_placeholder_path_parts(identifier: str) -> dict[str, str] | None:
    match = re.match(r"^\{(?P<token>[A-Za-z0-9_]+)\}/(?P<path>.+)$", identifier)
    if not match:
        return None
    alias_token = match.group("token")
    source_database = fabric_path_token_to_name(alias_token)
    path_parts = [clean_identifier(part) for part in match.group("path").strip("/").split("/") if clean_identifier(part)]
    if not path_parts:
        return None
    if path_parts[0].casefold() == "files":
        object_name = "/".join(path_parts[1:]) if len(path_parts) > 1 else "Files"
        display = f"{source_database}/Files/{object_name}" if object_name != "Files" else f"{source_database}/Files"
        register_fabric_path_alias(
            identifier,
            alias_token,
            "File",
            source_database,
            "",
            object_name,
            display,
            "placeholder_file_path_to_lakehouse_file",
        )
        return {
            "source_type": "File",
            "source_database": source_database,
            "schema_name": "",
            "object_name": object_name,
            "object_display_name": display,
        }
    if path_parts[0].casefold() == "tables":
        path_parts = path_parts[1:]
    if len(path_parts) >= 2:
        schema_name = path_parts[-2]
        object_name = path_parts[-1]
    else:
        schema_name = ""
        object_name = path_parts[-1]
    display = ".".join([part for part in [source_database, schema_name, object_name] if part])
    register_fabric_path_alias(
        identifier,
        alias_token,
        "LakehouseTable",
        source_database,
        schema_name,
        object_name,
        display,
        "placeholder_path_to_lakehouse_schema_object",
    )
    return {
        "source_type": "LakehouseTable",
        "source_database": source_database,
        "schema_name": schema_name,
        "object_name": object_name,
        "object_display_name": display,
    }


def normalize_placeholder_display(value: str) -> str:
    if not re.match(r"^\{[A-Za-z0-9_]+\}/", value or ""):
        return value
    parts = object_parts(value)
    return parts["object_display_name"]


def object_parts(identifier: str, source_type_hint: str = "") -> dict[str, str]:
    """Split one resolved object identifier into the source_type/
    source_database/schema_name/object_name/object_display_name fields every
    ObjectRow/FlowRow needs, handling every identifier shape this codebase
    can produce: Fabric OneLake placeholder paths, api://, static://,
    Lakehouse.schema.table, and plain database.schema.table strings. This is
    the one place that decides "what kind of thing is this identifier",
    so every extractor funnels through it via add_object()."""
    clean = clean_identifier(identifier)
    clean = strip_delta_prefix(clean)
    placeholder_parts = fabric_placeholder_path_parts(clean)
    if placeholder_parts:
        return placeholder_parts
    if clean.lower().startswith("api://"):
        api_path = clean[6:].strip("/")
        api_parts = api_path.split("/", 1)
        source_database = api_parts[0] if api_parts else ""
        object_name = api_parts[1] if len(api_parts) > 1 else source_database
        return {
            "source_type": "ExternalAPI",
            "source_database": source_database,
            "schema_name": "",
            "object_name": object_name,
            "object_display_name": f"{source_database}/{object_name}" if object_name != source_database else source_database,
        }
    if clean.lower().startswith("static://"):
        static_path = clean[9:].strip("/")
        static_parts = static_path.split("/", 1)
        source_database = static_parts[0] if static_parts else ""
        object_name = static_parts[1] if len(static_parts) > 1 else source_database
        return {
            "source_type": "NotebookStaticData",
            "source_database": source_database,
            "schema_name": "",
            "object_name": object_name,
            "object_display_name": f"{source_database}/{object_name}" if object_name != source_database else source_database,
        }
    if re.match(r"(?i)^(abfss|https?|wasbs|s3)://", clean):
        table_path = re.search(r"(?i)(.*?/Tables)/([^/`]+)/([^/`]+)$", clean)
        if table_path:
            source_database = table_path.group(1)
            schema_name = table_path.group(2)
            object_name = table_path.group(3)
            return {
                "source_type": "LakehouseTable",
                "source_database": source_database,
                "schema_name": schema_name,
                "object_name": object_name,
                "object_display_name": f"{source_database}/{schema_name}/{object_name}",
            }
        table_path = re.search(r"(?i)(.*?/Tables)/([^/`]+)$", clean)
        if table_path:
            source_database = table_path.group(1)
            object_name = table_path.group(2)
            return {
                "source_type": "LakehouseTable",
                "source_database": source_database,
                "schema_name": "",
                "object_name": object_name,
                "object_display_name": f"{source_database}/{object_name}",
            }
        return {
            "source_type": "File",
            "source_database": "",
            "schema_name": "",
            "object_name": clean,
            "object_display_name": clean,
        }
    if clean.startswith("Files/") or re.search(r"(?i)\.(csv|parquet|json|xlsx?|txt)$", clean):
        return {
            "source_type": "File",
            "source_database": "",
            "schema_name": "",
            "object_name": clean,
            "object_display_name": clean,
        }
    named_table_path = re.search(r"(?i)^(.+?)/Tables/([^/`]+)/([^/`]+)$", clean)
    if named_table_path:
        source_database = named_table_path.group(1)
        schema_name = named_table_path.group(2)
        object_name = named_table_path.group(3)
        return {
            "source_type": "LakehouseTable",
            "source_database": source_database,
            "schema_name": schema_name,
            "object_name": object_name,
            "object_display_name": f"{source_database}.{schema_name}.{object_name}",
        }
    if "/" in clean and not clean.startswith("Files/"):
        path_parts = [part for part in clean.strip("/").split("/") if part]
        if len(path_parts) == 2 and not re.search(r"[{}]", clean):
            schema_name, object_name = path_parts
            return {
                "source_type": source_type_hint or "FabricOrSQL",
                "source_database": "",
                "schema_name": schema_name,
                "object_name": object_name,
                "object_display_name": f"{schema_name}.{object_name}",
            }
    clean = clean.replace("`", "").replace("[", "").replace("]", "").replace('"', "")
    parts = [p for p in re.split(r"\s*\.\s*", clean) if p]
    source_database = ""
    schema_name = ""
    object_name = clean
    if len(parts) == 2:
        schema_name, object_name = parts
    elif len(parts) >= 3:
        source_database = ".".join(parts[:-2])
        schema_name = parts[-2]
        object_name = parts[-1]
    display = ".".join([p for p in [source_database, schema_name, object_name] if p])
    return {
        "source_type": source_type_hint or "FabricOrSQL",
        "source_database": source_database,
        "schema_name": schema_name,
        "object_name": object_name,
        "object_display_name": display,
    }


SQL_OBJECT_RE = re.compile(
    r"(?is)\b(from|join|using|into|merge\s+into|delete\s+from|insert\s+into|create\s+table\s+if\s+not\s+exists|create(?:\s+or\s+replace)?\s+table|create(?:\s+or\s+replace)?\s+(?:temporary\s+|temp\s+)?view|update(?!\s+set\b)|exec(?:ute)?|call)\s+"
    r"((?:\[[^\]]+\]|`[^`]+`|\"[^\"]+\"|[A-Za-z_][A-Za-z0-9_$#-]*)(?:\s*\.\s*(?:\[[^\]]+\]|`[^`]+`|\"[^\"]+\"|[A-Za-z_][A-Za-z0-9_$#-]*)){0,3})"
)


def extract_sql_objects(sql: str) -> list[tuple[str, str, str]]:
    """Regex-scan one SQL statement's text for FROM/JOIN/USING (read),
    INSERT/UPDATE/MERGE/etc. (write), and EXEC/CALL (execute) object
    references, returning (usage, raw_identifier, matched_verb) tuples.
    Filters out CTE names (identifiers defined by the query's own WITH
    clause, not real external objects) so they don't get misreported as
    read dependencies."""
    rows: list[tuple[str, str, str]] = []
    cte_names = {
        norm(match.group(1))
        for match in re.finditer(r"(?is)(?:\bwith|,)\s+([A-Za-z_][A-Za-z0-9_$#-]*)\s+as\s*\(", sql)
    }
    cte_names.update(
        norm(match.group(2))
        for match in re.finditer(r"(?is)['\"]\s*(select\b.*?\bfrom\s+([A-Za-z_][A-Za-z0-9_$#-]*)\b.*?)['\"]\s+if\b", sql)
        if match.group(2)
    )
    for match in re.finditer(r"(?is)\bshow\s+tables\s+in\s+([A-Za-z_][A-Za-z0-9_$#-]*)", sql):
        rows.append(("read", f"{match.group(1)}.*", "show tables in"))
    for match in SQL_OBJECT_RE.finditer(sql):
        verb = re.sub(r"\s+", " ", match.group(1).strip().lower())
        identifier = clean_identifier(match.group(2))
        if is_noise_identifier(identifier):
            continue
        if verb in {"from", "join", "using"}:
            usage = "read"
        elif "exec" in verb or verb == "call":
            usage = "execute"
        else:
            usage = "write"
        if usage == "read" and "." not in identifier and norm(identifier) in cte_names:
            continue
        rows.append((usage, identifier, verb))
    return rows


def split_sql_lineage_chunks(sql: str) -> list[tuple[int, str]]:
    starts = [m.start() for m in re.finditer(
        r"(?im)^\s*(?:create(?:\s+or\s+replace)?\s+table|create\s+table\s+if\s+not\s+exists|create(?:\s+or\s+replace)?\s+(?:temporary\s+|temp\s+)?view|insert\s+into|merge\s+into|update|delete\s+from)\b",
        sql,
    )]
    if not starts:
        return [(0, sql)]
    chunks: list[tuple[int, str]] = []
    for index, start in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(sql)
        chunks.append((start, sql[start:end]))
    return chunks


def extract_magic_sql_blocks(code: str) -> Iterable[tuple[str, int, str]]:
    """Extract Fabric SQL magic cells from exported .py notebook definitions."""
    lines = code.splitlines(keepends=True)
    current: list[str] = []
    in_sql = False
    start_offset = 0
    offset = 0

    def flush() -> tuple[str, int, str] | None:
        if not in_sql or not "".join(current).strip():
            return None
        return "".join(current), start_offset, "fabric_sql_magic"

    for line in lines:
        stripped = line.lstrip()
        if stripped.startswith("# MAGIC"):
            content = stripped[len("# MAGIC"):].lstrip()
            marker = content.strip().lower()
            if marker.startswith("%%sql") or marker.startswith("%sql"):
                pending = flush()
                if pending:
                    yield pending
                current = []
                in_sql = True
                start_offset = offset
                after_marker = re.sub(r"(?is)^\s*%{1,2}sql\b", "", content, count=1)
                if after_marker.strip():
                    current.append(after_marker)
            elif in_sql:
                current.append(content)
        else:
            pending = flush()
            if pending:
                yield pending
            current = []
            in_sql = False
        offset += len(line)

    pending = flush()
    if pending:
        yield pending

    for match in re.finditer(r"(?ims)^\s*%%sql[^\n]*\n(.*?)(?=^\s*(?:%%|# CELL|# METADATA|\Z))", code):
        sql = match.group(1)
        if sql.strip():
            yield sql, match.start(1), "direct_sql_magic"


def sql_literal(value: str) -> str:
    raw = value.strip()
    if re.match(r"(?i)^null$", raw):
        return ""
    if raw[:1].lower() == "n" and raw[1:2] in {"'", '"'}:
        raw = raw[1:]
    if len(raw) >= 2 and raw[0] == raw[-1] and raw[0] in {"'", '"'}:
        return raw[1:-1].replace("''", "'")
    return raw


def extract_insert_value_tuples(sql: str, table_pattern: str) -> Iterable[tuple[int, list[str]]]:
    insert_re = re.compile(
        rf"(?is)\binsert\s+into\s+((?:\[[^\]]+\]|`[^`]+`|\"[^\"]+\"|[A-Za-z_][A-Za-z0-9_$#-]*)(?:\s*\.\s*(?:\[[^\]]+\]|`[^`]+`|\"[^\"]+\"|[A-Za-z_][A-Za-z0-9_$#-]*))?)\s+values\b"
    )
    for match in insert_re.finditer(sql):
        table = clean_identifier(match.group(1)).replace("`", "").replace("[", "").replace("]", "").replace('"', "")
        if not re.search(table_pattern, table, re.I):
            continue
        start = match.end()
        end_match = re.search(r";", sql[start:])
        end = start + end_match.start() if end_match else len(sql)
        values_text = sql[start:end]
        tuple_start = -1
        depth = 0
        quote = ""
        i = 0
        while i < len(values_text):
            ch = values_text[i]
            if quote:
                if ch == quote:
                    if i + 1 < len(values_text) and values_text[i + 1] == quote:
                        i += 1
                    else:
                        quote = ""
            else:
                if ch in {"'", '"'}:
                    quote = ch
                elif ch == "(":
                    if depth == 0:
                        tuple_start = i + 1
                    depth += 1
                elif ch == ")":
                    depth -= 1
                    if depth == 0 and tuple_start >= 0:
                        tuple_text = values_text[tuple_start:i]
                        yield start + tuple_start - 1, [sql_literal(part) for part in split_top_level_args(tuple_text)]
                        tuple_start = -1
            i += 1


def extract_control_config_mappings(sql: str, entity_lookup: dict[str, dict[str, str]] | None = None) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    entity_rows: list[dict[str, str]] = []
    field_rows: list[dict[str, str]] = []
    entity_map: dict[str, dict[str, str]] = dict(entity_lookup or {})

    for row_offset, values in extract_insert_value_tuples(sql, r"(?:^|\.)EntityConfig$"):
        if len(values) < 5:
            continue
        entity, schema, table, src_lh, dst_lh = values[:5]
        if not (entity and schema and table and src_lh and dst_lh):
            continue
        row = {
            "offset": str(row_offset),
            "entity": entity,
            "source_object": f"{src_lh}.{schema}.{table}",
            "target_object": f"{dst_lh}.{schema}.{table}",
            "source_lakehouse": src_lh,
            "target_lakehouse": dst_lh,
        }
        entity_rows.append(row)
        entity_map[entity.casefold()] = row

    for row_offset, values in extract_insert_value_tuples(sql, r"(?:^|\.)EntityFieldConfig$"):
        if len(values) < 5:
            continue
        entity, src_schema, src_table, dst_schema, dst_table = values[:5]
        if not (src_schema and src_table and dst_schema and dst_table):
            continue
        parent = entity_map.get(entity.casefold(), {})
        src_lh = parent.get("source_lakehouse", "")
        dst_lh = parent.get("target_lakehouse", "")
        source_object = ".".join([p for p in [src_lh, src_schema, src_table] if p])
        target_object = ".".join([p for p in [dst_lh, dst_schema, dst_table] if p])
        field_rows.append(
            {
                "offset": str(row_offset),
                "entity": entity,
                "source_object": source_object,
                "target_object": target_object,
                "source_lakehouse": src_lh,
                "target_lakehouse": dst_lh,
            }
        )

    return entity_rows, field_rows


def build_entity_config_lookup(sql_blocks: Iterable[str]) -> dict[str, dict[str, str]]:
    lookup: dict[str, dict[str, str]] = {}
    for sql in sql_blocks:
        entity_rows, _ = extract_control_config_mappings(sql)
        for row in entity_rows:
            lookup[row["entity"].casefold()] = row
    return lookup


def extract_string_arg_patterns(code: str) -> Iterable[tuple[str, str, str, int]]:
    patterns = [
        ("read", "spark_read_table", r"(?is)\b(?:spark\.read(?:\s*\\?\s*\.[A-Za-z_][A-Za-z0-9_]*\([^)]*\))*\s*\\?\s*\.table|spark\.read\s*\\?\s*\.table|spark\.table|read\.table)\s*\(\s*(?:f)?[\"']([^\"']+)[\"']"),
        ("write", "save_as_table", r"(?is)\b(?:saveAsTable|writeTo)\s*\(\s*(?:f)?[\"']([^\"']+)[\"']"),
        ("write", "insert_into", r"(?is)\binsertInto\s*\(\s*(?:f)?[\"']([^\"']+)[\"']"),
        ("read", "delta_for_name", r"(?is)\bDeltaTable\.forName\s*\(\s*[^,]+,\s*(?:f)?[\"']([^\"']+)[\"']"),
        ("read", "spark_read_load", r"(?is)\bspark\.read(?:\s*\\?\s*\.[A-Za-z_][A-Za-z0-9_]*\([^)]*\))*\s*\\?\s*\.load\s*\(\s*(?:f)?[\"']([^\"']+)[\"']"),
        ("write", "write_save_path", r"(?is)\bwrite(?:\.[A-Za-z_][A-Za-z0-9_]*\([^)]*\))*\.save\s*\(\s*(?:f)?[\"']([^\"']+)[\"']"),
        ("read", "option_dbtable", r"(?is)\boption\s*\(\s*[\"'](?:dbtable|table|tableName|schemaTable)[\"']\s*,\s*(?:f)?[\"']([^\"']+)[\"']"),
        ("read", "watermark_source_table", r"(?is)\bsource_table\s*=\s*(?:f)?[\"']([^\"']+)[\"']"),
        ("read", "catalog_table_exists", r"(?is)\bspark\.catalog\.tableExists\s*\(\s*(?:f)?[\"']([^\"']+)[\"']"),
    ]
    for usage, operation, pattern in patterns:
        for match in re.finditer(pattern, code):
            if is_ignored_context(code, match.start()):
                continue
            yield usage, operation, match.group(1), match.start()


def is_ignored_context(code: str, offset: int) -> bool:
    line_start = code.rfind("\n", 0, offset) + 1
    prefix = code[line_start:offset]
    stripped = prefix.lstrip()
    if stripped.startswith("#"):
        return True
    if "print(" in prefix and (prefix.count('"') % 2 == 1 or prefix.count("'") % 2 == 1):
        return True
    return False


def is_function_definition_context(code: str, offset: int) -> bool:
    line_start = code.rfind("\n", 0, offset) + 1
    prefix = code[line_start:offset]
    return bool(re.search(r"\bdef\s+$", prefix))


def is_empty_literal_arg(arg: str) -> bool:
    raw = arg.strip().rstrip(",")
    if raw in {'""', "''"}:
        return True
    if raw[:2].lower() in {"f'", 'f"', "r'", 'r"'} or raw[0:1] in {"'", '"'}:
        try:
            return ast.literal_eval(raw.lstrip("fFrRuUbB")) == ""
        except Exception:
            return False
    return False


def resolve_arg_value(arg: str, constants: dict[str, str]) -> tuple[str, str]:
    raw = arg.strip().rstrip(",")
    if not raw:
        return "", ""
    if raw[0:1] in {"'", '"'} or raw[:2].lower() in {"f'", 'f"', "r'", 'r"'}:
        try:
            return ast.literal_eval(raw.lstrip("fFrRuUbB")), ""
        except Exception:
            return raw.strip("fFrRuUbB").strip("\"'"), ""
    if raw in constants:
        return resolve_template(constants[raw], constants)
    return "{" + raw + "}", raw


def extract_variable_arg_patterns(
    code: str,
    constants: dict[str, str],
    skip_var_ranges: list[tuple[int, int, str]] | None = None,
    context_offset: int = 0,
) -> Iterable[tuple[str, str, str, int, str]]:
    parameterized_path_vars = collect_parameterized_path_builder_vars(code)
    static_dict_load_vars = collect_static_dict_temp_view_load_vars(code, constants)
    external_skip_vars = skip_var_ranges or []
    patterns = [
        ("read", "spark_read_load_variable", r"(?is)\bspark\.read(?:\s*\\?\s*\.[A-Za-z_][A-Za-z0-9_]*\([^)]*\))*\s*\\?\s*\.load\s*\(\s*([A-Za-z_][A-Za-z0-9_\.]*)"),
        ("read", "spark_read_table_variable", r"(?is)\b(?:spark\.read(?:\s*\\?\s*\.[A-Za-z_][A-Za-z0-9_]*\([^)]*\))*\s*\\?\s*\.table|spark\.table|read\.table)\s*\(\s*([A-Za-z_][A-Za-z0-9_\.]*)"),
        ("read", "catalog_table_exists_variable", r"(?is)\bspark\.catalog\.tableExists\s*\(\s*([A-Za-z_][A-Za-z0-9_\.]*)"),
    ]
    for usage, operation, pattern in patterns:
        for match in re.finditer(pattern, code):
            if is_ignored_context(code, match.start()):
                continue
            if code[match.end():].lstrip().startswith("("):
                continue
            arg = match.group(1)
            remainder = code[match.end(1):].lstrip()
            if arg.lower() in {"f", "r", "u", "b", "fr", "rf"} and remainder.startswith(("'", '"')):
                continue
            effective_offset = context_offset + match.start()
            if is_parameterized_path_builder_var(arg, parameterized_path_vars, effective_offset):
                continue
            if is_parameterized_path_builder_var(arg, static_dict_load_vars, effective_offset):
                continue
            if is_parameterized_path_builder_var(arg, external_skip_vars, effective_offset):
                continue
            value, unresolved = resolve_arg_value(arg, constants)
            yield usage, operation, value, match.start(), unresolved


def extract_sql_strings(code: str) -> Iterable[tuple[str, int, str]]:
    patterns = [
        r"(?is)\bspark\.sql\s*\(\s*(?:f)?(\"\"\".*?\"\"\"|'''.*?'''|\"(?:\\.|[^\"])+\"|'(?:\\.|[^'])+')",
        r"(?is)\b(?:query|sql|sql_text|sql_query|statement)\s*=\s*(?:f)?(\"\"\".*?\"\"\"|'''.*?'''|\"(?:\\.|[^\"])+\"|'(?:\\.|[^'])+')",
        r"(?is)\boption\s*\(\s*[\"'](?:query|sqlQuery)[\"']\s*,\s*(?:f)?(\"\"\".*?\"\"\"|'''.*?'''|\"(?:\\.|[^\"])+\"|'(?:\\.|[^'])+')",
    ]
    for pattern in patterns:
        for match in re.finditer(pattern, code):
            if is_ignored_context(code, match.start()):
                continue
            raw = match.group(1)
            try:
                sql = ast.literal_eval(raw)
            except Exception:
                sql = raw.strip("\"'")
            if re.search(r"(?i)\b(select|from|join|insert|merge|update|delete|create|exec|call)\b", sql):
                yield sql, match.start(), "spark_sql_or_query_string"


def extract_ast_sql_assignments(code: str) -> Iterable[tuple[str, str, int]]:
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return
    for node in tree.body:
        if not isinstance(node, ast.Assign) or len(node.targets) != 1:
            continue
        target = node.targets[0]
        if not isinstance(target, ast.Name):
            continue
        call = node.value
        if not isinstance(call, ast.Call):
            continue
        func = call.func
        if not (
            isinstance(func, ast.Attribute)
            and func.attr == "sql"
            and isinstance(func.value, ast.Name)
            and func.value.id == "spark"
        ):
            continue
        if not call.args:
            continue
        sql_template = template_from_ast(call.args[0])
        if not sql_template or not re.search(r"(?i)\b(select|from|join|insert|merge|update|delete|create)\b", sql_template):
            continue
        yield target.id, sql_template, offset_for_lineno(code, getattr(node, "lineno", 1))


ASSIGN_READ_RE = re.compile(
    r"(?is)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:\(\s*)?(spark\.sql\s*\(.*?\)|spark\.read(?:\s*\\?\s*\.[A-Za-z_][A-Za-z0-9_]*\([^)]*\))*\s*\\?\s*\.(?:load|table)\s*\(.*?\)|spark\.table\s*\(.*?\))"
)

ASSIGN_LOAD_TABLE_RE = re.compile(
    r"(?is)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:data_load\.)?load_table\s*\((.*?)\)"
)

ASSIGN_SQL_STRING_RE = re.compile(
    r"(?is)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*spark\.sql\s*\(\s*(?:f)?(\"\"\".*?\"\"\"|'''.*?'''|\"(?:\\.|[^\"])+\"|'(?:\\.|[^'])+')"
)

ASSIGN_SQL_VARIABLE_RE = re.compile(
    r"(?is)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*spark\.sql\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)"
)


WRITE_VAR_RE = re.compile(
    r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*\.write(?:\s*\\?\s*\.[A-Za-z_][A-Za-z0-9_]*\([^)]*\))*\s*\\?\s*\.(saveAsTable|save|insertInto)\s*\(\s*(?:f)?[\"']([^\"']+)[\"']"
)

WRITE_VAR_ARG_RE = re.compile(
    r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*\.write(?:\s*\\?\s*\.[A-Za-z_][A-Za-z0-9_]*\([^)]*\))*\s*\\?\s*\.(saveAsTable|save|insertInto)\s*\(\s*([A-Za-z_][A-Za-z0-9_\.]*)"
)

WRITE_REDUCTION_RE = re.compile(
    r"(?is)\bwrite_reduction_table\s*\((.*?)\)"
)

DELTA_MERGE_RE = re.compile(
    r"(?is)\b(?:delta_merge_upsert|upsert_to_table)\s*\((.*?)\)"
)


def split_top_level_args(arg_text: str) -> list[str]:
    args: list[str] = []
    current: list[str] = []
    depth = 0
    quote = ""
    i = 0
    while i < len(arg_text):
        ch = arg_text[i]
        if quote:
            current.append(ch)
            if ch == quote and (i == 0 or arg_text[i - 1] != "\\"):
                quote = ""
        else:
            if ch in {"'", '"'}:
                quote = ch
                current.append(ch)
            elif ch in "([{":
                depth += 1
                current.append(ch)
            elif ch in ")]}":
                depth = max(0, depth - 1)
                current.append(ch)
            elif ch == "," and depth == 0:
                args.append("".join(current).strip())
                current = []
            else:
                current.append(ch)
        i += 1
    if current:
        args.append("".join(current).strip())
    return args


def keyword_arg(arg_text: str, name: str) -> str:
    for arg in split_top_level_args(arg_text):
        if "=" not in arg:
            continue
        key, value = arg.split("=", 1)
        if key.strip() == name:
            return value.strip()
    return ""


def resolve_arg_list(args: list[str], constants: dict[str, str]) -> tuple[list[str], str]:
    values: list[str] = []
    unresolved_parts: list[str] = []
    for arg in args:
        value, unresolved = resolve_arg_value(arg, constants)
        values.append(value)
        if unresolved:
            unresolved_parts.append(unresolved)
    return values, ",".join(x for x in unresolved_parts if x)


def collect_static_constructor_assignments(code: str, constants: dict[str, str]) -> dict[str, str]:
    values: dict[str, str] = {}
    constructors = {
        "source_fqn": 3,
        "source_fqn_ws": 4,
        "target_fqn": 4,
        "build_table_identifier": 3,
    }
    pattern = re.compile(
        r"(?ims)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]+)?=\s*"
        r"(source_fqn|source_fqn_ws|target_fqn|build_table_identifier)\s*\((.*?)\)"
    )
    for match in pattern.finditer(code):
        if is_ignored_context(code, match.start()):
            continue
        var_name, function_name, arg_text = match.group(1), match.group(2), match.group(3)
        args = split_top_level_args(arg_text)
        arity = constructors[function_name]
        if len(args) < arity:
            continue
        resolved_args, unresolved = resolve_arg_list(args[:arity], constants)
        if unresolved:
            continue
        clean_parts = [part.strip("`[]\"' ") for part in resolved_args if part.strip("`[]\"' ")]
        if len(clean_parts) == arity:
            values[var_name] = ".".join(clean_parts)
    return values


def combine_object_name(lakehouse: str, schema: str, table: str, constants: dict[str, str]) -> tuple[str, str]:
    lakehouse_value, lakehouse_unresolved = resolve_arg_value(lakehouse, constants) if lakehouse else ("", "")
    schema_value, schema_unresolved = resolve_arg_value(schema, constants) if schema else ("", "")
    table_value, table_unresolved = resolve_arg_value(table, constants) if table else ("", "")
    unresolved = ",".join(x for x in [lakehouse_unresolved, schema_unresolved, table_unresolved] if x)
    parts = [p for p in [lakehouse_value, schema_value, table_value] if p]
    return ".".join(parts), unresolved


def template_from_arg_node(node: ast.AST) -> str:
    value = literal_eval_node(node)
    if isinstance(value, (str, int, float)):
        return str(value)
    template = template_from_ast(node)
    if template is not None:
        return template
    try:
        return "{" + ast.unparse(node) + "}"
    except Exception:
        return ""


def ast_call_name(node: ast.AST) -> str:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return node.attr
    return ""


def function_param_names(node: ast.FunctionDef | ast.AsyncFunctionDef) -> list[str]:
    params = [arg.arg for arg in node.args.posonlyargs]
    params.extend(arg.arg for arg in node.args.args)
    params.extend(arg.arg for arg in node.args.kwonlyargs)
    return params


def call_argument_templates(call: ast.Call, params: list[str]) -> dict[str, str]:
    mapping: dict[str, str] = {}
    for param, arg in zip(params, call.args):
        value = template_from_arg_node(arg)
        if value:
            mapping[param] = value
    for keyword in call.keywords:
        if not keyword.arg:
            continue
        value = template_from_arg_node(keyword.value)
        if value:
            mapping[keyword.arg] = value
    return mapping


def keyword_node(call: ast.Call, name: str) -> ast.AST | None:
    for keyword in call.keywords:
        if keyword.arg == name:
            return keyword.value
    return None


def substitute_param_templates(template: str, mapping: dict[str, str]) -> str:
    def replace(match: re.Match[str]) -> str:
        return mapping.get(match.group(1), match.group(0))

    return re.sub(r"\{([A-Za-z_][A-Za-z0-9_]*)\}", replace, template)


def extract_parameterized_upsert_call_writes(code: str, constants: dict[str, str]) -> Iterable[tuple[str, int, str]]:
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return

    function_params: dict[str, list[str]] = {}
    body_upserts: dict[str, list[tuple[str, str, str, int, set[str]]]] = defaultdict(list)
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        params = function_param_names(node)
        function_params[node.name] = params
        param_set = set(params)
        for child in ast.walk(node):
            if not isinstance(child, ast.Call) or ast_call_name(child.func) not in {"upsert_to_table", "delta_merge_upsert"}:
                continue
            lakehouse_node = keyword_node(child, "lakehouse")
            schema_node = keyword_node(child, "schema")
            table_node = keyword_node(child, "table_name")
            if len(child.args) >= 5 and ast_call_name(child.func) == "upsert_to_table":
                lakehouse_node = lakehouse_node or child.args[2]
                schema_node = schema_node or child.args[3]
                table_node = table_node or child.args[4]
            if not lakehouse_node or not schema_node or not table_node:
                continue
            lakehouse = template_from_arg_node(lakehouse_node)
            schema = template_from_arg_node(schema_node)
            table = template_from_arg_node(table_node)
            referenced_params = {
                name
                for name in param_set
                if "{" + name + "}" in lakehouse or "{" + name + "}" in schema or "{" + name + "}" in table
            }
            if referenced_params:
                body_upserts[node.name].append(
                    (lakehouse, schema, table, offset_for_lineno(code, getattr(child, "lineno", 1)), referenced_params)
                )

    if not body_upserts:
        return

    seen: set[tuple[str, int]] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        function_name = ast_call_name(node.func)
        if function_name not in body_upserts:
            continue
        mapping = call_argument_templates(node, function_params.get(function_name, []))
        if not mapping:
            continue
        for lakehouse, schema, table, body_offset, referenced_params in body_upserts[function_name]:
            if not referenced_params.issubset(mapping):
                continue
            identifier = ".".join(
                part
                for part in [
                    substitute_param_templates(lakehouse, mapping),
                    substitute_param_templates(schema, mapping),
                    substitute_param_templates(table, mapping),
                ]
                if part
            )
            resolved, unresolved = resolve_template(identifier, constants)
            if unresolved or not resolved:
                continue
            key = (resolved, body_offset)
            if key in seen:
                continue
            seen.add(key)
            yield resolved, body_offset, function_name


def extract_helper_objects(code: str, constants: dict[str, str]) -> Iterable[tuple[str, str, str, int, str]]:
    # Generic ingestion helpers used by the local notebook codebase.
    function_ranges = collect_function_parameter_ranges(code)
    for match in re.finditer(r"(?is)\b(upsert_to_table|delta_merge_upsert)\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()) or is_function_definition_context(code, match.start()):
            continue
        function_name, arg_text = match.group(1), match.group(2)
        args = split_top_level_args(arg_text)
        lakehouse = keyword_arg(arg_text, "lakehouse")
        schema = keyword_arg(arg_text, "schema")
        table = keyword_arg(arg_text, "table_name")
        target_path = keyword_arg(arg_text, "target_path")
        if not table and len(args) >= 5 and function_name == "upsert_to_table":
            lakehouse, schema, table = args[2], args[3], args[4]
        if any(is_function_parameter_arg(arg, function_ranges, match.start()) for arg in [target_path, lakehouse, schema, table] if arg):
            continue
        if target_path:
            target_path_value, target_path_unresolved = resolve_arg_value(target_path, constants)
            if target_path_value and not re.search(r"[{}]", target_path_value):
                identifier, unresolved = target_path_value, target_path_unresolved
            else:
                identifier, unresolved = combine_object_name(lakehouse, schema, table, constants)
        else:
            identifier, unresolved = combine_object_name(lakehouse, schema, table, constants)
        if identifier:
            yield "write", function_name, identifier, match.start(), unresolved

    for match in re.finditer(r"(?is)\b(create_process_control_table|get_last_successful_process)\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()) or is_function_definition_context(code, match.start()):
            continue
        function_name, arg_text = match.group(1), match.group(2)
        lakehouse = keyword_arg(arg_text, "lakehouse")
        schema = keyword_arg(arg_text, "schema")
        table = keyword_arg(arg_text, "table_name")
        identifier, unresolved = combine_object_name(lakehouse, schema, table, constants)
        if identifier:
            direction = "write" if function_name == "create_process_control_table" else "read"
            yield direction, function_name, identifier, match.start(), unresolved

    for match in re.finditer(r"(?is)\bload_[A-Za-z0-9_]*inputs\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()) or is_function_definition_context(code, match.start()):
            continue
        arg_text = match.group(1)
        schema = keyword_arg(arg_text, "schema")
        for arg in split_top_level_args(arg_text):
            if "=" not in arg:
                continue
            key, value = arg.split("=", 1)
            if key.strip().endswith("_table_name"):
                identifier, unresolved = combine_object_name("", schema, value.strip(), constants)
                if identifier:
                    yield "read", "load_inputs_helper", identifier, match.start(), unresolved

    for match in re.finditer(r"(?is)\b(?:build_lh_read_path|build_table_path|build_lakehouse_tables?_path)\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()) or is_function_definition_context(code, match.start()):
            continue
        arg_text = match.group(1)
        args = split_top_level_args(arg_text)
        schema = keyword_arg(arg_text, "schema") or keyword_arg(arg_text, "schema_name")
        table = keyword_arg(arg_text, "table_name")
        if not table and len(args) >= 3:
            table = args[2]
        if not table or is_empty_literal_arg(table):
            continue
        expanded_tables = assignment_config_tables_for_arg(code, table, match.start())
        if expanded_tables:
            for expanded_table in expanded_tables:
                identifier, unresolved = combine_object_name("", schema, repr(expanded_table), constants)
                if identifier:
                    yield "read", "assignment_config_path_builder", identifier, match.start(), unresolved
            continue
        if is_function_parameter_arg(table, function_ranges, match.start()):
            continue
        identifier, unresolved = combine_object_name("", schema, table, constants)
        if identifier:
            yield "read", "path_builder", identifier, match.start(), unresolved

    for match in re.finditer(r"(?is)\b(?:data_load\.)?load_table\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()) or is_function_definition_context(code, match.start()):
            continue
        arg_text = match.group(1)
        args = split_top_level_args(arg_text)
        lakehouse = keyword_arg(arg_text, "lh_id") or keyword_arg(arg_text, "lakehouse_id")
        schema = keyword_arg(arg_text, "schema") or keyword_arg(arg_text, "schema_name")
        table = keyword_arg(arg_text, "table") or keyword_arg(arg_text, "table_name")
        if not lakehouse and len(args) >= 3:
            lakehouse = args[2]
        if not table and len(args) >= 4:
            table = args[3]
        if not schema and len(args) >= 5:
            schema = args[4]
        identifier, unresolved = combine_object_name(lakehouse, schema, table, constants)
        if identifier:
            yield "read", "load_table_helper", identifier, match.start(), unresolved

    for match in re.finditer(r"(?is)\bwrite_reduction_table\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()):
            continue
        line_prefix = code[code.rfind("\n", 0, match.start()) + 1:match.start()]
        if re.search(r"\bdef\s+$", line_prefix):
            continue
        arg_text = match.group(1)
        args = split_top_level_args(arg_text)
        table = keyword_arg(arg_text, "table_name")
        if not table and len(args) >= 2:
            table = args[1]
        identifier, unresolved = combine_object_name("out_base", "", table, constants)
        if identifier:
            yield "write", "write_reduction_table", identifier, match.start(), unresolved

    for match in re.finditer(r"(?is)\bspark\.table\s*\(\s*(get_bronze_table|get_silver_table|get_silver_control_table)\s*\((.*?)\)\s*\)", code):
        if is_ignored_context(code, match.start()):
            continue
        function_name, arg_text = match.group(1), match.group(2)
        identifier, unresolved = table_helper_identifier(function_name, arg_text, constants)
        if identifier:
            yield "read", function_name, identifier, match.start(), unresolved

    for match in re.finditer(r"(?is)\bsource_table\s*=\s*(get_bronze_table|get_silver_table|get_silver_control_table)\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()):
            continue
        function_name, arg_text = match.group(1), match.group(2)
        identifier, unresolved = table_helper_identifier(function_name, arg_text, constants)
        if identifier:
            yield "read", function_name, identifier, match.start(), unresolved

    for match in re.finditer(r"(?is)\bsaveAsTable\s*\(\s*(get_silver_table|get_silver_control_table)\s*\((.*?)\)\s*\)", code):
        if is_ignored_context(code, match.start()):
            continue
        function_name, arg_text = match.group(1), match.group(2)
        identifier, unresolved = table_helper_identifier(function_name, arg_text, constants)
        if identifier:
            yield "write", function_name, identifier, match.start(), unresolved

    for match in re.finditer(r"(?is)\bwrite_single_file_from_spark\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()):
            continue
        arg_text = match.group(1)
        output_dir = keyword_arg(arg_text, "output_dir")
        output_file = keyword_arg(arg_text, "output_file_name")
        dir_value, dir_unresolved = resolve_arg_value(output_dir, constants) if output_dir else ("", "")
        file_value, file_unresolved = resolve_arg_value(output_file, constants) if output_file else ("", "")
        identifier = ""
        if dir_value and file_value:
            identifier = f"{dir_value.rstrip('/')}/{file_value.lstrip('/')}"
        elif dir_value:
            identifier = dir_value
        elif file_value:
            identifier = file_value
        unresolved = ",".join(x for x in [dir_unresolved, file_unresolved] if x)
        if identifier:
            yield "write", "write_single_file_from_spark", identifier, match.start(), unresolved

    if re.search(r"(?is)\bdrop_table_if_exists\s*\(|mssparkutils\.fs\.rm\s*\(", code):
        for identifier, offset, unresolved in extract_drop_table_paths(code, constants):
            yield "write", "drop_table_path", identifier, offset, unresolved

    for match in re.finditer(r"(?im)^\s*%run\s+([^\s#]+)", code):
        yield "execute", "notebook_run_magic", match.group(1).strip(), match.start(), ""

    for match in re.finditer(r"(?is)\b(?:mssparkutils|notebookutils)(?:\.mssparkutils)?\.notebook\.run\s*\(\s*(?:f)?[\"']([^\"']+)[\"']", code):
        if is_ignored_context(code, match.start()):
            continue
        yield "execute", "notebook_run", match.group(1).strip(), match.start(), ""


def extract_table_relationships(code: str, constants: dict[str, str]) -> Iterable[tuple[str, list[str], int, str]]:
    for match in re.finditer(r"(?is)\bTableRelationship\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()):
            continue
        arg_text = match.group(1)
        target_arg = keyword_arg(arg_text, "target")
        sources_arg = keyword_arg(arg_text, "sources")
        if not target_arg or not sources_arg:
            args = split_top_level_args(arg_text)
            if not target_arg and args:
                target_arg = args[0]
            if not sources_arg and len(args) >= 2:
                sources_arg = args[1]
        if not target_arg or not sources_arg:
            continue
        target_value, target_unresolved = resolve_arg_value(target_arg, constants)
        raw_sources = sources_arg.strip()
        if raw_sources.startswith("[") and raw_sources.endswith("]"):
            raw_sources = raw_sources[1:-1]
        source_values: list[str] = []
        unresolved_parts: list[str] = []
        for source_arg in split_top_level_args(raw_sources):
            source_value, source_unresolved = resolve_arg_value(source_arg, constants)
            if source_value:
                source_values.append(source_value)
            if source_unresolved:
                unresolved_parts.append(source_unresolved)
        unresolved = ",".join(x for x in [target_unresolved, *unresolved_parts] if x)
        if target_value and source_values:
            yield target_value, source_values, match.start(), unresolved


def extract_dynamic_shortcut_flows(code: str, constants: dict[str, str]) -> Iterable[tuple[str, str, int, str]]:
    if not re.search(r"(?is)\bload_table_from_csv", code):
        return
    if not re.search(r"(?is)Files/\{path_shortcut\}/\{table_name\}/\{table_name\}\.csv", code):
        return
    if not re.search(r"(?is)\.saveAsTable\s*\(\s*f?['\"][^'\"]*\{table_name\}", code):
        return

    call_re = re.compile(r"(?is)\b(?:override_tables(?:_with_tracking)?|override_tables_with_tracking)\s*\((.*?)\)")
    for match in call_re.finditer(code):
        if is_ignored_context(code, match.start()):
            continue
        line_prefix = code[code.rfind("\n", 0, match.start()) + 1:match.start()]
        if re.search(r"\bdef\s+$", line_prefix):
            continue
        arg_text = match.group(1)
        path_arg = keyword_arg(arg_text, "path_shortcut")
        args = split_top_level_args(arg_text)
        if not path_arg and args:
            path_arg = args[0]
        shortcut, unresolved = resolve_arg_value(path_arg, constants) if path_arg else ("", "")
        if not shortcut:
            continue

        schema = "dbo"
        schema_match = re.search(r"(?m)^\s*def_schema\s*=\s*['\"]([^'\"]+)['\"]", code)
        if schema_match:
            schema = schema_match.group(1)
        elif constants.get("DBO_SCHEMA_NAME"):
            schema = constants["DBO_SCHEMA_NAME"]
        elif constants.get("process_context.schema_info"):
            schema = constants["process_context.schema_info"]
        elif constants.get("context.schema_info"):
            schema = constants["context.schema_info"]

        source = f"Files/{shortcut.strip('/')}/{{table_name}}/{{table_name}}.csv"
        target = f"{schema}.{{table_name}}"
        unresolved_vars = ",".join(x for x in [unresolved, "table_name"] if x)
        yield source, target, match.start(), unresolved_vars


def extract_bronze_to_silver_agg_flows(code: str, constants: dict[str, str]) -> Iterable[tuple[str, str, str, int]]:
    if not (re.search(r"\bupdate_delta_bronze_table\s*\(", code) and re.search(r"\bupdate_silver_aggregation\s*\(", code)):
        return
    bronze_parts = [constants.get("lh_bronze", ""), constants.get("schema", ""), constants.get("bronze_table", "")]
    silver_parts = [constants.get("lh_silver", ""), constants.get("schema", ""), constants.get("silver_table", "")]
    if not all(bronze_parts) or not all(silver_parts):
        return
    bronze_table = ".".join(bronze_parts)
    silver_table = ".".join(silver_parts)
    source_root = constants.get("shortcut_root", "")
    source_file = f"{source_root.rstrip('/')}/{constants.get('bronze_table', '').strip()}/*" if source_root else ""
    offset = 0
    call = re.search(r"\bupdate_silver_aggregation\s*\(", code)
    if call:
        offset = call.start()
    if source_file:
        yield source_file, bronze_table, "bronze_partition_refresh", offset
    yield bronze_table, silver_table, "silver_aggregation", offset


def simplify_path_template(value: str) -> str:
    return re.sub(r"""\{([A-Za-z_][A-Za-z0-9_]*)\.(?:r?strip|lstrip)\(['"]\/['"]\)\}""", r"{\1}", value)


def extract_write_bronze_hst_flows(code: str, constants: dict[str, str]) -> Iterable[tuple[str, str, str, int, str]]:
    for match in re.finditer(r"(?is)\bwrite_bronze_hst\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()):
            continue
        line_prefix = code[code.rfind("\n", 0, match.start()) + 1:match.start()]
        if re.search(r"\bdef\s+$", line_prefix):
            continue
        arg_text = match.group(1)
        args = split_top_level_args(arg_text)
        source_root = keyword_arg(arg_text, "source_shortcut_root") or (args[0] if len(args) >= 1 else "")
        source_rel = keyword_arg(arg_text, "source_rel_path") or (args[1] if len(args) >= 2 else "")
        dest_schema = keyword_arg(arg_text, "dest_schema") or (args[2] if len(args) >= 3 else "")
        dest_table = keyword_arg(arg_text, "dest_table") or (args[3] if len(args) >= 4 else "")
        root_value, root_unresolved = resolve_arg_value(source_root, constants) if source_root else ("", "")
        rel_value, rel_unresolved = resolve_arg_value(source_rel, constants) if source_rel else ("", "")
        schema_value, schema_unresolved = resolve_arg_value(dest_schema, constants) if dest_schema else ("", "")
        table_value, table_unresolved = resolve_arg_value(dest_table, constants) if dest_table else ("", "")
        if not (root_value and rel_value and schema_value and table_value):
            continue
        source_value = simplify_path_template(f"{root_value.rstrip('/')}/{rel_value.lstrip('/')}")
        target_value = f"{schema_value}.{table_value}"
        unresolved = ",".join(
            part for part in [root_unresolved, rel_unresolved, schema_unresolved, table_unresolved] if part
        )
        yield source_value, target_value, "write_bronze_hst_call", match.start(), unresolved

    if re.search(r"(?is)\bdef\s+write_bronze_hst\s*\(", code) and "source_path_full" in code and "saveAsTable" in code:
        offset_match = re.search(r"(?is)\bdef\s+write_bronze_hst\s*\(", code)
        source_value = "{source_shortcut_root_param}/{source_rel_path_param}"
        target_value = "{DEST_SCHEMA}.{DEST_TABLE}"
        yield source_value, target_value, "write_bronze_hst_helper", offset_match.start() if offset_match else 0, ""


def extract_cdf_scd1_flows(code: str, constants: dict[str, str]) -> Iterable[tuple[str, str, int, str]]:
    if not (re.search(r"(?is)\breadChangeFeed", code) and re.search(r"(?is)\bscd1_merge\s*\(", code)):
        return
    bronze_lh = constants.get("bronze_lh", "")
    silver_lh = constants.get("silver_lh", "")
    entity_name = constants.get("entity_name", "")
    if entity_name:
        ent_name = "FormSubmissions" if entity_name == "form_submissions" else entity_name.capitalize()
    else:
        ent_name = "{ent_name}"
    source = ".".join(part for part in [bronze_lh or "{bronze_lh}", "dbo", ent_name] if part)
    target = ".".join(part for part in [silver_lh or "{silver_lh}", "{table}"] if part)
    unresolved = ",".join(
        part
        for part in [
            "" if bronze_lh else "bronze_lh",
            "" if silver_lh else "silver_lh",
            "" if entity_name else "ent_name",
            "table",
        ]
        if part
    )
    call = re.search(r"(?is)\bscd1_merge\s*\(", code)
    yield source, target, call.start() if call else 0, unresolved


def configured_source_prefix(code: str, source_key: str) -> tuple[str, str]:
    table_row = re.compile(
        rf"(?im)^\s*#?\s*\|\s*`?{re.escape(source_key)}`?\s*\|\s*([^|\n]+?)\s*\|\s*([^|\n]+?)\s*\|"
    )
    for match in table_row.finditer(code):
        workspace_name = match.group(1).strip().strip("` ")
        lakehouse_name = match.group(2).strip().strip("` ")
        if set(workspace_name) <= {"-"} or set(lakehouse_name) <= {"-"}:
            continue
        if workspace_name and lakehouse_name:
            return f"{workspace_name}.{lakehouse_name}", ""
    if source_key == "datamartSales":
        default_lakehouse = re.search(r'"default_lakehouse_name"\s*:\s*"([^"]+)"', code)
        if default_lakehouse:
            return default_lakehouse.group(1), "source_workspace_name"
    return source_key, f"SOURCES.{source_key}"


def configured_source_identifier(code: str, source_key: str, table_name: str, constants: dict[str, str]) -> tuple[str, str]:
    schema = constants.get(f"SOURCES.{source_key}.schema", "dbo")
    prefix, unresolved = configured_source_prefix(code, source_key)
    identifier = ".".join(part for part in [prefix, schema, table_name] if part)
    return identifier, unresolved


def configured_target_identifier(table_name: str, constants: dict[str, str]) -> tuple[str, str]:
    workspace_name = constants.get("TARGET.workspace_name", "")
    lakehouse_name = constants.get("TARGET.lakehouse_name", "")
    schema = constants.get("TARGET.schema", "sales")
    unresolved_parts: list[str] = []
    if not workspace_name:
        unresolved_parts.append("TARGET.workspace_name")
    if not lakehouse_name:
        unresolved_parts.append("TARGET.lakehouse_name")
    identifier = ".".join(part for part in [workspace_name, lakehouse_name, schema, table_name] if part)
    return identifier, ",".join(unresolved_parts)


def collect_literal_string_dicts(code: str) -> dict[str, tuple[dict[str, str], int]]:
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return {}
    dictionaries: dict[str, tuple[dict[str, str], int]] = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.Dict):
            continue
        values: dict[str, str] = {}
        for key_node, value_node in zip(node.value.keys, node.value.values):
            if key_node is None:
                continue
            key = literal_eval_node(key_node)
            value = literal_eval_node(value_node)
            if isinstance(key, str) and isinstance(value, str):
                values[key] = value
        if not values:
            continue
        for target in node.targets:
            if isinstance(target, ast.Name):
                dictionaries[target.id] = (values, offset_for_lineno(code, getattr(node, "lineno", 1)))
    return dictionaries


def collect_local_function_names(code: str) -> set[str]:
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return set()
    return {node.name for node in tree.body if isinstance(node, ast.FunctionDef)}


def collect_no_arg_function_sql_sources(code: str) -> dict[str, list[tuple[str, int, str]]]:
    clean_code = clean_code_for_ast(code)
    try:
        tree = ast.parse(clean_code)
    except SyntaxError:
        return {}
    sources: dict[str, list[tuple[str, int, str]]] = {}
    for node in tree.body:
        if not isinstance(node, ast.FunctionDef):
            continue
        if node.args.args or node.args.posonlyargs or node.args.kwonlyargs or node.args.vararg or node.args.kwarg:
            continue
        segment = ast.get_source_segment(clean_code, node) or ""
        if not segment:
            continue
        base_offset = offset_for_lineno(code, getattr(node, "lineno", 1))
        function_sources: list[tuple[str, int, str]] = []
        for sql, rel_offset, evidence_type in extract_sql_strings(segment):
            function_sources.append((sql, base_offset + rel_offset, evidence_type))
        if function_sources:
            sources[node.name] = function_sources
    return sources


SAFE_DF_SOURCE_FUNCTIONS = {
    "build_crm_person_with_customer",
    "build_customer_product_link",
    "build_employee_product_link",
    "build_product_link",
    "build_stores_table",
    "get_employee_link_filter",
    "get_product_link_filter",
    "get_store_link_filter",
}


def collect_dataframe_output_dicts(code: str) -> dict[str, list[tuple[str, str, int]]]:
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return {}
    dictionaries: dict[str, list[tuple[str, str, int]]] = {}

    def register(name: str, value_node: ast.AST, lineno: int) -> None:
        if not isinstance(value_node, ast.Dict):
            return
        entries: list[tuple[str, str, int]] = []
        for key_node, item_node in zip(value_node.keys, value_node.values):
            table_name = literal_eval_node(key_node) if key_node is not None else None
            if isinstance(table_name, str) and isinstance(item_node, ast.Name):
                entries.append((table_name, item_node.id, offset_for_lineno(code, getattr(item_node, "lineno", lineno))))
        if entries:
            dictionaries[name] = entries

    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    register(target.id, node.value, getattr(node, "lineno", 1))
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.value is not None:
            register(node.target.id, node.value, getattr(node, "lineno", 1))
    return dictionaries


def collect_dataframe_tuple_lists(code: str, constants: dict[str, str]) -> dict[str, list[tuple[str, str, int]]]:
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return {}
    lists: dict[str, list[tuple[str, str, int]]] = {}

    def register(name: str, value_node: ast.AST, lineno: int) -> None:
        if not isinstance(value_node, (ast.List, ast.Tuple)):
            return
        entries: list[tuple[str, str, int]] = []
        for element in value_node.elts:
            if not isinstance(element, ast.Tuple) or len(element.elts) < 2:
                continue
            df_node, table_node = element.elts[0], element.elts[1]
            if not isinstance(df_node, ast.Name):
                continue
            table_name = literal_eval_node(table_node)
            unresolved = ""
            if not isinstance(table_name, str):
                table_template = template_from_ast(table_node)
                if table_template:
                    table_name, unresolved = resolve_template(table_template, constants)
            if isinstance(table_node, ast.Name):
                table_name, unresolved = resolve_arg_value(table_node.id, constants)
            if isinstance(table_name, str) and table_name and not unresolved:
                entries.append((table_name, df_node.id, offset_for_lineno(code, getattr(element, "lineno", lineno))))
        if entries:
            lists[name] = entries

    for node in tree.body:
        if isinstance(node, ast.Assign):
            for target in node.targets:
                if isinstance(target, ast.Name):
                    register(target.id, node.value, getattr(node, "lineno", 1))
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.value is not None:
            register(node.target.id, node.value, getattr(node, "lineno", 1))
    return lists


def collect_registered_source_views(code: str, constants: dict[str, str]) -> dict[str, dict[str, str]]:
    views: dict[str, dict[str, str]] = {}
    for match in re.finditer(r"(?is)\bregister_source_view\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()):
            continue
        line_prefix = code[code.rfind("\n", 0, match.start()) + 1:match.start()]
        if re.search(r"\bdef\s+$", line_prefix):
            continue
        arg_text = match.group(1)
        args = split_top_level_args(arg_text)
        source_arg = keyword_arg(arg_text, "source_key") or (args[0] if len(args) >= 1 else "")
        table_arg = keyword_arg(arg_text, "table_name") or (args[1] if len(args) >= 2 else "")
        view_arg = keyword_arg(arg_text, "view_name") or (args[2] if len(args) >= 3 else "")
        source_key, source_unresolved = resolve_arg_value(source_arg, constants) if source_arg else ("", "")
        table_name, table_unresolved = resolve_arg_value(table_arg, constants) if table_arg else ("", "")
        view_name, view_unresolved = resolve_arg_value(view_arg, constants) if view_arg else (table_name, "")
        if not source_key or not table_name or not view_name:
            continue
        source_identifier, source_identifier_unresolved = configured_source_identifier(code, source_key, table_name, constants)
        unresolved = ",".join(
            part for part in [source_unresolved, table_unresolved, view_unresolved, source_identifier_unresolved] if part
        )
        views[norm(view_name)] = {
            "view_name": view_name,
            "source_identifier": source_identifier,
            "offset": str(match.start()),
            "unresolved": unresolved,
        }
    return views


def remap_registered_view_identifier(
    identifier: str, registered_view_sources: dict[str, dict[str, str]]
) -> tuple[str, str]:
    clean = clean_identifier(identifier).replace("`", "").replace("[", "").replace("]", "").replace('"', "")
    candidates = [clean, clean.split(".")[-1] if "." in clean else clean]
    for candidate in candidates:
        source = registered_view_sources.get(norm(candidate))
        if source:
            return source["source_identifier"], source.get("unresolved", "")
    return identifier, ""


def resolve_sql_object_identifier(
    identifier: str,
    constants: dict[str, str],
    registered_view_sources: dict[str, dict[str, str]],
) -> tuple[str, str]:
    object_identifier, mapped_unresolved = remap_registered_view_identifier(identifier, registered_view_sources)
    _identifier_value, identifier_unresolved = resolve_template(object_identifier, constants)
    unresolved = ",".join(part for part in [identifier_unresolved, mapped_unresolved] if part)
    return object_identifier, unresolved


def extract_full_table_map_flows(code: str, constants: dict[str, str]) -> Iterable[tuple[str, str, int, str]]:
    dictionaries = collect_literal_string_dicts(code)
    if not dictionaries:
        return
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return
    for node in ast.walk(tree):
        if not isinstance(node, ast.For):
            continue
        if not isinstance(node.target, ast.Tuple) or len(node.target.elts) < 2:
            continue
        target_var_node, source_var_node = node.target.elts[:2]
        if not isinstance(target_var_node, ast.Name) or not isinstance(source_var_node, ast.Name):
            continue
        target_var = target_var_node.id
        source_var = source_var_node.id
        iter_node = node.iter
        if not (
            isinstance(iter_node, ast.Call)
            and isinstance(iter_node.func, ast.Attribute)
            and iter_node.func.attr == "items"
            and isinstance(iter_node.func.value, ast.Name)
        ):
            continue
        map_name = iter_node.func.value.id
        if map_name not in dictionaries:
            continue
        source_key = ""
        save_found = False
        for child in ast.walk(ast.Module(body=node.body, type_ignores=[])):
            if isinstance(child, ast.Call) and isinstance(child.func, ast.Name):
                if child.func.id == "_abfss" and len(child.args) >= 2:
                    first = literal_eval_node(child.args[0])
                    second = child.args[1]
                    if isinstance(first, str) and isinstance(second, ast.Name) and second.id == source_var:
                        source_key = first
                elif child.func.id == "save_to_sales" and len(child.args) >= 2:
                    second = child.args[1]
                    if isinstance(second, ast.Name) and second.id == target_var:
                        save_found = True
        if not source_key or not save_found:
            continue
        table_map, map_offset = dictionaries[map_name]
        flow_offset = offset_for_lineno(code, getattr(node, "lineno", 1)) or map_offset
        for target_table, source_table in table_map.items():
            source_identifier, source_unresolved = configured_source_identifier(code, source_key, source_table, constants)
            target_identifier, target_unresolved = configured_target_identifier(target_table, constants)
            unresolved = ",".join(part for part in [source_unresolved, target_unresolved] if part)
            yield source_identifier, target_identifier, flow_offset, unresolved


def extract_tracked_output_flows(code: str, constants: dict[str, str]) -> Iterable[tuple[str, str, str, int, str]]:
    if "TRACKED_OUTPUTS" not in code or "source_watermarks" not in code:
        return
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return
    for node in ast.walk(tree):
        if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.List):
            continue
        if not any(isinstance(target, ast.Name) and target.id == "TRACKED_OUTPUTS" for target in node.targets):
            continue
        offset = offset_for_lineno(code, getattr(node, "lineno", 1))
        for element in node.value.elts:
            if not isinstance(element, ast.Dict):
                continue
            table_name = ""
            dataframe = ""
            source_nodes: list[ast.AST] = []
            for key_node, value_node in zip(element.keys, element.values):
                key = literal_eval_node(key_node) if key_node is not None else None
                if key == "table_name":
                    value = literal_eval_node(value_node)
                    if isinstance(value, str):
                        table_name = value
                elif key == "dataframe" and isinstance(value_node, ast.Name):
                    dataframe = value_node.id
                elif key == "source_watermarks" and isinstance(value_node, ast.Dict):
                    source_nodes.extend(key for key in value_node.keys if key is not None)
            if not table_name or not source_nodes:
                continue
            target = ".".join(
                part
                for part in [
                    constants.get("TARGET_LAKEHOUSE", ""),
                    constants.get("TARGET_SCHEMA", "dbo"),
                    table_name,
                ]
                if part
            )
            target_unresolved = "" if constants.get("TARGET_LAKEHOUSE") else "TARGET_LAKEHOUSE"
            for source_node in source_nodes:
                source_value = ""
                source_unresolved = ""
                if isinstance(source_node, ast.Name):
                    source_value, source_unresolved = resolve_arg_value(source_node.id, constants)
                else:
                    literal = literal_eval_node(source_node)
                    if isinstance(literal, str):
                        source_value = literal
                    else:
                        template_value = template_from_ast(source_node)
                        if template_value:
                            source_value, source_unresolved = resolve_template(template_value, constants)
                if not source_value:
                    continue
                unresolved = ",".join(part for part in [source_unresolved, target_unresolved] if part)
                yield source_value, target, dataframe, offset, unresolved


def extract_drop_table_paths(code: str, constants: dict[str, str]) -> Iterable[tuple[str, int, str]]:
    seen: set[str] = set()
    for match in re.finditer(
        r"""(?is)f(['"])(?P<template>[^'"]*(?:/Tables/|_abfss_path)[^'"]+)\1\s+for\s+(?P<var>[A-Za-z_][A-Za-z0-9_]*)\s+in\s+(?P<list>[A-Za-z_][A-Za-z0-9_]*)""",
        code,
    ):
        template = match.group("template")
        var_name = match.group("var")
        list_name = match.group("list")
        for value in split_list(constants.get(list_name, "")):
            raw_identifier = template.replace("{" + var_name + "}", value)
            identifier, unresolved = resolve_template(raw_identifier, constants)
            if identifier and identifier not in seen:
                seen.add(identifier)
                yield identifier, match.start("template"), unresolved

    for match in re.finditer(r"""(?is)f(['"])(?P<template>[^'"]*(?:/Tables/|_abfss_path)[^'"]+)\1""", code):
        template = match.group("template")
        if re.search(r"\{[A-Za-z_][A-Za-z0-9_]*\}", template) and not re.search(
            r"\{(?:bronze_abfss_path|silver_abfss_path|gold_abfss_path)[^}]*\}", template
        ):
            continue
        identifier, unresolved = resolve_template(template, constants)
        if unresolved:
            continue
        if identifier and identifier not in seen:
            seen.add(identifier)
            yield identifier, match.start("template"), unresolved


def table_helper_identifier(function_name: str, arg_text: str, constants: dict[str, str]) -> tuple[str, str]:
    args = split_top_level_args(arg_text)
    table = keyword_arg(arg_text, "table_name")
    if not table and args:
        table = args[0]
    schema = keyword_arg(arg_text, "schema")
    if not schema:
        schema = "CONTROL_SCHEMA" if function_name == "get_silver_control_table" else "DATA_SCHEMA"
    lakehouse = {
        "get_bronze_table": "BRONZE_LAKEHOUSE",
        "get_silver_table": "SILVER_LAKEHOUSE",
        "get_silver_control_table": "SILVER_LAKEHOUSE",
    }.get(function_name, "")
    table_value, table_unresolved = resolve_arg_value(table, constants) if table else ("", "")
    if table_value and "." in table_value:
        return table_value, table_unresolved
    return combine_object_name(lakehouse, schema, table, constants)


def collect_path_builder_assignments(code: str, constants: dict[str, str]) -> dict[str, str]:
    values: dict[str, str] = {}
    function_ranges = collect_function_parameter_ranges(code)
    for match in re.finditer(r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:build_lh_read_path|build_table_path|build_lakehouse_tables?_path)\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()):
            continue
        var_name, arg_text = match.group(1), match.group(2)
        args = split_top_level_args(arg_text)
        schema = keyword_arg(arg_text, "schema") or keyword_arg(arg_text, "schema_name")
        table = keyword_arg(arg_text, "table_name")
        if not table and len(args) >= 3:
            table = args[2]
        if not table or is_empty_literal_arg(table):
            continue
        if is_function_parameter_arg(table, function_ranges, match.start()):
            continue
        identifier, _ = combine_object_name("", schema, table, constants)
        if identifier:
            values[var_name] = identifier
    for match in re.finditer(r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(get_bronze_table|get_silver_table|get_silver_control_table)\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()):
            continue
        var_name, function_name, arg_text = match.group(1), match.group(2), match.group(3)
        identifier, _ = table_helper_identifier(function_name, arg_text, constants)
        if identifier:
            values[var_name] = identifier
    for match in re.finditer(r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*build_lakehouse_files_path\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()):
            continue
        var_name, arg_text = match.group(1), match.group(2)
        relative_folder = keyword_arg(arg_text, "relative_folder")
        value, _ = resolve_arg_value(relative_folder, constants) if relative_folder else ("", "")
        if value:
            values[var_name] = value if value.startswith("Files/") else f"Files/{value.lstrip('/')}"
    for match in re.finditer(r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:data_load\.)?build_lh_write_path\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()):
            continue
        var_name, arg_text = match.group(1), match.group(2)
        args = split_top_level_args(arg_text)
        lakehouse = keyword_arg(arg_text, "lh_id") or keyword_arg(arg_text, "lakehouse_id")
        schema = keyword_arg(arg_text, "schema") or keyword_arg(arg_text, "schema_name")
        if not lakehouse and len(args) >= 2:
            lakehouse = args[1]
        identifier, _ = combine_object_name(lakehouse, schema, "", constants)
        if identifier:
            values[var_name] = identifier
    for match in re.finditer(r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*build_versioned_filename\s*\((.*?)\)", code):
        if is_ignored_context(code, match.start()):
            continue
        var_name, arg_text = match.group(1), match.group(2)
        base_name = keyword_arg(arg_text, "base_name")
        extension = keyword_arg(arg_text, "extension")
        base_value, _ = resolve_arg_value(base_name, constants) if base_name else ("", "")
        ext_value, _ = resolve_arg_value(extension, constants) if extension else ("", "")
        if base_value and ext_value:
            values[var_name] = f"{base_value}.{ext_value.lstrip('.')}"
    return values


@dataclass
class ObjectRow:
    notebook_key: str
    workspace_name: str
    workspace_environment: str
    notebook_name: str
    item_qualified_name: str
    direction: str
    operation: str
    source_type: str
    source_database: str
    schema_name: str
    object_name: str
    object_display_name: str
    dataframe: str
    line_number: str
    confidence: str
    evidence: str
    definition_path: str
    unresolved_variables: str = ""


@dataclass
class FlowRow:
    notebook_key: str
    workspace_name: str
    workspace_environment: str
    notebook_name: str
    item_qualified_name: str
    source_object: str
    target_object: str
    source_dataframe: str
    target_dataframe: str
    operation: str
    confidence: str
    evidence: str
    definition_path: str


@dataclass
class NotebookResult:
    objects: list[ObjectRow] = field(default_factory=list)
    flows: list[FlowRow] = field(default_factory=list)
    gaps: list[dict[str, str]] = field(default_factory=list)


def line_number_for_offset(text: str, offset: int) -> int:
    return text.count("\n", 0, max(0, offset)) + 1


def add_object(
    result: NotebookResult,
    item: dict[str, str],
    direction: str,
    operation: str,
    identifier: str,
    constants: dict[str, str],
    dataframe: str,
    offset: int,
    code: str,
    evidence: str,
    definition_path: str,
    confidence: str = "parsed",
) -> ObjectRow | None:
    """The common sink every extract_*/collect_* pattern-matcher in this file
    ultimately calls: resolves `identifier` against known constants (falling
    back to "likely" confidence if anything stays unresolved), skips it if it
    resolves to a noise value (a variable name, not a real object), splits it
    into type/database/schema/object parts, and appends one ObjectRow to
    `result`. Returns the row (or None if skipped) so a caller can chain
    further processing on it."""
    resolved, unresolved = resolve_template(identifier, constants)
    if is_noise_identifier(resolved):
        return None
    parts = object_parts(resolved)
    row = ObjectRow(
        notebook_key=stable_id(item["qualified_name"]),
        workspace_name=item.get("workspace_name", ""),
        workspace_environment=item.get("workspace_environment", ""),
        notebook_name=item.get("item_name", ""),
        item_qualified_name=item.get("qualified_name", ""),
        direction=direction,
        operation=operation,
        source_type=parts["source_type"],
        source_database=parts["source_database"],
        schema_name=parts["schema_name"],
        object_name=parts["object_name"],
        object_display_name=parts["object_display_name"],
        dataframe=dataframe,
        line_number=str(line_number_for_offset(code, offset)) if offset >= 0 else "",
        confidence="likely" if unresolved else confidence,
        evidence=evidence,
        definition_path=definition_path,
        unresolved_variables=unresolved,
    )
    result.objects.append(row)
    return row


def parse_sql_block_into_result(
    result: NotebookResult,
    item: dict[str, str],
    sql: str,
    constants: dict[str, str],
    offset: int,
    code: str,
    evidence_prefix: str,
    definition_path: str,
    flow_operation: str,
    entity_lookup: dict[str, dict[str, str]] | None = None,
    registered_view_sources: dict[str, dict[str, str]] | None = None,
) -> None:
    resolved_sql, unresolved = resolve_template(sql, constants)
    registered_view_sources = registered_view_sources or {}

    for chunk_offset, chunk in split_sql_lineage_chunks(resolved_sql):
        sql_objects = extract_sql_objects(chunk)
        writes: list[ObjectRow] = []
        reads: list[ObjectRow] = []
        for usage, identifier, verb in sql_objects:
            direction = "read" if usage == "read" else "write" if usage == "write" else "execute"
            object_identifier = identifier
            _identifier_value, object_unresolved = resolve_template(object_identifier, constants)
            if direction == "read":
                object_identifier, mapped_unresolved = remap_registered_view_identifier(identifier, registered_view_sources)
                _identifier_value, identifier_unresolved = resolve_template(object_identifier, constants)
                object_unresolved = ",".join(part for part in [identifier_unresolved, mapped_unresolved] if part)
            row = add_object(
                result,
                item,
                direction,
                f"sql_{verb.replace(' ', '_')}",
                object_identifier,
                constants,
                "",
                offset + chunk_offset,
                code,
                f"{evidence_prefix}: SQL verb '{verb}'.",
                definition_path,
                "likely" if object_unresolved else "parsed",
            )
            if row:
                if object_unresolved and not row.unresolved_variables:
                    row.unresolved_variables = object_unresolved
                if direction == "write":
                    writes.append(row)
                elif direction == "read":
                    reads.append(row)
        for target in writes:
            for source in reads:
                if source.object_display_name and target.object_display_name and source.object_display_name != target.object_display_name:
                    flow_confidence = "likely" if source.confidence == "likely" or target.confidence == "likely" else "parsed"
                    result.flows.append(
                        FlowRow(
                            notebook_key=stable_id(item["qualified_name"]),
                            workspace_name=item.get("workspace_name", ""),
                            workspace_environment=item.get("workspace_environment", ""),
                            notebook_name=item.get("item_name", ""),
                            item_qualified_name=item.get("qualified_name", ""),
                            source_object=source.object_display_name,
                            target_object=target.object_display_name,
                            source_dataframe="",
                            target_dataframe="",
                            operation=flow_operation,
                            confidence=flow_confidence,
                            evidence=f"{evidence_prefix}: SQL statement contains write target and read sources.",
                            definition_path=definition_path,
                        )
                    )

    entity_rows, field_rows = extract_control_config_mappings(resolved_sql, entity_lookup)
    for operation, rows in [("control_entity_config", entity_rows), ("control_entity_field_config", field_rows)]:
        for mapping in rows:
            mapping_offset = offset + int(mapping.get("offset", "0") or "0")
            confidence = "parsed" if mapping.get("source_lakehouse") and mapping.get("target_lakehouse") else "likely"
            source = add_object(
                result,
                item,
                "read",
                operation,
                mapping["source_object"],
                constants,
                "",
                mapping_offset,
                code,
                f"{evidence_prefix}: {operation} maps declared source object.",
                definition_path,
                confidence,
            )
            target = add_object(
                result,
                item,
                "write",
                operation,
                mapping["target_object"],
                constants,
                "",
                mapping_offset,
                code,
                f"{evidence_prefix}: {operation} maps declared target object.",
                definition_path,
                confidence,
            )
            if source and target and source.object_display_name != target.object_display_name:
                result.flows.append(
                    FlowRow(
                        notebook_key=stable_id(item["qualified_name"]),
                        workspace_name=item.get("workspace_name", ""),
                        workspace_environment=item.get("workspace_environment", ""),
                        notebook_name=item.get("item_name", ""),
                        item_qualified_name=item.get("qualified_name", ""),
                        source_object=source.object_display_name,
                        target_object=target.object_display_name,
                        source_dataframe="",
                        target_dataframe="",
                        operation=operation,
                        confidence=confidence,
                        evidence=f"{evidence_prefix}: control configuration declares source-to-target mapping.",
                        definition_path=definition_path,
                    )
                )


def lakehouse_tier(item_name: str) -> str:
    """Return "bronze"/"silver"/"gold" if the item's name contains that
    medallion-tier word, else "" -- used to pair a notebook's workspace with
    its sibling tier lakehouses in build_fabric_context()."""
    lower = item_name.casefold()
    for tier in ["bronze", "silver", "gold"]:
        if tier in lower:
            return tier
    return ""


def build_fabric_context(item_rows: list[dict[str, str]], workspace_rows: list[dict[str, str]]) -> dict[str, dict[tuple[str, str] | str, dict[str, str] | str]]:
    """Build a lookup the whole notebook parse needs but that isn't visible
    from a single notebook's own code: each workspace's bronze/silver/gold
    lakehouse items (keyed by (workspace_name, tier)) and every workspace's
    Fabric id. Consumed by contextual_fabric_constants() to resolve
    IEConnects-Variables-Library placeholders that reference "the current
    workspace's bronze lakehouse" without naming it directly."""
    lakehouses_by_workspace_tier: dict[tuple[str, str], dict[str, str]] = {}
    for row in item_rows:
        if row.get("item_type") != "Lakehouse" or not row.get("technical_id"):
            continue
        tier = lakehouse_tier(row.get("item_name", ""))
        if tier:
            lakehouses_by_workspace_tier[(row.get("workspace_name", ""), tier)] = row
    workspace_ids = {
        row.get("workspace_name", ""): row.get("technical_id", "")
        for row in workspace_rows
        if row.get("workspace_name") and row.get("technical_id")
    }
    return {
        "lakehouses_by_workspace_tier": lakehouses_by_workspace_tier,
        "workspace_ids": workspace_ids,
    }


def contextual_fabric_constants(
    code: str,
    item: dict[str, str],
    fabric_context: dict[str, dict[tuple[str, str] | str, dict[str, str] | str]],
    named_paths: bool = False,
) -> dict[str, str]:
    """Resolve this notebook's own workspace/lakehouse ids as pseudo-constants
    (ieconnects_ws_id, ieconnects_{tier}_lh_id, and optionally
    {tier}_abfss_path) -- but only when the code actually imports the shared
    "IEConnects-Variables-Library" notebook, since that's what makes these
    otherwise-external names resolvable in context. Without this, code like
    `variables.bronze_lh_id` would look like an unresolvable external
    reference instead of the current workspace's own bronze lakehouse."""
    constants: dict[str, str] = {}
    if "IEConnects-Variables-Library" not in code:
        return constants
    workspace_name = item.get("workspace_name", "")
    workspace_ids = fabric_context.get("workspace_ids", {})
    workspace_id = workspace_ids.get(workspace_name, "") if isinstance(workspace_ids, dict) else ""
    if isinstance(workspace_id, str) and workspace_id:
        constants["ieconnects_ws_id"] = workspace_id
    lakehouses = fabric_context.get("lakehouses_by_workspace_tier", {})
    if not isinstance(lakehouses, dict):
        return constants
    for tier in ["bronze", "silver", "gold"]:
        row = lakehouses.get((workspace_name, tier))
        if not isinstance(row, dict):
            continue
        item_name = row.get("item_name", "")
        item_id = row.get("technical_id", "")
        if item_id:
            constants[f"ieconnects_{tier}_lh_id"] = item_id
        if named_paths and item_name:
            constants[f"{tier}_abfss_path"] = f"{item_name}/Tables"
    return constants


def parse_notebook_code(
    item: dict[str, str],
    definition_path: Path,
    part_label: str,
    fabric_context: dict[str, dict[tuple[str, str] | str, dict[str, str] | str]] | None = None,
    static_control_config_lookup: dict[tuple[str, str], dict[str, str]] | None = None,
) -> NotebookResult:
    """Main per-notebook-definition entry point and the core of this file
    (~2,000 lines, to line ~5087). Given one downloaded notebook/SQL
    definition part, this: resolves constants (literal, Fabric-context, and
    path-builder), then runs the full battery of extract_*/collect_*
    pattern-matchers below (dozens of AST- and regex-based heuristics, each
    targeting one specific coding convention seen in real-world Fabric
    notebooks -- magic %%sql blocks, parameterized upserts, dict-driven temp
    views, shortcut/CDF flows, helper-function calls, etc.) to build up one
    NotebookResult of source/destination objects and flows, entirely by
    static analysis -- no notebook code is ever executed. Each individual
    extractor is intentionally narrow and conservative (see the module
    docstring): when in doubt, it records nothing rather than guessing.
    """
    code, markdown, _ = read_notebook_part(definition_path)
    inline_code = load_same_workspace_run_includes(code, definition_path)
    raw_parse_code = f"{inline_code}\n{code}" if inline_code else code
    parse_code = uncomment_magic_python(raw_parse_code)
    fabric_context = fabric_context or {}
    static_control_config_lookup = static_control_config_lookup or {}
    constants = collect_constants(parse_code)
    constants.update(contextual_fabric_constants(parse_code, item, fabric_context, named_paths=False))
    constants.update(collect_path_builder_assignments(parse_code, constants))
    constants.update(contextual_fabric_constants(parse_code, item, fabric_context, named_paths=True))
    static_entity_mapping = static_control_config_lookup.get(
        (item.get("workspace_name", ""), constants.get("entity_cfg", "").casefold())
    ) if constants.get("entity_cfg") else None
    result = NotebookResult()
    df_sources: dict[str, list[ObjectRow]] = defaultdict(list)
    dict_sources: dict[tuple[str, str], list[ObjectRow]] = defaultdict(list)
    registered_view_sources = collect_registered_source_views(parse_code, constants)
    local_function_names = collect_local_function_names(parse_code)
    no_arg_function_sql_sources = collect_no_arg_function_sql_sources(parse_code)
    static_dict_load_vars = collect_static_dict_temp_view_load_vars(parse_code, constants)
    parameterized_local_vars = (
        collect_parameterized_local_assignment_vars(parse_code)
        if "ENDPOINTS_CONFIG" in parse_code and "ingest_entity" in parse_code
        else []
    )
    table_ref_vars = collect_call_assignment_vars(parse_code, {"_build_table_ref"}) if "check_last_execution_status" in parse_code else []
    registry_path_vars = collect_loop_var_ranges(parse_code, {"registry_paths"}) if "load_previous_managed_shortcuts" in parse_code else []
    assignment_config_path_vars = collect_assignment_config_path_vars(parse_code) if "get_assignment_config" in parse_code else []
    runtime_config_vars = collect_static_control_config_runtime_vars(parse_code) if static_entity_mapping else []
    variable_skip_ranges = static_dict_load_vars + parameterized_local_vars + table_ref_vars + registry_path_vars + assignment_config_path_vars + runtime_config_vars
    traceable_function_names = local_function_names | SAFE_DF_SOURCE_FUNCTIONS
    magic_sql_blocks = list(extract_magic_sql_blocks(raw_parse_code))
    magic_entity_lookup = build_entity_config_lookup(sql for sql, _offset, _evidence_type in magic_sql_blocks)

    if definition_path.suffix.lower() == ".sql":
        parse_sql_block_into_result(
            result,
            item,
            code,
            constants,
            0,
            code,
            "SQL notebook content",
            part_label,
            "sql_notebook",
            registered_view_sources=registered_view_sources,
        )
        if not result.objects:
            result.gaps.append({"gap_type": "no_objects_parsed", "notes": "SQL notebook downloaded but no read/write/execute object references matched current parser."})
        return result

    # Markdown summaries often contain curated Sources/Destinations sections.
    for md_match in re.finditer(r"(?im)^\s*-\s+([A-Za-z0-9_.\-/]+(?:\.[A-Za-z0-9_\-/]+){1,3})\s*$", markdown):
        context = markdown[max(0, md_match.start() - 500): md_match.start()]
        direction = "write" if re.search(r"(?i)destinations?", context) else "read" if re.search(r"(?i)sources?", context) else ""
        if direction:
            add_object(result, item, direction, "markdown_summary", md_match.group(1), constants, "", -1, code, "Notebook markdown source/destination summary.", part_label, "review")

    for sql, offset, evidence_type in magic_sql_blocks:
        parse_sql_block_into_result(
            result,
            item,
            sql,
            constants,
            offset,
            raw_parse_code,
            evidence_type,
            part_label,
            "sql_magic",
            magic_entity_lookup,
            registered_view_sources,
        )

    for view in registered_view_sources.values():
        source_row = add_object(
            result,
            item,
            "read",
            "register_source_view",
            view["source_identifier"],
            constants,
            view["view_name"],
            int(view.get("offset", "0") or "0"),
            parse_code,
            "register_source_view declares temp view source table.",
            part_label,
            "likely" if view.get("unresolved") else "parsed",
        )
        if source_row and view.get("unresolved") and not source_row.unresolved_variables:
            source_row.unresolved_variables = view["unresolved"]
            source_row.confidence = "likely"

    if static_entity_mapping:
        entity_offset = parse_code.find(constants.get("entity_cfg", ""))
        if entity_offset < 0:
            entity_offset = 0
        source_row = add_object(
            result,
            item,
            "read",
            "static_control_config_backfill",
            static_entity_mapping["source_object"],
            constants,
            "",
            entity_offset,
            parse_code,
            "Local control config definition maps runtime entity source object.",
            part_label,
            "parsed",
        )
        target_row = add_object(
            result,
            item,
            "write",
            "static_control_config_backfill",
            static_entity_mapping["target_object"],
            constants,
            "",
            entity_offset,
            parse_code,
            "Local control config definition maps runtime entity target object.",
            part_label,
            "parsed",
        )
        if source_row and target_row and source_row.object_display_name != target_row.object_display_name:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source_row.object_display_name,
                    target_object=target_row.object_display_name,
                    source_dataframe="",
                    target_dataframe="",
                    operation="static_control_config_backfill",
                    confidence="parsed",
                    evidence="Local control config definition maps runtime entity source-to-target objects.",
                    definition_path=part_label,
                )
            )

    for source_identifier, view_name, entry_offset in extract_static_dict_temp_view_flows(parse_code, constants):
        source_row = add_object(
            result,
            item,
            "read",
            "static_dict_temp_view_source",
            source_identifier,
            constants,
            "",
            entry_offset,
            parse_code,
            "Static dictionary loop reads table before creating a temp view.",
            part_label,
        )
        target_row = add_object(
            result,
            item,
            "write",
            "static_dict_temp_view",
            view_name,
            constants,
            "",
            entry_offset,
            parse_code,
            "Static dictionary loop creates temp view.",
            part_label,
        )
        if source_row and target_row and source_row.object_display_name != target_row.object_display_name:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source_row.object_display_name,
                    target_object=target_row.object_display_name,
                    source_dataframe="",
                    target_dataframe="",
                    operation="static_dict_temp_view",
                    confidence="parsed",
                    evidence="Static dictionary loop maps source table to temp view.",
                    definition_path=part_label,
                )
            )

    for target_value, offset in extract_static_endpoint_ingest_writes(parse_code, constants):
        add_object(
            result,
            item,
            "write",
            "static_endpoint_ingest_target",
            target_value,
            constants,
            "",
            offset,
            parse_code,
            "Static ENDPOINTS_CONFIG entry maps API entity to dbo/hst Delta targets.",
            part_label,
            "parsed",
        )

    for source_value, target_value, source_dataframe, target_dataframe, offset, evidence in extract_external_api_ingest_flows(parse_code, constants):
        source = add_object(
            result,
            item,
            "read",
            "external_api_ingest_endpoint",
            source_value,
            constants,
            source_dataframe,
            offset,
            parse_code,
            evidence,
            part_label,
            "parsed",
        )
        target = add_object(
            result,
            item,
            "write",
            "external_api_ingest_endpoint",
            target_value,
            constants,
            target_dataframe,
            offset,
            parse_code,
            evidence,
            part_label,
            "parsed",
        )
        if source and target and source.object_display_name != target.object_display_name:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target.object_display_name,
                    source_dataframe=source_dataframe,
                    target_dataframe=target_dataframe,
                    operation="external_api_ingest_endpoint",
                    confidence="parsed",
                    evidence=evidence,
                    definition_path=part_label,
                )
            )

    for source_value, target_value, source_dataframe, target_dataframe, offset, evidence in extract_static_notebook_dataset_flows(parse_code, constants):
        source = add_object(
            result,
            item,
            "read",
            "static_notebook_dataset",
            source_value,
            constants,
            source_dataframe,
            offset,
            parse_code,
            evidence,
            part_label,
            "parsed",
        )
        target = add_object(
            result,
            item,
            "write",
            "static_notebook_dataset",
            target_value,
            constants,
            target_dataframe,
            offset,
            parse_code,
            evidence,
            part_label,
            "parsed",
        )
        if source and target and source.object_display_name != target.object_display_name:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target.object_display_name,
                    source_dataframe=source_dataframe,
                    target_dataframe=target_dataframe,
                    operation="static_notebook_dataset",
                    confidence="parsed",
                    evidence=evidence,
                    definition_path=part_label,
                )
            )

    for source_value, target_value, source_dataframe, target_dataframe, offset, evidence in extract_static_empty_dataframe_bootstrap_flows(parse_code, constants):
        source = add_object(
            result,
            item,
            "read",
            "static_empty_dataframe_bootstrap",
            source_value,
            constants,
            source_dataframe,
            offset,
            parse_code,
            evidence,
            part_label,
            "parsed",
        )
        target = add_object(
            result,
            item,
            "write",
            "static_empty_dataframe_bootstrap",
            target_value,
            constants,
            target_dataframe,
            offset,
            parse_code,
            evidence,
            part_label,
            "parsed",
        )
        if source and target and source.object_display_name != target.object_display_name:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target.object_display_name,
                    source_dataframe=source_dataframe,
                    target_dataframe=target_dataframe,
                    operation="static_empty_dataframe_bootstrap",
                    confidence="parsed",
                    evidence=evidence,
                    definition_path=part_label,
                )
            )

    for source_value, target_value, source_dataframe, target_dataframe, offset, evidence in extract_delta_maintenance_log_flows(parse_code, constants):
        source = add_object(
            result,
            item,
            "read",
            "delta_maintenance_log",
            source_value,
            constants,
            source_dataframe,
            offset,
            parse_code,
            evidence,
            part_label,
            "parsed",
        )
        target = add_object(
            result,
            item,
            "write",
            "delta_maintenance_log",
            target_value,
            constants,
            target_dataframe,
            offset,
            parse_code,
            evidence,
            part_label,
            "parsed",
        )
        if source and target and source.object_display_name != target.object_display_name:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target.object_display_name,
                    source_dataframe=source_dataframe,
                    target_dataframe=target_dataframe,
                    operation="delta_maintenance_log",
                    confidence="parsed",
                    evidence=evidence,
                    definition_path=part_label,
                )
            )

    for source_value, target_value, source_dataframe, target_dataframe, offset, evidence in extract_static_sql_seed_flows(parse_code, constants):
        operation = "static_sql_ddl_bootstrap" if source_value.endswith("sql_DDL_schema") else "static_sql_values_seed"
        source = add_object(
            result,
            item,
            "read",
            operation,
            source_value,
            constants,
            source_dataframe,
            offset,
            parse_code,
            evidence,
            part_label,
            "parsed",
        )
        target = add_object(
            result,
            item,
            "write",
            operation,
            target_value,
            constants,
            target_dataframe,
            offset,
            parse_code,
            evidence,
            part_label,
            "parsed",
        )
        if source and target and source.object_display_name != target.object_display_name:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target.object_display_name,
                    source_dataframe=source_dataframe,
                    target_dataframe=target_dataframe,
                    operation=operation,
                    confidence="parsed",
                    evidence=evidence,
                    definition_path=part_label,
                )
            )

    for source_value, offset in extract_control_status_check_reads(parse_code, constants):
        add_object(
            result,
            item,
            "read",
            "control_status_check",
            source_value,
            constants,
            "",
            offset,
            parse_code,
            "check_last_execution_status reads control.TableStatus from a declared workspace/lakehouse.",
            part_label,
            "parsed",
        )

    for direction, identifier, offset in extract_central_registry_audit_objects(parse_code, constants):
        add_object(
            result,
            item,
            direction,
            "central_registry_audit_table",
            identifier,
            constants,
            "",
            offset,
            parse_code,
            "Central registry notebook reads/writes declared audit Delta tables.",
            part_label,
            "parsed",
        )

    for usage, operation, value, offset in extract_string_arg_patterns(parse_code):
        row = add_object(result, item, usage, operation, value, constants, "", offset, parse_code, f"Detected {operation} call.", part_label)
        if row and usage == "read":
            # If assignment can be inferred from preceding same statement, attach later through ASSIGN_READ_RE.
            pass

    for usage, operation, value, offset, unresolved_arg in extract_variable_arg_patterns(parse_code, constants, variable_skip_ranges):
        if not value:
            continue
        row = add_object(
            result,
            item,
            usage,
            operation,
            value,
            constants,
            "",
            offset,
            parse_code,
            f"Detected {operation} call through variable argument.",
            part_label,
            "likely" if unresolved_arg else "parsed",
        )
        if row and unresolved_arg and not row.unresolved_variables:
            row.unresolved_variables = unresolved_arg
            row.confidence = "likely"

    for value, offset, function_name in extract_parameterized_upsert_call_writes(parse_code, constants):
        add_object(
            result,
            item,
            "write",
            "parameterized_upsert_call",
            value,
            constants,
            "",
            offset,
            parse_code,
            f"Function '{function_name}' calls upsert_to_table with concrete arguments at call site.",
            part_label,
            "parsed",
        )

    for usage, operation, value, offset, unresolved_arg in extract_helper_objects(parse_code, constants):
        row = add_object(result, item, usage, operation, value, constants, "", offset, parse_code, f"Detected local helper '{operation}' object argument.", part_label, "parsed")
        if row and unresolved_arg and not row.unresolved_variables:
            row.unresolved_variables = unresolved_arg
            row.confidence = "likely"

    for target_value, source_values, offset, unresolved in extract_table_relationships(parse_code, constants):
        target = add_object(
            result,
            item,
            "write",
            "process_tracker_relationship",
            target_value,
            constants,
            "",
            offset,
            parse_code,
            "ProcessTracker TableRelationship declares target object.",
            part_label,
            "likely" if unresolved else "parsed",
        )
        if target and unresolved and not target.unresolved_variables:
            target.unresolved_variables = unresolved
            target.confidence = "likely"
        for source_value in source_values:
            source = add_object(
                result,
                item,
                "read",
                "process_tracker_relationship",
                source_value,
                constants,
                "",
                offset,
                parse_code,
                "ProcessTracker TableRelationship declares source object.",
                part_label,
                "likely" if unresolved else "parsed",
            )
            if source and unresolved and not source.unresolved_variables:
                source.unresolved_variables = unresolved
                source.confidence = "likely"
            if source and target and source.object_display_name != target.object_display_name:
                result.flows.append(
                    FlowRow(
                        notebook_key=stable_id(item["qualified_name"]),
                        workspace_name=item.get("workspace_name", ""),
                        workspace_environment=item.get("workspace_environment", ""),
                        notebook_name=item.get("item_name", ""),
                        item_qualified_name=item.get("qualified_name", ""),
                        source_object=source.object_display_name,
                        target_object=target.object_display_name,
                        source_dataframe="",
                        target_dataframe="",
                        operation="process_tracker_relationship",
                        confidence="likely" if source.confidence == "likely" or target.confidence == "likely" else "parsed",
                        evidence="ProcessTracker TableRelationship declares source-to-target mapping.",
                        definition_path=part_label,
                    )
                )

    for source_value, target_value, offset, unresolved in extract_dynamic_shortcut_flows(parse_code, constants):
        source = add_object(
            result,
            item,
            "read",
            "dynamic_shortcut_csv_load",
            source_value,
            constants,
            "table_name",
            offset,
            parse_code,
            "Dynamic shortcut CSV loader reads table-named files.",
            part_label,
            "likely",
        )
        target = add_object(
            result,
            item,
            "write",
            "dynamic_shortcut_csv_load",
            target_value,
            constants,
            "table_name",
            offset,
            parse_code,
            "Dynamic shortcut CSV loader writes same table name to Delta.",
            part_label,
            "likely",
        )
        for row in [source, target]:
            if row and unresolved and not row.unresolved_variables:
                row.unresolved_variables = unresolved
                row.confidence = "likely"
        if source and target:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target.object_display_name,
                    source_dataframe="table_name",
                    target_dataframe="table_name",
                    operation="dynamic_shortcut_csv_load",
                    confidence="likely",
                    evidence="Code maps Files/{path_shortcut}/{table_name}/{table_name}.csv to schema.{table_name}.",
                    definition_path=part_label,
                )
            )

    for source_value, target_value, operation, offset in extract_bronze_to_silver_agg_flows(parse_code, constants):
        source = add_object(
            result,
            item,
            "read",
            operation,
            source_value,
            constants,
            "",
            offset,
            parse_code,
            f"Detected {operation} source.",
            part_label,
            "parsed",
        )
        target = add_object(
            result,
            item,
            "write",
            operation,
            target_value,
            constants,
            "",
            offset,
            parse_code,
            f"Detected {operation} target.",
            part_label,
            "parsed",
        )
        if source and target and source.object_display_name != target.object_display_name:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target.object_display_name,
                    source_dataframe="",
                    target_dataframe="",
                    operation=operation,
                    confidence="parsed",
                    evidence=f"Static code links {operation} source to target.",
                    definition_path=part_label,
                )
            )

    for source_value, target_value, operation, offset, unresolved in extract_write_bronze_hst_flows(parse_code, constants):
        source = add_object(
            result,
            item,
            "read",
            operation,
            source_value,
            constants,
            "",
            offset,
            parse_code,
            "CDP bronze HST helper reads parquet files from shortcut path.",
            part_label,
            "likely",
        )
        target = add_object(
            result,
            item,
            "write",
            operation,
            target_value,
            constants,
            "",
            offset,
            parse_code,
            "CDP bronze HST helper writes append Delta table.",
            part_label,
            "likely",
        )
        for row in [source, target]:
            if row and unresolved and not row.unresolved_variables:
                row.unresolved_variables = unresolved
                row.confidence = "likely"
        if source and target and source.object_display_name != target.object_display_name:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target.object_display_name,
                    source_dataframe="",
                    target_dataframe="",
                    operation=operation,
                    confidence="likely",
                    evidence="write_bronze_hst maps shortcut parquet input to destination Delta table.",
                    definition_path=part_label,
                )
            )

    for source_value, target_value, offset, unresolved in extract_cdf_scd1_flows(parse_code, constants):
        source = add_object(
            result,
            item,
            "read",
            "cdf_scd1_merge",
            source_value,
            constants,
            "df_cdf_delta",
            offset,
            parse_code,
            "CDF silver handler reads bronze change feed.",
            part_label,
            "likely" if unresolved else "parsed",
        )
        target = add_object(
            result,
            item,
            "write",
            "cdf_scd1_merge",
            target_value,
            constants,
            "df_out",
            offset,
            parse_code,
            "CDF silver handler writes transformer outputs through scd1_merge.",
            part_label,
            "likely",
        )
        for row in [source, target]:
            if row and unresolved and not row.unresolved_variables:
                row.unresolved_variables = unresolved
                row.confidence = "likely"
        if source and target and source.object_display_name != target.object_display_name:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target.object_display_name,
                    source_dataframe="df_cdf_delta",
                    target_dataframe="df_out",
                    operation="cdf_scd1_merge",
                    confidence="likely",
                    evidence="Code links bronze CDF source to silver scd1_merge target; transformer table name remains dynamic.",
                    definition_path=part_label,
                )
            )

    for source_value, target_value, offset, unresolved in extract_full_table_map_flows(parse_code, constants):
        source = add_object(
            result,
            item,
            "read",
            "full_table_map",
            source_value,
            constants,
            "",
            offset,
            parse_code,
            "FULL_TABLE_MAP declares source table for full copy.",
            part_label,
            "likely" if unresolved else "parsed",
        )
        target = add_object(
            result,
            item,
            "write",
            "full_table_map",
            target_value,
            constants,
            "",
            offset,
            parse_code,
            "FULL_TABLE_MAP declares target table for full copy.",
            part_label,
            "likely" if unresolved else "parsed",
        )
        for row in [source, target]:
            if row and unresolved and not row.unresolved_variables:
                row.unresolved_variables = unresolved
                row.confidence = "likely"
        if source and target and source.object_display_name != target.object_display_name:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target.object_display_name,
                    source_dataframe="",
                    target_dataframe="",
                    operation="full_table_map",
                    confidence="likely" if source.confidence == "likely" or target.confidence == "likely" else "parsed",
                    evidence="FULL_TABLE_MAP loop copies declared source table to declared target table.",
                    definition_path=part_label,
                )
            )

    for source_value, target_value, dataframe, offset, unresolved in extract_tracked_output_flows(parse_code, constants):
        source = add_object(
            result,
            item,
            "read",
            "tracked_output_watermark",
            source_value,
            constants,
            dataframe,
            offset,
            parse_code,
            "TRACKED_OUTPUTS source_watermarks declares source table.",
            part_label,
            "likely" if unresolved else "parsed",
        )
        target = add_object(
            result,
            item,
            "write",
            "tracked_output_watermark",
            target_value,
            constants,
            dataframe,
            offset,
            parse_code,
            "TRACKED_OUTPUTS declares target output table.",
            part_label,
            "likely" if unresolved else "parsed",
        )
        for row in [source, target]:
            if row and unresolved and not row.unresolved_variables:
                row.unresolved_variables = unresolved
                row.confidence = "likely"
        if source and target and source.object_display_name != target.object_display_name:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target.object_display_name,
                    source_dataframe=dataframe,
                    target_dataframe=dataframe,
                    operation="tracked_output_watermark",
                    confidence="likely" if source.confidence == "likely" or target.confidence == "likely" else "parsed",
                    evidence="TRACKED_OUTPUTS maps source_watermarks to output table.",
                    definition_path=part_label,
                )
            )

    for sql, offset, evidence_type in extract_sql_strings(parse_code):
        resolved_sql, _unresolved = resolve_template(sql, constants)
        for usage, identifier, verb in extract_sql_objects(resolved_sql):
            direction = "read" if usage == "read" else "write" if usage == "write" else "execute"
            object_identifier, object_unresolved = resolve_sql_object_identifier(identifier, constants, registered_view_sources)
            row = add_object(
                result,
                item,
                direction,
                f"sql_{verb.replace(' ', '_')}",
                object_identifier,
                constants,
                "",
                offset,
                parse_code,
                f"{evidence_type}: SQL verb '{verb}'.",
                part_label,
                "likely" if object_unresolved else "parsed",
            )
            if row and object_unresolved and not row.unresolved_variables:
                row.unresolved_variables = object_unresolved
                row.confidence = "likely"

    for match in ASSIGN_SQL_STRING_RE.finditer(parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        df_name = match.group(1)
        raw_sql = match.group(2)
        try:
            sql = ast.literal_eval(raw_sql)
        except Exception:
            sql = raw_sql.strip("\"'")
        resolved_sql, _unresolved = resolve_template(sql, constants)
        statement_rows: list[ObjectRow] = []
        for usage, identifier, verb in extract_sql_objects(resolved_sql):
            if usage != "read":
                continue
            object_identifier, object_unresolved = resolve_sql_object_identifier(identifier, constants, registered_view_sources)
            row = add_object(
                result,
                item,
                "read",
                f"sql_{verb.replace(' ', '_')}",
                object_identifier,
                constants,
                df_name,
                match.start(2),
                parse_code,
                f"DataFrame '{df_name}' assigned from SQL verb '{verb}'.",
                part_label,
                "likely" if object_unresolved else "parsed",
            )
            if row:
                if object_unresolved and not row.unresolved_variables:
                    row.unresolved_variables = object_unresolved
                statement_rows.append(row)
        if statement_rows:
            df_sources[df_name].extend(statement_rows)

    for match in ASSIGN_SQL_VARIABLE_RE.finditer(parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        df_name, sql_var = match.group(1), match.group(2)
        if sql_var not in constants:
            continue
        resolved_sql, _unresolved = resolve_template(constants[sql_var], constants)
        statement_rows: list[ObjectRow] = []
        for usage, identifier, verb in extract_sql_objects(resolved_sql):
            if usage != "read":
                continue
            object_identifier, object_unresolved = resolve_sql_object_identifier(identifier, constants, registered_view_sources)
            row = add_object(
                result,
                item,
                "read",
                f"sql_{verb.replace(' ', '_')}",
                object_identifier,
                constants,
                df_name,
                match.start(2),
                parse_code,
                f"DataFrame '{df_name}' assigned from SQL variable '{sql_var}' verb '{verb}'.",
                part_label,
                "likely" if object_unresolved else "parsed",
            )
            if row:
                if object_unresolved and not row.unresolved_variables:
                    row.unresolved_variables = object_unresolved
                statement_rows.append(row)
        if statement_rows:
            df_sources[df_name].extend(statement_rows)

    for df_name, sql, offset in extract_ast_sql_assignments(parse_code):
        if is_ignored_context(parse_code, offset):
            continue
        line_number = str(line_number_for_offset(parse_code, offset))
        if any(
            row.dataframe == df_name and row.operation.startswith("sql_") and row.line_number == line_number
            for row in result.objects
        ):
            continue
        resolved_sql, _unresolved = resolve_template(sql, constants)
        statement_rows: list[ObjectRow] = []
        for usage, identifier, verb in extract_sql_objects(resolved_sql):
            if usage != "read":
                continue
            object_identifier, object_unresolved = resolve_sql_object_identifier(identifier, constants, registered_view_sources)
            row = add_object(
                result,
                item,
                "read",
                f"sql_{verb.replace(' ', '_')}",
                object_identifier,
                constants,
                df_name,
                offset,
                parse_code,
                f"DataFrame '{df_name}' assigned from AST SQL verb '{verb}'.",
                part_label,
                "likely" if object_unresolved else "parsed",
            )
            if row:
                if object_unresolved and not row.unresolved_variables:
                    row.unresolved_variables = object_unresolved
                statement_rows.append(row)
        if statement_rows:
            df_sources[df_name].extend(statement_rows)

    for match in re.finditer(r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)", parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        df_name, function_name = match.group(1), match.group(2)
        if function_name not in no_arg_function_sql_sources:
            continue
        statement_rows: list[ObjectRow] = []
        for sql, offset, evidence_type in no_arg_function_sql_sources[function_name]:
            resolved_sql, _unresolved = resolve_template(sql, constants)
            for usage, identifier, verb in extract_sql_objects(resolved_sql):
                if usage != "read":
                    continue
                object_identifier, object_unresolved = resolve_sql_object_identifier(identifier, constants, registered_view_sources)
                row = add_object(
                    result,
                    item,
                    "read",
                    f"sql_{verb.replace(' ', '_')}",
                    object_identifier,
                    constants,
                    df_name,
                    offset,
                    parse_code,
                    f"DataFrame '{df_name}' assigned from local SQL function '{function_name}' verb '{verb}'.",
                    part_label,
                    "likely" if object_unresolved else "parsed",
                )
                if row:
                    if object_unresolved and not row.unresolved_variables:
                        row.unresolved_variables = object_unresolved
                    statement_rows.append(row)
        if statement_rows:
            df_sources[df_name].extend(statement_rows)

    for match in ASSIGN_READ_RE.finditer(parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        df_name = match.group(1)
        statement = match.group(2)
        statement_offset = match.start(2)
        statement_rows: list[ObjectRow] = []
        for usage, operation, value, rel_offset in extract_string_arg_patterns(statement):
            if usage != "read":
                continue
            row = add_object(result, item, "read", operation, value, constants, df_name, statement_offset + rel_offset, parse_code, f"DataFrame '{df_name}' assigned from {operation}.", part_label)
            if row:
                statement_rows.append(row)
        for usage, operation, value, rel_offset, unresolved_arg in extract_variable_arg_patterns(statement, constants, variable_skip_ranges, statement_offset):
            if usage != "read":
                continue
            absolute_offset = statement_offset + rel_offset
            row = add_object(
                result,
                item,
                "read",
                operation,
                value,
                constants,
                df_name,
                absolute_offset,
                parse_code,
                f"DataFrame '{df_name}' assigned from {operation}.",
                part_label,
                "likely" if unresolved_arg else "parsed",
            )
            if row:
                if unresolved_arg and not row.unresolved_variables:
                    row.unresolved_variables = unresolved_arg
                statement_rows.append(row)
        for sql, rel_offset, evidence_type in extract_sql_strings(statement):
            resolved_sql, _ = resolve_template(sql, constants)
            for usage, identifier, verb in extract_sql_objects(resolved_sql):
                if usage != "read":
                    continue
                object_identifier, object_unresolved = resolve_sql_object_identifier(identifier, constants, registered_view_sources)
                row = add_object(
                    result,
                    item,
                    "read",
                    f"sql_{verb.replace(' ', '_')}",
                    object_identifier,
                    constants,
                    df_name,
                    statement_offset + rel_offset,
                    parse_code,
                    f"DataFrame '{df_name}' assigned from SQL verb '{verb}'.",
                    part_label,
                    "likely" if object_unresolved else "parsed",
                )
                if row:
                    if object_unresolved and not row.unresolved_variables:
                        row.unresolved_variables = object_unresolved
                    statement_rows.append(row)
        if statement_rows:
            df_sources[df_name].extend(statement_rows)

    for match in ASSIGN_LOAD_TABLE_RE.finditer(parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        df_name = match.group(1)
        arg_text = match.group(2)
        args = split_top_level_args(arg_text)
        lakehouse = keyword_arg(arg_text, "lh_id") or keyword_arg(arg_text, "lakehouse_id")
        schema = keyword_arg(arg_text, "schema") or keyword_arg(arg_text, "schema_name")
        table = keyword_arg(arg_text, "table") or keyword_arg(arg_text, "table_name")
        if not lakehouse and len(args) >= 3:
            lakehouse = args[2]
        if not table and len(args) >= 4:
            table = args[3]
        if not schema and len(args) >= 5:
            schema = args[4]
        identifier, unresolved = combine_object_name(lakehouse, schema, table, constants)
        if identifier:
            row = add_object(
                result,
                item,
                "read",
                "load_table_helper",
                identifier,
                constants,
                df_name,
                match.start(2),
                parse_code,
                f"DataFrame '{df_name}' assigned from load_table helper.",
                part_label,
                "likely" if unresolved else "parsed",
            )
            if row:
                if unresolved and not row.unresolved_variables:
                    row.unresolved_variables = unresolved
                df_sources[df_name].append(row)

    for match in re.finditer(r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*df_to_process\s*\((.*?)\)", parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        line_prefix = parse_code[parse_code.rfind("\n", 0, match.start()) + 1:match.start()]
        if re.search(r"\bdef\s+$", line_prefix):
            continue
        df_name, arg_text = match.group(1), match.group(2)
        args = split_top_level_args(arg_text)
        entity = keyword_arg(arg_text, "entity")
        orig_schema = keyword_arg(arg_text, "orig_schema")
        if not entity and args:
            entity = args[0]
        if not orig_schema and len(args) >= 2:
            orig_schema = args[1]
        identifier, unresolved = combine_object_name("", orig_schema, entity, constants)
        if identifier:
            row = add_object(
                result,
                item,
                "read",
                "df_to_process_helper",
                identifier,
                constants,
                df_name,
                match.start(2),
                parse_code,
                f"DataFrame '{df_name}' assigned from df_to_process helper.",
                part_label,
                "likely" if unresolved else "parsed",
            )
            if row:
                if unresolved and not row.unresolved_variables:
                    row.unresolved_variables = unresolved
                df_sources[df_name].append(row)

    for match in re.finditer(r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\bload_[A-Za-z0-9_]*inputs\s*\((.*?)\)", parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        dict_name, arg_text = match.group(1), match.group(2)
        schema = keyword_arg(arg_text, "schema")
        for arg in split_top_level_args(arg_text):
            if "=" not in arg:
                continue
            key, value = arg.split("=", 1)
            key = key.strip()
            if not key.endswith("_table_name"):
                continue
            dict_key = key[: -len("_table_name")]
            identifier, unresolved = combine_object_name("", schema, value.strip(), constants)
            if not identifier:
                continue
            row = add_object(
                result,
                item,
                "read",
                "load_inputs_helper",
                identifier,
                constants,
                f"{dict_name}[{dict_key}]",
                match.start(2),
                parse_code,
                f"Input dictionary '{dict_name}' key '{dict_key}' assigned from load inputs helper.",
                part_label,
                "likely" if unresolved else "parsed",
            )
            if row:
                if unresolved and not row.unresolved_variables:
                    row.unresolved_variables = unresolved
                dict_sources[(dict_name, dict_key)].append(row)
                # Ejemplo ilustrativo: prefijos que marcan una clave como
                # alias de otro sistema origen (p.ej.
                # "crm_leads_table_name" es un alias de "leads_table_name").
                # Adapta la lista a los prefijos de tu propio entorno.
                alias_keys = []
                for prefix in ["crm_", "vendor_", "legacy_", "dept_"]:
                    if dict_key.startswith(prefix):
                        alias_keys.append(dict_key[len(prefix):])
                for alias_key in alias_keys:
                    dict_sources[(dict_name, alias_key)].append(row)

    for match in re.finditer(r"""(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)\s*\[\s*['"]([^'"]+)['"]\s*\]""", parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        df_name, dict_name, dict_key = match.group(1), match.group(2), match.group(3)
        if (dict_name, dict_key) in dict_sources:
            df_sources[df_name].extend(dict_sources[(dict_name, dict_key)])

    try:
        propagation_tree = ast.parse(clean_code_for_ast(parse_code))
    except SyntaxError:
        propagation_tree = None

    # Propagate DataFrame derivations like df2 = df1.transform(...), multiline
    # chains, local DataFrame functions, and joins. Iterate because notebooks
    # often build several layers.
    for _ in range(8):
        changed = False
        for match in re.finditer(r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*)(?:\.|$)", parse_code):
            target, source = match.group(1), match.group(2)
            if source in df_sources:
                before = len(df_sources[target])
                df_sources[target].extend(x for x in df_sources[source] if x not in df_sources[target])
                changed = changed or len(df_sources[target]) > before
        for match in re.finditer(r"(?ms)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\b(?P<body>.*?)(?=^\S|\Z)", parse_code):
            target, left, body = match.group(1), match.group(2), match.group("body")
            before = len(df_sources[target])
            if left in df_sources:
                df_sources[target].extend(x for x in df_sources[left] if x not in df_sources[target])
            for joined in re.findall(r"\.join\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)", body):
                if joined in df_sources:
                    df_sources[target].extend(x for x in df_sources[joined] if x not in df_sources[target])
            changed = changed or len(df_sources[target]) > before
        for match in re.finditer(
            r"(?ms)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:,\s*[A-Za-z_][A-Za-z0-9_]*)*\s*=\s*"
            r"run_group_pipeline\s*\((?P<body>.*?)(?=^\S|\Z)",
            parse_code,
        ):
            target, body = match.group(1), match.group("body")
            before = len(df_sources[target])
            for source in sorted(set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\b", body))):
                if source in df_sources and source != target:
                    df_sources[target].extend(x for x in df_sources[source] if x not in df_sources[target])
            changed = changed or len(df_sources[target]) > before
        for line in parse_code.splitlines():
            match = re.search(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([A-Za-z_][A-Za-z0-9_]*).{0,600}?\.join\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)", line)
            if not match:
                continue
            target, left, right = match.group(1), match.group(2), match.group(3)
            before = len(df_sources[target])
            if left in df_sources:
                df_sources[target].extend(x for x in df_sources[left] if x not in df_sources[target])
            if right in df_sources:
                df_sources[target].extend(x for x in df_sources[right] if x not in df_sources[target])
            changed = changed or len(df_sources[target]) > before
        if propagation_tree:
            for node in ast.walk(propagation_tree):
                if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.Call):
                    continue
                if len(node.targets) != 1 or not isinstance(node.targets[0], ast.Name):
                    continue
                call = node.value
                if not isinstance(call.func, ast.Name) or call.func.id not in traceable_function_names:
                    continue
                target = node.targets[0].id
                source_names: list[str] = []
                for arg_node in list(call.args) + [kw.value for kw in call.keywords if kw.value is not None]:
                    if isinstance(arg_node, ast.Name):
                        source_names.append(arg_node.id)
                if not source_names:
                    continue
                before = len(df_sources[target])
                for source_name in source_names:
                    if source_name in df_sources:
                        df_sources[target].extend(x for x in df_sources[source_name] if x not in df_sources[target])
                changed = changed or len(df_sources[target]) > before
        if not changed:
            break

    if propagation_tree:
        for node in ast.walk(propagation_tree):
            if not isinstance(node, ast.Assign) or not isinstance(node.value, ast.Call):
                continue
            if len(node.targets) != 1 or not isinstance(node.targets[0], ast.Name):
                continue
            call = node.value
            if not isinstance(call.func, ast.Name) or call.func.id not in traceable_function_names:
                continue
            target = node.targets[0].id
            source_names: list[str] = []
            for arg_node in list(call.args) + [kw.value for kw in call.keywords if kw.value is not None]:
                if isinstance(arg_node, ast.Name):
                    source_names.append(arg_node.id)
            explicit_sources: list[ObjectRow] = []
            for source_name in source_names:
                explicit_sources.extend(row for row in df_sources.get(source_name, []) if row not in explicit_sources)
            if explicit_sources:
                df_sources[target] = explicit_sources

    temp_view_sources: dict[str, list[ObjectRow]] = defaultdict(list)
    record_sources: dict[str, list[ObjectRow]] = defaultdict(list)

    def extend_sources(target_name: str, rows: list[ObjectRow]) -> bool:
        if not target_name or not rows:
            return False
        before = len(df_sources[target_name])
        df_sources[target_name].extend(row for row in rows if row not in df_sources[target_name])
        return len(df_sources[target_name]) > before

    def temp_sources_for_identifier(identifier: str) -> list[ObjectRow]:
        clean = clean_identifier(identifier).replace("`", "").replace("[", "").replace("]", "").replace('"', "")
        keys = [norm(clean)]
        if "." in clean:
            keys.append(norm(clean.split(".")[-1]))
        rows: list[ObjectRow] = []
        for key in keys:
            rows.extend(row for row in temp_view_sources.get(key, []) if row not in rows)
        return rows

    for _ in range(4):
        changed = False
        for match in re.finditer(r"""(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*\.createOrReplaceTempView\s*\(\s*['"]([^'"]+)['"]\s*\)""", parse_code):
            if is_ignored_context(parse_code, match.start()):
                continue
            df_name, view_name = match.group(1), match.group(2)
            rows = df_sources.get(df_name, [])
            if not rows:
                continue
            key = norm(view_name)
            before = len(temp_view_sources[key])
            temp_view_sources[key].extend(row for row in rows if row not in temp_view_sources[key])
            changed = changed or len(temp_view_sources[key]) > before

        for match in ASSIGN_SQL_STRING_RE.finditer(parse_code):
            if is_ignored_context(parse_code, match.start()):
                continue
            df_name = match.group(1)
            raw_sql = match.group(2)
            try:
                sql = ast.literal_eval(raw_sql)
            except Exception:
                sql = raw_sql.strip("\"'")
            source_rows: list[ObjectRow] = []
            for usage, identifier, _verb in extract_sql_objects(resolve_template(sql, constants)[0]):
                if usage == "read":
                    source_rows.extend(row for row in temp_sources_for_identifier(identifier) if row not in source_rows)
            changed = extend_sources(df_name, source_rows) or changed

        for match in ASSIGN_SQL_VARIABLE_RE.finditer(parse_code):
            if is_ignored_context(parse_code, match.start()):
                continue
            df_name, sql_var = match.group(1), match.group(2)
            if sql_var not in constants:
                continue
            source_rows: list[ObjectRow] = []
            for usage, identifier, _verb in extract_sql_objects(resolve_template(constants[sql_var], constants)[0]):
                if usage == "read":
                    source_rows.extend(row for row in temp_sources_for_identifier(identifier) if row not in source_rows)
            changed = extend_sources(df_name, source_rows) or changed

        for match in re.finditer(
            r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:,\s*[A-Za-z_][A-Za-z0-9_]*)+\s*=\s*execute_crm_bulk_patch\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)",
            parse_code,
        ):
            record_name, source_df = match.group(1), match.group(2)
            rows = df_sources.get(source_df, [])
            if not rows:
                continue
            before = len(record_sources[record_name])
            record_sources[record_name].extend(row for row in rows if row not in record_sources[record_name])
            changed = changed or len(record_sources[record_name]) > before

        for match in re.finditer(r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*spark\.createDataFrame\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)", parse_code):
            if is_ignored_context(parse_code, match.start()):
                continue
            df_name, record_name = match.group(1), match.group(2)
            changed = extend_sources(df_name, record_sources.get(record_name, [])) or changed

        if not changed:
            break

    for match in re.finditer(r"(?is)\bexecute_crm_bulk_patch\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)", parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        source_df = match.group(1)
        entity = constants.get("entity_name", "{entity_name}")
        target_row = add_object(
            result,
            item,
            "write",
            "external_crm_patch",
            f"ExternalCRM.{entity}",
            constants,
            source_df,
            match.start(),
            parse_code,
            f"DataFrame '{source_df}' is sent to an external CRM batch PATCH.",
            part_label,
            "likely" if "{" in entity else "parsed",
        )
        if not target_row:
            continue
        for source in df_sources.get(source_df, []):
            if norm(source.object_display_name) in temp_view_sources:
                continue
            if source.object_display_name == target_row.object_display_name:
                continue
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target_row.object_display_name,
                    source_dataframe=source.dataframe,
                    target_dataframe=source_df,
                    operation="external_crm_patch",
                    confidence="likely" if source.confidence == "likely" or target_row.confidence == "likely" else "parsed",
                    evidence=f"DataFrame '{source_df}' is posted to an external CRM after local filtering.",
                    definition_path=part_label,
                )
            )

    def add_dataframe_write_target(
        df_name: str,
        target_value: str,
        operation: str,
        offset: int,
        evidence: str,
        confidence: str = "parsed",
        fallback_sources: list[ObjectRow] | None = None,
        flow_confidence: str | None = None,
    ) -> ObjectRow | None:
        target_row = add_object(
            result,
            item,
            "write",
            operation,
            target_value,
            constants,
            df_name,
            offset,
            parse_code,
            evidence,
            part_label,
            confidence,
        )
        if not target_row:
            return None
        source_rows = list(df_sources.get(df_name, []))
        if not source_rows and fallback_sources:
            source_rows = fallback_sources
        for source in source_rows:
            if source.object_display_name == target_row.object_display_name:
                continue
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target_row.object_display_name,
                    source_dataframe=source.dataframe,
                    target_dataframe=df_name,
                    operation=operation,
                    confidence=flow_confidence
                    or ("likely" if source.confidence == "likely" or target_row.confidence == "likely" else "parsed"),
                    evidence=evidence,
                    definition_path=part_label,
                )
            )
        return target_row

    def declared_read_sources_for_table(table_name: str) -> list[ObjectRow]:
        preferred: list[ObjectRow] = []
        fallback: list[ObjectRow] = []
        for row in result.objects:
            if row.direction != "read" or row.operation != "load_inputs_helper":
                continue
            if norm(row.object_name) != norm(table_name):
                continue
            if row.dataframe.startswith("input_dfs["):
                preferred.append(row)
            elif not row.dataframe:
                fallback.append(row)
        return preferred or fallback

    if "write_or_merge_table" in parse_code:
        output_dicts = collect_dataframe_output_dicts(parse_code)
        for dict_name, entries in output_dicts.items():
            if not re.search(
                rf"(?is)\bfor\s+[A-Za-z_][A-Za-z0-9_]*\s*,\s*[A-Za-z_][A-Za-z0-9_]*\s+in\s+{re.escape(dict_name)}\.items\s*\(\s*\).*?\bwrite_or_merge_table\s*\(",
                parse_code,
            ):
                continue
            for table_name, df_name, offset in entries:
                schema = constants.get("OUTPUT_SCHEMA", "")
                target_value = ".".join(part for part in [schema, table_name] if part)
                add_dataframe_write_target(
                    df_name,
                    target_value,
                    "write_or_merge_table_loop_dict",
                    offset,
                    f"Loop over '{dict_name}' writes DataFrame '{df_name}' to declared table '{table_name}'.",
                )

        tuple_lists = collect_dataframe_tuple_lists(parse_code, constants)
        for list_name, entries in tuple_lists.items():
            if not re.search(
                rf"(?is)\bfor\s+[A-Za-z_][A-Za-z0-9_]*\s*,\s*[A-Za-z_][A-Za-z0-9_]*\s*,\s*[A-Za-z_][A-Za-z0-9_]*\s+in\s+{re.escape(list_name)}\s*:.*?\bwrite_or_merge_table\s*\(",
                parse_code,
            ):
                continue
            for table_name, df_name, offset in entries:
                schema = constants.get("OUTPUT_SCHEMA", "")
                target_value = ".".join(part for part in [schema, table_name] if part)
                fallback_sources = declared_read_sources_for_table(table_name) if "reduce_crm_tables" in parse_code else []
                add_dataframe_write_target(
                    df_name,
                    target_value,
                    "write_or_merge_table_tuple_list",
                    offset,
                    f"Loop over '{list_name}' writes DataFrame '{df_name}' to declared table '{table_name}'.",
                    fallback_sources=fallback_sources,
                    flow_confidence="likely" if fallback_sources and "reduce_crm_tables" in parse_code else None,
                )

    delta_table_targets: dict[str, tuple[str, int, str]] = {}
    for match in re.finditer(
        r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*DeltaTable\.forName\s*\(\s*[^,]+,\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)",
        parse_code,
    ):
        if is_ignored_context(parse_code, match.start()):
            continue
        target_value, unresolved = resolve_arg_value(match.group(2), constants)
        if target_value:
            delta_table_targets[match.group(1)] = (target_value, match.start(), unresolved)

    for match in re.finditer(
        r"(?is)\b([A-Za-z_][A-Za-z0-9_]*)(?:\s*\.alias\s*\([^)]*\))?\s*\.merge\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\.alias\s*\([^)]*\))?",
        parse_code,
    ):
        if is_ignored_context(parse_code, match.start()):
            continue
        table_var, df_name = match.group(1), match.group(2)
        if table_var not in delta_table_targets:
            continue
        target_value, target_offset, unresolved = delta_table_targets[table_var]
        add_dataframe_write_target(
            df_name,
            target_value,
            "delta_table_merge",
            target_offset,
            f"DeltaTable variable '{table_var}' merges DataFrame '{df_name}' into declared target.",
            "likely" if unresolved else "parsed",
        )

    for match in WRITE_VAR_RE.finditer(parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        df_name, op, target = match.group(1), match.group(2), match.group(3)
        target_row = add_object(result, item, "write", op, target, constants, df_name, match.start(), parse_code, f"DataFrame '{df_name}' writes with {op}.", part_label)
        if not target_row:
            continue
        sources = df_sources.get(df_name, [])
        for source in sources:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target_row.object_display_name,
                    source_dataframe=source.dataframe,
                    target_dataframe=df_name,
                    operation=op,
                    confidence="likely" if source.confidence == "likely" or target_row.confidence == "likely" else "parsed",
                    evidence=f"DataFrame variable '{df_name}' links read object to write target.",
                    definition_path=part_label,
                )
            )

    for match in WRITE_VAR_ARG_RE.finditer(parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        df_name, op, target_arg = match.group(1), match.group(2), match.group(3)
        remainder = parse_code[match.end(3):].lstrip()
        if target_arg.lower() in {"f", "r", "u", "b", "fr", "rf"} and remainder.startswith(("'", '"')):
            continue
        if is_parameterized_path_builder_var(target_arg, variable_skip_ranges, match.start()):
            continue
        target, unresolved_arg = resolve_arg_value(target_arg, constants)
        target_row = add_object(
            result,
            item,
            "write",
            f"{op}_variable",
            target,
            constants,
            df_name,
            match.start(),
            parse_code,
            f"DataFrame '{df_name}' writes with {op} using variable argument.",
            part_label,
            "likely" if unresolved_arg else "parsed",
        )
        if not target_row:
            continue
        if unresolved_arg and not target_row.unresolved_variables:
            target_row.unresolved_variables = unresolved_arg
        sources = df_sources.get(df_name, [])
        for source in sources:
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target_row.object_display_name,
                    source_dataframe=source.dataframe,
                    target_dataframe=df_name,
                    operation=f"{op}_variable",
                    confidence="likely" if source.confidence == "likely" or target_row.confidence == "likely" else "parsed",
                    evidence=f"DataFrame variable '{df_name}' links read object to variable write target.",
                    definition_path=part_label,
                )
            )

    for match in re.finditer(r"(?is)\bwrite_delta_table\s*\((.*?)\)", parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        line_prefix = parse_code[parse_code.rfind("\n", 0, match.start()) + 1:match.start()]
        if re.search(r"\bdef\s+$", line_prefix):
            continue
        args = split_top_level_args(match.group(1))
        if len(args) < 2:
            continue
        df_name = args[0].strip()
        target_arg = args[1].strip()
        target, unresolved_arg = resolve_arg_value(target_arg, constants)
        target_row = add_object(
            result,
            item,
            "write",
            "write_delta_table",
            target,
            constants,
            df_name,
            match.start(),
            parse_code,
            f"DataFrame '{df_name}' writes with write_delta_table helper.",
            part_label,
            "likely" if unresolved_arg else "parsed",
        )
        if not target_row:
            continue
        if unresolved_arg and not target_row.unresolved_variables:
            target_row.unresolved_variables = unresolved_arg
            target_row.confidence = "likely"
        for source in df_sources.get(df_name, []):
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target_row.object_display_name,
                    source_dataframe=source.dataframe,
                    target_dataframe=df_name,
                    operation="write_delta_table",
                    confidence="likely" if source.confidence == "likely" or target_row.confidence == "likely" else "parsed",
                    evidence=f"DataFrame variable '{df_name}' links read object to write_delta_table target.",
                    definition_path=part_label,
                )
            )

    for match in re.finditer(r"(?is)\bsave_to_sales\s*\((.*?)\)", parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        line_prefix = parse_code[parse_code.rfind("\n", 0, match.start()) + 1:match.start()]
        if re.search(r"\bdef\s+$", line_prefix):
            continue
        args = split_top_level_args(match.group(1))
        if len(args) < 2:
            continue
        df_name = args[0].strip()
        target_table, target_table_unresolved = resolve_arg_value(args[1].strip(), constants)
        if not target_table:
            continue
        target_value, target_unresolved = configured_target_identifier(target_table, constants)
        combined_unresolved = ",".join(part for part in [target_table_unresolved, target_unresolved] if part)
        target_row = add_object(
            result,
            item,
            "write",
            "save_to_sales",
            target_value,
            constants,
            df_name,
            match.start(),
            parse_code,
            f"DataFrame '{df_name}' writes with save_to_sales helper.",
            part_label,
            "likely" if combined_unresolved else "parsed",
        )
        if not target_row:
            continue
        if combined_unresolved and not target_row.unresolved_variables:
            target_row.unresolved_variables = combined_unresolved
            target_row.confidence = "likely"
        for source in df_sources.get(df_name, []):
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target_row.object_display_name,
                    source_dataframe=source.dataframe,
                    target_dataframe=df_name,
                    operation="save_to_sales",
                    confidence="likely" if source.confidence == "likely" or target_row.confidence == "likely" else "parsed",
                    evidence=f"DataFrame variable '{df_name}' links SQL/read sources to save_to_sales target.",
                    definition_path=part_label,
                )
            )

    for match in re.finditer(r"(?is)\bwrite_single_file_from_spark\s*\((.*?)\)", parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        line_prefix = parse_code[parse_code.rfind("\n", 0, match.start()) + 1:match.start()]
        if re.search(r"\bdef\s+$", line_prefix):
            continue
        arg_text = match.group(1)
        args = split_top_level_args(arg_text)
        df_name = keyword_arg(arg_text, "df") or (args[0] if len(args) >= 1 else "")
        output_dir = keyword_arg(arg_text, "output_dir") or (args[1] if len(args) >= 2 else "")
        output_file = keyword_arg(arg_text, "output_file_name") or (args[2] if len(args) >= 3 else "")
        df_name = df_name.strip()
        dir_value, dir_unresolved = resolve_arg_value(output_dir, constants) if output_dir else ("", "")
        file_value, file_unresolved = resolve_arg_value(output_file, constants) if output_file else ("", "")
        if dir_value and file_value:
            target_value = f"{dir_value.rstrip('/')}/{file_value.lstrip('/')}"
        elif dir_value:
            target_value = dir_value
        else:
            target_value = file_value
        unresolved = ",".join(part for part in [dir_unresolved, file_unresolved] if part)
        target_row = add_object(
            result,
            item,
            "write",
            "write_single_file_from_spark",
            target_value,
            constants,
            df_name,
            match.start(),
            parse_code,
            f"DataFrame '{df_name}' writes with write_single_file_from_spark helper.",
            part_label,
            "likely" if unresolved else "parsed",
        )
        if not target_row:
            continue
        if unresolved and not target_row.unresolved_variables:
            target_row.unresolved_variables = unresolved
            target_row.confidence = "likely"
        for source in df_sources.get(df_name, []):
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target_row.object_display_name,
                    source_dataframe=source.dataframe,
                    target_dataframe=df_name,
                    operation="write_single_file_from_spark",
                    confidence="likely" if source.confidence == "likely" or target_row.confidence == "likely" else "parsed",
                    evidence=f"DataFrame variable '{df_name}' links read sources to write_single_file_from_spark target.",
                    definition_path=part_label,
                )
            )

    for match in WRITE_REDUCTION_RE.finditer(parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        line_prefix = parse_code[parse_code.rfind("\n", 0, match.start()) + 1:match.start()]
        if re.search(r"\bdef\s+$", line_prefix):
            continue
        arg_text = match.group(1)
        args = split_top_level_args(arg_text)
        if len(args) < 2:
            continue
        df_name = args[0].strip()
        table = keyword_arg(arg_text, "table_name") or args[1]
        target, unresolved = combine_object_name("out_base", "", table, constants)
        target_row = add_object(
            result,
            item,
            "write",
            "write_reduction_table",
            target,
            constants,
            df_name,
            match.start(),
            parse_code,
            f"DataFrame '{df_name}' writes with write_reduction_table helper.",
            part_label,
            "likely" if unresolved else "parsed",
        )
        if not target_row:
            continue
        if unresolved and not target_row.unresolved_variables:
            target_row.unresolved_variables = unresolved
        for source in df_sources.get(df_name, []):
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target_row.object_display_name,
                    source_dataframe=source.dataframe,
                    target_dataframe=df_name,
                    operation="write_reduction_table",
                    confidence="likely",
                    evidence=f"DataFrame variable '{df_name}' links load_table source to write_reduction_table target.",
                    definition_path=part_label,
                )
            )

    for match in DELTA_MERGE_RE.finditer(parse_code):
        if is_ignored_context(parse_code, match.start()):
            continue
        function_name, arg_text = match.group(0).split("(", 1)[0].split(".")[-1], match.group(1)
        args = split_top_level_args(arg_text)
        source_df = keyword_arg(arg_text, "source_df")
        target_path = keyword_arg(arg_text, "target_path")
        table_name = keyword_arg(arg_text, "table_name")
        if not source_df and function_name == "delta_merge_upsert" and len(args) >= 2:
            source_df = args[1]
        if not target_path and function_name == "delta_merge_upsert" and len(args) >= 3:
            target_path = args[2]
        if not table_name and len(args) >= 5:
            table_name = args[4]
        source_df = source_df.strip()
        if source_df not in df_sources:
            continue
        target_value, target_unresolved = resolve_arg_value(target_path, constants) if target_path else ("", "")
        if (not target_value or re.search(r"[{}]", target_value)) and table_name:
            table_value, table_unresolved = resolve_arg_value(table_name, constants)
            if table_value:
                target_value = table_value
                target_unresolved = table_unresolved
        if not target_value:
            continue
        target_row = add_object(
            result,
            item,
            "write",
            function_name,
            target_value,
            constants,
            source_df,
            match.start(),
            parse_code,
            f"DataFrame '{source_df}' writes with {function_name}.",
            part_label,
            "likely" if target_unresolved else "parsed",
        )
        if not target_row:
            continue
        if target_unresolved and not target_row.unresolved_variables:
            target_row.unresolved_variables = target_unresolved
            target_row.confidence = "likely"
        for source in df_sources.get(source_df, []):
            result.flows.append(
                FlowRow(
                    notebook_key=stable_id(item["qualified_name"]),
                    workspace_name=item.get("workspace_name", ""),
                    workspace_environment=item.get("workspace_environment", ""),
                    notebook_name=item.get("item_name", ""),
                    item_qualified_name=item.get("qualified_name", ""),
                    source_object=source.object_display_name,
                    target_object=target_row.object_display_name,
                    source_dataframe=source.dataframe,
                    target_dataframe=source_df,
                    operation=function_name,
                    confidence="likely" if target_row.confidence == "likely" or source.confidence == "likely" else "parsed",
                    evidence=f"DataFrame variable '{source_df}' links read object to {function_name} target.",
                    definition_path=part_label,
                )
            )

    # SQL statements with both reads and writes can define direct flows.
    for sql, _offset, _evidence_type in extract_sql_strings(parse_code):
        resolved_sql, _sql_unresolved = resolve_template(sql, constants)
        sql_objects = extract_sql_objects(resolved_sql)
        writes = [identifier for usage, identifier, _verb in sql_objects if usage == "write"]
        reads = [identifier for usage, identifier, _verb in sql_objects if usage == "read"]
        for target in writes:
            target_identifier, target_unresolved = resolve_sql_object_identifier(target, constants, {})
            target_display = object_parts(resolve_template(target_identifier, constants)[0])["object_display_name"]
            for source in reads:
                temp_rows = temp_sources_for_identifier(source)
                if temp_rows:
                    source_candidates = [(row.object_display_name, row.confidence) for row in temp_rows]
                else:
                    source_identifier, source_unresolved = resolve_sql_object_identifier(source, constants, registered_view_sources)
                    source_candidates = [
                        (object_parts(resolve_template(source_identifier, constants)[0])["object_display_name"], "likely" if source_unresolved else "parsed")
                    ]
                for source_display, source_confidence in source_candidates:
                    if norm(source_display) in temp_view_sources:
                        continue
                    if not (source_display and target_display and source_display != target_display):
                        continue
                    result.flows.append(
                        FlowRow(
                            notebook_key=stable_id(item["qualified_name"]),
                            workspace_name=item.get("workspace_name", ""),
                            workspace_environment=item.get("workspace_environment", ""),
                            notebook_name=item.get("item_name", ""),
                            item_qualified_name=item.get("qualified_name", ""),
                            source_object=source_display,
                            target_object=target_display,
                            source_dataframe="",
                            target_dataframe="",
                            operation="sql_statement",
                            confidence="likely" if target_unresolved or source_confidence == "likely" else "parsed",
                            evidence="SQL statement contains write target and read sources.",
                            definition_path=part_label,
                        )
                    )

    if not code.strip():
        result.gaps.append({"gap_type": "empty_code", "notes": "Notebook part had no code text."})
    elif not result.objects:
        result.gaps.append({"gap_type": "no_objects_parsed", "notes": "Code downloaded but no read/write/execute object references matched current parser."})
    return result


def build_definition_map(manifest_rows: list[dict[str, str]], e1_rows: list[dict[str, str]]) -> dict[str, list[str]]:
    """Resolve each notebook item's local definition file path(s), preferring
    Phase 51's download manifest and falling back to the E1 manual-review
    queue's own recorded paths for anything the manifest missed. This is
    what lets main() turn "which notebooks exist" (index/items.csv) into
    "which local file do I actually parse for each one"."""
    paths_by_item: dict[str, list[str]] = defaultdict(list)
    for row in manifest_rows:
        if row.get("status") != "downloaded":
            continue
        for path in split_list(row.get("part_paths", "")):
            if path.endswith((".ipynb", ".py", ".scala", ".sql")) or Path(path).name.startswith("notebook-content"):
                paths_by_item[row.get("item_qualified_name", "")].append(path)
    for row in e1_rows:
        item = row.get("item_qualified_name", "")
        for path in split_list(row.get("local_definition_paths", "")):
            if path not in paths_by_item[item]:
                paths_by_item[item].append(path)
    return paths_by_item


def build_static_control_config_lookup(
    item_rows: list[dict[str, str]],
    paths_by_item: dict[str, list[str]],
) -> dict[tuple[str, str], dict[str, str]]:
    """Pre-scan every notebook that references the shared control.EntityConfig/
    EntityFieldConfig tables and index their entity->table mappings by
    (workspace_name, entity_name). parse_notebook_code() then looks a
    notebook's own `entity_cfg` constant up in this lookup so it can resolve
    "this notebook processes whatever entity its config says" into the
    actual table name that config points to, without re-scanning every other
    notebook each time."""
    lookup: dict[tuple[str, str], dict[str, str]] = {}
    for item in item_rows:
        if item.get("item_type") != "Notebook":
            continue
        workspace_name = item.get("workspace_name", "")
        for path_text in paths_by_item.get(item.get("qualified_name", ""), []):
            path = Path(path_text)
            if not path.exists():
                continue
            code, _markdown, _ = read_notebook_part(path)
            if "control.EntityConfig" not in code and "control.EntityFieldConfig" not in code:
                continue
            for sql, _offset, _evidence_type in extract_magic_sql_blocks(code):
                entity_rows, field_rows = extract_control_config_mappings(sql)
                for mapping in entity_rows + field_rows:
                    entity = mapping.get("entity", "")
                    if not entity:
                        continue
                    key = (workspace_name, entity.casefold())
                    current = lookup.get(key)
                    current_has_lakehouses = bool(current and current.get("source_lakehouse") and current.get("target_lakehouse"))
                    mapping_has_lakehouses = bool(mapping.get("source_lakehouse") and mapping.get("target_lakehouse"))
                    if current is None or (mapping_has_lakehouses and not current_has_lakehouses):
                        lookup[key] = mapping
    return lookup


def collect_static_control_config_runtime_vars(code: str) -> list[tuple[int, int, str]]:
    try:
        tree = ast.parse(clean_code_for_ast(code))
    except SyntaxError:
        return []
    entries: list[tuple[int, int, str]] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            template = template_from_ast(node.value) or ""
            call_name = ast_call_name(node.value.func) if isinstance(node.value, ast.Call) else ""
            dynamic_config_value = (
                "entity_cfg_row" in template
                or "field_cfg_rows" in template
                or call_name in {"get_src_dst_tables_from_rows"}
            )
            if not dynamic_config_value:
                continue
            for target in node.targets:
                if isinstance(target, ast.Name):
                    entries.append((0, len(code), target.id))
                elif isinstance(target, ast.Tuple):
                    for element in target.elts:
                        if isinstance(element, ast.Name):
                            entries.append((0, len(code), element.id))
    return entries



# %% [markdown]
# ## Sistema de ficheros virtual (VPath) -- ver nota al principio del fichero

# %%
class VPath:
    """Shim mínimo de pathlib.Path respaldado por un diccionario en
    memoria {ruta_virtual: texto} en vez del disco real -- implementa
    exactamente los métodos que el parser copiado arriba usa sobre un
    Path (.exists(), .read_text(), .name, .suffix, .parent, el operador
    /, igualdad/hash para poder vivir en un set()). Rebinding `Path =
    VPath` más abajo hace que TODO el código ya definido arriba (que
    referencia el nombre global `Path`, resuelto en tiempo de llamada,
    no de definición) empiece a usarlo sin que haga falta tocarlo."""

    def __init__(self, path_str):
        self._path = str(path_str)

    def __truediv__(self, other):
        return VPath(self._path.rstrip("/") + "/" + str(other))

    def __str__(self):
        return self._path

    def __repr__(self):
        return f"VPath({self._path!r})"

    def __eq__(self, other):
        return isinstance(other, VPath) and self._path == other._path

    def __hash__(self):
        return hash(self._path)

    @property
    def name(self):
        return self._path.rsplit("/", 1)[-1]

    @property
    def suffix(self):
        name = self.name
        return "." + name.rsplit(".", 1)[-1] if "." in name else ""

    @property
    def parent(self):
        if "/" not in self._path:
            return VPath("")
        return VPath(self._path.rsplit("/", 1)[0])

    def exists(self):
        if self._path in VIRTUAL_FS:
            return True
        prefix = self._path.rstrip("/") + "/"
        return any(p.startswith(prefix) for p in VIRTUAL_FS)

    def read_text(self, encoding="utf-8", errors="strict"):
        return VIRTUAL_FS[self._path]


Path = VPath


# %% [markdown]
# ## Ejecutar

# %%
NOTEBOOK_DEFINITION_COLUMNS = [
    "workspace_name", "item_name", "item_qualified_name", "technical_id",
    "part_path", "part_text", "status", "error", "downloaded_at",
]


def build_definition_map_from_bronze(definition_rows):
    """Reemplaza build_definition_map(manifest_rows, e1_rows) del
    original: misma forma de salida (qualified_name -> lista de rutas),
    pero las rutas son virtuales ("<workspace>/<item>.Notebook/<part>")
    respaldadas por VIRTUAL_FS en vez de rutas reales en disco resueltas
    desde un CSV manifiesto. No hay tabla bronze equivalente a la cola E1
    -- degrada a no usarla, igual que el original cuando el fichero falta."""
    paths_by_item = defaultdict(list)
    virtual_fs = {}
    for row in definition_rows:
        if row.get("status") != "downloaded":
            continue
        part_path = row.get("part_path", "") or ""
        if not (
            part_path.endswith((".ipynb", ".py", ".scala", ".sql"))
            or Path(part_path).name.startswith("notebook-content")
        ):
            continue
        full_path = f"{row.get('workspace_name', '')}/{row.get('item_name', '')}.Notebook/{part_path}"
        virtual_fs[full_path] = row.get("part_text", "") or ""
        paths_by_item[row.get("item_qualified_name", "")].append(full_path)
    return paths_by_item, virtual_fs


all_item_rows = read_table("bronze_items")
workspace_rows = read_table("bronze_workspaces")
fabric_context = build_fabric_context(all_item_rows, workspace_rows)
items = [row for row in all_item_rows if row.get("item_type") == "Notebook" and row.get("status") == "discovered"]

filter_set = {n.strip().lower() for n in re.split(r"[;,]", WorkspaceNameFilter or "") if n.strip()}
if filter_set:
    items = [row for row in items if (row.get("workspace_name") or "").strip().lower() in filter_set]

definition_rows = read_table("bronze_notebook_definitions")
paths_by_item, definition_map_fs = build_definition_map_from_bronze(definition_rows)
VIRTUAL_FS = definition_map_fs
static_control_config_lookup = build_static_control_config_lookup(all_item_rows, paths_by_item)

object_seen: set[tuple[str, ...]] = set()
flow_seen: set[tuple[str, ...]] = set()
object_rows: list[dict[str, str]] = []
flow_rows: list[dict[str, str]] = []
gap_rows: list[dict[str, str]] = []

for item in sorted(items, key=lambda r: (r.get("workspace_name", ""), r.get("item_name", ""))):
    qualified = item.get("qualified_name", "")
    paths = paths_by_item.get(qualified, [])
    if not paths:
        gap_rows.append(
            {
                "item_qualified_name": qualified,
                "workspace_name": item.get("workspace_name", ""),
                "item_name": item.get("item_name", ""),
                "gap_type": "definition_not_downloaded",
                "definition_paths": "",
                "notes": "No local notebook definition path found in download manifest or E1 queue.",
            }
        )
        continue
    item_objects_before = len(object_rows)
    for path_text in paths:
        path = Path(path_text)
        if not path.exists():
            gap_rows.append(
                {
                    "item_qualified_name": qualified,
                    "workspace_name": item.get("workspace_name", ""),
                    "item_name": item.get("item_name", ""),
                    "gap_type": "definition_path_missing",
                    "definition_paths": path_text,
                    "notes": "Manifest/E1 path does not exist on disk.",
                }
            )
            continue
        result = parse_notebook_code(item, path, str(path), fabric_context, static_control_config_lookup)
        for obj in result.objects:
            key = (
                obj.item_qualified_name,
                obj.direction,
                obj.operation,
                obj.object_display_name,
                obj.dataframe,
                obj.definition_path,
                obj.line_number,
            )
            if key in object_seen:
                continue
            object_seen.add(key)
            object_rows.append(obj.__dict__)
        for flow in result.flows:
            key = (
                flow.item_qualified_name,
                flow.source_object,
                flow.target_object,
                flow.source_dataframe,
                flow.target_dataframe,
                flow.operation,
                flow.definition_path,
            )
            if key in flow_seen:
                continue
            flow_seen.add(key)
            flow_rows.append(flow.__dict__)
        for gap in result.gaps:
            gap_rows.append(
                {
                    "item_qualified_name": qualified,
                    "workspace_name": item.get("workspace_name", ""),
                    "item_name": item.get("item_name", ""),
                    "gap_type": gap.get("gap_type", ""),
                    "definition_paths": str(path),
                    "notes": gap.get("notes", ""),
                }
            )
    if len(object_rows) == item_objects_before:
        pass

for row in object_rows:
    if re.match(r"^\{[A-Za-z0-9_]+\}/", row.get("object_display_name", "")):
        parts = object_parts(row["object_display_name"])
        row["source_type"] = parts["source_type"]
        row["source_database"] = parts["source_database"]
        row["schema_name"] = parts["schema_name"]
        row["object_name"] = parts["object_name"]
        row["object_display_name"] = parts["object_display_name"]

normalized_flow_rows: list[dict[str, str]] = []
normalized_flow_seen: set[tuple[str, ...]] = set()
flow_dedupe_fields = list(FlowRow.__dataclass_fields__.keys())
for row in flow_rows:
    normalized = dict(row)
    normalized["source_object"] = normalize_placeholder_display(normalized.get("source_object", ""))
    normalized["target_object"] = normalize_placeholder_display(normalized.get("target_object", ""))
    key = tuple(normalized.get(field, "") for field in flow_dedupe_fields)
    if key in normalized_flow_seen:
        continue
    normalized_flow_seen.add(key)
    normalized_flow_rows.append(normalized)
flow_rows = normalized_flow_rows

object_item_keys = {row["item_qualified_name"] for row in object_rows}
normalized_gap_rows: list[dict[str, str]] = []
gap_aggregate: dict[tuple[str, str, str, str, str], dict[str, str]] = {}
exact_gap_seen: set[tuple[str, str, str, str, str, str]] = set()
for gap in gap_rows:
    gap_type = gap.get("gap_type", "")
    item_name = gap.get("item_qualified_name", "")
    if gap_type in {"empty_code", "no_objects_parsed"} and item_name in object_item_keys:
        continue
    if gap_type in {"empty_code", "no_objects_parsed"}:
        key = (
            item_name,
            gap.get("workspace_name", ""),
            gap.get("item_name", ""),
            gap_type,
            gap.get("notes", ""),
        )
        current = gap_aggregate.get(key)
        if current is None:
            gap_aggregate[key] = {**gap}
            continue
        paths = split_list(current.get("definition_paths", ""))
        for path in split_list(gap.get("definition_paths", "")):
            if path not in paths:
                paths.append(path)
        current["definition_paths"] = "; ".join(paths)
        continue
    key = (
        item_name,
        gap.get("workspace_name", ""),
        gap.get("item_name", ""),
        gap_type,
        gap.get("definition_paths", ""),
        gap.get("notes", ""),
    )
    if key in exact_gap_seen:
        continue
    exact_gap_seen.add(key)
    normalized_gap_rows.append(gap)
normalized_gap_rows.extend(gap_aggregate.values())
gap_rows = sorted(normalized_gap_rows, key=lambda row: (row.get("workspace_name", ""), row.get("item_name", ""), row.get("gap_type", "")))

if filter_set:
    # Esta corrida solo re-parseó los workspaces de WorkspaceNameFilter --
    # funde con lo ya publicado en OneLake para el resto, igual que el
    # original fundía con sus 4 CSV (ver cabecera del fichero).
    previous_payload = read_onelake_json(OUTPUT_ONELAKE_PATH) or {}
    existing_objects = previous_payload.get("objects", [])
    existing_flows = previous_payload.get("flows", [])
    existing_gaps = previous_payload.get("gaps", [])
    retained_objects = [r for r in existing_objects if r.get("workspace_name") not in filter_set and (r.get("workspace_name") or "").strip().lower() not in filter_set]
    retained_flows = [r for r in existing_flows if (r.get("workspace_name") or "").strip().lower() not in filter_set]
    retained_gaps = [r for r in existing_gaps if (r.get("workspace_name") or "").strip().lower() not in filter_set]
    object_rows = retained_objects + object_rows
    flow_rows = retained_flows + flow_rows
    gap_rows = retained_gaps + gap_rows

object_items = {row["item_qualified_name"] for row in object_rows}
flow_items = {row["item_qualified_name"] for row in flow_rows}
direction_counts = Counter(row["direction"] for row in object_rows)
confidence_counts = Counter(row["confidence"] for row in object_rows)
gap_counts = Counter(row["gap_type"] for row in gap_rows)
summary_rows = [
    {"metric": "notebook_items", "value": str(len(items)), "notes": "Mapped notebooks in bronze_items."},
    {"metric": "notebooks_with_downloaded_definition", "value": str(len(paths_by_item)), "notes": "Notebooks with at least one downloaded definition."},
    {"metric": "notebooks_with_super_lineage_objects", "value": str(len(object_items)), "notes": "Notebooks with parsed read/write/execute object rows."},
    {"metric": "notebooks_with_source_to_target_flows", "value": str(len(flow_items)), "notes": "Notebooks with inferred source->target mappings."},
    {"metric": "super_lineage_object_rows", "value": str(len(object_rows)), "notes": "Object rows in the final payload."},
    {"metric": "super_lineage_flow_rows", "value": str(len(flow_rows)), "notes": "Flow rows in the final payload."},
]
for key, value in direction_counts.most_common():
    summary_rows.append({"metric": f"direction_{key}", "value": str(value), "notes": "Object-row direction split."})
for key, value in confidence_counts.most_common():
    summary_rows.append({"metric": f"confidence_{key}", "value": str(value), "notes": "Object-row confidence split."})
for key, value in gap_counts.most_common():
    summary_rows.append({"metric": f"gap_{key}", "value": str(value), "notes": "Notebook super-lineage gap split."})

json_payload = {
    "schema_version": "notebook-super-lineage.v1",
    "summary": {row["metric"]: row["value"] for row in summary_rows},
    "objects": object_rows,
    "flows": flow_rows,
    "gaps": gap_rows,
}
write_json_onelake(OUTPUT_ONELAKE_PATH, json_payload)

print("Notebook super lineage built.")
print(f"Notebooks: {len(items)}")
print(f"Object rows: {len(object_rows)}")
print(f"Flow rows: {len(flow_rows)}")
print(f"Gaps: {len(gap_rows)}")
print(f"Output: {OUTPUT_ONELAKE_PATH}")
