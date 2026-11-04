#!/usr/bin/env python3
"""Build the next actionable D4 evidence-gate plan.

The plan translates E2 root causes into concrete workstreams. It does not
promote evidence, query external systems, or modify orchestration rules.
"""

from __future__ import annotations

import csv
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent  # Anchor default paths to the repo, not $PWD


PLAN_COLUMNS = [
    "plan_id",
    "priority_score",
    "priority_band",
    "workstream",
    "action_bucket",
    "codex_action_status",
    "requires_external_access",
    "external_access_type",
    "root_cause_class",
    "closure_opportunity",
    "metadata_gap_reason",
    "metadata_error_class",
    "catalog_match_class",
    "strict_promotion_candidate",
    "impact_priority",
    "source_type",
    "source_server",
    "source_database",
    "schema_name",
    "object_name",
    "raw_object_type",
    "affected_item_count",
    "semantic_model_count",
    "operation_split",
    "affected_items_sample",
    "recommended_next_action",
    "codex_next_step",
    "evidence_to_use",
]

SUMMARY_COLUMNS = ["scope", "value", "count", "notes"]


def read_csv(path: str | Path) -> list[dict[str, str]]:
    path = Path(path)
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: str | Path, rows: list[dict[str, str]], columns: list[str]) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({column: row.get(column, "") for column in columns})


def to_int(value: str | None) -> int:
    try:
        return int(float(value or 0))
    except ValueError:
        return 0


def compact(value: str | None, max_len: int = 900) -> str:
    text = " ".join((value or "").split())
    if len(text) <= max_len:
        return text
    return text[: max_len - 3] + "..."


def classify_workstream(row: dict[str, str]) -> dict[str, str]:
    root = row.get("root_cause_class", "")
    gap = row.get("metadata_gap_reason", "")
    error = row.get("metadata_error_class", "")
    catalog = row.get("catalog_match_class", "")

    if root in {
        "missing_source_target_no_local_catalog_match",
        "missing_source_target_global_name_ambiguous",
        "missing_source_target_unique_name_review_only",
    }:
        return {
            "workstream": "source_target_backfill",
            "action_bucket": root,
            "codex_action_status": "local_definition_parser_work",
            "requires_external_access": "no",
            "external_access_type": "",
            "codex_next_step": "Review local TMDL/notebook/CopyJob parser evidence and connection context to recover the missing source target before exact type promotion.",
            "evidence_to_use": "Local definitions, semantic model source expressions, notebook super-lineage, CopyJob/DataPipeline object lineage, Fabric SQL endpoint catalog.",
        }

    if root in {
        "metadata_access_failed_source_db_not_cataloged",
        "metadata_access_failed_same_db_multiple_schema_matches",
    }:
        external_type = "owner_catalog_or_credentials"
        if "aad" in error:
            external_type = "aad_or_sql_metadata_permission"
        elif "network" in error:
            external_type = "network_or_host_access"
        elif "credentials" in error or "login" in error:
            external_type = "sql_credentials_or_login_permission"
        return {
            "workstream": "metadata_access_retry_or_catalog",
            "action_bucket": f"{root}:{error}",
            "codex_action_status": "blocked_until_readonly_access_or_catalog",
            "requires_external_access": "yes",
            "external_access_type": external_type,
            "codex_next_step": "Retry read-only metadata only when credentials/network/catalog access is available; otherwise keep out of hard orchestration.",
            "evidence_to_use": "Read-only sys.objects/INFORMATION_SCHEMA/Fabric endpoint catalog or owner-approved catalog evidence.",
        }

    if root in {
        "object_absent_in_confirmed_source_database",
        "object_exists_as_unsupported_physical_type",
    }:
        return {
            "workstream": "object_not_found_closure",
            "action_bucket": root,
            "codex_action_status": "local_parser_or_owner_catalog_review",
            "requires_external_access": "maybe",
            "external_access_type": "owner_catalog_if_parser_review_cannot_explain_absence",
            "codex_next_step": "Treat current metadata absence as confirmed; inspect parser/source definition for alias, rename, wrong database, dynamic SQL, or stale object reference.",
            "evidence_to_use": "Existing read-only metadata gaps, SQL probe results, local source definitions, owner catalog if needed.",
        }

    if root == "same_database_multiple_schema_disambiguation":
        return {
            "workstream": "schema_disambiguation",
            "action_bucket": f"{root}:{catalog}",
            "codex_action_status": "local_definition_parser_work",
            "requires_external_access": "no",
            "external_access_type": "",
            "codex_next_step": "Use source expression/query text to select the exact schema among same-database matches.",
            "evidence_to_use": "TMDL M expressions, SQL/native query text, notebook code, CopyJob source path.",
        }

    if root == "native_query_requires_definition_review":
        return {
            "workstream": "native_query_review",
            "action_bucket": root,
            "codex_action_status": "local_definition_parser_work",
            "requires_external_access": "no",
            "external_access_type": "",
            "codex_next_step": "Read native query text and classify the referenced object as table, view, stored procedure, file, shortcut, query, function, schema, or dynamic reference.",
            "evidence_to_use": "Semantic model TMDL/M native query text and parser evidence.",
        }

    if root == "missing_gap_record_requires_manual_review":
        return {
            "workstream": "gap_record_reconciliation",
            "action_bucket": root,
            "codex_action_status": "local_reconciliation_work",
            "requires_external_access": "no",
            "external_access_type": "",
            "codex_next_step": "Reconcile why D4 has a pending row but no metadata gap record; regenerate parser evidence or mark explicit review status.",
            "evidence_to_use": "D4 source queue, E2 classification, metadata gaps, source object resolution queue.",
        }

    return {
        "workstream": "unclassified_review",
        "action_bucket": root or gap or "unclassified",
        "codex_action_status": "manual_review_required",
        "requires_external_access": "unknown",
        "external_access_type": "",
        "codex_next_step": "Review the row manually before operational use.",
        "evidence_to_use": "D4 and E2 evidence.",
    }


