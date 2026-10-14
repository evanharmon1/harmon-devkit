#!/usr/bin/env bash
set -euo pipefail

# egress-allowlist.sh — default-deny egress for the AGENT devcontainer
# (docs/decisions/2026-09-29-agent-posture-three-posture-model.md, #286).
#
#   egress-allowlist.sh apply    — resolve the allowlist and install it as the
#                                  container's OUTPUT/FORWARD filter: allowed
#                                  destinations pass, everything else is
#                                  REJECTed and its address recorded. Runs as
#                                  root (re-execs through `sudo -n`). Exits
#                                  non-zero — failing the lifecycle step that
#                                  called it — if enforcement cannot be
#                                  installed, and then removes the filter's
#                                  allow rules and leaves the OUTPUT and
#                                  FORWARD policies DROP (fail_closed below).
#                                  Idempotent; re-run it to pick up
#                                  rotated CDN addresses. The agent lifecycle
#                                  runs it only from the snapshot below.
#   egress-allowlist.sh snapshot — validate the lists, then copy this applier
#                                  and both lists to a root-owned directory
#                                  (/usr/local/share/harmon-egress). Every
#                                  later apply runs from there, so an edit to
#                                  the writable checkout cannot widen egress
#                                  at the next start. Root.
#   egress-allowlist.sh establish — agent post-create's single egress step:
#                                  install iptables, snapshot, then apply FROM
#                                  the snapshot, with the same fail_closed
#                                  exit as apply around all three. Root.
#
# "Fails closed" means: once running as root, every exit of apply or
# establish short of a verified filter — a refused list, a failed iptables
# install, a failed rule, a failed verify, a signal — flushes the chain's
# allow rules, sets the OUTPUT and FORWARD policies to DROP for every address
# family the container has, and exits non-zero. It says egress was left at
# DROP only when every one of those steps succeeded; otherwise — no iptables
# at all, or any step failing — it prints a CRITICAL do-not-use line instead.
# Either way the create or start that ran it fails, and a container whose
# create or start failed must not be used.
#   egress-allowlist.sh verify   — fail unless the default-deny filter is in
#                                  place (root; re-execs through `sudo -n`).
#   egress-allowlist.sh blocked  — print every destination refused since the
#                                  container started, for the lane report. No
#                                  root needed.
#   egress-allowlist.sh plan     — print the resolved allow set without
#                                  touching the filter (used by the unit test).
#   egress-allowlist.sh hosts    — print the validated list entries.
#
# The lists: .devcontainer/egress-allowlist.txt (shared, owned by harmon-init)
# plus the optional per-repo .devcontainer/egress-allowlist.local.txt, read
# relative to this script — so the snapshot copy reads the snapshot's lists.
# Format is documented at the top of the shared list. A literal address may
# not be 0.0.0.0 in any form, nor a CIDR wider than /16: either would turn one
# list line into an allow-everything rule. The same refusal applies to every
# range fetched through @github-meta, which becomes a rule unreviewed: an
# over-broad one fails the plan (and so apply) rather than being skipped. IPv6
# literals are not accepted at all — v6 egress is closed outright (see apply).
#
# Scope, stated plainly: this is enforcement INSIDE the container's network
# namespace, which needs CAP_NET_ADMIN. It bounds what the agent harnesses
# reach — their permission layers deny the commands that would rewrite the
# filter (sudo, iptables, nft) — but it is not a boundary against root inside
# the container. DNS is allowed to the configured resolvers only, so DNS
# itself remains a narrow channel. Both residuals are recorded in the ADR.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_LIST="${EGRESS_ALLOWLIST_SHARED:-${SCRIPT_DIR}/../egress-allowlist.txt}"
LOCAL_LIST="${EGRESS_ALLOWLIST_LOCAL:-${SCRIPT_DIR}/../egress-allowlist.local.txt}"
RESOLV_CONF="${EGRESS_RESOLV_CONF:-/etc/resolv.conf}"
IF_INET6="${EGRESS_IF_INET6:-/proc/net/if_inet6}"
GITHUB_META_URL="https://api.github.com/meta"
CHAIN=HARMON_EGRESS
# xt_recent keeps the last 100 refused destination addresses in a
# world-readable /proc file, so `blocked` needs no daemon and no root.
RECENT_NAME=harmon_egress_blocked
RECENT_FILE="${EGRESS_RECENT_FILE:-/proc/net/xt_recent/${RECENT_NAME}}"
# The root-owned snapshot the agent lifecycle applies from. Its layout mirrors
# .devcontainer/ (scripts/egress-allowlist.sh beside the lists one level up),
# so the list paths above resolve inside it unchanged.
SNAPSHOT_DIR=/usr/local/share/harmon-egress
# The narrowest prefix a literal CIDR entry may have.
MIN_PREFIX=16

