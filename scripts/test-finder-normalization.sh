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
    return 0
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

echo "==> every MACHINE-SHAPED finder has a raw-output conformance fixture"
# Only github-review-json is decoded here. A local-CLI finder's free text is
# the dispatched role's evidence source under /review's own contract, so it has
# no fixture in this corpus and the decoder refuses it outright (asserted
# below) rather than half-parsing it.
missing=0
while IFS= read -r slug; do
    [ -d "$fixtures/$slug" ] || {
        echo "  no fixture directory for machine-shaped finder $slug" >&2
        missing=1
    }
done < <(jq -r '.finders[] | select(.raw_shape == "github-review-json") | .slug' "$registry")
[ "$missing" -eq 0 ] ||
    fail "a machine-shaped finder with no fixture has no proven raw-output contract"

echo "==> a free-text finder is refused, not half-parsed"
while IFS= read -r slug; do
    [ ! -d "$fixtures/$slug" ] ||
        fail "$slug produces free text and must not have a decode fixture"
    # That finder's OWN stage, so the refusal under test is the raw-shape one
    # and not the stage-affinity check that runs before it.
    finder_stage="$(jq -r --arg slug "$slug" '.finders[] | select(.slug == $slug) | .stages[0]' "$registry")"
    set +e
    printf 'P1 scripts/x.sh:1 — nope.\n' |
        node "$normalizer" --finder "$slug" --stage "$finder_stage" --round 1 \
            --reviewed-head 0808080808080808080808080808080808080808 \
            >/dev/null 2>"$tmp/free-text-$slug.err"
    status=$?
    set -e
    [ "$status" -eq 2 ] ||
        fail "$slug free text was decoded rather than refused (exit $status)"
    grep -Fq "the dispatched role's evidence source" "$tmp/free-text-$slug.err" ||
        fail "$slug refusal did not name where that output is read instead"
done < <(jq -r '.finders[] | select(.raw_shape == "labelled-text") | .slug' "$registry")

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

echo "==> a badged top-level comment on the current head is decoded"
# A top-level comment carries no commit_id — its registry head_binding is the
# reviewed-commit line in its own body — so an inline-only decoder dropped it
# silently, while AGENTS.md requires exactly that finding to outrank a later
# clean result.
jq -e '[.findings[] | select(.source_id == "9401")] | length == 2' \
    "$fixtures/codex-cloud/expected.json" >/dev/null ||
    fail "the top-level comment surface was not decoded, or its two badged findings were not split"
jq -e '[.severity_hypotheses[] | select(.id | endswith("-2") or endswith("-3")) | .priority] == ["P1", "P2"]' \
    "$fixtures/codex-cloud/expected.json" >/dev/null ||
    fail "the two findings in one comment body did not get their own priorities"

echo "==> a top-level comment for another head, or another actor, is not evidence"
jq -e '[.findings[].source_id] | (index("9402") == null) and (index("9403") == null)' \
    "$fixtures/codex-cloud/expected.json" >/dev/null ||
    fail "a stale or foreign top-level comment was accepted as current-head evidence"

echo "==> an undecodable finding cannot be waved through"
# There is no flag to continue past exit 3: a pass that omits a finding is
# exactly what a stage banks as clean.
! grep -Fq 'allow-undecoded' "$normalizer" ||
    fail "the undecoded escape hatch is back"

echo "==> a badge mentioned mid-sentence does not split a finding"
# Splitting on every occurrence turned a finding that discusses "the P0/P1
# gate" into fabricated findings, one of which could pick up a spurious higher
# severity. Both finders lead a finding with its badge, so a cut is made only
# where the badge opens a line.
jq -n '{review:{id:1,state:"COMMENTED",commit_id:"0303030303030303030303030303030303030303",
      user:{id:199175422},
      body:"### Codex Review\n\n**P1** The gate accepts an empty list, the same class as the P0/P1 rule in AGENTS.md.\n\n**Reviewed commit:** `0303030303030303030303030303030303030303`"},
    comments:[]}' >"$tmp/prose.json"
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --reviewed-head 0303030303030303030303030303030303030303 \
    --input "$tmp/prose.json" >"$tmp/prose.out.json" ||
    fail "a body mentioning a badge mid-sentence did not decode"
jq -e '(.findings | length) == 1 and (.severity_hypotheses[0].priority == "P1")' \
    "$tmp/prose.out.json" >/dev/null ||
    fail "a mid-sentence badge split the finding or changed its severity: $(cat "$tmp/prose.out.json")"

