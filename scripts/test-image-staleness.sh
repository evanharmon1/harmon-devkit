#!/usr/bin/env bash
# test-image-staleness.sh — unit-test the image-staleness warning.
#
# The helper's value is entirely in WHEN it speaks. A check that warns on a
# fresh rebuild trains the operator to ignore it, and a check that stays quiet
# on a six-week-old image is the bug the warning exists to fix — so every case
# here asserts silence-or-noise plus a zero exit, never the exact wording.
#
# No container and no image: the helper compares two directories given to it by
# env var, so each case is a pair of throwaway fixture trees. The real defaults
# are exercised in a live container, not here. Run via `task test:image-staleness`.
set -euo pipefail
cd "$(dirname "$0")/.."
helper=".devcontainer/scripts/check-image-staleness.sh"

[ -r "$helper" ] || {
    echo "TEST FAIL: $helper not found" >&2
    exit 1
}

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

tmp_root="$(mktemp -d -t harmon-image-staleness-XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

# run_helper <baked> <checkout> — capture stdout+stderr and the exit code.
# The exit code is captured explicitly because `set -e` here would otherwise
# abort the suite on the very failure a case is trying to report.
out=""
rc=0
run_helper() {
    set +e
    out="$(DEVCONTAINER_BAKED_CONFIG_DIR="$1" DEVCONTAINER_REPO_CONFIG_DIR="$2" bash "$helper" 2>&1)"
    rc=$?
    set -e
}

# fixture <label> — a baked/checkout pair holding the same three files, one of
# them nested, so a case only has to describe how it diverges from clean.
fixture() {
    local root="${tmp_root}/$1"
    if [ -e "$root" ]; then
        echo "TEST BUG: fixture '$1' reused" >&2
        exit 1
    fi
    mkdir -p "$root/baked/claude-hooks" "$root/checkout/claude-hooks"
    local side
    for side in baked checkout; do
        printf 'palette = "x"\n' >"$root/$side/starship.toml"
        printf 'alias k=kubectl\n' >"$root/$side/shell-aliases.sh"
        printf 'echo hook\n' >"$root/$side/claude-hooks/session-start-context.sh"
    done
    printf '%s' "$root"
}

# ---- 1. identical trees: a freshly rebuilt image says nothing ----

echo "==> identical trees produce no output"
root="$(fixture identical)"
run_helper "$root/baked" "$root/checkout"
[ "$rc" -eq 0 ] || fail "identical trees exited ${rc}, not 0"
[ -z "$out" ] || fail "identical trees produced output: ${out}"

# ---- 2. modified + added + removed: all three shapes are drift ----
# A modified file is the obvious one. The other two matter because the config
# set GROWS: a file added to the checkout after the build, and one deleted from
# it, are both "this image was built from a different repo state" — and a
# hardcoded file list would notice neither.

echo "==> a modified, an added, and a removed file are all counted"
root="$(fixture drift)"
printf 'palette = "y"\n' >"$root/checkout/starship.toml"            # modified
printf 'echo new\n' >"$root/checkout/claude-hooks/protect-files.sh" # added since the build
rm "$root/checkout/shell-aliases.sh"                                # removed since the build
run_helper "$root/baked" "$root/checkout"
[ "$rc" -eq 0 ] || fail "drift exited ${rc} — the warning must never break the lifecycle"
[ -n "$out" ] || fail "drift produced no warning at all"
printf '%s\n' "$out" | grep -q 'image is stale: 3 ' ||
    fail "expected a count of 3 in the summary line, got: ${out}"
printf '%s\n' "$out" | grep -q 'rebuild' ||
    fail "the summary line does not name the remedy: ${out}"
for name in starship.toml protect-files.sh shell-aliases.sh; do
    printf '%s\n' "$out" | grep -q "$name" || fail "the drifted file ${name} is not named: ${out}"
done
# Names only, never contents — this output lands in a lifecycle log, and the
# config it compares references tokens, hostnames, and machine paths.
if printf '%s\n' "$out" | grep -q 'palette'; then
    fail "the warning printed file CONTENTS: ${out}"
fi

# ---- 2b. a path that changed TYPE is drift, not silence ----
# diff -q -r reports "File A is a directory while file B is a regular file" —
# a third message form. A parser matching only "Files … differ" and "Only in …"
# reads a type flip as a clean tree: the one wrong answer, a stale image
# reported fresh (challenge-stage finding on the PR that added this helper).

echo "==> a file that became a directory (and vice versa) is counted"
root="$(fixture typeflip)"
rm "$root/checkout/starship.toml"
mkdir "$root/checkout/starship.toml" # file in the image, directory in the checkout
run_helper "$root/baked" "$root/checkout"
[ "$rc" -eq 0 ] || fail "a type flip exited ${rc}, not 0"
[ -n "$out" ] || fail "a type flip was reported as a clean tree"
printf '%s\n' "$out" | grep -q 'image is stale: 1 ' ||
    fail "expected a count of 1 for the type flip, got: ${out}"
