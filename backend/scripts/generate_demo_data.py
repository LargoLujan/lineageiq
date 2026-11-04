"""Generates a synthetic Fabric tenant ("Contoso") for the product demo.

Deterministic on purpose: every ID is derived with uuid5 from a fixed
name, so running this script always produces exactly the same output
files -- there is no dependency on a real Fabric tenant, which is why it
is safe to include in a public/commercial repository.

Usage:
    python backend/scripts/generate_demo_data.py

It writes the minimal input CSVs that backend/scripts/11_build_lineage_
explorer_fast.py, 17_build_object_impact_index_fast.py, 21_build_reverse_
impact_package_fast.py and build_graph_map_index.py need, and then
invokes those four scripts to produce the final JSON files read by the
frontend (frontend/semantic-lineage/data/*.json: lineage-explorer,
object-impact and the two Graph Map indexes) -- so the output schema is
exactly the same code the real product uses against a real tenant, not a
hand-made recreation. Everything it writes lands in git-ignored paths
(index/, analysis/, frontend/**/data/).

Afterwards, to open the viewer without signing in (read-only):
    LINEAGE_DEMO_MODE=1 python backend/scripts/lineage_web_server.py --bind 127.0.0.1 --directory frontend/semantic-lineage
"""

import csv
import subprocess
import sys
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
NAMESPACE = uuid.UUID("6f1e6a4e-3b7a-4b1a-9e7d-2f6a8c1d9b0e")


def gid(name):
    """GUID determinista: el mismo nombre siempre da el mismo ID."""
    return str(uuid.uuid5(NAMESPACE, name))


def write_csv(path, fieldnames, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, quoting=csv.QUOTE_ALL)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in fieldnames})
    print(f"[demo-data] {path.relative_to(REPO_ROOT)}: {len(rows)} fila(s)")


# ---------------------------------------------------------------------------
# Demo tenant: "Contoso", a fictitious company with a typical Fabric data
# platform (medallion architecture) across 3 workspaces.
# ---------------------------------------------------------------------------

WORKSPACES = [
    {"name": "Contoso-Sales_Prod", "env": "PROD"},
    {"name": "Contoso-Finance_Prod", "env": "PROD"},
    {"name": "Contoso-HR_Dev", "env": "DEV"},
]

# (workspace, item_type, item_name)
ITEMS = [
    ("Contoso-Sales_Prod", "Lakehouse", "LH_Sales_Bronze"),
    ("Contoso-Sales_Prod", "Lakehouse", "LH_Sales_Silver"),
    ("Contoso-Sales_Prod", "Lakehouse", "LH_Sales_Gold"),
    ("Contoso-Sales_Prod", "Notebook", "NB_Load_Salesforce_Bronze"),
    ("Contoso-Sales_Prod", "Notebook", "NB_Sales_Silver_Transform"),
    ("Contoso-Sales_Prod", "Notebook", "NB_Sales_Gold_Aggregate"),
    ("Contoso-Sales_Prod", "DataPipeline", "PL_Sales_Daily_Refresh"),
    ("Contoso-Sales_Prod", "CopyJob", "Copy_CRM_Contacts"),
    ("Contoso-Sales_Prod", "SemanticModel", "SM_Sales_Performance"),
    ("Contoso-Sales_Prod", "Report", "RPT_Sales_Dashboard"),
    ("Contoso-Finance_Prod", "Lakehouse", "LH_Finance_Silver"),
    ("Contoso-Finance_Prod", "Notebook", "NB_Finance_ERP_Ingest"),
    ("Contoso-Finance_Prod", "DataPipeline", "PL_Finance_Monthly_Close"),
    ("Contoso-Finance_Prod", "SemanticModel", "SM_Finance_Overview"),
    ("Contoso-Finance_Prod", "Report", "RPT_Finance_Executive"),
    ("Contoso-HR_Dev", "Lakehouse", "LH_HR_Bronze"),
    ("Contoso-HR_Dev", "Notebook", "NB_HR_Employee_Sync"),
    ("Contoso-HR_Dev", "SemanticModel", "SM_HR_Headcount"),
]


