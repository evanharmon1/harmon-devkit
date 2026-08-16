#!/usr/bin/env bash
# triage.sh — `task triage` entry point: run the triage skill over this repo's
# backlog with a cheap headless model.
#
# The skill (ai/skills/universal/triage, vendored as .agents/skills/triage or
# .claude/skills/triage in consumers) is written for simple models: all
# enforcement lives in its asset scripts, the model only classifies. This
# wrapper picks the model, grants it exactly the tools the skill needs, and —
# most importantly — owns the write gate:
#
#   - DRY-RUN is the default. TRIAGE_EXECUTE is forced to 0, so even a model
#     that passes --execute to a script is refused by the script itself.
#   - `task triage -- --execute` is the supervised apply mode. It requires an
#     interactive terminal: the skill's v1 gate is a human watching the first
#     runs (issue #455's [HUMAN] criterion), so a headless --execute is
#     refused outright rather than made configurable. Unattended cadence is a
#     separate, later decision.
#
# Anything after --execute (or all args, without it) is passed to the model as
# an operator note, e.g.: task triage -- --execute only issues touching CI
#
# Env: TRIAGE_MODEL (default: haiku) picks the model.
#
# Exit: 2 = environment/usage refusal, otherwise the model run's exit code.
set -euo pipefail
cd "$(dirname "$0")/.."

die() {
    echo "triage: $*" >&2
    exit 2
}

mode="dry-run"
note=""
if [ "${1:-}" = "--execute" ]; then
    mode="execute"
    shift
fi
[ "$#" -eq 0 ] || note="$*"

command -v claude >/dev/null 2>&1 ||
    die "the claude CLI is required (or run the skill interactively via" \
        "your agent session instead)"
command -v gh >/dev/null 2>&1 || die "the gh CLI is required"
claude --help 2>/dev/null | grep -q -- "--setting-sources" ||
    die "this claude CLI lacks --setting-sources; refusing to launch the" \
        "worker with the repo's settings grants in effect — upgrade the CLI"

# Resolve the skill wherever this checkout carries it: authored source in
# harmon-devkit itself, vendored copies in consumers.
skill_dir=""
for d in ai/skills/universal/triage .agents/skills/triage \
    .claude/skills/triage; do
    if [ -f "$d/SKILL.md" ]; then
        skill_dir="$d"
        break
    fi
done
[ -n "$skill_dir" ] || die "no triage skill found in this checkout"

repo="$(gh repo view "$(git remote get-url origin)" \
    --json nameWithOwner -q .nameWithOwner)" ||
    die "could not resolve the GitHub repo from the origin remote"
# Bind the run to this repository: the write scripts refuse any --repo that
# differs, so a prompt-injected worker cannot aim an authorized script at a
# different repository it happens to have credentials for.
export TRIAGE_REPO="$repo"

# The worker gets no mktemp and no general Write: the wrapper owns the scratch
# directory, the Write grant below is scoped to it, and triage-report.sh
# refuses an entries file outside it — so the report can only ever publish
# run-generated content, never an arbitrary readable file.
scratch="$(mktemp -d)" || die "could not create a scratch directory"
export TRIAGE_SCRATCH="$scratch"
# Scratch holds scan.json (issue metadata); do not let runs accumulate it.
trap 'rm -rf "$scratch"' EXIT

if [ "$mode" = "execute" ]; then
    # Supervised runs only: a human must be watching (v1's [HUMAN] gate). The
    # supervision flow is dry-run -> review -> execute; the confirmation below
    # makes skipping the review a deliberate act rather than a default.
    [ -t 0 ] && [ -t 1 ] ||
        die "--execute needs an interactive terminal — supervised runs only"
    printf 'triage: EXECUTE will write labels and the rolling report in %s.\n' \
        "$repo"
    printf 'triage: review a dry-run first if you have not. Type "yes": '
    IFS= read -r reply
    [ "$reply" = "yes" ] || die "execute not confirmed"
    export TRIAGE_EXECUTE=1
    mode_text="EXECUTE — a human is supervising. You may pass --execute to a
triage script exactly where SKILL.md says to, and nowhere else."
else
    export TRIAGE_EXECUTE=0
    mode_text="DRY-RUN — never pass --execute to any script. Report what the
scripts say they WOULD write."
fi

# Reads are scoped like the writes: the worker may read its own scratch and
# the skill it is executing, nothing else on disk — file contents outside
# those trees must never be copyable into a published report entry. Glob/Grep
# are omitted entirely; scan.json is the worker's data.
skill_abs="$(cd "$skill_dir" && pwd)"
tools="Read(//${scratch#/}/**),Read(//${skill_abs#/}/**)"
tools="$tools,Write(//${scratch#/}/**)"
tools="$tools,Bash($skill_dir/assets/triage-scan.sh:*)"
tools="$tools,Bash($skill_dir/assets/triage-apply.sh:*)"
tools="$tools,Bash($skill_dir/assets/triage-report.sh:*)"
tools="$tools,Bash(gh issue view:*),Bash(gh issue list:*)"

prompt="You are running the triage skill headlessly over one repository.

Repo: $repo
Skill: $skill_dir/SKILL.md
Scratch directory (already created — write scan.json and entries.md here;
do not run mktemp): $scratch
Mode: $mode_text

Read the skill file and follow its steps exactly, in order. Use only the
tools you were granted. Finish with the summary its final step defines."
if [ -n "$note" ]; then
    prompt="$prompt

Operator note (from the human who launched this run): $note"
fi

# --setting-sources "" launches the worker with NO settings files loaded:
# --allowedTools only ever adds grants, and this repo's own settings allow
# e.g. Bash(task:*), which would hand a prompt-injected worker tools far
# outside the three guarded scripts. Not exec'd: the EXIT trap above must
# still remove the scratch directory.
# --tools restricts which built-ins EXIST for the worker (permission rules
# alone cannot remove default-allowed tools); the allow/disallow rules then
# scope the three that remain.
claude -p "$prompt" \
    --model "${TRIAGE_MODEL:-haiku}" \
    --setting-sources "" \
    --tools "Read,Write,Bash" \
    --allowedTools "$tools" \
    --disallowedTools "Glob,Grep"
