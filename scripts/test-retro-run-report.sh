#!/usr/bin/env bash
# test-retro-run-report.sh — behavioural tests for the /retro skill's
# run-evidence projection (ai/skills/universal/retro/assets/retro-run-report.mjs,
# issue #664).
#
# Fully hermetic and offline. Two stubs stand in for the world:
#   * `gh` — a PATH shim answering `pr view`, the paginated issue/PR comments
#     endpoint, and `api user` from canned JSON, logging every argv it was
#     called with so a test can assert what the asset asked for as well as
#     what it did with the answer.
#   * the harvester — a stub standing in for scripts/dev-flow-stats.mjs (#663)
#     so the unit cases stay hermetic and can drive its 0/1/3 exits at will.
#     Section 5 runs the REAL script, now that #751 has merged, so neither the
#     stub's fidelity nor the resolution path is taken on trust.
#     The stub's trajectory takes its RUN-RECORD
#     half verbatim from ai/schemas/fixtures/run.schema/valid/*.json, so the
#     fixture corpus stays the single description of a run's shape; the
#     HARVEST half (rounds[], findings_by_class_and_provenance, orphan/forged
#     comments) is literal here because those fields are computed from posted
#     evidence payloads, not from the run record.
#
# The PR number is 634 throughout because that is the PR
# run.schema/valid/further-along.json's own record names — the asset refuses a
# trajectory bound to a different PR, so letting the fixture supply both sides
# keeps that check honest rather than papering over it.
#
# Two cases at the end are seam guards for contracts this asset consumes but
# does not own: the real harvester's CLI flags (skipped while #663 is
# unmerged) and the renderer's own golden policy-disclosure grammar.
# Run via `task test:retro-run-report`.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

REPORT="$PWD/ai/skills/universal/retro/assets/retro-run-report.mjs"
FIXTURES="$PWD/ai/schemas/fixtures/run.schema/valid"
REAL_STATS="$PWD/scripts/dev-flow-stats.mjs"
PR=634
ISSUE=664
# The default trusted actor: the gh stub reports it as the authenticated user
# and set_comments authors comments as it, so the ordinary case is a trusted
# marker. A test that wants an untrusted one overrides COMMENT_ACTOR.
ACTOR=37220977

pass=0
fail=0
skip=0
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*"
}
bad() {
    fail=$((fail + 1))
    echo "  ✗ $*" >&2
}
skipped() {
    skip=$((skip + 1))
    echo "  ↷ $*"
}

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
# Stubs and fixture plumbing
# ---------------------------------------------------------------------------

# write_file PATH CONTENT — every multi-word body below travels through a file
# rather than an argv word list, so a marker's own spaces cannot be resplit.
write_file() {
    printf '%s' "$2" >"$1"
}

# marker_file PATH KIND RUN_ID STAGE DEST ROUND — one evidence comment in the
# grammar ai/schemas/README.md "Evidence marker and digest grammar" fixes:
# the marker line first, then the fenced payload.
marker_file() {
    printf '<!-- devflow:%s v2 run_id=%s stage=%s dest=%s round=%s seq=1 -->\n```json\n{}\n```\n' \
        "$2" "$3" "$4" "$5" "$6" >"$1"
}

# make_gh DIR — a `gh` shim in DIR/bin, reading canned answers from
# $GH_PR_JSON / $GH_COMMENTS_DIR and its actor id from $GH_USER_ID, appending
# each invocation to $GH_LOG.
make_gh() {
    mkdir -p "$1/bin"
    cat >"$1/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "${1:-}" in
pr)
    cat "$GH_PR_JSON"
    ;;
api)
    case "$*" in
    */issues/*/comments*)
        n="$(printf '%s\n' "$*" | sed -n 's|.*/issues/\([0-9]*\)/comments.*|\1|p')"
        file="${GH_COMMENTS_DIR:-/nonexistent}/$n.json"
        if [ -f "$file" ]; then cat "$file"; else echo '[[]]'; fi
        ;;
    *user*)
        if [ -z "${GH_USER_ID:-}" ]; then
            echo "gh stub: no GH_USER_ID configured" >&2
            exit 1
        fi
        printf '%s\n' "$GH_USER_ID"
        ;;
    *)
        echo "gh stub: unexpected api call $*" >&2
        exit 1
        ;;
    esac
    ;;
*)
    echo "gh stub: unexpected command $*" >&2
    exit 1
    ;;
esac
GH_STUB
    chmod +x "$1/bin/gh"
}

# make_stats PATH EXIT_CODE [PAYLOAD_FILE] — a harvester stub. It logs its
# argv to $STATS_LOG, prints PAYLOAD_FILE (when given) on stdout, and exits
# EXIT_CODE, so a test can drive the 0/1/3 branches the asset maps. Both
# spellings exist because the asset dispatches on the extension: a `.mjs` runs
# under node, anything else executes directly.
make_stats() {
    local target="$1" code="$2" payload="${3:-}"
    if [ "${target##*.}" = "mjs" ]; then
        cat >"$target" <<'STATS_MJS'
#!/usr/bin/env node
import { appendFileSync, readFileSync } from 'node:fs'
if (process.env.STATS_LOG) appendFileSync(process.env.STATS_LOG, process.argv.slice(2).join(' ') + '\n')
const payload = process.env.STUB_PAYLOAD
if (payload) process.stdout.write(readFileSync(payload, 'utf8'))
else process.stderr.write(`stub harvester: exit ${process.env.STUB_EXIT}\n`)
process.exitCode = Number(process.env.STUB_EXIT)
STATS_MJS
    else
        cat >"$target" <<'STATS_SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${STATS_LOG:-/dev/null}"
if [ -n "${STUB_PAYLOAD:-}" ]; then cat "$STUB_PAYLOAD"; else echo "stub harvester: exit $STUB_EXIT" >&2; fi
exit "$STUB_EXIT"
STATS_SH
    fi
    chmod +x "$target"
    STUB_EXIT="$code"
    STUB_PAYLOAD="$payload"
    export STUB_EXIT STUB_PAYLOAD
}

# make_trajectory FIXTURE OUT — compose the trajectory the harvester would
# return for FIXTURE: run-record fields read from the fixture, harvest fields
# supplied by $ROUNDS_JSON / $CLASSES_JSON / $ORPHANS_JSON / $ISSUE_NUMBER.
make_trajectory() {
    # One-shot overrides. A `VAR=x helper` prefix on a shell FUNCTION persists
    # in bash (unlike on an external command), so without this each override
    # would silently configure every later call too — and a case could then
    # pass for a reason its own setup never established. Captured, then
    # cleared, so the prefix means what it looks like it means.
    local issue="${ISSUE_NUMBER:-0}" rounds="${ROUNDS_JSON:-[]}" classes="${CLASSES_JSON:-{\}}"
    local orphans="${ORPHANS_JSON:-[]}" forged="${FORGED_JSON:-[]}"
    unset ISSUE_NUMBER ROUNDS_JSON CLASSES_JSON ORPHANS_JSON FORGED_JSON
    ISSUE_NUMBER="$issue" ROUNDS_JSON="$rounds" CLASSES_JSON="$classes" \
        ORPHANS_JSON="$orphans" FORGED_JSON="$forged" node -e '
      const fs = require("node:fs")
      const [fixture, out] = process.argv.slice(1)
      const run = JSON.parse(fs.readFileSync(fixture, "utf8"))
      const trajectory = {
        run_id: run.run_id,
        issue: Number(process.env.ISSUE_NUMBER || 0),
        initiated_by: run.initiated_by,
        started_at: run.started_at,
        outcome: run.outcome,
        pr: run.pr,
        promotion: run.promotion,
        stage_transitions: run.stage_transitions,
        interventions: run.interventions,
        settlements: run.settlements,
        rounds: JSON.parse(process.env.ROUNDS_JSON || "[]"),
        findings_by_class_and_provenance: JSON.parse(process.env.CLASSES_JSON || "{}"),
        orphan_comments: JSON.parse(process.env.ORPHANS_JSON || "[]"),
        forged_comments: JSON.parse(process.env.FORGED_JSON || "[]")
      }
      fs.writeFileSync(out, JSON.stringify(trajectory, null, 2))
    ' "$1" "$2"
}

