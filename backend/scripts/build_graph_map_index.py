#!/usr/bin/env python3
"""Build the unified nodes+edges index for Graph Map Mode (Fase G.1).

Combines the item-level catalog (index/items.csv, index/workspaces.csv,
index/dependencies.csv) with the object-level impact index
(frontend/semantic-lineage/data/object-impact.json) into one lightweight,
Cytoscape-ready graph: every workspace, every Fabric item (every item
type the scan found), and every source object (table/view/stored
procedure/file/etc.) as nodes; every dependency, usage, and
object-to-report path as edges. Deliberately does NOT duplicate the heavy
per-row text (evidence strings, execution schedules, column lists) that
lineage-explorer.json/object-impact.json already carry -- Graph Map Mode
only needs enough per-node/edge detail to render and navigate; the
existing detail panel's data source stays the source of truth for
everything else.

Every relationship_type/usage_type value is labelled in both Spanish and
English via RELATIONSHIP_LABELS below. That dict is seeded from the values
the scanners emit today plus the broader vocabulary requested for Graph Map Mode (triggers,
transforms, loads_into, feeds, uses, publishes_to) so it doesn't need
editing again the day one of those first appears in real data -- anything
still unmapped falls back to "unknown relation" rather than failing.

Usage: python3 backend/scripts/build_graph_map_index.py
Writes: frontend/semantic-lineage/data/graph-map-index.json
"""

from __future__ import annotations

import csv
import json
import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# Same directory-on-sys.path trick mcp_server.py already relies on to reach
# into the lineage_web package from a standalone script run directly
# (`python3 backend/scripts/build_graph_map_index.py`) -- Python prepends
# the script's own directory to sys.path[0] automatically.
from lineage_web.admin_settings import _load_admin_settings
from lineage_web.sensitivity_classifier import classify_columns

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
INDEX_DIR = REPO_ROOT / "index"
ANALYSIS_DIR = REPO_ROOT / "analysis"
DATA_DIR = REPO_ROOT / "frontend" / "semantic-lineage" / "data"
# Split in two so Graph Map Mode's default view (item level) is a small,
# fast fetch -- the object level (tables/views/columns, once every source
# object is included) is an order of magnitude bigger and only needed when a user actually expands into "focused graph" detail
# for one specific node (G.8), not on every page load.
ITEM_OUTPUT_PATH = DATA_DIR / "graph-map-index.json"
OBJECT_OUTPUT_PATH = DATA_DIR / "graph-map-index-objects.json"

# item_type -> layer, for the color-by-layer legend Graph Map Mode's visual
# polish (G.9) will use. Lakehouse/Warehouse are split further by name
# (bronze/silver/gold) below, matching the same heuristic already used in
# backend/scripts/52_build_notebook_super_lineage.py's lakehouse_tier().
ITEM_TYPE_LAYER = {
    "SemanticModel": "semantic",
    "Report": "reporting",
    "PaginatedReport": "reporting",
    "Exploration": "reporting",
    "Dashboard": "reporting",
    "SQLEndpoint": "storage",
    "Lakehouse": "storage",
    "Warehouse": "storage",
    "SQLDatabase": "storage",
    "VariableLibrary": "orchestration",
    "Environment": "orchestration",
    "DataPipeline": "orchestration",
    "CopyJob": "orchestration",
    "Dataflow": "orchestration",
    "Notebook": "orchestration",
    "Eventstream": "orchestration",
    "KQLQueryset": "orchestration",
    "KQLDashboard": "reporting",
    "Reflex": "orchestration",
    "GraphQLApi": "orchestration",
    "UserDataFunction": "orchestration",
    "DataAgent": "orchestration",
}

# object-impact.json's source_type -> layer, for object-level nodes.
SOURCE_TYPE_LAYER = {
    "SQL": "external",
    "ExternalAPI": "external",
    "File": "external",
    "NotebookStaticData": "external",
    "Fabric": "storage",
    "FabricOrSQL": "storage",
    "Lakehouse": "storage",
    "LakehouseTable": "storage",
}

