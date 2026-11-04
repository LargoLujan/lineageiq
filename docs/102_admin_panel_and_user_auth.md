# Admin panel and user authentication

This guide describes how people sign in to LineageIQ, who is allowed to do what, how automation callers authenticate, and what each tab of the admin panel is for. Everything here is read from the code in `backend/scripts/lineage_web/` and `frontend/semantic-lineage/app.js`.

LineageIQ maps lineage at **object level** (items, tables, views, stored procedures, files). It does not build column-to-column lineage.

## Quick reference

| Topic | Where it lives |
| --- | --- |
| Settings file | `config/admin_settings.json` (git-ignored; template: `config/admin_settings.example.json`) |
| Sign-in code | `backend/scripts/lineage_web/auth.py` |
| Settings load, save and merge | `backend/scripts/lineage_web/admin_settings.py` |
| Defaults and limits | `backend/scripts/lineage_web/constants.py` |
| Request gates (session, API key, admin, demo mode) | `backend/scripts/lineage_web/handler.py` |
| Route registry (auth level per route) | `backend/scripts/lineage_web/routes.py` |
| Admin panel UI | `frontend/semantic-lineage/app.js` (`adminTabGroups`) |

## Sign-in (Microsoft Entra ID device code)

The web UI signs users in with the OAuth device-code flow through MSAL. No client secret and no redirect URI are needed.

1. The browser calls `POST /api/auth/device-start`. The server starts an MSAL device flow against `https://login.microsoftonline.com/<tenant_id>` and answers `202` with `flow_id`, `user_code` and `verification_uri`.
2. The user opens the verification URL and enters the code.
3. The browser polls `GET /api/auth/device-status?flow_id=<id>` until the status is `done`. That response sets the session cookie.
4. `GET /api/auth/me` returns the signed-in identity and its flags. `POST /api/auth/logout` ends the session and clears the cookie.

Details:

- The requested scope is `https://api.fabric.microsoft.com/.default`. Tokens for other resources (SQL, OneLake) are minted silently from the same MSAL cache when needed.
- `tenant_id` comes from `config/admin_settings.json`.
- `entra_client_id` is optional. **When it is empty, the server uses the public client ID of the Azure CLI** (`04b07795-8ddb-461a-bbee-02f9e1bf7b46`), so sign-in works without an app registration. Set your own client ID only if your organisation requires a dedicated Entra app registration.
- Each client IP can have at most 3 pending sign-ins (`429 too_many_pending_flows` beyond that). A flow that is never completed is discarded after 15 minutes.
- At sign-in the server checks once whether the account holds the Entra **Fabric Administrator** role (one call to the Fabric admin API). The result is `is_fabric_tenant_admin`. It is separate from `is_admin` below: it decides whether a full scan covers the whole tenant or only the workspaces the user can see.

## Sessions and the cookie

| Property | Value |
| --- | --- |
| Cookie name | `fabric_lineage_session` |
| Flags | `HttpOnly`, `SameSite=Lax`, `Path=/` |
| `Secure` flag | Set only when the request arrived as HTTPS (`X-Forwarded-Proto: https` from a reverse proxy). Direct HTTP on a LAN gets a cookie without `Secure`. |
| Idle timeout | 8 hours |
| Absolute lifetime | 24 hours |
| Storage | In server memory only. A restart signs everyone out. |

- The session ID is never returned in a JSON body. It only travels in the cookie.
- Any `POST` that relies on the cookie goes through an `Origin`/`Referer` check against the server's own origin (a CSRF defence). Calls that use an API key are not affected.
- Ended sessions (signed out, revoked by an admin, expired) are appended to `dbo.session_history` in the configured Warehouse. If the Warehouse is not available, the "history" view falls back to an in-memory list that holds the last 200 entries and is lost on restart.
- Fabric scans started by a signed-in user run with that user's own delegated token, so they only see what that user can see in Fabric.
- When an **admin** signs in, the server also stores that session's token cache in `config/service_session.json` (git-ignored). The server uses it as a fallback identity for live Warehouse and OneLake reads when no service principal is configured. See [105](105_fabric_native_discovery_setup.md) and [106](106_onelake_web_data_publish.md).

