#!/usr/bin/env bash
# triage-apply.sh — the triage skill's ONLY label write path.
#
# Why a script: the triage skill is designed to be executed by cheap, simple
# models. Every rule that can be enforced mechanically is enforced here, so the
# model supplies classification judgment and nothing else. The skill contract
# (issue #455 / specs/issue-strategy.md in harmon-init) is:
#
#   v1 WRITES ONLY labels, and only these:
#     - classification-axis labels (the manifest's `classification` families —
#       area:*/layer:*/domain:* on a default registry; whatever axes the
#       repo's registry declares otherwise)
#     - a work-type label (bug/feature/task/...) on PERSONAL-account repos only
#       (org repos use native issue Type, which v1 cannot write)
#     - needs-triage — added freely, removed only when classification is
#       complete
#   v1 NEVER writes: foreman:*, rigor:*, tier:*, method:*, claim:*, suggest:*,
#   agent:* (legacy claims), milestones, closes, assignees, body/title edits.
#   This script contains no code path for any of those — the never-list is a
#   regex refusal on top of the structural absence.
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
#   triage-apply.sh label --repo owner/repo --issue N
#                   [--add LABEL]... [--remove needs-triage]
#                   [--inapplicable AXIS]... [--manifest PATH] [--execute]
#
# `native-type` is a read: it prints the issue's native GitHub issue Type name,
# or "none". It exists so the classifying model never needs raw `gh api`
# access — org-repo Type checks go through here.
#
# Dry-run is the DEFAULT: without --execute the script prints exactly what it
# would write and writes nothing. --execute additionally requires
# TRIAGE_EXECUTE=1 in the environment — the `task triage` wrapper sets it only
# for a supervised run, so a model cannot promote itself to write mode by
# adding a flag.
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
#       5 = refused: work-type label on an org repo (native Type owns it there)
#       6 = refused: needs-triage removal while classification is incomplete
set -euo pipefail

NEVER_RE='^(foreman:|rigor:|tier:|method:|claim:|suggest:|agent:)'
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
    echo "       $0 label --repo owner/repo --issue N [--add LABEL]..." >&2
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
             $3 ~ /^(foreman|rigor|tier|method|claim|suggest|agent)$/) {
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

# Print the native issue Type name, or "none". Non-zero when it cannot be read
# (missing scope, old GitHub, network) — callers must treat that as unknown,
# never as absent.
native_type_read() {
    local repo="$1" issue="$2" native
    native="$(gh api graphql \
        -f query='query($o: String!, $r: String!, $n: Int!) {
            repository(owner: $o, name: $r) {
              issue(number: $n) { issueType { name } } } }' \
        -f o="${repo%%/*}" -f r="${repo#*/}" -F n="$issue" \
        -q '.data.repository.issue.issueType.name' 2>/dev/null)" || return 1
    if [ -z "$native" ] || [ "$native" = "null" ]; then
        echo "none"
    else
        echo "$native"
    fi
}

cmd_native_type() {
    local repo="" issue=""
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
    native_type_read "$repo" "$issue" ||
        die 2 "could not read the native issue Type of $repo#$issue"
}

cmd_label() {
    local repo="" issue="" manifest="./label-registry.json" execute=0
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
        die 2 "nothing requested — pass --add and/or --remove"

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
    # in the owner-appropriate form, and each active axis either applied
    # exactly once or attested inapplicable. A conflicted axis is never
    # "applied", and neither is a label whose value the active taxonomy does
    # not recognize (retired, misspelled) — prefix presence alone must not
    # satisfy the gate.
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
            if [ "$count" -eq 0 ]; then
                in_list "$axis" "$(printf '%s\n' \
                    "${inapplicable[@]+"${inapplicable[@]}"}")" ||
                    die 6 "refused: no $axis:* label and no --inapplicable" \
                        "$axis attestation — classification is incomplete"
            fi
        done
        need_owner_type
        if [ "$owner_type" = "Organization" ]; then
            local native
            native="$(native_type_read "$repo" "$issue")" ||
                die 6 "refused: could not verify the native issue Type"
            [ "$native" != "none" ] ||
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

    if [ "${#effective_adds[@]}" -eq 0 ] && [ "${#removes[@]}" -eq 0 ]; then
        echo "triage-apply: nothing to do — requested labels already present"
        return 0
    fi

    for axis in "${inapplicable[@]+"${inapplicable[@]}"}"; do
        echo "attested inapplicable: $axis"
    done

    if [ "$execute" -eq 0 ]; then
        for l in "${effective_adds[@]+"${effective_adds[@]}"}"; do
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

    local args=()
    if [ "${#effective_adds[@]}" -gt 0 ]; then
        args+=(--add-label "$(
            IFS=,
            echo "${effective_adds[*]}"
        )")
    fi
    if [ "${#removes[@]}" -gt 0 ]; then
        args+=(--remove-label "$(
            IFS=,
            echo "${removes[*]}"
        )")
    fi
    gh issue edit "$issue" --repo "$repo" "${args[@]}" >/dev/null </dev/null ||
        die 1 "write failed: gh issue edit $repo#$issue"
    for l in "${effective_adds[@]+"${effective_adds[@]}"}"; do
        echo "APPLIED add '$l' to $repo#$issue"
    done
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
label) cmd_label "$@" ;;
*) usage ;;
esac
