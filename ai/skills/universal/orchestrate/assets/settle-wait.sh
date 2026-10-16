#!/usr/bin/env bash
# Preserve orchestrate's public entry point; the shared implementation also
# serves integrate without a dependency on the orchestrate skill package.
set -eu

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$here/../../dev-flow-support/assets/settle-wait.sh" "$@"
