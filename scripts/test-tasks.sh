#!/usr/bin/env bash
# test-tasks.sh — guard the Taskfile against regressions that only surface at
# run time: a Taskfile that no longer compiles, and setup tasks that fail when
# they should be safe no-ops. Run via `task test:tasks`.
#
# Coverage note: the bootstrap assertion only exercises the "Homebrew already
# installed" path, so it is skipped on runners without brew (e.g. the default
# ubuntu-latest CI). It still guards the common local/macOS case — the exact
# regression where `task bootstrap` aborted on a sudo precheck despite brew
# already being installed.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "$repo"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

echo "==> Taskfile compiles (every task parses)"
if ! task --list-all >/dev/null 2>&1; then
    fail "task --list-all failed — the Taskfile does not compile"
fi

echo "==> bootstrap is a no-op when Homebrew is already installed"
if command -v brew >/dev/null 2>&1; then
    if ! task bootstrap >/dev/null 2>&1; then
        fail "task bootstrap failed even though brew is already installed"
    fi
else
    echo "    (skipped: brew not on PATH)"
fi

echo "==> Semgrep wrapper preserves explicit scan targets"
semgrep_bin="${test_tmp}/semgrep-bin"
semgrep_args="${test_tmp}/semgrep-args"
mkdir -p "$semgrep_bin"
cat >"${semgrep_bin}/uvx" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${SEMGREP_ARGS:?}"
EOF
chmod +x "${semgrep_bin}/uvx"
PATH="${semgrep_bin}:${PATH}" SEMGREP_ARGS="$semgrep_args" \
    ./scripts/run-semgrep.sh scripts
[ "$(tail -n 1 "$semgrep_args")" = "scripts" ] ||
    fail "Semgrep wrapper did not preserve the explicit target"
if grep -Fxq . "$semgrep_args"; then
    fail "Semgrep wrapper appended a repository-wide target"
fi

echo "==> secret helper tasks reject missing destination metadata"
# Assert the stable missing-destination diagnostic, not just a nonzero exit:
# a bare `if ! task ...` would also be satisfied by an unrelated failure
# (missing op/gh, a Taskfile parse error). Clear any inherited destination
# metadata first so the tests actually exercise the missing-metadata path.
out=$(printf '%s' 'dummy-secret' |
    env -u VAULT -u ITEM -u FIELD -u SECTION task secret:set:1p 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
    fail "task secret:set:1p succeeded without destination metadata"
fi
case "$out" in
*"VAULT, ITEM, and FIELD are required"*) ;;
*) fail "task secret:set:1p failed for the wrong reason: $out" ;;
esac
out=$(printf '%s' 'dummy-secret' |
    env -u NAME -u REPO task secret:set:gh 2>&1) && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
    fail "task secret:set:gh succeeded without destination metadata"
fi
case "$out" in
*"NAME and REPO are required"*) ;;
*) fail "task secret:set:gh failed for the wrong reason: $out" ;;
esac

echo "==> 1Password helper rejects SSH Key categories at runtime"
op_bin="${test_tmp}/op-bin"
op_edit_called="${test_tmp}/op-edit-called"
mkdir -p "$op_bin"
cat >"${op_bin}/op" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
"item get")
    printf '{"category":"%s","fields":[{"label":"password","type":"CONCEALED","value":"old"}]}\n' \
        "${OP_FIXTURE_CATEGORY:?}"
    ;;
"item edit")
    : >"${OP_EDIT_CALLED:?}"
    cat >/dev/null
    ;;
*)
    exit 1
    ;;
esac
EOF
chmod +x "${op_bin}/op"
for category in SSH_KEY SSHKEY; do
    rm -f "$op_edit_called"
    out=$(printf '%s' 'dummy-secret' |
        PATH="${op_bin}:${PATH}" OP_FIXTURE_CATEGORY="$category" \
            OP_EDIT_CALLED="$op_edit_called" VAULT=test ITEM=test FIELD=password \
            ./scripts/secret-set-1p.sh 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "secret:set:1p accepted unsupported category $category"
    fi
    case "$out" in
    *"item holds a passkey or SSH key"*) ;;
    *) fail "secret:set:1p rejected $category for the wrong reason: $out" ;;
    esac
    if [ -e "$op_edit_called" ]; then
        fail "secret:set:1p attempted an item edit for $category"
    fi
done

echo "==> task targets OK (compile + bootstrap idempotency)"
