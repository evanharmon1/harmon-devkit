#!/usr/bin/env bash
# test-status.sh — unit-test the two things status.sh reports about credentials:
#
#   * "Project board writes" (`task status:gh`) — the token scope the claim
#     lifecycle needs, reported from the section session-start orientation
#     actually runs, in every scope state.
#   * "Local credentials" (`task status:creds` and `task status:setup`) — the gh
#     and Codex logins the Dev Loop gates on, in every state including
#     not-installed, rendered as its own section for the session-start hook AND
#     inside the setup audit BEFORE the gate that skips the rest of it, counted
#     by the summary at the end of that audit, and — standalone — spending
#     exactly one bounded network call, for the token scopes alone (#827).
#
# Run via `task test:status`.
#
# Hermetic in two directions:
#
#   * every `gh` call is answered by a stub on PATH, so this makes no network
#     requests and cannot depend on the scopes of the developer's own token —
#     which is the whole point. The bug it guards (a claim that silently no-ops
#     on a token without the scope) is INVISIBLE when tested with a token that
#     has it.
#   * the checks run against fixture roots this script builds, never against the
#     repo it lives in. status.sh resolves its own root from BASH_SOURCE and
#     feature-detects the board tooling from it, so a test that used the host
#     repo would assert one profile's layout and fail in every other — a repo
#     generated with `project_management: none` correctly omits the check.
set -euo pipefail
cd "$(dirname "$0")/.."
status="./scripts/status.sh"
# status.sh sources the required-scope list from its sibling; every fixture root
# below therefore needs both files, not just the script under test.
scopes_lib="./scripts/gh-scopes.sh"
output_lib="./scripts/lib/output.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Four fixture roots, each holding a copy of the script under test:
#   with-board  — has the board tooling, so the check applies
#   no-board    — has none of it, so the check must not render at all
#   skills-only — the DEFAULT generated profile: `project_management: none` with
#                 `use_skills_sync: true`, so the vendored universal skill set
#                 (track-work included) is present but there is no board
#   with-codex  — opted into second-model review, so the Codex login is a gate.
#                 The other three have no codex-review.sh, which is what makes
#                 them the not-opted-in case for that check.
#   creds-board — codex opted in AND board tooling present, so the session-start
#                 scope check demands the Projects scopes. Its twin below
#                 (with-codex, no board) is what proves that demand is gated.
#   org-repo    — an ORG repo (github_org != the author's account), which
#                 renders the issue-types setup and therefore needs admin:org.
for fixture in with-board no-board skills-only with-codex creds-board org-repo; do
    mkdir -p "${TMP}/${fixture}/scripts/lib"
    cp "${status}" "${TMP}/${fixture}/scripts/status.sh"
    cp "${scopes_lib}" "${TMP}/${fixture}/scripts/gh-scopes.sh"
    cp "${output_lib}" "${TMP}/${fixture}/scripts/lib/output.sh"
done
# The markers status.sh feature-detects on. Contents are never read.
: >"${TMP}/with-board/scripts/setup-github-project.sh"
: >"${TMP}/with-codex/scripts/codex-review.sh"
: >"${TMP}/creds-board/scripts/codex-review.sh"
: >"${TMP}/creds-board/scripts/setup-github-project.sh"
: >"${TMP}/org-repo/scripts/codex-review.sh"
: >"${TMP}/org-repo/scripts/setup-github-issue-types.sh"
mkdir -p "${TMP}/skills-only/.claude/skills/track-work/assets"
: >"${TMP}/skills-only/.claude/skills/track-work/assets/set-issue-status.sh"

# A board repo whose remote is a GitHub Enterprise host, and which exports no
# GH_HOST — the case where forcing github.com disowns a valid login.
mkdir -p "${TMP}/enterprise/scripts/lib"
cp "${status}" "${TMP}/enterprise/scripts/status.sh"
cp "${scopes_lib}" "${TMP}/enterprise/scripts/gh-scopes.sh"
cp "${output_lib}" "${TMP}/enterprise/scripts/lib/output.sh"
: >"${TMP}/enterprise/scripts/setup-github-project.sh"
git -C "${TMP}/enterprise" init -q
git -C "${TMP}/enterprise" remote add origin git@ghe.example.com:owner/repo.git

WITH_BOARD="${TMP}/with-board/scripts/status.sh"
NO_BOARD="${TMP}/no-board/scripts/status.sh"
SKILLS_ONLY="${TMP}/skills-only/scripts/status.sh"
ENTERPRISE="${TMP}/enterprise/scripts/status.sh"
WITH_CODEX="${TMP}/with-codex/scripts/status.sh"
CREDS_BOARD="${TMP}/creds-board/scripts/status.sh"
ORG_REPO="${TMP}/org-repo/scripts/status.sh"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

