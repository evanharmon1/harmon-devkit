#!/usr/bin/env bash
set -euo pipefail

# Agent-Deck conductor setup — extracted out of post-create-common.sh so bot
# post-create can run it AFTER bot-autonomy.sh apply, not before: this step
# can spawn a `claude` process (agent-deck conductor setup's first
# registration), and that process must already see the bot's policy. Called
# from both profiles' post-create.sh as the last step, after the shared
# setup and (bot only) apply have both already run. See
# post-create-common.sh's ownership/Coder-persistence prefix, which still
# runs unconditionally first in both profiles — this script has no ordering
# requirement of its own relative to that.

# Inject Telegram bot token from env var into agent-deck config
if [ -n "${AGENT_DECK_TELEGRAM_KEY:-}" ]; then
    echo "==> Injecting Telegram bot token into agent-deck config..."
    sd 'token = ".*"' "token = \"${AGENT_DECK_TELEGRAM_KEY}\"" "$HOME/.agent-deck/config.toml"
fi

# Ensure bridge dependencies are installed for the runtime Python.
# The shared toolchain image installs toml/aiogram for the base system Python,
# but the devcontainer Python feature (3.14) replaces python3 on the PATH.
pip install --quiet toml aiogram 2>/dev/null || true

# Set up conductor if not already present (named after this repo).
#
# Existence is asked of agent-deck itself (`conductor status <name>` exits 0
# iff the conductor is registered), never of a hardcoded directory. The
# original guard probed a path agent-deck does not use (~/.agent-deck instead
# of the XDG data dir), so setup re-ran on EVERY create — and that re-run
# spawns a `claude` process, which before link-claude-json.sh above was the
# thing that clobbered the persisted ~/.claude.json. A path probe stays wrong
# in general: `agent-deck conductor migrate-dir --apply` relocates conductors
# to a custom [conductor].dir no fixed path would find. Asking by name is
# location-agnostic.
REPO_NAME="$(basename "$PWD")"
# Registration cannot be read off the exit code alone: `conductor status
# <name>` exits 1 for an unknown name on a CONFIGURED install, but on a fresh
# volume (conductor never set up at all) it prints "Conductor is not enabled."
# and exits 0 — so a negated exit-code guard would skip setup on exactly the
# fresh containers that need it. Treat "no output", a failed call, and the
# not-enabled message all as missing.
conductor_registered=false
if command -v agent-deck >/dev/null 2>&1; then
    conductor_status_out="$(agent-deck conductor status "$REPO_NAME" 2>/dev/null)" ||
        conductor_status_out=""
    case "$conductor_status_out" in
    "" | *[Nn]"ot enabled"*) conductor_registered=false ;;
    *) conductor_registered=true ;;
    esac
fi
if command -v agent-deck >/dev/null 2>&1 && [ "$conductor_registered" = false ]; then
    echo "==> Setting up agent-deck conductor '$REPO_NAME'..."
    if ! echo "n" | agent-deck conductor setup "$REPO_NAME" \
        --description "$REPO_NAME devcontainer conductor" \
        --no-heartbeat; then
        # Non-fatal, and deliberately NO automatic rollback: this script cannot
        # prove which on-disk state a failed setup owns. `status` can
        # transiently misreport an existing conductor as missing, and two
        # overlapping lifecycle runs can each see it absent — so any rm here
        # risks deleting a real conductor's user-maintained state, a strictly
        # worse outcome than the residual it would fix. The one case cleanup
        # would help — setup registered the conductor, then failed, leaving it
        # skipped-but-unusable — is handed to the operator instead:
        echo "WARN: agent-deck conductor setup failed (non-fatal). If the conductor" >&2
        echo "WARN: exists but is unusable, run: agent-deck conductor teardown ${REPO_NAME} --remove" >&2
        echo "WARN: and rebuild (or re-run this script) to recreate it." >&2
    fi
fi
