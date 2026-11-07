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
gate_document="$tmp/readiness-pass.json"
printf '%s\n' '{"status":"pass","condition":"ready","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fingerprint":"fp"}' >"$gate_document"
trap 'rm -rf "$tmp"' EXIT

source_root="$(git -C "$asset_dir" rev-parse --show-toplevel)"
# Execute tools from a current, isolated Git root, independent of the outer branch.
tool_root="${tmp}/tool-root"
mkdir -p "$tool_root"
cp -R "${source_root}/ai" "$tool_root/ai"
cp "${source_root}/.devflow.toml" "${source_root}/agent-registry.json" "$tool_root/"
git init -q -b main "$tool_root"
git -C "$tool_root" add ai .devflow.toml agent-registry.json
git -C "$tool_root" -c user.name=test -c user.email=test@example.test commit -qm 'controlled executing tools'
git -C "$tool_root" update-ref refs/remotes/origin/main HEAD
git -C "$tool_root" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
asset_dir="$tool_root/ai/skills/universal/dev-flow-support/assets"
writer="$asset_dir/run-record.mjs"
monitor="$asset_dir/../../orchestrate/assets/dev-flow-monitor.sh"

# Capacity reads remain offline; these lifecycle fixtures carry no live claims
# or open deliveries. Capacity boundary behavior lives in test:provision-lane.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = "issue" ]; then
    printf '%s\n' '{"state":"OPEN","labels":[]}'
elif [ "$1" = "label" ] && [ "$2" = "list" ]; then
    printf '[]\n'
elif [ "$1" = "api" ]; then
    api_path=""
    for arg in "$@"; do
        case "$arg" in
        repos/example/repo/issues/334 | repos/example/repo/issues/334/comments | repos/example/repo/issues/334/timeline | \
            repos/owner/b/issues/7 | repos/owner/b/issues/7/comments | repos/owner/b/issues/7/timeline)
            api_path="$arg"
            ;;
        esac
    done
    case "$api_path" in
    repos/example/repo/issues/334 | repos/owner/b/issues/7)
        printf '%s\n' '{"state":"open","labels":[],"assignees":[]}'
        ;;
    repos/example/repo/issues/334/comments | repos/example/repo/issues/334/timeline | \
        repos/owner/b/issues/7/comments | repos/owner/b/issues/7/timeline)
        printf '[]\n'
        ;;
    *)
        printf '{"state":"%s"}\n' "${RUN_RECORD_PR_STATE:-MERGED}"
        ;;
    esac
else
    printf '{"state":"%s"}\n' "${RUN_RECORD_PR_STATE:-MERGED}"
fi
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# plan-revise calls the existing restoration helper at its supported boundary.
# This test verifies that resolved claim inputs are passed without doing any
# external claim writes; the helper's transaction semantics are covered by its
# dedicated suite.
claim_record_file="$tmp/retained-claim-record.md"
claim_registry_snapshot="$tmp/retained-claim-registry.json"
claim_transaction_log="$tmp/claim-transaction-calls.log"
printf '%s\n' 'Claiming — starting implementation on branch 334-l (session fixture).' >"$claim_record_file"
printf '%s\n' '{"families":[{"slug":"gpt"}]}' >"$claim_registry_snapshot"
: >"$claim_transaction_log"
export RUN_RECORD_CLAIM_TXN_LOG="$claim_transaction_log"
cat >"$tool_root/ai/skills/universal/claim/assets/claim-transaction.sh" <<'CLAIM_TXN'
#!/usr/bin/env bash
set -euo pipefail
{
    printf 'restore'
    for arg in "$@"; do printf ' %s' "$arg"; done
    printf '\n'
} >>"${RUN_RECORD_CLAIM_TXN_LOG:?}"
CLAIM_TXN
chmod +x "$tool_root/ai/skills/universal/claim/assets/claim-transaction.sh"

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

repo="$tmp/repo"
git init -q -b main "$repo"
git -C "$repo" config user.name t
git -C "$repo" config user.email t@t
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf '{"trusted_orchestrator_actor_ids": [12345]}\n' >"$repo/agent-registry.json"
git -C "$repo" add agent-registry.json
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m registry

# The public writer's canonical checker resolves its helper from the physical
# writer path. Seed the unmodified runtime closure before any reviewed head so
# freshness, registry lookup, and the carry graph use one fixture repository.
fixture_support="$repo/ai/skills/universal/dev-flow-support"
fixture_integrate="$repo/ai/skills/universal/integrate"
mkdir -p "$fixture_support" "$fixture_integrate" "$repo/ai"
cp -R "$asset_dir" "$fixture_support/assets"
cp -R "$asset_dir/../../integrate/assets" "$fixture_integrate/assets"
# The validator defaults to its vendored schema copy, but preserve the
# authoring schemas too so every module-relative validation dependency remains
# available without replacing this fixture's intentionally local registry.
cp -R "$asset_dir/../../../../schemas" "$repo/ai/schemas"
git -C "$repo" add ai/schemas ai/skills/universal/dev-flow-support/assets ai/skills/universal/integrate/assets
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "test: seed integration runtime fixture"
capture_writer="$fixture_support/assets/run-record.mjs"
# Guarded activation requires a known, current default-branch tip (#1722).
git -C "$repo" update-ref refs/remotes/origin/main HEAD
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
state="$repo/.git/dev-flow-v2"

# The state root must be this fixture's, never the clone running the test.
resolved="$(cd "$repo" && git rev-parse --path-format=absolute --git-common-dir)"
[ "$resolved" = "$repo/.git" ] || fail "fixture common dir resolved to $resolved"

new_record() {
    local run_id="$1"
    mkdir -p "$state/runs/$run_id"
    jq -n --arg id "$run_id" '{
      schema: 2, run_id: $id, initiated_by: "human",
      dispatch_admission: {slate: "fixture", working: 1, in_flight: 1, at: "2026-01-01T00:00:00Z"},
      started_at: "2026-01-01T00:00:00Z",
      stage_transitions: [{stage: "kickoff", entered_at: "2026-01-01T00:00:00Z"}],
      interventions: [], outcome: null, pr: null,
      evidence_comments: [], evidence_registrations: [], pr_bindings: [],
      outcome_transitions: [], settlements: [], promotion: null, receipts: []
    }' >"$state/runs/$run_id/run.json"
}

new_run() {
    local run_id="$1" branch active_state registry_revision
    new_record "$run_id"
    printf 'fixture\n' >"$state/runs/$run_id/owner-slate"
    branch="fixture-$run_id"
    active_state="$("$monitor" active-path --branch "$branch" --repo-root "$repo")"
    registry_revision="$(git -C "$repo" rev-parse HEAD)"
    "$monitor" activate --active-state "$active_state" --run-id "$run_id" --branch "$branch" \
        --expected-predecessor absent --expected-generation 0 --registry-revision "$registry_revision" \
        --writer feature-owner --repo-root "$repo" >/dev/null
    rm "$state/runs/$run_id/owner-slate"
}

# Capture acquisition stdout; never recover tokens from status or the lock file.
token_for() { cat "$tmp/token-$1" 2>/dev/null || true; }
pointer_for_run() { "$monitor" active-path --branch "fixture-$1" --repo-root "$repo"; }

# Null-cycle admission consumes a complete resolved projection. Build fixture
# projections through the production reader rather than hand-authoring a
# partial object that can accidentally turn review off.
resolve_fixture_policy() {
    local destination="$1" integration="$2" trigger="${3:-after-ci}" profile="${4:-}" source="$tmp/resolved-policy.toml"
    local policy_source="$asset_dir/../../../../../.devflow.toml"
    if [ "$profile" = "optional-codex" ]; then
        sed -E "s/^[[:space:]]*integration[[:space:]]*=[[:space:]]*[0-9]+/integration = $integration/;s/^[[:space:]]*review_trigger[[:space:]]*=[[:space:]]*\"after-ci\"/review_trigger = \"$trigger\"/" \
            "$policy_source" | sed '/^review_trigger[[:space:]]*=/a\
finder = [{ id = "codex-cloud", gates = false, budget = 1 }]' >"$source"
    elif [ "$profile" = "optional-codex-required-copilot" ]; then
        sed -E "s/^[[:space:]]*integration[[:space:]]*=[[:space:]]*[0-9]+/integration = $integration/;s/^[[:space:]]*review_trigger[[:space:]]*=[[:space:]]*\"after-ci\"/review_trigger = \"$trigger\"/" \
            "$policy_source" | awk '
                /^\[stage\.integration\]$/ { integration = 1 }
                /^\[/ && $0 != "[stage.integration]" { integration = 0 }
                integration && /^[[:space:]]*finders[[:space:]]*=/ { print "finders = [\"codex-cloud\", \"copilot-cloud\"]"; next }
                { print }
            ' | sed -E '/^review_trigger[[:space:]]*=/a finder = [{ id = "codex-cloud", gates = false, budget = 1 }, { id = "copilot-cloud", gates = true, budget = 1 }]' >"$source"
    else
        sed -E "s/^[[:space:]]*integration[[:space:]]*=[[:space:]]*[0-9]+/integration = $integration/;s/^[[:space:]]*review_trigger[[:space:]]*=[[:space:]]*\"after-ci\"/review_trigger = \"$trigger\"/" \
            "$policy_source" >"$source"
    fi
    # List real Taskfile targets from the source checkout; executing tools stay isolated.
    node "$asset_dir/devflow-policy.mjs" resolve --policy "$source" --registry "$asset_dir/../../../../../agent-registry.json" \
        --taskfile-dir "$source_root" --json >"$destination"
}
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

expect_usage() {
    local label="$1" pattern="$2"
    shift 2
    local output rc=0
    output="$("$@" 2>&1)" || rc=$?
    [ "$rc" -eq 2 ] || fail "$label: expected usage error (exit 2), got $rc: $output"
    grep -qF -- "$pattern" <<<"$output" || fail "$label: usage error did not mention '$pattern': $output"
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
    PLAN_SLATE="$slate" PLAN_LANES="$*" PLAN_WRITER="$writer" PLAN_REVIEWER_TIER="${PLAN_REVIEWER_TIER:-frontier}" node --input-type=module -e '
      const { chainDigest } = await import(process.env.PLAN_WRITER)
      const entries = process.env.PLAN_LANES.split(" ").map((pair) => pair.split(":"))
      const policy = {
        rigor: "deep", rigor_source: "default",
        caps: { challenge: 1, review: 1, integration: 1, remediation: 1, min_rounds: 1, wall_clock_min: 60 },
        breadth: { max_agent_runs: 20, max_parallel_agents: 1 },
        strategy: "plan", strategy_source: "default",
        role_tiers: { orchestrator: "apex", implementer: "frontier", challenger: "apex", reviewer: process.env.PLAN_REVIEWER_TIER, integrator: "economy" },
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
    bash -c "cd '$repo' && node '$writer' promote --slate s6 --session alice --owner-token \"$(token_for s6)\" --run-id run-a --head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --fingerprint fp --gate \"$gate_document\" --at 2026-01-01T00:03:30Z"
expect_refused "promotion precheck foreign owner" "run run-a is owned by slate s1, not s6" \
    bash -c "cd '$repo' && node '$writer' promote --check --slate s6 --session alice --owner-token \"$(token_for s6)\" --run-id run-a --head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --fingerprint fp --gate \"$gate_document\" --at 2026-01-01T00:03:30Z"
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
    bash -c "cd '$repo' && node '$writer' promote --slate s10 --session carol --owner-token \"$(token_for s10)\" --run-id run-u --head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --fingerprint fp --gate \"$gate_document\" --at 2026-01-01T00:01:00Z"
expect_refused "promotion precheck outside plan" "run run-u is not a lane in any revision of slate s10's plan" \
    bash -c "cd '$repo' && node '$writer' promote --check --slate s10 --session carol --owner-token \"$(token_for s10)\" --run-id run-u --head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --fingerprint fp --gate \"$gate_document\" --at 2026-01-01T00:01:00Z"
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

# The generic intervention writer must not mint the note shape that the
# integration authority reader accepts; only integration-review-capture runs
# the live checks that make such a ruling authority.
forged_authority="$tmp/forged-authority.json"
printf '{"schema":1,"kind":"attach"}\n' >"$forged_authority"
forged_digest="$(sha256_file "$forged_authority")"
cp "$run" "$tmp/forged-authority-before.json"
expect_refused "generic intervention refuses an integration authority note" "recorded only by integration-review-capture" \
    rr alice intervention --run-id run-a --kind other --note "integration-review-authority v1 attach sha256=$forged_digest" --ruling "$forged_authority" --at 2026-01-01T00:04:00Z
cmp -s "$run" "$tmp/forged-authority-before.json" || fail "a refused authority-shaped intervention changed run.json"
pass "the generic intervention command cannot forge retained integration authority"

# A generic ruling has no live-comment authentication, so it cannot publish
# admission-shaped bytes for the exit reader to trust.
forged_pre_cycle_admission="$tmp/forged-pre-cycle-admission.json"
printf '%s\n' '{"schema":1,"kind":"pre-cycle-remediation-admission","run_id":"run-a","transition_index":1,"remediation_head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","findings":[{}]}' >"$forged_pre_cycle_admission"
cp "$run" "$tmp/forged-pre-cycle-admission-before.json"
expect_refused "generic intervention refuses a pre-cycle admission artifact" "authenticated transition writer" \
    rr alice intervention --run-id run-a --kind other --note "forged admission" --ruling "$forged_pre_cycle_admission" --at 2026-01-01T00:04:00Z
cmp -s "$run" "$tmp/forged-pre-cycle-admission-before.json" || fail "a refused pre-cycle admission changed run.json"
[ ! -e "$state/runs/run-a/rulings/$(sha256_file "$forged_pre_cycle_admission")" ] || fail "a refused pre-cycle admission left a generic ruling"
pass "the generic intervention command cannot forge retained pre-cycle admission evidence"

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
    rr alice promote --run-id run-c --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:02:30Z
[ -e "$(pointer_for_run run-c)" ] || fail "a refused promotion retired the active pointer"
pass "a promotion dated before the last transition is refused"
node "$asset_dir/validate-result-schemas.mjs" run "$state/runs/run-c/run.json" --receipts "$state/runs/run-c/run.json" \
    --adjudication "$state/runs/run-c/adjudications/challenge-r1.json" >/dev/null ||
    fail "strict validation with the challenge adjudication fails after the writer's transitions"
pass "transitions written after an adjudication keep strict --receipts validation passing"
rr alice bind-pr --run-id run-c --number 44 --url https://example.test/pr/44 --at 2026-01-01T00:05:00Z >/dev/null
cp "$state/runs/run-c/run.json" "$tmp/before-unsettled-promotion.json"
expect_refused "promotion over an unsettled deferred finding" "has no settlement" \
    rr alice promote --run-id run-c --head "$(printf '%040d' 0 | tr 0 a)" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:10:00Z
cmp -s "$state/runs/run-c/run.json" "$tmp/before-unsettled-promotion.json" ||
    fail "a refused promotion over an unsettled finding changed the canonical record"
pass "a promotion over an unsettled deferred finding is refused with a byte-identical canonical record"
cp "$run" "$tmp/before-promotion.json"
expect_refused "promotion before PR binding" "before PR binding #42" \
    rr alice promote --run-id run-a --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:04:30Z
cmp -s "$run" "$tmp/before-promotion.json" || fail "a backfilled promotion changed the record"
rr alice bind-pr --run-id run-a --number 46 --url https://example.test/pr/46 --at 2026-01-01T00:10:00Z >/dev/null
cp "$run" "$tmp/before-promotion.json"
expect_refused "promotion before a later PR binding" "before PR binding #46" \
    rr alice promote --run-id run-a --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:09:00Z
cmp -s "$run" "$tmp/before-promotion.json" || fail "a promotion before a later binding changed the record"
pass "promotion cannot predate the initial or a later PR binding"

# --check exercises the exact promotion candidate without leaving an owner,
# lock, candidate, record, or active-pointer side effect behind.
cp "$state/locks/s1.json" "$tmp/lock-before-scope-precheck.json"
jq '.issues = [11, 12]' "$state/locks/s1.json" >"$tmp/lock-narrow.json"
mv "$tmp/lock-narrow.json" "$state/locks/s1.json"
cp -R "$state" "$tmp/state-before-scope-precheck"
rr alice promote --check --run-id run-a --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:10:00Z \
    --issues 11,12,13,14 >/dev/null
diff -r "$state" "$tmp/state-before-scope-precheck" >/dev/null ||
    fail "an accepted scope-change promotion precheck changed durable state"
cp "$tmp/lock-before-scope-precheck.json" "$state/locks/s1.json"
cp -R "$state" "$tmp/state-before-promote-check"
rr alice promote --check --run-id run-a --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:10:00Z >/dev/null
diff -r "$state" "$tmp/state-before-promote-check" >/dev/null ||
    fail "a successful promotion precheck changed durable state"
no_candidates "successful promotion precheck"
expect_refused "precheck promotion before a later PR binding" "before PR binding #46" \
    rr alice promote --check --run-id run-a --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:09:00Z
diff -r "$state" "$tmp/state-before-promote-check" >/dev/null ||
    fail "a refused promotion precheck changed durable state"
no_candidates "refused chronology promotion precheck"
cp -R "$state" "$tmp/state-before-unsettled-promote-check"
expect_refused "precheck promotion over an unsettled deferred finding" "has no settlement" \
    rr alice promote --check --run-id run-c --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:10:00Z
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
promotion_parity invalid-head 2 '--head must be a 40-hex SHA' --head nope --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:10:00Z
promotion_parity missing-fingerprint 2 '--fingerprint is required' --head "$head_sha" --at 2026-01-01T00:10:00Z
promotion_parity invalid-at 2 '--at must be a UTC timestamp' --head "$head_sha" --fingerprint fp --gate "$gate_document" --at nope
promotion_parity wrong-token 1 'owner token does not match' --owner-token wrong --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:10:00Z
# Missing, unreadable, malformed, failed and mismatched evidence refuses both paths.
promotion_parity absent-gate 1 '--gate readiness pass document is required' --head "$head_sha" --fingerprint fp --at 2026-01-01T00:10:00Z
promotion_parity unreadable-gate 1 'readiness gate document not found' --head "$head_sha" --fingerprint fp --gate "$tmp/missing.json" --at 2026-01-01T00:10:00Z
invalid_gate_index=0
for invalid_gate in 'null' '[]' '{' \
    '{"status":"fail","condition":"ready","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fingerprint":"fp"}' \
    '{"status":"pass","condition":"ready","head":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","fingerprint":"fp"}' \
    '{"status":"pass","condition":"ready","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fingerprint":"other"}' \
    '{"status":"pass","condition":"fingerprint","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fingerprint":"fp"}'; do
    printf '%s\n' "$invalid_gate" >"$tmp/invalid-gate.json"
    invalid_gate_index=$((invalid_gate_index + 1))
    promotion_parity "invalid-gate-$invalid_gate_index" 1 'readiness gate document' --head "$head_sha" --fingerprint fp --gate "$tmp/invalid-gate.json" --at 2026-01-01T00:10:00Z
done
jq '.condition = "promoted"' "$gate_document" >"$tmp/promoted-pass.json"
rr alice promote --check --run-id run-a --head "$head_sha" --fingerprint fp --gate "$tmp/promoted-pass.json" --at 2026-01-01T00:10:00Z >/dev/null
pass "full promoted-mode pass supports reconciliation with the same document checks"
cp "$run" "$tmp/run-before-invalid-schema.json"
jq '.schema = 99' "$run" >"$tmp/run-invalid-schema.json"
mv "$tmp/run-invalid-schema.json" "$run"
promotion_parity invalid-existing-schema 1 'failed `run` validation' --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:10:00Z
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
    bash -c "cd '$repo' && RUN_RECORD_OWNER_TOKEN='$(token_for s1)' node --require '$cleanup_preload' '$writer' promote --check --slate s1 --session alice --run-id run-a --head '$head_sha' --fingerprint fp --gate \"$gate_document\" --at 2026-01-01T00:10:00Z"
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
    owner_token="$(token_for s1)" head="$head_sha" gate_document="$gate_document" gate_fingerprint=fp promoted_at=2026-01-01T00:10:00Z \
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
    rr alice promote --run-id run-a --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:11:00Z
expect_refused "promotion precheck after promotion" "run already ended with outcome ready-for-review" \
    rr alice promote --check --run-id run-a --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:11:00Z
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

# The documented unexplained-promotion reconciliation is a mutating write,
# using the promoted-mode gate pass and retaining the original event in --exit.
reconcile_started_at="$(date -u +%s)"
new_run run-d
rr alice transition --run-id run-d --stage claim --exit fixture --at 2026-01-01T00:01:00Z >/dev/null
walk run-d
rr alice bind-pr --run-id run-d --number 47 --url https://example.test/pr/47 --at 2026-01-01T00:05:00Z >/dev/null
rr alice promote --run-id run-d --head "$head_sha" --fingerprint fp --gate "$tmp/promoted-pass.json" \
    --exit "reconciled ready_for_review event 123 at 2026-01-01T00:06:00Z" >/dev/null
jq -e --arg head "$head_sha" '.outcome == "ready-for-review" and .promotion.head == $head and .promotion.gate_fingerprint == "fp"' \
    "$state/runs/run-d/run.json" >/dev/null || fail "documented promoted-pass reconciliation did not close the run"
jq -e '.stage_transitions[-1].exit == "reconciled ready_for_review event 123 at 2026-01-01T00:06:00Z"' \
    "$state/runs/run-d/run.json" >/dev/null || fail "reconciliation did not retain the recipe exit text"
jq -e --argjson started "$reconcile_started_at" '
    (.promotion.promoted_at | type == "string" and length > 0) and
    ((.promotion.promoted_at | fromdateiso8601) >= $started)' \
    "$state/runs/run-d/run.json" >/dev/null || fail "reconciliation without --at did not record the write time"
pass "the documented non-check reconciliation records a promoted pass and ends the run ready-for-review"

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
    # Guarded activation requires the default tip in this independent fixture too.
    git -C "$repo" update-ref refs/remotes/origin/main HEAD
    git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
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
# A remediation transition needs the original PR and a real branch worktree.
printf '{"branch":"main"}\n' >"$state/runs/run-f/branch.json"
(cd "$repo" && RUN_RECORD_OWNER_TOKEN="$(token_for s13)" node "$writer" bind-pr --slate s13 --session alice --run-id run-f --number 493 --url https://github.com/example/repo/pull/493 --at 2026-01-01T00:06:30Z) >/dev/null
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
integration_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" branch "$integration_branch" "$integration_base"
git -C "$repo" checkout -q "$integration_branch"
printf 'reviewed carry fixture\n' >"$repo/reviewed-carry.txt"
git -C "$repo" add reviewed-carry.txt
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "reviewed carry fixture"
mkdir -p "$state/runs/run-integrator/passes" "$state/runs/run-integrator/adjudications"
printf '{"branch":"%s"}\n' "$integration_branch" >"$state/runs/run-integrator/branch.json"
resolve_fixture_policy "$state/runs/run-integrator/policy.json" 0
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
expect_refused "integrator receipt with a pending review after CI settled" "is not a completed observation" \
    rri receipt --run-id run-integrator --pass "$tmp/integration-pending-review.json"
jq '.payload.checks[0].bucket = "pass" | .payload.verdict = "pending" |
    .payload.codex_cycle = {head:.head,cycle:1,attempt:2,trigger_comment_id:"1001",exit_code:12} |
    del(.payload.applied_dispositions)' \
    "$integration_pass" >"$tmp/integration-retrying-review.json"
expect_refused "integrator receipt while a review retry is pending" "is not a completed observation" \
    rri receipt --run-id run-integrator --pass "$tmp/integration-retrying-review.json"
# An integrator may report findings while one finder is still pending, or while
# the Codex reader has a transient failure.  Those are useful live diagnostics,
# but neither is a completed observation that the public writer may retain.
jq '.payload.verdict = "findings" | .payload.findings = [{id:"integration-r1-human-1",body:"human finding",source_id:"1004"}] |
    .payload.finder_cycles = [{finder:"coderabbit-cloud",head:.head,cycle:1,attempt:1,exit_code:11}] |
    del(.payload.applied_dispositions)' \
    "$integration_pass" >"$tmp/integration-pending-finder.json"
expect_refused "integrator receipt with a pending finder after CI settled" "finder_cycles[0] (coderabbit-cloud): checker exit_code 11 is not a completed observation" \
    rri receipt --run-id run-integrator --pass "$tmp/integration-pending-finder.json"
jq '.payload.verdict = "findings" | .payload.findings = [{id:"integration-r1-human-1",body:"human finding",source_id:"1004"}] |
    .payload.codex_cycle = {head:.head,cycle:1,attempt:1,trigger_comment_id:"1001",exit_code:16} |
    del(.payload.applied_dispositions)' \
    "$integration_pass" >"$tmp/integration-transient-codex.json"
expect_refused "integrator receipt with a transient Codex read after CI settled" "codex_cycle: checker exit_code 16 is not a completed observation" \
    rri receipt --run-id run-integrator --pass "$tmp/integration-transient-codex.json"
[ ! -e "$state/runs/run-integrator/passes/integration-r1-integrator.json" ] ||
    fail "an incomplete observation consumed the immutable integration receipt slot"
jq '.payload.codex_cycle={head:.head,cycle:3,attempt:1,trigger_comment_id:"200",exit_code:0}' "$integration_pass" >"$tmp/integration-gap.json"
expect_refused "uncaptured cycle/carry/released reservation cannot silently skip ordinal history" "integration-history-incomplete" \
    rri receipt --run-id run-integrator --pass "$tmp/integration-gap.json"
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

# The public owner-only capture command must retain a complete reserve/attach
# chain as immutable rulings; receipt authentication reads those bytes rather
# than mutable checker state. Stub only the live observations this command owns.
capture_bin="$tmp/capture-bin"
mkdir -p "$capture_bin"
cat >"$capture_bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'repos/example/repo/issues/comments/'*'/reactions?per_page=100'*)
    if [ "${CAPTURE_CLEAN:-}" = 1 ]; then
      printf '[[{"id":901,"content":"+1","created_at":"%s","user":{"id":199175422,"login":"chatgpt-codex-connector[bot]","type":"Bot"}}]]\n' "${CAPTURE_REACTION_AT:-2026-10-01T00:22:00Z}"
    else
      printf '%s\n' '[[]]'
    fi ;;
  *'pr view 493 --repo example/repo --json baseRefOid --jq .baseRefOid'*)
    printf '%s\n' "${CAPTURE_BASE:?}" ;;
  *'pr view 493 --repo example/repo --json state,isDraft,headRefOid'*)
    printf '{"state":"OPEN","isDraft":true,"headRefOid":"%s"}\n' "${CAPTURE_HEAD:?}" ;;
  *'pr view 493 --repo example/repo --json headRefOid,state'*)
    printf '{"state":"OPEN","headRefOid":"%s"}\n' "${CAPTURE_HEAD:?}" ;;
  *'contents/agent-registry.json?ref='*)
    if [ "${CAPTURE_CUSTOM:-}" = 1 ] && [ "${CAPTURE_CODEX_SETTLEMENT:-}" != 1 ]; then cat "$(dirname "$0")/custom-registry.b64"; else cat "$(dirname "$0")/registry.b64"; fi ;;
  *'repos/example/repo/issues/comments/902'*)
    jq -n --arg head "${CAPTURE_HEAD:?}" --argjson actor "${CAPTURE_CUSTOM_ACTOR:-175728472}" --arg suffix "${CAPTURE_CUSTOM_SUFFIX:-}" \
      '{id:902,body:("**P2** custom finding" + $suffix + "\n\n**Reviewed commit:** `" + $head + "`"),issue_url:"https://api.github.com/repos/example/repo/issues/493",created_at:"2026-10-01T00:22:00Z",updated_at:"2026-10-01T00:22:00Z",user:{id:$actor,login:(if $actor == 199175422 then "chatgpt-codex-connector[bot]" else "Copilot" end),type:"Bot"}}' ;;
  *'repos/example/repo/issues/comments/200'*)
    printf '%s\n' '{"id":200,"body":"@codex review","issue_url":"https://api.github.com/repos/example/repo/issues/493","created_at":"2026-10-01T00:07:00Z","user":{"id":37220977,"login":"fixture-owner","type":"User"}}' ;;
  *'repos/example/repo/issues/comments/201'*)
    printf '%s\n' '{"id":201,"body":"@codex review","issue_url":"https://api.github.com/repos/example/repo/issues/493","created_at":"2026-10-01T00:21:00Z","user":{"id":37220977,"login":"fixture-owner","type":"User"}}' ;;
  *'repos/example/repo/issues/comments/202'*)
    printf '{"id":202,"body":"@codex review","issue_url":"https://api.github.com/repos/example/repo/issues/493","created_at":"%s","user":{"id":37220977,"login":"fixture-owner","type":"User"}}\n' "${CAPTURE_TRIGGER_AT:-2026-10-01T00:24:00Z}" ;;
  *'users/chatgpt-codex-connector[bot]'*)
    printf '%s\n' '{"id":199175422,"login":"chatgpt-codex-connector[bot]","type":"Bot"}' ;;
  *'users/copilot-pull-request-reviewer[bot]'*)
    printf '%s\n' '{"id":175728472,"login":"copilot-pull-request-reviewer[bot]","type":"Bot"}' ;;
  *'users/Copilot'*)
    printf '%s\n' '{"id":175728472,"login":"Copilot","type":"Bot"}' ;;
  *'repos/example/repo/issues/493/timeline'*)
    # The canonical checker reads ordinary timeline evidence through gh's
    # paginated slurp form, while the public writer requests individual,
    # projected pages.  Model both transports: returning a raw writer page to
    # the checker would turn this fixture mismatch into a false regression.
    if [[ "$*" == *'--paginate'* && "$*" == *'--slurp'* ]]; then
      printf '%s\n' '[[]]'
    elif [ "${CAPTURE_REQUESTED_REVIEWER:-}" = large ] || [ "${CAPTURE_REQUESTED_REVIEWER:-}" = paginated-ambiguous ]; then
      timeline_query="${*#*timeline\?}"
      timeline_page="${timeline_query##*&page=}"
      timeline_page="${timeline_page%% *}"
      # `gh --jq` projects the useful event shape before Node receives a page.
      # Deliberately return a >1 MiB raw body without that projection: a raw
      # timeline collector must fail instead of masking the regression.
      if [[ "$*" != *'--jq'* ]]; then
        printf '{"event":"commented","body":"['
        head -c 1200000 /dev/zero | tr '\0' x
        printf ']"}\n'
      elif [ "$timeline_page" = 1 ]; then
        printf '['
        if [ "${CAPTURE_REQUESTED_REVIEWER:-}" = paginated-ambiguous ]; then
          printf '%s' '{"event":"review_requested","created_at":"2026-10-01T00:07:00Z","actor":{"id":37220977},"review_requester":{"id":37220977},"requested_reviewer":{"id":175728472}}'
        else
          printf '%s' '{"event":"commented"}'
        fi
        for _ in $(seq 1 99); do printf ',{"event":"commented"}'; done
        printf ']\n'
      elif [ "$timeline_page" = 2 ]; then
        if [ "${CAPTURE_REQUESTED_REVIEWER:-}" = paginated-ambiguous ]; then
          printf '%s\n' '[{"event":"review_requested","created_at":"2026-10-01T00:07:01Z","actor":{"id":37220977},"review_requester":{"id":37220977},"requested_reviewer":{"id":175728472}}]'
        else
          printf '%s\n' '[{"event":"review_requested","created_at":"2026-10-01T00:07:00Z","actor":{"id":37220977},"review_requester":{"id":37220977},"requested_reviewer":{"id":175728472}}]'
        fi
      else
        printf '%s\n' '[]'
      fi
    elif [ "${CAPTURE_REQUESTED_REVIEWER:-}" = 1 ]; then
      printf '%s\n' '[{"event":"review_requested","created_at":"2026-10-01T00:07:00Z","actor":{"id":37220977},"review_requester":{"id":37220977},"requested_reviewer":{"id":175728472,"login":"copilot-pull-request-reviewer[bot]"}}]'
    elif [ "${CAPTURE_REQUESTED_REVIEWER:-}" = absent ]; then
      printf '%s\n' '[]'
    elif [ "${CAPTURE_REQUESTED_REVIEWER:-}" = ambiguous ]; then
      printf '%s\n' '[{"event":"review_requested","created_at":"2026-10-01T00:07:00Z","actor":{"id":37220977},"review_requester":{"id":37220977},"requested_reviewer":{"id":175728472}},{"event":"review_requested","created_at":"2026-10-01T00:07:01Z","actor":{"id":37220977},"review_requester":{"id":37220977},"requested_reviewer":{"id":175728472}}]'
    elif [ "${CAPTURE_REQUESTED_REVIEWER:-}" = wrong-reviewer ]; then
      printf '%s\n' '[{"event":"review_requested","created_at":"2026-10-01T00:07:00Z","actor":{"id":37220977},"review_requester":{"id":37220977},"requested_reviewer":{"id":42}}]'
    elif [ "${CAPTURE_REQUESTED_REVIEWER:-}" = retry-too-short ]; then
      printf '%s\n' '[{"event":"review_requested","created_at":"2026-10-01T00:08:00Z","actor":{"id":37220977},"review_requester":{"id":37220977},"requested_reviewer":{"id":175728472}}]'
    elif [ "${CAPTURE_REQUESTED_REVIEWER:-}" = retry-valid ]; then
      printf '%s\n' '[{"event":"review_requested","created_at":"2026-10-01T00:21:00Z","actor":{"id":37220977},"review_requester":{"id":37220977},"requested_reviewer":{"id":175728472}}]'
    elif [ "${CAPTURE_REQUESTED_REVIEWER:-}" = malformed-owner ]; then
      printf '%s\n' '[{"event":"review_requested","created_at":"2026-10-01T00:07:00Z","actor":{},"review_requester":{},"requested_reviewer":{"id":175728472}}]'
    else
      printf '%s\n' '[]'
    fi ;;
  *'repos/example/repo/pulls/493/reviews?per_page=100'*)
    if [ "${CAPTURE_INLINE:-}" = 1 ]; then
      jq -cn --arg h "$CAPTURE_HEAD" '[[{id:904,submitted_at:"2026-10-01T00:23:00Z",commit_id:$h,
        body:("### Codex Review\n\nHere are some automated review suggestions for this pull request.\n\n**Reviewed commit:** `" + $h + "`"),
        user:{id:199175422,login:"chatgpt-codex-connector[bot]",type:"Bot"}}]]'
    elif [ "${CAPTURE_REQUESTED_REVIEWER:-}" = 1 ] || [ "${CAPTURE_REQUESTED_REVIEWER:-}" = large ] || [ "${CAPTURE_REQUESTED_REVIEWER:-}" = retry-valid ]; then
      printf '[[{"id":903,"submitted_at":"2026-10-01T00:22:00Z","commit_id":"%s","user":{"id":175728472,"login":"Copilot","type":"Bot"}}]]\n' "${CAPTURE_HEAD:?}"
    else
      printf '%s\n' '[[]]'
    fi ;;
  *'repos/example/repo/pulls/493/comments?per_page=100'*)
    if [ "${CAPTURE_PRE_CYCLE:-}" = 1 ]; then
      jq -cn --arg source "${CAPTURE_PRE_CYCLE_SOURCE:?}" --arg reply "${CAPTURE_PRE_CYCLE_REPLY:?}" \
        --arg source_updated_at "${CAPTURE_PRE_CYCLE_SOURCE_UPDATED_AT:-2026-10-01T00:01:00Z}" \
        --arg reply_updated_at "${CAPTURE_PRE_CYCLE_REPLY_UPDATED_AT:-2026-10-01T00:02:00Z}" \
        --argjson source_root "${CAPTURE_PRE_CYCLE_SOURCE_ROOT:-null}" \
        --argjson reply_root "${CAPTURE_PRE_CYCLE_REPLY_ROOT:-4483086823}" \
        --arg batch_reply "${CAPTURE_PRE_CYCLE_BATCH_REPLY:-}" '[[
        {id:4483086823,body:"<!-- CodeRabbit -->\n\n**Minor** registry-path defect",original_commit_id:$source,commit_id:$source,
          created_at:"2026-10-01T00:01:00Z",updated_at:$source_updated_at,
          user:{id:136622811,login:"coderabbitai[bot]",type:"Bot"}} + (if $source_root == null then {} else {in_reply_to_id:$source_root} end),
        {id:4483740368,in_reply_to_id:$reply_root,body:$reply,
          created_at:"2026-10-01T00:02:00Z",updated_at:$reply_updated_at,
          user:{id:37220977,login:"fixture-owner",type:"User"}}
      ] + (if $batch_reply == "" then [] else [
        {id:4483086824,body:"<!-- CodeRabbit -->\n\n**Minor** second registry-path defect",original_commit_id:$source,commit_id:$source,
          created_at:"2026-10-01T00:01:30Z",updated_at:"2026-10-01T00:01:30Z",
          user:{id:136622811,login:"coderabbitai[bot]",type:"Bot"}},
        {id:4483740369,in_reply_to_id:4483086824,body:$batch_reply,
          created_at:"2026-10-01T00:02:30Z",updated_at:"2026-10-01T00:02:30Z",
          user:{id:37220977,login:"fixture-owner",type:"User"}}
      ] end)]'
    elif [ "${CAPTURE_INLINE:-}" = 1 ]; then
      jq -cn --arg h "$CAPTURE_HEAD" --arg reply "${CAPTURE_INLINE_REPLIED:-}" '[[
        {id:905,body:"**P2** inline finding",original_commit_id:$h,commit_id:$h,pull_request_review_id:904,
          created_at:"2026-10-01T00:23:00Z",updated_at:"2026-10-01T00:23:00Z",
          user:{id:199175422,login:"chatgpt-codex-connector[bot]",type:"Bot"}},
        (if $reply == "1" then {id:906,in_reply_to_id:905,body:"Declined with fixture evidence",author_association:"OWNER",
          created_at:"2026-10-01T00:24:00Z",user:{id:37220977,type:"User"}} else empty end)]]'
    else printf '%s\n' '[[]]'; fi ;;
  *'repos/example/repo/pulls/493'*)
    printf '{"base":{"sha":"%s"},"head":{"sha":"%s"},"user":{"id":37220977}}\n' "${CAPTURE_BASE:?}" "${CAPTURE_HEAD:?}" ;;
  *'repos/example/repo/commits/'*'/check-suites?per_page=100'*)
    printf '%s\n' '[{"check_suites":[]}]' ;;
  *"repos/example/repo/commits/${CAPTURE_ORIGIN_HEAD:-__missing__}"*)
    printf '{"sha":"%s","commit":{"author":{"date":"2026-10-01T00:00:00Z"},"committer":{"date":"2026-10-01T00:00:00Z"}}}\n' "${CAPTURE_ORIGIN_HEAD:?}" ;;
  *'repos/example/repo/commits/'*)
    printf '%s\n' "{\"sha\":\"${CAPTURE_HEAD:?}\",\"commit\":{\"author\":{\"date\":\"2026-10-01T00:00:00Z\"},\"committer\":{\"date\":\"2026-10-01T00:00:00Z\"}}}" ;;
  *'repos/example/repo/issues/493/comments?per_page=100'*)
    if [ "${CAPTURE_CUSTOM:-}" = 1 ]; then
      "$0" api repos/example/repo/issues/comments/902 | jq -s '[.]'
    elif [ "${CAPTURE_FINDING:-}" = 1 ]; then
      printf '[[{"id":902,"created_at":"2026-10-01T00:24:00Z","body":"**P1** late finding\\n\\n**Reviewed commit:** `%s`","user":{"id":199175422,"login":"chatgpt-codex-connector[bot]","type":"Bot"}}]]\n' "${CAPTURE_ORIGIN_HEAD:?}"
    else
      printf '%s\n' '[[]]'
    fi ;;
  *'api user'*) printf '%s\n' '{"id":37220977}' ;;
  *) printf 'unexpected gh command: %s\n' "$*" >&2; exit 1 ;;
