#!/usr/bin/env bash
# triage-apply.sh — the triage skill's ONLY issue-mutation path.
#
# Why a script: the triage skill is designed to be executed by cheap, simple
# models. Every rule that can be enforced mechanically is enforced here, so the
# model supplies classification judgment and nothing else. The skill contract
# (issue #455 / specs/issue-strategy.md in harmon-init, extended by
# harmon-devkit#1250 for harmon-init ADR 2026-09-30, "Classify issues by
# impact, risk, and complexity, and derive the tier") is:
#
#   WRITES ONLY classification metadata, and only these:
#     - classification-axis labels (the manifest's `classification` families —
#       area:*/layer:*/domain:* on a default registry, each with its explicit
#       `none` value; whatever axes the repo's registry declares otherwise)
#     - a work-type label (bug/feature/task/...) on PERSONAL-account repos only
#       (org repos use native issue Type instead)
#     - a native issue Type on ORGANIZATION repos only, selected from the
#       organization's enabled Types
#     - Impact, Risk, Complexity and Priority (AI): the `Impact`, `Risk`,
#       `Complexity` and `Priority (AI)` issue fields on ORGANIZATION repos
#       (GraphQL setIssueFieldValue), the exclusive `impact:*`, `risk:*`,
#       `complexity:*` and `priority-ai:*` labels on PERSONAL-account repos.
#       One code path per owner type: on an organization the same-named
#       labels are inert — never written, and a stray one never counts as the
#       axis being set.
#     - the derived Tier, as the `tier:<value>` label on EVERY owner type,
#       written in the same call that writes Risk or Complexity. The value is
#       the vendored policy reader's answer (dev-flow-support's
#       devflow-policy.mjs) — this script never re-implements the matrix and
#       never lets a caller choose a Tier. An issue carrying `tier:pinned`
#       never has a tier label written or removed. GitHub has no conditional
#       label edit, so a pin added between the last read and the label edit
#       is caught by a read after it: the Tier change is undone and the call
#       exits 4. A label change after that read is not seen — a pin added
#       later, or a re-tier during the restore itself — and a restore edit
#       that fails is reported for fixing by hand even if it landed.
#     - needs-triage — DERIVED from the required set (work type, every active
#       label axis, Impact, Risk, Complexity), never added or removed by
#       judgement: added while any required axis is missing, removed once
#       every one is present.
#     - human — added when completion is primarily a human's; explicit removal
#       requires a live non-collector without a [HUMAN] majority. The classifier
#       judges agent-completability; this helper enforces the mechanical guards.
#   NEVER writes: the human Priority and Effort (fields or labels), foreman:*,
#   rigor:*, tier:pinned, scoped tier:<role>:* (tier:implementer:* and the
#   other roles), strategy:*, method:* (the retired prefix strategy:* replaces
#   — stays reserved so a stale or hostile manifest cannot redefine it as
#   agent-writable), claim:*, agent:* (legacy claims), milestones, closes,
#   assignees, body/title edits. This script contains no code path for any of
#   those — the never-list is a regex refusal on top of the structural
#   absence.
#
# The write-allowlist, the active label axes, and their recognized values are
# read from the repo's label-registry.json manifest (values whose effective
# `writers` include "agent", within the scope above), falling back to
# `gh label list` intersected with a hard-coded copy of the harmon-init
# template defaults where no manifest exists. An "evil" manifest cannot widen
# the scope: the never-list and the scope filter are hard-coded and applied
# on top of it. Impact, Risk, Complexity and Priority (AI) are not manifest
# axes here: their scales are the rubric's (references/classification-rubric.md,
# references/priority-rubric.md), intersected with what the target repository
# actually provisions — its live labels on a personal account, its issue
# fields and their options on an organization.
#
# Usage:
#   triage-apply.sh allowlist [--repo owner/repo] [--manifest PATH]
#   triage-apply.sh axes [--repo owner/repo] [--manifest PATH]
#   triage-apply.sh axis-values [--repo owner/repo] [--manifest PATH]
#   triage-apply.sh work-types [--repo owner/repo] [--manifest PATH]
#   triage-apply.sh classification-axes --repo owner/repo [--policy PATH] [--tier-derivation]
#   triage-apply.sh native-type --repo owner/repo --issue N
#   triage-apply.sh native-types --repo owner/repo
#   triage-apply.sh label --repo owner/repo --issue N
#                   [--add LABEL]... [--native-type TYPE]
#                   [--impact V] [--risk V] [--complexity V]
#                   [--priority-ai V] [--remove needs-triage|human]
#                   [--reconcile] [--manifest PATH] [--policy PATH]
#                   [--execute]
#
# `native-type` is a read: it prints JSON with an explicit `state` (`set` or
# `unset`) and the exact Type `name` when set. It exists so the classifying
# model never needs raw `gh api` access — org-repo Type checks go through here.
# `classification-axes` is a read too: JSON naming the storage (`label` or
# `field`), which of Impact/Risk/Complexity/Priority (AI) the repository
# provisions and with which values, and the provisioned tier labels — the one
# source triage-scan.sh reads, so the two can never drift.
# --tier-derivation opts into the additive tier_derivation capability field;
# default catalogue reads do not invoke the policy resolver.
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
# --impact/--risk/--complexity/--priority-ai V fill an UNSET axis (`--add
# impact:V` and friends are read as the same request, so a caller that only
# knows labels still reaches the one owner-type code path). A different value
# already set is refused — triage fills, it never re-rates — except Priority
# (AI), which is replaced only when the human Priority is unset and this call
# changed the classification. Priority (AI) is written only alongside a
# complete Impact, Risk and Complexity. A human Priority is reported, never
# written.
#
# --reconcile asks for nothing but the derived writes: needs-triage from the
# required set, and the Tier wherever Risk and Complexity are both set. It is
# how a run settles an issue that needs no other write (the scan's
# `missing-needs-triage` / `needs-triage-removable`); every other call derives
# the same writes alongside its own.
#
# --policy PATH (default ./.devflow.toml) is the policy the Tier is derived
# under. Without a [tier.matrix] there (or without the file, the reader, or
# node) the Tier is not written and the reason is printed; the axes still are.
#
# --inapplicable is retired: an attestation no label records cannot be
# derived from. Apply the axis's explicit `none` value instead.
#
# Exit: 0 = applied, or dry-run resolved cleanly (including nothing to do)
#       1 = the write failed
#       2 = usage/environment error (bad flags, --execute without the env gate,
#           could not verify something the gate needs)
#       4 = refused: human-removal guard, never-list, allowlist, exclusive-axis conflict, a value
#           off its scale or not provisioned, or a different value already set,
#           or a tier:pinned that appeared during the label edit (its Tier
#           change undone)
#       5 = refused: work-type label on an org repo, or native Type on a
#           personal repo
#       6 = refused: an explicit needs-triage add/remove that contradicts the
#           required set, or Priority (AI) without complete classification
set -euo pipefail

# The never-list. `tier:` is NOT refused as a whole prefix any more: the
# stored, derived Tier (`tier:<value>`) is this script's own write. What stays
# refused is exactly the forbidden forms — the human pin marker and the scoped
# per-role execution-policy overrides — and a caller-supplied bare
# `tier:<value>` is refused separately below (the Tier is derived, never
# chosen). `priority:` is the HUMAN Priority (`priority-ai:` does not match).
NEVER_RE='^(foreman:|rigor:|strategy:|method:|claim:|agent:|priority:|effort:|tier:pinned$|tier:[^:]+:)'
# The rubric scales (references/classification-rubric.md and
# references/priority-rubric.md; harmon-init ADR 2026-09-30 D2). The Tier
# ladder is vocabulary, not policy: the matrix cells come from the reader.
IMPACT_SCALE='minimal low medium high massive'
RISK_SCALE='trivial low medium high critical'
COMPLEXITY_SCALE='xs s m l xl'
PRIORITY_AI_SCALE='p0 p1 p2 p3 p4'
TIER_RUNGS='local economy standard frontier apex'
# The three REQUIRED classification axes stored as an issue field on an
# organization and as a label family on a personal account. Priority (AI)
# shares their storage but is never required.
FIELD_AXES='impact risk complexity'
# Every prefix this storage owns. The manifest-driven label-axis path below
# never treats one of them as an ordinary classification axis: on an
# organization those labels are inert.
FIELD_AXIS_RE='^(impact|risk|complexity|priority-ai)$'
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
    echo "       $0 classification-axes --repo owner/repo [--policy PATH] [--tier-derivation]" >&2
    echo "       $0 native-types --repo owner/repo" >&2
    echo "       $0 label --repo owner/repo --issue N [--add LABEL]..." >&2
    echo "           [--native-type TYPE] [--impact V] [--risk V]" >&2
    echo "           [--complexity V] [--priority-ai V]" >&2
    echo "           [--remove needs-triage|human] [--reconcile] [--manifest PATH]" >&2
    echo "           [--policy PATH] [--execute]" >&2
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
             $3 ~ /^(foreman|rigor|tier|strategy|method|claim|agent|priority|effort)$/) {
                print $2
            }' | paste -sd ', ' -)"
    [ -z "$bad" ] ||
        die 2 "refusing to derive from classification families triage cannot" \
            "govern (prefix-less, open-values, or reserved prefix): $bad"
    printf '%s\n' "$records"
}

