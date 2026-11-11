#!/usr/bin/env bash
# update-branch.sh — catch a behind PR up to its base on the server, guarded.
#
# SKILL.md § "Base reconciliation" makes GitHub update-branch the standard way
# to catch a PR up (harmon-devkit#1360, harmon-init ADR 2026-10-11): GitHub
# merges the PR's own base into its branch, CI runs on the merged head, and the
# agent pushes nothing. This is the one write that path needs, and the agent
# posture allows only GET through raw `gh api`, so it lives here, validated to
# do exactly one thing:
#
#   1. re-read the PR and require the head and base the gate captured: a head
#      that moved is a newer push, a base that changed is a retarget;
#   2. send REST `PUT repos/OWNER/REPO/pulls/N/update-branch` with the captured
#      head as `expected_head_sha`. That endpoint takes no other field and
#      always merges. Rebase exists only as GraphQL `updateMethod` or
#      `gh pr update-branch --rebase`; neither is reachable from here, and a
#      rebase flag is refused by name because it rewrites pushed history;
#   3. wait, bounded, for the head to move;
#   4. accept the new head as the catch-up only when GitHub provably made it.
#
# Provenance (step 4). Parents alone are not enough: a writer with push access
# can push a merge commit with the same two parents and a different tree
# (harmon-init#1630). The new head must therefore satisfy all of:
#   - exactly two parents: the captured head first, then the base tip read
#     from refs/heads/<base> in step 1 — or, where the base advanced during
#     the request, a descendant of that tip still reachable from the base
#     branch. Not the PR's `baseRefOid`: GitHub keeps that at the base as of
#     the last head update, so it is stale exactly when a catch-up is needed;
#   - committer `GitHub <noreply@github.com>`;
#   - `verification.verified == true`. GitHub signs the commits it creates with
#     its web-flow key, and a signature that verifies for that committer
#     cannot be produced by anyone else, so it binds the tree as well as the
#     parents. No local trial merge is needed.
# A head that moves but fails any of these is not a catch-up: it is a newer
# push under the readiness gate's "no newer push" condition (exit 12).
#
# Usage:
#   update-branch.sh --repo OWNER/REPO --pr N --head SHA --base BRANCH
#       [--state CHECKER_STATE_FILE] [--record RUN_DIRECTORY] [--maintainer-requested | --queue-head-upkeep REASON]
#       [--wait SECONDS] [--interval SECONDS]
#
#   Callers should pass --state and run a final checker `check` before this
#   helper. An existing cycle must record a clean verdict for the captured
#   head (or its carried head). A superseded cycle does not block this head.
#   Repeat --state for every configured PR-side finder; every named state is
#   structurally guarded. With --record, the run record's resolved policy
#   classifies each state by finder slug: a required finder's cycle must be
#   settled clean. A non-gating finder's cycle that is already terminal
#   (findings or a usage-limit answer recorded, or a released reservation) is
#   reported (advisory-unsettled) and left untouched rather than blocking; a
#   non-gating cycle still reserved or awaiting its answer refuses (17
#   advisory-cycle-open), because moving the head would strand it: catch-up
#   waits until every advisory cycle has reached its own finder's terminal
#   completion signal, or has been settled through that finder's documented
#   path.
#   Without --record, or when the record cannot classify a state, every state
#   is guarded as required. A relaxation also requires a --state for every
#   required finder (17 required-state-missing otherwise).
#   Absent state means no open cycle and prints a one-line notice.
#   Omitting --state preserves legacy behaviour without this ordering guard.
#   Pass --state only once this run has reserved its own cycle (the state's
#   run_id is this run's). At integration cap 0 or before the first reservation,
#   omit --state: no cycle of this run needs settlement, and an earlier run's
#   state must not block reconciliation.
#
#   The catch-up runs at the readiness gate, on a draft. A PR that is no
#   longer a draft needs an explicit authorization: --maintainer-requested
#   asserts the maintainer's request; --queue-head-upkeep REASON prints the
#   supplied reason for the orchestrator's current merge-queue-head upkeep
#   (ruling 53). The caller verifies that this PR is the queue head before
#   using that flag; it is not blanket permission to update other ready PRs.
#   The check runs again on every re-read after the request, so a promotion
#   that lands while GitHub merges is reported too (15) — the merge may
#   already have happened, which the caller reports rather than acts on.
#
#   --head and --base are what the readiness gate captured (`headRefOid`,
#   `baseRefName`). --wait bounds step 3 by wall clock (default 180): the
#   deadline is fixed when the wait starts, and each re-read is cut short at
#   the time left, so a slow read cannot stretch it. --interval is the pause
#   between re-reads (default 5). Every gh call is bounded with GNU `timeout`
#   (or `gtimeout` on macOS). Without either the helper fails closed (13)
#   before any GitHub call: an unbounded read could stretch the wait without
#   limit.
#
# On success prints the new head OID (bare 40-hex) on stdout. A PR GitHub
# reports already level prints the captured head unchanged. Diagnostics go to
# stderr as `update-branch: <token>: <detail>`.
#
# Exit codes:
#    0  caught up (or already level) — fast-forward to the printed OID
#    2  usage error, or a refusal by this helper (any rebase mode)
#   10  ruleset refusal — GitHub answered that a repository rule rejects the
#       merge it would make (a "rule violation"), and the rule is not a ban on
#       merge commits. Only this and 11 take the local-merge fallback.
#   11  conflict — the base does not merge cleanly. Local-merge fallback.
#   12  stale head — the head is not the one captured (expected_head_sha
#       refused, or a re-read shows another head), or it moved to a head that
#       is not GitHub's catch-up. A newer push: re-read the PR and re-run the
#       gate. Never a reason to fall back to a local merge.
#   13  indeterminate — the head was still unmoved when the wait ended, or a
#       response could not be read. The request may still be pending: stop
#       and report, never request again.
#   14  retarget — `baseRefName` is not the captured base. `base-retargeted`
#       applies; nothing is merged against the new base.
#   15  not a draft — the PR is ready for review, before the request or
#       after it, without --maintainer-requested or --queue-head-upkeep.
#       Report drift; do not act without either authorization.
#   16  refused, not a merge refusal a local merge can satisfy — a ban on
#       merge commits (linear history: a local merge breaks the same rule and
#       cannot be pushed), or any other 4xx: rate limiting, an
#       authentication or permission failure, a fork without maintainer edits,
#       a 422 whose message is not a known merge refusal, or a PR that is not
#       open. Never the fallback: stop and report (for a fork, ask for
#       maintainer edits).
#   17  unsettled cycle — a required finder's --state does not record a
#       settled clean cycle for this PR/head, any --state cannot be read, an
#       advisory cycle is not yet terminal, or an advisory relaxation lacks a
#       required finder's state. For a required cycle run a final checker
#       `check` first; an advisory cycle waits for its own finder's terminal
#       completion signal or its finder's documented settlement. No GitHub
#       write was made. Never a local-merge fallback.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  update-branch.sh --repo OWNER/REPO --pr N --head SHA --base BRANCH
      [--state CHECKER_STATE_FILE] [--record RUN_DIRECTORY] [--maintainer-requested | --queue-head-upkeep REASON]
      [--wait SECONDS] [--interval SECONDS]