POLICY_SECTION='<!-- dev-flow:begin:policy-disclosure -->
rigor: `standard` (`default_rigor`) → challenge ≤3, review ≤3, integration 4, remediation 4, min_rounds 1

- cap-below-default: challenge lowered to 2 by the rigor:light label
<!-- dev-flow:end:policy-disclosure -->'

# make_pr_json OUT BODY_FILE — a `gh pr view --json` answer. $PR_NUMBER (default
# $PR) is the PR it describes and $CLOSING supplies closingIssuesReferences.
# Comments do NOT come from here: the asset reads them through the paginated
# REST endpoint (see set_comments).
make_pr_json() {
    # One-shot overrides — see make_trajectory.
    local number="${PR_NUMBER:-$PR}" closing="${CLOSING:-[]}"
    unset PR_NUMBER CLOSING
    PR_NUMBER="$number" CLOSING="$closing" node -e '
      const fs = require("node:fs")
      const [out, bodyFile] = process.argv.slice(1)
      fs.writeFileSync(out, JSON.stringify({
        number: Number(process.env.PR_NUMBER),
        url: `https://github.com/o/r/pull/${process.env.PR_NUMBER}`,
        title: "feat(x): y",
        state: "OPEN",
        isDraft: true,
        body: fs.readFileSync(bodyFile, "utf8"),
        closingIssuesReferences: JSON.parse(process.env.CLOSING)
      }, null, 2))
    ' "$1" "$2"
}

# set_comments DIR NUMBER COMMENT_FILE... — the answer the gh stub serves for
# `repos/o/r/issues/NUMBER/comments`. Written as an array of PAGES, which is
# what `gh api --paginate --slurp` returns; $PAGE_PER_COMMENT=1 puts each
# comment on its own page so a test can prove the pages are flattened, and
# $COMMENT_ACTOR overrides the author id so a test can post an untrusted one.
set_comments() {
    local dir="$1" number="$2"
    # One-shot overrides — see make_trajectory.
    local actor="${COMMENT_ACTOR:-$ACTOR}" created="${COMMENT_CREATED_AT:-2026-08-20T09:00:00Z}"
    local perpage="${PAGE_PER_COMMENT:-0}"
    unset COMMENT_ACTOR COMMENT_CREATED_AT PAGE_PER_COMMENT
    shift 2
    mkdir -p "$dir"
    COMMENT_ACTOR="$actor" COMMENT_CREATED_AT="$created" PAGE_PER_COMMENT="$perpage" node -e '
      const fs = require("node:fs")
      const [out, ...files] = process.argv.slice(1)
      const created = (process.env.COMMENT_CREATED_AT || "2026-08-20T09:00:00Z").split(",")
      const comments = files.map((file, i) => ({
        id: 1000 + i,
        user: { login: "evanharmon1", id: Number(process.env.COMMENT_ACTOR) },
        created_at: created[i] || created[created.length - 1],
        body: fs.readFileSync(file, "utf8")
      }))
      const pages = process.env.PAGE_PER_COMMENT === "1" ? comments.map((c) => [c]) : [comments]
      fs.writeFileSync(out, JSON.stringify(pages))
    ' "$dir/$number.json" "$@"
}

# run_report ENVDIR [args...] — run the asset with the stub PATH in place,
# capturing stdout/stderr/exit code into OUT/ERR/RC.
run_report() {
    local dir="$1" arg has_trust=0
    shift
    # The asset has no default trust root by design, so every ordinary case
    # supplies one; a case testing the trust boundary passes its own.
    for arg in "$@"; do
        case "$arg" in
        --trusted-actor-id | --trusted-actors-file) has_trust=1 ;;
        esac
    done
    [ "$has_trust" -eq 1 ] || set -- "$@" --trusted-actor-id "$ACTOR"
    RC=0
    OUT="$(PATH="$dir/bin:$PATH" node "$REPORT" "$@" 2>"$dir/stderr")" || RC=$?
    ERR="$(cat "$dir/stderr")"
}

contains() {
    printf '%s' "$1" | grep -qF -- "$2"
}

# scaffold DIR FIXTURE BODY — the common setup: gh stub, harvester stub with a
# trajectory built from FIXTURE, a PR whose body is BODY, and one trusted
# evidence marker on the PR naming that fixture's run.
scaffold() {
    local d="$1" fixture="$2" body="$3" run_id
    mkdir -p "$d"
    make_gh "$d"
    ISSUE_NUMBER="$ISSUE" make_trajectory "$FIXTURES/$fixture.json" "$d/trajectory.json"
    make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
    write_file "$d/body" "$body"
    run_id="$(node -pe 'JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).run_id' "$d/trajectory.json")"
    marker_file "$d/c1" evidence "$run_id" challenge pr -
    make_pr_json "$d/pr.json" "$d/body"
    set_comments "$d/comments" "$PR" "$d/c1"
}

# ---------------------------------------------------------------------------
# 1. Is there evidence, and can this checkout read it?
# ---------------------------------------------------------------------------

echo "==> a checkout with no harvester but a discoverable run exits 12, not 10"
d="$TMPROOT/nostats-with-run"
scaffold "$d" further-along "body"
rm "$d/stats.mjs"
git init -q -b main "$d/repo"
RC=0
OUT="$(cd "$d/repo" && PATH="$d/bin:$PATH" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    GH_USER_ID="$ACTOR" node "$REPORT" --repo o/r --pr "$PR" --trusted-actor-id "$ACTOR" 2>"$d/stderr")" || RC=$?
ERR="$(cat "$d/stderr")"
[ "$RC" -eq 12 ] && contains "$ERR" "no-stats-script" &&
    ok "exit 12 naming no-stats-script" || bad "expected exit 12 / no-stats-script, got $RC: $ERR"
contains "$ERR" "run-6001-further-along" &&
    ok "the message names the run that was found but cannot be read" ||
    bad "exit 12 did not name the discovered run"
contains "$ERR" "do NOT report the session as having no run record" &&
    ok "the message forbids reporting the run record absent" ||
    bad "exit 12 does not distinguish itself from an absent run record"
[ -z "$OUT" ] && ok "no report is rendered" || bad "exit 12 rendered a report"

