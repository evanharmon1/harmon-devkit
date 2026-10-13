#!/usr/bin/env bash
# guard-closing-keywords.sh — assemble the commit range and PR metadata that
# check-closing-keywords.sh needs, then run it.
#
# Why a script and not inline Taskfile `cmds:`: inline command strings are not
# seen by shellcheck/shfmt (`lint:shell` only covers `scripts/*.sh`), so this
# logic — traps, temp files, `git log`, `gh api` — was unlinted and untestable
# where it used to live (harmon-init#1196). The Taskfile target is now a
# one-liner that calls this file.
#
# Where it runs:
#   - CI (`closing-keywords.yml`) supplies PR metadata from the event payload
#     and never invokes this script; it calls check-closing-keywords.sh with a
#     trusted default-branch copy of that program.
#   - Locally, as the pre-PR pre-flight documented in AGENTS.md beside
#     `guard:release-title`, and as the first step of `task ci`.
#
# Inputs (all optional; every one has a documented fallback):
#   BASE_SHA   base commit-ish for the range          (default: origin/main)
#   HEAD_SHA   head commit-ish for the range          (default: HEAD)
#   PR_TITLE   the PR title  — see "PR metadata" below
#   PR_BODY    the PR body   — see "PR metadata" below
#   GH_REPO    [HOST/]OWNER/REPO — gh's own documented form, and the only
#              input read here; it is resolved through gh_rest_repo, which
#              drops any HOST/ segment so endpoints stay repos/OWNER/REPO.
#              The host is not lost: it travels separately, as the
#              --hostname gh_rest_api derives from gh_rest_host.
#              (default: the current git remote)
#
# PR metadata: both PR_TITLE and PR_BODY are used verbatim when BOTH are set —
# which is how you pre-flight a title/body you have not published yet:
#
#   PR_TITLE="fix: …" PR_BODY="$(cat body.md)" task guard:closing-keywords
#
# If either is unset, the open PR for the current branch supplies both. That PR
# is found by selecting the bounded open-PR listing LOCALLY on
# .head.ref == the branch name and NOTHING else — the semantics of the
# `gh pr list --head "$branch"` this replaced. The filter runs here rather than
# server side because a `head=OWNER:branch` query built from the BASE
# repository's owner matches no PR opened from a fork, which silently demoted a
# real fork PR to the placeholder metadata below (challenge r3); a local match
# on the ref has never had that blind spot. The ref is the whole selector: the
# local head SHA used to narrow a ref several open PRs share, and that read the
# wrong PR's title and body whenever the branch's own PR had advanced remotely
# while an unrelated same-ref PR still carried this checkout's stale commit
# (challenge r5). Two forks can share a ref, and telling their PRs apart needs
# head-repository identity this checkout does not have — so several matches take
# the fail-closed path below. Refusing is the honest answer; guessing is not.
#
# Before a PR exists, a successful, COMPLETE and empty listing substitutes inert
# placeholder metadata so the commit messages are still scanned. Two things are
# indeterminate instead: a failed listing, and one that filled its bound without
# matching — a partial list cannot witness an absence, and grading it as "no PR"
# would quietly demote this guard to a commit-only scan (the invariant the
# status.sh inventories encode, challenge r2). Commit messages are read as data,
# never executed.
#
# Exit: 0 = ok, 1 = violation, 2 = indeterminate (refused to guess).
set -euo pipefail

# Resolve the sibling checker from THIS script's directory rather than $PWD:
# the Taskfile always runs from the repo root, but a hand-run from a
# subdirectory would otherwise fail with a confusing "no such file".
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
# shellcheck source=scripts/lib/gh-rest.sh
. "${script_dir}/lib/gh-rest.sh"

commits_file=$(mktemp)
trap 'rm -f "$commits_file"' EXIT

base_sha="${BASE_SHA:-origin/main}"
head_sha="${HEAD_SHA:-HEAD}"

