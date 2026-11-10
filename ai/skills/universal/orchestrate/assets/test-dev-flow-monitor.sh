#!/usr/bin/env bash
# ai/skills/universal/orchestrate/assets/test-dev-flow-monitor.sh — regression tests for ai/skills/universal/orchestrate/assets/dev-flow-monitor.sh trust
# contract alignment: integer actor ID comparison, per-reservation governing
# revision resolution, and fail-closed behavior on absent/malformed inputs.
# Refs #780, #741.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR="$SCRIPT_DIR/dev-flow-monitor.sh"

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

pass() {
    echo "  PASS: $1"
    return 0
}

[ -x "$MONITOR" ] || fail "monitor script not found or not executable"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v git >/dev/null 2>&1 || fail "git is required"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

source_root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
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
MONITOR="$tool_root/ai/skills/universal/orchestrate/assets/dev-flow-monitor.sh"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    else
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    fi
}

# ---------------------------------------------------------------------------
# Fixture: create a repo with origin/main carrying agent-registry.json.
# Returns the work repo path in $FIXTURE_REPO and the registry commit in
# $FIXTURE_REV.  The work repo has origin set up so
# refs/remotes/origin/HEAD -> refs/remotes/origin/main.
# ---------------------------------------------------------------------------
fixture_counter=0
setup_fixture() {
    local registry_json="$1"
    fixture_counter=$((fixture_counter + 1))
    local base="$tmp/fixture-$fixture_counter"
    mkdir -p "$base/source"

    git -C "$base/source" init -b main -q
    git -C "$base/source" config user.name "test"
    git -C "$base/source" config user.email "test@test.com"
    printf '%s\n' "$registry_json" >"$base/source/agent-registry.json"
    git -C "$base/source" add agent-registry.json
    git -C "$base/source" commit -q -m "initial registry"

    git clone -q --bare "$base/source" "$base/remote.git"
    git clone -q "$base/remote.git" "$base/work"
    git -C "$base/work" remote set-head origin main
    git -C "$base/work" config user.name "test"
    git -C "$base/work" config user.email "test@test.com"

    FIXTURE_REPO="$base/work"
    FIXTURE_REV="$(git -C "$FIXTURE_REPO" log -1 --format='%H' origin/main -- agent-registry.json)"
    return 0
}

# Monitor tests start with an admitted run; admission itself is tested by provisioning.
admit_run() {
    local repo="$1" run_id="$2" record
    record="$(dirname "$("$MONITOR" state-path --run-id "$run_id" --repo-root "$repo")")/run.json"
    mkdir -p "$(dirname "$record")"
    printf 'fixture\n' >"$(dirname "$record")/owner-slate"
    jq -n --arg run "$run_id" '{schema: 2, run_id: $run, outcome: null,
        dispatch_admission: {slate: "fixture", working: 1, in_flight: 1, at: "2026-01-01T00:00:00Z"}}' >"$record"
}

# Helper: activate a run and return the generation
activate_run() {
    local repo="$1" run_id="$2" branch="$3" rev="$4"
    local active_state
    active_state="$("$MONITOR" active-path --branch "$branch" --repo-root "$repo")"
    admit_run "$repo" "$run_id"
    "$MONITOR" activate --active-state "$active_state" --run-id "$run_id" \
        --branch "$branch" --expected-predecessor absent --expected-generation 0 \
        --registry-revision "$rev" --writer feature-owner --repo-root "$repo"
}

# Helper: attempt a comment reservation (exit code is the test signal)
try_comment_reservation() {
    local repo="$1" run_id="$2" branch="$3" actor_id="$4" event="$5"
    local active_state state head digest
    active_state="$("$MONITOR" active-path --branch "$branch" --repo-root "$repo")"
    state="$("$MONITOR" state-path --run-id "$run_id" --repo-root "$repo")"
    head="$(git -C "$repo" rev-parse HEAD)"
    digest="$(sha256_of "test-body-$event")"
    "$MONITOR" reserve --state "$state" --event "$event" --action comment \
        --expected-head "$head" --writer feature-owner \
        --active-state "$active_state" --run-id "$run_id" \
        --branch "$branch" --generation 1 \
        --trusted-actor-id "$actor_id" --repo-root "$repo" \
        --evidence-role reviewer --evidence-finder codex \
        --marker "marker-$event" --payload-digest "$digest" 2>&1
}

# Helper: update agent-registry.json on origin/main
update_origin_registry() {
    local repo="$1" registry_json="$2"
    local base
    base="$(dirname "$repo")"
    git -C "$base/source" checkout -q main
    printf '%s\n' "$registry_json" >"$base/source/agent-registry.json"
    git -C "$base/source" add agent-registry.json
    git -C "$base/source" commit -q -m "update registry"
    git -C "$base/source" push -q "$base/remote.git" main
    git -C "$repo" fetch -q origin
}

echo "=== ai/skills/universal/orchestrate/assets/dev-flow-monitor.sh trust contract tests ==="

# ── Test 1: Integer allowlist acceptance ──────────────────────────
echo ""
echo "--- Integer allowlist acceptance ---"
setup_fixture '{"trusted_orchestrator_actor_ids": [12345, 67890]}'
activate_run "$FIXTURE_REPO" "run-int-accept" "test-branch" "$FIXTURE_REV" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-int-accept" "test-branch" "12345" "evt-accept")"
grep -q "reserved evt-accept" <<<"$output" ||
    fail "integer actor id 12345 should be accepted; got: $output"
pass "actor id 12345 (integer) accepted from integer allowlist"

# ── Test 2: Untrusted actor rejection ─────────────────────────────
echo ""
echo "--- Untrusted actor rejection ---"
setup_fixture '{"trusted_orchestrator_actor_ids": [12345, 67890]}'
activate_run "$FIXTURE_REPO" "run-reject" "test-branch" "$FIXTURE_REV" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-reject" "test-branch" "99999" "evt-reject" || true)"
grep -q "not trusted" <<<"$output" ||
    fail "actor id 99999 should be rejected; got: $output"
pass "actor id 99999 (not in allowlist) correctly rejected"

# ── Test 3: String allowlist elements are malformed ───────────────
echo ""
echo "--- String allowlist elements rejected (malformed) ---"
setup_fixture '{"trusted_orchestrator_actor_ids": ["12345", "67890"]}'
activate_run "$FIXTURE_REPO" "run-string-reject" "test-branch" "$FIXTURE_REV" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-string-reject" "test-branch" "12345" "evt-string" || true)"
grep -q "not trusted" <<<"$output" ||
    fail "string allowlist should be treated as malformed; got: $output"
pass "allowlist with string elements correctly rejected as malformed"

# ── Test 4: Empty allowlist fails closed ──────────────────────────
echo ""
echo "--- Empty allowlist fails closed ---"
setup_fixture '{"trusted_orchestrator_actor_ids": []}'
activate_run "$FIXTURE_REPO" "run-empty" "test-branch" "$FIXTURE_REV" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-empty" "test-branch" "12345" "evt-empty" || true)"
grep -q "not trusted" <<<"$output" ||
    fail "empty allowlist should fail closed; got: $output"
pass "empty allowlist correctly fails closed"

# ── Test 5: Absent allowlist fails closed ─────────────────────────
echo ""
echo "--- Absent allowlist fails closed ---"
setup_fixture '{}'
activate_run "$FIXTURE_REPO" "run-absent" "test-branch" "$FIXTURE_REV" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-absent" "test-branch" "12345" "evt-absent" || true)"
grep -q "not trusted" <<<"$output" ||
    fail "absent allowlist should fail closed; got: $output"
pass "absent trusted_orchestrator_actor_ids correctly fails closed"

# ── Test 6: Per-write governing revision changes ─────────────────
echo ""
echo "--- Per-write governing revision changes ---"
setup_fixture '{"trusted_orchestrator_actor_ids": [12345]}'
activate_run "$FIXTURE_REPO" "run-rev-change" "test-branch" "$FIXTURE_REV" >/dev/null
rev_before="$FIXTURE_REV"

output="$(try_comment_reservation "$FIXTURE_REPO" "run-rev-change" "test-branch" "12345" "evt-rev1")"
grep -q "reserved evt-rev1" <<<"$output" ||
    fail "first reservation should succeed; got: $output"
pass "reservation 1 accepted with governing revision $rev_before"

update_origin_registry "$FIXTURE_REPO" '{"trusted_orchestrator_actor_ids": [67890]}'
rev_after="$(git -C "$FIXTURE_REPO" log -1 --format='%H' origin/main -- agent-registry.json)"
[ "$rev_before" != "$rev_after" ] ||
    fail "registry revision should have changed after update"

output="$(try_comment_reservation "$FIXTURE_REPO" "run-rev-change" "test-branch" "12345" "evt-rev2" || true)"
grep -q "not trusted" <<<"$output" ||
    fail "actor 12345 should be rejected after registry update removed it; got: $output"
pass "reservation 2 correctly uses updated governing revision (actor removed)"

output="$(try_comment_reservation "$FIXTURE_REPO" "run-rev-change" "test-branch" "67890" "evt-rev3")"
grep -q "reserved evt-rev3" <<<"$output" ||
    fail "actor 67890 should be accepted after registry update added it; got: $output"
pass "reservation 3 accepted with new governing revision (actor added)"

# Verify the recorded governing revision in the reservation matches the new one
state="$("$MONITOR" state-path --run-id "run-rev-change" --repo-root "$FIXTURE_REPO")"
recorded_rev="$(jq -r '.actions[] | select(.event == "evt-rev3") | .comment_auth.registry_revision' "$state")"
[ "$recorded_rev" = "$rev_after" ] ||
    fail "recorded registry_revision should be the governing revision ($rev_after), got: $recorded_rev"
pass "reservation records the per-write governing revision, not the activation-time one"

# ── Test 7: Unresolvable governing revision (no registry on default branch) ──
echo ""
echo "--- Unresolvable governing revision ---"
fixture_counter=$((fixture_counter + 1))
base="$tmp/fixture-$fixture_counter"
mkdir -p "$base/source"
git -C "$base/source" init -b main -q
git -C "$base/source" config user.name "test"
git -C "$base/source" config user.email "test@test.com"
echo "placeholder" >"$base/source/README.md"
git -C "$base/source" add README.md
git -C "$base/source" commit -q -m "initial (no registry)"
git clone -q --bare "$base/source" "$base/remote.git"
git clone -q "$base/remote.git" "$base/work"
git -C "$base/work" remote set-head origin main
FIXTURE_REPO="$base/work"

kickoff_rev="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
# Activation still needs a valid registry revision — use a fake one that the
# activate command will accept by putting a registry file in the local repo only
printf '{"trusted_orchestrator_actor_ids": [12345]}' >"$FIXTURE_REPO/agent-registry.json"
git -C "$FIXTURE_REPO" add agent-registry.json
git -C "$FIXTURE_REPO" -c user.name='test' -c user.email='test@test.com' \
    commit -q -m "local-only registry"
local_rev="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
activate_run "$FIXTURE_REPO" "run-no-origin-reg" "test-branch" "$local_rev" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-no-origin-reg" "test-branch" "12345" "evt-no-reg" || true)"
grep -q "no agent-registry.json revision found" <<<"$output" ||
    fail "should fail when no registry on default branch; got: $output"
pass "correctly fails closed when no agent-registry.json exists on origin/main"

# ── Test 8: Float in allowlist is malformed ───────────────────────
echo ""
echo "--- Float in allowlist rejected (malformed) ---"
setup_fixture '{"trusted_orchestrator_actor_ids": [12345.5, 67890]}'
activate_run "$FIXTURE_REPO" "run-float" "test-branch" "$FIXTURE_REV" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-float" "test-branch" "67890" "evt-float" || true)"
grep -q "not trusted" <<<"$output" ||
    fail "float in allowlist should be malformed; got: $output"
pass "allowlist containing a float correctly rejected as malformed"

# ── Test 9: Zero in allowlist is malformed ────────────────────────
echo ""
echo "--- Zero in allowlist rejected (malformed) ---"
setup_fixture '{"trusted_orchestrator_actor_ids": [0, 67890]}'
activate_run "$FIXTURE_REPO" "run-zero" "test-branch" "$FIXTURE_REV" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-zero" "test-branch" "67890" "evt-zero" || true)"
grep -q "not trusted" <<<"$output" ||
    fail "zero in allowlist should be malformed; got: $output"
pass "allowlist containing zero correctly rejected as malformed"

# ── Test 10: orchestrator-dir resolves under the common directory ──
echo ""
echo "--- orchestrator-dir names the per-run, per-attempt directory ---"
setup_fixture '{"trusted_orchestrator_actor_ids": [12345]}'
git -C "$FIXTURE_REPO" worktree add -q "$FIXTURE_REPO-lane" -b lane-dir
common="$(git -C "$FIXTURE_REPO" rev-parse --path-format=absolute --git-common-dir)"
dir="$("$MONITOR" orchestrator-dir --slate-id epic-1 --run-id run-x --nonce a1 --repo-root "$FIXTURE_REPO-lane")"
[ "$dir" = "$common/dev-flow-v2/slates/epic-1/orchestrator/run-x/a1" ] ||
    fail "orchestrator-dir from a linked worktree: got $dir"
if "$MONITOR" orchestrator-dir --slate-id ../x --run-id run-x --nonce a1 --repo-root "$FIXTURE_REPO" 2>/dev/null; then
    fail "orchestrator-dir accepted an unsafe slate id"
fi
if "$MONITOR" orchestrator-dir --slate-id epic-1 --run-id run-x --repo-root "$FIXTURE_REPO" 2>/dev/null; then
    fail "orchestrator-dir accepted a missing nonce"
fi
pass "orchestrator-dir resolves the common directory and refuses unsafe or missing keys"

