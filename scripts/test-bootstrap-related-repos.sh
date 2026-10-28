#!/usr/bin/env bash
# test-bootstrap-related-repos.sh — unit-test bootstrap-related-repos.sh fallback,
# private temporary directories with atomic publish, and idempotency (stubbed gh/git
# and local bare git repo, no network).
#
# Run via `task test:related-repos`.
set -euo pipefail
cd "$(dirname "$0")/.."

unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST
unset NODE_OPTIONS

SUT="./.devcontainer/scripts/bootstrap-related-repos.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { # shell-robustness: ok — this reporter always exits 1
    echo "TEST FAIL: $*" >&2
    exit 1
}

# --- Setup local bare git repository to act as hermetic upstream ---
BARE_BASE="${TMP}/bare-upstream"
mkdir -p "${BARE_BASE}/test-owner"
BARE_REPO="${BARE_BASE}/test-owner/test-repo.git"
git init --bare "${BARE_REPO}" >/dev/null 2>&1

SCRATCH="${TMP}/scratch-repo"
git clone "${BARE_REPO}" "${SCRATCH}" >/dev/null 2>&1
git -C "${SCRATCH}" -c user.name="Test" -c user.email="test@example.com" commit --allow-empty -m "initial commit" >/dev/null 2>&1
git -C "${SCRATCH}" push origin HEAD:main >/dev/null 2>&1
git -C "${SCRATCH}" checkout -b feature-branch >/dev/null 2>&1
git -C "${SCRATCH}" -c user.name="Test" -c user.email="test@example.com" commit --allow-empty -m "branch commit" >/dev/null 2>&1
git -C "${SCRATCH}" push origin feature-branch >/dev/null 2>&1
rm -rf "${SCRATCH}"

BIN_DIR="${TMP}/bin"
mkdir -p "${BIN_DIR}"

REAL_GIT="$(command -v git)"
REAL_MV="$(command -v mv)"
REAL_MKTEMP="$(command -v mktemp)"

# --- Stub mktemp that can simulate tempdir creation failure ---
cat <<EOF >"${BIN_DIR}/mktemp"
#!/usr/bin/env bash
if [ -n "\${STUB_MKTEMP_LOG:-}" ]; then
    echo "\$*" >>"\${STUB_MKTEMP_LOG}"
fi
if [ "\${STUB_MKTEMP:-}" = "fail" ]; then
    echo "mktemp: failed to create directory: Permission denied" >&2
    exit 1
fi
exec "${REAL_MKTEMP}" "\$@"
EOF
chmod +x "${BIN_DIR}/mktemp"

# --- Stub git that enforces offline operation and logs arguments ---
cat <<EOF >"${BIN_DIR}/git"
#!/usr/bin/env bash
if [ -n "\${GIT_LOG:-}" ]; then
    echo "\$*" >>"\${GIT_LOG}"
fi
if [ -n "\${STUB_GIT_CLONE_SLEEP:-}" ]; then
    for arg in "\$@"; do
        if [ "\$arg" = "clone" ]; then
            echo "\$*" >>"\${STUB_GIT_CLONE_LOG}"
            sleep "\${STUB_GIT_CLONE_SLEEP}"
            exit 1
        fi
    done
fi
for arg in "\$@"; do
    case "\$arg" in
    *https://github.com* | *https://*)
        echo "ERROR: network URL attempted in offline test: \$arg" >&2
        exit 99
        ;;
    esac
done
exec "${REAL_GIT}" "\$@"
EOF
chmod +x "${BIN_DIR}/git"

# --- Stub mv that can simulate concurrent target creation before publish ---
cat <<EOF >"${BIN_DIR}/mv"
#!/usr/bin/env bash
if [ -n "\${STUB_MV_LOG:-}" ]; then
    echo "\$*" >>"\${STUB_MV_LOG}"
fi
if [ "\$1" = "--version" ]; then
    if [ "\${STUB_MV:-}" = "no-version" ]; then
        echo "mv: unrecognized option '--version'" >&2
        exit 64
    fi
    exec "${REAL_MV}" --version
fi
if [ "\${STUB_MV:-}" = "concurrent-dir" ]; then
    dest=""
    for arg in "\$@"; do
        dest="\$arg"
    done
    if [ -n "\$dest" ]; then
        mkdir -p "\$dest"
        echo "user-checkout-data" >"\${dest}/marker.txt"
    fi
elif [ "\${STUB_MV:-}" = "concurrent-file" ]; then
    dest=""
    for arg in "\$@"; do
        dest="\$arg"
    done
    if [ -n "\$dest" ]; then
        echo "user-plain-file" >"\$dest"
    fi
