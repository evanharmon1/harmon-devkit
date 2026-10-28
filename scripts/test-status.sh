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
rest_lib="./scripts/lib/gh-rest.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# status.sh branches its remedy text on FOREMAN_DEVCONTAINER (unset = dev
# posture, "bot", "agent"), and the bot and agent profiles export it — plus a
# preset GH_TOKEN / GITHUB_TOKEN — into every process; gh and the REST helper
# honour more GH_* variables (GH_HOST, GH_REPO, GH_REST_HOST), and status.sh
# its own STATUS_* switches. A case must not inherit whichever environment the
# caller happens to be in (#1395), so every variable in those families is
# cleared here, by pattern rather than by a list that misses the next one; the
# cases that exercise a branch set its variables themselves, per case.
for _ambient in $(compgen -e); do
    case "$_ambient" in
    FOREMAN_DEVCONTAINER | GH_* | GITHUB_* | STATUS_*) unset "$_ambient" ;;
    esac
done
unset _ambient

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
    cp "${rest_lib}" "${TMP}/${fixture}/scripts/lib/gh-rest.sh"
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
cp "${rest_lib}" "${TMP}/enterprise/scripts/lib/gh-rest.sh"
: >"${TMP}/enterprise/scripts/setup-github-project.sh"
git -C "${TMP}/enterprise" init -q
git -C "${TMP}/enterprise" remote add origin git@ghe.example.com:owner/repo.git

# A board repo whose owner AND name carry hyphens — the shape of this repository
# itself. The resolved OWNER/REPO used to be validated against a class in which
# `.-/` was the RANGE 0x2E-0x2F, so `-` was rejected, gh_rest_repo returned 1,
# and the `if` guarding the open-PR read below simply skipped it: `task
# status:gh` reported no open PRs at all, silently (challenge r3).
mkdir -p "${TMP}/hyphenated/scripts/lib"
cp "${status}" "${TMP}/hyphenated/scripts/status.sh"
cp "${scopes_lib}" "${TMP}/hyphenated/scripts/gh-scopes.sh"
cp "${output_lib}" "${TMP}/hyphenated/scripts/lib/output.sh"
cp "${rest_lib}" "${TMP}/hyphenated/scripts/lib/gh-rest.sh"
: >"${TMP}/hyphenated/scripts/setup-github-project.sh"
git -C "${TMP}/hyphenated" init -q
git -C "${TMP}/hyphenated" remote add origin git@github.com:my-org/harmon-init.git

# A repo that ships a release workflow, so the setup audit renders its
# "Release published" line (the check is gated on that file). It is a git repo
# with a GitHub remote so the whole-block run below resolves a branch and an
# owner/repo the way a real checkout does.
mkdir -p "${TMP}/with-release/scripts/lib" "${TMP}/with-release/.github/workflows"
cp "${status}" "${TMP}/with-release/scripts/status.sh"
cp "${scopes_lib}" "${TMP}/with-release/scripts/gh-scopes.sh"
cp "${output_lib}" "${TMP}/with-release/scripts/lib/output.sh"
cp "${rest_lib}" "${TMP}/with-release/scripts/lib/gh-rest.sh"
: >"${TMP}/with-release/.github/workflows/release.yml"
git -C "${TMP}/with-release" init -q
git -C "${TMP}/with-release" remote add origin git@github.com:owner/public.git

WITH_BOARD="${TMP}/with-board/scripts/status.sh"
WITH_RELEASE="${TMP}/with-release/scripts/status.sh"
NO_BOARD="${TMP}/no-board/scripts/status.sh"
SKILLS_ONLY="${TMP}/skills-only/scripts/status.sh"
ENTERPRISE="${TMP}/enterprise/scripts/status.sh"
HYPHENATED="${TMP}/hyphenated/scripts/status.sh"
WITH_CODEX="${TMP}/with-codex/scripts/status.sh"
CREDS_BOARD="${TMP}/creds-board/scripts/status.sh"
ORG_REPO="${TMP}/org-repo/scripts/status.sh"

fail() {
    # shell-robustness: ok — always exits, so its status is never read
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
        echo 'if [ -n "${STUB_HOST_AUDIT:-}" ]; then printf "%s|%s|%s\n" "${GH_HOST:-}" "${GH_REPO:-}" "$*" >>"$STUB_HOST_AUDIT"; fi'
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
        echo 'if [ "$1" = "api" ]; then'
        echo '    endpoint="${2:-}"'
        echo '    if [ "${3:-}" = "--jq" ] && [ "${4:-}" = ".owner.type" ]; then'
        echo '        [ "${GH_OWNER_TYPE_FAIL:-0}" = 0 ] || exit 1'
        echo '        [ -n "${GH_REPO_JSON:-}" ] || exit 1'
        echo '        printf "%s\n" "$GH_REPO_JSON" | jq -r .owner.type'
        echo '        exit 0'
        echo '    fi'
        cat <<'ROUTING_STUB'
    case "$endpoint" in
    repos/*/actions/organization-variables\?*)
        [ -n "${GH_ROUTING_ORG_JSON:-}" ] || exit 1
        case "${GH_ROUTING_ORG_MODE:-shared}" in
        fail) exit 1 ;;
        incomplete) printf '{"total_count":31,"variables":[]}\n'; exit 0 ;;
        restricted) printf '{"total_count":0,"variables":[]}\n'; exit 0 ;;
        esac
        page="${endpoint##*&page=}"
        per_page="${endpoint##*per_page=}"; per_page="${per_page%%&*}"
        if [ "${GH_ROUTING_ORG_MODE:-}" = fail-page-two ] && [ "$page" -eq 2 ]; then exit 1; fi
        printf '%s\n' "$GH_ROUTING_ORG_JSON" | jq -c --argjson page "$page" --argjson size "$per_page" \
            '{total_count:length,variables:.[(($page-1)*$size):($page*$size)]}'
        exit 0
        ;;
    esac
ROUTING_STUB
        # GH_STUB_FULL_PAGES=1: answer the three completeness-required
        # inventories with a FULL page every time, exactly as GitHub answers a
        # list longer than per_page. Only a bound can end such a walk, so this
        # is what lets a case drive gh_rest_paginate_* into its
        # GH_REST_MAX_PAGES ceiling (exit 4) instead of a natural short page.
        cat <<'STUB'
    if [ "${GH_STUB_FULL_PAGES:-0}" = 1 ]; then
        page_items="${endpoint##*per_page=}"
        page_items="${page_items%%&*}"
        case "$endpoint" in
        */labels\?*)
            jq -cn --argjson n "$page_items" '[range(0;$n) | {name:"l\(.)"}]'
            exit 0
            ;;
        orgs/*/issue-types\?*)
            jq -cn --argjson n "$page_items" '[range(0;$n) | {name:"t\(.)"}]'
            exit 0
            ;;
        orgs/*/issue-fields\?*)
            jq -cn --argjson n "$page_items" '{issue_fields:[range(0;$n) | {name:"f\(.)",data_type:"text"}]}'
            exit 0
            ;;
        esac
    fi
