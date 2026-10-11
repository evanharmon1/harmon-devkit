#!/usr/bin/env bash
# test-run-record.sh — behavioral tests for run-record.mjs, the dev-flow v2
# run-record writer and slate lock (harmon-devkit#1296).
#
# Every case runs inside a temporary fixture repository: the writer resolves
# its state root from the current directory's Git common directory, and the
# Git environment is scrubbed first so a hook-exported GIT_DIR can never point
# it at a real clone's dev-flow-v2 tree.
#
# Run from scripts/test-skills.sh (task test:skills) and task test:run-record.
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

# write_plan SLATE ISSUE:RUN... — the minimal plan shape the writer reads:
# the latest revision's issue numbers and lane run ids.
write_plan() {
    local slate="$1"
    shift
    mkdir -p "$state/slates/$slate"
    printf '%s\n' "$@" | jq -R 'split(":") | {issue: (.[0]|tonumber), run: .[1]}' | jq -s '{
      schema: 1, slate_id: "'"$slate"'",
      revisions: [{plan: {issues: map({number: .issue}), lanes: map(select(.run != "") | {run_id: .run, issue})}}]
    }' >"$state/slates/$slate/plan.json"
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
new_run run-z
cp "$state/runs/run-z/run.json" "$tmp/run-z.json"
expect_refused "run outside the plan" "run run-z is not a lane in any revision of slate s1's plan" \
    rr alice transition --run-id run-z --stage claim --exit kicked --at 2026-01-01T00:01:00Z
cmp -s "$state/runs/run-z/run.json" "$tmp/run-z.json" || fail "a refused foreign run changed its record"
pass "a write naming a run that is not a lane of the locked slate's plan is refused, record unchanged"

expect_refused "issues disagreeing with the plan" "disagrees with slate s1's plan" \
    bash -c "cd '$repo' && node '$writer' lock acquire --slate s1 --session alice --issues 11"
pass "--issues that disagree with the plan are refused"

# -- transitions -----------------------------------------------------------
rr alice transition --run-id run-a --stage claim --exit "resolved" --at 2026-01-01T00:01:00Z >/dev/null
[ "$(jq -r '.stage_transitions | map(.stage) | join(",")' "$run")" = "kickoff,claim" ] || fail "claim transition not recorded"
[ "$(jq -r '.stage_transitions[0].exit' "$run")" = "resolved" ] || fail "previous stage exit not recorded"
[ "$(jq -c '.receipts' "$run")" = '[{"kind":"transition","stage":"claim","entered_at":"2026-01-01T00:01:00Z"}]' ] ||
    fail "transition did not append its matching receipt"
pass "transition appends the stage and its receipt, and closes the previous exit"
[ "$(lock_scope s1)" = "alice:7:11,12,13,14" ] || fail "lock scope not re-derived from the plan: $(lock_scope s1)"
pass "every write re-derives the lock's issue set from the plan"

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
pass "a second slate cannot write a run another slate owns, even when its plan names it"

mkdir -p "$state/slates/s7"
printf 'not json\n' >"$state/slates/s7/plan.json"
rr alice intervention --run-id run-a --kind other --note "unaffected" --at 2026-01-01T00:03:40Z >/dev/null ||
    fail "an unrelated or malformed plan.json elsewhere blocked the owning slate"
pass "an unrelated, even malformed, plan.json elsewhere does not block the owner"

# -- interventions and ruling digests -------------------------------------
mkdir -p "$state/slates/s1/orchestrator/run-a/a1"
ruling="$state/slates/s1/orchestrator/run-a/a1/ruling-1.md"
printf 'Ruling 1: keep the scope.\n' >"$ruling"
rr alice intervention --run-id run-a --kind other --note "scope ruling" --ruling "$ruling" --at 2026-01-01T00:04:00Z >/dev/null
digest="$(sha256_file "$ruling")"
note="$(jq -r '.interventions[-1].note' "$run")"
[ "$note" = "scope ruling [ruling dev-flow-v2/slates/s1/orchestrator/run-a/a1/ruling-1.md sha256=$digest]" ] ||
    fail "ruling digest not recorded: $note"
