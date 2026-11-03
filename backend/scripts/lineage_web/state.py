"""Shared mutable state (locks + dicts) for the lineage_web package.
Every submodule that touches one of these imports it directly from here
(`from .state import _sessions`) -- Python binds that to the SAME dict
object, not a copy, so mutations stay visible across every importer just
like when they all lived in one file. Verified before this split (D.3,
2026-07-08) that none of these names is ever reassigned anywhere in the
original file, only mutated in place -- reassigning any of them in a
submodule would break the sharing, so don't.
"""
import threading

from .utils import _now_iso

_cache_lock = threading.Lock()
_compressed_cache = {}  # Path -> (mtime_ns, compressed_bytes)
_scan_lock = threading.Lock()
_scan_state = {
    "status": "idle",
    "workspace": None,
    "pid": None,
    # Same value as started_at, under a name that's stable API contract for
    # /api/status callers (Tanda 5, E.1) even if the internal state
    # representation changes later -- a Fabric pipeline's Until activity
    # compares this against the id it got back from the trigger call to
    # confirm it's still polling the scan it started, not a different one.
    "scan_id": None,
    "started_at": None,
    "ended_at": None,
    "duration_seconds": None,
    "exit_code": None,
    "log_path": None,
    "last_error": None,
    "cancel_requested": False,
    # Who started this scan (the signed-in user's email), or None for an
    # anonymous-started scan (only possible when allow_anonymous_scans is
    # on) -- lets /api/scan-stop restrict stopping someone else's scan to
    # that same person or an admin, instead of anyone being able to kill it.
    "started_by_email": None,
    # True only for a full scan started by a signed-in user who holds the
    # "Fabric Administrator" Entra ID role -- their -WorkspaceNameFilter
    # came from the tenant-wide admin API (every workspace) instead of
    # their own personal accessible-workspace list. False for every other
    # scan kind, including a single-workspace scan (this only describes
    # full-scan scope). See scan_manager._start_full_scan.
    "is_tenant_admin_scan": False,
    # How many workspaces -WorkspaceNameFilter actually covers for the
    # current/last full scan (None for a single-workspace scan or a
    # session-less/anonymous full scan, which has no explicit filter --
    # "the whole tenant" in that case, per the script's own default).
    "workspace_count": None,
    # Set only for a scan running via discovery_pipeline.mode ==
    # "fabric_pipeline" (see fabric_pipeline.py) -- the Fabric Job Scheduler
    # job instance id, so /api/scan-stop knows to cancel it through the
    # Fabric API instead of killing a local process tree (pid stays None
    # for this kind of run). None for every local, subprocess-based scan.
    "fabric_job_instance_id": None,
}
# FIFO list of requests that arrived while a scan was already running (Tanda
# 10) -- protected by the SAME _scan_lock as _scan_state above, not a
# separate lock, since every transition that matters (claim the running
# slot, enqueue instead, pop the next entry once a scan ends) has to be
# atomic across both together. Each entry:
# {queue_id, kind ("scan"|"full_scan"), workspace_name (kind=="scan" only),
#  session_id (None for an anonymous/api-key request), api_key_name,
#  requested_by_email, requested_at}. See scan_manager._queue_snapshot() for
# what of this is safe to expose publicly -- never session_id, which is a
# bearer credential (see auth._list_sessions_for_admin's own comment on why
# it never leaves this process either).
_scan_queue = []
_session_lock = threading.Lock()
_sessions = {}  # session_id -> {"user_email", "user_name", "msal_cache" (serialized), "created_at"}
# Bounded history of ended sessions (2026-08-18, admin panel Sessions tab --
# same SAME lock as _sessions above, not a separate one, since every ended-
# session code path already holds _session_lock at the point it needs to
# append here too). Never includes access_token/msal_cache, same as the
# live rows in _sessions -- see auth._list_sessions_for_admin's own
# docstring for why those never leave this process.
_session_history = []  # capped list, newest first; see auth._record_ended_session
_device_flow_lock = threading.Lock()
_pending_device_flows = {}  # flow_id -> {"status": "pending"|"done"|"error", "user_code", "verification_uri", "message", "result", "error"}
_rate_limit_lock = threading.Lock()
_rate_limit_windows = {}  # client_ip -> (window_start_epoch, request_count) -- see rate_limit.py
_metrics_lock = threading.Lock()
_metrics_started_at = _now_iso()  # process start -- never reassigned, see the module docstring above
_request_counts = {}  # (method, path, status_code) -> count -- see observability.py
# In-memory only, deliberately NOT persisted to admin_settings.json
# (2026-08-18 admin-panel completeness pass) -- so an admin can see which
# API keys are actually still in use, without the write-storm/lock-file
# risk a real per-request disk write would add (auth._valid_api_key
# updates this on every successful match). Resets on restart, same
# accepted tradeoff as observability.py's _request_counts above.
_api_key_last_used_lock = threading.Lock()
_api_key_last_used = {}  # key_hash -> ISO timestamp

# Entra profile photo (2026-08-18), keyed by lowercased user_email. In-memory
# only, capped by _PHOTO_CACHE_TTL_SECONDS in graph_profile.py rather than
# persisted -- avatars rarely change and every render checking Graph would be
# wasteful, but a hard restart (or the TTL) is enough to pick up a new one.
# A cached entry with data=None means "checked, no photo available" (no
# consent, guest account, 404, ...) so a failed lookup isn't retried on
# every single render either.
_profile_photo_lock = threading.Lock()
_profile_photo_cache = {}  # user_email -> {"content_type", "data", "fetched_at"}

# Tenant display name (2026-08-18): the SAME for every signed-in user in
# the tenant, so it's cached globally (one entry, keyed "value") rather
# than per-user like the photo above -- see graph_profile.py's
# _fetch_tenant_name for what populates this.
_tenant_name_lock = threading.Lock()
_tenant_name_cache = {}  # {"name": str|None, "fetched_at": float} once populated

# Directory profile (displayName/jobTitle/department) for OTHER users, by
# lowercased email (2026-08-24, admin panel's "Usuarios por workspace") --
# separate from _profile_photo_cache above (that one is only ever the
# signed-in user's OWN photo). A cached entry with profile=None means
# "looked up, Graph didn't have it or the call failed" so a bad email
# isn't retried on every single render either. See graph_profile.py's
# _fetch_user_profiles.
_user_profile_lock = threading.Lock()
_user_profile_cache = {}  # email -> {"profile": dict|None, "fetched_at": float}

# Multi-tenant installer wizard (Fase 5, 2026-08-24) -- ONE install can run
# at a time per server process, same reasoning as _scan_state above (a
# second concurrent install would race on the same isolated `fab` HOME
# directory). See installer.py's run_install for what populates this;
# "idle" means no install has ever run yet or the last one's result was
# already read via GET /api/admin/installer/status and cleared.
_installer_lock = threading.Lock()
_installer_state = {
    "status": "idle",  # idle | running | succeeded | failed
    "current_step": None,
    "message": "",
    "log": [],  # [{"step", "message", "ok", "at"}, ...] append-only for one run
    "started_at": None,
    "ended_at": None,
}