Catches a behind PR up to its base with GitHub update-branch in merge mode,
guarded by --head as expected_head_sha. Prints the new head OID.
Rebase is refused. A non-draft PR requires --maintainer-requested or
--queue-head-upkeep (orchestrator authorization for the current queue head). Exit codes: 0 caught up,
2 usage, 10 ruleset refusal, 11 conflict, 12 stale head,
13 indeterminate (including no timeout/gtimeout on PATH), 14 retarget,
15 not a draft, 16 refused otherwise, 17 unsettled cycle (run final check first).
Callers should pass --state once per configured PR-side finder; repeats guard
every named state. With --record, a finder the run's resolved policy does not
require (gates=false, budget 0, or integration cap 0) is reported, not blocked,
once its cycle is terminal (findings, usage limit, or released); one still
reserved or awaiting its answer refuses with 17 advisory-cycle-open. Without
--record every state is guarded as required. A superseded cycle does not
block the captured head.
Missing state means no open cycle and prints a one-line notice on stderr.
Pass --state only once this run has reserved its own cycle (the state's run_id
is this run's). At integration cap 0 or before the first reservation, omit
--state: no cycle of this run needs settlement, and an earlier run's state
must not block reconciliation.
EOF
    exit 2
}

refuse() {
    printf 'update-branch: refused: %s\n' "$*" >&2
    exit 2
}

# finish TOKEN CODE DETAIL — report a non-zero outcome and exit with CODE.
finish() {
    printf 'update-branch: %s: %s\n' "$1" "$3" >&2
    exit "$2"
}

