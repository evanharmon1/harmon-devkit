#!/usr/bin/env bash
# lifecycle-labels.sh — execute one canonical lifecycle label transition across
# an issue and every discoverable same-repository delivery PR.
#
# Canonical contract: docs/dev-loop/label-lifecycle.md
# - Claim writes delegate exclusively to claim/assets/claim-transaction.sh and
#   track-work/assets/release-claim.sh; never a second claim writer.
# - Sibling-aware needs-review clearing delegates to clear-needs-review.sh.
# - `slated` stays outside this asset (owned by dev-flow-support/assets/plan-revise.mjs).
# - `promote` adds `merge-ready` only when given a passing live-check result
#   for the current non-draft delivery PR head.
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
release_claim_sh="$script_dir/release-claim.sh"
clear_needs_review_sh="$script_dir/clear-needs-review.sh"
claim_transaction_sh="$script_dir/../../claim/assets/claim-transaction.sh"

usage() {
    cat <<'EOF'
Usage:
  lifecycle-labels.sh --rules-json
  lifecycle-labels.sh <event> --repo OWNER/NAME --issue N [options]

Events:
  claim          Start a verified claim (delegates to claim-transaction.sh)
  review-entry   Enter or renew agent review (adds needs-review; claim stays)
  review-clear   Clear needs-review when review work is complete
  fix-round      Pull back into fix rounds (claim stays/restores; clears needs-review)
  park           Park a passed non-head draft PR (releases claim; adds parked)
  unpark         Remove parked when leaving the queue without promoting
  promote        Mark promoted queue head merge-ready (requires --check-result FILE)
  unpromote      Remove merge-ready on invalidation (base move, red CI, late review)
  block          Mark draft work blocked on human input
  unblock        Clear blocked once human input resolves or work ends
  resume         Resume work on draft (removes parked/merge-ready; claim stays/restores)
  close          Terminal close cleanup across claim and lifecycle state labels

Options:
  --repo OWNER/NAME            Target repository (required)
  --issue N                    Target issue number (required)
  --pr N                       Explicit delivery PR number
  --branch BRANCH              Claim/feature branch for open Refs PR discovery and keyed claim release
  --check-result FILE          Passing live handoff-check JSON verdict (required for promote; alias: --gate)
  --head SHA                   Expected 40-hex PR head SHA (optional extra guard for promote)
  --record-file FILE           Claim comment record file for claim-transaction.sh
  --claim-label LABEL|none     Claim label for claim-transaction.sh
  --model-label LABEL|none     Optional model label for claim-transaction.sh
  --family SLUG                Trusted model family for claim-transaction.sh
  --runtime-environment VALUE  Runtime environment for claim-transaction.sh
  --registry-snapshot FILE|none Registry snapshot path for claim-transaction.sh
  --allow-label-less           Permit label-less claim ownership
  --approve-review-pullback    Pass review pull-back approval to claim-transaction.sh
  --reason TEXT                Override release reason passed to release-claim.sh
  --not-after ISO8601          Forward cutoff timestamp to release-claim.sh
  --require-closed             Forward closed-issue requirement to release-claim.sh
  --idempotency-key SHA256     Override SHA-256 idempotency key for release-claim.sh (requires --branch)
  -h, --help                   Show this help text
EOF
}

rules_json() {
    cat <<'EOF'
{
  "asset": "track-work/assets/lifecycle-labels.sh",
  "labels": {
    "claim:*": {
      "managed": true,
      "delegates_add": "claim/assets/claim-transaction.sh",
      "delegates_remove": "track-work/assets/release-claim.sh",
      "object_scope": "issue",
      "add_events": ["claim", "resume", "fix-round"],
      "remove_events": ["park", "promote", "close"],
      "never_coexists_with": ["parked", "merge-ready"]
    },
    "slated": {
      "managed": false,
      "outside_asset": "dev-flow-support/assets/plan-revise.mjs",
      "object_scope": "issue",
      "add_events": [],
      "remove_events": [],
      "never_coexists_with": []
    },
    "parked": {
      "managed": true,
      "object_scope": "issue_and_pr",
      "add_events": ["park"],
      "remove_events": ["promote", "unpark", "resume", "close"],
      "never_coexists_with": ["claim:*", "merge-ready", "needs-review", "blocked"]
    },
    "merge-ready": {
      "managed": true,
      "object_scope": "issue_and_pr",
      "add_events": ["promote"],
      "remove_events": ["unpromote", "resume", "close"],
      "never_coexists_with": ["claim:*", "parked", "needs-review", "blocked"]
    },
    "needs-review": {
      "managed": true,
      "delegates_remove": "track-work/assets/clear-needs-review.sh",
      "object_scope": "issue_and_pr",
      "add_events": ["review-entry"],
      "remove_events": ["review-clear", "fix-round", "close"],
      "never_coexists_with": ["parked", "merge-ready"]
    },
    "blocked": {
      "managed": true,
      "object_scope": "issue_and_pr_if_present",
      "add_events": ["block"],
      "remove_events": ["unblock", "close"],
      "never_coexists_with": ["parked", "merge-ready"]
    }
  }
}
EOF
}

lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

sha256_hex() {
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$1"
    else
        echo "lifecycle-labels: no SHA-256 tool available" >&2
        return 1
    fi
}

if [ "$#" -eq 0 ]; then
    usage >&2
    exit 2
fi

case "$1" in
-h | --help)
    usage
    exit 0
    ;;
--rules-json)
    [ "$#" -eq 1 ] || {
        usage >&2
        exit 2
    }
    rules_json
    exit 0
    ;;
esac

event="$1"
shift

case "$event" in
slated | slate | unslate)
    echo "lifecycle-labels: 'slated' stays outside lifecycle-labels.sh (owned by dev-flow-support/assets/plan-revise.mjs)" >&2
    exit 2
    ;;
claim | review-entry | review-clear | fix-round | park | unpark | promote | unpromote | block | unblock | resume | close) ;;
*)
    echo "lifecycle-labels: unknown event '$event'" >&2
    usage >&2
    exit 2
    ;;
esac

repo=""
issue=""
pr=""
branch=""
check_result=""
expected_head=""
record_file=""
claim_label=""
model_label=""
family=""
runtime_environment=""
registry_snapshot=""
allow_label_less=0
approve_review_pullback=0
release_reason=""
not_after=""
require_closed=0
idempotency_key=""

while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --issue | --pr | --branch | --check-result | --gate | --head | \
        --record-file | --claim-label | --model-label | --family | \
        --runtime-environment | --registry-snapshot | --reason | \
        --not-after | --idempotency-key)
        if [ "$#" -lt 2 ]; then
            usage >&2
            exit 2
        fi
        case "$1" in
        --repo) repo="$2" ;;
        --issue) issue="$2" ;;
        --pr) pr="$2" ;;
        --branch) branch="$2" ;;
        --check-result | --gate) check_result="$2" ;;
        --head) expected_head="$2" ;;
        --record-file) record_file="$2" ;;
        --claim-label) claim_label="$2" ;;
        --model-label) model_label="$2" ;;
        --family) family="$2" ;;
        --runtime-environment) runtime_environment="$2" ;;
        --registry-snapshot) registry_snapshot="$2" ;;
        --reason) release_reason="$2" ;;
        --not-after) not_after="$2" ;;
        --idempotency-key) idempotency_key="$2" ;;
        esac
        shift 2
        ;;
    --allow-label-less)
        allow_label_less=1
        shift
        ;;
    --approve-review-pullback)
        approve_review_pullback=1
        shift
        ;;
    --require-closed)
        require_closed=1
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "lifecycle-labels: unknown option '$1'" >&2
        usage >&2
        exit 2
        ;;
    esac
done

for tool in gh jq git; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "lifecycle-labels: required tool '$tool' is not installed" >&2
        exit 2
    }
done

if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    [[ ! "$issue" =~ ^[1-9][0-9]*$ ]]; then
    echo "lifecycle-labels: expected --repo OWNER/NAME and a positive numeric --issue" >&2
    exit 2
fi

if [ -z "$pr" ] && [ -z "$branch" ] && [ "${GH_REPO:-}" = "$repo" ]; then
    pr="${PR_NUMBER:-}"
fi
if [ -n "$pr" ] && [[ ! "$pr" =~ ^[1-9][0-9]*$ ]]; then
    echo "lifecycle-labels: expected a positive numeric --pr" >&2
    exit 2
fi
if [ -n "$branch" ] && ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    echo "lifecycle-labels: invalid branch name '$branch'" >&2
    exit 2
fi
if [ -n "$expected_head" ] && [[ ! "$expected_head" =~ ^[0-9a-f]{40}$ ]]; then
    echo "lifecycle-labels: --head must be a 40-character lowercase hex SHA" >&2
    exit 2
fi
if [ -n "$idempotency_key" ] && [[ ! "$idempotency_key" =~ ^[0-9a-f]{64}$ ]]; then
    echo "lifecycle-labels: --idempotency-key must be a 64-character lowercase hex SHA-256" >&2
    exit 2
fi
if [ -n "$idempotency_key" ] && [ -z "$branch" ]; then
    echo "lifecycle-labels: --idempotency-key requires --branch" >&2
    exit 2
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/lifecycle-labels.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

rules_json >"$tmp/rules.json"

