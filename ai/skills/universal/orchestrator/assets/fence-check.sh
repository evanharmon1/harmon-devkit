#!/usr/bin/env bash
# Prove that a lane's committed diff stays within its rendered file fence.
# A fence entry matches literally per path component; a component is
# glob-interpreted only when it itself contains `*` or `?` (so a bracket
# expression like `[id]` is otherwise literal, and `**` still matches any
# number of path components).
set -euo pipefail

usage() {
    echo "usage: fence-check.sh --brief <rendered.md>" >&2
    exit 2
}

brief=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --brief)
        [ "$#" -ge 2 ] || usage
        brief="$2"
        shift 2
        ;;
    *) usage ;;
    esac
done

[ -n "$brief" ] || usage
[ -f "$brief" ] || {
    echo "fence-check: brief is not a file: $brief" >&2
    exit 1
}
invoking_repo="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "fence-check: not inside a Git worktree" >&2
    exit 1
}
validator="$invoking_repo/scripts/validate-result-schemas.mjs"
[ -x "$validator" ] || {
    echo "fence-check: brief validator is unavailable: $validator" >&2
    exit 1
}
node "$validator" brief "$brief" >/dev/null || {
    echo "fence-check: rendered brief failed schema validation" >&2
    exit 1
}
scratch="$(mktemp -d "${TMPDIR:-/tmp}/lane-fence-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
envelope="$scratch/envelope.json"
allowed="$scratch/allowed"
expanded="$scratch/expanded"
changed_raw="$scratch/changed.raw"
offenders="$scratch/offenders"
claims="$scratch/claims"

awk '
  /^<!-- BEGIN SCHEMA-BOUND ENVELOPE FACTS -->$/ { inside=1; next }
  /^<!-- END SCHEMA-BOUND ENVELOPE FACTS -->$/ { inside=0; next }
  inside && /^```json$/ { fenced=1; next }
  inside && fenced && /^```$/ { fenced=0; next }
  inside && fenced { print }
' "$brief" >"$envelope"
jq -e 'type == "object" and (.fence | type == "array")' "$envelope" >/dev/null || {
    echo "fence-check: could not extract the validated brief envelope" >&2
    exit 1
}
default_branch="$(jq -r '.default_branch' "$envelope")"
recorded_base="$(jq -r '.base_sha' "$envelope")"
worktree_path="$(jq -r '.worktree_path' "$envelope")"
expected_branch="$(jq -r '.branch' "$envelope")"
report="$(jq -r '.report_path' "$envelope")"
lane_root="$(git -C "$worktree_path" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "fence-check: envelope worktree_path is not a Git worktree: $worktree_path" >&2
    exit 1
}
resolved_worktree="$(cd "$worktree_path" && pwd -P)"
resolved_lane_root="$(cd "$lane_root" && pwd -P)"
[ "$resolved_worktree" = "$resolved_lane_root" ] || {
    echo "fence-check: envelope worktree_path is not the worktree root: $worktree_path" >&2
    exit 1
}
invoking_common="$(git -C "$invoking_repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
    echo "fence-check: could not resolve the invoking repository" >&2
    exit 1
}
lane_common="$(git -C "$worktree_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
    echo "fence-check: could not resolve the envelope worktree repository" >&2
    exit 1
}
[ "$invoking_common" = "$lane_common" ] || {
    echo "fence-check: envelope worktree_path belongs to a different repository: $worktree_path" >&2
    exit 1
}
current_branch="$(git -C "$worktree_path" branch --show-current)" || {
    echo "fence-check: could not resolve the current branch in $worktree_path" >&2
    exit 1
}
[ "$current_branch" = "$expected_branch" ] || {
    echo "fence-check: envelope branch $expected_branch does not match worktree branch ${current_branch:-<detached>}" >&2
    exit 1
}

