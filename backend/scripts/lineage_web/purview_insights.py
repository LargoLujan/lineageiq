"""Purview-inspired governance views -- access audit, capacity insight, a
changes digest, and a tenant-wide sensitivity
overview.

Live-Warehouse/OneLake read when available (these four views
used to read local-only files that nothing keeps fresh once discovery
moved to the Fabric-native pipeline -- see catalog.py's own
_warehouse_or_local, the same pattern applied here), falling back to the
original local CSV/JSON on any failure, same as catalog.py already does.
"""
import csv
import json
import threading
import time
from collections import defaultdict

from . import onelake_data, warehouse
from .catalog import _norm, _object_display_name, _object_key, _warehouse_or_local
from .constants import FULL_SCAN_LABEL
from .paths import (
    EXECUTION_DURATION_BY_ITEM_PATH,
    GOVERNANCE_ENDORSEMENT_PATH,
    GOVERNANCE_RLS_ROLES_PATH,
    GOVERNANCE_SCAN_STATUS_PATH,
    GOVERNANCE_SENSITIVITY_LABELS_PATH,
    GOVERNANCE_TAGS_PATH,
    GRAPH_MAP_INDEX_OBJECTS_PATH,
    ITEM_HISTORY_PATH,
    ITEMS_INDEX_PATH,
    WORKSPACE_INDEX_PATH,
    WORKSPACE_ROLE_ASSIGNMENTS_PATH,
)
from .sensitivity_classifier import PRIVACY_FRAMEWORKS, SENSITIVITY_CATEGORIES, category_frameworks, category_label, category_recommendation, category_risk, category_risk_label, classify_columns


