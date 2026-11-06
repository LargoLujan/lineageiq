# Security Policy

## Supported versions

Only the latest release receives security fixes. Older releases are not patched; upgrade to the latest one instead.

| Version | Supported |
| --- | --- |
| 0.2.x (latest release: [v0.2.0](https://github.com/LargoLujan/lineageiq/releases/latest)) | Yes |
| 0.1.x and earlier | No |

The same rule applies to the demo image: use `ghcr.io/largolujan/lineageiq:latest` or the tag of the latest release.

## Reporting a vulnerability

Please do **not** report security problems in public issues, discussions or pull requests.

Report them privately through GitHub:

1. Open the [Security tab](https://github.com/LargoLujan/lineageiq/security) of this repository.
2. Select **Report a vulnerability** ([direct link](https://github.com/LargoLujan/lineageiq/security/advisories/new)).
3. Fill in the form. Only you and the maintainer can see the report.

### What to include

- The version or image tag you tested, and how you run LineageIQ: the demo image, the local web server, Docker Compose, `Dockerfile.render`, the local discovery scripts or the Fabric notebooks.
- The affected component, for example a REST route, sign-in and sessions, API keys, an MCP server, a discovery script, a notebook or a Docker image.
- Steps to reproduce or a proof of concept. Where possible, reproduce it against the demo image or the synthetic Contoso data.
- The impact: what an attacker could read, change or reach, and what access they need first.
- A suggested fix, if you have one.

Do not put real tenant data, tokens, API keys, client secrets or personal data in the report. If a log is needed, redact names, identifiers and hostnames first.

## What to expect

LineageIQ has a single maintainer, so responses are best effort:

- The aim is to acknowledge a report within 7 days. This is a goal, not a guaranteed service level.
- You will get updates in the private advisory while the report is assessed and fixed.
- Once a fixed release is out, the advisory is published. You will be credited in it unless you ask not to be.

## Security model

These notes describe how the project is built, so you can judge what counts as a vulnerability. Details are in the [admin panel and authentication guide](https://github.com/LargoLujan/lineageiq/blob/main/docs/102_admin_panel_and_user_auth.md).

- **Read-only discovery.** The discovery scripts and Fabric notebooks read from the Fabric and Power BI APIs and from the SQL endpoints they catalogue. They write only LineageIQ's own results: local files, or the Warehouse and Lakehouse you set aside for LineageIQ. Other writes are opt-in, admin-initiated actions on targets you designate: publishing results to a Warehouse or OneLake folder, triggering the discovery pipeline, and the admin-only installer. A discovery step that writes to a scanned item is a bug worth reporting.
- **Authentication.** Reads need a signed-in Microsoft Entra ID session (device-code flow through MSAL) or an admin-issued API key. Admin routes check an allowlist in `config/admin_settings.json`; with an empty allowlist nobody is an admin.
- **API keys.** Only a SHA-256 hash of each key and its last four characters are stored. The raw key is shown once, at creation. Keys are `read_only` (the default) or `full`, and can expire. Only `full` keys can trigger or stop scans.
- **Sessions.** Sessions live in server memory only and expire after 8 hours idle or 24 hours in total. The cookie is `HttpOnly` and `SameSite=Lax`, and `Secure` when the request arrived over HTTPS. Cookie-authenticated `POST` requests are checked against the server's own origin.
- **Rate limiting.** `/api/*` allows 180 requests per 60-second window per client IP and answers `429` with `Retry-After` beyond that.
- **Remote MCP endpoint.** The Streamable HTTP MCP server runs as a subprocess bound to `127.0.0.1` and is reached only through the `/mcp` reverse proxy. Every request, including `initialize`, needs `Authorization: Bearer <api-key>`. There is no OAuth flow.
- **Secrets.** Configuration fields such as `sp_client_secret_ref` and `password_ref` hold the name of an environment variable, not the secret itself.
- **Demo mode.** `LINEAGE_DEMO_MODE=1` makes every catalogue and lineage read public and changes nothing for writes. It is meant only for the synthetic Contoso tenant. The demo image contains only public code and that synthetic data, runs as a non-root user and starts the server with `--no-mcp-http`.
- **Network exposure.** The Cloudflare quick tunnel is off by default (`LINEAGE_WEB_PUBLIC_TUNNEL=false`), and Docker Compose publishes the port on `127.0.0.1` only. The server itself binds to `0.0.0.0` by default; pass `--bind 127.0.0.1` to keep it local.

### Usually not a vulnerability

- Data exposed because `LINEAGE_DEMO_MODE` was set on real tenant data, because `allow_anonymous_scans` was turned on, or because the quick tunnel was opened on unprotected data. These settings are documented as unsafe for that use. A way to make demo mode allow a **write** is a vulnerability, though.
- False positives or misses of the heuristic sensitivity classifiers.
- Vulnerabilities in Microsoft Fabric, Power BI, Microsoft Entra ID or third-party packages themselves. Report those to the vendor or the package maintainers. Outdated dependencies in this repository are handled as normal Dependabot updates.