esac
EOF
chmod +x "$capture_bin/gh"
cat >"$capture_bin/date" <<'EOF'
#!/usr/bin/env bash
# The retry reserve must create its own canonical reservation timestamp before
# the fixture's second owner request.  Keep that clock local to the checker
# invocation; source.reserved_at is deliberately unrelated and untrusted.
case "$*" in
  '-u +%s')
    if [ -n "${CAPTURE_EPOCH:-}" ]; then printf '%s\n' "$CAPTURE_EPOCH"; else exec /bin/date "$@"; fi
    ;;
  '-u +%Y-%m-%dT%H:%M:%SZ')
    if [ -n "${CAPTURE_NOW:-}" ]; then printf '%s\n' "$CAPTURE_NOW"; else exec /bin/date "$@"; fi
    ;;
  *) exec /bin/date "$@" ;;
esac
EOF
chmod +x "$capture_bin/date"
base64 <"$asset_dir/../../../../../agent-registry.json" >"$capture_bin/registry.b64"

# #1861: a reviewer can find a P1 after integration begins but before any
# Codex cycle exists (for example while initial CI/base reconciliation is
# pending). Exercise the public writer, its real authenticated comment reader,
# and the documented CLI flags rather than constructing run.json by hand.
# The source/fix commits are real local objects so the writer also proves the
# remediation head descends from the reviewed head.
pre_cycle_source="$(git -C "$repo" rev-parse HEAD)"
pre_cycle_fixed="$(git -C "$repo" commit-tree "${pre_cycle_source}^{tree}" -p "$pre_cycle_source" -m 'pre-cycle remediation fixture')"
pre_cycle_branch="fixture-run-pre-cycle"
git -C "$repo" branch -f "$pre_cycle_branch" "$pre_cycle_fixed"
pre_cycle_lane="$tmp/pre-cycle-bound-lane"
git -C "$repo" worktree add -q "$pre_cycle_lane" "$pre_cycle_branch"
pre_cycle_lane_git="$(git -C "$pre_cycle_lane" rev-parse --path-format=absolute --git-dir)"
[ "$pre_cycle_lane_git" != "$repo/.git" ] || fail "pre-cycle remediation fixture is not a linked worktree"
pre_cycle_source_digest="sha256:$(printf '%s' $'<!-- CodeRabbit -->\n\n**Minor** registry-path defect' | sha256sum | awk '{print $1}')"
pre_cycle_attestation="{\"disposition\":\"fix\",\"finding_id\":\"pre-cycle-coderabbit-4483086823\",\"source_comment_id\":4483086823,\"fixed_head\":\"$pre_cycle_fixed\",\"original_priority\":\"P1\",\"adjudicated_priority\":\"P1\"}"
pre_cycle_reply="<!-- dev-flow-pre-cycle-remediation: $pre_cycle_attestation -->"
pre_cycle_reply_digest="sha256:$(printf '%s' "$pre_cycle_reply" | sha256sum | awk '{print $1}')"
new_run run-pre-cycle
write_plan s-pre-cycle 1861:run-pre-cycle
acquire s-pre-cycle alice --issues 1861
printf '{"branch":"%s"}\n' "$pre_cycle_branch" >"$state/runs/run-pre-cycle/branch.json"
pre_write() {
    (cd "$pre_cycle_lane" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$pre_cycle_fixed" CAPTURE_BASE="$integration_base" \
        CAPTURE_PRE_CYCLE=1 CAPTURE_PRE_CYCLE_SOURCE="$pre_cycle_source" CAPTURE_PRE_CYCLE_REPLY="${CAPTURE_PRE_CYCLE_REPLY:-$pre_cycle_reply}" \
        RUN_RECORD_OWNER_TOKEN="$(token_for s-pre-cycle)" node "$writer" "$@" --slate s-pre-cycle --session alice --run-id run-pre-cycle)
}
for step in "claim:k" "implement:claimed" "verify:implemented" "challenge:verified" "security:converged" "integration:secure"; do
    pre_write transition --stage "${step%%:*}" --exit "${step#*:}" --at 2026-10-01T00:00:00Z >/dev/null
done
pre_write bind-pr --number 493 --url https://github.com/example/repo/pull/493 --at 2026-10-01T00:00:30Z >/dev/null
pre_cycle_args=(
    --remediation-head "$pre_cycle_fixed" --remediation-findings ''
    --pre-cycle-finding-id pre-cycle-coderabbit-4483086823
    --pre-cycle-original-priority P1 --pre-cycle-adjudicated-priority P1
    --pre-cycle-source-head "$pre_cycle_source" --pre-cycle-source-comment-id 4483086823
    --pre-cycle-source-actor-id 136622811 --pre-cycle-source-created-at 2026-10-01T00:01:00Z
    --pre-cycle-source-updated-at 2026-10-01T00:01:00Z
    --pre-cycle-source-digest "$pre_cycle_source_digest"
    --pre-cycle-verification-head "$pre_cycle_fixed" --pre-cycle-verification-reply-id 4483740368
    --pre-cycle-verification-actor-id 37220977 --pre-cycle-verification-created-at 2026-10-01T00:02:00Z
    --pre-cycle-verification-updated-at 2026-10-01T00:02:00Z
    --pre-cycle-verification-digest "$pre_cycle_reply_digest"
)
pre_cycle_run="$state/runs/run-pre-cycle/run.json"
# Recovery does not require a disabled Codex finder merely to read the
# independent orchestrator allowlist. A finding nested below an older thread
# root still receives its verification reply at that root.
printf '%s\n' '{"trusted_orchestrator_actor_ids":[37220977]}' >"$tmp/pre-cycle-trust-registry.json"
base64 <"$tmp/pre-cycle-trust-registry.json" >"$capture_bin/custom-registry.b64"
if ! (cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CUSTOM=1 CAPTURE_PRE_CYCLE=1 \
    CAPTURE_PRE_CYCLE_SOURCE="$pre_cycle_source" CAPTURE_PRE_CYCLE_REPLY="$pre_cycle_reply" \
    CAPTURE_PRE_CYCLE_SOURCE_ROOT=4483000000 CAPTURE_PRE_CYCLE_REPLY_ROOT=4483000000 \
    CAPTURE_HEAD="$pre_cycle_fixed" CAPTURE_BASE="$integration_base" PRE_SOURCE="$pre_cycle_source" \
    PRE_FIXED="$pre_cycle_fixed" PRE_REPLY="$pre_cycle_reply" node --input-type=module -e '
      import { createHash } from "node:crypto";
      import { pathToFileURL } from "node:url";
      const { authenticatePreCycleRemediation } = await import(pathToFileURL(process.argv[1]).href);
      const digest = (body) => `sha256:${createHash("sha256").update(body, "utf8").digest("hex")}`;
      const errors = authenticatePreCycleRemediation({
        finding_id:"pre-cycle-coderabbit-4483086823", original_priority:"P1", adjudicated_priority:"P1",
        source:{comment_id:4483086823,author_actor_id:136622811,created_at:"2026-10-01T00:01:00Z",updated_at:"2026-10-01T00:01:00Z",head:process.env.PRE_SOURCE,body_digest:digest("<!-- CodeRabbit -->\n\n**Minor** registry-path defect")},
        verification:{head:process.env.PRE_FIXED,reply_id:4483740368,author_actor_id:37220977,created_at:"2026-10-01T00:02:00Z",updated_at:"2026-10-01T00:02:00Z",body_digest:digest(process.env.PRE_REPLY)}
      }, {record:{pr_bindings:[{number:493,url:"https://github.com/example/repo/pull/493"}]},repoDir:process.cwd()});
      if (errors.length) console.error(JSON.stringify(errors));
      process.exit(errors.length === 0 ? 0 : 1);
    ' "$asset_dir/lib/integrator-receipt-auth.mjs"); then
    fail "pre-cycle recovery rejected a trusted reply at a follow-up thread root or required an omitted Codex finder"
fi
pass "pre-cycle recovery reads trust independently and matches follow-up replies to their thread root"
# The authenticated source and remediation commits can belong to a foreign
# lane clone. The conductor has no copy of these objects, so only the recorded
# lane repository can prove ancestry.
foreign_pre_cycle="$tmp/pre-cycle-foreign"
git init -q -b main "$foreign_pre_cycle"
git -C "$foreign_pre_cycle" config user.name t
git -C "$foreign_pre_cycle" config user.email t@t
git -C "$foreign_pre_cycle" -c user.name=t -c user.email=t@t commit -q --allow-empty -m source
foreign_source="$(git -C "$foreign_pre_cycle" rev-parse HEAD)"
git -C "$foreign_pre_cycle" -c user.name=t -c user.email=t@t commit -q --allow-empty -m fixed
foreign_fixed="$(git -C "$foreign_pre_cycle" rev-parse HEAD)"
foreign_attestation="{\"disposition\":\"fix\",\"finding_id\":\"pre-cycle-coderabbit-4483086823\",\"source_comment_id\":4483086823,\"fixed_head\":\"$foreign_fixed\",\"original_priority\":\"P1\",\"adjudicated_priority\":\"P1\"}"
foreign_reply="<!-- dev-flow-pre-cycle-remediation: $foreign_attestation -->"
if ! (cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_PRE_CYCLE=1 CAPTURE_PRE_CYCLE_SOURCE="$foreign_source" \
    CAPTURE_PRE_CYCLE_REPLY="$foreign_reply" CAPTURE_HEAD="$foreign_fixed" CAPTURE_BASE="$integration_base" \
    PRE_SOURCE="$foreign_source" PRE_FIXED="$foreign_fixed" PRE_REPLY="$foreign_reply" PRE_REPO="$foreign_pre_cycle" node --input-type=module -e '
      import { createHash } from "node:crypto";
      import { pathToFileURL } from "node:url";
      const { authenticatePreCycleRemediation } = await import(pathToFileURL(process.argv[1]).href);
      const digest = (body) => `sha256:${createHash("sha256").update(body, "utf8").digest("hex")}`;
      const errors = authenticatePreCycleRemediation({
        finding_id:"pre-cycle-coderabbit-4483086823", original_priority:"P1", adjudicated_priority:"P1",
        source:{comment_id:4483086823,author_actor_id:136622811,created_at:"2026-10-01T00:01:00Z",updated_at:"2026-10-01T00:01:00Z",head:process.env.PRE_SOURCE,body_digest:digest("<!-- CodeRabbit -->\n\n**Minor** registry-path defect")},
        verification:{head:process.env.PRE_FIXED,reply_id:4483740368,author_actor_id:37220977,created_at:"2026-10-01T00:02:00Z",updated_at:"2026-10-01T00:02:00Z",body_digest:digest(process.env.PRE_REPLY)}
      }, {record:{pr_bindings:[{number:493,url:"https://github.com/example/repo/pull/493"}]},repoDir:process.env.PRE_REPO});
      process.exit(errors.length === 0 ? 0 : 1);
    ' "$asset_dir/lib/integrator-receipt-auth.mjs"); then
    fail "pre-cycle recovery did not use the supplied foreign repository for ancestry"
fi
pass "pre-cycle ancestry verification accepts commits only present in the recorded lane clone"
# Authentication must prove ancestry from the real graph, not a locally
# replaced one.  This replacement would make the unrelated source appear to
# be the remediation's parent to an unguarded `git merge-base` call.
pre_cycle_fake_source="$(git -C "$repo" commit-tree "${pre_cycle_source}^{tree}" -m 'unrelated pre-cycle source')"
pre_cycle_fake_attestation="{\"disposition\":\"fix\",\"finding_id\":\"pre-cycle-coderabbit-4483086823\",\"source_comment_id\":4483086823,\"fixed_head\":\"$pre_cycle_fixed\",\"original_priority\":\"P1\",\"adjudicated_priority\":\"P1\"}"
pre_cycle_fake_reply="<!-- dev-flow-pre-cycle-remediation: $pre_cycle_fake_attestation -->"
git -C "$repo" replace --graft "$pre_cycle_fixed" "$pre_cycle_fake_source"
if (cd "$pre_cycle_lane" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$pre_cycle_fixed" CAPTURE_BASE="$integration_base" \
    CAPTURE_PRE_CYCLE=1 CAPTURE_PRE_CYCLE_SOURCE="$pre_cycle_fake_source" CAPTURE_PRE_CYCLE_REPLY="$pre_cycle_fake_reply" \
    PRE_SOURCE="$pre_cycle_fake_source" PRE_FIXED="$pre_cycle_fixed" PRE_REPLY="$pre_cycle_fake_reply" node --input-type=module -e '
      import { createHash } from "node:crypto";
      import { pathToFileURL } from "node:url";
      const { authenticatePreCycleRemediation } = await import(pathToFileURL(process.argv[1]).href);
      const digest = (body) => `sha256:${createHash("sha256").update(body, "utf8").digest("hex")}`;
      const source = process.env.PRE_SOURCE;
      const fixed = process.env.PRE_FIXED;
      const errors = authenticatePreCycleRemediation({
        finding_id: "pre-cycle-coderabbit-4483086823", original_priority: "P1", adjudicated_priority: "P1",
        source: { comment_id: 4483086823, author_actor_id: 136622811, created_at: "2026-10-01T00:01:00Z", updated_at: "2026-10-01T00:01:00Z", head: source, body_digest: digest("<!-- CodeRabbit -->\\n\\n**Minor** registry-path defect") },
        verification: { head: fixed, reply_id: 4483740368, author_actor_id: 37220977, created_at: "2026-10-01T00:02:00Z", updated_at: "2026-10-01T00:02:00Z", body_digest: digest(process.env.PRE_REPLY) },
      }, { record: { pr_bindings: [{ number: 493, url: "https://github.com/example/repo/pull/493" }] }, repoDir: process.cwd() });
      process.exit(errors.some((error) => error.includes("is not a descendant")) ? 0 : 1);
    ' "$asset_dir/lib/integrator-receipt-auth.mjs"); then
    :
else
    fail "replace-ref fake ancestry was accepted for pre-cycle remediation"
fi
git -C "$repo" replace -d "$pre_cycle_fixed" >/dev/null
# Unlike replace refs, graft files have no command-line opt-out.  Their mere
# presence therefore refuses even otherwise valid ancestry evidence.
pre_cycle_grafts="$(git -C "$pre_cycle_lane" rev-parse --path-format=absolute --git-path info/grafts)"
mkdir -p "$(dirname "$pre_cycle_grafts")"
printf '%s %s\n' "$pre_cycle_fixed" "$pre_cycle_source" >"$pre_cycle_grafts"
if (cd "$pre_cycle_lane" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$pre_cycle_fixed" CAPTURE_BASE="$integration_base" \
    CAPTURE_PRE_CYCLE=1 CAPTURE_PRE_CYCLE_SOURCE="$pre_cycle_source" CAPTURE_PRE_CYCLE_REPLY="$pre_cycle_reply" \
    PRE_SOURCE="$pre_cycle_source" PRE_FIXED="$pre_cycle_fixed" PRE_REPLY="$pre_cycle_reply" node --input-type=module -e '
      import { createHash } from "node:crypto";
      import { pathToFileURL } from "node:url";
      const { authenticatePreCycleRemediation } = await import(pathToFileURL(process.argv[1]).href);
      const digest = (body) => `sha256:${createHash("sha256").update(body, "utf8").digest("hex")}`;
      const source = process.env.PRE_SOURCE;
      const fixed = process.env.PRE_FIXED;
      const errors = authenticatePreCycleRemediation({
        finding_id: "pre-cycle-coderabbit-4483086823", original_priority: "P1", adjudicated_priority: "P1",
        source: { comment_id: 4483086823, author_actor_id: 136622811, created_at: "2026-10-01T00:01:00Z", updated_at: "2026-10-01T00:01:00Z", head: source, body_digest: digest("<!-- CodeRabbit -->\\n\\n**Minor** registry-path defect") },
        verification: { head: fixed, reply_id: 4483740368, author_actor_id: 37220977, created_at: "2026-10-01T00:02:00Z", updated_at: "2026-10-01T00:02:00Z", body_digest: digest(process.env.PRE_REPLY) },
      }, { record: { pr_bindings: [{ number: 493, url: "https://github.com/example/repo/pull/493" }] }, repoDir: process.cwd() });
      process.exit(errors.some((error) => error.includes("is not a descendant")) ? 0 : 1);
    ' "$asset_dir/lib/integrator-receipt-auth.mjs"); then
    :
else
    rm -f "$pre_cycle_grafts"
    fail "grafted ancestry was accepted for pre-cycle remediation"
fi
rm -f "$pre_cycle_grafts"
pass "pre-cycle ancestry ignores replace refs and refuses grafted history"
# The first attempted admission is a direct integration → integration
# transition. It reaches the new deferred-publication path, then fails complete
# candidate validation. Neither its run projection nor a ruling may survive.
cp "$pre_cycle_run" "$tmp/pre-cycle-before-invalid-reentry.json"
if [ -d "$state/runs/run-pre-cycle/rulings" ]; then
    find "$state/runs/run-pre-cycle/rulings" -type f -print -exec sha256sum {} \; | sort >"$tmp/pre-cycle-rulings-before-invalid-reentry.txt"
else
    : >"$tmp/pre-cycle-rulings-before-invalid-reentry.txt"
fi
expect_refused "invalid direct pre-cycle integration re-entry leaves no admission" \
    "not a valid transition from integration" \
    pre_write transition --stage integration --exit fixed --at 2026-10-01T00:03:00Z "${pre_cycle_args[@]}"
cmp -s "$pre_cycle_run" "$tmp/pre-cycle-before-invalid-reentry.json" || fail "an invalid pre-cycle re-entry changed run.json"
if [ -d "$state/runs/run-pre-cycle/rulings" ]; then
    find "$state/runs/run-pre-cycle/rulings" -type f -print -exec sha256sum {} \; | sort >"$tmp/pre-cycle-rulings-after-invalid-reentry.txt"
else
    : >"$tmp/pre-cycle-rulings-after-invalid-reentry.txt"
fi
cmp -s "$tmp/pre-cycle-rulings-before-invalid-reentry.txt" "$tmp/pre-cycle-rulings-after-invalid-reentry.txt" || fail "an invalid pre-cycle re-entry published an orphan admission"
# The ordinary remediation path remains able to make its first admission.
pre_write transition --stage implement --exit remediating --at 2026-10-01T00:00:40Z >/dev/null
pre_write transition --stage verify --exit fixed --at 2026-10-01T00:00:45Z >/dev/null
pre_write transition --stage security --exit clean --at 2026-10-01T00:00:50Z >/dev/null
cp "$pre_cycle_run" "$tmp/pre-cycle-before.json"
expect_usage "pre-cycle evidence cannot omit a required receipt field" "pre-cycle remediation evidence requires every" \
    pre_write transition --stage integration --exit fixed --at 2026-10-01T00:03:00Z \
    --remediation-head "$pre_cycle_fixed" --remediation-findings '' \
    --pre-cycle-finding-id pre-cycle-coderabbit-4483086823
cmp -s "$pre_cycle_run" "$tmp/pre-cycle-before.json" || fail "a missing pre-cycle evidence field changed run.json"
pre_cycle_untrusted_args=("${pre_cycle_args[@]}")
for index in "${!pre_cycle_untrusted_args[@]}"; do
    if [ "${pre_cycle_untrusted_args[$index]}" = --pre-cycle-verification-actor-id ]; then
        pre_cycle_untrusted_args[$((index + 1))]=1
        break
    fi
done
expect_refused "pre-cycle verification actor must be trusted" "must be by a trusted orchestrator" \
    pre_write transition --stage integration --exit fixed --at 2026-10-01T00:03:00Z "${pre_cycle_untrusted_args[@]}"
cmp -s "$pre_cycle_run" "$tmp/pre-cycle-before.json" || fail "an unauthenticated pre-cycle reply changed run.json"
pre_cycle_not_fixed="not fixed at $pre_cycle_fixed"
pre_cycle_not_fixed_args=("${pre_cycle_args[@]}")
for index in "${!pre_cycle_not_fixed_args[@]}"; do
    if [ "${pre_cycle_not_fixed_args[$index]}" = --pre-cycle-verification-digest ]; then
        pre_cycle_not_fixed_args[$((index + 1))]="sha256:$(printf '%s' "$pre_cycle_not_fixed" | sha256sum | awk '{print $1}')"
        break
    fi
done
CAPTURE_PRE_CYCLE_REPLY="$pre_cycle_not_fixed" expect_refused "pre-cycle reply must explicitly attest a fix" "canonical fix attestation" \
    pre_write transition --stage integration --exit fixed --at 2026-10-01T00:03:00Z "${pre_cycle_not_fixed_args[@]}"
cmp -s "$pre_cycle_run" "$tmp/pre-cycle-before.json" || fail "a non-fix pre-cycle reply changed run.json"
pre_cycle_misprioritized_attestation="{\"disposition\":\"fix\",\"finding_id\":\"pre-cycle-coderabbit-4483086823\",\"source_comment_id\":4483086823,\"fixed_head\":\"$pre_cycle_fixed\",\"original_priority\":\"P2\",\"adjudicated_priority\":\"P2\"}"
pre_cycle_misprioritized_reply="<!-- dev-flow-pre-cycle-remediation: $pre_cycle_misprioritized_attestation -->"
pre_cycle_misprioritized_args=("${pre_cycle_args[@]}")
for index in "${!pre_cycle_misprioritized_args[@]}"; do
    if [ "${pre_cycle_misprioritized_args[$index]}" = --pre-cycle-verification-digest ]; then
        pre_cycle_misprioritized_args[$((index + 1))]="sha256:$(printf '%s' "$pre_cycle_misprioritized_reply" | sha256sum | awk '{print $1}')"
        break
    fi
done
CAPTURE_PRE_CYCLE_REPLY="$pre_cycle_misprioritized_reply" expect_refused "pre-cycle attestation cannot rescore the original priority" "canonical fix attestation" \
    pre_write transition --stage integration --exit fixed --at 2026-10-01T00:03:00Z "${pre_cycle_misprioritized_args[@]}"
cmp -s "$pre_cycle_run" "$tmp/pre-cycle-before.json" || fail "a misprioritized pre-cycle reply changed run.json"
# GitHub keeps an edited reply's original created_at. The body is valid only
# at its authenticated updated_at, so current text cannot be backdated.
CAPTURE_PRE_CYCLE_REPLY_UPDATED_AT=2026-10-01T00:10:00Z expect_refused \
    "an edited pre-cycle reply cannot be backdated with its original created_at" \
    "paginated source-thread reply" \
    pre_write transition --stage integration --exit fixed --at 2026-10-01T00:03:00Z "${pre_cycle_args[@]}"
cmp -s "$pre_cycle_run" "$tmp/pre-cycle-before.json" || fail "a backdated edited reply changed run.json"
# An edited source revision before the trusted reply is valid. The real
# admission below uses this exact evidence and its retry repeats it unchanged.
pre_cycle_edited_source_args=("${pre_cycle_args[@]}")
for index in "${!pre_cycle_edited_source_args[@]}"; do
    if [ "${pre_cycle_edited_source_args[$index]}" = --pre-cycle-source-updated-at ]; then
        pre_cycle_edited_source_args[$((index + 1))]=2026-10-01T00:01:30Z
        break
    fi
done
# But a current source revision after the trusted reply is not covered by it,
# even when the live object and CLI evidence agree on that edited timestamp.
pre_cycle_stale_source_args=("${pre_cycle_args[@]}")
for index in "${!pre_cycle_stale_source_args[@]}"; do
    if [ "${pre_cycle_stale_source_args[$index]}" = --pre-cycle-source-updated-at ]; then
        pre_cycle_stale_source_args[$((index + 1))]=2026-10-01T00:02:30Z
        break
    fi
done
CAPTURE_PRE_CYCLE_SOURCE_UPDATED_AT=2026-10-01T00:02:30Z expect_refused \
    "an edited pre-cycle source cannot rely on an earlier trusted reply" \
    "chronologically ordered" \
    pre_write transition --stage integration --exit fixed --at 2026-10-01T00:03:00Z "${pre_cycle_stale_source_args[@]}"
cmp -s "$pre_cycle_run" "$tmp/pre-cycle-before.json" || fail "an edited source changed run.json"
# Simulate interruption after the deterministic ruling published but before
# run.json did: restore the exact pre-call record and retry the same command.
cp "$pre_cycle_run" "$tmp/pre-cycle-before-admission.json"
CAPTURE_PRE_CYCLE_SOURCE_UPDATED_AT=2026-10-01T00:01:30Z \
    pre_write transition --stage integration --exit fixed --at 2026-10-01T00:03:00Z "${pre_cycle_edited_source_args[@]}" >/dev/null
find "$state/runs/run-pre-cycle/rulings" -type f -print | sort >"$tmp/pre-cycle-rulings-after-admission.txt"
cp "$tmp/pre-cycle-before-admission.json" "$pre_cycle_run"
CAPTURE_PRE_CYCLE_SOURCE_UPDATED_AT=2026-10-01T00:01:30Z \
    pre_write transition --stage integration --exit fixed --at 2026-10-01T00:03:00Z "${pre_cycle_edited_source_args[@]}" >/dev/null
find "$state/runs/run-pre-cycle/rulings" -type f -print | sort >"$tmp/pre-cycle-rulings-after-retry.txt"
cmp -s "$tmp/pre-cycle-rulings-after-admission.txt" "$tmp/pre-cycle-rulings-after-retry.txt" || fail "an exact pre-cycle retry changed the deterministic admission set"
node "$asset_dir/validate-result-schemas.mjs" run "$pre_cycle_run" --no-adjudications >/dev/null ||
    fail "authenticated pre-cycle remediation record failed strict validation"
jq -e --arg source "$pre_cycle_source" --arg fixed "$pre_cycle_fixed" '
  [.stage_transitions[] | select(any(.remediation?.pre_cycle?.findings[]?; .finding_id == "pre-cycle-coderabbit-4483086823"))] | .[0].remediation as $r |
  $r.head == $fixed and $r.findings == [] and
  ($r.pre_cycle.admission_digest | test("^[0-9a-f]{64}$")) and
  ($r.pre_cycle.findings | length) == 1 and
  $r.pre_cycle.findings[0].finding_id == "pre-cycle-coderabbit-4483086823" and
  $r.pre_cycle.findings[0].original_priority == "P1" and $r.pre_cycle.findings[0].adjudicated_priority == "P1" and
  $r.pre_cycle.findings[0].source.head == $source and $r.pre_cycle.findings[0].verification.head == $fixed and
  $r.pre_cycle.findings[0].seq == 0 and $r.pre_cycle.findings[0].prev_digest == "genesis" and
  ($r.pre_cycle.findings[0].digest | test("^[0-9a-f]{64}$"))' "$pre_cycle_run" >/dev/null ||
    fail "writer did not retain authenticated pre-cycle evidence with original P1 and exact fix head"
pass "public writer authenticates and chains a pre-cycle P1 remediation without inventing a cycle"

# Multiple independently authenticated findings fixed by the same commit stay
# in one remediation transition. The batch is evidence, not a synthetic cycle.
pre_cycle_batch_attestation="{\"disposition\":\"fix\",\"finding_id\":\"pre-cycle-coderabbit-4483086824\",\"source_comment_id\":4483086824,\"fixed_head\":\"$pre_cycle_fixed\",\"original_priority\":\"P1\",\"adjudicated_priority\":\"P1\"}"
pre_cycle_batch_reply="<!-- dev-flow-pre-cycle-remediation: $pre_cycle_batch_attestation -->"
pre_cycle_batch_source_digest="sha256:$(printf '%s' $'<!-- CodeRabbit -->\n\n**Minor** second registry-path defect' | sha256sum | awk '{print $1}')"
pre_cycle_batch_reply_digest="sha256:$(printf '%s' "$pre_cycle_batch_reply" | sha256sum | awk '{print $1}')"
new_run run-pre-cycle-batch
write_plan s-pre-cycle-batch 1862:run-pre-cycle-batch
acquire s-pre-cycle-batch alice --issues 1862
printf '{"branch":"%s"}\n' "$pre_cycle_branch" >"$state/runs/run-pre-cycle-batch/branch.json"
pre_batch_write() {
    (cd "$pre_cycle_lane" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$pre_cycle_fixed" CAPTURE_BASE="$integration_base" \
        CAPTURE_PRE_CYCLE=1 CAPTURE_PRE_CYCLE_SOURCE="$pre_cycle_source" CAPTURE_PRE_CYCLE_REPLY="$pre_cycle_reply" \
        CAPTURE_PRE_CYCLE_BATCH_REPLY="$pre_cycle_batch_reply" RUN_RECORD_OWNER_TOKEN="$(token_for s-pre-cycle-batch)" \
        node "$writer" "$@" --slate s-pre-cycle-batch --session alice --run-id run-pre-cycle-batch)
}
for step in "claim:k" "implement:claimed" "verify:implemented" "challenge:verified" "security:converged" "integration:secure"; do
    pre_batch_write transition --stage "${step%%:*}" --exit "${step#*:}" --at 2026-10-01T00:00:00Z >/dev/null
done
pre_batch_write bind-pr --number 493 --url https://github.com/example/repo/pull/493 --at 2026-10-01T00:00:30Z >/dev/null
pre_batch_write transition --stage implement --exit remediating --at 2026-10-01T00:00:40Z >/dev/null
pre_batch_write transition --stage verify --exit fixed --at 2026-10-01T00:00:45Z >/dev/null
pre_batch_write transition --stage security --exit clean --at 2026-10-01T00:00:50Z >/dev/null
pre_cycle_batch_file="$tmp/pre-cycle-batch.json"
jq -n --arg source "$pre_cycle_source" --arg fixed "$pre_cycle_fixed" --arg source_digest "$pre_cycle_batch_source_digest" --arg reply_digest "$pre_cycle_batch_reply_digest" '[{
  finding_id:"pre-cycle-coderabbit-4483086824", original_priority:"P1", adjudicated_priority:"P1",
  source:{comment_id:4483086824,author_actor_id:136622811,created_at:"2026-10-01T00:01:30Z",updated_at:"2026-10-01T00:01:30Z",head:$source,body_digest:$source_digest},
  verification:{head:$fixed,reply_id:4483740369,author_actor_id:37220977,created_at:"2026-10-01T00:02:30Z",updated_at:"2026-10-01T00:02:30Z",body_digest:$reply_digest}
}]' >"$pre_cycle_batch_file"
pre_cycle_batch_run="$state/runs/run-pre-cycle-batch/run.json"
# A batch supplements the primary evidence; by itself it must be refused
# before candidate validation or retained-admission publication.
cp "$pre_cycle_batch_run" "$tmp/pre-cycle-batch-only-before.json"
if [ -d "$state/runs/run-pre-cycle-batch/rulings" ]; then
    find "$state/runs/run-pre-cycle-batch/rulings" -type f -print | sort >"$tmp/pre-cycle-batch-only-rulings-before.txt"
else
    : >"$tmp/pre-cycle-batch-only-rulings-before.txt"
fi
expect_usage "pre-cycle batch cannot be supplied without its primary evidence" "pre-cycle-batch requires the complete primary" \
    pre_batch_write transition --stage integration --exit fixed --at 2026-10-01T00:03:00Z \
    --remediation-head "$pre_cycle_fixed" --remediation-findings '' --pre-cycle-batch "$pre_cycle_batch_file"
cmp -s "$pre_cycle_batch_run" "$tmp/pre-cycle-batch-only-before.json" || fail "a batch-only pre-cycle request changed run.json"
if [ -d "$state/runs/run-pre-cycle-batch/rulings" ]; then
    find "$state/runs/run-pre-cycle-batch/rulings" -type f -print | sort >"$tmp/pre-cycle-batch-only-rulings-after.txt"
else
    : >"$tmp/pre-cycle-batch-only-rulings-after.txt"
fi
cmp -s "$tmp/pre-cycle-batch-only-rulings-before.txt" "$tmp/pre-cycle-batch-only-rulings-after.txt" || fail "a batch-only pre-cycle request published a retained admission"
pass "batch-only pre-cycle evidence is refused without changing public run state"
pre_batch_write transition --stage integration --exit fixed --at 2026-10-01T00:03:00Z "${pre_cycle_args[@]}" --pre-cycle-batch "$pre_cycle_batch_file" >/dev/null
node "$asset_dir/validate-result-schemas.mjs" run "$pre_cycle_batch_run" --no-adjudications >/dev/null ||
    fail "two-finding pre-cycle remediation record failed strict validation"
jq -e '[.stage_transitions[] | select(.remediation? != null)] as $pushes |
  ($pushes | length) == 1 and ($pushes[0].remediation.pre_cycle.findings | length) == 2 and
  ([.receipts[] | select(.kind == "pass")] | length) == 0' "$pre_cycle_batch_run" >/dev/null ||
    fail "batch evidence did not retain two findings in one remediation entry without a fake review"
pass "public writer authenticates two distinct source/reply pairs in one pre-cycle remediation push"

capture_state="$tmp/capture-state.json"
capture_base="$integration_base"
capture_finder="$(jq -c '
  .finders[] | select(.slug == "codex-cloud") | {
    slug, actor_id:(.trusted_actor_id|tostring), actor_login:.trusted_actor_login,
    trigger_mechanism:.collection.trigger.mechanism, trigger_body:.collection.trigger.body,
    reviewer_login:.collection.trigger.reviewer_login, surfaces:.collection.terminal_signals.surfaces,
    head_binding:.collection.terminal_signals.head_binding, verdict_mode:.collection.terminal_signals.verdict_mode,
    clean_verdict:.collection.terminal_signals.clean_verdict, actionable_pattern:.collection.terminal_signals.actionable_pattern,
    severity_marker:.collection.terminal_signals.severity_marker, metadata_line:.collection.terminal_signals.metadata_line,
    about_summary:.collection.terminal_signals.about_summary, heading:.collection.terminal_signals.heading,
    carrier_sentence:.collection.terminal_signals.carrier_sentence, success_reaction:.collection.terminal_signals.success_reaction,
    pending_reaction:.collection.terminal_signals.pending_reaction
  }' "$asset_dir/../../../../../agent-registry.json")"
# A retained reservation is the first real review-request authority, not a
# later receipt or settlement.  The public writer must refuse an attempt to
# record a new pre-cycle attestation after that immutable boundary.
pre_cycle_reserve_state="$tmp/pre-cycle-reserve-state.json"
jq -n --arg head "$pre_cycle_fixed" --argjson finder "$capture_finder" '{version:2,repo:"example/repo",pr:493,head:$head,phase:"reserved",trigger_comment_id:null,
  charged_cycles:1,exempt_cycles:0,attempt:1,run_id:"run-pre-cycle",timeout_min:10,reserved_at:"2026-10-01T00:03:15Z",finder:$finder}' >"$pre_cycle_reserve_state"
pre_write integration-review-capture --state "$pre_cycle_reserve_state" --authority-kind reserve --at 2026-10-01T00:03:30Z >/dev/null
pre_cycle_late_args=("${pre_cycle_args[@]}")
for index in "${!pre_cycle_late_args[@]}"; do
    if [ "${pre_cycle_late_args[$index]}" = --pre-cycle-finding-id ]; then
        pre_cycle_late_args[$((index + 1))]=pre-cycle-coderabbit-4483086824
        break
    fi
done
expect_refused "pre-cycle writer refuses a retained reservation before verification admission" \
    "before the first retained review reservation" \
    pre_write transition --stage integration --exit fixed --at 2026-10-01T00:04:00Z "${pre_cycle_late_args[@]}"
pass "a real retained reserve authority blocks late pre-cycle recovery before any settlement"
# The fixture GH endpoint supplies the trusted registry at the retained base;
# that base itself must be on the reviewed branch so the real carry proof can
# derive both canonical three-dot identities from one local graph.
jq -n --arg head "$integration_head" --argjson finder "$capture_finder" '{version:2,repo:"example/repo",pr:493,head:$head,phase:"reserved",trigger_comment_id:null,
  charged_cycles:1,exempt_cycles:0,attempt:1,run_id:"run-integrator",timeout_min:10,reserved_at:"2026-09-30T23:55:00Z",finder:$finder}' >"$capture_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$capture_writer" integration-review-capture \
    --slate s-integrator --session alice --run-id run-integrator --state "$capture_state" --authority-kind reserve --at 2026-09-30T23:55:30Z) >/dev/null
# Release a never-triggered capture, then reserve the refunded same cycle.
# Keep the old ruling: downstream attachment replay and receipt must select
# the replacement by its reservation time, not become ambiguous.
recovery_checker="$fixture_integrate/assets/check-codex-cloud-review.sh"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_NOW=2026-10-01T00:05:00Z CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" \
    bash "$recovery_checker" release --state "$capture_state" --note 'trigger POST failed' \
    --now 2026-10-01T00:05:00Z) >/dev/null
jq -e '.phase == "released" and .charged_cycles == 0 and .exempt_cycles == 0' "$capture_state" >/dev/null ||
    fail "release did not refund the untriggered reservation"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_NOW=2026-10-01T00:06:00Z CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" \
    bash "$recovery_checker" reserve --state "$capture_state" --repo example/repo --pr 493 \
    --head "$integration_head" --attempt 1 --run-id run-integrator --timeout-min 10 --finder codex-cloud) >/dev/null
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$capture_writer" integration-review-capture \
    --slate s-integrator --session alice --run-id run-integrator --state "$capture_state" --authority-kind reserve --at 2026-10-01T00:06:30Z) >/dev/null
jq -e '.phase == "reserved" and .charged_cycles == 1 and .exempt_cycles == 0 and .attempt == 1 and
    (.superseded_reservations | length) == 1' "$capture_state" >/dev/null ||
    fail "re-reservation lost the refunded cycle or release history"
cp "$capture_state" "$tmp/recovery-reserve.json"
jq '.timeout_min = 15' "$capture_state" >"$capture_state.next"
mv "$capture_state.next" "$capture_state"
expect_refused "same reservation identity with changed controls still refuses" "conflicts with a retained transition capture" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" integration-review-capture --slate s-integrator --session alice --run-id run-integrator --state "$7" --authority-kind reserve --at 2026-10-01T00:06:30Z' _ \
    "$repo" "$capture_bin:$PATH" "$integration_head" "$capture_base" "$(token_for s-integrator)" "$capture_writer" "$capture_state"
cp "$tmp/recovery-reserve.json" "$capture_state"
rri bind-pr --run-id run-integrator --number 493 --url https://github.com/example/repo/pull/493 --at 2026-10-01T00:06:30Z >/dev/null
# The capture input is still the integrator-owned mutable state file.  Rewrite
# every source-only control we can without changing the coordinate needed to
# locate the retained reservation.  The public writer must rebuild from that
# reservation and retain the checker transition, never merge these keys back.
jq '.phase="attached" | .trigger_comment_id="200" |
    .run_id="foreign-run" | .reserved_at="2026-09-01T00:00:00Z" |
    .timeout_min=1 | .finder={slug:"foreign"} |
    .carry={from_head:("f" * 40),attests_head:("e" * 40)}' "$capture_state" >"$capture_state.next"
mv "$capture_state.next" "$capture_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$capture_writer" integration-review-capture \
    --slate s-integrator --session alice --run-id run-integrator --state "$capture_state" --authority-kind attach --at 2026-10-01T00:07:30Z) >/dev/null
# A replay after a crash observes the same transition. It adopts the retained
# capture without appending another authority that would make receipt lookup
# ambiguous.
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$capture_writer" integration-review-capture \
    --slate s-integrator --session alice --run-id run-integrator --state "$capture_state" --authority-kind attach --at 2026-10-01T00:08:00Z) >/dev/null
AUTH_COMMON="$repo/.git" AUTH_RUN=run-integrator AUTH_RECORD="$state/runs/run-integrator/run.json" node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const { retainedAuthorities } = await import(process.argv[1]);
  const record = JSON.parse(readFileSync(process.env.AUTH_RECORD));
  const retained = retainedAuthorities(record, { common: process.env.AUTH_COMMON, runId: process.env.AUTH_RUN });
  if (retained.length !== 3) process.exit(1);
  const attached = retained.find((entry) => entry.kind === "attach")?.authority.snapshot;
  if (!attached || attached.carry !== undefined || attached.run_id !== "run-integrator" ||
      attached.reserved_at !== "2026-10-01T00:06:00Z" || attached.timeout_min === 1 ||
      attached.finder?.slug !== "codex-cloud" || attached.last_reviewed_verdict === "clean") process.exit(1);
' "$asset_dir/lib/integrator-review-authority.mjs" || fail "public capture command did not retain a validated reserve/attach ruling chain"
pass "owner attachment replay rechecks live evidence without enriching the retained immutable capture"

# Remediation must consume the live frontier before any head move. These use
# the public writer and real checker with the authenticated offline GH fixture.
new_run run-remediation
write_plan s-remediation 181043:run-remediation
acquire s-remediation alice --issues 181043
rem_dir="$state/runs/run-remediation"
printf '{"branch":"%s"}\n' "$integration_branch" >"$rem_dir/branch.json"
resolve_fixture_policy "$rem_dir/policy.json" 1
rem_write() {
    (cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" \
        RUN_RECORD_OWNER_TOKEN="$(token_for s-remediation)" node "$capture_writer" "$@" \
        --slate s-remediation --session alice --run-id run-remediation)
}
for step in "claim:k" "implement:claimed" "verify:implemented" "challenge:verified" "security:converged" "integration:secure"; do
    rem_write transition --stage "${step%%:*}" --exit "${step#*:}" --at 2026-10-01T00:05:00Z >/dev/null
done
rem_transition() { rem_write transition --stage implement --exit remediating --at 2026-10-01T00:40:00Z "$@"; }
cp "$rem_dir/run.json" "$tmp/rem-unbound.json"
expect_refused "unbound remediation names bind-pr recovery" "use bind-pr" rem_transition
cmp -s "$rem_dir/run.json" "$tmp/rem-unbound.json" || fail "unbound refusal changed run"
rem_write bind-pr --number 493 --url https://github.com/example/repo/pull/493 --at 2026-10-01T00:05:30Z >/dev/null
cp "$rem_dir/run.json" "$tmp/rem-no-reservation.json"
rem_transition >/dev/null
cp "$tmp/rem-no-reservation.json" "$rem_dir/run.json"
pass "unbound remediation fails closed and bind-pr recovers without inventing a reservation"
# A configured positive-cap finder never reserved is not pending.
rem_transition >/dev/null
cp "$tmp/rem-no-reservation.json" "$rem_dir/run.json"
pass "configured but never-reserved finder permits remediation after first-head CI failure"
cp "$rem_dir/policy.json" "$tmp/rem-policy.json"
resolve_fixture_policy "$rem_dir/policy.json" 0
rem_transition >/dev/null
cp "$tmp/rem-no-reservation.json" "$rem_dir/run.json"
cp "$tmp/rem-policy.json" "$rem_dir/policy.json"
pass "cap-zero never-reserved finder permits remediation"
rem_state="$repo/.git/integrate-codex/example/repo/493.json"
mkdir -p "$(dirname "$rem_state")"
jq --arg run run-remediation '.run_id=$run' "$tmp/recovery-reserve.json" >"$rem_state"
rem_write integration-review-capture --state "$rem_state" --authority-kind reserve --at 2026-10-01T00:06:30Z >/dev/null
cp "$rem_dir/run.json" "$tmp/rem-reserved.json"
cp "$rem_state" "$tmp/rem-reserve-state.json"
CAPTURE_CLEAN=1 expect_refused "reserve-only frontier blocks even when reviewer has finished" "integration-receipt-required" rem_transition
cmp -s "$rem_dir/run.json" "$tmp/rem-reserved.json" || fail "reserve-only refusal changed run"
pass "reserve-only frontier cannot skip terminal attach capture"
# An actual released-unused reservation keeps its immutable identity and refund.
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_NOW=2026-10-01T00:20:00Z CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" \
    bash "$recovery_checker" release --state "$rem_state" --note 'unused remediation fixture' --now 2026-10-01T00:20:00Z) >/dev/null
cp "$rem_state" "$tmp/rem-exact-released.json"
rem_transition >/dev/null
cp "$tmp/rem-reserved.json" "$rem_dir/run.json"
pass "exact released-unused reservation proof permits remediation"
# Replacing the released reservation preserves its history, even when the
# refunded ordinal is reused. Historical proof pays only the old debt.
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_NOW=2026-10-01T00:21:00Z CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" \
    bash "$recovery_checker" reserve --state "$rem_state" --repo example/repo --pr 493 \
    --head "$integration_head" --attempt 1 --run-id run-remediation --timeout-min 10 --finder codex-cloud) >/dev/null
expect_refused "released R1 cannot authorize uncaptured pending R2" "uncaptured reservation" rem_transition
rem_write integration-review-capture --state "$rem_state" --authority-kind reserve --at 2026-10-01T00:21:30Z >/dev/null
cp "$rem_dir/run.json" "$tmp/rem-release-r2-reserved-record.json"
expect_refused "released R1 cannot authorize retained pending R2" "integration-receipt-required" rem_transition
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_NOW=2026-10-01T00:32:00Z CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" \
    bash "$recovery_checker" release --state "$rem_state" --note 'second unused fixture' --now 2026-10-01T00:32:00Z) >/dev/null
cp "$rem_state" "$tmp/rem-release-r2-state.json"
rem_transition >/dev/null
cp "$tmp/rem-release-r2-reserved-record.json" "$rem_dir/run.json"
pass "released R1 followed by released R2 settles both retained debts"
for mutation in wrong-head wrong-time release-before-reserve release-after-replacement wrong-finder wrong-run ambiguous malformed; do
    case "$mutation" in
    wrong-head) filter='.superseded_reservations[1].head=("f" * 40)' ;;
    wrong-time) filter='.superseded_reservations[1].reserved_at="2026-10-01T00:06:01Z"' ;;
    release-before-reserve) filter='.superseded_reservations[1].released_at="2026-10-01T00:05:00Z"' ;;
    release-after-replacement) filter='.superseded_reservations[1].released_at="2026-10-01T00:22:00Z"' ;;
    wrong-finder) filter='.finder.slug="other-finder"' ;;
    wrong-run) filter='.run_id="other-run"' ;;
    ambiguous) filter='.superseded_reservations += [.superseded_reservations[1]]' ;;
    malformed) filter='.superseded_reservations[1].released_at="invalid"' ;;
    esac
    jq "$filter" "$tmp/rem-release-r2-state.json" >"$rem_state"
    expect_refused "$mutation historical release proof refuses" "integration-receipt-required" rem_transition
    cmp -s "$rem_dir/run.json" "$tmp/rem-release-r2-reserved-record.json" || fail "release proof refusal changed the record"