def qname(workspace, item_type, item_name):
    return f"{workspace} / {item_type} / {item_name}"


def build_workspaces_csv():
    fieldnames = [
        "workspace_name", "normalized_workspace_name", "environment", "workspace_type",
        "capacity_name", "capacity_id", "capacity_region", "capacity_assignment_progress",
        "domain_name", "domain_id", "owner", "admin_principals", "description",
        "source_system", "technical_id", "status", "notes",
    ]
    rows = []
    for w in WORKSPACES:
        rows.append({
            "workspace_name": w["name"],
            "normalized_workspace_name": w["name"],
            "environment": w["env"],
            "workspace_type": "Workspace",
            "capacity_name": "Contoso-F64",
            "capacity_id": gid("capacity:contoso-f64"),
            "capacity_region": "West Europe",
            "capacity_assignment_progress": "Completed",
            "owner": "Demo Data Platform Team",
            "admin_principals": "demo-admin@contoso.example",
            "description": "Synthetic demo workspace, no real tenant data.",
            "source_system": "Demo data generator",
            "technical_id": gid(f"workspace:{w['name']}"),
            "status": "discovered",
            "notes": "",
        })
    write_csv(REPO_ROOT / "index/workspaces.csv", fieldnames, rows)


def build_items_csv():
    fieldnames = [
        "workspace_name", "workspace_environment", "item_type", "item_name", "qualified_name",
        "folder_id", "description", "default_identity", "sensitivity_label", "tags",
        "source_system", "technical_id", "status", "notes",
    ]
    env_by_ws = {w["name"]: w["env"] for w in WORKSPACES}
    rows = []
    for workspace, item_type, item_name in ITEMS:
        rows.append({
            "workspace_name": workspace,
            "workspace_environment": env_by_ws[workspace],
            "item_type": item_type,
            "item_name": item_name,
            "qualified_name": qname(workspace, item_type, item_name),
            "source_system": "Demo data generator",
            "technical_id": gid(qname(workspace, item_type, item_name)),
            "status": "discovered",
            "notes": "",
        })
    write_csv(REPO_ROOT / "index/items.csv", fieldnames, rows)


# from_item, to_item, relationship_type
DEPENDENCIES = [
    (("Contoso-Sales_Prod", "Report", "RPT_Sales_Dashboard"),
     ("Contoso-Sales_Prod", "SemanticModel", "SM_Sales_Performance"), "uses_model"),
    (("Contoso-Sales_Prod", "DataPipeline", "PL_Sales_Daily_Refresh"),
     ("Contoso-Sales_Prod", "Notebook", "NB_Load_Salesforce_Bronze"), "executes"),
    (("Contoso-Sales_Prod", "DataPipeline", "PL_Sales_Daily_Refresh"),
     ("Contoso-Sales_Prod", "Notebook", "NB_Sales_Silver_Transform"), "executes"),
    (("Contoso-Sales_Prod", "DataPipeline", "PL_Sales_Daily_Refresh"),
     ("Contoso-Sales_Prod", "Notebook", "NB_Sales_Gold_Aggregate"), "executes"),
    (("Contoso-Finance_Prod", "Report", "RPT_Finance_Executive"),
     ("Contoso-Finance_Prod", "SemanticModel", "SM_Finance_Overview"), "uses_model"),
    (("Contoso-Finance_Prod", "DataPipeline", "PL_Finance_Monthly_Close"),
     ("Contoso-Finance_Prod", "Notebook", "NB_Finance_ERP_Ingest"), "executes"),
]


def build_dependencies_csv():
    fieldnames = ["from_qualified_name", "to_qualified_name", "relationship_type", "source_system", "evidence", "confidence", "notes"]
    rows = []
    for src, dst, rel in DEPENDENCIES:
        rows.append({
            "from_qualified_name": qname(*src),
            "to_qualified_name": qname(*dst),
            "relationship_type": rel,
            "source_system": "Demo data generator",
            "evidence": "Synthetic demo relationship.",
            "confidence": "confirmed",
            "notes": "",
        })
    write_csv(REPO_ROOT / "index/dependencies.csv", fieldnames, rows)


