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
# All three return 0 UNCONDITIONALLY. Every assertion here is spelled
# `cond && ok "..." || bad "..."`, so the reporter's own exit status is part
# of that branch: if `echo` ever fails — a transient write error on the
# grouped-output pipe `task` runs these under — a passing assertion silently
# becomes a reported failure. Seen exactly once in a `task verify` run whose
# other two assertions over the same output passed, which is what makes the
# diagnosis certain rather than speculative. The counters must not lie about
# the code under test because of a pipe.
ok() {
    pass=$((pass + 1))
    echo "  ✓ $*" || true
    return 0
}
bad() {
    fail=$((fail + 1))
    echo "  ✗ $*" >&2 || true
    return 0
}
skipped() {
    skip=$((skip + 1))
    echo "  ↷ $*" || true
    return 0
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

evidence_marker_file() {
    local json_round="$5"
    [ "$json_round" = - ] && json_round=null
    printf '<!-- dev-flow-v2-evidence: {"run_id":"%s","stage":"%s","round":%s,"sequence":1,"destination":"%s"} -->\n## %s round %s\n' \
        "$2" "$3" "$json_round" "$4" "$3" "$5" >"$1"
}

# make_gh DIR — a `gh` shim in DIR/bin, reading canned answers from
# $GH_PR_JSON / $GH_COMMENTS_DIR and its actor id from $GH_USER_ID, appending
# each invocation to $GH_LOG.
make_gh() {
    mkdir -p "$1/bin"
    cat >"$1/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -euo pipefail
issue_failure_status() {
    if [ "${GH_FAIL_ISSUE:-}" = "$1" ]; then
        printf '%s\n' "${GH_FAIL_ISSUE_STATUS:-404}"
    elif [ "${GH_FAIL_ISSUE_2:-}" = "$1" ]; then
        printf '%s\n' "${GH_FAIL_ISSUE_STATUS_2:-404}"
    else
        return 1
    fi
}
printf '%s\n' "$*" >>"${GH_LOG:-/dev/null}"
case "${1:-}" in
pr)
    cat "$GH_PR_JSON"
    ;;
api)
    case "$*" in
    */issues/*/comments*)
        n="$(printf '%s\n' "$*" | sed -n 's|.*/issues/\([0-9]*\)/comments.*|\1|p')"
        if status="$(issue_failure_status "$n")"; then
            if [ "$status" = "timeout" ]; then
                echo "gh stub: request timed out reading issue $n" >&2
            else
                echo "gh stub: HTTP $status reading issue $n" >&2
            fi
            exit 1
        fi
        file="${GH_COMMENTS_DIR:-/nonexistent}/$n.json"
        if [ -f "$file" ]; then cat "$file"; else echo '[[]]'; fi
        ;;
    */issues/*)
        n="$(printf '%s\n' "$*" | sed -n 's|.*/issues/\([0-9]*\).*$|\1|p')"
        if status="$(issue_failure_status "$n")"; then
            if [ "$status" = "timeout" ]; then
                echo "gh stub: request timed out reading issue $n" >&2
            else
                echo "gh stub: HTTP $status reading issue $n" >&2
            fi
            exit 1
        fi
        if [ "${GH_PULL_REQUEST_ISSUE:-}" = "$n" ]; then
            printf '{"number":%s,"pull_request":{}}\n' "$n"
        else
            printf '{"number":%s}\n' "$n"
        fi
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
# supplied by $ROUNDS_JSON / $CLASSES_JSON / $ORPHANS_JSON /
# $SLOT_FAILURES_JSON / $ISSUE_NUMBER.
make_trajectory() {
    # One-shot overrides. A `VAR=x helper` prefix on a shell FUNCTION persists
    # in bash (unlike on an external command), so without this each override
    # would silently configure every later call too — and a case could then
    # pass for a reason its own setup never established. Captured, then
    # cleared, so the prefix means what it looks like it means.
    local issue="${ISSUE_NUMBER:-0}" rounds="${ROUNDS_JSON:-[]}" classes="${CLASSES_JSON:-{\}}"
    local orphans="${ORPHANS_JSON:-[]}" forged="${FORGED_JSON:-[]}" slot_failures="${SLOT_FAILURES_JSON:-[]}"
    local future_adjudications="${FUTURE_ADJUDICATIONS_JSON:-[]}"
    local run_id="${RUN_ID_OVERRIDE:-}"
    unset ISSUE_NUMBER ROUNDS_JSON CLASSES_JSON ORPHANS_JSON FORGED_JSON SLOT_FAILURES_JSON FUTURE_ADJUDICATIONS_JSON RUN_ID_OVERRIDE
    ISSUE_NUMBER="$issue" ROUNDS_JSON="$rounds" CLASSES_JSON="$classes" RUN_ID_OVERRIDE="$run_id" \
        ORPHANS_JSON="$orphans" FORGED_JSON="$forged" SLOT_FAILURES_JSON="$slot_failures" \
        FUTURE_ADJUDICATIONS_JSON="$future_adjudications" node -e '
      const fs = require("node:fs")
      const [fixture, out] = process.argv.slice(1)
      const run = JSON.parse(fs.readFileSync(fixture, "utf8"))
      const trajectory = {
        run_id: process.env.RUN_ID_OVERRIDE || run.run_id,
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
        slot_failures: JSON.parse(process.env.SLOT_FAILURES_JSON || "[]"),
        future_adjudication_files: JSON.parse(process.env.FUTURE_ADJUDICATIONS_JSON || "[]"),
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
    grep -qF -- "$2" <<<"$1"
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

echo "==> a Refs-only PR discovers trusted evidence on the non-closing issue"
d="$TMPROOT/nonclosing-refs"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "- Refs #$ISSUE"
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
marker_file "$d/i1" run-index run-6001-further-along kickoff issue -
set_comments "$d/comments" "$ISSUE" "$d/i1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && contains "$OUT" 'run `run-6001-further-along`' &&
    ok "the non-closing reference selects the trusted issue marker" ||
    bad "expected Refs-only discovery, got $RC: $ERR"
contains "$OUT" "evidence marker on issue #$ISSUE (non-closing reference)" &&
    ok "the source names the non-closing tier" || bad "the source hides the selected discovery tier"

echo "==> an unreadable non-closing hint is disclosed without hiding a valid peer"
d="$TMPROOT/nonclosing-unreadable"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" $'Refs #999999\nRefs #664'
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
marker_file "$d/i1" run-index run-6001-further-along kickoff issue -
set_comments "$d/comments" "$ISSUE" "$d/i1"
GH_FAIL_ISSUE=999999 GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && contains "$OUT" 'run `run-6001-further-along`' &&
    ok "the readable peer still selects the run" || bad "an unreadable hint denied discovery: $ERR"
contains "$OUT" "issue #999999 (non-closing reference):" &&
    contains "$OUT" "HTTP 404 reading issue 999999" &&
    ok "the report discloses the ignored hint and fetch failure" ||
    bad "the report hid the unreadable hint"

echo "==> a transient non-closing lookup failure is indeterminate"
d="$TMPROOT/nonclosing-transient"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" "Refs #999998"
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
GH_FAIL_ISSUE=999998 GH_FAIL_ISSUE_STATUS=503 GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && contains "$ERR" "indeterminate" && contains "$ERR" "HTTP 503" &&
    ok "the transient failure cannot become absent evidence" ||
    bad "a transient hint failure was ignored, got $RC: $ERR"

echo "==> durable ignored hints remain disclosed before a later transient failure"
d="$TMPROOT/nonclosing-durable-then-transient"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" $'Refs #999999\nRefs #999998'
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
GH_FAIL_ISSUE=999999 GH_FAIL_ISSUE_STATUS=404 \
    GH_FAIL_ISSUE_2=999998 GH_FAIL_ISSUE_STATUS_2=503 \
    GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && contains "$ERR" "indeterminate" && contains "$ERR" "HTTP 503" &&
    contains "$ERR" "ignoring body discovery hint issue #999999" && contains "$ERR" "HTTP 404" &&
    ok "the indeterminate path preserves the earlier durable-hint disclosure" ||
    bad "the later transient failure dropped an earlier ignored hint, got $RC: $ERR"

echo "==> a same-repository qualified reference is accepted case-insensitively"
d="$TMPROOT/qualified-refs"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "aDdReSsEs O/R#$ISSUE"
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
marker_file "$d/i1" run-index run-6001-further-along kickoff issue -
set_comments "$d/comments" "$ISSUE" "$d/i1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "the qualified same-repository reference is discovered" ||
    bad "expected qualified discovery, got $RC: $ERR"

echo "==> a same-repository full issue URL is accepted"
d="$TMPROOT/full-url-issue"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "Refs https://github.com/O/R/issues/$ISSUE"
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
marker_file "$d/i1" run-index run-6001-further-along kickoff issue -
set_comments "$d/comments" "$ISSUE" "$d/i1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && contains "$OUT" "evidence marker on issue #$ISSUE (non-closing reference)" &&
    ok "the full issue URL discovers same-repository evidence" ||
    bad "expected full-URL issue discovery, got $RC: $ERR"

echo "==> a same-repository full pull URL is disclosed and ignored"
d="$TMPROOT/full-url-pull"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" "Refs https://github.com/o/r/pull/$ISSUE"
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
GH_LOG="$d/gh.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] && contains "$ERR" "is a pull request, not an issue" &&
    ok "the full pull URL is disclosed as a PR hint" ||
    bad "full pull URL evidence selected a run, got $RC: $ERR"
contains "$(cat "$d/gh.log")" "repos/o/r/issues/$ISSUE" &&
    bad "the full pull URL caused a network lookup" || ok "the full pull URL caused no network lookup"

echo "==> a foreign-repository full URL is disclosed and never consulted"
d="$TMPROOT/full-url-foreign"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" "Refs https://github.com/other/project/issues/$ISSUE"
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
GH_LOG="$d/gh.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] && contains "$ERR" "https://github.com/other/project/issues/$ISSUE" &&
    contains "$ERR" "cross-repository reference does not belong to o/r" &&
    ok "the foreign full URL is disclosed and ignored" ||
    bad "expected foreign full-URL refusal, got $RC: $ERR"
contains "$(cat "$d/gh.log")" "repos/o/r/issues/$ISSUE" &&
    bad "the foreign full URL was queried in the target repository" ||
    ok "the foreign full URL was not queried"

echo "==> a qualified cross-repository reference is never consulted"
d="$TMPROOT/cross-repo-refs"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" "Refs other/project#$ISSUE"
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
marker_file "$d/i1" run-index run-6001-further-along kickoff issue -
set_comments "$d/comments" "$ISSUE" "$d/i1"
GH_LOG="$d/gh.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] && ok "the cross-repository reference cannot select a run" ||
    bad "expected cross-repository refusal, got $RC: $ERR"
contains "$(cat "$d/gh.log")" "repos/o/r/issues/$ISSUE/comments" &&
    bad "the cross-repository issue was queried in the target repository" ||
    ok "the cross-repository issue was not queried"
contains "$ERR" "cross-repository reference does not belong to o/r" &&
    ok "the ignored cross-repository hint is disclosed" || bad "the cross-repository hint was dropped silently"

echo "==> only line-anchored declarations create reference hints"
for example in 'quoted line' 'mid-line prose'; do
    d="$TMPROOT/declaration-${example// /-}"
    mkdir -p "$d"
    make_gh "$d"
    make_stats "$d/stats.mjs" 0
    case "$example" in
    'quoted line') write_file "$d/body" '> Refs #664' ;;
    'mid-line prose') write_file "$d/body" 'Historical example: Refs #664' ;;
    esac
    write_file "$d/c1" "no marker"
    make_pr_json "$d/pr.json" "$d/body"
    set_comments "$d/comments" "$PR" "$d/c1"
    marker_file "$d/i1" run-index run-6001-further-along kickoff issue -
    set_comments "$d/comments" "$ISSUE" "$d/i1"
    GH_LOG="$d/gh.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
        run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
    [ "$RC" -eq 10 ] && ok "$example does not create a discovery hint" ||
        bad "$example selected a run, got $RC: $ERR"
    contains "$(cat "$d/gh.log")" "repos/o/r/issues/$ISSUE/comments" &&
        bad "$example caused an issue lookup" || ok "$example issue was not queried"
