#!/usr/bin/env python3
"""Backfill missing semantic model source targets from metadata and model sources.

This script is intentionally narrow. It updates semantic model source
candidate rows only when read-only metadata evidence found the same
schema/object and that metadata target is also a confirmed source dependency
of the same semantic model.

It does not query external systems and it does not infer from global object
name matches.
"""

from __future__ import annotations

import argparse
import csv
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent  # Anchor default paths to the repo, not $PWD


MARKER = "semantic_metadata_model_source_target_backfill"

BACKFILL_COLUMNS = [
    "semantic_model_qualified_name",
    "workspace_name",
    "workspace_environment",
    "semantic_model_name",
    "semantic_table",
    "schema_name",
    "object_name",
    "object_type",
    "backfilled_source_server",
    "backfilled_database_name",
    "metadata_object_type",
    "metadata_resolver",
    "metadata_type_code",
    "metadata_type_desc",
    "model_dependency_source_type",
    "definition_path",
    "status",
    "evidence",
]

SUMMARY_COLUMNS = ["scope", "value", "count", "notes"]

RELATIONAL_SOURCE_TYPES = {"sql", "fabric", "fabricorsql"}


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


def object_key(row: dict[str, str]) -> tuple[str, str]:
    schema = clean(row.get("schema_name")) or clean(row.get("metadata_schema_name"))
    obj = clean(row.get("object_name")) or clean(row.get("metadata_object_name"))
    return (norm(schema), norm(obj))


def dependency_target_key(source_type: str, server: str, database: str) -> tuple[str, str, str]:
    return (norm(source_type), norm(server), norm(database))


def metadata_databases(row: dict[str, str]) -> list[str]:
    raw = clean(row.get("metadata_database")) or clean(row.get("source_database"))
    parts = [part.strip() for part in raw.split(";") if part.strip()]
    return parts or [""]


def metadata_server(row: dict[str, str]) -> str:
    return clean(row.get("metadata_server")) or clean(row.get("source_server"))


def append_evidence(existing: str, addition: str) -> str:
    existing = clean(existing)
    if MARKER in existing:
        return existing
    if not existing:
        return addition
    return f"{existing} {addition}"


def make_backfill_row(
    row: dict[str, str],
    metadata_row: dict[str, str],
    dependency_row: dict[str, str],
    source_server: str,
    database_name: str,
    status: str,
    evidence: str,
) -> dict[str, str]:
    return {
        "semantic_model_qualified_name": row.get("semantic_model_qualified_name", ""),
        "workspace_name": row.get("workspace_name", ""),
        "workspace_environment": row.get("workspace_environment", ""),
        "semantic_model_name": row.get("semantic_model_name", ""),
        "semantic_table": row.get("semantic_table", ""),
        "schema_name": row.get("schema_name", ""),
        "object_name": row.get("object_name", ""),
        "object_type": row.get("object_type", ""),
        "backfilled_source_server": source_server,
        "backfilled_database_name": database_name,
        "metadata_object_type": metadata_row.get("object_type", ""),
        "metadata_resolver": metadata_row.get("resolver", ""),
        "metadata_type_code": metadata_row.get("metadata_type_code", ""),
        "metadata_type_desc": metadata_row.get("metadata_type_desc", ""),
        "model_dependency_source_type": dependency_row.get("source_type", ""),
        "definition_path": row.get("definition_path", ""),
        "status": status,
        "evidence": evidence,
    }


def build_model_targets(
    dependency_rows: list[dict[str, str]],
) -> dict[str, dict[tuple[str, str, str], dict[str, str]]]:
    targets_by_model: dict[str, dict[tuple[str, str, str], dict[str, str]]] = defaultdict(dict)
    for row in dependency_rows:
        model_name = clean(row.get("semantic_model_qualified_name"))
        source_type = clean(row.get("source_type"))
        server = clean(row.get("source_server"))
        database = clean(row.get("datamart_name"))
        confidence = norm(row.get("confidence"))
        if not model_name or confidence != "confirmed" or not (server or database):
            continue

        aliases = {source_type, "SQL", "Fabric", "FabricOrSQL"}
        for alias in aliases:
            if norm(alias) in RELATIONAL_SOURCE_TYPES:
                targets_by_model[model_name][dependency_target_key(alias, server, database)] = row
    return targets_by_model


def build_metadata_by_object(
    metadata_rows: list[dict[str, str]],
) -> dict[tuple[str, str], list[dict[str, str]]]:
    rows_by_object: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
    for row in metadata_rows:
        key = object_key(row)
        if not key[1]:
            continue
        if norm(row.get("confidence")) not in {"", "confirmed"}:
            continue
        if metadata_server(row) or metadata_databases(row):
            rows_by_object[key].append(row)
    return rows_by_object


def matching_model_metadata_targets(
    candidate: dict[str, str],
    metadata_rows: list[dict[str, str]],
    model_targets: dict[tuple[str, str, str], dict[str, str]],
) -> list[tuple[dict[str, str], dict[str, str], str, str]]:
    matches: list[tuple[dict[str, str], dict[str, str], str, str]] = []
    for metadata_row in metadata_rows:
        server = metadata_server(metadata_row)
        for database in metadata_databases(metadata_row):
            for source_type in ("SQL", "Fabric", "FabricOrSQL"):
                dependency = model_targets.get(dependency_target_key(source_type, server, database))
                if dependency:
                    matches.append((metadata_row, dependency, server, database))
    return matches


