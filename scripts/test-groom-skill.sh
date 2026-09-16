#!/usr/bin/env bash
# test-groom-skill.sh — unit-test the groom skill's contract scripts. Fully
# offline: every `gh` call goes to a PATH-stubbed gh driven by fixture files,
# and the wrapper's model run goes to a PATH-stubbed claude.
#
# What this keeps honest (issue #1015's [CI] criteria):
#   - audit mode writes nothing to GitHub (dry-run never calls a stubbed gh
#     write); apply mode is refused without --execute AND GROOM_EXECUTE=1,
#     and every applied write is logged with its exact command
#   - the verdict vocabulary rejects a CLOSE-* row with empty evidence, an
#     unknown verdict, and a NEEDS-DECISION row with no question
#   - the report renders every required section, in order, and shows number
#     AND title for every close candidate
#   - the decision helper posts the dated comment, closes named siblings with
#     a pointer, and adds blocked-by edges
#   - bot-authored issues are refused for close/retitle/relabel
#
# Run via `task test:groom-skill`.
set -euo pipefail
cd "$(dirname "$0")/.."
exec </dev/null

verdicts="./ai/skills/universal/groom/assets/groom-verdicts.sh"
report="./ai/skills/universal/groom/assets/groom-report.sh"
apply="./ai/skills/universal/groom/assets/groom-apply.sh"
decide="./ai/skills/universal/groom/assets/groom-decide.sh"
wrapper="./scripts/groom.sh"
repo="testowner/testrepo"

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

# Same sha256 fallback groom-decide.sh's own sha256_stream uses — reads a
# stream on stdin and prints only the hex digest, for tests that verify a
# logged body-sha256 suffix against the actual posted body.
test_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stub_dir="$tmp/fixtures"
mkdir -p "$tmp/bin" "$stub_dir"

cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GH_STUB_LOG:?}"
case "${1:-} ${2:-}" in
"issue close")
    [ "${GH_STUB_FAIL_CLOSE:-0}" = 0 ] || exit 1
    ;;
"issue comment")
    [ -t 0 ] || cat >/dev/null
    ;;
"issue edit")
    if grep -qx 'issue edit --help' <<<"$*"; then
        printf '%s\n' '  --type string   Set the issue type by name'
        exit 0
    fi
    [ -t 0 ] || cat >/dev/null
    ;;
"issue view")
    n="$3"
    # Simulates a concurrent edit landing between two live re-reads of the
    # SAME issue within one apply-plan invocation (pass 1's validation and
    # pass 2's write-adjacent re-check — challenge round 2 finding 4). Scoped
    # to --json title reads of one designated issue so it never perturbs the
    # bot-ownership (--json author) reads every other test relies on.
    if [ -n "${GH_STUB_RACE_ISSUE:-}" ] && [ "$n" = "${GH_STUB_RACE_ISSUE}" ] &&
        grep -q -- '--json title' <<<"$*"; then
        count_file="${GH_STUB_RACE_COUNTER:?}"
        count=0
        [ -f "$count_file" ] && count="$(cat "$count_file")"
        count=$((count + 1))
        printf '%s' "$count" >"$count_file"
        if [ "$count" -ge 2 ]; then
            cat "${GH_STUB_DIR:?}/issue-$n-race.json"
        else
            cat "${GH_STUB_DIR:?}/issue-$n.json"
        fi
    elif [ -f "${GH_STUB_DIR:?}/issue-$n.json" ]; then
        cat "${GH_STUB_DIR:?}/issue-$n.json"
    else
        echo '{"labels":[],"author":{"login":"someone","type":"User","is_bot":false}}'
    fi
    ;;
"label list") cat "${GH_STUB_DIR:?}/labels.json" ;;
"repo view") printf '%s\n' "${GH_STUB_REPO:?}" ;;
"project list") exit 1 ;;
"issue list") cat "${GH_STUB_DIR:?}/open-issues.json" ;;
api\ repos/*/milestones)
    [ "${GH_STUB_FAIL_MILESTONES:-0}" = 0 ] || exit 1
    cat "${GH_STUB_DIR:?}/milestones.json"
    ;;
api\ repos/*/issues/*/dependencies/blocked_by)
    # Simulates a host/repository that does not expose the issue-dependencies
    # endpoint at all (groom-decide.sh's probe, Codex review on PR #1032,
    # comment 4012885483) — both the probe (GET, no -F) and the real write
    # (-F issue_id=...) hit this same case arm and fail alike.
    [ "${GH_STUB_FAIL_DEPENDENCIES:-0}" = 0 ] || exit 1
    ;;
api\ repos/*/issues/*/sub_issues) ;;
api\ repos/*/issues/*)
    n="${2##*/}"
    # Simulates an inaccessible/deleted issue whose numeric id cannot be
    # resolved (groom-apply.sh's sub-issue-link preflight, challenge/Codex
    # finding 4011648563) without touching every other id-resolution call.
    if [ -n "${GH_STUB_UNRESOLVABLE_ISSUE:-}" ] && [ "$n" = "${GH_STUB_UNRESOLVABLE_ISSUE}" ]; then
        exit 1
    fi
    printf '{"id": %s}\n' "$((n * 1000))"
    ;;
