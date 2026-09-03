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
    'run.json.evidence_comments' 'fenced JSON'; do
    grep -Fq "$text" "$skill" || fail "review skill is missing $text"
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

echo "==> renderer projects the review record"
rendered="$(scripts/render-dev-flow.sh adjudication-record --record "$render_record")"
grep -Fq 'review-r1-codex-cli-1' <<<"$rendered" || fail "review finding was not rendered"

echo "==> renderer publishes verified provenance rather than superseded pass provenance"
verified_record="$tmp/verified-render"
cp -R "$render_record" "$verified_record"
jq '.corrections = [{finding_id: "review-r1-codex-cli-1", field: "provenance",
      asserted: "original", corrected: "round:2", evidence: "trusted history"}] |
    .verified_findings = [{id: "review-r1-codex-cli-1", provenance_status: "corrected",
      verified_provenance: "round:2", fingerprint_status: "verified", verified_fingerprint: "new"}]' \
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
set +e
monitor_reserve --state "$state" --event forged-revision --action comment \
    --expected-head "$head" --writer feature-owner --trusted-actor-id "$trusted_actor_id" \
    --registry-revision "$untrusted_registry_revision" \
    --marker "$comment_marker" --payload-digest "$comment_digest" >"$tmp/forged-revision.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "caller-selected registry revision bypassed the active run"
grep -Fq 'registry revision does not match the active run' "$tmp/forged-revision.out" ||
    fail "active-run registry-revision rejection was not reported"
set +e
monitor_reserve --state "$state" --event forged-trust --action comment \
    --expected-head "$head" --writer feature-owner --trusted-actor-id 1 \
    --registry-revision "$registry_revision" \
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
    --registry-revision "$registry_revision" \
    --marker "$comment_marker" --payload-digest "$comment_digest" >/dev/null
jq -n --arg head "$head" --arg marker "$comment_marker" --arg body "$comment_body" \
    --arg digest "$comment_digest" \
    '{status: "landed", event: "crash-write", action: "comment", head: $head,
      comments: [{comment_id: 42, actor_id: 1, marker: $marker, body: $body, payload_digest: $digest}]}' \
    >"$tmp/untrusted.json"
set +e
monitor_reconcile --state "$state" --event crash-write --observed "$tmp/untrusted.json" \
    >"$tmp/untrusted.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "untrusted comment postcondition was adopted"
jq -n --arg head "$head" --arg actor "$trusted_actor_id" --arg marker "$comment_marker" \
    --arg body "$comment_body" --arg digest "$comment_digest" \
    '{status: "landed", event: "crash-write", action: "comment", head: $head,
      comments: [
        {comment_id: 43, actor_id: $actor, marker: $marker, body: $body, payload_digest: $digest},
        {comment_id: 42, actor_id: $actor, marker: $marker, body: $body, payload_digest: $digest}
      ]}' \
    >"$tmp/landed.json"
monitor_reconcile --state "$state" --event crash-write --observed "$tmp/landed.json" |
    grep -Fq 'adopt crash-write' || fail "crash-after-write action was not adopted"
jq -e '.cursor == "crash-write" and .actions[0].state == "adopted"' "$state" >/dev/null ||
    fail "adoption did not durably advance the cursor"
jq -e '.actions[0].postcondition.comment_id == "42"' "$state" >/dev/null ||
    fail "monitor did not canonically adopt the lowest matching comment id"

monitor_reserve --state "$state" --event absent-write --action push \
    --expected-head "$head" --writer feature-owner >/dev/null
jq -n '{status: "absent"}' >"$tmp/absent.json"
monitor_reconcile --state "$state" --event absent-write --observed "$tmp/absent.json" |
    grep -Fq 'retry absent-write' || fail "absent action was not marked retryable"
jq -e '.cursor == "crash-write" and .actions[1].state == "reserved"' "$state" >/dev/null ||
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
    --expected-head "$head" --writer feature-owner >/dev/null
"$monitor" reserve "${ordered_args[@]}" --state "$ordered_state" --event e2 --action assembly \
    --expected-head "$head" --writer feature-owner >/dev/null
jq -n --arg head "$head" '{status: "landed", event: "e2", action: "assembly", head: $head}' >"$tmp/e2.json"
set +e
"$monitor" reconcile "${ordered_args[@]}" --state "$ordered_state" --event e2 \
    --observed "$tmp/e2.json" >"$tmp/e2.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "out-of-order action advanced the monitor cursor"
grep -Fq 'out of reservation order' "$tmp/e2.out" || fail "out-of-order refusal was not reported"
jq -n --arg head "$head" '{status: "landed", event: "e1", action: "assembly", head: $head}' >"$tmp/e1.json"
"$monitor" reconcile "${ordered_args[@]}" --state "$ordered_state" --event e1 \
    --observed "$tmp/e1.json" >/dev/null
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
        --expected-head "$head" --writer feature-owner >"$tmp/concurrent-$number.out" &
done
wait
jq -e '[.actions[] | select(.state == "reserved")] | length == 20' "$concurrent_state" >/dev/null ||
    fail "concurrent reservations lost monitor state"
[ ! -e "${concurrent_active_state}.lock" ] || fail "monitor left its portable lock behind"

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