# make_stub SCENARIO — write $TMP/bin/gh answering `auth status` per SCENARIO.
# Every other gh call returns an empty JSON array: status.sh reads pr/run lists
# through jq, and a stub that failed them would exercise the wrong code path.
# An unrecognized call exits non-zero rather than defaulting to success, so a
# future probe added to this section shows up here instead of passing silently.
make_stub() {
    local scenario="$1"
    mkdir -p "${TMP}/bin"
    {
        echo '#!/usr/bin/env bash'
        # A call log, so a case can assert on which gh calls a section made
        # rather than only on what it printed. The standalone credentials
        # section's contract is "no network call", and the only way to see a
        # network call that a stub happily answers is to look at the log.
        echo 'if [ -n "${STUB_CALLS:-}" ]; then echo "$*" >>"$STUB_CALLS"; fi'
        echo 'if [ "$1" = "auth" ] && [ "$2" = "status" ]; then'
        case "$scenario" in
        project)
            echo "    echo \"  - Token scopes: 'gist', 'project', 'repo'\""
            echo '    exit 0'
            ;;
        read-only)
            echo "    echo \"  - Token scopes: 'gist', 'read:project', 'repo'\""
            echo '    exit 0'
            ;;
        none)
            echo "    echo \"  - Token scopes: 'gist', 'read:org', 'repo', 'workflow'\""
            echo '    exit 0'
            ;;
        unparseable)
            # Authenticated, but the scopes are not reported in the form we
            # parse — a GitHub App installation token, or a future gh that
            # renames the line. Must read as "unknown", never as satisfied.
            echo '    echo "  x Logged in to github.com"'
            echo '    exit 0'
            ;;
        unauthenticated)
            echo '    echo "You are not logged into any GitHub hosts." >&2'
            echo '    exit 1'
            ;;
        fine-grained)
            # A fine-grained PAT or App token: permissions, not OAuth scopes, so
            # gh reports the line with nothing in it.
            echo '    echo "  - Token scopes: none"'
            echo '    exit 0'
            ;;
        inactive-has-scope)
            # Two accounts on one host; only the INACTIVE one holds 'project'.
            # A stub that ignores --active proves the aggregate-read bug; this
            # one honours it, so the check must read the active account's line.
            echo '    if [ "$3" = "--active" ]; then'
            echo "        echo \"  - Active account: true\""
            echo "        echo \"  - Token scopes: 'gist', 'repo'\""
            echo '    else'
            echo "        echo \"  - Token scopes: 'gist', 'repo'\""
            echo "        echo \"  - Token scopes: 'gist', 'project', 'repo'\""
            echo '    fi'
            echo '    exit 0'
            ;;
        env-token-no-scope)
            # A classic PAT supplied through GH_TOKEN: it reports real scopes, so
            # the scope verdict is correct — but `gh auth refresh` edits the
            # stored credential, which this one overrides, so that remedy cannot
            # work here.
            echo '    echo "  X Failed to log in to github.com using token (GH_TOKEN)"'
            echo "    echo \"  - Token scopes: 'gist', 'repo'\""
            echo '    exit 0'
            ;;
        enterprise-env-token)
            # GH_ENTERPRISE_TOKEN is how gh authenticates against GHES from the
            # environment. Same override problem as GH_TOKEN, different name.
            echo '    echo "  X Failed to log in using token (GH_ENTERPRISE_TOKEN)"'
            echo "    echo \"  - Token scopes: 'gist', 'repo'\""
            echo '    exit 0'
            ;;
        records-hostname)
            # Records the --hostname it was handed, and only authenticates for
            # the Enterprise host — so forcing github.com fails the probe and
            # takes the whole section down, exactly as the real gh would.
            echo '    host=""; prev=""'
            echo '    for a in "$@"; do case "$prev" in --hostname) host="$a" ;; esac; prev="$a"; done'
            echo '    echo "$host" >>"$STUB_HOSTS"'
            echo '    if [ "$host" != "ghe.example.com" ]; then'
            echo '        echo "You are not logged into any GitHub hosts." >&2'
            echo '        exit 1'
            echo '    fi'
            echo "    echo \"  - Token scopes: 'gist', 'project', 'repo'\""
            echo '    exit 0'
            ;;
        other-host-has-scope)
            # Two hosts; only the unrelated one holds 'project'. A stub that
            # ignores --hostname proves the cross-host bug; this one honours it,
            # so the check must read the targeted host's line only.
            echo "    host=\"\"; prev=\"\""
            echo '    for a in "$@"; do case "$prev" in --hostname) host="$a" ;; esac; prev="$a"; done'
            echo '    if [ "$host" = "github.com" ]; then'
            echo "        echo \"  - Token scopes: 'gist', 'repo'\""
            echo '    else'
            echo "        echo \"  - Token scopes: 'gist', 'project', 'repo'\""
            echo '    fi'
            echo '    exit 0'
            ;;
        no-active-flag)
            # gh predates --active (pre-2.40): the flag is a usage error, which
            # must not read as a failed login.
            echo '    if [ "$3" = "--active" ]; then'
            echo '        echo "unknown flag: --active" >&2'
            echo '        exit 1'
            echo '    fi'
            echo "    echo \"  - Token scopes: 'gist', 'project', 'repo'\""
            echo '    exit 0'
            ;;
        hangs)
            # Outlives the probe's deadline. Driven with NETWORK_TIMEOUT=1 so
            # the case costs a second rather than the default five.
            echo '    sleep 30'
            echo '    exit 0'
            ;;
        broken-token-store)
            # Authenticated as far as the API is concerned, but the LOCAL
            # credential read fails for a reason `gh auth login` cannot repair —
            # a locked keychain, an unreadable hosts.yml. Deliberately does NOT
            # carry gh's no-credential wording: that is the whole distinction.
            echo "    echo \"  - Token scopes: 'gist', 'project', 'repo'\""
            echo '    exit 0'
            ;;
        fully-scoped)
            # Every required scope. The session-start check must then say
            # nothing at all.
            echo "    echo \"  - Token scopes: 'read:project', 'project', 'repo', 'workflow'\""
            echo '    exit 0'
            ;;
        creds-read-project)
            # Projects READ only. Satisfies the session-start "was this
            # credential minted with Projects in mind" check via the
            # `project|read:project` alternation, while still failing the
            # board-WRITE check in the GitHub section.
            echo "    echo \"  - Token scopes: 'read:project', 'repo', 'workflow'\""
            echo '    exit 0'
            ;;
        scope-probe-fails)
            # The LOCAL credential read succeeds (see `auth token` below) but
            # the scope probe cannot answer — a network blip, a proxy. Must be
            # silence, never an accusation.
            echo '    echo "error connecting to github.com" >&2'
            echo '    exit 1'
            ;;
        no-workflow)
            # A credential that satisfies the Projects half but not the
            # unconditional half of the list.
            echo "    echo \"  - Token scopes: 'repo', 'project', 'read:project'\""
            echo '    exit 0'
            ;;
        *) fail "unknown stub scenario: ${scenario}" ;;
        esac
        echo 'fi'
        # `gh auth token` is the standalone credentials section's LOCAL read: it
        # prints the stored/environment credential without calling GitHub. The
        # stub answers it from the same scenario as `auth status` so the two
        # cannot disagree, and prints a placeholder rather than nothing because
        # the real command's output IS the token — a probe that captured or
        # echoed it would show up as this string in the assertions.
        echo 'if [ "$1" = "auth" ] && [ "$2" = "token" ]; then'
        case "$scenario" in
        unauthenticated)
            echo '    echo "no oauth token" >&2'
            echo '    exit 1'
            ;;
        hangs)
            echo '    sleep 30'
            echo '    exit 0'
            ;;
        broken-token-store)
            echo '    echo "error: failed to read keyring: interaction denied" >&2'
            echo '    exit 1'
            ;;
        *)
            echo '    echo "STUB-TOKEN-MUST-NEVER-BE-PRINTED"'
            echo '    exit 0'
            ;;
        esac
        echo 'fi'
        echo 'case "$*" in'
        echo '*"pr list"* | *"run list"*) echo "[]" ;;'
        echo '*) echo "stub: unexpected gh call: $*" >&2; exit 1 ;;'
        echo 'esac'
    } >"${TMP}/bin/gh"
    chmod +x "${TMP}/bin/gh"
}

# run_gh_section SCENARIO [SCRIPT] — status.sh's gh section, with the stub on
# PATH. SCRIPT defaults to the with-board fixture. NO_COLOR keeps the assertions
# free of ANSI escapes.
run_gh_section() {
    make_stub "$1"
    local script="${2:-${WITH_BOARD}}"
    PATH="${TMP}/bin:${PATH}" NO_COLOR=1 "${script}" gh 2>&1
}

# make_codex_stub STATE — write $TMP/bin/codex answering `login status`.
#   in     — logged in (exit 0, as the real CLI's "Logged in using ChatGPT")
#   out    — not logged in (exit 1, as its "Not logged in")
#   broken — the CLI could not run at all: a malformed config.toml exits non-zero
#            like a logout does, but says nothing about credentials
# All three write their verdict to STDERR with an empty stdout, which is what the
# shipped CLI does — a probe that read stdout alone would see nothing from any of
# them. Any other call fails loudly: the credentials group must read local login
# state and nothing else, so a probe that grew a second codex call — or a network
# one — shows up here instead of passing silently.
make_codex_stub() {
    local state="$1"
    mkdir -p "${TMP}/bin"
    {
        echo '#!/usr/bin/env bash'
        echo 'if [ "$1" = "login" ] && [ "$2" = "status" ]; then'
        case "$state" in
        in)
            # Unrelated stderr chatter alongside a SUCCESSFUL probe: some
            # installs emit this while still exiting 0, so a check that read
            # stderr being non-empty as failure would report a logged-in reader
            # as broken.
            echo '    echo "ERROR codex_models_manager::cache: failed to load models cache" >&2'
            echo '    echo "Logged in using ChatGPT" >&2'
            echo '    exit 0'
            ;;
        out)
            echo '    echo "Not logged in" >&2'
            echo '    exit 1'
            ;;
        broken)
            # Deliberately does NOT carry the logged-out phrase — that is the
            # whole distinction under test.
            echo '    echo "Error: failed to parse config.toml: invalid TOML at line 3" >&2'
            echo '    exit 1'
            ;;
        *) fail "unknown codex stub state: ${state}" ;;
        esac
        echo 'fi'
        echo 'echo "stub: unexpected codex call: $*" >&2'
        echo 'exit 1'
    } >"${TMP}/bin/codex"
    chmod +x "${TMP}/bin/codex"
}

# make_claude_stub STATE — write $TMP/bin/claude answering `auth status --json`.
#   in      — logged in
#   out     — logged out: a NORMAL, successful report carrying loggedIn:false,
#             which is why the check reads the field and not the exit code
#   ancient — a `claude` predating `auth status`: a usage error with no field,
#             which must read as unknown rather than as a logout
# Any other call fails loudly: this probe must read local login state and nothing
# else, so a second call — or a network one — shows up here instead of passing
# silently.
make_claude_stub() {
    local state="$1"
    mkdir -p "${TMP}/bin"
    {
        echo '#!/usr/bin/env bash'
        echo 'if [ "$1" = "auth" ] && [ "$2" = "status" ]; then'
        case "$state" in
        in)
            echo '    echo "{ \"loggedIn\": true, \"authMethod\": \"claude.ai\" }"'
            echo '    exit 0'
            ;;
        out)
            echo '    echo "{ \"loggedIn\": false }"'
            echo '    exit 0'
            ;;
        ancient)
            echo '    echo "error: unknown command auth" >&2'
            echo '    exit 1'
            ;;
        *) fail "unknown claude stub state: ${state}" ;;
        esac
        echo 'fi'
        echo 'echo "stub: unexpected claude call: $*" >&2'
        echo 'exit 1'
    } >"${TMP}/bin/claude"
    chmod +x "${TMP}/bin/claude"
}

# The credentials group probes codex and claude on every invocation, so stub both
# before the first case runs — a case that reached the real CLI would pass or fail on
# whether the developer happens to be logged in, which is worse than no test at
# all.
make_codex_stub in
make_claude_stub in

