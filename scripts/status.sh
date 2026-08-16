#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
PROJECT_NAME="$(basename "${REPO_ROOT}")"

# Section filter: empty = show all, or "git", "gh", "creds", "code", "env"
SECTION="${1:-}"

# Temp directory for parallel data collection
TMPDIR_STATUS="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_STATUS}"' EXIT

# Overridable so a test can drive the deadline path without waiting on it.
NETWORK_TIMEOUT="${NETWORK_TIMEOUT:-5}"

# The required-scope list and its comparison helpers, stated once for this
# script, setup-gh-scopes.sh, and the devcontainer's gh_auth_help banner.
# A consumer repo extends it by exporting GH_REQUIRED_SCOPES — see that file.
# shellcheck source=scripts/gh-scopes.sh
. "${REPO_ROOT}/scripts/gh-scopes.sh"

# ── Tool detection ──────────────────────────────────────────────────────────

# NO_COLOR (https://no-color.org/) turns off gum styling as well as ANSI, which
# makes the board's output plain, stable text — greppable, diffable, and
# assertable by scripts/test-status.sh without matching around escape sequences
# or box drawing.
HAS_GUM=false
[[ -z "${NO_COLOR:-}" ]] && command -v gum &>/dev/null && HAS_GUM=true

# Network probes below are bounded so a hung `gh` call cannot wedge the board.
# Stock macOS ships no `timeout` — it comes from coreutils, which also provides
# `gtimeout`. When it was missing, every bounded probe failed 127 into
# /dev/null and the board rendered an EMPTY PR/checks section instead of
# reporting a problem. Resolve once; if it is genuinely unavailable, run the
# probes unbounded and say so rather than silently showing nothing.
TIMEOUT_BIN=""
if command -v timeout &>/dev/null; then
    TIMEOUT_BIN=timeout
elif command -v gtimeout &>/dev/null; then
    TIMEOUT_BIN=gtimeout
else
    echo "status: no 'timeout' found (brew install coreutils) — network probes are unbounded." >&2
fi

# A deadline alone does NOT bound a probe, because every probe below is read
# through `$(...)`: a command substitution returns when the write end of its
# pipe closes, not when `timeout` exits. A probe that survives SIGTERM keeps
# that pipe open and the board hangs FOREVER while `timeout` has already
# reported 124 (harmon-init#865 — `claude auth status --json` blocks reading a
# terminal stdin, and `timeout 3` around it wedged the whole board with no
# deadline left to fire). Two guards, because they fail differently:
#
#   * `</dev/null` — no probe here reads stdin, and a CLI that waits on one
#     never starts blocking. This is the fix for the observed hang.
#   * `-k` — a hard kill after the deadline, so the pipe closes even for a
#     probe that ignores or traps SIGTERM. This is the guard for the next one.
#
# `-k` is probed rather than assumed: where `timeout` is BusyBox's, rejecting
# the flag would fail every probe and report a wholly broken board. Note the
# deadline exit code is then 137 (SIGKILL) rather than 124 — both mean "the
# deadline fired", and every reader of these codes treats them alike.
TIMEOUT_KILL_AFTER=no
if [ -n "${TIMEOUT_BIN}" ] && "${TIMEOUT_BIN}" -k 1 1 true 2>/dev/null; then
    TIMEOUT_KILL_AFTER=yes
fi

run_timeout() {
    local secs="$1"
    shift
    if [ -z "${TIMEOUT_BIN}" ]; then
        "$@" </dev/null
    elif [ "${TIMEOUT_KILL_AFTER}" = yes ]; then
        "${TIMEOUT_BIN}" -k 1 "${secs}" "$@" </dev/null
    else
        "${TIMEOUT_BIN}" "${secs}" "$@" </dev/null
    fi
}

# ── Formatting helpers ──────────────────────────────────────────────────────

# Every `gum` call goes through here, because gum asks the TERMINAL for its
# background colour (OSC 11) whenever its own stdout is one — and waits 5s for
# an answer. A terminal that replies to neither that nor the cursor-position
# probe gum falls back on pays the full 5s, EVERY invocation; a board renders
# a dozen of them, which is the minutes-long hang of harmon-init#865 on a
# devcontainer terminal. (Terminals that answer either probe were always fast,
# which is why this never reproduced on a Mac.)
#
# Piping stdout removes the terminal from gum's view, so it does not ask.
# `CLICOLOR_FORCE` then restores the colour gum drops for a non-terminal
# stdout: with stderr still on the terminal the output is BYTE-IDENTICAL to
# what an answering terminal produced before this change, 256-colour included.
# Where stderr is redirected too, gum cannot read the depth and falls back to
# 16 colours — not a regression, since gum emitted no colour at all into that
# case before.
gum_style() {
    CLICOLOR_FORCE=1 gum style "$@" | cat
}

section_header() {
    local title="$1"
    if $HAS_GUM; then
        gum_style --bold --foreground 212 --border-foreground 240 \
            --border rounded --padding "0 1" -- "$title"
    else
        echo ""
        echo "==> ${title}"
        echo "────────────────────────────────────────"
    fi
}

section_box() {
    local content
    content="$(cat)"
    if $HAS_GUM; then
        echo "$content" | gum_style --border rounded \
            --border-foreground 240 --padding "0 1" --margin "0 0"
    else
        echo "$content"
        echo ""
    fi
}

kv() {
    local key="$1" val="$2"
    if $HAS_GUM; then
        printf "  %s  %s\n" "$(gum_style --bold --foreground 39 "$key:")" "$val"
    else
        printf "  %-20s %s\n" "$key:" "$val"
    fi
}

should_show() {
    [[ -z "${SECTION}" || "${SECTION}" == "$1" ]]
}

# ── Setup-check helpers ─────────────────────────────────────────────────────

# Color is on when stdout is a TTY or gum is present (gum forces color anyway).
# ANSI only — no extra dependency. Detected here at top level because inside the
# section's `| section_box` pipe, stdout reads as a non-TTY.
USE_COLOR=false
[[ -z "${NO_COLOR:-}" ]] && { [ -t 1 ] || $HAS_GUM; } && USE_COLOR=true

# c SGR TEXT — wrap TEXT in an ANSI SGR sequence when color is enabled.
c() {
    if $USE_COLOR; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}

# Status glyphs: colored Unicode when color is on, plain ASCII otherwise.
if $USE_COLOR; then
    I_OK="$(c '1;32' '✓')"
    I_NO="$(c '1;31' '✗')"
    I_UNKNOWN="$(c '1;33' '?')"
    I_NA="$(c '2' '–')"
    I_INFO="$(c '1;36' '•')"
else
    I_OK='[x]'
    I_NO='[ ]'
    I_UNKNOWN='[?]'
    I_NA='[-]'
    I_INFO=' * '
fi

# subhead TEXT — a colored group header inside a section.
subhead() {
    printf '\n  %s\n' "$(c '1;36' "▸ $1")"
}

# bar PERCENT — a 20-cell Unicode progress bar (green fill on a dim track).
bar() {
    local pct="$1" width=20 i=0 fill="" track=""
    local filled=$((pct * width / 100))
    [ "${filled}" -gt "${width}" ] && filled="${width}"
    [ "${filled}" -lt 0 ] && filled=0
    while [ "${i}" -lt "${width}" ]; do
        if [ "${i}" -lt "${filled}" ]; then fill="${fill}█"; else track="${track}░"; fi
        i=$((i + 1))
    done
    printf '%s%s' "$(c '32' "${fill}")" "$(c '2' "${track}")"
}

SETUP_OK=0
SETUP_NO=0
SETUP_UNKNOWN=0
SETUP_NA=0

# checkline STATUS LABEL [DETAIL]
#   STATUS in: ok | no | unknown | na | info
# Counters mutate in the caller's subshell, so the summary line MUST be emitted
# from the same { ... } group as the checks (see the Setup section).
checkline() {
    local status="$1" label="$2" detail="${3:-}" icon=""
    case "$status" in
    ok) icon="$I_OK" && SETUP_OK=$((SETUP_OK + 1)) ;;
    no) icon="$I_NO" && SETUP_NO=$((SETUP_NO + 1)) ;;
    unknown) icon="$I_UNKNOWN" && SETUP_UNKNOWN=$((SETUP_UNKNOWN + 1)) ;;
    na) icon="$I_NA" && SETUP_NA=$((SETUP_NA + 1)) ;;
    info) icon="$I_INFO" ;;
    esac
    if [ -n "$detail" ]; then
        printf '  %s %s — %s\n' "$icon" "$label" "$detail"
    else
        printf '  %s %s\n' "$icon" "$label"
    fi
}

