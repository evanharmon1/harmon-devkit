#!/usr/bin/env bash
# Inspect only the final result; never dump the execution transcript.
set -euo pipefail

if [ "${1:-inspect}" = cleanup ]; then
    branch=${PRIMARY_BRANCH:-}
    [ -n "$branch" ] || exit 0
    case "$branch" in
    claude/*) ;;
    *)
        echo "Refusing cleanup of a branch outside claude/" >&2
        exit 1
        ;;
    esac
    if [ "$branch" = "${DEFAULT_BRANCH:?}" ]; then
        echo "Refusing cleanup of the default branch" >&2
        exit 1
    fi
    git show-ref --verify --quiet "refs/heads/$branch" || exit 0
    git checkout --detach "${START_COMMIT:?}"
    git branch -D -- "$branch"
    exit 0
fi

retry=false
failed=true
result=''
if [ -n "${EXECUTION_FILE:-}" ] && [ -f "$EXECUTION_FILE" ]; then
    result=$(jq -sce 'if length == 1 and (.[0] | type == "array") then
        [.[0][] | select(type == "object" and .type == "result")] | last
        | select(type == "object") else empty end' "$EXECUTION_FILE" 2>/dev/null) || result=''
fi
# Retire the primary file before a retry can fail without writing a new one.
if [ "${ARCHIVE_EXECUTION:-false}" = true ] &&
    [ -n "${EXECUTION_FILE:-}" ] && [ -f "$EXECUTION_FILE" ]; then
    mv "$EXECUTION_FILE" "$EXECUTION_FILE.primary"
fi

if [ -n "$result" ]; then
    if [ "${ACTION_OUTCOME:-}" = success ] &&
        jq -e '.is_error == false and .subtype == "success"' <<<"$result" >/dev/null; then
        failed=false
    fi
    # Retry only a failed step with explicit proof of zero model usage.
    if [ "${ACTION_OUTCOME:-}" = failure ] && [ "${HAS_ALT:-false}" = true ] &&
        jq -e '.is_error == true and .total_cost_usd == 0 and
            (.modelUsage | type == "object" and length == 0)' <<<"$result" >/dev/null; then
        retry=true
    fi
fi
printf 'retry=%s\nfailed=%s\n' "$retry" "$failed" >>"${GITHUB_OUTPUT:?}"

if [ "$failed" = true ]; then
    if [ -n "$result" ]; then
        diagnostic=$(jq -c '{result, subtype, is_error, total_cost_usd, modelUsage, errors}' <<<"$result")
    else
        diagnostic='{"result":"Execution file missing, malformed, or without a result; no safe retry.","is_error":true}'
    fi
    # Exact credential redaction applies to comments as well as logs (GitHub
    # masks logs only). Also remove recognizable tokens and review mentions.
    diagnostic=$(jq -nr --arg text "$diagnostic" '
        [env.REDACT_PRIMARY, env.REDACT_ALT, env.GH_TOKEN, env.REDACT_APP_TOKEN]
        | map(select(type == "string" and length > 0)) as $secrets
        | reduce $secrets[] as $secret ($text; split($secret) | join("[REDACTED]"))
        | gsub("sk-[A-Za-z0-9_-]+|gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+"; "[REDACTED]")
        | gsub("(?i)\u0040codex"; "[review mention removed]")
        | gsub("`"; "\\u0060")')
    printf 'Claude failure: %s\n' "$diagnostic"
    if [ -n "${TARGET:-}" ]; then
        body=$(printf 'Claude workflow attempt failed.\n\n```json\n%s\n```\n' "$diagnostic")
        if ! gh api "repos/${GH_REPO:?}/issues/$TARGET/comments" -f body="$body" >/dev/null 2>&1; then
            echo "::warning::Could not post the Claude failure comment; result decisions are unchanged."
        fi
    fi
fi
