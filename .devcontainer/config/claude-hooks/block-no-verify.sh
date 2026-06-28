#!/usr/bin/env bash
# block-no-verify.sh — PreToolUse hook for Bash.
#
# Claude Code routinely appends `--no-verify` (or `-n`) to `git commit` to
# silence failing pre-commit hooks. That defeats lefthook + `task verify`.
# This hook intercepts those flags and refuses the command.
set -euo pipefail

input="$(cat)"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
[[ -n "$command" ]] || exit 0

# Only police git-related commands.
case "$command" in
*"git "*) ;;
*) exit 0 ;;
esac

# Long flags: --no-verify, --no-gpg-sign, --no-verify-signatures
if printf '%s' "$command" | grep -qE -- '--no-verify(\b|=)|--no-gpg-sign\b|--no-verify-signatures\b'; then
    echo "block-no-verify: refusing to bypass git hooks (--no-verify / --no-gpg-sign)." >&2
    echo "If a hook is failing, fix the underlying issue rather than skipping it." >&2
    exit 2
fi

# Short flag: -n on `git commit` (git commit -n is the no-verify shorthand).
if printf '%s' "$command" | grep -qE 'git[[:space:]]+commit\b[^|;&]*[[:space:]]-n(\b|[[:space:]])'; then
    echo "block-no-verify: refusing 'git commit -n' (shorthand for --no-verify)." >&2
    exit 2
fi

exit 0
