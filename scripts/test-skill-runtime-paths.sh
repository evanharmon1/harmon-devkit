#!/usr/bin/env bash
# test-skill-runtime-paths.sh — unit tests for check-skill-runtime-paths.sh,
# the harmon-devkit#974 guard that keeps a vendored skill from depending on a
# repository-root `scripts/` path the skills sync does not ship.
#
# Hermetic: every case builds a throwaway skill tree under a temp directory and
# points the guard at it with its optional root argument, so nothing here reads
# or writes the real `ai/skills/`. The default-root case goes one further and
# builds a throwaway git checkout, because the default roots are resolved
# against the repository top level and cannot be redirected by an argument. The
# last section additionally asserts the guard passes on the real tree — a guard
# that only ever sees synthetic input proves nothing about the repository it
# gates.
#
# Run via `task test:skill-runtime-paths`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"
GUARD="$repo/scripts/check-skill-runtime-paths.sh"

tmp="$(mktemp -d -t skill-runtime-paths-XXXXXX)"
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
# Both reporters end with an explicit `return 0`: their last statement is an
# arithmetic assignment, whose status would otherwise become the reporter's own
# and be read as the assertion's result by any caller that chained one.
ok() {
    echo "  ✓ $*"
    pass=$((pass + 1))
    return 0
}
bad() {
    echo "  ✗ $*" >&2
    fail=$((fail + 1))
    return 0
}

# make_tree NAME — a fresh skill root, printed on stdout.
make_tree() {
    local root="$tmp/$1"
    mkdir -p "$root/universal/demo/assets"
    printf '%s\n' '---' 'name: demo' 'description: demo' '---' >"$root/universal/demo/SKILL.md"
    printf '%s\n' "$root"
}

# expect_reject DESC ROOT NEEDLE — the guard must exit non-zero AND say why.
# A rejection that fires for an unrelated reason is a passing test that proves
# nothing, so the diagnostic is asserted too.
expect_reject() {
    local desc=$1 root=$2 needle=$3 out rc=0
    out="$("$GUARD" "$root" 2>&1)" || rc=$?
    if [ "$rc" -eq 0 ]; then
        bad "$desc (guard accepted it)"
        sed 's/^/      /' <<<"$out" >&2
    elif ! grep -qF -- "$needle" <<<"$out"; then
        bad "$desc (rejected, but not for the expected reason: missing '$needle')"
        sed 's/^/      /' <<<"$out" >&2
    else
        ok "$desc"
    fi
}

expect_accept() {
    local desc=$1 root=$2 out rc=0
    out="$("$GUARD" "$root" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        bad "$desc (guard rejected it)"
        sed 's/^/      /' <<<"$out" >&2
    else
        ok "$desc"
    fi
}

echo "==> invocation shapes are rejected"

# The five shapes the guard names, one case each. Each is written the way a
# real regression would arrive: somebody moves a runtime back to scripts/, or
# adds a new skill that reaches for one.
root="$(make_tree relative-command)"
printf '#!/usr/bin/env bash\n./scripts/devflow-policy.mjs resolve\n' >"$root/universal/demo/assets/run.sh"
expect_reject "a command-position ./scripts/<x> is rejected" "$root" "assets/run.sh"

root="$(make_tree interpreter)"
printf '#!/usr/bin/env bash\nnode scripts/render-dev-flow.mjs --help\n' >"$root/universal/demo/assets/run.sh"
expect_reject "an interpreter handed scripts/<x> is rejected" "$root" "assets/run.sh"

root="$(make_tree variable-rooted)"
printf '#!/usr/bin/env bash\nr="$(git rev-parse --show-toplevel)"\nexec "$r"/scripts/dev-flow-exit.sh "$@"\n' \
    >"$root/universal/demo/assets/run.sh"
expect_reject "a variable-rooted \$root/scripts/<x> is rejected" "$root" "assets/run.sh"

root="$(make_tree command-substitution-rooted)"
printf '#!/usr/bin/env bash\nexec "$(git rev-parse --show-toplevel)/scripts/dev-flow-exit.sh" "$@"\n' \
    >"$root/universal/demo/assets/run.sh"
