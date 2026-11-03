#!/usr/bin/env python3
"""Backfill missing semantic model source targets from exact sibling rows.

This script is intentionally narrow. It updates semantic model source
candidate rows only when the same semantic model name, semantic table,
schema, object name, and raw object type has exactly one non-empty
server/database target elsewhere in the candidate file.

It does not query external systems and it does not infer from global object
name matches.
"""

from __future__ import annotations

import argparse
import csv
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent  # D.0: anchor default paths to the repo, not $PWD

MARKER = "semantic_sibling_source_target_backfill"

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
    "sibling_semantic_model_qualified_name",
    "sibling_workspace_name",
    "sibling_workspace_environment",
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


def candidate_key(row: dict[str, str]) -> tuple[str, str, str, str, str]:
    return (
        norm(row.get("semantic_model_name")),
        norm(row.get("semantic_table")),
        norm(row.get("schema_name")),
        norm(row.get("object_name")),
        norm(row.get("object_type")),
    )


def target_key(row: dict[str, str]) -> tuple[str, str]:
    return (norm(row.get("source_server")), norm(row.get("database_name")))


def append_evidence(existing: str, addition: str) -> str:
    existing = clean(existing)
    if MARKER in existing:
        return existing
    if not existing:
        return addition
    return f"{existing} {addition}"


def make_backfill_row(row: dict[str, str], sibling: dict[str, str], status: str, evidence: str) -> dict[str, str]:
    return {
        "semantic_model_qualified_name": row.get("semantic_model_qualified_name", ""),
        "workspace_name": row.get("workspace_name", ""),
        "workspace_environment": row.get("workspace_environment", ""),
        "semantic_model_name": row.get("semantic_model_name", ""),
        "semantic_table": row.get("semantic_table", ""),
        "schema_name": row.get("schema_name", ""),
        "object_name": row.get("object_name", ""),
        "object_type": row.get("object_type", ""),
        "backfilled_source_server": sibling.get("source_server", ""),
        "backfilled_database_name": sibling.get("database_name", ""),
        "sibling_semantic_model_qualified_name": sibling.get("semantic_model_qualified_name", ""),
        "sibling_workspace_name": sibling.get("workspace_name", ""),
        "sibling_workspace_environment": sibling.get("workspace_environment", ""),
        "definition_path": row.get("definition_path", ""),
        "status": status,
        "evidence": evidence,
    }


def build_doc(path: str | Path, backfill_rows: list[dict[str, str]], changed_count: int, applied: bool) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    status_counts = Counter(row.get("status", "") for row in backfill_rows)
    workspace_counts = Counter(row.get("workspace_name", "") for row in backfill_rows if row.get("workspace_name"))
    lines = [
        "# D4 Semantic Sibling Source Target Backfill",
        "",
        f"Generated: {datetime.now(timezone.utc).isoformat(timespec='seconds')}",
        "",
        "## Purpose",
        "",
        "Backfill missing semantic model source server/database values only from exact sibling semantic model rows.",
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
            "- Matching requires same semantic model name, semantic table, schema, object name, and raw object type, with exactly one sibling source target.",
            "",
            "## Outputs",
            "",
            "- `analysis/d4_semantic_sibling_target_backfill.csv`",
            "- `analysis/d4_semantic_sibling_target_backfill_summary.csv`",
            "- `docs/51_d4_semantic_sibling_target_backfill.md`",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", default=str(REPO_ROOT / "analysis/semantic_model_view_candidates.csv"))
    parser.add_argument("--output", default=str(REPO_ROOT / "analysis/semantic_model_view_candidates.csv"))
    parser.add_argument("--backfill-output", default=str(REPO_ROOT / "analysis/d4_semantic_sibling_target_backfill.csv"))
    parser.add_argument("--summary-output", default=str(REPO_ROOT / "analysis/d4_semantic_sibling_target_backfill_summary.csv"))
    parser.add_argument("--doc-output", default=str(REPO_ROOT / "docs/51_d4_semantic_sibling_target_backfill.md"))
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    rows, columns = read_csv(args.input)
    if not rows:
        write_csv(args.backfill_output, [], BACKFILL_COLUMNS)
        write_csv(args.summary_output, [], SUMMARY_COLUMNS)
        build_doc(args.doc_output, [], 0, args.apply)
        print("No semantic model source candidates found.")
        return 0

    siblings_by_key: dict[tuple[str, str, str, str, str], list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        if row.get("source_server") and row.get("database_name") and row.get("object_name"):
            siblings_by_key[candidate_key(row)].append(row)

    changed_rows = 0
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
                        "source_server": output.get("source_server", ""),
                        "database_name": output.get("database_name", ""),
                        "semantic_model_qualified_name": "",
                        "workspace_name": "",
                        "workspace_environment": "",
                    },
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

        sibling_rows = siblings_by_key.get(candidate_key(row), [])
        unique_targets = {target_key(sibling) for sibling in sibling_rows}
        if len(unique_targets) != 1:
            output_rows.append(output)
            continue

        sibling = sibling_rows[0]
        addition = (
            f"Source endpoint backfilled by {MARKER} from sibling semantic model "
            f"'{sibling.get('semantic_model_qualified_name','')}' with the same semantic model name, "
            "semantic table, schema, object name, and raw object type."
        )
        output["source_server"] = sibling.get("source_server", "")
        output["database_name"] = sibling.get("database_name", "")
        output["evidence"] = append_evidence(evidence, addition)
        changed_rows += 1
        backfill_rows.append(make_backfill_row(output, sibling, "applied", addition))
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
    for workspace, count in Counter(row.get("workspace_name", "") for row in backfill_rows if row.get("workspace_name")).most_common():
        summary_rows.append({"scope": "workspace", "value": workspace, "count": str(count), "notes": "Backfilled rows by workspace."})

    write_csv(args.backfill_output, backfill_rows, BACKFILL_COLUMNS)
    write_csv(args.summary_output, summary_rows, SUMMARY_COLUMNS)
    build_doc(args.doc_output, backfill_rows, changed_rows, args.apply)

    print(f"Semantic sibling source target backfill rows changed: {changed_rows}")
    print(f"Backfill rows emitted or retained: {len(backfill_rows)}")
    print(f"Applied: {'yes' if args.apply else 'no'}")
    print(f"Output: {args.backfill_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