STUB
        echo '    case "$endpoint" in'
        echo '    graphql | search/* | repositories/*) echo "HTTP 403: REST-only proxy rejection" >&2; exit 1 ;;'
        echo '    *"&page=2"*) echo "[]"; exit 0 ;;'
        echo '    repos/*/*\?* | repos/*/*)'
        echo '        case "$endpoint" in'
        echo '        */pulls\?* | */labels\?* | */pulls/comments\?* | */rulesets) echo "[]" ;;'
        echo '        */vulnerability-alerts) echo "[]" ;;'
        # The latest-release read. GH_STUB_RELEASES picks the answer: `none`
        # (default) is a successful read of a repository with no release,
        # `present` one with v4.47.1, `fail` the proxy refusing the read,
        # `garbage` a 200 that is not a release list at all, and `malformed` a JSON
        # array whose elements are not releases (a proxy's error objects),
        # `empty-tag` a release with an empty tag_name, `two-documents` an error
        # document followed by an empty array, and `trailing-document` an empty
        # array followed by an error document (valid up to the first document).
        echo '        */releases\?*)'
        echo '            case "${GH_STUB_RELEASES:-none}" in'
        echo '            present) echo "[{\"tag_name\":\"v4.47.1\",\"draft\":false}]" ;;'
        echo '            fail) echo "HTTP 403: REST-only proxy rejection" >&2; exit 1 ;;'
        echo '            garbage) echo "<html>proxy error</html>" ;;'
        echo '            malformed) echo "[{\"message\":\"rate limited\"}]" ;;'
        echo '            empty-tag) echo "[{\"tag_name\":\"\"}]" ;;'
        echo '            two-documents) echo "[{\"message\":\"rate limited\"}]"; echo "[]" ;;'
        echo '            trailing-document) echo "[]"; echo "[{\"message\":\"rate limited\"}]" ;;'
        echo '            *) echo "[]" ;;'
        echo '            esac'
        echo '            ;;'
        echo '        */private-vulnerability-reporting) echo "{}" ;;'
        echo '        *) [ -n "${GH_REPO_JSON:-}" ] || exit 1; printf "%s\n" "$GH_REPO_JSON" ;;'
        echo '        esac'
        echo '        exit 0'
        echo '        ;;'
        echo '    orgs/*/issue-types\?*) echo "[]"; exit 0 ;;'
        # The preview documents its page in two shapes, and a read can also
        # simply fail. `empty` (the default) keeps every existing case on the
        # wrapped-and-empty answer they were written against. `wrapped` and
        # `bare` serve the org snapshot in GH_STUB_ISSUE_FIELDS_JSON (a bare
        # JSON array) in that shape, so a case chooses the fields and the shape
        # independently.
        echo '    orgs/*/issue-fields\?*)'
        echo '        case "${GH_STUB_ISSUE_FIELDS:-empty}" in'
        echo '        wrapped) printf "{\"issue_fields\":%s}\n" "${GH_STUB_ISSUE_FIELDS_JSON:-[]}" ;;'
        echo '        bare) printf "%s\n" "${GH_STUB_ISSUE_FIELDS_JSON:-[]}" ;;'
        echo '        fail) exit 1 ;;'
        echo '        *) echo "{\"issue_fields\":[]}" ;;'
        echo '        esac'
        echo '        exit 0'
        echo '        ;;'
        echo '    orgs/*/installations | user/installations) echo "{\"installations\":[]}"; exit 0 ;;'
        echo '    esac'
        echo '    echo "stub: unexpected REST endpoint: $endpoint" >&2'
        echo '    exit 1'
        echo 'fi'
        echo 'if [ "$1" = "variable" ] && [ "$2" = "list" ] && [ "$3" = "--repo" ]; then'
        echo '    [ -n "${GH_ROUTING_REPO_JSON:-}" ] || exit 1'
        echo '    routing_jq=""'
        echo '    while [ "$#" -gt 0 ]; do'
        echo '        case "$1" in'
        echo '        --jq) [ "$#" -ge 2 ] || exit 2; routing_jq="$2"; shift 2 ;;'
        echo '        *) shift ;;'
        echo '        esac'
        echo '    done'
        echo '    if [ -n "$routing_jq" ]; then'
        echo '        printf "%s\n" "$GH_ROUTING_REPO_JSON" | jq "$routing_jq"'
        echo '    else'
        echo '        printf "%s\n" "$GH_ROUTING_REPO_JSON"'
        echo '    fi'
        echo '    exit 0'
        echo 'fi'
        echo 'if [ "$1" = "variable" ] && [ "$2" = "list" ] && [ -n "${GH_VARIABLES_JSON:-}" ]; then'
        echo '    printf "%s\n" "$GH_VARIABLES_JSON"'
        echo '    exit 0'
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
ISOLATED_TOOLS="env bash awk basename cat cut dirname find git grep head jq mktemp rm sed sort tr uniq wc timeout gtimeout"

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
    local stub_repo="${GH_REPO:-}"
    if [ -z "${stub_repo}" ] && [ -n "${GH_REPO_JSON:-}" ]; then
        stub_repo="$(jq -r '.full_name // empty' <<<"${GH_REPO_JSON}")"
    fi
    GH_REPO="${stub_repo}" PATH="${TMP}/bin:${PATH}" NO_COLOR=1 "${script}" setup 2>&1
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
    GH_REPO="${GH_REPO:-}" PATH="${TMP}/bin-iso" NO_COLOR=1 "${script}" setup 2>&1
}

# summary_field OUTPUT NAME — the count NAME carries on status.sh's Summary line
# (`2 ok · 3 missing · 0 unknown · 4 n/a`). Empty when there is no such line,
# which is how a case detects that the gh gate stopped the run short.
summary_field() {
    sed -n -E "s#.*Summary:.*[^0-9]([0-9]+) $2.*#\1#p" <<<"$1" | sed -n '1p'
}

echo "==> public setup status requires exact safety overrides for all five classes"
make_codex_stub in
public_repo='{"full_name":"owner/public","visibility":"PUBLIC","private":false,"default_branch":"main","owner":{"type":"Organization"}}'
internal_repo='{"full_name":"owner/internal","visibility":"INTERNAL","private":false,"default_branch":"main","owner":{"type":"Organization"}}'
safe_public="$(jq -cn '["CI_RUNS_ON","BROWSER_RUNS_ON","IMAGE_BUILD_RUNS_ON","ISOLATED_RUNS_ON","MULTICORE_RUNS_ON"] | map({name:.,value:"\"ubuntu-latest\""})')"
STUB_CALLS="${TMP}/public-routing-calls"
export STUB_CALLS
: >"$STUB_CALLS"
out="$(GH_REPO_JSON="$public_repo" GH_ROUTING_REPO_JSON="$safe_public" run_setup_section project)"
baseline_missing="$(summary_field "$out" missing)"
[ -n "$baseline_missing" ] || fail "safe public flow lacks failure tally"
for name in CI_RUNS_ON BROWSER_RUNS_ON IMAGE_BUILD_RUNS_ON ISOLATED_RUNS_ON MULTICORE_RUNS_ON; do
    case "$out" in *"[x] Actions runner routing ($name) - public override is ubuntu-latest"*) ;; *) fail "missing safe public check $name: $out" ;; esac
    for mode in missing different; do
        inventory="$(jq -c --arg name "$name" --arg mode "$mode" 'if $mode == "missing" then map(select(.name != $name)) else map(if .name == $name then .value="\"provider\"" else . end) end' <<<"$safe_public")"
        bad="$(GH_REPO_JSON="$public_repo" GH_ROUTING_REPO_JSON="$inventory" run_setup_section project)"
        case "$bad" in *"[ ] Actions runner routing ($name) - public override must be exact ubuntu-latest JSON"*) ;; *) fail "public $mode $name not a failure: $bad" ;; esac
        bad_missing="$(summary_field "$bad" missing)"
        [ "$bad_missing" -eq "$((baseline_missing + 1))" ] || fail "public $mode $name did not increment the failure tally"
    done
