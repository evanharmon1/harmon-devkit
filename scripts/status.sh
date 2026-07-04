#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"
PROJECT_NAME="$(basename "${REPO_ROOT}")"

# Section filter: empty = show all, or "git", "gh", "code", "env"
SECTION="${1:-}"

# Temp directory for parallel data collection
TMPDIR_STATUS="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_STATUS}"' EXIT

NETWORK_TIMEOUT=5

# ── Tool detection ──────────────────────────────────────────────────────────

HAS_GUM=false
command -v gum &>/dev/null && HAS_GUM=true

# ── Formatting helpers ──────────────────────────────────────────────────────

section_header() {
    local title="$1"
    if $HAS_GUM; then
        gum style --bold --foreground 212 --border-foreground 240 \
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
        echo "$content" | gum style --border rounded \
            --border-foreground 240 --padding "0 1" --margin "0 0"
    else
        echo "$content"
        echo ""
    fi
}

kv() {
    local key="$1" val="$2"
    if $HAS_GUM; then
        printf "  %s  %s\n" "$(gum style --bold --foreground 39 "$key:")" "$val"
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
{ [ -t 1 ] || $HAS_GUM; } && USE_COLOR=true

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

# ── Parallel data collection ────────────────────────────────────────────────

PID_PRS=""
PID_CHECKS=""
PID_TOKEI=""

CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || echo "detached")"

