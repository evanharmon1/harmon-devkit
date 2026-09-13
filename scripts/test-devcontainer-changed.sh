#!/usr/bin/env bash
# test-devcontainer-changed.sh — regression for the devcontainer change
# detector.
#
# Every case here is a way the required `devcontainer-verify` check could go
# wrong: a false `false` skips validation on a real devcontainer change, and
# a detector that errors out wedges the check entirely.
set -euo pipefail

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$repo_root/scripts/devcontainer-changed.sh"

tmp="$(mktemp -d -t test-devcontainer-changed-XXXXXX)"
cleanup() {
    cd "$repo_root" 2>/dev/null || true
    cleanup_attempt=0
    while [ -e "$tmp" ] && [ "$cleanup_attempt" -lt 3 ]; do
        rm -rf "$tmp" >/dev/null 2>&1 || true
        cleanup_attempt=$((cleanup_attempt + 1))
        if [ -e "$tmp" ] && [ "$cleanup_attempt" -lt 3 ]; then
            sleep 1
        fi
    done

    if [ -e "$tmp" ]; then
        echo "test-devcontainer-changed: cleanup left $tmp after ${cleanup_attempt} attempts" >&2
    fi
    return 0
}

on_exit() {
    status=$?
    trap - EXIT HUP INT TERM
    cleanup
    exit "$status"
}

on_signal() {
    status=$1
    trap - EXIT HUP INT TERM
    cleanup
    exit "$status"
}

trap on_exit EXIT
trap 'on_signal 129' HUP
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

repo="$tmp/repo"
mkdir -p "$repo/.devcontainer" "$repo/src" "$repo/.github/workflows" "$repo/scripts"
cd "$repo"
git init -q .
git config user.email test@example.com
git config user.name Test
# The fixture must not leave background maintenance writing objects while its
# temporary directory is being removed.
git config maintenance.auto false
git config gc.auto 0
git config gc.autoDetach false

printf '%s\n' 'FROM scratch' >.devcontainer/Dockerfile
printf '%s\n' 'x' >src/app.js
printf '%s\n' 'name: Devcontainer Build' >.github/workflows/devcontainer-build.yml
printf '%s\n' '#!/usr/bin/env bash' >scripts/verify-ci-results.sh
printf '%s\n' '#!/usr/bin/env bash' >scripts/devcontainer-assert.sh
printf '%s\n' '#!/usr/bin/env bash' >scripts/devcontainer-smoke.sh
git add -A
git commit -qm base
base="$(git rev-parse HEAD)"

# ── an unrelated change is a no-op ──────────────────────────────────
printf '%s\n' 'y' >src/app.js
git commit -qam "unrelated"
[ "$("$helper" "$base" HEAD)" = false ] ||
    fail "a change touching only src/ was reported as a devcontainer change"

# ── a .devcontainer/ change counts ──────────────────────────────────
prev="$(git rev-parse HEAD)"
printf '%s\n' 'FROM ghcr.io/evanharmon1/harmon-devcontainer:pinned' >.devcontainer/Dockerfile
git commit -qam "devcontainer"
[ "$("$helper" "$prev" HEAD)" = true ] ||
    fail "a change under .devcontainer/ was not detected"

# ── a nested .devcontainer/ change counts ───────────────────────────
prev="$(git rev-parse HEAD)"
mkdir -p .devcontainer/dev
printf '%s\n' '{}' >.devcontainer/dev/devcontainer.json
git add -A
git commit -qm "nested"
[ "$("$helper" "$prev" HEAD)" = true ] ||
    fail "a change under .devcontainer/dev/ was not detected"

# ── editing the workflow counts: it decides how the container is built ──
prev="$(git rev-parse HEAD)"
printf '%s\n' '# edited' >>.github/workflows/devcontainer-build.yml
git commit -qam "workflow"
[ "$("$helper" "$prev" HEAD)" = true ] ||
    fail "a change to the devcontainer-build.yml workflow itself was not detected"

# ── each watched script counts ──────────────────────────────────────
for script in verify-ci-results devcontainer-assert devcontainer-smoke; do
    prev="$(git rev-parse HEAD)"
    printf '%s\n' '# edited' >>"scripts/${script}.sh"
    git commit -qam "edit ${script}"
    [ "$("$helper" "$prev" HEAD)" = true ] ||
        fail "a change to scripts/${script}.sh was not detected"
done

# ── the detector script itself counts (it decides its own coverage) ─────
prev="$(git rev-parse HEAD)"
printf '%s\n' '#!/usr/bin/env bash' >scripts/devcontainer-changed.sh
git add -A
git commit -qm "add detector"
[ "$("$helper" "$prev" HEAD)" = true ] ||
    fail "a change to scripts/devcontainer-changed.sh itself was not detected"

# ── a path that merely starts with the same letters does NOT ────────
# `.devcontainer-notes.md` must not match the `.devcontainer/` prefix.
prev="$(git rev-parse HEAD)"
printf '%s\n' 'notes' >.devcontainer-notes.md
git add -A
git commit -qm "lookalike"
[ "$("$helper" "$prev" HEAD)" = false ] ||
    fail "a path merely prefixed '.devcontainer' was treated as a devcontainer change"