# has_cred FILE NAME — true if NAME appears in FILE, where FILE is the output of
# `gh secret/variable list --json name`. Only names are fetched (never values),
# and this never prints the file — it only reports presence as ✓/✗.
has_cred() {
    jq -e --arg n "$2" 'any(.[]; .name == $n)' "$1" >/dev/null 2>&1
}

# has_scope LINE NAME — true if NAME is present as a quoted scope in a
# `gh auth status` "Token scopes:" line (`… 'gist', 'project', 'repo'`).
# Matching on the quotes is what keeps `project` from also matching
# `read:project` (and vice versa) — the two are different grants and the
# caller decides which ones satisfy it.
has_scope() {
    case "$1" in
    *"'$2'"*) return 0 ;;
    *) return 1 ;;
    esac
}

# gh_target_host is defined in scripts/gh-scopes.sh, sourced above: the host and
# the required scopes are one question (whose token, carrying what), and two
# copies of the resolution would let the check and its remedy disagree about
# which credential they mean.

# ── Parallel data collection ────────────────────────────────────────────────

PID_PRS=""
PID_CHECKS=""
PID_TOKEI=""

CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || echo "detached")"

# Resolve auth once and keep the output: it is both the gate for the GitHub
# section and the only place the token's scopes are reported, and re-running it
# per use would spend an extra API call to learn the same thing. Captured with
# `2>&1` because gh has moved this report between stdout and stderr across
# versions, and bounded by run_timeout — the bare `gh auth status` calls it
# replaces were the section's only unbounded network probes.
GH_AUTH_FILE="${TMPDIR_STATUS}/auth.txt"
: >"${GH_AUTH_FILE}"
GH_AUTHED=false
GH_AUTH_TIMEDOUT=false
# Whether the bounded probe below actually ran. The credentials group reports the
# validated answer when it did and falls back to a network-free local read when it
# did not — see render_local_credentials. A flag rather than "is GH_AUTH_FILE
# empty", because a failed probe legitimately leaves that file empty too.
GH_AUTH_PROBED=false
# The setup section needs this too — it reports the same credential's ability to
# read the board, and used to run its own `gh auth status` to decide whether to
# render at all. One probe, two consumers.
#
# Deliberately NOT extended to `SECTION == creds`: that section's gh line is a
# LOCAL read (see render_local_credentials), and turning it into the full
# validating probe would change what that line is entitled to claim. The scope
# check issue #827 asks for is added there as its own narrowly-scoped call
# instead — see render_gh_scope_check.
if should_show "gh" || [[ "${SECTION}" == "setup" ]]; then
    GH_AUTH_PROBED=true
    gh_auth_rc=0
    # `gh auth status` reports every account on every host, and the scope line
    # read below cannot tell them apart — so narrow it to one credential from
    # both directions: --active (not a second, inactive account on this host)
    # and --hostname (not an unrelated host's account, whose scopes say nothing
    # about the API calls this repo makes). The host comes from the repository,
    # not a github.com assumption — see gh_target_host.
    gh_host="$(gh_target_host)"
    run_timeout "${NETWORK_TIMEOUT}" gh auth status --active \
        --hostname "${gh_host}" >"${GH_AUTH_FILE}" 2>&1 ||
        gh_auth_rc=$?
    if grep -qi 'unknown flag' "${GH_AUTH_FILE}" 2>/dev/null; then
        # gh predates --active (added in 2.40). Fall back rather than read a
        # usage error as a failed login — and keep --hostname, which is far
        # older. Multi-account per host arrived WITH 2.40, so on a gh this old
        # one host means one account and the narrowing is complete anyway.
        gh_auth_rc=0
        run_timeout "${NETWORK_TIMEOUT}" gh auth status \
            --hostname "${gh_host}" >"${GH_AUTH_FILE}" 2>&1 ||
            gh_auth_rc=$?
    fi
    # 124 is `timeout`'s own "deadline hit" code, and 137 the same deadline
    # reached through run_timeout's `-k` hard kill. Both are distinguished from
    # a real failure because bounding this probe made a slow network
    # indistinguishable from a missing login, and reporting "not authenticated"
    # for a timeout sends the reader to fix the wrong thing.
    #
    # 137 is not proof the deadline fired: `timeout` also returns it for a probe
    # killed by anything else (OOM, an operator, a supervisor). Both roads lead
    # to the same verdict — UNKNOWN, never "logged out" — so they share a branch,
    # and only the wording below stays agnostic about which one it was.
    case "${gh_auth_rc}" in
    0) GH_AUTHED=true ;;
    124 | 137) GH_AUTH_TIMEDOUT=true ;;
    esac
fi

# The token's scope line, and how to give THIS credential more access. The
# remedy names the credential SOURCE, never a particular scope: the call sites
# already say which requirement is unmet, and a remedy that hardcoded "Projects"
# mis-instructed a reader whose missing scope was `workflow` — or one of a
# consumer's own GH_REQUIRED_SCOPES additions.
# Derived once, because every call site below would otherwise guess — and a
# remedy that cannot work is worse than none. `gh auth refresh` edits only the
# STORED classic credential: it cannot touch an env-provided token (which
# overrides the stored one, on github.com and Enterprise alike) and cannot add a
# fine-grained or App token's permissions, which are not OAuth scopes at all.
GH_SCOPES_LINE=""
# The stored-credential remedy names the TASK rather than a raw command: the
# task refuses against an env token and without a TTY, and verifies the grant
# actually landed, which a pasted `gh auth refresh` does none of (issue #596).
# The raw command rides along for a reader who is not in a checkout yet, and is
# derived from the same required-scope list — the two divergent remedy strings
# #596 reported were exactly this string drifting from the skills' hint.
GH_REMEDY_DEFAULT="run: task setup:gh-scopes (or: gh auth refresh -s $(gh_scopes_request_list))"
GH_REMEDY="${GH_REMEDY_DEFAULT}"

# derive_gh_scope_state FILE — set GH_SCOPES_LINE and GH_REMEDY from a captured
# `gh auth status` report. A function rather than a straight-line block because
# there are two probes that can produce one: the shared one below, and the
# credentials section's own narrow one (render_gh_scope_check). Deriving it
# twice by hand is how the two remedy strings issue #596 reported came to exist.
derive_gh_scope_state() {
    local file="$1"
    GH_SCOPES_LINE=""
    GH_REMEDY="${GH_REMEDY_DEFAULT}"
    [[ -s "${file}" ]] || return 0
    GH_SCOPES_LINE="$(grep -i 'token scopes:' "${file}" 2>/dev/null || true)"
    case "$(<"${file}")" in
    *"(GH_TOKEN)"*)
        GH_REMEDY="reissue GH_TOKEN with the missing scopes — an env token overrides gh auth refresh"
        ;;
    *"(GITHUB_TOKEN)"*)
        GH_REMEDY="reissue GITHUB_TOKEN with the missing scopes — an env token overrides gh auth refresh"
        ;;
    *"(GH_ENTERPRISE_TOKEN)"*)
        GH_REMEDY="reissue GH_ENTERPRISE_TOKEN with the missing scopes — an env token overrides gh auth refresh"
        ;;
    *"(GITHUB_ENTERPRISE_TOKEN)"*)
        GH_REMEDY="reissue GITHUB_ENTERPRISE_TOKEN with the missing scopes — an env token overrides gh auth refresh"
        ;;
    *)
        # Not an env token. A scope line with no scopes in it is a fine-grained
        # PAT or an App installation token — a permission, granted at the source.
        if [[ -n "${GH_SCOPES_LINE}" && "${GH_SCOPES_LINE}" != *"'"* ]]; then
            GH_REMEDY="grant the matching permission where the token was issued"
        fi
        ;;
    esac
}

derive_gh_scope_state "${GH_AUTH_FILE}"

# `should_show "gh"` as well as the auth flag: the auth probe above now also runs
# for the setup section, and these two lists are read only by the GitHub section.
# Without the guard, `task status:setup` would spend two network calls fetching
# data nothing displays.
if [[ "${GH_AUTHED}" == true ]] && should_show "gh"; then
    run_timeout "${NETWORK_TIMEOUT}" gh pr list --limit 10 \
        --json number,title,headRefName \
        >"${TMPDIR_STATUS}/prs.json" 2>/dev/null &
    PID_PRS=$!

    run_timeout "${NETWORK_TIMEOUT}" gh run list --branch "${CURRENT_BRANCH}" \
        --limit 5 --json status,conclusion,name,createdAt \
        >"${TMPDIR_STATUS}/checks.json" 2>/dev/null &
    PID_CHECKS=$!
fi

if should_show "code" && command -v tokei &>/dev/null; then
    tokei --output json "${REPO_ROOT}" >"${TMPDIR_STATUS}/tokei.json" 2>/dev/null &
    PID_TOKEI=$!
