#!/usr/bin/env bash
# test-independence.sh — unit tests for verify-independence.sh, the guard that
# keeps shipped output free of the maintainer's personal dotfiles repo.
# Hermetic and offline: builds throwaway git repos in temp dirs and drives the
# real script against them. Run via `task test:independence`.
#
# Why fixtures at all: `task validate:independence` only ever runs the guard
# against a clean checkout, where the expected answer is "OK". Every rejection
# path could be replaced with a no-op and CI would stay green. These tests are
# what make the guard's failures load-bearing rather than assumed.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
GUARD="$repo/scripts/verify-independence.sh"

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

pass=0
fail=0
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*"
}
bad() {
    fail=$((fail + 1))
    echo "  ✗ $*" >&2
}

# newrepo NAME — a throwaway repo with all four scanned trees present and a
# copy of the guard at the path the guard exempts, so the fixture mirrors the
# real layout (including the self-exemption) rather than a stripped-down one.
newrepo() {
    local dir="$TMPROOT/$1"
    mkdir -p "$dir"/{ai,templates,scripts,snippets}
    git -C "$dir" init -q .
    git -C "$dir" config user.email test@example.com
    git -C "$dir" config user.name Test
    cp "$GUARD" "$dir/scripts/verify-independence.sh"
    printf 'placeholder\n' >"$dir/ai/.gitkeep"
    printf '%s\n' "$dir"
}

guard() { (cd "$1" && bash ./scripts/verify-independence.sh); }

expect_ok() {
    local desc="$1" dir="$2" output
    if output="$(guard "$dir" 2>&1)"; then
        ok "$desc"
    else
        bad "$desc (expected exit 0)"
        printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
}

# Succeed iff the guard exits non-zero AND names the offending path — a
# rejection that fires for an unrelated reason is a passing test that proves
# nothing.
expect_fail_contains() {
    local desc="$1" dir="$2" needle="$3" output
    if output="$(guard "$dir" 2>&1)"; then
        bad "$desc (expected non-zero exit)"
        printf '%s\n' "$output" | sed 's/^/      /' >&2
    elif printf '%s\n' "$output" | grep -qF "$needle"; then
        ok "$desc"
    else
        bad "$desc (rejected, but not for the expected reason: missing '$needle')"
        printf '%s\n' "$output" | sed 's/^/      /' >&2
    fi
}

echo "verify-independence: acceptance"

d="$(newrepo clean)"
printf 'ordinary guidance about your own dotfiles setup\n' >"$d/ai/notes.md"
expect_ok "a clean tree passes" "$d"

# The rule bans the personal repo and hardcoded checkout paths, NOT the
# technique — standardize-repo carries real chezmoi guidance on purpose.
d="$(newrepo chezmoi)"
cat >"$d/ai/chezmoi-guidance.md" <<'EOF'
Add generated files to `.chezmoiignore` and verify with `chezmoi status`.
The `private_`/`dot_` prefixes and `{{ .chezmoi.* }}` templates are fine.
EOF
expect_ok "chezmoi technique guidance passes" "$d"

d="$(newrepo self)"
expect_ok "the guard exempts only its own source" "$d"

# Near-misses: ordinary filenames that merely start with the same characters
# are not a personal checkout, and rejecting them would fail text that breaks
# no invariant.
d="$(newrepo near-miss)"
printf 'x\n' >"$d/ai/.dotfiles.example"
printf 'x\n' >"$d/ai/.dotfiles.json"
printf 'see .dotfiles.bak for the old copy\n' >"$d/ai/notes.md"
expect_ok "dotted near-miss names pass" "$d"

d="$(newrepo innocuous-link)"
ln -s ../templates "$d/ai/link"
expect_ok "an innocuous symlink passes" "$d"

echo "verify-independence: rejection"

d="$(newrepo name)"
printf 'see harmon-dotfiles ADR 0002\n' >"$d/ai/skill.md"
expect_fail_contains "the repo name in content is rejected" "$d" "ai/skill.md"

d="$(newrepo homepath)"
printf 'source ~/.dotfiles/.functions\n' >"$d/templates/setup.sh"
expect_fail_contains "a ~/.dotfiles path is rejected" "$d" "templates/setup.sh"

d="$(newrepo relpath)"
printf '.dotfiles/private/config\n' >"$d/templates/notes.md"
expect_fail_contains "a leading .dotfiles/ path is rejected" "$d" "templates/notes.md"

d="$(newrepo pathname)"
mkdir -p "$d/ai/example/.dotfiles"
printf 'clean content\n' >"$d/ai/example/.dotfiles/config"
expect_fail_contains "a .dotfiles path component is rejected" "$d" ".dotfiles/config"

