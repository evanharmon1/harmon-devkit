#!/usr/bin/env bash
# test-hooks.sh — round-trip the Taskfile targets and Codex adapters shared by
# the Claude/Codex hooks. Guards against the go-task CLI_ARGS
# quoting/injection class of bug, where a valid commit message is silently
# rejected (blocking every commit) or a path with a space is silently skipped.
# Run via `task test:hooks`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

# The agy-adapter fixtures below run `git init`/`commit`/`worktree add` in
# throwaway repos. Left unsanitized, a machine with commit.gpgsign=true or a
# global core.hooksPath can make those fixture commits prompt, fail, or fire
# unrelated hooks — and since this suite is part of the required local gate,
# that makes `task test:hooks` unreliable rather than merely the fixture.
# Same isolation scripts/test-worktree.sh uses, for the same reason.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
git_config_count="${GIT_CONFIG_COUNT:-0}"
case "$git_config_count" in
'' | *[!0-9]*) git_config_count=0 ;;
esac
i=0
while [ "$i" -lt "$git_config_count" ]; do
    unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i"
    i=$((i + 1))
done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_ALTERNATE_OBJECT_DIRECTORIES

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "==> lint:commit-msg:text accepts a valid conventional message"
if ! printf '%s' 'feat: a valid message' | task lint:commit-msg:text >/dev/null 2>&1; then
    fail "lint:commit-msg:text rejected a VALID conventional message"
fi

echo "==> lint:commit-msg:text rejects a non-conventional message"
if printf '%s' 'not a conventional message' | task lint:commit-msg:text >/dev/null 2>&1; then
    fail "lint:commit-msg:text accepted an INVALID message"
fi

if command -v shfmt >/dev/null 2>&1; then
    echo "==> format:file formats a file, including a path containing a space"
    spaced="$tmpdir/with space.sh"
    printf 'f(){\necho hi\n}\n' >"$spaced"
    before="$(cat "$spaced")"
    if ! task format:file -- "$spaced" >/dev/null 2>&1; then
        fail "format:file errored on a path containing a space"
    fi
    if [ "$before" = "$(cat "$spaced")" ]; then
        fail "format:file did not reformat a mis-formatted file"
    fi
else
    echo "==> format:file delegation skipped (shfmt unavailable)"
fi

echo "==> hook-delegation targets OK (commit-msg accept/reject, format:file)"

codex_hooks_dir="$repo/.devcontainer/config/codex-hooks"
if [ -x "$codex_hooks_dir/file-payload.sh" ] && [ -x "$codex_hooks_dir/claude-compat.sh" ]; then
    echo "==> Codex apply_patch adapter emits one Claude-style payload per file"
    capture="$tmpdir/capture"
    mock="$tmpdir/mock-hook.sh"
    cat >"$mock" <<'EOF'
#!/usr/bin/env bash
jq -r '.tool_input.file_path' >>"$HOOK_CAPTURE"
EOF
    chmod +x "$mock"
    export HOOK_CAPTURE="$capture"
    printf '%s' '{"cwd":"/tmp/project","tool_input":{"command":"*** Begin Patch\n*** Update File: one.txt\n*** Add File: dir/two.txt\n*** End Patch"}}' |
        bash "$codex_hooks_dir/file-payload.sh" "$mock"
    printf 'one.txt\ndir/two.txt\n' >"$tmpdir/expected"
    cmp -s "$tmpdir/expected" "$capture" ||
        fail "Codex file-payload adapter did not preserve both patch paths"

    echo "==> Codex Bash adapter exports the session cwd"
    cwd_mock="$tmpdir/cwd-hook.sh"
    cat >"$cwd_mock" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$CLAUDE_PROJECT_DIR"
cat >/dev/null
EOF
    chmod +x "$cwd_mock"
    got="$(printf '%s' '{"cwd":"/tmp/codex-project"}' |
        bash "$codex_hooks_dir/claude-compat.sh" "$cwd_mock")"
    [ "$got" = "/tmp/codex-project" ] || fail "Codex Bash adapter lost the session cwd"

    echo "==> shared Claude/Codex hook adapters OK"
else
    echo "==> Codex adapter fixtures skipped (devcontainer assets absent)"
fi

