#!/usr/bin/env bash
# triage-apply.sh — the triage skill's ONLY label write path.
#
# Why a script: the triage skill is designed to be executed by cheap, simple
# models. Every rule that can be enforced mechanically is enforced here, so the
# model supplies classification judgment and nothing else. The skill contract
# (issue #455 / specs/issue-strategy.md in harmon-init) is:
#
#   v1 WRITES ONLY labels, and only these:
#     - area:* / layer:* / domain:* classification labels
#     - a work-type label (bug/feature/task/...) on PERSONAL-account repos only
#       (org repos use native issue Type, which v1 cannot write)
#     - needs-triage — added freely, removed only when classification is
#       complete
#   v1 NEVER writes: foreman:*, rigor:*, tier:*, method:*, claim:*, suggest:*,
#   agent:* (legacy claims), milestones, closes, assignees, body/title edits.
#   This script contains no code path for any of those — the never-list is a
#   regex refusal on top of the structural absence.
#
# The write-allowlist is read from the repo's label-registry.json manifest
# (values whose effective `writers` include "agent", within the v1 scope
# above), falling back to `gh label list` + a fixed v1 vocabulary where no
# manifest exists. An "evil" manifest cannot widen the scope: the never-list
# and the v1 scope filter are hard-coded and applied on top of it.
#
# Usage:
#   triage-apply.sh allowlist [--repo owner/repo] [--manifest PATH]
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
AXES='area layer domain'
# v1 fallback work-type vocabulary, used only when no manifest exists. The
# manifest wins where present. `enhancement` is deliberately absent — it is the
# retired GitHub default this vocabulary replaces with `feature`.
FALLBACK_WORK_TYPES='bug feature task research documentation question'

usage() {
    echo "Usage: $0 allowlist [--repo owner/repo] [--manifest PATH]" >&2
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

# Print the v1 write-allowlist, one label per line.
allowlist_compute() {
    local repo="$1" manifest="$2"
    if [ -f "$manifest" ]; then
        jq -r '
          [ .families[]
            | select((.retired // false) | not)
            | . as $f
            | .values[]?
            | select((.retired // false) | not)
            | ((.writers // $f.writers) // []) as $w
            | select(($w | index("agent")) != null)
            | select(
                ((["area", "layer", "domain"] | index($f.prefix // "")) != null)
                or ($f.axis == "work-type")
                or ($f.axis == "workflow" and .value == "needs-triage"))
            | if ($f.prefix // "") == "" then .value
              else "\($f.prefix):\(.value)" end
          ] | unique[]' "$manifest"
    else
        [ -n "$repo" ] ||
            die 2 "no manifest at '$manifest' and no --repo for the gh fallback"
        local live wt
        live="$(gh label list --repo "$repo" --limit 1000 --json name \
            -q '.[].name')"
        printf '%s\n' "$live" | grep -E '^(area|layer|domain):' || true
        for wt in $FALLBACK_WORK_TYPES needs-triage; do
            printf '%s\n' "$live" | grep -qx "$wt" && printf '%s\n' "$wt"
        done
        return 0
    fi
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

    local l axis
    # v1 removes exactly one label kind. Everything else is out of scope by
    # construction, not by validation of a wider mechanism.
    for l in "${removes[@]+"${removes[@]}"}"; do
        [ "$l" = "needs-triage" ] ||
            die 2 "--remove accepts only needs-triage (got '$l')"
    done
    for axis in "${inapplicable[@]+"${inapplicable[@]}"}"; do
        case " $AXES " in
        *" $axis "*) ;;
        *) die 2 "--inapplicable accepts one of: $AXES (got '$axis')" ;;
        esac
    done

    # Never-list first — independent of, and senior to, any manifest content.
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

    # Bare-named allowlist entries are the work-type vocabulary plus
    # needs-triage; org repos classify with native issue Type instead.
    local work_types
    work_types="$(printf '%s\n' "$allowlist" |
        grep -v ':' | grep -vx 'needs-triage' || true)"

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
        case " $AXES " in *" $axis "*)
            count="$(printf '%s\n' "$post" | grep -c "^$axis:" || true)"
            [ "$count" -le 1 ] ||
                die 4 "refused: adding '$l' would leave $count $axis:* labels;" \
                    "conflicted axes go to the report"
            ;;
        esac
    done

    # needs-triage removal gate: classification must be COMPLETE — a work type
    # in the owner-appropriate form, and each axis either applied exactly once
    # or attested inapplicable. A conflicted axis is never "applied".
    if [ "${#removes[@]}" -gt 0 ]; then
        for axis in $AXES; do
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
    gh issue edit "$issue" --repo "$repo" "${args[@]}" >/dev/null ||
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
native-type) cmd_native_type "$@" ;;
label) cmd_label "$@" ;;
*) usage ;;
esac
