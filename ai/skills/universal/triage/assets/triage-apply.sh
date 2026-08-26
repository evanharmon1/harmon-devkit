#!/usr/bin/env bash
# triage-apply.sh — the triage skill's ONLY issue-mutation path.
#
# Why a script: the triage skill is designed to be executed by cheap, simple
# models. Every rule that can be enforced mechanically is enforced here, so the
# model supplies classification judgment and nothing else. The skill contract
# (issue #455 / specs/issue-strategy.md in harmon-init) is:
#
#   v1 WRITES ONLY classification metadata, and only these:
#     - classification-axis labels (the manifest's `classification` families —
#       area:*/layer:*/domain:* on a default registry; whatever axes the
#       repo's registry declares otherwise)
#     - a work-type label (bug/feature/task/...) on PERSONAL-account repos only
#       (org repos use native issue Type instead)
#     - a native issue Type on ORGANIZATION repos only, selected from the
#       organization's enabled Types
#     - needs-triage — added freely, removed only when classification is
#       complete
#   v1 NEVER writes: foreman:*, rigor:*, tier:* (including scoped
#   tier:<role>:* — tier:orchestrator:*/tier:implementer:*/tier:reviewer:*),
#   strategy:*, method:* (the retired prefix strategy:* replaces — stays
#   reserved so a stale or hostile manifest cannot redefine it as
#   agent-writable), claim:*, suggest:*, agent:* (legacy claims), milestones,
#   closes, assignees, body/title edits. This script contains no code path for
#   any of those — the never-list is a regex refusal on top of the structural
#   absence.
#
# The write-allowlist, the active axes, and the recognized axis values are all
# read from the repo's label-registry.json manifest (values whose effective
# `writers` include "agent", within the v1 scope above), falling back to
# `gh label list` intersected with a hard-coded copy of the harmon-init
# template defaults where no manifest exists. An "evil" manifest cannot widen
# the scope: the never-list and the v1 scope filter are hard-coded and applied
# on top of it.
#
# Usage:
#   triage-apply.sh allowlist [--repo owner/repo] [--manifest PATH]
#   triage-apply.sh axes [--repo owner/repo] [--manifest PATH]
#   triage-apply.sh axis-values [--repo owner/repo] [--manifest PATH]
#   triage-apply.sh work-types [--repo owner/repo] [--manifest PATH]
#   triage-apply.sh native-type --repo owner/repo --issue N
#   triage-apply.sh native-types --repo owner/repo
#   triage-apply.sh label --repo owner/repo --issue N
#                   [--add LABEL]... [--native-type TYPE]
#                   [--remove needs-triage]
#                   [--inapplicable AXIS]... [--manifest PATH] [--execute]
#
# `native-type` is a read: it prints JSON with an explicit `state` (`set` or
# `unset`) and the exact Type `name` when set. It exists so the classifying
# model never needs raw `gh api` access — org-repo Type checks go through here.
#
# Dry-run is the DEFAULT: without --execute the script prints exactly what it
# would write and writes nothing. --execute additionally requires
# TRIAGE_EXECUTE=1 in the environment — the `task triage` wrapper sets it only
# for a supervised run, so a model cannot promote itself to write mode by
# adding a flag.
#
# --native-type TYPE is a best-effort fill of an observed-unset enabled
# organization Type. It is refused on personal repos and is validated before
# dry-run output or an execute mutation. The script re-reads immediately before
# writing and refuses an observed conflict, but GitHub exposes no conditional
# Type mutation: a concurrent writer in that final read-to-write window cannot
# be protected from an overwrite.
#
# --inapplicable AXIS (area|layer|domain) attests that the axis genuinely does
# not apply to the issue; it is consumed by the needs-triage removal gate and
# echoed in the output so the run's record shows the attestation.
#
# Exit: 0 = applied, or dry-run resolved cleanly (including nothing to do)
#       1 = the write failed
#       2 = usage/environment error (bad flags, --execute without the env gate,
#           could not verify something the gate needs)
#       4 = refused: never-list, allowlist, or exclusive-axis conflict
#       5 = refused: work-type label on an org repo, or native Type on a
#           personal repo
#       6 = refused: needs-triage removal while classification is incomplete
set -euo pipefail