done

echo "==> plus and ordered list markers qualify declaration lines"
for list_marker in '+' '1.'; do
    d="$TMPROOT/declaration-list-${list_marker//./dot}"
    mkdir -p "$d"
    make_gh "$d"
    ISSUE_NUMBER="$ISSUE" make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
    make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
    write_file "$d/body" "$list_marker Refs #$ISSUE"
    write_file "$d/c1" "no marker"
    make_pr_json "$d/pr.json" "$d/body"
    set_comments "$d/comments" "$PR" "$d/c1"
    marker_file "$d/i1" run-index run-6001-further-along kickoff issue -
    set_comments "$d/comments" "$ISSUE" "$d/i1"
    GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
        run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
    [ "$RC" -eq 0 ] && contains "$OUT" "evidence marker on issue #$ISSUE (non-closing reference)" &&
        ok "$list_marker list declaration is discovered" ||
        bad "$list_marker list declaration was ignored, got $RC: $ERR"
done

echo "==> a referenced pull request is disclosed and never read as issue evidence"
d="$TMPROOT/nonclosing-pr-number"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" "Refs #$ISSUE"
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
marker_file "$d/i1" evidence run-other-pr challenge pr -
set_comments "$d/comments" "$ISSUE" "$d/i1"
GH_PULL_REQUEST_ISSUE="$ISSUE" GH_LOG="$d/gh.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] && contains "$ERR" "is a pull request, not an issue" &&
    ok "the PR-number hint is disclosed and ignored" || bad "PR evidence selected a run, got $RC: $ERR"
