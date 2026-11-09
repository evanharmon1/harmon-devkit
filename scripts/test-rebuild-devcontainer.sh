#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat >"$tmp/bin/devcontainer" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
if [ "${FAIL_UP:-0}" = 1 ] && [ "$1" = up ]; then exit 9; fi
MOCK
chmod +x "$tmp/bin/devcontainer"
# Run the real entry point in a container too: override only the filesystem
# marker probes for the simulated host cases, leaving all other tests intact.
cat >"$tmp/host-env" <<'MOCK'
function [ {
    if builtin [ "$#" -eq 3 ]; then
        case "$1:$2" in
        -e:/.dockerenv|-e:/run/.containerenv|-e:/etc/harmon-devcontainer/image-inputs.sha256|-d:/usr/local/share/devcontainer-config)
            builtin [ "$2" = "${SIMULATED_MARKER:-}" ]
            return $?
            ;;
        esac
    fi
    builtin [ "$@"
}
MOCK
export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls"
: >"$CALLS"
if REMOTE_CONTAINERS=1 bash "$root/scripts/rebuild-devcontainer.sh" >/dev/null 2>&1; then
    echo 'inside-container invocation succeeded' >&2
    exit 1
fi
[ ! -s "$CALLS" ] || {
    echo 'container refusal invoked CLI' >&2
    exit 1
}
for marker in /.dockerenv /usr/local/share/devcontainer-config; do
    : >"$CALLS"
    if env -u CODER_WORKSPACE_AGENT_NAME -u SIMULATED_MARKER -u REMOTE_CONTAINERS -u FOREMAN_DEVCONTAINER -u CODESPACES BASH_ENV="$tmp/host-env" \
        CODER_WORKSPACE_AGENT_NAME=host SIMULATED_MARKER="$marker" \
        bash "$root/scripts/rebuild-devcontainer.sh" >/dev/null 2>&1; then
        [ "$marker" = /.dockerenv ] && [ "$(wc -l <"$CALLS")" -eq 2 ] || exit 1
    else
        [ "$marker" = /usr/local/share/devcontainer-config ] && [ ! -s "$CALLS" ] || exit 1
    fi
done
: >"$CALLS"
if env -u CODER_WORKSPACE_AGENT_NAME -u SIMULATED_MARKER -u REMOTE_CONTAINERS -u FOREMAN_DEVCONTAINER -u CODESPACES BASH_ENV="$tmp/host-env" \
    CODER_WORKSPACE_AGENT_NAME=devcontainer bash "$root/scripts/rebuild-devcontainer.sh" >/dev/null 2>&1; then
    echo 'devcontainer agent invocation succeeded' >&2
    exit 1
fi
[ ! -s "$CALLS" ] || exit 1
for profile in dev bot agent; do
    : >"$CALLS"
    env -u CODER_WORKSPACE_AGENT_NAME -u SIMULATED_MARKER -u REMOTE_CONTAINERS -u FOREMAN_DEVCONTAINER -u CODESPACES BASH_ENV="$tmp/host-env" \
        bash "$root/scripts/rebuild-devcontainer.sh" "$profile" >/dev/null
    case "$profile" in
    dev) config=.devcontainer/dev/devcontainer.json ;;
    bot) config=.devcontainer/devcontainer.json ;;
    agent) config=.devcontainer/agent/devcontainer.json ;;
    esac
    grep -Fx "up --workspace-folder $root --config $root/$config --remove-existing-container" "$CALLS" >/dev/null
    grep -Fx "exec --workspace-folder $root --config $root/$config env DEVCONTAINER_STALENESS_ALWAYS=1 bash .devcontainer/scripts/check-image-staleness.sh" "$CALLS" >/dev/null
    [ "$(wc -l <"$CALLS")" -eq 2 ]
done
: >"$CALLS"
if env -u CODER_WORKSPACE_AGENT_NAME -u SIMULATED_MARKER -u REMOTE_CONTAINERS -u FOREMAN_DEVCONTAINER -u CODESPACES BASH_ENV="$tmp/host-env" FAIL_UP=1 \
    bash "$root/scripts/rebuild-devcontainer.sh" dev >/dev/null 2>&1; then
    echo 'failed rebuild reported success' >&2
    exit 1
fi
[ "$(wc -l <"$CALLS")" -eq 1 ]
echo 'rebuild-devcontainer: all cases passed'
