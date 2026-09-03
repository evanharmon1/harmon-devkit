#!/usr/bin/env bash
# Durable reservation/reconciliation primitive for /orchestrator.  It keeps
# replayable external action intent outside run.json, whose schema deliberately
# limits it to lifecycle state.  Callers supply an observed postcondition; this
# helper refuses to infer one from a stale or malformed observation.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  dev-flow-monitor.sh reserve --state FILE --event ID --action assembly|push|comment \
    --expected-head SHA --writer feature-owner
  dev-flow-monitor.sh reconcile --state FILE --event ID --observed FILE

The state file is durable monitor state.  A reservation is written before an
external action.  The observed file must be JSON with status landed, absent, or
indeterminate; landed also requires matching event, action, and expected_head.
`reconcile` prints adopt, retry, or block and advances the event cursor only
for an adopted landed action.  PR merges are never reservable.
EOF
    exit 2
}

die() {
    printf 'dev-flow-monitor: %s\n' "$*" >&2
    exit 2
}

command_name="${1:-}"
shift || true
state=""
event=""
action=""
expected_head=""
writer=""
observed=""

while [ "$#" -gt 0 ]; do
    case "$1" in
    --state)
        state="${2:-}"
        shift 2
        ;;
    --event)
        event="${2:-}"
        shift 2
        ;;
    --action)
        action="${2:-}"
        shift 2
        ;;
    --expected-head)
        expected_head="${2:-}"
        shift 2
        ;;
    --writer)
        writer="${2:-}"
        shift 2
        ;;
    --observed)
        observed="${2:-}"
        shift 2
        ;;
    *) usage ;;
    esac
done

[ -n "$state" ] && [ -n "$event" ] || usage
case "$command_name" in
reserve)
    [ -n "$action" ] && [ -n "$expected_head" ] && [ -n "$writer" ] || usage
    case "$action" in assembly | push | comment) ;; *) die "action $action is not replayable" ;; esac
    [ "$writer" = "feature-owner" ] || die "only the feature-branch owner may reserve $action"
    mkdir -p "$(dirname "$state")"
    if [ ! -e "$state" ]; then
        jq -n '{version: 1, cursor: null, actions: []}' >"$state"
    fi
    jq -e --arg event "$event" --arg action "$action" --arg head "$expected_head" '
            (.version == 1) and
            ([.actions[] | select(.event == $event)] | length == 0) and
            ($head | test("^[0-9a-f]{40}$")) and
            ($action != "merge")
        ' "$state" >/dev/null || die "invalid state, duplicate event, or invalid reservation"
    tmp="${state}.tmp.$$"
    jq --arg event "$event" --arg action "$action" --arg head "$expected_head" '
            .actions += [{event: $event, action: $action, expected_head: $head, state: "reserved"}]
        ' "$state" >"$tmp"
    mv "$tmp" "$state"
    printf 'reserved %s\n' "$event"
    ;;
reconcile)
    [ -n "$observed" ] && [ -f "$observed" ] || usage
    jq -e '.version == 1 and (.actions | type == "array")' "$state" >/dev/null || die "invalid state"
    reservation="$(jq -c --arg event "$event" '.actions[] | select(.event == $event)' "$state")"
    [ -n "$reservation" ] || die "unknown reservation $event"
    status="$(jq -r '.status // empty' "$observed")"
    case "$status" in
    landed)
        expected_action="$(jq -r '.action' <<<"$reservation")"
        expected_head_value="$(jq -r '.expected_head' <<<"$reservation")"
        jq -e --arg event "$event" --arg action "$expected_action" --arg head "$expected_head_value" '
                    .event == $event and .action == $action and .head == $head
                ' "$observed" >/dev/null || die "landed postcondition does not match reservation"
        tmp="${state}.tmp.$$"
        jq --arg event "$event" '
                    .actions |= map(if .event == $event then .state = "adopted" else . end) |
                    .cursor = $event
                ' "$state" >"$tmp"
        mv "$tmp" "$state"
        printf 'adopt %s\n' "$event"
        ;;
    absent)
        printf 'retry %s\n' "$event"
        ;;
    indeterminate)
        printf 'block %s: postcondition is indeterminate\n' "$event" >&2
        exit 2
        ;;
    *) die "observed status must be landed, absent, or indeterminate" ;;
    esac
    ;;
*) usage ;;
esac
