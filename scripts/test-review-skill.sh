#!/usr/bin/env bash
# Regression coverage for the /review stage's durable-record hand-off.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}
sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}
skill="ai/skills/universal/review/SKILL.md"
fixture="ai/schemas/fixtures/exit/single-round-clean-converge"
render_record="ai/schemas/fixtures/render/record"
monitor="scripts/dev-flow-monitor.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> review skill names both role dispatches and record authority"
for text in '[stage.challenge].finders' '[stage.review].finders' challenger reviewer \
    'scripts/dev-flow-exit.sh' 'scripts/render-dev-flow.sh' 'scripts/round-push.sh' \
    'run.json.evidence_comments' 'fenced JSON' 'git remote get-url origin' \
    'gh repo view "$origin_url"' 'inline confidence-stage procedure' \
    'validated finding records' 'override it upward' 'run.json.interventions'; do
    grep -Fq "$text" "$skill" || fail "review skill is missing $text"
done
grep -Fq 'display login is non-authoritative metadata' "$skill" ||
    fail "review skill treats mutable display login as evidence identity"
grep -Fq 'Immediately before that remediation dispatch' "$skill" ||
    fail "review skill does not enforce breadth before remediation"
grep -Fq 'Immediately before every implementer invocation' ai/skills/universal/orchestrator/SKILL.md ||
    fail "orchestrator skill does not account for total agent-run breadth"
grep -Fq 'never consume `[breadth].max_agent_runs`' "$skill" ||
    fail "review skill charges confidence finders to the implementer budget"
for text in 'mandatory round-two scaffolding checkpoint' \
    'A rewrite of `continue`, remediation, or exit handling must preserve' \
    'publish only the verified or corrected provenance and fingerprint values' \
    'publish a terminal blocker instead' \
    'must finish before reserving any comment' \
    'Never reserve an oversized unsplit body' \
    "candidates' run, head, role, finder"; do
    grep -Fq "$text" "$skill" || fail "review invariant is missing: $text"
done
grep -Fq 'resolved cap is `0`' "$skill" ||
    fail "review skill does not skip finder dispatch for a disabled stage"
grep -Fq 'wall_clock_min' ai/skills/universal/orchestrator/SKILL.md ||
    fail "orchestrator skill does not enforce the whole-run wall-clock ceiling"
for text in 'Retry an unavailable primary' 'already active dev-flow-v2 run' \
    'session-lifetime persistent monitor primitive' 'distinct_families' \
    'assembly.canonical_head' 'adopt the existing entry without appending' \
    'sole external action still authorized'; do
    grep -Fq "$text" "$skill" ai/skills/universal/implement/SKILL.md \
        ai/skills/universal/orchestrator/SKILL.md ||
        fail "review workflow documentation is missing $text"
done
entry_gate_line="$(grep -n '^## Entry gate$' "$skill" | cut -d: -f1)"
dispatch_line="$(grep -n '^## Dispatch and receipt$' "$skill" | cut -d: -f1)"
[ -n "$entry_gate_line" ] && [ -n "$dispatch_line" ] && [ "$entry_gate_line" -lt "$dispatch_line" ] ||
    fail "review skill does not fail topology before dispatch"
for role in challenger reviewer; do
    agent="ai/agents/$role.md"
    grep -Fq "ai/schemas/result.$role.schema.json" "$agent" ||
        fail "$role does not name its result schema"
    grep -Fq 'scripts/validate-result-schemas.mjs envelope ... --receipt' "$agent" ||
        fail "$role does not validate its full result envelope before handoff"
    grep -Fq 'validated finding records' "$agent" ||
        fail "$role cannot compare finding provenance across rounds"
done
grep -Fq 'synthesis_of' ai/skills/universal/orchestrator/SKILL.md ||
    fail "orchestrator skill does not preserve council synthesis provenance"
for model_skill in "$skill" ai/skills/universal/orchestrator/SKILL.md; do
    ! grep -Fq 'disable-model-invocation: true' "$model_skill" ||
        fail "$model_skill is not model-invocable"
    grep -Fq 'Use when' "$model_skill" || fail "$model_skill has no model discovery trigger"
done
! grep -Eq '(^|[[:space:]])flock([[:space:]]|$)' "$monitor" ||
    fail "monitor depends on non-portable flock"
grep -Fq 'shasum -a 256' "$monitor" || fail "monitor has no stock-macOS SHA-256 fallback"

echo "==> fixture-driven review-stage dry run converges"
set +e
out="$(node scripts/dev-flow-exit.mjs --run "$fixture/run" --stage review \
    --policy "$fixture/policy.toml" --current-head \
    "$(jq -r '.head' "$fixture/run/passes/review-r1-codex-cli.json")" --json)"
status=$?
set -e
[ "$status" -eq 20 ] || fail "expected converged exit 20, got $status"
jq -e '.outcome == "converged" and .reason == "empty_round" and .rounds_counted == 1' \
    <<<"$out" >/dev/null || fail "fixture exit verdict differs: $out"

