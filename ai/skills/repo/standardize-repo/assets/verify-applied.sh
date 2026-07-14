#!/usr/bin/env bash
#
# verify-applied.sh — validate a repo AFTER harmon-init conventions were applied.
#
# Usage:
#   verify-applied.sh [--ack-codeowner-change @old=@new]... [TARGET_DIR]
#   TARGET_DIR defaults to ".". Each acknowledgement must name one owner that
#   was actually dropped from main and one replacement present in the new file.
#
# Mirrors the validation philosophy of harmon-init's scripts/test-template.sh,
# but runs against an ALREADY-RENDERED, real repo (the result of `copier copy`
# / `copier update`), not a throwaway copier render. So it:
#   - delegates the heavy linting to the repo's own gate (`task verify`) instead
#     of re-implementing every linter, and
#   - spot-checks the structural invariants the template guarantees
#     (AGENTS.md canonical + agent-instruction symlinks, a parseable Taskfile,
#     no unrendered jinja markers, no leaked secrets).
#
# All checks accumulate; the script exits non-zero if ANY check fails, so it is
# safe to run as a post-apply gate in CI or locally.
#
# Portable to macOS bash 3.2 (no mapfile, no grep -P, no associative arrays).

set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
Usage:
  verify-applied.sh [--ack-codeowner-change @old=@new]... [TARGET_DIR]

The CODEOWNERS acknowledgement is intentionally exact: repeat it for each
intentional owner migration. The verifier rejects stale, extra, malformed, or
non-materialized mappings; there is no blanket access-control bypass.
USAGE
}

target=""
codeowner_ack_count=0
codeowner_acks=()
while [ $# -gt 0 ]; do
    case "$1" in
    --ack-codeowner-change)
        [ $# -ge 2 ] || {
            usage
            echo "FAIL: --ack-codeowner-change requires @old=@new" >&2
            exit 2
        }
        ack="$2"
        if ! printf '%s\n' "$ack" | grep -qE '^@[A-Za-z0-9_/-]+=@[A-Za-z0-9_/-]+$'; then
            usage
            echo "FAIL: malformed CODEOWNERS acknowledgement: $ack" >&2
            exit 2
        fi
        old="${ack%%=*}"
        new="${ack#*=}"
        if [ "$old" = "$new" ]; then
            echo "FAIL: CODEOWNERS acknowledgement must name a real migration: $ack" >&2
            exit 2
        fi
        codeowner_acks+=("$ack")
        codeowner_ack_count=$((codeowner_ack_count + 1))
        shift 2
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    -*)
        usage
        echo "FAIL: unknown argument: $1" >&2
        exit 2
        ;;
    *)
        if [ -n "$target" ]; then
            usage
            echo "FAIL: more than one target directory given" >&2
            exit 2
        fi
        target="$1"
        shift
        ;;
    esac
done
[ -n "$target" ] || target="."

if [ ! -d "$target" ]; then
    echo "FAIL: target directory not found: $target" >&2
    exit 1
fi

cd "$target"

have() { command -v "$1" >/dev/null 2>&1; }

fail=0
fail_msgs=""
err() {
    echo "FAIL: $*" >&2
    fail=1
    # accumulate a one-line summary of each failed check for the final verdict,
    # so "FAILED" names what failed rather than trailing the advisory drift WARN
    fail_msgs="${fail_msgs}    - $(printf '%s' "$*" | head -n 1)
"
}

echo "Verifying applied conventions in: $(pwd)"

# ── 1. The repo's own gate: `task verify` (lint + output checks) ─────
# This is the authoritative check — it runs whatever lint/test targets the
# generated Taskfile defines. We only orchestrate the structural spot-checks
# below; we do NOT duplicate the linters here.
if [ -f Taskfile.yml ] || [ -f Taskfile.yaml ]; then
    if have task; then
        if ! task verify; then
            err "'task verify' failed"
        fi
    else
        echo "WARN: 'task' (go-task) not installed — skipping 'task verify' gate"
    fi
else
    echo "WARN: no Taskfile.yml — repo may not have been standardized yet"
fi

# ── 2. AGENTS.md is canonical; agent-instruction files symlink to it ─
# copier.yml sets _preserve_symlinks: true so CLAUDE.md / GEMINI.md /
# .github/copilot-instructions.md stay as links pointing at AGENTS.md
# (copilot's canonical path is one dir down, so it links to ../AGENTS.md).
if [ ! -e AGENTS.md ]; then
    err "AGENTS.md missing"
