#!/usr/bin/env bash
# Find repository validators and helpers coupled to manifest/schema/registry files.
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
              | select(contains("_") or contains("-") or length >= 12)
              | select(test("^[A-Za-z][A-Za-z0-9_.:-]*$"))
            ' "$target"
            jq -r '
              .. | objects | .enum? | select(type == "array")[] | strings
              | select(length >= 4 and length <= 80)
              | select(test("^[A-Za-z][A-Za-z0-9_.:-]*$"))
            ' "$target"
            ;;
        *.yaml | *.yml | *.toml)
            sed -nE 's/^[[:space:]]*([A-Za-z][A-Za-z0-9_.-]{3,79})[[:space:]]*=?.*/\1/p' "$target"
            ;;
        esac
    } | while IFS= read -r term; do
        [ -n "$term" ] || continue
        printf '%s\n' "$term"
        printf '%s\n' "$term" | tr '_' '-'
    done | LC_ALL=C sort -u >"$terms"

    {
        [ ! -d "$repo/scripts" ] || grep -rFl -f "$terms" "$repo/scripts" || [ "$?" -eq 1 ]
        [ ! -d "$repo/ai/skills" ] || grep -rFl -f "$terms" "$repo/ai/skills" || [ "$?" -eq 1 ]
        [ ! -d "$repo/taskfiles" ] || grep -rFl -f "$terms" "$repo/taskfiles" || [ "$?" -eq 1 ]
        [ ! -f "$repo/Taskfile.yml" ] || grep -Fl -f "$terms" "$repo/Taskfile.yml" || [ "$?" -eq 1 ]
    } 2>/dev/null | while IFS= read -r candidate; do
        [ "$candidate" != "$target" ] || continue
        relative_candidate="${candidate#"$repo"/}"
        case "$relative_candidate" in
        scripts/* | taskfiles/* | Taskfile.yml | ai/skills/*/assets/*)
            printf '%s\n' "$relative_candidate" >>"$matches"
            ;;
        esac
    done
done

LC_ALL=C sort -u "$matches"
