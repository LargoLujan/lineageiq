#!/usr/bin/env python3
"""Classify unresolved D4 object-type gaps without promoting evidence.

This script explains why pending table/view/SP typing rows are still pending.
It uses only local artifacts and writes review queues; it does not modify
metadata evidence or external systems.
"""

from __future__ import annotations

import csv
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def norm(value: str | None) -> str:
    return (value or "").strip().casefold()


def text(value: str | None) -> str:
    return (value or "").strip()


def read_csv(relative_path: str) -> list[dict[str, str]]:
    path = ROOT / relative_path
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def write_csv(relative_path: str, rows: list[dict[str, str]], fields: list[str]) -> None:
    path = ROOT / relative_path
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def load_catalog() -> list[dict[str, str]]:
    catalog: list[dict[str, str]] = []
    sql_paths = [
        "analysis/sql_server_deep_catalog_objects.csv",
        "analysis/sql_server_deep_catalog_more_sql_objects.csv",
    ]
    for relative_path in sql_paths:
        for row in read_csv(relative_path):
            catalog.append(
                {
                    "catalog_source": relative_path,
                    "source_type": "SQL",
                    "source_server": text(row.get("source_server")),
                    "source_database": text(row.get("database_name")),
                    "schema_name": text(row.get("schema_name")),
                    "object_name": text(row.get("object_name")),
                    "object_type": text(row.get("object_type")),
                    "metadata_type_desc": text(row.get("type_desc")),
                }
            )

    for row in read_csv("analysis/sql_endpoint_object_catalog.csv"):
        catalog.append(
            {
                "catalog_source": "analysis/sql_endpoint_object_catalog.csv",
                "source_type": text(row.get("source_type")) or "Fabric",
                "source_server": text(row.get("source_server")),
                "source_database": text(row.get("source_database")),
                "schema_name": text(row.get("schema_name")),
                "object_name": text(row.get("object_name")),
                "object_type": text(row.get("object_type")),
                "metadata_type_desc": text(row.get("metadata_type_desc")),
            }
        )
    return catalog


def display_match(row: dict[str, str]) -> str:
    return (
        f"{row.get('source_type','')}|{row.get('source_server','')}/"
        f"{row.get('source_database','')}/{row.get('schema_name','')}."
        f"{row.get('object_name','')}:{row.get('object_type','')}"
    )


def compact_matches(rows: list[dict[str, str]], limit: int = 5) -> str:
    return "; ".join(display_match(row) for row in rows[:limit])


def classify_error(error: str) -> str:
    lower = error.casefold()
    if not error:
        return "no_gap_error_record"
    if "source server or database is missing" in lower:
        return "missing_source_server_or_database"
    if "login failed for user ''" in lower:
        return "sql_auth_credentials_not_supplied"
    if "token-identified principal" in lower:
        return "aad_token_login_failed"
    if "could not login because the authentication failed" in lower:
        return "sql_login_authentication_failed"
    if "network-related" in lower or "could not open a connection" in lower:
        return "network_or_host_unreachable"
    if "object was not found" in lower:
        return "object_not_found_in_target_catalog"
    if "multiple schemas" in lower:
        return "object_name_found_in_multiple_schemas"
    return "other_metadata_error"


def allowed_types(value: str) -> set[str]:
    raw = norm(value)
    if not raw:
        return {"table", "view", "stored_procedure"}
    if "stored_procedure" in raw or "procedure" in raw:
        return {"stored_procedure"}
    if "table" in raw and "view" in raw:
        return {"table", "view"}
    if "table" in raw:
        return {"table"}
    if "view" in raw:
        return {"view"}
    return {"table", "view", "stored_procedure"}