# Relative policy/manifest names are trustworthy only at the checkout root.
# The scan invokes this same check through the internal check-root command.
guard_run_root() {
    [ -n "${TRIAGE_REPO:-}" ] || return 0
    local root cwd
    cwd="$(pwd -P)" || die 4 "refused: could not resolve the bound run's working directory"
    root="$(git rev-parse --show-toplevel 2>/dev/null)" ||
        die 4 "refused: a bound run must run from the repository root (not a Git checkout)"
    root="$(cd "$root" && pwd -P)" ||
        die 4 "refused: could not resolve the bound run's repository root"
    [ "$cwd" = "$root" ] ||
        die 4 "refused: a bound run must run from the repository root '$root' (got '$cwd')"
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

# Reads and writes use the repo's own policy in a bound run: a scratch policy
# must neither choose a Tier nor suppress the scan's missing-Tier flags.
guard_policy() {
    local policy="$1"
    if [ -n "${TRIAGE_REPO:-}" ] && [ "$policy" != "./.devflow.toml" ]; then
        die 4 "refused: --policy is fixed to ./.devflow.toml in a bound run" \
            "— a worker-writable policy would choose its own Tier"
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

# Fetch the complete live label set, one name per line. Callers read it in
# a command substitution, where its `die` ends only that subshell (no
# inherit_errexit), so every caller re-raises the failure itself: an empty
# vocabulary would read every axis as unprovisioned and let the derived
# needs-triage removal fire. A page equal to the
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

# Print the active LABEL classification axes (label prefixes), one per line —
# Impact/Risk/Complexity/Priority (AI) are excluded here even when a registry
# declares them as classification families: their storage depends on the
# owner type (see classification_axes_json), so they never ride this path —
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
                $6 == "true" && $9 == "false" &&
                $3 !~ /^(impact|risk|complexity|priority-ai)$/ { print $3 }' |
            sort -u
    else
        [ -n "$repo" ] ||
            die 2 "no manifest at '$manifest' and no --repo for the gh fallback"
        local live a
        live="$(live_labels "$repo")" ||
            die 2 "could not list the live labels of $repo"
        for a in $FALLBACK_AXES; do
            grep -q "^$a:" <<<"$live" && printf '%s\n' "$a"
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
                $7 == "true" && $10 == "false" && $11 == "false" &&
                $2 !~ /^(impact|risk|complexity|priority-ai):/ {
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
        live="$(live_labels "$repo")" ||
            die 2 "could not list the live labels of $repo"
        printf '%s\n' "$live" | grep -E "^($re):" || true
    fi
}

# Print the v1 write-allowlist, one label per line.
allowlist_compute() {
    local repo="$1" manifest="$2" records
    if [ -f "$manifest" ]; then
        records="$(render_manifest "$manifest")"
        # v1 scope: the manifest's own classification families (any axis the
        # registry declares, not a fixed three), work-type, needs-triage, and
        # human from the human-work family. Effective writers grant the write;
        # human removal additionally requires the live mechanical guards.
        printf '%s\n' "$records" |
            awk -F '|' '$1 == "value" && $10 == "false" && $11 == "false" &&
                ("," $6 ",") ~ /,agent,/ &&
                $2 !~ /^(impact|risk|complexity|priority-ai):/ &&
                (($5 == "classification" && $7 == "true") ||
                 $5 == "work-type" ||
                 ($5 == "workflow" && $2 == "needs-triage") ||
                 ($3 == "human-work" && $2 == "human")) {
                    print $2
                }' |
            sort -u
    else
        [ -n "$repo" ] ||
            die 2 "no manifest at '$manifest' and no --repo for the gh fallback"
        local live wt
        live="$(live_labels "$repo")" ||
            die 2 "could not list the live labels of $repo"
        axis_values_recognized "$repo" "$manifest"
        for wt in $FALLBACK_WORK_TYPES needs-triage human; do
            grep -qx "$wt" <<<"$live" && printf '%s\n' "$wt"
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
        live="$(live_labels "$repo")" ||
            die 2 "could not list the live labels of $repo"
        for wt in $FALLBACK_WORK_TYPES; do
            grep -qx "$wt" <<<"$live" && printf '%s\n' "$wt"
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
    grep -qxF -- "$1" <<<"$2"
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
    grep -q -- '--type' < <(gh issue edit --help 2>/dev/null)
}

# ── Impact / Risk / Complexity / Priority (AI) / Tier ───────────────────────

# on_scale VALUE "SPACE SEPARATED SCALE" — 0 when VALUE is one of the scale.
on_scale() {
    case " $2 " in
    *" $1 "*) return 0 ;;
    esac
    return 1
}

axis_scale() {
    case "$1" in
    impact) printf '%s\n' "$IMPACT_SCALE" ;;
    risk) printf '%s\n' "$RISK_SCALE" ;;
    complexity) printf '%s\n' "$COMPLEXITY_SCALE" ;;
    priority-ai) printf '%s\n' "$PRIORITY_AI_SCALE" ;;
    *) return 1 ;;
    esac
}

# The organization issue field that stores an axis (harmon-init's
# setup-github-issue-fields.sh creates exactly these names). `Priority` — the
# HUMAN priority — is read only, and is deliberately not an axis here.
axis_field_name() {
    case "$1" in
    impact) printf '%s\n' 'Impact' ;;
    risk) printf '%s\n' 'Risk' ;;
    complexity) printf '%s\n' 'Complexity' ;;
    priority-ai) printf '%s\n' 'Priority (AI)' ;;
    *) return 1 ;;
    esac
}

# Issue fields are a public-preview GraphQL feature behind this header.
GQL_FEATURES='GraphQL-Features: issue_fields'

