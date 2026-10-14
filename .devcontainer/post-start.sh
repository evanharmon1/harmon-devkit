#!/usr/bin/env bash
set -euo pipefail

# Redirect all output to a log file to avoid SIGPIPE when VS Code
# disconnects the pipe before the script finishes.
exec &>/tmp/devcontainer-post-start.log

# Bot gh-identity tripwire (harmon-init#1236): warn when gh is unauthenticated
# or holds a non-bot credential — on every START, not just create, because an
# interactive `gh auth login` can happen at any point in a container's life.
# This copy lands in the log for the lifecycle record; the VISIBLE surface is
# the status board's creds section (scripts/status.sh), which the session-start
# hook renders — same two-surface split as check-image-staleness.sh.
# BEFORE the common startup work, so a failure there (this script is set -e)
# cannot skip the every-start check it promises; warn-only (`|| true`), so a
# diagnostic never aborts the lifecycle it diagnoses. It depends on nothing
# the common script sets up — gh ships in the image, and the helper is a bash
# script driving a Go binary, so the NODE_OPTIONS unset below does not apply
# to it.
bash .devcontainer/scripts/check-bot-gh-identity.sh || true

# Prevent VS Code's JS debug extension from breaking Node.js processes,
# duplicating post-start-common.sh's own line for the same reason (see that
# script). verify runs BEFORE post-start-common.sh below — ahead of its own
# unset — so a bot-autonomy module that shells out to a Node-based harness
# CLI (Claude Code, Codex, OpenCode) is not itself broken by an inherited VS
# Code debug NODE_OPTIONS value.
unset NODE_OPTIONS

# verify runs before the shared post-start-common.sh on purpose: that script's
# Agent-Deck conductor-start block launches an autonomous
# `agent-deck session start` unconditionally once a conductor is registered.
# Under `set -euo pipefail`, a verify failure aborts here — before the
# conductor block is ever reached — so a drifted policy blocks the conductor
# from starting rather than letting it run for the rest of its lifetime
# against a policy no later verify point can retroactively fix.
bash .devcontainer/scripts/bot-autonomy.sh verify

bash .devcontainer/scripts/post-start-common.sh
