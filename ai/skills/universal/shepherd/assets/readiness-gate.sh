#!/usr/bin/env bash
# readiness-gate.sh — hard-enforce every step-6 readiness condition before
# `gh pr ready`.
#
# The readiness gate is the one-way door of the shepherd lifecycle: promotion
# notifies CODEOWNERS and requested reviewers, and `gh pr ready --undo` cannot
# unsend that. A hand-assembled gate enforces exactly the conditions its
# author remembered to guard that day — a session-authored one printed failing
# checks in its snapshot and promoted anyway (harmon-devkit#384) — so this
# script wires every condition to an exit code. Nothing is printed-and-passed:
# the first failed condition exits non-zero naming it, and only a full pass
# prints the promotion content fingerprint.
#
# This helper never writes to GitHub. The caller owns `gh pr ready`.
#
# Usage:
#   readiness-gate.sh check --repo OWNER/REPO --pr N --head SHA
#       (--codex-state FILE [--codex-actor-id N] | --codex-disabled)
#       [--allow-edited-root ID]...
#   readiness-gate.sh fingerprint --repo OWNER/REPO --pr N
#
# `check` evaluates the gate for the adjudicated 40-hex head SHA and, on full
# pass only, prints `{"status":"pass",...,"fingerprint":...}`. `fingerprint`
# recomputes the same five-surface content fingerprint with no gate attached —
# it is the post-promotion read the caller compares against `check`'s value.
#
# Exit codes:
#   0  pass — every condition held; the fingerprint is on stdout
#   1  fail — a readiness condition is definitively not met
#   2  indeterminate — a fetch failed, data is malformed, GitHub has not
#      populated an answer yet, or the arguments are unusable. Unknown never
#      passes: 2 is "re-poll or reconcile", never "promote".
#
# `check` emits one JSON line naming the decisive condition:
#   pr-not-open, pr-not-draft, head-mismatch, head-moved   (fail)
#   checks-failing, checks-pending                          (fail)
#   changes-requested, merge-state-dirty, merge-state-behind (fail)
#   threads-unanswered, threads-new-follow-up,
#   threads-edited-since-reply                              (fail)
#   deferred-unchecked, deferred-no-outcome                 (fail)
#   codex-not-clean                                         (fail)
#   checks-indeterminate, merge-state-unknown, fetch-failed,
#   malformed-data, codex-indeterminate, usage              (indeterminate)
#
# Two readiness conditions are deliberately NOT verified here, because no API
# answers them — the caller must hold them as prose prerequisites:
#   - required automation that reacts only to `pull_request.ready_for_review`
#     (a configuration blocker: promotion would notify humans before its
#     result exists);
#   - the Codex Automatic-review knobs being off/Follow-personal (a
#     human-configured prerequisite; GitHub exposes no reliable API for it).
# Nor does a pass certify adjudication QUALITY: the gate proves every inline
# thread carries your reply and every deferred finding a disposition, not that
# either is any good — a human still reads the PR.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  readiness-gate.sh check --repo OWNER/REPO --pr N --head SHA
      (--codex-state FILE [--codex-actor-id N] | --codex-disabled)
      [--allow-edited-root ID]...
  readiness-gate.sh fingerprint --repo OWNER/REPO --pr N

check evaluates every step-6 readiness condition for the adjudicated head;
fingerprint recomputes the five-surface content fingerprint for the
post-promotion compare. --codex-state FILE runs the sibling
check-codex-cloud-review.sh against that attempt state (Codex cloud review
enabled); --codex-disabled records the caller's assertion that no Codex
cloud reviewer is configured. Exactly one of the two is required.
--allow-edited-root ID clears an edited-since-reply line for that thread
root only — the named-exception rule: the caller's report must say why the
edit needs no reply.
EOF
    exit 2
}

