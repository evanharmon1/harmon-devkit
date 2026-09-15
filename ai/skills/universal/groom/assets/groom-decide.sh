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
# every --blocked-by target's numeric id resolution, PLUS (whenever any
# --blocked-by is given) a probe that the issue-dependencies endpoint itself
# is available — all run before the decision comment is posted. Posting the
# comment first and only then discovering a --supersedes target is bot-owned
# (or that the dependencies endpoint is unsupported) left the comment posted
# (and any earlier --supersedes sibling already closed) with no way to undo
# either once the run died — exactly the partial-application failure this
# script's own preflight is meant to guard against.
#
# --log PATH is REQUIRED in --execute mode (same append-only, exact-command
# contract as groom-apply.sh's --log): opened with a "# run <UTC> execute"
# header, and one "WRITE <exact command>" line before every gh write —
# the decision comment, each superseded sibling's close, and each blocked-by
# edge (Codex review on PR #1032, comment 4011648572 — without it, none of
# this script's writes had a durable exact-command record comparable to
# groom-apply.sh's). Dry run never touches it.
#
# --outcomes FILE (optional) appends one JSON Lines record per applied write:
# {"issue":<decided-issue>,"op":"decision","status":"DECIDED <YYYY-MM-DD>","at":"<UTC>"}
# for the decided issue, {"issue":<sibling>,"op":"close","status":"DONE",
# "at":"<UTC>"} for each closed --supersedes sibling, and
# {"issue":<decided-issue>,"op":"blocked-by","status":"DECIDED <YYYY-MM-DD>","at":"<UTC>"}
# for each added blocked-by edge (Codex review on PR #1032, comment
# 4011648572) — for groom-report.sh render --outcomes to merge into each
# row's `status` column (finding 8). The blocked-by record is keyed by the
# SAME decided-issue number as the decision outcome and carries the SAME
# "DECIDED <date>" status, not "DONE": groom-report.sh's outcomes merge keeps
# only the LAST record per issue number, so a trailing "DONE" status for that
# issue silently overwrote the dated decision status the report is supposed
# to show for it (Codex review on PR #1032, comment 4012242590). In --execute
# mode the sink's appendability is checked before any write; once writes are
# underway a write_outcome failure warns and continues rather than aborting
# the run (challenge round 2 finding 8).
#
# Blocked-by edges use GitHub's issue-dependency REST endpoint, id-not-number
# (the same call ai/skills/universal/breakdown/SKILL.md §7 documents — no
# reusable helper script exists there to call instead):
#   gh api repos/<owner>/<repo>/issues/<blocked>/dependencies/blocked_by \
#     -F issue_id=<blocker's numeric id>
#
# PREFLIGHT also rejects (exit 2) a --supersedes or --blocked-by value equal
# to --issue itself, a value repeated within the same flag (Codex review on
# PR #1032, comment 4011648597), or a value present in BOTH --supersedes and
# --blocked-by (Codex review on PR #1032, comment 4012242629 — closing an
# issue as superseded and adding the same, now-closed issue as a blocker in
# the same run is contradictory tracker state) — before any gh call,
# including the bot-ownership reads below. It also rejects (exit 2) a
# --decision-file whose trimmed content is empty (Codex review on PR #1032,
# comment 4012242616), before any write.
#
# Usage:
#   groom-decide.sh --repo owner/repo --issue N --decision-file PATH
#                    [--supersedes M]... [--blocked-by K]... [--outcomes PATH]
#                    [--log PATH] [--execute]
#
# Exit: 0 = dry-run resolved or every write applied, 1 = a write failed,
#       2 = usage/environment error (including --execute without --log, a
#       --supersedes/--blocked-by that self-references --issue, repeats, or
#       intersects the other flag, and an empty/whitespace-only
#       --decision-file), 4 = refused (a --supersedes target is
#       bot-authored, or --blocked-by is given and the issue-dependencies
#       endpoint is unavailable — Codex review on PR #1032, comment
#       4012885483).
set -euo pipefail