# Unlocked/concurrent callers retain duplicate-event refusal. The full helper
# test exercises a lock-holder resume and overlapping serialized callers.
setup_fixture '{"trusted_orchestrator_actor_ids": [12345]}'
activate_run "$FIXTURE_REPO" "run-rearm" "test-branch" "$FIXTURE_REV" >/dev/null
try_comment_reservation "$FIXTURE_REPO" "run-rearm" "test-branch" "12345" "evt-rearm" >/dev/null
output="$(try_comment_reservation "$FIXTURE_REPO" "run-rearm" "test-branch" "12345" "evt-rearm" || true)"
grep -q 'duplicate event' <<<"$output" || fail "unlocked re-arm did not refuse a duplicate event"
state="$("$MONITOR" state-path --run-id run-rearm --repo-root "$FIXTURE_REPO")"
[ "$(jq '.actions | length' "$state")" -eq 1 ] || fail "exact re-arm duplicated reservation"
output="$(try_comment_reservation "$FIXTURE_REPO" "run-rearm" "test-branch" "12345" "evt-other" || true)"
# A different event has a different marker and is a distinct reservation.
grep -q 'reserved evt-other' <<<"$output" || fail "distinct marker did not reserve"
update_origin_registry "$FIXTURE_REPO" '{"trusted_orchestrator_actor_ids": [67890]}'
output="$(try_comment_reservation "$FIXTURE_REPO" "run-rearm" "test-branch" "12345" "evt-rearm" || true)"
grep -q 'not trusted' <<<"$output" || fail "re-arm trusted a removed actor"
pass "unlocked re-arm refuses duplicate events and rechecks the governing allowlist"

# ── Active-pointer retirement ----------------------------------------------
echo ""
echo "--- Active-pointer retirement is run-bound and reservation-aware ---"
setup_fixture '{"trusted_orchestrator_actor_ids": [12345]}'
activate_run "$FIXTURE_REPO" "run-retire" "retire-branch" "$FIXTURE_REV" >/dev/null
retire_pointer="$("$MONITOR" active-path --branch retire-branch --repo-root "$FIXTURE_REPO")"
retire_record="$(dirname "$("$MONITOR" state-path --run-id run-retire --repo-root "$FIXTURE_REPO")")/run.json"
mkdir -p "$(dirname "$retire_record")"
jq -n '{schema: 2, run_id: "run-retire", outcome: "abandoned"}' >"$retire_record"
output="$("$MONITOR" retire --run-id run-retire --repo-root "$FIXTURE_REPO")"
grep -qF 'retired run run-retire active pointer' <<<"$output" || fail "matching run pointer was not retired: $output"
[ ! -e "$retire_pointer" ] || fail "retire left the matching pointer behind"
race_output=""
race_rc=0
admit_run "$FIXTURE_REPO" run-retire-race
race_output="$("$MONITOR" activate --active-state "$retire_pointer" --run-id run-retire-race \
    --branch retire-branch --expected-predecessor run-retire --expected-generation 1 \
    --registry-revision "$FIXTURE_REV" \
    --writer feature-owner --repo-root "$FIXTURE_REPO" 2>&1)" || race_rc=$?
[ "$race_rc" -eq 2 ] || fail "stale activation after pointer retirement was not refused: $race_output"
grep -qF 'concurrently retired; retry activation' <<<"$race_output" ||
    fail "stale activation did not explain the safe retry: $race_output"
output="$("$MONITOR" retire --run-id run-retire --repo-root "$FIXTURE_REPO")"
grep -qF 'nothing of this run to retire' <<<"$output" ||
    fail "retiring a run with an absent pointer did not report a successful no-op: $output"
replay_rc=0
replay_output="$("$MONITOR" activate --active-state "$retire_pointer" --run-id run-retire \
    --branch retire-branch --expected-predecessor absent --expected-generation 0 \
    --registry-revision "$FIXTURE_REV" --writer feature-owner --repo-root "$FIXTURE_REPO" 2>&1)" || replay_rc=$?
[ "$replay_rc" -eq 2 ] || fail "activation replayed an ended run after retirement: $replay_output"
grep -qF 'target run run-retire has already ended' <<<"$replay_output" ||
    fail "ended-run activation refusal was unclear: $replay_output"
[ ! -e "$retire_pointer" ] || fail "refused ended-run replay recreated the active pointer"
pass "activation refuses replay of the original request after its ended run was retired"
generation="$(activate_run "$FIXTURE_REPO" run-retire-next retire-branch "$FIXTURE_REV")"
[ "$generation" = 1 ] || fail "a new run on the retired branch did not restart at generation 1: $generation"
next_retire_record="$(dirname "$("$MONITOR" state-path --run-id run-retire-next --repo-root "$FIXTURE_REPO")")/run.json"
jq -n '{schema: 2, run_id: "run-retire-next", outcome: "capped"}' >"$next_retire_record"
"$MONITOR" retire --run-id run-retire-next --repo-root "$FIXTURE_REPO" >/dev/null
replay_rc=0
replay_output="$("$MONITOR" activate --active-state "$retire_pointer" --run-id run-retire \
    --branch retire-branch --expected-predecessor absent --expected-generation 0 \
    --registry-revision "$FIXTURE_REV" --writer feature-owner --repo-root "$FIXTURE_REPO" 2>&1)" || replay_rc=$?
[ "$replay_rc" -eq 2 ] || fail "activation replayed an ended run after an intervening run ended and retired: $replay_output"
[ ! -e "$retire_pointer" ] || fail "intervening-run replay recreated the active pointer"
pass "activation refuses an ended run's original request after an intervening run also ended and retired"
# Admission is bound to the owner slate, with the existing solo exemption.
for admission_case in mismatch missing admitted solo; do
    admission_run="run-admission-$admission_case"
    admission_branch="admission-$admission_case"
    admit_run "$FIXTURE_REPO" "$admission_run"
    admission_dir="$(dirname "$("$MONITOR" state-path --run-id "$admission_run" --repo-root "$FIXTURE_REPO")")"
    case "$admission_case" in
    mismatch) printf 'other\n' >"$admission_dir/owner-slate" ;;
    missing) rm "$admission_dir/owner-slate" ;;
    solo)
        printf 'solo-%s\n' "$admission_run" >"$admission_dir/owner-slate"
        jq 'del(.dispatch_admission)' "$admission_dir/run.json" >"$admission_dir/new.json"
        mv "$admission_dir/new.json" "$admission_dir/run.json"
        ;;
    esac
    admission_pointer="$("$MONITOR" active-path --branch "$admission_branch" --repo-root "$FIXTURE_REPO")"
    admission_rc=0
    admission_output="$("$MONITOR" activate --active-state "$admission_pointer" --run-id "$admission_run" \
        --branch "$admission_branch" --expected-predecessor absent --expected-generation 0 \
        --registry-revision "$FIXTURE_REV" --writer feature-owner --repo-root "$FIXTURE_REPO" 2>&1)" || admission_rc=$?
    case "$admission_case" in
    mismatch | missing)
        [ "$admission_rc" -eq 2 ] || fail "$admission_case owner slate accepted: $admission_output"
        grep -qF 'activation refused:' <<<"$admission_output" || fail "unclear refusal: $admission_output"
        [ ! -e "$admission_pointer" ] || fail "$admission_case wrote an active pointer"
        ;;
    *) [ "$admission_rc" -eq 0 ] && [ "$admission_output" = 1 ] || fail "$admission_case activation failed: $admission_output" ;;
    esac
    pass "activation admission: $admission_case"
done
# A legacy active generation must refuse re-arm with an actionable migration.
legacy_run=run-admission-legacy
legacy_branch=admission-legacy
admit_run "$FIXTURE_REPO" "$legacy_run"
legacy_dir="$(dirname "$("$MONITOR" state-path --run-id "$legacy_run" --repo-root "$FIXTURE_REPO")")"
legacy_pointer="$("$MONITOR" active-path --branch "$legacy_branch" --repo-root "$FIXTURE_REPO")"
"$MONITOR" activate --active-state "$legacy_pointer" --run-id "$legacy_run" --branch "$legacy_branch" \
    --expected-predecessor absent --expected-generation 0 --registry-revision "$FIXTURE_REV" \
    --writer feature-owner --repo-root "$FIXTURE_REPO" >/dev/null
rearm_output="$("$MONITOR" activate --active-state "$legacy_pointer" --run-id "$legacy_run" --branch "$legacy_branch" \
    --expected-predecessor absent --expected-generation 0 --registry-revision "$FIXTURE_REV" \
    --writer feature-owner --repo-root "$FIXTURE_REPO" 2>&1)" || fail "admitted re-arm failed: $rearm_output"
[ "$rearm_output" = 1 ] || fail "admitted re-arm changed generation: $rearm_output"
pass "admitted active generation can re-arm"
jq 'del(.dispatch_admission)' "$legacy_dir/run.json" >"$legacy_dir/new.json"
mv "$legacy_dir/new.json" "$legacy_dir/run.json"
legacy_rc=0
legacy_output="$("$MONITOR" activate --active-state "$legacy_pointer" --run-id "$legacy_run" --branch "$legacy_branch" \
    --expected-predecessor absent --expected-generation 0 --registry-revision "$FIXTURE_REV" \
    --writer feature-owner --repo-root "$FIXTURE_REPO" 2>&1)" || legacy_rc=$?
[ "$legacy_rc" -eq 2 ] || fail "legacy re-arm unexpectedly succeeded: $legacy_output"
grep -qF 'retire the legacy run (reconcile its events and prune its active pointer if required), then provision a replacement run' <<<"$legacy_output" || fail "legacy migration missing: $legacy_output"
pass "legacy active generation refuses re-arm with migration guidance"
ended_target=run-activate-ended
ended_record="$(dirname "$("$MONITOR" state-path --run-id "$ended_target" --repo-root "$FIXTURE_REPO")")/run.json"
mkdir -p "$(dirname "$ended_record")"
jq -n --arg run "$ended_target" '{schema: 2, run_id: $run, outcome: "abandoned"}' >"$ended_record"
ended_pointer="$("$MONITOR" active-path --branch ended-target-branch --repo-root "$FIXTURE_REPO")"
ended_rc=0
ended_output="$("$MONITOR" activate --active-state "$ended_pointer" --run-id "$ended_target" \
    --branch ended-target-branch --expected-predecessor absent --expected-generation 0 \
    --registry-revision "$FIXTURE_REV" --writer feature-owner --repo-root "$FIXTURE_REPO" 2>&1)" || ended_rc=$?
[ "$ended_rc" -eq 2 ] || fail "activation accepted an already-ended unbound target: $ended_output"
[ ! -e "$(dirname "$ended_record")/branch.json" ] || fail "ended target activation wrote a branch binding before refusal"
[ ! -e "$ended_pointer" ] || fail "ended target activation wrote an active pointer before refusal"
pass "activation refuses ended target runs before writing their branch binding"
invalid_target=run-activate-invalid
invalid_record="$(dirname "$("$MONITOR" state-path --run-id "$invalid_target" --repo-root "$FIXTURE_REPO")")/run.json"
mkdir -p "$(dirname "$invalid_record")"
jq -n --arg run "$invalid_target" '{schema: 1, run_id: $run, outcome: null}' >"$invalid_record"
invalid_pointer="$("$MONITOR" active-path --branch invalid-target-branch --repo-root "$FIXTURE_REPO")"
invalid_rc=0
invalid_output="$("$MONITOR" activate --active-state "$invalid_pointer" --run-id "$invalid_target" \
    --branch invalid-target-branch --expected-predecessor absent --expected-generation 0 \
    --registry-revision "$FIXTURE_REV" --writer feature-owner --repo-root "$FIXTURE_REPO" 2>&1)" || invalid_rc=$?
[ "$invalid_rc" -eq 2 ] || fail "activation accepted an invalid target run.json: $invalid_output"
grep -qF 'activation refused: run record is invalid' <<<"$invalid_output" ||
    fail "invalid target run refusal was inaccurate: $invalid_output"
! grep -qF 'still open' <<<"$invalid_output" || fail "invalid target run refusal incorrectly described it as open"
[ ! -e "$(dirname "$invalid_record")/branch.json" ] || fail "invalid target activation wrote a branch binding before refusal"
[ ! -e "$invalid_pointer" ] || fail "invalid target activation wrote an active pointer before refusal"
pass "activation describes an invalid target run record accurately"
pass "retirement deletes only a validated terminal pointer; fresh activation starts at generation 1 and stale activation explains a safe retry"

echo "--- Activation compares predecessor identity across a generation restart ---"
aba_branch="aba-branch"
activate_run "$FIXTURE_REPO" run-aba-a "$aba_branch" "$FIXTURE_REV" >/dev/null
aba_pointer="$("$MONITOR" active-path --branch "$aba_branch" --repo-root "$FIXTURE_REPO")"
aba_old_record="$(dirname "$("$MONITOR" state-path --run-id run-aba-a --repo-root "$FIXTURE_REPO")")/run.json"
jq -n '{schema: 2, run_id: "run-aba-a", outcome: "abandoned"}' >"$aba_old_record"
"$MONITOR" retire --run-id run-aba-a --repo-root "$FIXTURE_REPO" >/dev/null
[ "$(activate_run "$FIXTURE_REPO" run-aba-b "$aba_branch" "$FIXTURE_REV")" = 1 ] ||
    fail "replacement run did not restart at generation 1"
aba_live_record="$(dirname "$("$MONITOR" state-path --run-id run-aba-b --repo-root "$FIXTURE_REPO")")/run.json"
jq -n '{schema: 2, run_id: "run-aba-b", outcome: null}' >"$aba_live_record"
aba_rc=0
admit_run "$FIXTURE_REPO" run-aba-c
aba_output="$("$MONITOR" activate --active-state "$aba_pointer" --run-id run-aba-c --branch "$aba_branch" \
    --expected-predecessor run-aba-a --expected-generation 1 --registry-revision "$FIXTURE_REV" \
    --writer feature-owner --repo-root "$FIXTURE_REPO" 2>&1)" || aba_rc=$?
