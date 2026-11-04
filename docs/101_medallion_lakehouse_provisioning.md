# Database bypass: a parallel Bronze/Silver/Gold (Kimball) Lakehouse

This is the practical setup guide: what you do by hand once, and what is already built and ready when you finish.

This is a **bypass**, not a replacement. The CSV/JSON pipeline (`backend/scripts/03` to `21` and the web app in `frontend/semantic-lineage/`) keeps working exactly as before. Nothing here touches it or depends on it. The Lakehouse is a new, parallel destination, and it is only fed when you turn on the `-PublishBronze` switch explicitly.

## What this does not touch

The tenant workspaces that LineageIQ scans stay read-only and unchanged. The only thing written is a **new workspace that belongs to this project**, which you create and control. No scanned workspace is ever written to.

## One-time setup (done by hand)

Do this in the Fabric portal, not by script. It is the first write action in the whole project, so it is documented here.

1. **Create a new workspace** in your tenant (`<tenant-id>`), dedicated to LineageIQ. Choose any name, but make sure it does not match a workspace that is already scanned (check against `index/workspaces.csv`).
2. **Assign it to a Fabric capacity.** Before confirming, check that the capacity supports **DirectLake**, which lets Power BI connect straight to the Gold tables without an import step.
3. Inside that workspace, **create one Lakehouse**.
4. **Confirm that your `az login` identity** has the Contributor role on that workspace. It is the only place in Fabric where this identity will write.
5. **Note these values** for the next step: workspace name and GUID, Lakehouse name and GUID, capacity name, and the connection string of the Lakehouse's SQL analytics endpoint (shown in the portal, in the Lakehouse settings).

## Connecting it

The settings live in the `lakehouse` block of `config/admin_settings.json`, which you can edit in the admin panel's **Write storage** tab (see [102](102_admin_panel_and_user_auth.md)). Every time those settings are saved, the server regenerates `config/lakehouse_target.json` from them. The upload and validation scripts read that mirrored file directly.

If you run the scripts without the web server, copy `config/lakehouse_target.example.json` to `config/lakehouse_target.json` and fill it in. The file is git-ignored.

```json
{
  "tenant_id": "<tenant-id>",
  "workspace_name": "<new workspace name>",
  "workspace_id": "<workspace GUID>",
  "lakehouse_name": "<Lakehouse name>",
  "lakehouse_id": "<Lakehouse GUID>",
  "capacity_name": "<capacity name>",
  "sql_endpoint_connection_string": "<SQL analytics endpoint host>",
  "item_type": "Lakehouse",
  "auth_mode": "user_session",
  "sp_tenant_id": "",
  "sp_client_id": "",
  "sp_client_secret_ref": ""
}
```

| Key | Meaning |
| --- | --- |
| `item_type` | `"Lakehouse"` or `"Warehouse"`. The example file ships with `"Warehouse"`. |
| `auth_mode` | `"user_session"` (the signed-in user or your `az` login) or `"service_principal"` (unattended) |
| `sp_tenant_id`, `sp_client_id` | Service principal identity. An empty tenant means `tenant_id`. |
| `sp_client_secret_ref` | The **name** of an environment variable that holds the client secret, never the secret itself |

## What is already built

- **`backend/scripts/64_upload_bronze_to_onelake.py`** (with `backend/scripts/64_upload_bronze_to_onelake.ps1` as a wrapper) uploads the project's 22 source CSV entities (workspaces, items, dependencies, executions, objects and columns, governance, deployment pipelines and more) to `Files/bronze/<entity>/snapshot_date=<date>/` in the Lakehouse. You can try it right now, with no credentials and no real Lakehouse:

  ```powershell
  pwsh -File backend/scripts/64_upload_bronze_to_onelake.ps1 -DryRun
  ```

  This lists every entity, its real size and the destination path it would have, without calling Azure. Once the Lakehouse exists and the config is filled in, remove `-DryRun` to upload for real. The Python script also accepts `--entities` (a comma-separated list) and `--snapshot-date`.

- **`requirements-lakehouse.txt`** lists the extra Python dependencies (`azure-identity`, `azure-storage-file-datalake`, `pandas`). Install them with `pip install -r requirements-lakehouse.txt` before the first real upload. `-DryRun` does not need them.

- **The `-PublishBronze` switch** (off by default) exists on both `backend/scripts/scan_single_workspace.ps1` and `backend/scripts/99_refresh_lineage_project.ps1`. When you turn it on, the scan uploads the freshly generated CSVs at the end as one more step. The scan stays read-only against Fabric except for this final upload, and the step degrades by itself (it does not abort the scan) if the Lakehouse is not configured yet.

  ```powershell
  pwsh -File backend/scripts/scan_single_workspace.ps1 -WorkspaceName "Name" -PublishBronze
  pwsh -File backend/scripts/99_refresh_lineage_project.ps1 -Mode full-read-only -PublishBronze
  ```

## Building Silver and Gold, and validating

1. **Fabric notebook `NB_Bronze_Silver_Gold_Build`.** The full source is in `fabric_notebooks/NB_Bronze_Silver_Gold_Build.py`. Fabric notebooks cannot be created from this repository, so you paste it by hand: create a notebook with that name in the Lakehouse and copy the contents, where each `# %%` block is one cell. It does three things:
   - **Bronze:** reads what was uploaded to `Files/` and writes managed Delta tables partitioned by `snapshot_date`.
   - **Silver:** deduplicates executions by `job_instance_id` and assigns deterministic UUID surrogate keys.
   - **Gold:** builds the Kimball star schema, 8 dimensions and 8 facts.

   `object_read_write_classification.csv` already arrives from the source with the object type and the read/write classification resolved by `backend/scripts/23_build_object_read_write_classification.ps1`. The notebook conforms it but does not reimplement that logic in Spark, so there is only one version of the rule.