## Allowlist: who can do what

Permissions live in the `users` table of `config/admin_settings.json`. Each row has:

| Field | Meaning |
| --- | --- |
| `email` | Matched case-insensitively against the sign-in identity (`preferred_username`, then `email`, then `upn`) |
| `full_name`, `job_title` | Display only |
| `is_admin` | Can open the admin panel and call admin routes |
| `can_full_scan` | Can start full-tenant scans, production-execution scans, Warehouse uploads and OneLake publishes |
| `can_install` | Stored, but **not enforced anywhere yet**. The install wizard currently requires `is_admin`. |

The panel derives the flat lists `admin_emails`, `full_scan_emails` and `install_emails` from this table when it saves. The server's permission checks read those flat lists, so they must stay in the file.

Other rules:

- **Fail closed.** With an empty allowlist nobody is an admin. The defaults contain no email address.
- Saving settings through the panel requires a non-empty `tenant_id` and a non-empty `admin_emails` list, so an admin cannot lock everyone out.
- **Environment seeds.** `ADMIN_EMAILS` and `FULL_SCAN_EMAILS` (comma-separated) fill `admin_emails` and `full_scan_emails` only while those lists are empty in the file. The seeds are never written back to disk.
- **Migration.** If an older file has `admin_emails`/`full_scan_emails` but no `users`, the server builds `users` from them on first load and saves it.
- Any signed-in user can read catalogue data and start a **single-workspace** scan. Full scans need `can_full_scan`.
- The add-user box in the Allowed users tab offers a directory search (`/api/admin/tenant-users`). It needs a Microsoft Graph permission. If the tenant has not consented to it, typing the email by hand still works.

### `allow_anonymous_scans`

`allow_anonymous_scans` (default `false`) lets a request with **no session and no API key** start scans using the server's shared `az` CLI session. It is an opt-in for older setups. It is **not shown in the admin panel**: set it by editing `config/admin_settings.json`. Leave it off unless you need it.

## API keys

API keys are for automation that cannot do a device-code sign-in, such as a Fabric pipeline Web activity or an MCP agent. Admins manage them in the **API keys** tab.

| Property | Behaviour |
| --- | --- |
| Format | `flm_` followed by a random URL-safe string |
| Storage | Only a SHA-256 hash and the last four characters (`key_preview`) are saved in `config/admin_settings.json` |
| Shown once | The raw key is returned only by the creating call. It cannot be recovered later. |
| Scope | `read_only` (default for new keys) or `full`. Keys saved before scopes existed count as `full`. |
| Expiry | Optional `expires_at`. An expired key is treated exactly like an unknown key. |
| Metadata | Name (unique), description, creator, creation date. "Last used" is kept in memory only and resets on restart. |
| Revoking | Removes the key and appends an entry (name, preview, who, when) to `revoked_api_keys`, capped at the latest 100. |

What each scope can do:

- Both scopes can call every route that accepts `session_or_api_key` for reading, and the governance routes that accept `admin_or_api_key`.
- Only `full` keys can trigger or stop scans, the Warehouse upload and the OneLake publish. A `read_only` key gets `403 insufficient_scope` there. A `full` key counts as authorised for full scans without being on `full_scan_emails`.
- REST callers send the key as `X-Api-Key: <key>`. The MCP endpoint (`/mcp`) uses `Authorization: Bearer <key>`. See [110](110_mcp_remote_setup.md).
- `POST /api/admin/settings` ignores any `api_keys` field, so an unrelated settings save cannot overwrite the keys.

## Demo mode (`LINEAGE_DEMO_MODE`)

Setting the environment variable `LINEAGE_DEMO_MODE` to `1`, `true` or `yes` before starting the server makes **read** routes and `/data/*` files available without sign-in. It exists for the synthetic Contoso tenant produced by `backend/scripts/generate_demo_data.py`.