# Derive this event's transition plan directly from the canonical rule table.
jq -n --slurpfile rules "$tmp/rules.json" --arg ev "$event" '
    ($rules[0].labels | to_entries | map(select(.value.managed == true))) as $managed
    | ([ $managed[] | select(.value.add_events | index($ev)) | .key ]) as $adds
    | ([ $managed[] | select(.value.remove_events | index($ev)) | .key ]) as $explicit_removes
    | ([ $managed[]
         | select(.key as $k | $adds | index($k))
         | .value.never_coexists_with[] ] | unique) as $coexist_removes
    | (($explicit_removes + $coexist_removes) | unique | map(select((. as $k | $adds | index($k)) | not))) as $removes
    | {
        adds: $adds,
        explicit_removes: $explicit_removes,
        coexist_removes: $coexist_removes,
        removes: $removes,
        adds_claim: (($adds | index("claim:*")) != null),
        removes_claim: (($removes | index("claim:*")) != null),
        direct_adds: [ $adds[] | select(. != "claim:*") ],
        direct_removes: [ $removes[] | select(. != "claim:*") ]
      }
' >"$tmp/plan.json"

adds_claim="$(jq -r '.adds_claim' "$tmp/plan.json")"
removes_claim="$(jq -r '.removes_claim' "$tmp/plan.json")"

checked_head=""
if [ "$event" = "promote" ]; then
    if [ -z "$check_result" ]; then
        echo "lifecycle-labels: promote requires --check-result FILE for the current head (refusing to add 'merge-ready' on issue #$issue)" >&2
        exit 2
    fi
    if [ ! -f "$check_result" ]; then
        echo "lifecycle-labels: promote check-result file not found: $check_result (refusing to add 'merge-ready' on issue #$issue)" >&2
        exit 1
    fi
    if ! jq -e '
        type == "object"
        and .status == "pass"
        and (.condition == "ready" or .condition == "promoted")
        and (.head | type == "string" and test("^[0-9a-f]{40}$"))
        and (.fingerprint | type == "string" and length > 0)
    ' "$check_result" >/dev/null 2>&1; then
        echo "lifecycle-labels: promote requires a passing live-check result (.status == \"pass\", .condition in [\"ready\",\"promoted\"], 40-hex .head, non-empty .fingerprint); refusing 'merge-ready' on issue #$issue" >&2
        exit 1
    fi
    checked_head="$(jq -r '.head' "$check_result")"
    if [ -n "$expected_head" ] && [ "$checked_head" != "$expected_head" ]; then
        echo "lifecycle-labels: promote check-result head '$checked_head' does not match --head '$expected_head' (refusing 'merge-ready' on issue #$issue)" >&2
        exit 1
    fi
fi

if [ "$event" = "claim" ]; then
    if [ -z "$record_file" ] || [ -z "$claim_label" ] || [ -z "$registry_snapshot" ]; then
        echo "lifecycle-labels: 'claim' requires --record-file, --claim-label, and --registry-snapshot for claim-transaction.sh" >&2
        exit 2
    fi
fi

read_issue_snapshot() {
    local dest="$1"
    gh issue view "$issue" --repo "$repo" \
        --json state,labels,assignees,closedByPullRequestsReferences >"$dest" || {
        echo "lifecycle-labels: could not read issue #$issue in $repo" >&2
        return 1
    }
    jq -e '
        (.state | type == "string")
        and (.labels | type == "array")
        and (.assignees | type == "array")
        and all(.closedByPullRequestsReferences[]?;
            (.repository | type) == "object"
            and (.repository.owner.login | type == "string" and length > 0)
            and (.repository.name | type == "string" and length > 0))
    ' "$dest" >/dev/null || {
        echo "lifecycle-labels: malformed issue #$issue JSON response" >&2
        return 1
    }
}

read_pr_snapshot() {
    local number="$1" dest="$2"
    gh pr view "$number" --repo "$repo" \
        --json number,state,isDraft,isCrossRepository,headRefName,headRefOid,labels >"$dest" || {
        echo "lifecycle-labels: could not read pr #$number in $repo" >&2
        return 1
    }
    jq -e '
        (.labels | type == "array")
        and (.state | type == "string")
        and (.isCrossRepository | type == "boolean")
    ' "$dest" >/dev/null || {
        echo "lifecycle-labels: malformed pr #$number JSON response" >&2
        return 1
    }
}

read_issue_snapshot "$tmp/issue.json" || exit 1

jq -r --arg repo "$repo" '
    .closedByPullRequestsReferences[]?
    | select(((.repository.owner.login + "/" + .repository.name) | ascii_downcase) == ($repo | ascii_downcase))
    | .number
' "$tmp/issue.json" >"$tmp/candidates"

if [ -n "$branch" ]; then
    gh pr list --repo "$repo" --state open --head "$branch" --limit 100 \
        --json number,headRefName,isCrossRepository >"$tmp/branch-prs.json" || {
        echo "lifecycle-labels: could not list open PRs for branch '$branch' in $repo" >&2
        exit 1
    }
    jq -e 'type == "array" and length < 100' "$tmp/branch-prs.json" >/dev/null || {
        echo "lifecycle-labels: branch PR listing is invalid or reached the 100-result limit" >&2
        exit 1
    }
    jq -r --arg branch "$branch" '
        .[] | select(.headRefName == $branch and .isCrossRepository == false) | .number
    ' "$tmp/branch-prs.json" >"$tmp/branch-candidates"
    cat "$tmp/branch-candidates" >>"$tmp/candidates"