[ "$aba_rc" -eq 2 ] || fail "stale activation replaced a new generation-1 run: $aba_output"
grep -qF 'predecessor changed' <<<"$aba_output" || fail "ABA refusal did not name the predecessor mismatch: $aba_output"
jq -e '.run_id == "run-aba-b" and .generation == 1' "$aba_pointer" >/dev/null ||
    fail "stale activation changed the replacement pointer"
aba_state="$("$MONITOR" state-path --run-id run-aba-b --repo-root "$FIXTURE_REPO")"
"$MONITOR" reserve --state "$aba_state" --event still-live --action push --expected-head "$FIXTURE_REV" \
    --writer feature-owner --active-state "$aba_pointer" --run-id run-aba-b --branch "$aba_branch" \
    --generation 1 --repo-root "$FIXTURE_REPO" >/dev/null || fail "replacement run became unusable after stale activation"
aba_stale_state="$("$MONITOR" state-path --run-id run-aba-c --repo-root "$FIXTURE_REPO")"
[ ! -e "$(dirname "$aba_stale_state")/branch.json" ] || fail "refused stale activation left a branch binding behind"
pass "stale generation-1 activation is refused without replacing or damaging the live predecessor"

activate_run "$FIXTURE_REPO" run-retire-old replace-branch "$FIXTURE_REV" >/dev/null
replace_pointer="$("$MONITOR" active-path --branch replace-branch --repo-root "$FIXTURE_REPO")"
admit_run "$FIXTURE_REPO" run-retire-new
"$MONITOR" activate --active-state "$replace_pointer" --run-id run-retire-new \
    --branch replace-branch --expected-predecessor run-retire-old --expected-generation 1 \
    --registry-revision "$FIXTURE_REV" \
    --writer feature-owner --repo-root "$FIXTURE_REPO" >/dev/null
retire_rc=0
output="$("$MONITOR" retire --run-id run-retire-old --repo-root "$FIXTURE_REPO" 2>&1)" || retire_rc=$?
[ "$retire_rc" -eq 0 ] || fail "retire did not treat a superseded pointer as a no-op: $output"
grep -qF 'nothing of this run to retire' <<<"$output" || fail "retire did not report that nothing remains for the old run: $output"
[ "$(jq -r '.run_id' "$replace_pointer")" = run-retire-new ] || fail "retire deleted a pointer owned by a different run"
pass "retire treats a pointer owned by a newer run as a successful no-op"

activate_run "$FIXTURE_REPO" run-retire-open open-retire-branch "$FIXTURE_REV" >/dev/null
open_retire_pointer="$("$MONITOR" active-path --branch open-retire-branch --repo-root "$FIXTURE_REPO")"
open_retire_record="$(dirname "$("$MONITOR" state-path --run-id run-retire-open --repo-root "$FIXTURE_REPO")")/run.json"
mkdir -p "$(dirname "$open_retire_record")"
jq -n '{schema: 2, run_id: "run-retire-open", outcome: null}' >"$open_retire_record"
retire_rc=0
output="$("$MONITOR" retire --run-id run-retire-open --repo-root "$FIXTURE_REPO" 2>&1)" || retire_rc=$?
[ "$retire_rc" -eq 2 ] || fail "retire did not refuse an open run: $output"
grep -qF 'run record is invalid or still open' <<<"$output" || fail "open-run refusal was unclear: $output"
[ -f "$open_retire_pointer" ] || fail "refused retirement removed an open run's pointer"

activate_run "$FIXTURE_REPO" run-retire-missing missing-retire-branch "$FIXTURE_REV" >/dev/null
rm "$(dirname "$("$MONITOR" state-path --run-id run-retire-missing --repo-root "$FIXTURE_REPO")")/run.json"
missing_retire_pointer="$("$MONITOR" active-path --branch missing-retire-branch --repo-root "$FIXTURE_REPO")"
retire_rc=0
output="$("$MONITOR" retire --run-id run-retire-missing --repo-root "$FIXTURE_REPO" 2>&1)" || retire_rc=$?
[ "$retire_rc" -eq 2 ] || fail "retire did not refuse a missing run.json: $output"
grep -qF 'run record is missing' <<<"$output" || fail "missing-run refusal was unclear: $output"
[ -f "$missing_retire_pointer" ] || fail "refused retirement removed a pointer with no run.json"
pass "retire shares prune eligibility and refuses open and missing run records"

activate_run "$FIXTURE_REPO" run-retire-reserved reserved-branch "$FIXTURE_REV" >/dev/null
reserved_pointer="$("$MONITOR" active-path --branch reserved-branch --repo-root "$FIXTURE_REPO")"
reserved_state="$("$MONITOR" state-path --run-id run-retire-reserved --repo-root "$FIXTURE_REPO")"
reserved_head="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
"$MONITOR" reserve --state "$reserved_state" --event evt --action push \
    --expected-head "$reserved_head" --writer feature-owner \
    --active-state "$reserved_pointer" --run-id run-retire-reserved \
    --branch reserved-branch --generation 1 --repo-root "$FIXTURE_REPO" >/dev/null
reserved_record="$(dirname "$reserved_state")/run.json"
jq -n --arg run run-retire-reserved '{schema: 2, run_id: $run, outcome: "abandoned"}' >"$reserved_record"
retire_rc=0
output="$("$MONITOR" retire --run-id run-retire-reserved --repo-root "$FIXTURE_REPO" 2>&1)" || retire_rc=$?
[ "$retire_rc" -eq 2 ] || fail "retire did not refuse the unreconciled reservation: $output"
grep -qF 'monitor.json has an unreconciled reserved action' <<<"$output" ||
    fail "unreconciled reservation did not defer retirement: $output"
[ -f "$reserved_pointer" ] || fail "retire deleted a pointer with an unreconciled reservation"
activation_rc=0
admit_run "$FIXTURE_REPO" run-retire-next-reserved
activation_output="$("$MONITOR" activate --active-state "$reserved_pointer" --run-id run-retire-next-reserved \
    --branch reserved-branch --expected-predecessor run-retire-reserved --expected-generation 1 \
    --registry-revision "$FIXTURE_REV" \
    --writer feature-owner --repo-root "$FIXTURE_REPO" 2>&1)" || activation_rc=$?
[ "$activation_rc" -eq 2 ] || fail "activation was not refused while the ended run had a reserved action: $activation_output"
grep -qF 'run-retire-reserved' <<<"$activation_output" || fail "activation refusal omitted the ended run id: $activation_output"
grep -qF 'evt' <<<"$activation_output" || fail "activation refusal omitted the reservation event id: $activation_output"
grep -qF 'reconcile' <<<"$activation_output" || fail "activation refusal omitted the reconciliation remedy: $activation_output"
grep -qF 'cancel --state' <<<"$activation_output" || fail "activation refusal omitted the cancellation remedy: $activation_output"
grep -qF 'retire' <<<"$activation_output" || fail "activation refusal omitted the retirement remedy: $activation_output"
grep -qF 'prune' <<<"$activation_output" || fail "activation refusal omitted the prune remedy: $activation_output"
[ "$(jq -r '.run_id' "$reserved_pointer")" = run-retire-reserved ] || fail "refused activation replaced the old active pointer"
observed="$tmp/reserved-observed.json"
jq -n --arg event evt --arg head "$reserved_head" \
    '{status: "landed", event: $event, action: "push", head: $head}' \
    >"$tmp/reserved-landed.json"
cancel_rc=0
cancel_output="$("$MONITOR" cancel --state "$reserved_state" --run-id run-retire-reserved --event evt \
    --observed "$tmp/reserved-landed.json" --reason 'operator checked the action' --repo-root "$FIXTURE_REPO" 2>&1)" || cancel_rc=$?
[ "$cancel_rc" -eq 2 ] || fail "cancel accepted an action observed landed: $cancel_output"
grep -qF 'observed landed; use reconcile' <<<"$cancel_output" || fail "landed cancellation refusal was unclear: $cancel_output"
jq -n --arg event evt --arg head "$reserved_head" \
    '{status: "absent", event: $event, action: "push", head: $head}' >"$observed"
jq -n '{status: "absent"}' >"$tmp/unbound-absent.json"
unbound_rc=0
unbound_output="$("$MONITOR" cancel --state "$reserved_state" --run-id run-retire-reserved --event evt \
    --observed "$tmp/unbound-absent.json" --reason 'unbound observation' --repo-root "$FIXTURE_REPO" 2>&1)" || unbound_rc=$?
[ "$unbound_rc" -eq 2 ] || fail "cancel accepted an unbound absent observation: $unbound_output"
grep -qF 'not bound to reservation event, action, and expected head' <<<"$unbound_output" ||
    fail "cancel did not report the unbound observation: $unbound_output"
jq -e '.actions[0].state == "reserved"' "$reserved_state" >/dev/null ||
    fail "refused unbound cancellation changed the reservation"
unbound_rc=0
unbound_output="$("$MONITOR" reconcile --state "$reserved_state" --event evt --observed "$tmp/unbound-absent.json" \
    --active-state "$reserved_pointer" --run-id run-retire-reserved --branch reserved-branch \
    --generation 1 --repo-root "$FIXTURE_REPO" 2>&1)" || unbound_rc=$?
[ "$unbound_rc" -eq 2 ] || fail "reconcile accepted an unbound absent observation: $unbound_output"
retry_output="$("$MONITOR" reconcile --state "$reserved_state" --event evt --observed "$observed" \
    --active-state "$reserved_pointer" --run-id run-retire-reserved --branch reserved-branch \
    --generation 1 --repo-root "$FIXTURE_REPO")"
grep -qF 'retry evt' <<<"$retry_output" ||
    fail "absent reconciliation did not authorize an explicit retry"
cancel_output="$("$MONITOR" cancel --state "$reserved_state" --run-id run-retire-reserved --event evt \
    --observed "$observed" --reason 'push was never sent after operator inspection' --repo-root "$FIXTURE_REPO")"
grep -qF 'cancelled reservation evt' <<<"$cancel_output" || fail "cancel did not record the absent action: $cancel_output"
jq -e --arg head "$reserved_head" '.actions[0].state == "cancelled" and
    .actions[0].cancellation.reason == "push was never sent after operator inspection" and
    .actions[0].cancellation.observation.status == "absent" and
    .actions[0].cancellation.observation.event == "evt" and
    .actions[0].cancellation.observation.action == "push" and
    .actions[0].cancellation.observation.head == $head' \
    "$reserved_state" >/dev/null || fail "cancel did not persist its reason"
"$MONITOR" retire --run-id run-retire-reserved --repo-root "$FIXTURE_REPO" >/dev/null
[ ! -e "$reserved_pointer" ] || fail "retirement did not resume after reservation reconciliation"
generation="$(activate_run "$FIXTURE_REPO" run-retire-next-reserved reserved-branch "$FIXTURE_REV")"
[ "$generation" = 1 ] || fail "activation did not succeed at generation 1 after reconciliation and retirement: $generation"
pass "an absent ended reservation can be cancelled durably, then retired before a fresh activation"

activate_run "$FIXTURE_REPO" run-retire-eventless eventless-branch "$FIXTURE_REV" >/dev/null
eventless_pointer="$("$MONITOR" active-path --branch eventless-branch --repo-root "$FIXTURE_REPO")"
eventless_state="$("$MONITOR" state-path --run-id run-retire-eventless --repo-root "$FIXTURE_REPO")"
eventless_record="$(dirname "$eventless_state")/run.json"
jq -n '{schema: 2, run_id: "run-retire-eventless", outcome: "capped"}' >"$eventless_record"
jq -n '{version: 1, cursor: null, actions: [
    {action: "push", state: "reserved"},
    {event: "", action: "comment", state: "reserved"}
]}' >"$eventless_state"
eventless_retire_rc=0
eventless_retire_output="$("$MONITOR" retire --run-id run-retire-eventless --repo-root "$FIXTURE_REPO" 2>&1)" ||
    eventless_retire_rc=$?
[ "$eventless_retire_rc" -eq 2 ] || fail "retire ignored a reserved action with no event name: $eventless_retire_output"
grep -qF 'unreconciled reserved action' <<<"$eventless_retire_output" ||
    fail "eventless reservation did not defer retirement: $eventless_retire_output"
eventless_activate_rc=0
admit_run "$FIXTURE_REPO" run-eventless-next
eventless_activate_output="$("$MONITOR" activate --active-state "$eventless_pointer" --run-id run-eventless-next \
    --branch eventless-branch --expected-predecessor run-retire-eventless --expected-generation 1 \
    --registry-revision "$FIXTURE_REV" --writer feature-owner --repo-root "$FIXTURE_REPO" 2>&1)" ||
    eventless_activate_rc=$?
[ "$eventless_activate_rc" -eq 2 ] || fail "activation ignored eventless reserved actions: $eventless_activate_output"
grep -qF '2 unreconciled reserved action(s)' <<<"$eventless_activate_output" ||
    fail "activation did not count eventless reservations: $eventless_activate_output"
grep -qF '["<missing event>","<missing event>"]' <<<"$eventless_activate_output" ||
    fail "activation did not identify missing reservation events: $eventless_activate_output"
eventless_prune_output="$("$MONITOR" prune --dry-run --repo-root "$FIXTURE_REPO")"
grep -qF "prune: skipped ${eventless_pointer##*/}: monitor.json has an unreconciled reserved action" \
    <<<"$eventless_prune_output" || fail "prune ignored eventless reserved actions: $eventless_prune_output"
[ -f "$eventless_pointer" ] || fail "eventless reservations did not preserve the active pointer"
pass "missing and empty reservation event names still block activation, retirement, and pruning"

activate_run "$FIXTURE_REPO" run-cancel-live live-cancel-branch "$FIXTURE_REV" >/dev/null
live_cancel_pointer="$("$MONITOR" active-path --branch live-cancel-branch --repo-root "$FIXTURE_REPO")"
live_cancel_state="$("$MONITOR" state-path --run-id run-cancel-live --repo-root "$FIXTURE_REPO")"
live_cancel_head="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
"$MONITOR" reserve --state "$live_cancel_state" --event evt-live-cancel --action push \
    --expected-head "$live_cancel_head" --writer feature-owner --active-state "$live_cancel_pointer" \
    --run-id run-cancel-live --branch live-cancel-branch --generation 1 --repo-root "$FIXTURE_REPO" >/dev/null
