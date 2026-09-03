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
  dev-flow-monitor.sh active-path --branch BRANCH [--repo-root DIR]
  dev-flow-monitor.sh activate --active-state FILE --run-id ID --branch BRANCH \
    --expected-generation N --registry-revision SHA --writer feature-owner \
    [--repo-root DIR]
  dev-flow-monitor.sh reserve --state FILE --event ID --action assembly|push|comment \
    --expected-head SHA --writer feature-owner --active-state FILE --run-id ID \
    --branch BRANCH --generation N [--repo-root DIR] \
    [--trusted-actor-id ID --registry-revision SHA --repo-root DIR \
     --marker TEXT --payload-digest SHA256]
  dev-flow-monitor.sh reconcile --state FILE --event ID --observed FILE \
    --active-state FILE --run-id ID --branch BRANCH --generation N \
    [--repo-root DIR]

The state file is durable monitor state.  A reservation is written before an
external action.  The observed file must be JSON with status landed, absent, or
indeterminate; landed also requires matching event, action, and expected_head.
Comment reservations authenticate the actor against the run-pinned registry
revision. Comment observations provide a complete comments[] candidate set;
the monitor filters and hashes it, then adopts the lowest matching comment ID.
`reconcile` prints adopt, retry, or block and advances the event cursor only
for an adopted landed action.  PR merges are never reservable.
EOF
    exit 2
}

die() {
    printf 'dev-flow-monitor: %s\n' "$*" >&2
    exit 2
}

sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        die "sha256sum or shasum is required"
    fi
}

lock_host="$(hostname)"
lock_uid="$(id -u)"
held_lock_file=""
held_lock_owner=""
lock_claim_file=""
held_break_dir=""
release_lock() {
    if [ -n "$lock_claim_file" ]; then
        rm -f "$lock_claim_file"
        lock_claim_file=""
    fi
    if [ -n "$held_lock_file" ] &&
        [ "$(cat "$held_lock_file" 2>/dev/null || true)" = "$held_lock_owner" ]; then
        rm -f "$held_lock_file"
    fi
    held_lock_file=""
    held_lock_owner=""
    if [ -n "$held_break_dir" ]; then
        rmdir "$held_break_dir" 2>/dev/null || true
        held_break_dir=""
    fi
}

lock_owner_stamp() {
    owner_start="$(LC_ALL=C TZ=UTC ps -o lstart= -p $$ 2>/dev/null |
        sed 's/^ *//;s/ *$//')"
    [ -n "$owner_start" ] || die "could not identify the monitor lock owner"
    printf '%s|%s|%s|%s|%s\n' "$$" "$lock_host" "$lock_uid" \
        "n$$.$RANDOM$RANDOM$RANDOM" "$owner_start"
}

lock_owner_alive() {
    owner_record="$1"
    IFS='|' read -r owner_pid owner_host owner_uid _owner_nonce owner_start <<EOF
$owner_record
EOF
    [ "$owner_host" = "$lock_host" ] || return 0
    [ "$owner_uid" = "$lock_uid" ] || return 0
    case "$owner_pid" in "" | *[!0-9]*) return 0 ;; esac
    [ -n "$owner_start" ] || return 0
    current_start="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$owner_pid" 2>/dev/null |
        sed 's/^ *//;s/ *$//')"
    [ -n "$current_start" ] || return 1
    [ "$current_start" = "$owner_start" ]
}

try_break_stale_lock() {
    stale_lock_file="$1"
    expected_owner="$2"
    break_dir="${stale_lock_file}.break"
    mkdir "$break_dir" 2>/dev/null || return 1
    held_break_dir="$break_dir"
    current_owner="$(cat "$stale_lock_file" 2>/dev/null || true)"
    if [ "$current_owner" != "$expected_owner" ] || lock_owner_alive "$current_owner"; then
        rmdir "$held_break_dir" 2>/dev/null || true
        held_break_dir=""
        return 1
    fi
    dead_lock_file="${stale_lock_file}.dead.$$.$RANDOM"
    if mv "$stale_lock_file" "$dead_lock_file" 2>/dev/null; then
        rm -f "$dead_lock_file"
    fi
    rmdir "$held_break_dir" 2>/dev/null || true
    held_break_dir=""
    return 0
}

