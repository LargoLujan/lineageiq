#!/usr/bin/env python3
"""Fast Python port of 11_build_lineage_explorer.ps1.

Faithful re-implementation: same inputs, same output shape. The only
intentional behavior differences are documented inline (case-insensitive
sort/unique to match PowerShell's default string comparison, and the
`id` fields on source nodes, which use a deterministic CRC32 instead of
.NET's randomized string GetHashCode() -- that value was never stable
across runs of the original script either, it is only used by the
frontend as an opaque key).
"""

import argparse
import json
import os
import sys
import re
import zlib
from collections import Counter, defaultdict, deque
from datetime import datetime
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent.parent  # Anchor default paths to the repo, not $PWD

EXACT_OBJECT_TYPES = {"table", "view", "stored_procedure", "file", "shortcut", "query"}

# Illustrative example: adapt this list to the business systems that
# appear in the workspace/item names of your own tenant, to normalize
# them to their "pretty" form.
FABRIC_TOKEN_WORDS = {
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
FABRIC_TOKEN_ACRONYMS = {"API", "BI", "CRM", "ERP", "FT", "HR", "ID", "IT", "LH", "QA", "SQL"}

PLACEHOLDER_SUFFIXES = ("_TABLES_PATH", "_TABLE_PATH", "_FILES_PATH", "_FILE_PATH", "_ABFSS_PATH", "_ONELAKE_PATH", "_PATH")


# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

def ensure_parent(path):
    parent = Path(path).parent
    if str(parent):
        parent.mkdir(parents=True, exist_ok=True)


def write_json_atomic(path, payload):
    # Colleagues load this file directly over the shared tunnel while a scan
    # may be regenerating it. Write to a temp file in the same directory
    # first, then os.replace() -- atomic on both POSIX and Windows -- so a
    # crash mid-write never leaves a truncated file being served.
    ensure_parent(path)
    tmp_path = f"{path}.tmp-{os.getpid()}"
    try:
        with open(tmp_path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise


def get_field(row, names):
    if row is None:
        return ""
    for name in names:
        if name in row:
            value = row[name]
            if value is not None:
                return str(value)
    return ""


def resolve_planning_edge_condition(condition_chain):
    if "Failed" in condition_chain:
        return "failed"
    if not condition_chain:
        return "completed"
    if all(c == "Succeeded" for c in condition_chain if c):
        return "succeeded"
    return "completed"


def resolve_pipeline_activity_dependency_edges(pipeline_activity_all_rows):
    """Real Fabric/ADF pipeline activities declare dependsOn with
    dependencyConditions (Succeeded/Failed/Completed/Skipped) between
    activities in the SAME pipeline. Resolve that into direct item-to-item
    edges (e.g. "Notebook A" -> "CopyJob B") so the Planning view can color
    arrows the same way the pipeline canvas does, instead of only inferring
    order from read/write table overlap. Some activities in between
    (Fail/IfCondition/Wait/...) do not themselves invoke an item, so walk
    backward through the dependsOn chain (bounded depth) to find the
    nearest invoking ancestor(s).
    """
    activity_invokes_by_pipeline = defaultdict(dict)
    activity_depends_on_by_pipeline = defaultdict(lambda: defaultdict(list))
    for row in pipeline_activity_all_rows:
        pipeline_key = row["pipeline_qualified_name"]
        activity_name = get_field(row, ["activity_name"])
        if not activity_name:
            continue
        invoked_item = get_field(row, ["invoked_item_qualified_name"])
        if invoked_item and activity_name not in activity_invokes_by_pipeline[pipeline_key]:
            activity_invokes_by_pipeline[pipeline_key][activity_name] = invoked_item
        depends_on_activity = get_field(row, ["depends_on_activity"])
        if depends_on_activity:
            raw_conditions = get_field(row, ["dependency_conditions"])
            conditions = [c for c in raw_conditions.split(";") if c]
            activity_depends_on_by_pipeline[pipeline_key][activity_name].append(
                {"depends_on_activity": depends_on_activity, "conditions": conditions}
            )

    max_walk_depth = 6
    edges = []
    for pipeline_key, invokes in activity_invokes_by_pipeline.items():
        depends_on_map = activity_depends_on_by_pipeline.get(pipeline_key, {})
        seen_edges = set()
        for activity_name, to_item in invokes.items():
            queue = deque(
                {"activity": dep["depends_on_activity"], "chain": list(dep["conditions"]), "depth": 1}
                for dep in depends_on_map.get(activity_name, [])
            )
            visited = set()
            while queue:
                current = queue.popleft()
                if current["depth"] > max_walk_depth:
                    continue
                if current["activity"] in visited:
                    continue
                visited.add(current["activity"])
                from_item = invokes.get(current["activity"])
                if from_item and from_item != to_item:
                    condition = resolve_planning_edge_condition(current["chain"])
                    edge_key = (from_item, to_item, condition)
                    if edge_key not in seen_edges:
                        seen_edges.add(edge_key)
                        edges.append(
                            {
                                "pipeline_qualified_name": pipeline_key,
                                "from_item_qualified_name": from_item,
                                "to_item_qualified_name": to_item,
                                "condition": condition,
                            }
                        )
                    continue
                for dep in depends_on_map.get(current["activity"], []):
                    queue.append(
                        {
                            "activity": dep["depends_on_activity"],
                            "chain": current["chain"] + list(dep["conditions"]),
                            "depth": current["depth"] + 1,
                        }
                    )
    return edges


def normalize_key(value):
    if not value:
        return ""
    return re.sub(r"\s+", " ", str(value).lower()).strip()


def normalize_object_type(value):
    clean = re.sub(r"[\s-]+", "_", normalize_key(value))
    aliases = {
        "storedprocedure": "stored_procedure",
        "stored_procedure": "stored_procedure",
        "procedure": "stored_procedure",
        "proc": "stored_procedure",
        "sp": "stored_procedure",
        "tbl": "table",
    }
    return aliases.get(clean, clean)


def is_exact_object_type(value):
    return normalize_object_type(value) in EXACT_OBJECT_TYPES


def read_csv(path):
    import csv

    if not path or not Path(path).exists():
        return []
    with open(path, newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def deterministic_id(prefix, key):
    return f"{prefix}:{zlib.crc32(normalize_key(key).encode('utf-8'))}"


def ci_lower(value):
    """Sort/unique key matching PowerShell's default case-insensitive string comparison."""
    return (value or "").lower()


def unique_ci_preserve_order(values):
    seen = set()
    result = []
    for value in values:
        if not value:
            continue
        key = ci_lower(value)
        if key in seen:
            continue
        seen.add(key)
        result.append(value)
    return result


# ---------------------------------------------------------------------------
# Reinvestigar panel metadata (Get-RefreshMetadata / Get-FileFreshness / Get-LatestRunLog)
# ---------------------------------------------------------------------------

def get_relative_path_text(path_str):
    if not path_str:
        return ""
    normalized = str(path_str).replace("\\", "/")
    cwd = str(Path.cwd()).replace("\\", "/")
    if normalized.startswith(cwd + "/"):
        return normalized[len(cwd) + 1:]
    return normalized


def count_lines_fast(path):
    # Streamed line count instead of loading the whole file into memory --
    # matters for frontend/semantic-lineage/data/lineage-explorer.json (large on big tenants),
    # which is itself one of the freshness-checked artifacts.
    count = 0
    try:
        with open(path, "rb") as handle:
            for _ in handle:
                count += 1
        return count
    except OSError:
        return 0


def get_file_freshness(paths):
    now = datetime.now()
    rows = []
    for path_str in paths:
        path = Path(path_str)
        if path.exists():
            stat = path.stat()
            is_dir = path.is_dir()
            line_count = 0 if is_dir else count_lines_fast(path)
            modified_at = datetime.fromtimestamp(stat.st_mtime)
            rows.append(
                {
                    "path": get_relative_path_text(path_str),
                    "exists": True,
                    "bytes": 0 if is_dir else stat.st_size,
                    "lines": line_count,
                    "modified_at": modified_at.replace(microsecond=0).isoformat(),
                    "age_hours": round((now - modified_at).total_seconds() / 3600, 2),
                }
            )
        else:
            rows.append(
                {
                    "path": get_relative_path_text(path_str),
                    "exists": False,
                    "bytes": 0,
                    "lines": 0,
                    "modified_at": "",
                    "age_hours": None,
                }
            )
    return rows


def get_latest_run_log(directory):
    dir_path = Path(directory)
    if not dir_path.exists():
        return None
    candidates = sorted(dir_path.glob("lineage_refresh_*.md"), key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0] if candidates else None


ARTIFACT_PATHS = [
    "index/workspaces.csv",
    "index/items.csv",
    "index/dependencies.csv",
    "index/executions.csv",
    "graph/nodes.csv",
    "graph/edges.csv",
    "analysis/orchestration_recommendations.csv",
    "index/manual_lineage_object_evidence.csv",
    "analysis/manual_lineage_review_queue.csv",
    "analysis/item_object_lineage_candidates.csv",
    "analysis/item_object_lineage_gaps.csv",
    "analysis/notebook_definition_download_manifest.csv",
    "analysis/notebook_super_lineage_objects.csv",
    "analysis/notebook_super_lineage_flows.csv",
    "analysis/notebook_super_lineage_gaps.csv",
    "analysis/notebook_super_lineage_summary.csv",
    "docs/45_notebook_super_lineage.md",
    "analysis/pipeline_object_lineage_candidates.csv",
    "analysis/pipeline_activity_lineage.csv",
    "analysis/pipeline_object_lineage_gaps.csv",
    "index/source_object_type_overrides.csv",
    "analysis/source_object_type_metadata_evidence.csv",
    "analysis/source_object_type_metadata_gaps.csv",
    "analysis/sql_endpoint_object_catalog.csv",
    "analysis/source_object_type_resolution_queue.csv",
    "analysis/source_object_type_resolution_summary.csv",
    "index/deployment_pipelines.csv",
    "index/deployment_pipeline_stages.csv",
    "analysis/deployment_pipeline_workspace_groups.csv",
    "frontend/semantic-lineage/data/lineage-explorer.json",
    "frontend/semantic-lineage/standalone.html",
    "analysis/visual-validation/playwright-results.json",
    "config/source_migration_map.csv",
]


def get_refresh_metadata(manifest_path, visual_validation_result_path, run_log_directory):
    manifest = None
    if Path(manifest_path).exists():
        try:
            with open(manifest_path, encoding="utf-8-sig") as handle:
                manifest = json.load(handle)
        except (OSError, json.JSONDecodeError):
            manifest = None

    visual = None
    if Path(visual_validation_result_path).exists():
        try:
            with open(visual_validation_result_path, encoding="utf-8-sig") as handle:
                visual_json = json.load(handle)
            stats = visual_json.get("stats", {}) or {}
            duration = stats.get("duration")
            visual = {
                "result_path": get_relative_path_text(visual_validation_result_path),
                "start_time": stats.get("startTime"),
                "duration_seconds": round(float(duration) / 1000, 2) if duration else None,
                "expected": stats.get("expected"),
                "skipped": stats.get("skipped"),
                "unexpected": stats.get("unexpected"),
                "flaky": stats.get("flaky"),
            }
        except (OSError, json.JSONDecodeError, TypeError, ValueError):
            visual = None

    latest_log = get_latest_run_log(run_log_directory)
    steps = (manifest.get("steps") if manifest else None) or []
    failed_steps = [step for step in steps if step.get("status") != "completed"]

    return {
        "status_generated_at": datetime.now().replace(microsecond=0).isoformat(),
        "manifest_path": get_relative_path_text(manifest_path),
        "manifest_found": bool(manifest),
        "latest_run_log": get_relative_path_text(str(latest_log)) if latest_log else "",
        "latest_run_mode": manifest.get("mode", "") if manifest else "",
        "latest_run_auth_method": manifest.get("auth_method", "") if manifest else "",
        "latest_run_started_at": manifest.get("started_at", "") if manifest else "",
        "latest_run_ended_at": manifest.get("ended_at", "") if manifest else "",
        "latest_run_duration_seconds": manifest.get("duration_seconds") if manifest else None,
        "latest_run_visual_validation": bool(manifest.get("run_visual_validation")) if manifest else False,
        "latest_run_status": "unknown" if not manifest else ("failed" if failed_steps else "completed"),
        "step_count": len(steps),
        "failed_step_count": len(failed_steps),
        "visual_validation": visual,
        "artifacts": get_file_freshness(ARTIFACT_PATHS),
        "commands": [
            {"id": "local-artifacts", "command": "pwsh -NoLogo -File backend/scripts/99_refresh_lineage_project.ps1 -Mode local-artifacts", "external_systems": "None"},
            {"id": "local-artifacts-visual", "command": "pwsh -NoLogo -File backend/scripts/99_refresh_lineage_project.ps1 -Mode local-artifacts -RunVisualValidation", "external_systems": "None"},
            {"id": "read-only-inventory", "command": "pwsh -NoLogo -File backend/scripts/99_refresh_lineage_project.ps1 -Mode read-only-inventory -AuthMethod azure-cli", "external_systems": "Fabric REST read-only"},
            {"id": "full-read-only", "command": "pwsh -NoLogo -File backend/scripts/99_refresh_lineage_project.ps1 -Mode full-read-only -AuthMethod azure-cli", "external_systems": "Fabric REST and Power BI REST read-only"},
            {"id": "full-read-only-tmdl", "command": "pwsh -NoLogo -File backend/scripts/99_refresh_lineage_project.ps1 -Mode full-read-only -AuthMethod azure-cli -RunTmdlEnrichment -MaxTmdlModels 120", "external_systems": "Fabric REST and Power BI REST read-only"},
        ],
        "safety_note": "The static HTML does not execute commands or modify Fabric. Final approval and execution are human-controlled.",
    }


# ---------------------------------------------------------------------------
# Fabric placeholder path resolution ({TOKEN}/tables/schema/object)
# ---------------------------------------------------------------------------

def convert_fabric_token_part(value):
    upper = (value or "").upper()
    if not upper:
        return ""
    if upper in FABRIC_TOKEN_WORDS:
        return FABRIC_TOKEN_WORDS[upper]
    if upper in FABRIC_TOKEN_ACRONYMS:
        return upper
    if value == upper:
        return value.lower().capitalize()
    return value


def convert_fabric_path_token_to_name(token):
    clean = re.sub(r"[{}]", "", token or "")
    clean = re.sub(r"_+", "_", clean).strip("_")
    if not clean:
        return "Unresolved_Lakehouse"
    upper_clean = clean.upper()
    for suffix in PLACEHOLDER_SUFFIXES:
        if upper_clean.endswith(suffix):
            clean = clean[: len(clean) - len(suffix)]
            break
    parts = [p for p in clean.split("_") if p]
    if parts and parts[0].upper() == "LH":
        body = "_".join(convert_fabric_token_part(p) for p in parts[1:])
        return f"LH_{body}" if body else "LH_Unresolved"
    rendered = "_".join(convert_fabric_token_part(p) for p in parts)
    return rendered if rendered else "Unresolved_Lakehouse"


PLACEHOLDER_PATTERN = re.compile(r"^\{[A-Za-z0-9_]+\}/")
PLACEHOLDER_TOKEN_PATH = re.compile(r"^\{(?P<token>[A-Za-z0-9_]+)\}/(?P<path>.+)$")


def convert_fabric_placeholder_object(source_type, source_database, schema_name, object_name, label):
    candidate = ""
    for value in (object_name, label):
        if value and PLACEHOLDER_PATTERN.match(value):
            candidate = value
            break

    def unchanged():
        display = label if label else (f"{schema_name}.{object_name}" if schema_name and object_name else object_name)
        return {
            "changed": False,
            "source_type": source_type,
            "source_database": source_database,
            "schema_name": schema_name,
            "object_name": object_name,
            "label": label,
            "display": display,
        }

    match = PLACEHOLDER_TOKEN_PATH.match(candidate) if candidate else None
    if not match:
        return unchanged()

    lakehouse_name = convert_fabric_path_token_to_name(match.group("token"))
    raw_path = match.group("path").strip("/")
    path_parts = [re.sub(r"^[\s`\"'\[\]]+", "", re.sub(r"[\s`\"'\[\]]+$", "", part)) for part in raw_path.split("/")]
    path_parts = [p for p in path_parts if p]
    if not path_parts:
        return unchanged()

    if path_parts[0].lower() == "files":
        file_object = "/".join(path_parts[1:]) if len(path_parts) > 1 else "Files"
        file_display = f"{lakehouse_name}/Files" if file_object == "Files" else f"{lakehouse_name}/Files/{file_object}"
        return {
            "changed": True,
            "source_type": "File",
            "source_database": lakehouse_name,
            "schema_name": "",
            "object_name": file_object,
            "label": file_display,
            "display": file_display,
        }

    if path_parts[0].lower() == "tables":
        path_parts = path_parts[1:]
    if len(path_parts) >= 2:
        normalized_schema = path_parts[-2]
        normalized_object = path_parts[-1]
    else:
        normalized_schema = ""
        normalized_object = path_parts[0]
    display = ".".join(v for v in (lakehouse_name, normalized_schema, normalized_object) if v)
    label_out = f"{normalized_schema}.{normalized_object}" if normalized_schema else normalized_object
    return {
        "changed": True,
        "source_type": "LakehouseTable",
        "source_database": lakehouse_name,
        "schema_name": normalized_schema,
        "object_name": normalized_object,
        "label": label_out,
        "display": display,
    }


# ---------------------------------------------------------------------------
# Object type resolution (override > manual > metadata > sharepoint > automatic)
# ---------------------------------------------------------------------------

def new_object_type_key(source_type, source_server, source_database, schema_name, object_name):
    type_part = normalize_key(source_type) if source_type else "*"
    return "|".join([type_part, normalize_key(source_server), normalize_key(source_database), normalize_key(schema_name), normalize_key(object_name)])


def add_object_type_resolver(index_map, source, row, object_type):
    source_type = get_field(row, ["source_type", "source_system"])
    source_server = get_field(row, ["source_server", "server"])
    source_database = get_field(row, ["source_database", "database_name", "database"])
    schema_name = get_field(row, ["schema_name", "source_schema"])
    object_name = get_field(row, ["object_name", "source_object"])

    placeholder = convert_fabric_placeholder_object(source_type, source_database, schema_name, object_name, "")
    if placeholder["changed"]:
        source_type = placeholder["source_type"]
        source_database = placeholder["source_database"]
        schema_name = placeholder["schema_name"]
        object_name = placeholder["object_name"]

    normalized_type = normalize_object_type(object_type)
    if not (source_server or source_database or object_name) or not is_exact_object_type(normalized_type):
        return

    keys = list(dict.fromkeys([
        new_object_type_key(source_type, source_server, source_database, schema_name, object_name),
        new_object_type_key("", source_server, source_database, schema_name, object_name),
    ]))
    for key in keys:
        existing = index_map.get(key)
        if existing and existing["object_type"] != normalized_type:
            index_map[key] = {
                "object_type": "unknown",
                "source": f"{source}_conflict",
                "confidence": "unknown",
                "evidence": "Conflicting object type evidence for this source object.",
            }
            continue
        index_map[key] = {
            "object_type": normalized_type,
            "source": source,
            "confidence": get_field(row, ["confidence", "object_type_confidence"]),
            "evidence": get_field(row, ["evidence"]),
        }


def resolve_source_object_type(type_maps, source_type, source_server, source_database, schema_name, object_name, raw_object_type):
    keys = list(dict.fromkeys([
        new_object_type_key(source_type, source_server, source_database, schema_name, object_name),
        new_object_type_key("", source_server, source_database, schema_name, object_name),
    ]))

    for index_map in type_maps:
        for key in keys:
            found = index_map.get(key)
            if found and is_exact_object_type(found["object_type"]):
                return found

    normalized_raw = normalize_object_type(raw_object_type)
    if normalized_raw == "table_or_view":
        return {
            "object_type": normalized_raw,
            "source": "tmdl_lookup_pending",
            "confidence": "confirmed",
            "evidence": "TMDL Schema/Item confirms the object name but not whether the SQL object is a table or view.",
        }
    if normalized_raw == "native_query_object":
        return {
            "object_type": normalized_raw,
            "source": "native_query_pending",
            "confidence": "likely",
            "evidence": "Native query parsing found an object reference, but the exact SQL object type requires metadata review.",
        }
    return {"object_type": normalized_raw, "source": "automatic_candidate", "confidence": "", "evidence": ""}


# ---------------------------------------------------------------------------
# Qualified-name parsing
# ---------------------------------------------------------------------------

def get_item_name_from_qualified_name(qualified_name):
    if not qualified_name:
        return ""
    return qualified_name.split(" / ")[-1]


def get_item_type_from_qualified_name(qualified_name):
    parts = (qualified_name or "").split(" / ")
    return parts[1] if len(parts) >= 3 else ""


def get_workspace_name_from_qualified_name(qualified_name):
    if not qualified_name or qualified_name.startswith("External Connection /"):
        return ""
    parts = qualified_name.split(" / ")
    return parts[0] if len(parts) >= 3 else ""


# Connection display name -> (server, database), built in main() from
# index/fabric_connections.csv (69_discover_fabric_connections.ps1). Cloud
# connections frequently surface in item dependencies as JUST their display
# name ("External Connection / SQL / LH_ContosoTicketing_Silver") -- without
# this, that label masquerades as a database and the read can never be tied
# to the real lakehouse endpoint behind the connection.
CONNECTION_DETAILS_BY_NAME = {}


def get_external_connection_parts(qualified_name):
    parts = qualified_name.split(" / ", 2)
    source_type = parts[1] if len(parts) >= 2 else "Unknown"
    connection_text = parts[2] if len(parts) >= 3 else qualified_name
    server = ""
    database = ""
    object_name = ""
    resolved_from_connection_name = False

    if ";" in connection_text:
        connection_parts = connection_text.split(";")
        server = connection_parts[0]
        if len(connection_parts) >= 2:
            database = connection_parts[1]
        if len(connection_parts) >= 3:
            object_name = ";".join(connection_parts[2:])
    elif source_type == "SharePoint":
        server = connection_text
        database = "SharePoint"
    else:
        database = connection_text
        resolved = CONNECTION_DETAILS_BY_NAME.get(ci_lower(connection_text))
        if resolved:
            server, database = resolved
            resolved_from_connection_name = True

    return {
        "source_type": source_type,
        "source_server": server,
        "source_database": database,
        "source_object": object_name,
        # When the server/database came from the connection catalog, keep
        # the connection's own display name as the label -- that is the name
        # people recognize in Fabric's UI.
        "label": connection_text if resolved_from_connection_name else (database if database else connection_text),
    }


# ---------------------------------------------------------------------------
# Execution / migration summaries
# ---------------------------------------------------------------------------

DURATION_PATTERN = re.compile(r"^\d+(\.\d+)?$")
INT_PATTERN = re.compile(r"^-?\d+$")


# No real Fabric notebook/pipeline/CopyJob run takes 24+ hours -- a value
# that large is corrupted instrumentation (e.g. a stored duration of several
# weeks against start/end timestamps showing the run actually took
# minutes), not a real long-running job. Drop it before it reaches an
# average -- a single such row can drag a whole tenant's Planning
# "critical path" to hundreds of hours.
MAX_REALISTIC_DURATION_SECONDS = 24 * 60 * 60


def median_seconds(values):
    if not values:
        return None
    ordered = sorted(values)
    count = len(ordered)
    mid = count // 2
    if count % 2 == 0:
        return round((ordered[mid - 1] + ordered[mid]) / 2, 2)
    return round(ordered[mid], 2)


def new_execution_summary(rows):
    schedule_rows = [r for r in rows if r.get("record_type") == "schedule"]
    job_rows = [r for r in rows if r.get("record_type") == "job_instance"]
    completed_durations = [
        float(r["duration_seconds"])
        for r in job_rows
        if r.get("duration_seconds") and DURATION_PATTERN.match(r["duration_seconds"]) and r.get("status") == "Completed"
    ]
    completed_durations = [d for d in completed_durations if 0 < d < MAX_REALISTIC_DURATION_SECONDS]
    avg_duration = round(sum(completed_durations) / len(completed_durations), 2) if completed_durations else None
    median_duration = median_seconds(completed_durations)
    dated_jobs = [r for r in job_rows if r.get("start_time")]
    latest = max(dated_jobs, key=lambda r: r["start_time"]) if dated_jobs else None

    return {
        "schedules": len(schedule_rows),
        "enabled_schedules": sum(1 for r in schedule_rows if r.get("schedule_enabled") == "True"),
        "disabled_schedules": sum(1 for r in schedule_rows if r.get("schedule_enabled") == "False"),
        "scheduled_times": "; ".join(unique_ci_preserve_order(r.get("scheduled_time", "") for r in schedule_rows)),
        "schedule_frequency": "; ".join(unique_ci_preserve_order(r.get("schedule_frequency", "") for r in schedule_rows)),
        "runs": len(job_rows),
        "completed_runs": sum(1 for r in job_rows if r.get("status") == "Completed"),
        "failed_runs": sum(1 for r in job_rows if r.get("status") == "Failed"),
        "avg_duration_seconds": avg_duration,
        "median_duration_seconds": median_duration,
        "latest_start": latest.get("start_time", "") if latest else "",
        "latest_status": latest.get("status", "") if latest else "",
    }


def get_migration_info(source_type, server, database, migration_by_key):
    key = normalize_key(f"{server}|{database}")
    candidates = migration_by_key.get(key, [])
    matches = [
        row
        for row in candidates
        if (not get_field(row, ["source_system"])) or normalize_key(get_field(row, ["source_system"])) == normalize_key(source_type)
    ]
    equivalents = unique_ci_preserve_order(
        " / ".join(v for v in (row.get("fabric_workspace", ""), row.get("fabric_item_type", ""), row.get("fabric_item_name", ""), row.get("fabric_object_name", "")) if v)
        for row in matches
    )
    return {
        "count": len(matches),
        "status": "; ".join(unique_ci_preserve_order(row.get("mapping_status", "") for row in matches)),
        "confidence": "; ".join(unique_ci_preserve_order(row.get("confidence", "") for row in matches)),
        "fabric_equivalent": "; ".join(sorted(equivalents, key=ci_lower)),
    }


# Fabric SQL-analytics-endpoint host -> real workspace name, built in main()
# from the sql_endpoint_object_catalog rows (each carries the endpoint host it
# was cataloged through plus the workspace that owns it). An External SQL
# connection like "<host>.datawarehouse.fabric.microsoft.com;LH_X" is really a
# read of the Fabric lakehouse/warehouse "LH_X" in that workspace -- without
# this mapping the frontend cannot tie the model's read to the very lakehouse
# the loading notebooks write, because the host string appears nowhere else.
# Hosts that ambiguously map to more than one workspace are stored as "" and
# treated as unresolved.
SQL_ENDPOINT_WORKSPACE_BY_HOST = {}


def new_source_node(dependency, item_by_qualified_name, object_rows, migration_by_key):
    target = dependency["to_qualified_name"]
    source_type = ""
    server = ""
    database = ""
    label = ""
    item_type = ""
    workspace_name = ""
    fabric_store_workspace = ""

    if target.startswith("External Connection /"):
        parts = get_external_connection_parts(target)
        source_type = parts["source_type"]
        server = parts["source_server"]
        database = parts["source_database"]
        label = parts["label"]
        item_type = "External"
        if server:
            fabric_store_workspace = SQL_ENDPOINT_WORKSPACE_BY_HOST.get(ci_lower(server), "") or ""
    elif target in item_by_qualified_name:
        target_item = item_by_qualified_name[target]
        item_type = target_item.get("item_type", "")
        label = target_item.get("item_name", "")
        source_type = "Fabric" if item_type in ("Lakehouse", "Warehouse", "SQLEndpoint") else item_type
        server = target_item.get("workspace_name", "")
        database = target_item.get("item_name", "")
        workspace_name = target_item.get("workspace_name", "")
    else:
        label = get_item_name_from_qualified_name(target)
        item_type = get_item_type_from_qualified_name(target)
        source_type = item_type if item_type else "Unknown"
        database = label
        workspace_name = get_workspace_name_from_qualified_name(target)

    migration = get_migration_info(source_type, server, database, migration_by_key)
    return {
        "id": deterministic_id("source", f"{source_type}|{server}|{database}|{label}"),
        "label": label,
        "type": "source",
        "source_type": source_type,
        "item_type": item_type,
        "workspace_name": workspace_name,
        "qualified_name": target,
        "server": server,
        "database": database,
        # Resolved owner workspace when `server` is a known Fabric SQL-
        # analytics-endpoint host: the store is really "<workspace>'s
        # lakehouse/warehouse named <database>", which is what planning's
        # store unification needs to connect models to the notebooks that
        # load them. Empty when the host is unknown or genuinely external.
        "fabric_store_workspace": fabric_store_workspace,
        "confidence": dependency.get("confidence", ""),
        "evidence": dependency.get("evidence", ""),
        "notes": dependency.get("notes", ""),
        "migration": migration,
        "objects": object_rows,
    }


def build_column_catalog_lookup(column_rows):
    by_full_key = {}
    schemas_by_name_key = {}
    for row in column_rows:
        full_key = (
            normalize_key(row.get("source_server", "")),
            normalize_key(row.get("source_database", "")),
            normalize_key(row.get("schema_name", "")),
            normalize_key(row.get("object_name", "")),
        )
        by_full_key.setdefault(full_key, []).append(row)
        name_key = (full_key[0], full_key[1], full_key[3])
        schemas_by_name_key.setdefault(name_key, set()).add(full_key[2])
    return by_full_key, schemas_by_name_key


def get_columns_for_object_row(object_row, by_full_key, schemas_by_name_key):
    server = object_row.get("server", "")
    database = object_row.get("database", "")
    schema = object_row.get("schema", "")
    object_name = object_row.get("object_name", "")
    if not server or not database or not object_name:
        return []

    full_key = (normalize_key(server), normalize_key(database), normalize_key(schema), normalize_key(object_name))
    if full_key not in by_full_key and not schema:
        # Native-query-parsed candidates often have no schema. Fall back to a
        # schema-agnostic name match only when that name is unambiguous across
        # schemas in the database -- otherwise leave columns off rather than
        # guessing the wrong table.
        name_key = (full_key[0], full_key[1], full_key[3])
        schemas = schemas_by_name_key.get(name_key)
        if schemas and len(schemas) == 1:
            only_schema = next(iter(schemas))
            full_key = (full_key[0], full_key[1], only_schema, full_key[3])

    rows = by_full_key.get(full_key)
    if not rows:
        return []

    def sort_key(row):
        try:
            return int(row.get("column_id", 0) or 0)
        except ValueError:
            return 0

    return [
        {
            "column_name": row.get("column_name", ""),
            "data_type": row.get("data_type", ""),
            "max_length": row.get("max_length", ""),
            "precision": row.get("precision", ""),
            "scale": row.get("scale", ""),
            "is_nullable": row.get("is_nullable", ""),
        }
        for row in sorted(rows, key=sort_key)
    ]


def add_columns_to_source(source, by_full_key, schemas_by_name_key):
    for object_row in source.get("objects", []) or []:
        columns = get_columns_for_object_row(object_row, by_full_key, schemas_by_name_key)
        if columns:
            object_row["columns"] = columns


# A VariableLibrary's own variables -- same "child rows keyed
# by the parent item's qualified_name" shape as the column catalog above,
# just keyed directly by qualified_name instead of a server/database/
# schema/object tuple since a variable belongs to exactly one item.
def build_variable_library_lookup(variable_rows):
    by_qn = {}
    for row in variable_rows:
        by_qn.setdefault(row.get("qualified_name", ""), []).append(
            {
                "variable_name": row.get("variable_name", ""),
                "variable_type": row.get("variable_type", ""),
                "value_set_name": row.get("value_set_name", ""),
                "variable_value": row.get("variable_value", ""),
                "resolved_item_qualified_name": row.get("resolved_item_qualified_name", ""),
                "variable_note": row.get("variable_note", ""),
            }
        )
    return by_qn


# ---------------------------------------------------------------------------
# Object candidate dedupe / lookup helpers
# ---------------------------------------------------------------------------

def get_unique_objects(objects):
    seen = set()
    result = []
    for obj in objects:
        if not obj:
            continue
        key = normalize_key(f"{obj.get('server','')}|{obj.get('database','')}|{obj.get('type','')}|{obj.get('schema','')}|{obj.get('object_name','')}|{obj.get('label','')}")
        if key in seen:
            continue
        seen.add(key)
        result.append(obj)
    return result


def get_source_parts_for_dependency(dependency, item_by_qualified_name):
    target = dependency["to_qualified_name"]
    if target.startswith("External Connection /"):
        return get_external_connection_parts(target)
    if target in item_by_qualified_name:
        target_item = item_by_qualified_name[target]
        return {
            "source_type": target_item.get("item_type", ""),
            "source_server": target_item.get("workspace_name", ""),
            "source_database": target_item.get("item_name", ""),
            "source_object": "",
            "label": target_item.get("item_name", ""),
        }
    return {
        "source_type": get_item_type_from_qualified_name(target),
        "source_server": get_workspace_name_from_qualified_name(target),
        "source_database": get_item_name_from_qualified_name(target),
        "source_object": "",
        "label": get_item_name_from_qualified_name(target),
    }


def get_candidate_objects_for_dependency(dependency, model_objects, objects_by_source, item_by_qualified_name):
    parts = get_source_parts_for_dependency(dependency, item_by_qualified_name)
    local_objects = []
    if model_objects:
        # Fabric's connections API often reports an "External Connection"
        # qualified name with just a database (e.g. "SQL / CONTOSO_SALES_DW",
        # no ";server" segment), so parts["source_server"] ends up empty even
        # though the semantic model's own TMDL definition (parsed into
        # model_objects) does know the real server. Requiring server
        # equality in that case rejected every real object candidate on an
        # empty-vs-populated mismatch. Only require server to match when
        # *both* sides actually have one.
        local_objects = [
            obj
            for obj in model_objects
            if normalize_key(obj.get("database", "")) == normalize_key(parts["source_database"])
            and (
                (not obj.get("server"))
                or (not parts["source_server"])
                or normalize_key(obj.get("server", "")) == normalize_key(parts["source_server"])
            )
        ]
    source_key = normalize_key(f"{parts['source_server']}|{parts['source_database']}")
    global_objects = objects_by_source.get(source_key, []) if source_key else []
    return get_unique_objects(local_objects + global_objects)


# ---------------------------------------------------------------------------
# Manual review source nodes
# ---------------------------------------------------------------------------

def get_manual_source_target(obj):
    if obj.get("source_qualified_name"):
        return obj["source_qualified_name"]
    source_type = obj.get("source_type") or "Manual"
    if obj.get("server") and obj.get("database"):
        return f"External Connection / {source_type} / {obj['server']};{obj['database']}"
    if obj.get("source_name"):
        return f"External Connection / {source_type} / {obj['source_name']}"
    if obj.get("database"):
        return f"External Connection / {source_type} / {obj['database']}"
    return "External Connection / Manual / Reviewed source"


def get_manual_source_nodes_for_item(item, manual_objects, existing_source_deps, item_by_qualified_name, migration_by_key):
    if not manual_objects:
        return []

    existing_targets = set()
    existing_source_keys = set()
    for dep in existing_source_deps:
        if dep.get("to_qualified_name"):
            existing_targets.add(normalize_key(dep["to_qualified_name"]))
        parts = get_source_parts_for_dependency(dep, item_by_qualified_name)
        source_key = normalize_key(f"{parts['source_server']}|{parts['source_database']}")
        if source_key:
            existing_source_keys.add(source_key)

    groups = defaultdict(list)
    group_order = []
    for obj in manual_objects:
        target = get_manual_source_target(obj)
        source_key = normalize_key(f"{obj.get('server','')}|{obj.get('database','')}")
        if normalize_key(target) in existing_targets or (source_key and source_key in existing_source_keys):
            continue
        group_key = normalize_key(f"{target}|{source_key}|{obj.get('source_name','')}")
        if group_key not in groups:
            group_order.append(group_key)
        groups[group_key].append(obj)

    nodes = []
    for group_key in sorted(group_order):
        objects = get_unique_objects(groups[group_key])
        if not objects:
            continue
        target = get_manual_source_target(objects[0])
        confidence_values = unique_ci_preserve_order(o.get("confidence", "") for o in objects)
        if "unknown" in [v.lower() for v in confidence_values]:
            confidence = "unknown"
        elif "likely" in [v.lower() for v in confidence_values]:
            confidence = "likely"
        else:
            confidence = "confirmed"
        evidence_text = "; ".join(unique_ci_preserve_order(o.get("evidence") or f"Manual review evidence for {o.get('label','')}." for o in objects))

        dependency = {
            "to_qualified_name": target,
            "confidence": confidence,
            "evidence": f"Manual lineage review for {item['qualified_name']}: {evidence_text}",
        }
        nodes.append(new_source_node(dependency, item_by_qualified_name, objects, migration_by_key))
    return nodes


# ---------------------------------------------------------------------------
# Notebook super-lineage (static code parse)
# ---------------------------------------------------------------------------

def convert_notebook_lineage_confidence(row):
    confidence = get_field(row, ["confidence"])
    unresolved = get_field(row, ["unresolved_variables"])
    if unresolved:
        return "likely"
    if confidence == "parsed":
        return "confirmed"
    if confidence in ("confirmed", "likely", "unknown"):
        return confidence
    return "likely"


def get_notebook_usage_type(direction):
    if direction == "write":
        return "writes_to"
    if direction == "execute":
        return "executes"
    return "reads_from"


def get_notebook_object_type(row):
    source_type = get_field(row, ["source_type"])
    direction = get_field(row, ["direction"])
    object_name = get_field(row, ["object_name"])
    if source_type == "File":
        return "file"
    if direction == "execute":
        return "stored_procedure"
    if object_name == "*":
        return "schema"
    if source_type == "LakehouseTable":
        return "table"
    return "table_or_view"


def new_notebook_super_lineage_object_node(row):
    schema_name = get_field(row, ["schema_name"])
    object_name = get_field(row, ["object_name"])
    display = get_field(row, ["object_display_name"])
    source_type = get_field(row, ["source_type"])
    source_database = get_field(row, ["source_database"])

    placeholder = convert_fabric_placeholder_object(source_type, source_database, schema_name, object_name, display)
    if placeholder["changed"]:
        source_type = placeholder["source_type"]
        source_database = placeholder["source_database"]
        schema_name = placeholder["schema_name"]
        object_name = placeholder["object_name"]
        display = placeholder["display"]

    if schema_name and object_name:
        label = f"{schema_name}.{object_name}"
    elif object_name:
        label = object_name
    else:
        label = display

    confidence = convert_notebook_lineage_confidence(row)
    direction = get_field(row, ["direction"])

    if source_type == "File":
        node_type = "file"
    elif direction == "execute":
        node_type = "stored_procedure"
    elif object_name == "*":
        node_type = "schema"
    elif source_type == "LakehouseTable":
        node_type = "table"
    else:
        node_type = get_notebook_object_type(row)

    unresolved = get_field(row, ["unresolved_variables"])
    evidence_parts = [
        "Notebook code static parse.",
        get_field(row, ["evidence"]),
        f"Unresolved variables: {unresolved}" if unresolved else "",
    ]
    evidence = " ".join(p for p in evidence_parts if p)

    return {
        "label": label,
        "type": node_type,
        "raw_object_type": source_type,
        "object_type_source": "notebook_static_parse",
        "object_type_confidence": confidence,
        "object_type_evidence": "Notebook definition parsed locally.",
        "schema": schema_name,
        "object_name": object_name,
        "semantic_table": "",
        "database": source_database,
        "server": "",
        "source_name": source_database,
        "source_type": source_type,
        "source_qualified_name": "",
        "usage_type": get_notebook_usage_type(direction),
        "confidence": confidence,
        "evidence": evidence,
        "definition_path": get_field(row, ["definition_path"]),
        "activity_name": get_field(row, ["dataframe"]),
        "activity_type": get_field(row, ["operation"]),
        "evidence_origin": "notebook_super_lineage",
    }


def get_notebook_source_label(direction, source_type, database):
    if database:
        return database
    if direction == "write":
        return "Destino pendiente"
    if direction == "execute":
        return "Objetos ejecutados"
    if source_type == "File":
        return "Archivos"
    return "Origen pendiente"


def new_notebook_super_lineage_sources(item, notebook_super_objects_by_item):
    if item.get("item_type") != "Notebook":
        return []
    rows = notebook_super_objects_by_item.get(item["qualified_name"])
    if not rows:
        return []

    groups = defaultdict(list)
    group_order = []
    for row in rows:
        direction = get_field(row, ["direction"])
        source_type = get_field(row, ["source_type"])
        database = get_field(row, ["source_database"])
        key = normalize_key(f"{direction}|{source_type}|{database}")
        if key not in groups:
            group_order.append(key)
        groups[key].append(row)

    nodes = []
    for key in sorted(group_order):
        group_rows = groups[key]
        if not group_rows:
            continue
        first = group_rows[0]
        direction = get_field(first, ["direction"])
        source_type = get_field(first, ["source_type"])
        database = get_field(first, ["source_database"])
        objects = get_unique_objects([new_notebook_super_lineage_object_node(r) for r in group_rows])
        confidence_values = [v.lower() for v in unique_ci_preserve_order(o.get("confidence", "") for o in objects)]
        if "unknown" in confidence_values:
            confidence = "unknown"
        elif "likely" in confidence_values:
            confidence = "likely"
        else:
            confidence = "confirmed"
        label = get_notebook_source_label(direction, source_type, database)
        nodes.append(
            {
                "id": deterministic_id("notebook-source", f"{item['qualified_name']}|{direction}|{source_type}|{database}"),
                "label": label,
                "type": "source",
                "source_type": source_type if source_type else "NotebookParse",
                "item_type": "NotebookObjectLineage",
                "workspace_name": item.get("workspace_name", ""),
                "qualified_name": f"{item['qualified_name']} / {direction} / {label}",
                "server": item.get("workspace_name", "") if database else "",
                "database": database if database else "",
                "confidence": confidence,
                "evidence": f"Notebook source/destination objects parsed from downloaded definition. Direction: {direction}.",
                "planning_role": "output" if direction == "write" else "input",
                "objects": objects,
            }
        )
    return nodes


def get_notebook_super_lineage_summary(item, notebook_super_objects_by_item, notebook_super_flows_by_item):
    if item.get("item_type") != "Notebook":
        return None
    object_rows = notebook_super_objects_by_item.get(item["qualified_name"], [])
    flow_rows = notebook_super_flows_by_item.get(item["qualified_name"], [])
    if not object_rows and not flow_rows:
        return None
    return {
        "object_count": len(object_rows),
        "source_count": sum(1 for r in object_rows if r.get("direction") == "read"),
        "destination_count": sum(1 for r in object_rows if r.get("direction") == "write"),
        "execute_count": sum(1 for r in object_rows if r.get("direction") == "execute"),
        "flow_count": len(flow_rows),
    }


# ---------------------------------------------------------------------------
# Planning info
# ---------------------------------------------------------------------------

def get_planning_info(item, indices):
    qualified_name = item["qualified_name"]
    critical = indices["critical_by_qn"].get(qualified_name)
    failure = indices["failure_by_qn"].get(qualified_name)
    schedule_review = indices["schedule_review_by_qn"].get(qualified_name)
    group = indices["orchestration_group_by_qn"].get(qualified_name)
    parallel_count = indices["parallel_counts_by_qn"].get(qualified_name, 0)

    hints = []
    for source in (critical, failure, schedule_review, group):
        if source and source.get("recommendation_hint"):
            hints.append(source["recommendation_hint"])
    if parallel_count > 0:
        hints.append("Candidate parallel execution exists; validate reads/writes before parallel execution.")

    return {
        "critical_path": bool(critical),
        "critical_rank": critical.get("rank", "") if critical else "",
        "failure_hotspot": bool(failure),
        "failure_rank": failure.get("rank", "") if failure else "",
        "failure_rate": failure.get("failure_rate", "") if failure else "",
        "schedule_review": bool(schedule_review),
        "enabled_schedules": schedule_review.get("enabled_schedules", "") if schedule_review else "",
        "disabled_schedules": schedule_review.get("disabled_schedules", "") if schedule_review else "",
        "parallel_candidate_count": parallel_count,
        "orchestration_group": bool(group),
        "executes_count": group.get("executes_count", "") if group else "",
        "recommendation_hint": " | ".join(unique_ci_preserve_order(hints)),
    }


# The 5 "core" modes keep their established plural key names -- lots of
# existing code (the frontend's rawModeItems, the notebook-super-lineage
# merge loop, impact category logic, etc.) already depends on these exact
# strings, so they must not change. Every OTHER item type that shows up in
# the tenant gets a mode key too now (see the governance-tool ask: every
# item type should be its own browsable/explorable section, not just
# these 5) -- keyed by its own lowercased item_type instead of a hand-
# picked plural, so a brand-new Fabric item type nobody has seen yet still
# gets a working (if grammatically plain) mode key with zero code changes,
# rather than silently falling through "all" only.
CORE_MODE_KEY_BY_ITEM_TYPE = {
    "SemanticModel": "semantic",
    "Notebook": "notebooks",
    "CopyJob": "copyjobs",
    "DataPipeline": "pipelines",
    "Dataflow": "dataflows",
    # Every workspace ALSO has its own top-level "environment" field (its
    # QA/PROD/DEV stage, from workspaces.csv) -- the generic ci_lower()
    # fallback below would otherwise map Fabric's "Environment" item type
    # (a Spark compute environment item) to that exact same key, silently
    # overwriting the workspace's stage string with a list of items on
    # every workspace that has one. Found live: this crashed
    # 17_build_object_impact_index_fast.py once it started iterating every
    # real mode instead of a fixed 4-type subset that happened to avoid the
    # collision by omission, not by design.
    "Environment": "environments",
}


def mode_key_for_item_type(item_type):
    return CORE_MODE_KEY_BY_ITEM_TYPE.get(item_type, ci_lower(item_type))


# ---------------------------------------------------------------------------
# Item node construction (the expensive part -- memoized by qualified_name)
# ---------------------------------------------------------------------------

def build_item_node(item, ctx, memo):
    qualified_name = item["qualified_name"]
    cached = memo.get(qualified_name)
    if cached is not None:
        return cached

    item_by_qn = ctx["item_by_qn"]
    migration_by_key = ctx["migration_by_key"]
    objects_by_model = ctx["objects_by_model"]
    objects_by_source = ctx["objects_by_source"]
    manual_objects_by_item = ctx["manual_objects_by_item"]
    notebook_super_objects_by_item = ctx["notebook_super_objects_by_item"]
    notebook_super_flows_by_item = ctx["notebook_super_flows_by_item"]
    analysis_by_qn = ctx["analysis_by_qn"]
    executions_by_qn = ctx["executions_by_qn"]
    dependencies_by_from = ctx["dependencies_by_from"]
    activities_by_pipeline_and_target = ctx["activities_by_pipeline_and_target"]
    variables_by_qn = ctx["variables_by_qn"]

    analysis = analysis_by_qn.get(qualified_name)
    execution_rows = executions_by_qn.get(qualified_name, [])
    deps = dependencies_by_from.get(qualified_name, [])

    source_deps = [d for d in deps if d.get("relationship_type") == "depends_on"]
    execute_deps = [d for d in deps if d.get("relationship_type") == "executes"]
    report_deps = [d for d in deps if d.get("relationship_type") == "serves_report"]
    model_deps = [d for d in deps if d.get("relationship_type") == "uses_model"]

    objects = objects_by_model.get(qualified_name, [])
    manual_objects = manual_objects_by_item.get(qualified_name, [])
    manual_source_nodes = get_manual_source_nodes_for_item(item, manual_objects, source_deps, item_by_qn, migration_by_key)
    notebook_super_source_nodes = new_notebook_super_lineage_sources(item, notebook_super_objects_by_item)

    sources = []
    for dep in source_deps:
        candidate_objects = get_candidate_objects_for_dependency(dep, objects, objects_by_source, item_by_qn)
        sources.append(new_source_node(dep, item_by_qn, candidate_objects, migration_by_key))
    sources.extend(manual_source_nodes)
    sources.extend(notebook_super_source_nodes)

    reports = []
    for dep in report_deps:
        target = dep.get("to_qualified_name")
        if target not in item_by_qn:
            continue
        report_item = item_by_qn[target]
        reports.append(
            {
                "label": report_item.get("item_name", ""),
                "item_type": report_item.get("item_type", ""),
                "workspace_name": report_item.get("workspace_name", ""),
                "qualified_name": report_item.get("qualified_name", ""),
                "confidence": dep.get("confidence", ""),
                "evidence": dep.get("evidence", ""),
                "notes": dep.get("notes", ""),
            }
        )

    executes = []
    for dep in execute_deps:
        target = dep.get("to_qualified_name")
        target_item = item_by_qn.get(target)
        target_notebook_sources = new_notebook_super_lineage_sources(target_item, notebook_super_objects_by_item) if target_item and target_item.get("item_type") == "Notebook" else []
        executes.append(
            {
                "label": target_item.get("item_name", "") if target_item else get_item_name_from_qualified_name(target),
                "item_type": target_item.get("item_type", "") if target_item else get_item_type_from_qualified_name(target),
                "workspace_name": target_item.get("workspace_name", "") if target_item else get_workspace_name_from_qualified_name(target),
                "qualified_name": target,
                "confidence": dep.get("confidence", ""),
                "evidence": dep.get("evidence", ""),
                "notes": dep.get("notes", ""),
                "execution": new_execution_summary(executions_by_qn[target]) if target_item and target in executions_by_qn else None,
                "sources": target_notebook_sources,
                "notebook_super_lineage": get_notebook_super_lineage_summary(target_item, notebook_super_objects_by_item, notebook_super_flows_by_item) if target_item else None,
                "invocation_activities": activities_by_pipeline_and_target.get((qualified_name, target), []),
            }
        )

    # A lightweight reference, not a full copy: the model's own full node
    # (sources/columns/analysis/execution/planning included) already gets
    # built once, separately, as that model's own entry in its type bucket
    # (e.g. workspace.semantic[]) -- embedding that same full node again
    # here, once per report/notebook/etc. that uses it, used to duplicate
    # potentially hundreds of KB of nested source-object/column data per
    # reference (a real semantic model with a couple of large SQL sources
    # can carry 400KB+ of embedded columns on its own). Found live
    # This was ~50% of a very large lineage-explorer.json a
    # tenant-wide scan produced, on top of the (separately fixed) "all"
    # duplication. app.js resolves qualified_name back to the model's own
    # full node client-side once, right after parsing (see
    # resolveEmbeddedItemReferences) -- confidence/evidence/notes are kept
    # here because they describe THIS relationship (this report's use of
    # the model), not the model itself, so they can't come from the
    # resolved node.
    models = []
    for dep in model_deps:
        target = dep.get("to_qualified_name")
        if target not in item_by_qn:
            continue
        model_item = item_by_qn[target]
        models.append(
            {
                "label": model_item.get("item_name", ""),
                "item_type": model_item.get("item_type", ""),
                "workspace_name": model_item.get("workspace_name", ""),
                "environment": model_item.get("workspace_environment", ""),
                "qualified_name": model_item.get("qualified_name", ""),
                "confidence": dep.get("confidence", ""),
                "evidence": dep.get("evidence", ""),
                "notes": dep.get("notes", ""),
            }
        )

    node = {
        "label": item.get("item_name", ""),
        "item_type": item.get("item_type", ""),
        "workspace_name": item.get("workspace_name", ""),
        "environment": item.get("workspace_environment", ""),
        "qualified_name": qualified_name,
        "description": item.get("description", ""),
        "sensitivity_label": item.get("sensitivity_label", ""),
        "technical_id": item.get("technical_id", ""),
        "default_identity": item.get("default_identity", ""),
        "tags": item.get("tags", ""),
        "analysis": (
            {"status": analysis.get("analysis_status", ""), "notes": analysis.get("notes", ""), "evidence": analysis.get("evidence", "")}
            if analysis
            else None
        ),
        "execution": new_execution_summary(execution_rows),
        "planning": get_planning_info(item, ctx["planning_indices"]),
        "reports": reports,
        "models": models,
        "sources": sources,
        "executes": executes,
        "dependency_count": len(deps),
        "notebook_super_lineage": get_notebook_super_lineage_summary(item, notebook_super_objects_by_item, notebook_super_flows_by_item),
        "variables": variables_by_qn.get(qualified_name, []),
    }
    memo[qualified_name] = node
    return node


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspaces-path", default=str(REPO_ROOT / "index/workspaces.csv"))
    parser.add_argument("--items-path", default=str(REPO_ROOT / "index/items.csv"))
    parser.add_argument("--dependencies-path", default=str(REPO_ROOT / "index/dependencies.csv"))
    parser.add_argument("--executions-path", default=str(REPO_ROOT / "index/executions.csv"))
    parser.add_argument("--item-analysis-path", default=str(REPO_ROOT / "index/item_analysis.csv"))
    parser.add_argument("--view-candidates-path", default=str(REPO_ROOT / "analysis/semantic_model_view_candidates.csv"))
    parser.add_argument("--manual-object-evidence-path", default=str(REPO_ROOT / "index/manual_lineage_object_evidence.csv"))
    parser.add_argument("--item-object-lineage-candidates-path", default=str(REPO_ROOT / "analysis/item_object_lineage_candidates.csv"))
    parser.add_argument("--control-framework-candidates-path", default=str(REPO_ROOT / "analysis/control_framework_lineage_candidates.csv"))
    parser.add_argument("--pipeline-object-lineage-candidates-path", default=str(REPO_ROOT / "analysis/pipeline_object_lineage_candidates.csv"))
    parser.add_argument("--pipeline-activity-lineage-path", default=str(REPO_ROOT / "analysis/pipeline_activity_lineage.csv"))
    parser.add_argument("--notebook-super-lineage-objects-path", default=str(REPO_ROOT / "analysis/notebook_super_lineage_objects.csv"))
    parser.add_argument("--notebook-super-lineage-flows-path", default=str(REPO_ROOT / "analysis/notebook_super_lineage_flows.csv"))
    parser.add_argument("--object-type-overrides-path", default=str(REPO_ROOT / "index/source_object_type_overrides.csv"))
    parser.add_argument("--object-type-metadata-evidence-path", default=str(REPO_ROOT / "analysis/source_object_type_metadata_evidence.csv"))
    parser.add_argument("--sql-endpoint-catalog-path", default=str(REPO_ROOT / "analysis/sql_endpoint_object_catalog.csv"))
    parser.add_argument("--fabric-connections-path", default=str(REPO_ROOT / "index/fabric_connections.csv"))
    parser.add_argument("--object-column-catalog-path", default=str(REPO_ROOT / "analysis/object_column_catalog.csv"))
    parser.add_argument("--variable-library-catalog-path", default=str(REPO_ROOT / "analysis/variable_library_catalog.csv"))
    parser.add_argument("--sharepoint-object-type-evidence-path", default="")
    parser.add_argument("--deployment-pipelines-path", default=str(REPO_ROOT / "index/deployment_pipelines.csv"))
    parser.add_argument("--deployment-pipeline-stages-path", default=str(REPO_ROOT / "index/deployment_pipeline_stages.csv"))
    parser.add_argument("--deployment-pipeline-groups-path", default=str(REPO_ROOT / "analysis/deployment_pipeline_workspace_groups.csv"))
    parser.add_argument("--migration-map-path", default=str(REPO_ROOT / "config/source_migration_map.csv"))
    parser.add_argument("--output-json-path", default=str(REPO_ROOT / "frontend/semantic-lineage/data/lineage-explorer.json"))
    parser.add_argument("--gap-path", default=str(REPO_ROOT / "analysis/lineage_explorer_gaps.csv"))
    parser.add_argument("--manifest-path", default=str(REPO_ROOT / "analysis/lineage_refresh_manifest.json"))
    parser.add_argument("--run-log-directory", default=str(REPO_ROOT / "runs"))
    parser.add_argument("--visual-validation-result-path", default=str(REPO_ROOT / "analysis/visual-validation/playwright-results.json"))
    parser.add_argument("--critical-path-path", default=str(REPO_ROOT / "analysis/critical_path_candidates.csv"))
    parser.add_argument("--failure-hotspots-path", default=str(REPO_ROOT / "analysis/failure_hotspots.csv"))
    parser.add_argument("--schedule-review-path", default=str(REPO_ROOT / "analysis/schedule_review_candidates.csv"))
    parser.add_argument("--parallelism-candidates-path", default=str(REPO_ROOT / "analysis/parallelism_candidates.csv"))
    parser.add_argument("--orchestration-group-candidates-path", default=str(REPO_ROOT / "analysis/orchestration_group_candidates.csv"))
    parser.add_argument("--git-connections-path", default=str(REPO_ROOT / "index/workspace_git_connections.csv"))
    parser.add_argument("--scan-history-path", default=str(REPO_ROOT / "analysis/single_workspace_scan/history.csv"))
    parser.add_argument("--role-assignments-path", default=str(REPO_ROOT / "index/workspace_role_assignments.csv"))
    args = parser.parse_args()

    for required in (args.workspaces_path, args.items_path, args.dependencies_path, args.executions_path):
        if not Path(required).exists():
            raise SystemExit(f"Required input not found: {required}")

    workspaces = read_csv(args.workspaces_path)
    items = [r for r in read_csv(args.items_path) if r.get("status") == "discovered"]
    dependencies = read_csv(args.dependencies_path)
    executions = read_csv(args.executions_path)
    analysis_rows = read_csv(args.item_analysis_path)
    view_candidates = [r for r in read_csv(args.view_candidates_path) if r.get("object_name")]
    manual_object_evidence_rows = [r for r in read_csv(args.manual_object_evidence_path) if r.get("item_qualified_name") and r.get("object_name")]
    item_object_candidate_rows = [r for r in read_csv(args.item_object_lineage_candidates_path) if r.get("item_qualified_name") and r.get("object_name")]
    pipeline_object_candidate_rows = [r for r in read_csv(args.pipeline_object_lineage_candidates_path) if r.get("item_qualified_name") and r.get("object_name")]
    # Runtime lineage logged by the metadata-driven load framework itself
    # (control.TableStatus rows: real source table -> target table -> the
    # executing notebook; extracted by 70_extract_control_framework_lineage).
    # Same column shape as the static candidates, so it rides the exact same
    # ingestion path -- it fills precisely the writes static parsing records
    # as "Destino pendiente".
    control_framework_candidate_rows = [r for r in read_csv(args.control_framework_candidates_path) if r.get("item_qualified_name") and r.get("object_name")]
    item_object_candidate_rows = item_object_candidate_rows + pipeline_object_candidate_rows + control_framework_candidate_rows
    pipeline_activity_lineage_rows = [r for r in read_csv(args.pipeline_activity_lineage_path) if r.get("pipeline_qualified_name") and r.get("invoked_item_qualified_name")]
    # Unfiltered (includes activities that do not themselves invoke an item,
    # such as Fail/IfCondition/Wait control-flow activities) so the
    # Succeeded/Failed/Completed dependsOn chain between two *invoking*
    # activities can be walked even when a non-invoking activity sits
    # between them.
    pipeline_activity_all_rows = [r for r in read_csv(args.pipeline_activity_lineage_path) if r.get("pipeline_qualified_name") and r.get("activity_name")]
    notebook_super_lineage_object_rows = [r for r in read_csv(args.notebook_super_lineage_objects_path) if r.get("item_qualified_name") and (r.get("object_display_name") or r.get("object_name"))]
    notebook_super_lineage_flow_rows = [r for r in read_csv(args.notebook_super_lineage_flows_path) if r.get("item_qualified_name") and r.get("source_object") and r.get("target_object")]
    object_type_override_rows = [r for r in read_csv(args.object_type_overrides_path) if r.get("object_name") and r.get("object_type")]
    object_type_metadata_evidence_rows = [r for r in read_csv(args.object_type_metadata_evidence_path) if r.get("object_name") and r.get("object_type")]
    sql_endpoint_catalog_rows = [r for r in read_csv(args.sql_endpoint_catalog_path) if r.get("object_name") and r.get("object_type") and get_field(r, ["catalog_status"]) in ("", "confirmed")]
    object_column_catalog_rows = [r for r in read_csv(args.object_column_catalog_path) if r.get("object_name") and r.get("column_name")]
    column_catalog_by_full_key, column_catalog_schemas_by_name_key = build_column_catalog_lookup(object_column_catalog_rows)
    variable_library_rows = [r for r in read_csv(args.variable_library_catalog_path) if r.get("qualified_name") and r.get("variable_name")]
    variables_by_qn = build_variable_library_lookup(variable_library_rows)
    sharepoint_object_type_rows = [r for r in read_csv(args.sharepoint_object_type_evidence_path) if r.get("object_name") and r.get("object_type")] if args.sharepoint_object_type_evidence_path else []
    deployment_pipeline_rows = [r for r in read_csv(args.deployment_pipelines_path) if r.get("deployment_pipeline_id")]
    deployment_pipeline_stage_rows = [r for r in read_csv(args.deployment_pipeline_stages_path) if r.get("deployment_pipeline_id") and r.get("stage_id")]
    deployment_pipeline_group_rows = [r for r in read_csv(args.deployment_pipeline_groups_path) if r.get("deployment_pipeline_id")]
    migration_rows = [r for r in read_csv(args.migration_map_path) if r.get("source_server") or r.get("fabric_item_name")]
    critical_rows = read_csv(args.critical_path_path)
    failure_rows = read_csv(args.failure_hotspots_path)
    schedule_review_rows = read_csv(args.schedule_review_path)
    parallel_rows = read_csv(args.parallelism_candidates_path)
    orchestration_group_rows = read_csv(args.orchestration_group_candidates_path)
    git_connection_rows = read_csv(args.git_connections_path)
    scan_history_rows = read_csv(args.scan_history_path)
    role_assignment_rows = [r for r in read_csv(args.role_assignments_path) if get_field(r, ["status"]) == "discovered"]

    # Governance view of who has access to each workspace and at what
    # role (Admin/Member/Contributor/Viewer) -- see backend/scripts/68_discover_
    # workspace_role_assignments.ps1. Grouped by workspace name so the
    # frontend can both list every principal AND, by matching principal_id
    # against the signed-in session's own object_id, show "your own role
    # here" without a second data source.
    role_assignments_by_workspace_name = defaultdict(list)
    for row in role_assignment_rows:
        role_assignments_by_workspace_name[ci_lower(get_field(row, ["workspace_name"]))].append({
            "principal_id": get_field(row, ["principal_id"]),
            "principal_name": get_field(row, ["principal_name"]),
            "principal_type": get_field(row, ["principal_type"]),
            "role": get_field(row, ["role"]),
        })

    # backend/scripts/67_discover_workspace_git_connections.ps1's output, keyed by
    # workspace name -- the connected repo (if any) shown in the workspace
    # detail panel, plus the sync-icon comparison in the workspace index.
    git_connection_by_workspace_name = {
        ci_lower(get_field(row, ["workspace_name"])): row for row in git_connection_rows
    }
    # The most recent scan that plausibly covered a given workspace: either
    # a scan of that workspace by name, or any full-tenant scan (workspace
    # name "__full_scan__") -- whichever is more recent. Used only to warn
    # "Fabric synced from git more recently than we last scanned this",
    # not as a guarantee that scan actually succeeded for this workspace.
    last_scanned_at_by_workspace_name = {}
    for row in scan_history_rows:
        if get_field(row, ["status"]) not in ("succeeded", "cancelled", "failed"):
            continue
        started_at = get_field(row, ["started_at"])
        if not started_at:
            continue
        row_workspace = get_field(row, ["workspace_name"])
        target_names = [ci_lower(row_workspace)] if row_workspace != "__full_scan__" else [
            ci_lower(get_field(w, ["workspace_name"])) for w in workspaces
        ]
        for name in target_names:
            existing = last_scanned_at_by_workspace_name.get(name)
            if existing is None or started_at > existing:
                last_scanned_at_by_workspace_name[name] = started_at

    # --- object type resolution maps -------------------------------------------------
    object_type_override_map = {}
    manual_object_type_map = {}
    metadata_object_type_map = {}
    sharepoint_object_type_map = {}
    for row in object_type_override_rows:
        add_object_type_resolver(object_type_override_map, "override", row, get_field(row, ["object_type"]))
    for row in manual_object_evidence_rows:
        add_object_type_resolver(manual_object_type_map, "manual_review", row, get_field(row, ["object_type"]))
    for row in object_type_metadata_evidence_rows:
        add_object_type_resolver(metadata_object_type_map, "metadata_readonly", row, get_field(row, ["object_type"]))
    for row in sql_endpoint_catalog_rows:
        add_object_type_resolver(metadata_object_type_map, "sql_endpoint_catalog", row, get_field(row, ["object_type"]))

    # See SQL_ENDPOINT_WORKSPACE_BY_HOST's definition for why this exists.
    # Populated before any build_item_node call so new_source_node sees it.
    endpoint_workspaces_by_host = {}
    for row in sql_endpoint_catalog_rows:
        host = ci_lower(get_field(row, ["source_server"]))
        workspace_name = get_field(row, ["workspace_name"])
        if host and workspace_name and "datawarehouse" in host:
            endpoint_workspaces_by_host.setdefault(host, set()).add(workspace_name)
    for host, names in endpoint_workspaces_by_host.items():
        SQL_ENDPOINT_WORKSPACE_BY_HOST[host] = names.pop() if len(names) == 1 else ""

    # See CONNECTION_DETAILS_BY_NAME's definition for why this exists.
    for row in read_csv(args.fabric_connections_path):
        display_name = ci_lower(get_field(row, ["display_name"]))
        server = get_field(row, ["source_server"])
        database = get_field(row, ["source_database"])
        if display_name and server and database:
            CONNECTION_DETAILS_BY_NAME[display_name] = (server, database)
    for row in sharepoint_object_type_rows:
        add_object_type_resolver(sharepoint_object_type_map, "sharepoint_catalog", row, get_field(row, ["object_type"]))
    type_maps = [object_type_override_map, manual_object_type_map, metadata_object_type_map, sharepoint_object_type_map]

    def resolve_type(source_type, source_server, source_database, schema_name, object_name, raw_object_type):
        return resolve_source_object_type(type_maps, source_type, source_server, source_database, schema_name, object_name, raw_object_type)

    # --- object candidate indices -----------------------------------------------------
    objects_by_model = defaultdict(list)
    objects_by_source = defaultdict(list)
    manual_objects_by_item = defaultdict(list)
    notebook_super_objects_by_item = defaultdict(list)
    notebook_super_flows_by_item = defaultdict(list)

    for row in notebook_super_lineage_object_rows:
        notebook_super_objects_by_item[row["item_qualified_name"]].append(row)
    for row in notebook_super_lineage_flow_rows:
        notebook_super_flows_by_item[row["item_qualified_name"]].append(row)

    def add_source_key_index(node, server, database):
        key = normalize_key(f"{server}|{database}")
        if key:
            objects_by_source[key].append(node)

    for row in item_object_candidate_rows:
        item_qn = get_field(row, ["item_qualified_name", "qualified_name"])
        if not item_qn:
            continue
        source_server = get_field(row, ["source_server", "server"])
        source_database = get_field(row, ["source_database", "database_name", "database"])
        source_name = get_field(row, ["source_name", "source_label"])
        object_name = get_field(row, ["object_name", "source_object"])
        schema_name = get_field(row, ["schema_name", "source_schema"])
        source_type = get_field(row, ["source_type"])
        placeholder = convert_fabric_placeholder_object(source_type, source_database, schema_name, object_name, "")
        if placeholder["changed"]:
            source_type = placeholder["source_type"]
            source_database = placeholder["source_database"]
            schema_name = placeholder["schema_name"]
            object_name = placeholder["object_name"]
            if not source_name:
                source_name = source_database
        object_type = get_field(row, ["object_type"]) or "native_query_object"
        confidence = get_field(row, ["confidence"]) or "likely"

        type_resolution = resolve_type(source_type, source_server, source_database, schema_name, object_name, object_type)
        if is_exact_object_type(object_type) and type_resolution["source"] not in ("override", "manual_review"):
            type_resolution = {
                "object_type": normalize_object_type(object_type),
                "source": "definition_extraction",
                "confidence": confidence,
                "evidence": get_field(row, ["evidence"]),
            }
        object_type_evidence = type_resolution.get("evidence", "")

        object_node = {
            "label": f"{schema_name}.{object_name}" if schema_name else object_name,
            "type": type_resolution["object_type"],
            "raw_object_type": object_type,
            "object_type_source": type_resolution["source"],
            "object_type_confidence": type_resolution["confidence"],
            "object_type_evidence": object_type_evidence,
            "schema": schema_name,
            "object_name": object_name,
            "semantic_table": get_field(row, ["semantic_table", "logical_table"]),
            "database": source_database,
            "server": source_server,
            "source_name": source_name,
            "source_type": source_type,
            "source_qualified_name": get_field(row, ["source_qualified_name"]),
            "usage_type": get_field(row, ["usage_type"]),
            "confidence": confidence,
            "evidence": " ".join(p for p in (get_field(row, ["evidence"]), f"Object type: {object_type_evidence}" if object_type_evidence else "") if p),
            "definition_path": get_field(row, ["definition_path"]),
            "activity_name": get_field(row, ["activity_name"]),
            "activity_type": get_field(row, ["activity_type"]),
            "invoked_item_qualified_name": get_field(row, ["invoked_item_qualified_name"]),
            "evidence_origin": "definition_extraction",
        }
        objects_by_model[item_qn].append(object_node)
        manual_objects_by_item[item_qn].append(object_node)
        add_source_key_index(object_node, source_server, source_database)

    for row in view_candidates:
        source_type = "SQL"
        source_server = get_field(row, ["source_server"])
        source_database = get_field(row, ["database_name", "source_database"])
        schema_name = get_field(row, ["schema_name"])
        object_name = get_field(row, ["object_name"])
        raw_object_type = get_field(row, ["object_type"])
        type_resolution = resolve_type(source_type, source_server, source_database, schema_name, object_name, raw_object_type)
        candidate_evidence = get_field(row, ["evidence"])
        object_type_evidence = type_resolution.get("evidence", "")
        object_node = {
            "label": f"{schema_name}.{object_name}" if schema_name else (object_name if object_name else source_database),
            "type": type_resolution["object_type"],
            "raw_object_type": raw_object_type,
            "object_type_source": type_resolution["source"],
            "object_type_confidence": type_resolution["confidence"],
            "object_type_evidence": object_type_evidence,
            "schema": schema_name,
            "object_name": object_name,
            "semantic_table": get_field(row, ["semantic_table"]),
            "database": source_database,
            "server": source_server,
            "source_type": source_type,
            "confidence": get_field(row, ["confidence"]),
            "evidence": " ".join(p for p in (candidate_evidence, f"Object type: {object_type_evidence}" if object_type_evidence else "") if p),
        }
        objects_by_model[row["semantic_model_qualified_name"]].append(object_node)
        add_source_key_index(object_node, source_server, source_database)

    for row in manual_object_evidence_rows:
        item_qn = get_field(row, ["item_qualified_name", "qualified_name"])
        if not item_qn:
            continue
        source_server = get_field(row, ["source_server", "server"])
        source_database = get_field(row, ["source_database", "database_name", "database"])
        source_name = get_field(row, ["source_name", "source_label"])
        object_name = get_field(row, ["object_name", "source_object"])
        schema_name = get_field(row, ["schema_name", "source_schema"])
        source_type = get_field(row, ["source_type"])
        placeholder = convert_fabric_placeholder_object(source_type, source_database, schema_name, object_name, "")
        if placeholder["changed"]:
            source_type = placeholder["source_type"]
            source_database = placeholder["source_database"]
            schema_name = placeholder["schema_name"]
            object_name = placeholder["object_name"]
            if not source_name:
                source_name = source_database
        object_type = get_field(row, ["object_type"]) or "manual_object"
        confidence = get_field(row, ["confidence"]) or "confirmed"
        type_resolution = resolve_type(source_type, source_server, source_database, schema_name, object_name, object_type)
        if is_exact_object_type(object_type) and type_resolution["source"] not in ("override",):
            type_resolution = {
                "object_type": normalize_object_type(object_type),
                "source": "manual_review",
                "confidence": confidence,
                "evidence": get_field(row, ["evidence"]),
            }
        object_type_evidence = type_resolution.get("evidence", "")

        object_node = {
            "label": f"{schema_name}.{object_name}" if schema_name else object_name,
            "type": type_resolution["object_type"],
            "raw_object_type": object_type,
            "object_type_source": type_resolution["source"],
            "object_type_confidence": type_resolution["confidence"],
            "object_type_evidence": object_type_evidence,
            "schema": schema_name,
            "object_name": object_name,
            "semantic_table": get_field(row, ["semantic_table", "logical_table"]),
            "database": source_database,
            "server": source_server,
            "source_name": source_name,
            "source_type": source_type,
            "source_qualified_name": get_field(row, ["source_qualified_name"]),
            "usage_type": get_field(row, ["usage_type"]),
            "confidence": confidence,
            "evidence": " ".join(p for p in (get_field(row, ["evidence"]), f"Object type: {object_type_evidence}" if object_type_evidence else "") if p),
            "reviewer": get_field(row, ["reviewer"]),
            "reviewed_at": get_field(row, ["reviewed_at"]),
            "notes": get_field(row, ["notes"]),
            "evidence_origin": "manual_review",
        }
        objects_by_model[item_qn].append(object_node)
        manual_objects_by_item[item_qn].append(object_node)
        add_source_key_index(object_node, source_server, source_database)

    # --- lookup indices -----------------------------------------------------------------
    item_by_qn = {item["qualified_name"]: item for item in items}

    analysis_by_qn = {}
    for row in analysis_rows:
        if row.get("qualified_name") and row["qualified_name"] not in analysis_by_qn:
            analysis_by_qn[row["qualified_name"]] = row

    critical_by_qn = {}
    for row in critical_rows:
        if row.get("qualified_name") and row["qualified_name"] not in critical_by_qn:
            critical_by_qn[row["qualified_name"]] = row

    failure_by_qn = {}
    for row in failure_rows:
        if row.get("qualified_name") and row["qualified_name"] not in failure_by_qn:
            failure_by_qn[row["qualified_name"]] = row

    schedule_review_by_qn = {}
    for row in schedule_review_rows:
        if row.get("qualified_name") and row["qualified_name"] not in schedule_review_by_qn:
            schedule_review_by_qn[row["qualified_name"]] = row

    orchestration_group_by_qn = {}
    for row in orchestration_group_rows:
        if row.get("source_qualified_name") and row["source_qualified_name"] not in orchestration_group_by_qn:
            orchestration_group_by_qn[row["source_qualified_name"]] = row

    parallel_counts_by_qn = defaultdict(int)
    for row in parallel_rows:
        for name in (row.get("candidate_a"), row.get("candidate_b")):
            if name:
                parallel_counts_by_qn[name] += 1

    workspace_by_id = {}
    workspace_by_name = {}
    for workspace in workspaces:
        workspace_id = get_field(workspace, ["technical_id", "workspace_id"])
        workspace_name = get_field(workspace, ["workspace_name"])
        if workspace_id and normalize_key(workspace_id) not in workspace_by_id:
            workspace_by_id[normalize_key(workspace_id)] = workspace
        if workspace_name and normalize_key(workspace_name) not in workspace_by_name:
            workspace_by_name[normalize_key(workspace_name)] = workspace

    pipeline_by_id = {}
    for pipeline in deployment_pipeline_rows:
        pipeline_id = get_field(pipeline, ["deployment_pipeline_id"])
        if pipeline_id and pipeline_id not in pipeline_by_id:
            pipeline_by_id[pipeline_id] = pipeline

    def resolve_local_workspace_name(workspace_id, workspace_name):
        if workspace_id and normalize_key(workspace_id) in workspace_by_id:
            return get_field(workspace_by_id[normalize_key(workspace_id)], ["workspace_name"])
        if workspace_name and normalize_key(workspace_name) in workspace_by_name:
            return get_field(workspace_by_name[normalize_key(workspace_name)], ["workspace_name"])
        return ""

    deployment_stage_by_workspace_name = {}
    for stage in deployment_pipeline_stage_rows:
        pipeline_id = get_field(stage, ["deployment_pipeline_id"])
        workspace_id = get_field(stage, ["workspace_id"])
        workspace_name = get_field(stage, ["workspace_name"])
        local_workspace_name = resolve_local_workspace_name(workspace_id, workspace_name)
        if not local_workspace_name:
            continue
        pipeline = pipeline_by_id.get(pipeline_id)
        deployment_stage_by_workspace_name[local_workspace_name] = {
            "deployment_pipeline_id": pipeline_id,
            "deployment_pipeline_name": get_field(stage, ["deployment_pipeline_name"]),
            "deployment_pipeline_description": get_field(pipeline, ["description"]) if pipeline else "",
            "stage_id": get_field(stage, ["stage_id"]),
            "stage_order": get_field(stage, ["stage_order"]),
            "stage_name": get_field(stage, ["stage_name"]),
            "stage_description": get_field(stage, ["stage_description"]),
            "stage_workspace_id": workspace_id,
            "stage_workspace_name": workspace_name if workspace_name else local_workspace_name,
            "is_public": get_field(stage, ["is_public"]),
            "status": get_field(stage, ["status"]),
            "evidence": get_field(stage, ["evidence"]),
        }

    dependencies_by_from = defaultdict(list)
    for dep in dependencies:
        dependencies_by_from[dep["from_qualified_name"]].append(dep)

    # (pipeline_qualified_name, invoked_item_qualified_name) -> [{activity_name, activity_type, parameters}]
    # A pipeline can invoke the same notebook from more than one activity with
    # different parameters each time, so this is a list, not a single value.
    # pipeline_activity_lineage.csv has one row per (activity, dependsOn) pair,
    # so the same activity can appear multiple times here -- dedupe by
    # (activity_name, parameters) so it only shows up once per distinct invocation.
    activities_by_pipeline_and_target = defaultdict(list)
    seen_activities = set()
    for row in pipeline_activity_lineage_rows:
        raw_parameters = get_field(row, ["parameters"])
        try:
            parameters = json.loads(raw_parameters) if raw_parameters else {}
        except json.JSONDecodeError:
            parameters = {}
        if not parameters:
            continue
        key = (row["pipeline_qualified_name"], row["invoked_item_qualified_name"])
        activity_name = get_field(row, ["activity_name"])
        dedupe_key = (key, activity_name, json.dumps(parameters, sort_keys=True))
        if dedupe_key in seen_activities:
            continue
        seen_activities.add(dedupe_key)
        activities_by_pipeline_and_target[key].append(
            {
                "activity_name": activity_name,
                "activity_type": get_field(row, ["activity_type"]),
                "parameters": parameters,
            }
        )

    pipeline_activity_dependency_edges = resolve_pipeline_activity_dependency_edges(pipeline_activity_all_rows)

    executions_by_qn = defaultdict(list)
    for row in executions:
        executions_by_qn[row["qualified_name"]].append(row)

    migration_by_key = defaultdict(list)
    for row in migration_rows:
        key = normalize_key(f"{get_field(row, ['source_server'])}|{get_field(row, ['source_database'])}")
        if key:
            migration_by_key[key].append(row)

    # items pre-grouped by workspace_name once, instead of re-filtering the full
    # item list on every workspace iteration (O(items) -> O(1) per workspace)
    items_by_workspace_name = defaultdict(list)
    for item in items:
        items_by_workspace_name[item.get("workspace_name", "")].append(item)

    ctx = {
        "item_by_qn": item_by_qn,
        "migration_by_key": migration_by_key,
        "objects_by_model": objects_by_model,
        "objects_by_source": objects_by_source,
        "manual_objects_by_item": manual_objects_by_item,
        "notebook_super_objects_by_item": notebook_super_objects_by_item,
        "notebook_super_flows_by_item": notebook_super_flows_by_item,
        "analysis_by_qn": analysis_by_qn,
        "executions_by_qn": executions_by_qn,
        "dependencies_by_from": dependencies_by_from,
        "activities_by_pipeline_and_target": activities_by_pipeline_and_target,
        "variables_by_qn": variables_by_qn,
        "planning_indices": {
            "critical_by_qn": critical_by_qn,
            "failure_by_qn": failure_by_qn,
            "schedule_review_by_qn": schedule_review_by_qn,
            "orchestration_group_by_qn": orchestration_group_by_qn,
            "parallel_counts_by_qn": parallel_counts_by_qn,
        },
    }

    # item nodes are memoized by qualified_name: each item appears in its
    # type-specific list (semantic/notebooks/copyjobs/pipelines) AND in "all"
    # -- the original PowerShell rebuilt the node from scratch both times.
    memo = {}

    workspace_payloads = []
    source_types_seen = set()

    for workspace in sorted(workspaces, key=lambda w: ci_lower(get_field(w, ["workspace_name"]))):
        workspace_name = get_field(workspace, ["workspace_name"])
        workspace_items = items_by_workspace_name.get(workspace_name, [])
        all_items = sorted(workspace_items, key=lambda i: (ci_lower(i.get("item_type", "")), ci_lower(i.get("item_name", ""))))
        if not all_items:
            continue

        # One bucket per item_type actually present in this workspace, keyed
        # by mode_key_for_item_type -- covers the 5 core modes AND every
        # other Fabric item type (Report, Lakehouse, Eventstream, ...) so
        # each is its own browsable mode, not just visible inside "all".
        items_by_mode_key = defaultdict(list)
        for workspace_item in workspace_items:
            items_by_mode_key[mode_key_for_item_type(workspace_item.get("item_type", ""))].append(workspace_item)
        for mode_key in items_by_mode_key:
            items_by_mode_key[mode_key].sort(key=lambda i: ci_lower(i.get("item_name", "")))

        deployment_stage = deployment_stage_by_workspace_name.get(workspace_name)
        if deployment_stage:
            deployment_pipeline = {"has_pipeline": True, **deployment_stage}
        else:
            deployment_pipeline = {
                "has_pipeline": False,
                "deployment_pipeline_id": "",
                "deployment_pipeline_name": "",
                "deployment_pipeline_description": "",
                "stage_id": "",
                "stage_order": "",
                "stage_name": "",
                "stage_description": "",
                "stage_workspace_id": "",
                "stage_workspace_name": "",
                "is_public": "",
                "status": "",
                "evidence": "",
            }

        # "all" is NOT written into the payload below -- every item already
        # appears in exactly one items_by_mode_key bucket (the union of
        # those buckets IS all_items, just partitioned by type), so a
        # separate "all" node list would be a byte-for-byte duplicate of
        # data already present elsewhere in the same workspace, once per
        # item. This doubling was a large contributor to an oversized
        # lineage-explorer.json after a tenant-wide scan (the browser could
        # no longer even load the file).
        # app.js reconstructs workspace.all client-side once, right after
        # parsing, by concatenating every data.modes key present on that
        # workspace -- see loadLineageDataOnMainThread/loadLineageDataViaWorker.
        nodes_by_mode_key = {mode_key: [build_item_node(i, ctx, memo) for i in mode_items] for mode_key, mode_items in items_by_mode_key.items()}

        for node_list in nodes_by_mode_key.values():
            for node in node_list:
                node_source_lists = (
                    [node["sources"]]
                    + [model.get("sources", []) for model in node.get("models", [])]
                    + [execute.get("sources", []) for execute in node.get("executes", [])]
                )
                for source in node["sources"]:
                    if source.get("source_type"):
                        source_types_seen.add(source["source_type"])
                for sources in node_source_lists:
                    for source in sources:
                        add_columns_to_source(source, column_catalog_by_full_key, column_catalog_schemas_by_name_key)

        git_row = git_connection_by_workspace_name.get(ci_lower(workspace_name))
        git_connected = bool(git_row) and get_field(git_row, ["git_connected"]) == "true"
        last_scanned_at = last_scanned_at_by_workspace_name.get(ci_lower(workspace_name), "")
        last_sync_time = get_field(git_row, ["last_sync_time"]) if git_row else ""
        # "stale": Fabric pulled from git more recently than we last scanned
        # this workspace -- our data may be missing whatever that sync
        # brought in. Pure ISO-8601 string comparison is safe here since
        # both sides are produced the same way (datetime.now().isoformat()-
        # style / .ToString("o")), which sort lexicographically like their
        # actual chronological order.
        if not git_connected:
            git_sync_status = "not_connected"
        elif not last_scanned_at:
            git_sync_status = "never_scanned"
        elif last_sync_time and last_sync_time > last_scanned_at:
            git_sync_status = "stale"
        else:
            git_sync_status = "synced"
        git_info = {
            "connected": git_connected,
            "provider_type": get_field(git_row, ["git_provider_type"]) if git_row else "",
            "organization_name": get_field(git_row, ["organization_name"]) if git_row else "",
            "project_name": get_field(git_row, ["project_name"]) if git_row else "",
            "repository_name": get_field(git_row, ["repository_name"]) if git_row else "",
            "branch_name": get_field(git_row, ["branch_name"]) if git_row else "",
            "directory_name": get_field(git_row, ["directory_name"]) if git_row else "",
            "last_sync_time": last_sync_time,
            "last_scanned_at": last_scanned_at,
            "sync_status": git_sync_status,
        }

        workspace_payloads.append(
            {
                "name": workspace_name,
                # The real Fabric workspace GUID -- used to build a direct
                # "open in Fabric" link for this workspace and for every
                # item inside it (see fabricWorkspaceUrl/fabricItemUrl in
                # app.js), not previously exposed to the frontend at all.
                "workspace_id": get_field(workspace, ["technical_id"]),
                "normalized_name": get_field(workspace, ["normalized_workspace_name"]),
                "environment": get_field(workspace, ["environment"]),
                "workspace_type": get_field(workspace, ["workspace_type"]),
                "capacity_name": get_field(workspace, ["capacity_name"]),
                "capacity_id": get_field(workspace, ["capacity_id"]),
                "capacity_region": get_field(workspace, ["capacity_region"]),
                "domain_name": get_field(workspace, ["domain_name"]),
                "owner": get_field(workspace, ["owner"]),
                "admin_principals": get_field(workspace, ["admin_principals"]),
                "description": get_field(workspace, ["description"]),
                "git": git_info,
                "role_assignments": role_assignments_by_workspace_name.get(ci_lower(workspace_name), []),
                "deployment_pipeline": deployment_pipeline,
                "counts": {
                    **{mode_key: len(mode_items) for mode_key, mode_items in items_by_mode_key.items()},
                    "all": len(all_items),
                },
                **nodes_by_mode_key,
            }
        )

    source_types = sorted(source_types_seen, key=ci_lower)

    semantic_model_count = sum(1 for i in items if i.get("item_type") == "SemanticModel")
    report_count = sum(1 for i in items if i.get("item_type") == "Report")
    notebook_count = sum(1 for i in items if i.get("item_type") == "Notebook")
    copyjob_count = sum(1 for i in items if i.get("item_type") == "CopyJob")
    pipeline_count = sum(1 for i in items if i.get("item_type") == "DataPipeline")
    dataflow_count = sum(1 for i in items if i.get("item_type") == "Dataflow")
    manual_lineage_item_count = len({r["item_qualified_name"] for r in manual_object_evidence_rows if r.get("item_qualified_name")})
    item_object_candidate_item_count = len({r["item_qualified_name"] for r in item_object_candidate_rows if r.get("item_qualified_name")})
    item_types = sorted({i.get("item_type", "") for i in items if i.get("item_type")}, key=ci_lower)

    # Tenant-wide count per mode key -- lets the frontend build the mode
    # bar (one button per item type that actually exists, "Todos" first,
    # then the rest ordered from most to fewest elements per the ask) as
    # data instead of hand-listing every Fabric item type in HTML/JS.
    mode_counts = Counter(mode_key_for_item_type(i.get("item_type", "")) for i in items if i.get("item_type"))

    all_object_nodes = [obj for objs in objects_by_model.values() for obj in objs]
    exact_object_type_count = sum(1 for o in all_object_nodes if is_exact_object_type(o.get("type", "")))
    unresolved_table_or_view_count = sum(1 for o in all_object_nodes if o.get("type") == "table_or_view")
    native_query_object_count = sum(1 for o in all_object_nodes if o.get("type") == "native_query_object")

    deployment_pipeline_payloads = []
    for pipeline in sorted(deployment_pipeline_rows, key=lambda p: ci_lower(get_field(p, ["deployment_pipeline_name"]))):
        pipeline_id = get_field(pipeline, ["deployment_pipeline_id"])

        def stage_sort_key(stage):
            order = get_field(stage, ["stage_order"])
            return int(order) if INT_PATTERN.match(order or "") else 999

        pipeline_stages = sorted(
            (s for s in deployment_pipeline_stage_rows if s.get("deployment_pipeline_id") == pipeline_id),
            key=stage_sort_key,
        )
        if not pipeline_stages:
            continue
        stage_payloads = []
        for stage in pipeline_stages:
            workspace_id = get_field(stage, ["workspace_id"])
            workspace_name = get_field(stage, ["workspace_name"])
            local_workspace_name = resolve_local_workspace_name(workspace_id, workspace_name)
            stage_payloads.append(
                {
                    "stage_id": get_field(stage, ["stage_id"]),
                    "stage_order": get_field(stage, ["stage_order"]),
                    "stage_name": get_field(stage, ["stage_name"]),
                    "stage_description": get_field(stage, ["stage_description"]),
                    "workspace_id": workspace_id,
                    "workspace_name": workspace_name,
                    "local_workspace_name": local_workspace_name,
                    "is_public": get_field(stage, ["is_public"]),
                    "status": get_field(stage, ["status"]),
                    "evidence": get_field(stage, ["evidence"]),
                }
            )
        indexed_workspace_names = unique_ci_preserve_order(s["local_workspace_name"] for s in stage_payloads)
        group = next((g for g in deployment_pipeline_group_rows if g.get("deployment_pipeline_id") == pipeline_id), None)
        deployment_pipeline_payloads.append(
            {
                "deployment_pipeline_id": pipeline_id,
                "deployment_pipeline_name": get_field(pipeline, ["deployment_pipeline_name"]),
                "description": get_field(pipeline, ["description"]),
                "stage_count": len(pipeline_stages),
                "assigned_stage_count": sum(1 for s in pipeline_stages if s.get("workspace_id") or s.get("workspace_name")),
                "indexed_workspace_count": len(indexed_workspace_names),
                "workspace_names": indexed_workspace_names,
                "status": get_field(group, ["status"]) if group else "",
                "evidence": get_field(group, ["evidence"]) if group else "Fabric deployment pipeline stage metadata.",
                "stages": stage_payloads,
            }
        )

    payload = {
        "generated_at": datetime.now().replace(microsecond=0).isoformat(),
        "summary": {
            "workspaces": len(workspace_payloads),
            "semantic_models": semantic_model_count,
            "reports": report_count,
            "notebooks": notebook_count,
            "copyjobs": copyjob_count,
            "pipelines": pipeline_count,
            "dataflows": dataflow_count,
            "all_items": len(items),
            "item_types": item_types,
            "critical_path_candidates": len(critical_rows),
            "failure_hotspots": len(failure_rows),
            "schedule_review_candidates": len(schedule_review_rows),
            "orchestration_group_candidates": len(orchestration_group_rows),
            "parallelism_candidates": len(parallel_rows),
            "manual_lineage_evidence_rows": len(manual_object_evidence_rows),
            "manual_lineage_items": manual_lineage_item_count,
            "item_object_lineage_candidate_rows": len(item_object_candidate_rows),
            "item_object_lineage_candidate_items": item_object_candidate_item_count,
            "pipeline_object_lineage_candidate_rows": len(pipeline_object_candidate_rows),
            "pipeline_object_lineage_candidate_items": len({r["item_qualified_name"] for r in pipeline_object_candidate_rows if r.get("item_qualified_name")}),
            "object_type_override_rows": len(object_type_override_rows),
            "object_type_metadata_evidence_rows": len(object_type_metadata_evidence_rows),
            "sql_endpoint_catalog_rows": len(sql_endpoint_catalog_rows),
            "exact_object_type_nodes": exact_object_type_count,
            "unresolved_table_or_view_nodes": unresolved_table_or_view_count,
            "native_query_object_nodes": native_query_object_count,
            "deployment_pipelines": len(deployment_pipeline_payloads),
            "deployment_pipeline_stage_workspaces": sum(1 for w in workspace_payloads if w["deployment_pipeline"]["has_pipeline"]),
            "mode_counts": dict(mode_counts),
        },
        # Every mode key that actually has at least one item, most to
        # fewest -- the frontend's mode bar (see the compact/overflow
        # redesign) reads this directly instead of a hand-maintained list,
        # which had already drifted out of sync here (missing "dataflows").
        "modes": [mode_key for mode_key, _ in mode_counts.most_common()],
        "filters": {"source_types": source_types, "confidence": ["confirmed", "likely", "unknown"]},
        "refresh": get_refresh_metadata(args.manifest_path, args.visual_validation_result_path, args.run_log_directory),
        "deployment_pipelines": deployment_pipeline_payloads,
        # Real Succeeded/Failed/Completed item-to-item execution order,
        # resolved from pipeline activity dependsOn chains. Used by the
        # Planning view to color arrows the same way a Fabric pipeline
        # canvas would, instead of only inferring order from read/write
        # table overlap.
        "pipeline_activity_dependency_edges": pipeline_activity_dependency_edges,
        "workspaces": workspace_payloads,
    }

    write_json_atomic(args.output_json_path, payload)

    # $gaps is declared in the original script but never populated -- keep the
    # header-only CSV for compatibility with anything that might read it.
    ensure_parent(args.gap_path)
    with open(args.gap_path, "w", encoding="utf-8") as handle:
        handle.write("")

    print("Lineage explorer data built.")
    print(f"Workspaces: {len(workspace_payloads)}")
    print(f"Output: {args.output_json_path}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 - top-level: report cleanly instead of a raw traceback
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
