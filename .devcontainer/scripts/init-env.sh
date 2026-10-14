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

# `--profile agent` (first arguments) selects the AGENT posture's closed,
# fail-closed allow-list — see "Agent posture" below. It is an explicit flag,
# never inferred from the env-file path, so no path rename can switch it off.
PROFILE=""
if [ "${1:-}" = "--profile" ]; then
    PROFILE="${2:-}"
    case "$PROFILE" in
    agent) ;;
    *)
        echo "init-env.sh: unknown --profile '${PROFILE}' (only 'agent' is defined)" >&2
        exit 1
        ;;
    esac
    shift 2
fi

# The agent profile names its env-file explicitly, as its initializeCommand
# does: the default below is the bot's env-file, which the agent must never
# read or write.
if [ "$PROFILE" = "agent" ] && [ -z "${1:-}" ]; then
    echo "init-env.sh: --profile agent needs the agent env-file path (.devcontainer/agent/devcontainer.env); it never falls back to the bot's .devcontainer/devcontainer.env" >&2
    exit 1
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
# FOREMAN_AGENT_GH_TOKEN is the separate READ-ONLY PAT foreman hands to
# dispatched agents as their GH_TOKEN (required before any dispatch); only
# the bot profile allow-lists it, so it is evicted from dev/ like GH_TOKEN.
BASE_MANAGED_VARS=(TS_AUTHKEY GH_TOKEN FOREMAN_AGENT_GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN AGENT_DECK_TELEGRAM_KEY)
OPT_IN_PROVIDER_KEYS=(KIMI_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY ZAI_API_KEY QWEN_API_KEY)
# AGENT_GH_TOKEN is the agent posture's own fine-grained PAT on the bot
# account (docs/guides/bot-account.md). It is a DIFFERENT host-side name from
# the bot's GH_TOKEN on purpose: a host that exports the bot token (a Coder
# workspace does) can then never project it into the agent env-file by name.
# Only the agent posture admits it, so it is evicted from the bot and dev
# env-files like any other credential a profile must not hold.
AGENT_ONLY_VARS=(AGENT_GH_TOKEN)
# KNOWN_VARS: every var this script recognizes. The filter below restricts the
# caller's allow-list to this set, so a positional arg can't smuggle an unknown
# var into the env-file. Includes the opt-in keys so an opted-in profile can
# inject them.
KNOWN_VARS=("${BASE_MANAGED_VARS[@]}" "${AGENT_ONLY_VARS[@]}" ANTHROPIC_API_KEY "${OPT_IN_PROVIDER_KEYS[@]}")
# EVICT_VARS: vars stripped from the env-file when not in the profile's
# allow-list. The opt-in provider keys are intentionally absent (see above) so an
# opted-out repo keeps any same-named value it set independently.
EVICT_VARS=("${BASE_MANAGED_VARS[@]}" "${AGENT_ONLY_VARS[@]}" ANTHROPIC_API_KEY)
# Agent posture (`--profile agent`): the ONLY vars its env-file may hold. The
# opt-in provider keys are admissible too, but only when the caller passes
# them (a per-repo, disclosed opt-in, as in bot). Everything else — the bot's
# GH_TOKEN and FOREMAN_AGENT_GH_TOKEN, TS_AUTHKEY, an `op` service-account
# token, ANTHROPIC_API_KEY, anything unknown — fails closed below.
AGENT_ADMITTED_VARS=(AGENT_GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN "${OPT_IN_PROVIDER_KEYS[@]}")

# Vars this profile is allowed to populate. Caller passes the allow-list
# as additional args after the env-file path. With no extra args we default to
# the always-on base vars only — ANTHROPIC_API_KEY (never allowed) and the opt-in
# provider keys (only when the caller passes them) are excluded, so the no-arg
# fallback evicts them rather than injecting them.
if [ "$#" -gt 0 ]; then
    ALLOWED_VARS=("$@")
elif [ "$PROFILE" = "agent" ]; then
    ALLOWED_VARS=(AGENT_GH_TOKEN CLAUDE_CODE_OAUTH_TOKEN)
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

