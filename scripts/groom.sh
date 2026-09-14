#!/usr/bin/env bash
# groom.sh — `task groom` entry point: run the groom skill's audit mode over
# this repo's backlog. Mirrors scripts/triage.sh's contract:
#
#   - AUDIT is the default. GROOM_EXECUTE is forced to 0, so even a model
#     that passes --execute to a script is refused by the script itself.
#     Audit fans out read-only subagents (Agent/Task/Glob/Grep granted) to
#     verify claims against the live code — this is the ONLY mode that ever
#     reads untrusted issue text, so it never has write tools armed.
#   - `task groom -- --execute --plan FILE [--decisions DIR]` is the
#     supervised apply mode. It requires an interactive terminal and an
#     explicit confirmation, exactly like triage.sh's --execute path, AND a
#     human-approved plan file to execute — apply mode grants only the
#     write-capable scripts (groom-apply.sh, groom-decide.sh, groom-
#     report.sh) plus read-only gh calls; no Agent, Task, Glob, or Grep, so a
#     prompt-injected finding from an earlier audit run has no path to a live
#     write here (issue #1015 finding 10 / challenge round 1).
#
# Unlike triage (a cheap classifier working only from a precomputed scan),
# groom verifies claims against the live code and merged PRs and fans out
# read-only subagents to do it (issue #1015) — it needs a broader tool grant
# and a model capable of that judgment, so the default model is NOT triage's
# cheap default.
#
# An operator note (free text, after the recognized flags) is appended to the
# prompt verbatim, e.g.:
#   task groom                                      # audit
#   task groom -- only the ci/* cluster             # audit, with a note
#   task groom -- --execute --plan plan.jsonl \
#       --decisions decisions/ apply batch 2 only   # apply, with a note
#
# Env: GROOM_MODEL (default: sonnet) picks the model.
#      GROOM_OUT_DIR (default: $HOME/.local/state/harmon-groom) is the root
#      the run's persistent output directory is created under.
#
# Exit: 2 = environment/usage refusal, otherwise the model run's exit code.
set -euo pipefail
cd "$(dirname "$0")/.."

die() {
    echo "groom: $*" >&2
    exit 2
}

mode="audit"
plan=""
decisions_dir=""
note=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --execute)
        mode="apply"
        shift
        ;;
    --plan)
        [ "$#" -ge 2 ] || die "--plan needs a path"
        plan="$2"
        shift 2
        ;;
    --decisions)
        [ "$#" -ge 2 ] || die "--decisions needs a path"
        decisions_dir="$2"
        shift 2
        ;;
    *) break ;;
    esac
done
[ "$#" -eq 0 ] || note="$*"

if [ "$mode" = "apply" ]; then
    [ -n "$plan" ] ||
        die "--execute requires --plan FILE — a human-approved plan JSONL" \
            "(see ai/skills/universal/groom/SKILL.md Step 6)"
    [ -r "$plan" ] || die "cannot read plan file: $plan"
    [ -z "$decisions_dir" ] || [ -d "$decisions_dir" ] ||
        die "cannot read decisions directory: $decisions_dir"
fi

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

# The report this whole workflow exists to produce must survive the wrapper
# process. A scratch dir cleaned up on EXIT (the earlier design) deletes it
# before the maintainer ever reads it — the model's only writable path and
# the wrapper's own trap raced each other, and the trap always won (issue
# #1015 finding 1). Every run instead gets its own persistent, timestamped
# directory that is never removed by this script.
owner_repo_dir="$(printf '%s' "$repo" | tr '/' '-')"
# Nanosecond precision (still a plain UTC timestamp) so two runs launched in
# the same second never collide on one output directory.
run_timestamp="$(date -u '+%Y%m%dT%H%M%S.%NZ')"
out_root="${GROOM_OUT_DIR:-$HOME/.local/state/harmon-groom}"
scratch="$out_root/$owner_repo_dir/$run_timestamp"
mkdir -p "$scratch" || die "could not create the run's output directory: $scratch"
export GROOM_SCRATCH="$scratch"

report_html="$scratch/report.html"
report_md="$scratch/report.md"
print_outputs() {
    printf 'groom: run output directory: %s\n' "$scratch" >&2
    printf 'groom: report (Step 4, if this run reached it): %s\n' "$report_html" >&2
    printf 'groom:                                     and: %s\n' "$report_md" >&2
}
trap print_outputs EXIT

if [ "$mode" = "apply" ]; then
    [ -t 0 ] && [ -t 1 ] ||
        die "--execute needs an interactive terminal — supervised runs only"
    printf 'groom: EXECUTE will apply the approved plan %s\n' "$plan"
    [ -z "$decisions_dir" ] ||
        printf 'groom: and record the decisions in %s\n' "$decisions_dir"
    printf 'groom: (close/retitle/relabel issues, edit milestones, post decision\n'
    printf 'groom: comments) in %s.\n' "$repo"
    printf 'groom: review a dry-run of that plan first if you have not. Type "yes": '
    IFS= read -r reply
    [ "$reply" = "yes" ] || die "execute not confirmed"
    export GROOM_EXECUTE=1
    mode_text="APPLY — a human is supervising. Execute EXACTLY the plan and
