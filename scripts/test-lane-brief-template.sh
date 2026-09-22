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
    # `|| true`: under `set -o pipefail` a non-matching grep makes the whole
    # assignment non-zero, and `set -e` then kills the script BEFORE the
    # `[ -n "$line" ]` check below can report which heading is missing — a test
    # that fails with no message at all.
    line="$(grep -nFx "$heading" "$rendered_file" | cut -d: -f1 || true)"
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

# Whitespace-normalised view of the rendered brief. These are hard-wrapped
# Markdown files, so any assertion about a phrase that can straddle a line
# break must run against this rather than against the file's lines.
impl_flat="$(tr '\n' ' ' <"$impl_rendered_file" | tr -s '[:space:]' ' ')"

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
    line="$(grep -nFx "$heading" "$impl_rendered_file" | cut -d: -f1 || true)"
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
    "**Unless your dispatch placed you in an isolated worktree, you share the"
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
case "$impl_contract_section" in
*'They differ in one place only — rule 5'*) ;;
*) fail "the contract claims an audience split other than rule 5's" ;;
esac
# rule 2's asymmetry is universal — "a commit you did not create" binds every
# audience identically — so it must not be recast as an audience split. An
# `implementer` is a bounded role that commits, which is what made the second
# claimed split false while every referrer still named only rule 5's.
case "$impl_contract_section" in
*'a moved HEAD is a deliverable for one audience'*) fail "rule 2 is described as an audience split it does not have" ;;
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

# Sweep the class rather than the instance, and DERIVE the set from the
# assertions themselves. Two earlier shapes of this check were weaker than
# their own comment: a hand list covered 16 of 42 literals, and the first
# derived version read ONE assertion syntax, so a duplicate in a `case` arm or
# in a line-continued `grep` survived. Every literal positively asserted
# against the whole rendered brief must occur exactly once there, or its
# assertion cannot fail when the load-bearing occurrence is deleted.
#
# Continuation lines are joined first so a `grep -Fq 'lit' \` whose filename
# sits on the next line is seen as one assertion. Negative assertions (the
# `if grep … then fail` and `*'lit'*) fail …` forms) are excluded by
# construction: those are the ones that must occur ZERO times.
# awk, not `sed -e ':a' … -e 'ta'`: the label/branch join and a literal `\n`
# on a substitution's right-hand side are GNU extensions, so that form fails on
# BSD/macOS sed — and this file ships to consumers. Byte-identical to the sed
# it replaces, including the edge case of a final line left with an
# unterminated continuation, which is why the raw form is kept for END.
impl_joined="$(awk '
    {
        line = $0
        if (pending != "") {
            sub(/^[[:space:]]*/, "", line)
            line = pending " " line
            pending = ""
        }
        if (line ~ /\\$/) {
            pending_raw = line
            sub(/\\$/, "", line)
            pending = line
            next
        }
        print line
    }
    END { if (pending != "") print pending_raw }
' "$0")"
# shell-robustness: begin-exempt — the forbidden text `grep -Fq` appears here
# only INSIDE the regex that searches this file FOR that text; these pipelines
# use `grep -oE`, which reads its input to EOF and cannot SIGPIPE the producer.
impl_asserted_literals="$(
    printf '%s\n' "$impl_joined" |
        grep -oE "^[[:space:]]*grep -Fq (-e )?'[^']+' +\"\\\$impl_rendered_file\"" |
        sed -E "s/^[[:space:]]*grep -Fq (-e )?'//; s/' +\"\\\$impl_rendered_file\"$//"
    # Double-quoted literals too. Both live instances are double-quoted only
    # because the literal contains an apostrophe, and a single-quote-only
    # extraction made them invisible to the sweep for three rounds.
    printf '%s\n' "$impl_joined" |
        grep -oE "^[[:space:]]*grep -Fq (-e )?\"[^\"\\\$]+\" +\"\\\$impl_rendered_file\"" |
        sed -E "s/^[[:space:]]*grep -Fq (-e )?\"//; s/\" +\"\\\$impl_rendered_file\"$//"
    # Only `case` blocks whose subject is the WHOLE rendered brief. Arms under
    # a scoped subject ($impl_launch, $impl_profile_block, $lane_inherits …)
    # assert against an extract, so their literal may legitimately occur more
    # than once in the brief — sweeping those reported a false duplicate.
    printf '%s\n' "$impl_joined" |
        awk '
            /^case "\$impl_flat" in$/ { inblock = 1; next }
            /^esac$/ { inblock = 0 }
            inblock && /^\*'"'"'[^'"'"']+'"'"'\*\) ;;$/ {
                line = $0
                sub(/^\*'"'"'/, "", line)
                sub(/'"'"'\*\) ;;$/, "", line)
                print line
            }
        '
)"
# shell-robustness: end-exempt
[ -n "$impl_asserted_literals" ] ||
    fail "could not derive the asserted-literal set from this test"