IPV4_RE='^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$'
HOST_RE='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'

fail() {
    echo "egress-allowlist: $*" >&2
    exit 1
}

warn() {
    echo "egress-allowlist: WARNING: $*" >&2
}

# as_root <subcommand> — re-exec this script through `sudo -n` unless already
# root. The environment is NOT carried across (no -E): the test-only overrides
# above never reach a root run.
as_root() {
    if [ "$(id -u)" -ne 0 ]; then
        exec sudo -n bash "${BASH_SOURCE[0]}" "$1"
    fi
}

# ipv4_in_range <ipv4-entry> — every octet of an IPV4_RE match is at most 255
# (the pattern bounds the digits, not the value) and has no leading zero
# (010 is 10 to bash's test but may be octal 8 to an inet_aton-style parser).
ipv4_in_range() {
    local octet
    local IFS=.
    for octet in ${1%%/*}; do
        case "$octet" in 0?*) return 1 ;; esac
        [ "$octet" -le 255 ] || return 1
    done
}

# overbroad <ipv4-entry> — print why the entry would allow far more than one
# service (the unspecified address in any form, or a CIDR wider than
# /MIN_PREFIX); print nothing when it is narrow enough to become a rule.
overbroad() {
    case "$1" in
    0.0.0.0 | 0.0.0.0/*)
        echo "is the unspecified address — refusing an entry that allows every destination"
        ;;
    */*)
        [ "${1#*/}" -ge "$MIN_PREFIX" ] ||
            echo "is wider than /${MIN_PREFIX} — refusing an over-broad CIDR"
        ;;
    esac
}

cmd_hosts() {
    local file line entry lineno reason count=0
    [ -f "$SHARED_LIST" ] || fail "shared allowlist not found at ${SHARED_LIST}"
    for file in "$SHARED_LIST" "$LOCAL_LIST"; do
        [ -f "$file" ] || continue
        lineno=0
        while IFS= read -r line || [ -n "$line" ]; do
            lineno=$((lineno + 1))
            entry="${line%%#*}"
            entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
            [ -n "$entry" ] || continue
            if [[ "$entry" =~ $IPV4_RE ]]; then
                ipv4_in_range "$entry" ||
                    fail "${file}:${lineno}: '${entry}' has an octet above 255 or with a leading zero — not an IPv4 address"
                reason="$(overbroad "$entry")"
                [ -z "$reason" ] || fail "${file}:${lineno}: '${entry}' ${reason}"
                printf '%s\n' "$entry"
                count=$((count + 1))
            elif [ "$entry" = "@github-meta" ] ||
                [[ "$entry" =~ $HOST_RE ]]; then
                printf '%s\n' "$entry"
                count=$((count + 1))
            else
                fail "${file}:${lineno}: '${entry}' is not a hostname, an IPv4 address/CIDR, or @github-meta"
            fi
        done <"$file"
    done
    [ "$count" -gt 0 ] || fail "the allowlist is empty — refusing to deny all egress"
}

