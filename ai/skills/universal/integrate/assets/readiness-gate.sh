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
#       --record DIR --integrator-result FILE [--allow-edited-root ID]...
#   readiness-gate.sh audit --repo OWNER/REPO --pr N --head SHA
#       --record DIR --integrator-result FILE [--allow-edited-root ID]...
#   readiness-gate.sh fingerprint --repo OWNER/REPO --pr N
#
# `check` evaluates the gate for the adjudicated 40-hex head SHA and, on full
# pass only, prints `{"status":"pass",...,"fingerprint":...}` — where the
# fingerprint is double-read: computed over the exact content the conditions
# judged, then re-fetched fresh and required identical (`content-moved`
# otherwise), so a mid-gate edit fails before promotion notifies anyone.
# `audit` is the same evaluation with the draft requirement inverted (its
# target must be non-draft — it judges an existing promotion): it answers
# "does this head independently pass everything else" for a PR somebody
# already promoted — §2's unexplained-promotion reconcile branch and §6's
# already-non-draft audit run it instead of hand-rolling the evidence — and
# its pass never authorizes `gh pr ready`; only a passing `check` does.
# `fingerprint` recomputes the same five-surface content fingerprint with no
# gate attached — it is the post-promotion read the caller compares against
# `check`'s value.
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
#   deferred-unsettled                                       (fail)
#   codex-not-clean                                         (fail)
#   checks-indeterminate, merge-state-unknown, fetch-failed,
#   malformed-data, codex-indeterminate, usage              (indeterminate)
#
# Two readiness conditions are deliberately NOT verified here, because no
# API answers them — the caller must hold them as prose prerequisites:
#   - required automation that reacts only to `pull_request.ready_for_review`
#     (a configuration blocker: promotion would notify humans before its
#     result exists);
#   - a required context that NEVER REGISTERED on this head. The checks
#     condition judges every check GitHub reports for the commit; a required
#     workflow that failed to trigger appears in no list, and the only state
#     that encodes it — merge-blockedness — must stay promotable (BLOCKED is
#     the expected pre-review state). "Every required workflow actually ran"
#     is §6's automation-coverage condition, held by the caller.
# Nor does a pass certify adjudication QUALITY: the gate re-checks the
# mechanical surfaces (reply linkage, deferred ticks, review decision) and
# freezes the rest into the fingerprint, but a top-level finding posted after
# the caller's last watch round is frozen, not adjudicated — the caller's §2
# watch owes it, exactly as it did under the hand-run recipe this replaces. A
# human still reads the PR.
#
# Toward the local filesystem and GitHub alike, the gate itself writes
# nothing: --integrator-result is a FILE the caller already has (the
# dispatched integrator agent's own schema-valid result.envelope, role
# integrator — see ai/agents/integrator.md and result.integrator.schema.json),
# never a live state file this script pokes at or a helper it re-invokes.
# --record DIR is the dev-flow-v2 record directory render-dev-flow.mjs reads
# to project current deferred-finding settlement (readiness-input), also
# read-only.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  readiness-gate.sh check --repo OWNER/REPO --pr N --head SHA
      --record DIR --integrator-result FILE [--allow-edited-root ID]...
  readiness-gate.sh audit --repo OWNER/REPO --pr N --head SHA
      --record DIR --integrator-result FILE [--allow-edited-root ID]...
  readiness-gate.sh fingerprint --repo OWNER/REPO --pr N

