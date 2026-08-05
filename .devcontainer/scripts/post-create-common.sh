#!/usr/bin/env bash
set -euo pipefail

# Prevent VS Code's JS debug extension from breaking Node.js processes.
# The extension injects NODE_OPTIONS=--require .../bootloader.js, but the
# bootloader may not exist during lifecycle commands (extensions not installed
# yet or workspace storage path is stale). This is a non-interactive context,
# so the shell profile's `unset NODE_OPTIONS` doesn't apply.
unset NODE_OPTIONS
# Prevent a host-exported ANTHROPIC_API_KEY from silently winning over
# CLAUDE_CODE_OAUTH_TOKEN and billing the API account instead.
unset ANTHROPIC_API_KEY

if [ -z "${DEVCONTAINER_GIT_NAME:-}" ] || [ -z "${DEVCONTAINER_GIT_EMAIL:-}" ]; then
    echo "DEVCONTAINER_GIT_NAME and DEVCONTAINER_GIT_EMAIL must be set." >&2
    exit 1
fi

# Shell aliases/functions are version-controlled in .devcontainer/config/ and
# baked into the image at /usr/local/share/devcontainer-config/shell-aliases.sh
# by the Dockerfile. We only wire up the source line in the rc files below.
PROFILE_SOURCE_LINE='source /usr/local/share/devcontainer-config/shell-aliases.sh'

# All runtime git-config writes target the image's XDG environment config
# explicitly. `git config --global` picks its file at runtime — ~/.gitconfig
# when that file exists, the XDG file otherwise — and whether ~/.gitconfig
# exists here depends on whether VS Code's copyGitConfig has copied the host's
# in yet, so --global writes land in a different file per attach mode and per
# lifecycle ordering. Pinning the file makes the environment layer
# deterministic and keeps ~/.gitconfig personal-only (issue #542).
ENV_GITCONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/git/config"
mkdir -p "$(dirname "$ENV_GITCONFIG")"

# Git identity for commits. Written to the environment layer, so in a bot or
# headless container DEVCONTAINER_GIT_* is the identity. When a human attaches
# via VS Code and copyGitConfig brings their personal ~/.gitconfig in, its
# user.* wins over this layer — that copy is personal-only config, and the
# attaching human's own identity taking precedence is the intended outcome.
git config --file "$ENV_GITCONFIG" user.name "${DEVCONTAINER_GIT_NAME}"
git config --file "$ENV_GITCONFIG" user.email "${DEVCONTAINER_GIT_EMAIL}"

# Loud, actionable guidance for an unauthenticated `gh`. The dev profile carries
# no GH_TOKEN and does not persist its login, so this is that profile's ordinary
# first-run state in EVERY attach mode — not just a bot misconfiguration on the
# headless path. Hence a shared helper: the VS Code branch below needs the same
# message and would otherwise say nothing at all.
#
# The REMEDY differs by profile, and printing the wrong one is a security bug
# rather than a typo: telling a bot container to `gh auth login` would put an
# operator credential — `workflow` scope and all — inside a bypassPermissions
# agent container, which is the exact escalation the bot PAT's denials exist to
# stop (docs/architecture/security.md). Each profile's own post-create.sh
# declares which remedy applies via DEVCONTAINER_GH_AUTH; anything else falls
# back to the token message, so the operator instructions can only ever appear
# where a wrapper explicitly asked for them.
#
# $1 is an extra command for the login path (the git bridge), omitted where
# VS Code already manages git's credential.
gh_auth_help() {
    echo "=============================================================="
    echo "  GitHub CLI is NOT authenticated — gh pr / gh api and the"
    echo "  related-repo clones will fail until this is fixed."
    echo ""
    if [ "${DEVCONTAINER_GH_AUTH:-token}" = "login" ]; then
        echo "  This profile authenticates as you. Log in:"
        echo ""
        echo "    gh auth login --hostname github.com --git-protocol https \\"
        echo "      --web --scopes \"workflow,project\""
        if [ -n "${1:-}" ]; then
            echo "    $1"
        fi
        echo ""
        echo "  Then re-run: bash .devcontainer/scripts/bootstrap-related-repos.sh"
        echo "  See docs/guides/devcontainers.md."
    else
        echo "  This profile authenticates from GH_TOKEN. Do NOT run"
        echo "  'gh auth login' here — that would put a human credential in an"
        echo "  agent container. Populate GH_TOKEN in the env-file this profile"
        echo "  loads (1Password Environment locally, workspace parameters on"
        echo "  Coder) and rebuild. See docs/guides/bot-account.md."
    fi
    echo "=============================================================="
}

