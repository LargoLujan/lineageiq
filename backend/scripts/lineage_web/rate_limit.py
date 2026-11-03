"""Fixed-window rate limiting per client IP, for /api/* only (Tanda 5,
E.3). In-memory and per-process, same tradeoff as every other piece of
shared state in this package: a server restart resets every window, which
is fine for a limiter whose job is smoothing bursts, not enforcing a hard
long-term quota.
"""
import time

from .constants import RATE_LIMIT_MAX_REQUESTS_PER_WINDOW, RATE_LIMIT_WINDOW_SECONDS
from .state import _rate_limit_lock, _rate_limit_windows


def _check_rate_limit(client_ip):
    """Returns (allowed, retry_after_seconds). Advances/resets that IP's
    window as a side effect, so call this at most once per request."""
    now = time.time()
    with _rate_limit_lock:
        # Opportunistic cleanup of expired windows -- otherwise this dict
        # only ever grows, one entry per distinct client_ip ever seen,
        # never shrinking (2026-08-17 security audit). Combined with the
        # _client_ip() fix above (untrusted callers can no longer mint
        # unlimited fake IPs via a spoofed header), this keeps the dict
        # bounded by real distinct recent visitors instead of unbounded.
        for stale_ip in [ip for ip, (window_start, _count) in _rate_limit_windows.items() if now - window_start >= RATE_LIMIT_WINDOW_SECONDS]:
            del _rate_limit_windows[stale_ip]
        window_start, count = _rate_limit_windows.get(client_ip, (now, 0))
        if now - window_start >= RATE_LIMIT_WINDOW_SECONDS:
            window_start, count = now, 0
        count += 1
        _rate_limit_windows[client_ip] = (window_start, count)
        retry_after = max(1, round(RATE_LIMIT_WINDOW_SECONDS - (now - window_start)))
        return count <= RATE_LIMIT_MAX_REQUESTS_PER_WINDOW, retry_after
