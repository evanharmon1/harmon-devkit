#!/usr/bin/env bash
# gh-write-broker.sh — the integrator's only permitted GitHub writes, each
# validated to post EXACTLY one thing, nothing else configurable.
#
# specs/dev-flow-v2.md's role-write contract: "every permitted external write
# goes through a broker script that validates its one action" — this is that
# broker for the writes ai/agents/integrator.md §4 and §6 make: the
# `@codex review` trigger and an inline-thread reply. Unlike gh-ro.sh (a
# structurally read-only front door that vets and forwards a caller-chosen
# endpoint), this wrapper does not forward a caller-chosen body or endpoint
# shape at all — each subcommand has its own fixed endpoint template and its
# own narrow body source, so there is no argument that could turn "post this
# reply" into "post anything else."
#
# Deliberately NOT a subcommand here: posting a new top-level PR conversation
# comment. specs/dev-flow-v2.md's role-write table authorizes the integrator
# for exactly "the Codex trigger comment; thread replies of given text" —
# a top-level comment is neither; disposing a badged finding with no inline
# thread is the orchestrating skill's own `settle` write (ai/skills/
# universal/integrate/SKILL.md §2), never delegated to this agent (review
# round 2 gauntlet challenge, harmon-devkit#639: an earlier revision of this
# broker carried a `top-level` subcommand that exceeded that boundary).
#
# This script does not, by itself, restrict which tools the dispatching
# harness lets the integrator invoke (ai/agents/integrator.md carries no
# `tools:`/`allowed-tools:` frontmatter — see its own note on why, and on the
# open question that leaves for a harness that cannot enforce this at
# dispatch time). What it does mean: an integrator that follows its own
# instructions, rather than calling `gh api` directly, is mechanically
# narrower than the raw prefix — no method choice, no arbitrary endpoint, no
# arbitrary body beyond what each subcommand below accepts.
#
# Usage:
#   gh-write-broker.sh trigger --repo OWNER/REPO --pr N
#       Posts the literal, hardcoded comment body "@codex review" to the PR's
#       top-level conversation and prints the created comment's {"id": N} —
#       the one trigger the Codex-cycle helper's reserve/attach state machine
#       expects. The body is not a parameter: there is no flag that changes
#       what gets posted here.
#   gh-write-broker.sh trigger --finder SLUG --repo OWNER/REPO --pr N
#       Posts the finder's trigger body (from the trusted registry at the
#       PR's merge-base commit) to the PR. The body is resolved from the
#       registry, never from a caller flag — constraint C1.
#   gh-write-broker.sh request-review --finder SLUG --repo OWNER/REPO --pr N
#       Requests the finder's reviewer login (from the trusted registry) as
#       a PR reviewer. For requested-reviewer finders (e.g. copilot-cloud).
#   gh-write-broker.sh reply --repo OWNER/REPO --pr N --comment-id ID --body-file FILE
#       Posts FILE's exact byte content as a reply within that inline review
#       comment's thread.
#
# `reply` takes its body from a FILE, never a flag value or
# stdin freeform text — matching ai/agents/integrator.md §6's own file-based
# posting (never a heredoc: contributor-controlled review text can contain
# any line, including one that would terminate a heredoc early and hand the
# remainder to the shell). The file must exist and be non-empty; this script
# never synthesizes or edits its content.
#
# Exit codes: 2 for a refusal or usage error; otherwise `gh api`'s own.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat >&2 <<'EOF'
Usage:
  gh-write-broker.sh trigger --repo OWNER/REPO --pr N
  gh-write-broker.sh trigger --finder SLUG --repo OWNER/REPO --pr N
  gh-write-broker.sh request-review --finder SLUG --repo OWNER/REPO --pr N
  gh-write-broker.sh reply --repo OWNER/REPO --pr N --comment-id ID --body-file FILE

trigger (no --finder) posts the hardcoded "@codex review" body.
trigger --finder posts the finder's trigger body from the trusted registry.
request-review --finder requests the finder's reviewer from the trusted registry.
reply posts a FILE's exact byte content to one inline thread.
No subcommand accepts a caller-supplied body on the command line.
EOF
    exit 2
}

refuse() {
    printf 'gh-write-broker: refused: %s\n' "$*" >&2
    exit 2
}

