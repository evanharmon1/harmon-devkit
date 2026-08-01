#!/usr/bin/env bash
# seed-fable-consent.sh — record Fable 5's one-time usage-credit consent for
# whichever account is currently signed in to Claude Code.
#
# Fable 5 needs a one-time "draws from usage credits" consent. Claude Code
# stores it PER MACHINE in ~/.claude.json under .fableOverageConsentV2, keyed
# by the signed-in account's organizationUuid (or "acct:<accountUuid>").
# ~/.claude is a container-local volume, so the consent granted on the host
# never reaches the dev container.
#
# Without the record Claude Code arms a credits gate on the first API response
# reporting overage-in-use — the setter is guarded by "no consent recorded", so
# a machine that already has it never arms the gate at all. Accepting the
# resulting prompt then live-checks extra usage, and when the account's cached
# extra-usage state is out_of_credits that path dead-ends, leaving Fable
# unselectable in /model on an account that is entitled to it.
#
# Runs from two places, because neither alone is sufficient:
#   * postStart — covers every container start, but on a FRESH volume it runs
#     before any login has happened, so .oauthAccount does not exist yet and
#     this exits without writing.
#   * Claude Code's SessionStart hook — runs after authentication, which is the
#     only point where the account UUIDs this key is built from are knowable on
#     a first-run container.
#
# Deriving the key from the live .oauthAccount rather than hardcoding one keeps
# this correct for whichever account is signed in.
#
# Idempotent and non-destructive: it no-ops when there is no account yet, when
# consent is already recorded, and when the file is unreadable or malformed.
# Exits 0 in all of those cases — it must never fail a container start or block
# a Claude session.
#
# Quiet by default: SessionStart hook stdout is injected into the session's
# context, so only --verbose (used by postStart) prints on success.

set -euo pipefail

CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude/.claude.json}"
verbose=""
[ "${1:-}" = "--verbose" ] && verbose=1

command -v jq >/dev/null 2>&1 || exit 0
[ -f "$CLAUDE_JSON" ] || exit 0

# Prefer organizationUuid over accountUuid — that is the order Claude Code
# itself resolves the key in, so seeding the other one would not be read.
consent_key="$(jq -r '.oauthAccount // {}
    | if .organizationUuid then .organizationUuid
      elif .accountUuid then "acct:" + .accountUuid
      else empty end' "$CLAUDE_JSON" 2>/dev/null || true)"
[ -n "$consent_key" ] || exit 0

already="$(jq -r --arg k "$consent_key" '.fableOverageConsentV2[$k] // false' \
    "$CLAUDE_JSON" 2>/dev/null || true)"
if [ "$already" = "true" ]; then
    exit 0
fi

consent_tmp="$(mktemp)"
if jq --arg k "$consent_key" \
    '.fableOverageConsentV2 = ((.fableOverageConsentV2 // {}) | .[$k] = true)' \
    "$CLAUDE_JSON" >"$consent_tmp"; then
    mv "$consent_tmp" "$CLAUDE_JSON"
    [ -n "$verbose" ] &&
        echo "==> Recorded Fable 5 usage-credit consent for the signed-in account"
else
    rm -f "$consent_tmp"
    echo "seed-fable-consent: could not update $CLAUDE_JSON; left unchanged" >&2
fi

exit 0