acquire_lock() {
    candidate_lock_file="${1}.lock"
    candidate_owner="$(lock_owner_stamp)"
    lock_claim_file="${candidate_lock_file}.claim.$$.$RANDOM"
    printf '%s\n' "$candidate_owner" >"$lock_claim_file"
    lock_attempts=0
    dead_owner=""
    dead_observations=0
    while ! ln "$lock_claim_file" "$candidate_lock_file" 2>/dev/null; do
        if [ ! -e "$candidate_lock_file" ]; then
            continue
        fi
        [ -f "$candidate_lock_file" ] || die "monitor lock is not a file: $candidate_lock_file"
        observed_owner="$(cat "$candidate_lock_file" 2>/dev/null || true)"
        if [ -n "$observed_owner" ] && ! lock_owner_alive "$observed_owner"; then
            if [ "$observed_owner" = "$dead_owner" ]; then
                dead_observations=$((dead_observations + 1))
            else
                dead_owner="$observed_owner"
                dead_observations=1
            fi
            # A dead shell may leave its current git/jq/mv child behind. Give
            # that bounded work two seconds to settle before reclaiming.
            if [ "$dead_observations" -ge 20 ]; then
                try_break_stale_lock "$candidate_lock_file" "$observed_owner" || true
                dead_owner=""
                dead_observations=0
                continue
            fi
        else
            dead_owner=""
            dead_observations=0
        fi
        lock_attempts=$((lock_attempts + 1))
        [ "$lock_attempts" -lt 600 ] ||
            die "monitor state remains locked; inspect $candidate_lock_file before retrying"
        sleep 0.1
    done
    held_lock_file="$candidate_lock_file"
    held_lock_owner="$candidate_owner"
    rm -f "$lock_claim_file"
    lock_claim_file=""
}

trap release_lock EXIT

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
registry_revision=""
active_state=""
branch=""
generation=""
expected_generation=""

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
    --registry-revision)
        registry_revision="${2:-}"
        shift 2
        ;;
    --active-state)
        active_state="${2:-}"
        shift 2
        ;;
    --branch)
        branch="${2:-}"
        shift 2
        ;;
    --generation)
        generation="${2:-}"
        shift 2
        ;;
    --expected-generation)
        expected_generation="${2:-}"
        shift 2
        ;;
    *) usage ;;
    esac
done

