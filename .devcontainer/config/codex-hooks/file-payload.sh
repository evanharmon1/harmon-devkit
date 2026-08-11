#!/usr/bin/env bash
# Translate Codex apply_patch payloads into Claude-style file hook payloads.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -x "$1" ]; then
    echo "file-payload: expected one executable hook path" >&2
    exit 1
fi

input="$(cat)"
project_dir="$(printf '%s' "$input" | jq -r '.cwd // empty')"
patch="$(printf '%s' "$input" | jq -r '.tool_input.command // .tool_input.patch // empty')"
[ -n "$patch" ] || exit 0

if [ -n "$project_dir" ]; then
    export CLAUDE_PROJECT_DIR="$project_dir"
fi

paths="$(printf '%s\n' "$patch" | sed -nE 's/^\*\*\* (Add|Update|Delete) File: //p; s/^\*\*\* Move to: //p')"
[ -n "$paths" ] || exit 0

while IFS= read -r file_path; do
    [ -n "$file_path" ] || continue
    jq -n --arg file_path "$file_path" '{tool_input: {file_path: $file_path}}' | "$1"
done <<EOF
$paths
EOF
