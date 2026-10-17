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
state="$repo/.git/dev-flow-v2"

# The state root must be this fixture's, never the clone running the test.
resolved="$(cd "$repo" && git rev-parse --path-format=absolute --git-common-dir)"
[ "$resolved" = "$repo/.git" ] || fail "fixture common dir resolved to $resolved"

new_run() {
    local run_id="$1"
    mkdir -p "$state/runs/$run_id"
    jq -n --arg id "$run_id" '{
      schema: 2, run_id: $id, initiated_by: "human",
      started_at: "2026-01-01T00:00:00Z",
      stage_transitions: [{stage: "kickoff", entered_at: "2026-01-01T00:00:00Z"}],
      interventions: [], outcome: null, pr: null,
      evidence_comments: [], evidence_registrations: [], pr_bindings: [],
      outcome_transitions: [], settlements: [], promotion: null, receipts: []
    }' >"$state/runs/$run_id/run.json"
}

# rr SESSION ARGS... — run the writer as SESSION on slate "s1" from the fixture.
rr() {
    local session="$1"
    shift
    (cd "$repo" && node "$writer" "$@" --slate s1 --session "$session")
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
expect_refused "write without a plan" "has no lock yet and no scope to record" \
    rr alice transition --run-id run-a --stage claim --exit kicked --at 2026-01-01T00:01:00Z
pass "a run write for a slate with no plan is refused"

(cd "$repo" && node "$writer" lock acquire --slate s1 --session alice --milestone 7 --issues 11,12) >/dev/null
[ "$(lock_scope s1)" = "alice:7:11,12" ] || fail "lock does not record session, milestone and issue set"
pass "before a plan exists, the lock records the given milestone and issue set"

write_plan s1 11:run-a 12:run-b 13:run-c 14:run-d
cp "$run" "$tmp/run-a-unplanned.json"
expect_refused "plan outside the reservation" "names issue(s) 13, 14 outside the reserved scope" \
    rr alice transition --run-id run-a --stage claim --exit kicked --at 2026-01-01T00:01:00Z
cmp -s "$run" "$tmp/run-a-unplanned.json" || fail "a write under an unreserved plan changed run.json"
pass "a canonical plan naming issues outside the reserved scope refuses every write"

(cd "$repo" && node "$writer" lock acquire --slate s1 --session alice --issues 11,12,13,14) >/dev/null
[ "$(lock_scope s1)" = "alice:7:11,12,13,14" ] || fail "widening the reservation did not record the new issue set"
pass "lock acquire --issues widens the reservation, keeping the recorded milestone"

new_run run-z
cp "$state/runs/run-z/run.json" "$tmp/run-z.json"
expect_refused "run outside the plan" "run run-z is not a lane in any revision of slate s1's plan" \
    rr alice transition --run-id run-z --stage claim --exit kicked --at 2026-01-01T00:01:00Z
cmp -s "$state/runs/run-z/run.json" "$tmp/run-z.json" || fail "a refused foreign run changed its record"
pass "a write naming a run that is not a lane of the locked slate's plan is refused, record unchanged"

expect_refused "reservation narrower than the plan" "names issue(s) 12, 13, 14 outside the reserved scope" \
    bash -c "cd '$repo' && node '$writer' lock acquire --slate s1 --session alice --issues 11"
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
    bash -c "cd '$repo' && node '$writer' intervention --slate s6 --session alice --run-id run-a --kind other --note x --at 2026-01-01T00:03:30Z"
cmp -s "$run" "$tmp/run-a.json" || fail "a refused foreign-slate write changed run.json"
[ ! -e "$state/locks/s6.json" ] || fail "a refused foreign-ownership write left slate s6 locked"
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
expect_refused "refused bind on a fresh slate" "run run-u is not a lane in any revision of slate s10's plan" \
    bash -c "cd '$repo' && node '$writer' transition --slate s10 --session carol --run-id run-u --stage claim --exit k --at 2026-01-01T00:01:00Z"
[ ! -e "$state/locks/s10.json" ] || fail "a refused bind left the slate lock this invocation created"
[ ! -e "$state/runs/run-u/owner-slate" ] || fail "a refused bind recorded an owner"
(cd "$repo" && node "$writer" lock acquire --slate s10 --session carol) >/dev/null
expect_refused "refused bind with a pre-existing lock" "run run-u is not a lane in any revision of slate s10's plan" \
    bash -c "cd '$repo' && node '$writer' transition --slate s10 --session carol --run-id run-u --stage claim --exit k --at 2026-01-01T00:01:00Z"
[ -e "$state/locks/s10.json" ] || fail "a refused bind released a lock it did not create"
(cd "$repo" && node "$writer" lock release --slate s10 --session carol) >/dev/null
pass "a refused bind releases only a slate lock this invocation created"

[ -z "$(find "$state" -name '*.wlock*')" ] || fail "a mutex or its temp stamp file was left behind"
pass "the write mutex leaves neither a lock nor a temp stamp behind"

mkdir -p "$state/slates/s11"
cp "$state/slates/s1/plan.json" "$state/slates/s11/plan.json"
expect_refused "plan copied from another slate" 'records slate_id "s1", not s11' \
    bash -c "cd '$repo' && node '$writer' lock acquire --slate s11 --session alice"
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
    timeout 60 bash -c "cd '$repo' && node '$writer' intervention --slate s1 --session alice --run-id run-d --kind other --note x --at 2026-01-01T00:02:00Z"; } 2>"$cpu_log"
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
    bash -c "cd '$repo' && node '$writer' lock acquire --slate s8 --session alice"