fi

[ -z "$pr" ] || printf '%s\n' "$pr" >>"$tmp/candidates"
sort -un "$tmp/candidates" >"$tmp/all-prs"

: >"$tmp/open-prs"
: >"$tmp/target-prs"
while IFS= read -r delivery; do
    [ -n "$delivery" ] || continue
    [[ "$delivery" =~ ^[1-9][0-9]*$ ]] || {
        echo "lifecycle-labels: invalid delivery PR number '$delivery'" >&2
        exit 1
    }
    read_pr_snapshot "$delivery" "$tmp/pr-$delivery.json" || exit 1
    pr_cross="$(jq -r '.isCrossRepository' "$tmp/pr-$delivery.json")"
    pr_state="$(jq -r '.state' "$tmp/pr-$delivery.json")"
    if [ -n "$pr" ] && [ "$delivery" = "$pr" ]; then
        if [ "$pr_cross" != "false" ]; then
            echo "lifecycle-labels: explicit pr #$pr is a cross-repository PR and cannot carry same-repo lifecycle labels" >&2
            exit 1
        fi
        if [ "$event" != "close" ] && [ "$event" != "review-clear" ] && [ "$pr_state" != "OPEN" ]; then
            echo "lifecycle-labels: explicit pr #$pr is '$pr_state', expected OPEN for '$event'" >&2
            exit 1
        fi
    fi
    if [ "$pr_cross" = "false" ] && [ "$pr_state" = "OPEN" ]; then
        printf '%s\n' "$delivery" >>"$tmp/open-prs"
        printf '%s\n' "$delivery" >>"$tmp/target-prs"
    elif [ "$event" = "close" ] && [ "$pr_cross" = "false" ]; then
        if [ -n "$pr" ] && [ "$delivery" = "$pr" ]; then
            printf '%s\n' "$delivery" >>"$tmp/target-prs"
        elif [ -z "$pr" ] && jq -e '
            any(.labels[]; (.name | ascii_downcase) as $n
                | $n == "parked" or $n == "merge-ready" or $n == "needs-review" or $n == "blocked")
        ' "$tmp/pr-$delivery.json" >/dev/null; then
            printf '%s\n' "$delivery" >>"$tmp/target-prs"
        fi
    fi
done <"$tmp/all-prs"

open_pr_count="$(wc -l <"$tmp/open-prs" | tr -d '[:space:]')"
issue_state="$(jq -r '.state' "$tmp/issue.json")"

has_live_claim_marker() {
    local snapshot="$1"
    if [ "$allow_label_less" -eq 1 ]; then
        jq -e '(.assignees | length) > 0 or any(.labels[]; (.name | startswith("claim:") or startswith("agent:")))' \
            "$snapshot" >/dev/null
    else
        jq -e 'any(.labels[]; (.name | startswith("claim:") or startswith("agent:")))' \
            "$snapshot" >/dev/null
    fi
}

# Validate all preconditions before making any GitHub writes.
case "$event" in
claim)
    [ "$issue_state" = "OPEN" ] || {
        echo "lifecycle-labels: cannot run 'claim' on non-OPEN issue #$issue (state=$issue_state)" >&2
        exit 1
    }
    while IFS= read -r delivery; do
        [ -n "$delivery" ] || continue
        if [ "$(jq -r '.isDraft' "$tmp/pr-$delivery.json")" != "true" ]; then
            echo "lifecycle-labels: 'claim' requires delivery PRs to be draft; pr #$delivery is non-draft" >&2
            exit 1
        fi
    done <"$tmp/open-prs"
    ;;
review-entry)
    [ "$open_pr_count" -ge 1 ] || {
        echo "lifecycle-labels: 'review-entry' requires at least one discoverable open delivery PR for issue #$issue (cannot apply 'needs-review')" >&2
        exit 1
    }
    ;;
fix-round)
    [ "$issue_state" = "OPEN" ] || {
        echo "lifecycle-labels: cannot run 'fix-round' on non-OPEN issue #$issue (state=$issue_state)" >&2
        exit 1
    }
    [ "$open_pr_count" -ge 1 ] || {
        echo "lifecycle-labels: 'fix-round' requires at least one discoverable open delivery PR for issue #$issue" >&2
        exit 1
    }
    while IFS= read -r delivery; do
        [ -n "$delivery" ] || continue
        if [ "$(jq -r '.isDraft' "$tmp/pr-$delivery.json")" != "true" ]; then
            echo "lifecycle-labels: 'fix-round' requires draft delivery PR; pr #$delivery has isDraft != true" >&2
            exit 1
        fi
    done <"$tmp/open-prs"
    if [ -z "$record_file" ] && ! has_live_claim_marker "$tmp/issue.json"; then
        echo "lifecycle-labels: issue #$issue has no live 'claim:*' label and no --record-file was supplied to restore it" >&2
        exit 1
    fi
    ;;