# ── Agent posture guard ─────────────────────────────────────────────
# Fails CLOSED rather than filtering: the other profiles silently drop an
# unrecognized allow-list entry and evict disallowed vars, but an agent
# container runs unwatched, so a misconfiguration must stop the build (this
# runs as initializeCommand, where a non-zero exit aborts it) instead of being
# quietly repaired. Two checks, both before anything is written:
#   1. every name the caller allow-lists must be admissible in the agent posture;
#   2. the agent env-file may hold nothing but those allow-listed names. Docker
#      also reads a bare `NAME` line (no `=`) as "pass the host's value
#      through", so any non-comment line that is not `<allowed>=...` counts.
# Names only, never values, in every message.
if [ "$PROFILE" = "agent" ]; then
    agent_guard_failed=0
    for var in "${ALLOWED_VARS[@]}"; do
        if ! contains "$var" "${AGENT_ADMITTED_VARS[@]}"; then
            echo "init-env.sh: agent posture: '${var}' is not admitted (admissible: ${AGENT_ADMITTED_VARS[*]})" >&2
            agent_guard_failed=1
        fi
    done
    if [ -f "$ENV_FILE" ]; then
        agent_line_no=0
        while IFS= read -r agent_line || [ -n "$agent_line" ]; do
            agent_line_no=$((agent_line_no + 1))
            case "$agent_line" in
            "" | \#*) continue ;;
            esac
            agent_name="${agent_line%%=*}"
            if [ "$agent_name" = "$agent_line" ] || ! contains "$agent_name" "${ALLOWED_VARS[@]}"; then
                # A bare line reports its whole text only when it is a plain
                # identifier; anything else is reported by line number, so a
                # malformed line holding a value never reaches the log.
                case "$agent_name" in
                *[!A-Za-z0-9_]* | "") agent_name="<line ${agent_line_no}>" ;;
                esac
                echo "init-env.sh: agent posture: ${ENV_FILE} holds '${agent_name}', which this profile does not admit" >&2
                agent_guard_failed=1
            fi
        done <"$ENV_FILE"
    fi
    if [ "$agent_guard_failed" -ne 0 ]; then
        echo "init-env.sh: agent posture: refusing to continue. Remove the names above from the env-file and the initializeCommand allow-list; see docs/guides/devcontainers.md." >&2
        exit 1
    fi
fi

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

# Create the env-file if it is missing — but NEVER touch an existing one: the
# whole point of the compare below is to leave an unchanged file's mtime alone,
# and an unconditional `touch` here would defeat it on its own.
if [ ! -f "$ENV_FILE" ]; then
    touch "$ENV_FILE"
fi

# Compose the new content in a scratch file and only write it back if it
# actually differs (see the cmp at the bottom). This script runs as
# initializeCommand — on EVERY VS Code connect, not just rebuilds — so an
# unconditional rewrite churned the env-file's mtime, which is enough for
# Coder's devcontainer integration to consider the config dirty and recreate
# the container. Everything below therefore reads and writes WORK_FILE, never
# ENV_FILE.
WORK_FILE="$(mktemp)"
trap 'rm -f "$WORK_FILE"' EXIT
cat "$ENV_FILE" >"$WORK_FILE"

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
        strip_var "$var" "$WORK_FILE"
    fi
done

# For allowed vars, replace any stale entry with the current host value.
# Vars not present in the host env are left untouched, so values
# populated out-of-band (e.g. from 1Password) survive rebuilds.
#
# A var missing from BOTH the host env and the env-file is a different case: it
# is not an out-of-band value being preserved, it is a value nothing will
# supply. Silence there is how a missing TS_AUTHKEY went unnoticed for hours in
# a Coder workspace — the container came up fine and only the Tailscale-
# dependent step failed, far from the cause. So collect those and warn on
# stderr below.
#
# The loop is over ALLOWED_VARS — the post-filter allow-list — NOT over
# BASE_MANAGED_VARS or EVICT_VARS. That is load-bearing for the profile
# boundary, not just tidiness: the bot profile deliberately omits TS_AUTHKEY
# (no tailnet path from a bypassPermissions container), so warning from the
# managed set would print "TS_AUTHKEY missing" on every bot rebuild —
# advertising a credential that profile must never hold, and training the
# reader to expect one. A var this profile is not allowed to populate is not
# missing; it is correctly absent.
missing=""
for var in "${ALLOWED_VARS[@]}"; do
    val="${!var:-}"
    if [ -n "$val" ]; then
        strip_var "$var" "$WORK_FILE"
        echo "${var}=${val}" >>"$WORK_FILE"
    elif ! grep "^${var}=." "$WORK_FILE" >/dev/null; then
        # `=.` requires at least one character after the `=`: a bare "VAR="
        # line (or a host var exported empty, which "${!var:-}" already treats
        # as unset) leaves the container with no usable value, so it warns the
        # same as a wholly absent one. Var names come from KNOWN_VARS, so they
        # carry no regex metacharacters.
        missing="${missing:+$missing }${var}"
    fi
done

# Write back ONLY on a real difference, so a no-op run leaves the env-file's
# mtime (and inode) untouched.
if ! cmp -s "$WORK_FILE" "$ENV_FILE"; then
    mv "$WORK_FILE" "$ENV_FILE"
fi
# Enforce 0600 on EVERY run, not just rewrites: a pre-existing env-file (say,
# copied from devcontainer.env.example under a permissive umask) holds secrets
# at 0644, and the skip-on-identical path above would otherwise leave it that
# way forever. chmod never changes mtime, so this cannot re-trigger the
# recreation churn the compare exists to prevent.
chmod 600 "$ENV_FILE"

# Names only, never values — this lands in build logs. Non-fatal by design: a
# rebuild must not be blocked by an optional secret, and this script runs as
# initializeCommand on the HOST, where a non-zero exit aborts the whole
# container build.
if [ -n "$missing" ]; then
    echo "init-env.sh: warning: allow-listed but unset in the host env and absent from ${ENV_FILE}:" >&2
    echo "init-env.sh:   ${missing}" >&2
    echo "init-env.sh: the container will start without them. On Coder/Codespaces set them as" >&2
    echo "init-env.sh: workspace/repo secrets; locally populate the env-file from 1Password." >&2
fi