expect_refused "tampered plan on a run write" "failed \`plan\` validation" \
    bash -c "cd '$repo' && node '$writer' transition --slate s8 --session alice --run-id run-t --stage claim --exit k --at 2026-01-01T00:01:00Z"
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
(cd "$repo" && node "$writer" transition --slate s1 --session alice --run-id run-c --stage claim --exit k --at 2026-01-01T00:01:00Z) >/dev/null
walk run-c defer
head_sha="$(printf '%040d' 0 | tr 0 a)"
expect_refused "promotion before last transition" "must not be before the last stage_transitions entry" \
    rr alice promote --run-id run-c --head "$head_sha" --fingerprint fp --at 2026-01-01T00:02:30Z
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

# Execute the command actually documented in integrate's promotion step,
# rather than a second hand-maintained version of that recipe. The fixture
# confirms that equal promotion/binding times are allowed.
awk '
    /<!-- promotion-record-command -->/ { marker = 1; next }
    marker && /```sh/ { code = 1; next }
    code && /```/ { exit }
    code { sub(/^   /, ""); print }
' "$asset_dir/../../integrate/SKILL.md" >"$tmp/documented-promote.sh"
[ -s "$tmp/documented-promote.sh" ] || fail "integrate promotion command is missing"
(cd "$repo" && support_dir="$asset_dir" slate=s1 session=alice run_id=run-a \
    head="$head_sha" gate_fingerprint=fp promoted_at=2026-01-01T00:10:00Z \
    bash -eu "$tmp/documented-promote.sh") >/dev/null
node "$asset_dir/validate-result-schemas.mjs" run "$run" --receipts "$run" --no-adjudications >/dev/null ||
    fail "the documented promotion command did not produce a strict-valid run"
[ "$(jq -r '.outcome + ":" + .promotion.promoted_at + ":" + (.outcome_transitions|length|tostring)' "$run")" = \
    "ready-for-review:2026-01-01T00:10:00Z:1" ] || fail "promotion not recorded"
pass "the documented promotion command records promotion, outcome and chain and passes run --receipts"

expect_refused "intervention after promotion" "run already ended with outcome ready-for-review" \
    rr alice intervention --run-id run-a --kind other --note late --at 2026-01-01T00:11:00Z
expect_refused "pr binding after promotion" "run already ended with outcome ready-for-review" \
    rr alice bind-pr --run-id run-a --number 43 --url https://example.test/pr/43 --at 2026-01-01T00:11:00Z
expect_refused "transition after promotion" "run already ended" \
    rr alice transition --run-id run-a --stage implement --at 2026-01-01T00:11:00Z
pass "every entry dated after the promotion is refused"

expect_refused "backfill after promotion" "run already ended with outcome ready-for-review" \
    rr alice intervention --run-id run-a --kind asked --note "backfilled answer" --at 2026-01-01T00:09:00Z
pass "once promoted, even a backfill dated before the promotion is refused: an ended run takes no entries"

