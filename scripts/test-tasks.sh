#!/usr/bin/env bash
# test-tasks.sh — guard the Taskfile against regressions that only surface at
# run time: a Taskfile that no longer compiles, and setup tasks that fail when
# they should be safe no-ops. Run via `task test:tasks`.
#
# The bootstrap assertion is hermetic: fake brew/npm commands exercise the
# "Homebrew already installed" path without installing or updating shared
# machine tooling. A fake curl proves the Homebrew installer was not reached.
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

echo "==> bootstrap avoids external installers when Homebrew is available"
bootstrap_bin="${shell_tmp}/bootstrap-bin"
bootstrap_curl_marker="${shell_tmp}/bootstrap-curl-called"
mkdir -p "$bootstrap_bin"
for command_name in brew npm; do
    cat >"${bootstrap_bin}/${command_name}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
cat >"${bootstrap_bin}/curl" <<'EOF'
#!/usr/bin/env bash
: >"${BOOTSTRAP_CURL_MARKER:?}"
exit 97
EOF
chmod +x "${bootstrap_bin}/brew" "${bootstrap_bin}/npm" "${bootstrap_bin}/curl"
if ! PATH="${bootstrap_bin}:${PATH}" BOOTSTRAP_CURL_MARKER="$bootstrap_curl_marker" \
    task bootstrap >/dev/null 2>&1; then
    fail "task bootstrap failed with hermetic Homebrew/npm fixtures"
fi
[ ! -e "$bootstrap_curl_marker" ] || fail "task bootstrap invoked the Homebrew download despite brew being available"

echo "==> shell quality helper preserves a path containing spaces"
shell_fixture="${shell_tmp}/fixture with spaces.sh"
cat >"$shell_fixture" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "ok"
EOF
./scripts/shell-quality.sh check "$shell_fixture"

if [ -x ./scripts/devcontainer-smoke.sh ]; then
    echo "==> devcontainer smoke test fails fast before a wedged daemon probe"
    smoke_bin="${shell_tmp}/smoke-bin"
    timeout_marker="${shell_tmp}/docker-timeout-called"
    devcontainer_marker="${shell_tmp}/devcontainer-called"
    mkdir -p "$smoke_bin"
    cat >"${smoke_bin}/timeout" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-k" ] && [ "${2:-}" = "5" ] && [ "${3:-}" = "20" ] \
    && [ "${4:-}" = "docker" ] && [ "${5:-}" = "info" ] || exit 98
: >"${TIMEOUT_MARKER:?}"
exit 124
EOF
    cat >"${smoke_bin}/docker" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
    cat >"${smoke_bin}/devcontainer" <<'EOF'
#!/usr/bin/env bash
: >"${DEVCONTAINER_MARKER:?}"
exit 99
EOF
    cat >"${smoke_bin}/jq" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${smoke_bin}/timeout" "${smoke_bin}/docker" "${smoke_bin}/devcontainer" "${smoke_bin}/jq"
    out=$(PATH="${smoke_bin}:${PATH}" TIMEOUT_MARKER="$timeout_marker" \
        DEVCONTAINER_MARKER="$devcontainer_marker" \
        ./scripts/devcontainer-smoke.sh .devcontainer/devcontainer.json 2>&1) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        fail "devcontainer smoke test accepted an unavailable Docker daemon"
    fi
    [ -e "$timeout_marker" ] || fail "devcontainer smoke test did not bound its Docker daemon probe"
    [ ! -e "$devcontainer_marker" ] || fail "devcontainer smoke test invoked the CLI after the Docker preflight failed"
    case "$out" in
    *"Docker daemon is unavailable"*) ;;
    *) fail "devcontainer smoke test failed for the wrong reason: $out" ;;
    esac
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