fi

# Wait for background jobs
for pid in $PID_PRS $PID_CHECKS $PID_TOKEI; do
    wait "$pid" 2>/dev/null || true
done

# Ensure files exist for later reads
for f in prs.json checks.json tokei.json; do
    [[ -f "${TMPDIR_STATUS}/${f}" ]] || echo "[]" >"${TMPDIR_STATUS}/${f}"
done

# ── Header ──────────────────────────────────────────────────────────────────

if [[ -z "${SECTION}" ]]; then
    if $HAS_GUM; then
        gum_style --bold --foreground 212 --border double \
            --border-foreground 99 --padding "0 2" --margin "1 0" \
            -- "${PROJECT_NAME}"
    else
        echo ""
        echo "=== ${PROJECT_NAME} ==="
        echo ""
    fi
fi

# ── Git Status ──────────────────────────────────────────────────────────────

if should_show "git"; then
    section_header "Git Status"

    last_commit="$(git log -1 --format='%h %s (%cr)' 2>/dev/null || echo "no commits")"
    dirty="$(git status --porcelain 2>/dev/null)"
    if [[ -z "$dirty" ]]; then
        status_text="clean"
    else
        changed="$(echo "$dirty" | wc -l | tr -d ' ')"
        status_text="dirty (${changed} files)"
    fi

    tag="$(git describe --tags --abbrev=0 --exclude="*-probe*" 2>/dev/null || echo "none")"

    {
        kv "Branch" "$CURRENT_BRANCH"
        kv "Status" "$status_text"
        kv "Tag" "$tag"
        kv "Last commit" "$last_commit"
        echo ""
        echo "  Recent commits:"
        git log --oneline -5 --format='    %C(yellow)%h%Creset %s %C(dim)(%cr)%Creset' \
            --color=always 2>/dev/null || echo "    (no commits)"
    } | section_box
fi

# ── GitHub Status ───────────────────────────────────────────────────────────

if should_show "gh"; then
    section_header "GitHub Status"

    if [[ "${GH_AUTH_TIMEDOUT}" == true ]]; then
        echo "  (gh auth status timed out after ${NETWORK_TIMEOUT}s, or was killed -- skipping)" | section_box
    elif [[ "${GH_AUTHED}" != true ]]; then
        echo "  (gh not authenticated -- skipping)" | section_box
    else
        {
            pr_file="${TMPDIR_STATUS}/prs.json"
            pr_count="$(jq 'length' "$pr_file" 2>/dev/null || echo "0")"
            if [[ "$pr_count" -gt 0 ]]; then
                echo "  Open PRs:"
                jq -r '.[] | "    #\(.number) \(.title) (\(.headRefName))"' "$pr_file"
            else
                echo "  Open PRs: none"
            fi

            echo ""

            checks_file="${TMPDIR_STATUS}/checks.json"
            checks_count="$(jq 'length' "$checks_file" 2>/dev/null || echo "0")"
            if [[ "$checks_count" -gt 0 ]]; then
                echo "  Recent CI runs (${CURRENT_BRANCH}):"
                jq -r '.[] |
                    (if .conclusion == "success" then "pass"
                     elif .conclusion == "failure" then "FAIL"
                     elif .status == "in_progress" then " run"
                     else " -- " end) as $icon |
                    "    \($icon)  \(.name)  (\(.createdAt | split("T")[0]))"' \
                    "$checks_file"
            else
                echo "  Recent CI runs: none"
            fi

            # ── Board writes ────────────────────────────────────────────────
            # The claim lifecycle moves an issue's project `Status` (a claim
            # sets In Progress, the PR stages advance it, the hand-back
            # restores it), and that write needs a token scope `gh auth login`
            # does not grant by default. Without it every board write exits 2
            # ("could not verify") and no card moves — and each step handles
            # that correctly on its own, so nothing escalates: the agent
            # reports the issue claimed, the board says nothing was started,
            # and neither is wrong from where it stands.
            #
            # `status:setup` has always checked this. It is repeated here
            # because this section is what session-start orientation runs, and
            # a tracking surface that has silently stopped tracking has to
            # surface BEFORE a claim is made, not after a human notices the
            # board is stale. The cost is nil: the scopes come from the auth
            # probe above, not a second call.
            #
            # Reported in both directions on purpose. A check that prints only
            # on failure is indistinguishable from a check that is not running
            # — which is the very bug this one exists to catch.
            # Gated on the board tooling itself, NOT on the presence of the
            # track-work skill: `project_management: none` is the default and
            # `use_skills_sync` is on, so the universal skill set (track-work
            # included) is vendored into repos that have no board at all.
            # Keying on the skill would demand the `project` scope from every
            # one of them. setup-github-project.sh is generated only for
            # `project_management: github`, which makes it a proxy for "this
            # repo is configured to have a board".
            #
            # The accepted cost, deliberately chosen: a repo on
            # `project_management: none` whose issues someone adds to a board by
            # hand gets no session-start warning, and learns from the claim's own
            # exit 2 instead. Nothing on disk can distinguish that repo from one
            # that simply opted out — board membership is remote state — so the
            # gate can only pick which error to make. A red line in every
            # opted-out repo, every session, is the worse one: it is universal
            # rather than conditional, and a check that cries wolf everywhere
            # stops being read where it matters.
            if [[ -f scripts/setup-github-project.sh ]]; then
                echo ""
                if [[ -z "${GH_SCOPES_LINE}" ]]; then
                    checkline unknown "Project board writes" \
                        "could not read token scopes from gh auth status"
                elif [[ "${GH_SCOPES_LINE}" != *"'"* ]]; then
                    # A fine-grained PAT or App token carries permissions, not
                    # OAuth scopes, and gh reports the line with no scopes in
                    # it. Such a token may well be able to write Projects — so
                    # this is genuinely unknown rather than a failure. The
                    # generated bot credential is exactly this case.
                    checkline unknown "Project board writes" \
                        "no OAuth scopes reported (fine-grained or App token) — ${GH_REMEDY}"
                elif has_scope "${GH_SCOPES_LINE}" project; then
                    checkline ok "Project board writes" "token has 'project'"
                elif has_scope "${GH_SCOPES_LINE}" read:project; then
                    # Called out separately because it is the state most easily
                    # mistaken for working: `--show` reads the card fine, so the
                    # board looks reachable right up to the write that moves it.
                    checkline no "Project board writes" \
                        "'read:project' is read-only — claims cannot move the board; ${GH_REMEDY}"
                else
                    checkline no "Project board writes" \
                        "token lacks 'project' — claims cannot move the board; ${GH_REMEDY}"
                fi
            fi
        } | section_box
    fi
fi

# ── Codebase Stats ──────────────────────────────────────────────────────────

if should_show "code"; then
    section_header "Codebase Stats"

    tokei_file="${TMPDIR_STATUS}/tokei.json"
    if [[ -s "$tokei_file" ]] && jq -e 'keys | length > 1' "$tokei_file" &>/dev/null; then
        {
            echo "  Languages (by lines of code):"
            jq -r '
                to_entries
                | map(select(.key != "Total"))
                | sort_by(-.value.code)
                | .[:10]
                | .[]
                | "    \(.key): \(.value.code) code, \(.value.comments) comments"
            ' "$tokei_file" 2>/dev/null || echo "    (parse error)"

            echo ""

            total_code="$(jq '[to_entries[] | select(.key != "Total") | .value.code] | add // 0' "$tokei_file" 2>/dev/null || echo "?")"
            total_files="$(jq '[to_entries[] | select(.key != "Total") | .value.reports | length] | add // 0' "$tokei_file" 2>/dev/null || echo "?")"
            kv "Total code lines" "$total_code"
            kv "Total files" "$total_files"
        } | section_box
    elif command -v tokei &>/dev/null; then
        tokei "${REPO_ROOT}" --compact 2>/dev/null | section_box
    else
        echo "  (tokei not installed)" | section_box
    fi
fi

# ── Site Overview ───────────────────────────────────────────────────────────
# Shown only for Astro sites, detected at runtime (src/pages/) so this generic
# status script needs no per-project-type templating.

if should_show "site" && [[ -d src/pages ]]; then
    section_header "Site Overview"
    {
        page_count="$(find src/pages -name '*.astro' 2>/dev/null | wc -l | tr -d ' ')"
        kv "Pages (src/pages/*.astro)" "${page_count}"
        if [[ -d dist ]]; then
            html_count="$(find dist -name '*.html' 2>/dev/null | wc -l | tr -d ' ')"
            dist_size="$(du -sh dist 2>/dev/null | cut -f1)"
            kv "Built pages (dist/*.html)" "${html_count}"
            kv "Build output size" "${dist_size}"
        else
            echo "  (no dist/ yet — run 'task build' for build stats)"
        fi
    } | section_box
