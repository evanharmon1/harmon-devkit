#!/usr/bin/env bash
set -euo pipefail

# renovate: datasource=npm depName=@devcontainers/cli
DEVCONTAINER_CLI_VERSION=0.88.0

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <devcontainer-config-path>" >&2
    exit 1
fi

CONFIG_PATH="$1"
WORKSPACE_ROOT="$(git rev-parse --show-toplevel)"

# Documented exclusion: this smoke test does not run from a linked worktree.
# Only the workspace folder is mounted, and in a linked worktree `.git` is a
# FILE pointing at $GIT_COMMON_DIR/worktrees/<name> OUTSIDE that folder — so
# every git command in post-create fails with "not a git repository". Mounting
# the common dir would change the container's contract for everyone to
# accommodate a host-side layout, so the test names the situation and the
# workaround instead of pretending to cover it. See docs/conventions.md
# § Worktrees.
#
# Checked FIRST, ahead of the toolchain and daemon probes below: the exclusion
# is deterministic from the checkout alone, and a missing Docker would otherwise
# mask it behind an error that sends the reader off installing Docker for a run
# that could never have passed here anyway.
if [ -f "${WORKSPACE_ROOT}/.git" ]; then
    cat >&2 <<EOF
${WORKSPACE_ROOT} is a linked git worktree, where this smoke test cannot pass:
its .git is a file pointing outside the mounted workspace, so post-create's git
commands see no repository.

Run it from the main checkout, or build and run the image directly:
  docker build -f .devcontainer/Dockerfile .
  docker run --rm <image> <command>
EOF
    exit 1
fi

if command -v devcontainer >/dev/null 2>&1; then
    DEVCONTAINER_CMD=(devcontainer)
else
    DEVCONTAINER_CMD=(npx --yes "@devcontainers/cli@${DEVCONTAINER_CLI_VERSION}")
fi

if command -v timeout >/dev/null 2>&1; then
    TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    TIMEOUT_BIN="gtimeout"
else
    echo "GNU timeout is required (install coreutils on macOS)." >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for devcontainer smoke tests." >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required for devcontainer smoke tests." >&2
    exit 1
fi

# Fail before the devcontainer CLI when the daemon is absent or wedged. The
# CLI can otherwise block indefinitely while probing Docker, which makes a
# fleet verification hang rather than produce an actionable failure.
if ! "$TIMEOUT_BIN" -k 5 20 docker info >/dev/null 2>&1; then
    echo "Docker daemon is unavailable or did not answer within 20 seconds." >&2
    exit 1
fi

USER_DATA_DIR="$(mktemp -d)"
SESSION_DATA_DIR="$(mktemp -d)"
LOG_FILE="$(mktemp)"
CONTAINER_ID=""

cleanup() {
    if [ -n "${CONTAINER_ID}" ]; then
        "$TIMEOUT_BIN" -k 5 20 docker rm -f "${CONTAINER_ID}" >/dev/null 2>&1 || true
    fi
    rm -rf "${USER_DATA_DIR}" "${SESSION_DATA_DIR}" "${LOG_FILE}"
}
trap cleanup EXIT

echo "==> Running devcontainer smoke test for ${CONFIG_PATH}..."
"$TIMEOUT_BIN" -k 30 1800 "${DEVCONTAINER_CMD[@]}" up \
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
