"""Multi-tenant installer (Fase 5, 2026-08-24): the admin panel's
"Instalar en otro tenant" wizard walks an admin through provisioning a
fresh copy of this project's Fabric-side assets (workspace, Lakehouse/
Warehouse, every fabric_notebooks/NB_*.py) into ANY tenant they have a
service principal for.

Built on the `fab` CLI, not raw REST calls -- this is the SAME mechanism
already used and trusted this project for pushing live notebook edits
(see docs/109_column_security_discovery.md's own history: `fab export`/
`fab import`, verified byte-identical on re-export). There is no second
tenant available this session to test raw REST workspace/item-creation
calls against, so reusing the CLI (which already handles auth, retries,
and the exact item-definition wire format) is the lower-risk choice.

Every `fab` call here runs with an ISOLATED HOME/USERPROFILE (see
_isolated_fab_env) pointed at a fresh temp directory -- `fab auth login`
writes its session to a fixed per-user config dir
(~/.config/fab/auth.json), so without this isolation, authenticating as
the TARGET tenant's service principal here would silently replace
whatever interactive fab/az session the machine's own operator has open
for THEIR OWN (usually different) tenant. Verified empirically
2026-08-24: overriding HOME makes a fresh `fab auth status` report a
separate, un-authenticated state instead of the real session's.

Pipeline/activity wiring is deliberately NOT automated here -- this
project's own docs/105_fabric_native_discovery_setup.md still treats that
as a manual, UI-driven step (no
pipeline-content.json template exists anywhere in this project to build
from, and a generated one has never been tested against a second
tenant). The install flow provisions workspace + Lakehouse/Warehouse
+ every notebook (with tenant-specific variables substituted), then hands
back the exact manual pipeline-activity order docs/105 already documents
-- see MANUAL_PIPELINE_STEP below.
"""
import json
import os
import re
import shutil
import subprocess
import tempfile

from .paths import FABRIC_NOTEBOOKS_DIR, REPO_ROOT
from .utils import _now_iso

# The 12 core discovery/build notebooks, in the exact pipeline dependency
# order docs/105_fabric_native_discovery_setup.md's own table documents
# (column "Depende de"). Kept as a flat ordered list (not the dependency
# graph itself) because that's all the install/deploy step needs -- the
# graph is only shown back to the admin as the manual pipeline-wiring
# instructions at the end, verbatim from that doc.
CORE_NOTEBOOK_ORDER = [
    "NB_Discover_Workspaces_Items",
    "NB_Discover_Dependencies",
    "NB_Discover_Object_Lineage",
    "NB_Discover_Semantic_Model_Lineage",
    "NB_Confirm_Source_Object_Types",
    "NB_Discover_Pipeline_Object_Lineage",
    "NB_Download_Notebook_Definitions",
    "NB_Discover_Executions",
    "NB_Build_Lineage_Explorer",
    "NB_Build_Object_Impact",
    "NB_Build_Graph_Map",
    "NB_Build_Notebook_Super_Lineage",
]

# Every other fabric_notebooks/NB_*.py this project ships beyond the core
# 12 (Fase A SQL-endpoint-catalog work, the Bronze/Silver/Gold Lakehouse
# bypass, hardening/backfill helpers) -- optional, deployed if present,
# with no fixed pipeline position asserted here (each has its own header
# comment explaining where it slots into a real run).
EXTRA_NOTEBOOKS = [
    "NB_Discover_Fabric_Connections",
    "NB_Extract_SQL_Endpoint_Catalog",
    "NB_Extract_Object_Column_Catalog",
    "NB_Discover_Column_Profile",
    "NB_Discover_Column_Sensitivity",
    "NB_Extract_Control_Framework_Lineage",
    "NB_Harden_Object_Lineage_Candidates",
    "NB_Backfill_Object_Source_Targets",
    "NB_Bronze_Silver_Gold_Build",
]

