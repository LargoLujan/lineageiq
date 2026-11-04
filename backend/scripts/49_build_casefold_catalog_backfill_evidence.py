#!/usr/bin/env python3
"""Build safe case-insensitive catalog evidence for unresolved object types.

This script is intentionally conservative. It promotes only unique catalog
matches where the lineage candidate already has enough target context:

* SQL deep catalog: same server + database + schema/object, case-insensitive.
* Fabric SQL endpoint catalog: same database + schema/object when the source
  server is missing but the Fabric database/lakehouse name is present.

Global object-name matches are reported for review but are not merged.
"""

from __future__ import annotations

import argparse
import csv
from collections import defaultdict
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent  # Anchor default paths to the repo, not $PWD

EVIDENCE_COLUMNS = [
    "source_type",
    "source_server",
    "source_database",
    "schema_name",
    "object_name",
    "object_type",
    "confidence",
    "evidence",
    "resolver",
    "reviewed_at",
    "metadata_server",
    "metadata_database",
    "metadata_schema_name",
    "metadata_object_name",
    "metadata_type_code",
    "metadata_type_desc",
    "raw_object_type",
    "candidate_count",
    "impacted_item_count",
    "impacted_item_types",
    "impacted_items_sample",
    "notes",
]

DIAGNOSIS_COLUMNS = [
    "source_type",
    "source_server",
    "source_database",
    "schema_name",
    "object_name",
    "raw_object_type",
    "diagnosis",
    "promoted",
    "match_count",
    "match_sample",
    "case_variant",
    "notes",
]

ALLOWED_TYPES = {"table", "view", "stored_procedure"}


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


def norm(value: str | None) -> str:
    return (value or "").strip().casefold()


def clean(value: str | None) -> str:
    return (value or "").strip()


def normalize_object_type(value: str | None) -> str:
    clean_value = norm(value).replace(" ", "_").replace("-", "_")
    aliases = {
        "storedprocedure": "stored_procedure",
        "procedure": "stored_procedure",
        "proc": "stored_procedure",
        "sp": "stored_procedure",
        "tbl": "table",
    }
    return aliases.get(clean_value, clean_value)


def is_case_variant(candidate: dict[str, str], match: dict[str, str], catalog_kind: str) -> bool:
    if catalog_kind == "sql":
        pairs = [
            ("source_server", "source_server"),
            ("source_database", "database_name"),
            ("schema_name", "schema_name"),
            ("object_name", "object_name"),
        ]
    else:
        pairs = [
            ("source_database", "source_database"),
            ("schema_name", "schema_name"),
            ("object_name", "object_name"),
        ]
    for left, right in pairs:
        left_value = clean(candidate.get(left))
        right_value = clean(match.get(right))
        if left_value and right_value and left_value != right_value and norm(left_value) == norm(right_value):
            return True
    return False


def match_sample(matches: list[dict[str, str]], catalog_kind: str, limit: int = 5) -> str:
    values: list[str] = []
    for row in matches[:limit]:
        if catalog_kind == "sql":
            values.append(
                f"{row.get('source_server','')}/{row.get('database_name','')}/"
                f"{row.get('schema_name','')}.{row.get('object_name','')}:{row.get('object_type','')}"
            )
        else:
            values.append(
                f"{row.get('workspace_name','')}/{row.get('source_database','')}/"
                f"{row.get('schema_name','')}.{row.get('object_name','')}:{row.get('object_type','')}"
            )
    return "; ".join(values)