# (item, source_type, source_server, source_database, schema, object_name, object_type, usage_type, confidence)
OBJECT_LINEAGE = [
    (("Contoso-Sales_Prod", "Notebook", "NB_Load_Salesforce_Bronze"),
     "File", "", "api.salesforce.com", "", "contacts", "file", "read", "confirmed"),
    (("Contoso-Sales_Prod", "Notebook", "NB_Load_Salesforce_Bronze"),
     "Fabric", "", "", "", "abfss://contoso-sales@onelake.dfs.fabric.microsoft.com/LH_Sales_Bronze/Tables/raw_contacts", "table_or_view", "write", "confirmed"),
    (("Contoso-Sales_Prod", "Notebook", "NB_Sales_Silver_Transform"),
     "Fabric", "", "", "", "abfss://contoso-sales@onelake.dfs.fabric.microsoft.com/LH_Sales_Bronze/Tables/raw_contacts", "table_or_view", "read", "confirmed"),
    (("Contoso-Sales_Prod", "Notebook", "NB_Sales_Silver_Transform"),
     "Fabric", "", "", "", "abfss://contoso-sales@onelake.dfs.fabric.microsoft.com/LH_Sales_Silver/Tables/contacts", "table_or_view", "write", "confirmed"),
    (("Contoso-Sales_Prod", "Notebook", "NB_Sales_Gold_Aggregate"),
     "Fabric", "", "", "", "abfss://contoso-sales@onelake.dfs.fabric.microsoft.com/LH_Sales_Silver/Tables/contacts", "table_or_view", "read", "confirmed"),
    (("Contoso-Sales_Prod", "Notebook", "NB_Sales_Gold_Aggregate"),
     "Fabric", "", "", "", "abfss://contoso-sales@onelake.dfs.fabric.microsoft.com/LH_Sales_Gold/Tables/sales_summary", "table_or_view", "write", "confirmed"),
    (("Contoso-Sales_Prod", "CopyJob", "Copy_CRM_Contacts"),
     "SQL", "crm-sql.contoso.example", "ContosoCRM", "dbo", "Contacts", "table", "read", "confirmed"),
    (("Contoso-Sales_Prod", "CopyJob", "Copy_CRM_Contacts"),
     "Fabric", "", "", "", "abfss://contoso-sales@onelake.dfs.fabric.microsoft.com/LH_Sales_Bronze/Tables/crm_contacts", "table_or_view", "write", "confirmed"),
    (("Contoso-Finance_Prod", "Notebook", "NB_Finance_ERP_Ingest"),
     "SQL", "erp-sql.contoso.example", "ContosoERP", "fin", "GeneralLedger", "table", "read", "confirmed"),
    (("Contoso-Finance_Prod", "Notebook", "NB_Finance_ERP_Ingest"),
     "Fabric", "", "", "", "abfss://contoso-finance@onelake.dfs.fabric.microsoft.com/LH_Finance_Silver/Tables/general_ledger", "table_or_view", "write", "confirmed"),
    (("Contoso-HR_Dev", "Notebook", "NB_HR_Employee_Sync"),
     "File", "", "hr.contoso.example", "", "employees.csv", "file", "read", "likely"),
    (("Contoso-HR_Dev", "Notebook", "NB_HR_Employee_Sync"),
     "Fabric", "", "", "", "abfss://contoso-hr@onelake.dfs.fabric.microsoft.com/LH_HR_Bronze/Tables/employees", "table_or_view", "write", "confirmed"),
]