contains "$(cat "$d/gh.log")" "repos/o/r/issues/$ISSUE/comments" &&
    bad "the referenced PR's comments were read" || ok "the referenced PR's comments were not read"

echo "==> body discovery accepts 10 unique hints and refuses 11 without truncating"
for count in 10 11; do
    d="$TMPROOT/hint-limit-$count"
    mkdir -p "$d"
    make_gh "$d"
    make_stats "$d/stats.mjs" 0
    : >"$d/body"
    i=1
    while [ "$i" -le "$count" ]; do
        printf 'Refs #%s\n' "$((7000 + i))" >>"$d/body"
        i=$((i + 1))
    done
    write_file "$d/c1" "no marker"
    make_pr_json "$d/pr.json" "$d/body"
    set_comments "$d/comments" "$PR" "$d/c1"
    GH_LOG="$d/gh.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
        run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
    if [ "$count" -eq 10 ]; then
        [ "$RC" -eq 10 ] && ok "10 unique hints remain within the bound" ||
            bad "the boundary count was refused, got $RC: $ERR"
    else
        [ "$RC" -eq 11 ] && contains "$ERR" "11 unique" && contains "$ERR" "--run <run_id>" &&
            ok "11 unique hints are refused with the explicit remedy" ||
            bad "the over-limit body was truncated or misreported, got $RC: $ERR"
        contains "$(cat "$d/gh.log")" "repos/o/r/issues/7001/comments" &&
            bad "an over-limit body performed a hint lookup" || ok "the over-limit body was refused before lookups"
    fi
done

echo "==> a body run-id token binds only through its issue's exact trusted marker"
d="$TMPROOT/body-run-token"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "Run identity: run-6001-further-along"
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
marker_file "$d/i1" run-index run-6001-further-along kickoff issue -
set_comments "$d/comments" 6001 "$d/i1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && contains "$OUT" 'run `run-6001-further-along`' &&
    ok "the exact trusted issue marker authenticates the body token" ||
    bad "expected authenticated body-token discovery, got $RC: $ERR"