usage() {
    echo "Usage: $0 --repo owner/repo --issue N --decision-file PATH" >&2
    echo "          [--supersedes M]... [--blocked-by K]... [--outcomes PATH]" >&2
    echo "          [--log PATH] [--execute]" >&2
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

guard_not_self() {
    local flag="$1" value="$2" issue_arg="$3"
    [ "$value" != "$issue_arg" ] ||
        die 2 "refused: $flag $value equals --issue $issue_arg (a decision" \
            "cannot name itself)"
}

# A plain string-list membership test stands in for an associative array
# (bash 3.2 has none — same reasoning as groom-apply.sh's seen_keys check).
guard_no_duplicates() {
    local flag="$1"
    shift
    local seen="" v
    for v in "$@"; do
        if grep -qxF "$v" <<<"$seen"; then
            die 2 "refused: $flag lists $v more than once"
        fi
        seen="$(printf '%s\n%s' "$seen" "$v")"
    done
}

# Same run-binding as groom-apply.sh / triage-apply.sh.
guard_repo_binding() {
    local repo="$1"
    if [ -n "${GROOM_REPO:-}" ] && [ "$repo" != "$GROOM_REPO" ]; then
        die 4 "refused: --repo '$repo' does not match this run's bound" \
            "repository '$GROOM_REPO'"
    fi
}

log_write() {
    local log="$1"
    shift
    # Serialize each argv element with %q (shell-safe quoting) instead of
    # flattening the array with "$*" (which loses argv boundaries whenever
    # the decision comment or a pointer contains whitespace, quotes, or shell
    # metacharacters — Codex review on PR #1032, comment 4012242585). The
    # resulting line is the EXACT command, re-parseable by `eval`.
    {
        printf 'WRITE'
        local arg
        for arg in "$@"; do
            printf ' %q' "$arg"
        done
        printf '\n'
    } >>"$log"
}

# Same as log_write, but for the decision comment specifically: appends
# " # body-sha256=<hex>" of the posted body on the SAME WRITE line (Codex
# review on PR #1032, comment 4012885422). Every decision executes the
# generated temp-file command (comment_cmd below), but the OLD code logged a
# separate comment_log_cmd array carrying the literal placeholder
# "<decision-comment>" instead — neither the executed argv nor replayable
# after a partial run. Logging the real --body-file path is not itself
# enough to reconstruct what was posted (the temp file is removed on exit),
# so the digest of its content travels with the WRITE line as the durable,
# comparable record of exactly what was sent.
log_write_comment() {
    local log="$1" body_sha="$2"
    shift 2
    {
        printf 'WRITE'
        local arg
        for arg in "$@"; do
            printf ' %q' "$arg"
        done
        printf ' # body-sha256=%s\n' "$body_sha"
    } >>"$log"
}

sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        die 2 "sha256sum or shasum is required"
    fi
}

# Print a dry-run "PLAN <exact command>" line with the same %q quoting as
# log_write (Codex review on PR #1032, comment 4012885429) — see
# groom-apply.sh's print_plan for the full reasoning: a maintainer comparing
# a PLAN line against the approved decision text needs argv boundaries
# preserved, not the lossy "${cmd[*]}" flattening.
print_plan() {
    printf 'PLAN'
    local arg
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
    printf '\n'
}

write_outcome() {
    local outcomes="$1" issue="$2" op="$3" status="$4"
    [ -n "$outcomes" ] || return 0
    local at
    at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    # Best-effort (challenge round 2 finding 8) — see groom-apply.sh's
    # write_outcome for the full reasoning: a failure here must warn and
    # continue, never abort a run whose live GitHub write already happened.
    jq -nc --argjson issue "$issue" --arg op "$op" --arg status "$status" --arg at "$at" \
        '{issue: $issue, op: $op, status: $status, at: $at}' >>"$outcomes" 2>/dev/null ||
        echo "groom-decide: warning: could not record the outcome for" \
            "#$issue ($op) to $outcomes" >&2
}

repo=""
issue=""
decision_file=""
execute=0
outcomes=""
log=""
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
    --log)
        [ "$#" -ge 2 ] || usage
        log="$2"
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

