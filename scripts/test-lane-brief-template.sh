#!/usr/bin/env bash
# Prose-contract test for the orchestrator's lane-brief template.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    echo "FAIL: $*" >&2
    exit 1
    return 0
}

template="ai/skills/universal/orchestrator/assets/lane-brief.md"
rendered="$(<"$template")"

required_placeholders=(
    '{{active-state-path}}'
    '{{attempt-nonce}}'
    '{{base-sha}}'
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
    grep -Fq "| \`$token\` |" ai/skills/universal/orchestrator/SKILL.md ||
        fail "$token is absent from the external placeholder source catalog"
    key="${token#\{\{}"
    key="${key%\}\}}"
    case "$key" in
    ready-sentinel) value="LANE-FIXTURE-READY" ;;
    handoff-sentinel) value="LANE-FIXTURE-HANDOFF" ;;
    blocked-sentinel) value="LANE-FIXTURE-BLOCKED" ;;
    attempt-nonce) value="a1b2c3" ;;
    *) value="fixture-$key" ;;
    esac
    rendered="${rendered//"$token"/"$value"}"
done

rendered_file="$(mktemp)"
trap 'rm -f "$rendered_file"' EXIT
printf '%s\n' "$rendered" >"$rendered_file"

if grep -Eq '\{\{[a-z0-9-]+\}\}' "$rendered_file"; then
    fail "rendered fixture retains a placeholder"
fi

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
    ai/skills/universal/orchestrator/SKILL.md ||
    fail "lane template is not scoped to PR-owning dispatches"
grep -Fq 'bounded remediation implementers, use their schema-bound role briefs' \
    ai/skills/universal/orchestrator/SKILL.md ||
    fail "non-PR implementer dispatches can receive the lane template"
grep -Fq "step 1's session/agent ownership comparison" "$rendered_file" ||
    fail "orchestrator claim handoff does not override implement session matching"
grep -Fq 'delegated use of the existing claim, not a claim transfer' \
    "$rendered_file" ||
    fail "claim handoff can be mistaken for ownership transfer"
grep -Fq "snapshot's recorded branch must equal" "$rendered_file" ||
    fail "claim handoff is not bound to the provisioned lane branch"
grep -Fq 'transactionally refresh the existing' \
    ai/skills/universal/orchestrator/SKILL.md ||
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

echo "lane-brief template: ok"
