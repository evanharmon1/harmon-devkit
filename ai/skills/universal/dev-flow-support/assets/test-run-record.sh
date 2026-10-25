#!/usr/bin/env bash
# test-run-record.sh — behavioral tests for run-record.mjs, the dev-flow v2
# run-record writer and slate lock (harmon-devkit#1296).
#
# Every case runs inside a temporary fixture repository: the writer resolves
# its state root from the current directory's Git common directory, and the
# Git environment is scrubbed first so a hook-exported GIT_DIR can never point
# it at a real clone's dev-flow-v2 tree.
#
# Run by task test:run-record (part of task test); scripts/test-skills.sh only
# checks that wiring.
set -euo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
writer="$asset_dir/run-record.mjs"
monitor="$asset_dir/../../orchestrate/assets/dev-flow-monitor.sh"

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

pass() {
    echo "  PASS: $1"
    return 0
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v git >/dev/null 2>&1 || fail "git is required"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/run-record.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

repo="$tmp/repo"
git init -q -b main "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf '{"trusted_orchestrator_actor_ids": [12345]}\n' >"$repo/agent-registry.json"
git -C "$repo" add agent-registry.json
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m registry
state="$repo/.git/dev-flow-v2"

# The state root must be this fixture's, never the clone running the test.
resolved="$(cd "$repo" && git rev-parse --path-format=absolute --git-common-dir)"
[ "$resolved" = "$repo/.git" ] || fail "fixture common dir resolved to $resolved"

new_run() {
    local run_id="$1" branch active_state registry_revision
    mkdir -p "$state/runs/$run_id"
    jq -n --arg id "$run_id" '{
      schema: 2, run_id: $id, initiated_by: "human",
      started_at: "2026-01-01T00:00:00Z",
      stage_transitions: [{stage: "kickoff", entered_at: "2026-01-01T00:00:00Z"}],
      interventions: [], outcome: null, pr: null,
      evidence_comments: [], evidence_registrations: [], pr_bindings: [],
      outcome_transitions: [], settlements: [], promotion: null, receipts: []
    }' >"$state/runs/$run_id/run.json"
    branch="fixture-$run_id"
    active_state="$("$monitor" active-path --branch "$branch" --repo-root "$repo")"
    registry_revision="$(git -C "$repo" rev-parse HEAD)"
    "$monitor" activate --active-state "$active_state" --run-id "$run_id" --branch "$branch" \
        --expected-predecessor absent --expected-generation 0 --registry-revision "$registry_revision" \
        --writer feature-owner --repo-root "$repo" >/dev/null
}

# Capture acquisition stdout; never recover tokens from status or the lock file.
token_for() { cat "$tmp/token-$1" 2>/dev/null || true; }
pointer_for_run() { "$monitor" active-path --branch "fixture-$1" --repo-root "$repo"; }
acquire() {
    local slate="$1" session="$2"
    shift 2
    (cd "$repo" && RUN_RECORD_OWNER_TOKEN="$(token_for "$slate")" node "$writer" lock acquire --slate "$slate" --session "$session" "$@") >"$tmp/new-token"
    if [ -s "$tmp/new-token" ]; then cp "$tmp/new-token" "$tmp/token-$slate"; fi
}

# rr SESSION ARGS... — run the writer as SESSION on slate "s1" from the fixture.
rr() {
    local session="$1"
    shift
    (cd "$repo" && RUN_RECORD_OWNER_TOKEN="$(token_for s1)" node "$writer" "$@" --slate s1 --session "$session")
}

expect_refused() {
    local label="$1" pattern="$2"
    shift 2
    local output rc=0
    output="$("$@" 2>&1)" || rc=$?
    [ "$rc" -eq 1 ] || fail "$label: expected refusal (exit 1), got $rc: $output"
    grep -qF -- "$pattern" <<<"$output" || fail "$label: refusal did not mention '$pattern': $output"
}

no_candidates() {
    if [ -n "$(find "$state" -name '*.candidate.*')" ]; then
        fail "$1: a candidate file was left behind"
    fi
}

run="$state/runs/run-a/run.json"
new_run run-a

# write_plan SLATE ISSUE:RUN... — a schema-valid one-revision plan: each
# issue in its own wave with one lane (fence and candidate file f/<issue>.txt).
write_plan() {
    local slate="$1"
    shift
    mkdir -p "$state/slates/$slate"
    PLAN_SLATE="$slate" PLAN_LANES="$*" PLAN_WRITER="$writer" node --input-type=module -e '
      const { chainDigest } = await import(process.env.PLAN_WRITER)
      const entries = process.env.PLAN_LANES.split(" ").map((pair) => pair.split(":"))
      const policy = {
        rigor: "deep", rigor_source: "default",
        caps: { challenge: 1, review: 1, integration: 1, remediation: 1, min_rounds: 1, wall_clock_min: 60 },
        breadth: { max_agent_runs: 20, max_parallel_agents: 1 },
        strategy: "plan", strategy_source: "default",
        role_tiers: { orchestrator: "apex", implementer: "frontier", challenger: "apex", reviewer: "frontier", integrator: "economy" },
        operator_pins: [],
      }
      const plan = {
        base_sha: "a".repeat(40), policy,
        dispatcher: { kind: "interactive", parallel_cap: 1, foreman_max_parallel: null },
        issues: entries.map(([n]) => ({ number: Number(n), title: `Issue ${n}`, url: `https://example.test/issues/${n}`,
          verdict: "valid", candidate_files: [`f/${n}.txt`], blocked_by: [] })),
        overlaps: [],
        waves: entries.map(([n], i) => ({ number: i + 1, issues: [Number(n)] })),
        lanes: entries.map(([n, run], i) => ({ lane: `l${n}`, issue: Number(n), wave: i + 1, branch: `${n}-l`,
          run_id: run, fence: [{ path: `f/${n}.txt` }], expansions: [] })),
      }
      const at = "2026-01-01T00:00:00Z", reason = "fixture plan"
      const digest = chainDigest({ seq: 0, plan, at, reason }, "genesis")
      process.stdout.write(JSON.stringify({ schema: 1, slate_id: process.env.PLAN_SLATE,
        revisions: [{ seq: 0, prev_digest: "genesis", digest, at, reason, plan }] }, null, 2) + "\n")
    ' >"$state/slates/$slate/plan.json"
    node "$asset_dir/validate-result-schemas.mjs" plan "$state/slates/$slate/plan.json" >/dev/null ||
        fail "fixture plan for $slate is invalid"
}

lock_scope() {
    jq -r '.session + ":" + (.milestone|tostring) + ":" + (.issues|map(tostring)|join(","))' "$state/locks/$1.json"
}

# -- runs are written only as lanes of the locked slate's plan ---------------
expect_refused "write without a plan" "lock acquire" \
    rr alice transition --run-id run-a --stage claim --exit kicked --at 2026-01-01T00:01:00Z
pass "a run write for a slate with no plan is refused"

acquire s1 alice --milestone 7 --issues 11,12
token="$(token_for s1)"
[[ "$token" =~ ^[0-9a-f]{64}$ ]] || fail "acquire did not print one random token line"
digest="$(printf '%s' "$token" | sha256_file /dev/stdin)"
[ "$(jq -r '.owner_token_digest' "$state/locks/s1.json")" = "$digest" ] || fail "lock did not record the token digest"
[[ "$(cat "$state/locks/s1.json")" != *"$token"* ]] || fail "lock contains the plaintext token"
# A later, separate process receives the literal token, with no inherited shell state.
env -u RUN_RECORD_OWNER_TOKEN bash -c 'cd "$1" && node "$2" lock acquire --slate s1 --session alice --owner-token "$3"' _ "$repo" "$writer" "$token" >"$tmp/later-acquire.out"
[ ! -s "$tmp/later-acquire.out" ] || fail "later process unexpectedly minted another token"
cp "$state/locks/s1.json" "$tmp/valid-lock.json"
jq '.owner_token_digest = "invalid"' "$tmp/valid-lock.json" >"$state/locks/s1.json"
expect_refused "malformed digest" "slate lock is malformed" \
    rr alice transition --owner-token "$token" --run-id run-a --stage claim --exit k
cp "$tmp/valid-lock.json" "$state/locks/s1.json"
expect_refused "wrong token explains reuse before recovery" \
    "pass the token from the original lock acquire output with --owner-token; only if the token is truly lost" \
    rr alice transition --owner-token wrong --run-id run-a --stage claim --exit k
expect_refused "same-name wrong token" "owner token does not match" \
    rr alice transition --owner-token wrong --run-id run-a --stage claim --exit k
expect_refused "same-name missing token" "owner token does not match" \
    env -u RUN_RECORD_OWNER_TOKEN bash -c "cd '$repo' && node '$writer' lock acquire --slate s1 --session alice"
expect_refused "same-name release missing token" "owner token does not match" \
    env -u RUN_RECORD_OWNER_TOKEN bash -c "cd '$repo' && node '$writer' lock release --slate s1 --session alice"
status="$(cd "$repo" && node "$writer" lock status --slate s1)"
[[ "$status" != *"$token"* ]] || fail "status logged the owner token"
acquire s1 alice --milestone 7 --issues 11,12
[ ! -s "$tmp/new-token" ] || fail "reacquisition printed the token twice"
expect_refused "same-name write missing token" "owner token does not match" \
    rr alice transition --owner-token '' --run-id run-a --stage claim --exit k
expect_refused "same-name side-effect wrong token" "owner token does not match" \
    rr alice receipt --owner-token wrong --run-id run-a --pass missing.json
expect_refused "same-name release wrong token" "owner token does not match" \
    bash -c "cd '$repo' && node '$writer' lock release --slate s1 --session alice --owner-token wrong"
expect_refused "same-name overlapping slate" "issue(s) 11 are already locked" \
    bash -c "cd '$repo' && node '$writer' lock acquire --slate duplicate --session alice --issues 11"