fi

# ── Environment ─────────────────────────────────────────────────────────────

if should_show "env"; then
    section_header "Environment"

    {
        python_ver="$(python3 --version 2>/dev/null | awk '{print $2}' || echo "not installed")"
        node_ver="$(node --version 2>/dev/null || echo "not installed")"
        docker_ver="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',' || echo "not installed")"
        task_ver="$(task --version 2>/dev/null | awk '{print $NF}' || echo "not installed")"

        kv "Python" "$python_ver"
        kv "Node.js" "$node_ver"
        kv "Docker" "$docker_ver"
        kv "Task" "$task_ver"

        echo ""

        if [[ -n "${REMOTE_CONTAINERS:-}" ]] || [[ -n "${CODESPACES:-}" ]] || [[ -n "${REMOTE_CONTAINERS_IPC:-}" ]]; then
            kv "Devcontainer" "active (VS Code)"
        elif [[ "${CODER:-}" == "true" ]]; then
            kv "Devcontainer" "active (Coder)"
        else
            kv "Devcontainer" "not detected"
        fi

        # Image staleness — silent unless this container's image-baked config
        # has drifted from the checkout's .devcontainer/config/. It belongs on
        # the board rather than only in the post-start log because the log is
        # not somewhere a human looks; the symptom (an old prompt, a retired
        # statusline) is what they see, and this is the line that explains it.
        # The helper is the single implementation — `task status:image` and
        # post-start run this same script — and it always exits 0.
        if [ -r .devcontainer/scripts/check-image-staleness.sh ]; then
            bash .devcontainer/scripts/check-image-staleness.sh || true
        fi
    } | section_box
fi

# ── Local credentials ───────────────────────────────────────────────────────
# The logins the Dev Loop gates on, read from LOCAL state only — no API call and
# no network — so this renders in any auth state and costs nothing.
#
# It is a section of its own AND a group inside the setup audit, from this one
# function so the probes are written once. Two callers, two reasons:
#
#   * `task status:creds` — the session-start hook runs it alongside status:git
#     and status:gh, so a missing login is reported when a session opens rather
#     than only on the explicit `task status:setup` a distracted session skips.
#     That is the whole point: the audit it used to live in is network-heavy and
#     excluded from the default board, while these probes are not.
#   * `task status:setup` — rendered BEFORE the gh gate there rather than inside
#     it. That gate skips the ENTIRE remaining audit when gh is logged out, so a
#     credentials group living there would surface a missing codex login only
#     after the reader had fixed gh and re-run: two round trips to learn what one
#     run can say, which is the interruption this group exists to remove.
#
# `should_show` also puts it on the bare `task status` board, alongside every
# other local section. The setup audit stays off that board because it is
# network-heavy; this group is not, so the reason to exclude it does not apply.
#
# Every probe here is bounded by the short LOCAL bound (3s), never by
# NETWORK_TIMEOUT — the session-start path must not inherit a cost its budget
# was not derived for.
#
# ONE of them reaches the network: the gh token's SCOPES (render_gh_scope_check
# below). That is not a local fact — no file on disk records it — and issue
# #827 needs it at session start, so the section spends exactly one bounded 3s
# call for it and nothing else. It is capped at the LOCAL bound rather than
# NETWORK_TIMEOUT for the same budget reason as everything else here: the hook
# budgets this section from the sum of these bounds (13s, both hook copies),
# and a section that overruns loses ALL of its buffered output. Set
# `STATUS_NO_NETWORK=1` to drop that one probe and make the section local-only
# again. Anything else added here must stay local.
# render_gh_scope_check — one ⚠/unknown line when the authenticated token is
# missing a scope this repo's tooling needs, and NOTHING when it has them all.
#
# Silent-on-success is a deliberate exception to this script's usual
# report-both-directions rule (issue #827's acceptance criterion). The rule
# exists so a check that never runs cannot masquerade as a passing one — and
# here the caller has already printed a ✓ line for the same credential from the
# same probe, so the evidence that this ran is on screen either way. A second
# green line on every session start, in every repo, would be pure noise.
#
# Read-only and non-fatal. It compares the scope line the shared probe already
# captured where there is one; standalone (`status:creds`) it makes the single
# bounded probe described above.
render_gh_scope_check() {
    local missing rc=0 file
    if [[ "${GH_AUTH_PROBED}" != true ]]; then
        # Standalone `task status:creds` — the session-start path, and the one
        # #827 is about. Scopes are a SERVER-side property of the token: no
        # local file records them, so the one fact this check needs cannot be
        # had without asking. The rest of the section stays local-only; this is
        # a single bounded, read-only, non-fatal call, and
        # `STATUS_NO_NETWORK=1` removes even that for offline shells.
        if [[ "${STATUS_NO_NETWORK:-}" == 1 ]]; then
            return 0
        fi
        file="${TMPDIR_STATUS}/auth-creds.txt"
        : >"${file}"
        # ONE call, bounded at the section's short local bound rather than
        # NETWORK_TIMEOUT. Not because it is local — it is not — but because
        # the session-start hook budgets this section from the sum of its
        # probes, and a section that overruns loses ALL of its output
        # (status.sh buffers before printing). A scope warning that costs the
        # reader their credential lines is worse than no scope warning. For
        # the same reason there is no `--active`-unsupported retry here: on a
        # gh older than 2.40 the check simply does not run.
        run_timeout 3 gh auth status --active \
            --hostname "$(gh_target_host)" >"${file}" 2>&1 || rc=$?
        if [[ "${rc}" -ne 0 ]] || grep -qi 'unknown flag' "${file}" 2>/dev/null; then
            # A failed probe is NOT a missing login (issues #774, #478) and is
            # not a missing scope either — say nothing rather than send a
            # correctly-scoped operator to re-mint a working credential. The
            # gh line above has already reported the credential itself.
            return 0
        fi
        derive_gh_scope_state "${file}"
    fi
    if [[ -z "${GH_SCOPES_LINE}" ]]; then
        # The probe ran and authenticated, but reported no scope line — an
        # older gh, or an output change. Unknown, never "missing": telling
        # someone to re-mint a working credential is the worse error.
        checkline unknown "gh token scopes" \
            "could not read token scopes from gh auth status"
        return
    fi
    if [[ "${GH_SCOPES_LINE}" != *"'"* ]]; then
        # A fine-grained PAT or an App installation token: permissions, not
        # OAuth scopes. gh reports the line with nothing quoted in it. Such a
        # token may well carry everything needed, so this is unknown — and the
        # bot profile's credential is exactly this case, which is why the
        # remedy here never says "log in" (see GH_REMEDY).
        checkline unknown "gh token scopes" \
            "no OAuth scopes reported (fine-grained or App token) — ${GH_REMEDY}"
        return
    fi
    missing="$(gh_scopes_missing "${GH_SCOPES_LINE}")"
    if [[ -n "${missing}" ]]; then
        checkline no "gh token scopes" \
            "missing $(gh_scopes_human "${missing}") — ${GH_REMEDY}"
    fi
}

