#!/usr/bin/env bash
# delete-merged-branch.sh — delete a verified merged lane's branch, local then
# remote, and nothing else. This is the one implementation of § Lane teardown
# step 3 in the orchestrate skill; the skill states the properties, this script
# enforces them.
#
# usage: delete-merged-branch.sh <owner/repo> <pr-number> <branch> [<remote>]
#   Run from inside the repository checkout (any worktree); <remote> defaults
#   to origin. Needs git, gh and jq.
#
# It refuses, deleting nothing, unless ALL of these hold on live reads:
#   - the PR is MERGED, its head branch is <branch>, it has a merge commit, it
#     is not cross-repository, and its head repository is <owner/repo>;
#   - <branch> is not the repository's default branch;
#   - no open PR has <branch> as its head;
#   - the remote's fetch URL AND push URL both name that head repository;
#   - the local branch, when it exists, is not checked out in any worktree and
#     its tip is the PR's headRefOid or an ancestor of it. GitHub merged exactly
#     headRefOid, so that one property needs no file comparison, whether the
#     merge was a merge commit, a squash or a rebase;
#   - the remote branch is absent or exactly at headRefOid.
# The local branch is deleted with its captured tip as the expected value, and
# the remote branch with a lease on headRefOid, so a commit or push that lands
# after the read makes the delete fail instead of being discarded. A branch
# already absent (deleted by the host, or never created locally) is a success.
#
# Exit: 0 deleted or already absent; 2 usage; 3 refused, nothing deleted
# (precondition failed or indeterminate); 4 a deletion itself failed.
set -euo pipefail

usage() {
    echo "usage: ${0##*/} <owner/repo> <pr-number> <branch> [<remote>]" >&2
    exit 2
}

refuse() {
    echo "refused: $*" >&2
    exit 3
}

[ "$#" -ge 3 ] && [ "$#" -le 4 ] || usage
repo="$1"
pr="$2"
branch="$3"
remote="${4:-origin}"
case "$pr" in '' | *[!0-9]*) usage ;; esac
case "$branch" in '' | -* | *' '*) usage ;; esac

git rev-parse --git-dir >/dev/null 2>&1 || refuse "not inside a git checkout"

pr_json="$(gh pr view "$pr" --repo "$repo" --json state,headRefName,headRefOid,mergeCommit,isCrossRepository,headRepository,headRepositoryOwner)" ||
    refuse "could not read PR #$pr"
state="$(jq -r '.state // ""' <<<"$pr_json")"
head_ref="$(jq -r '.headRefName // ""' <<<"$pr_json")"
head_oid="$(jq -r '.headRefOid // ""' <<<"$pr_json")"
merge_oid="$(jq -r '.mergeCommit.oid // ""' <<<"$pr_json")"
cross="$(jq -r '.isCrossRepository' <<<"$pr_json")"
head_repo="$(jq -r '(.headRepositoryOwner.login // "") + "/" + (.headRepository.name // "")' <<<"$pr_json")"
lower() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; }
[ "$state" = "MERGED" ] || refuse "PR #$pr is '$state', not MERGED"
[ "$head_ref" = "$branch" ] || refuse "PR #$pr head is '$head_ref', not '$branch'"
[ -n "$head_oid" ] && [ -n "$merge_oid" ] || refuse "PR #$pr carries no head or merge commit"
[ "$cross" = "false" ] || refuse "PR #$pr is cross-repository or its kind is unknown"
[ "$(lower "$head_repo")" = "$(lower "$repo")" ] || refuse "PR #$pr head repository is '$head_repo', not '$repo'"

default_json="$(gh repo view "$repo" --json defaultBranchRef)" ||
    refuse "could not read the default branch of $repo"
default_branch="$(jq -r '.defaultBranchRef.name // ""' <<<"$default_json")"
[ -n "$default_branch" ] || refuse "default branch of $repo is unknown"
[ "$branch" != "$default_branch" ] || refuse "'$branch' is the default branch"

open_json="$(gh pr list --repo "$repo" --head "$branch" --state open --json number)" ||
    refuse "could not list open PRs headed by '$branch'"
