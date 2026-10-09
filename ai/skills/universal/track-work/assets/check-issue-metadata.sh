#!/usr/bin/env bash
# check-issue-metadata.sh — validate an issue draft and its proposed metadata
# before `gh issue create`. This script is deliberately read-only: it reads the
# target checkout's label registries and bounded live label listings when needed,
# and never calls a GitHub write endpoint.
set -euo pipefail

FORBIDDEN_RE='^(foreman:|rigor:|tier:pinned$|tier:|strategy:|method:|claim:|agent:|priority:|effort:)'
asset_dir="$(cd "$(dirname "$0")" && pwd -P)"
title_module_dir="$asset_dir/../../issue-title-support/assets"

help_text() {
    cat <<'EOF'
Usage: check-issue-metadata.sh --repo [HOST/]OWNER/REPO --repo-root PATH
          --owner-type personal|organization
          --title TITLE --body-file PATH [--label LABEL]...
          [--work-type-label LABEL]
          [--issue-type TYPE] (--agent-authored|--human-authored)
          [--inapplicable AXIS]...
          [--impact VALUE --risk VALUE --complexity VALUE]

       check-issue-metadata.sh --required-axes --repo [HOST/]OWNER/REPO [--repo-root PATH]

       check-issue-metadata.sh --title-only --title TITLE [--previous-title PREV_TITLE]

Validates a proposed issue without writing to GitHub. The target checkout's
label-registry.json is authoritative when present; otherwise the checker makes
one bounded `gh label list --limit 1000` vocabulary read against --repo. Agent
drafts also read labels independently through `classification-axes` for the
provisioned rating catalogue. The checkout must have a GitHub remote matching --repo. A proposed member of a manifest
`open_values` family also uses one bounded label read to prove that concrete
label exists; the manifest still supplies its policy.

Personal-account example:
  check-issue-metadata.sh --repo me/project --repo-root . --owner-type personal \
    --title '(cache): Reject stale entries' --body-file issue.md \
    --work-type-label bug --label area:build --label layer:none \
    --label domain:platform --label impact:medium --label risk:low \
    --label complexity:s --label ai-generated --agent-authored

Organization example:
  check-issue-metadata.sh --repo org/project --repo-root . --owner-type organization \
    --issue-type Bug --title '(cache): Reject stale entries' --body-file issue.md \
    --label area:build --inapplicable layer --label domain:platform --human-authored

Organization field proposals use --impact/--risk/--complexity; personal
proposals use impact:*/risk:*/complexity:* labels. Agent drafts require all
three, a work type, and each active exclusive classification prefix from the
manifest (area/layer/domain without a manifest; explicit none is a value).
Human drafts are exempt from completeness. Agent --inapplicable is accepted only
when a valid present manifest has no agent-writable axis:none member; the created
issue then needs needs-triage. Otherwise agent drafts must use the axis:none label.
Every creation recipe reserves needs-triage for incomplete filing or a failed
classification write; preflight verifies its existence and agent writer policy
separately from draft authorship. The sibling triage/assets/triage-apply.sh
supplies classification values.

--required-axes prints the same required-axis set used by agent preflight as
JSON, including family, agent_writable_value and agent_writable_none. It reads
the local manifest when --repo-root is given, otherwise the target default-branch
manifest via gh. Active classification families must be closed, prefixed and
nonreserved; any family triage cannot govern is refused before filing.
Availability is null when
only the canonical fallback supplies policy;
false means the validated manifest offers no agent-writable value. Missing
manifests retain the canonical fallback; unreadable or invalid manifests refuse.

Title-only example (for a proposed retitle):
  check-issue-metadata.sh --title-only --title '(cache): Reject stale entries' \
    --previous-title '(cache): Reject stale entries when cache is cold'

Exit: 0 = verified, 1 = authoring-contract violation,
      2 = usage error or indeterminate repository/vocabulary read.
EOF
}

usage() {
    help_text >&2
    exit 2
}

die() {
    echo "check-issue-metadata: $*" >&2
    exit 2
}

violations=0
violation() {
    echo "check-issue-metadata: $*" >&2
    violations=1
}

warn() {
    echo "check-issue-metadata: warning: $*" >&2
}

load_required_axis_contract() {
    tmp="$(mktemp -d)" || die "cannot create temporary directory"
    trap 'rm -rf "$tmp"' EXIT
    vocab="$tmp/vocabulary"
    : >"$vocab"
    manifest="$repo_root/label-registry.json"
    if [ -z "$repo_root" ]; then
        manifest="$tmp/remote-label-registry.json"
        if ! repo_api "repos/$repo_slug/contents/label-registry.json" \
            -H 'Accept: application/vnd.github.raw+json' >"$manifest" 2>"$tmp/manifest-read-error"; then
            if grep -qF '(HTTP 404)' "$tmp/manifest-read-error"; then
                # Only an authorized Contents listing can prove absence.
                repo_api "repos/$repo_slug/contents/" >"$tmp/root-contents" 2>/dev/null &&
                    jq -e 'type == "array" and
                      all(.[]; type == "object" and (.name | type == "string")) and
                      all(.[]; .name != "label-registry.json")' "$tmp/root-contents" >/dev/null ||
                    die "remote label-registry.json is unreadable"
                if jq -e 'length >= 1000' "$tmp/root-contents" >/dev/null; then
                    die "remote label-registry.json is unreadable; the root listing may be truncated (1000 or more entries)"
                fi
                rm "$manifest"
            else
                die "remote label-registry.json is unreadable"
            fi
        fi
    fi
    registry_records="$tmp/registry-records"
    : >"$registry_records"
    required_axes="$tmp/required-axes"
    required_families="$tmp/required-families"
    printf '%s\n' area layer domain >"$required_axes"
    printf '%s\n' 'area|area' 'layer|layer' 'domain|domain' >"$required_families"
    registry_helper="$asset_dir/../../label-registry-support/assets/label-registry.sh"
    [ -x "$registry_helper" ] ||
        die "shared label-registry interpreter is missing: $registry_helper"

    if [ -e "$manifest" ] || [ -L "$manifest" ]; then
        [ -f "$manifest" ] && [ -r "$manifest" ] ||
            die "label-registry.json is present but unreadable"
        "$registry_helper" render "$manifest" >"$registry_records" ||
            die "label-registry.json is present but invalid"

        # Match triage's render_manifest refusal before exposing any axes.
        ungovernable="$(awk -F '|' '$1 == "family" && $4 == "classification" &&
          $9 == "false" && ($3 == "" || $8 == "true" ||
          $3 ~ /^(foreman|rigor|tier|strategy|method|claim|agent|priority|effort)$/) {
            print $2
          }' "$registry_records" | paste -sd ', ' -)"
        [ -z "$ungovernable" ] ||
            die "classification families triage cannot govern (prefix-less, open-values, or reserved prefix): $ungovernable; use closed families with nonreserved prefixes before filing"

        # Match triage's axes_active rule: prefixes, not family names, define
        # active exclusive label classification axes. Ratings use separate storage.
        awk -F '|' '$1 == "family" && $4 == "classification" &&
          $6 == "true" && $9 == "false" && $3 != "" &&
          $3 !~ /^(impact|risk|complexity|priority-ai)$/ { print $3 "|" $2 }
        ' "$registry_records" | sort -u >"$required_families"
        ambiguity="$(awk -F '|' '
          FILENAME == ARGV[1] { if (!($1 in required)) required[$1]=$2; next }
          $1 == "family" && $9 == "false" && $3 in required && required[$3] != $2 {
            print "families " required[$3] " and " $2 " share prefix " $3;
            exit
          }
        ' "$required_families" "$registry_records")"
        [ -z "$ambiguity" ] ||
            die "$ambiguity; assign distinct prefixes before filing or discovering required axes"
        awk -F '|' '{ print $1 }' "$required_families" | sort -u >"$required_axes"

        awk -F '|' '
          $1 == "value" && $8 != "agent-registry" &&
          $10 == "false" && $11 == "false" {
            print $2 "|" $3 "|" $5 "|" $6 "|" $7
          }
        ' "$registry_records" >"$vocab"

    fi

}

