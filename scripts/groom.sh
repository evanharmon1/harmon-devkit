#!/usr/bin/env bash
# groom.sh — `task groom` entry point: run the groom skill's audit mode over
# this repo's backlog, or apply an already-approved plan. Mirrors
# scripts/triage.sh's contract:
#
#   - AUDIT is the default. GROOM_EXECUTE is forced to 0, so even a model
#     that passes --execute to a script is refused by the script itself.
#     Audit fans out read-only subagents (Agent/Task/Glob/Grep granted) to
#     verify claims against the live code — this is the ONLY mode that ever
#     reads untrusted issue text, and the only mode that ever runs a model at
#     all, so its own tool grant carries no write-capable script (issue #1015
#     finding 10 / challenge round 1; challenge round 2 finding 7 — a fan-out
#     session has no business calling groom-apply.sh/groom-decide.sh, since
#     it never runs with GROOM_EXECUTE=1 anyway).
#   - `task groom -- --run DIR --plan FILE [--decisions DIR] [--execute]` is
#     apply mode: a deterministic, model-free sequence over an already-
#     approved plan — no Claude session, no tool grant, no prompt to bind
#     (challenge round 2 findings 1 and 2, replacing the earlier headless
#     `claude -p` apply worker that round 1/finding 10 had to sandbox by tool
#     grant alone — a prompt-injected finding now has no model in the write
#     path to inject at all). `--run DIR` names the AUDIT run whose output
#     this applies against (the directory that already holds
#     `dispositions.json`); omitting `--execute` dry-runs the exact same
#     sequence, printing PLAN lines and writing nothing. `--execute`
#     additionally requires an interactive terminal and an explicit "yes"
#     confirmation, exactly like triage.sh's --execute path.
#
# Unlike triage (a cheap classifier working only from a precomputed scan),
# groom verifies claims against the live code and merged PRs and fans out
# read-only subagents to do it (issue #1015) — it needs a broader tool grant
# and a model capable of that judgment, so the default model is NOT triage's
# cheap default. That grant and model exist only for audit mode; apply mode
# runs no model.
#
# An operator note (free text, after the recognized flags) is appended to the
# AUDIT prompt verbatim, e.g.:
#   task groom                                       # audit
#   task groom -- only the ci/* cluster              # audit, with a note
#   task groom -- --run "$SCRATCH" --plan plan.jsonl \
#       --decisions decisions/                       # apply, dry-run
#   task groom -- --execute --run "$SCRATCH" \
#       --plan plan.jsonl --decisions decisions/     # apply, execute
#
# Env: GROOM_MODEL (default: sonnet) picks the AUDIT model.
#      GROOM_OUT_DIR (default: $HOME/.local/state/harmon-groom) is the root
#      an audit run's persistent output directory is created under, as
#      `mktemp -d "$GROOM_OUT_DIR/<owner>-<repo>/run.XXXXXX"` (mode 0700 —
#      issue #1015 challenge round 2 findings 6 and 9), never removed by this
#      script.
#
# Exit: 2 = environment/usage refusal, otherwise the apply sequence's (apply
#       mode) or the model run's (audit mode) exit code.
set -euo pipefail
cd "$(dirname "$0")/.."

die() {
    echo "groom: $*" >&2
    exit 2
}

mode="audit"
plan=""
run_dir=""
decisions_dir=""
execute=0
note=""
while [ "$#" -gt 0 ]; do
    case "$1" in
    --execute)
        execute=1
        shift
        ;;
    --plan)
        [ "$#" -ge 2 ] || die "--plan needs a path"
        plan="$2"
        shift 2
        ;;
    --run)
        [ "$#" -ge 2 ] || die "--run needs a path"
        run_dir="$2"
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

if [ "$execute" -eq 1 ] || [ -n "$plan" ] || [ -n "$run_dir" ]; then
    mode="apply"
fi

