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
    '{{blocked-sentinel}}'
    '{{branch}}'
    '{{brief-envelope-json}}'
    '{{challenge-cap}}'
    '{{claim-handoff}}'
    '{{deadline}}'
    '{{default-branch}}'
    '{{file-scope-fence}}'
    '{{gate-bounds-override}}'
    '{{gate-commands}}'
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
    '{{repo-tier}}'
    '{{report-path}}'
    '{{review-cap}}'
    '{{rigor-source}}'
    '{{rigor}}'
    '{{role-tiers}}'
    '{{run-id}}'
    '{{scratch-dir}}'
    '{{strategy-source}}'
    '{{strategy}}'
    '{{verified-facts-and-rulings}}'
    '{{wall-clock-min}}'
    '{{worktree-path}}'
)

# The prose rule is "any double-brace token", so the machine check is too:
# a narrower class (lowercase/digit/hyphen) let `{{scratch_dir}}`, `{{Branch}}`
# or `{{ branch }}` sit in the template unseen by BOTH the set-equality check
# and the unrendered-token gate, shipping a literal token to a worker.
placeholders=()
while IFS= read -r token; do
    placeholders[${#placeholders[@]}]="$token"
done < <(grep -oE '\{\{[^}]*\}\}' "$template" | sort -u)

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

if grep -Eq '\{\{[^}]*\}\}' "$rendered_file"; then
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
    '{{claim-handoff}}'
    '{{codex-launch-flags}}'
    '{{codex-model-id}}'
    '{{default-branch}}'
    '{{effort}}'
    '{{file-scope-fence}}'
    '{{gate-bounds-override}}'
    '{{gate-commands}}'
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
done < <(grep -oE '\{\{[^}]*\}\}' "$impl_template" | sort -u)

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
    # The tier selects a table row, so the fixture must render a REAL one.
    # Rendering it as `fixture-repo-tier` made the regression floor itself a
    # demonstration that an out-of-vocabulary tier passes clean.
    repo-tier) value="heavy" ;;
    *) value="fixture-$key" ;;
    esac
    impl_rendered="${impl_rendered//"$token"/"$value"}"
done

printf '%s\n' "$impl_rendered" >"$impl_rendered_file"

if grep -Eq '\{\{[^}]*\}\}' "$impl_rendered_file"; then
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
grep -Fq 'Resolved tier for this unit: **heavy**' "$impl_rendered_file" ||
    fail "implementer-brief does not resolve a gate-bounds tier per dispatch"
for tier_row in '| `light` |' '| `standard` |' '| `heavy` |'; do
    grep -Fq "$tier_row" "$impl_rendered_file" ||
        fail "implementer-brief gate-bounds table is missing row: $tier_row"
done
# The tier selects a table row, so it must be constrained to that table's
# vocabulary. Rendering it as free prose let `medium`/`docs`/`small` produce a
# brief pointing at no row at all — the worker then picks a bound from nothing,
# which is the failure the table exists to prevent.
grep -Fq 'one of `light`, `standard`, or' "$impl_rendered_file" ||
    fail "implementer-brief does not enumerate the legal gate tiers"
grep -Fq 'report BLOCKED rather than picking a row' "$impl_rendered_file" ||
    fail "implementer-brief accepts an out-of-vocabulary gate tier"
# A repo can match more than one row's description, so the row is decided by a
# procedure, not by resemblance — and the asymmetric direction has to win.
grep -Fq 'strongest signal wins' "$impl_rendered_file" ||
    fail "implementer-brief gate tier has no tie-break procedure"
grep -Fq 'does **not** make a repository `light`' "$impl_rendered_file" ||
    fail "implementer-brief does not close the observed light/heavy misread"
# Gate NAMES are not invocations; a worker in a repo whose gates are not
# `task <name>` was handed bounds for commands it never received.
grep -Fq 'Run the gates with these exact commands' "$impl_rendered_file" ||
    fail "implementer-brief bounds gates it never names a command for"
grep -Fq 'fixture-gate-commands' "$impl_rendered_file" ||
    fail "implementer-brief does not render the repository's gate commands"
# The maintainer-confirmation note belongs to the authoring procedure, not to
# the artifact a worker reads; `[HUMAN]` is this repo's issue-criteria grammar.
if grep -Fq '[HUMAN]' "$impl_rendered_file"; then
    fail "implementer-brief freezes an authoring marker into the dispatched artifact"