echo "==> a multi-finder logical round spends one unit of the cap, with one receipt per pass"
# #796 acceptance: /review runs every finder in the stage's `finders` array for
# a round, writes one receipt per finder pass, and advances the cap by ONE.
# The two fixtures below are the dry runs for that — a two-finder round and a
# single-finder round of a different family. The pair is Codex+Copilot rather
# than Codex+CodeRabbit because CodeRabbit is registered PR-side only: its CLI
# takes no target from us, so a local pass could not be bound to the round's
# reviewed_head (see docs/guides/codex-review.md). The Codex+CodeRabbit
# multi-finder round is covered where it is actually supported — the
# integration stage, in scripts/test-integrate-readiness.sh.
multi_fixture="ai/schemas/fixtures/exit/multi-finder-round-codex-and-copilot"
solo_fixture="ai/schemas/fixtures/exit/copilot-only-round"
multi_head="$(jq -r '."current-head"' "$multi_fixture/invoke.json")"

policy_resolve() {
    # --registry and --task-targets are not optional here: without them the
    # reader exits 3 (indeterminate — nothing to cross-validate finder slugs
    # against), and a per-run finder request that is never cross-validated is
    # exactly the hole these cases exist to close.
    node scripts/devflow-policy.mjs resolve --policy "$1/policy.toml" \
        --registry "$1/registry.json" --task-targets "$1/task-targets.json" \
        --json "${@:2}"
}
[ "$(jq -r '.stages.review.finders | length' <<<"$(policy_resolve "$multi_fixture")")" -eq 2 ] ||
    fail "the multi-finder fixture does not configure two review-stage primaries"
[ "$(find "$multi_fixture/run/passes" -name 'review-r1-*.json' | wc -l)" -eq 2 ] ||
    fail "a two-finder round did not write one pass receipt per finder"
[ "$(jq -r '[.receipts[] | select(.kind == "pass")] | length' "$multi_fixture/run/run.json")" -eq 2 ] ||
    fail "a two-finder round did not record one pass receipt per finder in run.json"

set +e
multi_out="$(node scripts/dev-flow-exit.mjs --run "$multi_fixture/run" --stage review \
    --policy "$multi_fixture/policy.toml" --current-head "$multi_head" --json)"
status=$?
set -e
[ "$status" -eq 20 ] || fail "multi-finder round did not converge (exit $status): $multi_out"
jq -e '.rounds_counted == 1' <<<"$multi_out" >/dev/null ||
    fail "a round with two finders spent more than one unit of the review cap: $multi_out"

echo "==> a single-finder round of a different family converges the same way"
solo_head="$(jq -r '."current-head"' "$solo_fixture/invoke.json")"
[ "$(jq -r '.stages.review.finders[0]' <<<"$(policy_resolve "$solo_fixture")")" = copilot-verification ] ||
    fail "the Copilot-only fixture does not configure copilot-verification"
set +e
solo_out="$(node scripts/dev-flow-exit.mjs --run "$solo_fixture/run" --stage review \
    --policy "$solo_fixture/policy.toml" --current-head "$solo_head" --json)"
status=$?
set -e
[ "$status" -eq 20 ] || fail "Copilot-only round did not converge (exit $status): $solo_out"
jq -e '.rounds_counted == 1' <<<"$solo_out" >/dev/null ||
    fail "a one-finder round did not spend exactly one unit of the review cap: $solo_out"

echo "==> a per-run finder request adds to the config and can never remove from it"
selection="$(policy_resolve "$solo_fixture" --add-finder review:codex-verification)"
jq -e '.stages.review.finders == ["copilot-verification", "codex-verification"]' \
    <<<"$selection" >/dev/null ||
    fail "an added finder did not join the configured set: $selection"
narrowed="$(policy_resolve "$multi_fixture" --select-finder review:codex-verification)"
jq -e '.stages.review.finders == ["codex-verification", "copilot-verification"] and
    (.finder_selection[0].retained_despite_selection == ["copilot-verification"])' \
    <<<"$narrowed" >/dev/null ||
    fail "a narrower per-run selection removed a config-required finder: $narrowed"
echo "==> a per-run addition is registry-checked but never charged to breadth"
# crossValidate sizes a stage's worst-case finder attempts against
# [breadth].max_agent_runs, and the skill says in terms that confidence
# finders never consume that budget. Applying the selection before that
# arithmetic made an otherwise valid tight policy fail for adding a finder —
# the one thing per-run selection is for.
tight_policy="$tmp/tight-breadth.toml"
sed 's/^max_agent_runs = 8$/max_agent_runs = 2/; s/^max_parallel_agents = 3$/max_parallel_agents = 2/' \
    "$solo_fixture/policy.toml" >"$tight_policy"
node scripts/devflow-policy.mjs resolve --policy "$tight_policy" \
    --registry "$solo_fixture/registry.json" --task-targets "$solo_fixture/task-targets.json" \
    --json >/dev/null ||
    fail "the tight-breadth policy is not valid on its own, so the case proves nothing"
node scripts/devflow-policy.mjs resolve --policy "$tight_policy" \
    --registry "$solo_fixture/registry.json" --task-targets "$solo_fixture/task-targets.json" \
    --add-finder review:codex-verification --json >/dev/null ||
    fail "adding a finder was charged against [breadth].max_agent_runs"
set +e
unknown_add="$(node scripts/devflow-policy.mjs resolve --policy "$tight_policy" \
    --registry "$solo_fixture/registry.json" --task-targets "$solo_fixture/task-targets.json" \
    --add-finder review:not-a-registered-finder 2>&1)"