echo "==> a short comments array against a declared count is indeterminate"
# "Actionable comments posted: 2" with one comment supplied is an incomplete
# input — an unpaginated or partial fetch — and normalizing the shortfall away
# would report a smaller round as complete.
jq '.comments = [.comments[0]]' "$fixtures/coderabbit-cloud/raw.json" >"$tmp/short.json"
set +e
node "$normalizer" --finder coderabbit-cloud --stage integration --round 1 \
    --reviewed-head "$(jq -r '."reviewed-head"' "$fixtures/coderabbit-cloud/args.json")" \
    --input "$tmp/short.json" >/dev/null 2>"$tmp/short.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "an incomplete comments array decoded cleanly (exit $status)"
grep -Fq 'declares 2 actionable comment(s) but 1 were decoded' "$tmp/short.err" ||
    fail "the shortfall was not reported: $(cat "$tmp/short.err")"

echo "==> a count-declaring finder needs its own current-head review as evidence"
# An absent, foreign or stale review meant the completeness check was skipped
# entirely, so a payload of one current comment and no review normalized to one
# finding and exited 0 — the partial fetch this check exists to catch.
for mutation in 'del(.review)' \
    '.review.user.id = 999999' \
    '.review.commit_id = "0000000000000000000000000000000000000000"' \
    '.review.body = "no count stated here"'; do
    jq "$mutation" "$fixtures/coderabbit-cloud/raw.json" >"$tmp/count-evidence.json"
    set +e
    node "$normalizer" --finder coderabbit-cloud --stage integration --round 1 \
        --reviewed-head "$(jq -r '."reviewed-head"' "$fixtures/coderabbit-cloud/args.json")" \
        --input "$tmp/count-evidence.json" >/dev/null 2>"$tmp/count-evidence.err"
    status=$?
    set -e
    [ "$status" -eq 3 ] ||
        fail "a count-declaring finder decoded without usable review evidence ($mutation, exit $status)"
done

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

echo "==> an off-scale badge does not inherit a known badge's priority"
# `anchor: anywhere` was a bare substring test, so `P30` matched the `P3` rule
# and an unknown substantive finding was normalized into the cosmetic,
# non-gating tier — the exact inverse of the rule that an unrecognized badge
# is adjudicated as at least a P2.
head40=3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a
jq -n --arg head "$head40" '{
    review: { state: "COMMENTED", user: { id: 199175422 }, commit_id: $head,
              body: "**P30** something nobody has a rule for\n\n**Reviewed commit:** `\($head)`" }
}' >"$tmp/offscale.json"
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/offscale.json" >"$tmp/offscale.out" 2>&1 || true
if grep -q '"priority": *"P3"' "$tmp/offscale.out"; then
    fail "an off-scale P30 badge was normalized as P3: $(cat "$tmp/offscale.out")"
fi

echo "==> a payload with no current-head evidence is refused, not read as clean"
# An empty or partial GitHub fetch used to emit findings: [] and exit 0, so
# missing terminal evidence was indistinguishable from a reviewer that found
# nothing — and a caller could persist that as a completed slice.
set +e
printf '{}' | node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" >/dev/null 2>"$tmp/empty.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "an empty cloud payload exited $status, not 3"
grep -Fq 'no current-head terminal evidence' "$tmp/empty.err" ||
    fail "the empty-payload refusal did not name its reason: $(cat "$tmp/empty.err")"

echo "==> a current-head review that states no declared verdict is not terminal"
# The floor asks for a TERMINAL result, not merely an artefact. A review at the
# right head from the right actor whose body is pending text — neither the
# declared clean verdict nor anything decodable — used to satisfy it and emit a
# successful empty slice.
jq -n --arg head "$head40" '{
    review: { state: "COMMENTED", user: { id: 199175422 }, commit_id: $head,
              body: "Still working on it, nothing to report yet." }
}' >"$tmp/nonterminal.json"
set +e
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/nonterminal.json" \
    >/dev/null 2>"$tmp/nonterminal.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "a non-terminal current-head review exited $status, not 3"

echo "==> a clean verdict in the finder's own declared words IS terminal"
clean_verdict="$(jq -r '.finders[] | select(.slug == "codex-cloud") | .collection.terminal_signals.clean_verdict' "$registry")"
jq -n --arg head "$head40" --arg v "$clean_verdict" '{
    review: { state: "COMMENTED", user: { id: 199175422 }, commit_id: $head, body: $v }
}' >"$tmp/clean.json"
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/clean.json" >/dev/null ||
    fail "the finder's own declared clean verdict was not accepted as terminal"

