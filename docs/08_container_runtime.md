# Container Runtime

## Purpose

Run the project tooling inside Docker so local installations and PATH changes do not affect the machine.

## Included Tools

The container includes:
- Azure CLI `2.87.0`.
- Fabric CLI `1.6.1`.
- Python `3.12`.
- PowerShell.
- Node.js and npm for browser-based visual validation.
- Chromium for Playwright visual validation.
- Git and OpenSSH.
- `jq` for JSON inspection.
- Graphviz for graph rendering.
- Python graph libraries: NetworkX, PyVis, pydot, graphviz, pandas, matplotlib.

Azure CLI and Fabric CLI are installed in separate Python virtual environments inside the image to avoid dependency conflicts.

## VS Code Dev Container

The project includes:

```text
.devcontainer/devcontainer.json
.vscode/extensions.json
```

VS Code Dev Containers installs the recommended extensions into the VS Code Server attached to the container when the project is rebuilt or reopened in container mode. These extensions are not Linux packages inside the Docker image; they are VS Code extensions scoped to the container workspace.

The recommended extension set includes:
- OpenAI/Codex-related extensions: `openai.chatgpt` and `codexbuild.codex-build`.
- Microsoft Fabric extensions.
- Azure and Azure DevOps extensions.
- SQL Server extensions.
- PowerShell, Python, and Jupyter.
- Graphify, Mermaid, Draw.io, Git Graph, and Markdown tooling.

Open command palette in VS Code and run:

```text
Dev Containers: Reopen in Container
```

The project folder is mounted at:

```text
/workspace
```

## Build

```powershell
docker compose build fabric-mapper
```

## Open Shell

```powershell
docker compose run --rm fabric-mapper bash
```

## Automatic Semantic Lineage Web

The container starts the semantic lineage web app automatically from:

```text
site/semantic-lineage
```

Default runtime behavior:
- Local URL: `http://127.0.0.1:8765/`.
- Docker port mapping: `8765:8765`.
- Public Cloudflare quick tunnel: enabled in `docker-compose.yml`.
- Docker Compose runs the mounted repo entrypoint at `/workspace/docker/entrypoint.sh`.
- Current URL files:
  - `analysis/public_web_forward_current/status.txt`
  - `analysis/public_web_forward_current/public-url.txt`
  - `analysis/public_web_forward_current/local-url.txt`

Check the active URLs:

```powershell
docker exec hyperledger-fabric-mapper cat /workspace/analysis/public_web_forward_current/status.txt
```

Inside an already open container shell:

```bash
cat analysis/public_web_forward_current/status.txt
```

The public quick tunnel URL changes on each fresh start and is only intended for temporary peer review. It is not a production deployment.

To disable automatic startup for one run:

```powershell
docker compose run --rm -e LINEAGE_WEB_AUTOSTART=false fabric-mapper bash
```

To keep the local web server but disable the public tunnel:

```powershell
docker compose run --rm -e LINEAGE_WEB_PUBLIC_TUNNEL=false fabric-mapper bash
```

## Preflight Inside Container

```powershell
docker compose run --rm fabric-mapper bash -lc "az --version && fab --version && python --version && pwsh -NoLogo -Command '$PSVersionTable.PSVersion' && node --version && npm --version && chromium --version"
```

## Browser Visual Validation

The image includes Chromium and Node.js so the interactive lineage explorer can be validated with Playwright before continuing visual phases.

Standalone browser validation:

```powershell
pwsh -NoLogo -File scripts/12_validate_lineage_visual.ps1
```

Integrated local refresh plus browser validation:

```powershell
pwsh -NoLogo -File scripts/99_refresh_lineage_project.ps1 -Mode local-artifacts -RunVisualValidation
```

Outputs:
- `analysis/visual-validation/playwright-results.json`
- `analysis/visual-validation/desktop-chromium-semantic-flow.png`
- `analysis/visual-validation/desktop-chromium-copyjobs-flow.png`
- `analysis/visual-validation/desktop-chromium-planning-board.png`
- `analysis/visual-validation/mobile-chromium-semantic-flow.png`
- `analysis/visual-validation/mobile-chromium-copyjobs-flow.png`
- `analysis/visual-validation/mobile-chromium-planning-board.png`

## Authentication

The container uses Docker volumes for auth caches:

```text
fabric_mapper_azure
fabric_mapper_fabric
```

This keeps container login state separate from the host.

Fabric CLI encrypted cache fallback:
- The image includes an entrypoint that runs `fab config set encryption_fallback_enabled true` at container start.
- This is intentionally done at startup because `/root/.fabric` is a Docker volume and would hide any build-time Fabric CLI config.
- After rebuilding the image, new `docker compose run` and Dev Container sessions should have this setting applied automatically.

Azure CLI login inside container:

```powershell
docker compose run --rm fabric-mapper az login --use-device-code --tenant <tenant-id> --allow-no-subscriptions
```

Preferred Phase 1 discovery inside container:

```powershell
docker compose run --rm fabric-mapper az login --use-device-code --tenant <tenant-id> --allow-no-subscriptions
docker compose run --rm fabric-mapper pwsh -NoLogo -File scripts/01_discover_workspaces.ps1 -AuthMethod azure-cli
```

Inside an already open container shell:

```bash
az login --use-device-code --tenant <tenant-id> --allow-no-subscriptions
pwsh -NoLogo -File scripts/01_discover_workspaces.ps1 -AuthMethod azure-cli
```

This path uses Azure CLI to acquire a Fabric REST bearer token and avoids Fabric CLI's interactive browser callback inside Linux containers.

Fabric CLI login inside container:

```powershell
docker compose run --rm fabric-mapper fab auth login --tenant <tenant-id>
```

If `fab auth login` fails with `Unsupported method POST` inside a container, do not keep retrying the browser flow. Use the Azure CLI device-code path above for read-only discovery, or use service principal login only after the SPN has been explicitly approved:

```powershell
docker compose run --rm fabric-mapper fab auth login -u <client_id> -p <secret> --tenant <tenant_id>
```

If Fabric CLI still reports an encrypted cache error inside the Linux container, enable its plaintext token fallback in the isolated Fabric auth volume manually, then retry login:

```powershell
docker compose run --rm fabric-mapper fab config set encryption_fallback_enabled true
docker compose run --rm fabric-mapper fab auth login --tenant <tenant-id>
```

Inside an already open container shell, the equivalent commands are:

```bash
fab config set encryption_fallback_enabled true
fab auth login --tenant <tenant-id>
```

Security note:
- This setting permits Fabric CLI to store auth tokens without OS-backed encryption when encrypted cache is unavailable.
- In this project, that cache is scoped to the Docker volume mounted at `/root/.fabric`.
- Do not copy the Fabric auth cache into the repository.
- Use this only for the isolated project runtime.

Check Fabric CLI status:

```powershell
docker compose run --rm fabric-mapper fab auth status
```

## Secret Files

Do not copy secret files into the repository.

When a phase needs local secrets, pass them explicitly:

```powershell
docker compose --env-file C:\path\to\secrets\lineageiq.local.env run --rm fabric-mapper bash
```

## Safety

- Discovery scripts should remain read-only by default.
- External changes must still be proposed in text first.
- The container isolates tooling, not permissions. Authenticated commands can still read tenant resources.