status=$?
set -e
[ "$status" -eq 1 ] || fail "an unregistered per-run addition resolved cleanly (exit $status)"
grep -Fq 'per-run selection adds unknown finder' <<<"$unknown_add" ||
    fail "an added finder is no longer registry-checked: $unknown_add"

echo "==> a per-run finder selection reaches the exit computation, not just the resolver"
# devflow-policy.mjs applies --add-finder to its own in-memory result;
# dev-flow-exit.mjs re-resolves the same policy file independently. Without the
# identical union there, an added finder is not a slot: its pass and findings
# are dropped and the round can report converged on the configured slots alone.
set +e
added_slot_out="$(node scripts/dev-flow-exit.mjs --run "$solo_fixture/run" --stage review \
    --policy "$solo_fixture/policy.toml" --current-head "$solo_head" \
    --add-finder review:codex-verification --json)"
status=$?
set -e
[ "$status" -eq 2 ] ||
    fail "an added finder was not treated as a round slot by the exit computation (exit $status): $added_slot_out"
jq -e '.outcome == "indeterminate" and (.reason | contains("codex-verification"))' \
    <<<"$added_slot_out" >/dev/null ||
    fail "the exit computation did not demand the added finder's own slot: $added_slot_out"

echo "==> the effective finder set renders as a disclosure under the rigor line"
disclosure_record="$tmp/finder-disclosure"
mkdir -p "$disclosure_record"
jq -n '{rigor:{level:"standard",source:"default_rigor"},
        rounds:{challenge:3,review:3,integration:2,remediation:2,min_rounds:1},
        disclosures:[{kind:"finders",
          detail:"review: codex-verification, copilot-verification (config: codex-verification; added this run: copilot-verification)"}]}' \
    >"$disclosure_record/policy.json"
disclosure_out="$(scripts/render-dev-flow.sh policy-disclosure --record "$disclosure_record")"
grep -Fq 'rigor: `standard`' <<<"$disclosure_out" ||
    fail "the rigor line did not render: $disclosure_out"
grep -Fq -- '- finders: review: codex-verification, copilot-verification' <<<"$disclosure_out" ||
    fail "the effective finder set was not disclosed beside the caps: $disclosure_out"

for text in 'spends **one** unit of the stage' 'Per-run finder selection' \
    'never remove one the configuration requires' \
    'never repository content' 'disclosures[]` entry of kind `finders`' \
    'Pass the same flags to'; do
    grep -Fq "$text" "$skill" || fail "review skill is missing the multi-finder rule: $text"
done

echo "==> pre-adjudication verification remains distinct from an exit"
pre_record="$tmp/pre-adjudication"
mkdir -p "$pre_record/passes"
cp "$fixture/run/run.json" "$pre_record/run.json"
cp "$fixture/run/passes/review-r1-codex-cli.json" "$pre_record/passes/"
set +e
pre_out="$(node scripts/dev-flow-exit.mjs --run "$pre_record" --stage review \
    --policy "$fixture/policy.toml" --current-head \
    "$(jq -r '.head' "$fixture/run/passes/review-r1-codex-cli.json")" --verification-only --json)"
status=$?
set -e
[ "$status" -eq 0 ] || fail "pre-adjudication verification failed: $pre_out"
jq -e '.outcome == "verification" and .action == "adjudicate"' <<<"$pre_out" >/dev/null ||
    fail "pre-adjudication projection was not distinct from an exit"

echo "==> pre-adjudication verification rejects a round beyond the cap"
over_cap_record="$tmp/over-cap"
mkdir -p "$over_cap_record/passes"
cp "$fixture/run/run.json" "$over_cap_record/run.json"
jq '.payload.round = 99' "$fixture/run/passes/review-r1-codex-cli.json" \
    >"$over_cap_record/passes/review-r1-codex-cli.json"
set +e
over_cap_out="$(node scripts/dev-flow-exit.mjs --run "$over_cap_record" --stage review \
    --policy "$fixture/policy.toml" --current-head \
    "$(jq -r '.head' "$fixture/run/passes/review-r1-codex-cli.json")" --verification-only --json)"
status=$?
set -e
[ "$status" -eq 2 ] || fail "over-cap pre-adjudication evidence returned $status"
jq -e '.outcome == "indeterminate" and (.reason | contains("exceed"))' \
    <<<"$over_cap_out" >/dev/null || fail "over-cap pre-adjudication evidence was accepted: $over_cap_out"

echo "==> pre-adjudication verification terminalizes an incomplete finder round"
incomplete_fixture="ai/schemas/fixtures/exit/finder-unavailable-one-of-two-slots"
set +e
incomplete_out="$(node scripts/dev-flow-exit.mjs --run "$incomplete_fixture/run" --stage review \
    --policy "$incomplete_fixture/policy.toml" \
    --current-head 0101010101010101010101010101010101010101 \
    --verification-only --json)"
status=$?
set -e
[ "$status" -eq 22 ] || fail "incomplete pre-adjudication round returned $status: $incomplete_out"
jq -e '.outcome == "capped" and .reason == "finder_unavailable" and
    .action == "escalate" and .incomplete_round == 1 and
    .partial_findings == ["review-r1-codex-cli-1"] and
    (.verified_findings | length) == 0' <<<"$incomplete_out" >/dev/null ||
    fail "incomplete round incorrectly authorized adjudication: $incomplete_out"

