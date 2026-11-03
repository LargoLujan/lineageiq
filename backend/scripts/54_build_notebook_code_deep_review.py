#!/usr/bin/env python3
"""Build a notebook code-read audit over every mapped notebook.

The output is intentionally notebook-level: it proves which local definitions
were read, what kind of active code was detected, and whether current lineage
evidence is flow-level, touchpoint-only, execute-only, helper/control, or still
missing.
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


def split_paths(value: str) -> list[str]:
    return [part.strip() for part in re.split(r";\s*", value or "") if part.strip()]


def read_paths(paths: list[str]) -> tuple[str, int, int, str, str]:
    chunks: list[str] = []
    total_bytes = 0
    line_count = 0
    existing: list[str] = []
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
        chunks.append(text)
        existing.append(path_text)
    return "\n\n".join(chunks), total_bytes, line_count, sha.hexdigest()[:16] if existing else "", "; ".join(existing)


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


def uncomment_magic_python(code: str) -> str:
    output: list[str] = []
    mode = ""
    for line in code.splitlines():
        stripped = line.lstrip()
        indent = line[: len(line) - len(stripped)]
        if stripped.startswith("# MAGIC"):
            content = stripped[len("# MAGIC"):].lstrip()
            marker = content.strip().lower()
            if marker.startswith(("%%pyspark", "%%python", "%python")):
                mode = "python"
                after_marker = re.sub(r"(?is)^\s*%{1,2}(?:pyspark|python)\b", "", content, count=1)
                output.append(indent + (after_marker if after_marker.strip() else "# magic python"))
            elif marker.startswith(("%%sql", "%sql")):
                mode = "sql"
                output.append(indent + "# " + content)
            elif mode == "python":
                output.append(indent + content)
            else:
                output.append(indent + "# " + content)
        else:
            output.append(line)
            if not stripped.startswith("#") and stripped.strip():
                mode = ""
    return "\n".join(output)


def active_lines(code: str) -> list[str]:
    lines = []
    for line in uncomment_magic_python(code).splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith("#") or stripped.startswith("--") or stripped.startswith("!") or stripped.startswith("%pip"):
            continue
        if stripped.startswith("# META") or stripped.startswith("# CELL") or stripped.startswith("# MARKDOWN"):
            continue
        lines.append(line)
    return lines


def count_pattern(lines: list[str], pattern: str) -> int:
    regex = re.compile(pattern, re.I)
    return sum(1 for line in lines if regex.search(line))


def first_evidence_line(code: str) -> str:
    patterns = [
        r"\bspark\.read|\bspark\.table\s*\(|\bspark\.sql\s*\(|saveAsTable|\.write|load_table\s*\(|write_reduction_table\s*\(",
        r"create_process_control_table|get_last_successful_process|drop_table_if_exists|mssparkutils\.fs\.rm",
        r"notebook\.run|^\s*%run|requests\.|refresh|executeQueries",
    ]
    lines = active_lines(code)
    for pattern in patterns:
        regex = re.compile(pattern, re.I)
        for index, line in enumerate(lines, start=1):
            if regex.search(line):
                return f"{index}: {line.strip()[:220]}"
    return ""


def classify(
    summary: dict[str, str],
    object_rows: list[dict[str, str]],
    flow_rows: list[dict[str, str]],
    code: str,
    active: list[str],
) -> tuple[str, str, str]:
    if summary.get("definition_status") != "downloaded":
        return "definition_missing", "missing_definition", "Definition was not available locally."

    operations = {row.get("operation", "") for row in object_rows}
    directions = Counter(row.get("direction", "") for row in object_rows)
    name = summary.get("notebook_name", "").casefold()

    if flow_rows:
        return "confirmed_static_flow", "transform_or_mapping", "Static code exposes source-to-target flow rows."
    if directions.get("execute", 0) and not directions.get("read", 0) and not directions.get("write", 0):
        return "execute_only", "orchestrator", "Notebook executes other notebooks without direct data touchpoints."
    if object_rows:
        is_central_registry = (
            "central_registry_audit_table" in operations
            and "schema shortcuts" in code.casefold()
            and "sin copia de datos" in code.casefold()
        )
        if is_central_registry:
            return (
                "touchpoints_confirmed_no_flow",
                "registry_shortcut_metadata",
                "Notebook manages Fabric/OneLake shortcuts and audit metadata; no direct business source-to-target data output is expected.",
            )
        if "drop_table_path" in operations:
            return "touchpoints_confirmed_no_flow", "purge_or_full_reload", "Notebook touches tables through drop/purge operations."
        if "create_process_control_table" in operations or "get_last_successful_process" in operations:
            return "touchpoints_confirmed_no_flow", "control_status", "Notebook reads/writes process control status."
        if directions.get("read", 0) and directions.get("write", 0):
            return "touchpoints_confirmed_no_flow", "transform_pairing_needed", "Reads and writes are known, but pairing is not statically direct."
        if directions.get("read", 0):
            return "source_touchpoints_only", "source_or_validation", "Reads are known; no write target found in active code."
        if directions.get("write", 0):
            return "destination_touchpoints_only", "destination_or_export", "Writes are known; no source object found in active code."

    active_data_count = count_pattern(active, r"\bspark\.read|\bspark\.table\s*\(|\bspark\.sql\s*\(|saveAsTable|\.write|load_table\s*\(|write_reduction_table\s*\(")
    active_control_count = count_pattern(active, r"requests\.|notebookutils|mssparkutils|refresh|executeQueries|create_process_control_table")
    commented_data_count = len(
        re.findall(r"(?im)^\s*#.*(?:spark\.read|spark\.table|spark\.sql|saveAsTable|\.write|CREATE TABLE|INSERT INTO)", code)
    )

    if "common_utils" in name or "credentials" in name or "template" in name:
        return "helper_or_template_no_concrete_objects", "helper_or_template", "Code defines utilities/config/templates; no concrete table/view/SP touchpoint is active."
    if commented_data_count and not active_data_count:
        return "inactive_or_commented_legacy_code", "inactive_legacy", "Data operations are present only in comments or disabled sample code."
    if active_control_count and not active_data_count:
        return "control_or_external_api_no_table_touch", "control_or_api", "Active code calls APIs/control helpers but no concrete table/view/SP is touched."
    if "test" in name or name == "tests":
        return "test_or_demo_no_concrete_objects", "test_or_demo", "Test/demo notebook with no concrete active table/view/SP touchpoint."
    if not active:
        return "empty_or_placeholder", "placeholder", "No active code lines found."
    return "no_concrete_data_objects_found", "unknown_no_objects", "Active code exists but no concrete table/view/SP touchpoint was found."


def main() -> None:
    summary_rows = read_csv(ROOT / "analysis/notebook_lineage_review_summary.csv")
    object_rows = read_csv(ROOT / "analysis/notebook_super_lineage_objects.csv")
    flow_rows = read_csv(ROOT / "analysis/notebook_super_lineage_flows.csv")

    objects_by_item: dict[str, list[dict[str, str]]] = defaultdict(list)
    flows_by_item: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in object_rows:
        objects_by_item[row.get("item_qualified_name", "")].append(row)
    for row in flow_rows:
        flows_by_item[row.get("item_qualified_name", "")].append(row)

    review_rows: list[dict[str, str]] = []
    status_counter: Counter = Counter()
    role_counter: Counter = Counter()

    for row in summary_rows:
        paths = split_paths(row.get("definition_paths", ""))
        code, total_bytes, line_count, digest, existing_paths = read_paths(paths)
        active = active_lines(code)
        item = row.get("item_qualified_name", "")
        objs = objects_by_item.get(item, [])
        flows = flows_by_item.get(item, [])
        status, role, note = classify(row, objs, flows, code, active)
        status_counter[status] += 1
        role_counter[role] += 1
        operations = Counter(obj.get("operation", "") for obj in objs if obj.get("operation"))

        review_rows.append(
            {
                "item_qualified_name": item,
                "workspace_name": row.get("workspace_name", ""),
                "workspace_environment": row.get("workspace_environment", ""),
                "notebook_name": row.get("notebook_name", ""),
                "code_read_status": "read" if existing_paths else "not_read",
                "definition_status": row.get("definition_status", ""),
                "definition_paths": existing_paths,
                "definition_total_bytes": str(total_bytes),
                "definition_line_count": str(line_count),
                "definition_sha1": digest,
                "active_code_line_count": str(len(active)),
                "active_data_operation_lines": str(
                    count_pattern(active, r"\bspark\.read|\bspark\.table\s*\(|\bspark\.sql\s*\(|saveAsTable|\.write|load_table\s*\(|write_reduction_table\s*\(")
                ),
                "active_control_or_api_lines": str(
                    count_pattern(active, r"requests\.|notebookutils|mssparkutils|refresh|executeQueries|create_process_control_table")
                ),
                "commented_data_operation_lines": str(
                    len(re.findall(r"(?im)^\s*#.*(?:spark\.read|spark\.table|spark\.sql|saveAsTable|\.write|CREATE TABLE|INSERT INTO)", code))
                ),
                "object_row_count": row.get("object_row_count", "0"),
                "flow_row_count": row.get("flow_row_count", "0"),
                "read_row_count": row.get("read_row_count", "0"),
                "write_row_count": row.get("write_row_count", "0"),
                "execute_row_count": row.get("execute_row_count", "0"),
                "likely_row_count": row.get("likely_row_count", "0"),
                "unresolved_row_count": row.get("unresolved_row_count", "0"),
                "review_batch": row.get("review_batch", ""),
                "lineage_code_review_status": status,
                "lineage_code_role": role,
                "lineage_code_review_note": note,
                "top_operations": "; ".join(f"{name}:{count}" for name, count in operations.most_common(8)),
                "sample_read_objects": row.get("sample_read_objects", ""),
                "sample_write_objects": row.get("sample_write_objects", ""),
                "sample_execute_objects": row.get("sample_execute_objects", ""),
                "sample_code_evidence": first_evidence_line(code),
            }
        )

    fields = [
        "item_qualified_name",
        "workspace_name",
        "workspace_environment",
        "notebook_name",
        "code_read_status",
        "definition_status",
        "definition_paths",
        "definition_total_bytes",
        "definition_line_count",
        "definition_sha1",
        "active_code_line_count",
        "active_data_operation_lines",
        "active_control_or_api_lines",
        "commented_data_operation_lines",
        "object_row_count",
        "flow_row_count",
        "read_row_count",
        "write_row_count",
        "execute_row_count",
        "likely_row_count",
        "unresolved_row_count",
        "review_batch",
        "lineage_code_review_status",
        "lineage_code_role",
        "lineage_code_review_note",
        "top_operations",
        "sample_read_objects",
        "sample_write_objects",
        "sample_execute_objects",
        "sample_code_evidence",
    ]
    write_csv(ROOT / "analysis/notebook_code_deep_review.csv", review_rows, fields)

    summary = [
        {"metric": "notebooks_reviewed", "value": str(len(review_rows)), "notes": "Notebook rows in deep code review."},
        {"metric": "code_read", "value": str(sum(1 for row in review_rows if row["code_read_status"] == "read")), "notes": "Definitions read from local files."},
        {"metric": "code_not_read", "value": str(sum(1 for row in review_rows if row["code_read_status"] != "read")), "notes": "Definitions missing locally."},
    ]
    for status, count in status_counter.most_common():
        summary.append({"metric": f"status_{status}", "value": str(count), "notes": "Deep code review status split."})
    for role, count in role_counter.most_common():
        summary.append({"metric": f"role_{role}", "value": str(count), "notes": "Deep code review role split."})
    write_csv(ROOT / "analysis/notebook_code_deep_review_summary.csv", summary, ["metric", "value", "notes"])

    doc_lines = [
        "# Notebook Code Deep Review",
        "",
        "Generated from every mapped notebook row and its local downloaded definition when available.",
        "",
        "## Outputs",
        "",
        "- `analysis/notebook_code_deep_review.csv`",
        "- `analysis/notebook_code_deep_review_summary.csv`",
        "",
        "## Summary",
        "",
    ]
    for item in summary:
        doc_lines.append(f"- `{item['metric']}`: {item['value']}")
    doc_lines.extend(
        [
            "",
            "## Safety",
            "",
            "- Code was read statically from local definitions.",
            "- No notebook was executed.",
            "- No external system was modified.",
            "- Rows with `likely` or unresolved variables remain review evidence, not hard orchestration rules.",
        ]
    )
    (ROOT / "docs/47_notebook_code_deep_review.md").write_text("\n".join(doc_lines) + "\n", encoding="utf-8")

    print("Notebook code deep review built.")
    print(f"Rows: {len(review_rows)}")
    for status, count in status_counter.most_common():
        print(f"{status}: {count}")


if __name__ == "__main__":
    main()
