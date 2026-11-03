#!/usr/bin/env bash
set -euo pipefail

# The Fabric auth cache is a mounted Docker volume, so this setting must be
# applied at container start rather than only during image build.
if command -v fab >/dev/null 2>&1; then
    current_value="$(fab config get encryption_fallback_enabled 2>/dev/null || true)"

    if [ "${current_value}" != "true" ]; then
        if ! fab config set encryption_fallback_enabled true >/dev/null 2>&1; then
            echo "Warning: could not enable Fabric CLI encryption fallback." >&2
        fi
    fi
fi

# Keep the lineage review app ready when the container starts. The script is
# non-blocking and writes the current local/public URLs under analysis/.
if [ -x /workspace/backend/scripts/start_lineage_web.sh ]; then
    if ! /workspace/backend/scripts/start_lineage_web.sh >/tmp/lineage-web-autostart.log 2>&1; then
        echo "Warning: could not start lineage web automatically. See /tmp/lineage-web-autostart.log." >&2
    fi

    if [ -f /workspace/analysis/public_web_forward_current/status.txt ]; then
        cat /workspace/analysis/public_web_forward_current/status.txt
    fi
fi

exec "$@"
