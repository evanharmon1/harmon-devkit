#!/usr/bin/env bash
# install-brewfile.sh — install this repo's Brewfile deps, but no-op gracefully
# when Homebrew is absent.
#
# `task install` must work in two very different places: a Homebrew host (Evan's
# Mac), and this repo's OWN devcontainer, which bakes its toolchain into the
# image and ships no brew. Running `brew bundle` unconditionally hard-fails in
# the latter before `task install` can reach the uv-based copier step that the
# skills tooling tests need. So skip the Brewfile when brew is missing rather
# than aborting; on a brew host this behaves exactly like the previous inline
# `brew bundle` call.
#
# Mirrors harmon-init's root-only script of the same name. It is deliberately
# not templated there — see install-copier.sh for why this repo needs the pair.
set -euo pipefail

# Absolute path to THIS repo's Brewfile (never a user/global one).
root="$(cd "$(dirname "$0")/.." && pwd)"

if ! command -v brew >/dev/null 2>&1; then
    # Without brew this script cannot install anything, so it has to decide
    # whether that is expected — and fail closed when it is not. The only
    # sanctioned brew-less environment for this repo is its devcontainer, which
    # bakes the toolchain into the image. Detect that directly rather than
    # assuming it: on an ordinary host, exiting 0 here would report a successful
    # install over a machine that has none of the Brewfile tools.
    # Signal set mirrors scripts/status.sh (its devcontainer detection): the
    # runtime marker files cover Docker and Podman, and the env vars cover
    # Codespaces, VS Code Remote - Containers, and Coder/envbuilder workspaces,
    # which do not always expose a marker file.
    if [ ! -e /.dockerenv ] &&
        [ ! -e /run/.containerenv ] &&
        [ -z "${REMOTE_CONTAINERS:-}" ] &&
        [ -z "${REMOTE_CONTAINERS_IPC:-}" ] &&
        [ -z "${CODESPACES:-}" ] &&
        [ "${CODER:-}" != "true" ]; then
        echo "install: Homebrew not found on a non-container host." >&2
        echo "  run 'task bootstrap' to install Homebrew, then re-run 'task install'." >&2
        exit 1
    fi

    # Inside the container the image bakes the toolchain, so the Brewfile has
    # nothing left to add. This script deliberately does NOT try to enumerate
    # the gate binaries and verify them: that list spans everything the gates
    # transitively invoke (shellcheck, node, python3, rg, uv, …), cannot be
    # proven complete, and silently rots as gates change — a list that is
    # almost complete still reports success over a half-equipped machine.
    #
    # Dependency checking belongs with each consumer instead, where it can be
    # exact and the error names the real problem: lint-hygiene.sh preflights
    # `file`, test-skills.sh and diff-template.sh preflight `copier`.
    echo "install: Homebrew not found — brew-less container; skipping Brewfile."
    exit 0
fi

# HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK: don't cascade-upgrade unrelated
# already-installed brew dependents.
HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew bundle --file="${root}/Brewfile"
