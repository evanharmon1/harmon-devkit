#!/usr/bin/env bash
# test-dev-flow-stats.sh — behavioral test for scripts/dev-flow-stats.mjs:
# evidence harvesting, trust/digest verification, the closed-cohort success
# metric, per-run trajectory rendering, and policy replay. See
# ai/schemas/README.md "Evidence marker and digest grammar" for the contract
# this reads, and #663's own acceptance criteria for what this proves.
#
# gh is faked (never touches the network): a stub on $PATH reads a JSON
# "database" built by a node helper using this script's own exported
# digest/marker functions, so every fixture here is a genuinely valid (or
# deliberately invalid) instance of the real grammar, never hand-typed
# guesses at what a hash should look like.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "${repo}"

fail() {
    echo "TEST FAIL: $*" >&2
    exit 1
}

command -v node >/dev/null 2>&1 || fail "node is required"
[ -f scripts/dev-flow-stats.mjs ] || fail "missing required asset: scripts/dev-flow-stats.mjs"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin"
mkdir -p "$stub"

# ---------------------------------------------------------------------------
# Fake gh: reads $DFSTATS_DB (a JSON object {issues, comments, commits}) and
# answers exactly the endpoints scripts/dev-flow-stats.mjs calls. --paginate
# --slurp gets one page (this repo's fixtures are always small enough).
# ---------------------------------------------------------------------------
cat >"$stub/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
db="${DFSTATS_DB:?DFSTATS_DB must be set}"

if [ "${1:-}" != api ]; then
    echo "fake gh: unsupported subcommand: ${1:-}" >&2
    exit 1
fi
shift
# Drop --paginate/--slurp flags; find the endpoint (first non-flag arg).
endpoint=""
for a in "$@"; do
    case "$a" in
    --paginate | --slurp) ;;
    *) endpoint="$a"; break ;;
    esac
done

case "$endpoint" in
repos/*/issues\?state=all\&per_page=100)
    jq '[.issues]' "$db"
    ;;
repos/*/issues/*/comments\?per_page=100)
    n="$(echo "$endpoint" | sed -E 's#.*/issues/([0-9]+)/comments.*#\1#')"
    jq --arg n "$n" '[(.comments[$n] // [])]' "$db"
    ;;
repos/*/pulls/*/commits\?per_page=100)
    n="$(echo "$endpoint" | sed -E 's#.*/pulls/([0-9]+)/commits.*#\1#')"
    jq --arg n "$n" '[(.commits[$n] // [])]' "$db"
    ;;
*)
    echo "fake gh: unhandled endpoint: $endpoint" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$stub/gh"

export PATH="$stub:$PATH"

