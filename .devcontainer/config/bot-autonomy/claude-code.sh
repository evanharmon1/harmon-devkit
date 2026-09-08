#!/usr/bin/env bash
set -euo pipefail

# bot-autonomy module: Claude Code. Dispatched by
# .devcontainer/scripts/bot-autonomy.sh, bot profile only. Governs
# permissions.defaultMode in the managed settings file — highest-precedence,
# so it cannot be overridden by the user or workspace layers. Covers every
# slug aliased to claude-code too (the six claude-code-* provider-rewired
# variants): they all exec this same `claude` binary, reconfigured by
# environment variables, so they share this one boundary.

MANAGED="${BOT_AUTONOMY_CLAUDE_MANAGED:-/etc/claude-code/managed-settings.json}"

cmd_apply() {
    command -v jq >/dev/null 2>&1 || {
        echo "claude-code: jq not found" >&2
        exit 1
    }
    [ -f "$MANAGED" ] || {
        echo "claude-code: ${MANAGED} not found" >&2
        exit 1
    }

    if [ "$(jq -r '.permissions.defaultMode // empty' "$MANAGED")" = "bypassPermissions" ]; then
        return 0
    fi

    local tmp
    tmp="$(mktemp)"
    if ! jq '.permissions.defaultMode = "bypassPermissions"' "$MANAGED" >"$tmp"; then
        rm -f "$tmp"
        echo "claude-code: failed to compute updated ${MANAGED}" >&2
        exit 1
    fi
    if [ -w "$MANAGED" ]; then
        install -m 0644 "$tmp" "$MANAGED"
    else
        sudo install -m 0644 "$tmp" "$MANAGED"
    fi
    rm -f "$tmp"
    echo "==> claude-code: bypassPermissions enabled"
}

cmd_verify() {
    command -v jq >/dev/null 2>&1 || {
        echo "claude-code: jq not found" >&2
        exit 1
    }
    [ -f "$MANAGED" ] || {
        echo "claude-code: ${MANAGED} not found" >&2
        exit 1
    }
    local mode
    mode="$(jq -r '.permissions.defaultMode // empty' "$MANAGED")"
    [ "$mode" = "bypassPermissions" ] || {
        echo "claude-code: verify failed — permissions.defaultMode is '${mode:-<unset>}', expected bypassPermissions" >&2
        exit 1
    }
}

case "${1:-}" in
apply) cmd_apply ;;
verify) cmd_verify ;;
executable) echo "claude" ;;
*)
    echo "Usage: $0 <apply|verify|executable>" >&2
    exit 2
    ;;
esac