echo "==> a checkout with no harvester and no marker exits 10"
d="$TMPROOT/nostats-no-run"
mkdir -p "$d"
make_gh "$d"
write_file "$d/body" "body"
make_pr_json "$d/pr.json" "$d/body"
git init -q -b main "$d/repo"
RC=0
OUT="$(cd "$d/repo" && PATH="$d/bin:$PATH" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    GH_USER_ID="$ACTOR" node "$REPORT" --repo o/r --pr "$PR" --trusted-actor-id "$ACTOR" 2>"$d/stderr")" || RC=$?
ERR="$(cat "$d/stderr")"
[ "$RC" -eq 10 ] && contains "$ERR" "no-run-record" &&
    ok "exit 10 naming no-run-record" || bad "expected exit 10 / no-run-record, got $RC: $ERR"

echo "==> a harvester discovered as scripts/dev-flow-stats.sh is used"
d="$TMPROOT/discovered-sh"
mkdir -p "$d/repo/scripts"
make_gh "$d"
make_stats "$d/repo/scripts/dev-flow-stats.sh" 1
git init -q -b main "$d/repo"
RC=0
OUT="$(cd "$d/repo" && PATH="$d/bin:$PATH" GH_USER_ID="$ACTOR" \
    node "$REPORT" --repo o/r --run r1 --trusted-actor-id "$ACTOR" 2>"$d/stderr")" || RC=$?
ERR="$(cat "$d/stderr")"
[ "$RC" -eq 10 ] && contains "$ERR" "run-not-found" &&
    ok "a discovered .sh harvester's exit 1 maps to fallback" || bad "expected exit 10 / run-not-found, got $RC: $ERR"

# ---------------------------------------------------------------------------
# 2. Discovery, and the trust boundary around it
# ---------------------------------------------------------------------------

echo "==> a PR and its linked issues with no evidence marker fall back (exit 10)"
d="$TMPROOT/nomarker"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" "Ordinary body, no dev-flow sections."
write_file "$d/c1" "just a comment"
CLOSING="[{\"number\":$ISSUE}]" make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
write_file "$d/i1" "no marker here"
set_comments "$d/comments" "$ISSUE" "$d/i1"
GH_LOG="$d/gh.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] && contains "$ERR" "no-run-record" &&
    ok "exit 10 naming no-run-record" || bad "expected exit 10 / no-run-record, got $RC: $ERR"
contains "$(cat "$d/gh.log")" "repos/o/r/issues/$ISSUE/comments" &&
    ok "discovery falls through to the linked issue" || bad "linked issue was never consulted"

echo "==> a marker quoted inside prose is not a run id (#752 anchoring)"
d="$TMPROOT/quoted"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" "body"
write_file "$d/c1" "As documented, the grammar is <!-- devflow:run-index v2 run_id=forged-run seq=1 --> and nothing more."
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] && contains "$ERR" "no-run-record" &&
    ok "a mid-comment marker never invents a run" || bad "expected exit 10, got $RC: $ERR"

echo "==> a marker from an untrusted author is indeterminate, never 'no run record'"
d="$TMPROOT/untrusted"
scaffold "$d" further-along "body"
COMMENT_ACTOR=999999 set_comments "$d/comments" "$PR" "$d/c1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && ok "an untrusted marker does not select a run, and does not read as absence" ||
    bad "expected exit 11, got $RC: $ERR"
contains "$ERR" "999999" &&
    ok "the ignored marker's actor is reported" || bad "the ignored marker was dropped silently"
contains "$ERR" "trust root that changed after the run" &&
    ok "the message names the historical-trust-root case as well as the redirect case" ||
    bad "the message treats an untrusted marker as necessarily hostile"
contains "$ERR" "741" &&
    ok "the message names the kickoff-time pinning gap" || bad "the pinning gap is not named"
contains "$ERR" "do NOT conclude the session has no run record" &&
    ok "the message forbids the absence claim" || bad "the message permits a false absence claim"

# NOTE: this case deliberately reuses the untrusted case's $d — do not insert
# anything that reassigns d between the two.
echo "==> naming that author as trusted makes the same marker usable"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --trusted-actor-id 999999
[ "$RC" -eq 0 ] && contains "$OUT" 'run `run-6001-further-along`' &&
    ok "the marker is followed once its author is trusted" || bad "expected exit 0, got $RC: $ERR"

echo "==> only a PR with NO marker at all is no-run-record"
d="$TMPROOT/trulyempty"
scaffold "$d" further-along "body"
write_file "$d/plain" "no marker here at all"
set_comments "$d/comments" "$PR" "$d/plain"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] && contains "$ERR" "evidence marker at all" &&
    ok "exit 10 is reserved for a genuinely empty search" || bad "expected exit 10, got $RC: $ERR"

echo "==> an untrusted second marker cannot force the ambiguity exit"
d="$TMPROOT/untrusted-second"
scaffold "$d" further-along "body"
marker_file "$d/c2" evidence run-someone-elses challenge pr -
TRUSTED="$ACTOR" node -e '
  const fs = require("node:fs")
  const [out, trusted, untrusted] = process.argv.slice(1)
  fs.writeFileSync(out, JSON.stringify([[
    { id: 1, user: { login: "a", id: Number(process.env.TRUSTED) }, body: fs.readFileSync(trusted, "utf8") },
    { id: 2, user: { login: "b", id: 424243 }, body: fs.readFileSync(untrusted, "utf8") }
  ]]))
' "$d/comments/$PR.json" "$d/c1" "$d/c2"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "the trusted marker still resolves" ||
    bad "an untrusted marker denied the evidence path, got $RC: $ERR"
contains "$OUT" "Untrusted evidence markers ignored during discovery: 1" &&
    ok "the report counts the ignored marker" || bad "the report hides the ignored marker"

echo "==> two TRUSTED run ids on one PR are indeterminate (exit 11)"
d="$TMPROOT/ambiguous"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" "body"
marker_file "$d/c1" evidence run-aaa challenge pr -
marker_file "$d/c2" evidence run-bbb review pr -
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1" "$d/c2"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && contains "$ERR" "run-aaa, run-bbb" &&
    ok "exit 11 naming both runs" || bad "expected exit 11 naming both runs, got $RC: $ERR"
[ -z "$OUT" ] && ok "an indeterminate discovery renders nothing" || bad "indeterminate discovery rendered a report"

echo "==> a run id found only on the linked issue is used"
d="$TMPROOT/issueonly"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" \
    ROUNDS_JSON='[{"stage":"challenge","round":1,"pass_count":1,"finding_count":0,"has_adjudication":true}]' \
    make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "body"
write_file "$d/c1" "no marker"
CLOSING="[{\"number\":$ISSUE}]" make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
marker_file "$d/i1" run-index run-6001-further-along kickoff issue -
set_comments "$d/comments" "$ISSUE" "$d/i1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && contains "$OUT" 'run `run-6001-further-along`' &&
    ok "the issue-side run-index anchors discovery" || bad "expected the issue's run id, got $RC: $ERR"
contains "$OUT" "run id from evidence marker on issue #$ISSUE" &&
    ok "the report states where the run id came from" || bad "provenance of the run id is not reported"

echo "==> a marker past the first page of comments is still found"
d="$TMPROOT/paged"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" \
    ROUNDS_JSON='[{"stage":"challenge","round":1,"pass_count":1,"finding_count":0,"has_adjudication":true}]' \
    make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "body"
write_file "$d/c1" "chatter"
write_file "$d/c2" "more chatter"
marker_file "$d/c3" evidence run-6001-further-along challenge pr -
make_pr_json "$d/pr.json" "$d/body"
PAGE_PER_COMMENT=1 set_comments "$d/comments" "$PR" "$d/c1" "$d/c2" "$d/c3"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && contains "$OUT" 'run `run-6001-further-along`' &&
    ok "every page of comments is searched, not just the first" ||
    bad "a marker on a later comment page was missed, got $RC: $ERR"