live_cancel_record="$(dirname "$live_cancel_state")/run.json"
jq -n '{schema: 2, run_id: "run-cancel-live", outcome: null}' >"$live_cancel_record"
jq -n --arg event evt-live-cancel --arg head "$live_cancel_head" \
    '{status: "absent", event: $event, action: "push", head: $head}' >"$tmp/live-cancel-observed.json"
cancel_rc=0
cancel_output="$("$MONITOR" cancel --state "$live_cancel_state" --run-id run-cancel-live --event evt-live-cancel \
    --observed "$tmp/live-cancel-observed.json" --reason 'fixture cancellation attempt' --repo-root "$FIXTURE_REPO" 2>&1)" || cancel_rc=$?
[ "$cancel_rc" -eq 2 ] || fail "cancel accepted a live run: $cancel_output"
grep -qF 'run run-cancel-live is live' <<<"$cancel_output" || fail "live cancellation refusal was unclear: $cancel_output"
jq -e '.actions[0].state == "reserved"' "$live_cancel_state" >/dev/null ||
    fail "refused cancellation changed the live reservation"
pass "cancel refuses a live run without changing its reservation"

# Use the actual pointer branch, keeping the negative identity tests explicit.
live_cancel_identity=(--writer feature-owner --active-state "$live_cancel_pointer"
    --branch "$(jq -r .branch "$live_cancel_pointer")" --generation 1)
for bad_generation in 2 0; do
    cancel_rc=0
    "$MONITOR" cancel --state "$live_cancel_state" --run-id run-cancel-live --event evt-live-cancel \
        --writer feature-owner --active-state "$live_cancel_pointer" \
        --branch "$(jq -r .branch "$live_cancel_pointer")" --generation "$bad_generation" \
        --observed "$tmp/live-cancel-observed.json" --reason 'stale caller' --repo-root "$FIXTURE_REPO" \
        >"$tmp/live-cancel-error" 2>&1 || cancel_rc=$?
    [ "$cancel_rc" -eq 2 ] || fail "live cancellation accepted a stale/invalid generation"
done
"$MONITOR" cancel --state "$live_cancel_state" --run-id run-cancel-live --event evt-live-cancel \
    "${live_cancel_identity[@]}" --observed "$tmp/live-cancel-observed.json" \
    --reason 'owner observed absent push' --repo-root "$FIXTURE_REPO" >/dev/null
jq -e '.actions[0].state == "cancelled" and .actions[0].cancellation.observation.status == "absent"' \
    "$live_cancel_state" >/dev/null || fail "live owner cancellation was not recorded"
pass "live push cancellation requires matching active generation and records absence"
printf '%s\n' '{"integrated_lanes":["a"],"discarded_lanes":[]}' >"$tmp/live-assembly.json"
"$MONITOR" reserve --state "$live_cancel_state" --run-id run-cancel-live --event assembly-live \
    --action assembly --expected-head "$live_cancel_head" --writer feature-owner \
    --active-state "$live_cancel_pointer" --branch live-cancel-branch --generation 1 \
    --assembly-plan "$tmp/live-assembly.json" --repo-root "$FIXTURE_REPO" >/dev/null
jq -n --arg head "$live_cancel_head" '{status:"absent",event:"assembly-live",action:"assembly",head:$head}' \
    >"$tmp/live-assembly-absent.json"
cancel_rc=0
"$MONITOR" cancel --state "$live_cancel_state" --run-id run-cancel-live --event assembly-live \
    "${live_cancel_identity[@]}" --observed "$tmp/live-assembly-absent.json" \
    --reason 'non-push owner attempt' --repo-root "$FIXTURE_REPO" >"$tmp/live-cancel-error" 2>&1 || cancel_rc=$?
[ "$cancel_rc" -eq 2 ] || fail 'live owner cancelled a non-push reservation'
jq -e '.actions[1].state == "reserved"' "$live_cancel_state" >/dev/null || fail 'non-push cancellation modified state'
pass "live cancellation remains push-only"

activate_run "$FIXTURE_REPO" run-retire-serial serial-branch "$FIXTURE_REV" >/dev/null
serial_pointer="$("$MONITOR" active-path --branch serial-branch --repo-root "$FIXTURE_REPO")"
serial_record="$(dirname "$("$MONITOR" state-path --run-id run-retire-serial --repo-root "$FIXTURE_REPO")")/run.json"
serial_snapshot="$tmp/serial-pointer.json"
cp "$serial_pointer" "$serial_snapshot"
jq -n '{schema: 2, run_id: "run-retire-serial", outcome: "abandoned"}' >"$serial_record"
rm -- "$serial_pointer"
serial_lock="${serial_pointer}.lock"
owner_start="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$$" 2>/dev/null | sed 's/^ *//;s/ *$//')"
[ -n "$owner_start" ] || fail "could not read the test lock owner's process start"
printf '%s|%s|%s|test-owner|%s\n' "$$" "$(hostname)" "$(id -u)" "$owner_start" >"$serial_lock"
real_ln="$(command -v ln)"
mkdir -p "$tmp/lock-bin"
cat >"$tmp/lock-bin/ln" <<'LOCK_HELPER'
#!/usr/bin/env bash
if [ ! -e "$LOCK_SIGNALLED" ]; then
    : >"$LOCK_SIGNALLED"
    printf 'lock-attempt\n' >"$LOCK_EVENTS"
fi
exec "$REAL_LN" "$@"
LOCK_HELPER
chmod +x "$tmp/lock-bin/ln"
lock_events="$tmp/retire-lock-events"
lock_signalled="$tmp/retire-lock-signalled"
mkfifo "$lock_events"
(
    export LOCK_EVENTS="$lock_events"
    export LOCK_SIGNALLED="$lock_signalled"
    export REAL_LN="$real_ln"
    export PATH="$tmp/lock-bin:$PATH"
    if "$MONITOR" retire --run-id run-retire-serial --repo-root "$FIXTURE_REPO" \
        >"$tmp/retire-serial.log" 2>&1; then
        retire_status=0
    else
        retire_status=$?
    fi
    if [ ! -e "$lock_signalled" ]; then
        printf 'retire-exit:%s\n' "$retire_status" >"$lock_events"
    fi
    exit "$retire_status"
) &
retire_pid=$!
lock_event=""
IFS= read -r lock_event <"$lock_events" || fail "retire produced no lock synchronization event"
[ "$lock_event" = "lock-attempt" ] ||
    fail "retire returned before locking the absent pointer: $lock_event; $(cat "$tmp/retire-serial.log")"
[ ! -e "$serial_pointer" ] || fail "serial fixture published the pointer before lock release"
cp "$serial_snapshot" "$serial_pointer.tmp"
mv "$serial_pointer.tmp" "$serial_pointer"
rm -f "$serial_lock"
retire_rc=0
wait "$retire_pid" || retire_rc=$?
[ "$retire_rc" -eq 0 ] || fail "retire did not complete after lock release: $(cat "$tmp/retire-serial.log")"
[ ! -e "$serial_pointer" ] || fail "retire left the pointer published by the in-flight activation"
pass "retire locks before checking absence and removes a pointer published while activation held the lock"

# ── Prune only validated terminal pointers ---------------------------------
echo ""
echo "--- Prune reports terminal removals and preserves every skip case ---"
setup_fixture '{"trusted_orchestrator_actor_ids": [12345]}'
write_run_outcome() {
    local run_id="$1" outcome="$2" run_file
    run_file="$(dirname "$("$MONITOR" state-path --run-id "$run_id" --repo-root "$FIXTURE_REPO")")/run.json"
    mkdir -p "$(dirname "$run_file")"
    jq -n --arg run "$run_id" --argjson outcome "$outcome" \
        '{schema: 2, run_id: $run, outcome: $outcome}' >"$run_file"
}
activate_run "$FIXTURE_REPO" run-prune-terminal terminal-branch "$FIXTURE_REV" >/dev/null
terminal_pointer="$("$MONITOR" active-path --branch terminal-branch --repo-root "$FIXTURE_REPO")"
write_run_outcome run-prune-terminal '"ready-for-review"'
activate_run "$FIXTURE_REPO" run-prune-open open-branch "$FIXTURE_REV" >/dev/null
open_pointer="$("$MONITOR" active-path --branch open-branch --repo-root "$FIXTURE_REPO")"
write_run_outcome run-prune-open null
activate_run "$FIXTURE_REPO" run-prune-version version-branch "$FIXTURE_REV" >/dev/null
version_pointer="$("$MONITOR" active-path --branch version-branch --repo-root "$FIXTURE_REPO")"
write_run_outcome run-prune-version '"capped"'
jq '.version = 2' "$version_pointer" >"$version_pointer.tmp"
mv "$version_pointer.tmp" "$version_pointer"
activate_run "$FIXTURE_REPO" run-prune-mismatch mismatch-branch "$FIXTURE_REV" >/dev/null
mismatch_pointer="$("$MONITOR" active-path --branch mismatch-branch --repo-root "$FIXTURE_REPO")"
write_run_outcome run-prune-mismatch '"abandoned"'
binding="$(dirname "$("$MONITOR" state-path --run-id run-prune-mismatch --repo-root "$FIXTURE_REPO")")/branch.json"
jq '.branch = "other-branch"' "$binding" >"$binding.tmp"
mv "$binding.tmp" "$binding"
activate_run "$FIXTURE_REPO" run-prune-missing missing-branch "$FIXTURE_REV" >/dev/null
rm "$(dirname "$("$MONITOR" state-path --run-id run-prune-missing --repo-root "$FIXTURE_REPO")")/run.json"
missing_pointer="$("$MONITOR" active-path --branch missing-branch --repo-root "$FIXTURE_REPO")"
activate_run "$FIXTURE_REPO" run-prune-reserved reserved-prune-branch "$FIXTURE_REV" >/dev/null
reserved_prune_pointer="$("$MONITOR" active-path --branch reserved-prune-branch --repo-root "$FIXTURE_REPO")"
write_run_outcome run-prune-reserved '"escalated"'
reserved_prune_state="$("$MONITOR" state-path --run-id run-prune-reserved --repo-root "$FIXTURE_REPO")"
jq -n '{version: 1, cursor: null, actions: [{event: "evt", action: "push", state: "reserved"}]}' >"$reserved_prune_state"
activate_run "$FIXTURE_REPO" run-prune-cancelled cancelled-prune-branch "$FIXTURE_REV" >/dev/null
cancelled_prune_pointer="$("$MONITOR" active-path --branch cancelled-prune-branch --repo-root "$FIXTURE_REPO")"
cancelled_prune_state="$("$MONITOR" state-path --run-id run-prune-cancelled --repo-root "$FIXTURE_REPO")"
cancelled_prune_head="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
"$MONITOR" reserve --state "$cancelled_prune_state" --event evt-cancelled-prune --action push \
    --expected-head "$cancelled_prune_head" --writer feature-owner --active-state "$cancelled_prune_pointer" \
    --run-id run-prune-cancelled --branch cancelled-prune-branch --generation 1 --repo-root "$FIXTURE_REPO" >/dev/null
write_run_outcome run-prune-cancelled '"escalated"'
jq -n --arg event evt-cancelled-prune --arg head "$cancelled_prune_head" \
    '{status: "absent", event: $event, action: "push", head: $head}' >"$tmp/cancelled-prune-observed.json"
"$MONITOR" cancel --state "$cancelled_prune_state" --run-id run-prune-cancelled --event evt-cancelled-prune \
    --observed "$tmp/cancelled-prune-observed.json" --reason 'test action was never sent' --repo-root "$FIXTURE_REPO" >/dev/null
invalid_pointer="$("$MONITOR" active-path --branch invalid-prune-branch --repo-root "$FIXTURE_REPO")"
printf '{invalid json\n' >"$invalid_pointer"
active_dir="$(dirname "$terminal_pointer")"
printf 'leftover\n' >"$active_dir/orphan.json.lock"
printf 'leftover\n' >"$active_dir/orphan.tmp.1"
printf 'leftover\n' >"$active_dir/orphan.claim.1"

output="$("$MONITOR" prune --dry-run --repo-root "$FIXTURE_REPO")"
grep -qF "would remove ${terminal_pointer##*/} (run run-prune-terminal" <<<"$output" || fail "dry-run omitted the terminal pointer: $output"
grep -qF 'run record is invalid or still open' <<<"$output" || fail "prune did not report the open run: $output"
grep -qF 'unsupported version' <<<"$output" || fail "prune did not report the unsupported pointer version: $output"
grep -qF 'branch-mismatched run binding' <<<"$output" || fail "prune did not report the branch-mismatched binding: $output"
grep -qF 'run record is missing' <<<"$output" || fail "prune did not report the missing run record: $output"
grep -qF 'unreconciled reserved action' <<<"$output" || fail "prune did not report the unreconciled reservation: $output"
grep -qF "would remove ${cancelled_prune_pointer##*/} (run run-prune-cancelled" <<<"$output" ||
    fail "prune did not accept an ended run whose reservation was cancelled: $output"
grep -qF 'leftover lock, temporary, claim' <<<"$output" || fail "prune did not report leftover files: $output"
[ -e "$terminal_pointer" ] || fail "--dry-run removed a terminal pointer"

output="$("$MONITOR" prune --repo-root "$FIXTURE_REPO")"
grep -qF "removed ${terminal_pointer##*/} (run run-prune-terminal" <<<"$output" || fail "prune did not report its removal: $output"
[ ! -e "$terminal_pointer" ] || fail "prune left a terminal pointer behind"
[ ! -e "$cancelled_prune_pointer" ] || fail "prune did not remove a terminal pointer after reservation cancellation"
[ -e "$open_pointer" ] && [ -e "$version_pointer" ] && [ -e "$mismatch_pointer" ] &&
    [ -e "$missing_pointer" ] && [ -e "$reserved_prune_pointer" ] && [ -e "$invalid_pointer" ] ||
    fail "prune removed a pointer that should have been skipped"
