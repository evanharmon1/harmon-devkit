#!/usr/bin/env bash
# codex-gate.sh — enable/disable/inspect the automatic Claude → Codex
# "stop-gate" review for THIS repo on THIS machine.
#
# The gate ships with the `codex@openai-codex` Claude Code plugin: a Stop hook
# that, when a Claude turn finishes, has Codex review the turn (read-only) and
# blocks Claude from stopping (BLOCK: <reason>) until material issues are
# addressed. The hook is always registered while the plugin is installed;
# whether it acts is a per-workspace `stopReviewGate` flag in the plugin's
# data dir. This script flips that same flag through the plugin's own
# companion runtime — identical state to running
# `/codex:setup --enable-review-gate` inside Claude Code — so the toggle is
# scriptable (task codex:gate:enable / codex:gate:disable / codex:gate:status).
#
# Usage: codex-gate.sh <enable|disable|status>
#
# Notes:
#   - The flag is per-user, per-machine, per-workspace path — never committed.
#     A git worktree is a different workspace path with its own flag.
#   - Upstream fails open ONLY when the codex binary/runtime is missing: the
#     hook then logs guidance and lets Claude stop. An installed-but-
#     unauthenticated codex instead makes the spawned review task fail, which
#     the hook converts into a BLOCK on every turn — so `enable` refuses to
#     arm the gate unless `codex login status` succeeds (disable/status stay
#     unguarded as the escape hatch if auth expires later).
#   - Claude Code caps consecutive stop-hook continuations, so an enabled gate
#     cannot loop forever; the AGENTS.md loop-cap policy still applies.
set -euo pipefail
cd "$(dirname "$0")/.."

ACTION="${1:-}"
case "$ACTION" in
enable | disable | status) ;;
*)
    echo "usage: $0 <enable|disable|status>" >&2
    exit 2
    ;;
esac

if ! command -v node >/dev/null 2>&1; then
    echo "node is required (the gate toggle drives the Claude Code codex plugin's Node runtime)." >&2
    exit 1
fi

# Toggling the gate is a human-only action in BOTH directions: disable lets a
# blocked agent disarm its reviewer; enable silently commits the human to
# billed every-turn reviews. Permission prefix rules cannot hold this line —
# `task --silent codex:gate:<action>` slips past exact-prefix ask rules while
# matching the broad Bash(task:*) allow — so enforce it here: agent/CI shells
# have no TTY on stdin, an interactive human terminal does. (The
# permissions.ask entries remain as a second layer. This is friction against
# silent toggling, not a cryptographic boundary: a policy-violating agent
# with file-write access could still edit scripts or state — which is why
# AGENTS.md forbids it and adjudication is the sanctioned way past a BLOCK.)
if [ "$ACTION" != "status" ] && [ ! -t 0 ]; then
    echo "Refusing to ${ACTION} the stop gate from a non-interactive shell: toggling the" >&2
    echo "gate is a human decision (agents must adjudicate or escalate a BLOCK, never" >&2
    echo "disarm — and arming commits the human to per-turn review costs). Run" >&2
    echo "'task codex:gate:${ACTION}' yourself in a terminal, or use /codex:setup inside" >&2
    echo "Claude Code." >&2
    exit 1
fi

claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
manifest="${claude_dir}/plugins/installed_plugins.json"

# Only accept an install that is actually active for THIS workspace: a
# user-scoped entry, or a project-scoped entry whose projectPath is this
# repo — entries[0] blindly could be another repo's project-scoped install
# (wrong version, and its Stop hook is not even active here).
plugin_root=""
if [ -f "$manifest" ]; then
    plugin_root="$(node -e '
const fs = require("fs");
const manifest = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const entries = (manifest.plugins || {})["codex@openai-codex"] || [];
const root = process.argv[2];
const pick = entries.find((e) => e.scope === "project" && e.projectPath === root)
  || entries.find((e) => e.scope === "user");
if (pick && pick.installPath) process.stdout.write(pick.installPath);
' "$manifest" "$(pwd)" 2>/dev/null || true)"
fi
# No cache-directory fallback on purpose: a cached runtime is NOT an active
# plugin — flipping state through another repo's project-scoped install would
# report the gate "enabled" while no Stop hook runs in this workspace.
if [ -z "$plugin_root" ] || [ ! -f "${plugin_root}/scripts/codex-companion.mjs" ]; then
    cat >&2 <<'EOF'