echo "==> a harvested run bound to a different PR is indeterminate (exit 11)"
d="$TMPROOT/wrongpr"
scaffold "$d" further-along "body"
PR_OTHER=901
PR_NUMBER="$PR_OTHER" make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR_OTHER" "$d/c1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR_OTHER" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && ok "exit 11" || bad "expected exit 11, got $RC: $ERR"
contains "$ERR" "records PR #$PR, not the requested #$PR_OTHER" &&
    ok "the mismatch names both PRs" || bad "the PR-binding mismatch is not explained"
[ -z "$OUT" ] && ok "nothing is rendered" || bad "a mis-bound run rendered a report"

echo "==> --as-of filters discovery, so a later marker cannot change history"
d="$TMPROOT/asof"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" \
    ROUNDS_JSON='[{"stage":"challenge","round":1,"pass_count":1,"finding_count":0,"has_adjudication":true}]' \
    make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "body"
marker_file "$d/c1" evidence run-6001-further-along challenge pr -
marker_file "$d/c2" evidence run-a-later-rerun challenge pr -
make_pr_json "$d/pr.json" "$d/body"
COMMENT_CREATED_AT="2026-08-20T09:00:00Z,2026-09-01T09:00:00Z" \
    set_comments "$d/comments" "$PR" "$d/c1" "$d/c2"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --as-of 2026-08-25T00:00:00Z
[ "$RC" -eq 0 ] && contains "$OUT" 'run `run-6001-further-along`' &&
    ok "a marker posted after the cutoff is excluded from discovery" ||
    bad "expected the pre-cutoff run, got $RC: $ERR"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] &&
    ok "without the cutoff the same two markers are ambiguous, proving the filter did the work" ||
    bad "expected exit 11 with no cutoff, got $RC: $ERR"

echo "==> an explicit --run whose record names no PR does not borrow that PR's caps"
d="$TMPROOT/unbound"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" \
    ROUNDS_JSON='[{"stage":"challenge","round":1,"pass_count":1,"finding_count":1,"has_adjudication":true}]' \
    make_trajectory "$FIXTURES/remediation-loop.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "$POLICY_SECTION"
make_pr_json "$d/pr.json" "$d/body"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --run run-6058-remediation-loop --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
contains "$OUT" "is not bound to PR #$PR" &&
    ok "the caps are refused with the binding reason" ||
    bad "an unbound run consumed the PR's disclosed caps"
contains "$OUT" "PR binding: none" &&
    ok "the binding line says none rather than claiming a marker" ||
    bad "the binding line claims a marker that explicit-run mode never read"
contains "$OUT" "- Rounds spent: 1 / no cap recorded" &&
    ok "rounds are reported without the unrelated denominator" ||
    bad "the unrelated cap still appears as a denominator"

echo "==> exit 12 does not present a --run argument as proof the run exists"
d="$TMPROOT/nostats-explicit-run"
mkdir -p "$d/repo"
make_gh "$d"
git init -q -b main "$d/repo"
RC=0
OUT="$(cd "$d/repo" && PATH="$d/bin:$PATH" node "$REPORT" --repo o/r --run made-up \
    --trusted-actor-id "$ACTOR" 2>"$d/stderr")" || RC=$?
ERR="$(cat "$d/stderr")"
[ "$RC" -eq 12 ] && ok "exit 12" || bad "expected exit 12, got $RC: $ERR"
contains "$ERR" "has NOT been verified against any marker" &&
    ok "an unverified --run id is reported as unverified" ||
    bad "an unchecked argv string was reported as a recorded run"
contains "$ERR" "IS recorded" &&
    bad "exit 12 claimed the --run id is recorded" ||
    ok "exit 12 makes no recording claim for a --run id"

# ---------------------------------------------------------------------------
# 3. The run-record path, measured against the fixture corpus
# ---------------------------------------------------------------------------

echo "==> the run-record path renders every fixed section"
d="$TMPROOT/full"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" \
    ROUNDS_JSON='[
      {"stage":"challenge","round":1,"pass_count":1,"finding_count":3,"has_adjudication":true},
      {"stage":"challenge","round":2,"pass_count":1,"finding_count":1,"has_adjudication":true},
      {"stage":"review","round":1,"pass_count":1,"finding_count":0,"has_adjudication":false}
    ]' \
    CLASSES_JSON='{"correctness/original":2,"hardening/original":1,"design/round:1":1}' \
    ORPHANS_JSON='[{"id":1,"actor_id":9}]' \
    make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "What/why.

$POLICY_SECTION
"
marker_file "$d/c1" evidence run-6001-further-along challenge pr -
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
GH_LOG="$d/gh.log" STATS_LOG="$d/stats.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    GH_USER_ID="$ACTOR" run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"

for needle in \
    '## Run evidence — run `run-6001-further-along`' \
    '### Policy the PR discloses (unverified)' \
    '### Stage `challenge`' \
    '### Stage `review`' \
    '### Findings by class and provenance' \
    '### Policy overrides the PR discloses (unverified)' \
    '### Interventions' \
    '### Deferred findings settled' \
    '### Evidence integrity' \
    "### Not measurable from this run's evidence"; do
    contains "$OUT" "$needle" && ok "section: $needle" || bad "missing section: $needle"
done

contains "$OUT" 'rigor: `standard` (`default_rigor`) → challenge ≤3, review ≤3, integration 4, remediation 4, min_rounds 1' &&
    ok "the run's own disclosed policy line is echoed" || bad "the policy line was not read back"
contains "$OUT" '**Unverified.**' &&
    ok "the disclosed policy is labelled unverified" || bad "the policy section claims more than it can prove"
contains "$OUT" 'does not reconstruct it' &&
    ok "the caveat says --as-of does not reconstruct the PR body" || bad "the --as-of caveat is missing"
contains "$OUT" "- Rounds spent: 2 / cap 3 (disclosed, unverified)" &&
    ok "challenge rounds are reported against the disclosed cap" || bad "challenge rounds-vs-cap missing"
contains "$OUT" "- Rounds spent: 1 / cap 3 (disclosed, unverified)" &&
    ok "review rounds are reported against the disclosed cap" || bad "review rounds-vs-cap missing"
contains "$OUT" '### Stage `plan`' &&
    ok "a non-confidence stage still gets its own section" || bad "the plan stage has no section"
contains "$OUT" "- Rounds spent: 0 / no cap recorded" &&
    bad "a stage with neither a cap nor a round still printed round lines" ||
    ok "a stage with neither a cap nor a round prints no round lines"
contains "$OUT" "- Rounds spent: 0 / cap 4 (disclosed, unverified)" &&
    ok "a capped stage that ran no round still reports 0 against its cap" ||
    bad "a capped stage with no rounds dropped its round line"
contains "$OUT" "- Rounds with no adjudication record: 1" &&
    ok "a round with no adjudication is named" || bad "unadjudicated round not reported"
contains "$OUT" "| correctness | original | 2 |" &&
    ok "class/provenance counts render" || bad "class/provenance table missing a row"
contains "$OUT" "| design | round:1 | 1 |" &&
    ok "a round:N provenance survives the class/provenance split" || bad "round:N provenance mangled"
contains "$OUT" "- cap-below-default: challenge lowered to 2 by the rigor:light label" &&
    ok "the published disclosure is reported as an override" || bad "disclosure not reported under Overrides"
