"""Lineage-usage analytics -- what the admin panel's
"Analíticas" tab is named for: real usage of the EXPLORER (which items people look at, how often,
by whom) instead of just raw server-request counts (still shown too, see
observability.py, since it's cheap and already useful for debugging).

Lives in its own Warehouse table (bronze_usage_events), same pattern as
collaboration.py's node_comments/node_favorites -- this web server owns
and writes to it directly, no local-CSV fallback (this feature only makes
sense once a Warehouse write target is configured).

Deliberately NOT a row per HTTP request (observability.py's in-memory
_request_counts already covers that cheaply) -- only a small, curated set
of MEANINGFUL user actions get a row here, one per frontend call to
_record_usage_event: an item's detail panel opening (see app.js's
selectNode -> trackUsageEvent). Keeping the event list short is a
deliberate cost/volume control for a Warehouse this project also expects
to run on Render's free tier -- a row per keystroke or per poll would
make this table grow far faster than it needs to for the insights it's
meant to answer (busiest items, usage trend, active users)."""
import json

from . import warehouse
from .utils import _now_iso

# Recorded event types -- keep this list short and additive; each new type
# needs a real question it answers on the Analíticas tab, not "might be
# useful someday" (see this module's own docstring on write-volume care).
# mcp_tool_call was added alongside the remote MCP server
# (mcp_http_server.py): "is anyone actually using this, and with what" is
# exactly the kind of real question this table exists to answer, and
# reuses the same 5 columns with no schema change -- qualified_name holds
# the tool name (e.g. "list_workspaces"), item_type is the constant
# "mcp_tool" tag, user_email holds "mcp:<api key name>" (an MCP caller has
# no Entra session, only the API key it authenticated with).
EVENT_TYPES = {"item_view", "mcp_tool_call"}

USAGE_EVENT_COLUMNS = ["event_type", "qualified_name", "item_type", "user_email", "occurred_at"]
_USAGE_EVENT_TABLE_DDL = (
    "CREATE TABLE dbo.bronze_usage_events ("
    "[event_type] VARCHAR(32), [qualified_name] VARCHAR(8000), [item_type] VARCHAR(64), "
    "[user_email] VARCHAR(320), [occurred_at] VARCHAR(64))"
)

# Same order-of-magnitude guard as collaboration.py's MAX_COMMENT_LENGTH --
# a qualified_name is normally well under this; this only exists so a
# malformed/adversarial client body can't blow up the VARCHAR(8000) column.
MAX_QUALIFIED_NAME_LENGTH = 4000


def record_usage_event(event_type, qualified_name, item_type, session):
    """Best-effort: never raises, a tracking call must never break the
    actual feature it's instrumenting (see app.js's trackUsageEvent, which
    also never awaits or surfaces this call's outcome to the user).
    Silently drops anything not in EVENT_TYPES rather than growing the
    table with typos/unexpected values from a future frontend change that
    forgot to update EVENT_TYPES too."""
    if event_type not in EVENT_TYPES:
        return
    row = {
        "event_type": event_type,
        "qualified_name": (qualified_name or "")[:MAX_QUALIFIED_NAME_LENGTH],
        "item_type": (item_type or "")[:64],
        "user_email": session["user_email"] if session else "",
        "occurred_at": _now_iso(),
    }
    try:
        warehouse.append_bronze_rows("bronze_usage_events", USAGE_EVENT_COLUMNS, [row], create_table_ddl=_USAGE_EVENT_TABLE_DDL)
    except warehouse.WarehouseError:
        pass


def get_usage_analytics(top_n=10, days=30):
    """Tenant-wide rollup for the admin panel's Analíticas tab. found=False
    (not an empty result) when the Warehouse has no bronze_usage_events
    rows yet -- either nothing has been viewed since this shipped, or
    (more likely early on) this is the first load before any real usage
    accumulates; the frontend shows an explanatory hint either way rather
    than a misleading all-zero dashboard."""
    try:
        rows = warehouse.query_bronze_table("bronze_usage_events", use_cache=False)
    except warehouse.WarehouseError as exc:
        return {"found": False, "reason": f"Warehouse read failed: {exc}"}
    if not rows:
        return {"found": False, "reason": "No hay eventos de uso registrados todavía."}

    item_view_counts = {}
    events_by_day = {}
    users = set()
    for row in rows:
        day = (row.get("occurred_at") or "")[:10]
        if day:
            events_by_day[day] = events_by_day.get(day, 0) + 1
        user_email = row.get("user_email") or ""
        if user_email:
            users.add(user_email)
        if row.get("event_type") == "item_view":
            key = (row.get("qualified_name") or "", row.get("item_type") or "")
            item_view_counts[key] = item_view_counts.get(key, 0) + 1

    top_items = sorted(
        (
            {"qualified_name": qn, "item_type": item_type, "view_count": count}
            for (qn, item_type), count in item_view_counts.items()
            if qn
        ),
        key=lambda entry: entry["view_count"],
        reverse=True,
    )[:top_n]

    daily_series = sorted(
        ({"day": day, "count": count} for day, count in events_by_day.items()),
        key=lambda entry: entry["day"],
    )[-days:]

    return {
        "found": True,
        "total_event_count": len(rows),
        "unique_user_count": len(users),
        "top_items": top_items,
        "daily_series": daily_series,
    }


def get_mcp_usage_analytics(days=30):
    """Same bronze_usage_events table as get_usage_analytics, filtered to
    mcp_tool_call rows -- who is actually calling the remote MCP server
    (backend/scripts/mcp_http_server.py), with what tool, how often. Same
    found=False-not-empty-dashboard contract as get_usage_analytics."""
    try:
        rows = warehouse.query_bronze_table("bronze_usage_events", use_cache=False)
    except warehouse.WarehouseError as exc:
        return {"found": False, "reason": f"Warehouse read failed: {exc}"}
    mcp_rows = [row for row in rows if row.get("event_type") == "mcp_tool_call"]
    if not mcp_rows:
        return {"found": False, "reason": "No hay llamadas MCP registradas todavía."}

    calls_by_tool = {}
    calls_by_caller = {}
    events_by_day = {}
    for row in mcp_rows:
        tool_name = row.get("qualified_name") or "(desconocida)"
        calls_by_tool[tool_name] = calls_by_tool.get(tool_name, 0) + 1
        # "mcp:<api key name>" -- see EVENT_TYPES' own comment on why
        # user_email holds this instead of a real email for this event type.
        caller = (row.get("user_email") or "mcp:?")[4:] or "?"
        calls_by_caller[caller] = calls_by_caller.get(caller, 0) + 1
        day = (row.get("occurred_at") or "")[:10]
        if day:
            events_by_day[day] = events_by_day.get(day, 0) + 1

    daily_series = sorted(
        ({"day": day, "count": count} for day, count in events_by_day.items()),
        key=lambda entry: entry["day"],
    )[-days:]

    return {
        "found": True,
        "total_call_count": len(mcp_rows),
        "unique_caller_count": len(calls_by_caller),
        "calls_by_tool": sorted(
            ({"tool_name": name, "call_count": count} for name, count in calls_by_tool.items()),
            key=lambda entry: entry["call_count"], reverse=True,
        ),
        "calls_by_caller": sorted(
            ({"caller": name, "call_count": count} for name, count in calls_by_caller.items()),
            key=lambda entry: entry["call_count"], reverse=True,
        ),
        "daily_series": daily_series,
    }
