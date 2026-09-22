#!/usr/bin/env bash
# Prose-contract tests for the two rendered implementer brief templates:
# the implement skill's base contract and the orchestrator's dev-flow-v2
# lane superset. Both are rendered with fixture values and asserted against
# their mandatory sections, their external source catalogs, and the strings
# a dispatched worker has historically needed and not been given.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    echo "FAIL: $*" >&2
    exit 1
    return 0
}

template="ai/skills/universal/orchestrate/assets/lane-brief.md"
rendered="$(<"$template")"

required_placeholders=(
    '{{active-state-path}}'
    '{{attempt-nonce}}'
    '{{base-sha}}'
    '{{brief-envelope-json}}'
    '{{blocked-sentinel}}'
    '{{branch}}'
    '{{challenge-cap}}'
    '{{claim-handoff}}'
    '{{deadline}}'
    '{{default-branch}}'
    '{{file-scope-fence}}'
    '{{generation}}'
    '{{git-sandbox-note}}'
    '{{handoff-sentinel}}'
    '{{harness}}'
    '{{integration-cap}}'
    '{{issue-number}}'
    '{{issue-title}}'
    '{{issue-url}}'
    '{{known-environmental-failure}}'
    '{{lane-name}}'
    '{{live-lane-overlaps}}'
    '{{max-agent-runs}}'
    '{{max-parallel-agents}}'
    '{{min-rounds}}'
    '{{operator-pins}}'
    '{{policy-projection}}'
    '{{pr-title}}'
    '{{ready-sentinel}}'
    '{{record-directory}}'
    '{{remediation-cap}}'
    '{{report-path}}'
    '{{review-cap}}'
    '{{rigor}}'
    '{{rigor-source}}'
    '{{role-tiers}}'
    '{{run-id}}'
    '{{scratch-dir}}'
    '{{strategy}}'
    '{{strategy-source}}'
    '{{verified-facts-and-rulings}}'
    '{{wall-clock-min}}'
    '{{worktree-path}}'
)

placeholders=()
while IFS= read -r token; do
    placeholders[${#placeholders[@]}]="$token"
done < <(grep -oE '\{\{[a-z0-9-]+\}\}' "$template" | sort -u)

[ "${#placeholders[@]}" -eq "${#required_placeholders[@]}" ] ||
    fail "template placeholder set differs from the required contract"
for expected in "${required_placeholders[@]}"; do
    found=0
    for token in "${placeholders[@]}"; do
        if [ "$token" = "$expected" ]; then
            found=1
            break
        fi
    done
    [ "$found" -eq 1 ] || fail "missing required placeholder: $expected"
done

for token in "${placeholders[@]}"; do
    grep -Fq "| \`$token\` |" ai/skills/universal/orchestrate/SKILL.md ||
        fail "$token is absent from the external placeholder source catalog"
    key="${token#\{\{}"
    key="${key%\}\}}"
    case "$key" in
    brief-envelope-json)
        value="$(awk '/^```json$/{capture=1;next} /^```$/{capture=0} capture' \
            ai/schemas/fixtures/brief.envelope/valid/minimal.md)"
        ;;
    ready-sentinel) value="LANE-FIXTURE-READY" ;;
    handoff-sentinel) value="LANE-FIXTURE-HANDOFF" ;;
    blocked-sentinel) value="LANE-FIXTURE-BLOCKED" ;;
    attempt-nonce) value="a1b2c3" ;;
    *) value="fixture-$key" ;;
    esac
    rendered="${rendered//"$token"/"$value"}"
done

rendered_file="$(mktemp)"
impl_rendered_file="$(mktemp)"
trap 'rm -f "$rendered_file" "$impl_rendered_file"' EXIT
printf '%s\n' "$rendered" >"$rendered_file"

if grep -Eq '\{\{[a-z0-9-]+\}\}' "$rendered_file"; then
    fail "rendered fixture retains a placeholder"
fi

node ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs brief "$rendered_file" >/dev/null ||
    fail "rendered fixture does not satisfy the brief envelope schema"

headings=(
    '## Identity and boundaries'
    '## File-scope fence'
    '## Scope — one issue, one PR'
    '## Procedure'
    '### Claude Code (Skill tool)'
    '### Codex CLI (read the skill)'
    '### Other supported harness (read the skill)'
    '## Long-running gate invocations'
    '## Known environmental failure'
    '## Stage-exit rules'
    '## Readiness gate'
    '## Resolved policy'
    '## PR requirements'
    '## Reporting protocol'
)
previous=0
for heading in "${headings[@]}"; do
    line="$(grep -nFx "$heading" "$rendered_file" | cut -d: -f1)"
    [ -n "$line" ] || fail "missing converged section: $heading"
    [ "$line" -gt "$previous" ] || fail "section is out of order: $heading"
    previous="$line"
