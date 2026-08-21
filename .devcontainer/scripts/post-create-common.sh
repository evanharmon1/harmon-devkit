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
# The scope list the login line below asks for comes from scripts/gh-scopes.sh,
# the same file status.sh and setup-gh-scopes.sh read, so the banner cannot
# drift from what the session-start check demands (issue #827). Sourced
# defensively: this script also runs in trees where the workspace folder is not
# yet the repo root, and a missing helper must not fail the whole post-create.
GH_SCOPES_LIB="${GH_SCOPES_LIB:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/gh-scopes.sh}"
if [ -r "${GH_SCOPES_LIB}" ]; then
    # shellcheck source=scripts/gh-scopes.sh
    . "${GH_SCOPES_LIB}"
else
    gh_scopes_request_list() { printf '%s' "repo,workflow,project,read:project"; }
fi

gh_auth_help() {
    echo "=============================================================="
    echo "  GitHub CLI is NOT authenticated — gh pr / gh api and the"
    echo "  related-repo clones will fail until this is fixed."
    echo ""
    if [ "${DEVCONTAINER_GH_AUTH:-token}" = "login" ]; then
        echo "  This profile authenticates as you. Log in:"
        echo ""
        echo "    gh auth login --hostname github.com --git-protocol https \\"
        echo "      --web --scopes \"$(gh_scopes_request_list)\""
        echo ""
        echo "  Then, in the checkout, 'task setup:gh-scopes' verifies the"
        echo "  scopes landed and adds any this repo needs. (It refreshes an"
        echo "  EXISTING login — it cannot replace the command above.)"
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
    /home/vscode/.config /home/vscode/.config/herdr /home/vscode/.config/opencode \
    /home/vscode/.local /home/vscode/.local/share /home/vscode/.local/share/opencode \
    /home/vscode/.local/share/zoxide; do
    sudo mkdir -p "$dir"
    sudo chown vscode:vscode "$dir"
    chmod 700 "$dir"
done

# --- Coder persistent volume symlinks ---
# Coder's envbuilder does not support devcontainer volume mounts, so on Coder
# the template provides a single persistent volume at ~/.persistent/ and we
# symlink the individual directories there.
#
# ORDERING IS LOAD-BEARING: this block must run BEFORE link-claude-json.sh and
# the onboarding seed below. Until these symlinks exist, ~/.claude on Coder is
# the container-local directory the ownership loop just created — the helper
# and the seed would populate THAT, and this block's migration `cp -a` would
# then copy the fresh stub over ~/.persistent/.claude/'s real account state:
# the exact clobber this change exists to prevent, surviving on the one
# platform whose persistence is wired by symlink instead of mount.
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
    mkdir -p "/home/vscode/.persistent/herdr" "$HOME/.config"
    # Unlike the agent dirs above, ~/.config/herdr can hold the only copy of
    # session snapshots — never delete the source unless the copy succeeded,
    # and fail the lifecycle rather than continue unpersisted: a
    # warn-and-continue would let Herdr write snapshots the next rebuild
    # silently discards.
    if [ -d "$HOME/.config/herdr" ] && [ ! -L "$HOME/.config/herdr" ]; then
        if ! cp -a "$HOME/.config/herdr/." "/home/vscode/.persistent/herdr/"; then
            echo "ERROR: Herdr state migration to ~/.persistent failed;" \
                "fix the persistent volume and rebuild" >&2
            exit 1
        fi
        rm -rf "${HOME:?}/.config/herdr"
    fi
    ln -sfn "/home/vscode/.persistent/herdr" "$HOME/.config/herdr"
    bash .devcontainer/scripts/persist-opencode.sh /home/vscode/.persistent
fi

# --- Persist ~/.claude.json into the ~/.claude volume ---
# MUST run before anything below that can spawn `claude` (the onboarding seed,
# the herdr integration install, and the agent-deck conductor setup all can) —
# a `claude` launched with no symlink in place writes a fresh, near-empty REAL
# file at ~/.claude.json, which post-start would then have moved OVER the
# persisted 38 KB of account state. And it must run AFTER the Coder persistence
# block above, so that on Coder ~/.claude already points into ~/.persistent
# rather than at the container-local directory. See link-claude-json.sh.
bash .devcontainer/scripts/link-claude-json.sh

# --- Claude Code onboarding seed ---
# Pre-seed ~/.claude/.claude.json so fresh containers skip the onboarding
# wizard (upstream issue: https://github.com/anthropics/claude-code/issues/8938).
# post-start-common.sh creates ~/.claude.json → ~/.claude/.claude.json so
# Claude Code finds this file on first launch. Guard: only seed on an empty
# volume — existing session data (token, settings) must never be clobbered.
# Same ordering constraint as the helper: on Coder this must see the
# persistent ~/.claude, not the pre-symlink local one.
CLAUDE_SESSION_FILE="$HOME/.claude/.claude.json"
if [ -d "$HOME/.claude" ] && [ ! -f "$CLAUDE_SESSION_FILE" ]; then
    echo '{"hasCompletedOnboarding":true}' >"$CLAUDE_SESSION_FILE"
    chmod 0600 "$CLAUDE_SESSION_FILE"
    echo "==> Seeded ~/.claude/.claude.json with hasCompletedOnboarding=true"
fi

# --- Herdr agent integrations ---
# resume_agents_on_restore only resumes agents whose Herdr integration has
# recorded a native session reference, and the integration also reports
# authoritative working/blocked state to the sidebar instead of Herdr
# screen-scraping. The installer is version-aware and file-writing only (no
# running server needed), so re-running on every create is safe. Guarded:
# the pinned shared image may predate the herdr binary, and a failed install
# only degrades resume back to fresh shells — never block the container on it.
if command -v herdr >/dev/null 2>&1; then
    for agent in claude codex opencode; do
        herdr integration install "$agent" ||
            echo "WARN: herdr integration install $agent failed (non-fatal)" >&2
    done
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
