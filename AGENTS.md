# AGENTS.md

Instructions for AI coding agents working in this repository, whatever the tool. Human contributors: see [CONTRIBUTING.md](CONTRIBUTING.md); everything there applies to agents too.

## What this project is

LineageIQ is a read-only lineage, catalogue and governance mapper for Microsoft Fabric (version 0.2.0, MIT).
It discovers workspaces and items through the Fabric and Power BI APIs, either locally with numbered PowerShell and Python scripts or inside Fabric with notebooks, and builds an object-level dependency graph.
`backend/scripts/lineage_web_server.py` serves that graph as a web UI, a REST API under `/api/*` and an MCP endpoint at `/mcp`; two more MCP servers run over stdio.

## Repository map

| Path | Contents |
| --- | --- |
| `backend/scripts/00_…73_*.ps1`, `*.py` | Numbered discovery and build phases; `99_refresh_lineage_project.ps1` runs them in order |
| `backend/scripts/lineage_web/` | Web server package: `handler.py` (request dispatch and auth gates), `routes.py` (route registry, source of `/api/openapi.json`), `auth.py`, `catalog.py`, `scan_manager.py`, `constants.py` and others |
| `backend/scripts/mcp_server.py` | MCP server, stdio, reads local artefacts |
| `backend/scripts/mcp_server_remote.py` | MCP server, stdio, calls the REST API |
| `backend/scripts/mcp_http_server.py` | MCP server, Streamable HTTP, behind the `/mcp` proxy |
| `backend/scripts/generate_demo_data.py` | Deterministic synthetic Contoso tenant used by the demo and the demo-mode tests |
| `backend/scripts/warehouse_sql/` | T-SQL stored-procedure versions of some build steps |
| `fabric_notebooks/NB_*.py` | Fabric notebook sources; each `# %%` block is one cell |
| `frontend/semantic-lineage/` | Web UI: vanilla JS, HTML and CSS; `vendor/` holds third-party libraries |
| `tests/python/` | pytest unit tests (no live Fabric connection) |
| `tests/visual/`, `tests/powershell/` | Playwright specs and Pester tests |
| `docs/` | Hand-written setup guides (`docs/04_*`, `06_*`, `08_*`, `1NN_*`) |
| `config/` | `*.example.*` templates only; real configuration is git-ignored |
| `index/`, `analysis/`, `graph/`, `data/`, `runs/` | Generated artefacts, git-ignored except `.gitkeep` and `*.example.csv` |

## Commands

Set up (Python 3.12):

```bash
python -m pip install --upgrade pip
pip install -r requirements-web.txt -r requirements-mcp.txt pytest
```

Run the web UI on demo data (writes only to git-ignored folders):

```bash
python backend/scripts/generate_demo_data.py
LINEAGE_DEMO_MODE=1 python backend/scripts/lineage_web_server.py --bind 127.0.0.1 --directory frontend/semantic-lineage
```

Checks, exactly as CI runs them (`.github/workflows/ci.yml`):

```bash
python -m compileall -q backend/scripts fabric_notebooks tests
python -m pytest tests/python/ -q
git ls-files "*.js" | grep -v "/vendor/" | while read -r f; do node --check "$f"; done   # Node 22
```

Optional, not in CI: `npm install && npx playwright install chromium && npm run test:visual` (Playwright) and `Invoke-Pester tests/powershell/LineageCommon.Tests.ps1` (Pester).

## Conventions

- **Python 3.12.** The web server and build scripts use the standard library. Add a dependency only when needed, pinned with `==` in the matching `requirements-*.txt` file.
- **Frontend.** Vanilla JavaScript with no build step. Do not edit files in `frontend/semantic-lineage/vendor/`. New UI strings need both an `en` and an `es` entry in the `i18n` object in `app.js`.
- **Identity.** Graph nodes are identified by `Workspace / Item Type / Item Name`. Fabric GUIDs are metadata only.
- **Edges.** Relationship types are `reads_from`, `writes_to`, `executes`, `refreshes`, `depends_on`, `uses_model`, `serves_report` and `contains`; confidence is `confirmed`, `likely` or `unknown`. Do not invent new values without updating every consumer.
- **Lineage level.** Lineage stops at object level (tables, views, stored procedures, files). There are no column-to-column edges.
- **Script pairs.** `11_build_lineage_explorer`, `17_build_object_impact_index` and `21_build_reverse_impact_package` have a canonical `.ps1` and a `*_fast.py` port: change both. For scripts without the `_fast` suffix, the `.py` file is the implementation and the `.ps1` is a thin wrapper. See `backend/scripts/README.md`.
- **Notebooks.** Keep the `# %%` cell structure, the configuration cell at the top and any cell titled "Parameters".
- **MCP tools.** The three servers expose the same catalogue. A new or changed tool usually belongs in all servers that can serve it, in the README tool table and in the tests.
- **Secrets.** Configuration stores the name of an environment variable in `*_secret_ref` and `password_ref` fields, never the secret.
- **Language and style.** Code, comments, docs and commit messages are in English. Commit subjects are imperative, capitalised, without a type prefix or trailing full stop.

## Safety rules

- **Never run discovery against a real tenant** in tests, CI or automated checks. Do not run `az login`, `fab auth login`, `99_refresh_lineage_project.ps1` with `-Mode read-only-inventory` or `-Mode full-read-only`, any numbered script that calls Fabric, or the notebooks against a live Fabric workspace. Tests use fixtures, mocks and the demo generator.
- **Never commit secrets or local state**: `.env`, `config/admin_settings.json`, `config/service_session.json`, tokens, keys, or anything under the generated folders. Do not force-add files that `.gitignore` excludes.
- **Demo and fixture data use the fictional Contoso tenant only**, as `generate_demo_data.py` does. Never copy real workspace, item, object or host names, GUIDs, user names or email addresses into the repository.
- **Keep discovery read-only.** Do not add code that writes to the Fabric items, SQL endpoints or OneLake data being scanned. LineageIQ's own outputs (local files, its designated Warehouse and Lakehouse) are the only write targets.
- **Do not weaken security controls** (sign-in gates, API key scopes, rate limiting, the Origin check, the `127.0.0.1` binding of the HTTP MCP subprocess, demo mode being read-only) unless the maintainer asks for it in the issue.
- **Keep `routes.py` in sync with `handler.py`** in the same change until that is automated. There is no code generation in either direction yet.
- **Never set `LINEAGE_DEMO_MODE`** outside the synthetic demo data.

## Definition of done

- `python -m compileall -q backend/scripts fabric_notebooks tests` and `python -m pytest tests/python/ -q` pass.
- `node --check` passes on every changed `.js` file outside `vendor/`.
- New or changed behaviour has tests that need no live Fabric connection.
- README, `docs/` and code comments match the new behaviour; `routes.py` matches `handler.py`.
- No secrets, no `.env`, no generated output and no real tenant data in the diff.
