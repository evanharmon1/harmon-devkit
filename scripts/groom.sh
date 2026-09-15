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
#   - `task groom -- --execute <script> [args…]` is apply mode: exec exactly
#     ONE named groom script with the operator's own arguments — nothing
#     else. `<script>` must be one of `groom-apply.sh`, `groom-decide.sh`, or
#     `groom-report.sh` (resolved under the skill's own assets/ directory);
#     any other name is refused. There is no orchestration left in this
#     wrapper to attack: it never reads a run directory, never loops over a
#     decisions directory, and never re-renders a report itself — the
#     operator runs each of the three commands directly, in the order
#     ai/skills/universal/groom/SKILL.md Step 6 gives, and the remaining
#     arguments after the script name are forwarded to it verbatim (challenge
#     round 3, deleting the --run/--plan/--decisions orchestration challenge
#     round 2 findings 1 and 2 had added — that orchestration's own
#     validation gaps, partial-apply hazards, and lost --max-closes
#     passthrough are moot once there is no orchestration left to have those
#     gaps). `groom-apply.sh` and `groom-decide.sh` still require an
#     interactive terminal and an explicit "yes" confirmation before
#     anything runs, then export `GROOM_EXECUTE=1`, the same as triage.sh's
#     --execute path; whether either performs a real write is entirely up to
#     whether ITS OWN --execute is present in the forwarded arguments
#     (dry-run a script by omitting its own trailing --execute).
#     `groom-report.sh` is exec'd directly instead, with none of that: no
#     interactive-terminal requirement, no confirmation prompt, and no
#     `GROOM_EXECUTE` export — it never writes to GitHub and reads no gate
#     (challenge round 2 confirming round, finding 4). It also runs BEFORE
#     this wrapper resolves the GitHub repo below, so rendering an
#     already-applied run's local dispositions/outcomes keeps working during
#     a GitHub outage or an expired `gh` session — it never needed
#     `GROOM_REPO` (cmd_render never reads it) and never saw it (Codex review
#     on PR #1032, comment 4012242636).
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
#   task groom -- --execute groom-apply.sh apply-plan --repo owner/repo \
#       --plan-file "$SCRATCH/plan.jsonl" --log "$SCRATCH/apply.log" \
#       --outcomes "$SCRATCH/outcomes.jsonl"          # apply, dry-run
#   task groom -- --execute groom-apply.sh apply-plan --repo owner/repo \
#       --plan-file "$SCRATCH/plan.jsonl" --log "$SCRATCH/apply.log" \
#       --outcomes "$SCRATCH/outcomes.jsonl" --execute # apply, execute
#
# Env: GROOM_MODEL (default: sonnet) picks the AUDIT model — the
#      coordinating session that reads SKILL.md and fans out Step 2's
#      cluster subagents.
#      GROOM_FANOUT_MODEL (default: opus) picks the model each Step 2
#      cluster subagent is dispatched on — independent of GROOM_MODEL, so
#      raising the coordinating session's own tier (a harder backlog, an
#      operator's preference) does not silently multiply that cost across
#      every fan-out subagent too, and so the fan-out step (the run's real
#      verification judgment) defaults to a stronger tier than the
#      comparatively mechanical coordinating session does (issue #1044).
#      Forwarded to the coordinating session as an explicit instruction;
#      SKILL.md Step 2 carries the same default for the interactive path,
#      where no wrapper prompt exists to forward it.
#      GROOM_OUT_DIR (default: $HOME/.local/state) names the CALLER'S root —
#      a directory this script does not own and never chmods, only creates
#      if missing (refused if it exists and is not a directory). Every audit
#      run's persistent output directory is created under a groom-owned
#      child of that root, `$GROOM_OUT_DIR/harmon-groom`, as
#      `mktemp -d ".../harmon-groom/<owner>-<repo>/run.XXXXXX"` — only that
#      child and the directories under it (never the caller's own root) are
#      secured to mode 0700 (issue #1015 challenge round 2 findings 6 and 9,
#      re-applied even when they already existed from an older, looser-mode
#      run — challenge round 3 finding 5). A GROOM_OUT_DIR pointed at a
#      directory the caller owns and shares with others — even the system
#      temp directory — must never have ITS OWN mode changed by this script
#      (Codex review on PR #1032, comment 4012242612). A pre-existing
#      "harmon-groom" child (or repo subdirectory under it) is refused
#      outright unless it is a real, non-symlink directory already owned by
#      the current user and not group/world-writable — `mkdir -p` and a bare
#      `chmod` both otherwise follow a symlink another user could plant at
#      that predictable path in a shared root, letting this script chmod and
#      populate an arbitrary target (Codex review on PR #1032, comment
#      4012885475). Never removed by this script.
#
# Exit: 2 = environment/usage refusal, otherwise the named script's exit code
#       (apply mode) or the model run's exit code (audit mode).
set -euo pipefail
cd "$(dirname "$0")/.."