def _read_csv_rows(path):
    if not path.exists():
        return []
    with open(path, "r", encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def _execution_duration_rows():
    """bronze_executions (Warehouse) carries raw per-job_instance rows, not
    the (qualified_name, job_type)-aggregated shape EXECUTION_DURATION_BY_
    ITEM_PATH used to hold -- so this can't reuse _warehouse_or_local
    as-is, it aggregates the raw rows itself. _get_capacity_insight only
    ever reads workspace_name/run_count/failed_count from each row, so
    that's all this computes -- no need to reproduce the full original
    CSV's duration statistics."""
    if warehouse.is_warehouse_read_enabled():
        try:
            raw_rows = warehouse.query_bronze_table("bronze_executions")
        except warehouse.WarehouseError as exc:
            print(f"[purview_insights] Warehouse read of bronze_executions failed, falling back to {EXECUTION_DURATION_BY_ITEM_PATH.name}: {exc}")
        else:
            buckets = defaultdict(lambda: {"workspace_name": "", "run_count": 0, "failed_count": 0})
            for row in raw_rows:
                if row.get("record_type") != "job_instance":
                    continue
                key = (row.get("qualified_name", ""), row.get("job_type", ""))
                bucket = buckets[key]
                bucket["workspace_name"] = row.get("workspace_name", "")
                bucket["run_count"] += 1
                if row.get("status") == "Failed":
                    bucket["failed_count"] += 1
            return list(buckets.values())
    return _read_csv_rows(EXECUTION_DURATION_BY_ITEM_PATH)


def _get_access_audit():
    rows = [
        row for row in _warehouse_or_local("bronze_workspace_role_assignments", WORKSPACE_ROLE_ASSIGNMENTS_PATH)
        if row.get("status") == "discovered"
    ]
    if not rows:
        return {
            "found": False,
            "reason": "No role assignments discovered yet -- run a scan (NB_Discover_Workspaces_Items writes dbo.bronze_workspace_role_assignments).",
        }

    by_workspace = {}
    for row in rows:
        workspace_name = row.get("workspace_name", "")
        by_workspace.setdefault(workspace_name, []).append(
            {
                "principal_name": row.get("principal_name", ""),
                "principal_email": row.get("principal_email", ""),
                "principal_type": row.get("principal_type", ""),
                "role": row.get("role", ""),
            }
        )

    # Tenant-wide view: which principals are Admin in the most workspaces --
    # the "who effectively has the keys to everything" question a single
    # per-workspace list can't answer at a glance. Keyed by name (not
    # email -- older rows predate principal_email existing at all, see
    # 68_discover_workspace_role_assignments.ps1) with email carried
    # alongside for display/click-through.
    admin_workspaces_by_principal = {}
    principal_type_by_name = {}
    principal_email_by_name = {}
    for row in rows:
        if row.get("role") != "Admin":
            continue
        name = row.get("principal_name", "")
        admin_workspaces_by_principal.setdefault(name, []).append(
            {"workspace_name": row.get("workspace_name", ""), "role": row.get("role", "")}
        )
        principal_type_by_name[name] = row.get("principal_type", "")
        if row.get("principal_email"):
            principal_email_by_name[name] = row.get("principal_email", "")

    tenant_wide_admins = sorted(
        (
            {
                "principal_name": name,
                "principal_email": principal_email_by_name.get(name, ""),
                "principal_type": principal_type_by_name.get(name, ""),
                "admin_workspace_count": len(workspaces),
                "workspaces": sorted(workspaces, key=lambda w: w["workspace_name"]),
            }
            for name, workspaces in admin_workspaces_by_principal.items()
        ),
        key=lambda entry: entry["admin_workspace_count"],
        reverse=True,
    )

    return {
        "found": True,
        "workspace_count": len(by_workspace),
        "assignment_count": len(rows),
        "by_workspace": [
            {"workspace_name": name, "assignments": assignments}
            for name, assignments in sorted(by_workspace.items())
        ],
        "tenant_wide_admins": tenant_wide_admins[:25],
        # So the admin panel can show "+N more" instead of silently
        # dropping them with no indication a cap was even hit.
        "tenant_wide_admin_total_count": len(tenant_wide_admins),
    }


def _capacity_label(row):
    # Fabric's workspaces endpoint doesn't return a human capacity name --
    # 01_discover_workspaces.ps1's own comment already notes this
    # ("Capacity ID captured; capacity name not returned by workspaces
    # endpoint.") -- capacity_id (+ capacity_region, when present) is real
    # data already in index/workspaces.csv today, so it's what this groups
    # by; capacity_name is only used to upgrade the label when some other
    # enrichment step *did* manage to resolve one for that row.
    name = (row.get("capacity_name") or "").strip()
    capacity_id = (row.get("capacity_id") or "").strip()
    region = (row.get("capacity_region") or "").strip()
    if name:
        return name
    if capacity_id:
        return capacity_id + (" (" + region + ")" if region else "")
    return "(sin capacidad asignada)"


def _get_capacity_insight():
    workspace_rows = _warehouse_or_local("bronze_workspaces", WORKSPACE_INDEX_PATH)
    if not workspace_rows:
        return {"found": False, "reason": "No workspaces discovered yet -- run a scan."}

    capacity_by_workspace = {row.get("workspace_name", ""): _capacity_label(row) for row in workspace_rows}

    item_rows = _warehouse_or_local("bronze_items", ITEMS_INDEX_PATH)
    execution_rows = _execution_duration_rows()

    stats = {}

    def _bucket(capacity_label):
        return stats.setdefault(capacity_label, {"workspaces": set(), "item_count": 0, "execution_count": 0, "failed_count": 0})

    for workspace_name, capacity_label in capacity_by_workspace.items():
        _bucket(capacity_label)["workspaces"].add(workspace_name)

    for row in item_rows:
        capacity_label = capacity_by_workspace.get(row.get("workspace_name", ""), "(sin capacidad asignada)")
        _bucket(capacity_label)["item_count"] += 1

    for row in execution_rows:
        capacity_label = capacity_by_workspace.get(row.get("workspace_name", ""), "(sin capacidad asignada)")
        bucket = _bucket(capacity_label)
        try:
            bucket["execution_count"] += int(row.get("run_count") or 0)
            bucket["failed_count"] += int(row.get("failed_count") or 0)
        except ValueError:
            pass

    capacities = sorted(
        (
            {
                "capacity_label": label,
                "workspace_count": len(bucket["workspaces"]),
                "item_count": bucket["item_count"],
                "execution_count": bucket["execution_count"],
                "failed_count": bucket["failed_count"],
            }
            for label, bucket in stats.items()
        ),
        key=lambda entry: entry["item_count"],
        reverse=True,
    )

    return {"found": True, "capacities": capacities}


def _get_dependency_changes(target_scans, limit):
    """Companion to _get_changes_digest, one level down the graph
    -- bronze_dependency_history has no local-CSV
    fallback (unlike bronze_item_history/ITEM_HISTORY_PATH): it's a brand
    new table this web server itself started writing to, with nothing
    equivalent ever produced locally, so this reads the Warehouse
    directly rather than going through _warehouse_or_local. Filtered to
    the SAME scan_started_at value(s) _get_changes_digest already
    resolved from the item history (a single-element set in single-scan
    mode, or every scan inside a date range), so this
    section always describes the same scan(s) as the one above it -- a
    scan that didn't touch bronze_dependency_history at all (e.g. it
    predates this feature, or Warehouse writes are off) just contributes
    nothing rather than this section picking a different run."""
    target_scans = {s for s in (target_scans or ()) if s}
    if not target_scans:
        return {"added_count": 0, "removed_count": 0, "modified_count": 0, "total_count": 0, "changes": []}
    try:
        rows = warehouse.query_bronze_table("bronze_dependency_history", use_cache=False)
    except warehouse.WarehouseError:
        return {"added_count": 0, "removed_count": 0, "modified_count": 0, "total_count": 0, "changes": []}

    matched_rows = [row for row in rows if row.get("scan_started_at", "") in target_scans]
    counts = {"added": 0, "removed": 0, "modified": 0}
    for row in matched_rows:
        event_type = row.get("event_type", "")
        if event_type in counts:
            counts[event_type] += 1
    return {
        "added_count": counts["added"],
        "removed_count": counts["removed"],
        "modified_count": counts["modified"],
        # So the admin panel can show "N more not shown" when limit is hit
        # instead of silently truncating with no indication.
        "total_count": len(matched_rows),
        "changes": [
            {
                "event_date": row.get("event_date", ""),
                "event_type": row.get("event_type", ""),
                "from_qualified_name": row.get("from_qualified_name", ""),
                "to_qualified_name": row.get("to_qualified_name", ""),
                "relationship_type": row.get("relationship_type", ""),
                "scope_label": row.get("scope_label", ""),
            }
            for row in matched_rows[:limit]
        ],
    }


def _get_changes_digest(limit=200, scan_started_at=None, date_from=None, date_to=None):
    """scan_started_at: picks one of this response's own
    available_scans values instead of always the latest scan. date_from/
    date_to (both optional, inclusive, "YYYY-MM-DD" against
    each row's event_date): aggregates EVERY scan in that range into one
    digest instead of a single scan -- takes priority over scan_started_at
    when either is given. Neither given = latest scan only (unchanged
    original behavior)."""
    rows = _warehouse_or_local("bronze_item_history", ITEM_HISTORY_PATH)
    if not rows:
        return {
            "found": False,
            "reason": "No item history yet -- it's appended after the first scan run since this feature was added; nothing to show until then.",
        }

    # Most-recent-first, capped -- this project's own scan history already
    # caps similarly (the scan queue, /api/history's implicit UI paging),
    # so a tenant with years of daily scans doesn't hand back thousands of
    # timestamps to populate one dropdown with.
    available_scans = sorted({row.get("scan_started_at", "") for row in rows if row.get("scan_started_at")}, reverse=True)[:50]
    latest_scan = max((row.get("scan_started_at", "") for row in rows), default="")
    # The earliest FULL scan on record -- the reference point for "show me everything since the
    # start". A single-workspace scan never counts as this even if
    # it happens to be the very first row ever written.
    first_full_scan = min(
        (row.get("scan_started_at", "") for row in rows if row.get("scope_label") == FULL_SCAN_LABEL and row.get("scan_started_at")),
        default="",
    )

    use_range = bool(date_from or date_to)
    if use_range:
        target_rows = [
            row for row in rows
            if (not date_from or row.get("event_date", "") >= date_from)
            and (not date_to or row.get("event_date", "") <= date_to)
        ]
        target_scan = None
    else:
        target_scan = scan_started_at if scan_started_at in available_scans else latest_scan
        target_rows = [row for row in rows if row.get("scan_started_at", "") == target_scan]

    # Per-scan change counts: lets the scan picker show "N
    # changes" next to each date without a second round trip -- `rows` is
    # already fully loaded above, so this is just counting what's already
    # in memory, not an extra query.
    available_scan_counts = {}
    for row in rows:
        scan_ts = row.get("scan_started_at", "")
        if scan_ts in available_scans:
            available_scan_counts[scan_ts] = available_scan_counts.get(scan_ts, 0) + 1

    counts = {"added": 0, "removed": 0, "modified": 0}
    for row in target_rows:
        event_type = row.get("event_type", "")
        if event_type in counts:
            counts[event_type] += 1

    # Which real scan(s) contributed to target_rows, newest first, each
    # with who triggered it -- a single entry in single-scan
    # mode, several in range mode. Empty triggered_by_email means an
    # anonymous/session-less trigger (a Fabric-pipeline scan with no
    # signed-in user attached), not a data gap.
    scans_included = sorted(
        {(row.get("scan_started_at", ""), row.get("triggered_by_email", "")) for row in target_rows if row.get("scan_started_at")},
        key=lambda pair: pair[0],
        reverse=True,
    )

    return {
        "found": True,
        "latest_scan_started_at": latest_scan,
        "first_full_scan_started_at": first_full_scan,
        "scan_started_at": target_scan,
        "date_from": date_from or "",
        "date_to": date_to or "",
        "available_scans": available_scans,
        "available_scan_counts": available_scan_counts,
        "scans_included": [{"scan_started_at": s, "triggered_by_email": e} for s, e in scans_included],
        "added_count": counts["added"],
        "removed_count": counts["removed"],
        "modified_count": counts["modified"],
        "total_count": len(target_rows),
        "changes": [
            {
                "event_date": row.get("event_date", ""),
                "event_type": row.get("event_type", ""),
                "qualified_name": row.get("qualified_name", ""),
                "item_type": row.get("item_type", ""),
                "item_name": row.get("item_name", ""),
                "workspace_name": row.get("workspace_name", ""),
                "scope_label": row.get("scope_label", ""),
                "triggered_by_email": row.get("triggered_by_email", ""),
            }
            for row in target_rows[:limit]
        ],
        "dependencies": _get_dependency_changes({s for s, _ in scans_included} or {target_scan}, limit),
    }


def _sensitivity_overview_from_warehouse(sample_limit, custom_categories=None):
    """Live-Warehouse counterpart to the OneLake/local-JSON path below
     -- dbo.bronze_object_column_catalog classified by column
    NAME via sensitivity_classifier.classify_columns, joined against dbo.
    bronze_sql_endpoint_object_catalog to resolve workspace_name/source_
    server/source_database per object.

    Join key: (source_database, schema_name, object_name), catalog._norm's
    casefold+strip -- the same alias NB_Build_Object_Impact.py's own
    catalog-alias resolution already uses, reused here rather than
    reinvented so this reads the tenant's data the same way every other
    object-attribution path in this project already does.

    It tries a SERVER-AWARE key first (catalog._object_key
    -- server+database+schema+object, same normalization) before falling
    back to the server-less alias above: a Dev/Pro pair of the SAME
    Lakehouse (identical database/schema/object names, different server)
    can collide on the server-less key alone even though each side is
    individually unambiguous once the server most of the tenant's data
    already carries is taken into account. Only used when the querying row
    itself has a source_server AND that server-aware key maps to EXACTLY
    ONE catalog row; any other case (no server on the querying row, 0
    matches, or 2+ matches even with server included) falls back to the
    original server-less alias exactly as before -- never a regression for
    a row that already resolved fine without server info.

    Only resolves a workspace when the winning key (server-aware, or the
    server-less fallback) maps to EXACTLY ONE sql-endpoint-catalog row --
    an ambiguous alias (two different real sources sharing one database|
    schema|object_name, AND sharing whatever server info is available) is
    left unresolved (a dash) rather than guessing, since a wrong
    attribution here would silently misattribute a flagged sensitive
    column to the wrong workspace -- worse than the dash it replaces.

    Returns None (not found=False) when the column catalog is reachable
    but genuinely empty, signaling the caller to fall back to the local
    JSON same as a Warehouse failure would; raises warehouse.WarehouseError
    (propagated to the caller) if either table can't be queried at all
    (e.g. not uploaded yet), same "degrade, don't break" contract as every
    other Warehouse-backed view in this module."""
    column_rows = warehouse.query_bronze_table("bronze_object_column_catalog")
    if not column_rows:
        return None
    sql_catalog_rows = warehouse.query_bronze_table("bronze_sql_endpoint_object_catalog")

    flagged_objects, total_object_count = _classified_objects_with_workspace(column_rows, sql_catalog_rows, custom_categories)

    by_category = {}
    for obj in flagged_objects:
        for category in obj["categories"]:
            bucket = by_category.setdefault(category, {"count": 0, "samples": []})
            bucket["count"] += 1
            if len(bucket["samples"]) < sample_limit:
                bucket["samples"].append(
                    {
                        "label": obj["label"],
                        "source_server": obj["source_server"],
                        "source_database": obj["source_database"],
                        "workspace_name": obj["workspace_name"],
                    }
                )

    categories = sorted(
        (
            {
                "category": key,
                "label_es": category_label(key, "es", custom_categories),
                "label_en": category_label(key, "en", custom_categories),
                "object_count": bucket["count"],
                "samples": bucket["samples"],
            }
            for key, bucket in by_category.items()
        ),
        key=lambda entry: entry["object_count"],
        reverse=True,
    )

    return {
        "found": True,
        "total_object_count": total_object_count,
        "flagged_object_count": len(flagged_objects),
        "categories": categories,
    }


# The shared per-OBJECT
# classification + workspace-resolution walk _sensitivity_overview_from_
# warehouse above already did inline -- extracted so _get_privacy_
# coverage_map below (per-object, deduplicated, "where is this data"
# framing) can reuse the exact same classification and server-aware
# workspace-resolution logic instead of a second, divergent copy of it.
# Pure refactor of the block above: same join keys, same "only resolve
# workspace when exactly one candidate matches" rule, same output shape
# per object.
def _classified_objects_with_workspace(column_rows, sql_catalog_rows, custom_categories=None):
    """Returns (flagged_objects, total_object_count). Each flagged_objects
    entry: {label, source_server, source_database, workspace_name,
    categories: set(...)} -- one entry per object that matched at least
    one sensitivity category, workspace_name resolved via the same
    server-aware-then-server-less alias join _sensitivity_overview_from_
    warehouse's own docstring documents in detail."""
    objects = {}
    for row in column_rows:
        object_name = row.get("object_name", "")
        column_name = row.get("column_name", "")
        if not object_name or not column_name:
            continue
        key = _object_key(row.get("source_server", ""), row.get("source_database", ""), row.get("schema_name", ""), object_name)
        obj = objects.setdefault(key, {
            "source_server": row.get("source_server", ""),
            "source_database": row.get("source_database", ""),
            "schema_name": row.get("schema_name", ""),
            "object_name": object_name,
            "column_names": [],
        })
        obj["column_names"].append(column_name)

    alias_matches = defaultdict(list)
    alias_matches_by_server = defaultdict(list)
    for row in sql_catalog_rows or []:
        if not (row.get("source_database") and row.get("schema_name") and row.get("object_name")):
            continue
        alias = (_norm(row.get("source_database", "")), _norm(row.get("schema_name", "")), _norm(row.get("object_name", "")))
        alias_matches[alias].append(row)
        if row.get("source_server"):
            server_alias = _object_key(row.get("source_server", ""), row.get("source_database", ""), row.get("schema_name", ""), row.get("object_name", ""))
            alias_matches_by_server[server_alias].append(row)

    flagged_objects = []
    for obj in objects.values():
        categories = classify_columns(obj["column_names"], custom_categories)
        if not categories:
            continue

        alias = (_norm(obj["source_database"]), _norm(obj["schema_name"]), _norm(obj["object_name"]))
        matches = None
        if obj["source_server"]:
            server_alias = _object_key(obj["source_server"], obj["source_database"], obj["schema_name"], obj["object_name"])
            server_matches = alias_matches_by_server.get(server_alias, [])
            if len(server_matches) == 1:
                matches = server_matches
        if matches is None:
            matches = alias_matches.get(alias, [])
        if len(matches) == 1:
            catalog_match = matches[0]
            workspace_name = catalog_match.get("workspace_name", "")
            source_server = catalog_match.get("source_server", "") or obj["source_server"]
            source_database = catalog_match.get("source_database", "") or obj["source_database"]
        else:
            workspace_name = ""
            source_server = obj["source_server"]
            source_database = obj["source_database"]

        flagged_objects.append({
            "label": _object_display_name(obj),
            "source_server": source_server,
            "source_database": source_database,
            "workspace_name": workspace_name,
            "categories": categories,
        })

    return flagged_objects, len(objects)


# A real 502 on this route in production surfaced that this
# recomputed EVERY category match for EVERY object on every single call --
# the raw Warehouse rows behind it are already cached (warehouse.py's own
# _table_cache), but that only saves the network round trip, not the
# actual classification/alias-join CPU work, which is the more expensive
# half at large-tenant scale. _get_privacy_framework_map calls this
# function internally too, so switching straight from "by framework" to
# "all tables" used to redo the full pass twice in a row for no reason.
# Short TTL (same 2 minutes of "absorb a user clicking around" as _table_
# cache's own 30s, just a bit longer since this is strictly more expensive
# to redo) -- long-lived staleness isn't a concern for a locator, unlike
# e.g. session state.
_PRIVACY_COVERAGE_CACHE_TTL_SECONDS = 120
_privacy_coverage_cache_lock = threading.Lock()
_privacy_coverage_cache = {}  # cache_key -> (result, computed_at)


def _get_privacy_coverage_map(settings=None, use_cache=True):
    """"where does this kind of data live"
    locator for GDPR/data-subject-rights requests (which can combine
    access, objection and biometric data). The existing per-CATEGORY
    Sensitivity tab repeats the same table once per category it matches --
    fine for "how many objects touch category X", wrong shape for "give
    me the list of tables to go look at, once each". This is that same
    classification data, pivoted: one row per flagged OBJECT, with every
    matched category attached to it, so a table with 3 sensitive columns
    of 3 different categories appears exactly once here, not 3 times.

    This is a LOCATOR, not a personal-data puller -- it answers "which
    Fabric tables might contain data relevant to this kind of request",
    never "show me this specific person's row" (this project has never
    read/indexed row-level personal data, by design -- content-based
    sensitivity sampling elsewhere in this file only ever computes a match
    PERCENTAGE, never surfaces a raw value). Most of what a real GDPR/
    FERPA/CCPA request touches (physical biometric access control, a CRM,
    a marketing platform, payment systems) very likely lives OUTSIDE
    this Fabric tenant entirely -- this can only ever cover the Fabric-
    hosted slice.

    max_risk: the highest risk level among an object's matched categories
    (very_high > high > medium > low), for sorting/color-coding without
    the caller having to know every category's own risk itself.

    use_cache: tests pass False to bypass the module-level result cache
    below -- without it, a later test's monkeypatched Warehouse rows could
    silently return an EARLIER test's cached result within the same
    pytest run, since this cache (unlike warehouse.py's own) is keyed
    only by custom_categories, not by whatever the mock happens to
    return."""
    custom_categories = (settings or {}).get("custom_sensitivity_categories") or []
    cache_key = json.dumps(custom_categories, sort_keys=True, default=str)
    if use_cache:
        with _privacy_coverage_cache_lock:
            cached = _privacy_coverage_cache.get(cache_key)
            if cached and (time.time() - cached[1]) < _PRIVACY_COVERAGE_CACHE_TTL_SECONDS:
                return cached[0]

    try:
        column_rows = warehouse.query_bronze_table("bronze_object_column_catalog")
    except warehouse.WarehouseError as exc:
        return {"found": False, "reason": f"Warehouse read failed: {exc}"}
    if not column_rows:
        return {"found": False, "reason": "No hay catálogo de columnas todavía -- ejecuta un escaneo (NB_Extract_Object_Column_Catalog.py)."}
    try:
        sql_catalog_rows = warehouse.query_bronze_table("bronze_sql_endpoint_object_catalog")
    except warehouse.WarehouseError:
        sql_catalog_rows = []

    flagged_objects, total_object_count = _classified_objects_with_workspace(column_rows, sql_catalog_rows, custom_categories)

    risk_rank = {"low": 0, "medium": 1, "high": 2, "very_high": 3}
    objects_out = []
    for obj in flagged_objects:
        category_entries = sorted(
            (
                {
                    "category": key,
                    "label_es": category_label(key, "es", custom_categories),
                    "label_en": category_label(key, "en", custom_categories),
                    "risk": category_risk(key, custom_categories),
                }
                for key in obj["categories"]
            ),
            key=lambda entry: risk_rank.get(entry["risk"], -1),
            reverse=True,
        )
        max_risk = category_entries[0]["risk"] if category_entries else ""
        objects_out.append({
            "label": obj["label"],
            "workspace_name": obj["workspace_name"],
            "source_server": obj["source_server"],
            "source_database": obj["source_database"],
            "categories": category_entries,
            "category_count": len(category_entries),
            "max_risk": max_risk,
        })

    objects_out.sort(key=lambda entry: (risk_rank.get(entry["max_risk"], -1), entry["category_count"]), reverse=True)

    category_counts = {}
    for obj in objects_out:
        for entry in obj["categories"]:
            category_counts[entry["category"]] = category_counts.get(entry["category"], 0) + 1

    result = {
        "found": True,
        "total_object_count": total_object_count,
        "flagged_object_count": len(objects_out),
        "category_counts": sorted(
            (
                {"category": key, "label_es": category_label(key, "es", custom_categories), "label_en": category_label(key, "en", custom_categories), "object_count": count}
                for key, count in category_counts.items()
            ),
            key=lambda entry: entry["object_count"],
            reverse=True,
        ),
        "objects": objects_out,
    }
    if use_cache:
        with _privacy_coverage_cache_lock:
            _privacy_coverage_cache[cache_key] = (result, time.time())
    return result


def _get_privacy_framework_map(settings=None, use_cache=True):
    """The same
    classification data, grouped by legal FRAMEWORK first (GDPR/FERPA/
    CCPA), then by category -- a "browse like a settings menu" structure
    for "what data do we have under GDPR" questions, requested after the
    per-object coverage map shipped. Unlike that map's own per-OBJECT
    dedup (its whole point), a table legitimately appears under EVERY
    framework/category it matches here -- not a duplicate, the same table
    genuinely being both a GDPR special-category concern AND a CCPA one
    is real and worth showing under both.

    Also folds in privacy_external_systems (admin-maintained, mostly for
    systems this locator can never reach because they live entirely
    outside Fabric) per category, so a category with zero Fabric matches
    (biometric, voice_recording -- see sensitivity_classifier.py's own
    notes on those two) can still show "known to live in: <system X>".

    found is always True here (unlike _get_privacy_coverage_map, which can
    report found=False on a Warehouse failure) -- the framework/category
    taxonomy and any logged external systems are still meaningful on their
    own even with zero live Fabric data; coverage.get("found") failing
    just means every category's object_count/objects end up empty.

    use_cache: threaded straight through to _get_privacy_coverage_map --
    see that function's own docstring on why tests need to pass False."""
    custom_categories = (settings or {}).get("custom_sensitivity_categories") or []
    external_systems = (settings or {}).get("privacy_external_systems") or []

    coverage = _get_privacy_coverage_map(settings, use_cache=use_cache)
    objects_by_category = defaultdict(list)
    if coverage.get("found"):
        for obj in coverage["objects"]:
            for entry in obj["categories"]:
                objects_by_category[entry["category"]].append(
                    {"label": obj["label"], "workspace_name": obj["workspace_name"], "source_server": obj["source_server"], "source_database": obj["source_database"]}
                )

    external_by_category = defaultdict(list)
    for system in external_systems:
        category = (system.get("category") or "").strip()
        if category:
            external_by_category[category].append(system)

    # Every category key with at least one framework tag -- built-in ones
    # always have one (enforced by sensitivity_classifier.py's own test
    # suite); a custom one only surfaces here if the admin who created it
    # actually tagged it with a real framework, otherwise it stays visible
    # in the plain coverage map but not in this framework browse.
    all_category_keys = list(SENSITIVITY_CATEGORIES.keys()) + [
        key for key in ((entry.get("key") or "").strip() for entry in custom_categories) if key
    ]

    frameworks_out = []
    for framework_key, framework_meta in PRIVACY_FRAMEWORKS.items():
        categories_out = []
        for category_key in all_category_keys:
            if framework_key not in category_frameworks(category_key, custom_categories):
                continue
            matched_objects = objects_by_category.get(category_key, [])
            categories_out.append({
                "category": category_key,
                "label_es": category_label(category_key, "es", custom_categories),
                "label_en": category_label(category_key, "en", custom_categories),
                "risk": category_risk(category_key, custom_categories),
                "object_count": len(matched_objects),
                "objects": matched_objects,
                "external_systems": external_by_category.get(category_key, []),
            })
        if not categories_out:
            continue
        categories_out.sort(key=lambda entry: (entry["object_count"], len(entry["external_systems"])), reverse=True)
        frameworks_out.append({
            "framework": framework_key,
            "label_es": framework_meta["es"],
            "label_en": framework_meta["en"],
            "description_es": framework_meta["description_es"],
            "description_en": framework_meta["description_en"],
            "category_count": len(categories_out),
            "total_object_count": sum(c["object_count"] for c in categories_out),
            "categories": categories_out,
        })

    return {
        "found": True,
        "frameworks": frameworks_out,
    }


def _get_sensitivity_overview(sample_limit=15, settings=None):
    # Live-Warehouse read first (see _sensitivity_overview_
    # from_warehouse's own docstring) -- the graph-map-index-objects.json
    # chain below is local-build-only and has been dead since discovery
    # moved to Fabric-native scanning; this bypasses it for this one
    # feature the same way _get_capacity_insight/_get_governance_scan_
    # overview already bypass their own stale local chains elsewhere in
    # this module. Falls back to the JSON path on ANY Warehouse failure
    # (not enabled, tables missing, connection error) -- same degrade-
    # don't-break contract as everything else here.
    custom_categories = (settings or {}).get("custom_sensitivity_categories") or []
    if warehouse.is_warehouse_read_enabled():
        try:
            live_result = _sensitivity_overview_from_warehouse(sample_limit, custom_categories)
        except warehouse.WarehouseError as exc:
            print(f"[purview_insights] Warehouse read for sensitivity overview failed, falling back to {GRAPH_MAP_INDEX_OBJECTS_PATH.name}: {exc}")
        else:
            if live_result is not None:
                return live_result

    # graph-map-index-objects.json is one of the 5 files onelake_data.py
    # publishes (see PUBLISHED_FILENAMES) -- fetch_cached_path() returns a
    # fresh-enough OneLake copy when onelake_data.mode == "onelake", or
    # None on any failure/misconfiguration, in which case this falls back
    # to the local static file exactly like before.
    source_path = onelake_data.fetch_cached_path(GRAPH_MAP_INDEX_OBJECTS_PATH.name) or GRAPH_MAP_INDEX_OBJECTS_PATH
    if not source_path.exists():
        return {
            "found": False,
            "reason": "graph-map-index-objects.json not built yet -- run a scan (NB_Build_Graph_Map writes it to OneLake).",
        }
    with open(source_path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)

    objects = [n["data"] for n in payload.get("nodes", [])]
    flagged = [obj for obj in objects if obj.get("sensitivity_categories")]

    by_category = {}
    for obj in flagged:
        for category in obj["sensitivity_categories"]:
            bucket = by_category.setdefault(category, {"count": 0, "samples": []})
            bucket["count"] += 1
            if len(bucket["samples"]) < sample_limit:
                bucket["samples"].append(
                    {
                        "label": obj.get("label", ""),
                        "source_server": obj.get("source_server", ""),
                        "source_database": obj.get("source_database", ""),
                        "workspace_name": obj.get("workspace_name", ""),
                    }
                )

    categories = sorted(
        (
            {
                "category": key,
                "label_es": category_label(key, "es", custom_categories),
                "label_en": category_label(key, "en", custom_categories),
                "object_count": bucket["count"],
                "samples": bucket["samples"],
            }
            for key, bucket in by_category.items()
        ),
        key=lambda entry: entry["object_count"],
        reverse=True,
    )

    return {
        "found": True,
        "total_object_count": len(objects),
        "flagged_object_count": len(flagged),
        "categories": categories,
    }


def _column_security_key(*parts):
    return "|".join(str(part or "").strip().casefold() for part in parts)


def _get_column_security_lookup():
    """Cross-references dbo.bronze_column_security (DDM/CLS, per-column,
    written by NB_Extract_SQL_Endpoint_Catalog's sys.masked_
    columns/sys.column_permissions queries) and dbo.bronze_row_level_
    security (RLS, per-object, sys.security_predicates) against a
    (workspace_name, "schema.object", column_name) key -- the same
    "schema.object" shape NB_Discover_Column_Sensitivity.py already builds
    for table_name, so this joins directly against _get_content_
    sensitivity_overview's own samples with no extra normalization beyond
    casefold/strip.

    Returns (column_lookup, object_lookup, scanned). `scanned` is True as
    soon as EITHER table has any row at all, and is meant to distinguish
    "checked this endpoint, found nothing" from "never scanned" for the
    admin panel's DDM/security column -- an approximation, not exact
    per-endpoint provenance: an endpoint genuinely skipped by the last
    WorkspaceNameFilter run while others succeeded would still read as
    "scanned" here since some OTHER endpoint's rows exist. Good enough for
    "don't claim confirmed-clean when nothing has ever run"; a real per-
    endpoint check would need cross-referencing sql_endpoint_qualified_name
    against bronze_sql_endpoint_object_catalog_status too.
    """
    column_lookup = {}
    object_lookup = {}
    scanned = False
    try:
        for row in warehouse.query_bronze_table("bronze_column_security"):
            scanned = True
            key = _column_security_key(
                row.get("workspace_name", ""),
                f"{row.get('schema_name', '')}.{row.get('object_name', '')}",
                row.get("column_name", ""),
            )
            column_lookup.setdefault(key, []).append({
                "security_type": row.get("security_type", ""),
                "detail": row.get("detail", ""),
            })
    except warehouse.WarehouseError:
        pass
    try:
        for row in warehouse.query_bronze_table("bronze_row_level_security"):
            scanned = True
            key = _column_security_key(
                row.get("workspace_name", ""),
                f"{row.get('schema_name', '')}.{row.get('object_name', '')}",
            )
            object_lookup.setdefault(key, []).append({
                "policy_name": row.get("policy_name", ""),
                "predicate_type": row.get("predicate_type", ""),
            })
    except warehouse.WarehouseError:
        pass
    return column_lookup, object_lookup, scanned


def _get_column_sensitivity_samples_lookup():
    """{(workspace, table, column) key -> {sample_values, sample_size,
    categories_matched}} from dbo.bronze_column_sensitivity_samples (see
    fabric_notebooks/NB_Discover_Column_Sensitivity.py's
    rewrite -- the "CAMBIO DE POLÍTICA DE PRIVACIDAD" that started storing
    real example values, in their OWN table, separate from the percentage
    -only bronze_column_sensitivity_content). Tolerant of the table not
    existing yet (a notebook that hasn't been re-run since this shipped) --
    returns {} rather than raising, same degrade pattern as every other
    Warehouse-backed lookup in this module."""
    lookup = {}
    try:
        rows = warehouse.query_bronze_table("bronze_column_sensitivity_samples")
    except warehouse.WarehouseError:
        return lookup
    for row in rows:
        key = _column_security_key(row.get("workspace_name", ""), row.get("table_name", ""), row.get("column_name", ""))
        try:
            sample_values = json.loads(row.get("sample_values_json") or "[]")
        except (json.JSONDecodeError, TypeError):
            sample_values = []
        lookup[key] = {
            "sample_values": sample_values,
            "sample_size": row.get("sample_size", ""),
            "categories_matched": [c for c in (row.get("categories_matched") or "").split(",") if c],
        }
    return lookup


def _get_content_sensitivity_overview(sample_limit=15, settings=None):
    """Tenant-wide rollup of dbo.bronze_column_sensitivity_content +
    dbo.bronze_column_sensitivity_samples (redesigned so it only
    samples columns whose name already matched), the
    content-VERIFIED counterpart to _get_sensitivity_overview above (which
    only ever matches by column NAME, never real cell values). Since that
    rewrite, NB_Discover_Column_Sensitivity.py only ever
    samples a column whose NAME already matched (Paso 0 in that notebook),
    so every row here already passed that first filter -- this is no
    longer "confirmed vs unconfirmed", it's "name-flagged, and THIS is
    what checking its real content actually found."

    A category with a reliable content regex (email/phone/national_id/
    financial, see sensitivity_classifier.CONTENT_PATTERN_CATEGORIES) gets
    a real match_percentage. A category without one (person_name/address/
    birth_date/gender/health) has match_percentage=None here -- there was
    never a way to auto-confirm those by content, so a column ends up in
    this list based on being name-matched, with sample_values attached for
    a human to judge instead of a percentage.

    Scope is narrower than the name-based list on purpose, same as
    catalog._get_column_profile/_get_column_sensitivity: only Fabric-
    native Lakehouse tables the scanning service principal already had a
    data role in when profiled (see docs/105) -- most of the tenant has no
    rows here yet, so "found: False" means "not checked yet", not "clean".
    No local-CSV fallback: this table only ever comes from the Fabric-
    native notebook, there was never a local-build equivalent.

    settings (optional): threaded through to category_label/
    category_risk/etc. for custom_sensitivity_categories label resolution
    -- a no-op today (a custom category key can never appear in `category`
    below, since NB_Discover_Column_Sensitivity.py doesn't know about
    admin-defined categories yet), kept only for signature symmetry with
    _get_sensitivity_overview."""
    custom_categories = (settings or {}).get("custom_sensitivity_categories") or []
    try:
        rows = warehouse.query_bronze_table("bronze_column_sensitivity_content")
    except warehouse.WarehouseError as exc:
        return {"found": False, "reason": f"Warehouse read failed: {exc}"}
    if not rows:
        return {
            "found": False,
            "reason": "No content-based sensitivity data yet -- run fabric_notebooks/NB_Discover_Column_Sensitivity.py (Fabric-native Lakehouse tables only, see docs/105).",
        }

    column_security_lookup, object_security_lookup, security_scanned = _get_column_security_lookup()
    samples_lookup = _get_column_sensitivity_samples_lookup()

    checked_tables = set()
    by_category = {}
    for row in rows:
        workspace_name = row.get("workspace_name", "")
        lakehouse_name = row.get("lakehouse_name", "")
        table_name = row.get("table_name", "")
        column_name = row.get("column_name", "")
        checked_tables.add((workspace_name, lakehouse_name, table_name))

        raw_match = (row.get("match_percentage") or "").strip() if isinstance(row.get("match_percentage"), str) else row.get("match_percentage")
        has_content_pattern = raw_match not in ("", None)
        match_percentage = None
        if has_content_pattern:
            try:
                match_percentage = round(float(raw_match), 1)
            except (TypeError, ValueError):
                has_content_pattern = False
        # No extra percentage threshold here -- the notebook's own
        # MIN_MATCH_PERCENTAGE_TO_KEEP already decided what's worth
        # writing at all; duplicating a second cutoff here would just be
        # two magic numbers that can silently drift apart.
        category = row.get("category", "")
        bucket = by_category.setdefault(category, {"columns": set(), "tables": set(), "samples": []})
        table_key = (workspace_name, lakehouse_name, table_name)
        column_key = table_key + (column_name,)
        bucket["tables"].add(table_key)
        if column_key not in bucket["columns"]:
            bucket["columns"].add(column_key)
            if len(bucket["samples"]) < sample_limit:
                column_hits = column_security_lookup.get(_column_security_key(workspace_name, table_name, column_name), [])
                object_hits = object_security_lookup.get(_column_security_key(workspace_name, table_name), [])
                sample_entry = samples_lookup.get(_column_security_key(workspace_name, table_name, column_name), {})
                bucket["samples"].append(
                    {
                        "workspace_name": workspace_name,
                        "lakehouse_name": lakehouse_name,
                        "table_name": table_name,
                        "column_name": column_name,
                        "match_percentage": match_percentage,
                        "has_content_pattern": has_content_pattern,
                        "sample_values": sample_entry.get("sample_values", []),
                        "sample_size": sample_entry.get("sample_size", ""),
                        "security_scanned": security_scanned,
                        "security_ddm": any(h["security_type"] == "ddm" for h in column_hits),
                        "security_cls": any(h["security_type"] == "cls" for h in column_hits),
                        "security_rls": bool(object_hits),
                        "security_detail": "; ".join(
                            [h["detail"] for h in column_hits] + [f"RLS: {h['policy_name']}" for h in object_hits]
                        ),
                    }
                )

    categories = sorted(
        (
            {
                "category": key,
                "label_es": category_label(key, "es", custom_categories),
                "label_en": category_label(key, "en", custom_categories),
                "risk": category_risk(key, custom_categories),
                "risk_label_es": category_risk_label(key, "es", custom_categories),
                "risk_label_en": category_risk_label(key, "en", custom_categories),
                "recommendation_es": category_recommendation(key, "es", custom_categories),
                "recommendation_en": category_recommendation(key, "en", custom_categories),
                "column_count": len(bucket["columns"]),
                "table_count": len(bucket["tables"]),
                "samples": bucket["samples"],
            }
            for key, bucket in by_category.items()
        ),
        key=lambda entry: entry["column_count"],
        reverse=True,
    )

    return {
        "found": True,
        "checked_table_count": len(checked_tables),
        "flagged_column_count": sum(entry["column_count"] for entry in categories),
        "categories": categories,
    }


def _get_sql_security_overview():
    """DDM/CLS/RLS at the SQL level (dbo.bronze_column_security, dbo.bronze_
    row_level_security), as
    flat row lists for the Governance panel's own "RLS, CLS y DDM" tab --
    distinct from _get_column_security_lookup() above, which builds
    point-lookup dicts keyed for joining against a specific sensitivity
    sample, not for tabular display of everything discovered. Same
    "not live-tested yet" caveat as that function: these two bronze tables
    have never been populated by a real NB_Extract_SQL_Endpoint_Catalog.py
    run in this session, so `scanned` will read False until one has."""
    try:
        column_security_rows = warehouse.query_bronze_table("bronze_column_security")
    except warehouse.WarehouseError:
        column_security_rows = []
    try:
        row_level_security_rows = warehouse.query_bronze_table("bronze_row_level_security")
    except warehouse.WarehouseError:
        row_level_security_rows = []
    return {
        "scanned": bool(column_security_rows) or bool(row_level_security_rows),
        "column_security": column_security_rows,
        "row_level_security": row_level_security_rows,
    }


def _get_governance_scan_overview():
    """Scanner API results (scripts/73_discover_governance_scan.ps1):
    sensitivity labels, endorsement, tags, and semantic model RLS roles,
    plus the scan's own status/diagnosis rows -- the admin panel's
    Governance tab reads `status` to show exactly why a section is empty
    (blocked/error, with a human fix) instead of a silent blank table, same
    "record gaps, don't fabricate" convention as the rest of this project.

    Local-CSV only for now (no dbo.bronze_governance_* Warehouse table yet
    -- this hasn't been ported to the Fabric-native pipeline the way
    variable_library_catalog was; that's a known follow-up, not an
    oversight). Never raises: an admin who hasn't run the scan yet should
    see "not run yet", not a 500."""
    status_rows = _read_csv_rows(GOVERNANCE_SCAN_STATUS_PATH)
    if not status_rows:
        return {
            "found": False,
            "reason": "Governance scan has not been run yet -- run scripts/73_discover_governance_scan.ps1.",
            "status": [],
        }

    sensitivity_rows = [r for r in _read_csv_rows(GOVERNANCE_SENSITIVITY_LABELS_PATH) if r.get("qualified_name")]
    endorsement_rows = [r for r in _read_csv_rows(GOVERNANCE_ENDORSEMENT_PATH) if r.get("qualified_name")]
    tag_rows = [r for r in _read_csv_rows(GOVERNANCE_TAGS_PATH) if r.get("qualified_name")]
    rls_rows = [r for r in _read_csv_rows(GOVERNANCE_RLS_ROLES_PATH) if r.get("qualified_name")]

    rls_by_dataset = defaultdict(lambda: defaultdict(list))
    for row in rls_rows:
        rls_by_dataset[row.get("qualified_name", "")][row.get("role_name", "")].append(
            {
                "table_name": row.get("table_name", ""),
                "filter_expression": row.get("filter_expression", ""),
                "member_name": row.get("member_name", ""),
                "member_type": row.get("member_type", ""),
            }
        )
    rls_by_role = [
        {
            "qualified_name": qualified_name,
            "roles": [
                {"role_name": role_name, "entries": entries}
                for role_name, entries in roles.items()
            ],
        }
        for qualified_name, roles in rls_by_dataset.items()
    ]

    blocked_or_error = [row for row in status_rows if row.get("status") in ("blocked", "error")]

    sql_security = _get_sql_security_overview()

    return {
        "found": True,
        "last_scanned_at": max((row.get("checked_at", "") for row in status_rows), default=""),
        "status": status_rows,
        "has_blocking_issues": len(blocked_or_error) > 0,
        "sensitivity_labels": sensitivity_rows,
        "endorsement": endorsement_rows,
        "tags": tag_rows,
        "rls_by_dataset": sorted(rls_by_role, key=lambda entry: entry["qualified_name"]),
        "sql_security": sql_security,
        "counts": {
            "sensitivity_labels": len(sensitivity_rows),
            "endorsement": len(endorsement_rows),
            "tags": len(tag_rows),
            "rls_datasets": len(rls_by_role),
            "sql_column_security": len(sql_security["column_security"]),
            "sql_row_level_security": len(sql_security["row_level_security"]),
        },
    }
