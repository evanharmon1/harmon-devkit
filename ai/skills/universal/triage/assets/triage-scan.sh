#!/usr/bin/env bash
# triage-scan.sh — read-only backlog scanner for the triage skill.
#
# Emits ONE JSON document with every deterministic fact the classifying model
# needs, so the model (deliberately a cheap one) never composes its own gh
# queries or date math. Writes nothing, ever.
#
# What it computes:
#   - the repo's owner type (User vs Organization — decides whether work-type
#     labels may be written at all; org classification is native issue Type)
#   - the v1 write-allowlist, the active classification axes, and their
#     recognized values (all delegated to triage-apply.sh, the enforcement
#     authority, so the two can never drift) plus label descriptions for
#     classification
#   - per open issue: work-type/axis state (none | ok | conflict), needs-*
#     labels, claim markers, staleness, and candidate flags for the rolling
#     report
#   - per open issue: acceptance-criteria checkbox facts (`criteria` —
#     total/unticked/unticked_ci/unticked_human/unticked_untagged, using the
#     track-work [CI]/[HUMAN] tag grammar) and, from those, high-confidence
#     ADVISORY "possible completion" candidates — `completion_reasons` and the
#     matching `completion-candidate:all-criteria-checked` /
#     `completion-candidate:human-only-remaining` flags. This scan never
#     ticks, edits, or closes anything; it only reports a candidate for a
#     human (or the `delivery` subcommand below) to confirm.
#   - flagged closed issues: closed-completed with unticked acceptance
#     criteria, and duplicate closes (pointer presence is per-issue judgment
#     the skill verifies from comments)
#   - the rolling report issue, which is EXCLUDED from both lists
#     (self-exclusion — the report never scans itself)
#
# Org native Type: newer gh bulk-reads it (`--json issueType`), and where that
# works every open issue carries `native_type_state` (`set` or `unset`) plus
# the exact `native_type` name only when set. Where it does not (older gh),
# state is `unknown`, `native_type` is null, and the skill checks per issue
# (triage-apply.sh native-type) before reporting one missing.
#
# By default only issues needing attention (any flag) are emitted; --all emits
# every open issue. Thresholds (days): TRIAGE_CLAIM_STALE_DAYS (default 14),
# TRIAGE_NEEDS_STALE_DAYS (default 30).
#
# Usage:
#   triage-scan.sh --repo owner/repo [--manifest PATH] [--limit N]
#                  [--closed-limit N] [--all] [--out PATH]
#   triage-scan.sh delivery --repo owner/repo --issue N [--out PATH]
#
# --out writes the scan itself (bound under TRIAGE_SCRATCH when the wrapper
# set it), so the calling model never needs a shell redirection — granted
# Bash commands accept redirections to arbitrary paths, and the skill's own
# idiom must not normalize that.
#
# `delivery` is a second, read-only report: for a single open issue, it looks
# for TRUSTED delivery evidence — a pull request in the SAME repository,
# MERGED, and linked by GitHub's own graph as a cross-referenced timeline
# event — and never a comment, a different repository's PR, an
# unmerged/closed-unmerged one, or a closing-keyword reference (reported as
# context only; see cmd_delivery). It exists so the
# `completion-candidate:human-only-remaining` flag above can be confirmed
# before it is reported: an issue whose [CI] criteria are all ticked and only
# a [HUMAN] one remains still needs a human to close it, but a genuinely
# merged delivery (harmon-init#1080, closed by harmon-init#1107 via "Refs",
# not a closing keyword) is worth surfacing. It writes nothing, ever, and
# never guesses: either read failing reports `indeterminate`, not `none`.
#
# Exit: 0 = scan (or delivery report) emitted, 2 = usage/environment error,
#       4 = refused (repo or out-path outside this run's binding).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
title_module_dir="$script_dir/../../issue-title-support/assets"

usage() {
    echo "Usage: $0 --repo owner/repo [--manifest PATH] [--limit N]" >&2
    echo "          [--closed-limit N] [--all] [--out PATH]" >&2
    echo "       $0 delivery --repo owner/repo --issue N [--out PATH]" >&2
    exit 2
}

die() {
    echo "triage-scan: $*" >&2
    exit 2
}

# gh issue view/edit accept URLs as well as numbers, and a URL names its own
# repository — which would bypass the TRIAGE_REPO binding entirely. Numbers
# only. Same rule as triage-apply.sh.
guard_issue_number() {
    local issue="$1"
    case "$issue" in
    '' | *[!0-9]*) die "refused: --issue must be a plain issue number (got '$issue')" ;;
    esac
}

# Reads are bound too: a scan (or delivery report) of a different repository
# would land that repo's issue data in the run's scratch dir, where the report
# pipeline can publish it. Same rule as the write scripts.
guard_repo_binding() {
    local repo="$1"
    if [ -n "${TRIAGE_REPO:-}" ] && [ "$repo" != "$TRIAGE_REPO" ]; then
        echo "triage-scan: refused: --repo '$repo' does not match this run's" \
            "bound repository '$TRIAGE_REPO'" >&2
        exit 4
    fi
}

