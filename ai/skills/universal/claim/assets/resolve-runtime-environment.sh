#!/usr/bin/env bash
# Classify the execution environment without exposing machine-specific identity.
#
# Output is exactly one of:
#   host | devcontainer | coder | codespace | github-actions | unknown
#
# More specific hosted environments win over the generic container signals
# they commonly inherit. Unknown or malformed signals never leak their values.
set -euo pipefail

if [ "$#" -ne 0 ]; then
    echo "Usage: $0" >&2
    exit 2
fi

is_true() {
    local normalized
    normalized="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$normalized" in
    1 | true | yes) return 0 ;;
    *) return 1 ;;
    esac
}

is_false_or_empty() {
    local normalized
    normalized="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$normalized" in
    '' | 0 | false | no) return 0 ;;
    *) return 1 ;;
    esac
}

# Ordered from the most specific execution service to the most generic
# container. A Codespace or Coder workspace can also expose devcontainer
# signals, and a GitHub Actions job can itself run in a container.
if is_true "${GITHUB_ACTIONS:-}"; then
    printf '%s\n' github-actions
elif is_true "${CODESPACES:-}"; then
    printf '%s\n' codespace
elif is_true "${CODER:-}" || [ -n "${CODER_AGENT_URL:-}" ]; then
    printf '%s\n' coder
elif is_true "${REMOTE_CONTAINERS:-}" || is_true "${DEVCONTAINER:-}" ||
    [ -n "${REMOTE_CONTAINERS_IPC:-}" ]; then
    printf '%s\n' devcontainer
elif ! is_false_or_empty "${GITHUB_ACTIONS:-}" ||
    ! is_false_or_empty "${CODESPACES:-}" ||
    ! is_false_or_empty "${CODER:-}" ||
    ! is_false_or_empty "${REMOTE_CONTAINERS:-}" ||
    ! is_false_or_empty "${DEVCONTAINER:-}" ||
    is_true "${CI:-}" || [ -n "${container:-}" ]; then
    # Some automation/container context exists, but none of the portable
    # categories above can be established safely.
    printf '%s\n' unknown
else
    printf '%s\n' host
fi