done

exit_rules=(
    'A confidence stage exits after two CONSECUTIVE rounds each adjudicating to zero P0/P1; a round with a confirmed P0/P1 is not clean, whatever was fixed, and a round with only P2s counts as clean for this exit but is NOT the no-findings exit.'
    'A confidence stage exits after a round with NO findings at all (any severity) once at least `min_rounds` rounds have run.'
    'A confidence stage exits after a capped final round adjudicating to zero P0/P1.'
)
for rule in "${exit_rules[@]}"; do
    grep -Fq "$rule" "$rendered_file" || fail "missing exact stage-exit rule: $rule"
done

grep -Fq 'immediately before `gh pr ready`' "$rendered_file" ||
    fail "missing immediate pre-promotion re-read rule"
grep -Fq 'Active `run.json.started_at` plus `wall_clock_min`' "$rendered_file" ||
    fail "deadline is not sourced from the active run start"
grep -Fq 'raw pane-history' "$rendered_file" ||
    fail "sentinel observation does not reject raw pane history"
grep -Fq 'substring match is never completion evidence' "$rendered_file" ||
    fail "sentinel observation is not final-line anchored"
grep -Fq 'return control to the supervising orchestrator' "$rendered_file" ||
    fail "lane integration handoff is missing"
grep -Fq 'Confidence-stage decision handshake' "$rendered_file" ||
    fail "confidence-stage decision handshake is missing"
grep -Fq 'Do not infer a disposition from silence' "$rendered_file" ||
    fail "confidence-stage decision wait is not fail-closed"
grep -Fq 'never adjudicates integration findings' "$rendered_file" ||
    fail "integration-only adjudication boundary is missing"
grep -Fq 'This lane'"'"'s branch and worktree were provisioned before dispatch. Override' \
    "$rendered_file" ||
    fail "pre-created lane branch does not override implement branch creation"
grep -Fq '`/implement` step 3: do not fetch-and-switch or create a branch' \
    "$rendered_file" ||
    fail "provisioned lane worktree is not retained"
grep -Fq 'dispatches a fresh implementer' "$rendered_file" ||
    fail "confidence remediation does not preserve fresh implementer dispatch"
grep -Fq 'no fresh-implementer dispatch surface exists' "$rendered_file" ||
    fail "inline confidence fallback has no authorized remediation path"
grep -Fq 'Never apply a fix without the matching explicit' "$rendered_file" ||
    fail "inline remediation is not bound to an orchestrator disposition"
grep -Fq 'orchestrator-provisioned' "$rendered_file" ||
    fail "inline confidence tasks have no persistent session requirement"
grep -Fq 'plain shell `&` backgrounding is not persistent evidence' \
    "$rendered_file" ||
    fail "ordinary shell backgrounding can masquerade as persistence"

grep -Fq 'every end-to-end, PR-owning implementation lane' \
    ai/skills/universal/orchestrate/SKILL.md ||
    fail "lane template is not scoped to PR-owning dispatches"
grep -Fq 'bounded remediation implementers, use their schema-bound role briefs' \
    ai/skills/universal/orchestrate/SKILL.md ||
    fail "non-PR implementer dispatches can receive the lane template"
grep -Fq "step 1's session/agent ownership comparison" "$rendered_file" ||
    fail "orchestrator claim handoff does not override implement session matching"
grep -Fq 'delegated use of the existing claim, not a claim transfer' \
    "$rendered_file" ||
    fail "claim handoff can be mistaken for ownership transfer"
grep -Fq "snapshot's recorded branch must equal" "$rendered_file" ||
    fail "claim handoff is not bound to the provisioned lane branch"
grep -Fq 'transactionally refresh the existing' \
    ai/skills/universal/orchestrate/SKILL.md ||
    fail "orchestrator does not refresh the claim after lane provisioning"
grep -Fq 'fixture-issue-url' "$rendered_file" ||
    fail "canonical issue URL is not passed through the rendered brief"
grep -Fq 'git check-ignore -q --no-index' "$rendered_file" ||
    fail "in-worktree report paths are not verified as excluded"
if grep -Fq '| Placeholder | Source |' "$rendered_file"; then
    fail "free-form values can still be substituted into an output catalog"
fi

