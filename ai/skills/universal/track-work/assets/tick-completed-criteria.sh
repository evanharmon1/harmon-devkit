#!/usr/bin/env bash
# tick-completed-criteria.sh — explicitly approved entry point for one verified
# post-merge criterion on a CLOSED/COMPLETED issue. This wrapper is intentionally
# not listed in the skill's allowed-tools, so it retains the normal write
# approval boundary before entering the closed-only core mode.
set -euo pipefail

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$script_dir/tick-criteria-core.sh" --mode closed "$@"