resolve_host() {
    if [ -n "${EGRESS_RESOLVER:-}" ]; then
        "$EGRESS_RESOLVER" "$1"
        return
    fi
    getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

github_meta_ranges() {
    local meta
    if [ -n "${EGRESS_GITHUB_META_FILE:-}" ]; then
        meta="$(cat "$EGRESS_GITHUB_META_FILE")"
    else
        meta="$(curl -fsS --max-time 20 "$GITHUB_META_URL")" || return 1
    fi
    printf '%s' "$meta" |
        jq -r '[.git, .web, .api, .packages] | map(. // []) | add | .[] | select(test(":") | not)' |
        sort -u
}

# cmd_plan — the resolved allow set, one IPv4 address or CIDR per line. A host
# that does not resolve is warned about and skipped (a dead host must not stop
# the container); an empty result is fatal, and so is an over-broad range in
# the @github-meta response.
cmd_plan() {
    local entries entry addr resolved reason out=""
    # Explicit, not left to set -e: apply runs this inside $(...), where bash
    # does not inherit errexit, so a refused list line would otherwise leave
    # the entries before it standing as the plan.
    entries="$(cmd_hosts)" || exit 1
    while IFS= read -r entry; do
        if [ "$entry" = "@github-meta" ]; then
            resolved="$(github_meta_ranges)" || {
                warn "could not fetch ${GITHUB_META_URL}; GitHub is allowed by hostname only"
                continue
            }
        elif [[ "$entry" =~ $IPV4_RE ]]; then
            resolved="$entry"
        else
            resolved="$(resolve_host "$entry" || true)"
            [ -n "$resolved" ] || {
                warn "${entry} did not resolve; it stays blocked until the next apply"
                continue
            }
        fi
        while IFS= read -r addr; do
            [[ "$addr" =~ $IPV4_RE ]] && ipv4_in_range "$addr" || continue
            # A fetched meta range becomes a rule without review, so it is held
            # to the same over-broad refusal as a literal list line.
            if [ "$entry" = "@github-meta" ]; then
                reason="$(overbroad "$addr")"
                [ -z "$reason" ] || fail "@github-meta: '${addr}' (from ${GITHUB_META_URL}) ${reason}"
            fi
            out="${out}${addr}"$'\n'
        done <<<"$resolved"
    done <<<"$entries"
    [ -n "$out" ] || fail "no allowlist entry resolved — refusing to install a filter that allows nothing"
    printf '%s' "$out" | sort -u
}

resolvers() {
    awk '/^[[:space:]]*nameserver[[:space:]]/ {print $2}' "$RESOLV_CONF" 2>/dev/null |
        grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true
}

ensure_iptables() {
    command -v iptables >/dev/null 2>&1 && command -v ip6tables >/dev/null 2>&1 && return 0
    # The shared image ships iptables only through the Docker-in-Docker
    # feature, which the agent posture omits. Install it while egress is
    # still open (this runs before the filter exists). fail_closed is
    # already armed: if the install fails part-way with iptables present it
    # closes egress, and with no iptables it prints the CRITICAL line.
    echo "==> egress-allowlist: installing iptables..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq &&
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends iptables >/dev/null ||
        fail "iptables is not installed and could not be installed — egress enforcement is impossible"
}

has_global_ipv6() {
    # /proc/net/if_inet6: the 4th field is the scope; 00 is global.
    awk '$4 == "00" {found=1} END {exit found ? 0 : 1}' "$IF_INET6" 2>/dev/null
}

# close_family <iptables|ip6tables> — deny one address family's egress: set
# the OUTPUT and FORWARD policies DROP, then flush the chain's rules if the
# chain exists. The OUTPUT/FORWARD/DOCKER-USER jumps stay, so traffic reaches
# the empty chain, falls through it, and meets the DROP policy — a previous
# allowlist cannot outlive the failure. Every step is attempted; the status
# is non-zero if any of them failed.
close_family() {
    local ipt="$1" ok=0
    "$ipt" -P OUTPUT DROP || ok=1
    "$ipt" -P FORWARD DROP || ok=1
    if "$ipt" -S "$CHAIN" >/dev/null 2>&1; then
        "$ipt" -F "$CHAIN" || ok=1
    fi
    return "$ok"
}

# fail_closed — the EXIT trap of apply and establish. It is armed as soon as
# they run as root — before iptables is installed, before any list is read —
# and disarmed only once the filter is installed AND verified, so every other
# exit — a failed iptables install, a plan or snapshot refusal (an over-broad
# literal or @github-meta range, an invalid list, an empty resolved set), a
# failed iptables call, a failed verify, a signal — runs it.
#
# One invariant: it closes every address family the container has (IPv4
# always; IPv6 when has_global_ipv6, the same test apply and verify use), and it
# says "left at DROP" only if every step of that succeeded. Any other outcome
# — no iptables at all, or any step failing — prints the CRITICAL do-not-use
# line instead. IPv6 without a global address is closed best-effort, as apply
# treats it. Nothing here can abort before its message, and the exit status
# is never 0.
fail_closed() {
    local rc=$? closed=1
    trap - EXIT
    if ! command -v iptables >/dev/null 2>&1; then
        closed=0
        echo "egress-allowlist: iptables is not installed, so nothing can set the policy to DROP" >&2
    else
        close_family iptables || closed=0
        if has_global_ipv6; then
            close_family ip6tables || closed=0
        else
            close_family ip6tables 2>/dev/null || true
        fi
    fi
    if [ "$closed" -eq 1 ]; then
        echo "egress-allowlist: ${STEP} did not complete — egress policy left at DROP" >&2
    else
        echo "egress-allowlist: CRITICAL: could not close egress — ${STEP} did not complete and egress could not be confirmed closed; do not use this container" >&2
    fi
    [ "$rc" -ne 0 ] || rc=1
    exit "$rc"
}

# jump_first <iptables|ip6tables> <chain> — make the jump to the filter the
# first rule of <chain>, exactly once. Checking for the jump and inserting it
# only when absent would leave an existing jump wherever it already is — below
# any rule prepended since — and verify, which requires it first, would then
# fail. So every existing copy is deleted (duplicates too) and one inserted at
# the top. apply sets the OUTPUT and FORWARD policies to DROP before calling
# this, so the moment between the delete and the insert fails closed: traffic
# that meets no jump meets the DROP policy. DOCKER-USER is reached only from
# FORWARD, whose own jump is already first by the time DOCKER-USER is moved.
jump_first() {
    while "$1" -D "$2" -j "$CHAIN" 2>/dev/null; do :; done
    "$1" -I "$2" 1 -j "$CHAIN"
}

cmd_apply() {
    as_root apply
    STEP=apply
    trap fail_closed EXIT
    ensure_iptables
    # Resolve everything BEFORE touching the filter: resolution needs the
    # network the filter is about to close. A failure here still exits
    # through fail_closed, so it denies egress rather than leaving it open.
    local plan dns dest ns
    plan="$(cmd_plan)"
    dns="$(resolvers)"

    iptables -P OUTPUT DROP
    iptables -P FORWARD DROP
    iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"
    jump_first iptables OUTPUT
    jump_first iptables FORWARD
    # DOCKER-USER is the chain a Docker daemon never rewrites and always
    # consults first, so a per-repo Docker-in-Docker opt-in cannot route
    # nested containers around this filter.
    iptables -N DOCKER-USER 2>/dev/null || true
    jump_first iptables DOCKER-USER

    iptables -A "$CHAIN" -o lo -j ACCEPT
    iptables -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    while IFS= read -r ns; do
        [ -n "$ns" ] || continue
        iptables -A "$CHAIN" -d "$ns" -p udp --dport 53 -j ACCEPT
        iptables -A "$CHAIN" -d "$ns" -p tcp --dport 53 -j ACCEPT
    done <<<"$dns"
    while IFS= read -r dest; do
        [ -n "$dest" ] || continue
        iptables -A "$CHAIN" -d "$dest" -j ACCEPT
    done <<<"$plan"
    if ! iptables -A "$CHAIN" -m recent --name "$RECENT_NAME" --rdest --set 2>/dev/null; then
        warn "this kernel has no xt_recent match: refused destinations are still blocked but NOT recorded, so 'blocked' will report nothing"
    fi
    iptables -A "$CHAIN" -p tcp -j REJECT --reject-with tcp-reset
    iptables -A "$CHAIN" -j REJECT --reject-with icmp-admin-prohibited

    # IPv6: nothing on the list is reached over v6, so v6 egress is closed
    # outright except loopback and replies.
    if ip6tables -P OUTPUT DROP 2>/dev/null && ip6tables -P FORWARD DROP 2>/dev/null; then
        ip6tables -N "$CHAIN" 2>/dev/null || ip6tables -F "$CHAIN"
        jump_first ip6tables OUTPUT
        ip6tables -A "$CHAIN" -o lo -j ACCEPT
        ip6tables -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        ip6tables -A "$CHAIN" -j REJECT
    elif has_global_ipv6; then
        fail "the container has a global IPv6 address but ip6tables cannot filter it"
    else
        warn "ip6tables unavailable; the container has no global IPv6 address, so there is no v6 egress to filter"
    fi

    echo "==> egress-allowlist: default-deny egress installed ($(printf '%s\n' "$plan" | grep -c .) allowed destinations)."
    cmd_verify
    trap - EXIT
}

# first_rule <chain> — the first rule of an `iptables -S <chain>` listing on
# stdin (the -P/-N line is not a rule); empty when the chain has none.
first_rule() {
    grep -m 1 -- "^-A $1 " || true
}

cmd_verify() {
    as_root verify
    command -v iptables >/dev/null 2>&1 || fail "verify failed — iptables is not installed, so nothing enforces egress"
    local out last forward docker_user=""
    out="$(iptables -S OUTPUT)" || fail "verify failed — cannot read the OUTPUT chain"
    grep -qx -- '-P OUTPUT DROP' <<<"$out" || fail "verify failed — OUTPUT policy is not DROP"
    [ "$(first_rule OUTPUT <<<"$out")" = "-A OUTPUT -j ${CHAIN}" ] ||
        fail "verify failed — the first OUTPUT rule is not the ${CHAIN} jump"
    forward="$(iptables -S FORWARD)" || fail "verify failed — cannot read the FORWARD chain"
    grep -qx -- '-P FORWARD DROP' <<<"$forward" || fail "verify failed — FORWARD policy is not DROP"
    # DOCKER-USER, where it exists, must send everything to the filter first:
    # it is what keeps a Docker-in-Docker daemon's nested containers inside
    # it. apply inserts the jump at the top, and Docker never rewrites the
    # chain, so any other first rule is a filter someone has loosened.
    if docker_user="$(iptables -S DOCKER-USER 2>/dev/null)"; then
        [ "$(first_rule DOCKER-USER <<<"$docker_user")" = "-A DOCKER-USER -j ${CHAIN}" ] ||
            fail "verify failed — the first DOCKER-USER rule is not the ${CHAIN} jump, so nested containers can route around the filter"
    else
        docker_user=""
    fi
    # Forwarded traffic must reach the filter before any other rule: through
    # the FORWARD jump apply inserts first, or — once a Docker-in-Docker
    # daemon has started and put its own DOCKER-USER jump on top, as it does
    # on every start — through DOCKER-USER, whose first rule is checked above.
    case "$(first_rule FORWARD <<<"$forward")" in
    "-A FORWARD -j ${CHAIN}") ;;
    "-A FORWARD -j DOCKER-USER")
        [ -n "$docker_user" ] ||
            fail "verify failed — the first FORWARD rule jumps to DOCKER-USER, which cannot be read"
        ;;
    *) fail "verify failed — the first FORWARD rule is not the ${CHAIN} jump (nor a DOCKER-USER jump that reaches it)" ;;
    esac
    last="$(iptables -S "$CHAIN" | tail -n 1)"
    [ "$last" = "-A ${CHAIN} -j REJECT --reject-with icmp-admin-prohibited" ] ||
        fail "verify failed — ${CHAIN} does not end in its REJECT rule (last rule: ${last})"
    if has_global_ipv6; then
        ip6tables -S OUTPUT 2>/dev/null | grep -x -- '-P OUTPUT DROP' >/dev/null ||
            fail "verify failed — the container has global IPv6 but the ip6tables OUTPUT policy is not DROP"
    fi
    echo "==> egress-allowlist: verify passed."
}

