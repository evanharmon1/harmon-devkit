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
api\ repos/*/milestones) cat "${GH_STUB_DIR:?}/milestones.json" ;;
api\ repos/*/issues/*/dependencies/blocked_by) ;;
api\ repos/*/issues/*/sub_issues) ;;
api\ repos/*/issues/*)
    n="${2##*/}"
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
{"number":5,"verdict":"CLOSE-wrong-repo (target)","priority":"low","reason":"belongs elsewhere","evidence":"targets other-repo","group":"misc"}
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

echo "==> validate: an invalid priority is refused"
bad_priority="$tmp/bad-priority.jsonl"
printf '%s\n' '{"number":12,"verdict":"KEEP","priority":"urgent","reason":"x","evidence":"","group":"ci"}' >"$bad_priority"
[ "$(run "$verdicts" validate "$bad_priority")" = 1 ] || fail "bad priority must exit 1"

echo "==> validate: CLOSE-wrong-repo accepts a real target, not just the literal word 'target'"
wrong_repo="$tmp/wrong-repo.jsonl"
printf '%s\n' '{"number":13,"verdict":"CLOSE-wrong-repo (harmonops/harmon-infra)","priority":"low","reason":"belongs there","evidence":"describes infra config","group":"misc"}' >"$wrong_repo"
[ "$(run "$verdicts" validate "$wrong_repo")" = 0 ] ||
    fail "a real target description must validate: $(cat "$tmp/out" "$tmp/err")"

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

# ── groom-report.sh ─────────────────────────────────────────────────────────
echo "==> report: renders every required section, in order, with number+title"
out_html="$tmp/report.html"
out_md="$tmp/report.md"
GROOM_NOW="2026-01-01 00:00 UTC" run "$report" render --dispositions "$disp" \
    --out-html "$out_html" --out-md "$out_md" >/dev/null
for section in "## Stats" "## What to do next" "## Close now" "## Milestones" \
    "## Parent issues" "## Decisions" "## Process findings" "## Every issue"; do
    grep -qF "$section" "$out_md" || fail "missing section: $section"
done
order="$(grep -n '^## ' "$out_md" | cut -d: -f2)"
expected="## Stats
## What to do next
## Close now
## Milestones
## Parent issues
## Decisions
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
# One JSON object per line, NOT wrapped in an array: gh api --paginate
# unwraps an array-shaped response into a stream of individual elements
# (this fixture simulates that stream, not the raw endpoint response).
cat >"$stub_dir/milestones.json" <<'JSON'
{"number":1,"title":"v1","state":"open","description":"","open_issues":1,"closed_issues":0}
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
[ "$(jq -r '.milestones | length' "$scan_out")" = 1 ] || fail "scan must carry milestones"
[ "$(jq -r '.board_access' "$scan_out")" != "null" ] || fail "scan must note board access"

echo "==> scan: refuses (exit 4, naming --limit) when the result hits --limit exactly"
: >"$GH_STUB_LOG"
[ "$(run "./ai/skills/universal/groom/assets/groom-scan.sh" --repo "$repo" \
    --limit 2 --out "$tmp/scan-truncated.json")" = 4 ] ||
    fail "a scan returning exactly --limit issues must exit 4"
grep -q -- "--limit" "$tmp/err" || fail "refusal must name --limit"
[ ! -f "$tmp/scan-truncated.json" ] || fail "a refused scan must not write --out"

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
    --decision-file "$decision_file" --supersedes 41 --execute)" = 4 ] ||
    fail "bot-owned supersedes must exit 4 (execute)"
grep -qE "^issue close 41 " "$GH_STUB_LOG" && fail "a bot-owned sibling must never be closed"
grep -qE "^issue comment 12 " "$GH_STUB_LOG" &&
    fail "preflight (finding 7) must refuse a bot-owned supersedes BEFORE posting the decision comment"

echo "==> groom-decide: a --blocked-by target's id is resolved before the decision comment posts (finding 7)"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 "$decide" --repo "$repo" --issue 12 \
    --decision-file "$decision_file" --supersedes 41 --blocked-by 7 --execute)" = 4 ] ||
    fail "a bot-owned supersedes must still refuse before any blocked-by/comment work"
grep -qE "^issue comment 12 " "$GH_STUB_LOG" && fail "no comment must post when preflight refuses"
grep -qE "^api repos/$repo/issues/12/dependencies/blocked_by" "$GH_STUB_LOG" &&
    fail "no blocked-by edge must be added when preflight refuses"

echo "==> groom-decide: --execute without the env gate is refused"
[ "$(run "$decide" --repo "$repo" --issue 12 --decision-file "$decision_file" --execute)" = 2 ] ||
    fail "--execute without GROOM_EXECUTE=1 must exit 2"

