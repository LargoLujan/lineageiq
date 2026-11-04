#!/usr/bin/env python3
"""Build workspace-scoped Fabric catalog evidence for D4 object types.

This is narrower than a global object-name lookup. It only emits local
evidence when a D4 row has no metadata target, but its affected workspaces
contain Fabric SQL endpoint catalog rows for the same object and all scoped
matches agree on one physical type.

The evidence confirms object type only; it does not infer the missing source
database/lakehouse target.
"""

from __future__ import annotations

import argparse
import csv
from collections import Counter, defaultdict
from datetime import datetime, timezone
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
    "d4_id",
    "source_id",
    "source_type",
    "source_server",
    "source_database",
    "schema_name",
    "object_name",
    "raw_object_type",
    "workspaces",
    "diagnosis",
    "promoted",
    "match_count",
    "match_types",
    "match_schemas",
    "matched_workspaces",
    "match_sample",
    "notes",
]

SUMMARY_COLUMNS = ["scope", "value", "count", "notes"]

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
    value = norm(value).replace(" ", "_").replace("-", "_")
    aliases = {
        "storedprocedure": "stored_procedure",
        "procedure": "stored_procedure",
        "proc": "stored_procedure",
        "sp": "stored_procedure",
        "tbl": "table",
    }
    return aliases.get(value, value)


def split_multi(value: str | None) -> list[str]:
    return [part.strip() for part in (value or "").split(";") if part.strip()]


def compact(values: set[str], limit: int = 12) -> str:
    ordered = sorted(value for value in values if value)
    suffix = "" if len(ordered) <= limit else f"; +{len(ordered) - limit} more"
    return "; ".join(ordered[:limit]) + suffix


def match_key(row: dict[str, str]) -> tuple[str, str, str, str, str]:
    return (
        clean(row.get("workspace_name")),
        clean(row.get("source_database")),
        clean(row.get("schema_name")),
        clean(row.get("object_name")),
        normalize_object_type(row.get("object_type")),
    )


def evidence_key(row: dict[str, str]) -> tuple[str, ...]:
    return (
        norm(row.get("source_type")),
        norm(row.get("source_server")),
        norm(row.get("source_database")),
        norm(row.get("schema_name")),
        norm(row.get("object_name")),
        normalize_object_type(row.get("object_type")),
    )


def match_sample(matches: list[dict[str, str]], limit: int = 5) -> str:
    values: list[str] = []
    for row in matches[:limit]:
        values.append(
            f"{row.get('workspace_name','')}/{row.get('source_database','')}/"
            f"{row.get('schema_name','')}.{row.get('object_name','')}:"
            f"{normalize_object_type(row.get('object_type'))}"
        )
    return "; ".join(values)


def diagnosis_row(
    candidate: dict[str, str],
    diagnosis: str,
    promoted: bool,
    matches: list[dict[str, str]],
    notes: str,
) -> dict[str, str]:
    match_types = {normalize_object_type(row.get("object_type")) for row in matches}
    schemas = {clean(row.get("schema_name")) for row in matches}
    matched_workspaces = {clean(row.get("workspace_name")) for row in matches}
    return {
        "d4_id": candidate.get("d4_id", ""),
        "source_id": candidate.get("source_id", ""),
        "source_type": candidate.get("source_type", ""),
        "source_server": candidate.get("source_server", ""),
        "source_database": candidate.get("source_database", ""),
        "schema_name": candidate.get("schema_name", ""),
        "object_name": candidate.get("object_name", ""),
        "raw_object_type": candidate.get("raw_object_type", ""),
        "workspaces": candidate.get("workspaces", ""),
        "diagnosis": diagnosis,
        "promoted": "true" if promoted else "false",
        "match_count": str(len(matches)),
        "match_types": compact(match_types),
        "match_schemas": compact(schemas),
        "matched_workspaces": compact(matched_workspaces),
        "match_sample": match_sample(matches),
        "notes": notes,
    }