check evaluates every step-6 readiness condition for the adjudicated head;
audit is the same evaluation with the draft requirement inverted (the PR
must be non-draft), for judging a PR somebody already promoted — its pass
never authorizes gh pr ready.
fingerprint recomputes the five-surface content fingerprint for the
post-promotion compare. --record DIR is the dev-flow-v2 record directory
(run.json plus adjudications/*.json) render-dev-flow.mjs projects deferred-
finding settlement from. --integrator-result FILE is the dispatched
integrator agent's schema-valid result.envelope (role integrator) for this
exact head; its payload's codex_cycle carries the current-head Codex verdict
when the resolved integration cap is not 0, or is null when it is — a null
codex_cycle is how the Codex condition is waived, so there is no separate
disabled flag. Both are always required; there is no mode where either is
skippable.
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
need node

# The record projector lives at a fixed repo-root path, not beside this asset
# script (which the skills-sync vendoring can relocate on its own), so it is
# resolved from the checkout's own toplevel rather than "$(dirname "$0")/..".
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" ||
    die "not inside a git checkout — cannot locate scripts/render-dev-flow.sh"
render_dev_flow="$repo_root/scripts/render-dev-flow.sh"
[ -x "$render_dev_flow" ] ||
    die "$render_dev_flow is missing or not executable"
validate_result_schemas="$repo_root/scripts/validate-result-schemas.mjs"
[ -f "$validate_result_schemas" ] ||
    die "$validate_result_schemas is missing"

# Bounded network calls where GNU timeout exists; a loud, unbounded fallback
# where it does not (stock macOS ships neither `timeout` nor `gtimeout`).
# This gate is mandatory for every promotion, so unlike the optional Codex
# helper it must still run there — the same trade scripts/status.sh makes.
timeout_bin=
if command -v timeout >/dev/null 2>&1; then
    timeout_bin=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=gtimeout
else
    printf 'readiness-gate: no GNU timeout (coreutils; gtimeout on macOS) — network calls are unbounded\n' >&2
fi

command_name="${1:-}"
[ -n "$command_name" ] || usage
shift

repo=
pr=
head=
record_dir=
integrator_result=
allowed_edited_roots='[]'

while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --pr | --head | --record | --integrator-result | --allow-edited-root)
        [ "$#" -ge 2 ] || usage
        case "$1" in
        --repo) repo=$2 ;;
        --pr) pr=$2 ;;
        --head) head=$2 ;;
        --record) record_dir=$2 ;;
        --integrator-result) integrator_result=$2 ;;
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

# check gates promotion, so the PR must still be draft; audit answers the
# reconcile question for a PR somebody already promoted, so it drops exactly
# that one requirement and nothing else.
require_draft=1
case "$command_name" in
check | audit)
    [ "$command_name" = check ] || require_draft=0
    [ -n "$head" ] || usage
    valid_sha "$head" || die "--head must be a full 40-hex commit"
    [ -n "$record_dir" ] || usage
    [ -d "$record_dir" ] || die "--record $record_dir is not a directory"
    # Always required, never a mode switch: the integrator result's own
    # codex_cycle (null vs. non-null) is what says whether the Codex
    # condition applies this pass, so there is no separate disabled flag for
    # the condition to be skippable by silence, or by a false claim, on.
    [ -n "$integrator_result" ] || usage
    [ -f "$integrator_result" ] ||
        die "--integrator-result $integrator_result does not exist"
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
    if [ -n "$timeout_bin" ]; then
        "$timeout_bin" -k 1 60 gh "$@"
    else
        gh "$@"
    fi
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
    # $fp_pr and $fp_inline may be pre-seeded by `check` — deliberately: the
    # EVALUATED fingerprint must hash the exact body the deferred-findings
    # condition judged and the exact comments the thread predicate
    # classified. A silent fresh fetch here would launder a mid-gate edit
    # into a passing fingerprint unvalidated; the fresh read the gate does
    # take is explicit, comes after every condition, and must equal the
    # evaluated one or the gate fails as content-moved.
    owner="${repo%/*}"
    name="${repo#*/}"
    if [ -z "$fp_pr" ]; then
        fp_pr="$(run_gh api repos/"$repo"/pulls/"$pr")" ||
            indeterminate fetch-failed "cannot fetch the PR object"
    fi
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

# ------------------------------ check / audit ------------------------------

# 1. PR scalars. `gh pr view` is a single-object read (pagination does not
# apply); the list surfaces below all go through --paginate --slurp.
scalars="$(run_gh pr view "$pr" --repo "$repo" \
    --json state,isDraft,headRefOid,reviewDecision,mergeStateStatus,headRefName)" ||
    indeterminate fetch-failed "cannot fetch the PR state"

# This PR's own branch name — an extra signal `evaluate_checks` uses below to
# narrow the case actions/runs' own `pull_requests[]` cannot: two open PRs
# sharing a head sha where GitHub returns an EMPTY pull_requests for BOTH
# workflow runs (harmon-devkit#714 shepherd, PR #723's own current-head
# cycle). Not a full answer — two PRs can also share the same branch name
# against different bases — but it costs nothing extra (already part of this
# same `gh pr view` call) and catches the more common case of a differently
# named sibling branch that happens to produce an identical tree.
head_ref_name="$(jq -er '.headRefName | select(type == "string")' <<<"$scalars")" ||
    indeterminate malformed-data "PR payload carries no head branch name"

