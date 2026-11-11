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
#   - the PR is MERGED, its head branch is <branch>, and it has a merge commit;
#   - <branch> is not the repository's default branch;
#   - no open PR has <branch> as its head;
#   - the ACTUAL local branch tip, when the local branch exists, is contained
#     in the merge: an ancestor of the merge commit, or, for a squash, tree-
#     identical to the merge commit on every path the branch changed since it
#     forked from the merge's first parent;
#   - the remote branch is absent or exactly at the PR's headRefOid.
# The remote branch is then deleted with a lease on headRefOid, so a push that
# lands between the read and the delete makes the delete fail instead of
# discarding it. A branch already absent (deleted by the host, or never created
# locally) is a success, not an error.
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

pr_json="$(gh pr view "$pr" --repo "$repo" --json state,headRefName,headRefOid,mergeCommit)" ||
    refuse "could not read PR #$pr"
state="$(jq -r '.state // ""' <<<"$pr_json")"
head_ref="$(jq -r '.headRefName // ""' <<<"$pr_json")"
head_oid="$(jq -r '.headRefOid // ""' <<<"$pr_json")"
merge_oid="$(jq -r '.mergeCommit.oid // ""' <<<"$pr_json")"
[ "$state" = "MERGED" ] || refuse "PR #$pr is '$state', not MERGED"
[ "$head_ref" = "$branch" ] || refuse "PR #$pr head is '$head_ref', not '$branch'"
[ -n "$head_oid" ] && [ -n "$merge_oid" ] || refuse "PR #$pr carries no head or merge commit"

default_json="$(gh repo view "$repo" --json defaultBranchRef)" ||
    refuse "could not read the default branch of $repo"
default_branch="$(jq -r '.defaultBranchRef.name // ""' <<<"$default_json")"
[ -n "$default_branch" ] || refuse "default branch of $repo is unknown"
[ "$branch" != "$default_branch" ] || refuse "'$branch' is the default branch"

open_json="$(gh pr list --repo "$repo" --head "$branch" --state open --json number)" ||
    refuse "could not list open PRs headed by '$branch'"
open_count="$(jq -r 'length' <<<"$open_json")"
[ "$open_count" = "0" ] || refuse "an open PR still has '$branch' as its head"

# The commits must be local to be compared; fetching is best effort and the
# existence check below is what decides.
git fetch --quiet "$remote" "$default_branch" >/dev/null 2>&1 || true
git fetch --quiet "$remote" "refs/pull/$pr/head" >/dev/null 2>&1 || true
git cat-file -e "$head_oid^{commit}" 2>/dev/null || refuse "head commit $head_oid is not available locally"
git cat-file -e "$merge_oid^{commit}" 2>/dev/null || refuse "merge commit $merge_oid is not available locally"

# contained <tip>: the tip's content is in the merge commit.
contained() {
    local tip="$1" base paths
    if git merge-base --is-ancestor "$tip" "$merge_oid"; then
        return 0
    fi
    base="$(git merge-base "$tip" "$merge_oid^" 2>/dev/null)" || return 1
    paths="$(git diff --name-only --no-renames "$base" "$tip")" || return 1
    [ -n "$paths" ] || return 1
    # Each changed path must read the same in the tip and in the merge commit.
    while IFS= read -r path; do
        git diff --quiet "$tip" "$merge_oid" -- "$path" || return 1
    done <<<"$paths"
    return 0
}

local_tip=""
if git show-ref --verify --quiet "refs/heads/$branch"; then
    local_tip="$(git rev-parse "refs/heads/$branch^{commit}")"
    contained "$local_tip" || refuse "local '$branch' at $local_tip has content that is not in the merge"
fi

remote_line="$(git ls-remote "$remote" "refs/heads/$branch")" || refuse "could not read $remote"
remote_oid="${remote_line%%[[:space:]]*}"
if [ -n "$remote_oid" ] && [ "$remote_oid" != "$head_oid" ]; then
    refuse "remote '$branch' is at $remote_oid, not the PR head $head_oid"
fi

# Every precondition held. Delete the local branch, then the remote one.
if [ -n "$local_tip" ]; then
    git branch -D "$branch" >/dev/null || {
        echo "failed: could not delete local '$branch'" >&2
        exit 4
    }
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
