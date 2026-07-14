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
    called="$(
        grep -rhoE '(run:[[:space:]]*|^[[:space:]]*|&&[[:space:]]*)task +[a-z][a-z0-9:_-]*' .github/workflows/ 2>/dev/null |
            sed -E 's/.*task +//' | sort -u || true
    )"
    for t in $called; do
        if ! printf '%s\n' "$tasklist" | grep -qE "^[* ]*${t}:([[:space:]]|\$)"; then
            err "workflow calls 'task ${t}' but the Taskfile has no such target"
        fi
    done
fi

# ── 3d. Terraform lint + provider-lock contract ──────────────────────
# Terraform coverage is capability-gated, not universal. When a repo selected
# include_terraform OR contains first-party .tf files, `task check` must actually
# reach fmt, TFLint, Checkov, and the cross-platform provider-lock check. Merely
# naming those tools in docs (or committing one host's lock file) is not proof.
include_terraform_answer=""
if [ -f .copier-answers.yml ]; then
    include_terraform_answer="$(
        sed -n -E 's/^[[:space:]]*include_terraform:[[:space:]]*([^#[:space:]]+).*$/\1/p' .copier-answers.yml |
            tail -n 1 | tr '[:upper:]' '[:lower:]' | tr -d "\"'"
    )"
fi

repo_files=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo_files="$(git ls-files --cached --others --exclude-standard 2>/dev/null || true)"
else
    repo_files="$(find . -type f 2>/dev/null | sed 's#^\./##' || true)"
fi
terraform_sources="$(
    printf '%s\n' "$repo_files" |
        grep -E '\.tf$' |
        grep -vE '(^|/)(\.terraform|node_modules|vendor|dist|build)/' || true
)"

has_terraform=false
case "$include_terraform_answer" in
true | yes)
    has_terraform=true
    ;;
false | no | "") ;;
*)
    err "invalid include_terraform value in .copier-answers.yml: $include_terraform_answer"
    ;;
esac
if [ -n "$terraform_sources" ]; then
    has_terraform=true
fi

