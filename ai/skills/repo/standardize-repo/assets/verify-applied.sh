#!/usr/bin/env bash
#
# verify-applied.sh — validate a repo AFTER harmon-init conventions were applied.
#
# Usage:
#   verify-applied.sh [TARGET_DIR]   # TARGET_DIR defaults to "."
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

target="${1:-.}"

if [ ! -d "$target" ]; then
    echo "FAIL: target directory not found: $target" >&2
    exit 1
fi

cd "$target"

have() { command -v "$1" >/dev/null 2>&1; }

fail=0
err() {
    echo "FAIL: $*" >&2
    fail=1
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
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    leaks=$(git ls-files --cached --others --exclude-standard -z 2>/dev/null |
        xargs -0 grep -IlE "$marker_re" 2>/dev/null || true)
else
    leaks=$(grep -rIlE "$marker_re" \
        --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.venv \
        --exclude-dir=.terraform --exclude-dir=.task --exclude-dir=.worktrees \
        --exclude-dir=dist . 2>/dev/null || true)
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

# ── Result ──────────────────────────────────────────────────────────
if [ "$fail" -ne 0 ]; then
    echo "verify-applied: FAILED" >&2
    exit 1
fi
echo "verify-applied: PASS"