command -v gh >/dev/null 2>&1 || refuse "gh is required"
command -v jq >/dev/null 2>&1 || refuse "jq is required"

valid_repo() {
    grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' <<<"$1"
}

valid_uint() {
    grep -Eq '^[0-9]+$' <<<"$1"
}

valid_sha() {
    grep -Eq '^[0-9a-f]{40}$' <<<"$1"
}

repo=
pr=
head=
base=
wait_sec=180
interval_sec=5
maintainer_requested=0
queue_head_upkeep=0
queue_head_reason=
checker_states=()
state_count=0
record_dir=

[ "$#" -gt 0 ] || usage
while [ "$#" -gt 0 ]; do
    case "$1" in
    --rebase | --update-method | --update-method=* | --method | --method=*)
        refuse "$1: update-branch runs in merge mode only — a rebase rewrites pushed history"
        ;;
    --repo | --pr | --head | --base | --wait | --interval | --state | --record)
        [ "$#" -ge 2 ] || usage
        case "$1" in
        --repo) repo=$2 ;;
        --record) record_dir=$2 ;;
        --pr) pr=$2 ;;
        --head) head=$2 ;;
        --base) base=$2 ;;
        --wait) wait_sec=$2 ;;
        --interval) interval_sec=$2 ;;
        --state)
            [ -n "$2" ] || refuse "--state requires a checker-state file path"
            checker_states+=("$2")
            state_count=$((state_count + 1))
            ;;
        esac
        shift 2
        ;;
    --maintainer-requested)
        maintainer_requested=1
        shift
        ;;
    --queue-head-upkeep)
        [ "$#" -ge 2 ] || refuse "--queue-head-upkeep requires a reason"
        [[ "$2" != --* ]] && [[ "$2" =~ [^[:space:]] ]] || refuse "--queue-head-upkeep requires a reason"
        queue_head_upkeep=1
        queue_head_reason=$2
        shift 2
        ;;
    -h | --help) usage ;;
    *) refuse "unrecognised argument: $1" ;;
    esac
done

valid_repo "$repo" || refuse "--repo must be OWNER/REPO"
grep -Eq '^[1-9][0-9]*$' <<<"$pr" || refuse "--pr must be a positive integer"
valid_sha "$head" || refuse "--head must be a 40-hex commit SHA"
[ -n "$base" ] || refuse "--base is required (the baseRefName the gate captured)"
valid_uint "$wait_sec" || refuse "--wait must be a non-negative integer"
valid_uint "$interval_sec" || refuse "--interval must be a non-negative integer"

if [ "$queue_head_upkeep" -eq 1 ]; then
    printf 'update-branch: queue-head-upkeep: %s\n' "$queue_head_reason" >&2
fi

# State is an ordering guard, not a replacement for check's live evidence
# scan. Only a cycle or carry for the captured head needs a clean verdict;
# an older cycle superseded by a push cannot attest this head anyway.
#
# Required or advisory (harmon-devkit#1887). The verdict guard binds a finder
# the run's resolved policy requires. A non-gating (advisory) finder's cycle
# that is already TERMINAL does not block a catch-up: it is reported, never
# written, so its state, budget and recorded findings stay exactly as they are
# for adjudication. Its evidence is already collected, and once the head moves
# the checker's `check` on that state stops at head-changed while `reserve`
# accepts a fresh attempt-1 cycle on the new head. A NON-TERMINAL advisory
# cycle (reserved, or attached with no answer yet) refuses instead: after the
# move `check` would stop at head-changed before reading its late evidence,
# `attach` refuses the moved head, and a reserved state blocks the finder's
# next reservation, so the catch-up would strand it. Terminal means attached
# with a recorded findings verdict for its own head, attached with a recorded
# usage-limit answer, or released (never triggered). A clean cycle passes the
# guard above on its own. The class
# comes only from the trusted run record (`--record`: its run.json binding and
# policy.json), never from the caller or a candidate branch. Without a record,
# or when the record cannot classify every named finder, every state is
# guarded as required, which is the behaviour before this split.
state_finder() {
    # A state with no finder profile is the legacy Codex cycle.
    jq -r '.finder.slug // "codex-cloud" | select(type == "string")' "$1" 2>/dev/null
}
finder_classes='{}'
required_finders='[]'
classified=0
if [ -n "$record_dir" ] && [ "$state_count" -gt 0 ]; then
    state_slugs=()
    unknown_slug=0
    for checker_state in "${checker_states[@]}"; do
        [ -e "$checker_state" ] || [ -L "$checker_state" ] || continue
        slug="$(state_finder "$checker_state")" && [ -n "$slug" ] || {
            unknown_slug=1
            continue
        }
        state_slugs+=("$slug")
    done
    if [ "$unknown_slug" -eq 0 ] && [ "${state_slugs[*]+set}" = set ]; then
        requirements_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../../dev-flow-support/assets/lib"
        # stdout is the projection; a refusal's message is folded in so it
        # can be reported, and anything that is not the projection fails jq.
        if projection="$(node "$requirements_dir/integration-finder-requirements.mjs" classify \
            --record "$record_dir" --repo "$repo" --pr "$pr" "${state_slugs[@]}" 2>&1)" &&
            finder_classes="$(jq -ce '.classes | select(type == "object")' <<<"$projection" 2>/dev/null)" &&
            required_finders="$(jq -ce '.required | select(type == "array")' <<<"$projection" 2>/dev/null)"; then
            classified=1
        else
            printf 'update-branch: finder-policy-indeterminate: %s — every state is guarded as required\n' \
                "$(tr '\n' ' ' <<<"${projection:-classification failed}")" >&2
            finder_classes='{}'
            required_finders='[]'
        fi
    elif [ "$unknown_slug" -eq 1 ]; then
        printf 'update-branch: finder-policy-indeterminate: a named state carries no readable finder slug — every state is guarded as required\n' >&2
    fi
