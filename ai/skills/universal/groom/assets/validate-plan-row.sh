#!/usr/bin/env bash
# validate-plan-row.sh — shared validator for groom plan rows.
#
# Validates single plan rows or an entire plan file against the groom/track-work/triage
# contracts. Used by groom-apply.sh during pass 1 and by report/verdict tooling
# before plan emission to ensure validation rules never drift.
#
# Exit: 0 = valid, 2 = usage/schema error, 4 = contract refusal (bot-owned issue,
#       concurrent title edit, duplicate self-pointer, invalid metadata, etc.).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
check_metadata="$script_dir/../../track-work/assets/check-issue-metadata.sh"
triage_apply="$script_dir/../../triage/assets/triage-apply.sh"
title_module_dir="$script_dir/../../issue-title-support/assets"

usage() {
    echo "Usage: $0 --repo owner/repo (--row JSON | --plan-file PATH) [--execute] [--manifest PATH]" >&2
    exit 2
}

die() {
    local code="$1"
    shift
    echo "validate-plan-row: $*" >&2
    exit "$code"
}

guard_issue_number() {
    local issue="$1"
    case "$issue" in
    '' | *[!0-9]*) die 2 "refused: issue must be a plain issue number (got '$issue')" ;;
    esac
}

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

refuse_if_bot() {
    local repo="$1" issue="$2" row="$3" execute="$4" verb="$5"
    local plan_bot_owned
    plan_bot_owned="$(jq -r '.bot_owned // false' <<<"$row")"
    if [ "$plan_bot_owned" = "true" ]; then
        die 4 "refused: $repo#$issue is bot-authored — groom never ${verb}s a bot-owned issue"
    fi
    if [ "$execute" -eq 1 ] && live_is_bot "$repo" "$issue"; then
        die 4 "refused: $repo#$issue is bot-authored (live re-check) — groom never ${verb}s a bot-owned issue"
    fi
}

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

    if [ "$reason" = "duplicate" ]; then
        local dup_comment dup_target
        dup_comment="$(jq -r '.comment // empty' <<<"$row")"
        dup_target="$(printf '%s' "$dup_comment" | grep -oE '#[0-9]+' | head -1 | tr -d '#')" || true
        [ -n "$dup_target" ] ||
            die 2 "refused: #$issue close reason is duplicate but its comment does not name a canonical issue (expected a '#N' pointer) — track-work's closing contract requires the canonical issue for a duplicate close"
        [ "$dup_target" != "$issue" ] ||
            die 2 "refused: #$issue close reason is duplicate but its comment's canonical pointer names itself (#$dup_target) rather than a different issue"
    fi

    refuse_if_bot "$repo" "$issue" "$row" "$execute" close

    if [ "$reason" = "completed" ]; then
        if [ "$execute" -eq 1 ]; then
            local body_json body
            body_json="$(gh issue view "$issue" --repo "$repo" --json body)" ||
                die 2 "could not re-read the body of $repo#$issue"
            body="$(jq -r '.body // ""' <<<"$body_json")"
            if grep -qE '^[[:space:]]*(>[[:space:]]*)*([-*+]|[0-9]+[.)])[[:space:]]+\[[[:space:]]\]' <<<"$body"; then
                die 4 "refused: #$issue close reason is completed but its live body still has an unticked '- [ ]' task item — track-work's closing contract requires every acceptance item ticked before closing completed"
            fi
        else
            local plan_unticked
            plan_unticked="$(jq -r '.unticked // false' <<<"$row")"
            if [ "$plan_unticked" = "true" ]; then
                echo "NOTE #$issue close reason is completed but the plan row's own 'unticked' hint says an acceptance item is still unchecked — verify before approving"
            fi
        fi
    fi
}

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
            | (sub("^(\\[(P[0-9]+|bug|feature|task|research|documentation|question|enhancement|build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)\\]\\s*:?\\s*|(bug|feature|task|research|documentation|question|enhancement):\\s*|(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\\([^)]*\\))?!?:\\s*|P[0-9]+:\\s*)"; ""; "i")) as $a
            | $b == $a;
            sub("^(\\[(P[0-9]+|bug|feature|task|research|documentation|question|enhancement|build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)\\]\\s*:?\\s*|(bug|feature|task|research|documentation|question|enhancement):\\s*|(build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)(\\([^)]*\\))?!?:\\s*|P[0-9]+:\\s*)"; ""; "i")
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

