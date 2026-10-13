#!/usr/bin/env bash
# Prepare web checkouts on startup and resume, including cached resumes.
# Local sessions and devcontainers use their own lifecycle.
[ "${CLAUDE_CODE_REMOTE:-}" = true ] || exit 0

if ! ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; then
    echo "==> WARNING: SessionStart remote preparation: could not locate the checkout; run task setup:remote."
    exit 0
fi

# Leave time to report a failure before the hook's 120-second timeout.
if ! command -v timeout >/dev/null 2>&1; then
    echo "==> WARNING: SessionStart remote preparation: preparation skipped because timeout is unavailable; run task setup:remote."
    exit 0
fi

# A regular file does not wait for descendants to close inherited stdout, as a
# command-substitution pipe would after timeout has already returned.
if ! output_file="$(mktemp)"; then
    echo "==> WARNING: SessionStart remote preparation: could not capture preparation output; run task setup:remote."
    exit 0
fi
trap 'rm -f "$output_file"' EXIT

if timeout --kill-after=5s 90s task --dir "$ROOT" setup:remote >"$output_file"; then
    cat "$output_file" >&2
    summary="setup:remote completed."
    while IFS= read -r line; do
        case "$line" in
        # The last status marker wins, including a final clean status that
        # supersedes a tool's earlier marker-shaped output.
        '==> setup:remote completed.' | '==> setup:remote completed with warnings:'*) summary="${line#==> }" ;;
        esac
    done <"$output_file"
    echo "==> SessionStart remote preparation: ${summary}"
else
    cat "$output_file" >&2
    echo "==> WARNING: SessionStart remote preparation: setup:remote failed; run task setup:remote again."
fi
# Preparation failures must never prevent a session from starting.
exit 0