[ -e "$active_dir/orphan.json.lock" ] && [ -e "$active_dir/orphan.tmp.1" ] && [ -e "$active_dir/orphan.claim.1" ] ||
    fail "prune removed a leftover lock/temp/claim entry"
pass "prune dry-run is read-only; actual pruning removes the terminal run and reports all skip classes"

echo ""

# #1722: every guarded boundary refuses stale tools before touching state.
setup_fixture '{"trusted_orchestrator_actor_ids": [12345]}'
mkdir -p "$FIXTURE_REPO/skills/orchestrate/assets"
cp "$MONITOR" "$FIXTURE_REPO/skills/orchestrate/assets/dev-flow-monitor.sh"
fixture_monitor="$FIXTURE_REPO/skills/orchestrate/assets/dev-flow-monitor.sh"
printf 'source:\n  ref: v1\n' >"$FIXTURE_REPO/.skills-sync.yaml"
git -C "$FIXTURE_REPO" add .skills-sync.yaml skills
git -C "$FIXTURE_REPO" commit -qm 'old pin'
old_head="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
printf 'source:\n  ref: v2\n' >"$FIXTURE_REPO/.skills-sync.yaml"
git -C "$FIXTURE_REPO" commit -qam 'new pin'
new_head="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
git -C "$FIXTURE_REPO" update-ref refs/remotes/origin/main "$new_head"
git -C "$FIXTURE_REPO" checkout -q --detach "$old_head"
for boundary in check-assets activate reserve-agent-run reserve; do
    rc=0
    output="$("$fixture_monitor" "$boundary" --repo-root "$FIXTURE_REPO" 2>&1)" || rc=$?
    [ "$rc" -eq 2 ] || fail "$boundary accepted stale tools"
    for expected in BLOCKER "$old_head" "$new_head" v1 v2 'fetch origin' 'merge --ff-only origin/main'; do
        [[ "$output" == *"$expected"* ]] || fail "$boundary omitted $expected: $output"
    done
done
git -C "$FIXTURE_REPO" checkout -q --detach "$new_head"
"$fixture_monitor" check-assets --repo-root "$FIXTURE_REPO"
printf 'source:\n  ref: v1\n' >"$FIXTURE_REPO/.skills-sync.yaml"
rc=0
output="$("$fixture_monitor" check-assets --repo-root "$FIXTURE_REPO" 2>&1)" || rc=$?
[ "$rc" -eq 2 ] && [[ "$output" == *'skills pin v1, default pin v2'* ]] || fail "pin-only mismatch accepted"
git -C "$FIXTURE_REPO" restore .skills-sync.yaml
# The target lane is current, but a script in an older sibling checkout is not.
mkdir -p "$FIXTURE_REPO/skills/orchestrate/assets"
cp "$MONITOR" "$FIXTURE_REPO/skills/orchestrate/assets/dev-flow-monitor.sh"
git -C "$FIXTURE_REPO" add skills
git -C "$FIXTURE_REPO" commit --allow-empty -qm 'vendored monitor'
script_head="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
git -C "$FIXTURE_REPO" -c user.name=test -c user.email=test@test.com commit --allow-empty -qm 'default advances'
fresh_head="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
git -C "$FIXTURE_REPO" update-ref refs/remotes/origin/main "$fresh_head"
git -C "$FIXTURE_REPO" worktree add -q --detach "$tmp/current-lane" "$fresh_head"
git -C "$FIXTURE_REPO" checkout -q --detach "$script_head"
rc=0
output="$(bash "$FIXTURE_REPO/skills/orchestrate/assets/dev-flow-monitor.sh" check-assets --repo-root "$tmp/current-lane" 2>&1)" || rc=$?
[ "$rc" -eq 2 ] && [[ "$output" == *"HEAD $script_head, default $fresh_head"* ]] || fail "current lane hid stale asset checkout: $output"
pass "stale HEAD and pins refuse all boundaries; current tools pass (#1722)"

# Challenge r1: executing assets keep their identity across clone boundaries.
git -C "$tmp/current-lane" status --porcelain >/dev/null
for layout in extracted separate; do
    tools="$tmp/$layout-tools"
    mkdir -p "$tools/skills/orchestrate/assets"
    cp "$MONITOR" "$tools/skills/orchestrate/assets/dev-flow-monitor.sh"
    if [ "$layout" = separate ]; then
        git -C "$tools" init -q -b main
        git -C "$tools" config user.name test
        git -C "$tools" config user.email test@test.com
        printf 'source:\n  ref: v1\n' >"$tools/.skills-sync.yaml"
        git -C "$tools" add .
        git -C "$tools" commit -qm 'separate tools v1'
        git -C "$tools" update-ref refs/remotes/origin/main HEAD
        git -C "$tools" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    else
        printf '# ref: v1 (fixture)\n' >"$tools/skills/.SKILLS_PROVENANCE"
    fi
    rc=0
    output="$(bash "$tools/skills/orchestrate/assets/dev-flow-monitor.sh" check-assets --repo-root "$tmp/current-lane" 2>&1)" || rc=$?
    [ "$rc" -eq 2 ] && [[ "$output" == *BLOCKER* && "$output" == *v1* && "$output" == *v2* ]] || fail "$layout assets lost their own stale pin: $output"
    if [ "$layout" = separate ]; then
        printf 'source:\n  ref: v2\n' >"$tools/.skills-sync.yaml"
        git -C "$tools" commit -qam 'separate tools v2'
        git -C "$tools" update-ref refs/remotes/origin/main HEAD
    else
        printf '# ref: v2 (fixture)\n' >"$tools/skills/.SKILLS_PROVENANCE"
    fi
    bash "$tools/skills/orchestrate/assets/dev-flow-monitor.sh" check-assets --repo-root "$tmp/current-lane"
    if [ "$layout" = separate ]; then
        tools_head="$(git -C "$tools" rev-parse HEAD)"
        git -C "$tools" commit --allow-empty -qm 'separate default advances'
        tools_tip="$(git -C "$tools" rev-parse HEAD)"
        git -C "$tools" update-ref refs/remotes/origin/main HEAD
        git -C "$tools" checkout -q --detach "$tools_head"
        rc=0
        output="$(bash "$tools/skills/orchestrate/assets/dev-flow-monitor.sh" check-assets --repo-root "$tmp/current-lane" 2>&1)" || rc=$?
        [ "$rc" -eq 2 ] && [[ "$output" == *"$tools_head"* && "$output" == *"$tools_tip"* ]] || fail "current target hid behind separate tools: $output"
    fi
done
pass "separate and extracted tools retain pins; separate checkout ancestry is checked"

# Challenge r2: current executing tools accept feature targets before catch-up.
primary="$tmp/separate-tools"
git -C "$primary" checkout -q --detach refs/remotes/origin/main
primary_head="$(git -C "$primary" rev-parse HEAD)"
git -C "$primary" worktree add -q --detach "$tmp/diverged-same-clone" "$tools_head"
git -C "$tmp/diverged-same-clone" commit --allow-empty -qm 'feature changes before catch-up'
[ "$(git -C "$tmp/diverged-same-clone" rev-list --count HEAD..refs/remotes/origin/main)" -gt 0 ] || fail 'same-clone target must be behind the base'
bash "$primary/skills/orchestrate/assets/dev-flow-monitor.sh" check-assets --repo-root "$tmp/diverged-same-clone"
git -C "$tmp/current-lane" checkout -q --detach "$script_head"
git -C "$tmp/current-lane" commit --allow-empty -qm 'separate feature changes before catch-up'
[ "$(git -C "$tmp/current-lane" rev-list --count HEAD..refs/remotes/origin/main)" -gt 0 ] || fail 'separate-clone target must be behind the base'
bash "$primary/skills/orchestrate/assets/dev-flow-monitor.sh" check-assets --repo-root "$tmp/current-lane"
pass "current primary assets accept diverged same-clone and separate-clone feature targets"
# A Git-backed asset checkout must never skip its own ancestry proof.
git -C "$primary" symbolic-ref --delete refs/remotes/origin/HEAD
git -C "$primary" update-ref -d refs/remotes/origin/main
rc=0
output="$(bash "$primary/skills/orchestrate/assets/dev-flow-monitor.sh" check-assets --repo-root "$tmp/current-lane" 2>&1)" || rc=$?
[ "$rc" -eq 2 ] && [[ "$output" == *BLOCKER* ]] || fail "missing executing default refs passed: $output"
git -C "$primary" update-ref refs/remotes/origin/main "$primary_head"
git -C "$primary" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
pass "separate Git-backed assets fail closed when default tracking refs are missing"

# Challenge r1: an active generation cannot reserve work after its tools go stale.
setup_fixture '{"trusted_orchestrator_actor_ids": [12345]}'
mkdir -p "$FIXTURE_REPO/skills/orchestrate/assets"
cp "$MONITOR" "$FIXTURE_REPO/skills/orchestrate/assets/dev-flow-monitor.sh"
git -C "$FIXTURE_REPO" add skills
git -C "$FIXTURE_REPO" commit -qm 'executing fixture monitor'
git -C "$FIXTURE_REPO" update-ref refs/remotes/origin/main HEAD
fixture_monitor="$FIXTURE_REPO/skills/orchestrate/assets/dev-flow-monitor.sh"
activate_run "$FIXTURE_REPO" run-stale-reserve stale-reserve "$FIXTURE_REV" >/dev/null
active="$("$MONITOR" active-path --branch stale-reserve --repo-root "$FIXTURE_REPO")"
state="$("$MONITOR" state-path --run-id run-stale-reserve --repo-root "$FIXTURE_REPO")"
reserve_head="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
"$fixture_monitor" reserve --state "$state" --event before-stale --action push \
    --expected-head "$reserve_head" --writer feature-owner --active-state "$active" \
    --run-id run-stale-reserve --branch stale-reserve --generation 1 --repo-root "$FIXTURE_REPO" >/dev/null
cp "$state" "$tmp/reservation-before-stale.json"
git -C "$FIXTURE_REPO" commit --allow-empty -qm 'default advances after activation'
git -C "$FIXTURE_REPO" update-ref refs/remotes/origin/main HEAD
git -C "$FIXTURE_REPO" checkout -q --detach "$reserve_head"
rc=0
output="$("$fixture_monitor" reserve --state "$state" --event after-stale --action push \
    --expected-head "$reserve_head" --writer feature-owner --active-state "$active" \
    --run-id run-stale-reserve --branch stale-reserve --generation 1 --repo-root "$FIXTURE_REPO" 2>&1)" || rc=$?
[ "$rc" -eq 2 ] && [[ "$output" == *BLOCKER* ]] || fail "stale active run reserved a push: $output"
cmp -s "$state" "$tmp/reservation-before-stale.json" || fail 'stale reservation changed monitor state'
pass "reserve refuses after activation when tools become stale, without durable writes"

# Resume from only durable records; no session directory or local agent exists.
node --input-type=module - "$tool_root" "$tmp" <<'NODE'
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { chmodSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createHash } from 'node:crypto'
const [tools, temporary] = process.argv.slice(2)
process.argv[1] = tools
const assets = join(tools, 'ai/skills/universal/orchestrate/assets')
const { chainDigest } = await import(join(assets, '../../dev-flow-support/assets/run-record.mjs'))
const fixture = join(tools, 'ai/schemas/fixtures')
const repo = join(temporary, 'resume-only')
mkdirSync(repo)
const git = (...args) => execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8' }).trim()
git('init', '-q', '-b', '935-plan')
writeFileSync(join(repo, 'agent-registry.json'), JSON.stringify({ finders: [{ trusted_actor_id: '424242' }] }))
git('add', 'agent-registry.json')
git('-c', 'user.name=test', '-c', 'user.email=test@example.test', 'commit', '--allow-empty', '-qm', 'fixture')
const head = git('rev-parse', 'HEAD')
// The live conductor and tool checkout both differ from the immutable kickoff registry.
writeFileSync(join(repo, 'agent-registry.json'), JSON.stringify({ finders: [{ trusted_actor_id: '424243' }] }))
const root = join(repo, '.git/dev-flow-v2')
const save = (file, data) => { mkdirSync(join(file, '..'), { recursive: true }); writeFileSync(file, typeof data === 'string' ? data : JSON.stringify(data)) }
const json = file => JSON.parse(readFileSync(file, 'utf8'))
const planDoc = json(join(fixture, 'plan/valid/interactive.json'))
const revision = planDoc.revisions[0]
const lane = revision.plan.lanes[0]
const runDir = join(root, 'runs', lane.run_id)
const run = json(join(fixture, 'run.schema/valid/fresh-kickoff.json'))
run.run_id = lane.run_id
run.stage_transitions = ['kickoff', 'claim', 'implement', 'verify', 'security', 'integration'].map((stage, index) =>
  ({ stage, entered_at: `2026-08-29T09:0${index}:00Z`, ...(index < 5 ? { exit: 'fixture gate passed' } : {}) }))
run.receipts = run.stage_transitions.slice(1).map(({ stage, entered_at }) => ({ kind: 'transition', stage, entered_at }))
run.pr = { number: 123, url: 'https://github.com/bound/delivery/pull/123' }
const binding = { number: 123, url: run.pr.url, bound_at: '2026-08-29T09:05:00Z' }
run.pr_bindings = [{ seq: 0, ...binding, prev_digest: 'genesis', digest: chainDigest(binding, 'genesis') }]
const runFile = join(runDir, 'run.json')
save(runFile, run)
save(join(runDir, 'owner-slate'), planDoc.slate_id)
save(join(runDir, 'branch.json'), { version: 1, run_id: lane.run_id, branch: lane.branch })
const pointer = join(root, 'active', createHash('sha256').update(lane.branch).digest('hex') + '.json')
save(pointer, { version: 1, run_id: lane.run_id, branch: lane.branch, generation: 2, registry_revision: head })
const reservation = { event: 'pending-push', action: 'push', state: 'reserved', expected_head: head }
save(join(runDir, 'monitor.json'), { version: 1, cursor: 0, actions: [reservation] })
save(join(root, 'slates', planDoc.slate_id, 'plan.json'), planDoc)
const briefTemplate = readFileSync(join(fixture, 'brief.envelope/valid/minimal.md'), 'utf8')
const facts = JSON.parse(briefTemplate.match(/```json\n([\s\S]*?)\n```/)[1])
Object.assign(facts, { run_id: lane.run_id, branch: lane.branch, generation: 2, record_directory: runDir,
  active_state_path: pointer, worktree_path: repo, deadline: '2099-01-01T00:00:00Z',
  issue: { number: 935, title: 'fixture', url: 'https://github.com/example/repo/issues/935' } })
