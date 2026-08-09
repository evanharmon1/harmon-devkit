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

# Only police git invocations.
printf '%s' "$command" | grep -qE '\bgit\b' || exit 0

if command -v python3 >/dev/null 2>&1; then
    if ! python3 -c '
import sys, shlex
try:
    lexer = shlex.shlex(sys.argv[1], posix=True, punctuation_chars=True)
    args = list(lexer)
except ValueError:
    sys.exit(0)
segments = []
current = []
for a in args:
    if a in (";", "&&", "||", "|", "&"):
        segments.append(current)
        current = []
    else:
        current.append(a)
if current: segments.append(current)
for seg in segments:
    if "git" not in seg: continue
    is_commit = "commit" in seg
    for a in seg:
        if a.startswith("--no-veri"):
            sys.exit(1)
        if is_commit and a.startswith("-") and not a.startswith("--"):
            if a.startswith(("-m", "-F", "-c", "-C", "-t", "-u")):
                continue
            if "n" in a:
                sys.exit(1)
sys.exit(0)
' "$command"; then
        echo "block-no-verify: refusing to bypass git hooks (--no-verify / -n)." >&2
        echo "If a hook is failing, fix the underlying issue rather than skipping it." >&2
        exit 2
    fi
fi

exit 0