pass "a tokenized lock refuses a same-name non-owner, and prints its token only once"
[ "$(lock_scope s1)" = "alice:7:11,12" ] || fail "lock does not record session, milestone and issue set"
pass "before a plan exists, the lock records the given milestone and issue set"

write_plan s1 11:run-a 12:run-b 13:run-c 14:run-d
cp "$run" "$tmp/run-a-unplanned.json"
expect_refused "plan outside the reservation" "names issue(s) 13, 14 outside the reserved scope" \
    rr alice transition --run-id run-a --stage claim --exit kicked --at 2026-01-01T00:01:00Z
cmp -s "$run" "$tmp/run-a-unplanned.json" || fail "a write under an unreserved plan changed run.json"
pass "a canonical plan naming issues outside the reserved scope refuses every write"

acquire s1 alice --issues 11,12,13,14
[ "$(lock_scope s1)" = "alice:7:11,12,13,14" ] || fail "widening the reservation did not record the new issue set"
pass "lock acquire --issues widens the reservation, keeping the recorded milestone"

new_run run-z
cp "$state/runs/run-z/run.json" "$tmp/run-z.json"
expect_refused "run outside the plan" "run run-z is not a lane in any revision of slate s1's plan" \
    rr alice transition --run-id run-z --stage claim --exit kicked --at 2026-01-01T00:01:00Z
cmp -s "$state/runs/run-z/run.json" "$tmp/run-z.json" || fail "a refused foreign run changed its record"
pass "a write naming a run that is not a lane of the locked slate's plan is refused, record unchanged"

expect_refused "reservation narrower than the plan" "names issue(s) 12, 13, 14 outside the reserved scope" \
    bash -c "cd '$repo' && node '$writer' lock acquire --slate s1 --session alice --owner-token \"$(token_for s1)\" --issues 11"
[ "$(lock_scope s1)" = "alice:7:11,12,13,14" ] || fail "a refused narrowing changed the lock"
pass "--issues that would leave plan issues unreserved are refused"

# -- attributable cap authorizations use the same validated writer ----------
instruction=$'Please run review round 2.
Keep the resolved cap unchanged.'
rr alice authorize-cap --run-id run-a --stage review --round 2 --actor maintainer \
    --instruction "$instruction" --at 2026-01-01T00:00:30Z >/dev/null
jq -e --arg instruction "$instruction" '.cap_authorizations == [{stage:"review",round:2,actor:"maintainer",instruction:$instruction,at:"2026-01-01T00:00:30Z"}]' "$run" >/dev/null ||
    fail "authorization did not retain all fields verbatim"
cp "$run" "$tmp/auth-before.json"
expect_refused "duplicate authorization" "duplicates cap_authorizations" \
    rr alice authorize-cap --run-id run-a --stage review --round 2 --actor maintainer --instruction again
cmp -s "$run" "$tmp/auth-before.json" || fail "duplicate authorization changed run.json"
for field in stage round actor instruction; do
    args=(--stage challenge --round 2 --actor maintainer --instruction authorize)
    case "$field" in
    stage) args[1]=remediation ;;
    round) args[3]=0 ;;
    actor) args[5]=' ' ;;
    instruction) args[7]=' ' ;;
    esac
    expect_refused "malformed authorization $field" "malformed entry" \
        rr alice authorize-cap --run-id run-a "${args[@]}"
    cmp -s "$run" "$tmp/auth-before.json" || fail "malformed $field changed run.json"
done
expect_refused "foreign-session authorization" "alice" \
    rr bob authorize-cap --run-id run-a --stage challenge --round 2 --actor maintainer --instruction authorize
cmp -s "$run" "$tmp/auth-before.json" || fail "foreign session changed run.json"
no_candidates authorization
pass "authorization preserves attribution, refuses duplicates/malformed entries and enforces session ownership atomically"

# -- transitions -----------------------------------------------------------
rr alice transition --run-id run-a --stage claim --exit "resolved" --at 2026-01-01T00:01:00Z >/dev/null
[ "$(jq -r '.stage_transitions | map(.stage) | join(",")' "$run")" = "kickoff,claim" ] || fail "claim transition not recorded"
[ "$(jq -r '.stage_transitions[0].exit' "$run")" = "resolved" ] || fail "previous stage exit not recorded"
[ "$(jq -c '.receipts' "$run")" = '[{"kind":"transition","stage":"claim","entered_at":"2026-01-01T00:01:00Z"}]' ] ||
    fail "transition did not append its matching receipt"
pass "transition appends the stage and its receipt, and closes the previous exit"

cp "$run" "$tmp/before.json"
expect_refused "edge outside the allowed set" "not a valid transition from claim" \
    rr alice transition --run-id run-a --stage security --exit claimed --at 2026-01-01T00:02:00Z
cmp -s "$run" "$tmp/before.json" || fail "a refused edge changed run.json"
no_candidates "refused edge"
pass "an edge outside the allowed set is refused and run.json is unchanged"

expect_refused "missing exit" "--exit is required" \
    rr alice transition --run-id run-a --stage implement --at 2026-01-01T00:02:00Z
pass "a transition that leaves a stage without an exit is refused"

# adjudicate RUN DISPOSITION — a challenge round-1 adjudication document.
adjudicate() {
    mkdir -p "$state/runs/$1/adjudications"
    jq -n --arg id "$1" --arg d "$2" '{
      schema: 2, run_id: $id, stage: "challenge", round: 1,
      reviewed_head: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      adjudications: [{finding_id: "challenge-r1-codex-adversarial-1", reviewer_priority: "P2",
        adjudicated_priority: "P2", disposition: $d, reason: "r", evidence: "e", override: null}]
    }' >"$state/runs/$1/adjudications/challenge-r1.json"
}

# walk RUN [DISPOSITION] — claim → … → integration, adjudicating challenge
# round 1 with DISPOSITION when one is given.
walk() {
    local run_id="$1" disposition="${2:-}" step
    for step in "implement:claimed" "verify:implemented" "challenge:verified"; do
        rr alice transition --run-id "$run_id" --stage "${step%%:*}" --exit "${step#*:}" --at 2026-01-01T00:03:00Z >/dev/null
    done
    [ -z "$disposition" ] || adjudicate "$run_id" "$disposition"
    for step in "security:converged" "integration:secure"; do
        rr alice transition --run-id "$run_id" --stage "${step%%:*}" --exit "${step#*:}" --at 2026-01-01T00:03:00Z >/dev/null
    done
}

walk run-a
[ "$(jq -r '.stage_transitions[-1].stage' "$run")" = "integration" ] || fail "walk to integration failed"

[ "$(cat "$state/runs/run-a/owner-slate")" = "s1" ] || fail "the first write did not record the owning slate"
write_plan s6 16:run-a
cp "$run" "$tmp/run-a.json"
expect_refused "run owned by another slate" "run run-a is owned by slate s1, not s6" \
    bash -c "cd '$repo' && node '$writer' intervention --slate s6 --session alice --owner-token \"$(token_for s6)\" --run-id run-a --kind other --note x --at 2026-01-01T00:03:30Z"
cmp -s "$run" "$tmp/run-a.json" || fail "a refused foreign-slate write changed run.json"
[ ! -e "$state/locks/s6.json" ] || fail "a refused foreign-ownership write left slate s6 locked"
cp -R "$state" "$tmp/state-before-foreign-promote-check"
expect_refused "promotion foreign owner" "run run-a is owned by slate s1, not s6" \
    bash -c "cd '$repo' && node '$writer' promote --slate s6 --session alice --owner-token \"$(token_for s6)\" --run-id run-a --head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --fingerprint fp --at 2026-01-01T00:03:30Z"
expect_refused "promotion precheck foreign owner" "run run-a is owned by slate s1, not s6" \
    bash -c "cd '$repo' && node '$writer' promote --check --slate s6 --session alice --owner-token \"$(token_for s6)\" --run-id run-a --head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --fingerprint fp --at 2026-01-01T00:03:30Z"
diff -r "$state" "$tmp/state-before-foreign-promote-check" >/dev/null ||
    fail "a foreign-owner promotion precheck changed durable state"
pass "a second slate cannot write a run another slate owns, and the refusal takes no lock"

[ -z "$(find "$state/runs" -name 'owner-slate.tmp.*')" ] || fail "an owner-slate temp file was left behind"
cp "$state/runs/run-a/owner-slate" "$tmp/owner-slate"
: >"$state/runs/run-a/owner-slate"
expect_refused "empty owner record" "is empty or malformed" \
    rr alice intervention --run-id run-a --kind other --note x --at 2026-01-01T00:03:35Z
printf 's1\n../x' >"$state/runs/run-a/owner-slate"
expect_refused "partial owner record" "is empty or malformed" \
    rr alice intervention --run-id run-a --kind other --note x --at 2026-01-01T00:03:35Z
cp "$tmp/owner-slate" "$state/runs/run-a/owner-slate"
cmp -s "$run" "$tmp/run-a.json" || fail "a refused malformed-owner write changed run.json"
pass "an empty or partial owner record is refused as malformed; the normal path leaves no temp file"

mkdir -p "$state/slates/s7"
printf 'not json\n' >"$state/slates/s7/plan.json"
rr alice intervention --run-id run-a --kind other --note "unaffected" --at 2026-01-01T00:03:40Z >/dev/null ||
    fail "an unrelated or malformed plan.json elsewhere blocked the owning slate"
pass "an unrelated, even malformed, plan.json elsewhere does not block the owner"

write_plan s10 18:run-q
new_run run-u
expect_refused "refused bind on a fresh slate" "lock acquire" \
    bash -c "cd '$repo' && node '$writer' transition --slate s10 --session carol --owner-token \"$(token_for s10)\" --run-id run-u --stage claim --exit k --at 2026-01-01T00:01:00Z"
[ ! -e "$state/locks/s10.json" ] || fail "a refused bind left the slate lock this invocation created"
[ ! -e "$state/runs/run-u/owner-slate" ] || fail "a refused bind recorded an owner"
acquire s10 carol
expect_refused "refused bind with a pre-existing lock" "run run-u is not a lane in any revision of slate s10's plan" \
    bash -c "cd '$repo' && node '$writer' transition --slate s10 --session carol --owner-token \"$(token_for s10)\" --run-id run-u --stage claim --exit k --at 2026-01-01T00:01:00Z"
