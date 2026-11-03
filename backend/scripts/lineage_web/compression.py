"""Static file serving with cached on-the-fly gzip.

Split out of lineage_web_server.py (D.3, 2026-07-08) -- pure code motion,
no logic changed from the original.
"""
import gzip
from pathlib import Path

from .state import _cache_lock, _compressed_cache


def get_compressed_bytes(path: Path, raw: bytes) -> bytes:
    mtime_ns = path.stat().st_mtime_ns
    with _cache_lock:
        cached = _compressed_cache.get(path)
        if cached and cached[0] == mtime_ns:
            return cached[1]
    compressed = gzip.compress(raw, compresslevel=6)
    with _cache_lock:
        _compressed_cache[path] = (mtime_ns, compressed)
    return compressed