echo "==> a terminal artifact on an UNDECLARED surface does not count"
# copilot-cloud declares only `review` and `inline`. A same-actor top-level
# comment stamped with this head must not stand in for a review it never made.
copilot_actor="$(jq -r '.finders[] | select(.slug == "copilot-cloud") | .trusted_actor_id' "$registry")"
jq -n --arg head "$head40" --argjson actor "$copilot_actor" '{
    top_level_comments: [ { id: 1, user: { id: $actor },
                            body: "**Reviewed commit:** `\($head)`\n\nNothing to report." } ]
}' >"$tmp/undeclared.json"
set +e
node "$normalizer" --finder copilot-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/undeclared.json" \
    >/dev/null 2>"$tmp/undeclared.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "a top-level comment satisfied copilot-cloud, which declares no comment surface (exit $status)"

echo "==> an inline comment from an earlier review is refused, not banked"
# A re-trigger without a head change leaves the previous review's comments in
# place. Same actor, same head, different review: banking it reports a stale
# finding as this round's.
jq -n --arg head "$head40" '{
    review: { id: 2, state: "COMMENTED", user: { id: 199175422 }, commit_id: $head,
              body: "Codex Review: didn'"'"'t find any major issues." },
    comments: [ { id: 9, pull_request_review_id: 1, user: { id: 199175422 },
                  original_commit_id: $head, path: "a.js", line: 1,
                  body: "P1 stale finding" } ]
}' >"$tmp/stale-review.json"
set +e
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/stale-review.json" \
    >/dev/null 2>"$tmp/stale-review.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "an inline comment from review 1 was decoded alongside review 2 (exit $status)"
grep -Fq 'belongs to review 1' "$tmp/stale-review.err" ||
    fail "the stale-review refusal did not name the mismatch: $(cat "$tmp/stale-review.err")"

echo "==> an inline comment with no review attribution is refused"
jq -n --arg head "$head40" '{
    review: { id: 2, state: "COMMENTED", user: { id: 199175422 }, commit_id: $head,
              body: "Codex Review: didn'"'"'t find any major issues." },
    comments: [ { id: 9, user: { id: 199175422 }, original_commit_id: $head,
                  path: "a.js", line: 1, body: "P1 unattributed" } ]
}' >"$tmp/unattributed.json"
set +e
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/unattributed.json" \
    >/dev/null 2>"$tmp/unattributed.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "an unattributed inline comment was decoded (exit $status)"

echo "==> a line-start off-scale badge keeps the P2 floor"
# priorityOf() consults the line-start path FIRST, so a boundary check that
# lived only in the fallback path never decided anything.
jq -n --arg head "$head40" '{
    review: { id: 3, state: "COMMENTED", user: { id: 199175422 }, commit_id: $head,
              body: "Codex Review: didn'"'"'t find any major issues." },
    comments: [ { id: 9, pull_request_review_id: 3, user: { id: 199175422 },
                  original_commit_id: $head, path: "a.js", line: 1,
                  body: "P30 an off-scale badge at line start" } ]
}' >"$tmp/leading-offscale.json"
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/leading-offscale.json" \
    >"$tmp/leading-offscale.out" 2>&1 ||
    fail "the line-start off-scale payload was refused outright: $(cat "$tmp/leading-offscale.out")"
grep -q '"priority": *"P3"' "$tmp/leading-offscale.out" &&
    fail "a line-start P30 badge was normalized as P3: $(cat "$tmp/leading-offscale.out")"

echo "==> a quoted clean verdict inside pending narration is not terminal"
# The declared sentence must OPEN the body. Quoting it while saying the review
# is still pending is not a verdict.
jq -n --arg head "$head40" '{
    review: { id: 4, state: "COMMENTED", user: { id: 199175422 }, commit_id: $head,
              body: "Review is still pending; someone quoted: Codex Review: didn'"'"'t find any major issues. No verdict has been issued." }
}' >"$tmp/quoted-clean.json"
set +e
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/quoted-clean.json" \
    >/dev/null 2>"$tmp/quoted-clean.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "a quoted clean verdict inside pending narration exited $status, not 3"

echo "==> a dismissed review is not a clean verdict"
# Under inline-comment-count the review's existence IS the signal, so a
# dismissed review carrying no comments was banked as clean.
for bad_state in DISMISSED PENDING; do
    copilot_actor="$(jq -r '.finders[] | select(.slug == "copilot-cloud") | .trusted_actor_id' "$registry")"
    jq -n --arg head "$head40" --arg st "$bad_state" --argjson actor "$copilot_actor" '{
        review: { id: 5, state: $st, user: { id: $actor }, commit_id: $head, body: "" }
    }' >"$tmp/state-$bad_state.json"
    set +e
    node "$normalizer" --finder copilot-cloud --stage integration --round 1 \
        --registry "$registry" --reviewed-head "$head40" <"$tmp/state-$bad_state.json" >/dev/null 2>&1
    status=$?
    set -e
    [ "$status" -eq 3 ] || fail "a $bad_state review was accepted as terminal (exit $status)"