[ -e "$state/locks/s10.json" ] || fail "a refused bind released a lock it did not create"
cp -R "$state" "$tmp/state-before-unplanned-promote-check"
expect_refused "promotion outside plan" "run run-u is not a lane in any revision of slate s10's plan" \
    bash -c "cd '$repo' && node '$writer' promote --slate s10 --session carol --owner-token \"$(token_for s10)\" --run-id run-u --head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --fingerprint fp --at 2026-01-01T00:01:00Z"
expect_refused "promotion precheck outside plan" "run run-u is not a lane in any revision of slate s10's plan" \
    bash -c "cd '$repo' && node '$writer' promote --check --slate s10 --session carol --owner-token \"$(token_for s10)\" --run-id run-u --head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --fingerprint fp --at 2026-01-01T00:01:00Z"
diff -r "$state" "$tmp/state-before-unplanned-promote-check" >/dev/null ||
    fail "an outside-plan promotion precheck changed durable state"
(cd "$repo" && node "$writer" lock release --slate s10 --session carol --owner-token "$(token_for s10)") >/dev/null
pass "writes require explicit acquisition and a refused bind preserves the held lock"

[ -z "$(find "$state" -name '*.wlock*')" ] || fail "a mutex or its temp stamp file was left behind"
pass "the write mutex leaves neither a lock nor a temp stamp behind"

mkdir -p "$state/slates/s11"
cp "$state/slates/s1/plan.json" "$state/slates/s11/plan.json"
expect_refused "plan copied from another slate" 'records slate_id "s1", not s11' \
    bash -c "cd '$repo' && node '$writer' lock acquire --slate s11 --session alice --owner-token \"$(token_for s11)\""
[ ! -e "$state/locks/s11.json" ] || fail "a plan bound to another slate produced a lock"
pass "a plan whose slate_id does not match its slate directory is refused before any lock"

# A mutex whose stamp cannot be read (here, a directory) is waited out under
# the deadline with back-off, not spun on. The outer timeout turns a
# reintroduced hot loop, which never reaches its deadline, into a failure
# rather than a hung suite.
mkdir -p "$state/runs/run-d/run.json.wlock"
cpu_log="$tmp/wlock-cpu"
TIMEFORMAT='%U %R'
{ time expect_refused "unreadable mutex stamp" "timed out waiting for" \
    timeout 60 bash -c "cd '$repo' && node '$writer' intervention --slate s1 --session alice --owner-token \"$(token_for s1)\" --run-id run-d --kind other --note x --at 2026-01-01T00:02:00Z"; } 2>"$cpu_log"
rmdir "$state/runs/run-d/run.json.wlock"
unset TIMEFORMAT
read -r cpu_user wall <"$cpu_log"
awk -v u="$cpu_user" 'BEGIN { exit !(u < 5) }' || fail "an unreadable mutex stamp burned ${cpu_user}s of CPU (wall ${wall}s)"
pass "an unreadable mutex stamp times out with back-off instead of spinning"

write_plan s8 17:run-t
new_run run-t
jq '.revisions[0].reason = "tampered"' "$state/slates/s8/plan.json" >"$tmp/s8.json"
cp "$tmp/s8.json" "$state/slates/s8/plan.json"
expect_refused "tampered plan on lock acquire" "failed \`plan\` validation" \
    bash -c "cd '$repo' && node '$writer' lock acquire --slate s8 --session alice --owner-token \"$(token_for s8)\""
expect_refused "tampered plan on a run write" "failed \`plan\` validation" \
    bash -c "cd '$repo' && node '$writer' transition --slate s8 --session alice --owner-token \"$(token_for s8)\" --run-id run-t --stage claim --exit k --at 2026-01-01T00:01:00Z"
[ ! -e "$state/locks/s8.json" ] || fail "a tampered plan produced a slate lock"
[ ! -e "$state/runs/run-t/owner-slate" ] || fail "a tampered plan produced an owner record"
pass "a plan whose digest chain is tampered is refused before any lock or ownership is recorded"

# -- interventions and ruling digests -------------------------------------
mkdir -p "$state/slates/s1/orchestrator/run-a/a1"
ruling="$state/slates/s1/orchestrator/run-a/a1/ruling-1.md"
printf 'Ruling 1: keep the scope.\n' >"$ruling"
rr alice intervention --run-id run-a --kind other --note "scope ruling" --ruling "$ruling" --at 2026-01-01T00:04:00Z >/dev/null
digest="$(sha256_file "$ruling")"
note="$(jq -r '.interventions[-1].note' "$run")"
[ "$note" = "scope ruling [ruling dev-flow-v2/runs/run-a/rulings/$digest sha256=$digest]" ] ||
    fail "ruling digest not recorded: $note"
snapshot="$state/runs/run-a/rulings/$digest"
cmp -s "$ruling" "$snapshot" || fail "ruling snapshot differs from the recorded source"
printf 'Later working-file edit.\n' >"$ruling"
[ "$(sha256_file "$snapshot")" = "$digest" ] || fail "editing a source changed its ruling snapshot"
rr alice intervention --run-id run-a --kind other --note "same ruling" --ruling "$snapshot" --at 2026-01-01T00:04:00Z >/dev/null
[ "$(find "$state/runs/run-a/rulings" -type f | wc -l | tr -d ' ')" = 1 ] || fail "identical ruling bytes were duplicated"
pass "an intervention snapshots the exact ruling bytes at a stable digest path"

# -- PR binding --------------------------------------------------------------
rr alice bind-pr --run-id run-a --number 42 --url https://example.test/pr/42 --at 2026-01-01T00:05:00Z >/dev/null
[ "$(jq -r '.pr.number' "$run")" = "42" ] || fail "pr projection not set"
[ "$(jq -r '.pr_bindings | length' "$run")" = "1" ] || fail "pr binding chain not appended"
before_bindings="$(jq -c '.pr_bindings' "$run")"
out="$(rr alice bind-pr --run-id run-a --number 42 --url https://example.test/pr/42 --at 2026-01-01T00:06:00Z)"
[ "$out" = "no change (already recorded)" ] || fail "rebinding the same PR was not a no-op: $out"
[ "$(jq -c '.pr_bindings' "$run")" = "$before_bindings" ] || fail "rebinding the same PR changed the chain"
pass "a PR binding extends the chain and sets the projection; a repeat is a no-op"

# -- promotion ---------------------------------------------------------------
new_run run-c
(cd "$repo" && node "$writer" transition --slate s1 --session alice --owner-token "$(token_for s1)" --run-id run-c --stage claim --exit k --at 2026-01-01T00:01:00Z) >/dev/null
walk run-c defer
head_sha="$(printf '%040d' 0 | tr 0 a)"
expect_refused "promotion before last transition" "must not be before the last stage_transitions entry" \
    rr alice promote --run-id run-c --head "$head_sha" --fingerprint fp --at 2026-01-01T00:02:30Z
[ -e "$(pointer_for_run run-c)" ] || fail "a refused promotion retired the active pointer"
pass "a promotion dated before the last transition is refused"
node "$asset_dir/validate-result-schemas.mjs" run "$state/runs/run-c/run.json" --receipts "$state/runs/run-c/run.json" \
    --adjudication "$state/runs/run-c/adjudications/challenge-r1.json" >/dev/null ||
    fail "strict validation with the challenge adjudication fails after the writer's transitions"
pass "transitions written after an adjudication keep strict --receipts validation passing"
rr alice bind-pr --run-id run-c --number 44 --url https://example.test/pr/44 --at 2026-01-01T00:05:00Z >/dev/null
cp "$state/runs/run-c/run.json" "$tmp/before-unsettled-promotion.json"
expect_refused "promotion over an unsettled deferred finding" "has no settlement" \
    rr alice promote --run-id run-c --head "$(printf '%040d' 0 | tr 0 a)" --fingerprint fp --at 2026-01-01T00:10:00Z
cmp -s "$state/runs/run-c/run.json" "$tmp/before-unsettled-promotion.json" ||
    fail "a refused promotion over an unsettled finding changed the canonical record"
pass "a promotion over an unsettled deferred finding is refused with a byte-identical canonical record"
cp "$run" "$tmp/before-promotion.json"
expect_refused "promotion before PR binding" "before PR binding #42" \
    rr alice promote --run-id run-a --head "$head_sha" --fingerprint fp --at 2026-01-01T00:04:30Z
cmp -s "$run" "$tmp/before-promotion.json" || fail "a backfilled promotion changed the record"
rr alice bind-pr --run-id run-a --number 46 --url https://example.test/pr/46 --at 2026-01-01T00:10:00Z >/dev/null
cp "$run" "$tmp/before-promotion.json"
expect_refused "promotion before a later PR binding" "before PR binding #46" \
    rr alice promote --run-id run-a --head "$head_sha" --fingerprint fp --at 2026-01-01T00:09:00Z
cmp -s "$run" "$tmp/before-promotion.json" || fail "a promotion before a later binding changed the record"
pass "promotion cannot predate the initial or a later PR binding"

# --check exercises the exact promotion candidate without leaving an owner,
# lock, candidate, record, or active-pointer side effect behind.
cp "$state/locks/s1.json" "$tmp/lock-before-scope-precheck.json"
jq '.issues = [11, 12]' "$state/locks/s1.json" >"$tmp/lock-narrow.json"
mv "$tmp/lock-narrow.json" "$state/locks/s1.json"
cp -R "$state" "$tmp/state-before-scope-precheck"
rr alice promote --check --run-id run-a --head "$head_sha" --fingerprint fp --at 2026-01-01T00:10:00Z \
    --issues 11,12,13,14 >/dev/null
diff -r "$state" "$tmp/state-before-scope-precheck" >/dev/null ||
    fail "an accepted scope-change promotion precheck changed durable state"
