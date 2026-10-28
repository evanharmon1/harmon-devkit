#!/usr/bin/env bash
# claim-release-merged.sh — process delivery references after a PR ends.
# CLAIM_RELEASE_EVENT: merged (default) or closed-unmerged.
# CLAIM_RELEASE_ACTION: release (default) or clear-needs-review. The latter
# is independent of claim attribution and no-ops when its helper is absent.
#
# A PR may complete one work unit while its issue stays open for a later phase
# or a HUMAN criterion.  This script joins GitHub's closing references with
# conservative same-repo #N references in the PR body, then leaves attribution
# to release-claim.sh's --branch check.  It never changes issue completion.
set -euo pipefail

event="${CLAIM_RELEASE_EVENT:-merged}"
action="${CLAIM_RELEASE_ACTION:-release}"
case "$event" in
merged)
    event_time="${MERGED_AT:-}"
    reason="merged (claiming work unit complete)"
    ;;
closed-unmerged)
    event_time="${CLOSED_AT:-}"
    reason="closed without merging"
    ;;
*)
    echo "unknown claim release event: $event" >&2
    exit 2
    ;;
esac
case "$action" in
release) release_script="${RELEASE_CLAIM_SCRIPT:-./.claude/skills/track-work/assets/release-claim.sh}" ;;
clear-needs-review)
    release_script="${CLEAR_NEEDS_REVIEW_SCRIPT:-./.claude/skills/track-work/assets/clear-needs-review.sh}"
    if [ ! -e "$release_script" ]; then
        echo "needs-review helper is not vendored — nothing to clear"
        exit 0
    fi
    ;;
*)
    echo "unknown claim release action: $action" >&2
    exit 2
    ;;
esac
for required in GH_REPO PR_NUMBER HEAD_REF event_time; do
    [ -n "${!required:-}" ] || {
        echo "$required is required" >&2
        exit 2
    }
done

[ -e "$release_script" ] || {
    echo "release-claim script is missing: $release_script" >&2
    exit 2
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
issues_file="$tmp/issues"
: >"$issues_file"
job_rc=0

if [ "$event" = closed-unmerged ]; then
    pr_state="$(gh pr view "$PR_NUMBER" --repo "$GH_REPO" --json state --jq .state)"
    if [ "$pr_state" != CLOSED ]; then
        echo "PR #$PR_NUMBER is $pr_state again — the close event is stale"
        exit 0
    fi
fi
if [ "$event" = closed-unmerged ] || [ "$action" = clear-needs-review ]; then
    # Keep same-repository closing links, including UI-only links that remain
    # open after non-default-base merges. A failed lookup must fail the job,
    # while still processing body-derived candidates through the shared parser.
    rc=0
    gh pr view "$PR_NUMBER" --repo "$GH_REPO" --json closingIssuesReferences \
        --jq '.closingIssuesReferences[]
              | select(.url | startswith("https://github.com/" + env.GH_REPO + "/"))
              | .number' >>"$issues_file" || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "PR #$PR_NUMBER: closingIssuesReferences lookup failed with exit $rc — continuing with body references" >&2
        job_rc="$rc"
    fi
fi

# Merged claim release stays body-only: UI-linked issues that GitHub closes
# are released by the issues-closed job. Merged cleanup reads closing links
# too, because a non-default-base merge closes nothing. Union those links
# with the body parser below, then clean only candidates that remain open.
# Treat PR-body text as data.  A candidate is a delivery reference — a
# reference keyword (Closes/Fixes/Resolves/Refs and their variants)
# immediately before a #N token or its repository-qualified same-repo form
# (this exact owner/repo, case-insensitively, preceded by a non-word
# character).  A bare #N with no keyword is an incidental mention: with one
# branch claiming several issues, "remaining work tracked in #M" must not
# submit #M for release, because the branch and timestamp checks prove
# ownership, never delivery.  Other repositories' owner/repo#N and URL
# fragments are excluded.  The release engine still owns every write decision
# through its timestamp and branch-bound claim-record checks.
# Prefer the close event's own body snapshot (PR_BODY, set by the workflow):
# a body edited after the close must not change what a delayed or retried run
# processes. The fetch is only the fallback for manual/backfill invocations.
if [ "${PR_BODY+set}" = set ]; then
    body="$PR_BODY"
else
    body="$(gh pr view "$PR_NUMBER" --repo "$GH_REPO" --json body --jq '.body // ""')"
fi
printf '%s\n' "$body" | awk -v repo="$GH_REPO" '
{
    for (i = 1; i <= length($0); i++) {
        if (substr($0, i, 1) != "#") {
            continue
        }
        # Try the qualified form first, independent of the character before
        # the # — a repository name may legally end in punctuation, so the
        # qualifier cannot be detected off that character alone.
        # GitHub owner/repo slugs are case-insensitive.
        start = 0
        qual_start = i - length(repo)
        if (qual_start >= 1 && tolower(substr($0, qual_start, length(repo))) == tolower(repo)) {
            qual_before = qual_start == 1 ? "" : substr($0, qual_start - 1, 1)
            if (qual_before == "" || qual_before !~ /[[:alnum:]_.\/-]/) {
                start = qual_start
            }
        }
        if (start == 0) {
            before = i == 1 ? "" : substr($0, i - 1, 1)
            if (before != "" && before ~ /[[:alnum:]_]/) {
                continue
            }
            start = i
        }
        j = i + 1
        while (j <= length($0) && substr($0, j, 1) ~ /[0-9]/) {
            j++
        }
        if (j == i + 1) {
            continue
        }
        after = j > length($0) ? "" : substr($0, j, 1)
        if (after != "" && after ~ /[[:alnum:]_]/) {
            continue
        }
        # Delivery keyword required immediately before the token, separated
        # by whitespace or a colon; a bare mention is not a candidate.
        k = start - 1
        sep = 0
        while (k >= 1 && substr($0, k, 1) ~ /[[:space:]:]/) {
            k--
            sep++
        }
        if (sep == 0) {
            continue
        }
        pre = tolower(substr($0, 1, k))
        if (pre !~ /(^|[^[:alnum:]_])(close[sd]?|fix(e[sd])?|resolve[sd]?|ref(s|erence[sd]?)?)$/) {
            continue
        }
        print substr($0, i + 1, j - i - 1)
        i = j - 1
    }
}' >>"$issues_file"

summary() {
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
    printf '%s\n' "$*" >>"$GITHUB_STEP_SUMMARY"
}

write_audit() {
    audit_issue="$1"
    audit_result="$2"
    # A body reference can name a number that is not a live issue (deleted, a
    # typo, a PR). The audit line must not abort the loop and starve the
    # releases of the PR's other referenced issues.
    issue_json="$(gh api "repos/$GH_REPO/issues/$audit_issue" 2>/dev/null || printf '{}')"
    issue_state="$(jq -r '.state // "unknown"' <<<"$issue_json")"
    remaining=0
    if [ "$issue_state" = "open" ]; then
        # Count every rendered unchecked task form GitHub supports: bulleted,
        # ordered, and blockquoted items alike (the shape guard:closing-keywords
        # uses); an informational count must not under-report HUMAN criteria.
        remaining="$(jq -r '.body // ""' <<<"$issue_json" |
            grep -Ec '^[[:space:]]*(>[[:space:]]*)*([-*+]|[0-9]+[.)])[[:space:]]+\[[[:space:]]\][[:space:]]' || true)"
    fi
    summary "### PR #$PR_NUMBER → issue #$audit_issue"
    summary "- Claim release: $audit_result"
    summary "- Issue state: $issue_state"
    if [ "$issue_state" = "open" ]; then
        summary "- Remaining unticked criteria: $remaining"
    fi
}