# ISOLATED_TOOLS — the external commands status.sh needs, both to reach the
# credentials group and to run the audit past the gh gate. The not-installed case
# pins PATH to a single directory built from this list, because filtering the
# real PATH is not enough: the devcontainer installs codex into /usr/bin,
# alongside git, grep, and jq, so dropping the directory that holds it would take
# the toolbox with it. `bash` is on the list because status.sh and the stubs both
# start with `#!/usr/bin/env bash`, which resolves bash through the PATH set here.
ISOLATED_TOOLS="bash awk basename cat cut dirname find git grep head jq mktemp rm sed sort tr uniq wc timeout gtimeout"

# make_isolated_bin MISSING — a bin directory holding a symlink to each tool
# above that exists here, plus the stubs written so far, minus MISSING. Whatever
# is not in it is genuinely unreachable for the run: a not-installed case that
# passed only because this machine happens to lack the CLI would prove nothing.
make_isolated_bin() {
    local missing="$1" tool="" resolved=""
    rm -rf "${TMP}/bin-iso"
    mkdir -p "${TMP}/bin-iso"
    for tool in ${ISOLATED_TOOLS}; do
        resolved="$(command -v "${tool}" 2>/dev/null || true)"
        if [ -n "${resolved}" ]; then
            ln -s "${resolved}" "${TMP}/bin-iso/${tool}"
        fi
    done
    for tool in gh codex claude; do
        if [ "${tool}" != "${missing}" ] && [ -f "${TMP}/bin/${tool}" ]; then
            cp "${TMP}/bin/${tool}" "${TMP}/bin-iso/${tool}"
        fi
    done
    # A degraded isolated PATH does not fail loudly — it fails as a PASS. Lose
    # grep and the gh auth probe never finds its scope line, so an authenticated
    # stub reads as logged out and the summary cases never reach the gate; lose
    # jq and the run past the gate dies at the first unguarded `jq -r` (127 under
    # set -e), taking the Summary line those cases assert on with it. Either
    # would satisfy an assertion written for a different reason, so check that
    # the load-bearing tools actually resolved — a broken symlink fails -x —
    # rather than trusting the loop above. Not hypothetical: an earlier revision
    # of this helper built a broken grep symlink and a case passed for the wrong
    # reason.
    for tool in bash find grep jq git; do
        [ -x "${TMP}/bin-iso/${tool}" ] ||
            fail "isolated PATH lacks a working ${tool} — the cases using it would assert against a degraded run"
    done
    if [ -n "${missing}" ]; then
        [ ! -e "${TMP}/bin-iso/${missing}" ] || fail "isolated PATH still holds ${missing}"
    fi
}

# run_setup_section GH_SCENARIO [SCRIPT] — status.sh's setup section with the
# stubs on PATH. Every case drives it with `unauthenticated`: the credentials
# group renders BEFORE the gh gate, so stopping at that gate keeps the case
# hermetic — every check past it needs live GitHub data — while proving the group
# is outside it.
run_setup_section() {
    make_stub "$1"
    local script="${2:-${WITH_CODEX}}"
    PATH="${TMP}/bin:${PATH}" NO_COLOR=1 "${script}" setup 2>&1
}

# run_creds_section GH_SCENARIO [SCRIPT] — status.sh's standalone credentials
# section (`task status:creds`, the one the session-start hook runs) with the
# stubs on PATH. SCRIPT defaults to the with-codex fixture, the profile in which
# the Codex login is a gate.
run_creds_section() {
    make_stub "$1"
    local script="${2:-${WITH_CODEX}}"
    PATH="${TMP}/bin:${PATH}" NO_COLOR=1 "${script}" creds 2>&1
}

# run_setup_without MISSING [SCRIPT] — the same, with MISSING genuinely absent
# from PATH. Callers write the stubs they want first.
run_setup_without() {
    local missing="$1" script="${2:-${WITH_CODEX}}"
    make_isolated_bin "${missing}"
    PATH="${TMP}/bin-iso" NO_COLOR=1 "${script}" setup 2>&1
}

# run_setup_isolated GH_SCENARIO [SCRIPT] — the setup section PAST the gh gate,
# on the isolated PATH so every check beyond it reads the same on any machine:
# no op, no direnv, no brew, no node. The summary cases below compare counts
# between two runs, and a tool that merely happens to be installed here would
# move both numbers.
run_setup_isolated() {
    make_stub "$1"
    make_isolated_bin ""
    local script="${2:-${WITH_CODEX}}"
    PATH="${TMP}/bin-iso" NO_COLOR=1 "${script}" setup 2>&1
}

# summary_field OUTPUT NAME — the count NAME carries on status.sh's Summary line
# (`2 ok · 3 missing · 0 unknown · 4 n/a`). Empty when there is no such line,
# which is how a case detects that the gh gate stopped the run short.
summary_field() {
    printf '%s\n' "$1" | sed -n -E "s#.*Summary:.*[^0-9]([0-9]+) $2.*#\1#p" | head -1
}

echo "==> a token with 'project' reports the board as writable"
out="$(run_gh_section project)"
case "$out" in
*"Project board writes"*"token has 'project'"*) ;;
*) fail "expected a satisfied board-writes line, got: ${out}" ;;
esac

echo "==> read-only 'read:project' is NOT reported as satisfied"
# The state most easily mistaken for working: --show reads the card fine, so the
# board looks reachable right up to the write that moves it.
out="$(run_gh_section read-only)"
case "$out" in
*"token has 'project'"*) fail "read:project must not satisfy a WRITE check: ${out}" ;;
*"read-only"*"task setup:gh-scopes"*) ;;
*) fail "expected a read-only warning naming the remedy, got: ${out}" ;;
esac

echo "==> a token with neither scope warns and names the remedy"
out="$(run_gh_section none)"
case "$out" in
*"lacks 'project'"*"task setup:gh-scopes"*) ;;
*) fail "expected a missing-scope warning naming the remedy, got: ${out}" ;;
esac

echo "==> unreadable scopes read as unknown, not as satisfied"
out="$(run_gh_section unparseable)"
case "$out" in
*"token has 'project'"*) fail "an unparseable scope list must not pass: ${out}" ;;
*"could not read token scopes"*) ;;
*) fail "expected an unknown-scopes line, got: ${out}" ;;
esac

echo "==> an unauthenticated gh skips the section without erroring"
out="$(run_gh_section unauthenticated)"
case "$out" in
*"not authenticated"*) ;;
*) fail "expected the unauthenticated skip, got: ${out}" ;;
esac
case "$out" in
*"Project board writes"*) fail "board-writes line rendered without auth: ${out}" ;;
esac

echo "==> a repo with no project tooling omits the check entirely"
# Not-applicable is not the same as fine: a repo generated with
# `project_management: none` has no board to write to, and a warning there would
# be noise the reader cannot act on.
out="$(run_gh_section project "${NO_BOARD}")"
case "$out" in
*"Project board writes"*) fail "board-writes line rendered in a repo with no board tooling: ${out}" ;;
esac

echo "==> the vendored track-work skill alone does NOT trigger the check"
# The default generated profile: `project_management: none` (the default) with
# `use_skills_sync: true` vendors the universal skill set, so keying the check on
# track-work's presence would demand the `project` scope from every repo that
# merely completed the documented skills-sync step.
out="$(run_gh_section none "${SKILLS_ONLY}")"
case "$out" in
*"Project board writes"*) fail "the skill's presence must not imply a board: ${out}" ;;
esac

echo "==> a fine-grained/App token reads as unknown, with the right remedy"
# Its Projects access is a permission, not a scope, so it may well be able to
# write — and `gh auth refresh` cannot change it either way.
out="$(run_gh_section fine-grained)"
case "$out" in
*"lacks 'project'"*) fail "a scope-less token must not be reported as lacking a scope: ${out}" ;;
*"no OAuth scopes reported"*) ;;
*) fail "expected the fine-grained-token notice, got: ${out}" ;;
esac
case "$out" in
*"gh auth refresh"*) fail "gh auth refresh cannot fix a fine-grained token: ${out}" ;;
esac

echo "==> an inactive account's scopes cannot answer for the active one"
out="$(run_gh_section inactive-has-scope)"
case "$out" in
*"token has 'project'"*) fail "read the ACTIVE account's scopes, not every account's: ${out}" ;;
*"lacks 'project'"*) ;;
*) fail "expected the active account's missing scope to be reported, got: ${out}" ;;
esac

echo "==> an env-provided token gets a remedy that can actually work"
# The scope verdict is right; only the fix differs. `gh auth refresh` edits the
# stored credential, which GH_TOKEN overrides — so recommending it here would be
# advice that silently changes nothing.
out="$(run_gh_section env-token-no-scope)"
case "$out" in
*"gh auth refresh -s"* | *"task setup:gh-scopes"*) fail "neither a refresh nor the setup task can change an env token: ${out}" ;;
*"reissue GH_TOKEN"*) ;;
*) fail "expected an env-token remedy, got: ${out}" ;;
esac