def root_cause_and_action(
    row: dict[str, str],
    casefold_diagnosis: str,
    error_class: str,
    source_db_status: str,
    catalog_match_class: str,
    match_rows: list[dict[str, str]],
) -> tuple[str, str, str, str]:
    gap = text(row.get("metadata_gap_reason"))
    closure = text(row.get("closure_opportunity"))
    raw = text(row.get("raw_object_type"))
    allowed = allowed_types(raw)
    match_types = {norm(match.get("object_type")) for match in match_rows}
    unsupported_same_db = bool(match_types) and not bool(match_types & allowed)

    if closure == "native_query_definition_review_required":
        return (
            "native_query_requires_definition_review",
            "Review semantic/TMDL or notebook native query text to recover the real physical object and operation.",
            "medium",
            "no",
        )

    if closure == "no_gap_record_manual_review_required":
        return (
            "missing_gap_record_requires_manual_review",
            "Inspect the source definition and add explicit evidence or rejection; there is no metadata gap row to close automatically.",
            "medium",
            "no",
        )

    if gap == "missing_metadata_target" or closure == "missing_metadata_target_mapping_required":
        if casefold_diagnosis == "review_only_global_unique_fabric_object_name" or catalog_match_class == "global_unique_object_name_only":
            return (
                "missing_source_target_unique_name_review_only",
                "Recover source server/database from item definition before promotion; object-name-only uniqueness is review evidence, not a hard rule.",
                "high",
                "no",
            )
        if casefold_diagnosis == "blocked_global_fabric_object_name_ambiguous" or catalog_match_class == "global_ambiguous_object_name":
            return (
                "missing_source_target_global_name_ambiguous",
                "Backfill source target from notebook/TMDL/CopyJob definition; same object name exists in multiple catalogs.",
                "high",
                "no",
            )
        return (
            "missing_source_target_no_local_catalog_match",
            "Review parser/source-target extraction; this is likely a source mapping gap, external source, alias, or object name not present in local catalogs.",
            "high",
            "no",
        )

    if gap == "metadata_query_failed":
        if catalog_match_class == "same_db_unique_schema_match" and not unsupported_same_db:
            return (
                "metadata_access_failed_but_strict_local_catalog_match_available",
                "Candidate for controlled evidence promotion by resolver update; verify the same server/database match and allowed object type before merging.",
                "high",
                "review_candidate",
            )
        if catalog_match_class == "same_db_multiple_schema_match":
            return (
                "metadata_access_failed_same_db_multiple_schema_matches",
                "Choose schema from source code or definition before promotion.",
                "high",
                "no",
            )
        if source_db_status == "source_db_not_in_local_catalog":
            return (
                "metadata_access_failed_source_db_not_cataloged",
                "Obtain/read approved metadata for the stated host/database; do not substitute same-name objects from other databases.",
                "high",
                "no",
            )
        return (
            f"metadata_access_failed_{error_class}",
            "Retry read-only metadata with the correct auth/network path or owner-provided catalog evidence.",
            "high",
            "no",
        )

    if gap == "object_not_found":
        if catalog_match_class == "same_db_unique_schema_match" and unsupported_same_db:
            return (
                "object_exists_as_unsupported_physical_type",
                "Review parser/query semantics; the name exists in the target database but not as table/view/stored procedure.",
                "high",
                "no",
            )
        if catalog_match_class == "same_db_unique_schema_match":
            return (
                "object_found_by_casefold_or_schema_gap",
                "Candidate for resolver review; confirm exact schema/type before evidence merge.",
                "medium",
                "review_candidate",
            )
        if source_db_status == "source_db_cataloged":
            return (
                "object_absent_in_confirmed_source_database",
                "Owner/source-definition review required; likely stale object, alias, wrong database, or object generated at runtime.",
                "high",
                "no",
            )
        return (
            "object_not_found_without_confirmed_source_catalog",
            "Confirm the source target first, then retry metadata lookup.",
            "medium",
            "no",
        )

    if gap == "object_name_found_in_multiple_schemas":
        return (
            "same_database_multiple_schema_disambiguation",
            "Use code/TMDL/native query text to choose the schema before promotion.",
            "high",
            "no",
        )

    if catalog_match_class == "source_db_not_in_local_catalog":
        return (
            "uncataloged_source_without_gap_reason",
            "Add source catalog access or owner evidence; current row lacks a precise metadata gap reason.",
            "medium",
            "no",
        )

    return (
        "unclassified_manual_review",
        "Manual review required; keep out of hard orchestration rules until evidence is explicit.",
        "low",
        "no",
    )