contains "$OUT" "evidence marker on issue #6001 (PR-body run-id token)" &&
    ok "the source names the body-token tier" || bad "the source hides body-token authentication"

echo "==> a body token cannot borrow a different run marker from the named issue"
d="$TMPROOT/body-run-token-mismatch"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" "Run identity: run-6001-further-along"
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
marker_file "$d/i1" run-index run-6001-something-else kickoff issue -
set_comments "$d/comments" 6001 "$d/i1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && contains "$ERR" "run-6001-further-along vs run-6001-something-else" &&
    ok "mismatched trusted evidence is indeterminate rather than absent" ||
    bad "a mismatched issue marker did not raise an integrity error, got $RC: $ERR"

echo "==> a contributor-controlled body run-id token never binds by itself"
d="$TMPROOT/unverified-body-run-token"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" "Run identity: run-6001-further-along"
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] && contains "$ERR" "run-6001-further-along had no matching trusted marker" &&
    ok "the unverified token is refused with an explicit reason" ||
    bad "expected an unauthenticated-token fallback, got $RC: $ERR"

echo "==> a valid PR marker does not query a nonexistent lower-tier token hint"
d="$TMPROOT/pr-marker-skips-body-hint"
scaffold "$d" further-along "Run: run-999999-example"
GH_FAIL_ISSUE=999999 GH_LOG="$d/gh.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && contains "$OUT" "evidence marker on PR #$PR" &&
    ok "the trusted PR marker remains authoritative" || bad "the lower hint denied PR discovery: $ERR"
contains "$(cat "$d/gh.log")" "repos/o/r/issues/999999/comments" &&
    bad "the nonexistent lower-tier hint was queried" || ok "the lower-tier hint was not queried"

echo "==> closing-reference evidence keeps precedence over non-closing evidence"
d="$TMPROOT/closing-precedence"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "Refs #665"
write_file "$d/c1" "no marker"
CLOSING="[{\"number\":$ISSUE}]" make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
marker_file "$d/i1" run-index run-6001-further-along kickoff issue -
marker_file "$d/i2" run-index run-a-lower-tier kickoff issue -
set_comments "$d/comments" "$ISSUE" "$d/i1"
set_comments "$d/comments" 665 "$d/i2"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && contains "$OUT" "evidence marker on issue #$ISSUE (closing reference)" &&
    ok "the closing-reference tier wins" || bad "a lower discovery tier overrode closing evidence: $ERR"

