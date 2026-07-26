#!/usr/bin/env bash
# install-copier.sh — ensure copier (the template engine) is installed, on the
# platforms where the Brewfile can't provide it.
#
# harmon-devkit hosts the standardize-repo skill, and its tooling tests render
# tiny local Copier templates to exercise the skill's guidance end to end
# (scripts/test-skills.sh, and the skill's own assets/diff-template.sh). So this
# repo needs copier even though a generated repo does not — harmon-init keeps it
# out of template/ for exactly that reason, which is why the install lives here
# rather than arriving from the template.
#
# On a Homebrew host copier comes from the Brewfile (`brew "copier"`), already on
# PATH via brew — nothing to do here. Only the brew-less case (this repo's
# devcontainer) needs uv to provide it; uv installs to ~/.local/bin, which the
# devcontainer image already puts on PATH.
#
# --force overwrites any foreign same-named entry point (e.g. a stale pipx shim)
# instead of aborting.
set -euo pipefail

if command -v brew >/dev/null 2>&1; then
    exit 0
fi

# Short-circuit when copier is already usable, so reruns need no network and
# work offline. A mere `--version` probe is not enough: the render-backed tests
# build templates carrying `_min_copier_version`, so a stale 8.x shim on PATH
# would pass the probe and still fail the tests later. Enforce the floor and
# fall through to the uv install (with --force) when it is unmet or unreadable.
#
# sort -V is safe here: this code only runs on the brew-less path, which is the
# Linux devcontainer. A macOS host takes the brew exit above.
COPIER_MIN=9.4.0

copier_meets_floor() {
    command -v copier >/dev/null 2>&1 || return 1
    local version
    version="$(copier --version 2>/dev/null |
        grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    [ -n "$version" ] || return 1
    [ "$(printf '%s\n%s\n' "$COPIER_MIN" "$version" | sort -V | head -1)" = "$COPIER_MIN" ]
}

if copier_meets_floor; then
    exit 0
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "install-copier: neither brew nor uv found — cannot install copier" >&2
    echo "  copier is required by the skills tooling tests" >&2
    exit 1
fi

uv tool install --force copier
