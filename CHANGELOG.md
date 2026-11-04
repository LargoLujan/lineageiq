# Changelog

All notable changes to LineageIQ are documented here. The project follows [Semantic Versioning](https://semver.org/); until 1.0.0, minor versions may change behaviour.

## [0.2.0] - 2026-11-04

### Added

- One-command demo image on GitHub Container Registry (`ghcr.io/largolujan/lineageiq`), built from `Dockerfile.demo`, with the synthetic Contoso tenant baked in and the stdio MCP server available through `docker run -i`.
- `demo-image` workflow that builds and smoke-tests the image (web UI, demo data and MCP tools) on pull requests and publishes it on releases.
- Setup guides: `docs/102_admin_panel_and_user_auth.md`, `docs/105_fabric_native_discovery_setup.md` and `docs/106_onelake_web_data_publish.md`.
- Richer demo tenant: execution history, schedules, failure hotspots and workspace role assignments, so the execution, schedule, role and planning views have data in demo mode.
- Favicon.

### Changed

- The web UI now starts in English, including the DAG view and static tooltips; Spanish stays one click away in the language menu.
- Product name: the web UI, the OpenAPI document (`LineageIQ API`, version 0.2.0), notification emails and the MCP servers (`lineageiq`, `lineageiq-remote`, `lineageiq-http`) all use LineageIQ.
- In demo mode the scan panel is hidden, since scans need a signed-in user.
- API messages that were only in Spanish are now in English, and the Warehouse and `/mcp` unavailability messages say why the feature is off.
- The Docker Compose service, image and container are named `lineageiq`, the port is published on `127.0.0.1` only, and the Cloudflare quick tunnel is off by default (opt in with `LINEAGE_WEB_PUBLIC_TUNNEL=true`).
- The install wizard lists the pipeline notebooks in their real dependency order (`NB_Confirm_Source_Object_Types` after `NB_Discover_Pipeline_Object_Lineage`).
- Generated script reports (`docs/10_*.md` to `docs/99_*.md`) are git-ignored; `73_discover_governance_scan.ps1` writes `docs/73_governance_scan.md`.
- Documentation, code comments and notebook comments are in English, without internal milestone labels.
- `70_extract_control_framework_lineage.py` resolves the Azure CLI executable instead of running it through a shell.

### Removed

- Local AI-assistant working files and an internal publication checklist from the repository.

## [0.1.0] - 2026-11-04

- First public release: read-only discovery scripts and Fabric notebooks, object-level lineage and reverse-impact views, governance panel, REST API, MCP servers and the synthetic demo tenant.

[0.2.0]: https://github.com/LargoLujan/lineageiq/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/LargoLujan/lineageiq/releases/tag/v0.1.0