render_local_credentials() {
    # Not-installed is tested FIRST because it makes every other branch
    # meaningless: with no gh on PATH the shared probe above exits 127, which
    # lands in the same "not authenticated" bucket as a real logout and would
    # prescribe `gh auth login` — a command the reader does not have. Same
    # distinction the Codex check below draws, and the same remedy style as the
    # 1Password and direnv lines further down.
    if ! command -v gh >/dev/null 2>&1; then
        checkline no "GitHub CLI (gh)" "brew install gh"
    elif [[ "${GH_AUTH_PROBED}" == true ]]; then
        # Reuses the single bounded probe from the top of this script instead of
        # calling `gh auth status` again, and inherits its distinction between a
        # deadline and a missing login — telling an authenticated reader to run
        # `gh auth login` because GitHub was slow sends them to fix the wrong
        # thing. The setup section's skip line stays as it is: it explains the
        # absence of everything after it, which this line does not.
        if [[ "${GH_AUTH_TIMEDOUT}" == true ]]; then
            checkline unknown "GitHub CLI (gh)" \
                "auth probe timed out after ${NETWORK_TIMEOUT}s, or was killed"
        elif [[ "${GH_AUTHED}" == true ]]; then
            checkline ok "GitHub CLI (gh)" "authenticated to $(gh_target_host)"
            render_gh_scope_check
        else
            checkline no "GitHub CLI (gh)" "gh auth login"
        fi
    else
        # Standalone `status:creds`: nothing probed the API, and this section is
        # not allowed to. `gh auth token` resolves the credential gh would use
        # from local config and the environment WITHOUT calling GitHub, which
        # answers the only question this line exists to answer — is there a login
        # at all. Its validity is `status:gh`'s to report, and the wording below
        # says so rather than claiming an authentication that was never checked.
        #
        # `2>&1 >/dev/null` — in that order — captures STDERR while sending
        # stdout to /dev/null. The order is load-bearing and not interchangeable
        # with `>/dev/null 2>&1`: this command's stdout IS the token, so the
        # value must never enter a variable, and only its diagnostic goes into
        # one. Nothing captured here is ever printed either way.
        #
        # Non-zero is then classified rather than assumed to mean logged out,
        # the same distinction the Codex probe below draws: a locked keychain or
        # an unreadable hosts.yml also exits non-zero, and `gh auth login` cannot
        # repair either. Only gh's documented no-credential wording earns that
        # remedy; everything else is unknown.
        gh_token_rc=0
        gh_token_err="$(run_timeout 3 gh auth token \
            --hostname "$(gh_target_host)" 2>&1 >/dev/null)" || gh_token_rc=$?
        case "${gh_token_rc}" in
        0)
            checkline ok "GitHub CLI (gh)" \
                "credential stored for $(gh_target_host) (not validated)"
            # Only once a credential is known to exist: asking GitHub about the
            # scopes of a token that is not there would spend a round trip to
            # learn what the line above already said.
            render_gh_scope_check
            ;;
        124 | 137) checkline unknown "GitHub CLI (gh)" "credential probe timed out or was killed" ;;
        *)
            case "$(printf '%s' "${gh_token_err}" | tr '[:upper:]' '[:lower:]')" in
            *"no oauth token"* | *"not logged in"*)
                checkline no "GitHub CLI (gh)" "gh auth login"
                ;;
            *)
                checkline unknown "GitHub CLI (gh)" \
                    "credential probe failed (exit ${gh_token_rc}) — check the gh CLI's config"
                ;;
            esac
            ;;
        esac
    fi

    # Codex gates `task challenge` and `task review` only where the repo opted
    # into second-model review, and scripts/codex-review.sh is that opt-in's
    # marker on disk — the template renders it only under `use_codex_review`.
    # Same each-script-is-its-own-marker rule the GitHub configuration checks
    # below use, and read off the filesystem rather than .copier-answers.yml:
    # nothing else in this script reads that file, and a generated repo may keep
    # it somewhere else. `codex login status` reads local credential state, so
    # the bound here is the short local one (as with `op account list`), never
    # NETWORK_TIMEOUT.
    if [ -f scripts/codex-review.sh ]; then
        if command -v codex >/dev/null 2>&1; then
            # The exit code is the primary signal, but it cannot tell "no
            # credentials" from "the CLI could not run": a malformed config.toml
            # also exits non-zero, and `codex login` cannot repair that. So keep
            # the documented logged-out phrase as the only thing that earns the
            # login remedy, and report every other failure as unknown rather than
            # sending the reader to re-authenticate a session that was never the
            # problem.
            #
            # Captured with 2>&1 because the shipped CLI writes BOTH verdicts to
            # stderr and leaves stdout empty — reading stdout alone would silently
            # demote every genuine logout to "unknown". Folding the streams also
            # picks up unrelated stderr chatter (a models-cache ERROR line appears
            # on some installs while the command still exits 0), which is exactly
            # why the match is on the phrase and the verdict on the exit code,
            # never on stderr being non-empty. The captured text is only ever
            # matched, never printed.
            codex_rc=0
            codex_out="$(run_timeout 3 codex login status 2>&1)" || codex_rc=$?
            case "${codex_rc}" in
            0) checkline ok "Codex CLI" "logged in" ;;
            124 | 137) checkline unknown "Codex CLI" "login status timed out or was killed" ;;
            *)
                case "${codex_out}" in
                *"Not logged in"*) checkline no "Codex CLI" "codex login" ;;
                *) checkline unknown "Codex CLI" \
                    "login status failed (exit ${codex_rc}) — check the codex CLI's config" ;;
                esac
                ;;
            esac
        else
            checkline no "Codex CLI" \
                "brew install --cask codex, or npm install -g @openai/codex"
        fi
    else
        checkline na "Codex CLI" "no second-model review configured"
    fi

    # Claude Code is the agent this repo's Dev Loop is written for, and a logged
    # out CLI stops it at the first `claude` invocation. `claude auth status
    # --json` reads STORED credential state: it answers identically with every
    # egress pointed at a dead port, so it belongs in this group rather than
    # behind NETWORK_TIMEOUT.
    #
    # Not-installed reads n/a rather than missing, which is the one place this
    # group departs from the gh and Codex lines above. Those two have a marker on
    # disk for "this repo expects it" — codex-review.sh is rendered only under
    # `use_codex_review`, and gh backs the whole GitHub half of the template.
    # There is no equivalent marker here: the template ships .claude/ to every
    # repo whether or not its author drives it with Claude Code, so an absent CLI
    # cannot be distinguished from a deliberate choice of a different agent, and
    # a red ✗ prescribing an install to somebody who chose Codex is noise they
    # cannot act on.
    if ! command -v claude >/dev/null 2>&1; then
        checkline na "Claude Code CLI" "claude CLI not installed"
    else
        # The verdict is the `loggedIn` field, not the exit code: a logged-out
        # CLI is a normal, successful report, and a `claude` too old for
        # `auth status` exits non-zero with no field at all — which is unknown,
        # not logged out. Whitespace is stripped so the match survives either
        # JSON formatting, and stderr is discarded because only the field is
        # read. The captured text is only ever matched, never printed.
        claude_rc=0
        claude_out="$(run_timeout 3 claude auth status --json 2>/dev/null)" ||
            claude_rc=$?
        case "$(printf '%s' "${claude_out}" | tr -d ' \n\t')" in
        *'"loggedIn":true'*) checkline ok "Claude Code CLI" "logged in" ;;
        *'"loggedIn":false'*) checkline no "Claude Code CLI" "claude auth login" ;;
        *)
            case "${claude_rc}" in
            124 | 137) checkline unknown "Claude Code CLI" "auth status timed out or was killed" ;;
            *) checkline unknown "Claude Code CLI" \
                "auth status reported nothing readable (exit ${claude_rc})" ;;
            esac
            ;;
        esac
    fi

    # Hand this group's tallies to the setup summary (see the caller there).
    # Guarded, and deliberately last: with `pipefail` set, a failed write here
    # would become the whole pipeline's status and `set -e` would take the script
    # down over a status board's bookkeeping.
    printf '%s %s %s %s\n' \
        "${SETUP_OK}" "${SETUP_NO}" "${SETUP_UNKNOWN}" "${SETUP_NA}" \
        >"${TMPDIR_STATUS}/cred-counts" 2>/dev/null || true
}

if should_show "creds"; then
    section_header "Local Credentials"
    render_local_credentials | section_box
fi

# ── Setup Completeness ──────────────────────────────────────────────────────
# Audits the repo against docs/CHECKLIST.md — which GitHub-side configuration
# the template expects has actually been applied. Network-heavy, so it is NOT
# part of the default dashboard; run it explicitly via `task status:setup`.
#
# Each check is feature-detected from local files (so this same script works in
# any generated repo) and reports one of: ✓ done · ✗ missing · ? unknown ·
# – not applicable.