fi
grep -Fq 'The gate bounds are defaults, not a repository contract.' "$impl_catalog" ||
    fail "the implement skill does not carry the gate-bounds provenance note"
grep -Fq 'A bound is the point at which you stop waiting, never the point at which you' \
    "$impl_rendered_file" ||
    fail "implementer-brief treats a hit timeout as a gate failure"
# The same whole-file hole the Codex block already closed: `GATE-EXIT=` occurs
# twice — once inside the nohup recipe that produces it, once in the prose that
# polls for it — so a whole-file grep stays green after the recipe loses it,
# shipping a detach pattern that writes no exit line against a template whose
# own rule is "an absent exit line is not a pass".
impl_detach="$(grep -F 'nohup bash -c' "$impl_rendered_file")"
[ -n "$impl_detach" ] ||
    fail "implementer-brief carries no detached-gate recipe"
case "$impl_detach" in
*'echo GATE-EXIT='*) ;;
*) fail "implementer-brief detach recipe does not emit the polled exit line" ;;
esac
grep -Fq 'until it contains `GATE-EXIT=`' "$impl_rendered_file" ||
    fail "implementer-brief does not require polling for the exit line"

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
# The launch command must carry the dispatcher's RENDERED approval/sandbox
# policy, never a hardcoded one. Hardcoding the bypass flag mandated a
# sandbox-off dispatch for every consumer and left the Git/sandbox rule and the
# file-scope fence with no enforcement layer at all.
case "$impl_launch" in
*'fixture-codex-launch-flags'*) ;;
*) fail "implementer-brief Codex launch command does not render the dispatcher's sandbox policy" ;;
esac
case "$impl_launch" in
*'--dangerously-bypass'*) fail "implementer-brief hardcodes a sandbox-off Codex launch" ;;
esac
grep -Fq -e '-a never -s workspace-write' "$impl_rendered_file" ||
    fail "implementer-brief does not name the sandboxed launch default"
grep -Fq 'deliberate per-dispatch override, never the default' "$impl_rendered_file" ||
    fail "implementer-brief does not mark the sandbox-off launch as an override"
grep -Fq 'every boundary in this brief is prose alone' "$impl_rendered_file" ||
    fail "implementer-brief does not say what running outside the sandbox costs"
grep -Fq 'launched outside the sandbox' "$impl_rendered_file" ||
    fail "a sandbox-off Codex dispatch is not disclosed on the profile line"
grep -Fq 'model_reasoning_effort` is accepted and ignored' "$impl_rendered_file" ||
    fail "implementer-brief Codex block is missing the reasoning-effort caveat"
grep -Fq 'The TUI `/model` picker is the only lever' "$impl_rendered_file" ||
    fail "implementer-brief Codex block does not name the effort lever"
# A caveat pinned to one exact patch version reads as not applying anywhere
# else, and the failure it guards is silent (the flag is accepted either way).
grep -Fq 'through at least 0.155.1' "$impl_rendered_file" ||
    fail "implementer-brief pins the effort caveat to a single build"
# The BLOCKED-on-mismatch rule cannot fire unless the effort is an input the
# worker can actually identify in its own brief.
grep -Fq 'reasoning effort `fixture-effort`' "$impl_rendered_file" ||
    fail "implementer-brief demands an effort check against an undisclosed effort"
grep -Fq '**A Codex brief forbids `gh pr ready` explicitly.**' "$impl_rendered_file" ||
    fail "implementer-brief Codex block does not restate the promotion prohibition"

# The five delegation invariants (#296, #438, #447, #582, #431), stated once.
# Each literal must be token-free, so the SAME string proves the rule is
# present in the template and proves no referrer restates it. The two rules
# that used to carry a value were asserted here in their POST-RENDER form
# (`fixture-scratch-dir`, `fixture-report-path`) — strings a referrer could
# never contain, which made the two assertions enforcing this change's central
# "stated once" claim dead in every possible tree.
impl_contract_rules=(
    '**Exit plan mode before spawning an implementer.**'
    "**You share the caller's working tree and \`HEAD\`.**"
    '**Keep the core work in your own context — no sub-delegation.**'
    '**Namespace every scratch file under the scratch directory your dispatch'
    '**Report through the output contract your dispatch names, and re-read every'
)
for rule in "${impl_contract_rules[@]}"; do
    case "$rule" in
    *fixture-*) fail "anti-restatement literal is post-render and can never match a referrer: $rule" ;;
    esac
    grep -Fq "$rule" "$impl_template" ||
        fail "anti-restatement literal does not match the UNRENDERED template: $rule"
