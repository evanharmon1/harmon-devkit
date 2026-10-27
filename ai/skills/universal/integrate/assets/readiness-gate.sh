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
# This helper never writes to GitHub. Use sibling promote.sh for recorded-run promotion.
#
# Usage:
#   readiness-gate.sh check --repo OWNER/REPO --pr N --head SHA
#       --record DIR --integration-cap N
#       [--integrator-result FILE] [--codex-recheck STATE_FILE] [--allow-edited-root ID]...
#   readiness-gate.sh promoted --repo OWNER/REPO --pr N --head SHA
#       --record DIR --integration-cap N
#       [--integrator-result FILE] [--codex-recheck STATE_FILE] [--allow-edited-root ID]...
#   readiness-gate.sh fingerprint --repo OWNER/REPO --pr N
#   readiness-gate.sh behind --repo OWNER/REPO --pr N
#
# `check` evaluates the gate for the adjudicated 40-hex head SHA and, on full
# pass only, prints `{"status":"pass",...,"fingerprint":...}` — where the
# fingerprint is double-read: computed over the exact content the conditions
# judged, then re-fetched fresh and required identical (`content-moved`
# otherwise), so a mid-gate edit fails before promotion notifies anyone.
# `promoted` is the same evaluation with the draft requirement inverted (its
# target must be non-draft — it judges an existing promotion): it answers
# "does this head independently pass everything else" for a PR somebody
# already promoted — §2's unexplained-promotion reconcile branch and §6's
# already-non-draft promoted run it instead of hand-rolling the evidence — and
# its pass never authorizes promotion. A passing `check` is promote.sh's
# precondition; promote.sh is the only promotion path.
# `fingerprint` recomputes the same five-surface content fingerprint with no
# gate attached — it is the post-promotion read the caller compares against
# `check`'s value.
#
# Exit codes:
#   0  pass — every condition held; fingerprint and cycle_evidence are on stdout
#   1  fail — a readiness condition is definitively not met
#   2  indeterminate — a fetch failed, data is malformed, GitHub has not
#      populated an answer yet, the arguments are unusable, or the checkout is
#      stale. Unknown never passes: 2 is "re-poll or reconcile", never
#      "promote".
#
# `check` emits one JSON line naming the decisive condition. This list is the
# contract a caller reads to know which conditions it must handle, so it is
# COMPLETE for `check` (review round 2, finding `review-r2-codex-verification-5`
# — it documented 27 of the emitted tokens, and the six it omitted were all
# pre-existing, `finder-not-clean` among them while its two sibling finder
# tokens were listed):
#   pr-not-open, pr-not-draft, head-mismatch, head-moved   (fail)
#   checks-failing                                         (fail)
#   changes-requested, merge-state-dirty                    (fail)
#   behind-base, base-retargeted                              (fail)
#   threads-unanswered, threads-new-follow-up,
#   threads-edited-since-reply                              (fail)
#   deferred-unsettled, closing-linkage-missing,
#   content-moved                                            (fail)
#   codex-not-clean, disposition-unsettled, codex-pr-not-open,
#   codex-quota-exhausted, finder-quota-exhausted             (fail)
#   finder-not-clean, finder-pr-not-open, finder-missing,
#   finder-capped,                                         (fail)
#   integrator-not-clean, unresolved-integrator-findings,   (fail)
#   evidence-marker-missing, remediation-capped,            (fail)
#   integration-filed-gating-finding                         (fail)
#   checks-indeterminate, checks-pending, checks-missing,
#   merge-state-unknown, fetch-failed,
#   malformed-data, codex-indeterminate, codex-cap-mismatch,
#   codex-stale, codex-transient-read, finder-transient-read,
#   finder-indeterminate, promotion-head-mismatch,
#   behind-base-unknown, asset-freshness-unknown,
#   codex-asset-freshness-unknown, finder-asset-freshness-unknown,
#   merge-state-stale,
#   integration-exit-indeterminate, integration-record-unbound,
#   checker-fast-path-unavailable, usage                     (indeterminate)
#
# A pass's cycle_evidence names the evidence kind (integrator-result or
# checker-state) and its file path. Checker-state evidence also reports the
# cycle ordinal; a cap-0 run requires an integrator result.
# checker-fast-path-unavailable requires dispatching an integrator and supplying
# --integrator-result; re-polling cannot replace missing integration evidence.
#
# `merge-state-behind` is RETIRED: the graph check (`behind-base`) runs first,
# so a genuinely behind head never reaches the cache branch, and a cache that
# still says BEHIND while the graph says 0 is lag — `merge-state-stale`,
# re-poll. Callers keyed to the old token should treat `behind-base` as its
# fail replacement and `merge-state-stale` as a retry.
#
# `promoted` emits the same set with one addition of its own — `pr-draft` (fail),
# for a PR that is no longer promoted — and without `pr-not-draft`. Both
# modes require behind_by == 0; the former audit-behind pass is retired.
#
# `codex-transient-read` exists because of harmon-devkit#508: the checker's
# exit 16 says an evidence READ failed, which is not evidence that the cycle
# is not clean. Reporting it as `codex-not-clean` sent the operator hunting a
# review problem that did not exist, and their only remedy was blind re-runs.
# `codex-quota-exhausted` is exit 15 (harmon-devkit#573): the reviewer
# answered that it will not review, which IS definitive — a blocker to report,
# not an unknown to re-poll. The reset time the reply may carry is context for
# the human, NOT an action: the head accepts no further reservation of either
# attempt, so waiting for the reset changes nothing. Recovery is a new commit
# or an operator removing the cycle state file; the route is carried in #1115.
#
# Required automation that reacts only to ready_for_review remains a caller
# prerequisite: promotion cannot wait for an automation it starts. Required
# status contexts, including ones that never registered, ARE checked against
# the union of ruleset and classic protection requirements on every evaluation.
# Definitive 404s (Branch not protected / Required status checks not enabled)
# mean no classic requirement; other classic read errors gate every reported check.
# Narrow only when every ruleset rule is required_status_checks or on the
# known-no-check list below.
# The remaining automation prerequisite is:
#   - required automation that reacts only to `pull_request.ready_for_review`
#     (a configuration blocker: promotion would notify humans before its
#     result exists);
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
# integrator — see ai/agents/integrator.md and result.integrator.schema.json).
# --record DIR is the dev-flow-v2 record directory render-dev-flow.mjs reads
# to project current deferred-finding settlement (readiness-input), also
# read-only — and the source of the active run's own identity: this script
# reads --record's run.json for run_id/initiated_by and binds the envelope
# to them (specs/dev-flow-v2.md:177-185), so evidence produced by a
# superseded or resumed run that happens to present the same head is refused
# rather than accepted on head equality alone.
#
# --codex-recheck STATE_FILE is the one place this script re-invokes a
# helper against live state: a cached codex_cycle can go stale between the
# dispatched integrator pass that produced --integrator-result and this gate
# running — a badged Codex finding posted as a top-level comment or review
# body in that window has no reply linkage and outranks a cached clean
# result on the same head (AGENTS.md's terminal-result contract), yet
# nothing about --integrator-result's own schema validity changes when that
# happens. Rather than re-deriving that classification here — the file's own
# stance a few paragraphs up ("classification belongs to the agent and the
# checker it runs") — a clean exit_code 0 is reconfirmed by re-invoking
# check-codex-cloud-review.sh's own `check` subcommand, read-only, against
# STATE_FILE: the same sibling asset and the same on-disk state the
# dispatched integrator agent itself drove (ai/agents/integrator.md §4),
# never a state file this script creates or owns. `check` takes only a
# transient advisory lock beside STATE_FILE (mkdir/rmdir, non-blocking) and,
# for a state file already carrying a persisted timeout_min — every state
# file a current integrator run produces — writes nothing else: it runs
# `check --read-only`, which records no marker and settles no charge, and the
# CI-settled charge is compared through `ci-split`, read-only too
# (harmon-devkit#1406, step 11 below); it is not
# exempt from the "gate writes nothing" claim above, only the one caller
# that legitimately re-runs another script's read path instead of reading a
# file directly. Without --integrator-result the same live check is the primary cycle
# evidence: no recording pass is required, and the final gate verdict names
# the checker state. A supplied result remains authoritative for its own
# validation obligations; the checker never masks an invalid result.

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  readiness-gate.sh check --repo OWNER/REPO --pr N --head SHA
      --record DIR --integration-cap N
      --remediation-cap N [--integration-exempt-cap N]
      [--integrator-result FILE] [--codex-recheck STATE_FILE] [--codex-repo-dir DIR]
      [--allow-edited-root ID]...
  readiness-gate.sh promoted --repo OWNER/REPO --pr N --head SHA
      --record DIR --integration-cap N
      --remediation-cap N [--integration-exempt-cap N]
      [--integrator-result FILE] [--codex-recheck STATE_FILE] [--codex-repo-dir DIR]
      [--allow-edited-root ID]...
  readiness-gate.sh fingerprint --repo OWNER/REPO --pr N
  readiness-gate.sh behind --repo OWNER/REPO --pr N