if ! merge_base="$(git merge-base "$base_sha" "$head_sha")" || [ -z "$merge_base" ]; then
    echo "guard:closing-keywords: could not resolve merge-base for ${base_sha} and ${head_sha}; refusing to scan an indeterminate commit range" >&2
    exit 2
fi
if ! commit_count="$(git rev-list --count "${merge_base}..${head_sha}")"; then
    echo "guard:closing-keywords: could not count commits in ${merge_base}..${head_sha}; refusing an indeterminate range" >&2
    exit 2
fi
if [ "$commit_count" -gt 250 ]; then
    echo "guard:closing-keywords: PR range has ${commit_count} commits, exceeding the workflow's 250-commit API limit" >&2
    exit 1
fi
git log --format=%B "${merge_base}..${head_sha}" >"$commits_file"

if [ -z "${PR_TITLE+x}" ] || [ -z "${PR_BODY+x}" ]; then
    branch="$(git branch --show-current)"
    repo="$(gh_rest_repo 2>/dev/null || true)"
    # One page of open PRs, newest first. The 100 is spelled out at each of the
    # four places it appears rather than held in a variable: test:tasks pins the
    # helper call's bound as a literal shape assertion, exactly as it pins
    # status.sh's three. `filled` reports the listing arriving AT that bound,
    # which leaves both a no-match and a lone-match result unproven rather than
    # settled.
    if [ -z "$branch" ] || [ -z "$repo" ] ||
        ! pr_json="$(gh_rest_paginate_array "repos/${repo}/pulls?state=open&sort=updated&direction=desc" 100 |
            jq -s --arg branch "$branch" --argjson limit 100 '
                (add // []) as $open
                | [$open[] | select(.head.ref == $branch)]
                | {filled: (($open | length) >= $limit), prs: map({title, body})}')"; then
        echo "guard:closing-keywords: could not list PR metadata for the current branch; supply both PR_TITLE and PR_BODY" >&2
        exit 2
    fi
    pr_count="$(printf '%s' "$pr_json" | jq '.prs | length')"
    if [ "$pr_count" -gt 1 ]; then
        echo "guard:closing-keywords: multiple open PRs match branch ${branch}; supply both PR_TITLE and PR_BODY" >&2
        exit 2
    elif [ "$pr_count" -eq 1 ] && [ "$(printf '%s' "$pr_json" | jq -r '.filled')" = true ]; then
        # Uniqueness and absence are the same claim about the same incomplete
        # read: the page came back full, so a second PR on this ref may be
        # sitting on the page nobody asked for, and the lone match is unique
        # only within the bound.
        echo "guard:closing-keywords: open-PR listing filled its 100-PR bound with one match for ${branch}; uniqueness is unproven — supply both PR_TITLE and PR_BODY" >&2
        exit 2
    elif [ "$pr_count" -eq 1 ]; then
        PR_TITLE="$(printf '%s' "$pr_json" | jq -r '.prs[0].title')"
        PR_BODY="$(printf '%s' "$pr_json" | jq -r '.prs[0].body // ""')"
    elif [ "$(printf '%s' "$pr_json" | jq -r '.filled')" = true ]; then
        # An incomplete read is not an absence: the page came back full, so an
        # older branch's PR may be sitting on the page nobody asked for.
        echo "guard:closing-keywords: open-PR listing filled its 100-PR bound with no match for ${branch}; absence is unproven — supply both PR_TITLE and PR_BODY" >&2
        exit 2
    else
        echo "guard:closing-keywords: no open PR for ${branch}; checking commits with inert pre-PR metadata" >&2
        PR_TITLE="Pre-PR local CI"
        PR_BODY="No pull request body exists yet."
    fi
fi
export PR_TITLE PR_BODY

if ! repo="$(gh_rest_repo)"; then
    echo "guard:closing-keywords: could not resolve owner/repository from the current remote" >&2
    exit 2
fi

"$script_dir/check-closing-keywords.sh" --repo "$repo" \
    --title-env PR_TITLE --body-env PR_BODY --commits-file "$commits_file"