echo "==> pre-adjudication verification refuses a stale non-current-head round"
invalidated_fixture="ai/schemas/fixtures/exit/continue-invalidated"
set +e
invalidated_out="$(node scripts/dev-flow-exit.mjs --run "$invalidated_fixture/run" --stage review \
    --policy "$invalidated_fixture/policy.toml" \
    --current-head 0202020202020202020202020202020202020202 \
    --heads "$invalidated_fixture/heads.json" --verification-only --json)"
status=$?
set -e
[ "$status" -eq 0 ] || fail "invalidated pre-adjudication projection returned $status: $invalidated_out"
jq -e '.outcome == "continue" and .reason == "invalidated" and
    .action == "dispatch" and .next_round == 2' <<<"$invalidated_out" >/dev/null ||
    fail "stale round incorrectly authorized adjudication: $invalidated_out"

echo "==> pre-adjudication verification targets the newest unadjudicated round, not an older exact-head round"
newest_stale_record="$tmp/newest-stale-round"
cp -R ai/schemas/fixtures/exit/two-round-converge/run "$newest_stale_record"
rm "$newest_stale_record/adjudications/review-r2.json"
jq '.head = "0202020202020202020202020202020202020202" |
    .payload.reviewed_head = "0202020202020202020202020202020202020202"' \
    "$newest_stale_record/passes/review-r1-codex-cli.json" \
    >"$tmp/review-r1-pass.json"
mv "$tmp/review-r1-pass.json" "$newest_stale_record/passes/review-r1-codex-cli.json"
jq '.reviewed_head = "0202020202020202020202020202020202020202"' \
    "$newest_stale_record/adjudications/review-r1.json" >"$tmp/review-r1-adjudication.json"
mv "$tmp/review-r1-adjudication.json" "$newest_stale_record/adjudications/review-r1.json"
jq '.head = "0101010101010101010101010101010101010101" |
    .payload.reviewed_head = "0101010101010101010101010101010101010101"' \
    "$newest_stale_record/passes/review-r2-codex-cli.json" \
    >"$tmp/review-r2-pass.json"
mv "$tmp/review-r2-pass.json" "$newest_stale_record/passes/review-r2-codex-cli.json"
set +e
newest_stale_out="$(node scripts/dev-flow-exit.mjs --run "$newest_stale_record" \
    --stage review --policy ai/schemas/fixtures/exit/two-round-converge/policy.toml \
    --current-head 0202020202020202020202020202020202020202 \
    --heads ai/schemas/fixtures/exit/two-round-converge/heads.json \
    --verification-only --json)"
status=$?
set -e
[ "$status" -eq 0 ] || fail "newest stale round projection returned $status: $newest_stale_out"
jq -e '.outcome == "continue" and .reason == "invalidated" and
    .action == "dispatch" and .next_round == 3' <<<"$newest_stale_out" >/dev/null ||
    fail "older exact-head round authorized adjudication of newer stale evidence: $newest_stale_out"

echo "==> renderer projects the review record"
rendered="$(scripts/render-dev-flow.sh adjudication-record --record "$render_record")"
grep -Fq 'review-r1-codex-cli-1' <<<"$rendered" || fail "review finding was not rendered"

echo "==> renderer publishes verified provenance rather than superseded pass provenance"
verified_record="$tmp/verified-render"
cp -R "$render_record" "$verified_record"
verified_findings="$(jq -s '[.[].payload.findings[] | {
    id, provenance_status: "verified", verified_provenance: .provenance,
    fingerprint_status: "verified", verified_fingerprint: .fingerprint
  }]' "$verified_record"/passes/review-*.json)"
jq --argjson findings "$verified_findings" '.stage = "review" |
    .corrections = [{finding_id: "review-r1-codex-cli-1", field: "provenance",
      asserted: "original", corrected: "round:2", evidence: "trusted history"}] |
    .verified_findings = $findings |
    (.verified_findings[] | select(.id == "review-r1-codex-cli-1") |
      .provenance_status) = "corrected" |
    (.verified_findings[] | select(.id == "review-r1-codex-cli-1") |
      .verified_provenance) = "round:2"' \
    "$render_record/verdict.json" >"$verified_record/verdict.json"
verified_rendered="$(scripts/render-dev-flow.sh round-table --record "$verified_record" --stage review --round 1)"
grep -Fq 'round:2 (corrected)' <<<"$verified_rendered" ||
    fail "renderer published the pass's superseded provenance"
grep -Fq 'original → round:2' <<<"$verified_rendered" ||
    fail "renderer did not accept the exit projection's structured correction"

echo "==> durable publisher owns crash adoption and postcondition refusal"
head="$(jq -r '.head' "$fixture/run/passes/review-r1-codex-cli.json")"
common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
resolved_state="$("$monitor" state-path --run-id fixture-run)"
[ "$resolved_state" = "$common_dir/dev-flow-v2/runs/fixture-run/monitor.json" ] ||
    fail "monitor state did not resolve through the git common directory"
for unsafe_run_id in . ..; do
    set +e
    "$monitor" state-path --run-id "$unsafe_run_id" >"$tmp/unsafe-run-id.out" 2>&1
    status=$?
    set -e
    [ "$status" -eq 2 ] || fail "unsafe run id $unsafe_run_id was accepted"
    grep -Fq 'run id is missing or unsafe' "$tmp/unsafe-run-id.out" ||
        fail "unsafe run id rejection was not reported"