NEVER_RE='^(foreman:|rigor:|tier:|strategy:|method:|claim:|suggest:|agent:)'
# Fallback vocabulary, used only when no manifest exists — a hard-coded copy of
# the harmon-init template's default label registry, so triage still applies
# reasonable labels on an unregistered repo. The manifest wins where present.
# `enhancement` is deliberately absent — it is the retired GitHub default this
# vocabulary replaces with `feature`.
FALLBACK_AXES='area layer domain'
FALLBACK_WORK_TYPES='bug feature task research documentation question'

usage() {
    echo "Usage: $0 allowlist [--repo owner/repo] [--manifest PATH]" >&2
    echo "       $0 axes [--repo owner/repo] [--manifest PATH]" >&2
    echo "       $0 axis-values [--repo owner/repo] [--manifest PATH]" >&2
    echo "       $0 work-types [--repo owner/repo] [--manifest PATH]" >&2
    echo "       $0 native-types --repo owner/repo" >&2
    echo "       $0 label --repo owner/repo --issue N [--add LABEL]..." >&2
    echo "           [--native-type TYPE]" >&2
    echo "           [--remove needs-triage] [--inapplicable AXIS]..." >&2
    echo "           [--manifest PATH] [--execute]" >&2
    exit 2
}

die() {
    local code="$1"
    shift
    echo "triage-apply: $*" >&2
    exit "$code"
}

asset_dir="$(cd "$(dirname "$0")" && pwd -P)"
registry_helper="$asset_dir/../../label-registry-support/assets/label-registry.sh"
[ -x "$registry_helper" ] ||
    die 2 "shared label-registry interpreter is missing or not executable at" \
        "'$registry_helper'"

render_manifest() {
    local manifest="$1" records bad
    records="$("$registry_helper" render "$manifest")" ||
        die 2 "refusing to derive from a registry v1 cannot govern"
    bad="$(printf '%s\n' "$records" |
        awk -F '|' '$1 == "family" && $4 == "classification" &&
            $9 == "false" &&
            ($3 == "" || $8 == "true" ||
             $3 ~ /^(foreman|rigor|tier|strategy|method|claim|suggest|agent)$/) {
                print $2
            }' | paste -sd ', ' -)"
    [ -z "$bad" ] ||
        die 2 "refusing to derive from classification families triage cannot" \
            "govern (prefix-less, open-values, or reserved prefix): $bad"
    printf '%s\n' "$records"
}

# In a bound run (TRIAGE_REPO set by the wrapper) the manifest is the repo's
# own ./label-registry.json and nothing else: the worker holds a scratch
# Write grant, so a caller-chosen manifest path would let a prompt-injected
# run author its own allowlist.
guard_manifest() {
    local manifest="$1"
    if [ -n "${TRIAGE_REPO:-}" ] && [ "$manifest" != "./label-registry.json" ]; then
        die 4 "refused: --manifest is fixed to ./label-registry.json in a" \
            "bound run — a worker-writable manifest would define its own allowlist"
    fi
}

# gh issue view/edit accept URLs as well as numbers, and a URL names its own
# repository — which would bypass the TRIAGE_REPO binding entirely. Numbers
# only.
guard_issue_number() {
    local issue="$1"
    case "$issue" in
    '' | *[!0-9]*) die 2 "refused: --issue must be a plain issue number (got '$issue')" ;;
    esac
}

# Fetch the complete live label set, one name per line. A page equal to the
# fetch limit may be truncated, and a hidden axis label would silently weaken
# the removal gate — refuse rather than derive from a partial vocabulary.
live_labels() {
    local repo="$1" live n
    live="$(gh label list --repo "$repo" --limit 1000 --json name \
        -q '.[].name')" ||
        die 2 "could not list the live labels of $repo"
    n="$(printf '%s\n' "$live" | grep -c . || true)"
    if [ "$n" -ge 1000 ]; then
        die 2 "the repo reports $n labels — the fetch may be truncated;" \
            "refusing to derive from a possibly partial label set"
    fi
    printf '%s\n' "$live"
}

