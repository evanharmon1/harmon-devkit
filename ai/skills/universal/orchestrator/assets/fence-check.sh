#!/usr/bin/env bash
# Prove that a lane's committed diff stays within its rendered file fence.
set -euo pipefail

usage() {
    echo "usage: fence-check.sh --brief <rendered.md> --base <sha> [--report <lane-report.md>]" >&2
    exit 2
}

brief=""
base=""
report=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --brief)
        [ "$#" -ge 2 ] || usage
        brief="$2"
        shift 2
        ;;
    --base)
        [ "$#" -ge 2 ] || usage
        base="$2"
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

[ -n "$brief" ] && [ -n "$base" ] || usage
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
git -C "$repo" cat-file -e "${base}^{commit}" 2>/dev/null || {
    echo "fence-check: base is not a commit: $base" >&2
    exit 1
}

scratch="$(mktemp -d "${TMPDIR:-/tmp}/lane-fence-check.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
envelope="$scratch/envelope.json"
allowed="$scratch/allowed"
expanded="$scratch/expanded"
changed="$scratch/changed"
offenders="$scratch/offenders"

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
jq -r '.fence[] | if type == "string" then . else .path end' "$envelope" >"$allowed"

is_tooling_owned() {
    candidate="$1"
    case "$candidate" in
    CHANGELOG.md | */CHANGELOG.md | package-lock.json | */package-lock.json | npm-shrinkwrap.json | */npm-shrinkwrap.json | pnpm-lock.yaml | */pnpm-lock.yaml | yarn.lock | */yarn.lock | bun.lock | */bun.lock | bun.lockb | */bun.lockb | uv.lock | */uv.lock | poetry.lock | */poetry.lock | Pipfile.lock | */Pipfile.lock | Cargo.lock | */Cargo.lock | composer.lock | */composer.lock | Gemfile.lock | */Gemfile.lock)
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
    for owned in CHANGELOG.md package-lock.json pnpm-lock.yaml yarn.lock uv.lock Cargo.lock; do
        case "$owned" in
        $entry)
            echo "fence-check: tooling-owned path must not be listed in a lane fence: $entry" >&2
            exit 1
            ;;
        esac
    done
done <"$allowed"

: >"$expanded"
if [ -n "$report" ]; then
    sed -nE 's/^([0-9]{4}-[0-9]{2}-[0-9]{2}) fence expansion: ([^:]+):[0-9]+(-[0-9]+)?([[:space:]]+.*)?$/\2/p' "$report" |
        LC_ALL=C sort -u >"$expanded"
fi

git -C "$repo" diff --name-only "$base...HEAD" -- >"$changed"
: >"$offenders"
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
    if [ "$matched" = false ] && ! grep -Fxq -- "$path" "$expanded"; then
        printf '%s\n' "$path" >>"$offenders"
    fi
done <"$changed"

if [ -s "$offenders" ]; then
    echo "fence-check: changed paths outside the lane fence:" >&2
    sed 's/^/  - /' "$offenders" >&2
    exit 1
fi

echo "fence-check: all changed paths are within the lane fence"