done
trusted_actor_id="199175422"
trust_repo="$tmp/trust-repo"
git init -q "$trust_repo"
jq -n '{}' >"$trust_repo/agent-registry.json"
git -C "$trust_repo" add agent-registry.json
git -C "$trust_repo" -c user.name='Fixture Author' -c user.email='fixture@example.invalid' \
    commit -qm 'test: registry without orchestrator trust'
untrusted_registry_revision="$(git -C "$trust_repo" rev-parse HEAD)"
jq -n --arg actor "$trusted_actor_id" '{trusted_orchestrator_actor_ids: [$actor]}' \
    >"$trust_repo/agent-registry.json"
git -C "$trust_repo" add agent-registry.json
git -C "$trust_repo" -c user.name='Fixture Author' -c user.email='fixture@example.invalid' \
    commit -qm 'test: registry with orchestrator trust'
registry_revision="$(git -C "$trust_repo" rev-parse HEAD)"
echo "==> monitor reclaims a lock whose recorded owner is dead"
stale_branch="feat/stale-lock-run"
stale_active_state="$("$monitor" active-path --branch "$stale_branch" --repo-root "$trust_repo")"
mkdir -p "$(dirname "$stale_active_state")"
printf '999999|%s|%s|fixture-dead-owner|Mon Jan  1 00:00:00 2001\n' \
    "$(hostname)" "$(id -u)" >"${stale_active_state}.lock"
stale_generation="$("$monitor" activate --active-state "$stale_active_state" \
    --run-id stale-lock-run --branch "$stale_branch" --expected-generation 0 \
    --registry-revision "$registry_revision" --writer feature-owner --repo-root "$trust_repo")"
[ "$stale_generation" -eq 1 ] || fail "stale owner recovery did not activate the run"
[ ! -e "${stale_active_state}.lock" ] || fail "recovered monitor lock remained after activation"
branch="feat/fixture-run"
active_state="$("$monitor" active-path --branch "$branch" --repo-root "$trust_repo")"
generation="$("$monitor" activate --active-state "$active_state" --run-id fixture-run \
    --branch "$branch" --expected-generation 0 --registry-revision "$registry_revision" \
    --writer feature-owner --repo-root "$trust_repo")"
jq -e --arg registry "$registry_revision" '.registry_revision == $registry' "$active_state" >/dev/null ||
    fail "active run did not pin its registry revision"
state="$("$monitor" state-path --run-id fixture-run --repo-root "$trust_repo")"
active_args=(--active-state "$active_state" --run-id fixture-run --branch "$branch"
    --generation "$generation" --repo-root "$trust_repo")
monitor_reserve() {
    "$monitor" reserve "${active_args[@]}" "$@"
}
monitor_reconcile() {
    "$monitor" reconcile "${active_args[@]}" "$@"
}
comment_marker="dev-flow:fixture-run:challenge:1"
comment_body="<!-- $comment_marker --> fixture evidence"
comment_digest="$(printf '%s' "$comment_body" | sha256_stream)"
comment_binding_args=(--evidence-role challenger --evidence-finder codex-cli)
jq -n '{integrated_lanes: ["lane-a"], discarded_lanes: []}' >"$tmp/assembly-plan.json"
set +e
monitor_reserve --state "$state" --event forged-revision --action comment \
    --expected-head "$head" --writer feature-owner --trusted-actor-id "$trusted_actor_id" \
    --registry-revision "$untrusted_registry_revision" \
    "${comment_binding_args[@]}" --marker "$comment_marker" \
    --payload-digest "$comment_digest" >"$tmp/forged-revision.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "caller-selected registry revision bypassed the active run"
grep -Fq 'registry revision does not match the active run' "$tmp/forged-revision.out" ||
    fail "active-run registry-revision rejection was not reported"
set +e
monitor_reserve --state "$state" --event forged-trust --action comment \
    --expected-head "$head" --writer feature-owner --trusted-actor-id 1 \
    --registry-revision "$registry_revision" "${comment_binding_args[@]}" \
    --marker "$comment_marker" --payload-digest "$comment_digest" >"$tmp/forged-trust.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "caller-declared actor bypassed the run-pinned registry trust root"
grep -Fq 'not trusted by the run-pinned registry revision' "$tmp/forged-trust.out" ||
    fail "registry-rooted actor rejection was not reported"
set +e
monitor_reserve --state "$tmp/noncanonical-monitor.json" --event split-ledger --action assembly \
    --expected-head "$head" --writer feature-owner >"$tmp/noncanonical.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "non-canonical monitor state path was accepted"
grep -Fq 'monitor state path is not canonical for this run' "$tmp/noncanonical.out" ||
    fail "non-canonical monitor state rejection was not reported"
monitor_reserve --state "$state" --event crash-write --action comment \
    --expected-head "$head" --writer feature-owner --trusted-actor-id "$trusted_actor_id" \
    --registry-revision "$registry_revision" "${comment_binding_args[@]}" \
    --marker "$comment_marker" --payload-digest "$comment_digest" >/dev/null
jq -n --arg run fixture-run --arg head "$head" --arg role challenger --arg finder codex-cli \
    --arg marker "$comment_marker" --arg body "$comment_body" --arg digest "$comment_digest" \
    '{status: "landed", event: "crash-write", action: "comment", head: $head,
      comments: [{comment_id: 42, actor_id: 1, run_id: $run, head: $head,
        role: $role, finder: $finder, marker: $marker, body: $body,
        payload_digest: $digest}]}' \
    >"$tmp/untrusted.json"
