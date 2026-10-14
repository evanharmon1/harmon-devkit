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

# Commit messages must come from the git invocation, never adjacent commands.
assert_commit_status() {
    local hook="$1" expected="$2" command_text="$3"
    local status=0 output
    output="$(jq -n --arg command "$command_text" --arg cwd "$tmpdir" \
        '{cwd: $cwd, tool_input: {command: $command}}' |
        CLAUDE_PROJECT_DIR="$repo" bash "$hook" 2>&1)" || status=$?
    [ "$status" -eq "$expected" ] ||
        fail "$hook: expected exit $expected, got $status for $command_text: $output"
}

python_before_commit="$(
    cat <<'COMMAND'
python3 - <<'EOF'
import pathlib
print('git commit -m bad message')
EOF
git commit -F msg.txt
COMMAND
)"
heredoc_message="$(
    cat <<'COMMAND'
git commit -m "$(cat <<'EOF'
fix: multiline message

A body with 'quotes' and a second paragraph.
EOF
)"
COMMAND
)"
bad_heredoc_message="$(
    cat <<'COMMAND'
git commit -m "$(cat <<'EOF'
bad message

A body that must not hide the invalid subject.
EOF
)"
COMMAND
)"

unquoted_heredoc_header="$(
    cat <<'COMMAND'
git commit -m "$(cat <<EOF
$TYPE: expanded by the shell
EOF
)"
COMMAND
)"
quoted_heredoc_literals="$(
    cat <<'COMMAND'
git commit -m "$(cat <<'EOF'
feat: add `--flag`

Mentions `x` and $HOME literally.
EOF
)"
COMMAND
)"

continued_commit="$(
    cat <<'COMMAND'
git commit \
-m "bad message"
COMMAND
)"

