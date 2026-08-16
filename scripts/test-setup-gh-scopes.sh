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

script="./scripts/setup-gh-scopes.sh"
scopes_lib="./scripts/gh-scopes.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# A board-carrying fixture, so the required list includes the Projects scopes.
mkdir -p "${TMP}/repo/scripts"
cp "${script}" "${TMP}/repo/scripts/setup-gh-scopes.sh"
cp "${scopes_lib}" "${TMP}/repo/scripts/gh-scopes.sh"
: >"${TMP}/repo/scripts/setup-github-project.sh"
SUT="${TMP}/repo/scripts/setup-gh-scopes.sh"

fail() {
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
    *"All requested scopes present"*) ;;
    *) fail "expected success after a landed refresh, got: ${out}" ;;
    esac

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
    *"All requested scopes present"*) fail "an inactive account's scopes verified the active one: ${out}" ;;
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
    *"All requested scopes present"*) fail "a read-only grant was reported as success: ${out}" ;;
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
    *"Already complete"*) ;;
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

echo "setup-gh-scopes.sh tests passed"