# Both discovery and enforcement use this bounded, truncation-guarded listing.
read_live_labels() {
    local listing count
    listing="$(gh label list --repo "$repo" --limit 1000 --json name -q '.[].name')" || return 2
    count="$(printf '%s\n' "$listing" | grep -c . || true)"
    if [ "$count" -ge 1000 ]; then
        warn "the repo reports $count labels — the fetch may be truncated; use a complete label listing before creation"
        return 2
    fi
    printf '%s\n' "$listing"
}

live_label_exists() {
    printf '%s\n' "$live" | awk -v wanted="$1" '
      tolower($0) == tolower(wanted) { found=1 }
      END { exit(found ? 0 : 1) }'
}

# Required families are closed: none uses active enumerated author policy.
none_available() {
    local axis="$1" author="$2" family
    family="$(required_none_family "$axis:none")"
    [ -e "$manifest" ] || return 2
    if [ "$author" = human ] && awk -F '|' -v wanted="$axis:none" -v family="$family" '
      tolower($1) == wanted && $2 == family &&
      index("," $4 ",", ",trusted-human,") && !index("," $4 ",", ",human,") { found=1 }
      END { exit(found ? 0 : 1) }' "$vocab"; then
        die "label '$axis:none' requires an actor-verifying trusted-human workflow"
    fi
    awk -F '|' -v wanted="$axis:none" -v family="$family" -v author="$author" '
      tolower($1) == wanted && $2 == family &&
      index("," $4 ",", "," author ",") { found=1 }
      END { exit(found ? 0 : 1) }' "$vocab"
}

required_none_family() {
    awk -F '|' -v label="$1" 'tolower($1 ":none") == label { print $2; exit }' "$required_families"
}

# Keep the caller's --repo spelling for gh label/issue/repo; API paths use
# owner/repo, with an explicit host only when the caller supplied one.
parse_target_repo() {
    grep -Eq '^([^/[:space:]]+/)?[^/[:space:]]+/[^/[:space:]]+$' <<<"$repo" ||
        die "--repo must be [HOST/]OWNER/REPO (got '$repo')"
    repo_host=""
    repo_slug="$repo"
    case "$repo" in
    */*/*)
        repo_host="${repo%%/*}"
        repo_slug="${repo#*/}"
        ;;
    esac
}

repo_api() {
    if [ -n "$repo_host" ]; then
        gh api "$@" --hostname "$repo_host"
    else
        gh api "$@"
    fi
}

normalize_github_remote() {
    local _remote="$1" _host _path _rest _scheme_url=0
    case "$_remote" in
    https://*/* | http://*/* | ssh://*/*)
        _rest="${_remote#*://}"
        _host="${_rest%%/*}"
        _path="${_rest#*/}"
        _scheme_url=1
        ;;
    *://*) return 1 ;;
    *:*)
        _host="${_remote%%:*}"
        _path="${_remote#*:}"
        ;;
    *) return 1 ;;
    esac
    _host="${_host##*@}"
    # IP-literal hosts are unsupported and fail closed.
    case "$_host" in
    *'['* | *']'*) return 1 ;;
    esac
    if [ "$_scheme_url" -eq 1 ]; then
        case "${_host##*:}" in
        '' | *[!0-9]*) ;;
        *) _host="${_host%:*}" ;;
        esac
    fi
    _host="$(printf '%s' "$_host" | tr '[:upper:]' '[:lower:]')"
    _path="$(printf '%s' "$_path" | tr '[:upper:]' '[:lower:]')"
    [ "$_host" != ssh.github.com ] || _host=github.com
    while [ "${_path%/}" != "$_path" ]; do
        _path="${_path%/}"
    done
    _path="${_path%.git}"
    [ -n "$_host" ] && [ -n "$_path" ] || return 1
    printf '%s/%s\n' "$_host" "$_path"
}

bind_target_checkout() {
    local target_repo repo_bound remote_names remote_name remote_url remote_repo
    target_repo="$(printf '%s\n' "${repo_host:-github.com}/$repo_slug" | tr '[:upper:]' '[:lower:]')"
    repo_bound=0
    remote_names="$(git -C "$repo_root" remote 2>/dev/null)" ||
        die "target repository root is not a readable Git checkout"
    for remote_name in $remote_names; do
        remote_url="$(git -C "$repo_root" remote get-url "$remote_name" 2>/dev/null)" || continue
        remote_repo="$(normalize_github_remote "$remote_url" || true)"
        [ "$remote_repo" = "$target_repo" ] && repo_bound=1
    done
    [ "$repo_bound" -eq 1 ] ||
        die "target repository root has no GitHub remote matching --repo $repo"
    # Resolve the checkout's top level: `--repo-root .` from a subdirectory binds
    # the same remotes but would look for the manifest beside the subdirectory,
    # silently bypassing an authoritative top-level label-registry.json in favor
    # of the weaker live-label fallback.
    repo_root="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)" ||
        die "could not resolve the target checkout's top-level directory"
    [ -n "$repo_root" ] && [ -d "$repo_root" ] ||
        die "could not resolve the target checkout's top-level directory"
}

