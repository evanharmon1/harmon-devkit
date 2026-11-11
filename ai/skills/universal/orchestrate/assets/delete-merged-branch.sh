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
#   - EVERY fetch URL and EVERY push URL of the remote names that head
#     repository (a push goes to all of its push URLs);
#   - the local branch, when it exists, is not checked out in any worktree and
#     its tip is the PR's headRefOid or an ancestor of it. GitHub merged exactly
#     headRefOid, so that one property needs no file comparison, whether the
#     merge was a merge commit, a squash or a rebase;
#   - the remote branch is absent or exactly at headRefOid;
#   - one GitHub host is in play (no GH_HOST other than github.com, no
#     enterprise token), the history is unmodified (no refs/replace/ ref, no
#     info/grafts), and the local branch is not a symbolic ref.
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

lower() { printf '%s\n' "$1" | tr '[:upper:]' '[:lower:]'; }

# One host only: a gh read from another host would describe another repository.
if [ -n "${GH_HOST:-}" ] && [ "$(lower "$GH_HOST")" != "github.com" ]; then
    refuse "GH_HOST is '$GH_HOST', not github.com"
fi
if [ -n "${GH_ENTERPRISE_TOKEN:-}" ] || [ -n "${GITHUB_ENTERPRISE_TOKEN:-}" ]; then
    refuse "an enterprise token is set; only github.com is supported"
fi

git rev-parse --git-dir >/dev/null 2>&1 || refuse "not inside a git checkout"

# Unmodified history only: replacement refs and grafts can make an unmerged
# commit look like an ancestor of the PR head (provision-lane.mjs refuses both).
export GIT_NO_REPLACE_OBJECTS=1
replace_refs="$(git for-each-ref --count=1 refs/replace/)" || refuse "could not list replacement refs"
[ -z "$replace_refs" ] || refuse "replacement refs exist; history is not trustworthy"
grafts="$(git rev-parse --path-format=absolute --git-path info/grafts)" || refuse "could not resolve info/grafts"
[ ! -e "$grafts" ] || refuse "info/grafts exists; history is not trustworthy"

pr_json="$(gh pr view "$pr" --repo "$repo" --json state,headRefName,headRefOid,mergeCommit,isCrossRepository,headRepository,headRepositoryOwner)" ||
    refuse "could not read PR #$pr"
state="$(jq -r '.state // ""' <<<"$pr_json")"
head_ref="$(jq -r '.headRefName // ""' <<<"$pr_json")"
head_oid="$(jq -r '.headRefOid // ""' <<<"$pr_json")"
merge_oid="$(jq -r '.mergeCommit.oid // ""' <<<"$pr_json")"
cross="$(jq -r '.isCrossRepository' <<<"$pr_json")"
head_repo="$(jq -r '(.headRepositoryOwner.login // "") + "/" + (.headRepository.name // "")' <<<"$pr_json")"
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

# urls_match <newline-separated URLs>: every one names the PR's head repository.
# A push goes to every push URL, so every one is checked, and an empty list fails.
urls_match() {
    local url
    while IFS= read -r url; do
        [ "$(remote_repo "$url" || true)" = "$want" ] || return 1
    done <<<"$1"
}
want="$(lower "$head_repo")"
fetch_urls="$(git remote get-url --all "$remote")" || refuse "could not resolve the fetch URLs of '$remote'"
push_urls="$(git remote get-url --push --all "$remote")" || refuse "could not resolve the push URLs of '$remote'"
urls_match "$fetch_urls" || refuse "a fetch URL of '$remote' is not $head_repo"
urls_match "$push_urls" || refuse "a push URL of '$remote' is not $head_repo"

# The head commit must be readable locally; fetch it from the verified remote.
if ! git cat-file -e "$head_oid^{commit}" 2>/dev/null; then
    git fetch --quiet "$remote" "$head_oid" >/dev/null 2>&1 || true
    git cat-file -e "$head_oid^{commit}" 2>/dev/null || refuse "head commit $head_oid is not available"
fi

local_tip=""
if git show-ref --verify --quiet "refs/heads/$branch"; then
    if git symbolic-ref -q "refs/heads/$branch" >/dev/null; then
        refuse "local '$branch' is a symbolic ref"
    fi
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
    git update-ref --no-deref -d "refs/heads/$branch" "$local_tip" || {
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
