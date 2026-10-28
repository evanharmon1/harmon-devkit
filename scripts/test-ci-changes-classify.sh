#!/usr/bin/env bash
# Real git trees exercise the skip boundary, including the stale-base revert.
set -euo pipefail
# Fixture commits must not inherit host signing, hooks or injected Git config.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
git_config_count="${GIT_CONFIG_COUNT:-0}"
case "$git_config_count" in
'' | *[!0-9]*) git_config_count=0 ;;
esac
i=0
while [ "$i" -lt "$git_config_count" ]; do
    unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i"
    i=$((i + 1))
done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_ALTERNATE_OBJECT_DIRECTORIES
repo="$(cd "$(dirname "$0")/.." && pwd)"
classifier="$repo/scripts/ci-changes-classify.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/ci-changes-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
    # shell-robustness: ok — always exits; its status is never used as success
    echo "TEST FAIL: $*" >&2
    exit 1
}
fixture() {
    mkdir -p "$work/$1"
    cd "$work/$1"
    git init -q
    git config user.name test
    git config user.email test@example.invalid
    git config core.fileMode true
    mkdir -p docs nested specs src .github/workflows scripts
    printf 'original\n' >src/app.js
    printf 'original\n' >docs/guide.md
    printf 'original\n' >README.md
    # Pin the shipped policy: consumer customizations must not alter fixtures.
    printf '[gates]\nround_code = "verify" # simple sibling key\ndocs_only_paths = ["docs/**", "specs/**", "*.md"]\n' >.devflow.toml
    git add .
    git commit -qm 'initial fixture'
    base="$(git rev-parse HEAD)"
}
merge_tree() {
    git add -A
    git commit -qm 'candidate change' --allow-empty
    candidate="$(git rev-parse HEAD)"
    tree="$(git rev-parse HEAD^{tree})"
    merge="$(printf 'synthetic PR merge\n' | git commit-tree "$tree" -p "$base" -p "$candidate")"
    git update-ref HEAD "$merge"
}
expect() {
    local expected="$1" event="${2:-pull_request}" actual
    actual="$(GITHUB_EVENT_NAME="$event" bash "$classifier")" || fail "$PWD: classifier failed"
    [ "$actual" = "docs_only=$expected" ] || fail "$PWD: expected $expected, got $actual"
    return 0
}

fixture docs
printf 'edit\n' >>docs/guide.md
printf 'new\n' >specs/design.txt
printf 'new\n' >README.md
merge_tree
expect true
expect false push
expect false merge_group
expect false workflow_dispatch
expect false unknown

fixture root_markdown
printf 'edit\n' >>README.md
merge_tree
expect true

for path in src/pages/about.md src/content/posts/p.md terraform/README.md .claude/skills/example/x.md; do
    fixture "nested-markdown-$(printf '%s' "$path" | tr '/.' '--')"
    mkdir -p "$(dirname "$path")"
    printf 'app or nested content\n' >"$path"
    merge_tree
    expect false
done

fixture mixed
printf 'edit\n' >>docs/guide.md
printf 'source\n' >>src/app.js
merge_tree
expect false

fixture rename
git mv docs/guide.md docs/renamed.md
merge_tree
expect false
fixture deletion
git rm -q docs/guide.md
merge_tree
expect false
fixture symlink
rm docs/guide.md
ln -s ../src/app.js docs/guide.md
merge_tree
expect false
fixture symlink_add
ln -s ../src/app.js docs/link.md
merge_tree
expect false
fixture mode
chmod +x README.md
merge_tree
expect false
fixture empty
merge_tree
expect false

# A permissive policy makes the infrastructure guard the only rejection reason.
fixture permissive_docs
printf 'edit\n' >>docs/guide.md
merge_tree
printf '[gates]\ndocs_only_paths = ["**"]\n' >.devflow.toml
expect true

for path in .github/actions/setup/action.yml .github/workflows/build.md scripts/helper.md Taskfile.yml Taskfile.yaml .devflow.toml scripts/ci-changes-classify.sh; do
    fixture "sensitive-$(printf '%s' "$path" | tr '/.' '--')"
    mkdir -p "$(dirname "$path")"
    printf '\n# edit\n' >>"$path"
    merge_tree
    printf '[gates]\ndocs_only_paths = ["**"]\n' >.devflow.toml
    expect false