expect_reject "a command-substitution-rooted \$(git rev-parse ...)/scripts/<x> is rejected" \
    "$root" "assets/run.sh"

root="$(make_tree dot-segment-rooted)"
printf '#!/usr/bin/env bash\nexec "$repo/./scripts/dev-flow-exit.sh" "$@"\n' \
    >"$root/universal/demo/assets/run.sh"
expect_reject "a variable root with an intervening ./ segment is rejected" \
    "$root" "assets/run.sh"

root="$(make_tree esm-import)"
printf "import { x } from '../../scripts/lib-helper.mjs'\n" >"$root/universal/demo/assets/run.mjs"
expect_reject "an ES-module import of a scripts/ path is rejected" "$root" "assets/run.mjs"

root="$(make_tree md-link)"
printf 'See [the reader](scripts/devflow-policy.mjs) for details.\n' >"$root/universal/demo/SKILL.md"
expect_reject "a Markdown link to a scripts/ path is rejected" "$root" "SKILL.md"

root="$(make_tree parent-relative)"
printf '#!/usr/bin/env bash\nbash ../../../scripts/consumer-pin-audit.sh\n' >"$root/universal/demo/assets/run.sh"
expect_reject "a ../-prefixed scripts/ invocation is rejected" "$root" "assets/run.sh"

echo "==> non-invocation references are accepted"

root="$(make_tree prose)"
cat >"$root/universal/demo/SKILL.md" <<'MD'
---
name: demo
description: demo
---
The repository's own scripts/lint-hygiene.sh is the hygiene check, and
scripts/status.sh reports state. Neither is this skill's runtime.
MD
expect_accept "prose naming a root scripts/ file is accepted" "$root"

root="$(make_tree bare-literal)"
printf '#!/usr/bin/env bash\nverify_member "$given" "scripts/gitleaks-scan.sh"\n' \
    >"$root/universal/demo/assets/run.sh"
expect_accept "a bare quoted scripts/ literal (a canonical path argument) is accepted" "$root"

root="$(make_tree sibling-asset)"
printf '#!/usr/bin/env bash\nd="$(cd "$(dirname "$0")" && pwd -P)"\nexec "$d/../../dev-flow-support/assets/dev-flow-exit.sh" "$@"\n' \
    >"$root/universal/demo/assets/run.sh"
expect_accept "the sanctioned sibling-package form is accepted" "$root"

root="$(make_tree empty)"
expect_accept "a skill tree with no scripts/ reference at all is accepted" "$root"

expect_accept "a missing skills root is a no-op, not a failure" "$tmp/does-not-exist"

echo "==> allowlist behaviour"

# A stale entry must fail: the exemptions are only trustworthy while every one
# of them is still suppressing something. Driven through the test-only
# allowlist override, because the shipped list is (correctly) never stale.
root="$(make_tree stale-allowlist)"
printf '#!/usr/bin/env bash\nnode scripts/devflow-policy.mjs resolve\n' \
    >"$root/universal/demo/assets/run.sh"
stale_entry="$(printf 'file\t%s/universal/demo/assets/run.sh\tscripts/not-referenced.sh\tdeliberately matches nothing' "$root")"
# Set and unset around the assertion rather than wrapping it in a `( ... )`
# subshell: `bad()` increments `fail` and a subshell would discard that
# increment, leaving a suite that prints its diagnostic and still exits 0. A
# `VAR=value expect_reject ...` env prefix is not the fix either — bash keeps
# the assignment in the shell after a FUNCTION call, so it would leak into the
# real-tree cases below.
export SKILL_RUNTIME_PATHS_ALLOWLIST="$stale_entry"
expect_reject "an allowlist entry that suppresses nothing is itself a failure" \
    "$root" "suppressed nothing and is stale"
unset SKILL_RUNTIME_PATHS_ALLOWLIST

# ...and an override that DOES suppress the only finding lets the tree pass,
# which is what makes the previous case a test of staleness rather than of the
# finding underneath it.
live_entry="$(printf 'file\t%s/universal/demo/assets/run.sh\tscripts/devflow-policy.mjs\tcovers the seeded finding' "$root")"
export SKILL_RUNTIME_PATHS_ALLOWLIST="$live_entry"
expect_accept "an allowlist entry that does suppress its finding is accepted" "$root"
unset SKILL_RUNTIME_PATHS_ALLOWLIST

