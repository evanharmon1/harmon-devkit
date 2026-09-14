#!/usr/bin/env bash
# groom-decide.sh — record one maintainer decision: post the dated decision
# comment, close every named superseded sibling as "not planned" with a
# pointer comment, and add blocked-by edges. This is the step that used to be
# done by hand ~20 times per groom run (issue #1015 criterion 5).
#
# Dry-run is the DEFAULT: prints "PLAN <exact gh command>" for every write and
# writes nothing. --execute additionally requires GROOM_EXECUTE=1 in the
# environment, same contract as groom-apply.sh and triage-apply.sh.
#
# Blocked-by edges use GitHub's issue-dependency REST endpoint, id-not-number
# (the same call ai/skills/universal/breakdown/SKILL.md §7 documents — no
# reusable helper script exists there to call instead):
#   gh api repos/<owner>/<repo>/issues/<blocked>/dependencies/blocked_by \
#     -F issue_id=<blocker's numeric id>
#
# Usage:
#   groom-decide.sh --repo owner/repo --issue N --decision-file PATH
#                    [--supersedes M]... [--blocked-by K]... [--execute]
#
# Exit: 0 = dry-run resolved or every write applied, 1 = a write failed,
#       2 = usage/environment error.
set -euo pipefail

usage() {
    echo "Usage: $0 --repo owner/repo --issue N --decision-file PATH" >&2
    echo "          [--supersedes M]... [--blocked-by K]... [--execute]" >&2
    exit 2
}

die() {
    local code="$1"
    shift
    echo "groom-decide: $*" >&2
    exit "$code"
}

guard_issue_number() {
    case "$1" in
    '' | *[!0-9]*) die 2 "refused: issue number must be plain digits (got '$1')" ;;
    esac
}

# Same run-binding as groom-apply.sh / triage-apply.sh.
guard_repo_binding() {
    local repo="$1"
    if [ -n "${GROOM_REPO:-}" ] && [ "$repo" != "$GROOM_REPO" ]; then
        die 4 "refused: --repo '$repo' does not match this run's bound" \
            "repository '$GROOM_REPO'"
    fi
}

repo=""
issue=""
decision_file=""
execute=0
supersedes=()
blocked_by=()
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo)
        [ "$#" -ge 2 ] || usage
        repo="$2"
        shift 2
        ;;
    --issue)
        [ "$#" -ge 2 ] || usage
        issue="$2"
        shift 2
        ;;
    --decision-file)
        [ "$#" -ge 2 ] || usage
        decision_file="$2"
        shift 2
        ;;
    --supersedes)
        [ "$#" -ge 2 ] || usage
        supersedes+=("$2")
        shift 2
        ;;
    --blocked-by)
        [ "$#" -ge 2 ] || usage
        blocked_by+=("$2")
        shift 2
        ;;
    --execute) execute=1 && shift ;;
    *) usage ;;
    esac
done
[ -n "$repo" ] && [ -n "$issue" ] && [ -n "$decision_file" ] || usage
guard_repo_binding "$repo"
guard_issue_number "$issue"
for m in "${supersedes[@]+"${supersedes[@]}"}"; do guard_issue_number "$m"; done
for k in "${blocked_by[@]+"${blocked_by[@]}"}"; do guard_issue_number "$k"; done
[ -r "$decision_file" ] || die 2 "cannot read decision file: $decision_file"

if [ "$execute" -eq 1 ]; then
    [ "${GROOM_EXECUTE:-0}" = "1" ] ||
        die 2 "--execute requires GROOM_EXECUTE=1 in the environment" \
            "(set by the task groom wrapper for supervised runs)"
fi

now="${GROOM_NOW_DATE:-$(date -u '+%Y-%m-%d')}"
comment_tmp="$(mktemp)" || die 2 "could not create a temp file"
trap 'rm -f "$comment_tmp"' EXIT
{
    printf 'Decision (maintainer, %s)\n\n' "$now"
    cat "$decision_file"
} >"$comment_tmp"

if [ "$execute" -eq 0 ]; then
    echo "PLAN gh issue comment $issue --repo $repo --body-file <decision-comment>"
else
    gh issue comment "$issue" --repo "$repo" --body-file "$comment_tmp" >/dev/null ||
        die 1 "write failed: decision comment on $repo#$issue"
    echo "APPLIED decision comment on $repo#$issue"
fi

for m in "${supersedes[@]+"${supersedes[@]}"}"; do
    pointer="Superseded by the decision on #$issue."
    if [ "$execute" -eq 0 ]; then
        echo "PLAN gh issue close $m --repo $repo --reason 'not planned' --comment '$pointer'"
    else
        gh issue close "$m" --repo "$repo" --reason "not planned" --comment "$pointer" >/dev/null ||
            die 1 "write failed: close $repo#$m"
        echo "APPLIED close $repo#$m (superseded by #$issue)"
    fi
done

for k in "${blocked_by[@]+"${blocked_by[@]}"}"; do
    if [ "$execute" -eq 0 ]; then
        echo "PLAN gh api repos/$repo/issues/$issue/dependencies/blocked_by -F issue_id=<id of #$k>"
    else
        blocker_id="$(gh api "repos/$repo/issues/$k" --jq .id)" ||
            die 1 "could not resolve the numeric id of $repo#$k"
        gh api "repos/$repo/issues/$issue/dependencies/blocked_by" \
            -F issue_id="$blocker_id" >/dev/null ||
            die 1 "write failed: blocked-by edge $repo#$issue <- $repo#$k"
        echo "APPLIED blocked-by $repo#$issue <- $repo#$k"
    fi
done