is_blank_body() {
    local body="$1"
    jq -rn -L "$title_module_dir" --arg b "$body" 'include "issue-title"; ($b | is_blank_body)'
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
                die 4 "refused: #$issue's live title no longer matches the plan's previous_title (expected '$previous_title', found '$live_title') — refresh the plan and re-approve"
            fi
        fi
        if [ "$loses_wording" = "true" ]; then
            if [ "$(is_blank_body "$live_body")" = "true" ] && [ "$preserve_original" != "true" ]; then
                die 4 "refused: #$issue retitle loses original title wording on an empty body — track-work's retitle contract requires preserve_original: true on the plan row to preserve wording"
            fi
            if [ "$preserve_original" = "true" ]; then
                command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
                    die 2 "sha256sum or shasum is required to compute body digest for #$issue"
            fi
        fi
    fi
}

validate_label() {
    local repo="$1" row="$2" execute="$3" manifest="$4"
    local issue
    issue="$(jq -r '.issue // empty' <<<"$row")"
    guard_issue_number "$issue"
    refuse_if_bot "$repo" "$issue" "$row" "$execute" label

    [ -x "$triage_apply" ] || die 2 "triage label helper is missing: $triage_apply"
    local cmd=("$triage_apply" label --repo "$repo" --issue "$issue")
    local add_labels remove_labels l
    add_labels="$(jq -r '.add // [] | .[]' <<<"$row")"
    remove_labels="$(jq -r '.remove // [] | .[]' <<<"$row")"
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        cmd+=(--add "$l")
    done <<<"$add_labels"
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        cmd+=(--remove "$l")
    done <<<"$remove_labels"
    [ -z "$manifest" ] || cmd+=(--manifest "$manifest")

    "${cmd[@]}" >/dev/null || die 4 "refused: #$issue label op failed triage-apply.sh validation"
}

validate_milestone_assign() {
    local repo="$1" row="$2" execute="$3"
    local issue milestone_title
    issue="$(jq -r '.issue // empty' <<<"$row")"
    guard_issue_number "$issue"
    milestone_title="$(jq -r '.milestone_title // empty' <<<"$row")"
    [ -n "$milestone_title" ] ||
        die 2 "refused: #$issue milestone-assign needs milestone_title"
    refuse_if_bot "$repo" "$issue" "$row" "$execute" milestone-assign
}

validate_sub_issue_link() {
    local repo="$1" row="$2" execute="$3"
    local parent child
    parent="$(jq -r '.parent // empty' <<<"$row")"
    child="$(jq -r '.child // empty' <<<"$row")"
    guard_issue_number "$parent"
    guard_issue_number "$child"
    [ "$parent" != "$child" ] ||
        die 2 "refused: sub-issue-link parent and child cannot be the same issue (#$parent)"
}

validate_row() {
    local repo="$1" row="$2" execute="$3" manifest="$4"
    local op
    op="$(jq -r '.op // empty' <<<"$row")"
    case "$op" in
    close) validate_close "$repo" "$row" "$execute" ;;
    retitle) validate_retitle "$repo" "$row" "$execute" ;;
    label) validate_label "$repo" "$row" "$execute" "$manifest" ;;
    milestone-assign) validate_milestone_assign "$repo" "$row" "$execute" ;;
    sub-issue-link) validate_sub_issue_link "$repo" "$row" "$execute" ;;
    *) die 4 "refused: unknown op '$op'" ;;
    esac
}

repo=""
row=""
plan_file=""
execute=0
manifest=""

while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo)
        [ "$#" -ge 2 ] || usage
        repo="$2"
        shift 2
        ;;
    --row)
        [ "$#" -ge 2 ] || usage
        row="$2"
        shift 2
        ;;
    --plan-file)
        [ "$#" -ge 2 ] || usage
        plan_file="$2"
        shift 2
        ;;
    --execute)
        execute=1
        shift
        ;;
    --manifest)
        [ "$#" -ge 2 ] || usage
        manifest="$2"
        shift 2
        ;;
    *) usage ;;
    esac
done

[ -n "$repo" ] || usage
if [ -z "$row" ] && [ -z "$plan_file" ]; then
    usage
fi

if [ -n "$row" ]; then
    validate_row "$repo" "$row" "$execute" "$manifest"
fi

if [ -n "$plan_file" ]; then
    [ -r "$plan_file" ] || die 2 "cannot read plan file: $plan_file"
    line_no=0
    while IFS= read -r r || [ -n "$r" ]; do
        [ -n "$r" ] || continue
        line_no=$((line_no + 1))
        jq -e . >/dev/null 2>&1 <<<"$r" || die 2 "plan file line $line_no is not valid JSON"
        validate_row "$repo" "$r" "$execute" "$manifest"
    done <"$plan_file"
fi
