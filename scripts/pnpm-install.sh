#!/usr/bin/env bash
# Run CI dependency setup with one isolated retry for a malformed SQLite index.
set -uo pipefail
[ -f package.json ] || exit 0
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
log="$(mktemp "${RUNNER_TEMP}/pnpm-install.XXXXXX")" || exit 1
trap 'rm -f "$log"' EXIT
summary() { printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"; }
if pnpm install --frozen-lockfile 2>&1 | tee "$log"; then
    exit 0
else
    statuses=("${PIPESTATUS[@]}")
    status=${statuses[0]}
    if [ "${statuses[1]}" -ne 0 ]; then
        summary 'Dependency setup failed: could not capture the install log.'
        if [ "$status" -eq 0 ]; then status=${statuses[1]}; fi
        exit "$status"
    fi
fi
if ! grep -E '\[?(ERR_PNPM_)?ERR_SQLITE_ERROR\]?.*database disk image is malformed' "$log" >/dev/null; then
    summary '### Dependency setup failed

pnpm install failed before tests; see the setup log for diagnostics.'
    exit "$status"
fi
summary '### Dependency setup: malformed pnpm SQLite store index

The first install failed before tests. Retrying once with a fresh job-private store; see the setup log for the original diagnostic.'
fresh="$(mktemp -d "${RUNNER_TEMP}/pnpm-recovery.XXXXXX")" || {
    summary 'Dependency setup failed: could not create a fresh job-private store.'
    exit 1
}
export PNPM_CONFIG_STORE_DIR="$fresh"
export npm_config_store_dir="$fresh"
if pnpm install --frozen-lockfile; then
    if ! printf '%s=%s\n%s=%s\n' PNPM_CONFIG_STORE_DIR "$fresh" npm_config_store_dir "$fresh" >>"$GITHUB_ENV"; then
        summary 'Dependency setup failed: could not publish the recovered store to GITHUB_ENV.'
        exit 1
    fi
    summary 'Dependency setup recovered on the single retry.'
else
    status=$?
    summary 'Dependency setup failed on the single retry; tests did not start.'
    exit "$status"
fi
