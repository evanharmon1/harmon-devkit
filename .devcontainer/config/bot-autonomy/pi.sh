#!/usr/bin/env bash
set -euo pipefail

# bot-autonomy module: pi (@earendil-works/pi-coding-agent). Dispatched by
# .devcontainer/scripts/bot-autonomy.sh, bot profile only. NOT Copier-gated:
# pi is a broker-style, model-agnostic harness with no account or paid tier
# of its own for AGENTS.md's Hard Rule to apply to.
#
# THIS MODULE'S apply IS A NO-OP BY DESIGN, and that is a decision, not an
# omission — maintainer decision 2026-09-03, option (a). Read this before
# "fixing" it:
#
#   pi's only prompt-avoidance knob is project TRUST, and pi's own docs
#   state that non-interactive modes (-p, --mode json, --mode rpc) never
#   show a trust prompt at all, whatever the setting. So the bot profile
#   already reaches the no-prompt state #1137 requires with pi left exactly
#   as it ships. What trust actually controls in non-interactive mode is
#   whether pi LOADS project-local resources — and, per pi's own docs,
#   "install missing project packages, and execute project extensions", i.e.
#   automatic code execution, not configuration.
#
#   Two designs for granting that trust were adjudicated and REJECTED during
#   this capability's own review:
#     1. defaultProjectTrust: "always" in ~/.pi/agent/settings.json — it is
#        the GLOBAL fallback, so it extends automatic extension-code
#        execution to every repository this pi installation is ever pointed
#        at, not only this one.
#     2. A workspace-keyed entry in ~/.pi/agent/trust.json — pi resolves
#        trust by canonical DIRECTORY PATH, not by content or commit, and
#        applies "the closest saved decision on the current or parent path".
#        A path-keyed grant therefore survives an untrusted branch checked
#        out into that same path, and extends to anything cloned or checked
#        out underneath it.
#   pi's trust primitive has no content-authentication mechanism (no commit
#   pinning, no hash verification) to build a safer version on. The accepted
#   cost is a capability gap: the bot's headless pi sessions silently ignore
#   this repository's own .pi/ resources. Do not reopen either design here;
#   option (2) is on record as a possible FUTURE, EXPLICIT OPT-IN only.
#
# verify still fails closed on BOTH of pi's trust-granting surfaces,
# regardless of cause — this module writes neither, but a stale volume, a
# manual edit, an interactive /trust run inside the bot container, or a
# future regression could populate either one. The trust.json check is
# deliberately NOT scoped to path-applicability: ~/.pi is one persistent
# volume for the bot container's whole lifetime, so a decision that does not
# apply to today's workspace is still live on disk and becomes applicable
# the instant pi is invoked against a matching path, with no guarantee a
# fresh verify runs first.
#
# trust.json's format, confirmed against the installed pi 0.84.4 binary (its
# own ProjectTrustStore/readTrustFile/findNearestTrustEntry): a flat JSON
# object mapping a canonical absolute directory path to `true` (trusted),
# `false` (explicitly distrusted) or `null`. Only `true` grants anything —
# `false` and `null` are safe, so failing on "an entry exists at all" would
# wrongly reject an explicitly-distrusted volume.
#
# See https://github.com/evanharmon1/harmon-init/blob/main/openspec/changes/archive/2026-09-05-bot-autonomy-new-harnesses/design.md - Decisions
# ("Resolved 2026-09-03").

PI_AGENT_DIR="${BOT_AUTONOMY_PI_AGENT_DIR:-$HOME/.pi/agent}"
PI_SETTINGS="${PI_AGENT_DIR}/settings.json"
PI_TRUST="${PI_AGENT_DIR}/trust.json"

cmd_apply() {
    # Intentionally writes nothing. See the header.
    echo "==> pi: no elevated trust applied (maintainer decision 2026-09-03; pi's own out-of-the-box posture in both profiles)"
}

verify_default_trust() {
    [ -f "$PI_SETTINGS" ] || return 0
    local value
    value="$(jq -r '.defaultProjectTrust // empty' "$PI_SETTINGS" 2>/dev/null)" || {
        echo "pi: verify failed — could not read ${PI_SETTINGS}" >&2
        exit 1
    }
    [ "$value" != "always" ] || {
        echo "pi: verify failed — ${PI_SETTINGS} sets defaultProjectTrust to 'always', which grants automatic project trust (and automatic project-extension code execution) to every repository this pi installation is ever pointed at; this module never writes it, so something else did" >&2
        exit 1
    }
}

verify_no_trusted_decision() {
    [ -f "$PI_TRUST" ] || return 0
    # A trust store pi itself refuses to read (not JSON, not an object) is
    # not evidence of safety — fail closed rather than reporting "no trusted
    # decisions found" over a file nothing could parse.
    jq -e 'type == "object"' "$PI_TRUST" >/dev/null 2>&1 || {
        echo "pi: verify failed — ${PI_TRUST} is not readable as a JSON object; pi's own trust store reader rejects it too, so its contents cannot be cleared as safe" >&2
        exit 1
    }
    local trusted
    # `true` is the only value that grants trust; `false`/`null` are safe.
    # Not scoped to the current workspace on purpose — see the header.
    trusted="$(jq -r '[to_entries[] | select(.value == true) | .key] | join(", ")' "$PI_TRUST")" || {
        echo "pi: verify failed — could not evaluate ${PI_TRUST}" >&2
        exit 1
    }
    [ -z "$trusted" ] || {
        echo "pi: verify failed — ${PI_TRUST} carries a trusted saved decision for: ${trusted}. pi applies the closest saved decision on the current or parent path, and this volume persists for the container's whole lifetime, so a decision that does not apply to the current workspace still becomes applicable the moment pi is invoked against a matching path" >&2
        exit 1
    }
}

cmd_verify() {
    command -v jq >/dev/null 2>&1 || {
        echo "pi: jq not found" >&2
        exit 1
    }
    verify_default_trust
    verify_no_trusted_decision
}

case "${1:-}" in
apply) cmd_apply ;;
verify) cmd_verify ;;
executable) echo "pi" ;;
*)
    # No `restore`: this module never overwrites anything, so it has nothing
    # captured to put back.
    echo "Usage: $0 <apply|verify|executable>" >&2
    exit 2
    ;;
esac