# Let VS Code's devcontainer integration manage the in-container git credential
# helper. Installing gh's URL-specific helpers here can confuse the remote
# containers bootstrap when it replaces credential.helper on attach.
if [ -n "${REMOTE_CONTAINERS_IPC:-}" ] || [ "${REMOTE_CONTAINERS:-}" = "true" ]; then
    # Unset from both global-scope files: a prior `gh auth setup-git` may have
    # written the helpers to either one (gh uses --global, whose target file
    # varies — see ENV_GITCONFIG above).
    for cfg in "$ENV_GITCONFIG" "$HOME/.gitconfig"; do
        [ -f "$cfg" ] || continue
        git config --file "$cfg" --unset-all credential.https://github.com.helper || true
        git config --file "$cfg" --unset-all credential.https://gist.github.com.helper || true
    done
    echo "VS Code devcontainer detected; skipping gh auth setup-git."
    # VS Code's forwarded host credential covers *git* on this path, but not
    # `gh` — it reads its own config, and the dev profile supplies no GH_TOKEN.
    # Pass NO git bridge: unsetting those helpers two lines up is deliberate, so
    # telling the user to run `gh auth setup-git` would undo it.
    gh auth status >/dev/null 2>&1 || gh_auth_help
elif gh auth status >/dev/null 2>&1; then
    gh auth setup-git
else
    # Nothing manages git's credential here, so the bridge is part of the fix.
    gh_auth_help "gh auth setup-git"
fi

# The GitHub SSH→HTTPS insteadOf rewrites are baked into the image's
# environment gitconfig (.devcontainer/config/gitconfig) — static config
# belongs in the image layer, not in runtime writes.

# Effective read, not --global: the scoped read surface skips the XDG file
# once ~/.gitconfig exists, so it would print empty exactly when identity
# lives in the environment layer.
echo "Git user: $(git config user.name)"
echo "GitHub auth status:"
gh auth status || true

# push.autoSetupRemote is baked in the environment gitconfig alongside the
# other static settings.

echo "==> Fixing ownership of persistent volume dirs..."
for dir in /home/vscode/.codex /home/vscode/.claude /home/vscode/.gemini \
    /home/vscode/.agent-deck /home/vscode/.shell-history \
    /home/vscode/.local /home/vscode/.local/share /home/vscode/.local/share/zoxide; do
    sudo mkdir -p "$dir"
    sudo chown vscode:vscode "$dir"
    chmod 700 "$dir"
done

# --- Claude Code onboarding seed ---
# Pre-seed ~/.claude/.claude.json so fresh containers skip the onboarding
# wizard (upstream issue: https://github.com/anthropics/claude-code/issues/8938).
# post-start-common.sh creates ~/.claude.json → ~/.claude/.claude.json so
# Claude Code finds this file on first launch. Guard: only seed on an empty
# volume — existing session data (token, settings) must never be clobbered.
CLAUDE_SESSION_FILE="$HOME/.claude/.claude.json"
if [ -d "$HOME/.claude" ] && [ ! -f "$CLAUDE_SESSION_FILE" ]; then
    echo '{"hasCompletedOnboarding":true}' >"$CLAUDE_SESSION_FILE"
    chmod 0600 "$CLAUDE_SESSION_FILE"
    echo "==> Seeded ~/.claude/.claude.json with hasCompletedOnboarding=true"