RELATIONSHIP_LABELS: dict[str, dict[str, str]] = {
    "reads_from": {"es": "Lee de", "en": "Reads from"},
    "writes_to": {"es": "Escribe en", "en": "Writes to"},
    "depends_on": {"es": "Depende de", "en": "Depends on"},
    "triggers": {"es": "Dispara", "en": "Triggers"},
    "executes": {"es": "Ejecuta", "en": "Executes"},
    "transforms": {"es": "Transforma", "en": "Transforms"},
    "loads_into": {"es": "Carga en", "en": "Loads into"},
    "feeds": {"es": "Alimenta a", "en": "Feeds"},
    "uses": {"es": "Usa", "en": "Uses"},
    "uses_connection": {"es": "Usa la conexión", "en": "Uses connection"},
    "publishes_to": {"es": "Publica en", "en": "Publishes to"},
    "refreshes": {"es": "Actualiza", "en": "Refreshes"},
    "serves_report": {"es": "Sirve al informe", "en": "Serves report"},
    "uses_model": {"es": "Usa el modelo", "en": "Uses model"},
    # H.6 (2026-07-08 revision pass): an item that reads/writes a table
    # living in a Lakehouse/Warehouse doesn't always get a captured direct
    # Fabric dependency row for that specific relationship (e.g. it goes
    # through a SQL analytics endpoint the item->item dependency crawl
    # doesn't see) -- this label marks edges *derived* from object-impact.json
    # object usage instead, so real depth (an item in one workspace pulling
    # from a table that lives in another) isn't lost just because no
    # explicit Fabric-level dependency row exists for it.
    "implied_data_usage": {"es": "Usa datos de (inferido)", "en": "Uses data from (inferred)"},
    "unknown": {"es": "Relación desconocida", "en": "Unknown relation"},
    # G/portal-1 (2026-07-09): one edge per (external origin, consuming item)
    # pair -- see build_external_origin_graph.
    "external_feed": {"es": "Alimenta desde el exterior", "en": "Feeds from external source"},
}

# Fabric-native storage/meta connectors that can show up as a source_type
# but are NOT truly external -- OneLake-backed storage under a different
# name, or Fabric's own internal telemetry/metadata surfaces.
FABRIC_INTERNAL_SOURCE_TYPES = {
    "Fabric",
    "FabricOrSQL",
    "Lakehouse",
    "LakehouseTable",
    "FabricDataPipelines",
    "FabricSqlEndpointMetadata",
    "CapacityMetricsCES",
    "UsageMetricsDataConnector",
}

# G/portal-1 originally hardcoded a 4-value whitelist (SQL/ExternalAPI/
# File/NotebookStaticData) -- real-world data has dozens of distinct
# source_type values (e.g. Dataverse shows up as "Cds"/"CommonDataService",
# never in that list, so reports reading from it rendered with no origin
# at all, as isolated "satellites"). Generalized rule: anything that
# isn't a Fabric-hosted storage/meta connector above, OR a reference to
# ANOTHER Fabric item (ITEM_TYPE_LAYER's keys -- e.g. a report whose
# source_type is "SemanticModel" already gets a normal item-to-item
# dependency edge elsewhere and must not ALSO become a portal node), is a
# real external origin: SharePoint, Dataverse, Amazon S3/Redshift, generic
# OData/ODBC/Web connectors, SQL Server, plain files, notebook-embedded
# static data, or whatever the tenant's data sources grow to include next
# -- no new code needed here when one does, unlike the old whitelist.
def is_external_origin_source_type(source_type: str) -> bool:
    return bool(source_type) and source_type not in FABRIC_INTERNAL_SOURCE_TYPES and source_type not in ITEM_TYPE_LAYER

# H.4: node size (px) reflects real magnitude, not a flat 22px for
# everything -- workspace > lakehouse/warehouse/SQLEndpoint (sized by how
# many source objects they actually contain) > every other item (fixed) >
# a source object/table (sized a little by column count). Ranges are
# deliberately non-overlapping between tiers so the ordering always reads
# correctly regardless of any one tenant's real counts, while still
# scaling *within* a tier by the real number.
ITEM_NODE_SIZE = 14.0
_STORAGE_SIZE_RANGE = (18.0, 40.0)
_WORKSPACE_SIZE_RANGE = (44.0, 90.0)
_OBJECT_SIZE_RANGE = (7.0, 12.0)


def _clamp(value: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, value))


def workspace_node_size(item_count: int) -> float:
    lo, hi = _WORKSPACE_SIZE_RANGE
    return round(_clamp(lo + 3.5 * math.sqrt(max(item_count, 0)), lo, hi), 1)


def storage_node_size(table_count: int) -> float:
    lo, hi = _STORAGE_SIZE_RANGE
    return round(_clamp(lo + 3.2 * math.sqrt(max(table_count, 0)), lo, hi), 1)