# Verbatim from docs/105_fabric_native_discovery_setup.md's own "orden de
# dependencia" table -- shown to the admin as the manual next step once
# the install finishes, since pipeline-activity wiring isn't automated
# (see this module's own docstring for why).
MANUAL_PIPELINE_STEP = {
    "es": (
        "El asistente no crea el Data Pipeline -- ni este proyecto ni esta sesión tienen un segundo tenant "
        "donde probar un pipeline-content.json generado a ciegas, y este mismo proyecto documenta ese paso "
        "como manual incluso para su propio tenant (ver docs/105_fabric_native_discovery_setup.md). Crea un "
        "Data Pipeline nuevo en el workspace de arriba y añade una actividad Notebook por cada notebook "
        "desplegado, con estas dependencias (ejecuta la siguiente solo si la anterior tiene éxito):"
    ),
    "en": (
        "The wizard does not create the Data Pipeline -- neither this project nor this session has a second "
        "tenant to test a blindly-generated pipeline-content.json against, and this project documents that "
        "step as manual even for its own tenant (see docs/105_fabric_native_discovery_setup.md). Create a new "
        "Data Pipeline in the workspace above and add one Notebook activity per deployed notebook, with these "
        "dependencies (run the next one only if the previous succeeded):"
    ),
}

# Tenant-specific config values found as plain top-level assignments
# across fabric_notebooks/NB_*.py (confirmed 2026-08-24 by grepping every
# notebook: 12 of them already carry placeholder values like "<tu-
# workspace>"/"<tenant-id>", the other 8 carry this project's own live
# values -- these names were clearly already designed for exactly this
# kind of per-tenant substitution). SP_SECRET_ONELAKE_PATH and
# FABRIC_API_BASE_URL are deliberately excluded: both are constant across
# every notebook regardless of tenant (a fixed relative Files/ path
# convention and Fabric's global API host), not something to prompt for.
TENANT_VARIABLE_NAMES = [
    "SP_TENANT_ID",
    "SP_CLIENT_ID",
    "ONELAKE_WORKSPACE_NAME",
    "ONELAKE_LAKEHOUSE_NAME",
    "WAREHOUSE_SQL_ENDPOINT",
    "WAREHOUSE_DATABASE_NAME",
    "AKV_ENDPOINT",
]

_VARIABLE_LINE_RE = re.compile(r'^(?P<indent>\s*)(?P<name>[A-Z][A-Z0-9_]*)(?P<eq>\s*=\s*)"(?P<value>[^"]*)"(?P<trail>\s*)$')


def available_notebooks():
    """{name: source_text} for every fabric_notebooks/NB_*.py that
    actually exists on disk, in CORE_NOTEBOOK_ORDER + EXTRA_NOTEBOOKS
    order -- a notebook listed above but missing from disk (shouldn't
    happen, but this project's own file set can grow) is silently
    skipped rather than raising, same "degrade, don't crash a wizard
    step" reasoning as the rest of this module."""
    result = {}
    for name in CORE_NOTEBOOK_ORDER + EXTRA_NOTEBOOKS:
        path = FABRIC_NOTEBOOKS_DIR / f"{name}.py"
        if path.exists():
            result[name] = path.read_text(encoding="utf-8")
    return result


def scan_tenant_variables():
    """{variable_name: {"notebook_count": N, "example_value": str}} for
    each name in TENANT_VARIABLE_NAMES actually found in at least one
    notebook -- feeds the wizard's "Notebooks y variables" step so an
    admin sees a real example value (the current one, or the "<...>"
    placeholder already templated in) before deciding what to type for
    the new tenant, instead of guessing variable names blind."""
    notebooks = available_notebooks()
    found = {}
    for name, source in notebooks.items():
        for line in source.splitlines():
            match = _VARIABLE_LINE_RE.match(line)
            if not match or match.group("name") not in TENANT_VARIABLE_NAMES:
                continue
            entry = found.setdefault(match.group("name"), {"notebook_count": 0, "example_value": match.group("value")})
            entry["notebook_count"] += 1
    return found