if should_show "gh" && gh auth status &>/dev/null 2>&1; then
    timeout "${NETWORK_TIMEOUT}" gh pr list --limit 10 \
        --json number,title,headRefName \
        >"${TMPDIR_STATUS}/prs.json" 2>/dev/null &
    PID_PRS=$!

    timeout "${NETWORK_TIMEOUT}" gh run list --branch "${CURRENT_BRANCH}" \
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
        gum style --bold --foreground 212 --border double \
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

    tag="$(git describe --tags --abbrev=0 2>/dev/null || echo "none")"

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

    if ! gh auth status &>/dev/null 2>&1; then
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
    } | section_box
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

    if ! gh auth status &>/dev/null 2>&1; then
        echo "  (gh not authenticated -- run 'gh auth login')" | section_box
    else
        d="${TMPDIR_STATUS}"

        # Repo identity — every API call below needs owner/repo, so resolve it
        # synchronously first.
        timeout "${NETWORK_TIMEOUT}" gh repo view \
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
            OWNER_TYPE="$(timeout "${NETWORK_TIMEOUT}" gh api "repos/${OWNER}/${REPO}" \
                --jq '.owner.type' 2>/dev/null || echo "User")"
            if [[ "${OWNER_TYPE}" == "Organization" ]]; then
                PKG_NS="orgs"
                APPS_PATH="orgs/${OWNER}/installations"
            else
                PKG_NS="users"
                APPS_PATH="user/installations"
            fi

            # ── Fire independent lookups in parallel ──
            (timeout "${NETWORK_TIMEOUT}" gh api "repos/${OWNER}/${REPO}/rulesets" \
                >"${d}/rulesets.json" 2>/dev/null || echo '[]' >"${d}/rulesets.json") &
            (timeout "${NETWORK_TIMEOUT}" gh api "repos/${OWNER}/${REPO}/vulnerability-alerts" \
                >/dev/null 2>&1 && echo yes >"${d}/depalerts" || echo no >"${d}/depalerts") &
            (timeout "${NETWORK_TIMEOUT}" gh api "repos/${OWNER}/${REPO}/private-vulnerability-reporting" \
                >"${d}/pvr.json" 2>/dev/null || echo '{}' >"${d}/pvr.json") &
            # --json name fetches ONLY names, never secret/variable values.
            (timeout "${NETWORK_TIMEOUT}" gh secret list --json name \
                >"${d}/secrets.json" 2>/dev/null || echo '[]' >"${d}/secrets.json") &
            (timeout "${NETWORK_TIMEOUT}" gh variable list --json name \
                >"${d}/vars.json" 2>/dev/null || echo '[]' >"${d}/vars.json") &
            (timeout "${NETWORK_TIMEOUT}" gh release list --limit 1 >"${d}/release.txt" 2>/dev/null || :) &
            # shellcheck disable=SC2016 # $o/$r are GraphQL variables, not shell
            (timeout "${NETWORK_TIMEOUT}" gh api graphql \
                -f query='query($o:String!,$r:String!){repository(owner:$o,name:$r){projectsV2(first:10){nodes{title number}}}}' \
                -F o="${OWNER}" -F r="${REPO}" \
                >"${d}/projects.json" 2>/dev/null || echo '{}' >"${d}/projects.json") &
            # PM setup surface — audit the results of the setup:github-* tasks the
            # repo actually ships (each script is the marker it opted in).
            if [ -f scripts/setup-github-labels.sh ]; then
                (timeout "${NETWORK_TIMEOUT}" gh label list -R "${OWNER}/${REPO}" --json name \
                    >"${d}/labels.json" 2>/dev/null || echo '[]' >"${d}/labels.json") &
            fi
            if [ -f scripts/setup-github-issue-types.sh ]; then
                (timeout "${NETWORK_TIMEOUT}" gh api "orgs/${OWNER}/issue-types" --paginate \
                    >"${d}/issue-types.json" 2>/dev/null || echo 'null' >"${d}/issue-types.json") &
            fi
            if [ -f scripts/setup-github-issue-fields.sh ]; then
                (timeout "${NETWORK_TIMEOUT}" gh api "orgs/${OWNER}/issue-fields" \
                    -H "X-GitHub-Api-Version: 2026-03-10" --paginate \
                    >"${d}/issue-fields.json" 2>/dev/null || echo 'null' >"${d}/issue-fields.json") &
            fi
            # App installs — definitive when we hold admin scope, else 'null'.
            (timeout "${NETWORK_TIMEOUT}" gh api "${APPS_PATH}" \
                --jq '[.installations[].app_slug]' \
                >"${d}/apps.json" 2>/dev/null || echo 'null' >"${d}/apps.json") &
            # Heuristic fallback signals for the two apps.
            (timeout "${NETWORK_TIMEOUT}" gh pr list --state all --author "app/renovate" \
                --limit 1 --json number >"${d}/renovate-pr.json" 2>/dev/null ||
                echo '[]' >"${d}/renovate-pr.json") &
            (timeout "${NETWORK_TIMEOUT}" gh api "repos/${OWNER}/${REPO}/pulls/comments?per_page=100" \
                --jq '[.[].user.login] | map(select(test("coderabbit";"i"))) | length' \
                >"${d}/coderabbit.txt" 2>/dev/null || echo 0 >"${d}/coderabbit.txt") &
            (
                if out="$(timeout "${NETWORK_TIMEOUT}" gh api \
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
                if [ -n "$(timeout 3 op account list 2>/dev/null)" ]; then
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
                    checkline na "CodeRabbit app" "no .coderabbit.yaml"
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
                    checkline unknown "GitHub Project linked" "needs read:project scope"
                fi
                if [ -f scripts/setup-github-labels.sh ]; then
                    if jq -e 'any(.[]?; .name == "needs-triage")' "${d}/labels.json" >/dev/null 2>&1; then
                        checkline ok "Starter labels" "seeded"
                    else
                        checkline no "Starter labels" "run task setup:github-labels"
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
                    field_names="$(jq -r '(if type == "object" then (.issue_fields // []) elif type == "array" then . else [] end) | map(.name) | join(",")' "${d}/issue-fields.json" 2>/dev/null || echo "")"
                    if [ -z "${field_names}" ]; then
                        checkline unknown "Org issue fields" "needs admin:org (public preview)"
                    elif printf '%s' "${field_names}" | grep -q 'Agent'; then
                        checkline ok "Org issue fields" "Product + Agent"
                    else
                        checkline no "Org issue fields" "run task setup:github-issue-fields"
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
                    if has_cred "${d}/vars.json" "FULL_SECURITY_SCAN"; then
                        checkline ok "FULL_SECURITY_SCAN (variable)"
                    else
                        checkline no "FULL_SECURITY_SCAN (variable)" "set =true to enable CodeQL"
                    fi
                else
                    checkline na "FULL_SECURITY_SCAN (variable)" "not referenced"
                fi
            fi

            # ── Code health ──
            subhead "Code health"
            todo_count="$(git grep -I -h 'TODO:' 2>/dev/null | wc -l | tr -d ' ' || true)"
            checkline info "TODO: markers" "${todo_count:-0} remaining"

            # Summary — MUST stay in this { } group so the counters are in scope
            # (the surrounding pipe to section_box runs a subshell).
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