def build_indexes(
    sql_catalog_rows: list[dict[str, str]],
    fabric_catalog_rows: list[dict[str, str]],
) -> dict[str, defaultdict[tuple[str, ...], list[dict[str, str]]]]:
    indexes: dict[str, defaultdict[tuple[str, ...], list[dict[str, str]]]] = {
        "sql_schema": defaultdict(list),
        "sql_name": defaultdict(list),
        "sql_target": defaultdict(list),
        "fabric_db_schema": defaultdict(list),
        "fabric_db_name": defaultdict(list),
        "fabric_name": defaultdict(list),
    }

    for row in sql_catalog_rows:
        object_type = normalize_object_type(row.get("object_type"))
        if object_type not in ALLOWED_TYPES:
            continue
        server = norm(row.get("source_server"))
        database = norm(row.get("database_name"))
        schema = norm(row.get("schema_name"))
        object_name = norm(row.get("object_name"))
        indexes["sql_schema"][(server, database, schema, object_name)].append(row)
        indexes["sql_name"][(server, database, object_name)].append(row)
        indexes["sql_target"][(server, database)].append(row)

    for row in fabric_catalog_rows:
        object_type = normalize_object_type(row.get("object_type"))
        if object_type not in ALLOWED_TYPES:
            continue
        if row.get("catalog_status") not in ("", "confirmed"):
            continue
        database = norm(row.get("source_database"))
        schema = norm(row.get("schema_name"))
        object_name = norm(row.get("object_name"))
        indexes["fabric_db_schema"][(database, schema, object_name)].append(row)
        indexes["fabric_db_name"][(database, object_name)].append(row)
        indexes["fabric_name"][(object_name,)].append(row)

    return indexes


def unique_by_schema(matches: list[dict[str, str]], schema_column: str = "schema_name") -> list[dict[str, str]]:
    if not matches:
        return []
    schemas = {norm(row.get(schema_column)) for row in matches}
    types = {normalize_object_type(row.get("object_type")) for row in matches}
    if len(schemas) == 1 and len(types) == 1:
        return [matches[0]]
    return matches


def make_evidence_row(
    candidate: dict[str, str],
    match: dict[str, str],
    catalog_kind: str,
    reviewed_at: str,
) -> dict[str, str]:
    object_type = normalize_object_type(match.get("object_type"))
    if catalog_kind == "sql":
        metadata_server = match.get("source_server", "")
        metadata_database = match.get("database_name", "")
        metadata_type_code = match.get("type_code", "")
        metadata_type_desc = match.get("type_desc", "")
        resolver = "sql_deep_catalog_casefold_backfill"
        evidence = (
            "Case-insensitive read-only SQL deep catalog match found "
            f"{metadata_server}/{metadata_database}/"
            f"{match.get('schema_name','')}.{match.get('object_name','')} as {metadata_type_desc or object_type}."
        )
    else:
        metadata_server = match.get("source_server", "")
        metadata_database = match.get("source_database", "")
        metadata_type_code = match.get("metadata_type_code", "")
        metadata_type_desc = match.get("metadata_type_desc", "")
        resolver = "fabric_sql_endpoint_casefold_backfill"
        evidence = (
            "Case-insensitive Fabric SQL endpoint catalog match found "
            f"{metadata_server}/{metadata_database}/"
            f"{match.get('schema_name','')}.{match.get('object_name','')} as {metadata_type_desc or object_type}."
        )

    case_variant = is_case_variant(candidate, match, catalog_kind)
    notes = "Strict case-insensitive catalog match."
    if catalog_kind == "fabric":
        notes += " Source server was missing in lineage; type is resolved from Fabric SQL endpoint catalog by database/schema/object."
    if case_variant:
        notes += " Candidate casing differs from catalog casing."

    return {
        "source_type": candidate.get("source_type", ""),
        "source_server": candidate.get("source_server", ""),
        "source_database": candidate.get("source_database", ""),
        "schema_name": candidate.get("schema_name", ""),
        "object_name": candidate.get("object_name", ""),
        "object_type": object_type,
        "confidence": "confirmed",
        "evidence": evidence,
        "resolver": resolver,
        "reviewed_at": reviewed_at,
        "metadata_server": metadata_server,
        "metadata_database": metadata_database,
        "metadata_schema_name": match.get("schema_name", ""),
        "metadata_object_name": match.get("object_name", ""),
        "metadata_type_code": metadata_type_code,
        "metadata_type_desc": metadata_type_desc,
        "raw_object_type": candidate.get("raw_object_type", ""),
        "candidate_count": candidate.get("candidate_count", ""),
        "impacted_item_count": candidate.get("affected_item_count", ""),
        "impacted_item_types": candidate.get("affected_item_types", ""),
        "impacted_items_sample": candidate.get("affected_items", ""),
        "notes": notes,
    }


