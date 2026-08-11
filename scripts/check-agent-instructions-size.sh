#!/usr/bin/env bash
# Advisory portability check for Codex's default cumulative AGENTS.md budget.
set -euo pipefail

file="${1:-AGENTS.md}"
limit="${AGENT_INSTRUCTIONS_WARN_BYTES:-32768}"

case "$limit" in
'' | *[!0-9]*)
    echo "check-agent-instructions-size: invalid byte limit: $limit" >&2
    exit 2
    ;;
esac

[ -f "$file" ] || exit 0
bytes="$(wc -c <"$file" | tr -d '[:space:]')"
[ "$bytes" -gt "$limit" ] || exit 0

message="$file is ${bytes} bytes; Codex reads 32 KiB by default. Keep Claude quality primary, but consider splitting nested guidance or raising project_doc_max_bytes."
if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    printf '::warning file=%s::%s\n' "$file" "$message"
else
    printf 'WARN: %s\n' "$message" >&2
fi

# Advisory by design: an oversized policy must not block CI or a merge.
exit 0
