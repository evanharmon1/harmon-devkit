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

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "fence-check: not inside a Git worktree" >&2
    exit 1
}
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
validator="$script_dir/../../../../../scripts/validate-result-schemas.mjs"
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
changed="$scratch/changed"
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
comparison_base="$(git -C "$repo" merge-base HEAD "origin/$default_branch" 2>/dev/null)" || {
    echo "fence-check: could not derive a merge base against origin/$default_branch" >&2
    exit 1
}
git -C "$repo" merge-base --is-ancestor "$recorded_base" "$comparison_base" || {
    echo "fence-check: brief base $recorded_base is not an ancestor of derived base $comparison_base" >&2
    exit 1
}
jq -r '.fence[] | if type == "string" then . else .path end' "$envelope" >"$allowed"

is_tooling_owned() {
    candidate="$1"
    case "$candidate" in
    CHANGELOG.md)
        return 0
        ;;
    esac
    return 1
}

while IFS= read -r entry; do
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

git -C "$repo" diff --name-status -z "$comparison_base...HEAD" -- >"$changed_raw" || {
    echo "fence-check: could not collect the lane diff" >&2
    exit 1
}
: >"$changed"
while IFS= read -r -d '' status; do
    IFS= read -r -d '' first || {
        echo "fence-check: malformed name-status record" >&2
        exit 1
    }
    printf '%s\n' "$first" >>"$changed"
    case "$status" in
    R* | C*)
        IFS= read -r -d '' second || {
            echo "fence-check: malformed rename/copy record" >&2
            exit 1
        }
        printf '%s\n' "$second" >>"$changed"
        ;;
    esac
done <"$changed_raw"

: >"$offenders"
: >"$claims"
while IFS= read -r path; do
    [ -n "$path" ] || continue
    if is_tooling_owned "$path"; then
        printf '%s\n' "$path" >>"$offenders"
        continue
    fi
    matched=false
    while IFS= read -r pattern; do
        case "$path" in
        $pattern)
            matched=true
            break
            ;;
        esac
    done <"$allowed"
    if [ "$matched" = false ]; then
        report_line="$(awk -F '\t' -v path="$path" '$1 == path { print $2; exit }' "$expanded")"
        if [ -n "$report_line" ]; then
            printf 'expansion-claimed: %s (report line %s)\n' "$path" "$report_line" >>"$claims"
        else
            printf '%s\n' "$path" >>"$offenders"
        fi
    fi
done <"$changed"

if [ -s "$offenders" ]; then
    echo "fence-check: changed paths outside the lane fence:" >&2
    sed 's/^/  - /' "$offenders" >&2
    exit 1
fi

[ ! -s "$claims" ] || cat "$claims"
echo "fence-check: all changed paths are within the lane fence"