decisions named below, nothing else. You may pass --execute to groom-
apply.sh/groom-decide.sh exactly where SKILL.md Step 6 says to."
else
    export GROOM_EXECUTE=0
    mode_text="AUDIT — never pass --execute to any script. Report what the
scripts say they WOULD write."
fi

skill_abs="$(cd "$skill_dir" && pwd)"
tools="Read(//${scratch#/}/**),Read(//${skill_abs#/}/**)"
tools="$tools,Write(//${scratch#/}/**)"
gh_read_tools="Bash(gh issue view:*),Bash(gh issue list:*)"
gh_read_tools="$gh_read_tools,Bash(gh pr view:*),Bash(gh pr list:*)"

if [ "$mode" = "apply" ]; then
    # start apply-mode tool grant (issue #1015 finding 10 — asserted in
    # scripts/test-groom-skill.sh by extracting exactly this marked block,
    # since the interactive --execute confirmation below prevents a test
    # from reaching this point live). Apply mode never fans out and never
    # re-reads issue bodies — it only executes an already-approved
    # plan/decisions set — so it gets no Agent/Task/Glob/Grep and no
    # scan/verdicts scripts. Read is also scoped to the plan/decisions paths
    # so the model can load them without a general filesystem grant.
    plan_abs="$(cd "$(dirname "$plan")" && pwd)/$(basename "$plan")"
    tools="$tools,Read(//${plan_abs#/})"
    if [ -n "$decisions_dir" ]; then
        decisions_abs="$(cd "$decisions_dir" && pwd)"
        tools="$tools,Read(//${decisions_abs#/}/**)"
    fi
    tools="$tools,Bash($skill_dir/assets/groom-apply.sh:*)"
    tools="$tools,Bash($skill_dir/assets/groom-decide.sh:*)"
    tools="$tools,Bash($skill_dir/assets/groom-report.sh:*)"
    tools="$tools,$gh_read_tools"
    claude_tools="Read,Write,Bash"
    # end apply-mode tool grant
else
    tools="$tools,Bash($skill_dir/assets/groom-scan.sh:*)"
    tools="$tools,Bash($skill_dir/assets/groom-verdicts.sh:*)"
    tools="$tools,Bash($skill_dir/assets/groom-report.sh:*)"
    tools="$tools,Bash($skill_dir/assets/groom-apply.sh:*)"
    tools="$tools,Bash($skill_dir/assets/groom-decide.sh:*)"
    tools="$tools,$gh_read_tools"
    tools="$tools,Agent,Task,Glob,Grep"
    claude_tools="Read,Write,Bash,Agent,Task,Glob,Grep"
fi

if [ "$mode" = "apply" ]; then
    prompt="You are running the groom skill's APPLY mode headlessly over one repository.

Repo: $repo
Skill: $skill_dir/SKILL.md
Scratch directory (already created — write the re-rendered report and
outcomes file here; do not run mktemp): $scratch
Plan file (human-approved — apply exactly this and nothing else): $plan
Decisions directory (one <issue>.md per decision, plus optional
<issue>.supersedes / <issue>.blocked-by lists naming one issue number per
line): ${decisions_dir:-none this run}
Mode: $mode_text

Follow SKILL.md Step 6 exactly: dry-run the plan and every decision first,
review the PLAN lines against what was approved, then re-run each with
--execute and --outcomes $scratch/outcomes.jsonl. Re-render the report with
groom-report.sh render --outcomes $scratch/outcomes.jsonl so it reflects
what was applied, then republish it (same Artifact URL, or the committed
path, per Step 4). Use only the tools you were granted — do not verify or
read any issue beyond what the plan and decisions name. Finish with the
summary SKILL.md's final step defines."
else
    prompt="You are running the groom skill's AUDIT mode headlessly over one repository.

Repo: $repo
Skill: $skill_dir/SKILL.md
Scratch directory (already created — write every dataset and report file
here; do not run mktemp): $scratch
Mode: $mode_text

Read the skill file and follow its steps exactly, in order. Stop at Step 5
(the maintainer pass) — apply mode is a separate, supervised run
(task groom -- --execute --plan FILE) with its own tool grant. Use only the
tools you were granted. Finish with the summary its final step defines."
fi
if [ -n "$note" ]; then
    prompt="$prompt

Operator note (from the human who launched this run): $note"
fi

claude -p "$prompt" \
    --model "${GROOM_MODEL:-sonnet}" \
    --setting-sources "" \
    --tools "$claude_tools" \
    --allowedTools "$tools"