impl_array_literals="$(
    printf '%s\n' "${impl_hard_rules[@]}"
    printf '%s\n' "${impl_contract_rules[@]}"
)"
impl_asserted_literals="$impl_asserted_literals
$impl_array_literals"

impl_swept=0
impl_swept_case=0
while IFS= read -r literal; do
    [ -n "$literal" ] || continue
    impl_swept=$((impl_swept + 1))
    # Counted against the FLATTENED brief, not the file's lines: an asserted
    # literal may straddle a wrap (every `case "$impl_flat"` literal does), so
    # a line-oriented count reports 0 for a literal that is plainly present —
    # and misses a duplicate that straddles a wrap, which is the very defect
    # this sweep exists to catch.
    count=0
    scan="$impl_flat"
    while :; do
        case "$scan" in
        *"$literal"*)
            count=$((count + 1))
            scan="${scan#*"$literal"}"
            ;;
        *) break ;;
        esac
    done
    [ "$count" -eq 1 ] ||
        fail "assertion literal occurs $count times in the rendered brief (needs exactly 1): $literal"
done <<EOF
$impl_asserted_literals
EOF

# The probe review round 2 used, as a test case: the extraction must actually
# reach the `case`-arm syntax, not merely the `grep -Fq` one. Round 1's version
# passed its own floor check while missing 18 case arms and 12 continued
# greps — and the same commit moved a literal from the covered syntax into an
# uncovered one, narrowing coverage while claiming to widen it.
for representative in \
    'It overrides three of the skill' \
    'the publication half of this template does not bind a bounded role'; do
    case "$impl_asserted_literals" in
    *"$representative"*) impl_swept_case=$((impl_swept_case + 1)) ;;
    esac
done
[ "$impl_swept_case" -eq 2 ] ||
    fail "the literal extraction no longer reaches case-arm assertions (found $impl_swept_case/2)"

# The surviving mutation probe from review round 3, as a test case: this
# literal is DOUBLE-quoted (it contains an apostrophe) and was invisible to the
# single-quote-only extraction, so duplicating it in the brief kept the suite
# green while the load-bearing occurrence could then be deleted.
case "$impl_asserted_literals" in
*"standing in for the **PR's** check status"*) ;;
*) fail "the literal extraction no longer reaches double-quoted assertions" ;;
esac

# Class closure: every `grep -Fq <literal> "$impl_rendered_file"` assertion in
# this file must have been derived. Counted on the joined text, excluding the
# `if`-guarded negative form, which must occur ZERO times and is swept
# elsewhere. A mismatch means a literal form the extraction cannot read.
# Variable-expansion assertions (`grep -Fq "$rule" …`) are excluded: their
# literals come from the arrays swept just above, not from the line. Every
# OTHER whole-brief grep assertion states its literal inline and must have been
# derived.
impl_assertion_lines="$(printf '%s\n' "$impl_joined" |
    grep -E "^[[:space:]]*grep -Fq .* \"\\\$impl_rendered_file\"" |
    grep -cvE "^[[:space:]]*grep -Fq (-e )?\"\\\$[A-Za-z_]" || true)"
