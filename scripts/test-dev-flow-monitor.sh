#!/usr/bin/env bash
# test-dev-flow-monitor.sh — regression tests for dev-flow-monitor.sh trust
# contract alignment: integer actor ID comparison, per-reservation governing
# revision resolution, and fail-closed behavior on absent/malformed inputs.
# Refs #780, #741.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR="$SCRIPT_DIR/dev-flow-monitor.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

pass() {
    echo "  PASS: $1"
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
}

# Helper: activate a run and return the generation
activate_run() {
    local repo="$1" run_id="$2" branch="$3" rev="$4"
    local active_state
    active_state="$("$MONITOR" active-path --branch "$branch" --repo-root "$repo")"
    "$MONITOR" activate --active-state "$active_state" --run-id "$run_id" \
        --branch "$branch" --expected-generation 0 \
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

echo "=== dev-flow-monitor.sh trust contract tests ==="

# ── Test 1: Integer allowlist acceptance ──────────────────────────
echo ""
echo "--- Integer allowlist acceptance ---"
setup_fixture '{"trusted_orchestrator_actor_ids": [12345, 67890]}'
activate_run "$FIXTURE_REPO" "run-int-accept" "test-branch" "$FIXTURE_REV" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-int-accept" "test-branch" "12345" "evt-accept")"
echo "$output" | grep -q "reserved evt-accept" ||
    fail "integer actor id 12345 should be accepted; got: $output"
pass "actor id 12345 (integer) accepted from integer allowlist"

# ── Test 2: Untrusted actor rejection ─────────────────────────────
echo ""
echo "--- Untrusted actor rejection ---"
setup_fixture '{"trusted_orchestrator_actor_ids": [12345, 67890]}'
activate_run "$FIXTURE_REPO" "run-reject" "test-branch" "$FIXTURE_REV" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-reject" "test-branch" "99999" "evt-reject" || true)"
echo "$output" | grep -q "not trusted" ||
    fail "actor id 99999 should be rejected; got: $output"
pass "actor id 99999 (not in allowlist) correctly rejected"

# ── Test 3: String allowlist elements are malformed ───────────────
echo ""
echo "--- String allowlist elements rejected (malformed) ---"
setup_fixture '{"trusted_orchestrator_actor_ids": ["12345", "67890"]}'
activate_run "$FIXTURE_REPO" "run-string-reject" "test-branch" "$FIXTURE_REV" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-string-reject" "test-branch" "12345" "evt-string" || true)"
echo "$output" | grep -q "not trusted" ||
    fail "string allowlist should be treated as malformed; got: $output"
pass "allowlist with string elements correctly rejected as malformed"

# ── Test 4: Empty allowlist fails closed ──────────────────────────
echo ""
echo "--- Empty allowlist fails closed ---"
setup_fixture '{"trusted_orchestrator_actor_ids": []}'
activate_run "$FIXTURE_REPO" "run-empty" "test-branch" "$FIXTURE_REV" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-empty" "test-branch" "12345" "evt-empty" || true)"
echo "$output" | grep -q "not trusted" ||
    fail "empty allowlist should fail closed; got: $output"
pass "empty allowlist correctly fails closed"

# ── Test 5: Absent allowlist fails closed ─────────────────────────
echo ""
echo "--- Absent allowlist fails closed ---"
setup_fixture '{}'
activate_run "$FIXTURE_REPO" "run-absent" "test-branch" "$FIXTURE_REV" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-absent" "test-branch" "12345" "evt-absent" || true)"
echo "$output" | grep -q "not trusted" ||
    fail "absent allowlist should fail closed; got: $output"
pass "absent trusted_orchestrator_actor_ids correctly fails closed"

# ── Test 6: Per-write governing revision changes ─────────────────
echo ""
echo "--- Per-write governing revision changes ---"
setup_fixture '{"trusted_orchestrator_actor_ids": [12345]}'
activate_run "$FIXTURE_REPO" "run-rev-change" "test-branch" "$FIXTURE_REV" >/dev/null
rev_before="$FIXTURE_REV"

output="$(try_comment_reservation "$FIXTURE_REPO" "run-rev-change" "test-branch" "12345" "evt-rev1")"
echo "$output" | grep -q "reserved evt-rev1" ||
    fail "first reservation should succeed; got: $output"
pass "reservation 1 accepted with governing revision $rev_before"

update_origin_registry "$FIXTURE_REPO" '{"trusted_orchestrator_actor_ids": [67890]}'
rev_after="$(git -C "$FIXTURE_REPO" log -1 --format='%H' origin/main -- agent-registry.json)"
[ "$rev_before" != "$rev_after" ] ||
    fail "registry revision should have changed after update"

output="$(try_comment_reservation "$FIXTURE_REPO" "run-rev-change" "test-branch" "12345" "evt-rev2" || true)"
echo "$output" | grep -q "not trusted" ||
    fail "actor 12345 should be rejected after registry update removed it; got: $output"
pass "reservation 2 correctly uses updated governing revision (actor removed)"

output="$(try_comment_reservation "$FIXTURE_REPO" "run-rev-change" "test-branch" "67890" "evt-rev3")"
echo "$output" | grep -q "reserved evt-rev3" ||
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
git -C "$FIXTURE_REPO" commit -q -m "local-only registry"
local_rev="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
activate_run "$FIXTURE_REPO" "run-no-origin-reg" "test-branch" "$local_rev" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-no-origin-reg" "test-branch" "12345" "evt-no-reg" || true)"
echo "$output" | grep -q "no agent-registry.json revision found" ||
    fail "should fail when no registry on default branch; got: $output"
pass "correctly fails closed when no agent-registry.json exists on origin/main"

# ── Test 8: Float in allowlist is malformed ───────────────────────
echo ""
echo "--- Float in allowlist rejected (malformed) ---"
setup_fixture '{"trusted_orchestrator_actor_ids": [12345.5, 67890]}'
activate_run "$FIXTURE_REPO" "run-float" "test-branch" "$FIXTURE_REV" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-float" "test-branch" "67890" "evt-float" || true)"
echo "$output" | grep -q "not trusted" ||
    fail "float in allowlist should be malformed; got: $output"
pass "allowlist containing a float correctly rejected as malformed"

# ── Test 9: Zero in allowlist is malformed ────────────────────────
echo ""
echo "--- Zero in allowlist rejected (malformed) ---"
setup_fixture '{"trusted_orchestrator_actor_ids": [0, 67890]}'
activate_run "$FIXTURE_REPO" "run-zero" "test-branch" "$FIXTURE_REV" >/dev/null

output="$(try_comment_reservation "$FIXTURE_REPO" "run-zero" "test-branch" "67890" "evt-zero" || true)"
echo "$output" | grep -q "not trusted" ||
    fail "zero in allowlist should be malformed; got: $output"
pass "allowlist containing zero correctly rejected as malformed"

echo ""
echo "=== All dev-flow-monitor trust contract tests passed ==="
