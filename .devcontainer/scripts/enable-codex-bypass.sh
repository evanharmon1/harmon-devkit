#!/usr/bin/env bash
set -euo pipefail

# BOT PROFILE ONLY. Docker is the isolation boundary, so remove Codex's nested
# sandbox and interactive approval prompts. The human profile deliberately
# keeps the managed workspace-write/on-request baseline.
managed="${CODEX_MANAGED_CONFIG:-/etc/codex/managed_config.toml}"

[ -f "$managed" ] || {
    echo "==> ${managed} not found; skipping Codex bot mode" >&2
    exit 0
}

tmp="$(mktemp)"
if awk '
    BEGIN { in_root = 1; sandbox = 0; approval = 0 }
    /^[[:space:]]*\[/ { in_root = 0 }
    in_root && /^[[:space:]]*sandbox_mode[[:space:]]*=/ {
        print "sandbox_mode = \"danger-full-access\""
        sandbox++
        next
    }
    in_root && /^[[:space:]]*approval_policy[[:space:]]*=/ {
        print "approval_policy = \"never\""
        approval++
        next
    }
    { print }
    END { if (sandbox != 1 || approval != 1) exit 1 }
' "$managed" >"$tmp"; then
    if [ -w "$managed" ]; then
        install -m 0644 "$tmp" "$managed"
    else
        sudo install -m 0644 "$tmp" "$managed"
    fi
    echo "==> Codex: danger-full-access/never enabled (bot profile)"
else
    echo "==> WARNING: managed Codex config lacks unique root sandbox/approval settings; leaving it unchanged" >&2
fi
rm -f "$tmp"
