#!/usr/bin/env bash
# gh-write-broker.sh — the integrator's only permitted GitHub writes, each
# validated to post EXACTLY one thing, nothing else configurable.
#
# specs/dev-flow-v2.md's role-write contract: "every permitted external write
# goes through a broker script that validates its one action" — this is that
# broker for the writes ai/agents/integrator.md §4 and §6 make: the
# `@codex review` trigger, an inline-thread reply, and a top-level PR
# conversation comment. Unlike gh-ro.sh (a structurally read-only front door
# that vets and forwards a caller-chosen endpoint), this wrapper does not
# forward a caller-chosen body or endpoint shape at all — each subcommand has
# its own fixed endpoint template and its own narrow body source, so there is
# no argument that could turn "post this reply" into "post anything else."
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
#   gh-write-broker.sh reply --repo OWNER/REPO --pr N --comment-id ID --body-file FILE
#       Posts FILE's exact byte content as a reply within that inline review
#       comment's thread.
#   gh-write-broker.sh top-level --repo OWNER/REPO --pr N --body-file FILE
#       Posts FILE's exact byte content as a new top-level PR conversation
#       comment.
#
# `reply` and `top-level` take their body from a FILE, never a flag value or
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
  gh-write-broker.sh trigger --repo OWNER/REPO --pr N
  gh-write-broker.sh reply --repo OWNER/REPO --pr N --comment-id ID --body-file FILE
  gh-write-broker.sh top-level --repo OWNER/REPO --pr N --body-file FILE

trigger posts the hardcoded "@codex review" body; reply and top-level post a
FILE's exact byte content to one specific, non-negotiable endpoint each. No
subcommand accepts a caller-supplied body on the command line or an
arbitrary endpoint.
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

while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --pr | --comment-id | --body-file)
        [ "$#" -ge 2 ] || usage
        case "$1" in
        --repo) repo=$2 ;;
        --pr) pr=$2 ;;
        --comment-id) comment_id=$2 ;;
        --body-file) body_file=$2 ;;
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

case "$subcommand" in
trigger)
    [ -z "$comment_id" ] && [ -z "$body_file" ] ||
        refuse "trigger takes no --comment-id or --body-file — its body is hardcoded"
    exec gh api "repos/$repo/issues/$pr/comments" -f body='@codex review' --jq .id
    ;;
reply)
    [ -n "$comment_id" ] || usage
    valid_uint "$comment_id" || refuse "invalid comment ID: $comment_id"
    [ -n "$body_file" ] || usage
    [ -f "$body_file" ] || refuse "--body-file $body_file does not exist"
    [ -s "$body_file" ] || refuse "--body-file $body_file is empty"
    exec gh api "repos/$repo/pulls/$pr/comments/$comment_id/replies" -F body=@"$body_file"
    ;;
top-level)
    [ -z "$comment_id" ] ||
        refuse "top-level takes no --comment-id — it posts to the PR conversation, not a reply thread"
    [ -n "$body_file" ] || usage
    [ -f "$body_file" ] || refuse "--body-file $body_file does not exist"
    [ -s "$body_file" ] || refuse "--body-file $body_file is empty"
    exec gh api "repos/$repo/issues/$pr/comments" -F body=@"$body_file"
    ;;
*)
    usage
    ;;
esac
