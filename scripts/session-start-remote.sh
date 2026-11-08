#!/usr/bin/env bash
# Prepare web checkouts on startup and resume, including cached resumes.
# Local sessions and devcontainers use their own lifecycle.
[ "${CLAUDE_CODE_REMOTE:-}" = true ] || exit 0

if ! ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"; then
    echo "==> WARNING: SessionStart remote preparation: could not locate the checkout; run task setup:remote."
    exit 0
fi

# Do this synchronously, before detaching setup and before even looking up task:
# a child preparation process cannot change the agent's environment. Claude
# evaluates these exports before subsequent Bash commands, after shell startup.
# Only a bootstrap-owned environment supplies a managed toolchain. Decide
# persistence before emitting remedies: a saved export already fixes shadows.
if [ -f "${HARMON_PREFIX:-/usr/local}/share/harmon-remote-env/manifest.json" ]; then
    if session_env="$(bash "$ROOT/scripts/reconcile-toolchain.sh" --session-env 2>/dev/null)"; then
        if [ -n "$session_env" ]; then
            path_warning=""
            if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
                if printf '\n%s\n' "$session_env" >>"$CLAUDE_ENV_FILE"; then
                    echo "==> Managed PATH saved for agent commands: ${HARMON_BIN:-${HARMON_PREFIX:-/usr/local}/bin} first."
                else
                    path_warning="could not persist managed PATH in CLAUDE_ENV_FILE; managed PATH applies only to preparation."
                fi
            else
                path_warning="CLAUDE_ENV_FILE is unavailable; managed PATH applies only to preparation."
            fi
            if [ -n "$path_warning" ]; then
                # PATH is still the incoming one. Send only the helper's
                # diagnostics to stdout; discard its duplicate export.
                bash "$ROOT/scripts/reconcile-toolchain.sh" --session-env 2>&1 >/dev/null
                echo "==> WARNING: SessionStart remote preparation: ${path_warning} Put ${HARMON_BIN:-${HARMON_PREFIX:-/usr/local}/bin} first on PATH in agent shells."
            fi
            eval "$session_env"
        fi
    else
        echo "==> WARNING: SessionStart remote preparation: could not prepare managed PATH; run bash scripts/reconcile-toolchain.sh --status."
    fi
fi

# Only the disposable waiter uses timeout; preparation never receives its signals.
if ! command -v timeout >/dev/null 2>&1; then
    echo "==> WARNING: SessionStart remote preparation: preparation skipped because timeout is unavailable; run task setup:remote."
    exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "==> WARNING: SessionStart remote preparation: preparation skipped because python3 is unavailable; run task setup:remote."
    exit 0
fi
if ! state_dir="$(git -C "$ROOT" rev-parse --absolute-git-dir)"; then
    echo "==> WARNING: SessionStart remote preparation: could not locate the git directory; run task setup:remote."
    exit 0
fi

# Python's standard library supplies portable session detachment and advisory
# locks (including on macOS). A short launch lock serializes metadata publication;
# the worker holds a separate run lock until task exits. Neither lock is passed
# to task or its descendants, so an escaped child cannot retain it indefinitely.
if ! worker="$(
    python3 - "$ROOT" "$state_dir/session-start-remote" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root, state = sys.argv[1], Path(sys.argv[2])
