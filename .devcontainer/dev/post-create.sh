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

# Dev profile: apply the BALANCED Antigravity policy — auto-accept edits and an
# allowlist of common commands, but still prompt for anything else. This is
# deliberately NOT the bot's blanket always-proceed policy
# (antigravity-settings.json); a human driving this container keeps a veto over
# unlisted or destructive commands. The helper records prior policy for rollback.
bash /usr/local/share/devcontainer-config/ensure-antigravity-cli.sh
bash /usr/local/share/devcontainer-config/apply-antigravity-settings.sh apply \
    /usr/local/share/devcontainer-config/antigravity-settings-dev.json "$PWD"
