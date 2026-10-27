#!/usr/bin/env bash
# clear-needs-review.sh — clear an issue and its delivery PRs, independently of claims.
set -euo pipefail

usage() {
    echo "Usage: clear-needs-review.sh --repo OWNER/NAME --issue N [--pr N]"
}

repo=""
issue=""
pr=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --issue | --pr)
        if [ "$#" -lt 2 ]; then
            usage >&2
            exit 2
        fi
        case "$1" in
        --repo) repo="$2" ;;
        --issue) issue="$2" ;;
        --pr) pr="$2" ;;
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

# The existing harmon-init PR-end caller supplies these without a new argv.
# Ignore an unrelated caller's PR_NUMBER rather than clearing another repository.
if [ -z "$pr" ] && [ "${GH_REPO:-}" = "$repo" ]; then
    pr="${PR_NUMBER:-}"
fi
if [ -n "$pr" ] && [[ ! "$pr" =~ ^[1-9][0-9]*$ ]]; then
    echo "Expected a positive numeric delivery PR." >&2
    exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Read every object before writing. Failed discovery must not silently clear only
# the issue. Closing links cover issue-close callers; Refs PRs use --pr or the
# same-repository PR-end event context above.
gh issue view "$issue" --repo "$repo" --json labels,closedByPullRequestsReferences >"$tmp/issue.json"
jq -er '.labels | type == "array"' "$tmp/issue.json" >/dev/null
jq -r --arg prefix "https://${GH_HOST:-github.com}/$repo/pull/" '
    .closedByPullRequestsReferences[]?
    | select((.url | ascii_downcase) | startswith($prefix | ascii_downcase))
    | .number
' "$tmp/issue.json" >"$tmp/prs"
[ -z "$pr" ] || printf '%s\n' "$pr" >>"$tmp/prs"
sort -un "$tmp/prs" >"$tmp/prs-sorted"
while IFS= read -r delivery; do
    [[ "$delivery" =~ ^[1-9][0-9]*$ ]] || exit 2
    gh pr view "$delivery" --repo "$repo" --json labels >"$tmp/pr-$delivery.json"
    jq -er '.labels | type == "array"' "$tmp/pr-$delivery.json" >/dev/null
done <"$tmp/prs-sorted"

clear_marker() {
    local kind="$1" number="$2" snapshot="$3" label
    label="$(jq -r '.labels[] | select((.name | ascii_downcase) == "needs-review") | .name' "$snapshot")"
    [ -n "$label" ] || return 0
    gh "$kind" edit "$number" --repo "$repo" --remove-label "$label" || return
    gh "$kind" view "$number" --repo "$repo" --json labels >"$tmp/after.json" || return
    if ! jq -e '.labels | type == "array" and all(.[]; (.name | ascii_downcase) != "needs-review")' \
        "$tmp/after.json" >/dev/null; then
        echo "needs-review removal could not be verified on $kind #$number" >&2
        return 1
    fi
}

# GitHub has no paired-label transaction. A partial failure is non-zero and an
# idempotent retry re-discovers PRs even when the issue marker is already absent.
clear_marker issue "$issue" "$tmp/issue.json"
while IFS= read -r delivery; do
    clear_marker pr "$delivery" "$tmp/pr-$delivery.json"
done <"$tmp/prs-sorted"
