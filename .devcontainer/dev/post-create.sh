#!/usr/bin/env bash
set -euo pipefail

export DEVCONTAINER_GIT_NAME="evanharmon1"
export DEVCONTAINER_GIT_EMAIL="evan@evanharmon.com"
# Which remedy post-create-common.sh prints when `gh` has no credential. This
# profile carries no GH_TOKEN and commits as the operator, so the fix is an
# operator `gh auth login`. This is the ONLY profile that may declare "login".
export DEVCONTAINER_GH_AUTH="login"

bash .devcontainer/scripts/post-create-common.sh

# Dev profile intentionally does NOT enable Claude bypassPermissions: a human
# driving this container gets the normal prompt-on-action default (the baked
# managed settings omit defaultMode). The bot profile opts in via
# enable-claude-bypass.sh. Do not "add it here for consistency".
