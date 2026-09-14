#!/usr/bin/env bash
# Find consumers naming a file or its hard-coded keys; YAML/TOML scalar values are out of scope.
set -euo pipefail

usage() {
    echo "usage: validator-dependency-scan.sh <path>..." >&2
    exit 2
}

[ "$#" -gt 0 ] || usage

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "validator-dependency-scan: not inside a Git worktree" >&2
    exit 1
}

scratch="$(mktemp -d "${TMPDIR:-/tmp}/validator-dependency-scan.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

terms="$scratch/terms"
matches="$scratch/matches"
: >"$matches"

scan_root() {
    root="$1"
    recursive="$2"
    [ -e "$root" ] || return 0
    if [ "$recursive" = true ]; then
        if grep -rFwl -f "$terms" "$root"; then
            return 0
        else
            status="$?"
        fi
    else
        if grep -Fwl -f "$terms" "$root"; then
            return 0
        else
            status="$?"
        fi
    fi
    case "$status" in
    0 | 1) return 0 ;;
    *)
        echo "validator-dependency-scan: grep failed for $root (exit $status)" >&2
        return "$status"
        ;;
    esac
}

for supplied in "$@"; do
    case "$supplied" in
    /*) target="$supplied" ;;
    *) target="$repo/$supplied" ;;
    esac
    [ -f "$target" ] || {
        echo "validator-dependency-scan: target is not a file: $supplied" >&2
        exit 1
    }

    relative="${target#"$repo"/}"
    {
        printf '%s\n' "$relative" "$(basename "$relative")"
        case "$target" in
        *.json)
            jq -r '
              .. | objects | keys[]
              | select(length <= 80)
              | select(test("^[A-Za-z][A-Za-z0-9_.:-]*$"))
            ' "$target"
            jq -r '
              .. | objects | .enum? | select(type == "array")[] | strings
              | select(length <= 80)
              | select(test("^[A-Za-z][A-Za-z0-9_.:-]*$"))
            ' "$target"
            ;;
        *.yaml | *.yml)
            # Bare keys accept the full [A-Za-z0-9_-] leading charset (dots
            # allowed inside); a "quoted" or 'quoted' key emits its unquoted
            # term. Each alternative mutates the matched line on success, so
            # a line matching one never also matches another.
            sed -nE \
                -e 's/^[[:space:]]*(-[[:space:]]+)?"([A-Za-z0-9_-][A-Za-z0-9_.-]{0,79})"[[:space:]]*:.*/\2/p' \
                -e 's/^[[:space:]]*(-[[:space:]]+)?'"'"'([A-Za-z0-9_-][A-Za-z0-9_.-]{0,79})'"'"'[[:space:]]*:.*/\2/p' \
                -e 's/^[[:space:]]*(-[[:space:]]+)?([A-Za-z0-9_-][A-Za-z0-9_.-]{0,79})[[:space:]]*:.*/\2/p' \
                "$target"
            ;;
        *.toml)
            sed -nE \
                -e 's/^[[:space:]]*"([A-Za-z0-9_-][A-Za-z0-9_.-]{0,79})"[[:space:]]*=.*/\1/p' \
                -e 's/^[[:space:]]*'"'"'([A-Za-z0-9_-][A-Za-z0-9_.-]{0,79})'"'"'[[:space:]]*=.*/\1/p' \
                -e 's/^[[:space:]]*([A-Za-z0-9_-][A-Za-z0-9_.-]{0,79})[[:space:]]*=.*/\1/p' \
                "$target"
            ;;
        esac
    } | while IFS= read -r term; do
        [ -n "$term" ] || continue
        printf '%s\n' "$term"
        printf '%s\n' "$term" | tr '_' '-'
    done | LC_ALL=C sort -u >"$terms"

    {
        scan_root "$repo/scripts" true
        scan_root "$repo/ai/skills" true
        scan_root "$repo/.agents/skills" true
        scan_root "$repo/.claude/skills" true
        scan_root "$repo/taskfiles" true
        scan_root "$repo/Taskfile.yml" false
    } | while IFS= read -r candidate; do
        [ "$candidate" != "$target" ] || continue
        relative_candidate="${candidate#"$repo"/}"
        case "$relative_candidate" in
        scripts/* | taskfiles/* | Taskfile.yml | ai/skills/*/assets/* | .agents/skills/*/assets/* | .claude/skills/*/assets/*)
            printf '%s\n' "$relative_candidate" >>"$matches"
            ;;
        esac
    done
done

LC_ALL=C sort -u "$matches"
