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
# apply-plan runs in TWO PASSES (challenge round 1 finding 5). Pass 0 refuses
# a plan carrying two rows for the same op+issue outright (challenge round 2
# finding 4 — a plan-authoring duplicate/leftover, e.g. two retitles for the
# same issue, must never resolve to "whichever pass 2 happens to apply last").
# Pass 1 then validates every remaining row — op recognized, required fields
# present, close reason valid, plan-carried bot_owned, a label op's full
# never-list/allowlist/axis/repo-kind validation via triage-apply.sh's own
# dry run (challenge round 2 finding 3 — validate_label used to check only
# bot ownership, so a label pass-1 accepted could still be refused for real
# in pass 2, after earlier rows in the same plan had already been written),
# and in --execute mode the live bot re-check — and performs no writes at
# all. Only once every row in the plan has validated does pass 2 run,
# applying (or, in dry-run, PLAN-printing) each write in order. A row that
# fails validation therefore aborts before ANY row has been written, instead
# of leaving the earlier rows in the plan already applied.
#
# A retitle's live-title re-check (finding 6: the issue's current title must
# still match the plan's previous_title, or the retitle is refused rather
# than silently overwriting a concurrent edit) runs in BOTH pass 1 and pass 2
# in --execute mode (challenge round 2 finding 4 — pass 1's own validation
# loop can itself take long enough, across every other row's live checks,
# for a concurrent edit to land in the gap before pass 2 writes; re-checking
# immediately adjacent to the write closes that window). A pass-2 refusal is
# reported as a conflict naming the plan-file row number — pass 1 already
# accepted the plan, so this is new information for whoever is watching the
# run, not a validation gap — and the run stops with whatever pass 2 already
# wrote recorded in the log.
#
# The write log (--log) is opened in APPEND mode with a
# "# run <UTC timestamp> apply" header line for every --execute invocation —
# it is never truncated, so a rerun after a partial failure keeps the record
# of what an earlier attempt already wrote. Each WRITE line is the EXACT
# command: log_write serializes every argv element with `printf '%q'`
# (bash 3.2 supports it) instead of flattening the array with "$*", which
# lost argv boundaries whenever an approved title, comment, or milestone name
# contained whitespace, quotes, or shell metacharacters (Codex review on
# PR #1032, comment 4012242585).
#
# --outcomes FILE (optional) appends one JSON Lines record per applied write —
# {"issue":N,"op":"close|retitle|label|milestone-assign|sub-issue-link",
#  "status":"DONE","at":"<UTC>"} (sub-issue-link records against the CHILD
# issue number) — for groom-report.sh render --outcomes to merge into each
# row's `status` column (issue #1015 finding 8). Dry-run never writes to it.
# In --execute mode pass 1 verifies the sink is appendable (same as --log);
# once writes are underway, a write_outcome failure warns and continues
# rather than aborting the run under set -e (challenge round 2 finding 8 —
# the outcome record is a convenience for the report, not itself a write
# whose loss should strand a plan partway through).
#
# Usage:
#   groom-apply.sh apply-plan --repo owner/repo --plan-file PATH --log PATH
#                  [--max-closes N] [--outcomes PATH] [--execute]
#
# Plan file: JSON Lines, one op per line:
#   {"op":"close","issue":N,"reason":"completed|not planned|duplicate","comment":"...","bot_owned":false,"unticked":false}
#   {"op":"retitle","issue":N,"title":"...","previous_title":"...","preserve_original":true,"bot_owned":false}
#   {"op":"label","issue":N,"add":["..."],"remove":["needs-triage"],"bot_owned":false}
#   {"op":"milestone-assign","issue":N,"milestone_title":"...","bot_owned":false}
#   {"op":"sub-issue-link","parent":N,"child":N}
#
# A "close" row's optional "unticked" field is a plan-authoring hint only
# (surfaced as a dry-run NOTE); the real gate is the live-body re-check below,
# which runs only in --execute mode.
#
# A "retitle" row gains an optional field: preserve_original: true. A retitle
# loses wording when the new title does not contain the previous title's
# outcome verbatim (detected via issue-title.jq's issue_title_outcome helper).
# In execute mode, pass 1 refuses (exit 4) any retitle that loses wording on an
# empty-body issue unless preserve_original is true. In pass 2, when
# preserve_original is true and wording is lost, after the title write succeeds
# a marked section ("## Original title\n<!-- groom-original-title -->\n<previous_title, verbatim>")
# is appended to the body via `gh issue edit N --repo R --body-file -` on stdin.
# The body append is idempotent: if the live body already carries the marker,
# the append is skipped and noted on stdout. If preserve_original is set but no
# wording is lost, nothing is appended and a NOTE is printed. In dry-run mode,
# a second PLAN line is printed for the body append whenever execute mode would
# append. The body append logs its own WRITE line and records a write_outcome
# with op "retitle-preserve".
#
# Exit: 0 = dry-run resolved or every write applied, 1 = a write failed,
#       2 = usage/environment error (including --execute without the env gate,
#       more "close" rows than --max-closes allows, an unwritable --outcomes
#       sink in --execute mode, two plan rows naming the same op+issue, a
#       "duplicate" close whose comment does not name a distinct canonical
#       issue — Codex review on PR #1032, comment 4012242606 — or a
#       sub-issue-link whose resolved parent and child ids are equal —
#       Codex review on PR #1032, comment 4012885462),
#       4 = refused (bot-owned issue, an unknown op, a label op triage-
#       apply.sh's own dry run would reject, a retitle whose live title no
#       longer matches the plan's previous_title, a shortening retitle on an
#       empty body lacking preserve_original: true, a completed close whose
#       live body still has an unticked task item, a sub-issue-link whose
#       parent or child id could not be resolved, or a milestone-assign whose
#       milestone_title or target issue could not be resolved — Codex review
#       on PR #1032, comments 4012242580 and 4012885414).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
triage_apply="$script_dir/../../triage/assets/triage-apply.sh"
check_metadata="$script_dir/../../track-work/assets/check-issue-metadata.sh"
title_module_dir="$script_dir/../../issue-title-support/assets"

