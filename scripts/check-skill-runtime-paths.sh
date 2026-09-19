#!/usr/bin/env bash
# check-skill-runtime-paths.sh — fail when anything under `ai/skills/` or
# `ai/agents/` INVOKES or LINKS a repository-root `scripts/<name>.(sh|mjs|py)`.
#
# Why (harmon-devkit#974): skills are vendored into consumer repositories by
# `task sync:skills`, which ships `ai/skills/` (and, per the sync manifest's
# optional `agents:` block, `ai/agents/`) and nothing from `scripts/`.
# A skill whose runtime lives at a repository-root path therefore installs
# somewhere it cannot run, and the failure surfaces only when somebody tries to
# use it. A script one skill uses belongs in that skill's own `assets/`; a
# script several skills share belongs in a shared support package
# (`dev-flow-support`, the way `issue-title-support` already works). This guard
# is what stops that class of gap returning silently.
#
# WHAT IT LOOKS FOR — invocation and link shapes only, deliberately:
#
#   ./scripts/x.sh                  command-position, relative
#   bash|sh|node|python scripts/x   an interpreter given the path
#   "$root"/scripts/x.sh            a variable-rooted path (any variable)
#   $repo_root/scripts/x.mjs        the same, unquoted
#   from '../../scripts/x.mjs'      an ES-module import or require()
#   [text](scripts/x.sh)            a Markdown link target
#
# It does NOT look for a bare `scripts/x.sh` in prose or as a standalone string
# argument. That is not an oversight: `standardize-repo` audits OTHER
# repositories and legitimately names their `scripts/` files, `implement-design`
# scaffolds a `scripts/check-contrast.mjs` INTO a consumer, `groom` describes a
# harmon-devkit CI check by name, and `review/assets/round-push.sh` passes
# `"scripts/gitleaks-scan.sh"` as the canonical repository path of a file in the
# repo under review. None of those is a vendored skill reaching for a runtime it
# does not ship, and a shape rule broad enough to catch them would be a rule
# nobody could keep green. Those bare literals need no allowlist entry either,
# and deliberately do not have one: the shape rule already passes them, so an
# entry for them would suppress nothing and the staleness check below would
# (correctly) call it out.
#
# ALLOWLIST — ruling 6 permits one where the shape rule alone is insufficient,
# and it is. Some skills invoke a `scripts/` path that belongs to a DIFFERENT
# repository: `standardize-repo` audits and rewrites a target repo's own tree,
# and `implement-design` scaffolds `scripts/check-contrast.mjs` INTO a consumer
# and then documents how to run it there. Those references are invocation-shaped
# and correct, and no shape rule can tell them apart from a skill reaching for a
# runtime it failed to ship — only intent can, so intent is what is recorded.
#
# The list lives in this file rather than a sibling data file so an exemption
# and its reason cannot drift apart. Two entry kinds, both `<TAB>`-separated:
#
#   dir   <prefix>       <reason>   every match under that path prefix
#   file  <path>  <needle>  <reason>   one fixed substring in one file
#
# An entry that matches nothing is itself a failure. An exemption nobody needs
# any more is an exemption nobody re-reads, and it silently widens the guard.
# That staleness check applies only to entries whose path lies UNDER one of the
# roots being scanned: the guard takes optional root arguments so its own unit
# test can drive it against synthetic trees, and there every real entry would
# otherwise read as stale and turn every synthetic case into a failure.
#
# SKILL_RUNTIME_PATHS_ALLOWLIST replaces the list wholesale. It exists so the
# unit test can exercise the staleness path itself, is never set by any `task`
# target or workflow, and announces itself loudly on stderr whenever it is
# used — so an overridden run can never be mistaken for a clean one.
#
# Run via `task validate:skill-runtime-paths`; unit-tested by
# `scripts/test-skill-runtime-paths.sh`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

# The scanned roots are everything `task sync:skills` vendors. The manifest
# ships `ai/agents/` alongside `ai/skills/`, and a shared agent that named a
# repository-root `scripts/` runtime would install into a consumer exactly as
# unrunnably as a skill would — so both are scanned by default. Explicit root
# arguments replace the default entirely, which is how the unit test drives the
# guard against synthetic trees.
if [ "$#" -gt 0 ]; then
    SCAN_ROOTS=("$@")