done

# The contract is referenced from files that are read standalone, so it must
# carry no value of its own: a reader following a pointer reads it unrendered.
impl_contract_section="$(awk '/^## Delegation contract/{c=1} /^## Gate commands/{c=0} c' "$impl_template")"
case "$impl_contract_section" in
*'{{'*) fail "the referenced delegation contract carries a placeholder a standalone reader cannot resolve" ;;
esac
case "$impl_contract_section" in
*'Two audiences, one contract'*) ;;
*) fail "the delegation contract does not split the PR-owning and bounded-role audiences" ;;
esac
for rule in "${impl_contract_rules[@]}"; do
    grep -Fq "$rule" "$impl_rendered_file" ||
        fail "implementer-brief delegation contract is missing: $rule"
done
grep -Fq "standing in for the **PR's** check status" "$impl_rendered_file" ||
    fail "delegation contract does not name the local-for-PR gate substitution"
grep -Fq '"replied" and "resolved" are distinct thread states' "$impl_rendered_file" ||
    fail "delegation contract collapses replied and resolved"
grep -Fq 'reconstruct, abbreviate from memory, or infer one' "$impl_rendered_file" ||
    fail "delegation contract does not require verbatim SHAs"
grep -Fq 'prefer an isolated worktree' "$impl_rendered_file" ||
    fail "delegation contract does not offer the structural fix for a shared HEAD"
grep -Fq 'a dirty index,' "$impl_rendered_file" ||
    fail "delegation contract names only branches as the shared-tree exposure"
grep -Fq 'Read-only fan-out' "$impl_rendered_file" ||
    fail "delegation contract does not distinguish allowed read-only fan-out"
grep -Fq 'may be unresumable' "$impl_rendered_file" ||
    fail "delegation contract omits the plan-mode recovery path"
# Scoped to the contract section, not the whole file: round 1's restructure
# added a second occurrence of this literal in § "Identity and boundaries", so
# a whole-file grep survives deleting rule 4's clause and the failure message
# would be a lie. Same defect class as the GATE-EXIT= hole above.
case "$impl_contract_section" in
*'never at the scratchpad root'*) ;;
*) fail "delegation contract does not forbid the scratchpad root" ;;
esac

# Sweep the class rather than the instance: every literal asserted against the
# whole rendered brief must occur exactly once there, or its assertion cannot
# fail when the load-bearing occurrence is deleted.
impl_single_occurrence=(
    'A bound is the point at which you stop waiting, never the point at which you'
    'Run the gates with these exact commands'
    'strongest signal wins'
    'does **not** make a repository `light`'
    'one of `light`, `standard`, or'
    'report BLOCKED rather than picking a row'
    '**A proposal-only unit still runs every gate, still commits, still pushes, and'
    'still opens the DRAFT PR. It stops there.'
    'This brief is a **PR-owning** contract'
    'It is not a work contract for a bounded role subagent'
    'Claim handoff — read this before running the skill'
    'use of an existing claim, never a transfer'
    'Keep every other refusal'
    '**Include the profile line**'
    'through at least 0.155.1'
    'The TUI `/model` picker is the only lever'
)
for literal in "${impl_single_occurrence[@]}"; do
    count="$(grep -Fc "$literal" "$impl_rendered_file" || true)"
    [ "$count" -eq 1 ] ||
        fail "assertion literal occurs $count times in the rendered brief (needs exactly 1): $literal"
done

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

# The claim handoff: without it the skill's own step-1 ownership ladder reads an
# orchestrator-authored claim as "claimed by someone else" and halts the
# dispatch before any implementation happens.
grep -Fq 'Claim handoff — read this before running the skill' "$impl_rendered_file" ||
    fail "implementer-brief has no claim-handoff override for a delegated claim"
grep -Fq 'use of an existing claim, never a transfer' "$impl_rendered_file" ||
    fail "implementer-brief claim handoff can be mistaken for a claim transfer"
grep -Fq 'fixture-claim-handoff' "$impl_rendered_file" ||
    fail "implementer-brief does not render the authenticated claim snapshot"