elif [ "\${STUB_MV:-}" = "fail-publish" ]; then
    echo "mv: simulated I/O error during publish" >&2
    exit 5
fi
exec "${REAL_MV}" "\$@"
EOF
chmod +x "${BIN_DIR}/mv"

# --- Stub mkdir that simulates a parent default ACL overriding the umask ---
REAL_MKDIR="$(command -v mkdir)"
cat <<EOF >"${BIN_DIR}/mkdir"
#!/usr/bin/env bash
"${REAL_MKDIR}" "\$@" || exit \$?
if [ -n "\${STUB_MKDIR_MODE:-}" ]; then
    for arg in "\$@"; do
        last="\$arg"
    done
    chmod "\${STUB_MKDIR_MODE}" "\$last"
fi
EOF
chmod +x "${BIN_DIR}/mkdir"

make_stub() {
    local scenario="$1"
    cat <<EOF >"${BIN_DIR}/gh"
#!/usr/bin/env bash
if [ -n "\${STUB_LOG:-}" ]; then
    echo "\$*" >>"\${STUB_LOG}"
fi
case "$scenario" in
auth-ok)
    if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then
        exit 0
    fi
    if [ "\$1" = "repo" ] && [ "\$2" = "clone" ]; then
        target_spec="\$3"
        target_dir="\$4"
        shift 4
        branch=""
        while [ \$# -gt 0 ]; do
            if [ "\$1" = "--branch" ]; then
                branch="\$2"
                shift 2
            else
                shift
            fi
        done
        upstream="${BARE_BASE}/\${target_spec}.git"
        if [ -n "\$branch" ]; then
            "${BIN_DIR}/git" clone --quiet --branch "\$branch" "\$upstream" "\$target_dir"
        else
            "${BIN_DIR}/git" clone --quiet "\$upstream" "\$target_dir"
        fi
        exit 0
    fi
    ;;
unauthenticated)
    if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then
        echo "You are not logged into any GitHub hosts." >&2
        exit 1
    fi
    if [ "\$1" = "repo" ] && [ "\$2" = "clone" ]; then
        echo "Authentication required." >&2
        exit 1
    fi
    ;;
clone-fails)
    if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then
        exit 0
    fi
    if [ "\$1" = "repo" ] && [ "\$2" = "clone" ]; then
        echo "clone error simulated" >&2
        exit 1
    fi
    ;;
concurrent-user-create)
    if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then
        exit 0
    fi
    if [ "\$1" = "repo" ] && [ "\$2" = "clone" ]; then
        target_spec="\$3"
        target_dir="\$4"
        # Simulate user creating the final target directory while clone runs
        mkdir -p "\${WORKSPACES_DIR}/test-repo"
        echo "user-checkout-data" >"\${WORKSPACES_DIR}/test-repo/user-file.txt"
        upstream="${BARE_BASE}/\${target_spec}.git"
        "${BIN_DIR}/git" clone --quiet "\$upstream" "\$target_dir"
        exit 0
    fi
    ;;
esac
echo "unexpected stub call: \$*" >&2
exit 1
EOF
    chmod +x "${BIN_DIR}/gh"
}

WORKSPACES="${TMP}/workspaces"
CONFIG="${TMP}/related-repos.txt"

run_sut() {
    (
        local scenario="$1"
        make_stub "${scenario}"
        export PATH="${BIN_DIR}:${PATH}"
        export WORKSPACES_DIR="${WORKSPACES}"
        export CONFIG_FILE="${CONFIG}"
        if [ "${TEST_UNSET_BASE_URL:-}" = "1" ]; then
            unset RELATED_REPOS_GIT_BASE_URL
        else
            export RELATED_REPOS_GIT_BASE_URL="${RELATED_REPOS_GIT_BASE_URL:-file://${BARE_BASE}/}"
        fi
        bash "${SUT}"
    )
}

# --- Test 1: Unauthenticated gh falls back to git clone (offline) ---
echo "==> unauthenticated gh falls back to git clone (offline)"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
STUB_LOG="${TMP}/stub-1.log"
GIT_LOG="${TMP}/git-1.log"
rm -f "${STUB_LOG}" "${GIT_LOG}"
export STUB_LOG GIT_LOG
run_sut unauthenticated
[ -d "${WORKSPACES}/test-repo/.git" ] || fail "expected test-repo to be cloned via git fallback"
grep -q "auth status" "${STUB_LOG}" || fail "expected gh auth status probe"
grep -q "clone.*test-owner/test-repo.git" "${GIT_LOG}" || fail "expected git fallback clone to be executed offline"

