# shellcheck shell=bash
# BOT PROFILE ONLY. Make `agy` (Google Antigravity CLI) auto-approve every tool
# without prompting — the closest analog to Claude Code's bypassPermissions,
# because the container is the isolation boundary.
#
# Why a wrapper and not just settings.json: interactive agy honors the
# `toolPermission: always-proceed` policy that apply-antigravity-settings.sh
# writes, so an interactive bot session is already autonomous. Headless print
# mode (`agy -p …`) is the gap — agy ignores settings allow-rules there and
# AUTO-DENIES anything needing approval ("Settings allow-rules do not apply;
# re-run with --dangerously-skip-permissions to auto-approve all tools"). agy
# exposes no environment variable for this, so the flag on the command line is
# the only mechanism that covers headless. The wrapper injects it for agent
# runs. Programmatic launchers that never source a login shell must still pass
# --dangerously-skip-permissions themselves.
#
# Guarded on the bot marker so the human dev profile keeps its prompts. Sourced
# from shell-aliases.sh; safe to source in any shell (no-op unless bot).
if [ "${FOREMAN_DEVCONTAINER:-}" = "bot" ]; then
    agy() {
        # Pass subcommands and version/help queries straight through: appending
        # the flag to `agy update` / `agy --version` would be rejected or
        # meaningless. A bare `agy` (interactive) already honors always-proceed.
        case "${1:-}" in
        "" | agent | agents | changelog | help | install | models | plugin | plugins | update | -h | --help | --version)
            command agy "$@"
            return
            ;;
        esac
        # Do not duplicate the flag if the caller already supplied it.
        for arg in "$@"; do
            if [ "$arg" = "--dangerously-skip-permissions" ]; then
                command agy "$@"
                return
            fi
        done
        command agy --dangerously-skip-permissions "$@"
    }
fi
