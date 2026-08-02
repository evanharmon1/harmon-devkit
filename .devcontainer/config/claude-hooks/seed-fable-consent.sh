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
#   * a `claude` shell wrapper (config/shell-aliases.sh) — runs immediately
#     before each launch, the one moment that is both after a previous session
#     wrote .oauthAccount and before the next CLI reads its config. Seeding
#     once at shell startup instead would miss a second `claude` in the same
#     terminal, which never re-sources the profile.
#
# It must NOT run from inside Claude Code (a SessionStart hook, say). The CLI
# caches .claude.json in memory at startup and never re-reads it, so a write
# from within a session cannot affect that session — and the CLI's next config
# write serializes its stale in-memory copy back over the file, dropping the
# record entirely. Writing between sessions is what makes the record both
# visible and durable.
#
# The honest residual: on a brand-new container the very first authenticated
# session still cannot select Fable, because the account it would be keyed to
# does not exist until that session authenticates. Every session after it can.
#
# Deriving the key from the live .oauthAccount rather than hardcoding one keeps
# this correct for whichever account is signed in.
#
# Idempotent and non-destructive: it no-ops when there is no account yet, when
# consent is already recorded, and when the file is unreadable or malformed.
# Exits 0 in all of those cases — it must never fail a container start or block
# a Claude session.
#
# Quiet by default: it runs in front of every `claude` launch, so only
# --verbose (used by postStart) prints on success.
#
# OPT-IN ONLY, and that is not incidental. `.fableOverageConsentV2` is a
# BILLING authorization: it records that Fable 5 may draw on usage credits past
# plan limits. This hook is baked into the image and runs for whichever account
# happens to be signed in, so seeding it unconditionally would turn opening a
# repo checkout into a billing-affecting authorization for someone else's
# account — and this dev container config is templated to other repos via
# harmon-init. Granting that silently is not a decision a shared default may
# make, so the gate defaults to off and the account owner opts in per machine:
#
#   echo 'DEVCONTAINER_FABLE_CONSENT=true' >> .devcontainer/devcontainer.env
#
# devcontainer.env is gitignored and personal, and init-env.sh leaves unmanaged
# vars alone, so the opt-in stays with the account owner and never rides along
# in the image or in git. Same shape as DEVCONTAINER_TAILSCALE.

set -euo pipefail

CLAUDE_JSON="${CLAUDE_JSON:-$HOME/.claude/.claude.json}"
verbose=""
[ "${1:-}" = "--verbose" ] && verbose=1

[ "${DEVCONTAINER_FABLE_CONSENT:-}" = "true" ] || exit 0

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

# Serialize against other copies of this script. agent-deck starts several
# Claude sessions at once, so concurrent launches — each running this first —
# are ordinary here, and the read/modify/write below would otherwise let one
# overwrite the other. Losing the lock race means another instance is
# performing the identical write, so skipping is correct rather than merely
# safe.
#
# It does NOT serialize against Claude Code itself, which rewrites
# ~/.claude.json from its own in-memory state without taking any lock. That is
# handled below instead, by comparing the file's signature before and after the
# read and abandoning the write if it moved.
if command -v flock >/dev/null 2>&1; then
    exec 9>"${CLAUDE_JSON}.fable-consent.lock" 2>/dev/null || exit 0
    flock -w 5 9 2>/dev/null || exit 0
fi

# The temp file MUST be a sibling of the target, not a bare `mktemp`. ~/.claude
# is a mounted volume while $TMPDIR is not, so a bare mktemp puts the temp file
# on a different filesystem and `mv` degrades from a rename into a copy over
# the destination — non-atomic, and a run interrupted mid-copy (or a full
# volume) would leave Claude Code reading a truncated settings file.
# That is strictly worse than never writing, and it would invalidate the
# atomicity the paragraph above relies on. Same directory keeps it a rename.
consent_tmp="$(mktemp "${CLAUDE_JSON}.XXXXXX")" || exit 0
trap 'rm -f "$consent_tmp"' EXIT

# Compare-and-swap on mtime+size. flock only orders seeders against each other;
# Claude Code takes no lock, so a live session rewriting .claude.json between
# the read below and the rename would be clobbered by this stale whole-file
# snapshot — losing OAuth or settings updates that have nothing to do with
# Fable. Re-stat immediately before the rename and abandon the write if the
# file moved. Abandoning is free: this runs before every launch, so the next
# one retries. Nanosecond mtime keeps same-second writes distinguishable.
stat_sig() { stat -c '%y %s' "$1" 2>/dev/null || echo unavailable; }
before_sig="$(stat_sig "$CLAUDE_JSON")"

if jq --arg k "$consent_key" \
    '.fableOverageConsentV2 = ((.fableOverageConsentV2 // {}) | .[$k] = true)' \
    "$CLAUDE_JSON" >"$consent_tmp"; then
    after_sig="$(stat_sig "$CLAUDE_JSON")"
    if [ "$before_sig" = "unavailable" ] || [ "$before_sig" != "$after_sig" ]; then
        rm -f "$consent_tmp"
        [ -n "$verbose" ] &&
            echo "==> Skipped Fable consent: $CLAUDE_JSON changed under us; will retry"
    else
        mv "$consent_tmp" "$CLAUDE_JSON"
        [ -n "$verbose" ] &&
            echo "==> Recorded Fable 5 usage-credit consent for the signed-in account"
    fi
else
    rm -f "$consent_tmp"
    echo "seed-fable-consent: could not update $CLAUDE_JSON; left unchanged" >&2
fi

exit 0
