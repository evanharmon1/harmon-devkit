#!/usr/bin/env bash
set -euo pipefail

export DEVCONTAINER_GIT_NAME="evanharmon1"
export DEVCONTAINER_GIT_EMAIL="evan@evanharmon.com"
# Which remedy post-create-common.sh prints when `gh` has no credential. This
# profile carries no GH_TOKEN and commits as the operator, so the fix is an
# operator `gh auth login`. This is the ONLY profile that may declare "login".
export DEVCONTAINER_GH_AUTH="login"

bash .devcontainer/scripts/post-create-common.sh

# Dev profile intentionally does NOT enable Claude bypassPermissions or call
# bot-autonomy.sh: a human driving this container gets the normal
# prompt-on-action default (the baked managed settings omit defaultMode).
# bot-autonomy.sh apply/verify and the flag-injecting Antigravity wrapper are
# installed by the bot post-create only. Do not "add them here for
# consistency".

# Dev profile ONLY: keep a `gh pr merge` prompt through a managed-settings
# drop-in. The project .claude/settings.json carries no `gh pr merge` ask (a
# host relies on the user's own settings), and the bot and agent profiles
# deliberately carry no merge guard at all — the "Protect Main" ruleset is the
# boundary there. A human driving this container still gets asked before a
# merge. This drop-in must NEVER be added to the bot or agent post-create.
CLAUDE_DEV_DROPIN_DIR=/etc/claude-code/managed-settings.d
CLAUDE_DEV_DROPIN_SRC=/usr/local/share/devcontainer-config/claude-settings-dev.json
if [ -w /etc/claude-code ]; then
    install -d -m 0755 "$CLAUDE_DEV_DROPIN_DIR"
    install -m 0644 "$CLAUDE_DEV_DROPIN_SRC" "$CLAUDE_DEV_DROPIN_DIR/dev-gh-pr-merge-ask.json"
else
    sudo install -d -m 0755 "$CLAUDE_DEV_DROPIN_DIR"
    sudo install -m 0644 "$CLAUDE_DEV_DROPIN_SRC" "$CLAUDE_DEV_DROPIN_DIR/dev-gh-pr-merge-ask.json"
fi

# Dev profile: apply the BALANCED Antigravity policy — auto-accept edits and an
# allowlist of common commands, but still prompt for anything else — WHEN
# HARMON_BOT_AUTONOMY_ANTIGRAVITY reads "enabled" (the rendered
# use_antigravity_cli marker; see devcontainer.json). This is deliberately NOT the
# bot's blanket always-proceed policy (antigravity-settings.json); a human
# driving this container keeps a veto over unlisted or destructive commands.
# ensure-antigravity-cli.sh always runs — its own internal marker check
# decides whether to download/reconcile or clean up — so a Copier-answer
# toggle from enabled to disabled is fully reconciled on the next rebuild
# instead of leaving a stale compatibility binary behind.
bash /usr/local/share/devcontainer-config/ensure-antigravity-cli.sh
if [ "${HARMON_BOT_AUTONOMY_ANTIGRAVITY:-}" = "enabled" ]; then
    bash /usr/local/share/devcontainer-config/apply-antigravity-settings.sh apply \
        /usr/local/share/devcontainer-config/antigravity-settings-dev.json "$PWD"
else
    bash /usr/local/share/devcontainer-config/apply-antigravity-settings.sh restore
fi

# Structural symmetry with bot's ordering (dev has no ordering REQUIREMENT
# here — a conductor-spawned `claude` under dev's default, prompt-enabled
# policy was never wrong).
bash .devcontainer/scripts/post-create-conductor.sh
