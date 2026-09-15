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
fixture_branch="$(git -C "$fixture" branch --show-current)"
invoking_worktree="$tmp/invoking-worktree"
git -C "$fixture" worktree add --detach -q "$invoking_worktree" "$base"

make_brief() {
    destination="$1"
    fence_json="$2"
    brief_base="${3:-$base}"
    brief_report="${4:-$tmp/report.md}"
    brief_branch="${5:-$fixture_branch}"
    awk '
      /^<!-- BEGIN SCHEMA-BOUND ENVELOPE FACTS -->$/ { inside=1; next }
      /^<!-- END SCHEMA-BOUND ENVELOPE FACTS -->$/ { inside=0; next }
      inside && /^```json$/ { fenced=1; next }
      inside && fenced && /^```$/ { fenced=0; next }
      inside && fenced { print }
    ' "$brief_source" | jq --argjson fence "$fence_json" --arg base "$brief_base" \
        --arg worktree "$fixture" --arg report "$brief_report" --arg branch "$brief_branch" \
        '.fence = $fence | .base_sha = $base | .default_branch = "main" | .worktree_path = $worktree | .report_path = $report | .branch = $branch | .claim_handoff.branch = $branch' \
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

make_brief "$tmp/wrong-branch.md" '[{"path":"allowed.txt"},{"path":"outside.txt"}]' \
    "$base" "$tmp/report.md" "not-$fixture_branch"
if out="$(cd "$fixture" && "$fence_check" --brief "$tmp/wrong-branch.md" 2>&1)"; then
    fail "a brief bound to another branch was accepted"
fi
case "$out" in
*"envelope branch not-$fixture_branch"*"worktree branch $fixture_branch"*) ;;
*) fail "branch-mismatch refusal did not name both branches: $out" ;;
esac

printf '%s\n' '2026-09-13 fence expansion: outside.txt:1-4 — rejecting validator' >"$tmp/report.md"
(
    cd "$fixture"
    "$fence_check" --brief "$tmp/allowed.md"
) >"$tmp/expansion.out" || fail "a dated self-expansion was not honoured"
grep -Fq 'expansion-claimed: outside.txt (report line 1)' "$tmp/expansion.out" ||
    fail "a report expansion was not labelled for the orchestrator"

make_brief "$tmp/other-report.md" '[{"path":"allowed.txt"}]' \
    "$base" "$tmp/absent-report.md"
if out="$(cd "$fixture" && "$fence_check" --brief "$tmp/other-report.md" 2>&1)"; then
    fail "an expansion from a report other than the envelope report_path was accepted"
fi
case "$out" in
*outside.txt*) ;;
*) fail "other-report refusal did not name outside.txt: $out" ;;
esac
if out="$(cd "$fixture" && "$fence_check" --brief "$tmp/allowed.md" --report "$tmp/report.md" 2>&1)"; then
    fail "the deleted --report option was still accepted"
fi
case "$out" in
*'usage: fence-check.sh --brief <rendered.md>'*) ;;
*) fail "deleted --report option did not produce usage: $out" ;;
esac

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
    "$fence_check" --brief "$tmp/glob.md"
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
    "$fence_check" --brief "$tmp/globstar.md"
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

