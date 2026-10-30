#!/usr/bin/env bash
# Prose guards for how the orchestrator launches, merges in, and waits on
# lanes:
# - #1190: every herdr lane launch carries GIT_MERGE_AUTOEDIT=no and
#   GIT_EDITOR=true, no lane guidance spells a merge (or a merging pull)
#   without --no-edit, a conflicted merge is finished with
#   `git commit --no-edit --cleanup=strip`, the lane brief grants no merge of
#   the default branch at all, and a lane stuck in an editor is escalated;
#   process-ending actions follow the orchestrate skill's convention.
# - #1192: the herdr skill states the millisecond unit beside its first
#   --timeout example, and the orchestrate skill names settle-wait.sh as the
#   required wait primitive (delivery confirmed first, an ordinary lane
#   settle without --until so only idle or done settles, --head bound for
#   CI) and forbids discarding a wait's exit status.
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
integrate=ai/skills/universal/integrate/SKILL.md

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

# Where a consumer's brief lets a lane merge the default branch, the skill
# spells the command out. This skill's own lane brief grants no merge at all,
# not even on a relay: a delegate never merges.
contains "$skill" '`git merge --no-edit origin/<default-branch>`'
contains "$brief" 'This lane never merges `{{default-branch}}` into `{{branch}}`.'
if grep -nE 'git merge|relay from the orchestrator' "$brief"; then
    fail "$brief spells a merge or a relay that could authorize one"
fi
contains "$brief" 'always pass the message (`-m`, `--body`) to anything that would ask for one'

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
contains "$skill" '`git add`'
contains "$skill" '`git commit --no-edit --cleanup=strip`'
contains "$skill" '`git merge --abort`'

# ── #1190/#1683: escalate stuck lanes; follow the orchestrate process convention ──
contains "$skill" 'reports BLOCKED and is escalated to the orchestrator and the maintainer; any process-ending action follows the convention below'
contains "$brief" "report BLOCKED so the orchestrator escalates it to the maintainer; any process-ending action follows the orchestrate skill's process-ending convention"

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
# An ordinary lane settle omits --until: herdr's success is `done` for an
# unseen tab and `idle` once seen, so no single state can express it; the
# asset reads the state and settles only on those two.
contains "$skill" 'settle-wait.sh agent <lane> --timeout-seconds 3600'
contains "$guide" '`agent prompt <name> "<brief>" --wait --until working --timeout 30000`'
contains "$guide" '`assets/settle-wait.sh agent <name> --timeout-seconds <s>`'
if grep -nE 'settle-wait\.sh agent <[a-z]+> --until' "$skill" "$guide"; then
    fail "an ordinary lane settle recipe passes --until"
fi
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

# Bounded background passes are the fallback only when a streaming monitor
# cannot reach both CLIs; the same durable watcher state and pass-end latency
# are documented in the operator guide. Integrator checker retries preserve
# their checker state and never reserve or trigger on a transient read.
contains "$skill" 'Prefer the harness streaming monitor (Claude Code: `Monitor`) when its command can reach both `gh` and `herdr`'
contains "$skill" 'From a shell outside that sandbox, launch a finite background Bash pass'
contains "$skill" 'Events surface at pass end, so the pass length bounds how long a lane can wait on an approval'
contains "$skill" 'run the existing `settle-wait.sh` command as a finite background Bash pass from a shell outside that sandbox'
contains "$skill" 'A failed Herdr state read remains exit 5 and a failed GitHub read remains exit 3; neither is settled'
contains "$guide" 'If it is sandboxed from either CLI, run finite background Bash passes outside that sandbox with `--iterations <n>`, capture their output'
contains "$guide" 'Events surface at pass end, so the pass length bounds how long a lane can wait on an approval'
contains "$integrate" 'exit 16 is a transient read status, never evidence that the reviewer is still working or that a review settled'
contains "$integrate" 'run each checker call as a finite background Bash pass outside that sandbox'
contains "$integrate" 'it repeats the read without reserving or triggering another review'
# Retired timed specs are retried on re-arm after the read is reconciled.
contains "$skill" 'Surface stderr on exit 1 and re-arm only after the failing read is reconciled'
contains "$skill" '`OBSERVATION-DEGRADED <lane>: <detail>` fires once per failure episode'
contains "$guide" 'and re-arm only after the failing read is reconciled'

# Agent-mode exit codes are herdr's own; the 1-4 table is checks mode's.
contains "$skill" 'In `agent` mode the status is herdr'
contains "$skill" '5 the lane is blocked at an approval or question'
help="$(bash ai/skills/universal/orchestrate/assets/settle-wait.sh --help)"
case "$help" in
*"Exit status, agent mode:"*"5    herdr's wait returned, but the lane is blocked"*"124"*"Exit status, checks mode:"*) ;;
*) fail "settle-wait.sh --help does not separate agent-mode and checks-mode exits" ;;
esac

