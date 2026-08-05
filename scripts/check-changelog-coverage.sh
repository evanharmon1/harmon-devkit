#!/usr/bin/env bash
# check-changelog-coverage.sh — detect feat/fix commits a tag ships that its
# changelog section omits (swallowed entries).
#
# Release-please merge races can produce this: two merges land in quick
# succession, the first merge's release-please run fails, and the first merge's
# feat/fix commits land in a tag whose changelog entry never recorded them.
# This script compares the feat/fix commits in a tag's tree against the entries
# in its CHANGELOG.md section and reports any missing.
#
# Usage:
#   check-changelog-coverage.sh [TAG]
#
# TAG defaults to the latest tag (git describe --tags --abbrev=0).
# Exit: 0 = all covered (or nothing to check), 1 = swallowed entries found,
#       2 = usage/configuration error.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
changelog="${repo_root}/CHANGELOG.md"

# Resolve the tag separately from the parameter expansion so `set -e` does not
# abort the script when git-describe fails in a tagless repo — the intent is
# for the guard below to handle that case gracefully.
tag="${1:-}"
if [ -z "$tag" ]; then
    tag="$(git describe --tags --abbrev=0 --exclude="*-probe*" 2>/dev/null)" || true
fi
if [ -z "$tag" ]; then
    echo "check-changelog-coverage: no tags in this repo — nothing to check"
    exit 0
fi

# Validate that the tag (whether explicit or resolved) actually exists — a
# typo in an explicit tag should exit 2 (configuration error), not 1
# (swallowed entries) or exit silently on a pipefail.
if ! git rev-parse --verify "refs/tags/${tag}" >/dev/null 2>&1; then
    echo "check-changelog-coverage: ${tag} is not a valid tag" >&2
    exit 2
fi

# The changelog header uses the version WITHOUT the leading 'v'.
version="${tag#v}"

if [ ! -f "$changelog" ]; then
    echo "check-changelog-coverage: no CHANGELOG.md at repo root — nothing to check"
    exit 0
fi

# ── Find the previous tag ──────────────────────────────────────────
# Strategy 1: parse the compare URL from the tag's changelog section header.
# release-please headers:
#   ## [VERSION](https://github.com/OWNER/REPO/compare/PREV...VERSION) (DATE)
prev_tag=""
section="$(sed -n "/^## \[${version}\]/,/^## \[/p" "$changelog")"
if [ -n "$section" ]; then
    # Extract the compare URL from the header line (first line of the section).
    # Use sed to process only line 1 — avoids a head -1 pipeline that can
    # SIGPIPE on large sections with pipefail+set -e.
    compare_url="$(echo "$section" | sed -n '1s/.*compare\/\([^)]*\)).*/\1/p')"
    if [ -n "$compare_url" ]; then
        prev_tag="${compare_url%%...*}"
    fi
fi

# Strategy 2: fall back to the tag immediately before this one in the tag list.
if [ -z "$prev_tag" ]; then
    prev_tag="$(git tag --sort=-v:refname 2>/dev/null | grep -A1 "^${tag}$" | tail -1)"
fi

if [ -z "$prev_tag" ]; then
    echo "check-changelog-coverage: ${tag} is the first tag — nothing to check"
    exit 0
fi

# ── Collect feat/fix commits in the range ──────────────────────────
# Only commits whose subject starts with feat/fix (conventional commits),
# including breaking-change markers (! before the colon).  Uses --no-merges
# because this repo (and harmon-init's target repos) squash-merge, so each PR
# becomes a single non-merge commit on main whose subject is the PR title.
# In a merge-commit workflow the detector would miss entries; that is a known
# limitation.
commits="$(git log --no-merges --format='%h %s' --abbrev=7 "${prev_tag}..${tag}" \
    -E --grep='^(feat|fix)(\(.+\))?!?:' 2>/dev/null)" || {
    echo "check-changelog-coverage: unable to list commits in ${prev_tag}..${tag} — range may not exist in this checkout (shallow clone?)" >&2
    exit 2
}

if [ -z "$commits" ]; then
    echo "check-changelog-coverage: no feat/fix commits in ${prev_tag}..${tag}"
    exit 0
fi

# ── Build the set of covered identifiers from the changelog section ─
# release-please entries reference commits by short SHA and PR number:
#   * **scope:** desc ([#NNN](.../issues/NNN)) ([abcdef0](.../commit/abcdef0...))
# We collect both forms.

# Short SHAs from commit URLs in the changelog section: /commit/<full-sha>
# We capture only the first 7 hex chars (the short SHA) for comparison against
# `git log --format='%h'`.  The URL carries the full 40-char hash.
covered_shas="$(echo "$section" | sed -n 's|.*/commit/\([0-9a-f]\{7\}\)[0-9a-f]\{1,\}.*|\1|p' | sort -u)"

# PR numbers from issue/PR URLs in the changelog section: /issues/NNN or /pull/NNN
# Two separate patterns because BSD sed basic regex does not support \| alternation.
covered_prs="$(
    {
        echo "$section" | sed -n 's|.*/issues/\([0-9]\{1,\}\).*|#\1|p'
        echo "$section" | sed -n 's|.*/pull/\([0-9]\{1,\}\).*|#\1|p'
    } | sort -u
)"

# ── Check each commit ─────────────────────────────────────────────
swallowed=0
while IFS= read -r line; do
    [ -n "$line" ] || continue
    sha="${line%% *}"
    subject="${line#* }"

    # Check 1: short SHA appears in the changelog section.
    if echo "$covered_shas" | grep -qx "$sha" 2>/dev/null; then
        continue
    fi

    # Check 2: a GitHub PR number (#NNN) in the commit subject appears in the
    # changelog section.  Squash-merge appends the PR number to the subject line.
    pr="$(echo "$subject" | sed -n 's/.*(#\([0-9]\{1,\}\)).*/\1/p')"
    if [ -n "$pr" ] && echo "$covered_prs" | grep -qx "#${pr}" 2>/dev/null; then
        continue
    fi

    # Not found — swallowed.
    if [ "$swallowed" -eq 0 ]; then
        echo "Swallowed changelog entries in ${tag} (commits in ${prev_tag}..${tag}"
        echo "missing from the ${version} section of CHANGELOG.md):"
        echo
    fi
    swallowed=$((swallowed + 1))
    echo "  ${sha} ${subject}"
done <<EOF
${commits}
EOF

if [ "$swallowed" -eq 0 ]; then
    echo "check-changelog-coverage: all feat/fix commits in ${prev_tag}..${tag} appear in the ${version} changelog section"
    exit 0
fi

echo
echo "check-changelog-coverage: ${swallowed} swallowed entr${swallowed#1}y found — the tag ships these commits but the changelog section omits them."
echo "This can happen when two merges race and the first merge's release-please run fails."
echo "Fix: add the missing entries to the ${version} section of CHANGELOG.md."
exit 1
