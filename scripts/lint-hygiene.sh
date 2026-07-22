#!/usr/bin/env bash
# lint-hygiene.sh — File hygiene checks (replaces pre-commit-hooks builtins).
#
# Checks: trailing whitespace, missing EOF newline, merge conflict markers,
# private key detection, mixed line endings, check-json, check-toml.
#
# Portable across macOS (bash 3.2, BSD grep) and Linux.
#
# Usage: ./scripts/lint-hygiene.sh [file ...]
#   If no files given, checks all tracked files.
#
# Per-file exemptions: an optional repo-root .lint-hygiene-ignore lists one
# path or glob per line ('#' comments and blank lines allowed); matching files
# are skipped entirely. Reserve it for app-managed configs the app rewrites on
# its own terms (e.g. karabiner.json dropping the final newline) — it is not a
# general lint escape hatch.
set -euo pipefail

errors=0
warn() {
    echo "FAIL: $*" >&2
    errors=$((errors + 1))
}

# Build file list (bash 3.2 compatible — no mapfile)
files=()
if [ $# -gt 0 ]; then
    files=("$@")
else
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(git ls-files -z --cached --others --exclude-standard 2>/dev/null)
fi

# Load per-file exemption patterns (bash 3.2 compatible)
ignore_patterns=()
if [ -f .lint-hygiene-ignore ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
        '' | '#'*) continue ;;
        esac
        ignore_patterns+=("$line")
    done <.lint-hygiene-ignore
fi

is_ignored() {
    # Empty-array guard: "${arr[@]}" on an empty array is an unbound-variable
    # error under `set -u` in bash 3.2.
    [ "${#ignore_patterns[@]}" -eq 0 ] && return 1
    local p pat
    p="$1"
    for pat in "${ignore_patterns[@]}"; do
        # shellcheck disable=SC2254  # unquoted on purpose: glob match
        case "$p" in
        $pat) return 0 ;;
        esac
    done
    return 1
}

for f in "${files[@]}"; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue # skip symlinks (AGENTS.md aliases etc.)
    if is_ignored "$f"; then continue; fi

    # Skip binary files and known binary extensions
    case "$f" in
    *.png | *.jpg | *.jpeg | *.gif | *.webp | *.ico | *.pdf | *.woff | *.woff2 | \
        *.ttf | *.eot | *.svg | *.zip | *.gz | *.tar | *.sqlite3 | *.db | *.pyc)
        continue
        ;;
    esac
    if file --mime-encoding "$f" 2>/dev/null | grep -q 'binary'; then
        continue
    fi

    # Windows batch/command files use CRLF by convention and live in the
    # boilerplate/snippet library as copy-paste references — not the repo's own
    # text files. Skip the line-ending/whitespace hygiene checks for them.
    case "$f" in
    *.cmd | *.bat) continue ;;
    esac

    # --- Trailing whitespace (exclude markdown/mdx where it's intentional) ---
    case "$f" in
    *.md | *.mdx) ;;
    *)
        if grep -En '[[:space:]]+$' "$f" >/dev/null 2>&1; then
            warn "$f: trailing whitespace detected"
        fi
        ;;
    esac

    # --- Missing final newline ---
    if [ -s "$f" ]; then
        if [ "$(tail -c 1 "$f" | wc -l)" -eq 0 ]; then
            warn "$f: no newline at end of file"
        fi
    fi

    # --- Merge conflict markers ---
    if grep -En '^(<<<<<<<|>>>>>>>|=======)( |$)' "$f" >/dev/null 2>&1; then
        warn "$f: merge conflict markers detected"
    fi

    # --- Private key detection ---
    # Skip self (any copy of this script) to avoid matching the pattern string.
    case "$f" in
    *lint-hygiene.sh) ;;
    *)
        if grep -l 'BEGIN.*PRIVATE KEY' "$f" >/dev/null 2>&1; then
            warn "$f: private key detected"
        fi
        ;;
    esac

    # --- Mixed line endings ---
    if file "$f" 2>/dev/null | grep -q 'CRLF'; then
        warn "$f: CRLF line endings detected (use LF)"
    fi

    # --- JSON syntax check ---
    case "$f" in
    *.json)
        # Skip JSONC files (devcontainer.json, tsconfig*.json at any depth —
        # TypeScript officially allows comments) and anything jinja-templated.
        # tsc -b validates the tsconfigs loudly, so hygiene needn't parse them.
        # Match only conventional devcontainer filenames (devcontainer.json or
        # .devcontainer.json, at the root or in a directory) — a suffix glob
        # like *devcontainer.json would exempt e.g. mydevcontainer.json too.
        case "$f" in
        devcontainer.json | */devcontainer.json | .devcontainer.json | */.devcontainer.json | \
            tsconfig*.json | */tsconfig*.json | template/*) ;;
        *)
            # Pass the path as argv, never interpolated into the Python source:
            # an apostrophe in a filename would otherwise be a SyntaxError
            # reported as invalid JSON, and a crafted name would execute.
            if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null; then
                warn "$f: invalid JSON"
            fi
            ;;
        esac
        ;;
    esac

    # --- TOML syntax check ---
    case "$f" in
    template/*.toml) ;;
    *.toml)
        if ! python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$f" 2>/dev/null; then
            warn "$f: invalid TOML"
        fi
        ;;
    esac
done

if [ "$errors" -gt 0 ]; then
    echo "lint-hygiene: $errors issue(s) found" >&2
    exit 1
fi