# cmd_snapshot — copy this applier and both lists into the root-owned
# snapshot. The lists are validated first, so a list apply would refuse never
# replaces a good snapshot. EGRESS_SNAPSHOT_DIR (test-only; like the other
# overrides it never crosses the sudo re-exec) writes an unprivileged copy.
cmd_snapshot() {
    local dir="${EGRESS_SNAPSHOT_DIR:-}" path
    if [ -z "$dir" ]; then
        as_root snapshot
        dir="$SNAPSHOT_DIR"
        # Root ownership of the files is worthless if the container user can
        # rename the directory that holds them.
        # The snapshot directory itself (when it already exists) and every
        # ancestor, / included.
        path="$dir"
        [ -e "$path" ] || path="${path%/*}"
        while :; do
            [ -n "$path" ] || path=/
            [ -z "$(find "$path" -maxdepth 0 \( ! -user root -o -perm -002 -o -perm -020 \))" ] ||
                fail "${path} is not root-owned and closed to writes — refusing to snapshot under it"
            [ "$path" != / ] || break
            path="${path%/*}"
        done
    fi
    cmd_hosts >/dev/null
    install -d -m 0755 "$dir" "${dir}/scripts"
    install -m 0755 "${BASH_SOURCE[0]}" "${dir}/scripts/egress-allowlist.sh"
    install -m 0644 "$SHARED_LIST" "${dir}/egress-allowlist.txt"
    if [ -f "$LOCAL_LIST" ]; then
        install -m 0644 "$LOCAL_LIST" "${dir}/egress-allowlist.local.txt"
    else
        rm -f "${dir}/egress-allowlist.local.txt"
    fi
    echo "==> egress-allowlist: snapshot written to ${dir}."
}