# --- Test 2: Failing gh repo clone falls back to git clone ---
echo "==> failing gh repo clone falls back to git clone"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
STUB_LOG="${TMP}/stub-2.log"
GIT_LOG="${TMP}/git-2.log"
rm -f "${STUB_LOG}" "${GIT_LOG}"
export STUB_LOG GIT_LOG
run_sut clone-fails
[ -d "${WORKSPACES}/test-repo/.git" ] || fail "expected test-repo to be cloned via git fallback after gh clone failed"
grep -q "clone.*test-owner/test-repo.git" "${GIT_LOG}" || fail "expected git fallback clone to be executed"

# --- Test 3: Both failing leaves no directory behind and exits 0 (offline) ---
echo "==> both failing leaves no directory behind and exits 0 (offline)"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "unknown-owner/nonexistent-repo" >"${CONFIG}"
GIT_LOG="${TMP}/git-3.log"
rm -f "${GIT_LOG}"
export GIT_LOG
rc=0
run_sut unauthenticated >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "script must exit 0 even when clone fails"
[ ! -e "${WORKSPACES}/nonexistent-repo" ] || fail "failed clone must not leave a directory behind"
grep -q "nonexistent-repo.git" "${GIT_LOG}" || fail "expected offline git fallback attempt"
[ -z "$(find "${WORKSPACES}" -name '.bootstrap-*' -print -quit 2>/dev/null)" ] || fail "temporary directory was not cleaned up after both clones failed"

# --- Test 4: Already-present repo is skipped ---
echo "==> already-present repo is skipped"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
mkdir -p "${WORKSPACES}/test-repo"
echo "custom-content" >"${WORKSPACES}/test-repo/marker.txt"
echo "test-owner/test-repo" >"${CONFIG}"
run_sut auth-ok
[ -f "${WORKSPACES}/test-repo/marker.txt" ] || fail "existing repository contents must not be clobbered"
[ ! -d "${WORKSPACES}/test-repo/.git" ] || fail "skipped repo should not have been cloned over"

# --- Test 5: Concurrent target creation does not delete user checkout or nest clone ---
echo "==> concurrent target creation does not delete user checkout"
# 5a: GNU atomic path
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
rc=0
STUB_MV="concurrent-dir" run_sut auth-ok >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "script must exit 0 when target created concurrently (GNU path)"
[ -f "${WORKSPACES}/test-repo/marker.txt" ] || fail "user checkout was deleted or clobbered by bootstrap (GNU path)"
[ -z "$(find "${WORKSPACES}/test-repo" -mindepth 1 ! -name 'marker.txt' -print -quit 2>/dev/null)" ] || fail "clone was nested inside concurrently created directory (GNU path)"
[ -z "$(find "${WORKSPACES}" -name '.bootstrap-*' -print -quit 2>/dev/null)" ] || fail "temporary clone directory was not cleaned up after publish skip (GNU path)"

# 5b: Non-GNU fallback path with detect-and-undo (forced via RELATED_REPOS_MV_ATOMIC=0)
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
rc=0
RELATED_REPOS_MV_ATOMIC=0 STUB_MV="concurrent-dir" run_sut auth-ok >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "script must exit 0 when target created concurrently (fallback path)"
[ -f "${WORKSPACES}/test-repo/marker.txt" ] || fail "user checkout was deleted or clobbered by bootstrap (fallback path)"
[ -z "$(find "${WORKSPACES}/test-repo" -mindepth 1 ! -name 'marker.txt' -print -quit 2>/dev/null)" ] || fail "clone was nested inside concurrently created directory (fallback path)"
[ -z "$(find "${WORKSPACES}" -name '.bootstrap-*' -print -quit 2>/dev/null)" ] || fail "temporary clone directory was not cleaned up after publish skip (fallback path)"

# 5c: an mv whose --version fails (non-GNU) must select the fallback publish, never `mv -T`
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
mv_log="${TMP}/mv-no-version.log"
rm -f "${mv_log}"
rc=0
STUB_MV="no-version" STUB_MV_LOG="${mv_log}" run_sut auth-ok >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "script must exit 0 when mv --version fails (non-GNU mv)"
[ -d "${WORKSPACES}/test-repo/.git" ] || fail "repo was not published via the fallback path when mv --version fails"
grep -q -- '--version' "${mv_log}" || fail "expected the script to probe mv --version"
if grep -Eq '(^| )-T( |$)' "${mv_log}"; then
    fail "mv -T used although mv --version failed; expected the fallback publish path"
fi

# --- Test 6: Plain file at target is left intact and publish fails safely ---
echo "==> plain file at target is left intact"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
rc=0
STUB_MV="concurrent-file" run_sut auth-ok >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "script must exit 0 when target is a plain file"
[ -f "${WORKSPACES}/test-repo" ] || fail "target plain file was removed"
[ "$(cat "${WORKSPACES}/test-repo")" = "user-plain-file" ] || fail "target plain file was overwritten"
[ -z "$(find "${WORKSPACES}" -name '.bootstrap-*' -print -quit 2>/dev/null)" ] || fail "temporary directory was not cleaned up when target is a plain file"