# --out is bound under TRIAGE_SCRATCH the same way for both subcommands: the
# calling model never needs a shell redirection, and a path outside this run's
# scratch directory is refused rather than silently honored.
guard_out_path() {
    local out="$1" out_abs
    [ -n "$out" ] || return 0
    [ -n "${TRIAGE_SCRATCH:-}" ] || return 0
    out_abs="$(cd "$(dirname "$out")" 2>/dev/null && pwd)/$(basename "$out")" || {
        echo "triage-scan: could not resolve --out path" >&2
        exit 2
    }
    case "$out_abs" in
    "$TRIAGE_SCRATCH"/*) ;;
    *)
        echo "triage-scan: refused: --out must live under this run's" \
            "scratch directory ($TRIAGE_SCRATCH)" >&2
        exit 4
        ;;
    esac
}

# triage-scan.sh delivery --repo owner/repo --issue N [--out PATH]
#
# Read-only. Looks for TRUSTED delivery evidence for one open issue: a pull
# request that is (a) in the SAME repository as the issue, (b) MERGED, and
# (c) linked by GitHub's own graph as a cross-referenced timeline event whose
# source PR carries a non-null merged_at (the harmon-init#1080/#1107 "Refs"
# case, where no closing keyword ever fired). A comment claiming "done", an
# unmerged or closed-unmerged PR, and a PR from a different repository are
# never evidence.
#
# Closing-keyword links (closedByPullRequestsReferences) are deliberately NOT
# evidence: a `Closes #N` PR that merged while #N is still open is either a
# state-propagation race, a merge to a non-default branch, or a human reopen
# — all ambiguous, so SKILL.md keeps that case unreported. They are still
# read (one GraphQL call, alongside the issue's own state — the `gh issue
# view` JSON field carries neither state nor mergedAt, confirmed live on gh
# 2.98.0) and emitted as `closing_references` so a human can see them.
cmd_delivery() {
    local repo="" issue="" out=""
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
        --out)
            [ "$#" -ge 2 ] || usage
            out="$2"
            shift 2
            ;;
        *) usage ;;
        esac
    done
    [ -n "$repo" ] && [ -n "$issue" ] || usage
    guard_issue_number "$issue"
    guard_repo_binding "$repo"
    guard_out_path "$out"

    local owner name
    owner="${repo%%/*}"
    name="${repo#*/}"

    # Both reads land in temp files, not shell variables: a real timeline page
    # (up to 100 events, each carrying full actor objects) can be large enough
    # that passing it back through --argjson on the command line overflows
    # ARG_MAX, where a --slurpfile read from disk does not.
    local delivery_tmp
    delivery_tmp="$(mktemp -d)" || die "could not create a temp directory"
    trap 'rm -rf "$delivery_tmp"' RETURN

    local closing_ok=1 reason=""
    if ! gh api graphql \
        -f query='query($o: String!, $r: String!, $n: Int!) {
            repository(owner: $o, name: $r) {
              issue(number: $n) {
                number
                state
                closedByPullRequestsReferences(first: 100) {
                  nodes {
                    number
                    state
                    mergedAt
                    repository { nameWithOwner }
                    url
                  }
                }
              }
            }
          }' \
        -f o="$owner" -f r="$name" -F n="$issue" \
        >"$delivery_tmp/closing.json" 2>/dev/null; then
        closing_ok=0
        reason="could not read $repo#$issue's closing pull request links"
    fi
    if [ "$closing_ok" -eq 1 ] &&
        [ "$(jq -r '.data.repository.issue == null' \
            "$delivery_tmp/closing.json" 2>/dev/null)" = "true" ]; then
        closing_ok=0
        reason="$repo#$issue was not found"
    fi

    [ -z "$out" ] || exec >"$out"

    # A non-open issue is settled by the first read alone: no completion
    # candidate, whatever the timeline would say — and no timeline read is
    # spent, so a later read failure can never blur a known closed state.
    if [ "$closing_ok" -eq 1 ]; then
        local issue_state
        issue_state="$(jq -r '.data.repository.issue.state' "$delivery_tmp/closing.json")"
        if [ "$issue_state" != "OPEN" ]; then
            jq -n --arg repo "$repo" --argjson issue "$issue" \
                --arg state "$issue_state" '
              {repo: $repo, issue: $issue, state: $state, verdict: "none",
               evidence: [], closing_references: [], timeline_truncated: false,
               reason: "issue is \($state), not open"}'
            return 0
        fi
    fi

    # One bounded page — not paginated — for cross-referenced (Refs-style)
    # links a closing keyword never produced.
    local timeline_ok=1 timeline_truncated=false
    if ! gh api "repos/$repo/issues/$issue/timeline" -X GET -f per_page=100 \
        >"$delivery_tmp/timeline.json" 2>/dev/null; then
        timeline_ok=0
        [ -n "$reason" ] || reason="could not read $repo#$issue's timeline"
    else
        [ "$(jq 'length' "$delivery_tmp/timeline.json")" -lt 100 ] ||
            timeline_truncated=true
    fi

    if [ "$closing_ok" -eq 0 ] || [ "$timeline_ok" -eq 0 ]; then
        jq -n --arg repo "$repo" --argjson issue "$issue" --arg reason "$reason" '
          {repo: $repo, issue: $issue, state: null, verdict: "indeterminate",
           evidence: [], closing_references: [], timeline_truncated: false,
           reason: $reason}'
        return 0
    fi

    # (3) A cross-referenced event says only that SOME text on the source PR
    # mentioned this issue — a comment on an already-merged PR produces the
    # same event as the PR body does, and comments are never evidence. So each
    # merged same-repo candidate costs one bounded PR read, and only a PR
    # whose own title or body references the issue (`#N`, `owner/repo#N`,
    # or its URL) stays
    # evidence. A failed PR read is indeterminate, never a silent drop.
    # A truncated page already fixes the verdict at indeterminate; do not
    # spend up to 100 PR reads deciding evidence the verdict will not use.
    if [ "$timeline_truncated" = true ]; then
        jq -n --arg repo "$repo" --argjson issue "$issue" '
          {repo: $repo, issue: $issue, state: "OPEN", verdict: "indeterminate",
           evidence: [], closing_references: [], timeline_truncated: true,
           reason: "timeline page truncated at 100 events; later pages unread"}'
        return 0
    fi
    local candidates pr pr_ok=1
    candidates="$(jq -r --arg repo "$repo" '
      [.[] | select(.event == "cross-referenced"
                    and .source.type == "issue"
                    and (.source.issue.pull_request != null)
                    and (.source.issue.pull_request.merged_at != null)
                    and (.source.issue.repository.full_name == $repo))
       | .source.issue.number] | unique | .[]' "$delivery_tmp/timeline.json")"
    printf '[]' >"$delivery_tmp/pr-bodies.json"
    for pr in $candidates; do
        if ! gh api "repos/$repo/pulls/$pr" >"$delivery_tmp/pr-$pr.json" 2>/dev/null; then
            pr_ok=0
            reason="could not read $repo#$pr, a merged pull request cross-referencing this issue"
            break
        fi
        jq -s --argjson pr "$pr" '.[0] + [{pr: $pr,
              title: (.[1].title // ""), body: (.[1].body // "")}]' \
            "$delivery_tmp/pr-bodies.json" "$delivery_tmp/pr-$pr.json" \
            >"$delivery_tmp/pr-bodies.next" &&
            mv "$delivery_tmp/pr-bodies.next" "$delivery_tmp/pr-bodies.json"
    done
    if [ "$pr_ok" -eq 0 ]; then
        jq -n --arg repo "$repo" --argjson issue "$issue" --arg reason "$reason" '
          {repo: $repo, issue: $issue, state: "OPEN", verdict: "indeterminate",
           evidence: [], closing_references: [], timeline_truncated: false,
           reason: $reason}'
        return 0
    fi

    jq -n \
        --arg repo "$repo" \
        --argjson issue_num "$issue" \
        --slurpfile closing_arr "$delivery_tmp/closing.json" \
        --slurpfile timeline_arr "$delivery_tmp/timeline.json" \
        --slurpfile bodies_arr "$delivery_tmp/pr-bodies.json" \
        --argjson timeline_truncated "$timeline_truncated" '
      ($closing_arr[0].data.repository.issue) as $iss
      | ($timeline_arr[0]) as $timeline
      | (($iss.closedByPullRequestsReferences.nodes // [])
         | map(select(.repository.nameWithOwner == $repo and .state == "MERGED")
               | {pr: .number, url: .url, merged_at: .mergedAt})
         | sort_by(.pr)) as $closing_refs
      | ([$timeline[]
          | select(.event == "cross-referenced"
                   and .source.type == "issue"
                   and (.source.issue.pull_request != null)
                   and (.source.issue.pull_request.merged_at != null)
                   and (.source.issue.repository.full_name == $repo)
                   # a closing-keyword PR is context, never evidence — even
                   # when its body (necessarily) also cross-references us
                   and ((.source.issue.number as $p
                         | any($closing_refs[]; .pr == $p)) | not))
          | {pr: .source.issue.number,
             url: .source.issue.pull_request.html_url,
             merged_at: .source.issue.pull_request.merged_at,
             via: "cross-reference"}]
         # keep only PRs whose own title/body names this issue
         | map(. as $ev
               | select(any($bodies_arr[0][]; .pr == $ev.pr
                            and ((.title + "\n" + .body)
                                 | test("(^|[^A-Za-z0-9_/#])(" + ($repo | gsub("\\."; "\\\\.")) + ")?#" + ($issue_num | tostring) + "([^0-9]|$)")
                                   or test("github\\.com/" + $repo + "/issues/"
                                           + ($issue_num | tostring) + "([^0-9]|$)")))))
        ) as $cross_ev
      # A human reopening an issue after its delivery merged is a decision,
      # not a completion signal: evidence merged before the latest `reopened`
      # event is discarded, so only delivery that landed on the CURRENT open
      # span counts.
      | ([$timeline[] | select(.event == "reopened") | .created_at]
         | max // null) as $reopened_at
      | ($cross_ev
         | map(select($reopened_at == null or .merged_at > $reopened_at))
         | unique_by(.pr) | sort_by(.pr)) as $evidence
      | {repo: $repo,
         issue: $issue_num,
         state: $iss.state,
         # A truncated page can hide a later `reopened` event as easily as
         # a later merge, so truncation is indeterminate whatever the first
         # page held — a verdict either way would rest on events unread.
         verdict: (if $iss.state != "OPEN" then "none"
                   elif $timeline_truncated then "indeterminate"
                   elif ($evidence | length) > 0 then "merged-delivery"
                   else "none" end),
         evidence: $evidence,
         closing_references: $closing_refs,
         timeline_truncated: $timeline_truncated}
      # Say why a verdict is not the evidence-driven one, so the calling
      # model can list it under Unverified candidates or drop it knowingly.
      | if $iss.state != "OPEN"
        then .reason = "issue is \($iss.state), not open"
        elif .verdict == "indeterminate"
        then .reason = "timeline page truncated at 100 events; later pages unread"
        elif $reopened_at != null and (.evidence | length) == 0
             and ($cross_ev | length) > 0
        then .reason = "issue was reopened after its merged delivery"
        elif (.evidence | length) == 0 and ($bodies_arr[0] | length) > 0
        then .reason = "merged cross-referencing PR(s) do not name this issue in their own title or body"
        else . end'
}

if [ "${1:-}" = "delivery" ]; then
    shift
    cmd_delivery "$@"
    exit 0
fi

[ -r "$title_module_dir/issue-title.jq" ] ||
    die "shared issue-title predicate is missing"

repo=""
manifest="./label-registry.json"
limit=500
closed_limit=100
all=0
out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --out)
        [ "$#" -ge 2 ] || usage
        out="$2"
        shift 2
        ;;
    --repo)
        [ "$#" -ge 2 ] || usage
        repo="$2"
        shift 2
        ;;
    --manifest)
        [ "$#" -ge 2 ] || usage
        manifest="$2"
        shift 2
        ;;
    --limit)
        [ "$#" -ge 2 ] || usage
        limit="$2"
        shift 2
        ;;
    --closed-limit)
        [ "$#" -ge 2 ] || usage
        closed_limit="$2"
        shift 2
        ;;
    --all) all=1 && shift ;;
    *) usage ;;
    esac