repo=""
repo_root=""
owner_type=""
title=""
title_set=0
title_only=0
required_axes_only=0
previous_title=""
previous_title_set=0
body_file=""
issue_type=""
work_type_label=""
author_type=""
impact=""
risk=""
complexity=""
labels=()
inapplicable=()

while [ "$#" -gt 0 ]; do
    case "$1" in
    -h | --help)
        help_text
        exit 0
        ;;
    --repo | --repo-root | --owner-type | --title | --body-file | --issue-type | --work-type-label | --label | --inapplicable | --previous-title | --impact | --risk | --complexity)
        [ "$#" -ge 2 ] || usage
        case "$1" in
        --repo) repo="$2" ;;
        --repo-root) repo_root="$2" ;;
        --owner-type) owner_type="$2" ;;
        --title)
            title="$2"
            title_set=1
            ;;
        --previous-title)
            [ -n "$2" ] || die "--previous-title requires a non-empty title argument"
            previous_title="$2"
            previous_title_set=1
            ;;
        --body-file) body_file="$2" ;;
        --issue-type) issue_type="$2" ;;
        --work-type-label) work_type_label="$2" ;;
        --impact | --risk | --complexity)
            [ -n "$2" ] || die "$1 requires a non-empty value"
            case "$1" in
            --impact)
                [ -z "$impact" ] || die "--impact is repeated"
                impact="$2"
                ;;
            --risk)
                [ -z "$risk" ] || die "--risk is repeated"
                risk="$2"
                ;;
            --complexity)
                [ -z "$complexity" ] || die "--complexity is repeated"
                complexity="$2"
                ;;
            esac
            ;;
        --label) labels+=("$2") ;;
        --inapplicable) inapplicable+=("$2") ;;
        esac
        shift 2
        ;;
    --agent-authored)
        [ -z "$author_type" ] || die "choose exactly one author type"
        author_type="agent"
        shift
        ;;
    --human-authored)
        [ -z "$author_type" ] || die "choose exactly one author type"
        author_type="human"
        shift
        ;;
    --required-axes)
        required_axes_only=1
        shift
        ;;
    --title-only)
        title_only=1
        shift
        ;;
    *) usage ;;
    esac
done

validate_title() {
    [ -r "$title_module_dir/issue-title.jq" ] ||
        die "shared issue-title predicate is missing"
    local diag_json rc=0
    diag_json="$(jq -n -L "$title_module_dir" --arg value "$title" \
        'include "issue-title"; $value | issue_title_diagnostics' 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$diag_json" ]; then
        die "could not evaluate the shared issue-title predicate"
    fi

    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        warn "$line"
    done < <(jq -r '.warnings[]' <<<"$diag_json")

    local err_count=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        violation "$line"
        err_count=$((err_count + 1))
    done < <(jq -r '.errors[]' <<<"$diag_json")

    if [ "$err_count" -eq 0 ]; then
        local is_valid
        is_valid="$(jq -r '.valid' <<<"$diag_json")"
        if [ "$is_valid" != "true" ]; then
            violation "title violates the canonical '(scope): imperative outcome' contract"
        fi
    fi
}

validate_previous_title() {
    [ -r "$title_module_dir/issue-title.jq" ] ||
        die "shared issue-title predicate is missing"
    local is_trunc rc=0
    is_trunc="$(jq -r -n -L "$title_module_dir" \
        --arg prop "$title" --arg prev "$previous_title" \
        'include "issue-title"; $prop | issue_title_is_truncation($prev)' 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        die "could not evaluate truncation against previous title"
    fi
    if [ "$is_trunc" = "true" ]; then
        violation "proposed title is a truncated prefix of the previous title (rewrite to shorten; never truncate)"
    fi
}

if [ "$title_only" -eq 1 ]; then
    [ "$required_axes_only" -eq 0 ] || usage
    [ "$title_set" -eq 1 ] || usage
    [ -z "$repo$repo_root$owner_type$body_file$issue_type$work_type_label$author_type$impact$risk$complexity" ] ||
        die "--title-only accepts only --title and optional --previous-title"
    [ "${#labels[@]}" -eq 0 ] && [ "${#inapplicable[@]}" -eq 0 ] ||
        die "--title-only accepts only --title and optional --previous-title"
    validate_title
    if [ "$previous_title_set" -eq 1 ]; then
        validate_previous_title
    fi
    [ "$violations" -eq 0 ] || exit 1
    echo "check-issue-metadata: issue title verified"
    exit 0
fi

if [ "$required_axes_only" -eq 1 ]; then
    [ -n "$repo" ] || usage
    [ -z "$owner_type$body_file$issue_type$work_type_label$author_type$impact$risk$complexity" ] &&
        [ "$title_set" -eq 0 ] && [ "$previous_title_set" -eq 0 ] &&
        [ "${#labels[@]}" -eq 0 ] && [ "${#inapplicable[@]}" -eq 0 ] || usage
    parse_target_repo
    if [ -n "$repo_root" ]; then
        [ -d "$repo_root" ] || die "target repository root is not a directory: $repo_root"
        repo_root="$(cd "$repo_root" && pwd -P)" || die "cannot resolve target repository root"
        bind_target_checkout
    fi
    load_required_axis_contract
    axis_source=manifest
    [ -e "$manifest" ] || axis_source=canonical-fallback
    none_availability="$tmp/none-availability"
    : >"$none_availability"
    while IFS='|' read -r axis family; do
        none_status=0
        none_available "$axis" agent || none_status=$?
        case "$none_status" in
        0) available=true ;;
        1) available=false ;;
        *) available=null ;;
        esac
        printf '%s|%s\n' "$axis" "$available" >>"$none_availability"
    done <"$required_families"
    jq -n --rawfile none "$none_availability" --arg source "$axis_source" --rawfile required "$required_families" \
        --rawfile vocabulary "$vocab" '
      def records: split("\n") | map(select(length > 0) | split("|"));
      def agent: (. // "") | split(",") | index("agent") != null;
      ($vocabulary | records) as $values |
      {source: $source, axes: [($required | records)[] |
        .[0] as $axis | .[1] as $family |
        {axis: $axis, family: $family,
         agent_writable_value:
           (if $source == "canonical-fallback" then null
           elif any($values[]; .[1] == $family and (.[3] | agent)) then true
           else false end),
         agent_writable_none:
           ([$none | records | .[] | select(.[0] == $axis) | .[1] | fromjson][0])} ]}
    '
    exit 0
fi

if [ -n "$work_type_label" ]; then
    labels+=("$work_type_label")
fi

[ -n "$repo" ] && [ -n "$repo_root" ] && [ -n "$owner_type" ] &&
    [ "$title_set" -eq 1 ] &&
    [ -n "$body_file" ] && [ -n "$author_type" ] || usage
parse_target_repo
case "$owner_type" in
personal | organization) ;;
*) die "--owner-type must be personal or organization" ;;
esac
[ -d "$repo_root" ] || die "target repository root is not a directory: $repo_root"
repo_root="$(cd "$repo_root" && pwd -P)" || die "cannot resolve target repository root"
[ -f "$body_file" ] && [ -r "$body_file" ] || die "cannot read body draft: $body_file"

