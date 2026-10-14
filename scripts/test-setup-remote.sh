#!/usr/bin/env bash
# test-setup-remote.sh — test `task setup:remote` end to end in a fixture repo:
# idempotency, the lefthook shim, frozen dependency installs, and sibling clones
# into the checkout's parent directory (stubbed lefthook/pnpm/uv/gh and a local
# bare repository as the sibling — no network).
#
# Run via `task test:setup-remote`.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST
unset GIT_SSH_COMMAND # a host may set one; the default (unset) case is what is under test
unset NODE_OPTIONS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
# Hermetic git: a platform may inject config (SSH->HTTPS rewrites, hooks paths).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# scripts/setup-remote.sh resolves the checkout with pwd -P (physical); a
# symlinked TMPDIR such as macOS's /var would otherwise make the printed and
# asserted paths differ (#1457).
# Two steps, each stopped by its own || exit 1 (not left to set -e): one
# command, cd "$(mktemp -d)", would swallow a failed mktemp and `cd ""` would
# resolve the checkout itself as the directory the trap removes.
TMP="$(mktemp -d)" || exit 1
TMP="$(cd "${TMP}" && pwd -P)" || exit 1
# A scenario may chmod a directory read-only; restore write access before removing it.
trap 'chmod -R u+w "${TMP}" 2>/dev/null; rm -rf "${TMP}"' EXIT

fail() { # shell-robustness: ok — this reporter always exits 1
    echo "TEST FAIL: $*" >&2
    exit 1
}

# --- A local bare repository standing in for a sibling on GitHub ---
BARE_BASE="${TMP}/bare-upstream"
mkdir -p "${BARE_BASE}/test-owner"
for name in sibling-a sibling-b; do
    git init -q --bare -b main "${BARE_BASE}/test-owner/${name}.git"
    git clone -q "${BARE_BASE}/test-owner/${name}.git" "${TMP}/seed-${name}" 2>/dev/null
    git -C "${TMP}/seed-${name}" -c user.name=Test -c user.email=test@example.com \
        commit -q --allow-empty -m "initial commit"
    git -C "${TMP}/seed-${name}" push -q origin HEAD:main 2>/dev/null
done

# --- A PATH holding only the tools the task needs, so a real lefthook/pnpm/uv on
# the host cannot leak into (or be missing from) a scenario. ---
MIN_BIN="${TMP}/minbin"
mkdir -p "${MIN_BIN}"
for tool in bash env git task dirname basename mktemp mv rm mkdir find cat sed grep sort cksum \
    xargs kill sleep uname head tr wc cp chmod ln touch id printf ls date; do
    src="$(command -v "$tool" 2>/dev/null || true)"
    [ -n "$src" ] && [ -x "$src" ] && ln -sf "$src" "${MIN_BIN}/${tool}"
done
REAL_LEFTHOOK="$(command -v lefthook 2>/dev/null || true)"

STUB_BIN="${TMP}/stubs"
LOG_DIR="${TMP}/logs"
mkdir -p "${STUB_BIN}" "${LOG_DIR}"

# lefthook: installs a pre-push shim only when it is missing or different.
cat >"${STUB_BIN}/lefthook" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LOG_DIR}/lefthook.log"
[ "${STUB_LEFTHOOK:-}" = "fail" ] && { echo "lefthook: simulated failure" >&2; exit 1; }
[ "${1:-}" = "install" ] || exit 2
hook=.git/hooks/pre-push
body='#!/bin/sh
# lefthook shim (stub)
exec lefthook run pre-push "$@"'
mkdir -p .git/hooks
if [ ! -f "$hook" ] || [ "$(cat "$hook")" != "$body" ]; then
    printf '%s\n' "$body" >"$hook"
    chmod +x "$hook"
fi
EOF
for tool in pnpm uv; do
    cat >"${STUB_BIN}/${tool}" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"\${STUB_LOG_DIR}/${tool}.log"
echo "\${CI-unset}" >>"\${STUB_LOG_DIR}/${tool}.ci"
[ "\${STUB_STRAY_STATUS:-}" != 1 ] || echo '==> setup:remote completed with warnings: stray tool output'
if [ -n "\${EXPECTED_SIBLING:-}" ]; then
    [ -d "\${EXPECTED_SIBLING}/.git" ] || exit 98
    [ "\$(git -C "\$EXPECTED_SIBLING" rev-parse origin/main)" = "\$EXPECTED_SIBLING_HEAD" ] || exit 97
fi
exit 0
EOF
done
# gh: authenticated; clones owner/repo from the local bare repository or fails.
cat >"${STUB_BIN}/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"\${STUB_LOG_DIR}/gh.log"
if [ "\$1" = "auth" ] && [ "\$2" = "status" ]; then exit 0; fi
if [ "\$1" = "repo" ] && [ "\$2" = "clone" ]; then
    upstream="${BARE_BASE}/\$3.git"
    [ -d "\$upstream" ] || { echo "gh: repository \$3 not found" >&2; exit 1; }
    exec git clone --quiet "\$upstream" "\$4"
fi
echo "unexpected gh call: \$*" >&2
exit 1
EOF
# git: refuse any network URL so a regression cannot reach out.
REAL_GIT="$(command -v git)"
cat >"${STUB_BIN}/git" <<EOF
#!/usr/bin/env bash
[ -z "\${STUB_LOG_DIR:-}" ] || echo "\${GIT_SSH_COMMAND-unset}" >>"\${STUB_LOG_DIR}/git-ssh.log"
for arg in "\$@"; do
    if [ "\$arg" = fetch ] && [ "\${STUB_FETCH_FAIL_DIR:-}" = "\${2:-}" ]; then
        echo "simulated fetch failure" >&2
        exit 1
    fi
    case "\$arg" in
    http://* | https://* | ssh://* | git@*)
        echo "ERROR: network URL attempted in offline test: \$arg" >&2
        exit 99
        ;;
    esac
done
# Transport-only fixture rewrite: identity queries still see the network URL,
# while fetch itself stays offline. Real insteadOf identity tests are separate.
if [ "\${3:-}" = fetch ] && [ -n "\${STUB_NETWORK_FETCH_BASE:-}" ]; then
    exec "${REAL_GIT}" \
        -c "url.file://\${STUB_NETWORK_FETCH_BASE}/test-owner/sibling-a.git.insteadOf=https://example.test/test-owner/SIBLING-a" \
        -c "url.file://\${STUB_NETWORK_FETCH_BASE}/test-owner/.insteadOf=https://example.test/TEST-owner/" \
        -c "url.file://\${STUB_NETWORK_FETCH_BASE}/.insteadOf=https://example.test/" "\$@"
