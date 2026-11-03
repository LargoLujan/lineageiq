#!/usr/bin/env bash
set -euo pipefail

# Starts the semantic lineage web UI and, optionally, a temporary public tunnel.
# This script is intentionally local/runtime-only: it does not modify Fabric.

LINEAGE_WEB_AUTOSTART="${LINEAGE_WEB_AUTOSTART:-true}"
LINEAGE_WEB_ROOT="${LINEAGE_WEB_ROOT:-/workspace/frontend/semantic-lineage}"
LINEAGE_WEB_PORT="${LINEAGE_WEB_PORT:-8765}"
LINEAGE_WEB_HOST="${LINEAGE_WEB_HOST:-0.0.0.0}"
LINEAGE_WEB_PUBLIC_TUNNEL="${LINEAGE_WEB_PUBLIC_TUNNEL:-false}"
LINEAGE_WEB_TUNNEL_WAIT_SECONDS="${LINEAGE_WEB_TUNNEL_WAIT_SECONDS:-90}"
LINEAGE_WEB_STATE_DIR="${LINEAGE_WEB_STATE_DIR:-/workspace/analysis/public_web_forward_current}"

if [ "${LINEAGE_WEB_AUTOSTART}" != "true" ]; then
    exit 0
fi

mkdir -p "${LINEAGE_WEB_STATE_DIR}"

if command -v flock >/dev/null 2>&1; then
    exec 9>"${LINEAGE_WEB_STATE_DIR}/start.lock"
    if ! flock -n 9; then
        exit 0
    fi
fi

LOCAL_URL="http://127.0.0.1:${LINEAGE_WEB_PORT}/"
PUBLIC_URL_FILE="${LINEAGE_WEB_STATE_DIR}/public-url.txt"
LOCAL_URL_FILE="${LINEAGE_WEB_STATE_DIR}/local-url.txt"
HTTP_LOG="${LINEAGE_WEB_STATE_DIR}/http-server.log"
CLOUDFLARED_LOG="${LINEAGE_WEB_STATE_DIR}/cloudflared.log"

echo "${LOCAL_URL}" > "${LOCAL_URL_FILE}"

is_local_ready() {
    curl -fsS -o /dev/null --max-time 5 "${LOCAL_URL}"
}

start_local_server() {
    if is_local_ready; then
        return 0
    fi

    if [ ! -d "${LINEAGE_WEB_ROOT}" ]; then
        echo "Warning: lineage web root not found: ${LINEAGE_WEB_ROOT}" >&2
        return 1
    fi

    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${LINEAGE_WEB_PORT}$"; then
        echo "Warning: port ${LINEAGE_WEB_PORT} is in use but ${LOCAL_URL} is not ready." >&2
        return 1
    fi

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    setsid python3 "${SCRIPT_DIR}/lineage_web_server.py" \
        --port "${LINEAGE_WEB_PORT}" \
        --bind "${LINEAGE_WEB_HOST}" \
        --directory "${LINEAGE_WEB_ROOT}" \
        > "${HTTP_LOG}" 2>&1 < /dev/null &
    echo "$!" > "${LINEAGE_WEB_STATE_DIR}/http-server.pid"

    for _ in $(seq 1 20); do
        if is_local_ready; then
            return 0
        fi
        sleep 1
    done

    echo "Warning: lineage web server did not become ready on ${LOCAL_URL}." >&2
    return 1
}

cloudflare_tunnel_running() {
    pgrep -af "cloudflared tunnel --url http://127\\.0\\.0\\.1:${LINEAGE_WEB_PORT}" >/dev/null 2>&1
}

public_url_ready() {
    [ -f "${PUBLIC_URL_FILE}" ] || return 1
    public_url="$(cat "${PUBLIC_URL_FILE}")"
    [ -n "${public_url}" ] || return 1
    curl -fsS -o /dev/null --max-time 20 "${public_url}/"
}

adopt_existing_public_url() {
    for candidate_file in "${PUBLIC_URL_FILE}" /workspace/analysis/public_web_forward_*/public-url.txt; do
        [ -f "${candidate_file}" ] || continue
        candidate_url="$(cat "${candidate_file}")"
        [ -n "${candidate_url}" ] || continue

        if curl -fsS -o /dev/null --max-time 20 "${candidate_url}/"; then
            echo "${candidate_url}" > "${PUBLIC_URL_FILE}"
            return 0
        fi
    done

    return 1
}

start_cloudflare_tunnel() {
    if [ "${LINEAGE_WEB_PUBLIC_TUNNEL}" != "true" ]; then
        return 0
    fi

    if public_url_ready; then
        return 0
    fi

    if adopt_existing_public_url; then
        return 0
    fi

    if ! cloudflare_tunnel_running; then
        : > "${CLOUDFLARED_LOG}"
        if command -v cloudflared >/dev/null 2>&1; then
            setsid cloudflared tunnel \
                --url "http://127.0.0.1:${LINEAGE_WEB_PORT}" \
                --no-autoupdate \
                > "${CLOUDFLARED_LOG}" 2>&1 < /dev/null &
        elif command -v npx >/dev/null 2>&1; then
            setsid npx --yes cloudflared tunnel \
                --url "http://127.0.0.1:${LINEAGE_WEB_PORT}" \
                --no-autoupdate \
                > "${CLOUDFLARED_LOG}" 2>&1 < /dev/null &
        else
            echo "Warning: cloudflared/npx not available; public tunnel was not started." >&2
            return 1
        fi
        echo "$!" > "${LINEAGE_WEB_STATE_DIR}/cloudflared.pid"
    fi

    for _ in $(seq 1 "${LINEAGE_WEB_TUNNEL_WAIT_SECONDS}"); do
        public_url="$(grep -Eo 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "${CLOUDFLARED_LOG}" | tail -n 1 || true)"
        if [ -n "${public_url}" ]; then
            echo "${public_url}" > "${PUBLIC_URL_FILE}"
            if curl -fsS -o /dev/null --max-time 20 "${public_url}/"; then
                return 0
            fi
        fi
        sleep 1
    done

    if [ -f "${PUBLIC_URL_FILE}" ]; then
        echo "Warning: public tunnel URL was created but did not validate yet: $(cat "${PUBLIC_URL_FILE}")" >&2
    else
        echo "Warning: public Cloudflare tunnel URL was not created." >&2
    fi
}

start_local_server || true
start_cloudflare_tunnel || true

{
    echo "Local lineage URL: ${LOCAL_URL}"
    if [ -f "${PUBLIC_URL_FILE}" ]; then
        echo "Public lineage URL: $(cat "${PUBLIC_URL_FILE}")"
    else
        echo "Public lineage URL: not enabled or not ready"
    fi
} | tee "${LINEAGE_WEB_STATE_DIR}/status.txt" >/dev/null
