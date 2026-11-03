"""Phase 70 - Control-framework runtime lineage extraction.

In many tenants a large share of notebooks/copyjobs are metadata-driven: their code names
no target tables (static parsing yields "Destino pendiente"), because what
gets loaded where is decided at runtime from each lakehouse's control schema.
But that same framework LOGS every run into control.TableStatus with the
full source table, full target table and the executing notebook's name
(ExecutedBy = "NB_Load_OrderList_2026/07/14-06:57:25") -- runtime lineage
evidence stronger than any code parse.

This script connects to every SQL analytics endpoint in the endpoint catalog
whose database exposes a control-schema status table, reads ONLY that
framework metadata (table names, run timestamps -- no business data), and
emits rows in the exact column shape of item_object_lineage_candidates.csv
so 11_build_lineage_explorer_fast.py can ingest them through the existing
--control-framework-candidates-path input with zero new parsing machinery.

Auth: Azure CLI AAD token for https://database.windows.net (never printed).
"""
import argparse
import csv
import re
import struct
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

STATUS_TABLE_NAMES = {"tablestatus", "status"}
EXECUTED_BY_SUFFIX = re.compile(r"[_ ]\d{4}/\d{2}/\d{2}[- ]\d{2}:\d{2}(:\d{2})?$")


def get_token(az_command):
    result = subprocess.run(
        [az_command, "account", "get-access-token", "--resource", "https://database.windows.net",
         "--query", "accessToken", "-o", "tsv"],
        capture_output=True, text=True, shell=True, timeout=120,
    )
    if result.returncode != 0:
        raise RuntimeError(f"az token acquisition failed: {result.stderr.strip()[:300]}")
    return result.stdout.strip()


def token_struct(token):
    raw = token.encode("utf-16-le")
    return struct.pack(f"<I{len(raw)}s", len(raw), raw)


def parse_full_table(value):
    """'LH_X.dbo.Table' -> (database, schema, object); tolerate 2/1-part forms."""
    parts = [p.strip() for p in str(value or "").split(".") if p.strip()]
    if len(parts) >= 3:
        return parts[0], parts[1], ".".join(parts[2:])
    if len(parts) == 2:
        return "", parts[0], parts[1]
    if len(parts) == 1:
        return "", "", parts[0]
    return "", "", ""


