#!/usr/bin/env bash
# test-finder-normalization.sh — conformance for scripts/normalize-finder-findings.mjs.
#
# Two obligations, both from #796:
#
#   1. every registered finder has a fixture of its OWN raw output shape that
#      decodes to a pinned pass core;
#   2. the shared consumers — adjudication, the exit computation, the
#      renderer — contain no finder-specific branch, which is the whole point
#      of decoding here instead of there.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fixtures="ai/schemas/fixtures/finder-normalization"
normalizer="scripts/normalize-finder-findings.mjs"
registry="agent-registry.json"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}
command -v node >/dev/null 2>&1 || fail "node is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
[ -f "$normalizer" ] || fail "missing $normalizer"
[ -d "$fixtures" ] || fail "missing $fixtures"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_fixture() {
    local dir="$1" args="$1/args.json" raw
    raw="$dir/$(jq -r '.raw' "$args")"
    node "$normalizer" \
        --finder "$(jq -r '.finder' "$args")" \
        --stage "$(jq -r '.stage' "$args")" \
        --round "$(jq -r '.round' "$args")" \
        --reviewed-head "$(jq -r '."reviewed-head"' "$args")" \
        --input "$raw"
}

echo "==> every registered finder has a raw-output conformance fixture"
missing=0
while IFS= read -r slug; do
    [ -d "$fixtures/$slug" ] || {
        echo "  no fixture directory for registered finder $slug" >&2
        missing=1
    }
done < <(jq -r '.finders[].slug' "$registry")
[ "$missing" -eq 0 ] ||
    fail "a registered finder with no fixture has no proven raw-output contract"

echo "==> each fixture decodes to its pinned pass core"
cases=0
for dir in "$fixtures"/*/; do
    dir="${dir%/}"
    slug="$(basename "$dir")"
    for required in args.json expected.json; do
        [ -f "$dir/$required" ] || fail "$slug fixture is missing $required"
    done
    jq -e --arg slug "$slug" '.finders[] | select(.slug == $slug)' "$registry" >/dev/null ||
        fail "fixture $slug does not name a registered finder"
    run_fixture "$dir" >"$tmp/$slug.json" ||
        fail "$slug fixture did not decode cleanly"
    # Compared as parsed JSON, not as bytes: a formatting change in the
    # normalizer's output must not read as a contract change.
    jq -e --slurpfile expected "$dir/expected.json" '. == $expected[0]' \
        "$tmp/$slug.json" >/dev/null ||
        fail "$slug decoded differently from $dir/expected.json"
    cases=$((cases + 1))
done
[ "$cases" -gt 0 ] || fail "no fixtures found under $fixtures"

echo "==> a confidence pass core carries the finder in every finding id"
for dir in "$fixtures"/*/; do
    dir="${dir%/}"
    slug="$(basename "$dir")"
    stage="$(jq -r '.stage' "$dir/args.json")"
    round="$(jq -r '.round' "$dir/args.json")"
    jq -e --arg slug "$slug" --arg stage "$stage" --arg round "$round" '
        [.findings[].id] | all(startswith("\($stage)-r\($round)-\($slug)-"))
    ' "$dir/expected.json" >/dev/null ||
        fail "$slug fixture has a finding id that does not carry its stage, round and finder"
done

echo "==> a review-stage decode is a schema-valid reviewer payload"
review_case=""
for dir in "$fixtures"/*/; do
    dir="${dir%/}"
    [ "$(jq -r '.stage' "$dir/args.json")" = review ] || continue
    [ "$(jq -r '.findings | length' "$dir/expected.json")" -gt 0 ] || continue
    review_case="$dir"
    break
done
[ -n "$review_case" ] || fail "no review-stage fixture with findings to validate as a payload"
jq -n --slurpfile payload "$review_case/expected.json" '
    {schema: 2, role: "reviewer", status: "completed",
     head: $payload[0].reviewed_head,
     produced_at: "2026-09-05T00:00:00Z",
     producer: {harness: "codex-cli", model: "gpt-5.6-codex", tier: "frontier"},
     run: {run_id: "finder-normalization-fixture", initiated_by: "human"},
     payload: $payload[0]}' >"$tmp/reviewer-envelope.json"
node scripts/validate-result-schemas.mjs envelope "$tmp/reviewer-envelope.json" >"$tmp/envelope.out" 2>&1 ||
    fail "a normalized review pass is not a schema-valid reviewer payload: $(cat "$tmp/envelope.out")"

echo "==> an integration decode is result.integrator's own verbatim finding slice"
for dir in "$fixtures"/*/; do
    dir="${dir%/}"
    [ "$(jq -r '.stage' "$dir/args.json")" = integration ] || continue
    jq -e '
        (.findings | all(keys == ["body", "id", "source_id"]))
        and ([.findings[].id] | sort) == ([.severity_hypotheses[].id] | sort)
    ' "$dir/expected.json" >/dev/null ||
        fail "$(basename "$dir") integration decode is not the integrator finding slice plus one hypothesis per finding"
