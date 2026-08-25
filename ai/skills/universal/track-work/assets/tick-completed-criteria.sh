#!/usr/bin/env bash
# tick-completed-criteria.sh — explicitly approved entry point for one verified
# post-merge criterion on a CLOSED/COMPLETED issue. This wrapper is intentionally
# not listed in the skill's allowed-tools, so it retains the normal write
# approval boundary before enabling tick-criteria.sh's closed-only mode.
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec env TICK_CRITERIA_CLOSED_ENTRYPOINT=1 \
    "$script_dir/tick-criteria.sh" --closed-ok "$@"