fi

relaxed=0
supplied_finders='[]'
for checker_state in ${checker_states[@]+"${checker_states[@]}"}; do
    if [ ! -e "$checker_state" ] && [ ! -L "$checker_state" ]; then
        printf 'update-branch: no-cycle-state: guard found no cycle state at %s\n' "$checker_state" >&2
        continue
    fi
    # Structure binds every state, advisory or not: a foreign, malformed or
    # unsupported file is a wiring error, never a non-gating reviewer.
    if ! jq -se --arg repo "$repo" --argjson pr "$pr" '
        length == 1 and (.[0] |
          type == "object" and .repo == $repo and .pr == $pr and
          (.version == 1 or .version == 2) and
          (.head | type == "string" and test("^[0-9a-f]{40}$")))
    ' "$checker_state" >/dev/null 2>&1; then
        finish unsettled-cycle 17 "checker state does not record a settled clean cycle for ${repo}#${pr} at ${head} — run a final checker check first, then catch up; no GitHub write was made"
    fi
    slug="$(state_finder "$checker_state")" || slug=
    finder_class=required
    if [ "$classified" -eq 1 ] && [ -n "$slug" ]; then
        finder_class="$(jq -r --arg s "$slug" '.[$s] // "required"' <<<"$finder_classes")"
        supplied_finders="$(jq -c --arg s "$slug" '. + [$s]' <<<"$supplied_finders")"
    fi
    if ! jq -e --arg head "$head" '
        if .head == $head or .carry.attests_head == $head then
          .phase == "attached" and .last_reviewed_verdict == "clean" and
          .last_reviewed_head == .head
        else true end
    ' "$checker_state" >/dev/null 2>&1; then
        [ "$finder_class" = advisory ] ||
            finish unsettled-cycle 17 "checker state does not record a settled clean cycle for ${repo}#${pr} at ${head} — run a final checker check first, then catch up; no GitHub write was made"
        state_phase="$(jq -r '.phase // "none"' "$checker_state")"
        state_verdict="$(jq -r '.last_reviewed_verdict // "none"' "$checker_state")"
        # Only an advisory cycle the checker can reserve afresh on the new
        # head without a cycle receipt may be left behind by a head move: a
        # released reservation, or a usage-limit answer (no verdict). A cycle
        # with a verdict for its own head cannot be left: the checker's
        # reserve owes it a receipt, and no non-gating cycle can be receipted
        # yet (harmon-devkit#1944). Anything else fails closed.
        jq -e '
            .phase == "released" or
            (.phase == "attached" and
              (.quota_exhausted_at | type == "string" and length > 0))
        ' "$checker_state" >/dev/null 2>&1 || {
            # The recovery is stated as the invariant, not a command recipe:
            # the checker's own recovery subcommands are Codex-only (`release`
            # accepts only an untriggered `@codex review` reservation), so a
            # recipe naming them would send another finder down a path that
            # refuses. Name them only for the Codex cycle they serve.
            codex_recovery=
            [ "$slug" != codex-cloud ] ||
                codex_recovery=" For this Codex cycle that means a checker check that answers a usage limit, or a checker release of an untriggered reservation."
            verdict_block=
            if jq -e '.last_reviewed_head == .head and
                (.last_reviewed_verdict == "clean" or .last_reviewed_verdict == "findings")' \
                "$checker_state" >/dev/null 2>&1; then
                verdict_block=" A cycle with a verdict for its own head blocks catch-up until a non-gating cycle can be receipted (harmon-devkit#1944): the checker owes it a receipt before reserving the finder afresh."
            fi
            finish advisory-cycle-open 17 "${slug} cycle at ${checker_state} is non-gating but cannot be left behind (phase ${state_phase}, verdict ${state_verdict}) — moving the head now would strand it. Catch-up waits until every advisory cycle has reached its own finder's terminal completion signal, or has been settled through that finder's documented path.${verdict_block}${codex_recovery} No GitHub write was made"
        }
        relaxed=1
        printf 'update-branch: advisory-unsettled: %s cycle at %s is non-gating under the run'"'"'s resolved policy and already terminal (phase %s, verdict %s, usage limit %s) — not a completed clean review. The helper writes no state: its recorded verdict, budget and findings stay as they are for adjudication. After the head moves, checker check on this state stops at head-changed and reads no further evidence; reserve a fresh cycle on the new head if this finder is to review it\n' \
            "$slug" "$checker_state" "$state_phase" "$state_verdict" \
            "$(jq -r 'if (.quota_exhausted_at | type == "string" and length > 0) then "answered" else "none" end' "$checker_state")" >&2
    fi
    if jq -e --arg head "$head" '(.run_id | type == "string" and length > 0) and (.head == $head or .carry.attests_head == $head)' "$checker_state" >/dev/null; then
        [ -n "$record_dir" ] ||
            finish integration-receipt-required 17 "a run-owned terminal cycle requires --record before catch-up; capture and receipt its integrator pass first"
    fi
    if [ -n "$record_dir" ]; then
        receipt_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
        node "$receipt_script_dir/../../dev-flow-support/assets/lib/integrator-review-authority.mjs" \
            require-receipt "$record_dir" "$checker_state" ||
            finish integration-receipt-required 17 "capture and receipt the current terminal review before catch-up; no GitHub write was made"
    fi