# Reject self-references and duplicates BEFORE any gh call (Codex review on
# PR #1032, comment 4011648597): a --supersedes/--blocked-by sidecar
# accidentally naming the decided issue itself, or naming the same sibling
# twice, used to be caught only when GitHub itself refused the write — after
# the decision comment (and any earlier --supersedes close) had already been
# posted for real.
for m in "${supersedes[@]+"${supersedes[@]}"}"; do guard_not_self --supersedes "$m" "$issue"; done
for k in "${blocked_by[@]+"${blocked_by[@]}"}"; do guard_not_self --blocked-by "$k" "$issue"; done
guard_no_duplicates --supersedes "${supersedes[@]+"${supersedes[@]}"}"
guard_no_duplicates --blocked-by "${blocked_by[@]+"${blocked_by[@]}"}"

# Reject any number present in BOTH --supersedes and --blocked-by (Codex
# review on PR #1032, comment 4012242629): execution would close that issue
# as superseded and then immediately add the just-closed issue as a blocker
# of the decided issue, producing contradictory tracker state. Checked before
# any gh call, same as the self-reference/duplicate guards above.
for k in "${blocked_by[@]+"${blocked_by[@]}"}"; do
    for m in "${supersedes[@]+"${supersedes[@]}"}"; do
        if [ "$k" = "$m" ]; then
            die 2 "refused: #$k appears in both --supersedes and" \
                "--blocked-by — an issue cannot be closed as superseded and" \
                "added as a blocker in the same decision"
        fi
    done
done

[ -r "$decision_file" ] || die 2 "cannot read decision file: $decision_file"

# Refuse a decision file whose trimmed content is empty, before any write
# (Codex review on PR #1032, comment 4012242616): readability alone let a
# zero-byte or whitespace-only approved artifact through to post only the
# generated heading and then close every --supersedes sibling and add every
# --blocked-by edge, with no actual maintainer decision preserved anywhere.
decision_trimmed="$(tr -d '[:space:]' <"$decision_file")"
[ -n "$decision_trimmed" ] ||
    die 2 "refused: --decision-file $decision_file is empty (or" \
        "whitespace-only) — a maintainer decision cannot be blank"

if [ "$execute" -eq 1 ]; then
    [ "${GROOM_EXECUTE:-0}" = "1" ] ||
        die 2 "--execute requires GROOM_EXECUTE=1 in the environment" \
            "(set by the task groom wrapper for supervised runs)"
    # --log is required in --execute mode (Codex review on PR #1032, comment
    # 4011648572) — same append-only, exact-command contract as
    # groom-apply.sh's --log, opened here before any write.
    [ -n "$log" ] ||
        die 2 "--execute requires --log PATH (append-only write record," \
            "same contract as groom-apply.sh)"
    printf '# run %s execute\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$log" ||
        die 2 "could not open log file: $log"
    # Verify the outcomes sink is appendable up front (challenge round 2
    # finding 8) — the same reasoning as groom-apply.sh's log/outcomes
    # preflight: a write_outcome failure discovered mid-run, after live
    # GitHub writes have already happened, must never be the thing that
    # aborts the run.
    if [ -n "$outcomes" ]; then
        : >>"$outcomes" 2>/dev/null ||
            die 2 "could not open --outcomes file: $outcomes"
    fi
fi

# ── Preflight (finding 7): resolve everything that can fail BEFORE the first
# write. A maintainer decision names issue numbers, not authors, and a bot
# (Renovate/Dependabot) routinely files near-duplicates that would otherwise
# fit a "superseded by" close — SKILL.md's contract is unqualified that a
# bot-authored issue is never closed by groom, whatever the write path.
#
# blocked_by_ids is a plain indexed array, positionally parallel to
# blocked_by (index i's id belongs to blocked_by[i]) — not `declare -A`,
# which is bash 4+ only and breaks this script on macOS's shipped bash 3.2
# (challenge round 2 finding 5).
blocked_by_ids=()
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
        id="$(gh api "repos/$repo/issues/$k" --jq .id)" ||
            die 1 "could not resolve the numeric id of $repo#$k"
        blocked_by_ids+=("$id")
    done
