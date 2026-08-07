#!/usr/bin/env bash
# shellcheck shell=bash
#
# claude-providers.sh — alternative Anthropic-compatible model launchers, SOURCED
# (not executed) from shell-aliases.sh (which is sourced from ~/.bashrc / ~/.zshrc
# by post-create-common.sh). Mirrors the equivalent host shell functions.
# Intentionally omits `set -euo pipefail` (it is sourced).
#
# Each function launches Claude Code against a provider's native /anthropic endpoint
# by setting ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN (+ per-tier model env vars) in
# a subshell, leaving the parent shell untouched. The API key is read from the env
# (the devcontainer env-file: KIMI_API_KEY/MOONSHOT_API_KEY, DEEPSEEK_API_KEY,
# ZAI_API_KEY); if absent, it falls back to `op run` against
# $CLAUDE_PROVIDERS_ENV_FILE (dev profile only — the bot has no 1Password CLI).
#
# CONTAINER ADAPTATIONS vs the host wrappers:
#   1. The `op run` re-exec re-sources THIS file's baked path
#      (/usr/local/share/devcontainer-config/claude-providers.sh), not whatever
#      host file defines the equivalent functions.
#   2. The launch subshell unsets CLAUDE_CODE_OAUTH_TOKEN (in addition to
#      ANTHROPIC_API_KEY). The container sets CLAUDE_CODE_OAUTH_TOKEN via its
#      env-file; if left set, it would compete with the provider's
#      ANTHROPIC_AUTH_TOKEN. Unsetting it guarantees the provider auth wins.
#
# The `op run` fallback uses --no-masking deliberately (matching the host
# wrappers). 1Password's default masking intercepts stdout/stderr to scrub
# secret values, which is incompatible with the interactive Claude Code TUI's
# terminal I/O. The trade-off: a process that prints ANTHROPIC_AUTH_TOKEN would
# not be auto-redacted — but normal Claude operation never prints it, and the
# launch subshell unsets every raw provider key after exporting
# ANTHROPIC_AUTH_TOKEN, so the token is the only secret in scope.

# Launch Claude Code with Kimi K3 without changing the parent shell environment.
# Uses an existing KIMI_API_KEY (or MOONSHOT_API_KEY), otherwise loads it from
# $CLAUDE_PROVIDERS_ENV_FILE through `op run` (dev profile only — bot has no op).
claude-kimi() {
    local api_key="${KIMI_API_KEY:-${MOONSHOT_API_KEY:-}}"
    local provider_env_file="${CLAUDE_PROVIDERS_ENV_FILE:-$HOME/.config/claude-providers.env}"

    if [ -z "$api_key" ]; then
        if [ "${CLAUDE_PROVIDERS_OP_RUN_ACTIVE:-}" = "1" ]; then
            echo "claude-kimi: $provider_env_file did not provide KIMI_API_KEY or MOONSHOT_API_KEY" >&2
            return 1
        fi
        if ! command -v op >/dev/null 2>&1; then
            echo "claude-kimi: op is not installed and KIMI_API_KEY or MOONSHOT_API_KEY is not set" >&2
            return 1
        fi
        if [ ! -r "$provider_env_file" ]; then
            echo "claude-kimi: cannot read $provider_env_file" >&2
            return 1
        fi

        CLAUDE_PROVIDERS_OP_RUN_ACTIVE=1 \
            op run --no-masking --env-file="$provider_env_file" -- "${SHELL:-/bin/zsh}" -c \
            'source /usr/local/share/devcontainer-config/claude-providers.sh; claude-kimi "$@"' -- "$@"
        return
    fi

    (
        unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN KIMI_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY
        unset CLAUDE_PROVIDERS_OP_RUN_ACTIVE
        export ANTHROPIC_BASE_URL="https://api.moonshot.ai/anthropic"
        export ANTHROPIC_AUTH_TOKEN="$api_key"
        export ANTHROPIC_MODEL="kimi-k3[1m]"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="kimi-k3[1m]"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="kimi-k3[1m]"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="kimi-k3[1m]"
        export ANTHROPIC_DEFAULT_FABLE_MODEL="kimi-k3[1m]"
        export CLAUDE_CODE_SUBAGENT_MODEL="kimi-k3[1m]"
        export ENABLE_CLAUDEAI_MCP_SERVERS="false"
        export ENABLE_TOOL_SEARCH="false"
        export CLAUDE_CODE_AUTO_COMPACT_WINDOW="1048576"
        export CLAUDE_CODE_EFFORT_LEVEL="max"
        command claude "$@"
    )
}