impl_derived_greps="$(printf '%s\n' "$impl_joined" |
    grep -cE "^[[:space:]]*grep -Fq (-e )?('[^']+'|\"[^\"\\\$]+\") +\"\\\$impl_rendered_file\"" || true)"
[ "${impl_assertion_lines:-0}" -eq "${impl_derived_greps:-0}" ] ||
    fail "the sweep reads ${impl_derived_greps:-0} of ${impl_assertion_lines:-0} inline-literal whole-brief assertions — a literal form it cannot parse would go unswept"
[ "$impl_swept" -ge 40 ] ||
    fail "derived only $impl_swept asserted literals — the extraction has drifted from the assertions"
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
case "$impl_flat" in
*'every off-profile choice — model family, tier, or effort — named as off-profile'*) ;;
*) fail "PR-body profile line does not require off-profile disclosure" ;;
esac
# AGENTS.md § "Rigor and Strategy" mandates the announce set: rigor+source, the
# four caps, min_rounds, wall-clock, the breadth envelope, strategy+source and
# all five tiers. The line enumerated three of those short, and the v2 superset
# already rendered all three — the base under-specified against both.
# Scoped to the profile-line bullet, not the whole brief: the catalog-row half
# below is already scoped for exactly this reason, and an unscoped check here
# passed a probe that deleted a field from the bullet while mentioning the same
# phrase elsewhere in the template.
impl_profile_block="$(awk '
    /^- \*\*Include the profile line\*\*/ { collecting = 1 }
    collecting { print; if ($0 ~ /Render it from:/) exit }
' "$impl_rendered_file" | tr '\n' ' ' | tr -s '[:space:]' ' ')"
[ -n "$impl_profile_block" ] ||
    fail "implementer-brief has no profile-line bullet"
# Both ends of the scope, not just the start. awk exits ON the terminator, so
# a block that does not END with it ran past it to EOF.
case "$impl_profile_block" in
*'Render it from: ') ;;
*'Render it from:') ;;
*) fail "the profile-line block ran past its terminator — the scoped check has silently become whole-file" ;;
esac
for announced in \
    '`min_rounds` floor and wall-clock' \
    'breadth envelope' \
    'max_agent_runs' \
    'max_parallel_agents' \
    'all five role tiers' \
    'strategy and its source'; do
    case "$impl_profile_block" in
    *"$announced"*) ;;
    *) fail "PR-body profile line omits a field AGENTS.md's announce set requires: $announced" ;;
    esac
done
# Scoped to the ROW, not the file: `min_rounds` also appears in unrelated prose
# in this skill, so a whole-file grep passes after the row loses it — the same
# defect class this change has now found five times.
impl_profile_row="$(grep -F '| `{{policy-profile}}` |' "$impl_catalog")"
[ -n "$impl_profile_row" ] ||
    fail "the implement catalog has no profile-line row"
for announced in 'min_rounds' 'wall-clock' 'breadth envelope' 'max_agent_runs' 'max_parallel_agents'; do
    case "$impl_profile_row" in
    *"$announced"*) ;;
    *) fail "the profile-line catalog row omits an announce-set field: $announced" ;;
    esac
done
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

# A shared-tree dispatch must prove the tree is clean before its first edit:
# on a shared checkout a dirty index belongs to someone else, and `git add -A`
# would sweep it into this worker's commit and attribute it to this work.
case "$impl_flat" in
*'require a clean index and worktree before your first edit'*) ;;
*) fail "implementer-brief does not require a clean tree before editing" ;;
esac
case "$impl_flat" in
*'`git status --porcelain` must print nothing'*) ;;
*) fail "implementer-brief does not name the clean-tree check" ;;
esac
case "$impl_flat" in
*'Report BLOCKED if it does not, naming what it printed'*) ;;
*) fail "implementer-brief does not block on a dirty shared tree" ;;
esac