park)
    [ "$open_pr_count" -ge 1 ] || {
        echo "lifecycle-labels: 'park' requires at least one discoverable open delivery PR for issue #$issue (cannot apply 'parked')" >&2
        exit 1
    }
    while IFS= read -r delivery; do
        [ -n "$delivery" ] || continue
        if [ "$(jq -r '.isDraft' "$tmp/pr-$delivery.json")" != "true" ]; then
            echo "lifecycle-labels: 'park' requires draft delivery PR; pr #$delivery is not draft (cannot apply 'parked')" >&2
            exit 1
        fi
    done <"$tmp/open-prs"
    ;;
promote)
    [ "$open_pr_count" -ge 1 ] || {
        echo "lifecycle-labels: 'promote' requires at least one discoverable open delivery PR for issue #$issue (cannot apply 'merge-ready')" >&2
        exit 1
    }
    while IFS= read -r delivery; do
        [ -n "$delivery" ] || continue
        if [ "$(jq -r '.isDraft' "$tmp/pr-$delivery.json")" != "false" ]; then
            echo "lifecycle-labels: 'promote' requires a non-draft delivery PR; pr #$delivery is still draft (cannot apply 'merge-ready')" >&2
            exit 1
        fi
        live_pr_head="$(jq -r '.headRefOid // empty' "$tmp/pr-$delivery.json")"
        if [ "$live_pr_head" != "$checked_head" ]; then
            echo "lifecycle-labels: 'promote' check-result head '$checked_head' does not match live head '$live_pr_head' on pr #$delivery (cannot apply 'merge-ready')" >&2
            exit 1
        fi
    done <"$tmp/open-prs"
    ;;
block)
    while IFS= read -r delivery; do
        [ -n "$delivery" ] || continue
        if [ "$(jq -r '.isDraft' "$tmp/pr-$delivery.json")" != "true" ]; then
            echo "lifecycle-labels: 'block' requires delivery PRs to stay draft; pr #$delivery is non-draft (cannot apply 'blocked')" >&2
            exit 1
        fi
    done <"$tmp/open-prs"
    ;;
resume)
    [ "$issue_state" = "OPEN" ] || {
        echo "lifecycle-labels: cannot run 'resume' on non-OPEN issue #$issue (state=$issue_state)" >&2
        exit 1
    }
    while IFS= read -r delivery; do
        [ -n "$delivery" ] || continue
        if [ "$(jq -r '.isDraft' "$tmp/pr-$delivery.json")" != "true" ]; then
            echo "lifecycle-labels: 'resume' requires delivery PRs to be draft; pr #$delivery is non-draft" >&2
            exit 1
        fi
    done <"$tmp/open-prs"
    if [ -z "$record_file" ] && ! has_live_claim_marker "$tmp/issue.json"; then
        echo "lifecycle-labels: issue #$issue has no live 'claim:*' label and no --record-file was supplied to restore it" >&2
        exit 1
    fi
    ;;
esac

ensure_label_provisioned() {
    local target_kind="$1" target_number="$2" wanted="$3"
    if [ ! -f "$tmp/repo-labels.json" ]; then
        if ! gh label list --repo "$repo" --limit 1000 --json name >"$tmp/repo-labels.json" ||
            ! jq -e 'type == "array"' "$tmp/repo-labels.json" >/dev/null 2>&1; then
            echo "lifecycle-labels: could not verify repository label provisioning for '$wanted' on $target_kind #$target_number" >&2
            return 1
        fi
    fi
    if ! jq -e --arg l "$wanted" 'any(.[]; (.name | ascii_downcase) == ($l | ascii_downcase))' \
        "$tmp/repo-labels.json" >/dev/null; then
        echo "lifecycle-labels: label '$wanted' is not provisioned in $repo (cannot apply to $target_kind #$target_number)" >&2
        return 1
    fi
}

add_managed_label() {
    local kind="$1" number="$2" snapshot="$3" add_label="$4"
    case "$add_label" in
    parked | merge-ready | needs-review | blocked) ;;
    *)
        echo "lifecycle-labels: internal error: unsupported add label '$add_label'" >&2
        exit 2
        ;;
    esac
    if jq -e --arg l "$add_label" 'any(.labels[]; (.name | ascii_downcase) == ($l | ascii_downcase))' \
        "$snapshot" >/dev/null; then
        return 0
    fi
    ensure_label_provisioned "$kind" "$number" "$add_label" || exit 1
    if ! gh "$kind" edit "$number" --repo "$repo" --add-label "$add_label" >/dev/null; then
        echo "lifecycle-labels: failed to apply label '$add_label' on $kind #$number" >&2
        exit 1
    fi
}