bind_target_checkout

for label in "${labels[@]+"${labels[@]}"}"; do
    [ -n "$label" ] || die "--label cannot be empty"
    case "$label" in
    *','* | *'|'* | *$'\n'* | *$'\r'*) die "invalid label value: '$label'" ;;
    esac
done

load_required_axis_contract
live_read=0
if [ -e "$manifest" ]; then
    # Retired members of active families are excluded from the vocabulary,
    # and the open-value fallback below must not resurrect one from its live
    # label: the manifest retiring a value is an authoritative "no".
    retired_members="$tmp/retired-members"
    awk -F '|' '
      $1 == "value" && $10 == "false" && $11 == "true" { print $2 }
    ' "$registry_records" >"$retired_members"

    # Open-value families define policy in the manifest but not every concrete
    # label name. Resolve only proposed members against one bounded live read;
    # the manifest remains authoritative for family, axis, writers, and
    # exclusivity, while GitHub supplies existence for the specific value.
    open_families="$tmp/open-families"
    awk -F '|' '
      $1 == "family" && $7 != "agent-registry" && $8 == "true" &&
      $9 == "false" && $3 != "" {
        print $3 "|" $2 "|" $4 "|" $5 "|" $6
      }
    ' "$registry_records" >"$open_families"
    open_candidates="$tmp/open-candidates"
    : >"$open_candidates"
    for label in "${labels[@]+"${labels[@]}"}"; do
        label_key="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
        # A label matching more than one active open family has no unique
        # authorization policy — the manifest model does not forbid two open
        # families sharing a prefix, and picking one by manifest order would
        # let a permissive sibling authorize a label a stricter family
        # governs. Ambiguity fails closed as indeterminate.
        matched_families=""
        matched_count=0
        matched_record=""
        while IFS='|' read -r prefix family axis writers exclusive; do
            [ -n "$prefix" ] || continue
            prefix_key="$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')"
            case "$label_key" in
            "$prefix_key":*)
                matched_count=$((matched_count + 1))
                matched_families="${matched_families}${matched_families:+, }$family"
                matched_record="$label|$family|$axis|$writers|$exclusive"
                ;;
            esac
        done <"$open_families"
        [ "$matched_count" -le 1 ] ||
            die "label '$label' matches multiple open-value families ($matched_families); the manifest gives it no unique policy"
        if [ "$matched_count" -eq 1 ] && grep -ixqF -- "$label" "$retired_members"; then
            violation "label '$label' is retired by the manifest"
            continue
        fi
        if [ "$matched_count" -eq 1 ]; then
            # The same ambiguity exists between an open family and a concrete
            # record: a different family enumerating this exact name would
            # otherwise silently supply the writers and exclusivity the open
            # family is documented to own. The one non-ambiguous overlap is
            # the open family enumerating some of its own members — a value
            # record there is that family's own per-value refinement.
            open_family="${matched_record#*|}"
            open_family="${open_family%%|*}"
            concrete_family="$(awk -F '|' -v wanted="$label_key" \
                'tolower($1) == wanted { print $2; exit }' "$vocab")"
            if [ -n "$concrete_family" ] && [ "$concrete_family" != "$open_family" ]; then
                die "label '$label' is enumerated by family '$concrete_family' and covered by open-value family '$open_family'; the manifest gives it no unique policy"
            fi
            printf '%s\n' "$matched_record" >>"$open_candidates"
        fi
    done
    if [ -s "$open_candidates" ]; then
        live="$(read_live_labels)" ||
            die "could not read open-value labels from the target repository"
        live_read=1
        while IFS='|' read -r label family axis writers exclusive; do
            label_key="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
            if ! live_label_exists "$label_key"; then
                # Open families opt into live existence: a proposed member the
                # bounded read cannot find must not validate, including one
                # the family itself enumerates for a per-value policy — the
                # ambiguity guard above guarantees any existing record for
                # this name is that same family's own, so dropping it makes
                # the absent label fail as unknown instead of passing stale.
                awk -F '|' -v wanted="$label_key" 'tolower($1) != wanted' "$vocab" >"$vocab.pruned" &&
                    mv "$vocab.pruned" "$vocab" ||
                    die "could not prune an absent open-value label from the vocabulary"
                continue
            fi
            awk -F '|' -v wanted="$label_key" 'tolower($1) == wanted { found=1 } END { exit(found ? 0 : 1) }' "$vocab" ||
                printf '%s|%s|%s|%s|%s\n' \
                    "$label" "$family" "$axis" "$writers" "$exclusive" >>"$vocab"
        done <"$open_candidates"
    fi