done
cp "$tmp/rem-exact-released.json" "$rem_state"
expect_refused "old released R1 cannot hide lost retained R2" "integration-receipt-required" rem_transition
cp "$tmp/rem-reserved.json" "$rem_dir/run.json"
pass "historical release proof binds exact identity, coherent times and owner container"
jq '.head=("f" * 40)' "$tmp/rem-exact-released.json" >"$rem_state"
expect_refused "released-unused proof must match the retained reservation identity" "integration-receipt-required" rem_transition
cp "$tmp/rem-exact-released.json" "$rem_state"
# Refunds reuse the ordinal. Only the old reservation's exact identity is paid;
# losing a new same-ordinal reservation cannot make that old release pay twice.
jq '.phase="reserved" | .charged_cycles=1 | .exempt_cycles=0 |
  .reserved_at="2026-10-01T00:20:30Z"' "$rem_state" >"$tmp/rem-after-release-reserve.json"
rem_write integration-review-capture --state "$tmp/rem-after-release-reserve.json" --authority-kind reserve --at 2026-10-01T00:20:40Z >/dev/null
rm "$tmp/rem-after-release-reserve.json"
expect_refused "older released state cannot discharge lost newer reservation debt" "integration-receipt-required" rem_transition
cp "$tmp/rem-reserved.json" "$rem_dir/run.json"
cp "$tmp/rem-reserve-state.json" "$rem_state"
pass "mismatched and older released-unused proofs cannot discharge another reservation"
# Capture at a pending exit, then make the live review terminal independently.
jq '.phase="attached" | .trigger_comment_id="200"' "$rem_state" >"$rem_state.next"
mv "$rem_state.next" "$rem_state"
rem_write integration-review-capture --state "$rem_state" --authority-kind attach --at 2026-10-01T00:07:30Z >/dev/null
cp "$rem_dir/run.json" "$tmp/rem-pending-attach.json"
cp "$tmp/rem-release-r2-state.json" "$rem_state"
expect_refused "release history cannot contradict retained R1 attachment" "integration-receipt-required" rem_transition
cmp -s "$rem_dir/run.json" "$tmp/rem-pending-attach.json" || fail "contradictory release refusal changed the record"
# Public capture deliberately does not mutate caller input: use its retained
# controls as the canonical state the integrator would have attached itself.
rem_attach_digest="$(jq -r '.interventions[-1].note' "$rem_dir/run.json" | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"
jq '.snapshot' "$rem_dir/rulings/$rem_attach_digest" >"$rem_state"
expect_refused "nonterminal attach cannot count as terminal" "integration-receipt-required" rem_transition
CAPTURE_CLEAN=1 expect_refused "live terminal cycle still requires receipt" "integration-receipt-required" rem_transition
pass "pending attach refuses without an admitted terminal receipt"
# An old terminal file must never replace canonical live state, even before
# the owner has captured the live newer reservation.
cp "$rem_state" "$tmp/rem-stale-state.json"
expect_refused "caller-named snapshot cannot replace canonical state" "not a supported canonical live state location" \
    rem_transition --finder-state "codex-cloud=$tmp/rem-stale-state.json"
jq '.phase="reserved" | .charged_cycles=2 | .attempt=1 | .trigger_comment_id=null | .reserved_at="2026-10-01T00:08:00Z"' \
    "$rem_state" >"$rem_state.next"
mv "$rem_state.next" "$rem_state"
CAPTURE_CLEAN=1 expect_refused "retained cycle debt refuses before classifying newer uncaptured live state" "integration-receipt-required" rem_transition
pass "stale caller-named state and newer unretained live reservation both refuse"
cp "$tmp/rem-stale-state.json" "$rem_state"
# #1630: genuinely admit checker-only cycle 1 before any role exists. The
# existing fixture captured a pending attachment; live authentication observes
# its later clean reaction without enriching those immutable authority bytes.
cp "$rem_dir/run.json" "$tmp/checker-before.json"
CAPTURE_CLEAN=1 rem_write checker-cycle-receipt --state "$rem_state" --repo-dir "$repo" --at 2026-10-01T00:23:00Z >/dev/null
CAPTURE_CLEAN=1 rem_write checker-cycle-receipt --state "$rem_state" --repo-dir "$repo" --at 2026-10-01T00:23:15Z >/dev/null
checker_digest="$(jq -r '.checker_cycle_receipts[0].digest' "$rem_dir/run.json")"
checker_receipt="$rem_dir/checker-cycles/$checker_digest.json"
jq -e '.kind == "checker-cycle" and .cycle.cycle == 1 and .cycle.exit_code == 0 and
  .cycle.accepted.id == "901" and (has("producer") | not) and (has("role") | not)' "$checker_receipt" >/dev/null ||
    fail 'checker history fabricated an agent result or lost accepted evidence'
[ ! -e "$rem_dir/passes/integration-r1-integrator.json" ] || fail 'checker receipt consumed an integrator round'
cp "$rem_dir/run.json" "$tmp/checker-admitted.json"
CAPTURE_CLEAN=1 rem_transition >/dev/null
cp "$tmp/checker-admitted.json" "$rem_dir/run.json"
pass "authenticated checker receipt is immutable, idempotent and discharges head-movement debt without a role pass"
# Retained receipts remain checked even by the head-movement guard. Neither
# a missing file nor altered bytes can turn historical evidence into authority.
cp "$checker_receipt" "$tmp/checker-receipt-original.json"
printf '\n' >>"$checker_receipt"
CAPTURE_CLEAN=1 expect_refused "altered historical checker bytes" "checker receipt digest mismatch" rem_transition
cp "$tmp/checker-receipt-original.json" "$checker_receipt"
mv "$checker_receipt" "$checker_receipt.missing"
CAPTURE_CLEAN=1 expect_refused "missing historical checker bytes" "checker-cycles" rem_transition
mv "$checker_receipt.missing" "$checker_receipt"
cp "$rem_dir/run.json" "$tmp/checker-mixed-start.json"
# A real new head with unavailable carry proof owes cycle 2. Preserve the
# original admitted cycle and its ordinal; the actual first role pass is r1.
cp "$rem_state" "$tmp/checker-state-before-catchup.json"
cp "${rem_state%.json}.spend.json" "$tmp/checker-spend-before-catchup.json"
cp "$rem_dir/policy.json" "$tmp/checker-policy-before-catchup.json"
resolve_fixture_policy "$rem_dir/policy.json" 5
# The owner normally retains the resolver's provenance in the run projection.
# This writer fixture used only raw resolver output until it reached readiness.
jq '.rigor.source = (.rigor.chosen_by // "default_rigor")' "$rem_dir/policy.json" >"$rem_dir/policy.json.next"
mv "$rem_dir/policy.json.next" "$rem_dir/policy.json"
checker_original_head="$integration_head"
checker_base_advance="$(printf 'fixture base advance\n' | git -C "$repo" commit-tree "$capture_base^{tree}" -p "$capture_base")"
checker_catchup="$(printf 'fixture base catch-up\n' | git -C "$repo" commit-tree "$integration_head^{tree}" -p "$integration_head" -p "$checker_base_advance")"
git -C "$repo" update-ref "refs/heads/$integration_branch" "$checker_catchup" "$integration_head"
integration_head="$checker_catchup"
# No reviewed base identity was available to the initial checker state. The
# actual carry command must refuse, so no carried evidence is invented.
jq --arg origin "$checker_original_head" '.last_reviewed_head=$origin | .last_reviewed_verdict="clean" |
  .last_reviewed_base_sha=null' "$rem_state" >"$rem_state.next"
mv "$rem_state.next" "$rem_state"
checker_carry_rc=0
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" \
    bash "$recovery_checker" carry --state "$rem_state" --head "$integration_head" --run-id run-remediation --repo-dir "$repo" \
    --record "$rem_dir") >"$tmp/checker-carry.json" 2>&1 || checker_carry_rc=$?
[ "$checker_carry_rc" -eq 17 ] || fail "unavailable base proof did not refuse carry: $(cat "$tmp/checker-carry.json")"
CAPTURE_CLEAN=1 expect_refused "checker history cannot be backfilled after a head move" "checker receipt authentication failed" \
    rem_write checker-cycle-receipt --state "$rem_state" --repo-dir "$repo" --at 2026-10-01T00:32:00Z
# Use the real checker reservation and owner captures for the actual second
# review. Its clean result is a genuine dispatched integrator envelope.
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_NOW=2026-10-01T00:23:30Z CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" \
    bash "$recovery_checker" reserve --state "$rem_state" --repo example/repo --pr 493 \
    --head "$integration_head" --attempt 1 --run-id run-remediation --timeout-min 10 --finder codex-cloud \
    --record "$rem_dir" --integration-cap 5) >/dev/null
rem_write integration-review-capture --state "$rem_state" --authority-kind reserve --at 2026-10-01T00:23:31Z >/dev/null
jq '.phase="attached" | .trigger_comment_id="202"' "$rem_state" >"$rem_state.next"
mv "$rem_state.next" "$rem_state"
CAPTURE_CLEAN=1 CAPTURE_REACTION_AT=2026-10-01T00:25:00Z rem_write integration-review-capture --state "$rem_state" --authority-kind attach --at 2026-10-01T00:25:30Z >/dev/null
checker_second_digest="$(jq -r '.interventions[-1].note' "$rem_dir/run.json" | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"
jq '.snapshot' "$rem_dir/rulings/$checker_second_digest" >"$rem_state"
checker_second_pass="$tmp/checker-second-integrator.json"
jq --arg head "$integration_head" '.run.run_id="run-remediation" | .head=$head | .produced_at="2026-10-01T00:35:00Z" |
  .payload.settled_at="2026-10-01T00:35:00Z" | .payload.integration_round=1 |
  .payload.codex_cycle={head:$head,cycle:2,charged:2,exempt:0,attempt:1,trigger_comment_id:"202",exit_code:0,
    accepted:{surface:"reaction",id:"901",reviewed_commit:$head}}' "$integration_pass" >"$checker_second_pass"
CAPTURE_CLEAN=1 CAPTURE_REACTION_AT=2026-10-01T00:25:00Z rem_write receipt --pass "$checker_second_pass" --codex-state "$rem_state" --codex-repo-dir "$repo" >/dev/null
jq -n --arg head "$integration_head" '{schema:2,run_id:"run-remediation",stage:"integration",round:1,reviewed_head:$head,adjudications:[]}' \
    >"$tmp/checker-second-adjudication.json"