echo "==> agy adapter follows Cwd to the worktree root and exports CLAUDE_PROJECT_DIR"
agy_fixture="$tmpdir/agy-fixture"
mkdir -p "$agy_fixture/.agents" "$agy_fixture/.claude/hooks"
cp "$repo/.agents/agy-adapter.sh" "$agy_fixture/.agents/agy-adapter.sh"
cat >"$agy_fixture/.claude/hooks/probe.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'PWD=%s CPD=%s\n' "$PWD" "${CLAUDE_PROJECT_DIR:-unset}" >>"$AGY_PROBE_LOG"
EOF
chmod +x "$agy_fixture/.claude/hooks/probe.sh"
git -C "$agy_fixture" init -q >/dev/null
git -C "$agy_fixture" config user.email "test@example.com" >/dev/null
git -C "$agy_fixture" config user.name "Test" >/dev/null
git -C "$agy_fixture" config commit.gpgsign false >/dev/null
git -C "$agy_fixture" add -A >/dev/null
git -C "$agy_fixture" commit -q -m init >/dev/null
agy_wt="$tmpdir/agy-fixture-wt"
git -C "$agy_fixture" worktree add -q "$agy_wt" -b agy-wt-branch >/dev/null
mkdir -p "$agy_wt/some/subdir"
agy_expected_root="$(git -C "$agy_wt" rev-parse --show-toplevel)"

agy_probe_log="$tmpdir/agy-probe.log"
: >"$agy_probe_log"
payload_a="$(jq -n --arg cwd "$agy_wt/some/subdir" '{toolCall: {name: "run_command", args: {CommandLine: "ls", Cwd: $cwd}}}')"
result_a="$(cd "$tmpdir" && AGY_PROBE_LOG="$agy_probe_log" bash -c 'printf "%s" "$1" | bash "$2" ./.claude/hooks/probe.sh PreToolUse' _ "$payload_a" "$agy_fixture/.agents/agy-adapter.sh")"
[ "$result_a" = '{"decision": "allow"}' ] || fail "agy-adapter (worktree Cwd) did not allow: $result_a"
[ -f "$agy_probe_log" ] || fail "agy-adapter (worktree Cwd) never ran the probe hook"
probe_line="$(cat "$agy_probe_log")"
[ "$probe_line" = "PWD=$agy_expected_root CPD=$agy_expected_root" ] ||
    fail "agy-adapter (worktree Cwd) expected PWD/CPD=$agy_expected_root, got: $probe_line"

# The fixture asks only when the adapter delivered Antigravity's CommandLine as
# Claude's .tool_input.command, so a passing test proves the translation the
# registered block-no-verify and enforce-conventional-commits hooks rely on,
# not merely that an "ask" string survives the round trip.
cat >"$agy_fixture/.claude/hooks/ask.sh" <<'EOF'
#!/usr/bin/env bash
received="$(jq -r '.tool_input.command // empty')"
if [ "$received" = "ls --fixture-marker" ]; then
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"fixture asks"}}'
fi
EOF
chmod +x "$agy_fixture/.claude/hooks/ask.sh"
payload_ask="$(jq -n --arg cwd "$agy_wt/some/subdir" '{toolCall: {name: "run_command", args: {CommandLine: "ls --fixture-marker", Cwd: $cwd}}}')"
result_ask="$(cd "$tmpdir" && bash -c 'printf "%s" "$1" | bash "$2" ./.claude/hooks/ask.sh PreToolUse' _ "$payload_ask" "$agy_fixture/.agents/agy-adapter.sh")"
printf '%s' "$result_ask" | jq -e '
    .decision == "ask" and (.reason | type == "string" and length > 0)
' >/dev/null || fail "agy-adapter did not preserve a hook's ask decision: $result_ask"

echo "==> agy adapter always executes ITS OWN hook, even when the target worktree's copy is tampered"
cat >"$agy_wt/.claude/hooks/probe.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'TAMPERED ran PWD=%s CPD=%s\n' "$PWD" "${CLAUDE_PROJECT_DIR:-unset}" >>"$AGY_PROBE_LOG"
EOF
git -C "$agy_wt" add -A >/dev/null
git -C "$agy_wt" commit -q -m "tamper: neuter the safety hook on this branch" >/dev/null
: >"$agy_probe_log"
result_tamper="$(cd "$tmpdir" && AGY_PROBE_LOG="$agy_probe_log" bash -c 'printf "%s" "$1" | bash "$2" ./.claude/hooks/probe.sh PreToolUse' _ "$payload_a" "$agy_fixture/.agents/agy-adapter.sh")"
[ "$result_tamper" = '{"decision": "allow"}' ] || fail "agy-adapter (tampered worktree hook) did not allow: $result_tamper"
probe_line_tamper="$(cat "$agy_probe_log")"
[ "$probe_line_tamper" = "PWD=$agy_expected_root CPD=$agy_expected_root" ] ||
    fail "agy-adapter ran the target worktree's own (tampered) hook instead of its trusted copy: $probe_line_tamper"