fi

# --- Coder persistent volume symlinks ---
# Coder's envbuilder does not support devcontainer volume mounts, so on Coder
# the template provides a single persistent volume at ~/.persistent/ and we
# symlink the individual directories there.
if [ "${CODER:-}" = "true" ] && [ -d "/home/vscode/.persistent" ]; then
    echo "==> Coder detected — setting up persistent volume symlinks..."
    for dir in .claude .codex .gemini .agent-deck .shell-history; do
        mkdir -p "/home/vscode/.persistent/$dir"
        if [ -d "$HOME/$dir" ] && [ ! -L "$HOME/$dir" ]; then
            cp -a "$HOME/$dir/." "/home/vscode/.persistent/$dir/" 2>/dev/null || true
            rm -rf "${HOME:?}/$dir"
        fi
        ln -sfn "/home/vscode/.persistent/$dir" "$HOME/$dir"
    done
    mkdir -p "/home/vscode/.persistent/zoxide" "$HOME/.local/share"
    if [ -d "$HOME/.local/share/zoxide" ] && [ ! -L "$HOME/.local/share/zoxide" ]; then
        cp -a "$HOME/.local/share/zoxide/." "/home/vscode/.persistent/zoxide/" 2>/dev/null || true
        rm -rf "${HOME:?}/.local/share/zoxide"
    fi
    ln -sfn "/home/vscode/.persistent/zoxide" "$HOME/.local/share/zoxide"
fi

# --- Agent-Deck config seeding ---
# When a fresh volume mount shadows ~/.agent-deck, seed it from the image-baked
# config. Source lives at /usr/local/share/ rather than /tmp/ because /tmp is a
# tmpfs at runtime on Coder hosts and would shadow build-time content.
if [ -d "$HOME/.agent-deck" ] && [ ! -f "$HOME/.agent-deck/config.toml" ]; then
    echo "==> Seeding agent-deck config into persistent volume..."
    cp /usr/local/share/devcontainer-config/agent-deck.toml "$HOME/.agent-deck/config.toml"
fi

# --- Claude Code settings ---
# Two layers, both owned by the dev container (never the volume):
#
#   1. /etc/claude-code/managed-settings.json — baked by the Dockerfile.
#      Highest precedence (policySettings); enforces skipDangerousModePermissionPrompt,
#      defaultMode, and the baseline Bash(...) allow list. Users CANNOT override
#      these. Source of truth: .devcontainer/config/claude-settings.json.
#
#   2. ~/.claude/settings.json (user level) — seed-merged below from
#      claude-user-defaults.json. Provides defaults the user CAN override
#      (currently: model, plus the statusLine renderer baked at
#      /etc/claude-code/statusline.sh). Existing values in ~/.claude/
#      settings.json always win on conflict, so /model and other in-app changes
#      stick across post-create runs. On a fresh volume the defaults are
#      populated; on a volume wipe + rebuild they come back automatically.
CLAUDE_DEFAULTS_SRC=/usr/local/share/devcontainer-config/claude-user-defaults.json
CLAUDE_USER_SETTINGS="$HOME/.claude/settings.json"
if [ -d "$HOME/.claude" ] && [ -f "$CLAUDE_DEFAULTS_SRC" ]; then
    if [ ! -f "$CLAUDE_USER_SETTINGS" ]; then
        echo "==> Seeding ~/.claude/settings.json from dev container defaults..."
        install -m 0600 "$CLAUDE_DEFAULTS_SRC" "$CLAUDE_USER_SETTINGS"
    elif command -v jq >/dev/null 2>&1; then
        # Deep-merge: defaults fill in missing fields, existing user values win.
        # `.[0] * .[1]` puts existing on the right so it overrides defaults.
        tmp=$(mktemp)
        if jq -s '.[0] * .[1]' "$CLAUDE_DEFAULTS_SRC" "$CLAUDE_USER_SETTINGS" >"$tmp"; then
            if ! cmp -s "$tmp" "$CLAUDE_USER_SETTINGS"; then
                echo "==> Merging dev container defaults into ~/.claude/settings.json..."
                install -m 0600 "$tmp" "$CLAUDE_USER_SETTINGS"
            fi
            rm -f "$tmp"
        else
            echo "WARNING: jq merge of Claude user defaults failed; leaving settings.json unchanged" >&2
            rm -f "$tmp"
        fi
    fi
