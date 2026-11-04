"""In-memory request metrics -- counts by (method, path,
status_code), reset on server restart, same tradeoff as every other piece
of in-memory-only shared state in this package. Exists so an admin can see
real traffic/error shape (including rate-limit rejections) from inside the
app instead of grepping the stderr access log by hand, and so a Fabric
pipeline integration's failure mode is visible here too, not just inferred
from its own retry logs.
"""
from .state import _metrics_lock, _metrics_started_at, _request_counts


def _record_request(method, path, status_code):
    key = (method, path, status_code)
    with _metrics_lock:
        _request_counts[key] = _request_counts.get(key, 0) + 1


def _metrics_snapshot():
    with _metrics_lock:
        rows = [
            {"method": method, "path": path, "status_code": status_code, "count": count}
            for (method, path, status_code), count in _request_counts.items()
        ]
    rows.sort(key=lambda row: row["count"], reverse=True)
    return {"since": _metrics_started_at, "routes": rows}