# --- Test 7: Branch suffix is preserved during fallback ---
echo "==> branch suffix is preserved during fallback"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo@feature-branch" >"${CONFIG}"
run_sut unauthenticated
[ -d "${WORKSPACES}/test-repo/.git" ] || fail "expected repo to be cloned"
current_branch="$(git -C "${WORKSPACES}/test-repo" rev-parse --abbrev-ref HEAD)"
[ "$current_branch" = "feature-branch" ] || fail "expected branch feature-branch, got $current_branch"

# --- Test 8: Orphaned temporary directories inside the staging directory are reaped; foreign ones are not ---
echo "==> orphaned temporary directories in the staging directory are reaped, foreign .bootstrap-* directories are not"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
: >"${CONFIG}"
dead_pid=999999
while kill -0 "$dead_pid" 2>/dev/null; do
    dead_pid=$((dead_pid + 1))
done
STAGE="${WORKSPACES}/.related-repos-bootstrap"
mkdir -p "${STAGE}"
chmod 700 "${STAGE}" # private, whatever the ambient umask
mkdir -p "${STAGE}/.bootstrap-orphan-dead.${dead_pid}.111111"
mkdir -p "${STAGE}/.bootstrap-orphan-live.$$.222222"
mkdir -p "${STAGE}/.bootstrap-orphan-stale-live.$$.333333"
python3 -c "import os, time; [os.utime(p, (time.time() - 7200, time.time() - 7200)) for p in ['${STAGE}/.bootstrap-orphan-dead.${dead_pid}.111111', '${STAGE}/.bootstrap-orphan-live.$$.222222']]"
python3 -c "import os, time; os.utime('${STAGE}/.bootstrap-orphan-stale-live.$$.333333', (time.time() - 172800, time.time() - 172800))"
# Foreign directories in the target (the checkout's parent is a general-purpose
# directory) that merely look like ours: neither the 24h rule nor the dead-PID
# rule may touch them.
mkdir -p "${WORKSPACES}/.bootstrap-foo" "${WORKSPACES}/.bootstrap-foreign-dead.${dead_pid}.444444"
echo "keep" >"${WORKSPACES}/.bootstrap-foo/user-data.txt"
python3 -c "import os, time; [os.utime(p, (time.time() - 172800, time.time() - 172800)) for p in ['${WORKSPACES}/.bootstrap-foo', '${WORKSPACES}/.bootstrap-foreign-dead.${dead_pid}.444444']]"
out="$(run_sut auth-ok 2>&1)"
[ ! -d "${STAGE}/.bootstrap-orphan-dead.${dead_pid}.111111" ] || fail "old orphan directory with dead PID should have been reaped"
[ -d "${STAGE}/.bootstrap-orphan-live.$$.222222" ] || fail "old directory with live PID must not be reaped"
[ ! -d "${STAGE}/.bootstrap-orphan-stale-live.$$.333333" ] || fail "directory older than 24h must be reaped unconditionally even with live PID"
[ -f "${WORKSPACES}/.bootstrap-foo/user-data.txt" ] || fail "a foreign .bootstrap-* directory older than a day must survive"
[ -d "${WORKSPACES}/.bootstrap-foreign-dead.${dead_pid}.444444" ] || fail "a foreign .bootstrap-* directory with a dead-PID name must survive"
case "$out" in
*"Removing orphaned temporary bootstrap directory"*) ;;
*) fail "expected log message for reaped orphan directory, got: $out" ;;
esac
case "$out" in
*"Removing stale temporary bootstrap directory"*) ;;
*) fail "expected log message for 24h stale orphan directory, got: $out" ;;
esac
rm -rf "${STAGE}/.bootstrap-orphan-live.$$.222222"

