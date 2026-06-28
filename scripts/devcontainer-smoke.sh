#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for devcontainer smoke tests." >&2
    exit 1
fi

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <devcontainer-config-path>" >&2
    exit 1
fi

CONFIG_PATH="$1"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel)"
USER_DATA_DIR="$(mktemp -d)"
SESSION_DATA_DIR="$(mktemp -d)"
LOG_FILE="$(mktemp)"
CONTAINER_ID=""

cleanup() {
    if [ -n "${CONTAINER_ID}" ]; then
        docker rm -f "${CONTAINER_ID}" >/dev/null 2>&1 || true
    fi
    rm -rf "${USER_DATA_DIR}" "${SESSION_DATA_DIR}" "${LOG_FILE}"
}
trap cleanup EXIT

echo "==> Running devcontainer smoke test for ${CONFIG_PATH}..."
npx -y @devcontainers/cli up \
    --workspace-folder "${WORKSPACE_ROOT}" \
    --config "${CONFIG_PATH}" \
    --remove-existing-container \
    --user-data-folder "${USER_DATA_DIR}" \
    --container-session-data-folder "${SESSION_DATA_DIR}" \
    --log-format json \
    --log-level info | tee "${LOG_FILE}"

CONTAINER_ID="$(jq -r 'select(.outcome=="success") | .containerId // empty' "${LOG_FILE}" | tail -n 1)"
if [ -z "${CONTAINER_ID}" ]; then
    echo "devcontainer smoke test failed: no successful container id found in CLI output." >&2
    exit 1
fi

# Derive the profile from the config's parent-dir basename: the dev profile
# lives in .devcontainer/dev/, everything else is the bot profile.
if [ "$(basename "$(dirname "${CONFIG_PATH}")")" = "dev" ]; then
    PROFILE="dev"
else
    PROFILE="bot"
fi

echo "==> Asserting ${PROFILE} permission invariants in the running container..."
bash "$(dirname "$0")/devcontainer-assert.sh" container "${CONFIG_PATH}" "${CONTAINER_ID}" "${PROFILE}"

echo "==> Smoke test passed for ${CONFIG_PATH}."
