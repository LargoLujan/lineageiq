#!/usr/bin/env python3
"""Fast Python port of 21_build_reverse_impact_package.ps1. Local-only: reads
the object impact index/summary, the SQL endpoint catalog, and the lineage
explorer JSON; writes frontend/semantic-lineage/data/object-impact.json plus a
markdown summary doc. Does not query or modify Fabric.
"""

import argparse
import csv
import json
import os
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent.parent  # D.0: anchor default paths to the repo, not $PWD

EXACT_TYPE_PATTERN = re.compile(r"(^|; )(table|view|stored_procedure|file|shortcut|query)(;|$)")
AMBIGUOUS_TYPE_PATTERN = re.compile(r"table_or_view|native_query_object")


def ensure_parent(path):
    parent = Path(path).parent
    if str(parent):
        parent.mkdir(parents=True, exist_ok=True)


def write_json_atomic(path, payload):
    # Colleagues load this file directly over the shared tunnel while a scan
    # may be regenerating it. Write to a temp file in the same directory
    # first, then os.replace() -- atomic on both POSIX and Windows -- so a
    # crash mid-write never leaves a truncated file being served.
    ensure_parent(path)
    tmp_path = f"{path}.tmp-{os.getpid()}"
    try:
        with open(tmp_path, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        raise


def get_field(row, names):
    if row is None:
        return ""
    for name in names:
        if name in row:
            value = row[name]
            if value is not None:
                return str(value)
    return ""


def normalize_key(value):
    if not value:
        return ""
    return re.sub(r"\s+", " ", str(value).strip().lower())


def new_object_alias_key(source_database, schema_name, object_name):
    return "|".join([normalize_key(source_database), normalize_key(schema_name), normalize_key(object_name)])


def build_column_catalog_lookup(column_rows):
    by_full_key = {}
    schemas_by_name_key = {}
    for row in column_rows:
        full_key = (
            normalize_key(row.get("source_server", "")),
            normalize_key(row.get("source_database", "")),
            normalize_key(row.get("schema_name", "")),
            normalize_key(row.get("object_name", "")),
        )
        by_full_key.setdefault(full_key, []).append(row)
        name_key = (full_key[0], full_key[1], full_key[3])
        schemas_by_name_key.setdefault(name_key, set()).add(full_key[2])
    return by_full_key, schemas_by_name_key


def get_columns_for_impact_object(object_row, by_full_key, schemas_by_name_key):
    server = get_field(object_row, ["source_server"])
    database = get_field(object_row, ["source_database"])
    schema = get_field(object_row, ["schema_name"])
    object_name = get_field(object_row, ["object_name"])
    if not server or not database or not object_name:
        return []

    full_key = (normalize_key(server), normalize_key(database), normalize_key(schema), normalize_key(object_name))
    if full_key not in by_full_key and not schema:
        name_key = (full_key[0], full_key[1], full_key[3])
        schemas = schemas_by_name_key.get(name_key)
        if schemas and len(schemas) == 1:
            only_schema = next(iter(schemas))
            full_key = (full_key[0], full_key[1], only_schema, full_key[3])

    rows = by_full_key.get(full_key)
    if not rows:
        return []

    def sort_key(row):
        try:
            return int(row.get("column_id", 0) or 0)
        except ValueError:
            return 0

    return [
        {
            "column_name": row.get("column_name", ""),
            "data_type": row.get("data_type", ""),
            "max_length": row.get("max_length", ""),
            "precision": row.get("precision", ""),
            "scale": row.get("scale", ""),
            "is_nullable": row.get("is_nullable", ""),
        }
        for row in sorted(rows, key=sort_key)
    ]


def read_csv(path):
    if not path or not Path(path).exists():
        return []
    with open(path, newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def ci_lower(value):
    return (value or "").lower()


def unique_ci_preserve_order(values):
    seen = set()
    result = []
    for value in values:
        if not value:
            continue
        key = ci_lower(value)
        if key in seen:
            continue
        seen.add(key)
        result.append(value)
    return result


def add_unique(target_list, seen, key, value):
    if not key or key in seen:
        return
    seen.add(key)
    target_list.append(value)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--impact-index-path", default=str(REPO_ROOT / "analysis/object_impact_index.csv"))
    parser.add_argument("--impact-summary-path", default=str(REPO_ROOT / "analysis/object_impact_summary.csv"))
    parser.add_argument("--catalog-path", default=str(REPO_ROOT / "analysis/sql_endpoint_object_catalog.csv"))
    parser.add_argument("--object-column-catalog-path", default=str(REPO_ROOT / "analysis/object_column_catalog.csv"))
    parser.add_argument("--explorer-data-path", default=str(REPO_ROOT / "frontend/semantic-lineage/data/lineage-explorer.json"))
    parser.add_argument("--output-json-path", default=str(REPO_ROOT / "frontend/semantic-lineage/data/object-impact.json"))
    parser.add_argument("--output-doc-path", default=str(REPO_ROOT / "docs/18_reverse_impact_search.md"))
    args = parser.parse_args()

    for required in (args.impact_index_path, args.impact_summary_path, args.explorer_data_path):
        if not Path(required).exists():
            raise SystemExit(f"Required input not found: {required}")

    raw_impact_rows = [r for r in read_csv(args.impact_index_path) if r.get("object_key") and r.get("item_qualified_name")]
    summary_rows = [r for r in read_csv(args.impact_summary_path) if r.get("object_key")]
    catalog_rows = [
        r
        for r in read_csv(args.catalog_path)
        if r.get("object_key") and r.get("source_database") and r.get("schema_name") and r.get("object_name")
    ]
    object_column_catalog_rows = [r for r in read_csv(args.object_column_catalog_path) if r.get("object_name") and r.get("column_name")]
    column_catalog_by_full_key, column_catalog_schemas_by_name_key = build_column_catalog_lookup(object_column_catalog_rows)
    with open(args.explorer_data_path, encoding="utf-8-sig") as handle:
        explorer = json.load(handle)

    # A qualified_name -> full item-node lookup from the already-built
    # explorer JSON, used only to enrich direct_items/downstream_reports
    # below with execution/default_identity -- no true "last modified by/
    # date" exists in the Fabric or Power BI APIs this account can reach
    # (verified live against both), so latest execution + configured
    # identity are the closest real signals available for "who/what last
    # touched this" without inventing data.
    item_by_qn = {}
    for workspace in explorer.get("workspaces", []) or []:
        for item in workspace.get("all", []) or []:
            qn = get_field(item, ["qualified_name"])
            if qn:
                item_by_qn[qn] = item

    def activity_fields(qualified_name):
        matched = item_by_qn.get(qualified_name)
        if not matched:
            return {"execution": None, "default_identity": ""}
        return {
            "execution": matched.get("execution"),
            "default_identity": matched.get("default_identity", ""),
        }

    reports_by_semantic_model = {}
    for workspace in explorer.get("workspaces", []) or []:
        for model in workspace.get("semantic", []) or []:
            model_name = get_field(model, ["qualified_name"])
            if not model_name:
                continue
            reports = []
            seen_reports = set()
            for report in model.get("reports", []) or []:
                report_name = get_field(report, ["qualified_name"])
                add_unique(
                    reports,
                    seen_reports,
                    report_name,
                    {
                        "label": get_field(report, ["label", "item_name"]),
                        "item_type": get_field(report, ["item_type"]),
                        "workspace_name": get_field(report, ["workspace_name"]),
                        "qualified_name": report_name,
                        "confidence": get_field(report, ["confidence"]),
                        "evidence": get_field(report, ["evidence"]),
                        "impact_path": "source_object -> semantic_model -> report",
                        **activity_fields(report_name),
                    },
                )
            reports_by_semantic_model[model_name] = reports

    summary_by_object_key = {row["object_key"]: row for row in summary_rows}

    catalog_by_object_key = {}
    catalog_by_alias = defaultdict(list)
    for row in catalog_rows:
        if row["object_key"] not in catalog_by_object_key:
            catalog_by_object_key[row["object_key"]] = row
        alias = new_object_alias_key(row.get("source_database"), row.get("schema_name"), row.get("object_name"))
        catalog_by_alias[alias].append(row)

    impact_rows = []
    for row in raw_impact_rows:
        alias = new_object_alias_key(
            get_field(row, ["source_database"]), get_field(row, ["schema_name"]), get_field(row, ["object_name"])
        )
        catalog_matches = catalog_by_alias.get(alias, [])
        catalog_match = catalog_matches[0] if len(catalog_matches) == 1 else None

        if catalog_match:
            row = dict(row)
            row["object_key"] = get_field(catalog_match, ["object_key"])
            row["object_display_name"] = get_field(catalog_match, ["object_display_name"])
            row["source_type"] = get_field(catalog_match, ["source_type"])
            row["source_server"] = get_field(catalog_match, ["source_server"])
            row["source_database"] = get_field(catalog_match, ["source_database"])
            row["schema_name"] = get_field(catalog_match, ["schema_name"])
            row["object_name"] = get_field(catalog_match, ["object_name"])
            row["object_type"] = get_field(catalog_match, ["object_type"])
            row["raw_object_type"] = get_field(catalog_match, ["raw_object_type", "object_type"])
            row["object_type_source"] = get_field(catalog_match, ["object_type_source"])
            row["object_type_confidence"] = get_field(catalog_match, ["object_type_confidence"])
            row["evidence"] = (get_field(row, ["evidence"]) + " Catalog metadata: " + get_field(catalog_match, ["evidence"])).strip()
        impact_rows.append(row)

    impact_groups_by_key = defaultdict(list)
    for row in impact_rows:
        impact_groups_by_key[row["object_key"]].append(row)

    # summary_by_object_key also carries objects 17_build_object_impact_index_fast.py
    # seeded straight from the deep SQL/SQL-endpoint catalogs with zero known
    # consumers -- a real table nobody's scanned notebook/model references yet
    # is still real and should be findable by name, not silently dropped
    # because it has no impact rows or live sql_endpoint_object_catalog match.
    all_object_keys = sorted(
        {k for k in impact_groups_by_key if k} | {k for k in catalog_by_object_key if k} | {k for k in summary_by_object_key if k},
        key=ci_lower,
    )

    objects = []
    for object_key in all_object_keys:
        group_rows = impact_groups_by_key.get(object_key, [])
        catalog = catalog_by_object_key.get(object_key)
        summary = summary_by_object_key.get(object_key)
        first = group_rows[0] if group_rows else (catalog or summary)
        if not first:
            continue

        direct_items = []
        seen_direct = set()
        downstream_reports = []
        seen_reports = set()

        for row in group_rows:
            item_qn = get_field(row, ["item_qualified_name"])
            add_unique(
                direct_items,
                seen_direct,
                item_qn,
                {
                    "label": get_field(row, ["item_name"]),
                    "item_type": get_field(row, ["item_type"]),
                    "workspace_name": get_field(row, ["item_workspace_name"]),
                    "qualified_name": item_qn,
                    "mode": get_field(row, ["mode"]),
                    "usage_type": get_field(row, ["usage_type"]),
                    "confidence": get_field(row, ["confidence"]),
                    "source_label": get_field(row, ["source_label"]),
                    "semantic_table": get_field(row, ["semantic_table"]),
                    "evidence": get_field(row, ["evidence"]),
                    "impact_path": "source_object -> item",
                    **activity_fields(item_qn),
                },
            )
            if get_field(row, ["item_type"]) == "SemanticModel" and item_qn in reports_by_semantic_model:
                for report in reports_by_semantic_model[item_qn]:
                    add_unique(downstream_reports, seen_reports, report["qualified_name"], report)

        all_workspaces = sorted(
            unique_ci_preserve_order(
                [d["workspace_name"] for d in direct_items]
                + [r["workspace_name"] for r in downstream_reports]
                + ([get_field(catalog, ["workspace_name"])] if catalog else [])
            ),
            key=ci_lower,
        )
        all_item_types = sorted(
            unique_ci_preserve_order([d["item_type"] for d in direct_items] + [r["item_type"] for r in downstream_reports]),
            key=ci_lower,
        )

        if catalog:
            object_type_values = get_field(catalog, ["object_type"])
            object_type_sources = get_field(catalog, ["object_type_source"])
        elif summary:
            object_type_values = get_field(summary, ["object_type_values"])
            object_type_sources = get_field(summary, ["object_type_sources"])
        else:
            object_type_values = get_field(first, ["object_type"])
            object_type_sources = get_field(first, ["object_type_source"])

        affected_item_count = len({d["qualified_name"] for d in direct_items})
        downstream_report_count = len({r["qualified_name"] for r in downstream_reports})

        search_parts = [
            get_field(first, ["object_display_name"]),
            get_field(first, ["source_type"]),
            get_field(first, ["source_server"]),
            get_field(first, ["source_database"]),
            get_field(first, ["schema_name"]),
            get_field(first, ["object_name"]),
            object_type_values,
            get_field(catalog, ["sql_endpoint_name"]) if catalog else "",
            *all_workspaces,
            *[d["label"] for d in direct_items],
            *[r["label"] for r in downstream_reports],
        ]
        search_text = " ".join(p for p in search_parts if p).lower()

        direct_items_sorted = sorted(direct_items, key=lambda d: (ci_lower(d["item_type"]), ci_lower(d["workspace_name"]), ci_lower(d["label"])))
        downstream_reports_sorted = sorted(downstream_reports, key=lambda r: (ci_lower(r["workspace_name"]), ci_lower(r["label"])))

        objects.append(
            {
                "object_key": object_key,
                "object_display_name": get_field(first, ["object_display_name"]),
                "source_type": get_field(first, ["source_type"]),
                "source_server": get_field(first, ["source_server"]),
                "source_database": get_field(first, ["source_database"]),
                "schema_name": get_field(first, ["schema_name"]),
                "object_name": get_field(first, ["object_name"]),
                "columns": get_columns_for_impact_object(first, column_catalog_by_full_key, column_catalog_schemas_by_name_key),
                "object_type_values": object_type_values,
                "object_type_sources": object_type_sources,
                "affected_item_count": affected_item_count,
                "downstream_report_count": downstream_report_count,
                "total_impact_count": affected_item_count + downstream_report_count,
                "semantic_model_count": len({d["qualified_name"] for d in direct_items if d["item_type"] == "SemanticModel"}),
                "notebook_count": len({d["qualified_name"] for d in direct_items if d["item_type"] == "Notebook"}),
                "copyjob_count": len({d["qualified_name"] for d in direct_items if d["item_type"] == "CopyJob"}),
                "pipeline_count": len({d["qualified_name"] for d in direct_items if d["item_type"] == "DataPipeline"}),
                "dataflow_count": len({d["qualified_name"] for d in direct_items if d["item_type"] == "Dataflow"}),
                "report_count": downstream_report_count,
                "workspace_count": len(all_workspaces),
                "workspaces": all_workspaces,
                "affected_item_types": all_item_types,
                "search_text": search_text,
                "catalog_status": get_field(catalog, ["catalog_status"]) if catalog else "",
                "catalog_only": bool(catalog or summary) and affected_item_count == 0 and downstream_report_count == 0,
                "catalog_workspace_name": get_field(catalog, ["workspace_name"]) if catalog else "",
                "sql_endpoint_name": get_field(catalog, ["sql_endpoint_name"]) if catalog else "",
                "sql_endpoint_qualified_name": get_field(catalog, ["sql_endpoint_qualified_name"]) if catalog else "",
                "endpoint_resolution_method": get_field(catalog, ["endpoint_resolution_method"]) if catalog else "",
                "catalog_evidence": get_field(catalog, ["evidence"]) if catalog else "",
                "direct_items": direct_items_sorted,
                "downstream_reports": downstream_reports_sorted,
            }
        )

    objects.sort(key=lambda o: (-o["total_impact_count"], -o["affected_item_count"], ci_lower(o["object_display_name"])))

    impacted_direct_items = len({r["item_qualified_name"] for r in impact_rows})
    all_downstream_report_qns = {r["qualified_name"] for o in objects for r in o["downstream_reports"]}

    payload = {
        "generated_at": datetime.now().replace(microsecond=0).isoformat(),
        "summary": {
            "source_objects": len(objects),
            "direct_impact_rows": len(impact_rows),
            "impacted_direct_items": impacted_direct_items,
            "downstream_reports": len(all_downstream_report_qns),
            "max_total_impact": objects[0]["total_impact_count"] if objects else 0,
            "exact_object_type_objects": sum(1 for o in objects if EXACT_TYPE_PATTERN.search(o["object_type_values"] or "")),
            "unresolved_objects": sum(1 for o in objects if AMBIGUOUS_TYPE_PATTERN.search(o["object_type_values"] or "")),
            "catalog_objects": sum(1 for o in objects if o["catalog_status"]),
            "catalog_only_objects": sum(1 for o in objects if o["catalog_only"]),
        },
        "objects": objects,
    }

    write_json_atomic(args.output_json_path, payload)

    summary = payload["summary"]
    doc_lines = [
        "# Reverse Impact Search",
        "",
        f"Generated at: {payload['generated_at']}",
        "",
        "## Purpose",
        "",
        "Provide the visual search baseline for impact questions such as: if a source table, view, stored procedure, file, or query changes, which semantic models, notebooks, CopyJobs, DataPipelines, and downstream reports can be affected.",
        "",
        "## Current Summary",
        "",
        f"- Source objects searchable: {summary['source_objects']}.",
        f"- Direct impact rows: {summary['direct_impact_rows']}.",
        f"- Direct impacted items: {summary['impacted_direct_items']}.",
        f"- Downstream reports attached from semantic models: {summary['downstream_reports']}.",
        f"- Exact object-type objects: {summary['exact_object_type_objects']}.",
        f"- Objects still carrying ambiguous type values: {summary['unresolved_objects']}.",
        f"- SQL endpoint catalog objects included: {summary['catalog_objects']}.",
        f"- Catalog-only objects without detected direct impact yet: {summary['catalog_only_objects']}.",
        "",
        "## Outputs",
        "",
        "- `frontend/semantic-lineage/data/object-impact.json`",
        "- `analysis/object_impact_index.csv`",
        "- `analysis/object_impact_summary.csv`",
        "- `analysis/sql_endpoint_object_catalog.csv`",
        "",
        "## Safety",
        "",
        "This package is local-only. It reads generated lineage artifacts and does not query or modify Fabric.",
    ]
    ensure_parent(args.output_doc_path)
    Path(args.output_doc_path).write_text("\n".join(doc_lines) + "\n", encoding="utf-8")

    print("Reverse impact package built.")
    print(f"Source objects: {summary['source_objects']}")
    print(f"Direct impact rows: {summary['direct_impact_rows']}")
    print(f"Downstream reports: {summary['downstream_reports']}")
    print(f"Output: {args.output_json_path}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 - top-level: report cleanly instead of a raw traceback
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
