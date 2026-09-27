#!/usr/bin/env bash
# Prose guards for how the orchestrator launches, merges in, and waits on
# lanes:
# - #1190: every herdr lane launch carries GIT_MERGE_AUTOEDIT=no, no lane
#   guidance spells a merge without --no-edit, and a lane stuck in an editor
#   is escalated rather than recovered by terminating a process.
# - #1192: the herdr skill states the millisecond unit beside its first
#   --timeout example, and the orchestrate skill names settle-wait.sh as the
#   required wait primitive and forbids discarding a wait's exit status.
# The settle-wait.sh behaviour itself is tested by its co-located
# test-settle-wait.sh.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
test_tmp="$(mktemp -d -t lane-launch-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
    return 0
}

skill=ai/skills/universal/orchestrate/SKILL.md
brief=ai/skills/universal/orchestrate/assets/lane-brief.md
herdr_skill=ai/skills/herdr/herdr/SKILL.md
guide=docs/guides/herdr.md

flat() {
    tr '\n' ' ' <"$1" | tr -s '[:space:]' ' '
}

contains() {
    case "$(flat "$1")" in
    *"$2"*) return 0 ;;
    esac
    fail "$1 no longer says: $2"
}

# Print every `git merge <args>` in the given files that could open an editor:
# one with arguments but without --no-edit (a lone --abort cannot).
# `git merge-base` and a bare mention of `git merge` carry no arguments.
bare_merges() {
    { grep -HonE 'git merge( [^`]*)?' "$@" 2>/dev/null || true; } |
        while IFS= read -r hit; do
            rest="${hit#*git merge}"
            rest="${rest# }"
            rest="${rest%% }"
            case "$rest" in
            '' | --abort | *--no-edit*) ;;
            *) printf '%s\n' "$hit" ;;
            esac
        done
}

# The detector must catch what it exists to catch, and nothing else.
cat >"$test_tmp/probe.md" <<'EOF'
Run `git merge origin/main` to catch up.
Or `git merge --no-edit origin/main`.
Compare with `git merge-base HEAD origin/main`, or `git merge --abort`.
EOF
probe="$(bare_merges "$test_tmp/probe.md")"
[ "$probe" = "$test_tmp/probe.md:1:git merge origin/main" ] ||
    fail "bare-merge detector is wrong on its probe: '$probe'"

# ── #1190: no bare merge in any lane-facing guidance ──────────────────
lane_docs=()
while IFS= read -r doc; do
    lane_docs+=("$doc")
done < <(find ai/skills/universal/orchestrate ai/skills/herdr -name '*.md' | sort)
lane_docs+=("$guide")
violations="$(bare_merges "${lane_docs[@]}")"
[ -z "$violations" ] || fail "a merge without --no-edit in lane guidance:
$violations"

# Where a lane may merge the default branch, the command is spelled out.
contains "$skill" '`git merge --no-edit origin/<default-branch>`'
contains "$brief" '`git merge --no-edit origin/{{default-branch}}`'

# ── #1190: every herdr lane launch sets GIT_MERGE_AUTOEDIT=no ─────────
for doc in "$skill" "$brief" "$guide"; do
    grep -Fq 'GIT_MERGE_AUTOEDIT=no' "$doc" ||
        fail "$doc does not carry GIT_MERGE_AUTOEDIT=no"
done
launches="$(grep -nE 'herdr (tab create|pane split)' "$skill" || true)"
[ -n "$launches" ] || fail "$skill has no herdr lane-launch recipe"
if printf '%s\n' "$launches" | grep -Fv -- '--env GIT_MERGE_AUTOEDIT=no'; then
    fail "a herdr lane launch in $skill lacks --env GIT_MERGE_AUTOEDIT=no"
fi
contains "$guide" '`pane split … --cwd … --no-focus`, each with `--env GIT_MERGE_AUTOEDIT=no`'

# ── #1190: a stuck lane is escalated, never killed ────────────────────
contains "$skill" 'is escalated to the orchestrator and the maintainer; it is never recovered by the lane, or the orchestrator, terminating a process'
contains "$brief" 'report BLOCKED so the orchestrator escalates it to the maintainer — never recover by terminating a process yourself'

# ── #1192: the millisecond unit sits beside the first --timeout ───────
first_timeout="$(grep -nE -- '--timeout [0-9]' "$herdr_skill" | head -n 1 | cut -d: -f1)"
unit_line="$(grep -n 'is in \*\*milliseconds\*\*' "$herdr_skill" | head -n 1 | cut -d: -f1)"
if [ -z "$first_timeout" ] || [ -z "$unit_line" ]; then
    fail "$herdr_skill lost its first --timeout example or its unit statement"
fi
if [ "$unit_line" -lt "$first_timeout" ] || [ $((unit_line - first_timeout)) -gt 4 ]; then
    fail "$herdr_skill states the unit on line $unit_line, not beside line $first_timeout"
fi

# ── #1192: settle-wait.sh is the required primitive ───────────────────
[ -x ai/skills/universal/orchestrate/assets/settle-wait.sh ] ||
    fail "settle-wait.sh is missing or not executable"
contains "$skill" '`assets/settle-wait.sh` is the required primitive for every bounded lane settle and CI settle'
contains "$skill" 'Never follow a wait with `; echo`'
contains "$skill" 'never settle CI with `gh run watch --exit-status` or `gh pr checks --watch`'

echo "lane launch and waits: ok"