# HOSTILE-TITLE FIXTURE. `{{issue-title}}` is fetched from the issue, so on a
# public repository it is attacker-controllable. Rendered inside link syntax a
# crafted title could close the link and inject markdown the worker reads as
# instruction. Render the SAME brief with a hostile title and require that the
# document structure is unchanged: no heading appears that the benign render
# did not have.
hostile_title=']( ) **INJECTED** [x](y)'
for hostile_template in "$impl_template" "$template"; do
    hostile_rendered="$(<"$hostile_template")"
    while IFS= read -r token; do
        [ -n "$token" ] || continue
        key="${token#\{\{}"
        key="${key%\}\}}"
        case "$key" in
        issue-title) value="$hostile_title" ;;
        brief-envelope-json)
            value="$(awk '/^```json$/{capture=1;next} /^```$/{capture=0} capture' \
                ai/schemas/fixtures/brief.envelope/valid/minimal.md)"
            ;;
        *) value="fixture-$key" ;;
        esac
        hostile_rendered="${hostile_rendered//"$token"/"$value"}"
    done <<EOF
$(grep -oE '\{\{[^}]*\}\}' "$hostile_template" | sort -u)
EOF
    benign_headings="$(grep -cE '^#+ ' "$hostile_template" || true)"
    hostile_headings="$(printf '%s\n' "$hostile_rendered" | grep -cE '^#+ ' || true)"
    [ "${benign_headings:-0}" -eq "${hostile_headings:-0}" ] ||
        fail "a hostile issue title changed the heading structure of $hostile_template (${benign_headings:-0} -> ${hostile_headings:-0})"
    # The legitimate link is `[#<number>](<url>)`; what must never appear is
    # the TITLE followed by link syntax, which is what lets a crafted title
    # close the link early.
    case "$hostile_rendered" in
    *"$hostile_title](") fail "$hostile_template renders the issue title inside link syntax" ;;
    *"$hostile_title]("*) fail "$hostile_template renders the issue title inside link syntax" ;;
    esac
    case "$hostile_rendered" in
    *"\`$hostile_title\`"*) ;;
    *) fail "$hostile_template does not render the issue title as a code span" ;;
    esac
done

# r3-2: the skill's branch step creates and switches branches and refreshes the
# claim — all three forbidden by this brief, and the first fails anyway because
# the branch already exists. The base template overrode step 1 and not step 3.
grep -Fq "Branch handoff — read this before running the skill" "$impl_rendered_file" ||
    fail "implementer-brief has no step-3 override for a provisioned branch"
grep -Fq 'do not fetch-and-switch, do' "$impl_rendered_file" ||
    fail "implementer-brief step-3 override does not forbid fetch-and-switch"
grep -Fq 'not create a branch, and do not refresh the claim' "$impl_rendered_file" ||
    fail "implementer-brief step-3 override does not forbid the claim refresh"
# The count was false — the harness sections grant a third override, of the
# skill's final step, which is the one that keeps a worker out of promotion.
# One enumeration, in § Scope, naming all three.
case "$impl_flat" in
*'It overrides three of the skill'*) ;;
*) fail "implementer-brief does not enumerate the skill steps it overrides" ;;
esac
case "$impl_flat" in
*'are the only ones this brief grants'*) fail "implementer-brief kept the false exhaustiveness claim" ;;
esac
grep -Fq 'returns control to whoever dispatched it' "$impl_rendered_file" ||
    fail "the override enumeration omits the final-step override that prevents promotion"
# Name the steps by NUMBER and bind each number to the skill's actual heading.
# The enumeration named the third override by position ("its final step"), and
# this change then appended § 10 to the skill, so the position silently moved to
# a section addressed to dispatchers rather than to the worker.
for step in 1 3 9; do
    case "$impl_flat" in
    *"**step $step**"*) ;;
    *) fail "the override enumeration does not name skill step $step by number" ;;
    esac
    grep -Eq "^## $step\. " "$impl_catalog" ||
        fail "the brief overrides skill step $step, which the skill does not number that way"
