#!/usr/bin/env bash
set -euo pipefail

# Populate the devcontainer env-file with host-environment secrets.
#
# Variables set in the host env always win — any stale entry in the file
# is replaced with the current value. Variables NOT in the host env are
# left untouched, so 1Password-managed values survive when the user
# doesn't also export them in their shell.
#
# On Coder / Codespaces the host env carries secrets from template
# parameters, so they flow into the env-file on every rebuild.

# Keep devcontainer config up to date on rebuilds.
# Only fast-forward main — don't touch feature branches or dirty trees.
if git rev-parse --is-inside-work-tree &>/dev/null &&
    [ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] &&
    git diff --quiet 2>/dev/null; then
    git pull --ff-only origin main 2>/dev/null || true
fi

ENV_FILE="${1:-.devcontainer/devcontainer.env}"
shift || true

# All vars this script knows how to manage. Anything in this list but
# NOT in the per-profile allow-list below is considered forbidden and is
# unconditionally stripped from the env-file on every run.
# ANTHROPIC_API_KEY is in the managed list so the eviction loop strips it from
# the env-file if it ever lands there — it must never be allowed into the
# container since it silently overrides CLAUDE_CODE_OAUTH_TOKEN.
ALL_MANAGED_VARS=(TS_AUTHKEY GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY ANTHROPIC_API_KEY)

# Vars this profile is allowed to populate. Caller passes the allow-list
# as additional args after the env-file path. With no extra args we
# default to all known vars except ANTHROPIC_API_KEY, which must never
# be allowed into the container (it silently overrides CLAUDE_CODE_OAUTH_TOKEN).
if [ "$#" -gt 0 ]; then
    ALLOWED_VARS=("$@")
else
    # Safe default: all managed vars; ANTHROPIC_API_KEY is filtered below.
    ALLOWED_VARS=("${ALL_MANAGED_VARS[@]}")
fi

contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# Restrict ALLOWED_VARS to the intersection with ALL_MANAGED_VARS, and strip
# ANTHROPIC_API_KEY unconditionally. A caller cannot smuggle an unknown var
# into the env-file by passing it as a positional arg.
FILTERED_ALLOWED_VARS=()
for var in "${ALLOWED_VARS[@]}"; do
    [ "$var" = "ANTHROPIC_API_KEY" ] && continue
    if contains "$var" "${ALL_MANAGED_VARS[@]}"; then
        FILTERED_ALLOWED_VARS+=("$var")
    fi
done
ALLOWED_VARS=("${FILTERED_ALLOWED_VARS[@]}")

touch "$ENV_FILE"

# Remove every line setting $1 from $2, portably. GNU `sed -i` is not
# available on macOS (BSD sed needs a suffix arg after -i, so `sed -i expr
# file` silently does nothing useful) — and initializeCommand runs this
# script on the HOST, which is often a Mac.
strip_var() {
    local tmp
    tmp="$(mktemp)"
    grep -v "^${1}=" "$2" >"$tmp" || true
    mv "$tmp" "$2"
}

# Strip any forbidden var (managed by the script but not in this
# profile's allow-list). This guarantees, for example, that the bot
# profile evicts TS_AUTHKEY even if a stale value was written to the
# env-file by an earlier rebuild.
for var in "${ALL_MANAGED_VARS[@]}"; do
    if ! contains "$var" "${ALLOWED_VARS[@]}"; then
        strip_var "$var" "$ENV_FILE"
    fi
done

# For allowed vars, replace any stale entry with the current host value.
# Vars not present in the host env are left untouched, so values
# populated out-of-band (e.g. from 1Password) survive rebuilds.
for var in "${ALLOWED_VARS[@]}"; do
    val="${!var:-}"
    if [ -n "$val" ]; then
        strip_var "$var" "$ENV_FILE"
        echo "${var}=${val}" >>"$ENV_FILE"
    fi
done