set +e
monitor_reconcile --state "$state" --event crash-write --observed "$tmp/untrusted.json" \
    >"$tmp/untrusted.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "untrusted comment postcondition was adopted"
jq -n --arg run fixture-run --arg head "$head" --arg role challenger --arg finder codex-cli \
    --arg actor "$trusted_actor_id" --arg marker "$comment_marker" \
    --arg body "$comment_body" --arg digest "$comment_digest" \
    '{status: "landed", event: "crash-write", action: "comment", head: $head,
      comments: [
        {comment_id: 43, actor_id: $actor, run_id: $run, head: $head,
          role: $role, finder: $finder, marker: $marker, body: $body, payload_digest: $digest},
        {comment_id: 42, actor_id: $actor, run_id: $run, head: $head,
          role: $role, finder: $finder, marker: $marker, body: $body, payload_digest: $digest}
      ]}' \
    >"$tmp/landed.json"
monitor_reconcile --state "$state" --event crash-write --observed "$tmp/landed.json" |
    grep -Fq 'adopt crash-write' || fail "crash-after-write action was not adopted"
jq -e '.cursor == "crash-write" and .actions[0].state == "adopted"' "$state" >/dev/null ||
    fail "adoption did not durably advance the cursor"
jq -e '.actions[0].postcondition.comment_id == "42"' "$state" >/dev/null ||
    fail "monitor did not canonically adopt the lowest matching comment id"

set +e
monitor_reserve --state "$state" --event duplicate-comment-auth --action comment \
    --expected-head "$head" --writer feature-owner --trusted-actor-id "$trusted_actor_id" \
    --registry-revision "$registry_revision" "${comment_binding_args[@]}" --marker "$comment_marker" \
    --payload-digest "$comment_digest" >"$tmp/duplicate-comment-auth.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "duplicate comment reservation identity was accepted"
grep -Fq 'duplicate comment reservation identity' "$tmp/duplicate-comment-auth.out" ||
    fail "duplicate comment reservation refusal was not reported"

conflicting_digest="$(printf '%s' 'changed evidence body' | sha256_stream)"
set +e
monitor_reserve --state "$state" --event conflicting-comment-auth --action comment \
    --expected-head "$head" --writer feature-owner --trusted-actor-id "$trusted_actor_id" \
    --registry-revision "$registry_revision" "${comment_binding_args[@]}" --marker "$comment_marker" \
    --payload-digest "$conflicting_digest" >"$tmp/conflicting-comment-auth.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "comment marker reuse with a changed digest was accepted"
grep -Fq 'duplicate comment reservation identity' "$tmp/conflicting-comment-auth.out" ||
    fail "conflicting comment marker refusal was not reported"

echo "==> comment retry requires a fully bound complete candidate set"
retry_marker="dev-flow:fixture-run:challenge:2"
retry_body="<!-- $retry_marker --> retry evidence"
retry_digest="$(printf '%s' "$retry_body" | sha256_stream)"
monitor_reserve --state "$state" --event comment-retry --action comment \
    --expected-head "$head" --writer feature-owner --trusted-actor-id "$trusted_actor_id" \
    --registry-revision "$registry_revision" "${comment_binding_args[@]}" \
    --marker "$retry_marker" --payload-digest "$retry_digest" >/dev/null
jq -n --arg run fixture-run --arg head "$head" --arg role challenger --arg finder codex-cli \
    --arg actor "$trusted_actor_id" --arg marker "$retry_marker" --arg body "$retry_body" \
    --arg digest "$retry_digest" \
    '{status: "absent", comments: [{comment_id: 84, actor_id: $actor,
      run_id: $run, head: $head, role: $role, finder: $finder, marker: $marker,
      body: $body, payload_digest: $digest}]}' >"$tmp/comment-candidate.json"
for binding in run_id head role finder payload_digest; do
    replacement=wrong
    case "$binding" in
    head) replacement=0000000000000000000000000000000000000000 ;;
    payload_digest) replacement=0000000000000000000000000000000000000000000000000000000000000000 ;;
    esac
    jq --arg binding "$binding" --arg replacement "$replacement" \
        '.comments[0][$binding] = $replacement' "$tmp/comment-candidate.json" \
        >"$tmp/comment-candidate-$binding.json"
    set +e
    monitor_reconcile --state "$state" --event comment-retry \
        --observed "$tmp/comment-candidate-$binding.json" >"$tmp/comment-candidate-$binding.out" 2>&1
    status=$?
    set -e
    [ "$status" -eq 2 ] || fail "comment retry accepted a mismatched $binding binding"
    grep -Fq 'comment candidate conflicts with reservation bindings' \
        "$tmp/comment-candidate-$binding.out" ||
        fail "comment retry did not report its mismatched $binding binding"
done
set +e
monitor_reconcile --state "$state" --event comment-retry \
    --observed "$tmp/comment-candidate.json" >"$tmp/comment-candidate-match.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "comment retry was authorized despite an authenticated match"
grep -Fq 'absent comment observation contains an authenticated match' \
    "$tmp/comment-candidate-match.out" ||
    fail "authenticated comment match did not block retry"
