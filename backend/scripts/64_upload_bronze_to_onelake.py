#!/usr/bin/env python3
"""Uploads the project's own CSV outputs (index/, analysis/) into a Fabric
Lakehouse's OneLake Files/ area, as one dated Bronze partition per entity.

Read-only against the many tenant workspaces this project scans -- this
script never touches those. It writes only into the single, project-owned
Lakehouse recorded in config/lakehouse_target.json (see
docs/101_medallion_lakehouse_provisioning.md), which nothing else in this
repository has ever written to before.

Landing shape: Files/bronze/<entity>/snapshot_date=<YYYY-MM-DD>/<entity>.csv
-- one immutable partition per entity per day. A Fabric notebook
(NB_Bronze_Silver_Gold_Build) reads these partitions and builds the Bronze/
Silver/Gold Delta tables; this script's job ends at "the file is visible in
OneLake."

--dry-run needs nothing beyond the standard library (no Azure SDK import,
no network call) so the whole flow -- entity list, file sizes, target
paths -- can be exercised and reviewed before config/lakehouse_target.json
is filled in with a real workspace/Lakehouse.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from datetime import date, datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_CONFIG_PATH = REPO_ROOT / "config" / "lakehouse_target.json"
MANIFEST_PATH = REPO_ROOT / "analysis" / "onelake_bronze_upload_manifest.csv"
MANIFEST_FIELDS = ["entity", "source_path", "target_path", "bytes", "status", "error", "uploaded_at"]

# entity name -> source CSV path, relative to the repo root. This is the
# full set from docs/101_medallion_lakehouse_provisioning.md's Bronze
# entity list -- every item/object/execution/governance table the project
# produces, not just object-level lineage.
ENTITY_SOURCE_PATHS = {
    "workspaces": "index/workspaces.csv",
    "items": "index/items.csv",
    "item_analysis": "index/item_analysis.csv",
    "dependencies": "index/dependencies.csv",
    "executions": "index/executions.csv",
    "object_column_catalog": "analysis/object_column_catalog.csv",
    "variable_library_catalog": "analysis/variable_library_catalog.csv",
    "object_impact_index": "analysis/object_impact_index.csv",
    "object_read_write_classification": "analysis/object_read_write_classification.csv",
    "notebook_super_lineage_objects": "analysis/notebook_super_lineage_objects.csv",
    "notebook_super_lineage_flows": "analysis/notebook_super_lineage_flows.csv",
    "semantic_model_datamart_dependencies": "analysis/semantic_model_datamart_dependencies.csv",
    "semantic_model_report_dependencies": "analysis/semantic_model_report_dependencies.csv",
    "workspace_governance_principals": "analysis/workspace_governance_principals.csv",
    "deployment_pipelines": "index/deployment_pipelines.csv",
    "deployment_pipeline_stages": "index/deployment_pipeline_stages.csv",
    "deployment_pipeline_stage_items": "index/deployment_pipeline_stage_items.csv",
    "source_object_type_overrides": "index/source_object_type_overrides.csv",
    "manual_lineage_object_evidence": "index/manual_lineage_object_evidence.csv",
    "source_object_type_metadata_evidence": "analysis/source_object_type_metadata_evidence.csv",
    "sql_endpoint_object_catalog": "analysis/sql_endpoint_object_catalog.csv",
    # Permanent added/removed/modified audit trail across scans -- see
    # ITEM_HISTORY_PATH in lineage_web_server.py. May not exist yet on a
    # fresh checkout (only created once the first scan produces a diff);
    # upload_one/run() already skip missing source files gracefully.
    "item_history": "analysis/item_history.csv",
}

ONELAKE_RESOURCE = "https://storage.azure.com/.default"


def _now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def load_lakehouse_config(config_path: Path) -> dict:
    if not config_path.exists():
        raise SystemExit(
            f"Lakehouse config not found: {config_path}\n"
            f"Copy config/lakehouse_target.example.json to {config_path.name} and fill it in "
            f"once the workspace/Lakehouse exist (see docs/101_medallion_lakehouse_provisioning.md)."
        )
    with open(config_path, "r", encoding="utf-8") as handle:
        config = json.load(handle)
    return config


def config_is_ready(config: dict) -> bool:
    return bool(config.get("workspace_name") and config.get("lakehouse_name"))


def resolve_entities(requested: str | None) -> dict:
    if not requested:
        return dict(ENTITY_SOURCE_PATHS)
    names = [name.strip() for name in requested.split(",") if name.strip()]
    unknown = [name for name in names if name not in ENTITY_SOURCE_PATHS]
    if unknown:
        raise SystemExit(f"Unknown entity name(s): {', '.join(unknown)}. Known entities: {', '.join(sorted(ENTITY_SOURCE_PATHS))}")
    return {name: ENTITY_SOURCE_PATHS[name] for name in names}


def build_target_path(workspace_name: str, lakehouse_name: str, entity: str, snapshot_date: str) -> str:
    return f"{workspace_name}/{lakehouse_name}.Lakehouse/Files/bronze/{entity}/snapshot_date={snapshot_date}/{entity}.csv"


def write_manifest(rows: list[dict]) -> None:
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(MANIFEST_PATH, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=MANIFEST_FIELDS, quoting=csv.QUOTE_ALL)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def upload_one(file_system_client, source_path: Path, target_path: str) -> None:
    # target_path here is relative to the Lakehouse's own OneLake file
    # system root (workspace/lakehouse already form the file system name +
    # top-level path when the DataLakeServiceClient's file system client is
    # constructed by the caller) -- see run() below.
    directory_path, file_name = target_path.rsplit("/", 1)
    directory_client = file_system_client.get_directory_client(directory_path)
    directory_client.create_directory()
    file_client = directory_client.create_file(file_name)
    data = source_path.read_bytes()
    file_client.upload_data(data, overwrite=True)


def run(args: argparse.Namespace) -> int:
    config = load_lakehouse_config(Path(args.lakehouse_config))
    entities = resolve_entities(args.entities)
    snapshot_date = args.snapshot_date or date.today().isoformat()

    ready = config_is_ready(config)
    if not ready and not args.dry_run:
        raise SystemExit(
            f"{args.lakehouse_config} has no workspace_name/lakehouse_name yet -- nothing to upload to.\n"
            "Run with --dry-run to preview what this step would do once the Lakehouse exists, "
            "or fill in the config first (see docs/101_medallion_lakehouse_provisioning.md)."
        )

    file_system_client = None
    if not args.dry_run:
        # Imported lazily so --dry-run never requires the Azure SDK to be
        # installed -- the whole entity list / target-path preview works
        # with the standard library alone.
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
    for entity, relative_path in entities.items():
        source_path = REPO_ROOT / relative_path
        target_path = build_target_path(
            config.get("workspace_name") or "<workspace>",
            config.get("lakehouse_name") or "<lakehouse>",
            entity,
            snapshot_date,
        )
        row = {
            "entity": entity,
            "source_path": relative_path,
            "target_path": target_path,
            "bytes": "",
            "status": "",
            "error": "",
            "uploaded_at": "",
        }

        if not source_path.exists():
            row["status"] = "skipped_missing_source"
            manifest_rows.append(row)
            print(f"[skip] {entity}: source not found at {relative_path}")
            continue

        row["bytes"] = str(source_path.stat().st_size)

        if args.dry_run:
            row["status"] = "dry_run"
            manifest_rows.append(row)
            print(f"[dry-run] {entity}: {relative_path} ({row['bytes']} bytes) -> {target_path}")
            continue

        try:
            # The Lakehouse-relative target path (workspace name is already
            # the file system; strip it back off here).
            lakehouse_relative_target = target_path.split("/", 1)[1]
            upload_one(file_system_client, source_path, lakehouse_relative_target)
            row["status"] = "uploaded"
            row["uploaded_at"] = _now_iso()
            print(f"[ok] {entity}: uploaded {row['bytes']} bytes -> {target_path}")
        except Exception as exc:  # noqa: BLE001 - any single entity failing must not abort the rest
            row["status"] = "failed"
            row["error"] = str(exc)
            had_failure = True
            print(f"[fail] {entity}: {exc}")

        manifest_rows.append(row)

    write_manifest(manifest_rows)
    print(f"Manifest: {MANIFEST_PATH.relative_to(REPO_ROOT)}")
    return 1 if had_failure else 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lakehouse-config", default=str(DEFAULT_CONFIG_PATH))
    parser.add_argument("--snapshot-date", default=None, help="YYYY-MM-DD, defaults to today")
    parser.add_argument("--entities", default=None, help="Comma-separated entity names, defaults to all")
    parser.add_argument("--dry-run", action="store_true", help="Preview without needing Azure auth or the Lakehouse to exist")
    args = parser.parse_args()
    sys.exit(run(args))


if __name__ == "__main__":
    main()
