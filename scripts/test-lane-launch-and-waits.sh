#!/usr/bin/env bash
# Prose guards for how the orchestrator launches, merges in, and waits on
# lanes:
# - #1190: every herdr lane launch carries GIT_MERGE_AUTOEDIT=no and
#   GIT_EDITOR=true, no lane guidance spells a merge (or a merging pull)
#   without --no-edit, a conflicted merge is finished with
#   `git commit --no-edit --cleanup=strip`, and a lane stuck in an editor is escalated rather
#   than recovered by terminating a process.
# - #1192: the herdr skill states the millisecond unit beside its first
#   --timeout example, and the orchestrate skill names settle-wait.sh as the
#   required wait primitive (delivery confirmed first, --head bound for CI)
#   and forbids discarding a wait's exit status.
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

# Print, as FILE:LINE:MATCH, every git command in the given files that could
# open an editor on a merge message:
# - `git merge <args>` (also `git -C <dir> merge`, `git -c k=v merge`) without
#   --no-edit, except --continue/--abort/--quit, which take no merge message
#   from the command line (the lane's GIT_EDITOR=true covers --continue);
# - `git pull <args>` without --rebase, --ff-only, or --no-edit.
# Backslash-continued lines are joined first, so a multi-line
# `git merge \` whose continuation carries --no-edit is one command, reported
# at its first line. `git merge-base` and a bare mention of `git merge` (no
# arguments) are not commands that merge.
bare_merges() {
    for file in "$@"; do
        awk -v file="$file" '
            function check(text, lineno,    s, m, verb, args) {
                s = text
                while (match(s, /git( -[Cc] [^ `]+)* (merge|pull)([ ][^`;&|]*)?/)) {
                    m = substr(s, RSTART, RLENGTH)
                    s = substr(s, RSTART + RLENGTH)
                    if (substr(s, 1, 1) == "-") continue
                    args = m
                    sub(/^git( -[Cc] [^ `]+)* /, "", args)
                    verb = args
                    sub(/ .*/, "", verb)
                    sub(/^(merge|pull)/, "", args)
                    sub(/[ ]+$/, "", args)
                    sub(/^[ ]+/, "", args)
                    if (verb == "merge") {
                        if (args == "") continue
                        if (args ~ /^--(continue|abort|quit)$/) continue
                        if (args ~ /(^| )--no-edit( |$)/) continue
                    } else {
                        if (args ~ /(^| )(--rebase(=[a-z]+)?|--ff-only|--no-edit)( |$)/) continue
                    }
                    sub(/[ ]+$/, "", m)
                    print file ":" lineno ":" m
                }
            }
            {
                line = $0
                if (buf == "") start = NR
                if (line ~ /\\$/) {
                    sub(/\\$/, "", line)
                    buf = buf line " "
                    next
                }
                text = buf line
                buf = ""
                gsub(/[ \t]+/, " ", text)
                check(text, start)
            }
            END { if (buf != "") { gsub(/[ \t]+/, " ", buf); check(buf, start) } }
        ' "$file"
    done
}

# The detector must catch what it exists to catch, and nothing else.
cat >"$test_tmp/probe.md" <<'EOF'
Run `git merge origin/main` to catch up.
Or `git merge --no-edit origin/main`.
Compare with `git merge-base HEAD origin/main`, or `git merge --abort`.
Finish with `git merge --continue`; a bare `git merge` mention is not a command.
Run `git -C ../lane merge origin/main` from outside.
Then `git -C ../lane merge --no-edit origin/main` is fine.
Run `git pull` or `git pull origin main`.
Fine: `git pull --rebase`, `git pull --ff-only origin main`, `git pull --no-edit origin main`.
    git merge \
        --no-edit \
        origin/main
    git merge \
        origin/main
EOF
probe="$(bare_merges "$test_tmp/probe.md")"
expected="$test_tmp/probe.md:1:git merge origin/main
$test_tmp/probe.md:5:git -C ../lane merge origin/main
$test_tmp/probe.md:7:git pull
$test_tmp/probe.md:7:git pull origin main
$test_tmp/probe.md:12:git merge origin/main"
[ "$probe" = "$expected" ] ||
    fail "bare-merge detector is wrong on its probe:
got:
$probe
expected:
$expected"

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

# ── #1190: every herdr lane launch sets GIT_MERGE_AUTOEDIT=no and ─────
# GIT_EDITOR=true (the latter covers finishing a conflicted merge).
for doc in "$skill" "$brief" "$guide"; do
    for var in GIT_MERGE_AUTOEDIT=no GIT_EDITOR=true; do
        grep -Fq "$var" "$doc" || fail "$doc does not carry $var"
    done
done
launches="$(grep -nE 'herdr (tab create|pane split)' "$skill" || true)"
[ -n "$launches" ] || fail "$skill has no herdr lane-launch recipe"
for var in GIT_MERGE_AUTOEDIT=no GIT_EDITOR=true; do
    if printf '%s\n' "$launches" | grep -Fv -- "--env $var"; then
        fail "a herdr lane launch in $skill lacks --env $var"
    fi
done
if printf '%s\n' "$launches" | grep -F '…'; then
    fail "a herdr lane launch in $skill uses a literal ellipsis, not placeholders"
fi
contains "$guide" 'each with `--env GIT_MERGE_AUTOEDIT=no --env GIT_EDITOR=true`'

# A conflicted merge is finished without an editor, or backed out.
for doc in "$skill" "$brief"; do
    contains "$doc" '`git add`'
    contains "$doc" '`git commit --no-edit --cleanup=strip`'
    contains "$doc" '`git merge --abort`'
done

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
contains "$skill" 'Never follow a wait, or the delivery check, with `; echo`'
contains "$skill" 'never settle CI with `gh run watch --exit-status` or `gh pr checks --watch`'
contains "$skill" 'checks --repo <owner/repo> --pr <n> --head <pushed-sha>'

# Delivery is confirmed with the one sanctioned raw-millisecond form, then
# the settle goes through the asset. The skill and the guide agree on both.
delivery='agent prompt <lane> "<text>" --wait --until working --timeout 30000'
contains "$skill" "herdr $delivery"
contains "$skill" 'settle-wait.sh agent <lane> --until <settled-state> --timeout-seconds'
contains "$guide" '`agent prompt <name> "<brief>" --wait --until working --timeout 30000`'
contains "$guide" '`assets/settle-wait.sh agent <name> --until <state> --timeout-seconds <s>`'
# Every raw herdr --timeout in the skill is the delivery check, and none is
# followed by something that discards its status.
raw="$(grep -nE 'herdr agent (wait|prompt).*--timeout [0-9]' "$skill" || true)"
[ -n "$raw" ] || fail "$skill lost its delivery check"
if printf '%s\n' "$raw" | grep -Fv -- "$delivery"; then
    fail "$skill passes a raw --timeout outside the delivery check"
fi
if grep -nE -- '--timeout [0-9]+ *(;|\|\|)' "$skill" "$guide"; then
    fail "a herdr wait's status is discarded"
fi

# Agent-mode exit codes are herdr's own; the 1-4 table is checks mode's.
contains "$skill" 'In `agent` mode the status is herdr'
help="$(bash ai/skills/universal/orchestrate/assets/settle-wait.sh --help)"
case "$help" in
*"Exit status, agent mode:"*"124"*"Exit status, checks mode:"*) ;;
*) fail "settle-wait.sh --help does not separate agent-mode and checks-mode exits" ;;
esac

echo "lane launch and waits: ok"