if [ "$has_terraform" = true ]; then
    provider_lock_helper="scripts/terraform-provider-locks.sh"
    if [ ! -f "$provider_lock_helper" ]; then
        err "Terraform is present but $provider_lock_helper is missing"
    else
        if [ ! -x "$provider_lock_helper" ]; then
            err "$provider_lock_helper must be executable"
        fi
        provider_lock_program="$(sed -E 's/[[:space:]]*#.*$//' "$provider_lock_helper")"
        for lock_contract in \
            'providers lock' \
            '-platform=darwin_arm64' \
            '-platform=linux_amd64'; do
            if ! grep -qF -- "$lock_contract" <<<"$provider_lock_program"; then
                err "$provider_lock_helper does not establish '$lock_contract'"
            fi
        done
    fi

    provider_lock_regression="scripts/test-terraform-provider-locks.sh"
    if [ ! -f "$provider_lock_regression" ]; then
        err "Terraform is present but $provider_lock_regression is missing"
    elif [ ! -x "$provider_lock_regression" ]; then
        err "$provider_lock_regression must be executable"
    elif ! "$provider_lock_regression" >/dev/null 2>&1; then
        err "$provider_lock_regression failed its hermetic lock-process checks"
    fi

    if have task && { [ -f Taskfile.yml ] || [ -f Taskfile.yaml ]; }; then
        terraform_tasklist="$(task --list-all 2>/dev/null || true)"
        for terraform_task in lint:terraform terraform:providers:lock; do
            if ! grep -qE "^[* ]*${terraform_task}:([[:space:]]|\$)" \
                <<<"$terraform_tasklist"; then
                err "Terraform Taskfile contract is missing target: $terraform_task"
            fi
        done

        terraform_lint_dry="$(NO_COLOR=1 task --dry lint:terraform 2>&1 || true)"
        terraform_check_dry="$(NO_COLOR=1 task --dry check 2>&1 || true)"
        terraform_lock_dry="$(NO_COLOR=1 task --dry terraform:providers:lock 2>&1 || true)"

        for dry_contract in \
            'terraform fmt -check' \
            'tflint --recursive' \
            'checkov==' \
            'checkov -d'; do
            if ! grep -qF -- "$dry_contract" <<<"$terraform_lint_dry"; then
                err "task lint:terraform does not reach '$dry_contract'"
            fi
            if ! grep -qF -- "$dry_contract" <<<"$terraform_check_dry"; then
                err "task check does not reach Terraform contract '$dry_contract'"
            fi
        done
        if ! grep -qE 'terraform-provider-locks\.sh[[:space:]]+check[[:space:]]+[^[:space:]]' \
            <<<"$terraform_lint_dry"; then
            err "task lint:terraform does not reach the provider-lock check helper"
        fi
        if ! grep -qE 'terraform-provider-locks\.sh[[:space:]]+check[[:space:]]+[^[:space:]]' \
            <<<"$terraform_check_dry"; then
            err "task check does not reach the Terraform provider-lock check helper"
        fi
        if ! grep -qE 'uvx .*--from .*checkov==' <<<"$terraform_lint_dry"; then
            err "task lint:terraform must run pinned Checkov through uvx --from"
        fi
        if ! grep -qE 'terraform-provider-locks\.sh[[:space:]]+update[[:space:]]+[^[:space:]]' \
            <<<"$terraform_lock_dry"; then
            err "task terraform:providers:lock does not reach the explicit lock update helper"
        fi
    else
        echo "WARN: task is unavailable; Terraform lint/lock task reachability needs manual audit." >&2
    fi

    if [ ! -f Brewfile ]; then
        err "Terraform is present but Brewfile is missing its local tool contract"
    else
        for formula in terraform tflint uv; do
            if ! grep -qE "^[[:space:]]*brew[[:space:]]+['\"]${formula}['\"]" Brewfile; then
                err "Terraform local lint contract is missing brew formula: $formula"
            fi
        done
    fi

    build_workflow=""
    for candidate in .github/workflows/build.yml .github/workflows/build.yaml; do
        if [ -f "$candidate" ]; then
            build_workflow="$candidate"
            break
        fi
    done
    if [ -z "$build_workflow" ]; then
        err "Terraform is present but no build workflow provisions its lint tools"
    else
        for setup_action in \
            'hashicorp/setup-terraform@' \
            'terraform-linters/setup-tflint@' \
            'astral-sh/setup-uv@'; do
            if ! grep -qE "^[[:space:]]*-[[:space:]]+uses:[[:space:]]+${setup_action}" \
                "$build_workflow"; then
                err "$build_workflow does not provision Terraform lint dependency: $setup_action"
            fi
        done
    fi
fi

# ── 3e. CodeQL selection, result truth table, and live capability ──
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