def object_node_size(column_count: int) -> float:
    lo, hi = _OBJECT_SIZE_RANGE
    return round(_clamp(lo + 0.6 * math.sqrt(max(column_count, 0)), lo, hi), 1)


def relationship_label(relationship_type: str) -> dict[str, str]:
    key = (relationship_type or "").strip() or "unknown"
    return RELATIONSHIP_LABELS.get(key, RELATIONSHIP_LABELS["unknown"])


def lakehouse_tier(item_name: str) -> str:
    lower = (item_name or "").casefold()
    for tier in ("bronze", "silver", "gold"):
        if tier in lower:
            return tier
    return ""


def read_csv(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def read_json(path: Path) -> Any:
    if not path.exists():
        return None
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def item_layer(item_type: str, item_name: str) -> str:
    if item_type in ("Lakehouse", "Warehouse"):
        tier = lakehouse_tier(item_name)
        if tier:
            return tier
    return ITEM_TYPE_LAYER.get(item_type, "orchestration")


def build_workspace_nodes(
    workspace_rows: list[dict[str, str]], item_counts_by_workspace: dict[str, int]
) -> tuple[list[dict[str, Any]], set[str], dict[str, str]]:
    nodes = []
    known_ids: set[str] = set()
    workspace_technical_id_by_name: dict[str, str] = {}
    for row in workspace_rows:
        name = row.get("workspace_name", "")
        if not name:
            continue
        workspace_id = "workspace::" + name
        technical_id = row.get("technical_id", "")
        item_count = item_counts_by_workspace.get(name, 0)
        nodes.append(
            {
                "data": {
                    "id": workspace_id,
                    "label": name,
                    "node_type": "Workspace",
                    "layer": "workspace",
                    "workspace_name": name,
                    "environment": row.get("environment", ""),
                    "capacity_name": row.get("capacity_name", ""),
                    "technical_id": technical_id,
                    "item_count": item_count,
                    "size": workspace_node_size(item_count),
                }
            }
        )
        known_ids.add(workspace_id)
        if technical_id:
            workspace_technical_id_by_name[name] = technical_id
    return nodes, known_ids, workspace_technical_id_by_name


# Purview-inspired "health/freshness" signal (Tanda A, 2026-07-09): a real
# item is worth flagging in the graph itself if its last run failed, or if
# it simply hasn't run in a long time -- both already computable from data
# 06_discover_executions.ps1/07_optimize_orchestration.ps1 already scan and
# aggregate, just never rendered anywhere before now. 30 days is a
# deliberately simple, single global threshold (not per-job_type/per-
# schedule-frequency) -- good enough to flag "nobody's looked at this in a
# month", not meant to replace analysis/schedule_review_candidates.csv's
# own more precise per-item schedule awareness.
STALE_AFTER_DAYS = 30


def _parse_execution_timestamp(value: str) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.strptime(value, "%m/%d/%Y %H:%M:%S")
    except ValueError:
        return None


def build_execution_health_index(execution_rows: list[dict[str, str]]) -> dict[str, dict[str, Any]]:
    """One entry per item qualified_name, aggregated across every job_type
    that item has (a SemanticModel's refresh and, say, a linked pipeline's
    own run history both count as "this item's executions" for a single
    health signal) -- total run/failed counts, plus the single most recent
    run's own status. The per-job_type breakdown stays in
    analysis/execution_duration_by_item.csv itself (MCP's get_execution_stats
    already exposes that detail; this index is deliberately coarser)."""
    health: dict[str, dict[str, Any]] = {}
    for row in execution_rows:
        qualified_name = row.get("qualified_name", "")
        if not qualified_name:
            continue
        try:
            run_count = int(row.get("run_count") or 0)
        except ValueError:
            run_count = 0
        try:
            failed_count = int(row.get("failed_count") or 0)
        except ValueError:
            failed_count = 0
        latest_start = _parse_execution_timestamp(row.get("latest_start_time", ""))
        entry = health.setdefault(
            qualified_name, {"run_count": 0, "failed_count": 0, "latest_start": None, "last_status": ""}
        )
        entry["run_count"] += run_count
        entry["failed_count"] += failed_count
        if latest_start and (entry["latest_start"] is None or latest_start > entry["latest_start"]):
            entry["latest_start"] = latest_start
            entry["last_status"] = row.get("last_status", "")
    return health


def health_fields_for(qualified_name: str, execution_health: dict[str, dict[str, Any]], now: datetime) -> dict[str, Any]:
    entry = execution_health.get(qualified_name)
    if not entry or not entry["run_count"]:
        return {}
    latest_start = entry["latest_start"]
    # latest_start is naive (job-instance timestamps carry no explicit
    # timezone in the source data) -- compare against a naive "now" too,
    # good enough for a coarse "hasn't run in 30+ days" signal.
    days_since_last_run = (now.replace(tzinfo=None) - latest_start).days if latest_start else None
    return {
        "exec_run_count": entry["run_count"],
        "exec_failed_count": entry["failed_count"],
        "exec_last_status": entry["last_status"],
        "exec_latest_start_time": latest_start.strftime("%Y-%m-%d %H:%M") if latest_start else "",
        "exec_is_stale": bool(days_since_last_run is not None and days_since_last_run > STALE_AFTER_DAYS),
    }


# Tanda C (Purview-inspired, 2026-07-09): config/admin_settings.json's
# certified_items (admin panel's "Certificaciones" tab) -- a human-curated
# "this is the trusted/official source" badge, indexed by qualified_name
# once here rather than scanned per node.
def build_certification_index(certified_items: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    index: dict[str, dict[str, Any]] = {}
    for entry in certified_items:
        qualified_name = entry.get("qualified_name", "")
        if qualified_name:
            index[qualified_name] = entry
    return index


# Roadmap Fase 2 (2026-08-17): admin_settings.json's tags -- same
# admin-curated indexing pattern as build_certification_index just above,
# except a node can have several, so this groups by qualified_name into a
# list instead of keeping the last entry.
def build_tag_index(tags: list[dict[str, Any]]) -> dict[str, list[str]]:
    index: dict[str, list[str]] = {}
    for entry in tags:
        qualified_name = entry.get("qualified_name", "")
        tag = (entry.get("tag") or "").strip()
        if not qualified_name or not tag:
            continue
        bucket = index.setdefault(qualified_name, [])
        if tag not in bucket:
            bucket.append(tag)
    return index


def build_item_nodes(
    item_rows: list[dict[str, str]],
    workspace_technical_id_by_name: dict[str, str],
    known_workspace_ids: set[str],
    storage_table_counts: dict[str, int],
    execution_health: dict[str, dict[str, Any]],
    now: datetime,
    certification_index: dict[str, dict[str, Any]],
    tag_index: dict[str, list[str]],
) -> tuple[list[dict[str, Any]], set[str]]:
    # H.5 (2026-07-08 revision pass): re-enabling compound (parent/child)
    # nesting -- items now carry `parent: workspace::<name>`, so Cytoscape
    # visually clusters each workspace's items together, matching the
    # "gravitational" clustering-by-real-hierarchy the map is meant to
    # show. Tried this in G.2 and reverted after cytoscape-dagre threw
    # "Not possible to find intersection inside of the rectangle" on
    # compound nesting -- but that was dagre's fragility specifically,
    # verified since abandoned in favor of `fcose` (G.2) for the very
    # reason that dagre can't handle a real tenant's disconnected-graph
    # shape at all. fcose supports compound graphs natively (part of why
    # it was picked); re-verified live before shipping this.
    nodes = []
    known_ids: set[str] = set()
    for row in item_rows:
        qualified_name = row.get("qualified_name", "")
        if not qualified_name:
            continue
        item_type = row.get("item_type", "")
        item_name = row.get("item_name", "")
        workspace_name = row.get("workspace_name", "")
        workspace_id = "workspace::" + workspace_name if workspace_name else ""
        table_count = storage_table_counts.get(qualified_name, 0)
        node_data = {
            "id": qualified_name,
            "label": item_name,
            "node_type": item_type,
            "layer": item_layer(item_type, item_name),
            "workspace_name": workspace_name,
            "description": row.get("description", ""),
            "default_identity": row.get("default_identity", ""),
            # Both ids together let the client build a real
            # https://app.fabric.microsoft.com/groups/{workspace_id}/items/{item_id}
            # deep link (G.5's "abrir en Fabric" button) -- confirmed in an
            # earlier session that Fabric has no dedicated web-URL field of
            # its own, this generic type-agnostic pattern is what's used.
            "technical_id": row.get("technical_id", ""),
            "workspace_technical_id": workspace_technical_id_by_name.get(workspace_name, ""),
            "table_count": table_count,
            "size": storage_node_size(table_count) if table_count else ITEM_NODE_SIZE,
        }
        node_data.update(health_fields_for(qualified_name, execution_health, now))
        certification = certification_index.get(qualified_name)
        if certification:
            node_data["is_certified"] = True
            node_data["certified_note"] = certification.get("note", "")
            node_data["certified_by"] = certification.get("certified_by", "")
        tags = tag_index.get(qualified_name)
        if tags:
            node_data["tags"] = tags
        if workspace_id in known_workspace_ids:
            node_data["parent"] = workspace_id
        nodes.append({"data": node_data})
        known_ids.add(qualified_name)
    return nodes, known_ids


def build_item_edges(dependency_rows: list[dict[str, str]], known_ids: set[str]) -> list[dict[str, Any]]:
    edges = []
    for index, row in enumerate(dependency_rows):
        source = row.get("from_qualified_name", "")
        target = row.get("to_qualified_name", "")
        # Some dependency rows point at an external/unresolved node that
        # never became a real item (e.g. an unclassified SQL connection
        # string) -- graph edges need both ends to exist, so those get
        # dropped here rather than rendering a dangling arrow. The reverse
        # impact package already carries this detail elsewhere.
        if source not in known_ids or target not in known_ids:
            continue
        relationship_type = row.get("relationship_type", "")
        labels = relationship_label(relationship_type)
        edges.append(
            {
                "data": {
                    "id": "item-edge::%d" % index,
                    "source": source,
                    "target": target,
                    "relationship_type": relationship_type,
                    "label_es": labels["es"],
                    "label_en": labels["en"],
                    "confidence": row.get("confidence", ""),
                }
            }
        )
    return edges


def build_object_graph(
    impact_payload: dict[str, Any] | None, known_item_ids: set[str]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    if not impact_payload:
        return [], []

    nodes = []
    edges = []
    edge_index = 0
    for obj in impact_payload.get("objects", []):
        object_key = obj.get("object_key", "")
        if not object_key:
            continue
        node_id = "object::" + object_key
        source_type = obj.get("source_type", "")
        columns = obj.get("columns", []) or []
        column_count = len(columns)
        # Tanda B (2026-07-09): a simplified, name-pattern-based equivalent
        # of Purview's automatic classifiers -- see sensitivity_classifier.py
        # for the real caveats (name heuristics, not content inspection).
        sensitivity_categories = sorted(classify_columns(c.get("column_name", "") for c in columns))
        nodes.append(
            {
                "data": {
                    "id": node_id,
                    "label": obj.get("object_display_name", ""),
                    "node_type": obj.get("object_type_values", "") or "source_object",
                    "layer": SOURCE_TYPE_LAYER.get(source_type, "external"),
                    "source_type": source_type,
                    "source_server": obj.get("source_server", ""),
                    "source_database": obj.get("source_database", ""),
                    # Set only for the ~11% of objects NB_Build_Object_Impact
                    # already confirmed against the SQL endpoint catalog (exact
                    # database+schema+object_name join, not a hostname guess)
                    # -- most objects here are genuinely external or just not
                    # yet resolved, so an empty value here is expected, not a
                    # bug (see purview_insights._get_sensitivity_overview).
                    "workspace_name": obj.get("catalog_workspace_name", ""),
                    "column_count": column_count,
                    "sensitivity_categories": sensitivity_categories,
                    "size": object_node_size(column_count),
                }
            }
        )

        for item in obj.get("direct_items", []):
            item_id = item.get("qualified_name", "")
            if item_id not in known_item_ids:
                continue
            relationship_type = item.get("usage_type", "") or "unknown"
            labels = relationship_label(relationship_type)
            edges.append(
                {
                    "data": {
                        "id": "object-edge::%d" % edge_index,
                        "source": node_id,
                        "target": item_id,
                        "relationship_type": relationship_type,
                        "label_es": labels["es"],
                        "label_en": labels["en"],
                        "confidence": item.get("confidence", ""),
                    }
                }
            )
            edge_index += 1

        for report in obj.get("downstream_reports", []):
            report_id = report.get("qualified_name", "")
            if report_id not in known_item_ids:
                continue
            labels = relationship_label("publishes_to")
            edges.append(
                {
                    "data": {
                        "id": "object-edge::%d" % edge_index,
                        "source": node_id,
                        "target": report_id,
                        "relationship_type": "publishes_to",
                        "label_es": labels["es"],
                        "label_en": labels["en"],
                        "confidence": report.get("confidence", ""),
                    }
                }
            )
            edge_index += 1

    return nodes, edges


def _slugify(value: str) -> str:
    keep = [c.casefold() if c.isalnum() else "-" for c in value]
    slug = "".join(keep).strip("-")
    while "--" in slug:
        slug = slug.replace("--", "-")
    return slug or "unknown"


def _origin_display_name(source_type: str, server: str, database: str) -> str:
    if server and database:
        return "%s (%s)" % (server, database)
    return server or database or source_type


# G/portal-1 (2026-07-09): "materialize non-Fabric origins as their own
# object" -- requested explicitly so semantic models/notebooks/copyjobs that
# read from a SQL Server outside Fabric, a SharePoint file, or an external
# API render as visibly connected to something, instead of that dependency
# being invisible until someone drills into G.8's per-item object detail.
# Deliberately NOT one node per source object (that's what the much bigger
# object-level graph_map_index-objects.json already is, with tens of
# thousands of direct edges on a large tenant -- too heavy to add to the
# default view) -- one node per real external
# *connection* (grouped by source_type+server+database, casefolded so
# "<SQL-SERVER-HOST>" and "<sql-server-host>" collapse together)
# instead, each with one deduplicated edge to every item that reads/writes/
# executes against it directly. That typically means tens of origins and
# hundreds of (origin, item) edges -- small enough for the
# default item-level graph without repeating the object-level graph's own
# performance problem.
def build_external_origin_graph(
    explorer_payload: dict[str, Any] | None, known_item_ids: set[str]
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    # Reads lineage-explorer.json's own per-item `sources[]` (every item's
    # direct read/write dependencies, already resolved with a real
    # source_type/server/database by 11_build_lineage_explorer_fast.py),
    # NOT object-impact.json. Originally read object-impact.json's
    # `objects` array instead, which only ever covers objects that made it
    # through the SQL-catalog-based object-type resolution pipeline --
    # fine for SQL/File/ExternalAPI/NotebookStaticData (the original
    # 4-type whitelist), but SharePoint, Dataverse ("CommonDataService"/
    # "Cds"), Amazon S3/
    # Redshift, Azure Data Lake Storage, Outlook, OData/ODBC/Web connectors
    # never go through that SQL-table/column cataloging at all, so they
    # never appeared there no matter how is_external_origin_source_type
    # itself was defined (symptom: Dataverse-sourced reports rendered as
    # isolated "satellites" with no origin, unlike SQL-sourced ones).
    if not explorer_payload:
        return [], []

    labels = relationship_label("external_feed")
    origins: dict[str, dict[str, Any]] = {}  # slug -> {source_type, server, database}
    pairs: set[tuple[str, str]] = set()  # (slug, item_id), deduped

    modes = explorer_payload.get("modes") or []
    for workspace in explorer_payload.get("workspaces", []) or []:
        for mode in modes:
            for item in workspace.get(mode) or []:
                if not isinstance(item, dict):
                    continue
                item_id = item.get("qualified_name", "")
                if not item_id or item_id not in known_item_ids:
                    continue
                for source in item.get("sources") or []:
                    source_type = source.get("source_type", "")
                    if not is_external_origin_source_type(source_type):
                        continue
                    server = source.get("server", "") or ""
                    database = source.get("database", "") or ""
                    slug = "origin::" + _slugify(source_type + "-" + server + "-" + database)
                    if slug not in origins:
                        origins[slug] = {
                            "source_type": source_type,
                            "source_server": server,
                            "source_database": database,
                        }
                    pairs.add((slug, item_id))

    nodes = []
    for slug, origin in origins.items():
        nodes.append(
            {
                "data": {
                    "id": slug,
                    "label": _origin_display_name(origin["source_type"], origin["source_server"], origin["source_database"]),
                    "node_type": "ExternalOrigin",
                    "layer": "external",
                    "source_type": origin["source_type"],
                    "source_server": origin["source_server"],
                    "source_database": origin["source_database"],
                    "size": 26.0,
                }
            }
        )

    edges = []
    for index, (slug, item_id) in enumerate(sorted(pairs)):
        edges.append(
            {
                "data": {
                    "id": "origin-edge::%d" % index,
                    "source": slug,
                    "target": item_id,
                    "relationship_type": "external_feed",
                    "label_es": labels["es"],
                    "label_en": labels["en"],
                    "confidence": "",
                }
            }
        )

    return nodes, edges


def compute_workspace_item_counts(item_rows: list[dict[str, str]]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for row in item_rows:
        name = row.get("workspace_name", "")
        if name:
            counts[name] = counts.get(name, 0) + 1
    return counts


def compute_storage_table_counts(impact_payload: dict[str, Any] | None) -> dict[str, int]:
    # H.4: how many source objects (tables/views/SPs) does each
    # Lakehouse/Warehouse/SQLEndpoint really contain -- object-impact.json
    # already resolved this per-object via a live SQL-endpoint catalog
    # query (see build_object_graph's catalog_evidence), grouping by that
    # same qualified name gives a real per-item table count for sizing.
    counts: dict[str, int] = {}
    if not impact_payload:
        return counts
    for obj in impact_payload.get("objects", []):
        owner = obj.get("sql_endpoint_qualified_name", "")
        if owner:
            counts[owner] = counts.get(owner, 0) + 1
    return counts


def build_implied_storage_edges(
    impact_payload: dict[str, Any] | None,
    known_item_ids: set[str],
    existing_pairs: set[tuple[str, str]],
    start_index: int,
) -> list[dict[str, Any]]:
    # H.6: an item reading/writing a table doesn't always have a captured
    # item-to-item Fabric dependency row for the Lakehouse/Warehouse that
    # table actually lives in (e.g. it goes through the SQL analytics
    # endpoint, which the item-dependency crawl doesn't always resolve
    # back to the item using it) -- real cross-workspace depth ("a table
    # in one workspace's lakehouse used by a notebook in another
    # workspace") was otherwise only reachable by drilling into G.8's
    # focused view one item at a time. Adds one edge per (item, owning
    # storage item) pair actually observed in the object catalog, deduped
    # against pairs already covered by a real dependency edge in either
    # direction -- in practice that adds a few hundred edges at most,
    # nowhere near the combinatorial blow-up a naive
    # every-co-user-to-every-co-user approach would risk.
    if not impact_payload:
        return []
    labels = relationship_label("implied_data_usage")
    pairs_seen: set[tuple[str, str]] = set()
    edges = []
    edge_index = start_index
    for obj in impact_payload.get("objects", []):
        owner = obj.get("sql_endpoint_qualified_name", "")
        if not owner or owner not in known_item_ids:
            continue
        consumers = list(obj.get("direct_items", [])) + list(obj.get("downstream_reports", []))
        for entry in consumers:
            item_id = entry.get("qualified_name", "")
            if not item_id or item_id == owner or item_id not in known_item_ids:
                continue
            pair = (item_id, owner)
            if pair in pairs_seen or pair in existing_pairs:
                continue
            pairs_seen.add(pair)
            edges.append(
                {
                    "data": {
                        "id": "implied-edge::%d" % edge_index,
                        "source": item_id,
                        "target": owner,
                        "relationship_type": "implied_data_usage",
                        "label_es": labels["es"],
                        "label_en": labels["en"],
                        "confidence": "inferred",
                        "is_implied": True,
                    }
                }
            )
            edge_index += 1
    return edges


def count_by(items: list[dict[str, Any]], data_key: str, field: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    for item in items:
        value = item[data_key][field]
        counts[value] = counts.get(value, 0) + 1
    return counts


def build_by_item_index(object_edges: list[dict[str, Any]]) -> dict[str, list[int]]:
    # For G.8's focused graph: given a selected item's qualified_name, look
    # up which object-level edges touch it in O(1) instead of a linear scan
    # over tens of thousands of edges on every click.
    index: dict[str, list[int]] = {}
    for position, edge in enumerate(object_edges):
        item_id = edge["data"]["target"]
        index.setdefault(item_id, []).append(position)
    return index


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False, separators=(",", ":"))


def main() -> None:
    now = datetime.now(timezone.utc)
    workspace_rows = read_csv(INDEX_DIR / "workspaces.csv")
    item_rows = read_csv(INDEX_DIR / "items.csv")
    dependency_rows = read_csv(INDEX_DIR / "dependencies.csv")
    impact_payload = read_json(DATA_DIR / "object-impact.json")
    # Only for build_external_origin_graph -- see its own docstring-style
    # comment for why object-impact.json alone isn't enough for that one.
    explorer_payload = read_json(DATA_DIR / "lineage-explorer.json")
    execution_rows = read_csv(ANALYSIS_DIR / "execution_duration_by_item.csv")

    item_counts_by_workspace = compute_workspace_item_counts(item_rows)
    storage_table_counts = compute_storage_table_counts(impact_payload)
    execution_health = build_execution_health_index(execution_rows)
    admin_settings = _load_admin_settings()
    certification_index = build_certification_index(admin_settings.get("certified_items") or [])
    tag_index = build_tag_index(admin_settings.get("tags") or [])

    workspace_nodes, known_workspace_ids, workspace_technical_id_by_name = build_workspace_nodes(
        workspace_rows, item_counts_by_workspace
    )
    item_nodes, known_item_ids = build_item_nodes(
        item_rows, workspace_technical_id_by_name, known_workspace_ids, storage_table_counts,
        execution_health, now, certification_index, tag_index,
    )
    item_edges = build_item_edges(dependency_rows, known_item_ids)

    # H.6: fold in implied item->owning-storage-item edges (see
    # build_implied_storage_edges) before computing is_connected/summary
    # counts below, so they're indistinguishable from captured dependency
    # edges everywhere except their own `relationship_type`/`is_implied`
    # flag -- the client styles them differently (graph-map.js), but they
    # participate in layout/connectivity like any other edge.
    existing_pairs: set[tuple[str, str]] = set()
    for edge in item_edges:
        s, t = edge["data"]["source"], edge["data"]["target"]
        existing_pairs.add((s, t))
        existing_pairs.add((t, s))
    implied_edges = build_implied_storage_edges(impact_payload, known_item_ids, existing_pairs, len(item_edges))
    item_edges = item_edges + implied_edges

    object_nodes, object_edges = build_object_graph(impact_payload, known_item_ids)
    origin_nodes, origin_edges = build_external_origin_graph(explorer_payload, known_item_ids)
    item_edges = item_edges + origin_edges

    item_level_nodes = workspace_nodes + item_nodes + origin_nodes

    # A noticeable share of item-level nodes have zero edges once filtered
    # against real dependency rows -- items whose lineage genuinely wasn't
    # captured. Feeding all of them into dagre's LR layout produces an
    # unusably tall bounding box: dagre stacks each disconnected component
    # in its own row, and with hundreds of singleton components that blows
    # out one axis until real nodes render sub-pixel. `is_connected` lets the client render a clean
    # layout by default (connected nodes only) while keeping every node in
    # the one file for G.4's search/index panel to still find and center
    # on any of them. H.5: every workspace node is now forced `is_connected`
    # regardless of its own (nonexistent) edges -- items nest inside it as
    # a compound parent, so it must always be present for that to render,
    # not just when something happens to link to it directly.
    connected_ids: set[str] = set(known_workspace_ids)
    for edge in item_edges:
        connected_ids.add(edge["data"]["source"])
        connected_ids.add(edge["data"]["target"])
    for node in item_level_nodes:
        node["data"]["is_connected"] = node["data"]["id"] in connected_ids

    generated_at = now.isoformat()

    item_payload = {
        "generated_at": generated_at,
        "summary": {
            "node_count": len(item_level_nodes),
            "connected_node_count": len(connected_ids),
            "edge_count": len(item_edges),
            "node_type_counts": count_by(item_level_nodes, "data", "node_type"),
            "relationship_type_counts": count_by(item_edges, "data", "relationship_type"),
        },
        "nodes": item_level_nodes,
        "edges": item_edges,
    }
    write_json(ITEM_OUTPUT_PATH, item_payload)

    object_payload = {
        "generated_at": generated_at,
        "summary": {
            "node_count": len(object_nodes),
            "edge_count": len(object_edges),
            "node_type_counts": count_by(object_nodes, "data", "node_type"),
            "relationship_type_counts": count_by(object_edges, "data", "relationship_type"),
        },
        "nodes": object_nodes,
        "edges": object_edges,
        # item qualified_name -> indices into `edges` above that touch it.
        "by_item_id": build_by_item_index(object_edges),
    }
    write_json(OBJECT_OUTPUT_PATH, object_payload)

    print("Graph Map index built.")
    print("Item-level: %d nodes, %d edges -> %s" % (len(item_level_nodes), len(item_edges), ITEM_OUTPUT_PATH.relative_to(REPO_ROOT)))
    print("Object-level: %d nodes, %d edges -> %s" % (len(object_nodes), len(object_edges), OBJECT_OUTPUT_PATH.relative_to(REPO_ROOT)))
    print("Item node types: %s" % json.dumps(item_payload["summary"]["node_type_counts"], ensure_ascii=False))
    print("Item relationship types: %s" % json.dumps(item_payload["summary"]["relationship_type_counts"], ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 - top-level: report cleanly instead of a raw traceback
        import sys

        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
