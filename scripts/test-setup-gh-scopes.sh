#!/usr/bin/env bash
# test-setup-gh-scopes.sh — unit-test setup-gh-scopes.sh, the one script here
# that MUTATES the operator's stored credential.
#
# Run via `task test:gh-scopes`.
#
# Its refusals are the safety story (an env token it cannot fix, a shell that
# cannot complete a browser flow) and its post-refresh verification is the
# reason it exists at all — `gh auth refresh` can exit 0 having granted less
# than was asked for. None of that is exercised by test-status.sh, which only
# covers the status consumer.
#
# Hermetic in two directions, as test-status.sh is:
#
#   * every `gh` call is answered by a stub on PATH, so this never reaches
#     GitHub and never touches the developer's own credential — which is the
#     whole point: the bug it guards (reporting a refresh that did not land)
#     is INVISIBLE when tested against a token that already has the scopes.
#   * the script runs from a fixture root this test builds, never the repo it
#     lives in, so the required-scope list under test is the fixture's.
set -euo pipefail
cd "$(dirname "$0")/.."

# Scrub every GitHub token variable from this test's own environment before
# anything runs. The BOT devcontainer profile supplies GH_TOKEN by design, and
# `task verify` runs there — so an inherited token would trip the env-token
# refusal in the baseline cases below and fail the suite for a reason that has
# nothing to do with the code. The explicit env-token cases set what they need,
# one variable at a time.
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST
# Likewise git's own discovery variables (set when this runs under a git hook), so
# the worktree case below finds the repository it builds, not the caller's.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

script="./scripts/setup-gh-scopes.sh"
scopes_lib="./scripts/gh-scopes.sh"
output_lib="./scripts/lib/output.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
# Keep git from walking above the temp directory, so a fixture that is not itself a
# repository is never mistaken for part of one that happens to contain $TMPDIR.
GIT_CEILING_DIRECTORIES="$(cd "${TMP}" && pwd -P)"
export GIT_CEILING_DIRECTORIES

# A board-carrying fixture, so the required list includes the Projects scopes.
mkdir -p "${TMP}/repo/scripts"
mkdir -p "${TMP}/repo/scripts/lib"
cp "${script}" "${TMP}/repo/scripts/setup-gh-scopes.sh"
cp "${scopes_lib}" "${TMP}/repo/scripts/gh-scopes.sh"
cp "${output_lib}" "${TMP}/repo/scripts/lib/output.sh"
: >"${TMP}/repo/scripts/setup-github-project.sh"
SUT="${TMP}/repo/scripts/setup-gh-scopes.sh"

# Each bootstrap-writing case gets an immutable script path. A background bash
# may open its script after setup returns, so overwriting a shared stub lets an
# earlier case execute a later case's marker-writing code.
bootstrap_fixture() {
    local name="$1"
    local root="${TMP}/bootstrap-${name}"
    mkdir -p "${root}/scripts/lib" "${root}/.devcontainer/scripts"
    cp "${script}" "${scopes_lib}" "${TMP}/repo/scripts/setup-github-project.sh" "${root}/scripts/"
    cp "${output_lib}" "${root}/scripts/lib/"
    SUT="${root}/scripts/setup-gh-scopes.sh"
    BOOTSTRAP="${root}/.devcontainer/scripts/bootstrap-related-repos.sh"
}

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

