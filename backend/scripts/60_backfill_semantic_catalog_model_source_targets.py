#!/usr/bin/env python3
"""Backfill semantic model source targets from full local catalogs.

This script uses only local catalog evidence. A missing semantic source target
is backfilled only when:

1. the semantic model has a confirmed source dependency for the target, and
2. the object exists exactly once inside that model's confirmed target set.

For rows without schema, the schema is filled only when the same object has a
single schema/type/target match in those confirmed targets.
"""

from __future__ import annotations

import argparse
import csv
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent  # Anchor default paths to the repo, not $PWD


MARKER = "semantic_catalog_model_source_target_backfill"

BACKFILL_COLUMNS = [
    "semantic_model_qualified_name",
    "workspace_name",
    "workspace_environment",
    "semantic_model_name",
    "semantic_table",
    "schema_name_before",
    "object_name",
    "object_type",
    "backfilled_source_server",
    "backfilled_database_name",
    "backfilled_schema_name",
    "catalog_object_type",
    "catalog_source",
    "catalog_type_code",
    "catalog_type_desc",
    "match_mode",
    "definition_path",
    "status",
    "evidence",
]

SUMMARY_COLUMNS = ["scope", "value", "count", "notes"]


def norm(value: str | None) -> str:
    return (value or "").strip().casefold()


def clean(value: str | None) -> str:
    return (value or "").strip()


def read_csv(path: str | Path) -> tuple[list[dict[str, str]], list[str]]:
    path = Path(path)
    if not path.exists():
        return [], []
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle)
        return list(reader), list(reader.fieldnames or [])


def write_csv(path: str | Path, rows: list[dict[str, str]], columns: list[str]) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({column: row.get(column, "") for column in columns})


def target_key(server: str, database: str) -> tuple[str, str]:
    return (norm(server), norm(database))


def catalog_identity(row: dict[str, str]) -> tuple[str, str, str, str, str]:
    return (
        norm(row.get("_source_server")),
        norm(row.get("_source_database")),
        norm(row.get("_schema_name")),
        norm(row.get("_object_name")),
        norm(row.get("_object_type")),
    )


def append_evidence(existing: str, addition: str) -> str:
    existing = clean(existing)
    if MARKER in existing:
        return existing
    if not existing:
        return addition
    return f"{existing} {addition}"


def build_model_targets(dependency_rows: list[dict[str, str]]) -> dict[str, set[tuple[str, str]]]:
    targets_by_model: dict[str, set[tuple[str, str]]] = defaultdict(set)
    for row in dependency_rows:
        model_name = clean(row.get("semantic_model_qualified_name"))
        server = clean(row.get("source_server"))
        database = clean(row.get("datamart_name"))
        if not model_name or norm(row.get("confidence")) != "confirmed" or not (server or database):
            continue
        targets_by_model[model_name].add(target_key(server, database))
    return targets_by_model


def normalize_sql_catalog_row(row: dict[str, str]) -> dict[str, str]:
    output = dict(row)
    output["_catalog"] = "sql_server_deep_catalog_objects"
    output["_source_server"] = clean(row.get("source_server"))
    output["_source_database"] = clean(row.get("database_name"))
    output["_schema_name"] = clean(row.get("schema_name"))
    output["_object_name"] = clean(row.get("object_name"))
    output["_object_type"] = clean(row.get("object_type"))
    output["_type_code"] = clean(row.get("type_code"))
    output["_type_desc"] = clean(row.get("type_desc"))
    return output


def normalize_fabric_catalog_row(row: dict[str, str]) -> dict[str, str]:
    output = dict(row)
    output["_catalog"] = "sql_endpoint_object_catalog"
    output["_source_server"] = clean(row.get("source_server"))
    output["_source_database"] = clean(row.get("source_database"))
    output["_schema_name"] = clean(row.get("schema_name"))
    output["_object_name"] = clean(row.get("object_name"))
    output["_object_type"] = clean(row.get("object_type"))
    output["_type_code"] = clean(row.get("metadata_type_code"))
    output["_type_desc"] = clean(row.get("metadata_type_desc"))
    return output