if [[ "${SECTION}" == "setup" ]]; then
    section_header "Setup Completeness"

    # Checklist progress — parse the repo's docs/CHECKLIST.md task boxes and show
    # how many are ticked as a colorful bar. Pure local file parsing (no network),
    # so it renders even when gh is unauthenticated.
    {
        cl="docs/CHECKLIST.md"
        if [ -f "${cl}" ]; then
            cl_total="$(grep -cE '^[[:space:]]*- \[[ xX]\]' "${cl}" 2>/dev/null || true)"
            cl_done="$(grep -cE '^[[:space:]]*- \[[xX]\]' "${cl}" 2>/dev/null || true)"
            cl_total="${cl_total:-0}"
            cl_done="${cl_done:-0}"
            cl_pct=0
            [ "${cl_total}" -gt 0 ] && cl_pct=$((cl_done * 100 / cl_total))
            printf '  %s  %s  %s\n' "$(bar "${cl_pct}")" \
                "$(c '1' "${cl_pct}%")" "$(c '2' "(${cl_done}/${cl_total} checked)")"
            kv "Checklist" "${cl}"
        else
            printf '  %s\n' "$(c '2' "no docs/CHECKLIST.md to parse")"
        fi
    } | section_box

    # Rendered here as a group inside the audit (see render_local_credentials
    # above for why it is also its own section, and why it sits BEFORE the gh
    # gate below).
    #
    # Its own { } group means its own copy of the SETUP_* counters: checkline
    # mutates them inside the subshell that `| section_box` creates, so they
    # cannot reach the summary at the end of this section through a variable.
    # They are handed across that boundary in a file instead (written at the end
    # of the group, folded in at the summary), the same way the fan-out phase
    # below returns its results. The plumbing is worth it — a summary reading
    # "100% · 0 missing" directly under a red ✗ Codex CLI line on the same screen
    # is a worse defect than the file is.
    {
        subhead "Local credentials"
        render_local_credentials
    } | section_box

    # Reuses the single bounded probe above rather than making a second,
    # unbounded `gh auth status` call to learn the same thing. Sharing that probe
    # means sharing its distinctions too: bounding it made a slow network look
    # exactly like a missing login, and telling an authenticated user to run
    # `gh auth login` because GitHub was slow sends them to fix the wrong thing.
    if [[ "${GH_AUTH_TIMEDOUT}" == true ]]; then
        echo "  (gh auth status timed out after ${NETWORK_TIMEOUT}s, or was killed -- skipping)" | section_box
    elif [[ "${GH_AUTHED}" != true ]]; then
        echo "  (gh not authenticated -- run 'gh auth login')" | section_box
    else
        d="${TMPDIR_STATUS}"

        # Repo identity — every API call below needs owner/repo, so resolve it
        # synchronously first.
        run_timeout "${NETWORK_TIMEOUT}" gh repo view \
            --json nameWithOwner,visibility,isPrivate,defaultBranchRef \
            >"${d}/repo.json" 2>/dev/null || echo '{}' >"${d}/repo.json"

        NWO="$(jq -r '.nameWithOwner // empty' "${d}/repo.json")"

        HAS_REMOTE=true
        [ -z "${NWO}" ] && HAS_REMOTE=false

        # Toolchain audit (brew) — slow JSON-API call; fire it in the background
        # so it overlaps the GitHub lookups. Needs no remote.
        if [ -f Brewfile ] && command -v brew >/dev/null 2>&1; then
            (brew bundle check --file=Brewfile >/dev/null 2>&1 &&
                echo ok >"${d}/brew" || echo no >"${d}/brew") &
        elif [ -f Brewfile ]; then
            echo unknown >"${d}/brew"
        else
            echo na >"${d}/brew"
        fi

        if ${HAS_REMOTE}; then
            OWNER="${NWO%%/*}"
            REPO="${NWO##*/}"
            VISIBILITY="$(jq -r '.visibility // "?"' "${d}/repo.json" | tr '[:upper:]' '[:lower:]')"
            IS_PRIVATE="$(jq -r '.isPrivate // false' "${d}/repo.json")"
            DEFAULT_BRANCH="$(jq -r '.defaultBranchRef.name // "?"' "${d}/repo.json")"
            OWNER_TYPE="$(run_timeout "${NETWORK_TIMEOUT}" gh api "repos/${OWNER}/${REPO}" \
                --jq '.owner.type' 2>/dev/null || echo "User")"
            if [[ "${OWNER_TYPE}" == "Organization" ]]; then
                PKG_NS="orgs"
                APPS_PATH="orgs/${OWNER}/installations"
            else
                PKG_NS="users"
                APPS_PATH="user/installations"
            fi

            # ── Fire independent lookups in parallel ──
            (run_timeout "${NETWORK_TIMEOUT}" gh api "repos/${OWNER}/${REPO}/rulesets" \
                >"${d}/rulesets.json" 2>/dev/null || echo '[]' >"${d}/rulesets.json") &
            (run_timeout "${NETWORK_TIMEOUT}" gh api "repos/${OWNER}/${REPO}/vulnerability-alerts" \
                >/dev/null 2>&1 && echo yes >"${d}/depalerts" || echo no >"${d}/depalerts") &
            (run_timeout "${NETWORK_TIMEOUT}" gh api "repos/${OWNER}/${REPO}/private-vulnerability-reporting" \
                >"${d}/pvr.json" 2>/dev/null || echo '{}' >"${d}/pvr.json") &
            # --json name fetches ONLY names, never secret/variable values.
            (run_timeout "${NETWORK_TIMEOUT}" gh secret list --json name \
                >"${d}/secrets.json" 2>/dev/null || echo '[]' >"${d}/secrets.json") &
            (run_timeout "${NETWORK_TIMEOUT}" gh variable list --json name \
                >"${d}/vars.json" 2>/dev/null || echo '[]' >"${d}/vars.json") &
            (run_timeout "${NETWORK_TIMEOUT}" gh release list --limit 1 >"${d}/release.txt" 2>/dev/null || :) &
            # shellcheck disable=SC2016 # $o/$r are GraphQL variables, not shell
            (run_timeout "${NETWORK_TIMEOUT}" gh api graphql \
                -f query='query($o:String!,$r:String!){repository(owner:$o,name:$r){projectsV2(first:10){nodes{title number}}}}' \
                -F o="${OWNER}" -F r="${REPO}" \
                >"${d}/projects.json" 2>/dev/null || echo '{}' >"${d}/projects.json") &
            # PM setup surface — audit the results of the setup:github-* tasks the
            # repo actually ships (each script is the marker it opted in).
            if [ -f scripts/setup-github-labels.sh ]; then
                # The REST endpoint with --paginate, not `gh label list`: the
                # check below compares against the WHOLE starter set, so any
                # fixed page cap (gh's default 30, or any --limit) can drop a
                # real label on a label-heavy repo and report it as missing.
                # One name per line — --paginate emits a document per page.
                (run_timeout "${NETWORK_TIMEOUT}" gh api "repos/${OWNER}/${REPO}/labels" --paginate --jq '.[].name' \
                    >"${d}/labels.txt" 2>/dev/null || : >"${d}/labels.txt") &
            fi
            if [ -f scripts/setup-github-issue-types.sh ]; then
                (run_timeout "${NETWORK_TIMEOUT}" gh api "orgs/${OWNER}/issue-types" --paginate \
                    >"${d}/issue-types.json" 2>/dev/null || echo 'null' >"${d}/issue-types.json") &
            fi
            if [ -f scripts/setup-github-issue-fields.sh ]; then
                (run_timeout "${NETWORK_TIMEOUT}" gh api "orgs/${OWNER}/issue-fields" \
                    -H "X-GitHub-Api-Version: 2026-03-10" --paginate \
                    >"${d}/issue-fields.json" 2>/dev/null || echo 'null' >"${d}/issue-fields.json") &
            fi
            # App installs — definitive when we hold admin scope, else 'null'.
            (run_timeout "${NETWORK_TIMEOUT}" gh api "${APPS_PATH}" \
                --jq '[.installations[].app_slug]' \
                >"${d}/apps.json" 2>/dev/null || echo 'null' >"${d}/apps.json") &
            # Heuristic fallback signals for the two apps.
            (run_timeout "${NETWORK_TIMEOUT}" gh pr list --state all --author "app/renovate" \
                --limit 1 --json number >"${d}/renovate-pr.json" 2>/dev/null ||
                echo '[]' >"${d}/renovate-pr.json") &
            (run_timeout "${NETWORK_TIMEOUT}" gh api "repos/${OWNER}/${REPO}/pulls/comments?per_page=100" \
                --jq '[.[].user.login] | map(select(test("coderabbit";"i"))) | length' \
                >"${d}/coderabbit.txt" 2>/dev/null || echo 0 >"${d}/coderabbit.txt") &
            (
                if out="$(run_timeout "${NETWORK_TIMEOUT}" gh api \
                    "/${PKG_NS}/${OWNER}/packages/container/${REPO}-devcontainer" 2>&1)"; then
                    echo yes >"${d}/ghcr"
                elif printf '%s' "${out}" | grep -q '404'; then
                    echo no >"${d}/ghcr"
                else
                    # e.g. token lacks read:packages — don't claim "missing".
                    echo unknown >"${d}/ghcr"
                fi
            ) &
        fi
        wait

        # ── Feature applicability, detected from local files ──
        # Match both .yml and .yaml — extension is each tool's own convention.
        has_claude_wf=0
        find .github/workflows -maxdepth 1 \( -name 'claude-*.yml' -o -name 'claude-*.yaml' \) 2>/dev/null | grep -q . && has_claude_wf=1
        has_release_wf=0
        find .github/workflows -maxdepth 1 \( -name 'release.yml' -o -name 'release.yaml' \) 2>/dev/null | grep -q . && has_release_wf=1
        uses_ci_app=$((has_claude_wf || has_release_wf))
        has_codeql_wf=0
        find .github/workflows -maxdepth 1 \( -name 'codeql.yml' -o -name 'codeql.yaml' \) 2>/dev/null | grep -q . && has_codeql_wf=1
        has_semgrep_ci=0
        grep -rEq 'task[[:space:]]+security:sast([[:space:]]|$)' .github/workflows \
            >/dev/null 2>&1 && has_semgrep_ci=1
        uses_full_scan=0
        grep -rq 'FULL_SECURITY_SCAN' .github/workflows >/dev/null 2>&1 && uses_full_scan=1

        {
            if ${HAS_REMOTE}; then
                checkline info "Repository" "${NWO} (${VISIBILITY}, default: ${DEFAULT_BRANCH})"
            else
                checkline info "Repository" "no GitHub remote — local checks only"
            fi

            # ── Local & hooks ──
            subhead "Local & hooks"
            if grep -rql lefthook .git/hooks 2>/dev/null; then
                checkline ok "Git hooks (lefthook)"
            else
                checkline no "Git hooks (lefthook)" "task install:hooks"
            fi
            if git check-ignore -q .env 2>/dev/null; then
                checkline ok ".env gitignored"
            else
                checkline no ".env gitignored" "add .env to .gitignore"
            fi

            # ── Toolchain ──
            subhead "Toolchain"
            case "$(cat "${d}/brew" 2>/dev/null)" in
            ok) checkline ok "Brewfile deps installed" ;;
            no) checkline no "Brewfile deps installed" "task install" ;;
            unknown) checkline unknown "Brewfile deps installed" "brew not found" ;;
            *) checkline na "Brewfile deps installed" "no Brewfile" ;;
            esac

            # ── Dev environment ──
            subhead "Dev environment"
            if command -v op >/dev/null 2>&1; then
                if [ -n "$(run_timeout 3 op account list 2>/dev/null)" ]; then
                    checkline ok "1Password CLI" "account configured"
                else
                    checkline unknown "1Password CLI" "installed; no account"
                fi
            else
                checkline no "1Password CLI" "brew install 1password-cli"
            fi
            if [ -f .envrc ]; then
                if command -v direnv >/dev/null 2>&1; then
                    checkline ok "direnv (.envrc)"
                else
                    checkline no "direnv (.envrc)" "brew install direnv"
                fi
            else
                checkline na "direnv (.envrc)" "no .envrc"
            fi

            # ── Devcontainer ──
            subhead "Devcontainer"
            if [ -d .devcontainer ]; then
                if [ -f .devcontainer/devcontainer.json ]; then
                    checkline ok "Bot profile (devcontainer.json)"
                else
                    checkline no "Bot profile (devcontainer.json)"
                fi
                if [ -f .devcontainer/dev/devcontainer.json ]; then
                    checkline ok "Dev profile (dev/devcontainer.json)"
                else
                    checkline no "Dev profile (dev/devcontainer.json)"
                fi
                if [ -f .devcontainer/devcontainer.env ]; then
                    checkline ok "Secrets env seeded" "devcontainer.env"
                else
                    checkline no "Secrets env seeded" "1Password Environments mount"
                fi
                if ${HAS_REMOTE}; then
                    case "$(cat "${d}/ghcr" 2>/dev/null)" in
                    yes) checkline ok "GHCR image" "${REPO}-devcontainer" ;;
                    no) checkline no "GHCR image" "built on first merge to main" ;;
                    *) checkline unknown "GHCR image" "needs read:packages scope" ;;
                    esac
                else
                    checkline unknown "GHCR image" "no remote"
                fi
            else
                checkline na "Devcontainer" "not enabled (.devcontainer absent)"
            fi

            if ${HAS_REMOTE}; then
                # ── GitHub configuration ──
                subhead "GitHub configuration"
                if ls .github/*[Rr]uleset*.json >/dev/null 2>&1; then
                    ruleset="$(jq -r '.[].name' "${d}/rulesets.json" 2>/dev/null |
                        grep -i 'protect' | head -1 || true)"
                    if [ -n "${ruleset}" ]; then
                        checkline ok "Branch ruleset" "${ruleset}"
                    else
                        checkline no "Branch ruleset" "import the ruleset JSON in .github/"
                    fi
                else
                    checkline na "Branch ruleset" "no ruleset JSON shipped"
                fi
                if [ "$(cat "${d}/depalerts" 2>/dev/null)" = "yes" ]; then
                    checkline ok "Dependabot alerts"
                else
                    checkline no "Dependabot alerts" "Settings → Advanced Security"
                fi
                if [ "${IS_PRIVATE}" = "true" ]; then
                    if [ "${has_semgrep_ci}" = 1 ] && [ "${has_codeql_wf}" = 1 ]; then
                        checkline ok "SAST route" "Semgrep CE default; paid CodeQL opt-in supported"
                    elif [ "${has_semgrep_ci}" = 1 ]; then
                        checkline ok "SAST route" "Semgrep CE (private)"
                    else
                        checkline no "SAST route" "add Semgrep CE or licensed private CodeQL"
                    fi
                elif [ "${has_codeql_wf}" = 1 ]; then
                    checkline ok "SAST route" "CodeQL (public/free)"
                elif [ "${has_semgrep_ci}" = 1 ]; then
                    checkline ok "SAST route" "Semgrep CE"
                else
                    checkline no "SAST route" "add CodeQL or Semgrep CE"
                fi
                if [ "${IS_PRIVATE}" = "true" ]; then
                    checkline na "Private vuln reporting" "private repo"
                elif [ "$(jq -r '.enabled // false' "${d}/pvr.json")" = "true" ]; then
                    checkline ok "Private vuln reporting"
                else
                    checkline no "Private vuln reporting" "Settings → Advanced Security"
                fi
                if [ -f renovate.json ] || [ -f .github/renovate.json ]; then
                    if grep -qi 'renovate' "${d}/apps.json" 2>/dev/null; then
                        checkline ok "Renovate app" "installed"
                    elif [ "$(jq 'length' "${d}/renovate-pr.json" 2>/dev/null || echo 0)" -gt 0 ]; then
                        checkline ok "Renovate app" "active (PRs seen)"
                    else
                        checkline unknown "Renovate app" "config present; install unconfirmed"
                    fi
                else
                    checkline na "Renovate app" "no renovate.json"
                fi
                if [ -f .coderabbit.yaml ] || [ -f .coderabbit.yml ]; then
                    if grep -qi 'coderabbit' "${d}/apps.json" 2>/dev/null; then
                        checkline ok "CodeRabbit app" "installed"
                    elif [ "$(cat "${d}/coderabbit.txt" 2>/dev/null || echo 0)" -gt 0 ]; then
                        checkline ok "CodeRabbit app" "active (reviews seen)"
                    else
                        checkline unknown "CodeRabbit app" "config present; install unconfirmed"
                    fi
                else
                    checkline unknown "CodeRabbit app access" \
                        "no config; confirm repo is excluded from the App installation"
                fi
                if jq -e '.data.repository' "${d}/projects.json" >/dev/null 2>&1; then
                    proj_count="$(jq -r '(.data.repository.projectsV2.nodes // []) | length' \
                        "${d}/projects.json" 2>/dev/null || echo 0)"
                    if [ "${proj_count:-0}" -gt 0 ]; then
                        proj_title="$(jq -r '.data.repository.projectsV2.nodes[0].title // "?"' \
                            "${d}/projects.json" 2>/dev/null)"
                        checkline ok "GitHub Project linked" "${proj_title}"
                    else
                        checkline no "GitHub Project linked" "link a Project v2 to the repo"
                    fi
                else
                    checkline unknown "GitHub Project linked" \
                        "unreadable — ${GH_REMEDY}"
                fi
                if [ -f scripts/setup-github-labels.sh ]; then
                    # The expected set comes from the label-registry renderer —
                    # the same rendering `task setup:github-labels` provisions
                    # (label-registry.json + the agent families it pulls from
                    # agent-registry.json) — rather than being probed with one
                    # sentinel label: a repo seeded before the set grew (a new
                    # area:/tier: value, say) has the sentinel and is missing
                    # the rest, and a single probe would call that green.
                    # Foreman-gated families are opt-in (--foreman, passed only
                    # when the repo uses foreman — the wrapper taskfile is its
                    # render-time marker), so expect them only there or a
                    # non-foreman repo reports permanently-missing labels.
                    # The WHOLE inventory now comes from the renderer, so
                    # without node or the manifest nothing can be enumerated:
                    # report unknown rather than grading an empty want-list —
                    # or a renderer failure — as complete.
                    if ! command -v node >/dev/null 2>&1; then
                        checkline unknown "Starter labels" "node unavailable — label inventory unchecked"
                    elif [ ! -f label-registry.json ] || [ ! -f scripts/label-registry-render.mjs ]; then
                        checkline unknown "Starter labels" "label-registry.json missing — label inventory unchecked"
                    else
                        foreman_flag=""
                        [ -f taskfiles/foreman.yml ] && foreman_flag="--foreman"
                        [ -f release-please-config.json ] && foreman_flag="$foreman_flag --release-please"
                        # shellcheck disable=SC2086  # foreman_flag is one optional word
                        if ! want_labels="$(node scripts/label-registry-render.mjs labels ${foreman_flag} 2>/dev/null)"; then
                            checkline unknown "Starter labels" "label-registry render failed — run node scripts/label-registry-render.mjs labels"
                        else
                            want_labels="$(printf '%s\n' "${want_labels}" | sed -n -E 's/^([^|]+)\|.*/\1/p')"
                            have_labels="$(cat "${d}/labels.txt" 2>/dev/null || true)"
                            want_count=0
                            missing_count=0
                            while IFS= read -r want; do
                                [ -z "${want}" ] && continue
                                want_count=$((want_count + 1))
                                printf '%s\n' "${have_labels}" | grep -qxF "${want}" ||
                                    missing_count=$((missing_count + 1))
                            done <<<"${want_labels}"
                            if [ -z "${have_labels}" ] || [ "${want_count}" -eq 0 ]; then
                                checkline no "Starter labels" "run task setup:github-labels"
                            elif [ "${missing_count}" -eq 0 ]; then
                                checkline ok "Starter labels" "all ${want_count} seeded"
                            else
                                checkline no "Starter labels" "${missing_count}/${want_count} missing — run task setup:github-labels"
                            fi
                        fi
                    fi
                fi
                if [ -f scripts/setup-github-issue-types.sh ]; then
                    type_names="$(jq -r 'if type == "array" then (map(.name) | join(",")) else "" end' "${d}/issue-types.json" 2>/dev/null || echo "")"
                    if [ -z "${type_names}" ]; then
                        checkline unknown "Org issue types" "needs admin:org"
                    elif printf '%s' "${type_names}" | grep -q 'Research'; then
                        checkline ok "Org issue types" "Bug/Feature/Task/Research"
                    else
                        checkline no "Org issue types" "run task setup:github-issue-types"
                    fi
                fi
                if [ -f scripts/setup-github-issue-fields.sh ]; then
                    # One `name<TAB>data_type` per line, not a joined string:
                    # `gh api --paginate` writes one JSON document per page, so jq
                    # runs per page and any single-line delimiter trick breaks at a
                    # page boundary.
                    field_rows="$(jq -r '(if type == "object" then (.issue_fields // []) elif type == "array" then . else [] end) | .[] | "\(.name)\t\(.data_type // "")"' "${d}/issue-fields.json" 2>/dev/null || echo "")"
                    # Product must be present AND of the right type: an org that
                    # happens to own a text-incompatible field named `Product`
                    # can never get it created (GitHub cannot change a field's
                    # data type in place). Reporting it done would hide exactly
                    # what the setup script warns about. The retired Agent,
                    # Domain, and Layer fields are deliberately NOT wanted here:
                    # the setup script no longer creates any of them, so
                    # requiring one would report a permanent false failure on
                    # every fresh org (#662, #875).
                    missing_fields=""
                    wrong_fields=""
                    for want in Product:text; do
                        wname="${want%%:*}"
                        wtype="${want##*:}"
                        htype="$(printf '%s\n' "${field_rows}" | awk -F'\t' -v n="${wname}" '$1 == n { print $2; exit }')"
                        if ! printf '%s\n' "${field_rows}" | cut -f1 | grep -qxF "${wname}"; then
                            missing_fields="${missing_fields}${missing_fields:+, }${wname}"
                        elif [ -n "${htype}" ] && [ "${htype}" != "${wtype}" ]; then
                            wrong_fields="${wrong_fields}${wrong_fields:+, }${wname} is ${htype}"
                        fi
                    done
                    if [ -z "${field_rows}" ]; then
                        checkline unknown "Org issue fields" "needs admin:org (public preview)"
                    elif [ -n "${wrong_fields}" ]; then
                        checkline no "Org issue fields" "wrong type: ${wrong_fields} — rename/delete, then re-run task setup:github-issue-fields"
                    elif [ -z "${missing_fields}" ]; then
                        checkline ok "Org issue fields" "Product"
                    else
                        checkline no "Org issue fields" "missing ${missing_fields} — run task setup:github-issue-fields"
                    fi
                fi
                if [ "${has_release_wf}" = 1 ]; then
                    if [ -s "${d}/release.txt" ]; then
                        rel="$(head -1 "${d}/release.txt" | awk '{print $1}')"
                        checkline ok "Release published" "${rel}"
                    else
                        checkline no "Release published" "task release:init"
                    fi
                else
                    checkline na "Release published" "no release workflow"
                fi

                # ── Secrets & variables (names only; values never read) ──
                subhead "Secrets & variables"
                if [ "${has_claude_wf}" = 1 ]; then
                    if has_cred "${d}/secrets.json" "CLAUDE_CODE_OAUTH_TOKEN"; then
                        checkline ok "CLAUDE_CODE_OAUTH_TOKEN"
                    else
                        checkline no "CLAUDE_CODE_OAUTH_TOKEN" "gh secret set"
                    fi
                else
                    checkline na "CLAUDE_CODE_OAUTH_TOKEN" "no claude-* workflows"
                fi
                if [ "${uses_ci_app}" = 1 ]; then
                    if has_cred "${d}/vars.json" "CI_APP_CLIENT_ID"; then
                        checkline ok "CI_APP_CLIENT_ID (variable)"
                    else
                        checkline no "CI_APP_CLIENT_ID (variable)" "gh variable set"
                    fi
                    if has_cred "${d}/secrets.json" "CI_APP_PRIVATE_KEY"; then
                        checkline ok "CI_APP_PRIVATE_KEY (secret)"
                    else
                        checkline no "CI_APP_PRIVATE_KEY (secret)" "gh secret set"
                    fi
                else
                    checkline na "CI App credentials" "not used by this repo"
                fi
                if [ "${uses_full_scan}" = 1 ]; then
                    if [ "${IS_PRIVATE}" != "true" ]; then
                        checkline na "Paid CodeQL opt-in" "CodeQL is public/free"
                    elif has_cred "${d}/vars.json" "FULL_SECURITY_SCAN"; then
                        checkline unknown "Paid CodeQL opt-in" "variable present; verify =true + entitlement"
                    else
                        checkline na "Paid CodeQL opt-in" "Semgrep CE free default"
                    fi
                else
                    checkline na "Paid CodeQL opt-in" "not supported by this profile"
                fi
            fi

            # ── Code health ──
            subhead "Code health"
            todo_count="$(git grep -I -h 'TODO:' 2>/dev/null | wc -l | tr -d ' ' || true)"
            checkline info "TODO: markers" "${todo_count:-0} remaining"

            # Summary — MUST stay in this { } group so the counters are in scope
            # (the surrounding pipe to section_box runs a subshell).
            #
            # Fold in the local-credentials group first. It tallied in a
            # different subshell, so its counts arrive through a file rather than
            # through these variables. Anything other than four plain integers —
            # absent, truncated, unreadable — means "no counts to add", which
            # leaves the summary reading exactly as it did before this existed
            # rather than corrupting it with a partial read.
            cred_ok=0
            cred_no=0
            cred_unknown=0
            cred_na=0
            read -r cred_ok cred_no cred_unknown cred_na \
                <"${TMPDIR_STATUS}/cred-counts" 2>/dev/null || true
            for cred_n in "${cred_ok}" "${cred_no}" "${cred_unknown}" "${cred_na}"; do
                case "${cred_n}" in
                "" | *[!0-9]*)
                    cred_ok=0
                    cred_no=0
                    cred_unknown=0
                    cred_na=0
                    break
                    ;;
                esac
            done
            SETUP_OK=$((SETUP_OK + cred_ok))
            SETUP_NO=$((SETUP_NO + cred_no))
            SETUP_UNKNOWN=$((SETUP_UNKNOWN + cred_unknown))
            SETUP_NA=$((SETUP_NA + cred_na))

            echo ""
            setup_total=$((SETUP_OK + SETUP_NO + SETUP_UNKNOWN))
            setup_pct=0
            [ "${setup_total}" -gt 0 ] && setup_pct=$((SETUP_OK * 100 / setup_total))
            printf '  %s  %s  %s\n' "$(bar "${setup_pct}")" \
                "$(c '1' "${setup_pct}%")" "$(c '2' "(${SETUP_OK}/${setup_total})")"
            kv "Summary" "$(c '32' "${SETUP_OK} ok") · $(c '31' "${SETUP_NO} missing") · $(c '33' "${SETUP_UNKNOWN} unknown") · ${SETUP_NA} n/a"
        } | section_box
    fi
fi