done

echo "==> narration is not decoded as a finding"
printf 'Codex verification checkpoint.\n\nThere are no P0 or P1 findings.\n' |
    node "$normalizer" --finder codex-verification --stage review --round 1 \
        --reviewed-head 0808080808080808080808080808080808080808 >"$tmp/clean.json" ||
    fail "a clean pass exited non-zero"
jq -e '.findings == [] and .counts == {P0: 0, P1: 0, P2: 0, P3: 0}' "$tmp/clean.json" >/dev/null ||
    fail "narration saying there are no P0 findings was decoded as one"

echo "==> a labelled finding with no decodable path fails closed"
set +e
printf 'P0 the whole approach is wrong and no file is named.\n' |
    node "$normalizer" --finder codex-verification --stage review --round 1 \
        --reviewed-head 0808080808080808080808080808080808080808 \
        >"$tmp/undecoded.json" 2>"$tmp/undecoded.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "an undecodable finding did not fail closed (exit $status)"
grep -Fq 'could not be decoded' "$tmp/undecoded.err" ||
    fail "the undecodable finding was not reported"
jq -e '.findings == []' "$tmp/undecoded.json" >/dev/null ||
    fail "an undecodable finding leaked into the pass"

echo "==> an inline comment carried forward from an older commit is not current-head evidence"
# GitHub advances an inline comment's commit_id when it still applies after a
# push; original_commit_id is the commit it was written against, and is what
# the integrate checker binds on. Binding on commit_id here would accept a
# comment about an older tree as this head's evidence.
jq --arg head "$(jq -r '."reviewed-head"' "$fixtures/codex-cloud/args.json")" '
      .comments[0].original_commit_id = "0000000000000000000000000000000000000000" |
      .comments[0].commit_id = $head' \
    "$fixtures/codex-cloud/raw.json" >"$tmp/carried-forward.json"
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --reviewed-head "$(jq -r '."reviewed-head"' "$fixtures/codex-cloud/args.json")" \
    --input "$tmp/carried-forward.json" >"$tmp/carried-forward.out.json"
jq -e '[.findings[].source_id] | index("9101") == null' "$tmp/carried-forward.out.json" >/dev/null ||
    fail "an inline comment written against an older commit was accepted as current-head evidence"

echo "==> another actor's comment on the same head is not this finder's evidence"
jq '.comments[0].user.id = 999999' "$fixtures/codex-cloud/raw.json" >"$tmp/foreign.json"
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --reviewed-head "$(jq -r '."reviewed-head"' "$fixtures/codex-cloud/args.json")" \
    --input "$tmp/foreign.json" >"$tmp/foreign.out.json"
jq -e '[.findings[].source_id] | index("9101") == null' "$tmp/foreign.out.json" >/dev/null ||
    fail "a comment by another actor was accepted as this finder's evidence"

echo "==> an unregistered finder refuses rather than guessing a decode"
set +e
printf 'P1 scripts/x.sh:1 — nope.\n' |
    node "$normalizer" --finder not-a-finder --stage review --round 1 \
        --reviewed-head 0808080808080808080808080808080808080808 >/dev/null 2>"$tmp/unknown.err"
status=$?
set -e
[ "$status" -eq 2 ] || fail "an unregistered finder was decoded (exit $status)"
grep -Fq 'is not a registered finder' "$tmp/unknown.err" ||
    fail "the unregistered-finder refusal was not reported"

echo "==> the shared consumers carry no finder-specific branch"
# The reason normalization exists. A finder slug appearing in any of these
# three is the failure mode #796 set out to remove: a second reviewer family
# becoming a third branch in code that should only ever see `findings[]`.
for consumer in scripts/dev-flow-exit.mjs scripts/render-dev-flow.mjs \
    ai/schemas/adjudication.schema.json; do
    [ -f "$consumer" ] || fail "missing shared consumer $consumer"
    while IFS= read -r slug; do
        if grep -Fq "$slug" "$consumer"; then
            fail "$consumer names finder $slug — adjudication, exit computation and rendering must read findings[] without knowing which product produced one"
        fi
    done < <(jq -r '.finders[].slug' "$registry")
done

echo "finder normalization OK ($cases fixture(s))"
