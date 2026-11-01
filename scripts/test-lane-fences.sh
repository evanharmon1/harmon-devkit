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
mkdir -p "$fixture/ai/skills/universal/dev-flow-support/assets"
ln -s "$repo/ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs" "$fixture/ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs"
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

fence_check="$repo/ai/skills/universal/orchestrate/assets/fence-check.sh"
make_brief "$tmp/allowed.md" '[{"path":"allowed.txt"}]'
printf '%s\n' changed >"$fixture/allowed.txt"
git -C "$fixture" add allowed.txt
git -C "$fixture" commit -qm "test: change allowed path"
(
    cd "$fixture"
    "$fence_check" --brief "$tmp/allowed.md"
) >/dev/null || fail "an in-fence change was rejected"

mkdir -p \
    "$fixture/.agents/skills/orchestrate/assets" \
    "$fixture/.agents/skills/dev-flow-support/assets" \
    "$tmp/nodebin"
cp "$fence_check" "$fixture/.agents/skills/orchestrate/assets/fence-check.sh"
# harmon-devkit#974: fence-check.sh resolves the brief validator from its OWN
# asset directory (`$asset_dir/../../dev-flow-support/assets`), not from
# `git rev-parse --show-toplevel` — the validator is a vendored sibling package
# now, and a consumer has no repository-root copy of it at all. So the stub
# expects the VENDORED path, and the fixture deliberately supplies the
# validator only there: if this resolution ever went back to the repository
# root, there would be nothing at the root to find and the case would fail.
# `pwd -P` still matters — the asset dir is resolved physically, so an
# invocation through a symlinked root (below) must reach the same real path.
ln -s "$repo/ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs" \
    "$fixture/.agents/skills/dev-flow-support/assets/validate-result-schemas.mjs"
fixture_resolved="$(cd "$fixture" && pwd -P)"
printf '#!/bin/sh\n[ "$1" = "%s/.agents/skills/orchestrate/assets/../../dev-flow-support/assets/validate-result-schemas.mjs" ]\n' "$fixture_resolved" >"$tmp/nodebin/node"
chmod +x "$tmp/nodebin/node"
(
    cd "$fixture"
    PATH="$tmp/nodebin:$PATH" .agents/skills/orchestrate/assets/fence-check.sh \
        --brief "$tmp/allowed.md"
) >/dev/null || fail "a vendored-layout fence check did not resolve its sibling dev-flow-support validator"

# #1080: exercise the same resolution through a DELIBERATE symlink alias to
# the fixture root, so the case fails on every platform (not only where
# TMPDIR itself happens to be a symlink, as on macOS) until fixed.
fixture_link="$tmp/repo-symlink"
ln -s "$fixture" "$fixture_link"
(
    cd "$fixture_link"
    PATH="$tmp/nodebin:$PATH" .agents/skills/orchestrate/assets/fence-check.sh \
        --brief "$tmp/allowed.md"
) >/dev/null || fail "a vendored-layout fence check invoked through a symlinked fixture root did not resolve its sibling dev-flow-support validator"

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
    mkdir -p "$dir/ai/skills/universal/dev-flow-support/assets"
    ln -s "$repo/ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs" "$dir/ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs"
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

# Empty-match-array regression (integration cycle 1, confirmed): a
# configured remote that does not match a non-GitHub/unparseable issue.url
# exercises the genuinely-empty match array, the exact path that used to
# expand `${#matches[@]}` directly. This host's bash is not 3.2, so it
# cannot reproduce the `set -u` abort itself; the assertion instead pins
# that the fallback path is reached and reports `source: fallback`, which
# a bash-3.2 abort on this same code path would never do.
no_match_fixture="$tmp/no-match-repo"
make_remote_fixture "$no_match_fixture" "https://github.com/evanharmon1/harmon-devkit.git" ""
no_match_base="$(git -C "$no_match_fixture" rev-parse HEAD)"
git -C "$no_match_fixture" update-ref refs/remotes/origin/main "$no_match_base"
printf '%s\n' changed >"$no_match_fixture/allowed.txt"
git -C "$no_match_fixture" add allowed.txt
git -C "$no_match_fixture" commit -qm "test: change allowed path with an unparseable issue.url and no matching remote"
make_remote_brief "$tmp/no-match.md" "$no_match_fixture" "$no_match_base" "not-a-url"
out="$(cd "$no_match_fixture" && "$fence_check" --brief "$tmp/no-match.md" 2>&1)" ||
    fail "an unparseable issue.url with a configured remote was rejected: $out"