rem_write adjudicate --file "$tmp/checker-second-adjudication.json" >/dev/null
node --input-type=module -e '
 const { integrationExitForRunDir } = await import(process.argv[2]);
 const result = await integrationExitForRunDir(process.argv[1], { integrationCap:5 });
 if (result.outcome !== "converged" || result.rounds_counted !== 2 || result.clean_streak !== 2 ||
     result.cycles[0].rounds.length !== 0 || result.cycles[1].rounds[0] !== 1) throw new Error(JSON.stringify(result));
' "$rem_dir" "$asset_dir/dev-flow-exit.mjs" || fail 'mixed checker/dispatched history did not retain both actual cycles'
MIXED_REAL_CHECKER="$recovery_checker" MIXED_CHECKER_PATH="$capture_bin:$PATH" \
    CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" CAPTURE_CLEAN=1 CAPTURE_REACTION_AT=2026-10-01T00:25:00Z \
    bash "$source_root/scripts/test-integrate-readiness.sh" --checker-history-record "$rem_dir" "$rem_state" "$repo" >"$tmp/checker-readiness.log" 2>&1 ||
    fail "actual mixed history failed readiness: $(cat "$tmp/checker-readiness.log")"
pass "checker-only cycle 1 → catch-up without carry → actual dispatched cycle 2/pass round 1 retains contiguous clean history"
# Restore this isolated fixture branch and record for the independent tests.
git -C "$repo" update-ref "refs/heads/$integration_branch" "$checker_original_head" "$checker_catchup"
integration_head="$checker_original_head"
cp "$tmp/checker-state-before-catchup.json" "$rem_state"
cp "$tmp/checker-spend-before-catchup.json" "${rem_state%.json}.spend.json"
cp "$tmp/checker-policy-before-catchup.json" "$rem_dir/policy.json"
rm -f "$rem_dir/passes/integration-r1-integrator.json" "$rem_dir/adjudications/integration-r1.json"

# Keep the actual admitted receipt for the mixed-history integration fixture.
# Restore the independent role-only debt regressions below to their own state.
cp "$tmp/checker-before.json" "$rem_dir/run.json"

# A true admitted terminal receipt allows the transition, even though the
# immutable attach capture was pending. Receipt authenticates its fresh verdict.
rem_pass="$tmp/rem-integrator-pass.json"
jq --arg head "$integration_head" '.run.run_id="run-remediation" | .head=$head | .produced_at="2026-10-01T00:30:00Z" |
  .payload.settled_at="2026-10-01T00:30:00Z" | .payload.integration_round=1 |
  .payload.codex_cycle={head:$head,cycle:1,attempt:1,trigger_comment_id:"200",exit_code:0,
    accepted:{surface:"reaction",id:"901",reviewed_commit:$head}}' "$integration_pass" >"$rem_pass"
CAPTURE_CLEAN=1 rem_write receipt --pass "$rem_pass" --codex-state "$rem_state" --codex-repo-dir "$repo" >/dev/null
cp "$rem_dir/run.json" "$tmp/rem-receipted.json"
CAPTURE_CLEAN=1 rem_transition >/dev/null
cp "$tmp/rem-receipted.json" "$rem_dir/run.json"
pass "fresh terminal observation with an admitted receipt permits remediation"
# A receipt only pays the exact captured cycle. If live state advances or is
# replaced, remediation still refuses but must never poll GitHub under the lock.
jq '.trigger_comment_id="201"' "$rem_state" >"$rem_state.next"
mv "$rem_state.next" "$rem_state"
cat >"$tmp/rem-forbidden-check.cjs" <<'JS'
const cp = require('node:child_process')
const fs = require('node:fs')
const original = cp.execFileSync
cp.execFileSync = function (command, args, ...rest) {
  if (command === 'bash' && args?.[0]?.endsWith('/check-codex-cloud-review.sh') && args[1] === 'check') {
    fs.appendFileSync(process.env.REMEDIATION_CHECKER_CALL_LOG, 'check\n')
    throw new Error('receipt refusal must not invoke the checker')
  }
  return original.call(this, command, args, ...rest)
}
require('node:module').syncBuiltinESMExports()
JS
cp "$rem_dir/run.json" "$tmp/rem-before-unreceipted-frontier.json"
rm -f "$tmp/rem-checker-calls.log"
output="$(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" \
    REMEDIATION_CHECKER_CALL_LOG="$tmp/rem-checker-calls.log" NODE_OPTIONS="--require=$tmp/rem-forbidden-check.cjs" \
    RUN_RECORD_OWNER_TOKEN="$(token_for s-remediation)" node "$capture_writer" transition \
    --slate s-remediation --session alice --run-id run-remediation --stage implement --exit remediating \
    --at 2026-10-01T00:40:00Z 2>&1)" && fail "unreceipted live frontier unexpectedly passed: $output"
grep -qF 'finish polling, capture the terminal attach, dispatch the integrator and run receipt' <<<"$output" || fail "unreceipted live frontier refusal lacked recovery guidance: $output"
[ ! -e "$tmp/rem-checker-calls.log" ] || fail "unreceipted live frontier invoked the checker"
cmp -s "$rem_dir/run.json" "$tmp/rem-before-unreceipted-frontier.json" || fail "unreceipted refusal changed run.json"
[ ! -e "$rem_dir/run.json.wlock" ] || fail "unreceipted refusal left the run-record mutex behind"
pass "unreceipted live frontier refuses with guidance without checker calls or lock residue"
cp "$tmp/rem-stale-state.json" "$rem_state"
# Even an admitted old terminal snapshot cannot authorize a newer reservation.
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" \
    bash "$recovery_checker" check --state "$rem_state" --run-id run-remediation --repo-dir "$repo") >/dev/null
cp "$rem_state" "$tmp/rem-old-terminal.json"
# A later head's paid review cannot receipt R1's old-head reservation. Its
# preserved exact release history must settle R1 independently instead.
cp "${rem_state%.json}.spend.json" "$tmp/rem-before-release-head-spend.json"
mv "$rem_dir/passes/integration-r1-integrator.json" "$tmp/rem-before-release-head-pass.json"
cp "$tmp/rem-reserved.json" "$rem_dir/run.json"
cp "$tmp/rem-exact-released.json" "$rem_state"
rem_release_head_a="$integration_head"
rem_release_head_b="$(git -C "$repo" commit-tree "$integration_head^{tree}" -p "$integration_head" -m 'review after an unused released reservation')"
git -C "$repo" update-ref "refs/heads/$integration_branch" "$rem_release_head_b" "$rem_release_head_a"
integration_head="$rem_release_head_b"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_NOW=2026-10-01T00:21:00Z CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" \
    bash "$recovery_checker" reserve --state "$rem_state" --repo example/repo --pr 493 \
    --head "$integration_head" --attempt 1 --run-id run-remediation --timeout-min 10 --finder codex-cloud) >/dev/null
rem_write integration-review-capture --state "$rem_state" --authority-kind reserve --at 2026-10-01T00:21:30Z >/dev/null
jq '.phase="attached" | .trigger_comment_id="202"' "$rem_state" >"$rem_state.next"
mv "$rem_state.next" "$rem_state"
CAPTURE_CLEAN=1 CAPTURE_REACTION_AT=2026-10-01T00:25:00Z rem_write integration-review-capture \
    --state "$rem_state" --authority-kind attach --at 2026-10-01T00:25:30Z >/dev/null
rem_release_attach_digest="$(jq -r '.interventions[-1].note' "$rem_dir/run.json" | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"
jq '.snapshot' "$rem_dir/rulings/$rem_release_attach_digest" >"$rem_state"
jq --arg head "$integration_head" '.head=$head | .payload.codex_cycle.head=$head |
  .payload.codex_cycle.trigger_comment_id="202" | .payload.codex_cycle.accepted.reviewed_commit=$head' \
    "$rem_pass" >"$tmp/rem-released-new-head-pass.json"
CAPTURE_CLEAN=1 CAPTURE_REACTION_AT=2026-10-01T00:25:00Z rem_write receipt \
    --pass "$tmp/rem-released-new-head-pass.json" --codex-state "$rem_state" --codex-repo-dir "$repo" >/dev/null
CAPTURE_CLEAN=1 rem_transition >/dev/null
git -C "$repo" update-ref "refs/heads/$integration_branch" "$rem_release_head_a" "$rem_release_head_b"
integration_head="$rem_release_head_a"
mv "$rem_dir/passes/integration-r1-integrator.json" "$tmp/rem-release-head-admitted-pass.json"
mv "$tmp/rem-before-release-head-pass.json" "$rem_dir/passes/integration-r1-integrator.json"
cp "$tmp/rem-receipted.json" "$rem_dir/run.json"
cp "$tmp/rem-old-terminal.json" "$rem_state"
cp "$tmp/rem-before-release-head-spend.json" "${rem_state%.json}.spend.json"
pass "released R1 plus a new-head receipted R2 settles independently"
# Recovery can restore a paid cycle's state while a newer reservation's spend
# survives, even though that reservation crashed before authority capture.
rem_spend="${rem_state%.json}.spend.json"
cp "$rem_spend" "$tmp/rem-spend-before-rollback.json"
for newer_spend in '{"charged":2,"exempt":0}' '{"charged":0,"exempt":2}'; do
    jq -n --argjson spend "$newer_spend" '{"run-remediation":$spend}' >"$rem_spend"
    CAPTURE_CLEAN=1 expect_refused "old paid state cannot hide newer unretained sidecar spend" "spend exceeds its matching live state" rem_transition
    cmp -s "$rem_dir/run.json" "$tmp/rem-receipted.json" || fail "newer spend refusal changed the record"
done
pass "restored older receipted state refuses higher sidecar spend without newer retained authority"
for malformed_spend in 'null' '{}' '[]' '{"charged":1}' '{"charged":null,"exempt":0}' \
    '{"charged":"1","exempt":0}' '{"charged":-1,"exempt":0}' '{"charged":0.5,"exempt":0}' \
    '{"charged":0,"exempt":null}' '{"charged":0,"exempt":"1"}' \
    '{"charged":0,"exempt":-1}' '{"charged":0,"exempt":0.5}'; do
    jq -n --argjson spend "$malformed_spend" '{"run-remediation":$spend}' >"$rem_spend"
    CAPTURE_CLEAN=1 expect_refused "present run spend requires both nonnegative integer counters" "invalid current-run spend counters" rem_transition
    cmp -s "$rem_dir/run.json" "$tmp/rem-receipted.json" || fail "malformed spend refusal changed the record"
done
printf '{broken\n' >"$rem_spend"
CAPTURE_CLEAN=1 expect_refused "malformed sidecar is not missing evidence" "integration-remediation-unsettled" rem_transition
rm "$rem_spend"
mkdir "$rem_spend"
CAPTURE_CLEAN=1 expect_refused "unreadable sidecar is not missing evidence" "integration-remediation-unsettled" rem_transition
rmdir "$rem_spend"
cmp -s "$rem_dir/run.json" "$tmp/rem-receipted.json" || fail "unreadable spend refusal changed the record"
# Equal totals with a different charged/exempt split are valid after CI
# reclassification. A lower total also does not contradict the paid state.
for settled_spend in '{"charged":0,"exempt":1}' '{"charged":0,"exempt":0}'; do
    jq -n --argjson spend "$settled_spend" '{"run-remediation":$spend}' >"$rem_spend"
    CAPTURE_CLEAN=1 rem_transition >/dev/null
    cp "$tmp/rem-receipted.json" "$rem_dir/run.json"
done
cp "$tmp/rem-spend-before-rollback.json" "$rem_spend"
pass "spend validation fails closed while accepting equal reclassified and lower cycle totals"
jq '.phase="reserved" | .charged_cycles=2 | .attempt=1 | .trigger_comment_id=null |
  .first_trigger_comment_id=null | .requested_at=null | .reserved_at="2026-10-01T00:08:00Z"' \
    "$rem_state" >"$rem_state.next"
mv "$rem_state.next" "$rem_state"
rem_write integration-review-capture --state "$rem_state" --authority-kind reserve --at 2026-10-01T00:08:30Z >/dev/null
cp "$rem_state" "$tmp/rem-new-reserve-state.json"
cp "$rem_dir/run.json" "$tmp/rem-new-reserve-record.json"
cp "$tmp/rem-old-terminal.json" "$rem_dir/codex-cloud-review.json"
rm "$rem_state"
CAPTURE_CLEAN=1 expect_refused "lost newer retained reservation cannot hide behind older settled copy" "integration-receipt-required" rem_transition
cmp -s "$rem_dir/run.json" "$tmp/rem-new-reserve-record.json" || fail "lost reservation refusal changed the record"
cp "$tmp/rem-new-reserve-state.json" "$rem_state"
rm "$rem_dir/codex-cloud-review.json"
pass "record-only reservation inventory refuses a lost second cycle even with a settled first-cycle copy"
CAPTURE_CLEAN=1 expect_refused "old receipted terminal snapshot cannot select a prior frontier" "not a supported canonical live state location" \
    rem_transition --finder-state "codex-cloud=$tmp/rem-old-terminal.json"
CAPTURE_CLEAN=1 expect_refused "new retained cycle remains pending after earlier receipt" "integration-receipt-required" rem_transition
cp "$tmp/rem-receipted.json" "$rem_dir/run.json"
cp "$tmp/rem-old-terminal.json" "$rem_state"
pass "stale terminal receipted snapshot cannot bypass a newer retained reservation"
# A custom finder outside integrate-codex is included in the live-state scan.
custom_rem_state="$repo/.git/integrate-custom-reviewer/example/repo/493.json"
mkdir -p "$(dirname "$custom_rem_state")"
jq '.finder.slug="custom-reviewer"' "$tmp/rem-reserve-state.json" >"$custom_rem_state"
rem_write integration-review-capture --state "$custom_rem_state" --authority-kind reserve --at 2026-10-01T00:08:30Z >/dev/null
CAPTURE_CLEAN=1 expect_refused "custom finder reservation cannot be ignored" "integration-receipt-required" rem_transition
cp "$tmp/rem-receipted.json" "$rem_dir/run.json"
rm "$custom_rem_state"
pass "every PR-side finder slug is checked, including a custom finder"
# The bound lane is a real linked worktree. Its local Git dir differs from
# the shared driver/broker directory, while the owner may also keep run state.
git -C "$repo" checkout -q main
git -C "$repo" worktree add -q "$tmp/rem-bound-lane" "$integration_branch"
rem_lane_git="$(git -C "$tmp/rem-bound-lane" rev-parse --path-format=absolute --git-dir)"
[ "$rem_lane_git" != "$repo/.git" ] || fail "remediation fixture is not a linked worktree"
mv "$rem_state" "$tmp/rem-common-backup.json"
for location in record common; do
    case "$location" in
    record) rem_candidate="$rem_dir/codex-cloud-review.json" ;;
    common) rem_candidate="$rem_state" ;;
    esac
    cp "$tmp/rem-reserved.json" "$rem_dir/run.json"
    cp "$tmp/rem-old-terminal.json" "$rem_candidate"
    CAPTURE_CLEAN=1 expect_refused "$location retained reservation refuses before receipt" "integration-receipt-required" rem_transition
    cp "$tmp/rem-no-reservation.json" "$rem_dir/run.json"
    cp "$tmp/rem-reserve-state.json" "$rem_candidate"
    CAPTURE_CLEAN=1 expect_refused "$location uncaptured reservation is not absence" "live reservation has no retained reserve authority" rem_transition
    cp "$tmp/rem-receipted.json" "$rem_dir/run.json"
    cp "$tmp/rem-old-terminal.json" "$rem_candidate"
    CAPTURE_CLEAN=1 rem_transition --finder-state "codex-cloud=$rem_candidate" >/dev/null
    cp "$tmp/rem-receipted.json" "$rem_dir/run.json"
    rm "$rem_candidate"
    pass "$location state is found for a linked lane: retained and uncaptured refuse, receipted passes"
done
# Naming the settled owner-record candidate cannot hide a newer common state.
cp "$tmp/rem-old-terminal.json" "$rem_dir/codex-cloud-review.json"
jq '.phase="reserved" | .charged_cycles=2 | .trigger_comment_id=null |
  .reserved_at="2026-10-01T00:35:00Z"' "$tmp/rem-reserve-state.json" >"$rem_state"
CAPTURE_CLEAN=1 expect_refused "settled record state cannot hide unsettled common state" "uncaptured reservation" \
    rem_transition --finder-state "codex-cloud=$rem_dir/codex-cloud-review.json"
rm "$rem_state"
# An unreadable/invalid candidate never becomes authenticated absence just
# because a different supported location has a valid settled copy.
rem_local_state="$rem_lane_git/integrate-codex/example/repo/493.json"
mkdir -p "$(dirname "$rem_local_state")"
printf '{broken\n' >"$rem_local_state"
CAPTURE_CLEAN=1 expect_refused "malformed local state refuses beside settled record state" "integration-remediation-unsettled" rem_transition
rm "$rem_local_state"
# Explicit --finder codex-cloud uses the named directory. Both common and
# linked-worktree locations remain candidates alongside the legacy directory.
cp "$tmp/rem-old-terminal.json" "$rem_state"
for named_git_dir in "$repo/.git" "$rem_lane_git"; do
    named_rem_state="$named_git_dir/integrate-codex-cloud/example/repo/493.json"
    mkdir -p "$(dirname "$named_rem_state")"
    jq '.reserved_at="2026-10-01T00:35:00Z"' "$tmp/rem-reserve-state.json" >"$named_rem_state"
    CAPTURE_CLEAN=1 expect_refused "settled legacy state cannot hide uncaptured named Codex pending state" "uncaptured reservation" \
        rem_transition --finder-state "codex-cloud=$rem_state"
    cmp -s "$rem_dir/run.json" "$tmp/rem-receipted.json" || fail "named-state refusal changed the record"
    rm "$named_rem_state"
    printf '{"run-remediation":{"charged":1,"exempt":0}}\n' >"${named_rem_state%.json}.spend.json"
    CAPTURE_CLEAN=1 expect_refused "named Codex spend without state cannot be missed" "has run spend without live reservation state" rem_transition
    rm "${named_rem_state%.json}.spend.json"
done
rm "$rem_state" "$rem_dir/codex-cloud-review.json"
pass "both legacy and named Codex state and sidecars are scanned in common and lane Git directories"
pass "every existing candidate must settle; an asserted settled path never narrows the scan"
# Discover uncaptured custom finders beside a settled Codex candidate.
mv "$tmp/rem-common-backup.json" "$rem_state"
for location in record common; do
    slug="custom-$location"
    case "$location" in
    record) custom_candidate="$rem_dir/$slug-review.json" ;;
    common) custom_candidate="$repo/.git/integrate-$slug/example/repo/493.json" ;;
    esac
    mkdir -p "$(dirname "$custom_candidate")"
    jq --arg slug "$slug" '.finder.slug=$slug' "$tmp/rem-reserve-state.json" >"$custom_candidate"
    CAPTURE_CLEAN=1 expect_refused "$location custom finder discovery refuses uncaptured state" "live reservation has no retained reserve authority" rem_transition
    rm "$custom_candidate"
done
pass "finder discovery scans record and common directories as well as the linked lane Git directory"
# Common state from a different run is not this run's review history.
foreign_candidate="$repo/.git/integrate-foreign-common/example/repo/493.json"
mkdir -p "$(dirname "$foreign_candidate")"
jq '.run_id="another-run" | .finder.slug="foreign-common"' "$tmp/rem-reserve-state.json" >"$foreign_candidate"
CAPTURE_CLEAN=1 rem_transition >/dev/null
cp "$tmp/rem-receipted.json" "$rem_dir/run.json"
pass "another run's common state is ignored when this run never reserved the finder"
foreign_spend="${foreign_candidate%.json}.spend.json"
printf '{"run-remediation":{"charged":1,"exempt":0}}\n' >"$foreign_spend"
CAPTURE_CLEAN=1 expect_refused "another run's common state cannot erase this run's spend" "retains authority or spend" rem_transition
rm "$foreign_candidate" "$foreign_spend"
pass "foreign common state refuses when this run holds finder spend"
# Discover charged spend even after a custom finder's record state was lost.
lost_spend="$rem_dir/lost-custom-review.spend.json"
printf '{"run-remediation":{"charged":1,"exempt":0}}\n' >"$lost_spend"
CAPTURE_CLEAN=1 expect_refused "record-only custom spend is not absence" "has run spend without live reservation state" rem_transition
rm "$lost_spend"
pass "record-directory spend-only custom finder discovery refuses lost charged state"
# An old same-run copy can coexist with a later, independently receipted cycle.
cp "$tmp/rem-old-terminal.json" "$rem_dir/codex-cloud-review.json"
resolve_fixture_policy "$rem_dir/policy.json" 2
rem_adjudication="$tmp/rem-cycle-one-adjudication.json"
jq -n --arg head "$integration_head" '{schema:2,run_id:"run-remediation",stage:"integration",round:1,
  reviewed_head:$head,adjudications:[]}' >"$rem_adjudication"
rem_write adjudicate --file "$rem_adjudication" >/dev/null
jq '.phase="reserved" | .charged_cycles=2 | .exempt_cycles=0 | .attempt=1 |
  .trigger_comment_id=null | .first_trigger_comment_id=null | .requested_at=null |
  .first_requested_at=null | .reserved_at="2026-10-01T00:23:00Z"' "$tmp/rem-old-terminal.json" >"$rem_state"
rem_write integration-review-capture --state "$rem_state" --authority-kind reserve --at 2026-10-01T00:23:30Z >/dev/null
jq '.phase="attached" | .trigger_comment_id="202"' "$rem_state" >"$rem_state.next"
mv "$rem_state.next" "$rem_state"
CAPTURE_CLEAN=1 CAPTURE_REACTION_AT=2026-10-01T00:25:00Z rem_write integration-review-capture \
    --state "$rem_state" --authority-kind attach --at 2026-10-01T00:25:30Z >/dev/null
rem_current_digest="$(jq -r '.interventions[-1].note' "$rem_dir/run.json" | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"
jq '.snapshot' "$rem_dir/rulings/$rem_current_digest" >"$rem_state"
jq '.payload.integration_round=2 | .payload.codex_cycle.cycle=2 |
  .payload.codex_cycle.trigger_comment_id="202"' "$rem_pass" >"$tmp/rem-cycle-two-pass.json"
CAPTURE_CLEAN=1 CAPTURE_REACTION_AT=2026-10-01T00:25:00Z rem_write receipt \
    --pass "$tmp/rem-cycle-two-pass.json" --codex-state "$rem_state" --codex-repo-dir "$repo" >/dev/null
CAPTURE_CLEAN=1 CAPTURE_REACTION_AT=2026-10-01T00:25:00Z rem_transition \
    --finder-state "codex-cloud=$rem_dir/codex-cloud-review.json" >/dev/null
cp "$tmp/rem-receipted.json" "$rem_dir/run.json"
cp "$tmp/rem-policy.json" "$rem_dir/policy.json"
cp "$tmp/rem-old-terminal.json" "$rem_state"
rm "$rem_dir/codex-cloud-review.json"
pass "older same-run settled record copy and current settled common copy both pass"
# A paid cycle on A stays paid when after-ci sees head B before a new reserve.
# Patch only the test process boundary and assert check is never invoked.
rem_no_check_hook="$tmp/rem-checker-forbidden.cjs"
cat >"$rem_no_check_hook" <<'JS'
const cp = require('node:child_process')
const fs = require('node:fs')
const original = cp.execFileSync
cp.execFileSync = function (command, args, ...rest) {
  if (command === 'bash' && args?.[0]?.endsWith('/check-codex-cloud-review.sh') && args[1] === 'check') {
    fs.appendFileSync(process.env.REMEDIATION_CHECKER_CALL_LOG, 'check\n')
    throw new Error('receipted cycle must not invoke the checker')
  }
  return original.call(this, command, args, ...rest)
}
require('node:module').syncBuiltinESMExports()
JS
rem_moved_head="$(git -C "$repo" commit-tree "$integration_head^{tree}" -p "$integration_head" -m 'head moved before after-ci reservation')"
git -C "$repo" update-ref "refs/heads/$integration_branch" "$rem_moved_head" "$integration_head"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$rem_moved_head" CAPTURE_BASE="$capture_base" \
    REMEDIATION_CHECKER_CALL_LOG="$tmp/rem-head-move-checks.log" NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--require=$rem_no_check_hook" \
    RUN_RECORD_OWNER_TOKEN="$(token_for s-remediation)" node "$capture_writer" transition \
    --slate s-remediation --session alice --run-id run-remediation --stage implement --exit remediating --at 2026-10-01T00:40:00Z) >/dev/null
[ ! -e "$tmp/rem-head-move-checks.log" ] || fail "receipted head A was re-polled after head B moved"
cp "$tmp/rem-receipted.json" "$rem_dir/run.json"
git -C "$repo" update-ref "refs/heads/$integration_branch" "$integration_head" "$rem_moved_head"
pass "receipted cycle on head A permits head B remediation without invoking the checker"
git -C "$repo" worktree remove "$tmp/rem-bound-lane"
git -C "$repo" checkout -q "$integration_branch"

# Caller cwd has no checker state. Only the bound lane's worktree is
# authoritative; a cross-worktree conductor must still see its pending review.
git -C "$repo" worktree add -q -b rem-conductor "$tmp/rem-conductor" "$integration_head"
rem_token="$(token_for s-remediation)"
cp "$tmp/rem-new-reserve-record.json" "$rem_dir/run.json"
expect_refused "cross-worktree caller cannot escape a retained cycle debt" "integration-receipt-required" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" transition --slate s-remediation --session alice --run-id run-remediation --stage implement --exit remediating --at 2026-10-01T00:40:00Z' _ \
    "$tmp/rem-conductor" "$capture_bin:$PATH" "$integration_head" "$capture_base" "$rem_token" "$capture_writer"
cp "$tmp/rem-receipted.json" "$rem_dir/run.json"
pass "cross-worktree transition preserves the record-only reservation check"
rem_write lock release >/dev/null
rm "$rem_state" "${rem_state%.json}.spend.json"

# reserved_at is the owner host's clock and the trigger's created_at is
# GitHub's. A host running fast by less than the checker's skew margin still
# attaches its own trigger; one beyond it, or a trigger an earlier cycle
# already consumed, refuses.
new_run run-clock-skew
write_plan s-clock-skew 41:run-clock-skew
acquire s-clock-skew alice --issues 41
skew_state="$tmp/skew-state.json"
jq -n --arg head "$integration_head" --argjson finder "$capture_finder" '{version:2,repo:"example/repo",pr:493,head:$head,phase:"reserved",trigger_comment_id:null,
  charged_cycles:1,exempt_cycles:0,attempt:1,run_id:"run-clock-skew",timeout_min:10,reserved_at:"2026-10-01T00:07:20Z",finder:$finder}' >"$skew_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-clock-skew)" node "$capture_writer" integration-review-capture \
    --slate s-clock-skew --session alice --run-id run-clock-skew --state "$skew_state" --authority-kind reserve --at 2026-10-01T00:07:25Z) >/dev/null
jq '.phase="attached" | .trigger_comment_id="200"' "$skew_state" >"$skew_state.next"
mv "$skew_state.next" "$skew_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-clock-skew)" node "$capture_writer" integration-review-capture \
    --slate s-clock-skew --session alice --run-id run-clock-skew --state "$skew_state" --authority-kind attach --at 2026-10-01T00:08:00Z) >/dev/null ||
    fail "a host clock 20s ahead of GitHub refused its own post-reservation trigger"
skew_cycle2_state="$tmp/skew-cycle2-state.json"
jq '.phase="reserved" | .charged_cycles=2 | .trigger_comment_id=null | .requested_at=null | .reserved_at="2026-10-01T00:07:30Z"' "$skew_state" >"$skew_cycle2_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-clock-skew)" node "$capture_writer" integration-review-capture \
    --slate s-clock-skew --session alice --run-id run-clock-skew --state "$skew_cycle2_state" --authority-kind reserve --at 2026-10-01T00:08:30Z) >/dev/null
jq '.phase="attached" | .trigger_comment_id="200"' "$skew_cycle2_state" >"$skew_cycle2_state.next"
mv "$skew_cycle2_state.next" "$skew_cycle2_state"
expect_refused "skew allowance never re-attaches a trigger an earlier cycle consumed" "post-reservation owner request" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_CLEAN=1 CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" integration-review-capture --slate s-clock-skew --session alice --run-id run-clock-skew --state "$7" --authority-kind attach --at 2026-10-01T00:09:00Z' _ \
    "$repo" "$capture_bin:$PATH" "$integration_head" "$capture_base" "$(token_for s-clock-skew)" "$capture_writer" "$skew_cycle2_state"
new_run run-clock-skew-far
write_plan s-clock-skew-far 42:run-clock-skew-far
acquire s-clock-skew-far alice --issues 42
skew_far_state="$tmp/skew-far-state.json"
jq '.run_id="run-clock-skew-far" | .phase="reserved" | .trigger_comment_id=null | .requested_at=null | .reserved_at="2026-10-01T00:12:30Z"' "$skew_state" >"$skew_far_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-clock-skew-far)" node "$capture_writer" integration-review-capture \
    --slate s-clock-skew-far --session alice --run-id run-clock-skew-far --state "$skew_far_state" --authority-kind reserve --at 2026-10-01T00:12:35Z) >/dev/null
jq '.phase="attached" | .trigger_comment_id="200"' "$skew_far_state" >"$skew_far_state.next"
mv "$skew_far_state.next" "$skew_far_state"
expect_refused "a trigger beyond the skew margin before reservation refuses" "post-reservation owner request" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_CLEAN=1 CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" integration-review-capture --slate s-clock-skew-far --session alice --run-id run-clock-skew-far --state "$7" --authority-kind attach --at 2026-10-01T00:13:00Z' _ \
    "$repo" "$capture_bin:$PATH" "$integration_head" "$capture_base" "$(token_for s-clock-skew-far)" "$capture_writer" "$skew_far_state"
pass "attach capture tolerates bounded host clock skew without re-attaching a consumed or stale trigger"

# A requested-reviewer finder has no comment ID. Public owner capture derives
# its request time from an authenticated timeline event, keyed by the retained
# reviewer actor ID, and refuses a malformed owner event on replay.
new_run run-requested-reviewer
write_plan s-requested-reviewer 25:run-requested-reviewer
acquire s-requested-reviewer alice --issues 25
for transition in 'claim:kicked' 'implement:claimed' 'verify:implemented' 'challenge:verified' 'security:converged' 'integration:secure'; do
    (cd "$repo" && RUN_RECORD_OWNER_TOKEN="$(token_for s-requested-reviewer)" node "$capture_writer" transition \
        --slate s-requested-reviewer --session alice --run-id run-requested-reviewer \
        --stage "${transition%%:*}" --exit "${transition#*:}" --at 2026-10-01T00:05:00Z) >/dev/null
done
(cd "$repo" && RUN_RECORD_OWNER_TOKEN="$(token_for s-requested-reviewer)" node "$capture_writer" bind-pr \
    --slate s-requested-reviewer --session alice --run-id run-requested-reviewer --number 493 \
    --url https://github.com/example/repo/pull/493 --at 2026-10-01T00:06:00Z) >/dev/null
requested_finder="$(jq -c '
  .finders[] | select(.slug == "copilot-cloud") | {
    slug, actor_id:(.trusted_actor_id|tostring), actor_login:.trusted_actor_login,
    trigger_mechanism:.collection.trigger.mechanism, trigger_body:.collection.trigger.body,
    reviewer_login:.collection.trigger.reviewer_login, surfaces:.collection.terminal_signals.surfaces,
    head_binding:.collection.terminal_signals.head_binding, verdict_mode:.collection.terminal_signals.verdict_mode,
    clean_verdict:.collection.terminal_signals.clean_verdict, actionable_pattern:.collection.terminal_signals.actionable_pattern,
    severity_marker:.collection.terminal_signals.severity_marker, metadata_line:.collection.terminal_signals.metadata_line,
    about_summary:.collection.terminal_signals.about_summary, heading:.collection.terminal_signals.heading,
    carrier_sentence:.collection.terminal_signals.carrier_sentence, success_reaction:.collection.terminal_signals.success_reaction,
    pending_reaction:.collection.terminal_signals.pending_reaction
  }' "$asset_dir/../../../../../agent-registry.json")"
requested_state="$tmp/requested-reviewer-state.json"
jq -n --arg head "$integration_head" --argjson finder "$requested_finder" '{version:2,repo:"example/repo",pr:493,head:$head,phase:"reserved",trigger_comment_id:null,
  first_trigger_comment_id:null,charged_cycles:1,exempt_cycles:0,attempt:1,run_id:"run-requested-reviewer",timeout_min:10,reserved_at:"2026-10-01T00:06:00Z",finder:$finder}' >"$requested_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_NOW=2026-10-01T00:07:30Z CAPTURE_EPOCH=1790813250 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-requested-reviewer)" node "$capture_writer" integration-review-capture \
    --slate s-requested-reviewer --session alice --run-id run-requested-reviewer --state "$requested_state" --authority-kind reserve --at 2026-10-01T00:06:30Z) >/dev/null
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_REQUESTED_REVIEWER=large CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-requested-reviewer)" node "$capture_writer" integration-review-capture \
    --slate s-requested-reviewer --session alice --run-id run-requested-reviewer --state "$requested_state" --authority-kind attach --at 2026-10-01T00:07:30Z) >/dev/null