die() {
    printf 'readiness-gate: %s\n' "$*" >&2
    exit 2
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

need gh
need jq

timeout_bin=
if command -v timeout >/dev/null 2>&1; then
    timeout_bin=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=gtimeout
else
    die "GNU timeout is required (coreutils; gtimeout on macOS)"
fi

command_name="${1:-}"
[ -n "$command_name" ] || usage
shift

repo=
pr=
head=
codex_state=
codex_disabled=0
codex_actor_id=199175422
allowed_edited_roots='[]'

while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --pr | --head | --codex-state | --codex-actor-id | --allow-edited-root)
        [ "$#" -ge 2 ] || usage
        case "$1" in
        --repo) repo=$2 ;;
        --pr) pr=$2 ;;
        --head) head=$2 ;;
        --codex-state) codex_state=$2 ;;
        --codex-actor-id) codex_actor_id=$2 ;;
        --allow-edited-root)
            printf '%s' "$2" | grep -Eq '^[1-9][0-9]*$' ||
                die "--allow-edited-root must be a thread root comment ID"
            allowed_edited_roots=$(jq -cn \
                --argjson prior "$allowed_edited_roots" \
                --argjson id "$2" '$prior + [$id]')
            ;;
        esac
        shift 2
        ;;
    --codex-disabled)
        codex_disabled=1
        shift
        ;;
    *) usage ;;
    esac
done

valid_repo() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
}

valid_uint() {
    printf '%s' "$1" | grep -Eq '^[1-9][0-9]*$'
}

valid_sha() {
    printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{40}$'
}

[ -n "$repo" ] || usage
[ -n "$pr" ] || usage
valid_repo "$repo" || die "invalid repository: $repo"
valid_uint "$pr" || die "invalid PR number: $pr"

case "$command_name" in
check)
    [ -n "$head" ] || usage
    valid_sha "$head" || die "--head must be a full 40-hex commit"
    # Exactly one Codex mode, explicitly: the Codex condition must not be
    # skippable by silence. Enabled needs the attempt state to judge;
    # disabled is the caller's recorded assertion, not a default.
    if [ -n "$codex_state" ] && [ "$codex_disabled" = 1 ]; then
        die "--codex-state and --codex-disabled are mutually exclusive"
    fi
    if [ -z "$codex_state" ] && [ "$codex_disabled" != 1 ]; then
        die "one of --codex-state or --codex-disabled is required"
    fi
    valid_uint "$codex_actor_id" || die "invalid Codex actor ID"
    ;;
fingerprint) ;;
*) usage ;;
esac

emit() {
    jq -cn \
        --arg status "$1" \
        --arg condition "$2" \
        --arg detail "$3" \
        --arg head "${head:-}" \
        '{status:$status,condition:$condition,detail:$detail,head:$head}'
}

fail_condition() {
    emit fail "$1" "$2"
    exit 1
}

indeterminate() {
    emit indeterminate "$1" "$2"
    exit 2
}

run_gh() {
    "$timeout_bin" -k 1 60 gh "$@"
}

# ---- Fingerprint components (ported from SKILL.md §6's promo_fp recipe) ----
#
# Every component is captured and exit-checked before anything is hashed: a
# failing fetch must abort as indeterminate, or "I could not read this"
# becomes "this did not change" — a stable hash missing a whole surface, which
# then passes the pre/post comparison with maximum confidence. `--slurp`
# output goes to a standalone jq (gh refuses `--slurp` with `--jq`), and the
# transforms keep content-bearing fields only, `sort_by(.id)` and `-S` for
# order-independence: `gh pr ready` mutates the PR object's own `updated_at`
# and draft flag, so including either would make every normal promotion
# invalidate its own fingerprint. An empty component that fetched successfully
# is real state (`add // []`); only a non-zero exit is unknown.
#
# `check` reuses fetches it already gated on (the PR object for the deferred
# findings, the inline comments for the thread predicate), so the fingerprint
# certifies exactly the content the gate evaluated — a comment landing mid-run
# surfaces in the caller's post-promotion compare rather than hiding between
# two reads.

fp_pr=
fp_reviews=
fp_top=
fp_inline=
fp_threads=