echo "==> the staging directory is private and never a symlink or a file"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
STUB_MKTEMP_LOG="${TMP}/mktemp.log"
rm -f "${STUB_MKTEMP_LOG}"
export STUB_MKTEMP_LOG
run_sut auth-ok >/dev/null 2>&1
unset STUB_MKTEMP_LOG
[ -s "${TMP}/mktemp.log" ] || fail "expected the clone to create a temporary directory"
grep -qv "${WORKSPACES}/.related-repos-bootstrap/" "${TMP}/mktemp.log" && fail "every temporary clone directory must live in the staging directory: $(cat "${TMP}/mktemp.log")"
mode="$(stat -c %a "${WORKSPACES}/.related-repos-bootstrap" 2>/dev/null || stat -f %Lp "${WORKSPACES}/.related-repos-bootstrap")"
[ "$mode" = "700" ] || fail "staging directory must be created with mode 0700, got ${mode}"
[ -d "${WORKSPACES}/test-repo/.git" ] || fail "clone must be published from the staging directory into the target"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}" "${TMP}/elsewhere"
ln -s "${TMP}/elsewhere" "${WORKSPACES}/.related-repos-bootstrap"
rc=0
run_sut auth-ok >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] || fail "a symlinked staging directory is a warning, not a failure"
[ ! -e "${WORKSPACES}/test-repo" ] || fail "must not clone through a symlinked staging directory"
[ -z "$(ls -A "${TMP}/elsewhere")" ] || fail "must not write through a symlinked staging directory"

echo "==> a group-writable staging directory is refused: warning, no clones, directory untouched"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}/.related-repos-bootstrap"
chmod 770 "${WORKSPACES}/.related-repos-bootstrap"
mkdir "${WORKSPACES}/.related-repos-bootstrap/.bootstrap-planted"
echo "test-owner/test-repo" >"${CONFIG}"
rc=0
out="$(run_sut auth-ok 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "an unsafe staging directory is a warning, not a failure"
case "$out" in
*"group- or world-writable; skipping"*) ;;
*) fail "expected the group-writable warning, got: $out" ;;
esac
[ ! -e "${WORKSPACES}/test-repo" ] || fail "must not clone when the staging directory is group-writable"
[ -d "${WORKSPACES}/.related-repos-bootstrap/.bootstrap-planted" ] || fail "the refused staging directory must be untouched"
[ "$(ls -A "${WORKSPACES}/.related-repos-bootstrap")" = ".bootstrap-planted" ] || fail "nothing may be written to a refused staging directory"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}/.related-repos-bootstrap"
chmod 707 "${WORKSPACES}/.related-repos-bootstrap"
out="$(run_sut auth-ok 2>&1)" || fail "a world-writable staging directory is a warning, not a failure"
case "$out" in
*"group- or world-writable; skipping"*) ;;
*) fail "expected the world-writable warning, got: $out" ;;
esac
[ ! -e "${WORKSPACES}/test-repo" ] || fail "must not clone when the staging directory is world-writable"

# --- Test 9: post-start-common.sh starts bootstrap-related-repos.sh detached ---
echo "==> post-start-common.sh starts bootstrap-related-repos.sh detached"
# SIGHUP is ignored in the PARENT before the fork (inherited across fork and exec, so
# the child is immune from its first instruction), then restored after the launches:
#   trap '' HUP
#   bash .devcontainer/scripts/bootstrap-related-repos.sh </dev/null >>log 2>&1 &
#   bash .devcontainer/scripts/fetch-related-repos.sh </dev/null >>log 2>&1 &
#   trap - HUP
# nohup and a HUP-ignoring subshell are the old, window-leaving forms and must not return.
# detach_form_ok FILE — the awk state machine that pins that form, as a function so the checks below
# can run it over doctored copies. HUP is ignored only by the two quoted forms:
# `trap -- HUP` RESETS the disposition, so a pattern that accepted "any two
# characters" there would pass a script that no longer protects the job. The nohup
# rule skips comment lines, like every other rule here, so a reworded comment
# cannot fail the test.
detach_form_ok() {
    awk -v sq="'" '
    function joined(   line, next_line) {
        line = $0
        while (line ~ /\\$/) {
            sub(/\\$/, "", line)
            if ((getline next_line) > 0) {
                line = line next_line
            } else {
                break
            }
        }
        return line
    }
    $0 ~ ("^[[:space:]]*trap (" sq sq "|\"\") HUP[[:space:]]*$") { state = 1; next }
    state == 1 && /^[[:space:]]*bash \.devcontainer\/scripts\/bootstrap-related-repos\.sh/ {
        line = joined()
        if (line ~ /<[[:space:]]*\/dev\/null/ && line ~ /&[[:space:]]*$/) { state = 2; next }
        state = 0
        next
    }
    state == 2 && /^[[:space:]]*bash \.devcontainer\/scripts\/fetch-related-repos\.sh/ {
        line = joined()
        if (line ~ /<[[:space:]]*\/dev\/null/ && line ~ /&[[:space:]]*$/) { state = 3; next }
        state = 0
        next
    }
    state == 3 && /^[[:space:]]*trap - HUP[[:space:]]*$/ { matched = 1; state = 0; next }
    /[^[:space:]]/ && !/^[[:space:]]*#/ { state = 0 }
    !/^[[:space:]]*#/ && /nohup .*(bootstrap|fetch)-related-repos/ { nohup_seen = 1 }
    END {
        exit (!matched || nohup_seen)
    }' "$1"
}
detach_form_ok .devcontainer/scripts/post-start-common.sh ||
    fail "expected post-start-common.sh to ignore SIGHUP in the parent (trap '' HUP), start bootstrap and fetch detached with </dev/null and a trailing &, then restore (trap - HUP), without nohup"