else
    SCAN_ROOTS=(ai/skills ai/agents)
fi

# kind<TAB>path<TAB>[needle<TAB>]reason
ALLOWLIST=$(
    cat <<'EOF'
dir	ai/skills/repo/standardize-repo/	every scripts/ path this skill names belongs to the TARGET repository it audits or updates, or to the harmon-init template it compares against — never to a runtime this skill has to ship
dir	ai/skills/frontend/implement-design/	this skill SCAFFOLDS check-contrast.mjs / measure-rendered-contrast.mjs into the consumer's own scripts/ and then documents running them there
file	ai/skills/universal/review/assets/test-round-push.sh	scripts/gitleaks-scan.sh	the broker's own test builds a synthetic closure in the repo-under-review layout, and sources the scanner from harmon-devkit's checkout to populate it
file	ai/skills/universal/review/assets/test-round-push.sh	scripts/summarize-gitleaks.mjs	same synthetic closure; the scanner's sibling module
EOF
)

if [ -n "${SKILL_RUNTIME_PATHS_ALLOWLIST-}" ]; then
    echo "check-skill-runtime-paths: WARNING — allowlist overridden by SKILL_RUNTIME_PATHS_ALLOWLIST (test-only); this run does NOT gate the repository" >&2
    ALLOWLIST="$SKILL_RUNTIME_PATHS_ALLOWLIST"
fi

fail=0
findings=""

note() {
    findings+="  ✗ $1:$2: $3"$'\n'
    fail=1
}

# allowlisted FILE LINE — 0 when an entry covers this hit. Prints the entry's
# identity on stdout so the caller can mark it used.
allowlisted() {
    local file=$1 line=$2 kind path needle
    while IFS=$'\t' read -r kind path needle _reason; do
        case "$kind" in
        dir)
            case "$file" in "$path"*)
                printf 'dir\t%s\n' "$path"
                return 0
                ;;
            esac
            ;;
        file)
            [ "$path" = "$file" ] || continue
            case "$line" in *"$needle"*)
                printf 'file\t%s\t%s\n' "$path" "$needle"
                return 0
                ;;
            esac
            ;;
        esac
    done <<<"$ALLOWLIST"
    return 1
}

# A root that is absent is a no-op rather than a failure: a consumer may carry
# one of the vendored trees and not the other, and the unit test points the
# guard at a path that does not exist on purpose.
PRESENT_ROOTS=()
for scan_root in "${SCAN_ROOTS[@]}"; do
    if [ -d "$scan_root" ]; then
        PRESENT_ROOTS+=("$scan_root")
    fi
done

if [ "${#PRESENT_ROOTS[@]}" -eq 0 ]; then
    echo "no ${SCAN_ROOTS[*]} director(y|ies) — nothing to check"
    exit 0
fi

echo "==> skill runtime paths: no repository-root scripts/ invocation under ${PRESENT_ROOTS[*]}"

# One ERE per shape. A `scripts/` path may be reached through any number of
# leading `./` or `../` segments — both still name the repository root's copy
# from inside a skill — so the pieces are named rather than inlined: NAME is
# the root-relative path itself, DOTS is one or more leading dot segments, and
# ROOT allows them optionally. Each pattern below then reads as the shape it
# is looking for.
NAME='scripts/[A-Za-z0-9._-]+\.(sh|mjs|py)'
DOTS='(\.{1,2}/)+'
ROOT="(\.{1,2}/)*${NAME}"
# VARROOT is anything that can stand in for the repository root ahead of a
# `/scripts/` path: `$var`, `${var}`, or a command substitution `$(...)`. The
# substitution body allows one level of nesting so the common
# `$(cd "$(dirname "$0")" && pwd -P)` spelling is recognised as a root too.
VARROOT='\$(\{?[A-Za-z_][A-Za-z0-9_]*\}?|\(([^()]|\([^()]*\))*\))'
PATTERNS=(
    # command position: ./scripts/x.sh or ../../scripts/x.sh at a shell
    # command boundary (line start, pipe, &&, ||, ;, `$(`, backtick). The
    # leading dots are REQUIRED here: a bare `scripts/x.sh` at the start of a
    # line is prose far more often than it is a command.
    "(^|[|;&(\`]|&&|\|\|)[[:space:]]*${DOTS}${NAME}"
    # an interpreter handed the path
    "\b(bash|sh|zsh|node|python3?|uv run)[[:space:]]+[\"']?${ROOT}"
    # a variable-rooted path: $var/scripts/x.sh, "${var}"/scripts/x.sh, a
    # command-substitution root "$(git rev-parse --show-toplevel)"/scripts/x.sh,
    # and any dot segments sitting between the root and scripts/, as in
    # "$repo/./scripts/x.sh" — every one of them names the repository root's
    # own copy just as plainly as the bare `$var/scripts/` spelling does.
    "${VARROOT}\"?/(${DOTS})?${NAME}"
    # an ES-module import or a require()
    "(from|import|require\()[[:space:]]*[\"']${ROOT}[\"']"
    # a Markdown link target
    "\]\(${ROOT}\)"
)

