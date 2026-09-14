#!/usr/bin/env bash
# groom-apply.sh — the groom skill's write path for everything triage-apply.sh
# and check-issue-metadata.sh do not already cover: closing issues, retitling
# (guarded by check-issue-metadata.sh --title-only --previous-title),
# assigning an existing milestone, and linking an existing sub-issue. Label
# writes are delegated to triage-apply.sh so classification metadata has
# exactly one write path repo-wide.
#
# Dry-run is the DEFAULT: every op prints "PLAN <exact gh command>" and writes
# nothing. --execute additionally requires GROOM_EXECUTE=1 in the environment
# (set only by the `task groom` wrapper for a supervised run) — a model cannot
# promote itself to write mode by adding a flag alone (same contract as
# triage-apply.sh's TRIAGE_EXECUTE gate).
#
# Bot-owned issues (author type Bot, or login matching app/* or *[bot]) are
# NEVER retitled, closed, or relabelled by this script — it refuses, naming
# the issue, whatever the plan row says (issue #1015 criterion 6). A plan row
# may carry its own "bot_owned" field (populated by groom-verdicts.sh's join
# from the scan); --execute additionally re-checks the issue's live author
# immediately before writing, since the plan may be stale by apply time.
#
# apply-plan runs in TWO PASSES (challenge round 1 finding 5). Pass 1
# validates every row — op recognized, required fields present, close reason
# valid, plan-carried bot_owned, and in --execute mode the live bot re-check
# AND a live retitle-conflict re-check (finding 6: the issue's current title
# must still match the plan's previous_title, or the retitle is refused
# rather than silently overwriting a concurrent edit) — and performs no
# writes at all. Only once every row in the plan has validated does pass 2
# run, applying (or, in dry-run, PLAN-printing) each write in order. A row
# that fails validation therefore aborts before ANY row has been written,
# instead of leaving the earlier rows in the plan already applied.
#
# The write log (--log) is opened in APPEND mode with a
# "# run <UTC timestamp> apply" header line for every --execute invocation —
# it is never truncated, so a rerun after a partial failure keeps the record
# of what an earlier attempt already wrote.
#
# --outcomes FILE (optional) appends one JSON Lines record per applied write —
# {"issue":N,"op":"close|retitle|label|milestone-assign|sub-issue-link",
#  "status":"DONE","at":"<UTC>"} (sub-issue-link records against the CHILD
# issue number) — for groom-report.sh render --outcomes to merge into each
# row's `status` column (issue #1015 finding 8). Dry-run never writes to it.
#
# Usage:
#   groom-apply.sh apply-plan --repo owner/repo --plan-file PATH --log PATH
#                  [--max-closes N] [--outcomes PATH] [--execute]
#
# Plan file: JSON Lines, one op per line:
#   {"op":"close","issue":N,"reason":"completed|not planned|duplicate","comment":"...","bot_owned":false}
#   {"op":"retitle","issue":N,"title":"...","previous_title":"...","bot_owned":false}
#   {"op":"label","issue":N,"add":["..."],"remove":["needs-triage"],"bot_owned":false}
#   {"op":"milestone-assign","issue":N,"milestone_title":"...","bot_owned":false}
#   {"op":"sub-issue-link","parent":N,"child":N}
#
# Exit: 0 = dry-run resolved or every write applied, 1 = a write failed,
#       2 = usage/environment error (including --execute without the env gate,
#       or more "close" rows than --max-closes allows), 4 = refused (bot-owned
#       issue, an unknown op, or a retitle whose live title no longer matches
#       the plan's previous_title).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
triage_apply="$script_dir/../../triage/assets/triage-apply.sh"
check_metadata="$script_dir/../../track-work/assets/check-issue-metadata.sh"

usage() {
    echo "Usage: $0 apply-plan --repo owner/repo --plan-file PATH --log PATH" >&2
    echo "                     [--max-closes N] [--outcomes PATH] [--execute]" >&2
    exit 2
}

die() {
    local code="$1"
    shift
    echo "groom-apply: $*" >&2
    exit "$code"
}

guard_issue_number() {
    case "$1" in
    '' | *[!0-9]*) die 2 "refused: issue must be a plain issue number (got '$1')" ;;
    esac
}

# Same run-binding as triage-apply.sh's TRIAGE_REPO guard: when the wrapper
# bound this run to one repository, a mismatched --repo is a confused (or
# prompt-injected) caller, not a supported use.
guard_repo_binding() {
    local repo="$1"
    if [ -n "${GROOM_REPO:-}" ] && [ "$repo" != "$GROOM_REPO" ]; then
        die 4 "refused: --repo '$repo' does not match this run's bound" \
            "repository '$GROOM_REPO'"
    fi
}

