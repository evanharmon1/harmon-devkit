#!/usr/bin/env bash
set -euo pipefail

# Support both env var names (TS_AUTHKEY used by this project, TS_AUTH_KEY used
# by the official Tailscale devcontainer feature).
TS_KEY="${TS_AUTHKEY:-${TS_AUTH_KEY:-}}"

# Two separate markers, because they answer two different questions.
#
# DEVCONTAINER_TAILSCALE=true means "this profile HAS a tailnet" — the dev
# profile sets it alongside the tailscale feature and --device=/dev/net/tun, and
# post-start-common.sh uses it to decide whether to invoke this script at all.
# It is NOT what makes a failure fatal: folding the two together would mean a
# profile that merely wants to connect opportunistically could not, because
# turning off fatality would also turn off the connection attempt.
#
# DEVCONTAINER_TAILSCALE_REQUIRED=true is what makes "no tailnet" a broken build
# rather than a skip. This script used to exit 0 on every failure path, so such
# a container started clean, reported success, and sat there logged out. It is
# gated on the `tailscale_required` copier answer (default no) because a fatal
# gate makes a profile unable to start without a Tailscale account and a live
# auth key — a dependency no generated repo may carry by default.
#
# Anywhere the second marker is absent — the bot profile, a default generated
# repo, a plain local devcontainer, CI — every path below stays a no-op exit 0,
# unchanged, and a present TS_AUTHKEY is still used to connect.
TS_REQUIRED="${DEVCONTAINER_TAILSCALE_REQUIRED:-}"

# Overridable so devcontainer-assert.sh can exercise the connect paths below
# against a stub socket, without root and without a real daemon. Nothing in a
# container ever sets it; the default is the only value that matters at runtime.
TS_SOCKET="${TS_SOCKET_PATH:-/var/run/tailscale/tailscaled.sock}"

# Narrow, deliberate escape hatch: build the tailnet-bearing profile in a place
# that has no tailnet and cannot get one. The only user is the smoke test
# (scripts/devcontainer-smoke.sh), which builds the dev profile with no key to
# prove the image and lifecycle scripts work — it is not testing connectivity.
#
# A separate knob rather than overriding DEVCONTAINER_TAILSCALE, so the profile
# marker keeps meaning "this profile has a tailnet" and stays assertable
# (devcontainer-assert.sh requires it on the dev config).
#
# It is meant to arrive via `devcontainer up --remote-env`, so opting out is an
# explicit act at the CALL SITE. Nothing in the runtime enforces that — a
# devcontainer.json could set it in containerEnv or remoteEnv and quietly
# disable this gate from inside the config the gate exists to guard — so
# devcontainer-assert.sh fails the build if either profile's config sets it.
#
# Only the exact string `true` demotes; anything else leaves the gate armed.
if [ "${DEVCONTAINER_TAILSCALE_OPTIONAL:-}" = "true" ]; then
    echo "DEVCONTAINER_TAILSCALE_OPTIONAL=true; tailnet failures are non-fatal for this build."
    TS_REQUIRED=""
fi

# bail <message>  → fatal when the tailnet is required, else a skip.
# Failure output goes to stderr AND names this script, because post-start.sh
# redirects everything to /tmp/devcontainer-post-start.log to avoid SIGPIPE —
# the nonzero exit is what surfaces in the build, and that log is where the
# reason lives.
bail() {
    if [ "${TS_REQUIRED}" = "true" ]; then
        echo "tailscale-connect.sh: FATAL: $1" >&2
        echo "tailscale-connect.sh: this profile requires the tailnet (DEVCONTAINER_TAILSCALE_REQUIRED=true)." >&2
        exit 1
    fi
    echo "$1 Skipping tailnet connect."
    exit 0
}

if ! command -v tailscale &>/dev/null; then
    bail "Tailscale CLI unavailable."
fi

if [ -z "${TS_KEY}" ]; then
    bail "TS_AUTHKEY (or TS_AUTH_KEY) missing."
fi

# Ensure tailscaled daemon is running. The devcontainer feature's entrypoint
# starts it, but it can crash in Codespaces when /dev/net/tun is unavailable
# (runArgs like --device=/dev/net/tun are ignored in Codespaces).
if ! pgrep -x tailscaled &>/dev/null; then
    echo "tailscaled not running; starting it..."
    if [ ! -c /dev/net/tun ]; then
        echo "No /dev/net/tun device; using userspace networking."
        sudo bash -c 'tailscaled --state=/var/lib/tailscale/tailscaled.state --tun=userspace-networking &>/var/log/tailscaled.log &'
    else
        sudo bash -c 'tailscaled --state=/var/lib/tailscale/tailscaled.state &>/var/log/tailscaled.log &'
    fi
fi