# -- lock contention ---------------------------------------------------------
expect_refused "same slate, other session" "locked by session alice" \
    rr bob intervention --run-id run-a --kind other --note x --at 2026-01-01T00:09:30Z
expect_refused "same milestone, other slate" "milestone 7 is already locked by session alice" \
    bash -c "cd '$repo' && node '$writer' lock acquire --slate s2 --session bob --milestone 7 --issues 99"
expect_refused "shared issue, other slate" "issue(s) 12, 13 are already locked by session alice" \
    bash -c "cd '$repo' && node '$writer' lock acquire --slate s3 --session bob --issues 12,13"
write_plan s5 12:run-x
expect_refused "plans sharing an issue" "issue(s) 12 are already locked by session alice" \
    bash -c "cd '$repo' && node '$writer' lock acquire --slate s5 --session bob"
(cd "$repo" && node "$writer" lock acquire --slate s4 --session bob --milestone 8 --issues 15) >/dev/null
expect_refused "release by non-holder" "only that session may release it" \
    bash -c "cd '$repo' && node '$writer' lock release --slate s1 --session bob"
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
pass "closing an open run records its outcome, refuses to overwrite an archive, and archives on retry"

# Fail the second attempt's rename after the first one actually moved. A
# retry must preserve the terminal record and the archived first attempt,
# move the remainder, and still refuse genuine destination conflicts above.
new_run run-partial
write_plan s-partial 101:run-partial
partial_source="$state/slates/s-partial/orchestrator/run-partial"
partial_target="$state/runs/run-partial/orchestrator"
mkdir -p "$partial_source/a1" "$partial_source/a2"
printf 'first\n' >"$partial_source/a1/dispatch.md"
printf 'second\n' >"$partial_source/a2/dispatch.md"
cat >"$tmp/fail-second-archive.mjs" <<'JS'
import fs from 'node:fs'
import { syncBuiltinESMExports } from 'node:module'
const rename = fs.renameSync
fs.renameSync = (source, target) => {
  if (source.endsWith('/orchestrator/run-partial/a2')) throw new Error('injected second archive failure')
  return rename(source, target)
}
syncBuiltinESMExports()
JS
partial_rc=0
(cd "$repo" && node --import "$tmp/fail-second-archive.mjs" "$writer" close \
    --slate s-partial --session alice --run-id run-partial --outcome abandoned \
    --exit 'operator stopped' --at 2026-01-01T00:02:00Z) >"$tmp/partial.log" 2>&1 || partial_rc=$?
[ "$partial_rc" -ne 0 ] || fail "injected partial archive unexpectedly succeeded"
grep -qF 'injected second archive failure' "$tmp/partial.log" || fail "partial archive did not reach injected failure"
[ ! -e "$partial_source/a1" ] && [ -f "$partial_target/a1/dispatch.md" ] && [ -f "$partial_source/a2/dispatch.md" ] ||
    fail "fixture did not stop after exactly one attempt moved"
cp "$state/runs/run-partial/run.json" "$tmp/partial-closed.json"
(cd "$repo" && node "$writer" close --slate s-partial --session alice --run-id run-partial) >/dev/null
cmp -s "$state/runs/run-partial/run.json" "$tmp/partial-closed.json" || fail "archive retry changed the terminal record"
[ ! -e "$partial_source" ] || fail "retry left the partial source behind"
[ "$(cat "$partial_target/a1/dispatch.md")" = first ] && [ "$(cat "$partial_target/a2/dispatch.md")" = second ] ||
    fail "retry lost or changed an archived attempt"
(cd "$repo" && node "$writer" lock release --slate s-partial --session alice) >/dev/null
pass "close resumes after an actual partial archive without overwriting attempts or rewriting the terminal record"

cp "$state/runs/run-b/run.json" "$tmp/run-b-closed.json"
expect_refused "intervention after abandon" "run already ended with outcome abandoned" \
    rr alice intervention --run-id run-b --kind other --note late --at 2026-01-01T00:03:00Z
expect_refused "pr binding after abandon" "run already ended with outcome abandoned" \
    rr alice bind-pr --run-id run-b --number 45 --url https://example.test/pr/45 --at 2026-01-01T00:03:00Z
cmp -s "$state/runs/run-b/run.json" "$tmp/run-b-closed.json" || fail "a write after a non-promotion close changed run.json"
pass "after a non-promotion close, every write is refused and the record is unchanged"