# github.com only, matching this repo's own normalization set
# (docs/conventions.md § Git transport): a remote's fetch URL is compared
# against a resolved owner/repo by stripping the same protocol/host forms
# that set already needs to handle.
remote_name_with_owner() {
    local url="$1"
    case "$url" in
    https://github.com/*) url="${url#https://github.com/}" ;;
    http://github.com/*) url="${url#http://github.com/}" ;;
    git@github.com:*) url="${url#git@github.com:}" ;;
    ssh://git@github.com/*) url="${url#ssh://git@github.com/}" ;;
    ssh://git@ssh.github.com:443/*) url="${url#ssh://git@ssh.github.com:443/}" ;;
    ssh://git@ssh.github.com/*) url="${url#ssh://git@ssh.github.com/}" ;;
    *) return 1 ;;
    esac
    printf '%s\n' "${url%.git}"
}

# origin is the writable remote in the supported fork topology, not
# necessarily the PR target. The envelope's own issue.url already pins the
# target repository (it is where the lane's issue and PR live), so it is the
# only signal used: derive owner/repo from it and match a configured remote
# against that. Ambient `gh repo view` resolution was tried and dropped —
# it resolves by remote-name preference (upstream > github > origin > ...)
# or a persisted gh-resolved config, not actual git ancestry, so it is not
# reliably fork-aware and can regress a non-fork checkout that happens to
# carry a gh-favoured remote name for an unrelated repository (challenge
# round 1, confirmed). No match, or no parseable issue.url, falls back to
# origin so an ordinary non-fork checkout is unaffected.
resolve_comparison_remote() {
    local worktree="$1" envelope="$2"
    local issue_url target_nwo remote url candidate

    issue_url="$(jq -r '.issue.url // empty' "$envelope" 2>/dev/null || true)"
    target_nwo=""
    case "$issue_url" in
    https://github.com/*/*)
        target_nwo="$(printf '%s\n' "$issue_url" | sed -nE 's#^https://github\.com/([^/]+)/([^/]+)/.*#\1/\2#p')"
        ;;
    esac

    if [ -n "$target_nwo" ]; then
        while IFS= read -r remote; do
            url="$(git -C "$worktree" remote get-url "$remote" 2>/dev/null)" || continue
            candidate="$(remote_name_with_owner "$url")" || continue
            if [ "$candidate" = "$target_nwo" ]; then
                printf '%s\t%s\n' "$remote" "issue.url ($target_nwo)"
                return 0
            fi
        done < <(git -C "$worktree" remote)
    fi

    printf '%s\t%s\n' "origin" "fallback"
}

resolution="$(resolve_comparison_remote "$worktree_path" "$envelope")"
comparison_remote="${resolution%%$'\t'*}"
resolution_source="${resolution#*$'\t'}"
echo "fence-check: using remote '$comparison_remote' for the comparison base (source: $resolution_source)" >&2
comparison_base="$(git -C "$worktree_path" merge-base HEAD "$comparison_remote/$default_branch" 2>/dev/null)" || {
    echo "fence-check: could not derive a merge base against $comparison_remote/$default_branch" >&2
    exit 1
}
git -C "$worktree_path" merge-base --is-ancestor "$recorded_base" "$comparison_base" || {
    echo "fence-check: brief base $recorded_base is not an ancestor of derived base $comparison_base" >&2
    exit 1
}
jq -j '.fence[] | ((if type == "string" then . else .path end) + "\u0000")' \
    "$envelope" >"$allowed"

is_tooling_owned() {
    candidate="$1"
    case "$candidate" in
    CHANGELOG.md)
        return 0
        ;;
    esac
    return 1
}

while IFS= read -r -d '' entry; do
    [ -n "$entry" ] || {
        echo "fence-check: fence contains an empty path" >&2
        exit 1
    }
    [ "$entry" != CHANGELOG.md ] || {
        echo "fence-check: release-owned path must not be listed in a lane fence: $entry" >&2
        exit 1
    }
done <"$allowed"

: >"$expanded"
if [ -f "$report" ]; then
    awk '
      /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] fence expansion: [^:]+:[0-9]+(-[0-9]+)?[[:space:]]+/ {
        path=$0
        sub(/^[^ ]+ fence expansion: /, "", path)
        sub(/:[0-9]+(-[0-9]+)?[[:space:]].*$/, "", path)
        print path "\t" NR
      }
    ' "$report" >"$expanded"
fi

git -C "$worktree_path" diff -C --find-copies-harder --name-status -z \
    "$comparison_base...HEAD" -- >"$changed_raw" || {
    echo "fence-check: could not collect the lane diff" >&2
    exit 1
}
: >"$offenders"
: >"$claims"

