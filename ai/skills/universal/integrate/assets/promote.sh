#!/usr/bin/env bash
# Promote a recorded run through one immediate gate/mutation/readback transaction.
# readiness-gate.sh remains read-only. No retry of the ready mutation is allowed.
# Exit codes: 0 promoted and recorded; 10 gate failed (no mutation);
# 11 gate indeterminate/invalid inputs (no mutation); 12 already non-draft
# (no mutation or record; caller audits); 13 mismatch/writer refusal, undone;
# 14 remote state unknown after one undo; 15 ready command failed, undone.
# An exit-0 writer warning about incomplete active-pointer retirement is success.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
support_dir="$(cd "$script_dir/../../dev-flow-support/assets" && pwd -P)"
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
an audit of the existing non-draft PR; it never writes a new promotion record.
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
        exit 12
    fi
    [ "$rc" -ne 1 ] || exit 10
    exit 11
fi
gate_fingerprint="$(jq -er --arg head "$head" '
  select(.status == "pass" and .condition == "ready" and .head == $head)
  | .fingerprint | select(type == "string" and length > 0)' <<<"$verdict")" || exit 11

# Retry only failed/malformed reads. A valid mismatch is evidence, never lag.
read_scalars() {
    local attempt value
    for attempt in 1 2 3; do
        if value="$(gh pr view "$pr" --repo "$repo" --json state,isDraft,headRefOid)" &&
            jq -e 'type == "object" and (.state | IN("OPEN", "CLOSED", "MERGED")) and
              (.isDraft | type == "boolean") and (.headRefOid | type == "string" and test("^[0-9a-f]{40}$"))' <<<"$value" >/dev/null; then
            printf '%s\n' "$value"
            return 0
        fi
        [ "$attempt" -eq 3 ] || sleep 1
    done
    return 1
}
undo() {
    local snapshot attempt
    # Even a failed mutation may have landed; issue exactly one inverse write.
    gh pr ready --undo "$pr" --repo "$repo" >&2 || true
    for attempt in 1 2 3; do
        if snapshot="$(read_scalars)" && jq -e '.state == "OPEN" and .isDraft == true' <<<"$snapshot" >/dev/null; then
            echo "BLOCKER: $reason; confirmed draft on $(jq -r .headRefOid <<<"$snapshot")" >&2
            exit "$undo_code"
        fi
        [ "$attempt" -eq 3 ] || sleep 1
    done
    echo "BLOCKER: $reason; remote state indeterminate after one undo; no second undo" >&2
    exit 14
}
ready_rc=0
gh pr ready "$pr" --repo "$repo" >&2 || ready_rc=$?
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
promoted_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || undo
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
