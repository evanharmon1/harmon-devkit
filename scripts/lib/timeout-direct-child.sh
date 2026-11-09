#!/usr/bin/env bash
# timeout-direct-child.sh — a TEST DOUBLE for timeout(1), never used at runtime.
#
# Install it under the name `timeout` (or `gtimeout`) on a stub PATH to make a
# test independent of whichever coreutils the host ships. It reproduces the one
# behaviour that differs between implementations and that harmon-init#2014 hit:
# the hard KILL (`-k`, or `-s KILL`) reaches ONLY the direct child, as in
# uutils coreutils' `timeout` (Ubuntu 26.04's default). GNU coreutils signals
# the child's whole process group at every stage, so a descendant dies with it;
# here a descendant that outlasted the TERM is orphaned and keeps every file
# descriptor it inherited, which is exactly what holds a command substitution
# open. (uutils delivers the TERM to the group; this double is stricter and
# sends it to the direct child too, so the cases that use it give the
# descendant a TERM-ignoring stub, as the real failure did.)
#
# Supports the only forms the suite uses: `timeout [-k GRACE] [-s SIGNAL]
# SECONDS COMMAND [ARG...]` (whole seconds, as the callers pass them). Like the
# real tool it exits 124 when the deadline fired and the child then died, and
# otherwise returns the child's own status (137 after the hard kill).
grace=""
signal="TERM"
while :; do
    case "${1:-}" in
    -k)
        grace="${2:?timeout-direct-child: -k needs a duration}"
        shift 2
        ;;
    -s)
        signal="${2:?timeout-direct-child: -s needs a signal}"
        shift 2
        ;;
    *) break ;;
    esac
done
secs="${1:?timeout-direct-child: missing duration}"
shift

fired="${TMPDIR:-/tmp}/timeout-direct-child.$$"
"$@" &
child=$!
(
    sleep "${secs}"
    : >"${fired}"
    kill -"${signal}" "${child}" 2>/dev/null
    if [ -n "${grace}" ]; then
        sleep "${grace}"
        kill -KILL "${child}" 2>/dev/null
    fi
) >/dev/null 2>&1 &
watcher=$!

rc=0
wait "${child}" || rc=$?
kill "${watcher}" 2>/dev/null || true
if [ -e "${fired}" ]; then
    rm -f "${fired}"
    # 137 (SIGKILL) is reported as-is; a TERM-killed child is the plain deadline.
    [ "${rc}" -eq 137 ] || rc=124
fi
exit "${rc}"
