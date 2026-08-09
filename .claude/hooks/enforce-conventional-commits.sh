#!/usr/bin/env bash
# enforce-conventional-commits.sh — PreToolUse hook for Bash.
#
# Enforces Conventional Commits at the AI boundary. Lefthook's commit-msg
# hook already enforces this for human commits, but Claude Code can bypass
# git hooks via --no-verify (which is separately blocked by block-no-verify.sh).
# Belt-and-suspenders: refuse non-conforming `git commit -m` messages here too.
set -euo pipefail

input="$(cat)"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
[[ -n "$command" ]] || exit 0

# Only police `git commit` invocations.
printf '%s' "$command" | grep -qE 'git[[:space:]]+commit\b' || exit 0

msg=""

if command -v python3 >/dev/null 2>&1; then
    msg="$(python3 -c '
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
    if not seg or seg[0] != "git": continue
    is_commit = "commit" in seg
    messages = []
    for i, a in enumerate(seg):
        if is_commit and (a == "-m" or a == "--message") and i + 1 < len(seg):
            messages.append(seg[i+1])
        elif is_commit and (a.startswith("-m") and len(a) > 2):
            messages.append(a[2:])
        elif is_commit and a.startswith("--message="):
            messages.append(a[10:])
    if messages:
        import re
        parsed_messages = []
        for m in messages:
            if m.startswith("$(cat <<"):
                m = re.sub(r"^\$\(cat\s+<<['\"]?[A-Za-z0-9_]+['\"]?\s*\n", "", m)
                m = re.sub(r"\n[A-Za-z0-9_]+\s*\)$", "", m)
            parsed_messages.append(m)
        print("\n\n".join(parsed_messages))
        sys.exit(0)
' "$command")"
else
    # Fallback if Python is unavailable
    if printf '%s' "$command" | grep -q "<<'EOF'"; then
        msg="$(printf '%s' "$command" | awk "/<<'\''?EOF'\''?/{flag=1; next} /^EOF\$/{flag=0} flag" | head -n1)"
    fi
    if [[ -z "$msg" ]]; then
        msg="$(printf '%s' "$command" | grep -oE -- "-m[[:space:]]+\"[^\"]+\"" | head -n1 | sed -E 's/^-m[[:space:]]+"(.*)"$/\1/' || true)"
    fi
    if [[ -z "$msg" ]]; then
        msg="$(printf '%s' "$command" | grep -oE -- "-m[[:space:]]+'[^']+'" | head -n1 | sed -E "s/^-m[[:space:]]+'(.*)'\$/\1/" || true)"
    fi
    if [[ -z "$msg" ]]; then
        msg="$(printf '%s' "$command" | grep -oE -- "-m[[:space:]]+[^[:space:]'\"]+" | head -n1 | sed -E 's/^-m[[:space:]]+(.*)$/\1/' || true)"
    fi
fi

# If we couldn't parse a message, don't block — let git itself error out.
[[ -n "$msg" ]] || exit 0

# Allow merge / revert / fixup commits that git itself generates.
case "$msg" in
"Merge "* | "Revert "* | "fixup!"* | "squash!"*) exit 0 ;;
esac

# Delegate validation to commitlint via the Taskfile — the single source of
# truth for the allowed type list and rules (commitlint.config.mjs). Pipe the
# message via stdin so it is never re-quoted or evaluated as a shell/template
# expression by go-task.
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Fail open if the toolchain is unavailable or the target doesn't exist in the local Taskfile.
command -v task >/dev/null 2>&1 || exit 0
task lint:commit-msg:text --summary >/dev/null 2>&1 || exit 0

if ! output="$(printf '%s' "$msg" | task lint:commit-msg:text 2>&1)"; then
    {
        echo "enforce-conventional-commits: commit message does not match Conventional Commits."
        echo "  got: $msg"
        echo "$output"
    } >&2
    exit 2
fi

exit 0