done

# Config parsing: no missing/ambiguous/unsupported value may authorize a skip.
for kind in missing absent empty malformed duplicate wrong_table; do
    fixture "config-$kind"
    printf 'edit\n' >>docs/guide.md
    merge_tree
    case "$kind" in
    missing) rm .devflow.toml ;;
    absent) printf '[gates]\nround_code = "verify"\n' >.devflow.toml ;;
    empty) printf '[gates]\ndocs_only_paths = []\n' >.devflow.toml ;;
    malformed) printf '[gates]\ndocs_only_paths = ["docs/**", broken]\n' >.devflow.toml ;;
    duplicate) printf '[gates]\ndocs_only_paths = ["docs/**"]\ndocs_only_paths = ["**"]\n' >.devflow.toml ;;
    wrong_table) printf '[other]\ndocs_only_paths = ["**"]\n' >.devflow.toml ;;
    esac
    expect false
done
for quote in '"""' "'''"; do
    fixture "multiline-string-${quote:0:1}"
    printf 'source\n' >>src/app.js
    merge_tree
    printf '[gates]\nnotes = %s\ndocs_only_paths = ["**"]\n%s\n' "$quote" "$quote" >.devflow.toml
    expect false
done
# Only the global multiline-string guard rejects a string spanning tables.
for quote in '"""' "'''"; do
    fixture "cross-table-multiline-string-${quote:0:1}"
    printf 'source\n' >>src/app.js
    merge_tree
    printf '[other]\nnotes = %s\n[gates]\ndocs_only_paths = ["**"]\n[x]\n%s\n' "$quote" "$quote" >.devflow.toml
    expect false
done
fixture ambiguous_gate_line
printf 'source\n' >>src/app.js
merge_tree
printf '[gates]\nnotes = [\ndocs_only_paths = ["**"]\n]\n' >.devflow.toml
expect false
fixture multiline
printf 'edit\n' >>README.md
merge_tree
printf '[gates]\ndocs_only_paths = [\n  "docs/**", # comment\n  "*.md",\n]\n' >.devflow.toml
expect true
fixture custom_allowlist
printf 'source\n' >>src/app.js
merge_tree
printf '[gates]\ndocs_only_paths = ["src/**"]\n' >.devflow.toml
expect true
printf '[gates]\ndocs_only_paths = ["specs/**"]\n' >.devflow.toml
expect false

# A consumer may narrow the real policy without changing the suite fixtures.
fixture custom_docs_allowlist
printf 'edit\n' >>docs/guide.md
merge_tree
printf '[gates]\ndocs_only_paths = ["docs/**"]\n' >.devflow.toml
expect true
fixture custom_docs_root_markdown
printf 'edit\n' >>README.md
merge_tree
printf '[gates]\ndocs_only_paths = ["docs/**"]\n' >.devflow.toml
expect false

# A stale event base equals the candidate's source tree and hides its revert.
# The merge ref's FIRST parent is the current base, which exposes the source edit.
fixture stale_base_revert
stale="$base"
printf 'base advanced\n' >src/app.js
git add src/app.js
git commit -qm 'base source change'
base="$(git rev-parse HEAD)"
git show "$stale:src/app.js" >src/app.js
printf 'docs\n' >>README.md
merge_tree
hidden="$(git diff --name-only "$stale" HEAD)"
[ "$hidden" = README.md ] || fail 'stale-range fixture does not hide the source revert'
expect false

fixture newline_path
printf 'source\n' >$'src/hidden\nREADME.md'
merge_tree
expect false

fixture missing_merge_parent
printf 'docs\n' >>README.md
git add README.md
git commit -qm 'ordinary non-merge head'
expect false
fixture shallow_merge
printf 'docs\n' >>README.md
merge_tree
git clone -q --depth 1 "file://$PWD" "$work/shallow-checkout"
cd "$work/shallow-checkout"
expect false

echo 'CI changes classifier truth tables: PASS'