done
case "$impl_flat" in
*'its **final step**'* | *'the **final step**'*) fail "an override is named by position instead of by step number" ;;
esac
# Every harness path routes through the skill, so every harness path owes both.
# Counted on the NORMALISED text, and on the whole phrase rather than a
# fragment of it: the clause wraps across lines, and it was once spliced into
# the middle of two of the three sentences and shipped as broken prose. The
# phrase below can only match where the clause follows "publication," and
# closes its own sentence, so placement and count are proven together.
impl_override_phrase='publication, applying the three § "Scope" step overrides and no others.'
impl_harness_sections=0
impl_scan="$impl_flat"
while :; do
    case "$impl_scan" in
    *"$impl_override_phrase"*)
        impl_harness_sections=$((impl_harness_sections + 1))
        impl_scan="${impl_scan#*"$impl_override_phrase"}"
        ;;
    *) break ;;
    esac
done
[ "$impl_harness_sections" -eq 3 ] ||
    fail "expected all 3 harness sections to close a sentence with the skill-step overrides (found $impl_harness_sections)"

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
# Whitespace-normalised and widened from one wording to the defect class: these
# are hard-wrapped Markdown files, so a line-oriented grep missed the exact
# clause reintroduced at its natural wrap point, and pinning one phrasing let a
# paraphrase through. `implementer` is granted round pushes through the broker
# by agent-registry.json and specs/dev-flow-v2.md, so an absolute write or push
# prohibition on a bounded role is false whatever words it uses.
for scoped in "$impl_rendered_file" ai/agents/challenger.md ai/agents/reviewer.md \
    ai/agents/integrator.md ai/agents/implementer.md ai/agents/README.md; do
    flat="$(tr '\n' ' ' <"$scoped" | tr -s '[:space:]' ' ')"
    for forbidden in \
        'writes nothing outside it' \
        'write nothing outside it' \
        'never does is push' \
        'never pushes, never opens'; do
        case "$flat" in
        *"$forbidden"*) fail "$scoped states an absolute write/push prohibition a bounded role is granted: $forbidden" ;;
        esac
    done
done
# The authority itself is referenced, never copied — the change's own thesis.
case "$impl_flat" in
*'its own agent definition grants; no copy of that authority is kept here'*) ;;
*) fail "implementer-brief keeps its own copy of a bounded role's write authority" ;;
esac
case "$impl_flat" in
*'`agent-registry.json` `roles[]`'*) ;;
*) fail "implementer-brief does not reference the machine-validated role authority" ;;
esac
case "$impl_flat" in
*'the publication half of this template does not bind a bounded role'*) ;;
*) fail "implementer-brief lost the one invariant the two-audience split adds" ;;
esac

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
# The lane BLOCKS on an unreadable base contract rather than degrading, because
# `implement` is a declared required dependency of `orchestrate`: the lane brief
# names four base sections it does not restate, so without them a lane would own
# a PR with no hard rules, no gate bounds, no proposal-only clause and no
# delegation contract. That is a vendoring error, not a mode to run in. The
# agent definitions still degrade — asserted separately below — because a
# bounded role can return an honest typed result without the contract.
case "$lane_inherits" in
*'report BLOCKED and stop'*) ;;
*) fail "lane-brief does not block on an unreadable base contract" ;;
esac
case "$lane_inherits" in
*'declares `implement` a required'*) ;;
*) fail "lane-brief does not name the required-dependency declaration it relies on" ;;
esac
case "$lane_inherits" in
*'stricter than the agent definitions'*) ;;
*) fail "lane-brief does not distinguish its blocking from the agents' degradation" ;;
esac
# The declaration itself must exist, or the lane blocks citing a contract that
# does not bind anything.
python3 - <<'PYEOF' || fail "orchestrate does not declare implement a required skill"
import json, sys
d = json.load(open("ai/skills/universal/orchestrate/assets/policy-contract.json"))
sys.exit(0 if "implement" in (d.get("requires_skills") or []) else 1)
PYEOF
grep -Fq 'required dependency' ai/skills/universal/orchestrate/SKILL.md ||
    fail "the orchestrate skill does not state the required dependency"
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
    # Asserted against all four agent files, and here is why all four rather
    # than the three the constraint strictly binds. `result.reviewer`,
    # `result.challenger` and `result.integrator` are additionalProperties:false
    # with no free-text field, so "say in your result" that a file was
    # unreadable can only be obeyed there by minting a finding or by
    # mislabelling a completed pass as blocked. `result.implementer` DOES carry
    # `summary`/`handoff`/`blocked_question`, so that role could obey it — but
    # the four files carry one identical paragraph by design, and a sentence
    # true in three of them and different in the fourth is the drift this whole
    # change exists to remove. The ladder is the disclosure path for all four.
    if grep -Fq 'say in your result that you could not read it' "$referrer"; then
        fail "$referrer asks for a disclosure the typed result has no field to carry"
    fi
    grep -Fq 'continue on `AGENTS.md` plus your' "$referrer" ||
        fail "$referrer does not continue on the degradation ladder it names"
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