echo "==> agy adapter refuses a Cwd from a foreign checkout (no cd, foreign hook not run)"
agy_foreign="$tmpdir/agy-foreign"
mkdir -p "$agy_foreign/.claude/hooks"
cat >"$agy_foreign/.claude/hooks/probe.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf 'FOREIGN ran\n' >>"$AGY_FOREIGN_LOG"
EOF
chmod +x "$agy_foreign/.claude/hooks/probe.sh"
git -C "$agy_foreign" init -q >/dev/null
git -C "$agy_foreign" config user.email "test@example.com" >/dev/null
git -C "$agy_foreign" config user.name "Test" >/dev/null
git -C "$agy_foreign" config commit.gpgsign false >/dev/null
git -C "$agy_foreign" add -A >/dev/null
git -C "$agy_foreign" commit -q -m init >/dev/null

agy_neutral="$tmpdir/agy-neutral"
mkdir -p "$agy_neutral"
agy_foreign_log="$tmpdir/agy-foreign-ran.log"
payload_b="$(jq -n --arg cwd "$agy_foreign" '{toolCall: {name: "run_command", args: {CommandLine: "ls", Cwd: $cwd}}}')"
result_b="$(cd "$agy_neutral" && AGY_FOREIGN_LOG="$agy_foreign_log" bash -c 'printf "%s" "$1" | bash "$2" ./.claude/hooks/probe.sh PreToolUse' _ "$payload_b" "$agy_fixture/.agents/agy-adapter.sh")"
decision_b="$(printf '%s' "$result_b" | jq -r '.decision')"
[ "$decision_b" = "deny" ] || fail "agy-adapter followed a foreign Cwd instead of denying: $result_b"
[ -f "$agy_foreign_log" ] && fail "agy-adapter ran the foreign checkout's hook"

echo "==> agy adapter worktree-root Cwd resolution OK"

# ---------------------------------------------------------------------------
# block-no-verify: SIGPIPE fail-open regression (#822)
# ---------------------------------------------------------------------------
# The hooks read JSON on stdin and exit 0 (allow) or 2 (block). A SIGPIPE
# defect in the old `printf | grep -q` pipeline could make a MATCH report as a
# FAILURE, which the hooks' `|| exit 0` / `if` treated as "allow". The
# herestring fix eliminates the pipeline. These cases verify the hooks block
# what they must and allow what they should, covering both the .claude/hooks
# and .devcontainer/config/claude-hooks copies.

hook_payload() {
    jq -n --arg cmd "$1" '{"tool_input":{"command":$cmd}}'
}

run_hook() {
    local hook="$1" cmd="$2"
    hook_payload "$cmd" | bash "$repo/$hook" 2>/dev/null
    return $?
}

# --- .devcontainer/config/claude-hooks/block-no-verify.sh ---
devc_bnv=".devcontainer/config/claude-hooks/block-no-verify.sh"

echo "==> block-no-verify (devcontainer) blocks --no-verify"
if run_hook "$devc_bnv" "git commit --no-verify -m 'test'"; then
    fail "devcontainer block-no-verify allowed --no-verify"
fi

echo "==> block-no-verify (devcontainer) blocks --no-gpg-sign"
if run_hook "$devc_bnv" "git commit --no-gpg-sign -m 'test'"; then
    fail "devcontainer block-no-verify allowed --no-gpg-sign"
fi

echo "==> block-no-verify (devcontainer) blocks git commit -n"
if run_hook "$devc_bnv" "git commit -n -m 'test'"; then
    fail "devcontainer block-no-verify allowed git commit -n"
fi

echo "==> block-no-verify (devcontainer) allows clean git commit"
if ! run_hook "$devc_bnv" "git commit -m 'feat: valid'"; then
    fail "devcontainer block-no-verify blocked a clean commit"
fi

echo "==> block-no-verify (devcontainer) allows non-git command"
if ! run_hook "$devc_bnv" "echo hello"; then
    fail "devcontainer block-no-verify blocked a non-git command"
fi

# --- .claude/hooks/block-no-verify.sh ---
claude_bnv=".claude/hooks/block-no-verify.sh"

echo "==> block-no-verify (claude) blocks --no-verify"
if run_hook "$claude_bnv" "git commit --no-verify -m 'test'"; then
    fail "claude block-no-verify allowed --no-verify"
fi

echo "==> block-no-verify (claude) allows clean git commit"
if ! run_hook "$claude_bnv" "git commit -m 'feat: valid'"; then
    fail "claude block-no-verify blocked a clean commit"
fi

echo "==> block-no-verify (claude) allows non-git command"
if ! run_hook "$claude_bnv" "echo hello"; then
    fail "claude block-no-verify blocked a non-git command"
fi

echo "==> block-no-verify SIGPIPE regression tests OK"