echo "==> a token-encoded closing issue is fetched and reported only once"
d="$TMPROOT/closing-token-reuse"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" "Run: run-$ISSUE-example"
write_file "$d/c1" "no marker"
CLOSING="[{\"number\":$ISSUE}]" make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
marker_file "$d/i1" run-index run-other kickoff issue -
COMMENT_ACTOR=777 set_comments "$d/comments" "$ISSUE" "$d/i1"
GH_LOG="$d/gh.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] &&
    [ "$(printf '%s\n' "$ERR" | grep -c "ignoring an untrusted evidence marker naming run run-other on issue #$ISSUE")" -eq 1 ] &&
    [ "$(printf '%s\n' "$(cat "$d/gh.log")" | grep -c "repos/o/r/issues/$ISSUE/comments")" -eq 1 ] &&
    ok "closing results authenticate token hints without a second fetch or anomaly" ||
    bad "the closing/token issue was fetched or reported more than once, got $RC: $ERR"

echo "==> two non-closing issues naming different runs are indeterminate"
d="$TMPROOT/ambiguous-nonclosing"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" $'Refs #664\nPart of #665'
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
marker_file "$d/i1" run-index run-one kickoff issue -
marker_file "$d/i2" run-index run-two kickoff issue -
set_comments "$d/comments" 664 "$d/i1"
set_comments "$d/comments" 665 "$d/i2"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && contains "$ERR" "run-one, run-two" &&
    ok "the selected non-closing tier refuses ambiguity" ||
    bad "expected non-closing ambiguity, got $RC: $ERR"

echo "==> selected-tier ambiguity preserves earlier discovery disclosures"
d="$TMPROOT/ambiguous-nonclosing-disclosure"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" $'Refs #999999\nRefs #664\nRefs #665'
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
marker_file "$d/i1" run-index run-one kickoff issue -
marker_file "$d/i2" run-index run-two kickoff issue -
set_comments "$d/comments" 664 "$d/i1"
set_comments "$d/comments" 665 "$d/i2"
GH_FAIL_ISSUE=999999 GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && contains "$ERR" "run-one, run-two" &&
    contains "$ERR" "ignoring body discovery hint issue #999999" && contains "$ERR" "HTTP 404" &&
    ok "ambiguity retains the accumulated ignored-hint disclosure" ||
    bad "selected-tier ambiguity dropped discovery context, got $RC: $ERR"

echo "==> every reference on one declaration line participates in ambiguity"
d="$TMPROOT/ambiguous-nonclosing-one-line"
mkdir -p "$d"
make_gh "$d"
make_stats "$d/stats.mjs" 0
write_file "$d/body" 'Refs #664, Refs #665'
write_file "$d/c1" "no marker"
make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
marker_file "$d/i1" run-index run-one kickoff issue -
marker_file "$d/i2" run-index run-two kickoff issue -
set_comments "$d/comments" 664 "$d/i1"
set_comments "$d/comments" 665 "$d/i2"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && contains "$ERR" "run-one, run-two" &&
    ok "same-line references reach the selected-tier ambiguity guard" ||
    bad "same-line references silently selected one run, got $RC: $ERR"

echo "==> body run tokens preserve dot, underscore, and uppercase suffixes"
for run_id in run-6001-feature.v2 run-6001-feature_name run-6001-UPPER; do
    d="$TMPROOT/token-domain-${run_id##*-}"
    mkdir -p "$d"
    make_gh "$d"
    RUN_ID_OVERRIDE="$run_id" ISSUE_NUMBER=6001 \
        make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
    make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
    write_file "$d/body" "Run: $run_id"
    write_file "$d/c1" "no marker"
    make_pr_json "$d/pr.json" "$d/body"
    set_comments "$d/comments" "$PR" "$d/c1"
    marker_file "$d/i1" run-index "$run_id" kickoff issue -
    set_comments "$d/comments" 6001 "$d/i1"
    GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
        run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
    [ "$RC" -eq 0 ] && contains "$OUT" "run \`$run_id\`" &&
        ok "$run_id is compared as one exact token" || bad "$run_id was narrowed, got $RC: $ERR"
done

echo "==> body run tokens stop before semicolon and comma punctuation"
for punctuation in ';' ','; do
    d="$TMPROOT/token-punctuation-${punctuation//;/semicolon}"
    mkdir -p "$d"
    make_gh "$d"
    RUN_ID_OVERRIDE=run-6001-feature ISSUE_NUMBER=6001 \
        make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
    make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
    write_file "$d/body" "Run: run-6001-feature$punctuation"
    write_file "$d/c1" "no marker"
    make_pr_json "$d/pr.json" "$d/body"
    set_comments "$d/comments" "$PR" "$d/c1"
    marker_file "$d/i1" run-index run-6001-feature kickoff issue -
    set_comments "$d/comments" 6001 "$d/i1"
    GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" GH_USER_ID="$ACTOR" \
        run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
    [ "$RC" -eq 0 ] && contains "$OUT" 'run `run-6001-feature`' &&
        ok "the run token stops before $punctuation" ||
        bad "the run token swallowed $punctuation, got $RC: $ERR"
done

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

echo "==> explicit --run tolerates a >1 MiB gh response"
d="$TMPROOT/large-gh-buffer"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" make_trajectory "$FIXTURES/remediation-loop.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
POLICY_SECTION="$POLICY_SECTION" node -e '
  const fs = require("node:fs")
  fs.writeFileSync(process.argv[1], process.env.POLICY_SECTION + "\n" + "x".repeat(2 * 1024 * 1024))
' "$d/body"
make_pr_json "$d/pr.json" "$d/body"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --run run-6058-remediation-loop --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && contains "$OUT" 'run `run-6058-remediation-loop`' &&
    ok "the 64 MiB subprocess buffer carries the large gh payload" ||
    bad "expected a successful large-output report, got $RC: $ERR"

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
      {"stage":"challenge","round":1,"pass_count":1,"adjudication_count":1,"finding_count":3,"has_adjudication":true},
      {"stage":"challenge","round":2,"pass_count":1,"adjudication_count":1,"finding_count":1,"has_adjudication":true},
      {"stage":"review","round":1,"pass_count":1,"adjudication_count":0,"finding_count":0,"has_adjudication":false}
    ]' \
    SLOT_FAILURES_JSON='[{"stage":"review","round":1,"slot":"codex-verification","reason":"finder_unavailable"}]' \
    FUTURE_ADJUDICATIONS_JSON='["review-r2.json"]' \
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
contains "$OUT" "- Rounds/passes/findings: not measured from local evidence (cap 4 (disclosed, unverified)) — integration passes carry no authenticated evidence marker today." &&
    ok "the integration stage discloses its cap without a fabricated zero round count" ||
    bad "the integration stage printed a round-count line instead of the not-measured disclosure"
contains "$OUT" "- Rounds with no adjudication record: 1" &&
    ok "a round with no adjudication is named" || bad "unadjudicated round not reported"
contains "$OUT" "- Round 1 evidence: 1 pass(es), 0 blocked pass(es), 1 adjudication(s)" &&
    ok "per-round pass and adjudication counts are disclosed" || bad "per-round evidence counts missing"
contains "$OUT" 'Slot failures (retained verbatim): `[{"stage":"review","round":1,"slot":"codex-verification","reason":"finder_unavailable"}]`' &&
    ok "slot failures are retained verbatim" || bad "slot failures were dropped or rewritten"
contains "$OUT" 'Future adjudications excluded by --as-of: `review-r2.json`' &&
    ok "future adjudications are disclosed in their stage" || bad "future adjudications were dropped"
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
    bad "a gap was declared for a measurement this run actually rendered per stage" ||
    ok "no per-stage gap is claimed when the breakdown was attributed to a stage"
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
grep -qE -- '--trusted-actor-id|--trusted-actors-file' < <(grep -A 3 'assets/retro-run-report.mjs --repo' ai/skills/universal/retro/SKILL.md) &&
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
contains "$OUT" "keyed by stage" &&
    ok "the per-stage gap IS declared when no split is derivable" ||
    bad "a genuine per-stage gap went unreported"

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
grep -q 'Do not write "there was no run record"' < <(grep -A 6 'Exit 10, `run-not-found`' ai/skills/universal/retro/SKILL.md) &&
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
contains "$OUT" "run-6001-further-along" &&
    bad "devflow:example selected a run" || ok "a non-canonical kind never names a run"
