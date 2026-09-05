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
# --config PATH overrides gitleaks' own auto-discovered .gitleaks.toml. It
# does NOT, however, override gitleaks' SEPARATE .gitleaksignore lookup:
# gitleaks 8.30.1's --gitleaks-ignore-path defaults to "." (--source's root)
# and, verified empirically, keeps reading that path even when
# --gitleaks-ignore-path is explicitly pointed elsewhere — the flag adds a
# location to check rather than replacing the default one. A branch could
# therefore commit a .gitleaksignore listing its own leaked secret's
# fingerprint and gitleaks would exit clean regardless of which
# .gitleaks.toml is in effect, or where --gitleaks-ignore-path points.
# There is no gitleaks flag that closes this, so this script refuses
# outright instead: when --config is given, a .gitleaksignore in the
# worktree root (--source's root) must be BYTE-IDENTICAL to the one beside
# PATH (the closure's own copy, extracted from the same merge base — absent
# there if the merge base ships none) or the scan refuses before gitleaks
# ever runs. `task security:secrets` itself never passes --config and is
# unaffected — this check only ever fires for the round-push broker's
# closure-consuming invocation.
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

# Bash 3.2 treats an empty indexed-array expansion as an unbound variable
# under `set -u` (the same class of bug round-push.sh's own git_args/
# git_arg_count guards against) — track presence separately so this script
# never expands config_args when --config was not given.
config_args=()
have_config=0
if [ -n "$config_path" ]; then
    closure_dir="$(dirname "$config_path")"
    closure_ignore="${closure_dir}/.gitleaksignore"
    worktree_ignore=".gitleaksignore"
    # Neither path may be a symlink (or any other non-regular file): `cmp`
    # below follows symlinks, so a branch could commit .gitleaksignore as a
    # symlink to bytes outside git's own tracking entirely and swap that
    # external target's content between this comparison and gitleaks' own
    # later read of the same path — the symlink itself, and this check,
    # would never see the change (Codex review, confirmed). A regular
    # file's bytes cannot move between two reads without also dirtying the
    # worktree, which the caller's own post-gate `git status` check catches
    # separately; a symlink's TARGET is invisible to that check entirely.
    for f in "$worktree_ignore" "$closure_ignore"; do
        if [ -L "$f" ]; then
            echo "gitleaks-scan: refusing — ${f} is a symlink; .gitleaksignore must be a regular file" >&2
            exit 1
        fi
        if [ -e "$f" ] && [ ! -f "$f" ]; then
            echo "gitleaks-scan: refusing — ${f} exists but is not a regular file" >&2
            exit 1
        fi
    done
    if [ -e "$worktree_ignore" ] || [ -e "$closure_ignore" ]; then
        if ! cmp -s "$worktree_ignore" "$closure_ignore" 2>/dev/null; then
            echo "gitleaks-scan: refusing — a .gitleaksignore in the worktree does not match the closure's copy (or one exists in only one place); gitleaks' ignore-path lookup cannot be redirected away from the worktree root, so this scan cannot proceed safely" >&2
            exit 1
        fi
    fi
    config_args=(--config "$config_path")
    have_config=1
fi

run_gitleaks() {
    if [ "$have_config" -eq 1 ]; then
        gitleaks detect --no-banner --redact --source . "${config_args[@]}" "$@"
    else
        gitleaks detect --no-banner --redact --source . "$@"
    fi
}

if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
    if [ "$have_config" -eq 1 ]; then
        exec gitleaks detect --no-banner --redact --source . "${config_args[@]}"
    else
        exec gitleaks detect --no-banner --redact --source .
    fi
fi

report="$(mktemp)"
trap 'rm -f "$report"' EXIT

rc=0
run_gitleaks --report-format json --report-path "$report" || rc=$?
node "${script_dir}/summarize-gitleaks.mjs" "$report"
exit "$rc"