elif [ -L AGENTS.md ] || [ ! -f AGENTS.md ]; then
    err "AGENTS.md should be a regular file, not a symlink or directory"
fi

for link in CLAUDE.md GEMINI.md; do
    if [ ! -L "$link" ]; then
        err "$link should be a symlink to AGENTS.md"
    elif [ "$(readlink "$link")" != "AGENTS.md" ]; then
        err "$link should resolve to AGENTS.md (found: $(readlink "$link"))"
    fi
done

# copilot's instructions file is optional, but if present it must link upward.
copilot=".github/copilot-instructions.md"
if [ -e "$copilot" ] || [ -L "$copilot" ]; then
    if [ ! -L "$copilot" ]; then
        err "$copilot should be a symlink to ../AGENTS.md"
    elif [ "$(readlink "$copilot")" != "../AGENTS.md" ]; then
        err "$copilot should resolve to ../AGENTS.md (found: $(readlink "$copilot"))"
    fi
fi

# ── 3. The generated Taskfile actually parses ───────────────────────
# `task verify` above would catch this too, but a broken Taskfile makes that
# step error out ambiguously; this gives a precise message.
if { [ -f Taskfile.yml ] || [ -f Taskfile.yaml ]; } && have task; then
    if ! task --list-all >/dev/null 2>&1; then
        err "Taskfile does not parse ('task --list-all' failed)"
    fi
fi

# ── 3b. Required universal Taskfile targets are present ──────────────
# Every standardized repo defines these regardless of project_type. A missing
# one means the Taskfile drifted from (or predates) the current template — the
# recurring example is status:setup (the setup-completeness audit), which older
# forks of scripts/status.sh + Taskfile never had.
if { [ -f Taskfile.yml ] || [ -f Taskfile.yaml ]; } && have task; then
    tasklist="$(task --list-all 2>/dev/null || true)"
    for t in verify check security status:setup install:hooks; do
        if ! printf '%s\n' "$tasklist" | grep -qE "^[* ]*${t}:([[:space:]]|\$)"; then
            err "Taskfile missing required target: ${t}"
        fi
    done
fi

# ── 3c. Workflow ↔ Taskfile contract ────────────────────────────────
# Every CI job / git hook delegates to a `task` target; enforce the CONVERSE —
# every `task <target>` a workflow invokes MUST exist in the Taskfile. CI's
# lint/build jobs call targets `task verify` never runs (e.g. test:tasks,
# test:hooks, test:devcontainer:permissions). A Taskfile that drifted from the
# template — or was restored wholesale from a pre-template `main` during a
# Path-B adopt while the template's workflows were taken as-is — can omit them,
# so `task verify` (and this script's §1 gate) stays GREEN while CI goes RED.
# This existence check catches that class at apply time. We anchor on a command
# CONTEXT — `run: task <t>`, a run-block line starting with `task <t>`, or
# `&& task <t>` — so prose ("the specific task described"), renovate comments
# (`go-task/task extractVersion`), and `setup-task@<sha>` never match.
if [ -d .github/workflows ] && { [ -f Taskfile.yml ] || [ -f Taskfile.yaml ]; } && have task; then
    tasklist="$(task --list-all 2>/dev/null || true)"
    called="$(grep -rhoE '(run:[[:space:]]*|^[[:space:]]*|&&[[:space:]]*)task +[a-z][a-z0-9:_-]*' .github/workflows/ 2>/dev/null |
        sed -E 's/.*task +//' | sort -u)"
    for t in $called; do
        if ! printf '%s\n' "$tasklist" | grep -qE "^[* ]*${t}:([[:space:]]|\$)"; then
            err "workflow calls 'task ${t}' but the Taskfile has no such target"
        fi
    done
fi

# ── 3d. CodeQL selection, fail-closed workflow, and live capability ──
# CodeQL is not universal merely because a repo contains Node/Python. The Copier
# answer selects it, FULL_SECURITY_SCAN starts it, and GitHub must accept SARIF.
# Public repositories have Code Security by default; private/internal repos need
# the live feature enabled. The API check below is GET-only. Missing permissions
# produce a manual-audit warning, never a guessed claim of coverage.
codeql_workflow=""
for candidate in .github/workflows/codeql.yml .github/workflows/codeql.yaml; do
    if [ -f "$candidate" ]; then
        codeql_workflow="$candidate"
        break
    fi
