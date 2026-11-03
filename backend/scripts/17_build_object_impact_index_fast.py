#!/usr/bin/env python3
import argparse
import csv
import json
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path



REPO_ROOT = Path(__file__).resolve().parent.parent.parent  # D.0: anchor default paths to the repo, not $PWD

EXACT_TYPES = {"table", "view", "stored_procedure", "file", "shortcut", "query"}
# Fallback only, for a lineage-explorer.json built before "modes" existed as
# a top-level field -- the real coverage source is payload["modes"] (see
# main()), which lists every real Fabric item type actually present in the
# tenant (Report, Lakehouse, PaginatedReport, ... 21 as of 2026-07-11), not
# just these original 5. Iterating only this fixed tuple silently skipped
# every item of any other type from the whole object-impact index -- found
# live 2026-07-11 while investigating an unrelated file-size issue in the
# same pipeline.
MODES = ("semantic", "notebooks", "copyjobs", "pipelines", "dataflows")


def normalize_key(value):
    if value is None:
        return ""
    return re.sub(r"\s+", " ", str(value).strip().lower())


def normalize_object_type(value):
    clean = re.sub(r"[\s-]+", "_", normalize_key(value))
    aliases = {
        "storedprocedure": "stored_procedure",
        "procedure": "stored_procedure",
        "proc": "stored_procedure",
        "sp": "stored_procedure",
        "tbl": "table",
    }
    return aliases.get(clean, clean)


def exact_object_type(value):
    return normalize_object_type(value) in EXACT_TYPES


def text(value):
    if value is None:
        return ""
    return str(value)


def object_key(source_type, server, database, schema, object_name):
    return "|".join(normalize_key(v) for v in (source_type, server, database, schema, object_name))


def resolution_key(source_type, server, database, schema, object_name):
    type_part = normalize_key(source_type) if source_type else "*"
    return "|".join(
        (
            type_part,
            normalize_key(server),
            normalize_key(database),
            normalize_key(schema),
            normalize_key(object_name),
        )
    )


def ensure_parent(path):
    parent = Path(path).parent
    if str(parent):
        parent.mkdir(parents=True, exist_ok=True)


def read_csv(path):
    if not Path(path).exists():
        return []
    with open(path, newline="", encoding="utf-8-sig") as handle:
        return list(csv.DictReader(handle))


def write_csv(path, rows, columns):
    ensure_parent(path)
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow({column: row.get(column, "") for column in columns})


def build_resolution_index(path):
    index = {}
    for row in read_csv(path):
        if normalize_key(row.get("status")) != "resolved":
            continue
        resolved_type = normalize_object_type(row.get("resolved_object_type"))
        if not exact_object_type(resolved_type):
            continue
        resolution = {
            "object_type": resolved_type,
            "object_type_source": text(row.get("resolver_source")),
            "object_type_confidence": text(row.get("resolver_confidence")),
            "evidence": text(row.get("resolver_evidence")),
        }
        keys = {
            resolution_key(
                row.get("source_type"),
                row.get("source_server"),
                row.get("source_database"),
                row.get("schema_name"),
                row.get("object_name"),
            ),
            resolution_key(
                "",
                row.get("source_server"),
                row.get("source_database"),
                row.get("schema_name"),
                row.get("object_name"),
            ),
        }
        for key in keys:
            if key and key not in index:
                index[key] = resolution
    return index


def get_resolution(index, source_type, server, database, schema, object_name):
    for key in (
        resolution_key(source_type, server, database, schema, object_name),
        resolution_key("", server, database, schema, object_name),
    ):
        if key in index:
            return index[key]
    return None


def gap_reason(item_type, source_count, object_count):
    if object_count > 0:
        return "object_level_present"
    if item_type == "Notebook":
        return "notebook_definition_extraction_required"
    if item_type == "CopyJob":
        return "copyjob_mapping_extraction_required"
    if item_type == "SemanticModel" and source_count > 0:
        return "tmdl_object_extraction_required_or_incomplete"
    if item_type == "SemanticModel":
        return "semantic_model_source_dependency_missing"
    if source_count > 0:
        return "source_known_object_missing"
    return "source_dependency_missing"


