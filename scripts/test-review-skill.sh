#!/usr/bin/env bash
# Regression coverage for the /review stage's durable-record hand-off.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}
skill="ai/skills/universal/review/SKILL.md"
fixture="ai/schemas/fixtures/exit/single-round-clean-converge"
render_record="ai/schemas/fixtures/render/record"
monitor="scripts/dev-flow-monitor.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> review skill names both role dispatches and record authority"
for text in '[stage.challenge].finders' '[stage.review].finders' challenger reviewer \
    'scripts/dev-flow-exit.sh' 'scripts/render-dev-flow.sh' 'scripts/round-push.sh'; do
    grep -Fq "$text" "$skill" || fail "review skill is missing $text"
done

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

echo "==> renderer projects the review record"
rendered="$(scripts/render-dev-flow.sh adjudication-record --record "$render_record")"
grep -Fq 'review-r1-codex-cli-1' <<<"$rendered" || fail "review finding was not rendered"

echo "==> durable publisher owns crash adoption and postcondition refusal"
head="$(jq -r '.head' "$fixture/run/passes/review-r1-codex-cli.json")"
common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
resolved_state="$("$monitor" state-path --run-id fixture-run)"
[ "$resolved_state" = "$common_dir/dev-flow-v2/runs/fixture-run/monitor.json" ] ||
    fail "monitor state did not resolve through the git common directory"
state="$tmp/monitor.json"
trusted_actor_id="199175422"
comment_marker="dev-flow:fixture-run:challenge:1"
comment_body="<!-- $comment_marker --> fixture evidence"
comment_digest="$(printf '%s' "$comment_body" | sha256sum | awk '{print $1}')"
"$monitor" reserve --state "$state" --event crash-write --action comment \
    --expected-head "$head" --writer feature-owner --trusted-actor-id "$trusted_actor_id" \
    --marker "$comment_marker" --payload-digest "$comment_digest" >/dev/null
jq -n --arg head "$head" --arg marker "$comment_marker" --arg body "$comment_body" \
    --arg digest "$comment_digest" \
    '{status: "landed", event: "crash-write", action: "comment", head: $head,
      comment_id: 42, actor_id: 1, marker: $marker, body: $body, payload_digest: $digest}' \
    >"$tmp/untrusted.json"
set +e
"$monitor" reconcile --state "$state" --event crash-write --observed "$tmp/untrusted.json" \
    >"$tmp/untrusted.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "untrusted comment postcondition was adopted"
jq -n --arg head "$head" --arg actor "$trusted_actor_id" --arg marker "$comment_marker" \
    --arg body "$comment_body" --arg digest "$comment_digest" \
    '{status: "landed", event: "crash-write", action: "comment", head: $head,
      comment_id: 42, actor_id: $actor, marker: $marker, body: $body, payload_digest: $digest}' \
    >"$tmp/landed.json"
"$monitor" reconcile --state "$state" --event crash-write --observed "$tmp/landed.json" |
    grep -Fq 'adopt crash-write' || fail "crash-after-write action was not adopted"
jq -e '.cursor == "crash-write" and .actions[0].state == "adopted"' "$state" >/dev/null ||
    fail "adoption did not durably advance the cursor"

"$monitor" reserve --state "$state" --event absent-write --action push \
    --expected-head "$head" --writer feature-owner >/dev/null
jq -n '{status: "absent"}' >"$tmp/absent.json"
"$monitor" reconcile --state "$state" --event absent-write --observed "$tmp/absent.json" |
    grep -Fq 'retry absent-write' || fail "absent action was not marked retryable"
jq -e '.cursor == "crash-write" and .actions[1].state == "reserved"' "$state" >/dev/null ||
    fail "absent action advanced the cursor"

jq -n '{status: "indeterminate"}' >"$tmp/indeterminate.json"
set +e
"$monitor" reconcile --state "$state" --event absent-write --observed "$tmp/indeterminate.json" \
    >"$tmp/indeterminate.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "indeterminate postcondition was accepted"
grep -Fq 'postcondition is indeterminate' "$tmp/indeterminate.out" ||
    fail "indeterminate refusal was not reported"

set +e
"$monitor" reserve --state "$state" --event lane-push --action push \
    --expected-head "$head" --writer lane >"$tmp/lane-push.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "parallel lane could reserve a feature-branch push"
grep -Fq 'only the feature-branch owner' "$tmp/lane-push.out" ||
    fail "single-writer rejection was not reported"

echo "==> monitor rejects out-of-order and stale reconciliation"
ordered_state="$tmp/ordered-monitor.json"
"$monitor" reserve --state "$ordered_state" --event e1 --action assembly \
    --expected-head "$head" --writer feature-owner >/dev/null
"$monitor" reserve --state "$ordered_state" --event e2 --action assembly \
    --expected-head "$head" --writer feature-owner >/dev/null
jq -n --arg head "$head" '{status: "landed", event: "e2", action: "assembly", head: $head}' >"$tmp/e2.json"
set +e
"$monitor" reconcile --state "$ordered_state" --event e2 --observed "$tmp/e2.json" >"$tmp/e2.out" 2>&1
status=$?
set -e
[ "$status" -eq 2 ] || fail "out-of-order action advanced the monitor cursor"
grep -Fq 'out of reservation order' "$tmp/e2.out" || fail "out-of-order refusal was not reported"
jq -n --arg head "$head" '{status: "landed", event: "e1", action: "assembly", head: $head}' >"$tmp/e1.json"
"$monitor" reconcile --state "$ordered_state" --event e1 --observed "$tmp/e1.json" >/dev/null
"$monitor" reconcile --state "$ordered_state" --event e2 --observed "$tmp/e2.json" >/dev/null
jq -n '{status: "absent"}' >"$tmp/stale.json"
"$monitor" reconcile --state "$ordered_state" --event e2 --observed "$tmp/stale.json" |
    grep -Fq 'adopt e2' || fail "adopted action was retryable"

echo "==> monitor serializes concurrent reservations"
concurrent_state="$tmp/concurrent-monitor.json"
for number in $(seq 1 20); do
    "$monitor" reserve --state "$concurrent_state" --event "concurrent-$number" --action assembly \
        --expected-head "$head" --writer feature-owner >"$tmp/concurrent-$number.out" &
done
wait
jq -e '[.actions[] | select(.state == "reserved")] | length == 20' "$concurrent_state" >/dev/null ||
    fail "concurrent reservations lost monitor state"

echo "review skill fixtures OK"
