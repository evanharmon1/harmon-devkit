#!/usr/bin/env bash
# One run-owner cycle. Compose the existing authorities; never adjudicate them.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
support_dir="$(cd "$script_dir/../../dev-flow-support/assets" && pwd -P)"
checker="$script_dir/check-codex-cloud-review.sh"
broker="$script_dir/gh-write-broker.sh"
repo= pr= head= slate= session= owner_token= run_id=
parent_digest=
repo_dir=.
remediation=0
attempt=1
timeout_min=15
wait_seconds=3600
interval_seconds=30

refuse() {
    printf 'drive-codex-cycle: %s\n' "$*" >&2
    exit 2
}
usage() {
    cat <<'HELP'
Usage: drive-codex-cycle.sh --repo OWNER/REPO --pr N --head SHA
  --slate ID --session NAME --owner-token TOKEN --run-id ID
  [--repo-dir DIR] [--remediation N] [--attempt 1|2] [--timeout-min 10..15]
  [--wait-seconds N] [--interval-seconds N]
  [--parent-authority-digest SHA256]

Run in the target clone (or name it with --repo-dir). Control paths derive from
its common Git directory: dev-flow-v2/runs/RUN and integrate-codex/OWNER/REPO/N.json.
The run's resolved policy supplies trigger timing, carry and integration limits.
Carry is attempted first unless its policy is fresh. Otherwise wait for CI when
required, reserve and capture, broker-trigger, check to a bounded observation,
then capture attach.
No automatic retry trigger: exit 12 returns control to the owner, who may invoke
--attempt 2 after retaining/receipting the first request. Resume reserved or
attached same-head requests without reserving or triggering them again.
The optional immutable parent selector applies to the starting capture. A retry
reserve consumes its cycle-origin selector; attach then resolves the newly
retained reservation. Attached/terminal resumes use the selector for attach.
First-attempt reserve does not accept a parent selector.

Exit: checker codes (0 clean, 10 findings, 12 retry, 13 expired, 14 closed,
15 quota, 19 stale, 2 indeterminate); failed steps retain their nonzero status.
Only pending (11) and transient reads (16) are polled. Expiry returns 13 without
an attach capture. A successful cycle capture does not attest PR readiness.
HELP
}
while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help)
        usage
        exit 0
        ;;
    esac
    [ "$#" -ge 2 ] || refuse "missing value for $1"
    case "$1" in
    --repo) repo=$2 ;;
    --pr) pr=$2 ;;
    --head) head=$2 ;;
    --slate) slate=$2 ;;
    --session) session=$2 ;;
    --owner-token) owner_token=$2 ;;
    --run-id) run_id=$2 ;;
    --parent-authority-digest)
        [[ "$2" =~ ^[0-9a-f]{64}$ ]] || refuse 'invalid --parent-authority-digest'
        parent_digest=$2
        ;;
    --repo-dir) repo_dir=$2 ;;
    --remediation) remediation=$2 ;;
    --attempt) attempt=$2 ;;
    --timeout-min) timeout_min=$2 ;;
    --wait-seconds) wait_seconds=$2 ;;
    --interval-seconds) interval_seconds=$2 ;;
    *) refuse "unknown option $1" ;;
    esac
    shift 2