facts.claim_handoff.branch = lane.branch
facts.sentinels = { ready: 'MERGE-READY-planning-a1', handoff: 'DRAFT-PUBLISHED-planning-a1', blocked: 'BLOCKED-planning-a1', attempt_nonce: 'a1' }
const brief = briefTemplate.replace(/```json\n[\s\S]*?\n```/, '```json\n' + JSON.stringify(facts) + '\n```')
save(join(runDir, 'lane-brief-a1.md'), brief)
save(join(runDir, 'lane-status-a1.json'), { state: 'working', seq: 1, stage: 'implement', round: 0, head,
  updated_at: '2026-11-04T21:00:00Z', summary: 'fixture working' })
// Terminal pointer eligibility is identical to the existing prune predicate.
const ended = 'run-terminal'
save(join(root, 'runs', ended, 'run.json'), { schema: 2, run_id: ended, outcome: 'abandoned' })
save(join(root, 'runs', ended, 'branch.json'), { version: 1, run_id: ended, branch: 'ended' })
const endedPointer = join(root, 'active', createHash('sha256').update('ended').digest('hex') + '.json')
save(endedPointer, { version: 1, run_id: ended, branch: 'ended', generation: 1, registry_revision: head })
const snapshot = dir => readdirSync(dir, { withFileTypes: true }).sort((a,b) => a.name.localeCompare(b.name)).flatMap(entry =>
  entry.isDirectory() ? snapshot(join(dir, entry.name)) : [[join(dir, entry.name), readFileSync(join(dir, entry.name), 'base64')]])
const before = snapshot(root)
const invoke = (rootArgs = ['--repo-root', repo], cwd = tools) => spawnSync('bash',
  [join(assets, 'dev-flow-monitor.sh'), 'resume', '--slate-id', planDoc.slate_id, ...rootArgs, '--now', '2026-08-29T12:00:00Z'], { cwd, encoding: 'utf8' })
