#!/usr/bin/env bash
set -euo pipefail

# bot-autonomy module: oh-my-pi (binary `omp`). Dispatched by
# .devcontainer/scripts/bot-autonomy.sh, bot profile only. NOT Copier-gated:
# oh-my-pi is a broker-style, model-agnostic harness with no account or paid
# tier of its own for AGENTS.md's Hard Rule to apply to.
#
# Forces tools.approvalMode to "yolo" in ~/.omp/agent/config.yml on every
# apply, overriding any prior value for that key while preserving every other
# key — the same managed-key/backup-and-restore shape opencode.sh uses. The
# value is written EXPLICITLY rather than left to oh-my-pi's own schema
# default (which happens to be "yolo" today) for three reasons: a
# project-level <cwd>/.omp/config.yml sits ABOVE global config in oh-my-pi's
# precedence chain; a future release could change its own default without
# notice; and a bot container's ~/.omp volume starts empty, so there is no
# durable state at all until this module creates it.
#
# verify reads oh-my-pi's own FULLY RESOLVED value (`omp config get
# tools.approvalMode --json`, run from the working directory being verified)
# rather than the global file alone — same reason opencode.sh asks
# `opencode debug config` instead of reading its global JSON: a
# workspace-level override would otherwise be missed entirely.
#
# Mechanism confirmed at implementation time against the actually-installed
# omp v18.1.2 in the shared image (not documentation alone): `omp config
# path` reports ~/.omp/agent; `omp config get tools.approvalMode --json`
# returns {"key","value","type":"enum","description"} and resolves a
# <cwd>/.omp/config.yml override over the global file; the enum is
# always-ask | write | yolo with schema default yolo. See
# https://github.com/evanharmon1/harmon-init/blob/main/openspec/changes/archive/2026-09-05-bot-autonomy-new-harnesses/design.md - Decisions.

OMP_AGENT_DIR="${BOT_AUTONOMY_OMP_AGENT_DIR:-$HOME/.omp/agent}"
CONFIG="${OMP_AGENT_DIR}/config.yml"
BACKUP="${CONFIG}.harmon-init-autonomy-backup"
WORKDIR="${BOT_AUTONOMY_OMP_WORKDIR:-$PWD}"

# An absent document (empty file) is as valid a starting point as a mapping;
# anything else means somebody's real configuration is in a shape this
# module must not rewrite blindly.
valid_document() {
    yq -e '. == null or (type == "!!map")' "$1" >/dev/null 2>&1
}

# tools_node_kind <file>  — "absent", or yq's type tag for the `tools` node.
# apply and restore MUST agree on this exactly: both write underneath
# `.tools`, and yq's assignment into a SCALAR node is a silent no-op that
# still exits 0, so a shape neither can own has to be refused rather than
# written through. One helper, so the two can never drift apart.
tools_node_kind() {
    if [ "$(yq -r 'has("tools")' "$1")" = "true" ]; then
        yq -r '.tools | type' "$1"
    else
        printf 'absent'
    fi
}

need_yq() {
    command -v yq >/dev/null 2>&1 || {
        echo "oh-my-pi: yq not found" >&2
        exit 1
    }
}

cmd_apply() {
    need_yq
    command -v jq >/dev/null 2>&1 || {
        echo "oh-my-pi: jq not found" >&2
        exit 1
    }
    mkdir -p "$OMP_AGENT_DIR"
    if [ ! -f "$CONFIG" ]; then
        : >"$CONFIG"
        chmod 0600 "$CONFIG"
    elif ! valid_document "$CONFIG"; then
        echo "oh-my-pi: ${CONFIG} is not a valid YAML mapping; leaving it unchanged" >&2
        exit 1
    fi

    # `tools` must be a mapping, absent, or explicitly null for this module to
    # own a key underneath it — without this guard apply would report success
    # having written no policy at all (verify would fail later, in the
    # container, over a value apply claimed to have set).
    local tools_kind
    tools_kind="$(tools_node_kind "$CONFIG")"
    case "$tools_kind" in
    absent | '!!null' | '!!map') ;;
    *)
        echo "oh-my-pi: ${CONFIG} has a 'tools' key of type ${tools_kind}, not a mapping; leaving it unchanged rather than writing a policy underneath it" >&2
        exit 1
        ;;
    esac

    # Gated on no backup existing yet, so apply -> apply -> restore returns
    # the value from before the FIRST apply, not from before the last one.
    if [ ! -f "$BACKUP" ]; then
        local approval_present prior_json tools_prior present values backup_tmp
        # Presence is has(), never the VALUE. An explicit `approvalMode: null`
        # and an explicit empty string are both keys that WERE there and must
        # be put back; a `// ""` default collapses each of them into the same
        # shell string as a genuinely absent key, so restore would delete a
        # key it had found.
        approval_present="$(yq -r '(.tools // {}) | has("approvalMode")' "$CONFIG")"
        # The raw value, JSON-encoded, so null / "" / a string all round-trip
        # exactly instead of being flattened through a shell string.
        prior_json="$(yq -o=json -I=0 '.tools.approvalMode' "$CONFIG")"
        # Three states, not a boolean: `tools:` written with no value is a
        # DIFFERENT prior shape from `tools: {…}`, and apply turns both into a
        # mapping. A has()/boolean backup cannot tell restore which one to put
        # back, so it would silently upgrade a null to an empty mapping.
        case "$tools_kind" in
        absent) tools_prior=absent ;;
        '!!null') tools_prior=null ;;
        *) tools_prior=map ;;
        esac
        if [ "$approval_present" = "true" ]; then
            present='["tools.approvalMode"]'
            values="$(jq -n --argjson v "$prior_json" '{"tools.approvalMode": $v}')"
        else
            present='[]'
            values='{}'
        fi
        backup_tmp="$(mktemp "${OMP_AGENT_DIR}/config.backup.tmp.XXXXXX")"
        jq -n \
            --argjson present "$present" \
            --argjson values "$values" \
            --arg tools_prior "$tools_prior" \
            '{present: $present, values: $values, tools_prior: $tools_prior}' >"$backup_tmp"
        chmod 0600 "$backup_tmp"
        mv -f "$backup_tmp" "$BACKUP"
    fi

    if [ "$(yq -r '.tools.approvalMode // ""' "$CONFIG")" != "yolo" ]; then
        yq -i '.tools.approvalMode = "yolo"' "$CONFIG"
        echo "==> oh-my-pi: tools.approvalMode=yolo applied"
    fi
}