for sentinel in \
    LANE-FIXTURE-READY-a1b2c3 \
    LANE-FIXTURE-HANDOFF-a1b2c3 \
    LANE-FIXTURE-BLOCKED-a1b2c3; do
    count="$(grep -Fc "$sentinel" "$rendered_file")"
    [ "$count" -eq 1 ] || fail "$sentinel must appear exactly once (found $count)"
    line="$(grep -nF "$sentinel" "$rendered_file" | cut -d: -f1)"
    reporting_line="$(grep -nFx '## Reporting protocol' "$rendered_file" | cut -d: -f1)"
    [ "$line" -gt "$reporting_line" ] || fail "$sentinel appears outside Reporting protocol"
done

# ── The implement skill's base brief template ──────────────────────────────
# harmon-devkit#855: the gate bounds, the stop-at-draft rule, and the
# proposal-only clause ship from a template rather than an orchestrator's
# memory. harmon-devkit#1051: the delegation contract is stated exactly once.

impl_template="ai/skills/universal/implement/assets/implementer-brief.md"
impl_catalog="ai/skills/universal/implement/SKILL.md"
[ -f "$impl_template" ] || fail "the implement skill ships no brief template"
impl_rendered="$(<"$impl_template")"

impl_required_placeholders=(
    '{{attempt-nonce}}'
    '{{base-sha}}'
    '{{blocked-sentinel}}'
    '{{branch}}'
    '{{codex-model-id}}'
    '{{default-branch}}'
    '{{file-scope-fence}}'
    '{{gate-bounds-override}}'
    '{{git-sandbox-note}}'
    '{{handoff-sentinel}}'
    '{{harness}}'
    '{{issue-number}}'
    '{{issue-title}}'
    '{{issue-url}}'
    '{{live-lane-overlaps}}'
    '{{policy-profile}}'
    '{{pr-title}}'
    '{{repo-tier}}'
    '{{report-path}}'
    '{{scratch-dir}}'
    '{{unit-kind}}'
    '{{unit-name}}'
    '{{verified-facts-and-rulings}}'
    '{{worktree-path}}'
)

impl_placeholders=()
while IFS= read -r token; do
    impl_placeholders[${#impl_placeholders[@]}]="$token"
done < <(grep -oE '\{\{[a-z0-9-]+\}\}' "$impl_template" | sort -u)

[ "${#impl_placeholders[@]}" -eq "${#impl_required_placeholders[@]}" ] ||
    fail "implementer-brief placeholder set differs from the required contract"
for expected in "${impl_required_placeholders[@]}"; do
    found=0
    for token in "${impl_placeholders[@]}"; do
        if [ "$token" = "$expected" ]; then
            found=1
            break
        fi
    done
    [ "$found" -eq 1 ] || fail "implementer-brief is missing required placeholder: $expected"
done

# There is no ready sentinel: a dispatched worker never promotes its own PR.
# The set-equality check above already proves the token is absent; this states
# why, so a later edit that adds one fails against an intent rather than a list.
grep -Fq 'There is no third sentinel here.' "$impl_template" ||
    fail "implementer-brief does not state why it carries no ready sentinel"

for token in "${impl_placeholders[@]}"; do
    grep -Fq "| \`$token\` |" "$impl_catalog" ||
        fail "$token is absent from the implement skill's external source catalog"
    key="${token#\{\{}"
    key="${key%\}\}}"
    case "$key" in
    handoff-sentinel) value="IMPL-FIXTURE-HANDOFF" ;;
    blocked-sentinel) value="IMPL-FIXTURE-BLOCKED" ;;
    attempt-nonce) value="a1b2c3" ;;
    *) value="fixture-$key" ;;
    esac
    impl_rendered="${impl_rendered//"$token"/"$value"}"
done

printf '%s\n' "$impl_rendered" >"$impl_rendered_file"

if grep -Eq '\{\{[a-z0-9-]+\}\}' "$impl_rendered_file"; then
    fail "rendered implementer-brief retains a placeholder"
fi
if grep -Fq '| Placeholder | Source |' "$impl_rendered_file"; then
    fail "free-form values can still be substituted into an output catalog"
fi

impl_headings=(
    '## Identity and boundaries'
    '## Hard rules'
    '## File-scope fence'
    '## Scope — one issue, one PR'
    '## Delegation contract'
    '## Gate commands and time bounds'
    '## Proposal-only units'
    '## Harness: Claude Code'
    '## Harness: Codex'
    '## Harness: other'
    '## PR requirements'
    '## Reporting protocol'
)
previous=0
for heading in "${impl_headings[@]}"; do
    line="$(grep -nFx "$heading" "$impl_rendered_file" | cut -d: -f1)"
    [ -n "$line" ] || fail "implementer-brief is missing mandatory section: $heading"
    [ "$line" -gt "$previous" ] || fail "implementer-brief section is out of order: $heading"
    previous="$line"