# make_stub SCENARIO — write $TMP/bin/gh. The refresh is RECORDED, never real:
# a stub that silently succeeded would let a broken verification pass.
make_stub() {
    local scenario="$1"
    mkdir -p "${TMP}/bin"
    {
        echo '#!/usr/bin/env bash'
        echo 'if [ -n "${STUB_CALLS:-}" ]; then echo "$*" >>"$STUB_CALLS"; fi'
        echo 'if [ "$1" = "auth" ] && [ "$2" = "refresh" ]; then'
        echo '    [ -n "${TMP_PHASE:-}" ] && : >"$TMP_PHASE"'
        echo '    exit 0'
        echo 'fi'
        # `gh auth token` is how the script establishes the credential CLASS
        # positively, from the token prefix, instead of inferring it from a
        # scope line current gh omits for fine-grained PATs.
        echo 'if [ "$1" = "auth" ] && [ "$2" = "token" ]; then'
        case "$scenario" in
        fine-grained) echo '    echo "github_pat_11ABCDEFG0abcdefghijkl"' ;;
        classic-pat) echo '    echo "ghp_ClassicPersonalAccessToken00"' ;;
        unknown-credential) echo '    echo "ghz_somethingGitHubAddedLater"' ;;
        logged-out)
            echo '    echo "no oauth token" >&2'
            echo '    exit 1'
            ;;
        *) echo '    echo "gho_16CharsOfClassicOAuthToken"' ;;
        esac
        echo '    exit 0'
        echo 'fi'
        echo 'if [ "$1" = "auth" ] && [ "$2" = "status" ]; then'
        echo '    seen_active=false'
        echo '    for a in "$@"; do [ "$a" = "--active" ] && seen_active=true; done'
        case "$scenario" in
        lands)
            # The happy path: after the refresh every requirement is present.
            echo "    echo \"  - Token scopes: 'repo', 'workflow', 'project', 'read:project'\""
            echo '    exit 0'
            ;;
        does-not-land)
            # `gh auth refresh` exits 0 but the grant did not happen — an org
            # that restricts the scope, or an operator who unticked it in the
            # browser. The reason this script verifies instead of trusting.
            echo "    echo \"  - Token scopes: 'repo', 'workflow'\""
            echo '    exit 0'
            ;;
        inactive-has-scope)
            # Two accounts on one host; only the INACTIVE one is fully scoped.
            # `gh auth refresh` only ever updates the active account, so a
            # verification that read every account would report a success that
            # did not happen.
            echo '    if [ "$seen_active" = true ]; then'
            echo "        echo \"  - Token scopes: 'repo', 'workflow'\""
            echo '    else'
            echo "        echo \"  - Token scopes: 'repo', 'workflow'\""
            echo "        echo \"  - Token scopes: 'project', 'read:project'\""
            echo '    fi'
            echo '    exit 0'
            ;;
        lands-after-refresh)
            # The genuine success path: incomplete BEFORE the refresh, complete
            # after it. A single-phase stub cannot test this any more, now that
            # an already-complete credential short-circuits without refreshing.
            echo '    if [ -f "${TMP_PHASE:-/nonexistent}" ]; then'
            echo "        echo \"  - Token scopes: 'repo', 'workflow', 'project', 'read:project'\""
            echo '    else'
            echo "        echo \"  - Token scopes: 'repo', 'workflow'\""
            echo '    fi'
            echo '    exit 0'
            ;;
        read-only-grant)
            # GitHub granted only the READ scope — an org restriction, or an
            # operator who unticked the write box in the browser.
            echo "    echo \"  - Token scopes: 'repo', 'workflow', 'read:project'\""
            echo '    exit 0'
            ;;
        write-only-grant)
            # Only 'project' reported. It subsumes 'read:project', so this must
            # NOT be reported as a missing scope.
            echo "    echo \"  - Token scopes: 'repo', 'workflow', 'project'\""
            echo '    exit 0'
            ;;
        logged-out)
            echo '    echo "You are not logged into any GitHub hosts." >&2'
            echo '    exit 1'
            ;;
        fine-grained)
            # What CURRENT gh actually prints for a fine-grained PAT: no
            # `Token scopes:` line at all. Verified against gh 2.97.0. The
            # earlier fixture emitted `Token scopes: none`, a form modern gh
            # does not produce — so it exercised a branch real credentials
            # never reach while the real shape fell through to the refresh.
            echo '    echo "  ✓ Logged in to github.com account someone (keyring)"'
            echo '    exit 0'
            ;;
        classic-pat)
            # A classic PAT DOES report quoted OAuth scopes, so it looks
            # refreshable — and is not: `gh auth refresh` cannot widen a PAT,
            # it runs a device flow and stores the OAuth token over it. Scopes
            # are deliberately incomplete here, so a script that failed to
            # refuse would go on to refresh and the call log would show it.
            echo "    echo \"  - Token scopes: 'repo', 'workflow'\""
            echo '    exit 0'
            ;;
        unknown-credential)
            # Logged in, no scope line, and `gh auth token` yields a prefix
            # this script does not know. Must fail CLOSED rather than refresh.
            echo '    echo "  ✓ Logged in to github.com account someone (keyring)"'
            echo '    exit 0'
            ;;
        esac
        echo 'fi'
        echo 'echo "stub: unexpected gh call: $*" >&2; exit 1'
    } >"${TMP}/bin/gh"
    chmod +x "${TMP}/bin/gh"
}

# pty_exec CMD... — run CMD under a pseudo-terminal, so the script sees a TTY
# on stdin and stdout.
#
# Two allocators, in preference order. `python3 -c 'pty.spawn(...)'` calls
# openpty directly and therefore works in a sandbox or CI shell with no
# CONTROLLING terminal — where `script` fails with tcgetattr/ioctl before ever
# running the command, failing every case for a reason unrelated to the code
# under test. `script` is the fallback for a host without python3; its BSD
# (macOS) and util-linux (CI) argument orders differ.
pty_exec() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,pty,sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' "$@" 2>&1
    elif [ "$(uname -s)" = "Darwin" ]; then
        script -q /dev/null "$@" 2>&1
    else
        script -qec "$*" /dev/null 2>&1
    fi
}

# Whether a pty can be allocated AT ALL. The cases that need one are skipped
# with a note rather than silently dropped (the same treatment test-status.sh
# gives a missing `timeout` binary). Everything BEFORE the TTY gate — the
# env-token refusals — is tested without a pty either way, because that
# refusal deliberately runs first.
PTY_OK=false
if [ "$(pty_exec printf PTYPROBE 2>/dev/null | tr -dc 'A-Z')" = "PTYPROBE" ]; then
    PTY_OK=true
fi

# run_sut_pty SCENARIO [ENV...] — the same, under a pseudo-terminal, capturing
# output. Only call when PTY_OK.
run_sut_pty() {
    local scenario="$1"
    shift
    make_stub "${scenario}"
    # A subshell with explicit exports rather than `env`: pty_exec is a shell
    # function, and `env` can only exec a real binary.
    (
        mkdir -p "${TMP}/home"
        export HOME="${TMP}/home"
        export PATH="${TMP}/bin:${PATH}"
        export TMP_PHASE="${TMP}/phase-marker"
        rm -f "${TMP_PHASE}"
        local kv
        for kv in "$@"; do export "${kv?}"; done
        pty_exec "${SUT}"
    ) || true
}

