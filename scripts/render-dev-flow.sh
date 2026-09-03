#!/usr/bin/env bash
# Thin wrapper so stage skills and Taskfile targets can call a stable path
# regardless of caller cwd; every real behavior lives in render-dev-flow.mjs.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "${script_dir}/render-dev-flow.mjs" "$@"