printf '%s\n' "$out" | grep -q 'starship.toml' ||
    fail "the type-flipped path is not named: ${out}"

# ---- 2b2. an executable-bit flip alone is drift ----
# diff compares content only; the x bit is invisible to it. The tree bakes
# hook scripts invoked directly from their installed paths, so a mode-only
# change leaves an image behaviorally stale while byte-identical (Codex
# cloud-review finding on this PR).

echo "==> a chmod-only change is counted as drift"
root="$(fixture xbit)"
chmod +x "$root/baked/starship.toml" # x in the image, not in the checkout
run_helper "$root/baked" "$root/checkout"
[ "$rc" -eq 0 ] || fail "an x-bit flip exited ${rc}, not 0"
[ -n "$out" ] || fail "an x-bit flip was reported as a clean tree"
printf '%s\n' "$out" | grep -q 'image is stale: 1 ' ||
    fail "expected a count of 1 for the x-bit flip, got: ${out}"
printf '%s\n' "$out" | grep -q 'starship.toml (executable bit)' ||
    fail "the x-bit-flipped path is not named with its reason: ${out}"

# ---- 2b3. content + mode changing together is ONE drifted config ----
# The diff pass counts the content change; the x-bit pass must not count the
# same path again, or the summary claims two configs for one file.

echo "==> a file changing both content and x bit is counted once"
root="$(fixture bothdims)"
printf 'palette = "z"\n' >"$root/checkout/starship.toml"
chmod +x "$root/checkout/starship.toml"
run_helper "$root/baked" "$root/checkout"
printf '%s\n' "$out" | grep -q 'image is stale: 1 ' ||
    fail "content+mode on one file must count once, got: ${out}"
[ "$(printf '%s\n' "$out" | grep -c 'starship.toml')" -eq 1 ] ||
    fail "the path is listed more than once: ${out}"

# ---- 2b4. a filename containing \" and \" is named intact ----
# The "Files A and B differ" parse must anchor on the known roots, not the
# first " and " — which can legally occur inside a filename.

echo "==> a filename containing ' and ' survives the parse"
root="$(fixture andname)"
printf 'a\n' >"$root/baked/settings and hooks.json"
printf 'b\n' >"$root/checkout/settings and hooks.json"
run_helper "$root/baked" "$root/checkout"
printf '%s\n' "$out" | grep -qF 'settings and hooks.json' ||
    fail "the ' and '-bearing filename was truncated: ${out}"

# ---- 2c. a broken comparison is indeterminate, never fresh ----
# A dangling symlink (or any unreadable entry) makes diff exit 2 with only
# stderr diagnostics. Discarding that used to leave count=0 and report a
# possibly-stale image as clean — the helper's one forbidden answer. It must
# say something (indeterminate), and still exit 0 (Codex cloud-review finding
# on the PR that added this helper; same class as the deferred symlink P2).

echo "==> a dangling symlink makes the check speak, not report fresh"
root="$(fixture dangling)"
# The same dangling link on BOTH sides: one-sided would be an ordinary
# "Only in" drift line. Two-sided, diff follows both, cannot read either
# target, and exits 2 with nothing but stderr — the silent false-fresh path.
ln -s /nonexistent-target-harmon-test "$root/baked/dangling-link"
ln -s /nonexistent-target-harmon-test "$root/checkout/dangling-link"
run_helper "$root/baked" "$root/checkout"
[ "$rc" -eq 0 ] || fail "a dangling symlink exited ${rc} — warn-only means exit 0 even when indeterminate"
[ -n "$out" ] || fail "a broken comparison was reported as a clean tree"
printf '%s\n' "$out" | grep -qi 'indeterminate' ||
    fail "a broken comparison did not announce itself as indeterminate: ${out}"

# ---- 3. no baked directory: absence is not staleness ----
# True outside the container and in an image built without this convention.
# Warning there would be noise nobody can act on.

echo "==> a missing baked directory is silent, not a warning"
root="$(fixture nobaked)"
rm -rf "$root/baked"
run_helper "$root/baked" "$root/checkout"
[ "$rc" -eq 0 ] || fail "a missing baked directory exited ${rc}, not 0"
[ -z "$out" ] || fail "a missing baked directory produced output: ${out}"

echo "==> a missing checkout directory is silent too"
root="$(fixture nocheckout)"
rm -rf "$root/checkout"
run_helper "$root/baked" "$root/checkout"
[ "$rc" -eq 0 ] || fail "a missing checkout directory exited ${rc}, not 0"
[ -z "$out" ] || fail "a missing checkout directory produced output: ${out}"

echo "image-staleness: all cases passed"
