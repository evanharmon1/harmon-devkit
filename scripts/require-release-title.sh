#!/usr/bin/env bash
# require-release-title.sh — fail a PR whose squash-merge title would silently
# skip a release even though the PR changes release-worthy content.
#
# Why: PRs are squash-merged and release-please reads ONLY the squash commit
# subject — which GitHub sets from the PR title for a multi-commit PR. A
# non-releasing title (chore/docs/ci/…) on a content change therefore merges
# with NO tag cut, so downstream consumers pinning a released tag never receive
# the change. This guard makes that loud at PR time instead of silent at merge
# time. See docs/conventions.md ("Releases").
#
# Usage:
#   PR_TITLE="<title>" [PR_BODY="…"] \
#   [CHANGED_FILES=$'a\nb'  |  BASE_SHA=<sha> [HEAD_SHA=<sha>]] \
#     require-release-title.sh PREFIX [PREFIX …]
#
# PREFIXes are release-worthy path prefixes: a literal directory that matches
# itself and everything beneath it (so `ai/skills` matches `ai/skills/x`, but
# NOT the sibling `ai/skills-extra`). Changed files come from $CHANGED_FILES
# (newline-separated) when set, else from `git diff --name-only BASE...HEAD`.
# A title is "releasing" iff its type is feat/fix, or it marks a breaking
# change (`!` before the colon, or a BREAKING CHANGE note in the body).
#
# Exit: 0 = ok (releasing title, or no release-worthy path touched, or no
#       prefixes configured), 1 = violation, 2 = usage error.
set -euo pipefail

# No prefixes configured -> the guard is inert (a repo that has not opted in).
if [ "$#" -eq 0 ]; then
    echo "require-release-title: no release-worthy path prefixes configured — nothing to guard"
    exit 0
fi

title="${PR_TITLE:-}"
[ -n "$title" ] || {
    echo "require-release-title: PR_TITLE is empty (set it to the PR title)" >&2
    exit 2
}

# is_releasing_title TITLE BODY — 0 when the title would cut a release.
is_releasing_title() {
    _rt_title="$1"
    _rt_body="${2:-}"
    # The conventional "type(scope)!" prefix is everything before the FIRST colon;
    # a title with no colon has no type line (only the body can declare breaking).
    case "$_rt_title" in
    *:*) _rt_head="${_rt_title%%:*}" ;;
    *) _rt_head="" ;;
    esac
    # Breaking change: a `!` immediately before that first colon (feat!:, fix(api)!:).
    # Matching a bare "!:" anywhere would let `chore: … !: …` bypass the guard.
    case "$_rt_head" in
    *"!") return 0 ;;
    esac
    # Breaking change footer in the body.
    case "$_rt_body" in
    *"BREAKING CHANGE"* | *"BREAKING-CHANGE"*) return 0 ;;
    esac
    # Leading conventional type (feat/fix), before an optional (scope).
    _rt_type="${_rt_head%%(*}"
    case "$_rt_type" in
    feat | fix) return 0 ;;
    *) return 1 ;;
    esac
}

if is_releasing_title "$title" "${PR_BODY:-}"; then
    echo "require-release-title: title is a releasing type — ok: ${title}"
    exit 0
fi

# Non-releasing title: only a problem if the PR touches release-worthy content.
if [ -n "${CHANGED_FILES+x}" ]; then
    files="$CHANGED_FILES"
else
    [ -n "${BASE_SHA:-}" ] || {
        echo "require-release-title: set CHANGED_FILES, or BASE_SHA for a git diff" >&2
        exit 2
    }
    files="$(git diff --name-only "${BASE_SHA}...${HEAD_SHA:-HEAD}")"
fi

matched=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    for prefix in "$@"; do
        prefix="${prefix%/}" # tolerate a configured prefix written as "dir/"
        case "$f" in
        "$prefix" | "$prefix"/*)
            matched="${matched}  - ${f}"$'\n'
            break
            ;;
        esac
    done
done <<EOF
${files}
EOF

if [ -z "$matched" ]; then
    echo "require-release-title: no release-worthy paths changed — ok: ${title}"
    exit 0
fi

paths_joined="$*"
cat >&2 <<EOF
require-release-title: this PR changes release-worthy content, but its title

    ${title}

is not a releasing type. Squash-merge uses the PR title as the commit subject,
and release-please only cuts a release for feat / fix / breaking changes — so as
titled, this would merge WITHOUT a release and downstream consumers pinning a
released tag would never receive it.

Release-worthy paths changed:
${matched}
Fix: retitle the PR with a releasing type —
    fix: …    (patch)      feat: …    (minor)      feat!: …    (major, breaking)
or, if this genuinely should not release, keep the change out of these prefixes:
    ${paths_joined}
EOF
exit 1
