#!/usr/bin/env bash
set -euo pipefail

export DEVCONTAINER_GIT_NAME="evanharmon1-bot"
export DEVCONTAINER_GIT_EMAIL="evanharmon1-bot@users.noreply.github.com"
# Which remedy post-create-common.sh prints when `gh` has no credential. This
# profile authenticates from the bot's scoped PAT, so the fix is always to
# supply GH_TOKEN. Never set this to "login": a `gh auth login` here would put
# the operator's credential inside a bypassPermissions agent container.
export DEVCONTAINER_GH_AUTH="token"

# Ordering is load-bearing (AGENTS.md;
# https://github.com/evanharmon1/harmon-init/tree/main/openspec/changes/archive/2026-09-05-bot-autonomy-bootstrap):
#   (i)   post-create-common.sh — workspace permissions and, on Coder, the
#         persistent-volume symlink setup MUST run before anything below
#         writes into those directories, or a write lands as the wrong owner
#         or into container-local storage the Coder block would later
#         disregard.
#   (ii)  ensure-antigravity-cli.sh — reconciles ~/.local/bin/agy-real and the
#         plain agy symlink from the rendered HARMON_BOT_AUTONOMY_ANTIGRAVITY
#         marker, before the bot-autonomy antigravity module acts on top of
#         whatever this leaves at ~/.local/bin/agy.
#   (iii) bot-autonomy.sh apply — every installed harness's bot policy, so a
#         fresh container's very first agent invocation already reflects it.
#   (iv)  the conductor step — spawns a `claude` process on first
#         registration, so it must not run before (iii) has succeeded.
#   (v)   bot-autonomy.sh verify — at the end of post-create, so a divergence
#         between what apply wrote and the harness's actual effective state
#         (e.g. an already-present workspace-level override) fails container
#         creation instead of surfacing only at the next post-start.
bash .devcontainer/scripts/post-create-common.sh
bash /usr/local/share/devcontainer-config/ensure-antigravity-cli.sh
bash .devcontainer/scripts/bot-autonomy.sh apply
bash .devcontainer/scripts/post-create-conductor.sh
bash .devcontainer/scripts/bot-autonomy.sh verify

# Install repo-managed git hooks (source of truth: .devcontainer/hooks/).
# This replaces the default git-lfs hooks with versions that also handle
# auto-installing node_modules in new worktrees. Only these named hooks are
# copied or chmodded; Git's sample hooks are left untouched.
install_repo_managed_hooks() {
    local hook hook_name target

    [ -d .devcontainer/hooks ] || return 0
    echo "==> Installing git hooks from .devcontainer/hooks/..."
    for hook in .devcontainer/hooks/*; do
        [ -f "$hook" ] || continue
        hook_name="$(basename "$hook")"
        target=".git/hooks/$hook_name"
        cp "$hook" "$target"
        chmod +x "$target" || true
    done
}
install_repo_managed_hooks