# Introduced one commit at a time (never together), and last among the
# $fixture-based cases: fence-check's diff is cumulative from the fixture's
# one fixed comparison base, so either a sibling added before its own
# assertion, or a later test's fence omitting it, would make it an unfenced
# offender for the wrong assertion. Reuses every path still live in that
# cumulative diff at this point (mirrors $copy_fence, plus the copy's own
# source, which --find-copies-harder keeps re-attributing on every later
# diff even though its own content never changed).
bracket_fence="$(jq -cn --arg newline_path "$newline_path" \
    '[{"path":"allowed.txt"},{"path":"outside.txt"},{"path":"outside-rename.txt"},{"path":"allowed-renamed.txt"},{"path":"glob/**"},{"path":"copy-destination.txt"},{"path":"copy-source.txt"},{"path":$newline_path},{"path":"app/[id]/page.tsx"}]')"
mkdir -p "$fixture/app/[id]"
printf '%s\n' base >"$fixture/app/[id]/page.tsx"
git -C "$fixture" add "app/[id]/page.tsx"
git -C "$fixture" commit -qm "test: add a literal bracketed path"
make_brief "$tmp/bracket-literal.md" "$bracket_fence"
(
    cd "$fixture"
    "$fence_check" --brief "$tmp/bracket-literal.md"
) >/dev/null || fail "a literal fence entry containing bracket characters rejected its own exact path"

mkdir -p "$fixture/app/i"
printf '%s\n' base >"$fixture/app/i/page.tsx"
git -C "$fixture" add "app/i/page.tsx"
git -C "$fixture" commit -qm "test: add a path a bracket-glob would collapse the literal entry onto"
if out="$(cd "$fixture" && "$fence_check" --brief "$tmp/bracket-literal.md" 2>&1)"; then
    fail "a literal bracketed fence entry was glob-interpreted to admit a different path"
fi
case "$out" in
*'app/i/page.tsx'*) ;;
*) fail "bracket-glob refusal did not name the unfenced sibling path: $out" ;;
esac

echo "== fence-check.sh: resolves the comparison base from the envelope issue.url's target remote =="
make_remote_fixture() {
    # $1: fixture dir  $2: origin url or "" to skip  $3: upstream url or ""
    # Callers create the upstream/main ref explicitly (or don't) afterward.
    local dir="$1" origin_url="$2" upstream_url="$3"
    git init -q "$dir"
    mkdir -p "$dir/scripts"
    ln -s "$repo/scripts/validate-result-schemas.mjs" "$dir/scripts/validate-result-schemas.mjs"
    git -C "$dir" config user.name "Lane Fence Test"
    git -C "$dir" config user.email "lane-fence@example.invalid"
    printf '%s\n' base >"$dir/allowed.txt"
    git -C "$dir" add .
    git -C "$dir" commit -qm "test: seed remote-resolution fixture"
    [ -z "$origin_url" ] || git -C "$dir" remote add origin "$origin_url"
    [ -z "$upstream_url" ] || git -C "$dir" remote add upstream "$upstream_url"
}

make_remote_brief() {
    # $1: destination  $2: fixture dir  $3: base sha  $4: issue url
    local destination="$1" dir="$2" base_sha="$3" issue_url="$4" branch
    branch="$(git -C "$dir" branch --show-current)"
    awk '
      /^<!-- BEGIN SCHEMA-BOUND ENVELOPE FACTS -->$/ { inside=1; next }
      /^<!-- END SCHEMA-BOUND ENVELOPE FACTS -->$/ { inside=0; next }
      inside && /^```json$/ { fenced=1; next }
      inside && fenced && /^```$/ { fenced=0; next }
      inside && fenced { print }
    ' "$brief_source" | jq --argjson fence '[{"path":"allowed.txt"}]' --arg base "$base_sha" \
        --arg worktree "$dir" --arg report "$tmp/remote-report.md" --arg branch "$branch" --arg issue_url "$issue_url" \
        '.fence = $fence | .base_sha = $base | .default_branch = "main" | .worktree_path = $worktree | .report_path = $report | .branch = $branch | .claim_handoff.branch = $branch | .issue.url = $issue_url' \
        >"$tmp/remote-envelope.json"
    sed -n '1,/^<!-- BEGIN SCHEMA-BOUND ENVELOPE FACTS -->$/p' "$brief_source" >"$destination"
    printf '\n```json\n' >>"$destination"
    cat "$tmp/remote-envelope.json" >>"$destination"
    printf '```\n\n' >>"$destination"
    sed -n '/^<!-- END SCHEMA-BOUND ENVELOPE FACTS -->$/,$p' "$brief_source" >>"$destination"
}

# Fork topology: origin is the writable fork and lacks the default branch
# entirely (no refs/remotes/origin/main at all); upstream is the PR target
# and carries it. issue.url names upstream's owner/repo.
fork_fixture="$tmp/fork-repo"
make_remote_fixture "$fork_fixture" "https://github.com/example-fork/harmon-devkit.git" \
    "https://github.com/example-upstream/harmon-devkit.git"
fork_base="$(git -C "$fork_fixture" rev-parse HEAD)"
git -C "$fork_fixture" update-ref refs/remotes/upstream/main "$fork_base"
printf '%s\n' changed >"$fork_fixture/allowed.txt"
git -C "$fork_fixture" add allowed.txt
git -C "$fork_fixture" commit -qm "test: change allowed path in fork topology"
make_remote_brief "$tmp/fork.md" "$fork_fixture" "$fork_base" "https://github.com/example-upstream/harmon-devkit/issues/1"
out="$(cd "$fork_fixture" && "$fence_check" --brief "$tmp/fork.md" 2>&1)" ||
    fail "a fork-topology change was rejected: $out"
case "$out" in
*"using remote 'upstream'"*"issue.url"*) ;;
*) fail "fork-topology comparison base did not report the resolved remote and source: $out" ;;
esac

# Non-fork checkout regression (challenge round 1, confirmed): origin already
# is the PR target (issue.url matches it) but the checkout also carries an
# unrelated upstream remote for a different repository entirely. The old
# `gh repo view`-ambient-resolution design could regress here by preferring
# a gh-favoured remote name over the actual target; issue.url must still
# resolve to origin.
unrelated_fixture="$tmp/unrelated-upstream-repo"
make_remote_fixture "$unrelated_fixture" "https://github.com/evanharmon1/harmon-devkit.git" \
    "https://github.com/example-unrelated/some-other-repo.git"
unrelated_base="$(git -C "$unrelated_fixture" rev-parse HEAD)"
git -C "$unrelated_fixture" update-ref refs/remotes/origin/main "$unrelated_base"
printf '%s\n' changed >"$unrelated_fixture/allowed.txt"
git -C "$unrelated_fixture" add allowed.txt
git -C "$unrelated_fixture" commit -qm "test: change allowed path with an unrelated upstream remote present"
make_remote_brief "$tmp/unrelated.md" "$unrelated_fixture" "$unrelated_base" "https://github.com/evanharmon1/harmon-devkit/issues/987"
out="$(cd "$unrelated_fixture" && "$fence_check" --brief "$tmp/unrelated.md" 2>&1)" ||
    fail "a non-fork checkout with an unrelated upstream remote was rejected: $out"
case "$out" in
*"using remote 'origin'"*"issue.url"*) ;;
*) fail "unrelated-upstream comparison base did not resolve to origin via issue.url: $out" ;;
esac

# Duplicate-remote regression (challenge round 2, confirmed): a second,
# never-fetched remote alias for the SAME repository sorts before origin in
# `git remote` order (alphabetical: "github" < "origin"). Picking the first
# URL-matching remote unconditionally would select the alias and fail
# closed even though origin (fetched, ref present) works fine.
duplicate_fixture="$tmp/duplicate-remote-repo"
make_remote_fixture "$duplicate_fixture" "https://github.com/evanharmon1/harmon-devkit.git" ""
git -C "$duplicate_fixture" remote add github "https://github.com/evanharmon1/harmon-devkit.git"
duplicate_base="$(git -C "$duplicate_fixture" rev-parse HEAD)"
git -C "$duplicate_fixture" update-ref refs/remotes/origin/main "$duplicate_base"
printf '%s\n' changed >"$duplicate_fixture/allowed.txt"
git -C "$duplicate_fixture" add allowed.txt
git -C "$duplicate_fixture" commit -qm "test: change allowed path with a never-fetched duplicate remote present"
make_remote_brief "$tmp/duplicate.md" "$duplicate_fixture" "$duplicate_base" "https://github.com/evanharmon1/harmon-devkit/issues/987"
out="$(cd "$duplicate_fixture" && "$fence_check" --brief "$tmp/duplicate.md" 2>&1)" ||
    fail "a duplicate-remote checkout with a never-fetched alphabetically-earlier alias was rejected: $out"
case "$out" in
*"using remote 'origin'"*"issue.url"*) ;;
*) fail "duplicate-remote comparison base did not prefer origin over the never-fetched alias: $out" ;;
esac

# Ref-resolvability preference regression (review round 1, confirmed
# coverage gap): no remote is named "origin", so the origin-preference
# branch never applies; two URL-matching remotes exist, and only the
# alphabetically LATER one ("zzz-mirror" > "alpha-mirror") has a fetched
# default-branch ref. The alphabetically-first-by-`git remote`-order match
# must still be skipped in favour of the one whose ref actually resolves.
ref_pref_fixture="$tmp/ref-preference-repo"
make_remote_fixture "$ref_pref_fixture" "" ""
git -C "$ref_pref_fixture" remote add alpha-mirror "https://github.com/evanharmon1/harmon-devkit.git"
git -C "$ref_pref_fixture" remote add zzz-mirror "https://github.com/evanharmon1/harmon-devkit.git"
ref_pref_base="$(git -C "$ref_pref_fixture" rev-parse HEAD)"
git -C "$ref_pref_fixture" update-ref refs/remotes/zzz-mirror/main "$ref_pref_base"
printf '%s\n' changed >"$ref_pref_fixture/allowed.txt"
git -C "$ref_pref_fixture" add allowed.txt
git -C "$ref_pref_fixture" commit -qm "test: change allowed path with no origin and an unresolvable alphabetically-first alias"
make_remote_brief "$tmp/ref-preference.md" "$ref_pref_fixture" "$ref_pref_base" "https://github.com/evanharmon1/harmon-devkit/issues/987"
out="$(cd "$ref_pref_fixture" && "$fence_check" --brief "$tmp/ref-preference.md" 2>&1)" ||
    fail "a checkout with no origin and an unresolvable alphabetically-first alias was rejected: $out"
case "$out" in
*"using remote 'zzz-mirror'"*"issue.url"*) ;;
*) fail "ref-preference comparison base did not skip the alphabetically-first remote lacking a resolvable ref: $out" ;;
esac

# URL-form and case-insensitivity regression (review round 1, confirmed
# coverage gap): every prior fixture uses one lower-case https://...git
# shape. A differently-cased ssh://git@github.com/ remote must still match
# a lower-case issue.url. The trailing "/" after ".git" also discriminates
# review round 1's own strip-order fix (review round 2, confirmed coverage
# gap): stripping ".git" before the trailing slash would leave this URL
# normalized to "evanharmon1/harmon-devkit.git", which never matches.
ssh_case_fixture="$tmp/ssh-case-repo"
make_remote_fixture "$ssh_case_fixture" "ssh://git@github.com/EvanHarmon1/Harmon-DevKit.git/" ""
ssh_case_base="$(git -C "$ssh_case_fixture" rev-parse HEAD)"
git -C "$ssh_case_fixture" update-ref refs/remotes/origin/main "$ssh_case_base"
printf '%s\n' changed >"$ssh_case_fixture/allowed.txt"
git -C "$ssh_case_fixture" add allowed.txt
git -C "$ssh_case_fixture" commit -qm "test: change allowed path with a differently-cased ssh:// origin remote"
make_remote_brief "$tmp/ssh-case.md" "$ssh_case_fixture" "$ssh_case_base" "https://github.com/evanharmon1/harmon-devkit/issues/987"
out="$(cd "$ssh_case_fixture" && "$fence_check" --brief "$tmp/ssh-case.md" 2>&1)" ||
    fail "a differently-cased ssh:// origin remote was rejected: $out"
case "$out" in
*"using remote 'origin'"*"issue.url"*) ;;
*) fail "ssh-case comparison base did not match a differently-cased ssh:// remote: $out" ;;
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
printf '%s\n' '"critical-key": value' >>"$scan_fixture/short-keys.yaml"
printf '%s\n' '      - 8080:8080' >>"$scan_fixture/short-keys.yaml"
printf '%s\n' '  guard:release-title:' >>"$scan_fixture/short-keys.yaml"
printf '%s\n' "'single-quoted-key': value" >>"$scan_fixture/short-keys.yaml"
printf '%s\n' '9lives: value' >>"$scan_fixture/short-keys.yaml"
printf '%s\n' 'id name' >"$scan_fixture/scripts/yaml-key-consumer.sh"
printf '%s\n' 'critical-key' >"$scan_fixture/scripts/yaml-quoted-key-consumer.sh"
printf '%s\n' '8080' >"$scan_fixture/scripts/yaml-port-mapping-consumer.sh"
printf '%s\n' 'task guard:release-title' >"$scan_fixture/scripts/yaml-colon-key-consumer.sh"
printf '%s\n' 'single-quoted-key' >"$scan_fixture/scripts/yaml-single-quoted-key-consumer.sh"
printf '%s\n' '9lives' >"$scan_fixture/scripts/yaml-digit-leading-key-consumer.sh"
printf '%s\n' 'id = "short"' >"$scan_fixture/short-keys.toml"
printf '%s\n' '_secret = "shh"' >>"$scan_fixture/short-keys.toml"
printf '%s\n' '"quoted-toml-key" = "x"' >>"$scan_fixture/short-keys.toml"
printf '%s\n' "'single-toml-key' = \"x\"" >>"$scan_fixture/short-keys.toml"
printf '%s\n' '-leading = "x"' >>"$scan_fixture/short-keys.toml"
printf '%s\n' 'id' >"$scan_fixture/scripts/toml-key-consumer.sh"
printf '%s\n' '_secret' >"$scan_fixture/scripts/toml-underscore-key-consumer.sh"
printf '%s\n' 'quoted-toml-key' >"$scan_fixture/scripts/toml-quoted-key-consumer.sh"
printf '%s\n' 'single-toml-key' >"$scan_fixture/scripts/toml-single-quoted-key-consumer.sh"
printf '%s\n' '-leading' >"$scan_fixture/scripts/toml-hyphen-leading-key-consumer.sh"
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
grep -Fxq scripts/yaml-quoted-key-consumer.sh <<<"$yaml_scan_out" ||
    fail "dependency scan missed a quoted YAML key"
grep -Fxq scripts/yaml-port-mapping-consumer.sh <<<"$yaml_scan_out" &&
    fail "dependency scan misread a Docker port-mapping scalar (- 8080:8080) as a key"
grep -Fxq scripts/yaml-colon-key-consumer.sh <<<"$yaml_scan_out" ||
    fail "dependency scan dropped a colon-bearing group:action-style YAML key"
grep -Fxq scripts/yaml-single-quoted-key-consumer.sh <<<"$yaml_scan_out" ||
    fail "dependency scan missed a single-quoted YAML key"
grep -Fxq scripts/yaml-digit-leading-key-consumer.sh <<<"$yaml_scan_out" ||
    fail "dependency scan missed a digit-leading bare YAML key"
toml_scan_out="$(cd "$scan_fixture" && "$scanner" short-keys.toml)" ||
    fail "TOML-key dependency scan failed"
grep -Fxq scripts/toml-key-consumer.sh <<<"$toml_scan_out" ||
    fail "dependency scan missed a short TOML key"
grep -Fxq scripts/toml-underscore-key-consumer.sh <<<"$toml_scan_out" ||
    fail "dependency scan missed an underscore-leading TOML key"
grep -Fxq scripts/toml-quoted-key-consumer.sh <<<"$toml_scan_out" ||
    fail "dependency scan missed a double-quoted TOML key"
grep -Fxq scripts/toml-single-quoted-key-consumer.sh <<<"$toml_scan_out" ||
    fail "dependency scan missed a single-quoted TOML key"
grep -Fxq scripts/toml-hyphen-leading-key-consumer.sh <<<"$toml_scan_out" ||
    fail "dependency scan missed a hyphen-leading bare TOML key"

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
