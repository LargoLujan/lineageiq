#!/usr/bin/env python3
"""Build notebook-by-notebook lineage audit batches.

This does not execute notebooks. It reconciles the notebook super-lineage
extract with local downloaded definitions so each notebook has an auditable
source/destination/execute summary and a recommended review batch.
"""

from __future__ import annotations

import csv
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def write_csv(path: Path, rows: list[dict[str, str]], fields: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def split_list(value: str) -> list[str]:
    if not value:
        return []
    return [part.strip() for part in value.split(";") if part.strip()]


def notebook_definition_paths(manifest_rows: list[dict[str, str]], e1_rows: list[dict[str, str]]) -> dict[str, list[str]]:
    paths_by_item: dict[str, list[str]] = defaultdict(list)
    for row in manifest_rows:
        if row.get("status") != "downloaded":
            continue
        item = row.get("item_qualified_name", "")
        for path in split_list(row.get("part_paths", "")):
            if path.endswith((".ipynb", ".py", ".scala", ".sql")) or Path(path).name.startswith("notebook-content"):
                paths_by_item[item].append(path)
    for row in e1_rows:
        item = row.get("item_qualified_name", "")
        for path in split_list(row.get("local_definition_paths", "")):
            if path not in paths_by_item[item]:
                paths_by_item[item].append(path)
    return paths_by_item


def read_definition_text(paths: list[str]) -> tuple[str, int, int, str, str]:
    parts: list[str] = []
    total_bytes = 0
    line_count = 0
    existing_paths: list[str] = []
    sha = hashlib.sha1()
    for path_text in paths:
        path = Path(path_text)
        if not path.exists() or path.is_dir():
            continue
        data = path.read_bytes()
        total_bytes += len(data)
        sha.update(path_text.encode("utf-8", errors="ignore"))
        sha.update(data)
        text = decode_definition_text(path, data)
        line_count += text.count("\n") + (1 if text else 0)
        parts.append(text)
        existing_paths.append(path_text)
    digest = sha.hexdigest()[:16] if existing_paths else ""
    return "\n\n".join(parts), total_bytes, line_count, digest, "; ".join(existing_paths)


def decode_definition_text(path: Path, data: bytes) -> str:
    text = data.decode("utf-8-sig", errors="ignore")
    if path.suffix.lower() != ".ipynb":
        return text
    try:
        payload = json.loads(text)
    except Exception:
        return text
    parts: list[str] = []
    for cell in payload.get("cells", []):
        source = cell.get("source", "")
        cell_text = "".join(source) if isinstance(source, list) else str(source)
        if cell.get("cell_type") == "code":
            parts.append(cell_text)
        elif cell.get("cell_type") == "markdown":
            parts.append("\n".join("# " + line for line in cell_text.splitlines()))
    return "\n\n".join(parts)


def language_hints(text: str, paths: list[str]) -> str:
    hints: set[str] = set()
    for path in paths:
        suffix = Path(path).suffix.lower().lstrip(".")
        if suffix:
            hints.add(suffix)
    if re.search(r"(?im)^\s*# MAGIC\s+%%sql|^\s*%%sql", text):
        hints.add("sparksql_magic")
    if re.search(r"\bspark\.", text):
        hints.add("pyspark")
    if re.search(r"\bSELECT\b|\bCREATE\s+TABLE\b|\bINSERT\s+INTO\b", text, re.I):
        hints.add("sql")
    return ";".join(sorted(hints))


def text_flags(text: str) -> dict[str, str]:
    checks = {
        "has_magic_sql": r"(?im)^\s*# MAGIC\s+%%sql|^\s*%%sql",
        "has_notebook_run": r"(?im)^\s*%run\s+|\b(?:mssparkutils|notebookutils)(?:\.mssparkutils)?\.notebook\.run\b",
        "has_spark_read": r"\bspark\.read\b|\bspark\.table\b",
        "has_spark_write": r"\.write\b|saveAsTable|insertInto|writeTo\(",
        "has_jdbc": r"\bjdbc\b|dbtable|sqlserver|mssql|pyodbc",
        "has_requests": r"\brequests\.|https?://|\.get\(|\.post\(",
        "has_secret": r"\bCredentials\b|secret|getSecret|KeyVault|password|pwd",
    }
    return {key: "yes" if re.search(pattern, text, re.I) else "no" for key, pattern in checks.items()}


def concise_join(values: list[str], limit: int = 12) -> str:
    unique = []
    seen = set()
    for value in values:
        if value and value not in seen:
            seen.add(value)
            unique.append(value)
    if len(unique) <= limit:
        return "; ".join(unique)
    return "; ".join(unique[:limit]) + f"; +{len(unique) - limit} more"


def confidence_rollup(rows: list[dict[str, str]]) -> Counter:
    return Counter(row.get("confidence", "") for row in rows if row.get("confidence", ""))


def classify_notebook(
    item_name: str,
    definition_status: str,
    object_rows: list[dict[str, str]],
    flow_rows: list[dict[str, str]],
    gap_types: list[str],
    flags: dict[str, str],
    text: str,
) -> tuple[str, str, str]:
    read_count = sum(1 for row in object_rows if row.get("direction") == "read")
    write_count = sum(1 for row in object_rows if row.get("direction") == "write")
    execute_count = sum(1 for row in object_rows if row.get("direction") == "execute")
    unresolved_count = sum(1 for row in object_rows if row.get("unresolved_variables"))
    likely_count = sum(1 for row in object_rows if row.get("confidence") == "likely")
    operations = {row.get("operation", "") for row in object_rows if row.get("operation")}
    name = item_name.casefold()

    if definition_status != "downloaded":
        return "definition_missing", "B01", "Definition missing or export failed."
    if gap_types and not object_rows:
        if "common_utils" in name or "credentials" in name or "template" in name:
            return "helper_or_template_no_objects", "B02", "Helper/template/config notebook; no data object parsed."
        if flags.get("has_requests") == "yes":
            return "external_api_or_control_no_objects", "B02", "No table object parsed, but API/control patterns exist."
        return "no_objects_after_static_parse", "B02", "Downloaded definition still has no parsed read/write/execute object."
    if execute_count and not read_count and not write_count:
        return "execute_only_orchestrator", "B03", "Notebook executes other notebooks but has no direct data object parsed."
    if flow_rows:
        return "source_to_target_flow_available", "B05", "Static code exposes at least one source-to-target flow; use row confidence for review."
    if unresolved_count or (object_rows and likely_count / max(1, len(object_rows)) >= 0.75):
        return "dynamic_lineage_review", "B04", "Many likely/unresolved references; dynamic code needs targeted review."
    if object_rows:
        is_central_registry = (
            "central_registry_audit_table" in operations
            and "schema shortcuts" in text.casefold()
            and "sin copia de datos" in text.casefold()
        )
        is_control_gate = "get_last_successful_process" in operations or "create_process_control_table" in operations
        is_purge_or_reload = "drop_table_path" in operations or re.search(
            r"\bdrop_table_if_exists\b|(?:notebookutils|mssparkutils)\.fs\.rm\b",
            text,
            re.I,
        )
        if is_central_registry:
            return (
                "registry_shortcut_management_no_flow_expected",
                "B08",
                "Fabric/OneLake registry and shortcut-management audit touchpoints; no direct business source-to-target data output expected.",
            )
        if is_control_gate and not execute_count:
            return (
                "control_gate_touchpoints_no_flow_expected",
                "B08",
                "Process-control gate/status touchpoints; no direct source-to-target data output expected.",
            )
        if write_count and not read_count and not execute_count and is_purge_or_reload:
            return (
                "purge_touchpoints_no_flow_expected",
                "B08",
                "Drop/purge/full-reload touchpoints; no direct source-to-target data output expected.",
            )
        if read_count and not write_count:
            return (
                "source_or_run_touchpoints_no_flow_expected",
                "B08",
                "Read-only validation/display/check touchpoints, optionally with helper notebook runs; no write target found in active code.",
            )
    if read_count or write_count:
        return "touchpoints_without_direct_flow", "B06", "Objects were parsed, but source-to-target pairing is not explicit."
    if flags.get("has_notebook_run") == "yes":
        return "run_dependency_review", "B03", "Run dependency exists but no object-level lineage parsed."
    if len(text.strip()) < 120:
        return "empty_or_placeholder", "B02", "Definition is empty or placeholder-like."
    return "manual_review", "B07", "Fallback manual review bucket."


def main() -> None:
    items = [
        row
        for row in read_csv(ROOT / "index/items.csv")
        if row.get("item_type") == "Notebook" and row.get("status") == "discovered"
    ]
    manifest_rows = read_csv(ROOT / "analysis/notebook_definition_download_manifest.csv")
    e1_rows = read_csv(ROOT / "analysis/e1_notebook_code_review_queue.csv")
    object_rows = read_csv(ROOT / "analysis/notebook_super_lineage_objects.csv")
    flow_rows = read_csv(ROOT / "analysis/notebook_super_lineage_flows.csv")
    gap_rows = read_csv(ROOT / "analysis/notebook_super_lineage_gaps.csv")

    paths_by_item = notebook_definition_paths(manifest_rows, e1_rows)
    manifest_by_item = {row.get("item_qualified_name", ""): row for row in manifest_rows}
    objects_by_item: dict[str, list[dict[str, str]]] = defaultdict(list)
    flows_by_item: dict[str, list[dict[str, str]]] = defaultdict(list)
    gaps_by_item: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in object_rows:
        objects_by_item[row.get("item_qualified_name", "")].append(row)
    for row in flow_rows:
        flows_by_item[row.get("item_qualified_name", "")].append(row)
    for row in gap_rows:
        gaps_by_item[row.get("item_qualified_name", "")].append(row)

    summary_rows: list[dict[str, str]] = []
    touchpoint_rows: list[dict[str, str]] = []
    flow_catalog_rows: list[dict[str, str]] = []
    batch_counter: Counter = Counter()
    role_counter: Counter = Counter()

    for item in sorted(items, key=lambda r: (r.get("workspace_name", ""), r.get("item_name", ""))):
        qualified = item.get("qualified_name", "")
        paths = paths_by_item.get(qualified, [])
        manifest = manifest_by_item.get(qualified, {})
        definition_status = "downloaded" if paths else (manifest.get("status") or "missing")
        definition_error = manifest.get("error", "")
        text, total_bytes, line_count, digest, existing_paths = read_definition_text(paths)
        flags = text_flags(text)
        objs = objects_by_item.get(qualified, [])
        flows = flows_by_item.get(qualified, [])
        gaps = gaps_by_item.get(qualified, [])
        gap_types = sorted({row.get("gap_type", "") for row in gaps if row.get("gap_type")})
        role, batch_id, review_reason = classify_notebook(
            item.get("item_name", ""),
            definition_status,
            objs,
            flows,
            gap_types,
            flags,
            text,
        )
        batch_counter[batch_id] += 1
        role_counter[role] += 1

        direction_counts = Counter(row.get("direction", "") for row in objs)
        conf_counts = confidence_rollup(objs)
        unresolved_count = sum(1 for row in objs if row.get("unresolved_variables"))
        read_objects = [row.get("object_display_name", "") for row in objs if row.get("direction") == "read"]
        write_objects = [row.get("object_display_name", "") for row in objs if row.get("direction") == "write"]
        execute_objects = [row.get("object_display_name", "") for row in objs if row.get("direction") == "execute"]

        summary_rows.append(
            {
                "item_qualified_name": qualified,
                "workspace_name": item.get("workspace_name", ""),
                "workspace_environment": item.get("workspace_environment", ""),
                "notebook_name": item.get("item_name", ""),
                "definition_status": definition_status,
                "definition_error": definition_error,
                "definition_paths": existing_paths,
                "definition_file_count": str(len([p for p in paths if Path(p).exists()])),
                "definition_total_bytes": str(total_bytes),
                "definition_line_count": str(line_count),
                "definition_sha1": digest,
                "language_hints": language_hints(text, paths),
                **flags,
                "role_category": role,
                "review_batch": batch_id,
                "review_reason": review_reason,
                "object_row_count": str(len(objs)),
                "read_row_count": str(direction_counts.get("read", 0)),
                "write_row_count": str(direction_counts.get("write", 0)),
                "execute_row_count": str(direction_counts.get("execute", 0)),
                "unique_read_objects": str(len(set(read_objects))),
                "unique_write_objects": str(len(set(write_objects))),
                "unique_execute_objects": str(len(set(execute_objects))),
                "flow_row_count": str(len(flows)),
                "parsed_row_count": str(conf_counts.get("parsed", 0)),
                "likely_row_count": str(conf_counts.get("likely", 0)),
                "review_row_count": str(conf_counts.get("review", 0)),
                "unresolved_row_count": str(unresolved_count),
                "gap_types": "; ".join(gap_types),
                "sample_read_objects": concise_join(read_objects),
                "sample_write_objects": concise_join(write_objects),
                "sample_execute_objects": concise_join(execute_objects),
            }
        )

        aggregate: dict[tuple[str, str], dict[str, object]] = {}
        for row in objs:
            key = (row.get("direction", ""), row.get("object_display_name", ""))
            if not key[0] or not key[1]:
                continue
            bucket = aggregate.setdefault(
                key,
                {
                    "operations": set(),
                    "confidences": Counter(),
                    "line_numbers": set(),
                    "unresolved": set(),
                    "source_types": set(),
                    "definition_paths": set(),
                },
            )
            bucket["operations"].add(row.get("operation", ""))
            bucket["confidences"][row.get("confidence", "")] += 1
            if row.get("line_number"):
                bucket["line_numbers"].add(row.get("line_number", ""))
            if row.get("unresolved_variables"):
                bucket["unresolved"].add(row.get("unresolved_variables", ""))
            if row.get("source_type"):
                bucket["source_types"].add(row.get("source_type", ""))
            if row.get("definition_path"):
                bucket["definition_paths"].add(row.get("definition_path", ""))

        for (direction, object_name), bucket in sorted(aggregate.items()):
            conf_counter: Counter = bucket["confidences"]  # type: ignore[assignment]
            confidence = "parsed" if conf_counter.get("parsed", 0) >= conf_counter.get("likely", 0) else "likely"
            if conf_counter.get("review", 0) and not conf_counter.get("parsed", 0):
                confidence = "review"
            touchpoint_rows.append(
                {
                    "item_qualified_name": qualified,
                    "workspace_name": item.get("workspace_name", ""),
                    "workspace_environment": item.get("workspace_environment", ""),
                    "notebook_name": item.get("item_name", ""),
                    "direction": direction,
                    "object_display_name": object_name,
                    "source_types": "; ".join(sorted(bucket["source_types"])),  # type: ignore[arg-type]
                    "operations": "; ".join(sorted(v for v in bucket["operations"] if v)),  # type: ignore[arg-type]
                    "row_count": str(sum(conf_counter.values())),
                    "confidence": confidence,
                    "confidence_counts": json.dumps(dict(conf_counter), sort_keys=True),
                    "line_numbers": concise_join(sorted(bucket["line_numbers"], key=lambda x: int(x) if x.isdigit() else 0), 20),  # type: ignore[arg-type]
                    "unresolved_variables": "; ".join(sorted(bucket["unresolved"])),  # type: ignore[arg-type]
                    "definition_paths": "; ".join(sorted(bucket["definition_paths"])),  # type: ignore[arg-type]
                    "review_batch": batch_id,
                }
            )

        flow_aggregate: dict[tuple[str, str], dict[str, object]] = {}
        for row in flows:
            key = (row.get("source_object", ""), row.get("target_object", ""))
            if not key[0] or not key[1]:
                continue
            bucket = flow_aggregate.setdefault(
                key,
                {"operations": set(), "confidences": Counter(), "evidence": set(), "definition_paths": set()},
            )
            bucket["operations"].add(row.get("operation", ""))
            bucket["confidences"][row.get("confidence", "")] += 1
            if row.get("evidence"):
                bucket["evidence"].add(row.get("evidence", ""))
            if row.get("definition_path"):
                bucket["definition_paths"].add(row.get("definition_path", ""))

        for (source, target), bucket in sorted(flow_aggregate.items()):
            conf_counter: Counter = bucket["confidences"]  # type: ignore[assignment]
            confidence = "parsed" if conf_counter.get("parsed", 0) >= conf_counter.get("likely", 0) else "likely"
            flow_catalog_rows.append(
                {
                    "item_qualified_name": qualified,
                    "workspace_name": item.get("workspace_name", ""),
                    "workspace_environment": item.get("workspace_environment", ""),
                    "notebook_name": item.get("item_name", ""),
                    "source_object": source,
                    "target_object": target,
                    "operations": "; ".join(sorted(v for v in bucket["operations"] if v)),  # type: ignore[arg-type]
                    "row_count": str(sum(conf_counter.values())),
                    "confidence": confidence,
                    "confidence_counts": json.dumps(dict(conf_counter), sort_keys=True),
                    "evidence": concise_join(sorted(bucket["evidence"]), 5),  # type: ignore[arg-type]
                    "definition_paths": "; ".join(sorted(bucket["definition_paths"])),  # type: ignore[arg-type]
                    "review_batch": batch_id,
                }
            )

    batch_names = {
        "B01": "definition_missing_or_export_failed",
        "B02": "no_objects_helpers_templates_or_external_control",
        "B03": "execute_only_orchestration",
        "B04": "dynamic_or_likely_heavy_lineage",
        "B05": "source_to_target_flows_available",
        "B06": "touchpoints_without_direct_flow",
        "B07": "manual_review_fallback",
        "B08": "non_transform_touchpoints_no_flow_expected",
    }
    batch_rows = []
    for batch_id in sorted(batch_names):
        batch_rows.append(
            {
                "review_batch": batch_id,
                "batch_name": batch_names[batch_id],
                "notebook_count": str(batch_counter.get(batch_id, 0)),
                "recommended_action": {
                    "B01": "Retry/read definition export only; no execution.",
                    "B02": "Confirm helper/template/API-control nature and add parser rules only if real data objects are hidden.",
                    "B03": "Link executed notebooks to inherited lineage where orchestration requires it.",
                    "B04": "Review dynamic variables and reduce likely/unresolved rows with targeted parser/backfill.",
                    "B05": "Use for graph review; these have direct static flows.",
                    "B06": "Inspect code paths to pair reads and writes where safe.",
                    "B07": "Manual targeted inspection.",
                    "B08": "Keep as visibility/control/purge evidence; do not use as hard source-to-target orchestration rules.",
                }[batch_id],
            }
        )

    summary_fields = [
        "item_qualified_name",
        "workspace_name",
        "workspace_environment",
        "notebook_name",
        "definition_status",
        "definition_error",
        "definition_paths",
        "definition_file_count",
        "definition_total_bytes",
        "definition_line_count",
        "definition_sha1",
        "language_hints",
        "has_magic_sql",
        "has_notebook_run",
        "has_spark_read",
        "has_spark_write",
        "has_jdbc",
        "has_requests",
        "has_secret",
        "role_category",
        "review_batch",
        "review_reason",
        "object_row_count",
        "read_row_count",
        "write_row_count",
        "execute_row_count",
        "unique_read_objects",
        "unique_write_objects",
        "unique_execute_objects",
        "flow_row_count",
        "parsed_row_count",
        "likely_row_count",
        "review_row_count",
        "unresolved_row_count",
        "gap_types",
        "sample_read_objects",
        "sample_write_objects",
        "sample_execute_objects",
    ]
    touchpoint_fields = [
        "item_qualified_name",
        "workspace_name",
        "workspace_environment",
        "notebook_name",
        "direction",
        "object_display_name",
        "source_types",
        "operations",
        "row_count",
        "confidence",
        "confidence_counts",
        "line_numbers",
        "unresolved_variables",
        "definition_paths",
        "review_batch",
    ]
    flow_fields = [
        "item_qualified_name",
        "workspace_name",
        "workspace_environment",
        "notebook_name",
        "source_object",
        "target_object",
        "operations",
        "row_count",
        "confidence",
        "confidence_counts",
        "evidence",
        "definition_paths",
        "review_batch",
    ]
    write_csv(ROOT / "analysis/notebook_lineage_review_summary.csv", summary_rows, summary_fields)
    write_csv(ROOT / "analysis/notebook_lineage_touchpoints.csv", touchpoint_rows, touchpoint_fields)
    write_csv(ROOT / "analysis/notebook_lineage_flow_catalog.csv", flow_catalog_rows, flow_fields)
    write_csv(ROOT / "analysis/notebook_lineage_review_batches.csv", batch_rows, ["review_batch", "batch_name", "notebook_count", "recommended_action"])

    for batch_id in sorted(batch_names):
        batch_summary = [row for row in summary_rows if row["review_batch"] == batch_id]
        write_csv(ROOT / f"analysis/notebook_lineage_batch_{batch_id.lower()}.csv", batch_summary, summary_fields)

    doc_lines = [
        "# Notebook Lineage Review Batches",
        "",
        "Generated from local notebook definitions and static notebook super-lineage outputs.",
        "",
        "## Outputs",
        "",
        "- `analysis/notebook_lineage_review_summary.csv`",
        "- `analysis/notebook_lineage_touchpoints.csv`",
        "- `analysis/notebook_lineage_flow_catalog.csv`",
        "- `analysis/notebook_lineage_review_batches.csv`",
        "- `analysis/notebook_lineage_batch_b01.csv` through `analysis/notebook_lineage_batch_b08.csv`",
        "",
        "## Batch Counts",
        "",
    ]
    for row in batch_rows:
        doc_lines.append(f"- `{row['review_batch']}` `{row['batch_name']}`: {row['notebook_count']} notebooks")
    doc_lines.extend(["", "## Role Counts", ""])
    for role, count in role_counter.most_common():
        doc_lines.append(f"- `{role}`: {count}")
    doc_lines.extend(
        [
            "",
            "## Current Evidence",
            "",
            f"- Notebook inventory rows: {len(items)}",
            f"- Notebook summary rows: {len(summary_rows)}",
            f"- Touchpoint rows: {len(touchpoint_rows)}",
            f"- Source-to-target flow rows: {len(flow_catalog_rows)}",
            "",
            "## Safety",
            "",
            "- No notebook was executed.",
            "- No external system was modified.",
            "- `likely` and unresolved rows remain review evidence, not hard orchestration rules.",
        ]
    )
    (ROOT / "docs/46_notebook_lineage_review_batches.md").write_text("\n".join(doc_lines) + "\n", encoding="utf-8")

    print("Notebook lineage review batches built.")
    print(f"Notebook summaries: {len(summary_rows)}")
    print(f"Touchpoints: {len(touchpoint_rows)}")
    print(f"Flow catalog rows: {len(flow_catalog_rows)}")
    for row in batch_rows:
        print(f"{row['review_batch']}: {row['notebook_count']} {row['batch_name']}")


if __name__ == "__main__":
    main()