# Print the active classification axes (label prefixes), one per line —
# derived from the manifest's EXCLUSIVE classification families (#485: only
# an at-most-one family is a completeness axis) so a repo that provisions
# only some axes is never asked to attest the missing ones. Fallback (no
# manifest): the harmon-init default prefixes intersected with the labels
# that actually exist live — an axis no live label carries is not demanded.
axes_active() {
    local repo="$1" manifest="$2" records
    if [ -f "$manifest" ]; then
        records="$(render_manifest "$manifest")"
        printf '%s\n' "$records" |
            awk -F '|' '$1 == "family" && $4 == "classification" &&
                $6 == "true" && $9 == "false" { print $3 }' |
            sort -u
    else
        [ -n "$repo" ] ||
            die 2 "no manifest at '$manifest' and no --repo for the gh fallback"
        local live a
        live="$(live_labels "$repo")"
        for a in $FALLBACK_AXES; do
            printf '%s\n' "$live" | grep -q "^$a:" && printf '%s\n' "$a"
        done
        return 0
    fi
}

# Print every RECOGNIZED axis label (full `prefix:value` names) of the active
# taxonomy, one per line. In manifest mode a live label outside this set
# (retired, misspelled) does NOT classify its axis — prefix presence alone is
# not classification. In fallback mode the live labels ARE the taxonomy, so
# every live label with an active axis prefix is recognized.
axis_values_recognized() {
    local repo="$1" manifest="$2" records
    if [ -f "$manifest" ]; then
        records="$(render_manifest "$manifest")"
        printf '%s\n' "$records" |
            awk -F '|' '$1 == "value" && $5 == "classification" &&
                $7 == "true" && $10 == "false" && $11 == "false" {
                    print $2
                }' |
            sort -u
    else
        [ -n "$repo" ] ||
            die 2 "no manifest at '$manifest' and no --repo for the gh fallback"
        local re
        re="$(axes_active "$repo" "$manifest" | paste -sd '|' -)"
        [ -n "$re" ] || return 0
        # gh failure must surface — an empty set born of an API error would
        # read every live axis label as unknown. Only grep's no-match status
        # is ignorable.
        local live
        live="$(live_labels "$repo")"
        printf '%s\n' "$live" | grep -E "^($re):" || true
    fi
}

# Print the v1 write-allowlist, one label per line.
allowlist_compute() {
    local repo="$1" manifest="$2" records
    if [ -f "$manifest" ]; then
        records="$(render_manifest "$manifest")"
        # v1 scope: the manifest's own classification families (any axis the
        # registry declares, not a fixed three), work-type, and needs-triage.
        printf '%s\n' "$records" |
            awk -F '|' '$1 == "value" && $10 == "false" && $11 == "false" &&
                ("," $6 ",") ~ /,agent,/ &&
                (($5 == "classification" && $7 == "true") ||
                 $5 == "work-type" ||
                 ($5 == "workflow" && $2 == "needs-triage")) {
                    print $2
                }' |
            sort -u
    else
        [ -n "$repo" ] ||
            die 2 "no manifest at '$manifest' and no --repo for the gh fallback"
        local live wt
        live="$(live_labels "$repo")"
        axis_values_recognized "$repo" "$manifest"
        for wt in $FALLBACK_WORK_TYPES needs-triage; do
            printf '%s\n' "$live" | grep -qx "$wt" && printf '%s\n' "$wt"
        done
        return 0
    fi
}

# Print every RECOGNIZED work-type value — the full non-retired work-type
# vocabulary, regardless of writers. Recognition and write permission are
# different questions: a human-applied work-type the manifest withholds from
# agents still classifies the issue, so the completeness checks read this
# set while additions stay bound to the agent-writable allowlist.
work_types_recognized() {
    local repo="$1" manifest="$2" records
    if [ -f "$manifest" ]; then
        records="$(render_manifest "$manifest")"
        printf '%s\n' "$records" |
            awk -F '|' '$1 == "value" && $5 == "work-type" &&
                $10 == "false" && $11 == "false" { print $2 }' |
            sort -u
    else
        [ -n "$repo" ] ||
            die 2 "no manifest at '$manifest' and no --repo for the gh fallback"
        local live wt
        live="$(live_labels "$repo")"
        for wt in $FALLBACK_WORK_TYPES; do
            printf '%s\n' "$live" | grep -qx "$wt" && printf '%s\n' "$wt"
        done
        return 0
    fi
}