# The checks above are only worth anything if the form can fail: doctor a copy of
# the real file each way and require the verdict to follow. `trap -- HUP` must be
# rejected (it resets, not ignores); a comment that merely mentions nohup must not be.
sed 's/^trap '"''"' HUP$/trap -- HUP/' .devcontainer/scripts/post-start-common.sh >"${TMP}/start-reset.sh"
grep -q '^trap -- HUP$' "${TMP}/start-reset.sh" || fail "test setup: the HUP-reset mutation did not apply"
if detach_form_ok "${TMP}/start-reset.sh"; then
    fail "Test 9 accepted 'trap -- HUP', which resets SIGHUP rather than ignoring it"
fi
{
    echo "# nohup bootstrap-related-repos.sh was the old form"
    cat .devcontainer/scripts/post-start-common.sh
} >"${TMP}/start-comment.sh"
detach_form_ok "${TMP}/start-comment.sh" ||
    fail "Test 9 failed on a comment line that merely mentions nohup"
{
    cat .devcontainer/scripts/post-start-common.sh
    echo "nohup bash .devcontainer/scripts/bootstrap-related-repos.sh &"
} >"${TMP}/start-nohup.sh"
if detach_form_ok "${TMP}/start-nohup.sh"; then
    fail "Test 9 accepted a live nohup invocation of the bootstrap"
fi

# --- Test 10: mktemp failure does not abort script under set -e ---
echo "==> mktemp failure does not abort script under set -e"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
rc=0
out="$(STUB_MKTEMP=fail run_sut auth-ok 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "script must exit 0 when mktemp fails"
case "$out" in
*"WARNING: failed to create temporary directory"*) ;;
*) fail "expected warning when mktemp fails, got: $out" ;;
esac
case "$out" in
*"Bootstrap complete: 0 cloned, 0 skipped, 1 failed"*) ;;
*) fail "expected 1 failed in summary when mktemp fails, got: $out" ;;
esac

# --- Test 11: fallback URL derives from GH_HOST when base URL unset ---
echo "==> fallback URL derives from GH_HOST when base URL unset"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
GIT_LOG="${TMP}/git-host.log"
rm -f "${GIT_LOG}"
export GIT_LOG
TEST_UNSET_BASE_URL=1 GH_HOST="github.mycompany.internal" run_sut unauthenticated >/dev/null 2>&1 || true
[ -f "${GIT_LOG}" ] || fail "expected git to be invoked for fallback"
if ! grep -q "https://github.mycompany.internal/test-owner/test-repo.git" "${GIT_LOG}"; then
    fail "expected clone from derived GH_HOST, got: $(cat "${GIT_LOG}")"
fi