- It widens reads only. Scan triggers, admin routes, API key management, comments and favourites still require a session or API key.
- `GET /api/auth/me` still returns `401` without a session, but adds `"demo_mode": true`. The UI uses that flag to skip the sign-in gate and show a "Demo data" badge.
- The variable is read on every request, so only whoever starts the process controls it.
- **Never enable it on a deployment that serves real tenant data.** It makes every catalogue and lineage read public.

## Admin panel tabs

Admins see **Admin settings** in the profile menu (top right). The panel has four groups and 19 tabs. Most tabs edit one block of `config/admin_settings.json`. Secrets are never stored in that file: fields named `*_secret_ref` or `password_ref` hold the **name of an environment variable** that the server reads at run time.

### Setup

| Tab | Purpose |
| --- | --- |
| Tenant & auth | Tenant ID and optional Entra client ID. A second card lists the extra permissions the Governance panel's Scanner API data needs (Power BI Administrator Entra role, Admin API tenant settings, optional Microsoft Graph permission) and points to `backend/scripts/73_discover_governance_scan.ps1`. |
| Write storage | The Warehouse (or Lakehouse) that receives the `dbo.bronze_*` tables: workspace and item pickers, SQL endpoint, authentication (service principal or the clicking user's session), "Test connection" and "Copy data now". See [101](101_medallion_lakehouse_provisioning.md). |
| Fabric-native scan | Which Fabric Data Pipeline runs the discovery notebooks. See [105](105_fabric_native_discovery_setup.md). |
| Explorer data (OneLake) | Which Lakehouse serves the explorer JSON files, plus "Publish data now". See [106](106_onelake_web_data_publish.md). |
| External sources | Registry of non-Fabric sources (connection details; passwords are referenced by environment variable name) with a connection test. The test is implemented in `backend/scripts/66_test_external_source_connection.ps1`. The tab also lists external servers detected in the last scan. |
| Notifications | Shared SMTP settings, your own email subscription (scan succeeded, failed or stopped, with a language), and an optional Microsoft Teams webhook with the same three triggers. The SMTP and Teams sections each have a test button. |

### Access

| Tab | Purpose |
| --- | --- |
| Allowed users | The `users` table described above. |
| Active sessions | Who is signed in now (email, name, object ID, tenant ID, last seen, number of workspaces visible, whether the account is a Fabric administrator), with a revoke button per user. A collapsible history lists ended sessions. |
| API keys | Create, list and revoke keys (see above). It also shows the `/mcp` URL and the commands to connect an MCP client. |

### Insights

| Tab | Purpose |
| --- | --- |
| Capacity | Every capacity in the tenant with region, state, item count and failure totals. It also holds the connection to the Microsoft Fabric Capacity Metrics app's semantic model (`capacity_metrics` block), the only source of real capacity-unit consumption. |
| Modification history | Items and dependencies added, removed or modified, per scan or over a date range. |
| Analytics | Usage of the explorer itself over 7, 30 or 90 days (stored in the Warehouse table `bronze_usage_events`), plus a card with HTTP request counts per route since the server last started. |

### Content

These tabs hold lists that an admin curates by hand. They are saved in `config/admin_settings.json` and shown in the explorer.

| Tab | Purpose |
| --- | --- |
| Certifications | Marks items as official or certified sources. |
| Business glossary | Business terms linked to the items that represent them. |
| Tags | Free-form tags on items. |
| Data quality | Rules (null percentage, distinct count, row count) evaluated against the column profiles collected by `NB_Discover_Column_Profile.py`. |
| Sensitivity classifiers | Custom sensitivity categories (regular-expression patterns) added to the built-in ones. They apply to name-based detection only. |
| Data products | Groups of items under an owner and a description, across workspaces. |
| Privacy systems | A hand-maintained checklist of systems, inside or outside Fabric, that hold each sensitive-data category, with an owner. No automatic connection to those systems. |

The Governance and Privacy panels in the header are separate from the admin panel and are also visible only to admins.