def main() -> None:
    d4_rows = read_csv("analysis/d4_closure_control_queue.csv")
    casefold_rows = read_csv("analysis/e1_casefold_catalog_backfill_diagnosis.csv")
    catalog = load_catalog()

    by_exact: dict[tuple[str, str, str, str], list[dict[str, str]]] = defaultdict(list)
    by_same_db_obj: dict[tuple[str, str, str], list[dict[str, str]]] = defaultdict(list)
    by_source_db: set[tuple[str, str]] = set()
    by_global_obj: dict[str, list[dict[str, str]]] = defaultdict(list)

    for row in catalog:
        server = norm(row.get("source_server"))
        database = norm(row.get("source_database"))
        schema = norm(row.get("schema_name"))
        obj = norm(row.get("object_name"))
        if not obj:
            continue
        if server and database:
            by_source_db.add((server, database))
            by_same_db_obj[(server, database, obj)].append(row)
            if schema:
                by_exact[(server, database, schema, obj)].append(row)
        by_global_obj[obj].append(row)

    casefold_by_key: dict[tuple[str, str, str, str, str, str], str] = {}
    casefold_by_object_key: dict[tuple[str, str, str, str, str], str] = {}
    for row in casefold_rows:
        full_key = (
            norm(row.get("source_type")),
            norm(row.get("source_server")),
            norm(row.get("source_database")),
            norm(row.get("schema_name")),
            norm(row.get("object_name")),
            norm(row.get("raw_object_type")),
        )
        object_key = full_key[:-1]
        casefold_by_key[full_key] = text(row.get("diagnosis"))
        casefold_by_object_key[object_key] = text(row.get("diagnosis"))

    output_rows: list[dict[str, str]] = []
    for index, row in enumerate(d4_rows, start=1):
        server = norm(row.get("source_server"))
        database = norm(row.get("source_database"))
        schema = norm(row.get("schema_name"))
        obj = norm(row.get("object_name"))
        full_key = (
            norm(row.get("source_type")),
            server,
            database,
            schema,
            obj,
            norm(row.get("raw_object_type")),
        )
        object_key = full_key[:-1]
        casefold_diagnosis = casefold_by_key.get(full_key) or casefold_by_object_key.get(object_key) or ""

        exact_matches = by_exact.get((server, database, schema, obj), []) if server and database and schema and obj else []
        same_db_matches = by_same_db_obj.get((server, database, obj), []) if server and database and obj else []
        global_matches = by_global_obj.get(obj, []) if obj else []
        source_db_status = (
            "source_target_missing"
            if not server or not database
            else "source_db_cataloged"
            if (server, database) in by_source_db
            else "source_db_not_in_local_catalog"
        )

        if exact_matches:
            catalog_match_class = "exact_catalog_match"
            match_rows = exact_matches
        elif len(same_db_matches) == 1:
            catalog_match_class = "same_db_unique_schema_match"
            match_rows = same_db_matches
        elif len(same_db_matches) > 1:
            catalog_match_class = "same_db_multiple_schema_match"
            match_rows = same_db_matches
        elif len(global_matches) == 1:
            catalog_match_class = "global_unique_object_name_only"
            match_rows = global_matches
        elif len(global_matches) > 1:
            catalog_match_class = "global_ambiguous_object_name"
            match_rows = global_matches
        else:
            catalog_match_class = "no_catalog_name_match"
            match_rows = []

        error_class = classify_error(text(row.get("metadata_error")))
        root_cause, action, confidence, candidate = root_cause_and_action(
            row,
            casefold_diagnosis,
            error_class,
            source_db_status,
            catalog_match_class,
            match_rows,
        )

        output_rows.append(
            {
                "classification_id": f"E2-{index:04d}",
                "d4_id": text(row.get("d4_id")),
                "source_id": text(row.get("source_id")),
                "priority_score": text(row.get("priority_score")),
                "priority_band": text(row.get("priority_band")),
                "source_type": text(row.get("source_type")),
                "source_server": text(row.get("source_server")),
                "source_database": text(row.get("source_database")),
                "schema_name": text(row.get("schema_name")),
                "object_name": text(row.get("object_name")),
                "raw_object_type": text(row.get("raw_object_type")),
                "metadata_gap_reason": text(row.get("metadata_gap_reason")),
                "closure_opportunity": text(row.get("closure_opportunity")),
                "metadata_error_class": error_class,
                "casefold_diagnosis": casefold_diagnosis,
                "source_db_status": source_db_status,
                "catalog_match_class": catalog_match_class,
                "catalog_match_count": str(len(match_rows)),
                "catalog_match_sample": compact_matches(match_rows),
                "root_cause_class": root_cause,
                "classification_confidence": confidence,
                "strict_promotion_candidate": candidate,
                "recommended_next_action": action,
                "affected_item_count": text(row.get("affected_item_count")),
                "semantic_model_count": text(row.get("semantic_model_count")),
                "operation_split": text(row.get("operation_split")),
                "affected_items_sample": text(row.get("affected_items_sample")),
            }
        )

    fields = [
        "classification_id",
        "d4_id",
        "source_id",
        "priority_score",
        "priority_band",
        "source_type",
        "source_server",
        "source_database",
        "schema_name",
        "object_name",
        "raw_object_type",
        "metadata_gap_reason",
        "closure_opportunity",
        "metadata_error_class",
        "casefold_diagnosis",
        "source_db_status",
        "catalog_match_class",
        "catalog_match_count",
        "catalog_match_sample",
        "root_cause_class",
        "classification_confidence",
        "strict_promotion_candidate",
        "recommended_next_action",
        "affected_item_count",
        "semantic_model_count",
        "operation_split",
        "affected_items_sample",
    ]
    write_csv("analysis/e2_unresolved_object_type_gap_classification.csv", output_rows, fields)

    summary_rows: list[dict[str, str]] = []
    for scope, column in [
        ("root_cause", "root_cause_class"),
        ("metadata_error_class", "metadata_error_class"),
        ("source_db_status", "source_db_status"),
        ("catalog_match_class", "catalog_match_class"),
        ("casefold_diagnosis", "casefold_diagnosis"),
        ("strict_promotion_candidate", "strict_promotion_candidate"),
    ]:
        counts = Counter(row[column] or "<blank>" for row in output_rows)
        for value, count in counts.most_common():
            summary_rows.append({"scope": scope, "value": value, "count": str(count)})
    write_csv("analysis/e2_unresolved_object_type_gap_summary.csv", summary_rows, ["scope", "value", "count"])

    segment_rows: list[dict[str, str]] = []
    segment_counts: Counter[tuple[str, str, str, str]] = Counter()
    segment_samples: dict[tuple[str, str, str, str], list[str]] = defaultdict(list)
    for row in output_rows:
        key = (
            row["root_cause_class"],
            row["source_server"] or "(missing)",
            row["source_database"] or "(missing)",
            row["metadata_gap_reason"] or "(blank)",
        )
        segment_counts[key] += 1
        if len(segment_samples[key]) < 5:
            segment_samples[key].append(
                ".".join(part for part in [row["schema_name"], row["object_name"]] if part)
                or row["object_name"]
            )

    for (root_cause, server, database, gap_reason), count in segment_counts.most_common():
        segment_rows.append(
            {
                "root_cause_class": root_cause,
                "source_server": server,
                "source_database": database,
                "metadata_gap_reason": gap_reason,
                "count": str(count),
                "sample_objects": "; ".join(segment_samples[(root_cause, server, database, gap_reason)]),
            }
        )
    write_csv(
        "analysis/e2_unresolved_object_type_gap_segment_summary.csv",
        segment_rows,
        ["root_cause_class", "source_server", "source_database", "metadata_gap_reason", "count", "sample_objects"],
    )

    doc_path = ROOT / "docs/44_unresolved_object_type_gap_classification.md"
    doc_path.parent.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()

    def md_counts(title: str, column: str, limit: int = 20) -> list[str]:
        lines = [f"## {title}", ""]
        counts = Counter(row[column] or "<blank>" for row in output_rows)
        for value, count in counts.most_common(limit):
            lines.append(f"- `{value}`: {count}")
        lines.append("")
        return lines

    doc_lines = [
        "# Unresolved Object Type Gap Classification",
        "",
        f"Generated: `{now}`",
        "",
        "Scope: current D4 unresolved object-type queue. This is a local/read-only classification; it does not promote evidence.",
        "",
        "Outputs:",
        "- `analysis/e2_unresolved_object_type_gap_classification.csv`",
        "- `analysis/e2_unresolved_object_type_gap_summary.csv`",
        "- `analysis/e2_unresolved_object_type_gap_segment_summary.csv`",
        "",
    ]
    doc_lines.extend(md_counts("Root Cause Classes", "root_cause_class"))
    doc_lines.extend(md_counts("Metadata Error Classes", "metadata_error_class"))
    doc_lines.extend(md_counts("Catalog Match Classes", "catalog_match_class"))
    doc_lines.extend(md_counts("Strict Promotion Candidate", "strict_promotion_candidate"))
    doc_lines.extend(["## Top Source Segments", ""])
    for row in segment_rows[:20]:
        doc_lines.append(
            f"- `{row['root_cause_class']}` / `{row['source_server']}` / "
            f"`{row['source_database']}` / `{row['metadata_gap_reason']}`: {row['count']}"
        )
    doc_lines.append("")
    doc_lines.extend(
        [
            "## Safety",
            "",
            "- Rows marked `review_candidate` are not automatically confirmed.",
            "- Object-name-only catalog matches remain review evidence only.",
            "- Same-name matches in other databases are not used as hard orchestration evidence.",
            "- Operational changes still require human approval and execution.",
            "",
        ]
    )
    doc_path.write_text("\n".join(doc_lines), encoding="utf-8")

    print("Unresolved object-type gap classification built.")
    print(f"Rows: {len(output_rows)}")
    print("Output: analysis/e2_unresolved_object_type_gap_classification.csv")
    print("Summary: analysis/e2_unresolved_object_type_gap_summary.csv")
    print("Segments: analysis/e2_unresolved_object_type_gap_segment_summary.csv")
    print("Doc: docs/44_unresolved_object_type_gap_classification.md")


if __name__ == "__main__":
    main()