done
if grep -q 'variable get CI_RUNS_ON' "$STUB_CALLS"; then fail "standalone CI_RUNS_ON probe remains"; fi
unset STUB_CALLS
out="$(GH_REPO_JSON="$public_repo" run_setup_section project)"
case "$out" in *'[?] Actions runner routing (CI_RUNS_ON) - public override unreadable'*) ;; *) fail "unreadable inventory was not unknown: $out" ;; esac
out="$(GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON='[]' run_setup_section project)"
case "$out" in *'Actions runner routing ('*) fail "internal repository audited as public: $out" ;; esac

echo "==> routing readout distinguishes repository and organization values"
routing_repo='[{"name":"CI_RUNS_ON","value":"[\"self-hosted\",\"linux\"]"},{"name":"BROWSER_RUNS_ON","value":"\"browser-provider\""}]'
routing_org='[{"name":"CI_RUNS_ON","value":"\"org-provider\""},{"name":"IMAGE_BUILD_RUNS_ON","value":"[\"image-provider\"]"},{"name":"ISOLATED_RUNS_ON","value":"\"ubuntu-latest\""}]'
out="$(GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON="$routing_repo" GH_ROUTING_ORG_JSON="$routing_org" run_setup_section project)"
for expected in 'CI_RUNS_ON (repo) - ["self-hosted","linux"]' 'CI_RUNS_ON (org) - "org-provider"' \
    'BROWSER_RUNS_ON (repo) - "browser-provider"' 'BROWSER_RUNS_ON (org) - unset' \
    'IMAGE_BUILD_RUNS_ON (repo) - unset' 'IMAGE_BUILD_RUNS_ON (org) - ["image-provider"]' \
    'ISOLATED_RUNS_ON (repo) - unset' 'ISOLATED_RUNS_ON (org) - "ubuntu-latest"'; do
    case "$out" in
    *"$expected"*) ;;
    *) fail "missing routing value $expected: $out" ;;
    esac
done
echo "==> multicore routing reports selected and unset values"
for value in '"multicore-provider"' '["self-hosted","linux"]'; do
    multicore_repo="$(jq -cn --arg value "$value" '[{name:"MULTICORE_RUNS_ON",value:$value},{name:"UNRELATED_VARIABLE",value:"unrelated"}]')"
    out="$(GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON="$multicore_repo" GH_ROUTING_ORG_JSON='[]' run_setup_section project)"
    case "$out" in *"MULTICORE_RUNS_ON (repo) - $value"*) ;; *) fail "multicore selected value missing: $out" ;; esac
done
out="$(GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON='[]' GH_ROUTING_ORG_JSON='[]' run_setup_section project)"
for scope in repo org; do
    case "$out" in *"MULTICORE_RUNS_ON ($scope) - unset"*) ;; *) fail "multicore unset fallback missing: $out" ;; esac
done
for unreadable in '' 'not-json' '{}'; do
    out="$(GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON='[]' GH_ROUTING_ORG_JSON="$unreadable" run_setup_section project)"
    for name in CI_RUNS_ON BROWSER_RUNS_ON IMAGE_BUILD_RUNS_ON ISOLATED_RUNS_ON MULTICORE_RUNS_ON; do
        case "$out" in
        *"$name (org) - unknown"*) ;;
        *) fail "unreadable $name org value was not unknown: $out" ;;
        esac
    done
done

echo "==> organization routing excludes variables restricted to other repositories"
out="$(GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON='[]' GH_ROUTING_ORG_JSON="$routing_org" GH_ROUTING_ORG_MODE=restricted run_setup_section project)"
for name in CI_RUNS_ON BROWSER_RUNS_ON IMAGE_BUILD_RUNS_ON ISOLATED_RUNS_ON MULTICORE_RUNS_ON; do
    case "$out" in
    *"$name (org) - unset"*) ;;
    *) fail "restricted $name was not absent for this repository: $out" ;;
    esac
done

echo "==> organization routing follows pages and rejects failed/incomplete inventories"
paged_routing="$(jq -cn '[range(0;30) | {name:"OTHER_\(.)",value:"other"}] + [{name:"ISOLATED_RUNS_ON",value:"\"page-two-provider\""}]')"
for mode in shared fail fail-page-two incomplete; do
    out="$(GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON='[]' GH_ROUTING_ORG_JSON="$paged_routing" GH_ROUTING_ORG_MODE="$mode" run_setup_section project)"
    if [ "$mode" = shared ]; then
        case "$out" in
        *'ISOLATED_RUNS_ON (org) - "page-two-provider"'*) ;;
        *) fail "organization routing missed page two: $out" ;;
        esac
    else
        for name in CI_RUNS_ON BROWSER_RUNS_ON IMAGE_BUILD_RUNS_ON ISOLATED_RUNS_ON MULTICORE_RUNS_ON; do
            case "$out" in
            *"$name (org) - unknown"*) ;;
            *) fail "$mode organization inventory hid incomplete $name: $out" ;;
            esac
        done
    fi
done
out="$(GH_REST_MAX_PAGES=1 GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON='[]' GH_ROUTING_ORG_JSON="$paged_routing" run_setup_section project)"
case "$out" in
*'ISOLATED_RUNS_ON (org) - unknown'*) ;;
*) fail "page ceiling reported a partial organization inventory: $out" ;;
esac

echo "==> organization routing uses the repository's Enterprise host"
STUB_CALLS="${TMP}/routing-ghe-calls.txt"
export STUB_CALLS
: >"$STUB_CALLS"
out="$(GH_REPO=ghe.example.com/owner/internal GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON="$routing_repo" GH_ROUTING_ORG_JSON="$routing_org" run_setup_section project)"
case "$out" in
*'CI_RUNS_ON (org) - "org-provider"'*) ;;
*) fail "Enterprise organization routing was not shown: $out" ;;
esac
if ! grep -F 'api repos/owner/internal/actions/organization-variables?per_page=30&page=1 --hostname ghe.example.com' "$STUB_CALLS" >/dev/null; then
    fail "organization routing did not honor the Enterprise host: $(cat "$STUB_CALLS")"
fi
for request in 'variable list --repo owner/internal --json name,value' 'variable list --json name --repo owner/internal'; do
    grep -F "$request" "$STUB_CALLS" >/dev/null || fail "repository routing did not honor Enterprise host: $request"
done
case "$out" in
*'BROWSER_RUNS_ON (repo) - "browser-provider"'*) ;;
*) fail "Enterprise repository routing was not shown: $out" ;;
esac
if grep -F 'variable list --org' "$STUB_CALLS" >/dev/null; then fail "organization routing used an org-wide listing"; fi
unset STUB_CALLS