AUTH_COMMON="$repo/.git" AUTH_RUN=run-requested-reviewer AUTH_RECORD="$state/runs/run-requested-reviewer/run.json" node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const { retainedAuthorities } = await import(process.argv[1]);
  const record = JSON.parse(readFileSync(process.env.AUTH_RECORD));
  const attached = retainedAuthorities(record, { common: process.env.AUTH_COMMON, runId: process.env.AUTH_RUN })
    .find((entry) => entry.kind === "attach")?.authority.snapshot;
  if (!attached || attached.trigger_comment_id !== null || attached.requested_at !== "2026-10-01T00:07:00Z" ||
      attached.first_requested_at !== "2026-10-01T00:07:00Z" || attached.finder?.slug !== "copilot-cloud" ||
      attached.last_reviewed_verdict !== "clean" || attached.last_reviewed_head !== process.argv[2]) process.exit(1);
' "$asset_dir/lib/integrator-review-authority.mjs" "$integration_head" || fail "requested-reviewer capture did not retain a clean authenticated timeline request from a projected large page"
expect_refused "requested-reviewer capture rejects malformed owner evidence" "exactly one owner request" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_REQUESTED_REVIEWER=malformed-owner CAPTURE_CLEAN=1 CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" integration-review-capture --slate s-requested-reviewer --session alice --run-id run-requested-reviewer --state "$7" --authority-kind attach --at 2026-10-01T00:08:00Z' _ \
    "$repo" "$capture_bin:$PATH" "$integration_head" "$capture_base" "$(token_for s-requested-reviewer)" "$capture_writer" "$requested_state"
expect_refused "requested-reviewer capture rejects matching owner requests on separate projected pages" "exactly one owner request" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_REQUESTED_REVIEWER=paginated-ambiguous CAPTURE_CLEAN=1 CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" integration-review-capture --slate s-requested-reviewer --session alice --run-id run-requested-reviewer --state "$7" --authority-kind attach --at 2026-10-01T00:08:00Z' _ \
    "$repo" "$capture_bin:$PATH" "$integration_head" "$capture_base" "$(token_for s-requested-reviewer)" "$capture_writer" "$requested_state"
for requested_case in absent ambiguous wrong-reviewer; do
    expect_refused "requested-reviewer capture rejects $requested_case reviewer evidence" "exactly one owner request" \
        bash -c 'cd "$1" && PATH="$2" CAPTURE_REQUESTED_REVIEWER="$3" CAPTURE_CLEAN=1 CAPTURE_HEAD="$4" CAPTURE_BASE="$5" RUN_RECORD_OWNER_TOKEN="$6" node "$7" integration-review-capture --slate s-requested-reviewer --session alice --run-id run-requested-reviewer --state "$8" --authority-kind attach --at 2026-10-01T00:08:00Z' _ \
        "$repo" "$capture_bin:$PATH" "$requested_case" "$integration_head" "$capture_base" "$(token_for s-requested-reviewer)" "$capture_writer" "$requested_state"
done
requested_parent_digest="$(jq -r '.interventions[] | select(.note | startswith("integration-review-authority v1 attach sha256=")) | .note' "$state/runs/run-requested-reviewer/run.json" | tail -1 | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"
# Requested-reviewer observations are finder evidence, not a synthetic Codex
# comment cycle. Resolve the production optional-Codex form so a null Codex
# cycle remains legitimate while the completed Copilot cycle is schema-checked.
resolve_fixture_policy "$state/runs/run-requested-reviewer/policy.json" 1 after-ci optional-codex-required-copilot
jq -e '.rounds.integration == 1 and .stages.integration.finders == ["codex-cloud", "copilot-cloud"] and
  (.stages.integration.finder | sort_by(.id) == [{id:"codex-cloud",gates:false,budget:1},{id:"copilot-cloud",gates:true,budget:1}])' \
    "$state/runs/run-requested-reviewer/policy.json" >/dev/null ||
    fail "production policy reader did not preserve optional Codex plus required Copilot"
git -C "$repo" branch fixture-run-requested-reviewer HEAD
requested_pass="$tmp/integration-r1-requested-reviewer.json"
jq --arg head "$integration_head" '
  .run = {run_id:"run-requested-reviewer",initiated_by:"human"} |
  .head = $head | .payload.integration_round = 1 |
  .produced_at = "2026-10-01T00:22:30Z" |
  .payload.settled_at = "2026-10-01T00:22:30Z" |
  .payload.codex_cycle = null |
  .payload.finder_cycles = [{finder:"copilot-cloud",head:$head,cycle:1,charged:1,exempt:0,attempt:1,exit_code:0,
    accepted:{surface:"review",id:"903",reviewed_commit:$head}}]
' "$integration_pass" >"$requested_pass"
printf '[]\n' >"$tmp/requested-reviewer-known-ids.json"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_REQUESTED_REVIEWER=1 CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" node "$fixture_support/assets/validate-result-schemas.mjs" integrator "$requested_pass" --receipt --run-id run-requested-reviewer --initiated-by human --known-ids "$tmp/requested-reviewer-known-ids.json" --integrator-record "$state/runs/run-requested-reviewer/run.json") >/dev/null ||
    fail "strict receipt validation rejected the real-registry requested-reviewer owner capture"
validate_requested_receipt() {
    (cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_REQUESTED_REVIEWER=1 CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" node "$fixture_support/assets/validate-result-schemas.mjs" integrator "$1" --receipt --run-id run-requested-reviewer --initiated-by human --known-ids "$tmp/requested-reviewer-known-ids.json" --integrator-record "$state/runs/run-requested-reviewer/run.json")
}
for mutation in fabricated-accepted missing-required duplicate-finder stale-head stale-counters; do
    case "$mutation" in
    fabricated-accepted) jq '.payload.finder_cycles[0].accepted.id = "999999999"' "$requested_pass" ;;
    missing-required) jq '.payload.finder_cycles = []' "$requested_pass" ;;
    duplicate-finder) jq '.payload.finder_cycles += [.payload.finder_cycles[0]]' "$requested_pass" ;;
    stale-head) jq '.payload.finder_cycles[0].head = ("f" * 40)' "$requested_pass" ;;
    stale-counters) jq '.payload.finder_cycles[0].cycle = 2 | .payload.finder_cycles[0].charged = 2' "$requested_pass" ;;
    esac >"$tmp/requested-reviewer-$mutation.json"
    if validate_requested_receipt "$tmp/requested-reviewer-$mutation.json" >"$tmp/requested-reviewer-$mutation.out" 2>&1; then
        fail "strict receipt validation admitted $mutation Copilot evidence"
    fi
done
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_REQUESTED_REVIEWER=1 CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-requested-reviewer)" node "$capture_writer" receipt --slate s-requested-reviewer --session alice --run-id run-requested-reviewer --pass "$requested_pass") >/dev/null ||
    fail "public writer rejected the real-registry required-Copilot receipt"
pass "required Copilot authenticates through strict validation and the public writer while Codex is optional; fabricated, omitted, duplicate, stale-head, and stale-counter evidence refuse"

# The explicit non-Codex per-PR budget is spent by the admitted head-A
# receipt. A later head-B receipt must omit that finder instead of fabricating
# a current cycle. Exercise both admission boundaries and invalid spend.
# Node subprocess stdin uses a socket on Linux, where opening /dev/stdin can
# fail ENXIO. Exercise that failure on every host while retaining the actual
# validator; its input must instead be a readable regular snapshot, cleaned up
# after successful and rejected envelope validation alike.
spend_preload="$tmp/spend-regular-input.cjs"
cat >"$spend_preload" <<'JS'
const fs = require('node:fs')
if (process.argv[1]?.endsWith('/validate-result-schemas.mjs') && process.argv[2] === 'envelope') {
  const input = process.argv[3]
  if (input === '/dev/stdin') {
    const error = new Error('ENXIO: cannot open subprocess stdin socket')
    error.code = 'ENXIO'
    throw error
  }
  if (!fs.statSync(input).isFile()) throw new Error('retained envelope validation requires a regular input file')
  fs.appendFileSync(process.env.SPEND_INPUT_LOG, `${input}\n`)
}
JS
spend_node_options="${NODE_OPTIONS:-}"
export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--require=$spend_preload"
export SPEND_INPUT_LOG="$tmp/spend-validator-inputs.log"
spent_record="$state/runs/run-requested-reviewer/run.json"
spent_prior="$state/runs/run-requested-reviewer/passes/integration-r1-integrator.json"
cp "$spent_record" "$tmp/spent-record-original.json"
cp "$spent_prior" "$tmp/spent-prior-original.json"
spent_head="$(printf 'test: next reviewed head\n' | git -C "$repo" commit-tree "${integration_head}^{tree}" -p "$integration_head")"
jq --arg head "$spent_head" '.head=$head | .payload.integration_round=2 | .payload.finder_cycles=[]' \
    "$requested_pass" >"$tmp/spent-next-head.json"
for mutation in unreceipted wrong-run same-head malformed; do
    cp "$tmp/spent-record-original.json" "$spent_record"
    cp "$tmp/spent-prior-original.json" "$spent_prior"
    case "$mutation" in
    unreceipted) jq '.receipts=[]' "$tmp/spent-record-original.json" >"$spent_record" ;;
    wrong-run) jq '.run.run_id="foreign-run"' "$tmp/spent-prior-original.json" >"$spent_prior" ;;
    same-head) jq --arg head "$spent_head" '.head=$head | .payload.finder_cycles[0].head=$head | .payload.finder_cycles[0].accepted.reviewed_commit=$head' "$tmp/spent-prior-original.json" >"$spent_prior" ;;
    malformed) jq '.payload.finder_cycles[0].cycle="1"' "$tmp/spent-prior-original.json" >"$spent_prior" ;;
    esac
    if validate_requested_receipt "$tmp/spent-next-head.json" >"$tmp/spent-$mutation.out" 2>&1; then
        fail "invalid $mutation prior spend waived a required finder"
    fi
done
cp "$tmp/spent-record-original.json" "$spent_record"
cp "$tmp/spent-prior-original.json" "$spent_prior"
validate_requested_receipt "$tmp/spent-next-head.json" >/dev/null ||
    fail "authenticated prior-head spend did not waive an explicitly exhausted non-Codex finder"
jq -n --arg head "$integration_head" '{schema:2,run_id:"run-requested-reviewer",stage:"integration",round:1,reviewed_head:$head,adjudications:[]}' >"$tmp/spent-adjudication.json"
(cd "$repo" && RUN_RECORD_OWNER_TOKEN="$(token_for s-requested-reviewer)" node "$capture_writer" adjudicate --slate s-requested-reviewer --session alice --run-id run-requested-reviewer --file "$tmp/spent-adjudication.json") >/dev/null
git -C "$repo" update-ref refs/heads/fixture-run-requested-reviewer "$spent_head" "$integration_head"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$spent_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-requested-reviewer)" node "$capture_writer" receipt --slate s-requested-reviewer --session alice --run-id run-requested-reviewer --pass "$tmp/spent-next-head.json") >/dev/null ||
    fail "public writer rejected head B after the admitted head-A finder budget was spent"
[ -s "$SPEND_INPUT_LOG" ] || fail "prior spend never reached real envelope validation"
while IFS= read -r spent_input; do
    [ ! -e "$spent_input" ] || fail "retained envelope validation left its temporary snapshot behind"
done <"$SPEND_INPUT_LOG"
if [ -n "$spend_node_options" ]; then export NODE_OPTIONS="$spend_node_options"; else unset NODE_OPTIONS; fi
unset SPEND_INPUT_LOG
pass "explicit non-Codex budget spent on head A admits omitted finder on head B; unreceipted, wrong-run, same-head and malformed spend refuse"

# A custom clean-sentence finder uses the canonical non-thread settlement
# path. Its current settlement is recorded after immutable attachment capture.
# Change only the hermetic trusted-registry fixture, never repository policy.
jq '(.finders[] | select(.slug == "codex-cloud") | .collection) as $collection |
    (.finders[] | select(.slug == "copilot-cloud") | .collection) = $collection' \
    "$asset_dir/../../../../../agent-registry.json" | base64 >"$capture_bin/custom-registry.b64"
custom_finder="$(jq -cn --argjson codex "$capture_finder" --argjson requested "$requested_finder" \
    '$codex + {slug:$requested.slug,actor_id:$requested.actor_id,actor_login:$requested.actor_login}')"
new_run run-custom-settlement
write_plan s-custom-settlement 27:run-custom-settlement
acquire s-custom-settlement alice --issues 27
custom_writer() {
    (cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CUSTOM=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-custom-settlement)" node "$capture_writer" "$@" --slate s-custom-settlement --session alice --run-id run-custom-settlement)
}
for transition in 'claim:kicked' 'implement:claimed' 'verify:implemented' 'challenge:verified' 'security:converged' 'integration:secure'; do
    custom_writer transition --stage "${transition%%:*}" --exit "${transition#*:}" --at 2026-10-01T00:05:00Z >/dev/null
done
custom_writer bind-pr --number 493 --url https://github.com/example/repo/pull/493 --at 2026-10-01T00:06:00Z >/dev/null
custom_record="$state/runs/run-custom-settlement/run.json"
resolve_fixture_policy "$state/runs/run-custom-settlement/policy.json" 1 after-ci optional-codex-required-copilot
git -C "$repo" branch fixture-run-custom-settlement "$integration_head"
custom_state="$repo/.git/integrate-copilot-cloud/example/repo/493.json"
mkdir -p "$(dirname "$custom_state")"
jq -n --arg head "$integration_head" --argjson finder "$custom_finder" '{version:2,repo:"example/repo",pr:493,head:$head,phase:"reserved",trigger_comment_id:null,
  charged_cycles:1,exempt_cycles:0,attempt:1,run_id:"run-custom-settlement",timeout_min:10,reserved_at:"2026-10-01T00:06:00Z",finder:$finder}' >"$custom_state"
custom_writer integration-review-capture --state "$custom_state" --authority-kind reserve --at 2026-10-01T00:06:30Z >/dev/null
jq '.phase="attached" | .trigger_comment_id="200"' "$custom_state" >"$tmp/custom-attached.json"
custom_writer integration-review-capture --state "$tmp/custom-attached.json" --authority-kind attach --at 2026-10-01T00:22:30Z >/dev/null
node --input-type=module - "$asset_dir/lib/integrator-review-authority.mjs" "$custom_record" "$repo/.git" <<'NODE' >"$custom_state"
import { readFileSync } from 'node:fs'
const { retainedAuthorities } = await import(process.argv[2])
const record = JSON.parse(readFileSync(process.argv[3]))
const state = retainedAuthorities(record, { common: process.argv[4], runId: record.run_id }).at(-1).authority.snapshot
if (state.settled?.length || state.last_reviewed_verdict !== 'findings') process.exit(1)
console.log(JSON.stringify(state))
NODE
custom_initial_exit=0
custom_initial="$(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CUSTOM=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" bash "$fixture_integrate/assets/check-codex-cloud-review.sh" check --state "$custom_state" --run-id run-custom-settlement --repo-dir "$repo" --read-only)" || custom_initial_exit=$?
[ "$custom_initial_exit" -eq 10 ] || fail "custom finder fixture did not report findings: $custom_initial"
jq --arg head "$integration_head" --argjson checked "$custom_initial" '
  .run.run_id="run-custom-settlement" | .payload.verdict="findings" |
  .payload.finder_cycles=[{finder:"copilot-cloud",head:$head,cycle:1,charged:1,exempt:0,attempt:1,trigger_comment_id:"200",exit_code:10,accepted:$checked.accepted}] |
  .payload.findings=[{id:"integration-r1-copilot-cloud-1",source_id:"902",body:("**P2** custom finding\n\n**Reviewed commit:** `" + $head + "`")}] |
  del(.payload.applied_dispositions)
' "$requested_pass" >"$tmp/custom-findings.json"
custom_writer receipt --pass "$tmp/custom-findings.json" >/dev/null
jq -n --arg head "$integration_head" '{schema:2,run_id:"run-custom-settlement",stage:"integration",round:1,reviewed_head:$head,
  adjudications:[{finding_id:"integration-r1-copilot-cloud-1",reviewer_priority:null,adjudicated_priority:"P2",disposition:"decline",reason:"fixture verifies independent adjudication",evidence:"exact live finding body retained",override:null}]}' >"$tmp/custom-adjudication.json"
custom_writer adjudicate --file "$tmp/custom-adjudication.json" >/dev/null
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CUSTOM=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" bash "$fixture_integrate/assets/check-codex-cloud-review.sh" settle \
    --state "$custom_state" --actor-id 175728472 --surface comment --id 902 --disposition declined --note 'fixture adjudication' --repo-dir "$repo") >/dev/null
custom_checked="$(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CUSTOM=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" bash "$fixture_integrate/assets/check-codex-cloud-review.sh" check --state "$custom_state" --run-id run-custom-settlement --repo-dir "$repo" --read-only)"
jq --argjson checked "$custom_checked" '.payload.integration_round=2 | .payload.verdict="clean" |
    .payload.findings=[] | .payload.applied_dispositions=[] |
    .payload.finder_cycles[0].exit_code=0 | .payload.finder_cycles[0].accepted=$checked.accepted' \
    "$tmp/custom-findings.json" >"$tmp/custom-clean.json"
validate_custom_receipt() {
    (cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CUSTOM=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" node "$fixture_support/assets/validate-result-schemas.mjs" integrator "$tmp/custom-clean.json" --receipt --run-id run-custom-settlement --initiated-by human --known-ids "$tmp/requested-reviewer-known-ids.json" --integrator-record "$custom_record")
}
cp "$custom_record" "$tmp/custom-record-original.json"
cp "$custom_state" "$tmp/custom-state-original.json"
for mutation in forged wrong-actor altered-body unreceipted; do
    cp "$tmp/custom-record-original.json" "$custom_record"
    cp "$tmp/custom-state-original.json" "$custom_state"
    case "$mutation" in
    forged) jq '.settled[0].id=999' "$tmp/custom-state-original.json" >"$custom_state" ;;
    wrong-actor) export CAPTURE_CUSTOM_ACTOR=199175422 ;;
    altered-body) export CAPTURE_CUSTOM_SUFFIX=' changed' ;;
    unreceipted) jq '.receipts=[]' "$tmp/custom-record-original.json" >"$custom_record" ;;
    esac
    if validate_custom_receipt >"$tmp/custom-$mutation.out" 2>&1; then
        fail "$mutation custom-finder settlement was admitted"
    fi
    unset CAPTURE_CUSTOM_ACTOR CAPTURE_CUSTOM_SUFFIX
done
cp "$tmp/custom-record-original.json" "$custom_record"
cp "$tmp/custom-state-original.json" "$custom_state"
validate_custom_receipt >/dev/null || fail "genuine current custom-finder settlement was rejected"
custom_writer receipt --pass "$tmp/custom-clean.json" >/dev/null || fail "public writer rejected genuine custom-finder settlement"
pass "custom clean-sentence finder settlement survives immutable attachment; forged, wrong-actor, altered-body and unreceipted candidates refuse"

# #1783: Codex also replays a pre-settlement attach snapshot. Current
# candidates must come from the canonical file, never overwrite its controls.
export CAPTURE_CUSTOM_ACTOR=199175422
new_run run-codex-settlement
write_plan s-codex-settlement 43:run-codex-settlement
acquire s-codex-settlement alice --issues 43
codex_settlement_writer() {
    (cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CUSTOM=1 CAPTURE_CODEX_SETTLEMENT=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-codex-settlement)" node "$capture_writer" "$@" --slate s-codex-settlement --session alice --run-id run-codex-settlement)
}
for transition in 'claim:kicked' 'implement:claimed' 'verify:implemented' 'challenge:verified' 'security:converged' 'integration:secure'; do
    codex_settlement_writer transition --stage "${transition%%:*}" --exit "${transition#*:}" --at 2026-10-01T00:05:00Z >/dev/null
done
codex_settlement_writer bind-pr --number 493 --url https://github.com/example/repo/pull/493 --at 2026-10-01T00:06:00Z >/dev/null
codex_settlement_record="$state/runs/run-codex-settlement/run.json"
resolve_fixture_policy "$state/runs/run-codex-settlement/policy.json" 1
git -C "$repo" branch fixture-run-codex-settlement "$integration_head"
codex_settlement_state="$repo/.git/integrate-codex/example/repo/493.json"
mkdir -p "$(dirname "$codex_settlement_state")"
jq -n --arg head "$integration_head" --argjson finder "$capture_finder" '{version:2,repo:"example/repo",pr:493,head:$head,phase:"reserved",trigger_comment_id:null,
  charged_cycles:1,exempt_cycles:0,attempt:1,run_id:"run-codex-settlement",timeout_min:10,reserved_at:"2026-10-01T00:06:00Z",finder:$finder}' >"$codex_settlement_state"
codex_settlement_writer integration-review-capture --state "$codex_settlement_state" --authority-kind reserve --at 2026-10-01T00:06:30Z >/dev/null
jq '.phase="attached" | .trigger_comment_id="200"' "$codex_settlement_state" >"$tmp/codex_settlement-attached.json"
codex_settlement_writer integration-review-capture --state "$tmp/codex_settlement-attached.json" --authority-kind attach --at 2026-10-01T00:22:30Z >/dev/null
node --input-type=module - "$asset_dir/lib/integrator-review-authority.mjs" "$codex_settlement_record" "$repo/.git" <<'NODE' >"$codex_settlement_state"
import { readFileSync } from 'node:fs'
const { retainedAuthorities } = await import(process.argv[2])
const record = JSON.parse(readFileSync(process.argv[3]))
const state = retainedAuthorities(record, { common: process.argv[4], runId: record.run_id }).at(-1).authority.snapshot
if (state.settled?.length || state.last_reviewed_verdict !== 'findings') process.exit(1)
console.log(JSON.stringify(state))
NODE
cp "$codex_settlement_state" "$tmp/codex-before-settlement.json"
codex_settlement_initial_exit=0
codex_settlement_initial="$(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CUSTOM=1 CAPTURE_CODEX_SETTLEMENT=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" bash "$fixture_integrate/assets/check-codex-cloud-review.sh" check --state "$codex_settlement_state" --run-id run-codex-settlement --repo-dir "$repo" --read-only)" || codex_settlement_initial_exit=$?
[ "$codex_settlement_initial_exit" -eq 10 ] || fail "codex_settlement finder fixture did not report findings: $codex_settlement_initial"
jq --arg head "$integration_head" --argjson checked "$codex_settlement_initial" '
  .run.run_id="run-codex-settlement" | .payload.verdict="findings" |
  .payload.finder_cycles=[{finder:"codex-cloud",head:$head,cycle:1,charged:1,exempt:0,attempt:1,trigger_comment_id:"200",exit_code:10,accepted:$checked.accepted}] |
  .payload.findings=[{id:"integration-r1-codex-cloud-1",source_id:"902",body:("**P2** custom finding\n\n**Reviewed commit:** `" + $head + "`")}] |
  .payload.codex_cycle=(.payload.finder_cycles[0] | del(.finder)) | .payload.finder_cycles=[] |
  del(.payload.applied_dispositions)
' "$requested_pass" >"$tmp/codex_settlement-findings.json"
codex_settlement_writer receipt --pass "$tmp/codex_settlement-findings.json" --codex-state "$codex_settlement_state" --codex-repo-dir "$repo" >/dev/null
jq -n --arg head "$integration_head" '{schema:2,run_id:"run-codex-settlement",stage:"integration",round:1,reviewed_head:$head,
  adjudications:[{finding_id:"integration-r1-codex-cloud-1",reviewer_priority:null,adjudicated_priority:"P2",disposition:"decline",reason:"fixture verifies independent adjudication",evidence:"exact live finding body retained",override:null}]}' >"$tmp/codex_settlement-adjudication.json"
codex_settlement_writer adjudicate --file "$tmp/codex_settlement-adjudication.json" >/dev/null
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CUSTOM=1 CAPTURE_CODEX_SETTLEMENT=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" bash "$fixture_integrate/assets/check-codex-cloud-review.sh" settle \
    --state "$codex_settlement_state" --actor-id 199175422 --surface comment --id 902 --disposition declined --note 'fixture adjudication' --repo-dir "$repo") >/dev/null
codex_settlement_checked="$(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CUSTOM=1 CAPTURE_CODEX_SETTLEMENT=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" bash "$fixture_integrate/assets/check-codex-cloud-review.sh" check --state "$codex_settlement_state" --run-id run-codex-settlement --repo-dir "$repo" --read-only)"
jq --argjson checked "$codex_settlement_checked" '.payload.integration_round=2 | .payload.verdict="clean" |
    .payload.findings=[] | .payload.applied_dispositions=[] |
    .payload.codex_cycle.exit_code=0 | .payload.codex_cycle.accepted=$checked.accepted' \
    "$tmp/codex_settlement-findings.json" >"$tmp/codex_settlement-clean.json"
validate_codex_settlement_receipt() {
    (cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CUSTOM=1 CAPTURE_CODEX_SETTLEMENT=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" node "$fixture_support/assets/validate-result-schemas.mjs" integrator "$tmp/codex_settlement-clean.json" --receipt --run-id run-codex-settlement --initiated-by human --known-ids "$tmp/requested-reviewer-known-ids.json" --integrator-record "$codex_settlement_record" --codex-state "$tmp/codex-before-settlement.json" --codex-repo-dir "$repo")
}
cp "$codex_settlement_record" "$tmp/codex_settlement-record-original.json"
cp "$codex_settlement_state" "$tmp/codex_settlement-state-original.json"
for mutation in forged wrong-actor altered-body unreceipted; do
    cp "$tmp/codex_settlement-record-original.json" "$codex_settlement_record"
    cp "$tmp/codex_settlement-state-original.json" "$codex_settlement_state"
    case "$mutation" in
    forged) jq '.settled[0].id=999' "$tmp/codex_settlement-state-original.json" >"$codex_settlement_state" ;;
    wrong-actor) export CAPTURE_CUSTOM_ACTOR=175728472 ;;
    altered-body) export CAPTURE_CUSTOM_SUFFIX=' changed' ;;
    unreceipted) jq '.receipts=[]' "$tmp/codex_settlement-record-original.json" >"$codex_settlement_record" ;;
    esac
    if validate_codex_settlement_receipt >"$tmp/codex_settlement-$mutation.out" 2>&1; then
        fail "$mutation codex_settlement-finder settlement was admitted"
    fi
    unset CAPTURE_CUSTOM_SUFFIX
    export CAPTURE_CUSTOM_ACTOR=199175422
done
cp "$tmp/codex_settlement-record-original.json" "$codex_settlement_record"
cp "$tmp/codex_settlement-state-original.json" "$codex_settlement_state"
validate_codex_settlement_receipt >/dev/null || fail "genuine current codex_settlement-finder settlement was rejected"
codex_settlement_writer receipt --pass "$tmp/codex_settlement-clean.json" --codex-state "$tmp/codex-before-settlement.json" --codex-repo-dir "$repo" >/dev/null || fail "public writer rejected genuine codex_settlement-finder settlement"
pass "codex_settlement clean-sentence finder settlement survives immutable attachment; forged, wrong-actor, altered-body and unreceipted candidates refuse"

# A later inline finding is first open and then answered on the same cycle.
# Replaying the old attachment must query the live replies, not freeze the
# original findings verdict. No caller-supplied reply data enters authority.
export CAPTURE_INLINE=1
inline_exit=0
inline_checked="$(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CUSTOM=1 CAPTURE_CODEX_SETTLEMENT=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" bash "$fixture_integrate/assets/check-codex-cloud-review.sh" check --state "$codex_settlement_state" --run-id run-codex-settlement --repo-dir "$repo" --read-only)" || inline_exit=$?
[ "$inline_exit" -eq 10 ] || fail "unanswered live inline finding did not block: $inline_checked"
export CAPTURE_INLINE_REPLIED=1
inline_checked="$(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CUSTOM=1 CAPTURE_CODEX_SETTLEMENT=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" bash "$fixture_integrate/assets/check-codex-cloud-review.sh" check --state "$codex_settlement_state" --run-id run-codex-settlement --repo-dir "$repo" --read-only)"
jq --argjson checked "$inline_checked" '.payload.codex_cycle.accepted=$checked.accepted' "$tmp/codex_settlement-clean.json" >"$tmp/codex-inline-clean.json"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CUSTOM=1 CAPTURE_CODEX_SETTLEMENT=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" node "$fixture_support/assets/validate-result-schemas.mjs" integrator "$tmp/codex-inline-clean.json" --receipt --run-id run-codex-settlement --initiated-by human --known-ids "$tmp/requested-reviewer-known-ids.json" --integrator-record "$codex_settlement_record" --codex-state "$tmp/codex-before-settlement.json" --codex-repo-dir "$repo") >/dev/null || fail 'trusted live replies were not replayed at receipt'
unset CAPTURE_INLINE CAPTURE_INLINE_REPLIED CAPTURE_CUSTOM_ACTOR
pass "Codex receipt replays trusted inline replies posted after attachment capture"

# An attachment captured while its parent was uniquely identifiable must replay
# as that same immutable request after a second finder shares its public
# coordinates. The selector is disambiguation only: it may not append another
# attachment or break the selected finder's later retry chain.
new_run run-selector-replay
write_plan s-selector-replay 26:run-selector-replay
acquire s-selector-replay alice --issues 26
selector_a_state="$tmp/selector-a-state.json"
jq -n --arg head "$integration_head" --argjson finder "$capture_finder" '{version:2,repo:"example/repo",pr:493,head:$head,phase:"reserved",trigger_comment_id:null,
  charged_cycles:1,exempt_cycles:0,attempt:1,run_id:"run-selector-replay",timeout_min:10,reserved_at:"2026-10-01T00:06:00Z",finder:$finder}' >"$selector_a_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-selector-replay)" node "$capture_writer" integration-review-capture \
    --slate s-selector-replay --session alice --run-id run-selector-replay --state "$selector_a_state" --authority-kind reserve --at 2026-10-01T00:06:30Z) >/dev/null
selector_a_reserve="$(jq -r '.interventions[] | select(.note | startswith("integration-review-authority v1 reserve sha256=")) | .note' "$state/runs/run-selector-replay/run.json" | tail -1 | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"
jq '.phase="attached" | .trigger_comment_id="200"' "$selector_a_state" >"$selector_a_state.next"
mv "$selector_a_state.next" "$selector_a_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-selector-replay)" node "$capture_writer" integration-review-capture \
    --slate s-selector-replay --session alice --run-id run-selector-replay --state "$selector_a_state" --authority-kind attach --at 2026-10-01T00:07:30Z) >/dev/null
selector_a_attach="$(jq -r '.interventions[] | select(.note | startswith("integration-review-authority v1 attach sha256=")) | .note' "$state/runs/run-selector-replay/run.json" | tail -1 | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"
selector_b_state="$tmp/selector-b-state.json"
jq -n --arg head "$integration_head" --argjson finder "$requested_finder" '{version:2,repo:"example/repo",pr:493,head:$head,phase:"reserved",trigger_comment_id:null,
  charged_cycles:1,exempt_cycles:0,attempt:1,run_id:"run-selector-replay",timeout_min:10,reserved_at:"2026-10-01T00:06:00Z",finder:$finder}' >"$selector_b_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_NOW=2026-10-01T00:07:30Z CAPTURE_EPOCH=1790813250 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-selector-replay)" node "$capture_writer" integration-review-capture \
    --slate s-selector-replay --session alice --run-id run-selector-replay --state "$selector_b_state" --authority-kind reserve --at 2026-10-01T00:06:30Z) >/dev/null
