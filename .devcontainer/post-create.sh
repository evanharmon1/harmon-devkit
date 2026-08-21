#!/usr/bin/env bash
set -euo pipefail

export DEVCONTAINER_GIT_NAME="evanharmon1-bot"
export DEVCONTAINER_GIT_EMAIL="evanharmon1-bot@users.noreply.github.com"
# Which remedy post-create-common.sh prints when `gh` has no credential. This
# profile authenticates from the bot's scoped PAT, so the fix is always to
# supply GH_TOKEN. Never set this to "login": a `gh auth login` here would put
# the operator's credential inside a bypassPermissions agent container.
export DEVCONTAINER_GH_AUTH="token"

bash .devcontainer/scripts/post-create-common.sh

# Bot profile: default Claude to bypassPermissions (no per-action prompts) —
# the container is the isolation boundary. The dev profile deliberately omits
# this so a human gets the normal prompt-on-action default.
bash .devcontainer/scripts/enable-claude-bypass.sh
bash .devcontainer/scripts/enable-codex-bypass.sh

# Opted-in bot profile: run Antigravity without permission prompts too. The
# helper preserves unrelated settings and records prior policy for rollback.
bash /usr/local/share/devcontainer-config/ensure-antigravity-cli.sh
bash /usr/local/share/devcontainer-config/apply-antigravity-settings.sh apply \
    /usr/local/share/devcontainer-config/antigravity-settings.json "$PWD"

# Install repo-managed git hooks (source of truth: .devcontainer/hooks/).
# This replaces the default git-lfs hooks with versions that also handle
# auto-installing node_modules in new worktrees.
if [ -d .devcontainer/hooks ]; then
    echo "==> Installing git hooks from .devcontainer/hooks/..."
    cp .devcontainer/hooks/* .git/hooks/
    chmod +x .git/hooks/*
fi