cp "$tmp/lock-before-scope-precheck.json" "$state/locks/s1.json"
cp -R "$state" "$tmp/state-before-promote-check"
rr alice promote --check --run-id run-a --head "$head_sha" --fingerprint fp --at 2026-01-01T00:10:00Z >/dev/null
diff -r "$state" "$tmp/state-before-promote-check" >/dev/null ||
    fail "a successful promotion precheck changed durable state"
no_candidates "successful promotion precheck"
expect_refused "precheck promotion before a later PR binding" "before PR binding #46" \
    rr alice promote --check --run-id run-a --head "$head_sha" --fingerprint fp --at 2026-01-01T00:09:00Z
diff -r "$state" "$tmp/state-before-promote-check" >/dev/null ||
    fail "a refused promotion precheck changed durable state"
no_candidates "refused chronology promotion precheck"
cp -R "$state" "$tmp/state-before-unsettled-promote-check"
expect_refused "precheck promotion over an unsettled deferred finding" "has no settlement" \
    rr alice promote --check --run-id run-c --head "$head_sha" --fingerprint fp --at 2026-01-01T00:10:00Z
diff -r "$state" "$tmp/state-before-unsettled-promote-check" >/dev/null ||
    fail "an unsettled promotion precheck changed durable state"
no_candidates "refused unsettled promotion precheck"
promotion_parity() {
    local label="$1" expected="$2" pattern="$3"
    shift 3
    local normal check normal_rc=0 check_rc=0
    cp -R "$state" "$tmp/state-before-$label"
    normal="$(rr alice promote --run-id run-a "$@" 2>&1)" || normal_rc=$?
    check="$(rr alice promote --check --run-id run-a "$@" 2>&1)" || check_rc=$?
    [ "$normal_rc" -eq "$expected" ] || fail "$label: promote exit $normal_rc, expected $expected: $normal"
    [ "$check_rc" -eq "$expected" ] || fail "$label: promote --check exit $check_rc, expected $expected: $check"
    grep -qF -- "$pattern" <<<"$normal" || fail "$label: promote omitted $pattern: $normal"
    grep -qF -- "$pattern" <<<"$check" || fail "$label: promote --check omitted $pattern: $check"
    diff -r "$state" "$tmp/state-before-$label" >/dev/null || fail "$label changed durable state"
    no_candidates "$label promotion precheck"
}
promotion_parity invalid-head 2 '--head must be a 40-hex SHA' --head nope --fingerprint fp --at 2026-01-01T00:10:00Z
promotion_parity missing-fingerprint 2 '--fingerprint is required' --head "$head_sha" --at 2026-01-01T00:10:00Z
promotion_parity invalid-at 2 '--at must be a UTC timestamp' --head "$head_sha" --fingerprint fp --at nope
promotion_parity wrong-token 1 'owner token does not match' --owner-token wrong --head "$head_sha" --fingerprint fp --at 2026-01-01T00:10:00Z
cp "$run" "$tmp/run-before-invalid-schema.json"
jq '.schema = 99' "$run" >"$tmp/run-invalid-schema.json"
mv "$tmp/run-invalid-schema.json" "$run"
promotion_parity invalid-existing-schema 1 'failed `run` validation' --head "$head_sha" --fingerprint fp --at 2026-01-01T00:10:00Z
cp "$tmp/run-before-invalid-schema.json" "$run"
pass "promotion precheck validates the same candidate and leaves durable state byte-identical"

# A non-ENOENT candidate-cleanup failure must refuse the actual read-only
# promote command. Preload node:fs before the ESM writer imports it so the
# fixture is deterministic and does not need a permission-racing process.
cleanup_preload="$tmp/deny-candidate-unlink.cjs"
printf '%s\n' \
    'const fs = require("node:fs")' \
    'const { syncBuiltinESMExports } = require("node:module")' \
    'const unlinkSync = fs.unlinkSync' \
    'fs.unlinkSync = (file, ...args) => {' \
    '  if (String(file).includes(".candidate.")) {' \
    '    const error = new Error("injected candidate cleanup failure")' \
    '    error.code = "EACCES"' \
    '    throw error' \
    '  }' \
    '  return unlinkSync(file, ...args)' \
    '}' \
    'syncBuiltinESMExports()' >"$cleanup_preload"
cp -R "$state" "$tmp/state-before-cleanup-failure-precheck"
expect_refused "precheck candidate cleanup failure" "EACCES" \
    bash -c "cd '$repo' && RUN_RECORD_OWNER_TOKEN='$(token_for s1)' node --require '$cleanup_preload' '$writer' promote --check --slate s1 --session alice --run-id run-a --head '$head_sha' --fingerprint fp --at 2026-01-01T00:10:00Z"
candidate_count="$(find "$state" -name '*.candidate.*' -type f | wc -l | tr -d ' ')"
[ "$candidate_count" = 1 ] || fail "cleanup-failure precheck left $candidate_count candidates, expected 1"
find "$state" -name '*.candidate.*' -type f -delete
diff -r "$state" "$tmp/state-before-cleanup-failure-precheck" >/dev/null ||
    fail "a cleanup-failure promotion precheck changed durable state"
no_candidates "refused cleanup-failure promotion precheck"
pass "promotion precheck propagates non-ENOENT candidate cleanup failures"

# Execute the command actually documented in integrate's promotion step,
# rather than a second hand-maintained version of that recipe. The fixture
# confirms that equal promotion/binding times are allowed.
awk '
    /<!-- promotion-record-command -->/ { marker = 1; next }
    marker && /```sh/ { code = 1; next }
    code && /```/ { exit }
    code { sub(/^   /, ""); gsub(/<token>/, "\"$owner_token\""); print }
' "$asset_dir/../../integrate/SKILL.md" >"$tmp/documented-promote.sh"
[ -s "$tmp/documented-promote.sh" ] || fail "integrate promotion command is missing"
(cd "$repo" && support_dir="$asset_dir" slate=s1 session=alice run_id=run-a \
    owner_token="$(token_for s1)" head="$head_sha" gate_fingerprint=fp promoted_at=2026-01-01T00:10:00Z \
    bash -eu "$tmp/documented-promote.sh") >/dev/null
node "$asset_dir/validate-result-schemas.mjs" run "$run" --receipts "$run" --no-adjudications >/dev/null ||
    fail "the documented promotion command did not produce a strict-valid run"
[ "$(jq -r '.outcome + ":" + .promotion.promoted_at + ":" + (.outcome_transitions|length|tostring)' "$run")" = \
    "ready-for-review:2026-01-01T00:10:00Z:1" ] || fail "promotion not recorded"
[ ! -e "$(pointer_for_run run-a)" ] || fail "promotion did not retire the run's active pointer"
pass "the documented promotion command records promotion, outcome and chain and passes run --receipts"

expect_refused "intervention after promotion" "run already ended with outcome ready-for-review" \
    rr alice intervention --run-id run-a --kind other --note late --at 2026-01-01T00:11:00Z
expect_refused "pr binding after promotion" "run already ended with outcome ready-for-review" \
    rr alice bind-pr --run-id run-a --number 43 --url https://example.test/pr/43 --at 2026-01-01T00:11:00Z
expect_refused "transition after promotion" "run already ended" \
    rr alice transition --run-id run-a --stage implement --at 2026-01-01T00:11:00Z
cp -R "$state" "$tmp/state-before-ended-promote-check"
expect_refused "promotion after promotion" "run already ended with outcome ready-for-review" \
    rr alice promote --run-id run-a --head "$head_sha" --fingerprint fp --at 2026-01-01T00:11:00Z
expect_refused "promotion precheck after promotion" "run already ended with outcome ready-for-review" \
    rr alice promote --check --run-id run-a --head "$head_sha" --fingerprint fp --at 2026-01-01T00:11:00Z
diff -r "$state" "$tmp/state-before-ended-promote-check" >/dev/null ||
    fail "an ended-run promotion precheck changed durable state"
pass "every entry dated after the promotion is refused"

expect_refused "backfill after promotion" "run already ended with outcome ready-for-review" \
    rr alice intervention --run-id run-a --kind asked --note "backfilled answer" --at 2026-01-01T00:09:00Z
pass "once promoted, even a backfill dated before the promotion is refused: an ended run takes no entries"

# -- lock contention ---------------------------------------------------------
expect_refused "same slate, other session" "locked by session alice" \
    rr bob intervention --run-id run-a --kind other --note x --at 2026-01-01T00:09:30Z
expect_refused "same milestone, other slate" "milestone 7 is already locked by session alice" \
    bash -c "cd '$repo' && node '$writer' lock acquire --slate s2 --session bob --owner-token \"$(token_for s2)\" --milestone 7 --issues 99"
expect_refused "shared issue, other slate" "issue(s) 12, 13 are already locked by session alice" \
    bash -c "cd '$repo' && node '$writer' lock acquire --slate s3 --session bob --owner-token \"$(token_for s3)\" --issues 12,13"
write_plan s5 12:run-x
expect_refused "plans sharing an issue" "issue(s) 12 are already locked by session alice" \
    bash -c "cd '$repo' && node '$writer' lock acquire --slate s5 --session bob --owner-token \"$(token_for s5)\""
acquire s4 bob --milestone 8 --issues 15
expect_refused "release by non-holder" "locked by session alice" \
    bash -c "cd '$repo' && node '$writer' lock release --slate s1 --session bob --owner-token \"$(token_for s1)\""
pass "the slate lock refuses another session by slate id, milestone and issue set, whatever flags it passes"

# -- run validated before writing ---------------------------------------------
new_run run-b
cp "$state/runs/run-b/run.json" "$tmp/run-b.json"
jq '.stage_transitions[0].stage = "claim"' "$tmp/run-b.json" >"$state/runs/run-b/run.json"
expect_refused "invalid existing record" "failed \`run\` validation" \
    rr alice transition --run-id run-b --stage explore --exit x --at 2026-01-01T00:01:00Z
