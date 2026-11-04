#!/usr/bin/env python3
"""Backfill item object source targets from local notebook flow evidence.

This script updates only local CSV evidence. It does not query external systems.
Rows are backfilled only when the local notebook super-lineage/flow catalog
points to one unique source endpoint for the same item, object, and usage side.
"""

from __future__ import annotations

import argparse
import csv
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent  # Anchor default paths to the repo, not $PWD


MARKER = "item_flow_source_target_backfill"

TARGET_COLUMNS = [
    "target_file",
    "row_number",
    "workspace_name",
    "item_type",
    "item_name",
    "item_qualified_name",
    "usage_type",
    "source_type_before",
    "source_server_before",
    "source_database_before",
    "schema_name_before",
    "object_name_before",
    "object_type",
    "backfilled_source_type",
    "backfilled_source_server",
    "backfilled_source_database",
    "backfilled_schema_name",
    "match_source",
    "match_side",
    "match_count",
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


def append_evidence(existing: str, addition: str) -> str:
    existing = clean(existing)
    if MARKER in existing:
        return existing
    if not existing:
        return addition
    return f"{existing} {addition}"


def normalize_object_type(value: str | None) -> str:
    raw = norm(value).replace("-", "_").replace(" ", "_")
    aliases = {
        "storedprocedure": "stored_procedure",
        "procedure": "stored_procedure",
        "proc": "stored_procedure",
        "sp": "stored_procedure",
    }
    return aliases.get(raw, raw)


def usage_side(value: str | None) -> str:
    usage = norm(value)
    if usage in {"read", "reads", "source", "input", "reads_from"}:
        return "source_object"
    if usage in {"write", "writes", "sink", "output", "writes_to"}:
        return "target_object"
    return ""


def direction_from_usage(value: str | None) -> str:
    side = usage_side(value)
    if side == "source_object":
        return "read"
    if side == "target_object":
        return "write"
    return ""


def split_ref(value: str) -> list[str]:
    return [part.strip().strip("[]`\"'") for part in value.split(".") if part.strip().strip("[]`\"'")]


def looks_like_database(value: str, known_databases: set[str]) -> bool:
    key = norm(value)
    if not key:
        return False
    if key in known_databases:
        return True
    # Last entry is an example of a tenant-specific database name prefix
    # -- add your own here.
    return key.startswith(("lh_", "datamart_", "dp_", "dwh_", "warehouse_", "contosohr"))


def parse_object_ref(value: str, known_databases: set[str]) -> dict[str, str] | None:
    raw = clean(value)
    if not raw:
        return None
    if raw.startswith(("Notebook/", "ExternalAPI", "File/")):
        return None
    if any(token in raw for token in ("{", "}", "*")):
        return None

    path_parts = [part.strip().strip("[]`\"'") for part in raw.split("/") if part.strip().strip("[]`\"'")]
    if len(path_parts) >= 2 and "." not in raw:
        obj = path_parts[-1]
        schema = path_parts[-2] if len(path_parts) >= 2 else ""
        database = path_parts[-3] if len(path_parts) >= 3 and looks_like_database(path_parts[-3], known_databases) else ""
        return {"source_database": database, "schema_name": schema, "object_name": obj}

    parts = split_ref(raw)
    if not parts:
        return None

    if len(parts) >= 4 and looks_like_database(parts[-3], known_databases):
        return {"source_database": parts[-3], "schema_name": parts[-2], "object_name": parts[-1]}
    if len(parts) >= 3:
        return {"source_database": parts[-3], "schema_name": parts[-2], "object_name": parts[-1]}
    if len(parts) == 2:
        if looks_like_database(parts[0], known_databases):
            return {"source_database": parts[0], "schema_name": "", "object_name": parts[1]}
        return {"source_database": "", "schema_name": parts[0], "object_name": parts[1]}
    return {"source_database": "", "schema_name": "", "object_name": parts[0]}


def canonical_database(value: str, known_databases: set[str]) -> str:
    database = clean(value)
    parts = split_ref(database)
    if len(parts) >= 2 and looks_like_database(parts[-1], known_databases):
        return parts[-1]
    return database


def build_catalog_server_index(paths: list[str]) -> tuple[set[str], dict[tuple[str, str, str], set[str]], dict[str, set[str]]]:
    known_databases: set[str] = set()
    servers_by_object: dict[tuple[str, str, str], set[str]] = defaultdict(set)
    servers_by_database: dict[str, set[str]] = defaultdict(set)

    for path in paths:
        rows, _ = read_csv(path)
        for row in rows:
            if path.endswith("sql_endpoint_object_catalog.csv"):
                database = clean(row.get("source_database"))
                server = clean(row.get("source_server"))
                schema = clean(row.get("schema_name"))
                obj = clean(row.get("object_name"))
                status = clean(row.get("catalog_status"))
                if status and status != "confirmed":
                    continue
            else:
                database = clean(row.get("database_name"))
                server = clean(row.get("source_server"))
                schema = clean(row.get("schema_name"))
                obj = clean(row.get("object_name"))

            if not database:
                continue
            db_key = norm(database)
            known_databases.add(db_key)
            if server:
                servers_by_database[db_key].add(server)
            if server and obj:
                servers_by_object[(db_key, norm(schema), norm(obj))].add(server)

    return known_databases, servers_by_object, servers_by_database


def resolve_server(
    database: str,
    schema: str,
    object_name: str,
    explicit_server: str,
    servers_by_object: dict[tuple[str, str, str], set[str]],
    servers_by_database: dict[str, set[str]],
) -> tuple[str, str]:
    if explicit_server:
        return explicit_server, "explicit_ref_server"

    db_key = norm(database)
    schema_key = norm(schema)
    object_key = norm(object_name)

    candidates = servers_by_object.get((db_key, schema_key, object_key), set())
    if len(candidates) == 1:
        return next(iter(candidates)), "unique_catalog_object_server"

    candidates = servers_by_database.get(db_key, set())
    if len(candidates) == 1:
        return next(iter(candidates)), "unique_catalog_database_server"

    return "", "no_unique_catalog_server"


def candidate_item_keys(row: dict[str, str]) -> list[str]:
    keys = [norm(row.get("item_qualified_name"))]
    invoked = norm(row.get("invoked_item_qualified_name"))
    if invoked:
        keys.append(invoked)
    evidence = row.get("evidence", "")
    match = re.search(r"invokes '([^']+)'", evidence)
    if match:
        keys.append(norm(match.group(1)))
    return list(dict.fromkeys(key for key in keys if key))


def build_flow_hints(
    flow_rows: list[dict[str, str]],
    known_databases: set[str],
    servers_by_object: dict[tuple[str, str, str], set[str]],
    servers_by_database: dict[str, set[str]],
) -> dict[tuple[str, str, str, str], list[dict[str, str]]]:
    hints: dict[tuple[str, str, str, str], list[dict[str, str]]] = defaultdict(list)
    for row in flow_rows:
        item_key = norm(row.get("item_qualified_name"))
        if not item_key:
            continue
        for side in ("source_object", "target_object"):
            parsed = parse_object_ref(row.get(side, ""), known_databases)
            if not parsed:
                continue
            database = canonical_database(parsed.get("source_database", ""), known_databases)
            schema = clean(parsed.get("schema_name"))
            obj = clean(parsed.get("object_name"))
            if not database or not obj:
                continue
            server, server_resolution = resolve_server(
                database,
                schema,
                obj,
                "",
                servers_by_object,
                servers_by_database,
            )
            if not server:
                continue
            key = (item_key, side, norm(schema), norm(obj))
            hints[key].append(
                {
                    "source_type": "FabricOrSQL",
                    "source_server": server,
                    "source_database": database,
                    "schema_name": schema,
                    "object_name": obj,
                    "match_source": "notebook_lineage_flow_catalog",
                    "match_side": side,
                    "server_resolution": server_resolution,
                    "source_ref": row.get(side, ""),
                    "source_object": row.get("source_object", ""),
                    "target_object": row.get("target_object", ""),
                    "confidence": row.get("confidence", ""),
                    "evidence": row.get("evidence", ""),
                }
            )
    return hints


def build_direct_hints(
    object_rows: list[dict[str, str]],
    known_databases: set[str],
    servers_by_object: dict[tuple[str, str, str], set[str]],
    servers_by_database: dict[str, set[str]],
) -> dict[tuple[str, str, str, str], list[dict[str, str]]]:
    hints: dict[tuple[str, str, str, str], list[dict[str, str]]] = defaultdict(list)
    for row in object_rows:
        item_key = norm(row.get("item_qualified_name"))
        direction = norm(row.get("direction"))
        if direction not in {"read", "write"} or not item_key:
            continue
        database = canonical_database(row.get("source_database", ""), known_databases)
        schema = clean(row.get("schema_name"))
        obj = clean(row.get("object_name"))
        if not database or not obj:
            continue
        server, server_resolution = resolve_server(
            database,
            schema,
            obj,
            clean(row.get("source_server")),
            servers_by_object,
            servers_by_database,
        )
        if not server:
            continue
        side = "source_object" if direction == "read" else "target_object"
        key = (item_key, side, norm(schema), norm(obj))
        hints[key].append(
            {
                "source_type": row.get("source_type", "") or "FabricOrSQL",
                "source_server": server,
                "source_database": database,
                "schema_name": schema,
                "object_name": obj,
                "match_source": "notebook_super_lineage_objects",
                "match_side": side,
                "server_resolution": server_resolution,
                "source_ref": row.get("object_display_name", "") or obj,
                "confidence": row.get("confidence", ""),
                "evidence": row.get("evidence", ""),
            }
        )
    return hints


def merge_hints(
    flow_hints: dict[tuple[str, str, str, str], list[dict[str, str]]],
    direct_hints: dict[tuple[str, str, str, str], list[dict[str, str]]],
) -> dict[tuple[str, str, str, str], list[dict[str, str]]]:
    merged: dict[tuple[str, str, str, str], list[dict[str, str]]] = defaultdict(list)
    for source in (flow_hints, direct_hints):
        for key, rows in source.items():
            merged[key].extend(rows)
    return merged


def find_hints_for_row(row: dict[str, str], hints: dict[tuple[str, str, str, str], list[dict[str, str]]]) -> list[dict[str, str]]:
    side = usage_side(row.get("usage_type"))
    if not side:
        return []
    schema = norm(row.get("schema_name"))
    obj = norm(row.get("object_name"))
    if not obj:
        return []

    matches: list[dict[str, str]] = []
    for item_key in candidate_item_keys(row):
        exact_key = (item_key, side, schema, obj)
        matches.extend(hints.get(exact_key, []))
        if not schema:
            # Allow a parsed schema to fill a blank candidate schema.
            for (hint_item, hint_side, hint_schema, hint_obj), hint_rows in hints.items():
                if hint_item == item_key and hint_side == side and hint_obj == obj:
                    matches.extend(hint_rows)
    return matches


def hint_identity(row: dict[str, str]) -> tuple[str, str, str, str]:
    return (
        norm(row.get("source_server")),
        norm(row.get("source_database")),
        norm(row.get("schema_name")),
        norm(row.get("object_name")),
    )


def make_backfill_row(
    target_file: str,
    row_number: int,
    original: dict[str, str],
    hint: dict[str, str] | None,
    status: str,
    evidence: str,
    match_count: int,
) -> dict[str, str]:
    hint = hint or {}
    return {
        "target_file": target_file,
        "row_number": str(row_number),
        "workspace_name": original.get("workspace_name", ""),
        "item_type": original.get("item_type", ""),
        "item_name": original.get("item_name", ""),
        "item_qualified_name": original.get("item_qualified_name", ""),
        "usage_type": original.get("usage_type", ""),
        "source_type_before": original.get("source_type", ""),
        "source_server_before": original.get("source_server", ""),
        "source_database_before": original.get("source_database", ""),
        "schema_name_before": original.get("schema_name", ""),
        "object_name_before": original.get("object_name", ""),
        "object_type": original.get("object_type", ""),
        "backfilled_source_type": hint.get("source_type", ""),
        "backfilled_source_server": hint.get("source_server", ""),
        "backfilled_source_database": hint.get("source_database", ""),
        "backfilled_schema_name": hint.get("schema_name", ""),
        "match_source": hint.get("match_source", ""),
        "match_side": hint.get("match_side", ""),
        "match_count": str(match_count),
        "status": status,
        "evidence": evidence,
    }


def process_candidate_file(
    path: str,
    output_path: str,
    hints: dict[tuple[str, str, str, str], list[dict[str, str]]],
    apply: bool,
) -> tuple[int, list[dict[str, str]], Counter[str]]:
    rows, columns = read_csv(path)
    if not rows:
        return 0, [], Counter({"input_missing_or_empty": 1})

    changed = 0
    backfills: list[dict[str, str]] = []
    blockers: Counter[str] = Counter()
    output_rows: list[dict[str, str]] = []

    for row_number, row in enumerate(rows, start=2):
        output = dict(row)
        object_type = normalize_object_type(row.get("object_type"))
        evidence = clean(row.get("evidence"))
        already_backfilled = MARKER in evidence
        missing_target = not clean(row.get("source_server")) or not clean(row.get("source_database"))

        if already_backfilled:
            backfills.append(
                make_backfill_row(path, row_number, row, output, "retained_existing_backfill", evidence, 1)
            )
            output_rows.append(output)
            continue

        if not missing_target or object_type not in {"table_or_view", "native_query_object"}:
            output_rows.append(output)
            continue

        matches = find_hints_for_row(row, hints)
        if not matches:
            blockers["no_local_flow_hint"] += 1
            output_rows.append(output)
            continue

        unique = {hint_identity(match) for match in matches}
        if len(unique) != 1:
            blockers["multiple_local_flow_targets"] += 1
            output_rows.append(output)
            continue

        hint = matches[0]
        if not clean(hint.get("source_server")) or not clean(hint.get("source_database")):
            blockers["hint_without_full_target"] += 1
            output_rows.append(output)
            continue

        addition = (
            f"Source endpoint backfilled by {MARKER} from {hint.get('match_source','')} "
            f"because the same item/usage side references {hint.get('source_ref','')} and local catalog "
            f"resolves it to {hint.get('source_server','')}/{hint.get('source_database','')}."
        )
        output["source_type"] = hint.get("source_type", "") or output.get("source_type", "")
        output["source_server"] = hint.get("source_server", "")
        output["source_database"] = hint.get("source_database", "")
        if not clean(output.get("schema_name")) and clean(hint.get("schema_name")):
            output["schema_name"] = hint.get("schema_name", "")
        output["evidence"] = append_evidence(evidence, addition)
        changed += 1
        backfills.append(make_backfill_row(path, row_number, row, hint, "applied", addition, len(matches)))
        output_rows.append(output)

    if apply:
        write_csv(output_path, output_rows, columns)
    return changed, backfills, blockers


def build_doc(path: str | Path, backfill_rows: list[dict[str, str]], changed: int, applied: bool) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    status_counts = Counter(row.get("status", "") for row in backfill_rows)
    target_counts = Counter(
        (row.get("backfilled_source_server", ""), row.get("backfilled_source_database", ""))
        for row in backfill_rows
        if row.get("backfilled_source_server") or row.get("backfilled_source_database")
    )
    source_counts = Counter(row.get("match_source", "") for row in backfill_rows if row.get("match_source"))

    lines = [
        "# D4 Item Flow Source Target Backfill",
        "",
        f"Generated: {datetime.now(timezone.utc).isoformat(timespec='seconds')}",
        "",
        "## Purpose",
        "",
        "Backfill missing source endpoints in Notebook/CopyJob/DataPipeline object candidate rows from local notebook flow evidence.",
        "",
        "## Result",
        "",
        f"- Candidate rows changed in this run: {changed}",
        f"- Backfill rows emitted or retained: {len(backfill_rows)}",
        f"- Applied to candidate CSVs: {'yes' if applied else 'no'}",
        "",
        "## Status Counts",
        "",
    ]
    for status, count in status_counts.most_common():
        lines.append(f"- {status or 'blank'}: {count}")
    lines.extend(["", "## Match Sources", ""])
    for source, count in source_counts.most_common():
        lines.append(f"- {source}: {count}")
    lines.extend(["", "## Top Targets", ""])
    for (server, database), count in target_counts.most_common(20):
        lines.append(f"- {server}/{database}: {count}")
    lines.extend(
        [
            "",
            "## Safety",
            "",
            "- Local CSV evidence only.",
            "- No external system was queried.",
            "- Backfill requires one unique local flow target for the same item, usage side, schema/object, and local catalog endpoint.",
            "- Placeholder targets and ambiguous host/database matches are not promoted.",
            "",
            "## Outputs",
            "",
            "- `analysis/d4_item_flow_source_target_backfill.csv`",
            "- `analysis/d4_item_flow_source_target_backfill_summary.csv`",
            "- `docs/54_d4_item_flow_source_target_backfill.md`",
        ]
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--item-input", default=str(REPO_ROOT / "analysis/item_object_lineage_candidates.csv"))
    parser.add_argument("--item-output", default=str(REPO_ROOT / "analysis/item_object_lineage_candidates.csv"))
    parser.add_argument("--pipeline-input", default=str(REPO_ROOT / "analysis/pipeline_object_lineage_candidates.csv"))
    parser.add_argument("--pipeline-output", default=str(REPO_ROOT / "analysis/pipeline_object_lineage_candidates.csv"))
    parser.add_argument("--flow-input", default=str(REPO_ROOT / "analysis/notebook_lineage_flow_catalog.csv"))
    parser.add_argument("--object-input", default=str(REPO_ROOT / "analysis/notebook_super_lineage_objects.csv"))
    parser.add_argument("--fabric-catalog-input", default=str(REPO_ROOT / "analysis/sql_endpoint_object_catalog.csv"))
    parser.add_argument("--sql-catalog-input", default=str(REPO_ROOT / "analysis/sql_server_deep_catalog_objects.csv"))
    parser.add_argument("--more-sql-catalog-input", default=str(REPO_ROOT / "analysis/sql_server_deep_catalog_more_sql_objects.csv"))
    parser.add_argument("--backfill-output", default=str(REPO_ROOT / "analysis/d4_item_flow_source_target_backfill.csv"))
    parser.add_argument("--summary-output", default=str(REPO_ROOT / "analysis/d4_item_flow_source_target_backfill_summary.csv"))
    parser.add_argument("--doc-output", default=str(REPO_ROOT / "docs/54_d4_item_flow_source_target_backfill.md"))
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()

    catalog_paths = [args.fabric_catalog_input, args.sql_catalog_input, args.more_sql_catalog_input]
    known_databases, servers_by_object, servers_by_database = build_catalog_server_index(catalog_paths)
    flow_rows, _ = read_csv(args.flow_input)
    object_rows, _ = read_csv(args.object_input)
    flow_hints = build_flow_hints(flow_rows, known_databases, servers_by_object, servers_by_database)
    direct_hints = build_direct_hints(object_rows, known_databases, servers_by_object, servers_by_database)
    hints = merge_hints(flow_hints, direct_hints)

    item_changed, item_backfills, item_blockers = process_candidate_file(
        args.item_input,
        args.item_output,
        hints,
        args.apply,
    )
    pipeline_changed, pipeline_backfills, pipeline_blockers = process_candidate_file(
        args.pipeline_input,
        args.pipeline_output,
        hints,
        args.apply,
    )

    backfill_rows = item_backfills + pipeline_backfills
    changed = item_changed + pipeline_changed

    summary_rows: list[dict[str, str]] = [
        {"scope": "total", "value": "changed_rows", "count": str(changed), "notes": "Rows backfilled in this run."},
        {"scope": "total", "value": "backfill_rows_emitted_or_retained", "count": str(len(backfill_rows)), "notes": args.backfill_output},
        {"scope": "input", "value": "flow_rows", "count": str(len(flow_rows)), "notes": args.flow_input},
        {"scope": "input", "value": "notebook_object_rows", "count": str(len(object_rows)), "notes": args.object_input},
        {"scope": "hint", "value": "flow_hint_keys", "count": str(len(flow_hints)), "notes": "Item/object/side keys from flow catalog."},
        {"scope": "hint", "value": "direct_hint_keys", "count": str(len(direct_hints)), "notes": "Item/object/side keys from notebook object rows."},
        {"scope": "changed_file", "value": args.item_input, "count": str(item_changed), "notes": "Item candidate rows changed."},
        {"scope": "changed_file", "value": args.pipeline_input, "count": str(pipeline_changed), "notes": "Pipeline candidate rows changed."},
    ]
    for status, count in Counter(row.get("status", "") for row in backfill_rows).most_common():
        summary_rows.append({"scope": "status", "value": status, "count": str(count), "notes": "Backfill row status."})
    for reason, count in item_blockers.most_common():
        summary_rows.append({"scope": "item_blocker", "value": reason, "count": str(count), "notes": args.item_input})
    for reason, count in pipeline_blockers.most_common():
        summary_rows.append({"scope": "pipeline_blocker", "value": reason, "count": str(count), "notes": args.pipeline_input})
    for source, count in Counter(row.get("match_source", "") for row in backfill_rows if row.get("match_source")).most_common():
        summary_rows.append({"scope": "match_source", "value": source, "count": str(count), "notes": "Local evidence source."})
    for target, count in Counter(
        f"{row.get('backfilled_source_server','')}/{row.get('backfilled_source_database','')}"
        for row in backfill_rows
        if row.get("backfilled_source_server") or row.get("backfilled_source_database")
    ).most_common():
        summary_rows.append({"scope": "target", "value": target, "count": str(count), "notes": "Backfilled rows by target."})

    write_csv(args.backfill_output, backfill_rows, TARGET_COLUMNS)
    write_csv(args.summary_output, summary_rows, SUMMARY_COLUMNS)
    build_doc(args.doc_output, backfill_rows, changed, args.apply)

    print(f"Item flow source target backfill rows changed: {changed}")
    print(f"Backfill rows emitted or retained: {len(backfill_rows)}")
    print(f"Applied: {'yes' if args.apply else 'no'}")
    print(f"Output: {args.backfill_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