for commit_hook in \
    "$repo/.claude/hooks/enforce-conventional-commits.sh" \
    "$repo/.devcontainer/config/claude-hooks/enforce-conventional-commits.sh" \
    "$repo/template/.claude/hooks/enforce-conventional-commits.sh" \
    "$repo/template/[% if devcontainer %].devcontainer[% endif %]/config/claude-hooks/enforce-conventional-commits.sh"; do
    [ -f "$commit_hook" ] || continue
    echo "==> conventional commit extraction: $commit_hook"
    printf 'fix: file message\n' >"$tmpdir/msg.txt"
    assert_commit_status "$commit_hook" 0 "$python_before_commit"
    printf 'bad file message\n' >"$tmpdir/msg.txt"
    # -F/--file deliberately delegate to lefthook, even for an invalid file.
    assert_commit_status "$commit_hook" 0 "$python_before_commit"
    assert_commit_status "$commit_hook" 0 'git commit --file msg.txt'
    assert_commit_status "$commit_hook" 0 'git commit --file=msg.txt'
    assert_commit_status "$commit_hook" 0 "$heredoc_message"
    assert_commit_status "$commit_hook" 2 "$bad_heredoc_message"
    assert_commit_status "$commit_hook" 0 "echo 'git commit -m bad'"
    assert_commit_status "$commit_hook" 2 'git commit -m "bad message"'
    assert_commit_status "$commit_hook" 0 'git commit -m "fix: ok"'
    assert_commit_status "$commit_hook" 0 'echo -m "bad message"; git commit --amend --no-edit'
    assert_commit_status "$commit_hook" 0 'git commit -C HEAD'
    assert_commit_status "$commit_hook" 0 'git commit'
    assert_commit_status "$commit_hook" 0 'git commit -m "unterminated'
    assert_commit_status "$commit_hook" 0 'echo -m "bad message"; git commit --message "fix: ok"'
    assert_commit_status "$commit_hook" 2 'git commit --message="bad message"'
    assert_commit_status "$commit_hook" 0 'git commit --message="fix: ok"'
    assert_commit_status "$commit_hook" 2 'git commit -m"bad message"'
    assert_commit_status "$commit_hook" 0 'git commit -m"fix: ok"'
    assert_commit_status "$commit_hook" 2 'git -C /tmp commit -m "bad message"'
    assert_commit_status "$commit_hook" 0 'git log -m "bad message" commit'
    assert_commit_status "$commit_hook" 0 'git commit -- path -m "bad message"'
    assert_commit_status "$commit_hook" 0 "${python_before_commit/-F msg.txt/-m \"fix: ok\"}"
    assert_commit_status "$commit_hook" 2 "${python_before_commit/-F msg.txt/-m \"bad message\"}"
    # Shell command words, Git global options, and clustered message options.
    assert_commit_status "$commit_hook" 2 'git --no-pager commit -m "bad message"'
    assert_commit_status "$commit_hook" 2 'git -P commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'git --bare commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'git -C . commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'git -c user.name=x commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'git --super-prefix prefix commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'git --exec-path commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'git --exec-path=/tmp commit -m "bad"'
    assert_commit_status "$commit_hook" 0 "$continued_commit"
    assert_commit_status "$commit_hook" 2 'FOO=1 git commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'env GIT_X=1 git commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'env -i -u HOME GIT_X=1 git commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'command git commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'builtin git commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'exec git commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'nohup git commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'time git commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'time -p git commit -m "bad"'
    assert_commit_status "$commit_hook" 2 '/usr/bin/git commit -m "bad"'
    assert_commit_status "$commit_hook" 2 '( git commit -m "bad" )'
    assert_commit_status "$commit_hook" 2 '{ git commit -m "bad"; }'
    assert_commit_status "$commit_hook" 2 'if git commit -m "bad"; then :; fi'
    assert_commit_status "$commit_hook" 2 '! git commit -m "bad"'
    assert_commit_status "$commit_hook" 2 'while git commit -m "bad"; do :; done'
    assert_commit_status "$commit_hook" 2 'until git commit -m "bad"; do :; done'
    assert_commit_status "$commit_hook" 0 'git commit -am "bad message"'
    assert_commit_status "$commit_hook" 0 'git commit -sm "bad"'
    assert_commit_status "$commit_hook" 0 'git commit -vam "bad"'
    assert_commit_status "$commit_hook" 0 'git commit -ambad'
    assert_commit_status "$commit_hook" 2 'git commit --mess "bad"'
    assert_commit_status "$commit_hook" 2 'git commit --messa=bad'
    assert_commit_status "$commit_hook" 0 'git commit -am "fix: ok"'
    assert_commit_status "$commit_hook" 0 'git commit "-amfix: ok"'
    assert_commit_status "$commit_hook" 0 'git commit -aF msg.txt'
    assert_commit_status "$commit_hook" 0 'git commit --fil msg.txt'
    assert_commit_status "$commit_hook" 0 'git commit --fil=msg.txt'

    # Certain message forms only: ambiguous syntax belongs to lefthook.
    assert_commit_status "$commit_hook" 2 'git commit -m "bad message" -SABCDEF12'
    assert_commit_status "$commit_hook" 0 'git commit -Cmain -m "fix: ok"'
    assert_commit_status "$commit_hook" 2 'git commit --m "bad message"'
    assert_commit_status "$commit_hook" 2 'git commit --me=bad'
    assert_commit_status "$commit_hook" 2 'curl http://x/#frag && git commit -m "bad message"'
    assert_commit_status "$commit_hook" 2 'git commit -m "feat: ok" && git commit -m "bad message"'
    assert_commit_status "$commit_hook" 2 'git --attr-source HEAD commit -m "bad message"'
    assert_commit_status "$commit_hook" 0 "git commit -m \$'feat: ok'"
    assert_commit_status "$commit_hook" 0 'git commit -m "$MESSAGE"'
    assert_commit_status "$commit_hook" 0 "printf x; $continued_commit"
    assert_commit_status "$commit_hook" 0 'git commit -m "bad message" && git commit -am "bad"'
    assert_commit_status "$commit_hook" 2 'git commit -C main -m "bad message"'
    assert_commit_status "$commit_hook" 0 "$unquoted_heredoc_header"
    assert_commit_status "$commit_hook" 0 'git commit -m "`echo feat`: ok"'
    assert_commit_status "$commit_hook" 0 "$quoted_heredoc_literals"
    assert_commit_status "$commit_hook" 0 'true # note ; git commit -m "bad message"'
    assert_commit_status "$commit_hook" 2 'git commit -u -m "bad message"'
    assert_commit_status "$commit_hook" 2 'true |& git commit -m "bad message"'
    assert_commit_status "$commit_hook" 0 'git commit --amend --no-edit;(echo -m "not a message")'
    assert_commit_status "$commit_hook" 0 '(git commit --no-edit)|grep -m1 x'
    assert_commit_status "$commit_hook" 2 'true;(git commit -m "bad message")'
    assert_commit_status "$commit_hook" 0 'echo "" git commit -m "bad message"'

done

echo "==> conventional commit extraction OK"

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

# ---------------------------------------------------------------------------
# protect-files: credential-shaped protection regression (#1019)
# ---------------------------------------------------------------------------
# The hook keeps only credential-shaped protections (.env, .pem, .key,
# .claude/settings.json, .codex/config.toml, /etc/claude-code/, /etc/codex/)
# and drops .git/, lockfiles, node_modules/, dist/, terraform state, and
# media/PDF suffixes.

devc_protect=".devcontainer/config/claude-hooks/protect-files.sh"

