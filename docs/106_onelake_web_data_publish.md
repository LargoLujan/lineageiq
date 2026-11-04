# Publishing explorer data to OneLake

The explorer loads five large JSON files. This guide explains how they get into the `Files/generated/` folder of a Fabric Lakehouse and how the web server serves them from there. With this in place the server can run anywhere, with no local copy of the data and no redeploy after a scan.

LineageIQ maps lineage at **object level**. These files describe items, objects and their relationships, not columns.

## The five files

| File | Used for |
| --- | --- |
| `lineage-explorer.json` | The main explorer graph |
| `object-impact.json` | Reverse impact by source object |
| `notebook-super-lineage.json` | Parsed notebook code and the objects it reads and writes |
| `graph-map-index.json` | Graph Map, item level |
| `graph-map-index-objects.json` | Graph Map, object level (loaded on demand) |

Landing path: `<workspace>/<lakehouse>.Lakehouse/Files/generated/<file>`. Each file is overwritten in place, because each one is a snapshot of the current state.

## Prerequisites

- A **Lakehouse**. A Warehouse has no Files area and cannot be used here. It can live in the same workspace as your write-storage Warehouse, as a separate item. See [101](101_medallion_lakehouse_provisioning.md).
- The workspace and Lakehouse **names** entered in the admin panel's **Explorer data (OneLake)** tab (below).

## Two ways to fill the folder

| Path | Who writes the files | When to use |
| --- | --- | --- |
| Fabric-native notebooks | `NB_Build_Lineage_Explorer`, `NB_Build_Object_Impact`, `NB_Build_Graph_Map` and `NB_Build_Notebook_Super_Lineage` write straight to the Lakehouse. See [105](105_fabric_native_discovery_setup.md). | You run discovery inside Fabric |
| Local publish | `backend/scripts/72_publish_web_data_to_onelake.py` uploads the files that the local build scripts produced under `frontend/semantic-lineage/data/` | You run the local scripts, or you want to push a local rebuild |

The local publish does not move any build logic into Fabric. It only uploads files that already exist.

## Local publish

```powershell
pwsh -NoLogo -File backend/scripts/72_publish_web_data_to_onelake.ps1 -DryRun
pwsh -NoLogo -File backend/scripts/72_publish_web_data_to_onelake.ps1
```

| Parameter | Meaning |
| --- | --- |
| `-DryRun` | Lists each file, its size and its target path. No Azure SDK, no network call and no Lakehouse needed. |
| `-Only <file>` | Publishes a single file, for example `object-impact.json` |
| `-AdminSettingsPath` | Settings file to read. Default: `config/admin_settings.json`. |
| `-PythonCommand` | Python executable. Default: `python`. |

The PowerShell file is a thin wrapper over the Python script, which accepts the same options as `--dry-run`, `--only` and `--admin-settings`.

How it works:

- It reads the destination from the `onelake_data` block of `config/admin_settings.json` (`workspace_name`, `lakehouse_name`). Without them, only `--dry-run` works.
- It authenticates with the Azure CLI session (`az login`) of whoever runs it. The service principal in `onelake_data` is not used for publishing.
- A missing source file is skipped with a message ("build it first"). Other files continue even if one upload fails.
- It writes a manifest to `analysis/onelake_web_data_publish_manifest.csv` with one row per file: target path, bytes, status and any error.
- The full local refresh can publish at the end of a run: `backend/scripts/99_refresh_lineage_project.ps1 ... -PublishWebData`.
- Install the dependencies first with `pip install -r requirements-lakehouse.txt` (or `requirements-web.txt`). They are not needed for `-DryRun`.

From the admin panel, **Publish data now** starts the same script on the server (`POST /api/admin/onelake-publish`). It needs `pwsh` on the server, and the caller must be on the `can_full_scan` list or hold a `full` API key (see [102](102_admin_panel_and_user_auth.md)). It uploads whatever is already saved on disk. It does not scan anything. When `onelake_data.auto_publish_after_scan` is on, a successful **local** scan queues a publish automatically. Scans run through a Fabric pipeline never trigger it, because the notebooks already write to the Lakehouse.

## Settings: the `onelake_data` block

The **Explorer data (OneLake)** tab edits this block, except `mode`, which has no field in the panel and is changed only by editing `config/admin_settings.json`.

| Key | Default | Meaning |
| --- | --- | --- |
| `mode` | `"onelake"` | `"onelake"` serves the five files from OneLake. `"local_files"` serves only from the local folder. |
| `workspace_name` | `""` | Workspace name (a name, not an ID) |
| `lakehouse_name` | `""` | Lakehouse name (a name, not an ID) |
| `sp_tenant_id` | `""` | Tenant of the service principal. Empty uses the top-level `tenant_id`. |
| `sp_client_id` | `""` | Client ID of the service principal |
| `sp_client_secret_ref` | `""` | **Name** of an environment variable on the server that holds the secret. The example file uses `ONELAKE_DATA_SP_CLIENT_SECRET`. |
| `auto_publish_after_scan` | `false` | Queue a publish after each successful local scan |

The service principal only needs **read** access to the Lakehouse. Whoever publishes uses their own `az` session. **Test connection** checks that the `Files` area of the Lakehouse is reachable with the credential you entered. It does not need any file to be published yet.

### Defaults when nothing is configured

Both defaults point at the live sources, and both fall back to local files:

- `onelake_data.mode` defaults to `"onelake"`. With no `workspace_name` and `lakehouse_name`, or when a download fails and no cached copy exists, the server serves `frontend/semantic-lineage/data/<file>` instead.
- `lakehouse.web_read_mode` defaults to `"warehouse"`. With no Warehouse configured, or when a query fails, the catalogue routes read the local `index/*.csv` files instead. See [101](101_medallion_lakehouse_provisioning.md).

Setting `mode` to `"local_files"` turns live OneLake serving off entirely.

## How the server serves the files

For a request to `/data/<file>`, the server checks sign-in first (a session, an API key, or demo mode). If `mode` is `"onelake"` and the file is one of the five, it then:

1. Returns the cached copy if it was downloaded less than 5 minutes ago.
2. Otherwise downloads `<lakehouse>.Lakehouse/Files/generated/<file>` from `https://onelake.dfs.fabric.microsoft.com`.
3. Stores it under `analysis/onelake_cache/` together with a pre-compressed `.gz` copy, so later requests are served fast.
4. If the download fails, serves the stale cached copy when there is one. With no cache, it falls back to the local file.

Any other file under `/data/` is always read from the local folder.

Credential used for the download, in order:

1. The service principal from the `onelake_data` block, when its fields are filled in.
2. The persisted admin session in `config/service_session.json`, stored when an admin signs in (see [102](102_admin_panel_and_user_auth.md)).
3. The Azure CLI session of the machine, which only exists on a server where `az login` was run.

When the two graph map files are refreshed, the server also merges the admin-curated **certifications** and **tags** into their nodes. A change in those tabs shows up after the next refresh of the cache, without re-running discovery.
