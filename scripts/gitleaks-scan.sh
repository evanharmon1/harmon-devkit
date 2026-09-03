#!/usr/bin/env bash
# gitleaks-scan.sh — secret scan for `task security:secrets`, and (with
# --config) the scanner half of the dev-flow-v2 round-push broker's
# merge-base-extracted closure (specs/dev-flow-v2.md § Configuration "Gate
# authority separates policy from branch implementation").
#
# Two modes, picked off GITHUB_STEP_SUMMARY: interactively gitleaks just prints;
# in a job with a step summary it writes a JSON report that summarize-gitleaks
# renders into the run summary.
#
# The report path is a fresh mktemp, never a fixed /tmp/<project>-gitleaks.json:
# a constant scratch path is shared state, so two checkouts of the same repo
# scanning at once — parallel worktrees running `task security`, or two jobs on
# one self-hosted runner — would overwrite each other's report and summarize the
# wrong findings. Same class of race as issue #476.
#
# --config PATH overrides gitleaks' own auto-discovered .gitleaks.toml (which
# it otherwise looks up relative to --source, i.e. the scanned worktree). The
# round-push broker passes its merge-base-extracted config explicitly, so a
# branch cannot weaken the rules used to scan its own push by editing its
# worktree copy; `task security:secrets` itself never passes --config and
# keeps today's auto-discovery behavior unchanged.
#
# summarize-gitleaks.mjs is resolved relative to THIS script's own location,
# never cwd: the broker runs this script with cwd set to the feature worktree
# (so --source . scans the real content under review), and a cwd-relative
# `scripts/summarize-gitleaks.mjs` would then resolve to the worktree's own
# (branch-controlled) copy instead of the merge-base-extracted one beside this
# script.
set -euo pipefail

config_path=
if [ "${1:-}" = "--config" ]; then
    [ "$#" -ge 2 ] || {
        echo "gitleaks-scan: --config requires a path" >&2
        exit 2
    }
    config_path=$2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

config_args=()
[ -z "$config_path" ] || config_args=(--config "$config_path")

if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
    exec gitleaks detect --no-banner --redact --source . "${config_args[@]}"
fi

report="$(mktemp)"
trap 'rm -f "$report"' EXIT

rc=0
gitleaks detect --no-banner --redact --source . "${config_args[@]}" \
    --report-format json --report-path "$report" || rc=$?
node "${script_dir}/summarize-gitleaks.mjs" "$report"
exit "$rc"
