#!/usr/bin/env bash
# Durable reservation/reconciliation primitive for /orchestrate.  It keeps
# replayable external action intent outside run.json, whose schema deliberately
# limits it to lifecycle state.  Callers supply an observed postcondition; this
# helper refuses to infer one from a stale or malformed observation.
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  dev-flow-monitor.sh state-path --run-id ID [--repo-root DIR]
  dev-flow-monitor.sh active-path --branch BRANCH [--repo-root DIR]
  dev-flow-monitor.sh retire --run-id ID [--repo-root DIR]
  dev-flow-monitor.sh prune [--dry-run] [--repo-root DIR]
  dev-flow-monitor.sh orchestrator-dir --slate-id ID --run-id ID --nonce NONCE \
    [--repo-root DIR]
  dev-flow-monitor.sh activate --active-state FILE --run-id ID --branch BRANCH \
    --expected-generation N --registry-revision SHA --writer feature-owner \
    [--repo-root DIR]
  dev-flow-monitor.sh reserve-agent-run --state FILE --event ID \
    --max-agent-runs N --writer feature-owner --active-state FILE --run-id ID \
    --branch BRANCH --generation N [--repo-root DIR]
  dev-flow-monitor.sh reserve --state FILE --event ID --action assembly|push|comment \
    --expected-head SHA --writer feature-owner --active-state FILE --run-id ID \
    --branch BRANCH --generation N [--repo-root DIR] \
    [--assembly-plan FILE] \
    [--trusted-actor-id ID --repo-root DIR \
     --evidence-role ROLE --evidence-finder FINDER \
     --marker TEXT --payload-digest SHA256 \
     --comment-lock-fd N]
  dev-flow-monitor.sh reconcile --state FILE --event ID --observed FILE \
    --active-state FILE --run-id ID --branch BRANCH --generation N \
    [--repo-root DIR]

`orchestrator-dir` prints the orchestrator's own per-run, per-attempt
working directory (dispatch files, rulings, watcher state):
<git-common-dir>/dev-flow-v2/slates/<slate-id>/orchestrator/<run-id>/<nonce>.

