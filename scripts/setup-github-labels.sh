#!/usr/bin/env bash
# setup-github-labels.sh — idempotently create/update this repo's starter label
# set, report labels outside the registry, and retire them safely when asked.
# The vocabulary is NOT listed here: every family, value, color, and description
# lives in label-registry.json (the machine-readable taxonomy manifest — see
# docs/project-management.md for the human-facing table, which is generated from
# the same file), and this script provisions whatever
# scripts/label-registry-render.mjs renders from it. The agent families
# (suggest:/claim:/foreman:<adapter>) come from agent-registry.json via the same
# renderer, so provisioning, inventory, docs, and both registries cannot fork
# (test-label-registry.sh and test-registry-drift.sh gate them together).
#
# Labels are REPO-level in GitHub — there's no shared org label pool. Run this in
# each repo; org "default labels" (Settings → Repository, UI-only, no API) only
# seed NEW repos and don't touch existing ones. Non-destructive: `--force`
# creates-or-updates and it never deletes labels, so GitHub's defaults stay
# unless you explicitly run a maintenance mode. The maintenance modes report
# live labels outside the active/adopted/tool-owned registry inventory and can
# prune them only after a prompt and a fresh zero-association check.
# `--migrate OLD=NEW` attempts to move OLD associations for matching issues,
# pull requests, and discussions returned by the paginated snapshots before the
# guarded prune.
# Retired values are intentionally reportable. The move is best-effort at
# GitHub's non-atomic API boundary and requires a quiescent maintenance window.
# Destructive maintenance assumes the operator has paused label/issue/PR/
# discussion writers for a quiescent window; GitHub cannot atomically bind the final association
# read to the subsequent label DELETE request.
#
# Usage:
#   setup-github-labels.sh --repo <owner/repo> [--foreman] [--release-please]
#   setup-github-labels.sh --repo <owner/repo> --report-unregistered [flags]
#   setup-github-labels.sh --repo <owner/repo> --prune [--migrate OLD=NEW] [--yes] [flags]
# Needs: gh authed with repo write; node (the renderer); jq for maintenance.
#
# --foreman additionally provisions the families the manifest gates on foreman
# (the arming selectors rendered from the agent registry, and foreman's own
# workflow-state protocol labels — human inputs the foreman CLI reads but never
# auto-creates). The flag is passed by the Taskfile target when the repo uses
# foreman, keeping this script identical across repos that do and don't.
#
# NOTE: hits the live GitHub API, so it is not exercised by `task test:template`
# (guarded by shellcheck + shfmt only). Test maintenance modes against a stub.
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage:
  setup-github-labels.sh --repo <owner/repo> [--foreman] [--release-please]
  setup-github-labels.sh --repo <owner/repo> --report-unregistered [flags]
  setup-github-labels.sh --repo <owner/repo> --prune [--migrate OLD=NEW] [--yes] [flags]

The default invocation only creates or updates registry-provisioned labels.
--report-unregistered is read-only. --prune requires operator confirmation of
a quiescent maintenance window. After any requested migration, it refuses
deletion when associations remain in its latest API snapshot, but GitHub has
no atomic read/delete boundary and a concurrent writer can still race the
request. --yes is the explicit noninteractive confirmation of that window and
of this best-effort boundary.
USAGE
}

repo=""
foreman=0
release_please=0
migrate_specs=()
report_unregistered=0
prune=0
assume_yes=0
while [ "$#" -gt 0 ]; do
    case "$1" in
    --help)
        usage
        exit 0
        ;;
    --repo)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
            echo "--repo requires a non-empty owner/repo value" >&2
            exit 2
        fi
        repo="${2:-}"
        shift 2
        ;;
    --foreman)
        foreman=1
        shift
        ;;
    --release-please)
        release_please=1
        shift
        ;;
    --report-unregistered)
        report_unregistered=1
        shift
        ;;
    --prune)
        prune=1
        shift
        ;;
    --yes)
        assume_yes=1
        shift
        ;;
    --migrate)
        if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
            echo "--migrate requires OLD=NEW" >&2
            exit 2
        fi
        migrate_specs+=("$2")
        shift 2
        ;;
    *)
        echo "Unknown argument: $1" >&2
        exit 2
        ;;
    esac
done

if [ -z "$repo" ]; then
    echo "--repo <owner/repo> is required" >&2
    usage
    exit 2