cmd_work_types() {
    local repo="" manifest="./label-registry.json"
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        --manifest)
            [ "$#" -ge 2 ] || usage
            manifest="$2"
            shift 2
            ;;
        *) usage ;;
        esac
    done
    guard_manifest "$manifest"
    work_types_recognized "$repo" "$manifest"
}

cmd_axes() {
    local repo="" manifest="./label-registry.json"
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        --manifest)
            [ "$#" -ge 2 ] || usage
            manifest="$2"
            shift 2
            ;;
        *) usage ;;
        esac
    done
    guard_manifest "$manifest"
    axes_active "$repo" "$manifest"
}

cmd_axis_values() {
    local repo="" manifest="./label-registry.json"
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        --manifest)
            [ "$#" -ge 2 ] || usage
            manifest="$2"
            shift 2
            ;;
        *) usage ;;
        esac
    done
    guard_manifest "$manifest"
    axis_values_recognized "$repo" "$manifest"
}

cmd_allowlist() {
    local repo="" manifest="./label-registry.json"
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        --manifest)
            [ "$#" -ge 2 ] || usage
            manifest="$2"
            shift 2
            ;;
        *) usage ;;
        esac
    done
    guard_manifest "$manifest"
    allowlist_compute "$repo" "$manifest"
}

# in_list NEEDLE LINES — 0 when NEEDLE is one of the newline-separated LINES.
in_list() {
    printf '%s\n' "$2" | grep -qxF -- "$1"
}

# Print an unambiguous internal state: "unset" or "set:<name>". A prefix is
# required because organization-defined Type names may themselves be "none"
# or "null"; those names must never collide with the empty-slot sentinel.
# Non-zero means the state could not be read (missing scope, old GitHub,
# network), which callers must treat as unknown, never as absent.
native_type_state_read() {
    local repo="$1" issue="$2" native
    native="$(gh api graphql \
        -f query='query($o: String!, $r: String!, $n: Int!) {
            repository(owner: $o, name: $r) {
              issue(number: $n) { issueType { name } } } }' \
        -f o="${repo%%/*}" -f r="${repo#*/}" -F n="$issue" \
        -q 'if .data.repository.issue.issueType == null
            then "unset"
            else "set:\(.data.repository.issue.issueType.name)"
            end' 2>/dev/null)" || return 1
    case "$native" in
    unset | set:*) printf '%s\n' "$native" ;;
    *) return 1 ;;
    esac
}

# A successful Type mutation can be followed by a transient GraphQL read
# failure. Reconcile with a small bounded retry budget; callers must still
# treat exhaustion as indeterminate rather than assuming the write rolled back.
native_type_reconcile() {
    local repo="$1" issue="$2" attempts=0 native
    while [ "$attempts" -lt 3 ]; do
        native="$(native_type_state_read "$repo" "$issue")" && {
            printf '%s\n' "$native"
            return 0
        }
        attempts=$((attempts + 1))
    done
    return 1
}

# Print Type names available in the target repository, one per line. Types are
# organization-owned, but a repository can expose only a subset, so validate
# against the issue's actual target rather than the broader org vocabulary.
enabled_native_types() {
    local repo="$1" types
    types="$(gh api graphql \
        -f query='query($o: String!, $r: String!) {
            repository(owner: $o, name: $r) {
              issueTypes(first: 100) {
                totalCount
                nodes { name isEnabled }
              }
            }
          }' \
        -f o="${repo%%/*}" -f r="${repo#*/}" \
        -q 'if .data.repository.issueTypes.totalCount > 100
            then error("native issue Type result exceeds the validation limit")
            else .data.repository.issueTypes.nodes[] |
                 select(.isEnabled == true) | .name
            end' 2>/dev/null)" || return 1
    printf '%s\n' "$types"
}

cmd_native_type() {
    local repo="" issue="" state
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        --issue)
            [ "$#" -ge 2 ] || usage
            issue="$2"
            shift 2
            ;;
        *) usage ;;
        esac
    done
    [ -n "$repo" ] && [ -n "$issue" ] || usage
    guard_issue_number "$issue"
    state="$(native_type_state_read "$repo" "$issue")" ||
        die 2 "could not read the native issue Type of $repo#$issue"
    if [ "$state" = "unset" ]; then
        printf '%s\n' '{"state":"unset","name":null}'
    else
        jq -cn --arg name "${state#set:}" '{state:"set", name:$name}'
    fi
}

