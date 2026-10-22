#!/usr/bin/env bash
# clear-needs-review.sh — clear one issue's review marker, independently of claims.
set -euo pipefail

usage() {
    echo "Usage: clear-needs-review.sh --repo OWNER/NAME --issue N"
}

repo=""
issue=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --issue)
        if [ "$#" -lt 2 ]; then
            usage >&2
            exit 2
        fi
        case "$1" in
        --repo) repo="$2" ;;
        --issue) issue="$2" ;;
        esac
        shift 2
        ;;
    --help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
    esac
done

if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    [[ ! "$issue" =~ ^[1-9][0-9]*$ ]]; then
    echo "Expected --repo OWNER/NAME and a positive numeric --issue." >&2
    exit 2
fi

labels="$(gh issue view "$issue" --repo "$repo" --json labels --jq '.labels[].name')" || exit $?
if grep -Fxq 'needs-review' <<<"$labels"; then
    gh issue edit "$issue" --repo "$repo" --remove-label needs-review
fi
