#!/usr/bin/env bash
# Apply the repository-level GitHub settings that are safe to reconcile.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
# Task buffers stdout in grouped mode. Keep legacy progress and the visual
# outcome on one live stream so their chronology cannot be reversed.
exec 1>&2
OUTPUT_FD=2
# shellcheck source=scripts/lib/output.sh
. "${script_dir}/lib/output.sh"

repo=""
bot_collaborator=""
bot_pending=false
bot_unverified=false
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo)
        repo="${2:-}"
        shift 2
        ;;
    --bot-collaborator)
        bot_collaborator="${2:-}"
        shift 2
        ;;
    *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

if [ -z "$repo" ]; then
    echo "Usage: $0 --repo <owner/repo> [--bot-collaborator <login>]" >&2
    exit 2
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "Required tool not found: gh" >&2
    exit 1
fi

fail_step() {
    local rc="$1" label="$2" detail="$3"
    checkline no "$label" "$detail (exit $rc)"
}

action_banner setup "GitHub repository" "Safety, vulnerability reporting, and automation access"
kv "Repository" "$repo"

if output_run "Enabling Dependabot alerts" \
    gh api "repos/$repo/vulnerability-alerts" --method PUT; then
    checkline ok "Dependabot alerts" "enabled"
else
    rc=$?
    fail_step "$rc" "Dependabot alerts" "GitHub API request failed"
    exit "$rc"
fi

if repo_private="$(gh api "repos/$repo" --jq '.private')"; then
    :
else
    rc=$?
    fail_step "$rc" "Repository visibility" "could not determine public/private state"
    exit "$rc"
fi
case "$repo_private" in
true | false) ;;
*)
    fail_step 1 "Repository visibility" "unexpected '.private' value: ${repo_private:-<empty>}"
    exit 1
    ;;
esac

if [ "$repo_private" = false ]; then
    if output_run "Enabling private vulnerability reporting" \
        gh api "repos/$repo/private-vulnerability-reporting" --method PUT; then
        checkline ok "Private vulnerability reporting" "enabled"
    else
        rc=$?
        fail_step "$rc" "Private vulnerability reporting" "GitHub API request failed"
        exit "$rc"
    fi
else
    checkline na "Private vulnerability reporting" "skipped: private repository; feature is public-repo-only"
fi

if [ -n "$bot_collaborator" ]; then
    # GitHub's response itself is authoritative here: 201 + an invitation body
    # means acceptance is pending; 204 + no body means access is already active.
    # A follow-up permission lookup cannot distinguish a pending invite from a
    # lookup failure, which was the old implementation's misleading fallback.
    if collaborator_response="$(output_run "Adding bot collaborator" \
        gh api "repos/$repo/collaborators/$bot_collaborator" --method PUT -f permission=push)"; then
        if [ -n "$collaborator_response" ]; then
            bot_pending=true
            checkline unknown "Bot collaborator" "invitation sent to $bot_collaborator; access starts after acceptance"
        elif permission="$(gh api "repos/$repo/collaborators/$bot_collaborator/permission" \
            --jq '.permission' 2>/dev/null)"; then
            case "$permission" in
            admin | maintain | push | write)
                checkline ok "Bot collaborator" "$bot_collaborator has $permission access"
                ;;
            *)
                bot_unverified=true
                checkline unknown "Bot collaborator" "access response was '$permission'; verify $bot_collaborator manually"
                ;;
            esac
        else
            bot_unverified=true
            checkline unknown "Bot collaborator" "GitHub accepted the request, but permission verification failed"
        fi
    else
        rc=$?
        fail_step "$rc" "Bot collaborator" "could not grant push access to $bot_collaborator"
        exit "$rc"
    fi
fi

output_summary "Repository setup"
if $bot_pending; then
    output_warning "GitHub repository settings are ready; bot collaborator acceptance is pending"
elif $bot_unverified; then
    output_warning "GitHub repository settings changed, but collaborator access needs verification"
else
    output_done "GitHub repository settings are ready for $repo"
fi
