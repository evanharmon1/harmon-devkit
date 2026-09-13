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
brief_source="$repo/ai/schemas/fixtures/brief.envelope/valid/codex.md"
git init -q "$fixture"
mkdir -p "$fixture/scripts"
ln -s "$repo/scripts/validate-result-schemas.mjs" "$fixture/scripts/validate-result-schemas.mjs"
git -C "$fixture" config user.name "Lane Fence Test"
git -C "$fixture" config user.email "lane-fence@example.invalid"
printf '%s\n' base >"$fixture/allowed.txt"
printf '%s\n' base >"$fixture/outside.txt"
printf '%s\n' base >"$fixture/outside-rename.txt"
printf '%s\n' 'unique unchanged copy source' >"$fixture/copy-source.txt"
mkdir -p "$fixture/glob"
printf '%s\n' base >"$fixture/glob/one.txt"
git -C "$fixture" add .
git -C "$fixture" commit -qm "test: seed fence fixture"
base="$(git -C "$fixture" rev-parse HEAD)"
git -C "$fixture" update-ref refs/remotes/origin/main "$base"
invoking_worktree="$tmp/invoking-worktree"
git -C "$fixture" worktree add --detach -q "$invoking_worktree" "$base"

make_brief() {
    destination="$1"
    fence_json="$2"
    brief_base="${3:-$base}"
    awk '
      /^<!-- BEGIN SCHEMA-BOUND ENVELOPE FACTS -->$/ { inside=1; next }
      /^<!-- END SCHEMA-BOUND ENVELOPE FACTS -->$/ { inside=0; next }
      inside && /^```json$/ { fenced=1; next }
      inside && fenced && /^```$/ { fenced=0; next }
      inside && fenced { print }
    ' "$brief_source" | jq --argjson fence "$fence_json" --arg base "$brief_base" \
        --arg worktree "$fixture" \
        '.fence = $fence | .base_sha = $base | .default_branch = "main" | .worktree_path = $worktree' \
        >"$tmp/envelope.json"
    sed -n '1,/^<!-- BEGIN SCHEMA-BOUND ENVELOPE FACTS -->$/p' "$brief_source" >"$destination"
    printf '\n```json\n' >>"$destination"
    cat "$tmp/envelope.json" >>"$destination"
    printf '```\n\n' >>"$destination"
    sed -n '/^<!-- END SCHEMA-BOUND ENVELOPE FACTS -->$/,$p' "$brief_source" >>"$destination"
}

fence_check="$repo/ai/skills/universal/orchestrator/assets/fence-check.sh"
make_brief "$tmp/allowed.md" '[{"path":"allowed.txt"}]'
printf '%s\n' changed >"$fixture/allowed.txt"
git -C "$fixture" add allowed.txt
git -C "$fixture" commit -qm "test: change allowed path"
(
    cd "$fixture"
    "$fence_check" --brief "$tmp/allowed.md"
) >/dev/null || fail "an in-fence change was rejected"

mkdir -p \
    "$fixture/.agents/skills/orchestrator/assets" \
    "$tmp/nodebin"
cp "$fence_check" "$fixture/.agents/skills/orchestrator/assets/fence-check.sh"
printf '#!/bin/sh\n[ "$1" = "%s/scripts/validate-result-schemas.mjs" ]\n' "$fixture" >"$tmp/nodebin/node"
chmod +x "$tmp/nodebin/node"
(
    cd "$fixture"
    PATH="$tmp/nodebin:$PATH" .agents/skills/orchestrator/assets/fence-check.sh \
        --brief "$tmp/allowed.md"
) >/dev/null || fail "a vendored-layout fence check did not resolve the repository validator"

printf '%s\n' changed >"$fixture/outside.txt"
git -C "$fixture" add outside.txt
git -C "$fixture" commit -qm "test: change outside path"
if out="$(cd "$fixture" && "$fence_check" --brief "$tmp/allowed.md" 2>&1)"; then
    fail "an out-of-fence change was accepted"