if [ "$mode" = "apply" ]; then
    [ -n "$run_dir" ] ||
        die "apply mode requires --run DIR — the audit run's output" \
            "directory (see ai/skills/universal/groom/SKILL.md Step 6)"
    [ -d "$run_dir" ] || die "cannot read run directory: $run_dir"
    [ -n "$plan" ] ||
        die "apply mode requires --plan FILE — a human-approved plan JSONL" \
            "(see ai/skills/universal/groom/SKILL.md Step 6)"
    [ -r "$plan" ] || die "cannot read plan file: $plan"
    [ -z "$decisions_dir" ] || [ -d "$decisions_dir" ] ||
        die "cannot read decisions directory: $decisions_dir"
fi

command -v gh >/dev/null 2>&1 || die "the gh CLI is required"

if [ "$mode" = "audit" ]; then
    command -v claude >/dev/null 2>&1 ||
        die "the claude CLI is required (or run the skill interactively via" \
            "your agent session instead)"
    grep -q -- "--setting-sources" < <(claude --help 2>/dev/null) ||
        die "this claude CLI lacks --setting-sources; refusing to launch the" \
            "worker with the repo's settings grants in effect — upgrade the CLI"
fi

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

if [ "$mode" = "audit" ]; then
    # The report this whole workflow exists to produce must survive the
    # wrapper process. A scratch dir cleaned up on EXIT (the earlier design)
    # deletes it before the maintainer ever reads it — the model's only
    # writable path and the wrapper's own trap raced each other, and the trap
    # always won (issue #1015 finding 1). Every run instead gets its own
    # persistent directory that is never removed by this script, created with
    # mktemp -d (portable, and 0700 by default — challenge round 2 findings 6
    # and 9: the earlier `mkdir -p` + hand-rolled `date +%N` timestamp both
    # left the directory world-readable under a normal umask and, on a
    # platform whose `date` has no %N, collision-prone).
    owner_repo_dir="$(printf '%s' "$repo" | tr '/' '-')"
    out_root="${GROOM_OUT_DIR:-$HOME/.local/state/harmon-groom}"
    mkdir -p -m 700 "$out_root" ||
        die "could not create the output root: $out_root"
    mkdir -p -m 700 "$out_root/$owner_repo_dir" ||
        die "could not create the repo's output directory:" \
            "$out_root/$owner_repo_dir"
    run_dir="$(mktemp -d "$out_root/$owner_repo_dir/run.XXXXXX")" ||
        die "could not create the run's output directory"
fi
export GROOM_SCRATCH="$run_dir"

report_html="$run_dir/report.html"
report_md="$run_dir/report.md"
print_outputs() {
    printf 'groom: run output directory: %s\n' "$run_dir" >&2
    printf 'groom: report (if this run produced one): %s\n' "$report_html" >&2
    printf 'groom:                              and: %s\n' "$report_md" >&2
}
trap print_outputs EXIT