# 11b: no GH_HOST, no base URL: the host comes from the checkout's origin remote
# (both URL forms), and github.com only when there is no origin at all. The script
# is copied into a throwaway repo so its origin is under the test's control.
echo "==> fallback URL derives from the origin remote host when GH_HOST is unset"
ORIGIN_FIXTURE="${TMP}/origin-fixture"
mkdir -p "${ORIGIN_FIXTURE}/.devcontainer/scripts"
cp "${SUT}" "${ORIGIN_FIXTURE}/.devcontainer/scripts/bootstrap-related-repos.sh"
"${REAL_GIT}" -C "${ORIGIN_FIXTURE}" init -q
origin_cases="https://ghe-https.example.com/o/r.git|ghe-https.example.com
ssh://git@ghe-ssh.example.com:2222/o/r.git|ghe-ssh.example.com
git@ghe-scp.example.com:o/r.git|ghe-scp.example.com
ghe.example.com:owner/repo.git|ghe.example.com
/srv/git/o:r.git|github.com
C:/src/repo|github.com
/srv/git/a@b:c/r.git|github.com
demo::some-address|github.com
x+y::path|github.com
demo::https://internal.example/o/r|github.com
+demo::path|+demo
git@ghe.example.com:owner/repo::backup|ghe.example.com
ghe-colons.example.com:owner::x/repo.git|ghe-colons.example.com
[2001:db8::1]:owner/repo.git|[2001:db8::1]
[2001:db8:0:0:0:0:0:1]:owner/repo.git|[2001:db8:0:0:0:0:0:1]
git@[2001:db8::1]:owner/repo.git|[2001:db8::1]
[2001:db8::1:owner/repo.git|github.com
/srv/git/a@[2001:db8::1]:r.git|github.com
https://ghe-port.example.com:8443/o/r.git|ghe-port.example.com:8443
https://user@ghe-user.example.com:8443/o/r@v1.git|ghe-user.example.com:8443
|github.com"
while IFS='|' read -r origin_url expected_host; do
    "${REAL_GIT}" -C "${ORIGIN_FIXTURE}" config --unset remote.origin.url 2>/dev/null || true
    [ -z "${origin_url}" ] || "${REAL_GIT}" -C "${ORIGIN_FIXTURE}" config remote.origin.url "${origin_url}"
    rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
    GIT_LOG="${TMP}/git-origin.log"
    rm -f "${GIT_LOG}"
    export GIT_LOG
    # A subshell, so SUT (and the unset) cannot outlive this call: prefix
    # assignments on a shell function call are not reliably scoped to it.
    (
        SUT="${ORIGIN_FIXTURE}/.devcontainer/scripts/bootstrap-related-repos.sh"
        TEST_UNSET_BASE_URL=1
        run_sut unauthenticated
    ) >/dev/null 2>&1 || true
    [ -f "${GIT_LOG}" ] || fail "expected git to be invoked for fallback (origin '${origin_url}')"
    # Fixed-string match: an IPv6 authority's brackets are regex syntax.
    grep -F "https://${expected_host}/test-owner/test-repo.git" "${GIT_LOG}" | grep clone >/dev/null ||
        fail "expected clone from origin host ${expected_host} (origin '${origin_url}'), got: $(cat "${GIT_LOG}")"
done <<EOF
${origin_cases}
EOF

# --- Test 12: invalid RELATED_REPOS_MV_ATOMIC warns and falls back ---
echo "==> invalid RELATED_REPOS_MV_ATOMIC warns and falls back"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
out="$(RELATED_REPOS_MV_ATOMIC=invalid run_sut auth-ok 2>&1)"
case "$out" in
*"WARNING: invalid RELATED_REPOS_MV_ATOMIC='invalid'"*) ;;
*) fail "expected warning for invalid RELATED_REPOS_MV_ATOMIC, got: $out" ;;
esac
[ -d "${WORKSPACES}/test-repo/.git" ] || fail "clone should succeed despite invalid override"

# --- Test 13: publish failure when target does not exist counts as failed ---
echo "==> publish failure when target does not exist counts as failed"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
rc=0
out="$(STUB_MV=fail-publish run_sut auth-ok 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "script must exit 0 on publish failure"
case "$out" in
*"WARNING: failed to publish test-repo to ${WORKSPACES}/test-repo (exit 5)"*) ;;
*) fail "expected failed to publish warning with exit code, got: $out" ;;
esac
case "$out" in
*"simulated I/O error during publish"*) ;;
*) fail "expected mv's stderr in the publish-failure warning, got: $out" ;;
esac
case "$out" in
*"Bootstrap complete: 0 cloned, 0 skipped, 1 failed"*) ;;
*) fail "expected 1 failed in summary on publish failure, got: $out" ;;
esac

