#!/usr/bin/env bash
set -euo pipefail

# Keep Semgrep on its PyPI/uv distribution. The Homebrew bottle has previously
# failed during TLS-store initialization on macOS, and uv gives local + CI the
# same explicitly pinned build.
# renovate: datasource=pypi depName=semgrep
SEMGREP_VERSION=1.170.0

# Semgrep defaults to the current directory when no target is provided. Do not
# append one here: callers can scope local scans with `task security:sast -- <path>`.
exec uvx --from "semgrep==${SEMGREP_VERSION}" semgrep scan \
    --config p/default \
    --metrics=off \
    --error \
    --severity ERROR \
    --exclude=.worktrees \
    "$@"
