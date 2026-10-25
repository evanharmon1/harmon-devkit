#!/usr/bin/env bash
# Promote a recorded run through one immediate gate/mutation/readback transaction.
# readiness-gate.sh remains read-only. No retry of the ready mutation is allowed.
# Exit codes: 0 promoted and recorded; 10 gate failed (no mutation);
# 11 indeterminate/invalid inputs/missing sibling (no mutation);
# 12 already non-draft and a promotion is recorded for the requested head;
# no mutation, caller audits the current head. 13 mismatch/writer refusal, undone;
# 14 remote state unknown after one undo; 15 ready command failed, undone.
# 16 promotion precheck refused before mutation; 17 unrecorded non-draft promotion
# (no mutation; caller uses unexplained-promotion reconciliation).
# After mutation: at most ten network reads/writes (fingerprint contributes five):
# 10 × 60s + 10 × 1s kill grace + two writer mutex waits × 15s = 640s.
# The pre-mutation gate uses its own per-read limits. Callers must allow at least
# 640s after it completes, plus gate/runtime overhead in the tool timeout.
# A run killed before exit is exit 14
# (remote state unknown), never a confirmed handoff. No read retries.
# An exit-0 writer warning about incomplete active-pointer retirement is success.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if ! support_dir="$(cd "$script_dir/../../dev-flow-support/assets" 2>/dev/null && pwd -P)" ||
    [ ! -r "$support_dir/run-record.mjs" ]; then
    echo 'BLOCKER: missing sibling dev-flow-support/assets/run-record.mjs; indeterminate' >&2
    exit 11
fi
timeout_bin=
if command -v timeout >/dev/null 2>&1; then
    timeout_bin=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=gtimeout
else
    echo 'BLOCKER: timeout (or gtimeout) is required to bound GitHub calls' >&2
    exit 11
fi
run_gh() {
    "$timeout_bin" -k 1 60 gh "$@"
}
gate="$script_dir/readiness-gate.sh"
repo= pr= head= record= slate= session= owner_token= run_id=
gate_args=()
usage() {
    cat >&2 <<'HELP'
Usage: promote.sh --repo OWNER/REPO --pr N --head SHA --record DIR
  --slate ID --session NAME --owner-token TOKEN --run-id ID
  --integration-cap N --remediation-cap N [--integration-exempt-cap N]
  [--integrator-result FILE] [--codex-recheck FILE] [--codex-repo-dir DIR]
  [--allow-edited-root ID]...
All gate options are forwarded unchanged to readiness-gate.sh check. The record
must be the canonical run directory in the current checkout's common Git dir.
Freeze the PR body and review content throughout this command. Exit 12 requires
a promoted check of an already recorded non-draft PR. Exit 17 instead routes an
unrecorded non-draft promotion to the unexplained-promotion procedure. Neither
exit writes a new promotion record.
HELP
    exit 11
}
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
    --slate) slate=$2 ;;
    --session) session=$2 ;;
    --owner-token) owner_token=$2 ;;
    --run-id) run_id=$2 ;;
    --repo)
        repo=$2
        gate_args+=("$1" "$2")
        ;;
    --pr)
        pr=$2
        gate_args+=("$1" "$2")
        ;;
    --head)
        head=$2
        gate_args+=("$1" "$2")
        ;;
    --record)
        record=$2
        gate_args+=("$1" "$2")
        ;;
    --integration-cap | --remediation-cap | --integration-exempt-cap | --integrator-result | --codex-recheck | --codex-repo-dir | --allow-edited-root)
        gate_args+=("$1" "$2")
        ;;
    *) usage ;;
    esac
    shift 2
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && "$pr" =~ ^[1-9][0-9]*$ && "$head" =~ ^[0-9a-f]{40}$ ]] || usage
[ -n "$record" ] && [ -n "$slate" ] && [ -n "$session" ] && [ -n "$owner_token" ] || usage
[[ "$run_id" =~ ^[A-Za-z0-9_-]+$ ]] || usage
# Bind the gate's record to the record the writer will update; no second gate.
common="$(git rev-parse --path-format=absolute --git-common-dir)" || exit 11
canonical="$(cd "$common/dev-flow-v2/runs/$run_id" && pwd -P)" || exit 11
record="$(cd "$record" && pwd -P)" || exit 11
if [ "$record" != "$canonical" ] || ! jq -e --arg id "$run_id" '.run_id == $id' "$record/run.json" >/dev/null; then
    echo 'BLOCKER: gate record and writer run identity differ' >&2
    exit 11