cp "$tmp/run-b.json" "$state/runs/run-b/run.json"
pass "an existing record that fails validation is refused before any write"

# -- close and archive -------------------------------------------------------
printf 'dispatch\n' >"$state/slates/s1/orchestrator/run-a/a1/dispatch.md"
mkdir -p "$state/slates/s1/orchestrator/run-a/a2"
printf '{}\n' >"$state/slates/s1/orchestrator/run-a/a2/watch.json"
rr alice close --run-id run-a >/dev/null
[ ! -e "$state/slates/s1/orchestrator/run-a" ] || fail "orchestrator files left in the slate directory"
for archived in a1/dispatch.md a1/ruling-1.md a2/watch.json; do
    [ -f "$state/runs/run-a/orchestrator/$archived" ] || fail "orchestrator file $archived not archived into the run directory"
done
[ "$(cat "$state/runs/run-a/orchestrator/a1/ruling-1.md")" = 'Later working-file edit.' ] || fail "archive changed the working ruling"
[ "$(sha256_file "$snapshot")" = "$digest" ] || fail "close broke the ruling reference"
[ "$(jq -r '.interventions[] | select(.note | startswith("scope ruling")) | .note' "$run")" = "$note" ] ||
    fail "close rewrote a historical intervention note"
pass "closing a promoted run moves its orchestrator files into the run directory"

out="$(rr alice close --run-id run-a)"
grep -qF 'archived 0' <<<"$out" || fail "a repeated close was not idempotent: $out"
pass "a repeated close is an idempotent no-op"

mkdir -p "$state/slates/s1/orchestrator/run-b/a1"
printf 'dispatch\n' >"$state/slates/s1/orchestrator/run-b/a1/dispatch.md"
mkdir -p "$state/runs/run-b/orchestrator/a1"
expect_refused "archive clash" "refusing to overwrite" \
    rr alice close --run-id run-b --outcome abandoned --exit "operator stopped" --at 2026-01-01T00:02:00Z
[ "$(jq -r '.outcome' "$state/runs/run-b/run.json")" = "abandoned" ] || fail "abandoned outcome not recorded"
[ -f "$state/slates/s1/orchestrator/run-b/a1/dispatch.md" ] || fail "a refused archive moved files"
rmdir "$state/runs/run-b/orchestrator/a1"
rr alice close --run-id run-b >/dev/null
[ -f "$state/runs/run-b/orchestrator/a1/dispatch.md" ] || fail "retried close did not archive"
[ ! -e "$(pointer_for_run run-b)" ] || fail "close did not retire the abandoned run's active pointer"
pass "closing an open run records its outcome, refuses to overwrite an archive, and archives on retry"

for outcome in capped escalated; do
    run_id="run-$outcome"
    slate="s-$outcome"
    issue=201
    [ "$outcome" = escalated ] && issue=202
    new_run "$run_id"
    write_plan "$slate" "$issue:$run_id"
    acquire "$slate" alice
    (cd "$repo" && node "$writer" close --slate "$slate" --session alice --owner-token "$(token_for "$slate")" \
        --run-id "$run_id" --outcome "$outcome" --exit "test $outcome" --at 2026-01-01T00:02:00Z) >/dev/null
    [ "$(jq -r '.outcome' "$state/runs/$run_id/run.json")" = "$outcome" ] || fail "$outcome outcome was not recorded"
    [ ! -e "$(pointer_for_run "$run_id")" ] || fail "$outcome close did not retire the active pointer"
    (cd "$repo" && node "$writer" lock release --slate "$slate" --session alice --owner-token "$(token_for "$slate")") >/dev/null
done
pass "close retires active pointers for capped and escalated outcomes"

terminal_pointer="$(pointer_for_run run-capped)"
registry_revision="$(git -C "$repo" rev-parse HEAD)"
# Model a stale terminal pointer left behind when retirement could not remove it.
jq -n --arg run run-capped --arg branch fixture-run-capped --arg registry "$registry_revision" \
    '{version: 1, run_id: $run, branch: $branch, generation: 1, registry_revision: $registry}' \
    >"$terminal_pointer"
prune_dry_run="$(cd "$tmp" && node "$writer" prune --dry-run --repo-root repo)"
grep -qF "would remove ${terminal_pointer##*/} (run run-capped" <<<"$prune_dry_run" ||
    fail "run-record prune --dry-run did not report a terminal pointer: $prune_dry_run"
[ -e "$terminal_pointer" ] || fail "run-record prune --dry-run removed a pointer"
prune_output="$(cd "$tmp" && node "$writer" prune --repo-root repo)"
grep -qF "removed ${terminal_pointer##*/} (run run-capped" <<<"$prune_output" ||
    fail "run-record prune did not report its terminal removal: $prune_output"
[ ! -e "$terminal_pointer" ] || fail "run-record prune left the terminal pointer"
for open_run in run-z run-u run-t; do
    open_pointer="$(pointer_for_run "$open_run")"
    [ -e "$open_pointer" ] || fail "run-record prune removed open-run pointer for $open_run"
    grep -qF "prune: skipped ${open_pointer##*/}: run record is invalid or still open" <<<"$prune_output" ||
        fail "run-record prune did not report open-run pointer $open_run as skipped: $prune_output"
done
pass "run-record prune resolves relative roots and removes only terminal pointers"

# A cleanup error cannot refuse a validated terminal outcome. close can be
# retried after the binding is restored and removes the still-live pointer.
new_run run-retirement-recovery
write_plan s-retirement-recovery 203:run-retirement-recovery
acquire s-retirement-recovery alice
recovery_binding="$state/runs/run-retirement-recovery/branch.json"
cp "$recovery_binding" "$tmp/recovery-binding.json"
rm "$recovery_binding"
recovery_rc=0
(cd "$repo" && node "$writer" close --slate s-retirement-recovery --session alice \
    --owner-token "$(token_for s-retirement-recovery)" --run-id run-retirement-recovery \
    --outcome abandoned --exit 'retirement retry fixture' --at 2026-01-01T00:02:00Z) \
    >"$tmp/retirement-recovery.out" 2>"$tmp/retirement-recovery.err" || recovery_rc=$?
[ "$recovery_rc" -eq 0 ] || fail "retirement failure refused close: $(cat "$tmp/retirement-recovery.err")"
grep -qF 'active pointer retirement' "$tmp/retirement-recovery.err" || fail "retirement failure was not reported"
[ "$(jq -r '.outcome' "$state/runs/run-retirement-recovery/run.json")" = abandoned ] || fail "close outcome was lost after retirement failure"
cp "$tmp/recovery-binding.json" "$recovery_binding"
(cd "$repo" && node "$writer" close --slate s-retirement-recovery --session alice \
    --owner-token "$(token_for s-retirement-recovery)" --run-id run-retirement-recovery) >/dev/null
[ ! -e "$(pointer_for_run run-retirement-recovery)" ] || fail "close retry did not retire the deferred pointer"
(cd "$repo" && node "$writer" lock release --slate s-retirement-recovery --session alice \
    --owner-token "$(token_for s-retirement-recovery)") >/dev/null
pass "a retirement failure is reported without refusing close, and a close retry retires the pointer"

# Fail the second attempt's rename after the first one actually moved. A
# retry must preserve the terminal record and the archived first attempt,
# move the remainder, and still refuse genuine destination conflicts above.
new_run run-partial
write_plan s-partial 101:run-partial
acquire s-partial alice
partial_source="$state/slates/s-partial/orchestrator/run-partial"
partial_target="$state/runs/run-partial/orchestrator"
mkdir -p "$partial_source/a1" "$partial_source/a2"
printf 'first\n' >"$partial_source/a1/dispatch.md"
printf 'second\n' >"$partial_source/a2/dispatch.md"
cat >"$tmp/fail-second-archive.mjs" <<'JS'
import fs from 'node:fs'
import { syncBuiltinESMExports } from 'node:module'
const readdir = fs.readdirSync
fs.readdirSync = (source, ...args) => {
  const entries = readdir(source, ...args)
  if (source.endsWith('/orchestrator/run-partial')) {
    return process.env.REVERSE_ARCHIVE_ORDER === '1' ? entries.sort().reverse() : entries.sort()
  }
  return entries
}
const rename = fs.renameSync
let archiveRenameCount = 0
fs.renameSync = (source, target) => {
  if (source.includes('/orchestrator/run-partial/')) {
    archiveRenameCount += 1
    if (archiveRenameCount === 2) throw new Error('injected second archive failure')
  }
  return rename(source, target)
}
syncBuiltinESMExports()
JS
partial_rc=0
(cd "$repo" && node --import "$tmp/fail-second-archive.mjs" "$writer" close \
    --slate s-partial --session alice --owner-token "$(token_for s-partial)" --run-id run-partial --outcome abandoned \
    --exit 'operator stopped' --at 2026-01-01T00:02:00Z) >"$tmp/partial.log" 2>&1 || partial_rc=$?
[ "$partial_rc" -ne 0 ] || fail "injected partial archive unexpectedly succeeded"
grep -qF 'injected second archive failure' "$tmp/partial.log" || fail "partial archive did not reach injected failure"
[ ! -e "$partial_source/a1" ] && [ -f "$partial_target/a1/dispatch.md" ] && [ -f "$partial_source/a2/dispatch.md" ] ||
    fail "fixture did not stop after exactly one attempt moved"
cp "$state/runs/run-partial/run.json" "$tmp/partial-closed.json"
(cd "$repo" && node "$writer" close --slate s-partial --session alice --owner-token "$(token_for s-partial)" --run-id run-partial) >/dev/null
cmp -s "$state/runs/run-partial/run.json" "$tmp/partial-closed.json" || fail "archive retry changed the terminal record"
[ ! -e "$partial_source" ] || fail "retry left the partial source behind"
[ "$(cat "$partial_target/a1/dispatch.md")" = first ] && [ "$(cat "$partial_target/a2/dispatch.md")" = second ] ||
    fail "retry lost or changed an archived attempt"
