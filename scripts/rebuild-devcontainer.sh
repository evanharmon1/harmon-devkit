#!/usr/bin/env bash
# Recreate one profile from the current checkout, then inspect its baked inputs.
set -euo pipefail

if [ -d /usr/local/share/devcontainer-config ] || [ -e /etc/harmon-devcontainer/image-inputs.sha256 ] ||
    [ "${CODER_WORKSPACE_AGENT_NAME:-}" = devcontainer ] || [ -n "${REMOTE_CONTAINERS:-}" ] ||
    [ -n "${FOREMAN_DEVCONTAINER:-}" ] || [ -n "${CODESPACES:-}" ] ||
    { [ "${CODER_WORKSPACE_AGENT_NAME:-}" != host ] && { [ -e /.dockerenv ] || [ -e /run/.containerenv ]; }; }; then
    echo 'Run devcontainer:rebuild on the host, not inside a container.' >&2
    exit 1
fi

case "${1:-dev}" in
dev) config=.devcontainer/dev/devcontainer.json ;;
bot) config=.devcontainer/devcontainer.json ;;
agent) config=.devcontainer/agent/devcontainer.json ;;
*)
    echo 'Usage: task devcontainer:rebuild -- [dev|bot|agent]' >&2
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
    echo 'Usage: task devcontainer:rebuild -- [dev|bot|agent]' >&2
    exit 2
fi
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
if ! command -v devcontainer >/dev/null 2>&1; then
    echo 'Install the devcontainer CLI on the host to rebuild.' >&2
    exit 1
fi
# The selected config supplies build.cacheFrom, including the GHCR image.
devcontainer up --workspace-folder "$root" --config "$root/$config" --remove-existing-container
devcontainer exec --workspace-folder "$root" --config "$root/$config" \
    env DEVCONTAINER_STALENESS_ALWAYS=1 bash .devcontainer/scripts/check-image-staleness.sh