echo "==> an Enterprise env token gets the same treatment as GH_TOKEN"
# The override problem is a property of environment tokens, not of github.com.
out="$(run_gh_section enterprise-env-token)"
case "$out" in
*"gh auth refresh -s"* | *"task setup:gh-scopes"*) fail "neither a refresh nor the setup task can change an env token: ${out}" ;;
*"reissue GH_ENTERPRISE_TOKEN"*) ;;
*) fail "expected the Enterprise env-token remedy, got: ${out}" ;;
esac

echo "==> the auth host comes from the repository, not a github.com assumption"
# A GHES repo with no GH_HOST exported. Forcing github.com would fail the probe,
# which this script reads as "not authenticated" — losing the PR list, the CI
# list, and the board-writes line all at once, while `gh pr list` would have
# worked fine against that remote.
STUB_HOSTS="${TMP}/hosts.txt"
export STUB_HOSTS
: >"${STUB_HOSTS}"
out="$(run_gh_section records-hostname "${ENTERPRISE}")"
grep -qx 'ghe.example.com' "${STUB_HOSTS}" ||
    fail "probe used $(tr '\n' ' ' <"${STUB_HOSTS}") — expected the remote's host"
case "$out" in
*"not authenticated"*) fail "a valid Enterprise login must not read as unauthenticated: ${out}" ;;
*"token has 'project'"*) ;;
*) fail "expected the Enterprise section to render, got: ${out}" ;;
esac

echo "==> GH_HOST still overrides the repository's remote"
: >"${STUB_HOSTS}"
out="$(
    make_stub records-hostname
    PATH="${TMP}/bin:${PATH}" NO_COLOR=1 \
        GH_HOST=ghe.example.com "${WITH_BOARD}" gh 2>&1
)"
grep -qx 'ghe.example.com' "${STUB_HOSTS}" ||
    fail "GH_HOST must win over the remote, got: $(tr '\n' ' ' <"${STUB_HOSTS}")"

echo "==> another host's scopes cannot answer for the targeted one"
# The scopes of an account on an unrelated host say nothing about the API calls
# this repo makes.
out="$(run_gh_section other-host-has-scope)"
case "$out" in
*"token has 'project'"*) fail "read the targeted host's scopes, not every host's: ${out}" ;;
*"lacks 'project'"*) ;;
*) fail "expected the targeted host's missing scope to be reported, got: ${out}" ;;
esac

echo "==> gh without --active falls back instead of reading as unauthenticated"
out="$(run_gh_section no-active-flag)"
case "$out" in
*"not authenticated"*) fail "a usage error must not read as a failed login: ${out}" ;;
*"token has 'project'"*) ;;
*) fail "expected the fallback to read the full report, got: ${out}" ;;
esac

echo "==> a probe that outlives its deadline says so, not 'not authenticated'"
# Bounding the auth probe made a slow network look exactly like a missing login.
# Reporting the latter for the former sends the reader to fix the wrong thing.
# Skipped where no `timeout` binary exists (stock macOS): run_timeout then runs
# the probe unbounded by design, and there is no deadline to hit.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    make_stub hangs
    out="$(PATH="${TMP}/bin:${PATH}" NO_COLOR=1 NETWORK_TIMEOUT=1 "${WITH_BOARD}" gh 2>&1)"
    case "$out" in
    *"timed out"*) ;;
    *"not authenticated"*) fail "a timeout must not be reported as missing auth: ${out}" ;;
    *) fail "expected a timeout notice, got: ${out}" ;;
    esac
else
    echo "    (skipped: no timeout binary — the probe is unbounded here)"
fi

echo "==> status:setup distinguishes a timeout from a missing login too"
# The setup section shares the one auth probe, so it inherits the probe's
# distinctions or silently loses them: on a deadline it must not tell an
# authenticated user to run `gh auth login`. Reachable hermetically because this
# gate precedes every other gh call in that section.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    make_stub hangs
    out="$(PATH="${TMP}/bin:${PATH}" NO_COLOR=1 NETWORK_TIMEOUT=1 "${WITH_BOARD}" setup 2>&1)"
    case "$out" in
    *"gh auth login"*) fail "a timeout must not be reported as a missing login: ${out}" ;;
    *"timed out"*) ;;
    *) fail "expected a timeout notice from status:setup, got: ${out}" ;;
    esac
else
    echo "    (skipped: no timeout binary — the probe is unbounded here)"
fi

echo "==> no user-facing message hardcodes the refresh remedy"
# The remedy is derived from the credential source once, because `gh auth refresh`
# is wrong for an env-provided or fine-grained token. Every message must use that
# derivation — a hardcoded copy is how one call site silently drifts back to
# advice that cannot work, and the setup section (which needs live GitHub data to
# render) cannot be driven by the stub above. So assert it statically instead:
# the literal may appear only in a comment or in the derivation itself.
while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
    *"#"*"gh auth refresh"*) continue ;; # a comment explaining the rule
    *GH_REMEDY*=*) continue ;;           # the derivation itself
    *) fail "hardcoded refresh remedy — use \${GH_REMEDY}: ${line}" ;;
    esac
done <<EOF
$(grep -n 'gh auth refresh' "${status}" || true)
EOF

echo "==> the session-start hook allows more time than this section can spend"
# A coupling that rots silently, and whose failure is total rather than partial:
# status.sh buffers each section before printing it (section_box reads all of its
# input first), so an outer deadline that fires mid-section discards everything
# the section was about to report — including the board-writes line. The section
# spends up to NETWORK_TIMEOUT on the auth probe and then up to NETWORK_TIMEOUT
# again on the PR/run probes, so the hook must allow more than twice the probe
# budget. Skipped where a hook is not generated (no devcontainer).
hook=".devcontainer/config/claude-hooks/session-start-context.sh"

# EVERY session-start hook that launches status sections under a deadline, not
# just the devcontainer one. Both ship and both are live — that one through
# claude-settings.json, the repo-local one through .agents/hooks.json — so a
# budget corrected in one of them is corrected nowhere for whoever runs the
# other. Checking only the first is how the repo-local copy kept a stale
# deadline through a change that existed to fix exactly that.
STATUS_HOOKS=".devcontainer/config/claude-hooks/session-start-context.sh .claude/hooks/session-start-context.sh"

# hook_deadline HOOK SECTION — the seconds HOOK allows `task status:SECTION`.
# Anchored on `task status:` rather than on the command, because the two hooks
# spell the deadline differently (`timeout 14` vs `"$timeout_cmd" 14`) and a
# pattern keyed to one of them silently reads nothing from the other — which is
# not a failure, just an assertion that stops asserting.
hook_deadline() {
    sed -n -E "s/.*[[:space:]]([0-9]+) task status:$2([[:space:]].*)?\$/\1/p" "$1" | head -1
}

# The seconds run_timeout waits between SIGTERM and SIGKILL. A probe that
# ignores the first spends its deadline PLUS this before the pipe it holds
# closes, so every budget below is modelled from the sum, not the deadline
# alone. Read out of status.sh rather than restated, because a grace changed
# in one place and remembered in the other is exactly how these budgets rot.
# Absent (no `-k` in run_timeout) it is zero and the sums are unchanged.
kill_grace="$(sed -n -E 's/.*"\$\{TIMEOUT_BIN\}" -k ([0-9]+) "\$\{secs\}".*/\1/p' "${status}" | head -1)"
: "${kill_grace:=0}"

probe="$(sed -n -E 's/^NETWORK_TIMEOUT="\$\{NETWORK_TIMEOUT:-([0-9]+)\}"$/\1/p' "${status}")"
[ -n "$probe" ] || fail "could not read NETWORK_TIMEOUT out of ${status}"
gh_worst="$(((probe + kill_grace) * 2))"
checked_hooks=0
for h in ${STATUS_HOOKS}; do
    [ -f "$h" ] || continue
    checked_hooks=$((checked_hooks + 1))
    budget="$(hook_deadline "$h" gh)"
    [ -n "$budget" ] || fail "could not read the status:gh timeout out of ${h}"
    [ "$budget" -gt "$gh_worst" ] ||
        fail "${h} allows ${budget}s but the section can spend ${gh_worst}s on probes alone (${probe}s deadline + ${kill_grace}s kill grace, twice) — the board-writes line is lost first"
