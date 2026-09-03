#!/usr/bin/env bash
# scripts/dev-flow-exit.sh — thin wrapper around scripts/dev-flow-exit.mjs.
# See `node scripts/dev-flow-exit.mjs --help`-shaped usage in the script's
# own header, and ai/schemas/README.md for the run directory layout.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec node "${here}/dev-flow-exit.mjs" "$@"