fi

rc=0
verdict="$("$gate" check "${gate_args[@]}")" || rc=$?
printf '%s\n' "$verdict"
if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 1 ] && jq -e '.condition == "pr-not-draft"' <<<"$verdict" >/dev/null 2>&1; then
        if jq -e --arg head "$head" '.promotion.head == $head' "$record/run.json" >/dev/null; then
            exit 12
        fi
        echo 'BLOCKER: unrecorded promotion; use the unexplained-promotion procedure' >&2
        exit 17
    fi
    [ "$rc" -ne 1 ] || exit 10
    exit 11
fi
gate_fingerprint="$(jq -er --arg head "$head" '
  select(.status == "pass" and .condition == "ready" and .head == $head)
  | .fingerprint | select(type == "string" and length > 0)' <<<"$verdict")" || exit 11

# Each read is attempted once; failed or malformed evidence routes to undo.
read_scalars() {
    local value
    value="$(run_gh pr view "$pr" --repo "$repo" --json state,isDraft,headRefOid)" || return 1
    jq -e 'type == "object" and (.state | IN("OPEN", "CLOSED", "MERGED")) and
      (.isDraft | type == "boolean") and (.headRefOid | type == "string" and test("^[0-9a-f]{40}$"))' <<<"$value" >/dev/null || return 1
    printf '%s\n' "$value"
}
undo() {
    local snapshot
    # Even a failed mutation may have landed; issue exactly one inverse write.
    run_gh pr ready --undo "$pr" --repo "$repo" >&2 || true
    if snapshot="$(read_scalars)" && jq -e '.state == "OPEN" and .isDraft == true' <<<"$snapshot" >/dev/null; then
        echo "BLOCKER: $reason; confirmed draft on $(jq -r .headRefOid <<<"$snapshot")" >&2
        exit "$undo_code"
    fi
    echo "BLOCKER: $reason; remote state indeterminate after one undo; no second undo" >&2
    exit 14
}
# Rehearse the exact writer mutation before notifying reviewers. The real
# writer repeats every check after the remote mutation; this read-only check
# is only a pre-mutation refusal boundary.
promoted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || exit 11
if ! node "$support_dir/run-record.mjs" promote --check \
    --slate "$slate" --session "$session" --owner-token "$owner_token" --run-id "$run_id" \
    --head "$head" --fingerprint "$gate_fingerprint" --at "$promoted_at"; then
    echo 'BLOCKER: promotion precheck refused; no promotion attempted' >&2
    exit 16
fi
ready_rc=0
run_gh pr ready "$pr" --repo "$repo" >&2 || ready_rc=$?
undo_code=13
reason='post-promotion readback mismatch or unknown'
if [ "$ready_rc" -ne 0 ]; then
    reason="ready command failed (exit $ready_rc)"
    undo_code=15
fi
scalars="$(read_scalars)" || undo
if ! jq -e --arg head "$head" '.state == "OPEN" and .isDraft == false and .headRefOid == $head' <<<"$scalars" >/dev/null; then
    undo
fi
fingerprint="$("$gate" fingerprint --repo "$repo" --pr "$pr")" || undo
if ! jq -e --arg fp "$gate_fingerprint" '.status == "fingerprint" and .fingerprint == $fp' <<<"$fingerprint" >/dev/null; then
    undo
fi
# This read MUST follow the fingerprint, which deliberately excludes the head.
scalars="$(read_scalars)" || undo
jq -e --arg head "$head" '.state == "OPEN" and .isDraft == false and .headRefOid == $head' <<<"$scalars" >/dev/null || undo
if [ "$ready_rc" -ne 0 ]; then
    reason="ready command failed (exit $ready_rc)"
    undo_code=15
    undo
fi
if ! node "$support_dir/run-record.mjs" promote \
    --slate "$slate" --session "$session" --owner-token "$owner_token" --run-id "$run_id" \
    --head "$head" --fingerprint "$gate_fingerprint" --at "$promoted_at"; then
    # Accept only an exact lost-response success, including the submitted time.
    if ! jq -e --arg head "$head" --arg fp "$gate_fingerprint" --arg at "$promoted_at" '
      .outcome == "ready-for-review" and .promotion ==
      {head:$head,gate_fingerprint:$fp,promoted_at:$at}' "$record/run.json" >/dev/null; then
        reason='promotion record write refused'
        undo
    fi
fi
printf 'Promoted and recorded %s#%s at %s\n' "$repo" "$pr" "$head"
