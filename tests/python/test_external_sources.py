"""Unit tests for the pure-logic pieces of backend/scripts/lineage_web/
external_sources.py added 2026-08-18 (Fabric connection assignment /
notifications). The subprocess-based connection tests aren't covered here
-- see the module's own docstrings for why those are "verified live, not
unit-tested" by this project's convention.
"""
import sys
from pathlib import Path
from unittest.mock import patch

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend" / "scripts"))

from lineage_web.external_sources import _external_source_identifier, _summarize_pending_external_sources, _test_external_source  # noqa: E402


def test_external_source_identifier_prefers_name():
    assert _external_source_identifier({"name": "Legacy CRM", "host": "sql01"}) == "Legacy CRM"


def test_external_source_identifier_falls_back_to_host():
    assert _external_source_identifier({"host": "sql01.internal", "type": "sql_server"}) == "sql01.internal"


def test_external_source_identifier_falls_back_to_account_for_snowflake():
    assert _external_source_identifier({"type": "snowflake", "account": "abc123.eu-west-1"}) == "abc123.eu-west-1"


def test_external_source_identifier_falls_back_to_project_id_for_bigquery():
    assert _external_source_identifier({"type": "google_bigquery", "project_id": "my-gcp-project"}) == "my-gcp-project"


def test_external_source_identifier_falls_back_to_file_path_for_sqlite():
    assert _external_source_identifier({"type": "sqlite", "file_path": "/data/legacy.db"}) == "/data/legacy.db"


def test_external_source_identifier_falls_back_to_type_when_nothing_else_set():
    assert _external_source_identifier({"type": "postgresql"}) == "postgresql"


def test_external_source_identifier_falls_back_to_question_mark_when_totally_empty():
    assert _external_source_identifier({}) == "?"


def test_summarize_pending_external_sources_with_no_sources():
    result = _summarize_pending_external_sources({})
    assert result == {"pending": [], "pending_count": 0, "broken": [], "broken_count": 0, "total_count": 0}


def test_summarize_pending_external_sources_flags_sources_without_a_connection():
    settings = {
        "external_sources": [
            {"type": "sql_server", "host": "sql01", "fabric_connection_id": "conn-1", "fabric_connection_last_test_status": "Online"},
            {"type": "postgresql", "host": "pg01"},
        ]
    }
    result = _summarize_pending_external_sources(settings)
    assert result["total_count"] == 2
    assert result["pending_count"] == 1
    assert result["pending"] == [{"index": 1, "type": "postgresql", "identifier": "pg01"}]
    assert result["broken_count"] == 0


def test_summarize_pending_external_sources_treats_empty_string_connection_id_as_unassigned():
    settings = {"external_sources": [{"type": "mysql", "host": "my01", "fabric_connection_id": ""}]}
    result = _summarize_pending_external_sources(settings)
    assert result["pending_count"] == 1


def test_summarize_pending_external_sources_flags_an_assigned_but_offline_connection_as_broken():
    settings = {
        "external_sources": [
            {
                "type": "sql_server",
                "host": "sql01",
                "fabric_connection_id": "conn-1",
                "fabric_connection_last_test_status": "Offline",
                "fabric_connection_last_test_at": "2026-08-18T10:00:00Z",
            }
        ]
    }
    result = _summarize_pending_external_sources(settings)
    assert result["pending_count"] == 0
    assert result["broken_count"] == 1
    assert result["broken"] == [{
        "index": 0,
        "type": "sql_server",
        "identifier": "sql01",
        "tested_at": "2026-08-18T10:00:00Z",
    }]


def test_summarize_pending_external_sources_does_not_double_count_pending_and_broken():
    # A source with NO connection assigned is "pending", never "broken" --
    # there's nothing to have tested yet.
    settings = {"external_sources": [{"type": "mysql", "host": "my01", "fabric_connection_last_test_status": "Offline"}]}
    result = _summarize_pending_external_sources(settings)
    assert result["pending_count"] == 1
    assert result["broken_count"] == 0


@patch("lineage_web.external_sources._load_admin_settings")
def test_test_external_source_refuses_reserved_sp_secret_password_ref(mock_load):
    mock_load.return_value = {"lakehouse": {"sp_client_secret_ref": "FABRIC_API_SP_CLIENT_SECRET"}}
    source = {"type": "sql_server", "host": "sql01", "password_ref": "FABRIC_API_SP_CLIENT_SECRET"}
    result = _test_external_source(source)
    assert result["ok"] is False
    assert "reserved" in result["message"].lower()


@patch("lineage_web.external_sources._resolve_pwsh_command")
@patch("lineage_web.external_sources._load_admin_settings")
def test_test_external_source_allows_a_different_password_ref(mock_load, mock_pwsh):
    mock_load.return_value = {"lakehouse": {"sp_client_secret_ref": "FABRIC_API_SP_CLIENT_SECRET"}}
    mock_pwsh.return_value = None  # short-circuits right after the reserved-name check, no real subprocess needed
    source = {"type": "sql_server", "host": "sql01", "password_ref": "MY_SOURCE_PASSWORD"}
    result = _test_external_source(source)
    assert result["message"] == "PowerShell ('pwsh') was not found on PATH."