def make_evidence_row(candidate: dict[str, str], matches: list[dict[str, str]], reviewed_at: str) -> dict[str, str]:
    first = matches[0]
    object_type = normalize_object_type(first.get("object_type"))
    schemas = {clean(row.get("schema_name")) for row in matches if clean(row.get("schema_name"))}
    databases = {clean(row.get("source_database")) for row in matches if clean(row.get("source_database"))}
    workspaces = {clean(row.get("workspace_name")) for row in matches if clean(row.get("workspace_name"))}
    servers = {clean(row.get("source_server")) for row in matches if clean(row.get("source_server"))}
    type_descs = {clean(row.get("metadata_type_desc")) for row in matches if clean(row.get("metadata_type_desc"))}
    type_codes = {clean(row.get("metadata_type_code")) for row in matches if clean(row.get("metadata_type_code"))}

    target_schema = clean(candidate.get("schema_name"))
    metadata_schema = clean(first.get("schema_name", ""))
    if len(schemas) == 1:
        metadata_schema = next(iter(schemas))

    evidence = (
        "Workspace-scoped Fabric SQL endpoint catalog matches all agree that "
        f"{candidate.get('object_name','')} is {object_type}. "
        "This confirms only the physical object type; the missing source target remains unresolved."
    )
    notes = (
        f"Matched workspaces: {compact(workspaces)}. "
        f"Matched databases: {compact(databases)}. "
        "No external system was queried by this script."
    )
    if not target_schema:
        notes += f" Candidate schema was blank; matched schema sample: {metadata_schema}."

    return {
        "source_type": candidate.get("source_type", ""),
        "source_server": "",
        "source_database": "",
        "schema_name": target_schema,
        "object_name": candidate.get("object_name", ""),
        "object_type": object_type,
        "confidence": "confirmed",
        "evidence": evidence,
        "resolver": "fabric_workspace_catalog_type_backfill",
        "reviewed_at": reviewed_at,
        "metadata_server": compact(servers, limit=3),
        "metadata_database": compact(databases, limit=8),
        "metadata_schema_name": metadata_schema,
        "metadata_object_name": first.get("object_name", ""),
        "metadata_type_code": compact(type_codes, limit=3),
        "metadata_type_desc": compact(type_descs, limit=3),
        "raw_object_type": candidate.get("raw_object_type", ""),
        "candidate_count": candidate.get("candidate_count", ""),
        "impacted_item_count": candidate.get("affected_item_count", ""),
        "impacted_item_types": candidate.get("impact_item_type_split", "") or candidate.get("affected_item_types", ""),
        "impacted_items_sample": candidate.get("affected_items_sample", ""),
        "notes": notes,
    }


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