pr_state="$(jq -er '.state | select(type == "string")' <<<"$scalars")" ||
    indeterminate malformed-data "PR payload carries no state"
[ "$pr_state" = "OPEN" ] ||
    fail_condition pr-not-open "PR state is $pr_state — only an open PR can be gated or audited"

if [ "$require_draft" = 1 ]; then
    jq -e '.isDraft == true' <<<"$scalars" >/dev/null ||
        fail_condition pr-not-draft "PR is not a draft — promotion is idempotently complete or someone else promoted; run audit, do not re-promote"
else
    # Audit judges an existing promotion, so its target must actually be
    # promoted: a PR converted back to draft since the caller observed it
    # has no standing handoff to accept.
    jq -e '.isDraft == false' <<<"$scalars" >/dev/null ||
        fail_condition pr-draft "the PR is a draft — there is no promotion to audit; check is the gate for promoting one"
fi

live_head="$(jq -er '.headRefOid | select(type == "string")' <<<"$scalars")" ||
    indeterminate malformed-data "PR payload carries no head commit"
[ "$live_head" = "$head" ] ||
    fail_condition head-mismatch "PR head is $live_head, not the adjudicated $head — re-adjudicate against the new head"

# 2. The PR object (REST) — the fingerprint's first surface, and a second
# head-moved check independent of the scalar fetch above.
fp_pr="$(run_gh api repos/"$repo"/pulls/"$pr")" ||
    indeterminate fetch-failed "cannot fetch the PR object"
rest_head="$(jq -er '.head.sha | select(type == "string")' <<<"$fp_pr")" ||
    indeterminate malformed-data "PR object carries no head commit"
[ "$rest_head" = "$head" ] ||
    fail_condition head-moved "PR head changed while the gate was reading it"