selector_b_reserve="$(jq -r '.interventions[] | select(.note | startswith("integration-review-authority v1 reserve sha256=")) | .note' "$state/runs/run-selector-replay/run.json" | tail -1 | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_REQUESTED_REVIEWER=1 CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-selector-replay)" node "$capture_writer" integration-review-capture \
    --slate s-selector-replay --session alice --run-id run-selector-replay --state "$selector_b_state" --authority-kind attach --parent-authority-digest "$selector_b_reserve" --at 2026-10-01T00:07:30Z) >/dev/null
selector_before_replay="$(jq '[.interventions[] | select(.note | startswith("integration-review-authority v1 "))] | length' "$state/runs/run-selector-replay/run.json")"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-selector-replay)" node "$capture_writer" integration-review-capture \
    --slate s-selector-replay --session alice --run-id run-selector-replay --state "$selector_a_state" --authority-kind attach --parent-authority-digest "$selector_a_reserve" --at 2026-10-01T00:08:00Z) >/dev/null
selector_after_replay="$(jq '[.interventions[] | select(.note | startswith("integration-review-authority v1 "))] | length' "$state/runs/run-selector-replay/run.json")"
[ "$selector_before_replay" -eq 4 ] && [ "$selector_after_replay" -eq "$selector_before_replay" ] ||
    fail "selector-added attachment replay changed immutable authority count"
expect_refused "selector-added attachment replay rejects the other finder parent" "attached trigger" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_CLEAN=1 CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" integration-review-capture --slate s-selector-replay --session alice --run-id run-selector-replay --state "$7" --authority-kind attach --parent-authority-digest "$8" --at 2026-10-01T00:08:00Z' _ \
    "$repo" "$capture_bin:$PATH" "$integration_head" "$capture_base" "$(token_for s-selector-replay)" "$capture_writer" "$selector_a_state" "$selector_b_reserve"
selector_retry_state="$tmp/selector-a-retry-state.json"
jq '.phase="reserved" | .attempt=2 | .first_trigger_comment_id="200" | .requires_full_window=true | .reserved_at="2000-01-01T00:00:00Z"' "$selector_a_state" >"$selector_retry_state"
selector_retry_epoch="$(node -e 'process.stdout.write(String(Date.parse("2026-10-01T00:20:00Z") / 1000))')"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_NOW=2026-10-01T00:20:00Z CAPTURE_EPOCH="$selector_retry_epoch" CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-selector-replay)" node "$capture_writer" integration-review-capture \
    --slate s-selector-replay --session alice --run-id run-selector-replay --state "$selector_retry_state" --authority-kind reserve --parent-authority-digest "$selector_a_attach" --at 2026-10-01T00:20:30Z) >/dev/null
selector_retry_reserve="$(jq -r '.interventions[] | select(.note | startswith("integration-review-authority v1 reserve sha256=")) | .note' "$state/runs/run-selector-replay/run.json" | tail -1 | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"
jq '.phase="attached" | .trigger_comment_id="201"' "$selector_retry_state" >"$selector_retry_state.next"
mv "$selector_retry_state.next" "$selector_retry_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-selector-replay)" node "$capture_writer" integration-review-capture \
    --slate s-selector-replay --session alice --run-id run-selector-replay --state "$selector_retry_state" --authority-kind attach --parent-authority-digest "$selector_retry_reserve" --at 2026-10-01T00:21:30Z) >/dev/null
AUTH_COMMON="$repo/.git" AUTH_RUN=run-selector-replay AUTH_RECORD="$state/runs/run-selector-replay/run.json" node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const { retainedAuthorities } = await import(process.argv[1]);
  const record = JSON.parse(readFileSync(process.env.AUTH_RECORD));
  const retained = retainedAuthorities(record, { common: process.env.AUTH_COMMON, runId: process.env.AUTH_RUN });
  const a = retained.filter((entry) => entry.authority.snapshot.finder?.slug === "codex-cloud");
  if (a.length !== 4 || a.at(-1)?.kind !== "attach" || a.at(-1)?.authority.snapshot.attempt !== 2) process.exit(1);
' "$asset_dir/lib/integrator-review-authority.mjs" || fail "selector-added replay broke the original finder's retry chain"
pass "selector-added public replay preserves its immutable attachment and later retry while refusing the other parent"

# A historical cycle-one origin is only retry context while it remains that
# finder's frontier. Once a cycle-two request is retained, neither an implicit
# lookup nor an explicit immutable selector may revive cycle one.
selector_cycle2_state="$tmp/selector-a-cycle2-state.json"
jq '.phase="reserved" | .charged_cycles=2 | .attempt=1 | .trigger_comment_id=null | .first_trigger_comment_id=null | .requested_at=null | .reserved_at="2026-10-01T00:06:00Z"' "$selector_a_state" >"$selector_cycle2_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-selector-replay)" node "$capture_writer" integration-review-capture \
    --slate s-selector-replay --session alice --run-id run-selector-replay --state "$selector_cycle2_state" --authority-kind reserve --at 2026-10-01T00:23:30Z) >/dev/null
jq '.phase="attached" | .trigger_comment_id="202"' "$selector_cycle2_state" >"$selector_cycle2_state.next"
mv "$selector_cycle2_state.next" "$selector_cycle2_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-selector-replay)" node "$capture_writer" integration-review-capture \
    --slate s-selector-replay --session alice --run-id run-selector-replay --state "$selector_cycle2_state" --authority-kind attach --at 2026-10-01T00:24:30Z) >/dev/null
selector_stale_retry_state="$tmp/selector-a-stale-retry-state.json"
jq '.phase="reserved" | .trigger_comment_id=null | .requested_at=null | .reserved_at="2026-10-01T00:25:00Z"' "$selector_retry_state" >"$selector_stale_retry_state"
cp "$state/runs/run-selector-replay/run.json" "$tmp/selector-stale-before.json"
expect_refused "public capture rejects an unselected stale cycle-one retry after cycle two" "ambiguous across retained finder authorities" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" integration-review-capture --slate s-selector-replay --session alice --run-id run-selector-replay --state "$7" --authority-kind reserve --at 2026-10-01T00:25:30Z' _ \
    "$repo" "$capture_bin:$PATH" "$integration_head" "$capture_base" "$(token_for s-selector-replay)" "$capture_writer" "$selector_stale_retry_state"
cmp -s "$state/runs/run-selector-replay/run.json" "$tmp/selector-stale-before.json" ||
    fail "unselected stale retry changed retained finder authorities"
expect_refused "public capture rejects a selected stale cycle-one retry after cycle two" "current cycle frontier" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" integration-review-capture --slate s-selector-replay --session alice --run-id run-selector-replay --state "$7" --authority-kind reserve --parent-authority-digest "$8" --at 2026-10-01T00:25:30Z' _ \
    "$repo" "$capture_bin:$PATH" "$integration_head" "$capture_base" "$(token_for s-selector-replay)" "$capture_writer" "$selector_stale_retry_state" "$selector_a_attach"
cmp -s "$state/runs/run-selector-replay/run.json" "$tmp/selector-stale-before.json" ||
    fail "selected stale retry changed retained finder authorities"
pass "public capture refuses stale retries with and without an origin selector while same-cycle retries remain admitted"

jq '.attempt = 2 | .first_trigger_comment_id = null | .reserved_at = "2000-01-01T00:00:00Z"' "$requested_state" >"$requested_state.retry"
mv "$requested_state.retry" "$requested_state"
expect_refused "requested-reviewer retry refuses a short owner window" "attempt 1 window has not elapsed" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_NOW=2026-10-01T00:07:30Z CAPTURE_EPOCH=1790813250 CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" integration-review-capture --slate s-requested-reviewer --session alice --run-id run-requested-reviewer --state "$7" --authority-kind reserve --parent-authority-digest "$8" --at 2026-10-01T00:07:40Z' _ \
    "$repo" "$capture_bin:$PATH" "$integration_head" "$capture_base" "$(token_for s-requested-reviewer)" "$capture_writer" "$requested_state" "$requested_parent_digest"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_NOW=2026-10-01T00:20:00Z CAPTURE_EPOCH="$(node -e 'process.stdout.write(String(Date.parse("2026-10-01T00:20:00Z") / 1000))')" CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-requested-reviewer)" node "$capture_writer" integration-review-capture \
    --slate s-requested-reviewer --session alice --run-id run-requested-reviewer --state "$requested_state" --authority-kind reserve --parent-authority-digest "$requested_parent_digest" --at 2026-10-01T00:20:30Z) >/dev/null
requested_retry_digest="$(jq -r '.interventions[] | select(.note | startswith("integration-review-authority v1 reserve sha256=")) | .note' "$state/runs/run-requested-reviewer/run.json" | tail -1 | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_REQUESTED_REVIEWER=retry-valid CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-requested-reviewer)" node "$capture_writer" integration-review-capture \
    --slate s-requested-reviewer --session alice --run-id run-requested-reviewer --state "$requested_state" --authority-kind attach --parent-authority-digest "$requested_retry_digest" --at 2026-10-01T00:22:30Z) >/dev/null
AUTH_COMMON="$repo/.git" AUTH_RUN=run-requested-reviewer AUTH_RECORD="$state/runs/run-requested-reviewer/run.json" node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const { retainedAuthorities } = await import(process.argv[1]);
  const record = JSON.parse(readFileSync(process.env.AUTH_RECORD));
  const retry = retainedAuthorities(record, { common: process.env.AUTH_COMMON, runId: process.env.AUTH_RUN })
    .find((entry) => entry.kind === "attach" && entry.authority.snapshot.attempt === 2)?.authority.snapshot;
  if (!retry || retry.first_requested_at !== "2026-10-01T00:07:00Z" || retry.requested_at !== "2026-10-01T00:21:00Z") process.exit(1);
' "$asset_dir/lib/integrator-review-authority.mjs" || fail "requested-reviewer retry did not preserve the immutable first request"
pass "requested-reviewer owner capture binds the retained reviewer actor and authenticated timeline request"

retry_parent_digest="$(jq -r '.interventions[] | select(.note | startswith("integration-review-authority v1 attach sha256=")) | .note' "$state/runs/run-integrator/run.json" | tail -1 | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"

# Exit 12 is diagnostic-only: it cannot be receipted (asserted above), and the
# owner creates the bounded attempt-2 reservation and attachment before a
# fresh integrator can report its terminal result.  This is the actual public
# capture path, including the retained first request and full-window check.
retry_state="$tmp/capture-retry-state.json"
jq -n --arg head "$integration_head" '{version:2,repo:"example/repo",pr:493,head:$head,phase:"reserved",trigger_comment_id:null,
  charged_cycles:1,exempt_cycles:0,attempt:2,run_id:"run-integrator",first_trigger_comment_id:200,
  requires_full_window:true,timeout_min:10,reserved_at:"2000-01-01T00:00:00Z"}' >"$retry_state"
retry_epoch="$(node -e 'process.stdout.write(String(Date.parse("2026-10-01T00:20:00Z") / 1000))')"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_NOW=2026-10-01T00:20:00Z CAPTURE_EPOCH="$retry_epoch" CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$capture_writer" integration-review-capture \
    --slate s-integrator --session alice --run-id run-integrator --state "$retry_state" --authority-kind reserve --parent-authority-digest "$retry_parent_digest" --at 2026-10-01T00:20:30Z) >/dev/null
retry_reserve_digest="$(jq -r '.interventions[] | select(.note | startswith("integration-review-authority v1 reserve sha256=")) | .note' "$state/runs/run-integrator/run.json" | tail -1 | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"
jq '.phase="attached" | .trigger_comment_id="201"' "$retry_state" >"$retry_state.next"
mv "$retry_state.next" "$retry_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$capture_writer" integration-review-capture \
    --slate s-integrator --session alice --run-id run-integrator --state "$retry_state" --authority-kind attach --parent-authority-digest "$retry_reserve_digest" --at 2026-10-01T00:21:30Z) >/dev/null
AUTH_COMMON="$repo/.git" AUTH_RUN=run-integrator AUTH_RECORD="$state/runs/run-integrator/run.json" node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const { retainedAuthorities } = await import(process.argv[1]);
  const record = JSON.parse(readFileSync(process.env.AUTH_RECORD));
  const retry = retainedAuthorities(record, { common: process.env.AUTH_COMMON, runId: process.env.AUTH_RUN })
    .find((entry) => entry.kind === "attach" && entry.authority.snapshot.attempt === 2)?.authority.snapshot;
  if (!retry || retry.trigger_comment_id !== 201 || retry.first_trigger_comment_id !== 200 ||
      retry.reserved_at !== "2026-10-01T00:20:00Z" || retry.finder?.slug !== "codex-cloud" ||
      retry.last_reviewed_head !== retry.head || retry.last_reviewed_verdict !== "clean" ||
      !/^[0-9a-f]{40}$/.test(retry.last_reviewed_base_sha ?? "")) process.exit(1);
' "$asset_dir/lib/integrator-review-authority.mjs" || fail "owner retry capture did not retain canonical attempt-2 controls"
pass "diagnostic retry evidence cannot be receipted before owner-captured attempt 2"
# The second integration round has an attached, trusted request.  A required CI failure
# after that request cannot use the null-cycle exception: both strict
# validation and the public writer must refuse it before any round-two receipt
# slot is consumed.  The later terminal clean receipt proves this refusal does
# not poison the real next admission.
rri bind-pr --run-id run-integrator --number 493 --url https://github.com/example/repo/pull/493 --at 2026-10-01T00:22:00Z >/dev/null
resolve_fixture_policy "$state/runs/run-integrator/policy.json" 1 after-ci
attached_after_ci_failure="$tmp/integration-r2-after-ci-failure-with-authority.json"
jq --arg head "$integration_head" '
  .head = $head | .payload.integration_round = 2 | .payload.codex_cycle = null |
  .payload.checks[0].bucket = "fail" | .payload.verdict = "findings" |
  .payload.findings = [{id:"integration-r2-human-1",body:"required build failed after review request",source_id:"1004"}] |
  del(.payload.applied_dispositions)
' "$integration_pass" >"$attached_after_ci_failure"
printf '[]\n' >"$tmp/integration-known-ids.json"
expect_refused "strict validator rejects a null after-ci receipt after an attached trusted request" "required-Codex failures remain blocked diagnostics, not completed receipts" \
    bash -c 'cd "$1" && PATH="$2" node "$3" integrator "$4" --receipt --run-id run-integrator --initiated-by human --known-ids "$5" --integrator-record "$6"' _ \
    "$repo" "$capture_bin:$PATH" "$fixture_support/assets/validate-result-schemas.mjs" "$attached_after_ci_failure" "$tmp/integration-known-ids.json" "$state/runs/run-integrator/run.json"
expect_refused "public writer rejects a null after-ci receipt after an attached trusted request" "required-Codex failures remain blocked diagnostics, not completed receipts" \
    rri receipt --run-id run-integrator --pass "$attached_after_ci_failure"
[ ! -e "$state/runs/run-integrator/passes/integration-r2-integrator.json" ] ||
    fail "a null receipt after an attached request consumed the round-two receipt slot"
# Admit the actual clean attempt-2 result through the public writer before a
# base catch-up asks carry to use it. The receipt is authenticated against the
# same real checker state and fixture surfaces as the owner capture above.
carry_pass="$tmp/integration-r2-carry.json"
jq --arg head "$integration_head" '
  .head = $head | .payload.integration_round = 2 |
  .payload.codex_cycle = {head:$head,cycle:1,attempt:2,trigger_comment_id:"201",exit_code:0,
    accepted:{surface:"reaction",id:"901",reviewed_commit:$head}}
' "$integration_pass" >"$carry_pass"
carry_auth_state="$tmp/carry-auth-state.json"
carry_attach_digest="$(jq -r '.interventions[] | select(.note | startswith("integration-review-authority v1 attach sha256=")) | .note' "$state/runs/run-integrator/run.json" | tail -1 | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"
cp "$state/runs/run-integrator/rulings/$carry_attach_digest" "$carry_auth_state"
jq '.snapshot | .run_id = "run-integrator"' "$carry_auth_state" >"${carry_auth_state}.next" && mv "${carry_auth_state}.next" "$carry_auth_state"
# The strict validator and the public writer each consume the complete
# recorded policy before either null/non-null branch can waive its contents.
# Keep the receipt otherwise live and valid; these are policy-boundary tests,
# not schema-only malformed-envelope tests.
integration_policy="$state/runs/run-integrator/policy.json"
cp "$integration_policy" "$tmp/integration-policy-valid.json"
printf '{}\n' >"$integration_policy"
printf '[]\n' >"$tmp/integration-known-ids.json"
expect_refused "strict validator rejects a malformed policy for a non-null current receipt" "recorded resolved policy is incomplete or invalid" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_CLEAN=1 CAPTURE_HEAD="$3" CAPTURE_BASE="$4" node "$5" envelope "$6" --run-id run-integrator --initiated-by human --known-ids "$7" --receipt --integrator-record "$8" --codex-state "$9" --codex-repo-dir "$1"' _ \
    "$repo" "$capture_bin:$PATH" "$integration_head" "$capture_base" "$fixture_support/assets/validate-result-schemas.mjs" "$carry_pass" "$tmp/integration-known-ids.json" "$state/runs/run-integrator/run.json" "$carry_auth_state"
jq 'del(.tier_order, .roles.integrator)' "$tmp/integration-policy-valid.json" >"$integration_policy"
expect_refused "public writer rejects missing resolved tier inputs before non-null receipt admission" "resolved policy is incomplete or invalid" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_CLEAN=1 CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" receipt --slate s-integrator --session alice --run-id run-integrator --pass "$7" --codex-state "$8" --codex-repo-dir "$1"' _ \
    "$repo" "$capture_bin:$PATH" "$integration_head" "$capture_base" "$(token_for s-integrator)" "$capture_writer" "$carry_pass" "$carry_auth_state"
cp "$tmp/integration-policy-valid.json" "$integration_policy"
pass "malformed policies and missing integrator tiers refuse at strict and public non-null receipt boundaries"
# This invokes the public strict validator directly, not the authority helper.
# The retained owner history ended attempt 2, so an otherwise valid clean
# receipt naming attempt 1 cannot select its stale trigger and be admitted.
stale_attempt_pass="$tmp/integration-r2-stale-attempt-one.json"
jq --arg head "$integration_head" '
  .head = $head | .payload.integration_round = 2 |
  .payload.codex_cycle = {head:$head,cycle:1,attempt:1,trigger_comment_id:"200",exit_code:0,
    accepted:{surface:"reaction",id:"901",reviewed_commit:$head}}
' "$integration_pass" >"$stale_attempt_pass"
expect_refused "strict validator rejects a stale attempt-one clean receipt after retained attempt two" "current retained owner authority" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_CLEAN=1 CAPTURE_HEAD="$3" CAPTURE_BASE="$4" node "$5" envelope "$6" --run-id run-integrator --initiated-by human --known-ids "$7" --receipt --integrator-record "$8" --codex-state "$9" --codex-repo-dir "$1"' _ \
    "$repo" "$capture_bin:$PATH" "$integration_head" "$capture_base" "$fixture_support/assets/validate-result-schemas.mjs" "$stale_attempt_pass" "$tmp/integration-known-ids.json" "$state/runs/run-integrator/run.json" "$carry_auth_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$capture_writer" receipt \
    --slate s-integrator --session alice --run-id run-integrator --pass "$carry_pass" \
    --codex-state "$carry_auth_state" --codex-repo-dir "$repo") >/dev/null
# A receipt for retry attempt 2 settles both retained reservations of that
# cycle, including the pending first attempt. No checker re-poll is needed.
cp "$state/runs/run-integrator/run.json" "$tmp/rem-retry-receipted-record.json"
cp "$carry_auth_state" "$state/runs/run-integrator/codex-cloud-review.json"
# The prior settlement fixture shares this PR's canonical path. Isolate the
# retry fixture from that foreign run, then restore its state for later cases.
cp "$codex_settlement_state" "$tmp/rem-retry-foreign-state.json"
cp "$carry_auth_state" "$codex_settlement_state"
(cd "$repo" && PATH="$capture_bin:$PATH" REMEDIATION_CHECKER_CALL_LOG="$tmp/rem-retry-checks.log" \
    NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }--require=$rem_no_check_hook" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" \
    node "$capture_writer" transition --slate s-integrator --session alice --run-id run-integrator \
    --stage implement --exit remediating --at 2026-10-01T00:40:00Z) >/dev/null
[ ! -e "$tmp/rem-retry-checks.log" ] || fail "receipted retry was re-polled"
cp "$tmp/rem-retry-receipted-record.json" "$state/runs/run-integrator/run.json"
rm "$state/runs/run-integrator/codex-cloud-review.json"
mv "$tmp/rem-retry-foreign-state.json" "$codex_settlement_state"
pass "attempt-two receipt settles the cycle's first and retry reservations without polling"
# The same independently observed clean cycle can be retained by a later
# integration round once the first round is adjudicated. These are
# corroborating receipts for one immutable owner attachment, not ambiguity.
jq -n --arg head "$integration_head" '{schema:2,run_id:"run-integrator",stage:"integration",round:2,reviewed_head:$head,adjudications:[]}' >"$tmp/integration-r2-adjudication.json"
rri adjudicate --run-id run-integrator --file "$tmp/integration-r2-adjudication.json" >/dev/null
carry_corroborating_pass="$tmp/integration-r3-corroborating-clean.json"
jq '.payload.integration_round = 3' "$carry_pass" >"$carry_corroborating_pass"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$capture_writer" receipt \
    --slate s-integrator --session alice --run-id run-integrator --pass "$carry_corroborating_pass" \
    --codex-state "$carry_auth_state" --codex-repo-dir "$repo") >/dev/null
jq -n --arg head "$integration_head" '{schema:2,run_id:"run-integrator",stage:"integration",round:3,reviewed_head:$head,adjudications:[]}' >"$tmp/integration-r3-adjudication.json"
rri adjudicate --run-id run-integrator --file "$tmp/integration-r3-adjudication.json" >/dev/null
receipted_clean_count="$(jq '[.receipts[] | select(.file == "integration-r2-integrator" or .file == "integration-r3-integrator")] | length' "$state/runs/run-integrator/run.json")"
[ "$receipted_clean_count" -eq 2 ] || fail "two independent clean receipts were not admitted before carry"
pass "two independently admitted clean receipts corroborate one carry origin"

# Exercise the same integration-history computation readiness-gate.sh uses.
# The released reserve is retained evidence, but adds no spent review cycle.
node --input-type=module -e '
  const [record, validator, engine] = process.argv.slice(1);
  const { integrationExitForRunDir } = await import(engine);
  const result = await integrationExitForRunDir(record, { integrationCap: 1, validatorPath: validator });
  if (result.reason !== "last_cycle_clean" || result.action !== "settle" ||
      result.cycles.length !== 1 || result.cycles[0].cycle !== 1) process.exit(1);
' "$state/runs/run-integrator" "$asset_dir/validate-result-schemas.mjs" "$asset_dir/dev-flow-exit.mjs" ||
    fail "readiness rejected the receipted replacement reservation or counted its released predecessor"
pass "readiness accepts the refunded cycle after re-reservation, attachment and receipt"

# The checked branch has one reviewed feature edit. Advancing main without a
# tree change and merging it into the branch preserves that nonempty canonical
# three-dot identity at both heads.
git -C "$repo" checkout -q main
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "base catch-up fixture"
carry_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q "$integration_branch"
carry_merge="$(git -C "$repo" commit-tree "$(git -C "$repo" rev-parse "$integration_head^{tree}")" \
    -p "$integration_head" -p "$carry_base" -m "base catch-up fixture")"
git -C "$repo" update-ref "refs/heads/$integration_branch" "$carry_merge"
git -C "$repo" checkout -q "$integration_branch"
carry_head="$(git -C "$repo" rev-parse HEAD)"
# Carry starts from the retained canonical attempt-2 attachment, not the
# mutable retry report. Poison every source-only control, including finder:
# the retained attachment supplies the exact finder profile, terminal/base
# markers, and request tuple the real carry selector re-proves.
cp "$carry_auth_state" "$tmp/carry-original.json"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$carry_head" CAPTURE_BASE="$carry_base" \
    CAPTURE_NOW=2026-10-01T00:22:20Z bash "$fixture_integrate/assets/check-codex-cloud-review.sh" carry \
    --state "$tmp/carry-original.json" --head "$carry_head" --run-id run-integrator --repo-dir "$repo") >/dev/null
# #1780: start with the real clean/carry above, leave it uncaptured in an
# isolated run-record view, release an unused reservation, then receipt the
# actual replacement cycle. Counters alone must not stand in for cycle 1.
cp "$state/runs/run-integrator/run.json" "$tmp/sequence-record-before.json"
mv "$state/runs/run-integrator/adjudications" "$tmp/sequence-adjudications"
mkdir "$state/runs/run-integrator/adjudications"
jq '.receipts=[] | .interventions=[]' "$tmp/sequence-record-before.json" >"$state/runs/run-integrator/run.json"
(
    cd "$repo"
    export PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$carry_head" CAPTURE_BASE="$carry_base"
    sequence_state="$tmp/sequence-live.json"
    cp "$tmp/carry-original.json" "$sequence_state"
    checker="$fixture_integrate/assets/check-codex-cloud-review.sh"
    CAPTURE_NOW=2026-10-01T00:23:00Z bash "$checker" reserve --state "$sequence_state" \
        --repo example/repo --pr 493 --head "$carry_head" --attempt 1 \
        --run-id run-integrator --timeout-min 15 --integration-cap 6 --integration-exempt-cap 6 >/dev/null
    bash "$checker" release --state "$sequence_state" --note 'unused catch-up reservation' \
        --now 2026-10-01T00:33:00Z >/dev/null
    jq -e '.charged_cycles == 1 and .exempt_cycles == 0' "$sequence_state" >/dev/null || fail '#1780 refund left phantom spend'
    CAPTURE_NOW=2026-10-01T00:34:00Z bash "$checker" reserve --state "$sequence_state" \
        --repo example/repo --pr 493 --head "$carry_head" --attempt 1 \
        --run-id run-integrator --timeout-min 15 --integration-cap 6 --integration-exempt-cap 6 >/dev/null
    export CAPTURE_TRIGGER_AT=2026-10-01T00:35:00Z CAPTURE_REACTION_AT=2026-10-01T00:35:30Z
    bash "$checker" attach --state "$sequence_state" --trigger-id 202 >/dev/null
    sequence_observation="$(bash "$checker" check --state "$sequence_state" --actor-id 199175422 --run-id run-integrator \
        --repo-dir "$repo" --now 2026-10-01T00:36:00Z)"
    jq -e '.status == "clean"' <<<"$sequence_observation" >/dev/null || fail '#1780 replacement cycle was not clean'
    jq -e '.charged_cycles == 2 and .exempt_cycles == 0' "$sequence_state" >/dev/null || fail '#1780 replacement is not cycle 2'
    jq --arg head "$carry_head" --argjson observation "$sequence_observation" --slurpfile live "$sequence_state" '
      .head=$head | .payload.integration_round=1 |
      .payload.codex_cycle={head:$head,cycle:($live[0].charged_cycles+$live[0].exempt_cycles),
        charged:$live[0].charged_cycles,exempt:$live[0].exempt_cycles,attempt:$live[0].attempt,
        trigger_comment_id:($live[0].trigger_comment_id|tostring),exit_code:0,accepted:$observation.accepted}
    ' "$integration_pass" >"$tmp/sequence-cycle-two.json"
    expect_refused '#1780 real cycle-2 receipt cannot skip the uncaptured origin' \
        'integration-history-incomplete: cycle 2 follows receipted cycle 0; capture and receipt each terminal integrator pass before moving its head. Restore original authenticated evidence through the owner recovery procedure; never fabricate a historical pass or renumber counters.' \
        rri receipt --run-id run-integrator --pass "$tmp/sequence-cycle-two.json" \
        --codex-state "$sequence_state" --codex-repo-dir "$repo"
    [ "$(jq '.receipts | length' "$state/runs/run-integrator/run.json")" = 0 ] || fail '#1780 refused receipt changed history'
)
cp "$tmp/sequence-record-before.json" "$state/runs/run-integrator/run.json"
rmdir "$state/runs/run-integrator/adjudications"
mv "$tmp/sequence-adjudications" "$state/runs/run-integrator/adjudications"
pass '#1780 real clean/carry/release/cycle-2 sequence refuses receipt with the owner recovery remedy'

jq '.finder={slug:"foreign"} | .run_id="foreign-run" |
  .reserved_at="1999-01-01T00:00:00Z" | .timeout_min=1' "$tmp/carry-original.json" >"$tmp/carry-state.json"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$carry_head" CAPTURE_BASE="$carry_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$capture_writer" integration-review-capture \
    --slate s-integrator --session alice --run-id run-integrator --state "$tmp/carry-state.json" --authority-kind carry --parent-authority-digest "$carry_attach_digest" --repo-dir "$repo" --at 2026-10-01T00:22:30Z) >/dev/null
carry_digest="$(jq -r '.interventions[] | select(.note | startswith("integration-review-authority v1 carry sha256=")) | .note' "$state/runs/run-integrator/run.json" | tail -1 | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"
jq '.snapshot' "$state/runs/run-integrator/rulings/$carry_digest" >"$tmp/carry-live-state.json"
jq -e --slurpfile original "$tmp/carry-original.json" '.carry == $original[0].carry' "$tmp/carry-live-state.json" >/dev/null ||
    fail 'carry capture changed the original canonical carry timestamp/object (#1783)'

expect_refused "carry replay refuses its child as a parent selector" "retained carry predecessor selector does not name a compatible retained authority" \
    bash -c 'cd "$1" && PATH="$2:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" integration-review-capture --slate s-integrator --session alice --run-id run-integrator --state "$7" --authority-kind carry --parent-authority-digest "$8" --repo-dir "$1" --at 2026-10-01T00:23:00Z' \
    _ "$repo" "$capture_bin" "$carry_head" "$carry_base" "$(token_for s-integrator)" "$capture_writer" "$tmp/carry-live-state.json" "$carry_digest"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$carry_head" CAPTURE_BASE="$carry_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$capture_writer" integration-review-capture \
    --slate s-integrator --session alice --run-id run-integrator --state "$tmp/carry-live-state.json" --authority-kind carry --parent-authority-digest "$carry_attach_digest" --repo-dir "$repo" --at 2026-10-01T00:23:00Z) >/dev/null
AUTH_COMMON="$repo/.git" AUTH_RUN=run-integrator AUTH_RECORD="$state/runs/run-integrator/run.json" node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const { retainedAuthorities } = await import(process.argv[1]);
  const record = JSON.parse(readFileSync(process.env.AUTH_RECORD));
  const carries = retainedAuthorities(record, { common: process.env.AUTH_COMMON, runId: process.env.AUTH_RUN })
    .filter((entry) => entry.kind === "carry");
  if (carries.length !== 1 || carries[0].authority.snapshot.carry?.attests_head !== process.argv[2] ||
      carries[0].authority.snapshot.finder?.slug !== "codex-cloud" ||
      typeof carries[0].authority.snapshot.carry?.carried_at !== "string") process.exit(1);
' "$asset_dir/lib/integrator-review-authority.mjs" "$carry_head" || fail "public writer did not retain one replay-stable ordinary carry"
pass "authenticated clean receipt carries across a real base catch-up and replays without a second immutable carry"
# A changed PR diff cannot inherit this carry. A later finding is a fresh live
# observation: replay re-proves the retained immutable carry but cannot rewrite
# that capture to make the old clean result current.
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_FINDING=1 CAPTURE_ORIGIN_HEAD="$integration_head" CAPTURE_HEAD="$carry_head" CAPTURE_BASE="$carry_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$capture_writer" integration-review-capture \
    --slate s-integrator --session alice --run-id run-integrator --state "$tmp/carry-live-state.json" --authority-kind carry --repo-dir "$repo" --at 2026-10-01T00:25:00Z) >/dev/null
