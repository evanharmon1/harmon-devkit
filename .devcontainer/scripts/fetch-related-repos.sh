#!/usr/bin/env bash
set -euo pipefail

# Freshen already-cloned related repos in the target directory on devcontainer START
# (post-start-common.sh), so siblings track their remotes without a manual
# fetch. Reads the same config as bootstrap-related-repos.sh:
# .devcontainer/related-repos.txt.
#
# STRICTLY NON-DESTRUCTIVE: runs `git fetch` only (updates remote-tracking refs
# and prunes deleted ones). It NEVER pulls, merges, checks out, or resets — so
# uncommitted changes, local commits, and the checked-out branch are left
# exactly as they are. Repos not yet cloned are skipped (bootstrap-related-repos.sh
# clones missing ones at create, start, and scope grant). Failures log a warning
# and continue; this never blocks start.

# Prevent VS Code's JS debug bootloader from breaking child Node processes.
unset NODE_OPTIONS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../related-repos.txt"
# setup:remote passes the checkout's parent; existing devcontainer callers keep
# /workspaces as their default.
WORKSPACES_DIR="${1:-/workspaces}"

[ -f "$CONFIG_FILE" ] || exit 0
[ -d "$WORKSPACES_DIR" ] || exit 0

fetched=0
skipped=0
failed=0
unrelated=0

# Identity is only the final owner/repository pair, independent of transport,
# host, port and leading path. Fold only that pair, not the whole URL.
repo_identity() {
    local path="${1%/}" owner repo
    case "$path" in
    *://*)
        path="${path#*://}"
        path="${path#*/}"
        ;;
    *:*) path="${path#*:}" ;;
    esac
    [ "$path" != "${path%/*}" ] || return 1
    owner="${path%/*}"
    owner="${owner##*/}"
    repo="${path##*/}"
    printf '%s/%s\n' "$owner" "$repo" | tr '[:upper:]' '[:lower:]' | sed 's/\.git$//'
}

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

    # Git can discover an enclosing repository from a plain subdirectory. Only
    # accept this directory's own worktree root (or its own bare repository).
    sibling_root=""
    if [ -d "$dir" ]; then
        if ! dir="$(cd "$dir" 2>/dev/null && pwd -P)"; then
            echo "==> WARNING: cannot enter ${basename}; continuing." >&2
            failed=$((failed + 1))
            continue
        fi
        if [ "$(git -C "$dir" rev-parse --is-bare-repository 2>/dev/null || true)" = true ]; then
            sibling_root="$(git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null || true)"
        else
            sibling_root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
        fi
    fi
    if [ -z "$sibling_root" ] || [ "$sibling_root" != "$dir" ]; then
        if [ -e "${dir}/.git" ] || [ -L "${dir}/.git" ]; then
            echo "==> WARNING: cannot open repository ${basename}; continuing." >&2
            failed=$((failed + 1))
        else
            skipped=$((skipped + 1))
        fi
        continue
    fi

    expected_identity="$(repo_identity "$target_spec" || true)"
    matching_remote=""
    while IFS= read -r remote; do
        [ -n "$remote" ] || continue
        # Resolve aliases without network access; only owner/repo identifies it.
        remote_url="$(git -C "$dir" ls-remote --get-url "$remote" 2>/dev/null || true)"
        if [ -n "$expected_identity" ] &&
            [ "$(repo_identity "$remote_url" || true)" = "$expected_identity" ]; then
            matching_remote="${matching_remote:-$remote}"
            if [ "$remote" = origin ]; then
                matching_remote="$remote"
                break
            fi
        fi
    done < <(git -C "$dir" remote 2>/dev/null || true)
    if [ -z "$matching_remote" ]; then
        echo "==> WARNING: skipping ${basename}: no remote matches the related-repos entry." >&2
        unrelated=$((unrelated + 1))
        continue
    fi

    # Empty refmap prevents configured fetch mappings from adding destinations.
    # Disable tag pruning/following and submodule recursion as well: this fetch
    # owns only the matching remote's branch refs, even in a mirror clone.
    if git -C "$dir" fetch --prune --no-prune-tags --no-tags --recurse-submodules=no \
        --refmap= --quiet "$matching_remote" "+refs/heads/*:refs/remotes/${matching_remote}/*" 2>/dev/null; then
        fetched=$((fetched + 1))
    else
        echo "==> WARNING: fetch failed for ${basename}; continuing." >&2
        failed=$((failed + 1))
    fi
done <"$CONFIG_FILE"

total=$((fetched + skipped + failed + unrelated))
if [ "$total" -gt 0 ]; then
    echo "==> Related-repo fetch: ${fetched} fetched, ${skipped} not-yet-cloned, ${failed} failed, ${unrelated} identity mismatches"
fi

# Always exit 0 — never block container start.
exit 0