cmd_native_types() {
    local repo="" owner_type
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        *) usage ;;
        esac
    done
    [ -n "$repo" ] || usage
    owner_type="$(gh api "repos/$repo" -q .owner.type)" ||
        die 2 "could not read the owner type of $repo"
    [ "$owner_type" = "Organization" ] ||
        die 5 "refused: native issue Types are available only on organization repos"
    enabled_native_types "$repo" ||
        die 2 "could not list enabled native issue Types of $repo"
}

gh_supports_native_type_write() {
    gh issue edit --help 2>/dev/null | grep -q -- '--type'
}

cmd_label() {
    local repo="" issue="" manifest="./label-registry.json" execute=0
    local native_type="" native_type_seen=0
    local adds=() removes=() inapplicable=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        --issue)
            [ "$#" -ge 2 ] || usage
            issue="$2"
            shift 2
            ;;
        --add)
            [ "$#" -ge 2 ] || usage
            adds+=("$2")
            shift 2
            ;;
        --native-type)
            [ "$#" -ge 2 ] || usage
            [ "$native_type_seen" -eq 0 ] ||
                die 2 "--native-type may be passed only once"
            [ -n "$2" ] || die 2 "--native-type requires a non-empty Type name"
            native_type="$2"
            native_type_seen=1
            shift 2
            ;;
        --remove)
            [ "$#" -ge 2 ] || usage
            removes+=("$2")
            shift 2
            ;;
        --inapplicable)
            [ "$#" -ge 2 ] || usage
            inapplicable+=("$2")
            shift 2
            ;;
        --manifest)
            [ "$#" -ge 2 ] || usage
            manifest="$2"
            shift 2
            ;;
        --execute) execute=1 && shift ;;
        *) usage ;;
        esac
    done
    [ -n "$repo" ] && [ -n "$issue" ] || usage
    guard_issue_number "$issue"
    guard_manifest "$manifest"
    # The wrapper binds the run to one repository; a mismatched --repo here is
    # a confused (or prompt-injected) caller, not a supported use.
    if [ -n "${TRIAGE_REPO:-}" ] && [ "$repo" != "$TRIAGE_REPO" ]; then
        die 4 "refused: --repo '$repo' does not match this run's bound" \
            "repository '$TRIAGE_REPO'"
    fi
    [ "${#adds[@]}" -gt 0 ] || [ "${#removes[@]}" -gt 0 ] ||
        [ -n "$native_type" ] ||
        die 2 "nothing requested — pass --add, --native-type, and/or --remove"

    local l axis axes
    axes="$(axes_active "$repo" "$manifest")"
    # v1 removes exactly one label kind. Everything else is out of scope by
    # construction, not by validation of a wider mechanism.
    for l in "${removes[@]+"${removes[@]}"}"; do
        [ "$l" = "needs-triage" ] ||
            die 2 "--remove accepts only needs-triage (got '$l')"
    done
    for axis in "${inapplicable[@]+"${inapplicable[@]}"}"; do
        in_list "$axis" "$axes" ||
            die 2 "--inapplicable accepts an active axis" \
                "($(printf '%s' "$axes" | tr '\n' ' ')) (got '$axis')"
    done

    # Commas first: gh's --add-label treats a comma as a list separator, so a
    # manifest value like "task,blocked" would validate as one name and land
    # as two labels — one of them never validated.
    for l in "${adds[@]+"${adds[@]}"}"; do
        case "$l" in
        *,*) die 4 "refused: '$l' contains a comma — gh would split it" \
            "into multiple labels" ;;
        esac
    done
    # Never-list next — independent of, and senior to, any manifest content.
    for l in "${adds[@]+"${adds[@]}"}"; do
        if printf '%s' "$l" | grep -qE "$NEVER_RE"; then
            die 4 "refused: '$l' is on the triage never-list"
        fi
    done

    local allowlist
    allowlist="$(allowlist_compute "$repo" "$manifest")"
    for l in "${adds[@]+"${adds[@]}"}"; do
        in_list "$l" "$allowlist" ||
            die 4 "refused: '$l' is not on the triage write-allowlist"
    done
    # Removal is a write too: a manifest that withholds needs-triage from
    # agents withholds the removal as much as the add.
    if [ "${#removes[@]}" -gt 0 ]; then
        in_list "needs-triage" "$allowlist" ||
            die 4 "refused: this repo's manifest does not grant agents" \
                "needs-triage, so triage may not remove it either"
    fi

    local current
    current="$(gh issue view "$issue" --repo "$repo" --json labels \
        -q '.labels[].name')" ||
        die 2 "could not read labels of $repo#$issue"

    # RECOGNIZED work-types classify an issue whoever applied them; org repos
    # classify with native issue Type instead. (Adds are separately bound to
    # the agent-writable allowlist above.)
    local work_types
    work_types="$(work_types_recognized "$repo" "$manifest")"

    local effective_adds=()
    for l in "${adds[@]+"${adds[@]}"}"; do
        in_list "$l" "$current" || effective_adds+=("$l")
    done

    local owner_type=""
    need_owner_type() {
        if [ -z "$owner_type" ]; then
            owner_type="$(gh api "repos/$repo" -q .owner.type)" ||
                die 2 "could not read the owner type of $repo"
        fi
    }

    local current_native_type="" effective_native_type="$native_type"
    if [ -n "$native_type" ]; then
        need_owner_type
        [ "$owner_type" = "Organization" ] ||
            die 5 "refused: --native-type is available only on organization repos"
        local enabled_types
        enabled_types="$(enabled_native_types "$repo")" ||
            die 2 "could not list enabled native issue Types of $repo"
        in_list "$native_type" "$enabled_types" ||
            die 4 "refused: native issue Type '$native_type' is not enabled on $repo"
        current_native_type="$(native_type_state_read "$repo" "$issue")" ||
            die 2 "could not read the current native issue Type of $repo#$issue"
        if [ "$current_native_type" != "unset" ]; then
            [ "$current_native_type" = "set:$native_type" ] ||
                die 4 "refused: $repo#$issue already has native issue Type" \
                    "'${current_native_type#set:}' — triage only fills an unset Type"
            effective_native_type=""
        fi
    fi

    local wt_count=0
    for l in "${effective_adds[@]+"${effective_adds[@]}"}"; do
        if in_list "$l" "$work_types"; then
            need_owner_type
            [ "$owner_type" = "Organization" ] &&
                die 5 "refused: '$l' — org repos use native issue Type;" \
                    "report the missing Type instead"
            # The registry marks the family non-exclusive, but triage only
            # ever FILLS an empty slot — it never stacks a second work type.
            wt_count=$((wt_count + 1))
            [ "$wt_count" -le 1 ] ||
                die 4 "refused: '$l' — one work-type label per apply call"
            while IFS= read -r existing; do
                [ -n "$existing" ] || continue
                in_list "$existing" "$current" &&
                    die 4 "refused: '$l' — the issue already carries" \
                        "work-type '$existing'; triage only fills an empty slot"
            done <<<"$work_types"
        fi
    done

    # Exclusive axes: adding to an axis must leave it with exactly one label.
    local post count
    post="$current"
    for l in "${effective_adds[@]+"${effective_adds[@]}"}"; do
        post="$(printf '%s\n%s' "$post" "$l")"
    done
    for l in "${effective_adds[@]+"${effective_adds[@]}"}"; do
        axis="${l%%:*}"
        if in_list "$axis" "$axes"; then
            count="$(printf '%s\n' "$post" | grep -c "^$axis:" || true)"
            [ "$count" -le 1 ] ||
                die 4 "refused: adding '$l' would leave $count $axis:* labels;" \
                    "conflicted axes go to the report"
        fi
    done

    # needs-triage removal gate: classification must be COMPLETE — a work type
    # in the owner-appropriate form, every required active axis either applied
    # exactly once or attested inapplicable, and the optional layer axis either
    # applied once or absent. A conflicted axis is never "applied", and neither
    # is a label whose value the active taxonomy does not recognize (retired,
    # misspelled) — prefix presence alone must not satisfy the gate.
    if [ "${#removes[@]}" -gt 0 ]; then
        local recognized
        recognized="$(axis_values_recognized "$repo" "$manifest")"
        while IFS= read -r l; do
            [ -n "$l" ] || continue
            axis="${l%%:*}"
            case "$l" in *:*) ;; *) continue ;; esac
            in_list "$axis" "$axes" || continue
            in_list "$l" "$recognized" ||
                die 6 "refused: '$l' is not in the active $axis taxonomy —" \
                    "classification is incomplete; report the unknown value"
        done <<<"$post"
        for axis in $axes; do
            count="$(printf '%s\n' "$post" | grep -c "^$axis:" || true)"
            if [ "$count" -gt 1 ]; then
                die 6 "refused: $axis is conflicted ($count labels) —" \
                    "needs-triage stays; report the conflict"
            fi
            if [ "$count" -eq 0 ] && [ "$axis" != "layer" ]; then
                in_list "$axis" "$(printf '%s\n' \
                    "${inapplicable[@]+"${inapplicable[@]}"}")" ||
                    die 6 "refused: no $axis:* label and no --inapplicable" \
                        "$axis attestation — classification is incomplete"
            fi
        done
        need_owner_type
        if [ "$owner_type" = "Organization" ]; then
            local native
            if [ -n "$native_type" ]; then
                native="set:$native_type"
            else
                native="$(native_type_state_read "$repo" "$issue")" ||
                    die 6 "refused: could not verify the native issue Type"
            fi
            [ "$native" != "unset" ] ||
                die 6 "refused: no native issue Type set —" \
                    "classification is incomplete (report the missing Type)"
        else
            local have_wt=1
            while IFS= read -r l; do
                [ -n "$l" ] || continue
                if in_list "$l" "$post"; then
                    have_wt=0
                    break
                fi
            done <<<"$work_types"
            [ "$have_wt" -eq 0 ] ||
                die 6 "refused: no work-type label — classification is incomplete"
        fi
    fi

    if [ "${#effective_adds[@]}" -eq 0 ] && [ "${#removes[@]}" -eq 0 ] &&
        [ -z "$effective_native_type" ]; then
        echo "triage-apply: nothing to do — requested labels already present"
        return 0
    fi

    for axis in "${inapplicable[@]+"${inapplicable[@]}"}"; do
        echo "attested inapplicable: $axis"
    done

    # Dry-run promises the execute outcome it would attempt. Probe the CLI
    # capability before printing a native-Type mutation so an old gh cannot
    # make dry-run appear executable when --execute would refuse.
    if [ -n "$effective_native_type" ]; then
        gh_supports_native_type_write ||
            die 2 "gh issue edit --type requires GitHub CLI 2.98 or newer"
    fi

    if [ "$execute" -eq 0 ]; then
        if [ -n "$effective_native_type" ] &&
            in_list needs-triage "$(printf '%s\n' \
                "${effective_adds[@]+"${effective_adds[@]}"}")"; then
            echo "DRY-RUN would add 'needs-triage' to $repo#$issue"
        fi
        if [ -n "$effective_native_type" ]; then
            echo "DRY-RUN would set native issue Type '$effective_native_type' on $repo#$issue"
        fi
        for l in "${effective_adds[@]+"${effective_adds[@]}"}"; do
            if [ -n "$effective_native_type" ] && [ "$l" = "needs-triage" ]; then
                continue
            fi
            echo "DRY-RUN would add '$l' to $repo#$issue"
        done
        for l in "${removes[@]+"${removes[@]}"}"; do
            echo "DRY-RUN would remove '$l' from $repo#$issue"
        done
        return 0
    fi

    [ "${TRIAGE_EXECUTE:-0}" = "1" ] ||
        die 2 "--execute requires TRIAGE_EXECUTE=1 in the environment" \
            "(set by the task triage wrapper for supervised runs)"

    # When this call establishes both the visibility marker and a native Type,
    # establish the marker first. Otherwise a successful Type write followed
    # by a failed marker add would leave an untyped-looking issue invisible to
    # triage. The remaining classification adds wait for the verified Type;
    # a failed Type write therefore cannot make them (or a later removal).
    local establish_needs_triage=0
    local post_type_adds=()
    if [ -n "$effective_native_type" ]; then
        for l in "${effective_adds[@]+"${effective_adds[@]}"}"; do
            if [ "$l" = "needs-triage" ]; then
                establish_needs_triage=1
            else
                post_type_adds+=("$l")
            fi
        done
    else
        post_type_adds=("${effective_adds[@]+"${effective_adds[@]}"}")
    fi
    if [ "$establish_needs_triage" -eq 1 ]; then
        gh issue edit "$issue" --repo "$repo" --add-label needs-triage \
            >/dev/null </dev/null ||
            die 1 "write failed: gh issue edit $repo#$issue"
        echo "APPLIED add 'needs-triage' to $repo#$issue"
    fi

    # GitHub CLI applies label edits before its deferred issue-Type mutation.
    # The only label intentionally established before Type is needs-triage
    # above, which keeps an otherwise untyped issue visible if its Type write
    # fails. All other labels wait for the verified Type.
    if [ -n "$effective_native_type" ]; then
        # A person may have classified the issue after the first preflight.
        # Re-read immediately before the non-conditional GitHub write and
        # refuse a conflicting human Type before touching any labels.
        current_native_type="$(native_type_state_read "$repo" "$issue")" ||
            die 2 "could not re-read the current native issue Type of $repo#$issue"
        if [ "$current_native_type" != "unset" ]; then
            [ "$current_native_type" = "set:$effective_native_type" ] ||
                die 4 "refused: $repo#$issue was classified as native issue Type" \
                    "'${current_native_type#set:}' while triage was preparing its write"
            effective_native_type=""
        else
            gh issue edit "$issue" --repo "$repo" --type "$effective_native_type" \
                >/dev/null </dev/null ||
                die 1 "write failed: gh issue edit --type $repo#$issue"
            current_native_type="$(native_type_reconcile "$repo" "$issue")" ||
                die 2 "write indeterminate: native issue Type may have applied to" \
                    "$repo#$issue but could not be verified after 3 reads;" \
                    "no remaining labels or needs-triage removal were attempted"
            [ "$current_native_type" = "set:$effective_native_type" ] ||
                die 1 "write failed: $repo#$issue native issue Type did not become" \
                    "'$effective_native_type'"
            # This is deliberately before the independent label edit below:
            # if that later mutation fails, stdout still records the durable
            # Type change rather than falsely implying the apply was inert.
            echo "APPLIED native issue Type '$effective_native_type' to $repo#$issue"
        fi
    fi
    # Keep adds and needs-triage removal in separate edits. A failed add must
    # leave needs-triage visible, while a Type failure above still prevents all
    # label edits.
    local args=()
    if [ "${#post_type_adds[@]}" -gt 0 ]; then
        args+=(--add-label "$(
            IFS=,
            echo "${post_type_adds[*]}"
        )")
    fi
    if [ "${#args[@]}" -gt 0 ]; then
        gh issue edit "$issue" --repo "$repo" "${args[@]}" >/dev/null </dev/null ||
            die 1 "write failed: gh issue edit $repo#$issue"
    fi
    for l in "${post_type_adds[@]+"${post_type_adds[@]}"}"; do
        echo "APPLIED add '$l' to $repo#$issue"
    done
    if [ "${#removes[@]}" -gt 0 ]; then
        gh issue edit "$issue" --repo "$repo" --remove-label "$(
            IFS=,
            echo "${removes[*]}"
        )" >/dev/null </dev/null ||
            die 1 "write failed: gh issue edit $repo#$issue"
    fi
    for l in "${removes[@]+"${removes[@]}"}"; do
        echo "APPLIED remove '$l' from $repo#$issue"
    done
}

[ "$#" -ge 1 ] || usage
cmd="$1"
shift
case "$cmd" in
allowlist) cmd_allowlist "$@" ;;
axes) cmd_axes "$@" ;;
axis-values) cmd_axis_values "$@" ;;
work-types) cmd_work_types "$@" ;;
native-type) cmd_native_type "$@" ;;
native-types) cmd_native_types "$@" ;;
label) cmd_label "$@" ;;
*) usage ;;
esac
