#!/usr/bin/env bash
# agy-adapter.sh
# Adapts agy's JSON hook contract to Claude Code's shell hook scripts.

set -euo pipefail

script_path="$1"
event_type="$2"

input="$(cat)"

if [ "$event_type" = "PreToolUse" ] || [ "$event_type" = "PostToolUse" ]; then
    tool_name="$(echo "$input" | jq -r '.toolCall.name // ""')"
    if [ "$tool_name" = "run_command" ]; then
        command="$(echo "$input" | jq -r '.toolCall.args.CommandLine // ""')"
        claude_input="$(jq -n --arg cmd "$command" '{tool_input: {command: $cmd}}')"
    elif [[ "$tool_name" == *"file"* || "$tool_name" == *"edit"* ]]; then
        path="$(echo "$input" | jq -r '.toolCall.args.TargetFile // .toolCall.args.AbsolutePath // ""')"
        claude_input="$(jq -n --arg p "$path" '{tool_input: {file_path: $p}}')"
    else
        claude_input="{}"
    fi
else
    claude_input="{}"
fi

# agy invokes hook commands from a cwd that is not the tool call's, so the
# relative hook path we were handed (./.claude/hooks/*.sh) would resolve
# against the wrong tree in a linked worktree. Anchor PWD/CLAUDE_PROJECT_DIR
# on the worktree ROOT containing the call's Cwd — not the Cwd itself, which
# may be a subdirectory where the same relative path is meaningless.
#
# The hook EXECUTABLE itself is resolved separately, against this adapter's
# own worktree, never the target root: block-no-verify.sh is a safety
# boundary (docs/conventions.md), and the target root's Cwd names whichever
# worktree the tool call under supervision claims — a worktree on another
# branch can ship a neutered copy of that same relative path. Following it
# for the executable too would let that branch disable its own safety hook.
self_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$script_path" in
/*) ;;
*) script_path="$self_root/$script_path" ;;
esac

cwd="$(echo "$input" | jq -r '.toolCall.args.Cwd // ""')"
if [ -n "$cwd" ] && [ "$cwd" != "null" ] && [ -d "$cwd" ]; then
    root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
    # Only follow a root that is a worktree of THIS repository: a Cwd inside
    # some other checkout must not make its .claude/hooks/*.sh the hook we run.
    self_repo="$(git -C "$self_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    cwd_repo="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -n "$root" ] && [ -n "$self_repo" ] && [ "$cwd_repo" = "$self_repo" ]; then
        export CLAUDE_PROJECT_DIR="$root"
        cd "$root"
    fi
fi

set +e
stderr_log="$(mktemp /tmp/agy-adapter-stderr.XXXXXX)"
trap 'rm -f "$stderr_log"' EXIT
output="$(echo "$claude_input" | bash "$script_path" 2>"$stderr_log")"
exit_code=$?
set -e
stderr_out="$(cat "$stderr_log")"

if [ "$event_type" = "PreToolUse" ]; then
    claude_decision="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
    claude_reason="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
    if [ "$claude_decision" = "ask" ]; then
        jq -n --arg r "$claude_reason" '{decision: "ask", reason: $r}'
    elif [ $exit_code -ne 0 ] || [ "$claude_decision" = "deny" ]; then
        [ -n "$claude_reason" ] && stderr_out="$claude_reason"
        jq -n --arg r "$stderr_out" '{decision: "deny", reason: $r}'
    else
        echo '{"decision": "allow"}'
    fi
elif [ "$event_type" = "PostToolUse" ]; then
    echo '{}'
elif [ "$event_type" = "PreInvocation" ]; then
    ctx="$(echo "$output" | jq -r '.hookSpecificOutput.additionalContext // ""')"
    if [ "$ctx" != "" ] && [ "$ctx" != "null" ]; then
        jq -n --arg c "$ctx" '{injectSteps: [{ephemeralMessage: $c}]}'
    else
        echo '{"injectSteps": []}'
    fi
else
    echo '{}'
fi