# 3. Checks, page-safe from the commit itself: check runs plus legacy commit
# statuses are what the PR's checks tab aggregates. `gh pr view`'s
# statusCheckRollup caps at one page, so it cannot be the evidence here. The
# evaluation is a function because it runs twice: here, and again immediately
# before the verdict — the fetches between the two take real time, a rerun or
# late-triggered workflow can turn the commit red inside that window, and
# checks are deliberately not part of the content fingerprint, so nothing
# after promotion would catch it either.
#
# What this judges is every check GitHub REPORTS for the commit. A required
# context that never registered at all is invisible to any list read (only
# merge-blocked-ness encodes it, and BLOCKED must stay promotable), so
# "every required workflow actually ran" remains the §6 automation-coverage
# condition the caller holds — see the header.
evaluate_checks() {
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
    # The raw statuses list keeps superseded posts for a context; only the
    # newest per context is live, and GitHub status IDs increase
    # monotonically.
    statuses="$(jq -ce \
        'add // [] | group_by(.context) | map(max_by(.id))' \
        <<<"$statuses_pages" 2>/dev/null)" ||
        indeterminate malformed-data "commit-statuses payload is malformed"

    # A workflow triggering on pull_request.edited (this repo's two `guard`
    # jobs, one apiece in release-content-guard.yml and tracking-guard.yml)
    # starts a fresh check suite on every PR-body edit against an unchanged
    # head, so a superseded failure sits in the check-runs list alongside a
    # later success forever — the `filter=latest` above collapses runs only
    # WITHIN one check suite, never across the separate suites repeated
    # `pull_request` deliveries create (harmon-devkit#714, found shepherding
    # #713). Collapse to the newest run per (name, workflow, triggering
    # event), the same way the statuses group above collapses per context —
    # but keyed on the *workflow*, not the bare check-run name: this repo's
    # two guard jobs are both literally named "guard", and collapsing by name
    # alone would hide a live failure in one behind a stale success in the
    # other. The event is part of the key, not just the workflow, because a
    # workflow can answer more than one question on the same commit — this
    # repo's build.yml runs on `pull_request`, `push`, `merge_group`, AND
    # `workflow_dispatch` alike, and a manually dispatched success is not a
    # supersession of a failed PR-triggered run of the same job name; only
    # repeated deliveries of the SAME event genuinely re-ask the same
    # question. Workflow/event identity comes from joining each run's
    # check_suite.id against `actions/runs`, which is GitHub-Actions-only; a
    # check run from any other source (a third-party App) has no entry there
    # and falls back to its app id — an App outside Actions does not
    # multiply suites per edit, so a per-app collapse is a safe, conservative
    # default, not a workaround (deferred P2, harmon-devkit#714 challenge r1
    # and r2, re-raised shepherd r2: an App that DID reuse a name across
    # permanently-coexisting, non-superseding suites would still be
    # conflated by app id alone — and the same fallback is reached not only
    # by a genuinely non-Actions App, but also if `actions/runs` ever omits
    # a suite that a real GitHub Actions workflow produced (no confirmed
    # trigger for that on this repo; both paths share the one signal
    # available, `app.id`, and so share the one mitigation); no
    # currently-installed App on this repo produces check-runs at all besides
    # `github-actions`, so the gap is real but unreached, and resolving it
    # generally needs a redesign out of this bounded fix's scope, per #714's
    # own "out of scope" note pointing at #639).
    #
    # "Newest" is resolved per SUITE, by check_suite.id, not `started_at` and
    # not by picking a single highest-id run directly. check_suite.id is
    # assigned in delivery order and strictly increasing, while `started_at`
    # is when a runner picked the job up, which queuing can reorder relative
    # to delivery (and ties outright on two runs started in the same second)
    # — the exact trap the statuses dedup above already avoids by sorting on
    # id rather than a timestamp. Once the newest suite for an identity is
    # found, EVERY run belonging to it is kept, not just one: a workflow can
    # define two jobs that render the same display name (a matrix job with
    # no differentiating `name:`, or simply two job blocks that both
    # hard-code one), and both then land in the same suite under the same
    # _identity. Picking a single highest-id winner across the whole
    # identity group would keep one sibling and silently drop the other's
    # failure even though neither superseded the other — they are
    # simultaneous facts about the same delivery, not a history to collapse.
    # Every run from an older, truly superseded suite for that identity is
    # still dropped (harmon-devkit#714 challenge r2).
    # head_sha alone does not scope to THIS pr: the same commit can back
    # open PRs against more than one base branch, and this endpoint returns
    # every workflow run for the sha regardless of which PR it ran under
    # (harmon-devkit#714 challenge r3). A run's own `pull_requests[]`
    # narrows that, but not cleanly: GitHub populates it with EVERY currently
    # open PR whose head matches this sha, not the one that triggered the
    # run, so a run genuinely triggered by a sibling PR still lists ours
    # whenever both share the head — a same-PR-number membership test alone
    # cannot tell "definitely ours" from "shared, and this run might not be"
    # (harmon-devkit#714 review r1). Three cases, not two: an EMPTY list is
    # not evidence of exclusion (GitHub is known to leave it empty even for
    # a run that genuinely belongs to the PR being gated) and keeps the run
    # exactly as before this filter existed; whether this PR's own number is
    # anywhere IN the list is what decides the rest, not the list's length —
    # a list omitting it entirely is positive proof to exclude, whether it
    # names exactly one other PR or several (harmon-devkit#714 shepherd,
    # fixing an earlier version that treated any 2+-PR list as ambiguous
    # without checking whether this PR was even one of them); a list that
    # DOES include this PR alongside at least one other is genuinely
    # ambiguous and must never be trusted to CLEAR another run's failure,
    # because a sibling PR's base branch can make the identical commit
    # behave differently under base-relative workflow logic (the same
    # reasoning behind scoping runs to a PR at all). Such a
    # run is kept, since dropping it could hide a real failure that IS ours
    # — but review round 2 found kept was not enough on its own: (1) two
    # ambiguous suites for the same nominal workflow/event still shared one
    # `:shared-pr` identity, so a later ambiguous suite could still supersede
    # an earlier one — there is no confident basis for "later ambiguous
    # supersedes earlier ambiguous" any more than there was for "supersedes
    # this PR's own run", so an ambiguous run's identity now folds in its own
    # check_suite.id, making it permanently distinct from every other suite,
    # ambiguous or not; and (2) "other-pr" was excluded only from the
    # workflow-run lookup, not from `check_runs` itself, so its check run
    # still fell through to the app-id identity and — if it happened to be a
    # FAILURE — could still fail a PR it was never really testing. A
    # positively-other-PR check run is now dropped outright, before any
    # identity is computed, not merely disconnected from its metadata. The
    # current-head Codex cycle then found a further gap in the empty-list
    # case itself: TWO open PRs sharing a head sha can both get an empty
    # `pull_requests` from GitHub, in which case both runs read as
    # "unscoped" and collapse together with nothing to tell them apart
    # (harmon-devkit#714 shepherd, PR #723). `pull_requests[]` isn't the only
    # signal available, though — a run's own `head_branch` is, at no extra
    # fetch cost, and a run whose branch is NOT this PR's own branch is
    # excluded exactly like a positively-other-PR run, even when
    # `pull_requests` is empty. This still isn't complete (two PRs can share
    # one branch against different bases, in which case the names match and
    # nothing here would catch it — raised again as a P1 the very next
    # cycle and declined again for the same reason: no further signal is
    # available from this endpoint, closing it needs a mechanism this
    # bounded fix doesn't have, and it needs four simultaneous rare
    # conditions — shared head sha, shared branch, an empty pull_requests
    # from GitHub on top of that, AND base-relative workflow behavior — none
    # of which this repo's own workflows exhibit even one of), but it costs
    # nothing and narrows the common case of a differently named sibling
    # branch that happens to produce an identical tree. Every PR-ownership
    # judgment here — the branch check above, and "does pull_requests[]
    # include this PR" below — applies only to `pull_request`-triggered
    # runs: a `push` or `workflow_dispatch` run has no PR to belong to in
    # the first place (its `pull_requests[]`, when non-empty, is a
    # best-effort historical association GitHub attaches after the fact,
    # not evidence about what the run itself was testing), so judging it
    # against a branch name OR a PR number is the same category error
    # either way — confirmed reachable for the PR-number path too, not just
    # the branch path (harmon-devkit#714 shepherd r3): a stale
    # `pull_requests[]` naming only a sibling PR must not make a real
    # push/workflow_dispatch failure disappear. A missing `head_branch`
    # (some trigger types never set it) keeps the prior behavior —
    # unscoped, kept — rather than excluding on absence.
    #
    # A non-`pull_request` event's identity includes its own branch, not
    # just its workflow and event: the same commit pushed to two different
    # branches produces two independently significant answers, and without
    # the branch in the key both suites would render as the identical
    # `wf:<id>:push`, letting one branch's later success hide the other's
    # earlier failure (harmon-devkit#714 shepherd r3). `pull_request` runs
    # don't need this — the PR itself is already the scoping unit for those.
    workflow_runs_pages="$(run_gh api --paginate --slurp \
        "repos/$repo/actions/runs?head_sha=$head&per_page=100")" ||
        indeterminate fetch-failed "cannot fetch workflow runs for the head"
    workflow_runs="$(jq -ce --argjson pr "$pr" --arg head_ref_name "$head_ref_name" \
        '[.[] | if (.workflow_runs | type) == "array" then .workflow_runs[]
                else error("page carries no workflow_runs") end]
         | map(
             if .event != "pull_request" then . + {_scope: "unscoped"}
             else
               (.pull_requests // []) as $prs |
               (($prs | length) > 0 and any($prs[]; .number == $pr)) as $includes_us |
               if ($prs | length) == 0 then
                 if .head_branch != null and .head_branch != $head_ref_name
                   then . + {_scope: "other-pr"}
                   else . + {_scope: "unscoped"} end
               elif $includes_us and ($prs | length) == 1 then . + {_scope: "this-pr"}
               elif $includes_us then . + {_scope: "ambiguous"}
               else . + {_scope: "other-pr"} end
             end)' \
        <<<"$workflow_runs_pages" 2>/dev/null)" ||
        indeterminate malformed-data "workflow-runs payload is malformed"
    check_runs="$(jq -ce \
        --slurpfile wf_sf <(printf '%s' "$workflow_runs") '
          ($wf_sf[0] | map(select(._scope == "other-pr") | (.check_suite_id | tostring))) as $other_pr_suites |
          ($wf_sf[0] | map(select(._scope != "other-pr") |
                           {key: (.check_suite_id | tostring),
                            value: {workflow_id, event, head_branch, scope: ._scope}}) | from_entries) as $suite_workflow |
          map(select((((.check_suite.id | tostring) as $s | $other_pr_suites | index($s)) // null) == null))
          | map(
              (.check_suite.id | tostring) as $sid |
              (.app.id // 0) as $app_id |
              ($suite_workflow[$sid]) as $sw |
              . + {_identity: [.name,
                  ($sw | if . == null then "app:" + ($app_id | tostring)
                         elif .scope == "ambiguous" then
                           "wf:" + (.workflow_id | tostring) + ":" +
                           (.event // "unknown") + ":shared-pr:" + $sid
                         elif .event != "pull_request" then
                           "wf:" + (.workflow_id | tostring) + ":" +
                           (.event // "unknown") + ":branch:" +
                           (.head_branch // "unknown")
                         else "wf:" + (.workflow_id | tostring) + ":" +
                              (.event // "unknown")
                         end)]})
          | group_by(._identity)
          | map(. as $group | ($group | max_by(.check_suite.id) | .check_suite.id) as $latest_suite |
                $group[] | select(.check_suite.id == $latest_suite))' \
        <<<"$check_runs" 2>/dev/null)" ||
        indeterminate malformed-data "check-runs payload could not be collapsed to latest per workflow"

    # An EMPTY list is indeterminate, never a pass: GitHub populates check
    # suites asynchronously, so a read moments after a push reports nothing
    # having run rather than nothing to run. A repo with genuinely no CI
    # needs a human to say so — this gate cannot tell the two apart.
    # --slurpfile over process substitution, never --argjson: a much-rerun
    # head's check-runs payload exceeds the per-argument limit as argv and jq
    # dies "Argument list too long", which this gate could only report as
    # `malformed-data` — indeterminate for a purely mechanical reason, on
    # exactly the heads it matters most for (observed on harmon-init#821's
    # gate after three infra reruns, 2026-08-12, where it also masked a real
    # merge-state-behind condition). printf is a shell builtin, so no exec
    # carries the payload; the fd does. $runs/$statuses are bound below so the
    # classification program itself is unchanged.
    checks_summary="$(jq -cn \
        --slurpfile runs_sf <(printf '%s' "$check_runs") \
        --slurpfile statuses_sf <(printf '%s' "$statuses") '
          $runs_sf[0] as $runs | $statuses_sf[0] as $statuses |
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
    # Bound the name lists the detail carries: with thousands of failing
    # checks the joined names are themselves a multi-megabyte string, and
    # emit's `jq --arg detail` puts that back into a single argv entry — the
    # same ARG_MAX death the --slurpfile change above just removed, one step
    # downstream. Twenty names diagnose as well as twenty thousand.
    failing_checks="$(jq -r '
        .failing | if length > 20
        then (.[0:20] | join(", ")) + " … and \(length - 20) more"
        else join(", ") end' <<<"$checks_summary")"
    [ -z "$failing_checks" ] ||
        fail_condition checks-failing "checks failing: $failing_checks"
    pending_checks="$(jq -r '
        .pending | if length > 20
        then (.[0:20] | join(", ")) + " … and \(length - 20) more"
        else join(", ") end' <<<"$checks_summary")"
    [ -z "$pending_checks" ] ||
        fail_condition checks-pending "checks not yet concluded: $pending_checks"
}
evaluate_checks

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

# 6. Deferred findings — projected from the record, never parsed from the
# PR body. The rendered "## Deferred findings" section is a VIEW of
# run.json's settlements[], not a second copy: render-dev-flow.mjs's
# readiness-input projection is the one place that reads the record and
# reports which defer-dispositioned findings still lack a settlement. A
# settlement's outcome shape (fixed in <sha> / declined: / filed as <n>) is
# enforced by run.schema.json at write time, so there is no longer a
# "ticked but no outcome" state to separately detect here — the renderer
# either sees a schema-valid settlement or none at all.
# stdout and stderr are captured separately: render-dev-flow.mjs's secret
# scanner logs its own diagnostic lines to stderr on every invocation
# (success included), and merging the two would corrupt the JSON this
# script parses below on the success path — the error message only needs
# stderr, and only on failure.
if ! readiness_input="$("$render_dev_flow" readiness-input \
    --record "$record_dir" --head "$head" 2>/dev/null)"; then
    readiness_input_err="$("$render_dev_flow" readiness-input \
        --record "$record_dir" --head "$head" 2>&1 >/dev/null)" || true
    indeterminate malformed-data "readiness-input projection failed: $readiness_input_err"
fi
projected_head="$(jq -er '.head | select(type == "string")' \
    <<<"$readiness_input" 2>/dev/null)" ||
    indeterminate malformed-data "readiness-input produced no head"
[ "$projected_head" = "$head" ] ||
    indeterminate malformed-data "readiness-input projected head $projected_head, not the gated $head"
unsettled_count="$(jq -r '.deferred_findings.unsettled | length' <<<"$readiness_input")"
if [ "$unsettled_count" -gt 0 ]; then
    first_unsettled="$(jq -r '.deferred_findings.unsettled[0].finding_id' <<<"$readiness_input")"
    fail_condition deferred-unsettled "$unsettled_count deferred finding(s) not yet settled, e.g.: $first_unsettled"
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

# 8. The remaining fingerprint surfaces (reviews, top-level comments, thread
# resolution). Thread isResolved is hashed but never gated: resolution is the
# maintainer's act, and rejection-answered threads legitimately stay
# unresolved until a human resolves them.
fetch_fingerprint_surfaces

# 9. The current-head Codex cloud-review cycle — evaluated from the
# dispatched integrator agent's own schema-valid result, run AFTER the
# fingerprint surfaces are captured, deliberately: activity the agent's own
# fresh evidence collection already classified sits inside the baseline
# fingerprint, and activity landing after that pass sits outside it, where
# the post-promotion compare flags it. Classification belongs to the agent
# and the checker it runs — never re-derived here, only validated and read.
node "$validate_result_schemas" envelope "$integrator_result" >/dev/null 2>&1 ||
    indeterminate codex-indeterminate "--integrator-result $integrator_result is not a schema-valid result.envelope"
integrator_role="$(jq -er '.role | select(type == "string")' \
    "$integrator_result" 2>/dev/null)" ||
    indeterminate malformed-data "integrator result carries no role"
[ "$integrator_role" = integrator ] ||
    indeterminate codex-indeterminate "--integrator-result names role $integrator_role, not integrator"
envelope_head="$(jq -er '.head | select(type == "string")' \
    "$integrator_result" 2>/dev/null)" ||
    indeterminate malformed-data "integrator result carries no head"
[ "$envelope_head" = "$head" ] ||
    indeterminate codex-indeterminate "integrator result is for head $envelope_head, not the gated $head — dispatch a fresh pass against this head"
codex_cycle="$(jq -c '.payload.codex_cycle' "$integrator_result" 2>/dev/null)" ||
    indeterminate malformed-data "integrator result payload is unreadable"
if [ "$codex_cycle" != null ]; then
    cycle_head="$(jq -er '.head | select(type == "string")' \
        <<<"$codex_cycle" 2>/dev/null)" ||
        indeterminate malformed-data "codex_cycle carries no head"
    [ "$cycle_head" = "$head" ] ||
        indeterminate codex-indeterminate "codex_cycle head $cycle_head disagrees with the gated $head"
    codex_exit="$(jq -er '.exit_code | select(type == "number")' \
        <<<"$codex_cycle" 2>/dev/null)" ||
        indeterminate malformed-data "codex_cycle carries no exit_code"
    case "$codex_exit" in
    0) ;;
    10 | 11 | 12 | 13)
        fail_condition codex-not-clean "the current-head Codex cycle exited $codex_exit, not terminal-clean"
        ;;
    *)
        indeterminate codex-indeterminate "codex_cycle exit_code $codex_exit is not a recognized terminal or pending value"
        ;;
    esac
fi
# codex_cycle == null means the resolved integration cap was 0 — the Codex
# condition is waived for this pass, exactly as a schema-valid, cap-0
# integrator result always reports it; nothing further to check here.

# 10. Freeze the evaluated fingerprint, then re-fetch every surface FRESH
# and require equality before any pass. The evaluated fingerprint hashes the
# exact bytes the conditions above judged (the gated body, the classified
# threads); the fresh read is the recipe's "re-fetch and compare as the last
# content read" — a review, comment, body edit, or resolution change landing
# while the gate evaluated fails HERE, before `gh pr ready` notifies anyone,
# not merely in the post-promotion compare that undo cannot fully walk back.
compute_fingerprint
evaluated_fingerprint="$fingerprint"
evaluated_c1="$c1"
evaluated_c2="$c2"
evaluated_c3="$c3"
evaluated_c4="$c4"
evaluated_c5="$c5"
fp_pr=
fp_reviews=
fp_top=
fp_inline=
fp_threads=
fetch_fingerprint_surfaces
compute_fingerprint
if [ "$fingerprint" != "$evaluated_fingerprint" ]; then
    changed_surfaces=""
    [ "$c1" = "$evaluated_c1" ] || changed_surfaces="$changed_surfaces PR-title/body"
    [ "$c2" = "$evaluated_c2" ] || changed_surfaces="$changed_surfaces reviews"
    [ "$c3" = "$evaluated_c3" ] || changed_surfaces="$changed_surfaces top-level-comments"
    [ "$c4" = "$evaluated_c4" ] || changed_surfaces="$changed_surfaces inline-comments"
    [ "$c5" = "$evaluated_c5" ] || changed_surfaces="$changed_surfaces thread-resolution"
    fail_condition content-moved "review content changed while the gate was evaluating (${changed_surfaces# }) — re-adjudicate against the current content"
fi

# 11. Checks, one more time — AFTER the fresh content compare, so no content
# fetch runs behind them: a rerun or a late-triggered workflow can appear on
# this immutable commit while everything above ran, checks sit outside the
# content fingerprint by design, and a pass printed over red CI is exactly
# the failure this script exists to make impossible.
evaluate_checks

# 12. Re-read every scalar condition as the LAST network read before the
# verdict — after the second checks evaluation, so no fetch runs behind it
# (everything after this is local). A changed head
# invalidates every result this gate relied on, and never wait out a
# mismatch: a fresh replica showing someone else's newer push is evidence,
# and re-polling until it converges would discard it. The review decision
# and merge state are re-evaluated here because they can move without moving
# the head: a CHANGES_REQUESTED review landing mid-gate is absorbed into the
# reviews fingerprint (so the post-promotion compare would stay identical),
# and mergeability is excluded from the fingerprint by design — this re-read
# is the only thing that can catch either.
recheck="$(run_gh pr view "$pr" --repo "$repo" \
    --json state,isDraft,headRefOid,reviewDecision,mergeStateStatus)" ||
    indeterminate fetch-failed "cannot re-read the PR immediately before the verdict"
jq -e '.state == "OPEN"' <<<"$recheck" >/dev/null ||
    fail_condition pr-not-open "the PR left the OPEN state while the gate was reading it"
if [ "$require_draft" = 1 ]; then
    jq -e '.isDraft == true' <<<"$recheck" >/dev/null ||
        fail_condition pr-not-draft "the PR was promoted while the gate was reading it"
else
    jq -e '.isDraft == false' <<<"$recheck" >/dev/null ||
        fail_condition pr-draft "the PR returned to draft while the audit was reading it — the promotion under audit no longer stands"
fi
jq -e --arg head "$head" '.headRefOid == $head' <<<"$recheck" >/dev/null ||
    fail_condition head-moved "PR head changed while the gate was reading it"
[ "$(jq -r '.reviewDecision // ""' <<<"$recheck")" != "CHANGES_REQUESTED" ] ||
    fail_condition changes-requested "a reviewer requested changes while the gate was reading"
case "$(jq -r '.mergeStateStatus // ""' <<<"$recheck")" in
DIRTY) fail_condition merge-state-dirty "merge conflicts appeared while the gate was reading" ;;
BEHIND) fail_condition merge-state-behind "the base branch advanced while the gate was reading" ;;
UNKNOWN | "")
    indeterminate merge-state-unknown "GitHub is recomputing mergeability — re-poll briefly"
    ;;
esac

if [ "$require_draft" = 1 ]; then
    verdict_condition=ready
    verdict_detail="every mechanically checkable readiness condition holds"
else
    verdict_condition=audit
    verdict_detail="every mechanically checkable condition except the draft requirement holds; this audits an existing promotion and never authorizes gh pr ready"
fi
jq -cn \
    --arg head "$head" \
    --arg fingerprint "$fingerprint" \
    --arg condition "$verdict_condition" \
    --arg detail "$verdict_detail" \
    '{status:"pass",condition:$condition,head:$head,fingerprint:$fingerprint,
      detail:$detail}'