check evaluates every step-6 readiness condition for the adjudicated head;
promoted is the same evaluation with the draft requirement inverted (the PR
must be non-draft), for judging a PR somebody already promoted — its pass
never authorizes gh pr ready.
fingerprint recomputes the five-surface content fingerprint for the
post-promotion compare. --record DIR is the dev-flow-v2 record directory
(run.json plus adjudications/*.json) render-dev-flow.mjs projects deferred-
finding settlement from, and this script separately reads run.json's own
settlements[] from for the applied-disposition check below.
--record is always required. Supply --integrator-result FILE, --codex-recheck
STATE_FILE, or both. Without an integrator result, the checker must return
terminal-clean for this repo/PR/head and active run; its cycle spend is checked
against the resolved caps and the pass verdict names that state as evidence.
Checker-only is a clean-run fast path: no integrator pass or integration
adjudication, only Codex bodies or exact review triggers on top-level/review surfaces,
record policy.json resolving integration finders to codex-cloud alone, and
exactly one clean charged checker cycle, zero exempt cycles and no settlements,
and no inline review
comments. The state's finder must be null or match the trusted registry's
codex-cloud reserve profile field by field, including actor 199175422.
Cycle spend comes from charged_cycles + exempt_cycles; state without
these counters is refused. Carry retains the reviewed cycle's state.
Otherwise dispatch an
integrator and supply --integrator-result. The gate reads checks, thread
replies and deferred settlements live in either path. No recording-pass
envelope is fabricated. A cap-0 run still needs an
integrator result with null codex_cycle: checker evidence never waives a cycle.
--integrator-result FILE is the dispatched integrator agent's schema-valid
result.envelope (role integrator) for this exact head. When supplied, it is
always validated and bound to run.json's run_id/initiated_by, even alongside
checker evidence; invalid or non-clean results never fall back to the checker.
Its codex_cycle is null only for a resolved integration cap of 0.
--integration-cap N is required (harmon-devkit#685; made mandatory rather
than advisory in harmon-devkit#639 gauntlet challenge round 3): it enforces
that a cap of 0 pairs only with a null codex_cycle, that a positive cap
pairs only with a non-null one, and that codex_cycle.cycle never exceeds it
— the resolved value is the caller's (this script does not read
.devflow.toml), but the caller always has it, resolved early in its own
process, so there is no legitimate case for omitting it: a null codex_cycle
with the flag missing used to be silently trusted as proof the resolved cap
was 0, when it was really just the integrator's own unverified claim.
--remediation-cap N is required, for the same reason --integration-cap is
(harmon-devkit#685, challenge round 1): each integration -> implement ->
integration loop the record's own stage_transitions[] records is one
remediation round, and the count may not exceed the cap. Left optional, a
caller that simply omitted the flag would skip the policy check entirely and
an over-cap run would still promote — enforcement is not something a caller
opts into. The resolved value is the caller's (this script does not read
.devflow.toml), and the same resolution that yields --integration-cap yields
this one.
--codex-recheck STATE_FILE invokes check-codex-cloud-review.sh check against
live GitHub state. It is required for checker-only evidence and for a supplied
integrator result carrying a clean Codex cycle; a cached result alone cannot
prove the cycle is still clean. The checker owns accepted-verdict classification
and carry proof, while this gate checks identity, caps and the remaining
readiness conditions. A non-clean or head-mismatched state is indeterminate.
--codex-repo-dir DIR is the checkout the --codex-recheck re-check computes
patch identities in when the cycle state carries a verdict forward from an
earlier head (harmon-init#752). It defaults to the working directory. A
checkout that does not hold the PR's history cannot re-derive that proof, and
the re-check then reports indeterminate rather than accepting the record — so
this flag is how a gate run outside the PR's worktree stays able to confirm a
carried verdict instead of failing one.
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

# Every helper this script runs is now a VENDORED SKILL ASSET, so all of them
# resolve from this script's own physical directory (harmon-devkit#974). The
# record projector and the schema validator used to be resolved from the
# checkout's git toplevel, on the reasoning that they lived at a fixed
# repository-root `scripts/` path while this asset could be relocated by
# skills-sync. That reasoning is now exactly backwards: they travel with the
# skills, and a consumer that vendored them has no repository-root copy to
# find. `pwd -P` because the dogfood tree reaches this file through a symlink,
# and a logical path would resolve `../..` against the link instead of the
# real package.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
support_dir="$script_dir/../../dev-flow-support/assets"
render_dev_flow="$support_dir/render-dev-flow.sh"
[ -x "$render_dev_flow" ] ||
    die "$render_dev_flow is missing or not executable — the dev-flow-support package must be vendored alongside this skill"
validate_result_schemas="$support_dir/validate-result-schemas.mjs"
[ -f "$validate_result_schemas" ] ||
    die "$validate_result_schemas is missing — the dev-flow-support package must be vendored alongside this skill"

# check-codex-cloud-review.sh is THIS script's own sibling asset, resolved from
# the same $script_dir. Only checked for executability where --codex-recheck
# actually needs it, in recheck_codex_freshness below, since the flag is
# optional.
codex_checker="$script_dir/check-codex-cloud-review.sh"
# The current-head Codex actor is a fixed platform constant (AGENTS.md's
# current-head Codex cycle contract), not a per-repo or per-call setting —
# hardcoded here exactly as ai/agents/integrator.md hardcodes it at its own
# check-codex-cloud-review.sh call site.
codex_actor_id=199175422

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

# shellcheck source=asset-freshness.sh
. "$script_dir/asset-freshness.sh"

command_name="${1:-}"
[ -n "$command_name" ] || usage
shift

repo=
pr=
head=
record_dir=
integrator_result=
integration_cap=
integration_exempt_cap=
remediation_cap=
codex_recheck_state=
# harmon-init#752: the checkout the re-check re-derives a CARRIED verdict's
# patch identity in. It defaults to the working directory, which is the PR's
# own worktree in every real invocation; naming it explicitly is what lets a
# caller run this gate from anywhere else without the carried proof silently
# becoming unprovable.
codex_repo_dir=.
allowed_edited_roots='[]'

while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --pr | --head | --record | --integrator-result | --integration-cap | --integration-exempt-cap | --remediation-cap | --codex-recheck | --codex-repo-dir | --allow-edited-root)
        [ "$#" -ge 2 ] || usage
        case "$1" in
        --repo) repo=$2 ;;
        --pr) pr=$2 ;;
        --head) head=$2 ;;
        --record) record_dir=$2 ;;
        --integrator-result) integrator_result=$2 ;;
        --integration-cap) integration_cap=$2 ;;
        --integration-exempt-cap) integration_exempt_cap=$2 ;;
        --remediation-cap) remediation_cap=$2 ;;
        --codex-recheck) codex_recheck_state=$2 ;;
        --codex-repo-dir) codex_repo_dir=$2 ;;
        --allow-edited-root)
            grep -Eq '^[1-9][0-9]*$' <<<"$2" ||
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
    grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' <<<"$1"
}

valid_uint() {
    grep -Eq '^[1-9][0-9]*$' <<<"$1"
}

valid_uint_or_zero() {
    grep -Eq '^(0|[1-9][0-9]*)$' <<<"$1"
}

valid_sha() {
    grep -Eq '^[0-9a-fA-F]{40}$' <<<"$1"
}

[ -n "$repo" ] || usage
[ -n "$pr" ] || usage
valid_repo "$repo" || die "invalid repository: $repo"
valid_uint "$pr" || die "invalid PR number: $pr"
[ -z "$integration_cap" ] || valid_uint_or_zero "$integration_cap" ||
    die "--integration-cap must be a non-negative integer"
[ -z "$integration_exempt_cap" ] || valid_uint_or_zero "$integration_exempt_cap" ||
    die "--integration-exempt-cap must be a non-negative integer"
# Codex cloud cycle 4, P2 (confirmed): the PR-body validator rejecting an
# impossible pair does not protect readiness, which never compares these flags
# with the disclosure. The resolver produces only 0 or a ceiling equal to the
# charged cap, so anything else here would let cycles beyond the real cap be
# approved as exempt at the enforcement boundary itself.
[ -z "$integration_exempt_cap" ] || [ -z "$integration_cap" ] ||
    [ "$integration_exempt_cap" = "0" ] ||
    [ "$integration_exempt_cap" = "$integration_cap" ] ||
    die "--integration-exempt-cap ($integration_exempt_cap) must be 0 or equal to --integration-cap ($integration_cap); no resolved policy produces any other pair"
[ -z "$remediation_cap" ] || valid_uint_or_zero "$remediation_cap" ||
    die "--remediation-cap must be a non-negative integer"

# check gates promotion, so the PR must still be draft; promoted answers the
# reconcile question for a PR somebody already promoted, so it drops exactly
# that one requirement and nothing else.
require_draft=1
case "$command_name" in
check | promoted)
    [ "$command_name" = check ] || require_draft=0
    [ -n "$head" ] || usage
    valid_sha "$head" || die "--head must be a full 40-hex commit"
    [ -n "$record_dir" ] || usage
    [ -d "$record_dir" ] || die "--record $record_dir is not a directory"
    # A supplied result is always validated; checker evidence never masks a
    # missing or invalid explicitly supplied result.
    [ -n "$integrator_result" ] || [ -n "$codex_recheck_state" ] || usage
    if [ -n "$integrator_result" ]; then
        [ -f "$integrator_result" ] ||
            die "--integrator-result $integrator_result does not exist"
    fi
    # Required, not advisory (harmon-devkit#639 gauntlet challenge round 3):
    # a null codex_cycle with --integration-cap omitted used to be silently
    # trusted as "the resolved cap must have been 0", but that is the
    # integrator's unverified claim, not something this gate independently
    # confirmed — a missed flag or a wrong/dishonest claim would waive a
    # positive-cap Codex requirement with nothing catching it. The caller
    # (the /integrate skill) always resolves this value early in its own
    # process, so there is no legitimate case for omitting it here.
    [ -n "$integration_cap" ] || usage
    # Required for the same reason (harmon-devkit#685, challenge round 1):
    # an optional policy check is one a caller can skip by omission, and a
    # skipped remediation check promotes an over-cap run.
    [ -n "$remediation_cap" ] || usage
    ;;
fingerprint | behind) ;;
*) usage ;;
esac

emit() {
    jq -cn \
        --arg status "$1" \
        --arg condition "$2" \
        --arg detail "$3" \
        --arg head "${head:-}" \
        --slurpfile checks_sf <(printf '%s' "${checks_summary:-null}") \
        '{status:$status,condition:$condition,detail:$detail,head:$head,
          reportable_checks:{failing:($checks_sf[0].optional_failing // [] | .[0:20]),
                             total:($checks_sf[0].optional_failing // [] | length)}}'
}

fail_condition() {
    emit fail "$1" "$2"
    exit 1
}

indeterminate() {
    emit indeterminate "$1" "$2"
    exit 2
}

normalize_body_field() {
    jq -c '
      if has("body") then
        .body |= (if . == null then "" else . end)
      else
        error("body is missing")
      end
      | if (.body | type) == "string" then
          .
        else
          error("body is neither a string nor null")
        end'
}

# A closing keyword is only a claim until GitHub resolves it to an issue
# linkage. Normalize every claimed target to owner/repo#number and compare it
# with the structured closingIssuesReferences from the SAME `gh pr view`
# response. GitHub treats repository names case-insensitively; issue numbers
# are numeric. A body with no claim produces an empty set and passes.
closing_target_kinds='{}'
assert_closing_linkage() {
    local acl_payload="$1" acl_phase="$2"
    local acl_sets acl_missing_count acl_missing acl_repo
    local acl_ref acl_target acl_number acl_kind acl_issue acl_pr_targets
    acl_sets="$(jq -cr --arg repo "$repo" '
      if (.closingIssuesReferences | type) != "array" then
        error("closingIssuesReferences is not an array")
      else
        ([.body
          | scan("(?:^|[^A-Za-z0-9_-])(?:close(?:s|d)?|fix(?:es|ed)?|resolve(?:s|d)?)[[:blank:]]*:?[[:blank:]]*(https://github\\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/issues/[0-9]+|[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+|#[0-9]+)"; "i")
          | .[0]
          | ascii_downcase
          | if startswith("#") then
              ($repo | ascii_downcase) + "#" + (ltrimstr("#") | tonumber | tostring)
            elif startswith("https://github.com/") then
              capture("^https://github\\.com/(?<target>[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)/issues/(?<number>[0-9]+)$")
              | .target + "#" + (.number | tonumber | tostring)
            else
              capture("^(?<target>[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#(?<number>[0-9]+)$")
              | .target + "#" + (.number | tonumber | tostring)
            end]
         | unique) as $claimed
        | ([.closingIssuesReferences[]
            | if ((.number | type) == "number"
                  and (.repository.name | type) == "string"
                  and (.repository.owner.login | type) == "string") then
                ((.repository.owner.login + "/" + .repository.name + "#"
                  + (.number | tostring)) | ascii_downcase)
              else
                error("malformed closingIssuesReferences entry")
              end]
           | unique) as $linked
        | {claimed:$claimed, missing:($claimed - $linked)}
      end' <<<"$acl_payload" 2>/dev/null)" ||
        indeterminate malformed-data "closing-linkage payload is malformed ($acl_phase)"

    acl_repo="$(jq -nr --arg repo "$repo" '$repo | ascii_downcase')"
    acl_pr_targets='[]'
    while IFS= read -r acl_ref; do
        acl_target="${acl_ref%#*}"
        [ "$acl_target" = "$acl_repo" ] || continue
        acl_number="${acl_ref##*#}"
        acl_kind="$(jq -r --arg ref "$acl_ref" '.[$ref] // ""' <<<"$closing_target_kinds")"
        if [ -z "$acl_kind" ]; then
            acl_issue="$(run_gh api repos/"$acl_target"/issues/"$acl_number")" ||
                indeterminate fetch-failed "cannot resolve claimed closing target $acl_ref"
            acl_kind="$(jq -r '
              if type != "object" then
                error("claimed target is not an object")
              elif has("pull_request") and (.pull_request | type) != "object" then
                "malformed-pull-request"
              elif has("pull_request") then
                "pull-request"
              else
                "issue"
              end' <<<"$acl_issue" 2>/dev/null)" ||
                indeterminate fetch-failed "cannot resolve claimed closing target $acl_ref"
            [ "$acl_kind" != malformed-pull-request ] ||
                indeterminate malformed-data "claimed closing target $acl_ref carries a malformed pull_request field"
            closing_target_kinds="$(jq -c --arg ref "$acl_ref" --arg kind "$acl_kind" \
                '. + {($ref):$kind}' <<<"$closing_target_kinds")"
        fi
        if [ "$acl_kind" = pull-request ]; then
            acl_pr_targets="$(jq -c --arg ref "$acl_ref" '. + [$ref]' <<<"$acl_pr_targets")"
        fi
    done < <(jq -r '.missing[]' <<<"$acl_sets")
    acl_sets="$(jq -c --argjson prs "$acl_pr_targets" '.missing -= $prs' <<<"$acl_sets")"

    acl_missing_count="$(jq -r '.missing | length' <<<"$acl_sets")"
    [ "$acl_missing_count" -eq 0 ] || {
        acl_missing="$(jq -r '.missing | join(", ")' <<<"$acl_sets")"
        fail_condition closing-linkage-missing "the PR body claims closing linkage that GitHub has not resolved ($acl_phase): $acl_missing"
    }
}

# Review round 2, finding `review-r2-codex-verification-4` (confirmed P2,
# disposition RESTRUCTURE TO INVARIANT): the Codex cycle and the per-finder
# cycles were TWO PARALLEL `case` STATEMENTS over one enum, and nothing forced
# them to agree. Review round 1 fixed both of its taxonomy defects on the
# codex arm alone — `-4` added the exit-14 terminal, `-2` renamed the
# codex-prefixed token on a per-finder condition — so the sibling still
# reported a schema-valid exit 14 as an unrecognized value, under a
# codex-prefixed condition, and prescribed a re-poll of a PR GitHub had
# already answered was closed.
#
# Both schema fields carry the same contract by construction: the
# `finder_cycles[].exit_code` description reads "Same contract as
# codex_cycle.exit_code above". So the mapping is ONE function keyed by
# surface, and the suite asserts its ARM SET against the schema exit-code
# enum on both surfaces — round 2 made this one function and still left exit 2
# in the catch-all, which is the round-3 finding `-4`, so "one place to add a
# code" is only true if something checks that every code was added. Exit 0 stays at each call site because it is the one code whose
# meaning is surface-specific: the Codex cycle re-checks its cached clean
# result, a finder cycle is simply terminal-clean.
exit_condition() {
    ec_surface=$1
    ec_exit=$2
    ec_subject=$3
    case "$ec_surface" in
    codex)
        ec_prefix=codex
        # Recovery for an exhausted Codex head is carried in #1115; a finder
        # has no equivalent reservation state to clear, so that sentence is
        # this surface only rather than a claim made on every finder.
        ec_quota_tail=" this head accepts no further reservation, so recovery is a new commit or an operator clearing the checker state (route carried in #1115)"
        ;;
    finder)
        ec_prefix=finder
        ec_quota_tail=""
        ;;
    *)
        indeterminate usage "exit_condition was called with an unknown surface: $ec_surface"
        ;;
    esac
    case "$ec_exit" in
    10 | 11 | 12 | 13)
        fail_condition "${ec_prefix}-not-clean" "$ec_subject exited $ec_exit, not terminal-clean"
        ;;
    14)
        # 14 is documented at every other layer — the checker header, both
        # schemas, the validator, `ai/agents/integrator.md` and AGENTS.md. It
        # is terminal for the whole stage rather than for one surface: GitHub
        # answered that the PR is merged or closed, so there is nothing left
        # to gate, whichever reader saw it first.
        fail_condition "${ec_prefix}-pr-not-open" "$ec_subject exited 14: the PR is no longer open, which ends the whole integration stage — stop rather than re-dispatching"
        ;;
    15)
        # harmon-devkit#573: the reviewer answered that it will not review
        # this head. Definitive, so a fail rather than an indeterminate — but
        # its own condition, because the remedy is to report the blocker and
        # wait for the quota, never to re-trigger or re-dispatch.
        fail_condition "${ec_prefix}-quota-exhausted" "$ec_subject exited 15: the reviewer reported its code-review usage limit is exhausted — report the blocker with the reset time;${ec_quota_tail:- do not re-trigger}"
        ;;
    16)
        # harmon-devkit#508: an evidence READ failed. This must never render
        # as `*-not-clean` — that was the original defect, where one flaky
        # GitHub read turned an already-adjudicated-clean cycle into a hard
        # gate failure with no remedy but blind re-runs. It is unknown, with
        # the reason named, and the caller repeats the READ.
        indeterminate "${ec_prefix}-transient-read" "$ec_subject exited 16: an evidence read failed transiently, which is not evidence the cycle is not clean — repeat the read (a fresh integrator pass) rather than treating the reviewer as absent"
        ;;
    19)
        indeterminate "${ec_prefix}-asset-freshness-unknown" "$ec_subject exited 19: its result came from a stale asset checkout and cannot establish anything about the PR — update this checkout to the PR base or newer (fetch and fast-forward), then rerun the pass"
        ;;
    2)
        # Review round 3, finding `review-r3-codex-verification-4` (confirmed
        # P3): 2 was the LAST documented code still falling to the catch-all,
        # so the gate told the operator that the one value every other layer
        # defines — the checker header, both schema enums, AGENTS.md — "is not
        # a recognized terminal or pending value". The outcome was already
        # right; the sentence was not, and a sentence is what the operator
        # acts on. Exit 2 is the checker saying its evidence does not add up,
        # which is unknown with the reason named, so the remedy is a fresh
        # pass rather than a promotion or a hard fail.
        indeterminate "${ec_prefix}-indeterminate" "$ec_subject exited 2: the checker could not determine a verdict from the evidence it read — dispatch a fresh pass rather than treating this as clean or as a review failure"
        ;;
    *)
        # Reached only by a value OUTSIDE the schema exit-code enum, which is
        # a defect in whatever produced the envelope. Every documented code has
        # its own arm above, and the suite asserts that against the enum in
        # `ai/schemas/result.integrator.schema.json` on BOTH surfaces, so a
        # code cannot be added to the schema and quietly left here. Three
        # consecutive review rounds each closed one member of this enum by
        # hand (`review-r1-codex-verification-4`, `-r2-...-4`, `-r3-...-4`);
        # the assertion is what ends that.
        indeterminate "${ec_prefix}-indeterminate" "$ec_subject exit_code $ec_exit is not a recognized terminal or pending value"
        ;;
    esac
}

# Establish how far the head is behind its base FROM THE COMMIT GRAPH, setting
# $behind_base_ref and $behind_by. `mergeStateStatus` is a lazily recomputed
# cache: on ponderousdev/omator#758 (2026-09-06 17:40Z) it read CLEAN/MERGEABLE
# for a head SIXTEEN commits behind main, minutes after two sibling PRs merged.
# The gate passed, the PR was reported ready, and the maintainer found "Update
# branch" instead of a merge button — and his click moved the head, invalidating
# the terminal Codex result the gate had just relied on.
#
# The base ref comes from the PR payload passed in, never from a local remote:
# it must follow a retarget, and a fork's `origin/main` is not this PR's base.
# A failed or malformed read is INDETERMINATE, never a pass — "I could not
# establish this" must not read as "this is fine".
#
# Sets globals rather than echoing, and must NOT be called through `$(...)`:
# `indeterminate` exits, and inside a command substitution that would end only
# the subshell and let the gate carry on with an unset behind_by.
behind_base_ref=
behind_by=
behind_base_oid=
# The remedy every behind-base message names (harmon-devkit#1360): the
# server-side catch-up is the default, the local merge only its fallback.
behind_remedy="catch up with update-branch.sh (GitHub update-branch in merge mode, guarded by the expected head) by default; fall back to a local merge under the full round gate only on a conflict or a ruleset refusal (SKILL.md, 'Base reconciliation')"
establish_behind() {
    establish_scalars="$1"
    establish_phase="$2"
    behind_base_ref="$(jq -er '.baseRefName | select(type == "string")' <<<"$establish_scalars")" ||
        indeterminate malformed-data "PR payload carries no base branch name (${establish_phase})"
    # Encode the ref before it becomes a URL path segment. Branch names may
    # contain `#`, `?` or a literal `%`, any of which silently truncate or
    # reinterpret the endpoint — `release#1` would query `repos/.../compare/release`
    # and answer about the wrong thing. `/` is restored afterwards because it
    # is a legitimate, unambiguous separator inside a ref and GitHub expects it
    # literally. Comparing against a base OID instead would answer a different
    # question: how far behind a SNAPSHOT of the base, not its current tip.
    # Done entirely in jq: the "loudly unbounded" path runs on a curated PATH
    # that has no `sed`, and reaching for one made the gate exit 127 there.
    establish_encoded="$(jq -rn --arg s "$behind_base_ref" '$s | @uri | gsub("%2F"; "/")')"
    establish_compare="$(run_gh api "repos/${repo}/compare/${establish_encoded}...${head}")" ||
        indeterminate behind-base-unknown "cannot compare ${behind_base_ref}...${head} to establish how far behind the head is (${establish_phase})"
    behind_by="$(jq -er '.behind_by | select(type == "number")' <<<"$establish_compare")" ||
        indeterminate behind-base-unknown "compare payload carries no numeric behind_by (${establish_phase})"
    # The tip the count is ABOUT. Comparing base names across the identity read
    # cannot see the base branch itself advancing — the name is unchanged and
    # the stale `behind_by 0` reads as level.
    behind_base_oid="$(jq -er '.base_commit.sha | select(type == "string")' <<<"$establish_compare")" ||
        indeterminate behind-base-unknown "compare payload carries no base commit sha (${establish_phase})"
}

run_gh() {
    if [ -n "$timeout_bin" ]; then
        "$timeout_bin" -k 1 60 gh "$@"
    else
        gh "$@"
    fi
}

asset_freshness_check() {
    if check_vendored_asset_freshness "$pr" "$repo" "$script_dir" "$timeout_bin"; then
        return 0
    fi
    indeterminate asset-freshness-unknown "$asset_freshness_detail"
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
        fp_pr="$(normalize_body_field <<<"$fp_pr")" ||
            indeterminate malformed-data "PR object carries an invalid body"
    fi
    fp_reviews="$(run_gh api --paginate --slurp repos/"$repo"/pulls/"$pr"/reviews)" ||
        indeterminate fetch-failed "cannot fetch PR reviews"
    fp_top="$(run_gh api --paginate --slurp repos/"$repo"/issues/"$pr"/comments)" ||
        indeterminate fetch-failed "cannot fetch top-level PR comments"
    if [ -z "$fp_inline" ]; then
        fp_inline="$(run_gh api --paginate --slurp repos/"$repo"/pulls/"$pr"/comments)" ||
            indeterminate fetch-failed "cannot fetch inline review comments"
    fi
    if [ -z "$fp_threads" ]; then
        fetch_review_threads
    fi
}

fetch_review_threads() {
    local owner="${repo%/*}" name="${repo#*/}"
    fp_threads="$(run_gh api graphql --paginate --slurp \
        -F owner="$owner" -F name="$name" -F pr="$pr" -f query='
      query($owner:String!,$name:String!,$pr:Int!,$endCursor:String){
        repository(owner:$owner,name:$name){ pullRequest(number:$pr){
          reviewThreads(first:100,after:$endCursor){
            pageInfo{hasNextPage endCursor} nodes{id isResolved comments(first:1){nodes{databaseId}}}}}}}')" ||
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

