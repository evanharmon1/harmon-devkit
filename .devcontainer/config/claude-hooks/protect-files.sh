#!/usr/bin/env bash
# protect-files.sh — PreToolUse hook for Edit|Write|MultiEdit.
#
# Blocks AI modification of sensitive files: credentials, secrets, and
# managed agent settings. Exit 2 tells Claude Code to refuse the tool call
# and surface the stderr message back to the model.
set -euo pipefail

input="$(cat)"
file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"
[[ -n "$file_path" ]] || exit 0

# Substring patterns — matched anywhere in the path.
protected=(
    ".claude/settings.json"
    ".codex/config.toml"
    "/etc/claude-code/"
    "/etc/codex/"
)

for pattern in "${protected[@]}"; do
    if [[ "$file_path" == *"$pattern"* ]]; then
        echo "protect-files: blocked write to '$file_path' (matches protected pattern '$pattern')" >&2
        exit 2
    fi
done

# Suffix and glob patterns — sensitive credentials.
case "$file_path" in
*.pem | *.key | *.env | .env.* | */.env.*)
    echo "protect-files: blocked write to '$file_path' (matches protected credential pattern)" >&2
    exit 2
    ;;
esac

exit 0