def build_catalog_by_target_object(
    sql_catalog_rows: list[dict[str, str]],
    fabric_catalog_rows: list[dict[str, str]],
) -> dict[tuple[tuple[str, str], str], list[dict[str, str]]]:
    catalog: dict[tuple[tuple[str, str], str], list[dict[str, str]]] = defaultdict(list)

    for row in sql_catalog_rows:
        normalized = normalize_sql_catalog_row(row)
        if not normalized["_object_name"] or not normalized["_source_database"]:
            continue
        key = (target_key(normalized["_source_server"], normalized["_source_database"]), norm(normalized["_object_name"]))
        catalog[key].append(normalized)

    for row in fabric_catalog_rows:
        if clean(row.get("catalog_status")) not in ("", "confirmed"):
            continue
        normalized = normalize_fabric_catalog_row(row)
        if not normalized["_object_name"] or not (normalized["_source_server"] or normalized["_source_database"]):
            continue
        key = (target_key(normalized["_source_server"], normalized["_source_database"]), norm(normalized["_object_name"]))
        catalog[key].append(normalized)

    return catalog


def find_catalog_matches(
    row: dict[str, str],
    model_targets: set[tuple[str, str]],
    catalog_by_target_object: dict[tuple[tuple[str, str], str], list[dict[str, str]]],
) -> list[tuple[str, dict[str, str]]]:
    matches: list[tuple[str, dict[str, str]]] = []
    object_name = norm(row.get("object_name"))
    schema_name = clean(row.get("schema_name"))

    for target in model_targets:
        for catalog_row in catalog_by_target_object.get((target, object_name), []):
            if schema_name:
                if norm(catalog_row.get("_schema_name")) != norm(schema_name):
                    continue
                matches.append(("strict_with_schema", catalog_row))
            else:
                matches.append(("strict_unique_schema", catalog_row))
    return matches


def make_backfill_row(
    row: dict[str, str],
    catalog_row: dict[str, str],
    match_mode: str,
    status: str,
    evidence: str,
) -> dict[str, str]:
    return {
        "semantic_model_qualified_name": row.get("semantic_model_qualified_name", ""),
        "workspace_name": row.get("workspace_name", ""),
        "workspace_environment": row.get("workspace_environment", ""),
        "semantic_model_name": row.get("semantic_model_name", ""),
        "semantic_table": row.get("semantic_table", ""),
        "schema_name_before": row.get("schema_name", ""),
        "object_name": row.get("object_name", ""),
        "object_type": row.get("object_type", ""),
        "backfilled_source_server": catalog_row.get("_source_server", "") or row.get("source_server", ""),
        "backfilled_database_name": catalog_row.get("_source_database", "") or row.get("database_name", ""),
        "backfilled_schema_name": catalog_row.get("_schema_name", "") or row.get("schema_name", ""),
        "catalog_object_type": catalog_row.get("_object_type", ""),
        "catalog_source": catalog_row.get("_catalog", ""),
        "catalog_type_code": catalog_row.get("_type_code", ""),
        "catalog_type_desc": catalog_row.get("_type_desc", ""),
        "match_mode": match_mode,
        "definition_path": row.get("definition_path", ""),
        "status": status,
        "evidence": evidence,
    }