done
[ "$checked_hooks" -gt 0 ] &&
    echo "    (checked ${checked_hooks} hook(s))" ||
    echo "    (skipped: no session-start hook in this profile)"

echo "==> the check never runs the setup section's Projects query"
# The line is fed by the auth probe the section already makes. If it ever grows a
# GraphQL call, the network cost lands in every session start — the reason the
# setup section is excluded from the default dashboard in the first place.
out="$(run_gh_section project)"
case "$out" in
*"stub: unexpected gh call"*) fail "the gh section made an unstubbed call: ${out}" ;;
esac

echo "==> the credentials group renders even when gh is unauthenticated"
# The regression that matters most. The gate below it skips the ENTIRE remaining
# audit when gh is logged out, so credentials checked inside that gate would
# surface a missing codex login only on the round trip AFTER the reader fixed gh
# — the interruption this group exists to remove.
make_codex_stub out
out="$(run_setup_section unauthenticated)"
case "$out" in
*"(gh not authenticated"*) ;;
*) fail "expected the gh skip line, got: ${out}" ;;
esac
case "$out" in
*"Codex CLI"*"codex login"*) ;;
*) fail "the credentials group must render before the gh gate: ${out}" ;;
esac

echo "==> gh's own credential line reports the state the section already probed"
# From the one bounded probe at the top of the script — no second `gh auth
# status` call, which is why this line survives a logged-out gh at all.
case "$out" in
*"[ ] GitHub CLI (gh) - gh auth login"*) ;;
*) fail "expected the gh credential line to name its remedy, got: ${out}" ;;
esac

echo "==> an authenticated codex reports ok"
make_codex_stub in
out="$(run_setup_section unauthenticated)"
case "$out" in
*"[x] Codex CLI"*) ;;
*) fail "expected codex to read as logged in, got: ${out}" ;;
esac

echo "==> a logged-out codex is missing, and names 'codex login'"
make_codex_stub out
out="$(run_setup_section unauthenticated)"
case "$out" in
*"[x] Codex CLI"*) fail "a logged-out codex must not read as ok: ${out}" ;;
*"[ ] Codex CLI - codex login"*) ;;
*) fail "expected a logged-out codex to name its remedy, got: ${out}" ;;
esac

echo "==> a repo without codex-review.sh reports codex n/a, not missing"
# `use_codex_review: false` renders no challenge/review tasks, so there is no
# stage a missing login can block — and a red line the reader cannot act on is
# how a board stops being read at all.
make_codex_stub out
out="$(run_setup_section unauthenticated "${WITH_BOARD}")"
case "$out" in
*"[ ] Codex CLI"*) fail "an opted-out repo must not report codex as missing: ${out}" ;;
*"codex login"*) fail "an opted-out repo must not prescribe a codex remedy: ${out}" ;;
*"[-] Codex CLI"*) ;;
*) fail "expected codex to read n/a without scripts/codex-review.sh, got: ${out}" ;;
esac

echo "==> a codex probe that fails for another reason reads unknown, not logged out"
# Non-zero is not the same as logged out. A malformed config.toml exits non-zero
# too, and `codex login` cannot repair it — the reader would be sent to fix the
# wrong thing, which is the failure the gh timeout branch already guards against.
# Only the documented logged-out phrase earns the login remedy.
make_codex_stub broken
out="$(run_setup_section unauthenticated)"
case "$out" in
*"[ ] Codex CLI"*) fail "a configuration failure must not read as a missing login: ${out}" ;;
*"codex login"*) fail "a configuration failure must not prescribe re-authentication: ${out}" ;;
*"[?] Codex CLI"*) ;;
*) fail "expected an unknown codex line, got: ${out}" ;;
esac

echo "==> codex missing from PATH is reported with the install remedy"
# Deterministic on a machine that HAS the real CLI: the run is pinned to an
# isolated PATH this script builds, not to the developer's.
make_stub unauthenticated
make_codex_stub in
out="$(run_setup_without codex)"
case "$out" in
*"[ ] Codex CLI"*"npm install -g @openai/codex"*) ;;
*) fail "expected an install remedy for a missing codex, got: ${out}" ;;
esac

echo "==> gh missing from PATH names an install remedy, not a login"
# The shared auth probe exits 127 when there is no gh to run, which lands in the
# same "not authenticated" bucket as a real logout — so without an explicit
# not-installed branch the line prescribes `gh auth login` to a reader who has no
# gh. Asserted against the whole credential line: the gate's own skip message
# below legitimately still names `gh auth login`, so a bare substring test for it
# would fail no matter what this line says.
make_stub unauthenticated
make_codex_stub in
out="$(run_setup_without gh)"
case "$out" in
*"GitHub CLI (gh) - gh auth login"*) fail "an absent gh must not be told to log in: ${out}" ;;
*"[ ] GitHub CLI (gh) - brew install gh"*) ;;
*) fail "expected an install remedy for a missing gh, got: ${out}" ;;
esac
# The rest of the run must still behave: an absent gh is not an authenticated
# one, so the audit past the gate stays skipped rather than erroring.
case "$out" in
*"(gh not authenticated"*) ;;
*) fail "an absent gh must still take the unauthenticated path: ${out}" ;;
esac

echo "==> a missing credential is counted in the setup summary"
# The regression behind the counters file. The credentials group tallies inside
# the subshell `| section_box` creates, so unless those counts cross the
# boundary the summary can print "0 missing" directly beneath a red ✗ Codex CLI
# line on the same screen.
#
# Reachable hermetically: past the gh gate the stubbed `gh repo view` leaves
# HAS_REMOTE false, which reduces the audit to local checks. Asserted as the
# DIFFERENCE between two otherwise identical runs — an absolute number would
# encode this machine's git-hook and devcontainer state, and the isolated PATH
# pins the rest.
make_codex_stub in
in_out="$(run_setup_isolated project)"
make_codex_stub out
out_out="$(run_setup_isolated project)"
in_ok="$(summary_field "${in_out}" ok)"
in_no="$(summary_field "${in_out}" missing)"
out_ok="$(summary_field "${out_out}" ok)"
out_no="$(summary_field "${out_out}" missing)"
{ [ -n "${in_ok}" ] && [ -n "${in_no}" ] && [ -n "${out_ok}" ] && [ -n "${out_no}" ]; } ||
    fail "no Summary line to read — the run did not get past the gh gate: ${out_out}"
[ "${out_no}" -eq "$((in_no + 1))" ] ||
    fail "a logged-out codex must add 1 to the summary's missing count (${in_no} -> ${out_no}): ${out_out}"
[ "${out_ok}" -eq "$((in_ok - 1))" ] ||
    fail "a logged-out codex must drop 1 from the summary's ok count (${in_ok} -> ${out_ok}): ${out_out}"

echo "==> an n/a credential lands in the summary's n/a tally, not its total"
# The counters cross as four separate numbers, so a fold that mixed them up
# would show here: n/a is excluded from setup_total by design, so switching one
# check from ok to n/a must move the n/a tally without adding to the total.
in_na="$(summary_field "${in_out}" 'n/a')"
na_out="$(run_setup_isolated project "${WITH_BOARD}")"
na_na="$(summary_field "${na_out}" 'n/a')"
{ [ -n "${in_na}" ] && [ -n "${na_na}" ]; } ||
    fail "no n/a tally to read: ${na_out}"
[ "${na_na}" -gt "${in_na}" ] ||
    fail "opting out of codex must raise the n/a tally (${in_na} -> ${na_na}): ${na_out}"

echo "==> a gh auth timeout reads as unknown in the credentials group too"
# The group shares the section's one bounded probe, so it inherits the probe's
# distinctions or silently loses them: on a deadline it must not tell an
# authenticated reader to run `gh auth login`.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    make_codex_stub in
    make_stub hangs
    out="$(PATH="${TMP}/bin:${PATH}" NO_COLOR=1 NETWORK_TIMEOUT=1 "${WITH_CODEX}" setup 2>&1)"
    case "$out" in
    *"[ ] GitHub CLI (gh)"*) fail "a timeout must not read as a missing gh login: ${out}" ;;
    *"[?] GitHub CLI (gh)"*"timed out"*) ;;
    *) fail "expected an unknown gh credential line, got: ${out}" ;;
    esac
else
    echo "    (skipped: no timeout binary — the probe is unbounded here)"
fi

echo "==> status:creds renders the credentials group on its own"
# The gap this section exists to close: the group used to render only inside
# status:setup, which the session-start hook does not run — so a missing login
# surfaced only on the explicit audit a distracted session skips.
make_codex_stub in
out="$(run_creds_section project)"
case "$out" in
*"GitHub CLI (gh)"*) ;;
*) fail "expected a gh credential line from status:creds, got: ${out}" ;;
esac
case "$out" in
*"[x] Codex CLI"*) ;;
*) fail "expected a Codex credential line from status:creds, got: ${out}" ;;
esac