# rc_pty_of SCENARIO [ENV...] — the exit code from a run that got a TTY, so a
# case can assert on the code the POST-REFRESH path returned. rc_of cannot:
# it runs without a TTY, so its non-zero comes from the TTY guard long before
# the verification under test, and a missing-scope branch that printed the
# right message but exited 0 would still look green.
rc_pty_of() {
    local scenario="$1"
    shift
    make_stub "${scenario}"
    local rc=0
    (
        mkdir -p "${TMP}/home"
        export HOME="${TMP}/home"
        export PATH="${TMP}/bin:${PATH}"
        export TMP_PHASE="${TMP}/phase-marker"
        rm -f "${TMP_PHASE}"
        local kv
        for kv in "$@"; do export "${kv?}"; done
        pty_exec "${SUT}" >/dev/null 2>&1
    ) || rc=$?
    printf '%s' "${rc}"
}

# run_sut_notty SCENARIO [ENV...] — capture output with NO tty. Valid for every
# assertion about a refusal that precedes the TTY gate.
run_sut_notty() {
    local scenario="$1"
    shift
    make_stub "${scenario}"
    env "$@" PATH="${TMP}/bin:${PATH}" "${SUT}" </dev/null 2>&1 || true
}

# rc_of SCENARIO [ENV...] — the exit code, which the refusals must make
# non-zero: a refusal that exited 0 would tell a caller the scopes are fine.
rc_of() {
    local scenario="$1"
    shift
    make_stub "${scenario}"
    local rc=0
    env "$@" PATH="${TMP}/bin:${PATH}" "${SUT}" </dev/null >/dev/null 2>&1 || rc=$?
    printf '%s' "${rc}"
}

echo "==> refuses without a TTY, and says why"
make_stub lands
out="$(PATH="${TMP}/bin:${PATH}" "${SUT}" </dev/null 2>&1 || true)"
case "$out" in
*"no TTY"*) ;;
*) fail "expected a TTY refusal, got: ${out}" ;;
esac
[ "$(rc_of lands)" != 0 ] || fail "the TTY refusal must exit non-zero"

echo "==> a no-TTY refusal never reaches gh auth refresh"
# The safety property behind the refusal: agents and CI must not re-mint the
# operator's credential, so the refusal has to come BEFORE the mutation.
STUB_CALLS="${TMP}/calls.txt"
export STUB_CALLS
: >"${STUB_CALLS}"
make_stub lands
PATH="${TMP}/bin:${PATH}" "${SUT}" </dev/null >/dev/null 2>&1 || true
if grep -q 'auth refresh' "${STUB_CALLS}"; then
    fail "a non-interactive run mutated the credential: $(tr '\n' ' ' <"${STUB_CALLS}")"
fi
unset STUB_CALLS

echo "==> refuses the env-token family gh uses for THIS host"
out="$(run_sut_notty lands GH_HOST=github.com GH_TOKEN=x)"
case "$out" in
*"GH_TOKEN is set"*"github.com"*) ;;
*) fail "expected a GH_TOKEN refusal on github.com, got: ${out}" ;;
esac
[ "$(rc_of lands GH_HOST=github.com GH_TOKEN=x)" != 0 ] ||
    fail "the env-token refusal must exit non-zero"

echo "==> does NOT refuse an env token gh ignores on this host"
# The dual-host case: gh reads GH_ENTERPRISE_TOKEN for a GHES host, not for
# github.com, so it does not override the credential being refreshed here.
out="$(run_sut_notty lands GH_HOST=github.com GH_ENTERPRISE_TOKEN=x)"
case "$out" in
*"GH_ENTERPRISE_TOKEN is set"*) fail "refused a token gh ignores on this host: ${out}" ;;
*"no TTY"*) ;; # fell through to the NEXT gate, which is the point
*) fail "expected the run to reach the TTY gate, got: ${out}" ;;
esac
out="$(run_sut_notty lands GH_HOST=ghe.example.com GH_TOKEN=x)"
case "$out" in
*"GH_TOKEN is set"*) fail "refused a github.com token in a GHES checkout: ${out}" ;;
*"no TTY"*) ;;
*) fail "expected the run to reach the TTY gate, got: ${out}" ;;
esac

echo "==> refuses the enterprise env token on an enterprise host"
out="$(run_sut_notty lands GH_HOST=ghe.example.com GH_ENTERPRISE_TOKEN=x)"
case "$out" in
*"GH_ENTERPRISE_TOKEN is set"*"ghe.example.com"*) ;;
*) fail "expected an enterprise env-token refusal, got: ${out}" ;;
esac

echo "==> the related-repo bootstrap is detached in the race-free form"
# The behavioural marker test below passes under the old, racy forms too (a HUP
# landing between the fork and a trap inside the child is not reproducible), so
# the detach form is pinned statically, inside trigger_related_repos_bootstrap:
#   prev_hup="$(trap -p HUP)"        the old disposition is captured first (under
#                                    set -u the restore aborts without it)
#   trap '' HUP                      the PARENT ignores SIGHUP before the fork
#   bash "${bootstrap}" ... </dev/null >>log 2>&1 &     then forks, detached
#   eval "${prev_hup}" / trap - HUP  and restores what it was after the fork
# An ignored signal stays ignored across fork and exec, so the job is immune from
# its first instruction. nohup, or a trap set inside the child, leaves a window and
# must not return. Comment lines never count, in either direction.
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
    /^trigger_related_repos_bootstrap\(\) \{/ { infn = 1; next }
    infn && /^\}/ { infn = 0 }
    !infn { next }
    /^[[:space:]]*#/ { next }
    /nohup/ { nohup_seen = 1 }
    /^[[:space:]]*prev_hup="\$\(trap -p HUP\)"[[:space:]]*$/ { captured = 1 }
    $0 ~ ("^[[:space:]]*trap (" sq sq "|\"\") HUP[[:space:]]*$") { state = 1; if (captured) armed = 1; next }
    state == 1 && /^[[:space:]]*bash "\$\{bootstrap\}"/ {
        line = joined()
        if (line ~ /<[[:space:]]*\/dev\/null/ && line ~ /&[[:space:]]*$/) { state = 2; next }
        state = 0
        next
    }
    state == 2 && /eval .*prev_hup/ { restored = 1 }
    state == 2 && /^[[:space:]]*trap - HUP[[:space:]]*$/ { reset = 1 }
    /[^[:space:]]/ && state == 1 { state = 0 }
    END {
        exit (!(armed && restored && reset) || nohup_seen)
    }' "$1"
}
detach_form_ok "${script}" ||
    fail "expected trigger_related_repos_bootstrap to ignore SIGHUP in the parent (trap '' HUP), fork the bootstrap with </dev/null and a trailing &, then restore it, without nohup"