fi
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "Invalid repository '$repo' (expected owner/repo)" >&2
    exit 2
fi
if [ "$report_unregistered" = 1 ] && [ "$prune" = 1 ]; then
    echo "--report-unregistered and --prune are mutually exclusive" >&2
    exit 2
fi
if [ "${#migrate_specs[@]}" -gt 0 ] && [ "$prune" != 1 ]; then
    echo "--migrate requires --prune" >&2
    exit 2
fi
if [ "$assume_yes" = 1 ] && [ "$prune" != 1 ]; then
    echo "--yes requires --prune" >&2
    exit 2
fi

for tool in gh node; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required tool not found: $tool" >&2
        exit 1
    fi
done
if [ "$report_unregistered" = 1 ] || [ "$prune" = 1 ]; then
    # GitHub label names are case-insensitive. Keep every local membership and
    # collision check aligned with the API so a differently-cased live label
    # cannot be reported or pruned as though it were unregistered.
    shopt -s nocasematch
    if ! command -v jq >/dev/null 2>&1; then
        echo "Required tool not found for maintenance mode: jq" >&2
        exit 1
    fi
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
renderer="$script_dir/label-registry-render.mjs"
OUTPUT_FD=2
# shellcheck source=scripts/lib/output.sh
. "$script_dir/lib/output.sh"

die() {
    output_emit 'ERROR: %s\n' "$*"
    exit 1
}

render_args=(labels)
if [ "$foreman" = 1 ]; then
    render_args+=(--foreman)
fi
if [ "$release_please" = 1 ]; then
    render_args+=(--release-please)
fi