def _apply_variable_overrides(py_source, overrides):
    """overrides: {name: new_value}. Replaces the quoted RHS of every
    top-level NAME = "..." assignment whose NAME is a key in overrides,
    line by line -- everything else (comments, other variables, cell
    markers) passes through byte-for-byte. A name in `overrides` that
    never appears in this particular notebook is simply a no-op for it
    (not every notebook uses every tenant variable, see
    scan_tenant_variables' own per-name notebook_count)."""
    if not overrides:
        return py_source
    lines = py_source.splitlines(keepends=True)
    out = []
    for line in lines:
        stripped_line = line[:-1] if line.endswith("\n") else line
        match = _VARIABLE_LINE_RE.match(stripped_line)
        if match and match.group("name") in overrides:
            newline = "\n" if line.endswith("\n") else ""
            out.append(f'{match.group("indent")}{match.group("name")}{match.group("eq")}"{overrides[match.group("name")]}"{match.group("trail")}{newline}')
        else:
            out.append(line)
    return "".join(out)


def _py_source_to_notebook_cells(py_source):
    """Splits on '# %%' markers -- this project's own convention (every
    fabric_notebooks/NB_*.py's header says so verbatim: 'Cada bloque
    "# %%" es una celda'), the same percent-format VS Code/Jupytext/
    Spyder already use. '# %% [markdown]' starts a markdown cell (content
    = each following line with one leading '# ' or bare '#' stripped);
    anything else starting with '# %%' is a code cell (content kept
    byte-for-byte, marker line itself dropped). Content before the first
    '# %%' marker (every notebook's opening comment block) becomes its
    own leading markdown cell, same treatment.

    Verified 2026-08-24 against a REAL fab-exported notebook-content.ipynb
    from this project's own live tenant: nbformat 4/5, cells shaped
    [{"cell_type", "metadata", "source": [...]}], metadata.language_info.
    name == "python" -- this is standard Jupyter nbformat, not a
    project-specific dialect, so no bespoke Fabric-only cell shape is
    invented here."""
    lines = py_source.splitlines()
    chunks = []
    current = []
    current_is_markdown = False
    started = False
    for line in lines:
        if line.startswith("# %%"):
            if started:
                chunks.append((current_is_markdown, current))
            current = []
            current_is_markdown = line.startswith("# %% [markdown]")
            started = True
            continue
        current.append(line)
    if started:
        chunks.append((current_is_markdown, current))
    elif current:
        chunks.append((False, current))

    # Leading content before any "# %%" marker (the file's opening
    # comment block) is its own markdown cell -- every notebook has one.
    if not started:
        pass  # handled by the elif above (whole file, no markers at all)
    else:
        leading = []
        for line in lines:
            if line.startswith("# %%"):
                break
            leading.append(line)
        if any(line.strip() for line in leading):
            chunks.insert(0, (True, leading))

    cells = []
    for is_markdown, body_lines in chunks:
        if is_markdown:
            stripped = []
            for line in body_lines:
                if line.startswith("# "):
                    stripped.append(line[2:])
                elif line == "#":
                    stripped.append("")
                else:
                    stripped.append(line)
            source_text = "\n".join(stripped).strip("\n")
            cells.append({"cell_type": "markdown", "metadata": None, "source": _split_source_lines(source_text)})
        else:
            source_text = "\n".join(body_lines).strip("\n")
            if not source_text:
                continue
            cells.append({"cell_type": "code", "metadata": {}, "source": _split_source_lines(source_text), "outputs": [], "execution_count": None})
    return cells


def _split_source_lines(text):
    """nbformat's own convention: `source` is a list of lines, every line
    except the last keeping its trailing '\\n' -- matches what a real
    fab-exported notebook-content.ipynb contains (verified 2026-08-24)."""
    if not text:
        return []
    parts = text.split("\n")
    return [f"{part}\n" for part in parts[:-1]] + [parts[-1]]


def notebook_content_json(py_source):
    cells = _py_source_to_notebook_cells(py_source)
    return json.dumps({
        "nbformat": 4,
        "nbformat_minor": 5,
        "metadata": {"language_info": {"name": "python"}},
        "cells": cells,
    }, indent=1)


def platform_json(display_name, item_type="Notebook"):
    return json.dumps({
        "$schema": "https://developer.microsoft.com/json-schemas/fabric/gitIntegration/platformProperties/2.0.0/schema.json",
        "metadata": {"type": item_type, "displayName": display_name},
        "config": {"version": "2.0", "logicalId": "00000000-0000-0000-0000-000000000000"},
    }, indent=4)