done

if [ -n "$codeql_workflow" ] &&
    grep -qE '^[[:space:]]*continue-on-error:[[:space:]]*true([[:space:]]|$)' "$codeql_workflow"; then
    err "$codeql_workflow lets CodeQL fail via 'continue-on-error: true'"
fi

if [ -f .copier-answers.yml ]; then
    use_codeql_answer="$(
        sed -n -E 's/^[[:space:]]*use_codeql:[[:space:]]*([^#[:space:]]+).*$/\1/p' .copier-answers.yml |
            tail -n 1 | tr '[:upper:]' '[:lower:]' | tr -d "\"'"
    )"
    case "$use_codeql_answer" in
    true | yes)
        if [ -z "$codeql_workflow" ]; then
            err "use_codeql=true but no .github/workflows/codeql.yml or codeql.yaml exists"
        fi
        if [ -f docs/architecture/security.md ] &&
            grep -qF 'CodeQL is deliberately omitted' docs/architecture/security.md; then
            err "use_codeql=true but security docs still say CodeQL is deliberately omitted"
        fi

        if [ -n "$codeql_workflow" ]; then
            echo "INFO: CodeQL workflow presence and FULL_SECURITY_SCAN are configuration only;" >&2
            echo "      verify a successful analysis/SARIF upload before claiming coverage." >&2

            codeql_nwo=""
            if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                remote_url="$(git remote get-url origin 2>/dev/null || true)"
                case "$remote_url" in
                https://github.com/*)
                    codeql_nwo="${remote_url#https://github.com/}"
                    ;;
                git@github.com:*)
                    codeql_nwo="${remote_url#git@github.com:}"
                    ;;
                ssh://git@github.com/*)
                    codeql_nwo="${remote_url#ssh://git@github.com/}"
                    ;;
                esac
                codeql_nwo="${codeql_nwo%.git}"
                codeql_nwo="${codeql_nwo%/}"
            fi

            if [ -n "$codeql_nwo" ] && have gh; then
                if repo_security="$(gh api "repos/$codeql_nwo" \
                    --jq '[.visibility, (.security_and_analysis.code_security.status // "unknown")] | @tsv' \
                    2>/dev/null)"; then
                    IFS=$'\t' read -r visibility code_security <<<"$repo_security"
                    [ -n "$code_security" ] || code_security="unknown"
                    case "$visibility" in
                    public)
                        echo "INFO: $codeql_nwo is public; GitHub Code Security is available by default." >&2
                        ;;
                    private | internal)
                        case "$code_security" in
                        enabled)
                            echo "INFO: $codeql_nwo reports GitHub Code Security enabled." >&2
                            ;;
                        disabled)
                            err "use_codeql=true but $codeql_nwo is $visibility with GitHub Code Security disabled; enable it first or re-render with use_codeql=false"
                            ;;
                        *)
                            echo "WARN: $codeql_nwo is $visibility but Code Security capability is '$code_security' —" >&2
                            echo "      verify Settings > Code security manually; do not infer CodeQL coverage." >&2
                            ;;
                        esac
                        ;;
                    *)
                        echo "WARN: could not classify repository visibility for $codeql_nwo —" >&2
                        echo "      verify Code Security capability manually; do not infer coverage." >&2
                        ;;
                    esac
                else
                    echo "WARN: read-only Code Security API audit failed for $codeql_nwo —" >&2
                    echo "      verify Settings > Code security manually; do not infer CodeQL coverage." >&2
                fi
            else
                echo "WARN: no queryable GitHub origin/gh CLI for the CodeQL capability audit —" >&2
                echo "      verify Code Security manually; do not infer coverage from workflow files." >&2
            fi
        fi
        ;;
    false | no)
        if [ -n "$codeql_workflow" ]; then
            err "use_codeql=false but $codeql_workflow still exists"
        fi
        for taskfile in Taskfile.yml Taskfile.yaml; do
            if [ -f "$taskfile" ] && grep -qF 'FULL_SECURITY_SCAN' "$taskfile"; then
                err "use_codeql=false but $taskfile still configures FULL_SECURITY_SCAN"
            fi
        done
        if [ -f README.md ] && grep -qE 'actions/workflows/codeql\.ya?ml' README.md; then
            err "use_codeql=false but README.md still advertises the CodeQL workflow"
        fi
        if [ -f docs/architecture/security.md ] &&
            ! grep -qF 'CodeQL is deliberately omitted' docs/architecture/security.md; then
            err "use_codeql=false but security docs do not explicitly document the SAST gap"
        fi
        ;;
    "")
        if [ -n "$codeql_workflow" ]; then
            echo "WARN: CodeQL workflow exists but .copier-answers.yml has no explicit use_codeql answer —" >&2
            echo "      review stack + live capability on the next template update." >&2
        fi
        ;;
    *)
        err "invalid use_codeql value in .copier-answers.yml: $use_codeql_answer"
        ;;
    esac