contains "$ERR" 'kind "example" is not run-index, run-record or evidence' &&
    ok "the malformed marker is reported with its reason" || bad "the malformed marker was dropped silently"

echo "==> a canonical kind missing required fields is malformed, not evidence"
d="$TMPROOT/fields"
scaffold "$d" further-along "body"
printf '<!-- devflow:evidence v2 run_id=run-6001-further-along seq=1 -->\n' >"$d/short"
set_comments "$d/comments" "$PR" "$d/short"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && contains "$ERR" "missing required marker field stage" &&
    ok "a marker without stage/dest/round is refused by name" ||
    bad "an incomplete marker participated in discovery, got $RC: $ERR"
printf '<!-- devflow:evidence v2 run_id=r stage=nonsense dest=pr round=- seq=1 -->\n' >"$d/badstage"
set_comments "$d/comments" "$PR" "$d/badstage"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && contains "$ERR" 'stage "nonsense" is not a run stage' &&
    ok "a marker with an unknown stage is refused by name" || bad "got $RC: $ERR"

echo "==> a TRUSTED actor's malformed marker is corrupted evidence, not absence"
d="$TMPROOT/malformed-trusted"
scaffold "$d" further-along "body"
marker_file "$d/bogus" example some-run challenge pr -
set_comments "$d/comments" "$PR" "$d/bogus"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] &&
    ok "a trusted actor's unparseable marker is indeterminate, never 'no run record'" ||
    bad "a trusted actor's corrupted evidence read as absence, got $RC"
contains "$ERR" "corrupted evidence rather than absence" &&
    ok "the reason says why it is not absence" || bad "the corrupted-evidence reasoning is missing"

echo "==> an UNTRUSTED author's malformed marker is still noise"
d="$TMPROOT/malformed-untrusted"
scaffold "$d" further-along "body"
marker_file "$d/bogus" example some-run challenge pr -
COMMENT_ACTOR=888888 set_comments "$d/comments" "$PR" "$d/bogus"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] &&
    ok "noise from an untrusted author stays exit 10" ||
    bad "an untrusted author's malformed marker was treated as corrupted evidence, got $RC"
contains "$ERR" "from an untrusted author" &&
    ok "the report distinguishes whose malformed marker it was" ||
    bad "the malformed-marker report does not name the author's trust"

echo "==> --run with no --pr reads the disclosure off the run's OWN bound PR"
d="$TMPROOT/runonly-policy"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" \
    ROUNDS_JSON='[{"stage":"challenge","round":1,"pass_count":1,"finding_count":1,"has_adjudication":true}]' \
    make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "$POLICY_SECTION"
make_pr_json "$d/pr.json" "$d/body"
GH_LOG="$d/gh.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --run run-6001-further-along --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "exit 0" || bad "expected exit 0, got $RC: $ERR"
contains "$OUT" "- Rounds spent: 1 / cap 3 (disclosed, unverified)" &&
    ok "a --run-only report still measures rounds against the disclosed cap" ||
    bad "a --run-only report lost its rounds-versus-cap measurement"
contains "$OUT" "PR binding: bound to PR #$PR" &&
    ok "the binding comes from the run record itself" || bad "the record's own PR binding was not used"
contains "$(cat "$d/gh.log")" "pr view $PR" &&
    ok "the run's own PR was fetched for its disclosure" || bad "the bound PR was never fetched"

echo "==> a --run-only report survives an unreadable bound PR"
d="$TMPROOT/runonly-prfail"
mkdir -p "$d/bin"
cat >"$d/bin/gh" <<'FAILGH'
#!/usr/bin/env bash
case "${1:-}" in
pr) echo "gh stub: PR unreadable" >&2; exit 1 ;;
*) echo '[[]]' ;;
esac
FAILGH
chmod +x "$d/bin/gh"
ISSUE_NUMBER="$ISSUE" make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
run_report "$d" --repo o/r --run run-6001-further-along --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && ok "an unreadable bound PR degrades rather than failing the report" ||
    bad "expected exit 0, got $RC: $ERR"
contains "$OUT" "Caps unknown" &&
    ok "the caps fall back to unknown" || bad "the caps were not reported unknown"
contains "$ERR" "could not read PR #$PR for its policy disclosure" &&
    ok "the degradation is stated, not silent" || bad "the failed PR read was silent"

echo "==> linked issues are scanned for anomalies even when the PR names the run"
d="$TMPROOT/scanboth"
mkdir -p "$d"
make_gh "$d"
ISSUE_NUMBER="$ISSUE" \
    ROUNDS_JSON='[{"stage":"challenge","round":1,"pass_count":1,"finding_count":0,"has_adjudication":true}]' \
    make_trajectory "$FIXTURES/further-along.json" "$d/trajectory.json"
