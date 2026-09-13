#!/usr/bin/env bash
# Prove that a lane's committed diff stays within its rendered file fence.
set -euo pipefail

usage() {
    echo "usage: fence-check.sh --brief <rendered.md> [--report <lane-report.md>]" >&2
    exit 2
}

brief=""
report=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --brief)
        [ "$#" -ge 2 ] || usage
        brief="$2"
        shift 2
        ;;
    --report)
        [ "$#" -ge 2 ] || usage
        report="$2"
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
[ -z "$report" ] || [ -f "$report" ] || {
    echo "fence-check: report is not a file: $report" >&2
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
comparison_base="$(git -C "$worktree_path" merge-base HEAD "origin/$default_branch" 2>/dev/null)" || {
    echo "fence-check: could not derive a merge base against origin/$default_branch" >&2
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
if [ -n "$report" ]; then
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
    case "${_fence_path_parts[$path_index]}" in
    $pattern_part)
        match_path_components "$((pattern_index + 1))" "$((path_index + 1))"
        ;;
    *) return 1 ;;
    esac
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