command -v gh >/dev/null 2>&1 || refuse "gh is required"
command -v jq >/dev/null 2>&1 || refuse "jq is required"

valid_repo() {
    grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' <<<"$1"
}

valid_uint() {
    grep -Eq '^[1-9][0-9]*$' <<<"$1"
}

valid_slug() {
    grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' <<<"$1"
}

[ "$#" -gt 0 ] || usage
subcommand=$1
shift

repo=
pr=
comment_id=
body_file=
finder=

while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --pr | --comment-id | --body-file | --finder)
        [ "$#" -ge 2 ] || usage
        case "$1" in
        --repo) repo=$2 ;;
        --pr) pr=$2 ;;
        --comment-id) comment_id=$2 ;;
        --body-file) body_file=$2 ;;
        --finder) finder=$2 ;;
        esac
        shift 2
        ;;
    *) usage ;;
    esac
done

[ -n "$repo" ] || usage
[ -n "$pr" ] || usage
valid_repo "$repo" || refuse "invalid repository: $repo"
valid_uint "$pr" || refuse "invalid PR number: $pr"

resolve_profile() {
    local slug=$1
    valid_slug "$slug" || refuse "invalid finder slug: $slug"

    # shellcheck source=trusted-registry.sh
    . "$SCRIPT_DIR/trusted-registry.sh"

    local tmpdir
    tmpdir=$(mktemp -d -t broker-profile-XXXXXX)
    trap 'rm -rf "$tmpdir"' RETURN

    resolve_trusted_registry "$repo" "$pr" "$tmpdir/registry.json" ||
        refuse "cannot resolve trusted registry for $repo#$pr"
    resolve_finder_profile "$tmpdir/registry.json" "$slug" "$tmpdir/profile.json" ||
        refuse "cannot resolve finder profile for slug '$slug'"

    cat "$tmpdir/profile.json"
}

case "$subcommand" in
trigger)
    [ -z "$comment_id" ] && [ -z "$body_file" ] ||
        refuse "trigger takes no --comment-id or --body-file — its body is hardcoded"
    if [ -z "$finder" ]; then
        exec gh api "repos/$repo/issues/$pr/comments" -f body='@codex review' --jq .id
    fi
    profile=$(resolve_profile "$finder")
    mechanism=$(printf '%s' "$profile" | jq -r '.collection.trigger.mechanism')
    [ "$mechanism" = "review-comment" ] ||
        refuse "finder '$finder' uses mechanism '$mechanism', not review-comment — use request-review instead"
    trigger_body=$(printf '%s' "$profile" | jq -r '.collection.trigger.body')
    [ -n "$trigger_body" ] ||
        refuse "finder '$finder' has no trigger body in the registry"
    exec gh api "repos/$repo/issues/$pr/comments" -f body="$trigger_body" --jq .id
    ;;
request-review)
    [ -n "$finder" ] || refuse "request-review requires --finder"
    [ -z "$comment_id" ] && [ -z "$body_file" ] ||
        refuse "request-review takes no --comment-id or --body-file"
    profile=$(resolve_profile "$finder")
    mechanism=$(printf '%s' "$profile" | jq -r '.collection.trigger.mechanism')
    [ "$mechanism" = "requested-reviewer" ] ||
        refuse "finder '$finder' uses mechanism '$mechanism', not requested-reviewer — use trigger instead"
    reviewer_login=$(printf '%s' "$profile" | jq -r '.collection.trigger.reviewer_login')
    [ -n "$reviewer_login" ] ||
        refuse "finder '$finder' has no reviewer_login in the registry"
    exec gh api "repos/$repo/pulls/$pr/requested_reviewers" \
        -f "reviewers[]=$reviewer_login" --jq '.users[].login'
    ;;
reply)
    [ -n "$comment_id" ] || usage
    valid_uint "$comment_id" || refuse "invalid comment ID: $comment_id"
    [ -n "$body_file" ] || usage
    [ -f "$body_file" ] || refuse "--body-file $body_file does not exist"
    [ -s "$body_file" ] || refuse "--body-file $body_file is empty"
    exec gh api "repos/$repo/pulls/$pr/comments/$comment_id/replies" -F body=@"$body_file"
    ;;
*)
    usage
    ;;
esac
