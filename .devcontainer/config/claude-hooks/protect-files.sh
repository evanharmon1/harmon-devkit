#!/usr/bin/env bash
# protect-files.sh — PreToolUse hook for Edit|Write|MultiEdit.
#
# Blocks AI modification of sensitive or generated files: secrets, lockfiles,
# git internals, dependency dirs, binary assets, terraform state, ansible vault,
# and Claude's own managed settings. Exit 2 tells Claude Code to refuse the
# tool call and surface the stderr message back to the model.
set -euo pipefail

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"
[[ -n "$file_path" ]] || exit 0

# Substring patterns — matched anywhere in the path.
protected=(
    ".env"
    "uv.lock"
    "package-lock.json"
    ".git/"
    "node_modules/"
    "dist/"
    ".terraform/"
    ".tfstate"
    ".claude/settings.json"
    "/etc/claude-code/"
)

for pattern in "${protected[@]}"; do
    if [[ "$file_path" == *"$pattern"* ]]; then
        echo "protect-files: blocked write to '$file_path' (matches protected pattern '$pattern')" >&2
        exit 2
    fi
done

# Suffix patterns — binary assets that shouldn't be hand-edited.
case "$file_path" in
*.png | *.jpg | *.jpeg | *.webp | *.gif | *.ico | *.pdf | *.pem | *.key)
    echo "protect-files: blocked write to '$file_path' (binary asset or secret)" >&2
    exit 2
    ;;
esac

exit 0