AUTH_COMMON="$repo/.git" AUTH_RUN=run-integrator AUTH_RECORD="$state/runs/run-integrator/run.json" node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const { retainedAuthorities } = await import(process.argv[1]);
  const record = JSON.parse(readFileSync(process.env.AUTH_RECORD));
  const carries = retainedAuthorities(record, { common: process.env.AUTH_COMMON, runId: process.env.AUTH_RUN })
    .filter((entry) => entry.kind === "carry");
  if (carries.length !== 1 || carries[0].authority.snapshot.last_reviewed_verdict !== "clean") process.exit(1);
' "$asset_dir/lib/integrator-review-authority.mjs" || fail "late finding rewrote immutable carried origin evidence"
late_rc=0
late_observation="$(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_FINDING=1 CAPTURE_ORIGIN_HEAD="$integration_head" CAPTURE_HEAD="$carry_head" CAPTURE_BASE="$carry_base" bash "$fixture_integrate/assets/check-codex-cloud-review.sh" check --state "$tmp/carry-live-state.json" --actor-id 199175422 --repo-dir "$repo" --read-only)" || late_rc=$?
[ "$late_rc" -eq 10 ] || fail "late Codex finding did not remain a live canonical observation: $late_observation"
late_clean_pass="$tmp/integration-r3-late-clean.json"
jq --arg head "$carry_head" --argjson observation "$late_observation" --slurpfile live "$tmp/carry-live-state.json" '
  .head = $head | .payload.integration_round = 4 | .payload.verdict = "clean" | .payload.findings = [] |
  .payload.codex_cycle = {
    head:$head, cycle:(($live[0].charged_cycles // 0) + ($live[0].exempt_cycles // 0)),
    attempt:$live[0].attempt, trigger_comment_id:($live[0].trigger_comment_id|tostring), exit_code:0,
    accepted:$observation.accepted,
    carried:($live[0].carry + {origin_head:$live[0].head})
  }' "$integration_pass" >"$late_clean_pass"
expect_refused "late finding rejects a claimed clean carried receipt" "does not match the live checker process exit" bash -c 'cd "$1" && PATH="$2" CAPTURE_FINDING=1 CAPTURE_ORIGIN_HEAD="$3" CAPTURE_HEAD="$4" CAPTURE_BASE="$5" RUN_RECORD_OWNER_TOKEN="$6" node "$7" receipt --slate s-integrator --session alice --run-id run-integrator --pass "$8" --codex-state "$9" --codex-repo-dir "$1"' _ "$repo" "$capture_bin:$PATH" "$integration_head" "$carry_head" "$carry_base" "$(token_for s-integrator)" "$capture_writer" "$late_clean_pass" "$tmp/carry-live-state.json"
late_findings_pass="$tmp/integration-r3-late-findings.json"
jq --arg head "$carry_head" --argjson observation "$late_observation" --slurpfile live "$tmp/carry-live-state.json" '
  .head = $head | .payload.integration_round = 4 | .payload.verdict = "findings" |
  .payload.findings = [{id:"integration-r4-codex-cloud-1",body:"**P1** late finding",source_id:"902"}] |
  .payload.codex_cycle = {
    head:$head, cycle:(($live[0].charged_cycles // 0) + ($live[0].exempt_cycles // 0)),
    attempt:$live[0].attempt, trigger_comment_id:($live[0].trigger_comment_id|tostring), exit_code:10,
    accepted:$observation.accepted,
    carried:($live[0].carry + {origin_head:$live[0].head})
  }' "$integration_pass" >"$late_findings_pass"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_FINDING=1 CAPTURE_ORIGIN_HEAD="$integration_head" CAPTURE_HEAD="$carry_head" CAPTURE_BASE="$carry_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$capture_writer" receipt --slate s-integrator --session alice --run-id run-integrator --pass "$late_findings_pass" --codex-state "$tmp/carry-live-state.json" --codex-repo-dir "$repo") >/dev/null
pass "late findings reject a claimed clean carry receipt and admit the truthful findings receipt"
# Advance the base a second time without changing the reviewed tree and retain
# the legitimate B->C carry. From here, only C is the live immutable frontier:
# a replay of A->B or a new A->C claim must not select history by its source.
git -C "$repo" checkout -q main
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "second base catch-up fixture"
carry_second_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q "$integration_branch"
carry_second_merge="$(git -C "$repo" commit-tree "$(git -C "$repo" rev-parse "$carry_head^{tree}")" \
    -p "$carry_head" -p "$carry_second_base" -m "second base catch-up fixture")"
git -C "$repo" update-ref "refs/heads/$integration_branch" "$carry_second_merge"
git -C "$repo" checkout -q "$integration_branch"
carry_second_head="$(git -C "$repo" rev-parse HEAD)"
jq --arg head "$carry_second_head" '.carry={from_head:.carry.attests_head,attests_head:$head}' "$tmp/carry-live-state.json" >"$tmp/carry-second-state.json"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$carry_second_head" CAPTURE_BASE="$carry_second_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$capture_writer" integration-review-capture \
    --slate s-integrator --session alice --run-id run-integrator --state "$tmp/carry-second-state.json" --authority-kind carry --repo-dir "$repo" --at 2026-10-01T00:23:30Z) >/dev/null
carry_second_digest="$(jq -r '.interventions[] | select(.note | startswith("integration-review-authority v1 carry sha256=")) | .note' "$state/runs/run-integrator/run.json" | tail -1 | sed -E 's/.*sha256=([0-9a-f]{64}).*/\1/')"
jq '.snapshot' "$state/runs/run-integrator/rulings/$carry_second_digest" >"$tmp/carry-second-live-state.json"
# S is a sibling catch-up whose parents deliberately omit B. The canonical
# checker proves B->S is not carryable (17), while the public owner capture
# also refuses a forged A->S claim because B/C remain the retained frontier.
git -C "$repo" checkout -q main
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "sibling catch-up base fixture"
sibling_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q "$integration_branch"
sibling_head="$(git -C "$repo" commit-tree "$(git -C "$repo" rev-parse "$carry_head^{tree}")" \
    -p "$integration_head" -p "$sibling_base" -m "sibling catch-up fixture")"
git -C "$repo" update-ref "refs/heads/$integration_branch" "$sibling_head"
git -C "$repo" checkout -q "$integration_branch"
# Keep B's complete canonical carry proof intact; `carry --head S` derives
# the proposed B->S transition itself. Hand-assembling `.carry` would remove
# its immutable base/digest/generation evidence and only test shape parsing.
cp "$tmp/carry-live-state.json" "$tmp/carry-b-to-sibling-state.json"
sibling_carry_rc=0
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$sibling_head" CAPTURE_BASE="$sibling_base" bash "$fixture_integrate/assets/check-codex-cloud-review.sh" carry --state "$tmp/carry-b-to-sibling-state.json" --head "$sibling_head" --run-id run-integrator --repo-dir "$repo") >"$tmp/carry-b-to-sibling.out" 2>&1 || sibling_carry_rc=$?
[ "$sibling_carry_rc" -eq 17 ] || fail "canonical B-to-sibling carry did not refuse with 17: $(cat "$tmp/carry-b-to-sibling.out")"
jq --arg head "$sibling_head" '.carry={from_head:.head,attests_head:$head}' "$carry_auth_state" >"$tmp/carry-a-to-sibling-state.json"
expect_refused "an omitted-B sibling carry cannot select the original attachment" "no retained carry predecessor matches this review cycle origin" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_CLEAN=1 CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" integration-review-capture --slate s-integrator --session alice --run-id run-integrator --state "$7" --authority-kind carry --repo-dir "$1" --at 2026-10-01T00:23:40Z' _ \
    "$repo" "$capture_bin:$PATH" "$sibling_head" "$sibling_base" "$(token_for s-integrator)" "$capture_writer" "$tmp/carry-a-to-sibling-state.json"
git -C "$repo" update-ref "refs/heads/$integration_branch" "$carry_second_head"
git -C "$repo" checkout -q "$integration_branch"
expect_refused "an older carry replay cannot bypass the current retained hop" "no retained carry predecessor matches this review cycle origin" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_CLEAN=1 CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" integration-review-capture --slate s-integrator --session alice --run-id run-integrator --state "$7" --authority-kind carry --repo-dir "$1" --at 2026-10-01T00:23:45Z' _ \
    "$repo" "$capture_bin:$PATH" "$carry_head" "$carry_base" "$(token_for s-integrator)" "$capture_writer" "$tmp/carry-live-state.json"
jq --arg head "$carry_second_head" '.carry={from_head:.head,attests_head:$head}' "$carry_auth_state" >"$tmp/carry-skip-hop-state.json"
expect_refused "a carry source cannot skip the current retained hop" "no retained carry predecessor matches this review cycle origin" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_CLEAN=1 CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" integration-review-capture --slate s-integrator --session alice --run-id run-integrator --state "$7" --authority-kind carry --repo-dir "$1" --at 2026-10-01T00:24:00Z' _ \
    "$repo" "$capture_bin:$PATH" "$carry_second_head" "$carry_second_base" "$(token_for s-integrator)" "$capture_writer" "$tmp/carry-skip-hop-state.json"
pass "a later retained carry makes stale replays, sibling-hop skips, and source-hop skips refuse at public capture"
printf 'changed\n' >"$repo/carry-changed.txt"
git -C "$repo" add carry-changed.txt
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m "changed carry fixture"
changed_head="$(git -C "$repo" rev-parse HEAD)"
jq --arg head "$changed_head" '.carry={from_head:.carry.attests_head,attests_head:$head}' "$tmp/carry-second-live-state.json" >"$tmp/carry-current-changed-state.json"
expect_refused "a changed diff refuses the current carry predecessor" "not-carried" \
    bash -c 'cd "$1" && PATH="$2" CAPTURE_CLEAN=1 CAPTURE_HEAD="$3" CAPTURE_BASE="$4" RUN_RECORD_OWNER_TOKEN="$5" node "$6" integration-review-capture --slate s-integrator --session alice --run-id run-integrator --state "$7" --authority-kind carry --repo-dir "$1" --at 2026-10-01T00:24:45Z' _ \
    "$repo" "$capture_bin:$PATH" "$changed_head" "$carry_second_base" "$(token_for s-integrator)" "$capture_writer" "$tmp/carry-current-changed-state.json"
# The rejected carry leaves the changed PR head able to start its own ordinary
# cycle. This is a new owner reservation, not a recovery or mutation of the
# prior carried attachment.
fresh_state="$tmp/fresh-changed-head-state.json"
jq -n --arg head "$changed_head" --argjson finder "$capture_finder" '{version:2,repo:"example/repo",pr:493,head:$head,phase:"reserved",
  trigger_comment_id:null,first_trigger_comment_id:null,requested_at:null,
  charged_cycles:2,exempt_cycles:0,attempt:1,run_id:"run-integrator",
  timeout_min:10,reserved_at:"2026-10-01T00:26:00Z",finder:$finder}' >"$fresh_state"
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_HEAD="$changed_head" CAPTURE_BASE="$carry_second_base" RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator)" node "$capture_writer" integration-review-capture \
    --slate s-integrator --session alice --run-id run-integrator --state "$fresh_state" --authority-kind reserve --at 2026-10-01T00:26:30Z) >/dev/null
AUTH_COMMON="$repo/.git" AUTH_RUN=run-integrator AUTH_RECORD="$state/runs/run-integrator/run.json" node --input-type=module -e '
  import { readFileSync } from "node:fs";
  const { retainedAuthorities } = await import(process.argv[1]);
  const record = JSON.parse(readFileSync(process.env.AUTH_RECORD));
  const fresh = retainedAuthorities(record, { common: process.env.AUTH_COMMON, runId: process.env.AUTH_RUN })
    .filter((entry) => entry.kind === "reserve").at(-1)?.authority.snapshot;
  if (!fresh || fresh.head !== process.argv[2] || fresh.attempt !== 1 || fresh.carry !== undefined) process.exit(1);
' "$asset_dir/lib/integrator-review-authority.mjs" "$changed_head" || fail "changed head did not admit a fresh ordinary reserve"
pass "a changed diff starts a fresh ordinary current-head cycle after carry refusal"
(cd "$repo" && node "$writer" lock release --slate s-integrator --session alice --owner-token "$(token_for s-integrator)") >/dev/null
pass "integrator receipts and empty adjudications are immutable, replay-safe integration evidence"

# A required-Codex terminal CI failure remains a blocked diagnostic. Its
# otherwise-valid envelope must not consume an immutable receipt or adjudication
# slot under the public writer.
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
resolve_fixture_policy "$state/runs/run-integrator-after-ci-failure/policy.json" 1 after-ci
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
expect_refused "public writer keeps a required-Codex after-ci failure outside immutable receipts" "required-Codex failures remain blocked diagnostics, not completed receipts" \
    rrif receipt --run-id run-integrator-after-ci-failure --pass "$after_ci_pass"
[ ! -e "$state/runs/run-integrator-after-ci-failure/passes/integration-r1-integrator.json" ] &&
    [ ! -e "$state/runs/run-integrator-after-ci-failure/adjudications/integration-r1.json" ] ||
    fail "a required-Codex after-ci failure consumed an immutable receipt or adjudication slot"
(cd "$repo" && node "$writer" lock release --slate s-integrator-failed --session alice --owner-token "$(token_for s-integrator-failed)") >/dev/null
pass "the supported writer keeps a required-Codex after-ci failure as a blocked diagnostic"

# Positive integration capacity does not itself make Codex required. Resolve
# the production policy with an explicitly advisory finder, then retain and
# adjudicate a real non-Codex finding with no Codex cycle. This guards the
# routing predicate against treating `codex_cycle: null` as an unconditional
# block merely because the integration cap is positive.
new_run run-integrator-optional-codex
write_plan s-integrator-optional 24:run-integrator-optional-codex
acquire s-integrator-optional alice
rio() { (cd "$repo" && node "$writer" transition --slate s-integrator-optional --session alice --owner-token "$(token_for s-integrator-optional)" --run-id run-integrator-optional-codex "$@"); }
rrio() { (cd "$repo" && RUN_RECORD_OWNER_TOKEN="$(token_for s-integrator-optional)" node "$writer" "$@" --slate s-integrator-optional --session alice); }
for step in "claim:k" "implement:claimed" "verify:implemented" "challenge:verified" "security:converged" "integration:secure"; do
    rio --stage "${step%%:*}" --exit "${step#*:}" --at 2026-01-01T00:06:00Z >/dev/null
done
optional_branch="fixture-run-integrator-optional-codex"
git -C "$repo" branch "$optional_branch" HEAD
mkdir -p "$state/runs/run-integrator-optional-codex/passes" "$state/runs/run-integrator-optional-codex/adjudications"
printf '{"branch":"%s"}\n' "$optional_branch" >"$state/runs/run-integrator-optional-codex/branch.json"
resolve_fixture_policy "$state/runs/run-integrator-optional-codex/policy.json" 1 after-ci optional-codex
jq -e '.rounds.integration == 1 and .stages.integration.finder == [{id:"codex-cloud",gates:false,budget:1}]' \
    "$state/runs/run-integrator-optional-codex/policy.json" >/dev/null ||
    fail "production policy reader did not preserve the advisory Codex finder"
optional_head="$(git -C "$repo" rev-parse "$optional_branch")"
optional_pass="$tmp/integration-r1-optional-codex.json"
jq --arg head "$optional_head" '
  .run = {run_id:"run-integrator-optional-codex",initiated_by:"human"}
  | .head = $head
  | .produced_at = "2026-10-01T00:00:00Z"
  | .payload.settled_at = "2026-10-01T00:00:00Z"
  | .payload.codex_cycle = null
  | .payload.verdict = "findings"
  | .payload.findings = [{id:"integration-r1-human-1",body:"human finding while Codex is advisory",source_id:"1004"}]
  | del(.payload.applied_dispositions)
' "$asset_dir/../../../../schemas/fixtures/result.integrator.schema/valid/codex-cycle-null.json" >"$optional_pass"
rrio receipt --run-id run-integrator-optional-codex --pass "$optional_pass" >/dev/null
jq -n --arg head "$optional_head" '{
  schema:2, run_id:"run-integrator-optional-codex", stage:"integration", round:1, reviewed_head:$head,
  adjudications:[{finding_id:"integration-r1-human-1", reviewer_priority:null, adjudicated_priority:"P2",
    disposition:"decline", reason:"the fixture exercises admission only", evidence:"production reader resolved Codex as advisory", override:null}]
}' >"$tmp/integration-r1-optional-codex-adjudication.json"
rrio adjudicate --run-id run-integrator-optional-codex --file "$tmp/integration-r1-optional-codex-adjudication.json" >/dev/null
[ -f "$state/runs/run-integrator-optional-codex/passes/integration-r1-integrator.json" ] &&
    [ -f "$state/runs/run-integrator-optional-codex/adjudications/integration-r1.json" ] ||
    fail "an optional-Codex null-cycle findings receipt was not retained and adjudicated"
(cd "$repo" && node "$writer" lock release --slate s-integrator-optional --session alice --owner-token "$(token_for s-integrator-optional)") >/dev/null
pass "a production-reader advisory Codex policy admits and adjudicates null-cycle findings"

# A zero integration cap opens no finder cycles, even when a configured or
# selected non-Codex finder gates. Positive capacity must still authenticate
# that finder before the writer can retain the same null-cycle receipt.
for requirement in configured selected; do
    cap_run="run-integrator-cap-zero-$requirement"
    cap_slate="s-integrator-cap-zero-$requirement"
    new_run "$cap_run"
    write_plan "$cap_slate" "28:$cap_run"
    acquire "$cap_slate" alice
    for step in "claim:k" "implement:claimed" "verify:implemented" "challenge:verified" "security:converged" "integration:secure"; do
        (cd "$repo" && RUN_RECORD_OWNER_TOKEN="$(token_for "$cap_slate")" node "$writer" transition \
            --slate "$cap_slate" --session alice --run-id "$cap_run" --stage "${step%%:*}" --exit "${step#*:}" --at 2026-01-01T00:06:00Z) >/dev/null
    done
    cap_branch="fixture-$cap_run"
    git -C "$repo" branch "$cap_branch" HEAD
    cap_dir="$state/runs/$cap_run"
    printf '{"branch":"%s"}\n' "$cap_branch" >"$cap_dir/branch.json"
    cap_profile=optional-codex-required-copilot
    if [ "$requirement" = selected ]; then
        cap_profile=optional-codex
        jq '.finder_selection = [{stage:"integration",configured:["codex-cloud"],requested:["copilot-cloud"],effective:["codex-cloud","copilot-cloud"]}]' "$cap_dir/run.json" >"$tmp/cap-selected.json"
        cp "$tmp/cap-selected.json" "$cap_dir/run.json"
    fi
    cap_pass="$tmp/$cap_run.json"
    jq --arg run "$cap_run" --arg head "$(git -C "$repo" rev-parse "$cap_branch")" \
        '.run.run_id=$run | .head=$head' \
        "$asset_dir/../../../../schemas/fixtures/result.integrator.schema/valid/codex-cycle-null.json" >"$cap_pass"
    resolve_fixture_policy "$cap_dir/policy.json" 1 after-ci "$cap_profile"
    expect_refused "positive integration capacity authenticates the $requirement non-Codex finder" "required finder copilot-cloud has no reported cycle" \
        bash -c 'cd "$1" && RUN_RECORD_OWNER_TOKEN="$2" node "$3" receipt --slate "$4" --session alice --run-id "$5" --pass "$6"' _ \
        "$repo" "$(token_for "$cap_slate")" "$writer" "$cap_slate" "$cap_run" "$cap_pass"
    [ ! -e "$cap_dir/passes/integration-r1-integrator.json" ] || fail "missing required finder consumed an immutable receipt"
    resolve_fixture_policy "$cap_dir/policy.json" 0 after-ci "$cap_profile"
    jq -e '.rounds.integration == 0' "$cap_dir/policy.json" >/dev/null || fail "production resolver did not disable integration"
    (cd "$repo" && RUN_RECORD_OWNER_TOKEN="$(token_for "$cap_slate")" node "$writer" receipt \
        --slate "$cap_slate" --session alice --run-id "$cap_run" --pass "$cap_pass") >/dev/null
    [ -f "$cap_dir/passes/integration-r1-integrator.json" ] || fail "cap-zero $requirement finder blocked the null-cycle receipt"
    (cd "$repo" && RUN_RECORD_OWNER_TOKEN="$(token_for "$cap_slate")" node "$writer" lock release --slate "$cap_slate" --session alice) >/dev/null
    pass "cap-zero $requirement non-Codex finder admits a null-cycle receipt; positive cap refuses omitted evidence"
done

new_run run-input-snapshot
write_plan s-input-snapshot 23:run-input-snapshot
acquire s-input-snapshot alice
ris() { (cd "$repo" && node "$writer" transition --slate s-input-snapshot --session alice --owner-token "$(token_for s-input-snapshot)" --run-id run-input-snapshot "$@"); }
rris() { (cd "$repo" && RUN_RECORD_OWNER_TOKEN="$(token_for s-input-snapshot)" node "$writer" "$@" --slate s-input-snapshot --session alice); }
for step in "claim:k" "implement:claimed" "verify:implemented" "challenge:verified" "security:converged" "integration:secure"; do
    ris --stage "${step%%:*}" --exit "${step#*:}" --at 2026-01-01T00:06:00Z >/dev/null
done
snapshot_branch="fixture-run-input-snapshot"
git -C "$repo" branch "$snapshot_branch" HEAD
mkdir -p "$state/runs/run-input-snapshot/passes" "$state/runs/run-input-snapshot/adjudications"
printf '{"branch":"%s"}\n' "$snapshot_branch" >"$state/runs/run-input-snapshot/branch.json"
resolve_fixture_policy "$state/runs/run-input-snapshot/policy.json" 0
snapshot_head="$(git -C "$repo" rev-parse "$snapshot_branch")"
snapshot_valid="$tmp/input-snapshot-valid.json"
jq --arg head "$snapshot_head" '
  .run = {run_id:"run-input-snapshot",initiated_by:"human"}
  | .head = $head | .produced_at = "2026-10-01T00:00:00Z" | .payload.settled_at = "2026-10-01T00:00:00Z"
  | .payload.codex_cycle = null
' "$asset_dir/../../../../schemas/fixtures/result.integrator.schema/valid/verdict-clean.json" >"$snapshot_valid"
snapshot_source="$tmp/input-snapshot-source.json"
jq '.producer.model = 123' "$snapshot_valid" >"$snapshot_source"
snapshot_hook="$tmp/input-snapshot-swap.mjs"
cat >"$snapshot_hook" <<'NODE'
import fs from 'node:fs'
import { basename } from 'node:path'
import { syncBuiltinESMExports } from 'node:module'

const original = fs.writeFileSync
let swapped = false
fs.writeFileSync = function (path, ...args) {
  if (!swapped && basename(path).startsWith('.context.')) {
    original(process.env.SNAPSHOT_SWAP_SOURCE, fs.readFileSync(process.env.SNAPSHOT_SWAP_REPLACEMENT))
    swapped = true
  }
  return original.call(this, path, ...args)
}
syncBuiltinESMExports()
NODE
snapshot_bare_rc=0
node "$fixture_support/assets/validate-result-schemas.mjs" integrator "$snapshot_source" >"$tmp/input-snapshot-bare.log" 2>&1 || snapshot_bare_rc=$?
[ "$snapshot_bare_rc" -ne 0 ] || fail "the invalid receipt source unexpectedly passed bare schema validation"
snapshot_receipt_rc=0
(cd "$repo" && SNAPSHOT_SWAP_SOURCE="$snapshot_source" SNAPSHOT_SWAP_REPLACEMENT="$snapshot_valid" RUN_RECORD_OWNER_TOKEN="$(token_for s-input-snapshot)" node --import "$snapshot_hook" "$writer" receipt --slate s-input-snapshot --session alice --run-id run-input-snapshot --pass "$snapshot_source") >"$tmp/input-snapshot-receipt.log" 2>&1 || snapshot_receipt_rc=$?
cmp -s "$snapshot_source" "$snapshot_valid" || fail "the receipt race fixture did not replace its producer source"
[ "$snapshot_receipt_rc" -eq 1 ] || fail "the invalid receipt snapshot was accepted after its source changed: $(cat "$tmp/input-snapshot-receipt.log")"
grep -q 'producer' "$tmp/input-snapshot-receipt.log" || fail "the invalid receipt snapshot did not fail schema validation"
[ ! -e "$state/runs/run-input-snapshot/passes/integration-r1-integrator.json" ] || fail "the invalid receipt snapshot consumed an immutable receipt slot"
rris receipt --run-id run-input-snapshot --pass "$snapshot_source" >/dev/null
cmp -s "$snapshot_source" "$state/runs/run-input-snapshot/passes/integration-r1-integrator.json" || fail "the valid receipt was not retained from its validated snapshot"
snapshot_adjudication_valid="$tmp/input-snapshot-adjudication-valid.json"
jq -n --arg head "$snapshot_head" '{schema:2,run_id:"run-input-snapshot",stage:"integration",round:1,reviewed_head:$head,adjudications:[]}' >"$snapshot_adjudication_valid"
snapshot_adjudication_source="$tmp/input-snapshot-adjudication-source.json"
jq '.schema = 99' "$snapshot_adjudication_valid" >"$snapshot_adjudication_source"
snapshot_adjudication_rc=0
(cd "$repo" && SNAPSHOT_SWAP_SOURCE="$snapshot_adjudication_source" SNAPSHOT_SWAP_REPLACEMENT="$snapshot_adjudication_valid" RUN_RECORD_OWNER_TOKEN="$(token_for s-input-snapshot)" node --import "$snapshot_hook" "$writer" adjudicate --slate s-input-snapshot --session alice --run-id run-input-snapshot --file "$snapshot_adjudication_source") >"$tmp/input-snapshot-adjudication.log" 2>&1 || snapshot_adjudication_rc=$?
cmp -s "$snapshot_adjudication_source" "$snapshot_adjudication_valid" || fail "the adjudication race fixture did not replace its producer source"
[ "$snapshot_adjudication_rc" -eq 1 ] || fail "the invalid adjudication snapshot was accepted after its source changed: $(cat "$tmp/input-snapshot-adjudication.log")"
[ ! -e "$state/runs/run-input-snapshot/adjudications/integration-r1.json" ] || fail "the invalid adjudication snapshot consumed an immutable adjudication slot"
rris adjudicate --run-id run-input-snapshot --file "$snapshot_adjudication_source" >/dev/null
cmp -s "$snapshot_adjudication_source" "$state/runs/run-input-snapshot/adjudications/integration-r1.json" || fail "the valid adjudication was not retained from its validated snapshot"
(cd "$repo" && node "$writer" lock release --slate s-input-snapshot --session alice --owner-token "$(token_for s-input-snapshot)") >/dev/null
pass "receipt and adjudication admission retain the same immutable bytes they validate"

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
PLAN_REVIEWER_TIER=economy write_plan planned-lane 333:run-planned-lane
node --input-type=module - "$asset_dir" "$state/slates/planned-lane/plan.json" >"$tmp/lane-policy.json" <<'NODE'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
const [assets, planFile] = process.argv.slice(2)
process.argv[1] = assets
const { resolvePolicy } = await import(`${assets}/devflow-policy.mjs`)
const { parseToml } = await import(`${assets}/lib/toml-lite.mjs`)
const full = resolvePolicy(parseToml(readFileSync(resolve(assets, '../../../../../.devflow.toml'), 'utf8')), {
  rigor: 'deep',
  tierOverrides: { implementer: 'frontier' },
  tierLabels: { reviewer: 'economy' },
})
if (!full.disclosures.some(({ code }) => code === 'off-profile-tier') ||
    !full.disclosures.some(({ code }) => code === 'role-tier-floor')) {
  throw new Error('policy reader did not emit both structured disclosure variants')
}
const profile = JSON.parse(readFileSync(planFile)).revisions.at(-1).plan.policy
full.rigor = { ...full.rigor, level: profile.rigor, source: profile.rigor_source }
full.rounds = { ...full.rounds, ...profile.caps, integration_exempt: profile.caps.integration }
full.breadth = { ...full.breadth, ...profile.breadth, max_in_flight: profile.breadth.max_in_flight ?? profile.breadth.max_parallel_agents }
full.strategy.name = profile.strategy
for (const [role, tier] of Object.entries(profile.role_tiers)) full.roles[role].tier = tier
console.log(JSON.stringify(full))
NODE
# The exact lane-profile comparison preserves the new ceiling and normalizes
# only its backwards-compatible parallel-ceiling default.
node --input-type=module - "$writer" "$state/slates/planned-lane/plan.json" "$tmp/lane-policy.json" <<'NODE'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync } from 'node:fs'
const [writer, planFile, policyFile] = process.argv.slice(2)
process.argv[1] = planFile
const { lanePolicyProjection } = await import(writer)
const plan = JSON.parse(readFileSync(planFile)).revisions.at(-1).plan
const lane = plan.lanes[0]
const policy = JSON.parse(readFileSync(policyFile))
assert.doesNotThrow(() => lanePolicyProjection(plan, lane, policyFile))
plan.policy.breadth.max_in_flight = 5
policy.breadth.max_in_flight = 5
writeFileSync(policyFile, JSON.stringify(policy))
assert.equal(lanePolicyProjection(plan, lane, policyFile).breadth.max_in_flight, 5)
policy.breadth.max_in_flight = 6
writeFileSync(policyFile, JSON.stringify(policy))
assert.throws(() => lanePolicyProjection(plan, lane, policyFile), /does not match/)
delete plan.policy.breadth.max_in_flight
policy.breadth.max_in_flight = plan.policy.breadth.max_parallel_agents
writeFileSync(policyFile, JSON.stringify(policy))
assert.doesNotThrow(() => lanePolicyProjection(plan, lane, policyFile))
NODE
pass "lane policy comparison retains explicit max_in_flight and accepts the legacy fallback"
deferred_run=run-deferred-lane
deferred_branch=333-l
deferred_revision="$(git -C "$repo" rev-parse HEAD)"
deferred_pointer="$("$monitor" active-path --branch "$deferred_branch" --repo-root "$repo")"
new_record "$deferred_run"
printf 'fixture\n' >"$state/runs/$deferred_run/owner-slate"
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
[ "$(jq -c '.disclosures' "$state/runs/run-planned-lane/policy.json")" = "$(jq -c '.disclosures' "$tmp/lane-policy.json")" ] ||
    fail "lane-init changed the policy reader's disclosures projection"
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

# A fresh retained run must be usable by confidence-stage consumers immediately.
acquire retained-lane alice --issues 334
PLAN_REVIEWER_TIER=economy write_plan retained-lane 334:run-retained-old
retained_base="$(git -C "$repo" rev-parse refs/remotes/origin/main)"
node --input-type=module - "$writer" "$state/slates/retained-lane/plan.json" "$retained_base" <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs'
const [writer, file, base] = process.argv.slice(2)
process.argv[1] = file
const { chainDigest } = await import(writer)
const document = JSON.parse(readFileSync(file))
const revision = document.revisions[0]
revision.plan.base_sha = base
revision.plan.issues[0].url = 'https://github.com/example/repo/issues/334'
revision.digest = chainDigest({ seq: revision.seq, plan: revision.plan, at: revision.at, reason: revision.reason }, revision.prev_digest)
writeFileSync(file, JSON.stringify(document))
NODE
git -C "$repo" branch 334-l "$retained_base"
retained_rr() {
    (cd "$repo" && node "$writer" "$@" --slate retained-lane --session alice --owner-token "$(token_for retained-lane)")
}
retained_rr lane-init --lane l334 --policy "$tmp/lane-policy.json" >/dev/null
retained_pointer="$("$monitor" active-path --branch 334-l --repo-root "$repo")"
"$monitor" activate --active-state "$retained_pointer" --run-id run-retained-old --branch 334-l \
    --expected-predecessor absent --expected-generation 0 --registry-revision "$retained_base" \
    --writer feature-owner --repo-root "$repo" >/dev/null