# Check whether proposed title loses wording from previous_title
# (issue #1059). Lost means the new outcome does not contain the previous
# outcome as a substring, case-sensitive, after collapsing whitespace.
# A verbatim restore or a pure prefix rewrite (e.g. fix(review): -> (review):)
# is not lost.
retitle_loses_wording() {
    local prev="$1" new="$2"
    [ -r "$title_module_dir/issue-title.jq" ] ||
        die 2 "shared issue-title predicate is missing: $title_module_dir/issue-title.jq"
    jq -n -L "$title_module_dir" --arg prev "$prev" --arg new "$new" '
      include "issue-title";
      def clean_outcome:
        issue_title_outcome
        | until(
            . as $b
            | (sub("^(\\[[^\\]]*\\]\\s*:?\\s*|(bug|feature|task|research|documentation|question|enhancement):\\s*|(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\\([^)]*\\))?!?:\\s*|P[0-9]+:\\s*)"; ""; "i")) as $a
            | $b == $a;
            sub("^(\\[[^\\]]*\\]\\s*:?\\s*|(bug|feature|task|research|documentation|question|enhancement):\\s*|(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\\([^)]*\\))?!?:\\s*|P[0-9]+:\\s*)"; ""; "i")
          )
        | gsub("[[:space:]]+"; " ")
        | sub("^ "; "")
        | sub(" $"; "");
      if $prev == $new then false
      else
        (($prev | clean_outcome) as $p | ($new | clean_outcome) as $n |
          if ($p | length) == 0 then false
          else ($n | contains($p) | not)
          end
        )
      end
    '
}

# sub-issue-link's resolved CHILD numeric id, cached in pass 1 (execute mode
# only) and consumed by pass 2 — indexed by plan-file line number. A plain
# indexed array stands in for an associative array (bash 3.2 has none, same
# reasoning as cmd_apply_plan's own seen_keys/lines handling below).
sub_issue_child_id=()

# Every milestone TITLE of the target repo, resolved once in pass 1 (execute
# mode only, on first use) by validate_milestone_assign and cached here —
# newline-separated, empty until fetched (Codex review on PR #1032, comment
# 4012242580).
milestone_titles=""
milestone_titles_fetched=0

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

