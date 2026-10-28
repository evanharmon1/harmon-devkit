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
# shellcheck source=scripts/lib/gh-rest.sh
. "${script_dir}/lib/gh-rest.sh"

repo=""
bot_collaborator=""
routing_names=(CI_RUNS_ON BROWSER_RUNS_ON IMAGE_BUILD_RUNS_ON ISOLATED_RUNS_ON MULTICORE_RUNS_ON)
routing_flags=(ci-runs-on browser-runs-on image-build-runs-on isolated-runs-on multicore-runs-on)
routing_values=('' '' '' '' '')
routing_set=(false false false false false)
routing_replace=(false false false false false)
bot_pending=false
bot_unverified=false
while [ "$#" -gt 0 ]; do
    case "$1" in
    --repo | --bot-collaborator)
        if [ "$#" -lt 2 ]; then
            echo "$1 requires a value" >&2
            exit 2
        fi
        if [ "$1" = --repo ]; then repo="$2"; else bot_collaborator="$2"; fi
        shift 2
        ;;
    --ci-runs-on | --multicore-runs-on | --browser-runs-on | --image-build-runs-on | --isolated-runs-on | \
        --replace-ci-runs-on | --replace-multicore-runs-on | --replace-browser-runs-on | --replace-image-build-runs-on | --replace-isolated-runs-on)
        for i in "${!routing_names[@]}"; do
            if [ "$1" = "--${routing_flags[$i]}" ]; then
                if [ "$#" -lt 2 ] || [ -z "$2" ]; then
                    echo "$1 requires a non-empty value" >&2
                    exit 2
                fi
                routing_values[$i]="$2"
                routing_set[$i]=true
                shift 2
                break
            elif [ "$1" = "--replace-${routing_flags[$i]}" ]; then
                routing_replace[$i]=true
                shift
                break
            fi
        done
        ;;
    *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

if [ -z "$repo" ]; then
    echo "Usage: $0 --repo <owner/repo> [--bot-collaborator <login>] [--{ci,browser,image-build,isolated,multicore}-runs-on <json>] [--replace-{ci,browser,image-build,isolated,multicore}-runs-on]" >&2
    exit 2
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "Required tool not found: gh" >&2
    exit 1
fi
# One classification for requested, repository, and organization selectors.
isolated_selector_state() {
    printf '%s\n' "$1" | jq -sr '
        if length != 1 then "unsupported" else .[0] |
            (if type == "object" then .labels else . end) |
            if (type == "string" and length > 0) or
                (type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
            then (if type == "array" then . else [.] end) |
                if any(.[]; ascii_downcase == "self-hosted") then "unsafe" else "safe" end
            else "unsupported" end
        end' 2>/dev/null || printf 'unsupported\n'
}

# Validate every requested value before any API call or mutation.
for i in "${!routing_names[@]}"; do
    if ${routing_replace[$i]} && ! ${routing_set[$i]}; then
        echo "--replace-${routing_flags[$i]} requires --${routing_flags[$i]}" >&2
        exit 2
    fi
    ${routing_set[$i]} || continue
    if ! command -v jq >/dev/null 2>&1; then
        echo "Required tool not found: jq" >&2
        exit 1
    fi
    if [ "${routing_names[$i]}" = ISOLATED_RUNS_ON ]; then
        case "$(isolated_selector_state "${routing_values[$i]}")" in
        safe) ;;
        unsafe)
            echo "ISOLATED_RUNS_ON invariant: isolated routing must never contain the self-hosted label" >&2
            exit 2
            ;;
        *)
            echo "ISOLATED_RUNS_ON invariant: unsupported selector shape; use a string, label array, or object with usable labels" >&2
            exit 2
            ;;
        esac
    elif ! printf '%s\n' "${routing_values[$i]}" | jq -se '
        length == 1 and (.[0] |
            (type == "string" and length > 0) or
            (type == "array" and length > 0 and all(.[]; type == "string" and length > 0)))
    ' >/dev/null; then
        echo "--${routing_flags[$i]} must be a non-empty JSON string or non-empty array of non-empty strings" >&2
        exit 2
    fi
done