def build_object_lineage_csv():
    fieldnames = [
        "workspace_name", "workspace_environment", "item_type", "item_name", "item_qualified_name",
        "source_type", "source_name", "source_qualified_name", "source_server", "source_database",
        "schema_name", "object_name", "object_type", "usage_type", "confidence", "definition_path", "evidence",
    ]
    env_by_ws = {w["name"]: w["env"] for w in WORKSPACES}
    rows = []
    for item, source_type, server, database, schema, obj_name, obj_type, usage, confidence in OBJECT_LINEAGE:
        workspace, item_type, item_name = item
        rows.append({
            "workspace_name": workspace,
            "workspace_environment": env_by_ws[workspace],
            "item_type": item_type,
            "item_name": item_name,
            "item_qualified_name": qname(*item),
            "source_type": source_type,
            "source_server": server,
            "source_database": database,
            "schema_name": schema,
            "object_name": obj_name,
            "object_type": obj_type,
            "usage_type": usage,
            "confidence": confidence,
            "definition_path": "notebook-content.py",
            "evidence": "Synthetic demo evidence.",
        })
    write_csv(REPO_ROOT / "analysis/item_object_lineage_candidates.csv", fieldnames, rows)


# (semantic model item, table alias, server, database, schema, object_name)
SEMANTIC_VIEWS = [
    (("Contoso-Sales_Prod", "SemanticModel", "SM_Sales_Performance"), "sales_summary",
     "contoso-sales.datawarehouse.fabric.microsoft.com", "LH_Sales_Gold", "dbo", "sales_summary"),
    (("Contoso-Finance_Prod", "SemanticModel", "SM_Finance_Overview"), "general_ledger",
     "contoso-finance.datawarehouse.fabric.microsoft.com", "LH_Finance_Silver", "fin", "general_ledger"),
    (("Contoso-HR_Dev", "SemanticModel", "SM_HR_Headcount"), "employees",
     "contoso-hr.datawarehouse.fabric.microsoft.com", "LH_HR_Bronze", "dbo", "employees"),
]


def build_semantic_view_candidates_csv():
    fieldnames = [
        "workspace_name", "workspace_environment", "semantic_model_name", "semantic_model_qualified_name",
        "semantic_table", "source_server", "database_name", "schema_name", "object_name", "object_type",
        "definition_path", "confidence", "evidence",
    ]
    env_by_ws = {w["name"]: w["env"] for w in WORKSPACES}
    rows = []
    for item, table_alias, server, database, schema, obj_name in SEMANTIC_VIEWS:
        workspace, item_type, item_name = item
        rows.append({
            "workspace_name": workspace,
            "workspace_environment": env_by_ws[workspace],
            "semantic_model_name": item_name,
            "semantic_model_qualified_name": qname(*item),
            "semantic_table": table_alias,
            "source_server": server,
            "database_name": database,
            "schema_name": schema,
            "object_name": obj_name,
            "object_type": "table_or_view",
            "definition_path": "definition/tables/" + table_alias + ".tmdl",
            "confidence": "confirmed",
            "evidence": "TMDL M expression contains Source{[Schema=...,Item=...]} lookup (synthetic demo).",
        })
    write_csv(REPO_ROOT / "analysis/semantic_model_view_candidates.csv", fieldnames, rows)


