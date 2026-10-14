#!/usr/bin/env bash
set -euo pipefail

# Prevent VS Code's JS debug extension from breaking Node.js processes.
# See post-create-common.sh for the full explanation.
unset NODE_OPTIONS

for dir in /home/vscode/.codex /home/vscode/.claude /home/vscode/.gemini \
    /home/vscode/.copilot /home/vscode/.pi /home/vscode/.omp \
    /home/vscode/.agent-deck /home/vscode/.shell-history \
    /home/vscode/.config/herdr /home/vscode/.config/opencode \
    /home/vscode/.local/share/opencode /home/vscode/.local/share/zoxide; do
    sudo mkdir -p "$dir"
    sudo chown vscode:vscode "$dir"
    sudo chmod 700 "$dir"
done

# --- Persist ~/.claude.json across rebuilds ---
# Claude Code stores interactive session state in ~/.claude.json (in the home
# dir, outside the ~/.claude/ volume). Without this, interactive `claude`
# forces a full OAuth login after every rebuild even though credentials in
# ~/.claude/.credentials.json are valid. post-create runs the same helper
# EARLY, before anything that can spawn `claude`; see the script for why a
# stray real file is merged into the volume copy rather than moved over it.
bash .devcontainer/scripts/link-claude-json.sh

# --- Enable Claude Code Remote Control for every interactive session ---
# Sets remoteControlAtStartup=true so agent-deck-spawned `claude` sessions
# register with claude.ai/code automatically. Idempotent.
CLAUDE_JSON="$HOME/.claude/.claude.json"
if command -v jq &>/dev/null; then
    [ -f "$CLAUDE_JSON" ] || echo '{}' >"$CLAUDE_JSON"
    if [ "$(jq -r '.remoteControlAtStartup // false' "$CLAUDE_JSON" 2>/dev/null)" != "true" ]; then
        tmp=$(mktemp)
        if jq '.remoteControlAtStartup = true' "$CLAUDE_JSON" >"$tmp"; then
            mv "$tmp" "$CLAUDE_JSON"
            echo "==> Enabled Claude Code Remote Control for all sessions"
        else
            rm -f "$tmp"
            echo "==> Warning: failed to update $CLAUDE_JSON; leaving existing value unchanged" >&2
        fi
    fi
fi

# --- Bootstrap missing related repos in the background ---
# Clones any missing sibling repos configured in .devcontainer/related-repos.txt
# into /workspaces/. Backgrounded so container start is never blocked.
#
# SIGHUP is ignored in THIS shell before the jobs are forked and restored after.
# POSIX guarantees an ignored signal stays ignored across fork and exec, so each
# child starts with SIGHUP already ignored and is immune from its first
# instruction; there is no window between fork and a later `trap` or `nohup` in
# which a HUP could kill it. nohup would add nothing (the disposition is already
# inherited and the redirections keep the jobs off the tty). A process-group
# SIGTERM at container teardown still ends them, which is expected.
trap '' HUP
bash .devcontainer/scripts/bootstrap-related-repos.sh </dev/null >>"$HOME/.related-repos-bootstrap.log" 2>&1 &

# --- Freshen related repos in the background (non-destructive git fetch) ---
# Reads .devcontainer/related-repos.txt and git-fetches already-cloned siblings
# in /workspaces/ so they track their remotes. NEVER pulls/merges/checks out —
# local work is left untouched. Backgrounded, with SIGHUP ignored in the parent
# before the fork (see above), so it neither delays the session nor is killed
# when the shell exits. No-op for an empty list.
bash .devcontainer/scripts/fetch-related-repos.sh </dev/null >>"$HOME/.related-repos-fetch.log" 2>&1 &
trap - HUP

echo "==> Starting tmux session..."
if command -v tmux &>/dev/null; then
    tmux has-session -t default 2>/dev/null || tmux new-session -d -s default
fi

echo "==> Zellij available (run 'zj' to create or attach to the main session)..."

# --- Agent-Deck Telegram token injection ---
# Re-inject on every start so token changes take effect without a full rebuild.
if [ -n "${AGENT_DECK_TELEGRAM_KEY:-}" ] && [ -f "$HOME/.agent-deck/config.toml" ]; then
    sd 'token = ".*"' "token = \"${AGENT_DECK_TELEGRAM_KEY}\"" "$HOME/.agent-deck/config.toml"
    echo "==> Injected Telegram bot token into agent-deck config"
fi

# --- Agent-Deck conductor ---
# Start the conductor session if it exists but is stopped.
# Check for "stopped" specifically — the previous "! grep running" approach
# was fooled by the bridge's status also appearing in conductor status output.
#
# No directory probe: `conductor status <name>` is already the authoritative
# existence check (exit 0 iff registered) and stays correct when conductors
# are relocated with `agent-deck conductor migrate-dir --apply` — a fixed
# path would go stale there. Matches post-create-common.sh's setup guard.
REPO_NAME="$(basename "$PWD")"
if command -v agent-deck &>/dev/null &&
    conductor_status="$(agent-deck conductor status "$REPO_NAME" 2>/dev/null)" &&
    grep -i "stopped" <<<"$conductor_status" >/dev/null; then
    agent-deck session start "conductor-$REPO_NAME" 2>/dev/null &
    echo "==> Conductor $REPO_NAME started"
fi

# --- Agent-Deck Telegram bridge ---
# Start the bridge daemon AFTER the conductor so it has something to route to.
BRIDGE_PY="$HOME/.agent-deck/conductor/bridge.py"
if [ -f "$BRIDGE_PY" ] && ! pgrep -f "bridge.py" >/dev/null 2>&1; then
    nohup python3 "$BRIDGE_PY" >>"$HOME/.agent-deck/conductor/bridge.log" 2>&1 &
    echo "==> Agent-Deck Telegram bridge started (PID $!)"
fi

# --- Image staleness ---
# Warn (only) when this container's image-baked config has drifted from the
# checkout — the tell that the container predates the repo state and wants a
# rebuild. Placed before the Tailscale block rather than at the very end so a
# connect failure cannot skip it, and `|| true` because a diagnostic must never
# be the thing that aborts the lifecycle it diagnoses (the helper exits 0 on its
# own; this is the belt to that suspenders).
bash .devcontainer/scripts/check-image-staleness.sh || true

if [ "${DEVCONTAINER_TAILSCALE:-}" = "true" ]; then
    echo "==> Connecting to Tailscale..."
    # Delegate unconditionally. This used to carry its own "already connected"
    # probe (`tailscale ip -4`) and skip the script when it passed — but that is
    # the WEAKER check and it won: `tailscale ip` answers from local state that
    # outlives the node it describes, so a reaped ephemeral node still reports an
    # address and none of tailscale-connect.sh's failure handling ever ran.
    # tailscale-connect.sh owns that decision now and has the same fast path,
    # checked properly against BackendState.
    #
    # Run in foreground — post-start output is already redirected to a log file
    # so there is no SIGPIPE risk. (The detached `… </dev/null … &` jobs
    # above are different: they survive the postStartCommand process group's
    # exit because they inherited an ignored SIGHUP from this shell before the
    # fork; a process-group SIGTERM at container teardown still ends them, which
    # is expected.)
    bash .devcontainer/scripts/tailscale-connect.sh
fi