# Checks live GitHub state, read-only: primary evidence on the checker-only
# path, or freshness confirmation for a supplied codex_cycle.exit_code 0.
# Supplied non-clean and null cycles retain their own handling below.
recheck_codex_freshness() {
    local recheck_state_input="${checker_state_snapshot:-$codex_recheck_state}"
    [ -n "$codex_recheck_state" ] ||
        indeterminate codex-stale "no --codex-recheck was given to confirm current-head Codex evidence against live GitHub state"
    [ -x "$codex_checker" ] ||
        die "$codex_checker is missing or not executable — cannot honor --codex-recheck"
    [ -f "$recheck_state_input" ] ||
        indeterminate codex-stale "--codex-recheck $codex_recheck_state does not exist — cannot confirm live Codex evidence"
    state_repo="$(jq -r '.repo // empty' "$recheck_state_input" 2>/dev/null)"
    state_pr="$(jq -r '.pr // empty' "$recheck_state_input" 2>/dev/null)"
    state_head="$(jq -r '.head // empty' "$recheck_state_input" 2>/dev/null)"
    # harmon-init#752: a cycle can attest a LATER head than its own, so the
    # state's head legitimately differs from the gated one — but only when the
    # state itself says so. The claim is the state's, never the caller's, and
    # the checker re-derives the identity behind it on the very next line.
    state_attests="$(jq -r '.carry.attests_head // empty' "$recheck_state_input" 2>/dev/null)"
    [ "$state_repo" = "$repo" ] && [ "$state_pr" = "$pr" ] &&
        { [ "$state_head" = "$head" ] || [ "$state_attests" = "$head" ]; } ||
        indeterminate codex-stale "--codex-recheck $codex_recheck_state belongs to ${state_repo:-?}#${state_pr:-?}@${state_head:-?}${state_attests:+ (attesting $state_attests)}, not the gated $repo#$pr@$head"
    codex_recheck_exit=0
    # Review round 5, P1 (confirmed): this recheck is the gate's own use of the
    # checker, and it was the one call site still not naming the run. A later
    # run can replace the shared same-head state, so without the run id this
    # call would happily validate a foreign run's cycle. `active_run_id` is
    # read from --record's run.json well before this runs.
    codex_recheck_output="$("$codex_checker" check --state "$recheck_state_input" --actor-id "$codex_actor_id" --run-id "$active_run_id" --repo-dir "$codex_repo_dir" --read-only 2>&1)" ||
        codex_recheck_exit=$?
    # harmon-devkit#508: exit 16 means the checker could not READ the evidence,
    # not that the cached clean result went stale. This is the exact shape the
    # issue observed — a gate re-checking a long-settled clean cycle, one
    # GitHub read hiccuping — so retry the READ once here rather than making
    # the operator re-run the whole gate blindly. Only the read is repeated:
    # nothing about the reviewer cycle is re-triggered, and a second failure
    # is reported as indeterminate WITH THE REASON rather than as staleness,
    # so a caller can tell "GitHub would not answer" from "the clean result no
    # longer holds".
    if [ "$codex_recheck_exit" -eq 16 ]; then
        # Review round 1, finding `review-r1-codex-verification-3` (P2): the
        # retry used to re-invoke immediately, and the checker has no retry of
        # its own, so both reads landed within microseconds of each other. A
        # transient GitHub failure has not cleared in that window, which made
        # the retry nearly free and nearly useless. This repo already settled
        # the shape in `lane-watch.sh` (bounded backoff, merged as 3760968);
        # one short bounded sleep is the same idea at the smallest scale the
        # single retry allows. `CODEX_RECHECK_RETRY_DELAY` exists so the test
        # suite can drive the path without paying the wall-clock cost.
        sleep "${CODEX_RECHECK_RETRY_DELAY:-2}"
        codex_recheck_exit=0
        # Scoped exactly as the first read is: during the retry delay another
        # run can replace the shared same-head state, and an unscoped retry
        # would accept that foreign run's cycle and settlements instead of
        # refusing the ownership mismatch.
        codex_recheck_output="$("$codex_checker" check --state "$recheck_state_input" --actor-id "$codex_actor_id" --run-id "$active_run_id" --repo-dir "$codex_repo_dir" --read-only 2>&1)" ||
            codex_recheck_exit=$?
        [ "$codex_recheck_exit" -ne 16 ] ||
            indeterminate codex-transient-read "live Codex check could not read its evidence twice (check-codex-cloud-review.sh exited 16 on both the read and its one retry) — GitHub would not answer; repeat the read rather than treating unknown evidence as stale: $codex_recheck_output"
    fi
    # Codex cloud-review cycle 3 on PR harmon-devkit#1125, finding 4067133481
    # (confirmed P2): 16 got its own handling above and 15 did not, so a live
    # recheck that came back quota-exhausted fell into the generic stale arm —
    # which prescribes dispatching a fresh integrator pass. That is the one
    # remedy exit 15 rules out: the finder has answered that it will not
    # review this head, and re-dispatching spends budget re-asking a question
    # already answered. The CACHED path has said so since harmon-devkit#573
    # (`codex_exit`s own 15 arm, via `exit_condition`); this path had the same
    # obligation and not the same code, which is the two-parallel-sites shape
    # this branch has been bitten by four times.
    #
    # `fail_condition`, not `indeterminate`: a usage limit is definitive, and
    # the remedy is to report the blocker, never to re-poll. Same wording and
    # same recovery route as the cached arm.
    if [ "$codex_recheck_exit" -eq 15 ]; then
        fail_condition codex-quota-exhausted "live Codex check came back quota-exhausted (check-codex-cloud-review.sh exited 15): the reviewer reported its code-review usage limit is exhausted — report the blocker with the reset time; this head accepts no further reservation, so recovery is a new commit or an operator clearing the checker state (route carried in #1115): $codex_recheck_output"
    fi
    if [ "$codex_recheck_exit" -eq 10 ]; then
        fail_condition codex-not-clean "live Codex check reports findings — adjudicate them before gating (check-codex-cloud-review.sh exited 10): $codex_recheck_output"
    fi
    [ "$codex_recheck_exit" -eq 0 ] ||
        indeterminate codex-stale "live Codex check does not confirm terminal-clean evidence (check-codex-cloud-review.sh exited $codex_recheck_exit) — resolve the checker-reported condition before gating: $codex_recheck_output"
}

# Fingerprinting only recomputes PR-content identity; it carries no verdict.
# A stale checkout must not invalidate a post-promotion content comparison.
if [ "$command_name" != fingerprint ]; then
    asset_freshness_check
fi

# `behind` is the read-only preflight the reserved-cycle rule needs. Before
# dispatching the last permitted review cycle an integrator must know whether
# the head is behind — and telling it to work that out itself would mean
# re-deriving ref encoding and fail-closed handling outside the one place they
# are tested, which is exactly the hand-rolling this skill forbids everywhere
# else. Same code path as the gate, same exit vocabulary: 0 level, 1 behind,
# 2 could not establish. It writes nothing and judges nothing else.
if [ "$command_name" = behind ]; then
    behind_scalars="$(run_gh pr view "$pr" --repo "$repo" --json headRefOid,baseRefName)" ||
        indeterminate fetch-failed "cannot fetch the PR state"
    head="$(jq -er '.headRefOid | select(type == "string")' <<<"$behind_scalars")" ||
        indeterminate malformed-data "PR payload carries no head commit"
    establish_behind "$behind_scalars" "preflight"
    # Same binding the gate does: a push or retarget during the comparison
    # would otherwise let this report `level` for a head that no longer
    # exists, and the caller spends its reserved cycle on the wrong one.
    behind_after="$(run_gh pr view "$pr" --repo "$repo" --json headRefOid,baseRefName,baseRefOid)" ||
        indeterminate fetch-failed "cannot confirm PR identity after the comparison"
    jq -e --arg h "$head" --arg b "$behind_base_ref" --arg o "$behind_base_oid" \
        '.headRefOid == $h and .baseRefName == $b and .baseRefOid == $o' <<<"$behind_after" >/dev/null ||
        indeterminate behind-base-unknown "the PR head, base branch or base tip moved while comparing — re-run the preflight"
    if [ "$behind_by" -eq 0 ]; then
        jq -cn --arg base "$behind_base_ref" --arg head "$head" \
            '{status:"level",behind_by:0,base:$base,head:$head}'
        exit 0
    fi
    emit fail behind-base "the head is ${behind_by} commit(s) behind ${behind_base_ref} — ${behind_remedy}, before spending the reserved cycle"
    exit 1
fi

if [ "$command_name" = fingerprint ]; then
    fetch_fingerprint_surfaces
    compute_fingerprint
    jq -cn --arg fingerprint "$fingerprint" \
        '{status:"fingerprint",fingerprint:$fingerprint}'
    exit 0
fi

# ------------------------------ check / promoted ------------------------------

# 1. PR scalars. `gh pr view` is a single-object read (pagination does not
# apply); the list surfaces below all go through --paginate --slurp.
scalars="$(run_gh pr view "$pr" --repo "$repo" \
    --json state,isDraft,headRefOid,reviewDecision,mergeStateStatus,headRefName,baseRefName,body,closingIssuesReferences)" ||
    indeterminate fetch-failed "cannot fetch the PR state"
scalars="$(normalize_body_field <<<"$scalars")" ||
    indeterminate malformed-data "PR payload carries an invalid body"

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
    fail_condition pr-not-open "PR state is $pr_state — only an open PR can be gated or re-checked"

if [ "$require_draft" = 1 ]; then
    jq -e '.isDraft == true' <<<"$scalars" >/dev/null ||
        fail_condition pr-not-draft "PR is not a draft — promotion is idempotently complete or someone else promoted; run promoted, do not re-promote"
else
    # Promoted judges an existing promotion, so its target must actually be
    # promoted: a PR converted back to draft since the caller observed it
    # has no standing handoff to accept.
    jq -e '.isDraft == false' <<<"$scalars" >/dev/null ||
        fail_condition pr-draft "the PR is a draft — there is no standing promotion to re-check; check is the gate for promoting one"
fi

live_head="$(jq -er '.headRefOid | select(type == "string")' <<<"$scalars")" ||
    indeterminate malformed-data "PR payload carries no head commit"
[ "$live_head" = "$head" ] ||
    fail_condition head-mismatch "PR head is $live_head, not the adjudicated $head — re-adjudicate against the new head"

# 2. The PR object (REST) — the fingerprint's first surface, and a second
# head-moved check independent of the scalar fetch above.
fp_pr="$(run_gh api repos/"$repo"/pulls/"$pr")" ||
    indeterminate fetch-failed "cannot fetch the PR object"
fp_pr="$(normalize_body_field <<<"$fp_pr")" ||
    indeterminate malformed-data "PR object carries an invalid body"
rest_head="$(jq -er '.head.sha | select(type == "string")' <<<"$fp_pr")" ||
    indeterminate malformed-data "PR object carries no head commit"
[ "$rest_head" = "$head" ] ||
    fail_condition head-moved "PR head changed while the gate was reading it"
scalar_body="$(jq -r '.body' <<<"$scalars")" ||
    indeterminate malformed-data "PR payload carries no body"
rest_body="$(jq -r '.body' <<<"$fp_pr")" ||
    indeterminate malformed-data "PR object carries no body"
[ "$scalar_body" = "$rest_body" ] ||
    fail_condition content-moved "PR body changed between the linkage and fingerprint reads — re-adjudicate against the current body"
assert_closing_linkage "$scalars" "initial snapshot"