# ── moving a file OUT of .devcontainer/ counts ──────────────────────
# Rename detection reports only the DESTINATION path, so moving a file out of
# .devcontainer/ can hide the fact that .devcontainer/ lost it. Only
# `--no-renames` makes the source side visible. The moved file is
# deliberately NOT matched by any other rule at its destination, so this
# case would pass with --no-renames reverted and prove nothing.
prev="$(git rev-parse HEAD)"
mkdir -p .devcontainer/config docs
printf '%s\n' 'asset content' >.devcontainer/config/asset.txt
git add -A
git commit -qm "add config asset"
prev="$(git rev-parse HEAD)"
git mv .devcontainer/config/asset.txt docs/asset.txt
git commit -qm "move out"
[ "$("$helper" "$prev" HEAD)" = true ] ||
    fail "moving a file OUT of .devcontainer/ was not detected (rename hid the source path)"
git mv docs/asset.txt .devcontainer/config/asset.txt
git commit -qm "move back"

# ── deletions count as changes ───────────────────────────────────────
prev="$(git rev-parse HEAD)"
git rm -q .devcontainer/dev/devcontainer.json
git commit -qm "delete"
[ "$("$helper" "$prev" HEAD)" = true ] ||
    fail "deleting a devcontainer file was not detected"

# ── a match early in a large diff is still detected ──────────────────
# Regression for a `grep -q` pipeline under `set -o pipefail`: grep -q can
# exit successfully as soon as it finds a match, before printf finishes
# writing the rest of a large changed-file list; printf's own SIGPIPE from
# that early exit then made pipefail report the whole pipeline as failed,
# masking a real match. `.devcontainer/Dockerfile` sorts first here, well
# ahead of enough trailing filenames to make that race matter.
prev="$(git rev-parse HEAD)"
printf 'FROM scratch\n# touched\n' >.devcontainer/Dockerfile
mkdir -p unrelated
i=0
while [ "$i" -lt 5000 ]; do
    printf 'noise %s\n' "$i" >"unrelated/file-${i}.txt"
    i=$((i + 1))
done
git add -A
git commit -qm "devcontainer change followed by a large unrelated tail"
[ "$("$helper" "$prev" HEAD)" = true ] ||
    fail "a devcontainer change early in a large diff was not detected (grep -q/pipefail race)"
rm -rf unrelated
git add -A
git commit -qm "remove unrelated noise files"

# ── a non-ASCII devcontainer path is still detected ───────────────────
# Regression for git's default core.quotePath=true, which C-quotes any path
# containing a non-ASCII byte (".devcontainer/café" becomes the literal
# string ".devcontainer/caf\303\251" wrapped in double quotes) — the anchored
# matcher would never recognize that quoted form as living under
# .devcontainer/ at all.
prev="$(git rev-parse HEAD)"
printf 'unicode path content\n' >".devcontainer/café.txt"
git add -A
git commit -qm "add a non-ASCII devcontainer path"
[ "$("$helper" "$prev" HEAD)" = true ] ||
    fail "a non-ASCII devcontainer path was not detected (git core.quotePath)"

# ── a devcontainer path containing a tab is still detected ───────────
# Regression for the same C-quoting, on a byte core.quotePath=false does NOT
# stop git from quoting: a literal tab, newline, quote, or backslash in a
# path is always quoted regardless of that setting. Only -z's NUL-delimited,
# unquoted output handles this (and the non-ASCII case above) correctly.
prev="$(git rev-parse HEAD)"
printf 'tab path content\n' >"$(printf '.devcontainer/a\tb')"
git add -A
git commit -qm "add a devcontainer path containing a tab"
[ "$("$helper" "$prev" HEAD)" = true ] ||
    fail "a devcontainer path containing a tab was not detected (git quoting)"

# ── fail-safe: unusable input must answer true, never false ─────────
[ "$("$helper" "" HEAD 2>/dev/null)" = true ] ||
    fail "an empty base must fail safe to changed=true"
[ "$("$helper" 0000000000000000000000000000000000000000 HEAD 2>/dev/null)" = true ] ||
    fail "an all-zero base (branch creation) must fail safe to changed=true"
[ "$("$helper" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef HEAD 2>/dev/null)" = true ] ||
    fail "a base missing from the clone must fail safe to changed=true"
[ "$("$helper" "$base" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef 2>/dev/null)" = true ] ||
    fail "a head missing from the clone must fail safe to changed=true"

# ── the workflow reads this from $GITHUB_OUTPUT, not stdout ─────────
out="$tmp/gh-output"
: >"$out"
GITHUB_OUTPUT="$out" "$helper" "$base" HEAD >/dev/null
grep -q '^changed=true$' "$out" ||
    fail "changed= was not written to \$GITHUB_OUTPUT"

echo "Devcontainer change-detection regression: PASS"