collect_org_routing() {
    local repo="$1" page=1 page_size=30 max_pages payload count expected="" total=0 pages=""
    max_pages="$(gh_rest_max_pages)" || return 2
    while [ "$page" -le "$max_pages" ]; do
        payload="$(GH_REST_TIMEOUT="${GH_REST_TIMEOUT:-5}" gh_rest_api \
            "repos/${repo}/actions/organization-variables?per_page=${page_size}&page=${page}")" || return
        jq -se 'length == 1 and (.[0] |
            (.total_count | type == "number" and . >= 0 and floor == .) and
            (.variables | type == "array" and length <= 30 and all(.[];
                type == "object" and (.name | type == "string") and (.value | type == "string"))))' \
            >/dev/null 2>&1 <<<"$payload" || return 3
        count="$(jq -r '.total_count' <<<"$payload")"
        [ -z "$expected" ] && expected="$count"
        [ "$expected" = "$count" ] || return 3
        count="$(jq '.variables | length' <<<"$payload")"
        total=$((total + count))
        pages="${pages}$(jq -c '.variables' <<<"$payload")"$'\n'
        if [ "$total" -eq "$expected" ]; then
            jq -se 'add | if (unique_by(.name) | length) == length then . else error("duplicate variables") end' <<<"$pages"
            return
        fi
        [ "$count" -eq "$page_size" ] && [ "$total" -lt "$expected" ] || return 3
        page=$((page + 1))
    done
    return 4
}

fail_step() {
    local rc="$1" label="$2" detail="$3"
    checkline no "$label" "$detail (exit $rc)"
}

# Resolve one target before any GitHub call. A hostless GH_REPO cannot
# override GH_HOST; the shared helper owns ports and the explicit-empty escape.
TARGET_HOST="$(GH_REPO="$repo" gh_rest_host)"
TARGET_HOST="${TARGET_HOST:-github.com}"
repo="$(GH_REPO="$repo" gh_rest_repo)"
export GH_HOST="$TARGET_HOST" GH_REPO="$repo"
if [ -n "${GH_REST_HOST-unset}" ]; then export GH_REST_HOST="$TARGET_HOST"; fi
routing_repo="$repo"

if ! command -v jq >/dev/null 2>&1; then
    echo "Required tool not found: jq" >&2
    exit 1
fi

action_banner setup "GitHub repository" "Safety, vulnerability reporting, and automation access"
kv "Repository" "$repo"

if repo_visibility="$(gh_rest_api "repos/$repo" --jq '.visibility')"; then
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

# One complete repository inventory feeds every class; writes do not get a
# locally imposed deadline. Public safety overrides precede inherited checks.
if routing_inventory="$(gh variable list --repo "$routing_repo" --json name,value)"; then
    :
else
    rc=$?
    fail_step "$rc" "Actions runner routing" "could not list repository variables"
    exit "$rc"
fi
if ! jq -se 'length == 1 and (.[0] | type == "array" and all(.[];
    type == "object" and (.name | type == "string") and (.value | type == "string")))' \
    >/dev/null 2>&1 <<<"$routing_inventory"; then
    fail_step 1 "Actions runner routing" "invalid repository variable inventory"
    exit 1
fi
repo_isolated_present=false
if jq -e 'any(.[]; .name == "ISOLATED_RUNS_ON")' <<<"$routing_inventory" >/dev/null; then repo_isolated_present=true; fi