def build_doc(path: str | Path, backfill_rows: list[dict[str, str]], changed_count: int, applied: bool) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    status_counts = Counter(row.get("status", "") for row in backfill_rows)
    target_counts = Counter(
        (row.get("backfilled_source_server", ""), row.get("backfilled_database_name", ""))
        for row in backfill_rows
        if row.get("backfilled_source_server") or row.get("backfilled_database_name")
    )
    workspace_counts = Counter(row.get("workspace_name", "") for row in backfill_rows if row.get("workspace_name"))
    lines = [
        "# D4 Semantic Metadata Model Source Target Backfill",
        "",
        f"Generated: {datetime.now(timezone.utc).isoformat(timespec='seconds')}",
        "",
        "## Purpose",
        "",
        "Backfill missing semantic model source server/database values only when local metadata and model connection evidence agree.",
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
    lines.extend(["", "## Top Targets", ""])
    for (server, database), count in target_counts.most_common(12):
        lines.append(f"- {server}/{database}: {count}")
    lines.extend(["", "## Top Workspaces", ""])
    for workspace, count in workspace_counts.most_common(12):
        lines.append(f"- {workspace}: {count}")
    lines.extend(
        [
            "",
            "## Safety",
            "",
            "- Local CSV evidence only.",
            "- No external system was queried.",
            "- No source target is inferred from global object-name matches.",
            "- Matching is case-insensitive, so capitalization differences do not block safe matches.",
            "- Matching requires the same schema/object in metadata and exactly one server/database target that is also a confirmed source dependency of the same semantic model.",
            "- The script does not fill blank schema names.",
            "",
            "## Outputs",
            "",
            "- `analysis/d4_semantic_metadata_model_target_backfill.csv`",
            "- `analysis/d4_semantic_metadata_model_target_backfill_summary.csv`",
            "- `docs/52_d4_semantic_metadata_model_target_backfill.md`",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", default=str(REPO_ROOT / "analysis/semantic_model_view_candidates.csv"))
    parser.add_argument("--output", default=str(REPO_ROOT / "analysis/semantic_model_view_candidates.csv"))
    parser.add_argument("--dependency-input", default=str(REPO_ROOT / "analysis/semantic_model_datamart_dependencies.csv"))
    parser.add_argument("--metadata-input", default=str(REPO_ROOT / "analysis/source_object_type_metadata_evidence.csv"))
    parser.add_argument("--backfill-output", default=str(REPO_ROOT / "analysis/d4_semantic_metadata_model_target_backfill.csv"))
    parser.add_argument("--summary-output", default=str(REPO_ROOT / "analysis/d4_semantic_metadata_model_target_backfill_summary.csv"))
    parser.add_argument("--doc-output", default=str(REPO_ROOT / "docs/52_d4_semantic_metadata_model_target_backfill.md"))
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    rows, columns = read_csv(args.input)
    dependency_rows, _ = read_csv(args.dependency_input)
    metadata_rows, _ = read_csv(args.metadata_input)
    if not rows:
        write_csv(args.backfill_output, [], BACKFILL_COLUMNS)
        write_csv(args.summary_output, [], SUMMARY_COLUMNS)
        build_doc(args.doc_output, [], 0, args.apply)
        print("No semantic model source candidates found.")
        return 0

    targets_by_model = build_model_targets(dependency_rows)
    metadata_by_object = build_metadata_by_object(metadata_rows)

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
                    {},
                    {},
                    output.get("source_server", ""),
                    output.get("database_name", ""),
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

        if not row.get("schema_name"):
            blocker_counts["blank_schema_not_backfilled"] += 1
            output_rows.append(output)
            continue

        metadata_matches = metadata_by_object.get(object_key(row), [])
        if not metadata_matches:
            blocker_counts["no_metadata_object_match"] += 1
            output_rows.append(output)
            continue

        model_name = clean(row.get("semantic_model_qualified_name"))
        model_targets = targets_by_model.get(model_name, {})
        if not model_targets:
            blocker_counts["no_confirmed_model_source_target"] += 1
            output_rows.append(output)
            continue

        matches = matching_model_metadata_targets(row, metadata_matches, model_targets)
        unique_targets = {(norm(server), norm(database)) for _, _, server, database in matches}
        if len(unique_targets) != 1:
            blocker_counts["multiple_model_metadata_target_matches" if unique_targets else "metadata_match_not_in_model_sources"] += 1
            output_rows.append(output)
            continue

        metadata_row, dependency_row, source_server, database_name = matches[0]
        addition = (
            f"Source endpoint backfilled by {MARKER} because read-only metadata found "
            f"{row.get('schema_name','')}.{row.get('object_name','')} in {source_server}/{database_name} "
            "and the same semantic model has a confirmed source dependency on that target."
        )
        output["source_server"] = source_server
        output["database_name"] = database_name
        output["evidence"] = append_evidence(evidence, addition)
        changed_rows += 1
        backfill_rows.append(
            make_backfill_row(output, metadata_row, dependency_row, source_server, database_name, "applied", addition)
        )
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

    print(f"Semantic metadata/model source target backfill rows changed: {changed_rows}")
    print(f"Backfill rows emitted or retained: {len(backfill_rows)}")
    print(f"Applied: {'yes' if args.apply else 'no'}")
    print(f"Output: {args.backfill_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