# The override must be impossible to mistake for a clean gated run.
root="$(make_tree override-warning)"
override_out="$(SKILL_RUNTIME_PATHS_ALLOWLIST="$(printf 'dir\t%s\tanything' "$root")" \
    "$GUARD" "$root" 2>&1 || true)"
if grep -qF 'allowlist overridden by SKILL_RUNTIME_PATHS_ALLOWLIST' <<<"$override_out"; then
    ok "an overridden allowlist announces itself on stderr"
else
    bad "an overridden allowlist ran silently"
fi

# A real entry is not reported stale merely because a synthetic scan never
# visited its path — otherwise the guard could not be run against any tree but
# its own, which is how the staleness check first broke this test suite.
root="$(make_tree out-of-scope-entries)"
expect_accept "shipped entries outside the scanned root are not reported stale" "$root"

echo "==> vendored agents are scanned too"

# `task sync:skills` ships ai/agents/ as well as ai/skills/, so an agent that
# named a repository-root runtime would install into a consumer exactly as
# unrunnably as a skill would. Two things are asserted: the shape rule fires on
# an agent file, and ai/agents is in the DEFAULT root set — the second needs a
# throwaway checkout, because the default roots resolve against the repository
# top level and no argument can redirect them.
agents_root="$tmp/agents-tree"
mkdir -p "$agents_root"
printf '%s\n' '---' 'name: demo' 'description: demo' '---' \
    'Run `bash scripts/dev-flow-exit.sh --help` before reporting.' >"$agents_root/demo.md"
expect_reject "an offending invocation in an agent .md is rejected" "$agents_root" "demo.md"

default_root_repo="$tmp/default-roots"
mkdir -p "$default_root_repo/ai/agents"
git -C "$default_root_repo" init -q
printf '%s\n' '---' 'name: demo' 'description: demo' '---' \
    'Run `bash scripts/dev-flow-exit.sh --help` before reporting.' \
    >"$default_root_repo/ai/agents/demo.md"
default_rc=0
default_out="$(cd "$default_root_repo" && "$GUARD" 2>&1)" || default_rc=$?
if [ "$default_rc" -ne 0 ] && grep -qF 'ai/agents/demo.md' <<<"$default_out"; then
    ok "ai/agents is scanned with no root argument (the default validate: target)"
else
    bad "ai/agents is not covered by the default scanned roots"
    sed 's/^/      /' <<<"$default_out" >&2
fi

echo "==> the real tree"

expect_accept "ai/skills passes the guard as committed" "ai/skills"
expect_accept "ai/agents passes the guard as committed" "ai/agents"

# No argument at all — exactly what `task validate:skill-runtime-paths` runs.
real_default_rc=0
real_default_out="$("$GUARD" 2>&1)" || real_default_rc=$?
if [ "$real_default_rc" -eq 0 ] &&
    grep -qF 'ai/skills ai/agents' <<<"$real_default_out"; then
    ok "the default roots are ai/skills and ai/agents, and both pass as committed"
else
    bad "the default-root run did not scan both trees cleanly"
    sed 's/^/      /' <<<"$real_default_out" >&2
fi

# The guard must be load-bearing on the real tree too: reintroduce the exact
# dependency #974 removed, in the file that used to carry it, and require the
# guard to catch it. A guard that passes because nothing under ai/skills has
# the shape any more would pass just as happily if the shape rule were broken.
probe="$tmp/real-tree-probe"
cp -r ai/skills "$probe"
printf '\nnode scripts/devflow-policy.mjs resolve --policy .devflow.toml\n' \
    >>"$probe/universal/review/assets/round-push.sh"
expect_reject "a reintroduced root-runtime invocation in review/assets is caught" \
    "$probe" "universal/review/assets/round-push.sh"

echo
if [ "$fail" -ne 0 ]; then
    echo "FAIL: $fail failed, $pass passed" >&2
    exit 1
fi
echo "PASS: $pass assertions"