2. **`backend/scripts/65_validate_lakehouse_gold_parity.ps1`** is a read-only check that compares row counts between the local CSVs and the Bronze and Gold tables in the Lakehouse. It uses the same AAD-token SQL connection pattern as `backend/scripts/34_extract_sql_endpoint_object_catalog.ps1`.
3. As a first consumer, build a Power BI report in DirectLake mode on the Gold tables.

## Live reads from the Warehouse (web server)

In the admin panel's **Write storage** tab, with `item_type = Warehouse` and `auth_mode = service_principal`, there are two independent switches.

- **Write:** "Copy automatically after every scan" (`lakehouse.auto_upload_after_scan`, off by default). After each scan, `backend/scripts/67_upload_bronze_to_warehouse.ps1` uploads `index/workspaces.csv`, `index/items.csv`, `index/dependencies.csv` and the project's other CSVs to `dbo.bronze_<entity>` in the Warehouse (incremental, only what changed). The **Copy data now** button runs the same upload on demand. A Lakehouse SQL endpoint is query-only, so this upload needs a Warehouse.
- **Read:** `lakehouse.web_read_mode`. With `"warehouse"`, `backend/scripts/lineage_web/catalog.py` (item search, an item's lineage, workspace and item resolution for the Fabric links) queries `dbo.bronze_workspaces`, `dbo.bronze_items` and `dbo.bronze_dependencies` on every request instead of reading the CSVs on the server's disk. The implementation is in `backend/scripts/lineage_web/warehouse.py`: a service principal token (`msal.ConfidentialClientApplication`, scope `https://database.windows.net/.default`) plus `pyodbc` with `SQL_COPT_SS_ACCESS_TOKEN`, and a 30-second cache per table. Without a service principal, it falls back to the persisted admin session described in [102](102_admin_panel_and_user_auth.md).

**Defaults:** `lakehouse.web_read_mode` is `"warehouse"` and `lakehouse.auto_upload_after_scan` is `false`. If the Warehouse is not configured, or a query fails for any reason (table not uploaded yet, endpoint down), the server falls back to the local CSV files and the request still succeeds. Set `web_read_mode` to `"local_files"` to read local files only.

This suits a web server that runs on a different machine or cloud from the one that scans. When the Warehouse is populated, what your colleagues see is as fresh as the last upload.

The large pre-built JSON files (`object-impact.json`, `notebook-super-lineage.json` and the others) are not read from SQL. They are served from OneLake: see [106](106_onelake_web_data_publish.md).

## Scans triggered from a Fabric Data Pipeline (web server)

The admin panel's **Fabric-native scan** tab makes scans run in Fabric instead of on the web server. The server triggers, polls and cancels an existing Fabric Data Pipeline through the Job Scheduler REST API, instead of spawning `pwsh` and the Azure CLI. This is the `fabric_pipeline` mode, the shipped default (`discovery_pipeline.mode`). It is implemented in `backend/scripts/lineage_web/fabric_pipeline.py`. The service principal token uses scope `https://api.fabric.microsoft.com/.default`, and the signed-in user's delegated token is tried first.

Endpoints used:

- Start: `POST /v1/workspaces/{workspaceId}/items/{itemId}/jobs/instances?jobType=Pipeline`, with `{"executionData": {"parameters": {"WorkspaceNameFilter": "..."}}}`. The new run ID comes back in the `Location` response header, not in the body.
- Poll: `GET /v1/workspaces/{workspaceId}/items/{itemId}/jobs/instances/{jobInstanceId}`.
- Cancel: `POST /v1/workspaces/{workspaceId}/items/{itemId}/jobs/instances/{jobInstanceId}/cancel`.

Because a scan no longer needs `pwsh` or the Azure CLI on the web host, that host can be a small, lean machine. The heavy work (Fabric API discovery, SQL metadata extraction) runs inside Fabric on your own capacity.

**The discovery notebooks** (workspaces and items, dependencies, object lineage, pipeline lineage, semantic model lineage, executions, the explorer builds and more) are listed with their order, parameters and prerequisites in [105](105_fabric_native_discovery_setup.md), the single source of truth for that setup. They write the same `dbo.bronze_*` tables that `67_upload_bronze_to_warehouse.ps1` uploads from local files. Like `NB_Bronze_Silver_Gold_Build.py`, the code is in this repository, but pasting it into Fabric, creating the service principal and building the Data Pipeline are manual steps. A notebook run by a pipeline can run under a service principal, but the native `notebookutils.credentials.getToken` helper has limited scope in that case. The notebooks therefore do their own MSAL login with the service principal, the same pattern as `warehouse.py` and `67_upload_bronze_to_warehouse.ps1`.

**The big explorer JSON files** (`lineage-explorer.json` and the four others the frontend loads) can be served live from OneLake instead of the server's local disk. See [106](106_onelake_web_data_publish.md). That needs a dedicated Lakehouse, because a Warehouse has no Files area in OneLake. It can live in the same workspace as the write Warehouse, as a separate item.

**What is tested:** the full trigger, poll and cancel mechanism has its own tests (`tests/python/test_fabric_pipeline_scan.py`), and the panel has a **Test connection** button. It verifies the IDs and the caller's access by reading the pipeline item's metadata, without starting a run. A pipeline scan produces no item diff, unlike a local scan, because the pipeline writes straight to the Warehouse and not to `index/items.csv` on the server.