die() {
    echo "groom: $*" >&2
    exit 2
}

# Create (or re-secure) a directory THIS SCRIPT owns, refusing anything
# already there that is not a real, currently-owned, non-group/world-writable
# directory (Codex review on PR #1032, comment 4012885475). Without this, a
# shared location such as the documented GROOM_OUT_DIR=/tmp example lets
# another user precreate the predictable "harmon-groom" child as a symlink to
# a directory the eventual caller can modify: `mkdir -p` follows the symlink
# (a no-op, since the target already "exists"), and a bare `chmod 700` then
# follows it too, changing the TARGET's mode — so a root-run groom could
# chmod and populate an arbitrary attacker-chosen directory even though the
# whole point of this helper is to secure only directories groom itself
# created. `mkdir` (no -p) is used for the create case so it fails outright
# on a concurrent creator instead of silently succeeding on someone else's
# directory.
secure_owned_dir() {
    local dir="$1" desc="$2"
    if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
        mkdir "$dir" || die "could not create $desc: $dir"
    else
        [ ! -L "$dir" ] ||
            die "refused: $desc already exists and is a symlink: $dir"
        [ -d "$dir" ] ||
            die "refused: $desc already exists and is not a directory: $dir"
        [ -O "$dir" ] ||
            die "refused: $desc already exists and is not owned by the" \
                "current user: $dir"
        local mode_str
        mode_str="$(ls -ld "$dir" | cut -c1-10)"
        if [ "${mode_str:5:1}" != "-" ] || [ "${mode_str:8:1}" != "-" ]; then
            die "refused: $desc already exists and is group- or" \
                "world-writable: $dir"
        fi
    fi
    chmod 700 "$dir" || die "could not secure $desc: $dir"
}

allowed_apply_scripts="groom-apply.sh, groom-decide.sh, groom-report.sh"

mode="audit"
apply_script=""
note=""

if [ "$#" -ge 1 ] && [ "$1" = "--execute" ]; then
    mode="apply"
    shift
    [ "$#" -ge 1 ] ||
        die "--execute needs a script name — one of: $allowed_apply_scripts"
    apply_script="$1"
    shift
    case "$apply_script" in
    groom-apply.sh | groom-decide.sh | groom-report.sh) ;;
    *)
        die "unknown script '$apply_script' — apply mode runs exactly one" \
            "of: $allowed_apply_scripts"
        ;;
    esac
else
    [ "$#" -eq 0 ] || note="$*"
fi

command -v gh >/dev/null 2>&1 || die "the gh CLI is required"

skill_dir=""
for d in ai/skills/universal/groom .agents/skills/groom .claude/skills/groom; do
    if [ -f "$d/SKILL.md" ]; then
        skill_dir="$d"
        break
    fi
done
[ -n "$skill_dir" ] || die "no groom skill found in this checkout"

# groom-report.sh runs BEFORE repository resolution below (Codex review on
# PR #1032, comment 4012242636): it is read-only, writes only to the two
# output files named on its own command line, never touches GitHub, and
# never reads GROOM_REPO, so gating it behind `gh repo view` made an
# already-applied run's local report un-renderable during a GitHub outage or
# an expired gh session for no reason the script itself needed. It carries
# none of the write gate either: no tty requirement, no confirmation prompt,
# and no GROOM_EXECUTE export (challenge round 2 confirming round, finding 4).
if [ "$mode" = "apply" ] && [ "$apply_script" = "groom-report.sh" ]; then
    exec "$skill_dir/assets/$apply_script" "$@"
fi

if [ "$mode" = "audit" ]; then
    command -v claude >/dev/null 2>&1 ||
        die "the claude CLI is required (or run the skill interactively via" \
            "your agent session instead)"
    grep -q -- "--setting-sources" < <(claude --help 2>/dev/null) ||
        die "this claude CLI lacks --setting-sources; refusing to launch the" \
            "worker with the repo's settings grants in effect — upgrade the CLI"
fi

