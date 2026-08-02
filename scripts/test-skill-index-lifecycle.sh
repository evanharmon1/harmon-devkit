#!/usr/bin/env bash
# test-skill-index-lifecycle.sh — guard the three public skill indexes against
# stale lifecycle language that contradicts the canonical /implement and
# /shepherd skills. The accepted vocabulary is "ready-for-review PR" and
# "shepherd a draft PR to ready for review"; the rejected patterns are the
# obsolete "green PR" / "to green" / "→ green" labels that predated the
# draft-PR lifecycle.
#
# Run via `task test:skill-index-lifecycle`.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

FILES=(
    README.md
    ai/skills/README.md
    docs/guides/codex-review.md
)

# Patterns that should not appear in skill/workflow descriptions.
# Each is a grep -iE regex.  We avoid GNU-only \b; instead we use
# literal context or POSIX character classes for word separation.
REJECTED=(
    'green PR'
    '(^|[^[:alnum:]_])PR([^[:alnum:]_].*)?to green|to green.*(^|[^[:alnum:]_])PR([^[:alnum:]_]|$)'
    '→ green'
    '(^|[^[:alnum:]_])not green([^[:alnum:]_]|$)'
    '(^|[^[:alnum:]_])checks green([^[:alnum:]_]|$)'
)

fail=0
for f in "${FILES[@]}"; do
    if [ ! -f "$f" ]; then
        echo "  ✗ guarded index missing: $f" >&2
        fail=1
        continue
    fi
    for pat in "${REJECTED[@]}"; do
        if grep -qiE "$pat" "$f"; then
            echo "  ✗ $f contains stale lifecycle language: '$pat'" >&2
            grep -niE "$pat" "$f" | sed 's/^/      /' >&2
            fail=1
        fi
    done
done

if [ "$fail" -ne 0 ]; then
    echo "" >&2
    echo "The files above use obsolete 'green PR' vocabulary." >&2
    echo "The canonical skills define the lifecycle as:" >&2
    echo "  /implement → ready-for-review PR" >&2
    echo "  /shepherd  → shepherd a draft PR to ready for review" >&2
    exit 1
fi

echo "✓ Public skill indexes use current lifecycle vocabulary"