protect_payload() {
    jq -n --arg file "$1" '{"tool_input":{"file_path":$file}}'
}

assert_protect_blocks() {
    local hook="$1" file="$2"
    local stderr_out
    local status=0
    stderr_out="$(protect_payload "$file" | bash "$repo/$hook" 2>&1 >/dev/null)" || status=$?
    if [ "$status" -ne 2 ]; then
        fail "$hook allowed '$file' (exit $status, expected 2)"
    fi
    if [[ "$stderr_out" != *"protect-files: blocked write to '$file'"* ]]; then
        fail "$hook blocked '$file' with unexpected stderr: $stderr_out"
    fi
}

assert_protect_allows() {
    local hook="$1" file="$2"
    local stderr_out
    local status=0
    stderr_out="$(protect_payload "$file" | bash "$repo/$hook" 2>&1 >/dev/null)" || status=$?
    if [ "$status" -ne 0 ]; then
        fail "$hook unexpectedly blocked '$file' (exit $status): $stderr_out"
    fi
}

if [ ! -f "$repo/$devc_protect" ]; then
    echo "==> protect-files regression tests skipped (devcontainer assets absent)"
elif [ ! -x "$repo/$devc_protect" ]; then
    fail "$devc_protect exists but is not executable"
else
    echo "==> protect-files blocks credential-shaped paths"
    assert_protect_blocks "$devc_protect" ".env"
    assert_protect_blocks "$devc_protect" "/repo/.env"
    assert_protect_blocks "$devc_protect" "/repo/.env.local"
    assert_protect_blocks "$devc_protect" "/repo/prod.env"
    assert_protect_blocks "$devc_protect" "/repo/subdir/.env.local"
    assert_protect_blocks "$devc_protect" "/repo/sub/.env.production"
    assert_protect_blocks "$devc_protect" "/repo/.envrc"
    assert_protect_blocks "$devc_protect" "secrets.pem"
    assert_protect_blocks "$devc_protect" "/repo/certs/server.pem"
    assert_protect_blocks "$devc_protect" "server.key"
    assert_protect_blocks "$devc_protect" "/repo/keys/id_rsa.key"
    assert_protect_blocks "$devc_protect" ".claude/settings.json"
    assert_protect_blocks "$devc_protect" "/repo/.claude/settings.json"
    assert_protect_blocks "$devc_protect" ".codex/config.toml"
    assert_protect_blocks "$devc_protect" "/repo/.codex/config.toml"
    assert_protect_blocks "$devc_protect" "/etc/claude-code/x"
    assert_protect_blocks "$devc_protect" "/etc/claude-code/config.json"
    assert_protect_blocks "$devc_protect" "/etc/codex/x"

    echo "==> protect-files allows dropped patterns (.git, lockfiles, dist, media, etc.)"
    assert_protect_allows "$devc_protect" "/repo/.git/dev-flow-v2/runs/r/run.json"
    assert_protect_allows "$devc_protect" "/repo/.git/deferred-findings/branch"
    assert_protect_allows "$devc_protect" "/repo/.git/config"
    assert_protect_allows "$devc_protect" "/repo/package-lock.json"
    assert_protect_allows "$devc_protect" "/repo/uv.lock"
    assert_protect_allows "$devc_protect" "/repo/node_modules/foo/index.js"
    assert_protect_allows "$devc_protect" "/repo/dist/x.js"
    assert_protect_allows "$devc_protect" "/repo/img.png"
    assert_protect_allows "$devc_protect" "/repo/photo.jpg"
    assert_protect_allows "$devc_protect" "/repo/doc.pdf"
    assert_protect_allows "$devc_protect" "/repo/.terraform/main.tf"
    assert_protect_allows "$devc_protect" "/repo/terraform.tfstate"
    assert_protect_allows "$devc_protect" "/repo/ai/schemas/result.envelope.schema.json"
    assert_protect_allows "$devc_protect" "/repo/config.environment.json"
    assert_protect_allows "$devc_protect" "/repo/config.env.js"
    assert_protect_allows "$devc_protect" "/repo/src/env.ts"
    assert_protect_allows "$devc_protect" "/repo/env.config.json"
    assert_protect_allows "$devc_protect" "/repo/prod.env.local"
    assert_protect_allows "$devc_protect" "/repo/.env.d/README.md"
    assert_protect_allows "$devc_protect" "/repo/.environment/schema.json"
    assert_protect_allows "$devc_protect" ""

    echo "==> protect-files regression tests OK"
fi

# git-merge-guard replaces the Bash(git merge:*) ask rules; see the script header.
bash "$(dirname "${BASH_SOURCE[0]}")/test-git-merge-guard.sh"