else
    live="$(read_live_labels)" ||
        die "could not read the target repository's labels"
    live_read=1
    while IFS= read -r label; do
        [ -n "$label" ] || continue
        # Proposed labels reject the record delimiter, so a live label that
        # contains it can never be selected. Ignore it instead of allowing it
        # to forge the family/writer fields of a second record.
        case "$label" in
        *'|'*) continue ;;
        esac
        label_key="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
        case "$label_key" in
        area:*) printf '%s|area|classification|human,agent|true\n' "$label" ;;
        layer:*) printf '%s|layer|classification|human,agent|true\n' "$label" ;;
        domain:*) printf '%s|domain|classification|human,agent|true\n' "$label" ;;
        ai-generated) printf '%s|provenance|provenance|human,agent|false\n' "$label" ;;
        needs-triage) printf '%s|workflow|workflow|human,agent|false\n' "$label" ;;
        human | umbrella) printf '%s|fallback-other|meta|human,agent|false\n' "$label" ;;
        *)
            if [ -n "$work_type_label" ] && [ "$label_key" = "$(printf '%s' "$work_type_label" | tr '[:upper:]' '[:lower:]')" ]; then
                printf '%s|work-type|work-type|human,agent|false\n' "$label"
            else
                printf '%s|fallback-other|meta|human|false\n' "$label"
            fi
            ;;
        esac
    done >"$vocab" <<EOF
$live
EOF
fi
sort -u "$vocab" -o "$vocab"

for axis in "${inapplicable[@]+"${inapplicable[@]}"}"; do
    grep -qxF -- "$axis" "$required_axes" ||
        die "--inapplicable requires an active classification prefix (got '$axis')"
    inapplicable_count=0
    for declared in "${inapplicable[@]+"${inapplicable[@]}"}"; do
        [ "$declared" = "$axis" ] && inapplicable_count=$((inapplicable_count + 1))
    done
    [ "$inapplicable_count" -le 1 ] || die "--inapplicable $axis is repeated"
done

# This is a filing operation by an agent even for human-authored content.
# Reserve the marker before creation: helper failure cannot be predicted, and
# every create-and-classify recipe must be able to mark its partial result.
marker_record="$(awk -F '|' 'tolower($1) == "needs-triage" { print; exit }' "$vocab")"
if [ -z "$marker_record" ]; then
    violation "filing marker 'needs-triage' does not exist in the target vocabulary; provision it before creation"
else
    IFS='|' read -r marker_name marker_family marker_axis marker_writers marker_exclusive <<EOF
$marker_record
EOF
    case ",$marker_writers," in
    *,agent,*) ;;
    *) violation "filing marker 'needs-triage' is not writable by an agent; ask the maintainer to authorize the filing path before creation" ;;
    esac
    [ "$marker_axis" = workflow ] ||
        violation "filing marker 'needs-triage' must have axis workflow (got '$marker_axis'); fix its manifest policy before creation"
    [ "$marker_exclusive" = false ] ||
        violation "filing marker 'needs-triage' must be non-exclusive (got '$marker_exclusive'); fix its manifest policy before creation"
fi
if [ "$live_read" -eq 0 ]; then
    live="$(read_live_labels)" ||
        die "could not verify provisioning of filing marker 'needs-triage'"
fi
if ! printf '%s\n' "$live" | awk 'tolower($0) == "needs-triage" { found=1 }
  END { exit(found ? 0 : 1) }'; then
    violation "filing marker 'needs-triage' is not provisioned in the target repository; provision it before creation"
fi

if [ "$author_type" = agent ]; then
    for axis in "${inapplicable[@]+"${inapplicable[@]}"}"; do
        none_status=0
        none_available "$axis" agent || none_status=$?
        if [ "$none_status" -eq 1 ]; then
            warn "registry has no agent-writable '$axis:none' member; --inapplicable $axis needs needs-triage on the created issue"
        else
            violation "--inapplicable $axis requires a manifest with no agent-writable '$axis:none' member; use the \`$axis:none\` label"
        fi
    done
fi
if [ -n "${CHECK_ISSUE_METADATA_DEBUG:-}" ]; then
    {
        echo "--- vocabulary ($(wc -l <"$vocab") records) ---"
        cat "$vocab"
        echo "--- environment ---"
        echo "repo_root=$repo_root"
        jq --version
        (awk -W version 2>&1 || awk --version 2>&1) | head -1
        sort --version | head -1
    } >&2
fi

# --owner-type selects the classification interface, but it is not trusted as
# evidence about the target. Resolve the repository owner's actual account kind
# so a caller cannot make an organization repository accept a work-type label
# (or make a personal repository attempt native Issue Type validation).
actual_owner_type="$(repo_api "repos/$repo_slug" --jq '.owner.type' 2>/dev/null)" ||
    die "could not read the target repository owner's account type"
case "$actual_owner_type" in
User) actual_owner_type="personal" ;;
Organization) actual_owner_type="organization" ;;
*) die "target repository returned an unknown owner account type: $actual_owner_type" ;;
esac
if [ "$owner_type" != "$actual_owner_type" ]; then
    # Stop here: every later work-classification check would run down the
    # wrong owner branch — an Issue Type lookup against a user account fails
    # and would turn this actionable contract violation into an indeterminate
    # exit 2.
    violation "--owner-type $owner_type does not match target repository owner type $actual_owner_type"
    exit 1
fi

# Classification storage and provisioned rubric values belong to triage's
# shared reader, including on repositories whose label manifest predates these
# axes. Authoring validates proposals; only triage's apply path writes them.
classification_json=""
classification_requested=0
[ -z "$impact$risk$complexity" ] || classification_requested=1
for label in "${labels[@]+"${labels[@]}"}"; do
    case "$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')" in
    impact:* | risk:* | complexity:*) classification_requested=1 ;;
    esac
done
if [ "$author_type" = agent ] || [ "$classification_requested" -eq 1 ]; then
    classification_helper="$asset_dir/../../triage/assets/triage-apply.sh"
    [ -x "$classification_helper" ] ||
        die "shared classification reader is missing; vendor the triage skill alongside track-work"
    if [ -n "$repo_host" ]; then
        # The shared helper takes owner/repo; GH_HOST binds its REST, GraphQL
        # and label reads just as it does for breakdown's classification read.
        classification_json="$(GH_HOST="$repo_host" "$classification_helper" classification-axes --repo "$repo_slug")" ||
            die "could not read provisioned Impact, Risk and Complexity"
    else
        classification_json="$("$classification_helper" classification-axes --repo "$repo")" ||
            die "could not read provisioned Impact, Risk and Complexity"
    fi
    expected_storage=label
    [ "$owner_type" != organization ] || expected_storage=field
    expected_owner=User
    [ "$owner_type" != organization ] || expected_owner=Organization
    jq -e --arg storage "$expected_storage" --arg owner "$expected_owner" '
      .storage == $storage and .owner_type == $owner and
      (.axes | type == "object") and
      all(.axes.impact, .axes.risk, .axes.complexity;
          (.provisioned | type == "boolean") and
          (.values | type == "array") and all(.values[]; type == "string"))
    ' <<<"$classification_json" >/dev/null ||
        die "shared classification reader returned an invalid or mismatched catalogue"