const output = invoke()
assert.equal(output.status, 0, output.stderr + output.stdout)
const view = JSON.parse(output.stdout)
assert.deepEqual(snapshot(root), before, 'resume wrote durable state')
assert.equal(view.lanes[0].run_id, lane.run_id)
assert.equal(view.lanes[0].generation, 2)
assert.equal(view.lanes[0].stage, 'integration')
assert.equal(view.lanes[0].branch, lane.branch)
assert.equal(view.lanes[0].pr.number, 123)
assert.deepEqual(view.lanes[0].unreconciled_reservations, [reservation])
assert.equal(view.lanes[0].lane_status.seq, 1)
assert.equal(view.lanes[0].lane_status_freshness, 'current')
assert.equal(view.lanes[0].local_branch_head, head)
assert.equal(view.undispatched.length, 1)
assert.match(view.terminal_pointers, /would remove .*run-terminal/)
assert.ok(view.watcher.argv.includes('planning:935-plan:a1:bound/delivery:cloud'))
assert.equal(view.watcher.argv[view.watcher.argv.indexOf('--registry') + 1], join(repo, 'agent-registry.json'))
assert.equal(view.watcher.argv[view.watcher.argv.indexOf('--registry-revision') + 1], head)
// Nested invocation must emit the same root-bound, executable watcher command.
const nested = join(repo, 'nested', 'directory')
mkdirSync(nested, { recursive: true })
const nestedViews = [invoke([], nested), invoke(['--repo-root', nested])].map(output => {
  assert.equal(output.status, 0, output.stderr + output.stdout)
  const nestedView = JSON.parse(output.stdout)
  assert.deepEqual(nestedView, view)
  return nestedView
})
assert.deepEqual(snapshot(root), before, 'nested resume wrote durable state')
// Exercise the actual watcher parser and observation loop with offline reads.
const bin = join(temporary, 'resume-bin')
mkdirSync(bin)
const calls = join(temporary, 'resume-gh-calls')
save(join(bin, 'gh'), `#!/bin/sh
printf '%s\\n' "$*" >>"$RESUME_GH_CALLS"
case "$*" in
  *--include*) printf 'HTTP/2 404\\n\\n{}\\n' ;;
  *issues/123/comments*) printf '%s\\n' '${JSON.stringify([
    { id: 101, user: { id: 424242, type: 'Bot', login: 'pinned-bot' }, created_at: '2026-11-04T21:00:00Z', body: 'pinned' },
    { id: 102, user: { id: 424243, type: 'Bot', login: 'drift-bot' }, created_at: '2026-11-04T21:00:00Z', body: 'drift' },
    { id: 103, user: { id: 199175422, type: 'Bot', login: 'tool-bot' }, created_at: '2026-11-04T21:00:00Z', body: 'tool' },
  ])}' ;;
  'pr view 123 '*) printf '%s\\n' '${JSON.stringify({ number: 123, isDraft: true, state: 'OPEN', headRefOid: head })}' ;;
  'pr list '*) printf '%s\\n' '${JSON.stringify([{ number: 999, isDraft: true, state: 'OPEN', headRefOid: head }])}' ;;
  *) printf '[]\\n' ;;
esac
`)
chmodSync(join(bin, 'gh'), 0o755)
const watchLane = (argv = view.watcher.argv) => spawnSync('bash', [view.watcher.executable,
  '--iterations', '1', ...argv],
{ cwd: tools, encoding: 'utf8', env: { ...process.env, RESUME_GH_CALLS: calls, PATH: bin + ':' + process.env.PATH } })
const watch = watchLane()
assert.equal(watch.status, 0, watch.stderr)
assert.match(watch.stdout, /LANE-STATUS planning: seq=1 state=working/)
assert.match(watch.stdout, /BRANCH planning: absent/) // unpushed local branch
assert.match(watch.stdout, /PR planning: bound\/delivery#123 /)
assert.match(watch.stdout, /PR-ACTIVITY planning: bound\/delivery#123 pinned-bot comment 101 /)
assert.doesNotMatch(watch.stdout, /drift-bot|tool-bot/)
assert.doesNotMatch(readFileSync(calls, 'utf8'), /pr list/)
assert.match(readFileSync(calls, 'utf8'), /pr view 123 --repo bound\/delivery/)
for (const nestedView of nestedViews) {
  const nestedWatch = watchLane(nestedView.watcher.argv)
  assert.equal(nestedWatch.status, 0, nestedWatch.stderr)
}
// Recovered argv observes new durable waits without Herdr or a remote branch.
let sequence = 1
for (const state of ['decision-request', 'blocked', 'handoff']) {
  save(join(runDir, 'lane-status-a1.json'), { state, seq: ++sequence, stage: 'challenge', round: 1, head,
    ...(state === 'decision-request' ? { request_id: 'DR-recovered' } : {}),
    updated_at: '2026-11-04T21:01:00Z', summary: 'recovered ' + state })
  const observed = watchLane()
  assert.equal(observed.status, 0, observed.stderr)
  assert.match(observed.stdout, new RegExp(`LANE-STATUS planning: seq=${sequence} state=${state}`))
}
// A conductor checkout or missing recorded root cannot substitute for the lane's head.
const missingRoot = [...view.watcher.argv]
missingRoot[missingRoot.indexOf('--status-root') + 1] = 'planning=' + join(temporary, 'absent-worktree')
assert.doesNotMatch(watchLane(missingRoot).stdout, /LANE-STATUS/)
// Reconstruction preserves historical status while explicitly qualifying its head.
git('-c', 'user.name=test', '-c', 'user.email=test@example.test', 'commit', '--allow-empty', '-qm', 'advance lane')
const advancedHead = git('rev-parse', 'HEAD')
const stale = JSON.parse(invoke().stdout).lanes[0]
assert.equal(stale.lane_status_freshness, 'stale')
assert.equal(stale.local_branch_head, advancedHead)
assert.equal(stale.lane_status.head, head)
assert.doesNotMatch(watchLane().stdout, /LANE-STATUS/)
git('update-ref', 'refs/heads/' + lane.branch, head)
save(join(runDir, 'lane-brief-a1.md'), brief.replace('"worktree_path":' + JSON.stringify(repo),
  '"worktree_path":' + JSON.stringify(join(temporary, 'absent-worktree'))))
const unavailable = JSON.parse(invoke().stdout).lanes[0]
assert.equal(unavailable.lane_status_freshness, 'unverifiable')
assert.equal(unavailable.local_branch_head, null)
assert.equal(unavailable.lane_status.head, head)
save(join(runDir, 'lane-brief-a1.md'), brief)
// Missing pins and unreadable immutable registry objects never select current trust.
const originalPointer = json(pointer)
for (const registry_revision of [undefined, '0'.repeat(40)]) {
  save(pointer, { ...originalPointer, registry_revision })
  const refused = invoke()
  assert.equal(refused.status, 1, refused.stdout + refused.stderr)
  assert.equal(JSON.parse(refused.stdout).watcher, null)
}
save(pointer, originalPointer)
for (const [option, value] of [['--registry-revision', 'main'], ['--registry-revision', '0'.repeat(40)],
  ['--registry', join(repo, 'not-the-registry.json')]]) {
  const invalidArgs = [...view.watcher.argv]
  invalidArgs[invalidArgs.indexOf(option) + 1] = value
  assert.equal(watchLane(invalidArgs).status, 2)
}
// Missing run records with each independent kind of dispatch evidence block.
const untouched = revision.plan.lanes[1]
const untouchedDir = join(root, 'runs', untouched.run_id)
// Terminal PR observation still needs its immutable pin after session loss.
const terminal = structuredClone(run)
terminal.outcome = 'abandoned'
terminal.stage_transitions.at(-1).exit = 'fixture ended'
const terminalOutcome = { outcome: 'abandoned', at: '2026-11-04T21:00:00Z' }
terminal.outcome_transitions = [{ seq: 0, ...terminalOutcome, prev_digest: 'genesis',
  digest: chainDigest(terminalOutcome, 'genesis') }]
save(runFile, terminal)
rmSync(pointer)
const unpinnedTerminal = invoke()
assert.equal(unpinnedTerminal.status, 1, unpinnedTerminal.stdout + unpinnedTerminal.stderr)
assert.equal(JSON.parse(unpinnedTerminal.stdout).lanes.length, 1, unpinnedTerminal.stdout + unpinnedTerminal.stderr)
assert.equal(JSON.parse(unpinnedTerminal.stdout).lanes[0].outcome, 'abandoned')
assert.equal(JSON.parse(unpinnedTerminal.stdout).watcher, null)
assert.match(unpinnedTerminal.stdout, /lacks a matching kickoff-pinned registry revision/)
save(pointer, originalPointer)
assert.equal(invoke().status, 0, 'terminal run with retained pin should remain watchable')
save(runFile, run)
save(join(untouchedDir, 'run.json'), { ...terminal, run_id: untouched.run_id })
save(join(untouchedDir, 'owner-slate'), planDoc.slate_id)
save(join(untouchedDir, 'branch.json'), { version: 1, run_id: untouched.run_id, branch: untouched.branch })
const otherPointer = join(root, 'active', createHash('sha256').update(untouched.branch).digest('hex') + '.json')
save(otherPointer, { version: 1, run_id: untouched.run_id, branch: untouched.branch, generation: 1, registry_revision: advancedHead })
const mismatchedPins = invoke()
assert.equal(mismatchedPins.status, 1, mismatchedPins.stdout + mismatchedPins.stderr)
assert.equal(JSON.parse(mismatchedPins.stdout).watcher, null)
assert.match(mismatchedPins.stdout, /different kickoff-pinned registry revisions/)
rmSync(otherPointer)
rmSync(untouchedDir, { recursive: true })
const expectMissingBlock = () => {
  const missing = invoke()
  assert.equal(missing.status, 1, missing.stderr + missing.stdout)
  assert.ok(missing.stdout, missing.stderr)
  const state = JSON.parse(missing.stdout)
  assert.equal(state.watcher, null)
  assert.ok(state.blockers.some(entry => entry.run_id === untouched.run_id && /surviving dispatch evidence/.test(entry.reason)))
}
for (const evidence of ['branch.json', 'monitor.json', 'lane-brief-a1.md']) {
  save(join(untouchedDir, evidence), '{}')
  expectMissingBlock()
  rmSync(untouchedDir, { recursive: true })
}
const ownerAttempt = join(root, 'slates', planDoc.slate_id, 'orchestrator', untouched.run_id)
save(join(ownerAttempt, 'a1', 'lane-brief.md'), 'surviving attempt')
expectMissingBlock()
rmSync(ownerAttempt, { recursive: true })
const strayPointer = join(root, 'active', createHash('sha256').update('other-branch').digest('hex') + '.json')
save(strayPointer, { version: 1, run_id: untouched.run_id, branch: 'other-branch', generation: 1, registry_revision: head })
expectMissingBlock()
rmSync(strayPointer)
revision.plan.lanes.pop()
const retainedIssue = revision.plan.issues.find(issue => issue.number === untouched.issue)
const priorIssue = structuredClone(retainedIssue)
Object.assign(retainedIssue, { verdict: 'handed-off', pr: 456 })
revision.plan.retained_lanes = [{ lane: untouched, policy: revision.plan.policy, state: 'idle' }]
const rehash = () => { revision.digest = chainDigest({ seq: revision.seq, at: revision.at, reason: revision.reason, plan: revision.plan }, 'genesis'); save(join(root, 'slates', planDoc.slate_id, 'plan.json'), planDoc) }
rehash()
expectMissingBlock()
revision.plan.lanes.push(untouched)
Object.keys(retainedIssue).forEach(key => delete retainedIssue[key])
Object.assign(retainedIssue, priorIssue)
delete revision.plan.retained_lanes
rehash()
assert.equal(invoke().status, 0)
// Conflicting attempts and corrupted records never yield an actionable watcher.
save(join(runDir, 'lane-brief-a2.md'), brief.replaceAll('-a1', '-a2').replace('"attempt_nonce":"a1"', '"attempt_nonce":"a2"'))
const ambiguous = invoke()
assert.equal(ambiguous.status, 1, ambiguous.stderr)
assert.equal(JSON.parse(ambiguous.stdout).watcher, null)
assert.match(ambiguous.stdout, /expected one current-generation attempt/)
console.log('  PASS: read-only resume reconstructs slate and re-arms real watcher without a session directory')
NODE

# Operational checkpoint (#1893): a compact, provenance-bearing projection of the next
# authorized action, derived only from durable records and never granting authority.
node --input-type=module - "$tool_root" "$tmp" <<'NODE'
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { createHash } from 'node:crypto'
const [tools, temporary] = process.argv.slice(2)
process.argv[1] = tools
const assets = join(tools, 'ai/skills/universal/orchestrate/assets')
const { chainDigest } = await import(join(assets, '../../dev-flow-support/assets/run-record.mjs'))
const { buildBriefValues } = await import(join(assets, 'lane-brief-values.mjs'))
const fixture = join(tools, 'ai/schemas/fixtures')
const repo = join(temporary, 'checkpoint')
mkdirSync(repo)
const git = (...args) => execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8' }).trim()
const commit = message => git('-c', 'user.name=test', '-c', 'user.email=test@example.test', 'commit', '--allow-empty', '-qm', message)
git('init', '-q', '-b', '935-plan')
writeFileSync(join(repo, 'agent-registry.json'), JSON.stringify({ finders: [{ trusted_actor_id: '424242' }] }))
git('add', 'agent-registry.json')
commit('fixture')
const head = git('rev-parse', 'HEAD')
git('branch', '936-fences')
commit('advance planning lane')
const advanced = git('rev-parse', 'HEAD')
git('update-ref', 'refs/heads/936-fences', advanced)
const root = join(repo, '.git/dev-flow-v2')
const save = (file, data) => { mkdirSync(join(file, '..'), { recursive: true }); writeFileSync(file, typeof data === 'string' ? data : JSON.stringify(data)) }
const json = file => JSON.parse(readFileSync(file, 'utf8'))
const planDoc = json(join(fixture, 'plan/valid/interactive.json'))
const revision = planDoc.revisions[0]
const plan = revision.plan
const [planning, fences] = plan.lanes
const briefTemplate = readFileSync(join(fixture, 'brief.envelope/valid/minimal.md'), 'utf8')
const baseFacts = JSON.parse(briefTemplate.match(/```json\n([\s\S]*?)\n```/)[1])
const startedAt = '2026-08-29T09:00:00Z'
const dir = lane => join(root, 'runs', lane.run_id)
const pointerFor = lane => join(root, 'active', createHash('sha256').update(lane.branch).digest('hex') + '.json')
const adjudicate = (lane, stage, round) => save(join(dir(lane), 'adjudications', `${stage}-r${round}.json`),
  { schema: 2, run_id: lane.run_id, stage, round, reviewed_head: head, adjudications: [] })
const stages = ['kickoff', 'claim', 'implement', 'verify', 'challenge', 'review', 'security', 'integration']
function seed(lane, { current, nonce, status, statusHead, exits = {}, reservations = [], mutateFacts = () => {}, mutateRun = () => {}, extras = () => {} }) {
  const run = json(join(fixture, 'run.schema/valid/fresh-kickoff.json'))
  run.run_id = lane.run_id
  run.started_at = startedAt
  const upto = stages.slice(0, stages.indexOf(current) + 1)
  run.stage_transitions = upto.map((stage, index) => ({ stage, entered_at: `2026-08-29T09:0${index}:00Z`,
    ...(index < upto.length - 1 ? { exit: exits[stage] ?? 'fixture stage passed' } : {}) }))
  run.receipts = run.stage_transitions.slice(1).map(({ stage, entered_at }) => ({ kind: 'transition', stage, entered_at }))
  mutateRun(run)
  save(join(dir(lane), 'run.json'), run)
  save(join(dir(lane), 'owner-slate'), planDoc.slate_id)
  save(join(dir(lane), 'branch.json'), { version: 1, run_id: lane.run_id, branch: lane.branch })
  save(pointerFor(lane), { version: 1, run_id: lane.run_id, branch: lane.branch, generation: 1, registry_revision: head })
  if (reservations.length > 0) save(join(dir(lane), 'monitor.json'), { version: 1, cursor: 0, actions: reservations,
    agent_run_budget: { max_agent_runs: 2, reservations: [{ event: 'a', ordinal: 1 }, { event: 'b', ordinal: 2 }] } })
  // The dispatch-time facts come from the real brief builder, so the comparison cannot be masked
  // by a hand-built fixture (e.g. the builder's max_in_flight default for breadth).
  const builderFacts = { harness: 'other', repo_tier: 'standard', unit_kind: 'implementation', worktree_path: repo,
    ...Object.fromEntries(['harness_text', 'effort', 'codex_model_id', 'codex_launch_flags', 'scratch_dir', 'gate_bounds_override',
      'gate_commands', 'git_sandbox_note', 'known_environmental_failure', 'pr_title', 'verified_facts_and_rulings'].map(key => [key, 'fixture'])),
    claim_handoff: { ...baseFacts.claim_handoff, branch: lane.branch },
    fence_notes: { 'orchestrate/SKILL.md': { planning: 'dispatch note', fences: 'other dispatch note' } } }
  const { envelope } = buildBriefValues({ plan, lane, facts: builderFacts, nonce, at: startedAt, generation: 1,
    active: pointerFor(lane), runDir: dir(lane), defaultBranch: 'main' })
  const facts = structuredClone(envelope)
  mutateFacts(facts)
  save(join(dir(lane), `lane-brief-${nonce}.md`), briefTemplate.replace(/```json\n[\s\S]*?\n```/, '```json\n' + JSON.stringify(facts) + '\n```'))
  if (status) save(join(dir(lane), `lane-status-${nonce}.json`), { seq: 4, stage: current === 'kickoff' ? 'implement' : current, round: 1,
    head: statusHead, updated_at: '2026-08-29T10:00:00Z', summary: `fixture ${status.state}`, ...status })
  extras()
}
// Lane A: completed detached verification, challenge in progress, asking for an approval decision.
seed(planning, { current: 'challenge', nonce: 'a1', statusHead: advanced, status: { state: 'decision-request', request_id: 'DR-approve-push' },
  exits: { verify: 'VERIFY-EXIT=0 (detached gate completed)' },
  mutateRun: run => { run.cap_authorizations = [{ stage: 'challenge', round: 6, actor: 'maintainer', instruction: 'one more round', at: '2026-08-29T09:30:00Z' }] },
  extras: () => { for (let round = 1; round <= 5; round += 1) adjudicate(planning, 'challenge', round) } })
// Lane B: paused (blocked), stale lane-status head, a reservation for a moved head, review budget spent,
// and a dispatch-time fence that no longer matches the plan.
seed(fences, { current: 'review', nonce: 'b1', statusHead: head, status: { state: 'blocked' },
  reservations: [{ event: 'pending-push', action: 'push', state: 'reserved', expected_head: head }],
  mutateFacts: facts => { facts.fence = [...facts.fence, 'scripts/outside-the-plan.sh']; facts.base_sha = 'd'.repeat(40) },
  extras: () => { for (let round = 1; round <= 5; round += 1) adjudicate(fences, 'review', round) } })
save(join(root, 'slates', planDoc.slate_id, 'plan.json'), planDoc)
const snapshot = target => readdirSync(target, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name)).flatMap(entry =>
  entry.isDirectory() ? snapshot(join(target, entry.name)) : [[join(target, entry.name), readFileSync(join(target, entry.name), 'base64')]])
const invoke = (now = '2026-08-29T12:00:00Z', cwd = tools) => spawnSync('bash', [join(assets, 'dev-flow-monitor.sh'), 'resume', '--slate-id', planDoc.slate_id, '--repo-root', repo, '--now', now],
  { cwd, encoding: 'utf8' })
const republish = () => {
  revision.digest = chainDigest({ seq: revision.seq, at: revision.at, reason: revision.reason, plan: revision.plan }, 'genesis')
  save(join(root, 'slates', planDoc.slate_id, 'plan.json'), planDoc)
}
const lanesOf = result => JSON.parse(result.stdout || (console.error(result.stderr), '{}')).lanes.map(lane => lane.checkpoint)
const before = snapshot(root)
const first = invoke()
assert.equal(first.status, 0, first.stderr + first.stdout)
assert.deepEqual(snapshot(root), before, 'checkpoint wrote durable state')
const view = JSON.parse(first.stdout)
const [a, b] = view.lanes.map(lane => lane.checkpoint)
// Every listed field is present with provenance, or explicitly missing; nothing is defaulted.
for (const checkpoint of [a, b]) {
  assert.match(checkpoint.authority, /^none/)
  for (const field of ['scope', 'constraints', 'position', 'budgets', 'wall_clock', 'last_completed', 'pending_decisions', 'next', 'evidence', 'history']) {
    assert.ok(field in checkpoint, field)
  }
  for (const field of ['pending_owner_actions', 'ownership_epoch', 'next_action_vocabulary']) {
    assert.equal(checkpoint[field].status, 'missing', field)
    assert.match(checkpoint[field].reason, /#18(90|91|92)/)
  }
  assert.equal(checkpoint.budgets.integration.status, 'missing')
  assert.equal(checkpoint.next.authority, 'none')
  assert.equal(checkpoint.next.requires_live_check, true)
}
assert.deepEqual(view.checkpoint.missing.map(entry => entry.source), ['pending_owner_actions', 'ownership_epoch', 'next_action_vocabulary'])
// Approved scope, concurrency and model constraints come from the plan, with its revision pinned.
// The approved fence is projected whole: a section restriction (note) is part of the scope, not dropped.
assert.deepEqual(a.scope.fence, [{ path: 'orchestrate/SKILL.md', note: 'Planning section only' }, { path: 'plan.schema.json', note: '' }])
assert.equal(a.scope.plan_revision.seq, revision.seq)
assert.equal(a.constraints.parallel_cap, 4)
assert.equal(a.constraints.role_tiers.implementer, 'frontier')
// Operator pins are hoisted once to the slate checkpoint; a lane carries only a count and digest.
const pinsDigest = createHash('sha256').update(JSON.stringify(plan.policy.operator_pins)).digest('hex')
assert.deepEqual(a.constraints.operator_pins, { count: 1, digest: pinsDigest, same_as_slate: true })
assert.deepEqual(view.checkpoint.plan.operator_pins, { count: 1, digest: pinsDigest, values: plan.policy.operator_pins })
assert.doesNotMatch(JSON.stringify(view.lanes.map(lane => lane.checkpoint)), /Codex CLI gpt/)
assert.equal(view.checkpoint.evaluated_at, '2026-08-29T12:00:00Z')
assert.equal(a.evaluated_at, '2026-08-29T12:00:00Z')
// The brief builder defaults breadth.max_in_flight; the plan omits it, so that must not read as changed scope.
assert.equal(a.constraints.breadth.max_in_flight, 4)
// The slate rollup applies the same max_in_flight rule as the lane comparison.
assert.equal(view.checkpoint.plan.breadth.max_in_flight, 4)
assert.equal(a.scope.base_sha, plan.base_sha)
assert.equal(a.scope.base_sha_source, 'plan.base_sha')
assert.deepEqual(a.conflicts, [])
// Lane A: completed detached verification is the last completed action; the pending approval is surfaced.
assert.deepEqual([a.last_completed.stage, a.last_completed.exit], ['verify', 'VERIFY-EXIT=0 (detached gate completed)'])
assert.deepEqual(a.pending_decisions, [{ kind: 'decision-request', request_id: 'DR-approve-push', stage: 'challenge', round: 1, source: 'lane-status' }])
assert.equal(a.next.action, 'answer-decision-request')
assert.equal(a.next.detail, 'DR-approve-push')
assert.equal(a.position.freshness, 'current')
// A cap authorization raises the ceiling; five adjudicated rounds of six leaves one.
assert.deepEqual([a.budgets.challenge.cap, a.budgets.challenge.authorized_ceiling, a.budgets.challenge.remaining, a.budgets.challenge.exhausted], [5, 6, 1, false])
assert.equal(a.budgets.agent_runs.status, 'missing')
assert.deepEqual(a.conditions.map(entry => entry.kind), [])
// Lane B: paused, stale heads, exhausted budget, changed scope. The reservation outranks everything else.
assert.equal(b.position.freshness, 'stale')
assert.deepEqual(b.conditions.map(entry => entry.kind).sort(), ['budget-exhausted', 'budget-exhausted', 'scope-changed', 'stale-head', 'stale-reservation'])
assert.deepEqual(b.conflicts.map(entry => entry.field), ['base_sha', 'fence', 'lane_status.head'])
assert.ok(b.conflicts[1].brief.some(item => item.path === 'scripts/outside-the-plan.sh'))
assert.equal(b.budgets.review.exhausted, true)
assert.deepEqual(b.budgets.agent_runs, { max: 2, reserved: 2, remaining: 0, source: 'runs/<run>/monitor.json agent_run_budget' })
assert.equal(b.next.action, 'reconcile-reservation')
assert.deepEqual(b.pending_decisions.map(entry => entry.kind).sort(), ['lane-blocked', 'unreconciled-reservation'])
// The wall-clock ceiling is derived from started_at + caps; a later clock surfaces expiry, never silently continues.
assert.equal(a.wall_clock.deadline, '2026-08-29T17:00:00Z')
assert.equal(a.wall_clock.expired, false)
const expired = lanesOf(invoke('2026-08-30T00:00:00Z'))[0]
assert.equal(expired.wall_clock.expired, true)
assert.equal(expired.evaluated_at, '2026-08-30T00:00:00Z')
const badNow = spawnSync('bash', [join(assets, 'dev-flow-monitor.sh'), 'resume', '--slate-id', planDoc.slate_id, '--repo-root', repo, '--now', 'tomorrow'], { encoding: 'utf8' })
assert.equal(badNow.status, 1)
assert.match(badNow.stderr, /--now must be a UTC timestamp/)
// The environment never supplies a clock.
const envClock = spawnSync('bash', [join(assets, 'dev-flow-monitor.sh'), 'resume', '--slate-id', planDoc.slate_id, '--repo-root', repo, '--now', '2026-08-29T12:00:00Z'],
  { encoding: 'utf8', env: { ...process.env, DEV_FLOW_RESUME_NOW: '2026-08-31T00:00:00Z' } })
assert.equal(JSON.parse(envClock.stdout).lanes[0].checkpoint.wall_clock.expired, false)
assert.equal(expired.next.action, 'report-deadline-blocker')
// Slate rollup.
assert.equal(view.checkpoint.pending_decisions, 3)
assert.deepEqual(view.checkpoint.next, [{ lane: 'planning', action: 'answer-decision-request' }, { lane: 'fences', action: 'reconcile-reservation' }])
// Fresh context: only the projection and its linked canonical evidence identify the next action.
const fresh = JSON.parse(invoke(undefined, temporary).stdout)
const target = fresh.lanes[0].checkpoint
const linked = json(target.evidence.lane_status)
assert.equal(linked.state, 'decision-request')
assert.equal(linked.request_id, target.next.detail)
assert.equal(json(target.evidence.run).stage_transitions.at(-1).stage, target.position.stage)
assert.equal(readFileSync(target.evidence.brief, 'utf8').includes(target.evidence.report), true)
// Restart/compaction: a rebuilt invocation with all session state gone is identical.
assert.deepEqual(fresh, view)
// Compaction: history growth changes counts, not size, and never embeds past rounds or logs.
save(join(dir(planning), 'passes', 'challenge-r6-codex.json'), '{"log":"x"}')
const size = JSON.stringify(JSON.parse(invoke().stdout).lanes[0].checkpoint).length
const grown = json(join(dir(planning), 'run.json'))
grown.interventions = Array.from({ length: 300 }, (_, index) => ({ kind: 'other', at: '2026-08-29T10:00:00Z', note: `historic intervention ${index}` }))
save(join(dir(planning), 'run.json'), grown)
for (let round = 7; round <= 206; round += 1) save(join(dir(planning), 'passes', `challenge-r${round}-codex.json`), '{"log":"x"}')
const after = JSON.parse(invoke().stdout).lanes[0].checkpoint
assert.equal(after.history.interventions, 300)
assert.equal(after.history.pass_files, 201)
assert.ok(JSON.stringify(after).length - size < 120, `checkpoint grew by ${JSON.stringify(after).length - size} bytes`)
assert.doesNotMatch(JSON.stringify(after), /historic intervention/)
// Stale head after the lane advances: the saved status stays historical evidence and surfaces the drift.
git('update-ref', 'refs/heads/935-plan', head)
const drifted = JSON.parse(invoke().stdout).lanes[0].checkpoint
assert.equal(drifted.position.freshness, 'stale')
assert.ok(drifted.conditions.some(entry => entry.kind === 'stale-head'))
// A stale saved status is never the basis for `next`; the disagreement is surfaced instead.
assert.equal(drifted.next.action, 'verify-live-state')
assert.ok(drifted.conflicts.some(entry => entry.field === 'lane_status.head'))
git('update-ref', 'refs/heads/935-plan', advanced)
// A run.json stage that disagrees with the lane status is the same kind of disagreement.
const statusFile = join(dir(planning), 'lane-status-a1.json')
const savedStatus = json(statusFile)
save(statusFile, { ...savedStatus, stage: 'review' })
const mismatched = lanesOf(invoke())[0]
assert.ok(mismatched.conditions.some(entry => entry.kind === 'status-stage-mismatch'))
assert.ok(mismatched.conflicts.some(entry => entry.field === 'lane_status.stage'))
assert.equal(mismatched.next.action, 'verify-live-state')
save(statusFile, savedStatus)
assert.equal(lanesOf(invoke())[0].next.action, 'answer-decision-request')
// A changed section note on a fenced item is a scope change even though the paths are identical.
planning.fence[0] = { ...planning.fence[0], note: 'Planning section rewritten' }
republish()
const renoted = lanesOf(invoke())[0]
assert.deepEqual(renoted.conflicts.map(entry => entry.field), ['fence'])
assert.deepEqual(renoted.scope.fence, [{ path: 'orchestrate/SKILL.md', note: 'Planning section rewritten' }, { path: 'plan.schema.json', note: '' }])
planning.fence[0] = { ...planning.fence[0], note: 'Planning section only' }
republish()
assert.deepEqual(lanesOf(invoke())[0].conflicts, [])
// Key order is not meaning: the same caps, tiers and breadth in another key order is no scope change.
const reorder = value => Object.fromEntries(Object.keys(value).reverse().map(key => [key, value[key]]))
const originalPolicy = plan.policy
plan.policy = { ...plan.policy, role_tiers: reorder(plan.policy.role_tiers), ...(plan.policy.breadth ? { breadth: reorder(plan.policy.breadth) } : {}) }
if (plan.policy.caps) plan.policy.caps = reorder(plan.policy.caps)
republish()
assert.notEqual(JSON.stringify(plan.policy.role_tiers), JSON.stringify(originalPolicy.role_tiers))
assert.deepEqual(lanesOf(invoke())[0].conflicts, [])
plan.policy = originalPolicy
republish()
// Revision metadata comes from the one validated plan read, never a second read of plan.json.
const resumeSource = readFileSync(join(assets, 'resume-slate.mjs'), 'utf8')
assert.equal(resumeSource.match(/readJson\(planFile/g).length, 1)
assert.doesNotMatch(resumeSource, /currentPlan/)
// A lane's own base_sha (valid on a conductor lane only when equal to the plan's) is the scope base and is named as such.
planning.base_sha = plan.base_sha
republish()
const laneBased = lanesOf(invoke())[0]
assert.equal(laneBased.scope.base_sha, plan.base_sha)
assert.equal(laneBased.scope.base_sha_source, 'plan.lanes[].base_sha')
assert.deepEqual(laneBased.conflicts, [])
delete planning.base_sha
republish()
// Changed approval scope: a newer plan fence no longer matches the dispatched brief.
planning.fence.push('scripts/expanded.sh')
republish()
const rescoped = JSON.parse(invoke().stdout).lanes[0].checkpoint
assert.deepEqual(rescoped.conflicts.map(entry => entry.field), ['fence'])
assert.ok(rescoped.scope.fence.some(item => item.path === 'scripts/expanded.sh' && item.note === ''))
// A partial or malformed agent-run budget fails closed instead of reading as a number.
const monitorFile = join(dir(fences), 'monitor.json')
const monitor = json(monitorFile)
for (const budget of [{ reservations: monitor.agent_run_budget.reservations }, { max_agent_runs: '2', reservations: [] }, { max_agent_runs: 2, reservations: 'a' },
  { max_agent_runs: 2, reservations: [null] }, { max_agent_runs: 2, reservations: [{ event: 'a', ordinal: 'x' }] },
  { max_agent_runs: 2, reservations: [{ ordinal: 1 }] }]) {
  save(monitorFile, { ...monitor, agent_run_budget: budget })
  const malformed = lanesOf(invoke())[1]
  assert.equal(malformed.budgets.agent_runs.status, 'missing')
  assert.match(malformed.budgets.agent_runs.reason, /malformed agent_run_budget/)
  assert.ok(!malformed.conditions.some(entry => entry.stage === 'agent-runs'))
}
save(monitorFile, monitor)
// A reservation for a moved head is stale even when no lane status was ever saved.
rmSync(join(dir(fences), 'lane-status-b1.json'))
const noStatus = lanesOf(invoke())[1]
assert.equal(noStatus.position.freshness, null)
assert.ok(noStatus.conditions.some(entry => entry.kind === 'stale-reservation'))
assert.equal(noStatus.position.heads.local_branch, advanced)
// A freshly provisioned lane has run stage kickoff while its status can only say implement: that is no mismatch.
const lanesFor = outcome => JSON.parse(outcome.stdout).lanes
const stageCase = (options, mutate = () => {}) => {
  // Start each case from a lane with no leftover reservation or adjudicated rounds.
  rmSync(join(dir(fences), 'monitor.json'), { force: true })
  rmSync(join(dir(fences), 'adjudications'), { recursive: true, force: true })
  seed(fences, { nonce: 'b1', statusHead: advanced, ...options })
  mutate()
  const lane = lanesFor(invoke())[1].checkpoint
  return lane
}
const fresh0 = stageCase({ current: 'kickoff', status: { state: 'working' } })
assert.ok(!fresh0.conditions.some(entry => entry.kind === 'status-stage-mismatch'), JSON.stringify(fresh0.conditions))
assert.equal(fresh0.next.action, 'await-lane')
// The handoff window: the lane reports integration before the owner records the transition out of security.
const window = stageCase({ current: 'security', status: { state: 'handoff', stage: 'integration' } })
assert.ok(!window.conditions.some(entry => entry.kind === 'status-stage-mismatch'), JSON.stringify(window.conditions))
assert.equal(window.next.action, 'run-integration')
// A newer status naming a different stage than the run is still a mismatch,
const stageClash = stageCase({ current: 'challenge', status: { state: 'working', stage: 'review' } })
assert.ok(stageClash.conditions.some(entry => entry.kind === 'status-stage-mismatch'))
assert.equal(stageClash.next.action, 'verify-live-state')
// an older status predates the run's current stage and says nothing about it,
const olderStatus = stageCase({ current: 'challenge', status: { state: 'working', stage: 'verify', updated_at: '2026-08-29T08:00:00Z' } })
assert.ok(!olderStatus.conditions.some(entry => entry.kind === 'status-stage-mismatch'))
// and handoff is compatible only with the stage it leads, not with an unrelated run stage.
const wrongWindow = stageCase({ current: 'verify', status: { state: 'handoff', stage: 'integration' } })
assert.ok(wrongWindow.conditions.some(entry => entry.kind === 'status-stage-mismatch'))
// An exited stage that used its whole cap is history, not a live budget condition.
const exitedCap = stageCase({ current: 'review', status: { state: 'working', stage: 'review' } }, () => {
  for (let round = 1; round <= 5; round += 1) adjudicate(fences, 'challenge', round)
})
assert.equal(exitedCap.budgets.challenge.exhausted, true)
assert.ok(!exitedCap.conditions.some(entry => entry.kind === 'budget-exhausted' && entry.stage === 'challenge'), JSON.stringify(exitedCap.conditions))
// while the same exhausted budget on the stage still in progress is a live one.
const liveCap = stageCase({ current: 'challenge', status: { state: 'working', stage: 'challenge' } }, () => {
  for (let round = 1; round <= 5; round += 1) adjudicate(fences, 'challenge', round)
})
assert.ok(liveCap.conditions.some(entry => entry.kind === 'budget-exhausted' && entry.stage === 'challenge'))
// `--now` and `evaluated_at` round-trip at one precision, and an explicit empty `--now` is refused rather than defaulted.
const wallClock = spawnSync('bash', [join(assets, 'dev-flow-monitor.sh'), 'resume', '--slate-id', planDoc.slate_id, '--repo-root', repo],
  { encoding: 'utf8' })
const evaluated = JSON.parse(wallClock.stdout).checkpoint.evaluated_at
assert.match(evaluated, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/)
const roundTrip = JSON.parse(invoke(evaluated).stdout)
assert.equal(roundTrip.checkpoint.evaluated_at, evaluated)
const emptyNow = spawnSync('bash', [join(assets, 'dev-flow-monitor.sh'), 'resume', '--slate-id', planDoc.slate_id, '--repo-root', repo, '--now', ''],
  { encoding: 'utf8' })
assert.equal(emptyNow.status, 2, emptyNow.stdout + emptyNow.stderr)
assert.match(emptyNow.stderr, /--now requires a UTC timestamp/)
assert.equal(emptyNow.stdout, '')
// An unusable lane is that lane's blocker; the rest of the slate still reports a checkpoint and rolls up.
rmSync(join(dir(fences), 'branch.json'))
const broken = invoke()
assert.equal(broken.status, 1)
const brokenView = JSON.parse(broken.stdout)
assert.ok(brokenView.blockers.some(entry => entry.lane === 'fences'))
assert.equal(brokenView.lanes.length, 1)
assert.equal(brokenView.lanes[0].checkpoint.next.action, 'answer-decision-request')
assert.equal(brokenView.checkpoint.lanes, 1)
assert.deepEqual(brokenView.checkpoint.blocked.map(entry => entry.lane), ['fences'])
assert.ok(brokenView.checkpoint.attention.some(entry => entry.lane === 'fences' && entry.kind === 'resume-blocked'))
// An undispatched lane (no run record and no surviving dispatch evidence) is part of the rollup.
rmSync(dir(fences), { recursive: true })
rmSync(pointerFor(fences))
const undispatched = invoke()
assert.equal(undispatched.status, 0, undispatched.stderr)
assert.deepEqual(JSON.parse(undispatched.stdout).checkpoint.undispatched, ['fences'])
console.log('  PASS: resume checkpoint projects scope, budgets, pending decisions and next action with provenance, compactly and read-only')
NODE

echo "=== All dev-flow-monitor trust contract tests passed ==="