# The guard is only worth anything if it can fail: break each element once in a
# scratch copy (never the real file) and require the verdict to follow.
mutate_detach() { # DESCRIPTION SED-EXPRESSION
    sed "$2" "${script}" >"${TMP}/detach-mutant.sh"
    if cmp -s "${script}" "${TMP}/detach-mutant.sh"; then
        fail "test setup: the mutation '$1' did not change the script"
    fi
    if detach_form_ok "${TMP}/detach-mutant.sh"; then
        fail "the detach guard accepted a script with $1"
    fi
}
mutate_detach "the parent-side HUP ignore removed" "/^[[:space:]]*trap '' HUP\$/d"
mutate_detach "the HUP ignore reset to the default (trap -- HUP)" "s/^\\([[:space:]]*\\)trap '' HUP\$/\\1trap -- HUP/"
mutate_detach "</dev/null removed from the forked command" '/bash "\${bootstrap}"/s# </dev/null##'
mutate_detach "the trailing & removed from the forked command" '/bash "\${bootstrap}"/s# &$##'
mutate_detach "nohup in front of the forked command" '/bash "\${bootstrap}"/s#bash "#nohup bash "#'
mutate_detach "the saved disposition no longer restored" '/eval "\${prev_hup}"/d'
mutate_detach "the default disposition no longer restored" '/^[[:space:]]*trap - HUP$/d'
mutate_detach "the saved disposition never captured before the ignore" '/prev_hup="\$(trap -p HUP)"/d'
# ...and a reworded comment must not be able to fail it.
# (awk, not sed: a newline in a sed replacement is GNU-only, and on BSD sed the
# "comment" would silently become a literal n, making this case vacuous.)
awk '{ print } /^trigger_related_repos_bootstrap\(\) \{$/ { print "    # nohup bash bootstrap was the old form" }' "${script}" >"${TMP}/detach-comment.sh"
grep -q '^    # nohup bash bootstrap was the old form$' "${TMP}/detach-comment.sh" ||
    fail "test setup: the comment line was not inserted"
detach_form_ok "${TMP}/detach-comment.sh" ||
    fail "the detach guard failed on a comment that merely mentions nohup"

if [ "${PTY_OK}" = true ]; then
    echo "==> a logged-out host is told to log in, not refreshed"
    out="$(run_sut_pty logged-out GH_HOST=github.com)"
    case "$out" in
    *"not logged in"*"gh auth login"*) ;;
    *) fail "expected a login remedy, got: ${out}" ;;
    esac

    echo "==> succeeds when the refresh lands, naming the scopes"
    out="$(run_sut_pty lands-after-refresh GH_HOST=github.com)"
    case "$out" in
    *"All requested GitHub CLI scopes are present"*) ;;
    *) fail "expected success after a landed refresh, got: ${out}" ;;
    esac

    echo "==> triggers bootstrap-related-repos.sh upon successful refresh grant"
    bootstrap_fixture success
    rm -f "${TMP}/bootstrap-marker"
    cat <<EOF >"${BOOTSTRAP}"
#!/usr/bin/env bash
touch "${TMP}/bootstrap-marker"
exit 0
EOF
    chmod +x "${BOOTSTRAP}"
    out="$(run_sut_pty lands-after-refresh GH_HOST=github.com)"
    case "$out" in
    *"Bootstrapping related repos in the background"*"${TMP}/home/.related-repos-bootstrap.log"*) ;;
    *) fail "expected background bootstrap invocation notice naming log path, got: ${out}" ;;
    esac
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        [ -f "${TMP}/bootstrap-marker" ] && break
        sleep 0.2
    done
    [ -f "${TMP}/bootstrap-marker" ] || fail "bootstrap marker file was not created after grant landed"

    echo "==> the bootstrap is told the checkout's physical parent, on any layout"
    SUT="${TMP}/repo/scripts/setup-gh-scopes.sh"
    mkdir -p "${TMP}/repo/.devcontainer/scripts"
    # The bootstrap's default target is /workspaces, which is right only inside the
    # devcontainer; anywhere else a scope refresh would clone into a directory that
    # does not exist. The trigger names the target, as setup-remote.sh does: the
    # parent of the PHYSICAL checkout (pwd -P).
    cat <<'EOF' >"${TMP}/repo/.devcontainer/scripts/bootstrap-related-repos.sh"