def notebook_name_from_executed_by(value):
    clean = str(value or "").strip()
    if not clean:
        return ""
    return EXECUTED_BY_SUFFIX.sub("", clean).strip("_ ").strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint-catalog-path", default=str(REPO_ROOT / "analysis/sql_endpoint_object_catalog.csv"))
    parser.add_argument("--items-path", default=str(REPO_ROOT / "index/items.csv"))
    parser.add_argument("--output-path", default=str(REPO_ROOT / "analysis/control_framework_lineage_candidates.csv"))
    parser.add_argument("--gaps-path", default=str(REPO_ROOT / "analysis/control_framework_lineage_gaps.csv"))
    parser.add_argument("--az-command", default="az")
    parser.add_argument("--connect-timeout-seconds", type=int, default=15)
    args = parser.parse_args()

    try:
        import pyodbc
    except ImportError:
        sys.exit("pyodbc is required (use the Python 3.12 install; see project notes on multiple Pythons).")

    with open(args.endpoint_catalog_path, encoding="utf-8-sig", newline="") as handle:
        catalog = list(csv.DictReader(handle))
    with open(args.items_path, encoding="utf-8-sig", newline="") as handle:
        items = [r for r in csv.DictReader(handle) if r.get("status") == "discovered"]

    notebooks_by_name = defaultdict(list)
    items_by_technical_id = {}
    for row in items:
        if row.get("item_type") == "Notebook":
            notebooks_by_name[row.get("item_name", "").strip().lower()].append(row)
        technical_id = (row.get("technical_id") or "").strip().lower()
        if technical_id:
            items_by_technical_id[technical_id] = row

    # (server, database, owner workspace) -> set of control status tables
    targets = {}
    for row in catalog:
        if (row.get("schema_name") or "").strip().lower() != "control":
            continue
        if (row.get("object_name") or "").strip().lower() not in STATUS_TABLE_NAMES:
            continue
        key = (row.get("source_server", ""), row.get("source_database", ""), row.get("workspace_name", ""))
        targets.setdefault(key, set()).add(row.get("object_name"))

    print(f"Control status tables found in endpoint catalog: {len(targets)} databases")
    token = token_struct(get_token(args.az_command))

    out_rows = []
    gaps = []
    for (server, database, owner_workspace), tables in sorted(targets.items()):
        for table in sorted(tables):
            try:
                connection = pyodbc.connect(
                    f"DRIVER={{ODBC Driver 17 for SQL Server}};SERVER={server};DATABASE={database};Encrypt=yes",
                    attrs_before={1256: token}, timeout=args.connect_timeout_seconds,
                )
                cursor = connection.cursor()
                cursor.execute(f"SELECT * FROM control.[{table}]")
                columns = {d[0].lower(): i for i, d in enumerate(cursor.description)}
                if "targettable" not in columns or "executedby" not in columns:
                    gaps.append({"server": server, "database": database, "table": table,
                                 "reason": f"columns not usable: {sorted(columns)}"})
                    connection.close()
                    continue
                # newest run wins per (notebook, source, target)
                latest = {}
                for row in cursor.fetchall():
                    notebook = notebook_name_from_executed_by(row[columns["executedby"]])
                    target = str(row[columns["targettable"]] or "").strip()
                    source = str(row[columns["sourcetable"]] or "").strip() if "sourcetable" in columns else ""
                    status = str(row[columns["status"]] or "").strip() if "status" in columns else ""
                    executed = str(row[columns["executedatutc"]] or "").strip() if "executedatutc" in columns else ""
                    if not notebook or not target:
                        continue
                    key = (notebook, source, target)
                    if key not in latest or executed > latest[key][0]:
                        latest[key] = (executed, status)
                connection.close()
            except Exception as error:  # noqa: BLE001 - per-endpoint isolation
                gaps.append({"server": server, "database": database, "table": table,
                             "reason": str(error)[:300]})
                continue

            for (notebook, source, target), (executed, status) in latest.items():
                # Some framework generations log the executing item's GUID
                # ("Notebook_<guid>" or a bare guid) instead of its name --
                # resolvable against the item index's technical ids.
                guid_match = re.search(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", notebook)
                if guid_match and items_by_technical_id.get(guid_match.group(0).lower()):
                    candidates = [items_by_technical_id[guid_match.group(0).lower()]]
                else:
                    candidates = notebooks_by_name.get(notebook.lower(), [])
                same_workspace = [c for c in candidates if c.get("workspace_name") == owner_workspace]
                chosen = same_workspace[0] if same_workspace else (candidates[0] if len(candidates) == 1 else None)
                if chosen is None:
                    gaps.append({"server": server, "database": database, "table": table,
                                 "reason": f"notebook '{notebook}' {'ambiguous across workspaces' if candidates else 'not found in items'}"})
                    continue
                evidence_base = (
                    f"control.{table} runtime log on {database} (ExecutedBy={notebook}, "
                    f"last run {executed or 'unknown'}, status {status or 'unknown'})."
                )
                for raw, usage in ((source, "reads_from"), (target, "writes_to")):
                    if not raw:
                        continue
                    obj_db, obj_schema, obj_name = parse_full_table(raw)
                    if not obj_name:
                        continue
                    out_rows.append({
                        "workspace_name": chosen.get("workspace_name", ""),
                        "workspace_environment": chosen.get("workspace_environment", ""),
                        "item_type": chosen.get("item_type", "Notebook"),
                        "item_name": chosen.get("item_name", ""),
                        "item_qualified_name": chosen.get("qualified_name", ""),
                        "source_type": "LakehouseTable",
                        "source_name": obj_db or database,
                        "source_qualified_name": "",
                        # the lakehouse named inside the control row lives in the
                        # same workspace as the endpoint that logged it unless the
                        # frontend's owner resolution says otherwise
                        "source_server": owner_workspace,
                        "source_database": obj_db or database,
                        "schema_name": obj_schema,
                        "object_name": obj_name,
                        "object_type": "table",
                        "usage_type": usage,
                        "confidence": "confirmed",
                        "definition_path": f"control.{table}@{database}",
                        "evidence": evidence_base,
                    })

    out_path = Path(args.output_path)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    columns = ["workspace_name", "workspace_environment", "item_type", "item_name", "item_qualified_name",
               "source_type", "source_name", "source_qualified_name", "source_server", "source_database",
               "schema_name", "object_name", "object_type", "usage_type", "confidence", "definition_path", "evidence"]
    with open(out_path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=columns)
        writer.writeheader()
        writer.writerows(out_rows)

    gaps_path = Path(args.gaps_path)
    with open(gaps_path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=["server", "database", "table", "reason"])
        writer.writeheader()
        writer.writerows(gaps)

    notebooks = {r["item_qualified_name"] for r in out_rows}
    print("Control framework lineage extraction completed.")
    print(f"Lineage rows: {len(out_rows)} (notebooks resolved: {len(notebooks)})")
    print(f"Gaps: {len(gaps)}")
    print(f"Output: {out_path}")
    print(f"Gaps file: {gaps_path}")


if __name__ == "__main__":
    main()