d="$(newrepo symlink)"
ln -s /home/someone/.dotfiles/tool "$d/snippets/tool"
expect_fail_contains "a symlink into a dotfiles tree is rejected" "$d" "snippets/tool"

d="$(newrepo binary)"
printf 'prefix\000harmon-dotfiles/config\000tail\n' >"$d/ai/payload.bin"
expect_fail_contains "a NUL-containing binary payload is rejected" "$d" "ai/payload.bin"

# The compiled-AppleScript case: UTF-16 stores the path as `.\0d\0o\0t\0…`, so
# an ASCII pattern never sees it contiguously. Written as bytes rather than
# built with osacompile so the test stays hermetic and runs off macOS.
d="$(newrepo utf16)"
printf '\376\377' >"$d/scripts/compiled.scpt"
printf '/\000U\000s\000e\000r\000s\000/\000x\000/\000.\000d\000o\000t\000f\000i\000l\000e\000s\000/\000c\000\n' \
    >>"$d/scripts/compiled.scpt"
expect_fail_contains "a UTF-16 path in a compiled asset is rejected" "$d" "scripts/compiled.scpt"

# A match near the front followed by more than a pipe buffer of data. With
# `grep -q` in the decode pipeline this passed: grep exited on the match, `tr`
# took SIGPIPE, and pipefail reported 141 — a found violation reported clean.
# 2 MiB is comfortably past any pipe buffer while keeping the test quick.
d="$(newrepo large-binary)"
{
    printf '\000h\000a\000r\000m\000o\000n\000-\000d\000o\000t\000f\000i\000l\000e\000s\000/\000c\000\n'
    head -c 2097152 /dev/zero | tr '\000' 'A'
} >"$d/ai/large.bin"
expect_fail_contains "a large NUL-padded binary is rejected" "$d" "large.bin references"

d="$(newrepo large-binary-staged)"
{
    printf '\000h\000a\000r\000m\000o\000n\000-\000d\000o\000t\000f\000i\000l\000e\000s\000/\000c\000\n'
    head -c 2097152 /dev/zero | tr '\000' 'A'
} >"$d/ai/large.bin"
git -C "$d" add ai/large.bin
rm "$d/ai/large.bin"
expect_fail_contains "a large staged binary is rejected" "$d" "STAGED copy references"

echo "verify-independence: index vs worktree"

# The core staged case: violation staged, worktree copy then cleaned without
# re-staging. The commit would record the offending blob.
d="$(newrepo staged)"
printf 'see harmon-dotfiles ADR 0002\n' >"$d/ai/skill.md"
git -C "$d" add ai/skill.md
printf 'clean text\n' >"$d/ai/skill.md"
expect_fail_contains "a staged-only violation is rejected" "$d" "STAGED"

# git grep skips symlink entries, so this one needs the index-mode read.
d="$(newrepo staged-link)"
ln -s /home/someone/.dotfiles/tool "$d/ai/tool"
git -C "$d" add ai/tool
rm "$d/ai/tool"
printf 'clean\n' >"$d/ai/tool"
expect_fail_contains "a staged symlink with a clean worktree copy is rejected" "$d" "STAGED symlink"

# A gitlink has no blob to scan and an uninitialized submodule is an empty
# directory locally, while `--recurse-submodules` hands a consumer whatever it
# points at. Staged with update-index rather than `git submodule add` so the
# fixture needs no second repo and no protocol.file.allow.
d="$(newrepo gitlink)"
sha="$(git -C "$d" hash-object -w /dev/null)"
git -C "$d" update-index --add --cacheinfo "160000,${sha},ai/vendored"
expect_fail_contains "a submodule gitlink is rejected" "$d" "ai/vendored"

d="$(newrepo ignored)"
printf 'node_modules/\n' >"$d/.gitignore"
mkdir -p "$d/templates/node_modules"
printf 'harmon-dotfiles\n' >"$d/templates/node_modules/dep.js"
expect_ok "a git-ignored file is not scanned" "$d"

echo "verify-independence: structure"

# Fail closed when the file list cannot be produced. A process substitution's
# exit status belongs to the substitution, not the loop, so an unchecked
# enumeration failure would hand the loop zero entries and the guard would
# report independence having scanned nothing.
d="$(newrepo corrupt-index)"
printf 'garbage-not-an-index' >"$d/.git/index"
expect_fail_contains "an unreadable index fails the guard" "$d" "could not enumerate"

d="$(newrepo missing-target)"
rm -rf "$d/snippets"
expect_fail_contains "a missing scan target is rejected" "$d" "missing"

echo
echo "independence guard tests: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
