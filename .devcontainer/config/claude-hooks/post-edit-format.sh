#!/usr/bin/env bash
# post-edit-format.sh — PostToolUse hook for Edit|Write|MultiEdit.
#
# Auto-formats the just-written file so AI-generated code matches repo
# conventions before it ever reaches git. Delegates to `task format:file`,
# the single source of truth for the per-language formatter set.
#
# Always exits 0: this hook fixes, never blocks the tool call.
set -euo pipefail

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"
[[ -n "$file_path" ]] || exit 0
[[ -f "$file_path" ]] || exit 0

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Delegate to the Taskfile so the formatter SET lives in one place.
task format:file -- "$file_path" >/dev/null 2>&1 || true

exit 0