remove_managed_label() {
    local kind="$1" number="$2" snapshot="$3" wanted="$4" remove_label
    case "$wanted" in
    parked | merge-ready | needs-review | blocked) ;;
    *)
        echo "lifecycle-labels: internal error: unsupported remove label '$wanted'" >&2
        exit 2
        ;;
    esac
    remove_label="$(jq -r --arg l "$wanted" '
        [ .labels[] | select((.name | ascii_downcase) == ($l | ascii_downcase)) | .name ][0] // empty
    ' "$snapshot")"
    [ -n "$remove_label" ] || return 0
    case "$remove_label" in
    parked | merge-ready | needs-review | blocked) ;;
    *)
        remove_label="$wanted"
        ;;
    esac
    if ! gh "$kind" edit "$number" --repo "$repo" --remove-label "$remove_label" >/dev/null; then
        echo "lifecycle-labels: failed to remove label '$wanted' on $kind #$number" >&2
        exit 1
    fi
}

run_claim_add() {
    local -a tx_args
    [ -n "$record_file" ] || return 0
    [ -x "$claim_transaction_sh" ] || {
        echo "lifecycle-labels: claim transaction helper is unavailable at $claim_transaction_sh (cannot update 'claim:*' on issue #$issue)" >&2
        exit 1
    }
    [ -n "$claim_label" ] && [ -n "$registry_snapshot" ] || {
        echo "lifecycle-labels: --record-file requires --claim-label and --registry-snapshot" >&2
        exit 2
    }
    tx_args=(
        --repo "$repo"
        --issue "$issue"
        --record-file "$record_file"
        --claim-label "$claim_label"
        --registry-snapshot "$registry_snapshot"
    )
    [ -z "$model_label" ] || tx_args+=(--model-label "$model_label")
    [ -z "$family" ] || tx_args+=(--family "$family")
    [ -z "$runtime_environment" ] || tx_args+=(--runtime-environment "$runtime_environment")
    [ "$allow_label_less" -eq 0 ] || tx_args+=(--allow-label-less)
    if [ "$approve_review_pullback" -eq 1 ] || [ "$event" = "fix-round" ]; then
        tx_args+=(--approve-review-pullback)
    fi
    if ! "$claim_transaction_sh" "${tx_args[@]}"; then
        echo "lifecycle-labels: claim-transaction.sh failed for 'claim:*' on issue #$issue" >&2
        exit 1
    fi
}

run_claim_release() {
    local eff_reason eff_key rc err_text surviving_claim
    local -a rel_args
    [ -x "$release_claim_sh" ] || {
        echo "lifecycle-labels: release-claim helper is unavailable at $release_claim_sh (cannot remove 'claim:*' on issue #$issue)" >&2
        exit 1
    }
    eff_reason="$release_reason"
    if [ -z "$eff_reason" ]; then
        case "$event" in
        park) eff_reason="handoff check passed (parked in merge queue)" ;;
        promote) eff_reason="handoff check passed (promoted to merge-ready)" ;;
        close) eff_reason="lifecycle terminal close" ;;
        *) eff_reason="lifecycle $event" ;;
        esac
    fi
    rel_args=(
        --repo "$repo"
        --issue "$issue"
    )
    if [ -n "$branch" ]; then
        eff_key="$idempotency_key"
        if [ -z "$eff_key" ]; then
            eff_key="$(sha256_hex "lifecycle-labels:$repo:$issue:$branch")"
        fi
        case "$eff_reason" in
        *"key=$eff_key"*) ;;
        *) eff_reason="$eff_reason; key=$eff_key" ;;
        esac
        rel_args+=(
            --reason "$eff_reason"
            --branch "$branch"
            --idempotency-key "$eff_key"
        )
    else
        rel_args+=(--reason "$eff_reason")
    fi
    [ -z "$not_after" ] || rel_args+=(--not-after "$not_after")
    [ "$require_closed" -eq 0 ] || rel_args+=(--require-closed)
    rc=0
    "$release_claim_sh" "${rel_args[@]}" >"$tmp/release.out" 2>"$tmp/release.err" || rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    err_text="$(cat "$tmp/release.err")"
    if [ "$rc" -eq 3 ]; then
        case "$err_text" in
        *"has no trusted claim comment — nothing to release"*)
            read_issue_snapshot "$tmp/issue-post-release.json" || exit 1
            surviving_claim="$(jq -r '
                [ .labels[] | select(.name | (startswith("claim:") or startswith("agent:"))) | .name ][0] // empty
            ' "$tmp/issue-post-release.json")"
            if [ -z "$surviving_claim" ]; then
                return 0
            fi
            ;;
        *"already superseded by a 'Claim released —' comment"*)
            if [ -z "$branch" ]; then
                read_issue_snapshot "$tmp/issue-post-release.json" || exit 1
                surviving_claim="$(jq -r '
                    [ .labels[] | select(.name | (startswith("claim:") or startswith("agent:"))) | .name ][0] // empty
                ' "$tmp/issue-post-release.json")"
                if [ -z "$surviving_claim" ] &&
                    [ "$(jq -r '.assignees | length' "$tmp/issue-post-release.json")" -eq 0 ]; then
                    return 0
                fi
            fi
            ;;
        esac
    fi
    [ -z "$err_text" ] || printf '%s\n' "$err_text" >&2
    echo "lifecycle-labels: release-claim.sh failed (exit $rc) while removing 'claim:*' on issue #$issue" >&2
    exit 1
}