def build_doc(
    path: str | Path,
    plan_rows: list[dict[str, str]],
    workspace_evidence_rows: list[dict[str, str]],
    semantic_sibling_rows: list[dict[str, str]],
    sql_probe_evidence_rows: list[dict[str, str]],
    sql_probe_new_rows: int,
) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    workstreams = Counter(row["workstream"] for row in plan_rows)
    external = Counter(row["requires_external_access"] for row in plan_rows)
    statuses = Counter(row["codex_action_status"] for row in plan_rows)
    root_causes = Counter(row["root_cause_class"] for row in plan_rows)

    lines = [
        "# D4 Next Evidence Gate Plan",
        "",
        f"Generated: {datetime.now(timezone.utc).isoformat(timespec='seconds')}",
        "",
        "## What Changed",
        "",
        f"- Workspace-scoped Fabric catalog evidence rows applied: {len(workspace_evidence_rows)}.",
        f"- Semantic sibling source-target backfill rows emitted or retained: {len(semantic_sibling_rows)}.",
        f"- SQL source read-only probe evidence rows found: {len(sql_probe_evidence_rows)}.",
        f"- SQL source read-only probe rows newly added to official metadata evidence: {sql_probe_new_rows}.",
        "",
        "## Current D4 Open Plan",
        "",
        f"- Open D4 rows: {len(plan_rows)}.",
        f"- Rows not requiring external access first: {external.get('no', 0)}.",
        f"- Rows requiring external access/catalog: {external.get('yes', 0)}.",
        f"- Rows that may need owner catalog after parser review: {external.get('maybe', 0)}.",
        "",
        "## Workstreams",
        "",
    ]
    for workstream, count in workstreams.most_common():
        lines.append(f"- {workstream}: {count}")
    lines.extend(["", "## Codex Action Status", ""])
    for status, count in statuses.most_common():
        lines.append(f"- {status}: {count}")
    lines.extend(["", "## Root Causes", ""])
    for root, count in root_causes.most_common():
        lines.append(f"- {root}: {count}")
    lines.extend(
        [
            "",
            "## Outputs",
            "",
            "- `analysis/d4_next_evidence_gate_plan.csv`",
            "- `analysis/d4_next_evidence_gate_summary.csv`",
            "- `analysis/d4_object_not_found_next_queue.csv`",
            "- `analysis/d4_metadata_access_next_queue.csv`",
            "- `analysis/d4_source_target_backfill_next_queue.csv`",
            "- `docs/50_d4_next_evidence_gate_plan.md`",
            "",
            "## Safety",
            "",
            "- Local planning only.",
            "- No orchestration rule was promoted.",
            "- No external write was made.",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    e2_rows = read_csv(REPO_ROOT / "analysis/e2_unresolved_object_type_gap_classification.csv")
    d4_rows = read_csv(REPO_ROOT / "analysis/d4_closure_control_queue.csv")
    workspace_evidence_rows = read_csv(REPO_ROOT / "analysis/d4_workspace_catalog_type_evidence.csv")
    semantic_sibling_rows = read_csv(REPO_ROOT / "analysis/d4_semantic_sibling_target_backfill.csv")
    sql_probe_evidence_rows = read_csv(REPO_ROOT / "analysis/d4_sql_source_probe_metadata_evidence.csv")
    official_evidence_rows = read_csv(REPO_ROOT / "analysis/source_object_type_metadata_evidence.csv")
    d4_by_source_id = {row.get("source_id", ""): row for row in d4_rows}

    official_keys = {
        (
            row.get("source_type", "").strip().casefold(),
            row.get("source_server", "").strip().casefold(),
            row.get("source_database", "").strip().casefold(),
            row.get("schema_name", "").strip().casefold(),
            row.get("object_name", "").strip().casefold(),
            row.get("object_type", "").strip().casefold(),
        )
        for row in official_evidence_rows
    }
    sql_probe_new_rows = 0
    for row in sql_probe_evidence_rows:
        key = (
            row.get("source_type", "").strip().casefold(),
            row.get("source_server", "").strip().casefold(),
            row.get("source_database", "").strip().casefold(),
            row.get("schema_name", "").strip().casefold(),
            row.get("object_name", "").strip().casefold(),
            row.get("object_type", "").strip().casefold(),
        )
        if key not in official_keys:
            sql_probe_new_rows += 1

    plan_rows: list[dict[str, str]] = []
    for index, row in enumerate(
        sorted(e2_rows, key=lambda item: (-to_int(item.get("priority_score")), item.get("classification_id", ""))),
        start=1,
    ):
        classification = classify_workstream(row)
        d4_row = d4_by_source_id.get(row.get("source_id", ""), {})
        plan_rows.append(
            {
                "plan_id": f"D4P{index:05d}",
                "priority_score": row.get("priority_score", ""),
                "priority_band": row.get("priority_band", ""),
                "root_cause_class": row.get("root_cause_class", ""),
                "closure_opportunity": row.get("closure_opportunity", ""),
                "metadata_gap_reason": row.get("metadata_gap_reason", ""),
                "metadata_error_class": row.get("metadata_error_class", ""),
                "catalog_match_class": row.get("catalog_match_class", ""),
                "strict_promotion_candidate": row.get("strict_promotion_candidate", ""),
                "impact_priority": d4_row.get("impact_priority", ""),
                "source_type": row.get("source_type", ""),
                "source_server": row.get("source_server", ""),
                "source_database": row.get("source_database", ""),
                "schema_name": row.get("schema_name", ""),
                "object_name": row.get("object_name", ""),
                "raw_object_type": row.get("raw_object_type", ""),
                "affected_item_count": row.get("affected_item_count", ""),
                "semantic_model_count": row.get("semantic_model_count", ""),
                "operation_split": row.get("operation_split", ""),
                "affected_items_sample": compact(row.get("affected_items_sample", "")),
                "recommended_next_action": row.get("recommended_next_action", ""),
                **classification,
            }
        )

    summary_rows: list[dict[str, str]] = []
    for scope, counter, notes in [
        ("workstream", Counter(row["workstream"] for row in plan_rows), "D4 open rows by next workstream."),
        ("codex_action_status", Counter(row["codex_action_status"] for row in plan_rows), "D4 open rows by Codex action status."),
        ("requires_external_access", Counter(row["requires_external_access"] for row in plan_rows), "D4 open rows by external dependency."),
        ("root_cause_class", Counter(row["root_cause_class"] for row in plan_rows), "D4 open rows by E2 root cause."),
        ("metadata_error_class", Counter(row["metadata_error_class"] for row in plan_rows), "D4 open rows by metadata error class."),
    ]:
        for value, count in counter.most_common():
            summary_rows.append({"scope": scope, "value": value, "count": str(count), "notes": notes})
    summary_rows.extend(
        [
            {"scope": "applied_backfill", "value": "workspace_catalog_type_evidence", "count": str(len(workspace_evidence_rows)), "notes": "Local evidence rows generated by backend/scripts/56_build_workspace_catalog_type_evidence.py."},
            {"scope": "applied_backfill", "value": "semantic_sibling_source_target_backfill", "count": str(len(semantic_sibling_rows)), "notes": "Rows emitted or retained by backend/scripts/58_backfill_semantic_sibling_source_targets.py."},
            {"scope": "sql_source_probe", "value": "probe_evidence_rows", "count": str(len(sql_probe_evidence_rows)), "notes": "Read-only probe evidence rows; compared with official evidence."},
            {"scope": "sql_source_probe", "value": "new_official_evidence_rows", "count": str(sql_probe_new_rows), "notes": "Rows from probe not already present in official metadata evidence."},
        ]
    )

    write_csv(REPO_ROOT / "analysis/d4_next_evidence_gate_plan.csv", plan_rows, PLAN_COLUMNS)
    write_csv(REPO_ROOT / "analysis/d4_next_evidence_gate_summary.csv", summary_rows, SUMMARY_COLUMNS)
    write_csv(
        REPO_ROOT / "analysis/d4_object_not_found_next_queue.csv",
        [row for row in plan_rows if row["workstream"] == "object_not_found_closure"],
        PLAN_COLUMNS,
    )
    write_csv(
        REPO_ROOT / "analysis/d4_metadata_access_next_queue.csv",
        [row for row in plan_rows if row["workstream"] == "metadata_access_retry_or_catalog"],
        PLAN_COLUMNS,
    )
    write_csv(
        REPO_ROOT / "analysis/d4_source_target_backfill_next_queue.csv",
        [row for row in plan_rows if row["workstream"] == "source_target_backfill"],
        PLAN_COLUMNS,
    )
    build_doc(
        REPO_ROOT / "docs/50_d4_next_evidence_gate_plan.md",
        plan_rows,
        workspace_evidence_rows,
        semantic_sibling_rows,
        sql_probe_evidence_rows,
        sql_probe_new_rows,
    )

    print(f"D4 next evidence gate plan rows: {len(plan_rows)}")
    print(f"Workspace catalog evidence applied: {len(workspace_evidence_rows)}")
    print(f"Semantic sibling source-target backfill rows: {len(semantic_sibling_rows)}")
    print(f"SQL source probe evidence rows: {len(sql_probe_evidence_rows)}")
    print(f"SQL source new official evidence rows: {sql_probe_new_rows}")
    print("Output: analysis/d4_next_evidence_gate_plan.csv")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