# Live re-check immediately before a write — the plan's own bot_owned field
# may be stale by apply time (defense in depth, same reasoning triage-apply.sh
# applies to its native-Type re-read).
live_is_bot() {
    local repo="$1" issue="$2" json
    json="$(gh issue view "$issue" --repo "$repo" --json author)" ||
        die 2 "could not re-read the author of $repo#$issue"
    jq -e '
      (.author.type == "Bot") or (.author.is_bot == true)
      or (.author.login == "app/renovate")
      or ((.author.login // "") | test("^app/|\\[bot\\]$"))
    ' <<<"$json" >/dev/null
}

log_write() {
    local log="$1"
    shift
    printf 'WRITE %s\n' "$*" >>"$log"
}

write_outcome() {
    local outcomes="$1" issue="$2" op="$3" status="$4"
    [ -n "$outcomes" ] || return 0
    local at
    at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    jq -nc --argjson issue "$issue" --arg op "$op" --arg status "$status" --arg at "$at" \
        '{issue: $issue, op: $op, status: $status, at: $at}' >>"$outcomes"
}

refuse_if_bot() {
    local repo="$1" issue="$2" row="$3" execute="$4" verb="$5"
    local plan_bot_owned
    plan_bot_owned="$(jq -r '.bot_owned // false' <<<"$row")"
    if [ "$plan_bot_owned" = "true" ]; then
        die 4 "refused: $repo#$issue is bot-authored — groom never" \
            "${verb}s a bot-owned issue"
    fi
    if [ "$execute" -eq 1 ] && live_is_bot "$repo" "$issue"; then
        die 4 "refused: $repo#$issue is bot-authored (live re-check) —" \
            "groom never ${verb}s a bot-owned issue"
    fi
}

# ── Pass 1: validation only. Every validate_* function either returns (row is
# fine) or calls die (aborts the WHOLE run before pass 2 ever writes anything).

validate_close() {
    local repo="$1" row="$2" execute="$3"
    local issue reason
    issue="$(jq -r '.issue // empty' <<<"$row")"
    guard_issue_number "$issue"
    reason="$(jq -r '.reason // empty' <<<"$row")"
    case "$reason" in
    completed | "not planned" | duplicate) ;;
    *) die 2 "refused: #$issue close reason must be completed, 'not planned', or duplicate (got '$reason')" ;;
    esac
    refuse_if_bot "$repo" "$issue" "$row" "$execute" close
}

validate_retitle() {
    local repo="$1" row="$2" execute="$3"
    local issue title previous_title
    issue="$(jq -r '.issue // empty' <<<"$row")"
    guard_issue_number "$issue"
    title="$(jq -r '.title // empty' <<<"$row")"
    previous_title="$(jq -r '.previous_title // empty' <<<"$row")"
    [ -n "$title" ] && [ -n "$previous_title" ] ||
        die 2 "refused: #$issue retitle needs both title and previous_title"
    refuse_if_bot "$repo" "$issue" "$row" "$execute" retitle

    [ -x "$check_metadata" ] || die 2 "title checker is missing: $check_metadata"
    "$check_metadata" --title-only --title "$title" --previous-title "$previous_title" \
        >/dev/null || die 4 "refused: #$issue retitle failed check-issue-metadata.sh --title-only"

    if [ "$execute" -eq 1 ]; then
        # Live re-check (finding 6): the plan's previous_title is a snapshot
        # from when the plan was authored. If the issue's live title has
        # since changed, applying the plan's new title would silently
        # overwrite that concurrent edit with no conflict signal at all.
        local live_json live_title
        live_json="$(gh issue view "$issue" --repo "$repo" --json title)" ||
            die 2 "could not re-read the live title of $repo#$issue"
        live_title="$(jq -r '.title // empty' <<<"$live_json")"
        [ "$live_title" = "$previous_title" ] ||
            die 4 "refused: #$issue's live title no longer matches the plan's" \
                "previous_title (expected '$previous_title', found" \
                "'$live_title') — refresh the plan and re-approve"
    fi
}

validate_label() {
    local repo="$1" row="$2" execute="$3"
    local issue
    issue="$(jq -r '.issue // empty' <<<"$row")"
    guard_issue_number "$issue"
    refuse_if_bot "$repo" "$issue" "$row" "$execute" relabel
    [ -x "$triage_apply" ] || die 2 "triage-apply.sh is missing: $triage_apply"
}

validate_milestone_assign() {
    local repo="$1" row="$2" execute="$3"
    local issue milestone_title
    issue="$(jq -r '.issue // empty' <<<"$row")"
    guard_issue_number "$issue"
    milestone_title="$(jq -r '.milestone_title // empty' <<<"$row")"
    [ -n "$milestone_title" ] ||
        die 2 "refused: #$issue milestone-assign needs a nonempty milestone_title"
}