# Wait for the daemon to ANSWER, and do it regardless of who started it.
#
# This wait used to live inside the branch above, so it ran only when THIS
# script started tailscaled. But `pgrep` succeeding proves only that the
# process exists: the tailscale feature's entrypoint spawns tailscaled and
# returns before it is listening, so a container under load reaches here with a
# live PID and no socket, and the `tailscale status` / `tailscale up` calls
# below race it. That used to cost a swallowed error message; now that a failed
# connect is fatal it would cost a failed build on nothing but timing.
#
# Answering, not merely existing, because the socket path alone proves nothing.
# `[ -S ... ]` proves an inode is there, which is not the same thing: a unix
# socket file outlives the process that bound it, so a tailscaled that crashed
# or was killed uncleanly leaves one behind. The replacement daemon then unlinks
# and re-binds it, and a bare `-S` check passes instantly against the STALE
# inode — so `status` and `up` race a daemon that is still starting. That was
# survivable while failures were swallowed; now it would fail the build on a
# daemon that was about to recover.
#
# So require both: the socket, and a status response that actually parses as
# tailscale's JSON. Exit status is deliberately not the test — `tailscale
# status` reports a logged-out backend through its output rather than
# consistently through its exit code, and this loop must not depend on which.
# Empty output is what a dead or still-starting daemon gives.
# The bound is a WALL-CLOCK DEADLINE, not an iteration count. Counting
# iterations only bounds the wait when every iteration is instant: a probe that
# is itself allowed seconds turns "100 tries" into minutes, so the deadline in
# the failure message stops being true exactly when it matters — against the
# slow or wedged daemon the deadline exists for.
#
# Each probe is hard-bounded too, with `-k`. Plain `timeout N` sends SIGTERM and
# then waits for the child, so a status call that ignores TERM would hang inside
# an otherwise-bounded loop. Worst case is therefore the deadline plus one
# probe's own budget, not an unbounded stall.
TS_STATUS_JSON=""
TS_READY_DEADLINE=$((SECONDS + 10))
while [ "${SECONDS}" -lt "${TS_READY_DEADLINE}" ]; do
    if [ -S "${TS_SOCKET}" ]; then
        TS_STATUS_JSON="$(sudo timeout -k 1 2 tailscale status --json 2>/dev/null || true)"
        case "${TS_STATUS_JSON}" in
        *'"BackendState"'*) break ;;
        esac
        TS_STATUS_JSON=""
    fi
    sleep 0.1
done
if [ -z "${TS_STATUS_JSON}" ]; then
    tail -5 /var/log/tailscaled.log 2>/dev/null || true
    bail "tailscaled is not answering on ${TS_SOCKET} after 10s; see /var/log/tailscaled.log."
fi

# Ask the backend whether it is actually up, not whether it remembers an
# address. `tailscale ip -4` answers from local state, which outlives the node
# it describes: these nodes are ephemeral, so the control plane reaps them once
# they have been offline a while, and the persisted /var/lib/tailscale volume
# then still holds an address for a node that no longer exists. Treating that as
# "connected" is the same report-success-while-logged-out failure this whole
# script was hardened against. BackendState is what `tailscale status` shows as
# `Logged out` / `NeedsLogin`, i.e. the thing to check. grep-style matching
# rather than jq: this script must not gain a dependency the tailscale feature
# does not already provide.
#
# BackendState only, deliberately — NOT `Self.Online`. The two differ when the
# backend is healthy locally but the control plane is unreachable: Running with
# Online false. Gating on Online would turn a Tailscale outage into a failed
# dev build, where today the container starts and reconnects on its own when
# the control plane returns.
#
# Matched, never piped into `grep -q`. That reads as equivalent and is not: grep
# exits at the first match and closes the pipe, tailscale dies of SIGPIPE, and
# the `set -o pipefail` at the top of this script turns the whole condition
# false. On a tailnet large enough for the JSON to exceed the pipe buffer that
# reports "not connected" for a perfectly healthy node and re-runs `tailscale
# up` against it.
#
# TS_STATUS_JSON is the response the readiness loop above already proved parses,
# so this re-uses it rather than asking a second time — one fewer call, and no
# window in which the two answers could disagree.
TS_RUNNING_RE='"BackendState"[[:space:]]*:[[:space:]]*"Running"'
if [[ "${TS_STATUS_JSON}" =~ $TS_RUNNING_RE ]]; then
    echo "Tailscale already connected."
    exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -n "${REPO_ROOT}" ]; then
    REPO_NAME=$(basename "${REPO_ROOT}")
elif [ -n "${GITHUB_REPOSITORY:-}" ]; then
    REPO_NAME=$(basename "${GITHUB_REPOSITORY}")
else
    REPO_NAME="devcontainer"
fi

SHORT_ID=$(hostname | cut -c1-8)
if [ -n "${CODESPACE_NAME:-}" ]; then
    TS_HOSTNAME="gh-${REPO_NAME}-${SHORT_ID}"
elif [ "${CODER:-}" = "true" ]; then
    TS_HOSTNAME="cr-${REPO_NAME}-${SHORT_ID}"
else
    TS_HOSTNAME="dc-${REPO_NAME}-${SHORT_ID}"
fi

# Bounded on purpose. `tailscale up` waits for the backend to reach Running and
# has no inherent deadline — if the control plane or DNS is unreachable it
# blocks indefinitely. That was survivable while a failure here was swallowed,
# but this path now decides whether the build fails: a hang means
# postStartCommand never returns, so the workspace hangs instead of reporting
# the problem, which is the same "no signal" outcome in a different costume.
#
# An external `timeout` rather than `tailscale up --timeout` so this does not
# depend on that flag existing in whichever version the devcontainer feature
# installs; guessing wrong there would turn every dev build into an
# unknown-flag failure. `timeout` is coreutils, as available as the `pgrep` and
# `sudo` this script already assumes.
#
# `-k 10` is the hard bound. Plain `timeout 90` sends SIGTERM and then
# WAITS for the child, so a wedged `tailscale up` that ignores TERM keeps
# the lifecycle hanging past the deadline that was supposed to end it.
# devcontainer-smoke.sh already uses `-k` for the same reason.
if TS_CONNECT_OUTPUT="$(
    sudo timeout -k 10 90 tailscale up \
        --ssh \
        --hostname="${TS_HOSTNAME}" \
        --authkey="${TS_KEY}" \
        --accept-routes 2>&1
)"; then
    echo "Connected to tailnet as ${TS_HOSTNAME}."
else
    # Where an expired, already-consumed (non-reusable), or wrong-kind key
    # lands. Print tailscale's own diagnosis before bailing — it is the only
    # thing that distinguishes those cases.
    printf '%s\n' "${TS_CONNECT_OUTPUT}" >&2
    bail "tailscale up failed."
fi
