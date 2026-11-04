#!/usr/bin/env python3
"""Publishes the big generated JSON payloads the web frontend loads
(lineage-explorer.json and friends) to a Fabric Lakehouse's OneLake Files
area, so lineage_web_server.py can serve them live from there
(admin_settings.json -> onelake_data.mode = "onelake") instead of needing
this machine's local disk.

This does NOT move the JSON-BUILDING logic into Fabric -- it publishes
whatever backend/scripts/11_build_lineage_explorer_fast.py,
21_build_reverse_impact_package_fast.py, 52_build_notebook_super_
lineage.py, and build_graph_map_index.py already built locally, unchanged.
Run this after (or as part of) a normal refresh, same idea as
64_upload_bronze_to_onelake.py for the CSV entities.

Landing shape: Files/generated/<filename> -- always overwritten in place
(these are current-snapshot artifacts, not dated partitions like the
bronze CSVs 64 uploads).

--dry-run needs nothing beyond the standard library (no Azure SDK import,
no network call), same as 64's own --dry-run.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_ADMIN_SETTINGS_PATH = REPO_ROOT / "config" / "admin_settings.json"
DATA_DIR = REPO_ROOT / "frontend" / "semantic-lineage" / "data"
MANIFEST_PATH = REPO_ROOT / "analysis" / "onelake_web_data_publish_manifest.csv"
MANIFEST_FIELDS = ["filename", "source_path", "target_path", "bytes", "status", "error", "published_at"]

# The only files the frontend actually fetches (confirmed by
# grepping app.js/graph-map-data.js for `./data/*.json` -- semantic-
# lineage.json, also under data/, is an intermediate build artifact with
# no browser consumer and is deliberately not published here).
PUBLISHED_FILENAMES = [
    "lineage-explorer.json",
    "object-impact.json",
    "notebook-super-lineage.json",
    "graph-map-index.json",
    "graph-map-index-objects.json",
]

ONELAKE_RESOURCE = "https://storage.azure.com/.default"


def _now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def load_onelake_config(admin_settings_path: Path) -> dict:
    if not admin_settings_path.exists():
        raise SystemExit(
            f"Admin settings not found: {admin_settings_path}\n"
            "Copy config/admin_settings.example.json to config/admin_settings.json and fill in "
            "the onelake_data block (workspace_name, lakehouse_name) from the admin panel first."
        )
    with open(admin_settings_path, "r", encoding="utf-8") as handle:
        settings = json.load(handle)
    return settings.get("onelake_data") or {}


def config_is_ready(config: dict) -> bool:
    return bool(config.get("workspace_name") and config.get("lakehouse_name"))


def write_manifest(rows: list[dict]) -> None:
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(MANIFEST_PATH, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=MANIFEST_FIELDS, quoting=csv.QUOTE_ALL)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def upload_one(file_system_client, source_path: Path, target_path: str) -> None:
    directory_path, file_name = target_path.rsplit("/", 1)
    directory_client = file_system_client.get_directory_client(directory_path)
    directory_client.create_directory()
    file_client = directory_client.create_file(file_name)
    data = source_path.read_bytes()
    file_client.upload_data(data, overwrite=True)


def run(args: argparse.Namespace) -> int:
    config = load_onelake_config(Path(args.admin_settings))
    filenames = [args.only] if args.only else list(PUBLISHED_FILENAMES)

    ready = config_is_ready(config)
    if not ready and not args.dry_run:
        raise SystemExit(
            f"{args.admin_settings}'s onelake_data block has no workspace_name/lakehouse_name yet -- "
            "nothing to publish to. Run with --dry-run to preview, or fill it in from the admin "
            "panel's Explorer data (OneLake) tab first."
        )

    file_system_client = None
    if not args.dry_run:
        # Imported lazily, same reasoning as 64_upload_bronze_to_onelake.py:
        # --dry-run should never require the Azure SDK to be installed.
        from azure.identity import AzureCliCredential
        from azure.storage.filedatalake import DataLakeServiceClient

        credential = AzureCliCredential()
        service_client = DataLakeServiceClient(
            account_url="https://onelake.dfs.fabric.microsoft.com",
            credential=credential,
        )
        file_system_client = service_client.get_file_system_client(config["workspace_name"])

    manifest_rows = []
    had_failure = False
    for filename in filenames:
        source_path = DATA_DIR / filename
        target_path = f"{config.get('workspace_name') or '<workspace>'}/{config.get('lakehouse_name') or '<lakehouse>'}.Lakehouse/Files/generated/{filename}"
        row = {"filename": filename, "source_path": str(source_path.relative_to(REPO_ROOT)), "target_path": target_path, "bytes": "", "status": "", "error": "", "published_at": ""}

        if not source_path.exists():
            row["status"] = "skipped_missing_source"
            manifest_rows.append(row)
            print(f"[skip] {filename}: source not found at {row['source_path']} -- build it first.")
            continue

        row["bytes"] = str(source_path.stat().st_size)

        if args.dry_run:
            row["status"] = "dry_run"
            manifest_rows.append(row)
            print(f"[dry-run] {filename}: {row['bytes']} bytes -> {target_path}")
            continue

        try:
            lakehouse_relative_target = target_path.split("/", 1)[1]
            upload_one(file_system_client, source_path, lakehouse_relative_target)
            row["status"] = "published"
            row["published_at"] = _now_iso()
            print(f"[ok] {filename}: published {row['bytes']} bytes -> {target_path}")
        except Exception as exc:  # noqa: BLE001 - one file failing must not abort the rest
            row["status"] = "failed"
            row["error"] = str(exc)
            had_failure = True
            print(f"[fail] {filename}: {exc}")

        manifest_rows.append(row)

    write_manifest(manifest_rows)
    print(f"Manifest: {MANIFEST_PATH.relative_to(REPO_ROOT)}")
    return 1 if had_failure else 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--admin-settings", default=str(DEFAULT_ADMIN_SETTINGS_PATH))
    parser.add_argument("--only", default=None, help="Publish a single filename instead of all of them (e.g. object-impact.json)")
    parser.add_argument("--dry-run", action="store_true", help="Preview without needing Azure auth or the Lakehouse to exist")
    args = parser.parse_args()
    sys.exit(run(args))


if __name__ == "__main__":
    main()
