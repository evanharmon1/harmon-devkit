#!/usr/bin/env bash
# groom-scan.sh — read-only backlog scanner for the groom skill. Writes nothing,
# ever. Emits one JSON dataset with everything the fan-out subagents and the
# report need precomputed: open issues (with age, bot-ownership, and title
# health already flagged), milestones, and whether the project board is
# readable at all — noted rather than guessed at, per issue #1015.
#
# Title health reuses the SAME shared predicate check-issue-metadata.sh and
# triage-scan.sh both call (issue-title-support/assets/issue-title.jq) rather
# than shelling out to check-issue-metadata.sh per issue: the module IS the
# logic check-issue-metadata.sh runs, and a per-issue subprocess over a
# multi-hundred-issue backlog is the exact cost triage-scan.sh already avoids
# the same way.
#
# Usage:
#   groom-scan.sh --repo owner/repo [--limit N] [--out PATH]
#
# --out writes the scan itself (bound under GROOM_SCRATCH when the wrapper set
# it, same convention as triage-scan.sh) so the caller never needs a shell
# redirection.
#
# --limit defaults to 5000 (issue #1015's own motivating repo had 384 open
# issues). A result that comes back AT the limit is refused outright rather
# than silently truncated — "verify every open issue" cannot be honored on a
# partial list, and a dropped/dead truncation flag defeats the point of
# noting it at all (challenge round 1 finding 2). Pass a higher --limit to
# proceed on a backlog that large.
#
# Exit: 0 = scan emitted, 2 = usage/environment error, 4 = refused (repo or
#       out-path outside this run's binding, or the open-issue count hit
#       --limit).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
title_module_dir="$script_dir/../../issue-title-support/assets"

usage() {
    echo "Usage: $0 --repo owner/repo [--limit N] [--out PATH]" >&2
    exit 2
}

die() {
    echo "groom-scan: $*" >&2
    exit 2
}

# Same reasoning as triage-scan.sh: a run bound to one repository must never
# read or publish another repository's issue data into this run's scratch dir.
guard_repo_binding() {
    local repo="$1"
    if [ -n "${GROOM_REPO:-}" ] && [ "$repo" != "$GROOM_REPO" ]; then
        echo "groom-scan: refused: --repo '$repo' does not match this run's" \
            "bound repository '$GROOM_REPO'" >&2
        exit 4
    fi
}

guard_out_path() {
    local out="$1" out_abs
    [ -n "$out" ] || return 0
    [ -n "${GROOM_SCRATCH:-}" ] || return 0
    out_abs="$(cd "$(dirname "$out")" 2>/dev/null && pwd)/$(basename "$out")" || {
        echo "groom-scan: could not resolve --out path" >&2
        exit 2
    }
    case "$out_abs" in
    "$GROOM_SCRATCH"/*) ;;
    *)
        echo "groom-scan: refused: --out must live under this run's scratch" \
            "directory ($GROOM_SCRATCH)" >&2
        exit 4
        ;;
    esac
}

[ -r "$title_module_dir/issue-title.jq" ] ||
    die "shared issue-title predicate is missing"

repo=""
limit=5000
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo)
        [ "$#" -ge 2 ] || usage
        repo="$2"
        shift 2
        ;;
    --limit)
        [ "$#" -ge 2 ] || usage
        limit="$2"
        shift 2
        ;;
    --out)
        [ "$#" -ge 2 ] || usage
        out="$2"
        shift 2
        ;;
    *) usage ;;
    esac
done
[ -n "$repo" ] || usage
guard_repo_binding "$repo"
guard_out_path "$out"

open_fields="number,title,body,labels,milestone,assignees,author,createdAt,updatedAt"
open_json="$(gh issue list --repo "$repo" --state open --limit "$limit" \
    --json "$open_fields")" ||
    die "could not list open issues of $repo"

open_count="$(jq length <<<"$open_json")"
if [ "$open_count" -ge "$limit" ]; then
    echo "groom-scan: refused: gh issue list returned $open_count open issue(s)," \
        "at or above --limit $limit — this run cannot verify every open issue" \
        "at that limit; pass a higher --limit to proceed" >&2
    exit 4
fi

# Board access needs the `project` scope; note whether it is usable instead of
# guessing (issue #1015's scan phase).
board_access="unavailable: gh project list requires the project scope"
owner="${repo%%/*}"
if gh project list --owner "$owner" --format json >/dev/null 2>&1; then
    board_access="available"
fi

# Issue bodies at real-repo scale can exceed ARG_MAX via --argjson; a temp file
# + --slurpfile read does not share that limit (same fix triage-scan.sh uses).
scan_tmp="$(mktemp -d)" || die "could not create a temp directory"
trap 'rm -rf "$scan_tmp"' EXIT
printf '%s' "$open_json" >"$scan_tmp/open.json"

# --paginate on an array-shaped endpoint writes ONE JSON array per page to
# stdout, concatenated back to back — it does NOT merge pages into a single
# array, and it does NOT unwrap each page into a stream of bare elements
# (confirmed against `gh api --help` and gh 2.98.0's actual output; Codex
# review on PR #1032, comment 4011648559). --slurpfile then reads every
# top-level JSON value in the file into its own array slot, so
# $milestones_arr ends up as an array of PAGE ARRAYS — even for a single
# page, since slurpfile always wraps top-level values in its own outer
# array. Flatten with `$milestones_arr[] | .[]` below to get each milestone
# object regardless of how many pages were emitted; a failed call or an
# empty `[]` page still flattens to nothing.
gh api "repos/$repo/milestones" --paginate -X GET -f state=all \
    -f per_page=100 >"$scan_tmp/milestones.pages" 2>/dev/null ||
    : >"$scan_tmp/milestones.pages"

[ -z "$out" ] || exec >"$out"

jq -n -L "$title_module_dir" \
    --arg repo "$repo" \
    --arg board_access "$board_access" \
    --slurpfile open_arr "$scan_tmp/open.json" \
    --slurpfile milestones_arr "$scan_tmp/milestones.pages" '
  include "issue-title";
  ($open_arr[0]) as $open |
  {
    repo: $repo,
    board_access: $board_access,
    open_total: ($open | length),
    milestones:
      [ $milestones_arr[] | .[] | {number, title, state, description,
                          open_issues: .open_issues, closed_issues: .closed_issues} ],
    open:
      [ $open[]
        | (((now - (.updatedAt | fromdateiso8601)) / 86400) | floor) as $updated_days
        | (((now - (.createdAt | fromdateiso8601)) / 86400) | floor) as $age_days
        | ((.author.type == "Bot") or (.author.is_bot == true)
           or (.author.login == "app/renovate")
           or ((.author.login // "") | test("^app/|\\[bot\\]$"))) as $bot_owned
        | {
            number, title,
            body: (.body // ""),
            labels: [.labels[].name],
            milestone: (.milestone.title // null),
            assignees: [.assignees[].login],
            author_login: (.author.login // null),
            bot_owned: $bot_owned,
            createdAt, updatedAt,
            age_days: $age_days,
            days_since_update: $updated_days,
            title_valid: (.title | issue_title_valid),
            title_warn: (.title | issue_title_warn)
          }
      ]
  }'
