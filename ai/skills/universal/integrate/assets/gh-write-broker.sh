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
# for exactly "the cloud finder's trigger; thread replies of given text" —
# `request-review` is that same trigger write for a finder GitHub triggers
# through a review REQUEST rather than a comment, and it carries the identical
# narrowing: the reviewer it names comes from the registry, so the agent
# chooses which registered finder to trigger and never what to post or whom to
# ask. Before #796 that table read "the Codex trigger comment"; a second
# comment-triggered finder and a request-triggered one are the same authority
# exercised for a different registered finder, not a wider one —
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
#   gh-write-broker.sh trigger --repo OWNER/REPO --pr N [--finder SLUG]
#       Posts a cloud finder's review-trigger comment to the PR's top-level
#       conversation and prints the created comment's {"id": N} — the one
#       trigger the cycle helper's reserve/attach state machine expects. The
#       body is STILL not a parameter. With no --finder it is the literal
#       "@codex review", exactly as before; with one, it is that finder's own
#       `collection.trigger.body` READ FROM agent-registry.json (#796), so the
#       set of postable bodies stays closed and repository-controlled rather
#       than becoming caller-supplied text. A finder whose trigger mechanism
#       is not review-comment is refused here — it has no comment to post.
#   gh-write-broker.sh request-review --repo OWNER/REPO --pr N --finder SLUG
#       Requests a review from that finder's registry-declared
#       `collection.trigger.reviewer_login`, for a finder whose trigger
#       mechanism is requested-reviewer (Copilot code review). The reviewer is
#       likewise read from the registry, never from a flag.
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

usage() {
    cat >&2 <<'EOF'
Usage:
  gh-write-broker.sh trigger --repo OWNER/REPO --pr N [--finder SLUG] [--registry FILE]
  gh-write-broker.sh request-review --repo OWNER/REPO --pr N --finder SLUG [--registry FILE]
  gh-write-broker.sh reply --repo OWNER/REPO --pr N --comment-id ID --body-file FILE

trigger posts a registry-declared review-trigger body (the hardcoded
"@codex review" with no --finder); request-review requests a
registry-declared reviewer login; reply posts a FILE's exact byte content to
one specific, non-negotiable endpoint. No subcommand accepts a caller-supplied
body or reviewer on the command line, or an arbitrary endpoint.
EOF
    exit 2
}

refuse() {
    printf 'gh-write-broker: refused: %s\n' "$*" >&2
    exit 2
}

command -v gh >/dev/null 2>&1 || refuse "gh is required"

valid_repo() {
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
}

valid_uint() {
    printf '%s' "$1" | grep -Eq '^[1-9][0-9]*$'
}

[ "$#" -gt 0 ] || usage
subcommand=$1
shift

repo=
pr=
comment_id=
body_file=
finder=
registry=

while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --pr | --comment-id | --body-file | --finder | --registry)
        [ "$#" -ge 2 ] || usage
        case "$1" in
        --repo) repo=$2 ;;
        --pr) pr=$2 ;;
        --comment-id) comment_id=$2 ;;
        --body-file) body_file=$2 ;;
        --finder) finder=$2 ;;
        --registry) registry=$2 ;;
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

# Reads ONE field of ONE finder's registry entry. The registry is repository
# content, not a caller argument: what a --finder can select is therefore
# bounded by what the repo has committed, which is what keeps this broker a
# broker. A missing or unreadable registry is a refusal, never a fallback to
# the Codex default — silently posting the wrong trigger would start a cycle
# for a finder nobody asked for.
finder_field() {
    local field=$1 value
    [ -n "$finder" ] || refuse "internal: finder_field called with no --finder"
    printf '%s' "$finder" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' ||
        refuse "invalid finder slug: $finder"
    command -v jq >/dev/null 2>&1 || refuse "jq is required to resolve --finder"
    [ -n "$registry" ] || registry="$(git rev-parse --show-toplevel 2>/dev/null)/agent-registry.json"
    [ -f "$registry" ] || refuse "no registry at $registry — cannot resolve finder $finder"
    value="$(jq -r --arg slug "$finder" --arg field "$field" '
          [.finders[]? | select(.slug == $slug)] as $entries |
          if ($entries | length) != 1 then "" else
            ($entries[0].collection.trigger[$field] // "")
          end' "$registry")" ||
        refuse "cannot read $registry"
    printf '%s' "$value"
}

require_trigger_mechanism() {
    local mechanism
    mechanism="$(finder_field mechanism)"
    [ -n "$mechanism" ] ||
        refuse "finder $finder is not a registered PR-side finder with a trigger in $registry"
    [ "$mechanism" = "$1" ] ||
        refuse "finder $finder is triggered by $mechanism, not $1"
}

case "$subcommand" in
trigger)
    [ -z "$comment_id" ] && [ -z "$body_file" ] ||
        refuse "trigger takes no --comment-id or --body-file — its body is registry-declared"
    if [ -z "$finder" ]; then
        exec gh api "repos/$repo/issues/$pr/comments" -f body='@codex review' --jq .id
    fi
    require_trigger_mechanism review-comment
    trigger_body="$(finder_field body)"
    [ -n "$trigger_body" ] ||
        refuse "finder $finder declares a review-comment trigger with no body"
    exec gh api "repos/$repo/issues/$pr/comments" -f body="$trigger_body" --jq .id
    ;;
request-review)
    [ -n "$finder" ] || usage
    [ -z "$comment_id" ] && [ -z "$body_file" ] ||
        refuse "request-review takes no --comment-id or --body-file"
    require_trigger_mechanism requested-reviewer
    reviewer="$(finder_field reviewer_login)"
    [ -n "$reviewer" ] ||
        refuse "finder $finder declares a requested-reviewer trigger with no reviewer_login"
    exec gh api "repos/$repo/pulls/$pr/requested_reviewers" \
        -f "reviewers[]=$reviewer" --jq '.number'
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