grep -Fq 'Keep every other refusal' "$impl_rendered_file" ||
    fail "implementer-brief claim handoff drops the other step-1 refusals"

# r3-2: the skill's branch step creates and switches branches and refreshes the
# claim — all three forbidden by this brief, and the first fails anyway because
# the branch already exists. The base template overrode step 1 and not step 3.
grep -Fq "Branch handoff — read this before running the skill" "$impl_rendered_file" ||
    fail "implementer-brief has no step-3 override for a provisioned branch"
grep -Fq 'do not fetch-and-switch, do' "$impl_rendered_file" ||
    fail "implementer-brief step-3 override does not forbid fetch-and-switch"
grep -Fq 'not create a branch, and do not refresh the claim' "$impl_rendered_file" ||
    fail "implementer-brief step-3 override does not forbid the claim refresh"
grep -Fq 'are the only ones this brief grants' "$impl_rendered_file" ||
    fail "implementer-brief does not bound which skill steps it overrides"
# Every harness path routes through the skill, so every harness path owes both.
impl_harness_sections=0
while IFS= read -r line; do
    case "$line" in
    *'Apply both § "Scope" overrides'*) impl_harness_sections=$((impl_harness_sections + 1)) ;;
    esac
done <"$impl_rendered_file"
[ "$impl_harness_sections" -eq 3 ] ||
    fail "expected all 3 harness sections to apply the skill-step overrides (found $impl_harness_sections)"

# r3-3: the proofs are alternatives tried in order, not a containment-keyed
# if/else. In a MAIN checkout the common Git directory is inside the worktree
# root, and check-ignore never matches under .git (structural exclusion, not a
# pattern), so testing containment first rejects the recommended path.
for brief in "$impl_rendered_file" "$rendered_file"; do
    grep -Fq 'take the **first** proof that holds' "$brief" ||
        fail "report-path proofs are not ordered alternatives in $brief"
    grep -Fq 'excludes it structurally rather than' "$brief" ||
        fail "report-path check does not explain why check-ignore cannot match under .git in $brief"
done

# r3-1: a bounded role's writes are what its own definition permits. The
# deleted clause ("writes nothing outside it") was false for `implementer`,
# which must commit, and `integrator`, which must persist state and post.
for scoped in "$impl_rendered_file" ai/agents/challenger.md ai/agents/reviewer.md \
    ai/agents/integrator.md ai/agents/implementer.md ai/agents/README.md; do
    if grep -Eq 'writes? nothing outside it' "$scoped"; then
        fail "$scoped still forbids writes a bounded role is required to make"
    fi
done
grep -Fq 'Its writes are exactly the ones its own agent definition permits' "$impl_rendered_file" ||
    fail "implementer-brief does not scope a bounded role's writes to its own definition"

# Audience: the template finishes at a published draft PR, which a bounded role
# subagent is forbidden to reach (ai/agents/implementer.md § Never).
grep -Fq 'This brief is a **PR-owning** contract' "$impl_rendered_file" ||
    fail "implementer-brief does not declare its audience"
grep -Fq 'It is not a work contract for a bounded role subagent' "$impl_rendered_file" ||
    fail "implementer-brief can still be dispatched to a bounded role subagent"
for dispatcher in \
    ai/skills/universal/implement/SKILL.md \
    ai/skills/universal/orchestrate/SKILL.md; do
    grep -Fq 'bounded role subagent' "$dispatcher" ||
        fail "$dispatcher does not exclude bounded role subagents from the PR-owning template"
done

# The lane superset must actually inherit what two documents say it inherits.
lane_inherits="$(awk '/^## Inherited base contract/{c=1} /^## Procedure/{c=0} c' \
    ai/skills/universal/orchestrate/assets/lane-brief.md)"
[ -n "$lane_inherits" ] ||
    fail "lane-brief does not name the base contract it extends"
for inherited in 'Delegation contract' 'Hard rules' 'Gate commands and time bounds' 'Proposal-only units'; do
    case "$lane_inherits" in
    *"$inherited"*) ;;
    *) fail "lane-brief claims no inheritance of the base section: $inherited" ;;
    esac
