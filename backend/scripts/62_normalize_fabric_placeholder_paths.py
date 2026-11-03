#!/usr/bin/env python3
"""Normalize Fabric notebook placeholder paths inside explorer JSON payloads.

The notebook parser can expose code constants such as
{LH_CONTOSOSALES_SILVER_PATH}/dbo/CUSTOMER. The canonical form used by the
web payload is Lakehouse.schema.object, with the raw placeholder kept in the
alias CSV for audit. Some notebook and CopyJob definitions also expose lower
case lakehouse id variables such as {sales_silver_lh_id}.dbo/Table or real
OneLake abfss paths; those are normalized here as well so the UI does not leak
technical placeholders.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ALIAS_PATH = ROOT / "analysis/notebook_lineage_path_aliases.csv"
DEFAULT_JSON_PATHS = [
    ROOT / "frontend/semantic-lineage/data/lineage-explorer.json",
    ROOT / "frontend/semantic-lineage/data/notebook-super-lineage.json",
    ROOT / "archive/lineage-explorer/data/lineage-explorer.json",
    ROOT / "archive/lineage-explorer/data/notebook-super-lineage.json",
    ROOT / "archive/lineage-explorer/data/deep-object-lineage.json",
    ROOT / "frontend/semantic-lineage/data/object-impact.json",
]
PLACEHOLDER_OBJECT_RE = re.compile(
    r"(?:\bFabricOrSQL\.)?\{(?P<token>[A-Za-z0-9_.]+)\}(?P<separator>[./])(?P<path>[^\s\"',;)]+)",
    re.IGNORECASE,
)
PLACEHOLDER_TOKEN_RE = re.compile(r"\{(?P<token>[A-Za-z0-9_.]+)\}")
ABFSS_PLACEHOLDER_RE = re.compile(
    r"abfss://\{(?P<workspace>[A-Za-z0-9_]+)_(?:WORKSPACE|WS)_ID\}@(?:msit-)?onelake\.dfs\.fabric\.microsoft\.com/"
    r"\{(?P<lakehouse>[A-Za-z0-9_]+)_(?:LAKEHOUSE|LH)_ID\}(?P<path>/[^\s\"',;)]*)?",
    re.IGNORECASE,
)
ABFSS_REAL_RE = re.compile(
    r"abfss://(?P<workspace>[^@/\s\"',;)]+)@(?:msit-)?onelake\.dfs\.fabric\.microsoft\.com/"
    r"(?P<lakehouse>[^/\s\"',;)]+)\.Lakehouse(?P<path>/[^\s\"',;)]*)?",
    re.IGNORECASE,
)
STRUCTURED_FIELDS = ("object_display_name", "object_name", "label")
GENERIC_UNRESOLVED_SOURCE_LABEL = "Origen pendiente"
NOTEBOOK_SOURCE_LABEL_REPLACEMENTS = {
    "notebook read sources": "Origen pendiente",
    "notebook write targets": "Destino pendiente",
    "notebook executed objects": "Objetos ejecutados",
    "notebook file inputs": "Archivos",
}
NOTEBOOK_INTERNAL_SOURCE_LABELS = {
    *NOTEBOOK_SOURCE_LABEL_REPLACEMENTS.keys(),
    "origen pendiente",
    "destino pendiente",
    "objetos ejecutados",
    "archivos",
    "unresolved source",
    "unresolved target",
    "executed objects",
    "files",
}
NOTEBOOK_SOURCE_ROLES = {"read", "write", "execute"}
AMBIGUOUS_TYPES = {
    "fabricorsql",
    "native_query_object",
    "table_or_view",
    "unknown",
    "",
}
LAKEHOUSE_SUFFIXES = (
    "_WORKSPACE_ID",
    "_WS_ID",
    "_LAKEHOUSE_ID",
    "_LH_ID",
    "_TABLES_PATH",
    "_TABLE_PATH",
    "_FILES_PATH",
    "_FILE_PATH",
    "_ABFSS_PATH",
    "_ONELAKE_PATH",
    "_PATH",
)
# Ejemplo ilustrativo: adapta esta lista a los sistemas de negocio que
# aparecen en los nombres de workspace/item de tu propio tenant, para
# normalizarlos a su forma "bonita".
FABRIC_TOKEN_WORDS = {
    "ADMINISTRATION": "Administration",
    "ADVENTUREWORKS": "AdventureWorks",
    "BRONZE": "Bronze",
    "CONTOSOHR": "ContosoHR",
    "DATAMART": "Datamart",
    "ECOMMERCE": "eCommerce",
    "FABRIKAMCRM": "FabrikamCRM",
    "FINANCE": "Finance",
    "GESTION": "Gestion",
    "GOLD": "Gold",
    "INTERNAL": "Internal",
    "NORTHWINDERP": "NorthwindERP",
    "OPERATIONS": "Operations",
    "SALES": "Sales",
    "SILVER": "Silver",
    "STAGING": "Staging",
    "SURVEY": "Survey",
}
FABRIC_TOKEN_ACRONYMS = {"API", "BI", "CRM", "ERP", "FT", "HR", "ID", "IT", "LH", "QA", "SQL"}


@dataclass(frozen=True)
class Alias:
    raw_identifier: str
    normalized_identifier: str
    source_type: str
    source_database: str
    schema_name: str
    object_name: str

    @property
    def object_label(self) -> str:
        return self.normalized_identifier


def read_aliases(path: Path) -> dict[str, Alias]:
    if not path.exists():
        raise FileNotFoundError(f"Alias file not found: {path}")
    aliases: dict[str, Alias] = {}
    with path.open(newline="", encoding="utf-8-sig") as handle:
        for row in csv.DictReader(handle):
            raw = (row.get("raw_identifier") or "").strip()
            normalized = (row.get("normalized_identifier") or "").strip()
            if not raw or not normalized:
                continue
            aliases[raw] = Alias(
                raw_identifier=raw,
                normalized_identifier=normalized,
                source_type=(row.get("source_type") or "").strip(),
                source_database=(row.get("source_database") or "").strip(),
                schema_name=(row.get("schema_name") or "").strip(),
                object_name=(row.get("object_name") or "").strip(),
            )
    return aliases


def pretty_token_part(value: str) -> str:
    upper = value.upper()
    if not upper:
        return ""
    if upper in FABRIC_TOKEN_WORDS:
        return FABRIC_TOKEN_WORDS[upper]
    if upper in FABRIC_TOKEN_ACRONYMS:
        return upper
    return value.title() if value.isupper() or value.islower() else value


def fabric_token_to_name(token: str) -> str:
    clean = re.sub(r"_+", "_", token.strip("{}")).strip("_")
    if "." in clean:
        clean = clean.split(".")[-1]
    upper = clean.upper()
    for suffix in LAKEHOUSE_SUFFIXES:
        if upper.endswith(suffix):
            clean = clean[: -len(suffix)]
            upper = clean.upper()
            break
    parts = [part for part in clean.split("_") if part]
    if parts and parts[0].upper() == "LH":
        body = "_".join(pretty_token_part(part) for part in parts[1:])
        return f"LH_{body}" if body else "LH_Unresolved"
    rendered = "_".join(pretty_token_part(part) for part in parts)
    return rendered or "Unresolved_Lakehouse"


def normalize_lakehouse_path(path: str) -> str:
    clean = (path or "").strip().strip("/")
    if not clean:
        return ""
    clean = re.sub(r"^Lakehouse/", "", clean, flags=re.IGNORECASE)
    clean = clean.replace("\\", "/").replace("/", ".")
    clean = re.sub(r"\.+", ".", clean).strip(".")
    return clean


def normalize_abfss_path(lakehouse: str, path: str) -> str:
    name = fabric_token_to_name(lakehouse)
    suffix = normalize_lakehouse_path(path)
    return f"{name}.{suffix}" if suffix else name


def replace_placeholder_object(match: re.Match[str], aliases: dict[str, Alias], stats: dict[str, int]) -> str:
    raw = match.group(0)
    alias = aliases.get(raw)
    if alias:
        stats["string_replacements"] += 1
        return alias.normalized_identifier
    token = match.group("token")
    path = normalize_lakehouse_path(match.group("path"))
    stats["derived_placeholder_replacements"] += 1
    store = fabric_token_to_name(token)
    return f"{store}.{path}" if path else store


def replace_placeholders(value: str, aliases: dict[str, Alias], stats: dict[str, int]) -> str:
    def replace_abfss(match: re.Match[str]) -> str:
        stats["abfss_replacements"] += 1
        return normalize_abfss_path(match.group("lakehouse"), match.group("path") or "")

    def replace_real_abfss(match: re.Match[str]) -> str:
        stats["abfss_replacements"] += 1
        return normalize_abfss_path(match.group("lakehouse"), match.group("path") or "")

    def replace_token(match: re.Match[str]) -> str:
        stats["token_replacements"] += 1
        return fabric_token_to_name(match.group("token"))

    normalized = ABFSS_PLACEHOLDER_RE.sub(replace_abfss, value)
    normalized = ABFSS_REAL_RE.sub(replace_real_abfss, normalized)
    normalized = PLACEHOLDER_OBJECT_RE.sub(lambda match: replace_placeholder_object(match, aliases, stats), normalized)
    normalized = PLACEHOLDER_TOKEN_RE.sub(replace_token, normalized)
    normalized = re.sub(r"\bFabricOrSQL\.", "", normalized, flags=re.IGNORECASE)
    normalized = re.sub(r"abfss://\{[A-Za-z0-9_]+", "ruta_onelake_parametrizada", normalized, flags=re.IGNORECASE)
    return normalized


def first_structured_alias(node: dict[str, Any], aliases: dict[str, Alias]) -> Alias | None:
    for field in STRUCTURED_FIELDS:
        value = node.get(field)
        if isinstance(value, str):
            alias = aliases.get(value.strip())
            if alias:
                return alias
    return None


def first_value(node: dict[str, Any], *names: str) -> str:
    for name in names:
        value = node.get(name)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def starts_with_prefix(value: str, prefix: str, separator: str = ".") -> bool:
    return bool(value and prefix and value.casefold().startswith(f"{prefix}{separator}".casefold()))


def ambiguous_type(value: Any) -> bool:
    return str(value or "").casefold() in AMBIGUOUS_TYPES


def is_notebook_internal_source_label(value: Any) -> bool:
    return str(value or "").strip().casefold() in NOTEBOOK_INTERNAL_SOURCE_LABELS


def notebook_source_replacement_label(value: Any) -> str:
    clean = str(value or "").strip()
    return NOTEBOOK_SOURCE_LABEL_REPLACEMENTS.get(clean.casefold(), clean)


def strip_notebook_internal_prefix(value: str) -> str:
    clean = (value or "").strip()
    for label in sorted(NOTEBOOK_INTERNAL_SOURCE_LABELS, key=len, reverse=True):
        for separator in (".", "/", " / "):
            prefix = f"{label}{separator}"
            if clean.casefold().startswith(prefix.casefold()):
                return clean[len(prefix) :].strip(" ./")
    return clean


def notebook_item_name_from_qualified_name(value: Any) -> str:
    parts = [part.strip() for part in str(value or "").split(" / ") if part.strip()]
    if len(parts) >= 5 and parts[-2].casefold() in NOTEBOOK_SOURCE_ROLES:
        return parts[-3]
    return ""


def looks_like_notebook_name(value: Any) -> bool:
    return bool(re.match(r"^(?:NB|Notebook)[_-]", str(value or "").strip(), flags=re.IGNORECASE))


def strip_exact_store_prefix(value: Any, store: str) -> str:
    clean = str(value or "").strip()
    if not clean or not store:
        return clean
    for separator in (".", "/", " / "):
        prefix = f"{store}{separator}"
        if clean.casefold().startswith(prefix.casefold()):
            return clean[len(prefix) :].strip(" ./")
    return clean


def first_parseable_label(node: dict[str, Any]) -> str:
    fields = (
        "object_display_name",
        "display_name",
        "label",
        "object_key",
        "source_object",
        "object_name",
    )
    for field in fields:
        value = node.get(field)
        if isinstance(value, str) and value.strip():
            clean = value.strip()
            if clean.casefold().startswith("file / "):
                clean = clean[7:].strip()
            clean = strip_notebook_internal_prefix(clean)
            clean = re.sub(r"^FabricOrSQL\.", "", clean, flags=re.IGNORECASE)
            if "." in clean or "/" in clean:
                return clean
    schema = first_value(node, "schema", "schema_name", "object_schema", "source_schema")
    object_name = first_value(node, "object_name", "source_object", "name")
    if schema and object_name and ("/" in object_name or "." in object_name):
        return f"{schema}.{object_name}"
    return ""


def parse_lakehouse_object_label(label: str) -> tuple[str, str, str] | None:
    clean = (label or "").strip()
    if not clean:
        return None
    clean = re.sub(r"^File\s*/\s*", "", clean, flags=re.IGNORECASE)
    clean = re.sub(r"^FabricOrSQL\.", "", clean, flags=re.IGNORECASE)
    clean = clean.replace("/", ".")
    clean = re.sub(r"\.+", ".", clean).strip(".")
    parts = [part.strip() for part in clean.split(".") if part.strip()]
    if len(parts) < 3:
        return None
    store, schema = parts[0], parts[1]
    object_name = ".".join(parts[2:])
    if not store or not schema or not object_name:
        return None
    if store.casefold() in {"fabricorsql", "file", "sql"}:
        return None
    return store, schema, object_name


def has_raw_lakehouse_placeholder(node: dict[str, Any]) -> bool:
    raw_text = " ".join(str(value) for value in node.values() if isinstance(value, str))
    return bool(
        re.search(r"\{[A-Za-z0-9_]+_(?:LH|LAKEHOUSE)_ID\}", raw_text, flags=re.IGNORECASE)
        or re.search(r"\{[A-Za-z0-9_]+_(?:TABLES?|FILES?|ONELAKE|ABFSS|PATH)", raw_text, flags=re.IGNORECASE)
        or ABFSS_REAL_RE.search(raw_text)
        or ABFSS_PLACEHOLDER_RE.search(raw_text)
    )


def set_if_present_or_blank(node: dict[str, Any], field: str, value: str) -> None:
    if field in node or not node.get(field):
        node[field] = value


def normalize_structured_lakehouse_fields(node: dict[str, Any], stats: dict[str, int], had_lakehouse_signal: bool) -> None:
    lakehouse_signal = had_lakehouse_signal or str(node.get("source_type") or node.get("raw_object_type") or "").casefold() == "lakehousetable"
    label = first_parseable_label(node)
    parsed = parse_lakehouse_object_label(label)
    if not parsed and lakehouse_signal:
        store = first_value(node, "database", "source_database", "source_name")
        object_name = first_value(node, "object_name", "source_object", "name")
        schema = first_value(node, "schema", "schema_name", "object_schema", "source_schema")
        if store and schema and object_name:
            parsed = parse_lakehouse_object_label(f"{store}.{schema}.{object_name}")
        elif schema and object_name:
            parsed = parse_lakehouse_object_label(f"{schema}.{object_name}")
    if not parsed:
        if lakehouse_signal:
            store = first_value(node, "label", "database", "source_database", "source_name")
            if store and "." not in store and "/" not in store and store.casefold() not in {"fabricorsql", "sql", "file"}:
                for field in ("database", "source_database", "source_name"):
                    if field in node:
                        node[field] = store
                stats["structured_lakehouse_nodes"] += 1
        if had_lakehouse_signal and ambiguous_type(node.get("source_type")):
            node["source_type"] = "LakehouseTable"
            stats["source_type_rewrites"] += 1
        return

    store, schema, object_name = parsed
    for field in ("database", "source_database", "source_name"):
        if field in node:
            node[field] = store
    for field in ("schema", "schema_name", "object_schema", "source_schema"):
        if field in node:
            node[field] = schema
    for field in ("object_name", "source_object"):
        if field in node:
            node[field] = object_name
    if "object_display_name" in node:
        node["object_display_name"] = f"{store}.{schema}.{object_name}"
    if "display_name" in node:
        node["display_name"] = f"{store}.{schema}.{object_name}"
    if "label" in node and ("object_name" in node or "object_display_name" in node or "source_object" in node):
        node["label"] = f"{store}.{schema}.{object_name}"

    if had_lakehouse_signal or ambiguous_type(node.get("source_type")):
        for field in ("source_type", "raw_object_type"):
            if field in node and ambiguous_type(node.get(field)):
                node[field] = "LakehouseTable"
                stats["source_type_rewrites"] += 1
        if "type" in node and ambiguous_type(node.get("type")):
            node["type"] = "table"
            stats["source_type_rewrites"] += 1
    stats["structured_lakehouse_nodes"] += 1


def canonical_object_label(node: dict[str, Any]) -> str:
    store = first_value(node, "database", "source_database", "source_name")
    if is_notebook_internal_source_label(store):
        store = ""
    schema = first_value(node, "schema", "schema_name", "object_schema", "source_schema")
    object_name = first_value(node, "object_name", "source_object", "name")
    raw_label = strip_notebook_internal_prefix(first_value(node, "object_display_name", "label", "qualified_name", "object_key"))
    source_type = first_value(node, "source_type", "raw_object_type")
    if not (object_name or raw_label):
        return ""
    raw_name = object_name or raw_label
    if store and (starts_with_prefix(raw_name, store) or starts_with_prefix(raw_label, store)):
        return raw_name if starts_with_prefix(raw_name, store) else raw_label
    if source_type == "File":
        if store and raw_name.casefold().startswith(f"{store}/".casefold()):
            return raw_name
        if store and object_name and "://" not in object_name:
            return f"{store}/{object_name.lstrip('/')}"
        return raw_label or raw_name
    if schema and starts_with_prefix(raw_name, schema):
        return f"{store}.{raw_name}" if store else raw_name
    if schema and starts_with_prefix(raw_label, schema):
        return f"{store}.{raw_label}" if store else raw_label
    if store and schema and object_name:
        return f"{store}.{schema}.{object_name}"
    if schema and object_name:
        return f"{schema}.{object_name}"
    if store and object_name:
        return f"{store}.{object_name}"
    return raw_label or raw_name


def normalize_notebook_internal_fields(node: dict[str, Any], stats: dict[str, int]) -> None:
    for field in ("label", "source_label"):
        value = node.get(field)
        if isinstance(value, str) and value.strip().casefold() in NOTEBOOK_SOURCE_LABEL_REPLACEMENTS:
            replacement = notebook_source_replacement_label(value)
            if replacement != value:
                node[field] = replacement
                stats["notebook_placeholder_labels"] += 1

    qualified_name = node.get("qualified_name")
    if isinstance(qualified_name, str):
        cleaned_qualified_name = qualified_name
        for old_label, replacement in NOTEBOOK_SOURCE_LABEL_REPLACEMENTS.items():
            cleaned_qualified_name = re.sub(
                re.escape(old_label),
                replacement,
                cleaned_qualified_name,
                flags=re.IGNORECASE,
            )
        if cleaned_qualified_name != qualified_name:
            node["qualified_name"] = cleaned_qualified_name
            stats["notebook_placeholder_labels"] += 1

    if node.get("item_type") != "NotebookObjectLineage":
        return

    item_name = notebook_item_name_from_qualified_name(node.get("qualified_name"))
    for field in ("database", "source_database", "source_name"):
        value = node.get(field)
        if not isinstance(value, str) or not value.strip():
            continue
        should_clear = is_notebook_internal_source_label(value)
        if item_name and value.strip().casefold() == item_name.casefold():
            should_clear = True
        if should_clear:
            node[field] = ""
            stats["notebook_placeholder_labels"] += 1


def normalize_notebook_name_pseudo_store(node: dict[str, Any], stats: dict[str, int]) -> None:
    store = first_value(node, "database", "source_database", "source_name")
    if not looks_like_notebook_name(store):
        return
    source_type = first_value(node, "source_type", "raw_object_type")
    schema = first_value(node, "schema", "schema_name", "object_schema", "source_schema")
    raw_label = first_value(node, "object_display_name", "label", "display_name", "object_key")
    object_name = first_value(node, "object_name", "source_object", "name")
    if not raw_label or not strip_exact_store_prefix(raw_label, store) != raw_label:
        return
    if schema or not (ambiguous_type(source_type) or source_type.casefold() == "fabricorsql"):
        return
    clean_label = strip_exact_store_prefix(raw_label, store)
    for field in ("database", "source_database", "source_name"):
        if isinstance(node.get(field), str) and node[field].strip().casefold() == store.casefold():
            node[field] = ""
            stats["notebook_pseudo_stores"] += 1
    for field in ("object_display_name", "label", "display_name"):
        if isinstance(node.get(field), str):
            cleaned = strip_exact_store_prefix(node[field], store)
            if cleaned != node[field]:
                node[field] = cleaned or object_name
                stats["notebook_pseudo_stores"] += 1


def normalize_object_label(node: dict[str, Any], stats: dict[str, int]) -> None:
    if not any(key in node for key in ("object_name", "object_display_name", "schema", "schema_name", "source_object")):
        return
    label = canonical_object_label(node)
    if not label:
        return
    for field in ("label", "object_display_name"):
        if field in node and isinstance(node.get(field), str) and node[field] != label:
            node[field] = label
            stats["canonical_labels"] += 1


def normalize_visible_fabricorsql_fields(node: dict[str, Any], stats: dict[str, int]) -> None:
    visible_fields = (
        "label",
        "database",
        "source_database",
        "source_name",
        "source_server",
        "object_display_name",
        "display_name",
        "object_name",
        "source_object",
    )
    for field in visible_fields:
        value = node.get(field)
        if not isinstance(value, str):
            continue
        has_visible_technical_value = "FabricOrSQL" in value or re.match(r"^(?:File\s*/\s*)?abfss://\{", value.strip(), flags=re.IGNORECASE)
        if not has_visible_technical_value:
            continue
        cleaned = re.sub(r"\bFabricOrSQL\.", "", value, flags=re.IGNORECASE).strip()
        cleaned = re.sub(r"^FabricOrSQL\s*/\s*", "", cleaned, flags=re.IGNORECASE).strip()
        cleaned = re.sub(r"\s*/\s*FabricOrSQL$", "", cleaned, flags=re.IGNORECASE).strip()
        if re.match(r"^(?:File\s*/\s*)?abfss://\{", cleaned, flags=re.IGNORECASE):
            cleaned = "Ruta OneLake parametrizada"
        if cleaned.casefold() == "fabricorsql":
            cleaned = GENERIC_UNRESOLVED_SOURCE_LABEL
        if cleaned != value:
            node[field] = cleaned
            stats["visible_fabricorsql_labels"] += 1
    qualified = node.get("qualified_name")
    if isinstance(qualified, str) and "FabricOrSQL" in qualified:
        cleaned = re.sub(r"\bFabricOrSQL\b", GENERIC_UNRESOLVED_SOURCE_LABEL, qualified, flags=re.IGNORECASE)
        cleaned = re.sub(r"\bFabricOrSQL\.", "", cleaned, flags=re.IGNORECASE)
        if cleaned != qualified:
            node["qualified_name"] = cleaned
            stats["visible_fabricorsql_labels"] += 1


def normalize_node(node: Any, aliases: dict[str, Alias], stats: dict[str, int]) -> Any:
    if isinstance(node, dict):
        had_lakehouse_signal = has_raw_lakehouse_placeholder(node)
        alias = first_structured_alias(node, aliases)
        if alias:
            if "source_type" in node:
                node["source_type"] = alias.source_type
            if "raw_object_type" in node and str(node.get("raw_object_type") or "").casefold() in {
                "fabricorsql",
                "native_query_object",
                "table_or_view",
                "unknown",
                "",
            }:
                node["raw_object_type"] = alias.source_type
            for field in ("database", "source_database", "source_name"):
                if field in node:
                    node[field] = alias.source_database
            for field in ("schema", "schema_name", "source_schema"):
                if field in node:
                    node[field] = alias.schema_name
            for field in ("object_name", "source_object"):
                if field in node:
                    node[field] = alias.object_name
            if "object_display_name" in node:
                node["object_display_name"] = alias.normalized_identifier
            if "label" in node:
                node["label"] = alias.object_label
            if "type" in node and alias.source_type == "LakehouseTable" and str(node.get("type") or "").casefold() in {
                "fabricorsql",
                "native_query_object",
                "table_or_view",
                "unknown",
                "",
            }:
                node["type"] = "table"
            stats["structured_nodes"] += 1
        for key, value in list(node.items()):
            node[key] = normalize_node(value, aliases, stats)
        normalize_structured_lakehouse_fields(node, stats, had_lakehouse_signal)
        normalize_visible_fabricorsql_fields(node, stats)
        normalize_notebook_internal_fields(node, stats)
        normalize_notebook_name_pseudo_store(node, stats)
        normalize_object_label(node, stats)
        return node
    if isinstance(node, list):
        for index, value in enumerate(node):
            node[index] = normalize_node(value, aliases, stats)
        return node
    if isinstance(node, str):
        return replace_placeholders(node, aliases, stats)
    return node


def normalize_json_file(path: Path, aliases: dict[str, Alias]) -> dict[str, int]:
    stats = {
        "structured_nodes": 0,
        "structured_lakehouse_nodes": 0,
        "string_replacements": 0,
        "derived_placeholder_replacements": 0,
        "token_replacements": 0,
        "abfss_replacements": 0,
        "source_type_rewrites": 0,
        "visible_fabricorsql_labels": 0,
        "canonical_labels": 0,
        "notebook_placeholder_labels": 0,
        "notebook_pseudo_stores": 0,
    }
    if not path.exists():
        return {**stats, "missing": 1}
    payload = json.loads(path.read_text(encoding="utf-8"))
    normalize_node(payload, aliases, stats)
    # These are the exact files the web frontend loads live over the shared
    # tunnel (lineage-explorer.json, object-impact.json, notebook-super-
    # lineage.json) -- write to a temp file and atomically replace so a
    # concurrent read never sees a truncated file mid-write. Compact, not
    # indent=2: nobody reads this file by hand, only JSON.parse() does, and
    # two-space-per-level indentation on a deeply nested structure this size
    # (workspaces -> items -> sources -> objects -> columns) adds 30-50%+
    # pure whitespace with zero functional benefit -- on a large tenant
    # that whitespace alone can push the file past what the browser can
    # load at all.
    tmp_path = path.with_name(path.name + ".tmp")
    tmp_path.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    tmp_path.replace(path)
    return stats


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--aliases", type=Path, default=DEFAULT_ALIAS_PATH)
    parser.add_argument("paths", nargs="*", type=Path, default=DEFAULT_JSON_PATHS)
    args = parser.parse_args()

    aliases = read_aliases(args.aliases)
    print(f"Aliases loaded: {len(aliases)}")
    for path in args.paths:
        stats = normalize_json_file(path, aliases)
        print(
            f"{path}: structured_nodes={stats['structured_nodes']} "
            f"structured_lakehouse_nodes={stats['structured_lakehouse_nodes']} "
            f"string_replacements={stats['string_replacements']} "
            f"derived_placeholder_replacements={stats['derived_placeholder_replacements']} "
            f"token_replacements={stats['token_replacements']} "
            f"abfss_replacements={stats['abfss_replacements']} "
            f"source_type_rewrites={stats['source_type_rewrites']} "
            f"visible_fabricorsql_labels={stats['visible_fabricorsql_labels']} "
            f"canonical_labels={stats['canonical_labels']} "
            f"notebook_placeholder_labels={stats['notebook_placeholder_labels']} "
            f"notebook_pseudo_stores={stats['notebook_pseudo_stores']} missing={stats.get('missing', 0)}"
        )


if __name__ == "__main__":
    main()