contains "$OUT" "answered the implementer's blocked_question" &&
    ok "interventions are listed" || bad "interventions missing"
contains "$OUT" "| 2026-08-20T10:00:00Z | asked | implement |" &&
    ok "an intervention is attributed to the stage that was open" || bad "intervention stage attribution wrong"
contains "$OUT" "codex-cli" &&
    ok "a settlement's finder slug is recovered from its finding id" || bad "finder slug not recovered"
contains "$OUT" "Trusted-but-unlisted comments: 1" &&
    ok "orphan comments are counted" || bad "orphan comment count missing"
contains "$OUT" "PR binding: bound to PR #$PR" &&
    ok "the report states the run's PR binding" || bad "PR binding not reported"
contains "$OUT" "harmon-devkit#753" &&
    ok "the override-detail gap names its follow-up issue" || bad "override gap not named"
contains "$OUT" "keyed by stage" &&
    ok "the run-wide class/provenance limitation is stated" || bad "class/provenance limitation not stated"
contains "$(cat "$d/stats.log")" "--trusted-actor-id $ACTOR" &&
    ok "the caller's trust root reaches the harvester" || bad "trusted actor id not passed through"
contains "$(cat "$d/gh.log")" "api user" &&
    bad "the tool consulted the authenticated account — there must be no implicit trust root" ||
    ok "no implicit trust root: the authenticated account is never consulted"

echo "==> a run with no trust root at all is a usage error, never a default"
d="$TMPROOT/notrust"
scaffold "$d" further-along "body"
RC=0
OUT="$(PATH="$d/bin:$PATH" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    node "$REPORT" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" 2>"$d/stderr")" || RC=$?
ERR="$(cat "$d/stderr")"
[ "$RC" -eq 2 ] && ok "exit 2" || bad "expected exit 2, got $RC: $ERR"
contains "$ERR" "at least one --trusted-actor-id" &&
    ok "the message says a trust root is required" || bad "the usage error does not name the missing trust root"
contains "$ERR" "741" &&
    ok "the message names where a configured allowlist will come from" ||
    bad "the usage error does not point at the registry allowlist issue"

echo "==> an arbitrary trusted actor id is honoured on its own"
d="$TMPROOT/trusted"
scaffold "$d" further-along "body"
COMMENT_ACTOR=424242 set_comments "$d/comments" "$PR" "$d/c1"
GH_LOG="$d/gh.log" STATS_LOG="$d/stats.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --trusted-actor-id 424242
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
contains "$(cat "$d/stats.log")" "--trusted-actor-id 424242" &&
    ok "the supplied id reaches the harvester" || bad "supplied trusted actor id not passed through"

echo "==> a PR body with no policy-disclosure section reports the caps unknown"
d="$TMPROOT/nopolicy"
scaffold "$d" further-along "No dev-flow sections at all."
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
contains "$OUT" "Caps unknown" &&
    ok "the caps are reported unknown rather than guessed from .devflow.toml" || bad "caps were not reported unknown"
contains "$OUT" "Unknown — the PR body published no policy-disclosure section" &&
    ok "overrides are unknown, not 'none'" || bad "overrides wrongly reported as none"

echo "==> two policy-disclosure sections in one body are ambiguous, not first-wins"
d="$TMPROOT/dualpolicy"
scaffold "$d" further-along "$POLICY_SECTION

$POLICY_SECTION"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
contains "$OUT" "more than one policy-disclosure section" &&
    ok "a duplicated section reports the caps unknown rather than picking one" ||
    bad "a duplicated policy-disclosure section was silently resolved first-wins"

echo "==> a stage entered twice collapses into one section (remediation loop)"
d="$TMPROOT/loop"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" \
    ROUNDS_JSON='[
      {"stage":"challenge","round":1,"pass_count":1,"finding_count":2,"has_adjudication":true},
      {"stage":"challenge","round":2,"pass_count":1,"finding_count":0,"has_adjudication":true}
    ]' \
    make_trajectory "$FIXTURES/remediation-loop.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "body"
marker_file "$d/c1" evidence run-6058-remediation-loop challenge pr -
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
[ "$(printf '%s\n' "$OUT" | grep -c '^### Stage `challenge`$')" -eq 1 ] &&
    ok "the re-entered stage has exactly one section" || bad "a re-entered stage rendered more than one section"
[ "$(printf '%s\n' "$OUT" | grep -c '^### Stage `implement`$')" -eq 1 ] &&
    ok "the re-entered implement stage has exactly one section" || bad "implement rendered more than one section"
contains "$OUT" "exit: P1 found, back to implement" &&
    ok "both of the stage's exits are listed" || bad "a re-entered stage's exits were dropped"
contains "$OUT" '- Outcome: `in-flight`' &&
    ok "a run with no outcome renders in-flight" || bad "null outcome mis-rendered"
contains "$OUT" "not yet an unattended run" &&
    ok "an in-flight run with no interventions is not called unattended" ||
    bad "an in-flight run was reported as having reached its outcome unattended"
contains "$OUT" "the run record names no PR yet" &&
    ok "a run with no recorded PR says the binding rests on the marker alone" ||
    bad "an unbound run silently claimed a PR binding"

echo "==> the machine form carries the same measurements"
d="$TMPROOT/json"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" \
    ROUNDS_JSON='[{"stage":"challenge","round":1,"pass_count":1,"finding_count":3,"has_adjudication":true}]' \
    CLASSES_JSON='{"correctness/original":3}' \
    make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "$POLICY_SECTION"
marker_file "$d/c1" evidence run-6001-further-along challenge pr -
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --json
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
printf '%s' "$OUT" >"$d/report.json"
node -e '
  const report = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))
  const problems = []
  if (report.schema !== "retro-run-report.v1") problems.push("schema")
  if (report.run_id !== "run-6001-further-along") problems.push("run_id")
  if (report.policy.rounds.challenge !== 3) problems.push("policy.rounds.challenge")
  if (report.policy.verified !== false) problems.push("policy.verified must be false")
  if (typeof report.policy.source !== "string") problems.push("policy.source")
  if (!Array.isArray(report.source.ignored_markers)) problems.push("source.ignored_markers")
  if (!Array.isArray(report.source.malformed_markers)) problems.push("source.malformed_markers")
  if (typeof report.source.pr_binding !== "string") problems.push("source.pr_binding")
  const challenge = report.measurements.stages.find((s) => s.stage === "challenge")
  if (!challenge || challenge.rounds_spent !== 1 || challenge.cap !== 3) problems.push("stages.challenge")
  if (report.measurements.settlements[0].finder !== "codex-cli") problems.push("settlements.finder")
  if (!report.unavailable.some((g) => g.issue.includes("753"))) problems.push("unavailable")
  if (problems.length > 0) { console.error(problems.join(", ")); process.exit(1) }
' "$d/report.json" &&
    ok "the JSON form carries schema, unverified policy, binding, stages, settlements and gaps" ||
    bad "the JSON form is missing fields"

echo "==> a malformed --as-of is a usage error, never a silent empty cutoff"
d="$TMPROOT/badasof"
scaffold "$d" further-along "body"
for stamp in not-a-date 2026-02-30T00:00:00Z 2026-09-03T12:00:00 0; do
    GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
        run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --as-of "$stamp"
    [ "$RC" -eq 2 ] && contains "$ERR" "not a valid ISO-8601 UTC timestamp" &&
        ok "--as-of $stamp is rejected" ||
        bad "--as-of $stamp gave $RC instead of a usage error: $ERR"