jq -n '{status: "absent", comments: []}' >"$tmp/comment-candidate-empty.json"
monitor_reconcile --state "$state" --event comment-retry \
    --observed "$tmp/comment-candidate-empty.json" |
    grep -Fq 'retry comment-retry' || fail "empty authenticated candidate set did not authorize retry"
jq '.status = "landed" | .event = "comment-retry" | .action = "comment" |
    .head = .comments[0].head' "$tmp/comment-candidate.json" >"$tmp/comment-candidate-landed.json"
monitor_reconcile --state "$state" --event comment-retry \
    --observed "$tmp/comment-candidate-landed.json" |
    grep -Fq 'adopt comment-retry' || fail "retried comment was not adopted"

echo "==> monitor durably enforces the total agent-run budget"
monitor_agent_run() {
    "$monitor" reserve-agent-run "${active_args[@]}" --state "$state" "$@"
}
monitor_agent_run --event initial-implementer --max-agent-runs 2 --writer feature-owner |
    grep -Fq 'reserved agent-run initial-implementer 1/2' ||
    fail "first agent run was not reserved"
monitor_agent_run --event initial-implementer --max-agent-runs 2 --writer feature-owner |
    grep -Fq 'adopt agent-run initial-implementer 1/2' ||
    fail "agent-run re-arm spent a duplicate slot"
monitor_agent_run --event remediation-r1 --max-agent-runs 2 --writer feature-owner |
    grep -Fq 'reserved agent-run remediation-r1 2/2' ||
    fail "remediation agent run was not reserved"
jq -e '.agent_run_budget.max_agent_runs == 2 and
    (.agent_run_budget.reservations | length) == 2' "$state" >/dev/null ||
    fail "agent-run accounting was not persisted"
set +e
monitor_agent_run --event remediation-r2 --max-agent-runs 2 --writer feature-owner \
    >"$tmp/exhausted-agent-run.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "agent run beyond max_agent_runs was accepted"
grep -Fq 'agent-run budget exhausted (2/2)' "$tmp/exhausted-agent-run.out" ||
    fail "agent-run budget exhaustion was not reported"
set +e
monitor_agent_run --event changed-budget --max-agent-runs 3 --writer feature-owner \
    >"$tmp/changed-agent-budget.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "run-pinned agent budget was changed"
grep -Fq 'max agent runs changed (recorded 2, supplied 3)' "$tmp/changed-agent-budget.out" ||
    fail "agent-run budget mutation was not reported"
set +e
monitor_agent_run --event lane-dispatch --max-agent-runs 2 --writer lane \
    >"$tmp/lane-agent-run.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "lane could reserve an agent run as feature owner"
grep -Fq 'only the feature-branch owner may reserve an agent run' "$tmp/lane-agent-run.out" ||
    fail "agent-run single-writer rejection was not reported"

monitor_reserve --state "$state" --event absent-write --action push \
    --expected-head "$head" --writer feature-owner >/dev/null
jq -n '{status: "absent"}' >"$tmp/absent.json"
monitor_reconcile --state "$state" --event absent-write --observed "$tmp/absent.json" |
    grep -Fq 'retry absent-write' || fail "absent action was not marked retryable"
jq -e '.cursor == "comment-retry" and
    ([.actions[] | select(.event == "absent-write" and .state == "reserved")] | length) == 1' \
    "$state" >/dev/null ||
    fail "absent action advanced the cursor"

jq -n '{status: "indeterminate"}' >"$tmp/indeterminate.json"
set +e
monitor_reconcile --state "$state" --event absent-write --observed "$tmp/indeterminate.json" \
    >"$tmp/indeterminate.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "indeterminate postcondition was accepted"
grep -Fq 'postcondition is indeterminate' "$tmp/indeterminate.out" ||
    fail "indeterminate refusal was not reported"

set +e
monitor_reserve --state "$state" --event lane-push --action push \
    --expected-head "$head" --writer lane >"$tmp/lane-push.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "parallel lane could reserve a feature-branch push"
grep -Fq 'only the feature-branch owner' "$tmp/lane-push.out" ||
    fail "single-writer rejection was not reported"

echo "==> monitor rejects out-of-order and stale reconciliation"
ordered_run_id="ordered-run"
ordered_branch="feat/ordered-run"
ordered_active_state="$("$monitor" active-path --branch "$ordered_branch" --repo-root "$trust_repo")"
ordered_generation="$("$monitor" activate --active-state "$ordered_active_state" \
    --run-id "$ordered_run_id" --branch "$ordered_branch" --expected-generation 0 \
    --registry-revision "$registry_revision" --writer feature-owner --repo-root "$trust_repo")"
ordered_state="$("$monitor" state-path --run-id "$ordered_run_id" --repo-root "$trust_repo")"
ordered_args=(--active-state "$ordered_active_state" --run-id "$ordered_run_id"
    --branch "$ordered_branch" --generation "$ordered_generation" --repo-root "$trust_repo")
"$monitor" reserve "${ordered_args[@]}" --state "$ordered_state" --event e1 --action assembly \
    --expected-head "$head" --writer feature-owner --assembly-plan "$tmp/assembly-plan.json" >/dev/null
"$monitor" reserve "${ordered_args[@]}" --state "$ordered_state" --event e2 --action assembly \
    --expected-head "$head" --writer feature-owner --assembly-plan "$tmp/assembly-plan.json" >/dev/null