fi
if [ "$owner_type" = personal ] && [ -n "$impact$risk$complexity" ]; then
    violation "personal repositories use impact:*/risk:*/complexity:* labels, not field flags"
fi

# Preserve source line numbers while reducing the body to Markdown structure.
# The shared parser accepts only the mechanized authoring profile: fenced
# examples are blanked, and a draft carrying raw HTML, HTML comments, or any
# other construct whose rendering a line-oriented parser cannot decide is a
# contract violation, with the parser naming each offending line.
visible_body="$tmp/visible-body"
parse_rc=0
bash "$asset_dir/parse-issue-markdown.sh" --structure "$body_file" >"$visible_body" 2>"$tmp/parse-err" || parse_rc=$?
if [ "$parse_rc" -eq 3 ]; then
    while IFS= read -r diagnostic; do
        violation "body is outside the authoring profile: ${diagnostic#parse-issue-markdown: }"
    done <"$tmp/parse-err"
    exit 1
elif [ "$parse_rc" -ne 0 ]; then
    cat "$tmp/parse-err" >&2
    die "could not parse issue body structure"
fi
rendered_tasks="$tmp/rendered-tasks"
printf '0:\n' >"$rendered_tasks"
bash "$asset_dir/parse-issue-markdown.sh" --tasks "$body_file" >>"$rendered_tasks" ||
    die "could not parse rendered issue tasks"

# Title syntax is mechanical. Whether the words form an imperative
# problem/outcome statement remains a semantic judgment owned by the prose.
validate_title
if [ "$previous_title_set" -eq 1 ]; then
    validate_previous_title
fi