The state file is durable monitor state.  A reservation is written before an
external action.  The observed file must be JSON with status landed, absent, or
indeterminate; landed also requires matching event, action, and expected_head.
Assembly reservations require a JSON plan naming integrated_lanes and
discarded_lanes; a landed observation must reproduce both lists exactly.
Comment reservations authenticate the actor against the governing registry
revision (the newest revision on the default branch, resolved per write). Comment observations provide a complete comments[] candidate set;
the monitor filters and hashes it, then adopts the lowest matching comment ID.
Agent-run reservations durably enforce the run-wide max_agent_runs ceiling;
an exact event re-arm adopts the already-spent slot without consuming another.
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
run_binding_claim=""
release_lock() {
    if [ -n "$run_binding_claim" ]; then
        rm -f "$run_binding_claim"
        run_binding_claim=""
    fi
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
    local lock_wait_limit="${2:-600}"
    candidate_lock_file="${1}.lock"
    candidate_owner="$(lock_owner_stamp)"
    lock_claim_file="${candidate_lock_file}.claim.$$.$RANDOM"
    printf '%s\n' "$candidate_owner" >"$lock_claim_file"
    lock_attempts=0
    nonfile_observations=0
    dead_owner=""
    dead_observations=0
    while ! ln "$lock_claim_file" "$candidate_lock_file" 2>/dev/null; do
        # The holder can release the lock between any two tests here, so a
        # successful `-e` says nothing about the next syscall. Ask the question
        # that decides the action first — is it a regular file? — and only then
        # ask whether it is still there at all, so "gone" reads as the ordinary
        # race it is instead of as a corrupt lock. Testing `-e` first and
        # dying on the following `-f` inverts that: it makes a benign release
        # fatal, which is what flaked `monitor serializes concurrent
        # reservations` under a loaded machine (#689).
        if [ ! -f "$candidate_lock_file" ]; then
            # Two probes cannot be atomic, so BOTH orders have a race. Testing
            # `-e` first and dying on `-f` makes a benign release fatal (the
            # original #689 flake). Testing `-f` first and dying on `-e` makes a
            # legitimate ACQUISITION by another contender fatal: the lock is
            # absent for `-f`, another process creates it, and `-e` then reports
            # a "corrupt" lock that is in fact a valid regular file.
            #
            # So the fatal path re-checks the TYPE, and requires it to stay
            # wrong across consecutive observations. A contender's lock appearing
            # mid-probe reads as a retry; only a path that is persistently
            # present and persistently not a regular file is a misconfiguration.
            if [ -e "$candidate_lock_file" ] && [ ! -f "$candidate_lock_file" ]; then
                nonfile_observations=$((nonfile_observations + 1))
                if [ "$nonfile_observations" -ge 3 ]; then
                    die "monitor lock is not a file: $candidate_lock_file"
                fi
                sleep 0.1
            else
                nonfile_observations=0
            fi
            continue
        fi
        nonfile_observations=0
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
        if [ "$lock_attempts" -ge "$lock_wait_limit" ]; then
            rm -f "$lock_claim_file"
            lock_claim_file=""
            if [ "$lock_wait_limit" -lt 600 ]; then
                return 1
            fi
            die "monitor state remains locked; inspect $candidate_lock_file before retrying"
        fi
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
evidence_role=""
evidence_finder=""
registry_revision=""
active_state=""
branch=""
generation=""
expected_generation=""
assembly_plan=""
max_agent_runs=""
slate_id=""
nonce=""
comment_lock_fd=""
dry_run=false

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
    --evidence-role)
        evidence_role="${2:-}"
        shift 2
        ;;
    --evidence-finder)
        evidence_finder="${2:-}"
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
    --slate-id)
        slate_id="${2:-}"
        shift 2
        ;;
    --nonce)
        nonce="${2:-}"
        shift 2
        ;;
    --comment-lock-fd)
        comment_lock_fd="${2:-}"
        shift 2
        ;;
    --dry-run)
        dry_run=true
        shift
        ;;
    --generation)
        generation="${2:-}"
        shift 2
        ;;
    --expected-generation)
        expected_generation="${2:-}"
        shift 2
        ;;
    --assembly-plan)
        assembly_plan="${2:-}"
        shift 2
        ;;
    --max-agent-runs)
        max_agent_runs="${2:-}"
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

run_branch_binding() {
    local binding
    binding="$(dirname "$(state_path)")/branch.json"
    [ -f "$binding" ] && [ ! -L "$binding" ] || die "run branch binding is missing or not a regular file: $binding"
    jq -e --arg run "$run_id" '
        .version == 1 and .run_id == $run and
        (.branch | type == "string" and length > 0)
    ' "$binding" >/dev/null 2>&1 || die "run branch binding is invalid for $run_id: $binding"
    jq -r '.branch' "$binding"
}

monitor_has_unreconciled_reservation() {
    local monitor
    monitor="$(state_path)"
    [ -e "$monitor" ] || return 1
    [ -f "$monitor" ] && [ ! -L "$monitor" ] || die "monitor state is not a regular file: $monitor"
    jq -e '
        .version == 1 and (.actions | type == "array") and
        all(.actions[]; .state == "reserved" or .state == "adopted")
    ' "$monitor" >/dev/null 2>&1 || die "monitor state is invalid: $monitor"
    jq -e '[.actions[] | select(.state == "reserved")] | length > 0' "$monitor" >/dev/null 2>&1
}

