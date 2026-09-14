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
# PREFLIGHT, before any write (challenge round 1 finding 7): every
# --supersedes target's live bot-ownership check, and — in --execute mode —
# every --blocked-by target's numeric id resolution, all run before the
# decision comment is posted. Posting the comment first and only then
# discovering a --supersedes target is bot-owned left the comment posted (and
# any earlier --supersedes sibling already closed) with no way to undo either
# once the run died — exactly the partial-application failure this script's
# own bot-ownership rule is meant to guard against.
#
# --outcomes FILE (optional) appends one JSON Lines record per applied write:
# {"issue":<decided-issue>,"op":"decision","status":"DECIDED <YYYY-MM-DD>","at":"<UTC>"}
# for the decided issue, and {"issue":<sibling>,"op":"close","status":"DONE",
# "at":"<UTC>"} for each closed --supersedes sibling — for groom-report.sh
# render --outcomes to merge into each row's `status` column (finding 8).
# Blocked-by edges are not disposition rows and get no outcome record.
#
# Blocked-by edges use GitHub's issue-dependency REST endpoint, id-not-number
# (the same call ai/skills/universal/breakdown/SKILL.md §7 documents — no
# reusable helper script exists there to call instead):
#   gh api repos/<owner>/<repo>/issues/<blocked>/dependencies/blocked_by \
#     -F issue_id=<blocker's numeric id>
#
# Usage:
#   groom-decide.sh --repo owner/repo --issue N --decision-file PATH
#                    [--supersedes M]... [--blocked-by K]... [--outcomes PATH]
#                    [--execute]
#
# Exit: 0 = dry-run resolved or every write applied, 1 = a write failed,
#       2 = usage/environment error, 4 = refused (a --supersedes target is
#       bot-authored).
set -euo pipefail

usage() {
    echo "Usage: $0 --repo owner/repo --issue N --decision-file PATH" >&2
    echo "          [--supersedes M]... [--blocked-by K]... [--outcomes PATH]" >&2
    echo "          [--execute]" >&2
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

write_outcome() {
    local outcomes="$1" issue="$2" op="$3" status="$4"
    [ -n "$outcomes" ] || return 0
    local at
    at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    jq -nc --argjson issue "$issue" --arg op "$op" --arg status "$status" --arg at "$at" \
        '{issue: $issue, op: $op, status: $status, at: $at}' >>"$outcomes"
}

repo=""
issue=""
decision_file=""
execute=0
outcomes=""
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
    --outcomes)
        [ "$#" -ge 2 ] || usage
        outcomes="$2"
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

# ── Preflight (finding 7): resolve everything that can fail BEFORE the first
# write. A maintainer decision names issue numbers, not authors, and a bot
# (Renovate/Dependabot) routinely files near-duplicates that would otherwise
# fit a "superseded by" close — SKILL.md's contract is unqualified that a
# bot-authored issue is never closed by groom, whatever the write path.
declare -A blocked_by_id=()
for m in "${supersedes[@]+"${supersedes[@]}"}"; do
    author_json="$(gh issue view "$m" --repo "$repo" --json author)" ||
        die 2 "could not read the author of $repo#$m"
    if jq -e '
        (.author.type == "Bot") or (.author.is_bot == true)
        or (.author.login == "app/renovate")
        or ((.author.login // "") | test("^app/|\\[bot\\]$"))
      ' <<<"$author_json" >/dev/null; then
        die 4 "refused: $repo#$m is bot-authored — groom never closes a bot-owned issue"
    fi
done
if [ "$execute" -eq 1 ]; then
    for k in "${blocked_by[@]+"${blocked_by[@]}"}"; do
        blocked_by_id["$k"]="$(gh api "repos/$repo/issues/$k" --jq .id)" ||
            die 1 "could not resolve the numeric id of $repo#$k"
    done
fi

# ── Writes. Every supersedes target and blocked-by id above has already been
# validated, so nothing here can fail partway through for a reason pass 1
# above should have caught.
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
    write_outcome "$outcomes" "$issue" "decision" "DECIDED $now"
fi

for m in "${supersedes[@]+"${supersedes[@]}"}"; do
    pointer="Superseded by the decision on #$issue."
    if [ "$execute" -eq 0 ]; then
        echo "PLAN gh issue close $m --repo $repo --reason 'not planned' --comment '$pointer'"
    else
        gh issue close "$m" --repo "$repo" --reason "not planned" --comment "$pointer" >/dev/null ||
            die 1 "write failed: close $repo#$m"
        echo "APPLIED close $repo#$m (superseded by #$issue)"
        write_outcome "$outcomes" "$m" "close" "DONE"
    fi
done

for k in "${blocked_by[@]+"${blocked_by[@]}"}"; do
    if [ "$execute" -eq 0 ]; then
        echo "PLAN gh api repos/$repo/issues/$issue/dependencies/blocked_by -F issue_id=<id of #$k>"
    else
        blocker_id="${blocked_by_id[$k]}"
        gh api "repos/$repo/issues/$issue/dependencies/blocked_by" \
            -F issue_id="$blocker_id" >/dev/null ||
            die 1 "write failed: blocked-by edge $repo#$issue <- $repo#$k"
        echo "APPLIED blocked-by $repo#$issue <- $repo#$k"
    fi
done