api\ repos/*)
    printf '%s\n' "${GH_STUB_OWNER_TYPE:-User}"
    ;;
*)
    echo "gh stub: unexpected call: $*" >&2
    exit 97
    ;;
esac
STUB
chmod +x "$tmp/bin/gh"

cat >"$tmp/bin/claude" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
    echo "  --setting-sources <sources>"
    exit 0
fi
printf '%s\n' "ARGS: $*" >>"${GH_STUB_LOG:?}"
printf '%s\n' "GROOM_EXECUTE=${GROOM_EXECUTE:-unset}" >>"${GH_STUB_LOG:?}"
printf '%s\n' "GROOM_REPO=${GROOM_REPO:-unset}" >>"${GH_STUB_LOG:?}"
printf '%s\n' "GROOM_SCRATCH=${GROOM_SCRATCH:-unset}" >>"${GH_STUB_LOG:?}"
# Simulate the model reaching Step 4/6 and writing the report into the
# directory the wrapper named — the wrapper test asserts these survive the
# wrapper process (issue #1015 finding 1).
if [ -n "${GROOM_SCRATCH:-}" ] && [ -d "$GROOM_SCRATCH" ]; then
    printf '<html>stub report</html>\n' >"$GROOM_SCRATCH/report.html"
    printf '# stub report\n' >"$GROOM_SCRATCH/report.md"
fi
STUB
chmod +x "$tmp/bin/claude"

export GH_STUB_DIR="$stub_dir"
export GH_STUB_LOG="$tmp/gh.log"
export GH_STUB_OWNER_TYPE="User"
: >"$GH_STUB_LOG"

run() {
    _rc=0
    PATH="$tmp/bin:$PATH" "$@" >"$tmp/out" 2>"$tmp/err" || _rc=$?
    echo "$_rc"
}

# pty_exec CMD... — run CMD under a pseudo-terminal, so it sees a TTY on
# stdin and stdout. Needed to get past the wrapper's own --execute
# interactivity gate and exercise the confirmed exec path. Two allocators,
# in preference order (the same pattern as scripts/test-setup-gh-scopes.sh):
# python3's pty.spawn calls openpty directly and works in a sandbox/CI shell
# with no controlling terminal, where `script` fails outright; `script` is
# the fallback for a host with no python3, and its BSD (macOS) / util-linux
# (Linux) argument orders differ.
pty_exec() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import os,pty,sys; sys.exit(os.waitstatus_to_exitcode(pty.spawn(sys.argv[1:])))' "$@" 2>&1
    elif [ "$(uname -s)" = "Darwin" ]; then
        script -q /dev/null "$@" 2>&1
    else
        script -qec "$*" /dev/null 2>&1
    fi
}

# Whether a pty can be allocated at all. Skipped with a note (never silently
# dropped) when it cannot — the same treatment test-status.sh gives a missing
# `timeout` binary.
PTY_OK=false
if [ "$(pty_exec printf PTYPROBE 2>/dev/null | tr -dc 'A-Z')" = "PTYPROBE" ]; then
    PTY_OK=true
fi

cat >"$stub_dir/labels.json" <<'JSON'
[{"name":"needs-triage","description":""}]
JSON

# ── groom-verdicts.sh: vocabulary contract ─────────────────────────────────
echo "==> validate: a well-formed cluster file passes"
good="$tmp/good.jsonl"
cat >"$good" <<'JSONL'
{"number":1,"verdict":"CLOSE-done","priority":"high","reason":"merged in PR","evidence":"PR #9","group":"ci"}
{"number":2,"verdict":"KEEP","priority":"low","reason":"still relevant","evidence":"","group":"infra"}
{"number":3,"verdict":"NEEDS-DECISION","priority":"medium","reason":"pick an approach","evidence":"","group":"design","question":"Ship A or B?"}
{"number":4,"verdict":"CLOSE-dup-of-#2","priority":"low","reason":"same as #2","evidence":"identical repro","group":"infra"}
{"number":5,"verdict":"CLOSE-wrong-repo (evanharmon1/other-repo)","priority":"low","reason":"belongs elsewhere","evidence":"targets other-repo","group":"misc"}
JSONL
[ "$(run "$verdicts" validate "$good")" = 0 ] || fail "well-formed file should validate: $(cat "$tmp/out" "$tmp/err")"

echo "==> validate: a CLOSE-* row with no evidence is refused"
bad_close="$tmp/bad-close.jsonl"
printf '%s\n' '{"number":9,"verdict":"CLOSE-done","priority":"high","reason":"x","evidence":"","group":"ci"}' >"$bad_close"
[ "$(run "$verdicts" validate "$bad_close")" = 1 ] || fail "empty-evidence CLOSE must exit 1"
grep -q "#9" "$tmp/err" || fail "refusal must name the issue number"

echo "==> validate: an unknown verdict is refused"
bad_verdict="$tmp/bad-verdict.jsonl"
printf '%s\n' '{"number":10,"verdict":"MAYBE","priority":"low","reason":"x","evidence":"y","group":"ci"}' >"$bad_verdict"
[ "$(run "$verdicts" validate "$bad_verdict")" = 1 ] || fail "unknown verdict must exit 1"
grep -q "#10" "$tmp/err" || fail "refusal must name the issue number"

echo "==> validate: NEEDS-DECISION with no question is refused"
bad_question="$tmp/bad-question.jsonl"
printf '%s\n' '{"number":11,"verdict":"NEEDS-DECISION","priority":"medium","reason":"x","evidence":"","group":"ci"}' >"$bad_question"
[ "$(run "$verdicts" validate "$bad_question")" = 1 ] || fail "missing question must exit 1"

echo "==> validate: NEEDS-DECISION with a whitespace-only question is refused (Codex 4012885444)"
ws_question="$tmp/ws-question.jsonl"
printf '%s\n' '{"number":25,"verdict":"NEEDS-DECISION","priority":"medium","reason":"x","evidence":"","group":"ci","question":"   "}' >"$ws_question"
[ "$(run "$verdicts" validate "$ws_question")" = 1 ] || fail "whitespace-only question must be refused"

echo "==> validate: a non-string question value ([] or a number) is refused (Codex 4012885444)"
array_question="$tmp/array-question.jsonl"
printf '%s\n' '{"number":26,"verdict":"NEEDS-DECISION","priority":"medium","reason":"x","evidence":"","group":"ci","question":[]}' >"$array_question"
[ "$(run "$verdicts" validate "$array_question")" = 1 ] || fail "an array question value must be refused"
number_question="$tmp/number-question.jsonl"
printf '%s\n' '{"number":27,"verdict":"NEEDS-DECISION","priority":"medium","reason":"x","evidence":"","group":"ci","question":123}' >"$number_question"
[ "$(run "$verdicts" validate "$number_question")" = 1 ] || fail "a numeric question value must be refused"

echo "==> validate: an invalid priority is refused"
bad_priority="$tmp/bad-priority.jsonl"
printf '%s\n' '{"number":12,"verdict":"KEEP","priority":"urgent","reason":"x","evidence":"","group":"ci"}' >"$bad_priority"
[ "$(run "$verdicts" validate "$bad_priority")" = 1 ] || fail "bad priority must exit 1"

echo "==> validate: CLOSE-wrong-repo accepts a real target, not just the literal word 'target'"
wrong_repo="$tmp/wrong-repo.jsonl"
printf '%s\n' '{"number":13,"verdict":"CLOSE-wrong-repo (harmonops/harmon-infra)","priority":"low","reason":"belongs there","evidence":"describes infra config","group":"misc"}' >"$wrong_repo"
[ "$(run "$verdicts" validate "$wrong_repo")" = 0 ] ||
    fail "a real target description must validate: $(cat "$tmp/out" "$tmp/err")"

echo "==> validate: the literal CLOSE-wrong-repo (target) placeholder is refused (Codex 4011648585)"
placeholder_target="$tmp/placeholder-target.jsonl"
printf '%s\n' '{"number":14,"verdict":"CLOSE-wrong-repo (target)","priority":"low","reason":"belongs elsewhere","evidence":"describes infra config","group":"misc"}' >"$placeholder_target"
[ "$(run "$verdicts" validate "$placeholder_target")" = 1 ] ||
    fail "the literal (target) placeholder must be refused"
grep -q "#14" "$tmp/err" || fail "placeholder refusal must name the issue number"

echo "==> validate: the placeholder rejection is case- and whitespace-insensitive"
placeholder_target_ci="$tmp/placeholder-target-ci.jsonl"
printf '%s\n' '{"number":15,"verdict":"CLOSE-wrong-repo (  Target  )","priority":"low","reason":"belongs elsewhere","evidence":"describes infra config","group":"misc"}' >"$placeholder_target_ci"
[ "$(run "$verdicts" validate "$placeholder_target_ci")" = 1 ] ||
    fail "a whitespace/case variant of the placeholder must still be refused"

echo "==> validate: a whitespace-only CLOSE-wrong-repo target is refused (Codex 4012885435)"
blank_target="$tmp/blank-target.jsonl"
printf '%s\n' '{"number":28,"verdict":"CLOSE-wrong-repo (   )","priority":"low","reason":"belongs elsewhere","evidence":"describes infra config","group":"misc"}' >"$blank_target"
[ "$(run "$verdicts" validate "$blank_target")" = 1 ] ||
    fail "a whitespace-only CLOSE-wrong-repo target must be refused"
grep -q "#28" "$tmp/err" || fail "the blank-target refusal must name the issue number"

echo "==> validate: whitespace-only evidence on a CLOSE verdict is refused (Codex 4011648593)"
ws_evidence="$tmp/ws-evidence.jsonl"
printf '%s\n' '{"number":16,"verdict":"CLOSE-done","priority":"high","reason":"x","evidence":"   ","group":"ci"}' >"$ws_evidence"
[ "$(run "$verdicts" validate "$ws_evidence")" = 1 ] || fail "whitespace-only evidence must be refused"

echo "==> validate: a non-string evidence value ([] or a number) is refused (Codex 4011648593)"
array_evidence="$tmp/array-evidence.jsonl"
printf '%s\n' '{"number":17,"verdict":"CLOSE-done","priority":"high","reason":"x","evidence":[],"group":"ci"}' >"$array_evidence"
[ "$(run "$verdicts" validate "$array_evidence")" = 1 ] || fail "an array evidence value must be refused"
number_evidence="$tmp/number-evidence.jsonl"
printf '%s\n' '{"number":18,"verdict":"CLOSE-done","priority":"high","reason":"x","evidence":123,"group":"ci"}' >"$number_evidence"
[ "$(run "$verdicts" validate "$number_evidence")" = 1 ] || fail "a numeric evidence value must be refused"

echo "==> validate: whitespace-only reason is refused (Codex 4012242599)"
ws_reason="$tmp/ws-reason.jsonl"
printf '%s\n' '{"number":19,"verdict":"KEEP","priority":"low","reason":"   ","evidence":"","group":"ci"}' >"$ws_reason"
[ "$(run "$verdicts" validate "$ws_reason")" = 1 ] || fail "whitespace-only reason must be refused"
grep -q "#19" "$tmp/err" || fail "refusal must name the issue number"

echo "==> validate: a non-string reason value ([] or a number) is refused (Codex 4012242599)"
array_reason="$tmp/array-reason.jsonl"
printf '%s\n' '{"number":23,"verdict":"KEEP","priority":"low","reason":[],"evidence":"","group":"ci"}' >"$array_reason"
[ "$(run "$verdicts" validate "$array_reason")" = 1 ] || fail "an array reason value must be refused"
number_reason="$tmp/number-reason.jsonl"
printf '%s\n' '{"number":24,"verdict":"KEEP","priority":"low","reason":123,"evidence":"","group":"ci"}' >"$number_reason"
[ "$(run "$verdicts" validate "$number_reason")" = 1 ] || fail "a numeric reason value must be refused"

echo "==> validate: multiple invalid rows in one file still exit 1 (never the raw count — Codex 4011648565)"
multi_bad="$tmp/multi-bad.jsonl"
cat >"$multi_bad" <<'JSONL'
{"number":20,"verdict":"CLOSE-done","priority":"high","reason":"x","evidence":"","group":"ci"}
{"number":21,"verdict":"MAYBE","priority":"low","reason":"x","evidence":"y","group":"ci"}
{"number":22,"verdict":"KEEP","priority":"urgent","reason":"x","evidence":"","group":"ci"}
JSONL
[ "$(run "$verdicts" validate "$multi_bad")" = 1 ] ||
    fail "multiple invalid rows must still exit 1, never wrap via bash's mod-256 exit status"

# ── groom-verdicts.sh: join ─────────────────────────────────────────────────
scan="$tmp/scan.json"
cat >"$scan" <<'JSON'
{"repo":"testowner/testrepo","open_total":5,"milestones":[{"number":1,"title":"v1","state":"open","open_issues":2,"closed_issues":0}],
 "open":[
  {"number":1,"title":"Fix the parser","bot_owned":false,"age_days":10,"days_since_update":2},
  {"number":2,"title":"Bot-filed task","bot_owned":true,"age_days":40,"days_since_update":40},
  {"number":3,"title":"Pick an approach","bot_owned":false,"age_days":5,"days_since_update":5},
  {"number":4,"title":"Duplicate report","bot_owned":false,"age_days":3,"days_since_update":3},
  {"number":5,"title":"Wrong repo idea","bot_owned":false,"age_days":1,"days_since_update":1}
 ]}
JSON

echo "==> join: merges titles/bot_owned from scan and computes stats"
disp="$tmp/dispositions.json"
[ "$(run "$verdicts" join --repo "$repo" --scan "$scan" --out "$disp" "$good")" = 0 ] ||
    fail "join should succeed: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -r '.dispositions | length' "$disp")" = 5 ] || fail "join must carry every row"
[ "$(jq -r '.dispositions[0].title' "$disp")" = "Fix the parser" ] || fail "join must attach titles"
[ "$(jq -r '.dispositions[1].bot_owned' "$disp")" = "true" ] || fail "join must attach bot_owned"
[ "$(jq -r '.stats.close_candidates' "$disp")" = 3 ] || fail "close_candidates must count every CLOSE-* verdict"
[ "$(jq -r '.stats.decisions' "$disp")" = 1 ] || fail "decisions must count NEEDS-DECISION rows"

echo "==> join: refuses when a cluster file is malformed (never publishes a partial dataset)"
[ "$(run "$verdicts" join --repo "$repo" --scan "$scan" --out "$tmp/bad-out.json" "$bad_close")" = 1 ] ||
    fail "join must refuse a malformed cluster file"
[ ! -f "$tmp/bad-out.json" ] || fail "join must not write an output file on refusal"

# ── groom-verdicts.sh: join coverage (finding 3) ────────────────────────────
echo "==> join: refuses a duplicate verdict row for the same issue"
dup_rows="$tmp/dup-rows.jsonl"
cat >"$dup_rows" <<'JSONL'
{"number":1,"verdict":"KEEP","priority":"low","reason":"a","evidence":"","group":"ci"}
{"number":1,"verdict":"KEEP","priority":"low","reason":"b","evidence":"","group":"ci"}
{"number":2,"verdict":"KEEP","priority":"low","reason":"c","evidence":"","group":"ci"}
{"number":3,"verdict":"KEEP","priority":"low","reason":"d","evidence":"","group":"ci"}
{"number":4,"verdict":"KEEP","priority":"low","reason":"e","evidence":"","group":"ci"}
{"number":5,"verdict":"KEEP","priority":"low","reason":"f","evidence":"","group":"ci"}
JSONL
[ "$(run "$verdicts" join --repo "$repo" --scan "$scan" --out "$tmp/dup-out.json" "$dup_rows")" = 1 ] ||
    fail "join must refuse a duplicate verdict row"
grep -q "#1" "$tmp/err" || fail "duplicate refusal must name the issue number"
[ ! -f "$tmp/dup-out.json" ] || fail "join must not write an output file on a duplicate refusal"

echo "==> join: refuses a verdict row for an unknown (not-open) issue number"
unknown_rows="$tmp/unknown-rows.jsonl"
cat >"$unknown_rows" <<'JSONL'
{"number":1,"verdict":"KEEP","priority":"low","reason":"a","evidence":"","group":"ci"}
{"number":2,"verdict":"KEEP","priority":"low","reason":"b","evidence":"","group":"ci"}
{"number":3,"verdict":"KEEP","priority":"low","reason":"c","evidence":"","group":"ci"}
{"number":4,"verdict":"KEEP","priority":"low","reason":"d","evidence":"","group":"ci"}
{"number":5,"verdict":"KEEP","priority":"low","reason":"e","evidence":"","group":"ci"}
{"number":999,"verdict":"KEEP","priority":"low","reason":"f","evidence":"","group":"ci"}
JSONL
[ "$(run "$verdicts" join --repo "$repo" --scan "$scan" --out "$tmp/unknown-out.json" "$unknown_rows")" = 1 ] ||
    fail "join must refuse a verdict row for an unknown issue"
grep -q "#999" "$tmp/err" || fail "unknown refusal must name the issue number"
[ ! -f "$tmp/unknown-out.json" ] || fail "join must not write an output file on an unknown refusal"

echo "==> join: refuses a missing open issue (no verdict row) without --allow-missing"
missing_rows="$tmp/missing-rows.jsonl"
cat >"$missing_rows" <<'JSONL'
{"number":1,"verdict":"KEEP","priority":"low","reason":"a","evidence":"","group":"ci"}
{"number":2,"verdict":"KEEP","priority":"low","reason":"b","evidence":"","group":"ci"}
{"number":3,"verdict":"KEEP","priority":"low","reason":"c","evidence":"","group":"ci"}
{"number":4,"verdict":"KEEP","priority":"low","reason":"d","evidence":"","group":"ci"}
JSONL
[ "$(run "$verdicts" join --repo "$repo" --scan "$scan" --out "$tmp/missing-out.json" "$missing_rows")" = 1 ] ||
    fail "join must refuse a missing open issue without --allow-missing"
grep -q "#5" "$tmp/err" || fail "missing refusal must name the issue number"
[ ! -f "$tmp/missing-out.json" ] || fail "join must not write an output file on a missing refusal"

echo "==> join: --allow-missing accepts the gap and records it in stats.unverified"
missing_disp="$tmp/missing-disp.json"
[ "$(run "$verdicts" join --repo "$repo" --scan "$scan" --out "$missing_disp" \
    --allow-missing "$missing_rows")" = 0 ] ||
    fail "join --allow-missing should succeed: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -r '.dispositions | length' "$missing_disp")" = 4 ] || fail "join must carry every given row"
[ "$(jq -c '.stats.unverified' "$missing_disp")" = "[5]" ] ||
    fail "stats.unverified must list the uncovered issue number"

echo "==> join: refuses a CLOSE-dup-of-#N target that is the row's own number (self-reference, Codex 4011648588)"
self_dup_rows="$tmp/self-dup-rows.jsonl"
cat >"$self_dup_rows" <<'JSONL'
{"number":1,"verdict":"CLOSE-dup-of-#1","priority":"low","reason":"a","evidence":"same as itself","group":"ci"}
{"number":2,"verdict":"KEEP","priority":"low","reason":"b","evidence":"","group":"infra"}
{"number":3,"verdict":"KEEP","priority":"low","reason":"c","evidence":"","group":"design"}
{"number":4,"verdict":"KEEP","priority":"low","reason":"d","evidence":"","group":"infra"}
{"number":5,"verdict":"KEEP","priority":"low","reason":"e","evidence":"","group":"misc"}
JSONL
[ "$(run "$verdicts" join --repo "$repo" --scan "$scan" --out "$tmp/self-dup-out.json" "$self_dup_rows")" = 1 ] ||
    fail "join must refuse a self-referential CLOSE-dup-of target"
grep -q "targets itself" "$tmp/err" || fail "self-reference refusal must say so"
[ ! -f "$tmp/self-dup-out.json" ] || fail "join must not write an output file on a self-reference refusal"

echo "==> join: refuses a CLOSE-dup-of-#N target not present in scan.open"
bad_dup_rows="$tmp/bad-dup-rows.jsonl"
cat >"$bad_dup_rows" <<'JSONL'
{"number":1,"verdict":"CLOSE-dup-of-#999","priority":"low","reason":"a","evidence":"identical repro","group":"ci"}
{"number":2,"verdict":"KEEP","priority":"low","reason":"b","evidence":"","group":"infra"}
{"number":3,"verdict":"KEEP","priority":"low","reason":"c","evidence":"","group":"design"}
{"number":4,"verdict":"KEEP","priority":"low","reason":"d","evidence":"","group":"infra"}
{"number":5,"verdict":"KEEP","priority":"low","reason":"e","evidence":"","group":"misc"}
JSONL
[ "$(run "$verdicts" join --repo "$repo" --scan "$scan" --out "$tmp/bad-dup-out.json" "$bad_dup_rows")" = 1 ] ||
    fail "join must refuse a CLOSE-dup-of target absent from scan.open"
grep -q "not in scan.open" "$tmp/err" || fail "unresolvable dup-of refusal must explain why"
[ ! -f "$tmp/bad-dup-out.json" ] || fail "join must not write an output file on an unresolvable dup-of refusal"

echo "==> join: zero verdict files is accepted only when scan.open is empty"
empty_scan="$tmp/empty-scan.json"
printf '{"repo":"%s","open_total":0,"milestones":[],"open":[]}\n' "$repo" >"$empty_scan"
empty_disp="$tmp/empty-disp.json"
[ "$(run "$verdicts" join --repo "$repo" --scan "$empty_scan" --out "$empty_disp")" = 0 ] ||
    fail "join with zero files and zero open issues should succeed: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -r '.dispositions | length' "$empty_disp")" = 0 ] || fail "join must write an empty dataset"
[ "$(run "$verdicts" join --repo "$repo" --scan "$scan" --out "$tmp/should-fail.json")" = 1 ] ||
    fail "join with zero files but a nonempty scan.open must be refused"
[ ! -f "$tmp/should-fail.json" ] || fail "join must not write an output file on that refusal"

echo "==> join: --proposals is carried into the dataset verbatim"
proposals="$tmp/proposals.json"
cat >"$proposals" <<'JSON'
{"parents":[{"parent":1,"title":"Parser work","children":[3,4]}],
 "milestones":[{"action":"rename","title":"v1","new_title":"v1.1","issues":[3,4]}]}
JSON
proposals_disp="$tmp/proposals-disp.json"
[ "$(run "$verdicts" join --repo "$repo" --scan "$scan" --out "$proposals_disp" \
    --proposals "$proposals" "$good")" = 0 ] ||
    fail "join --proposals should succeed: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -r '.proposals.parents[0].title' "$proposals_disp")" = "Parser work" ] ||
    fail "join must carry proposals.parents into the dataset"
[ "$(jq -r '.proposals.milestones[0].new_title' "$proposals_disp")" = "v1.1" ] ||
    fail "join must carry proposals.milestones into the dataset"

echo "==> join: refuses when the scan's repo differs from --repo (Codex 4012885488)"
other_repo_scan="$tmp/other-repo-scan.json"
cat >"$other_repo_scan" <<'JSON'
{"repo":"someone-else/other-repo","open_total":0,"milestones":[],"open":[]}
JSON
[ "$(run "$verdicts" join --repo "$repo" --scan "$other_repo_scan" \
    --out "$tmp/mismatched-repo-out.json")" = 2 ] ||
    fail "a scan whose repo differs from --repo must exit 2"
grep -q "someone-else/other-repo" "$tmp/err" || fail "the refusal must name the scan's repo"
[ ! -f "$tmp/mismatched-repo-out.json" ] || fail "join must not write an output file on a repo mismatch"

echo "==> join: a scan with no repo field is accepted (nothing to compare)"
no_repo_field_scan="$tmp/no-repo-field-scan.json"
cat >"$no_repo_field_scan" <<'JSON'
{"open_total":0,"milestones":[],"open":[]}
JSON
[ "$(run "$verdicts" join --repo "$repo" --scan "$no_repo_field_scan" \
    --out "$tmp/no-repo-field-out.json")" = 0 ] ||
    fail "a scan with no repo field should succeed: $(cat "$tmp/out" "$tmp/err")"

# ── groom-verdicts.sh: GROOM_SCRATCH path binding (Codex 4011648576) ───────
verdicts_scratch="$tmp/verdicts-scratch"
mkdir -p "$verdicts_scratch"
cp "$good" "$verdicts_scratch/good.jsonl"
cp "$scan" "$verdicts_scratch/scan.json"
cp "$proposals" "$verdicts_scratch/proposals.json"

echo "==> validate: a verdict file outside GROOM_SCRATCH is refused"
[ "$(run env GROOM_SCRATCH="$verdicts_scratch" "$verdicts" validate "$good")" = 4 ] ||
    fail "a verdict file outside the run's scratch dir must exit 4"
grep -q -- "must live under this run's scratch directory" "$tmp/err" ||
    fail "the refusal must explain the scratch-dir binding"

echo "==> validate: a verdict file inside GROOM_SCRATCH is unaffected"
[ "$(run env GROOM_SCRATCH="$verdicts_scratch" "$verdicts" validate "$verdicts_scratch/good.jsonl")" = 0 ] ||
    fail "a verdict file inside the run's scratch dir should still validate: $(cat "$tmp/out" "$tmp/err")"

# #1079: GROOM_SCRATCH itself must be canonicalized before the prefix
# compare, not just the candidate path — a scratch root reached through a
# symlink (e.g. macOS's /var -> /private/var) must resolve the same as one
# reached directly, on every platform, not only where TMPDIR itself
# happens to be a symlink.
echo "==> validate: a verdict file inside a SYMLINKED GROOM_SCRATCH is still accepted"
verdicts_scratch_real="$tmp/verdicts-scratch-real"
mkdir -p "$verdicts_scratch_real"
cp "$good" "$verdicts_scratch_real/good.jsonl"
verdicts_scratch_link="$tmp/verdicts-scratch-link"
ln -s "$verdicts_scratch_real" "$verdicts_scratch_link"
[ "$(run env GROOM_SCRATCH="$verdicts_scratch_link" "$verdicts" validate "$verdicts_scratch_link/good.jsonl")" = 0 ] ||
    fail "a verdict file inside a symlinked scratch dir should still validate: $(cat "$tmp/out" "$tmp/err")"

# Review round 1, finding 1: groom-scan.sh and groom-report.sh each got a
# missing-scratch case in the challenge round-2 remediation; groom-verdicts.sh
# never did, despite guard_scratch_path being byte-identical across all
# three files' copies.
echo "==> validate: GROOM_SCRATCH itself missing is refused (exit 4)"
[ "$(run env GROOM_SCRATCH="$tmp/verdicts-scratch-missing" "$verdicts" validate \
    "$tmp/verdicts-scratch-missing/good.jsonl")" = 4 ] ||
    fail "a missing GROOM_SCRATCH must exit 4: $(cat "$tmp/out" "$tmp/err")"
grep -q -- "does not exist" "$tmp/err" || fail "the refusal must say the scratch directory does not exist"

echo "==> join: --scan outside GROOM_SCRATCH is refused"
[ "$(run env GROOM_SCRATCH="$verdicts_scratch" "$verdicts" join --repo "$repo" --scan "$scan" \
    --out "$verdicts_scratch/out.json" "$verdicts_scratch/good.jsonl")" = 4 ] ||
    fail "--scan outside the run's scratch dir must exit 4"

echo "==> join: --out outside GROOM_SCRATCH is refused"
[ "$(run env GROOM_SCRATCH="$verdicts_scratch" "$verdicts" join --repo "$repo" \
    --scan "$verdicts_scratch/scan.json" --out "$tmp/escape-out.json" \
    "$verdicts_scratch/good.jsonl")" = 4 ] ||
    fail "--out outside the run's scratch dir must exit 4"
[ ! -f "$tmp/escape-out.json" ] || fail "a refused --out must never be written (prompt-injection escape)"

echo "==> join: --proposals outside GROOM_SCRATCH is refused"
[ "$(run env GROOM_SCRATCH="$verdicts_scratch" "$verdicts" join --repo "$repo" \
    --scan "$verdicts_scratch/scan.json" --out "$verdicts_scratch/out.json" \
    --proposals "$proposals" "$verdicts_scratch/good.jsonl")" = 4 ] ||
    fail "--proposals outside the run's scratch dir must exit 4"

echo "==> join: a positional verdict FILE outside GROOM_SCRATCH is refused"
[ "$(run env GROOM_SCRATCH="$verdicts_scratch" "$verdicts" join --repo "$repo" \
    --scan "$verdicts_scratch/scan.json" --out "$verdicts_scratch/out.json" "$good")" = 4 ] ||
    fail "a verdict FILE outside the run's scratch dir must exit 4"

echo "==> join: every path under GROOM_SCRATCH succeeds"
[ "$(run env GROOM_SCRATCH="$verdicts_scratch" "$verdicts" join --repo "$repo" \
    --scan "$verdicts_scratch/scan.json" --out "$verdicts_scratch/out.json" \
    --proposals "$verdicts_scratch/proposals.json" "$verdicts_scratch/good.jsonl")" = 0 ] ||
    fail "join with every path under the scratch dir should succeed: $(cat "$tmp/out" "$tmp/err")"

# ── groom-report.sh ─────────────────────────────────────────────────────────
echo "==> report: renders every required section, in order, with number+title"
out_html="$tmp/report.html"
out_md="$tmp/report.md"
GROOM_NOW="2026-01-01 00:00 UTC" run "$report" render --dispositions "$disp" \
    --out-html "$out_html" --out-md "$out_md" >/dev/null
for section in "## Stats" "## What to do next" "## Close now" "## Milestones" \
    "## Parent issues" "## Decisions" "## Completed this run" "## Process findings" \
    "## Every issue"; do
    grep -qF "$section" "$out_md" || fail "missing section: $section"
done
order="$(grep -n '^## ' "$out_md" | cut -d: -f2)"
expected="## Stats
## What to do next
## Close now
## Milestones
## Parent issues
## Decisions
## Completed this run
## Process findings
## Bot-owned issues (excluded from retitle/close/relabel)
## Every issue"
[ "$order" = "$expected" ] || fail "sections must appear in the required order: got:
$order"
grep -q "#1 — Fix the parser" "$out_md" || fail "close candidate must show number and title"
grep -q "#2 — Bot-filed task" "$out_md" || fail "bot-owned section must show number and title"
grep -qF "Generated: 2026-01-01 00:00 UTC" "$out_md" || fail "GROOM_NOW override must be honored"
grep -q "<title>Groom report" "$out_html" || fail "HTML must carry a title"
grep -q "id=q" "$out_html" || fail "HTML must carry the filter/search input"

# ── groom-scan.sh ────────────────────────────────────────────────────────────
echo "==> scan: read-only, computes age/bot_owned/title health, notes board access"
cat >"$stub_dir/open-issues.json" <<'JSON'
[
  {"number":1,"title":"(ci): Fix the parser","body":"x","labels":[{"name":"area:ci"}],
   "milestone":null,"assignees":[],"author":{"login":"alice","type":"User","is_bot":false},
   "createdAt":"2025-01-01T00:00:00Z","updatedAt":"2025-01-01T00:00:00Z"},
  {"number":2,"title":"legacy unscoped title","body":"y","labels":[],
   "milestone":null,"assignees":[],"author":{"login":"dependabot[bot]","type":"Bot","is_bot":true},
   "createdAt":"2025-01-01T00:00:00Z","updatedAt":"2025-01-01T00:00:00Z"}
]
JSON
# TWO JSON arrays, concatenated back to back: gh api --paginate on an
# array-shaped endpoint writes one JSON array PER PAGE to stdout — it does
# not merge pages into a single array, and it does not unwrap a page into a
# stream of bare elements (Codex review on PR #1032, comment 4011648559).
# This fixture simulates a two-page result; groom-scan.sh must flatten both
# pages into one flat milestones list.
cat >"$stub_dir/milestones.json" <<'JSON'
[{"number":1,"title":"v1","state":"open","description":"","open_issues":1,"closed_issues":0}]
[{"number":2,"title":"v2","state":"closed","description":"d","open_issues":0,"closed_issues":3}]
JSON
: >"$GH_STUB_LOG"
scan_out="$tmp/scan-live.json"
[ "$(run "./ai/skills/universal/groom/assets/groom-scan.sh" --repo "$repo" --out "$scan_out")" = 0 ] ||
    fail "groom-scan should succeed: $(cat "$tmp/out" "$tmp/err")"
grep -qE "^issue (edit|close|comment) " "$GH_STUB_LOG" && fail "scan must never write"
[ "$(jq -r '.open | length' "$scan_out")" = 2 ] || fail "scan must carry every open issue"
[ "$(jq -r '.open[1].bot_owned' "$scan_out")" = "true" ] || fail "scan must flag bot_owned"
[ "$(jq -r '.open[1].title_valid' "$scan_out")" = "false" ] || fail "scan must flag an invalid title"
[ "$(jq -r '.open[0].age_days' "$scan_out")" != "null" ] || fail "scan must compute age_days"
[ "$(jq -r '.milestones | length' "$scan_out")" = 2 ] ||
    fail "scan must flatten every paginated milestones page into one list"
[ "$(jq -r '.milestones[0].number' "$scan_out")" = 1 ] || fail "scan must carry page 1's milestone"
[ "$(jq -r '.milestones[1].number' "$scan_out")" = 2 ] || fail "scan must carry page 2's milestone"
[ "$(jq -r '.board_access' "$scan_out")" != "null" ] || fail "scan must note board access"

echo "==> scan: an empty milestones page flattens to an empty list, not an error"
cat >"$stub_dir/milestones.json" <<'JSON'
[]
JSON
: >"$GH_STUB_LOG"
empty_ms_out="$tmp/scan-empty-milestones.json"
[ "$(run "./ai/skills/universal/groom/assets/groom-scan.sh" --repo "$repo" --out "$empty_ms_out")" = 0 ] ||
    fail "groom-scan with an empty milestones page should succeed: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -r '.milestones | length' "$empty_ms_out")" = 0 ] ||
    fail "an empty milestones page must flatten to an empty list, not error"

echo "==> scan: a failed milestones request is fatal, not an empty list (Codex 4012242594)"
: >"$GH_STUB_LOG"
fail_ms_out="$tmp/scan-milestones-fail.json"
[ "$(run env GH_STUB_FAIL_MILESTONES=1 "./ai/skills/universal/groom/assets/groom-scan.sh" \
    --repo "$repo" --out "$fail_ms_out")" = 2 ] ||
    fail "a failed milestones request must be fatal: $(cat "$tmp/out" "$tmp/err")"
[ ! -f "$fail_ms_out" ] || fail "a failed scan must not write --out"
grep -qi "milestone" "$tmp/err" || fail "the refusal must mention milestones"

echo "==> scan: refuses (exit 4, naming --limit) when the result hits --limit exactly"
: >"$GH_STUB_LOG"
[ "$(run "./ai/skills/universal/groom/assets/groom-scan.sh" --repo "$repo" \
    --limit 2 --out "$tmp/scan-truncated.json")" = 4 ] ||
    fail "a scan returning exactly --limit issues must exit 4"
grep -q -- "--limit" "$tmp/err" || fail "refusal must name --limit"
[ ! -f "$tmp/scan-truncated.json" ] || fail "a refused scan must not write --out"

# Challenge round 2, finding 1: guard_out_path's GROOM_SCRATCH canonicalization
# (#1079) had no coverage at all in this file before this case.
echo "==> scan: GROOM_SCRATCH itself missing is refused (exit 4) when --out is given"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_SCRATCH="$tmp/scan-scratch-missing" \
    "./ai/skills/universal/groom/assets/groom-scan.sh" --repo "$repo" \
    --out "$tmp/scan-scratch-missing/scan.json")" = 4 ] ||
    fail "a missing GROOM_SCRATCH with --out given must exit 4: $(cat "$tmp/out" "$tmp/err")"
grep -q -- "does not exist" "$tmp/err" || fail "the refusal must say the scratch directory does not exist"

echo "==> scan: --out inside a SYMLINKED GROOM_SCRATCH is still accepted"
scan_scratch_real="$tmp/scan-scratch-real"
mkdir -p "$scan_scratch_real"
scan_scratch_link="$tmp/scan-scratch-link"
ln -s "$scan_scratch_real" "$scan_scratch_link"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_SCRATCH="$scan_scratch_link" \
    "./ai/skills/universal/groom/assets/groom-scan.sh" --repo "$repo" \
    --out "$scan_scratch_link/scan.json")" = 0 ] ||
    fail "--out inside a symlinked scratch dir should still succeed: $(cat "$tmp/out" "$tmp/err")"
[ -f "$scan_scratch_real/scan.json" ] || fail "the scan output must actually land under the real scratch dir"

# Review round 1, finding 1: guard_out_path returns early, before the
# scratch-existence check, when --out is omitted (groom-scan.sh's Exit:
# docstring documents this conditioning) — every other case in this file
# passes --out, so that early-return path itself was never exercised.
echo "==> scan: a broken GROOM_SCRATCH is not refused when --out is omitted"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_SCRATCH="$tmp/scan-scratch-never-created" \
    "./ai/skills/universal/groom/assets/groom-scan.sh" --repo "$repo")" = 0 ] ||
    fail "a scan with no --out must ignore a broken GROOM_SCRATCH entirely: $(cat "$tmp/out" "$tmp/err")"

# Review round 2, finding 1: guard_out_path's OTHER exit-4 branch (--out
# resolves outside an existing GROOM_SCRATCH) had no coverage for
# groom-scan.sh anywhere, unlike groom-report.sh/groom-verdicts.sh, even
# though this branch's comparison logic is exactly what #1079 changed.
echo "==> scan: --out outside an existing GROOM_SCRATCH is refused"
scan_scratch_existing="$tmp/scan-scratch-existing"
mkdir -p "$scan_scratch_existing"
[ "$(run env GROOM_SCRATCH="$scan_scratch_existing" \
    "./ai/skills/universal/groom/assets/groom-scan.sh" --repo "$repo" \
    --out "$tmp/scan-escape.json")" = 4 ] ||
    fail "--out outside the run's scratch dir must exit 4"
grep -q -- "must live under this run's scratch" "$tmp/err" ||
    fail "the refusal must explain the scratch-dir binding"
[ ! -f "$tmp/scan-escape.json" ] || fail "a refused --out must never be written (prompt-injection escape)"

echo "==> report: is deterministic (byte-identical on an unchanged dataset)"
out_html2="$tmp/report2.html"
GROOM_NOW="2026-01-01 00:00 UTC" run "$report" render --dispositions "$disp" \
    --out-html "$out_html2" --out-md "$tmp/report2.md" >/dev/null
diff -u "$out_html" "$out_html2" >&2 || fail "re-render of the same dataset must be byte-identical"

echo "==> report: a title containing a literal pipe does not corrupt the Markdown table"
pipe_disp="$tmp/pipe-disp.json"
cat >"$pipe_disp" <<'JSON'
{"repo":"o/r","dispositions":[
  {"number":9,"title":"Support a | b pipeline syntax","verdict":"KEEP","priority":"low","reason":"still needed | still valid","group":"ci","status":"PENDING"}
],"stats":{"open_total":1,"close_candidates":0,"decisions":0,"high_priority":0},"milestones":[]}
JSON
run "$report" render --dispositions "$pipe_disp" --out-html "$tmp/pipe.html" \
    --out-md "$tmp/pipe.md" >/dev/null
pipe_row="$(grep '^| #9 ' "$tmp/pipe.md")"
[ -n "$pipe_row" ] || fail "the #9 table row must be a single line"
[ "$(printf '%s\n' "$pipe_row" | awk -F' \\| ' '{print NF}')" = 6 ] ||
    fail "an escaped pipe must not add a phantom table column: $pipe_row"

echo "==> report: after outcomes merge, a DONE close/DECIDED decision moves from the actionable sets to Completed this run (Codex 4012242626)"
done_outcomes="$tmp/done-close-outcomes.jsonl"
cat >"$done_outcomes" <<'JSON'
{"issue":1,"op":"close","status":"DONE","at":"2026-01-01T00:00:00Z"}
{"issue":3,"op":"decision","status":"DECIDED 2026-01-01","at":"2026-01-01T00:00:00Z"}
JSON
done_md="$tmp/done.md"
run "$report" render --dispositions "$disp" --outcomes "$done_outcomes" \
    --out-html "$tmp/done.html" --out-md "$done_md" >/dev/null
close_now_section="$(sed -n '/^## Close now$/,/^## /p' "$done_md")"
grep -q '#1 —' <<<"$close_now_section" &&
    fail "a DONE close must not remain listed under Close now"
grep -q '#4 —' <<<"$close_now_section" ||
    fail "an untouched close candidate must still be listed under Close now"
decisions_section="$(sed -n '/^## Decisions$/,/^## /p' "$done_md")"
grep -q '#3 —' <<<"$decisions_section" &&
    fail "a DECIDED decision must not remain listed under Decisions"
completed_section="$(sed -n '/^## Completed this run$/,/^## /p' "$done_md")"
grep -q '#1 —' <<<"$completed_section" ||
    fail "a DONE close must be listed under Completed this run"
grep -q '#3 —' <<<"$completed_section" ||
    fail "a DECIDED decision must be listed under Completed this run"
grep -qF -- "- Close candidates: 2" "$done_md" ||
    fail "the Stats close-candidate count must reflect PENDING rows only"
grep -qF -- "- Decisions needed: 0" "$done_md" ||
    fail "the Stats decisions count must reflect PENDING rows only"
done_html="$tmp/done.html"
grep -qF "Completed this run" "$done_html" || fail "HTML must also render the Completed this run section"
grep -qF "close — status: DONE" "$done_html" || fail "HTML Completed this run must show the DONE close"

echo "==> report: outcomes are keyed by (issue, op) — a retitle outcome never marks the same issue's CLOSE row done (Codex 4012885408)"
retitle_only_outcomes="$tmp/retitle-only-outcomes.jsonl"
cat >"$retitle_only_outcomes" <<'JSON'
{"issue":1,"op":"retitle","status":"DONE","at":"2026-01-01T00:00:00Z"}
JSON
retitle_only_md="$tmp/retitle-only.md"
run "$report" render --dispositions "$disp" --outcomes "$retitle_only_outcomes" \
    --out-html "$tmp/retitle-only.html" --out-md "$retitle_only_md" >/dev/null
close_now_retitle_section="$(sed -n '/^## Close now$/,/^## /p' "$retitle_only_md")"
grep -q '#1 —' <<<"$close_now_retitle_section" ||
    fail "a retitle-only outcome for #1 must leave its CLOSE row PENDING (still listed under Close now)"
completed_retitle_section="$(sed -n '/^## Completed this run$/,/^## /p' "$retitle_only_md")"
grep -q '#1 —' <<<"$completed_retitle_section" &&
    fail "a retitle outcome must never move #1 to Completed this run — that section is for the OP that matches the row's own verdict"

echo "==> report: renders an Unverified section only when stats.unverified is nonempty"
run "$report" render --dispositions "$missing_disp" --out-html "$tmp/unverified.html" \
    --out-md "$tmp/unverified.md" >/dev/null
grep -q "^## Unverified" "$tmp/unverified.md" || fail "Unverified section must render when unverified is nonempty"
grep -q "#5" "$tmp/unverified.md" || fail "Unverified section must name the uncovered issue"
unv_order="$(grep -n '^## ' "$tmp/unverified.md" | cut -d: -f2)"
unv_lines=()
while IFS= read -r unv_line; do unv_lines+=("$unv_line"); done <<<"$unv_order"
bot_idx=-1
unverified_idx=-1
for i in "${!unv_lines[@]}"; do
    case "${unv_lines[$i]}" in
    *"Bot-owned"*) bot_idx="$i" ;;
    "## Unverified") unverified_idx="$i" ;;
    esac
done
[ "$bot_idx" -ge 0 ] && [ "$unverified_idx" -eq $((bot_idx + 1)) ] ||
    fail "Unverified must come right after Bot-owned issues"
run "$report" render --dispositions "$disp" --out-html "$tmp/no-unverified.html" \
    --out-md "$tmp/no-unverified.md" >/dev/null
grep -q "^## Unverified" "$tmp/no-unverified.md" && fail "Unverified section must not render when unverified is empty"

echo "==> report: a nonempty stats.unverified prevents the clean-backlog message even with zero close/decision/finding rows (Codex 4012242642)"
grep -qF "Nothing to do — backlog is clean this run." "$tmp/unverified.md" &&
    fail "an audit with unverified (unallocated) issues must never be reported as clean"
grep -qF "Nothing to do — backlog is clean this run." "$tmp/unverified.html" &&
    fail "the HTML render must never report an unverified audit as clean either"

echo "==> report: a genuinely clean audit (no close/decisions/findings/unverified) still reports clean"
clean_disp="$tmp/clean-disp.json"
cat >"$clean_disp" <<'JSON'
{"repo":"o/r","dispositions":[
  {"number":1,"title":"Still relevant","verdict":"KEEP","priority":"low","reason":"still needed","group":"ci"}
],"stats":{"open_total":1,"close_candidates":0,"decisions":0,"high_priority":0,"unverified":[]},"milestones":[]}
JSON
clean_md="$tmp/clean.md"
run "$report" render --dispositions "$clean_disp" --out-html "$tmp/clean.html" --out-md "$clean_md" >/dev/null
grep -qF "Nothing to do — backlog is clean this run." "$clean_md" ||
    fail "a genuinely clean audit must still report the backlog as clean"

echo "==> report: Parent issues and Milestones render from dataset proposals"
run "$report" render --dispositions "$proposals_disp" --out-html "$tmp/proposals.html" \
    --out-md "$tmp/proposals.md" >/dev/null
grep -q "#1 Parser work: #3, #4" "$tmp/proposals.md" ||
    fail "Parent issues must render a proposal's parent, title, and children in order"
grep -q "rename v1 → v1.1 (#3, #4)" "$tmp/proposals.md" ||
    fail "Milestones must render a proposal action/title/new_title/issues"
grep -q "Parser work" "$tmp/proposals.html" || fail "HTML must also render the parent proposal"
grep -q "v1.1" "$tmp/proposals.html" || fail "HTML must also render the milestone proposal"

echo "==> report: a nonexistent --outcomes path is an empty outcomes set, not an error (challenge round 2 confirming round, finding 2)"
missing_outcomes="$tmp/does-not-exist-yet/outcomes.jsonl"
[ ! -e "$missing_outcomes" ] || fail "test setup: outcomes path must not already exist"
[ "$(run "$report" render --dispositions "$disp" --outcomes "$missing_outcomes" \
    --out-html "$tmp/missing-outcomes.html" --out-md "$tmp/missing-outcomes.md")" = 0 ] ||
    fail "render with a nonexistent --outcomes path must exit 0: $(cat "$tmp/out" "$tmp/err")"
grep -q "no outcomes file yet at $missing_outcomes" "$tmp/err" ||
    fail "a missing --outcomes path must note it on stderr"
[ "$(grep -c '^| #[0-9]' "$tmp/missing-outcomes.md")" = 5 ] ||
    fail "every disposition row must still render in the Every issue table"
while IFS= read -r status_col; do
    [ "$status_col" = "PENDING" ] || fail "every row must be PENDING when --outcomes is missing: got '$status_col'"
done < <(awk -F'|' '/^\| #[0-9]/{n=NF-1; gsub(/^ +| +$/, "", $n); print $n}' "$tmp/missing-outcomes.md")

# ── groom-report.sh: GROOM_SCRATCH path binding (Codex 4011648576) ─────────
report_scratch="$tmp/report-scratch"
mkdir -p "$report_scratch"
cp "$disp" "$report_scratch/dispositions.json"

echo "==> report: --dispositions outside GROOM_SCRATCH is refused"
[ "$(run env GROOM_SCRATCH="$report_scratch" "$report" render --dispositions "$disp" \
    --out-html "$report_scratch/out.html" --out-md "$report_scratch/out.md")" = 4 ] ||
    fail "--dispositions outside the run's scratch dir must exit 4"
grep -q -- "must live under this run's scratch directory" "$tmp/err" ||
    fail "the refusal must explain the scratch-dir binding"

echo "==> report: --out-html outside GROOM_SCRATCH is refused, even when other paths are inside it"
[ "$(run env GROOM_SCRATCH="$report_scratch" "$report" render \
    --dispositions "$report_scratch/dispositions.json" \
    --out-html "$tmp/escape.html" --out-md "$report_scratch/out.md")" = 4 ] ||
    fail "--out-html outside the run's scratch dir must exit 4"
[ ! -f "$tmp/escape.html" ] || fail "a refused --out-html must never be written (prompt-injection escape)"

echo "==> report: --out-md outside GROOM_SCRATCH is refused"
[ "$(run env GROOM_SCRATCH="$report_scratch" "$report" render \
    --dispositions "$report_scratch/dispositions.json" \
    --out-html "$report_scratch/out.html" --out-md "$tmp/escape.md")" = 4 ] ||
    fail "--out-md outside the run's scratch dir must exit 4"
[ ! -f "$tmp/escape.md" ] || fail "a refused --out-md must never be written (prompt-injection escape)"

echo "==> report: --outcomes outside GROOM_SCRATCH is refused"
[ "$(run env GROOM_SCRATCH="$report_scratch" "$report" render \
    --dispositions "$report_scratch/dispositions.json" --outcomes "$tmp/escape-outcomes.jsonl" \
    --out-html "$report_scratch/out.html" --out-md "$report_scratch/out.md")" = 4 ] ||
    fail "--outcomes outside the run's scratch dir must exit 4"

echo "==> report: every path under GROOM_SCRATCH succeeds"
[ "$(run env GROOM_SCRATCH="$report_scratch" "$report" render \
    --dispositions "$report_scratch/dispositions.json" \
    --out-html "$report_scratch/out.html" --out-md "$report_scratch/out.md")" = 0 ] ||
    fail "render with every path under the scratch dir should succeed: $(cat "$tmp/out" "$tmp/err")"

# Challenge round 2, finding 1: guard_scratch_path's GROOM_SCRATCH
# canonicalization (#1079) had no missing-scratch or symlinked-scratch case
# in this file before these two.
echo "==> report: GROOM_SCRATCH itself missing is refused (exit 4)"
[ "$(run env GROOM_SCRATCH="$tmp/report-scratch-missing" "$report" render \
    --dispositions "$disp" --out-html "$tmp/report-scratch-missing/out.html" \
    --out-md "$tmp/report-scratch-missing/out.md")" = 4 ] ||
    fail "a missing GROOM_SCRATCH must exit 4: $(cat "$tmp/out" "$tmp/err")"
grep -q -- "does not exist" "$tmp/err" || fail "the refusal must say the scratch directory does not exist"

echo "==> report: every path inside a SYMLINKED GROOM_SCRATCH is still accepted"
report_scratch_link="$tmp/report-scratch-link"
ln -s "$report_scratch" "$report_scratch_link"
[ "$(run env GROOM_SCRATCH="$report_scratch_link" "$report" render \
    --dispositions "$report_scratch_link/dispositions.json" \
    --out-html "$report_scratch_link/symlink-out.html" \
    --out-md "$report_scratch_link/symlink-out.md")" = 0 ] ||
    fail "render through a symlinked scratch dir should still succeed: $(cat "$tmp/out" "$tmp/err")"
[ -f "$report_scratch/symlink-out.html" ] ||
    fail "the html output must actually land under the real scratch dir"

echo "==> apply-plan / groom-decide: a mismatched --repo is refused when the run is bound"
noop_plan="$tmp/noop-plan.jsonl"
: >"$noop_plan"
[ "$(run env GROOM_REPO="$repo" "$apply" apply-plan --repo other/elsewhere \
    --plan-file "$noop_plan" --log "$tmp/apply.log")" = 4 ] ||
    fail "unbound repo apply-plan must exit 4"
[ "$(run env GROOM_REPO="$repo" "$apply" apply-plan --repo "$repo" \
    --plan-file "$noop_plan" --log "$tmp/apply.log")" = 0 ] ||
    fail "bound repo apply-plan must pass"
printf 'placeholder decision text\n' >"$tmp/noop-decision.md"
[ "$(run env GROOM_REPO="$repo" "$decide" --repo other/elsewhere --issue 1 \
    --decision-file "$tmp/noop-decision.md")" = 4 ] ||
    fail "unbound repo decide must exit 4"

# ── groom-apply.sh: write gate ──────────────────────────────────────────────
cat >"$stub_dir/issue-30.json" <<'JSON'
{"title":"(ci): Fix parser bug","labels":[{"name":"needs-triage"}],"author":{"login":"someone","type":"User","is_bot":false}}
JSON
cat >"$stub_dir/issue-31.json" <<'JSON'
{"labels":[],"author":{"login":"dependabot[bot]","type":"Bot","is_bot":true}}
JSON
# validate_milestone_assign (Codex 4012242580) resolves this list in execute
# mode — reset it to a single page carrying "v1" (the groom-scan.sh section
# above left it at an empty page) so the write-gate tests below that assign
# "v1" keep passing.
cat >"$stub_dir/milestones.json" <<'JSON'
[{"number":1,"title":"v1","state":"open","description":"","open_issues":1,"closed_issues":0}]
JSON

echo "==> apply-plan: dry-run writes nothing"
plan="$tmp/plan.jsonl"
cat >"$plan" <<'JSONL'
{"op":"close","issue":30,"reason":"completed","comment":"done","bot_owned":false}
{"op":"retitle","issue":30,"title":"(ci): Fix the parser","previous_title":"(ci): Fix parser bug","bot_owned":false}
{"op":"milestone-assign","issue":30,"milestone_title":"v1","bot_owned":false}
{"op":"sub-issue-link","parent":1,"child":30}
JSONL
: >"$GH_STUB_LOG"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$plan" --log "$tmp/apply.log")" = 0 ] ||
    fail "dry-run apply-plan should succeed: $(cat "$tmp/out" "$tmp/err")"
grep -q "^PLAN " "$tmp/out" || fail "dry-run must print PLAN lines"
grep -qE "^issue (close|edit)" "$GH_STUB_LOG" && fail "dry-run must not call a gh write command"
[ ! -s "$tmp/apply.log" ] || fail "dry-run must not write the log file"

echo "==> apply-plan: --execute without GROOM_EXECUTE=1 is refused, writes nothing"
: >"$GH_STUB_LOG"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$plan" --log "$tmp/apply.log" --execute)" = 2 ] ||
    fail "--execute without the env gate must exit 2"
grep -qE "^issue (close|edit)" "$GH_STUB_LOG" && fail "refused execute must not call a gh write command"
[ ! -s "$tmp/apply.log" ] || fail "refused execute must not write the log file"

echo "==> apply-plan: --execute with the env gate applies and logs every write"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$plan" \
    --log "$tmp/apply.log" --execute)" = 0 ] ||
    fail "gated execute should succeed: $(cat "$tmp/out" "$tmp/err")"
grep -q "^WRITE gh issue close 30" "$tmp/apply.log" || fail "close must be logged before running"
grep -q "^WRITE gh issue edit 30 .*--title" "$tmp/apply.log" || fail "retitle must be logged"
grep -q "^WRITE gh issue edit 30 .*--milestone v1" "$tmp/apply.log" || fail "milestone-assign must be logged"
grep -q "^WRITE gh api repos/$repo/issues/1/sub_issues" "$tmp/apply.log" || fail "sub-issue-link must be logged"
grep -q "^issue close 30 " "$GH_STUB_LOG" || fail "close must actually run"

echo "==> apply-plan: milestone-assign is resolved against the repo's real milestone list in pass 1, before any write (Codex 4012242580)"
unknown_milestone_plan="$tmp/unknown-milestone-plan.jsonl"
cat >"$unknown_milestone_plan" <<'JSONL'
{"op":"close","issue":30,"reason":"completed","bot_owned":false}
{"op":"milestone-assign","issue":30,"milestone_title":"does-not-exist","bot_owned":false}
JSONL
: >"$GH_STUB_LOG"
unknown_milestone_log="$tmp/unknown-milestone.log"
: >"$unknown_milestone_log"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$unknown_milestone_plan" \
    --log "$unknown_milestone_log" --execute)" = 4 ] ||
    fail "a milestone_title absent from the repo's milestones must exit 4: $(cat "$tmp/out" "$tmp/err")"
grep -q "does-not-exist" "$tmp/err" || fail "the refusal must name the unresolved milestone title"
grep -qE "^issue close 30" "$GH_STUB_LOG" &&
    fail "an unresolvable milestone in a later row must prevent EVERY write, including an earlier valid close"
grep -q "^WRITE " "$unknown_milestone_log" && fail "no WRITE lines should be logged when pass 1 refuses"

echo "==> apply-plan: milestone-assign is not resolved against the live milestone list in dry-run mode"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$unknown_milestone_plan" \
    --log "$tmp/unknown-milestone-dry.log")" = 0 ] ||
    fail "dry-run must not resolve milestone titles: $(cat "$tmp/out" "$tmp/err")"
grep -q "^PLAN " "$tmp/out" || fail "dry-run must still print the PLAN line"

echo "==> apply-plan: milestone-assign also preflights the TARGET issue in pass 1; an unresolvable target aborts before ANY write (Codex 4012885414)"
unresolvable_target_plan="$tmp/unresolvable-target-plan.jsonl"
cat >"$unresolvable_target_plan" <<'JSONL'
{"op":"close","issue":30,"reason":"completed","bot_owned":false}
{"op":"milestone-assign","issue":80,"milestone_title":"v1","bot_owned":false}
JSONL
: >"$GH_STUB_LOG"
unresolvable_target_log="$tmp/unresolvable-target.log"
: >"$unresolvable_target_log"
[ "$(run env GROOM_EXECUTE=1 GH_STUB_UNRESOLVABLE_ISSUE=80 "$apply" apply-plan \
    --repo "$repo" --plan-file "$unresolvable_target_plan" \
    --log "$unresolvable_target_log" --execute)" = 4 ] ||
    fail "an unresolvable milestone-assign target must exit 4 in pass 1: $(cat "$tmp/out" "$tmp/err")"
grep -q "#80" "$tmp/err" || fail "the refusal must name the unresolvable target issue"
grep -qE "^issue close 30" "$GH_STUB_LOG" &&
    fail "an unresolvable milestone-assign target in a later row must prevent EVERY write, including an earlier valid close"
grep -q "^WRITE " "$unresolvable_target_log" && fail "no WRITE lines should be logged when pass 1 refuses"

echo "==> apply-plan: milestone-assign's target-issue preflight does not run in dry-run mode"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$unresolvable_target_plan" \
    --log "$tmp/unresolvable-target-dry.log")" = 0 ] ||
    fail "dry-run must not resolve the milestone-assign target issue: $(cat "$tmp/out" "$tmp/err")"
grep -q "^PLAN " "$tmp/out" || fail "dry-run must still print the PLAN line"

echo "==> apply-plan: WRITE log lines preserve argv boundaries for values containing spaces and quotes (Codex 4012242585)"
tricky_comment="two words and a 'single quote'"
quote_plan="$tmp/quote-plan.jsonl"
jq -nc --arg comment "$tricky_comment" \
    '{"op":"close","issue":30,"reason":"completed","comment":$comment,"bot_owned":false}' >"$quote_plan"
: >"$GH_STUB_LOG"
quote_log="$tmp/quote.log"
: >"$quote_log"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$quote_plan" \
    --log "$quote_log" --execute)" = 0 ] ||
    fail "execute with a comment containing spaces and a quote should succeed: $(cat "$tmp/out" "$tmp/err")"
write_line="$(grep '^WRITE gh issue close 30' "$quote_log" | tail -1)"
[ -n "$write_line" ] || fail "close must be logged"
reconstructed=()
eval "reconstructed=(${write_line#WRITE })"
last_idx=$((${#reconstructed[@]} - 1))
[ "${reconstructed[$last_idx]}" = "$tricky_comment" ] ||
    fail "the logged WRITE line must reconstruct the exact comment argument:" \
        "got '${reconstructed[$last_idx]:-}' from '$write_line'"

echo "==> apply-plan: dry-run PLAN lines also preserve argv boundaries for values containing spaces and quotes (Codex 4012885429)"
: >"$GH_STUB_LOG"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$quote_plan" --log "$tmp/quote-dry.log")" = 0 ] ||
    fail "dry-run with a tricky comment should succeed: $(cat "$tmp/out" "$tmp/err")"
plan_line="$(grep '^PLAN gh issue close 30' "$tmp/out" | tail -1)"
[ -n "$plan_line" ] || fail "close must be PLANned"
plan_reconstructed=()
eval "plan_reconstructed=(${plan_line#PLAN })"
plan_last_idx=$((${#plan_reconstructed[@]} - 1))
[ "${plan_reconstructed[$plan_last_idx]}" = "$tricky_comment" ] ||
    fail "the PLAN line must reconstruct the exact comment argument:" \
        "got '${plan_reconstructed[$plan_last_idx]:-}' from '$plan_line'"

echo "==> apply-plan: pass 1 validates every row before pass 2 writes any (finding 5)"
partial_plan="$tmp/partial-plan.jsonl"
cat >"$partial_plan" <<'JSONL'
{"op":"close","issue":30,"reason":"completed","bot_owned":false}
{"op":"milestone-assign","issue":30,"milestone_title":"v1","bot_owned":false}
{"op":"bogus-op","issue":30}
JSONL
: >"$GH_STUB_LOG"
partial_log="$tmp/partial.log"
: >"$partial_log"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$partial_plan" \
    --log "$partial_log" --execute)" = 4 ] ||
    fail "a plan with an unknown op must exit 4"
grep -qE "^issue (close|edit)" "$GH_STUB_LOG" &&
    fail "an invalid row later in the plan must prevent EVERY write, including earlier valid rows"
grep -q "^WRITE " "$partial_log" && fail "no WRITE lines should be logged when pass 1 refuses"

echo "==> apply-plan: a rerun appends to the log instead of truncating it (finding 5)"
rerun_log="$tmp/rerun-apply.log"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$plan" \
    --log "$rerun_log" --execute)" = 0 ] ||
    fail "first execute run should succeed: $(cat "$tmp/out" "$tmp/err")"
first_lines="$(wc -l <"$rerun_log")"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$plan" \
    --log "$rerun_log" --execute)" = 0 ] ||
    fail "second execute run should succeed: $(cat "$tmp/out" "$tmp/err")"
second_lines="$(wc -l <"$rerun_log")"
[ "$second_lines" -gt "$first_lines" ] || fail "a rerun must APPEND to the log, not truncate it"
[ "$(grep -c '^# run ' "$rerun_log")" = 2 ] || fail "each execute run must add its own header line"
[ "$(grep -c '^WRITE gh issue close 30' "$rerun_log")" = 2 ] ||
    fail "earlier WRITE lines must be preserved across a rerun"

echo "==> apply-plan: --outcomes records one DONE entry per applied write (finding 8)"
outcomes_file="$tmp/outcomes.jsonl"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$plan" \
    --log "$tmp/outcomes-apply.log" --outcomes "$outcomes_file" --execute)" = 0 ] ||
    fail "gated execute with --outcomes should succeed: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -s '[.[] | select(.issue == 30 and .op == "close" and .status == "DONE")] | length' "$outcomes_file")" -ge 1 ] ||
    fail "close outcome must be recorded"
[ "$(jq -s '[.[] | select(.issue == 30 and .op == "retitle" and .status == "DONE")] | length' "$outcomes_file")" -ge 1 ] ||
    fail "retitle outcome must be recorded"
[ "$(jq -s '[.[] | select(.issue == 30 and .op == "milestone-assign" and .status == "DONE")] | length' "$outcomes_file")" -ge 1 ] ||
    fail "milestone-assign outcome must be recorded"
[ "$(jq -s '[.[] | select(.issue == 30 and .op == "sub-issue-link" and .status == "DONE")] | length' "$outcomes_file")" -ge 1 ] ||
    fail "sub-issue-link outcome must be recorded against the child issue"

echo "==> apply-plan: dry-run never writes to --outcomes"
dry_outcomes="$tmp/dry-outcomes.jsonl"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$plan" --log "$tmp/dry-apply.log" \
    --outcomes "$dry_outcomes")" = 0 ] || fail "dry-run with --outcomes should succeed"
[ ! -s "$dry_outcomes" ] || fail "dry-run must never write to --outcomes"

echo "==> apply-plan: sub-issue-link ids are resolved in pass 1; an inaccessible child aborts before ANY write (Codex 4011648563)"
sub_issue_plan="$tmp/sub-issue-plan.jsonl"
cat >"$sub_issue_plan" <<'JSONL'
{"op":"close","issue":30,"reason":"completed","bot_owned":false}
{"op":"sub-issue-link","parent":1,"child":70}
JSONL
: >"$GH_STUB_LOG"
sub_issue_log="$tmp/sub-issue.log"
: >"$sub_issue_log"
[ "$(run env GROOM_EXECUTE=1 GH_STUB_UNRESOLVABLE_ISSUE=70 "$apply" apply-plan \
    --repo "$repo" --plan-file "$sub_issue_plan" --log "$sub_issue_log" --execute)" = 4 ] ||
    fail "an inaccessible sub-issue-link child must exit 4 in pass 1: $(cat "$tmp/out" "$tmp/err")"
grep -qE "^issue close 30" "$GH_STUB_LOG" &&
    fail "an unresolvable child in a later row must prevent EVERY write, including an earlier valid close"
grep -q "^WRITE " "$sub_issue_log" && fail "no WRITE lines should be logged when pass 1 refuses"
grep -q "#70" "$tmp/err" || fail "the refusal must name the unresolvable child issue"

echo "==> apply-plan: sub-issue-link with an inaccessible PARENT also aborts before any write"
sub_issue_parent_plan="$tmp/sub-issue-parent-plan.jsonl"
printf '%s\n' '{"op":"sub-issue-link","parent":99,"child":30}' >"$sub_issue_parent_plan"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 GH_STUB_UNRESOLVABLE_ISSUE=99 "$apply" apply-plan \
    --repo "$repo" --plan-file "$sub_issue_parent_plan" --log "$tmp/sub-issue-parent.log" \
    --execute)" = 4 ] ||
    fail "an inaccessible sub-issue-link parent must exit 4 in pass 1: $(cat "$tmp/out" "$tmp/err")"
grep -q "#99" "$tmp/err" || fail "the refusal must name the unresolvable parent issue"

echo "==> apply-plan: sub-issue-link refuses (exit 2) when the RESOLVED parent and child ids are equal, e.g. '1' vs '01' (Codex 4012885462)"
self_ref_plan="$tmp/self-ref-sub-issue-plan.jsonl"
printf '%s\n' '{"op":"sub-issue-link","parent":1,"child":"01"}' >"$self_ref_plan"
: >"$GH_STUB_LOG"
self_ref_log="$tmp/self-ref-sub-issue.log"
: >"$self_ref_log"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$self_ref_plan" \
    --log "$self_ref_log" --execute)" = 2 ] ||
    fail "a self-referential sub-issue-link (parent/child resolving to the same id) must exit 2: $(cat "$tmp/out" "$tmp/err")"
grep -q "^WRITE " "$self_ref_log" && fail "no WRITE lines should be logged when pass 1 refuses"

echo "==> apply-plan: sub-issue-link ids are not resolved in dry-run mode"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$sub_issue_plan" \
    --log "$tmp/sub-issue-dry.log")" = 0 ] ||
    fail "dry-run must not resolve sub-issue-link ids: $(cat "$tmp/out" "$tmp/err")"
grep -q "^PLAN " "$tmp/out" || fail "dry-run must still print the PLAN line"

echo "==> apply-plan: a 'completed' close is refused in execute mode when the live body still has an unticked task item (Codex 4011648601)"
cat >"$stub_dir/issue-60.json" <<'JSON'
{"title":"(ci): task with open work","labels":[],"author":{"login":"someone","type":"User","is_bot":false},"body":"## Acceptance criteria\n\n- [ ] [CI] still open\n"}
JSON
unticked_plan="$tmp/unticked-plan.jsonl"
printf '%s\n' '{"op":"close","issue":60,"reason":"completed","bot_owned":false}' >"$unticked_plan"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$unticked_plan" \
    --log "$tmp/unticked.log" --execute)" = 4 ] ||
    fail "a completed close with an unticked body item must exit 4"
grep -qi "unticked" "$tmp/err" || fail "refusal must explain the unticked item"
grep -qE "^issue close 60" "$GH_STUB_LOG" && fail "an unticked completed close must never call gh issue close"

echo "==> apply-plan: a 'completed' close proceeds when the live body has every item ticked"
cat >"$stub_dir/issue-61.json" <<'JSON'
{"title":"(ci): task all done","labels":[],"author":{"login":"someone","type":"User","is_bot":false},"body":"## Acceptance criteria\n\n- [x] [CI] done\n"}
JSON
ticked_plan="$tmp/ticked-plan.jsonl"
printf '%s\n' '{"op":"close","issue":61,"reason":"completed","bot_owned":false}' >"$ticked_plan"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$ticked_plan" \
    --log "$tmp/ticked.log" --execute)" = 0 ] ||
    fail "a completed close with every item ticked should succeed: $(cat "$tmp/out" "$tmp/err")"
grep -qE "^issue close 61" "$GH_STUB_LOG" || fail "a fully-ticked completed close must actually run"

echo "==> apply-plan: a 'completed' close is refused when the unticked item is blockquoted (Codex 4012885453)"
cat >"$stub_dir/issue-63.json" <<'JSON'
{"title":"(ci): task with a carried-over item","labels":[],"author":{"login":"someone","type":"User","is_bot":false},"body":"## Acceptance criteria\n\n> - [ ] carried over from another issue\n"}
JSON
blockquoted_unticked_plan="$tmp/blockquoted-unticked-plan.jsonl"
printf '%s\n' '{"op":"close","issue":63,"reason":"completed","bot_owned":false}' >"$blockquoted_unticked_plan"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$blockquoted_unticked_plan" \
    --log "$tmp/blockquoted-unticked.log" --execute)" = 4 ] ||
    fail "a completed close with a blockquoted unticked item must exit 4: $(cat "$tmp/out" "$tmp/err")"
grep -qi "unticked" "$tmp/err" || fail "refusal must explain the unticked item"
grep -qE "^issue close 63" "$GH_STUB_LOG" && fail "a blockquoted unticked completed close must never call gh issue close"

echo "==> apply-plan: the unticked body re-check does not run in dry-run mode"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$unticked_plan" --log "$tmp/unticked-dry.log")" = 0 ] ||
    fail "dry-run must not perform the live-body re-check: $(cat "$tmp/out" "$tmp/err")"
grep -q "^PLAN " "$tmp/out" || fail "dry-run must still print the PLAN line"

echo "==> apply-plan: dry-run prints a NOTE when the plan row's own 'unticked' hint is set"
hint_plan="$tmp/hint-plan.jsonl"
printf '%s\n' '{"op":"close","issue":62,"reason":"completed","bot_owned":false,"unticked":true}' >"$hint_plan"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$hint_plan" --log "$tmp/hint.log")" = 0 ] ||
    fail "dry-run with an unticked hint should still succeed: $(cat "$tmp/out" "$tmp/err")"
grep -q "^NOTE #62" "$tmp/out" || fail "dry-run must print a NOTE for the plan row's own unticked hint"

echo "==> apply-plan: retitle refuses (exit 4) when the live title no longer matches previous_title (finding 6)"
stale_plan="$tmp/stale-retitle-plan.jsonl"
printf '%s\n' '{"op":"retitle","issue":30,"title":"(ci): Fix the parser","previous_title":"(ci): a totally different title","bot_owned":false}' >"$stale_plan"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$stale_plan" \
    --log "$tmp/stale.log" --execute)" = 4 ] ||
    fail "a stale previous_title must be refused in execute mode"
grep -q "no longer matches" "$tmp/err" || fail "refusal must explain the live-title mismatch"
grep -qE "^issue edit 30" "$GH_STUB_LOG" && fail "a refused retitle must never call gh issue edit"

echo "==> apply-plan: retitle's live-title check does not run in dry-run mode"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$stale_plan" --log "$tmp/stale-dry.log")" = 0 ] ||
    fail "dry-run must not perform the live-title re-check: $(cat "$tmp/out" "$tmp/err")"
grep -q "^PLAN " "$tmp/out" || fail "dry-run must still print the PLAN line"

echo "==> apply-plan: pass 1 refuses (exit 2) two plan rows naming the same op+issue (finding 4)"
dup_op_plan="$tmp/dup-op-plan.jsonl"
cat >"$dup_op_plan" <<'JSONL'
{"op":"retitle","issue":50,"title":"New A","previous_title":"Original title","bot_owned":false}
{"op":"retitle","issue":50,"title":"New B","previous_title":"Original title","bot_owned":false}
JSONL
: >"$GH_STUB_LOG"
dup_op_log="$tmp/dup-op.log"
: >"$dup_op_log"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$dup_op_plan" --log "$dup_op_log")" = 2 ] ||
    fail "two retitle rows for the same issue must exit 2: $(cat "$tmp/out" "$tmp/err")"
grep -q "#50" "$tmp/err" || fail "duplicate refusal must name the issue number"
[ ! -s "$dup_op_log" ] || fail "a pass-0 duplicate refusal must not write the log file"

echo "==> apply-plan: retitle refuses (exit 4) as a pass-2 conflict when a concurrent edit lands between pass 1 and pass 2 (finding 4)"
cat >"$stub_dir/issue-50.json" <<'JSON'
{"title":"(ci): Original title","labels":[],"author":{"login":"someone","type":"User","is_bot":false}}
JSON
cat >"$stub_dir/issue-50-race.json" <<'JSON'
{"title":"(ci): Changed by someone else","labels":[],"author":{"login":"someone","type":"User","is_bot":false}}
JSON
race_plan="$tmp/race-plan.jsonl"
printf '%s\n' '{"op":"retitle","issue":50,"title":"(ci): New title","previous_title":"(ci): Original title","bot_owned":false}' >"$race_plan"
race_counter="$tmp/race-counter"
rm -f "$race_counter"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 GH_STUB_RACE_ISSUE=50 GH_STUB_RACE_COUNTER="$race_counter" \
    "$apply" apply-plan --repo "$repo" --plan-file "$race_plan" \
    --log "$tmp/race.log" --execute)" = 4 ] ||
    fail "a pass-2 title conflict must exit 4: $(cat "$tmp/out" "$tmp/err")"
grep -q "conflicts with a" "$tmp/err" || fail "pass-2 refusal must report a conflict, not a plain validation failure"
grep -q "plan row 1" "$tmp/err" || fail "pass-2 refusal must name the plan row number"
grep -qE "^issue edit 50" "$GH_STUB_LOG" && fail "a pass-2-refused retitle must never call gh issue edit"

echo "==> apply-plan: pass 1 refuses (exit 4) a label op triage-apply.sh's own dry run would reject, before any write (finding 3)"
label_never_plan="$tmp/label-never-list-plan.jsonl"
cat >"$label_never_plan" <<'JSONL'
{"op":"close","issue":30,"reason":"completed","bot_owned":false}
{"op":"label","issue":30,"add":["rigor:high"],"bot_owned":false}
JSONL
: >"$GH_STUB_LOG"
label_never_log="$tmp/label-never.log"
: >"$label_never_log"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$label_never_plan" \
    --log "$label_never_log" --execute)" = 4 ] ||
    fail "a never-list label op must exit 4 in pass 1: $(cat "$tmp/out" "$tmp/err")"
grep -qE "^issue close" "$GH_STUB_LOG" &&
    fail "a pass-1-refused label op must prevent the earlier valid close from writing too"
grep -q "^WRITE " "$label_never_log" && fail "no WRITE lines should be logged when pass 1 refuses"

echo "==> apply-plan: an unwritable --outcomes sink is refused in pass 1, before any write (finding 8)"
: >"$GH_STUB_LOG"
outcomes_refuse_log="$tmp/outcomes-refuse.log"
: >"$outcomes_refuse_log"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$plan" \
    --log "$outcomes_refuse_log" --outcomes "$tmp/does-not-exist/outcomes.jsonl" --execute)" = 2 ] ||
    fail "an unwritable --outcomes path must exit 2: $(cat "$tmp/out" "$tmp/err")"
grep -qE "^issue (close|edit)" "$GH_STUB_LOG" && fail "a refused --outcomes sink must prevent every write"

echo "==> apply-plan: a bot-owned issue is refused for close/retitle/label"
bot_plan="$tmp/bot-plan.jsonl"
printf '%s\n' '{"op":"close","issue":31,"reason":"completed","bot_owned":true}' >"$bot_plan"
: >"$GH_STUB_LOG"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$bot_plan" --log "$tmp/apply.log")" = 4 ] ||
    fail "bot-owned close must exit 4"
grep -q "bot-authored" "$tmp/err" || fail "refusal must say why"

echo "==> apply-plan: closes above --max-closes are refused before any write"
many_plan="$tmp/many-plan.jsonl"
: >"$many_plan"
for n in $(seq 1 3); do
    printf '{"op":"close","issue":%d,"reason":"completed","bot_owned":false}\n' "$n" >>"$many_plan"
done
: >"$GH_STUB_LOG"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$many_plan" --log "$tmp/apply.log" \
    --max-closes 2)" = 2 ] || fail "over-cap plan must exit 2"
[ -s "$GH_STUB_LOG" ] && fail "an over-cap plan must not touch gh at all"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$many_plan" --log "$tmp/apply.log" \
    --max-closes 5)" = 0 ] || fail "an explicit higher --max-closes must be honored"

echo "==> apply-plan: a non-numeric --max-closes is refused, never silently ignored"
: >"$GH_STUB_LOG"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$many_plan" --log "$tmp/apply.log" \
    --max-closes abc)" = 2 ] || fail "non-numeric --max-closes must exit 2"
[ -s "$GH_STUB_LOG" ] && fail "a refused --max-closes must not touch gh at all"

echo "==> apply-plan: a malformed plan file is refused with a documented exit code"
: >"$GH_STUB_LOG"
printf 'not valid json at all\n' >"$tmp/malformed-plan.jsonl"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$tmp/malformed-plan.jsonl" \
    --log "$tmp/apply.log")" = 2 ] || fail "a malformed plan file must exit 2 (documented), not a raw jq code"

echo "==> apply-plan: a 'duplicate' close with no canonical-issue comment is refused (Codex 4012242606)"
no_pointer_plan="$tmp/no-pointer-plan.jsonl"
printf '%s\n' '{"op":"close","issue":30,"reason":"duplicate","comment":"see the other one","bot_owned":false}' >"$no_pointer_plan"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$no_pointer_plan" --log "$tmp/apply.log")" = 2 ] ||
    fail "a duplicate close whose comment names no canonical issue must exit 2"
grep -qi "canonical issue" "$tmp/err" || fail "refusal must explain the missing canonical pointer"

echo "==> apply-plan: a 'duplicate' close whose comment names itself is refused"
self_pointer_plan="$tmp/self-pointer-plan.jsonl"
printf '%s\n' '{"op":"close","issue":30,"reason":"duplicate","comment":"same as #30","bot_owned":false}' >"$self_pointer_plan"
[ "$(run "$apply" apply-plan --repo "$repo" --plan-file "$self_pointer_plan" --log "$tmp/apply.log")" = 2 ] ||
    fail "a duplicate close pointing at itself must exit 2"
grep -qi "names itself" "$tmp/err" || fail "refusal must explain the self-referential pointer"

echo "==> apply-plan: a 'duplicate' close with a distinct canonical-issue pointer proceeds"
good_pointer_plan="$tmp/good-pointer-plan.jsonl"
printf '%s\n' '{"op":"close","issue":30,"reason":"duplicate","comment":"same as #12","bot_owned":false}' >"$good_pointer_plan"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 "$apply" apply-plan --repo "$repo" --plan-file "$good_pointer_plan" \
    --log "$tmp/good-pointer.log" --execute)" = 0 ] ||
    fail "a duplicate close with a distinct canonical pointer should succeed: $(cat "$tmp/out" "$tmp/err")"
grep -qE "^issue close 30" "$GH_STUB_LOG" || fail "a well-formed duplicate close must actually run"

# ── groom-decide.sh ──────────────────────────────────────────────────────────
decision_file="$tmp/decision.md"
printf 'We are closing #40 in favor of #12 because it duplicates the same fix.\n' >"$decision_file"

echo "==> groom-decide: dry-run prints PLAN lines and writes nothing"
: >"$GH_STUB_LOG"
[ "$(run "$decide" --repo "$repo" --issue 12 --decision-file "$decision_file" \
    --supersedes 40 --blocked-by 7)" = 0 ] || fail "dry-run decide should succeed: $(cat "$tmp/out" "$tmp/err")"
grep -q "^PLAN " "$tmp/out" || fail "dry-run decide must print PLAN lines"
grep -qE "^issue (close|comment|edit) " "$GH_STUB_LOG" &&
    fail "dry-run decide must not call a gh write command"

echo "==> groom-decide: --supersedes equal to --issue is refused before any write (self-reference, Codex 4011648597)"
: >"$GH_STUB_LOG"
[ "$(run "$decide" --repo "$repo" --issue 12 --decision-file "$decision_file" \
    --supersedes 12)" = 2 ] || fail "a --supersedes equal to --issue must exit 2"
[ -s "$GH_STUB_LOG" ] && fail "a self-referential --supersedes must never call gh at all"

echo "==> groom-decide: --blocked-by equal to --issue is refused before any write (self-reference)"
: >"$GH_STUB_LOG"
[ "$(run "$decide" --repo "$repo" --issue 12 --decision-file "$decision_file" \
    --blocked-by 12)" = 2 ] || fail "a --blocked-by equal to --issue must exit 2"
[ -s "$GH_STUB_LOG" ] && fail "a self-referential --blocked-by must never call gh at all"

echo "==> groom-decide: a duplicate --supersedes value is refused"
: >"$GH_STUB_LOG"
[ "$(run "$decide" --repo "$repo" --issue 12 --decision-file "$decision_file" \
    --supersedes 40 --supersedes 40)" = 2 ] || fail "a duplicate --supersedes must exit 2"
[ -s "$GH_STUB_LOG" ] && fail "a duplicate --supersedes must never call gh at all"

echo "==> groom-decide: a duplicate --blocked-by value is refused"
: >"$GH_STUB_LOG"
[ "$(run "$decide" --repo "$repo" --issue 12 --decision-file "$decision_file" \
    --blocked-by 7 --blocked-by 7)" = 2 ] || fail "a duplicate --blocked-by must exit 2"
[ -s "$GH_STUB_LOG" ] && fail "a duplicate --blocked-by must never call gh at all"

echo "==> groom-decide: a number in BOTH --supersedes and --blocked-by is refused (Codex 4012242629)"
: >"$GH_STUB_LOG"
[ "$(run "$decide" --repo "$repo" --issue 12 --decision-file "$decision_file" \
    --supersedes 40 --blocked-by 40)" = 2 ] ||
    fail "a number in both --supersedes and --blocked-by must exit 2"
[ -s "$GH_STUB_LOG" ] && fail "a supersedes/blocked-by intersection must never call gh at all"

echo "==> groom-decide: an empty decision file is refused before any write (Codex 4012242616)"
empty_decision_file="$tmp/empty-decision.md"
: >"$empty_decision_file"
: >"$GH_STUB_LOG"
[ "$(run "$decide" --repo "$repo" --issue 12 --decision-file "$empty_decision_file")" = 2 ] ||
    fail "an empty decision file must exit 2"
[ -s "$GH_STUB_LOG" ] && fail "an empty decision file must never call gh at all"

echo "==> groom-decide: a whitespace-only decision file is refused before any write"
ws_decision_file="$tmp/ws-decision.md"
printf '   \n\t\n' >"$ws_decision_file"
: >"$GH_STUB_LOG"
[ "$(run "$decide" --repo "$repo" --issue 12 --decision-file "$ws_decision_file")" = 2 ] ||
    fail "a whitespace-only decision file must exit 2"
[ -s "$GH_STUB_LOG" ] && fail "a whitespace-only decision file must never call gh at all"

echo "==> groom-decide: a bot-owned --supersedes sibling is refused, even in dry-run"
cat >"$stub_dir/issue-41.json" <<'JSON'
{"labels":[],"author":{"login":"renovate[bot]","type":"Bot","is_bot":true}}
JSON
: >"$GH_STUB_LOG"
[ "$(run "$decide" --repo "$repo" --issue 12 --decision-file "$decision_file" \
    --supersedes 41)" = 4 ] || fail "bot-owned supersedes must exit 4 (dry-run)"
grep -q "bot-authored" "$tmp/err" || fail "refusal must say why"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 "$decide" --repo "$repo" --issue 12 \
    --decision-file "$decision_file" --supersedes 41 --log "$tmp/decide-bot.log" --execute)" = 4 ] ||
    fail "bot-owned supersedes must exit 4 (execute)"
grep -qE "^issue close 41 " "$GH_STUB_LOG" && fail "a bot-owned sibling must never be closed"
grep -qE "^issue comment 12 " "$GH_STUB_LOG" &&
    fail "preflight (finding 7) must refuse a bot-owned supersedes BEFORE posting the decision comment"

echo "==> groom-decide: a --blocked-by target's id is resolved before the decision comment posts (finding 7)"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 "$decide" --repo "$repo" --issue 12 \
    --decision-file "$decision_file" --supersedes 41 --blocked-by 7 \
    --log "$tmp/decide-bot2.log" --execute)" = 4 ] ||
    fail "a bot-owned supersedes must still refuse before any blocked-by/comment work"
grep -qE "^issue comment 12 " "$GH_STUB_LOG" && fail "no comment must post when preflight refuses"
grep -qE "^api repos/$repo/issues/12/dependencies/blocked_by" "$GH_STUB_LOG" &&
    fail "no blocked-by edge must be added when preflight refuses"

echo "==> groom-decide: --execute refuses (exit 4) before any write when the issue-dependencies endpoint is unavailable (Codex 4012885483)"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 GH_STUB_FAIL_DEPENDENCIES=1 "$decide" --repo "$repo" --issue 12 \
    --decision-file "$decision_file" --supersedes 40 --blocked-by 7 \
    --log "$tmp/decide-dep-fail.log" --execute)" = 4 ] ||
    fail "an unavailable issue-dependencies endpoint must exit 4: $(cat "$tmp/out" "$tmp/err")"
grep -qi "dependencies" "$tmp/err" || fail "the refusal must mention the dependencies endpoint"
grep -qE "^issue comment 12 " "$GH_STUB_LOG" &&
    fail "no comment must post when the dependency-endpoint probe refuses"
grep -qE "^issue close 40 " "$GH_STUB_LOG" &&
    fail "no supersedes close must run when the dependency-endpoint probe refuses"
grep -q "^WRITE " "$tmp/decide-dep-fail.log" && fail "no WRITE lines should be logged when the probe refuses"

echo "==> groom-decide: without --blocked-by, the dependency-endpoint probe never runs"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 GH_STUB_FAIL_DEPENDENCIES=1 "$decide" --repo "$repo" --issue 12 \
    --decision-file "$decision_file" --supersedes 40 \
    --log "$tmp/decide-no-blocked-by.log" --execute)" = 0 ] ||
    fail "a decision with no --blocked-by must succeed even when the dependencies endpoint is down: $(cat "$tmp/out" "$tmp/err")"

echo "==> groom-decide: dry-run prints the dependency-endpoint probe as a PLAN line, never calling gh"
: >"$GH_STUB_LOG"
[ "$(run "$decide" --repo "$repo" --issue 12 --decision-file "$decision_file" \
    --blocked-by 7)" = 0 ] || fail "dry-run with --blocked-by should succeed: $(cat "$tmp/out" "$tmp/err")"
grep -q "^PLAN gh api repos/$repo/issues/12/dependencies/blocked_by" "$tmp/out" ||
    fail "dry-run must print the dependency-endpoint probe as a PLAN line"
grep -qE "^api repos/$repo/issues/12/dependencies/blocked_by" "$GH_STUB_LOG" &&
    fail "dry-run must never actually call the dependency-endpoint probe"

echo "==> groom-decide: --execute without the env gate is refused"
[ "$(run "$decide" --repo "$repo" --issue 12 --decision-file "$decision_file" --execute)" = 2 ] ||
    fail "--execute without GROOM_EXECUTE=1 must exit 2"

echo "==> groom-decide: --execute without --log is refused, writes nothing (Codex 4011648572)"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 "$decide" --repo "$repo" --issue 12 \
    --decision-file "$decision_file" --supersedes 40 --execute)" = 2 ] ||
    fail "--execute without --log must exit 2"
grep -qE "^issue (close|comment) " "$GH_STUB_LOG" && fail "refused execute must not call a gh write command"

echo "==> groom-decide: --execute posts the comment, closes the sibling, adds the edge, and logs every write"
decide_log="$tmp/decide.log"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 GROOM_NOW_DATE=2026-01-02 "$decide" --repo "$repo" --issue 12 \
    --decision-file "$decision_file" --supersedes 40 --blocked-by 7 \
    --log "$decide_log" --execute)" = 0 ] ||
    fail "gated decide should succeed: $(cat "$tmp/out" "$tmp/err")"
grep -q "^issue comment 12 " "$GH_STUB_LOG" || fail "decide must post the decision comment"
grep -q "^issue close 40 .*not planned" "$GH_STUB_LOG" || fail "decide must close the superseded sibling"
grep -q "^api repos/$repo/issues/12/dependencies/blocked_by" "$GH_STUB_LOG" ||
    fail "decide must add the blocked-by edge"
grep -q "^# run " "$decide_log" || fail "an execute run must write a header line to --log"
grep -q "^WRITE gh issue comment 12" "$decide_log" || fail "the decision comment must be logged before it runs"
grep -q "^WRITE gh issue close 40" "$decide_log" || fail "the superseded-sibling close must be logged"
grep -q "^WRITE gh api repos/$repo/issues/12/dependencies/blocked_by" "$decide_log" ||
    fail "the blocked-by edge must be logged"

echo "==> groom-decide: the decision comment's WRITE line logs the ACTUAL argv and its body-sha256, not the old placeholder (Codex 4012885422)"
comment_write_line="$(grep '^WRITE gh issue comment 12' "$decide_log" | tail -1)"
[ -n "$comment_write_line" ] || fail "the decision comment WRITE line must exist"
case "$comment_write_line" in
*'<decision-comment>'*)
    fail "the WRITE line must never log the old placeholder body-file path: $comment_write_line"
    ;;
esac
grep -q -- '--body-file' <<<"$comment_write_line" ||
    fail "the WRITE line must still name the --body-file flag"
sha_suffix="${comment_write_line##*# body-sha256=}"
[ "$sha_suffix" != "$comment_write_line" ] ||
    fail "the WRITE line must append a '# body-sha256=<hex>' suffix: $comment_write_line"
expected_sha="$({
    printf 'Decision (maintainer, %s)\n\n' "2026-01-02"
    cat "$decision_file"
} | test_sha256)"
[ "$sha_suffix" = "$expected_sha" ] ||
    fail "the logged body-sha256 must match the posted comment body: got '$sha_suffix', expected '$expected_sha'"

echo "==> groom-decide: a rerun appends to the log instead of truncating it"
rerun_decide_log="$tmp/rerun-decide.log"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 GROOM_NOW_DATE=2026-01-02 "$decide" --repo "$repo" --issue 12 \
    --decision-file "$decision_file" --supersedes 40 --blocked-by 7 \
    --log "$rerun_decide_log" --execute)" = 0 ] ||
    fail "first execute run should succeed: $(cat "$tmp/out" "$tmp/err")"
first_decide_lines="$(wc -l <"$rerun_decide_log")"
[ "$(run env GROOM_EXECUTE=1 GROOM_NOW_DATE=2026-01-02 "$decide" --repo "$repo" --issue 12 \
    --decision-file "$decision_file" --supersedes 40 --blocked-by 7 \
    --log "$rerun_decide_log" --execute)" = 0 ] ||
    fail "second execute run should succeed: $(cat "$tmp/out" "$tmp/err")"
second_decide_lines="$(wc -l <"$rerun_decide_log")"
[ "$second_decide_lines" -gt "$first_decide_lines" ] || fail "a rerun must APPEND to the log, not truncate it"
[ "$(grep -c '^# run ' "$rerun_decide_log")" = 2 ] || fail "each execute run must add its own header line"

echo "==> groom-decide: --outcomes records DECIDED for the issue, DONE for each closed sibling, and DECIDED (not DONE) for each blocked-by edge (finding 8, Codex 4011648572, Codex 4012242590)"
decide_outcomes="$tmp/decide-outcomes.jsonl"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 GROOM_NOW_DATE=2026-01-02 "$decide" --repo "$repo" --issue 12 \
    --decision-file "$decision_file" --supersedes 40 --blocked-by 7 \
    --outcomes "$decide_outcomes" --log "$tmp/decide-outcomes.log" --execute)" = 0 ] ||
    fail "gated decide with --outcomes should succeed: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -s '[.[] | select(.issue == 12 and .op == "decision" and .status == "DECIDED 2026-01-02")] | length' \
    "$decide_outcomes")" -ge 1 ] || fail "decision outcome must be recorded"
[ "$(jq -s '[.[] | select(.issue == 40 and .op == "close" and .status == "DONE")] | length' \
    "$decide_outcomes")" -ge 1 ] || fail "superseded-sibling close outcome must be recorded"
# Recorded as DECIDED, not DONE (Codex review on PR #1032, comment
# 4012242590): groom-report.sh's outcomes merge keeps only the LAST record
# per issue number, and this edge is recorded against the SAME decided-issue
# number (#12) as the decision outcome above — a trailing DONE record would
# silently overwrite the dated DECIDED status the report shows for #12.
[ "$(jq -s '[.[] | select(.issue == 12 and .op == "blocked-by" and .status == "DECIDED 2026-01-02")] | length' \
    "$decide_outcomes")" -ge 1 ] || fail "blocked-by outcome must be recorded as DECIDED, not DONE"
[ "$(jq -s '[.[] | select(.issue == 12 and .op == "blocked-by" and .status == "DONE")] | length' \
    "$decide_outcomes")" = 0 ] || fail "blocked-by outcome must never be recorded as DONE"

echo "==> groom-decide: an unwritable --outcomes sink is refused before any write (finding 8)"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 "$decide" --repo "$repo" --issue 12 \
    --decision-file "$decision_file" --supersedes 40 \
    --outcomes "$tmp/does-not-exist-2/outcomes.jsonl" --log "$tmp/decide-outcomes-refuse.log" \
    --execute)" = 2 ] ||
    fail "an unwritable --outcomes path must exit 2: $(cat "$tmp/out" "$tmp/err")"
grep -qE "^issue (close|comment) " "$GH_STUB_LOG" && fail "a refused --outcomes sink must prevent every write"

echo "==> groom-decide: dry-run never writes to --outcomes"
dry_decide_outcomes="$tmp/dry-decide-outcomes.jsonl"
[ "$(run "$decide" --repo "$repo" --issue 12 --decision-file "$decision_file" \
    --supersedes 40 --outcomes "$dry_decide_outcomes")" = 0 ] ||
    fail "dry-run decide with --outcomes should succeed"
[ ! -s "$dry_decide_outcomes" ] || fail "dry-run must never write to --outcomes"

# ── wrapper ──────────────────────────────────────────────────────────────────
export GH_STUB_REPO="$repo"
# Keep every run's persistent output directory under $tmp (cleaned up by this
# script's own EXIT trap) instead of the real $HOME (issue #1015 finding 1:
# the wrapper's scratch dir is no longer deleted on exit, so tests must not
# let it default to the real user's state directory).
export GROOM_OUT_DIR="$tmp/groom-out"

echo "==> wrapper: audit mode forces GROOM_EXECUTE=0"
: >"$GH_STUB_LOG"
[ "$(run "$wrapper")" = 0 ] || fail "wrapper audit run failed: $(cat "$tmp/out" "$tmp/err")"
grep -q "GROOM_EXECUTE=0" "$GH_STUB_LOG" || fail "env gate not forced to 0"
grep -q "GROOM_REPO=$repo" "$GH_STUB_LOG" || fail "run must be repo-bound"
grep -q "AUDIT" "$GH_STUB_LOG" || fail "prompt must state AUDIT"
grep -q -- "--model sonnet" "$GH_STUB_LOG" || fail "default model must be sonnet"
grep -qF 'Step 2 fan-out: dispatch every cluster subagent with model: "opus"' "$GH_STUB_LOG" ||
    fail "default fan-out model must be opus (issue #1044) — fan-out verification defaults to frontier, independent of the standard-tier coordinator"
grep -q '^GROOM_SCRATCH=/' "$GH_STUB_LOG" || fail "run must bind a scratch dir"
grep -q "GROOM_SCRATCH=$GROOM_OUT_DIR/" "$GH_STUB_LOG" ||
    fail "the scratch dir must be created under GROOM_OUT_DIR"
scratch_val="$(grep -m1 '^GROOM_SCRATCH=' "$GH_STUB_LOG" | cut -d= -f2-)"
expected_grant="Edit(//${scratch_val#/}/**)"
# Anchored on the leading comma the wrapper always emits before the grant
# (tools="$tools,Edit(...)"), so a MultiEdit(...)/NotebookEdit(...) grant —
# which has no comma directly before "Edit(" — cannot satisfy this on its
# own; no separate denylist needed (challenge round 2 finding).
grep -qF -- ",$expected_grant" "$GH_STUB_LOG" ||
    fail "worker Edit grant must be exactly run-dir-scoped"
grep -q -- "Write(//" "$GH_STUB_LOG" &&
    fail "worker must not be granted a Write(path) rule (Claude Code does not honor it)"
grep -q -- "--tools Read,Write,Bash,Agent,Task,Glob,Grep" "$GH_STUB_LOG" ||
    fail "worker must run with the audit-mode built-in tool set (Write included, per the comment above the grant)"
for grant in "groom-scan.sh" "groom-verdicts.sh" "groom-report.sh" "Agent,Task,Glob,Grep"; do
    grep -qF "$grant" "$GH_STUB_LOG" ||
        fail "audit mode's tool grant must be unchanged — missing '$grant'"
done
grep -qF "groom-apply.sh" "$GH_STUB_LOG" &&
    fail "audit mode's tool grant must not include groom-apply.sh (finding 7 — a fan-out session never applies)"
grep -qF "groom-decide.sh" "$GH_STUB_LOG" &&
    fail "audit mode's tool grant must not include groom-decide.sh (finding 7 — a fan-out session never decides)"

echo "==> wrapper: GROOM_FANOUT_MODEL overrides the fan-out tier independently of GROOM_MODEL (issue #1044)"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_MODEL=opus GROOM_FANOUT_MODEL=haiku "$wrapper")" = 0 ] ||
    fail "wrapper audit run with a fan-out override failed: $(cat "$tmp/out" "$tmp/err")"
grep -q -- "--model opus" "$GH_STUB_LOG" ||
    fail "GROOM_MODEL must still control the coordinating session's own model"
grep -qF 'Step 2 fan-out: dispatch every cluster subagent with model: "haiku"' "$GH_STUB_LOG" ||
    fail "GROOM_FANOUT_MODEL must control the fan-out instruction independently of GROOM_MODEL"

echo "==> SKILL.md: Step 2 documents the interactive-path fan-out tier contract directly (issue #1044) — the wrapper-prompt tests above cover only the headless path, and the interactive /groom path relies entirely on this prose"
skill_md="ai/skills/universal/groom/SKILL.md"
[ -f "$skill_md" ] || fail "$skill_md must exist"
grep -q "frontier.*tier" "$skill_md" || fail "SKILL.md Step 2 must name the frontier tier for fan-out dispatch"
grep -qF "agent-registry.json" "$skill_md" ||
    fail "SKILL.md Step 2 must point at agent-registry.json for cross-harness tier lookup, not hardcode one harness"
grep -qF "opus" "$skill_md" || fail "SKILL.md Step 2 must give the Claude Code example (opus)"
grep -q "rather than leaving it unset" "$skill_md" ||
    fail "SKILL.md Step 2 must explicitly say not to leave the fan-out model unset"
grep -qF "no separate \`frontier\` tier" "$skill_md" ||
    fail "SKILL.md Step 2 must cover families with no separate frontier tier (Codex review on PR #1045, comment about claude-code-deepseek/-glm/-kimi/-minimax)"
grep -qF "claude-code-qwen-local" "$skill_md" ||
    fail "SKILL.md Step 2 must cover a harness rewired to one fixed model regardless of requested tier (Codex review on PR #1045, comment about claude-code-qwen-local)"
grep -qF "model_resolution.details" "$skill_md" ||
    fail "SKILL.md Step 2 must say to read the harness's own model_resolution, not just its family's tier table"
grep -qF "harness-runtime" "$skill_md" ||
    fail "SKILL.md Step 2 must name harness-runtime-owned harnesses (Codex review round 4 on PR #1045 — Antigravity/OpenCode/Pi have no per-dispatch override at all)"
grep -qF "there is no override to make" "$skill_md" ||
    fail "SKILL.md Step 2 must honestly state that harness-runtime-owned harnesses have no per-dispatch override, rather than claiming a worked example (e.g. Antigravity) it cannot verify"
grep -qF "test-registry-drift.sh" "$skill_md" ||
    fail "SKILL.md Step 2 must cite the test enforcing that opus/fable always remap to a provider wrapper's strongest model (Codex review round 5 on PR #1045)"
grep -q "Do not pass a family's raw registry model slug" "$skill_md" ||
    fail "SKILL.md Step 2 must warn against passing a raw registry model slug (e.g. deepseek-flash) as the Agent tool's model argument — it only accepts Claude Code's own aliases (Codex review round 5 on PR #1045)"

echo "==> canary: opus is still agent-registry.json's frontier-tier model for the claude family (Codex review on PR #1045) — this must fail loudly if the registry ever retiers or renames it, since scripts/groom.sh's GROOM_FANOUT_MODEL default and SKILL.md Step 2's own example both hardcode the literal 'opus'"
[ -f agent-registry.json ] || fail "agent-registry.json must exist"
registry_claude_frontier="$(jq -r '.families[] | select(.slug == "claude") | .models[] | select(.tier == "frontier") | .slug' agent-registry.json)"
[ "$registry_claude_frontier" = "opus" ] ||
    fail "agent-registry.json's claude/frontier model is '$registry_claude_frontier', not 'opus' — update scripts/groom.sh's GROOM_FANOUT_MODEL default and SKILL.md Step 2's example to match"

echo "==> canary: claude-code-qwen-local is still fixed to one model regardless of requested tier (Codex review on PR #1045) — this must fail loudly if the registry ever changes so SKILL.md's own worked example goes stale"
qwen_local_resolution="$(jq -r '.harnesses[] | select(.slug == "claude-code-qwen-local") | .model_resolution.details' agent-registry.json)"
case "$qwen_local_resolution" in
*"serving qwen3-coder:30b"*) : ;;
*) fail "claude-code-qwen-local's model_resolution.details no longer describes a fixed local model ('$qwen_local_resolution') — update SKILL.md Step 2's worked example to match" ;;
esac

echo "==> canary: antigravity, opencode, and pi are still harness-runtime-owned with no per-dispatch override (Codex review round 4 on PR #1045) — this must fail loudly if the registry ever gives one of them a per-dispatch model parameter, so SKILL.md's honesty statement doesn't go stale"
for harness in antigravity opencode pi; do
    owner="$(jq -r --arg h "$harness" '.harnesses[] | select(.slug == $h) | .model_resolution.owner' agent-registry.json)"
    [ "$owner" = "harness-runtime" ] ||
        fail "agent-registry.json's $harness harness now resolves its model via '$owner', not 'harness-runtime' — SKILL.md Step 2 may be able to name a real per-dispatch override for it now instead of the honest fallback"
done

echo "==> wrapper: the run's report survives the wrapper process (finding 1 — no more rm -rf EXIT trap)"
audit_scratch="$(grep -o 'GROOM_SCRATCH=/[^[:space:]]*' "$GH_STUB_LOG" | tail -1 | cut -d= -f2)"
[ -n "$audit_scratch" ] || fail "could not recover the run's scratch dir from the stub log"
[ -f "$audit_scratch/report.html" ] || fail "report.html must still exist after the wrapper returns"
[ -f "$audit_scratch/report.md" ] || fail "report.md must still exist after the wrapper returns"

echo "==> wrapper: the run's output directory is created 0700 (findings 6, 9)"
audit_scratch_mode="$(stat -c '%a' "$audit_scratch" 2>/dev/null || stat -f '%Lp' "$audit_scratch")"
[ "$audit_scratch_mode" = "700" ] || fail "run directory must be mode 700 (got $audit_scratch_mode)"

echo "==> wrapper: a pre-existing GROOM_OUT_DIR root's mode is untouched, only the groom-owned child is secured (Codex 4012242612)"
shared_out_dir="$tmp/shared-out"
mkdir -p "$shared_out_dir"
chmod 1777 "$shared_out_dir"
before_mode="$(stat -c '%a' "$shared_out_dir" 2>/dev/null || stat -f '%Lp' "$shared_out_dir")"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_OUT_DIR="$shared_out_dir" "$wrapper")" = 0 ] ||
    fail "wrapper audit run with a shared GROOM_OUT_DIR failed: $(cat "$tmp/out" "$tmp/err")"
after_mode="$(stat -c '%a' "$shared_out_dir" 2>/dev/null || stat -f '%Lp' "$shared_out_dir")"
[ "$after_mode" = "$before_mode" ] ||
    fail "a pre-existing GROOM_OUT_DIR root must never have its own mode changed (was $before_mode, now $after_mode)"
[ -d "$shared_out_dir/harmon-groom" ] || fail "a groom-owned child directory must be created under the root"
child_mode="$(stat -c '%a' "$shared_out_dir/harmon-groom" 2>/dev/null || stat -f '%Lp' "$shared_out_dir/harmon-groom")"
[ "$child_mode" = "700" ] || fail "the groom-owned child directory must be secured to 700 (got $child_mode)"

echo "==> wrapper: a symlinked pre-existing harmon-groom child is refused, and the symlink target's mode is untouched (Codex 4012885475)"
symlink_out_dir="$tmp/symlink-out"
mkdir -p "$symlink_out_dir"
attack_target="$tmp/attack-target"
mkdir -p "$attack_target"
chmod 755 "$attack_target"
ln -s "$attack_target" "$symlink_out_dir/harmon-groom"
target_before_mode="$(stat -c '%a' "$attack_target" 2>/dev/null || stat -f '%Lp' "$attack_target")"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_OUT_DIR="$symlink_out_dir" "$wrapper")" = 2 ] ||
    fail "a symlinked harmon-groom child must be refused: $(cat "$tmp/out" "$tmp/err")"
grep -qi "symlink" "$tmp/err" || fail "the refusal must say it is a symlink: $(cat "$tmp/err")"
target_after_mode="$(stat -c '%a' "$attack_target" 2>/dev/null || stat -f '%Lp' "$attack_target")"
[ "$target_after_mode" = "$target_before_mode" ] ||
    fail "the symlink target's mode must be untouched (was $target_before_mode, now $target_after_mode)"

echo "==> wrapper: a GROOM_OUT_DIR root that exists but is not a directory is refused"
not_a_dir="$tmp/not-a-dir"
: >"$not_a_dir"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_OUT_DIR="$not_a_dir" "$wrapper")" = 2 ] ||
    fail "a non-directory GROOM_OUT_DIR root must be refused"
grep -qi "not a directory" "$tmp/err" || fail "the refusal must explain why: $(cat "$tmp/err")"

echo "==> wrapper: --execute needs a script name (challenge round 3: no --run/--plan/--decisions orchestration left)"
: >"$GH_STUB_LOG"
[ "$(run "$wrapper" --execute)" = 2 ] || fail "--execute with no script name must exit 2"
for allowed in groom-apply.sh groom-decide.sh groom-report.sh; do
    grep -qF "$allowed" "$tmp/err" ||
        fail "the missing-script refusal must name '$allowed' as allowed: $(cat "$tmp/err")"
done

echo "==> wrapper: --execute refuses any script name outside the allowed set"
[ "$(run "$wrapper" --execute bogus.sh --repo "$repo")" = 2 ] ||
    fail "an unknown script name must exit 2"
grep -qF "bogus.sh" "$tmp/err" || fail "the refusal must name the rejected script: $(cat "$tmp/err")"
for allowed in groom-apply.sh groom-decide.sh groom-report.sh; do
    grep -qF "$allowed" "$tmp/err" ||
        fail "the unknown-script refusal must name '$allowed' as allowed: $(cat "$tmp/err")"
done

echo "==> wrapper: --execute groom-apply.sh / groom-decide.sh still requires an interactive terminal (write gate unchanged)"
for gated in groom-apply.sh groom-decide.sh; do
    [ "$(run "$wrapper" --execute "$gated" --repo "$repo")" = 2 ] ||
        fail "non-interactive --execute $gated must exit 2 even with a valid script name"
    grep -qi "interactive terminal" "$tmp/err" ||
        fail "refusal for $gated must name the interactive-terminal requirement: $(cat "$tmp/err")"
done

echo "==> wrapper: a confirmed --execute execs the named script verbatim, with GROOM_EXECUTE=1 and GROOM_REPO set, and nothing else in between"
# Point skill_dir at a fixture rather than the real ai/skills/universal/
# groom/assets/*.sh: the wrapper no longer validates or interprets anything
# about its target beyond the name, so a fixture that just records its own
# basename/argv/env is enough to prove the exec contract without touching
# the real write-path scripts. Built unconditionally — groom-report.sh's own
# direct-exec path (below) needs no pty; only the confirmed
# apply.sh/decide.sh path does.
fake_root="$tmp/fake-repo"
mkdir -p "$fake_root/scripts" "$fake_root/ai/skills/universal/groom/assets"
cp "$wrapper" "$fake_root/scripts/groom.sh"
chmod +x "$fake_root/scripts/groom.sh"
: >"$fake_root/ai/skills/universal/groom/SKILL.md"
git -C "$fake_root" init -q
git -C "$fake_root" remote add origin https://github.com/testowner/testrepo.git

for stub_script in groom-apply.sh groom-decide.sh groom-report.sh; do
    cat >"$fake_root/ai/skills/universal/groom/assets/$stub_script" <<'STUB'
#!/usr/bin/env bash
{
    printf 'SCRIPT=%s\n' "$(basename "$0")"
    printf 'GROOM_EXECUTE=%s\n' "${GROOM_EXECUTE:-unset}"
    printf 'GROOM_REPO=%s\n' "${GROOM_REPO:-unset}"
    printf 'ARGV:'
    printf ' %s' "$@"
    printf '\n'
} >>"${EXEC_LOG:?}"
STUB
    chmod +x "$fake_root/ai/skills/universal/groom/assets/$stub_script"
done

echo "==> wrapper: --execute groom-report.sh execs directly — no tty, no confirmation prompt, no GROOM_EXECUTE (challenge round 2 confirming round, finding 4)"
report_exec_log="$tmp/report-exec.log"
: >"$report_exec_log"
report_rc=0
env PATH="$tmp/bin:$PATH" EXEC_LOG="$report_exec_log" "$fake_root/scripts/groom.sh" \
    --execute groom-report.sh --marker report-arg \
    --outcomes /tmp/does-not-need-to-exist.jsonl \
    </dev/null >"$tmp/report-wrap-out" 2>"$tmp/report-wrap-err" || report_rc=$?
[ "$report_rc" = 0 ] ||
    fail "non-interactive --execute groom-report.sh must succeed without a tty: $(cat "$tmp/report-wrap-out" "$tmp/report-wrap-err")"
grep -q "SCRIPT=groom-report.sh" "$report_exec_log" ||
    fail "--execute groom-report.sh must exec the report script: $(cat "$report_exec_log")"
grep -q "GROOM_EXECUTE=unset" "$report_exec_log" ||
    fail "groom-report.sh must never see GROOM_EXECUTE exported by the wrapper: $(cat "$report_exec_log")"
grep -q "GROOM_REPO=unset" "$report_exec_log" ||
    fail "groom-report.sh must never see GROOM_REPO — it runs before repo" \
        "resolution (Codex 4012242636): $(cat "$report_exec_log")"
grep -q "ARGV: --marker report-arg --outcomes /tmp/does-not-need-to-exist.jsonl" "$report_exec_log" ||
    fail "groom-report.sh must receive the operator's arguments verbatim: $(cat "$report_exec_log")"
grep -qi 'type "yes"' "$tmp/report-wrap-out" "$tmp/report-wrap-err" &&
    fail "groom-report.sh must never be gated behind the confirmation prompt"

echo "==> wrapper: --execute groom-report.sh works even when 'gh repo view' would fail (Codex 4012242636)"
report_offline_log="$tmp/report-offline.log"
: >"$report_offline_log"
offline_rc=0
env -u GH_STUB_REPO PATH="$tmp/bin:$PATH" EXEC_LOG="$report_offline_log" \
    "$fake_root/scripts/groom.sh" --execute groom-report.sh --marker offline-arg \
    </dev/null >"$tmp/report-offline-out" 2>"$tmp/report-offline-err" || offline_rc=$?
[ "$offline_rc" = 0 ] ||
    fail "groom-report.sh must run even though 'gh repo view' would fail:" \
        "$(cat "$tmp/report-offline-out" "$tmp/report-offline-err")"
grep -q "SCRIPT=groom-report.sh" "$report_offline_log" ||
    fail "the report script must still run when the repo cannot be resolved: $(cat "$report_offline_log")"

echo "==> wrapper: a confirmed --execute execs groom-apply.sh/groom-decide.sh verbatim, with GROOM_EXECUTE=1 and GROOM_REPO set (write gate unchanged)"
if [ "$PTY_OK" = true ]; then
    exec_log="$tmp/exec.log"
    for script_name in groom-apply.sh groom-decide.sh; do
        : >"$exec_log"
        {
            printf 'yes\n' | pty_exec env PATH="$tmp/bin:$PATH" EXEC_LOG="$exec_log" \
                "$fake_root/scripts/groom.sh" --execute "$script_name" \
                --marker "$script_name-arg" --outcomes "/tmp/does-not-need-to-exist.jsonl"
        } >"$tmp/pty-out" 2>&1 || true
        grep -q "SCRIPT=$script_name" "$exec_log" ||
            fail "confirmed apply mode must exec $script_name verbatim: $(cat "$tmp/pty-out" "$exec_log")"
        grep -q "GROOM_EXECUTE=1" "$exec_log" ||
            fail "$script_name must see GROOM_EXECUTE=1: $(cat "$exec_log")"
        grep -q "GROOM_REPO=$repo" "$exec_log" ||
            fail "$script_name must see GROOM_REPO=$repo: $(cat "$exec_log")"
        grep -q "ARGV: --marker $script_name-arg --outcomes /tmp/does-not-need-to-exist.jsonl" "$exec_log" ||
            fail "$script_name must receive the operator's arguments verbatim: $(cat "$exec_log")"
    done
else
    echo "   (skipped: no pty allocator available in this environment)"
fi

echo "All groom skill tests passed."