echo "==> groom-decide: --execute posts the comment, closes the sibling, adds the edge"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 GROOM_NOW_DATE=2026-01-02 "$decide" --repo "$repo" --issue 12 \
    --decision-file "$decision_file" --supersedes 40 --blocked-by 7 --execute)" = 0 ] ||
    fail "gated decide should succeed: $(cat "$tmp/out" "$tmp/err")"
grep -q "^issue comment 12 " "$GH_STUB_LOG" || fail "decide must post the decision comment"
grep -q "^issue close 40 .*not planned" "$GH_STUB_LOG" || fail "decide must close the superseded sibling"
grep -q "^api repos/$repo/issues/12/dependencies/blocked_by" "$GH_STUB_LOG" ||
    fail "decide must add the blocked-by edge"

echo "==> groom-decide: --outcomes records DECIDED for the issue and DONE for each closed sibling (finding 8)"
decide_outcomes="$tmp/decide-outcomes.jsonl"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 GROOM_NOW_DATE=2026-01-02 "$decide" --repo "$repo" --issue 12 \
    --decision-file "$decision_file" --supersedes 40 --blocked-by 7 \
    --outcomes "$decide_outcomes" --execute)" = 0 ] ||
    fail "gated decide with --outcomes should succeed: $(cat "$tmp/out" "$tmp/err")"
[ "$(jq -s '[.[] | select(.issue == 12 and .op == "decision" and .status == "DECIDED 2026-01-02")] | length' \
    "$decide_outcomes")" -ge 1 ] || fail "decision outcome must be recorded"
[ "$(jq -s '[.[] | select(.issue == 40 and .op == "close" and .status == "DONE")] | length' \
    "$decide_outcomes")" -ge 1 ] || fail "superseded-sibling close outcome must be recorded"

echo "==> groom-decide: an unwritable --outcomes sink is refused before any write (finding 8)"
: >"$GH_STUB_LOG"
[ "$(run env GROOM_EXECUTE=1 "$decide" --repo "$repo" --issue 12 \
    --decision-file "$decision_file" --supersedes 40 \
    --outcomes "$tmp/does-not-exist-2/outcomes.jsonl" --execute)" = 2 ] ||
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
grep -q "GROOM_SCRATCH=/" "$GH_STUB_LOG" || fail "run must bind a scratch dir"
grep -q "GROOM_SCRATCH=$GROOM_OUT_DIR/" "$GH_STUB_LOG" ||
    fail "the scratch dir must be created under GROOM_OUT_DIR"
for grant in "groom-scan.sh" "groom-verdicts.sh" "groom-report.sh" "Agent,Task,Glob,Grep"; do
    grep -qF "$grant" "$GH_STUB_LOG" ||
        fail "audit mode's tool grant must be unchanged — missing '$grant'"
done
grep -qF "groom-apply.sh" "$GH_STUB_LOG" &&
    fail "audit mode's tool grant must not include groom-apply.sh (finding 7 — a fan-out session never applies)"
grep -qF "groom-decide.sh" "$GH_STUB_LOG" &&
    fail "audit mode's tool grant must not include groom-decide.sh (finding 7 — a fan-out session never decides)"

echo "==> wrapper: the run's report survives the wrapper process (finding 1 — no more rm -rf EXIT trap)"
audit_scratch="$(grep -o 'GROOM_SCRATCH=/[^[:space:]]*' "$GH_STUB_LOG" | tail -1 | cut -d= -f2)"
[ -n "$audit_scratch" ] || fail "could not recover the run's scratch dir from the stub log"
[ -f "$audit_scratch/report.html" ] || fail "report.html must still exist after the wrapper returns"
[ -f "$audit_scratch/report.md" ] || fail "report.md must still exist after the wrapper returns"

echo "==> wrapper: the run's output directory is created 0700 (findings 6, 9)"
audit_scratch_mode="$(stat -c '%a' "$audit_scratch" 2>/dev/null || stat -f '%Lp' "$audit_scratch")"
[ "$audit_scratch_mode" = "700" ] || fail "run directory must be mode 700 (got $audit_scratch_mode)"

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
grep -q "GROOM_REPO=$repo" "$report_exec_log" ||
    fail "groom-report.sh must still see GROOM_REPO=$repo: $(cat "$report_exec_log")"
grep -q "ARGV: --marker report-arg --outcomes /tmp/does-not-need-to-exist.jsonl" "$report_exec_log" ||
    fail "groom-report.sh must receive the operator's arguments verbatim: $(cat "$report_exec_log")"
grep -qi 'type "yes"' "$tmp/report-wrap-out" "$tmp/report-wrap-err" &&
    fail "groom-report.sh must never be gated behind the confirmation prompt"

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