open_count="$(jq -r 'length' <<<"$open_json")"
[ "$open_count" = "0" ] || refuse "an open PR still has '$branch' as its head"

# remote_repo <url>: owner/repo of a github.com URL, lower-cased, or fail. The
# same forms as fence-check.sh; the host is case-insensitive, so lower-case first
# (a tr, not ${var,,}, to stay portable to bash 3.2).
remote_repo() {
    local url
    url="$(lower "$1")"
    case "$url" in
    https://github.com/*) url="${url#https://github.com/}" ;;
    http://github.com/*) url="${url#http://github.com/}" ;;
    git@github.com:*) url="${url#git@github.com:}" ;;
    ssh://git@github.com/*) url="${url#ssh://git@github.com/}" ;;
    ssh://git@ssh.github.com:443/*) url="${url#ssh://git@ssh.github.com:443/}" ;;
    ssh://git@ssh.github.com/*) url="${url#ssh://git@ssh.github.com/}" ;;
    *) return 1 ;;
    esac
    url="${url%/}"
    printf '%s\n' "${url%.git}"
}

# Both URLs must name the PR's head repository; a push URL can differ.
fetch_url="$(git remote get-url "$remote")" || refuse "could not resolve the fetch URL of '$remote'"
push_url="$(git remote get-url --push "$remote")" || refuse "could not resolve the push URL of '$remote'"
want="$(lower "$head_repo")"
[ "$(remote_repo "$fetch_url" || true)" = "$want" ] || refuse "fetch URL of '$remote' is not $head_repo"
[ "$(remote_repo "$push_url" || true)" = "$want" ] || refuse "push URL of '$remote' is not $head_repo"

# The head commit must be readable locally; fetch it from the verified remote.
if ! git cat-file -e "$head_oid^{commit}" 2>/dev/null; then
    git fetch --quiet "$remote" "$head_oid" >/dev/null 2>&1 || true
    git cat-file -e "$head_oid^{commit}" 2>/dev/null || refuse "head commit $head_oid is not available"
fi

local_tip=""
if git show-ref --verify --quiet "refs/heads/$branch"; then
    local_tip="$(git rev-parse "refs/heads/$branch^{commit}")"
    if [ "$local_tip" != "$head_oid" ] && ! git merge-base --is-ancestor "$local_tip" "$head_oid"; then
        refuse "local '$branch' at $local_tip is not the PR head $head_oid or an ancestor of it"
    fi
    checked_out="$(git worktree list --porcelain)" || refuse "could not list worktrees"
    if grep -qxF "branch refs/heads/$branch" <<<"$checked_out"; then
        refuse "'$branch' is checked out in a worktree"
    fi
fi

remote_line="$(git ls-remote "$remote" "refs/heads/$branch")" || refuse "could not read $remote"
remote_oid="${remote_line%%[[:space:]]*}"
if [ -n "$remote_oid" ] && [ "$remote_oid" != "$head_oid" ]; then
    refuse "remote '$branch' is at $remote_oid, not the PR head $head_oid"
fi

# Every precondition held. Delete the local branch, then the remote one.
if [ -n "$local_tip" ]; then
    git update-ref -d "refs/heads/$branch" "$local_tip" || {
        echo "failed: local '$branch' moved or could not be deleted" >&2
        exit 4
    }
    git config --remove-section "branch.$branch" 2>/dev/null || true
    echo "deleted local $branch ($local_tip)"
else
    echo "local $branch already absent"
fi

if [ -z "$remote_oid" ]; then
    echo "remote $branch already absent"
    exit 0
fi

if git push --quiet --force-with-lease="refs/heads/$branch:$head_oid" "$remote" ":refs/heads/$branch"; then
    echo "deleted remote $branch ($head_oid)"
    exit 0
fi

# The delete failed. If the host removed the branch in the meantime, that is
# the outcome we wanted; any other state is reported, never retried.
after="$(git ls-remote "$remote" "refs/heads/$branch" 2>/dev/null)" || after="?"
if [ -z "$after" ]; then
    echo "remote $branch already absent"
    exit 0
fi
echo "failed: remote '$branch' was not deleted (it moved or the push was refused)" >&2
exit 4