case "$out" in
*"using remote 'origin'"*"(source: fallback)"*) ;;
*) fail "no-match comparison base did not reach the empty-array fallback path: $out" ;;
esac

# Local-branch-ambiguity regression (integration cycle 2, confirmed): a
# local branch literally named "origin/main" exists at HEAD, alongside the
# real refs/remotes/origin/main pointing at the true (older) base. The
# short <remote>/<branch> form resolves refs/heads/... before
# refs/remotes/..., so it would silently pick the local branch at HEAD,
# collapsing the merge base to HEAD and hiding an out-of-fence change.
ambiguous_fixture="$tmp/ambiguous-branch-repo"
make_remote_fixture "$ambiguous_fixture" "https://github.com/evanharmon1/harmon-devkit.git" ""
ambiguous_base="$(git -C "$ambiguous_fixture" rev-parse HEAD)"
git -C "$ambiguous_fixture" update-ref refs/remotes/origin/main "$ambiguous_base"
printf '%s\n' changed >"$ambiguous_fixture/outside.txt"
git -C "$ambiguous_fixture" add outside.txt
git -C "$ambiguous_fixture" commit -qm "test: an out-of-fence change with an ambiguous local branch name"
git -C "$ambiguous_fixture" branch -- origin/main
make_remote_brief "$tmp/ambiguous.md" "$ambiguous_fixture" "$ambiguous_base" "https://github.com/evanharmon1/harmon-devkit/issues/987"
if out="$(cd "$ambiguous_fixture" && "$fence_check" --brief "$tmp/ambiguous.md" 2>&1)"; then
    fail "an out-of-fence change was silently allowed by a local branch shadowing the remote-tracking ref name: $out"
fi
case "$out" in
*outside.txt*) ;;
*) fail "ambiguous-branch refusal did not name the out-of-fence path: $out" ;;
esac

# Leading-hyphen remote name regression (integration cycle 2, confirmed):
# the only target-matching remote is named "-target" (legal via `git
# remote add --`); `git remote get-url` without `--` would parse it as an
# unrecognized option and silently drop the match via `|| continue`.
hyphen_fixture="$tmp/hyphen-remote-repo"
make_remote_fixture "$hyphen_fixture" "" ""
git -C "$hyphen_fixture" remote add -- -target "https://github.com/evanharmon1/harmon-devkit.git"
hyphen_base="$(git -C "$hyphen_fixture" rev-parse HEAD)"
git -C "$hyphen_fixture" update-ref refs/remotes/-target/main "$hyphen_base"
printf '%s\n' changed >"$hyphen_fixture/allowed.txt"
git -C "$hyphen_fixture" add allowed.txt
git -C "$hyphen_fixture" commit -qm "test: change allowed path with a leading-hyphen remote name"
make_remote_brief "$tmp/hyphen.md" "$hyphen_fixture" "$hyphen_base" "https://github.com/evanharmon1/harmon-devkit/issues/987"
out="$(cd "$hyphen_fixture" && "$fence_check" --brief "$tmp/hyphen.md" 2>&1)" ||
    fail "a leading-hyphen remote name was rejected: $out"
case "$out" in
*"using remote '-target'"*"issue.url"*) ;;
*) fail "hyphen-remote comparison base did not resolve the leading-hyphen remote: $out" ;;
esac

# Mixed-case host regression (integration cycle 2, confirmed): the target
# remote's URL uses an upper-case host ("GITHUB.COM"), which no case arm
# matches literally; the old trailing-only lowercase step ran too late to
# help.
host_case_fixture="$tmp/host-case-repo"
make_remote_fixture "$host_case_fixture" "https://GITHUB.COM/evanharmon1/harmon-devkit.git" ""
host_case_base="$(git -C "$host_case_fixture" rev-parse HEAD)"
git -C "$host_case_fixture" update-ref refs/remotes/origin/main "$host_case_base"
printf '%s\n' changed >"$host_case_fixture/allowed.txt"
git -C "$host_case_fixture" add allowed.txt
git -C "$host_case_fixture" commit -qm "test: change allowed path with an upper-case host origin remote"
make_remote_brief "$tmp/host-case.md" "$host_case_fixture" "$host_case_base" "https://github.com/evanharmon1/harmon-devkit/issues/987"
out="$(cd "$host_case_fixture" && "$fence_check" --brief "$tmp/host-case.md" 2>&1)" ||
    fail "an upper-case host origin remote was rejected: $out"
