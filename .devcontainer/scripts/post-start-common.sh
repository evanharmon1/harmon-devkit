#!/usr/bin/env bash
set -euo pipefail

# Prevent VS Code's JS debug extension from breaking Node.js processes.
# See post-create-common.sh for the full explanation.
unset NODE_OPTIONS

for dir in /home/vscode/.codex /home/vscode/.claude /home/vscode/.gemini \
    /home/vscode/.agent-deck /home/vscode/.shell-history /home/vscode/.local/share/zoxide; do
    sudo mkdir -p "$dir"
    sudo chown vscode:vscode "$dir"
    sudo chmod 700 "$dir"
done

# --- Persist ~/.claude.json across rebuilds ---
# Claude Code stores interactive session state in ~/.claude.json (in the home
# dir, outside the ~/.claude/ volume). Without this, interactive `claude`
# forces a full OAuth login after every rebuild even though credentials in
# ~/.claude/.credentials.json are valid.
if [ -d "$HOME/.claude" ] && [ ! -L "$HOME/.claude.json" ]; then
    if [ -f "$HOME/.claude.json" ]; then
        mv "$HOME/.claude.json" "$HOME/.claude/.claude.json"
    fi
    ln -sfn "$HOME/.claude/.claude.json" "$HOME/.claude.json"
fi

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

# --- Record Fable 5's usage-credit consent for the signed-in account ---
# Fable 5 needs a one-time "draws from usage credits" consent, stored per machine
# in ~/.claude.json under .fableOverageConsentV2, keyed by the signed-in account's
# organizationUuid (or "acct:<accountUuid>"). ~/.claude is a container-local
# volume, so the host's consent never reaches it. Without the record Claude Code
# arms a credits gate on the first API response that reports overage-in-use, and
# accepting the resulting prompt dead-ends whenever the account's cached
# extra-usage state is out_of_credits — leaving Fable unselectable in /model.
#
# This lives here rather than beside post-create-common.sh's onboarding seed
# because that block only fires on an empty volume, before any login has
# happened, so the account UUIDs this key is built from do not exist yet. Reading
# them from the live oauthAccount keeps the record correct for whichever account
# is signed in, and re-applies it if the file is ever reset. No-op until first
# login. Idempotent.
if command -v jq &>/dev/null && [ -f "$CLAUDE_JSON" ]; then
    CONSENT_KEY=$(jq -r '.oauthAccount // {}
        | if .organizationUuid then .organizationUuid
          elif .accountUuid then "acct:" + .accountUuid
          else empty end' "$CLAUDE_JSON" 2>/dev/null || true)
    if [ -n "$CONSENT_KEY" ] &&
        [ "$(jq -r --arg k "$CONSENT_KEY" '.fableOverageConsentV2[$k] // false' \
            "$CLAUDE_JSON" 2>/dev/null || true)" != "true" ]; then
        consent_tmp=$(mktemp)
        if jq --arg k "$CONSENT_KEY" \
            '.fableOverageConsentV2 = ((.fableOverageConsentV2 // {}) | .[$k] = true)' \
            "$CLAUDE_JSON" >"$consent_tmp"; then
            mv "$consent_tmp" "$CLAUDE_JSON"
            echo "==> Recorded Fable 5 usage-credit consent for the signed-in account"
        else
            rm -f "$consent_tmp"
            echo "==> Warning: failed to update $CLAUDE_JSON; leaving existing value unchanged" >&2
        fi
    fi
fi

# --- Freshen related repos in the background (non-destructive git fetch) ---
# Reads .devcontainer/related-repos.txt and git-fetches already-cloned siblings
# in /workspaces/ so they track their remotes. NEVER pulls/merges/checks out —
# local work is left untouched. nohup'd + backgrounded so it neither delays the
# session nor is killed with the postStart process group. No-op for an empty list.
nohup bash .devcontainer/scripts/fetch-related-repos.sh \
    >>"$HOME/.related-repos-fetch.log" 2>&1 &

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
REPO_NAME="$(basename "$PWD")"
if command -v agent-deck &>/dev/null &&
    [ -d "$HOME/.agent-deck/conductor/$REPO_NAME" ] &&
    agent-deck conductor status "$REPO_NAME" 2>/dev/null | grep -qi "stopped"; then
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

if [ "${DEVCONTAINER_TAILSCALE:-}" = "true" ]; then
    echo "==> Connecting to Tailscale..."
    if command -v tailscale &>/dev/null && sudo tailscale ip -4 >/dev/null 2>&1; then
        echo "Tailscale already connected."
    else
        # Run in foreground — post-start output is already redirected to a log file
        # so there is no SIGPIPE risk, and background processes get killed when
        # VS Code's postStartCommand process group exits.
        bash .devcontainer/scripts/tailscale-connect.sh
    fi
fi