# ---------------------------------------------------------------------------
# Node fixture builder — shared helpers, then one function per scenario.
# Writes $tmp/scenarios/<name>.json, each a full {issues, comments, commits}
# database plus metadata the bash cases below read (trusted actor ids, run
# ids, expected outcomes).
# ---------------------------------------------------------------------------
mkdir -p "$tmp/scenarios"
cat >"$tmp/build-fixtures.mjs" <<NODE
import { writeFileSync, mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import {
  entryDigest, sha256, canonicalDigest, GENESIS,
} from "${repo}/scripts/dev-flow-stats.mjs";

const TRUSTED_ORCHESTRATOR = 9001;
const OTHER_TRUSTED = 9002;
const UNTRUSTED = 6666;

function chain(contents) {
  let prev = GENESIS;
  return contents.map((content, seq) => {
    const digest = entryDigest(content, prev);
    const e = { ...content, seq, digest, prev_digest: prev };
    prev = digest;
    return e;
  });
}

function marker(kind, runId, stage, dest, round, seq) {
  return \`<!-- devflow:\${kind} v2 run_id=\${runId} stage=\${stage} dest=\${dest} round=\${round === null ? "-" : round} seq=\${seq} -->\`;
}

function fence(text) {
  return "\`\`\`json\n" + text + "\n\`\`\`";
}

let nextCommentId = 1;
function comment(actorId, login, body, createdAt) {
  return { id: nextCommentId++, user: { id: actorId, login }, body, created_at: createdAt };
}

function runRecordComment(actorId, login, runId, body, createdAt) {
  const text = JSON.stringify(body);
  const m = marker("run-record", runId, "kickoff", "issue", null, 1);
  return comment(actorId, login, \`\${m}\n\${fence(text)}\`, createdAt);
}

function evidenceComment(actorId, login, runId, stage, dest, round, seq, payload, createdAt) {
  const text = JSON.stringify(payload);
  const m = marker("evidence", runId, stage, dest, round, seq);
  return comment(actorId, login, \`\${m}\n\${fence(text)}\`, createdAt);
}

function pass(finder, findings) {
  return {
    schema: 2, role: "reviewer", status: "completed", head: "0".repeat(40),
    produced_at: "2026-09-01T00:00:00Z", producer: finder,
    run: { run_id: "placeholder", initiated_by: "human" },
    payload: { finder, findings: findings.map((f, i) => ({ id: \`review-r1-\${finder}-\${i + 1}\`, class: "correctness", provenance: "original", severity: "P2", ...f })) },
  };
}

function writeScenario(name, db) {
  writeFileSync(path.join("${tmp}/scenarios", \`\${name}.json\`), JSON.stringify(db, null, 2));
}

// --- Scenario 1: happy path, one issue, one clean ready-for-review run ---
{
  const runId = "run-happy-1";
  const stageTransitions = chain([
    { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
    { stage: "claim", entered_at: "2026-09-01T00:01:00Z", exit: "implementing" },
    { stage: "implement", entered_at: "2026-09-01T00:02:00Z", exit: "reviewing" },
    { stage: "review", entered_at: "2026-09-01T00:03:00Z", exit: "integrating" },
    { stage: "integration", entered_at: "2026-09-01T00:10:00Z" },
  ]);
  const roundPayload = { passes: [pass("codex-cli", [])], adjudication: { schema: 2, run_id: runId, stage: "review", round: 1, adjudications: [] } };
  const ev = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, roundPayload, "2026-09-01T00:03:30Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: stageTransitions, interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 501, url: "https://example.invalid/pr/501" },
    // Populated for real, matching the one evidence comment actually
    // posted above — proves the happy path also satisfies the
    // evidence_comments[] cross-check (ai/schemas/README.md), not just the
    // vacuous "empty list" case every other scenario here uses.
    evidence_comments: [{
      id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator",
      digest: sha256(JSON.stringify(roundPayload)),
      marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 },
    }],
    promotion: { head: "1".repeat(40), promoted_at: "2026-09-01T00:15:00Z", gate_fingerprint: "abc" },
  };
  const rr = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("happy", {
    issues: [{ number: 101, pull_request: null }],
    comments: { "101": [rr, ev] },
    commits: { "501": [] },
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 101, evCommentId: ev.id },
  });
}

// --- Scenario 2: chain fork — two entries claim the same prev_digest ---
{
  const runId = "run-fork-1";
  const base = chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" }]);
  const forkA = { stage: "claim", entered_at: "2026-09-01T00:01:00Z", exit: "implementing" };
  const forkB = { stage: "explore", entered_at: "2026-09-01T00:01:05Z", exit: "planning" };
  const digestA = entryDigest(forkA, base[0].digest);
  const digestB = entryDigest(forkB, base[0].digest);
  const forked = [
    ...base,
    { ...forkA, seq: 1, digest: digestA, prev_digest: base[0].digest },
    { ...forkB, seq: 1, digest: digestB, prev_digest: base[0].digest },
  ];
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: forked, interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const rr = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("fork", {
    issues: [{ number: 102, pull_request: null }],
    comments: { "102": [rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 102 },
  });
}

// --- Scenario 3: untrusted author — plausible payload, wrong actor id ---
{
  const runId = "run-untrusted-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  // Posted by an actor NOT in the trusted set, even though the payload
  // itself looks completely legitimate (initiated_by: "human", well-formed
  // chain) — the trust check must reject on actor id alone.
  const rr = runRecordComment(UNTRUSTED, "impersonator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("untrusted-author", {
    issues: [{ number: 103, pull_request: null }],
    comments: { "103": [rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 103 },
  });
}

// --- Scenario 4: duplicate marker (same-writer resume), lowest id wins,
// stable under --as-of at any cutoff regardless of which duplicate a
// harvester happens to read first ---
{
  const runId = "run-dup-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" }, { stage: "claim", entered_at: "2026-09-01T00:01:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const rr = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  const payloadA = { passes: [pass("codex-cli", [{ title: "finding-from-first-post" }])], adjudication: null };
  const first = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, payloadA, "2026-09-01T00:02:00Z");
  // A resumed session re-posts the SAME event (same marker) — same content
  // this time (a genuine duplicate of the identical event, not a fork).
  const duplicate = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, payloadA, "2026-09-01T00:05:00Z");
  writeScenario("duplicate-marker", {
    issues: [{ number: 104, pull_request: null }],
    comments: { "104": [rr, first, duplicate] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 104, firstId: first.id, duplicateId: duplicate.id },
  });
}

// --- Scenario 5: split segments (oversized payload) ---
{
  const runId = "run-split-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const rr = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  const fullPayload = { passes: [pass("codex-cli", [{ title: "split-finding" }])], adjudication: null };
  const text = JSON.stringify(fullPayload);
  const mid = Math.floor(text.length / 2);
  const seg1text = text.slice(0, mid);
  const seg2text = text.slice(mid);
  const m1 = marker("evidence", runId, "challenge", "issue", 1, 1);
  const m2 = marker("evidence", runId, "challenge", "issue", 1, 2);
  const seg1 = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${m1}\n\${fence(seg1text)}\`, "2026-09-01T00:02:00Z");
  const seg2 = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${m2}\n\${fence(seg2text)}\`, "2026-09-01T00:02:01Z");
  writeScenario("split", {
    issues: [{ number: 105, pull_request: null }],
    comments: { "105": [rr, seg1, seg2] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 105 },
  });
}

// --- Scenario 6: digest tampering (edited comment body) ---
{
  const runId = "run-tamper-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "claim", entered_at: "2026-09-01T00:01:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const rr = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  // Tamper: change entered_at on the (already-embedded, already-digested)
  // second entry without recomputing the chain — this is what an EDIT to
  // the live comment (not a fresh re-post) looks like, since the outer
  // comment body changes but the entry's own recorded digest does not.
  rr.body = rr.body.replace("2026-09-01T00:01:00Z", "2099-01-01T00:00:00Z");
  writeScenario("tamper", {
    issues: [{ number: 106, pull_request: null }],
    comments: { "106": [rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 106 },
  });
}

// --- Scenario 7: stale non-terminal run terminalized as abandoned ---
{
  const runId = "run-stale-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-01-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-01-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const rr = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-01-01T00:00:00Z");
  writeScenario("stale", {
    issues: [{ number: 107, pull_request: null }],
    comments: { "107": [rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 107, asOf: "2026-09-01T00:00:00Z" },
  });
}

// --- Scenario 8: post-ready human fix ---
{
  const runId = "run-postfix-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T00:01:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 502, url: "https://example.invalid/pr/502" },
    evidence_comments: [],
    promotion: { head: "2".repeat(40), promoted_at: "2026-09-01T00:10:00Z", gate_fingerprint: "def" },
  };
  const rr = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  const humanCommit = { commit: { committer: { date: "2026-09-01T00:20:00Z" } }, author: { id: 42 } };
  writeScenario("postfix", {
    issues: [{ number: 108, pull_request: null }],
    comments: { "108": [rr] },
    commits: { "502": [humanCommit] },
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 108 },
  });
}

// --- Scenario 9: multiple issues combined, for --repo cohort math ---
{
  const dbs = ["happy", "postfix"].map((n) => JSON.parse(readFileSync(path.join("${tmp}/scenarios", \`\${n}.json\`), "utf8")));
  const combined = { issues: [], comments: {}, commits: {}, meta: { trustedActorIds: [TRUSTED_ORCHESTRATOR] } };
  for (const db of dbs) {
    combined.issues.push(...db.issues);
    Object.assign(combined.comments, db.comments);
    Object.assign(combined.commits, db.commits);
  }
  writeScenario("cohort", combined);
}

// --- Scenario 10: the real omator#397 trajectory (#663's own required
// fixture) — wraps the ALREADY-COMMITTED pass/adjudication JSON under
// ai/schemas/fixtures/{result.reviewer.schema,adjudication.schema}/valid/
// as evidence comments, rather than inventing new data. 4 challenge + 3
// review rounds, both stages capped (specs/dev-flow-v2.md's own account of
// this trajectory). Used for --run trajectory rendering and --replay.
{
  const runId = "omator-397";
  const head = "7ce1103d9bd263637eeec8d77325ed1356e8ff93";
  const rounds = [
    ["challenge", 1], ["challenge", 2], ["challenge", 3], ["challenge", 4],
    ["review", 1], ["review", 2], ["review", 3],
  ];
  const fixtureRoot = "${repo}/ai/schemas/fixtures";
  const comments = [];
  let t = 0;
  const at = () => \`2026-07-10T\${String(9 + t++).padStart(2, "0")}:00:00Z\`;

  const stageTransitions = chain([
    { stage: "kickoff", entered_at: at(), exit: "claimed" },
    { stage: "claim", entered_at: at(), exit: "implementing" },
    { stage: "implement", entered_at: at(), exit: "challenging" },
    { stage: "challenge", entered_at: at(), exit: "capped: 1 adjudicated P1 remaining" },
    { stage: "review", entered_at: at(), exit: "capped: 1 adjudicated P1 remaining" },
  ]);
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-07-10T09:00:00Z",
    stage_transitions: stageTransitions, interventions: chain([]), settlements: chain([]),
    outcome: "capped", pr: null, evidence_comments: [], promotion: null,
  };
  const rr = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-07-10T09:00:00Z");
  comments.push(rr);

  for (const [stage, round] of rounds) {
    const passDoc = JSON.parse(readFileSync(path.join(fixtureRoot, "result.reviewer.schema/valid", \`omator-397-\${stage}-r\${round}.json\`), "utf8"));
    const adjDoc = JSON.parse(readFileSync(path.join(fixtureRoot, "adjudication.schema/valid", \`omator-397-\${stage}-r\${round}-adjudication.json\`), "utf8"));
    const envelope = { ...passDoc, run: { run_id: runId, initiated_by: "human" } };
    const roundPayload = { passes: [envelope], adjudication: adjDoc };
    comments.push(evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, stage, "issue", round, 1, roundPayload, at()));
  }

  writeScenario("omator-397", {
    issues: [{ number: 397, pull_request: null }],
    comments: { "397": comments },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 397, head },
  });
}

// --- Scenario 11: Foreman-initiated run ---
{
  const runId = "run-foreman-1";
  const FOREMAN = 9099;
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "foreman", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "claim", entered_at: "2026-09-01T00:01:00Z", exit: "implementing" },
      { stage: "implement", entered_at: "2026-09-01T00:02:00Z", exit: "reviewing" },
      { stage: "review", entered_at: "2026-09-01T00:03:00Z", exit: "integrating" },
      { stage: "integration", entered_at: "2026-09-01T00:10:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 599, url: "https://example.invalid/pr/599" },
    evidence_comments: [],
    promotion: { head: "3".repeat(40), promoted_at: "2026-09-01T00:15:00Z", gate_fingerprint: "ghi" },
  };
  // Posted by the Foreman service account — trust derives from that actor
  // id being in the configured set, never from initiated_by: "foreman"
  // inside the payload (ai/schemas/README.md "Trust: actor ID, never a
  // payload claim").
  const rr = runRecordComment(FOREMAN, "foreman-bot", runId, runBody, "2026-09-01T00:00:00Z");
  const roundPayload = { passes: [pass("codex-cli", [])], adjudication: { schema: 2, run_id: runId, stage: "review", round: 1, adjudications: [] } };
  const ev = evidenceComment(FOREMAN, "foreman-bot", runId, "review", "issue", 1, 1, roundPayload, "2026-09-01T00:03:30Z");
  writeScenario("foreman", {
    issues: [{ number: 109, pull_request: null }],
    comments: { "109": [rr, ev] },
    commits: { "599": [] },
    meta: { runId, trustedActorIds: [FOREMAN], issueNumber: 109 },
  });
}

// --- Scenario 12: deleted evidence comment — listed in evidence_comments[]
// but the comment itself no longer exists. Must reject as deleted-entry
// tampering, never silently read as "this round never happened".
{
  const runId = "run-deleted-evidence-1";
  const roundPayload = { passes: [pass("codex-cli", [])], adjudication: { schema: 2, run_id: runId, stage: "review", round: 1, adjudications: [] } };
  const ev = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, roundPayload, "2026-09-01T00:03:30Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null,
    evidence_comments: [{
      id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator",
      digest: sha256(JSON.stringify(roundPayload)),
      marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 },
    }],
    promotion: null,
  };
  const rr = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("deleted-evidence", {
    issues: [{ number: 110, pull_request: null }],
    // "ev" is deliberately NOT included here — it existed when the run
    // record's evidence_comments[] entry was written, and has since been
    // deleted from GitHub.
    comments: { "110": [rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 110 },
  });
}

console.log("fixtures built");
NODE

node "$tmp/build-fixtures.mjs" >/dev/null

meta() {
    jq -r "$2" "$tmp/scenarios/$1.json"
}

# ---------------------------------------------------------------------------
# Scenario tests
# ---------------------------------------------------------------------------

echo "== happy path: --run trajectory renders a clean ready-for-review run =="
export DFSTATS_DB="$tmp/scenarios/happy.json"
run_id="$(meta happy .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.outcome == "ready-for-review"' >/dev/null || fail "happy: expected ready-for-review outcome"
echo "$out" | jq -e '.rounds | length == 1' >/dev/null || fail "happy: expected exactly one round"
echo "$out" | jq -e '.rounds[0].stage == "review" and .rounds[0].round == 1' >/dev/null || fail "happy: round stage/number mismatch"

echo "== happy path: --repo metric counts the issue as unattended success =="
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.cohort_size == 1 and .unattended_success_count == 1' >/dev/null || fail "happy: expected 1/1 unattended success"
echo "$out" | jq -e '.per_issue[0].success == true' >/dev/null || fail "happy: per_issue success flag wrong"

echo "== chain fork: two entries claiming the same prev_digest -> indeterminate, never silently resolved =="
export DFSTATS_DB="$tmp/scenarios/fork.json"
run_id="$(meta fork .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "fork: expected exit 3 (indeterminate), got $rc: $out"
echo "$out" | grep -qi "chain broken\|indeterminate" || fail "fork: expected a chain-break/indeterminate reason, got: $out"

echo "== chain fork does not abort the whole --repo scan: other issues still count =="
python3 - "$tmp/scenarios/fork.json" "$tmp/scenarios/happy.json" "$tmp/scenarios/fork-plus-happy.json" <<'PY'
import json, sys
fork = json.load(open(sys.argv[1]))
happy = json.load(open(sys.argv[2]))
combined = {"issues": fork["issues"] + happy["issues"], "comments": {**fork["comments"], **happy["comments"]}, "commits": {**fork.get("commits", {}), **happy.get("commits", {})}}
json.dump(combined, open(sys.argv[3], "w"))
PY
export DFSTATS_DB="$tmp/scenarios/fork-plus-happy.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.indeterminate_count == 1' >/dev/null || fail "fork-plus-happy: expected indeterminate_count 1"
echo "$out" | jq -e '.cohort_size == 1 and .unattended_success_count == 1' >/dev/null || fail "fork-plus-happy: the OTHER issue should still be counted"

echo "== untrusted author: plausible payload, wrong actor id -> rejected as forged, never trusted =="
export DFSTATS_DB="$tmp/scenarios/untrusted-author.json"
run_id="$(meta untrusted-author .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.cohort_size == 0' >/dev/null || fail "untrusted-author: forged run must not enter the cohort at all (no run record found -> not yet kicked off, not a failure)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "untrusted-author: --run should report not-found (an untrusted marker is not a run), got rc=$rc: $out"

echo "== two-source trust root: an id NOT in the configured set is never trusted even alone =="
export DFSTATS_DB="$tmp/scenarios/untrusted-author.json"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 4242 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "untrusted-author under a different trusted set: expected a clean (empty) cohort, not an error, got rc=$rc: $out"
echo "$out" | jq -e '.cohort_size == 0' >/dev/null || fail "untrusted-author under a different trusted set: must still find no run"

echo "== duplicate marker (same-writer resume): lowest id canonical, stable across --as-of cutoffs =="
export DFSTATS_DB="$tmp/scenarios/duplicate-marker.json"
run_id="$(meta duplicate-marker .meta.runId)"
first_id="$(meta duplicate-marker .meta.firstId)"
before_cutoff="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --as-of 2026-09-01T00:03:00Z --json)"
after_cutoff="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --as-of 2026-09-02T00:00:00Z --json)"
echo "$before_cutoff" | jq -e '.rounds | length == 1' >/dev/null || fail "duplicate-marker: expected exactly one round (duplicate resolved, not double-counted)"
echo "$after_cutoff" | jq -e '.rounds | length == 1' >/dev/null || fail "duplicate-marker: still exactly one round after the duplicate's own timestamp"
[ "$(echo "$before_cutoff" | jq -c .rounds)" = "$(echo "$after_cutoff" | jq -c .rounds)" ] || fail "duplicate-marker: reconstruction must be identical at both cutoffs (concurrent-writer stability)"

echo "== split segments reassemble in sequence order =="
export DFSTATS_DB="$tmp/scenarios/split.json"
run_id="$(meta split .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.rounds | length == 1' >/dev/null || fail "split: expected the two segments to reassemble into one round"
echo "$out" | jq -e '.rounds[0].finding_count == 1' >/dev/null || fail "split: expected the reassembled finding to be visible"

echo "== digest tampering: an edited entry is rejected, not silently replayed =="
export DFSTATS_DB="$tmp/scenarios/tamper.json"
run_id="$(meta tamper .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "tamper: expected exit 3 (indeterminate), got $rc: $out"
echo "$out" | grep -qi "tampered\|does not match" || fail "tamper: expected a tamper-shaped reason, got: $out"

echo "== stale non-terminal run terminalizes as abandoned at --as-of =="
export DFSTATS_DB="$tmp/scenarios/stale.json"
as_of="$(meta stale .meta.asOf)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --as-of "$as_of" --json)"
echo "$out" | jq -e '.cohort_size == 1 and .unattended_success_count == 0' >/dev/null || fail "stale: expected the run to close as a failure (abandoned), not stay open"

echo "== post-ready human fix is reported as a separate number =="
export DFSTATS_DB="$tmp/scenarios/postfix.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.unattended_success_count == 1 and .post_ready_fix_count == 1' >/dev/null || fail "postfix: expected success still counted, plus a separate post-ready fix"

echo "== --repo cohort combines multiple issues correctly =="
export DFSTATS_DB="$tmp/scenarios/cohort.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.cohort_size == 2 and .unattended_success_count == 2' >/dev/null || fail "cohort: expected 2/2"

echo "== --trusted-actors-file is unioned with --trusted-actor-id =="
echo '{"trusted_actor_ids":[9001]}' >"$tmp/trusted.json"
export DFSTATS_DB="$tmp/scenarios/happy.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actors-file "$tmp/trusted.json" --json)"
echo "$out" | jq -e '.cohort_size == 1' >/dev/null || fail "trusted-actors-file: expected the file-configured actor to be trusted"

echo "== missing --trusted-actor-id/--trusted-actors-file is a usage error, never a silent open-trust default =="
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing trust config: expected exit 2, got $rc"
echo "$out" | grep -qi "trusted-actor" || fail "missing trust config: expected an explanatory error"

echo "== omator#397: the real committed trajectory harvests and renders =="
export DFSTATS_DB="$tmp/scenarios/omator-397.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run omator-397 --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.outcome == "capped"' >/dev/null || fail "omator-397: expected capped outcome"
echo "$out" | jq -e '.rounds | length == 7' >/dev/null || fail "omator-397: expected 4 challenge + 3 review rounds"
echo "$out" | jq -e '[.rounds[] | select(.stage == "challenge")] | length == 4' >/dev/null || fail "omator-397: expected 4 challenge rounds"
echo "$out" | jq -e '[.rounds[] | select(.stage == "review")] | length == 3' >/dev/null || fail "omator-397: expected 3 review rounds"
echo "$out" | jq -e '[.rounds[].finding_count] | add > 0' >/dev/null || fail "omator-397: expected real findings to carry through"

echo "== Foreman-initiated run: trust from actor id, never from initiated_by =="
export DFSTATS_DB="$tmp/scenarios/foreman.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9099 --json)"
echo "$out" | jq -e '.cohort_size == 1 and .unattended_success_count == 1' >/dev/null || fail "foreman: expected 1/1 unattended success"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run run-foreman-1 --trusted-actor-id 9099 --json)"
echo "$out" | jq -e '.initiated_by == "foreman"' >/dev/null || fail "foreman: expected initiated_by foreman on the rendered trajectory"
# The SAME payload, checked against a trusted set that does NOT include the
# Foreman actor id, must find nothing — proving trust never falls back to
# reading initiated_by out of the payload.
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.cohort_size == 0' >/dev/null || fail "foreman: a payload claiming initiated_by=foreman must not self-authenticate under an unrelated trusted set"

echo "== --replay: fake exit-script, policy unchanged -> no diff =="
cat >"$tmp/fake-exit-script.mjs" <<'FAKE'
#!/usr/bin/env node
// Test double for scripts/dev-flow-exit.mjs's CLI contract: --run <dir>
// --stage <s> --policy <f> --current-head <h> --json. Counts this run
// directory's own rounds for --stage and compares against a `<stage>_cap =
// N` line grepped from --policy — enough to prove dev-flow-stats.mjs wires
// arguments, the run directory, and the verdict JSON through correctly,
// without depending on the real exit-computation logic (#720, not yet on
// main — see ai/schemas/README.md and this lane's PR body).
import { readFileSync, readdirSync, existsSync } from "node:fs";
import path from "node:path";

function parseArgs(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith("--")) {
      a[argv[i].slice(2)] = argv[i + 1] && !argv[i + 1].startsWith("--") ? argv[++i] : true;
    }
  }
  return a;
}
const args = parseArgs(process.argv.slice(2));
const passesDir = path.join(args.run, "passes");
const files = existsSync(passesDir) ? readdirSync(passesDir) : [];
const rounds = new Set(
  files.filter((f) => f.startsWith(`${args.stage}-r`)).map((f) => f.match(/-r(\d+)-/)[1]),
);
const policyText = readFileSync(args.policy, "utf8");
const capMatch = policyText.match(new RegExp(`${args.stage}_cap\\s*=\\s*(\\d+)`));
const cap = capMatch ? Number(capMatch[1]) : 99;
const outcome = rounds.size >= cap ? "capped" : "continue";
const verdict = { stage: args.stage, outcome, reason: outcome === "capped" ? "fake-cap-reached" : "fake-below-cap", rounds_counted: rounds.size, next_round: outcome === "continue" ? rounds.size + 1 : null };
if (args.json) console.log(JSON.stringify(verdict));
process.exit(outcome === "capped" ? 22 : 0);
FAKE
cat >"$tmp/policy-matching.toml" <<'TOML'
challenge_cap = 4
review_cap = 3
TOML
export DFSTATS_DB="$tmp/scenarios/omator-397.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --replay --policy "$tmp/policy-matching.toml" --exit-script "$tmp/fake-exit-script.mjs" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.[0].diffs | length == 0' >/dev/null || fail "replay (matching policy): expected no diffs, got: $out"