def _isolated_fab_env(config):
    """A fresh, throwaway HOME/USERPROFILE so fab's SPN auth for the
    TARGET tenant's service principal never touches (or gets silently
    replaced by) whatever interactive fab/az session the machine's own
    operator has open for their own tenant -- fab keeps its session at a
    fixed per-user path (~/.config/fab/auth.json). Verified empirically
    2026-08-24: overriding HOME/USERPROFILE gives `fab auth status` a
    fresh, separate "not logged in" state instead of the real one.

    The SPN credentials themselves go in as FAB_TENANT_ID/FAB_SPN_CLIENT_
    ID/FAB_SPN_CLIENT_SECRET env vars -- fab's own FabAuth._load_env()
    reads these automatically the moment any `fab` subcommand starts, so
    no explicit `fab auth login -u ... -p <secret> --tenant ...` call is
    needed at all (2026-08-26 security audit: that `-p` put the client
    secret directly in this subprocess's argv, visible to anything that
    can list processes on the machine -- Task Manager, `wmic process`,
    `ps`. Env vars aren't visible that way). See _fab_auth_check below for
    how the caller verifies these actually work, since fab no longer gets
    an explicit login call to fail loudly.

    Returns (env, home_dir) -- caller must shutil.rmtree(home_dir) when
    the install run ends, success or failure."""
    home_dir = tempfile.mkdtemp(prefix="fab_install_")
    env = dict(os.environ)
    env["HOME"] = home_dir
    env["USERPROFILE"] = home_dir
    env["FAB_TENANT_ID"] = config["tenant_id"]
    env["FAB_SPN_CLIENT_ID"] = config["client_id"]
    env["FAB_SPN_CLIENT_SECRET"] = config["client_secret"]
    return env, home_dir


def _fab_auth_check(env):
    """Confirms the FAB_SPN_* env vars _isolated_fab_env set actually
    authenticate, replacing the old explicit `fab auth login` call. `fab
    auth status --output_format json` mints a real token non-interactively
    under the hood (FabAuth.get_access_token(..., interactive_renew=
    False)) but, unlike `auth login`, always exits 0 whether or not that
    succeeded -- success has to be read from its own `logged_in` JSON
    field, not the process exit code."""
    ok, output = _fab(["auth", "status", "--output_format", "json"], env)
    if not ok:
        return False, output
    try:
        data = json.loads(output)
    except json.JSONDecodeError:
        return False, "Unexpected output from 'fab auth status'."
    if not data.get("logged_in"):
        return False, "Service principal authentication failed -- check the tenant id, client id, and secret."
    return True, f"Authenticated as app {data.get('app_id', '?')}."


def _fab(args, env, timeout=120):
    """Returns (ok, output_or_error). Never raises -- a wizard step must
    always be able to report a clean failure message, same reasoning as
    every other subprocess wrapper in this package (external_sources.py,
    fabric_pipeline.py)."""
    try:
        result = subprocess.run(
            ["fab"] + args, capture_output=True, text=True, timeout=timeout, env=env, cwd=str(REPO_ROOT),
        )
    except FileNotFoundError:
        return False, "The 'fab' (Fabric CLI) command was not found on PATH."
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, f"Could not run 'fab {' '.join(args)}': {exc}"
    if result.returncode != 0:
        return False, (result.stderr or result.stdout or "Unknown fab error.").strip()
    return True, result.stdout.strip()