#!/usr/bin/env bash
set -euo pipefail
capture="${BOOTSTRAP_CAPTURE_DIR:?}"
printf '%s\n' "$#" >"${capture}/args.pending"
: >"${capture}/partial-ready"
# Each layout pauses between fields until the assertion has checked readiness.
# Open the FIFO read/write so even an aborted test cannot leave open() blocked;
# the bounded read then lets this detached fixture exit on its own.
IFS= read -r -t 10 release <>"${capture}/release" || exit 1
printf '%s\n' "${1:-}" >>"${capture}/args.pending"
mv "${capture}/args.pending" "${capture}/args"
EOF
    chmod +x "${TMP}/repo/.devcontainer/scripts/bootstrap-related-repos.sh"
    bootstrap_capture_ready() {
        [ -f "$1/args" ]
    }
    # assert_bootstrap_target SUT-PATH EXPECTED-DIR DESCRIPTION
    assert_bootstrap_target() {
        local sut="$1" want="$2" what="$3" capture got_count got_target
        capture="$(mktemp -d "${TMP}/bootstrap-capture.XXXXXX")"
        mkfifo "${capture}/release"
        # Keeping both ends open makes the release write nonblocking even if the
        # child fails. Each invocation owns its capture and synchronization paths.
        exec 3<>"${capture}/release"
        (
            SUT="${sut}"
            run_sut_pty lands-after-refresh GH_HOST=github.com BOOTSTRAP_CAPTURE_DIR="${capture}"
        ) >/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            [ -f "${capture}/partial-ready" ] && break
            sleep 0.2
        done
        [ -f "${capture}/partial-ready" ] || fail "${what}: the bootstrap was not started"
        # Deterministically hold a nonempty, incomplete record. The exact
        # readiness predicate used below must reject it in every layout.
        [ "$(cat "${capture}/args.pending")" = 1 ] || fail "${what}: expected only the count before release"
        if bootstrap_capture_ready "${capture}"; then
            fail "${what}: a partial bootstrap capture was ready before publication"
        fi
        printf 'publish\n' >&3
        exec 3>&-
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            bootstrap_capture_ready "${capture}" && break
            sleep 0.2
        done
        bootstrap_capture_ready "${capture}" || fail "${what}: the bootstrap did not publish its arguments"
        # The atomic rename publishes a complete immutable capture. Read it once
        # so assertions and diagnostics always describe the same snapshot.
        {
            IFS= read -r got_count
            IFS= read -r got_target
        } <"${capture}/args"
        [ "${got_count}" = 1 ] ||
            fail "${what}: the bootstrap must get exactly one argument, got: ${got_count}"
        [ "${got_target}" = "${want}" ] ||
            fail "${what}: expected the target ${want}, got: ${got_target}"
    }
    # A checkout whose parent is a directory named "workspaces" — the devcontainer
    # layout, without needing a writable /workspaces on this host...
    mkdir -p "${TMP}/layout/workspaces"
    cp -R "${TMP}/repo" "${TMP}/layout/workspaces/checkout"
    want_ws="$(cd "${TMP}/layout/workspaces" && pwd -P)"
    assert_bootstrap_target "${TMP}/layout/workspaces/checkout/scripts/setup-gh-scopes.sh" "${want_ws}" \
        "a checkout under a workspaces directory"
    # ...one under another directory, which is the case the default got wrong...
    mkdir -p "${TMP}/layout/elsewhere/deep"
    cp -R "${TMP}/repo" "${TMP}/layout/elsewhere/deep/checkout"
    want_el="$(cd "${TMP}/layout/elsewhere/deep" && pwd -P)"
    [ "${want_el}" != "${want_ws}" ] || fail "test setup: the two layouts must resolve to different parents"
    assert_bootstrap_target "${TMP}/layout/elsewhere/deep/checkout/scripts/setup-gh-scopes.sh" "${want_el}" \
        "a checkout under another directory"
    # ...and one entered through a symlink, where the PHYSICAL parent wins.
    mkdir -p "${TMP}/layout/links"
    ln -s "${TMP}/layout/elsewhere/deep/checkout" "${TMP}/layout/links/alias"
    assert_bootstrap_target "${TMP}/layout/links/alias/scripts/setup-gh-scopes.sh" "${want_el}" \
        "a checkout entered through a symlink"
    # ...and a linked worktree, which sits INSIDE its primary checkout (this
    # repository's own .worktrees/<name> layout): siblings belong beside the
    # PRIMARY checkout, not under its .worktrees directory.
    mkdir -p "${TMP}/layout/base"
    cp -R "${TMP}/repo" "${TMP}/layout/base/primary"
    (
        cd "${TMP}/layout/base/primary"
        git init -q
        git add -A
        git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
            -c core.hooksPath=/dev/null commit -q -m fixture
        git worktree add -q .worktrees/linked -b linked
    ) >/dev/null 2>&1 || fail "test setup: could not build a repository with a linked worktree"
    [ -f "${TMP}/layout/base/primary/.worktrees/linked/scripts/setup-gh-scopes.sh" ] ||
        fail "test setup: the linked worktree has no copy of the script"
    want_primary="$(cd "${TMP}/layout/base" && pwd -P)"
    assert_bootstrap_target "${TMP}/layout/base/primary/.worktrees/linked/scripts/setup-gh-scopes.sh" "${want_primary}" \
        "a linked worktree"
    # ...and the other root this repository uses, a Claude Code agent worktree at
    # <primary>/.claude/worktrees/<name>, which also belongs beside the PRIMARY.
    (
        cd "${TMP}/layout/base/primary"
        git worktree add -q .claude/worktrees/agent -b agent
    ) >/dev/null 2>&1 || fail "test setup: could not add a .claude/worktrees linked worktree"
    [ -f "${TMP}/layout/base/primary/.claude/worktrees/agent/scripts/setup-gh-scopes.sh" ] ||
        fail "test setup: the .claude/worktrees linked worktree has no copy of the script"
    assert_bootstrap_target "${TMP}/layout/base/primary/.claude/worktrees/agent/scripts/setup-gh-scopes.sh" "${want_primary}" \
        "a linked worktree under .claude/worktrees"
    # ...but ONLY a linked worktree gets that treatment. A --separate-git-dir
    # checkout whose git directory happens to be named .git elsewhere is still an
    # ordinary checkout: it keeps its own parent, not the git directory's.
    mkdir -p "${TMP}/layout/sepbase" "${TMP}/layout/gitstore"
    cp -R "${TMP}/repo" "${TMP}/layout/sepbase/checkout"
    (
        cd "${TMP}/layout/sepbase/checkout"
        git init -q --separate-git-dir "${TMP}/layout/gitstore/.git"
    ) >/dev/null 2>&1 || fail "test setup: could not build a --separate-git-dir checkout"
    [ -f "${TMP}/layout/gitstore/.git/HEAD" ] || fail "test setup: the separate git directory was not created"
    want_sep="$(cd "${TMP}/layout/sepbase" && pwd -P)"
    assert_bootstrap_target "${TMP}/layout/sepbase/checkout/scripts/setup-gh-scopes.sh" "${want_sep}" \
        "a --separate-git-dir checkout"
    # ...and a linked worktree whose PRIMARY keeps its git directory elsewhere
    # (--separate-git-dir). Git reports the common dir as <store>/.git, and
    # <store> even passes for a working-tree top level, but it is not a checkout:
    # the override must not trust it, and the argument falls back to the linked
    # worktree's own physical parent.
    mkdir -p "${TMP}/layout/sepprimary/store" "${TMP}/layout/sepprimary/work"
    cp -R "${TMP}/repo" "${TMP}/layout/sepprimary/work/primary"
    (
        cd "${TMP}/layout/sepprimary/work/primary"
        git init -q --separate-git-dir "${TMP}/layout/sepprimary/store/.git"
        git add -A
        git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
            -c core.hooksPath=/dev/null commit -q -m fixture
        git worktree add -q .worktrees/linked -b linked
    ) >/dev/null 2>&1 || fail "test setup: could not build a linked worktree of a --separate-git-dir primary"
    [ -f "${TMP}/layout/sepprimary/work/primary/.worktrees/linked/scripts/setup-gh-scopes.sh" ] ||
        fail "test setup: that linked worktree has no copy of the script"
    want_sepwt="$(cd "${TMP}/layout/sepprimary/work/primary/.worktrees" && pwd -P)"
    assert_bootstrap_target "${TMP}/layout/sepprimary/work/primary/.worktrees/linked/scripts/setup-gh-scopes.sh" "${want_sepwt}" \
        "a linked worktree of a --separate-git-dir primary"
    # ...and one whose --separate-git-dir store is an ANCESTOR of the checkout:
    # <work>/.git holds the metadata, the primary is <work>/primary, and git treats
    # <work> as a working tree of that repository, so every "is it a primary"
    # predicate except the exact <primary>/.worktrees/<name> layout holds for it.
    # The target must be the linked worktree's own physical parent, never <work>'s.
    mkdir -p "${TMP}/layout/ancestor/work"
    cp -R "${TMP}/repo" "${TMP}/layout/ancestor/work/primary"
    (
        cd "${TMP}/layout/ancestor/work/primary"
        git init -q --separate-git-dir "${TMP}/layout/ancestor/work/.git"
        git add -A
        git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false \
            -c core.hooksPath=/dev/null commit -q -m fixture
        git worktree add -q .worktrees/linked -b linked
    ) >/dev/null 2>&1 || fail "test setup: could not build a linked worktree of a primary whose git directory is an ancestor"
    [ -f "${TMP}/layout/ancestor/work/primary/.worktrees/linked/scripts/setup-gh-scopes.sh" ] ||
        fail "test setup: the ancestor-store linked worktree has no copy of the script"
    want_ancwt="$(cd "${TMP}/layout/ancestor/work/primary/.worktrees" && pwd -P)"
    assert_bootstrap_target "${TMP}/layout/ancestor/work/primary/.worktrees/linked/scripts/setup-gh-scopes.sh" "${want_ancwt}" \
        "a linked worktree of a primary whose --separate-git-dir store is an ancestor"
    rm -rf "${TMP}/layout"

    echo "==> bootstrap-related-repos.sh failure does not change exit status of setup-gh-scopes"
    bootstrap_fixture failure
    cat <<EOF >"${BOOTSTRAP}"