retire_active_pointer() {
    local binding_branch pointer pointer_run pointer_generation
    binding_branch="$(run_branch_binding)"
    branch="$binding_branch"
    pointer="$(active_path)"
    [ -e "$pointer" ] || {
        printf 'retire: active pointer for %s is already absent\n' "$run_id"
        return 0
    }
    [ -f "$pointer" ] && [ ! -L "$pointer" ] || die "active pointer is not a regular file: $pointer"
    acquire_lock "$pointer"
    [ -e "$pointer" ] || {
        printf 'retire: active pointer for %s disappeared before the lock was acquired\n' "$run_id"
        return 0
    }
    jq -e '
        .version == 1 and (.run_id | type == "string" and length > 0) and
        (.branch | type == "string" and length > 0) and
        (.generation | type == "number" and . > 0 and floor == .) and
        (.registry_revision | type == "string" and test("^[0-9a-f]{40}$"))
    ' "$pointer" >/dev/null 2>&1 || die "active pointer is invalid: $pointer"
    pointer_run="$(jq -r '.run_id' "$pointer")"
    pointer_generation="$(jq -r '.generation' "$pointer")"
    [ "$(jq -r '.branch' "$pointer")" = "$binding_branch" ] || die "active pointer branch does not match run $run_id's branch binding"
    if [ "$pointer_run" != "$run_id" ]; then
        printf 'retire: left active pointer for %s untouched; it now names run %s (generation %s)\n' \
            "$binding_branch" "$pointer_run" "$pointer_generation"
        return 0
    fi
    if monitor_has_unreconciled_reservation; then
        printf 'retire: deferred run %s; monitor.json has an unreconciled reserved action\n' "$run_id"
        return 0
    fi
    rm -- "$pointer" || die "could not remove active pointer: $pointer"
    [ ! -e "$pointer" ] || die "active pointer remains after retirement: $pointer"
    printf 'retired run %s active pointer (generation %s)\n' "$run_id" "$pointer_generation"
}

skip_prune_entry() {
    printf 'prune: skipped %s: %s\n' "$1" "$2"
    skipped_count=$((skipped_count + 1))
    [ -z "$held_lock_file" ] || release_lock
}

prune_pointer() {
    local pointer="$1" name="$2" pointer_json candidate_run candidate_branch generation binding run_record monitor hash_name
    if [ ! -f "$pointer" ] || [ -L "$pointer" ]; then
        skip_prune_entry "$name" "not a regular pointer file"
        return 0
    fi
    if [ -L "${pointer}.lock" ] || { [ -e "${pointer}.lock" ] && [ ! -f "${pointer}.lock" ]; }; then
        skip_prune_entry "$name" "pointer lock is not a regular file"
        return 0
    fi
    if ! acquire_lock "$pointer" 1; then
        skip_prune_entry "$name" "pointer lock is busy"
        return 0
    fi
    if [ ! -f "$pointer" ] || [ -L "$pointer" ]; then
        skip_prune_entry "$name" "pointer changed while acquiring its lock"
        return 0
    fi
    if ! jq -e '
        .version == 1 and
        (.run_id | type == "string" and test("^[A-Za-z0-9._-]+$") and . != "." and . != "..") and
        (.branch | type == "string" and length > 0) and
        (.generation | type == "number" and . > 0 and floor == .) and
        (.registry_revision | type == "string" and test("^[0-9a-f]{40}$"))
    ' "$pointer" >/dev/null 2>&1; then
        skip_prune_entry "$name" "invalid pointer or unsupported version"
        return 0
    fi
    pointer_json="$(cat "$pointer")"
    candidate_run="$(jq -r '.run_id' <<<"$pointer_json")"
    candidate_branch="$(jq -r '.branch' <<<"$pointer_json")"
    generation="$(jq -r '.generation' <<<"$pointer_json")"
    hash_name="$(printf '%s' "$candidate_branch" | sha256_stream).json"
    [ "$name" = "$hash_name" ] || {
        skip_prune_entry "$name" "pointer branch does not match its active-path filename"
        return 0
    }
    run_id="$candidate_run"
    binding="$(dirname "$(state_path)")/branch.json"
    if [ ! -f "$binding" ] || [ -L "$binding" ] || ! jq -e --arg run "$candidate_run" --arg branch "$candidate_branch" '
        .version == 1 and .run_id == $run and .branch == $branch
    ' "$binding" >/dev/null 2>&1; then
        skip_prune_entry "$name" "missing or branch-mismatched run binding"
        return 0
    fi
    run_record="$(dirname "$binding")/run.json"
    if [ ! -f "$run_record" ] || [ -L "$run_record" ]; then
        skip_prune_entry "$name" "run record is missing or not a regular file"
        return 0
    fi
    if ! jq -e --arg run "$candidate_run" '
        .schema == 2 and .run_id == $run and
        (.outcome == "ready-for-review" or .outcome == "capped" or
         .outcome == "escalated" or .outcome == "abandoned")
    ' "$run_record" >/dev/null 2>&1; then
        skip_prune_entry "$name" "run record is invalid or still open"
        return 0
    fi
    monitor="$(state_path)"
    if [ -e "$monitor" ]; then
        if [ ! -f "$monitor" ] || [ -L "$monitor" ] || ! jq -e '
            .version == 1 and (.actions | type == "array") and
            all(.actions[]; .state == "reserved" or .state == "adopted")
        ' "$monitor" >/dev/null 2>&1; then
            skip_prune_entry "$name" "monitor state is invalid"
            return 0
        fi
        if jq -e '[.actions[] | select(.state == "reserved")] | length > 0' "$monitor" >/dev/null 2>&1; then
            skip_prune_entry "$name" "monitor.json has an unreconciled reserved action"
            return 0
        fi
    fi
    if [ "$dry_run" = true ]; then
        printf 'prune: would remove %s (run %s, generation %s)\n' "$name" "$candidate_run" "$generation"
        would_remove_count=$((would_remove_count + 1))
    else
        rm -- "$pointer" || die "could not remove active pointer: $pointer"
        [ ! -e "$pointer" ] || die "active pointer remains after prune: $pointer"
        printf 'prune: removed %s (run %s, generation %s)\n' "$name" "$candidate_run" "$generation"
        removed_count=$((removed_count + 1))
    fi
    release_lock
}

