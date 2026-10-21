#!/usr/bin/env bash
# ai/skills/universal/orchestrate/assets/test-dev-flow-monitor.sh — regression tests for ai/skills/universal/orchestrate/assets/dev-flow-monitor.sh trust
# contract alignment: integer actor ID comparison, per-reservation governing
# revision resolution, and fail-closed behavior on absent/malformed inputs.
# Refs #780, #741.
set -euo pipefail

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

    FIXTURE_REPO="$base/work"
    FIXTURE_REV="$(git -C "$FIXTURE_REPO" log -1 --format='%H' origin/main -- agent-registry.json)"
    return 0
}

# Helper: activate a run and return the generation
activate_run() {
    local repo="$1" run_id="$2" branch="$3" rev="$4"
    local active_state
    active_state="$("$MONITOR" active-path --branch "$branch" --repo-root "$repo")"
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
generation="$(activate_run "$FIXTURE_REPO" run-retire-next retire-branch "$FIXTURE_REV")"
[ "$generation" = 1 ] || fail "a new run on the retired branch did not restart at generation 1: $generation"
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

activate_run "$FIXTURE_REPO" run-retire-held held-branch "$FIXTURE_REV" >/dev/null
held_pointer="$("$MONITOR" active-path --branch held-branch --repo-root "$FIXTURE_REPO")"
held_record="$(dirname "$("$MONITOR" state-path --run-id run-retire-held --repo-root "$FIXTURE_REPO")")/run.json"
mkdir -p "$(dirname "$held_record")"
jq -n '{schema: 2, run_id: "run-retire-held", outcome: "abandoned"}' >"$held_record"
held_lock="${held_pointer}.lock"
owner_start="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$$" 2>/dev/null | sed 's/^ *//;s/ *$//')"
[ -n "$owner_start" ] || fail "could not read the test lock owner's process start"
printf '%s|%s|%s|test-owner|%s\n' "$$" "$(hostname)" "$(id -u)" "$owner_start" >"$held_lock"
"$MONITOR" retire --run-id run-retire-held --repo-root "$FIXTURE_REPO" >"$tmp/retire-held.log" 2>&1 &
retire_pid=$!
sleep 0.2
held_before_release=0
[ -f "$held_pointer" ] && held_before_release=1
rm -f "$held_lock"
retire_rc=0
wait "$retire_pid" || retire_rc=$?
[ "$held_before_release" -eq 1 ] || fail "retire did not wait for the held pointer lock"
[ "$retire_rc" -eq 0 ] || fail "retire did not complete after lock release: $(cat "$tmp/retire-held.log")"
[ ! -e "$held_pointer" ] || fail "retire left the pointer after the lock was released"
pass "retire waits for the existing pointer lock before deleting"

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
echo "=== All dev-flow-monitor trust contract tests passed ==="
