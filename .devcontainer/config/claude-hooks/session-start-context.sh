#!/usr/bin/env bash
# session-start-context.sh — SessionStart hook (startup + compact matchers).
#
# Re-injects orienting context every time a Claude session starts or its
# context window is compacted: current branch, recent commits, working-tree
# status, open PRs/issues, and a short reminder of repo conventions. Uses
# `task status:git` + `task status:gh` (the fine-grained dashboard sections
# from scripts/status.sh) so the payload stays small and fast — `status:site`
# and `status:code` are intentionally skipped because they hit the network
# and the local build respectively.
set -euo pipefail

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Strip ANSI color codes so the additionalContext payload renders cleanly.
strip_ansi() { sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g'; }

git_status="$(timeout 5 task status:git 2>/dev/null | strip_ansi || echo '(task status:git unavailable)')"
gh_status="$(timeout 8 task status:gh 2>/dev/null | strip_ansi || echo '(task status:gh unavailable)')"
branch="$(git branch --show-current 2>/dev/null || echo 'unknown')"

reminder=$'Repo conventions:\n- Run `task verify` before committing (lint + build + validate + test).\n- Conventional Commits required (feat/fix/docs/style/refactor/perf/test/chore/ci/build/change/remove/revert).\n- Never bypass git hooks with --no-verify; fix the underlying issue.\n- Use lefthook for git hooks (not pre-commit).\n- See docs/conventions.md (and AGENTS.md) for the authoritative conventions catalog.'

context="$(printf 'Branch: %s\n\n=== task status:git ===\n%s\n\n=== task status:gh ===\n%s\n\n%s\n' \
    "$branch" "$git_status" "$gh_status" "$reminder")"

# Emit as JSON so Claude Code injects it as additionalContext.
jq -n --arg ctx "$context" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