validate_sub_issue_link() {
    local row="$1"
    local parent child
    parent="$(jq -r '.parent // empty' <<<"$row")"
    child="$(jq -r '.child // empty' <<<"$row")"
    guard_issue_number "$parent"
    guard_issue_number "$child"
}

# ── Pass 2: perform the write (or print the PLAN line in dry-run). Every row
# has already validated in pass 1, so these do not re-validate fields.

apply_close() {
    local repo="$1" row="$2" log="$3" execute="$4" outcomes="$5"
    local issue reason comment
    issue="$(jq -r '.issue // empty' <<<"$row")"
    reason="$(jq -r '.reason // empty' <<<"$row")"
    comment="$(jq -r '.comment // empty' <<<"$row")"

    local cmd=(gh issue close "$issue" --repo "$repo" --reason "$reason")
    [ -z "$comment" ] || cmd+=(--comment "$comment")
    if [ "$execute" -eq 0 ]; then
        echo "PLAN ${cmd[*]}"
        return 0
    fi
    log_write "$log" "${cmd[*]}"
    "${cmd[@]}" >/dev/null || die 1 "write failed: close $repo#$issue"
    echo "APPLIED close $repo#$issue ($reason)"
    write_outcome "$outcomes" "$issue" "close" "DONE"
}

apply_retitle() {
    local repo="$1" row="$2" log="$3" execute="$4" outcomes="$5"
    local issue title
    issue="$(jq -r '.issue // empty' <<<"$row")"
    title="$(jq -r '.title // empty' <<<"$row")"

    local cmd=(gh issue edit "$issue" --repo "$repo" --title "$title")
    if [ "$execute" -eq 0 ]; then
        echo "PLAN ${cmd[*]}"
        return 0
    fi
    log_write "$log" "${cmd[*]}"
    "${cmd[@]}" >/dev/null || die 1 "write failed: retitle $repo#$issue"
    echo "APPLIED retitle $repo#$issue"
    write_outcome "$outcomes" "$issue" "retitle" "DONE"
}

apply_label() {
    local repo="$1" row="$2" log="$3" execute="$4" outcomes="$5"
    local issue
    issue="$(jq -r '.issue // empty' <<<"$row")"

    local args=(label --repo "$repo" --issue "$issue")
    local a
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        args+=(--add "$a")
    done < <(jq -r '.add // [] | .[]' <<<"$row")
    while IFS= read -r a; do
        [ -n "$a" ] || continue
        args+=(--remove "$a")
    done < <(jq -r '.remove // [] | .[]' <<<"$row")

    if [ "$execute" -eq 0 ]; then
        echo "PLAN $triage_apply ${args[*]}"
        "$triage_apply" "${args[@]}"
        return 0
    fi
    log_write "$log" "$triage_apply ${args[*]} --execute"
    TRIAGE_EXECUTE=1 "$triage_apply" "${args[@]}" --execute ||
        die 1 "write failed: label $repo#$issue"
    write_outcome "$outcomes" "$issue" "label" "DONE"
}

apply_milestone_assign() {
    local repo="$1" row="$2" log="$3" execute="$4" outcomes="$5"
    local issue milestone_title
    issue="$(jq -r '.issue // empty' <<<"$row")"
    # `gh issue edit --milestone` takes the milestone's NAME, not its number
    # (confirmed against `gh issue edit --help`, gh 2.98.0: "-m, --milestone
    # name  Edit the milestone the issue belongs to by name") — there is no
    # by-number form. groom-scan.sh's milestones[] already carries `title`.
    milestone_title="$(jq -r '.milestone_title // empty' <<<"$row")"

    local cmd=(gh issue edit "$issue" --repo "$repo" --milestone "$milestone_title")
    if [ "$execute" -eq 0 ]; then
        echo "PLAN ${cmd[*]}"
        return 0
    fi
    log_write "$log" "${cmd[*]}"
    "${cmd[@]}" >/dev/null || die 1 "write failed: milestone-assign $repo#$issue"
    echo "APPLIED milestone-assign $repo#$issue -> '$milestone_title'"
    write_outcome "$outcomes" "$issue" "milestone-assign" "DONE"
}