def get_unique_fabric_match(
    indexes: dict[str, defaultdict[tuple[str, ...], list[dict[str, str]]]],
    database: str,
    schema: str,
    object_name: str,
) -> tuple[list[dict[str, str]], str]:
    if not database or not object_name:
        return [], ""
    if schema:
        matches = indexes["fabric_db_schema"].get((database, schema, object_name), [])
        if len(matches) == 1:
            return matches, "fabric_db_schema"
        if len(matches) > 1:
            return matches, "fabric_db_schema_multiple"

    matches = unique_by_schema(indexes["fabric_db_name"].get((database, object_name), []))
    if len(matches) == 1:
        return matches, "fabric_db_name_unique_schema"
    if len(matches) > 1:
        return matches, "fabric_db_name_multiple"
    return [], ""


def should_try_fabric_catalog(candidate: dict[str, str]) -> bool:
    source_type = norm(candidate.get("source_type"))
    source_server = norm(candidate.get("source_server"))
    source_database = norm(candidate.get("source_database"))
    if source_type in {"fabric", "fabricorsql", "lakehouse", "warehouse"}:
        return True
    if source_database.startswith("lh_"):
        return True
    if ".datawarehouse.fabric.microsoft.com" in source_server:
        return True
    return False


def diagnosis_row(
    candidate: dict[str, str],
    diagnosis: str,
    promoted: bool,
    matches: list[dict[str, str]],
    catalog_kind: str,
    notes: str,
) -> dict[str, str]:
    case_variant = "false"
    if len(matches) == 1 and is_case_variant(candidate, matches[0], catalog_kind):
        case_variant = "true"
    return {
        "source_type": candidate.get("source_type", ""),
        "source_server": candidate.get("source_server", ""),
        "source_database": candidate.get("source_database", ""),
        "schema_name": candidate.get("schema_name", ""),
        "object_name": candidate.get("object_name", ""),
        "raw_object_type": candidate.get("raw_object_type", ""),
        "diagnosis": diagnosis,
        "promoted": "true" if promoted else "false",
        "match_count": str(len(matches)),
        "match_sample": match_sample(matches, catalog_kind),
        "case_variant": case_variant,
        "notes": notes,
    }


def evidence_key(row: dict[str, str]) -> tuple[str, ...]:
    return (
        norm(row.get("source_type")),
        norm(row.get("source_server")),
        norm(row.get("source_database")),
        norm(row.get("schema_name")),
        norm(row.get("object_name")),
        normalize_object_type(row.get("object_type")),
    )


