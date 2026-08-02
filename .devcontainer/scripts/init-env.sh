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

# This script controls two things about the env-file: which vars it INJECTS
# (from the host env, per the profile's allow-list) and which it EVICTS (strips
# when disallowed). The env-file is actively-managed runtime state, NOT user
# data — TS_AUTHKEY is evicted from the bot profile, ANTHROPIC_API_KEY is always
# stripped — so this is secret hygiene, not a mutation of user-owned files (the
# values themselves live in 1Password; the env-file is only a projection). Vars
# the script does NOT recognize are left untouched, so a value an opted-out repo
# populates out-of-band (e.g. an app's own DEEPSEEK_API_KEY) survives rebuilds.
#
# The var sets are split by purpose, not merged into one:
#   BASE_MANAGED_VARS    — always-on secrets every profile may carry. These form
#                          the implicit default allow-list (the no-arg fallback)
#                          and are evicted when a profile disallows them.
#   ANTHROPIC_API_KEY    — recognized only to be stripped. It silently overrides
#                          CLAUDE_CODE_OAUTH_TOKEN, so it must never reach the
#                          container: never allow-listed, always evicted.
#   OPT_IN_PROVIDER_KEYS — alt-model keys (use_alternative_claude_providers).
#                          They are INJECTION-controlled only: an opted-in
#                          profile's initializeCommand passes them (so they're
#                          injected from the host env); an opted-out one doesn't
#                          (so they're never injected). They are deliberately NOT
#                          evicted when disallowed, so an opted-out repo that
#                          uses a same-named var as an unrelated application
#                          secret does NOT silently lose it on every rebuild. The
#                          load-bearing control is injection: a no-arg or
#                          opted-out invocation never writes paid opt-in
#                          credentials into a default-off repo's env-file, and a
#                          revoked opt-in stops injecting them. The trade-off is
#                          that a stale provider key already in the env-file when
#                          the opt-in is revoked is NOT auto-evicted — it lingers
#                          until cleared manually. That is a least-privilege nit,
#                          not a leak: the key stays safe in 1Password and the
#                          env-file is host-local and gitignored.
BASE_MANAGED_VARS=(TS_AUTHKEY GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY)
OPT_IN_PROVIDER_KEYS=(KIMI_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY)
# KNOWN_VARS: every var this script recognizes. The filter below restricts the
# caller's allow-list to this set, so a positional arg can't smuggle an unknown
# var into the env-file. Includes the opt-in keys so an opted-in profile can
# inject them.
KNOWN_VARS=("${BASE_MANAGED_VARS[@]}" ANTHROPIC_API_KEY "${OPT_IN_PROVIDER_KEYS[@]}")
# EVICT_VARS: vars stripped from the env-file when not in the profile's
# allow-list. The opt-in provider keys are intentionally absent (see above) so an
# opted-out repo keeps any same-named value it set independently.
EVICT_VARS=("${BASE_MANAGED_VARS[@]}" ANTHROPIC_API_KEY)

# Vars this profile is allowed to populate. Caller passes the allow-list
# as additional args after the env-file path. With no extra args we default to
# the always-on base vars only — ANTHROPIC_API_KEY (never allowed) and the opt-in
# provider keys (only when the caller passes them) are excluded, so the no-arg
# fallback evicts them rather than injecting them.
if [ "$#" -gt 0 ]; then
    ALLOWED_VARS=("$@")
else
    ALLOWED_VARS=("${BASE_MANAGED_VARS[@]}")
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

# Restrict ALLOWED_VARS to the intersection with KNOWN_VARS, and strip
# ANTHROPIC_API_KEY unconditionally. A caller cannot smuggle an unknown var
# into the env-file by passing it as a positional arg.
FILTERED_ALLOWED_VARS=()
for var in "${ALLOWED_VARS[@]}"; do
    [ "$var" = "ANTHROPIC_API_KEY" ] && continue
    if contains "$var" "${KNOWN_VARS[@]}"; then
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

# Strip any forbidden var (in EVICT_VARS but not in this profile's allow-list).
# This guarantees, for example, that the bot profile evicts TS_AUTHKEY even if a
# stale value was written to the env-file by an earlier rebuild. The opt-in
# provider keys are not in EVICT_VARS, so an opted-out repo keeps any same-named
# value it set independently.
for var in "${EVICT_VARS[@]}"; do
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
