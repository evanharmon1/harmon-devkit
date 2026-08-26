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
#
# --out writes the scan itself (bound under TRIAGE_SCRATCH when the wrapper
# set it), so the calling model never needs a shell redirection — granted
# Bash commands accept redirections to arbitrary paths, and the skill's own
# idiom must not normalize that.
#
# Exit: 0 = scan emitted, 2 = usage/environment error,
#       4 = refused (repo or out-path outside this run's binding).
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
title_module_dir="$script_dir/../../issue-title-support/assets"

usage() {
    echo "Usage: $0 --repo owner/repo [--manifest PATH] [--limit N]" >&2
    echo "          [--closed-limit N] [--all]" >&2
    exit 2
}

die() {
    echo "triage-scan: $*" >&2
    exit 2
}

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
# Reads are bound too: a scan of a different repository would land that
# repo's issue data in the run's scratch dir, where the report pipeline can
# publish it. Same rule as the write scripts.
if [ -n "${TRIAGE_REPO:-}" ] && [ "$repo" != "$TRIAGE_REPO" ]; then
    echo "triage-scan: refused: --repo '$repo' does not match this run's" \
        "bound repository '$TRIAGE_REPO'" >&2
    exit 4
fi
# Same manifest rule as triage-apply.sh: a bound run reads the repo's own
# manifest only — a worker-writable one would define its own vocabulary.
if [ -n "${TRIAGE_REPO:-}" ] && [ "$manifest" != "./label-registry.json" ]; then
    echo "triage-scan: refused: --manifest is fixed to ./label-registry.json" \
        "in a bound run" >&2
    exit 4
fi

if [ -n "$out" ] && [ -n "${TRIAGE_SCRATCH:-}" ]; then
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
fi

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
open_fields="number,title,labels,createdAt,updatedAt,assignees"
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
    --argjson open "$open_json" \
    --argjson closed "$closed_json" \
    --argjson claim_stale "$claim_stale" \
    --argjson needs_stale "$needs_stale" \
    --argjson all "$all" \
    --argjson axes "$axes_json" \
    --argjson known "$known_json" \
    --arg native_type_mode "$native_type_mode" \
    --argjson wt "$wt_json" '
  include "issue-title";
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
                 then "title-malformed" else empty end)
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
