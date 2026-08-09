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

cwd="$(echo "$input" | jq -r '.toolCall.args.Cwd // ""')"
if [ -n "$cwd" ] && [ "$cwd" != "null" ]; then
    export CLAUDE_PROJECT_DIR="$cwd"
fi

set +e
stderr_log="$(mktemp /tmp/agy-adapter-stderr.XXXXXX)"
trap 'rm -f "$stderr_log"' EXIT
output="$(echo "$claude_input" | bash "$script_path" 2>"$stderr_log")"
exit_code=$?
set -e
stderr_out="$(cat "$stderr_log")"

if [ "$event_type" = "PreToolUse" ]; then
    if [ $exit_code -ne 0 ]; then
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
