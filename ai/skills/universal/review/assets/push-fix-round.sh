#!/usr/bin/env bash
# Run-owner transaction: trusted broker + monitor-owned reservation lifecycle.
set -euo pipefail
export GIT_NO_REPLACE_OBJECTS=1
usage() {
    cat >&2 <<'HELP'
Usage: push-fix-round.sh --run-id ID --active-state FILE --generation N
  --event ID --remote NAME --branch NAME --host HOST --repo OWNER/REPO
  --against REF --scratch-dir DIR [--stale-event ID] [--rigor LEVEL]
  [--strategy NAME] [-c NAME=VALUE]...

Run from the clean, committed feature worktree. --against is the owner's
trusted target branch ref. Scratch must resolve outside that worktree.
A stale event is cancelled only after observing its head absent remotely;
use a NEW event ID for the replacement. Repeating an adopted current event
only reconciles it. Failed pushes are observed and reconciled too; absent
attempts are cancelled, indeterminate attempts require owner investigation.
HELP
    exit 2
}
fail() {
    printf 'push-fix-round: %s\n' "$*" >&2
    exit 2
}
run_id= active_state= generation= event= remote= branch= host= repo= against= scratch_dir= stale_event=
policy_args=() transport=()
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
    --run-id) run_id=$2 ;;
    --active-state) active_state=$2 ;;
    --generation) generation=$2 ;;
    --event) event=$2 ;;
    --remote) remote=$2 ;;
    --branch) branch=$2 ;;
    --host) host=$2 ;;
    --repo) repo=$2 ;;
    --against) against=$2 ;;
    --scratch-dir) scratch_dir=$2 ;;
    --stale-event) stale_event=$2 ;;
    --rigor | --strategy) policy_args+=("$1" "$2") ;;
    -c) transport+=("$1" "$2") ;;
    *) usage ;;
    esac
    shift 2
done
for value in "$run_id" "$active_state" "$generation" "$event" "$remote" "$branch" "$host" "$repo" "$against" "$scratch_dir"; do
    [ -n "$value" ] || usage