echo "==> isolated self-hosted repository and inherited values render violations"
unsafe_isolated='[{"name":"ISOLATED_RUNS_ON","value":"[\"linux\",\"SELF-HOSTED\"]"}]'
out="$(GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON='[]' GH_ROUTING_ORG_JSON="$unsafe_isolated" run_setup_section project)"
for scope in org; do
    case "$out" in
    *"[ ] ISOLATED_RUNS_ON ($scope) - ISOLATED_RUNS_ON invariant violated"*) ;;
    *) fail "unsafe isolated $scope value was not a violation: $out" ;;
    esac
done
case "$out" in
*'organization Actions variables'*) ;;
*) fail "organization isolated violation omitted owner: $out" ;;
esac

out="$(GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON="$unsafe_isolated" GH_ROUTING_ORG_JSON="$unsafe_isolated" run_setup_section project)"
case "$out" in *'[ ] ISOLATED_RUNS_ON (repo) - ISOLATED_RUNS_ON invariant violated'*) ;; *) fail "unsafe repository value not violation" ;; esac
case "$out" in *'warning: unsafe or unsupported organization value shadowed'*) ;; *) fail "shadowed organization value not warning" ;; esac

echo "==> full setup flow pins every GitHub call despite conflicting ambient hosts"
for host in github.com ghe.example.com; do
    ambient=github.com
    [ "$host" != github.com ] || ambient=ghe.example.com
    STUB_HOST_AUDIT="${TMP}/host-property"
    export STUB_HOST_AUDIT
    : >"$STUB_HOST_AUDIT"
    out="$(GH_REPO="$host/owner/internal" GH_HOST="$ambient" GH_REST_HOST="$ambient" GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON='[]' GH_ROUTING_ORG_JSON='[]' run_setup_section project)"
    [ -s "$STUB_HOST_AUDIT" ] || fail "empty host property audit"
    while IFS='|' read -r actual_host actual_repo request; do
        [ "$actual_host" = "$host" ] && [ "$actual_repo" = "owner/internal" ] || fail "ambient host redirected $request"
    done <"$STUB_HOST_AUDIT"
    unset STUB_HOST_AUDIT
done

echo "==> group labels and unsupported isolated shapes are violations in both scopes"
for selector in '{"group":"pool","labels":"SELF-HOSTED"}' '{"group":"pool","labels":["linux","Self-Hosted"]}' '42' 'null' '{}' '{"group":"pool"}' '[["linux"]]'; do
    isolated="$(jq -cn --arg value "$selector" '[{name:"ISOLATED_RUNS_ON",value:$value}]')"
    out="$(GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON="$isolated" GH_ROUTING_ORG_JSON="$isolated" run_setup_section project)"
    for scope in repo; do
        case "$out" in *"[ ] ISOLATED_RUNS_ON ($scope) - ISOLATED_RUNS_ON invariant violated"*) ;; *) fail "unsupported/unsafe $scope selector accepted $selector: $out" ;; esac
    done
    inherited="$(GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON='[]' GH_ROUTING_ORG_JSON="$isolated" run_setup_section project)"
    case "$inherited" in *'[ ] ISOLATED_RUNS_ON (org) - ISOLATED_RUNS_ON invariant violated'*) ;; *) fail "inherited selector was not violation: $inherited" ;; esac
done
isolated='[{"name":"ISOLATED_RUNS_ON","value":"{\"group\":\"pool\",\"labels\":[\"ubuntu-latest\"]}"}]'
out="$(GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON="$isolated" GH_ROUTING_ORG_JSON="$isolated" run_setup_section project)"
case "$out" in *'ISOLATED_RUNS_ON invariant violated'*) fail "safe group selector reported as violation" ;; esac

echo "==> custom-port remote and GH_REPO targets preserve REST refusal and escape"
port_root="${TMP}/port-target"
mkdir -p "$port_root/scripts/lib"
cp "$status" "$port_root/scripts/status.sh"
cp "$scopes_lib" "$port_root/scripts/gh-scopes.sh"
cp "$output_lib" "$port_root/scripts/lib/output.sh"
cp "$rest_lib" "$port_root/scripts/lib/gh-rest.sh"
git -C "$port_root" init -q
git -C "$port_root" remote add origin https://ghe.example.com:8443/owner/internal.git
for source in explicit remote; do
    make_stub project
    STUB_HOST_AUDIT="${TMP}/port-status-audit"
    export STUB_HOST_AUDIT
    : >"$STUB_HOST_AUDIT"
    target=ghe.example.com:8443/owner/internal
    if [ "$source" = remote ]; then target=""; fi
    out="$(GH_HOST= GH_REPO="$target" PATH="${TMP}/bin:$PATH" NO_COLOR=1 "$port_root/scripts/status.sh" setup 2>&1)"
    if grep -q '|api repos/' "$STUB_HOST_AUDIT"; then fail "shared port refusal was bypassed"; fi
    : >"$STUB_HOST_AUDIT"
    out="$(GH_HOST= GH_REPO="$target" GH_REST_HOST= GH_REPO_JSON="$internal_repo" GH_ROUTING_REPO_JSON='[]' GH_ROUTING_ORG_JSON='[]' PATH="${TMP}/bin:$PATH" NO_COLOR=1 "$port_root/scripts/status.sh" setup 2>&1)"
    [ -s "$STUB_HOST_AUDIT" ] || fail "empty port host audit"
    while IFS='|' read -r host nwo request; do
        [ "$host" = ghe.example.com:8443 ] && [ "$nwo" = owner/internal ] || fail "port status host mismatch ($source)"
        case "$request" in api\ *) case "$request" in *--hostname*) fail "port escape emitted --hostname" ;; esac ;; esac
    done <"$STUB_HOST_AUDIT"
    case "$out" in *'authenticated to ghe.example.com:8443'*) ;; *) fail "printed host disagrees with check: $out" ;; esac
    unset STUB_HOST_AUDIT
done

echo "==> failed owner-type reads leave all organization routing values unknown"
out="$(GH_REPO_JSON="$internal_repo" GH_OWNER_TYPE_FAIL=1 GH_ROUTING_REPO_JSON='[]' GH_ROUTING_ORG_JSON="$routing_org" run_setup_section project)"
for name in CI_RUNS_ON BROWSER_RUNS_ON IMAGE_BUILD_RUNS_ON ISOLATED_RUNS_ON MULTICORE_RUNS_ON; do
    case "$out" in
    *"$name (org) - unknown"*) ;;
    *) fail "failed owner-type lookup hid unknown $name org value: $out" ;;
    esac
done

echo "==> a token with 'project' reports the board as writable"
out="$(run_gh_section project)"
case "$out" in
*"Project board writes"*"token has 'project'"*) ;;
*) fail "expected a satisfied board-writes line, got: ${out}" ;;
esac