if [ "$mode" = "apply" ]; then
    if [ "$execute" -eq 1 ]; then
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
    else
        export GROOM_EXECUTE=0
        printf 'groom: DRY RUN — printing PLAN lines for %s, nothing will be written.\n' \
            "$plan" >&2
    fi

    # Deterministic, model-free apply sequence (challenge round 2 findings 1
    # and 2): groom-apply.sh for the plan file, groom-decide.sh once per
    # decision file, then a re-render of the SAME dispositions dataset this
    # audit run produced, with the outcomes just written merged in. No model,
    # no tool grant, no prompt anywhere in this branch.
    execute_flag=()
    [ "$execute" -eq 1 ] && execute_flag=(--execute)

    "$skill_dir/assets/groom-apply.sh" apply-plan --repo "$repo" \
        --plan-file "$plan" --log "$run_dir/apply.log" \
        --outcomes "$run_dir/outcomes.jsonl" "${execute_flag[@]+"${execute_flag[@]}"}"

    if [ -n "$decisions_dir" ]; then
        shopt -s nullglob
        for decision_file in "$decisions_dir"/*.md; do
            issue="$(basename "$decision_file" .md)"
            case "$issue" in
            '' | *[!0-9]*)
                die "decision file must be named <issue-number>.md (got" \
                    "'$(basename "$decision_file")')"
                ;;
            esac
            supersedes_args=()
            blocked_by_args=()
            if [ -f "$decisions_dir/$issue.supersedes" ]; then
                while IFS= read -r m; do
                    [ -n "$m" ] || continue
                    supersedes_args+=(--supersedes "$m")
                done <"$decisions_dir/$issue.supersedes"
            fi
            if [ -f "$decisions_dir/$issue.blocked-by" ]; then
                while IFS= read -r k; do
                    [ -n "$k" ] || continue
                    blocked_by_args+=(--blocked-by "$k")
                done <"$decisions_dir/$issue.blocked-by"
            fi
            "$skill_dir/assets/groom-decide.sh" --repo "$repo" --issue "$issue" \
                --decision-file "$decision_file" \
                "${supersedes_args[@]+"${supersedes_args[@]}"}" \
                "${blocked_by_args[@]+"${blocked_by_args[@]}"}" \
                --outcomes "$run_dir/outcomes.jsonl" "${execute_flag[@]+"${execute_flag[@]}"}"
        done
        shopt -u nullglob
    fi

    # groom-report.sh render requires --outcomes to be readable when given;
    # a dry run (or an execute run with nothing yet applied) never creates
    # the file, so ensure it exists — without ever truncating a real one
    # from an earlier apply against this same --run directory.
    [ -f "$run_dir/outcomes.jsonl" ] || : >"$run_dir/outcomes.jsonl"

    "$skill_dir/assets/groom-report.sh" render \
        --dispositions "$run_dir/dispositions.json" \
        --outcomes "$run_dir/outcomes.jsonl" \
        --out-html "$report_html" --out-md "$report_md"

    exit 0
fi

# ── AUDIT mode from here down: fan out a headless Claude session. ──────────
export GROOM_EXECUTE=0
mode_text="AUDIT — never pass --execute to any script. Report what the
scripts say they WOULD write."

skill_abs="$(cd "$skill_dir" && pwd)"
tools="Read(//${run_dir#/}/**),Read(//${skill_abs#/}/**)"
tools="$tools,Write(//${run_dir#/}/**)"
gh_read_tools="Bash(gh issue view:*),Bash(gh issue list:*)"
gh_read_tools="$gh_read_tools,Bash(gh pr view:*),Bash(gh pr list:*)"
tools="$tools,Bash($skill_dir/assets/groom-scan.sh:*)"
tools="$tools,Bash($skill_dir/assets/groom-verdicts.sh:*)"
tools="$tools,Bash($skill_dir/assets/groom-report.sh:*)"
tools="$tools,$gh_read_tools"
tools="$tools,Agent,Task,Glob,Grep"
claude_tools="Read,Write,Bash,Agent,Task,Glob,Grep"

prompt="You are running the groom skill's AUDIT mode headlessly over one repository.

Repo: $repo
Skill: $skill_dir/SKILL.md
Scratch directory (already created — write every dataset and report file
here; do not run mktemp): $run_dir
Mode: $mode_text

Read the skill file and follow its steps exactly, in order. Stop at Step 5
(the maintainer pass) — apply mode is a separate, model-free run
(task groom -- --execute --run DIR --plan FILE) that a human runs directly;
it has no tool grant here. Use only the tools you were granted. Finish with
the summary its final step defines."
if [ -n "$note" ]; then
    prompt="$prompt

Operator note (from the human who launched this run): $note"
fi

claude -p "$prompt" \
    --model "${GROOM_MODEL:-sonnet}" \
    --setting-sources "" \
    --tools "$claude_tools" \
    --allowedTools "$tools"