def create_workspace_and_item(config, on_step):
    """Standalone "dar de alta" popup support (Fase 5): creates a
    workspace and, inside it, one Lakehouse or Warehouse -- the SAME
    fab mkdir/assign mechanism run_install uses for its own workspace/
    storage steps, just callable on its own for the "Escaneo en Fabric"
    and "Datos del explorador (OneLake)" tabs' own "+ Nuevo workspace"
    popups. Those don't need the rest of the installer (no notebooks, no
    cross-tenant service principal) -- they reuse whatever service
    principal that admin-panel section already has configured, to
    provision a workspace/Lakehouse in the SAME tenant this server
    already targets. config: {tenant_id, client_id, client_secret,
    workspace_name, capacity_name, item_type ("Lakehouse"|"Warehouse"),
    item_name}."""
    env, home_dir = _isolated_fab_env(config)
    try:
        ok, detail = _fab_auth_check(env)
        on_step("auth", detail if ok else f"No se pudo autenticar: {detail}", ok)
        if not ok:
            return

        workspace_path = f'{config["workspace_name"]}.Workspace'
        exists_ok, _ = _fab(["exists", workspace_path], env)
        if not exists_ok:
            ok, detail = _fab(["mkdir", workspace_path], env)
            on_step("workspace", detail if ok else f"No se pudo crear el workspace: {detail}", ok)
            if not ok:
                return
        else:
            on_step("workspace", f"El workspace '{config['workspace_name']}' ya existía -- reutilizado.", True)

        if config.get("capacity_name"):
            ok, detail = _fab(["assign", f'.capacities/{config["capacity_name"]}.Capacity', "-W", workspace_path, "-f"], env)
            on_step("capacity", detail if ok else f"No se pudo asignar la capacidad: {detail}", ok)
            if not ok:
                return

        if config.get("item_name"):
            item_type = config.get("item_type") or "Lakehouse"
            item_path = f'{workspace_path}/{config["item_name"]}.{item_type}'
            exists_ok, _ = _fab(["exists", item_path], env)
            if not exists_ok:
                ok, detail = _fab(["mkdir", item_path], env)
                on_step("item", detail if ok else f"No se pudo crear {item_type} '{config['item_name']}': {detail}", ok)
                if not ok:
                    return
            else:
                on_step("item", f"{item_type} '{config['item_name']}' ya existía -- reutilizado.", True)

        on_step("done", "Alta completada.", True)
    except Exception as exc:  # noqa: BLE001 - same "always end the run cleanly" reasoning as run_install
        on_step("error", f"Error inesperado: {exc}", False)
    finally:
        shutil.rmtree(home_dir, ignore_errors=True)