scan_tmp="$(mktemp)"
trap 'rm -f "$scan_tmp"' EXIT
: >"$scan_tmp"
for pattern in "${PATTERNS[@]}"; do
    grep -rInE --binary-files=without-match -- "$pattern" "${PRESENT_ROOTS[@]}" >>"$scan_tmp" || true
done

matched_entries=""
while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file=${hit%%:*}
    rest=${hit#*:}
    lineno=${rest%%:*}
    text=${rest#*:}
    if used="$(allowlisted "$file" "$text")"; then
        matched_entries+="$used"$'\n'
        continue
    fi
    note "$file" "$lineno" "invokes a repository-root scripts/ path — ${text#"${text%%[![:space:]]*}"}"
done < <(sort -u "$scan_tmp")

# A stale allowlist entry is a failure of its own — checked against what this
# run actually suppressed, not against the tree, so an entry whose file still
# contains the needle but no longer produces a FLAGGED line is stale too.
while IFS=$'\t' read -r kind path needle reason; do
    # dir entries carry only three fields; the third is the reason.
    [ "$kind" = "dir" ] && reason="$needle"
    case "$kind" in
    # A dir entry has no needle field, so `read` lands the reason in $needle;
    # blank it so the diagnostic below does not print the reason twice.
    dir)
        needle=""
        identity=$(printf 'dir\t%s' "$path")
        ;;
    file) identity=$(printf 'file\t%s\t%s' "$path" "$needle") ;;
    *) continue ;;
    esac
    # Out of scope for this run: this entry covers a path the scan never
    # visited, so its silence says nothing about whether it is still needed.
    in_scope=0
    for scan_root in "${PRESENT_ROOTS[@]}"; do
        case "$path" in "$scan_root"* | "${scan_root%/}/"*)
            in_scope=1
            break
            ;;
        esac
    done
    [ "$in_scope" -eq 1 ] || continue
    if ! grep -qxF -- "$identity" <<<"$matched_entries"; then
        findings+="  ✗ allowlist entry suppressed nothing and is stale: [$kind] $path ${needle:+($needle) }— $reason"$'\n'
        fail=1
    fi
done <<<"$ALLOWLIST"

if [ "$fail" -ne 0 ]; then
    printf '%s' "$findings" >&2
    cat >&2 <<'EOF'

  A skill or agent may not depend on a repository-root scripts/ path: `task
  sync:skills` vendors ai/skills/ and ai/agents/ and nothing from scripts/, so
  a consumer installs an asset that cannot run. Move the script into the owning
  skill's assets/, or into the shared dev-flow-support package if several
  skills use it, and reference it relative to the calling asset's own physical
  directory
  ("$(cd "$(dirname "$0")" && pwd -P)/../../<package>/assets/<name>").
EOF
    exit 1
fi

allowed_count="$(printf '%s' "$matched_entries" | sort -u | grep -c . || true)"
echo "  ✓ no repository-root scripts/ invocation under ${PRESENT_ROOTS[*]} (${allowed_count} allowlist entr(y/ies) in use)"
