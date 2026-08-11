#!/usr/bin/env bash
# test-lint-hygiene.sh — behavioral fixtures for lint-hygiene.sh's
# trigger-phrase adjacency scan (issue #725).
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
script=./scripts/lint-hygiene.sh

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
        echo "  ok: $name"
    else
        fail=$((fail + 1))
        echo "  FAIL: $name (want exit $want, got $got)" >&2
    fi
}

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

echo "test-lint-hygiene: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