run_clear_needs_review() {
    local cnr_out
    local -a cnr_args
    [ -x "$clear_needs_review_sh" ] || {
        echo "lifecycle-labels: clear-needs-review helper is unavailable at $clear_needs_review_sh (cannot remove 'needs-review' on issue #$issue)" >&2
        exit 1
    }
    cnr_args=(--repo "$repo" --issue "$issue")
    [ -z "$pr" ] || cnr_args+=(--pr "$pr")
    [ -z "$branch" ] || cnr_args+=(--branch "$branch")
    if ! cnr_out="$("$clear_needs_review_sh" "${cnr_args[@]}")"; then
        echo "lifecycle-labels: clear-needs-review.sh failed while removing 'needs-review' on issue #$issue" >&2
        exit 1
    fi
    printf '%s\n' "$cnr_out" >"$tmp/cnr.out"
}

# For close with an explicit --pr while another open same-repo sibling delivery
# PR remains open, scope state-label cleanup to that PR (and retain issue state
# owned by the still-open sibling).
close_has_open_sibling=0
if [ "$event" = "close" ] && [ -n "$pr" ]; then
    while IFS= read -r open_pr; do
        [ -n "$open_pr" ] || continue
        if [ "$open_pr" != "$pr" ]; then
            close_has_open_sibling=1
        fi
    done <"$tmp/open-prs"
fi

apply_object_removes() {
    local kind="$1" number="$2" snapshot="$3" skip_needs_review="$4" lbl
    while IFS= read -r lbl; do
        [ -n "$lbl" ] || continue
        if [ "$lbl" = "needs-review" ] && [ "$skip_needs_review" -eq 1 ]; then
            continue
        fi
        remove_managed_label "$kind" "$number" "$snapshot" "$lbl"
    done < <(jq -r '.direct_removes[]' "$tmp/plan.json")
}

apply_object_adds() {
    local kind="$1" number="$2" snapshot="$3" lbl
    while IFS= read -r lbl; do
        [ -n "$lbl" ] || continue
        add_managed_label "$kind" "$number" "$snapshot" "$lbl"
    done < <(jq -r '.direct_adds[]' "$tmp/plan.json")
}

# Step 0: Verify repository label provisioning up front for every managed add
# so an unprovisioned label never releases a claim or partially mutates objects.
while IFS= read -r planned_add; do
    [ -n "$planned_add" ] || continue
    ensure_label_provisioned issue "$issue" "$planned_add" || exit 1
done < <(jq -r '.direct_adds[]' "$tmp/plan.json")

# Step 1: Execute claim release first when required (park, promote, close) so
# `parked` and `merge-ready` never coexist with a live `claim:*` marker.
if [ "$removes_claim" = "true" ] && [ "$close_has_open_sibling" -eq 0 ]; then
    run_claim_release
    read_issue_snapshot "$tmp/issue.json" || exit 1
    surviving_after_release="$(jq -r '
        [ .labels[] | select(.name | (startswith("claim:") or startswith("agent:"))) | .name ][0] // empty
    ' "$tmp/issue.json")"
    if [ -n "$surviving_after_release" ]; then
        echo "lifecycle-labels: write did not stick: label '$surviving_after_release' still present on issue #$issue after claim release" >&2
        exit 1
    fi
fi

# Step 2: Execute delegated needs-review removal for review-clear, fix-round,
# and sibling-scoped close.
needs_review_retained=0
delegated_needs_review=0
case "$event" in
review-clear)
    delegated_needs_review=1
    run_clear_needs_review
    if grep -Fxq "NEEDS-REVIEW-RETAINED" "$tmp/cnr.out"; then
        needs_review_retained=1
        printf '%s\n' "NEEDS-REVIEW-RETAINED"
    fi
    ;;
fix-round)
    delegated_needs_review=1
    # Remove parked/merge-ready before restoring claim and pulling back review.
    apply_object_removes issue "$issue" "$tmp/issue.json" 1
    while IFS= read -r delivery; do
        [ -n "$delivery" ] || continue
        apply_object_removes pr "$delivery" "$tmp/pr-$delivery.json" 1
    done <"$tmp/target-prs"
    run_claim_add
    run_clear_needs_review
    if grep -Fxq "NEEDS-REVIEW-RETAINED" "$tmp/cnr.out"; then
        echo "lifecycle-labels: NEEDS-REVIEW-RETAINED on issue #$issue; another open delivery PR still carries 'needs-review', refusing fix-round" >&2
        exit 1
    fi
    ;;