done

# Hard rules — each one a prohibition a dispatched worker has actually broken.
impl_hard_rules=(
    '**Never run `gh pr ready`.**'
    '**Never merge and never cut a release**'
    '**Never rewrite pushed history.**'
    '**Never bypass a git hook.**'
    '**Never disable a stop-gate.**'
)
for rule in "${impl_hard_rules[@]}"; do
    grep -Fq "$rule" "$impl_rendered_file" || fail "implementer-brief is missing hard rule: $rule"
done

# Gate bounds: the 180-second-timeout failure is the reason this table exists,
# so the tier rows and their numbers are pinned, not just the heading.
grep -Fq 'Resolved tier for this unit: **fixture-repo-tier**' "$impl_rendered_file" ||
    fail "implementer-brief does not resolve a gate-bounds tier per dispatch"
for tier_row in \
    '| `light` — docs/config repo' \
    '| `standard` — ordinary app repo' \
    '| `heavy` — large shell/lint surface'; do
    grep -Fq "$tier_row" "$impl_rendered_file" ||
        fail "implementer-brief gate-bounds table is missing row: $tier_row"
done
grep -Fq '[HUMAN] maintainer confirms' "$impl_rendered_file" ||
    fail "implementer-brief gate bounds are not marked for maintainer confirmation"
grep -Fq 'A bound is the point at which you stop waiting, never the point at which you' \
    "$impl_rendered_file" ||
    fail "implementer-brief treats a hit timeout as a gate failure"
grep -Fq 'GATE-EXIT=' "$impl_rendered_file" ||
    fail "implementer-brief does not require a polled exit line for a long gate"

# Proposal-only: "proposal only" was read as "no pull request".
grep -Fq '**A proposal-only unit still runs every gate, still commits, still pushes, and' \
    "$impl_rendered_file" ||
    fail "implementer-brief proposal-only clause does not require the delivery path"
grep -Fq 'as "no pull request"' "$impl_rendered_file" ||
    fail "implementer-brief does not name the observed proposal-only misreading"
grep -Fq 'still opens the DRAFT PR. It stops there.' "$impl_rendered_file" ||
    fail "implementer-brief proposal-only clause does not stop at the draft PR"

# Codex variant: launch flags, the effort caveat, and the explicit prohibition.
# Assert the flags inside the launch COMMAND, not merely somewhere in the
# section: the prose below the block also names the update-check flag, so a
# whole-file grep stays green after the command loses it.
impl_launch="$(awk '
    /^codex --model / { collecting = 1 }
    collecting { print; if ($0 !~ /\\$/) exit }
' "$impl_rendered_file")"
[ -n "$impl_launch" ] ||
    fail "implementer-brief Codex block carries no codex launch command"
case "$impl_launch" in
*'codex --model fixture-codex-model-id'*) ;;
*) fail "implementer-brief Codex launch command does not carry the rendered model" ;;
esac
case "$impl_launch" in
*'-c check_for_update_on_startup=false'*) ;;
*) fail "implementer-brief Codex launch command is missing the update-check flag" ;;
esac
case "$impl_launch" in
*'--dangerously-bypass-approvals-and-sandbox'*) ;;
*) fail "implementer-brief Codex launch command is missing the sandbox flag" ;;
esac
grep -Fq '`-c model_reasoning_effort` is accepted' "$impl_rendered_file" ||
    fail "implementer-brief Codex block is missing the reasoning-effort caveat"
grep -Fq 'The TUI `/model` picker is the only lever' "$impl_rendered_file" ||
    fail "implementer-brief Codex block does not name the effort lever"
grep -Fq '**A Codex brief forbids `gh pr ready` explicitly.**' "$impl_rendered_file" ||
    fail "implementer-brief Codex block does not restate the promotion prohibition"

# The five delegation invariants (#296, #438, #447, #582, #431), stated once.
impl_contract_rules=(
    '**Exit plan mode before spawning an implementer.**'
    "**You share the caller's working tree and \`HEAD\`.**"
    '**Keep the core work in your own context — no sub-delegation.**'
    '**Namespace every scratch file under `fixture-scratch-dir`.**'
    '**Report through `fixture-report-path` and the sentinels below, and re-read every'
)
for rule in "${impl_contract_rules[@]}"; do
    grep -Fq "$rule" "$impl_rendered_file" ||
        fail "implementer-brief delegation contract is missing: $rule"