(cd "$repo" && node "$writer" lock release --slate s-partial --session alice --owner-token "$(token_for s-partial)") >/dev/null
pass "close resumes after an actual partial archive without overwriting attempts or rewriting the terminal record"

# Repeat the same run-partial fixture in a second temporary repository, with
# readdirSync returning the attempt names in reverse order. Keeping the source
# suffix identical exercises the second-rename counter fault with a2 first.
(
    repo="$tmp/reversed-repo"
    git init -q -b main "$repo"
    git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
    printf '{"trusted_orchestrator_actor_ids": [12345]}\n' >"$repo/agent-registry.json"
    git -C "$repo" add agent-registry.json
    git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m registry
    state="$repo/.git/dev-flow-v2"
    new_run run-partial
    write_plan s-partial 102:run-partial
    rm -f "$tmp/token-s-partial"
    acquire s-partial alice
    partial_reversed_source="$state/slates/s-partial/orchestrator/run-partial"
    partial_reversed_target="$state/runs/run-partial/orchestrator"
    mkdir -p "$partial_reversed_source/a1" "$partial_reversed_source/a2"
    printf 'first\n' >"$partial_reversed_source/a1/dispatch.md"
    printf 'second\n' >"$partial_reversed_source/a2/dispatch.md"
    partial_rc=0
    (cd "$repo" && REVERSE_ARCHIVE_ORDER=1 node --import "$tmp/fail-second-archive.mjs" "$writer" close \
        --slate s-partial --session alice --owner-token "$(token_for s-partial)" --run-id run-partial --outcome abandoned \
        --exit 'operator stopped' --at 2026-01-01T00:02:00Z) >"$tmp/partial-reversed.log" 2>&1 || partial_rc=$?
    [ "$partial_rc" -ne 0 ] || fail "reversed injected partial archive unexpectedly succeeded"
    grep -qF 'injected second archive failure' "$tmp/partial-reversed.log" || fail "reversed partial archive did not reach injected failure"
    [ ! -e "$partial_reversed_source/a2" ] && [ -f "$partial_reversed_target/a2/dispatch.md" ] && [ -f "$partial_reversed_source/a1/dispatch.md" ] ||
        fail "reversed fixture did not stop after exactly one attempt moved"
    cp "$state/runs/run-partial/run.json" "$tmp/partial-reversed-closed.json"
    (cd "$repo" && node "$writer" close --slate s-partial --session alice --owner-token "$(token_for s-partial)" --run-id run-partial) >/dev/null
    cmp -s "$state/runs/run-partial/run.json" "$tmp/partial-reversed-closed.json" || fail "reversed archive retry changed the terminal record"
    [ ! -e "$partial_reversed_source" ] || fail "reversed retry left the partial source behind"
    [ "$(cat "$partial_reversed_target/a1/dispatch.md")" = first ] && [ "$(cat "$partial_reversed_target/a2/dispatch.md")" = second ] ||
        fail "reversed retry lost or changed an archived attempt"
    (cd "$repo" && node "$writer" lock release --slate s-partial --session alice --owner-token "$(token_for s-partial)") >/dev/null
    pass "close resumes after a reversed-order partial archive and preserves both attempts"
)

cp "$state/runs/run-b/run.json" "$tmp/run-b-closed.json"
expect_refused "intervention after abandon" "run already ended with outcome abandoned" \
    rr alice intervention --run-id run-b --kind other --note late --at 2026-01-01T00:03:00Z
expect_refused "pr binding after abandon" "run already ended with outcome abandoned" \
    rr alice bind-pr --run-id run-b --number 45 --url https://example.test/pr/45 --at 2026-01-01T00:03:00Z
cmp -s "$state/runs/run-b/run.json" "$tmp/run-b-closed.json" || fail "a write after a non-promotion close changed run.json"
pass "after a non-promotion close, every write is refused and the record is unchanged"

new_run run-e
write_plan s12 19:run-e
acquire s12 alice
(cd "$repo" && node "$writer" transition --slate s12 --session alice --owner-token "$(token_for s12)" --run-id run-e --stage claim --exit k --at 2026-01-01T00:05:00Z) >/dev/null
cp "$state/runs/run-e/run.json" "$tmp/run-e.json"
expect_refused "close before the active stage" "before the active stage claim began" \
    bash -c "cd '$repo' && node '$writer' close --slate s12 --session alice --owner-token \"$(token_for s12)\" --run-id run-e --outcome abandoned --exit x --at 2026-01-01T00:04:00Z"
cmp -s "$state/runs/run-e/run.json" "$tmp/run-e.json" || fail "a close dated before the active stage changed run.json"
(cd "$repo" && node "$writer" lock release --slate s12 --session alice --owner-token "$(token_for s12)") >/dev/null
pass "a close dated before the active stage began is refused"

# -- remediation push record (harmon-devkit#1386) ------------------------------
new_run run-f
write_plan s13 20:run-f
acquire s13 alice
rf() { (cd "$repo" && node "$writer" transition --slate s13 --session alice --owner-token "$(token_for s13)" --run-id run-f "$@"); }
for step in "claim:k" "implement:claimed" "verify:implemented" "challenge:verified" "security:converged" "integration:secure"; do
    rf --stage "${step%%:*}" --exit "${step#*:}" --at 2026-01-01T00:06:00Z >/dev/null
done
fix_head=cccccccccccccccccccccccccccccccccccccccc
expect_refused "remediation outside an integration re-entry" "only on a transition that re-enters integration" \
    rf --stage implement --exit remediating --at 2026-01-01T00:07:00Z --remediation-head "$fix_head" --remediation-findings integration-r1-codex-cloud-1
rf --stage implement --exit remediating --at 2026-01-01T00:07:00Z >/dev/null
rf --stage integration --exit fixed --at 2026-01-01T00:08:00Z \
    --remediation-head "$fix_head" --remediation-findings integration-r1-codex-cloud-1,challenge-r1-codex-adversarial-2 >/dev/null
[ "$(jq -c '.stage_transitions[-1].remediation' "$state/runs/run-f/run.json")" = \
    "{\"head\":\"$fix_head\",\"findings\":[\"integration-r1-codex-cloud-1\",\"challenge-r1-codex-adversarial-2\"]}" ] ||
    fail "the integration re-entry did not record the remediation push"
(cd "$repo" && node "$writer" lock release --slate s13 --session alice --owner-token "$(token_for s13)") >/dev/null
pass "a remediation push is recorded on the integration re-entry, and refused anywhere else"

