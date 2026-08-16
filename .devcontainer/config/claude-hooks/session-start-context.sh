#!/usr/bin/env bash
# session-start-context.sh — SessionStart hook (startup + compact matchers).
#
# Re-injects orienting context every time a Claude session starts or its
# context window is compacted: current branch, recent commits, working-tree
# status, open PRs/issues, local logins, and a short reminder of repo
# conventions. Uses `task status:git` + `task status:gh` + `task status:creds`
# (the fine-grained dashboard sections from scripts/status.sh) so the payload
# stays small and fast — `status:site` and `status:code` are intentionally
# skipped because they hit the network and the local build respectively, and
# `status:setup` because it is a network-heavy audit.
set -euo pipefail

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Strip ANSI color codes so the additionalContext payload renders cleanly.
strip_ansi() { sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g'; }

# The outer deadlines must exceed what the sections themselves allow, or the
# inner bounds are pointless: whatever the section was about to report is lost
# wholesale, because status.sh buffers each section before printing it.
#
# Each probe's worst case is its deadline PLUS status.sh's kill grace — the
# second run_timeout waits between SIGTERM and SIGKILL for a probe that ignores
# the first. Budgeting from the deadline alone understates every probe by that
# second, which was the whole of the margin these numbers used to carry.
#
# status:gh spends up to NETWORK_TIMEOUT (5s) on the auth probe and then up to
# another 5s on the PR/run probes it launches in parallel — 12s worst case with
# the grace, so 14 here. status:git makes no network calls at all.
#
# status:creds is budgeted from its own probes rather than by copying a
# neighbour's number: it runs three LOCAL probes back to back, each bounded at
# 3s inside status.sh, plus ONE bounded 3s call to read the gh token's SCOPES
# (a server-side property no local file records — issue #827), which is why it
# is capped at the local bound rather than NETWORK_TIMEOUT. Four probes, so
# 12s of deadlines plus four kill graces — 16s worst case, so 17 here for the
# `task` and shell startup around them.
#
# There is a SECOND deadline above all of these: the `timeout` on the
# SessionStart entries in claude-settings.json, which Claude Code applies to this
# whole script. Overrunning it is worse than any single section overrunning its
# own bound — the hook is killed before `jq` emits anything, so the entire
# payload is lost rather than one section of it. The sections are therefore run
# in PARALLEL: the hook's wall clock is then the LONGEST deadline (17s), which
# fits inside that outer timeout, where the sum (36s) would not.
git_out="$(mktemp)"
gh_out="$(mktemp)"
creds_out="$(mktemp)"
trap 'rm -f "${git_out}" "${gh_out}" "${creds_out}"' EXIT

timeout 5 task status:git >"$git_out" 2>/dev/null &
git_pid=$!
timeout 14 task status:gh >"$gh_out" 2>/dev/null &
gh_pid=$!
timeout 17 task status:creds >"$creds_out" 2>/dev/null &
creds_pid=$!

# `wait` on each, with the failure recorded rather than propagated: `set -e`
# would otherwise take the whole hook down over one section's deadline, which is
# the payload-loss failure this structure exists to avoid.
git_rc=0
wait $git_pid || git_rc=$?
gh_rc=0
wait $gh_pid || gh_rc=$?
creds_rc=0
wait $creds_pid || creds_rc=$?

# An empty file counts as a failure too: `timeout` kills status.sh mid-section,
# and section_box buffers a section before printing it, so a killed run leaves
# nothing rather than a partial section.
if [ $git_rc -ne 0 ] || [ ! -s "$git_out" ]; then
    git_status="(task status:git unavailable or failed)"
else
    git_status="$(strip_ansi <"$git_out")"
fi

if [ $gh_rc -ne 0 ] || [ ! -s "$gh_out" ]; then
    gh_status="(task status:gh unavailable or failed)"
else
    gh_status="$(strip_ansi <"$gh_out")"
fi

if [ $creds_rc -ne 0 ] || [ ! -s "$creds_out" ]; then
    creds_status="(task status:creds unavailable or failed)"
else
    creds_status="$(strip_ansi <"$creds_out")"
fi

branch="$(git branch --show-current 2>/dev/null || echo 'unknown')"

reminder=$'Repo conventions:\n- Run `task verify` before committing (lint + build + validate + test).\n- Conventional Commits required (feat/fix/docs/style/refactor/perf/test/chore/ci/build/change/remove/revert).\n- Never bypass git hooks with --no-verify; fix the underlying issue.\n- Use lefthook for git hooks (not pre-commit).\n- See docs/conventions.md (and AGENTS.md) for the authoritative conventions catalog.'

context="$(printf 'Branch: %s\n\n=== task status:git ===\n%s\n\n=== task status:gh ===\n%s\n\n=== task status:creds ===\n%s\n\n%s\n' \
    "$branch" "$git_status" "$gh_status" "$creds_status" "$reminder")"

# Emit as JSON so Claude Code injects it as additionalContext.
jq -n --arg ctx "$context" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