# ── #1519: agy posture per profile, disclosed in the existing brief text ──
# Scope these pins to Lane launch and waits, so matching prose elsewhere
# cannot mask a missing launch-posture subsection.
agy_posture="$test_tmp/agy-posture.md"
awk '
    /^## Lane launch and waits$/ { in_launch = 1; next }
    in_launch && /^## / { exit }
    in_posture && /^(#|##|###) / { exit }
    in_launch && /^### Antigravity \(agy\) lane permission posture$/ { in_posture = 1 }
    in_posture { print }
' "$skill" >"$agy_posture"
contains "$agy_posture" 'Choose the agy permission posture using `FOREMAN_DEVCONTAINER`: `bot`, `agent`, or unset for dev or host (see `docs/glossary.md`)'
contains "$agy_posture" 'With `FOREMAN_DEVCONTAINER` unset (dev or host), the orchestrator does not infer the profile from settings'
contains "$agy_posture" 'It dispatches agy lanes only after confirming that the agy settings in effect (`~/.gemini/antigravity-cli/settings.json`) carry the template dev-profile permissions from `antigravity-settings-dev.json`'
contains "$agy_posture" 'Otherwise it does not dispatch agy lanes, and in a dev devcontainer it reports that a rebuild is needed'
contains "$agy_posture" '`HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled` gates installing the bot wrapper and applying the dev settings, not profile selection'
contains "$agy_posture" "Disclose the chosen posture in the lane brief's verified-facts/rulings text"
contains "$agy_posture" '`--dangerously-skip-permissions` belongs only to the bot posture and is never passed under dev, host or agent'
contains "$agy_posture" '**Bot:** `FOREMAN_DEVCONTAINER=bot`. When `HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled`'
contains "$agy_posture" 'bot-autonomy wrapper at `~/.local/bin/agy` injects `--dangerously-skip-permissions` into every agy argv except bare `agy` and the passthrough subcommands'
contains "$agy_posture" 'Interactive pane launches with arguments receive the flag too'
contains "$agy_posture" "Bare interactive \`agy\` uses the bot's \`always-proceed\` settings"
contains "$agy_posture" 'the wrapper injects no flag for bare interactive `agy` or the subcommands it passes through unchanged'
contains "$agy_posture" 'Not every bot launch carries the flag'
contains "$agy_posture" 'A launcher that resolves `agy` another way must pass `--dangerously-skip-permissions` itself for lane runs'
contains "$agy_posture" "**Dev:** \`FOREMAN_DEVCONTAINER\` is unset; use the template's \`.devcontainer/config/antigravity-settings-dev.json\`"
contains "$agy_posture" "With \`HARMON_BOT_AUTONOMY_ANTIGRAVITY=enabled\`, the dev profile's post-create"
contains "$agy_posture" 'step runs `apply-antigravity-settings.sh` to apply that file **user-global** at `~/.gemini/antigravity-cli/settings.json` inside the dev devcontainer'
contains "$agy_posture" 'This settings posture applies to interactive agy panes; headless `agy -p` ignores settings allow-rules and auto-denies (see `docs/guides/devcontainers.md`)'
contains "$agy_posture" "This posture holds only in a devcontainer built with the template's dev settings; a pre-existing container needs a rebuild before agy lanes run"
contains "$agy_posture" "**Host:** \`FOREMAN_DEVCONTAINER\` is unset; use the user's own agy settings; the template's dev-profile settings are not applied to the host. Dispatch agy lanes only once the gate above confirms the template dev-profile permissions are in effect; otherwise dispatch none"
contains "$agy_posture" 'Headless `agy -p` ignores settings allow-rules and auto-denies (see `docs/guides/devcontainers.md`)'
contains "$agy_posture" '**Agent:** `FOREMAN_DEVCONTAINER=agent`; agy is refused by `.devcontainer/config/agent/harnesses.json`; do not launch an agy lane in that profile'
contains "$agy_posture" "The maintainer's 2026-10-18 ruling keeps the existing template dev settings: this changes no lane-scoped allowlist"
contains "$agy_posture" 'Refer to the template-owned settings file rather than copying its contents here'
contains "$agy_posture" 'changes no live behaviour'
contains "$agy_posture" 'The agy launch argv and lane workspace directories belong to [#1290](https://github.com/evanharmon1/harmon-devkit/issues/1290)'
# The positive pins require the three allowed occurrences: one bot-only
# sentence and two Bot-bullet instructions. Any extra occurrence, including
# under a nested subheading or an unrecognized label, violates that invariant.
flag_count="$(awk '{ count += gsub(/--dangerously-skip-permissions/, "") } END { print count + 0 }' "$agy_posture")"
[ "$flag_count" -eq 3 ] ||
    fail 'The skip-permissions flag must appear only in the Bot bullet and the bot-only sentence (3 occurrences)'

echo "lane launch and waits: ok"