fi
case "$out" in
*outside.txt*) ;;
*) fail "out-of-fence failure did not name outside.txt: $out" ;;
esac
if out="$(cd "$invoking_worktree" && "$fence_check" --brief "$tmp/allowed.md" 2>&1)"; then
    fail "invoking from another checkout silently checked that checkout"
fi
case "$out" in
*outside.txt*) ;;
*) fail "cross-checkout refusal did not report the lane worktree path: $out" ;;
esac

printf '%s\n' '2026-09-13 fence expansion: outside.txt:1-4 — rejecting validator' >"$tmp/report.md"
(
    cd "$fixture"
    "$fence_check" --brief "$tmp/allowed.md" --report "$tmp/report.md"
) >"$tmp/expansion.out" || fail "a dated self-expansion was not honoured"
grep -Fq 'expansion-claimed: outside.txt (report line 1)' "$tmp/expansion.out" ||
    fail "a report expansion was not labelled for the orchestrator"

make_brief "$tmp/bad-base.md" '[{"path":"allowed.txt"},{"path":"outside.txt"}]' \
    0000000000000000000000000000000000000000
if out="$(cd "$fixture" && "$fence_check" --brief "$tmp/bad-base.md" 2>&1)"; then
    fail "a brief base outside the derived-base ancestry was accepted"
fi
case "$out" in
*'is not an ancestor of derived base'*) ;;
*) fail "base-ancestry refusal was not actionable: $out" ;;
esac

git -C "$fixture" mv outside-rename.txt allowed-renamed.txt
git -C "$fixture" commit -qm "test: rename an out-of-fence source"
make_brief "$tmp/rename.md" '[{"path":"allowed.txt"},{"path":"outside.txt"},{"path":"allowed-renamed.txt"}]'
if out="$(cd "$fixture" && "$fence_check" --brief "$tmp/rename.md" 2>&1)"; then
    fail "a rename from an out-of-fence source was accepted"
fi
case "$out" in
*outside-rename.txt*) ;;
*) fail "rename refusal did not name its out-of-fence source: $out" ;;
esac

make_brief "$tmp/glob.md" '[{"path":"allowed.txt"},{"path":"outside.txt"},{"path":"outside-rename.txt"},{"path":"allowed-renamed.txt"},{"path":"glob/*.txt"}]'
printf '%s\n' changed >"$fixture/glob/one.txt"
git -C "$fixture" add glob/one.txt
git -C "$fixture" commit -qm "test: change glob path"
(
    cd "$fixture"
    "$fence_check" --brief "$tmp/glob.md" --report "$tmp/report.md"
) >/dev/null || fail "a matching glob entry was rejected"

mkdir -p "$fixture/glob/private"
printf '%s\n' changed >"$fixture/glob/private/task.txt"
git -C "$fixture" add glob/private/task.txt
git -C "$fixture" commit -qm "test: add nested glob path"
if out="$(cd "$fixture" && "$fence_check" --brief "$tmp/glob.md" 2>&1)"; then
    fail "a single-component glob accepted a nested path"
fi
case "$out" in
*glob/private/task.txt*) ;;
*) fail "nested-path refusal did not name the path: $out" ;;
esac
make_brief "$tmp/globstar.md" '[{"path":"allowed.txt"},{"path":"outside.txt"},{"path":"outside-rename.txt"},{"path":"allowed-renamed.txt"},{"path":"glob/**"}]'
(
    cd "$fixture"
    "$fence_check" --brief "$tmp/globstar.md" --report "$tmp/report.md"
) >/dev/null || fail "a recursive glob rejected a nested path"

make_brief "$tmp/tooling.md" '[{"path":"CHANGELOG.md"}]'
if out="$(cd "$fixture" && "$fence_check" --brief "$tmp/tooling.md" 2>&1)"; then
    fail "a tooling-owned path was accepted in the fence"