def build_doc(path: str | Path, backfill_rows: list[dict[str, str]], changed_count: int, applied: bool) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    status_counts = Counter(row.get("status", "") for row in backfill_rows)
    mode_counts = Counter(row.get("match_mode", "") for row in backfill_rows if row.get("match_mode"))
    target_counts = Counter(
        (row.get("backfilled_source_server", ""), row.get("backfilled_database_name", ""))
        for row in backfill_rows
        if row.get("backfilled_source_server") or row.get("backfilled_database_name")
    )
    lines = [
        "# D4 Semantic Catalog Model Source Target Backfill",
        "",
        f"Generated: {datetime.now(timezone.utc).isoformat(timespec='seconds')}",
        "",
        "## Purpose",
        "",
        "Backfill missing semantic model source targets from full local SQL/Fabric catalogs when the same model has a confirmed dependency on the matched target.",
        "",
        "## Result",
        "",
        f"- Candidate rows changed in this run: {changed_count}",
        f"- Backfill rows emitted or retained: {len(backfill_rows)}",
        f"- Applied to `analysis/semantic_model_view_candidates.csv`: {'yes' if applied else 'no'}",
        "",
        "## Status Counts",
        "",
    ]
    for status, count in status_counts.most_common():
        lines.append(f"- {status or 'blank'}: {count}")
    lines.extend(["", "## Match Modes", ""])
    for mode, count in mode_counts.most_common():
        lines.append(f"- {mode}: {count}")
    lines.extend(["", "## Top Targets", ""])
    for (server, database), count in target_counts.most_common(12):
        lines.append(f"- {server}/{database}: {count}")
    lines.extend(
        [
            "",
            "## Safety",
            "",
            "- Local CSV evidence only.",
            "- No external system was queried.",
            "- Matching is scoped to confirmed source dependencies of the same semantic model.",
            "- Object-name-only global catalog matches are not used.",
            "- Blank schema rows are backfilled only when one target/schema/type match exists inside the model's confirmed target set.",
            "",
            "## Outputs",
            "",
            "- `analysis/d4_semantic_catalog_model_target_backfill.csv`",
            "- `analysis/d4_semantic_catalog_model_target_backfill_summary.csv`",
            "- `docs/53_d4_semantic_catalog_model_target_backfill.md`",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", default=str(REPO_ROOT / "analysis/semantic_model_view_candidates.csv"))
    parser.add_argument("--output", default=str(REPO_ROOT / "analysis/semantic_model_view_candidates.csv"))
    parser.add_argument("--dependency-input", default=str(REPO_ROOT / "analysis/semantic_model_datamart_dependencies.csv"))
    parser.add_argument("--sql-catalog-input", default=str(REPO_ROOT / "analysis/sql_server_deep_catalog_objects.csv"))
    parser.add_argument("--fabric-catalog-input", default=str(REPO_ROOT / "analysis/sql_endpoint_object_catalog.csv"))
    parser.add_argument("--backfill-output", default=str(REPO_ROOT / "analysis/d4_semantic_catalog_model_target_backfill.csv"))
    parser.add_argument("--summary-output", default=str(REPO_ROOT / "analysis/d4_semantic_catalog_model_target_backfill_summary.csv"))
    parser.add_argument("--doc-output", default=str(REPO_ROOT / "docs/53_d4_semantic_catalog_model_target_backfill.md"))
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    rows, columns = read_csv(args.input)
    dependency_rows, _ = read_csv(args.dependency_input)
    sql_catalog_rows, _ = read_csv(args.sql_catalog_input)
    fabric_catalog_rows, _ = read_csv(args.fabric_catalog_input)

    if not rows:
        write_csv(args.backfill_output, [], BACKFILL_COLUMNS)
        write_csv(args.summary_output, [], SUMMARY_COLUMNS)
        build_doc(args.doc_output, [], 0, args.apply)
        print("No semantic model source candidates found.")
        return 0

    targets_by_model = build_model_targets(dependency_rows)
    catalog_by_target_object = build_catalog_by_target_object(sql_catalog_rows, fabric_catalog_rows)

    changed_rows = 0
    blocker_counts: Counter[str] = Counter()
    backfill_rows: list[dict[str, str]] = []
    output_rows: list[dict[str, str]] = []

    for row in rows:
        output = dict(row)
        evidence = clean(row.get("evidence"))
        already_backfilled = MARKER in evidence
        if already_backfilled:
            backfill_rows.append(
                make_backfill_row(
                    output,
                    {
                        "_source_server": output.get("source_server", ""),
                        "_source_database": output.get("database_name", ""),
                        "_schema_name": output.get("schema_name", ""),
                        "_object_type": "",
                        "_catalog": "",
                        "_type_code": "",
                        "_type_desc": "",
                    },
                    "retained",
                    "retained_existing_backfill",
                    evidence,
                )
            )
            output_rows.append(output)
            continue

        missing_target = not row.get("source_server") and not row.get("database_name") and row.get("object_name")
        if not missing_target:
            output_rows.append(output)
            continue

        model_name = clean(row.get("semantic_model_qualified_name"))
        model_targets = targets_by_model.get(model_name, set())
        if not model_targets:
            blocker_counts["no_confirmed_model_source_target"] += 1
            output_rows.append(output)
            continue

        matches = find_catalog_matches(row, model_targets, catalog_by_target_object)
        if not matches:
            blocker_counts["no_catalog_match_in_model_sources"] += 1
            output_rows.append(output)
            continue

        unique_catalog_identities = {catalog_identity(catalog_row) for _, catalog_row in matches}
        if len(unique_catalog_identities) != 1:
            blocker_counts["multiple_catalog_model_source_matches"] += 1
            output_rows.append(output)
            continue

        match_mode, catalog_row = matches[0]
        addition = (
            f"Source endpoint backfilled by {MARKER} using {catalog_row.get('_catalog','')} because "
            f"{catalog_row.get('_schema_name','')}.{catalog_row.get('_object_name','')} exists in "
            f"{catalog_row.get('_source_server','')}/{catalog_row.get('_source_database','')} and that target "
            "is a confirmed source dependency of the same semantic model."
        )
        output["source_server"] = catalog_row.get("_source_server", "")
        output["database_name"] = catalog_row.get("_source_database", "")
        if not output.get("schema_name") and catalog_row.get("_schema_name"):
            output["schema_name"] = catalog_row.get("_schema_name", "")
        output["evidence"] = append_evidence(evidence, addition)
        changed_rows += 1
        backfill_rows.append(make_backfill_row(output, catalog_row, match_mode, "applied", addition))
        output_rows.append(output)

    if args.apply:
        write_csv(args.output, output_rows, columns)

    summary_rows: list[dict[str, str]] = [
        {"scope": "total", "value": "input_rows", "count": str(len(rows)), "notes": args.input},
        {"scope": "total", "value": "changed_rows", "count": str(changed_rows), "notes": "Rows backfilled in this run."},
        {"scope": "total", "value": "backfill_rows_emitted_or_retained", "count": str(len(backfill_rows)), "notes": args.backfill_output},
    ]
    for status, count in Counter(row.get("status", "") for row in backfill_rows).most_common():
        summary_rows.append({"scope": "status", "value": status, "count": str(count), "notes": "Backfill row status."})
    for mode, count in Counter(row.get("match_mode", "") for row in backfill_rows if row.get("match_mode")).most_common():
        summary_rows.append({"scope": "match_mode", "value": mode, "count": str(count), "notes": "Strict match mode."})
    for reason, count in blocker_counts.most_common():
        summary_rows.append({"scope": "blocker", "value": reason, "count": str(count), "notes": "Rows intentionally not backfilled."})
    for target, count in Counter(
        f"{row.get('backfilled_source_server','')}/{row.get('backfilled_database_name','')}"
        for row in backfill_rows
        if row.get("backfilled_source_server") or row.get("backfilled_database_name")
    ).most_common():
        summary_rows.append({"scope": "target", "value": target, "count": str(count), "notes": "Backfilled rows by target."})
    for workspace, count in Counter(row.get("workspace_name", "") for row in backfill_rows if row.get("workspace_name")).most_common():
        summary_rows.append({"scope": "workspace", "value": workspace, "count": str(count), "notes": "Backfilled rows by workspace."})

    write_csv(args.backfill_output, backfill_rows, BACKFILL_COLUMNS)
    write_csv(args.summary_output, summary_rows, SUMMARY_COLUMNS)
    build_doc(args.doc_output, backfill_rows, changed_rows, args.apply)

    print(f"Semantic catalog/model source target backfill rows changed: {changed_rows}")
    print(f"Backfill rows emitted or retained: {len(backfill_rows)}")
    print(f"Applied: {'yes' if args.apply else 'no'}")
    print(f"Output: {args.backfill_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