_fence_pattern_parts=()
_fence_path_parts=()

# A fence entry component matches literally first (exact string compare), so
# a literal path segment containing glob metacharacters — most commonly a
# bracket expression such as a Next.js `[id]` route segment — is never
# glob-interpreted. Pattern matching is a fallback tried only when the
# component itself contains `*` or `?`; a component made only of `[`...`]`
# with no `*`/`?` anywhere in it never falls back, so it can only ever match
# itself.
component_matches() {
    local path_part="$1" pattern_part="$2"

    [ "$path_part" = "$pattern_part" ] && return 0

    case "$pattern_part" in
    *'*'* | *'?'*)
        case "$path_part" in
        $pattern_part) return 0 ;;
        *) return 1 ;;
        esac
        ;;
    *) return 1 ;;
    esac
}

match_path_components() {
    local pattern_index="$1"
    local path_index="$2"
    local pattern_part

    if [ "$pattern_index" -eq "${#_fence_pattern_parts[@]}" ]; then
        [ "$path_index" -eq "${#_fence_path_parts[@]}" ]
        return
    fi

    pattern_part="${_fence_pattern_parts[$pattern_index]}"
    if [ "$pattern_part" = "**" ]; then
        while [ "$path_index" -le "${#_fence_path_parts[@]}" ]; do
            if match_path_components "$((pattern_index + 1))" "$path_index"; then
                return 0
            fi
            path_index="$((path_index + 1))"
        done
        return 1
    fi

    [ "$path_index" -lt "${#_fence_path_parts[@]}" ] || return 1
    if component_matches "${_fence_path_parts[$path_index]}" "$pattern_part"; then
        match_path_components "$((pattern_index + 1))" "$((path_index + 1))"
    else
        return 1
    fi
}

path_matches_pattern() {
    local path_rest="$1"
    local pattern_rest="$2"
    _fence_path_parts=()
    _fence_pattern_parts=()

    while [[ "$path_rest" == */* ]]; do
        _fence_path_parts+=("${path_rest%%/*}")
        path_rest="${path_rest#*/}"
    done
    _fence_path_parts+=("$path_rest")

    while [[ "$pattern_rest" == */* ]]; do
        _fence_pattern_parts+=("${pattern_rest%%/*}")
        pattern_rest="${pattern_rest#*/}"
    done
    _fence_pattern_parts+=("$pattern_rest")

    match_path_components 0 0
}

check_path() {
    path="$1"
    if is_tooling_owned "$path"; then
        printf '%s\0' "$path" >>"$offenders"
        return 0
    fi
    matched=false
    while IFS= read -r -d '' pattern; do
        if path_matches_pattern "$path" "$pattern"; then
            matched=true
            break
        fi
    done <"$allowed"
    if [ "$matched" = false ]; then
        report_line="$(awk -F '\t' -v path="$path" '$1 == path { print $2; exit }' "$expanded")"
        if [ -n "$report_line" ]; then
            printf '%s\0%s\0' "$path" "$report_line" >>"$claims"
        else
            printf '%s\0' "$path" >>"$offenders"
        fi
    fi
}

while IFS= read -r -d '' status; do
    IFS= read -r -d '' first || {
        echo "fence-check: malformed name-status record" >&2
        exit 1
    }
    check_path "$first"
    case "$status" in
    R* | C*)
        IFS= read -r -d '' second || {
            echo "fence-check: malformed rename/copy record" >&2
            exit 1
        }
        check_path "$second"
        ;;
    esac
done <"$changed_raw"

if [ -s "$offenders" ]; then
    echo "fence-check: changed paths outside the lane fence:" >&2
    while IFS= read -r -d '' path; do
        printf '  - %q\n' "$path" >&2
    done <"$offenders"
    exit 1
fi

if [ -s "$claims" ]; then
    while IFS= read -r -d '' path && IFS= read -r -d '' report_line; do
        printf 'expansion-claimed: %q (report line %s)\n' "$path" "$report_line"
    done <"$claims"
fi
echo "fence-check: all changed paths are within the lane fence"
