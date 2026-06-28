#!/usr/bin/env bash
set -euo pipefail

# Support both env var names (TS_AUTHKEY used by this project, TS_AUTH_KEY used
# by the official Tailscale devcontainer feature).
TS_KEY="${TS_AUTHKEY:-${TS_AUTH_KEY:-}}"

if ! command -v tailscale &>/dev/null; then
    echo "Tailscale CLI unavailable; skipping tailnet connect."
    exit 0
fi

if [ -z "${TS_KEY}" ]; then
    echo "TS_AUTHKEY (or TS_AUTH_KEY) missing; skipping tailnet connect."
    exit 0
fi

# Ensure tailscaled daemon is running. The devcontainer feature's entrypoint
# starts it, but it can crash in Codespaces when /dev/net/tun is unavailable
# (runArgs like --device=/dev/net/tun are ignored in Codespaces).
if ! pgrep -x tailscaled &>/dev/null; then
    echo "tailscaled not running; starting it..."
    if [ ! -c /dev/net/tun ]; then
        echo "No /dev/net/tun device; using userspace networking."
        sudo bash -c 'tailscaled --state=/var/lib/tailscale/tailscaled.state --tun=userspace-networking &>/var/log/tailscaled.log &'
    else
        sudo bash -c 'tailscaled --state=/var/lib/tailscale/tailscaled.state &>/var/log/tailscaled.log &'
    fi
    for _ in $(seq 1 50); do
        [ -S /var/run/tailscale/tailscaled.sock ] && break
        sleep 0.1
    done
    if [ ! -S /var/run/tailscale/tailscaled.sock ]; then
        echo "tailscaled failed to start; check /var/log/tailscaled.log"
        tail -5 /var/log/tailscaled.log 2>/dev/null || true
        echo "Continuing without tailnet."
        exit 0
    fi
fi

if sudo tailscale ip -4 >/dev/null 2>&1; then
    echo "Tailscale already connected."
    exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "${REPO_ROOT}" ]; then
    REPO_NAME=$(basename "${REPO_ROOT}")
elif [ -n "${GITHUB_REPOSITORY:-}" ]; then
    REPO_NAME=$(basename "${GITHUB_REPOSITORY}")
else
    REPO_NAME="devcontainer"
fi

SHORT_ID=$(hostname | cut -c1-8)
if [ -n "${CODESPACE_NAME:-}" ]; then
    TS_HOSTNAME="gh-${REPO_NAME}-${SHORT_ID}"
elif [ "${CODER:-}" = "true" ]; then
    TS_HOSTNAME="cr-${REPO_NAME}-${SHORT_ID}"
else
    TS_HOSTNAME="dc-${REPO_NAME}-${SHORT_ID}"
fi

if TS_CONNECT_OUTPUT="$(
    sudo tailscale up \
        --ssh \
        --hostname="${TS_HOSTNAME}" \
        --authkey="${TS_KEY}" \
        --accept-routes 2>&1
)"; then
    echo "Connected to tailnet as ${TS_HOSTNAME}."
else
    echo "Tailscale connect failed; continuing without tailnet."
    printf '%s\n' "${TS_CONNECT_OUTPUT}"
fi