#!/usr/bin/env bash
exit 1
EOF
    [ "$(rc_pty_of lands-after-refresh GH_HOST=github.com)" = 0 ] ||
        fail "setup-gh-scopes must succeed even if bootstrap-related-repos.sh exits non-zero"

    echo "==> bootstrap is NOT triggered if refresh does not land"
    bootstrap_fixture refused
    rm -f "${TMP}/refused-bootstrap-marker"
    cat <<EOF >"${BOOTSTRAP}"
#!/usr/bin/env bash
touch "${TMP}/refused-bootstrap-marker"
exit 0
EOF
    chmod +x "${BOOTSTRAP}"
    out="$(run_sut_pty does-not-land GH_HOST=github.com)"
    case "$out" in
    *"Bootstrapping related repos"*) fail "bootstrap should not be invoked when grant verification fails: ${out}" ;;
    esac
    sleep 0.5
    [ ! -f "${TMP}/refused-bootstrap-marker" ] || fail "bootstrap marker was created even though grant verification failed"

    SUT="${TMP}/repo/scripts/setup-gh-scopes.sh"
    rm -rf "${TMP}/repo/.devcontainer"

    echo "==> FAILS when the refresh silently did not land"
    # The whole reason this script verifies rather than trusting the exit code.
    out="$(run_sut_pty does-not-land GH_HOST=github.com)"
    case "$out" in
    *"did not grant"*) ;;
    *) fail "a refresh that did not land must fail loudly, got: ${out}" ;;
    esac
    [ "$(rc_pty_of does-not-land GH_HOST=github.com)" != 0 ] ||
        fail "an unlanded refresh must exit non-zero from the verification path"
    [ "$(rc_pty_of lands-after-refresh GH_HOST=github.com)" = 0 ] ||
        fail "a landed refresh must exit zero (else the case above proves nothing)"

    echo "==> another account's scopes cannot verify the refreshed one"
    # gh auth refresh updates only the ACTIVE account; reading every account on the
    # host would let an unrelated login satisfy the requirement.
    out="$(run_sut_pty inactive-has-scope GH_HOST=github.com)"
    case "$out" in
    *"All requested GitHub CLI scopes are present"*) fail "an inactive account's scopes verified the active one: ${out}" ;;
    *"did not grant"*) ;;
    *) fail "expected the active account's missing scopes to be reported, got: ${out}" ;;
    esac

    echo "==> a refresh that grants only read:project FAILS"
    # The alternation `project|read:project` is right for the status check —
    # either proves the credential was minted with Projects in mind. It is
    # wrong here: the refresh asked for both, and coming back with only the
    # read grant leaves board writes broken while satisfying the alternation.
    out="$(run_sut_pty read-only-grant GH_HOST=github.com)"
    case "$out" in
    *"All requested GitHub CLI scopes are present"*) fail "a read-only grant was reported as success: ${out}" ;;
    *"did not grant"*"project"*) ;;
    *) fail "expected the missing write scope to be reported, got: ${out}" ;;
    esac

    echo "==> a write-only grant is accepted (project implies read:project)"
    # Reported with only 'project', which subsumes 'read:project' — so nothing
    # is missing, and the run must succeed rather than report a missing scope.
    out="$(run_sut_pty write-only-grant GH_HOST=github.com)"
    case "$out" in
    *"did not grant"*) fail "'project' subsumes 'read:project' and must not fail: ${out}" ;;
    esac
    [ "$(rc_pty_of write-only-grant GH_HOST=github.com)" = 0 ] ||
        fail "a write-only grant must exit zero: ${out}"

    echo "==> an already-complete credential is NOT refreshed"
    # `gh auth refresh` opens a browser even when it would change nothing, so
    # the documented sequence (log in with the derived scopes, then run this to
    # verify) would authenticate twice, and every re-run would repeat it.
    STUB_CALLS="${TMP}/complete-calls.txt"
    export STUB_CALLS
    : >"${STUB_CALLS}"
    out="$(run_sut_pty lands GH_HOST=github.com)"
    if grep -q 'auth refresh' "${STUB_CALLS}"; then
        fail "refreshed a credential that needed nothing: $(tr '\n' ' ' <"${STUB_CALLS}")"
    fi
    unset STUB_CALLS
    case "$out" in
    *"GitHub CLI scopes are already ready"*) ;;
    *) fail "expected the no-op path to say so, got: ${out}" ;;
    esac
    [ "$(rc_pty_of lands GH_HOST=github.com)" = 0 ] ||
        fail "the already-complete path must exit zero"

    echo "==> a stored fine-grained token is refused BEFORE any refresh"
    # `gh auth refresh` against a fine-grained PAT completes a device flow and
    # stores a new CLASSIC token — silently replacing a deliberately narrow
    # credential with a broad one. The refusal has to precede the mutation, so
    # this asserts on the call log, not just the message.
    #
    # The stub prints NO scope line, which is what current gh does for a
    # fine-grained PAT — the shape that previously slipped past the guard.
    STUB_CALLS="${TMP}/fg-calls.txt"
    export STUB_CALLS
    : >"${STUB_CALLS}"
    out="$(run_sut_pty fine-grained GH_HOST=github.com)"
    if grep -q 'auth refresh' "${STUB_CALLS}"; then
        fail "refreshed a fine-grained credential: $(tr '\n' ' ' <"${STUB_CALLS}")"
    fi
    unset STUB_CALLS
    case "$out" in
    *"fine-grained PAT or a GitHub App"*"where that token was issued"*) ;;
    *) fail "expected the source-side remedy for a fine-grained token, got: ${out}" ;;
    esac
    [ "$(rc_pty_of fine-grained GH_HOST=github.com)" != 0 ] ||
        fail "the fine-grained refusal must exit non-zero"

    echo "==> a stored classic PAT is refused, despite reporting OAuth scopes"
    # The one prefix that looks safe and is not. `gh auth refresh` has no way to
    # edit a credential GitHub issued outside the OAuth flow, so it mints a new
    # OAuth token and stores it over the PAT. Verified against gh 2.97.0: a
    # stored ghp_ token sends `gh auth refresh` straight into the device flow.
    # The stub reports INCOMPLETE scopes, so nothing short-circuits before the
    # refresh — a missing refusal shows up in the call log.
    STUB_CALLS="${TMP}/pat-calls.txt"
    export STUB_CALLS
    : >"${STUB_CALLS}"
    out="$(run_sut_pty classic-pat GH_HOST=github.com)"
    if grep -q 'auth refresh' "${STUB_CALLS}"; then
        fail "refreshed a classic PAT: $(tr '\n' ' ' <"${STUB_CALLS}")"
    fi
    unset STUB_CALLS
    case "$out" in
    *"classic personal access token"*"settings/tokens"*) ;;
    *) fail "expected the re-issue remedy for a classic PAT, got: ${out}" ;;
    esac
    [ "$(rc_pty_of classic-pat GH_HOST=github.com)" != 0 ] ||
        fail "the classic-PAT refusal must exit non-zero"

    echo "==> the classic-PAT remedy names the RESOLVED host, not github.com"
    # A GHES or ghe.com credential is re-issued on that host's own settings
    # page. Hardcoding github.com sends the operator somewhere that cannot
    # reissue the credential being diagnosed.
    out="$(run_sut_pty classic-pat GH_HOST=ghe.example.com)"
    case "$out" in
    *"https://ghe.example.com/settings/tokens"*) ;;
    *) fail "expected the enterprise host in the re-issue URL, got: ${out}" ;;
    esac
    case "$out" in
    *"https://github.com/settings/tokens"*)
        fail "the remedy named github.com on an enterprise host: ${out}"
        ;;
    esac

    echo "==> an unidentifiable credential fails closed"
    # A prefix GitHub adds later, or a `gh auth token` that errors. Proceeding
    # would refresh an unknown credential class — the exact broadening the
    # guard above exists to prevent — so the unknown case must refuse, and must
    # name the remedy for the legitimate under-scoped OAuth user it may catch.
    STUB_CALLS="${TMP}/unknown-calls.txt"
    export STUB_CALLS
    : >"${STUB_CALLS}"
    out="$(run_sut_pty unknown-credential GH_HOST=github.com)"
    if grep -q 'auth refresh' "${STUB_CALLS}"; then
        fail "refreshed an unidentifiable credential: $(tr '\n' ' ' <"${STUB_CALLS}")"
    fi
    unset STUB_CALLS
    case "$out" in
    *"could not identify the credential class"*"gh auth login"*) ;;
    *) fail "expected a fail-closed refusal naming the login remedy, got: ${out}" ;;
    esac
    [ "$(rc_pty_of unknown-credential GH_HOST=github.com)" != 0 ] ||
        fail "the unidentifiable-credential refusal must exit non-zero"

    echo "==> the token value is never printed"
    # The script prints scope LINES; nothing it captures may contain a credential,
    # and the stub's scope lines are the only thing it is allowed to echo back.
    out="$(run_sut_pty lands GH_HOST=github.com)"
    case "$out" in
    *ghp_* | *gho_*) fail "something token-shaped reached the output: ${out}" ;;
    esac
