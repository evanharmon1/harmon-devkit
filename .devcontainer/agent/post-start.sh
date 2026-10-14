#!/usr/bin/env bash
set -euo pipefail

# Redirect all output to a log file to avoid SIGPIPE when VS Code
# disconnects the pipe before the script finishes. fd 3 keeps the original
# stderr, so the fail-closed lines below reach whoever started the container
# as well as the log.
POST_START_LOG=/tmp/devcontainer-post-start.log
exec 3>&2
exec &>"$POST_START_LOG"

# alert <line> — a line a human must see: to the log, then to the original
# stderr. That write runs in a subshell, so a pipe VS Code already closed
# cannot kill this script before it exits non-zero.
alert() {
    echo "$*" >&2
    (echo "$*" >&3) 2>/dev/null || true
}

# Every other failure — the profile's drift gate (agent-autonomy.sh verify)
# included — would otherwise exit non-zero with nothing on the original
# stderr. The egress path below reports its own failure and disarms this, so
# its lines are not repeated.
trap 'rc=$?; [ "$rc" -eq 0 ] || alert "post-start: failed (exit ${rc}) — do not use this container (details: ${POST_START_LOG})"' EXIT

# Egress FIRST, on every start: the filter lives in the container's network
# namespace, which a restart recreates empty. It applies from the root-owned
# snapshot post-create wrote, never from the writable checkout, so an edit to
# the checkout's lists or applier changes nothing here. The applier closes
# egress on any failure it reaches; the fallback below covers the ones it
# cannot — the snapshot missing or unreadable, or a failure before it runs as
# root — without relying on it, under the applier's own rule: for each
# address family the container has (IPv4 always, IPv6 when it has a global
# address), set OUTPUT/FORWARD to DROP and flush the filter chain if it
# exists, and say "left at DROP" only if every one of those steps succeeded.
# Either way the start fails, and a container whose start failed must not be
# used.
close_egress_family() {
    local ipt="$1" ok=0
    sudo -n "$ipt" -P OUTPUT DROP || ok=1
    sudo -n "$ipt" -P FORWARD DROP || ok=1
    if sudo -n "$ipt" -S HARMON_EGRESS >/dev/null 2>&1; then
        sudo -n "$ipt" -F HARMON_EGRESS || ok=1
    fi
    return "$ok"
}
if ! bash /usr/local/share/harmon-egress/scripts/egress-allowlist.sh apply; then
    closed=1
    close_egress_family iptables || closed=0
    # The applier's has_global_ipv6 test: the 4th field is the scope; 00 is global.
    if awk '$4 == "00" {found=1} END {exit found ? 0 : 1}' /proc/net/if_inet6 2>/dev/null; then
        close_egress_family ip6tables || closed=0
    else
        close_egress_family ip6tables 2>/dev/null || true
    fi
    if [ "$closed" -eq 1 ]; then
        alert "post-start: egress policy left at DROP"
    else
        alert "post-start: CRITICAL: could not close egress (no iptables, no root, or a DROP or flush step failed) — do not use this container"
    fi
    alert "post-start: egress filter not installed — failing the start; do not use this container (details: ${POST_START_LOG})"
    trap - EXIT
    exit 1
fi

# The gh-identity tripwire: the agent PAT is on the bot account, so the same
# '-bot' relationship holds. Warn-only, as in bot.
bash .devcontainer/scripts/check-bot-gh-identity.sh || true

# Same reason as the bot post-start: verify before the shared startup work,
# with NODE_OPTIONS cleared so a harness CLI it may touch is not broken by an
# inherited VS Code debug value.
unset NODE_OPTIONS
bash .devcontainer/agent/agent-autonomy.sh verify

bash .devcontainer/scripts/post-start-common.sh
