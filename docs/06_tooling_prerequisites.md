# Tooling Prerequisites

## Purpose

The discovery scripts need controlled access to Microsoft Fabric. Before discovery starts, run a local tooling preflight to confirm which tools and existing project patterns are available.

## Required Access Paths

### Fabric REST API

Primary path for workspace and item discovery.

Expected base URL:

```text
https://api.fabric.microsoft.com/v1
```

Recommended authentication:
- Azure CLI token through `AzureCliCredential`.
- Scope: `https://api.fabric.microsoft.com/.default`.

The discovery scripts accept `-AuthMethod` (`auto`, `azure-cli` or `fabric-cli`). `auto` tries the Azure CLI first and then the Fabric CLI.

Optional reference project: if you already maintain your own Fabric deployment tooling, point `backend/scripts/00_preflight_tools.ps1` at it with `-ReferenceProjectPath` (or the `FABRIC_LINEAGE_REFERENCE_PROJECT` environment variable) and reuse its REST client, authentication and workspace-listing code as reference. The preflight only checks that the path exists.

### Azure CLI

Needed for:
- Fabric REST authentication.
- OneLake storage tokens used by the upload and publish scripts.

Expected command:

```powershell
az login --tenant <tenant-id>
```

or:

```powershell
az login --use-device-code --tenant <tenant-id> --allow-no-subscriptions
```

If you cannot install the Azure CLI MSI because it needs administrator rights, a per-user install through Python (`pip install --user azure-cli`) is an alternative. Make sure the scripts directory of that Python install is on your `PATH`, and open a new terminal after changing it.

### Fabric CLI

Useful for Fabric-specific actions where REST is not enough. The tenant installer in the admin panel uses it.

Expected command:

```powershell
fab auth login --tenant <tenant-id>
```

Container note:
- User-mode `fab auth login` uses an interactive browser flow.
- In the Linux container, that flow can fail with `Unsupported method POST`.
- For read-only discovery inside the container, prefer Azure CLI device-code login and direct Fabric REST:

```powershell
az login --use-device-code --tenant <tenant-id> --allow-no-subscriptions
pwsh -NoLogo -File backend/scripts/01_discover_workspaces.ps1 -AuthMethod azure-cli
```

- A service principal login for the Fabric CLI is possible only after the service principal and its permissions are explicitly approved. See [08](08_container_runtime.md).

### Other evidence sources

Azure DevOps, SharePoint and a locally synced OneLake folder can serve as extra evidence when a lineage question cannot be answered from the Fabric APIs. The shipped scripts do not call Azure DevOps or SharePoint directly. In the lineage build, SharePoint and manual files are only inputs for resolving object types (see the `index/*.example.csv` templates).

## Preflight Script

Run:

```powershell
pwsh -NoLogo -File backend/scripts/00_preflight_tools.ps1
```

Output:

```text
index/tooling_inventory.csv
```

The script checks which tools are installed and reports their paths. It does not authenticate and does not query external systems.

## Safety Rules

- Do not print secrets.
- Do not read `.env` secret values.
- Do not call Fabric APIs until you intend to run discovery.
- Authentication for other sources should be approved per source before use.
