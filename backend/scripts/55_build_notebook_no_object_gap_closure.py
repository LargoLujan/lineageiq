#!/usr/bin/env python3
"""Classify notebook no-object parse gaps into actionable or closed buckets."""

from __future__ import annotations

import csv
from collections import Counter
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


def closure_for(review: dict[str, str]) -> tuple[str, str, str, str]:
    status = review.get("lineage_code_review_status", "")
    role = review.get("lineage_code_role", "")
    if status == "helper_or_template_no_concrete_objects":
        return (
            "closed_non_data_notebook",
            "helper_or_template",
            "Utility/config/template code; no concrete table/view/SP dependency is expected.",
            "Keep visible as helper context only.",
        )
    if status == "test_or_demo_no_concrete_objects":
        return (
            "closed_non_data_notebook",
            "test_or_demo",
            "Test/demo notebook; no operational table/view/SP dependency is expected.",
            "Exclude from hard orchestration rules unless promoted to production logic.",
        )
    if status == "control_or_external_api_no_table_touch":
        return (
            "closed_non_data_notebook",
            "control_or_api",
            "Control/API code with no concrete table/view/SP touchpoint.",
            "Track as control/API evidence only.",
        )
    if status == "empty_or_placeholder":
        return (
            "closed_non_data_notebook",
            "placeholder",
            "Empty or placeholder notebook; no data dependency is expected.",
            "No lineage action unless the notebook is later populated.",
        )
    if status == "inactive_or_commented_legacy_code":
        return (
            "closed_non_data_notebook",
            "inactive_legacy",
            "Data operations are disabled or commented; no active lineage dependency is expected.",
            "Do not use commented code as orchestration evidence.",
        )
    if status:
        return (
            "needs_targeted_review",
            role or "unknown",
            "No-object gap has a deep-review status that is not in the closed non-data list.",
            "Inspect active code before using or dismissing the gap.",
        )
    return (
        "needs_targeted_review",
        "missing_deep_review",
        "No matching deep code review row was found.",
        "Rebuild notebook review outputs.",
    )


def main() -> None:
    gaps = [
        row
        for row in read_csv(ROOT / "analysis/notebook_super_lineage_gaps.csv")
        if row.get("gap_type") == "no_objects_parsed"
    ]
    summary_by_item = {
        row.get("item_qualified_name", ""): row
        for row in read_csv(ROOT / "analysis/notebook_lineage_review_summary.csv")
    }
    review_by_item = {
        row.get("item_qualified_name", ""): row
        for row in read_csv(ROOT / "analysis/notebook_code_deep_review.csv")
    }

    rows: list[dict[str, str]] = []
    for gap in sorted(gaps, key=lambda r: (r.get("workspace_name", ""), r.get("item_name", ""), r.get("definition_paths", ""))):
        item = gap.get("item_qualified_name", "")
        summary = summary_by_item.get(item, {})
        review = review_by_item.get(item, {})
        closure_status, closure_role, closure_reason, next_action = closure_for(review)
        rows.append(
            {
                "item_qualified_name": item,
                "workspace_name": gap.get("workspace_name", ""),
                "notebook_name": gap.get("item_name", ""),
                "review_batch": summary.get("review_batch", ""),
                "role_category": summary.get("role_category", ""),
                "gap_type": gap.get("gap_type", ""),
                "closure_status": closure_status,
                "closure_role": closure_role,
                "closure_reason": closure_reason,
                "lineage_code_review_status": review.get("lineage_code_review_status", ""),
                "lineage_code_role": review.get("lineage_code_role", ""),
                "active_code_line_count": review.get("active_code_line_count", ""),
                "active_data_operation_lines": review.get("active_data_operation_lines", ""),
                "active_control_or_api_lines": review.get("active_control_or_api_lines", ""),
                "commented_data_operation_lines": review.get("commented_data_operation_lines", ""),
                "sample_code_evidence": review.get("sample_code_evidence", ""),
                "definition_paths": gap.get("definition_paths", ""),
                "hard_orchestration_dependency": "no" if closure_status == "closed_non_data_notebook" else "unknown",
                "next_action": next_action,
            }
        )

    fields = [
        "item_qualified_name",
        "workspace_name",
        "notebook_name",
        "review_batch",
        "role_category",
        "gap_type",
        "closure_status",
        "closure_role",
        "closure_reason",
        "lineage_code_review_status",
        "lineage_code_role",
        "active_code_line_count",
        "active_data_operation_lines",
        "active_control_or_api_lines",
        "commented_data_operation_lines",
        "sample_code_evidence",
        "definition_paths",
        "hard_orchestration_dependency",
        "next_action",
    ]
    write_csv(ROOT / "analysis/notebook_no_object_gap_closure.csv", rows, fields)

    status_counts = Counter(row["closure_status"] for row in rows)
    role_counts = Counter(row["closure_role"] for row in rows)
    review_counts = Counter(row["lineage_code_review_status"] for row in rows)
    summary_rows = [
        {"metric": "no_object_gap_rows", "value": str(len(rows)), "notes": "Rows from notebook_super_lineage_gaps.csv with no_objects_parsed."},
    ]
    for status, count in sorted(status_counts.items()):
        summary_rows.append({"metric": f"closure_status_{status}", "value": str(count), "notes": "No-object closure status split."})
    for role, count in role_counts.most_common():
        summary_rows.append({"metric": f"closure_role_{role}", "value": str(count), "notes": "No-object closure role split."})
    for status, count in review_counts.most_common():
        summary_rows.append({"metric": f"deep_review_status_{status}", "value": str(count), "notes": "Deep review status for no-object gaps."})
    write_csv(ROOT / "analysis/notebook_no_object_gap_closure_summary.csv", summary_rows, ["metric", "value", "notes"])

    doc_lines = [
        "# Notebook No-Object Gap Closure",
        "",
        "Generated from notebook super-lineage gaps plus the deep code-read audit.",
        "",
        "## Outputs",
        "",
        "- `analysis/notebook_no_object_gap_closure.csv`",
        "- `analysis/notebook_no_object_gap_closure_summary.csv`",
        "",
        "## Summary",
        "",
    ]
    for row in summary_rows:
        doc_lines.append(f"- `{row['metric']}`: {row['value']}")
    doc_lines.extend(
        [
            "",
            "## Safety",
            "",
            "- Closed non-data notebooks are not hard orchestration dependencies.",
            "- This script reads local evidence only and does not execute notebooks.",
            "- If a closed notebook later receives active table/view/SP code, rebuild the parser outputs.",
        ]
    )
    (ROOT / "docs/48_notebook_no_object_gap_closure.md").write_text("\n".join(doc_lines) + "\n", encoding="utf-8")

    print("Notebook no-object gap closure built.")
    print(f"Rows: {len(rows)}")
    for status, count in sorted(status_counts.items()):
        print(f"{status}: {count}")


if __name__ == "__main__":
    main()
