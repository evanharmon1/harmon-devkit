#!/usr/bin/env bash
# Adapt Codex hook context to the shared Claude-compatible policy scripts.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -x "$1" ]; then
    echo "claude-compat: expected one executable hook path" >&2
    exit 1
fi

input="$(cat)"
project_dir="$(printf '%s' "$input" | jq -r '.cwd // empty')"
if [ -n "$project_dir" ]; then
    export CLAUDE_PROJECT_DIR="$project_dir"
fi

printf '%s' "$input" | "$1"
