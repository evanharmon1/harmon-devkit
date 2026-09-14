#!/usr/bin/env bash
# groom.sh — `task groom` entry point: run the groom skill's audit mode over
# this repo's backlog. Mirrors scripts/triage.sh's contract:
#
#   - DRY-RUN (audit) is the default. GROOM_EXECUTE is forced to 0, so even a
#     model that passes --execute to a script is refused by the script itself.
#   - `task groom -- --execute` is the supervised apply mode. It requires an
#     interactive terminal and an explicit confirmation, exactly like
#     triage.sh's --execute path — apply writes labels, closes issues, edits
#     milestones, and posts decision comments.
#
# Unlike triage (a cheap classifier working only from a precomputed scan),
# groom verifies claims against the live code and merged PRs and fans out
# read-only subagents to do it (issue #1015) — it needs a broader tool grant
# and a model capable of that judgment, so the default model is NOT triage's
# cheap default.
#
# Anything after --execute (or all args, without it) is passed to the model as
# an operator note, e.g.: task groom -- --execute only the ci/* cluster
#
# Env: GROOM_MODEL (default: sonnet) picks the model.
#
# Exit: 2 = environment/usage refusal, otherwise the model run's exit code.
set -euo pipefail
cd "$(dirname "$0")/.."

die() {
    echo "groom: $*" >&2
    exit 2
}

mode="audit"
note=""
if [ "${1:-}" = "--execute" ]; then
    mode="apply"
    shift
fi
[ "$#" -eq 0 ] || note="$*"

command -v claude >/dev/null 2>&1 ||
    die "the claude CLI is required (or run the skill interactively via" \
        "your agent session instead)"
command -v gh >/dev/null 2>&1 || die "the gh CLI is required"
grep -q -- "--setting-sources" < <(claude --help 2>/dev/null) ||
    die "this claude CLI lacks --setting-sources; refusing to launch the" \
        "worker with the repo's settings grants in effect — upgrade the CLI"

skill_dir=""
for d in ai/skills/universal/groom .agents/skills/groom .claude/skills/groom; do
    if [ -f "$d/SKILL.md" ]; then
        skill_dir="$d"
        break
    fi
done
[ -n "$skill_dir" ] || die "no groom skill found in this checkout"

repo="$(gh repo view "$(git remote get-url origin)" \
    --json nameWithOwner -q .nameWithOwner)" ||
    die "could not resolve the GitHub repo from the origin remote"
export GROOM_REPO="$repo"

scratch="$(mktemp -d)" || die "could not create a scratch directory"
export GROOM_SCRATCH="$scratch"
trap 'rm -rf "$scratch"' EXIT

if [ "$mode" = "apply" ]; then
    [ -t 0 ] && [ -t 1 ] ||
        die "--execute needs an interactive terminal — supervised runs only"
    printf 'groom: EXECUTE will close/retitle/relabel issues, edit milestones,\n'
    printf 'and post decision comments in %s.\n' "$repo"
    printf 'groom: review a dry-run report first if you have not. Type "yes": '
    IFS= read -r reply
    [ "$reply" = "yes" ] || die "execute not confirmed"
    export GROOM_EXECUTE=1
    mode_text="APPLY — a human is supervising. You may pass --execute to a
groom script exactly where SKILL.md says to, and nowhere else."
else
    export GROOM_EXECUTE=0
    mode_text="AUDIT — never pass --execute to any script. Report what the
scripts say they WOULD write."
fi

skill_abs="$(cd "$skill_dir" && pwd)"
tools="Read(//${scratch#/}/**),Read(//${skill_abs#/}/**)"
tools="$tools,Write(//${scratch#/}/**)"
tools="$tools,Bash($skill_dir/assets/groom-scan.sh:*)"
tools="$tools,Bash($skill_dir/assets/groom-verdicts.sh:*)"
tools="$tools,Bash($skill_dir/assets/groom-report.sh:*)"
tools="$tools,Bash($skill_dir/assets/groom-apply.sh:*)"
tools="$tools,Bash($skill_dir/assets/groom-decide.sh:*)"
tools="$tools,Bash(gh issue view:*),Bash(gh issue list:*)"
tools="$tools,Bash(gh pr view:*),Bash(gh pr list:*)"
tools="$tools,Agent,Task,Glob,Grep"

prompt="You are running the groom skill's $mode mode headlessly over one repository.

Repo: $repo
Skill: $skill_dir/SKILL.md
Scratch directory (already created — write every dataset and report file
here; do not run mktemp): $scratch
Mode: $mode_text

Read the skill file and follow its steps exactly, in order. Stop at Step 5
(the maintainer pass) unless your mode is APPLY and an operator note below
names what was approved. Use only the tools you were granted. Finish with the
summary its final step defines."
if [ -n "$note" ]; then
    prompt="$prompt

Operator note (from the human who launched this run): $note"
fi

claude -p "$prompt" \
    --model "${GROOM_MODEL:-sonnet}" \
    --setting-sources "" \
    --tools "Read,Write,Bash,Agent,Task,Glob,Grep" \
    --allowedTools "$tools"