# Launch Claude Code with DeepSeek V4 Pro for primary work and V4 Flash for
# lightweight tiers and subagents, without changing the parent shell environment.
# Uses an existing DEEPSEEK_API_KEY, otherwise loads it from
# $CLAUDE_PROVIDERS_ENV_FILE through `op run` (dev profile only — bot has no op).
claude-deepseek() {
    local api_key="${DEEPSEEK_API_KEY:-}"
    local provider_env_file="${CLAUDE_PROVIDERS_ENV_FILE:-$HOME/.config/claude-providers.env}"

    if [ -z "$api_key" ]; then
        if [ "${CLAUDE_PROVIDERS_OP_RUN_ACTIVE:-}" = "1" ]; then
            echo "claude-deepseek: $provider_env_file did not provide DEEPSEEK_API_KEY" >&2
            return 1
        fi
        if ! command -v op >/dev/null 2>&1; then
            echo "claude-deepseek: op is not installed and DEEPSEEK_API_KEY is not set" >&2
            return 1
        fi
        if [ ! -r "$provider_env_file" ]; then
            echo "claude-deepseek: cannot read $provider_env_file" >&2
            return 1
        fi

        CLAUDE_PROVIDERS_OP_RUN_ACTIVE=1 \
            op run --no-masking --env-file="$provider_env_file" -- "${SHELL:-/bin/zsh}" -c \
            'source /usr/local/share/devcontainer-config/claude-providers.sh; claude-deepseek "$@"' -- "$@"
        return
    fi

    (
        unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN KIMI_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY
        unset CLAUDE_PROVIDERS_OP_RUN_ACTIVE
        export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
        export ANTHROPIC_AUTH_TOKEN="$api_key"
        export ANTHROPIC_MODEL="deepseek-v4-pro[1m]"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="deepseek-v4-pro[1m]"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="deepseek-v4-pro[1m]"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="deepseek-v4-flash"
        export ANTHROPIC_DEFAULT_FABLE_MODEL="deepseek-v4-pro[1m]"
        export CLAUDE_CODE_SUBAGENT_MODEL="deepseek-v4-flash"
        export ENABLE_CLAUDEAI_MCP_SERVERS="false"
        export CLAUDE_CODE_EFFORT_LEVEL="max"
        command claude "$@"
    )
}

# Launch Claude Code with Z.AI GLM-5.2 without changing the parent shell
# environment. Uses an existing ZAI_API_KEY, otherwise loads it from
# $CLAUDE_PROVIDERS_ENV_FILE through `op run` (dev profile only — bot has no op).
claude-glm() {
    local api_key="${ZAI_API_KEY:-}"
    local provider_env_file="${CLAUDE_PROVIDERS_ENV_FILE:-$HOME/.config/claude-providers.env}"

    if [ -z "$api_key" ]; then
        if [ "${CLAUDE_PROVIDERS_OP_RUN_ACTIVE:-}" = "1" ]; then
            echo "claude-glm: $provider_env_file did not provide ZAI_API_KEY" >&2
            return 1
        fi
        if ! command -v op >/dev/null 2>&1; then
            echo "claude-glm: op is not installed and ZAI_API_KEY is not set" >&2
            return 1
        fi
        if [ ! -r "$provider_env_file" ]; then
            echo "claude-glm: cannot read $provider_env_file" >&2
            return 1
        fi

        CLAUDE_PROVIDERS_OP_RUN_ACTIVE=1 \
            op run --no-masking --env-file="$provider_env_file" -- "${SHELL:-/bin/zsh}" -c \
            'source /usr/local/share/devcontainer-config/claude-providers.sh; claude-glm "$@"' -- "$@"
        return
    fi

    (
        unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN KIMI_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY
        unset CLAUDE_PROVIDERS_OP_RUN_ACTIVE
        export ANTHROPIC_BASE_URL="https://api.z.ai/api/anthropic"
        export ANTHROPIC_AUTH_TOKEN="$api_key"
        export ANTHROPIC_MODEL="glm-5.2"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="glm-5.2"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="glm-5.2"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="glm-5.2"
        export ANTHROPIC_DEFAULT_FABLE_MODEL="glm-5.2"
        export CLAUDE_CODE_SUBAGENT_MODEL="glm-5.2"
        export ENABLE_CLAUDEAI_MCP_SERVERS="false"
        export ENABLE_TOOL_SEARCH="false"
        export CLAUDE_CODE_AUTO_COMPACT_WINDOW="1048576"
        export CLAUDE_CODE_EFFORT_LEVEL="max"
        export API_TIMEOUT_MS="3000000"
        command claude "$@"
    )
}