# cmd_establish — snapshot, then apply the snapshot, as ONE fail-closed step:
# a list the snapshot refuses, or an applier that fails, leaves egress DROP
# rather than open. iptables is installed first so that DROP can be set even
# when the snapshot is what fails.
cmd_establish() {
    local dir="${EGRESS_SNAPSHOT_DIR:-$SNAPSHOT_DIR}"
    as_root establish
    STEP=establish
    trap fail_closed EXIT
    ensure_iptables
    cmd_snapshot
    bash "${dir}/scripts/egress-allowlist.sh" apply
    trap - EXIT
}

cmd_blocked() {
    if [ ! -r "$RECENT_FILE" ]; then
        echo "egress-allowlist: no blocked-destination record at ${RECENT_FILE} (filter not applied, or this kernel lacks xt_recent)"
        return 0
    fi
    local addr name
    sed -n 's/^src=\([0-9.]*\) .*/\1/p' "$RECENT_FILE" | sort -u | while IFS= read -r addr; do
        name="$(getent hosts "$addr" 2>/dev/null | awk '{print $2}' | head -n 1 || true)"
        printf 'blocked %s%s\n' "$addr" "${name:+ (${name})}"
    done
}

case "${1:-}" in
apply) cmd_apply ;;
verify) cmd_verify ;;
blocked) cmd_blocked ;;
snapshot) cmd_snapshot ;;
establish) cmd_establish ;;
plan) cmd_plan ;;
hosts) cmd_hosts ;;
*)
    echo "Usage: $0 <apply|verify|snapshot|establish|blocked|plan|hosts>" >&2
    exit 2
    ;;
esac