done
[ -n "$repo" ] || usage
guard_repo_binding "$repo"
# Same manifest rule as triage-apply.sh: a bound run reads the repo's own
# manifest only — a worker-writable one would define its own vocabulary.
if [ -n "${TRIAGE_REPO:-}" ] && [ "$manifest" != "./label-registry.json" ]; then
    echo "triage-scan: refused: --manifest is fixed to ./label-registry.json" \
        "in a bound run" >&2
    exit 4
fi

guard_out_path "$out"

claim_stale="${TRIAGE_CLAIM_STALE_DAYS:-14}"
needs_stale="${TRIAGE_NEEDS_STALE_DAYS:-30}"

owner_type="$(gh api "repos/$repo" -q .owner.type)" ||
    die "could not read the owner type of $repo"

allowlist="$("$script_dir/triage-apply.sh" allowlist \
    --repo "$repo" --manifest "$manifest")" ||
    die "could not compute the write-allowlist"
allow_json="$(printf '%s\n' "$allowlist" | jq -R . | jq -s 'map(select(. != ""))')"
# Recognition is wider than writability: a human-only work-type still
# classifies the issue (triage-apply.sh work-types is the one source).
work_types="$("$script_dir/triage-apply.sh" work-types \
    --repo "$repo" --manifest "$manifest")" ||
    die "could not compute the recognized work-type vocabulary"