def build_doc(path: str | Path, evidence_rows: list[dict[str, str]], diagnosis_rows: list[dict[str, str]], merged: tuple[int, int, int] | None) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    promoted = [row for row in diagnosis_rows if row.get("promoted") == "true"]
    diagnosis_counts = Counter(row.get("diagnosis", "") for row in diagnosis_rows)
    lines = [
        "# D4 Workspace Catalog Type Backfill",
        "",
        f"Generated: {datetime.now(timezone.utc).isoformat(timespec='seconds')}",
        "",
        "## Purpose",
        "",
        "Confirm exact object type for D4 rows where the source target is missing, using only Fabric SQL endpoint catalog rows inside the affected workspaces.",
        "",
        "## Result",
        "",
        f"- Current open D4 rows evaluated: {len(diagnosis_rows)}",
        f"- Workspace-catalog evidence rows emitted or retained: {len(evidence_rows)}",
        f"- New workspace-scoped matches in the current open D4 queue: {len(promoted)}",
    ]
    if merged is not None:
        before, added, after = merged
        lines.extend(
            [
                f"- Metadata evidence rows before merge: {before}",
                f"- Metadata evidence rows added: {added}",
                f"- Metadata evidence rows after merge: {after}",
            ]
        )
    lines.extend(["", "## Diagnosis", ""])
    for diagnosis, count in diagnosis_counts.most_common():
        lines.append(f"- {diagnosis or 'blank'}: {count}")
    lines.extend(
        [
            "",
            "## Safety",
            "",
            "- Local artifacts only.",
            "- No Fabric, SQL, OneLake, SharePoint, repository, schedule, or pipeline change was made.",
            "- This confirms object type only; missing source targets remain separate D4/E2 gaps.",
            "",
            "## Outputs",
            "",
            "- `analysis/d4_workspace_catalog_type_evidence.csv`",
            "- `analysis/d4_workspace_catalog_type_diagnosis.csv`",
            "- `analysis/d4_workspace_catalog_type_summary.csv`",
            "- `docs/49_d4_workspace_catalog_type_backfill.md`",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--d4-control", default=str(REPO_ROOT / "analysis/d4_closure_control_queue.csv"))
    parser.add_argument("--fabric-catalog", default=str(REPO_ROOT / "analysis/sql_endpoint_object_catalog.csv"))
    parser.add_argument("--metadata-evidence", default=str(REPO_ROOT / "analysis/source_object_type_metadata_evidence.csv"))
    parser.add_argument("--evidence-output", default=str(REPO_ROOT / "analysis/d4_workspace_catalog_type_evidence.csv"))
    parser.add_argument("--diagnosis-output", default=str(REPO_ROOT / "analysis/d4_workspace_catalog_type_diagnosis.csv"))
    parser.add_argument("--summary-output", default=str(REPO_ROOT / "analysis/d4_workspace_catalog_type_summary.csv"))
    parser.add_argument("--doc-output", default=str(REPO_ROOT / "docs/49_d4_workspace_catalog_type_backfill.md"))
    parser.add_argument("--merge-metadata", action="store_true")
    args = parser.parse_args()

    d4_rows = read_csv(args.d4_control)
    catalog_rows = [
        row
        for row in read_csv(args.fabric_catalog)
        if row.get("catalog_status") in ("", "confirmed")
        and normalize_object_type(row.get("object_type")) in ALLOWED_TYPES
    ]

    by_ws_schema_object: dict[tuple[str, str, str], list[dict[str, str]]] = defaultdict(list)
    by_ws_object: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
    for row in catalog_rows:
        workspace = norm(row.get("workspace_name"))
        schema = norm(row.get("schema_name"))
        object_name = norm(row.get("object_name"))
        if not workspace or not object_name:
            continue
        by_ws_schema_object[(workspace, schema, object_name)].append(row)
        by_ws_object[(workspace, object_name)].append(row)

    reviewed_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
    evidence_rows: list[dict[str, str]] = []
    diagnosis_rows: list[dict[str, str]] = []

    for row in d4_rows:
        source_type = norm(row.get("source_type"))
        source_server = norm(row.get("source_server"))
        source_database = norm(row.get("source_database"))
        raw_type = norm(row.get("raw_object_type"))
        workspaces = split_multi(row.get("workspaces"))
        schema = norm(row.get("schema_name"))
        object_name = norm(row.get("object_name"))

        if source_type not in {"fabric", "fabricorsql", "lakehouse", "warehouse"}:
            continue
        if source_server or source_database:
            continue
        if raw_type != "table_or_view":
            continue
        if not workspaces or not object_name:
            diagnosis_rows.append(diagnosis_row(row, "missing_workspace_or_object_name", False, [], "Cannot scope catalog lookup."))
            continue

        matches: list[dict[str, str]] = []
        for workspace in workspaces:
            workspace_key = norm(workspace)
            if schema:
                matches.extend(by_ws_schema_object.get((workspace_key, schema, object_name), []))
            else:
                matches.extend(by_ws_object.get((workspace_key, object_name), []))

        unique_matches: list[dict[str, str]] = []
        seen: set[tuple[str, str, str, str, str]] = set()
        for match in matches:
            key = match_key(match)
            if key in seen:
                continue
            seen.add(key)
            unique_matches.append(match)

        if not unique_matches:
            diagnosis_rows.append(diagnosis_row(row, "no_workspace_catalog_match", False, [], "No Fabric catalog row matched within affected workspaces."))
            continue

        match_types = {normalize_object_type(match.get("object_type")) for match in unique_matches}
        match_schemas = {norm(match.get("schema_name")) for match in unique_matches}
        if len(match_types) != 1:
            diagnosis_rows.append(diagnosis_row(row, "blocked_conflicting_workspace_catalog_types", False, unique_matches, "Workspace-scoped matches disagree on object type."))
            continue
        if not schema and len(match_schemas) != 1:
            diagnosis_rows.append(diagnosis_row(row, "blocked_multiple_workspace_catalog_schemas", False, unique_matches, "Candidate schema is blank and matches span multiple schemas."))
            continue

        evidence_rows.append(make_evidence_row(row, unique_matches, reviewed_at))
        diagnosis_rows.append(diagnosis_row(row, "workspace_catalog_unique_type_match", True, unique_matches, "Exact type promoted from workspace-scoped Fabric catalog evidence."))

    existing_workspace_rows = [
        row
        for row in read_csv(args.metadata_evidence)
        if row.get("resolver") == "fabric_workspace_catalog_type_backfill"
    ]
    existing_keys = {evidence_key(row) for row in evidence_rows}
    for row in existing_workspace_rows:
        key = evidence_key(row)
        if key in existing_keys:
            continue
        existing_keys.add(key)
        evidence_rows.append(row)

    write_csv(args.evidence_output, evidence_rows, EVIDENCE_COLUMNS)
    write_csv(args.diagnosis_output, diagnosis_rows, DIAGNOSIS_COLUMNS)

    summary_rows: list[dict[str, str]] = []
    for diagnosis, count in Counter(row.get("diagnosis", "") for row in diagnosis_rows).most_common():
        summary_rows.append({"scope": "diagnosis", "value": diagnosis, "count": str(count), "notes": "Workspace-scoped D4 type backfill diagnosis."})
    for object_type, count in Counter(row.get("object_type", "") for row in evidence_rows).most_common():
        summary_rows.append({"scope": "evidence_object_type", "value": object_type, "count": str(count), "notes": "Object types emitted as local evidence."})

    merged: tuple[int, int, int] | None = None
    if args.merge_metadata:
        merged = merge_evidence(args.metadata_evidence, evidence_rows)
        before, added, after = merged
        summary_rows.extend(
            [
                {"scope": "metadata_merge", "value": "before", "count": str(before), "notes": args.metadata_evidence},
                {"scope": "metadata_merge", "value": "added", "count": str(added), "notes": args.metadata_evidence},
                {"scope": "metadata_merge", "value": "after", "count": str(after), "notes": args.metadata_evidence},
            ]
        )

    write_csv(args.summary_output, summary_rows, SUMMARY_COLUMNS)
    build_doc(args.doc_output, evidence_rows, diagnosis_rows, merged)

    print(f"D4 workspace catalog type evidence rows: {len(evidence_rows)}")
    print(f"D4 workspace catalog diagnoses: {len(diagnosis_rows)}")
    if merged is not None:
        before, added, after = merged
        print(f"Metadata evidence merge: before={before} added={added} after={after}")
    print(f"Evidence: {args.evidence_output}")
    print(f"Diagnosis: {args.diagnosis_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