# assert_rest_only_calls LABEL — fail if the stub's call log ($STUB_CALLS) holds
# a GraphQL-backed or otherwise proxy-refused surface. Every pattern is anchored
# on `(^| )` because the log line is the bare `$*` of the gh call: a `gh pr list`
# is logged as `pr list ...`, with no leading space for a ` pr list` pattern to
# match. `release list` is GraphQL-backed, and is the call #1437 removed. The
# `search` and `project` subcommands are refused by the proxy the same way as
# the `search/` and GraphQL endpoints, and `pr checks` / `pr status` are
# GraphQL-backed like `pr list` and `pr view`.
assert_rest_only_calls() {
    if grep -E '(^| )(graphql|search/|repositories/)|--paginate|(^| )pr (list|view|checks|status)|(^| )issue (list|view)|(^| )label list|(^| )release (list|view)|(^| )search |(^| )project ' "${STUB_CALLS}" >/dev/null; then
        fail "$1 used a forbidden GitHub surface: $(tr '\n' ' ' <"${STUB_CALLS}")"
    fi
}

echo "==> REST-only setup completes and marks the GraphQL-only project surface unavailable"
STUB_CALLS="${TMP}/rest-only-calls.txt"
export STUB_CALLS
: >"${STUB_CALLS}"
out="$(GH_REPO_JSON="$public_repo" run_setup_section project)"
case "$out" in
*"GitHub Project linked"*"unavailable through the REST-only GitHub API"*) ;;
*) fail "expected an explicit unavailable project line, got: ${out}" ;;
esac
assert_rest_only_calls "REST-only setup status"
unset STUB_CALLS

# ── Release line (#1437) ─────────────────────────────────────────────────────
# The line states one of three things and only the middle one may recommend a
# remedy: a release exists, the read succeeded and found none, or the read
# failed. Every case runs under the REST-only stub (GraphQL, search and
# repositories/ refused with a 403), the shape of a Claude Code on the web
# session, and checks the call log so a GraphQL-backed read cannot hide behind a
# stub that happens to answer it.
STUB_CALLS="${TMP}/release-calls.txt"
export STUB_CALLS
run_release_setup() {
    : >"${STUB_CALLS}"
    GH_STUB_RELEASES="$1" GH_REPO_JSON="$public_repo" run_setup_section project "${WITH_RELEASE}"
}

echo "==> the release line reports a release read over REST"
out="$(run_release_setup present)"
case "$out" in
*"[x] Release published - v4.47.1"*) ;;
*) fail "expected the latest release on the release line, got: ${out}" ;;
esac
assert_rest_only_calls "the release line"
grep -F 'releases?per_page=1' "${STUB_CALLS}" >/dev/null ||
    fail "the release line did not read repos/{owner}/{repo}/releases?per_page=1: $(tr '\n' ' ' <"${STUB_CALLS}")"
case "$out" in
*"task release:init"*) fail "a repository with a release was told to run release:init: ${out}" ;;
*) ;;
esac

echo "==> a successful read that finds no release still recommends release:init"
out="$(run_release_setup none)"
case "$out" in
*"[ ] Release published"*"task release:init"*) ;;
*) fail "an observed absence must keep its remedy, got: ${out}" ;;
esac

echo "==> a failed release read reports unavailable and prints no remedy"
for mode in fail garbage malformed empty-tag two-documents trailing-document; do
    out="$(run_release_setup "${mode}")"
    case "$out" in
    *"[?] Release published - unavailable"*) ;;
    *) fail "a ${mode} release read was not reported as unavailable: ${out}" ;;
    esac
    case "$out" in
    *"Release published"*"task release:init"* | *"[ ] Release published"*)
        fail "a ${mode} release read stated an absence it did not observe: ${out}"
        ;;
    *) ;;
    esac
    assert_rest_only_calls "the ${mode} release read"
done

echo "==> every section, and the whole block, completes under the REST-only stub"
# The forbidden-surface check above covered the setup section alone, so a
# GraphQL-backed call reintroduced in any other section would have passed: the
# stub answers `pr list` and `run list` with `[]` and a grep nobody ran saw
# nothing. Each section, and one run with NO section argument (the whole status
# block), now runs with every gh call logged. A read the proxy refuses must
# render as a line of its own; the proxy's raw error text appearing in the
# output means a failure leaked through instead.
for section in "" git gh creds code env setup; do
    : >"${STUB_CALLS}"
    make_stub project
    rc=0
    out="$(cd "${TMP}/with-release" && GH_STUB_RELEASES=fail GH_REPO_JSON="$public_repo" \
        GH_REPO=owner/public PATH="${TMP}/bin:${PATH}" NO_COLOR=1 \
        "${WITH_RELEASE}" ${section:+"${section}"} 2>&1)" || rc=$?
    label="the ${section:-whole-block} run"
    [ "${rc}" -eq 0 ] || fail "${label} exited ${rc} under the REST-only stub: ${out}"
    case "$out" in
    *"HTTP 403"* | *"stub: unexpected"*) fail "${label} leaked a refused read instead of reporting it: ${out}" ;;
    *) ;;
    esac
    assert_rest_only_calls "${label}"
done
# The whole block must still hold every default section's header, so a run that
# "completed" by skipping a section cannot pass.
: >"${STUB_CALLS}"
make_stub project
rc=0
out="$(cd "${TMP}/with-release" && GH_REPO_JSON="$public_repo" GH_REPO=owner/public \
    PATH="${TMP}/bin:${PATH}" NO_COLOR=1 "${WITH_RELEASE}" 2>&1)" || rc=$?
[ "${rc}" -eq 0 ] || fail "the whole-block header run exited ${rc}: ${out}"
for header in "Git Status" "GitHub Status" "Codebase Stats" "Environment" "Local Credentials"; do
    case "$out" in
    *"${header}"*) ;;
    *) fail "the whole-block run lacks its ${header} section: ${out}" ;;
    esac
done
# The sections that cannot be filled through REST say so: the setup audit is
# where the GraphQL-only Projects surface and the (here refused) release read
# live, and both must be named unavailable rather than graded absent.
out="$(GH_STUB_RELEASES=fail GH_REPO_JSON="$public_repo" run_setup_section project "${WITH_RELEASE}")"
for line in "GitHub Project linked - unavailable through the REST-only GitHub API" \
    "Release published - unavailable"; do
    case "$out" in
    *"${line}"*) ;;
    *) fail "the setup audit did not report '${line}': ${out}" ;;
    esac
done
unset STUB_CALLS

echo "==> read-only 'read:project' is NOT reported as satisfied"
# The state most easily mistaken for working: --show reads the card fine, so the
# board looks reachable right up to the write that moves it.
out="$(run_gh_section read-only)"
case "$out" in
*"token has 'project'"*) fail "read:project must not satisfy a WRITE check: ${out}" ;;
*"read-only"*"task setup:gh-scopes"*) ;;
*) fail "expected a read-only warning naming the remedy, got: ${out}" ;;
esac

echo "==> the bot profile's scope remedy re-provisions GH_TOKEN, never widens the login"
out="$(FOREMAN_DEVCONTAINER=bot run_gh_section read-only)"
case "$out" in
*"bot profile: re-provision GH_TOKEN"*) ;;
*) fail "expected the bot-profile scope remedy, got: ${out}" ;;
esac
case "$out" in
*"task setup:gh-scopes"* | *"gh auth refresh"*) fail "the bot profile must not be told to widen its login: ${out}" ;;
esac