# Inspect private isolated values first, even without a flag. Public values
# are repaired without interpreting their old shape.
# Public repository overrides must shadow every organization routing value.
for i in 3 0 1 2 4; do
    if [ "$i" != 3 ] && [ "$repo_visibility" != public ] && ! ${routing_set[$i]}; then continue; fi
    routing_name="${routing_names[$i]}"
    routing_value="${routing_values[$i]}"
    if [ "$repo_visibility" = public ] && ${routing_set[$i]} && [ "$routing_value" != '"ubuntu-latest"' ]; then
        checkline unknown "Actions runner routing" "public repository selected non-canonical routing; enforcing ubuntu-latest"
    fi
    if [ "$repo_visibility" = public ]; then routing_value='"ubuntu-latest"'; fi
    current_routing_records=""
    current_routing_present=false
    current_routing=""
    if current_routing_records="$(jq --arg name "$routing_name" '[.[] | select(.name == $name)]' <<<"$routing_inventory")"; then
        current_routing_count="$(jq -r 'length' <<<"$current_routing_records")"
        case "$current_routing_count" in
        0) ;;
        1)
            current_routing_present=true
            current_routing="$(jq -r '.[0].value' <<<"$current_routing_records")"
            ;;
        *)
            fail_step 1 "Actions runner routing" "GitHub returned multiple ${routing_name} variables"
            exit 1
            ;;
        esac

        if [ "$repo_visibility" != public ] && [ "$routing_name" = ISOLATED_RUNS_ON ] && $current_routing_present; then
            case "$(isolated_selector_state "$current_routing")" in
            unsupported)
                fail_step 1 "ISOLATED_RUNS_ON invariant" "unsupported repository selector shape; correct the repository value before re-running setup"
                exit 1
                ;;
            unsafe)
                if [ "$repo_visibility" != public ] && ! { ${routing_set[$i]} && ${routing_replace[$i]}; }; then
                    fail_step 1 "ISOLATED_RUNS_ON invariant" "existing repository value contains self-hosted; pass a safe --isolated-runs-on with --replace-isolated-runs-on to repair it"
                    exit 1
                fi
                ;;
            esac
        fi
        if [ "$repo_visibility" != public ] && ! ${routing_set[$i]}; then continue; fi

        if ! $current_routing_present; then
            if output_run "Creating Actions runner routing" \
                gh_rest_api "repos/$repo/actions/variables" --method POST \
                -f name="$routing_name" -f value="$routing_value"; then
                if [ "$repo_visibility" = public ]; then
                    checkline ok "Actions runner routing" "created ${routing_name} (public repository safety enforcement)"
                else
                    checkline ok "Actions runner routing" "created ${routing_name}"
                fi
            else
                rc=$?
                fail_step "$rc" "Actions runner routing" "could not create ${routing_name}"
                exit "$rc"
            fi
        elif [ "$current_routing" = "$routing_value" ]; then
            checkline ok "Actions runner routing" "${routing_name} already matches the selected runner settings"
        else
            if [ "$repo_visibility" = public ]; then
                if output_run "Enforcing public repository runner safety" \
                    gh variable set "$routing_name" --repo "$routing_repo" --body '"ubuntu-latest"'; then
                    checkline ok "Actions runner routing" "standardized public ${routing_name} to ubuntu-latest (public repository safety enforcement)"
                else
                    rc=$?
                    fail_step "$rc" "Actions runner routing" "could not enforce GitHub-hosted routing on a public repository"
                    exit "$rc"
                fi
            elif ${routing_replace[$i]}; then
                if output_run "Replacing Actions runner routing" \
                    gh variable set "$routing_name" --repo "$routing_repo" --body "$routing_value"; then
                    checkline ok "Actions runner routing" "replaced ${routing_name} by explicit request"
                else
                    rc=$?
                    fail_step "$rc" "Actions runner routing" "could not update ${routing_name}"
                    exit "$rc"
                fi
            else
                checkline na "Actions runner routing" "preserved existing ${repo_visibility} ${routing_name}; pass --replace-${routing_flags[$i]} to replace it"
            fi
        fi
        if [ "$routing_name" = ISOLATED_RUNS_ON ]; then repo_isolated_present=true; fi
    else
        rc=$?
        fail_step "$rc" "Actions runner routing" "could not list repository variables"
        exit "$rc"
    fi
done

# The repository override, including one just written, determines inheritance.
owner_type="$(gh_rest_api "repos/$repo" --jq '.owner.type' 2>/dev/null || echo unknown)"
if [ "$owner_type" = User ]; then
    checkline na "ISOLATED_RUNS_ON (org)" "not an organization"
elif org_routing="$(collect_org_routing "$repo" 2>/dev/null)"; then
    if jq -e 'any(.[]; .name == "ISOLATED_RUNS_ON")' <<<"$org_routing" >/dev/null; then
        org_isolated="$(jq -r '.[] | select(.name == "ISOLATED_RUNS_ON") | .value' <<<"$org_routing")"
        if [ "$(isolated_selector_state "$org_isolated")" != safe ]; then
            if $repo_isolated_present; then
                checkline unknown "ISOLATED_RUNS_ON (org)" "warning: unsafe or unsupported value is shadowed by the repository override; contact the organization's routing owner (whoever manages organization Actions variables)"
            else
                fail_step 1 "ISOLATED_RUNS_ON invariant" "inherited organization value is self-hosted or unsupported; contact the organization's routing owner (whoever manages organization Actions variables), or create a safe repository override"
                exit 1
            fi
        fi
    fi
else
    checkline unknown "ISOLATED_RUNS_ON (org)" "unknown — organization variable inventory unreadable"
fi

# Runner routing is the security-relevant mutation. Complete it before the
# independent repository settings below so an unrelated API failure cannot
# leave a public repository on a previously unsafe route.
if output_run "Enabling Dependabot alerts" \
    gh_rest_api "repos/$repo/vulnerability-alerts" --method PUT; then
    checkline ok "Dependabot alerts" "enabled"
else
    rc=$?
    fail_step "$rc" "Dependabot alerts" "GitHub API request failed"
    exit "$rc"
fi

if [ "$repo_visibility" = public ]; then
    if output_run "Enabling private vulnerability reporting" \
        gh_rest_api "repos/$repo/private-vulnerability-reporting" --method PUT; then
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
        gh_rest_api "repos/$repo/collaborators/$bot_collaborator" --method PUT -f permission=push)"; then
        if [ -n "$collaborator_response" ]; then
            bot_pending=true
            checkline unknown "Bot collaborator" "invitation sent to $bot_collaborator; access starts after acceptance"
        elif permission="$(gh_rest_api "repos/$repo/collaborators/$bot_collaborator/permission" \
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
