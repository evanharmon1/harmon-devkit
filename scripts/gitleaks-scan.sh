#!/usr/bin/env bash
# gitleaks-scan.sh — secret scan for `task security:secrets`.
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
set -euo pipefail

if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
    exec gitleaks detect --no-banner --redact --source .
fi

report="$(mktemp)"
trap 'rm -f "$report"' EXIT

rc=0
gitleaks detect --no-banner --redact --source . \
    --report-format json --report-path "$report" || rc=$?
node scripts/summarize-gitleaks.mjs "$report"
exit "$rc"
