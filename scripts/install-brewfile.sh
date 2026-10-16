#!/usr/bin/env bash
# Install this repo's Brewfile, or use a positively marked harmon toolchain.
set -euo pipefail

# Absolute path to THIS repo's Brewfile (never a user/global one).
root="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v brew >/dev/null 2>&1; then
    if [ -f "${HARMON_TOOLCHAIN_MANIFEST:-/usr/local/share/harmon-devcontainer/manifest.json}" ]; then
        echo "install: Homebrew not found — harmon toolchain manifest present; skipping Brewfile."
        exit 0
    fi
    echo "Homebrew not found — install Homebrew (run 'task bootstrap') and retry." >&2
    exit 1
fi

# HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK: don't cascade-upgrade unrelated
# already-installed brew dependents.
HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew bundle --file="${root}/Brewfile"
