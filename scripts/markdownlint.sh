#!/usr/bin/env bash
# markdownlint.sh — resolve markdownlint-cli2 and run it in check or fix mode.
#
# Prefer the repo-pinned binary (node_modules/.bin) so hooks/CI match the
# lockfile; fall back to npx for non-node repos and fresh scaffolds. Invoking
# the .bin shim directly is package-manager-agnostic (works under npm too,
# where `pnpm exec` would break). Keeps this bin-vs-npx dispatch out of the
# Taskfile per the "keep cmds trivial; non-trivial shell lives in scripts/*.sh"
# rule.
#
# Usage:
#   markdownlint.sh check [glob-or-file ...]   # read-only gate
#   markdownlint.sh fix   [glob-or-file ...]   # best-effort auto-fix
# With no glob/file args, a canonical repo-wide default set is used.
set -euo pipefail

mode="${1:-check}"
if [ "$#" -gt 0 ]; then shift; fi

# Canonical excludes: generated output (dist, .task, .terraform, .venv,
# node_modules), vendored skills (.claude), scratch worktrees, spec fixtures,
# and the template/ tree (jinja markdown — present only in the template repo
# itself, an inert glob everywhere else).
default_globs=(
    '**/*.md'
    '#template/**'
    '#.claude/**'
    '#specs/*/**'
    '#**/node_modules/**'
    '#dist/**'
    '#.worktrees/**'
    '#**/.terraform/**'
    '#**/.venv/**'
    '#**/.task/**'
    '#.foreman/**'
)

# renovate: datasource=npm depName=markdownlint-cli2
MARKDOWNLINT_CLI2_VERSION="0.22.1"

if [ -x node_modules/.bin/markdownlint-cli2 ]; then
    run=(node_modules/.bin/markdownlint-cli2)
elif command -v markdownlint-cli2 >/dev/null 2>&1; then
    run=(markdownlint-cli2)
else
    run=(npx --yes "markdownlint-cli2@${MARKDOWNLINT_CLI2_VERSION}")
fi

if [ "$#" -eq 0 ]; then
    set -- "${default_globs[@]}"
fi

case "$mode" in
check)
    "${run[@]}" "$@"
    ;;
fix)
    # Best-effort: --fix must not abort `task format` on un-auto-fixable rule
    # violations (e.g. MD024 duplicate heading, MD040 missing fence language) —
    # `markdownlint.sh check` is the gate.
    "${run[@]}" --fix "$@" || true
    ;;
*)
    echo "markdownlint.sh: unknown mode '$mode' (expected check|fix)" >&2
    exit 2
    ;;
esac