done

echo "==> a review with no state at all is refused"
copilot_actor="$(jq -r '.finders[] | select(.slug == "copilot-cloud") | .trusted_actor_id' "$registry")"
jq -n --arg head "$head40" --argjson actor "$copilot_actor" '{
    review: { id: 6, user: { id: $actor }, commit_id: $head, body: "" }
}' >"$tmp/state-absent.json"
set +e
node "$normalizer" --finder copilot-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/state-absent.json" >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 3 ] || fail "a review with no state was accepted as terminal (exit $status)"

echo "==> a success reaction on the trigger IS a terminal clean result"
# codex-cloud declares `reaction` as a terminal surface and the integrate
# checker already treats a fresh +1 on the trigger as clean; refusing it here
# blocked a genuinely complete cycle.
success_reaction="$(jq -r '.finders[] | select(.slug == "codex-cloud") | .collection.terminal_signals.success_reaction' "$registry")"
jq -n --arg r "$success_reaction" '{
    trigger_reactions: [ { content: $r, user: { id: 199175422 } } ]
}' >"$tmp/reaction.json"
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/reaction.json" >/dev/null ||
    fail "a declared success reaction on the trigger was not accepted as terminal"

echo "==> another actor's reaction is not this finder's verdict"
jq -n --arg r "$success_reaction" '{
    trigger_reactions: [ { content: $r, user: { id: 1 } } ]
}' >"$tmp/reaction-foreign.json"
set +e
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/reaction-foreign.json" >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 3 ] || fail "a stray reaction from another actor was accepted as terminal (exit $status)"

# ── #819: abbreviated SHA in a top-level comment stamp ──────────────────────
echo "==> an abbreviated SHA stamp with findings that prefix-matches the head is refused"
jq -n --arg head "$head40" '{
    top_level_comments: [ { id: 8190, user: { id: 199175422 },
        body: "**P1** Something wrong.\n\n**Reviewed commit:** `'"${head40:0:7}"'`" } ]
}' >"$tmp/abbrev-stamp.json"
set +e
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/abbrev-stamp.json" \
    >/dev/null 2>"$tmp/abbrev-stamp.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "an abbreviated stamp with findings was accepted (exit $status)"
grep -Fq 'abbreviated SHA' "$tmp/abbrev-stamp.err" ||
    fail "the abbreviated-stamp refusal did not name its reason: $(cat "$tmp/abbrev-stamp.err")"

echo "==> an abbreviated SHA stamp without findings is skipped when other evidence exists"
jq -n --arg head "$head40" '{
    review: { id: 819, state: "COMMENTED", user: { id: 199175422 }, commit_id: $head,
              body: "Codex Review: didn'"'"'t find any major issues." },
    top_level_comments: [ { id: 8192, user: { id: 199175422 },
        body: "Nothing to report.\n\n**Reviewed commit:** `'"${head40:0:10}"'`" } ]
}' >"$tmp/abbrev-with-review.json"
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/abbrev-with-review.json" \
    >"$tmp/abbrev-with-review.out" 2>&1 ||
    fail "an abbreviated stamp alongside a clean review killed the decoder"
jq -e '(.findings | length) == 0' "$tmp/abbrev-with-review.out" >/dev/null ||
    fail "the abbreviated unlabelled comment produced findings"

echo "==> an abbreviated SHA stamp for a DIFFERENT head is skipped, not refused"
# The stamp is short but does not prefix-match the reviewed head, so it is
# clearly about a different commit — skip it rather than dying.
jq -n --arg head "$head40" '{
    review: { id: 819, state: "COMMENTED", user: { id: 199175422 }, commit_id: $head,
              body: "Codex Review: didn'"'"'t find any major issues." },
    top_level_comments: [ { id: 8191, user: { id: 199175422 },
        body: "**P1** Old finding.\n\n**Reviewed commit:** `abcdef0`" } ]
}' >"$tmp/abbrev-other.json"
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/abbrev-other.json" \
    >"$tmp/abbrev-other.out" 2>&1 ||
    fail "an abbreviated stamp for a different head caused a hard failure"
jq -e '(.findings | length) == 0' "$tmp/abbrev-other.out" >/dev/null ||
    fail "a non-matching abbreviated stamp produced findings"