cmd_restore() {
    need_yq
    command -v jq >/dev/null 2>&1 || {
        echo "oh-my-pi: jq not found" >&2
        exit 1
    }
    [ -f "$BACKUP" ] || return 0
    if [ ! -f "$CONFIG" ] || ! valid_document "$CONFIG"; then
        echo "oh-my-pi: restore failed — ${CONFIG} is missing or not a valid YAML mapping; leaving ${BACKUP} in place" >&2
        return 1
    fi
    # Guard the CURRENT shape before writing, exactly as apply does. The file
    # can have changed since apply ran — a hand edit, another tool — and a
    # scalar `tools` would swallow the restore silently, leaving the operator
    # with neither their prior value nor the backup that held it.
    local tools_kind
    tools_kind="$(tools_node_kind "$CONFIG")"
    case "$tools_kind" in
    absent | '!!null' | '!!map') ;;
    *)
        echo "oh-my-pi: restore failed — ${CONFIG} now has a 'tools' key of type ${tools_kind}, not a mapping; leaving it and ${BACKUP} untouched" >&2
        return 1
        ;;
    esac

    local approval_present prior_json tools_prior
    approval_present="$(jq -r '(.present // []) | any(. == "tools.approvalMode")' "$BACKUP")" || {
        echo "oh-my-pi: restore failed — could not read ${BACKUP}; leaving it in place" >&2
        return 1
    }
    prior_json="$(jq -c '.values["tools.approvalMode"]' "$BACKUP")"
    tools_prior="$(jq -r '.tools_prior // "map"' "$BACKUP")"
    if [ "$approval_present" = "true" ]; then
        # strenv + from_json, never string interpolation: the captured value
        # comes off disk, so splicing it into the expression would let a
        # hand-edited backup run arbitrary yq against the operator's config.
        # from_json is also what makes null and "" restore as themselves
        # rather than as the string "null" or as a deleted key.
        BOT_AUTONOMY_OMP_PRIOR="$prior_json" \
            yq -i '.tools.approvalMode = (strenv(BOT_AUTONOMY_OMP_PRIOR) | from_json)' "$CONFIG"
    else
        yq -i 'del(.tools.approvalMode)' "$CONFIG"
        # apply may have created the `tools` node itself, or turned an
        # explicit null into a mapping. Put back the shape that was there,
        # but only while nothing else has since been added underneath it.
        if [ "$(yq -r '(.tools // {}) | length' "$CONFIG")" = "0" ]; then
            case "$tools_prior" in
            absent) yq -i 'del(.tools)' "$CONFIG" ;;
            null) yq -i '.tools = null' "$CONFIG" ;;
            esac
        fi
    fi
    rm -f "$BACKUP"
    echo "==> oh-my-pi: approval-mode policy restored"
}

cmd_verify() {
    command -v omp >/dev/null 2>&1 || {
        echo "oh-my-pi: omp CLI not found" >&2
        exit 1
    }
    command -v jq >/dev/null 2>&1 || {
        echo "oh-my-pi: jq not found" >&2
        exit 1
    }
    [ -d "$WORKDIR" ] || {
        echo "oh-my-pi: verify failed — working directory ${WORKDIR} does not exist" >&2
        exit 1
    }

    local resolved mode
    resolved="$(cd "$WORKDIR" && omp config get tools.approvalMode --json 2>/dev/null)" || {
        echo "oh-my-pi: verify failed — 'omp config get tools.approvalMode --json' did not run in ${WORKDIR}" >&2
        exit 1
    }
    mode="$(printf '%s' "$resolved" | jq -r '.value // empty')" || {
        echo "oh-my-pi: verify failed — could not evaluate the resolved approval mode" >&2
        exit 1
    }
    if [ "$mode" != "yolo" ]; then
        local cause="$CONFIG" candidate
        candidate="${WORKDIR}/.omp/config.yml"
        if [ -f "$candidate" ] && command -v yq >/dev/null 2>&1 &&
            yq -e '.tools.approvalMode != null' "$candidate" >/dev/null 2>&1; then
            cause="$candidate"
        fi
        echo "oh-my-pi: verify failed — resolved tools.approvalMode is '${mode:-<unset>}', expected 'yolo' (check ${cause})" >&2
        exit 1
    fi
}

case "${1:-}" in
apply) cmd_apply ;;
verify) cmd_verify ;;
restore) cmd_restore ;;
executable) echo "omp" ;;
*)
    echo "Usage: $0 <apply|verify|restore|executable>" >&2
    exit 2
    ;;
esac