repo="$(gh repo view "$(git remote get-url origin)" \
    --json nameWithOwner -q .nameWithOwner)" ||
    die "could not resolve the GitHub repo from the origin remote"
export GROOM_REPO="$repo"

if [ "$mode" = "apply" ]; then
    [ -t 0 ] && [ -t 1 ] ||
        die "--execute needs an interactive terminal — supervised runs only"
    printf 'groom: EXECUTE will run %s in %s with GROOM_EXECUTE=1 —\n' \
        "$apply_script" "$repo"
    printf 'groom: whether it writes for real is up to its OWN --execute flag\n'
    printf 'groom: (in the arguments you gave). Review a dry-run first (omit\n'
    printf 'groom: the script'"'"'s own --execute) if you have not.\n'
    printf 'groom: Type "yes": '
    IFS= read -r reply
    [ "$reply" = "yes" ] || die "execute not confirmed"
    export GROOM_EXECUTE=1
    exec "$skill_dir/assets/$apply_script" "$@"
fi

# ── AUDIT mode from here down: fan out a headless Claude session. ──────────

# The report this whole workflow exists to produce must survive the wrapper
# process. A scratch dir cleaned up on EXIT (the earlier design) deletes it
# before the maintainer ever reads it — the model's only writable path and
# the wrapper's own trap raced each other, and the trap always won (issue
# #1015 finding 1). Every run instead gets its own persistent directory that
# is never removed by this script, created with mktemp -d (portable, and
# 0700 by default — challenge round 2 findings 6 and 9: the earlier
# `mkdir -p` + hand-rolled `date +%N` timestamp both left the directory
# world-readable under a normal umask and, on a platform whose `date` has no
# %N, collision-prone).
owner_repo_dir="$(printf '%s' "$repo" | tr '/' '-')"
# GROOM_OUT_DIR (default $HOME/.local/state) names the CALLER'S root — a
# directory this script does not own, so it is only ever created if missing,
# NEVER chmod'd: a root-run `GROOM_OUT_DIR=/tmp task groom` must not turn the
# system temp directory's mode from 1777 into 0700, and an owned shared team
# directory must not become inaccessible to its other users (Codex review on
# PR #1032, comment 4012242612). A pre-existing root that is not a directory
# at all is refused outright rather than silently used as one.
out_parent="${GROOM_OUT_DIR:-$HOME/.local/state}"
if [ -e "$out_parent" ] && [ ! -d "$out_parent" ]; then
    die "GROOM_OUT_DIR root exists and is not a directory: $out_parent"
fi
mkdir -p "$out_parent" || die "could not create the output root: $out_parent"
# Every run's output lives under a groom-OWNED child of that root instead —
# this script always creates it (whether or not it happened to already exist
# from an earlier run), so it — and everything under it — is always safe to
# secure to mode 0700. mkdir -p -m 700 only applies the mode to directories
# it actually creates, so chmod it explicitly every run: a host upgraded
# from an older version of this script (which used a bare mkdir -p with no
# explicit mode) can already have this child directory at a looser mode, and
# -m would silently no-op on it (challenge round 3 finding 5).
out_root="$out_parent/harmon-groom"
secure_owned_dir "$out_root" "the output root"
secure_owned_dir "$out_root/$owner_repo_dir" "the repo's output directory"
run_dir="$(mktemp -d "$out_root/$owner_repo_dir/run.XXXXXX")" ||
    die "could not create the run's output directory"
export GROOM_SCRATCH="$run_dir"

report_html="$run_dir/report.html"
report_md="$run_dir/report.md"
print_outputs() {
    printf 'groom: run output directory: %s\n' "$run_dir" >&2
    printf 'groom: report (if this run produced one): %s\n' "$report_html" >&2
    printf 'groom:                              and: %s\n' "$report_md" >&2
}
trap print_outputs EXIT

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
(task groom -- --execute <script> [args…]) that a human runs directly; it
has no tool grant here. Use only the tools you were granted. Finish with
the summary its final step defines.

Step 2 fan-out: dispatch every cluster subagent with model: \"${GROOM_FANOUT_MODEL:-opus}\"
— do not leave the model unset to inherit this session's own model."
if [ -n "$note" ]; then
    prompt="$prompt

Operator note (from the human who launched this run): $note"
fi

claude -p "$prompt" \
    --model "${GROOM_MODEL:-sonnet}" \
    --setting-sources "" \
    --tools "$claude_tools" \
    --allowedTools "$tools"