fi

# ── 4. No unrendered template markers leaked into the repo ──────────
# harmon-init uses CUSTOM jinja delimiters ([[ var ]], [% block %]). Legitimate
# look-alikes must NOT trip this: go-task uses {{.VAR}} (dot, no space), GitHub
# Actions uses ${{ }}, bash uses [[ -n "$x" ]] / array[idx], and terminfo uses
# \E[%p1%d — none of which have the "<delim><optional-ws-dash><space><token>"
# shape we match. We anchor variable markers on the copier answer-variable name
# stems (kept in sync with copier.yml; every question variable must be covered
# by one stem) so a real leak ([[ git_init ]], {{ author_full_name }}) is caught
# while bash bare-word tests ([[ true ]]) are not. Block markers anchor on the
# jinja keyword set, including the raw/endraw the template actually emits and the
# [%- whitespace-control form used in LICENSE.jinja.
#
# Enumerate files the way gitleaks (step 5) does — honoring .gitignore — so
# vendored dependencies in gitignored dirs cannot false-trip the scan: .venv
# ships Ansible's own .j2/jinja templates and plugin docs, .terraform caches
# provider source, node_modules is third-party. `git ls-files --cached --others
# --exclude-standard` lists tracked AND untracked-but-not-ignored files, so a
# freshly rendered, not-yet-staged repo is still fully checked. Fall back to a
# recursive grep (with explicit excludes) when the target is not a git work tree.
varpfx='project_|author_|github_|organization|repo_url|ci_runner|include_|use_|devcontainer|git_init|bunch_add|obsidian_|run_task_install|projects_directory|bunches_directory|license|current_|country|state'
blockkw='if|for|set|else|elif|endif|endfor|endset|raw|endraw|macro|endmacro|block|endblock|include|extends|with|endwith|filter|endfilter'
marker_re="\[\[-? ($varpfx)|\{\{-? ($varpfx)|\[%-? ($blockkw) "
# Exclude *.j2 / *.jinja from the scan: those are legitimately full of standard
# Jinja ({{ x }} / {% x %}) — Ansible templates, nginx configs, etc. — and the
# {{ <stem> }} branch of marker_re can't tell `{{ github_runner_image }}` (a real
# Ansible var) from a copier leak. Copier's own delimiters are [[ ]] / [% %], so
# dropping these files loses no real-leak coverage. Likewise drop anything under
# a `skills/` dir: agent-skill references/assets legitimately DOCUMENT copier's
# [[ ]] / [% %] delimiters as examples (the standardize-repo skill itself does),
# so they would false-positive on the repo that HOSTS the skill — cf. the
# .claude/** exclude in the markdownlint config.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    leaks=$(git ls-files --cached --others --exclude-standard -z 2>/dev/null |
        xargs -0 grep -IlE "$marker_re" 2>/dev/null |
        grep -vE '\.(j2|jinja)$|(^|/)skills/' || true)
else
    leaks=$(grep -rIlE "$marker_re" \
        --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv \
        --exclude-dir=.terraform --exclude-dir=.task --exclude-dir=.worktrees \
        --exclude-dir=dist --exclude-dir=skills --exclude='*.j2' --exclude='*.jinja' . 2>/dev/null || true)
fi
if [ -n "$leaks" ]; then
    err "unrendered template markers found in:"
    # Print one path per line for readability; indented so it groups under the FAIL.
    echo "$leaks" | sed 's/^/    /' >&2
fi

# ── 5. No secrets committed/sitting in the tree (gitleaks) ──────────
# Matches test-template.sh: gitleaks is best-effort locally, but if it is
# installed a finding is a hard failure.
if have gitleaks; then
    if ! gitleaks detect --no-banner --redact --source .; then
        err "gitleaks reported findings"
    fi
else
    echo "WARN: gitleaks not installed — skipping secrets scan"
fi

