"""Generates a synthetic Fabric tenant ("Contoso") for the product demo.

Deterministic on purpose: every ID is derived with uuid5 from a fixed
name, so running this script always produces exactly the same output
files -- there is no dependency on a real Fabric tenant, which is why it
is safe to include in a public/commercial repository.

Usage:
    python backend/scripts/generate_demo_data.py

It writes the input CSVs (including run history, schedules, role
assignments and the execution analysis files) that backend/scripts/11_build_lineage_
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
from datetime import datetime, timedelta
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
NAMESPACE = uuid.UUID("6f1e6a4e-3b7a-4b1a-9e7d-2f6a8c1d9b0e")


def gid(name):
    """Deterministic GUID: the same name always yields the same ID."""
    return str(uuid.uuid5(NAMESPACE, name))


def write_csv(path, fieldnames, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, quoting=csv.QUOTE_ALL)
        writer.writeheader()
        for row in rows:
            writer.writerow({key: row.get(key, "") for key in fieldnames})
    print(f"[demo-data] {path.relative_to(REPO_ROOT)}: {len(rows)} row(s)")


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


# Run profile per executable item:
# (item, job_type, base_duration_seconds, run_count, failed_run_indexes, manual_run_indexes)
RUN_PROFILES = [
    (("Contoso-Sales_Prod", "Notebook", "NB_Load_Salesforce_Bronze"), "RunNotebook", 210, 14, (), (2, 9)),
    (("Contoso-Sales_Prod", "Notebook", "NB_Sales_Silver_Transform"), "RunNotebook", 340, 14, (5,), (5,)),
    (("Contoso-Sales_Prod", "Notebook", "NB_Sales_Gold_Aggregate"), "RunNotebook", 420, 14, (), ()),
    (("Contoso-Sales_Prod", "DataPipeline", "PL_Sales_Daily_Refresh"), "Pipeline", 1020, 14, (5,), (5,)),
    (("Contoso-Sales_Prod", "CopyJob", "Copy_CRM_Contacts"), "CopyJob", 150, 14, (3, 7, 11), (7,)),
    (("Contoso-Sales_Prod", "SemanticModel", "SM_Sales_Performance"), "Refresh", 95, 14, (), ()),
    (("Contoso-Finance_Prod", "Notebook", "NB_Finance_ERP_Ingest"), "RunNotebook", 780, 12, (1, 4, 6, 10), (4, 6)),
    (("Contoso-Finance_Prod", "DataPipeline", "PL_Finance_Monthly_Close"), "Pipeline", 1500, 12, (4,), (4,)),
    (("Contoso-Finance_Prod", "SemanticModel", "SM_Finance_Overview"), "Refresh", 120, 12, (), ()),
    (("Contoso-HR_Dev", "Notebook", "NB_HR_Employee_Sync"), "RunNotebook", 75, 10, (2,), tuple(range(10))),
    (("Contoso-HR_Dev", "SemanticModel", "SM_HR_Headcount"), "Refresh", 40, 10, (), tuple(range(10))),
]

# (item, scheduled_time, enabled, frequency)
SCHEDULES = [
    (("Contoso-Sales_Prod", "DataPipeline", "PL_Sales_Daily_Refresh"), "06:00", True, "type=Daily; interval=1"),
    (("Contoso-Sales_Prod", "CopyJob", "Copy_CRM_Contacts"), "05:30", True, "type=Daily; interval=1"),
    (("Contoso-Finance_Prod", "DataPipeline", "PL_Finance_Monthly_Close"), "05:00", True, "type=Monthly; interval=1"),
    (("Contoso-HR_Dev", "Notebook", "NB_HR_Employee_Sync"), "22:00", False, "type=Weekly; interval=1"),
]

SCHEDULE_TIMEZONE = "UTC"
RUN_HISTORY_START = datetime(2026, 1, 5, 6, 0, 0)

EXECUTION_FIELDS = [
    "record_type", "workspace_name", "item_name", "item_type", "qualified_name", "job_type",
    "trigger_type", "schedule_id", "schedule_enabled", "scheduled_time", "schedule_timezone",
    "schedule_frequency", "schedule_config", "job_instance_id", "root_activity_id", "start_time",
    "end_time", "duration_seconds", "status", "failure_reason", "source_system", "evidence",
    "technical_id", "notes",
]


def _iso(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def _median(values):
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2


def _fmt(value):
    return f"{round(value, 3):g}"


def build_execution_rows():
    """Deterministic run history: one job_instance row per run plus one
    schedule row per configured schedule (same shape as 06_discover_
    executions.ps1). Durations vary +/-25% around the item's base value,
    derived from uuid5 so they never change between runs."""
    rows = []
    for item, job_type, base, run_count, failed_idx, manual_idx in RUN_PROFILES:
        workspace, item_type, item_name = item
        item_q = qname(*item)
        for n in range(run_count):
            jitter = (int(gid(f"jitter:{item_q}:{n}")[:4], 16) % 51 - 25) / 100.0
            failed = n in failed_idx
            duration = round(base * (1 + jitter) * (0.35 if failed else 1.0))
            start = RUN_HISTORY_START + timedelta(days=n * 2)
            manual = n in manual_idx
            if manual:
                start += timedelta(hours=5, minutes=17)
            rows.append({
                "record_type": "job_instance",
                "workspace_name": workspace,
                "item_name": item_name,
                "item_type": item_type,
                "qualified_name": item_q,
                "job_type": job_type,
                "trigger_type": "Manual" if manual else "Scheduled",
                "job_instance_id": gid(f"run:{item_q}:{n}"),
                "root_activity_id": gid(f"run:{item_q}:{n}:root"),
                "start_time": _iso(start),
                "end_time": _iso(start + timedelta(seconds=duration)),
                "duration_seconds": str(duration),
                "status": "Failed" if failed else "Completed",
                "failure_reason": "Synthetic demo failure: upstream source timeout." if failed else "",
                "source_system": "Demo data generator",
                "evidence": "Synthetic demo run history.",
                "technical_id": gid(item_q),
            })
    for item, scheduled_time, enabled, frequency in SCHEDULES:
        workspace, item_type, item_name = item
        item_q = qname(*item)
        job_type = next(p[1] for p in RUN_PROFILES if p[0] == item)
        rows.append({
            "record_type": "schedule",
            "workspace_name": workspace,
            "item_name": item_name,
            "item_type": item_type,
            "qualified_name": item_q,
            "job_type": job_type,
            "trigger_type": "Scheduled",
            "schedule_id": gid(f"schedule:{item_q}"),
            "schedule_enabled": "True" if enabled else "False",
            "scheduled_time": scheduled_time,
            "schedule_timezone": SCHEDULE_TIMEZONE,
            "schedule_frequency": frequency,
            "source_system": "Demo data generator",
            "evidence": "Synthetic demo schedule.",
            "technical_id": gid(item_q),
        })
    return rows


def build_executions_csv():
    rows = build_execution_rows()
    write_csv(REPO_ROOT / "index/executions.csv", EXECUTION_FIELDS, rows)
    return rows


def build_execution_analysis_csvs(execution_rows):
    """analysis/execution_duration_by_item.csv, failure_hotspots.csv and
    schedule_review_candidates.csv -- aggregated from the job rows with the
    same columns and rules as 06_discover_executions.ps1 and
    07_optimize_orchestration.ps1 (hotspot = at least 3 failed runs)."""
    jobs = [r for r in execution_rows if r["record_type"] == "job_instance"]
    schedules = [r for r in execution_rows if r["record_type"] == "schedule"]

    groups = {}
    for row in jobs:
        groups.setdefault((row["qualified_name"], row["job_type"]), []).append(row)

    duration_rows = []
    for (item_q, job_type), group in groups.items():
        first = group[0]
        completed = [r for r in group if r["status"] == "Completed"]
        durations = [float(r["duration_seconds"]) for r in completed]
        latest = max(group, key=lambda r: r["start_time"])
        duration_rows.append({
            "workspace_name": first["workspace_name"],
            "item_name": first["item_name"],
            "item_type": first["item_type"],
            "qualified_name": item_q,
            "job_type": job_type,
            "run_count": len(group),
            "completed_count": len(completed),
            "failed_count": sum(1 for r in group if r["status"] == "Failed"),
            "cancelled_count": 0,
            "scheduled_count": sum(1 for r in group if r["trigger_type"] == "Scheduled"),
            "manual_count": sum(1 for r in group if r["trigger_type"] == "Manual"),
            "latest_start_time": latest["start_time"],
            "latest_end_time": latest["end_time"],
            "min_duration_seconds": _fmt(min(durations)),
            "avg_duration_seconds": _fmt(sum(durations) / len(durations)),
            "median_duration_seconds": _fmt(_median(durations)),
            "max_duration_seconds": _fmt(max(durations)),
            "last_status": latest["status"],
        })
    duration_rows.sort(key=lambda r: (float(r["max_duration_seconds"]), r["run_count"]), reverse=True)
    duration_fields = [
        "workspace_name", "item_name", "item_type", "qualified_name", "job_type", "run_count",
        "completed_count", "failed_count", "cancelled_count", "scheduled_count", "manual_count",
        "latest_start_time", "latest_end_time", "min_duration_seconds", "avg_duration_seconds",
        "median_duration_seconds", "max_duration_seconds", "last_status",
    ]
    write_csv(REPO_ROOT / "analysis/execution_duration_by_item.csv", duration_fields, duration_rows)

    hotspots = []
    for row in duration_rows:
        if row["failed_count"] < 3:
            continue
        hotspots.append({
            **{k: row[k] for k in (
                "workspace_name", "item_name", "item_type", "qualified_name", "job_type", "run_count",
                "completed_count", "failed_count", "avg_duration_seconds", "max_duration_seconds",
                "latest_start_time", "latest_end_time", "last_status")},
            "failure_rate": round(row["failed_count"] / max(1, row["run_count"]), 4),
            "recommendation_hint": "Stabilize before optimizing schedule or parallelism.",
        })
    hotspots.sort(key=lambda r: (r["failed_count"], r["failure_rate"], float(r["max_duration_seconds"])), reverse=True)
    for rank, row in enumerate(hotspots, start=1):
        row["rank"] = rank
    hotspot_fields = [
        "workspace_name", "item_name", "item_type", "qualified_name", "job_type", "run_count",
        "completed_count", "failed_count", "failure_rate", "avg_duration_seconds",
        "max_duration_seconds", "latest_start_time", "latest_end_time", "last_status",
        "recommendation_hint", "rank",
    ]
    write_csv(REPO_ROOT / "analysis/failure_hotspots.csv", hotspot_fields, hotspots)

    duration_by_qn = {}
    for row in duration_rows:
        duration_by_qn.setdefault(row["qualified_name"], row)
    review_by_qn = {}
    for row in schedules:
        entry = review_by_qn.setdefault(row["qualified_name"], {"enabled": 0, "disabled": 0, "times": [], "zones": []})
        entry["enabled" if row["schedule_enabled"] == "True" else "disabled"] += 1
        if row["scheduled_time"] not in entry["times"]:
            entry["times"].append(row["scheduled_time"])
        if row["schedule_timezone"] not in entry["zones"]:
            entry["zones"].append(row["schedule_timezone"])
    review_rows = []
    for item_q, entry in review_by_qn.items():
        duration = duration_by_qn.get(item_q)
        review_rows.append({
            "qualified_name": item_q,
            "workspace_name": duration["workspace_name"] if duration else item_q.split(" / ")[0],
            "item_name": duration["item_name"] if duration else item_q.split(" / ")[-1],
            "item_type": duration["item_type"] if duration else "",
            "enabled_schedules": entry["enabled"],
            "disabled_schedules": entry["disabled"],
            "schedule_times": "; ".join(entry["times"]),
            "schedule_timezones": "; ".join(entry["zones"]),
            "run_count": duration["run_count"] if duration else 0,
            "failed_count": duration["failed_count"] if duration else 0,
            "avg_duration_seconds": duration["avg_duration_seconds"] if duration else 0,
            "recommendation_hint": "Review disabled schedules and confirm only intentional schedules are enabled.",
        })
    review_rows.sort(key=lambda r: (r["enabled_schedules"], r["disabled_schedules"], r["failed_count"]), reverse=True)
    review_fields = [
        "qualified_name", "workspace_name", "item_name", "item_type", "enabled_schedules",
        "disabled_schedules", "schedule_times", "schedule_timezones", "run_count", "failed_count",
        "avg_duration_seconds", "recommendation_hint",
    ]
    write_csv(REPO_ROOT / "analysis/schedule_review_candidates.csv", review_fields, review_rows)


# (workspace, principal_name, principal_email, principal_type, role)
ROLE_ASSIGNMENTS = [
    ("Contoso-Sales_Prod", "Data Engineering Team", "", "Group", "Admin"),
    ("Contoso-Sales_Prod", "Alice Example", "alice@contoso.com", "User", "Member"),
    ("Contoso-Sales_Prod", "Bob Example", "bob@contoso.com", "User", "Contributor"),
    ("Contoso-Sales_Prod", "Sales Analysts", "", "Group", "Viewer"),
    ("Contoso-Finance_Prod", "Data Engineering Team", "", "Group", "Admin"),
    ("Contoso-Finance_Prod", "Carol Example", "carol@contoso.com", "User", "Member"),
    ("Contoso-Finance_Prod", "Finance Controllers", "", "Group", "Viewer"),
    ("Contoso-HR_Dev", "Alice Example", "alice@contoso.com", "User", "Admin"),
    ("Contoso-HR_Dev", "Dave Example", "dave@example.com", "User", "Contributor"),
    ("Contoso-HR_Dev", "HR Reviewers", "", "Group", "Viewer"),
]


def build_role_assignments_csv():
    fieldnames = [
        "workspace_name", "principal_id", "principal_name", "principal_email",
        "principal_type", "role", "status", "evidence",
    ]
    rows = []
    for workspace, name, email, principal_type, role in ROLE_ASSIGNMENTS:
        rows.append({
            "workspace_name": workspace,
            "principal_id": gid(f"principal:{name}"),
            "principal_name": name,
            "principal_email": email,
            "principal_type": principal_type,
            "role": role,
            "status": "discovered",
            "evidence": "Synthetic demo role assignment.",
        })
    write_csv(REPO_ROOT / "index/workspace_role_assignments.csv", fieldnames, rows)


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
        print(f"[demo-data] Running: {' '.join(cmd)}")
        result = subprocess.run(cmd, cwd=REPO_ROOT)
        if result.returncode != 0:
            raise SystemExit(f"Failed to run {cmd[1]} (exit code {result.returncode})")


def main():
    build_workspaces_csv()
    build_items_csv()
    build_dependencies_csv()
    build_object_lineage_csv()
    build_semantic_view_candidates_csv()
    execution_rows = build_executions_csv()
    # Before the build scripts: 11 reads failure_hotspots / schedule_review.
    build_execution_analysis_csvs(execution_rows)
    build_role_assignments_csv()
    run_build_scripts()
    print("[demo-data] Done. Synthetic demo data (fictitious 'Contoso' tenant) generated.")


if __name__ == "__main__":
    main()
