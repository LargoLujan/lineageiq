"""Non-path module-level constants shared across the lineage_web package.
Split out of lineage_web_server.py (D.3, 2026-07-08) -- pure code motion.
"""
import re

SESSION_COOKIE_NAME = "fabric_lineage_session"
AZURE_CLI_FALLBACK_CLIENT_ID = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
FABRIC_TOKEN_SCOPES = ["https://api.fabric.microsoft.com/.default"]
SESSION_IDLE_TIMEOUT_SECONDS = 8 * 3600
SESSION_ABSOLUTE_LIFETIME_SECONDS = 24 * 3600
MAX_SESSION_HISTORY_ENTRIES = 200
DEVICE_FLOW_STALE_SECONDS = 900
MAX_PENDING_DEVICE_FLOWS_PER_IP = 3
# A request that arrives while a scan is already running is queued instead
# of rejected (Tanda 10) -- this caps how many can pile up behind it so a
# runaway caller (or someone clicking repeatedly) can't grow the queue
# without bound; a real person queuing this many distinct scans in one
# sitting is not a case this project needs to optimize for.
MAX_QUEUED_SCANS = 20
# Applies to /api/* only (Tanda 5, E.3) -- static file serving is excluded
# since one page load can legitimately fire a dozen+ requests (HTML, CSS,
# several vendor bundles, several large data JSON files) with no
# meaningful abuse surface of its own. Calibrated against real frontend
# polling: /api/status every 4s (~15/min) and device-code sign-in status
# every 3s (~20/min) are the two tightest legitimate loops in app.js, so
# even both running at once from one tab (~35-40/min) leaves ~4x headroom
# before this trips.
RATE_LIMIT_WINDOW_SECONDS = 60
RATE_LIMIT_MAX_REQUESTS_PER_WINDOW = 180
DEFAULT_ADMIN_SETTINGS = {
    # Empty, not a specific person's tenant/email -- this is a fallback used
    # by _merge_admin_settings() for any key genuinely absent from
    # config/admin_settings.json, not just a one-time bootstrap value, so
    # baking in a real identity here would make it come back as a silent
    # admin fallback if that key were ever dropped from the real config
    # (which is git-ignored precisely so a fork/redeploy doesn't inherit
    # the original deployment's identity). First-time setup means copying
    # config/admin_settings.example.json to config/admin_settings.json and
    # filling these in by hand -- fail closed (nobody is admin) until then,
    # not fail open with someone else's email.
    "tenant_id": "",
    "entra_client_id": "",
    "admin_emails": [],
    "full_scan_emails": [],
    # Added 2026-08-24 (Fase 3): the admin panel's "Usuarios permitidos" tab
    # became one hand-maintained table (email/full name/job title/three
    # permission checkboxes) instead of two flat email lists typed blind --
    # see frontend's renderAdminUsersTab. admin_emails/full_scan_emails above
    # and install_emails below are now DERIVED from this list client-side at
    # save time (see deriveAllowlistsFromUsers) and kept only because
    # _email_in_allowlist's ~10 call sites across auth.py/handler.py/
    # scan_manager.py already read them as flat lists -- changing those call
    # sites to read `users` directly would be a much larger, harder-to-verify
    # change for no behavioral benefit.
    "users": [],
    # Same flat-list-derived-from-users convention as admin_emails/
    # full_scan_emails above, for the "install/register workspaces"
    # permission. Not enforced anywhere yet -- the multi-tenant installer
    # wizard it belongs to doesn't exist yet (Fase 5) -- but the checkbox
    # already exists in the users table, so the flag has somewhere real to
    # live in the meantime instead of being invented twice later.
    "install_emails": [],
    # Off by default: with per-user sign-in now in place, a scan/stop request
    # with no session should require signing in rather than silently falling
    # back to the shared `az` CLI session -- that fallback used to be the
    # ONLY behavior (before sign-in existed) and stays available here as an
    # explicit opt-in for anyone who wants it back, not a silent bypass of
    # full_scan_emails.
    "allow_anonymous_scans": False,
    "lakehouse": {
        "workspace_name": "",
        "workspace_id": "",
        "lakehouse_name": "",
        "lakehouse_id": "",
        "capacity_name": "",
        "sql_endpoint_connection_string": "",
        # Added 2026-07-20, purely additive: "Lakehouse" (default, backward
        # compatible with every config saved before this field existed) or
        # "Warehouse". Everything else in this object keeps the same field
        # names regardless of which item type was actually picked -- see
        # fabric_api._fetch_warehouses_in_workspace's docstring for why that
        # was the deliberate choice instead of a wider rename.
        "item_type": "Lakehouse",
        # Off by default: once populated (typically right after the first
        # manual "Copiar datos ahora" run from the admin panel), every
        # subsequent workspace/full scan also uploads Bronze straight to
        # this write-target's SQL endpoint, not just to local CSVs -- see
        # scan_manager.py's _maybe_trigger_warehouse_upload.
        "auto_upload_after_scan": False,
        # Added 2026-07-21: how 66_test_external_source_connection.ps1 (test)
        # and 67_upload_bronze_to_warehouse.ps1 (real upload) authenticate to
        # this SQL endpoint. "user_session" (default, backward compatible)
        # uses whichever admin is clicking the button's own delegated token
        # -- fine for a one-off manual test/upload, but it stops working the
        # moment nobody is signed in, which is wrong for a target that's
        # supposed to receive every future scheduled/automated scan.
        # "service_principal" uses the sp_* fields below instead: an Entra
        # app registration's own client-credentials grant, which keeps
        # working unattended (see Get-ServicePrincipalAccessToken in both
        # scripts) -- the right choice once this write-target is meant to be
        # a permanent, always-on database rather than a one-time copy.
        "auth_mode": "user_session",
        # Defaults to the top-level tenant_id above when left blank.
        "sp_tenant_id": "",
        "sp_client_id": "",
        # Env var NAME holding the app registration's client secret value,
        # same password_ref convention as external_sources[].password_ref
        # below -- the real secret lives in .env, never in this JSON.
        "sp_client_secret_ref": "",
        # Added 2026-07-24: the write side (auto_upload_after_scan above)
        # already keeps dbo.bronze_* tables fresh after every scan; this is
        # the read-side opt-in -- "local_files" (default, unchanged behavior)
        # keeps catalog.py reading index/*.csv straight off this machine's
        # disk; "warehouse" makes it query dbo.bronze_workspaces/items/
        # dependencies live instead (see lineage_web/warehouse.py), which is
        # what lets a web server running anywhere (not just this machine)
        # show current data without a redeploy. Requires auth_mode ==
        # "service_principal" above -- falls back to local_files behavior
        # automatically if the Warehouse read fails for any reason.
        # 2026-08-24: default flipped to "warehouse" -- this project no
        # longer runs local scans/keeps local CSVs current, so local_files
        # would just be permanently stale (see Fase 1 admin-panel cleanup,
        # which also removed the UI toggle for this).
        "web_read_mode": "warehouse",
    },
    # Added 2026-07-24: lets a scan run entirely inside Fabric (an existing
    # Data Pipeline, triggered on demand via the Job Scheduler REST API)
    # instead of scan_manager.py spawning local PowerShell/az-cli -- see
    # fabric_pipeline.py. "local" (scan_manager.py spawning subprocesses on
    # this machine) still exists as a code path but is no longer reachable
    # from the admin panel (2026-08-24 Fase 1 cleanup removed the mode
    # toggle -- this project only ever scans via the Fabric pipeline now).
    # A separate service principal from `lakehouse` above on purpose (the
    # pipeline lives in its own workspace/item and only needs Fabric API
    # permissions, not database access) -- fine to point both at the same
    # app registration if that's simpler for a given tenant.
    "discovery_pipeline": {
        "mode": "fabric_pipeline",
        "workspace_id": "",
        "pipeline_item_id": "",
        # Display-only (2026-08-18) -- resolved and saved alongside the
        # ids by the admin panel's live picker (see fabric_api._fetch_
        # data_pipelines_in_workspace), same "id is what's actually used,
        # name is just what's shown back" split as lakehouse.workspace_
        # name/lakehouse_name above. A hand-edited config only setting
        # the ids still works fine; these just stay blank until the next
        # save through the panel.
        "workspace_name": "",
        "pipeline_name": "",
        "sp_tenant_id": "",
        "sp_client_id": "",
        "sp_client_secret_ref": "",
    },
    # Added 2026-07-24: where the big generated JSON payloads (lineage-
    # explorer.json and friends -- see onelake_data.py's own docstring for
    # the full list) are served FROM. "local_files" (handler.py reading
    # frontend/semantic-lineage/data/ off this machine's disk) still exists
    # as a code path but is no longer reachable from the admin panel
    # (2026-08-24 Fase 1 cleanup removed the mode toggle and required
    # workspace_name/lakehouse_name -- this project always serves live from
    # OneLake now). "onelake" fetches/caches each file from a Fabric
    # Lakehouse's OneLake Files area, published there by backend/scripts/
    # 68_publish_web_data_to_onelake.py (this does NOT move the JSON-
    # building logic itself into Fabric, only where the finished file
    # lives). Deliberately separate from `lakehouse` above: that write
    # target is very often a Warehouse (SQL tables only, no Files/ area),
    # while this needs an actual Lakehouse -- can point at a different
    # item than `lakehouse`, or the same one if it happens to be a
    # Lakehouse too.
    "onelake_data": {
        "mode": "onelake",
        # workspace_name/lakehouse_name (by NAME, not id) are all this
        # block has ever actually used -- onelake_data.py's _download()
        # only ever reads those two off `config`, confirmed by grep
        # (2026-08-18 admin-panel audit finding): workspace_id/
        # lakehouse_id fields used to exist here but nothing ever read or
        # wrote them, unlike `lakehouse` above (whose *_id fields are real
        # -- resolved from the admin's own live picker selection).
        "workspace_name": "",
        "lakehouse_name": "",
        "sp_tenant_id": "",
        "sp_client_id": "",
        "sp_client_secret_ref": "",
        # Off by default: when on, a successful FULL scan (never a
        # single-workspace one -- see scan_manager._maybe_trigger_onelake_
        # publish's own comment on why) queues a republish of the big
        # generated JSON payloads to OneLake, same "one manual run turns
        # this on" convenience as lakehouse.auto_upload_after_scan.
        "auto_publish_after_scan": False,
    },
    # Added 2026-08-24: connection to the Microsoft Fabric Capacity Metrics
    # app's own semantic model -- the only place real CU (Capacity Unit)
    # consumption per item/capacity actually lives (see capacity_metrics.py's
    # own docstring; purview_insights._get_capacity_insight's "CU (mes)"
    # column has always shown "No disponible" for exactly this reason). The
    # app itself can't be installed via any API (a first-party Marketplace
    # template app, not a Fabric item this project's `fab`-based installer
    # can provision) -- see the admin panel's Capacidad tab for the manual
    # install steps and a "Detectar automáticamente" button that fills these
    # fields in once it's there. Same auth_mode/sp_* shape as `lakehouse`
    # above: "user_session" (default) reuses whichever admin is viewing the
    # tab's own delegated access; "service_principal" keeps the tab's data
    # loading unattended for every admin, not just whoever happens to be
    # signed in with dataset access.
    "capacity_metrics": {
        "workspace_name": "",
        "workspace_id": "",
        "dataset_name": "",
        "dataset_id": "",
        "auth_mode": "user_session",
        "sp_tenant_id": "",
        "sp_client_id": "",
        "sp_client_secret_ref": "",
    },
    "external_sources": [],
    # Static, machine-to-machine credentials for automation callers that
    # can't do an interactive Entra device-code sign-in -- the primary case
    # is a Fabric pipeline's Web activity triggering/polling a scan (see
    # Tanda 5, E.0/E.1). Each entry is {name, key_hash, key_preview,
    # created_at, description, created_by, scope, expires_at} (last 4
    # added 2026-08-18, admin-panel completeness pass -- with several keys
    # in use, name alone didn't say who a key was for or what it could do).
    # The raw key is only ever shown once, at creation time, in the admin
    # panel -- key_hash IS the stored credential-check value (nothing else
    # to hash against, same tradeoff as an API gateway's static key), so
    # this file's git-ignored status is what protects it, exactly like
    # every other secret-shaped field already in this config. scope is
    # "read_only" or "full" (missing/legacy = "full", see auth.py's
    # _api_key_scope); expires_at is an optional ISO timestamp, blank means
    # never (see auth.py's _api_key_expired).
    "api_keys": [],
    # Audit trail of revoked keys (2026-08-18) -- POST /api/admin/api-
    # keys/revoke appends here instead of only deleting from api_keys
    # above, bounded to the most recent 100 entries. Each entry:
    # {name, key_preview, description, revoked_at, revoked_by} -- never
    # key_hash, nothing here was ever a secret.
    "revoked_api_keys": [],
    # SMTP is shared/admin-wide (one relay for the whole tool); "subscribers"
    # is each admin's own personal opt-in (which statuses, which language) --
    # see the admin panel's Notifications tab. smtp_password_ref follows the
    # same convention as external_sources[].password_ref: an env var NAME,
    # never a plaintext secret in this file.
    "notifications": {
        "smtp_host": "",
        "smtp_port": 587,
        "smtp_use_tls": True,
        "smtp_user": "",
        "smtp_password_ref": "",
        "from_address": "",
        "subscribers": [],
        # Microsoft Teams webhook (Tanda A follow-up) -- fully implemented
        # in the admin panel and scan_manager._maybe_send_teams_
        # notification since it shipped, but never added here, so a fresh
        # config/admin_settings.json never showed these keys and this
        # dict (documented as the schema of record for every other
        # setting) silently drifted from what the app actually reads/
        # writes (2026-08-18 admin-panel audit finding).
        "teams_webhook_url": "",
        "teams_language": "es",
        "teams_notify_succeeded": False,
        "teams_notify_failed": False,
        "teams_notify_cancelled": False,
    },
    # Tanda C (Purview-inspired, 2026-07-09): a "certified/official source"
    # badge an admin applies by hand -- deliberately just a curated list of
    # qualified_names (+ who/when/why), not derived from anything scanned,
    # since "this is the trusted one" is a human judgment call Purview's own
    # certification feature treats the same way. Each entry:
    # {qualified_name, certified_by, certified_at, note}.
    "certified_items": [],
    # A real business glossary (distinct from the existing, static,
    # tool-concept glossary in i18n.*.glossary -- "what does 'confidence'
    # mean", not "what is an Active Customer") -- each entry:
    # {term_es, term_en, definition_es, definition_en, linked_qualified_names}.
    "business_glossary": [],
    # Roadmap Fase 2 (2026-08-17): free-form tags on items, same
    # admin-curated pattern as certified_items just above -- a plain list an
    # admin edits by hand rather than anything scanned, so "this is a
    # finance report" is as easy to record as "this is the certified one".
    # Multiple entries can share a qualified_name (several tags on one
    # item) or a tag (grouping several items). Each entry:
    # {qualified_name, tag, tagged_by, tagged_at}.
    "tags": [],
    # Roadmap Fase 1 (2026-08-31, Purview-parity push): data-quality rules
    # an admin defines by hand, evaluated against dbo.bronze_column_profile
    # (already collected by NB_Discover_Column_Profile.py -- no new scan,
    # no new Fabric permission, see data_quality.py). Same admin-curated
    # list pattern as certified_items/tags above. Each entry:
    # {id, workspace_name, lakehouse_name, table_name, column_name (""
    # means the rule is table-scoped, not column-scoped), rule_type
    # ("null_percentage_max"|"distinct_count_min"|"row_count_min"),
    # threshold (number), created_by, created_at, note}.
    "data_quality_rules": [],
    # Roadmap Fase 2 (2026-08-31, same Purview-parity push): admin-defined
    # sensitivity categories on top of the 9 built-in ones in
    # sensitivity_classifier.py -- see that module's own
    # _custom_category_registry for exactly how these merge in (and its
    # docstring for what this does NOT reach yet: the 3D graph map and
    # either Fabric notebook's own hand-ported copy). Each entry: {key
    # (must not collide with a built-in category key), label_es, label_en,
    # patterns (list of regex strings, ANY match = category matches, same
    # semantics as a built-in category's own "patterns"), risk
    # ("low"|"medium"|"high"|"very_high"), recommendation_es,
    # recommendation_en, created_by, created_at}.
    "custom_sensitivity_categories": [],
    # Roadmap Fase 3 (2026-08-31, same Purview-parity push): Purview's
    # Unified Catalog groups assets into "data products" with an owner and
    # a description, cutting across whatever workspace/domain each asset
    # actually lives in. Named "data_products" (not "domains") on purpose
    # -- this project already surfaces Fabric's OWN native per-workspace
    # "Domain" field (data.domain_name in the frontend detail panel,
    # scanned from the tenant), so reusing that word here would collide
    # with an existing, different, already-real concept. Same admin-
    # curated-list pattern as business_glossary just above (in fact the
    # closest existing precedent: same linked_qualified_names chip-list
    # shape). Each entry: {id, name, owner_email, description_es,
    # description_en, linked_qualified_names, created_by, created_at}.
    "data_products": [],
    # Roadmap Fase 6 (2026-08-31, follow-up to the Fase 5 privacy locator):
    # admin-maintained "known systems" per sensitivity category -- most of
    # what a real data-subject-rights request touches (biometric access
    # control, a CRM, a marketing platform) lives entirely OUTSIDE this
    # Fabric tenant, so the locator alone can never point to it. This is a
    # plain, hand-maintained checklist (no automated discovery, no live
    # connection to those systems -- that's out of scope by design, same
    # as everything else this project only ever reads Fabric/OneLake/
    # Azure DevOps/SharePoint), so staff handling a real request have a
    # documented starting point instead of rediscovering it from scratch
    # each time. Each entry: {id, category (a sensitivity_classifier.py
    # key, built-in or one of custom_sensitivity_categories' own keys),
    # system_name, in_fabric (bool -- mainly for documenting an OUTSIDE-
    # Fabric system, though a Fabric one can be logged too for a single
    # place to see "here's everywhere, in and out"), owner_name,
    # owner_email, notes, created_by, created_at}.
    "privacy_external_systems": [],
}
FULL_SCAN_LABEL = "__full_scan__"
EXECUTIONS_SCAN_LABEL = "__production_executions__"
WAREHOUSE_UPLOAD_LABEL = "__warehouse_upload__"
ONELAKE_PUBLISH_LABEL = "__onelake_publish__"
HISTORY_FIELDS = [
    "workspace_name", "started_at", "ended_at", "duration_seconds", "status",
    "step_count", "degraded_step_count", "failed_step", "error", "triggered_by_email",
    "diff_added", "diff_removed", "diff_modified", "diff_by_type_json", "diff_path",
]
DIFF_TRACKED_FIELDS = ("item_name", "description", "sensitivity_label", "folder_id", "default_identity", "status")
# Same idea as DIFF_TRACKED_FIELDS, one level down the graph (roadmap
# Nivel 1, 2026-08-17: "historial point-in-time de dependencias") -- a
# dependency's identity is the edge itself (from/to/relationship_type, see
# scan_manager._diff_dependencies), so only fields that can change WITHOUT
# it becoming a different edge belong here.
DEPENDENCY_DIFF_TRACKED_FIELDS = ("confidence", "evidence")
COMPRESSIBLE_SUFFIXES = {".json", ".js", ".css", ".html", ".htm", ".mmd", ".md", ".svg", ".txt"}
MIN_COMPRESS_BYTES = 1024
NOTIFICATION_TEXT = {
    "es": {
        "subject": {
            "succeeded": "Escaneo completado",
            "failed": "Escaneo con errores",
            "cancelled": "Escaneo detenido",
        },
        "heading": {
            "succeeded": "El escaneo terminó correctamente",
            "failed": "El escaneo terminó con errores",
            "cancelled": "El escaneo fue detenido",
        },
        "full_scan_label": "Escaneo completo del tenant",
        "scope_label": "Alcance",
        "triggered_by_label": "Iniciado por",
        "duration_label": "Duración",
        "anonymous": "anónimo",
        "changes_heading": "Cambios detectados",
        "no_changes": "No se detectaron cambios en los elementos de este alcance.",
        "type_col": "Tipo",
        "added_col": "Añadidos",
        "removed_col": "Eliminados",
        "modified_col": "Modificados",
        "error_label": "Error",
        "failed_step_label": "Paso que falló",
        "footer": "Este correo se envió automáticamente porque tienes activadas las notificaciones de escaneo en el panel de administración de Fabric Lineage Mapper.",
    },
    "en": {
        "subject": {
            "succeeded": "Scan completed",
            "failed": "Scan finished with errors",
            "cancelled": "Scan stopped",
        },
        "heading": {
            "succeeded": "The scan finished successfully",
            "failed": "The scan finished with errors",
            "cancelled": "The scan was stopped",
        },
        "full_scan_label": "Full tenant scan",
        "scope_label": "Scope",
        "triggered_by_label": "Started by",
        "duration_label": "Duration",
        "anonymous": "anonymous",
        "changes_heading": "Changes detected",
        "no_changes": "No item changes were detected for this scope.",
        "type_col": "Type",
        "added_col": "Added",
        "removed_col": "Removed",
        "modified_col": "Modified",
        "error_label": "Error",
        "failed_step_label": "Failed step",
        "footer": "This email was sent automatically because scan notifications are enabled for your account in the Fabric Lineage Mapper admin panel.",
    },
}
FABRIC_API_BASE_URL = "https://api.fabric.microsoft.com/v1"
GUID_PATTERN = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