make_stats "$d/stats.mjs" 0 "$d/trajectory.json"
write_file "$d/body" "body"
marker_file "$d/c1" evidence run-6001-further-along challenge pr -
marker_file "$d/i1" evidence run-a-redirect challenge issue 1
CLOSING="[{\"number\":$ISSUE}]" make_pr_json "$d/pr.json" "$d/body"
set_comments "$d/comments" "$PR" "$d/c1"
COMMENT_ACTOR=777777 set_comments "$d/comments" "$ISSUE" "$d/i1"
GH_LOG="$d/gh.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && contains "$OUT" 'run `run-6001-further-along`' &&
    ok "the PR's own run is still the one selected" || bad "expected the PR run, got $RC: $ERR"
contains "$(cat "$d/gh.log")" "repos/o/r/issues/$ISSUE/comments" &&
    ok "the linked issue was scanned despite the PR already naming a run" ||
    bad "the linked issue was skipped, so its anomalies went unseen"
contains "$OUT" "Untrusted evidence markers ignored during discovery: 1" &&
    ok "the redirect marker on the linked issue reaches the integrity count" ||
    bad "an anomaly on the authoritative issue was invisible"
contains "$OUT" "run-a-redirect" &&
    ok "the ignored marker names the run it tried to redirect to" ||
    bad "the ignored marker is unidentified"

echo "==> the skill separates the two exit-10 fallbacks and gates issue filing"
grep -q '| 10 · `no-run-record` |' ai/skills/universal/retro/SKILL.md &&
    ok "no-run-record has its own exit-table row" || bad "the exit-10 row still conflates two cases"
grep -q '| 10 · `run-not-found` |' ai/skills/universal/retro/SKILL.md &&
    ok "run-not-found has its own exit-table row" || bad "run-not-found has no row of its own"
grep -q 'do \*\*not\*\* say the session has no run record' < <(grep -A 1 '| 10 · `run-not-found` |' ai/skills/universal/retro/SKILL.md) &&
    ok "the run-not-found row forbids the unestablished absence claim" ||
    bad "the run-not-found row still permits claiming no run record"
grep -q 'do not create it unless asked' < <(grep -A 1 '| 11 | evidence exists' ai/skills/universal/retro/SKILL.md) &&
    ok "exit 11 drafts the follow-up rather than filing it unbidden" ||
    bad "exit 11 still orders an unrequested GitHub write"

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

echo "==> record-missing for an explicit --run remains authenticated and indeterminate"
d="$TMPROOT/record-missing-explicit"
scaffold "$d" further-along "body"
printf '%s\n' '{"status":"record-missing","run_id":"made-up"}' >"$d/record-missing.json"
make_stats "$d/stats.mjs" 1 "$d/record-missing.json"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --run made-up --record-dir "$d" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && contains "$ERR" "record-missing" && contains "$ERR" "Authenticated evidence exists" &&
    ok "exit 11 preserves structured record-missing" || bad "expected exit 11 / record-missing, got $RC: $ERR"

echo "==> a --run id containing the text 'record-missing' is not misclassified without a structured status"
d="$TMPROOT/notfound-explicit-collision"
scaffold "$d" further-along "body"
# Mirrors the real harvester's plain not-found message, which echoes the
# requested run id verbatim and emits no structured JSON status. The run id
# below contains the literal substring "record-missing" so a stderr-substring
# classifier (the pre-fix behavior) would misclassify this as record-missing
# and return exit 11 instead of the correct run-not-found fallback (exit 10).
cat >"$d/stats.mjs" <<'STATS_MJS'
#!/usr/bin/env node
process.stderr.write('dev-flow-stats: run "run-804-record-missing" not found (searched every issue run record in o/r)\n')
process.exitCode = 1
STATS_MJS
chmod +x "$d/stats.mjs"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --run run-804-record-missing --stats-script "$d/stats.mjs"
[ "$RC" -eq 10 ] && contains "$ERR" "run-not-found" &&
    ok "a stderr substring match on 'record-missing' no longer forces exit 11 without a structured status" ||
    bad "expected exit 10 / run-not-found (stderr-substring collision), got $RC: $ERR"

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

echo "==> --record-dir is passed through to the harvester unchanged"
d="$TMPROOT/record-dir-passthrough"
scaffold "$d" further-along "body"
mkdir -p "$d/records"
STATS_LOG="$d/stats.log" GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --record-dir "$d/records"
[ "$RC" -eq 0 ] && contains "$(cat "$d/stats.log")" "--record-dir $d/records" &&
    ok "the local record directory reaches the harvester" ||
    bad "--record-dir was not passed through unchanged: rc=$RC, log=$(cat "$d/stats.log"), err=$ERR"

echo "==> evidence-only harvester output is reported without fabricating a trajectory"
d="$TMPROOT/evidence-only"
scaffold "$d" further-along "body"
printf '%s\n' '{"status":"evidence-only","run_id":"run-6001-further-along","issue":6001,"marker_facts":[{"stage":"review","destination":"issue","round":1,"sequence":1}],"untrusted_marker_facts":[{"stage":"review","destination":"issue","round":2,"sequence":2}],"legacy_also_present":true}' >"$d/evidence-only.json"
make_stats "$d/stats.mjs" 0 "$d/evidence-only.json"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs" --json
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e --argjson pr "$PR" '.status == "evidence-only" and .marker_facts[0].stage == "review" and .untrusted_marker_facts[0].round == 2 and .legacy_also_present == true and .source.pr_binding == ("bound to PR #" + ($pr | tostring))' >/dev/null &&
    ok "the report preserves authenticated marker facts and stops before trajectory measurement" ||
    bad "evidence-only output was not preserved: rc=$RC, out=$OUT, err=$ERR"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && contains "$OUT" 'Untrusted marker facts' && contains "$OUT" '"round":2' && contains "$OUT" 'Legacy also present: `true`' && contains "$OUT" "PR binding: bound to PR #$PR" &&
    ok "the text report preserves untrusted marker anomaly facts" ||
    bad "evidence-only text output dropped untrusted marker facts: rc=$RC, out=$OUT, err=$ERR"

