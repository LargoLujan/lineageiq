# Contributing to LineageIQ

Thanks for your interest in LineageIQ. Bug reports, documentation fixes, tests and small focused features are all welcome. This guide explains how to set up the project, run it and its tests the way CI does, and get a change merged.

By taking part you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md). To report a security problem, follow [SECURITY.md](SECURITY.md) and do not open a public issue.

## Questions and ideas

- **Questions** ("how do I…", "is this expected?"): ask in [Discussions, Q&A](https://github.com/LargoLujan/lineageiq/discussions/categories/q-a).
- **Bugs and concrete feature requests**: open an [issue](https://github.com/LargoLujan/lineageiq/issues/new/choose) using one of the forms.
- **Larger changes**: open an issue or a discussion first, so we can agree on the approach before you write a lot of code.

## Prerequisites

- **Python 3.12**, the version CI and the Docker images use.
- **Git**.
- **Node.js 22**, only for the JavaScript syntax check and the Playwright visual tests.
- Optional: **PowerShell** (`pwsh`) for the discovery scripts and the Pester tests, and **Docker** for the container images.

You do not need Microsoft Fabric access to contribute. The unit tests need no live Fabric connection, and the synthetic Contoso demo tenant exercises every view of the web UI.

## Set up

```bash
git clone https://github.com/LargoLujan/lineageiq.git
cd lineageiq
python -m pip install --upgrade pip
pip install -r requirements-web.txt -r requirements-mcp.txt pytest
```

`requirements-lakehouse.txt` is only needed for the OneLake bronze upload script, and `npm install` only for the Playwright tests.

## Run the app with demo data

```bash
python backend/scripts/generate_demo_data.py
LINEAGE_DEMO_MODE=1 python backend/scripts/lineage_web_server.py --bind 127.0.0.1 --directory frontend/semantic-lineage
```

On Windows PowerShell:

```powershell
python backend/scripts/generate_demo_data.py
$env:LINEAGE_DEMO_MODE = "1"; python backend/scripts/lineage_web_server.py --bind 127.0.0.1 --directory frontend/semantic-lineage
```

Open `http://127.0.0.1:8765`. The generator writes only to git-ignored folders (`index/`, `analysis/` and `frontend/semantic-lineage/data/`). In PowerShell, run `Remove-Item Env:LINEAGE_DEMO_MODE` before you start the server for anything else from the same window. Never set `LINEAGE_DEMO_MODE` on real tenant data: it makes every read public.

To try the stdio MCP server against the same data, run `python backend/scripts/mcp_server.py` from your MCP client (see [MCP Servers](https://github.com/LargoLujan/lineageiq#mcp-servers) in the README).

## Run the checks the way CI does

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs on every push and pull request to `main`. Run the same commands before you open a pull request.

**Python compile and unit tests** (Python 3.12):

```bash
python -m compileall -q backend/scripts fabric_notebooks tests
python -m pytest tests/python/ -q
```

**JavaScript syntax check** (Node 22), on every tracked `.js` file outside `vendor/`:

```bash
git ls-files "*.js" | grep -v "/vendor/" | while read -r f; do node --check "$f"; done
```

On Windows PowerShell:

```powershell
git ls-files "*.js" | Where-Object { $_ -notmatch "/vendor/" } | ForEach-Object { node --check $_ }
```

**Leak scan.** CI also greps tracked files for a pattern stored in the `LEAK_SCAN_PATTERN` repository secret. The step is skipped when the secret is not available, for example on pull requests from forks, so follow the data rules below yourself.

Not run by CI, but useful when you touch these areas:

- Playwright visual tests (`tests/visual/`): `npm install`, `npx playwright install chromium`, then `npm run test:visual`. The explorer specs use the `standalone.html` export, built with `backend/scripts/10_build_semantic_lineage_standalone.ps1`.
- Pester tests for the PowerShell helpers: `Invoke-Pester tests/powershell/LineageCommon.Tests.ps1`.
- If you change `Dockerfile.demo` or code it copies, the `Demo image` workflow builds and smoke-tests the image on your pull request. You can build it locally with `docker build -f Dockerfile.demo -t lineageiq-demo .`.

## Project layout

| Path | What lives there |
| --- | --- |
| `backend/scripts/` | Numbered discovery and build phases (`00`–`73`, `99_refresh_lineage_project.ps1` runs them in order), the demo generator and the three MCP servers |
| `backend/scripts/lineage_web/` | The web server package: request handling (`handler.py`), the route registry (`routes.py`), sign-in, catalogue, scans and governance |
| `fabric_notebooks/` | `NB_*.py` sources for Fabric-native discovery; each `# %%` block is one notebook cell |
| `frontend/semantic-lineage/` | The web UI: vanilla JavaScript, HTML and CSS, with third-party libraries in `vendor/` |
| `tests/python/`, `tests/visual/`, `tests/powershell/` | pytest, Playwright and Pester tests |
| `docs/` | Setup guides; start with the [Documentation](https://github.com/LargoLujan/lineageiq#documentation) table in the README |
| `config/` | `*.example.json` and `*.example.csv` templates; real configuration is git-ignored |

[`backend/scripts/README.md`](backend/scripts/README.md) explains the script order and the PowerShell and Python pairing conventions.

## Making a change

1. **Start from an issue.** Comment on an existing one or open a new one, so the change is agreed and others know you are working on it.
2. **Create a branch** from `main` with a short descriptive name. Existing branches use prefixes such as `feat/`, `fix/` and `chore/`.
3. **Keep it small and focused.** One logical change per pull request is much easier to review than a bundle of unrelated edits.
4. **Add or update tests** for any behaviour you change. Tests must not call a real tenant (see below).
5. **Update the documentation** (README, `docs/`, code comments) when behaviour, configuration or commands change.
6. **Open a pull request** against `main`, fill in the template and link the issue (`Closes #123`).
7. **CI must pass** before a pull request is merged. The maintainer may ask for changes; that is a normal part of review.

Pull requests are merged with a merge commit, so every commit in your branch stays in the history. Tidy them up before you ask for review.

### Things that are easy to miss

- **Routes.** `backend/scripts/lineage_web/routes.py` is the source of `/api/openapi.json` and is kept in sync with `handler.py` by hand. If you add, remove or change a route in `handler.py`, update `routes.py` in the same pull request.
- **PowerShell and Python pairs.** For `11_build_lineage_explorer`, `17_build_object_impact_index` and `21_build_reverse_impact_package`, logic changes must be made in both the `.ps1` file and its `*_fast.py` port. There is no automated parity test yet.
- **MCP tools.** The three MCP servers expose the same catalogue. If you add or change a tool, check whether the other servers and the tool table in the README need the same change.
- **UI text.** The web UI is bilingual. New strings in `frontend/semantic-lineage/app.js` need both an `en` and an `es` entry in the `i18n` object.
- **Language.** Code, comments, documentation and commit messages are in English.

## Commit messages

Follow the style already in the history:

- A short subject line in the imperative mood, starting with a capital letter and with no trailing full stop, for example `Respect the hidden attribute for admin-only buttons`.
- No type prefix such as `feat:` or `fix:`.
- For anything non-trivial, a blank line and a body that explains what changed and why. Bullet lists are fine.

## Data rules: Contoso only

Everything committed to this repository must be safe to publish.

- Fixtures, test data, examples, screenshots and documentation use the fictional **Contoso** tenant, in the style of `backend/scripts/generate_demo_data.py`, or neutral placeholders such as `<tenant-id>` and `<workspace name>`.
- Never commit real tenant data: no real workspace, item, table or host names, no GUIDs, user names or email addresses from a real tenant, and no output generated from one.
- Never commit secrets or local configuration: `.env`, `config/admin_settings.json`, `config/service_session.json` and other files that `.gitignore` excludes. Do not force-add ignored files.
- If you have run LineageIQ against a real tenant from your working copy, run the pre-publication check before you push:

  ```bash
  pwsh -NoLogo -File backend/scripts/check_repository_publication.ps1 -SummaryOnly
  ```

## Licence

LineageIQ is released under the [MIT License](LICENSE). By submitting a contribution, you agree that it is licensed under the same terms.