# Bound the work: every candidate costs a release-engine run plus an audit
# API call inside a five-minute job. A body with more delivery references
# than this is pathological; process the cap, report the truncation loudly,
# and fail the job so a human reconciles the remainder — never truncate
# silently.
max_candidates="${CLAIM_RELEASE_MAX_CANDIDATES:-50}"
total_candidates="$(sort -nu "$issues_file" | grep -c . || true)"
if [ "$total_candidates" -gt "$max_candidates" ]; then
    dropped="$(sort -nu "$issues_file" | tail -n +"$((max_candidates + 1))" | tr '\n' ' ')"
    echo "truncating: $total_candidates delivery references exceed the $max_candidates-candidate cap; unprocessed: $dropped" >&2
    summary "### PR #$PR_NUMBER — candidate cap exceeded"
    summary "- Processed the first $max_candidates of $total_candidates references; unprocessed: $dropped"
    summary "- Re-run the release for the remainder by hand (release-claim.sh) or raise CLAIM_RELEASE_MAX_CANDIDATES."
    job_rc=5
fi
while IFS= read -r issue; do
    [ -n "$issue" ] || continue
    rc=0
    if [ "$action" = clear-needs-review ]; then
        if [ "$event" = merged ]; then
            # Both closing keywords and Refs can leave issues open (notably
            # on a non-default-base merge). The issue-close job covers only
            # issues GitHub actually closes; clear every still-open candidate.
            issue_json="$(gh api "repos/$GH_REPO/issues/$issue")" || rc=$?
            if [ "$rc" -ne 0 ]; then
                echo "issue #$issue: state lookup failed with exit $rc — continuing" >&2
                job_rc="$rc"
                continue
            fi
            [ "$(jq -r '.state' <<<"$issue_json")" = open ] || continue
        fi
        "$release_script" --repo "$GH_REPO" --issue "$issue" || rc=$?
        if [ "$rc" -ne 0 ]; then
            echo "issue #$issue: needs-review cleanup failed with exit $rc — continuing" >&2
            job_rc="$rc"
        fi
        continue
    fi
    "$release_script" \
        --repo "$GH_REPO" --issue "$issue" \
        --reason "PR #${PR_NUMBER} $reason" \
        --not-after "$event_time" --branch "$HEAD_REF" || rc=$?
    case "$rc" in
    0) write_audit "$issue" "released" ;;
    3) write_audit "$issue" "no attributable live claim" ;;
    *)
        write_audit "$issue" "failed (exit $rc)"
        echo "issue #$issue: release failed with exit $rc — continuing to the rest" >&2
        job_rc="$rc"
        ;;
    esac
done < <(sort -nu "$issues_file" | awk -v limit="$max_candidates" 'NR <= limit')

exit "$job_rc"
