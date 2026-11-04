# Fabric-native discovery setup

This guide explains how to run LineageIQ's discovery **inside Fabric**: a Data Pipeline runs a chain of notebooks on your own capacity and writes the results to a Warehouse and a Lakehouse. The web server then only reads those results and triggers the pipeline. It needs no PowerShell and no Azure CLI.

LineageIQ maps lineage at **object level** (items, tables, views, stored procedures, files). It does not build column-to-column lineage. Column catalogues and profiles are collected, but they are not lineage edges.

The local alternative (PowerShell scripts run by `backend/scripts/99_refresh_lineage_project.ps1`) is described in the repository `README.md`.

## What you build

```text
Data Pipeline (parameter: WorkspaceNameFilter)
  -> Notebook activities, chained on success  (this guide, "Notebooks and order")
       writes dbo.bronze_* tables  -> Warehouse
       writes Files/generated/*.json -> Lakehouse (OneLake)
Web server
  -> reads the Warehouse tables and the Lakehouse JSON files live
  -> triggers the pipeline through the Fabric Job Scheduler API
```

The notebook sources are in `fabric_notebooks/`. Fabric items cannot be created from this repository, so you import them yourself (below) or use the install wizard.

## Prerequisites

| Item | Why |
| --- | --- |
| A Fabric workspace on a capacity | Holds the pipeline, the notebooks and the two items below |
| A **Warehouse** | Receives the `dbo.bronze_*` tables. Create it as described in [101](101_medallion_lakehouse_provisioning.md). |
| A **Lakehouse** | Its `Files/generated/` folder receives the explorer JSON files, and its `Files/_private/` folder holds the service principal secret. A Warehouse has no Files area, so this must be a real Lakehouse. |
| A **service principal** (Entra app registration) | The identity the notebooks use. See below. |

### Service principal

Every discovery and build notebook signs in with its own MSAL client-credentials login (`msal.ConfidentialClientApplication`). It does not use `notebookutils.credentials.getToken`, because that helper has limited scope under a service principal.

- **Tenant-wide discovery** needs the Entra **Fabric Administrator** role on the service principal. Without it, `NB_Discover_Workspaces_Items` falls back to the regular Fabric API and only sees what the identity can see.
- **Workspace role.** The notebooks assume the service principal is a **Contributor** on the workspace that holds the Lakehouse and the Warehouse. It must be able to read `Files/` in the Lakehouse and create and write tables in the Warehouse.
- **Secret.** The client secret is stored as a text file in the Lakehouse at `Files/_private/sp-client-secret.txt` and read with `notebookutils.fs.head`. It is never a pipeline parameter: a parameter value can end up in the job's failure message. Access to the file is governed by the service principal's role on that workspace.
- The same app registration can serve the notebooks, the Warehouse connection and the pipeline trigger on the admin panel, or you can use different ones.

## Configuration variables

Each notebook starts with a configuration cell holding the same values. Fill them in every notebook you import.

| Variable | Value |
| --- | --- |
| `SP_TENANT_ID` | Entra tenant ID, for example `<tenant-id>` |
| `SP_CLIENT_ID` | Client ID of the service principal |
| `ONELAKE_WORKSPACE_NAME` | Workspace that holds the Lakehouse |
| `ONELAKE_LAKEHOUSE_NAME` | Name of the Lakehouse |
| `SP_SECRET_ONELAKE_PATH` | Leave as `Files/_private/sp-client-secret.txt` |
| `WAREHOUSE_SQL_ENDPOINT` | SQL endpoint host of the Warehouse, for example `<warehouse-host>.datawarehouse.fabric.microsoft.com` |
| `WAREHOUSE_DATABASE_NAME` | Warehouse name |

`NB_Confirm_Source_Object_Types` also has an `AKV_ENDPOINT` variable, used for the credentials of external SQL servers (see its header).

## Importing the notebooks

Each `fabric_notebooks/NB_*.py` file is one notebook. Every `# %%` line starts a new cell, and `# %% [markdown]` starts a text cell. To import by hand, create a notebook with the same name as the file and paste the cells in order.

Cells titled "Parameters" must be marked as the notebook's **parameters cell** (cell menu, "Toggle parameter cell") so that the pipeline can override them. The install wizard does not mark this cell for you, so toggle it after the install.