def run_install(config, on_step):
    """config: {tenant_id, client_id, client_secret, workspace_name,
    capacity_name, lakehouse_name, warehouse_name, item_type
    ("Lakehouse"|"Warehouse", which one is the write-storage target),
    variable_overrides: {name: value}, notebook_names: [str, ...] (which
    of available_notebooks() to deploy -- lets an admin skip the optional
    EXTRA_NOTEBOOKS)}.

    on_step(step_key, message, ok) is called after every step, in order,
    so the caller (handler.py's background thread) can update the
    pollable install-progress state the same way scan_manager.py already
    does for scans. Runs everything against an ISOLATED fab session (see
    _isolated_fab_env) and always tears it down in a finally block, even
    on an unhandled exception -- an install must never leave the target
    tenant's service-principal session sitting in a temp directory, and
    must never leave the OPERATOR's own fab session touched at all."""
    env, home_dir = _isolated_fab_env(config)
    try:
        ok, detail = _fab_auth_check(env)
        on_step("auth", detail if ok else f"No se pudo autenticar: {detail}", ok)
        if not ok:
            return

        workspace_path = f'{config["workspace_name"]}.Workspace'
        exists_ok, _ = _fab(["exists", workspace_path], env)
        if not exists_ok:
            ok, detail = _fab(["mkdir", workspace_path], env)
            on_step("workspace", detail if ok else f"No se pudo crear el workspace: {detail}", ok)
            if not ok:
                return
        else:
            on_step("workspace", f"El workspace '{config['workspace_name']}' ya existía -- reutilizado.", True)
        if config.get("capacity_name"):
            ok, detail = _fab(["assign", f'.capacities/{config["capacity_name"]}.Capacity', "-W", workspace_path, "-f"], env)
            on_step("capacity", detail if ok else f"No se pudo asignar la capacidad: {detail}", ok)
            if not ok:
                return

        storage_item_type = config.get("item_type") or "Warehouse"
        storage_name = config["warehouse_name"] if storage_item_type == "Warehouse" else config["lakehouse_name"]
        storage_path = f"{workspace_path}/{storage_name}.{storage_item_type}"
        overrides = dict(config.get("variable_overrides") or {})
        exists_ok, _ = _fab(["exists", storage_path], env)
        if not exists_ok:
            ok, detail = _fab(["mkdir", storage_path], env)
            on_step("storage", detail if ok else f"No se pudo crear {storage_item_type} '{storage_name}': {detail}", ok)
            if not ok:
                return
            # The SQL analytics endpoint hostname only exists once Fabric
            # has actually provisioned the item -- can't be known ahead of
            # time, so the wizard can't pre-fill it (see app.js's own
            # renderInstallerStepNotebooks comment). Only Warehouse's
            # connectionString is a flat property (Lakehouse nests it
            # under sqlEndpointProperties instead, see fabric_api.py's own
            # comment on that same asymmetry) -- Lakehouse-as-storage still
            # needs this filled in by hand.
            if storage_item_type == "Warehouse":
                endpoint_ok, endpoint_detail = _fab(["get", storage_path, "-q", "properties.connectionString"], env)
                if endpoint_ok and endpoint_detail:
                    overrides.setdefault("WAREHOUSE_SQL_ENDPOINT", endpoint_detail.strip().strip('"'))
                    overrides.setdefault("WAREHOUSE_DATABASE_NAME", storage_name)
                    on_step("storage_endpoint", f"SQL endpoint resuelto automáticamente: {overrides['WAREHOUSE_SQL_ENDPOINT']}", True)
                else:
                    on_step("storage_endpoint", "No se pudo resolver el SQL endpoint automáticamente -- revisa WAREHOUSE_SQL_ENDPOINT a mano.", False)
        else:
            on_step("storage", f"{storage_item_type} '{storage_name}' ya existía -- reutilizado.", True)

        if config.get("lakehouse_name") and storage_item_type != "Lakehouse":
            lakehouse_path = f'{workspace_path}/{config["lakehouse_name"]}.Lakehouse'
            exists_ok, _ = _fab(["exists", lakehouse_path], env)
            if not exists_ok:
                ok, detail = _fab(["mkdir", lakehouse_path], env)
                on_step("onelake_lakehouse", detail if ok else f"No se pudo crear el Lakehouse de OneLake '{config['lakehouse_name']}': {detail}", ok)
                if not ok:
                    return
            else:
                on_step("onelake_lakehouse", f"Lakehouse '{config['lakehouse_name']}' ya existía -- reutilizado.", True)

        notebooks = available_notebooks()
        requested = config.get("notebook_names") or list(notebooks.keys())
        deployed, failed = 0, 0
        for name in requested:
            source = notebooks.get(name)
            if source is None:
                on_step("notebooks", f"{name}: no encontrado en fabric_notebooks/, omitido.", False)
                failed += 1
                continue
            patched_source = _apply_variable_overrides(source, overrides)
            item_dir = os.path.join(home_dir, f"{name}.Notebook")
            os.makedirs(item_dir, exist_ok=True)
            with open(os.path.join(item_dir, ".platform"), "w", encoding="utf-8") as handle:
                handle.write(platform_json(name))
            with open(os.path.join(item_dir, "notebook-content.ipynb"), "w", encoding="utf-8") as handle:
                handle.write(notebook_content_json(patched_source))
            ok, detail = _fab(["import", f"{workspace_path}/{name}.Notebook", "-i", item_dir, "-f"], env, timeout=180)
            on_step("notebooks", f"{name}: {'desplegado' if ok else 'FALLO - ' + detail}", ok)
            if ok:
                deployed += 1
            else:
                failed += 1
        on_step(
            "notebooks_summary",
            f"{deployed} notebook(s) desplegados, {failed} fallido(s) de {len(requested)} solicitados.",
            failed == 0,
        )
        on_step("done", "Instalación completada. Falta el paso manual del Data Pipeline (ver instrucciones).", True)
    except Exception as exc:  # noqa: BLE001 - a background install thread must always end the run cleanly, never crash silently mid-progress
        on_step("error", f"Error inesperado durante la instalación: {exc}", False)
    finally:
        shutil.rmtree(home_dir, ignore_errors=True)
