#!/usr/bin/env bash
# clear-needs-review.sh — clear an issue and its delivery PRs, independently of claims.
set -euo pipefail

usage() {
    echo "Usage: clear-needs-review.sh --repo OWNER/NAME --issue N [--pr N] [--branch BRANCH]"
}

repo=""
issue=""
pr=""
branch=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --issue | --pr | --branch)
        if [ "$#" -lt 2 ]; then
            usage >&2
            exit 2
        fi
        case "$1" in
        --repo) repo="$2" ;;
        --issue) issue="$2" ;;
        --pr) pr="$2" ;;
        --branch) branch="$2" ;;
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

if [ -n "$branch" ] && ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    echo "Expected a valid claim branch." >&2
    exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Read every candidate before writing. Closing links cover issue-close callers;
# the claim branch additionally identifies Refs deliveries without event context.
gh issue view "$issue" --repo "$repo" --json labels,closedByPullRequestsReferences >"$tmp/issue.json"
jq -er '.labels | type == "array"' "$tmp/issue.json" >/dev/null
jq -r --arg prefix "https://${GH_HOST:-github.com}/$repo/pull/" '
    .closedByPullRequestsReferences[]?
    | select((.url | ascii_downcase) | startswith($prefix | ascii_downcase))
    | .number
' "$tmp/issue.json" >"$tmp/candidates"
if [ -n "$branch" ]; then
    gh pr list --repo "$repo" --state open --head "$branch" --limit 100 \
        --json number,headRefName,isCrossRepository >"$tmp/branch-prs.json"
    jq -e 'type == "array" and length < 100' "$tmp/branch-prs.json" >/dev/null
    jq -r --arg branch "$branch" '.[] | select(.headRefName == $branch and .isCrossRepository == false) | .number' \
        "$tmp/branch-prs.json" >>"$tmp/candidates"
fi
[ -z "$pr" ] || printf '%s\n' "$pr" >>"$tmp/candidates"
sort -un "$tmp/candidates" >"$tmp/all-prs"
if [ -n "$pr" ]; then
    printf '%s\n' "$pr" >"$tmp/selected-prs"
else
    cp "$tmp/all-prs" "$tmp/selected-prs"
fi
while IFS= read -r delivery; do
    [[ "$delivery" =~ ^[1-9][0-9]*$ ]] || exit 2
    gh pr view "$delivery" --repo "$repo" --json labels,state,isCrossRepository >"$tmp/pr-$delivery.json"
    jq -e '.labels | type == "array"' "$tmp/pr-$delivery.json" >/dev/null
done <"$tmp/all-prs"

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

# Never clear an unrelated delivery. Clear selected PRs first; only then decide
# whether another open delivery still needs the issue-level marker.
while IFS= read -r delivery; do
    clear_marker pr "$delivery" "$tmp/pr-$delivery.json"
done <"$tmp/selected-prs"
keep_issue=0
while IFS= read -r delivery; do
    grep -Fxq "$delivery" "$tmp/selected-prs" && continue
    gh pr view "$delivery" --repo "$repo" --json labels,state,isCrossRepository >"$tmp/sibling.json"
    if jq -e '.state == "OPEN" and .isCrossRepository == false
        and any(.labels[]; (.name | ascii_downcase) == "needs-review")' "$tmp/sibling.json" >/dev/null; then
        keep_issue=1
    fi
done <"$tmp/all-prs"
if [ "$keep_issue" -eq 0 ]; then
    clear_marker issue "$issue" "$tmp/issue.json"
else
    echo "needs-review retained on issue: another open delivery PR still owes review" >&2
fi