echo "== --replay: fake exit-script, looser candidate policy -> reports the diff =="
cat >"$tmp/policy-looser.toml" <<'TOML'
challenge_cap = 10
review_cap = 10
TOML
out="$(node scripts/dev-flow-stats.mjs --repo o/r --replay --policy "$tmp/policy-looser.toml" --exit-script "$tmp/fake-exit-script.mjs" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.[0].diffs | length == 2' >/dev/null || fail "replay (looser policy): expected both stages to diff, got: $out"
echo "$out" | jq -e '[.[0].diffs[].recomputed] == ["continue","continue"]' >/dev/null || fail "replay (looser policy): expected recomputed=continue for both stages"

echo "== --config is accepted as an alias for --policy (issue #663's own acceptance-criterion flag) =="
out="$(node scripts/dev-flow-stats.mjs --repo o/r --replay --config "$tmp/policy-matching.toml" --exit-script "$tmp/fake-exit-script.mjs" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.[0].diffs | length == 0' >/dev/null || fail "replay --config alias: expected no diffs"

echo "== evidence_comments[] cross-check: a genuinely listed-and-present comment passes (happy path, re-verified) =="
export DFSTATS_DB="$tmp/scenarios/happy.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run run-happy-1 --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.rounds | length == 1' >/dev/null || fail "happy (evidence_comments populated): expected the listed round to still be found"

echo "== deleted evidence comment: listed in evidence_comments[] but the comment no longer exists -> indeterminate, never silently absent =="
export DFSTATS_DB="$tmp/scenarios/deleted-evidence.json"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run run-deleted-evidence-1 --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "deleted-evidence: expected exit 3 (indeterminate), got $rc: $out"
echo "$out" | grep -qi "deleted-entry tampering\|no longer exists" || fail "deleted-evidence: expected a deleted-entry-tampering reason, got: $out"

echo "TEST PASS: dev-flow-stats harvesting/trust/metric/replay behavior"