echo "==> the agent posture's scope remedy names AGENT_GH_TOKEN, not GH_TOKEN"
out="$(FOREMAN_DEVCONTAINER=agent run_gh_section read-only)"
case "$out" in
*"agent posture: re-provision AGENT_GH_TOKEN"*) ;;
*) fail "expected the agent-posture scope remedy, got: ${out}" ;;
esac
case "$out" in
*"task setup:gh-scopes"* | *"gh auth refresh"* | *"bot profile"*) fail "the agent posture must get its own remedy: ${out}" ;;
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
STUB_CALLS="${TMP}/enterprise-calls.txt"
export STUB_CALLS
: >"${STUB_CALLS}"
out="$(run_gh_section records-hostname "${ENTERPRISE}")"
grep -qx 'ghe.example.com' "${STUB_HOSTS}" ||
    fail "probe used $(tr '\n' ' ' <"${STUB_HOSTS}") — expected the remote's host"
case "$out" in
*"not authenticated"*) fail "a valid Enterprise login must not read as unauthenticated: ${out}" ;;
*"token has 'project'"*) ;;
*) fail "expected the Enterprise section to render, got: ${out}" ;;
esac
# The REST reads must follow the same host: the endpoint stays repos/OWNER/REPO
# (never repos/HOST/OWNER/REPO) and --hostname carries the Enterprise host, or
# every read after the auth probe silently goes to github.com (challenge r1).
grep -q '^api repos/owner/repo/pulls?state=open&sort=updated&direction=desc&per_page=10&page=1 --hostname ghe.example.com$' "${STUB_CALLS}" ||
    fail "Enterprise REST reads did not carry the remote's host: $(grep '^api ' "${STUB_CALLS}" | tr '\n' ';')"
grep -q '^api repos/ghe.example.com/' "${STUB_CALLS}" &&
    fail "an Enterprise host leaked into the endpoint path: $(grep '^api ' "${STUB_CALLS}" | tr '\n' ';')"
unset STUB_CALLS

echo "==> a hyphenated owner and name still reach the open-PR read"
# The two fixtures above are hyphen-free, which is why neither could see the
# character-class defect: this read is the one that silently vanished.
STUB_CALLS="${TMP}/hyphenated-calls.txt"
export STUB_CALLS
: >"${STUB_CALLS}"
out="$(run_gh_section project "${HYPHENATED}")"
case "$out" in
*"not authenticated"*) fail "the hyphenated fixture's section did not render: ${out}" ;;
esac
grep -q '^api repos/my-org/harmon-init/pulls?state=open&sort=updated&direction=desc&per_page=10&page=1$' "${STUB_CALLS}" ||
    fail "a hyphenated repository never reached the open-PR read: $(grep '^api ' "${STUB_CALLS}" | tr '\n' ';')"
unset STUB_CALLS

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

echo "==> no user-facing message hardcodes a remedy that acts on the current login"
# One invariant, widened from the original refresh-only form (issue #596).
#
# The remedy is derived from the credential source once, because `gh auth
# refresh` is wrong for an env-provided or fine-grained token — a hardcoded
# copy is how one call site silently drifts back to advice that cannot work,
# and the setup section (which needs live GitHub data to render) cannot be
# driven by the stub above. So assert it statically.
#
# The class is wider than refresh, and the bot profile is why
# (harmon-init#1236). There, EVERY remedy that acts on the current gh login is
# wrong, not just the one that cannot work: the gh-identity tripwire may be
# about to report that login as a personal credential which must be removed,
# and advice to use it (`gh auth login`) or widen it (`gh auth refresh -s`,
# `task setup:gh-scopes`) on the same screen re-creates the exact escalation
# the tripwire exists to stop. Challenge found two such sites in two
# consecutive rounds — the setup audit's login line, then the scope remedy —
# so the guard is written against the class.
#
# The literal may appear only in a comment or inside one of the profile-aware
# derivation helpers, which ARE the rule.
#
# The original form also exempted any `GH_REMEDY*=` assignment, because back
# then the assignment WAS the derivation. It no longer is, and that exemption
# had become a hole wide enough to drive the finding through: `GH_REMEDY_DEFAULT
# ="see: task setup:gh-scopes"` matched it and sailed past. Mutation-verified
# after removal. The patterns below are deliberately the RUNNABLE recommendation
# forms — `gh auth refresh -s` rather than bare `gh auth refresh` — so
# derive_gh_scope_state is exempt on the same grounds as the other two: it IS
# the derivation, and its "an env token overrides gh auth refresh" branches
# explain why that command will not work rather than recommending it. The
# exemption is by FUNCTION, not by line shape — which is what the removed
# assignment exemption got wrong.
remedy_helper_lines="$(awk '
    /^(gh_login_remedy|gh_scope_remedy_default|derive_gh_scope_state)\(\) \{/ { inf = 1 }
    inf { print NR }
    inf && /^\}/ { inf = 0 }
' "${status}")"
while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
    *"#"*"gh auth refresh"* | *"#"*"gh auth login"* | *"#"*"setup:gh-scopes"*) continue ;;
    esac
    # Inside a derivation helper? Then it is the single source, not a copy.
    if grep -qx "${line%%:*}" <<<"${remedy_helper_lines}"; then
        continue
    fi
    fail "hardcoded remedy acting on the current login — derive it: ${line}"
done <<EOF
$(grep -nE "gh auth refresh|gh auth login|task setup:gh-scopes" "${status}" || true)
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
    sed -n -E "s/.*[[:space:]]([0-9]+) task status:$2([[:space:]].*)?\$/\1/p" "$1" | sed -n '1p'
}

# The seconds run_timeout waits between SIGTERM and SIGKILL. A probe that
# ignores the first spends its deadline PLUS this before the pipe it holds
# closes, so every budget below is modelled from the sum, not the deadline
# alone. Read out of status.sh rather than restated, because a grace changed
# in one place and remembered in the other is exactly how these budgets rot.
# Absent (no `-k` in run_timeout) it is zero and the sums are unchanged.
kill_grace="$(sed -n -E 's/.*"\$\{TIMEOUT_BIN\}" -k ([0-9]+) "\$\{secs\}".*/\1/p' "${status}" | sed -n '1p')"
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
# rather than days later, when a board write fails mid-integration.
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

echo "==> status:creds names the profile's own provisioning remedy, never an interactive login"
make_codex_stub in
out="$(FOREMAN_DEVCONTAINER=bot run_creds_section unauthenticated)"
case "$out" in
*"GitHub CLI (gh) - bot profile: provision GH_TOKEN"*) ;;
*) fail "expected the bot-profile login remedy from status:creds, got: ${out}" ;;
esac
case "$out" in
*"GitHub CLI (gh) - gh auth login"*) fail "the bot profile must not be told to log in interactively: ${out}" ;;
esac
out="$(FOREMAN_DEVCONTAINER=agent run_creds_section unauthenticated)"
case "$out" in
*"GitHub CLI (gh) - agent posture: provision AGENT_GH_TOKEN"*) ;;
*) fail "expected the agent-posture login remedy from status:creds, got: ${out}" ;;
esac
case "$out" in
*"GitHub CLI (gh) - gh auth login"* | *"bot profile"*) fail "the agent posture must get its own login remedy: ${out}" ;;
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