case "$out" in
*"using remote 'origin'"*"issue.url"*) ;;
*) fail "host-case comparison base did not match an upper-case host remote: $out" ;;
esac

# Overlapping remote-namespace regression (integration cycle 3, confirmed):
# remote "foo" and remote "foo/release" can compose the identical tracking
# ref under two different (remote, branch) pairs (e.g. "foo" + branch
# "release/main" and "foo/release" + branch "main" both resolve to
# refs/remotes/foo/release/main); which remote actually supplied a resolved
# ref would then be ambiguous, so the script must refuse rather than guess.
# `git remote add` itself refuses to create this pair directly (a builtin
# subset/superset guard added for this exact reason), so the fixture writes
# the second remote's config directly via `git config`, the way a
# hand-edited .git/config or an older git without that guard could still
# produce it.
overlap_fixture="$tmp/overlap-namespace-repo"
make_remote_fixture "$overlap_fixture" "" ""
git -C "$overlap_fixture" remote add foo "https://github.com/evanharmon1/harmon-devkit.git"
git -C "$overlap_fixture" config remote."foo/release".url "https://github.com/example-other/some-other-repo.git"
git -C "$overlap_fixture" config remote."foo/release".fetch "+refs/heads/*:refs/remotes/foo/release/*"
overlap_base="$(git -C "$overlap_fixture" rev-parse HEAD)"
git -C "$overlap_fixture" update-ref refs/remotes/foo/main "$overlap_base"
printf '%s\n' changed >"$overlap_fixture/allowed.txt"
git -C "$overlap_fixture" add allowed.txt
git -C "$overlap_fixture" commit -qm "test: change allowed path with overlapping remote namespaces present"
make_remote_brief "$tmp/overlap.md" "$overlap_fixture" "$overlap_base" "https://github.com/evanharmon1/harmon-devkit/issues/987"
if out="$(cd "$overlap_fixture" && "$fence_check" --brief "$tmp/overlap.md" 2>&1)"; then
    fail "overlapping remote namespaces (foo, foo/release) did not refuse to derive a comparison base: $out"
fi
case "$out" in
*'remote namespaces overlap (foo, foo/release)'*) ;;
*) fail "overlap refusal did not name both overlapping remote names: $out" ;;
esac

scanner="$repo/ai/skills/universal/orchestrate/assets/validator-dependency-scan.sh"
skill="ai/skills/universal/orchestrate/SKILL.md"
template="ai/skills/universal/orchestrate/assets/lane-brief.md"
grep -Fq 'A file-scope fence is the closed list of paths and globs' "$skill" ||
    fail "orchestrate skill does not define a lane fence"
grep -Fq 'validator-dependency-scan.sh' "$skill" ||
    fail "orchestrate skill does not require the validator-dependency scan"
grep -Fq 'one writer per file' "$skill" ||
    fail "orchestrate skill does not state cross-lane ownership"
grep -Fq 'run.json` intervention with `kind: asked' "$skill" ||
    fail "orchestrate skill does not record self-expansion intervention"
grep -Fq 'fence-check.sh' "$skill" ||
    fail "orchestrate skill does not require the pre-gate subset check"
grep -Fq 'not a readiness-gate condition' "$skill" ||
    fail "orchestrate skill incorrectly folds the subset check into readiness"
grep -Fq 'A validator or test that rejects your change and that no other live lane touches' "$template" &&
    grep -Fq 'may be added to this fence by you ONCE' "$template" ||
    fail "lane-brief template lost the bounded self-expansion clause"
grep -Fq 'For every other out-of-fence edit, append a dated blocker' "$template" ||
    fail "lane-brief template lost the out-of-fence STOP rule"