# Print a dry-run "PLAN <exact command>" line with the same argv-preserving
# %q quoting log_write uses for the durable WRITE record (Codex review on
# PR #1032, comment 4012885429): a maintainer-approved title, comment, or
# milestone name containing spaces, quotes, newlines, or shell metacharacters
# flattened via "${cmd[*]}" into an ambiguous string a reviewer cannot
# reliably compare with the approval before running --execute for real — a
# newline could even fabricate an apparent extra PLAN line.
print_plan() {
    printf 'PLAN'
    local arg
    for arg in "$@"; do
        printf ' %q' "$arg"
    done
    printf '\n'
}

log_write() {
    local log="$1"
    shift
    # Serialize each argv element with %q (shell-safe quoting) instead of
    # flattening the array with "$*" (which loses argv boundaries whenever an
    # approved title, comment, or milestone name contains whitespace, quotes,
    # or shell metacharacters — Codex review on PR #1032, comment
    # 4012242585). The resulting line is the EXACT command, re-parseable by
    # `eval`, not an approximation of it.
    {
        printf 'WRITE'
        local arg
        for arg in "$@"; do
            printf ' %q' "$arg"
        done
        printf '\n'
    } >>"$log"
}

# Same as log_write, but for body append writes: appends
# " # body-sha256=<hex>" of the posted body on the SAME WRITE line (Codex
# review on PR #1089, comment 4030604913; mirrors groom-decide.sh comment 4012885422).
log_write_body() {
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

is_blank_body() {
    local body="$1"
    jq -rn --arg b "$body" '
      def is_blank_codepoint:
        . < 32 or (. >= 127 and . <= 159) or . == 32 or . == 160 or . == 5760
        or (. >= 8192 and . <= 8205) or . == 8232 or . == 8233
        or . == 8239 or . == 8287 or . == 8288 or . == 12288 or . == 65279;
      ($b | explode | all(is_blank_codepoint))
    '
}

# Resolve every milestone TITLE of $repo, once, in execute mode (Codex review
# on PR #1032, comment 4012242580): without this, an approved plan's
# milestone-assign row was accepted in pass 1 even when its milestone_title
# was stale, renamed, or never existed, and `gh issue edit --milestone` (which
# resolves by NAME, not number) only failed in pass 2 — after every earlier
# row's write had already run, exactly the partial-application hazard the
# two-pass split (finding 5) exists to prevent. Same pagination-flattening
# reasoning as groom-scan.sh's milestones fetch (Codex review comment
# 4011648559): `gh api --paginate` emits one JSON array per page.
fetch_milestone_titles() {
    local repo="$1" pages
    [ "$milestone_titles_fetched" -eq 1 ] && return 0
    pages="$(gh api "repos/$repo/milestones" --paginate -X GET -f state=all -f per_page=100)" ||
        die 2 "could not list the milestones of $repo"
    milestone_titles="$(printf '%s' "$pages" | jq -rs '.[][] | .title')" ||
        die 2 "could not parse the milestones of $repo"
    milestone_titles_fetched=1
}

write_outcome() {
    local outcomes="$1" issue="$2" op="$3" status="$4"
    [ -n "$outcomes" ] || return 0
    local at
    at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    # Best-effort (challenge round 2 finding 8): pass 1 already checked the
    # sink is appendable, but a failure here (disk full, sink removed mid-run)
    # must warn and continue rather than abort under set -e — the live
    # GitHub write this outcome describes has already happened, and losing
    # its record must never look like the partial-application failure the
    # two-pass restructuring (finding 5) exists to prevent.
    jq -nc --argjson issue "$issue" --arg op "$op" --arg status "$status" --arg at "$at" \
        '{issue: $issue, op: $op, status: $status, at: $at}' >>"$outcomes" 2>/dev/null ||
        echo "groom-apply: warning: could not record the outcome for" \
            "#$issue ($op) to $outcomes" >&2
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

    # A "duplicate" close must carry a comment naming the canonical issue
    # (Codex review on PR #1032, comment 4012242606): the reason alone does
    # not preserve where the real work lives, and
    # ai/skills/universal/track-work/SKILL.md's closing contract requires the
    # pointer. Applies in BOTH dry-run and execute mode — this validates the
    # plan row's own content, not live GitHub state.
    if [ "$reason" = "duplicate" ]; then
        local dup_comment dup_target
        dup_comment="$(jq -r '.comment // empty' <<<"$row")"
        # grep -oE exits 1 on no match, which set -e would otherwise treat as
        # this whole function failing (a bare pattern-not-found is not an
        # error here — it means "no canonical pointer", handled below).
        dup_target="$(printf '%s' "$dup_comment" | grep -oE '#[0-9]+' | head -1 | tr -d '#')" || true
        [ -n "$dup_target" ] ||
            die 2 "refused: #$issue close reason is duplicate but its comment" \
                "does not name a canonical issue (expected a '#N' pointer) —" \
                "track-work's closing contract requires the canonical issue" \
                "for a duplicate close"
        [ "$dup_target" != "$issue" ] ||
            die 2 "refused: #$issue close reason is duplicate but its" \
                "comment's canonical pointer names itself (#$dup_target)" \
                "rather than a different issue"
    fi

    refuse_if_bot "$repo" "$issue" "$row" "$execute" close

    # track-work's closing contract (ai/skills/universal/track-work/SKILL.md
    # §4): "completed" claims every acceptance item is ticked; the documented
    # fail condition is closing completed while the live body still shows an
    # unticked `- [ ]` item (Codex review on PR #1032, comment 4011648601).
    if [ "$reason" = "completed" ]; then
        if [ "$execute" -eq 1 ]; then
            local body_json body
            body_json="$(gh issue view "$issue" --repo "$repo" --json body)" ||
                die 2 "could not re-read the body of $repo#$issue"
            body="$(jq -r '.body // ""' <<<"$body_json")"
            # Any depth of blockquote prefix (`> - [ ] …`, `> > - [ ] …`, …)
            # still represents unfinished work — same UNCHECKED_RE predicate
            # track-work/assets/check-closing-keywords.sh uses — so a
            # checklist item carried over blockquoted from another issue is
            # not missed here just because this narrower regex required the
            # marker at the start of the line (Codex review on PR #1032,
            # comment 4012885453).
            if grep -qE '^[[:space:]]*(>[[:space:]]*)*([-*+]|[0-9]+[.)])[[:space:]]+\[[[:space:]]\]' <<<"$body"; then
                die 4 "refused: #$issue close reason is completed but its" \
                    "live body still has an unticked '- [ ]' task item —" \
                    "track-work's closing contract requires every acceptance" \
                    "item ticked before closing completed"
            fi
        else
            # Dry run never reads the live body (no write is imminent); it
            # only surfaces the plan row's own optional "unticked" hint, when
            # a plan author set one, so a reviewer can flag it before
            # approving.
            local plan_unticked
            plan_unticked="$(jq -r '.unticked // false' <<<"$row")"
            if [ "$plan_unticked" = "true" ]; then
                echo "NOTE #$issue close reason is completed but the plan" \
                    "row's own 'unticked' hint says an acceptance item is" \
                    "still unchecked — verify before approving"
            fi
        fi
    fi
}

validate_retitle() {
    local repo="$1" row="$2" execute="$3"
    local issue title previous_title preserve_original
    issue="$(jq -r '.issue // empty' <<<"$row")"
    guard_issue_number "$issue"
    title="$(jq -r '.title // empty' <<<"$row")"
    previous_title="$(jq -r '.previous_title // empty' <<<"$row")"
    preserve_original="$(jq -r '.preserve_original // false' <<<"$row")"
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
        local live_json live_title live_body
        live_json="$(gh issue view "$issue" --repo "$repo" --json title,body)" ||
            die 2 "could not re-read the live title and body of $repo#$issue"
        live_title="$(jq -r '.title // empty' <<<"$live_json")"
        live_body="$(jq -r '.body // ""' <<<"$live_json")"
        local loses_wording
        loses_wording="$(retitle_loses_wording "$previous_title" "$title")"
        if [ "$live_title" != "$previous_title" ]; then
            if [ "$live_title" = "$title" ]; then
                if [ "$preserve_original" = "true" ] && [ "$loses_wording" = "true" ] && ! grep -qF '<!-- groom-original-title -->' <<<"$live_body"; then
                    echo "NOTE #$issue title already updated to '$title'; original title preservation will be resumed" >&2
                else
                    echo "NOTE #$issue title already updated to '$title'; row already applied" >&2
                fi
            else
                die 4 "refused: #$issue's live title no longer matches the plan's" \
                    "previous_title (expected '$previous_title', found" \
                    "'$live_title') — refresh the plan and re-approve"
            fi
        fi
        if [ "$loses_wording" = "true" ]; then
            if [ "$(is_blank_body "$live_body")" = "true" ] && [ "$preserve_original" != "true" ]; then
                die 4 "refused: #$issue retitle loses original title wording on an" \
                    "empty body — track-work's retitle contract requires" \
                    "preserve_original: true on the plan row to preserve wording"
            fi
            if [ "$preserve_original" = "true" ]; then
                command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
                    die 2 "sha256sum or shasum is required to compute body digest for #$issue"
            fi
        fi
    fi
}

validate_label() {
    local repo="$1" row="$2" execute="$3"
    local issue
    issue="$(jq -r '.issue // empty' <<<"$row")"
    guard_issue_number "$issue"
    refuse_if_bot "$repo" "$issue" "$row" "$execute" relabel
    [ -x "$triage_apply" ] || die 2 "triage-apply.sh is missing: $triage_apply"

    # Delegate to triage-apply.sh's OWN dry run (challenge round 2 finding 3):
    # its never-list, allowlist, exclusive-axis, and repo-kind checks (exit
    # 4/5/6) run unconditionally, before its own --execute gate, so calling it
    # here without --execute performs exactly the same validation depth pass
    # 2 would hit for real — uniform with every other op's pass-1 check.
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
    "$triage_apply" "${args[@]}" >/dev/null ||
        die 4 "refused: #$issue label op failed triage-apply.sh's own" \
            "dry-run validation (never-list, allowlist, axis, or repo-kind)"
}

validate_milestone_assign() {
    local repo="$1" row="$2" execute="$3"
    local issue milestone_title
    issue="$(jq -r '.issue // empty' <<<"$row")"
    guard_issue_number "$issue"
    milestone_title="$(jq -r '.milestone_title // empty' <<<"$row")"
    [ -n "$milestone_title" ] ||
        die 2 "refused: #$issue milestone-assign needs a nonempty milestone_title"

    # Resolve the milestone list once and refuse a title that is not present
    # (Codex review on PR #1032, comment 4012242580) — see
    # fetch_milestone_titles above. Dry run never resolves the list; it only
    # prints the PLAN line, unchanged.
    if [ "$execute" -eq 1 ]; then
        fetch_milestone_titles "$repo"
        grep -qxF "$milestone_title" <<<"$milestone_titles" ||
            die 4 "refused: #$issue milestone-assign names" \
                "'$milestone_title', which is not a milestone of $repo"
        # Resolve the TARGET issue too (Codex review on PR #1032, comment
        # 4012885414): this validated only that the milestone title exists,
        # never that #$issue itself is still resolvable. `gh issue edit`
        # resolves the issue argument in the write command itself, so a
        # deleted/inaccessible target following an earlier valid row let
        # pass 1 succeed, the earlier write run, and only pass 2's edit fail
        # — contradicting Step 6's all-rows-before-any-write guarantee.
        gh api "repos/$repo/issues/$issue" --jq .id >/dev/null ||
            die 4 "refused: could not resolve the numeric id of $repo#$issue" \
                "(milestone-assign target) — it may be inaccessible or deleted"
    fi
}

validate_sub_issue_link() {
    local repo="$1" row="$2" execute="$3" lineno="$4"
    local parent child
    parent="$(jq -r '.parent // empty' <<<"$row")"
    child="$(jq -r '.child // empty' <<<"$row")"
    guard_issue_number "$parent"
    guard_issue_number "$child"

    # Resolve BOTH ids during pass 1, in execute mode, and cache the child's
    # id for pass 2 (Codex review on PR #1032, comment 4011648563): without
    # this, an inaccessible/deleted child was discovered only when pass 2
    # got to this row, after every earlier row's write had already run —
    # exactly the partial-application hazard the two-pass split (finding 5)
    # exists to prevent. Dry run never resolves ids; it only prints the PLAN
    # line, unchanged.
    if [ "$execute" -eq 1 ]; then
        local parent_id child_id
        parent_id="$(gh api "repos/$repo/issues/$parent" --jq .id)" ||
            die 4 "refused: could not resolve the numeric id of $repo#$parent" \
                "(sub-issue-link parent at plan row $lineno) — it may be" \
                "inaccessible or deleted"
        child_id="$(gh api "repos/$repo/issues/$child" --jq .id)" ||
            die 4 "refused: could not resolve the numeric id of $repo#$child" \
                "(sub-issue-link child at plan row $lineno) — it may be" \
                "inaccessible or deleted"
        # Compare the RESOLVED ids, not the plan's own digit strings (Codex
        # review on PR #1032, comment 4012885462): "1" and "01" both pass the
        # digit guards and both resolve, but GitHub cannot make an issue its
        # own sub-issue, and a self-referential row reached the API only in
        # pass 2 — after any earlier row's write had already run — without
        # this check.
        [ "$parent_id" != "$child_id" ] ||
            die 2 "refused: sub-issue-link at plan row $lineno cannot make" \
                "$repo#$parent its own sub-issue (parent and child both" \
                "resolve to id $parent_id)"
        sub_issue_child_id[$lineno]="$child_id"
    fi
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
        print_plan "${cmd[@]}"
        return 0
    fi
    log_write "$log" "${cmd[@]}"
    "${cmd[@]}" >/dev/null || die 1 "write failed: close $repo#$issue"
    echo "APPLIED close $repo#$issue ($reason)"
    write_outcome "$outcomes" "$issue" "close" "DONE"
}

apply_retitle() {
    local repo="$1" row="$2" log="$3" execute="$4" outcomes="$5" lineno="$6"
    local issue title previous_title preserve_original
    issue="$(jq -r '.issue // empty' <<<"$row")"
    title="$(jq -r '.title // empty' <<<"$row")"
    previous_title="$(jq -r '.previous_title // empty' <<<"$row")"
    preserve_original="$(jq -r '.preserve_original // false' <<<"$row")"

    local cmd=(gh issue edit "$issue" --repo "$repo" --title "$title")
    local loses_wording
    loses_wording="$(retitle_loses_wording "$previous_title" "$title")"

    if [ "$execute" -eq 0 ]; then
        print_plan "${cmd[@]}"
        if [ "$preserve_original" = "true" ]; then
            if [ "$loses_wording" = "true" ]; then
                print_plan gh issue edit "$issue" --repo "$repo" --body-file -
            else
                echo "NOTE #$issue title wording preserved in new title; body left unchanged"
            fi
        fi
        return 0
    fi

    # Re-check immediately adjacent to the write (challenge round 2 finding
    # 4): pass 1 already ran this same comparison, but pass 1's own
    # validation loop can take long enough — across every other row's live
    # checks — for a concurrent edit to land in the gap before pass 2 gets
    # here. Pass 1 already accepted the plan, so this is reported as a
    # conflict naming the row, not a fresh validation failure; whatever pass 2
    # already wrote for earlier rows is recorded in $log.
    local live_json live_title live_body
    live_json="$(gh issue view "$issue" --repo "$repo" --json title,body)" ||
        die 2 "could not re-read the live title and body of $repo#$issue"
    live_title="$(jq -r '.title // empty' <<<"$live_json")"
    live_body="$(jq -r '.body // ""' <<<"$live_json")"
    local is_resume=false
    if [ "$live_title" != "$previous_title" ]; then
        if [ "$live_title" = "$title" ]; then
            if [ "$preserve_original" = "true" ] && [ "$loses_wording" = "true" ] && ! grep -qF '<!-- groom-original-title -->' <<<"$live_body"; then
                is_resume=true
                echo "NOTE #$issue title already updated to '$title'; resuming original title preservation append"
            else
                echo "NOTE #$issue title already updated to '$title'; row already applied"
                write_outcome "$outcomes" "$issue" "retitle" "DONE"
                return 0
            fi
        else
            die 4 "refused: plan row $lineno (#$issue retitle) conflicts with a" \
                "concurrent edit — the live title changed since pass 1 validated" \
                "this plan (expected '$previous_title', found '$live_title')." \
                "Refresh the plan and re-approve; writes already applied by this" \
                "run are recorded in $log."
        fi
    fi

    if [ "$is_resume" = "false" ]; then
        if [ "$preserve_original" != "true" ] && [ "$loses_wording" = "true" ]; then
            [ "$(is_blank_body "$live_body")" = "false" ] ||
                die 4 "refused: plan row $lineno (#$issue retitle) loses wording from" \
                    "the title, the live issue body is empty, and preserve_original is" \
                    "not true. Set preserve_original: true on the plan row to append" \
                    "an 'Original title' section to the body, or rewrite the title" \
                    "to preserve the outcome wording."
        fi

        log_write "$log" "${cmd[@]}"
        "${cmd[@]}" >/dev/null || die 1 "write failed: retitle $repo#$issue"
        echo "APPLIED retitle $repo#$issue"
        write_outcome "$outcomes" "$issue" "retitle" "DONE"
    else
        write_outcome "$outcomes" "$issue" "retitle" "DONE"
    fi

    if [ "$preserve_original" = "true" ]; then
        if [ "$loses_wording" != "true" ]; then
            echo "NOTE #$issue title wording preserved in new title; body left unchanged"
            return 0
        fi

        live_body="$(gh issue view "$issue" --repo "$repo" --json body -q '.body // ""')" ||
            die 1 "write failed: could not re-read live body of $repo#$issue before appending original title (title already changed to '$title')"

        if grep -qF '<!-- groom-original-title -->' <<<"$live_body"; then
            echo "NOTE #$issue body already carries <!-- groom-original-title -->; skipped append"
            return 0
        fi

        local new_body
        if [ "$(is_blank_body "$live_body")" = "true" ]; then
            new_body="$(printf '## Original title\n<!-- groom-original-title -->\n%s\n' "$previous_title")"
        elif [[ "$live_body" =~ $'\n'$ ]]; then
            new_body="${live_body}"$'\n'"## Original title"$'\n'"<!-- groom-original-title -->"$'\n'"$previous_title"$'\n'
        else
            new_body="${live_body}"$'\n\n'"## Original title"$'\n'"<!-- groom-original-title -->"$'\n'"$previous_title"$'\n'
        fi

        local body_cmd=(gh issue edit "$issue" --repo "$repo" --body-file -)
        local body_sha
        body_sha="$(printf '%s' "$new_body" | sha256_stream)" ||
            die 1 "write failed: compute body sha256 for $repo#$issue (title already changed to '$title')"
        log_write_body "$log" "$body_sha" "${body_cmd[@]}"
        if ! printf '%s' "$new_body" | "${body_cmd[@]}" >/dev/null; then
            die 1 "write failed: append original title to $repo#$issue (title already changed to '$title')"
        fi
        echo "APPLIED retitle-preserve $repo#$issue"
        write_outcome "$outcomes" "$issue" "retitle-preserve" "DONE"
    fi
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
        # Print the PLAN line only — validate_label (pass 1) already invoked
        # this exact triage-apply.sh dry run to validate this row, so calling
        # it again here would be a second, redundant subprocess/API round
        # trip for identical validation with no functional difference
        # (challenge round 3 finding 6).
        print_plan "$triage_apply" "${args[@]}"
        return 0
    fi
    log_write "$log" "$triage_apply" "${args[@]}" "--execute"
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
        print_plan "${cmd[@]}"
        return 0
    fi
    log_write "$log" "${cmd[@]}"
    "${cmd[@]}" >/dev/null || die 1 "write failed: milestone-assign $repo#$issue"
    echo "APPLIED milestone-assign $repo#$issue -> '$milestone_title'"
    write_outcome "$outcomes" "$issue" "milestone-assign" "DONE"
}

apply_sub_issue_link() {
    local repo="$1" row="$2" log="$3" execute="$4" outcomes="$5" lineno="$6"
    local parent child
    parent="$(jq -r '.parent // empty' <<<"$row")"
    child="$(jq -r '.child // empty' <<<"$row")"

    local cmd_desc="gh api repos/$repo/issues/$parent/sub_issues -F sub_issue_id=<id of #$child>"
    if [ "$execute" -eq 0 ]; then
        echo "PLAN $cmd_desc"
        return 0
    fi
    # Use the id pass 1 already resolved and validated (finding 4011648563)
    # instead of re-querying here — a second query would also reopen the
    # exact race the preflight closes.
    local child_id="${sub_issue_child_id[$lineno]:-}"
    [ -n "$child_id" ] ||
        die 1 "internal error: pass 1 did not cache an id for $repo#$child" \
            "(sub-issue-link at plan row $lineno)"
    local cmd=(gh api "repos/$repo/issues/$parent/sub_issues" -F "sub_issue_id=$child_id")
    log_write "$log" "${cmd[@]}"
    "${cmd[@]}" >/dev/null ||
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
        # Verify the outcomes sink is appendable up front too (challenge
        # round 2 finding 8) — the same reasoning as the log check above: a
        # write_outcome failure discovered mid-run, after live GitHub writes
        # have already happened, must never be the thing that aborts the run.
        if [ -n "$outcomes" ]; then
            : >>"$outcomes" 2>/dev/null ||
                die 2 "could not open --outcomes file: $outcomes"
        fi
    fi

    # Read every line into an array FIRST, then iterate it — not a
    # `while read < "$plan_file"` loop. A write op below (gh, or another
    # asset script) may itself read stdin (e.g. a stubbed `gh issue edit`
    # draining `--body-file -`); with a live redirect still open on fd 0 that
    # silently truncates the loop's remaining plan-file input mid-run. Read
    # via a dedicated fd (3), not `mapfile` (bash 4+ only — this script must
    # stay portable to macOS's shipped bash 3.2, challenge round 2 finding 5).
    local lines=() lineno=0 line op
    exec 3<"$plan_file"
    while IFS= read -r line <&3 || [ -n "$line" ]; do
        lines+=("$line")
    done
    exec 3<&-

    # Pass 0 — refuse a plan naming the same op+issue twice outright
    # (challenge round 2 finding 4): a plan-authoring duplicate or leftover
    # row (two retitles for the same issue, say) must never resolve to
    # "whichever pass 2 happens to apply last, silently discarding the
    # other" — no live checks have run yet, so this is cheap to catch first.
    # A plain string list stands in for an associative array (bash 3.2 has
    # none) keyed "op:issue"; sub-issue-link has no single "issue" field and
    # is not covered by this check.
    local seen_keys="" issue_field key
    for line in "${lines[@]+"${lines[@]}"}"; do
        [ -n "$line" ] || continue
        op="$(jq -r '.op // empty' <<<"$line")"
        issue_field="$(jq -r '.issue // empty' <<<"$line")"
        [ -n "$issue_field" ] || continue
        key="$op:$issue_field"
        if grep -qxF "$key" <<<"$seen_keys"; then
            die 2 "refused: plan file has more than one '$op' row for" \
                "#$issue_field — remove the duplicate/leftover and re-approve"
        fi
        seen_keys="$(printf '%s\n%s' "$seen_keys" "$key")"
    done

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
        sub-issue-link) validate_sub_issue_link "$repo" "$line" "$execute" "$lineno" ;;
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
        retitle) apply_retitle "$repo" "$line" "$log" "$execute" "$outcomes" "$lineno" </dev/null ;;
        label) apply_label "$repo" "$line" "$log" "$execute" "$outcomes" </dev/null ;;
        milestone-assign) apply_milestone_assign "$repo" "$line" "$log" "$execute" "$outcomes" </dev/null ;;
        sub-issue-link) apply_sub_issue_link "$repo" "$line" "$log" "$execute" "$outcomes" "$lineno" </dev/null ;;
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