fi
exec "${REAL_GIT}" "\$@"
EOF
chmod +x "${STUB_BIN}"/*

# A repository generated without a devcontainer ships setup:remote (and this test)
# but not the bootstrap script: the sibling-clone scenarios then cannot run, and the
# task is expected to say it skipped the related repos.
HAVE_BOOTSTRAP=0
if [ -f "${REPO_ROOT}/.devcontainer/scripts/bootstrap-related-repos.sh" ]; then
    HAVE_BOOTSTRAP=1
else
    echo "skip: .devcontainer/scripts/bootstrap-related-repos.sh is absent; the sibling-clone scenarios are skipped"
fi

# make_fixture <name> <related-repos.txt content|-> — a git repository standing in
# for a rendered template repo, one directory below a writable parent. The real
# scripts are copied in; the Taskfile is the repository's own (run via -t/-d).
make_fixture() {
    local name="$1" related="$2"
    FIX_PARENT="${TMP}/${name}"
    FIX="${FIX_PARENT}/checkout"
    mkdir -p "${FIX}/scripts" "${FIX}/.devcontainer/scripts"
    git init -q "${FIX}"
    cp "${REPO_ROOT}/scripts/setup-remote.sh" "${FIX}/scripts/setup-remote.sh"
    cp "${REPO_ROOT}/scripts/session-start-remote.sh" "${FIX}/scripts/session-start-remote.sh"
    if [ "$HAVE_BOOTSTRAP" = 1 ]; then
        cp "${REPO_ROOT}/.devcontainer/scripts/bootstrap-related-repos.sh" "${FIX}/.devcontainer/scripts/"
        cp "${REPO_ROOT}/.devcontainer/scripts/fetch-related-repos.sh" "${FIX}/.devcontainer/scripts/"
    fi
    printf 'pre-push:\n  commands:\n    noop:\n      run: "true"\n' >"${FIX}/lefthook.yml"
    if [ "$related" != "-" ]; then
        printf '%s\n' "$related" >"${FIX}/.devcontainer/related-repos.txt"
    fi
}

# run_setup <path-dirs> [ENV=val ...] — `task setup:remote` in $FIX; sets rc, OUT, ERR.
run_setup() {
    local pathdirs="$1"
    shift
    rc=0
    OUT="${TMP}/out.txt"
    ERR="${TMP}/err.txt"
    (
        cd "${FIX}"
        export PATH="${pathdirs}"
        export STUB_LOG_DIR="${LOG_DIR}"
        export RELATED_REPOS_GIT_BASE_URL="file://${BARE_BASE}/"
        for kv in "$@"; do export "$kv"; done
        task --silent -t "${REPO_ROOT}/Taskfile.yml" -d "${RUN_DIR:-${FIX}}" setup:remote
    ) >"${OUT}" 2>"${ERR}" || rc=$?
}

# all_output — both streams: task's grouped output folds stderr into stdout.
all_output() { cat "${OUT}" "${ERR}"; }

# output_has <pattern> — grep the captured files directly: piping a writer into
# grep -q under pipefail can fail on SIGPIPE although the text is present (#1508).
output_has() { grep -q -- "$1" "${OUT}" "${ERR}"; }

# digest <dir> — every path and every file's content, so "changes nothing" means it.
digest() {
    (cd "$1" && find . | LC_ALL=C sort && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 cksum)
}

# The uncloneable entry comes first so a later entry proves the run continues.
RELATED='test-owner/missing-repo
test-owner/sibling-a # inline comments are ignored
test-owner/existing-repo
test-owner/sibling-b@main'

STUBS_PATH="${STUB_BIN}:${MIN_BIN}"

# --- Scenario 1+2: first run prepares the checkout, second run changes nothing ---
echo "==> task setup:remote prepares a checkout and its siblings"
make_fixture main "$RELATED"
mkdir -p "${FIX_PARENT}/existing-repo"
echo "custom-content" >"${FIX_PARENT}/existing-repo/marker.txt"
rm -f "${LOG_DIR}"/*.log
run_setup "${STUBS_PATH}"
[ "$rc" -eq 0 ] || fail "first run must succeed (rc=$rc): $(all_output)"
if [ "$HAVE_BOOTSTRAP" = 1 ]; then
    [ -d "${FIX_PARENT}/sibling-a/.git" ] || fail "sibling-a must be cloned into the checkout's parent"
    [ -d "${FIX_PARENT}/sibling-b/.git" ] || fail "sibling-b (listed after the failing entry) must be cloned: the run continues"
    [ ! -e "${FIX_PARENT}/missing-repo" ] || fail "an uncloneable repository must leave nothing behind"
    [ "$(cat "${FIX_PARENT}/existing-repo/marker.txt")" = "custom-content" ] || fail "an existing directory must not be modified"
    [ ! -d "${FIX_PARENT}/existing-repo/.git" ] || fail "an existing directory must not be cloned over"
    [ -z "$(find "${FIX_PARENT}" -name '.bootstrap-*' -print -quit)" ] || fail "no temporary bootstrap directory may survive"
    output_has 'WARNING: failed to clone test-owner/missing-repo' || fail "the uncloneable repository must produce a warning: $(all_output)"
    output_has "Skipping existing-repo" || fail "the existing directory must be reported as skipped"
    output_has "cloned into ${FIX_PARENT}" || fail "the task must print where it cloned"
    output_has 'reference context' || fail "the task must say siblings are reference context"
    output_has 'private to you' || fail "the task must state that the target directory must be private to the user"
    [ -s "${LOG_DIR}/git-ssh.log" ] || fail "expected git to be invoked with GIT_SSH_COMMAND recorded"
    [ "$(sort -u "${LOG_DIR}/git-ssh.log")" = "ssh -oBatchMode=yes" ] || fail "git must run with GIT_SSH_COMMAND=\"ssh -oBatchMode=yes\" (so an ssh remote cannot prompt), got: $(sort -u "${LOG_DIR}/git-ssh.log")"
    output_has "session's own repository" || fail "the task must say siblings cannot be pushed from Claude Code on the web"
else
    output_has 'is not present in this repository' || fail "without the bootstrap script the task must report the related repos as skipped: $(all_output)"
    [ -z "$(find "${FIX_PARENT}" -mindepth 1 -maxdepth 1 ! -name checkout ! -name existing-repo -print -quit)" ] || fail "nothing may be cloned without the bootstrap script"
fi

echo "==> .git/hooks/pre-push is the lefthook shim"
[ -x "${FIX}/.git/hooks/pre-push" ] || fail "pre-push must be installed and executable"
grep -q 'lefthook' "${FIX}/.git/hooks/pre-push" || fail "pre-push must be the lefthook shim"

echo "==> a second run succeeds and changes nothing"
before="$(digest "${FIX_PARENT}")"
run_setup "${STUBS_PATH}"
[ "$rc" -eq 0 ] || fail "second run must succeed (rc=$rc): $(all_output)"
after="$(digest "${FIX_PARENT}")"
[ "$before" = "$after" ] || fail "the second run changed the tree:
$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)"
[ "$(wc -l <"${LOG_DIR}/lefthook.log" | tr -d ' ')" -eq 2 ] || fail "lefthook install must run on each invocation (idempotent, not skipped)"

if [ "$HAVE_BOOTSTRAP" = 1 ]; then
    echo "==> a cached sibling is fetched forward without changing its checkout"
    sibling="${FIX_PARENT}/sibling-a"
    old_head="$(git -C "$sibling" rev-parse HEAD)"
    echo 'local work' >"${sibling}/local-work.txt"
    git -C "${TMP}/seed-sibling-a" -c user.name=Test -c user.email=test@example.com \
        commit -q --allow-empty -m 'new upstream commit'
    git -C "${TMP}/seed-sibling-a" push -q origin HEAD:main
    new_head="$(git -C "${TMP}/seed-sibling-a" rev-parse HEAD)"
    run_setup "${STUBS_PATH}"
    [ "$rc" -eq 0 ] || fail "fetch-forward run must succeed: $(all_output)"
    [ "$(git -C "$sibling" rev-parse origin/main)" = "$new_head" ] || fail "existing sibling must see new upstream commit"
    [ "$(git -C "$sibling" rev-parse HEAD)" = "$old_head" ] || fail "fetch must not move the checkout"
    [ "$(cat "${sibling}/local-work.txt")" = 'local work' ] || fail "fetch must preserve local work"
    output_has '^  + related-repo fetch -> .* (warn-only)' || fail "fetch must appear in the setup summary: $(all_output)"
    output_has 'Related-repo fetch: 2 fetched' || fail "fetch summary must report both siblings: $(all_output)"

    echo "==> a sibling fetch failure warns and does not fail preparation"
    run_setup "${STUBS_PATH}" "STUB_FETCH_FAIL_DIR=${sibling}"
    [ "$rc" -eq 0 ] || fail "fetch failure must not fail setup: $(all_output)"
    output_has '^  + related-repo fetch -> .* (warn-only)' || fail "failed fetch must remain a warn-only summary step: $(all_output)"
    output_has 'WARNING: fetch failed for sibling-a; continuing.' || fail "fetch failure must warn: $(all_output)"
    output_has 'Related-repo fetch: 1 fetched, 2 not-yet-cloned, 1 failed' || fail "fetch must continue to sibling-b: $(all_output)"

    echo "==> an unrelated same-name sibling is skipped without any ref changes"
    git -C "$sibling" remote set-url origin "${BARE_BASE}/test-owner/sibling-b.git"
    before="$(digest "$sibling")"
    run_setup "${STUBS_PATH}"
    [ "$rc" -eq 0 ] || fail "identity mismatch must not fail setup: $(all_output)"
    output_has 'WARNING: skipping sibling-a: no remote matches' || fail "identity mismatch must warn"
    [ "$before" = "$(digest "$sibling")" ] || fail "an unrelated sibling must remain untouched"
    output_has '1 identity mismatches' || fail "identity skips must be reported"
    git -C "$sibling" remote set-url origin "${BARE_BASE}/test-owner/sibling-a.git"

    echo "==> a mirror fetch refspec cannot update or prune local branches or tags"
    git -C "$sibling" branch protected-local HEAD
    git -C "$sibling" branch upstream-only HEAD
    git -C "$sibling" tag protected-tag HEAD
    git -C "$sibling" config remote.origin.fetch '+refs/*:refs/*'
    git -C "$sibling" config remote.origin.pruneTags true
    protected="$(git -C "$sibling" rev-parse protected-local)"
    git -C "${TMP}/seed-sibling-a" push -q origin HEAD:protected-local
    git -C "${TMP}/seed-sibling-a" tag upstream-only-tag HEAD
    git -C "${TMP}/seed-sibling-a" push -q origin refs/tags/upstream-only-tag
    git -C "$sibling" update-ref refs/remotes/origin/deleted "$old_head"
    run_setup "${STUBS_PATH}"
    [ "$rc" -eq 0 ] || fail "mirror-configured fetch must succeed: $(all_output)"
    [ "$(git -C "$sibling" rev-parse protected-local)" = "$protected" ] || fail "fetch must not update a local branch"
    [ "$(git -C "$sibling" rev-parse upstream-only)" = "$protected" ] || fail "fetch must not prune a local branch"
    [ "$(git -C "$sibling" rev-parse protected-tag)" = "$protected" ] || fail "fetch must not prune a local tag"
    ! git -C "$sibling" show-ref --verify --quiet refs/tags/upstream-only-tag || fail "fetch must not import an upstream tag"
    [ "$(git -C "$sibling" rev-parse origin/protected-local)" = "$new_head" ] || fail "explicit remote-tracking destination must update"
    ! git -C "$sibling" show-ref --verify --quiet refs/remotes/origin/deleted || fail "deleted remote-tracking branches must be pruned"
    [ "$(git -C "$sibling" rev-parse HEAD)" = "$old_head" ] || fail "mirror fetch must preserve HEAD"
    [ "$(cat "${sibling}/local-work.txt")" = 'local work' ] || fail "mirror fetch must preserve local work"

    echo "==> matching origin is preferred over an earlier-sorting matching remote"
    make_fixture prefer-origin 'test-owner/sibling-a'
    sibling="${FIX_PARENT}/sibling-a"
    git clone -q "${BARE_BASE}/test-owner/sibling-a.git" "$sibling"
    git -C "$sibling" remote add aaa "${BARE_BASE}/test-owner/sibling-a.git"
    git -C "${TMP}/seed-sibling-a" -c user.name=Test -c user.email=test@example.com \
        commit -q --allow-empty -m 'upstream for origin preference'
    git -C "${TMP}/seed-sibling-a" push -q origin HEAD:main
    expected_head="$(git -C "${TMP}/seed-sibling-a" rev-parse HEAD)"
    run_setup "${STUBS_PATH}"
    [ "$rc" -eq 0 ] || fail "origin preference run must succeed"
    [ "$(git -C "$sibling" rev-parse origin/main)" = "$expected_head" ] || fail "matching origin must be refreshed before aaa"
    ! git -C "$sibling" show-ref --verify --quiet refs/remotes/aaa/main || fail "only preferred origin must be fetched"

    echo "==> HTTPS and SSH identity spellings match without fetching another remote"
    make_fixture identities 'git@example.test:test-owner/sibling-a.git@main'
    sibling="${FIX_PARENT}/sibling-a"
    git clone -q "${BARE_BASE}/test-owner/sibling-a.git" "$sibling"
    # The git shim redirects only fetch transport; the identity URL stays real.
    git -C "$sibling" remote set-url origin 'https://example.test/test-owner/sibling-a'
    git -C "$sibling" remote add unrelated "${TMP}/absent-other-remote"
    run_setup "${STUBS_PATH}" "STUB_NETWORK_FETCH_BASE=${BARE_BASE}"
    [ "$rc" -eq 0 ] || fail "normalized identity fetch must succeed: $(all_output)"
    output_has 'Related-repo fetch: 1 fetched' || fail "HTTPS/SSH identity must match and only origin must be fetched"
    printf '%s\n' 'ssh://git@example.test/test-owner/sibling-a.git' >"${FIX}/.devcontainer/related-repos.txt"
    run_setup "${STUBS_PATH}" "STUB_NETWORK_FETCH_BASE=${BARE_BASE}"
    output_has 'Related-repo fetch: 1 fetched' || fail "ssh:// identity must match HTTPS"

    echo "==> owner/repository identity paths match case-insensitively"
    git -C "$sibling" remote set-url origin 'https://example.test/TEST-owner/sibling-a'
    printf '%s\n' 'git@example.test:test-OWNER/sibling-a.git' >"${FIX}/.devcontainer/related-repos.txt"
    run_setup "${STUBS_PATH}" "STUB_NETWORK_FETCH_BASE=${BARE_BASE}"
    output_has 'Related-repo fetch: 1 fetched' || fail "owner path casing must not reject the sibling"
    # Keep the directory basename fixed while changing repository casing in origin.
    git -C "$sibling" remote set-url origin 'https://example.test/test-owner/SIBLING-a'
    printf '%s\n' 'git@example.test:test-owner/sibling-a.git' >"${FIX}/.devcontainer/related-repos.txt"
    run_setup "${STUBS_PATH}" "STUB_NETWORK_FETCH_BASE=${BARE_BASE}"
    output_has 'Related-repo fetch: 1 fetched' || fail "repository path casing must not reject the sibling"

    echo "==> an insteadOf alias is verified through its effective fetch URL"
    printf '%s\n' 'test-owner/sibling-a' >"${FIX}/.devcontainer/related-repos.txt"
    git -C "$sibling" remote set-url origin 'sibling-alias:repo'
    git -C "$sibling" config "url.file://${BARE_BASE}/test-owner/sibling-a.git.insteadOf" 'sibling-alias:repo'
    run_setup "${STUBS_PATH}"
    output_has 'Related-repo fetch: 1 fetched' || fail "insteadOf alias must resolve before comparison"
    git -C "$sibling" config "url.file://${BARE_BASE}/test-owner/sibling-b.git.insteadOf" 'sibling-alias:repo'
    git -C "$sibling" config --unset "url.file://${BARE_BASE}/test-owner/sibling-a.git.insteadOf"
    before="$(digest "$sibling")"
    run_setup "${STUBS_PATH}"
    output_has 'WARNING: skipping sibling-a: no remote matches' || fail "effective unrelated URL must be refused"
    [ "$before" = "$(digest "$sibling")" ] || fail "a mismatching effective URL must not mutate the sibling"

    echo "==> checkout SSH host/port does not govern shorthand sibling identity"
    make_fixture ssh-checkout 'test-owner/sibling-a'
    git -C "$FIX" remote add origin 'ssh://git@ssh.github.com:443/checkout-owner/checkout.git'
    git clone -q "${BARE_BASE}/test-owner/sibling-a.git" "${FIX_PARENT}/sibling-a"
    PATH="${STUBS_PATH}" STUB_LOG_DIR="${LOG_DIR}" \
        bash "${FIX}/.devcontainer/scripts/fetch-related-repos.sh" "$FIX_PARENT" >"$OUT" 2>"$ERR"
    output_has 'Related-repo fetch: 1 fetched' || fail "checkout host/port must not affect owner/repo identity"

    echo "==> a fork is fetched only through the matching upstream remote"
    make_fixture fork 'test-owner/sibling-a'
    sibling="${FIX_PARENT}/sibling-a"
    git clone -q "${BARE_BASE}/test-owner/sibling-a.git" "$sibling"
    fork_head="$(git -C "$sibling" rev-parse origin/main)"
    git -C "$sibling" remote set-url origin "${BARE_BASE}/fork-owner/sibling-a.git"
    git -C "$sibling" remote add upstream "${BARE_BASE}/test-owner/sibling-a.git"
    git -C "$sibling" config remote.upstream.fetch '+refs/*:refs/*'
    git -C "$sibling" branch protected-local HEAD
    git -C "${TMP}/seed-sibling-a" -c user.name=Test -c user.email=test@example.com \
        commit -q --allow-empty -m 'new upstream for fork'
    git -C "${TMP}/seed-sibling-a" push -q origin HEAD:main
    upstream_head="$(git -C "${TMP}/seed-sibling-a" rev-parse HEAD)"
    run_setup "${STUBS_PATH}"
    output_has 'Related-repo fetch: 1 fetched' || fail "a fork with matching upstream must be fetched"
    [ "$(git -C "$sibling" rev-parse upstream/main)" = "$upstream_head" ] || fail "matching upstream namespace must update"
    [ "$(git -C "$sibling" rev-parse origin/main)" = "$fork_head" ] || fail "unmatched origin refs must stay unchanged"
    [ "$(git -C "$sibling" rev-parse protected-local)" = "$fork_head" ] || fail "upstream mirror refspec must not prune local branches"

    echo "==> an untraversable sibling warns and the next sibling is fetched"
    make_fixture inaccessible $'test-owner/sibling-a\ntest-owner/sibling-b'
    mkdir "${FIX_PARENT}/sibling-a"
    git clone -q "${BARE_BASE}/test-owner/sibling-b.git" "${FIX_PARENT}/sibling-b"
    chmod 000 "${FIX_PARENT}/sibling-a"
    if (cd "${FIX_PARENT}/sibling-a") 2>/dev/null; then
        echo "skip: sibling remains traversable despite chmod 000 (root)"
    else
        run_setup "${STUBS_PATH}"
        [ "$rc" -eq 0 ] || fail "one inaccessible sibling must not abort setup"
        output_has 'WARNING: cannot enter sibling-a; continuing.' || fail "inaccessible sibling must warn"
        output_has '1 fetched, 0 not-yet-cloned, 1 failed' || fail "next sibling must still be fetched"
    fi
    chmod 755 "${FIX_PARENT}/sibling-a"

    echo "==> an existing unreadable Git entry warns and the loop continues"
    printf 'gitdir: %s/missing-git-dir\n' "$TMP" >"${FIX_PARENT}/sibling-a/.git"
    run_setup "${STUBS_PATH}"
    [ "$rc" -eq 0 ] || fail "an unreadable Git entry must warn without failing setup"
    output_has 'WARNING: cannot open repository sibling-a; continuing.' || fail "unopenable .git must warn"
    output_has '1 fetched, 0 not-yet-cloned, 1 failed' || fail "unopenable .git must not count as not-yet-cloned or stop later fetches"

    echo "==> a plain directory inside an enclosing repository is not a sibling clone"
    make_fixture enclosing 'test-owner/sibling-a'
    git init -q "${FIX_PARENT}"
    git -C "${FIX_PARENT}" remote add origin "${BARE_BASE}/test-owner/sibling-a.git"
    mkdir "${FIX_PARENT}/sibling-a"
    before="$(digest "${FIX_PARENT}/.git")"
    run_setup "${STUBS_PATH}"
    output_has '0 fetched, 1 not-yet-cloned' || fail "plain nested directory must be not-yet-cloned"
    [ "$before" = "$(digest "${FIX_PARENT}/.git")" ] || fail "fetch must not mutate the enclosing repository"

    echo "==> a bare sibling root is fetched"
    make_fixture bare 'test-owner/sibling-a'
    git clone -q --bare "${BARE_BASE}/test-owner/sibling-a.git" "${FIX_PARENT}/sibling-a"
    run_setup "${STUBS_PATH}"
    output_has 'Related-repo fetch: 1 fetched' || fail "a bare sibling root must be recognized"

    echo "==> linked-worktree and separate-git-dir siblings are fetched"
    for layout in worktree separate; do
        make_fixture "layout-${layout}" 'test-owner/sibling-a'
        sibling="${FIX_PARENT}/sibling-a"
        if [ "$layout" = worktree ]; then
            git clone -q "${BARE_BASE}/test-owner/sibling-a.git" "${TMP}/worktree-source"
            git -C "${TMP}/worktree-source" worktree add -q --detach "$sibling" HEAD
        else
            git clone -q --separate-git-dir="${TMP}/separate-git-dir" "${BARE_BASE}/test-owner/sibling-a.git" "$sibling"
        fi
        [ -f "${sibling}/.git" ] || fail "fixture must have a .git file"
        old_head="$(git -C "$sibling" rev-parse HEAD)"
        git -C "${TMP}/seed-sibling-a" -c user.name=Test -c user.email=test@example.com \
            commit -q --allow-empty -m "upstream for ${layout}"
        git -C "${TMP}/seed-sibling-a" push -q origin HEAD:main
        new_head="$(git -C "${TMP}/seed-sibling-a" rev-parse HEAD)"
        # Fetch is also independent of the bootstrap script being available.
        rm "${FIX}/.devcontainer/scripts/bootstrap-related-repos.sh"
        run_setup "${STUBS_PATH}"
        [ "$rc" -eq 0 ] || fail "${layout} fetch must succeed: $(all_output)"
        [ "$(git -C "$sibling" rev-parse origin/main)" = "$new_head" ] || fail "${layout} remote refs must update"
        [ "$(git -C "$sibling" rev-parse HEAD)" = "$old_head" ] || fail "${layout} HEAD must not move"
    done
fi

if [ "$HAVE_BOOTSTRAP" = 1 ]; then
    echo "==> a crashed fetch helper fails setup but later dependency steps still run"
    make_fixture fetch-crash ''
    printf '#!/usr/bin/env bash\nexit 7\n' >"${FIX}/.devcontainer/scripts/fetch-related-repos.sh"
    touch "${FIX}/pnpm-lock.yaml" "${FIX}/uv.lock"
    rm -f "${LOG_DIR}/pnpm.log" "${LOG_DIR}/uv.log"
    run_setup "${STUBS_PATH}"
    [ "$rc" -ne 0 ] || fail "a crashed fetch helper must fail setup"
    output_has 'Failed:' && output_has 'related-repo fetch ->' || fail "fetch helper crash must be named as failure"
    [ -s "${LOG_DIR}/pnpm.log" ] && [ -s "${LOG_DIR}/uv.log" ] || fail "dependency installs must continue after helper crash"
    ! output_has 'setup:remote completed' || fail "a helper crash must not report completion"
fi

if [ "$HAVE_BOOTSTRAP" = 1 ]; then
    echo "==> sibling cloning and fetching finish before dependency installs"
    make_fixture ordering "test-owner/sibling-a"
    touch "${FIX}/pnpm-lock.yaml" "${FIX}/uv.lock"
    expected_head="$(git -C "${TMP}/seed-sibling-a" rev-parse HEAD)"
    run_setup "${STUBS_PATH}" "EXPECTED_SIBLING=${FIX_PARENT}/sibling-a" "EXPECTED_SIBLING_HEAD=${expected_head}"
    [ "$rc" -eq 0 ] || fail "sibling clone must precede both installers: $(all_output)"
    git -C "${TMP}/seed-sibling-a" -c user.name=Test -c user.email=test@example.com \
        commit -q --allow-empty -m 'upstream for dependency ordering'
    git -C "${TMP}/seed-sibling-a" push -q origin HEAD:main
    expected_head="$(git -C "${TMP}/seed-sibling-a" rev-parse HEAD)"
    run_setup "${STUBS_PATH}" "EXPECTED_SIBLING=${FIX_PARENT}/sibling-a" "EXPECTED_SIBLING_HEAD=${expected_head}"
    [ "$rc" -eq 0 ] || fail "sibling fetch must precede both installers: $(all_output)"
fi

# --- Frozen dependency installs, only for lockfiles that exist ---
echo "==> dependencies install frozen from the lockfiles that exist"
make_fixture deps -
touch "${FIX}/pnpm-lock.yaml" "${FIX}/uv.lock"
rm -f "${LOG_DIR}"/*.log "${LOG_DIR}"/*.ci
run_setup "${STUBS_PATH}" CI=false # an inherited CI=false must not let pnpm prompt
[ "$rc" -eq 0 ] || fail "deps run must succeed (rc=$rc): $(all_output)"
grep -qx 'install --frozen-lockfile' "${LOG_DIR}/pnpm.log" || fail "pnpm must install --frozen-lockfile"
grep -qx 'sync --frozen' "${LOG_DIR}/uv.log" || fail "uv must sync --frozen"
[ "$(cat "${LOG_DIR}/pnpm.ci")" = "true" ] || fail "pnpm must receive CI=true whatever was inherited, got: $(cat "${LOG_DIR}/pnpm.ci")"
[ "$(cat "${LOG_DIR}/uv.ci")" = "true" ] || fail "uv must receive CI=true whatever was inherited, got: $(cat "${LOG_DIR}/uv.ci")"
output_has 'no .devcontainer/related-repos.txt' || fail "a missing related-repos.txt must be reported as skipped"

echo "==> no lockfile means no dependency install"
make_fixture nodeps -
rm -f "${LOG_DIR}"/*.log
run_setup "${STUBS_PATH}"
[ "$rc" -eq 0 ] || fail "no-lockfile run must succeed (rc=$rc): $(all_output)"
[ ! -e "${LOG_DIR}/pnpm.log" ] && [ ! -e "${LOG_DIR}/uv.log" ] || fail "pnpm/uv must not run without a lockfile"
[ -z "$(find "${FIX_PARENT}" -mindepth 1 -maxdepth 1 ! -name checkout -print -quit)" ] || fail "without related-repos.txt nothing may be created beside the checkout"

if [ "$HAVE_BOOTSTRAP" = 1 ]; then
    # --- A checkout entered through a symlink still gets its siblings beside the real one ---
    echo "==> a symlinked checkout clones siblings beside the real checkout"
    make_fixture symlinked "test-owner/sibling-a"
    mkdir -p "${TMP}/linkdir"
    ln -s "${FIX}" "${TMP}/linkdir/checkout-link"
    RUN_DIR="${TMP}/linkdir/checkout-link" run_setup "${STUBS_PATH}"
    [ "$rc" -eq 0 ] || fail "symlinked run must succeed (rc=$rc): $(all_output)"
    [ -d "${FIX_PARENT}/sibling-a/.git" ] || fail "siblings must land beside the real checkout ($(ls -A "${FIX_PARENT}"))"
    [ -z "$(find "${TMP}/linkdir" -mindepth 1 -maxdepth 1 ! -name checkout-link -print -quit)" ] || fail "nothing may be cloned beside the symlink"

    # --- A caller's own GIT_SSH_COMMAND is left alone ---
    echo "==> an existing GIT_SSH_COMMAND is preserved"
    make_fixture sshcmd "test-owner/sibling-a"
    rm -f "${LOG_DIR}/git-ssh.log"
    run_setup "${STUBS_PATH}" "GIT_SSH_COMMAND=ssh -i /custom/key"
    [ "$rc" -eq 0 ] || fail "custom GIT_SSH_COMMAND run must succeed (rc=$rc): $(all_output)"
    [ "$(sort -u "${LOG_DIR}/git-ssh.log")" = "ssh -i /custom/key" ] || fail "a caller's GIT_SSH_COMMAND must not be overwritten, got: $(sort -u "${LOG_DIR}/git-ssh.log")"

    # --- A non-writable parent is skipped, not reported as a clone ---
    echo "==> a non-writable parent is reported as skipped and nothing is cloned"
    make_fixture readonly $'test-owner/sibling-a\ntest-owner/sibling-b'
    git clone -q "${BARE_BASE}/test-owner/sibling-a.git" "${FIX_PARENT}/sibling-a"
    readonly_head="$(git -C "${FIX_PARENT}/sibling-a" rev-parse HEAD)"
    git -C "${TMP}/seed-sibling-a" -c user.name=Test -c user.email=test@example.com \
        commit -q --allow-empty -m 'upstream for read-only parent'
    git -C "${TMP}/seed-sibling-a" push -q origin HEAD:main
    expected_head="$(git -C "${TMP}/seed-sibling-a" rev-parse HEAD)"
    chmod 555 "${FIX_PARENT}"
    if [ -w "${FIX_PARENT}" ]; then
        chmod 755 "${FIX_PARENT}"
        echo "skip: the parent is writable despite chmod 555 (running as root); non-writable-parent scenario skipped"
    else
        rm -f "${LOG_DIR}"/*.log
        run_setup "${STUBS_PATH}"
        chmod 755 "${FIX_PARENT}"
        [ "$rc" -eq 0 ] || fail "a non-writable parent is a skip, not a failure (rc=$rc): $(all_output)"
        output_has '^  - related repos: .*is not writable' || fail "the related repos must be listed under Skipped: $(all_output)"
        ! output_has '^  + related repos' || fail "a non-writable parent must not be reported as Ran: $(all_output)"
        [ ! -e "${LOG_DIR}/gh.log" ] || fail "the bootstrap must not run against a non-writable parent"
        [ ! -e "${FIX_PARENT}/sibling-b" ] || fail "nothing may be cloned into a non-writable parent"
        [ "$(git -C "${FIX_PARENT}/sibling-a" rev-parse origin/main)" = "$expected_head" ] || fail "a read-only parent must still allow fetching an existing sibling"
        [ "$(git -C "${FIX_PARENT}/sibling-a" rev-parse HEAD)" = "$readonly_head" ] || fail "read-only-parent fetch must not move HEAD"
    fi
fi

# --- A tool that is missing is skipped, not a failure ---
echo "==> a missing lefthook is reported and the run continues"
make_fixture nolefthook -
run_setup "${MIN_BIN}" # no lefthook on PATH
[ "$rc" -eq 0 ] || fail "a missing lefthook is a skip, not a failure (rc=$rc): $(all_output)"
output_has 'lefthook is not on PATH' || fail "a missing lefthook must be reported as skipped: $(all_output)"
[ ! -e "${FIX}/.git/hooks/pre-push" ] || fail "no pre-push shim can exist without lefthook"

# --- Every config name lefthook itself searches for counts ---
echo "==> lefthook config detection covers every name lefthook searches"
for cfg in lefthook.yml lefthook.yaml lefthook.toml lefthook.json .lefthook.yml .lefthook.yaml .lefthook.toml .lefthook.json; do
    make_fixture "cfg-${cfg}" -
    rm -f "${FIX}/lefthook.yml" "${FIX}/lefthook.yaml"
    : >"${FIX}/${cfg}"
    rm -f "${LOG_DIR}/lefthook.log"
    run_setup "${STUBS_PATH}"
    [ "$rc" -eq 0 ] || fail "${cfg}: run must succeed (rc=$rc): $(all_output)"
    [ -s "${LOG_DIR}/lefthook.log" ] || fail "${cfg} must count as a lefthook config (lefthook install was not run)"
done
make_fixture cfg-none -
rm -f "${FIX}/lefthook.yml" "${LOG_DIR}/lefthook.log"
run_setup "${STUBS_PATH}"
[ ! -e "${LOG_DIR}/lefthook.log" ] || fail "without any lefthook config, lefthook install must not run"
output_has 'no lefthook config' || fail "a missing lefthook config must be reported as skipped"

# --- A step that could run and failed is a non-zero exit, and later steps still run ---
echo "==> a failing lefthook fails the task but the related repos are still cloned"
make_fixture failing "test-owner/sibling-a"
run_setup "${STUBS_PATH}" STUB_LEFTHOOK=fail
[ "$rc" -ne 0 ] || fail "a failed lefthook install must produce a non-zero exit"
output_has 'lefthook install failed' || fail "the failure must be named: $(all_output)"
if [ "$HAVE_BOOTSTRAP" = 1 ]; then
    [ -d "${FIX_PARENT}/sibling-a/.git" ] || fail "later steps must still run after a failed step"
fi

# --- Real lefthook, when the host has it: the shim is the genuine article ---
if [ -n "${REAL_LEFTHOOK}" ]; then
    echo "==> the real lefthook installs its pre-push shim"
    make_fixture reallefthook -
    mkdir -p "${TMP}/real-bin"
    ln -sf "${REAL_LEFTHOOK}" "${TMP}/real-bin/lefthook"
    # npm's lefthook is a Node entry point (#!/usr/bin/env node), unlike the
    # Homebrew or Go binary, so the minimal PATH must still reach node. Without
    # it this case fails wherever lefthook comes from npm, as in the
    # sync-harmon-devkit job.
    node_bin="$(command -v node 2>/dev/null || true)"
    [ -n "${node_bin}" ] && ln -sf "${node_bin}" "${TMP}/real-bin/node"
    run_setup "${MIN_BIN}:${TMP}/real-bin"
    [ "$rc" -eq 0 ] || fail "real lefthook run must succeed (rc=$rc): $(all_output)"
    grep -qi 'lefthook' "${FIX}/.git/hooks/pre-push" || fail "real lefthook must install its pre-push shim"
    before="$(digest "${FIX}/.git/hooks")"
    run_setup "${MIN_BIN}:${TMP}/real-bin"
    [ "$rc" -eq 0 ] || fail "second real lefthook run must succeed (rc=$rc)"
    [ "$before" = "$(digest "${FIX}/.git/hooks")" ] || fail "the second real lefthook run changed the hooks"
else
    echo "==> (lefthook is not installed on this host; the real-shim check is skipped)"
fi

# Settings must leave room for the wrapper's deadline and kill grace.
python3 - "${REPO_ROOT}" <<'PYSETTINGS'
import json
import pathlib
import re
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
script = (root / "scripts/session-start-remote.sh").read_text()
grace, deadline = map(int, re.search(r"timeout --kill-after=(\d+)s (\d+)s task", script).groups())
for name in (".claude/settings.json", "template/.claude/settings.json.jinja"):
    path = root / name
    if not path.exists():  # Generated repos have only the root settings.
        continue
    entries = json.loads(re.search(r'"SessionStart": (\[.*?\]),\s*"PreToolUse"', path.read_text(), re.S).group(1))
    assert len(entries) == 1 and entries[0]["matcher"] == "startup|resume", name
    hook = entries[0]["hooks"][0]
    assert 'scripts/session-start-remote.sh' in hook["command"], name
    assert hook["timeout"] > deadline + grace, name
    # A missing wrapper must still report its fallback summary to the agent.
    result = subprocess.run(hook["command"], shell=True, env={"CLAUDE_PROJECT_DIR": "/nonexistent-session-checkout"}, capture_output=True, text=True)
    assert result.returncode == 0 and "SessionStart remote preparation:" in result.stdout, name
PYSETTINGS

# --- The SessionStart wrapper is remote-only and always succeeds ---
echo "==> SessionStart is a no-op locally and prepares remote sessions"
make_fixture hook -
mkdir -p "${TMP}/hook-bin"
cat >"${TMP}/hook-bin/timeout" <<'EOF'
#!/usr/bin/env bash
[ "$1" = '--kill-after=5s' ] && [ "$2" = '90s' ] || exit 99
shift 2
exec "$@"
EOF
cat >"${TMP}/hook-bin/task" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --dir ] && [ "$3" = setup:remote ] || exit 99
exec bash "$2/scripts/setup-remote.sh"
EOF
chmod +x "${TMP}/hook-bin/task" "${TMP}/hook-bin/timeout"
echo "==> SessionStart distinguishes complete preparation from skipped and warning steps"
for scenario in complete complete-no-lockfiles complete-stray-marker skipped clone-warning fetch-warning; do
    make_fixture "hook-${scenario}" ''
    touch "${FIX}/pnpm-lock.yaml" "${FIX}/uv.lock"
    scenario_path="${TMP}/hook-bin:${STUBS_PATH}"
    fetch_fail_dir=""
    stray_status=""
    case "$scenario" in
    complete-stray-marker) stray_status=1 ;;
    complete-no-lockfiles)
        rm "${FIX}/pnpm-lock.yaml" "${FIX}/uv.lock" "${FIX}/lefthook.yml" "${FIX}/.devcontainer/related-repos.txt"
        ;;
    skipped) scenario_path="${TMP}/hook-bin:${MIN_BIN}" ;;
    clone-warning)
        [ "$HAVE_BOOTSTRAP" = 1 ] || continue
        echo 'test-owner/missing-repo' >"${FIX}/.devcontainer/related-repos.txt"
        ;;
    fetch-warning)
        [ "$HAVE_BOOTSTRAP" = 1 ] || continue
        echo 'test-owner/sibling-a' >"${FIX}/.devcontainer/related-repos.txt"
        git clone -q "${BARE_BASE}/test-owner/sibling-a.git" "${FIX_PARENT}/sibling-a"
        fetch_fail_dir="${FIX_PARENT}/sibling-a"
        ;;
    esac
    rc=0
    CLAUDE_CODE_REMOTE=true STUB_LOG_DIR="${LOG_DIR}" STUB_FETCH_FAIL_DIR="$fetch_fail_dir" STUB_STRAY_STATUS="$stray_status" \
        RELATED_REPOS_GIT_BASE_URL="file://${BARE_BASE}/" PATH="$scenario_path" \
        bash "${FIX}/scripts/session-start-remote.sh" >"${OUT}" 2>"${ERR}" || rc=$?
    [ "$rc" -eq 0 ] || fail "${scenario} SessionStart must exit 0"
    if [ "$scenario" = complete-no-lockfiles ] || { [[ "$scenario" = complete* ]] && [ "$HAVE_BOOTSTRAP" = 1 ]; }; then
        grep -qx '==> SessionStart remote preparation: setup:remote completed.' "$OUT" || fail "complete run needs a complete summary: $(all_output)"
    else
        grep -q '^==> SessionStart remote preparation: setup:remote completed with warnings:' "$OUT" || fail "${scenario} needs a degraded summary: $(all_output)"
    fi
    [ "$(wc -l <"$OUT" | tr -d ' ')" -eq 1 ] || fail "only the compact summary belongs on stdout"
    grep -q 'setup:remote summary' "$ERR" || fail "step details must remain on stderr"
    case "$scenario" in
    complete-stray-marker) grep -q 'completed with warnings: stray tool output' "$ERR" || fail "fixture must emit the stray marker before the final status" ;;
    skipped) grep -q 'skipped steps' "$OUT" && grep -q 'lefthook is not on PATH' "$ERR" || fail "missing tools need a summary and stderr detail" ;;
    clone-warning) grep -q 'with warnings: related repos' "$OUT" || fail "bootstrap warnings must reach the summary" ;;
    fetch-warning) grep -q 'with warnings: related-repo fetch' "$OUT" || fail "fetch warnings must reach the summary" ;;
    esac
done
make_fixture hook -
cat >"${TMP}/hook-bin/task" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${HOOK_TASK_LOG}"
echo "preparation detail"
exit "${HOOK_TASK_RC:-0}"
EOF
cat >"${TMP}/hook-bin/timeout" <<'EOF'
#!/usr/bin/env bash
[ "$1" = '--kill-after=5s' ] && [ "$2" = '90s' ] || exit 99
shift 2
exec "$@"
EOF
chmod +x "${TMP}/hook-bin/task" "${TMP}/hook-bin/timeout"
HOOK_TASK_LOG="${TMP}/hook-task.log"
export HOOK_TASK_LOG
for remote in unset false true; do
    rc=0
    (
        export PATH="${TMP}/hook-bin:${MIN_BIN}"
        if [ "$remote" = unset ]; then
            unset CLAUDE_CODE_REMOTE
        else
            export CLAUDE_CODE_REMOTE="$remote"
        fi
        bash "${FIX}/scripts/session-start-remote.sh"
    ) >"${OUT}" 2>"${ERR}" || rc=$?
    [ "$rc" -eq 0 ] || fail "SessionStart $remote must exit 0"
    if [ "$remote" != true ]; then
        [ ! -e "$HOOK_TASK_LOG" ] || fail "local SessionStart must not prepare"
        [ ! -s "$OUT" ] && [ ! -s "$ERR" ] || fail "local SessionStart must be silent"
    else
        grep -qx -- "--dir ${FIX} setup:remote" "$HOOK_TASK_LOG" || fail "remote SessionStart must prepare its checkout"
        grep -q 'SessionStart remote preparation: setup:remote completed.' "${OUT}" || fail "remote SessionStart must print a summary"
        ! grep -q 'preparation detail' "${OUT}" || fail "preparation details must stay off stdout"
        grep -q 'preparation detail' "${ERR}" || fail "preparation details must reach stderr"
    fi
done
rc=0
CLAUDE_CODE_REMOTE=true HOOK_TASK_RC=1 PATH="${TMP}/hook-bin:${MIN_BIN}" \
    bash "${FIX}/scripts/session-start-remote.sh" >"${OUT}" 2>"${ERR}" || rc=$?
[ "$rc" -eq 0 ] || fail "preparation failure must not fail SessionStart"
grep -q 'WARNING: SessionStart remote preparation: setup:remote failed' "${OUT}" || fail "preparation failure must warn"

echo "==> SessionStart reports checkout resolution failures on stdout"
cat >"${TMP}/hook-bin/dirname" <<'EOF'
#!/usr/bin/env bash
echo /nonexistent-session-checkout/scripts
EOF
chmod +x "${TMP}/hook-bin/dirname"
rc=0
CLAUDE_CODE_REMOTE=true PATH="${TMP}/hook-bin:${MIN_BIN}" \
    bash "${FIX}/scripts/session-start-remote.sh" >"${OUT}" 2>"${ERR}" || rc=$?
[ "$rc" -eq 0 ] || fail "checkout resolution failure must not fail SessionStart"
grep -q 'SessionStart remote preparation: could not locate the checkout' "${OUT}" || fail "checkout resolution failure must report its summary on stdout"
rm -f "${TMP}/hook-bin/dirname"

echo "==> SessionStart skips preparation when timeout is missing"
rm -f "${TMP}/hook-bin/timeout" "$HOOK_TASK_LOG"
rc=0
CLAUDE_CODE_REMOTE=true PATH="${TMP}/hook-bin:${MIN_BIN}" \
    bash "${FIX}/scripts/session-start-remote.sh" >"${OUT}" 2>"${ERR}" || rc=$?
[ "$rc" -eq 0 ] || fail "missing timeout must not fail SessionStart"
[ ! -e "$HOOK_TASK_LOG" ] || fail "missing timeout must skip preparation"
grep -q 'SessionStart remote preparation: preparation skipped because timeout is unavailable; run task setup:remote.' "${OUT}" || fail "missing timeout must report a skip and manual setup instruction"

echo "==> SessionStart bounds a slow preparation task and still exits 0"
REAL_TIMEOUT="$(command -v timeout 2>/dev/null || true)"
if [ -n "$REAL_TIMEOUT" ]; then
    cat >"${TMP}/hook-bin/task" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${HOOK_TASK_LOG}"
sleep 5
echo 'slow task completed' >>"${HOOK_TASK_LOG}"
EOF
    cat >"${TMP}/hook-bin/timeout" <<EOF
#!/usr/bin/env bash
[ "\$1" = '--kill-after=5s' ] && [ "\$2" = '90s' ] || exit 99
shift 2
# Exercise a real deadline without making the suite wait 90 seconds.
exec "${REAL_TIMEOUT}" --kill-after=1s 0.1s "\$@"
EOF
    chmod +x "${TMP}/hook-bin/task" "${TMP}/hook-bin/timeout"
    rm -f "$HOOK_TASK_LOG"
    rc=0
    CLAUDE_CODE_REMOTE=true PATH="${TMP}/hook-bin:${MIN_BIN}" \
        bash "${FIX}/scripts/session-start-remote.sh" >"${OUT}" 2>"${ERR}" || rc=$?
    [ "$rc" -eq 0 ] || fail "deadline must not fail SessionStart"
    grep -qx -- "--dir ${FIX} setup:remote" "$HOOK_TASK_LOG" || fail "deadline must actually start preparation"
    ! grep -q 'slow task completed' "$HOOK_TASK_LOG" || fail "deadline must interrupt slow preparation"
    grep -q 'WARNING: SessionStart remote preparation: setup:remote failed' "${OUT}" || fail "deadline must warn"

    echo "==> an escaped descendant holding stdout cannot keep SessionStart past its deadline"
    cat >"${TMP}/hook-bin/task" <<EOF
#!/usr/bin/env bash
# Simulate a slow launcher: readiness, not this startup latency, starts the clock.
sleep 0.3
"$(command -v python3)" - <<'PYDAEMON'
import subprocess
import sys

# The detached child signals only after it starts with stdout inherited.
subprocess.Popen([sys.executable, "-c", """
import os
import pathlib
import time
print("daemon holding stdout started", flush=True)
pathlib.Path(os.environ["HOOK_DAEMON_READY"]).write_text(str(time.monotonic()))
time.sleep(3)
"""], start_new_session=True, stdin=subprocess.DEVNULL,
                 stderr=subprocess.DEVNULL)
PYDAEMON
EOF
    cat >"${TMP}/hook-bin/timeout" <<'EOF'
#!/usr/bin/env bash
[ "$1" = '--kill-after=5s' ] && [ "$2" = '90s' ] || exit 99
shift 2
# The preceding scenario tests real GNU timeout. This shim isolates pipe EOF:
# start the task, wait for explicit daemon readiness, then model deadline expiry.
"$@" &
attempts=0
while [ ! -s "$HOOK_DAEMON_READY" ] && [ "$attempts" -lt 1000 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
done
[ -s "$HOOK_DAEMON_READY" ] || exit 99
sleep 0.1
exit 124
EOF
    chmod +x "${TMP}/hook-bin/task" "${TMP}/hook-bin/timeout"
    python3 - "${FIX}/scripts/session-start-remote.sh" "${TMP}/hook-bin:${MIN_BIN}" "${TMP}" <<'PYDEADLINE'
import os
import pathlib
import subprocess
import sys
import time

script, path, fixture_tmp = sys.argv[1:]
ready = pathlib.Path(fixture_tmp) / "daemon.ready"
env = dict(os.environ, CLAUDE_CODE_REMOTE="true", PATH=path, TMPDIR=fixture_tmp,
           HOOK_DAEMON_READY=str(ready))
result = subprocess.run(["bash", script], env=env, capture_output=True, text=True)
finished = time.monotonic()
assert result.returncode == 0, result
assert ready.exists(), "daemon never signaled readiness within the bounded startup wait"
elapsed = finished - float(ready.read_text())
assert "daemon holding stdout started" in result.stderr, result
assert "setup:remote failed; run task setup:remote again." in result.stdout, result
assert elapsed < 1.1, f"wrapper waited {elapsed:.2f}s past the 0.1s deadline + 1s grace"
print(f"stdout-holder wrapper returned {elapsed:.2f}s after readiness (deadline + grace: 1.1s)")
PYDEADLINE
else
    echo "skip: timeout is unavailable; the real deadline scenario cannot run"
fi

echo "test-setup-remote.sh passed"