else
    echo "    (skipped: no controlling terminal — cannot allocate a pty for the"
    echo "     interactive path; the refusals above are covered without one)"
fi

echo "==> gh_target_host resolves the CREDENTIAL host, not the SSH endpoint"
# gh stores one credential per credential host. `ssh.github.com` is GitHub's
# SSH-over-443 endpoint — a transport address, never a credential host — so a
# parser that returns it verbatim makes every caller (the status scope check,
# and this script's own --hostname) ask about a host nobody is logged in to.
# AGENTS.md documents both spellings of that remote as supported, so it is a
# normal input rather than an exotic one.
#
# Driven through a scratch repo's real `remote.origin.url`, because that is what
# the function reads; stubbing git would test the stub. GH_HOST is scrubbed at
# the top of this file, and the function short-circuits on it when set.
host_fixture="${TMP}/host-fixture"
mkdir -p "${host_fixture}"
git -C "${host_fixture}" init -q
# Resolved BEFORE the subshell cds into the fixture — `scopes_lib` is relative
# to the repo root, and resolving it after the cd looks for ./scripts there.
scopes_lib_abs="$(cd "$(dirname "${scopes_lib}")" && pwd)/$(basename "${scopes_lib}")"
gh_target_host_for() {
    git -C "${host_fixture}" remote remove origin 2>/dev/null || true
    git -C "${host_fixture}" remote add origin "$1"
    (cd "${host_fixture}" && . "${scopes_lib_abs}" && gh_target_host)
}
while IFS='|' read -r url want; do
    [ -n "${url}" ] || continue
    got="$(gh_target_host_for "${url}")"
    [ "${got}" = "${want}" ] ||
        fail "gh_target_host ${url}: expected ${want}, got ${got}"
done <<'EOF'
ssh://git@ssh.github.com:443/evanharmon1/harmon-devkit.git|github.com
ssh://git@ssh.github.com/evanharmon1/harmon-devkit.git|github.com
git@ssh.github.com:evanharmon1/harmon-devkit.git|github.com
ssh://git@github.com/evanharmon1/harmon-devkit.git|github.com
git@github.com:evanharmon1/harmon-devkit.git|github.com
https://github.com/evanharmon1/harmon-devkit.git|github.com
ssh://git@ghe.example.com:22/team/repo.git|ghe.example.com
git@ghe.example.com:team/repo.git|ghe.example.com
https://ghe.example.com/team/repo.git|ghe.example.com
EOF

echo "setup-gh-scopes.sh tests passed"
