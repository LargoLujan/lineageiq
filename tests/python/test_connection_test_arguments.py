"""Argument checks of the admin connection tests in
backend/scripts/lineage_web/external_sources.py: values entered in the admin
panel go to pwsh as named-parameter arguments, so a value that starts with
'-' or contains a line break, and a secret reference that is not a plain
environment variable name, are refused before any process is started.
"""
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web.external_sources import _test_external_source, _test_lakehouse_connection  # noqa: E402

NEWLINE = chr(10)


def _run_ok(*args, **kwargs):
    return SimpleNamespace(stdout='{"ok": true, "message": "Connected."}', stderr="")


@patch("lineage_web.external_sources.subprocess.run")
@patch("lineage_web.external_sources._resolve_pwsh_command", return_value="pwsh")
@patch("lineage_web.external_sources._load_admin_settings", return_value={})
def test_a_host_that_starts_with_a_dash_is_refused_before_running_anything(mock_load, mock_pwsh, mock_run):
    result = _test_external_source({"type": "sql_server", "host": "-Command", "password_ref": "SQL_PASSWORD"})
    assert result["ok"] is False
    assert "'host'" in result["message"]
    mock_run.assert_not_called()


@patch("lineage_web.external_sources.subprocess.run")
@patch("lineage_web.external_sources._resolve_pwsh_command", return_value="pwsh")
@patch("lineage_web.external_sources._load_admin_settings", return_value={})
def test_a_database_with_a_line_break_is_refused(mock_load, mock_pwsh, mock_run):
    result = _test_external_source({"type": "sql_server", "host": "sql01", "database": "sales" + NEWLINE + "x"})
    assert result["ok"] is False
    assert "'database'" in result["message"]
    mock_run.assert_not_called()


@patch("lineage_web.external_sources.subprocess.run")
@patch("lineage_web.external_sources._resolve_pwsh_command", return_value="pwsh")
@patch("lineage_web.external_sources._load_admin_settings", return_value={})
def test_a_password_reference_must_be_an_environment_variable_name(mock_load, mock_pwsh, mock_run):
    for bad in ("SQL-PASSWORD", "$(whoami)", "1PASSWORD", "PASS WORD"):
        result = _test_external_source({"type": "sql_server", "host": "sql01", "password_ref": bad})
        assert result["ok"] is False, bad
        assert "'password_ref'" in result["message"]
    mock_run.assert_not_called()


@patch("lineage_web.external_sources._test_subprocess_env", return_value=None)
@patch("lineage_web.external_sources.subprocess.run", side_effect=_run_ok)
@patch("lineage_web.external_sources._resolve_pwsh_command", return_value="pwsh")
@patch("lineage_web.external_sources._load_admin_settings", return_value={})
def test_valid_values_reach_the_script_unchanged(mock_load, mock_pwsh, mock_run, mock_env):
    source = {
        "type": "postgresql", "host": "pg.contoso.com", "auth_mode": "sql_auth", "user": "reader",
        "password_ref": "CONTOSO_PG_PASSWORD", "port": 5432, "database": "sales",
    }
    result = _test_external_source(source)
    assert result == {"ok": True, "message": "Connected."}
    args = mock_run.call_args[0][0]
    assert args[:3] == ["pwsh", "-NoLogo", "-File"]
    for flag, value in (("-EngineType", "postgresql"), ("-SourceHost", "pg.contoso.com"), ("-User", "reader"),
                        ("-PasswordEnvVar", "CONTOSO_PG_PASSWORD"), ("-Port", "5432"), ("-Database", "sales")):
        assert args[args.index(flag) + 1] == value
    assert "-TrustServerCertificate" in args


@patch("lineage_web.external_sources.subprocess.run")
@patch("lineage_web.external_sources._resolve_pwsh_command", return_value="pwsh")
def test_a_lakehouse_secret_reference_must_be_an_environment_variable_name(mock_pwsh, mock_run):
    lakehouse = {
        "sql_endpoint_connection_string": "contoso.datawarehouse.fabric.microsoft.com",
        "lakehouse_name": "lh_contoso",
        "auth_mode": "service_principal",
        "sp_tenant_id": "00000000-0000-0000-0000-000000000000",
        "sp_client_id": "11111111-1111-1111-1111-111111111111",
        "sp_client_secret_ref": "SECRET;rm",
    }
    result = _test_lakehouse_connection(lakehouse)
    assert result["ok"] is False
    assert "'sp_client_secret_ref'" in result["message"]
    mock_run.assert_not_called()
