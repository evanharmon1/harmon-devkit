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
strip_ansi() { sed -E 's/\x1B\[''[0-9;]*[A-Za-z]//g'; }

# The outer deadlines must exceed what the sections themselves allow, or the
# inner bounds are pointless: whatever the section was about to report is lost
# wholesale, because status.sh buffers each section before printing it. status:gh
# spends up to NETWORK_TIMEOUT (5s) on the auth probe and then up to another 5s
# on the PR/run probes it launches in parallel — 10s worst case, so 12 here.
# status:git makes no network calls at all.
#
# status:creds is budgeted from its own probes rather than by copying a
# neighbour's number: it makes NO network call (that is why it can be here at
# all — status:gh already spends this startup's only auth round trip), and runs
# three LOCAL probes back to back, each bounded at 3s inside status.sh — 9s
# worst case, so 11 here for the `task` and shell startup around them. The three run in
# parallel, so it adds nothing to the wall clock the gh deadline already allows.
remote_url="$(git config --get remote.origin.url 2>/dev/null || echo '')"
host_owner="$(echo "$remote_url" | sed -E 's/^(https?:\/\/|git@)([^:\/]+)[:\/]([^\/]+)\/[^\/]+(\.git)?$/\2 \3/')"
host="${host_owner% *}"
owner="${host_owner#* }"

if [ "$host" = "github.com" ]; then
    case "$owner" in
    "evanharmon1" | "evanharmon1" | "harmonops" | "ponderousdev")
        git_out="$(mktemp)"
        gh_out="$(mktemp)"
        creds_out="$(mktemp)"
        timeout_cmd="timeout"
        if command -v gtimeout >/dev/null 2>&1; then
            timeout_cmd="gtimeout"
        fi
        "$timeout_cmd" 5 task status:git >"$git_out" 2>/dev/null &
        git_pid=$!
        "$timeout_cmd" 12 task status:gh >"$gh_out" 2>/dev/null &
        gh_pid=$!
        "$timeout_cmd" 11 task status:creds >"$creds_out" 2>/dev/null &
        creds_pid=$!

        git_rc=0
        wait $git_pid || git_rc=$?
        gh_rc=0
        wait $gh_pid || gh_rc=$?
        creds_rc=0
        wait $creds_pid || creds_rc=$?

        if [ $git_rc -ne 0 ] || [ ! -s "$git_out" ]; then
            git_status="(task status:git unavailable or failed)"
        else
            git_status="$(cat "$git_out" | strip_ansi)"
        fi

        if [ $gh_rc -ne 0 ] || [ ! -s "$gh_out" ]; then
            gh_status="(task status:gh unavailable or failed)"
        else
            gh_status="$(cat "$gh_out" | strip_ansi)"
        fi
        if [ $creds_rc -ne 0 ] || [ ! -s "$creds_out" ]; then
            creds_status="(task status:creds unavailable or failed)"
        else
            creds_status="$(cat "$creds_out" | strip_ansi)"
        fi
        rm -f "$git_out" "$gh_out" "$creds_out"
        ;;
    *)
        git_status="(task status:git skipped - untrusted repository)"
        gh_status="(task status:gh skipped - untrusted repository)"
        creds_status="(task status:creds skipped - untrusted repository)"
        ;;
    esac
else
    git_status="(task status:git skipped - untrusted repository)"
    gh_status="(task status:gh skipped - untrusted repository)"
    creds_status="(task status:creds skipped - untrusted repository)"
fi

branch="$(git branch --show-current 2>/dev/null || echo 'unknown')"

reminder=$'Repo conventions:\n- Run `task verify` before committing (lint + build + validate + test).\n- Conventional Commits required (feat/fix/docs/style/refactor/perf/test/chore/ci/build/revert).\n- Never bypass git hooks with --no-verify; fix the underlying issue.\n- Use lefthook for git hooks (not pre-commit).\n- See docs/conventions.md (and AGENTS.md) for the authoritative conventions catalog.'

context="$(printf 'Branch: %s\n\n=== task status:git ===\n%s\n\n=== task status:gh ===\n%s\n\n=== task status:creds ===\n%s\n\n%s\n' \
    "$branch" "$git_status" "$gh_status" "$creds_status" "$reminder")"

# Emit as JSON so Claude Code injects it as additionalContext.
jq -n --arg ctx "$context" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
