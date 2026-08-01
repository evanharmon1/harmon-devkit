#!/usr/bin/env bash
# test-status.sh — unit-test status.sh's "Project board writes" check: the token
# scope the claim lifecycle needs is reported from the section that session-start
# orientation actually runs (`task status:gh`), in every scope state. Run via
# `task test:status`.
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

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# Three fixture roots, each holding a copy of the script under test:
#   with-board  — has the board tooling, so the check applies
#   no-board    — has none of it, so the check must not render at all
#   skills-only — the DEFAULT generated profile: `project_management: none` with
#                 `use_skills_sync: true`, so the vendored universal skill set
#                 (track-work included) is present but there is no board
for fixture in with-board no-board skills-only; do
    mkdir -p "${TMP}/${fixture}/scripts"
    cp "${status}" "${TMP}/${fixture}/scripts/status.sh"
done
# The markers status.sh feature-detects on. Contents are never read.
: >"${TMP}/with-board/scripts/setup-github-project.sh"
mkdir -p "${TMP}/skills-only/.claude/skills/track-work/assets"
: >"${TMP}/skills-only/.claude/skills/track-work/assets/set-issue-status.sh"

# A board repo whose remote is a GitHub Enterprise host, and which exports no
# GH_HOST — the case where forcing github.com disowns a valid login.
mkdir -p "${TMP}/enterprise/scripts"
cp "${status}" "${TMP}/enterprise/scripts/status.sh"
: >"${TMP}/enterprise/scripts/setup-github-project.sh"
git -C "${TMP}/enterprise" init -q
git -C "${TMP}/enterprise" remote add origin git@ghe.example.com:owner/repo.git

WITH_BOARD="${TMP}/with-board/scripts/status.sh"
NO_BOARD="${TMP}/no-board/scripts/status.sh"
SKILLS_ONLY="${TMP}/skills-only/scripts/status.sh"
ENTERPRISE="${TMP}/enterprise/scripts/status.sh"

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
        *) fail "unknown stub scenario: ${scenario}" ;;
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
*"read-only"*"gh auth refresh -s project"*) ;;
*) fail "expected a read-only warning naming the remedy, got: ${out}" ;;
esac

echo "==> a token with neither scope warns and names the remedy"
out="$(run_gh_section none)"
case "$out" in
*"lacks 'project'"*"gh auth refresh -s project"*) ;;
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
*"gh auth refresh -s project"*) fail "gh auth refresh cannot change an env token: ${out}" ;;
*"reissue GH_TOKEN"*) ;;
*) fail "expected an env-token remedy, got: ${out}" ;;
esac

echo "==> an Enterprise env token gets the same treatment as GH_TOKEN"
# The override problem is a property of environment tokens, not of github.com.
out="$(run_gh_section enterprise-env-token)"
case "$out" in
*"gh auth refresh -s project"*) fail "gh auth refresh cannot change an env token: ${out}" ;;
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
    *GH_REMEDY=*) continue ;;            # the derivation itself
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
# budget. Skipped where the hook is not generated (no devcontainer).
hook=".devcontainer/config/claude-hooks/session-start-context.sh"
if [ -f "$hook" ]; then
    budget="$(sed -n -E 's/.*timeout ([0-9]+) task status:gh.*/\1/p' "$hook")"
    probe="$(sed -n -E 's/^NETWORK_TIMEOUT="\$\{NETWORK_TIMEOUT:-([0-9]+)\}"$/\1/p' "${status}")"
    [ -n "$budget" ] || fail "could not read the status:gh timeout out of ${hook}"
    [ -n "$probe" ] || fail "could not read NETWORK_TIMEOUT out of ${status}"
    [ "$budget" -gt "$((probe * 2))" ] ||
        fail "hook allows ${budget}s but the section can spend $((probe * 2))s on probes alone — the board-writes line is lost first"
else
    echo "    (skipped: no devcontainer hook in this profile)"
fi

echo "==> the check never runs the setup section's Projects query"
# The line is fed by the auth probe the section already makes. If it ever grows a
# GraphQL call, the network cost lands in every session start — the reason the
# setup section is excluded from the default dashboard in the first place.
out="$(run_gh_section project)"
case "$out" in
*"stub: unexpected gh call"*) fail "the gh section made an unstubbed call: ${out}" ;;
esac

echo "status.sh tests passed"
