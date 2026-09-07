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
ci_runs_on=""
ci_runs_on_set=false
replace_ci_runs_on=false
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
    --ci-runs-on)
        ci_runs_on="${2:-}"
        ci_runs_on_set=true
        shift 2
        ;;
    --replace-ci-runs-on)
        replace_ci_runs_on=true
        shift
        ;;
    *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

if [ -z "$repo" ]; then
    echo "Usage: $0 --repo <owner/repo> [--bot-collaborator <login>] [--ci-runs-on <json-array>] [--replace-ci-runs-on]" >&2
    exit 2
fi
if $ci_runs_on_set && [ -z "$ci_runs_on" ]; then
    echo "--ci-runs-on requires a non-empty value" >&2
    exit 2
fi
if $replace_ci_runs_on && ! $ci_runs_on_set; then
    echo "--replace-ci-runs-on requires --ci-runs-on" >&2
    exit 2
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "Required tool not found: gh" >&2
    exit 1
fi
if $ci_runs_on_set; then
    if ! command -v jq >/dev/null 2>&1; then
        echo "Required tool not found: jq" >&2
        exit 1
    fi
    if ! printf '%s\n' "$ci_runs_on" | jq -se '
        length == 1 and (
            (.[0] | type == "string" and . == "ubuntu-latest") or
            (.[0] | type == "array" and length > 0 and all(.[]; type == "string" and length > 0) and index("self-hosted") != null)
        )
    ' >/dev/null; then
        echo "--ci-runs-on must be \"ubuntu-latest\" or a JSON string array containing self-hosted" >&2
        exit 2
    fi
fi

fail_step() {
    local rc="$1" label="$2" detail="$3"
    checkline no "$label" "$detail (exit $rc)"
}

action_banner setup "GitHub repository" "Safety, vulnerability reporting, and automation access"
kv "Repository" "$repo"

if repo_visibility="$(gh api "repos/$repo" --jq '.visibility')"; then
    :
else
    rc=$?
    fail_step "$rc" "Repository visibility" "could not determine repository visibility"
    exit "$rc"
fi
case "$repo_visibility" in
public | private | internal) ;;
*)
    fail_step 1 "Repository visibility" "unexpected '.visibility' value: ${repo_visibility:-<empty>}"
    exit 1
    ;;
esac

if $ci_runs_on_set; then
    if [ "$repo_visibility" = public ] && [ "$ci_runs_on" != '"ubuntu-latest"' ]; then
        checkline unknown "Actions runner routing" "public repository selected non-canonical routing; enforcing ubuntu-latest"
        ci_runs_on='"ubuntu-latest"'
    fi
    current_ci_runs_on_records=""
    current_ci_runs_on_present=false
    current_ci_runs_on=""
    if current_ci_runs_on_records="$(gh variable list --repo "$repo" --json name,value \
        --jq '[.[] | select(.name == "CI_RUNS_ON")]')"; then
        current_ci_runs_on_count="$(jq -r 'length' <<<"$current_ci_runs_on_records")"
        case "$current_ci_runs_on_count" in
        0) ;;
        1)
            current_ci_runs_on_present=true
            current_ci_runs_on="$(jq -r '.[0].value' <<<"$current_ci_runs_on_records")"
            ;;
        *)
            fail_step 1 "Actions runner routing" "GitHub returned multiple CI_RUNS_ON variables"
            exit 1
            ;;
        esac

        if ! $current_ci_runs_on_present; then
            if output_run "Creating Actions runner routing" \
                gh api "repos/$repo/actions/variables" --method POST \
                -f name=CI_RUNS_ON -f value="$ci_runs_on"; then
                checkline ok "Actions runner routing" "created CI_RUNS_ON"
            else
                rc=$?
                fail_step "$rc" "Actions runner routing" "could not create CI_RUNS_ON"
                exit "$rc"
            fi
        elif [ "$current_ci_runs_on" = "$ci_runs_on" ]; then
            checkline ok "Actions runner routing" "CI_RUNS_ON already matches the selected runner settings"
        else
            if [ "$repo_visibility" = public ]; then
                if output_run "Enforcing public repository runner safety" \
                    gh variable set CI_RUNS_ON --repo "$repo" --body '"ubuntu-latest"'; then
                    checkline ok "Actions runner routing" "standardized public CI_RUNS_ON to ubuntu-latest"
                else
                    rc=$?
                    fail_step "$rc" "Actions runner routing" "could not enforce GitHub-hosted routing on a public repository"
                    exit "$rc"
                fi
            elif $replace_ci_runs_on; then
                if output_run "Replacing Actions runner routing" \
                    gh variable set CI_RUNS_ON --repo "$repo" --body "$ci_runs_on"; then
                    checkline ok "Actions runner routing" "replaced CI_RUNS_ON by explicit request"
                else
                    rc=$?
                    fail_step "$rc" "Actions runner routing" "could not update CI_RUNS_ON"
                    exit "$rc"
                fi
            else
                checkline na "Actions runner routing" "preserved existing ${repo_visibility} CI_RUNS_ON; pass --replace-ci-runs-on to replace it"
            fi
        fi
    else
        rc=$?
        fail_step "$rc" "Actions runner routing" "could not list repository variables"
        exit "$rc"
    fi
fi

# Runner routing is the security-relevant mutation. Complete it before the
# independent repository settings below so an unrelated API failure cannot
# leave a public repository on a previously unsafe route.
if output_run "Enabling Dependabot alerts" \
    gh api "repos/$repo/vulnerability-alerts" --method PUT; then
    checkline ok "Dependabot alerts" "enabled"
else
    rc=$?
    fail_step "$rc" "Dependabot alerts" "GitHub API request failed"
    exit "$rc"
fi

if [ "$repo_visibility" = public ]; then
    if output_run "Enabling private vulnerability reporting" \
        gh api "repos/$repo/private-vulnerability-reporting" --method PUT; then
        checkline ok "Private vulnerability reporting" "enabled"
    else
        rc=$?
        fail_step "$rc" "Private vulnerability reporting" "GitHub API request failed"
        exit "$rc"
    fi
else
    checkline na "Private vulnerability reporting" "skipped: ${repo_visibility} repository; feature is public-repo-only"
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