close)
    if [ "$close_has_open_sibling" -eq 1 ]; then
        delegated_needs_review=1
        run_clear_needs_review
        if grep -Fxq "NEEDS-REVIEW-RETAINED" "$tmp/cnr.out"; then
            needs_review_retained=1
            printf '%s\n' "NEEDS-REVIEW-RETAINED"
        fi
    fi
    ;;
esac

# Step 3: Remove conflicting / target lifecycle state labels across issue and
# target delivery PRs, then restore/start claim if applicable, then apply adds.
if [ "$event" != "fix-round" ]; then
    if [ "$close_has_open_sibling" -eq 0 ]; then
        apply_object_removes issue "$issue" "$tmp/issue.json" "$delegated_needs_review"
    fi
    while IFS= read -r delivery; do
        [ -n "$delivery" ] || continue
        if [ "$close_has_open_sibling" -eq 1 ] && [ "$delivery" != "$pr" ]; then
            continue
        fi
        apply_object_removes pr "$delivery" "$tmp/pr-$delivery.json" "$delegated_needs_review"
    done <"$tmp/target-prs"

    if [ "$adds_claim" = "true" ]; then
        run_claim_add
    fi

    if [ "$close_has_open_sibling" -eq 0 ]; then
        apply_object_adds issue "$issue" "$tmp/issue.json"
    fi
    while IFS= read -r delivery; do
        [ -n "$delivery" ] || continue
        apply_object_adds pr "$delivery" "$tmp/pr-$delivery.json"
    done <"$tmp/target-prs"
fi

# Step 4: Fresh re-read verification across the issue and every target PR.
verify_object_labels() {
    local kind="$1" number="$2" snapshot="$3" allow_retained_issue_nr="$4" lbl
    while IFS= read -r lbl; do
        [ -n "$lbl" ] || continue
        if ! jq -e --arg l "$lbl" 'any(.labels[]; (.name | ascii_downcase) == ($l | ascii_downcase))' \
            "$snapshot" >/dev/null; then
            echo "lifecycle-labels: write did not stick: label '$lbl' missing on $kind #$number after re-read" >&2
            exit 1
        fi
    done < <(jq -r '.direct_adds[]' "$tmp/plan.json")

    while IFS= read -r lbl; do
        [ -n "$lbl" ] || continue
        if [ "$lbl" = "needs-review" ] && [ "$allow_retained_issue_nr" -eq 1 ]; then
            continue
        fi
        if jq -e --arg l "$lbl" 'any(.labels[]; (.name | ascii_downcase) == ($l | ascii_downcase))' \
            "$snapshot" >/dev/null; then
            echo "lifecycle-labels: write did not stick: label '$lbl' still present on $kind #$number after re-read" >&2
            exit 1
        fi
    done < <(jq -r '.direct_removes[]' "$tmp/plan.json")
}

read_issue_snapshot "$tmp/issue-after.json" || exit 1
if [ "$close_has_open_sibling" -eq 0 ]; then
    verify_object_labels issue "$issue" "$tmp/issue-after.json" "$needs_review_retained"
    if [ "$removes_claim" = "true" ]; then
        surviving_claim="$(jq -r '
            [ .labels[] | select(.name | (startswith("claim:") or startswith("agent:"))) | .name ][0] // empty
        ' "$tmp/issue-after.json")"
        if [ -n "$surviving_claim" ]; then
            echo "lifecycle-labels: write did not stick: label '$surviving_claim' still present on issue #$issue after re-read" >&2
            exit 1
        fi
    fi
    if [ "$adds_claim" = "true" ] && ! has_live_claim_marker "$tmp/issue-after.json"; then
        echo "lifecycle-labels: write did not stick: label '${claim_label:-claim:*}' missing on issue #$issue after re-read" >&2
        exit 1
    fi
fi

# Determine which PRs must be verified on re-read:
# - For review-clear, match clear-needs-review.sh's exact selection scope:
#   explicit --pr clears only that PR; --branch (without --pr) clears only open
#   same-repo PRs on --branch while preserving closing-linked siblings on other
#   branches; neither clears all target PRs.
while IFS= read -r delivery; do
    [ -n "$delivery" ] || continue
    if [ "$close_has_open_sibling" -eq 1 ] && [ "$delivery" != "$pr" ]; then
        continue
    fi
    if [ "$event" = "review-clear" ]; then
        if [ -n "$pr" ] && [ "$delivery" != "$pr" ]; then
            continue
        elif [ -z "$pr" ] && [ -n "$branch" ] && ! grep -Fxq "$delivery" "$tmp/branch-candidates"; then
            continue
        fi
    fi
    read_pr_snapshot "$delivery" "$tmp/pr-after-$delivery.json" || exit 1
    verify_object_labels pr "$delivery" "$tmp/pr-after-$delivery.json" 0
done <"$tmp/target-prs"