cp "$retained_pointer" "$tmp/retained-predecessor.json"
retained_rr transition --run-id run-retained-old --stage claim >/dev/null
retained_rr close --run-id run-retained-old --outcome abandoned --exit 'terminal fixture' >/dev/null
# Reproduce a terminal predecessor whose pointer retirement did not complete.
cp "$tmp/retained-predecessor.json" "$retained_pointer"
cp "$state/runs/run-retained-old/run.json" "$tmp/retained-terminal.json"
export RUN_RECORD_PR_STATE=OPEN
for decision in handoff fix-request reactivate; do
    extra=()
    case "$decision" in
    handoff) extra=(--pr 334) ;;
    reactivate) extra=(
        --run-id run-retained-fix --claim-record-file "$claim_record_file"
        --claim-label claim:gpt --model-label none --family gpt --registry-snapshot "$claim_registry_snapshot"
    ) ;;
    esac
    (cd "$repo" && node "$asset_dir/plan-revise.mjs" "$decision" --slate retained-lane --session alice \
        --owner-token "$(token_for retained-lane)" --issue 334 --reason 'retained activation regression' "${extra[@]+"${extra[@]}"}") >/dev/null
done
claim_restore_call="restore --repo example/repo --issue 334 --record-file $claim_record_file --claim-label claim:gpt --model-label none --family gpt --registry-snapshot $claim_registry_snapshot"
[ "$(cat "$claim_transaction_log")" = "$claim_restore_call" ] || fail "retained reactivation did not pass the exact resolved claim inputs: $(cat "$claim_transaction_log")"
# A parked branch stays on its old merge base when the slate base advances.
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'advance slate base'
retained_moved="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" update-ref refs/remotes/origin/main "$retained_moved"
(cd "$repo" && node "$asset_dir/plan-revise.mjs" base-move --slate retained-lane --session alice \
    --owner-token "$(token_for retained-lane)" --new-base "$retained_moved" --reason 'parked branch stays behind') >/dev/null
[ "$(git -C "$repo" merge-base refs/remotes/origin/main 334-l)" = "$retained_base" ] || fail "parked branch fixture unexpectedly caught up"
[ "$retained_moved" != "$retained_base" ] || fail "slate base did not advance"
# Stale executing assets must fail before any fresh run files are published.
tools_current="$(git -C "$tool_root" rev-parse HEAD)"
tools_new="$(printf 'new tools\n' | git -C "$tool_root" -c user.name=t -c user.email=t@t commit-tree "${tools_current}^{tree}" -p "$tools_current")"
git -C "$tool_root" update-ref refs/remotes/origin/main "$tools_new"
retained_rc=0
retained_rr lane-init --lane l334 --policy "$tmp/lane-policy.json" >"$tmp/retained-stale.log" 2>&1 || retained_rc=$?
[ "$retained_rc" -ne 0 ] || fail "stale retained assets accepted"
grep -q 'stale asset checkout' "$tmp/retained-stale.log" || fail "wrong stale preflight refusal"
[ ! -e "$state/runs/run-retained-fix/run.json" ] || fail "stale preflight published run"
git -C "$tool_root" update-ref refs/remotes/origin/main "$tools_current"
pass "retained asset freshness preflight leaves no run record"

# A later activation failure rolls back files and allows an ordinary retry.
real_bash="$(command -v bash)"
mkdir -p "$tmp/activation-failure-bin"
cat >"$tmp/activation-failure-bin/bash" <<BASH
#!/bin/sh
if [ "\$2" = activate ]; then
    echo 'injected activation failure' >&2
    exit 1
fi
exec "$real_bash" "\$@"
BASH
chmod +x "$tmp/activation-failure-bin/bash"
retained_rc=0
PATH="$tmp/activation-failure-bin:$PATH" retained_rr lane-init --lane l334 --policy "$tmp/lane-policy.json" >"$tmp/retained-activate.log" 2>&1 || retained_rc=$?
[ "$retained_rc" -ne 0 ] || fail "injected activation failure accepted"
grep -q 'injected activation failure' "$tmp/retained-activate.log" || fail "wrong activation refusal"
for name in run.json policy.json owner-slate branch.json; do
    [ ! -e "$state/runs/run-retained-fix/$name" ] || fail "activation failure left $name"
done
cmp -s "$tmp/retained-predecessor.json" "$retained_pointer" || fail "failed activation changed predecessor"
pass "retained activation failure rolls back new run files"

# A failure after publication must preserve the run; unreadable pointers are
# equally indeterminate. Reset only fixture state after each injected failure.
for pointer_mode in committed unreadable; do
    cat >"$tmp/activation-failure-bin/bash" <<BASH
#!/bin/sh
if [ "\$2" = activate ]; then
    "$real_bash" "\$@" || exit \$?
    if [ "$pointer_mode" = unreadable ]; then
        printf '{invalid' >"$retained_pointer"
    fi
    echo 'injected post-publication failure' >&2
    exit 1
fi
exec "$real_bash" "\$@"
BASH
    retained_rc=0
    PATH="$tmp/activation-failure-bin:$PATH" retained_rr lane-init --lane l334 --policy "$tmp/lane-policy.json" >"$tmp/retained-post-publication.log" 2>&1 || retained_rc=$?
    [ "$retained_rc" -ne 0 ] || fail "post-publication failure accepted: $pointer_mode"
    grep -q 'injected post-publication failure' "$tmp/retained-post-publication.log" || fail "wrong post-publication refusal"
    for name in run.json policy.json owner-slate branch.json; do
        [ -f "$state/runs/run-retained-fix/$name" ] || fail "post-publication failure deleted $name: $pointer_mode"
    done
    if [ "$pointer_mode" = committed ]; then
        jq -e '.run_id == "run-retained-fix"' "$retained_pointer" >/dev/null || fail "activation did not publish its pointer"
    fi
    cp "$tmp/retained-predecessor.json" "$retained_pointer"
    for name in run.json policy.json owner-slate branch.json; do
        rm "$state/runs/run-retained-fix/$name"
    done
    pass "retained activation preserves run files after $pointer_mode publication failure"
done

retained_rr lane-init --lane l334 --policy "$tmp/lane-policy.json" >"$tmp/retained-init.json"
jq -e --arg pointer "$retained_pointer" --arg dir "$state/runs/run-retained-fix" \
    '.run_id == "run-retained-fix" and .branch == "334-l" and .generation == 2 and .active_state_path == $pointer and .record_directory == $dir' \
    "$tmp/retained-init.json" >/dev/null || fail "retained lane-init omitted its activation identity"
jq -e '.branch == "334-l" and .run_id == "run-retained-fix"' \
    "$state/runs/run-retained-fix/branch.json" >/dev/null || fail "retained run has no generation-2 branch binding"
jq -e '.run_id == "run-retained-fix" and .generation == 2' "$retained_pointer" >/dev/null || fail "retained active pointer did not advance"
cmp -s "$tmp/retained-terminal.json" "$state/runs/run-retained-old/run.json" || fail "retained activation changed its terminal predecessor"
retained_rr transition --run-id run-retained-fix --stage claim >/dev/null
for stage in implement verify challenge; do
    retained_rr transition --run-id run-retained-fix --stage "$stage" --exit 'regression fixture' >/dev/null
done
retained_rr ledger --run-id run-retained-fix --stage challenge >/dev/null
pass "retained lane-init activates generation 2 after a slate base move and supports ledger"

# Fleet branches may exist only in a foreign clone, not the conductor checkout.
retained_rr close --run-id run-retained-fix --outcome abandoned --exit 'next retained fixture' >/dev/null
retained_sequence="$(jq -r '.revisions[-1].seq' "$state/slates/retained-lane/plan.json")"
for decision in handoff fix-request reactivate; do
    extra=()
    case "$decision" in
    handoff) extra=(--pr 334 --expected-revision "$retained_sequence") ;;
    reactivate) extra=(
        --run-id run-retained-no-local-ref --claim-record-file "$claim_record_file"
        --claim-label claim:gpt --model-label none --family gpt --registry-snapshot "$claim_registry_snapshot"
    ) ;;
    esac
    (cd "$repo" && node "$asset_dir/plan-revise.mjs" "$decision" --slate retained-lane --session alice \
        --owner-token "$(token_for retained-lane)" --issue 334 --reason 'foreign branch regression' "${extra[@]+"${extra[@]}"}") >/dev/null
done
claim_restore_calls_twice="$(printf '%s\n%s' "$claim_restore_call" "$claim_restore_call")"
[ "$(cat "$claim_transaction_log")" = "$claim_restore_calls_twice" ] || fail "foreign-branch reactivation did not pass the exact resolved claim inputs twice: $(cat "$claim_transaction_log")"
git -C "$repo" update-ref -d refs/heads/334-l
retained_rr lane-init --lane l334 --policy "$tmp/lane-policy.json" >"$tmp/retained-no-local-ref.json"
jq -e '.run_id == "run-retained-no-local-ref" and .branch == "334-l"' \
    "$state/runs/run-retained-no-local-ref/branch.json" >/dev/null || fail "retained activation required a conductor-local lane branch"
retained_registry="$(git -C "$repo" log -1 --format=%H "$retained_moved" -- agent-registry.json)"
jq -e --arg revision "$retained_registry" '.registry_revision == $revision' "$retained_pointer" >/dev/null || fail "retained activation did not use the slate registry revision"
unset RUN_RECORD_PR_STATE
pass "retained lane-init activates without a local lane branch using the slate registry"

# A reused lane name may have a newer historical delivery than the one being
# reactivated. Select the predecessor by repository-qualified issue and branch.
node --input-type=module - "$writer" "$repo" "$tmp" "$retained_moved" "$tmp/lane-policy.json" <<'IDENTITY'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
const [writer, repo, tmp, base, policyFile] = process.argv.slice(2)
process.argv[1] = tmp
const { acquireSlateLock, branchHead, chainDigest, laneInit, validateFile } = await import(writer)
process.chdir(repo)
process.env.RUN_RECORD_PR_STATE = 'OPEN'
const root = join(repo, '.git/dev-flow-v2')
const slate = 'retained-delivery-identity'
const dir = join(root, 'slates', slate)
mkdirSync(dir, { recursive: true })
const foreign = join(tmp, 'retained-delivery-foreign')
execFileSync('git', ['init', '-q', '-b', '335-current', foreign])
execFileSync('git', ['-C', foreign, 'remote', 'add', 'origin', 'https://github.com/owner/b'])
execFileSync('git', ['-C', foreign, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'foreign fixture'])
const foreignHead = execFileSync('git', ['-C', foreign, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
const policy = JSON.parse(readFileSync(join(root, 'slates/planned-lane/plan.json'))).revisions.at(-1).plan.policy
const issue = (repo, verdict, pr) => ({ repo, number: 335, title: repo, url: `https://github.com/${repo}/issues/335`,
  verdict, candidate_files: ['same.txt'], blocked_by: [], ...(pr ? { pr } : {}) })
const lane = (repo, branch, run_id) => ({ repo, base_sha: foreignHead, lane: 'reused', issue: 335,
  wave: 1, branch, run_id, fence: ['same.txt'], expansions: [] })
const originalLane = lane('owner/b', '335-current', 'run-identity-predecessor')
const plan = { repo: 'owner/a', base_sha: base, policy,
  repository_bases: [{ repo: 'owner/b', base_sha: foreignHead }],
  dispatcher: { kind: 'interactive', parallel_cap: policy.breadth.max_parallel_agents, foreman_max_parallel: null },
  issues: [issue('owner/b', 'valid')], lanes: [originalLane], waves: [{ number: 1, issues: ['owner/b#335'] }], overlaps: [] }
const document = { schema: 1, slate_id: slate, revisions: [] }
function append(plan) {
  const seq = document.revisions.length
  const prev_digest = document.revisions.at(-1)?.digest ?? 'genesis'
  const at = `2026-11-04T00:0${seq}:00Z`
  const reason = 'retained delivery identity fixture'
  const digest = chainDigest({ seq, plan, at, reason }, prev_digest)
  document.revisions.push({ seq, prev_digest, digest, at, reason, plan })
  writeFileSync(join(dir, 'plan.json'), JSON.stringify(document))
  validateFile('plan', join(dir, 'plan.json'), 'identity fixture')
}
append(plan)
const lock = acquireSlateLock({ root, slate, session: 'alice', issues: ['owner/b#335', 'owner/c#335'], create: true })
const args = { slate, session: 'alice', lane: 'reused', policy: policyFile, 'owner-token': lock.mintedToken }
laneInit(args)
const oldDir = join(root, 'runs', originalLane.run_id)
writeFileSync(join(oldDir, 'branch.json'), JSON.stringify({ version: 1, run_id: originalLane.run_id,
  branch: originalLane.branch, repo: 'owner/b', repo_root: foreign }))
// Same numeric issue and lane name, but a different repository and branch.
const other = structuredClone(plan)
other.repository_bases.push({ repo: 'owner/c', base_sha: foreignHead })
other.issues = [issue('owner/b', 'done'), issue('owner/c', 'valid')]
other.lanes = [lane('owner/c', '335-other', 'run-unrelated-delivery')]
other.waves = [{ number: 1, issues: ['owner/c#335'] }]
append(other)
const fresh = structuredClone(other)
fresh.issues = [issue('owner/b', 'handed-off', 335), issue('owner/c', 'done')]
fresh.lanes = []
fresh.retained_lanes = [{ lane: { ...originalLane, run_id: 'run-identity-fresh' }, policy, state: 'working' }]
fresh.waves = [{ number: 1, issues: ['owner/b#335'] }]
fresh.merge_queue = [{ repo: 'owner/b', issue: 335, pr: 335 }]
append(fresh)
laneInit(args)
const freshDir = join(root, 'runs/run-identity-fresh')
const binding = JSON.parse(readFileSync(join(freshDir, 'branch.json')))
assert.equal(binding.repo, 'owner/b')
assert.equal(binding.repo_root, foreign)
assert.deepEqual(branchHead(freshDir), { branch: '335-current', repoRoot: foreign, head: foreignHead })
console.log('PASS: foreign retained predecessor ignores unrelated deliveries reusing a lane name')
IDENTITY

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

# Equal numbers in different repositories are different lock and dispatch identities.
node --input-type=module - "$writer" "$tmp" <<'MULTI_REPO'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
const [writer, tmp] = process.argv.slice(2)
process.argv[1] = tmp
const { acquireSlateLock, releaseSlateLock, assertDispatchCapacity, branchHead, runRepository, chainDigest, planGraph, planWire } = await import(writer)
const repo = join(tmp, 'multi-repo-locks')
mkdirSync(repo)
execFileSync('git', ['init', '-q', repo])
execFileSync('git', ['-C', repo, 'remote', 'add', 'origin', 'git@github.com:owner/a.git'])
process.chdir(repo)
const root = join(repo, '.git/dev-flow-v2')
const a = acquireSlateLock({ root, slate: 'a', session: 'a', issues: [7], create: true })
const b = acquireSlateLock({ root, slate: 'b', session: 'b', issues: ['owner/b#7'], create: true })
assert.deepEqual(a.issues, [7])
assert.deepEqual(b.issues, ['owner/b#7'])
assert.throws(() => acquireSlateLock({ root, slate: 'same-a', session: 'c', issues: ['OWNER/A#7'], create: true }), /already locked/)
assert.throws(() => acquireSlateLock({ root, slate: 'same-b', session: 'c', issues: ['owner/b#7'], create: true }), /already locked/)
const policy = { rigor: 'thorough', rigor_source: 'operator', caps: { challenge: 1, review: 1, integration: 1, remediation: 1, min_rounds: 1, wall_clock_min: 60 },
  breadth: { max_agent_runs: 4, max_parallel_agents: 2, max_in_flight: 2 }, strategy: 'orchestrate', strategy_source: 'operator',
  role_tiers: { orchestrator: 'apex', implementer: 'apex', challenger: 'apex', reviewer: 'frontier', integrator: 'economy' }, operator_pins: [] }
const plan = { repo: 'owner/a', base_sha: 'a'.repeat(40), policy,
  repository_bases: [{ repo: 'owner/b', base_sha: 'b'.repeat(40) }],
  dispatcher: { kind: 'interactive', parallel_cap: 2, foreman_max_parallel: null },
  issues: ['owner/a', 'owner/b'].map((repo) => ({ repo, number: 7, title: repo, url: `https://github.com/${repo}/issues/7`, verdict: 'valid', candidate_files: ['same.txt'], blocked_by: [] })),
  lanes: ['owner/a', 'owner/b'].map((repo, index) => ({ repo, base_sha: (index === 0 ? 'a' : 'b').repeat(40), issue: 7, lane: `lane-${index}`, branch: `feat/${index}`, run_id: `run-${index}`, wave: 1, fence: ['same.txt'], expansions: [] })),
  waves: [{ number: 1, issues: [7, 'owner/b#7'] }], overlaps: [] }
assert.deepEqual(planWire(planGraph(plan)), plan)
const malformed = structuredClone(plan)
malformed.issues[1].number = 'owner/b#7'
assert.throws(() => planGraph(malformed), /wire issue numbers must be integers/)
const dir = join(root, 'slates/fleet')
mkdirSync(dir, { recursive: true })
const entry = { seq: 0, prev_digest: 'genesis', at: '2026-11-01T00:00:00Z', reason: 'two repositories', plan }
entry.digest = chainDigest({ seq: entry.seq, plan, at: entry.at, reason: entry.reason }, 'genesis')
writeFileSync(join(dir, 'plan.json'), JSON.stringify({ schema: 1, slate_id: 'fleet', revisions: [entry] }))
execFileSync(process.execPath, [join(dirname(writer), 'validate-result-schemas.mjs'), 'plan', join(dir, 'plan.json')])
// Make the first issue closed, so integer-only candidate lookup refuses B.
const bin = join(tmp, 'multi-repo-bin')
mkdirSync(bin)
const log = join(tmp, 'multi-repo-gh.jsonl')
writeFileSync(join(bin, 'gh'), `#!/usr/bin/env node
const args = process.argv.slice(2)
require('node:fs').appendFileSync(${JSON.stringify(log)}, JSON.stringify(args)+'\\n')
const path = args.find((arg) => arg.startsWith('repos/owner/')) || ''
if (path.endsWith('/comments') || path.endsWith('/timeline')) console.log('[]')
else console.log(JSON.stringify({state: path.includes('/owner/a/') ? 'CLOSED' : 'OPEN', labels: [], assignees: []}))
`, { mode: 0o755 })
process.env.PATH = `${bin}:${process.env.PATH}`
assert.deepEqual(assertDispatchCapacity(root, plan, plan.lanes[1], 'fleet'), { working: 1, in_flight: 1 })
const calls = readFileSync(log, 'utf8').trim().split('\n').map(JSON.parse)
assert.ok(calls.some((args) => args[2] === 'https://github.com/owner/b/issues/7'))
assert.ok(!calls.some((args) => args[2] === 'https://github.com/owner/a/issues/7'))
// Retained lane identities must survive the same repository-qualified projection.
const retainedPlan = structuredClone(plan)
retainedPlan.retained_lanes = [{ lane: retainedPlan.lanes.pop(), policy, state: 'pending' }]
retainedPlan.issues[1].verdict = 'handed-off'
retainedPlan.issues[1].pr = 77
assert.equal(planGraph(retainedPlan).retained_lanes[0].lane.issue, 'owner/b#7')
assert.deepEqual(planWire(planGraph(retainedPlan)), retainedPlan)
console.log('PASS: repository-qualified locks and dispatch distinguish owner/a#7 from owner/b#7')

// Handoff removes the live lane while its integration run remains open.
// Resolve its latest retained assignment after retirement from the live plan.
releaseSlateLock({ root, slate: 'a', session: 'a', ownerToken: a.mintedToken })
releaseSlateLock({ root, slate: 'b', session: 'b', ownerToken: b.mintedToken })
const foreign = join(tmp, 'handed-off-foreign')
mkdirSync(foreign)
execFileSync('git', ['init', '-q', '-b', 'feat/1', foreign])
execFileSync('git', ['-C', foreign, 'remote', 'add', 'origin', 'https://github.com/owner/b'])
execFileSync('git', ['-C', foreign, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '--allow-empty', '-m', 'foreign head'])
const head = execFileSync('git', ['-C', foreign, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim()
const latest = structuredClone(plan)
const reassignment = { seq: 1, prev_digest: entry.digest, at: entry.at, reason: 'confirmed lane assignment', plan: latest }
reassignment.digest = chainDigest({ seq: reassignment.seq, plan: latest, at: reassignment.at, reason: reassignment.reason }, entry.digest)
writeFileSync(join(dir, 'plan.json'), JSON.stringify({ schema: 1, slate_id: 'fleet', revisions: [entry, reassignment] }))
const lock = acquireSlateLock({ root, slate: 'fleet', session: 'fleet', create: true })
const runDir = join(root, 'runs/run-1')
mkdirSync(runDir, { recursive: true })
writeFileSync(join(runDir, 'owner-slate'), 'fleet\n')
writeFileSync(join(runDir, 'run.json'), JSON.stringify({ run_id: 'run-1', outcome: null }))
const binding = { version: 1, run_id: 'run-1', branch: 'feat/1', repo: 'owner/b', repo_root: foreign }
writeFileSync(join(runDir, 'branch.json'), JSON.stringify(binding))
assert.equal(runRepository(runDir), foreign)
assert.deepEqual(branchHead(runDir), { branch: 'feat/1', repoRoot: foreign, head })
execFileSync(process.execPath, [join(dirname(writer), 'plan-revise.mjs'), 'handoff', '--slate', 'fleet',
  '--session', 'fleet', '--owner-token', lock.mintedToken, '--issue', '7', '--repo', 'owner/b', '--pr', '123',
  '--reason', 'foreign integration handoff'])
const handedOff = JSON.parse(readFileSync(join(dir, 'plan.json'))).revisions.at(-1).plan
assert.ok(!handedOff.lanes.some((lane) => lane.run_id === 'run-1'))
assert.equal(JSON.parse(readFileSync(join(runDir, 'run.json'))).outcome, null)
assert.equal(runRepository(runDir), foreign)
assert.deepEqual(branchHead(runDir), { branch: 'feat/1', repoRoot: foreign, head })
// A fresh run appears only in retained_lanes, with no older live assignment.
const document = JSON.parse(readFileSync(join(dir, 'plan.json')))
const freshPlan = structuredClone(document.revisions.at(-1).plan)
freshPlan.retained_lanes[0].lane.run_id = 'run-foreign-fresh'
const prior = document.revisions.at(-1)
const freshRevision = { seq: prior.seq + 1, prev_digest: prior.digest, at: prior.at, reason: 'fresh retained fix run', plan: freshPlan }
freshRevision.digest = chainDigest({ seq: freshRevision.seq, plan: freshPlan, at: freshRevision.at, reason: freshRevision.reason }, prior.digest)
document.revisions.push(freshRevision)
writeFileSync(join(dir, 'plan.json'), JSON.stringify(document))
const freshDir = join(root, 'runs/run-foreign-fresh')
mkdirSync(freshDir)
writeFileSync(join(freshDir, 'owner-slate'), 'fleet\n')
writeFileSync(join(freshDir, 'run.json'), JSON.stringify({ run_id: 'run-foreign-fresh', outcome: null }))
writeFileSync(join(freshDir, 'branch.json'), JSON.stringify({ ...binding, run_id: 'run-foreign-fresh' }))
assert.equal(runRepository(freshDir), foreign)
assert.deepEqual(branchHead(freshDir), { branch: 'feat/1', repoRoot: foreign, head })
console.log('PASS: fresh foreign retained run resolves branchHead from retained assignment')
execFileSync('git', ['-C', foreign, 'remote', 'set-url', 'origin', 'https://github.com/owner/wrong'])
assert.throws(() => runRepository(runDir), /origin does not match/)
assert.throws(() => branchHead(runDir), /origin does not match/)
console.log('PASS: foreign runRepository and branchHead retain the latest validated assignment after plan-revise handoff')
MULTI_REPO

no_candidates "suite"
echo "test-run-record: all cases passed"

# Replay the genuine attempt-two authority before later carry captures changed
# the frontier. The retained ruling files and checker surfaces are unchanged.
strict_record="$state/runs/run-integrator/strict-fixture-run.json"
jq --arg digest "$carry_attach_digest" '
  .interventions |= (reduce .[] as $item ([];
    if any(.[]; (.note // "") | contains($digest)) then . else . + [$item] end))
' "$state/runs/run-integrator/run.json" >"$strict_record"
strict_validator="$fixture_support/assets/validate-result-schemas.mjs"
strict_common=(integrator "$carry_pass" --receipt --run-id run-integrator --initiated-by human --known-ids "$tmp/integration-known-ids.json")
strict_record_args=(--integrator-record "$strict_record")
strict_state_args=(--codex-state "$carry_auth_state")
strict_repo_args=(--codex-repo-dir "$repo")
(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" \
    node "$strict_validator" "${strict_common[@]}" "${strict_record_args[@]}" "${strict_state_args[@]}" "${strict_repo_args[@]}") >/dev/null || fail "documented non-null invocation failed"
for missing in record state repo; do
    args=("${strict_common[@]}")
    [[ "$missing" == record ]] || args+=("${strict_record_args[@]}")
    [[ "$missing" == state ]] || args+=("${strict_state_args[@]}")
    [[ "$missing" == repo ]] || args+=("${strict_repo_args[@]}")
    case "$missing" in
    record) flag=--integrator-record ;;
    state) flag=--codex-state ;;
    repo) flag=--codex-repo-dir ;;
    esac
    strict_rc=0
    strict_output="$(cd "$repo" && PATH="$capture_bin:$PATH" CAPTURE_CLEAN=1 CAPTURE_HEAD="$integration_head" CAPTURE_BASE="$capture_base" \
        node "$strict_validator" "${args[@]}" 2>&1)" || strict_rc=$?
    [ "$strict_rc" -eq 2 ] || fail "missing $flag returned $strict_rc: $strict_output"
    grep -Fxq -- "validate-result-schemas: --receipt requires $flag for kind integrator" <<<"$strict_output" || fail "missing $flag was not named: $strict_output"
done
pass "documented strict non-null invocation and missing context"

# Takeover is an authorized append after terminal failure, never a reopen.
(
    repo="$tmp/takeover-repo"
    git init -q -b main "$repo"
    git -C "$repo" remote add origin https://github.com/o/r
    state="$repo/.git/dev-flow-v2"
    new_record run-takeover
    write_plan source 77:run-takeover
    printf 'source\n' >"$state/runs/run-takeover/owner-slate"
    TAKEOVER_RECORD="$state/runs/run-takeover/run.json" PLAN_WRITER="$writer" node --input-type=module <<'NODE'
import { readFileSync, writeFileSync } from 'node:fs'
const { chainDigest } = await import(process.env.PLAN_WRITER)
const file = process.env.TAKEOVER_RECORD
const r = JSON.parse(readFileSync(file))
r.stage_transitions = ['kickoff', 'claim', 'implement', 'verify', 'security', 'integration'].map((stage) => ({stage, entered_at:r.started_at, exit:'tooling blocker'}))
r.pr = {number:42, url:'https://github.com/o/r/pull/42'}
const content = { ...r.pr, bound_at:r.started_at }
r.pr_bindings = [{seq:0, ...content, prev_digest:'genesis', digest:chainDigest(content, 'genesis')}]
const outcome = {outcome:'escalated', at:'2026-01-01T00:01:00Z'}
r.outcome = outcome.outcome
r.outcome_transitions = [{seq:0, ...outcome, prev_digest:'genesis', digest:chainDigest(outcome,'genesis')}]
writeFileSync(file, JSON.stringify(r))
NODE
    original="$tmp/takeover-original.json"
    cp "$state/runs/run-takeover/run.json" "$original"
    acquire recovery bob --issues 77
    tk() {
        (cd "$repo" && node "$writer" "$@" --slate recovery --session bob --owner-token "$(token_for recovery)" --run-id run-takeover --number 42 --url https://github.com/o/r/pull/42)
    }
    expect_refused 'promotion without takeover' 'requires the recorded taking-over' tk takeover-promote --head "$head_sha" --fingerprint fp --gate "$gate_document"
    tk takeover --actor orchestrator-bob --reason 'tooling blocker' --at 2026-01-01T00:02:00Z >/dev/null
    cp "$state/runs/run-takeover/run.json" "$tmp/takeover-started.json"
    tk takeover --actor orchestrator-bob --reason 'tooling blocker' >/dev/null
    cmp -s "$state/runs/run-takeover/run.json" "$tmp/takeover-started.json" || fail 'takeover retry changed history'
    expect_refused 'conflicting reason' 'conflicting takeover retry' tk takeover --actor orchestrator-bob --reason other
    expect_refused 'backdated promotion' 'timestamp must not precede' tk takeover-promote --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:01:30Z
    expect_refused 'wrong gate head' 'same head and fingerprint' tk takeover-promote --head bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --fingerprint fp --gate "$gate_document"
    tk takeover-promote --check --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:03:00Z >/dev/null
    cmp -s "$state/runs/run-takeover/run.json" "$tmp/takeover-started.json" || fail 'takeover precheck wrote state'
    tk takeover-promote --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:03:00Z >/dev/null
    cp "$state/runs/run-takeover/run.json" "$tmp/takeover-promoted.json"
    tk takeover-promote --head "$head_sha" --fingerprint fp --gate "$gate_document" >/dev/null
    cmp -s "$state/runs/run-takeover/run.json" "$tmp/takeover-promoted.json" || fail 'promotion retry changed history'
    expect_refused 'conflicting promotion time' 'conflicting takeover retry' tk takeover-promote --head "$head_sha" --fingerprint fp --gate "$gate_document" --at 2026-01-01T00:04:00Z
    diff -u <(jq -S . "$original") <(jq -S 'del(.takeover_history)' "$state/runs/run-takeover/run.json") || fail 'takeover rewrote original lane record'
    [ "$(cat "$state/runs/run-takeover/owner-slate")" = source ] || fail 'takeover transferred owner-slate'
    cp "$original" "$state/runs/run-takeover/run.json"
    expect_refused 'wrong bound PR' 'bound PR' bash -c 'cd "$1" && node "$2" takeover --slate recovery --session bob --owner-token "$3" --run-id run-takeover --number 99 --url https://github.com/o/r/pull/99 --actor bob --reason blocker' _ "$repo" "$writer" "$(token_for recovery)"
    for outcome in null abandoned ready-for-review capped; do
        # Keep the original record valid while varying the original outcome.
        OUTCOME="$outcome" INPUT="$original" OUTPUT="$state/runs/run-takeover/run.json" PLAN_WRITER="$writer" node --input-type=module <<'NODE'
import {readFileSync,writeFileSync} from 'node:fs'
const {chainDigest}=await import(process.env.PLAN_WRITER)
const r=JSON.parse(readFileSync(process.env.INPUT))
r.outcome=process.env.OUTCOME==='null'?null:process.env.OUTCOME
const c={outcome:r.outcome,at:'2026-01-01T00:01:00Z'}
r.outcome_transitions=r.outcome?[{seq:0,...c,prev_digest:'genesis',digest:chainDigest(c,'genesis')}]:[]
if(r.outcome==='ready-for-review')r.promotion={head:'a'.repeat(40),promoted_at:c.at,gate_fingerprint:'fp'}
writeFileSync(process.env.OUTPUT,JSON.stringify(r))
NODE
        if [ "$outcome" = capped ]; then
            tk takeover --actor bob --reason blocker --at 2026-01-01T00:02:00Z >/dev/null
        else
            expect_refused "ineligible $outcome" 'escalated or capped' tk takeover --actor bob --reason blocker
        fi
    done
    cp "$original" "$state/runs/run-takeover/run.json"
    expect_refused 'wrong owner token' 'token does not match' bash -c 'cd "$1" && node "$2" takeover --slate recovery --session bob --owner-token wrong --run-id run-takeover --number 42 --url https://github.com/o/r/pull/42 --actor bob --reason blocker' _ "$repo" "$writer"
    acquire recovery-other charlie --issues 88
    expect_refused 'unrelated issue scope' 'same qualified issue' bash -c 'cd "$1" && node "$2" takeover --slate recovery-other --session charlie --owner-token "$3" --run-id run-takeover --number 42 --url https://github.com/o/r/pull/42 --actor charlie --reason blocker' _ "$repo" "$writer" "$(token_for recovery-other)"
    expect_refused 'different session' 'locked by session bob' bash -c 'cd "$1" && node "$2" takeover --slate recovery --session eve --owner-token "$3" --run-id run-takeover --number 42 --url https://github.com/o/r/pull/42 --actor eve --reason blocker' _ "$repo" "$writer" "$(token_for recovery)"
    pass 'terminal takeover preserves original history, authorizes owner, binds PR and exact gate, and retries idempotently'
)
