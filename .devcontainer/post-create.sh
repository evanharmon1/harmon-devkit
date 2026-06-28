#!/usr/bin/env bash
set -euo pipefail

export DEVCONTAINER_GIT_NAME="evanharmon1-bot"
export DEVCONTAINER_GIT_EMAIL="evanharmon1-bot@users.noreply.github.com"

bash .devcontainer/scripts/post-create-common.sh

# Install repo-managed git hooks (source of truth: .devcontainer/hooks/).
# This replaces the default git-lfs hooks with versions that also handle
# auto-installing node_modules in new worktrees.
if [ -d .devcontainer/hooks ]; then
    echo "==> Installing git hooks from .devcontainer/hooks/..."
    cp .devcontainer/hooks/* .git/hooks/
    chmod +x .git/hooks/*
fi
