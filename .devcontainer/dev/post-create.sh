#!/usr/bin/env bash
set -euo pipefail

export DEVCONTAINER_GIT_NAME="evanharmon1"
export DEVCONTAINER_GIT_EMAIL="evan@evanharmon.com"

bash .devcontainer/scripts/post-create-common.sh

# Dev profile intentionally does NOT enable Claude bypassPermissions: a human
# driving this container gets the normal prompt-on-action default (the baked
# managed settings omit defaultMode). The bot profile opts in via
# enable-claude-bypass.sh. Do not "add it here for consistency".