def next_action(reason):
    return {
        "object_level_present": "Ready for reverse impact search with current evidence.",
        "notebook_definition_extraction_required": "Read notebook definition/code and parse lakehouse, Spark SQL, JDBC/ODBC, table, view, stored procedure, path, and notebook-call references.",
        "copyjob_mapping_extraction_required": "Read CopyJob definition/source-destination mappings and extract source and target tables, views, stored procedures, files, or folders.",
        "tmdl_object_extraction_required_or_incomplete": "Read or re-read semantic model TMDL/Power Query and extract every Schema/Item/native query object reference.",
        "semantic_model_source_dependency_missing": "Read semantic model connections and TMDL to identify source systems before object extraction.",
        "source_known_object_missing": "Inspect item definition or owner evidence to attach object-level references to the known source.",
    }.get(reason, "Discover item dependencies first, then extract object-level lineage.")


def unique_sorted(values):
    return sorted({text(v) for v in values if text(v)})


# Everything above builds impact_rows purely from what an already-scanned
# item's own parsed code/definition references -- an object with zero
# detected consumers (e.g. a real table nobody's scanned notebook/model
# happens to read yet) never gets a row, so it's invisible to a name search
# even though it genuinely exists (e.g. a SQL Server view confirmed to
# exist via a direct SQL connection but read by nothing scanned yet would
# be completely absent here). These two catalogs are existence-driven
# instead (every real table/view/procedure a scan actually found, regardless
# of whether anything reads it) -- seed summary-only entries (0 affected
# items) for any catalog object that impact_rows didn't already surface, so
# a name search can still find it.
def seed_catalog_only_summary_rows(by_object, deep_catalog_path, sql_endpoint_catalog_path):
    seeded = []

    for row in read_csv(deep_catalog_path):
        server = text(row.get("source_server"))
        database = text(row.get("database_name"))
        schema = text(row.get("schema_name"))
        object_name = text(row.get("object_name"))
        if not object_name:
            continue
        key = object_key("SQL", server, database, schema, object_name)
        if key in by_object:
            continue
        object_type = normalize_object_type(row.get("object_type"))
        display_tail = f"{schema}.{object_name}" if schema else object_name
        seeded.append(
            {
                "object_key": key,
                "object_display_name": " / ".join(v for v in (database, display_tail) if v),
                "source_type": "SQL",
                "source_server": server,
                "source_database": database,
                "schema_name": schema,
                "object_name": object_name,
                "object_type_values": object_type,
                "object_type_sources": "sql_server_deep_catalog",
                "affected_item_count": 0,
                "semantic_model_count": 0,
                "notebook_count": 0,
                "copyjob_count": 0,
                "pipeline_count": 0,
                "dataflow_count": 0,
                "affected_item_types": "",
                "affected_items_sample": "",
            }
        )
        by_object[key] = True

    for row in read_csv(sql_endpoint_catalog_path):
        object_name = text(row.get("object_name"))
        if not object_name:
            continue
        server = text(row.get("source_server")) or text(row.get("sql_endpoint_name"))
        database = text(row.get("source_database"))
        schema = text(row.get("schema_name"))
        source_type = text(row.get("source_type")) or "Lakehouse"
        key = object_key(source_type, server, database, schema, object_name)
        if key in by_object:
            continue
        display_tail = f"{schema}.{object_name}" if schema else object_name
        seeded.append(
            {
                "object_key": key,
                "object_display_name": text(row.get("object_display_name")) or " / ".join(v for v in (database, display_tail) if v),
                "source_type": source_type,
                "source_server": server,
                "source_database": database,
                "schema_name": schema,
                "object_name": object_name,
                "object_type_values": normalize_object_type(row.get("object_type")),
                "object_type_sources": "sql_endpoint_object_catalog",
                "affected_item_count": 0,
                "semantic_model_count": 0,
                "notebook_count": 0,
                "copyjob_count": 0,
                "pipeline_count": 0,
                "dataflow_count": 0,
                "affected_item_types": "",
                "affected_items_sample": "",
            }
        )
        by_object[key] = True

    return seeded


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--explorer-data-path", required=True)
    parser.add_argument("--object-type-resolution-queue-path", required=True)
    parser.add_argument("--output-impact-path", required=True)
    parser.add_argument("--output-impact-summary-path", required=True)
    parser.add_argument("--output-coverage-path", required=True)
    parser.add_argument("--output-coverage-summary-path", required=True)
    parser.add_argument("--output-doc-path", required=True)
    parser.add_argument("--pipeline-object-lineage-candidates-path", default=str(REPO_ROOT / "analysis/pipeline_object_lineage_candidates.csv"))
    parser.add_argument("--sql-server-deep-catalog-path", default=str(REPO_ROOT / "analysis/sql_server_deep_catalog_objects.csv"))
    parser.add_argument("--sql-endpoint-catalog-path", default=str(REPO_ROOT / "analysis/sql_endpoint_object_catalog.csv"))
    args = parser.parse_args()

    with open(args.explorer_data_path, encoding="utf-8-sig") as handle:
        payload = json.load(handle)

    modes = payload.get("modes") or MODES

    resolution_index = build_resolution_index(args.object_type_resolution_queue_path)
    impact_rows = []
    coverage_rows = []

    for workspace in payload.get("workspaces", []) or []:
        workspace_name = text(workspace.get("name"))
        workspace_environment = text(workspace.get("environment"))
        for mode in modes:
            for item in workspace.get(mode, []) or []:
                if not item:
                    continue
                sources = item.get("sources", []) or []
                object_count = 0
                exact_count = 0
                item_type = text(item.get("item_type"))
                item_name = text(item.get("label"))
                item_qualified_name = text(item.get("qualified_name"))

                for source in sources:
                    source_server = text(source.get("server"))
                    source_database = text(source.get("database"))
                    source_type = text(source.get("source_type"))
                    for obj in source.get("objects", []) or []:
                        if not obj:
                            continue
                        schema = text(obj.get("schema"))
                        object_name = text(obj.get("object_name"))
                        server = text(obj.get("server")) or source_server
                        database = text(obj.get("database")) or source_database
                        obj_source_type = text(obj.get("source_type")) or source_type
                        original_object_type = text(obj.get("type"))
                        raw_object_type = text(obj.get("raw_object_type"))
                        object_type = original_object_type
                        object_type_source = text(obj.get("object_type_source"))
                        object_type_confidence = text(obj.get("object_type_confidence"))
                        resolution = get_resolution(
                            resolution_index,
                            obj_source_type,
                            server,
                            database,
                            schema,
                            object_name,
                        )
                        if resolution:
                            object_type = resolution["object_type"]
                            if not raw_object_type:
                                raw_object_type = original_object_type
                            object_type_source = resolution["object_type_source"]
                            object_type_confidence = resolution["object_type_confidence"]

                        evidence = text(obj.get("evidence"))
                        if resolution and resolution.get("evidence"):
                            evidence = re.sub(
                                r"\s+",
                                " ",
                                f"{evidence} Exact object type resolved from {resolution['object_type_source']}: {resolution['evidence']}",
                            ).strip()

                        display_tail = f"{schema}.{object_name}" if schema else object_name
                        display_parts = [v for v in (database, display_tail) if v]
                        impact_rows.append(
                            {
                                "object_key": object_key(obj_source_type, server, database, schema, object_name),
                                "object_display_name": " / ".join(display_parts[:2]),
                                "source_type": obj_source_type,
                                "source_server": server,
                                "source_database": database,
                                "schema_name": schema,
                                "object_name": object_name,
                                "object_type": object_type,
                                "raw_object_type": raw_object_type,
                                "object_type_source": object_type_source,
                                "object_type_confidence": object_type_confidence,
                                "item_workspace_name": workspace_name,
                                "item_type": item_type,
                                "item_name": item_name,
                                "item_qualified_name": item_qualified_name,
                                "mode": mode,
                                "source_label": text(source.get("label")),
                                "source_qualified_name": text(source.get("qualified_name")),
                                "semantic_table": text(obj.get("semantic_table")),
                                "usage_type": text(obj.get("usage_type")),
                                "confidence": text(obj.get("confidence")),
                                "evidence": evidence,
                            }
                        )
                        object_count += 1
                        if exact_object_type(object_type):
                            exact_count += 1

                reason = gap_reason(item_type, len(sources), object_count)
                coverage_rows.append(
                    {
                        "workspace_name": workspace_name,
                        "workspace_environment": workspace_environment,
                        "item_type": item_type,
                        "item_name": item_name,
                        "item_qualified_name": item_qualified_name,
                        "source_count": len(sources),
                        "object_count": object_count,
                        "exact_object_count": exact_count,
                        "ambiguous_object_count": object_count - exact_count,
                        "coverage_status": "object_level_present" if object_count > 0 else ("source_only" if sources else "no_source"),
                        "gap_reason": reason,
                        "next_action": next_action(reason),
                    }
                )

    for pipeline_row in read_csv(args.pipeline_object_lineage_candidates_path):
        object_name = text(pipeline_row.get("object_name"))
        item_qualified_name = text(pipeline_row.get("item_qualified_name"))
        if not object_name or not item_qualified_name:
            continue

        source_type = text(pipeline_row.get("source_type")) or "FabricOrSQL"
        server = text(pipeline_row.get("source_server"))
        database = text(pipeline_row.get("source_database"))
        schema = text(pipeline_row.get("schema_name"))
        original_object_type = text(pipeline_row.get("object_type")) or "table_or_view"
        object_type = original_object_type
        object_type_source = ""
        object_type_confidence = ""
        resolution = get_resolution(resolution_index, source_type, server, database, schema, object_name)
        if resolution:
            object_type = resolution["object_type"]
            object_type_source = resolution["object_type_source"]
            object_type_confidence = resolution["object_type_confidence"]

        evidence = text(pipeline_row.get("evidence"))
        if resolution and resolution.get("evidence"):
            evidence = re.sub(
                r"\s+",
                " ",
                f"{evidence} Exact object type resolved from {resolution['object_type_source']}: {resolution['evidence']}",
            ).strip()

        display_tail = f"{schema}.{object_name}" if schema else object_name
        display_parts = [v for v in (database, display_tail) if v]
        impact_rows.append(
            {
                "object_key": object_key(source_type, server, database, schema, object_name),
                "object_display_name": " / ".join(display_parts[:2]),
                "source_type": source_type,
                "source_server": server,
                "source_database": database,
                "schema_name": schema,
                "object_name": object_name,
                "object_type": object_type,
                "raw_object_type": original_object_type,
                "object_type_source": object_type_source,
                "object_type_confidence": object_type_confidence,
                "item_workspace_name": text(pipeline_row.get("workspace_name")),
                "item_type": "DataPipeline",
                "item_name": text(pipeline_row.get("item_name")),
                "item_qualified_name": item_qualified_name,
                "mode": "pipelines",
                "source_label": text(pipeline_row.get("source_name")),
                "source_qualified_name": text(pipeline_row.get("source_qualified_name")),
                "semantic_table": "",
                "usage_type": text(pipeline_row.get("usage_type")),
                "confidence": text(pipeline_row.get("confidence")),
                "evidence": evidence,
            }
        )

    seen_impact_rows = set()
    deduped_impact_rows = []
    for row in impact_rows:
        key = tuple((name, row.get(name, "")) for name in sorted(row.keys()))
        if key in seen_impact_rows:
            continue
        seen_impact_rows.add(key)
        deduped_impact_rows.append(row)
    impact_rows = deduped_impact_rows

    impact_summary = []
    by_object = defaultdict(list)
    for row in impact_rows:
        by_object[row["object_key"]].append(row)
    for rows in by_object.values():
        first = rows[0]
        affected_items = unique_sorted(row.get("item_qualified_name") for row in rows)
        item_types = unique_sorted(row.get("item_type") for row in rows)
        impact_summary.append(
            {
                "object_key": first["object_key"],
                "object_display_name": first["object_display_name"],
                "source_type": first["source_type"],
                "source_server": first["source_server"],
                "source_database": first["source_database"],
                "schema_name": first["schema_name"],
                "object_name": first["object_name"],
                "object_type_values": "; ".join(unique_sorted(row.get("object_type") for row in rows)),
                "object_type_sources": "; ".join(unique_sorted(row.get("object_type_source") for row in rows)),
                "affected_item_count": len(affected_items),
                "semantic_model_count": len({row["item_qualified_name"] for row in rows if row.get("item_type") == "SemanticModel" and row.get("item_qualified_name")}),
                "notebook_count": len({row["item_qualified_name"] for row in rows if row.get("item_type") == "Notebook" and row.get("item_qualified_name")}),
                "copyjob_count": len({row["item_qualified_name"] for row in rows if row.get("item_type") == "CopyJob" and row.get("item_qualified_name")}),
                "pipeline_count": len({row["item_qualified_name"] for row in rows if row.get("item_type") == "DataPipeline" and row.get("item_qualified_name")}),
                "dataflow_count": len({row["item_qualified_name"] for row in rows if row.get("item_type") == "Dataflow" and row.get("item_qualified_name")}),
                "affected_item_types": "; ".join(item_types),
                "affected_items_sample": "; ".join(affected_items[:12]),
            }
        )

    catalog_only_rows = seed_catalog_only_summary_rows(by_object, args.sql_server_deep_catalog_path, args.sql_endpoint_catalog_path)
    impact_summary.extend(catalog_only_rows)

    coverage_summary = []
    by_item_type = defaultdict(list)
    for row in coverage_rows:
        by_item_type[row["item_type"]].append(row)
    for item_type, rows in by_item_type.items():
        coverage_summary.append(
            {
                "item_type": item_type,
                "item_count": len(rows),
                "with_sources": sum(int(row["source_count"]) > 0 for row in rows),
                "with_object_level_lineage": sum(int(row["object_count"]) > 0 for row in rows),
                "without_object_level_lineage": sum(int(row["object_count"]) == 0 for row in rows),
                "object_references": sum(int(row["object_count"]) for row in rows),
                "exact_object_references": sum(int(row["exact_object_count"]) for row in rows),
                "ambiguous_object_references": sum(int(row["ambiguous_object_count"]) for row in rows),
            }
        )

    impact_columns = [
        "object_key",
        "object_display_name",
        "source_type",
        "source_server",
        "source_database",
        "schema_name",
        "object_name",
        "object_type",
        "raw_object_type",
        "object_type_source",
        "object_type_confidence",
        "item_workspace_name",
        "item_type",
        "item_name",
        "item_qualified_name",
        "mode",
        "source_label",
        "source_qualified_name",
        "semantic_table",
        "usage_type",
        "confidence",
        "evidence",
    ]
    impact_summary_columns = [
        "object_key",
        "object_display_name",
        "source_type",
        "source_server",
        "source_database",
        "schema_name",
        "object_name",
        "object_type_values",
        "object_type_sources",
        "affected_item_count",
        "semantic_model_count",
        "notebook_count",
        "copyjob_count",
        "pipeline_count",
        "dataflow_count",
        "affected_item_types",
        "affected_items_sample",
    ]
    coverage_columns = [
        "workspace_name",
        "workspace_environment",
        "item_type",
        "item_name",
        "item_qualified_name",
        "source_count",
        "object_count",
        "exact_object_count",
        "ambiguous_object_count",
        "coverage_status",
        "gap_reason",
        "next_action",
    ]
    coverage_summary_columns = [
        "item_type",
        "item_count",
        "with_sources",
        "with_object_level_lineage",
        "without_object_level_lineage",
        "object_references",
        "exact_object_references",
        "ambiguous_object_references",
    ]

    impact_rows.sort(key=lambda r: (r["source_type"], r["source_server"], r["source_database"], r["schema_name"], r["object_name"], r["item_type"], r["item_name"]))
    impact_summary.sort(key=lambda r: (-int(r["affected_item_count"]), r["source_database"], r["schema_name"], r["object_name"]))
    coverage_rows.sort(key=lambda r: (r["item_type"], r["workspace_name"], r["item_name"]))
    coverage_summary.sort(key=lambda r: r["item_type"])

    write_csv(args.output_impact_path, impact_rows, impact_columns)
    write_csv(args.output_impact_summary_path, impact_summary, impact_summary_columns)
    write_csv(args.output_coverage_path, coverage_rows, coverage_columns)
    write_csv(args.output_coverage_summary_path, coverage_summary, coverage_summary_columns)

    total_items = len(coverage_rows)
    with_object_level = sum(int(row["object_count"]) > 0 for row in coverage_rows)
    exact_refs = sum(1 for row in impact_rows if exact_object_type(row.get("object_type")))
    generated_at = datetime.now().replace(microsecond=0).isoformat()
    ensure_parent(args.output_doc_path)
    doc_lines = [
        "# Object-Level Lineage And Reverse Impact",
        "",
        f"Generated at: {generated_at}",
        "",
        "## Purpose",
        "",
        "Provide the local index needed to answer reverse-impact questions such as: if a SQL/Fabric table, view, stored procedure, file, or query changes, which semantic models, notebooks, CopyJobs, pipelines, and reports can be affected.",
        "",
        "## Current Coverage",
        "",
        f"- Items inspected in the explorer payload: {total_items}.",
        f"- Items with object-level lineage today: {with_object_level}.",
        f"- Items without object-level lineage today: {total_items - with_object_level}.",
        f"- Unique source objects currently indexed: {len(impact_summary)}.",
        f"- Object references currently indexed: {len(impact_rows)}.",
        f"- Exact table/view/stored-procedure/file/query references: {exact_refs}.",
        f"- Catalog-only objects (real, confirmed to exist via a deep SQL/SQL-endpoint catalog scan, but with zero detected consumers today): {len(catalog_only_rows)}.",
        "",
        "## Coverage By Item Type",
        "",
        "| Item type | Items | With sources | With objects | Without objects | Object refs | Exact refs | Ambiguous refs |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for row in coverage_summary:
        doc_lines.append(
            f"| {row['item_type']} | {row['item_count']} | {row['with_sources']} | {row['with_object_level_lineage']} | {row['without_object_level_lineage']} | {row['object_references']} | {row['exact_object_references']} | {row['ambiguous_object_references']} |"
        )
    doc_lines.extend(
        [
            "",
            "## Outputs",
            "",
            f"- {args.output_impact_path}: one row per object-to-item impact edge.",
            f"- {args.output_impact_summary_path}: one row per source object with affected item counts and samples.",
            f"- {args.output_coverage_path}: one row per item showing whether object-level lineage is present.",
            f"- {args.output_coverage_summary_path}: item-type coverage totals.",
            "",
            "## Remaining Gaps",
            "",
            "1. Semantic models: TMDL extraction is complete for all accessible models. Remaining missing rows are models whose definition export is denied or items with source-only evidence.",
            "2. Notebooks: read-only definition extraction is complete for accessible notebook definitions. Remaining gaps are notebooks with no parseable object candidates or definition conversion/access failures.",
            "3. CopyJobs: read-only definition extraction is complete for accessible CopyJob definitions. Remaining gaps are CopyJobs with no parseable object candidates.",
            "4. DataPipelines: pipeline object-level source/write lineage still needs a later focused extraction from pipeline activities and nested item calls.",
            "5. Exact object types: resolve table_or_view and native_query_object rows through SQL/Fabric metadata or owner evidence, then record approved types in index/source_object_type_overrides.csv.",
            "",
            "## Safety",
            "",
            "This script is local-only. It reads the generated explorer JSON and writes CSV/documentation outputs. It does not query or modify Fabric.",
        ]
    )
    Path(args.output_doc_path).write_text("\n".join(doc_lines) + "\n", encoding="utf-8")

    print("Object impact index built.")
    print(f"Unique objects: {len(impact_summary)} ({len(catalog_only_rows)} catalog-only, 0 known consumers)")
    print(f"Object impact rows: {len(impact_rows)}")
    print(f"Items with object-level lineage: {with_object_level} / {total_items}")
    print(f"Output: {args.output_impact_path}")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 - top-level: report cleanly instead of a raw traceback
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