done
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || refuse 'invalid --repo'
[[ "$pr" =~ ^[1-9][0-9]*$ ]] || refuse 'invalid --pr'
[[ "$head" =~ ^[0-9a-f]{40}$ ]] || refuse 'invalid --head'
for value in "$slate" "$session" "$run_id"; do
    [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || refuse 'invalid run identity'
done
[ -n "$owner_token" ] || refuse '--owner-token is required'
[[ "$remediation" =~ ^(0|[1-9][0-9]*)$ ]] || refuse 'invalid --remediation'
case "$attempt" in 1 | 2) ;; *) refuse 'invalid --attempt' ;; esac
case "$timeout_min" in 10 | 11 | 12 | 13 | 14 | 15) ;; *) refuse 'invalid --timeout-min' ;; esac
for value in "$wait_seconds" "$interval_seconds"; do
    [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$value" -le 86400 ] || refuse 'durations must be 1..86400 seconds'
done
cd "$repo_dir"
repo_dir="$(git rev-parse --show-toplevel)"
common="$(git rev-parse --git-common-dir)"
common="$(cd "$common" && pwd -P)"
record="$common/dev-flow-v2/runs/$run_id"
state="$common/integrate-codex/$repo/$pr.json"
# Authenticate before checker mutations; capture repeats authentication when it
# writes. argv[1] names this driver so importing the writer does not run its CLI.
node --input-type=module -e '
import { pathToFileURL } from "node:url";
const [, , writer, root, slate, session, ownerToken, runId] = process.argv;
const { assertRunOwner, checkSlateLock } = await import(pathToFileURL(writer).href);
assertRunOwner(root, slate, runId);
checkSlateLock({ root, slate, session, ownerToken });
' "$script_dir/drive-codex-cycle.sh" "$support_dir/run-record.mjs" \
    "$common/dev-flow-v2" "$slate" "$session" "$owner_token" "$run_id"
# Validate policy input before any transition; neither a caller-supplied record
# nor policy is accepted.
review_trigger="$(jq -er '.stages.integration.review_trigger // "after-ci"' "$record/policy.json")"
integration_cap="$(jq -er '.rounds.integration | select(type == "number" and . > 0 and . == floor)' "$record/policy.json")"
exempt_cap="$(jq -er '.rounds.integration_exempt | select(type == "number" and . >= 0 and . == floor)' "$record/policy.json")"
carry_policy="$(jq -er '
  [.stages.integration.finder[]? | select(.id == "codex-cloud")] as $entries |
  if ($entries | length) > 1 then error("duplicate codex-cloud policy")
  else ($entries[0].carry // "identity") end |
  select(. == "identity" or . == "identity-or-incremental" or . == "fresh")
' "$record/policy.json")"
timing="$("$checker" trigger-timing --review-trigger "$review_trigger" --remediation "$remediation")"
order="$(jq -er '.order | select(. == "after-ci" or . == "with-push")' <<<"$timing")"
timeout_bin="$(command -v timeout || command -v gtimeout)" || refuse 'GNU timeout (timeout or gtimeout) is required'
# shellcheck source=gh-write-broker.sh
. "$broker"
deadline=$(($(date -u +%s) + wait_seconds))

capture() {
    local parent_args=()
    [ -z "$parent_digest" ] || parent_args=(--parent-authority-digest "$parent_digest")
    node "$support_dir/run-record.mjs" integration-review-capture \
        --slate "$slate" --session "$session" --owner-token "$owner_token" \
        --run-id "$run_id" --state "$state" --authority-kind "$1" --repo-dir "$repo_dir" \
        ${parent_args[@]+"${parent_args[@]}"}
}
assert_head() {
    local live budget
    budget=$((deadline - $(date -u +%s)))
    [ "$budget" -gt 0 ] || {
        printf 'drive-codex-cycle: wait budget expired; no terminal capture\n' >&2
        exit 13
    }
    [ "$budget" -le 60 ] || budget=60
    live="$(bounded_gh_call "$timeout_bin" "$budget" gh pr view "$pr" --repo "$repo" --json state,isDraft,headRefOid)"
    jq -e --arg head "$head" '.state == "OPEN" and .isDraft == true and .headRefOid == $head' \
        <<<"$live" >/dev/null || refuse 'PR is not an open draft on the captured head'
}

# An initial cycle has no state to carry. For existing state the checker owns
# proof and error classification: only 17 permits the ordinary path.
if [ "$carry_policy" != fresh ] && { [ -e "$state" ] || [ -L "$state" ]; }; then
    if "$checker" carry --state "$state" --head "$head" --run-id "$run_id" --repo-dir "$repo_dir"; then
        capture carry
        "$checker" check --state "$state" --run-id "$run_id" --repo-dir "$repo_dir" --actor-id 199175422
        exit 0
    else
        rc=$?
        [ "$rc" -eq 17 ] || exit "$rc"
    fi
fi
assert_head
phase=new
if [ -f "$state" ] && jq -e --arg head "$head" --arg run "$run_id" \
    --argjson attempt "$attempt" '.head == $head and .run_id == $run and .attempt == $attempt' "$state" >/dev/null; then
    phase="$(jq -er '.phase' "$state")"
    case "$phase" in
    reserved | attached | terminal) ;;
    released)
        [ "$attempt" = 1 ] || refuse 'a released reservation must restart at attempt 1'
        phase=new
        ;;
    *) refuse 'unrecognized resumable phase' ;;
    esac
fi
if [ "$phase" = new ]; then
    case "$order" in
    after-ci)
        "$support_dir/settle-wait.sh" checks --repo "$repo" --pr "$pr" --head "$head" \
            --timeout-seconds "$wait_seconds" --interval-seconds "$interval_seconds"
        # CI owns its wait budget. Begin a fresh bounded setup phase rather
        # than charging that elapsed time to the upcoming review.
        deadline=$(($(date -u +%s) + wait_seconds))
        ;;
    with-push) ;;
    *) refuse 'invalid trigger order' ;;
    esac
    "$checker" reserve --state "$state" --repo "$repo" --pr "$pr" --head "$head" \
        --attempt "$attempt" --run-id "$run_id" --record "$record" \
        --integration-cap "$integration_cap" --integration-exempt-cap "$exempt_cap" \
        --review-trigger "$review_trigger" --remediation "$remediation" --timeout-min "$timeout_min"
    phase=reserved
fi
assert_head
if [ "$phase" = reserved ]; then
    # A reserved resume also proves authority before posting. Attached state
    # cannot be recaptured as reserve; attach capture verifies its retained parent.
    capture reserve
    # Restructure review-r2-codex-verification-1: the retry's cycle-origin
    # parent belongs only to reserve. Attach selects the reservation just
    # retained here; a resume that skipped reserve keeps its attach selector.
    parent_digest=
    assert_head
    "$broker" trigger --repo "$repo" --pr "$pr" --common-state
fi

# Restructure challenge-r3-codex-adversarial-1: the review observation has its
# own budget, independent of CI settlement and trigger setup. Head reads still
# use only the time remaining in their current phase.
deadline=$(($(date -u +%s) + wait_seconds))
while :; do
    assert_head
    if "$checker" check --state "$state" --run-id "$run_id" --repo-dir "$repo_dir" --actor-id 199175422 --timeout-min "$timeout_min"; then
        rc=0
    else
        rc=$?
    fi
    case "$rc" in
    0 | 10 | 12 | 13 | 15)
        assert_head
        capture attach
        exit "$rc"
        ;;
    11 | 16) ;;
    *) exit "$rc" ;;
    esac
    remaining=$((deadline - $(date -u +%s)))
    [ "$remaining" -gt 0 ] || {
        printf 'drive-codex-cycle: polling bound expired; no terminal capture\n' >&2
        exit 13
    }
    delay=$interval_seconds
    [ "$delay" -le "$remaining" ] || delay=$remaining
    sleep "$delay"
done
