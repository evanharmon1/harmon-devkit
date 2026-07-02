#!/usr/bin/env bash
set -euo pipefail

# BOT PROFILE ONLY. Default Claude Code to `bypassPermissions` in this container
# so the agent runs without per-action prompts — the container is the isolation
# boundary. Called from the bot post-create.sh; the dev post-create.sh
# intentionally does NOT call it, so a human gets the normal prompt-on-action
# default.
#
# The mode is injected into the MANAGED settings (/etc/claude-code/
# managed-settings.json) — highest precedence, so it cannot be overridden. The
# baked managed file deliberately omits defaultMode (shared by both profiles);
# this is the one bot-only difference. Idempotent and never fatal.

MANAGED=/etc/claude-code/managed-settings.json

command -v jq >/dev/null 2>&1 || {
    echo "==> jq not found; cannot enable Claude bypass mode" >&2
    exit 0
}
[ -f "$MANAGED" ] || {
    echo "==> ${MANAGED} not found; skipping Claude bypass mode" >&2
    exit 0
}

# Already set? nothing to do.
if [ "$(jq -r '.permissions.defaultMode // empty' "$MANAGED")" = "bypassPermissions" ]; then
    exit 0
fi

tmp=$(mktemp)
if jq '.permissions.defaultMode = "bypassPermissions"' "$MANAGED" >"$tmp"; then
    sudo install -m 0644 "$tmp" "$MANAGED"
    echo "==> Claude: bypassPermissions enabled (bot profile)"
else
    echo "==> WARNING: failed to enable Claude bypass mode; leaving managed settings unchanged" >&2
fi
rm -f "$tmp"