# Enumerate level-two headings outside fenced code blocks. Unknown level-two
# headings are rejected: the contract is a skeleton, not a partial ordering
# into which competing section dialects can be inserted.
headings="$tmp/headings"
awk '
  function canonical(s, lower) {
    lower = tolower(s)
    if (lower == "problem") return "problem"
    if (lower ~ /^current violation \(observed [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)$/) return "current"
    if (lower == "acceptance criteria") return "acceptance"
    if (lower == "verify") return "verify"
    if (lower == "out of scope") return "out-of-scope"
    if (lower == "provenance") return "provenance"
    return "unknown"
  }
  # No fence tracking here: the structure pass replaces every fence delimiter
  # and interior line with a placeholder, so no heading-shaped line survives
  # from inside one.
  match($0, /^ ? ? ?##[[:space:]]+/) {
    text = substr($0, RSTART + RLENGTH)
    # A closing hash sequence counts only when whitespace precedes it —
    # CommonMark renders `## Problem#` with the hash as heading text.
    sub(/[[:space:]]+#+[[:space:]]*$/, "", text)
    sub(/[[:space:]]+$/, "", text)
    printf "%d|%s|%s\n", NR, canonical(text), text
  }
' "$visible_body" >"$headings"

if grep -q '|unknown|' "$headings"; then
    while IFS='|' read -r line kind text; do
        [ "$kind" = unknown ] && violation "body line $line has noncanonical level-two heading '$text'"
    done <"$headings"
fi

for required in problem acceptance; do
    count="$(awk -F '|' -v name="$required" '$2 == name { n++ } END { print n + 0 }' "$headings")"
    [ "$count" -eq 1 ] || violation "body requires exactly one $required heading (found $count)"
done
for optional in current verify out-of-scope provenance; do
    count="$(awk -F '|' -v name="$optional" '$2 == name { n++ } END { print n + 0 }' "$headings")"
    [ "$count" -le 1 ] || violation "body repeats the optional $optional heading"
done

order_error="$(awk -F '|' '
  BEGIN { rank["problem"]=1; rank["current"]=2; rank["acceptance"]=3;
          rank["verify"]=4; rank["out-of-scope"]=5; rank["provenance"]=6 }
  $2 != "unknown" { if (rank[$2] <= prior) { print $1; exit }; prior=rank[$2] }
' "$headings")"
[ -z "$order_error" ] || violation "canonical headings are duplicated or out of order at body line $order_error"

section_bounds() {
    _name="$1"
    _start="$(awk -F '|' -v name="$_name" '$2 == name { print $1; exit }' "$headings")"
    [ -n "$_start" ] || return 1
    _end="$(awk -F '|' -v start="$_start" '$1 > start { print $1; exit }' "$headings")"
    [ -n "$_end" ] || _end=2147483647
    printf '%s %s\n' "$_start" "$_end"
}

for required in problem acceptance; do
    bounds="$(section_bounds "$required" || true)"
    [ -n "$bounds" ] || continue
    start="${bounds%% *}"
    end="${bounds#* }"
    # Judged on the raw body, not the structure pass: a fence there is a
    # nonblank placeholder, which would let a section holding only an EMPTY
    # code block count as substantive. Delimiter-only lines are skipped, so a
    # fence's actual contents still count while its frame does not.
    substantive="$(awk -v start="$start" -v end="$end" '
      NR > start && NR < end && $0 !~ /^[[:space:]]*$/ &&
      $0 !~ /^[[:space:]]*(```|~~~)/ { print; exit }
    ' "$body_file")"
    [ -n "$substantive" ] || violation "$required section is empty"
done

bounds="$(section_bounds acceptance || true)"
if [ -n "$bounds" ]; then
    start="${bounds%% *}"
    end="${bounds#* }"
    acceptance_result="$(awk -F ':' -v start="$start" -v end="$end" '
      NR == FNR { rendered[$1] = 1; next }
      FNR <= start || FNR >= end { next }
      /^[[:space:]]*$/ { next }
      {
        line=$0
        if (rendered[FNR]) {
          criteria++
          match(line, /\[[ xX]\][[:space:]]+/)
          line=substr(line, RSTART + RLENGTH)
          lower=tolower(line)
          if (lower ~ /^\[human\][[:space:]]+/) human_criteria++
          if (lower !~ /^\[(ci|human)\][[:space:]]+/) bad_tag++
          else {
            sub(/^\[(ci|human)\][[:space:]]+/, "", lower)
            if (lower !~ /[^[:space:]]/) empty_description++
          }
          seen=1
          next
        }
        nested=line
        sub(/^[[:space:]]+/, "", nested)
        if (nested ~ /^([-*+]|[0-9]+[.)])[[:space:]]+\[[ xX]\][[:space:]]+/) { non_task++; next }
        if (nested ~ /^([-*+]|[0-9]+[.)])[[:space:]]+/) { non_task++; next }
        if (line ~ /^ ? ? ?([-*+]|[0-9]+[.)])[[:space:]]+/) { non_task++; next }
        if (seen && line ~ /^[[:space:]]+/) next
        non_task++
      }
      END { printf "%d %d %d %d %d\n", criteria + 0, bad_tag + 0,
                   non_task + 0, empty_description + 0, human_criteria + 0 }
    ' "$rendered_tasks" "$visible_body")"
    criteria="${acceptance_result%% *}"
    rest="${acceptance_result#* }"
    bad_tag="${rest%% *}"
    non_task="${rest#* }"
    empty_description="${non_task#* }"
    human_criteria="${empty_description#* }"
    empty_description="${empty_description%% *}"
    non_task="${non_task%% *}"
    [ "$criteria" -gt 0 ] || violation "acceptance criteria section needs at least one rendered task-list item"
    [ "$bad_tag" -eq 0 ] || violation "every acceptance criterion must begin with [CI] or [HUMAN]"
    [ "$non_task" -eq 0 ] || violation "acceptance criteria must be rendered task-list items, not prose or plain lists"
    [ "$empty_description" -eq 0 ] || violation "every acceptance criterion needs nonempty text after its [CI] or [HUMAN] tag"
    if [ "$author_type" = agent ] && [ "$((human_criteria * 2))" -gt "$criteria" ]; then
        printf '%s\n' "${labels[@]+"${labels[@]}"}" | grep -xF human >/dev/null ||
            violation "primarily human work (a majority of [HUMAN] criteria) requires label 'human' at creation"
    fi
fi

if [[ "$title" =~ ^\((HUMAN|QA)\):\  ]]; then
    for required_label in human umbrella; do
        printf '%s\n' "${labels[@]+"${labels[@]}"}" | grep -xF "$required_label" >/dev/null ||
            violation "a collector requires '$required_label' at creation"
    done
fi

rot_rc=0
rot_output="$("$asset_dir/check-issue-rot.sh" --repo-root "$repo_root" "$body_file" 2>&1)" || rot_rc=$?
case "$rot_rc" in
0) ;;
1) violation "perishable facts require a substantive Verify section: $rot_output" ;;
*) die "perishable-fact check was indeterminate: $rot_output" ;;
esac

# check-issue-rot.sh intentionally accepts Verify at any Markdown heading level.
# The authoring skeleton is narrower: when a perishable fact exists, Verify is
# the canonical level-two section. Mask every Verify-like heading and ask the
# existing rot checker whether the remaining draft still contains perishable
# evidence; this reuses its definition instead of copying its pattern list.
verify_count="$(awk -F '|' '$2 == "verify" { n++ } END { print n + 0 }' "$headings")"
current_count="$(awk -F '|' '$2 == "current" { n++ } END { print n + 0 }' "$headings")"
if [ "$current_count" -gt 0 ] && [ "$verify_count" -eq 0 ]; then
    violation "Current violation requires the canonical level-two ## Verify section"
fi
if [ "$verify_count" -eq 0 ]; then
    masked_body="$tmp/body-without-noncanonical-verify"
    awk '
      {
        lower=tolower($0)
        if (lower ~ /^ ? ? ?#+[[:space:]]+(verify|verification)([[:space:]]+#+)?[[:space:]]*$/) print "x" $0
        else print
      }
    ' "$body_file" >"$masked_body"
    masked_rc=0
    "$asset_dir/check-issue-rot.sh" --repo-root "$repo_root" "$masked_body" >/dev/null 2>&1 || masked_rc=$?
    case "$masked_rc" in
    0) ;;
    1) violation "perishable facts require the canonical level-two ## Verify section" ;;
    *) die "canonical Verify check was indeterminate" ;;
    esac
fi

has_ai_generated=0
has_needs_triage=0
work_type_count=0
impact_count=0
risk_count=0
complexity_count=0
seen_labels="$tmp/seen-labels"
: >"$seen_labels"

for label in "${labels[@]+"${labels[@]}"}"; do
    if grep -ixqF -- "$label" "$seen_labels"; then
        violation "label '$label' is proposed more than once"
        continue
    fi
    printf '%s\n' "$label" >>"$seen_labels"
    label_key="$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')"
    if grep -qiE "$FORBIDDEN_RE" <<<"$label"; then
        human_only=0
        case "$label_key" in
        priority:* | effort:*) [ "$author_type" != human ] || human_only=1 ;;
        esac
        if [ "$human_only" -ne 1 ]; then
            violation "label '$label' belongs to a forbidden authoring-time family"
            continue
        fi
    fi
    case "$label_key" in
    impact:* | risk:* | complexity:*)
        classification_axis="${label_key%%:*}"
        classification_value="${label_key#*:}"
        if [ "$owner_type" = organization ]; then
            violation "organization $classification_axis uses an issue field; pass --$classification_axis instead of '$label'"
        elif jq -e --arg a "$classification_axis" --arg v "$classification_value" '
          .axes[$a].provisioned and (.axes[$a].values | index($v) != null)
        ' <<<"$classification_json" >/dev/null; then
            case "$classification_axis" in
            impact) impact_count=$((impact_count + 1)) ;;
            risk) risk_count=$((risk_count + 1)) ;;
            complexity) complexity_count=$((complexity_count + 1)) ;;
            esac
        else
            violation "label '$label' is not a provisioned classification value"
        fi
        continue
        ;;
    esac
    none_family="$(required_none_family "$label_key")"
    if [ -n "$none_family" ] && [ -e "$manifest" ]; then
        if ! none_available "${label_key%:none}" "$author_type"; then
            article=an
            [ "$author_type" != human ] || article=a
            violation "label '$label' is not writable by $article $author_type (none member unavailable)"
            continue
        fi
    fi
    record="$(awk -F '|' -v wanted="$label_key" 'tolower($1) == wanted { print; exit }' "$vocab")"
    if [ -z "$record" ]; then
        violation "label '$label' does not exist in the target vocabulary"
        continue
    fi
    IFS='|' read -r _name family axis writers exclusive <<EOF
$record
EOF
    # The prefix regex above catches the well-known spellings, but the
    # manifest may declare a strategy or Foreman family under any prefix, and
    # a claim-shaped family under any axis it likes. The resolved
    # record's axis is the semantic class, so authoring-time rejection binds
    # to it as well: strategy, foreman, and model-routing labels are live
    # ownership or execution controls whatever they are named.
    case "$axis" in
    strategy | foreman | model)
        violation "label '$label' belongs to the authoring-forbidden '$axis' axis"
        continue
        ;;
    esac
    if [ "$author_type" = agent ]; then
        case ",$writers," in
        *,agent,*) ;;
        *) violation "label '$label' is not writable by an agent" ;;
        esac
    else
        case ",$writers," in
        *,human,*) ;;
        *,trusted-human,*)
            die "label '$label' requires an actor-verifying trusted-human workflow"
            ;;
        *) violation "label '$label' is not writable by a human author" ;;
        esac
    fi
    [ "$label_key" = ai-generated ] && has_ai_generated=1
    [ "$label_key" = needs-triage ] && has_needs_triage=1
    [ "$axis" = work-type ] && work_type_count=$((work_type_count + 1))
    if [ "$exclusive" = true ]; then
        family_count="$(awk -F '|' -v fam="$family" -v seen="$seen_labels" '
          BEGIN { while ((getline line < seen) > 0) selected[tolower(line)]=1 }
          selected[tolower($1)] && $2 == fam { n++ }
          END { print n + 0 }
        ' "$vocab")"
        [ "$family_count" -le 1 ] || violation "exclusive label family '$family' has $family_count proposed values"
    fi
done

if [ "$author_type" = agent ] && [ "$has_ai_generated" -ne 1 ]; then
    violation "agent-authored issues require the ai-generated label"
fi
case "$owner_type" in
personal)
    [ -z "$issue_type" ] || violation "personal-account repositories use a work-type label, not native Issue Type"
    if [ "$author_type" = agent ] || [ "$work_type_count" -gt 0 ]; then
        [ "$work_type_count" -eq 1 ] ||
            violation "personal-account repositories require exactly one work-type label (found $work_type_count)"
    fi
    ;;
organization)
    [ -z "$work_type_label" ] ||
        violation "organization repositories use native Issue Type, not --work-type-label"
    [ "$work_type_count" -eq 0 ] ||
        violation "organization repositories use native Issue Type and no work-type label"
    if grep -q '[^[:space:]]' <<<"$issue_type"; then
        repo_owner="${repo_slug%%/*}"
        native_types="$(repo_api "orgs/$repo_owner/issue-types" --jq '.[].name')" ||
            die "could not read native Issue Types for organization $repo_owner"
        if ! printf '%s\n' "$native_types" | awk -v wanted="$issue_type" '
          BEGIN { wanted=tolower(wanted) }
          tolower($0) == wanted { found=1 }
          END { exit(found ? 0 : 1) }
        '; then
            violation "native Issue Type '$issue_type' does not exist for organization $repo_owner"
        fi
    elif [ "$author_type" = agent ]; then
        violation "organization repositories require a native Issue Type"
    fi
    ;;
esac

for classification_axis in impact risk complexity; do
    if [ "$owner_type" = personal ]; then
        case "$classification_axis" in
        impact) classification_count="$impact_count" ;;
        risk) classification_count="$risk_count" ;;
        complexity) classification_count="$complexity_count" ;;
        esac
        if [ "$classification_count" -gt 1 ]; then
            violation "$classification_axis requires exactly one value (found $classification_count)"
        elif [ "$author_type" = agent ] && [ "$classification_count" -ne 1 ]; then
            violation "agent-authored drafts require $classification_axis (personal label)"
        fi
    else
        case "$classification_axis" in
        impact) classification_value="$impact" ;;
        risk) classification_value="$risk" ;;
        complexity) classification_value="$complexity" ;;
        esac
        if [ -n "$classification_value" ]; then
            if ! jq -e --arg a "$classification_axis" --arg v "$classification_value" '
              .axes[$a].provisioned and (.axes[$a].values | index($v) != null)
            ' <<<"$classification_json" >/dev/null; then
                canonical_value="$(jq -r --arg a "$classification_axis" --arg v "$classification_value" '
                  if .axes[$a].provisioned then
                    [.axes[$a].values[] | select(ascii_downcase == ($v | ascii_downcase))][0] // empty
                  else empty end
                ' <<<"$classification_json")"
                if [ -n "$canonical_value" ]; then
                    violation "--$classification_axis '$classification_value' is not canonical; use '$canonical_value'"
                else
                    violation "--$classification_axis is not a provisioned organization field value"
                fi
            fi
        elif [ "$author_type" = agent ]; then
            violation "agent-authored drafts require --$classification_axis (organization issue field)"
        fi
    fi
done

is_inapplicable() {
    _wanted="$1"
    for _axis in "${inapplicable[@]+"${inapplicable[@]}"}"; do
        [ "$_axis" = "$_wanted" ] && return 0
    done
    return 1
}

undecided=""
while IFS='|' read -r axis family; do
    [ -n "$axis" ] || continue
    count="$(awk -F '|' -v fam="$family" -v seen="$seen_labels" '
      BEGIN { while ((getline line < seen) > 0) selected[tolower(line)]=1 }
      selected[tolower($1)] && $2 == fam { n++ }
      END { print n + 0 }
    ' "$vocab")"
    if [ "$author_type" = agent ] && [ "$count" -gt 1 ]; then
        violation "$axis requires exactly one label (found $count)"
    fi
    if [ "$count" -gt 0 ] && is_inapplicable "$axis"; then
        violation "$axis cannot have both a label and an inapplicable declaration"
    elif [ "$count" -eq 0 ] && ! is_inapplicable "$axis"; then
        undecided="${undecided}${undecided:+, }$axis"
    fi
done <"$required_families"
if [ -n "$undecided" ] && [ "$author_type" = agent ]; then
    violation "agent-authored drafts require every classification axis ($undecided missing); choose a label or explicit none"
fi
if [ "$author_type" = agent ] && [ "$has_needs_triage" -eq 1 ]; then
    violation "agent-authored drafts must be fully classified; needs-triage is derived by the shared helper, never authored"
fi

if [ "$violations" -ne 0 ]; then
    exit 1
fi

echo "check-issue-metadata: issue draft and proposed metadata verified"