fetch_fingerprint_surfaces() {
    # $fp_inline may be pre-seeded by `check` (the thread-predicate fetch).
    owner="${repo%/*}"
    name="${repo#*/}"
    fp_pr="$(run_gh api repos/"$repo"/pulls/"$pr")" ||
        indeterminate fetch-failed "cannot fetch the PR object"
    fp_reviews="$(run_gh api --paginate --slurp repos/"$repo"/pulls/"$pr"/reviews)" ||
        indeterminate fetch-failed "cannot fetch PR reviews"
    fp_top="$(run_gh api --paginate --slurp repos/"$repo"/issues/"$pr"/comments)" ||
        indeterminate fetch-failed "cannot fetch top-level PR comments"
    if [ -z "$fp_inline" ]; then
        fp_inline="$(run_gh api --paginate --slurp repos/"$repo"/pulls/"$pr"/comments)" ||
            indeterminate fetch-failed "cannot fetch inline review comments"
    fi
    fp_threads="$(run_gh api graphql --paginate --slurp \
        -F owner="$owner" -F name="$name" -F pr="$pr" -f query='
      query($owner:String!,$name:String!,$pr:Int!,$endCursor:String){
        repository(owner:$owner,name:$name){ pullRequest(number:$pr){
          reviewThreads(first:100,after:$endCursor){
            pageInfo{hasNextPage endCursor} nodes{id isResolved}}}}}')" ||
        indeterminate fetch-failed "cannot fetch review-thread resolution"
}

compute_fingerprint() {
    c1="$(jq -cS '{title,body}' <<<"$fp_pr")" ||
        indeterminate malformed-data "PR object is not hashable"
    c2="$(jq -c 'add // [] | map({id, u:.user.login, s:.state, b:.body,
                                  t:.submitted_at}) | sort_by(.id)' \
        <<<"$fp_reviews")" ||
        indeterminate malformed-data "reviews payload is not hashable"
    c3="$(jq -c 'add // [] | map({id, u:.user.login, b:.body, t:.updated_at})
                 | sort_by(.id)' <<<"$fp_top")" ||
        indeterminate malformed-data "top-level comments are not hashable"
    c4="$(jq -c 'add // [] | map({id, u:.user.login, b:.body, t:.updated_at})
                 | sort_by(.id)' <<<"$fp_inline")" ||
        indeterminate malformed-data "inline comments are not hashable"
    c5="$(jq -c '[.[].data.repository.pullRequest.reviewThreads.nodes[]]
                 | map({id, r:.isResolved}) | sort_by(.id)' <<<"$fp_threads")" ||
        indeterminate malformed-data "thread resolution is not hashable"
    fingerprint="$(printf '%s\n' "$c1" "$c2" "$c3" "$c4" "$c5" |
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum # stock macOS ships shasum, not sha256sum
        else
            shasum -a 256
        fi)" || indeterminate malformed-data "hashing the fingerprint failed"
    fingerprint="${fingerprint%% *}"
    [ -n "$fingerprint" ] ||
        indeterminate malformed-data "hashing produced an empty fingerprint"
}

if [ "$command_name" = fingerprint ]; then
    fetch_fingerprint_surfaces
    compute_fingerprint
    jq -cn --arg fingerprint "$fingerprint" \
        '{status:"fingerprint",fingerprint:$fingerprint}'
    exit 0
fi

# ---------------------------------- check ----------------------------------

# 1. PR scalars. `gh pr view` is a single-object read (pagination does not
# apply); the list surfaces below all go through --paginate --slurp.
scalars="$(run_gh pr view "$pr" --repo "$repo" \
    --json state,isDraft,headRefOid,reviewDecision,mergeStateStatus)" ||
    indeterminate fetch-failed "cannot fetch the PR state"

pr_state="$(jq -er '.state | select(type == "string")' <<<"$scalars")" ||
    indeterminate malformed-data "PR payload carries no state"
[ "$pr_state" = "OPEN" ] ||
    fail_condition pr-not-open "PR state is $pr_state — only an open draft can be promoted"

jq -e '.isDraft == true' <<<"$scalars" >/dev/null ||
    fail_condition pr-not-draft "PR is not a draft — promotion is idempotently complete or someone else promoted; audit, do not re-promote"

live_head="$(jq -er '.headRefOid | select(type == "string")' <<<"$scalars")" ||
    indeterminate malformed-data "PR payload carries no head commit"
[ "$live_head" = "$head" ] ||
    fail_condition head-mismatch "PR head is $live_head, not the adjudicated $head — re-adjudicate against the new head"

# 2. The PR object (REST). Feeds the deferred-findings condition AND the
# fingerprint's first surface, so the gate judges the exact body it hashes.
fp_pr="$(run_gh api repos/"$repo"/pulls/"$pr")" ||
    indeterminate fetch-failed "cannot fetch the PR object"
