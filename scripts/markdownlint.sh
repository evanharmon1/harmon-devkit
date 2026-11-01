#!/usr/bin/env bash
# markdownlint.sh — resolve markdownlint-cli2 and run it in check or fix mode.
#
# Prefer the repo-pinned binary (node_modules/.bin) so hooks/CI match the
# lockfile; then a PATH-installed binary already AT the pin, which is what a
# provisioned machine (the devcontainer image, a remote VM the bootstrap set up)
# has; fall back to npx for non-node repos and fresh scaffolds. Invoking
# the .bin shim directly is package-manager-agnostic (works under npm too,
# where `pnpm exec` would break). Keeps this dispatch out of the
# Taskfile per the "keep cmds trivial; non-trivial shell lives in scripts/*.sh"
# rule.
#
# Usage:
#   markdownlint.sh check [glob-or-file ...]   # read-only gate
#   markdownlint.sh fix   [glob-or-file ...]   # best-effort auto-fix
# With no glob/file args, a canonical repo-wide default set is used.
set -euo pipefail

mode="${1:-check}"
if [ "$#" -gt 0 ]; then shift; fi

# Canonical excludes: generated output (dist, .task, .terraform, .venv,
# node_modules), vendored agent assets (.claude/skills, .agents/skills, _bmad),
# scratch worktrees, spec fixtures, and the template/ tree (jinja markdown —
# present only in the template repo itself, an inert glob everywhere else).
default_globs=(
    '**/*.md'
    '#.git/**'
    '#template/**'
    '#.claude/**'
    '#.agents/skills/**'
    '#_bmad/**'
    '#specs/*/**'
    '#**/node_modules/**'
    '#dist/**'
    '#.worktrees/**'
    '#**/.terraform/**'
    '#**/.venv/**'
    '#**/.task/**'
    '#.foreman/**'
    '#.lane/**'
    '#**/.lane-report.md'
)

# renovate: datasource=npm depName=markdownlint-cli2
MARKDOWNLINT_VERSION=0.24.0

# Prefer a repo-local install; then a PATH binary at the pin; otherwise fetch a
# PINNED version. Resolving `latest` here meant a new upstream rule could turn
# every repo red with no commit — the opposite of what a lint gate is for.
#
# The PATH step is there because `npx` never looks at PATH: it resolves a local
# or remote npm package. A machine the devcontainer image or the remote
# bootstrap provisioned already carries markdownlint-cli2 at this pin, and
# without this step `task check` re-downloaded it — so a job claiming to run
# with only what its setup installed did not, and an environment whose egress
# closes after setup could not run the gate at all.
#
# The version must MATCH the pin, and that is a safety condition rather than a
# nicety: preferring any PATH binary would silently downgrade every machine
# carrying an older global copy, which is the `latest` problem above in reverse.
# A failed probe, a mismatch, an unreadable banner, or a banner in an
# unrecognised shape all fall through to npx, so the pin decides what runs in
# every case.
#
# THE RULE: a read that can fail is not an answer. The probe's exit STATUS is
# taken first, and separately from parsing what it printed, because "it could
# not say" and "it said the wrong version" are different facts and only the
# second is about the pin. Discarding the status with `|| true` accepted a binary
# that printed the pinned banner and exited nonzero — a damaged global install, a
# broken wrapper, a Node runtime that has moved out from under it — as the pinned
# linter, and `task check` then ran that broken executable in place of the npx
# package that works.
#
# images/devcontainer/install/lib.sh states the same rule for the image's own
# version probes (harmon_installed_version), and the duplication is DELIBERATE
# rather than an oversight: this dispatcher cannot source that helper. It is
# root-only — part of harmon-init's image build, with no template twin — so it
# does not exist in a generated repository at all, and where it does exist it is
# a file the image or the remote bootstrap installed, so sourcing it would make
# resolving the linter depend on a provisioned machine. That is the one thing
# this script must not assume: it also runs on fresh scaffolds and unprovisioned
# CI. A change to the rule belongs in both places.
markdownlint_path_bin=""
if markdownlint_path_bin="$(command -v markdownlint-cli2 2>/dev/null)"; then
    # The banner's first line is `markdownlint-cli2 v<version> (markdownlint …)`.
    # Read with shell builtins alone, so resolving the linter needs nothing on
    # PATH but the linter.
    if markdownlint_banner="$("$markdownlint_path_bin" --version 2>/dev/null)"; then
        case "${markdownlint_banner%%$'\n'*}" in
        "markdownlint-cli2 v${MARKDOWNLINT_VERSION}" | "markdownlint-cli2 v${MARKDOWNLINT_VERSION} "*) ;;
        *) markdownlint_path_bin="" ;;
        esac
    else
        markdownlint_path_bin=""
    fi
fi

if [ -x node_modules/.bin/markdownlint-cli2 ]; then
    run=(node_modules/.bin/markdownlint-cli2)
elif [ -n "$markdownlint_path_bin" ]; then
    run=("$markdownlint_path_bin")
elif [ "$mode" = "offline" ]; then
    # Use only an already-cached copy of the pinned package, never the network.
    run=(npx --offline --yes "markdownlint-cli2@${MARKDOWNLINT_VERSION}")
else
    run=(npx --yes "markdownlint-cli2@${MARKDOWNLINT_VERSION}")
fi

if [ "$#" -eq 0 ]; then
    set -- "${default_globs[@]}"
fi

case "$mode" in
check | offline)
    "${run[@]}" "$@"
    ;;
fix)
    # Best-effort: --fix must not abort `task format` on un-auto-fixable rule
    # violations (e.g. MD024 duplicate heading, MD040 missing fence language) —
    # `markdownlint.sh check` is the gate.
    "${run[@]}" --fix "$@" || true
    ;;
*)
    echo "markdownlint.sh: unknown mode '$mode' (expected check|fix|offline)" >&2
    exit 2
    ;;
esac
