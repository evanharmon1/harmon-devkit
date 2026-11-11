#!/usr/bin/env bash
# tick-criteria.sh — allowlisted, implementation-authorised ticker for an
# open issue assigned to the authenticated account or referenced by the
# current branch's open PR. Closed ticks must use the distinct,
# non-allowlisted tick-completed-criteria.sh entry point.
set -euo pipefail

# The owner token comes out of the environment first, by builtins only, so no
# command this wrapper runs inherits it; it is handed on solely to the core
# (which isolates it the same way before running anything).
tick_env_token="${RUN_RECORD_OWNER_TOKEN:-}"
unset RUN_RECORD_OWNER_TOKEN

case "$0" in
*/*) script_dir="${0%/*}" ;;
*) script_dir="." ;;
esac
script_dir="$(CDPATH= cd -- "${script_dir:-/}" && pwd)"
if [ -n "$tick_env_token" ]; then
    RUN_RECORD_OWNER_TOKEN="$tick_env_token" exec "$script_dir/tick-criteria-core.sh" --mode open "$@"
fi
exec "$script_dir/tick-criteria-core.sh" --mode open "$@"