prune_active_pointers() {
    local common_dir active_dir entry name
    common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
        die "could not resolve git common directory"
    active_dir="$common_dir/dev-flow-v2/active"
    removed_count=0
    would_remove_count=0
    skipped_count=0
    if [ ! -d "$active_dir" ]; then
        printf 'prune: active directory is absent; no pointers to inspect\n'
        return 0
    fi
    shopt -s nullglob dotglob
    local entries=("$active_dir"/*)
    for entry in "${entries[@]}"; do
        name="${entry##*/}"
        if [[ "$name" == *.json ]]; then
            prune_pointer "$entry" "$name"
        else
            skip_prune_entry "$name" "leftover lock, temporary, claim, or other non-pointer entry"
        fi
    done
    printf 'prune: complete; removed=%s would_remove=%s skipped=%s\n' \
        "$removed_count" "$would_remove_count" "$skipped_count"
}

orchestrator_dir() {
    local common_dir value
    validate_run_id
    for value in "$slate_id" "$nonce"; do
        [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] && [ "$value" != "." ] && [ "$value" != ".." ] ||
            die "slate id or nonce is missing or unsafe"
    done
    common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ||
        die "could not resolve git common directory"
    printf '%s/dev-flow-v2/slates/%s/orchestrator/%s/%s\n' "$common_dir" "$slate_id" "$run_id" "$nonce"
}

if [ "$command_name" = "orchestrator-dir" ]; then
    orchestrator_dir
    exit 0
fi

if [ "$command_name" = "active-path" ]; then
    [ -n "$branch" ] || die "branch is required"
    active_path
    exit 0
fi

if [ "$command_name" = "retire" ]; then
    validate_run_id
    [ -n "$run_id" ] && [ "$dry_run" = false ] || usage
    retire_active_pointer
    exit 0
fi

if [ "$command_name" = "prune" ]; then
    prune_active_pointers
    exit 0
fi

resolve_governing_registry_revision() {
    local default_ref default_branch gov_rev
    default_ref="$(git -C "$repo_root" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)" ||
        die "could not determine default branch (refs/remotes/origin/HEAD is unset)"
    default_branch="${default_ref#refs/remotes/}"
    gov_rev="$(git -C "$repo_root" log -1 --format='%H' "$default_branch" -- agent-registry.json 2>/dev/null)" ||
        die "could not resolve governing registry revision on ${default_branch}"
    [ -n "$gov_rev" ] ||
        die "no agent-registry.json revision found on ${default_branch}"
    printf '%s\n' "$gov_rev"
}