echo "==> an explicitly selected evidence-only run discloses that it is unbound"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --run run-6001-further-along --stats-script "$d/stats.mjs" --json
[ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.source.pr_binding | startswith("unbound")' >/dev/null &&
    ok "the absent evidence-only PR binding is disclosed" ||
    bad "an unbound evidence-only run claimed a binding: rc=$RC, out=$OUT, err=$ERR"

echo "==> evidence-only output rejects a retained binding to another PR"
jq --argjson pr "$((PR + 1))" '.pr_binding = {number:$pr}' "$d/evidence-only.json" >"$d/evidence-only-bound.json"
make_stats "$d/stats.mjs" 0 "$d/evidence-only-bound.json"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --run run-6001-further-along --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && contains "$ERR" "bound to PR #$((PR + 1)), not the requested #$PR" &&
    ok "the retained evidence-only PR binding is authoritative" ||
    bad "a differently-bound evidence-only run was accepted: rc=$RC, out=$OUT, err=$ERR"

echo "==> evidence-only Markdown folds a newline-bearing run id"
newline_run_id=$'run-6001\ninjected-heading'
jq --arg run "$newline_run_id" '.run_id = $run | del(.pr_binding)' "$d/evidence-only.json" >"$d/evidence-only-newline.json"
make_stats "$d/stats.mjs" 0 "$d/evidence-only-newline.json"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --run "$newline_run_id" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | sed -n '1p')" = '## Run evidence — run `run-6001 injected-heading`' ] &&
    ok "the evidence-only heading neutralizes embedded newlines" ||
    bad "a newline-bearing run id broke the Markdown heading: rc=$RC, out=$OUT, err=$ERR"

echo "==> discovery accepts the review skill's evidence-marker grammar"
d="$TMPROOT/evidence-marker-grammar"
scaffold "$d" further-along "body"
evidence_marker_file "$d/c1" run-6001-further-along challenge pr -
set_comments "$d/comments" "$PR" "$d/c1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 0 ] && contains "$OUT" 'run-6001-further-along' &&
    ok "the writer grammar selects the run" ||
    bad "the writer grammar was not discovered: rc=$RC, err=$ERR"

echo "==> discovery rejects marker destinations that disagree with the fetched endpoint"
d="$TMPROOT/evidence-marker-wrong-endpoint"
scaffold "$d" further-along "body"
evidence_marker_file "$d/c1" run-6001-further-along review issue 1
set_comments "$d/comments" "$PR" "$d/c1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && contains "$ERR" 'marker destination issue does not match PR' &&
    ok "a PR comment cannot claim an issue destination" ||
    bad "the PR endpoint mismatch was accepted or hidden: rc=$RC, err=$ERR"

write_file "$d/c1" "no marker"
marker_file "$d/i1" evidence run-6001-further-along integration pr -
set_comments "$d/comments" "$PR" "$d/c1"
set_comments "$d/comments" "$ISSUE" "$d/i1"
CLOSING="[{\"number\":$ISSUE}]" make_pr_json "$d/pr.json" "$d/body"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && contains "$ERR" 'marker destination pr does not match issue' &&
    ok "an issue comment cannot claim a PR destination" ||
    bad "the issue endpoint mismatch was accepted or hidden: rc=$RC, err=$ERR"

echo "==> current evidence markers reject trailing content and invalid destination/round pairs"
d="$TMPROOT/evidence-marker-strict"
scaffold "$d" further-along "body"
write_file "$d/c1" '<!-- dev-flow-v2-evidence: {"run_id":"run-6001-further-along","stage":"review","round":1,"sequence":1,"destination":"issue"} --> trailing'
set_comments "$d/comments" "$PR" "$d/c1"
GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
    run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
[ "$RC" -eq 11 ] && contains "$ERR" 'trailing content or an invalid payload' &&
    ok "trailing marker bytes are trusted malformed evidence" ||
    bad "trailing marker content was accepted or hidden: rc=$RC, err=$ERR"
for pair in 'issue null' 'pr 1'; do
    destination="${pair%% *}"
    round="${pair##* }"
    write_file "$d/c1" "<!-- dev-flow-v2-evidence: {\"run_id\":\"run-6001-further-along\",\"stage\":\"review\",\"round\":$round,\"sequence\":1,\"destination\":\"$destination\"} -->"
    set_comments "$d/comments" "$PR" "$d/c1"
    GH_PR_JSON="$d/pr.json" GH_COMMENTS_DIR="$d/comments" \
        run_report "$d" --repo o/r --pr "$PR" --stats-script "$d/stats.mjs"
    [ "$RC" -eq 11 ] && contains "$ERR" 'destination and round do not form' ||
        bad "invalid $destination/$round marker pair was accepted or hidden: rc=$RC, err=$ERR"
done
ok "both invalid destination/round combinations are rejected"

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
