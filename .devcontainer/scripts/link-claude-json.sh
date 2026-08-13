#!/usr/bin/env bash
# link-claude-json.sh — persist ~/.claude.json into the ~/.claude volume.
#
# Claude Code stores account/session state (OAuth account linkage, subscription
# detection, remote-control registration, per-project history) in
# ~/.claude.json — in the HOME dir, OUTSIDE the persisted ~/.claude/ volume.
# The container persists it by symlinking ~/.claude.json into that volume.
#
# The subtlety this script exists for: anything that launches `claude` BEFORE
# the symlink exists makes Claude Code write a fresh REAL file at
# ~/.claude.json, containing little more than a trust-dialog acceptance. A
# naive `mv ~/.claude.json ~/.claude/.claude.json` then overwrites the volume's
# real state with that stub — the user is logged out, plan detection reverts to
# usage credits, and remote-control session resume breaks. So the volume copy
# ALWAYS wins: a stray file is merged INTO it, never over it, and if the merge
# cannot be done safely the stray is set aside rather than either side lost.
#
# Idempotent, non-fatal, and safe to call from both post-create and post-start;
# post-create calls it EARLY, before anything that can spawn `claude`.
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
VOLUME_COPY="$CLAUDE_DIR/.claude.json"
STRAY="$HOME/.claude.json"

# No volume (or not mounted yet) — nothing to persist into. Never create the
# directory here: doing so would defeat the mount check and strand state in the
# container-local filesystem.
[ -d "$CLAUDE_DIR" ] || exit 0

# Set the stray aside instead of losing it. Timestamped and next to the volume
# copy, so it is inside the persisted volume and survives the next rebuild.
park_stray() {
    local bak
    bak="${VOLUME_COPY}.stray-$(date +%Y%m%d%H%M%S).bak"
    mv "$STRAY" "$bak"
    chmod 0600 "$bak" 2>/dev/null || true
    echo "==> Kept the persisted ~/.claude/.claude.json; stray file parked at ${bak}" >&2
}

if [ -L "$STRAY" ]; then
    # Already a symlink. `ln -sfn` below re-points it if it aims elsewhere.
    :
elif [ -e "$STRAY" ] && [ ! -f "$STRAY" ]; then
    # A directory or special file — not something this script can reason about.
    echo "WARNING: ${STRAY} exists and is not a regular file; leaving it alone" >&2
    exit 0
elif [ -f "$STRAY" ]; then
    if [ -s "$VOLUME_COPY" ]; then
        # Both sides hold data. Deep-merge with the VOLUME COPY WINNING on
        # every conflicting key (`.[0] * .[1]` puts the volume on the right),
        # so the stray only contributes keys the volume lacks.
        if command -v jq >/dev/null 2>&1; then
            tmp=$(mktemp)
            if jq -s '.[0] * .[1]' "$STRAY" "$VOLUME_COPY" >"$tmp" && [ -s "$tmp" ]; then
                install -m 0600 "$tmp" "$VOLUME_COPY"
                rm -f "$tmp" "$STRAY"
                echo "==> Merged stray ~/.claude.json into the persisted copy (volume state wins)"
            else
                rm -f "$tmp"
                park_stray
            fi
        else
            echo "WARNING: jq unavailable; cannot merge ~/.claude.json safely" >&2
            park_stray
        fi
    else
        # First migration, or an empty/absent volume copy: adopting the stray
        # is the legitimate path — there is no persisted state to protect.
        mv "$STRAY" "$VOLUME_COPY"
        chmod 0600 "$VOLUME_COPY"
        echo "==> Migrated ~/.claude.json into the persistent volume"
    fi
fi

ln -sfn "$VOLUME_COPY" "$STRAY"