# Stated once: the lane superset, every agent, and the operator guide reference
# it; none restates it. Matched on a whitespace-normalised, emphasis-stripped
# form of both sides — the previous line-oriented `grep -Fq` over hard-wrapped
# Markdown only fired on a restatement that happened to reproduce the
# template's exact wrap column and its `**` markers, so a copy wrapped one word
# earlier, or set without bold, escaped the guard that enforces this change's
# central claim. Same normalisation the bounded-role guard already uses.
normalise_prose() {
    tr '\n' ' ' <"$1" | sed 's/\*\*//g; s/`//g' | tr -s '[:space:]' ' '
}
for referrer in \
    ai/skills/universal/orchestrate/assets/lane-brief.md \
    ai/agents/README.md \
    ai/agents/implementer.md \
    ai/agents/challenger.md \
    ai/agents/reviewer.md \
    ai/agents/integrator.md \
    docs/guides/herdr.md; do
    grep -Fq 'implementer-brief.md' "$referrer" ||
        fail "$referrer does not reference the one delegation contract"
    referrer_flat="$(normalise_prose "$referrer")"
    for rule in "${impl_contract_rules[@]}"; do
        rule_flat="$(printf '%s' "$rule" | sed 's/\*\*//g; s/`//g' | tr -s '[:space:]' ' ')"
        case "$referrer_flat" in
        *"$rule_flat"*) fail "$referrer restates the delegation contract instead of referencing it" ;;
        esac
    done
done

# rv1-7: the operator guide is the most claim-dense referrer and had no floor at
# all — and challenge-r1-13 was exactly one of its claims having gone false.
# Each claim it makes about the base template is pinned to the template here.
herdr_flat="$(normalise_prose docs/guides/herdr.md)"
for claimed in \
    'assets/implementer-brief.md' \
    'gate commands with real time bounds per repo tier' \
    'strongest-signal-wins procedure' \
    'never gh pr ready' \
    'proposal-only unit still runs gates, commits, pushes' \
    'claim-handoff override' \
    'report-file and sentinel contract' \
    'PR-body profile line' \
    'one delegation contract' \
    'source catalog in implement/SKILL.md' \
    'Inherited base contract'; do
    case "$herdr_flat" in
    *"$claimed"*) ;;
    *) fail "docs/guides/herdr.md no longer makes the claim this test pins: $claimed" ;;
    esac
done
# Each of those claims must be TRUE of the artifact, not merely present in the guide.
for backed in \
    'Gate commands and time bounds' \
    'strongest signal wins' \
    'Never run `gh pr ready`.' \
    'Proposal-only units' \
    'Claim handoff — read this before running the skill' \
    'Reporting protocol' \
    'Include the profile line' \
    'Delegation contract'; do
    case "$impl_flat" in
    *"$backed"*) ;;
    *) fail "herdr.md advertises something the template does not carry: $backed" ;;
    esac
done

echo "implementer-brief template: ok"
echo "lane-brief template: ok"
