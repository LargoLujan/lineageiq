#!/usr/bin/env python3
"""Pre-gzip every compressible static file under frontend/semantic-lineage/
at Docker BUILD time, writing a "<file>.gz" sibling next to each one.

Only exists for the resource-constrained hosted read-only deploy (Render's
free tier: 512MB RAM, 0.1 CPU) -- lineage_web/handler.py's _serve_static
serves that sibling directly when present, instead of reading the
(potentially tens of MB) raw file into memory and gzip-compressing it on every request. The
normal local/tunnel run (no .gz siblings on disk) is unaffected.

Run once during `docker build`, never at container start -- these are
static data snapshots baked into the image, not something that changes
while the container is running.
"""
import gzip
import sys
from pathlib import Path

COMPRESSIBLE_SUFFIXES = {".json", ".js", ".css", ".html", ".htm", ".mmd", ".md", ".svg", ".txt"}
MIN_COMPRESS_BYTES = 1024


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "frontend/semantic-lineage")
    if not root.is_dir():
        print(f"Not a directory: {root}", file=sys.stderr)
        sys.exit(1)

    total_raw = 0
    total_gz = 0
    count = 0
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in COMPRESSIBLE_SUFFIXES:
            continue
        raw = path.read_bytes()
        if len(raw) <= MIN_COMPRESS_BYTES:
            continue
        compressed = gzip.compress(raw, compresslevel=6)
        gz_path = path.with_name(path.name + ".gz")
        gz_path.write_bytes(compressed)
        total_raw += len(raw)
        total_gz += len(compressed)
        count += 1
        print(f"  {path.relative_to(root)}: {len(raw):,} -> {len(compressed):,} bytes")

    print(f"Pre-gzipped {count} files: {total_raw:,} -> {total_gz:,} bytes total.")


if __name__ == "__main__":
    main()