fi

# Probe the issue-dependencies endpoint's own availability BEFORE any write
# (Codex review on PR #1032, comment 4012885483): resolving each
# --blocked-by target's numeric id above only proves that ISSUE is
# accessible, not that this GitHub host or repository exposes the
# issue-dependencies endpoint at all. Without this probe, the decision
# comment was posted and every --supersedes sibling closed before the FIRST
# blocked-by write ever touched the endpoint and failed there instead —
# exactly the partial-application hazard this preflight section exists to
# prevent. A GET (no -F) mirrors the same availability check
# ai/skills/universal/breakdown/SKILL.md §7 already performs before relying
# on this endpoint. Dry run never calls gh; it prints the probe as a PLAN
# line so the maintainer sees it would run.
if [ "${#blocked_by[@]}" -gt 0 ]; then
    if [ "$execute" -eq 1 ]; then
        gh api "repos/$repo/issues/$issue/dependencies/blocked_by" >/dev/null 2>&1 ||
            die 4 "refused: $repo#$issue's issue-dependencies endpoint" \
                "(GET repos/$repo/issues/$issue/dependencies/blocked_by) is" \
                "unavailable — this host or repository does not support" \
                "blocked-by edges"
    else
        echo "PLAN gh api repos/$repo/issues/$issue/dependencies/blocked_by (availability probe)"
    fi
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

comment_cmd=(gh issue comment "$issue" --repo "$repo" --body-file "$comment_tmp")
if [ "$execute" -eq 0 ]; then
    print_plan "${comment_cmd[@]}"
else
    body_sha="$(sha256_stream <"$comment_tmp")"
    log_write_comment "$log" "$body_sha" "${comment_cmd[@]}"
    "${comment_cmd[@]}" >/dev/null ||
        die 1 "write failed: decision comment on $repo#$issue"
    echo "APPLIED decision comment on $repo#$issue"
    write_outcome "$outcomes" "$issue" "decision" "DECIDED $now"
fi

for m in "${supersedes[@]+"${supersedes[@]}"}"; do
    pointer="Superseded by the decision on #$issue."
    cmd=(gh issue close "$m" --repo "$repo" --reason "not planned" --comment "$pointer")
    if [ "$execute" -eq 0 ]; then
        print_plan "${cmd[@]}"
    else
        log_write "$log" "${cmd[@]}"
        "${cmd[@]}" >/dev/null || die 1 "write failed: close $repo#$m"
        echo "APPLIED close $repo#$m (superseded by #$issue)"
        write_outcome "$outcomes" "$m" "close" "DONE"
    fi
done

blocked_by_i=0
for k in "${blocked_by[@]+"${blocked_by[@]}"}"; do
    if [ "$execute" -eq 0 ]; then
        echo "PLAN gh api repos/$repo/issues/$issue/dependencies/blocked_by -F issue_id=<id of #$k>"
    else
        blocker_id="${blocked_by_ids[$blocked_by_i]}"
        cmd=(gh api "repos/$repo/issues/$issue/dependencies/blocked_by" -F "issue_id=$blocker_id")
        log_write "$log" "${cmd[@]}"
        "${cmd[@]}" >/dev/null ||
            die 1 "write failed: blocked-by edge $repo#$issue <- $repo#$k"
        echo "APPLIED blocked-by $repo#$issue <- $repo#$k"
        # Recorded as DECIDED (not DONE): groom-report.sh's outcomes merge
        # keeps only the LAST record per issue number, and a blocked-by edge
        # is recorded against the DECIDED issue's own number (same as the
        # decision outcome above) — a trailing DONE record silently
        # overwrote the dated DECIDED status the decision comment had just
        # recorded (Codex review on PR #1032, comment 4012242590).
        write_outcome "$outcomes" "$issue" "blocked-by" "DECIDED $now"
    fi
    blocked_by_i=$((blocked_by_i + 1))
done