done
# An advisory relaxation is earned only alongside every required finder's
# own guard: omitting a required state cannot leave it unchecked.
if [ "$relaxed" -eq 1 ]; then
    missing="$(jq -rn --argjson req "$required_finders" --argjson got "$supplied_finders" \
        '[$req[] | select(. as $r | $got | index($r) | not)] | join(", ")')"
    [ -z "$missing" ] ||
        finish required-state-missing 17 "an advisory cycle was relaxed but no present, readable --state names required finder(s) ${missing} — pass every required finder's state; no GitHub write was made"
fi

timeout_bin=
if command -v timeout >/dev/null 2>&1; then
    timeout_bin=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=gtimeout
fi
# Fail closed: the wall-clock bound depends on cutting a read short.
[ -n "$timeout_bin" ] ||
    finish indeterminate 13 "neither timeout nor gtimeout is on PATH (GNU coreutils; gtimeout on macOS) — no GitHub call was made"

# run_gh_for SECONDS ARGS... — gh, cut short after SECONDS.
run_gh_for() {
    limit=$1
    shift
    "$timeout_bin" -k 1 "$limit" gh "$@"
}

run_gh() {
    run_gh_for 60 "$@"
}

# read_pr [SECONDS] — the PR's head and base, bounded by SECONDS (default 60).
read_pr() {
    run_gh_for "${1:-60}" pr view "$pr" --repo "$repo" --json state,isDraft,headRefOid,baseRefName,baseRefOid
}

# field JSON NAME — a required string field, or non-zero.
field() {
    jq -er --arg k "$2" '.[$k] | select(type == "string")' <<<"$1"
}

# ---- 1. re-read: the head and base must still be the captured ones ----------
before="$(read_pr)" ||
    finish indeterminate 13 "cannot read PR #${pr} before requesting update-branch"
state="$(field "$before" state)" ||
    finish indeterminate 13 "PR read carries no state"
