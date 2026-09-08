#!/usr/bin/env bash
set -euo pipefail

# bot-autonomy module: OpenCode. Dispatched by
# .devcontainer/scripts/bot-autonomy.sh, bot profile only. Forces
# permission.* to "allow" in ~/.config/opencode/opencode.json on every apply,
# overriding any prior value for that key while preserving every other key —
# the same managed-key/backup-and-restore shape
# apply-antigravity-settings.sh already uses for Antigravity. Not
# Copier-gated: OpenCode has no balanced/dev policy to select between, so
# apply is unconditional (this module runs in the bot profile only, same as
# every other module here).
#
# verify reads OpenCode's own resolved configuration (`opencode debug
# config`, run from the working directory being verified) rather than the
# global file alone: OpenCode layers a workspace-level opencode.json (or
# .opencode/opencode.json) over the global default, and a global-only check
# would miss a repository whose own config still denies or asks.

CONFIG_DIR="${BOT_AUTONOMY_OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
CONFIG="${CONFIG_DIR}/opencode.json"
BACKUP="${CONFIG}.harmon-init-autonomy-backup"
WORKDIR="${BOT_AUTONOMY_OPENCODE_WORKDIR:-$PWD}"

valid_object() {
    jq -e 'type == "object"' "$1" >/dev/null 2>&1
}

atomic_replace() {
    chmod 0600 "$1"
    mv -f "$1" "$2"
}

cmd_apply() {
    command -v jq >/dev/null 2>&1 || {
        echo "opencode: jq not found" >&2
        exit 1
    }
    mkdir -p "$CONFIG_DIR"
    if [ ! -f "$CONFIG" ]; then
        echo '{}' >"$CONFIG"
        chmod 0600 "$CONFIG"
    elif ! valid_object "$CONFIG"; then
        echo "opencode: ${CONFIG} is not a valid JSON object; leaving it unchanged" >&2
        exit 1
    fi

    if [ ! -f "$BACKUP" ]; then
        local backup_tmp
        backup_tmp="$(mktemp "${CONFIG_DIR}/opencode.backup.tmp.XXXXXX")"
        jq '{
            present: (if has("permission") then ["permission"] else [] end),
            values: (if has("permission") then {permission: .permission} else {} end)
        }' "$CONFIG" >"$backup_tmp"
        atomic_replace "$backup_tmp" "$BACKUP"
    fi

    local config_tmp
    config_tmp="$(mktemp "${CONFIG_DIR}/opencode.json.tmp.XXXXXX")"
    jq '.permission = {"*": "allow"}' "$CONFIG" >"$config_tmp"
    if ! cmp -s "$config_tmp" "$CONFIG"; then
        atomic_replace "$config_tmp" "$CONFIG"
        echo "==> opencode: permission allow-all applied"
    else
        rm -f "$config_tmp"
    fi
}

cmd_restore() {
    [ -f "$BACKUP" ] || return 0
    if [ ! -f "$CONFIG" ] || ! valid_object "$CONFIG"; then
        echo "opencode: restore failed — ${CONFIG} is missing or not a valid JSON object; leaving ${BACKUP} in place" >&2
        return 1
    fi
    local config_tmp
    config_tmp="$(mktemp "${CONFIG_DIR}/opencode.json.tmp.XXXXXX")"
    jq -s '
        .[0] as $current | .[1] as $backup |
        ($current | del(.permission)) as $base |
        reduce $backup.present[] as $key ($base; .[$key] = $backup.values[$key])
    ' "$CONFIG" "$BACKUP" >"$config_tmp"
    atomic_replace "$config_tmp" "$CONFIG"
    rm -f "$BACKUP"
    echo "==> opencode: permission policy restored"
}

cmd_verify() {
    command -v opencode >/dev/null 2>&1 || {
        echo "opencode: opencode CLI not found" >&2
        exit 1
    }
    command -v jq >/dev/null 2>&1 || {
        echo "opencode: jq not found" >&2
        exit 1
    }
    [ -d "$WORKDIR" ] || {
        echo "opencode: verify failed — working directory ${WORKDIR} does not exist" >&2
        exit 1
    }

    local resolved denied
    resolved="$(cd "$WORKDIR" && opencode debug config 2>/dev/null)" || {
        echo "opencode: verify failed — 'opencode debug config' did not run in ${WORKDIR}" >&2
        exit 1
    }
    # Check EVERY key in the resolved permission object, not the wildcard
    # alone: OpenCode layers a workspace-level override alongside the global
    # "*", not only in place of it — {"*":"allow","bash":"deny"} resolves
    # with both keys present, and a wildcard-only check would report
    # allow-all while `bash` still prompts or fails.
    denied="$(printf '%s' "$resolved" | jq -r '
        (.permission // {}) as $perm |
        (if ($perm["*"] // "unset") != "allow" then ["*"] else [] end) +
        [$perm | to_entries[] | select(.value != "allow") | .key] | unique | join(", ")
    ')" || {
        echo "opencode: verify failed — could not evaluate the resolved permission policy" >&2
        exit 1
    }
    if [ -n "$denied" ]; then
        local cause candidate
        cause="$CONFIG"
        for candidate in "${WORKDIR}/opencode.json" "${WORKDIR}/.opencode/opencode.json"; do
            if [ -f "$candidate" ] && jq -e '.permission != null' "$candidate" >/dev/null 2>&1; then
                cause="$candidate"
            fi
        done
        echo "opencode: verify failed — effective permission is not allow-all for: ${denied} (check ${cause})" >&2
        exit 1
    fi
}

case "${1:-}" in
apply) cmd_apply ;;
verify) cmd_verify ;;
restore) cmd_restore ;;
executable) echo "opencode" ;;
*)
    echo "Usage: $0 <apply|verify|restore|executable>" >&2
    exit 2
    ;;
esac