validate_run_id() {
    [[ "$run_id" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$run_id" != "." ] && [ "$run_id" != ".." ] ||
        die "run id is missing or unsafe"
}

state_path() {
    validate_run_id
    common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
        die "could not resolve git common directory"
    printf '%s/dev-flow-v2/runs/%s/monitor.json\n' "$common_dir" "$run_id"
}

if [ "$command_name" = "state-path" ]; then
    state_path
    exit 0
fi

active_path() {
    local common_dir branch_key
    common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
        die "could not resolve git common directory"
    branch_key="$(printf '%s' "$branch" | sha256_stream)"
    printf '%s/dev-flow-v2/active/%s.json\n' "$common_dir" "$branch_key"
}

if [ "$command_name" = "active-path" ]; then
    [ -n "$branch" ] || die "branch is required"
    active_path
    exit 0
fi

if [ "$command_name" = "activate" ]; then
    validate_run_id
    [ -n "$branch" ] && [ -n "$active_state" ] && [ "$writer" = "feature-owner" ] || usage
    [[ "$expected_generation" =~ ^(0|[1-9][0-9]*)$ ]] || die "expected generation must be a non-negative integer"
    [[ "$registry_revision" =~ ^[0-9a-f]{40}$ ]] ||
        die "activation requires a full kickoff-pinned registry revision"
    git -C "$repo_root" show "${registry_revision}:agent-registry.json" >/dev/null 2>&1 ||
        die "could not read agent-registry.json at the kickoff-pinned revision"
    [ "$active_state" = "$(active_path)" ] || die "active state path is not canonical for this branch"
    mkdir -p "$(dirname "$active_state")"
    acquire_lock "$active_state"
    if [ -e "$active_state" ]; then
        # Re-arm after a crash that landed the activation: adopt the exact
        # already-active generation instead of superseding it a second time.
        if jq -e --arg run "$run_id" --arg branch "$branch" --arg registry "$registry_revision" \
            --argjson next "$((expected_generation + 1))" '
            .version == 1 and .run_id == $run and .branch == $branch and
            .generation == $next and .registry_revision == $registry
        ' "$active_state" >/dev/null; then
            printf '%s\n' "$((expected_generation + 1))"
            exit 0
        fi
        current_generation="$(jq -r '.generation // empty' "$active_state")"
        [[ "$current_generation" =~ ^[1-9][0-9]*$ ]] || die "active run state is invalid"
    else
        current_generation=0
    fi
    [ "$current_generation" -eq "$expected_generation" ] ||
        die "active run generation changed (expected $expected_generation, found $current_generation)"
    next_generation=$((expected_generation + 1))
    active_tmp="${active_state}.tmp.$$"
    jq -n --arg run "$run_id" --arg branch "$branch" --arg registry "$registry_revision" \
        --argjson generation "$next_generation" \
        '{version: 1, run_id: $run, branch: $branch, generation: $generation,
          registry_revision: $registry}' >"$active_tmp"
    mv "$active_tmp" "$active_state"
    printf '%s\n' "$next_generation"
    exit 0
fi

[ -n "$state" ] && [ -n "$event" ] || usage
[ -n "$active_state" ] && [ -n "$run_id" ] && [ -n "$branch" ] || usage
validate_run_id
[[ "$generation" =~ ^[1-9][0-9]*$ ]] || die "generation must be a positive integer"
[ "$active_state" = "$(active_path)" ] || die "active state path is not canonical for this branch"
expected_state="$(state_path)"
[ "$state" = "$expected_state" ] || die "monitor state path is not canonical for this run"
acquire_lock "$active_state"
jq -e --arg run "$run_id" --arg branch "$branch" --argjson generation "$generation" '
    .version == 1 and .run_id == $run and .branch == $branch and
    .generation == $generation and
    (.registry_revision | type == "string" and test("^[0-9a-f]{40}$"))
' "$active_state" >/dev/null || die "run is no longer active for this branch generation"
mkdir -p "$(dirname "$state")"
case "$command_name" in
reserve)
    [ -n "$action" ] && [ -n "$expected_head" ] && [ -n "$writer" ] || usage
    case "$action" in assembly | push | comment) ;; *) die "action $action is not replayable" ;; esac
    [ "$writer" = "feature-owner" ] || die "only the feature-branch owner may reserve $action"
    if [ "$action" = "comment" ]; then
        [[ "$trusted_actor_id" =~ ^[1-9][0-9]*$ ]] || die "comment reservation requires a trusted actor id"
        [[ "$registry_revision" =~ ^[0-9a-f]{40}$ ]] ||
            die "comment reservation requires a full run-pinned registry revision"
        active_registry_revision="$(jq -r '.registry_revision' "$active_state")"
        [ "$registry_revision" = "$active_registry_revision" ] ||
            die "registry revision does not match the active run"
        [ -n "$marker" ] || die "comment reservation requires a deterministic marker"
        [[ "$payload_digest" =~ ^[0-9a-f]{64}$ ]] || die "comment reservation requires a SHA-256 payload digest"
        # The actor ID is evidence, not authority. Resolve authority from the
        # immutable registry snapshot captured for this run; accepting the ID
        # merely because the caller repeated it would let a forged record
        # vouch for its own comments. #741 owns adding this top-level allowlist
        # to the live registry/schema. Until it lands, the absent list remains
        # empty and comment evidence correctly fails closed.
        registry_json="$(git -C "$repo_root" show "${registry_revision}:agent-registry.json" 2>/dev/null)" ||
            die "could not read agent-registry.json at the run-pinned revision"
        jq -e --arg actor "$trusted_actor_id" '
            (.trusted_orchestrator_actor_ids // []) | index($actor) != null
        ' <<<"$registry_json" >/dev/null ||
            die "comment actor id is not trusted by the run-pinned registry revision"
    fi
    if [ ! -e "$state" ]; then
        init_tmp="${state}.tmp.init.$$"
        jq -n '{version: 1, cursor: null, actions: []}' >"$init_tmp"
        mv "$init_tmp" "$state"
    fi
    jq -e --arg event "$event" --arg action "$action" --arg head "$expected_head" '
            (.version == 1) and
            ([.actions[] | select(.event == $event)] | length == 0) and
            ($head | test("^[0-9a-f]{40}$")) and
            ($action != "merge")
        ' "$state" >/dev/null || die "invalid state, duplicate event, or invalid reservation"
    tmp="${state}.tmp.$$"
    jq --arg event "$event" --arg action "$action" --arg head "$expected_head" \
        --arg actor "$trusted_actor_id" --arg registry_revision "$registry_revision" \
        --arg marker "$marker" --arg digest "$payload_digest" '
            .actions += [{
                event: $event,
                action: $action,
                expected_head: $head,
                state: "reserved",
                comment_auth: (if $action == "comment" then {
                    trusted_actor_id: $actor,
                    registry_revision: $registry_revision,
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
            jq -e '.comments | type == "array"' "$observed" >/dev/null ||
                die "comment observation must contain the complete comments candidate set"
            candidates="$(jq -c --arg actor "$expected_actor" --arg marker "$expected_marker" \
                --arg digest "$expected_digest" '
                    [.comments[] | select(
                        (.comment_id | type == "number" and . > 0 and floor == .) and
                        (.actor_id | tostring) == $actor and
                        .marker == $marker and
                        .payload_digest == $digest and
                        (.body | type == "string" and contains($marker))
                    )] | sort_by(.comment_id)[]
                ' "$observed")"
            while IFS= read -r candidate; do
                [ -n "$candidate" ] || continue
                actual_digest="$(jq -j '.body' <<<"$candidate" | sha256_stream)"
                [ "$actual_digest" = "$expected_digest" ] || continue
                comment_id="$(jq -r '.comment_id' <<<"$candidate")"
                break
            done <<<"$candidates"
            [ -n "$comment_id" ] || die "comment postcondition is not authenticated"
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