[ "$state" = OPEN ] ||
    finish refused 16 "PR #${pr} is ${state}, not open"
# Not `jq -e`: it fails on a false value, which is the one this check needs.
is_draft="$(jq -r '.isDraft | if type == "boolean" then tostring else error("no isDraft") end' <<<"$before")" ||
    finish indeterminate 13 "PR read carries no isDraft"
[ "$is_draft" = true ] || [ "$maintainer_requested" = 1 ] || [ "$queue_head_upkeep" = 1 ] ||
    finish not-draft 15 "PR #${pr} is ready for review — catch-up requires --maintainer-requested or orchestrator-authorized --queue-head-upkeep; otherwise report its drift"
current_base="$(field "$before" baseRefName)" ||
    finish indeterminate 13 "PR read carries no baseRefName"
[ "$current_base" = "$base" ] ||
    finish retarget 14 "the PR base is ${current_base}, not the captured ${base} — base-retargeted applies"
current_head="$(field "$before" headRefOid)" ||
    finish indeterminate 13 "PR read carries no headRefOid"
[ "$current_head" = "$head" ] ||
    finish stale-head 12 "the PR head is ${current_head}, not the captured ${head} — a newer push; re-run the gate"
# The base tip from the branch itself, never the PR's baseRefOid (see the
# provenance note above). Ref encoding as readiness-gate.sh does it.
encoded_base="$(jq -rn --arg s "$base" '$s | @uri | gsub("%2F"; "/")')"
read_base_tip() {
    run_gh api --method GET "repos/${repo}/git/ref/heads/${encoded_base}" |
        jq -er '.object.sha | select(type == "string")'
}
base_oid="$(read_base_tip)" ||
    finish indeterminate 13 "cannot read the tip of ${base} from refs/heads/${base}"
valid_sha "$base_oid" ||
    finish indeterminate 13 "the tip of ${base} is not a commit SHA"

# compare_status FROM TO — GitHub's compare status of TO against FROM
# (`ahead` means TO descends from FROM).
compare_status() {
    run_gh api --method GET "repos/${repo}/compare/${1}...${2}" |
        jq -er '.status | select(type == "string")'
}

# ---- 2. the request: merge mode, guarded by the expected head ---------------
# gh api prints the error body on stdout and `gh: <message> (HTTP n)` on
# stderr, so both are kept for the classification below.
response_dir="$(mktemp -d -t update-branch-XXXXXX)"
trap 'rm -rf "$response_dir"' EXIT
put_rc=0
run_gh api --method PUT "repos/${repo}/pulls/${pr}/update-branch" \
    -f "expected_head_sha=${head}" \
    >"${response_dir}/out" 2>"${response_dir}/err" || put_rc=$?

if [ "$put_rc" -ne 0 ]; then
    response="$(cat "${response_dir}/out" "${response_dir}/err" | tr '\n' ' ')"
    lower="$(tr '[:upper:]' '[:lower:]' <<<"$response")"
    status_code="$(grep -Eo 'HTTP [0-9]{3}' <<<"$response" | head -n 1 | tr -dc '0-9')" || status_code=
    case "$lower" in
    *"expected head sha"* | *"expected_head_sha"*)
        finish stale-head 12 "GitHub refused the expected head ${head} — a newer push; re-run the gate: ${response}"
        ;;
    *"no new commits"*)
        printf 'update-branch: level: GitHub reports no new commits on %s\n' "$base" >&2
        printf '%s\n' "$head"
        exit 0
        ;;
    *conflict*)
        finish conflict 11 "the base does not merge cleanly — take the local-merge fallback: ${response}"
        ;;
    *"merge commit"*)
        # Checked before the generic rule match: a linear-history ruleset also
        # reports a rule violation, and its ban rejects a local merge too.
        finish refused 16 "a rule bans merge commits, so a local merge would be rejected too — stop and report, no fallback: ${response}"
        ;;
    *"rule violation"*)
        finish ruleset 10 "a repository rule rejects the merge — take the local-merge fallback: ${response}"
        ;;
    esac
    case "$status_code" in
    4??)
        finish refused 16 "GitHub refused update-branch (HTTP ${status_code}) for a reason that is not a known merge refusal — stop and report, no fallback: ${response}"
        ;;
    esac
    # A 5xx, a timeout or a transport error leaves the request's fate unknown.
    finish indeterminate 13 "update-branch request did not complete (exit ${put_rc}) — it may still be pending; do not request again: ${response}"