jq -n '{status: "absent"}' >"$tmp/e2-absent.json"
set +e
"$monitor" reconcile "${ordered_args[@]}" --state "$ordered_state" --event e2 \
    --observed "$tmp/e2-absent.json" >"$tmp/e2-absent.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "out-of-order absent action was authorized for retry"
grep -Fq 'out of reservation order' "$tmp/e2-absent.out" ||
    fail "out-of-order retry refusal was not reported"
jq -n --arg head "$head" '{status: "landed", event: "e2", action: "assembly", head: $head,
    integrated_lanes: ["lane-a"], discarded_lanes: []}' >"$tmp/e2.json"
set +e
"$monitor" reconcile "${ordered_args[@]}" --state "$ordered_state" --event e2 \
    --observed "$tmp/e2.json" >"$tmp/e2.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "out-of-order action advanced the monitor cursor"
grep -Fq 'out of reservation order' "$tmp/e2.out" || fail "out-of-order refusal was not reported"
jq -n --arg head "$head" '{status: "landed", event: "e1", action: "assembly", head: $head,
    integrated_lanes: ["lane-a"], discarded_lanes: []}' >"$tmp/e1.json"
"$monitor" reconcile "${ordered_args[@]}" --state "$ordered_state" --event e1 \
    --observed "$tmp/e1.json" >/dev/null
jq -n --arg head "$head" '{status: "landed", event: "e2", action: "assembly", head: $head,
    integrated_lanes: ["lane-b"], discarded_lanes: []}' >"$tmp/e2-wrong-plan.json"
set +e
"$monitor" reconcile "${ordered_args[@]}" --state "$ordered_state" --event e2 \
    --observed "$tmp/e2-wrong-plan.json" >"$tmp/e2-wrong-plan.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "assembly reconciliation accepted a different lane selection"
grep -Fq 'assembled lane selection does not match reservation' "$tmp/e2-wrong-plan.out" ||
    fail "assembly-plan mismatch was not reported"
"$monitor" reconcile "${ordered_args[@]}" --state "$ordered_state" --event e2 \
    --observed "$tmp/e2.json" >/dev/null
jq -n '{status: "absent"}' >"$tmp/stale.json"
"$monitor" reconcile "${ordered_args[@]}" --state "$ordered_state" --event e2 \
    --observed "$tmp/stale.json" |
    grep -Fq 'adopt e2' || fail "adopted action was retryable"

echo "==> monitor serializes concurrent reservations"
concurrent_run_id="concurrent-run"
concurrent_branch="feat/concurrent-run"
concurrent_active_state="$("$monitor" active-path --branch "$concurrent_branch" --repo-root "$trust_repo")"
concurrent_generation="$("$monitor" activate --active-state "$concurrent_active_state" \
    --run-id "$concurrent_run_id" --branch "$concurrent_branch" --expected-generation 0 \
    --registry-revision "$registry_revision" --writer feature-owner --repo-root "$trust_repo")"
concurrent_state="$("$monitor" state-path --run-id "$concurrent_run_id" --repo-root "$trust_repo")"
concurrent_args=(--active-state "$concurrent_active_state" --run-id "$concurrent_run_id"
    --branch "$concurrent_branch" --generation "$concurrent_generation" --repo-root "$trust_repo")
for number in $(seq 1 20); do
    "$monitor" reserve "${concurrent_args[@]}" --state "$concurrent_state" \
        --event "concurrent-$number" --action assembly \
        --expected-head "$head" --writer feature-owner \
        --assembly-plan "$tmp/assembly-plan.json" >"$tmp/concurrent-$number.out" &
done
wait
jq -e '[.actions[] | select(.state == "reserved")] | length == 20' "$concurrent_state" >/dev/null ||
    fail "concurrent reservations lost monitor state"
[ ! -e "${concurrent_active_state}.lock" ] || fail "monitor left its portable lock behind"

echo "==> one run id cannot bind two branch-specific active pointers"
other_branch="feat/other-fixture-run"
other_active_state="$("$monitor" active-path --branch "$other_branch" --repo-root "$trust_repo")"
set +e
"$monitor" activate --active-state "$other_active_state" --run-id fixture-run \
    --branch "$other_branch" --expected-generation 0 --registry-revision "$registry_revision" \
    --writer feature-owner --repo-root "$trust_repo" >"$tmp/other-branch.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "one run id was activated for two branches"
grep -Fq 'already bound to a different branch' "$tmp/other-branch.out" ||
    fail "cross-branch run binding refusal was not reported"

echo "==> monitor rejects a superseded run at the same head"
replacement_generation="$("$monitor" activate --active-state "$active_state" --run-id replacement-run \
    --branch "$branch" --expected-generation "$generation" --registry-revision "$registry_revision" \
    --writer feature-owner --repo-root "$trust_repo")"
[ "$replacement_generation" -eq $((generation + 1)) ] || fail "replacement run did not advance generation"
set +e
monitor_reserve --state "$state" --event stale-run --action push \
    --expected-head "$head" --writer feature-owner >"$tmp/stale-run.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "superseded run reserved a write at the same head"
grep -Fq 'no longer active for this branch generation' "$tmp/stale-run.out" ||
    fail "stale-generation rejection was not reported"

echo "review skill fixtures OK"