if [ "$command_name" = "activate" ]; then
    validate_run_id
    [ -n "$branch" ] && [ -n "$active_state" ] && [ "$writer" = "feature-owner" ] || usage
    [[ "$expected_generation" =~ ^(0|[1-9][0-9]*)$ ]] || die "expected generation must be a non-negative integer"
    [[ "$registry_revision" =~ ^[0-9a-f]{40}$ ]] ||
        die "activation requires a full kickoff-pinned registry revision"
    git -C "$repo_root" show "${registry_revision}:agent-registry.json" >/dev/null 2>&1 ||
        die "could not read agent-registry.json at the kickoff-pinned revision"
    [ "$active_state" = "$(active_path)" ] || die "active state path is not canonical for this branch"
    # A run ID names one canonical monitor ledger in the git common dir. Bind
    # that identity to its branch with an atomic hard link before taking the
    # branch pointer lock, so two branch-specific active locks can never race
    # writes into the same run ledger.
    run_binding_file="$(dirname "$(state_path)")/branch.json"
    mkdir -p "$(dirname "$run_binding_file")"
    run_binding_claim="${run_binding_file}.claim.$$.$RANDOM"
    jq -n --arg run "$run_id" --arg branch "$branch" \
        '{version: 1, run_id: $run, branch: $branch}' >"$run_binding_claim"
    if ! ln "$run_binding_claim" "$run_binding_file" 2>/dev/null; then
        [ -f "$run_binding_file" ] || die "run branch binding is not a file"
        jq -e --arg run "$run_id" --arg branch "$branch" '
            .version == 1 and .run_id == $run and .branch == $branch
        ' "$run_binding_file" >/dev/null || die "run id is already bound to a different branch"
    fi
    rm -f "$run_binding_claim"
    run_binding_claim=""
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
reserve-agent-run)
    [ "$writer" = "feature-owner" ] || die "only the feature-branch owner may reserve an agent run"
    [[ "$max_agent_runs" =~ ^(0|[1-9][0-9]*)$ ]] ||
        die "max agent runs must be a non-negative integer"
    if [ ! -e "$state" ]; then
        init_tmp="${state}.tmp.init.$$"
        jq -n '{version: 1, cursor: null, actions: []}' >"$init_tmp"
        mv "$init_tmp" "$state"
    fi
    jq -e '
        .version == 1 and (.actions | type == "array") and
        ((.agent_run_budget // null) == null or
          (.agent_run_budget | type == "object" and
           (.max_agent_runs | type == "number" and floor == . and . >= 0) and
           (.reservations | type == "array") and
           all(.reservations[];
             (.event | type == "string" and length > 0) and
             (.ordinal | type == "number" and floor == . and . > 0))))
    ' "$state" >/dev/null || die "invalid agent-run budget state"
    recorded_max="$(jq -r '.agent_run_budget.max_agent_runs // empty' "$state")"
    if [ -n "$recorded_max" ] && [ "$recorded_max" -ne "$max_agent_runs" ]; then
        die "max agent runs changed (recorded $recorded_max, supplied $max_agent_runs)"
    fi
    reserved_ordinal="$(jq -r --arg event "$event" '
        [.agent_run_budget.reservations[]? | select(.event == $event) | .ordinal][0] // empty
    ' "$state")"
    if [ -n "$reserved_ordinal" ]; then
        printf 'adopt agent-run %s %s/%s\n' "$event" "$reserved_ordinal" "$max_agent_runs"
        exit 0
    fi
    consumed="$(jq -r '(.agent_run_budget.reservations // []) | length' "$state")"
    [ "$consumed" -lt "$max_agent_runs" ] ||
        die "agent-run budget exhausted ($consumed/$max_agent_runs)"
    next_ordinal=$((consumed + 1))
    tmp="${state}.tmp.$$"
    jq --arg event "$event" --argjson max "$max_agent_runs" \
        --argjson ordinal "$next_ordinal" '
            .agent_run_budget = (.agent_run_budget // {
                max_agent_runs: $max,
                reservations: []
            }) |
            .agent_run_budget.reservations += [{event: $event, ordinal: $ordinal}]
        ' "$state" >"$tmp"
    mv "$tmp" "$state"
    printf 'reserved agent-run %s %s/%s\n' "$event" "$next_ordinal" "$max_agent_runs"
    ;;
