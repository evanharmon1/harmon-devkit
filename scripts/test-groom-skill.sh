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
    if [ -f "${GH_STUB_DIR:?}/issue-$n.json" ]; then
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
cat >"$stub_dir/milestones.json" <<'JSON'
[{"number":1,"title":"v1","state":"open","description":"","open_issues":1,"closed_issues":0}]
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
{"labels":[{"name":"needs-triage"}],"author":{"login":"someone","type":"User","is_bot":false}}
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

# ── wrapper ──────────────────────────────────────────────────────────────────
export GH_STUB_REPO="$repo"

echo "==> wrapper: audit mode forces GROOM_EXECUTE=0"
: >"$GH_STUB_LOG"
[ "$(run "$wrapper")" = 0 ] || fail "wrapper audit run failed: $(cat "$tmp/out" "$tmp/err")"
grep -q "GROOM_EXECUTE=0" "$GH_STUB_LOG" || fail "env gate not forced to 0"
grep -q "GROOM_REPO=$repo" "$GH_STUB_LOG" || fail "run must be repo-bound"
grep -q "AUDIT" "$GH_STUB_LOG" || fail "prompt must state AUDIT"
grep -q -- "--model sonnet" "$GH_STUB_LOG" || fail "default model must be sonnet"
grep -q "GROOM_SCRATCH=/" "$GH_STUB_LOG" || fail "run must bind a scratch dir"

echo "==> wrapper: --execute without a terminal is refused"
[ "$(run "$wrapper" --execute)" = 2 ] || fail "non-interactive --execute must exit 2"

echo "All groom skill tests passed."
