#!/usr/bin/env bash
# Prose-contract test for the orchestrator's lane-brief template.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

template="ai/skills/universal/orchestrator/assets/lane-brief.md"
rendered="$(<"$template")"

mapfile -t placeholders < <(grep -oE '\{\{[a-z0-9-]+\}\}' "$template" | sort -u)
[ "${#placeholders[@]}" -gt 0 ] || fail "template exposes no placeholders"

for token in "${placeholders[@]}"; do
    grep -Fq "| \`$token\` |" "$template" ||
        fail "$token is absent from the placeholder source table"
    key="${token#\{\{}"
    key="${key%\}\}}"
    case "$key" in
    ready-sentinel) value="LANE-FIXTURE-READY" ;;
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

for sentinel in LANE-FIXTURE-READY-a1b2c3 LANE-FIXTURE-BLOCKED-a1b2c3; do
    count="$(grep -Fc "$sentinel" "$rendered_file")"
    [ "$count" -eq 1 ] || fail "$sentinel must appear exactly once (found $count)"
    line="$(grep -nF "$sentinel" "$rendered_file" | cut -d: -f1)"
    reporting_line="$(grep -nFx '## Reporting protocol' "$rendered_file" | cut -d: -f1)"
    [ "$line" -gt "$reporting_line" ] || fail "$sentinel appears outside Reporting protocol"
done

echo "lane-brief template: ok"