pass "an intervention pointing at a ruling file records its SHA-256"

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
node "$asset_dir/validate-result-schemas.mjs" run "$state/runs/run-c/run.json" --receipts "$state/runs/run-c/run.json" \
    --adjudication "$state/runs/run-c/adjudications/challenge-r1.json" >/dev/null ||
    fail "strict validation with the challenge adjudication fails after the writer's transitions"
pass "transitions written after an adjudication keep strict --receipts validation passing"
rr alice bind-pr --run-id run-c --number 44 --url https://example.test/pr/44 --at 2026-01-01T00:05:00Z >/dev/null
expect_refused "promotion over an unsettled deferred finding" "has no settlement" \
    rr alice promote --run-id run-c --head "$(printf '%040d' 0 | tr 0 a)" --fingerprint fp --at 2026-01-01T00:10:00Z
pass "a promotion over an unsettled deferred finding is refused"
head_sha="$(printf '%040d' 0 | tr 0 a)"
expect_refused "promotion before last transition" "must not be before the last stage_transitions entry" \
    rr alice promote --run-id run-a --head "$head_sha" --fingerprint fp --at 2026-01-01T00:02:30Z
pass "a promotion dated before the last transition is refused"

rr alice promote --run-id run-a --head "$head_sha" --fingerprint fp --at 2026-01-01T00:10:00Z >/dev/null
[ "$(jq -r '.outcome + ":" + .promotion.promoted_at + ":" + (.outcome_transitions|length|tostring)' "$run")" = \
    "ready-for-review:2026-01-01T00:10:00Z:1" ] || fail "promotion not recorded"
pass "promotion records the promotion, the outcome chain and the projection"

expect_refused "intervention after promotion" "after promotion.promoted_at" \
    rr alice intervention --run-id run-a --kind other --note late --at 2026-01-01T00:11:00Z
expect_refused "pr binding after promotion" "after promotion.promoted_at" \
    rr alice bind-pr --run-id run-a --number 43 --url https://example.test/pr/43 --at 2026-01-01T00:11:00Z
expect_refused "transition after promotion" "run already ended" \
    rr alice transition --run-id run-a --stage implement --at 2026-01-01T00:11:00Z
pass "every entry dated after the promotion is refused"

rr alice intervention --run-id run-a --kind asked --note "backfilled answer" --at 2026-01-01T00:09:00Z >/dev/null
pass "a backfilled intervention dated before the promotion is still accepted"

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
[ "$(sha256_file "$state/runs/run-a/orchestrator/a1/ruling-1.md")" = "$digest" ] || fail "archived ruling changed"
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

# -- linked worktree resolves the common directory -----------------------------
git -C "$repo" worktree add -q "$tmp/lane" -b lane
new_run run-d
(cd "$tmp/lane" && node "$writer" transition --slate s1 --session alice --run-id run-d --stage claim --exit k --at 2026-01-01T00:01:00Z) >/dev/null
[ "$(jq -r '.stage_transitions[-1].stage' "$state/runs/run-d/run.json")" = "claim" ] ||
    fail "a linked worktree did not write the common directory's record"
pass "a linked worktree writes the common directory's record"

# -- release ---------------------------------------------------------------
(cd "$repo" && node "$writer" lock release --slate s4 --session alice --force --reason "dead session") >/dev/null
[ ! -e "$state/locks/s4.json" ] || fail "force release left the lock"
(cd "$repo" && node "$writer" lock release --slate s1 --session alice) >/dev/null
[ ! -e "$state/locks/s1.json" ] || fail "holder release left the lock"
pass "the holder releases its lock; --force --reason breaks another session's"

no_candidates "suite"
echo "test-run-record: all cases passed"