fi

# ---- 3. bounded wait for the head to move -----------------------------------
# An absolute deadline, not a sum of sleeps: the time a read takes counts, and
# each read is capped at what is left (at least 1s, so the first read runs
# even with --wait 0, and at most the usual 60s).
deadline=$(($(date +%s) + wait_sec))
new_head="$head"
while :; do
    budget=$((deadline - $(date +%s)))
    [ "$budget" -ge 1 ] || budget=1
    [ "$budget" -le 60 ] || budget=60
    if after="$(read_pr "$budget")" && new_head="$(field "$after" headRefOid)"; then
        after_base="$(field "$after" baseRefName)" ||
            finish indeterminate 13 "PR read carries no baseRefName"
        [ "$after_base" = "$base" ] ||
            finish retarget 14 "the PR base changed to ${after_base} while update-branch ran — base-retargeted applies"
        after_draft="$(jq -r '.isDraft | if type == "boolean" then tostring else error("no isDraft") end' <<<"$after")" ||
            finish indeterminate 13 "PR read carries no isDraft"
        [ "$after_draft" = true ] || [ "$maintainer_requested" = 1 ] || [ "$queue_head_upkeep" = 1 ] ||
            finish not-draft 15 "PR #${pr} was promoted while update-branch ran (head now ${new_head}) — report it; the merge may already have happened"
        [ "$new_head" = "$head" ] || break
    else
        new_head="$head"
    fi
    remaining=$((deadline - $(date +%s)))
    [ "$remaining" -gt 0 ] ||
        finish indeterminate 13 "the head was still ${head} after ${wait_sec}s — the request may still be pending; stop and report, do not request again"
    pause=$interval_sec
    [ "$pause" -le "$remaining" ] || pause=$remaining
    sleep "$pause"
done
valid_sha "$new_head" ||
    finish indeterminate 13 "the PR head ${new_head} is not a commit SHA"

# ---- 4. provenance: is the new head GitHub's catch-up? ----------------------
commit="$(run_gh api --method GET "repos/${repo}/commits/${new_head}")" ||
    finish indeterminate 13 "cannot read commit ${new_head} to establish its provenance"
parents="$(jq -r '[.parents[]?.sha] | if length == 2 then join(" ") else empty end' <<<"$commit")" ||
    finish indeterminate 13 "cannot read the parents of ${new_head}"
first_parent=${parents%% *}
second_parent=${parents#* }
[ -n "$parents" ] && [ "$first_parent" = "$head" ] && valid_sha "$second_parent" ||
    finish stale-head 12 "the head moved to ${new_head}, which is not a two-parent merge whose first parent is ${head} — not this catch-up; a newer push, re-run the gate"
if [ "$second_parent" != "$base_oid" ]; then
    # The base advanced while GitHub merged: the second parent must descend
    # from the tip read before the request and still be on the base branch.
    descent="$(compare_status "$base_oid" "$second_parent")" ||
        finish indeterminate 13 "cannot compare ${base_oid}...${second_parent} to place the merged base"
    [ "$descent" = ahead ] ||
        finish stale-head 12 "the head moved to ${new_head}, whose second parent ${second_parent} does not descend from the ${base} tip ${base_oid} — not this catch-up; a newer push, re-run the gate"
    tip_now="$(read_base_tip)" ||
        finish indeterminate 13 "cannot re-read the tip of ${base} to place the merged base"
    valid_sha "$tip_now" ||
        finish indeterminate 13 "the tip of ${base} is not a commit SHA"
    containment="$(compare_status "$second_parent" "$tip_now")" ||
        finish indeterminate 13 "cannot compare ${second_parent}...${tip_now} to place the merged base"
    case "$containment" in
    identical | ahead) ;;
    *) finish stale-head 12 "the head moved to ${new_head}, whose second parent ${second_parent} is not on ${base} — not this catch-up; a newer push, re-run the gate" ;;
    esac
fi
jq -e '
    .commit.committer.name == "GitHub"
    and .commit.committer.email == "noreply@github.com"
    and .commit.verification.verified == true
' <<<"$commit" >/dev/null ||
    finish stale-head 12 "the head moved to ${new_head} with the catch-up's parents, but GitHub did not make it (committer or signature) — treat it as a newer push and re-run the gate"

printf '%s\n' "$new_head"