def build_executions_csv():
    fieldnames = [
        "record_type", "workspace_name", "item_name", "item_type", "qualified_name", "job_type",
        "trigger_type", "schedule_id", "schedule_enabled", "scheduled_time", "schedule_timezone",
        "schedule_frequency", "schedule_config", "job_instance_id", "root_activity_id", "start_time",
        "end_time", "duration_seconds", "status", "failure_reason", "source_system", "evidence",
        "technical_id", "notes",
    ]
    pipelines = [
        ("Contoso-Sales_Prod", "DataPipeline", "PL_Sales_Daily_Refresh", "06:00", "480"),
        ("Contoso-Finance_Prod", "DataPipeline", "PL_Finance_Monthly_Close", "05:00", "1200"),
    ]
    rows = []
    for workspace, item_type, item_name, scheduled_time, duration in pipelines:
        item_q = qname(workspace, item_type, item_name)
        rows.append({
            "record_type": "schedule",
            "workspace_name": workspace,
            "item_name": item_name,
            "item_type": item_type,
            "qualified_name": item_q,
            "job_type": "Pipeline",
            "trigger_type": "Scheduled",
            "schedule_id": gid(f"schedule:{item_q}"),
            "schedule_enabled": "True",
            "scheduled_time": scheduled_time,
            "schedule_timezone": "UTC",
            "schedule_frequency": "type=Daily; interval=1",
            "source_system": "Demo data generator",
            "evidence": "Synthetic demo schedule.",
            "technical_id": gid(item_q),
            "notes": "",
        })
        rows.append({
            "record_type": "job_instance",
            "workspace_name": workspace,
            "item_name": item_name,
            "item_type": item_type,
            "qualified_name": item_q,
            "job_type": "Pipeline",
            "trigger_type": "Scheduled",
            "job_instance_id": gid(f"run:{item_q}:1"),
            "root_activity_id": gid(f"run:{item_q}:1:root"),
            "start_time": "2026-01-15T06:00:00Z",
            "end_time": "2026-01-15T06:08:00Z",
            "duration_seconds": duration,
            "status": "Completed",
            "source_system": "Demo data generator",
            "evidence": "Synthetic demo run history.",
            "technical_id": gid(item_q),
            "notes": "",
        })
    write_csv(REPO_ROOT / "index/executions.csv", fieldnames, rows)


# The Markdown reports written by 17 and 21 go to analysis/ (ignored by
# git), not to docs/ as in the real pipeline: this way the README quick start
# leaves no untracked files in the repository.
DEMO_REPORTS_DIR = REPO_ROOT / "analysis/demo_reports"


def run_build_scripts():
    # Same order as 99_refresh_lineage_project.ps1: 11 (explorer) -> 17
    # (impact index) -> 21 (object-impact.json, the Impact view) ->
    # Graph Map index, which also reads object-impact.json.
    scripts = [
        [sys.executable, str(REPO_ROOT / "backend/scripts/11_build_lineage_explorer_fast.py")],
        [
            sys.executable, str(REPO_ROOT / "backend/scripts/17_build_object_impact_index_fast.py"),
            "--explorer-data-path", str(REPO_ROOT / "frontend/semantic-lineage/data/lineage-explorer.json"),
            "--object-type-resolution-queue-path", str(REPO_ROOT / "analysis/source_object_type_resolution_queue.csv"),
            "--output-impact-path", str(REPO_ROOT / "analysis/object_impact_index.csv"),
            "--output-impact-summary-path", str(REPO_ROOT / "analysis/object_impact_summary.csv"),
            "--output-coverage-path", str(REPO_ROOT / "analysis/object_level_lineage_coverage.csv"),
            "--output-coverage-summary-path", str(REPO_ROOT / "analysis/object_level_lineage_summary.csv"),
            "--output-doc-path", str(DEMO_REPORTS_DIR / "16_object_level_lineage_and_impact.md"),
        ],
        [
            sys.executable, str(REPO_ROOT / "backend/scripts/21_build_reverse_impact_package_fast.py"),
            "--output-doc-path", str(DEMO_REPORTS_DIR / "18_reverse_impact_search.md"),
        ],
        [sys.executable, str(REPO_ROOT / "backend/scripts/build_graph_map_index.py")],
    ]
    for cmd in scripts:
        print(f"[demo-data] Ejecutando: {' '.join(cmd)}")
        result = subprocess.run(cmd, cwd=REPO_ROOT)
        if result.returncode != 0:
            raise SystemExit(f"Fallo al ejecutar {cmd[1]} (exit code {result.returncode})")


def main():
    build_workspaces_csv()
    build_items_csv()
    build_dependencies_csv()
    build_object_lineage_csv()
    build_semantic_view_candidates_csv()
    build_executions_csv()
    run_build_scripts()
    print("[demo-data] Listo. Datos de demo sintéticos (tenant ficticio 'Contoso') generados.")


if __name__ == "__main__":
    main()