## Notebooks and order

Run the core notebooks in this order. Each notebook reads tables written by the ones listed under "Depends on" and degrades to empty inputs when an optional table is missing.

| # | Notebook | Depends on | Writes |
| --- | --- | --- | --- |
| 1 | `NB_Discover_Workspaces_Items` | none | `bronze_workspaces`, `bronze_items`, `bronze_workspace_role_assignments` |
| 2 | `NB_Discover_Dependencies` | 1 | `bronze_dependencies`, `bronze_variable_library_catalog` |
| 3 | `NB_Discover_Object_Lineage` | 1, 2 | `bronze_item_object_lineage_candidates` |
| 4 | `NB_Discover_Pipeline_Object_Lineage` | 1; 3 (to inherit objects from invoked items) | `bronze_pipeline_object_lineage_candidates`, `bronze_pipeline_activity_lineage` |
| 5 | `NB_Discover_Semantic_Model_Lineage` | 1 | `bronze_semantic_model_view_candidates` |
| 6 | `NB_Confirm_Source_Object_Types` (optional) | 3, 4, 5 | `bronze_source_object_type_metadata_evidence`, `bronze_source_object_type_metadata_gaps` |
| 7 | `NB_Discover_Executions` | 1 | `bronze_executions` |
| 8 | `NB_Build_Lineage_Explorer` | 1, 2, 7 and the candidate tables | `Files/generated/lineage-explorer.json` |
| 9 | `NB_Build_Object_Impact` | 8 | `Files/generated/object-impact.json` |
| 10 | `NB_Build_Graph_Map` | 8, 9 | `Files/generated/graph-map-index.json`, `Files/generated/graph-map-index-objects.json` |
| 11 | `NB_Download_Notebook_Definitions` | 1 | `bronze_notebook_definitions` |
| 12 | `NB_Build_Notebook_Super_Lineage` | 11 | `Files/generated/notebook-super-lineage.json` |

Notes:

- Notebook 6 is the only step that connects from Fabric to SQL servers **outside** Fabric. It needs a network route from your capacity to those servers (for example a data gateway). A server it cannot reach is recorded as a gap and the rest of the notebook continues.
- The install wizard lists the same 12 notebooks in a slightly different order. Use the order above: it follows the dependencies stated in each notebook header.
- Chain the activities with **On success** so a failed step stops the run.
- A pipeline run writes the Warehouse tables and the Lakehouse JSON files directly. It does not trigger "Copy data now" or "Publish data now", and it does not produce a scan diff in the admin panel's modification history.

### Optional notebooks

Notebook 8 reads the tables written by the four catalogue notebooks (connections, SQL endpoint catalogue, object column catalogue, control framework) when they exist, so run those before it. The hardening and backfill notebooks rewrite the candidate tables in place, so run them before the notebooks that read those tables.

| Notebook | Depends on | Writes |
| --- | --- | --- |
| `NB_Discover_Fabric_Connections` | none | `bronze_fabric_connections` |
| `NB_Extract_SQL_Endpoint_Catalog` | `NB_Discover_Fabric_Connections` | `bronze_sql_endpoint_object_catalog` (+ status table) |
| `NB_Extract_Object_Column_Catalog` | 3, 4, 5, `NB_Extract_SQL_Endpoint_Catalog` | `bronze_object_column_catalog` (+ status table) |
| `NB_Extract_Control_Framework_Lineage` | `NB_Extract_SQL_Endpoint_Catalog` | `bronze_control_framework_lineage_candidates` (+ gaps table) |
| `NB_Harden_Object_Lineage_Candidates` | 2, 3, 4, 5 | Rewrites the three candidate tables in place; adds review and summary tables |
| `NB_Backfill_Object_Source_Targets` | 3, 4, 5, `NB_Extract_SQL_Endpoint_Catalog` | Rewrites the three candidate tables in place; adds a summary table |
| `NB_Discover_Column_Profile` | none | `bronze_column_profile` (column statistics for Lakehouse tables) |
| `NB_Discover_Column_Sensitivity` | none | `bronze_column_sensitivity_content` (and `bronze_column_sensitivity_samples` only when sample storage is on) |
| `NB_Bronze_Silver_Gold_Build` | see [101](101_medallion_lakehouse_provisioning.md) | A separate Bronze, Silver and Gold build with Spark; not part of this chain |

