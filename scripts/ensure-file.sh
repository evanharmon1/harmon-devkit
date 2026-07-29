#!/usr/bin/env bash
# ensure-file.sh — make sure `file(1)` is available for scripts/lint-hygiene.sh.
#
# lint-hygiene.sh uses `file --mime-encoding` to tell binaries from text and now
# fails closed when it is missing, so CI has to provision it rather than inherit
# it. GitHub-hosted images ship `file`; a self-hosted runner selected via
# `ci_runner=self-hosted` / `CI_RUNS_ON` may not, and `self-hosted` implies only
# the `linux` label — not a Debian/Ubuntu host. So probe for a package manager
# instead of assuming apt-get, and fail with an actionable message when none of
# them matches rather than dying on `apt-get: command not found`.
#
# Nothing here runs on a host that already has `file`, which is the overwhelming
# majority: it is a base-OS utility on every mainstream distro and on macOS.
set -euo pipefail

if command -v file >/dev/null 2>&1; then
    exit 0
fi

if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends file
elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y file
elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y file
elif command -v zypper >/dev/null 2>&1; then
    sudo zypper --non-interactive install file
elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm file
elif command -v apk >/dev/null 2>&1; then
    sudo apk add --no-cache file
else
    echo "ensure-file: 'file' is missing and no supported package manager was found." >&2
    echo "  scripts/lint-hygiene.sh requires it to distinguish binaries from text." >&2
    echo "  Preinstall it on this runner (it is a base-OS package on every" >&2
    echo "  mainstream distro) and re-run." >&2
    exit 1
fi

command -v file >/dev/null 2>&1 || {
    echo "ensure-file: install reported success but 'file' is still not on PATH" >&2
    exit 1
}