done
case "$lane_inherits" in
*'{{repo-tier}}'*) ;;
*) fail "lane-brief inherits gate bounds without rendering a tier" ;;
esac
case "$lane_inherits" in
*'{{gate-commands}}'*) ;;
*) fail "lane-brief inherits gate bounds without rendering the gate commands" ;;
esac
case "$lane_inherits" in
*'.agents/skills/implement/assets/implementer-brief.md'*) ;;
*) fail "lane-brief does not give the base contract a resolution path" ;;
esac
# A consumer may vendor `orchestrate` without `implement`, so an unreadable
# base contract degrades the way every agent definition degrades; it is not a
# blocker that strands a supported configuration.
case "$lane_inherits" in
*'not finding the file is a supported state, not a blocker'*) ;;
*) fail "lane-brief blocks instead of degrading when the base contract is absent" ;;
esac
case "$lane_inherits" in
*'fall back to `AGENTS.md`'*) ;;
*) fail "lane-brief names no degradation target for an unreadable base contract" ;;
esac
# "Not restated here" has to be true. The inline copy drifted — it had lost
# `gh pr ready`, the release/tag clause, amend/rebase, and the scope rule — so
# it was deleted rather than completed: one copy, in the base template.
lane_identity="$(awk '/^## Identity and boundaries/{c=1} /^## File-scope fence/{c=0} c' \
    ai/skills/universal/orchestrate/assets/lane-brief.md)"
# The parenthetical NAMES the inherited rules as a pointer, which is the point;
# what must not come back is an imperative copy of them. These two literals
# appear only in a restatement, never in the pointer's own wording.
for restated in 'gh pr ready' 'force-push'; do
    case "$lane_identity" in
    *"$restated"*) fail "lane-brief restates a base hard rule it declares inherited: $restated" ;;
    esac
done
case "$lane_identity" in
*'deliberately not copied here'*) ;;
*) fail "lane-brief does not point at the base hard rules it no longer copies" ;;
esac

# Every referrer resolves the contract the way this repo resolves any skill
# file, and says what to do when nothing is readable.
for referrer in \
    ai/agents/challenger.md \
    ai/agents/reviewer.md \
    ai/agents/integrator.md \
    ai/agents/implementer.md; do
    grep -Fq '.agents/skills/implement/assets/implementer-brief.md' "$referrer" ||
        fail "$referrer has no resolution path for the delegation contract"
    grep -Fq 'one bounded glob' "$referrer" ||
        fail "$referrer does not degrade to a bounded glob"
    grep -Fq 'do not guess the contract' "$referrer" ||
        fail "$referrer does not say what to do when the contract is unreadable"
    grep -Fq 'bounded-role side of it' "$referrer" ||
        fail "$referrer does not place the role on the bounded side of rule 5"
done
grep -Fq 'discover-don' ai/agents/README.md ||
    fail "the agents README does not bind the pointer to its own discovery rule"
grep -Fq '`isolation` is a caller decision, not frontmatter' ai/agents/README.md ||
    fail "the agents README does not own the isolation decision itself"

# The orchestrator-facing instruction, in both dispatching skills.
grep -Fq 'Render `assets/implementer-brief.md`. Never write the brief freehand.' \
    "$impl_catalog" ||
    fail "the implement skill does not require rendering the template"
grep -Fq 'Brief template source catalog' "$impl_catalog" ||
    fail "the implement skill ships no external source catalog"

# A catalog row that describes a value the template's own startup check
# refuses renders an unstartable brief: the dispatcher follows the row, the
# worker BLOCKs before implementation, and it cannot even write that blocker
# to the path it was given. The two shapes the check accepts are the only two
# the row may offer.
impl_report_row="$(grep -F '| `{{report-path}}` |' "$impl_catalog")"
case "$impl_report_row" in
*'common Git directory'*) ;;
*) fail "the report-path catalog row omits the shape the startup check accepts" ;;
esac
case "$impl_report_row" in
*'outside the worktree'*) fail "the report-path catalog row offers a shape the startup check refuses" ;;
esac

# The artifact keeps the one-sentence provenance note (r1-16 kept it
# deliberately), so the authoring procedure must not claim the note lives only
# there — a later editor would believe the artifact is already clean and not look.
if grep -Fq 'defaults measured from run history' "$impl_template"; then
    grep -Fq 'The artifact keeps the one-sentence provenance note' "$impl_catalog" ||
        fail "the implement skill misdescribes where the gate-bounds note lives"
fi
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