new_run run-e
write_plan s12 19:run-e
(cd "$repo" && node "$writer" transition --slate s12 --session alice --run-id run-e --stage claim --exit k --at 2026-01-01T00:05:00Z) >/dev/null
cp "$state/runs/run-e/run.json" "$tmp/run-e.json"
expect_refused "close before the active stage" "before the active stage claim began" \
    bash -c "cd '$repo' && node '$writer' close --slate s12 --session alice --run-id run-e --outcome abandoned --exit x --at 2026-01-01T00:04:00Z"
cmp -s "$state/runs/run-e/run.json" "$tmp/run-e.json" || fail "a close dated before the active stage changed run.json"
(cd "$repo" && node "$writer" lock release --slate s12 --session alice) >/dev/null
pass "a close dated before the active stage began is refused"

# -- remediation push record (harmon-devkit#1386) ------------------------------
new_run run-f
write_plan s13 20:run-f
rf() { (cd "$repo" && node "$writer" transition --slate s13 --session alice --run-id run-f "$@"); }
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
(cd "$repo" && node "$writer" lock release --slate s13 --session alice) >/dev/null
pass "a remediation push is recorded on the integration re-entry, and refused anywhere else"

# -- linked worktree resolves the common directory -----------------------------
git -C "$repo" worktree add -q "$tmp/lane" -b lane
new_run run-d
(cd "$tmp/lane" && node "$writer" transition --slate s1 --session alice --run-id run-d --stage claim --exit k --at 2026-01-01T00:01:00Z) >/dev/null
[ "$(jq -r '.stage_transitions[-1].stage' "$state/runs/run-d/run.json")" = "claim" ] ||
    fail "a linked worktree did not write the common directory's record"
pass "a linked worktree writes the common directory's record"

# -- release ---------------------------------------------------------------
cp "$state/locks/s4.json" "$tmp/held-lock.json"
force_rc=0
(cd "$repo" && node "$writer" lock release --slate s4 --session alice --force) >"$tmp/no-reason.log" 2>&1 || force_rc=$?
[ "$force_rc" -eq 2 ] || fail "force release without a reason was not a usage error"
cmp -s "$state/locks/s4.json" "$tmp/held-lock.json" || fail "missing reason changed the held lock"

# An unwritable audit destination must leave the old session's reservation.
mkdir -p "$state/locks/recoveries"
printf 'blocked\n' >"$state/locks/recoveries/s4"
force_rc=0
(cd "$repo" && node "$writer" lock release --slate s4 --session alice --force --reason 'dead session') >"$tmp/audit-failure.log" 2>&1 || force_rc=$?
[ "$force_rc" -ne 0 ] || fail "force release succeeded without its audit"
cmp -s "$state/locks/s4.json" "$tmp/held-lock.json" || fail "audit failure released the lock"
rm "$state/locks/recoveries/s4"
(cd "$repo" && node "$writer" lock release --slate s4 --session alice --force --reason "dead session") >/dev/null
[ ! -e "$state/locks/s4.json" ] || fail "force release left the lock"
audits=("$state/locks/recoveries/s4/"*.json)
[ "${#audits[@]}" -eq 1 ] && [ -f "${audits[0]}" ] || fail "force release did not leave exactly one audit"
jq -e --slurpfile held "$tmp/held-lock.json" '
    .action == "force-release" and .session == "alice" and .reason == "dead session" and
    .lock == $held[0] and (.at | test("Z$"))
' "${audits[0]}" >/dev/null || fail "recovery audit lost attribution, reason, time or the old lock"
(cd "$repo" && node "$writer" lock acquire --slate s4 --session alice --milestone 8 --issues 15) >/dev/null
[ "$(lock_scope s4)" = "alice:8:15" ] || fail "new session could not acquire after explicit recovery"
(cd "$repo" && node "$writer" lock release --slate s4 --session alice) >/dev/null
(cd "$repo" && node "$writer" lock release --slate s1 --session alice) >/dev/null
[ ! -e "$state/locks/s1.json" ] || fail "holder release left the lock"
pass "explicit recovery requires a reason, retains an audit before release, and permits normal reacquisition"

no_candidates "suite"
echo "test-run-record: all cases passed"
