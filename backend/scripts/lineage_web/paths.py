"""Filesystem layout: every REPO_ROOT-derived path this server touches,
in one place so D.1's directory-move depth math only ever needs auditing
here. Split out of lineage_web_server.py (D.3, 2026-07-08) -- pure code
motion, no logic changed.
"""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent.parent
STATE_DIR = REPO_ROOT / "analysis" / "single_workspace_scan"
LOG_DIR = STATE_DIR / "logs"
STATE_PATH = STATE_DIR / "state.json"
QUEUE_PATH = STATE_DIR / "queue.json"
HISTORY_PATH = STATE_DIR / "history.csv"
PROGRESS_PATH = STATE_DIR / "progress.json"
WORKSPACE_INDEX_PATH = REPO_ROOT / "index" / "workspaces.csv"
ITEMS_INDEX_PATH = REPO_ROOT / "index" / "items.csv"
DEPENDENCIES_INDEX_PATH = REPO_ROOT / "index" / "dependencies.csv"
OBJECT_IMPACT_PATH = REPO_ROOT / "frontend" / "semantic-lineage" / "data" / "object-impact.json"
GRAPH_MAP_INDEX_OBJECTS_PATH = REPO_ROOT / "frontend" / "semantic-lineage" / "data" / "graph-map-index-objects.json"
NOTEBOOK_SUPER_LINEAGE_PATH = REPO_ROOT / "frontend" / "semantic-lineage" / "data" / "notebook-super-lineage.json"
DIFF_DIR = STATE_DIR / "diffs"
# Root that catalog.py's _get_notebook_code() reads notebook source from --
# see 51_download_notebook_definitions.ps1's own -OutputDirectory default.
# A dedicated constant (used with the same .resolve()+containment check as
# DIFF_DIR/_resolve_static_path) instead of catalog.py concatenating
# REPO_ROOT itself, so path traversal there gets the same defense-in-depth
# guard the rest of this package already applies (2026-08-17 security
# audit).
NOTEBOOK_DEFINITIONS_DIR = REPO_ROOT / "data" / "notebook_definitions"
ITEM_HISTORY_PATH = REPO_ROOT / "analysis" / "item_history.csv"
ITEM_HISTORY_FIELDS = ("event_date", "event_type", "qualified_name", "item_type", "item_name", "workspace_name", "scope_label", "scan_started_at", "triggered_by_email")
# dbo.bronze_dependency_history's columns -- same idea as ITEM_HISTORY_
# FIELDS, one level down the graph (an edge, not a node). See scan_
# manager._append_dependency_history_rows_warehouse.
DEPENDENCY_HISTORY_FIELDS = ("event_date", "event_type", "from_qualified_name", "to_qualified_name", "relationship_type", "scope_label", "scan_started_at")
SCAN_SCRIPT_PATH = REPO_ROOT / "backend" / "scripts" / "scan_single_workspace.ps1"
FULL_SCAN_SCRIPT_PATH = REPO_ROOT / "backend" / "scripts" / "99_refresh_lineage_project.ps1"
EXECUTIONS_SCAN_SCRIPT_PATH = REPO_ROOT / "backend" / "scripts" / "71_scan_production_executions.ps1"
ADMIN_SETTINGS_PATH = REPO_ROOT / "config" / "admin_settings.json"
LAKEHOUSE_TARGET_PATH = REPO_ROOT / "config" / "lakehouse_target.json"
# Fase 5 (2026-08-24), the multi-tenant installer wizard's source of truth
# for what gets deployed -- see installer.py.
FABRIC_NOTEBOOKS_DIR = REPO_ROOT / "fabric_notebooks"
# Downloadable from the admin panel's API keys tab (2026-08-24) -- a
# colleague setting up the remote MCP agent needs this one file, not a
# full repo checkout ("todo remoto", no local Fabric access/repo required
# for a commercial deployment). See handler.py's GET /mcp_server_remote.py.
MCP_SERVER_REMOTE_PATH = REPO_ROOT / "backend" / "scripts" / "mcp_server_remote.py"
# Persisted delegated "service session" (see service_session.py) -- already
# covered by .gitignore's blanket `config/*.json` rule, same as the two
# paths above.
SERVICE_SESSION_PATH = REPO_ROOT / "config" / "service_session.json"
TEST_EXTERNAL_SOURCE_SCRIPT_PATH = REPO_ROOT / "backend" / "scripts" / "66_test_external_source_connection.ps1"
WAREHOUSE_UPLOAD_SCRIPT_PATH = REPO_ROOT / "backend" / "scripts" / "67_upload_bronze_to_warehouse.ps1"
ONELAKE_PUBLISH_SCRIPT_PATH = REPO_ROOT / "backend" / "scripts" / "72_publish_web_data_to_onelake.ps1"
# Purview-inspired admin tabs (Tanda A, 2026-07-09): all three read data
# already produced by existing scripts (68/06/07), nothing new to scan.
WORKSPACE_ROLE_ASSIGNMENTS_PATH = REPO_ROOT / "index" / "workspace_role_assignments.csv"
EXECUTION_DURATION_BY_ITEM_PATH = REPO_ROOT / "analysis" / "execution_duration_by_item.csv"
FAILURE_HOTSPOTS_PATH = REPO_ROOT / "analysis" / "failure_hotspots.csv"
SCHEDULE_REVIEW_CANDIDATES_PATH = REPO_ROOT / "analysis" / "schedule_review_candidates.csv"
# Local cache for onelake_data.py's fetched copies of the big generated
# JSON payloads (see 72_publish_web_data_to_onelake.py) -- separate from
# frontend/semantic-lineage/data/ (the local-files source) so the two
# never collide or get silently mixed up.
ONELAKE_CACHE_DIR = REPO_ROOT / "analysis" / "onelake_cache"
# Governance scan (2026-08-26, scripts/73_discover_governance_scan.ps1) --
# Scanner API: sensitivity label, endorsement, tags, and semantic model RLS
# roles, tenant-wide. See that script's own docstring for the 401
# blocker this API can hit; governance_scan_status.csv is
# what lets the admin panel's Governance tab show a diagnosis instead of a
# silently-empty section.
GOVERNANCE_SENSITIVITY_LABELS_PATH = REPO_ROOT / "analysis" / "governance_sensitivity_labels.csv"
GOVERNANCE_ENDORSEMENT_PATH = REPO_ROOT / "analysis" / "governance_endorsement.csv"
GOVERNANCE_TAGS_PATH = REPO_ROOT / "analysis" / "governance_tags.csv"
GOVERNANCE_RLS_ROLES_PATH = REPO_ROOT / "analysis" / "governance_rls_roles.csv"
GOVERNANCE_SCAN_STATUS_PATH = REPO_ROOT / "analysis" / "governance_scan_status.csv"
