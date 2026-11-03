# Tooling Prerequisites

## Purpose

Phases 1 and later need controlled access to Microsoft Fabric, Azure DevOps, SharePoint, and OneLake. Before discovery starts, run a local tooling preflight to confirm which tools and existing project patterns are available.

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

Optional reference project: if you already maintain your own Fabric
deployment tooling, point `00_preflight_tools.ps1` at it with
`-ReferenceProjectPath` (or the `FABRIC_LINEAGE_REFERENCE_PROJECT`
environment variable) and reuse its REST client, authentication and
workspace-listing code as reference.

### Azure CLI

Needed for:
- Fabric REST authentication.
- Azure DevOps Microsoft Entra token.
- OneLake storage token.

Expected command:

```powershell
az login --tenant <tenant-id>
```

or:

```powershell
az login --use-device-code --allow-no-subscriptions
```

Current local finding:
- `az.exe` was not found in PATH during initial preflight.
- Azure CLI was installed later through Python user packages because the MSI requires administrator rights.
- User-level command path:

```text
C:\Users\<username>\AppData\Roaming\Python\Python312\Scripts\az.bat
```

- The user PATH was updated with:

```text
C:\Users\<username>\AppData\Roaming\Python\Python312\Scripts
```

New terminals should resolve `az` directly. Existing sessions may need PATH refresh or explicit `az.bat`.

### Fabric CLI

Useful for Fabric-specific actions where REST is not enough.

Expected command:

```powershell
fab auth login --tenant <tenant-id>
```

Current local finding:
- `fab.exe` was found at `C:\Users\<username>\AppData\Local\Programs\Python\Python312\Scripts\fab.exe`.
- `fabric.exe` was not found in PATH.
- `fab auth status` confirmed an active Fabric CLI session during setup.

Container note:
- User-mode `fab auth login` uses an interactive browser flow.
- In the Linux container, that flow failed with `Unsupported method POST`.
- For Phase 1 read-only discovery inside the container, prefer Azure CLI device-code login and direct Fabric REST:

```powershell
az login --use-device-code --tenant <tenant-id> --allow-no-subscriptions
pwsh -NoLogo -File scripts/01_discover_workspaces.ps1 -AuthMethod azure-cli
```

- Service principal Fabric CLI login remains possible only after the SPN and its permissions are explicitly approved.

### Azure DevOps REST

Main technical source for repositories, notebooks, pipeline definitions, deployment scripts, and evidence.

Preferred token:

```powershell
az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv
```

Fallback:
- `AZURE_DEVOPS_PAT`, only with minimal scope and never stored in Git.

### SharePoint

Secondary source for documentation, mapping files, architecture notes, and runbooks.

Use connector or Microsoft Graph only after confirming the target site/library.

### Local OneLake

Supporting source for local folder and path evidence when available.

Use it to validate:
- Lakehouse paths.
- Tables and files.
- Shortcuts.
- Local synced or mounted workspace content.

## Preflight Script

Run:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\00_preflight_tools.ps1
```

Output:

```text
index/tooling_inventory.csv
```

The script does not authenticate and does not query external systems.

## Safety Rules

- Do not print secrets.
- Do not read `.env` secret values.
- Do not call Fabric APIs until the user starts Phase 1.
- Do not call Azure DevOps or SharePoint until the relevant source step is approved.