fi
case "$out" in
*release-owned*CHANGELOG.md*) ;;
*) fail "release-owned refusal was not actionable: $out" ;;
esac

make_brief "$tmp/lockfile.md" '[{"path":"allowed.txt"},{"path":"outside.txt"},{"path":"outside-rename.txt"},{"path":"allowed-renamed.txt"},{"path":"glob/**"},{"path":"package-lock.json"}]'
(
    cd "$fixture"
    "$fence_check" --brief "$tmp/lockfile.md"
) >/dev/null || fail "an ordinary lockfile fence entry was rejected"

newline_path=$'allowed-newline-a.txt\nallowed-newline-b.txt'
printf '%s\n' changed >"$fixture/$newline_path"
git -C "$fixture" add -- "$newline_path"
git -C "$fixture" commit -qm "test: add a newline-bearing out-of-fence path"
make_brief "$tmp/newline.md" '[{"path":"allowed.txt"},{"path":"outside.txt"},{"path":"outside-rename.txt"},{"path":"allowed-renamed.txt"},{"path":"glob/**"},{"path":"allowed-newline-a.txt"},{"path":"allowed-newline-b.txt"}]'
if out="$(cd "$fixture" && "$fence_check" --brief "$tmp/newline.md" 2>&1)"; then
    fail "a newline-bearing out-of-fence path was split into allowed paths"
