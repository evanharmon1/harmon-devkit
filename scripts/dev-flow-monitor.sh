#!/usr/bin/env bash
# Durable reservation/reconciliation primitive for /orchestrator.  It keeps
# replayable external action intent outside run.json, whose schema deliberately
# limits it to lifecycle state.  Callers supply an observed postcondition; this
# helper refuses to infer one from a stale or malformed observation.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  dev-flow-monitor.sh state-path --run-id ID [--repo-root DIR]
  dev-flow-monitor.sh reserve --state FILE --event ID --action assembly|push|comment \
    --expected-head SHA --writer feature-owner \
    [--trusted-actor-id ID --marker TEXT --payload-digest SHA256]
  dev-flow-monitor.sh reconcile --state FILE --event ID --observed FILE

The state file is durable monitor state.  A reservation is written before an
external action.  The observed file must be JSON with status landed, absent, or
indeterminate; landed also requires matching event, action, and expected_head.
Comment observations additionally require comment_id, trusted actor_id, marker,
payload_digest, and body; the body is hashed again before adoption.
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
run_id=""
repo_root="."
trusted_actor_id=""
marker=""
payload_digest=""

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
    --run-id)
        run_id="${2:-}"
        shift 2
        ;;
    --repo-root)
        repo_root="${2:-}"
        shift 2
        ;;
    --trusted-actor-id)
        trusted_actor_id="${2:-}"
        shift 2
        ;;
    --marker)
        marker="${2:-}"
        shift 2
        ;;
    --payload-digest)
        payload_digest="${2:-}"
        shift 2
        ;;
    *) usage ;;
    esac
done

if [ "$command_name" = "state-path" ]; then
    [[ "$run_id" =~ ^[A-Za-z0-9._-]+$ ]] || die "run id is missing or unsafe"
    common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
        die "could not resolve git common directory"
    printf '%s/dev-flow-v2/runs/%s/monitor.json\n' "$common_dir" "$run_id"
    exit 0
fi

[ -n "$state" ] && [ -n "$event" ] || usage
command -v flock >/dev/null 2>&1 || die "flock is required"
mkdir -p "$(dirname "$state")"
# The state is a read-modify-write record shared by monitor re-arms. Keep the
# lock beside it so callers with the same durable state serialize both reserve
# and reconciliation; a temp-file rename alone cannot prevent lost updates.
exec 9>"${state}.lock"
flock -x 9
case "$command_name" in
reserve)
    [ -n "$action" ] && [ -n "$expected_head" ] && [ -n "$writer" ] || usage
    case "$action" in assembly | push | comment) ;; *) die "action $action is not replayable" ;; esac
    [ "$writer" = "feature-owner" ] || die "only the feature-branch owner may reserve $action"
    if [ "$action" = "comment" ]; then
        [[ "$trusted_actor_id" =~ ^[1-9][0-9]*$ ]] || die "comment reservation requires a trusted actor id"
        [ -n "$marker" ] || die "comment reservation requires a deterministic marker"
        [[ "$payload_digest" =~ ^[0-9a-f]{64}$ ]] || die "comment reservation requires a SHA-256 payload digest"
    fi
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
    jq --arg event "$event" --arg action "$action" --arg head "$expected_head" \
        --arg actor "$trusted_actor_id" --arg marker "$marker" --arg digest "$payload_digest" '
            .actions += [{
                event: $event,
                action: $action,
                expected_head: $head,
                state: "reserved",
                comment_auth: (if $action == "comment" then {
                    trusted_actor_id: $actor,
                    marker: $marker,
                    payload_digest: $digest
                } else null end)
            }]
        ' "$state" >"$tmp"
    mv "$tmp" "$state"
    printf 'reserved %s\n' "$event"
    ;;
reconcile)
    [ -n "$observed" ] && [ -f "$observed" ] || usage
    jq -e '.version == 1 and (.actions | type == "array")' "$state" >/dev/null || die "invalid state"
    reservation="$(jq -c --arg event "$event" '.actions[] | select(.event == $event)' "$state")"
    [ -n "$reservation" ] || die "unknown reservation $event"
    reservation_state="$(jq -r '.state' <<<"$reservation")"
    case "$reservation_state" in
    adopted)
        # A stale re-arm must adopt the durable result, not retry a write
        # already known to have landed.
        printf 'adopt %s\n' "$event"
        exit 0
        ;;
    reserved) ;;
    *) die "reservation $event is not actionable" ;;
    esac
    status="$(jq -r '.status // empty' "$observed")"
    case "$status" in
    landed)
        jq -e --arg event "$event" '
            . as $state |
            [$state.actions[].event] | index($event) as $index |
            [$state.actions[0:$index][] | select(.state != "adopted")] | length == 0
        ' "$state" >/dev/null || die "cannot adopt $event out of reservation order"
        expected_action="$(jq -r '.action' <<<"$reservation")"
        expected_head_value="$(jq -r '.expected_head' <<<"$reservation")"
        jq -e --arg event "$event" --arg action "$expected_action" --arg head "$expected_head_value" '
                    .event == $event and .action == $action and .head == $head
                ' "$observed" >/dev/null || die "landed postcondition does not match reservation"
        comment_id=""
        if [ "$expected_action" = "comment" ]; then
            expected_actor="$(jq -r '.comment_auth.trusted_actor_id' <<<"$reservation")"
            expected_marker="$(jq -r '.comment_auth.marker' <<<"$reservation")"
            expected_digest="$(jq -r '.comment_auth.payload_digest' <<<"$reservation")"
            jq -e --arg actor "$expected_actor" --arg marker "$expected_marker" --arg digest "$expected_digest" '
                (.comment_id | type == "number" and . > 0 and floor == .) and
                (.actor_id | tostring) == $actor and
                .marker == $marker and
                .payload_digest == $digest and
                (.body | type == "string" and contains($marker))
            ' "$observed" >/dev/null || die "comment postcondition is not authenticated"
            actual_digest="$(jq -j '.body' "$observed" | sha256sum | awk '{print $1}')"
            [ "$actual_digest" = "$expected_digest" ] || die "comment body digest does not match reservation"
            comment_id="$(jq -r '.comment_id' "$observed")"
        fi
        tmp="${state}.tmp.$$"
        jq --arg event "$event" --arg comment_id "$comment_id" '
                    .actions |= map(if .event == $event then .state = "adopted" else . end) |
                    .actions |= map(if .event == $event and $comment_id != "" then
                        .postcondition = {comment_id: $comment_id}
                    else . end) |
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