# 3. Checks, page-safe from the commit itself: check runs plus legacy commit
# statuses are what the PR's checks tab aggregates. `gh pr view`'s
# statusCheckRollup caps at one page, so it cannot be the evidence here. The
# A permission denial here is indeterminate, even if the Actions-only settle
# fallback succeeded: workflow runs cannot prove external checks or statuses.
# The evaluation is a function because it runs twice: here, and again immediately
# before the verdict — the fetches between the two take real time, a rerun or
# late-triggered workflow can turn the commit red inside that window, and
# checks are deliberately not part of the content fingerprint, so nothing
# after promotion would catch it either.
#
# Required contexts come from the effective branch rules, including inherited
# rulesets. Missing or pending required checks are indeterminate. Other checks
# are reported, never used to turn a handoff red. Without an explicit
# required context, or when classic protection cannot be read, every reported
# check gates. Narrow only when every ruleset rule is a status-check rule or
# is known to add no check requirement. Check-bearing and unknown types broaden.
known_no_check_rules='["deletion","non_fast_forward","creation","update",
    "required_linear_history","required_signatures","pull_request",
    "commit_message_pattern","commit_author_email_pattern",
    "committer_email_pattern","branch_name_pattern","tag_name_pattern"]'
checks_summary='{"optional_failing":[]}'
evaluate_checks() {
    local rules_pages required_checks explicit_required_rule classic_checks classic_payload
    local encoded_rule_base rules_known
    encoded_rule_base="$(jq -rn --arg s "$(jq -r '.baseRefName' <<<"$scalars")" '$s | @uri')"
    rules_pages="$(run_gh api --paginate --slurp "repos/$repo/rules/branches/$encoded_rule_base")" ||
        indeterminate checks-indeterminate "cannot read effective required status checks for the PR base"
    required_checks="$(jq -ce '
      [ .[] | if type == "array" then .[] else error("rules page is not an array") end
        | select(.type == "required_status_checks")
        | .parameters.required_status_checks
        | if type == "array" then .[] else error("missing required_status_checks") end
        | if (.context | type == "string" and length > 0) and
             (.integration_id == null or (.integration_id | type == "number" and floor == .))
          then {context, app:(.integration_id // null)} else error("invalid required context") end
      ] | unique' <<<"$rules_pages" 2>/dev/null)" ||
        indeterminate checks-indeterminate "effective required status checks are malformed"
    rules_known="$(jq -r --argjson no_checks "$known_no_check_rules" '
      all(.[][]; .type == "required_status_checks" or
        (.type as $type | any($no_checks[]; . == $type)))' <<<"$rules_pages")"
    # Rulesets and classic protection can coexist. An unreadable classic
    # policy (including an ambiguous 404) cannot prove a check optional.
    classic_checks=null
    if classic_payload="$(run_gh api "repos/$repo/branches/$encoded_rule_base/protection/required_status_checks" 2>&1)"; then
        classic_checks="$(jq -ce '
          if (.contexts | type) != "array" or ((.checks // []) | type) != "array"
          then error("invalid classic contexts") else
            [(.checks // [])[] | {context, app:(.app_id // null)}] as $checks |
            ($checks + [.contexts[] | . as $context |
              select(any($checks[]; .context == $context) | not) | {context:.,app:null}]) |
            if all(.[]; (.context | type == "string" and length > 0) and
                (.app == null or (.app | type == "number" and floor == .)))
            then unique else error("invalid classic context") end
          end' <<<"$classic_payload" 2>/dev/null)" || classic_checks=null
    else
        # gh prints the JSON error body before its diagnostic, possibly with
        # no intervening newline. Only these exact 404 diagnostics prove none.
        case "$classic_payload" in
        *"gh: Branch not protected (HTTP 404)" | *"gh: Required status checks not enabled (HTTP 404)")
            classic_checks='[]'
            ;;
        esac
        printf '%s\n' "$classic_payload" >&2
    fi
    required_checks="$(jq -cn \
        --slurpfile rules <(printf '%s' "$required_checks") \
        --slurpfile classic <(printf '%s' "$classic_checks") \
        '$rules[0] + ($classic[0] // []) | unique')"
    explicit_required_rule=false
    if [ "$classic_checks" != null ] && [ "$required_checks" != '[]' ] && [ "$rules_known" = true ]; then
        explicit_required_rule=true
    fi
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
        --argjson explicit_required_rule "$explicit_required_rule" \
        --slurpfile required_sf <(printf '%s' "$required_checks") \
        --slurpfile runs_sf <(printf '%s' "$check_runs") \
        --slurpfile statuses_sf <(printf '%s' "$statuses") '
          $required_sf[0] as $required |
          def run_state:
            if .status != "completed" then "pending"
            elif (.conclusion == "success" or .conclusion == "neutral"
                  or .conclusion == "skipped") then "ok"
            else "failing" end;
          def status_state:
            if .state == "success" then "ok"
            elif .state == "pending" then "pending"
            else "failing" end;
          (($runs_sf[0] | map({name:(.name // "unnamed check"),
                              app:(.app.id // null), state:run_state})) +
          ($statuses_sf[0] | map({name:(.context // "unnamed status"),
                                  app:null, state:status_state}))) as $all |
          def matches($req): .name == $req.context and
            ($req.app == null or $req.app == -1 or .app == $req.app);
          # Index by context so large histories do not multiply every rule
          # by every check. Preserve independent workflow/app identities.
          ($all | group_by(.name) | map({key:.[0].name,value:.}) | from_entries) as $by_name |
          ($required | group_by(.context) | map({key:.[0].context,value:.}) | from_entries) as $required_by_name |
          ([$required[] | . as $req |
            [($by_name[$req.context] // [])[] | select(matches($req))] as $found |
            if ($found | length) == 0 then {name:$req.context,state:"missing"}
            else $found[] end] + (if $explicit_required_rule then [] else $all end)) as $gating |
          {total:($all | length),
           failing:[$gating[] | select(.state == "failing") | .name] | unique,
           pending:[$gating[] | select(.state == "pending") | .name] | unique,
           missing:[$gating[] | select(.state == "missing") | .name] | unique,
           optional_failing:[$all[] | select($explicit_required_rule and .state == "failing") |
              . as $row | select(any(($required_by_name[$row.name] // [])[]; . as $req | $row | matches($req)) | not) | .name] | unique}
        ')" || indeterminate malformed-data "check states could not be classified"
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
        indeterminate checks-pending "required checks not yet concluded: $pending_checks"
    missing_checks="$(jq -r '.missing | .[0:20] | join(", ")' <<<"$checks_summary")"
    [ -z "$missing_checks" ] ||
        indeterminate checks-missing "required checks have no result on this head: $missing_checks"
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
# The TRUTH check runs FIRST, so a head that is genuinely behind always reports
# `behind-base` and follows one recipe. `merge-state-behind` stays after it as
# the cache backstop; reaching it now means the cache says BEHIND while the
# graph says 0, which is cache lag in the other direction.
# Both draft promotion and a live promoted re-check require a level head.
establish_behind "$scalars" "before evaluating"
[ "$behind_by" -eq 0 ] ||
    fail_condition behind-base "the head is ${behind_by} commit(s) behind ${behind_base_ref} — ${behind_remedy}; then CI, and carry or one fresh current-head cycle"

merge_state="$(jq -r '.mergeStateStatus // ""' <<<"$scalars")"
case "$merge_state" in
DIRTY) fail_condition merge-state-dirty "merge conflicts with the base branch" ;;
BEHIND)
    # The graph reported 0 just above, so a cache still reading BEHIND is lag,
    # not work: failing it would send the caller to merge a base it is level
    # with, which creates no commit and reproduces the blocker forever.
    [ "$behind_by" -ne 0 ] ||
        indeterminate merge-state-stale "mergeStateStatus still reads BEHIND while the commit graph reports 0 behind ${behind_base_ref:-the base} — the cache is lagging; re-poll briefly"
    ;;
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

# 7. Every thread needs an agent reply, then resolution or the agent speaking
# last (SKILL.md §2). Guard the identity lookup as carefully
# as the fetch: if `gh api user` fails while the comments endpoint works,
# every comment classifies as reviewer activity — loud, but wrong.
me="$(run_gh api user | jq -er '.login | select(type == "string" and . != "")')" ||
    indeterminate fetch-failed "identity lookup failed — thread answers are unknown, NOT answered"
fp_inline="$(run_gh api --paginate --slurp repos/"$repo"/pulls/"$pr"/comments)" ||
    indeterminate fetch-failed "inline-comment fetch failed — threads are unknown, NOT answered"
# harmon-devkit#675: a reply of "Fixed in <sha>" sometimes reads to the
# connector as an instruction, so it runs a fix task of its own and posts a
# report on what IT did — observed on harmon-devkit#665 thread 3886138416,
# where the follow-up at 09:25:52Z said "### Summary … Committed the change on
# `codex/name-review-trigger-broker` … A pull request could not be created".
# That is the bot describing work already on the head, not a reviewer
# follow-up, and treating it as one blocked the gate until a human replied a
# second time to a machine.
#
# In an unresolved thread, an unbadged self-report from the pinned actor is
# INFORMATIONAL and does not raise `threads-new-follow-up`. Two deliberate limits:
#
#   - it is scoped to the FOLLOW-UP computation only. A thread with no reply
#     from you at all is still `unanswered`, and an edit after your reply is
#     still `edited-since-reply`, whoever wrote either — this narrows exactly
#     the one state the issue reported and nothing else.
#   - a BADGED follow-up still blocks, unconditionally. The test for a badge
#     is the same whole-body `p<digit>` scan the checker uses, and it is
#     content-negative: a real finding restated in a self-report-shaped body
#     is still a finding.
#
# An unrecognised self-report shape keeps today's behaviour (it blocks), which
# is a false block rather than a false pass.
fetch_review_threads
thread_resolution="$(jq -ce '
  if type != "array" or length == 0 then error("missing thread pages") else . end |
  [ .[] | .data.repository.pullRequest.reviewThreads |
    if (.nodes | type) != "array" then error("missing reviewThreads nodes") else .nodes[] end |
    if (.id | type) != "string" or (.isResolved | type) != "boolean" or
       (.comments.nodes | type) != "array" or (.comments.nodes | length) != 1 or
       (.comments.nodes[0].databaseId | type) != "number"
    then error("thread has no resolution/root identity")
    else {root:.comments.nodes[0].databaseId, resolved:.isResolved} end
  ] | if (group_by(.root) | any(.[]; length != 1)) then error("duplicate thread root") else . end
' <<<"$fp_threads" 2>/dev/null)" ||
    indeterminate malformed-data "review threads have no reliable resolution/root mapping"
threads_needing_attention="$(jq -c --arg me "$me" \
    --slurpfile resolution_sf <(printf '%s' "$thread_resolution") \
    --argjson bot "$codex_actor_id" 'add // []
    | def is_bot_self_report:
        ((.user.id? == $bot) and
         (((.body // "") | ascii_downcase | test("\\bp[0-9]+\\b")) | not) and
         # Mirrors the checker predicate `is_self_report`, kept deliberately
         # identical. Challenge round 2, finding
         # `challenge-r2-codex-adversarial-1`: the round-1 version asked only
         # whether a self-work marker appeared ANYWHERE, so a body could
         # describe its own work in one line and raise a concern in the
         # next and still pass as informational. The invariant is that the
         # body states NOTHING BUT work the bot itself did, so every non-blank line
         # must be a heading, a bold-only label, or a list item — a
         # free-standing prose paragraph is what a concern looks like.
         # Any non-match still raises `threads-new-follow-up`.
         (((.body // "") | ascii_downcase | split("\n") |
            map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) |
            any(.[]; test("^#{1,6}[[:space:]]*summary[[:space:]]*$")))) and
         (((.body // "") | ascii_downcase |
            (test("committed .*on `[^`]+` as `[0-9a-f]{7,40}`") or
             test("a pull request could not be created") or
             test("reviewed commit `[0-9a-f]{7,40}` and found no additional")))) and
         # Challenge round 3, finding `challenge-r3-codex-adversarial-6`
         # (confirmed P2): this predicate is documented as kept identical to
         # the checker`s `is_self_report`, and it was not — it skipped the
         # About-block removal and rejected Codex`s own whole-line
         # `**Reviewed commit:**` metadata, so the two disagreed on real
         # bodies. Same About-block anchor and same permitted line shapes as
         # the checker now.
         (((.body // "") | ascii_downcase |
            gsub("<details[^<]*<summary>[^<]*about codex[^<]*</summary>.*?</details>"; ""; "im") |
            split("\n") |
            map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) |
            map(select(. != "")) |
            all(.[];
              test("^#{1,6}[[:space:]]") or
              test("^\\*\\*[^*]+\\*\\*[[:space:][:punct:]]*$") or
              test("^[*+-][[:space:]]") or
              test("^[0-9]+\\.[[:space:]]") or
              test("^\\*\\*reviewed commit:\\*\\*[[:space:]]*`[0-9a-f]{7,40}`[[:space:]]*$")))) and
         (((.body // "") | ascii_downcase |
            test("useful\\? react with")) | not));
      group_by(.in_reply_to_id // .id)
    | map( . as $t
      | ([$t[] | select(.user.login == $me and .in_reply_to_id != null)
               | .created_at] | max) as $mine
      | ([$t[] | select(.user.login != $me
                        and (is_bot_self_report | not)
                        and ($mine == null or .created_at >= $mine))
               | .created_at] | max) as $new
      | ([$t[] | select(.user.login != $me and $mine != null
                        and .updated_at >= $mine and .created_at < $mine)
               | .updated_at] | max) as $edit
      | ($t[0].in_reply_to_id // $t[0].id) as $root
      | ([$resolution_sf[0][] | select(.root == $root)]) as $resolution
      | { root: $root, path: $t[0].path,
          state: (if   ($resolution | length) != 1 then "unknown-resolution"
                  elif $mine == null then "unanswered"
                  elif $resolution[0].resolved then null
                  elif $new  != null then "new-follow-up"
                  elif $edit != null then "edited-since-reply"
                  else null end),
          at: ($new // $edit) })
    | map(select(.state != null))' <<<"$fp_inline")" ||
    indeterminate malformed-data "inline comments could not be classified"

missing_inline_roots="$(jq -nr \
    --slurpfile resolution <(printf '%s' "$thread_resolution") \
    --slurpfile inline <(printf '%s' "$fp_inline") '
      ($inline[0] | add // [] | map(.in_reply_to_id // .id)) as $roots |
      [$resolution[0][] | .root
       | select(. as $root | $roots | index($root) | not)] | join(", ")')" ||
    indeterminate malformed-data "cannot correlate REST comments with GraphQL threads"
[ -z "$missing_inline_roots" ] ||
    fail_condition threads-unanswered "review threads have no agent reply in the inline surface — roots: $missing_inline_roots"
[ "$(jq '[.[] | select(.state == "unknown-resolution")] | length' <<<"$threads_needing_attention")" -eq 0 ] ||
    indeterminate malformed-data "an inline root has no GraphQL review-thread mapping"
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

# 8. Capture remaining fingerprint surfaces; retain exactly the thread state
# evaluated above. compute_fingerprint still hashes only {id,r} per thread.
fetch_fingerprint_surfaces

# 9. The current-head Codex cloud-review cycle — from a schema-valid
# integrator result or, on the clean-run fast path, live checker state.
# Evaluated AFTER the fingerprint surfaces are captured, deliberately: activity the agent's own
# fresh evidence collection already classified sits inside the baseline
# fingerprint, and activity landing after that pass sits outside it, where
# the post-promotion compare flags it. Classification belongs to the agent
# and the checker it runs — never re-derived here, only validated and read.
#
# Bind the evidence to the active run before trusting it (specs/dev-flow-
# v2.md:177-185's run-identity invariant): a superseded or resumed run can
# present the SAME head as the active one, so a bare envelope_head == $head
# compare below is not enough to prove --integrator-result belongs to this
# run rather than an earlier one that happened to reach the same commit.
# run.json's own run_id/initiated_by are the active run's identity; passing
# them lets the validator's own receipt check reject a mismatched .run.
run_json="${record_dir}/run.json"
[ -f "$run_json" ] ||
    indeterminate malformed-data "no run.json in --record $record_dir to bind the active run identity"
active_run_id="$(jq -er '.run_id | select(type == "string")' "$run_json" 2>/dev/null)" ||
    indeterminate malformed-data "run.json carries no run_id"
active_initiated_by="$(jq -er '.initiated_by | select(type == "string")' "$run_json" 2>/dev/null)" ||
    indeterminate malformed-data "run.json carries no initiated_by"
# The resolved policy is the coverage obligation, never the set of finders
# the integrator happened to run. Legacy ids default to gating; explicit
# gates=false or budget=0 opts a finder out. A cap-0 stage never opens.
required_finders="$(jq -ce --argjson cap "$integration_cap" '
  .stages.integration as $stage |
  if ($stage.finders | type) != "array" or
     any($stage.finders[]; type != "string") or
     (($stage.finder // []) | type) != "array"
  then error("invalid integration finder policy") else
    [$stage.finders[] | . as $id |
      [($stage.finder // [])[] | select(.id == $id)] as $entries |
      if ($entries | length) > 1 then error("duplicate resolved finder") else
        ($entries[0] // {}) as $entry |
        select($cap > 0 and $entry.gates != false and $entry.budget != 0) |
        {id:$id, budget:($entry.budget // $cap), explicit_budget:($entry.budget != null), carry:($entry.carry // "identity")} |
        if (.budget | type == "number" and . > 0 and floor == .)
        then . else error("invalid finder limits") end
      end] | unique_by(.id)
  end' "$record_dir/policy.json" 2>/dev/null)" || {
    if [ -z "$integrator_result" ]; then
        indeterminate checker-fast-path-unavailable "cannot determine required finders from the resolved policy — dispatch an integrator"
    fi
    indeterminate finder-indeterminate "cannot determine required finders from the resolved policy"
}
# Only validated same-run receipts can prove prior spend. Only a non-Codex
# finder with an explicit spent budget becomes optional on later heads.
# Codex's current-head contract never drops out through spend; findings owe the
# ordinary settlement checks. Advisory cycles belong in the dispatch report,
# outside finder_cycles, whose schema intentionally aggregates gating verdicts.
prior_finder_spend="$(
    for prior_pass in "$record_dir"/passes/*.json; do
        [ -f "$prior_pass" ] || continue
        jq -e --arg head "$head" '.role == "integrator" and .head != $head' \
            "$prior_pass" >/dev/null 2>&1 || continue
        node "$validate_result_schemas" envelope "$prior_pass" \
            --run-id "$active_run_id" --initiated-by "$active_initiated_by" >/dev/null 2>&1 || continue
        jq -c --arg head "$head" '
          select(.role == "integrator" and .head != $head) |
          [(.payload.finder_cycles // [])[],
           (.payload.codex_cycle | select(. != null) | . + {finder:"codex-cloud"})] | .[]
        ' "$prior_pass"
    done | jq -sc '.'
)" || indeterminate finder-indeterminate "cannot read prior finder spend"
required_finders="$(jq -c --argjson prior "$prior_finder_spend" '
  map(. as $limits | select(.id == "codex-cloud" or (.explicit_budget | not) or
    (any($prior[]; .finder == $limits.id and .cycle >= $limits.budget) | not)))
' <<<"$required_finders")" || indeterminate finder-indeterminate "cannot apply prior finder budgets"
codex_required="$(jq 'any(.[]; .id == "codex-cloud")' <<<"$required_finders")"
if [ -z "$integrator_result" ]; then
    jq -e '.stage_transitions[-1].stage == "integration" and
      ([.finder_selection[]? | select(.stage == "integration")] | length == 0)' \
        "$run_json" >/dev/null 2>&1 ||
        indeterminate checker-fast-path-unavailable "the active stage is not integration or the run selected integration finders; dispatch an integrator and supply --integrator-result"
    # The clean-run fast path has no integration work to adjudicate and
    # exactly one configured finder. Anything else needs an integrator.
    for checker_pass in "$record_dir"/passes/*.json; do
        [ -f "$checker_pass" ] || continue
        checker_role="$(jq -er '.role' "$checker_pass")" ||
            indeterminate malformed-data "cannot read recorded pass $checker_pass"
        [ "$checker_role" != integrator ] ||
            indeterminate checker-fast-path-unavailable "the record holds an integrator pass; dispatch an integrator and supply --integrator-result"
    done
    for checker_adj in "$record_dir"/adjudications/*.json; do
        [ -f "$checker_adj" ] || continue
        checker_stage="$(jq -er '.stage' "$checker_adj")" ||
            indeterminate malformed-data "cannot read adjudication $checker_adj"
        [ "$checker_stage" != integration ] ||
            indeterminate checker-fast-path-unavailable "the record holds an integration adjudication; dispatch an integrator and supply --integrator-result"
    done
    [ "$integration_cap" -gt 0 ] ||
        indeterminate codex-cap-mismatch "checker-only evidence cannot waive a cap-0 cycle; supply an integrator result"
    jq -e 'map(.id) == ["codex-cloud"]' \
        <<<"$required_finders" >/dev/null 2>&1 ||
        indeterminate checker-fast-path-unavailable "resolved integration finders are not proven to be codex-cloud alone; dispatch an integrator and supply --integrator-result"
    # Closed allowlist: do not parse finding prose or exempt the caller.
    # Empty review bodies carry no prose; every top-level comment counts.
    non_codex_findings="$(jq -cn --argjson top "$fp_top" --argjson reviews "$fp_reviews" \
        --argjson bot "$codex_actor_id" '
      [((($top | add // [])[]),
        (($reviews | add // [])[] | select((.body // "") != ""))) |
        select(.user.id != $bot) |
        select(((.body // "") | gsub("^\\s+|\\s+$"; "")) != "@codex review")]
    ')" || indeterminate malformed-data "PR comment and review bodies could not be classified"
    [ "$(jq 'length' <<<"$non_codex_findings")" -eq 0 ] ||
        indeterminate checker-fast-path-unavailable "the PR carries bodies outside Codex comments and exact review triggers; dispatch an integrator and supply --integrator-result"
    [ "$(jq 'add // [] | length' <<<"$fp_inline")" -eq 0 ] ||
        indeterminate checker-fast-path-unavailable "the PR carries inline review comments; dispatch an integrator and supply --integrator-result"

fi
if [ -n "$integrator_result" ]; then
    # The run's known finding universe, so the validator's
    # checkAppliedDispositionsKnownFindingIds actually runs here
    # (harmon-devkit#685: "nested integrator passes' applied_dispositions ids are
    # validated against the run's known finding universe"). That check is gated
    # on --known-ids, and this gate — the production caller — was not passing it,
    # so a clean integrator pass could claim dispositions for findings that never
    # existed and still authorize promotion; only impossible integration ids were
    # caught, by the flagless half of the check. Challenge round 2, confirmed.
    #
    # The universe is every finding the record's own PASSES produced — the ids
    # raised under `passes/`, and nothing else. An adjudication is a judgement
    # ABOUT a finding, never evidence that one was produced: integrate cycle 2 on
    # PR #800 showed that harvesting adjudication ids too lets a fabricated
    # same-run adjudication whitelist an arbitrary id, since
    # `render-dev-flow readiness-input` explicitly continues past an adjudication
    # row with no pass behind it. Narrowing to passes removes that class rather
    # than patching it — every legitimately adjudicated finding was raised by a
    # pass, so a complete record already contains it, and a record missing that
    # pass is incomplete in a way the gate should fail closed on. An id in
    # neither the passes nor the gated payload's own findings[] (which the
    # validator checks separately) names nothing the record can account for.
    #
    # `--record` is the dev-flow-v2 record directory the review stage retains
    # and this stage consumes, so both subdirectories are its documented
    # contents, not an assumption about the caller.
    # A plain glob and jq, never find/xargs: this script must keep running on
    # the minimal toolset its own no-GNU-timeout path already restricts PATH to,
    # and jq is the only thing here that is not a shell builtin.
    # mktemp, never a $$-derived name: on a shared host $TMPDIR is world-writable
    # and a PID-derived path is predictable, so `>` would follow a symlink an
    # attacker planted there and truncate whatever the invoking user can write.
    # Challenge round 3 (P2), confirmed.
    known_ids_file="$(mktemp "${TMPDIR:-/tmp}/readiness-gate-known-ids.XXXXXX")" ||
        indeterminate malformed-data "could not create a temporary file for the run's known finding ids"
    # `|| :` so the trap's own last command always succeeds: this script's
    # verdict IS its exit code, and a cleanup that fails — `rm` missing from a
    # restricted PATH, a read-only TMPDIR — must never be what the caller reads
    # instead of fail/indeterminate/pass.
    trap 'rm -f "$known_ids_file" 2>/dev/null || :' EXIT
    {
        for known_ids_doc in "$record_dir"/passes/*.json; do
            [ -f "$known_ids_doc" ] || continue
            # SEMANTICALLY validate each pass before trusting its ids, rather
            # than approximating validity with a status/role filter of our own.
            # `status: "completed"` does not establish it — a structurally valid
            # pass whose `counts` disagree with its findings is rejected by
            # validate-result-schemas.mjs while render-dev-flow's readiness-input,
            # which is only structural, lets it through (integrate cycle 3 on
            # PR #800). Running the real validator is both stricter and less code:
            # it subsumes the blocked-role rule this filter used to hand-roll,
            # including the distinction that a blocked confidence-role pass
            # carries no findings while a blocked integrator legitimately does.
            node "$validate_result_schemas" envelope "$known_ids_doc" \
                --run-id "$active_run_id" --initiated-by "$active_initiated_by" \
                >/dev/null 2>&1 || continue
            jq -r '.payload.findings[]?.id // empty' "$known_ids_doc" 2>/dev/null || true
        done
    } | jq -Rn '[inputs | select(. != "")] | unique' >"$known_ids_file" 2>/dev/null || true
    # An unreadable or absent record leaves an EMPTY universe rather than no
    # check: an empty FILE would make the validator's own --known-ids parse fail
    # (a usage error), where an empty ARRAY is the honest "this run has produced
    # no findings the record can account for" — and still enforcing.
    [ -s "$known_ids_file" ] || printf '[]\n' >"$known_ids_file"
    node "$validate_result_schemas" envelope "$integrator_result" \
        --run-id "$active_run_id" --initiated-by "$active_initiated_by" \
        --known-ids "$known_ids_file" >/dev/null 2>&1 ||
        indeterminate codex-indeterminate "--integrator-result $integrator_result is not a schema-valid result.envelope for the active run ($active_run_id/$active_initiated_by), or names an applied disposition outside the run's known finding universe"

fi

# A promoted catch-up may keep its terminal run only with a checker-proven
# identical-change carry from the recorded promotion. All other head drift
# remains a mismatch; the live checker proof is required below as well.
record_promotion_head="$(jq -r '.promotion.head // ""' "$run_json" 2>/dev/null)" ||
    indeterminate malformed-data "run.json's promotion could not be read"
promotion_carried=0
if [ -n "$record_promotion_head" ] && [ "$record_promotion_head" != "$head" ]; then
    promotion_receipt=null
    if [ -n "$integrator_result" ]; then
        promotion_receipt="$(jq -c '{head,cycle:.payload.codex_cycle}' "$integrator_result")"
    fi
    # Identity is transitive through the reviewed head, not a hop counter:
    # check proves current == reviewed; the immutable promoted receipt proves
    # promoted == reviewed when promotion itself used an earlier carry.
    if [ "$command_name" = promoted ] && [ -n "$codex_recheck_state" ] &&
        jq -e --arg promoted "$record_promotion_head" --arg head "$head" \
            --argjson receipt "$promotion_receipt" '
          .carry.attests_head == $head and
          (.head == $promoted or
           ($receipt.head == $promoted and
            $receipt.cycle.carried.attests_head == $promoted and
            $receipt.cycle.carried.origin_head == .head and
            $receipt.cycle.carried.change_id == .carry.change_id))
        ' "$codex_recheck_state" >/dev/null 2>&1; then
        recheck_codex_freshness
        promotion_carried=1
    else
        indeterminate promotion-head-mismatch "run.json records promotion.head $record_promotion_head, not the gated $head — a checker-proven carry from the promoted head is required"
    fi
fi
if [ -n "$integrator_result" ]; then
    integrator_role="$(jq -er '.role | select(type == "string")' \
        "$integrator_result" 2>/dev/null)" ||
        indeterminate malformed-data "integrator result carries no role"
    [ "$integrator_role" = integrator ] ||
        indeterminate codex-indeterminate "--integrator-result names role $integrator_role, not integrator"
    envelope_head="$(jq -er '.head | select(type == "string")' \
        "$integrator_result" 2>/dev/null)" ||
        indeterminate malformed-data "integrator result carries no head"
    { [ "$envelope_head" = "$head" ] ||
        { [ "$promotion_carried" -eq 1 ] && [ "$envelope_head" = "$record_promotion_head" ]; }; } ||
        indeterminate codex-indeterminate "integrator result is for head $envelope_head, not the gated $head — dispatch a fresh pass against this head"
    codex_cycle="$(jq -c '.payload.codex_cycle' "$integrator_result" 2>/dev/null)" ||
        indeterminate malformed-data "integrator result payload is unreadable"
    if [ "$promotion_carried" -eq 1 ] && [ "$envelope_head" != "$head" ] && [ "$codex_cycle" != null ]; then
        # The promoted record is immutable. Project only its Codex receipt to
        # the carried head in memory; bind the original envelope to the record
        # below, and independently re-check all live readiness conditions.
        codex_cycle="$(jq -c --arg head "$head" \
            --slurpfile state "$codex_recheck_state" '
          .head=$head | .carried=($state[0].carry + {origin_head:$state[0].head})
        ' <<<"$codex_cycle")" || indeterminate codex-carried-unproven "cannot project the promoted carry"
    fi
else
    # No synthetic integrator envelope: the checker owns verdict collection,
    # and its state owns cycle spend. Live checks, threads and settlements are
    # evaluated by this gate in both paths.
    [ -f "$script_dir/trusted-registry.sh" ] ||
        indeterminate checker-fast-path-unavailable "trusted-registry.sh is missing; cannot confirm the checker finder profile"
    # shellcheck source=trusted-registry.sh
    . "$script_dir/trusted-registry.sh"
    checker_profile_dir="$(mktemp -d "${TMPDIR:-/tmp}/readiness-gate-profile.XXXXXX")" ||
        indeterminate checker-fast-path-unavailable "cannot create a temporary directory for checker evidence"
    trap 'rm -rf "$checker_profile_dir" 2>/dev/null || :' EXIT
    checker_state_snapshot="$checker_profile_dir/state.json"
    cp "$codex_recheck_state" "$checker_state_snapshot" ||
        indeterminate codex-stale "cannot snapshot --codex-recheck for live evidence"
    jq -e '.phase == "attached" or .phase == "terminal"' "$checker_state_snapshot" >/dev/null 2>&1 ||
        indeterminate checker-fast-path-unavailable "checker evidence is not attached or terminal"
    # Both the checker and cycle construction use this private snapshot;
    # a concurrent reservation cannot replace the state between those reads.
    recheck_codex_freshness
    resolve_trusted_registry "$repo" "$pr" "$checker_profile_dir/registry.json" ||
        indeterminate checker-fast-path-unavailable "cannot resolve the trusted registry for checker evidence"
    resolve_finder_profile "$checker_profile_dir/registry.json" codex-cloud \
        "$checker_profile_dir/profile.json" ||
        indeterminate checker-fast-path-unavailable "cannot resolve the trusted Codex finder profile"
    # Fixed legacy defaults of check-codex-cloud-review.sh, not caller state.
    cat >"$checker_profile_dir/legacy.json" <<'LEGACY'
{"slug":"codex-cloud","actor_id":"199175422","actor_login":"chatgpt-codex-connector[bot]","trigger_mechanism":"review-comment","trigger_body":"@codex review","reviewer_login":null,"surfaces":["reaction","comment","review","inline"],"head_binding":"reviewed-commit-line","verdict_mode":"clean-sentence","clean_verdict":"codex review: didn't find any major issues.","actionable_pattern":null,"severity_marker":"\\bp[0-9]+\\b","metadata_line":"^\\*\\*reviewed commit:\\*\\*[[:space:]]*`[0-9a-f]{7,40}`[[:space:]]*$","about_summary":"about codex","heading":"^#{1,6}[^a-z0-9]*codex review$","carrier_sentence":"here are some automated review suggestions for this pull request.","success_reaction":"+1","pending_reaction":"eyes"}
LEGACY
    jq -e --slurpfile trusted "$checker_profile_dir/profile.json" \
        --slurpfile legacy "$checker_profile_dir/legacy.json" '
          ($trusted[0] | {
            slug:.slug, actor_id:(.trusted_actor_id | tostring), actor_login:.trusted_actor_login,
            trigger_mechanism:.collection.trigger.mechanism, trigger_body:.collection.trigger.body,
            reviewer_login:.collection.trigger.reviewer_login,
            surfaces:.collection.terminal_signals.surfaces,
            head_binding:.collection.terminal_signals.head_binding,
            verdict_mode:.collection.terminal_signals.verdict_mode,
            clean_verdict:.collection.terminal_signals.clean_verdict,
            actionable_pattern:.collection.terminal_signals.actionable_pattern,
            severity_marker:.collection.terminal_signals.severity_marker,
            metadata_line:.collection.terminal_signals.metadata_line,
            about_summary:.collection.terminal_signals.about_summary,
            heading:.collection.terminal_signals.heading,
            carrier_sentence:.collection.terminal_signals.carrier_sentence,
            success_reaction:.collection.terminal_signals.success_reaction,
            pending_reaction:.collection.terminal_signals.pending_reaction
          }) as $expected |
          $expected.actor_id == "199175422" and
          $expected.actor_login == "chatgpt-codex-connector[bot]" and
          ($expected.surfaces | index("comment") != null) and
          ($expected.surfaces | index("review") != null) and
          (if .finder == null then $expected == $legacy[0] else .finder == $expected end)
          ' "$checker_state_snapshot" >/dev/null 2>&1 ||
        indeterminate checker-fast-path-unavailable "checker finder profile differs from the trusted Codex reserve profile; dispatch an integrator and supply --integrator-result"
    codex_cycle="$(jq -ce --arg head "$head" '
      def uint: type == "number" and . >= 0 and . == floor;
      select(has("charged_cycles") and has("exempt_cycles"))
      | select((.charged_cycles | uint) and (.exempt_cycles | uint))
      | select((.charged_cycles + .exempt_cycles) > 0)
      | . as $state
      | {head:$head, cycle:(.charged_cycles + .exempt_cycles), exit_code:0,
         charged:.charged_cycles, exempt:.exempt_cycles}
        + (if $state.carry != null then
             {carried:($state.carry + {origin_head:$state.head})} else {} end)
      ' "$checker_state_snapshot" 2>/dev/null)" ||
        indeterminate malformed-data "checker state carries invalid cycle counters"
    jq -e '.charged_cycles == 1 and .exempt_cycles == 0 and (.settled // []) == []' \
        "$checker_state_snapshot" >/dev/null 2>&1 ||
        indeterminate checker-fast-path-unavailable "checker evidence is not exactly one clean charged cycle with zero exempt cycles and no settlements; dispatch an integrator and supply --integrator-result"
fi
cycle_state_file="${checker_state_snapshot:-$codex_recheck_state}"
if [ "$codex_cycle" != null ]; then
    cycle_head="$(jq -er '.head | select(type == "string")' \
        <<<"$codex_cycle" 2>/dev/null)" ||
        indeterminate malformed-data "codex_cycle carries no head"
    [ "$cycle_head" = "$head" ] ||
        indeterminate codex-indeterminate "codex_cycle head $cycle_head disagrees with the gated $head"
    # harmon-devkit#685's "accepted-cycle reviewed commit" invariant
    # (codex_cycle.accepted.reviewed_commit must equal this same head) is
    # already enforced one step earlier, unconditionally, by
    # validate-result-schemas.mjs's own envelope receipt validation above —
    # it rejects any envelope whose accepted.reviewed_commit disagrees with
    # the envelope's own head, and envelope_head is already checked against
    # $head. A second check here would be unreachable dead code: nothing
    # gets this far without both already having been proven equal.
    codex_exit="$(jq -er '.exit_code | select(type == "number")' \
        <<<"$codex_cycle" 2>/dev/null)" ||
        indeterminate malformed-data "codex_cycle carries no exit_code"
    if [ -n "$integration_cap" ]; then
        cycle_accounting="$(node "$support_dir/lib/cap-authorizations.mjs" \
            --run "$run_json" --run-id "$active_run_id" --cap "$integration_cap" --cycle "$codex_cycle")" ||
            indeterminate malformed-data "integration cycle accounting or authorization record is unreadable"
        [ "$(jq -r '.admitted' <<<"$cycle_accounting")" = true ] ||
            indeterminate codex-cap-mismatch "codex_cycle exceeds --integration-cap $integration_cap without a contiguous authorization"
        cycle_number="$(jq -er '.cycle | select(type == "number")' \
            <<<"$codex_cycle" 2>/dev/null)" ||
            indeterminate malformed-data "codex_cycle carries no cycle number"
        [ "$integration_cap" -gt 0 ] ||
            indeterminate codex-cap-mismatch "codex_cycle is non-null but --integration-cap is 0 (harmon-devkit#685: a cap-0 pass must report a null codex_cycle)"
        # harmon-init#1326: `cycle` is the stage's TOTAL cycle ordinal, and
        # once base-merge-only cycles are exempt from the integration cap that
        # total may legitimately exceed it. A producer that classifies its
        # cycles says so by reporting `charged` (and `exempt`), and then the
        # two ceilings are checked independently — charged against
        # --integration-cap, exempt against --integration-exempt-cap.
        #
        # A producer that reports no `charged` is one that does not classify,
        # so every cycle it ran was charged: the original single-counter rule
        # is exactly right for it and still applies unchanged. That is what
        # keeps this backward compatible with a pass driven by an older skill,
        # rather than silently granting it an exemption it never computed.
        # Review round 4, P2 (recurring): the two counters are one statement,
        # and the repo's schema validator is a subset that has no
        # `dependentRequired`, so the pair cannot be expressed there. Enforce
        # it here instead, where it is checkable and where the consequence
        # lives: `exempt` without `charged` would otherwise fall through to
        # the legacy single-counter branch and be silently ignored, which is
        # the direction that hides spend.
        cycle_exempt_probe="$(jq -er '.exempt | select(type == "number")' \
            <<<"$codex_cycle" 2>/dev/null)" || cycle_exempt_probe=
        cycle_charged="$(jq -er '.charged | select(type == "number")' \
            <<<"$codex_cycle" 2>/dev/null)" || cycle_charged=
        [ -n "$cycle_charged" ] || [ -z "$cycle_exempt_probe" ] ||
            indeterminate malformed-data "codex_cycle reports exempt but no charged count"
        if [ -n "$cycle_charged" ]; then
            cycle_exempt="$(jq -er '.exempt | select(type == "number")' \
                <<<"$codex_cycle" 2>/dev/null)" ||
                indeterminate malformed-data "codex_cycle reports charged but no exempt count"
            [ "$((cycle_charged + cycle_exempt))" -eq "$cycle_number" ] ||
                indeterminate malformed-data "codex_cycle.charged $cycle_charged + .exempt $cycle_exempt does not equal .cycle $cycle_number"
            # An unbounded exemption is a budget hole: without a declared
            # ceiling there is nothing to check an exempt count against, so a
            # pass claiming exempt cycles under a caller that never declared
            # one is refused rather than trusted.
            [ -n "$integration_exempt_cap" ] || [ "$cycle_exempt" -eq 0 ] ||
                indeterminate codex-cap-mismatch "codex_cycle reports $cycle_exempt exempt cycle(s) but no --integration-exempt-cap was declared"
            [ -z "$integration_exempt_cap" ] ||
                [ "$cycle_exempt" -le "$integration_exempt_cap" ] ||
                indeterminate codex-cap-mismatch "codex_cycle.exempt $cycle_exempt exceeds --integration-exempt-cap $integration_exempt_cap"
            # Challenge round 1, P1 (confirmed): internal arithmetic alone is
            # not integrity. The result is agent-produced, so a schema-valid
            # one whose counters merely add up can still move spend from the
            # charged column into the exempt one and walk past both ceilings.
            # Where the durable checker state is supplied, it is the record of
            # what was actually reserved, and the reported split must match it.
            if [ -n "$cycle_state_file" ] && [ -f "$cycle_state_file" ]; then
                state_charged="$(jq -er '.charged_cycles | select(type == "number")' \
                    "$cycle_state_file" 2>/dev/null)" || state_charged=
                state_exempt="$(jq -er '.exempt_cycles | select(type == "number")' \
                    "$cycle_state_file" 2>/dev/null)" || state_exempt=
                # A result that CLAIMS a split owes durable proof of it. State
                # written before these counters existed carries neither — but a
                # producer old enough to have written that state also omits the
                # split entirely and takes the legacy single-counter branch
                # above, so reaching here with a split and no state counters is
                # not the backward-compatible case. It is an assertion with
                # nothing behind it, and accepting it would let a producer move
                # spend from the charged column into the exempt one and satisfy
                # both ceilings on its own say-so.
                if [ -n "$state_charged" ] && [ -n "$state_exempt" ]; then
                    [ "$cycle_charged" -eq "$state_charged" ] &&
                        [ "$cycle_exempt" -eq "$state_exempt" ] ||
                        indeterminate codex-cap-mismatch "codex_cycle reports charged $cycle_charged / exempt $cycle_exempt but the checker state records charged $state_charged / exempt $state_exempt"
                else
                    indeterminate codex-cap-mismatch "codex_cycle reports a charged/exempt split but the checker state records no counters to confirm it against"
                fi
            fi
        fi
    fi
    # harmon-init#752. A CARRIED cycle is the one shape where no reviewer
    # looked at the gated head at all: the result asserts that a clean verdict
    # for an earlier head still attests this one. The assertion is checkable
    # and therefore must be checked — against the durable checker state, which
    # is what actually made the proof, exactly as the charged/exempt split is.
    # Without that state there is nothing behind the claim but the producer's
    # word, so a claimed carry with no state is indeterminate rather than a
    # pass; `--codex-recheck` stays advisory for every other shape.
    # Challenge round 5, finding `challenge-r5-codex-adversarial-1` (confirmed
    # P1): every carried check below fires on the result CLAIMING a carry, so
    # omitting the claim skipped all of them. A producer could then set
    # `accepted.reviewed_commit` to the envelope head — schema-valid, since
    # without `carried` the ordinary head-agreement rule is satisfied — and the
    # freshness recheck would accept the very state that says this head was
    # never reviewed, promoting a retained result whose provenance is false.
    #
    # The obligation is therefore BIDIRECTIONAL. A result may not claim a carry
    # the state does not record, and it may not omit one the state does: the
    # disclosure exists precisely so a head attested without a reviewer reading
    # it is visible, and a disclosure that can be dropped discloses nothing.
    if [ -n "$cycle_state_file" ] && [ -f "$cycle_state_file" ]; then
        state_attests_head="$(jq -r '.carry.attests_head // empty' \
            "$cycle_state_file" 2>/dev/null)" || state_attests_head=
        if [ "$state_attests_head" = "$head" ]; then
            jq -e 'has("carried")' <<<"$codex_cycle" >/dev/null 2>&1 ||
                indeterminate codex-carried-unproven "the checker state records that $head is attested by a cycle for an earlier commit, but codex_cycle discloses no carried record — a result that omits the carry asserts a reviewer read this head when none did"
        fi
    fi
    if jq -e 'has("carried")' <<<"$codex_cycle" >/dev/null 2>&1; then
        [ -n "$cycle_state_file" ] && [ -f "$cycle_state_file" ] ||
            indeterminate codex-carried-unproven "codex_cycle claims a carried-forward verdict but no --codex-recheck state was supplied to confirm it against — a carry means no reviewer read this head, so the claim cannot rest on the result alone"
        # Challenge round 2, finding `challenge-r2-codex-adversarial-3`
        # (confirmed P2): spot-checking two fields let a schema-valid result
        # alter `from_head`, `base_sha`, `generation` or `carried_at` while
        # keeping the two that were compared — a promoted result carrying false
        # provenance. The disclosure IS the record, so compare it AS the
        # record: one exact object equality, which cannot be partial and cannot
        # fall behind a field added later.
        #
        # `origin_head` is the one field the envelope adds, because the receipt
        # carve-out needs it; the state expresses the same fact as the cycle's
        # own head, so it is checked against that.
        cycle_carried_origin="$(jq -er '.carried.origin_head | select(type == "string")' \
            <<<"$codex_cycle" 2>/dev/null)" ||
            indeterminate codex-carried-unproven "codex_cycle claims a carried-forward verdict with no origin_head"
        state_cycle_head="$(jq -er '.head | select(type == "string")' \
            "$cycle_state_file" 2>/dev/null)" || state_cycle_head=
        jq -e --argjson cycle "$codex_cycle" \
            '(.carry // null) as $state
             | ($cycle.carried | del(.origin_head)) as $claimed
             | ($state != null) and ($state == $claimed)' \
            "$cycle_state_file" >/dev/null 2>&1 ||
            indeterminate codex-carried-unproven "codex_cycle's carried record does not match the checker state's byte for byte — claimed $(jq -c '.carried | del(.origin_head)' <<<"$codex_cycle"), recorded $(jq -c '.carry // null' "$cycle_state_file")"
        [ "$cycle_carried_origin" = "$state_cycle_head" ] ||
            indeterminate codex-carried-unproven "codex_cycle says the verdict was carried from $cycle_carried_origin but the checker state's cycle is ${state_cycle_head:-none}"
    fi
    case "$codex_exit" in
    0) [ -z "$integrator_result" ] || recheck_codex_freshness ;;
    *) exit_condition codex "$codex_exit" "the current-head Codex cycle" ;;
    esac
elif [ "$codex_required" = true ]; then
    # harmon-devkit#685: a positive cap requires a cycle to have been
    # attempted — a null codex_cycle under a resolved cap above 0 means the
    # dispatched pass never ran one, whatever its verdict claims.
    indeterminate codex-cap-mismatch "codex_cycle is null but --integration-cap is $integration_cap (a positive cap requires a cycle)"
fi
# A null cycle is admissible only when the stage is disabled or codex-cloud
# is not a required finder. All other readiness obligations still apply.

# 8b. Require a terminal result for EVERY required finder, including one
# that was never driven. codex_cycle remains its canonical legacy entry.
# Non-Codex carry is deliberately outside the result schema's contract.
finder_cycles='[]'
if [ -n "$integrator_result" ]; then
    finder_cycles="$(jq -c '.payload.finder_cycles // []' "$integrator_result")" ||
        indeterminate finder-indeterminate "cannot read finder cycle evidence"
fi
while IFS= read -r finder_required; do
    fc_slug="$(jq -r '.id' <<<"$finder_required")"
    if [ "$fc_slug" = codex-cloud ]; then
        fc_cycle="$codex_cycle"
    else
        fc_cycle="$(jq -ce --arg id "$fc_slug" '
          [.[] | select(.finder == $id)] |
          if length == 1 then .[0] else null end' <<<"$finder_cycles")" ||
            fail_condition finder-missing "required finder $fc_slug has no unique current-head cycle — request it and settle its findings"
    fi
    [ "$fc_cycle" != null ] ||
        fail_condition finder-missing "required finder $fc_slug has no current-head cycle"
    [ "$(jq -r '.head' <<<"$fc_cycle")" = "$head" ] ||
        indeterminate finder-indeterminate "required finder $fc_slug reviewed a different head"
    fc_exit="$(jq -r '.exit_code' <<<"$fc_cycle")"
    case "$fc_exit" in
    0) ;;
    *) exit_condition finder "$fc_exit" "required finder $fc_slug" ;;
    esac
    # Only Codex has checker-backed exemptions. Every non-Codex cycle spends
    # its budget, irrespective of its self-reported charged/exempt split.
    jq -e --argjson limits "$finder_required" '
      (if $limits.id != "codex-cloud" then .cycle <= $limits.budget
       elif $limits.explicit_budget then (.charged // .cycle) <= $limits.budget
       else true end) and
      (if $limits.carry == "fresh" then .carried == null else true end) and
      .cycle == ((.charged // .cycle) + (.exempt // 0))
    ' <<<"$fc_cycle" >/dev/null ||
        fail_condition finder-capped "required finder $fc_slug exceeded its resolved budget, has inconsistent spend, or requires a fresh review"
done < <(jq -c '.[]' <<<"$required_finders")

applied_dispositions='[]'
if [ -n "$integrator_result" ]; then
    # 9a. The pass's own findings[] is unconditional evidence, independent of
    # codex_cycle — a null or clean codex_cycle says nothing about a NEW
    # top-level human finding the integrator surfaced this same pass (review
    # round 2 gauntlet challenge, harmon-devkit#639): a badged finding outside
    # an inline thread has no reply linkage, so no other condition here (the
    # thread-reply-linkage check is inline-only, the fingerprint only detects
    # CHANGE, deferred-findings only covers findings already carried from an
    # earlier stage) can ever catch it. Any non-empty findings[] on the pass
    # being gated is exactly what "the orchestrator has not adjudicated away"
    # (ai/agents/integrator.md §7) means — it is unresolved by construction,
    # whatever verdict the pass claims.
    findings_json="$(jq -c '.payload.findings // []' "$integrator_result" 2>/dev/null)" ||
        indeterminate malformed-data "integrator result payload is unreadable"
    findings_count="$(jq -r 'length' <<<"$findings_json" 2>/dev/null)" ||
        indeterminate malformed-data "integrator result findings could not be read"
    if [ "$findings_count" -gt 0 ]; then
        finding_ids="$(jq -r '[.[].id] | join(", ")' <<<"$findings_json")"
        fail_condition unresolved-integrator-findings "the gated pass's own findings[] is non-empty: $finding_ids — adjudicate and re-dispatch before promoting"
    fi

    # 9b. Every applied disposition that touches a DEFERRED finding must have a
    # matching settlement in run.json, regardless of the disposition's outcome
    # (harmon-devkit#685: "the moment an integrator pass applies fix|decline|file
    # to a deferred finding, the matching append-only settlement exists"). This
    # is scoped to deferred findings ONLY, never to a finding this same
    # integration pass discovered fresh (review round 2 gauntlet challenge,
    # harmon-devkit#639): a fresh integration-stage finding was never carried
    # with disposition `defer` by any adjudication document, so a settlement for
    # it is exactly the "settlement for a finding never dispositioned defer"
    # render-dev-flow.mjs's own cross-document consistency check rejects as
    # invalid — requiring one here would make such a finding impossible to
    # ever pass this gate, resolved or not. readiness_input's own
    # deferred_findings (settled ∪ unsettled) is the authoritative set of
    # finding ids that are genuinely deferred; read straight from run.json for
    # the settlement lookup itself rather than the projection, since this check
    # additionally needs applied_dispositions from a DIFFERENT document (the
    # integrator result), so the cross-reference happens here, not in the
    # projection.
    deferred_ids="$(jq -c '[.deferred_findings.settled[].finding_id,
    .deferred_findings.unsettled[].finding_id]' <<<"$readiness_input" 2>/dev/null)" ||
        indeterminate malformed-data "readiness-input's deferred_findings could not be read"
    applied_dispositions="$(jq -c '.payload.applied_dispositions // []' \
        "$integrator_result" 2>/dev/null)" ||
        indeterminate malformed-data "integrator result payload is unreadable"
    # The disposition travels with the finding_id through this whole check, not
    # just the id alone (Codex cloud-review cycle on PR harmon-devkit#758): an
    # id-only match would accept run.json recording "declined" for a finding
    # applied_dispositions calls "fixed" — both documents individually
    # schema-valid, the deferred projection reads settled, and the gate would
    # promote over contradictory evidence about how the finding was actually
    # resolved.
    settleable_tsv="$(jq -r --argjson deferred "$deferred_ids" \
        '.[] | select(.disposition == "fix" or .disposition == "decline" or .disposition == "file") |
     . as $d | select($deferred | index($d.finding_id) != null) | [$d.finding_id, $d.disposition] | @tsv' \
        <<<"$applied_dispositions" 2>/dev/null)"
    if [ -n "$settleable_tsv" ]; then
        # $run_json is already resolved and proven to exist above, for the
        # active-run binding — reused here rather than re-checked.
        settlements="$(jq -c '.settlements // []' "$run_json" 2>/dev/null)" ||
            indeterminate malformed-data "run.json's settlements could not be read"
        while IFS=$'\t' read -r finding_id disposition; do
            [ -n "$finding_id" ] || continue
            jq -e --arg id "$finding_id" --arg disp "$disposition" \
                'any(.[]; .finding_id == $id and .disposition == $disp)' \
                <<<"$settlements" >/dev/null 2>&1 ||
                fail_condition disposition-unsettled "applied_dispositions names deferred finding $finding_id as $disposition but run.json's settlements[] has no entry with that id and disposition"
        done <<<"$settleable_tsv"
    fi

    # 9c. The pass itself must be a completed, clean one — independent of
    # whether the Codex condition above was waived (Codex cloud-review cycle on
    # PR harmon-devkit#758). Everything above reads PARTS of the result
    # (codex_cycle, findings[], applied_dispositions) and re-derives the rest
    # live, so a schema-valid envelope with status:"blocked" (the agent stopped
    # in its §1 before ever reading the threads or the top-level comments) or a
    # verdict of "pending" (CI unsettled when it looked, so it skipped the
    # cycle without driving one — a null codex_cycle that is NOT a cap-0
    # waiver) carrying empty findings[] passes every check above under
    # --integration-cap 0: the empty lists mean "never collected", not "nothing
    # found", and 9a's top-level-finding catch is only as good as the pass that
    # populated it. The validator already ties verdict:"clean" to green
    # required checks, a null-or-terminal-clean cycle, and empty
    # unanswered_thread_roots, so requiring it here is what makes those
    # guarantees apply to the gated pass at all.
    integrator_status="$(jq -er '.status | select(type == "string")' \
        "$integrator_result" 2>/dev/null)" ||
        indeterminate malformed-data "integrator result carries no status"
    [ "$integrator_status" = completed ] ||
        fail_condition integrator-not-clean "integrator result status is $integrator_status, not completed — the pass never finished collecting evidence; re-dispatch against this head"
    integrator_verdict="$(jq -er '.payload.verdict | select(type == "string")' \
        "$integrator_result" 2>/dev/null)" ||
        indeterminate malformed-data "integrator result carries no verdict"
    [ "$integrator_verdict" = clean ] ||
        fail_condition integrator-not-clean "integrator result verdict is $integrator_verdict, not clean — only a completed clean pass for this head can be gated; re-dispatch after what it is waiting on or reporting is settled"

fi

# 9d. Remediation loops against the resolved remediation cap
# (harmon-devkit#685: "integration -> implement -> integration loops are
# counted against [rounds.<policy>].remediation; exceeding it is capped with
# escalation, and code-changing integration dispositions past the cap are
# rejected"). The count is the record's own, not a claim the pass makes:
# stage_transitions[] records every stage the run entered, so every
# `integration` entry AFTER the first is a return to it, and the count of
# returns is the number of remediation loops. Every return necessarily went
# back through implement, because integration's only outgoing edge IS
# implement (run.schema.json's ALLOWED_EDGES, enforced by
# validate-result-schemas.mjs's checkStageTransitionsOrder, which also
# refuses a first-visit implement -> integration as a premature remediation
# return). The path back in may then run implement -> verify -> ... ->
# integration or implement -> integration; either way it is one loop.
#
# One condition, not two. The criterion's second half — "code-changing
# integration dispositions past the cap are rejected" — needs no separate
# branch, and a branch written for it was wrong (challenge round 1,
# confirmed). Past the cap, THIS condition already rejects the pass whatever
# its dispositions. AT the cap it must not fire at all: SKILL.md's dispatch
# contract has `applied_dispositions` carry everything "accumulated so far
# this integration stage, so a pass that comes back clean can echo them", so
# the fix that CAUSED the final loop is still listed on the clean pass that
# closes it. Reading that as "a code change still needs applying" refuses
# precisely the run that converged exactly on budget. A pass that genuinely
# still owes a code change is not clean, and step 9c already refuses it.
remediation_loops="$(jq -r '[.stage_transitions[]? | select(.stage == "integration")] | length | if . > 0 then . - 1 else 0 end' \
    "$run_json" 2>/dev/null)" ||
    indeterminate malformed-data "run.json's stage_transitions could not be read for the remediation-loop count"
[ "$remediation_loops" -le "$remediation_cap" ] ||
    fail_condition remediation-capped "the record shows $remediation_loops integration -> implement -> integration remediation loop(s), exceeding --remediation-cap $remediation_cap — escalate rather than promote (harmon-devkit#685)"
# The LOWER bound, and the complement of the ceiling above. A code-changing
# disposition (fix/restructure/delete) means code changed during integration,
# and integration's ONLY outgoing edge is implement (run.schema.json's
# ALLOWED_EDGES, with no self-loop and no repeated consecutive stage) — so
# such a disposition cannot exist without the record showing at least one
# integration -> implement -> integration re-entry. Zero loops alongside one
# is an inconsistent record that would promote having spent no remediation
# round at all, which at --remediation-cap 0 is the whole budget.
#
# Deliberately "at least one", NOT "at least the round the finding came
# from". Integrate cycle 2 asked for the stronger, round-indexed form and
# cycle 3 showed it unsound: a finding id's round segment is its pass's
# `integration_round`, and that schema field counts PASSES, not rounds
# ("integration_round counts passes, cycle counts Codex cycles"). Waiting
# and re-dispatching advance it while spending no remediation round, so a
# finding first raised by pass 2 and fixed by the first fix push has one
# legitimate loop and a round-indexed bound would reject it forever. The
# residual it was reaching for — one recorded loop covering several later
# code-changing cycles — needs per-finding loop attribution the record does
# not carry, and is filed rather than approximated (see the follow-up).
#
# Distinct from the at-cap branch challenge round 2 deleted: that one refused
# a pass AT the ceiling for echoing the very fix that caused its own final
# loop. This refuses a record claiming a code change with no loop recorded
# anywhere, which no legitimate trajectory produces.
if [ "$remediation_loops" -eq 0 ]; then
    code_changing="$(jq -r '[.[] | select(.disposition == "fix" or .disposition == "restructure" or .disposition == "delete") | .finding_id] | join(", ")' \
        <<<"$applied_dispositions" 2>/dev/null)" ||
        indeterminate malformed-data "applied_dispositions could not be read for the remediation-loop lower bound"
    [ -z "$code_changing" ] ||
        fail_condition remediation-capped "the gated pass applies code-changing disposition(s) ($code_changing) but the record shows no integration -> implement -> integration remediation loop at all — a code change during integration always records one (harmon-devkit#685)"
fi

# 9f. The integration record (harmon-devkit#1272), read directly — never a
# verdict reason, never an inference about fix pushes (challenge-r5 replaced
# the round-4 verdict allowlist). (c) Any engine indeterminate — a push after
# a tell cycle without a delete/restructure remedy, a P2-only push past the
# fixing ceiling, a head move the record's remediation pushes cannot classify
# (harmon-devkit#1386: the engine reads run.json's stage_transitions[]
# remediation records, never `charged`), a cycle-ordinal hole, an invalid
# record — is indeterminate. (b) Any integration adjudication entry
# holding an adjudicated P0 or P1 whose disposition is file or defer fails:
# filing settles P2s only. (a) An integration pass with findings and no
# adjudication never reaches this step: step 6's readiness-input projection
# already refuses it. (e) The record must END at the gated pass: its latest
# integration pass carries the gated result's integration_round,
# codex_cycle.cycle and head, so a record missing a later pass (and the
# adjudication with it) cannot vouch for the gated head
# (integration-r1-codex-cloud-1). Owed whenever the gated result carries a
# Codex cycle or the record holds any integration pass; a cap-0 run with no
# integration pass has nothing to bind. (d) Otherwise this step passes.
exit_engine="$support_dir/dev-flow-exit.mjs"
[ -f "$exit_engine" ] ||
    die "$exit_engine is missing — the dev-flow-support package must be vendored alongside this skill"
# The engine path goes LAST: the engine treats process.argv[1] as the script
# it was invoked as and runs its own CLI when that resolves to itself.
integration_record="$(node --input-type=module -e '
const [record, cap, validator, gated, engine] = process.argv.slice(1);
const { integrationExitForRunDir, loadRunDir, ExitIndeterminate } = await import(engine);
try {
  await integrationExitForRunDir(record, { integrationCap: Number(cap), validatorPath: validator });
} catch (err) {
  if (!(err instanceof ExitIndeterminate)) throw err;
  console.log(JSON.stringify({ ok: false, reason: err.message }));
  process.exit(0);
}
const { passes, adjudications } = loadRunDir(record);
const fs = await import("node:fs");
const result = gated ? JSON.parse(fs.readFileSync(gated, "utf8")) : null;
const bindOf = (envelope) => ({ round: envelope.payload?.integration_round ?? null, cycle: envelope.payload?.codex_cycle?.cycle ?? null, head: envelope.head ?? null });
const latest = passes
  .filter((p) => p.envelope.role === "integrator")
  .map((p) => bindOf(p.envelope))
  .sort((x, y) => x.round - y.round)
  .at(-1) ?? null;
const want = result ? bindOf(result) : null;
const owed = result && (want.cycle !== null || latest !== null);
const bound = !owed || (latest !== null && latest.round === want.round && latest.cycle === want.cycle && latest.head === want.head);
const docs = adjudications.map((a) => a.doc).filter((d) => d?.stage === "integration");
const filed = docs.flatMap((d) => d.adjudications)
  .filter((e) => ["P0", "P1"].includes(e.adjudicated_priority) && ["file", "defer"].includes(e.disposition))
  .map((e) => e.finding_id);
console.log(JSON.stringify({ ok: true, filed, bound, latest, want }));
' "$record_dir" "$integration_cap" "$validate_result_schemas" "$integrator_result" "$exit_engine" 2>/dev/null)" ||
    indeterminate integration-exit-indeterminate "the integration record could not be read over --record"
jq -e '.ok' <<<"$integration_record" >/dev/null 2>&1 ||
    indeterminate integration-exit-indeterminate "the integration exit is indeterminate: $(jq -r '.reason // "unreadable record output"' <<<"$integration_record" 2>/dev/null)"
jq -e '.bound' <<<"$integration_record" >/dev/null 2>&1 ||
    indeterminate integration-record-unbound "the record's latest integration pass $(jq -c '.latest' <<<"$integration_record") is not the gated result $(jq -c '.want' <<<"$integration_record") (integration_round, codex_cycle.cycle, head) — persist every integrator pass and its adjudication before gating"
filed_gating="$(jq -r '.filed | join(", ")' <<<"$integration_record")"
[ -z "$filed_gating" ] ||
    fail_condition integration-filed-gating-finding "integration adjudication files or defers a confirmed P0/P1 ($filed_gating) — filing settles P2s only; fix it and run a clean cycle, or escalate"

# 9e. Every adjudicated round has its own issue evidence comment
# (harmon-devkit#685: "every adjudicated round has a matching issue evidence
# marker (destination: issue, same stage/round); a `pr`-destination marker
# does not substitute"). validate-result-schemas.mjs enforces the same rule
# over a run record, but its missing-marker half deliberately waits for
# `outcome: ready-for-review` — a run adjudicates a round and THEN publishes
# its evidence, so an unconditional document check would fault the normal
# in-flight sequence. That relaxation leaves the invariant unenforced at
# exactly the moment it matters most, since promotion is what makes the
# record the durable artifact a harvester reads back. Challenge round 3,
# confirmed: gating promotion is the missing half, not a duplicate of it.
#
# Read from the record the gate already holds: each adjudication document's
# (stage, round) against run.json's own evidence_comments[]. A marker with
# round: null is a per-stage rollup and satisfies nothing here; a `pr`
# marker naming the round is called out separately, because the schema has
# the rollup link BACK to the per-round issue comments and so posted after
# them.
for evidence_adj in "$record_dir"/adjudications/*.json; do
    [ -f "$evidence_adj" ] || continue
    evidence_pair="$(jq -r '[.stage, .round] | @tsv' "$evidence_adj" 2>/dev/null)" || continue
    evidence_stage="${evidence_pair%%	*}"
    evidence_round="${evidence_pair##*	}"
    [ -n "$evidence_stage" ] && [ -n "$evidence_round" ] &&
        [ "$evidence_stage" != null ] && [ "$evidence_round" != null ] || continue
    evidence_destinations="$(jq -r --arg stage "$evidence_stage" --argjson round "$evidence_round" \
        --arg run_id "$active_run_id" \
        '[.evidence_comments[]?.marker
          | select(.run_id == $run_id and .stage == $stage and .round == $round)
          | .destination] | unique | join(",")' \
        "$run_json" 2>/dev/null)" ||
        indeterminate malformed-data "run.json's evidence_comments could not be read"
    case ",${evidence_destinations}," in
    *,issue,*) ;;
    *,pr,*)
        fail_condition evidence-marker-missing "$evidence_stage round $evidence_round is adjudicated but its only evidence marker has destination \"pr\" — the per-round record belongs on the issue, and a pr comment never substitutes for it (harmon-devkit#685)"
        ;;
    *)
        fail_condition evidence-marker-missing "$evidence_stage round $evidence_round is adjudicated but no evidence marker with destination \"issue\" records it — post its round evidence before promoting (harmon-devkit#685)"
        ;;
    esac
done

# Authenticity backstop, deliberately AFTER the per-round conditions above so
# the specific, actionable one reports first. The flat evidence_comments[]
# projection is not self-authenticating: it is derived from the append-only
# evidence_registrations[] chain, and render-dev-flow's readiness-input
# validates structure only — so a record can carry an out-of-band marker with
# the right stage/round/destination that the chain never registered, or a
# settlement the adjudications do not support. The record's own SEMANTIC
# validation recomputes the chain digests (checkRunChainIntegrity), binds every
# marker's run_id (checkEvidenceMarkerRunId), and re-applies the
# adjudication/marker rule for an ended run. Codex cloud-review cycle 1 on
# PR #800, confirmed.
evidence_validate_args=()
for evidence_adj in "$record_dir"/adjudications/*.json; do
    [ -f "$evidence_adj" ] || continue
    evidence_validate_args+=(--adjudication "$evidence_adj")
done
[ "${#evidence_validate_args[@]}" -gt 0 ] || evidence_validate_args=(--no-adjudications)
# #821: strict mode — bind adjudication documents to the trusted receipt
# sequence when the run record carries one. The receipts field is not yet in
# run.schema.json, so pass --receipts only when the data exists; when it
# does, every adjudication stage must have a matching transition receipt.
receipts_file="${record_dir}/run.json"
if jq -e '.receipts | type == "array"' "$receipts_file" >/dev/null 2>&1; then
    evidence_validate_args+=(--receipts "$receipts_file")
fi
if ! record_semantic_err="$(node "$validate_result_schemas" run "$run_json" \
    "${evidence_validate_args[@]}" 2>&1 >/dev/null)"; then
    indeterminate malformed-data "run.json fails its own semantic validation against the record's adjudication set — its evidence chain, markers, or settlements cannot be trusted: $(printf '%s' "$record_semantic_err" | head -1)"
fi

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
# 9b. Re-read the scalars and re-establish the base relation. This runs
# BEFORE the fresh content fingerprint and the second checks evaluation,
# deliberately: the compare below is a network call of up to 60s, and
# step 12 promises the final scalar read is the LAST one with nothing
# fetching behind it. Putting the comparison after those snapshots broke
# that promise — a check turning red or content moving during it went
# unseen, because the read that follows looks at scalars only. A changed head
# invalidates every result this gate relied on, and never wait out a
# mismatch: a fresh replica showing someone else's newer push is evidence,
# and re-polling until it converges would discard it. The review decision
# and merge state are re-evaluated here because they can move without moving
# the head: a CHANGES_REQUESTED review landing mid-gate is absorbed into the
# reviews fingerprint (so the post-promotion compare would stay identical),
# and mergeability is excluded from the fingerprint by design — this re-read
# is the only thing that can catch either.
recheck="$(run_gh pr view "$pr" --repo "$repo" \
    --json state,isDraft,headRefOid,reviewDecision,mergeStateStatus,baseRefName)" ||
    indeterminate fetch-failed "cannot re-read the PR immediately before the verdict"
jq -e '.state == "OPEN"' <<<"$recheck" >/dev/null ||
    fail_condition pr-not-open "the PR left the OPEN state while the gate was reading it"
if [ "$require_draft" = 1 ]; then
    jq -e '.isDraft == true' <<<"$recheck" >/dev/null ||
        fail_condition pr-not-draft "the PR was promoted while the gate was reading it"
else
    jq -e '.isDraft == false' <<<"$recheck" >/dev/null ||
        fail_condition pr-draft "the PR returned to draft during the promoted re-check — the promotion no longer stands"
fi
jq -e --arg head "$head" '.headRefOid == $head' <<<"$recheck" >/dev/null ||
    fail_condition head-moved "PR head changed while the gate was reading it"
[ "$(jq -r '.reviewDecision // ""' <<<"$recheck")" != "CHANGES_REQUESTED" ] ||
    fail_condition changes-requested "a reviewer requested changes while the gate was reading"
# Re-establish behind-by from the GRAPH, not just the cache. Gate evaluation is
# long, and a base that advances (or a retarget) during it leaves a head that
# was level when checked and is behind by the verdict — caught here only if the
# cache happens to have caught up, which is the assumption this whole condition
# exists to stop making.
# A retarget mid-gate invalidates every condition already evaluated against
# the old base, so stop rather than re-deriving against a moving target.
recheck_base="$(jq -er '.baseRefName | select(type == "string")' <<<"$recheck")" ||
    indeterminate malformed-data "PR payload carries no base branch name (immediately before the verdict)"
# BOTH modes: evidence gathered against the old base says nothing about a new
# one, and retargeting can change required workflows and mergeability. §2
# classifies this as drift, so it is reported rather than undone.
[ "$recheck_base" = "$behind_base_ref" ] ||
    fail_condition base-retargeted "the PR base changed from ${behind_base_ref} to ${recheck_base} while the gate was reading — re-run against the new base"
establish_behind "$recheck" "immediately before the verdict"
[ "$behind_by" -eq 0 ] ||
    fail_condition behind-base "the head fell ${behind_by} commit(s) behind ${behind_base_ref} while the gate was reading — ${behind_remedy}; then re-run"

case "$(jq -r '.mergeStateStatus // ""' <<<"$recheck")" in
DIRTY) fail_condition merge-state-dirty "merge conflicts appeared while the gate was reading" ;;
BEHIND)
    # Lag claim only — see the pre-evaluation branch.
    [ "$behind_by" -ne 0 ] ||
        indeterminate merge-state-stale "mergeStateStatus reads BEHIND while the commit graph reports 0 behind ${behind_base_ref:-the base} — the cache is lagging; re-poll briefly"
    ;;
UNKNOWN | "")
    indeterminate merge-state-unknown "GitHub is recomputing mergeability — re-poll briefly"
    ;;
esac

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

# 11b. harmon-devkit#1406: a with-push cycle's charge is settled from CI
# evidence by the integrator's own `check`, never by this gate. So ask the
# checker, read-only, what split the latest CI implies — AFTER the final checks
# read, so no evidence older than it can leave an exemption standing on a
# ready verdict (thread 4260347252) — and refuse a state that records another.
if [ "$codex_cycle" != null ] && [ -n "${cycle_state_file:-}" ] && [ -f "$cycle_state_file" ]; then
    [ -x "$codex_checker" ] ||
        indeterminate codex-cap-mismatch "$codex_checker is missing — cannot confirm the cycle's CI-settled charge"
    ci_split_out="$("$codex_checker" ci-split --state "$cycle_state_file" --run-id "$active_run_id" 2>/dev/null)" ||
        indeterminate codex-cap-mismatch "cannot derive the cycle's CI-settled charge from $cycle_state_file"
    jq -e '.recorded == .settled' <<<"$ci_split_out" >/dev/null 2>&1 ||
        indeterminate codex-cap-mismatch "the cycle's charge is not settled from the latest CI evidence: the checker state records $(jq -c '.recorded' <<<"$ci_split_out" 2>/dev/null) but CI implies $(jq -c '.settled' <<<"$ci_split_out" 2>/dev/null) ($(jq -r '.detail' <<<"$ci_split_out" 2>/dev/null)) — run the checker's \`check --run-id\` to settle it, then dispatch the integrator again or re-run this gate"
fi

# 12. The LAST network read, and it reapplies EVERY scalar gate rather than
# just identity. Checking only head/base
# would let a close, a promotion, a CHANGES_REQUESTED review or a DIRTY merge
# state land during the comparison and still emit `ready`, and draft state and
# mergeability are excluded from the fingerprint so nothing downstream catches
# them. Bounded, not regressive: no further network call follows, and the
# residual window is the caller's contractual pre-promotion re-read.
final="$(run_gh pr view "$pr" --repo "$repo" \
    --json state,isDraft,headRefOid,reviewDecision,mergeStateStatus,baseRefName,baseRefOid,body,closingIssuesReferences)" ||
    indeterminate fetch-failed "cannot re-read the PR after the final comparison"
final="$(normalize_body_field <<<"$final")" ||
    indeterminate malformed-data "final PR payload carries an invalid body"
jq -e '.state == "OPEN"' <<<"$final" >/dev/null ||
    fail_condition pr-not-open "the PR left the OPEN state while the gate was comparing against the base"
if [ "$require_draft" = 1 ]; then
    jq -e '.isDraft == true' <<<"$final" >/dev/null ||
        fail_condition pr-not-draft "the PR was promoted while the gate was comparing against the base"
else
    jq -e '.isDraft == false' <<<"$final" >/dev/null ||
        fail_condition pr-draft "the PR returned to draft while the gate was comparing against the base"
fi
jq -e --arg head "$head" '.headRefOid == $head' <<<"$final" >/dev/null ||
    fail_condition head-moved "PR head changed while the gate was comparing against the base"
body_unchanged="$(jq -nr --argjson final "$final" --argjson verified "$fp_pr" \
    '$final.body == $verified.body')" ||
    indeterminate malformed-data "cannot compare the final and fingerprinted PR bodies"
[ "$body_unchanged" = true ] ||
    fail_condition content-moved "PR body changed after the fingerprint comparison — re-adjudicate against the current body"
assert_closing_linkage "$final" "final snapshot"
jq -e --arg base "$behind_base_ref" '.baseRefName == $base' <<<"$final" >/dev/null ||
    fail_condition base-retargeted "the PR base changed while the gate was comparing against it — re-run against the new base"
jq -e --arg oid "$behind_base_oid" '.baseRefOid == $oid' <<<"$final" >/dev/null ||
    fail_condition behind-base "the base branch advanced while the gate was comparing against it — the behind count is stale; ${behind_remedy}; then re-run"
[ "$(jq -r '.reviewDecision // ""' <<<"$final")" != "CHANGES_REQUESTED" ] ||
    fail_condition changes-requested "a reviewer requested changes while the gate was comparing against the base"
# Same three-way handling as the recheck above — writing only the DIRTY arm
# here let UNKNOWN or a cache-BEHIND arriving during the comparison window
# fall straight through to `ready`, which is precisely the set of states the
# readiness rule excludes.
case "$(jq -r '.mergeStateStatus // ""' <<<"$final")" in
DIRTY) fail_condition merge-state-dirty "merge conflicts appeared while the gate was comparing against the base" ;;
BEHIND)
    # Lag claim only — see the pre-evaluation branch.
    [ "$behind_by" -ne 0 ] ||
        indeterminate merge-state-stale "mergeStateStatus turned BEHIND while the gate was comparing, with the graph reporting 0 behind ${behind_base_ref:-the base} — the cache is lagging; re-poll briefly"
    ;;
UNKNOWN | "")
    indeterminate merge-state-unknown "GitHub stopped reporting mergeability while the gate was comparing — re-poll briefly"
    ;;
esac

if [ "$require_draft" = 1 ]; then
    verdict_condition=ready
    verdict_detail="every mechanically checkable readiness condition holds"
else
    verdict_condition=promoted
    verdict_detail="every mechanically checkable condition except the draft requirement holds; this re-checks an existing promotion and never authorizes gh pr ready"
fi
# The checker-only verdict attests these exact checked bytes. A newer
# reservation or state edit invalidates it, even when the PR head is unchanged.
if [ -z "$integrator_result" ]; then
    cmp -s "$codex_recheck_state" "$checker_state_snapshot" ||
        indeterminate codex-stale "checker state changed during the gate — re-run the gate against the current state"
fi
jq -cn \
    --arg head "$head" \
    --arg fingerprint "$fingerprint" \
    --arg condition "$verdict_condition" \
    --arg detail "$verdict_detail" \
    --arg checker_state "$codex_recheck_state" \
    --arg integrator_result "$integrator_result" \
    --argjson cycle "$codex_cycle" \
    --slurpfile checks_sf <(printf '%s' "$checks_summary") \
    '{reportable_checks:{failing:($checks_sf[0].optional_failing | .[0:20]),
                         total:($checks_sf[0].optional_failing | length)},
      status:"pass",condition:$condition,head:$head,fingerprint:$fingerprint,
      detail:$detail}
     + {cycle_evidence:(if $integrator_result != "" then
          {kind:"integrator-result",path:$integrator_result}
        else {kind:"checker-state",path:$checker_state,cycle:$cycle.cycle} end)}'
