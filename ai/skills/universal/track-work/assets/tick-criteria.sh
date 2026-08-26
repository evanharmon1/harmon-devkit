#!/usr/bin/env bash
# tick-criteria.sh — allowlisted, implementation-authorised ticker for an
# open issue assigned to the authenticated account. Closed ticks must use the
# distinct, non-allowlisted tick-completed-criteria.sh entry point.
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$script_dir/tick-criteria-core.sh" --mode open "$@"