fi

# --- Agent-Deck conductor setup ---
# Inject Telegram bot token from env var into agent-deck config
if [ -n "${AGENT_DECK_TELEGRAM_KEY:-}" ]; then
    echo "==> Injecting Telegram bot token into agent-deck config..."
    sd 'token = ".*"' "token = \"${AGENT_DECK_TELEGRAM_KEY}\"" "$HOME/.agent-deck/config.toml"
fi

# Ensure bridge dependencies are installed for the runtime Python.
# The shared toolchain image installs toml/aiogram for the base system Python,
# but the devcontainer Python feature (3.14) replaces python3 on the PATH.
pip install --quiet toml aiogram 2>/dev/null || true

# Set up conductor if not already present (named after this repo)
REPO_NAME="$(basename "$PWD")"
if [ ! -d "$HOME/.agent-deck/conductor/$REPO_NAME" ]; then
    echo "==> Setting up agent-deck conductor '$REPO_NAME'..."
    echo "n" | agent-deck conductor setup "$REPO_NAME" \
        --description "$REPO_NAME devcontainer conductor" \
        --no-heartbeat || true
fi

if [ -f pyproject.toml ]; then
    echo "==> Setting up Python virtualenv and dependencies..."
    # .venv is a named volume (see devcontainer.json mounts), which docker
    # creates root-owned on first use — hand it to the container user before
    # uv sync writes into it.
    if [ -d .venv ] && [ ! -w .venv ]; then
        sudo chown "$(id -un):$(id -gn)" .venv
    fi
    uv sync
else
    echo "==> No pyproject.toml found; skipping Python setup."
fi

if [ -f ansible/requirements.yml ]; then
    echo "==> Installing Ansible Galaxy collections..."
    uv run ansible-galaxy collection install -r ansible/requirements.yml
else
    echo "==> No ansible/requirements.yml found; skipping Ansible setup."
fi

if [ -d services/harmon-lab-proxy/homepage ]; then
    echo "==> Installing Node.js dependencies for homepage..."
    (cd services/harmon-lab-proxy/homepage && npm ci)
fi

if [ -f lefthook.yml ] && command -v lefthook &>/dev/null; then
    echo "==> Setting up git hooks via lefthook..."
    lefthook install
fi

echo "==> Wiring up shell aliases/functions source line..."
# Source the image-baked shell-aliases.sh from both .bashrc and .zshrc so it
# works regardless of which shell is active (scripts still use bash).
for rcfile in ~/.bashrc ~/.zshrc; do
    touch "$rcfile"
    if ! grep -Fqx "${PROFILE_SOURCE_LINE}" "$rcfile"; then
        {
            echo ""
            echo "# Added by devcontainer post-create"
            echo "${PROFILE_SOURCE_LINE}"
        } >>"$rcfile"
    fi
done

if [ -d terraform ]; then
    echo "==> Initializing Terraform providers..."
    (cd terraform && terraform init -backend=false) || true
fi

if command -v direnv &>/dev/null && [ -f .envrc ]; then
    echo "==> Allowing direnv .envrc..."
    direnv allow
fi

# Clone related repos into /workspaces/ (idempotent + non-destructive; reads
# .devcontainer/related-repos.txt). Runs on create so a rebuilt container
# re-populates siblings. No-op when the list is empty/absent.
bash .devcontainer/scripts/bootstrap-related-repos.sh

echo "==> Setup complete! Run 'task verify' to validate your environment."
