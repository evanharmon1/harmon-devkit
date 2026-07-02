#!/usr/bin/env bash
set -euo pipefail

# Freshen already-cloned related repos in /workspaces/ on devcontainer START
# (post-start-common.sh), so siblings track their remotes without a manual
# fetch. Reads the same config as bootstrap-related-repos.sh:
# .devcontainer/related-repos.txt.
#
# STRICTLY NON-DESTRUCTIVE: runs `git fetch` only (updates remote-tracking refs
# and prunes deleted ones). It NEVER pulls, merges, checks out, or resets — so
# uncommitted changes, local commits, and the checked-out branch are left
# exactly as they are. Repos not yet cloned are skipped (bootstrap clones those
# at create time). Failures log a warning and continue; this never blocks start.

# Prevent VS Code's JS debug bootloader from breaking child Node processes.
unset NODE_OPTIONS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../related-repos.txt"
WORKSPACES_DIR="/workspaces"

[ -f "$CONFIG_FILE" ] || exit 0
[ -d "$WORKSPACES_DIR" ] || exit 0

fetched=0
skipped=0
failed=0

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    # Strip inline comments, then trim leading/trailing whitespace.
    line="${raw_line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue

    # Derive the target basename, mirroring bootstrap-related-repos.sh: drop an
    # optional plain @branch suffix (but keep ssh git@host:... intact), then
    # strip the path, any ssh "host:" prefix, and a trailing .git.
    target_spec="$line"
    if [[ "$line" == *"@"* ]]; then
        suffix="${line##*@}"
        if [[ "$suffix" != *.* && "$suffix" != *:* && "$suffix" != */* ]]; then
            target_spec="${line%@*}"
        fi
    fi
    basename_raw="${target_spec##*/}"
    basename_raw="${basename_raw##*:}"
    basename="${basename_raw%.git}"
    [ -z "$basename" ] && continue

    dir="${WORKSPACES_DIR}/${basename}"

    # Only fetch repos that are already cloned; bootstrap handles the rest.
    if [ ! -d "${dir}/.git" ]; then
        skipped=$((skipped + 1))
        continue
    fi

    if git -C "$dir" fetch --all --prune --quiet 2>/dev/null; then
        fetched=$((fetched + 1))
    else
        echo "==> WARNING: fetch failed for ${basename}; continuing." >&2
        failed=$((failed + 1))
    fi
done <"$CONFIG_FILE"

total=$((fetched + skipped + failed))
if [ "$total" -gt 0 ]; then
    echo "==> Related-repo fetch: ${fetched} fetched, ${skipped} not-yet-cloned, ${failed} failed"
fi

# Always exit 0 — never block container start.
exit 0