# ── Completeness-required inventories ────────────────────────────────────────
# status.sh walks labels, org issue types, and org issue fields with MAX_ITEMS=0,
# so the GH_REST_MAX_PAGES ceiling — not the data — can be what ends the walk,
# and the pages that did arrive are a PARTIAL list. Each of those three
# renderers can print a definite verdict about what the repository lacks, and
# printing it from a partial list is an absence nobody observed (challenge r2).
# No fixture above ships the setup:github-* markers, so this one is the first to
# render any of the three.
mkdir -p "${TMP}/inventories/scripts/lib" "${TMP}/bin-node"
cp "${status}" "${TMP}/inventories/scripts/status.sh"
cp "${scopes_lib}" "${TMP}/inventories/scripts/gh-scopes.sh"
cp "${output_lib}" "${TMP}/inventories/scripts/lib/output.sh"
cp "${rest_lib}" "${TMP}/inventories/scripts/lib/gh-rest.sh"
: >"${TMP}/inventories/scripts/setup-github-labels.sh"
: >"${TMP}/inventories/scripts/setup-github-issue-types.sh"
: >"${TMP}/inventories/scripts/setup-github-issue-fields.sh"
# The labels renderer takes its WANT list from the label-registry renderer. Both
# paths are markers it only tests with -f, and the node stub below supplies the
# rendering, so these cases assert on how status.sh grades an inventory rather
# than on whatever label-registry.json happens to hold today.
: >"${TMP}/inventories/label-registry.json"
: >"${TMP}/inventories/scripts/label-registry-render.mjs"
{
    echo '#!/usr/bin/env bash'
    echo '[ "${1:-}" != --version ] || { echo v20.0.0; exit 0; }'
    echo 'printf "%s\n" "area:ci|ci and automation" "type:bug|a defect"'
} >"${TMP}/bin-node/node"
chmod +x "${TMP}/bin-node/node"
INVENTORIES="${TMP}/inventories/scripts/status.sh"
inventory_repo='{"full_name":"owner/repo","visibility":"PUBLIC","private":false,"default_branch":"main","owner":{"type":"Organization"}}'

# run_inventory_section — the setup audit on the fixture above, with the node
# stub ahead of the shared bin so no other case inherits it.
run_inventory_section() {
    make_stub project
    PATH="${TMP}/bin-node:${TMP}/bin:${PATH}" NO_COLOR=1 \
        GH_REPO=owner/repo GH_REPO_JSON="${inventory_repo}" \
        "${INVENTORIES}" setup 2>&1
}

echo "==> a read that trips the page ceiling reports unknown, never an absence"
# GH_REST_MAX_PAGES=1 against full pages: page 1 arrives, page 2 is refused, and
# the walk returns 4 holding one page of a list it never finished reading.
out="$(GH_STUB_FULL_PAGES=1 GH_REST_MAX_PAGES=1 run_inventory_section)"
for label in "Starter labels" "Org issue types" "Org issue fields"; do
    case "$out" in
    *"[?] ${label} - read truncated at the 1-page ceiling"*) ;;
    *) fail "a truncated read was not reported as unknown for ${label}: ${out}" ;;
    esac
done
case "$out" in
*"run task setup:github-labels"*)
    fail "a truncated label read still told the reader to provision labels: ${out}"
    ;;
esac
case "$out" in
*"run task setup:github-issue-types"*)
    fail "a truncated issue-type read still told the reader to provision types: ${out}"
    ;;
esac
case "$out" in
*"run task setup:github-issue-fields"*)
    fail "a truncated issue-field read still told the reader to provision fields: ${out}"
    ;;
esac

echo "==> a complete, genuinely empty read still renders its existing verdict"
# The other half of the invariant: completeness gates the claim, it does not
# suppress it. An unprovisioned repository answers every page and answers it
# empty, and that IS an observed absence. Labels are the one of the three whose
# empty verdict is a definite negative; org issue types and fields have always
# reported an empty read as unknown-needs-admin:org, and must keep saying that
# rather than borrowing the truncation reason.
out="$(run_inventory_section)"
case "$out" in
*"[ ] Starter labels - run task setup:github-labels"*) ;;
*) fail "an empty label read lost its provisioning verdict: ${out}" ;;
esac
case "$out" in
*"[?] Org issue types - needs admin:org"*) ;;
*) fail "an empty issue-type read lost its existing verdict: ${out}" ;;
esac
case "$out" in
*"[?] Org issue fields - needs admin:org (public preview)"*) ;;
*) fail "an empty issue-field read lost its existing verdict: ${out}" ;;
esac
case "$out" in
*"read truncated at the"*) fail "a complete read was reported as truncated: ${out}" ;;
esac

echo "==> both documented issue-field page shapes render the same field list"
# The preview documents its page as the array wrapped under `issue_fields` AND as
# the bare array. The reader required the wrapper, so the other shape was a
# FAILED read — rendered `unknown`, which told an org that really does have the
# field that nobody could see it (review r1). The shape is the only difference
# between these two runs, so the verdict may not depend on it.
#
# The org below is FULLY PROVISIONED as the setup script leaves it: GitHub's
# built-ins (Priority, the dates), Product, the four classification fields, and
# Effort on the ladder. Options come back in no particular order — status.sh must
# read them by name, not position — and Impact carries one option an owner added,
# which is fine. There is no Agent, Domain, Layer, or Tier field, and Priority is
# not wanted: it is GitHub's own human priority, so requiring any of them would
# report a permanent false failure on every fresh org (#662, #875, #698).
fields_complete='[
 {"name":"Priority","data_type":"single_select","options":[{"name":"Low","priority":4},{"name":"Urgent","priority":1},{"name":"High","priority":2},{"name":"Medium","priority":3}]},
 {"name":"Start date","data_type":"date"},
 {"name":"Target date","data_type":"date"},
 {"name":"Product","data_type":"text"},
 {"name":"Impact","data_type":"single_select","options":[{"name":"massive","priority":5},{"name":"epic","priority":6},{"name":"minimal","priority":1},{"name":"high","priority":4},{"name":"low","priority":2},{"name":"medium","priority":3}]},
 {"name":"Risk","data_type":"single_select","options":[{"name":"trivial","priority":1},{"name":"low","priority":2},{"name":"medium","priority":3},{"name":"high","priority":4},{"name":"critical","priority":5}]},
 {"name":"Complexity","data_type":"single_select","options":[{"name":"xs","priority":1},{"name":"s","priority":2},{"name":"m","priority":3},{"name":"l","priority":4},{"name":"xl","priority":5}]},
 {"name":"Priority (AI)","data_type":"single_select","options":[{"name":"p0","priority":1},{"name":"p1","priority":2},{"name":"p2","priority":3},{"name":"p3","priority":4},{"name":"p4","priority":5}]},
 {"name":"Effort","data_type":"single_select","options":[{"name":"1","priority":1},{"name":"2","priority":2},{"name":"3","priority":3},{"name":"5","priority":4},{"name":"8","priority":5},{"name":"13","priority":6},{"name":"20","priority":7}]},
 {"name":"Model family","data_type":"single_select","options":[{"name":"gemini","priority":2},{"name":"claude","priority":1}]},
 {"name":"Model","data_type":"single_select","options":[{"name":"opus","priority":1},{"name":"flash","priority":2}]},
 {"name":"Model version","data_type":"single_select","options":[{"name":"3.8","priority":3},{"name":"5.5","priority":1},{"name":"5.1","priority":2},{"name":"4.0","priority":4}]},
 {"name":"Model effort","data_type":"single_select","options":[{"name":"low","priority":1},{"name":"high","priority":2}]}
]'
issue_fields_ok="[x] Org issue fields - Product, Impact, Risk, Complexity, Priority (AI), Effort, Model family, Model, Model version, Model effort"
for shape in wrapped bare; do
    out="$(GH_STUB_ISSUE_FIELDS="$shape" GH_STUB_ISSUE_FIELDS_JSON="$fields_complete" run_inventory_section)"
    case "$out" in
    *"$issue_fields_ok"*) ;;
    *) fail "the ${shape} issue-field page shape did not render a fully provisioned org as ok: ${out}" ;;
    esac
