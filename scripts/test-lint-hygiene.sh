#!/usr/bin/env bash
# test-lint-hygiene.sh — behavioral fixtures for lint-hygiene.sh's
# trigger-phrase adjacency scan (#725) and fenced shell budgets (#422).
#
# The scan must flag every form whose RENDERED COPY reconstructs a literal
# Claude trigger phrase, and must not flag prose-separated text or the
# functional workflow definitions. Fixtures run the real script against
# scratch files, so a regression in the tr/grep pipeline fails here rather
# than shipping.
#
# Portable across macOS bash 3.2 and Linux.
set -euo pipefail

cd "$(dirname "$0")/.."
project_root=$(pwd)
script="$project_root/scripts/lint-hygiene.sh"

pass=0
fail=0

# expect <name> <want-exit> <content...>  — writes the content to a scratch
# .md file, runs the scan on it, and compares the exit code.
expect() {
    name=$1
    want=$2
    shift 2
    dir=$(mktemp -d)
    printf '%s\n' "$@" >"$dir/fixture.md"
    got=0
    "$script" "$dir/fixture.md" >/dev/null 2>&1 || got=$?
    rm -rf "$dir"
    if [ "$got" -eq "$want" ]; then
        pass=$((pass + 1))
        echo "  ok: $name" || true
    else
        fail=$((fail + 1))
        echo "  FAIL: $name (want exit $want, got $got)" >&2 || true
    fi
    return 0
}

expect_vendored_asset() {
    name=$1
    want=$2
    path=$3
    content=$4
    got=0
    (
        cd "$vendored_fixture_root"
        mkdir -p "$(dirname "$path")"
        printf '%s' "$content" >"$path"
        "$script" "$path" >/dev/null 2>&1
    ) || got=$?
    rm -f "$vendored_fixture_root/$path"
    if [ "$got" -eq "$want" ]; then
        pass=$((pass + 1))
        echo "  ok: $name"
    else
        fail=$((fail + 1))
        echo "  FAIL: $name (want exit $want, got $got)" >&2
    fi
    return 0
}

vendored_fixture="lint-hygiene-vendored-$$"
vendored_fixture_root=$(mktemp -d)
trap 'rm -rf "$vendored_fixture_root"' EXIT HUP INT TERM

echo "==> installer-owned agent assets bypass content hygiene, not secret scanning"
expect_vendored_asset "Claude skills asset" 0 ".claude/skills/$vendored_fixture.txt" "trailing space "
expect_vendored_asset "portable skills asset" 0 ".agents/skills/$vendored_fixture.txt" "trailing space "
expect_vendored_asset "BMad asset" 0 "_bmad/$vendored_fixture.csv" "trailing space "
expect_vendored_asset "vendored agent private key still scanned" 1 ".agents/skills/$vendored_fixture.key" "-----BEGIN PRIVATE KEY-----"

echo "==> adjacency forms that rendered copy reconstructs are flagged"
expect "same-line adjacency" 1 'post an @claude plan comment'
expect "fold/paragraph boundary" 1 'post an @claude' 'plan comment'
expect "backtick-separated tokens" 1 'post an `@claude` `plan` comment'
expect "backticked phrase" 1 'post an `@claude implement` comment'
expect "case variant" 1 'post an @Claude Review comment'
expect "bold subcommand" 1 'post an @claude **plan** comment'
expect "linked subcommand" 1 'post an @claude [plan](docs/x.md) comment'
expect "linked mention" 1 'post a [`@claude`](https://example.com) plan comment'

echo "==> safe forms pass"
expect "prose-separated tokens" 0 'an @claude mention naming plan, implement, or review'
expect "mention alone" 0 'mention @claude and nothing else'
expect "subcommand alone" 0 'the plan is reviewed'
expect "prose word inside a wide gap" 0 'the @claude commands naming plan, implement, or review'
expect "non-ASCII prose separation" 0 'the @claude command 日本語のドキュメント plan section'