rest_head="$(jq -er '.head.sha | select(type == "string")' <<<"$fp_pr")" ||
    indeterminate malformed-data "PR object carries no head commit"
[ "$rest_head" = "$head" ] ||
    fail_condition head-moved "PR head changed while the gate was reading it"

# 3. Required checks, page-safe from the commit itself: check runs plus legacy
# commit statuses are what the PR's checks tab aggregates. `gh pr view`'s
# statusCheckRollup caps at one page, so it cannot be the evidence here.
check_runs_pages="$(run_gh api --paginate --slurp \
    "repos/$repo/commits/$head/check-runs?per_page=100&filter=latest")" ||
    indeterminate fetch-failed "cannot fetch check runs for the head"
check_runs="$(jq -ce \
    '[.[] | if (.check_runs | type) == "array" then .check_runs[]
            else error("page carries no check_runs") end]' \
    <<<"$check_runs_pages" 2>/dev/null)" ||
    indeterminate malformed-data "check-runs payload is malformed"
statuses_pages="$(run_gh api --paginate --slurp \
    "repos/$repo/commits/$head/statuses?per_page=100")" ||
    indeterminate fetch-failed "cannot fetch commit statuses for the head"
# The raw statuses list keeps superseded posts for a context; only the newest
# per context is live, and GitHub comment/status IDs increase monotonically.
statuses="$(jq -ce \
    'add // [] | group_by(.context) | map(max_by(.id))' \
    <<<"$statuses_pages" 2>/dev/null)" ||
    indeterminate malformed-data "commit-statuses payload is malformed"