echo "==> status:creds spends exactly ONE network call, and only for scopes"
# The session-start budget rests on this count. `gh auth status` asks GitHub;
# `gh auth token` reads local config and the environment. The section was
# network-free until issue #827 — scopes are a server-side property of the
# token that no local file records, so the check it asks for cannot be had
# without exactly one round trip. One, not two: a stub that answers `auth
# status` happily would hide a second from every output assertion.
STUB_CALLS="${TMP}/creds-calls.txt"
export STUB_CALLS
: >"${STUB_CALLS}"
make_codex_stub in
out="$(run_creds_section project)"
grep -q 'auth token' "${STUB_CALLS}" ||
    fail "status:creds made no local credential read at all: $(tr '\n' ' ' <"${STUB_CALLS}")"
calls="$(grep -c 'auth status' "${STUB_CALLS}" || true)"
[ "${calls}" = 1 ] ||
    fail "status:creds made ${calls} 'gh auth status' calls, expected exactly 1: $(tr '\n' ' ' <"${STUB_CALLS}")"
unset STUB_CALLS

echo "==> STATUS_NO_NETWORK=1 returns status:creds to a local-only read"
# The opt-out for an offline or latency-sensitive shell. The credential lines
# must still render — only the scope probe is given up.
STUB_CALLS="${TMP}/creds-calls-offline.txt"
export STUB_CALLS
: >"${STUB_CALLS}"
make_codex_stub in
make_stub none
offline_out="$(PATH="${TMP}/bin:${PATH}" NO_COLOR=1 STATUS_NO_NETWORK=1 \
    "${CREDS_BOARD}" creds 2>&1)"
if grep -q 'auth status' "${STUB_CALLS}"; then
    fail "STATUS_NO_NETWORK=1 still probed the network: $(tr '\n' ' ' <"${STUB_CALLS}")"
fi
case "$offline_out" in
*"gh token scopes"*) fail "a scope verdict without a probe to back it: ${offline_out}" ;;
esac
case "$offline_out" in
*"GitHub CLI (gh)"*) ;;
*) fail "the credential lines must still render offline: ${offline_out}" ;;
esac
unset STUB_CALLS

echo "==> status:creds warns when the token is missing a required scope"
# The whole point of #827: an under-scoped login is caught at session start
# rather than days later, when a board write fails mid-shepherd.
make_codex_stub in
scope_out="$(run_creds_section none "${CREDS_BOARD}")"
case "$scope_out" in
*"gh token scopes"*"missing"*"project"*) ;;
*) fail "expected a missing-scope warning from status:creds, got: ${scope_out}" ;;
esac
case "$scope_out" in
*"task setup:gh-scopes"*) ;;
*) fail "the warning must name the runnable remedy, got: ${scope_out}" ;;
esac

echo "==> a fully-scoped token produces NO scope line"
# Silent on success, deliberately: the ✓ credential line above already proves
# the check ran, and a second green line every session in every repo is noise.
make_codex_stub in
scope_out="$(run_creds_section fully-scoped "${CREDS_BOARD}")"
case "$scope_out" in
*"gh token scopes"*) fail "a complete token must not produce a scope line: ${scope_out}" ;;
esac

echo "==> 'read:project' alone satisfies the session-start scope check"
# It does not satisfy the board-WRITE check in the GitHub section, and must
# not: these are different questions about the same token. This one asks
# whether the credential was minted with Projects in mind at all.
make_codex_stub in
scope_out="$(run_creds_section creds-read-project "${CREDS_BOARD}")"
case "$scope_out" in
*"gh token scopes"*) fail "read:project must satisfy the session-start check: ${scope_out}" ;;
esac

echo "==> a failed scope probe is not reported as a missing scope"
# Issues #774 and #478: a probe that could not answer is unknown, never a
# verdict. Sending a correctly-scoped operator to re-mint a working credential
# is the error this guards.
make_codex_stub in
scope_out="$(run_creds_section scope-probe-fails "${CREDS_BOARD}")"
case "$scope_out" in
*"missing"*"project"*) fail "a failed probe must not accuse the token: ${scope_out}" ;;
esac
case "$scope_out" in
*"credential stored"*) ;;
*) fail "the credential line must survive a failed scope probe: ${scope_out}" ;;
esac

echo "==> a repo with no board tooling is never asked for Projects scopes"
# `project_management: none` is the DEFAULT generated profile, and such a repo
# has no board to write to. Demanding Projects access there would warn every
# session, in the majority profile, about a grant the repo never uses — and
# train the reader to ignore the line in the repos where it matters. Same
# marker, and the same accepted cost, as the board-writes check in status:gh.
make_codex_stub in
scope_out="$(run_creds_section none)"
case "$scope_out" in
*"gh token scopes"*) fail "a boardless repo must not demand Projects scopes: ${scope_out}" ;;
esac

echo "==> a boardless repo IS still warned about repo/workflow"
# The gate is on the Projects requirement alone — the unconditional part of the
# list must keep working, or the case above would pass for the wrong reason.
make_codex_stub in
scope_out="$(run_creds_section no-workflow)"
case "$scope_out" in
*"gh token scopes"*"missing workflow"*) ;;
*) fail "expected an unconditional-scope warning in a boardless repo: ${scope_out}" ;;
esac

echo "==> an org repo is asked for admin:org, a personal one is not"
# The org-only setup tasks (issue types, issue fields) state they need
# admin:org, and the template renders them only when the repo belongs to an
# org. Same marker rule as the Projects scopes: a personal-account repo renders
# neither script and must never be warned about a grant it cannot use.
make_codex_stub in
scope_out="$(run_creds_section fully-scoped "${ORG_REPO}")"
case "$scope_out" in
*"gh token scopes"*"missing admin:org"*) ;;
*) fail "expected an admin:org warning in an org repo, got: ${scope_out}" ;;
esac
make_codex_stub in
scope_out="$(run_creds_section fully-scoped "${CREDS_BOARD}")"
case "$scope_out" in
*"admin:org"*) fail "a personal-account repo must not demand admin:org: ${scope_out}" ;;
esac

echo "==> GH_EXTRA_SCOPES adds to the profile's list rather than replacing it"
# The documented extension point. Additive is the whole contract: a consumer
# that names only its own requirement must still be held to this repo's, and to
# any a later template update introduces.
make_codex_stub in
scope_out="$(GH_EXTRA_SCOPES=delete_repo run_creds_section fully-scoped "${CREDS_BOARD}")"
case "$scope_out" in
*"gh token scopes"*"missing delete_repo"*) ;;
*) fail "GH_EXTRA_SCOPES was not required, got: ${scope_out}" ;;
esac
make_codex_stub in
scope_out="$(GH_EXTRA_SCOPES=delete_repo run_creds_section none "${CREDS_BOARD}")"
case "$scope_out" in
*"project"*) ;;
*) fail "GH_EXTRA_SCOPES replaced the built-in requirements: ${scope_out}" ;;
esac

echo "==> status:creds never prints the token it reads"
# `gh auth token` writes the credential to stdout — the value is the output. The
# probe reads its exit code only, so the stub's placeholder must not reach the
# board (nor, by the same redirect, a log or the session-start payload).
case "$out" in
*STUB-TOKEN-MUST-NEVER-BE-PRINTED*) fail "the credential value reached the board: ${out}" ;;
esac

echo "==> status:creds does not claim an authentication it never checked"
# It reports that a credential EXISTS. Whether GitHub still accepts it is
# status:gh's answer, and wording this line as "authenticated" would assert
# something no probe here established.
case "$out" in
*"authenticated to"*) fail "a local-only read must not claim authentication: ${out}" ;;
*"not validated"*) ;;
*) fail "expected the stored-credential wording, got: ${out}" ;;
esac

echo "==> status:creds reports a logged-out gh with the login remedy"
make_codex_stub in
out="$(run_creds_section unauthenticated)"
case "$out" in
*"[ ] GitHub CLI (gh) - gh auth login"*) ;;
*) fail "expected a missing-login line from status:creds, got: ${out}" ;;
esac

