"""Comments and favorites on catalog nodes (roadmap Nivel 1, 2026-08-17) --
the lightest-weight collaborative layer identified in the competitive
research (the Castor Docs pattern): treat each workspace/item/object as
something people can comment on and bookmark, not just a read-only
record.

Lives entirely in two Warehouse tables this web server itself owns and
writes to directly via warehouse.append_bronze_rows/delete_bronze_rows --
there is no local-CSV fallback mode the way catalog.py's scan-produced
data has, since this feature only makes sense once a Warehouse write
target is configured (see the admin panel's "Almacén de escritura" tab).
Every read here bypasses query_bronze_table's cache (use_cache=False):
comments/favorites are low-volume, interactive data where a user posting
a comment expects to see it appear immediately, not up to 5 minutes
later.
"""
import secrets

from . import warehouse
from .utils import _now_iso

COMMENT_COLUMNS = ["comment_id", "qualified_name", "author_email", "author_name", "comment_text", "created_at"]
_COMMENT_TABLE_DDL = (
    "CREATE TABLE dbo.node_comments ("
    "[comment_id] VARCHAR(64), [qualified_name] VARCHAR(8000), [author_email] VARCHAR(320), "
    "[author_name] VARCHAR(400), [comment_text] VARCHAR(8000), [created_at] VARCHAR(64))"
)

FAVORITE_COLUMNS = ["qualified_name", "user_email", "created_at"]
_FAVORITE_TABLE_DDL = (
    "CREATE TABLE dbo.node_favorites ("
    "[qualified_name] VARCHAR(8000), [user_email] VARCHAR(320), [created_at] VARCHAR(64))"
)

# Same limit the frontend's own textarea enforces client-side -- kept here
# too so the API rejects an oversized body instead of silently truncating
# it at the VARCHAR(8000) column boundary.
MAX_COMMENT_LENGTH = 4000


def get_comments(qualified_name):
    try:
        rows = warehouse.query_bronze_table("node_comments", use_cache=False)
    except warehouse.WarehouseError:
        # Most common cause: dbo.node_comments doesn't exist yet because no
        # one has ever posted a comment -- append_bronze_rows creates it on
        # first write, same "nothing to show yet" as every other empty
        # bronze-backed view in this project.
        return []
    matching = [row for row in rows if row.get("qualified_name") == qualified_name]
    matching.sort(key=lambda row: row.get("created_at", ""))
    return matching


def add_comment(qualified_name, author_email, author_name, comment_text):
    row = {
        "comment_id": secrets.token_urlsafe(12),
        "qualified_name": qualified_name,
        "author_email": author_email,
        "author_name": author_name,
        "comment_text": comment_text,
        "created_at": _now_iso(),
    }
    warehouse.append_bronze_rows("node_comments", COMMENT_COLUMNS, [row], create_table_ddl=_COMMENT_TABLE_DDL)
    return row


def delete_comment(comment_id, requester_email, requester_is_admin):
    """Returns (ok, error_code). error_code is "" on success, "not_found",
    or "forbidden" (the requester is neither the comment's own author nor
    an admin)."""
    try:
        all_rows = warehouse.query_bronze_table("node_comments", use_cache=False)
    except warehouse.WarehouseError:
        return False, "not_found"
    match = next((row for row in all_rows if row.get("comment_id") == comment_id), None)
    if match is None:
        return False, "not_found"
    if match.get("author_email") != requester_email and not requester_is_admin:
        return False, "forbidden"
    warehouse.delete_bronze_rows("node_comments", {"comment_id": comment_id})
    return True, ""


def get_my_favorites(user_email):
    try:
        rows = warehouse.query_bronze_table("node_favorites", use_cache=False)
    except warehouse.WarehouseError:
        return []
    return sorted({row.get("qualified_name", "") for row in rows if row.get("user_email") == user_email} - {""})


def toggle_favorite(qualified_name, user_email):
    """Returns the new state: True if now favorited, False if just removed."""
    try:
        rows = warehouse.query_bronze_table("node_favorites", use_cache=False)
    except warehouse.WarehouseError:
        rows = []
    already = any(row.get("qualified_name") == qualified_name and row.get("user_email") == user_email for row in rows)
    if already:
        warehouse.delete_bronze_rows("node_favorites", {"qualified_name": qualified_name, "user_email": user_email})
        return False
    warehouse.append_bronze_rows(
        "node_favorites", FAVORITE_COLUMNS,
        [{"qualified_name": qualified_name, "user_email": user_email, "created_at": _now_iso()}],
        create_table_ddl=_FAVORITE_TABLE_DDL,
    )
    return True