done
grep -Fq 'gate result standing in for the **PR' "$impl_rendered_file" ||
    fail "delegation contract does not name the local-for-PR gate substitution"
grep -Fq '"replied" and "resolved" are distinct thread states' "$impl_rendered_file" ||
    fail "delegation contract collapses replied and resolved"
grep -Fq 'never reconstruct, abbreviate from' "$impl_rendered_file" ||
    fail "delegation contract does not require verbatim SHAs"
grep -Fq 'prefer an isolated worktree' "$impl_rendered_file" ||
    fail "delegation contract does not offer the structural fix for a shared HEAD"
grep -Fq 'a dirty index, a stash entry, or' "$impl_rendered_file" ||
    fail "delegation contract names only branches as the shared-tree exposure"
grep -Fq 'Read-only fan-out' "$impl_rendered_file" ||
    fail "delegation contract does not distinguish allowed read-only fan-out"
grep -Fq 'may be unresumable' "$impl_rendered_file" ||
    fail "delegation contract omits the plan-mode recovery path"
grep -Fq 'never at the scratchpad' "$impl_rendered_file" ||
    fail "delegation contract does not forbid the scratchpad root"

# Fence prose, identical to the lane superset so the two cannot drift.
grep -Fq 'A validator or test that rejects your change and that no other live lane touches' \
    "$impl_rendered_file" ||
    fail "implementer-brief lost the bounded self-expansion clause"
grep -Fq 'For every other out-of-fence edit, append a dated blocker' "$impl_rendered_file" ||
    fail "implementer-brief lost the out-of-fence STOP rule"
grep -Fq 'git check-ignore -q --no-index' "$impl_rendered_file" ||
    fail "implementer-brief does not verify an in-worktree report path is excluded"

# PR requirements, including the profile line #855 asks for.
grep -Fq '**Include the profile line**' "$impl_rendered_file" ||
    fail "implementer-brief does not require the PR-body profile line"
grep -Fq 'every off-profile choice — model family, tier, or' "$impl_rendered_file" ||
    fail "PR-body profile line does not require off-profile disclosure"
grep -Fq 'gh pr create --draft' "$impl_rendered_file" ||
    fail "implementer-brief does not open the PR as a draft"

# Sentinels: exactly one occurrence each, inside the reporting section.
impl_reporting_line="$(grep -nFx '## Reporting protocol' "$impl_rendered_file" | cut -d: -f1)"
for sentinel in IMPL-FIXTURE-HANDOFF-a1b2c3 IMPL-FIXTURE-BLOCKED-a1b2c3; do
    count="$(grep -Fc "$sentinel" "$impl_rendered_file")"
    [ "$count" -eq 1 ] || fail "$sentinel must appear exactly once (found $count)"
    line="$(grep -nF "$sentinel" "$impl_rendered_file" | cut -d: -f1)"
    [ "$line" -gt "$impl_reporting_line" ] ||
        fail "$sentinel appears outside Reporting protocol"
done
grep -Fq 'raw pane-history substring match' "$impl_rendered_file" ||
    fail "implementer-brief accepts pane history as completion evidence"

# The orchestrator-facing instruction, in both dispatching skills.
grep -Fq 'Render `assets/implementer-brief.md`. Never write the brief freehand.' \
    "$impl_catalog" ||
    fail "the implement skill does not require rendering the template"
grep -Fq 'Brief template source catalog' "$impl_catalog" ||
    fail "the implement skill ships no external source catalog"
grep -Fq 'Never write an implementer brief freehand, whatever its shape.' \
    ai/skills/universal/orchestrate/SKILL.md ||
    fail "the orchestrate skill permits a freehand implementer brief"
grep -Fq 'assets/implementer-brief.md' ai/skills/universal/orchestrate/SKILL.md ||
    fail "the orchestrate skill does not point non-v2 dispatches at the base template"

# Stated once: the lane superset and every agent reference it, none restates it.
for referrer in \
    ai/skills/universal/orchestrate/assets/lane-brief.md \
    ai/agents/README.md \
    ai/agents/implementer.md \
    ai/agents/challenger.md \
    ai/agents/reviewer.md \
    ai/agents/integrator.md; do
    grep -Fq 'implementer-brief.md' "$referrer" ||
        fail "$referrer does not reference the one delegation contract"
    for rule in "${impl_contract_rules[@]}"; do
        if grep -Fq "$rule" "$referrer"; then
            fail "$referrer restates the delegation contract instead of referencing it"
        fi
    done
done

echo "implementer-brief template: ok"
echo "lane-brief template: ok"