done
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --as-of 2026-08-25T00:00:00.500Z
[ "$RC" -eq 0 ] && ok "a fractional-seconds cutoff is still accepted" ||
    bad "a valid fractional-seconds cutoff was rejected: $ERR"

echo "==> the remediation budget is named as unmeasurable, not silently skipped"
d="$TMPROOT/remediation"
scaffold "$d" further-along "$POLICY_SECTION"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
contains "$OUT" "remediation 4" &&
    ok "the disclosed remediation cap appears in the policy line" ||
    bad "the policy line dropped the remediation cap"
contains "$OUT" "remediation rounds spent against the remediation cap" &&
    ok "the report says the remediation budget is not measurable from this evidence" ||
    bad "a cap is displayed with no section measuring it and no gap entry naming it"

echo "==> a marker after blank lines is not the comment's first line"
d="$TMPROOT/blankline"
scaffold "$d" further-along "body"
{
    printf '\n\n'
    cat "$d/c1"
} >"$d/c-blank"
set_comments "$d/comments" "$PR" "$d/c-blank"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] && contains "$ERR" "evidence marker at all" &&
    ok "leading blank lines do not promote a quoted marker to the first line" ||
    bad "a marker after blank lines was accepted, got $RC: $ERR"

echo "==> an indented marker on the first line is still a marker"
d="$TMPROOT/indented"
scaffold "$d" further-along "body"
{
    printf '  '
    cat "$d/c1"
} >"$d/c-indent"
set_comments "$d/comments" "$PR" "$d/c-indent"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "leading spaces on the marker line are tolerated" ||
    bad "an indented first-line marker was rejected, got $RC: $ERR"

echo "==> the report distinguishes disclosed policy overrides from adjudication overrides"
d="$TMPROOT/overrides"
scaffold "$d" further-along "$POLICY_SECTION"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
contains "$OUT" "**Adjudication overrides are not covered here.**" &&
    ok "the overrides section says what it does not cover" ||
    bad "an empty overrides section could be read as 'nothing was overridden'"
contains "$OUT" 'never "the orchestrator overrode nothing"' &&
    ok "the wrong reading is named explicitly" || bad "the wrong reading is not ruled out"
contains "$OUT" "kickoff-time registry revision" &&
    ok "evidence integrity states the trust-pinning limitation" ||
    bad "the trust-pinning limitation is not stated where integrity is read"

echo "==> the skill's documented command is runnable as written"
grep -A 3 'assets/retro-run-report.mjs --repo' ai/skills/universal/retro/SKILL.md |
    grep -qE -- '--trusted-actor-id|--trusted-actors-file' &&
    ok "the documented command carries the required trust root" ||
    bad "copying the documented command would exit 2 before doing any work"

echo "==> a terminal run with no interventions IS reported unattended"
d="$TMPROOT/unattended"
scaffold "$d" further-along "body"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
contains "$OUT" '- Outcome: `ready-for-review`' &&
    ok "the fixture's terminal outcome renders" || bad "terminal outcome missing"

echo "==> class/provenance is attributed to the one stage that found anything"
d="$TMPROOT/onestage"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" \
    ROUNDS_JSON='[
      {"stage":"challenge","round":1,"pass_count":1,"finding_count":3,"has_adjudication":true},
      {"stage":"review","round":1,"pass_count":1,"finding_count":0,"has_adjudication":true}
    ]' \
    CLASSES_JSON='{"correctness/original":2,"design/round:1":1}' \
    make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "$POLICY_SECTION"
marker_file "$d/c1" evidence run-6001-further-along challenge pr -
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
contains "$OUT" "  - correctness / original: 2" &&
    ok "the stage section carries its own class/provenance rows" ||
    bad "class/provenance was not attributed to the only stage with findings"
contains "$OUT" "this is its only stage with findings" &&
    ok "the attribution states why it is sound" || bad "the attribution is asserted without its reason"
contains "$OUT" "belongs to stage \`challenge\`" &&
    ok "the run-wide table points back at that stage" || bad "the run-wide table does not name the stage"

echo "==> two stages with findings fall back to the run-wide table, saying why"
d="$TMPROOT/twostage"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" \
    ROUNDS_JSON='[
      {"stage":"challenge","round":1,"pass_count":1,"finding_count":3,"has_adjudication":true},
      {"stage":"review","round":1,"pass_count":1,"finding_count":2,"has_adjudication":true}
    ]' \
    CLASSES_JSON='{"correctness/original":5}' \
    make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "$POLICY_SECTION"
marker_file "$d/c1" evidence run-6001-further-along challenge pr -
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
contains "$OUT" "not derivable per stage" &&
    ok "a multi-stage run says the split is not derivable rather than guessing" ||
    bad "a multi-stage run silently attributed the aggregate"
contains "$OUT" "- Adjudication overrides: not derivable" &&
    ok "each stage with findings names the adjudication-override gap" ||
    bad "the override gap is absent from the stage sections"
contains "$OUT" "belongs to stage" &&
    bad "a multi-stage run claimed single-stage attribution" ||
    ok "no single-stage claim is made when two stages found things"

echo "==> the report names the actual trust root, not just where it came from"
d="$TMPROOT/trustnamed"
scaffold "$d" further-along "body"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --trusted-actor-id "$ACTOR"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
contains "$OUT" "actor id(s) $ACTOR" &&
    ok "the trust root names the id, so a pasted retro is auditable" ||
    bad "the trust root is reported without its ids"
contains "$OUT" "supplied on the command line" &&
    bad "the trust root still reports only its provenance" ||
    ok "the unauditable placeholder is gone"

echo "==> an actors file is named alongside its ids"
d="$TMPROOT/trustfile"
scaffold "$d" further-along "body"
COMMENT_ACTOR=555555 set_comments "$d/comments" "$PR" "$d/c1"
echo '{"trusted_actor_ids":[555555,111]}' >"$d/actors.json"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --trusted-actors-file "$d/actors.json"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
contains "$OUT" "actor id(s) 111, 555555" &&
    ok "file-supplied ids are normalized, sorted and reported" ||
    bad "file-supplied ids are not in the report"
contains "$OUT" "$d/actors.json" &&
    ok "the actors file is named too" || bad "the actors file source is not reported"

echo "==> the skill gives run-not-found its own provenance wording"
grep -q 'Exit 10, `run-not-found`' ai/skills/universal/retro/SKILL.md &&
    ok "run-not-found has provenance wording of its own" ||
    bad "run-not-found shares the no-run-record provenance wording"
grep -A 6 'Exit 10, `run-not-found`' ai/skills/universal/retro/SKILL.md |
    grep -q 'Do not write "there was no run record"' &&
    ok "that wording forbids the unestablished absence claim" ||
    bad "the run-not-found wording still permits claiming no run record"
grep -q -- '--stats-script <path>' ai/skills/universal/retro/SKILL.md &&
    ok "--stats-script is documented in the skill, not only in --help" ||
    bad "--stats-script is an undocumented escape hatch"

echo "==> --as-of discloses in the OUTPUT what it does and does not reconstruct"
d="$TMPROOT/asof-scope"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" \
    ROUNDS_JSON='[{"stage":"challenge","round":1,"pass_count":1,"finding_count":0,"has_adjudication":true}]' \
    make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "$POLICY_SECTION"