# The implement skill's base brief template restates the same fence prose, so
# the two are asserted against identical literals: a reworded clause in either
# file fails here rather than drifting until a worker reads two different rules.
impl_template="ai/skills/universal/implement/assets/implementer-brief.md"
for clause in \
    'A validator or test that rejects your change and that no other live lane touches' \
    'may be added to this fence by you ONCE' \
    'For every other out-of-fence edit, append a dated blocker'; do
    grep -Fq "$clause" "$impl_template" ||
        fail "implementer-brief fence prose drifted from the lane template: $clause"
done

test_deps="$(yq -r '.tasks.test.deps[]' Taskfile.yml)"
verify_cmds="$(yq -r '.tasks.verify.cmds[].task' Taskfile.yml)"
grep -Fxq 'test:lane-fences' <<<"$test_deps" || fail "test:lane-fences is not wired into test deps"
if grep -Fxq 'test:lane-fences' <<<"$verify_cmds"; then
    fail "test:lane-fences is duplicated in verify cmds"
fi

# Exercise the token and fail-closed invariants with the earlier attack cases.
(
    fixture="$tmp/plan-scan"
    mkdir -p "$fixture/repo" "$fixture/repo/src" "$fixture/repo/scripts" "$fixture/repo/tests" "$fixture/repo/test" "$fixture/repo/__tests__" "$fixture/repo/app"
    git -C "$fixture/repo" init -q
    cd "$fixture/repo"
    validator="$repo/ai/skills/universal/dev-flow-support/assets/validate-result-schemas.mjs"
    fixture_plan="$repo/ai/schemas/fixtures/plan/valid/interactive.json"
    plan() {
        python3 - "$fixture_plan" "$1" "$2" "$3" <<'PYTHON'
import hashlib, json, sys
with open(sys.argv[1]) as f:
    doc = json.load(f)
r = doc['revisions'][0]
p = r['plan']
p['issues'] = [dict(number=935, title='fixture', url='https://github.com/example/repo/issues/935', verdict='valid', candidate_files=['src/source.sh'], blocked_by=[])]
p['overlaps'] = []
p['waves'] = [dict(number=1, issues=[935])]
p['lanes'] = [dict(lane='one', issue=935, wave=1, branch='fixture', run_id='fixture', fence=json.loads(sys.argv[2]), expansions=[])]
p['policy']['operator_pins'] = json.loads(sys.argv[3])
r['reason'] = sys.argv[4]
doc['revisions'] = [r]
content = {key:r[key] for key in ('seq', 'plan', 'at', 'reason', 'prev_digest')}
r['digest'] = hashlib.sha256(json.dumps(content, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
with open('plan.json', 'w') as f:
    json.dump(doc, f)
PYTHON
        node "$validator" plan plan.json >/dev/null
    }
    # Quoted commands, YAML list/mapping prefixes, and JSONC strings/comments
    # all supply path tokens without needing a syntax-specific parser.
    cat >src/source.sh <<'SOURCE'
"scripts/test-double.sh" 'scripts/test-single.sh'
  - ./scripts/test-list.sh
  - cmd: scripts/test-mapping.sh
{ "url": "https://example.test/a//b", /* scripts/validate-config.sh */
  "value":(scripts/test-value.sh,scripts/test-other.sh) }
SOURCE
    for path in scripts/test-double.sh scripts/test-single.sh scripts/test-list.sh scripts/test-mapping.sh scripts/validate-config.sh scripts/test-value.sh scripts/test-other.sh; do
        printf '%s\n' 'fixture' >"$path"
    done
    # Test naming variants and reverse references use the same token rule.
    for path in tests/ordinary.ts test/ordinary.py __tests__/ordinary.jsx app/widget.test.ts app/widget.spec.js app/test_widget.py app/widget_test.py app/test-widget.cjs; do
        printf '%s\n' 'assert src/source.sh' >"$path"
    done
    git add src scripts tests test __tests__ app
    plan '["src/source.sh"]' '[]' 'initial plan'
    if "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
        echo 'incomplete fence was accepted' >&2
        exit 1
    fi
    for path in scripts/test-double.sh scripts/test-single.sh scripts/test-list.sh scripts/test-mapping.sh scripts/validate-config.sh scripts/test-value.sh scripts/test-other.sh tests/ordinary.ts test/ordinary.py __tests__/ordinary.jsx app/widget.test.ts app/widget.spec.js app/test_widget.py app/widget_test.py app/test-widget.cjs; do
        grep -Fq "missing: $path:" "$fixture/out" || {
            echo "missing discovery: $path" >&2
            exit 1
        }
    done
    plan '["src/source.sh","scripts/*","tests/*","test/*","__tests__/*","app/*"]' '[]' 'complete plan'
    "$scanner" --check-plan plan.json >"$fixture/out"
    "$scanner" src/source.sh >"$fixture/out"
    grep -Fxq scripts/test-list.sh "$fixture/out"
    if "$scanner" --check-plan plan.json --lane missing >"$fixture/out" 2>&1; then
        echo 'unknown lane accepted' >&2
        exit 1
    fi
    # A candidate may be covered by a dated plan waiver.
    omitted="$(git ls-files | python3 -c 'import json,sys; print(json.dumps([p.strip() for p in sys.stdin if p.strip() != "scripts/test-double.sh"]))')"
    plan "$omitted" '[]' 'fence-waiver: one scripts/test-double.sh: accepted'
    "$scanner" --check-plan plan.json >"$fixture/out"
    plan "$omitted" '["fence-waiver: two scripts/test-double.sh: other lane"]' 'lane-scoped waiver'
    if "$scanner" --check-plan plan.json --lane one >"$fixture/out" 2>&1; then
        echo 'another lane waiver accepted' >&2
        exit 1
    fi
    grep -Fq 'missing: scripts/test-double.sh:' "$fixture/out"
    # An undated revision must not activate either source of recorded waivers.
    for waiver_source in pin reason; do
        if [ "$waiver_source" = pin ]; then
            plan "$omitted" '["fence-waiver: one scripts/test-double.sh: accepted"]' 'undated pin'
        else
            plan "$omitted" '[]' 'fence-waiver: one scripts/test-double.sh: accepted'
        fi
        "$scanner" --check-plan plan.json --lane one >"$fixture/out"
        python3 - <<'PYTHON'
import json
with open('plan.json') as f:
    doc = json.load(f)
del doc['revisions'][0]['at']
with open('plan.json', 'w') as f:
    json.dump(doc, f)
PYTHON
        if "$scanner" --check-plan plan.json --lane one >"$fixture/out" 2>&1; then
            echo "undated $waiver_source waiver accepted" >&2
            exit 1
        fi
        grep -Fq 'missing: scripts/test-double.sh:' "$fixture/out"
    done
    # An undated expansion cannot exempt an unreadable planned path.
    plan '["src/source.sh"]' '[]' 'undated expansion'
    python3 - <<'PYTHON'
import json
with open('plan.json') as f:
    doc = json.load(f)
doc['revisions'][0]['plan']['lanes'][0]['expansions'].append(
    {'path': 'src/planned-undated.sh', 'reason': 'planned'})
with open('plan.json', 'w') as f:
    json.dump(doc, f)
PYTHON
    if "$scanner" --check-plan plan.json --lane one >"$fixture/out" 2>&1; then
        echo 'undated expansion accepted' >&2
        exit 1
    fi
    grep -Fq 'incomplete: src/planned-undated.sh:' "$fixture/out"
    # Real consumers include shell-variable paths and unclassified file types.
    printf '%s\n' 'bash "$repo/src/source.sh"' >scripts/test-dollar.sh
    printf '%s\n' "cmds:" "  - './src/source.sh'" '  - cmd: "src/source.sh"' >Taskfile.yml
    mkdir -p .github/workflows bin
    printf '%s\n' 'run: bash src/source.sh' >.github/workflows/ci.yml
    printf '%s\n' 'run: src/source.sh' >lefthook.yml
    printf '%s\n' 'test:' '  bash src/source.sh' >Makefile
    printf '%s\n' 'bash src/source.sh' >bin/check
    printf '%s\n' 'system("src/source.sh")' >scripts/check-source.rb
    printf '%s\n' 'run src/source.sh' >tests/source.bats
    git add scripts/test-dollar.sh Taskfile.yml .github bin lefthook.yml Makefile scripts/check-source.rb tests/source.bats
    plan '["src/source.sh"]' '[]' 'consumer paths'
    if "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
        echo 'consumer references were missed' >&2
        exit 1
    fi
    for path in scripts/test-dollar.sh Taskfile.yml .github/workflows/ci.yml lefthook.yml Makefile bin/check scripts/check-source.rb tests/source.bats; do
        grep -Fq "missing: $path:" "$fixture/out" || {
            echo "missing consumer: $path" >&2
            exit 1
        }
    done
    # A prose glob is not a concrete path token or a consumer edge.
    mkdir -p docs
    printf '%s\n' 'Examples: src/*.sh' >docs/glob-mention.md
    git add docs/glob-mention.md
    plan '["src/source.sh"]' '[]' 'prose glob'
    "$scanner" --check-plan plan.json >"$fixture/out" 2>&1 || true
    if grep -Fq 'missing: docs/glob-mention.md:' "$fixture/out"; then
        echo 'prose glob treated as a consumer' >&2
        exit 1
    fi
    # Forward discovery must not promote an ordinary referenced file to a test.
    printf '%s\n' 'scripts/ordinary.js' >docs-forward.md
    printf '%s\n' 'fixture' >scripts/ordinary.js
    git add docs-forward.md scripts/ordinary.js
    plan '["docs-forward.md"]' '[]' 'forward classification'
    if ! "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
        cat "$fixture/out" >&2
        exit 1
    fi
    if grep -Fq 'scripts/ordinary.js' "$fixture/out"; then
        echo 'ordinary forward reference treated as a test' >&2
        exit 1
    fi
    # Every resolving suffix counts, even when a longer path also matches.
    mkdir -p nested/src
    printf '%s\n' 'fixture' >nested/src/source.sh
    printf '%s\n' 'bash "$repo/nested/src/source.sh"' >scripts/longest.sh
    git add nested/src/source.sh scripts/longest.sh
    plan '["src/source.sh"]' '[]' 'all suffixes'
    if "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
        echo 'shared suffix consumer missed' >&2
        exit 1
    fi
    grep -Fq 'missing: scripts/longest.sh:' "$fixture/out"
    # Non-test modules that name a fenced JSON manifest are consumers too.
    printf '%s\n' '{"entries":[]}' >agent-registry.json
    printf '%s\n' 'readFileSync("agent-registry.json")' >scripts/discover.mjs
    git add agent-registry.json scripts/discover.mjs
    "$scanner" agent-registry.json >"$fixture/positional-expected"
    "$scanner" ./agent-registry.json >"$fixture/out"
    cmp "$fixture/positional-expected" "$fixture/out"
    "$scanner" .//agent-registry.json >"$fixture/out"
    cmp "$fixture/positional-expected" "$fixture/out"
    plan '["agent-registry.json"]' '[]' 'manifest consumer'
    if "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
        echo 'manifest consumer missed' >&2
        exit 1
    fi
    grep -Fq 'missing: scripts/discover.mjs:' "$fixture/out"
    # Live-plan-shaped hub: preserve comment, wiring and genuine reverse edges.
    mkdir -p pin
    printf '%s\n' '# scripts/test-noise.sh' \
        'grep -qF "./scripts/test-wired.sh" "$repo/Taskfile.yml"' >scripts/test-hub.sh
    printf '%s\n' 'fixture' >scripts/test-noise.sh
    printf '%s\n' 'fixture' >scripts/test-wired.sh
    printf '%s\n' 'run: scripts/test-hub.sh' >pin/consumer.yml
    printf '%s\n' 'run: scripts/test-hub.sh' >>Taskfile.yml
    git add scripts/test-hub.sh scripts/test-noise.sh scripts/test-wired.sh pin/consumer.yml Taskfile.yml
    plan '["scripts/test-hub.sh"]' '[]' 'live shaped inventory'
    if "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
        echo 'live shaped inventory unexpectedly complete' >&2
        exit 1
    fi
    [ "$(grep -c ': missing:' "$fixture/out")" -eq 4 ] || {
        cat "$fixture/out" >&2
        exit 1
    }
    for path in Taskfile.yml pin/consumer.yml scripts/test-noise.sh scripts/test-wired.sh; do
        grep -Fq "missing: $path:" "$fixture/out"
    done
    # Shell and Markdown delimiters, and a colon between a key and a path.
    printf '%s\n' 'fixture' >scripts/test-final-dot.sh
    git add scripts/test-final-dot.sh
    printf '%s\n' 'key:scripts/test-double.sh; scripts/test-single.sh|scripts/test-list.sh&scripts/test-other.sh' \
        '`scripts/test-value.sh` <scripts/test-mapping.sh> [scripts/validate-config.sh] scripts/test-final-dot.sh.' >src/delimiters.md
    git add src/delimiters.md
    plan '["src/delimiters.md"]' '[]' 'delimiter fixture'
    if "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
        echo 'punctuated references were missed' >&2
        exit 1
    fi
    for path in scripts/test-double.sh scripts/test-single.sh scripts/test-list.sh scripts/test-other.sh scripts/test-value.sh scripts/test-mapping.sh scripts/validate-config.sh scripts/test-final-dot.sh; do
        grep -Fq "missing: $path:" "$fixture/out" || {
            echo "missing delimiter path: $path" >&2
            exit 1
        }
    done
    plan '["src/future/**"]' '[]' 'empty glob'
    if "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
        echo 'unmatched glob accepted' >&2
        exit 1
    fi
    grep -Fq 'incomplete: src/future/**: glob matches no tracked or fenced path' "$fixture/out"
    plan '["src"]' '[]' 'directory path'
    if "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
        echo 'directory accepted' >&2
        exit 1
    fi
    grep -Fq 'incomplete: src: directory, not a regular file' "$fixture/out"
    if "$scanner" /outside-repository >"$fixture/out" 2>&1; then
        echo 'outside path accepted' >&2
        exit 1
    fi
    grep -Fq 'absolute path outside repository:' "$fixture/out"
    plan '["src/path:planned"]' '[]' 'fence-waiver: one src/path:planned: accepted'
    "$scanner" --check-plan plan.json >"$fixture/out"
    # A waiver removed by the latest revision must stop applying.
    plan '["src/path:planned"]' '[]' 'new revision'
    python3 - <<'PYTHON'
import json
with open('plan.json') as f: doc = json.load(f)
old = dict(doc['revisions'][0], reason='fence-waiver: one src/path:planned: old waiver')
doc['revisions'].insert(0, old)
with open('plan.json', 'w') as f: json.dump(doc, f)
PYTHON
    if "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
        echo 'stale waiver accepted' >&2
        exit 1
    fi
    grep -Fq 'incomplete: src/path:planned:' "$fixture/out"
    # A binary test whose bytes expose a source path is still a candidate.
    printf 'run src/source.sh\000' >scripts/test-binary.sh
    git add scripts/test-binary.sh
    plan '["src/source.sh"]' '[]' 'binary consumer'
    if "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
        echo 'binary consumer was missed' >&2
        exit 1
    fi
    grep -Fq 'missing: scripts/test-binary.sh:' "$fixture/out"
    # A non-UTF-8 consumer can still contain a recognizable path.
    printf 'caf\351 src/source.sh\n' >scripts/latin-consumer.rb
    git add scripts/latin-consumer.rb
    plan '["src/source.sh"]' '[]' 'lossy reverse text'
    if "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
        echo 'non-UTF-8 consumer missed' >&2
        exit 1
    fi
    grep -Fq 'missing: scripts/latin-consumer.rb:' "$fixture/out"
    # Profile-level operator pins cover a missing consumer independently of slate pins.
    plan '["src/source.sh"]' '[]' 'lane profile waiver'
    python3 - <<'PYTHON'
import hashlib, json
with open('plan.json') as f: doc = json.load(f)
r = doc['revisions'][0]
p = r['plan']
profile = dict(p['policy'])
profile['operator_pins'] = ['fence-waiver: one scripts/test-dollar.sh: lane profile accepts omission']
p['lane_profiles'] = [{'lane': 'one', 'policy': profile}]
content = {key:r[key] for key in ('seq', 'plan', 'at', 'reason', 'prev_digest')}
r['digest'] = hashlib.sha256(json.dumps(content, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()
with open('plan.json', 'w') as f: json.dump(doc, f)
PYTHON
    node "$validator" plan plan.json >/dev/null
    "$scanner" --check-plan plan.json >"$fixture/out" 2>&1 || true
    grep -Fq 'covered: scripts/test-dollar.sh:' "$fixture/out"
    # Each supported shell-prefix form resolves independently to an owner sibling.
    mkdir -p forms/schemas
    printf '%s\n' fixture >forms/sibling.sh
    printf '%s\n' fixture >forms/schemas/x.json
    printf '%s\n' 'run "$asset_dir/sibling.sh"' >forms/asset.sh
    printf '%s\n' 'run "$here/sibling.sh"' >forms/here.sh
    printf '%s\n' 'run "$(dirname "$0")/sibling.sh"' >forms/dirname.sh
    printf '%s\n' 'run "${BASH_SOURCE[0]%/*}/sibling.sh"' >forms/bash-source.sh
    printf '%s\n' 'run "${dir}/schemas/x.json"' >forms/schema.sh
    git add forms
    plan '["forms/sibling.sh","forms/schemas/x.json"]' '[]' 'sibling forms'
    if "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
        echo 'sibling forms missed' >&2
        exit 1
    fi
    for path in forms/asset.sh forms/here.sh forms/dirname.sh forms/bash-source.sh forms/schema.sh; do
        grep -Fq "missing: $path:" "$fixture/out" || {
            echo "missing sibling form: $path" >&2
            exit 1
        }
    done
    # The seven previously missed real sibling pairs, represented by tracked fixtures.
    pairs=(
        'ai/skills/universal/dev-flow-support/assets/run-record.mjs|ai/skills/universal/dev-flow-support/assets/test-run-record.sh'
        'ai/skills/universal/implement/assets/record-implementer.sh|ai/skills/universal/implement/assets/test-record-implementer.sh'
        'ai/skills/repo/standardize-repo/assets/render-bundle.sh|ai/skills/repo/standardize-repo/assets/test-render-bundle.sh'
        'ai/skills/repo/standardize-repo/assets/diff-template.sh|ai/skills/repo/standardize-repo/assets/test-render-bundle.sh'
        'scripts/test-git-merge-guard.sh|scripts/test-hooks.sh'
        'ai/skills/universal/track-work/assets/parse-issue-markdown.awk|ai/skills/universal/track-work/assets/parse-issue-markdown.sh'
        'ai/skills/universal/orchestrate/assets/policy-contract.json|ai/skills/universal/orchestrate/assets/consumer-pin-audit.sh'
    )
    for pair in "${pairs[@]}"; do
        source_path="${pair%%|*}"
        consumer_path="${pair#*|}"
        mkdir -p "$(dirname "$source_path")" "$(dirname "$consumer_path")"
        printf '%s\n' fixture >"$source_path"
        printf 'run "$asset_dir/%s"\n' "$(basename "$source_path")" >>"$consumer_path"
    done
    git add ai scripts/test-git-merge-guard.sh scripts/test-hooks.sh
    for pair in "${pairs[@]}"; do
        source_path="${pair%%|*}"
        consumer_path="${pair#*|}"
        plan "[\"$source_path\"]" '[]' 'sibling reference'
        if "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
            echo "sibling consumer missed: $consumer_path" >&2
            exit 1
        fi
        grep -Fq "missing: $consumer_path:" "$fixture/out" || {
            echo "missing sibling: $source_path -> $consumer_path" >&2
            exit 1
        }
    done
    # Every unreadable fenced path is named, even when another is unreadable.
    printf 'PNG\000data' >src/logo.png
    ln -s absent src/dangling.js
    git add src/logo.png src/dangling.js
    plan '["src/logo.png","src/planned.js","src/dangling.js"]' '[]' 'unreadable sources'
    if "$scanner" --check-plan plan.json >"$fixture/out" 2>&1; then
        echo 'unreadable fenced paths were accepted' >&2
        exit 1
    fi
    grep -Fq 'incomplete: src/logo.png: binary or NUL bytes' "$fixture/out"
    grep -Fq 'incomplete: src/planned.js: missing or planned path' "$fixture/out"
    grep -Fq 'incomplete: src/dangling.js: dangling symlink or not a regular file' "$fixture/out"
    plan '["src/logo.png","src/planned.js","src/dangling.js"]' '[]' $'fence-waiver: one src/logo.png: accepted\nfence-waiver: one src/planned.js: accepted\nfence-waiver: one src/dangling.js: accepted'
    "$scanner" --check-plan plan.json >"$fixture/out"
)

echo "lane fences: ok"