reserve)
    [ -n "$action" ] && [ -n "$expected_head" ] && [ -n "$writer" ] || usage
    case "$action" in assembly | push | comment) ;; *) die "action $action is not replayable" ;; esac
    [ "$writer" = "feature-owner" ] || die "only the feature-branch owner may reserve $action"
    assembly_plan_json="null"
    if [ "$action" = "assembly" ]; then
        [ -n "$assembly_plan" ] && [ -f "$assembly_plan" ] ||
            die "assembly reservation requires an assembly plan file"
        jq -e '
            type == "object" and
            (.integrated_lanes | type == "array" and all(.[]; type == "string" and length > 0)) and
            (.discarded_lanes | type == "array" and all(.[]; type == "string" and length > 0)) and
            ((.integrated_lanes + .discarded_lanes) | length > 0) and
            ((.integrated_lanes | unique | length) == (.integrated_lanes | length)) and
            ((.discarded_lanes | unique | length) == (.discarded_lanes | length)) and
            (. as $plan |
              [$plan.integrated_lanes[] |
                select(. as $lane | ($plan.discarded_lanes | index($lane)) != null)] |
              length == 0)
        ' "$assembly_plan" >/dev/null || die "assembly plan must account for unique, disjoint lane identities"
        assembly_plan_json="$(jq -c '{integrated_lanes, discarded_lanes}' "$assembly_plan")"
    elif [ -n "$assembly_plan" ]; then
        die "assembly plan is permitted only for an assembly reservation"
    fi
    if [ "$action" = "comment" ]; then
        [[ "$trusted_actor_id" =~ ^[1-9][0-9]*$ ]] || die "comment reservation requires a trusted actor id"
        [ -n "$marker" ] || die "comment reservation requires a deterministic marker"
        [[ "$payload_digest" =~ ^[0-9a-f]{64}$ ]] || die "comment reservation requires a SHA-256 payload digest"
        [[ "$evidence_role" =~ ^[a-z][a-z0-9-]*$ ]] ||
            die "comment reservation requires an evidence role"
        [[ "$evidence_finder" =~ ^[a-z0-9][a-z0-9-]*$ ]] ||
            die "comment reservation requires an evidence finder"
        governing_revision="$(resolve_governing_registry_revision)"
        registry_json="$(git -C "$repo_root" show "${governing_revision}:agent-registry.json" 2>/dev/null)" ||
            die "could not read agent-registry.json at governing revision ${governing_revision}"
        jq -e --argjson actor "$trusted_actor_id" '
            (.trusted_orchestrator_actor_ids // []) as $ids |
            ($ids | type == "array" and length > 0) and
            all($ids[]; type == "number" and floor == . and . > 0) and
            ($ids | index($actor) != null)
        ' <<<"$registry_json" >/dev/null ||
            die "comment actor id is not trusted by the governing registry revision"
    fi
    if [ ! -e "$state" ]; then
        init_tmp="${state}.tmp.init.$$"
        jq -n '{version: 1, cursor: null, actions: []}' >"$init_tmp"
        mv "$init_tmp" "$state"
    fi
    if [ "$action" = "comment" ]; then
        # Exact comment re-arms recover a crash after reserve/post/register.
        # Recheck today's allowlist above before adopting yesterday's intent;
        # a changed actor/marker/body/head never gets a second reservation.
        existing="$(jq -c --arg event "$event" '.actions[] | select(.event == $event)' "$state")"
        if [ -n "$existing" ]; then
            # Ordinary/concurrent callers retain the duplicate-event refusal.
            # Only the holder of the complete publication transaction lock
            # may re-arm. The inherited descriptor must reference that exact
            # canonical file and own its existing exclusive advisory lock: a freshly
            # opened descriptor in a competitor cannot acquire it.
            [[ "$comment_lock_fd" =~ ^[1-9][0-9]*$ ]] && [ "$comment_lock_fd" -ge 3 ] || die "duplicate event; comment re-arm requires the publication lock holder"
            publication_lock="$(dirname "$state")/post-evidence.lock"
            # fcntl's standard-library implementation is available on both
            # Linux and macOS; no platform-specific lock utility is required.
            python3 - "$publication_lock" "$comment_lock_fd" <<'PY' || die "duplicate event; caller does not own the canonical publication lock"
import fcntl, os, sys
path, fd = sys.argv[1], int(sys.argv[2])
actual, expected = os.fstat(fd), os.stat(path)
if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
    sys.exit(2)
probe = os.open(path, os.O_RDWR)
try:
    try:
        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        sys.exit(2)  # There was no existing lock to authenticate.
finally:
    os.close(probe)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(2)  # Another open file description owns the lock.
PY
            jq -e --arg head "$expected_head" --arg actor "$trusted_actor_id" \
                --arg run "$run_id" --arg role "$evidence_role" --arg finder "$evidence_finder" \
                --arg marker "$marker" --arg digest "$payload_digest" '
                .action == "comment" and .expected_head == $head and
                (.state == "reserved" or .state == "adopted") and
                .comment_auth.trusted_actor_id == $actor and .comment_auth.run_id == $run and
                .comment_auth.role == $role and .comment_auth.finder == $finder and
                .comment_auth.marker == $marker and .comment_auth.payload_digest == $digest
            ' <<<"$existing" >/dev/null || die "comment re-arm conflicts with reservation bindings"
            printf 'reserved %s\n' "$event"
            exit 0
        fi
        jq -e --arg marker "$marker" '
            [.actions[] | select(
                .action == "comment" and .comment_auth.marker == $marker
            )] | length == 0
        ' "$state" >/dev/null || die "duplicate comment reservation identity"
    fi
    jq -e --arg event "$event" --arg action "$action" --arg head "$expected_head" '
            (.version == 1) and
            ([.actions[] | select(.event == $event)] | length == 0) and
            ($head | test("^[0-9a-f]{40}$")) and
            ($action != "merge")
        ' "$state" >/dev/null || die "invalid state, duplicate event, or invalid reservation"
    tmp="${state}.tmp.$$"
    jq --arg event "$event" --arg action "$action" --arg head "$expected_head" \
        --arg actor "$trusted_actor_id" --arg registry_revision "${governing_revision:-}" \
        --arg marker "$marker" --arg digest "$payload_digest" \
        --arg run "$run_id" --arg role "$evidence_role" --arg finder "$evidence_finder" \
        --argjson assembly_plan "$assembly_plan_json" '
            .actions += [{
                event: $event,
                action: $action,
                expected_head: $head,
                state: "reserved",
                assembly_plan: (if $action == "assembly" then $assembly_plan else null end),
                comment_auth: (if $action == "comment" then {
                    trusted_actor_id: $actor,
                    registry_revision: $registry_revision,
                    run_id: $run,
                    role: $role,
                    finder: $finder,
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
    expected_action="$(jq -r '.action' <<<"$reservation")"
    case "$reservation_state" in
    adopted)
        if [ "$expected_action" = "comment" ]; then
            # An adopted ID is durable, but its GitHub content remains mutable.
            # Revalidate the supplied complete set instead of certifying edits.
            :
        else
            # A stale re-arm must adopt the durable result, not retry a write
            # already known to have landed.
            printf 'adopt %s\n' "$event"
            exit 0
        fi
        ;;
    reserved) ;;
    *) die "reservation $event is not actionable" ;;
    esac
    status="$(jq -r '.status // empty' "$observed")"
    expected_head_value="$(jq -r '.expected_head' <<<"$reservation")"
    comment_id=""
    if [ "$expected_action" = "comment" ] && { [ "$status" = "landed" ] || [ "$status" = "absent" ]; }; then
        expected_actor="$(jq -r '.comment_auth.trusted_actor_id' <<<"$reservation")"
        expected_run="$(jq -r '.comment_auth.run_id' <<<"$reservation")"
        expected_role="$(jq -r '.comment_auth.role' <<<"$reservation")"
        expected_finder="$(jq -r '.comment_auth.finder' <<<"$reservation")"
        expected_marker="$(jq -r '.comment_auth.marker' <<<"$reservation")"
        expected_digest="$(jq -r '.comment_auth.payload_digest' <<<"$reservation")"
        jq -e '
            (.comments | type == "array") and all(.comments[];
                type == "object" and
                (.comment_id | type == "number" and . > 0 and floor == .) and
                ((.actor_id | type == "number") or (.actor_id | type == "string")) and
                (.run_id | type == "string" and length > 0) and
                (.head | type == "string" and test("^[0-9a-f]{40}$")) and
                (.role | type == "string" and test("^[a-z][a-z0-9-]*$")) and
                (.finder | type == "string" and test("^[a-z0-9][a-z0-9-]*$")) and
                (.marker | type == "string" and length > 0) and
                (.payload_digest | type == "string" and test("^[0-9a-f]{64}$")) and
                (.body | type == "string"))
        ' "$observed" >/dev/null ||
            die "comment observation must contain a valid complete comments candidate set"
        candidates="$(jq -c --arg actor "$expected_actor" --arg marker "$expected_marker" '
            [.comments[] | select(
                (.actor_id | tostring) == $actor and .marker == $marker
            )] | sort_by(.comment_id)[]
        ' "$observed")"
        while IFS= read -r candidate; do
            [ -n "$candidate" ] || continue
            jq -e --arg run "$expected_run" --arg head "$expected_head_value" \
                --arg role "$expected_role" --arg finder "$expected_finder" \
                --arg marker "$expected_marker" --arg digest "$expected_digest" '
                    .run_id == $run and .head == $head and .role == $role and
                    .finder == $finder and .marker == $marker and
                    .payload_digest == $digest and (.body | contains($marker))
                ' <<<"$candidate" >/dev/null ||
                die "comment candidate conflicts with reservation bindings"
            actual_digest="$(jq -j '.body' <<<"$candidate" | sha256_stream)"
            [ "$actual_digest" = "$expected_digest" ] ||
                die "comment candidate body digest conflicts with reservation"
            if [ -z "$comment_id" ]; then
                comment_id="$(jq -r '.comment_id' <<<"$candidate")"
            fi
        done <<<"$candidates"
        if [ "$status" = "absent" ] && [ -n "$comment_id" ]; then
            die "absent comment observation contains an authenticated match"
        fi
    fi
    case "$status" in
    landed | absent)
        # A retry is authorization to perform the reserved external action,
        # so it owes the same ordering proof as adoption. Authorizing a later
        # absent action while an earlier reservation is still unresolved
        # would let the write happen out of order and discover the violation
        # only after the side effect already exists.
        jq -e --arg event "$event" '
            . as $state |
            [$state.actions[].event] | index($event) as $index |
            [$state.actions[0:$index][] | select(.state != "adopted")] | length == 0
        ' "$state" >/dev/null || die "cannot reconcile $event out of reservation order"
        ;;
    esac
    if [ "$reservation_state" = "adopted" ] && [ "$expected_action" = "comment" ]; then
        [ "$status" = "landed" ] &&
            [ "$comment_id" = "$(jq -r '.postcondition.comment_id' <<<"$reservation")" ] ||
            die "adopted comment postcondition changed or disappeared"
        printf 'adopt %s\n' "$event"
        exit 0
    fi
    case "$status" in
    landed)
        jq -e --arg event "$event" --arg action "$expected_action" --arg head "$expected_head_value" '
                    .event == $event and .action == $action and .head == $head
                ' "$observed" >/dev/null || die "landed postcondition does not match reservation"
        if [ "$expected_action" = "comment" ]; then
            [ -n "$comment_id" ] || die "comment postcondition is not authenticated"
        elif [ "$expected_action" = "assembly" ]; then
            expected_plan="$(jq -c '.assembly_plan' <<<"$reservation")"
            jq -e --argjson plan "$expected_plan" '
                .integrated_lanes == $plan.integrated_lanes and
                .discarded_lanes == $plan.discarded_lanes
            ' "$observed" >/dev/null || die "assembled lane selection does not match reservation"
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