echo "==> a local token read that fails for another reason reads unknown"
# Non-zero is not the same as logged out, exactly as for the Codex probe: a
# locked keychain exits non-zero too, and `gh auth login` cannot repair it — the
# reader would be sent to fix the wrong thing. Only gh's documented
# no-credential wording earns that remedy.
make_codex_stub in
out="$(run_creds_section broken-token-store)"
case "$out" in
*"[ ] GitHub CLI (gh)"*) fail "a broken credential store must not read as logged out: ${out}" ;;
*"gh auth login"*) fail "a broken credential store must not prescribe re-authentication: ${out}" ;;
*"[?] GitHub CLI (gh)"*"credential probe failed"*) ;;
*) fail "expected an unknown gh credential line, got: ${out}" ;;
esac

echo "==> a local token read that outlives its deadline reads unknown too"
# The probe is bounded, which makes a wedged credential helper look exactly like
# a missing login unless the deadline is classified apart from it.
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
    make_codex_stub in
    out="$(run_creds_section hangs)"
    case "$out" in
    *"[ ] GitHub CLI (gh)"*) fail "a timeout must not read as a missing login: ${out}" ;;
    *"[?] GitHub CLI (gh)"*"timed out"*) ;;
    *) fail "expected a timeout notice from status:creds, got: ${out}" ;;
    esac
else
    echo "    (skipped: no timeout binary — the probe is unbounded here)"
fi

echo "==> status:creds reports a logged-out codex too"
make_codex_stub out
out="$(run_creds_section project)"
case "$out" in
*"[x] Codex CLI"*) fail "a logged-out codex must not read as ok: ${out}" ;;
*"[ ] Codex CLI - codex login"*) ;;
*) fail "expected a logged-out codex line from status:creds, got: ${out}" ;;
esac

echo "==> a logged-out Claude Code CLI is reported, and names its remedy"
# The third login #733 requires at session start. The field is the verdict, not
# the exit code: a logged-out CLI reports it successfully.
make_codex_stub in
make_claude_stub out
out="$(run_creds_section project)"
case "$out" in
*"[x] Claude Code CLI"*) fail "a logged-out claude must not read as ok: ${out}" ;;
*"[ ] Claude Code CLI - claude auth login"*) ;;
*) fail "expected a logged-out claude line, got: ${out}" ;;
esac

echo "==> a claude too old for 'auth status' reads unknown, not logged out"
# No field at all is not the same as loggedIn:false, and `claude auth login`
# cannot repair a CLI that has no such command.
make_claude_stub ancient
out="$(run_creds_section project)"
case "$out" in
*"[ ] Claude Code CLI"*) fail "an unreadable report must not read as a logout: ${out}" ;;
*"claude auth login"*) fail "an unreadable report must not prescribe re-authentication: ${out}" ;;
*"[?] Claude Code CLI"*) ;;
*) fail "expected an unknown claude line, got: ${out}" ;;
esac

echo "==> claude missing from PATH reads n/a, not missing"
# Unlike gh and Codex there is no marker on disk for "this repo expects Claude
# Code" — the template ships .claude/ everywhere — so an absent CLI cannot be
# told apart from an author who drives this repo with a different agent, and a
# red line prescribing an install would be noise they cannot act on.
make_stub project
make_codex_stub in
make_claude_stub in
make_isolated_bin claude
out="$(PATH="${TMP}/bin-iso" NO_COLOR=1 "${WITH_CODEX}" creds 2>&1)"
case "$out" in
*"[ ] Claude Code CLI"*) fail "an absent claude must not read as a missing login: ${out}" ;;
*"[-] Claude Code CLI"*) ;;
*) fail "expected an n/a claude line, got: ${out}" ;;
esac

echo "==> status:creds omits the setup audit it was carved out of"
# It is a section, not a shortcut into the network-heavy audit: a status:creds
# that dragged the checklist bar or the GitHub configuration checks along would
# put exactly the cost back into session start that this split removed.
case "$out" in
*"Setup Completeness"*) fail "status:creds rendered the setup audit: ${out}" ;;
*"Checklist"*) fail "status:creds rendered the checklist progress: ${out}" ;;
esac

echo "==> gh missing from PATH still names an install remedy in status:creds"
make_stub project
make_codex_stub in
make_isolated_bin gh
out="$(PATH="${TMP}/bin-iso" NO_COLOR=1 "${WITH_CODEX}" creds 2>&1)"
case "$out" in
*"GitHub CLI (gh) - gh auth login"*) fail "an absent gh must not be told to log in: ${out}" ;;
*"[ ] GitHub CLI (gh) - brew install gh"*) ;;
*) fail "expected an install remedy for a missing gh, got: ${out}" ;;
esac

# ── run_timeout actually bounds a probe (harmon-init#865) ───────────────────
#
# A deadline is NOT a bound here. status.sh reads every probe through `$(...)`,
# and a command substitution returns when the write end of its pipe closes, not
# when `timeout` exits — so a probe that blocks on stdin, or that survives the
# SIGTERM the deadline sends, hangs the board FOREVER while `timeout` has long
# since reported 124. That is what `task status` did in a devcontainer terminal:
# `claude auth status --json` waits on a terminal stdin, and nothing downstream
# was left to fire.
#
# Both cases are driven from a stdin that is open and silent, the way a terminal
# with nobody typing at it is. The outer deadline is the test's own safety net:
# a regression must FAIL here, not wedge CI.

# make_claude_stub_wedged MODE — a `claude` that reproduces one half of the hang.
#   stdin — reads stdin to EOF before answering. Answers only if it was given
#           an empty stdin of its own; otherwise it blocks on the caller's.
#   term  — ignores SIGTERM and never exits, so only a hard kill closes the
#           pipe the capture is waiting on.
make_claude_stub_wedged() {
    mkdir -p "${TMP}/bin"
    {
        echo '#!/usr/bin/env bash'
        echo "trap '' TERM"
        case "$1" in
        stdin) echo 'cat >/dev/null' ;;
        term) echo 'while :; do sleep 1; done' ;;
        *) fail "unknown wedged claude stub mode: $1" ;;
        esac
        echo 'echo "{ \"loggedIn\": true }"'
    } >"${TMP}/bin/claude"
    chmod +x "${TMP}/bin/claude"
}

# run_creds_wedged — the credentials section with stdin bound to a pipe that
# stays open and never delivers a byte. Read-write is how the fifo is opened
# without blocking on a writer that will never come.
run_creds_wedged() {
    local fifo="${TMP}/wedge.fifo" rc=0
    rm -f "${fifo}"
    mkfifo "${fifo}"
    exec 9<>"${fifo}"
    # `-k` on the safety net for the same reason status.sh needs one: the stub
    # under test ignores SIGTERM, and a net that can only ask nicely is not a
    # net. Harmless where the shape already terminates — status.sh dies on the
    # TERM and the stub holds only status.sh's own capture pipe, not this one.
    # shellcheck disable=SC2086 # deliberate: empty or the two words `-k 5`
    "${TIMEOUT_FOR_TESTS}" ${TEST_KILL_AFTER} 60 env PATH="${TMP}/bin:${PATH}" NO_COLOR=1 \
        "${WITH_CODEX}" creds <&9 2>&1 || rc=$?
    exec 9>&-
    rm -f "${fifo}"
    return "${rc}"
}

TIMEOUT_FOR_TESTS="$(command -v timeout || command -v gtimeout || true)"
# Either empty or the two words `-k 5`; expanded unquoted at the call site
# because a quoted "" would be passed as a zero-length duration argument.
TEST_KILL_AFTER=""
if [ -n "${TIMEOUT_FOR_TESTS}" ] && "${TIMEOUT_FOR_TESTS}" -k 1 1 true 2>/dev/null; then
    TEST_KILL_AFTER="-k 5"
fi
if [ -n "${TIMEOUT_FOR_TESTS}" ]; then
    echo "==> a probe that blocks on stdin cannot wedge the board"
    # Passes only if run_timeout handed the probe its own empty stdin: the stub
    # answers after EOF, and EOF is what it never gets from the caller's.
    make_stub project
    make_codex_stub in
    make_claude_stub_wedged stdin
    out="$(run_creds_wedged)" ||
        fail "status:creds never returned with a probe blocked on stdin — the deadline does not bound the capture"
    case "$out" in
    *"Claude Code CLI"*"logged in"*) ;;
    *) fail "expected the stdin-blocked probe to be answered from an empty stdin, got: ${out}" ;;
    esac

    echo "==> a probe that ignores SIGTERM cannot wedge the board either"
    # Nothing can make this one answer, so the contract is weaker but the point
    # is the same: report the deadline and move on, rather than hang holding a
    # pipe open. Skipped where `timeout` has no `-k`, which is the one build
    # where status.sh cannot promise this.
    if "${TIMEOUT_FOR_TESTS}" -k 1 1 true 2>/dev/null; then
        make_claude_stub_wedged term
        out="$(run_creds_wedged)" ||
            fail "status:creds never returned with a probe that ignores SIGTERM — the capture outlives its deadline"
        case "$out" in
        *"[?] Claude Code CLI"*"timed out"*) ;;
        *) fail "expected a timeout notice for a probe that ignores SIGTERM, got: ${out}" ;;
        esac
    else
        echo "    (skipped: this timeout has no -k, so the hard kill is unavailable)"
    fi
    make_claude_stub in
