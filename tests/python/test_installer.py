"""Unit tests for the pure-logic pieces of backend/scripts/lineage_web/
installer.py (the multi-tenant installer wizard).
Everything that shells out to the real `fab` CLI (run_install, _fab,
_isolated_fab_env) is NOT covered here -- there is no second Fabric tenant
this project can test workspace/notebook creation against, see the
module's own docstring. This file covers what IS fully deterministic and
testable offline: variable substitution and the .py -> nbformat cell
conversion, both verified against real fabric_notebooks/ source and a
real fab-exported notebook-content.ipynb.
"""
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web import installer  # noqa: E402


def test_apply_variable_overrides_replaces_matching_names_only():
    source = (
        'SP_TENANT_ID = "<tenant-id>"\n'
        'SP_CLIENT_ID = "<client-id>"\n'
        'UNRELATED_NAME = "keep-me"\n'
    )
    patched = installer._apply_variable_overrides(source, {"SP_TENANT_ID": "new-tenant-guid"})
    assert 'SP_TENANT_ID = "new-tenant-guid"' in patched
    assert 'SP_CLIENT_ID = "<client-id>"' in patched  # untouched, not in overrides
    assert 'UNRELATED_NAME = "keep-me"' in patched  # untouched, not a known variable name


def test_apply_variable_overrides_preserves_indentation_and_trailing_content():
    source = '    WAREHOUSE_DATABASE_NAME = "old"  \n'
    patched = installer._apply_variable_overrides(source, {"WAREHOUSE_DATABASE_NAME": "new"})
    assert patched == '    WAREHOUSE_DATABASE_NAME = "new"  \n'


def test_apply_variable_overrides_no_op_when_empty():
    source = 'SP_TENANT_ID = "abc"\n'
    assert installer._apply_variable_overrides(source, {}) == source


def test_apply_variable_overrides_leaves_non_matching_line_shape_alone():
    # Not a simple `NAME = "value"` line (a dict/expression) -- must not be touched.
    source = 'SP_TENANT_ID = get_tenant_id()\n'
    patched = installer._apply_variable_overrides(source, {"SP_TENANT_ID": "should-not-apply"})
    assert patched == source


def test_py_source_to_cells_splits_on_percent_markers():
    source = (
        "# Header comment\n"
        "# more header\n"
        "\n"
        "# %% [markdown]\n"
        "# ## Configuracion\n"
        "# some text\n"
        "\n"
        "# %%\n"
        "import msal\n"
        "TENANT = 1\n"
    )
    cells = installer._py_source_to_notebook_cells(source)
    assert len(cells) == 3
    assert cells[0]["cell_type"] == "markdown"
    assert "Header comment" in "".join(cells[0]["source"])
    assert cells[1]["cell_type"] == "markdown"
    assert "## Configuracion" in "".join(cells[1]["source"])
    assert cells[2]["cell_type"] == "code"
    assert "import msal" in "".join(cells[2]["source"])
    assert "TENANT = 1" in "".join(cells[2]["source"])


def test_py_source_to_cells_drops_empty_code_cells():
    source = "# %%\n\n\n# %%\nreal_code = 1\n"
    cells = installer._py_source_to_notebook_cells(source)
    code_cells = [c for c in cells if c["cell_type"] == "code"]
    assert len(code_cells) == 1
    assert "real_code = 1" in "".join(code_cells[0]["source"])


def test_notebook_content_json_is_valid_nbformat():
    source = "# %%\nx = 1\n"
    payload = json.loads(installer.notebook_content_json(source))
    assert payload["nbformat"] == 4
    assert payload["metadata"]["language_info"]["name"] == "python"
    assert payload["cells"][0]["cell_type"] == "code"
    assert payload["cells"][0]["source"] == ["x = 1"]


def test_platform_json_has_display_name_and_type():
    payload = json.loads(installer.platform_json("NB_Example", item_type="Notebook"))
    assert payload["metadata"]["displayName"] == "NB_Example"
    assert payload["metadata"]["type"] == "Notebook"


def test_available_notebooks_reads_real_fabric_notebooks_dir():
    notebooks = installer.available_notebooks()
    # At minimum, the core discovery notebooks this project ships must be found.
    assert "NB_Discover_Workspaces_Items" in notebooks
    assert "NB_Discover_Dependencies" in notebooks
    assert notebooks["NB_Discover_Workspaces_Items"].strip()


def test_scan_tenant_variables_finds_known_names_with_examples():
    found = installer.scan_tenant_variables()
    assert "SP_TENANT_ID" in found
    assert found["SP_TENANT_ID"]["notebook_count"] > 0
    assert found["SP_TENANT_ID"]["example_value"]


def test_scan_tenant_variables_every_real_notebook_converts_without_error():
    # Real end-to-end smoke: every fabric_notebooks/NB_*.py this project
    # ships must convert to valid nbformat JSON without raising -- catches
    # a "# %%"-adjacent edge case none of the synthetic tests above cover.
    for name, source in installer.available_notebooks().items():
        payload = json.loads(installer.notebook_content_json(source))
        assert payload["cells"], f"{name} produced zero cells"