if [ -n "$codeql_workflow" ] && awk '
    function indentation(value) {
        match(value, /^[ ]*/)
        return RLENGTH
    }
    function finish_step() {
        if (step_is_analyze && step_continues) {
            fail_open = 1
        }
        step_is_analyze = 0
        step_continues = 0
    }
    BEGIN {
        in_analyze_job = 0
        job_indent = -1
        steps_indent = -1
        step_indent = -1
        fail_open = 0
    }
    {
        line = $0
        normalized = tolower(line)
        if (line ~ /^[[:space:]]*(#|$)/) {
            next
        }
        indent = indentation(line)
        if (!in_analyze_job) {
            if (line ~ /^[ ]*analyze:[ ]*(#.*)?$/) {
                in_analyze_job = 1
                job_indent = indent
            }
            next
        }
        if (indent <= job_indent) {
            finish_step()
            in_analyze_job = 0
            next
        }
        if (indent == job_indent + 2 &&
            normalized ~ /^[ ]*continue-on-error:[ ]*true([ ]|$)/) {
            fail_open = 1
        }
        if (indent == job_indent + 2 && line ~ /^[ ]*steps:[ ]*$/) {
            steps_indent = indent
            next
        }
        if (steps_indent >= 0) {
            if (indent == steps_indent + 2 && line ~ /^[ ]*-[ ]/) {
                finish_step()
                step_indent = indent
            }
            if (step_indent >= 0) {
                if (normalized ~ /uses:[ ]*github\/codeql-action\/analyze@/) {
                    step_is_analyze = 1
                }
                if (normalized ~ /^[ ]*continue-on-error:[ ]*true([ ]|$)/) {
                    step_continues = 1
                }
            }
        }
    }
    END {
        finish_step()
        exit(fail_open ? 0 : 1)
    }
' "$codeql_workflow"; then
    err "$codeql_workflow lets the CodeQL analyze job/action fail via 'continue-on-error: true'"
fi

if [ -n "$codeql_workflow" ] && ! awk '
    BEGIN {
        in_analyze = 0
        scan_gate = 0
        trusted_event = 0
        trusted_repo = 0
    }
    {
        line = $0
        if (!in_analyze) {
            if (line ~ /^  analyze:[ ]*(#.*)?$/) {
                in_analyze = 1
            }
            next
        }
        if (line ~ /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/) {
            in_analyze = 0
            next
        }
        if (index(line, "vars.FULL_SECURITY_SCAN ==") && index(line, "true")) {
            scan_gate = 1
        }
        if (index(line, "github.event_name !=") && index(line, "pull_request")) {
            trusted_event = 1
        }
        if (index(line, "head.repo.full_name == github.repository")) {
            trusted_repo = 1
        }
    }
    END {
        exit(scan_gate && trusted_event && trusted_repo ? 0 : 1)
    }
' "$codeql_workflow"; then
    err "$codeql_workflow analyze job must require FULL_SECURITY_SCAN=true and a trusted same-repository event"
fi

if [ -n "$codeql_workflow" ]; then
    codeql_result_helper="scripts/verify-codeql-result.sh"
    if [ ! -f "$codeql_result_helper" ]; then
        err "$codeql_workflow has no $codeql_result_helper fail-closed aggregate helper"
    else
        if [ ! -x "$codeql_result_helper" ]; then
            err "$codeql_result_helper must be executable because the workflow runs it directly"
        fi

        codeql_result_contract_ok=true
        if ! env -u FULL_SECURITY_SCAN IS_FORK=false ANALYZE_RESULT=skipped \
            "$codeql_result_helper" >/dev/null 2>&1; then
            codeql_result_contract_ok=false
        fi
        if ! env FULL_SECURITY_SCAN= IS_FORK=false ANALYZE_RESULT=skipped \
            "$codeql_result_helper" >/dev/null 2>&1; then
            codeql_result_contract_ok=false
        fi
        if ! env FULL_SECURITY_SCAN=false IS_FORK=false ANALYZE_RESULT=skipped \
            "$codeql_result_helper" >/dev/null 2>&1; then
            codeql_result_contract_ok=false
        fi
        if ! env FULL_SECURITY_SCAN=true IS_FORK=true ANALYZE_RESULT=skipped \
            "$codeql_result_helper" >/dev/null 2>&1; then
            codeql_result_contract_ok=false
        fi
        if ! env FULL_SECURITY_SCAN=true IS_FORK=false ANALYZE_RESULT=success \
            "$codeql_result_helper" >/dev/null 2>&1; then
            codeql_result_contract_ok=false
        fi
        for rejected_contract in \
            'true false skipped' \
            'true false failure' \
            'true false cancelled' \
            'false false success' \
            'yes false skipped' \
            'TRUE false skipped' \
            'true false unknown'; do
            rejected_scan="${rejected_contract%% *}"
            rejected_rest="${rejected_contract#* }"
            rejected_fork="${rejected_rest%% *}"
            rejected_result="${rejected_rest#* }"
            if env FULL_SECURITY_SCAN="$rejected_scan" IS_FORK="$rejected_fork" \
                ANALYZE_RESULT="$rejected_result" \
                "$codeql_result_helper" >/dev/null 2>&1; then
                codeql_result_contract_ok=false
            fi
        done
        if [ "$codeql_result_contract_ok" != true ]; then
            err "$codeql_result_helper does not enforce the disabled/fork/enabled CodeQL result truth table"
        fi
    fi

    for workflow_contract in \
        'FULL_SECURITY_SCAN:' \
        'vars.FULL_SECURITY_SCAN' \
        'IS_FORK:' \
        'github.event.pull_request.head.repo.full_name != github.repository' \
        'ANALYZE_RESULT:' \
        'needs.analyze.result' \
        'run: ./scripts/verify-codeql-result.sh'; do
        if ! grep -qF "$workflow_contract" "$codeql_workflow"; then
            err "$codeql_workflow does not wire the aggregate result contract: $workflow_contract"
        fi
    done

    # A fork PR must not make a potentially self-hosted aggregate runner check
    # out and execute fork-controlled repository code. Trusted events may run the
    # tested helper; forks use a tiny workflow-defined diagnostic instead.
    if ! awk '
        function reset_step() {
            is_checkout = 0
            is_helper = 0
            is_fork_check = 0
            trusted_event = 0
            trusted_repo = 0
            fork_event = 0
            fork_repo = 0
            defaults_scan = 0
            validates_scan = 0
            validates_skip = 0
            executes_repo_code = 0
        }
        function finish_step() {
            if (is_checkout && trusted_event && trusted_repo) {
                safe_checkout = 1
            }
            if (is_helper && trusted_event && trusted_repo) {
                safe_helper = 1
            }
            if (is_fork_check && fork_event && fork_repo && defaults_scan &&
                validates_scan && validates_skip && !executes_repo_code) {
                safe_fork_check = 1
            }
            reset_step()
        }
        BEGIN {
            in_verify = 0
            in_step = 0
            safe_checkout = 0
            safe_helper = 0
            safe_fork_check = 0
            reset_step()
        }
        {
            line = $0
            if (!in_verify) {
                if (line ~ /^  codeql-verify:[ ]*(#.*)?$/) {
                    in_verify = 1
                }
                next
            }
            if (line ~ /^  [A-Za-z0-9_-]+:[ ]*(#.*)?$/) {
                finish_step()
                in_verify = 0
                next
            }
            if (line ~ /^      - /) {
                if (in_step) {
                    finish_step()
                }
                in_step = 1
            }
            if (!in_step || line ~ /^[[:space:]]*#/) {
                next
            }
            if (line ~ /uses:[ ]*actions\/checkout@/) {
                is_checkout = 1
            }
            if (line ~ /run:[ ]*\.\/scripts\/verify-codeql-result\.sh/) {
                is_helper = 1
            }
            if (line ~ /name:[ ]*Check deliberate fork skip/) {
                is_fork_check = 1
            }
            if (index(line, "github.event_name !=") && index(line, "pull_request")) {
                trusted_event = 1
            }
            if (index(line, "head.repo.full_name == github.repository")) {
                trusted_repo = 1
            }
            if (index(line, "github.event_name ==") && index(line, "pull_request")) {
                fork_event = 1
            }
            if (index(line, "head.repo.full_name != github.repository")) {
                fork_repo = 1
            }
            if (index(line, "scan=\"${FULL_SECURITY_SCAN:-false}\"")) {
                defaults_scan = 1
            }
            if (index(line, "case \"$scan\" in")) {
                validates_scan = 1
            }
            if (index(line, "ANALYZE_RESULT") && index(line, "!=") &&
                index(line, "skipped")) {
                validates_skip = 1
            }
            if (is_fork_check &&
                (line ~ /uses:/ || line ~ /run:[ ]*(\.\/|bash |sh ).*scripts\// ||
                 line ~ /(^|[ ])\.\/scripts\//)) {
                executes_repo_code = 1
            }
        }
        END {
            if (in_step) {
                finish_step()
            }
            exit(safe_checkout && safe_helper && safe_fork_check ? 0 : 1)
        }
    ' "$codeql_workflow"; then
        err "$codeql_workflow must guard aggregate checkout/helper execution to trusted events and validate fork skips without repository code"
    fi

    # The Copier stack flags decide which languages can be rendered, but they do
    # not prove that a repository actually contains that first-party language.
    # Warn on source/matrix drift so an audit can choose the explicit language
    # set rather than silently scanning only tooling or missing real code.
    first_party_source_files="$(
        printf '%s\n' "$repo_files" |
            grep -vE '(^|/)(\.git|\.github|\.claude|\.codex|\.agents|node_modules|\.venv|\.terraform|vendor|dist|build|coverage|generated|_generated)/' |
            grep -vE '(^|/)(astro|commitlint|eslint|knip|playwright|postcss|prettier|tailwind|vite|vitest|webpack)\.config\.(cjs|mjs|js|jsx|ts|tsx)$' |
            grep -vE '(^|/)scripts/summarize-gitleaks\.mjs$' || true
    )"
    has_javascript_source=false
    has_python_source=false
    if printf '%s\n' "$first_party_source_files" |
        grep -qE '\.(cjs|mjs|js|jsx|cts|mts|ts|tsx)$'; then
        has_javascript_source=true
    fi
    if printf '%s\n' "$first_party_source_files" | grep -qE '\.py$'; then
        has_python_source=true
    fi

    matrix_has_javascript=false
    matrix_has_python=false
    if grep -qF 'javascript-typescript' "$codeql_workflow"; then
        matrix_has_javascript=true
    fi
    if grep -qE '(^|[^[:alnum:]_-])python([^[:alnum:]_-]|$)' "$codeql_workflow"; then
        matrix_has_python=true
    fi

    if [ "$matrix_has_javascript" = true ] && [ "$has_javascript_source" = false ]; then
        echo "WARN: CodeQL matrix includes javascript-typescript but no first-party JS/TS source was found." >&2
    elif [ "$matrix_has_javascript" = false ] && [ "$has_javascript_source" = true ]; then
        echo "WARN: first-party JS/TS source exists but CodeQL omits javascript-typescript." >&2
    fi
    if [ "$matrix_has_python" = true ] && [ "$has_python_source" = false ]; then
        echo "WARN: CodeQL matrix includes python but no first-party Python source was found." >&2
    elif [ "$matrix_has_python" = false ] && [ "$has_python_source" = true ]; then
        echo "WARN: first-party Python source exists but CodeQL omits python." >&2
    fi
fi

use_codeql_answer=""
if [ -f .copier-answers.yml ]; then
    use_codeql_answer="$(
        sed -n -E 's/^[[:space:]]*use_codeql:[[:space:]]*([^#[:space:]]+).*$/\1/p' .copier-answers.yml |
            tail -n 1 | tr '[:upper:]' '[:lower:]' | tr -d "\"'"
    )"
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
                    err "CodeQL workflow exists but $codeql_nwo is $visibility with GitHub Code Security disabled; enable it first or select use_codeql=false and remove the workflow/coverage claims"
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

case "$use_codeql_answer" in
true | yes)
    if [ -z "$codeql_workflow" ]; then
        err "use_codeql=true but no .github/workflows/codeql.yml or codeql.yaml exists"
    fi
    if [ -f docs/architecture/security.md ] &&
        grep -qF 'CodeQL is deliberately omitted' docs/architecture/security.md; then
        err "use_codeql=true but security docs still say CodeQL is deliberately omitted"
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