# --- Test 14: a signal stops the bootstrap; it must not keep cloning the remaining entries ---
# INT is what an operator sends to the foreground post-create call; TERM and HUP
# are what teardown sends. Each must terminate with the conventional 128+n status,
# after exactly one clone attempt, leaving no temporary directory behind.
# job control is switched on around the launch: a non-interactive shell starts an
# async job with SIGINT ignored, and a signal ignored at entry cannot be trapped,
# which would test the harness instead of the script.
signal_case() {
    local sig="$1" want="$2"
    echo "==> ${sig} terminates the bootstrap and cleans up its temporary directory"
    rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
    printf '%s\n' "test-owner/test-repo" "test-owner/second-repo" >"${CONFIG}"
    make_stub unauthenticated
    local clone_log="${TMP}/clone-${sig}.log"
    rm -f "${clone_log}"
    set -m
    PATH="${BIN_DIR}:${PATH}" WORKSPACES_DIR="${WORKSPACES}" CONFIG_FILE="${CONFIG}" \
        RELATED_REPOS_GIT_BASE_URL="file://${BARE_BASE}/" \
        STUB_GIT_CLONE_SLEEP=3 STUB_GIT_CLONE_LOG="${clone_log}" \
        bash "${SUT}" >/dev/null 2>&1 &
    local sut_pid=$!
    set +m
    local waited=0
    while [ ! -s "${clone_log}" ] && [ "$waited" -lt 100 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    [ -s "${clone_log}" ] || {
        kill -TERM "$sut_pid" 2>/dev/null || true
        fail "first clone never started (${sig})"
    }
    kill -"${sig}" "$sut_pid"
    local rc=0
    wait "$sut_pid" || rc=$?
    [ "$rc" -eq "$want" ] || fail "expected exit ${want} after ${sig}, got $rc"
    [ "$(wc -l <"${clone_log}" | tr -d ' ')" -eq 1 ] || fail "${sig} must stop the loop; clones attempted: $(cat "${clone_log}")"
    [ -z "$(find "${WORKSPACES}" -name '.bootstrap-*' -print -quit 2>/dev/null)" ] || fail "temporary directory was not cleaned up after ${sig}"
    return 0
}
signal_case TERM 143
signal_case INT 130
signal_case HUP 129

# --- Test 15: the target directory is a positional argument ---
echo "==> the target directory argument wins over WORKSPACES_DIR"
rm -rf "${WORKSPACES}" "${TMP}/arg-target" && mkdir -p "${WORKSPACES}" "${TMP}/arg-target"
echo "test-owner/test-repo" >"${CONFIG}"
(
    make_stub unauthenticated
    export PATH="${BIN_DIR}:${PATH}"
    export WORKSPACES_DIR="${WORKSPACES}" # the decoy the argument must beat
    export CONFIG_FILE="${CONFIG}"
    export RELATED_REPOS_GIT_BASE_URL="file://${BARE_BASE}/"
    bash "${SUT}" "${TMP}/arg-target" >/dev/null
)
[ -d "${TMP}/arg-target/test-repo/.git" ] || fail "expected the clone in the argument directory"
[ ! -e "${WORKSPACES}/test-repo" ] || fail "the argument must win over WORKSPACES_DIR"

echo "==> the staging directory is created 0700 whatever the umask or a parent ACL does"
rm -rf "${WORKSPACES}" && mkdir -p "${WORKSPACES}"
echo "test-owner/test-repo" >"${CONFIG}"
(
    umask 000                                           # inherited umask
    STUB_MKDIR_MODE=775 run_sut auth-ok >/dev/null 2>&1 # a default ACL widening what the umask made
)
mode="$(stat -c %a "${WORKSPACES}/.related-repos-bootstrap" 2>/dev/null || stat -f %Lp "${WORKSPACES}/.related-repos-bootstrap")"
[ "$mode" = "700" ] || fail "the created staging directory must be 0700 despite umask 000 and a widening ACL, got ${mode}"
[ -d "${WORKSPACES}/test-repo/.git" ] || fail "a staging directory this run created and fixed to 0700 must be used"

echo "==> a trailing slash on the target is normalized once"
rm -rf "${TMP}/slash-target" && mkdir -p "${TMP}/slash-target"
STUB_MKTEMP_LOG="${TMP}/mktemp-slash.log"
rm -f "${STUB_MKTEMP_LOG}"
export STUB_MKTEMP_LOG
(
    make_stub auth-ok
    export PATH="${BIN_DIR}:${PATH}"
    unset WORKSPACES_DIR
    export CONFIG_FILE="${CONFIG}"
    export RELATED_REPOS_GIT_BASE_URL="file://${BARE_BASE}/"
    bash "${SUT}" "${TMP}/slash-target/" >/dev/null 2>&1
)
unset STUB_MKTEMP_LOG
[ -d "${TMP}/slash-target/test-repo/.git" ] || fail "a target with a trailing slash must be cloned into"
grep -q '//' "${TMP}/mktemp-slash.log" && fail "a trailing slash must not leave a double slash in derived paths: $(cat "${TMP}/mktemp-slash.log")"
grep -q "${TMP}/slash-target/.related-repos-bootstrap/" "${TMP}/mktemp-slash.log" || fail "the staging directory must derive from the normalized target: $(cat "${TMP}/mktemp-slash.log")"

echo "==> the default target stays /workspaces and the devcontainer call sites pass no argument"
grep -q 'WORKSPACES_DIR="${1:-${WORKSPACES_DIR:-/workspaces}}"' "${SUT}" || fail "the default target must remain /workspaces"
for site in .devcontainer/scripts/post-create-common.sh .devcontainer/scripts/post-start-common.sh; do
    calls="$(grep 'bootstrap-related-repos\.sh' "$site" | grep -v '^[[:space:]]*#' || true)"
    [ -n "$calls" ] || fail "$site no longer calls bootstrap-related-repos.sh"
    if grep -Eq 'bootstrap-related-repos\.sh[[:space:]]+[^[:space:]&;|)<>]' <<<"$calls"; then
        fail "$site must call bootstrap-related-repos.sh without a target argument (so it targets /workspaces)"
    fi
done

echo "test-bootstrap-related-repos.sh passed"
