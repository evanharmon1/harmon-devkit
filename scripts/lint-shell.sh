#!/usr/bin/env bash
# Check shell files with shellcheck + shfmt (the `lint:shell` gate).
#
# harmon-devkit keeps its own checker, shell-quality.sh, because it excludes
# deliberately incomplete snippets from the operational pass. This wrapper keeps
# the template's gate contract (the file name and the toolchain-registry check)
# without forking shell-quality.sh: it first verifies the shellcheck pin against
# the same registry per-session reconciliation uses, then delegates.
# Explicit arguments (the lefthook staged-files path) are forwarded as-is.
set -euo pipefail

here="$(dirname "${BASH_SOURCE[0]}")"

# The registry reads the same CI pin used by per-session reconciliation.
bash "$here/reconcile-toolchain.sh" --check shellcheck

exec "$here/shell-quality.sh" check --exclude-snippets "$@"
