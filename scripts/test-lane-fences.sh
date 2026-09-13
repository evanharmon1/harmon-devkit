#!/usr/bin/env bash
# Behavioral and prose-contract tests for orchestrated lane file fences.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "FAIL: $*" >&2
    exit 1
}

tmp="$(mktemp -d "${TMPDIR:-/tmp}/lane-fences-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

fixture="$tmp/repo"
git init -q "$fixture"
git -C "$fixture" config user.name "Lane Fence Test"
git -C "$fixture" config user.email "lane-fence@example.invalid"
printf '%s\n' base >"$fixture/allowed.txt"
printf '%s\n' base >"$fixture/outside.txt"
mkdir -p "$fixture/glob"
printf '%s\n' base >"$fixture/glob/one.txt"
git -C "$fixture" add .
git -C "$fixture" commit -qm "test: seed fence fixture"
base="$(git -C "$fixture" rev-parse HEAD)"

make_brief() {
    destination="$1"
    fence_json="$2"
    awk '
      /^<!-- BEGIN SCHEMA-BOUND ENVELOPE FACTS -->$/ { inside=1; next }
      /^<!-- END SCHEMA-BOUND ENVELOPE FACTS -->$/ { inside=0; next }
      inside && /^```json$/ { fenced=1; next }
      inside && fenced && /^```$/ { fenced=0; next }
      inside && fenced { print }
    ' .lane-brief.md | jq --argjson fence "$fence_json" '.fence = $fence' >"$tmp/envelope.json"
    sed -n '1,/^<!-- BEGIN SCHEMA-BOUND ENVELOPE FACTS -->$/p' .lane-brief.md >"$destination"
    printf '\n```json\n' >>"$destination"
    cat "$tmp/envelope.json" >>"$destination"
    printf '```\n\n' >>"$destination"
    sed -n '/^<!-- END SCHEMA-BOUND ENVELOPE FACTS -->$/,$p' .lane-brief.md >>"$destination"
}

fence_check="$repo/ai/skills/universal/orchestrator/assets/fence-check.sh"
make_brief "$tmp/allowed.md" '[{"path":"allowed.txt"}]'
printf '%s\n' changed >"$fixture/allowed.txt"
git -C "$fixture" add allowed.txt
git -C "$fixture" commit -qm "test: change allowed path"
(
    cd "$fixture"
    "$fence_check" --brief "$tmp/allowed.md" --base "$base"
) >/dev/null || fail "an in-fence change was rejected"

printf '%s\n' changed >"$fixture/outside.txt"
git -C "$fixture" add outside.txt
git -C "$fixture" commit -qm "test: change outside path"
if out="$(cd "$fixture" && "$fence_check" --brief "$tmp/allowed.md" --base "$base" 2>&1)"; then
    fail "an out-of-fence change was accepted"
fi
case "$out" in
*outside.txt*) ;;
*) fail "out-of-fence failure did not name outside.txt: $out" ;;
esac

printf '%s\n' '2026-09-13 fence expansion: outside.txt:1-4 — rejecting validator' >"$tmp/report.md"
(
    cd "$fixture"
    "$fence_check" --brief "$tmp/allowed.md" --base "$base" --report "$tmp/report.md"
) >/dev/null || fail "a dated self-expansion was not honoured"

make_brief "$tmp/glob.md" '[{"path":"allowed.txt"},{"path":"outside.txt"},{"path":"glob/*.txt"}]'
printf '%s\n' changed >"$fixture/glob/one.txt"
git -C "$fixture" add glob/one.txt
git -C "$fixture" commit -qm "test: change glob path"
(
    cd "$fixture"
    "$fence_check" --brief "$tmp/glob.md" --base "$base"
) >/dev/null || fail "a matching glob entry was rejected"

make_brief "$tmp/tooling.md" '[{"path":"CHANGELOG.md"}]'
if out="$(cd "$fixture" && "$fence_check" --brief "$tmp/tooling.md" --base "$base" 2>&1)"; then
    fail "a tooling-owned path was accepted in the fence"
fi
case "$out" in
*tooling-owned*CHANGELOG.md*) ;;
*) fail "tooling-owned refusal was not actionable: $out" ;;
esac

scanner="$repo/ai/skills/universal/orchestrator/assets/validator-dependency-scan.sh"
scan_out="$("$scanner" agent-registry.json)" || fail "real-tree dependency scan failed"
for consumer in \
    ai/skills/universal/breakdown/assets/discover-label-vocabulary.mjs \
    ai/skills/universal/label-registry-support/assets/label-registry.sh \
    scripts/label-registry-render.mjs \
    scripts/validate-label-registry.mjs; do
    grep -Fxq "$consumer" <<<"$scan_out" || fail "dependency scan missed $consumer"
done

skill="ai/skills/universal/orchestrator/SKILL.md"
template="ai/skills/universal/orchestrator/assets/lane-brief.md"
grep -Fq 'A file-scope fence is the closed list of paths and globs' "$skill" ||
    fail "orchestrator skill does not define a lane fence"
grep -Fq 'validator-dependency-scan.sh' "$skill" ||
    fail "orchestrator skill does not require the validator-dependency scan"
grep -Fq 'one writer per file' "$skill" ||
    fail "orchestrator skill does not state cross-lane ownership"
grep -Fq 'run.json` intervention with `kind: asked' "$skill" ||
    fail "orchestrator skill does not record self-expansion intervention"
grep -Fq 'fence-check.sh' "$skill" ||
    fail "orchestrator skill does not require the pre-gate subset check"
grep -Fq 'not a readiness-gate condition' "$skill" ||
    fail "orchestrator skill incorrectly folds the subset check into readiness"
grep -Fq 'A validator or test that rejects your change and that no other live lane touches' "$template" &&
    grep -Fq 'may be added to this fence by you ONCE' "$template" ||
    fail "lane-brief template lost the bounded self-expansion clause"
grep -Fq 'For every other out-of-fence edit, append a dated blocker' "$template" ||
    fail "lane-brief template lost the out-of-fence STOP rule"

test_deps="$(yq -r '.tasks.test.deps[]' Taskfile.yml)"
verify_cmds="$(yq -r '.tasks.verify.cmds[].task' Taskfile.yml)"
grep -Fxq 'test:lane-fences' <<<"$test_deps" || fail "test:lane-fences is not wired into test deps"
if grep -Fxq 'test:lane-fences' <<<"$verify_cmds"; then
    fail "test:lane-fences is duplicated in verify cmds"
fi

echo "lane fences: ok"