# Integration results use the same immutable writer as confidence passes, but
# their coordinates are payload.integration_round plus the stable integrator
# producer name.  This covers a recovery where a producer and an empty
# adjudication already exist on disk: identical bytes are adopted only after
# the fresh stage/head/time/schema checks, and a changed replay is refused.
new_run run-integrator
write_plan s-integrator 21:run-integrator
acquire s-integrator alice
ri() { (cd "$repo" && node "$writer" transition --slate s-integrator --session alice --owner-token "$(token_for s-integrator)" --run-id run-integrator "$@"); }
rri() { (cd "$repo" && RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$writer" "$@" --slate s-integrator --session alice); }
for step in "claim:k" "implement:claimed" "verify:implemented" "challenge:verified" "security:converged" "integration:secure"; do
    ri --stage "${step%%:*}" --exit "${step#*:}" --at 2026-01-01T00:06:00Z >/dev/null
done
integration_branch="fixture-run-integrator"
git -C "$repo" branch "$integration_branch" HEAD
mkdir -p "$state/runs/run-integrator/passes" "$state/runs/run-integrator/adjudications"
printf '{"branch":"%s"}\n' "$integration_branch" >"$state/runs/run-integrator/branch.json"
printf '{"roles":{"integrator":{"tier":"economy"}},"rounds":{"integration":0}}\n' >"$state/runs/run-integrator/policy.json"
integration_head="$(git -C "$repo" rev-parse "$integration_branch")"
integration_pass="$tmp/integration-r1-integrator.json"
jq --arg head "$integration_head" '
  .run = {run_id:"run-integrator",initiated_by:"human"}
  | .head = $head
  | .produced_at = "2026-10-01T00:00:00Z"
  | .payload.settled_at = "2026-10-01T00:00:00Z"
  | .payload.codex_cycle = null
' "$asset_dir/../../../../schemas/fixtures/result.integrator.schema/valid/verdict-clean.json" >"$integration_pass"
jq '.payload.checks[0].bucket = "pending"' \
    "$integration_pass" >"$tmp/integration-pending.json"
expect_refused "integrator receipt with pending checks" "pending checks cannot be admitted as an integrator receipt" \
    rri receipt --run-id run-integrator --pass "$tmp/integration-pending.json"
jq '.payload.checks[0].bucket = "pass" | .payload.verdict = "pending" |
    .payload.codex_cycle = {head:.head,cycle:1,attempt:1,trigger_comment_id:"1001",exit_code:11} |
    del(.payload.applied_dispositions)' \
    "$integration_pass" >"$tmp/integration-pending-review.json"
expect_refused "integrator receipt with a pending review after CI settled" "pending review verdict or checker cycle cannot be admitted as an integrator receipt" \
    rri receipt --run-id run-integrator --pass "$tmp/integration-pending-review.json"
jq '.payload.checks[0].bucket = "pass" | .payload.verdict = "pending" |
    .payload.codex_cycle = {head:.head,cycle:1,attempt:2,trigger_comment_id:"1001",exit_code:12} |
    del(.payload.applied_dispositions)' \
    "$integration_pass" >"$tmp/integration-retrying-review.json"
expect_refused "integrator receipt while a review retry is pending" "pending review verdict or checker cycle cannot be admitted as an integrator receipt" \
    rri receipt --run-id run-integrator --pass "$tmp/integration-retrying-review.json"
rri receipt --run-id run-integrator --pass "$integration_pass" >/dev/null
[ -f "$state/runs/run-integrator/passes/integration-r1-integrator.json" ] ||
    fail "integrator receipt was not published under its stable coordinates"
rri receipt --run-id run-integrator --pass "$integration_pass" >/dev/null
jq '.producer.model = "different-producer-bytes"' "$integration_pass" >"$tmp/integration-replay-changed.json"
expect_refused "integrator receipt changed replay" "already receipted with different content" \
    rri receipt --run-id run-integrator --pass "$tmp/integration-replay-changed.json"
jq -n --arg head "$integration_head" '{schema:2,run_id:"run-integrator",stage:"integration",round:1,reviewed_head:$head,adjudications:[]}' \
    >"$tmp/integration-r1-adjudication.json"
rri adjudicate --run-id run-integrator --file "$tmp/integration-r1-adjudication.json" >/dev/null
[ -f "$state/runs/run-integrator/adjudications/integration-r1.json" ] ||
    fail "integration adjudication was not published with its receipted pass"
(cd "$repo" && node "$writer" lock release --slate s-integrator --session alice --owner-token "$(token_for s-integrator)") >/dev/null
pass "integrator receipts and empty adjudications are immutable, replay-safe integration evidence"

# A completed after-ci integration observation with a terminal required-check
# failure has no Codex cycle to authenticate.  Exercise the actual record
# writer for the narrowly permitted non-clean receipt and its adjudication;
# this is not a clean/cap-zero waiver.
new_run run-integrator-after-ci-failure
write_plan s-integrator-failed 22:run-integrator-after-ci-failure
acquire s-integrator-failed alice
rif() { (cd "$repo" && node "$writer" transition --slate s-integrator-failed --session alice --owner-token "$(token_for s-integrator-failed)" --run-id run-integrator-after-ci-failure "$@"); }
rrif() { (cd "$repo" && RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator-failed)" node "$writer" "$@" --slate s-integrator-failed --session alice); }
for step in "claim:k" "implement:claimed" "verify:implemented" "challenge:verified" "security:converged" "integration:secure"; do
    rif --stage "${step%%:*}" --exit "${step#*:}" --at 2026-01-01T00:06:00Z >/dev/null
done
after_ci_branch="fixture-run-integrator-after-ci-failure"
git -C "$repo" branch "$after_ci_branch" HEAD
mkdir -p "$state/runs/run-integrator-after-ci-failure/passes" "$state/runs/run-integrator-after-ci-failure/adjudications"
printf '{"branch":"%s"}\n' "$after_ci_branch" >"$state/runs/run-integrator-after-ci-failure/branch.json"
printf '{"roles":{"integrator":{"tier":"economy"}},"rounds":{"integration":1},"stages":{"integration":{"finders":["codex-cloud"],"review_trigger":"after-ci"}}}\n' >"$state/runs/run-integrator-after-ci-failure/policy.json"
after_ci_head="$(git -C "$repo" rev-parse "$after_ci_branch")"
after_ci_pass="$tmp/integration-r1-after-ci-failure.json"
jq --arg head "$after_ci_head" '
  .run = {run_id:"run-integrator-after-ci-failure",initiated_by:"human"}
  | .head = $head
  | .produced_at = "2026-10-01T00:00:00Z"
  | .payload.settled_at = "2026-10-01T00:00:00Z"
  | .payload.codex_cycle = null
  | .payload.checks[0].bucket = "fail"
  | .payload.verdict = "findings"
  | .payload.findings = [{id:"integration-r1-human-1",body:"required build failed",source_id:"1004"}]
  | del(.payload.applied_dispositions)
' "$asset_dir/../../../../schemas/fixtures/result.integrator.schema/valid/codex-cycle-null.json" >"$after_ci_pass"
rrif receipt --run-id run-integrator-after-ci-failure --pass "$after_ci_pass" >/dev/null
after_ci_adjudication="$tmp/integration-r1-after-ci-failure-adjudication.json"
jq -n --arg head "$after_ci_head" '
  {schema:2,run_id:"run-integrator-after-ci-failure",stage:"integration",round:1,reviewed_head:$head,
   adjudications:[{finding_id:"integration-r1-human-1",reviewer_priority:null,adjudicated_priority:"P2",
     disposition:"decline",reason:"the required check failure is retained for escalation",evidence:"receipt records the terminal required CI failure",override:null}]}
' >"$after_ci_adjudication"
rrif adjudicate --run-id run-integrator-after-ci-failure --file "$after_ci_adjudication" >/dev/null
[ -f "$state/runs/run-integrator-after-ci-failure/passes/integration-r1-integrator.json" ] &&
    [ -f "$state/runs/run-integrator-after-ci-failure/adjudications/integration-r1.json" ] ||
    fail "the after-ci failure receipt/adjudication was not published by the supported writer"
(cd "$repo" && node "$writer" lock release --slate s-integrator-failed --session alice --owner-token "$(token_for s-integrator-failed)") >/dev/null
pass "the supported writer retains a completed after-ci required-CI failure receipt and adjudication"

# -- linked worktree resolves the common directory -----------------------------
git -C "$repo" worktree add -q "$tmp/lane" -b lane
new_run run-d
(cd "$tmp/lane" && node "$writer" transition --slate s1 --session alice --owner-token "$(token_for s1)" --run-id run-d --stage claim --exit k --at 2026-01-01T00:01:00Z) >/dev/null
[ "$(jq -r '.stage_transitions[-1].stage' "$state/runs/run-d/run.json")" = "claim" ] ||
    fail "a linked worktree did not write the common directory's record"
pass "a linked worktree writes the common directory's record"

# -- release ---------------------------------------------------------------
cp "$state/locks/s4.json" "$tmp/held-lock.json"
force_rc=0
(cd "$repo" && node "$writer" lock release --slate s4 --session alice --owner-token "$(token_for s4)" --force) >"$tmp/no-reason.log" 2>&1 || force_rc=$?
[ "$force_rc" -eq 2 ] || fail "force release without a reason was not a usage error"
cmp -s "$state/locks/s4.json" "$tmp/held-lock.json" || fail "missing reason changed the held lock"

# An unwritable audit destination must leave the old session's reservation.
mkdir -p "$state/locks/recoveries"
printf 'blocked\n' >"$state/locks/recoveries/s4"
force_rc=0
(cd "$repo" && node "$writer" lock release --slate s4 --session alice --owner-token "$(token_for s4)" --force --reason 'dead session') >"$tmp/audit-failure.log" 2>&1 || force_rc=$?
[ "$force_rc" -ne 0 ] || fail "force release succeeded without its audit"
cmp -s "$state/locks/s4.json" "$tmp/held-lock.json" || fail "audit failure released the lock"
rm "$state/locks/recoveries/s4"
(cd "$repo" && node "$writer" lock release --slate s4 --session alice --owner-token "$(token_for s4)" --force --reason "dead session") >/dev/null
[ ! -e "$state/locks/s4.json" ] || fail "force release left the lock"
audits=("$state/locks/recoveries/s4/"*.json)
[ "${#audits[@]}" -eq 1 ] && [ -f "${audits[0]}" ] || fail "force release did not leave exactly one audit"
jq -e --slurpfile held "$tmp/held-lock.json" '
    .action == "force-release" and .session == "alice" and .reason == "dead session" and
    .lock == $held[0] and (.at | test("Z$"))
' "${audits[0]}" >/dev/null || fail "recovery audit lost attribution, reason, time or the old lock"
acquire s4 alice --milestone 8 --issues 15
[ "$(lock_scope s4)" = "alice:8:15" ] || fail "new session could not acquire after explicit recovery"
(cd "$repo" && node "$writer" lock release --slate s4 --session alice --owner-token "$(token_for s4)") >/dev/null
(cd "$repo" && node "$writer" lock release --slate s1 --session alice --owner-token "$(token_for s1)") >/dev/null
[ ! -e "$state/locks/s1.json" ] || fail "holder release left the lock"
pass "explicit recovery requires a reason, retains an audit before release, and permits normal reacquisition"

# Lost-token recovery must also work for a tokenized lock with the same session name.
acquire lost-token alice --issues 223
write_plan lost-token 223:run-lost-token
new_run run-lost-token
old_token="$(token_for lost-token)"
expect_refused "same-name lost-token ordinary write" "owner token does not match" \
    env -u RUN_RECORD_OWNER_TOKEN bash -c 'cd "$1" && node "$2" transition --slate lost-token --session alice --run-id run-lost-token --stage claim --exit k' _ "$repo" "$writer"
(cd "$repo" && env -u RUN_RECORD_OWNER_TOKEN node "$writer" lock release \
    --slate lost-token --session alice --force --reason 'operator confirms lost-token recovery') >/dev/null
[ ! -e "$state/locks/lost-token.json" ] || fail "same-name lost-token force release left the lock"
rm "$tmp/token-lost-token"
acquire lost-token alice --issues 223
[ -n "$(token_for lost-token)" ] && [ "$(token_for lost-token)" != "$old_token" ] ||
    fail "same-name lost-token recovery did not mint a fresh token"
expect_refused "old token after same-name lost-token recovery" "owner token does not match" \
    env -u RUN_RECORD_OWNER_TOKEN bash -c 'cd "$1" && node "$2" transition --slate lost-token --session alice --owner-token "$3" --run-id run-lost-token --stage claim --exit k' _ "$repo" "$writer" "$old_token"
(cd "$repo" && node "$writer" lock release --slate lost-token --session alice --owner-token "$(token_for lost-token)") >/dev/null
pass "a same-named session without its token force-releases a tokenized lock and rejects the old token after recovery"

# Pre-change locks have no token: accept the holder, warn, ignore supplied tokens.
acquire legacy alice --issues 222
write_plan legacy 222:run-legacy
new_run run-legacy
legacy_token="$(token_for legacy)"
jq 'del(.owner_token_digest)' "$state/locks/legacy.json" >"$tmp/legacy.json"
cp "$tmp/legacy.json" "$state/locks/legacy.json"
(cd "$repo" && node "$writer" lock acquire --slate legacy --session alice --owner-token ignored) >"$tmp/legacy.out" 2>"$tmp/legacy.err"
[ ! -s "$tmp/legacy.out" ] || fail "legacy acquisition printed a token"
grep -qF 'lock release then lock acquire' "$tmp/legacy.err" || fail "legacy lock did not warn about upgrade"
(cd "$repo" && node "$writer" transition --slate legacy --session alice --owner-token ignored --run-id run-legacy --stage claim --exit k --at 2026-01-01T00:01:00Z) >/dev/null 2>"$tmp/legacy-write.err"
grep -qF 'legacy slate lock' "$tmp/legacy-write.err" || fail "legacy write did not warn"
[ "$(jq -r '.stage_transitions[-1].stage' "$state/runs/run-legacy/run.json")" = claim ] || fail "legacy write refused its holder"
(cd "$repo" && node "$writer" lock release --slate legacy --session alice --force --reason 'operator confirms upgrade') >/dev/null
rm "$tmp/token-legacy"
acquire legacy alice --issues 222
[ "$(token_for legacy)" != "$legacy_token" ] || fail "recovery reused the old token"
expect_refused "old token after recovery" "owner token does not match" \
    bash -c "cd '$repo' && node '$writer' lock release --slate legacy --session alice --owner-token '$legacy_token'"
(cd "$repo" && node "$writer" lock release --slate legacy --session alice --owner-token "$(token_for legacy)") >/dev/null
pass "legacy locks accept a supplied token with a warning; explicit recovery mints a fresh token"

# Planned-lane initialization uses the same receipt-aware writer as later
# interventions; it must never adopt or overwrite an existing record.
acquire planned-lane alice --issues 333
write_plan planned-lane 333:run-planned-lane
node --input-type=module - "$asset_dir" "$state/slates/planned-lane/plan.json" >"$tmp/lane-policy.json" <<'NODE'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
const [assets, planFile] = process.argv.slice(2)
process.argv[1] = assets
const { resolvePolicy } = await import(`${assets}/devflow-policy.mjs`)
const { parseToml } = await import(`${assets}/lib/toml-lite.mjs`)
const full = resolvePolicy(parseToml(readFileSync(resolve(assets, '../../../../../.devflow.toml'), 'utf8')))
const profile = JSON.parse(readFileSync(planFile)).revisions.at(-1).plan.policy
full.rigor = { ...full.rigor, level: profile.rigor, source: profile.rigor_source }
full.rounds = { ...full.rounds, ...profile.caps, integration_exempt: profile.caps.integration }
full.breadth = { ...full.breadth, ...profile.breadth }
full.strategy.name = profile.strategy
for (const [role, tier] of Object.entries(profile.role_tiers)) full.roles[role].tier = tier
console.log(JSON.stringify(full))
NODE
deferred_run=run-deferred-lane
deferred_branch=333-l
deferred_revision="$(git -C "$repo" rev-parse HEAD)"
deferred_pointer="$("$monitor" active-path --branch "$deferred_branch" --repo-root "$repo")"
"$monitor" activate --active-state "$deferred_pointer" --run-id "$deferred_run" --branch "$deferred_branch" \
    --expected-predecessor absent --expected-generation 0 --registry-revision "$deferred_revision" \
    --writer feature-owner --repo-root "$repo" >/dev/null
deferred_state="$("$monitor" state-path --run-id "$deferred_run" --repo-root "$repo")"
deferred_head="$(git -C "$repo" rev-parse HEAD)"
"$monitor" reserve --state "$deferred_state" --event evt-lane-init --action push \
    --expected-head "$deferred_head" --writer feature-owner --active-state "$deferred_pointer" \
    --run-id "$deferred_run" --branch "$deferred_branch" --generation 1 --repo-root "$repo" >/dev/null
jq -n --arg run "$deferred_run" '{schema: 2, run_id: $run, outcome: "abandoned"}' \
    >"$(dirname "$deferred_state")/run.json"
lane_init_output=""
lane_init_rc=0
lane_init_output="$(cd "$repo" && node "$writer" lane-init --slate planned-lane --session alice \
    --owner-token "$(token_for planned-lane)" --lane l333 --policy "$tmp/lane-policy.json" \
    --at 2026-01-01T00:00:00Z 2>&1)" || lane_init_rc=$?
[ "$lane_init_rc" -eq 1 ] || fail "lane-init did not refuse a deferred terminal pointer: exit=$lane_init_rc output=$lane_init_output"
for needle in "$deferred_run" evt-lane-init reconcile retire prune; do
    grep -qF "$needle" <<<"$lane_init_output" || fail "lane-init refusal omitted '$needle': $lane_init_output"
done
[ ! -e "$state/runs/run-planned-lane/run.json" ] || fail "refused lane-init wrote its run record"
deferred_observed="$tmp/lane-init-observed.json"
jq -n --arg event evt-lane-init --arg head "$deferred_head" \
    '{status: "landed", event: $event, action: "push", head: $head}' >"$deferred_observed"
"$monitor" reconcile --state "$deferred_state" --event evt-lane-init --observed "$deferred_observed" \
    --active-state "$deferred_pointer" --run-id "$deferred_run" --branch "$deferred_branch" \
    --generation 1 --repo-root "$repo" >/dev/null
"$monitor" retire --run-id "$deferred_run" --repo-root "$repo" >/dev/null
(cd "$repo" && node "$writer" lane-init --slate planned-lane --session alice \
    --owner-token "$(token_for planned-lane)" --lane l333 --policy "$tmp/lane-policy.json" --at 2026-01-01T00:00:00Z) >/dev/null
planned_record="$state/runs/run-planned-lane/run.json"
jq -e '.schema == 2 and .receipts == [] and .stage_transitions[0].stage == "kickoff"' \
    "$planned_record" >/dev/null || fail "lane-init omitted receipt-complete kickoff state"
[ "$(cat "$state/runs/run-planned-lane/owner-slate")" = planned-lane ] || fail "lane-init omitted slate binding"
(cd "$repo" && node "$writer" intervention --slate planned-lane --session alice \
    --owner-token "$(token_for planned-lane)" --run-id run-planned-lane --kind asked \
    --note 'planned-lane initialized' --at 2026-01-01T00:01:00Z) >/dev/null
prior_record="$(sha256_file "$planned_record")"
expect_refused "existing planned run" "already exists" \
    bash -c 'cd "$1" && node "$2" lane-init --slate planned-lane --session alice --owner-token "$3" --lane l333' \
    _ "$repo" "$writer" "$(token_for planned-lane)"
[ "$(sha256_file "$planned_record")" = "$prior_record" ] || fail "lane-init replaced an existing run"
expect_refused "unknown planned lane" "unknown lane" \
    bash -c 'cd "$1" && node "$2" lane-init --slate planned-lane --session alice --owner-token "$3" --lane missing' \
    _ "$repo" "$writer" "$(token_for planned-lane)"
pass "lane-init creates a receipt-complete owned run, accepts an intervention, and never overwrites"

# -- answered harness approvals (#1529): fresh run, independent of promotion cases --
new_run run-prompts
acquire prompt-slate alice --issues 999
write_plan prompt-slate 999:run-prompts
prompt_rr() {
    (cd "$repo" && RUN_RECORD_OWNER_TOKEN="$(token_for prompt-slate)" node "$writer" "$@" --slate prompt-slate --session alice)
}
for decision in approved denied; do
    prompt_rr intervention --run-id run-prompts --kind prompt --decision "$decision" \
        --command 'task verify' --answered-by orchestrator --note 'inspected full request' \
        --at 2026-01-01T00:01:00Z >/dev/null
done
jq -e '(.interventions | length) == 2 and .interventions[0].decision == "approved" and .interventions[1].decision == "denied" and all(.interventions[]; .command == "task verify" and .answered_by == "orchestrator")' \
    "$state/runs/run-prompts/run.json" >/dev/null || fail "prompt fields were not retained"
for vector in \
    '--decision approved|--command is required' \
    '--command verify|--decision must be approved or denied' \
    '--decision unknown --command verify|--decision must be approved or denied' \
    '--decision denied --command verify --answered-by bot|--answered-by must be orchestrator or human'; do
    flags="${vector%%|*}"
    expected="${vector#*|}"
    # Fixed test vectors only; split intentionally into CLI arguments.
    read -r -a prompt_flags <<<"$flags"
    prompt_rc=0
    prompt_rr intervention --run-id run-prompts --kind prompt --note request "${prompt_flags[@]}" >"$tmp/prompt-refusal" 2>&1 || prompt_rc=$?
    [ "$prompt_rc" -ne 0 ] || fail "invalid prompt accepted: $flags"
    grep -qF -- "$expected" "$tmp/prompt-refusal" || fail "writer refusal omitted '$expected': $(cat "$tmp/prompt-refusal")"
done
prompt_rc=0
prompt_rr intervention --run-id run-prompts --kind other --decision approved --note request >"$tmp/prompt-refusal" 2>&1 || prompt_rc=$?
[ "$prompt_rc" -ne 0 ] || fail "other accepted prompt fields"
grep -qF -- 'prompt fields require --kind prompt' "$tmp/prompt-refusal" || fail "other refusal was not the writer's diagnostic"
[ "$(jq '.interventions | length' "$state/runs/run-prompts/run.json")" -eq 2 ] || fail "refused prompt mutated run"
pass "answered approval prompts retain decisions and commands and refuse incomplete or invalid input"
for field in decision command; do
    jq --arg field "$field" 'del(.interventions[0][$field])' "$state/runs/run-prompts/run.json" >"$tmp/incomplete-prompt.json"
    prompt_rc=0
    node "$asset_dir/validate-result-schemas.mjs" run "$tmp/incomplete-prompt.json" >"$tmp/prompt-schema-refusal" 2>&1 || prompt_rc=$?
    [ "$prompt_rc" -ne 0 ] || fail "schema accepted prompt missing $field"
    grep -qF "$field" "$tmp/prompt-schema-refusal" || fail "schema refusal omitted missing $field"
done
pass "run schema requires prompt decision and command independently of writer checks"

no_candidates "suite"
echo "test-run-record: all cases passed"