done

echo "==> an org that is missing fields, options, or the right type is reported, with the remedy"
# issue_fields_case LABEL JQ_EDIT EXPECTED — render the org after JQ_EDIT is applied
# to the complete snapshot and require EXPECTED in the Org issue fields line.
issue_fields_case() {
    local label="$1" edit="$2" expected="$3" snapshot
    snapshot="$(jq -c "$edit" <<<"$fields_complete")"
    out="$(GH_STUB_ISSUE_FIELDS=bare GH_STUB_ISSUE_FIELDS_JSON="$snapshot" run_inventory_section)"
    case "$out" in
    *"$expected"*) ;;
    *) fail "${label}: expected '${expected}' in: ${out}" ;;
    esac
    case "$out" in
    *"$issue_fields_ok"*) fail "${label}: an incomplete org was reported ok: ${out}" ;;
    esac
}
# The state of every org today: GitHub's built-ins and Product, nothing else.
issue_fields_case "an org with only GitHub's built-ins" \
    'map(select(.name == "Priority" or .name == "Start date" or .name == "Target date" or .name == "Product")) + [{"name":"Effort","data_type":"single_select","options":[{"name":"High","priority":1},{"name":"Medium","priority":2},{"name":"Low","priority":3}]}]' \
    "[ ] Org issue fields - missing Impact, Risk, Complexity, Priority (AI), Model family, Model, Model version, Model effort; Effort lacks 1, 2, 3, 5, 8, 13, 20 — run task setup:github-issue-fields"
issue_fields_case "a missing option" \
    'map(if .name == "Impact" then .options |= map(select(.name != "massive")) else . end)' \
    "[ ] Org issue fields - Impact lacks massive — run task setup:github-issue-fields"
issue_fields_case "an Effort still on the shipped options" \
    'map(if .name == "Effort" then .options = [{"name":"High","priority":1},{"name":"Low","priority":2}] else . end)' \
    "[ ] Org issue fields - Effort lacks 1, 2, 3, 5, 8, 13, 20 — run task setup:github-issue-fields"
issue_fields_case "a field of the wrong data type" \
    'map(if .name == "Risk" then {name, data_type: "text"} else . end)' \
    "[ ] Org issue fields - wrong type: Risk is text — rename/delete, then re-run task setup:github-issue-fields"
issue_fields_case "a field with no options array" \
    'map(if .name == "Complexity" then del(.options) else . end)' \
    "[ ] Org issue fields - Complexity lacks xs, s, m, l, xl — run task setup:github-issue-fields"
# A field that keeps its name and options but loses its data_type is a changed or
# malformed preview response: the verdict is unknown, never ok (challenge r3, C3-F4).
issue_fields_case "a field with no data_type" \
    'map(if .name == "Impact" then del(.data_type) else . end)' \
    "[?] Org issue fields - type unreadable for Impact — inventory unchecked"
# An option is one option however its name is spelled: a name that merely lists
# the wanted ones, joined by a comma or by the control character the renderer
# itself joins with, must not satisfy them (challenge r1, C1-F4).
issue_fields_case "one option named like the whole wanted scale" \
    'map(if .name == "Impact" then .options = [{"name":"minimal,low,medium,high,massive","priority":1}] else . end)' \
    "[ ] Org issue fields - Impact lacks minimal, low, medium, high, massive — run task setup:github-issue-fields"
issue_fields_case "one option whose name hides the renderer's own separator" \
    'map(if .name == "Impact" then .options = [{"name":"minimal\u001flow\u001fmedium\u001fhigh\u001fmassive","priority":1}] else . end)' \
    "[ ] Org issue fields - Impact lacks minimal, low, medium, high, massive — run task setup:github-issue-fields"
# Priority (AI) and Priority are two fields: the first being absent must read as
# exactly that, never as the built-in Priority being absent or standing in for it.
issue_fields_case "Priority (AI) missing while the built-in Priority exists" \
    'map(select(.name != "Priority (AI)"))' \
    "[ ] Org issue fields - missing Priority (AI) — run task setup:github-issue-fields"
# Names are matched whole: a field that merely STARTS with a wanted name is a
# different field and must not satisfy it.
issue_fields_case "a field whose name only starts with a wanted name" \
    'map(if .name == "Effort" then .name = "Effort estimate" else . end)' \
    "[ ] Org issue fields - missing Effort — run task setup:github-issue-fields"
# The four Model fields (#1517) are wanted by name and type only: their options
# come from agent-registry.json and belong to the setup script, which validates
# the registry. A Model field with no options at all is still ok here.
issue_fields_case "a missing Model field" \
    'map(select(.name != "Model effort"))' \
    "[ ] Org issue fields - missing Model effort — run task setup:github-issue-fields"
issue_fields_case "a Model field of the wrong data type" \
    'map(if .name == "Model" then {name, data_type: "text"} else . end)' \
    "[ ] Org issue fields - wrong type: Model is text — rename/delete, then re-run task setup:github-issue-fields"
echo "==> the Model fields' options are not checked"
out="$(GH_STUB_ISSUE_FIELDS=bare GH_STUB_ISSUE_FIELDS_JSON="$(jq -c 'map(if (.name | startswith("Model")) then .options = [] else . end)' <<<"$fields_complete")" run_inventory_section)"
case "$out" in
*"$issue_fields_ok"*) ;;
*) fail "present, correctly typed Model fields were not ok without options: ${out}" ;;
esac

echo "==> the human Priority is not wanted: an org without the built-in Priority is still ok"
out="$(GH_STUB_ISSUE_FIELDS=bare GH_STUB_ISSUE_FIELDS_JSON="$(jq -c 'map(select(.name != "Priority"))' <<<"$fields_complete")" run_inventory_section)"
case "$out" in
*"$issue_fields_ok"*) ;;
*) fail "the built-in Priority was required of a fully provisioned org: ${out}" ;;
esac

echo "==> a failed issue-field read still renders unknown, never an absence"
# Completeness is what accepting a second shape must not cost. A read that FAILED
# is still a list nobody saw, so it may borrow neither the provisioning verdict
# nor the needs-admin one — the same invariant the truncation cases above assert,
# on the other incomplete-read code path.
out="$(GH_STUB_ISSUE_FIELDS=fail run_inventory_section)"
case "$out" in
*"[?] Org issue fields - read failed — inventory unchecked"*) ;;
*) fail "a failed issue-field read was not reported as unknown: ${out}" ;;
esac
case "$out" in
*"run task setup:github-issue-fields"*)
    fail "a failed issue-field read still told the reader to provision fields: ${out}"
    ;;
esac

echo "status.sh tests passed"
