#!/usr/bin/env bash
set -euo pipefail

# bot-autonomy module: OpenAI Codex CLI. Dispatched by
# .devcontainer/scripts/bot-autonomy.sh, bot profile only. Replaces the old
# awk-based rewrite of two keys in place with a complete, shipped bot managed
# config, installed and verified by checksum — a pattern miss can no longer
# print a warning and silently leave the human baseline (workspace-write/
# on-request) in effect. codex-managed-config.bot.toml's structural parity
# with the shared codex-managed-config.toml baseline (every key but
# sandbox_mode/approval_policy) is a separate, authoring-time check
# (scripts/test-bot-autonomy.sh), not this module's concern at apply/verify
# time.

MANAGED="${BOT_AUTONOMY_CODEX_MANAGED:-/etc/codex/managed_config.toml}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT_CONFIG="${BOT_AUTONOMY_CODEX_BOT_CONFIG:-${SCRIPT_DIR}/../codex-managed-config.bot.toml}"

checksum() {
    sha256sum "$1" | awk '{print $1}'
}

cmd_apply() {
    [ -f "$BOT_CONFIG" ] || {
        echo "codex-cli: shipped bot config not found at ${BOT_CONFIG}" >&2
        exit 1
    }
    if [ -f "$MANAGED" ] && [ "$(checksum "$MANAGED")" = "$(checksum "$BOT_CONFIG")" ]; then
        return 0
    fi
    if [ -w "$MANAGED" ] || { [ ! -e "$MANAGED" ] && [ -w "$(dirname "$MANAGED")" ]; }; then
        install -m 0644 "$BOT_CONFIG" "$MANAGED"
    else
        sudo install -m 0644 "$BOT_CONFIG" "$MANAGED"
    fi
    echo "==> codex-cli: danger-full-access/never managed config installed"
}

cmd_verify() {
    [ -f "$BOT_CONFIG" ] || {
        echo "codex-cli: shipped bot config not found at ${BOT_CONFIG}" >&2
        exit 1
    }
    [ -f "$MANAGED" ] || {
        echo "codex-cli: ${MANAGED} not found" >&2
        exit 1
    }
    [ "$(checksum "$MANAGED")" = "$(checksum "$BOT_CONFIG")" ] || {
        echo "codex-cli: verify failed — ${MANAGED} checksum does not match the shipped bot config ${BOT_CONFIG}" >&2
        exit 1
    }
}

case "${1:-}" in
apply) cmd_apply ;;
verify) cmd_verify ;;
executable) echo "codex" ;;
*)
    echo "Usage: $0 <apply|verify|executable>" >&2
    exit 2
    ;;
esac