state.mkdir(mode=0o700, exist_ok=True)
with (state / "launch.lock").open("a") as launch_lock:
    fcntl.flock(launch_lock, fcntl.LOCK_EX)
    with (state / "run.lock").open("a") as run_lock:
        try:
            fcntl.flock(run_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            # An active setup owns the run lock. Observe it; never launch a peer.
            info = json.loads((state / "active.json").read_text())
        else:
            directory = Path(tempfile.mkdtemp(prefix="run-", dir=state))
            info = {"directory": str(directory)}
            with (directory / "output.log").open("w") as log:
                pid = os.fork()
                if pid == 0:
                    # Close inherited hook pipes before starting any slow work.
                    os.setsid()
                    os.close(launch_lock.fileno())
                    with open(os.devnull) as null:
                        os.dup2(null.fileno(), 0)
                    os.dup2(log.fileno(), 1)
                    os.dup2(log.fileno(), 2)
                    rc = 1
                    try:
                        rc = subprocess.call(["task", "--dir", root, "setup:remote"],
                                             close_fds=True)
                    except Exception as error:
                        print(f"Could not run setup:remote: {error}", file=sys.stderr, flush=True)
                    finally:
                        (directory / "status.tmp").write_text(str(rc) + "\n")
                        (directory / "status.tmp").replace(directory / "status")
                    os._exit(0)
            info["pid"] = pid
            (state / "active.json").write_text(json.dumps(info))
        print(info["directory"])
        print(info["pid"])
PY
)"; then
    echo "==> WARNING: SessionStart remote preparation: could not start or observe preparation; run task setup:remote after checking for an existing setup."
    exit 0
fi

run_dir="${worker%$'\n'*}"
worker_pid="${worker##*$'\n'}"
output_file="$run_dir/output.log"
status_file="$run_dir/status"

# This process group contains only the waiter. The new-session worker has no
# hook stdin/stdout/stderr pipes and keeps running after the 90-second deadline.
timeout 90s bash -c 'while [ ! -f "$1" ]; do sleep 0.1; done' bash "$status_file" >/dev/null 2>&1 || true
if [ ! -f "$status_file" ]; then
    # Both new launches and observers re-check the lock after their wait. PIDs
    # can be reused, and a dead worker cannot write its completion status.
    if ! worker_state="$(
        python3 - "$state_dir/session-start-remote" "$run_dir" <<'PYLIVENESS'
import fcntl
import json
from pathlib import Path
import sys

state, directory = Path(sys.argv[1]), sys.argv[2]
with (state / "launch.lock").open("a") as launch_lock:
    fcntl.flock(launch_lock, fcntl.LOCK_EX)
    with (state / "run.lock").open("a") as run_lock:
        try:
            fcntl.flock(run_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            active = json.loads((state / "active.json").read_text())
            print("running" if active["directory"] == directory else "ended")
        else:
            print("ended")
PYLIVENESS
    )"; then
        echo "==> WARNING: SessionStart remote preparation: could not check setup:remote status (log: $output_file); inspect preparation before re-running task setup:remote."
        exit 0
    fi
    # Completion can race the liveness check; status is published before the
    # worker releases the lock, so re-read it before declaring a lost worker.
    if [ ! -f "$status_file" ]; then
        if [ "$worker_state" = running ]; then
            echo "==> WARNING: SessionStart remote preparation: setup:remote still running (PID $worker_pid; log: $output_file). Lefthook hooks, related repos and dependencies may not be ready; wait for $status_file before working or re-running task setup:remote."
        else
            echo "==> WARNING: SessionStart remote preparation: setup:remote ended without a status (log: $output_file); run task setup:remote again."
        fi
        exit 0
    fi
fi

cat "$output_file" >&2
if [ "$(cat "$status_file")" = 0 ]; then
    summary="setup:remote completed."
    while IFS= read -r line; do
        case "$line" in
        # The last status marker wins, including a final clean status that
        # supersedes a tool's earlier marker-shaped output.
        '==> setup:remote completed.'* | '==> setup:remote completed with warnings:'*) summary="${line#==> }" ;;
        esac
    done <"$output_file"
    echo "==> SessionStart remote preparation: ${summary}"
else
    # Re-probe without installing so failures still name drift and its remedy.
    drift="$(cd "$ROOT" && bash scripts/reconcile-toolchain.sh --status)" || drift="toolchain status unavailable"
    echo "==> WARNING: SessionStart remote preparation: setup:remote failed; run task setup:remote again.${drift:+ ${drift}}"
fi
# Preparation failures must never prevent a session from starting.
exit 0