write_file "$d/c1" "no marker on the PR"
marker_file "$d/i1" run-index run-6001-further-along kickoff issue -
CLOSING="[{\"number\":$ISSUE}]" make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
set_comments "$d/comments" "$ISSUE" "$d/i1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --as-of 2026-08-25T00:00:00Z
[ "$RC" -eq 0 ] && ok "exit 0 on the linked-issue discovery path" || bad "expected exit 0, got $RC: $ERR"
contains "$OUT" "the run record and its comment evidence only" &&
    ok "the report narrows what --as-of reconstructs" ||
    bad "--as-of still implies it reconstructs everything"
contains "$OUT" "linked-issue set" &&
    ok "the linked-issue set is named as current-state in the output, not just the docs" ||
    bad "the un-versioned linked-issue input is not disclosed in the report"
contains "$OUT" "closing references" &&
    ok "the disclosure names where the linked-issue set comes from" ||
    bad "the disclosure does not say what the linked-issue set is"

echo "==> without --as-of no reconstruction is claimed, so no disclaimer is printed"
d="$TMPROOT/noasof"
scaffold "$d" further-along "$POLICY_SECTION"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
contains "$OUT" "the run record and its comment evidence only" &&
    bad "an --as-of disclaimer appeared with no --as-of" ||
    ok "the disclaimer is scoped to the flag that needs it"

echo "==> trust-file entries are type-checked, not coerced (§5 proves the harvester agrees)"
d="$TMPROOT/trustcoerce"
scaffold "$d" further-along "body"
for bad_entry in 'true' '"555"' '1.5' '0'; do
    printf '{"trusted_actor_ids":[%s]}' "$bad_entry" >"$d/actors.json"
    GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
        run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --trusted-actors-file "$d/actors.json"
    [ "$RC" -eq 2 ] && contains "$ERR" "must be JSON integers" &&
        ok "a $bad_entry entry is rejected" || bad "a $bad_entry entry gave $RC: $ERR"
done
printf '{"trusted_actor_ids":[%s]}' "$ACTOR" >"$d/actors.json"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --trusted-actors-file "$d/actors.json"
[ "$RC" -eq 0 ] && ok "a genuine JSON integer is still accepted" || bad "expected exit 0, got $RC: $ERR"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --trusted-actor-id "$ACTOR"
[ "$RC" -eq 0 ] && ok "command-line ids stay coerced from argv strings, as the harvester does" ||
    bad "a valid --trusted-actor-id was rejected: $ERR"

echo "==> only run-index, run-record and evidence markers participate in discovery"
d="$TMPROOT/kinds"
scaffold "$d" further-along "body"
marker_file "$d/bogus" example run-6001-further-along challenge pr -
set_comments "$d/comments" "$PR" "$d/bogus"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] && ok "a non-canonical kind never names a run" ||
    bad "devflow:example selected a run, got $RC: $ERR"
contains "$ERR" 'kind "example" is not run-index, run-record or evidence' &&
    ok "the malformed marker is reported with its reason" || bad "the malformed marker was dropped silently"

echo "==> a canonical kind missing required fields is malformed, not evidence"
d="$TMPROOT/fields"
scaffold "$d" further-along "body"
printf '<!-- devflow:evidence v2 run_id=run-6001-further-along seq=1 -->\n' >"$d/short"
set_comments "$d/comments" "$PR" "$d/short"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] && contains "$ERR" "missing required marker field stage" &&
    ok "a marker without stage/dest/round is refused by name" ||
    bad "an incomplete marker participated in discovery, got $RC: $ERR"
printf '<!-- devflow:evidence v2 run_id=r stage=nonsense dest=pr round=- seq=1 -->\n' >"$d/badstage"
set_comments "$d/comments" "$PR" "$d/badstage"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] && contains "$ERR" 'stage "nonsense" is not a run stage' &&
    ok "a marker with an unknown stage is refused by name" || bad "got $RC: $ERR"

echo "==> a malformed marker alone does not make discovery indeterminate"
d="$TMPROOT/malformed-only"
scaffold "$d" further-along "body"
marker_file "$d/bogus" example some-run challenge pr -
set_comments "$d/comments" "$PR" "$d/bogus"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] &&
    ok "noise is exit 10, not the exit 11 reserved for a refused claim" ||
    bad "a malformed marker was treated as a refused claim, got $RC"

# ---------------------------------------------------------------------------
# 4. Harvester failure modes and usage
# ---------------------------------------------------------------------------

echo "==> a harvester that reports the run indeterminate exits 11 and renders nothing"
d="$TMPROOT/indet"
scaffold "$d" further-along "body"
make_stats "$d/stats.mjs" 3
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && ok "exit 11" || bad "expected exit 11, got $RC: $ERR"
[ -z "$OUT" ] && ok "nothing is rendered" || bad "an indeterminate harvest rendered a report"
contains "$ERR" "indeterminate" && ok "the reason names indeterminacy" || bad "stderr does not say indeterminate"

echo "==> run-not-found after a TRUSTED marker is deleted-entry tampering, not absence"
d="$TMPROOT/notfound"
scaffold "$d" further-along "body"
make_stats "$d/stats.mjs" 1
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && ok "exit 11" || bad "expected exit 11, got $RC: $ERR"
contains "$ERR" "deleted-entry tampering, never a run that did not happen" &&
    ok "the evidence contract's wording is quoted back" || bad "the deleted-entry case is not named"

echo "==> run-not-found for an unverified --run id is still a plain fallback"
d="$TMPROOT/notfound-explicit"
scaffold "$d" further-along "body"
make_stats "$d/stats.mjs" 1
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --run made-up --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] && contains "$ERR" "run-not-found" &&
    ok "exit 10 naming run-not-found" || bad "expected exit 10 / run-not-found, got $RC: $ERR"

echo "==> a harvester crash is an operational error, never a silent fallback"
d="$TMPROOT/crash"
scaffold "$d" further-along "body"
make_stats "$d/stats.mjs" 2
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 1 ] && ok "exit 1" || bad "expected exit 1, got $RC: $ERR"

echo "==> usage errors exit 2"
d="$TMPROOT/usage"
mkdir -p "$d"
make_gh "$d"
run_report "$d" --repo o/r
[ "$RC" -eq 2 ] && ok "--pr or --run is required" || bad "expected exit 2, got $RC"
run_report "$d" --repo not-a-slug --pr 1
[ "$RC" -eq 2 ] && ok "--repo must be owner/repo" || bad "expected exit 2, got $RC"
run_report "$d" --repo o/r --pr "$PR" --stats-script "$TMPROOT/absent.mjs"
[ "$RC" -eq 2 ] && ok "--stats-script must exist" || bad "expected exit 2, got $RC"
run_report "$d" --repo o/r --pr "$PR" --trusted-actor-id nope
[ "$RC" -eq 2 ] && ok "--trusted-actor-id must be a positive integer" || bad "expected exit 2, got $RC"
echo '{"nope":[]}' >"$d/actors.json"
run_report "$d" --repo o/r --pr "$PR" --trusted-actors-file "$d/actors.json"
[ "$RC" -eq 2 ] && ok "--trusted-actors-file must carry trusted_actor_ids" || bad "expected exit 2, got $RC"