The column profile and sensitivity notebooks only read Lakehouses where the service principal already has a data role. In `NB_Discover_Column_Sensitivity`, `STORE_REAL_SAMPLE_VALUES` is `False` by default: no real cell values are stored, only counts and percentages. Turn it on only if your data policy allows it.

## Pipeline parameters

Create one **String** pipeline parameter named `WorkspaceNameFilter` with an empty default, and pass it to each notebook activity as a base parameter of the same name.

| Parameter | Used by | Meaning |
| --- | --- | --- |
| `WorkspaceNameFilter` | Notebooks 1 to 7, 11, 12 and the optional catalogue notebooks that have a parameters cell | Empty means the whole tenant. Otherwise a list of workspace names separated by `;`. Only those workspaces are rediscovered and the other workspaces' rows are kept. `NB_Discover_Semantic_Model_Lineage` honours a single exact name only. |
| `TargetColumnsFilter` | `NB_Discover_Column_Sensitivity` only | Limits content sampling to the listed columns. Optional. A pipeline without this parameter ignores it. |

Notebooks 8, 9 and 10, `NB_Discover_Fabric_Connections`, `NB_Harden_Object_Lineage_Candidates`, `NB_Backfill_Object_Source_Targets` and `NB_Discover_Column_Profile` have no parameters cell. They always process everything.

The web server sends `WorkspaceNameFilter` when it starts the pipeline: empty for a tenant-wide scan, a `;`-joined list for a scan scoped to a user's accessible workspaces or to one workspace.

## The "Fabric-native scan" tab

In the admin panel, open **Setup, Fabric-native scan** (see [102](102_admin_panel_and_user_auth.md)). It writes the `discovery_pipeline` block of `config/admin_settings.json`.

| Field | Meaning |
| --- | --- |
| Mode | Fixed to Fabric / Pipeline (`discovery_pipeline.mode = "fabric_pipeline"`, the default). |
| Workspace, Data Pipeline | Picked by name from your own Fabric access. The panel saves the IDs. |
| Service principal (optional) | `sp_tenant_id`, `sp_client_id` and `sp_client_secret_ref`, the **name** of an environment variable on the server that holds the secret. |
| Test connection | Reads the pipeline item's metadata to confirm the IDs and your access. It does not start a run. |

How the server authenticates the trigger, in order:

1. The delegated token of the signed-in user who started the scan. No app registration is needed.
2. The service principal, when its fields are filled in. Use this if a run must be possible with nobody signed in.

Scans use the Fabric Job Scheduler REST API: start (`POST .../jobs/instances?jobType=Pipeline`), poll, and cancel. A signed-in user who is not a Fabric administrator gets a scan limited to the workspaces they can see. A scan started with an API key covers the whole tenant.

The tab also has two helpers:

- **+ New workspace** creates a workspace (optionally assigned to a capacity) from the panel.
- **Install into another tenant** opens a wizard that uses the `fab` CLI with a service principal of the **target** tenant, in an isolated session so your own `fab` login is untouched. It creates the workspace, the storage item and an extra Lakehouse when the storage is a Warehouse, then deploys the notebooks with the configuration variables above filled in. For a Warehouse it resolves `WAREHOUSE_SQL_ENDPOINT` automatically. For a Lakehouse you must fill it in by hand. **It does not create the Data Pipeline.** Build the pipeline yourself using the order above.

## Where the results go

| Destination | Contents | Read by |
| --- | --- | --- |
| Warehouse `dbo.bronze_*` | Catalogue and lineage tables | The web server, when `lakehouse.web_read_mode` is `warehouse` (the default). See [101](101_medallion_lakehouse_provisioning.md). |
| Lakehouse `Files/generated/` | The five explorer JSON files | The web server, through the Explorer data (OneLake) tab. See [106](106_onelake_web_data_publish.md). |

If the Warehouse or the OneLake destination is not configured, or a live read fails, the server falls back to the local files under `index/` and `frontend/semantic-lineage/data/`.
