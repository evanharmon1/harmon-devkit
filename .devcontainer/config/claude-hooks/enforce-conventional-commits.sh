#!/usr/bin/env bash
# enforce-conventional-commits.sh — PreToolUse hook for Bash.
#
# Lint only message forms readable with certainty; pass everything else to
# lefthook's commit-msg hook, which is the real enforcement.
set -euo pipefail

input="$(cat)"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
[[ -n "$command" ]] || exit 0

# Python is required for safe shell tokenization. If parsing is unavailable or
# fails, let lefthook validate the actual commit message instead.
command -v python3 >/dev/null 2>&1 || exit 0
messages_json="$(python3 -c '
import json
import os
import re
import shlex
import sys

try:
    command = sys.argv[1]
    # A continuation, or a # that starts a word (a shell comment, which can
    # hide or invent command boundaries), is left to the real commit hook.
    if chr(92) + "\n" in command or re.search(r"(^|[\s;&|()])#", command):
        sys.exit(0)
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    # Keep newlines as command boundaries, rather than ordinary whitespace.
    lexer.whitespace = " \t\r"
    lexer.commenters = ""
    segments = []
    segment = []
    heredocs = []
    for token in lexer:
        if token == "\n":
            segments.append(segment)
            segment = []
            # Consume heredoc bodies as data, never shell command segments.
            for delimiter, strip_tabs in heredocs:
                for line in lexer.instream:
                    if (line.lstrip("\t") if strip_tabs else line).rstrip("\n") == delimiter:
                        break
            heredocs = []
        elif token and set(token) <= set(";&|()"):
            # Operators written together (;( |( )&&) are one token; all end a command.
            segments.append(segment)
            segment = []
        else:
            if segment and segment[-1] == "<<":
                strip_tabs = token.startswith("-")
                heredocs.append((token[1:] if strip_tabs else token, strip_tabs))
            segment.append(token)
    segments.append(segment)
except ValueError:
    sys.exit(0)

all_messages = []
for segment in segments:
    # Locate the executable after shell assignments, wrappers and control words.
    index = 0
    while index < len(segment):
        word = segment[index]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", word):
            index += 1
        elif word in ("command", "builtin", "exec", "nohup", "time", "-p",
                      "{", "!", "if", "then", "do", "else", "elif", "while", "until"):
            index += 1
        elif word == "env":
            index += 1
            while index < len(segment) and segment[index].startswith("-"):
                option = segment[index]
                index += 1
                if option in ("-u", "--unset", "-C", "--chdir"):
                    index += 1
                elif option == "--":
                    break
        else:
            break
    if index >= len(segment) or os.path.basename(segment[index]) != "git":
        continue
    index += 1
    # Only these Git options consume separate values; bare --exec-path does not.
    while index < len(segment) and segment[index].startswith("-"):
        option = segment[index]
        index += 1
        if option in ("-C", "-c", "--git-dir", "--work-tree", "--namespace",
                      "--super-prefix", "--config-env", "--attr-source"):
            index += 1
    if index >= len(segment) or segment[index] != "commit":
        continue
    args = segment[index + 1:]
    messages = []
    index = 0
    while index < len(args):
        arg = args[index]
        if arg == "--":
            break
        name, equals, value = arg.partition("=")
        is_file = len(name) >= 5 and "--file".startswith(name)
        is_message = len(name) >= 3 and "--message".startswith(name)
        if arg.startswith("--"):
            if is_file:
                sys.exit(0)
            if is_message:
                if equals:
                    messages.append(value)
                elif index + 1 < len(args):
                    index += 1
                    messages.append(args[index])
        elif arg.startswith("-F"):
            sys.exit(0)
        elif arg == "-m" and index + 1 < len(args):
            index += 1
            messages.append(args[index])
        elif arg.startswith("-m") and len(arg) > 2:
            messages.append(arg[2:])
        elif arg.startswith("-") and "m" in arg:
            sys.exit(0)  # Ambiguous clusters are left to the real commit hook.
        elif arg in ("-C", "-c", "-t"):
            index += 1  # These operands are not messages.
        index += 1
    parsed = []
    for message in messages:
        if message.startswith("$("):
            # Recognize only a literal cat heredoc owned by this -m argument.
            # Never evaluate shell substitutions or search the whole command.
            match = re.fullmatch(
                r"\$\(cat\s+<<([\"\x27]?)([A-Za-z0-9_]+)\1[ \t]*\n(.*?)\n\2\n?\)",
                message, re.DOTALL,
            )
            if not match or (not match[1] and re.search("[$`]", match[3])):
                sys.exit(0)  # An unquoted delimiter lets the shell expand the body.
            message = match[3]
        elif "$" in message or "`" in message:
            sys.exit(0)  # Shell expansions are left to the real commit hook.
        parsed.append(message)
    if parsed:
        all_messages.append("\n\n".join(parsed))
print(json.dumps(all_messages))
' "$command")"

[[ -n "$messages_json" && "$messages_json" != "[]" ]] || exit 0

# Delegate to the Taskfile's commitlint rules via stdin, without evaluating
# or re-quoting the message as a shell/template expression.
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"

# Fail open if the toolchain is unavailable or the target doesn't exist in the local Taskfile.
command -v task >/dev/null 2>&1 || exit 0
task lint:commit-msg:text --summary >/dev/null 2>&1 || exit 0

while IFS= read -r -d "" msg; do
    case "$msg" in
    "Merge "* | "Revert "* | "fixup!"* | "squash!"*) continue ;;
    esac
    if ! output="$(printf '%s' "$msg" | task lint:commit-msg:text 2>&1)"; then
        {
            echo "enforce-conventional-commits: commit message does not match Conventional Commits."
            echo "  got: $msg"
            echo "$output"
        } >&2
        exit 2
    fi
done < <(printf '%s' "$messages_json" | jq -j '.[] | ., "\u0000"')

exit 0
