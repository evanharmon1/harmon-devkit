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
# ZAI_API_KEY, QWEN_API_KEY); if absent, it falls back to `op run` against
# $CLAUDE_PROVIDERS_ENV_FILE (dev profile only — the bot has no 1Password CLI).
# claude-qwen-local is the exception: it targets a LOCAL Anthropic-compatible
# endpoint (Ollama/LM Studio), so it needs no secret at all.
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
        unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN KIMI_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY QWEN_API_KEY
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
        unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN KIMI_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY QWEN_API_KEY
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
        unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN KIMI_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY QWEN_API_KEY
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
        export API_TIMEOUT_MS="3000000"
        command claude "$@"
    )
}

# Launch Claude Code with Qwen3.7-Max for the main/reasoning roles and
# Qwen3-Coder-Plus for the coding/subagent roles, without changing the parent
# shell environment. Uses an existing QWEN_API_KEY, otherwise loads it from
# $CLAUDE_PROVIDERS_ENV_FILE through `op run` (dev profile only — bot has no op).
claude-qwen() {
    local api_key="${QWEN_API_KEY:-}"
    local provider_env_file="${CLAUDE_PROVIDERS_ENV_FILE:-$HOME/.config/claude-providers.env}"

    if [ -z "$api_key" ]; then
        if [ "${CLAUDE_PROVIDERS_OP_RUN_ACTIVE:-}" = "1" ]; then
            echo "claude-qwen: $provider_env_file did not provide QWEN_API_KEY" >&2
            return 1
        fi
        if ! command -v op >/dev/null 2>&1; then
            echo "claude-qwen: op is not installed and QWEN_API_KEY is not set" >&2
            return 1
        fi
        if [ ! -r "$provider_env_file" ]; then
            echo "claude-qwen: cannot read $provider_env_file" >&2
            return 1
        fi

        CLAUDE_PROVIDERS_OP_RUN_ACTIVE=1 \
            op run --no-masking --env-file="$provider_env_file" -- "${SHELL:-/bin/zsh}" -c \
            'source /usr/local/share/devcontainer-config/claude-providers.sh; claude-qwen "$@"' -- "$@"
        return
    fi

    (
        unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN KIMI_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY QWEN_API_KEY
        unset CLAUDE_PROVIDERS_OP_RUN_ACTIVE
        export ANTHROPIC_BASE_URL="https://dashscope.aliyuncs.com/api/anthropic"
        export ANTHROPIC_AUTH_TOKEN="$api_key"
        export ANTHROPIC_MODEL="qwen3.7-max"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="qwen3.7-max"
        export ANTHROPIC_DEFAULT_FABLE_MODEL="qwen3.7-max"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="qwen3-coder-plus"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="qwen3-coder-plus"
        export CLAUDE_CODE_SUBAGENT_MODEL="qwen3-coder-plus"
        export ENABLE_CLAUDEAI_MCP_SERVERS="false"
        export ENABLE_TOOL_SEARCH="false"
        export CLAUDE_CODE_AUTO_COMPACT_WINDOW="1048576"
        command claude "$@"
    )
}

# Launch Claude Code against a LOCAL Anthropic-compatible endpoint (Ollama or
# LM Studio) serving qwen3-coder:30b, without changing the parent shell
# environment. No provider secret is required — this is a local-only lane —
# but ANTHROPIC_AUTH_TOKEN must still be non-empty for the SDK, so a
# placeholder value is sent; it is meaningless to a local endpoint, and no
# real secret is ever read or exported by this function.
#
# The default HOST is chosen, not hardcoded: "localhost" inside a container
# resolves to the container itself, not the developer's machine, where Ollama/
# LM Studio actually listen — but this file also sources un-containerized (the
# host wrappers), where "localhost" IS correct. So the default probes for
# host.docker.internal and only falls back to "localhost" when that name does
# not resolve. Both shipped devcontainer profiles
# (.devcontainer/devcontainer.json, .devcontainer/dev/devcontainer.json) add
# `--add-host=host.docker.internal:host-gateway` to runArgs, so the probe's
# primary path resolves there even on native Linux (Docker Desktop resolves it
# without any mapping). Outside those profiles — a hand-rolled `docker run`, a
# different devcontainer config — add the same --add-host yourself, or just set
# QWEN_LOCAL_BASE_URL directly; it always overrides either default. On native
# Linux the DNS mapping alone is not enough: stock Ollama binds
# 127.0.0.1:11434, which is loopback-only and unreachable from the container
# even once host.docker.internal resolves. Do NOT bind 0.0.0.0 — Ollama has no
# auth, so that exposes it to the whole LAN. Instead set
# OLLAMA_HOST=<docker0-bridge-IP> (`ip addr show docker0`, typically
# 172.17.0.1) to scope it to the Docker bridge, or firewall 11434 to that
# bridge if it must stay on 0.0.0.0 for other reasons — or point
# QWEN_LOCAL_BASE_URL at an already-reachable endpoint.
#
# No /anthropic (or other) path suffix on the default: unlike the hosted
# wrappers below, Ollama's and LM Studio's Anthropic-compatible servers expose
# /v1/messages etc. from the SERVER ROOT, and the Claude Code SDK appends that
# API path to ANTHROPIC_BASE_URL itself — a base URL ending in /anthropic here
# would double up to /anthropic/v1/messages and 404.
claude-qwen-local() {
    local default_host="localhost"
    if command -v getent >/dev/null 2>&1 && getent hosts host.docker.internal >/dev/null 2>&1; then
        default_host="host.docker.internal"
    fi
    local base_url="${QWEN_LOCAL_BASE_URL:-http://${default_host}:11434}"

    (
        unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN KIMI_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY QWEN_API_KEY
        unset CLAUDE_PROVIDERS_OP_RUN_ACTIVE
        export ANTHROPIC_BASE_URL="$base_url"
        export ANTHROPIC_AUTH_TOKEN="local"
        export ANTHROPIC_MODEL="qwen3-coder:30b"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="qwen3-coder:30b"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="qwen3-coder:30b"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="qwen3-coder:30b"
        export ANTHROPIC_DEFAULT_FABLE_MODEL="qwen3-coder:30b"
        export CLAUDE_CODE_SUBAGENT_MODEL="qwen3-coder:30b"
        export ENABLE_CLAUDEAI_MCP_SERVERS="false"
        command claude "$@"
    )
}