fi
case "$out" in
*allowed-newline-a.txt*allowed-newline-b.txt*) ;;
*) fail "newline-path refusal did not render the escaped full path: $out" ;;
esac
newline_fence="$(jq -cn --arg path "$newline_path" \
    '[{"path":"allowed.txt"},{"path":"outside.txt"},{"path":"outside-rename.txt"},{"path":"allowed-renamed.txt"},{"path":"glob/**"},{"path":$path}]')"
make_brief "$tmp/newline-fence.md" "$newline_fence"
(
    cd "$fixture"
    "$fence_check" --brief "$tmp/newline-fence.md"
) >/dev/null || fail "an exact newline-bearing fence entry was split into patterns"

cp "$fixture/copy-source.txt" "$fixture/copy-destination.txt"
git -C "$fixture" add copy-destination.txt
git -C "$fixture" commit -qm "test: copy an unchanged out-of-fence source"
copy_fence="$(jq -cn --arg path "$newline_path" \
    '[{"path":"allowed.txt"},{"path":"outside.txt"},{"path":"outside-rename.txt"},{"path":"allowed-renamed.txt"},{"path":"glob/**"},{"path":"copy-destination.txt"},{"path":$path}]')"
make_brief "$tmp/copy.md" "$copy_fence"
if out="$(cd "$fixture" && "$fence_check" --brief "$tmp/copy.md" 2>&1)"; then
    fail "a copy from an unchanged out-of-fence source was accepted"
fi
case "$out" in
*copy-source.txt*) ;;
*) fail "copy refusal did not name its out-of-fence source: $out" ;;
esac

scanner="$repo/ai/skills/universal/orchestrator/assets/validator-dependency-scan.sh"
scan_fixture="$tmp/scan-repo"
git init -q "$scan_fixture"
mkdir -p \
    "$scan_fixture/ai/skills/universal/breakdown/assets" \
    "$scan_fixture/ai/skills/universal/label-registry-support/assets" \
    "$scan_fixture/.agents/skills/portable/assets" \
    "$scan_fixture/.claude/skills/compat/assets" \
    "$scan_fixture/scripts"
printf '%s\n' '{"registry_set": []}' >"$scan_fixture/agent-registry.json"
for consumer in \
    ai/skills/universal/breakdown/assets/discover-label-vocabulary.mjs \
    ai/skills/universal/label-registry-support/assets/label-registry.sh \
    scripts/label-registry-render.mjs \
    scripts/validate-label-registry.mjs; do
    printf '%s\n' 'registry_set' >"$scan_fixture/$consumer"
done
printf '%s\n' 'registry_set' >"$scan_fixture/.agents/skills/portable/assets/registry-consumer.sh"
printf '%s\n' 'registry_set' >"$scan_fixture/.claude/skills/compat/assets/registry-consumer.sh"
printf '%s\n' '{"status":"ok","properties":{"baseSha":{"enum":["go"]}}}' >"$scan_fixture/short-keys.json"
printf '%s\n' 'status baseSha' >"$scan_fixture/scripts/short-key-consumer.sh"
printf '%s\n' 'go' >"$scan_fixture/scripts/short-enum-consumer.sh"
printf '%s\n' 'id: short' >"$scan_fixture/short-keys.yaml"
printf '%s\n' '- name: fixture' >>"$scan_fixture/short-keys.yaml"
printf '%s\n' 'id name' >"$scan_fixture/scripts/yaml-key-consumer.sh"
printf '%s\n' 'id = "short"' >"$scan_fixture/short-keys.toml"
printf '%s\n' 'id' >"$scan_fixture/scripts/toml-key-consumer.sh"
isolated_scan_out="$(cd "$scan_fixture" && "$scanner" agent-registry.json)" ||
    fail "isolated dependency scan failed"
for consumer in \
    ai/skills/universal/breakdown/assets/discover-label-vocabulary.mjs \
    ai/skills/universal/label-registry-support/assets/label-registry.sh \
    scripts/label-registry-render.mjs \
    scripts/validate-label-registry.mjs; do
    grep -Fxq "$consumer" <<<"$isolated_scan_out" || fail "isolated scan missed $consumer"
done
for consumer in \
    .agents/skills/portable/assets/registry-consumer.sh \
    .claude/skills/compat/assets/registry-consumer.sh; do
    grep -Fxq "$consumer" <<<"$isolated_scan_out" || fail "vendored scan missed $consumer"
done
short_scan_out="$(cd "$scan_fixture" && "$scanner" short-keys.json)" ||
    fail "short-key dependency scan failed"
grep -Fxq scripts/short-key-consumer.sh <<<"$short_scan_out" ||
    fail "dependency scan missed short schema keys"
grep -Fxq scripts/short-enum-consumer.sh <<<"$short_scan_out" ||
    fail "dependency scan missed a short enum value"
yaml_scan_out="$(cd "$scan_fixture" && "$scanner" short-keys.yaml)" ||
    fail "YAML-key dependency scan failed"
grep -Fxq scripts/yaml-key-consumer.sh <<<"$yaml_scan_out" ||
    fail "dependency scan missed short or list-mapping YAML keys"
toml_scan_out="$(cd "$scan_fixture" && "$scanner" short-keys.toml)" ||
    fail "TOML-key dependency scan failed"
grep -Fxq scripts/toml-key-consumer.sh <<<"$toml_scan_out" ||
    fail "dependency scan missed a short TOML key"

scan_out="$("$scanner" agent-registry.json)" || fail "real-tree dependency scan failed"
for consumer in \
    ai/skills/universal/breakdown/assets/discover-label-vocabulary.mjs \
    ai/skills/universal/label-registry-support/assets/label-registry.sh \
    scripts/label-registry-render.mjs \
    scripts/validate-label-registry.mjs; do
    grep -Fxq "$consumer" <<<"$scan_out" || fail "dependency scan missed $consumer"
done

real_grep="$(command -v grep)"
mkdir -p "$tmp/fakebin"
printf '#!/bin/sh\ncase "$*" in *"/scripts"*) exit 2;; esac\nexec %s "$@"\n' "$real_grep" >"$tmp/fakebin/grep"
chmod +x "$tmp/fakebin/grep"
if out="$(PATH="$tmp/fakebin:$PATH" "$scanner" agent-registry.json 2>&1)"; then
    fail "a grep error produced a partial successful dependency scan"
fi
case "$out" in
*'grep failed for'*'/scripts (exit 2)'*) ;;
*) fail "grep failure did not name its root and status: $out" ;;
esac

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