else
    echo "    (skipped: no timeout binary — the probes are unbounded here)"
fi

echo "==> every gum call keeps its stdout off the terminal"
# gum asks the TERMINAL for its background colour (OSC 11) whenever its own
# stdout is one, and waits 5s when nothing answers — per invocation, and a board
# renders a dozen. That is the other half of harmon-init#865, and it is invisible
# in every test above because they all run under NO_COLOR with no terminal at
# all. gum_style is the single place that keeps stdout off the terminal; a call
# site that bypasses it reintroduces the stall on exactly the terminals that
# cannot answer, which are the ones nobody develops on. Command substitution
# also preserves gum's failure status so this optional renderer can fall back.
grep -qF 'styled="$(CLICOLOR_FORCE=1 gum style "$@")"' "${output_lib}" ||
    fail "gum_style no longer captures gum's stdout with CLICOLOR_FORCE — the terminal probe, colour, and fallback depend on it"
grep -q 'gum_style ' "${status}" ||
    fail "nothing calls gum_style — the check below would pass vacuously"
stray="$({
    grep -nE '(^|[^_[:alnum:]])gum[[:space:]]+style' "${status}"
    grep -nE '(^|[^_[:alnum:]])gum[[:space:]]+style' "${output_lib}"
} |
    grep -vF 'CLICOLOR_FORCE=1 gum style' |
    grep -vE '^[0-9]+:[[:space:]]*#' || true)"
[ -z "${stray}" ] ||
    fail "gum is invoked outside gum_style, so its stdout is a terminal and it will stall there:
${stray}"

# The half of gum_style the grep above cannot see: that piping stdout does not
# cost the colour. gum drops ANSI for a stdout it does not consider a terminal,
# and CLICOLOR_FORCE is the whole of what puts it back — so assert the mechanism
# rather than trusting it. Run against the same shape gum_style uses, which needs
# no terminal and therefore works in CI.
#
# What this canNOT see is the colour DEPTH: with no terminal on stdout or stderr
# gum reads 16 colours here, where an interactive board keeps the full 256. That
# distinction needs a pty, and a pty harness portable to macOS bash 3.2 would
# cost either divergent `script` invocations or a new dependency in a file that
# ships to generated repos. Total colour loss is the regression worth catching;
# the depth was verified by hand against a terminal that answers.
#
# Both probes run with the caller's colour environment CLEARED, so that
# CLICOLOR_FORCE is the only difference between them. Either variable leaking in
# breaks the assertion in a different direction: an inherited NO_COLOR (which gum
# honours over CLICOLOR_FORCE) renders the forced probe plain, and an inherited
# CLICOLOR_FORCE colours the plain one. Both would fail this gate purely on the
# environment it was run in — `NO_COLOR=1 task verify` is an ordinary thing to
# type — while status.sh stays correct in both, since NO_COLOR turns gum off
# there entirely.
if command -v gum >/dev/null 2>&1; then
    gum_plain="$(env -u NO_COLOR -u CLICOLOR_FORCE gum style --bold --foreground 212 -- probe | cat)"
    gum_forced="$(env -u NO_COLOR CLICOLOR_FORCE=1 gum style --bold --foreground 212 -- probe | cat)"
    case "$gum_plain" in
    *$'\033['*) fail "gum coloured a piped stdout unprompted — CLICOLOR_FORCE is asserting nothing below" ;;
    esac
    case "$gum_forced" in
    *$'\033['*) ;;
    *) fail "CLICOLOR_FORCE did not restore gum's colour through a pipe, so gum_style renders the board plain" ;;
    esac
else
    echo "    (skipped: gum not installed — the board renders its plain fallback)"
fi

echo "==> the session-start hook allows more time than status:creds can spend"
# The same coupling as the status:gh assertion above, and the same total failure
# mode — but budgeted from THIS section's own probes rather than inherited from
# its neighbour's. Both bounds are read out of the files, so adding a probe to
# the credentials group without widening the hook fails here.
# Deadlines and probe COUNT, because each probe carries the kill grace too.
# BOTH functions: the scope probe (#827) lives in render_gh_scope_check, and a
# scan that stopped at render_local_credentials would model the section as
# cheaper than it is — which is exactly the drift this assertion exists to
# catch.
creds_probes="$(awk '
    /^render_local_credentials\(\) \{/ { inf = 1 }
    /^render_gh_scope_check\(\) \{/ { inf = 1 }
    inf && /^\}/ { inf = 0 }
    inf {
        line = $0
        while (match(line, /run_timeout [0-9]+ /)) {
            total += substr(line, RSTART + 12, RLENGTH - 13) + 0
            n += 1
            line = substr(line, RSTART + RLENGTH)
        }
    }
    END { print total + 0, n + 0 }
' "${status}")"
creds_deadlines="${creds_probes% *}"
creds_count="${creds_probes#* }"
creds_worst="$((creds_deadlines + creds_count * kill_grace))"
[ "$creds_count" -gt 0 ] ||
    fail "found no bounded probes in the credentials section — the budget below would assert nothing"
checked_hooks=0
for h in ${STATUS_HOOKS}; do
    [ -f "$h" ] || continue
    checked_hooks=$((checked_hooks + 1))
    creds_budget="$(hook_deadline "$h" creds)"
    [ -n "$creds_budget" ] || fail "could not read the status:creds timeout out of ${h}"
    [ "$creds_budget" -gt "$creds_worst" ] ||
        fail "${h} allows ${creds_budget}s but the credentials section can spend ${creds_worst}s on probes alone (${creds_deadlines}s of deadlines + ${creds_count} probes x ${kill_grace}s kill grace) — the whole group is lost first"
done
[ "$checked_hooks" -gt 0 ] &&
    echo "    (checked ${checked_hooks} hook(s))" ||
    echo "    (skipped: no session-start hook in this profile)"

echo "==> the session-start hook fits inside its managed SessionStart deadline"
# The deadline ABOVE the per-section ones: Claude Code applies the `timeout` on
# the SessionStart entries to the whole hook, and overrunning it is worse than
# overrunning a section bound — the hook is killed before `jq` emits anything,
# so the entire payload is lost rather than one section of it. Adding a section
# is exactly when that ceiling gets forgotten, so derive both sides from the
# files: the sections run in parallel, which makes the hook's wall clock the
# LONGEST section deadline rather than their sum.
settings=".devcontainer/config/claude-settings.json"
if [ -f "$hook" ] && [ -f "$settings" ]; then
    managed="$(jq -r '
        [.hooks.SessionStart[]?.hooks[]?
         | select(.command | test("session-start-context"))
         | .timeout // empty]
        | min // empty
    ' "$settings")"
    [ -n "$managed" ] ||
        fail "could not read the SessionStart hook timeout out of ${settings}"

    # Every bounded section launch in the hook, and whether it was backgrounded.
    section_bounds="$(sed -n -E 's/^[[:space:]]*timeout ([0-9]+) task status:[a-z]+ .*/\1/p' "$hook")"
    backgrounded="$(sed -n -E 's/^[[:space:]]*timeout [0-9]+ task status:[a-z]+ .*&$/&/p' "$hook" | wc -l | tr -d ' ')"
    n_sections="$(printf '%s\n' "$section_bounds" | grep -c '[0-9]' || true)"
    [ "${n_sections:-0}" -ge 2 ] ||
        fail "found ${n_sections:-0} bounded status sections in ${hook} — the ceiling below would assert nothing"

    longest=0
    total=0
    for b in $section_bounds; do
        total=$((total + b))
        [ "$b" -gt "$longest" ] && longest="$b"
    done

    if [ "$backgrounded" -eq "$n_sections" ]; then
        wall="$longest"
        shape="in parallel"
    else
        wall="$total"
        shape="sequentially"
    fi
    [ "$managed" -gt "$wall" ] ||
        fail "the hook runs its ${n_sections} sections ${shape} (${wall}s worst case) but claude-settings.json kills it at ${managed}s — the whole payload is discarded, not one section"
else
    echo "    (skipped: no devcontainer hook/settings in this profile)"
fi

echo "status.sh tests passed"