done
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
monitor="$asset_dir/../../orchestrate/assets/dev-flow-monitor.sh"
root="$(git rev-parse --show-toplevel)"
cd "$root"
[ "$(git symbolic-ref --quiet --short HEAD)" = "$branch" ] || fail 'branch mismatch'
[ -z "$(git status --porcelain --untracked-files=all)" ] || fail 'commit changes before pushing'
head="$(git rev-parse HEAD)"
ref="$(git rev-parse --symbolic-full-name --verify "$against")"
case "$ref" in refs/*) ;; *) fail '--against must name a target ref' ;; esac
[ ! -e "$(git rev-parse --git-path info/grafts)" ] || fail 'grafted history cannot establish a trusted closure'
base="$(git merge-base "$ref" "$head")"
mkdir -p "$scratch_dir"
scratch_dir="$(cd "$scratch_dir" && pwd -P)"
case "$scratch_dir/" in "$root/"*) fail 'scratch must be outside the feature worktree' ;; esac
work="$(mktemp -d "$scratch_dir/push-fix-round.XXXXXX")"
lock=
cleanup() {
    rm -rf "$work"
    if [ -n "$lock" ]; then rmdir "$lock"; fi
}
trap cleanup EXIT
# Extract immutable content before invoking any policy reader or broker.
# Full extraction preserves relative imports and consumer/source layouts.
git archive --format=tar "$base" >"$work/base.tar"
mkdir "$work/closure"
tar -xf "$work/base.tar" -C "$work/closure"
closure="$work/closure"
find_asset() {
    local path
    for path in "ai/skills/universal/$1" ".agents/skills/$1" ".claude/skills/$1"; do
        if [ -f "$closure/$path" ] && [ ! -L "$closure/$path" ]; then
            printf '%s\n' "$closure/$path"
            return 0
        fi
    done
    fail "merge base lacks $1; no branch-code fallback"
}
broker="$(find_asset review/assets/round-push.sh)"
reader="$(find_asset dev-flow-support/assets/devflow-policy.mjs)"
# --list excludes targets without descriptions; gate aliases need not have one.
task --dir "$root" --list-all --json >"$work/tasks.json"
jq -e '[.tasks[].name] | if all(.[]; type == "string") then . else error("invalid task list") end' \
    "$work/tasks.json" >"$work/task-targets.json"
"$monitor" check-assets --repo-root "$root"
state="$("$monitor" state-path --run-id "$run_id" --repo-root "$root")"
mkdir "${state}.push-fix-lock" || fail 'another push command owns this run; inspect stale locks before retrying'
lock="${state}.push-fix-lock"
identity=(--state "$state" --run-id "$run_id" --active-state "$active_state" --branch "$branch" --generation "$generation" --repo-root "$root")
broker_remote=(--remote "$remote" --branch "$branch" --host "$host" --repo "$repo")
read_remote() {
    # preflight validates destination, transport and forge permission before
    # reading. Never reinterpret a failed remote read as an absent branch.
    "$broker" preflight "${broker_remote[@]}" ${transport[@]+"${transport[@]}"}
}
remote_head="$(read_remote)"
observe() {
    local observed_event=$1 observed_head=$2
    jq -n --arg event "$observed_event" --arg head "$observed_head" --arg remote "$remote_head" \
        --arg status "$3" '{event:$event, action:"push", head:$head, status:$status, remote_head:$remote}' >"$work/observed.json"
}
# An unchanged tip alone proves nothing about whether a push landed. Resolve
# commit reachability before either authorizing a retry or cancelling intent.
head_presence() {
    local expected=$1 observed=$2 ancestry_rc=0 shallow_state
    if [ "$observed" = absent ]; then
        printf '%s\n' absent
    elif [ "$observed" = "$expected" ]; then
        printf '%s\n' landed
    elif ! git cat-file -e "$observed^{commit}" 2>/dev/null; then
        printf '%s\n' indeterminate
    else
        git merge-base --is-ancestor "$expected" "$observed" 2>/dev/null || ancestry_rc=$?
        case "$ancestry_rc" in
        0) printf '%s\n' landed ;;
        1)
            # A shallow boundary can hide the expected commit even when its
            # object exists locally. Negative reachability needs full history.
            shallow_state="$(git rev-parse --is-shallow-repository 2>/dev/null)" || shallow_state=unknown
            if [ "$shallow_state" = false ]; then
                printf '%s\n' absent
            else printf '%s\n' indeterminate; fi
            ;;
        *) printf '%s\n' indeterminate ;;
        esac
    fi
}
if [ -n "$stale_event" ]; then
    [ "$stale_event" != "$event" ] || fail 'replacement must use a new event ID'
    stale_reservation="$(jq -ec --arg event "$stale_event" '
        [.actions[] | select(.event == $event)] |
        if length == 1 and .[0].action == "push" then .[0]
        else error("stale event must identify exactly one push") end' "$state")"
    stale_head="$(jq -r '.expected_head' <<<"$stale_reservation")"
    case "$(jq -r '.state' <<<"$stale_reservation")" in
    cancelled)
        # Cancellation is a durable boundary. An exact retry must reach the
        # replacement's reserve/adopt path, including after a successful push
        # that now contains the old commit in its ancestry.
        jq -e --arg event "$stale_event" '
            (.cancellation.reason | type == "string" and length > 0) and
            .cancellation.observation.status == "absent" and
            .cancellation.observation.event == $event and
            .cancellation.observation.action == "push" and
            .cancellation.observation.head == .expected_head
        ' <<<"$stale_reservation" >/dev/null || fail 'stale cancellation lacks a bound absent observation'
        ;;
    reserved)
        case "$(head_presence "$stale_head" "$remote_head")" in
        absent) ;;
        landed) fail 'stale push landed; reconcile it instead of cancelling' ;;
        *) fail 'stale head ancestry is indeterminate; investigate before cancelling' ;;
        esac
        observe "$stale_event" "$stale_head" absent
        "$monitor" cancel "${identity[@]}" --writer feature-owner --event "$stale_event" \
            --observed "$work/observed.json" --reason 'remote observation proves stale push absent; replacing with a new event'
        ;;
    *) fail 'stale push must be reserved or validly cancelled' ;;
    esac
fi
existing=""
if [ -e "$state" ]; then
    existing="$(jq -er --arg event "$event" '[.actions[] | select(.event == $event)] | if length == 0 then "" elif length == 1 and .[0].action == "push" then .[0] else error("invalid event") end' "$state")"
fi
if [ -n "$existing" ]; then
    [ "$(jq -r .expected_head <<<"$existing")" = "$head" ] || fail 'event names a different head; use --stale-event and a new event'
    case "$(jq -r .state <<<"$existing")" in
    adopted)
        [ "$(head_presence "$head" "$remote_head")" = landed ] || fail 'adopted push is not provably present on remote; investigate'
        observe "$event" "$head" landed
        "$monitor" reconcile "${identity[@]}" --event "$event" --observed "$work/observed.json"
        exit 0
        ;;
    reserved) ;;
    *) fail 'event is not actionable; use a new event ID' ;;
    esac
else
    "$monitor" reserve "${identity[@]}" --writer feature-owner --event "$event" --action push --expected-head "$head"
fi
status="$(head_presence "$head" "$remote_head")"
observe "$event" "$head" "$status"
"$monitor" reconcile "${identity[@]}" --event "$event" --observed "$work/observed.json"
[ "$status" != landed ] || exit 0
push_rc=0
"$broker" push "${broker_remote[@]}" --sha "$head" --expect "$remote_head" \
    --against "$ref" --closure-base "$base" --policy "$closure/.devflow.toml" \
    --devflow-policy-script "$reader" --registry "$closure/agent-registry.json" \
    --gitleaks-script "$closure/scripts/gitleaks-scan.sh" --gitleaks-config "$closure/.gitleaks.toml" \
    --task-targets "$work/task-targets.json" ${policy_args[@]+"${policy_args[@]}"} ${transport[@]+"${transport[@]}"} || push_rc=$?
# The only continuation after a failed broker is read/reconciliation, never
# another push. Keep the broker's failure even if its push actually landed.
before="$remote_head"
remote_head="$(read_remote)"
status="$(head_presence "$head" "$remote_head")"
# A changed tip that does not contain our head cannot establish what happened
# during the attempt. Preserve the reservation rather than guessing absence.
if [ "$status" = absent ] && [ "$remote_head" != "$before" ]; then
    status=indeterminate
fi
observe "$event" "$head" "$status"
"$monitor" reconcile "${identity[@]}" --event "$event" --observed "$work/observed.json"
if [ "$status" = absent ]; then
    "$monitor" cancel "${identity[@]}" --writer feature-owner --event "$event" \
        --observed "$work/observed.json" --reason 'broker attempt ended with push observed absent'
    [ "$push_rc" -ne 0 ] || push_rc=2
fi
exit "$push_rc"