def merge_evidence(base_path: str | Path, additional_rows: list[dict[str, str]]) -> tuple[int, int, int]:
    base_rows = read_csv(base_path)
    merged: dict[tuple[str, ...], dict[str, str]] = {}
    for row in base_rows:
        merged[evidence_key(row)] = row
    added = 0
    for row in additional_rows:
        key = evidence_key(row)
        if key not in merged:
            added += 1
        merged[key] = row
    merged_rows = sorted(
        merged.values(),
        key=lambda row: (
            norm(row.get("source_type")),
            norm(row.get("source_server")),
            norm(row.get("source_database")),
            norm(row.get("schema_name")),
            norm(row.get("object_name")),
            normalize_object_type(row.get("object_type")),
        ),
    )
    write_csv(base_path, merged_rows, EVIDENCE_COLUMNS)
    return len(base_rows), added, len(merged_rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resolution-queue", default=str(REPO_ROOT / "analysis/source_object_type_resolution_queue.csv"))
    parser.add_argument("--sql-catalog", action="append", default=[
        "analysis/sql_server_deep_catalog_objects.csv",
        "analysis/sql_server_deep_catalog_more_sql_objects.csv",
    ])
    parser.add_argument("--fabric-catalog", default=str(REPO_ROOT / "analysis/sql_endpoint_object_catalog.csv"))
    parser.add_argument("--evidence-output", default=str(REPO_ROOT / "analysis/source_object_type_casefold_catalog_evidence.csv"))
    parser.add_argument("--diagnosis-output", default=str(REPO_ROOT / "analysis/e1_casefold_catalog_backfill_diagnosis.csv"))
    parser.add_argument("--merge-into", default="")
    args = parser.parse_args()

    pending = [
        row for row in read_csv(args.resolution_queue)
        if row.get("status") == "needs_metadata_review"
        and normalize_object_type(row.get("raw_object_type")) in {"table_or_view", "native_query_object"}
    ]
    sql_catalog_rows: list[dict[str, str]] = []
    for path in args.sql_catalog:
        sql_catalog_rows.extend(read_csv(path))
    fabric_catalog_rows = read_csv(args.fabric_catalog)
    indexes = build_indexes(sql_catalog_rows, fabric_catalog_rows)
    reviewed_at = datetime.now().replace(microsecond=0).isoformat()

    evidence_rows_by_key: dict[tuple[str, ...], dict[str, str]] = {}
    diagnosis_rows: list[dict[str, str]] = []

    for candidate in pending:
        server = norm(candidate.get("source_server"))
        database = norm(candidate.get("source_database"))
        schema = norm(candidate.get("schema_name"))
        object_name = norm(candidate.get("object_name"))
        if not object_name:
            continue

        if should_try_fabric_catalog(candidate):
            matches, match_mode = get_unique_fabric_match(indexes, database, schema, object_name)
            if len(matches) == 1:
                row = make_evidence_row(candidate, matches[0], "fabric", reviewed_at)
                evidence_rows_by_key[evidence_key(row)] = row
                diagnosis_rows.append(diagnosis_row(
                    candidate,
                    f"promoted_{match_mode}",
                    True,
                    matches,
                    "fabric",
                    "Unique Fabric SQL endpoint catalog match by database/schema/object or database/object.",
                ))
                continue
            if len(matches) > 1:
                diagnosis_rows.append(diagnosis_row(
                    candidate,
                    f"blocked_{match_mode}",
                    False,
                    matches,
                    "fabric",
                    "Multiple Fabric catalog matches; not promoted.",
                ))
                continue

        promoted = False
        if server and database:
            if schema:
                matches = indexes["sql_schema"].get((server, database, schema, object_name), [])
                if len(matches) == 1:
                    row = make_evidence_row(candidate, matches[0], "sql", reviewed_at)
                    evidence_rows_by_key[evidence_key(row)] = row
                    diagnosis_rows.append(diagnosis_row(candidate, "promoted_sql_deep_catalog_same_endpoint", True, matches, "sql", "Unique same server/database/schema/object match."))
                    promoted = True
                elif len(matches) > 1:
                    diagnosis_rows.append(diagnosis_row(candidate, "blocked_multiple_sql_catalog_matches", False, matches, "sql", "Multiple same-endpoint matches; not promoted."))
                    promoted = True
            else:
                matches = unique_by_schema(indexes["sql_name"].get((server, database, object_name), []))
                if len(matches) == 1:
                    row = make_evidence_row(candidate, matches[0], "sql", reviewed_at)
                    evidence_rows_by_key[evidence_key(row)] = row
                    diagnosis_rows.append(diagnosis_row(candidate, "promoted_sql_deep_catalog_unique_name_same_endpoint", True, matches, "sql", "Unique same server/database/object match."))
                    promoted = True
                elif len(matches) > 1:
                    diagnosis_rows.append(diagnosis_row(candidate, "blocked_multiple_sql_catalog_name_matches", False, matches, "sql", "Multiple same-endpoint object-name matches; not promoted."))
                    promoted = True

            if not promoted:
                target_rows = indexes["sql_target"].get((server, database), [])
                diagnosis = "sql_target_not_in_local_deep_catalog" if not target_rows else "sql_object_not_found_in_local_deep_catalog"
                diagnosis_rows.append(diagnosis_row(candidate, diagnosis, False, [], "sql", "No strict case-insensitive SQL catalog match."))
            continue

        if database:
            if schema:
                matches = indexes["fabric_db_schema"].get((database, schema, object_name), [])
                if len(matches) == 1:
                    row = make_evidence_row(candidate, matches[0], "fabric", reviewed_at)
                    evidence_rows_by_key[evidence_key(row)] = row
                    diagnosis_rows.append(diagnosis_row(candidate, "promoted_fabric_catalog_database_schema_object", True, matches, "fabric", "Unique Fabric catalog database/schema/object match."))
                    continue
                if len(matches) > 1:
                    diagnosis_rows.append(diagnosis_row(candidate, "blocked_multiple_fabric_catalog_database_schema_matches", False, matches, "fabric", "Multiple Fabric catalog database/schema/object matches; not promoted."))
                    continue

            matches = unique_by_schema(indexes["fabric_db_name"].get((database, object_name), []))
            if len(matches) == 1:
                row = make_evidence_row(candidate, matches[0], "fabric", reviewed_at)
                evidence_rows_by_key[evidence_key(row)] = row
                diagnosis_rows.append(diagnosis_row(candidate, "promoted_fabric_catalog_database_object_unique_schema", True, matches, "fabric", "Unique Fabric catalog database/object match."))
                continue
            if len(matches) > 1:
                diagnosis_rows.append(diagnosis_row(candidate, "blocked_multiple_fabric_catalog_database_object_matches", False, matches, "fabric", "Multiple Fabric catalog database/object matches; not promoted."))
                continue

            diagnosis_rows.append(diagnosis_row(candidate, "missing_source_server_no_fabric_catalog_match", False, [], "fabric", "Source database exists in lineage but no Fabric catalog match was found."))
            continue

        global_matches = indexes["fabric_name"].get((object_name,), [])
        if len(global_matches) == 1:
            diagnosis_rows.append(diagnosis_row(candidate, "review_only_global_unique_fabric_object_name", False, global_matches, "fabric", "Object name is globally unique in Fabric catalog, but source database is missing; not promoted."))
        elif len(global_matches) > 1:
            diagnosis_rows.append(diagnosis_row(candidate, "blocked_global_fabric_object_name_ambiguous", False, global_matches, "fabric", "Object name exists in multiple Fabric catalog locations; not promoted."))
        else:
            diagnosis_rows.append(diagnosis_row(candidate, "missing_source_target_no_catalog_match", False, [], "fabric", "No source server/database and no unique catalog match."))

    evidence_rows = sorted(
        evidence_rows_by_key.values(),
        key=lambda row: (
            norm(row.get("source_type")),
            norm(row.get("source_server")),
            norm(row.get("source_database")),
            norm(row.get("schema_name")),
            norm(row.get("object_name")),
        ),
    )
    diagnosis_rows = sorted(
        diagnosis_rows,
        key=lambda row: (
            row.get("promoted") != "true",
            row.get("diagnosis", ""),
            norm(row.get("source_server")),
            norm(row.get("source_database")),
            norm(row.get("schema_name")),
            norm(row.get("object_name")),
        ),
    )

    write_csv(args.evidence_output, evidence_rows, EVIDENCE_COLUMNS)
    write_csv(args.diagnosis_output, diagnosis_rows, DIAGNOSIS_COLUMNS)

    print(f"Pending candidates considered: {len(pending)}")
    print(f"Evidence rows produced: {len(evidence_rows)}")
    print(f"Diagnosis rows produced: {len(diagnosis_rows)}")
    if args.merge_into:
        base, added, total = merge_evidence(args.merge_into, evidence_rows)
        print(f"Merged into {args.merge_into}: base={base}, added={added}, total={total}")
    print(f"Evidence: {args.evidence_output}")
    print(f"Diagnosis: {args.diagnosis_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