The codex Claude Code plugin is not installed for this user (or not active
for this workspace). Install it inside Claude Code:
  /plugin marketplace add openai/codex-plugin-cc
  /plugin install codex@openai-codex
(This repo's .claude/settings.json also offers it automatically when you
trust the folder in Claude Code.) See docs/guides/codex-review.md.
EOF
    exit 1
fi

# Write the SAME per-workspace state the Claude Code hook reads: outside
# Claude Code the companion falls back to a temp dir, so pin CLAUDE_PLUGIN_DATA
# to the plugin's real data dir (~/.claude/plugins/data/<plugin>-<marketplace>).
export CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-${claude_dir}/plugins/data/codex-openai-codex}"

# Arming the gate while codex cannot actually review would trap Claude in
# stop-blocks (see header) — refuse unless codex is present, authenticated,
# AND the plugin's own companion reports ready. Auth alone is not enough:
# `setup --json` can exit 0 with ready:false (e.g. the app-server cannot
# initialize its state runtime), and an armed gate would then BLOCK every
# turn while `codex login status` still passes.
if [ "$ACTION" = "enable" ] || [ "$ACTION" = "status" ]; then
    # Best-effort effective-enablement check (settings.local.json > project
    # settings.json > user settings.json; managed/enterprise layers are not
    # consulted). An installed-but-disabled plugin registers NO Stop hook, so
    # an armed flag would report protection that does not exist — refuse to
    # arm, and mark status output as inert.
    enabled="$(node -e '
const fs = require("fs");
const read = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return null; } };
for (const p of process.argv.slice(1)) {
  const v = read(p)?.enabledPlugins?.["codex@openai-codex"];
  if (v === true) { process.stdout.write("true"); process.exit(0); }
  if (v === false) { process.stdout.write("false"); process.exit(0); }
}
process.stdout.write("unknown");
' "$(pwd)/.claude/settings.local.json" "$(pwd)/.claude/settings.json" "${claude_dir}/settings.json" 2>/dev/null || echo unknown)"
    if [ "$enabled" = "false" ] && [ "$ACTION" = "enable" ]; then
        echo "Refusing to enable the stop gate: the codex plugin is explicitly disabled in" >&2
        echo "your Claude Code settings (enabledPlugins), so its Stop hook is not active —" >&2
        echo "the armed flag would report protection that does not exist. Re-enable the" >&2
        echo "plugin first (/plugin, or enabledPlugins in .claude/settings*.json)." >&2
        exit 1
    fi
    if [ "$enabled" = "false" ] && [ "$ACTION" = "status" ]; then
        echo "WARNING: the codex plugin is explicitly disabled in Claude Code settings" >&2
        echo "(enabledPlugins) — no Stop hook is active, so any enabled gate flag" >&2
        echo "reported below is INERT until the plugin is re-enabled." >&2
    fi
fi

# Auth + companion-readiness preflights gate ONLY `enable` — status and
# disable must stay usable as the inspection/escape hatch when auth or the
# runtime has gone bad after arming.
if [ "$ACTION" = "enable" ]; then
    if ! command -v codex >/dev/null 2>&1 || ! codex login status >/dev/null 2>&1; then
        echo "Refusing to enable the stop gate: codex is missing or not authenticated." >&2
        echo "The plugin fails open only when the codex BINARY is missing; an installed" >&2
        echo "but unauthenticated codex makes the Stop hook BLOCK every Claude turn." >&2
        echo "Run 'codex login' first. (codex-gate.sh disable/status work without auth.)" >&2
        exit 1
    fi
    ready="$(node "${plugin_root}/scripts/codex-companion.mjs" setup --json 2>/dev/null |
        node -e 'let s="";process.stdin.on("data",(d)=>{s+=d;}).on("end",()=>{let r=false;try{r=JSON.parse(s).ready===true;}catch{}process.stdout.write(r?"true":"false");});' || echo false)"
    if [ "$ready" != "true" ]; then
        echo "Refusing to enable the stop gate: the codex plugin companion reports it is" >&2
        echo "not ready (run 'task codex:gate:status' for details). An armed gate with an" >&2
        echo "unusable runtime would BLOCK every Claude turn instead of reviewing." >&2
        exit 1
    fi
fi

case "$ACTION" in
enable) exec node "${plugin_root}/scripts/codex-companion.mjs" setup --enable-review-gate ;;
disable) exec node "${plugin_root}/scripts/codex-companion.mjs" setup --disable-review-gate ;;
status) exec node "${plugin_root}/scripts/codex-companion.mjs" setup ;;
esac