if [ "$report_unregistered" = 1 ] || [ "$prune" = 1 ]; then
    action_banner clean "GitHub label retirement" "Read, migrate, and prune only with explicit maintenance flags"
    kv "Repository" "$repo"

    maintenance_tmp="$(mktemp -d)"
    trap 'rm -rf "$maintenance_tmp"' EXIT
    live_pages="$maintenance_tmp/live-pages.json"
    live_labels_json="$maintenance_tmp/live-labels.json"
    association_pages="$maintenance_tmp/association-pages.json"
    discussion_pages="$maintenance_tmp/discussion-pages.json"
    associations_json="$maintenance_tmp/associations.json"
    repo_owner="${repo%%/*}"
    repo_name="${repo#*/}"

    read_live_labels() {
        if ! gh api --paginate --slurp "repos/$repo/labels?per_page=100" >"$live_pages"; then
            die "could not read the complete label list; refusing maintenance"
        fi
        if ! jq -e '
            if type != "array" or any(.[]; type != "array") then
                error("expected paginated label arrays")
            else
                [.[][] |
                    if type != "object" or (.name | type) != "string" or (.name | length) == 0 or (.name | test("[\\n\\r]")) or
                        (.color | type) != "string" or (.description != null and (.description | type) != "string") or
                        (.node_id | type) != "string" or (.node_id | length) == 0 then
                        error("label response contains an invalid name")
                    else {name, color, description: (.description // ""), id: .node_id} end
                ]
            end
        ' "$live_pages" >"$live_labels_json"; then
            die "label response was invalid or incomplete; refusing maintenance"
        fi
    }

    read_associations() {
        if ! gh api --paginate --slurp "repos/$repo/issues?state=all&per_page=100" >"$association_pages"; then
            die "could not read the complete issue and pull-request list; refusing maintenance"
        fi
        if ! jq -e '
            if type != "array" or any(.[]; type != "array") then
                error("expected paginated issue arrays")
            else
                [.[][] |
                    if type != "object" then
                        error("issue response contains a non-object")
                    elif (.number | type) != "number" then
                        error("issue response contains an invalid number")
                    elif has("pull_request") and (.pull_request | type) != "object" then
                        error("issue response contains an invalid pull-request marker")
                    elif (.labels | type) != "array" then
                        error("issue response contains no labels array")
                    elif any(.labels[]; type != "object" or ((.name | type) != "string") or ((.name | length) == 0) or (.name | test("[\\n\\r]"))) then
                        error("issue response contains an invalid label")
                    else
                        {number, kind: (if has("pull_request") then "pr" else "issue" end), id: null, labels: [.labels[].name]}
                    end
                ]
            end
        ' "$association_pages" >"$associations_json"; then
            die "issue or pull-request response was invalid; refusing maintenance"
        fi

        if ! gh api graphql --paginate --slurp -f owner="$repo_owner" -f name="$repo_name" -f query='query($owner:String!,$name:String!,$endCursor:String){repository(owner:$owner,name:$name){discussions(first:100,after:$endCursor){nodes{id number labels(first:100){nodes{name} pageInfo{hasNextPage}}}pageInfo{hasNextPage endCursor}}}}' >"$discussion_pages"; then
            die "could not read the complete discussion list; refusing maintenance"
        fi
        if ! jq -e '
            if type != "array" or any(.[]; (.data.repository.discussions.nodes | type) != "array") then
                error("expected paginated discussion objects")
            else
                [.[] | .data.repository.discussions.nodes[] |
                    if (.id | type) != "string" or (.id | length) == 0 or (.number | type) != "number" or
                        (.labels.nodes | type) != "array" or .labels.pageInfo.hasNextPage != false or
                        any(.labels.nodes[]; (.name | type) != "string" or (.name | length) == 0 or (.name | test("[\\n\\r]"))) then
                        error("discussion response is invalid or has more than 100 labels")
                    else {number, kind: "discussion", id, labels: [.labels.nodes[].name]} end
                ]
            end
        ' "$discussion_pages" >"$maintenance_tmp/discussions.json"; then
            die "discussion response was invalid or incomplete; refusing maintenance"
        fi
        jq -s '.[0] + .[1]' "$associations_json" "$maintenance_tmp/discussions.json" >"$maintenance_tmp/all-associations.json"
        mv "$maintenance_tmp/all-associations.json" "$associations_json"
    }

    protected_exact=()
    protected_prefixes=()
    load_inventory() {
        local inventory kind name extra
        if ! inventory="$(node "$renderer" inventory "${render_args[@]:1}")"; then
            die "registry inventory rendering failed; refusing maintenance"
        fi
        while IFS='|' read -r kind name extra; do
            [ -z "$kind" ] && continue
            [ -n "$name" ] || die "registry inventory contained an empty label"
            [ -z "$extra" ] || die "registry inventory contained a malformed record"
            case "$kind" in
            exact)
                protected_exact+=("$name")
                ;;
            prefix)
                protected_prefixes+=("$name")
                ;;
            *)
                die "registry inventory contained unknown record type '$kind'"
                ;;
            esac
        done <<<"$inventory"
    }

    is_protected_label() {
        local name="$1" exact prefix
        for exact in "${protected_exact[@]}"; do
            [[ "$name" == "$exact" ]] && return 0
        done
        for prefix in "${protected_prefixes[@]}"; do
            case "$name" in
            "$prefix"?*) return 0 ;;
            esac
        done
        return 1
    }

    live_label_name() {
        local wanted="$1" name
        while IFS= read -r -d '' name; do
            if [[ "$name" == "$wanted" ]]; then
                printf '%s' "$name"
                return 0
            fi
        done < <(jq -j '.[].name + "\u0000"' "$live_labels_json")
        return 1
    }

    live_label_exists() {
        live_label_name "$1" >/dev/null
    }

    candidate_label_name() {
        local wanted="$1" name
        for name in "${candidates[@]}"; do
            if [[ "$name" == "$wanted" ]]; then
                printf '%s' "$name"
                return 0
            fi
        done
        return 1
    }

    association_counts() {
        local label="$1"
        jq -r --arg label "$label" '
            reduce .[] as $item ({issues: 0, prs: 0, discussions: 0};
                if any($item.labels[]; ascii_downcase == ($label | ascii_downcase)) then
                    if $item.kind == "pr" then .prs += 1
                    elif $item.kind == "discussion" then .discussions += 1
                    else .issues += 1 end
                else . end)
            | "\(.issues)\t\(.prs)\t\(.discussions)"
        ' "$associations_json"
    }

    candidates=()
    candidate_issues=()
    candidate_prs=()
    candidate_discussions=()
    collect_candidates() {
        local name counts issue_count pr_count discussion_count
        while IFS= read -r -d '' name; do
            if is_protected_label "$name"; then
                continue
            fi
            counts="$(association_counts "$name")"
            IFS=$'\t' read -r issue_count pr_count discussion_count <<<"$counts"
            candidates+=("$name")
            candidate_issues+=("$issue_count")
            candidate_prs+=("$pr_count")
            candidate_discussions+=("$discussion_count")
        done < <(jq -j '.[].name + "\u0000"' "$live_labels_json")
    }

    print_report() {
        local i
        if [ "${#candidates[@]}" -eq 0 ]; then
            output_emit '%s\n' 'No unregistered labels found.'
            return 0
        fi
        for i in "${!candidates[@]}"; do
            printf -v quoted_name '%q' "${candidates[$i]}"
            output_emit 'Unregistered label: %s (issues: %s, PRs: %s, discussions: %s)\n' \
                "$quoted_name" "${candidate_issues[$i]}" "${candidate_prs[$i]}" "${candidate_discussions[$i]}"
        done
    }

    migration_old=()
    migration_new=()
    migration_create_from=()
    migration_parent=()
    migration_complete=()
    parse_migrations() {
        local spec old new i
        [ "${#migrate_specs[@]}" -gt 0 ] || return 0
        for spec in "${migrate_specs[@]}"; do
            if [[ "$spec" == *=*=* ]]; then
                echo "Invalid migration '$spec' (OLD=NEW is ambiguous when either label contains '='); relabel those records manually" >&2
                exit 2
            fi
            case "$spec" in
            *=*)
                old="${spec%%=*}"
                new="${spec#*=}"
                ;;
            *)
                echo "Invalid migration '$spec' (expected OLD=NEW)" >&2
                exit 2
                ;;
            esac
            if [ -z "$old" ] || [ -z "$new" ] ||
                [[ "$old" == *$'\n'* || "$old" == *$'\r'* || "$new" == *$'\n'* || "$new" == *$'\r'* ]]; then
                echo "Invalid migration '$spec' (labels must be non-empty and single-line)" >&2
                exit 2
            fi
            if [[ "$old" == "$new" ]]; then
                echo "Invalid migration '$spec' (OLD and NEW must differ)" >&2
                exit 2
            fi
            for i in "${!migration_old[@]}"; do
                if [[ "$old" == "${migration_old[$i]}" ]]; then
                    echo "Duplicate migration source '$old'" >&2
                    exit 2
                fi
            done
            migration_old+=("$old")
            migration_new+=("$new")
        done
    }

    is_migration_source() {
        local wanted="$1" old
        [ "${#migration_old[@]}" -gt 0 ] || return 1
        for old in "${migration_old[@]}"; do
            [[ "$old" == "$wanted" ]] && return 0
        done
        return 1
    }

    is_broker_migration_source() {
        case "$1" in
        agent:github-copilot | agent:github-copilot:* | suggest:copilot | suggest:copilot:* | claim:copilot | claim:copilot:*) return 0 ;;
        esac
        return 1
    }

    fixed_migration_destination() {
        local source="$1" suffix
        case "$source" in
        agent:claude-code) printf '%s' 'claim:claude' ;;
        agent:codex) printf '%s' 'claim:gpt' ;;
        agent:gemini-cli) printf '%s' 'claim:gemini' ;;
        agent:kimi-k2) printf '%s' 'claim:kimi' ;;
        agent:qwen-code) printf '%s' 'claim:qwen' ;;
        suggest:codex) printf '%s' 'suggest:gpt' ;;
        suggest:codex:*)
            suffix="${source#*:}"
            printf 'suggest:gpt:%s' "${suffix#*:}"
            ;;
        claim:codex) printf '%s' 'claim:gpt' ;;
        claim:codex:*)
            suffix="${source#*:}"
            printf 'claim:gpt:%s' "${suffix#*:}"
            ;;
        *) return 1 ;;
        esac
    }

    validate_migrations() {
        local i old new canonical_old canonical_new canonical_parent expected_fixed prefix parent source_complete
        for i in "${!migration_old[@]}"; do
            old="${migration_old[$i]}"
            new="${migration_new[$i]}"
            source_complete=0
            if canonical_old="$(candidate_label_name "$old")"; then
                :
            elif live_label_exists "$old"; then
                die "migration source '$old' is live but is not one of the reported unregistered labels"
            else
                canonical_old="$old"
                source_complete=1
            fi
            if is_broker_migration_source "$canonical_old"; then
                die "migration source '$canonical_old' is broker-derived and has no trustworthy single destination; re-express or remove each matching record manually using its confirmed family/model, then rerun --prune"
            fi
            if expected_fixed="$(fixed_migration_destination "$canonical_old")" && [[ "$new" != "$expected_fixed" ]]; then
                die "migration source '$canonical_old' has authoritative destination '$expected_fixed', not '$new'"
            fi
            if ! is_protected_label "$new"; then
                die "migration destination '$new' is not covered by the registry inventory"
            fi
            parent=""
            for prefix in "${protected_prefixes[@]}"; do
                if [[ "$new" == "$prefix"?* ]] && { [ -z "$parent" ] || [ "${#prefix}" -gt "$((${#parent} + 1))" ]; }; then
                    parent="${prefix%:}"
                fi
            done
            canonical_parent=""
            if [ "$source_complete" = 1 ]; then
                canonical_new="$(live_label_name "$new")" ||
                    die "migration source '$canonical_old' is absent but destination '$new' is not live; run label setup first"
                migration_create_from+=("")
            elif canonical_new="$(live_label_name "$new")"; then
                migration_create_from+=("")
            else
                [ -n "$parent" ] || die "migration destination '$new' is not live and is not an on-demand registry family label"
                canonical_parent="$(live_label_name "$parent")" ||
                    die "migration destination '$new' requires live family label '$parent'; run label setup first"
                canonical_new="$new"
                migration_create_from+=("$canonical_parent")
            fi
            migration_old[i]="$canonical_old"
            migration_new[i]="$canonical_new"
            migration_parent+=("$canonical_parent")
            migration_complete+=("$source_complete")
        done
    }

    create_missing_destinations() {
        local i new parent metadata color description canonical_new quoted_new quoted_parent
        for i in "${!migration_old[@]}"; do
            parent="${migration_create_from[$i]}"
            [ -n "$parent" ] || continue
            new="${migration_new[$i]}"
            if canonical_new="$(live_label_name "$new")"; then
                migration_new[i]="$canonical_new"
                continue
            fi
            metadata="$(jq -cer --arg parent "$parent" '.[] | select((.name | ascii_downcase) == ($parent | ascii_downcase)) | {color, description}' "$live_labels_json")" ||
                die "could not read metadata for migration destination family '$parent'"
            color="$(jq -r '.color' <<<"$metadata")"
            description="$(jq -r '.description' <<<"$metadata")"
            gh label create "$new" --repo "$repo" --color "$color" --description "$description" ||
                die "could not create on-demand migration destination '$new'; refusing further maintenance"
            read_live_labels
            canonical_new="$(live_label_name "$new")" ||
                die "created migration destination '$new' could not be re-read; refusing further maintenance"
            migration_new[i]="$canonical_new"
            printf -v quoted_new '%q' "$canonical_new"
            printf -v quoted_parent '%q' "$parent"
            output_emit 'Created migration destination: %s (copied metadata from %s)\n' "$quoted_new" "$quoted_parent"
        done
    }

    print_migration_plan() {
        local i old new counts issue_count pr_count discussion_count
        for i in "${!migration_old[@]}"; do
            old="${migration_old[$i]}"
            new="${migration_new[$i]}"
            if [ "${migration_complete[$i]}" = 1 ]; then
                printf -v quoted_old '%q' "$old"
                printf -v quoted_new '%q' "$new"
                output_emit 'Migration already complete: %s -> %s (source label is absent)\n' "$quoted_old" "$quoted_new"
                continue
            fi
            counts="$(association_counts "$old")"
            IFS=$'\t' read -r issue_count pr_count discussion_count <<<"$counts"
            printf -v quoted_old '%q' "$old"
            printf -v quoted_new '%q' "$new"
            output_emit 'Migration: %s -> %s (issues: %s, PRs: %s, discussions: %s)\n' \
                "$quoted_old" "$quoted_new" "$issue_count" "$pr_count" "$discussion_count"
        done
    }

    confirm_prune() {
        local answer
        if [ "$assume_yes" = 1 ]; then
            output_emit '%s\n' 'Prune confirmed by explicit --yes: operator confirms a quiescent maintenance window for issue, PR, and discussion label writers and accepts the unavoidable GitHub final-read/delete API race.'
            return 0
        fi
        if [ ! -t 0 ]; then
            output_emit '%s\n' 'Prune cancelled: interactive confirmation requires a TTY; pass --yes explicitly for noninteractive use.'
            return 1
        fi
        if ! read -r -p 'Confirm a quiescent maintenance window (pause label/issue/PR/discussion writers) and accept the unavoidable GitHub final-read/delete API race; proceed? [y/N] ' answer </dev/tty; then
            output_emit '%s\n' 'Prune cancelled: confirmation was unavailable.'
            return 1
        fi
        case "$answer" in
        y | Y | yes | YES | Yes) return 0 ;;
        *)
            output_emit '%s\n' 'Prune cancelled; no labels were changed.'
            return 1
            ;;
        esac
    }

    read_item_labels() {
        local kind="$1" number="$2" item_id="${3:-}" response
        if [ "$kind" = discussion ]; then
            response="$(gh api graphql -f id="$item_id" -f query='query($id:ID!){node(id:$id){... on Discussion{labels(first:100){nodes{name}pageInfo{hasNextPage}}}}}')" || return 1
            jq -e 'if .data.node.labels.pageInfo.hasNextPage == false then {labels: .data.node.labels.nodes} else error("discussion has more than 100 labels") end' <<<"$response"
            return
        fi
        if [ "$kind" = pr ]; then
            gh pr view "$number" --repo "$repo" --json labels
        else
            gh issue view "$number" --repo "$repo" --json labels
        fi
    }

    migration_labels_present() {
        local labels_json="$1" old="$2" new="$3" parent="$4"
        jq -e --arg old "$old" --arg new "$new" --arg parent "$parent" '
            (.labels | type) == "array" and
            any(.labels[]?; ((.name | ascii_downcase) == ($old | ascii_downcase))) and
            any(.labels[]?; ((.name | ascii_downcase) == ($new | ascii_downcase))) and
            ($parent == "" or any(.labels[]?; ((.name | ascii_downcase) == ($parent | ascii_downcase))))
        ' <<<"$labels_json" >/dev/null
    }

    migration_result_valid() {
        local labels_json="$1" old="$2" new="$3" parent="$4"
        jq -e --arg old "$old" --arg new "$new" --arg parent "$parent" '
            (.labels | type) == "array" and
            any(.labels[]?; ((.name | ascii_downcase) == ($new | ascii_downcase))) and
            ($parent == "" or any(.labels[]?; ((.name | ascii_downcase) == ($parent | ascii_downcase)))) and
            all(.labels[]?; ((.name | ascii_downcase) != ($old | ascii_downcase)))
        ' <<<"$labels_json" >/dev/null
    }

    verify_migration_before_remove() {
        local kind="$1" number="$2" item_id="$3" old="$4" new="$5" parent="$6" phase="$7" labels_json
        if ! labels_json="$(read_item_labels "$kind" "$number" "$item_id")"; then
            die "could not read labels on $kind #$number $phase; refusing further maintenance"
        fi
        if ! migration_labels_present "$labels_json" "$old" "$new" "$parent"; then
            die "could not verify migration labels on $kind #$number $phase; refusing further maintenance"
        fi
    }

    verify_migration_after_remove() {
        local kind="$1" number="$2" item_id="$3" old="$4" new="$5" parent="$6" labels_json
        if ! labels_json="$(read_item_labels "$kind" "$number" "$item_id")"; then
            die "could not re-read labels on $kind #$number after removing '$old'; refusing further maintenance"
        fi
        if ! migration_result_valid "$labels_json" "$old" "$new" "$parent"; then
            die "migration verification failed on $kind #$number; destination labels must remain and '$old' must be absent"
        fi
    }

    live_label_id() {
        jq -er --arg label "$1" '.[] | select((.name | ascii_downcase) == ($label | ascii_downcase)) | .id' "$live_labels_json"
    }

    edit_discussion_label() {
        local operation="$1" discussion_id="$2" label="$3" label_id mutation
        label_id="$(live_label_id "$label")" || die "could not resolve label ID for '$label'"
        if [ "$operation" = add ]; then
            mutation='mutation($labelableId:ID!,$labelIds:[ID!]!){addLabelsToLabelable(input:{labelableId:$labelableId,labelIds:$labelIds}){clientMutationId}}'
        else
            mutation='mutation($labelableId:ID!,$labelIds:[ID!]!){removeLabelsFromLabelable(input:{labelableId:$labelableId,labelIds:$labelIds}){clientMutationId}}'
        fi
        gh api graphql -f labelableId="$discussion_id" -F labelIds[]="$label_id" -f query="$mutation" >/dev/null
    }

    edit_issue_or_pr_label() {
        local operation="$1" number="$2" label="$3" encoded_label
        if [ "$operation" = add ]; then
            jq -nc --arg label "$label" '{labels: [$label]}' |
                gh api --method POST "repos/$repo/issues/$number/labels" --input - >/dev/null
        else
            encoded_label="$(jq -rn --arg label "$label" '$label | @uri')"
            gh api --method DELETE "repos/$repo/issues/$number/labels/$encoded_label" >/dev/null
        fi
    }

    # GitHub exposes no conditional mutation that means "remove OLD only while
    # NEW is still present." Keep the safe ordering explicit: add NEW, verify
    # both labels, re-read both labels immediately before removing OLD, remove
    # OLD, then verify the result. A concurrent writer can still change labels
    # between that final read and the remove request; the API has no transaction
    # or compare-and-swap token for this boundary, so the post-remove check can
    # detect a bad result but cannot undo a successful concurrent removal.
    apply_migrations() {
        local i old new parent number kind item_id
        for i in "${!migration_old[@]}"; do
            [ "${migration_complete[$i]}" = 0 ] || continue
            old="${migration_old[$i]}"
            new="${migration_new[$i]}"
            parent="${migration_parent[$i]}"
            while IFS=$'\t' read -r -d '' number kind item_id; do
                if [ "$kind" = discussion ]; then
                    if [ -n "$parent" ]; then
                        edit_discussion_label add "$item_id" "$parent" ||
                            die "could not add family label '$parent' to discussion #$number; refusing further maintenance"
                    fi
                    edit_discussion_label add "$item_id" "$new" ||
                        die "could not add '$new' to discussion #$number; refusing further maintenance"
                    verify_migration_before_remove discussion "$number" "$item_id" "$old" "$new" "$parent" "after adding destination labels"
                    verify_migration_before_remove discussion "$number" "$item_id" "$old" "$new" "$parent" "immediately before removing '$old'"
                    edit_discussion_label remove "$item_id" "$old" ||
                        die "could not remove '$old' from discussion #$number; refusing further maintenance"
                else
                    if [ -n "$parent" ]; then
                        edit_issue_or_pr_label add "$number" "$parent" ||
                            die "could not add family label '$parent' to $kind #$number; refusing further maintenance"
                    fi
                    edit_issue_or_pr_label add "$number" "$new" ||
                        die "could not add '$new' to $kind #$number; refusing further maintenance"
                    verify_migration_before_remove "$kind" "$number" "" "$old" "$new" "$parent" "after adding destination labels"
                    verify_migration_before_remove "$kind" "$number" "" "$old" "$new" "$parent" "immediately before removing '$old'"
                    edit_issue_or_pr_label remove "$number" "$old" ||
                        die "could not remove '$old' from $kind #$number; refusing further maintenance"
                fi
                verify_migration_after_remove "$kind" "$number" "$item_id" "$old" "$new" "$parent"
                printf -v quoted_old '%q' "$old"
                printf -v quoted_new '%q' "$new"
                output_emit 'Migrated %s -> %s on %s #%s\n' "$quoted_old" "$quoted_new" "$kind" "$number"
            done < <(
                jq -j --arg old "$old" '
                    .[] | select(any(.labels[]; ascii_downcase == ($old | ascii_downcase))) |
                    [(.number | tostring), .kind, (.id // "")] |
                    join("\t") + "\u0000"
                ' "$associations_json"
            )
        done
    }

    parse_migrations
    read_live_labels
    load_inventory
    read_associations
    collect_candidates
    print_report

    if [ "$report_unregistered" = 1 ]; then
        exit 0
    fi

    validate_migrations
    if [ "${#candidates[@]}" -eq 0 ]; then
        exit 0
    fi

    safe_candidate_count=0
    associated_candidate_found=0
    for i in "${!candidates[@]}"; do
        if [ "${candidate_issues[$i]}" -eq 0 ] && [ "${candidate_prs[$i]}" -eq 0 ] && [ "${candidate_discussions[$i]}" -eq 0 ]; then
            safe_candidate_count=$((safe_candidate_count + 1))
        elif ! is_migration_source "${candidates[$i]}"; then
            printf -v quoted_name '%q' "${candidates[$i]}"
            output_emit 'Refused: %s (issues: %s, PRs: %s, discussions: %s)\n' "$quoted_name" \
                "${candidate_issues[$i]}" "${candidate_prs[$i]}" "${candidate_discussions[$i]}"
            associated_candidate_found=1
        fi
    done
    print_migration_plan

    if [ "$associated_candidate_found" -ne 0 ] && [ "${#migration_old[@]}" -eq 0 ]; then
        output_emit '%s\n' 'No labels deleted because the report contained associated labels.'
        exit 1
    fi
    if [ "$safe_candidate_count" -eq 0 ] && [ "${#migration_old[@]}" -eq 0 ]; then
        exit 1
    fi
    if ! confirm_prune; then
        exit 1
    fi

    if [ "${#migration_old[@]}" -gt 0 ]; then
        create_missing_destinations
        apply_migrations
    fi

    # The report is only a plan. First preflight every label that could be
    # deleted after migration, before deleting any one of them. An initially
    # associated non-migration label remains refused by name even if it later
    # becomes empty; only labels that were safe in the report (or were made safe
    # by a requested migration) enter prune_candidates.
    read_live_labels
    for name in "${candidates[@]}"; do
        if ! live_label_exists "$name"; then
            die "label '$name' disappeared during preflight; refusing all label deletion"
        fi
    done
    read_associations
    prune_candidates=()
    refused=0
    for i in "${!candidates[@]}"; do
        name="${candidates[$i]}"
        counts="$(association_counts "${candidates[$i]}")"
        IFS=$'\t' read -r issue_count pr_count discussion_count <<<"$counts"
        if { [ "${candidate_issues[$i]}" -ne 0 ] || [ "${candidate_prs[$i]}" -ne 0 ] || [ "${candidate_discussions[$i]}" -ne 0 ]; } &&
            ! is_migration_source "$name"; then
            printf -v quoted_name '%q' "$name"
            output_emit 'Refused: %s (issues: %s, PRs: %s, discussions: %s)\n' "$quoted_name" \
                "${candidate_issues[$i]}" "${candidate_prs[$i]}" "${candidate_discussions[$i]}"
            refused=1
            continue
        fi
        if [ "$issue_count" -ne 0 ] || [ "$pr_count" -ne 0 ] || [ "$discussion_count" -ne 0 ]; then
            die "association drift detected for '$name' before deletion; refusing all label deletion"
        fi
        prune_candidates+=("$name")
    done

    if [ "${#prune_candidates[@]}" -eq 0 ]; then
        exit 1
    fi
    if [ "$refused" -ne 0 ]; then
        output_emit '%s\n' 'No labels deleted because the preflight contained refused labels.'
        exit 1
    fi

    # The complete preflight above is deliberately one bounded snapshot for the
    # whole deletion batch. Re-scanning every issue, PR, and discussion before
    # every candidate makes API work grow with candidates × repository history
    # and can exhaust quota after partial deletion. The required quiescent
    # window keeps this bounded plan meaningful; GitHub still offers no atomic
    # read/delete primitive for the narrow final boundary.
    for name in "${prune_candidates[@]}"; do
        if ! gh label delete --repo "$repo" --yes -- "$name"; then
            die "could not delete '$name'; refusing further maintenance"
        fi
        printf -v quoted_name '%q' "$name"
        output_emit 'Deleted: %s\n' "$quoted_name"
    done

    output_emit '%s\n' 'Label retirement complete.'
    exit 0
fi

action_banner setup "GitHub labels" "Registry-driven taxonomy with non-destructive updates"
kv "Repository" "$repo"

# Render first, then provision: the renderer fails closed (bad manifest, name
# or description over GitHub's limits, registry color drift) BEFORE any label
# reaches GitHub, so a bad vocabulary never half-provisions.
labels="$(node "$renderer" "${render_args[@]}")"

while IFS='|' read -r name color desc; do
    [ -z "$name" ] && continue
    if gh label create "$name" --repo "$repo" --color "$color" --description "$desc" --force >/dev/null; then
        checkline ok "Label" "$name"
    else
        rc=$?
        checkline no "Label" "$name (exit $rc)"
        exit "$rc"
    fi
done < <(printf '%s\n' "$labels")

output_summary "Label provisioning"
output_done "Starter labels are ready on $repo (existing labels left as-is)"