# ── #829: narration after a clean verdict ───────────────────────────────────
echo "==> narration on a subsequent line after a clean verdict is not terminal"
jq -n --arg head "$head40" '{
    review: { id: 829, state: "COMMENTED", user: { id: 199175422 }, commit_id: $head,
              body: "Codex Review: didn'"'"'t find any major issues.\n\nHowever, you might want to reconsider the approach." }
}' >"$tmp/narration.json"
set +e
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/narration.json" \
    >/dev/null 2>"$tmp/narration.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "a clean verdict with trailing narration was accepted as terminal (exit $status)"

echo "==> a clean verdict followed by declared metadata IS terminal"
jq -n --arg head "$head40" '{
    review: { id: 8291, state: "COMMENTED", user: { id: 199175422 }, commit_id: $head,
              body: "Codex Review: didn'"'"'t find any major issues.\n\n**Reviewed commit:** `'"$head40"'`" }
}' >"$tmp/clean-meta.json"
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/clean-meta.json" >/dev/null ||
    fail "a clean verdict with only declared metadata was not accepted as terminal"

echo "==> the real Codex clean layout — verdict, praise, metadata, About block — IS terminal"
jq -n --arg head "$head40" '{
    review: { id: 8292, state: "COMMENTED", user: { id: 199175422 }, commit_id: $head,
              body: ("Codex Review: didn'"'"'t find any major issues. Keep it up!\n\n" +
                     "**Reviewed commit:** `" + $head + "`\n\n" +
                     "<details> <summary>About Codex in GitHub</summary>\n" +
                     "Reviews are triggered when you open a pull request.\n</details>") }
}' >"$tmp/real-layout.json"
node "$normalizer" --finder codex-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/real-layout.json" >/dev/null ||
    fail "the real Codex clean layout was not accepted as terminal"

# ── #837: review-body findings counted before actionable check ──────────────
echo "==> a zero-count review whose body carries a severity phrase does not pass and emit"
coderabbit_head="$(jq -r '."reviewed-head"' "$fixtures/coderabbit-cloud/args.json")"
coderabbit_actor="$(jq -r '.finders[] | select(.slug == "coderabbit-cloud") | .trusted_actor_id' "$registry")"
jq -n --arg head "$coderabbit_head" --argjson actor "$coderabbit_actor" '{
    review: { id: 837, state: "COMMENTED", commit_id: $head,
              user: { id: $actor },
              body: "Actionable comments posted: 0\n\nPotential issue in scripts/foo.sh:1 — risk" },
    comments: []
}' >"$tmp/zero-count-body.json"
set +e
node "$normalizer" --finder coderabbit-cloud --stage integration --round 1 \
    --reviewed-head "$coderabbit_head" <"$tmp/zero-count-body.json" \
    >/dev/null 2>"$tmp/zero-count-body.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "a zero-count review with a body finding passed the count check (exit $status)"

# ── #840: inline comment from a dismissed review ────────────────────────────
echo "==> a dismissed review's inline comment is not terminal and not emitted"
copilot_actor="$(jq -r '.finders[] | select(.slug == "copilot-cloud") | .trusted_actor_id' "$registry")"
jq -n --arg head "$head40" --argjson actor "$copilot_actor" '{
    review: { id: 840, state: "DISMISSED", user: { id: $actor }, commit_id: $head, body: "" },
    comments: [ { id: 8401, pull_request_review_id: 840, user: { id: $actor },
                  original_commit_id: $head, commit_id: $head,
                  path: "a.js", line: 1, body: "something wrong here" } ]
}' >"$tmp/dismissed-inline.json"
set +e
node "$normalizer" --finder copilot-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/dismissed-inline.json" \
    >/dev/null 2>"$tmp/dismissed-inline.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "a dismissed review's inline comment was accepted as terminal (exit $status)"

echo "==> a PENDING review's inline comment is not terminal and not emitted"
jq -n --arg head "$head40" --argjson actor "$copilot_actor" '{
    review: { id: 8402, state: "PENDING", user: { id: $actor }, commit_id: $head, body: "" },
    comments: [ { id: 8403, pull_request_review_id: 8402, user: { id: $actor },
                  original_commit_id: $head, commit_id: $head,
                  path: "b.js", line: 5, body: "also wrong" } ]
}' >"$tmp/pending-inline.json"
set +e
node "$normalizer" --finder copilot-cloud --stage integration --round 1 \
    --registry "$registry" --reviewed-head "$head40" <"$tmp/pending-inline.json" \
    >/dev/null 2>"$tmp/pending-inline.err"
status=$?
set -e
[ "$status" -eq 3 ] || fail "a pending review's inline comment was accepted as terminal (exit $status)"

echo "finder normalization OK ($cases fixture(s))"