echo "==> --trusted-actors-file widens the discovery trust root too"
d="$TMPROOT/actorsfile"
scaffold "$d" further-along "body"
COMMENT_ACTOR=555555 set_comments "$d/comments" "$PR" "$d/c1"
echo '{"trusted_actor_ids":[555555]}' >"$d/actors.json"
STATS_LOG="$d/stats.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --trusted-actors-file "$d/actors.json"
[ "$RC" -eq 0 ] && ok "a file-supplied id gates discovery, not just the harvester" ||
    bad "expected exit 0, got $RC: $ERR"
contains "$(cat "$d/stats.log")" "--trusted-actors-file" &&
    ok "the file is passed through to the harvester as well" || bad "the actors file did not reach the harvester"

# ---------------------------------------------------------------------------
# 5. The real harvester: contract, discovery and trust agreement
# ---------------------------------------------------------------------------
#
# #663 (PR #751) merged on 2026-09-05, so scripts/dev-flow-stats.mjs is on `main` and
# these run for real — the skip-when-absent guard is gone deliberately. Its
# absence is now a FAILURE, not a skip: this asset's whole evidence path runs
# through that script, and a silent skip would let its removal pass unnoticed.

echo "==> the real harvester is present"
[ -f "$REAL_STATS" ] &&
    ok "scripts/dev-flow-stats.mjs is in the checkout" ||
    bad "scripts/dev-flow-stats.mjs is missing — the evidence path this asset exists to drive cannot run"

# A gh stub permissive enough for the real harvester's own API walk: the
# comments endpoint answers from $GH_COMMENTS_DIR, `pr view` from $GH_PR_JSON,
# and every other endpoint returns an empty page set so discoverAllRuns simply
# finds nothing rather than erroring.
make_permissive_gh() {
    mkdir -p "$1/bin"
    cat >"$1/bin/gh" <<'REAL_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "${1:-}" in
pr)
    cat "$GH_PR_JSON"
    ;;
api)
    case "$*" in
    */issues/*/comments*)
        n="$(printf '%s\n' "$*" | sed -n 's|.*/issues/\([0-9]*\)/comments.*|\1|p')"
        file="${GH_COMMENTS_DIR:-/nonexistent}/$n.json"
        if [ -f "$file" ]; then cat "$file"; else echo '[[]]'; fi
        ;;
    *--slurp*) echo '[]' ;;
    *) echo '[]' ;;
    esac
    ;;
*)
    echo '[]'
    ;;
esac
REAL_GH
    chmod +x "$1/bin/gh"
}

echo "==> the real harvester accepts the exact flag set this asset sends"
d="$TMPROOT/contract"
make_permissive_gh "$d"
RC=0
PATH="$d/bin:$PATH" node "$REAL_STATS" --repo o/r --run no-such-run --json \
    --trusted-actor-id 1 --as-of 2026-01-01T00:00:00Z >/dev/null 2>"$d/stderr" || RC=$?
[ "$RC" -eq 2 ] &&
    bad "the harvester rejected this asset's flag set as a usage error: $(cat "$d/stderr")" ||
    ok "the flag set parses (exit $RC, not a usage error)"

echo "==> the asset auto-discovers and INVOKES the real harvester, no --stats-script"
d="$TMPROOT/realpath"
mkdir -p "$d"
make_permissive_gh "$d"
write_file "$d/body" "$POLICY_SECTION"
marker_file "$d/c1" evidence run-6001-further-along challenge pr -
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
RC=0
OUT="$(PATH="$d/bin:$PATH" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    node "$REPORT" --repo o/r --pr "$PR" --trusted-actor-id "$ACTOR" 2>"$d/stderr")" || RC=$?
ERR="$(cat "$d/stderr")"
# 12 would mean the harvester was never found; 2 a usage error. 11 is the
# correct end-to-end answer: a trusted marker named a run the REAL harvester
# cannot find in the stubbed repo, which is the deleted-entry case.
[ "$RC" -ne 12 ] &&
    ok "the real scripts/dev-flow-stats.mjs is resolved from the git top level" ||
    bad "the asset did not find the harvester now on main: $ERR"
[ "$RC" -eq 11 ] && contains "$ERR" "deleted-entry tampering" &&
    ok "the real harvester ran and its exit code was mapped end to end" ||
    bad "expected exit 11 from the real harvester's run-not-found, got $RC: $ERR"

echo "==> the real harvester rejects the trust-file entries this asset now rejects"
d="$TMPROOT/trustagree"
make_permissive_gh "$d"
for bad_entry in 'true' '"555"'; do
    printf '{"trusted_actor_ids":[%s]}' "$bad_entry" >"$d/actors.json"
    RC=0
    PATH="$d/bin:$PATH" node "$REAL_STATS" --repo o/r --run x --json \
        --trusted-actors-file "$d/actors.json" >/dev/null 2>"$d/stderr" || RC=$?
    [ "$RC" -eq 2 ] &&
        ok "the harvester also rejects a $bad_entry entry — the two trust sets agree" ||
        bad "the harvester accepted $bad_entry (exit $RC) where this asset rejects it: the trust sets diverge"
done

# ---------------------------------------------------------------------------
# 6. Seam guard: the renderer's own published policy line
# ---------------------------------------------------------------------------
#
# The caps in the report are parsed out of the section
# scripts/render-dev-flow.mjs publishes into the PR body. Binding that parse to
# the renderer's OWN golden fixture is what turns a future grammar change from
# a silent "caps unknown" into a failing test.

echo "==> the renderer's golden policy-disclosure output still parses"
GOLDEN="$PWD/ai/schemas/fixtures/render/golden/policy-disclosure.txt"
if [ ! -f "$GOLDEN" ]; then
    skipped "ai/schemas/fixtures/render/golden/policy-disclosure.txt is absent"
else
    d="$TMPROOT/golden"
    body="$(
        echo "<!-- dev-flow:begin:policy-disclosure -->"
        cat "$GOLDEN"
        echo "<!-- dev-flow:end:policy-disclosure -->"
    )"
    scaffold "$d" further-along "$body"
    GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
        run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --json
    if [ "$RC" -ne 0 ]; then
        bad "expected exit 0, got $RC: $ERR"
    else
        printf '%s' "$OUT" >"$d/report.json"
        node -e '
          const fs = require("node:fs")
          const report = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
          const golden = fs.readFileSync(process.argv[2], "utf8")
          const problems = []
          if (!report.policy.present) {
            problems.push(`policy not parsed: ${report.policy.reason}`)
          } else {
            if (report.policy.rigor.level !== "standard") problems.push("rigor.level")
            if (report.policy.rigor.source !== "default_rigor") problems.push("rigor.source")
            const want = { challenge: 3, review: 3, integration: 4, remediation: 4, min_rounds: 1 }
            for (const key of Object.keys(want)) {
              if (report.policy.rounds[key] !== want[key]) problems.push("rounds." + key)
            }
            const bullets = golden.split("\n").filter((l) => l.startsWith("- ")).map((l) => l.slice(2))
            if (JSON.stringify(report.policy.disclosures) !== JSON.stringify(bullets)) problems.push("disclosures")
          }
          if (problems.length > 0) { console.error(problems.join(", ")); process.exit(1) }
        ' "$d/report.json" "$GOLDEN" &&
            ok "the golden rigor line and its disclosure bullets round-trip" ||
            bad "the renderer's golden policy-disclosure no longer parses"
    fi
fi

# ---------------------------------------------------------------------------

echo ""
echo "retro-run-report: $pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