apply_sub_issue_link() {
    local repo="$1" row="$2" log="$3" execute="$4" outcomes="$5"
    local parent child
    parent="$(jq -r '.parent // empty' <<<"$row")"
    child="$(jq -r '.child // empty' <<<"$row")"

    local cmd_desc="gh api repos/$repo/issues/$parent/sub_issues -F sub_issue_id=<id of #$child>"
    if [ "$execute" -eq 0 ]; then
        echo "PLAN $cmd_desc"
        return 0
    fi
    local child_id
    child_id="$(gh api "repos/$repo/issues/$child" --jq .id)" ||
        die 1 "could not resolve the numeric id of $repo#$child"
    log_write "$log" "gh api repos/$repo/issues/$parent/sub_issues -F sub_issue_id=$child_id"
    gh api "repos/$repo/issues/$parent/sub_issues" -F sub_issue_id="$child_id" >/dev/null ||
        die 1 "write failed: sub-issue link $repo#$parent <- $repo#$child"
    echo "APPLIED sub-issue-link $repo#$parent <- $repo#$child"
    # Recorded against the CHILD issue number: that is the row a maintainer
    # reading the report is looking at when a sub-issue link lands.
    write_outcome "$outcomes" "$child" "sub-issue-link" "DONE"
}

cmd_apply_plan() {
    local repo="" plan_file="" log="" max_closes=25 execute=0 outcomes=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        --plan-file)
            [ "$#" -ge 2 ] || usage
            plan_file="$2"
            shift 2
            ;;
        --log)
            [ "$#" -ge 2 ] || usage
            log="$2"
            shift 2
            ;;
        --max-closes)
            [ "$#" -ge 2 ] || usage
            max_closes="$2"
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
    [ -n "$repo" ] && [ -n "$plan_file" ] && [ -n "$log" ] || usage
    guard_repo_binding "$repo"
    [[ "$max_closes" =~ ^[0-9]+$ ]] ||
        die 2 "refused: --max-closes must be a nonnegative integer (got '$max_closes')"
    [ -r "$plan_file" ] || die 2 "cannot read plan file: $plan_file"

    local close_count
    close_count="$(jq -s '[.[] | select(.op == "close")] | length' "$plan_file")" ||
        die 2 "plan file is not valid JSON Lines: $plan_file"
    [[ "$close_count" =~ ^[0-9]+$ ]] || die 2 "could not count close operations in the plan file"
    if [ "$close_count" -gt "$max_closes" ]; then
        die 2 "refused: plan closes $close_count issues, above --max-closes" \
            "$max_closes — pass an explicit higher --max-closes to proceed"
    fi

    if [ "$execute" -eq 1 ]; then
        [ "${GROOM_EXECUTE:-0}" = "1" ] ||
            die 2 "--execute requires GROOM_EXECUTE=1 in the environment" \
                "(set by the task groom wrapper for supervised runs)"
        printf '# run %s apply\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$log" ||
            die 2 "could not open log file: $log"
    fi

    # Read every line into an array FIRST, then iterate it — not a
    # `while read < "$plan_file"` loop. A write op below (gh, or another
    # asset script) may itself read stdin (e.g. a stubbed `gh issue edit`
    # draining `--body-file -`); with a live redirect still open on fd 0 that
    # silently truncates the loop's remaining plan-file input mid-run.
    local lines=() lineno=0 line op
    mapfile -t lines <"$plan_file"

    # Pass 1 — validate every row; write NOTHING (finding 5). A refusal here
    # aborts before pass 2 has run at all, so no earlier row in the plan has
    # been written either.
    for line in "${lines[@]+"${lines[@]}"}"; do
        lineno=$((lineno + 1))
        [ -n "$line" ] || continue
        op="$(jq -r '.op // empty' <<<"$line")"
        case "$op" in
        close) validate_close "$repo" "$line" "$execute" ;;
        retitle) validate_retitle "$repo" "$line" "$execute" ;;
        label) validate_label "$repo" "$line" "$execute" ;;
        milestone-assign) validate_milestone_assign "$repo" "$line" "$execute" ;;
        sub-issue-link) validate_sub_issue_link "$line" ;;
        *) die 4 "refused: plan-file line $lineno has an unknown op '$op'" ;;
        esac
    done

    # Pass 2 — every row validated; now perform the writes (or, in dry-run,
    # print the PLAN lines).
    lineno=0
    for line in "${lines[@]+"${lines[@]}"}"; do
        lineno=$((lineno + 1))
        [ -n "$line" ] || continue
        op="$(jq -r '.op // empty' <<<"$line")"
        case "$op" in
        close) apply_close "$repo" "$line" "$log" "$execute" "$outcomes" </dev/null ;;
        retitle) apply_retitle "$repo" "$line" "$log" "$execute" "$outcomes" </dev/null ;;
        label) apply_label "$repo" "$line" "$log" "$execute" "$outcomes" </dev/null ;;
        milestone-assign) apply_milestone_assign "$repo" "$line" "$log" "$execute" "$outcomes" </dev/null ;;
        sub-issue-link) apply_sub_issue_link "$repo" "$line" "$log" "$execute" "$outcomes" </dev/null ;;
        esac
    done
}

[ "$#" -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
apply-plan) cmd_apply_plan "$@" ;;
*) usage ;;
esac
