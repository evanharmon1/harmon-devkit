#!/usr/bin/env bash
set -euo pipefail

# Clone "related" repos listed in .devcontainer/related-repos.txt into
# /workspaces/, adjacent to the main repo. Idempotent and NON-DESTRUCTIVE: if a
# target dir already exists it is left completely untouched (no fetch, no pull,
# no checkout, no warning) — fetching is fetch-related-repos.sh's job at start.
#
# Runs on devcontainer create (post-create-common.sh), so a rebuilt or
# persistence-lost container re-clones any sibling that is missing.
#
# Config format (.devcontainer/related-repos.txt):
#   owner/repo                       # default branch, cloned via gh CLI
#   owner/repo@branch                # specific branch
#   https://github.com/owner/repo    # full URL (also supports .git suffix)
#   git@github.com:owner/repo.git    # ssh URL
#
# Lines starting with # are comments. Blank lines are ignored.
#
# Failures (missing config, bad URL, network errors) log a warning and
# continue — this script never causes post-create to fail.

# Prevent VS Code's JS debug bootloader from breaking child Node processes
# spawned by gh. See post-create-common.sh for the full explanation.
unset NODE_OPTIONS

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../related-repos.txt"
WORKSPACES_DIR="/workspaces"

# --- Pre-flight checks ---

if [ ! -f "$CONFIG_FILE" ]; then
    echo "==> No related-repos.txt found at ${CONFIG_FILE}; skipping."
    exit 0
fi

if [ ! -d "$WORKSPACES_DIR" ]; then
    echo "==> WARNING: ${WORKSPACES_DIR} does not exist; skipping related-repo bootstrap." >&2
    exit 0
fi

# /workspaces is owned by root in the devcontainer image — VS Code only fixes
# ownership on the workspace folder itself, not its parent. Make it writable
# by vscode so subsequent `git clone` calls can create sibling directories.
# Idempotent: chown is a no-op if ownership already matches.
if [ ! -w "$WORKSPACES_DIR" ]; then
    sudo chown vscode:vscode "$WORKSPACES_DIR"
fi

# --- Parse and clone ---

cloned=0
skipped=0
failed=0

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    # Strip inline comments (everything from the first # onward), then trim
    # leading and trailing whitespace.
    line="${raw_line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    # Skip blank lines (and lines that were comment-only).
    [ -z "$line" ] && continue

    # Split optional @branch suffix. Only split on the LAST @ so ssh URLs
    # like git@github.com:o/r.git are not mangled — those URLs always end
    # in .git, so a trailing @branch on the same line is unambiguous.
    branch=""
    target_spec="$line"
    if [[ "$line" == *"@"* ]]; then
        suffix="${line##*@}"
        # Treat the suffix as a branch only if it doesn't look like a host
        # (no dots, no colons, no slashes). This keeps `git@github.com:...`
        # intact while still splitting `owner/repo@feature/foo` correctly
        # only when the user wrote a plain branch name.
        if [[ "$suffix" != *.* && "$suffix" != *:* && "$suffix" != */* ]]; then
            branch="$suffix"
            target_spec="${line%@*}"
        fi
    fi

    # Derive the target basename.
    #   owner/repo                  -> repo
    #   https://host/owner/repo.git -> repo
    #   git@host:owner/repo.git     -> repo
    basename_raw="${target_spec##*/}"  # strip everything up to last /
    basename_raw="${basename_raw##*:}" # strip ssh "host:" prefix if any
    basename="${basename_raw%.git}"    # strip optional .git

    if [ -z "$basename" ]; then
        echo "==> WARNING: could not derive directory name for entry '${raw_line}'; skipping." >&2
        failed=$((failed + 1))
        continue
    fi

    target="${WORKSPACES_DIR}/${basename}"

    if [ -e "$target" ]; then
        echo "==> Skipping ${basename} (already present at ${target})"
        skipped=$((skipped + 1))
        continue
    fi

    # Decide whether to use gh (for owner/repo shorthand) or git (for URLs).
    use_gh=false
    if [[ "$target_spec" != *://* && "$target_spec" != *@*:* && "$target_spec" == */* ]]; then
        use_gh=true
    fi

    branch_label="${branch:-default branch}"
    echo "==> Cloning ${target_spec} (${branch_label}) -> ${target}"

    set +e
    if [ "$use_gh" = true ]; then
        if [ -n "$branch" ]; then
            gh repo clone "$target_spec" "$target" -- --branch "$branch" --quiet
        else
            gh repo clone "$target_spec" "$target" -- --quiet
        fi
    else
        if [ -n "$branch" ]; then
            git clone --quiet --branch "$branch" "$target_spec" "$target"
        else
            git clone --quiet "$target_spec" "$target"
        fi
    fi
    rc=$?
    set -e

    if [ "$rc" -eq 0 ]; then
        cloned=$((cloned + 1))
    else
        echo "==> WARNING: failed to clone ${target_spec} (exit ${rc}); continuing." >&2
        failed=$((failed + 1))
        # Clean up partial clone if gh/git left a stub directory behind.
        [ -d "$target" ] && rm -rf "$target"
    fi
done <"$CONFIG_FILE"

# --- Summary ---

total=$((cloned + skipped + failed))
if [ "$total" -eq 0 ]; then
    echo "==> No repos configured in ${CONFIG_FILE}; nothing to do."
else
    echo "==> Bootstrap complete: ${cloned} cloned, ${skipped} skipped, ${failed} failed"
fi

# Always exit 0 — failures are logged but never block post-create.
exit 0
