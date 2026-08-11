#!/usr/bin/env bash
# test-hooks.sh — round-trip the Taskfile targets and Codex adapters shared by
# the Claude/Codex hooks. Guards against the go-task CLI_ARGS
# quoting/injection class of bug, where a valid commit message is silently
# rejected (blocking every commit) or a path with a space is silently skipped.
# Run via `task test:hooks`.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

echo "==> lint:commit-msg:text accepts a valid conventional message"
if ! printf '%s' 'feat: a valid message' | task lint:commit-msg:text >/dev/null 2>&1; then
    fail "lint:commit-msg:text rejected a VALID conventional message"
fi

echo "==> lint:commit-msg:text rejects a non-conventional message"
if printf '%s' 'not a conventional message' | task lint:commit-msg:text >/dev/null 2>&1; then
    fail "lint:commit-msg:text accepted an INVALID message"
fi

echo "==> format:file formats a file, including a path containing a space"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
spaced="$tmpdir/with space.sh"
printf 'f(){\necho hi\n}\n' >"$spaced"
before="$(cat "$spaced")"
if ! task format:file -- "$spaced" >/dev/null 2>&1; then
    fail "format:file errored on a path containing a space"
fi
if [ "$before" = "$(cat "$spaced")" ]; then
    fail "format:file did not reformat a mis-formatted file"
fi

echo "==> hook-delegation targets OK (commit-msg accept/reject, format:file)"

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
    bash "$repo/.devcontainer/config/codex-hooks/file-payload.sh" "$mock"
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
    bash "$repo/.devcontainer/config/codex-hooks/claude-compat.sh" "$cwd_mock")"
[ "$got" = "/tmp/codex-project" ] || fail "Codex Bash adapter lost the session cwd"

echo "==> shared Claude/Codex hook adapters OK"