# An EMPTY list is indeterminate, never a pass: GitHub populates check suites
# asynchronously, so a read moments after a push reports nothing having run
# rather than nothing to run. A repo with genuinely no CI needs a human to say
# so — this gate cannot tell the two apart.
checks_summary="$(jq -cn \
    --argjson runs "$check_runs" \
    --argjson statuses "$statuses" '
      def run_state:
        if .status != "completed" then "pending"
        elif (.conclusion == "success" or .conclusion == "neutral"
              or .conclusion == "skipped") then "ok"
        else "failing" end;
      def status_state:
        if .state == "success" then "ok"
        elif .state == "pending" then "pending"
        else "failing" end;
      ($runs | map({name:(.name // "unnamed check"), state:run_state})) +
      ($statuses | map({name:(.context // "unnamed status"),
                        state:status_state}))
      | {total:length,
         failing:[.[] | select(.state == "failing") | .name],
         pending:[.[] | select(.state == "pending") | .name]}')" ||
    indeterminate malformed-data "check states could not be classified"
[ "$(jq -r '.total' <<<"$checks_summary")" -gt 0 ] ||
    indeterminate checks-indeterminate "GitHub reports no checks for this head — populated asynchronously, so re-poll; if the repo truly has no CI, that is a human call, not a pass"
failing_checks="$(jq -r '.failing | join(", ")' <<<"$checks_summary")"
[ -z "$failing_checks" ] ||
    fail_condition checks-failing "checks failing: $failing_checks"
pending_checks="$(jq -r '.pending | join(", ")' <<<"$checks_summary")"
[ -z "$pending_checks" ] ||
    fail_condition checks-pending "checks not yet concluded: $pending_checks"

# 4. Review decision. REVIEW_REQUIRED (and empty) are expected pre-promotion
# states — the review they wait on is what `gh pr ready` requests. Only
# CHANGES_REQUESTED gates.
review_decision="$(jq -r '.reviewDecision // ""' <<<"$scalars")"
[ "$review_decision" != "CHANGES_REQUESTED" ] ||
    fail_condition changes-requested "a reviewer has requested changes"

# 5. Merge state. BLOCKED (and DRAFT) are PROMOTABLE: on a repo whose ruleset
# requires review, a fully green draft reads BLOCKED by construction, because
# the review it waits on is exactly what promotion requests — requiring CLEAN
# deadlocks precisely the repos that comply (evanharmon1/harmon-init#714).
# Only DIRTY and BEHIND are the caller's to resolve; UNKNOWN means GitHub is
# still computing mergeability.
merge_state="$(jq -r '.mergeStateStatus // ""' <<<"$scalars")"
case "$merge_state" in
DIRTY) fail_condition merge-state-dirty "merge conflicts with the base branch" ;;
BEHIND) fail_condition merge-state-behind "the head is behind the base branch" ;;
UNKNOWN | "")
    indeterminate merge-state-unknown "GitHub is still computing mergeability — re-poll briefly"
    ;;
esac

# 6. Deferred findings in the PR body. Every entry under a "## Deferred
# findings" heading must be ticked, and a tick settles nothing without its
# outcome — `fixed in <sha>`, `declined: <reason>`, or `filed as [#]<n>`
# (the description is contributor-editable, so a bare `- [x]` is a checkbox,
# not a decision). Items span their indented continuation lines.
deferred_summary="$(jq -c '
      def outcome_present:
        test("fixed in [0-9a-f]{7,40}"; "i") or
        test("declined:"; "i") or
        test("filed as [^ ]*#[0-9]+"; "i");
      (.body // "") | gsub("\r"; "") | split("\n")
      | (length) as $count
      | ([to_entries[]
          | select(.value | test("^#{1,6}[[:space:]]*deferred findings[[:space:]]*$"; "i"))
          | .key] | first) as $start
      | if $start == null then {unchecked:[], no_outcome:[]}
        else
          ([to_entries[]
            | select(.key > $start and (.value | test("^#{1,6}[[:space:]]")))
            | .key] | first // $count) as $end
          | .[($start + 1):$end]
          | reduce .[] as $line ([];
              if ($line | test("^[[:space:]]*[-*+][[:space:]]+\\[[ xX]\\]"))
              then . + [$line]
              elif (length > 0 and ($line | test("^[[:space:]]*$") | not)
                    and ($line | test("^[[:space:]]*[-*+][[:space:]]") | not))
              then .[:-1] + [.[-1] + " " + $line]
              else . end)
          | {unchecked:
               [.[] | select(test("^[[:space:]]*[-*+][[:space:]]+\\[ \\]"))],
             no_outcome:
               [.[] | select(test("^[[:space:]]*[-*+][[:space:]]+\\[[xX]\\]"))
                    | select(outcome_present | not)]}
        end' <<<"$fp_pr")" ||
    indeterminate malformed-data "the PR body could not be parsed for deferred findings"
unchecked_count="$(jq -r '.unchecked | length' <<<"$deferred_summary")"
if [ "$unchecked_count" -gt 0 ]; then
    first_unchecked="$(jq -r '.unchecked[0][0:120]' <<<"$deferred_summary")"
    fail_condition deferred-unchecked "$unchecked_count deferred finding(s) still unchecked, e.g.: $first_unchecked"
fi
no_outcome_count="$(jq -r '.no_outcome | length' <<<"$deferred_summary")"
if [ "$no_outcome_count" -gt 0 ]; then
    first_no_outcome="$(jq -r '.no_outcome[0][0:120]' <<<"$deferred_summary")"
    fail_condition deferred-no-outcome "$no_outcome_count ticked entr(y/ies) carry no outcome (fixed in <sha> / declined: / filed as): $first_no_outcome"
fi

# 7. Unanswered inline threads, by reply linkage, never by timestamp — the
# predicate is SKILL.md §2's, verbatim. Guard the identity lookup as carefully
# as the fetch: if `gh api user` fails while the comments endpoint works,
# every comment classifies as reviewer activity — loud, but wrong.
me="$(run_gh api user | jq -er '.login | select(type == "string" and . != "")')" ||
    indeterminate fetch-failed "identity lookup failed — thread answers are unknown, NOT answered"
fp_inline="$(run_gh api --paginate --slurp repos/"$repo"/pulls/"$pr"/comments)" ||
    indeterminate fetch-failed "inline-comment fetch failed — threads are unknown, NOT answered"
threads_needing_attention="$(jq -c --arg me "$me" 'add // []
    | group_by(.in_reply_to_id // .id)
    | map( . as $t
      | ([$t[] | select(.user.login == $me and .in_reply_to_id != null)
               | .created_at] | max) as $mine
      | ([$t[] | select(.user.login != $me
                        and ($mine == null or .created_at >= $mine))
               | .created_at] | max) as $new
      | ([$t[] | select(.user.login != $me and $mine != null
                        and .updated_at >= $mine and .created_at < $mine)
               | .updated_at] | max) as $edit
      | { root: ($t[0].in_reply_to_id // $t[0].id), path: $t[0].path,
          state: (if   $mine == null then "unanswered"
                  elif $new  != null then "new-follow-up"
                  elif $edit != null then "edited-since-reply"
                  else null end),
          at: ($new // $edit) })
    | map(select(.state != null))' <<<"$fp_inline")" ||
    indeterminate malformed-data "inline comments could not be classified"

unanswered_roots="$(jq -r \
    '[.[] | select(.state == "unanswered") | .root] | join(", ")' \
    <<<"$threads_needing_attention")"
[ -z "$unanswered_roots" ] ||
    fail_condition threads-unanswered "inline threads with no reply from you — roots: $unanswered_roots"
follow_up_roots="$(jq -r \
    '[.[] | select(.state == "new-follow-up") | .root] | join(", ")' \
    <<<"$threads_needing_attention")"
[ -z "$follow_up_roots" ] ||
    fail_condition threads-new-follow-up "reviewer follow-ups after your reply — roots: $follow_up_roots"
# edited-since-reply is the one state with an escape hatch, and it is named,
# never blanket: each allowed root must appear in the caller's report with why
# the edit needs no reply.
edited_roots="$(jq -r --argjson allowed "$allowed_edited_roots" \
    '[.[] | select(.state == "edited-since-reply") | .root
         | select(. as $r | $allowed | index($r) | not)] | join(", ")' \
    <<<"$threads_needing_attention")"
[ -z "$edited_roots" ] ||
    fail_condition threads-edited-since-reply "reviewer edits after your reply — re-read and answer, or clear each root explicitly with --allow-edited-root: $edited_roots"

# 8. The current-head Codex cloud-review cycle, where enabled. Classification
# belongs to the sibling helper — run it, never re-derive its evidence.
if [ "$codex_disabled" != 1 ]; then
    codex_helper="$(dirname "$0")/check-codex-cloud-review.sh"
    [ -x "$codex_helper" ] ||
        die "check-codex-cloud-review.sh is not beside this script"
    codex_rc=0
    codex_out="$("$codex_helper" check --state "$codex_state" \
        --actor-id "$codex_actor_id")" || codex_rc=$?
    case "$codex_rc" in
    0) ;;
    10 | 11 | 12 | 13)
        codex_status="$(jq -r '.status // "not clean"' <<<"$codex_out" \
            2>/dev/null || printf 'not clean')"
        fail_condition codex-not-clean "the current-head Codex cycle is ${codex_status} (helper exit $codex_rc), not terminal-clean"
        ;;
    *)
        indeterminate codex-indeterminate "check-codex-cloud-review.sh exited $codex_rc — reconcile the attempt state before promoting"
        ;;
    esac
fi

# 9. The remaining fingerprint surfaces (reviews, top-level comments, thread
# resolution). Thread isResolved is hashed but never gated: resolution is the
# maintainer's act, and rejection-answered threads legitimately stay
# unresolved until a human resolves them.
fetch_fingerprint_surfaces

# 10. The head must not have moved while any of the above was read — a changed
# head invalidates every result this gate relied on. Never wait out a
# mismatch here: a fresh replica showing someone else's newer push is
# evidence, and re-polling until it converges would discard it.
recheck="$(run_gh pr view "$pr" --repo "$repo" --json state,isDraft,headRefOid)" ||
    indeterminate fetch-failed "cannot re-read the PR immediately before the verdict"
jq -e '.state == "OPEN"' <<<"$recheck" >/dev/null ||
    fail_condition pr-not-open "the PR left the OPEN state while the gate was reading it"
jq -e '.isDraft == true' <<<"$recheck" >/dev/null ||
    fail_condition pr-not-draft "the PR was promoted while the gate was reading it"
jq -e --arg head "$head" '.headRefOid == $head' <<<"$recheck" >/dev/null ||
    fail_condition head-moved "PR head changed while the gate was reading it"

compute_fingerprint
jq -cn \
    --arg head "$head" \
    --arg fingerprint "$fingerprint" \
    '{status:"pass",condition:"ready",head:$head,fingerprint:$fingerprint,
      detail:"every mechanically checkable readiness condition holds; ready_for_review-only automation and the Codex Auto-review knobs remain human-verified prerequisites"}'