echo "==> functional workflow definitions are exempt"
# The real workflow file carries the literal trigger phrase by design; the
# scan's path exclusion must keep gating it out.
if "$script" .github/workflows/claude-plan.yml >/dev/null 2>&1; then
    pass=$((pass + 1))
    echo "  ok: workflow file exempt"
else
    fail=$((fail + 1))
    echo "  FAIL: workflow file exempt (scan flagged a functional definition)" >&2
fi

echo "==> skill Markdown fenced shell budgets (issue #422)"
# Isolated tree: relative ai/skills paths exercise the production path filter.
# Sizes count content only, excluding opening and closing delimiters.
expect_shell_size() {
    local name=$1 want=$2 path=$3 blocks=$4 lines=$5 opener=$6 closer=$7
    local expected=${8:-} got=0 output block line
    mkdir -p "$vendored_fixture_root/$(dirname "$path")"
    {
        for ((block = 0; block < blocks; block++)); do
            printf '%s\n' "$opener"
            for ((line = 0; line < lines; line++)); do
                printf '%s\n' 'echo example'
            done
            [ -z "$closer" ] || printf '%s\n' "$closer"
        done
    } >"$vendored_fixture_root/$path"
    output=$(cd "$vendored_fixture_root" && "$script" "$path" 2>&1) || got=$?
    rm -f "$vendored_fixture_root/$path"
    if [ "$got" -eq "$want" ] && { [ -z "$expected" ] || [[ "$output" == *"$path: fenced shell too large ($expected"* ]]; }; then
        pass=$((pass + 1))
        echo "  ok: $name"
    else
        fail=$((fail + 1))
        echo "  FAIL: $name (want exit $want, got $got): $output" >&2
    fi
    return 0
}

skill_path=ai/skills/example/references/snippets.md
expect_shell_size "single block at limit" 0 "$skill_path" 1 150 '```sh' '```'
expect_shell_size "single block above limit is reported" 1 "$skill_path" 1 151 '```sh' '```' 'total=151, limit=400; longest=151, limit=150)'
expect_shell_size "many small blocks at total limit" 0 "$skill_path" 40 10 '```bash' '```'
expect_shell_size "total above limit is reported" 1 "$skill_path" 4 101 '```bash' '```' 'total=404, limit=400; longest=101, limit=150)'
expect_shell_size "shell alias" 1 "$skill_path" 1 151 '```shell' '```' 'total=151'
expect_shell_size "console alias" 1 "$skill_path" 1 151 '```console' '```' 'total=151'
expect_shell_size "indented tilde fence with arguments" 1 "$skill_path" 1 151 '   ~~~ bash title="example"' '   ~~~~  ' 'total=151'
expect_shell_size "longer backtick fences" 1 "$skill_path" 1 151 '````sh' '`````' 'total=151'
expect_shell_size "short closing fence leaves content counted" 1 "$skill_path" 1 150 '````sh' '```' 'total=151'
expect_shell_size "different closing marker leaves content counted" 1 "$skill_path" 1 150 '```sh' '~~~' 'total=151'
expect_shell_size "unclosed fence counted through EOF" 1 "$skill_path" 1 151 '```sh' '' 'total=151'
expect_shell_size "non-shell fenced example ignored" 0 "$skill_path" 1 151 $'````markdown\n```sh' $'```\n````'
expect_shell_size "unrelated language ignored" 0 "$skill_path" 1 151 '```python' '```'
expect_shell_size "language prefix ignored" 0 "$skill_path" 1 151 '```shellcheck' '```'
expect_shell_size "Markdown outside skills ignored" 0 docs/example.md 1 151 '```sh' '```'
expect_shell_size "skill assets shell script ignored" 0 ai/skills/example/assets/run.sh 1 151 '```sh' '```'
expect_shell_size "explicit dot-relative path guarded" 1 "./$skill_path" 1 151 '```sh' '```' 'total=151'
expect_shell_size "only legacy mode-update exempt for issue 420" 0 ai/skills/repo/standardize-repo/references/mode-update.md 1 151 '```sh' '```'
expect_shell_size "another mode-update not exempt" 1 ai/skills/example/references/mode-update.md 1 151 '```sh' '```' 'total=151'

echo "test-lint-hygiene: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