# Print the single-select issue fields the repository exposes as compact JSON
# — [{id, name, options: [{id, name}]}]. Non-zero on a failed read or a list
# longer than one page: a hidden field must never read as "not provisioned".
org_issue_fields() {
    local repo="$1"
    gh api graphql -H "$GQL_FEATURES" \
        -f query='query($o: String!, $r: String!) {
            repository(owner: $o, name: $r) {
              issueFields(first: 100) {
                pageInfo { hasNextPage }
                nodes {
                  ... on IssueFieldSingleSelect { id name options { id name } }
                }
              }
            }
          }' \
        -f o="${repo%%/*}" -f r="${repo#*/}" \
        -q 'if .data.repository == null then error("repository not found")
            elif (.data.repository.issueFields.pageInfo.hasNextPage // false)
            then error("issue field list exceeds one page")
            else [(.data.repository.issueFields.nodes // [])[]
                  | select((.id // null) != null and (.name // null) != null)
                  | {id, name, options: [(.options // [])[] | {id, name}]}]
            end | tojson' 2>/dev/null
}

# Print {"id": <issue node id>, "fields": {"<Field name>": "<value>", ...}}
# for one issue's single-select field values. Non-zero on a failed read or a
# truncated value list.
org_issue_field_values() {
    local repo="$1" issue="$2"
    gh api graphql -H "$GQL_FEATURES" \
        -f query='query($o: String!, $r: String!, $n: Int!) {
            repository(owner: $o, name: $r) {
              issue(number: $n) {
                id
                issueFieldValues(first: 50) {
                  pageInfo { hasNextPage }
                  nodes {
                    ... on IssueFieldSingleSelectValue {
                      name
                      field { ... on IssueFieldSingleSelect { name } }
                    }
                  }
                }
              }
            }
          }' \
        -f o="${repo%%/*}" -f r="${repo#*/}" -F n="$issue" \
        -q '.data.repository.issue as $i
            | if $i == null then error("issue not found")
              elif ($i.issueFieldValues.pageInfo.hasNextPage // false)
              then error("issue field values exceed one page")
              else {id: $i.id,
                    fields: ([($i.issueFieldValues.nodes // [])[]
                              | select((.field.name? // null) != null
                                       and (.name? // null) != null)
                              | {key: .field.name, value: .name}]
                             | from_entries)}
              end | tojson' 2>/dev/null
}

# Every Impact/Risk/Complexity/Priority (AI) write of one call is ONE
# setIssueFieldValue mutation — the organization's single code path.
org_set_issue_fields() {
    local issue_id="$1" fields_json="$2"
    jq -cn --arg id "$issue_id" --argjson f "$fields_json" '{
        query: "mutation($issue: ID!, $fields: [IssueFieldCreateOrUpdateInput!]!) { setIssueFieldValue(input: {issueId: $issue, issueFields: $fields}) { clientMutationId } }",
        variables: {issue: $id, fields: $f}}' |
        gh api graphql -H "$GQL_FEATURES" --input - >/dev/null
}

# classification_axes_json REPO OWNER_TYPE — what this repository provisions
# for Impact, Risk, Complexity and Priority (AI), and its tier labels. A
# personal account provisions an axis by carrying its labels; an organization
# by exposing the issue field (its options name the values). Values are
# always the rubric scale intersected with what is provisioned.
classification_axes_json() {
    local repo="$1" owner_type="$2" live catalogue="[]" storage=label
    live="$(live_labels "$repo")" ||
        die 2 "could not list the live labels of $repo"
    if [ "$owner_type" = "Organization" ]; then
        storage=field
        catalogue="$(org_issue_fields "$repo")" ||
            die 2 "could not read the issue fields of $repo. Organization" \
                "issue fields are a GitHub public-preview GraphQL feature" \
                "(header 'GraphQL-Features: issue_fields'): the token needs" \
                "read access to the organization's issue fields (and write" \
                "access to set them), and the preview must be enabled for the" \
                "organization. Triage does not classify $repo until this read" \
                "works — report it."
    fi
    jq -cn --arg live "$live" --arg storage "$storage" \
        --arg owner_type "$owner_type" --argjson catalogue "$catalogue" \
        --arg impact "$IMPACT_SCALE" --arg risk "$RISK_SCALE" \
        --arg complexity "$COMPLEXITY_SCALE" \
        --arg priority_ai "$PRIORITY_AI_SCALE" --arg tiers "$TIER_RUNGS" '
      ($live | split("\n") | map(select(. != ""))) as $l
      | {"impact": {field: "Impact", scale: $impact},
         "risk": {field: "Risk", scale: $risk},
         "complexity": {field: "Complexity", scale: $complexity},
         "priority-ai": {field: "Priority (AI)", scale: $priority_ai}} as $spec
      | ($spec | with_entries(
          .key as $a | .value as $s
          | ($s.scale | split(" ")) as $scale
          | if $storage == "field" then
              ([$catalogue[] | select(.name == $s.field)] | first) as $f
              | .value = {provisioned: ($f != null), field: $s.field,
                          values: (if $f == null then []
                                   else [$scale[] | . as $v
                                         | select(any($f.options[];
                                             (.name | ascii_downcase) == $v))]
                                   end)}
            else
              ([$scale[] | . as $v
                | select(any($l[]; . == "\($a):\($v)"))]) as $vals
              | .value = {provisioned: (($vals | length) > 0),
                          values: $vals}
            end)) as $axes
      | {owner_type: $owner_type, storage: $storage, axes: $axes,
         required: [("impact", "risk", "complexity")
                    | select($axes[.].provisioned)],
         tier_values: [$tiers | split(" ")[]
                       | select(. as $t | any($l[]; . == "tier:\($t)"))]}'
}

cmd_classification_axes() {
    local repo="" owner_type policy="./.devflow.toml" catalogue derivation with_derivation=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
        --repo)
            [ "$#" -ge 2 ] || usage
            repo="$2"
            shift 2
            ;;
        --policy)
            [ "$#" -ge 2 ] || usage
            policy="$2"
            shift 2
            ;;
        --tier-derivation) with_derivation=1 && shift ;;
        *) usage ;;
        esac
    done
    [ -n "$repo" ] || usage
    guard_policy "$policy"
    owner_type="$(gh api "repos/$repo" -q .owner.type)" ||
        die 2 "could not read the owner type of $repo"
    catalogue="$(classification_axes_json "$repo" "$owner_type")"
    if [ "$with_derivation" -eq 0 ]; then
        printf '%s\n' "$catalogue"
        return 0
    fi
    derivation="$(tier_derivation_json "$catalogue" "$policy")"
    jq -c --argjson derivation "$derivation" \
        '. + {tier_derivation: $derivation}' <<<"$catalogue"
}

# derive_tier RISK COMPLEXITY POLICY — the Tier, by CALLING the vendored
# policy reader; never a copy of its matrix. Prints the rung, or a line
# beginning with "!" that says why no Tier can be derived. The reader is the
# sibling `dev-flow-support` skill, resolved physically: both are `universal`
# skills, so they sit side by side in every consumer's flattened skills
# directory, and a repository-root `scripts/` path would not exist there.
derive_tier() {
    local risk="$1" complexity="$2" policy="$3" dir out status tier
    dir="$(cd "$asset_dir/../../dev-flow-support/assets" 2>/dev/null && pwd -P)" || {
        echo "!the dev-flow-support skill is not vendored beside triage"
        return 0
    }
    [ -f "$dir/devflow-policy.mjs" ] || {
        echo "!dev-flow-support/assets/devflow-policy.mjs is missing"
        return 0
    }
    command -v node >/dev/null 2>&1 || {
        echo "!node is not installed, so the policy reader cannot run"
        return 0
    }
    # Exit 3 (indeterminate) still prints the resolution; read the JSON
    # whatever the status and decide from issue_tier alone.
    out="$(node "$dir/devflow-policy.mjs" resolve --policy "$policy" \
        --risk="$risk" --complexity="$complexity" --json 2>/dev/null)" || true
    status="$(jq -r '.issue_tier.status // empty' <<<"$out" 2>/dev/null)" ||
        status=""
    case "$status" in
    derived)
        tier="$(jq -r '.issue_tier.tier // empty' <<<"$out")"
        if on_scale "$tier" "$TIER_RUNGS"; then
            printf '%s\n' "$tier"
        else
            echo "!the policy reader derived '$tier', which is not a Tier rung"
        fi
        ;;
    "") echo "!the policy reader could not resolve '$policy'" ;;
    *)
        echo "!$(jq -r '.issue_tier.reason // "the derived Tier is \(.issue_tier.status)"' \
            <<<"$out")"
        ;;
    esac
}

# Evaluate provisioned input pairs with the same helper and policy the writer
# uses. Partial Tier-label provisioning must not hide pairs it can write.
tier_derivation_json() {
    local catalogue="$1" policy="$2" risk complexity derived reason rows="[]"
    while IFS= read -r risk; do
        while IFS= read -r complexity; do
            derived="$(derive_tier "$risk" "$complexity" "$policy")"
            reason=""
            if [[ "$derived" == '!'* ]]; then
                reason="${derived#!}"
            elif ! jq -e --arg t "$derived" '.tier_values | index($t) != null' \
                <<<"$catalogue" >/dev/null; then
                reason="no 'tier:$derived' label is provisioned"
            fi
            rows="$(jq -c --arg risk "$risk" --arg complexity "$complexity" \
                --arg reason "$reason" '. + [{risk: $risk, complexity: $complexity,
                  derivable: ($reason == ""),
                  reason: (if $reason == "" then null else $reason end)}]' <<<"$rows")"
        done < <(jq -r '.axes.complexity.values[]' <<<"$catalogue")
    done < <(jq -r '.axes.risk.values[]' <<<"$catalogue")
    jq -cn --argjson cases "$rows" '
      {derivable: any($cases[]; .derivable),
       reason: (if any($cases[]; .derivable) then null
                elif $cases == [] then "Risk and Complexity are not both provisioned"
                else [$cases[].reason] | unique | join("; ") end),
       cases: $cases}'
}

cmd_label() {
    local repo="" issue="" manifest="./label-registry.json" execute=0
    local policy="./.devflow.toml"
    local native_type="" native_type_seen=0
    local adds=() removes=()
    local req_impact="" req_risk="" req_complexity="" req_priority_ai=""
    local reconcile=0
    # set_axis_request AXIS VALUE — one value per axis per call, whether it
    # came from --<axis> or from --add <axis>:<value>.
    set_axis_request() {
        local var="req_${1//-/_}" cur
        [ -n "$2" ] || die 2 "--$1 requires a non-empty value"
        cur="${!var}"
        [ -z "$cur" ] || [ "$cur" = "$2" ] ||
            die 2 "conflicting $1 values requested ('$cur' and '$2')"
        printf -v "$var" '%s' "$2"
    }
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
        --impact | --risk | --complexity | --priority-ai)
            [ "$#" -ge 2 ] || usage
            set_axis_request "${1#--}" "$2"
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
            die 2 "--inapplicable is retired: apply the axis's explicit" \
                "'none' value (for example area:none) instead — needs-triage" \
                "is derived from the labels the issue carries"
            ;;
        --manifest)
            [ "$#" -ge 2 ] || usage
            manifest="$2"
            shift 2
            ;;
        --policy)
            [ "$#" -ge 2 ] || usage
            policy="$2"
            shift 2
            ;;
        --reconcile) reconcile=1 && shift ;;
        --execute) execute=1 && shift ;;
        *) usage ;;
        esac
    done
    [ -n "$repo" ] && [ -n "$issue" ] || usage
    guard_issue_number "$issue"
    guard_manifest "$manifest"
    guard_policy "$policy"
    # The wrapper binds the run to one repository; a mismatched --repo here is
    # a confused (or prompt-injected) caller, not a supported use.
    if [ -n "${TRIAGE_REPO:-}" ] && [ "$repo" != "$TRIAGE_REPO" ]; then
        die 4 "refused: --repo '$repo' does not match this run's bound" \
            "repository '$TRIAGE_REPO'"
    fi

    local l axis value var
    # Commas first: gh's --add-label treats a comma as a list separator, so a
    # manifest value like "task,blocked" would validate as one name and land
    # as two labels — one of them never validated.
    for l in "${adds[@]+"${adds[@]}"}"; do
        case "$l" in
        *,*) die 4 "refused: '$l' contains a comma — gh would split it" \
            "into multiple labels" ;;
        esac
    done
    # `--add impact:high` is the same request as `--impact high`: every axis
    # with an owner-type-dependent storage leaves the ordinary label path
    # here, so there is exactly one code path per owner type for it.
    local label_adds=()
    for l in "${adds[@]+"${adds[@]}"}"; do
        if [[ "$l" == *:* ]] && [[ "${l%%:*}" =~ $FIELD_AXIS_RE ]]; then
            set_axis_request "${l%%:*}" "${l#*:}"
        else
            label_adds+=("$l")
        fi
    done
    adds=("${label_adds[@]+"${label_adds[@]}"}")

    [ "${#adds[@]}" -gt 0 ] || [ "${#removes[@]}" -gt 0 ] ||
        [ -n "$native_type" ] || [ -n "$req_impact$req_risk$req_complexity$req_priority_ai" ] ||
        [ "$reconcile" -eq 1 ] ||
        die 2 "nothing requested — pass --add, --native-type, an axis" \
            "(--impact/--risk/--complexity/--priority-ai), --remove, or" \
            "--reconcile"

    # Requested removals are bounded to the derived marker and guarded human.
    local human_remove=0
    for l in "${removes[@]+"${removes[@]}"}"; do
        case "$l" in
        *,*) die 4 "refused: '$l' contains a comma — gh would split its removal" ;;
        human) human_remove=1 ;;
        needs-triage) ;;
        *) die 2 "--remove accepts only needs-triage or human (got '$l')" ;;
        esac
    done
    if [ "$human_remove" -eq 1 ]; then
        ! in_list human "$(printf '%s\n' "${adds[@]+"${adds[@]}"}")" ||
            die 2 "human cannot be both added and removed"
    fi

    # Validate the registry here, in this shell: a refusal inside the command
    # substitutions below would only end that subshell (no inherit_errexit)
    # and leave an empty vocabulary behind.
    if [ -f "$manifest" ]; then
        render_manifest "$manifest" >/dev/null
    fi
    local axes
    axes="$(axes_active "$repo" "$manifest")"
    # Never-list next — independent of, and senior to, any manifest content.
    for l in "${adds[@]+"${adds[@]}"}"; do
        if grep -qE "$NEVER_RE" <<<"$l"; then
            die 4 "refused: '$l' is on the triage never-list"
        fi
        case "$l" in
        tier:*)
            die 4 "refused: '$l' — the Tier is derived from Risk × Complexity" \
                "in the call that writes them, never chosen; pass --risk" \
                "and --complexity instead"
            ;;
        esac
    done
    for axis in impact risk complexity priority-ai; do
        var="req_${axis//-/_}"
        value="${!var}"
        [ -n "$value" ] || continue
        on_scale "$value" "$(axis_scale "$axis")" ||
            die 4 "refused: '$value' is not a $axis value" \
                "($(axis_scale "$axis"))"
    done

    local allowlist
    allowlist="$(allowlist_compute "$repo" "$manifest")"
    for l in "${adds[@]+"${adds[@]}"}"; do
        in_list "$l" "$allowlist" ||
            die 4 "refused: '$l' is not on the triage write-allowlist"
    done
    # Removal is a write too: effective writers must grant each requested label.
    for l in "${removes[@]+"${removes[@]}"}"; do
        in_list "$l" "$allowlist" ||
            die 4 "refused: this repo's manifest or live fallback does not grant" \
                "agents '$l', so triage may not remove it either"
    done

    # needs-triage is never an ordinary add: it is derived below, and an
    # explicit request is only checked against that derivation.
    local nt_explicit_add=0 nt_explicit_remove=0
    label_adds=()
    for l in "${adds[@]+"${adds[@]}"}"; do
        if [ "$l" = "needs-triage" ]; then
            nt_explicit_add=1
        else
            label_adds+=("$l")
        fi
    done
    adds=("${label_adds[@]+"${label_adds[@]}"}")
    for l in "${removes[@]+"${removes[@]}"}"; do
        [ "$l" != "needs-triage" ] || nt_explicit_remove=1
    done
    [ "$nt_explicit_add" -eq 0 ] || [ "$nt_explicit_remove" -eq 0 ] ||
        die 2 "needs-triage cannot be both added and removed"

    local owner_type
    owner_type="$(gh api "repos/$repo" -q .owner.type)" ||
        die 2 "could not read the owner type of $repo"

    # RECOGNIZED work-types classify an issue whoever applied them; org repos
    # classify with native issue Type instead. (Adds are separately bound to
    # the agent-writable allowlist above.)
    local work_types class_json enabled_types=""
    work_types="$(work_types_recognized "$repo" "$manifest")"
    # What the repository provisions for Impact/Risk/Complexity/Priority (AI)
    # — in the owner type's ONE storage: labels on a personal account, issue
    # fields on an organization (where the same-named labels are inert and a
    # stray one never counts).
    class_json="$(classification_axes_json "$repo" "$owner_type")"

    # ── One snapshot drives every write ─────────────────────────────────────
    # read_state reads the issue: its labels on every owner type and, on an
    # organization, its field values and native Type. plan_call computes
    # every write and every derived value (axis writes, the Tier add and
    # removes, needs-triage) from that state alone. A dry run reads and plans
    # once. An execute run plans from the first read, then — immediately
    # before its first mutation — takes ONE fresh snapshot, refuses if a value
    # it writes changed (triage only fills) or a human Priority appeared before
    # a Priority (AI) replacement, and re-plans everything from the snapshot.
    # No later re-read exists to disagree with it.
    local human_issue_json="" human_guard_jq="" title_module_dir
    title_module_dir="$asset_dir/../../issue-title-support/assets"
    if [ "$human_remove" -eq 1 ]; then
        human_guard_jq="$(cat "$title_module_dir/issue-conformance.jq" \
            "$asset_dir/human-work.jq")" ||
            die 2 "could not read the shared human-work projection"
    fi
    local current="" issue_fields_json='{"id":null,"fields":{}}' issue_id=""
    local native_state=""
    read_state() {
        if [ "$human_remove" -eq 1 ]; then
            human_issue_json="$(gh issue view "$issue" --repo "$repo" \
                --json labels,title,body)" ||
                die 2 "could not read live title/body/labels of $repo#$issue"
            jq -e '(.title | type == "string") and (.body | type == "string")
                and (.labels | type == "array")
                and all(.labels[]; .name | type == "string")' \
                <<<"$human_issue_json" >/dev/null ||
                die 2 "could not verify live title/body/labels of $repo#$issue"
            current="$(jq -r '.labels[].name' <<<"$human_issue_json")"
        else
            current="$(gh issue view "$issue" --repo "$repo" --json labels \
                -q '.labels[].name')" ||
                die 2 "could not read labels of $repo#$issue"
        fi
        if [ "$human_remove" -eq 1 ] && grep -qE '^(claim:|agent:)' <<<"$current"; then
            die 4 "refused: $repo#$issue is claimed — report-only, no write"
        fi
        if [ "$owner_type" = "Organization" ]; then
            issue_fields_json="$(org_issue_field_values "$repo" "$issue")" ||
                die 2 "could not read the issue field values of $repo#$issue"
            issue_id="$(jq -r '.id // empty' <<<"$issue_fields_json")"
            native_state="$(native_type_state_read "$repo" "$issue")" ||
                native_state=""
        fi
    }
    # plan_call's results (it assigns these; they outlive each call).
    local effective_adds=() effective_native_type="" notes=() field_writes=()
    local pai_replace=0 tier_add="" tier_removes=() nt_add=0 nt_remove=0
    local label_change_adds=() label_change_removes=() org_field_writes=()
    local marker_first=0
    plan_call() {
        # Recomputed from every snapshot, including reads between org mutations.
        if [ "$human_remove" -eq 1 ]; then
            local human_facts
            human_facts="$(jq -L "$title_module_dir" --argjson known '[]' "$human_guard_jq"'
                human_work(.; [.labels[].name])' <<<"$human_issue_json")" ||
                die 2 "could not evaluate human-removal guards for $repo#$issue"
            [ "$(jq -r '.collector' <<<"$human_facts")" = false ] ||
                die 4 "refused: removal of 'human' from $repo#$issue — collector title"
            # Fail closed on ambiguous section boundaries, even inside code fences.
            jq -e '.body | split("\n")
                | all(.[]; test("^ {1,3}#{1,6}([ \\t]|$)") | not)' \
                <<<"$human_issue_json" >/dev/null ||
                die 4 "refused: removal of 'human' from $repo#$issue —" \
                    "ambiguous section boundary: heading indented one to three spaces"
            jq -e '.human_criteria * 2 <= .total_criteria' \
                <<<"$human_facts" >/dev/null ||
                die 4 "refused: removal of 'human' from $repo#$issue — [HUMAN] majority"
        fi

        effective_adds=()
        for l in "${adds[@]+"${adds[@]}"}"; do
            in_list "$l" "$current" || effective_adds+=("$l")
        done

        local current_native_type=""
        effective_native_type="$native_type"
        if [ -n "$native_type" ]; then
            [ "$owner_type" = "Organization" ] ||
                die 5 "refused: --native-type is available only on organization repos"
            [ -n "$enabled_types" ] ||
                enabled_types="$(enabled_native_types "$repo")" ||
                die 2 "could not list enabled native issue Types of $repo"
            in_list "$native_type" "$enabled_types" ||
                die 4 "refused: native issue Type '$native_type' is not enabled on $repo"
            [ -n "$native_state" ] ||
                die 2 "could not read the current native issue Type of $repo#$issue"
            current_native_type="$native_state"
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

        # ── Impact / Risk / Complexity / Priority (AI) ──────────────────────────
        # What the repository provisions, and what the issue currently holds, in
        # the owner type's ONE storage: labels on a personal account, issue
        # fields on an organization (where the same-named labels are inert and a
        # stray one never counts).
        # axis_current AXIS — unset | set:<value> | conflict | unknown:<value>
        axis_current() {
            local a="$1" n v
            if [ "$owner_type" = "Organization" ]; then
                v="$(jq -r --arg f "$(axis_field_name "$a")" \
                    '.fields[$f] // empty | ascii_downcase' <<<"$issue_fields_json")"
                if [ -z "$v" ]; then
                    echo unset
                elif on_scale "$v" "$(axis_scale "$a")"; then
                    echo "set:$v"
                else
                    echo "unknown:$v"
                fi
                return 0
            fi
            n="$(printf '%s\n' "$current" | grep -c "^$a:" || true)"
            if [ "$n" -eq 0 ]; then
                echo unset
            elif [ "$n" -gt 1 ]; then
                echo conflict
            else
                v="$(printf '%s\n' "$current" | grep "^$a:")"
                v="${v#*:}"
                if on_scale "$v" "$(axis_scale "$a")"; then
                    echo "set:$v"
                else
                    echo "unknown:$v"
                fi
            fi
        }
        axis_provisioned() {
            [ "$(jq -r --arg a "$1" '.axes[$a].provisioned' <<<"$class_json")" = true ]
        }
        axis_value_provisioned() {
            jq -e --arg a "$1" --arg v "$2" '.axes[$a].values | index($v) != null' \
                <<<"$class_json" >/dev/null
        }
        human_priority() {
            if [ "$owner_type" = "Organization" ]; then
                jq -r '.fields["Priority"] // empty' <<<"$issue_fields_json"
            else
                printf '%s\n' "$current" | grep '^priority:' | sed 's/^priority://' |
                    paste -sd ',' - || true
            fi
        }
        storage_name() {
            if [ "$owner_type" = "Organization" ]; then
                echo "issue field '$(axis_field_name "$1")'"
            else
                echo "$1:* labels"
            fi
        }

        notes=() field_writes=()
        local axis_label_adds=() replace_removes=()
        local post_impact="" post_risk="" post_complexity="" class_changed=0 cur
        pai_replace=0
        for axis in $FIELD_AXES; do
            cur="$(axis_current "$axis")"
            var="req_${axis//-/_}"
            value="${!var}"
            [ "${cur%%:*}" != set ] || printf -v "post_$axis" '%s' "${cur#set:}"
            [ -n "$value" ] || continue
            axis_provisioned "$axis" ||
                die 4 "refused: $repo provisions no $axis ($(storage_name "$axis"))"
            axis_value_provisioned "$axis" "$value" ||
                die 4 "refused: '$value' is not a provisioned $axis value on $repo" \
                    "($(storage_name "$axis"))"
            case "$cur" in
            unset)
                field_writes+=("$axis=$value")
                printf -v "post_$axis" '%s' "$value"
                class_changed=1
                ;;
            "set:$value") ;;
            conflict)
                die 4 "refused: $repo#$issue carries more than one $axis:* label —" \
                    "a human must resolve the conflict; report it"
                ;;
            *)
                die 4 "refused: $repo#$issue already has $axis '${cur#*:}' —" \
                    "triage fills an unset axis, it never re-rates one"
                ;;
            esac
        done

        if [ -n "$req_priority_ai" ]; then
            for axis in $FIELD_AXES; do
                var="post_$axis"
                [ -n "${!var}" ] ||
                    die 6 "refused: Priority (AI) is set only alongside a complete" \
                        "Impact, Risk and Complexity — $axis is unset"
            done
            axis_provisioned priority-ai ||
                die 4 "refused: $repo provisions no Priority (AI)" \
                    "($(storage_name priority-ai))"
            axis_value_provisioned priority-ai "$req_priority_ai" ||
                die 4 "refused: '$req_priority_ai' is not a provisioned Priority" \
                    "(AI) value on $repo ($(storage_name priority-ai))"
            local human
            human="$(human_priority)"
            [ -z "$human" ] ||
                notes+=("human Priority '$human' is set on $repo#$issue — reported, not changed; it overrides Priority (AI)")
            cur="$(axis_current priority-ai)"
            case "$cur" in
            unset) field_writes+=("priority-ai=$req_priority_ai") ;;
            "set:$req_priority_ai") ;;
            *)
                if [ -z "$human" ] && [ "$class_changed" -eq 1 ]; then
                    field_writes+=("priority-ai=$req_priority_ai")
                    pai_replace=1
                    # Remove the OTHER values only: the requested one may
                    # already be among conflicting labels, and removing it
                    # beside its own add would race the two edits.
                    if [ "$owner_type" != "Organization" ]; then
                        while IFS= read -r l; do
                            [ -n "$l" ] || continue
                            [ "$l" != "priority-ai:$req_priority_ai" ] || continue
                            replace_removes+=("$l")
                        done < <(printf '%s\n' "$current" | grep '^priority-ai:' || true)
                    fi
                elif [ -n "$human" ]; then
                    notes+=("Priority (AI) '${cur#*:}' kept on $repo#$issue — a human Priority is set")
                else
                    notes+=("Priority (AI) '${cur#*:}' kept on $repo#$issue — this call did not change the classification")
                fi
                ;;
            esac
        fi
        if [ "$owner_type" != "Organization" ]; then
            for l in "${field_writes[@]+"${field_writes[@]}"}"; do
                axis_label_adds+=("${l%%=*}:${l#*=}")
            done
        fi

        # ── Tier: derived wherever Risk and Complexity are both set ─────────────
        # Written in the call that writes Risk or Complexity, and repaired by any
        # later call (a missing or stale label) — never over tier:pinned. Why it
        # was NOT written is said only when this call wrote an input or asked to
        # reconcile; an unrelated label call stays quiet about it.
        tier_add="" tier_removes=()
        local writes_rc=0 tier_quiet=1
        for l in "${field_writes[@]+"${field_writes[@]}"}"; do
            case "${l%%=*}" in risk | complexity) writes_rc=1 ;; esac
        done
        [ "$writes_rc" -eq 0 ] && [ "$reconcile" -eq 0 ] || tier_quiet=0
        tier_note() {
            [ "$tier_quiet" -eq 1 ] || notes+=("$1")
        }
        if in_list "tier:pinned" "$current"; then
            tier_note "tier: $repo#$issue carries tier:pinned — the Tier label is left as it is"
        elif [ -z "$post_risk" ] || [ -z "$post_complexity" ]; then
            tier_note "tier: not derived — Risk and Complexity are both needed"
        else
            local derived
            derived="$(derive_tier "$post_risk" "$post_complexity" "$policy")"
            if [ "${derived#!}" != "$derived" ]; then
                tier_note "tier: not written — ${derived#!}"
            elif ! jq -e --arg t "$derived" '.tier_values | index($t) != null' \
                <<<"$class_json" >/dev/null; then
                tier_note "tier: not written — $repo has no 'tier:$derived' label"
            else
                in_list "tier:$derived" "$current" || tier_add="tier:$derived"
                # Every other unqualified Tier label goes: the other rungs, the
                # retired tier:adaptive, any off-ladder value. Never tier:pinned (held
                # above) and never a scoped tier:<role>:* override.
                while IFS= read -r value; do
                    [ -n "$value" ] || continue
                    [ "$value" != "tier:pinned" ] && [ "$value" != "tier:$derived" ] ||
                        continue
                    tier_removes+=("$value")
                done < <(printf '%s\n' "$current" | grep -E '^tier:[^:]+$' || true)
                if [ -n "$tier_add" ] || [ "${#tier_removes[@]}" -gt 0 ]; then
                    notes+=("tier: derived '$derived' from Risk $post_risk × Complexity $post_complexity")
                fi
            fi
        fi

        # Exclusive label axes: adding to an axis must leave it with exactly one
        # label.
        local post count
        post="$current"
        for l in "${effective_adds[@]+"${effective_adds[@]}"}" \
            "${axis_label_adds[@]+"${axis_label_adds[@]}"}" $tier_add; do
            post="$(printf '%s\n%s' "$post" "$l")"
        done
        for l in "${replace_removes[@]+"${replace_removes[@]}"}" \
            "${tier_removes[@]+"${tier_removes[@]}"}"; do
            post="$(printf '%s\n' "$post" | grep -vxF -- "$l" || true)"
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

        # ── needs-triage, derived from the required set ─────────────────────────
        # Required (harmon-init ADR 2026-09-30 D6): a work type in the
        # owner-appropriate form; exactly one recognized label of every active
        # label axis (`none` is an ordinary recognized value — the explicit
        # "does not apply"); and each of Impact, Risk and Complexity the
        # repository provisions. Judged on the state this call leaves behind. A
        # conflicted axis is never "present", and neither is a label whose value
        # the active taxonomy does not recognize (retired, misspelled).
        local missing=() indeterminate="" recognized
        recognized="$(axis_values_recognized "$repo" "$manifest")"
        if [ "$owner_type" = "Organization" ]; then
            local native=""
            if [ -n "$native_type" ]; then
                native="set:$native_type"
            elif [ -n "$native_state" ]; then
                native="$native_state"
            else
                indeterminate="could not verify the native issue Type"
            fi
            [ "$native" != "unset" ] || missing+=("work type (no native issue Type)")
        else
            local have_wt=1
            while IFS= read -r l; do
                [ -n "$l" ] || continue
                if in_list "$l" "$post"; then
                    have_wt=0
                    break
                fi
            done <<<"$work_types"
            [ "$have_wt" -eq 0 ] || missing+=("work type (no work-type label)")
        fi
        for axis in $axes; do
            count="$(printf '%s\n' "$post" | grep -c "^$axis:" || true)"
            if [ "$count" -gt 1 ]; then
                missing+=("$axis (conflicted: $count labels)")
            elif [ "$count" -eq 0 ]; then
                missing+=("$axis (no $axis:* label — apply its value, or $axis:none)")
            else
                l="$(printf '%s\n' "$post" | grep "^$axis:")"
                in_list "$l" "$recognized" ||
                    missing+=("$axis ('$l' is not in the active $axis taxonomy)")
            fi
        done
        for axis in $FIELD_AXES; do
            axis_provisioned "$axis" || continue
            var="post_$axis"
            [ -n "${!var}" ] || missing+=("$axis (unset)")
        done

        local nt_present=0 nt_granted=0
        nt_add=0 nt_remove=0
        in_list needs-triage "$current" && nt_present=1
        in_list needs-triage "$allowlist" && nt_granted=1
        local missing_text
        missing_text="$(printf '%s; ' "${missing[@]+"${missing[@]}"}")"
        missing_text="${missing_text%; }"
        if [ -n "$indeterminate" ]; then
            # Only a REMOVAL needs the whole required set proven; anything already
            # known missing is enough to add the marker.
            [ "$nt_explicit_remove" -eq 0 ] ||
                die 6 "refused: $indeterminate — needs-triage stays"
            if [ "$nt_present" -eq 0 ] && [ "$nt_granted" -eq 1 ] &&
                { [ "${#missing[@]}" -gt 0 ] || [ "$nt_explicit_add" -eq 1 ]; }; then
                nt_add=1
                notes+=("needs-triage: derived — missing: ${missing_text:-unverified work type} ($indeterminate)")
            else
                notes+=("needs-triage: left as it is — $indeterminate")
            fi
        elif [ "${#missing[@]}" -gt 0 ]; then
            [ "$nt_explicit_remove" -eq 0 ] ||
                die 6 "refused: needs-triage stays — classification is incomplete:" \
                    "$missing_text"
            if [ "$nt_present" -eq 0 ]; then
                if [ "$nt_granted" -eq 1 ]; then
                    nt_add=1
                    notes+=("needs-triage: derived — missing: $missing_text")
                else
                    notes+=("needs-triage: not granted to agents by this repo's manifest — left as it is (missing: $missing_text)")
                fi
            fi
        else
            [ "$nt_explicit_add" -eq 0 ] ||
                die 6 "refused: needs-triage is derived — every required axis is" \
                    "present, so it is not added"
            if [ "$nt_present" -eq 1 ]; then
                if [ "$nt_granted" -eq 1 ]; then
                    nt_remove=1
                    notes+=("needs-triage: derived — every required axis is present")
                else
                    notes+=("needs-triage: not granted to agents by this repo's manifest — left as it is (classification complete)")
                fi
            fi
        fi

        label_change_adds=("${effective_adds[@]+"${effective_adds[@]}"}"
            "${axis_label_adds[@]+"${axis_label_adds[@]}"}")
        [ -z "$tier_add" ] || label_change_adds+=("$tier_add")
        label_change_removes=("${replace_removes[@]+"${replace_removes[@]}"}"
            "${tier_removes[@]+"${tier_removes[@]}"}")
        # Removals come from labels read off the issue, not from the caller:
        # gh splits a comma-bearing name into two labels, so one such label
        # could remove another (tier:pinned, say) that was never validated.
        for l in "${label_change_removes[@]+"${label_change_removes[@]}"}"; do
            case "$l" in
            *,*) die 4 "refused: '$l' on $repo#$issue contains a comma — gh would" \
                "split its removal into multiple labels; report it" ;;
            esac
        done
        # Only the explicit guarded request can remove human; replacements above
        # remain comma-checked and never select that label.
        if [ "$human_remove" -eq 1 ] && in_list human "$current"; then
            label_change_removes+=("human")
        fi
        org_field_writes=()
        [ "$owner_type" != "Organization" ] ||
            org_field_writes=("${field_writes[@]+"${field_writes[@]}"}")

        # The visibility marker goes first whenever a non-label write (a native
        # Type, an issue field) precedes the label edit: if that write lands and
        # a later one fails, the issue must still be visible to triage.
        marker_first=0
        if [ "$nt_add" -eq 1 ] &&
            { [ -n "$effective_native_type" ] || [ "${#org_field_writes[@]}" -gt 0 ]; }; then
            marker_first=1
        fi
        [ "$nt_add" -eq 0 ] || [ "$marker_first" -eq 1 ] ||
            label_change_adds+=("needs-triage")
    }
    print_notes() {
        for l in "${notes[@]+"${notes[@]}"}"; do
            echo "$l"
        done
    }
    nothing_to_do() {
        [ "${#label_change_adds[@]}" -eq 0 ] &&
            [ "${#label_change_removes[@]}" -eq 0 ] &&
            [ "${#org_field_writes[@]}" -eq 0 ] && [ -z "$effective_native_type" ] &&
            [ "$nt_add" -eq 0 ] && [ "$nt_remove" -eq 0 ]
    }

    read_state
    plan_call
    if nothing_to_do; then
        print_notes
        echo "triage-apply: nothing to do — requested labels already present"
        return 0
    fi
    # Dry-run promises the execute outcome it would attempt. Probe the CLI
    # capability before printing a native-Type mutation so an old gh cannot
    # make dry-run appear executable when --execute would refuse.
    local probed=0
    if [ -n "$effective_native_type" ]; then
        gh_supports_native_type_write ||
            die 2 "gh issue edit --type requires GitHub CLI 2.98 or newer"
        probed=1
    fi

    if [ "$execute" -eq 1 ]; then
        [ "${TRIAGE_EXECUTE:-0}" = "1" ] ||
            die 2 "--execute requires TRIAGE_EXECUTE=1 in the environment" \
                "(set by the task triage wrapper for supervised runs)"
        # The snapshot, immediately before the first mutation.
        local first_states="" first_pai_replace="$pai_replace" w
        for w in "${field_writes[@]+"${field_writes[@]}"}"; do
            first_states="$(printf '%s\n%s=%s' "$first_states" "${w%%=*}" \
                "$(axis_current "${w%%=*}")")"
        done
        read_state
        while IFS= read -r w; do
            [ -n "$w" ] || continue
            [ "$(axis_current "${w%%=*}")" = "${w#*=}" ] ||
                die 4 "refused: $repo#$issue $(storage_name "${w%%=*}") changed" \
                    "while triage was preparing its write — triage only fills"
        done <<<"$first_states"
        if [ "$first_pai_replace" -eq 1 ] && [ -n "$(human_priority)" ]; then
            die 4 "refused: a human Priority was set on $repo#$issue while" \
                "triage was preparing to replace Priority (AI)"
        fi
        plan_call
        if nothing_to_do; then
            print_notes
            echo "triage-apply: nothing to do — requested labels already present"
            return 0
        fi
        if [ -n "$effective_native_type" ] && [ "$probed" -eq 0 ]; then
            gh_supports_native_type_write ||
                die 2 "gh issue edit --type requires GitHub CLI 2.98 or newer"
        fi
    fi
    print_notes

    # ── A fresh read before EVERY mutation ──────────────────────────────────
    # The snapshot above is the read for the first mutation. Each later one
    # (an organization can make up to five: the needs-triage marker, the
    # native Type, the field mutation, the label edit, the needs-triage
    # removal) is preceded by before_mutation: re-read, re-plan, and refuse
    # (exit 4, no further write) unless the remaining writes are exactly the
    # ones still planned and no tier:pinned or human Priority has appeared.
    # Writes already made are recorded in `done_writes`, so the comparison
    # covers only what is left.
    local mutated=0 done_writes=""
    # plan_signature [all] — the plan's writes, one per line; without
    # `all`, minus the writes this call has already made.
    plan_signature() {
        local x scope="${1:-remaining}"
        {
            [ "$nt_add" -eq 0 ] || echo "nt-add"
            [ -z "$effective_native_type" ] || echo "type:$effective_native_type"
            for x in "${org_field_writes[@]+"${org_field_writes[@]}"}"; do
                echo "field:$x"
            done
            for x in "${label_change_adds[@]+"${label_change_adds[@]}"}"; do
                [ "$x" = needs-triage ] || echo "label+:$x"
            done
            for x in "${label_change_removes[@]+"${label_change_removes[@]}"}"; do
                echo "label-:$x"
            done
            [ "$nt_remove" -eq 0 ] || echo "nt-remove"
        } | while IFS= read -r x; do
            [ "$scope" = all ] || ! in_list "$x" "$done_writes" || continue
            echo "$x"
        done
    }
    before_mutation() {
        if [ "$mutated" -eq 0 ]; then
            mutated=1
            return 0
        fi
        local planned was_pinned=0 had_human
        planned="$(plan_signature)"
        in_list "tier:pinned" "$current" && was_pinned=1
        had_human="$(human_priority)"
        read_state
        plan_call
        if [ "$was_pinned" -eq 0 ] && in_list "tier:pinned" "$current"; then
            die 4 "refused: tier:pinned was added to $repo#$issue between" \
                "triage's writes — no further write was made"
        fi
        if [ -z "$had_human" ] && [ -n "$(human_priority)" ]; then
            die 4 "refused: a human Priority was set on $repo#$issue between" \
                "triage's writes — no further write was made"
        fi
        # A write this call already made that the fresh plan needs again was
        # reverted by someone else: refuse rather than build on it.
        local again
        again="$(plan_signature all | while IFS= read -r x; do
            if in_list "$x" "$done_writes"; then echo "$x"; fi
        done)"
        [ -z "$again" ] ||
            die 4 "refused: $repo#$issue changed between triage's writes —" \
                "a write it already made was reverted ($(printf '%s' "$again" |
                    paste -sd ' ' -)); no further write was made"
        [ "$(plan_signature)" = "$planned" ] ||
            die 4 "refused: $repo#$issue changed between triage's writes —" \
                "the remaining writes no longer match its plan; no further" \
                "write was made (planned: $(printf '%s' "$planned" | paste -sd ' ' -);" \
                "now: $(plan_signature | paste -sd ' ' -))"
    }
    record_done() {
        done_writes="$(printf '%s\n%s' "$done_writes" "$1")"
    }

    if [ "$execute" -eq 0 ]; then
        [ "$marker_first" -eq 0 ] ||
            echo "DRY-RUN would add 'needs-triage' to $repo#$issue"
        if [ -n "$effective_native_type" ]; then
            echo "DRY-RUN would set native issue Type '$effective_native_type' on $repo#$issue"
        fi
        for l in "${org_field_writes[@]+"${org_field_writes[@]}"}"; do
            echo "DRY-RUN would set issue field '$(axis_field_name "${l%%=*}")' to '${l#*=}' on $repo#$issue"
        done
        for l in "${label_change_adds[@]+"${label_change_adds[@]}"}"; do
            echo "DRY-RUN would add '$l' to $repo#$issue"
        done
        for l in "${label_change_removes[@]+"${label_change_removes[@]}"}"; do
            echo "DRY-RUN would remove '$l' from $repo#$issue"
        done
        [ "$nt_remove" -eq 0 ] ||
            echo "DRY-RUN would remove 'needs-triage' from $repo#$issue"
        return 0
    fi

    if [ "$marker_first" -eq 1 ]; then
        before_mutation
        gh issue edit "$issue" --repo "$repo" --add-label needs-triage \
            >/dev/null </dev/null ||
            die 1 "write failed: gh issue edit $repo#$issue"
        record_done "nt-add"
        echo "APPLIED add 'needs-triage' to $repo#$issue"
    fi

    # GitHub CLI applies label edits before its deferred issue-Type mutation.
    # The only label intentionally established before Type is needs-triage
    # above, which keeps an otherwise untyped issue visible if its Type write
    # fails. All other labels wait for the verified Type.
    # The read just before this write (the snapshot, or before_mutation's)
    # showed the Type unset — plan_call refuses a different one.
    if [ -n "$effective_native_type" ]; then
        before_mutation
        local current_native_type
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
        record_done "type:$effective_native_type"
        echo "APPLIED native issue Type '$effective_native_type' to $repo#$issue"
    fi

    # Organization axes: one setIssueFieldValue mutation, then a verified
    # re-read — a field write that cannot be confirmed stops the run before
    # the Tier label or a needs-triage removal could claim it landed.
    if [ "${#org_field_writes[@]}" -gt 0 ]; then
        before_mutation
        local catalogue fields_input w name opt
        catalogue="$(org_issue_fields "$repo")" ||
            die 2 "could not re-read the issue fields of $repo"
        fields_input='[]'
        for w in "${org_field_writes[@]}"; do
            name="$(axis_field_name "${w%%=*}")"
            opt="$(jq -c --arg n "$name" --arg v "${w#*=}" '
                [.[] | select(.name == $n)] | first
                | {fieldId: .id,
                   singleSelectOptionId: ([.options[]
                       | select((.name | ascii_downcase) == $v)] | first | .id)}
                | select(.fieldId != null and .singleSelectOptionId != null)' \
                <<<"$catalogue")"
            [ -n "$opt" ] ||
                die 2 "could not resolve issue field '$name' option '${w#*=}' on $repo"
            fields_input="$(jq -c --argjson o "$opt" '. + [$o]' <<<"$fields_input")"
        done
        [ -n "$issue_id" ] || die 2 "could not resolve the node id of $repo#$issue"
        org_set_issue_fields "$issue_id" "$fields_input" </dev/null ||
            die 1 "write failed: setIssueFieldValue on $repo#$issue"
        for w in "${org_field_writes[@]}"; do
            record_done "field:$w"
        done
        local attempts=0 verified=""
        while [ "$attempts" -lt 3 ]; do
            verified="$(org_issue_field_values "$repo" "$issue")" && break
            verified=""
            attempts=$((attempts + 1))
        done
        [ -n "$verified" ] ||
            die 2 "write indeterminate: the issue fields may have applied to" \
                "$repo#$issue but could not be verified after 3 reads;" \
                "no labels or needs-triage removal were attempted"
        for w in "${org_field_writes[@]}"; do
            name="$(axis_field_name "${w%%=*}")"
            [ "$(jq -r --arg n "$name" '.fields[$n] // empty | ascii_downcase' \
                <<<"$verified")" = "${w#*=}" ] ||
                die 1 "write failed: $repo#$issue issue field '$name' did not" \
                    "become '${w#*=}'"
            echo "APPLIED issue field '$name' = '${w#*=}' on $repo#$issue"
        done
    fi

    # undo_tier_if_pinned — run after a label edit that changed the Tier,
    # whether it succeeded or failed (a failed edit can still land).
    # before_mutation checked for tier:pinned on the read before the edit, but
    # a pin added between that read and the edit is not seen there, and GitHub
    # has no conditional label edit. So read once more: a pin now present
    # means this call overrode a human's choice, and whatever Tier part of the
    # edit is on the issue is undone. Returns 1 when a pin was found, 0
    # otherwise; a pin added after this read is not seen.
    # With `failed`, the edit itself reported failure: an unreadable result
    # keeps the write-failure exit (1) rather than becoming exit 2.
    undo_tier_if_pinned() {
        [ -n "$tier_add" ] || [ "${#tier_removes[@]}" -gt 0 ] || return 0
        local post_edit restore=() readd=() t
        if ! post_edit="$(gh issue view "$issue" --repo "$repo" --json labels \
            -q '.labels[].name')"; then
            [ "${1:-}" != failed ] ||
                die 1 "write failed: gh issue edit $repo#$issue, and the read" \
                    "that checks for a tier:pinned added during it failed too;" \
                    "check its Tier labels by hand"
            die 2 "write indeterminate: the label edit on $repo#$issue may" \
                "have changed its Tier, but the read that checks for a" \
                "tier:pinned added during it failed; check its Tier labels by hand"
        fi
        in_list "tier:pinned" "$post_edit" || return 0
        # The restore leaves the issue with the human's Tier: this call's
        # added Tier goes, and a Tier it removed comes back only when no
        # tier:<value> appeared since the read before the edit (`current`).
        # A human who replaced the Tier before pinning (the documented pin
        # workflow) keeps their choice alone; a Tier that was already there
        # is not mistaken for theirs.
        local human_tier
        human_tier="$(grep -E '^tier:[^:]+$' <<<"$post_edit" |
            grep -vxF -e "tier:pinned" -e "${tier_add:-tier:pinned}" |
            while IFS= read -r t; do
                in_list "$t" "$current" || echo "$t"
            done || true)"
        if [ -z "$human_tier" ]; then
            for t in "${tier_removes[@]+"${tier_removes[@]}"}"; do
                in_list "$t" "$post_edit" || readd+=("$t")
            done
        fi
        [ "${#readd[@]}" -eq 0 ] || restore+=(--add-label "$(
            IFS=,
            echo "${readd[*]}"
        )")
        if [ -n "$tier_add" ] && in_list "$tier_add" "$post_edit"; then
            restore+=(--remove-label "$tier_add")
        fi
        [ "${#restore[@]}" -gt 0 ] || return 1
        gh issue edit "$issue" --repo "$repo" "${restore[@]}" \
            >/dev/null </dev/null ||
            die 1 "write failed: tier:pinned was added to $repo#$issue during" \
                "triage's label edit, and restoring its Tier failed — fix by" \
                "hand: ${restore[*]}"
        for t in "${readd[@]+"${readd[@]}"}"; do
            echo "RESTORED '$t' on $repo#$issue"
        done
        if [ -n "$tier_add" ] && in_list "$tier_add" "$post_edit"; then
            echo "RESTORED removal of '$tier_add' from $repo#$issue"
            # A human who pinned the very Tier this call derived looks the
            # same on the issue as this call's own write; say so rather than
            # undo their choice silently.
            echo "NOTE: if '$tier_add' on $repo#$issue was set by the person" \
                "who pinned it, re-add it — triage cannot tell it from its own write" >&2
        fi
        return 1
    }

    # One label edit for every add and every replaced value; the needs-triage
    # removal stays a separate, last edit so a failed add leaves it visible.
    local args=()
    if [ "${#label_change_adds[@]}" -gt 0 ]; then
        args+=(--add-label "$(
            IFS=,
            echo "${label_change_adds[*]}"
        )")
    fi
    if [ "${#label_change_removes[@]}" -gt 0 ]; then
        args+=(--remove-label "$(
            IFS=,
            echo "${label_change_removes[*]}"
        )")
    fi
    if [ "${#args[@]}" -gt 0 ]; then
        before_mutation
        # The re-plan may have settled the label lists afresh; rebuild the
        # edit from them (they equal what was planned, or it refused).
        args=()
        [ "${#label_change_adds[@]}" -eq 0 ] || args+=(--add-label "$(
            IFS=,
            echo "${label_change_adds[*]}"
        )")
        [ "${#label_change_removes[@]}" -eq 0 ] || args+=(--remove-label "$(
            IFS=,
            echo "${label_change_removes[*]}"
        )")
        if ! gh issue edit "$issue" --repo "$repo" "${args[@]}" >/dev/null </dev/null; then
            # A failed edit can still land. Report proven removals and unknown
            # outcomes separately, while retaining the failed call's exit.
            if in_list human "$(printf '%s\n' "${label_change_removes[@]+"${label_change_removes[@]}"}")"; then
                local failed_edit_labels
                if ! failed_edit_labels="$(gh issue view "$issue" --repo "$repo" \
                    --json labels)" ||
                    ! jq -e '(.labels | type == "array")
                        and all(.labels[]; .name | type == "string")' \
                        <<<"$failed_edit_labels" >/dev/null; then
                    echo "INDETERMINATE remove 'human' from $repo#$issue (edit failed; re-read failed)"
                elif jq -e 'all(.labels[]; .name != "human")' \
                    <<<"$failed_edit_labels" >/dev/null; then
                    record_done "label-:human"
                    echo "APPLIED remove 'human' from $repo#$issue (confirmed by re-read after failed edit)"
                fi
            fi
            undo_tier_if_pinned failed ||
                die 1 "write failed: gh issue edit $repo#$issue; tier:pinned" \
                    "is now on it, and any Tier change of this edit that" \
                    "landed was undone"
            die 1 "write failed: gh issue edit $repo#$issue"
        fi
        for l in "${label_change_adds[@]+"${label_change_adds[@]}"}"; do
            if [ "$l" = needs-triage ]; then
                record_done "nt-add"
            else
                record_done "label+:$l"
            fi
        done
        for l in "${label_change_removes[@]+"${label_change_removes[@]}"}"; do
            record_done "label-:$l"
        done
    fi
    for l in "${label_change_adds[@]+"${label_change_adds[@]}"}"; do
        echo "APPLIED add '$l' to $repo#$issue"
    done
    for l in "${label_change_removes[@]+"${label_change_removes[@]}"}"; do
        echo "APPLIED remove '$l' from $repo#$issue"
    done
    if [ "${#args[@]}" -gt 0 ] && ! undo_tier_if_pinned; then
        die 4 "refused: tier:pinned was added to $repo#$issue during" \
            "triage's label edit — its Tier change was undone and no" \
            "further write was made"
    fi
    if [ "$nt_remove" -eq 1 ]; then
        before_mutation
        gh issue edit "$issue" --repo "$repo" --remove-label needs-triage \
            >/dev/null </dev/null ||
            die 1 "write failed: gh issue edit $repo#$issue"
        echo "APPLIED remove 'needs-triage' from $repo#$issue"
    fi
}

[ "$#" -ge 1 ] || usage
cmd="$1"
shift
guard_run_root
case "$cmd" in
check-root) [ "$#" -eq 0 ] || usage ;;
allowlist) cmd_allowlist "$@" ;;
axes) cmd_axes "$@" ;;
axis-values) cmd_axis_values "$@" ;;
work-types) cmd_work_types "$@" ;;
classification-axes) cmd_classification_axes "$@" ;;
native-type) cmd_native_type "$@" ;;
native-types) cmd_native_types "$@" ;;
label) cmd_label "$@" ;;
*) usage ;;
esac