wt_json="$(printf '%s\n' "$work_types" | jq -R . | jq -s 'map(select(. != ""))')"
# Active axes and their recognized values come from triage-apply.sh too (one
# source, no drift): manifest-derived where a registry exists, the hard-coded
# harmon-init template defaults otherwise. A live label with an active prefix
# but an unrecognized value does NOT classify its axis — it is flagged.
axes="$("$script_dir/triage-apply.sh" axes \
    --repo "$repo" --manifest "$manifest")" ||
    die "could not compute the active classification axes"
axes_json="$(printf '%s\n' "$axes" | jq -R . | jq -s 'map(select(. != ""))')"
axis_values="$("$script_dir/triage-apply.sh" axis-values \
    --repo "$repo" --manifest "$manifest")" ||
    die "could not compute the recognized axis values"
known_json="$(printf '%s\n' "$axis_values" | jq -R . |
    jq -s 'map(select(. != ""))')"

mode="fallback"
if [ -f "$manifest" ]; then
    mode="manifest"
    vocabulary="$(jq --argjson allow "$allow_json" '
      [ .families[]
        | . as $f
        | .values[]?
        | {label: (if ($f.prefix // "") == "" then .value
                   else "\($f.prefix):\(.value)" end),
           description: (.description // "")}
        | select(.label as $l | $allow | index($l) != null)
      ] | unique_by(.label)' "$manifest")"
else
    vocabulary="$(gh label list --repo "$repo" --limit 1000 \
        --json name,description |
        jq --argjson allow "$allow_json" '
          [ .[]
            | {label: .name, description: (.description // "")}
            | select(.label as $l | $allow | index($l) != null)
          ] | unique_by(.label)')"
fi

report="$("$script_dir/triage-report.sh" find --repo "$repo")" ||
    die "could not locate the rolling report issue"
report_json=null
[ "$report" = "none" ] || report_json="$report"

# Org repos classify with native issue Type. Newer gh exposes it in bulk via
# --json issueType; where that works it rides in the SAME list request as the
# issues themselves — a second snapshot could miss issues that moved between
# the two calls and misreport a set Type as unset — so every issue carries a
# native_type and the per-issue graphql check in SKILL.md becomes unnecessary,
# which also stops natively-typed issues starving the reading budget. Older
# gh (or an API refusal) falls back to the per-issue path: native_type_mode
# says which.
open_fields="number,title,labels,createdAt,updatedAt,assignees,body"
native_type_mode="n/a"
open_json=""
if [ "$owner_type" = "Organization" ]; then
    native_type_mode="per-issue"
    if open_json="$(gh issue list --repo "$repo" --state open \
        --limit "$limit" --json "$open_fields,issueType" 2>/dev/null)"; then
        native_type_mode="bulk"
    else
        open_json=""
    fi
fi
if [ -z "$open_json" ]; then
    open_json="$(gh issue list --repo "$repo" --state open --limit "$limit" \
        --json "$open_fields")" ||
        die "could not list open issues of $repo"
fi
closed_json="$(gh issue list --repo "$repo" --state closed \
    --limit "$closed_limit" \
    --json number,title,labels,stateReason,closedAt,body)" ||
    die "could not list closed issues of $repo"

# A page equal to the limit means the backlog may extend beyond it — say so
# in the output rather than letting a truncated snapshot pose as complete.
truncated_open=false
[ "$(jq length <<<"$open_json")" -lt "$limit" ] || truncated_open=true
truncated_closed=false
[ "$(jq length <<<"$closed_json")" -lt "$closed_limit" ] || truncated_closed=true

# open_json/closed_json now carry every issue body (needed for the
# criteria/completion facts below), which at a real repo's scale can be large
# enough that handing them to jq via --argjson on the command line overflows
# ARG_MAX. A temp-file + --slurpfile read does not share that limit.
scan_tmp="$(mktemp -d)" || die "could not create a temp directory"
trap 'rm -rf "$scan_tmp"' EXIT
printf '%s' "$open_json" >"$scan_tmp/open.json"
printf '%s' "$closed_json" >"$scan_tmp/closed.json"

# --out: the scan owns its output file so the caller needs no redirection.
[ -z "$out" ] || exec >"$out"

jq -n -L "$title_module_dir" \
    --arg repo "$repo" \
    --arg owner_type "$owner_type" \
    --arg mode "$mode" \
    --argjson truncated_open "$truncated_open" \
    --argjson truncated_closed "$truncated_closed" \
    --argjson report "$report_json" \
    --argjson allow "$allow_json" \
    --argjson vocabulary "$vocabulary" \
    --slurpfile open_arr "$scan_tmp/open.json" \
    --slurpfile closed_arr "$scan_tmp/closed.json" \
    --argjson claim_stale "$claim_stale" \
    --argjson needs_stale "$needs_stale" \
    --argjson all "$all" \
    --argjson axes "$axes_json" \
    --argjson known "$known_json" \
    --arg native_type_mode "$native_type_mode" \
    --argjson wt "$wt_json" '
  include "issue-title";
  ($open_arr[0]) as $open | ($closed_arr[0]) as $closed |
  def axis_labels($ls; $a): [$ls[] | select(startswith($a + ":"))];
  def axis_known($ls; $a):
    [axis_labels($ls; $a)[] | select(. as $l | $known | index($l) != null)];
  def axis_unknown($ls; $a):
    [axis_labels($ls; $a)[] | select(. as $l | $known | index($l) == null)];
  # A label with an active prefix but a value outside the taxonomy does not
  # classify the axis: state "unknown" (report it), never "ok".
  def axis_state($ls; $a):
    (axis_known($ls; $a) | length) as $n
    | if $n > 1 then "conflict"
      elif $n == 1 then "ok"
      elif (axis_unknown($ls; $a) | length) > 0 then "unknown"
      else "none" end;
  def axis_optional_when_absent($a): $a == "layer";
  def axis_incomplete($ls; $a):
    axis_state($ls; $a) as $state
    | ($state != "ok"
       and ($state != "none" or (axis_optional_when_absent($a) | not)));

  # Acceptance-criteria checkbox facts, for the "possible completion"
  # candidates. checkbox_line_re is the SAME predicate closed_flagged uses
  # below (unordered/ordered markers, any indentation, any blockquote depth),
  # extended to also match a ticked box ([x]/[X]) so a line counts whether
  # ticked or not; checkbox_unticked_re is the original, unticked-only form.
  # Unlike the closed_flagged count, a CRITERION is a top-level rendered item
  # only, and flush-left: a blockquoted `> - [x]` is a quoted example, an
  # indented item is a nested child (or, at four spaces, a code block), and
  # the authoring contract writes criteria at column 0 — so none of those
  # may count; any of them would mint or suppress a completion candidate.
  # The checkbox must be followed by whitespace (or end the line): GitHub
  # renders `- [x][CI]` as plain text, not a task item.
  def checkbox_line_re:
    "^([-*+]|[0-9]{1,9}[.)])[ \\t]+\\[[ \\txX]\\]([ \\t]|$)";
  def checkbox_unticked_re:
    "^([-*+]|[0-9]{1,9}[.)])[ \\t]+\\[[ \\t]\\]([ \\t]|$)";
  # The text immediately after an unticked checkbox marker — used only to
  # classify the track-work [CI]/[HUMAN] tag grammar, never to decide whether
  # a line counts as a criterion (checkbox_unticked_re already decided that).
  def checkbox_rest($line):
    ($line | capture(
      "^([-*+]|[0-9]{1,9}[.)])[ \\t]+\\[[ \\txX]\\]([ \\t]+(?<rest>.*))?$"
    )).rest // "";
  # The track-work tag grammar exactly: case-insensitive [CI]/[HUMAN]
  # immediately after the checkbox, followed by whitespace or end-of-line;
  # anything else unticked is untagged.
  def rest_tag($rest):
    if ($rest | test("^\\[ci\\]([ \\t]|$)"; "i")) then "ci"
    elif ($rest | test("^\\[human\\]([ \\t]|$)"; "i")) then "human"
    else "untagged" end;
  # Only the rendered `## Acceptance criteria` section holds criteria
  # (the track-work authoring contract): a task list in another section, a
  # quoted example, or a fenced code sample is not one, and an issue with no
  # such section has no criteria at all. Lines are taken from that heading
  # (case-insensitive, any trailing hashes) up to the next level-two
  # heading, skipping fenced blocks — which is why this stays a line walk
  # rather than a whole-body regex.
  def criteria_lines($body):
    (($body // "") | split("\n"))
    # A fence closes only on the same delimiter character at least as long
    # as the opener (CommonMark), so a ``` sample nested inside a ```` block
    # does not end it early and count the sample as criteria.
    # One walk tracks three states, fences first: inside a fence nothing is
    # markup (a literal `<!--` in a code sample opens no comment); outside
    # one, HTML-comment spans are invisible when rendered and are blanked
    # (`<!--` to the next `-->`, across lines) before heading/criterion tests.
    | reduce .[] as $raw ({in: false, fence: null, html: false, out: []};
        # A backtick opener whose info string contains a backtick is prose,
        # not a fence (CommonMark); tilde fences carry no such rule.
        (($raw | capture("^[ ]{0,3}(?<f>`{3,}|~{3,})(?<info>.*)$")) // null
         | if . != null and (.f | startswith("`")) and (.info | test("`"))
           then null else . end) as $m
        | if .fence != null then
            (if $m != null and ($m.f[0:1] == .fence[0:1])
                and (($m.f | length) >= (.fence | length))
                and ($raw | test("^[ ]{0,3}(`+|~+)[ \\t]*$"))
             then .fence = null else . end)
          else
            # blank comment spans on this line, carrying open state across
            ((if .html then
                (if ($raw | test("-->")) then {html: false, l: ($raw | sub("^.*?-->"; ""))}
                 else {html: true, l: ""} end)
              else {html: false, l: $raw} end)
             | if (.html | not) and (.l | test("<!--")) then
                 (.l | gsub("<!--.*?-->"; "")) as $g
                 | if ($g | test("<!--")) then {html: true, l: ($g | sub("<!--.*$"; ""))}
                   else {html: false, l: $g} end
               else . end) as $c
            | .html = $c.html
            | ($c.l) as $line
            | if $m != null and ($c.l == $raw) then .fence = $m.f
              # Headings are flush-left, like the criteria: an indented
              # heading may be scoped to an enclosing list item, where a
              # later flush-left task item is a sibling of the list. A
              # level-one heading ends the section too.
              elif ($line | test("^#[ \\t]+")) then .in = false
              elif ($line | test("^##[ \\t]+")) then
                .in = ($line
                       | sub("^##[ \\t]+"; "")
                       | sub("[ \\t]+#+[ \\t]*$"; "")
                       | sub("[ \\t]+$"; "")
                       | ascii_downcase) == "acceptance criteria"
              elif .in then .out += [$line]
              else . end
          end)
    | .out;
  # An untagged box is not a criterion (the track-work contract), ticked or
  # not, so `total`/`unticked` count tagged items only. An UNTICKED untagged
  # box is still reported separately and still blocks both candidates: it is
  # a malformed criterion a human has to read, not one this scan may ignore.
  def criteria_facts($body):
    criteria_lines($body) as $lines
    | ([$lines[] | select(test(checkbox_line_re))
        | select(rest_tag(checkbox_rest(.)) != "untagged")] | length) as $total
    | ([$lines[] | select(test(checkbox_unticked_re))]) as $unticked_lines
    | ([$unticked_lines[] | rest_tag(checkbox_rest(.))]) as $tags
    | ([$tags[] | select(. != "untagged")] | length) as $unticked
    | { total: $total,
        unticked: $unticked,
        unticked_ci: ([$tags[] | select(. == "ci")] | length),
        unticked_human: ([$tags[] | select(. == "human")] | length),
        unticked_untagged: ([$tags[] | select(. == "untagged")] | length) };
  def completion_reasons($crit):
    [ (if ($crit.total >= 1 and $crit.unticked == 0
           and $crit.unticked_untagged == 0)
       then "completion-candidate:all-criteria-checked" else empty end),
      (if ($crit.total >= 1 and $crit.unticked_ci == 0
           and $crit.unticked_untagged == 0 and $crit.unticked_human >= 1)
       then "completion-candidate:human-only-remaining" else empty end) ];

  {
    repo: $repo,
    owner_type: $owner_type,
    mode: $mode,
    axes: $axes,
    native_type_mode: $native_type_mode,
    thresholds: {claim_stale_days: $claim_stale,
                 needs_stale_days: $needs_stale},
    truncated_open: $truncated_open,
    truncated_closed: $truncated_closed,
    report_issue: $report,
    allowlist: $allow,
    vocabulary: $vocabulary,
    work_type_values: $wt,
    open_total: ([$open[] | select(.number != $report)] | length),
    open:
      [ $open[]
        | select(.number != $report)
        | (.labels | map(.name)) as $ls
        | (((now - (.updatedAt | fromdateiso8601)) / 86400) | floor)
            as $days
        | ($ls | map(select(. as $l | $wt | index($l) != null)))
            as $have_wt
        # State and name are separate so a real custom Type named "none" or
        # "null" can never collide with an unset/unavailable sentinel.
        | (if $native_type_mode == "bulk"
           then (if .issueType == null then "unset" else "set" end)
           elif $owner_type == "Organization" then "unknown"
           else "n/a" end) as $nts
        | (if $nts == "set" then .issueType.name else null end) as $nt
        | ($axes | map({key: ., value: axis_state($ls; .)})
           | from_entries) as $ax
        | ($ls | map(select(startswith("needs-")))) as $needs
        | ($ls | map(select(startswith("claim:") or startswith("agent:"))))
            as $claims
        # Completeness reads the owner-appropriate source: on org repos a
        # work-type LABEL proves nothing (native Type owns classification),
        # so where the bulk read resolved the Type it alone decides — a
        # legacy-labeled, natively-untyped issue must not read removable
        # when the apply gate would refuse it. Personal repos, and org
        # repos the bulk read could not cover, still read the labels.
        | (if $owner_type == "Organization" and $nts != "unknown"
           then ($nts == "set")
           else (($have_wt | length) > 0) end)
            as $typed
        # A stray unrecognized label also blocks completeness — the apply
        # script refuses that removal (exit 6), so the scan must not badge
        # the same issue needs-triage-removable.
        | (($typed | not)
           or ([$axes[] | select(axis_incomplete($ls; .))] | length > 0)
           or ([$axes[] | axis_unknown($ls; .) | length] | any(. > 0)))
            as $incomplete
        # needs-triage is RE-ADDED only on a missing work type (personal
        # repos, where labels are authoritative) or a conflicted axis. A bare
        # missing axis is not enough: a removed needs-triage may rest on an
        # --inapplicable attestation, which no label records, and re-adding
        # would churn every legitimately attested issue forever. Org repos
        # remain exempt when native Type state is unknown — an empty label
        # set proves nothing there until the bounded per-issue read runs.
        # The absent layer axis is optional for completeness; a present layer
        # conflict or unknown value still requeues needs-triage below.
        # An unknown value requeues too — checked independently of the axis
        # state (mirroring $incomplete), because a stray label beside a
        # recognized one leaves the state "ok" while the issue still needs
        # a human: an unknown value cannot stand for an inapplicability
        # attestation.
        | (([$ax[]] | any(. == "conflict"))
           or ([$axes[] | axis_unknown($ls; .) | length] | any(. > 0))
           or ($owner_type == "User" and ($have_wt | length) == 0)
           # Bulk-resolved orgs requeue on a definitively unset Type too;
           # the exemption stays only where native Type is unreadable.
           or ($owner_type == "Organization" and $nts == "unset"))
            as $needs_triage_worthy
        | criteria_facts(.body) as $crit
        | completion_reasons($crit) as $creasons
        | {number, title, updatedAt,
           days_since_update: $days,
           labels: $ls,
           assignees: [.assignees[].login],
           work_type: $have_wt,
           native_type_state: $nts,
           native_type: $nt,
           axis_state: $ax,
           axis_labels: ($axes | map({key: ., value: axis_labels($ls; .)})
                         | from_entries),
           # The stray labels by name, so a report entry can say which
           # label needs cleanup — axis_labels alone cannot distinguish a
           # recognized human-only value from an unrecognized one.
           unknown_labels: ($axes
                            | map({key: ., value: axis_unknown($ls; .)})
                            | from_entries
                            | with_entries(select(.value | length > 0))),
           needs_labels: $needs,
           claim_labels: $claims,
           criteria: $crit,
           completion_reasons: $creasons,
           flags:
             ([ # With a bulk-read native Type state, a typed org
                # issue needs no work-type attention at all — the flag fires
                # only where the Type is genuinely unset or unreadable.
                (if ($have_wt | length) == 0
                    and ($owner_type == "User" or $nts != "set")
                 then "missing-work-type" else empty end),
                ($ax | to_entries[]
                 | select(.value == "none"
                         and (axis_optional_when_absent(.key) | not))
                 | "axis-missing:\(.key)"),
                ($ax | to_entries[]
                 | select(.value == "conflict") | "axis-conflict:\(.key)"),
                # Unknown values flag independently of the axis state: a
                # recognized value beside a retired one still reads "ok",
                # but the stray label must surface rather than go quiet.
                ($axes[] | . as $a
                 | select((axis_unknown($ls; $a) | length) > 0)
                 | "axis-unknown-value:\($a)"),
                (if $needs_triage_worthy
                    and (($ls | index("needs-triage")) == null)
                 then "missing-needs-triage" else empty end),
                # Org repos classify by native Type; a work-type LABEL there
                # is legacy and says nothing about the Type. Where the bulk
                # read resolved the Type, flag only issues whose Type is
                # unset; without it, flag every labeled issue so the skill
                # still runs its per-issue native-Type check — otherwise a
                # bug-labeled org issue with complete axes goes quiet and its
                # missing native Type is never noticed.
                (if $owner_type == "Organization" and ($have_wt | length) > 0
                    and $nts != "set"
                 then "legacy-work-type-label" else empty end),
                (if $incomplete and (($ls | index("needs-triage")) != null)
                 then "partially-classified" else empty end),
                (if (($ls | index("needs-triage")) != null)
                    and ($incomplete | not)
                 then "needs-triage-removable" else empty end),
                (if ($claims | length) > 0 and $days > $claim_stale
                 then "stale-claim-candidate" else empty end),
                (if ($ls | index("blocked")) != null
                 then "blocked-candidate" else empty end),
                (if ($needs | length) > 0 and $days > $needs_stale
                 then "aging-needs-candidate" else empty end),
                (if (.title | length) > 70
                 then "title-long" else empty end),
                (if (.title | issue_title_valid | not)
                 then "title-malformed" else empty end),
                $creasons[]
              ])}
        | select(($all == 1) or ((.flags | length) > 0))
      ],
    closed_flagged:
      [ $closed[]
        | select(.number != $report)
        # The same predicate the closing-keywords guard uses: unordered AND
        # ordered markers, any indentation/whitespace, any blockquote depth.
        | ((.body // "") | split("\n")
           | map(select(test(
               "^[ \\t]*(>[ \\t]*)*([-*+]|[0-9]+[.)])[ \\t]+\\[[ \\t]\\]")))
           | length)
            as $unticked
        # gh emits GraphQL-cased reasons (COMPLETED); normalize before
        # comparing so fixtures and live data behave alike.
        | ((.stateReason // "") | ascii_downcase) as $reason
        | select($reason == "duplicate"
                 or ($reason == "completed" and $unticked > 0))
        | {number, title, stateReason: $reason, closedAt,
           unticked_criteria: $unticked}
      ]
  }'