# ── 6. Template-owned file content drift (advisory) ─────────────────
# Renders harmon-init from this repo's .copier-answers.yml and diffs the
# template-owned file set (see diff-template.sh / template-owned-files.txt).
# Advisory here — some drift is legitimate local customization, and the
# update/audit modes review and reconcile it. After a `copier update` it should
# show only intentional customizations.
diff_tool="$(dirname "$0")/diff-template.sh"
if [ -f .copier-answers.yml ] && [ -x "$diff_tool" ] && have copier && have yq; then
    if ! "$diff_tool" . >/dev/null 2>&1; then
        echo "WARN: template-owned files differ from a fresh harmon-init render —" >&2
        echo "      review with $diff_tool --show . and reconcile (mode-update.md /" >&2
        echo "      mode-audit.md drift class K). Legit customizations are expected." >&2
    fi
fi

# ── 7. CODEOWNERS must not lose owners on adopt (access-control regression) ─
# CODEOWNERS is rendered from the single `code_owner` answer (`* @owner`), so a
# Path-B adopt over a repo with MORE owners (or a team) silently drops them — an
# access-control change that must be surfaced and confirmed, never auto-applied.
# harmon-init also freezes CODEOWNERS via _skip_if_exists; this is the belt to
# that suspenders (and catches a hand-overwritten CODEOWNERS too). Compare the
# @owners in the pre-adopt CODEOWNERS (on `main`) against the current one. An
# intentional migration is acknowledged only with an exact
# `--ack-codeowner-change @old=@new` mapping: @old must truly be dropped and
# @new must be present now. Extra/stale mappings fail, so this cannot become a
# blanket bypass. Skip cleanly only when there is no main or not a git tree.
co=".github/CODEOWNERS"
codeowners_compared=0
if git rev-parse --is-inside-work-tree >/dev/null 2>&1 &&
    git cat-file -e "main:$co" 2>/dev/null; then
    codeowners_compared=1
    before="$(git show "main:$co" 2>/dev/null | grep -oE '@[A-Za-z0-9_/-]+' | sort -u)"
    if [ -f "$co" ]; then
        after="$(grep -oE '@[A-Za-z0-9_/-]+' "$co" 2>/dev/null | sort -u)"
    else
        after=""
    fi
    dropped="$(comm -23 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -v '^$' || true)"
    acknowledged_old=""
    if [ "$codeowner_ack_count" -gt 0 ]; then
        for ack in "${codeowner_acks[@]}"; do
            old="${ack%%=*}"
            new="${ack#*=}"
            if ! printf '%s\n' "$before" | grep -qxF "$old"; then
                err "CODEOWNERS acknowledgement is stale: $old was not present on main"
                continue
            fi
            if ! printf '%s\n' "$dropped" | grep -qxF "$old"; then
                err "CODEOWNERS acknowledgement is extra: $old was not actually dropped"
                continue
            fi
            if ! printf '%s\n' "$after" | grep -qxF "$new"; then
                err "CODEOWNERS acknowledgement is not materialized: replacement $new is absent"
                continue
            fi
            if printf '%s' "$acknowledged_old" | grep -qxF "$old"; then
                err "CODEOWNERS owner acknowledged more than once: $old"
                continue
            fi
            acknowledged_old="${acknowledged_old}${old}
"
            echo "ACK: intentional CODEOWNERS migration $old -> $new"
        done
    fi

    unacknowledged=""
    for owner in $dropped; do
        if ! printf '%s' "$acknowledged_old" | grep -qxF "$owner"; then
            unacknowledged="${unacknowledged}${owner}
"
        fi
    done
    if [ -n "$unacknowledged" ]; then
        err "CODEOWNERS dropped owner(s) present on main without an exact migration acknowledgement: $(printf '%s ' $unacknowledged)— restore them, or repeat --ack-codeowner-change @old=@new for each intentional migration after confirming it with the user."
    fi
fi
if [ "$codeowner_ack_count" -gt 0 ] && [ "$codeowners_compared" -eq 0 ]; then
    err "CODEOWNERS acknowledgement supplied, but main has no comparable .github/CODEOWNERS"
fi

# ── Result ──────────────────────────────────────────────────────────
if [ "$fail" -ne 0 ]; then
    echo "verify-applied: FAILED — checks that did not pass:" >&2
    printf '%s' "$fail_msgs" >&2
    exit 1
fi
echo "verify-applied: PASS"
