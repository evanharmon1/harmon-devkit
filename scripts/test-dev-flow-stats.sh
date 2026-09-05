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
repos/*/commits/*/pulls)
    sha="$(echo "$endpoint" | sed -E 's#.*/commits/([0-9a-f]+)/pulls.*#\1#')"
    jq --arg sha "$sha" '[(.commit_pulls[$sha] // [])]' "$db"
    ;;
repos/*/commits/*/check-suites)
    sha="$(echo "$endpoint" | sed -E 's#.*/commits/([0-9a-f]+)/check-suites.*#\1#')"
    jq --arg sha "$sha" '[{check_suites: (.commit_check_suites[$sha] // [])}]' "$db"
    ;;
repos/*/commits\?path=agent-registry.json\&sha=*)
    jq '[(.registry_commits // [])]' "$db"
    ;;
repos/*/contents/agent-registry.json\?ref=*)
    sha="$(echo "$endpoint" | sed -E 's#.*[?&]ref=([0-9a-f]+).*#\1#')"
    jq --arg sha "$sha" '{content: (.registry_contents[$sha] // null)}' "$db"
    ;;
repos/[^/]*/[^/]*)
    jq '{default_branch: (.default_branch // "main")}' "$db"
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
  entryDigest, sha256, canonicalDigest, GENESIS, payloadDigest,
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

// Auto-derives evidence_registrations[]/pr_bindings[]/outcome_transitions[]
// from a body's own evidence_comments[]/pr/outcome, UNLESS the scenario
// already set one explicitly (needed only by the two scenarios deliberately
// testing THESE chains' own tamper detection — everything else gets a
// consistent, valid chain for free). outcome_transitions borrows
// promotion.promoted_at as its timestamp when a promotion exists — the
// same causal link reconstructAsOf itself now relies on for
// "ready-for-review" — falling back to started_at otherwise; pr_bindings
// always uses started_at (no existing scenario depends on PR-binding's own
// as-of timing, only outcome's).
function deriveDefaultChains(body) {
  const out = {};
  if (!("evidence_registrations" in body)) {
    out.evidence_registrations = chain((body.evidence_comments || []).map((e) => ({
      id: e.id, author_actor_id: e.author_actor_id, login: e.login,
      payload_digest: e.digest, marker: e.marker, registered_at: body.started_at,
    })));
  }
  if (!("pr_bindings" in body)) {
    out.pr_bindings = body.pr ? chain([{ number: body.pr.number, url: body.pr.url, bound_at: body.started_at }]) : chain([]);
  }
  if (!("outcome_transitions" in body)) {
    const at = body.promotion ? body.promotion.promoted_at : body.started_at;
    out.outcome_transitions = body.outcome ? chain([{ outcome: body.outcome, at }]) : chain([]);
  }
  return out;
}

// Returns { index, record } — the run-index anchor and the run-record
// comment it names, built together since the index's payload has to name
// the record comment's own id/digest/author (ai/schemas/README.md
// "Comment kinds", run-index). Every scenario needs both on the issue now;
// scanning for a bare run-record marker with no anchoring index is exactly
// what challenge round 1 confirmed as a real gap.
function runRecordComment(actorId, login, runId, bodyIn, createdAt) {
  const body = { ...bodyIn, ...deriveDefaultChains(bodyIn) };
  const text = JSON.stringify(body);
  const m = marker("run-record", runId, "kickoff", "issue", null, 1);
  const record = comment(actorId, login, \`\${m}\n\${fence(text)}\`, createdAt);
  const indexPayload = {
    run_id: runId, initiated_by: body.initiated_by, branch: null,
    run_record: { id: String(record.id), author_actor_id: actorId, login },
  };
  const im = marker("run-index", runId, "kickoff", "issue", null, 1);
  const index = comment(actorId, login, \`\${im}\n\${fence(JSON.stringify(indexPayload))}\`, createdAt);
  return { index, record };
}

function evidenceComment(actorId, login, runId, stage, dest, round, seq, payload, createdAt) {
  const text = JSON.stringify(payload);
  const m = marker("evidence", runId, stage, dest, round, seq);
  return comment(actorId, login, \`\${m}\n\${fence(text)}\`, createdAt);
}

// Builds the evidence_comments[] entry naming a comment created by
// evidenceComment() above — discovery is list-driven now, so every real
// round comment in a fixture needs a matching entry or it is simply never
// found. digest is the digest of the FULL reassembled payload (the same
// value across every segment of a split round, not each segment's own
// text) — pass it explicitly rather than recomputing per-segment.
function evidenceIndexEntry(evComment, actorId, login, runId, stage, dest, round, seq, digest) {
  return {
    id: String(evComment.id), author_actor_id: actorId, login,
    digest,
    marker: { run_id: runId, stage, destination: dest, round, sequence: seq },
  };
}

function pass(finder, findings) {
  return {
    schema: 2, role: "reviewer", status: "completed", head: "0".repeat(40),
    produced_at: "2026-09-01T00:00:00Z", producer: finder,
    run: { run_id: "placeholder", initiated_by: "human" },
    payload: { finder, findings: findings.map((f, i) => ({ id: \`review-r1-\${finder}-\${i + 1}\`, class: "correctness", provenance: "original", severity: "P2", ...f })) },
  };
}

// review round 4: first_seen(sha) resolution data for the fake gh shim's
// commits/{sha}/pulls and commits/{sha}/check-suites endpoints. Merged by
// caller into the scenario db's commit_pulls/commit_check_suites maps.
function mergedPrSeen(sha, prNumber, mergedAt) {
  return { commit_pulls: { [sha]: [{ number: prNumber, merged_at: mergedAt }] } };
}
function checkSuiteSeen(sha, createdAts) {
  return { commit_check_suites: { [sha]: createdAts.map((created_at) => ({ created_at })) } };
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
      digest: payloadDigest(JSON.stringify(roundPayload)),
      marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 },
    }],
    promotion: { head: "1".repeat(40), promoted_at: "2026-09-01T00:15:00Z", gate_fingerprint: "abc" },
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("happy", {
    issues: [{ number: 101, pull_request: null }],
    comments: { "101": [idx, rr, ev] },
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
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("fork", {
    issues: [{ number: 102, pull_request: null }],
    comments: { "102": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 102 },
  });
}

// --- Scenario 2b: a resumed writer's own retry re-appends a BYTE-IDENTICAL
// entry (same seq, same prev_digest, same digest) — must normalize to one
// and validate cleanly, the opposite of scenario 2's genuine fork (review
// round 1, confirmed P1: this was previously indistinguishable from a
// broken chain, since nothing collapsed the duplicate before the strict
// seq === i check ran).
{
  const runId = "run-dup-retry-1";
  const base = chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" }]);
  const claimContent = { stage: "claim", entered_at: "2026-09-01T00:01:00Z" };
  const claimDigest = entryDigest(claimContent, base[0].digest);
  const claimEntry = { ...claimContent, seq: 1, digest: claimDigest, prev_digest: base[0].digest };
  const retried = [...base, claimEntry, { ...claimEntry }]; // exact duplicate append
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: retried, interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("dup-retry", {
    issues: [{ number: 118, pull_request: null }],
    comments: { "118": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 118 },
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
  const { index: idx, record: rr } = runRecordComment(UNTRUSTED, "impersonator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("untrusted-author", {
    issues: [{ number: 103, pull_request: null }],
    comments: { "103": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 103 },
  });
}

// --- Scenario 4: duplicate marker (same-writer resume), lowest id wins,
// stable under --as-of at any cutoff regardless of which duplicate a
// harvester happens to read first ---
{
  const runId = "run-dup-1";
  const payloadA = { passes: [pass("codex-cli", [{ title: "finding-from-first-post" }])], adjudication: null };
  const first = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, payloadA, "2026-09-01T00:02:00Z");
  // A resumed session re-posts the SAME event (same marker, same content —
  // a genuine duplicate of the identical event, not a fork) before
  // realizing it already succeeded. A writer that then updates
  // evidence_comments[] names only the CANONICAL (lowest-id) comment —
  // list-driven discovery means the duplicate is simply never listed, so
  // there is nothing to "resolve" at read time; it is an unlisted orphan,
  // correctly ignored.
  const duplicate = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, payloadA, "2026-09-01T00:05:00Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" }, { stage: "claim", entered_at: "2026-09-01T00:01:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null,
    evidence_comments: [evidenceIndexEntry(first, TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, payloadDigest(JSON.stringify(payloadA)))],
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("duplicate-marker", {
    issues: [{ number: 104, pull_request: null }],
    comments: { "104": [idx, rr, first, duplicate] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 104, firstId: first.id, duplicateId: duplicate.id },
  });
}

// --- Scenario 5: split segments (oversized payload) ---
{
  const runId = "run-split-1";
  const fullPayload = { passes: [pass("codex-cli", [{ title: "split-finding" }])], adjudication: null };
  const text = JSON.stringify(fullPayload);
  const mid = Math.floor(text.length / 2);
  const seg1text = text.slice(0, mid);
  const seg2text = text.slice(mid);
  const m1 = marker("evidence", runId, "challenge", "issue", 1, 1);
  const m2 = marker("evidence", runId, "challenge", "issue", 1, 2);
  const seg1 = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${m1}\n\${fence(seg1text)}\`, "2026-09-01T00:02:00Z");
  const seg2 = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${m2}\n\${fence(seg2text)}\`, "2026-09-01T00:02:01Z");
  // Every segment of a split payload is indexed with the digest of the
  // FULL reassembled text (ai/schemas/README.md "Digest") — the same
  // value on both entries, not each segment's own partial-text digest.
  const fullDigest = payloadDigest(text);
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null,
    evidence_comments: [
      evidenceIndexEntry(seg1, TRUSTED_ORCHESTRATOR, "orchestrator", runId, "challenge", "issue", 1, 1, fullDigest),
      evidenceIndexEntry(seg2, TRUSTED_ORCHESTRATOR, "orchestrator", runId, "challenge", "issue", 1, 2, fullDigest),
    ],
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("split", {
    issues: [{ number: 105, pull_request: null }],
    comments: { "105": [idx, rr, seg1, seg2] },
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
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  // Tamper: change entered_at on the (already-embedded, already-digested)
  // second entry without recomputing the chain — this is what an EDIT to
  // the live comment (not a fresh re-post) looks like, since the outer
  // comment body changes but the entry's own recorded digest does not.
  rr.body = rr.body.replace("2026-09-01T00:01:00Z", "2099-01-01T00:00:00Z");
  writeScenario("tamper", {
    issues: [{ number: 106, pull_request: null }],
    comments: { "106": [idx, rr] },
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
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-01-01T00:00:00Z");
  writeScenario("stale", {
    issues: [{ number: 107, pull_request: null }],
    comments: { "107": [idx, rr] },
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
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  // Post-ready fix detection is now position-based (does a commit follow
  // promotion.head in the PR's own sequence), not timestamp-based — the
  // fixture needs the promoted-head commit present so there is a position
  // to follow.
  const promotedCommit = { sha: "2".repeat(40), commit: { committer: { date: "2026-09-01T00:10:00Z" } }, author: { id: TRUSTED_ORCHESTRATOR } };
  const humanCommit = { sha: "4".repeat(40), commit: { committer: { date: "2026-09-01T00:20:00Z" } }, author: { id: 42 } };
  writeScenario("postfix", {
    issues: [{ number: 108, pull_request: null }],
    comments: { "108": [idx, rr] },
    commits: { "502": [promotedCommit, humanCommit] },
    ...mergedPrSeen(humanCommit.sha, 502, "2026-09-01T00:20:00Z"),
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 108 },
  });
}

// --- Scenario 8b: post-ready fix on a run that ALSO had a pre-ready
// intervention — proves the check runs independently of unattended
// success, not only when success is true (challenge round 2, P1).
{
  const runId = "run-postfix-with-intervention-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T00:05:00Z" },
    ]),
    interventions: chain([{ kind: "other", at: "2026-09-01T00:02:00Z", note: "human nudged the stuck round" }]),
    settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 505, url: "https://example.invalid/pr/505" },
    evidence_comments: [],
    promotion: { head: "8".repeat(40), promoted_at: "2026-09-01T00:10:00Z", gate_fingerprint: "pqr" },
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  const promotedCommit = { sha: "8".repeat(40), commit: { committer: { date: "2026-09-01T00:10:00Z" } }, author: { id: TRUSTED_ORCHESTRATOR } };
  const humanCommit = { sha: "9".repeat(40), commit: { committer: { date: "2026-09-01T00:20:00Z" } }, author: { id: 42 } };
  writeScenario("postfix-with-intervention", {
    issues: [{ number: 116, pull_request: null }],
    comments: { "116": [idx, rr] },
    commits: { "505": [promotedCommit, humanCommit] },
    ...mergedPrSeen(humanCommit.sha, 505, "2026-09-01T00:20:00Z"),
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 116 },
  });
}

// --- Scenario 9: multiple issues combined, for --repo cohort math ---
{
  const dbs = ["happy", "postfix"].map((n) => JSON.parse(readFileSync(path.join("${tmp}/scenarios", \`\${n}.json\`), "utf8")));
  const combined = { issues: [], comments: {}, commits: {}, commit_pulls: {}, commit_check_suites: {}, meta: { trustedActorIds: [TRUSTED_ORCHESTRATOR] } };
  for (const db of dbs) {
    combined.issues.push(...db.issues);
    Object.assign(combined.comments, db.comments);
    Object.assign(combined.commits, db.commits);
    Object.assign(combined.commit_pulls, db.commit_pulls);
    Object.assign(combined.commit_check_suites, db.commit_check_suites);
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
  const evComments = [];
  const evIndexEntries = [];
  let t = 0;
  const at = () => \`2026-07-10T\${String(9 + t++).padStart(2, "0")}:00:00Z\`;

  const stageTransitions = chain([
    { stage: "kickoff", entered_at: at(), exit: "claimed" },
    { stage: "claim", entered_at: at(), exit: "implementing" },
    { stage: "implement", entered_at: at(), exit: "challenging" },
    { stage: "challenge", entered_at: at(), exit: "capped: 1 adjudicated P1 remaining" },
    { stage: "review", entered_at: at(), exit: "capped: 1 adjudicated P1 remaining" },
  ]);

  for (const [stage, round] of rounds) {
    const passDoc = JSON.parse(readFileSync(path.join(fixtureRoot, "result.reviewer.schema/valid", \`omator-397-\${stage}-r\${round}.json\`), "utf8"));
    const adjDoc = JSON.parse(readFileSync(path.join(fixtureRoot, "adjudication.schema/valid", \`omator-397-\${stage}-r\${round}-adjudication.json\`), "utf8"));
    const envelope = { ...passDoc, run: { run_id: runId, initiated_by: "human" } };
    const roundPayload = { passes: [envelope], adjudication: adjDoc };
    const ev = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, stage, "issue", round, 1, roundPayload, at());
    evComments.push(ev);
    evIndexEntries.push(evidenceIndexEntry(ev, TRUSTED_ORCHESTRATOR, "orchestrator", runId, stage, "issue", round, 1, payloadDigest(JSON.stringify(roundPayload))));
  }

  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-07-10T09:00:00Z",
    stage_transitions: stageTransitions, interventions: chain([]), settlements: chain([]),
    outcome: "capped", pr: null, evidence_comments: evIndexEntries, promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-07-10T09:00:00Z");

  writeScenario("omator-397", {
    issues: [{ number: 397, pull_request: null }],
    comments: { "397": [idx, rr, ...evComments] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 397, head },
  });
}

// --- Scenario 11: Foreman-initiated run ---
{
  const runId = "run-foreman-1";
  const FOREMAN = 9099;
  const roundPayload = { passes: [pass("codex-cli", [])], adjudication: { schema: 2, run_id: runId, stage: "review", round: 1, adjudications: [] } };
  const ev = evidenceComment(FOREMAN, "foreman-bot", runId, "review", "issue", 1, 1, roundPayload, "2026-09-01T00:03:30Z");
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
    evidence_comments: [evidenceIndexEntry(ev, FOREMAN, "foreman-bot", runId, "review", "issue", 1, 1, payloadDigest(JSON.stringify(roundPayload)))],
    promotion: { head: "3".repeat(40), promoted_at: "2026-09-01T00:15:00Z", gate_fingerprint: "ghi" },
  };
  // Posted by the Foreman service account — trust derives from that actor
  // id being in the configured set, never from initiated_by: "foreman"
  // inside the payload (ai/schemas/README.md "Trust: actor ID, never a
  // payload claim").
  const { index: idx, record: rr } = runRecordComment(FOREMAN, "foreman-bot", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("foreman", {
    issues: [{ number: 109, pull_request: null }],
    comments: { "109": [idx, rr, ev] },
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
      digest: payloadDigest(JSON.stringify(roundPayload)),
      marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 },
    }],
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("deleted-evidence", {
    issues: [{ number: 110, pull_request: null }],
    // "ev" is deliberately NOT included here — it existed when the run
    // record's evidence_comments[] entry was written, and has since been
    // deleted from GitHub.
    comments: { "110": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 110 },
  });
}

// --- Scenario 12.5 (kept out of numeric order to avoid renumbering
// everything below): --as-of between a stage-exit and its later promotion
// must read as in-flight, never as ready-for-review borrowed from the
// record's own CURRENT (later) outcome field.
{
  const runId = "run-future-outcome-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T00:05:00Z", exit: "ready-for-review" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 504, url: "https://example.invalid/pr/504" },
    evidence_comments: [],
    // Promotion lands 15 minutes AFTER the integration exit text already
    // says "ready-for-review" — the exit text alone is not the readiness
    // signal; the promotion entry's own timestamp is.
    promotion: { head: "7".repeat(40), promoted_at: "2026-09-01T00:20:00Z", gate_fingerprint: "mno" },
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("future-outcome", {
    issues: [{ number: 112, pull_request: null }],
    comments: { "112": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 112 },
  });
}

// --- Scenario 12.5b: terminal outcome derivation must not depend on the
// exit text starting with a specific "magic word" — run.schema.json's
// exit field is free text, only ever exemplified, never a fixed format.
{
  const runId = "run-freetext-exit-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      // Deliberately does NOT start with "escalated" even though this run
      // IS escalated (body.outcome says so) — a phrasing choice, not a
      // violation of any format the schema actually requires.
      { stage: "review", entered_at: "2026-09-01T00:05:00Z", exit: "blocked pending a maintainer decision" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "escalated", pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("freetext-exit", {
    issues: [{ number: 115, pull_request: null }],
    comments: { "115": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 115 },
  });
}

// --- Scenario 12.55: the run-record comment is EDITED after the index
// was created — the exact scenario the P0 (challenge round 2) was about.
// Every other fixture here builds the record's FINAL body directly and
// never actually simulates a temporal edit, which is exactly how that bug
// stayed invisible to the round-1 test suite.
{
  const runId = "run-edited-record-1";
  const kickoffOnly = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  // Index is minted from the KICKOFF-only body — this is what "the index
  // captures the record's identity at creation" actually means; it must
  // never be asked to also vouch for content the record does not have yet.
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, kickoffOnly, "2026-09-01T00:00:00Z");
  // Now edit the SAME comment in place, as the real protocol requires —
  // extends the chain with a real transition, a real digest, a real link.
  const editedTransitions = chain([
    { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
    { stage: "claim", entered_at: "2026-09-01T00:05:00Z", exit: "implementing" },
  ]);
  const editedBody = { ...kickoffOnly, stage_transitions: editedTransitions };
  const m = marker("run-record", runId, "kickoff", "issue", null, 1);
  rr.body = \`\${m}\n\${fence(JSON.stringify(editedBody))}\`;
  writeScenario("edited-record", {
    issues: [{ number: 114, pull_request: null }],
    comments: { "114": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 114 },
  });
}

// --- Scenario 12.6: the run-record comment itself is deleted, but the
// tiny run-index anchor survives. Must report deleted-entry tampering,
// never "this issue was never kicked off" — the exact scenario challenge
// round 1's P1 finding was about.
{
  const runId = "run-deleted-record-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("deleted-record", {
    issues: [{ number: 113, pull_request: null }],
    // "record" is deliberately NOT included — only its index survives.
    comments: { "113": [idx] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 113 },
  });
}

// --- Scenario 12.7: a listed evidence entry whose OWN marker names a
// DIFFERENT run_id than the run record it's listed on (challenge round 3,
// "Bind listed evidence to the current run") ---
{
  const runId = "run-foreign-evidence-1";
  const otherRunId = "run-other-victim-1";
  // The comment's marker genuinely says otherRunId — a copy-paste/stale
  // index bug listing it under THIS run's evidence_comments[] anyway.
  const roundPayload = { passes: [pass("codex-cli", [{ title: "belongs-to-a-different-run" }])], adjudication: null };
  const foreignEv = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", otherRunId, "review", "issue", 1, 1, roundPayload, "2026-09-01T00:02:00Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null,
    evidence_comments: [{
      id: String(foreignEv.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator",
      digest: payloadDigest(JSON.stringify(roundPayload)),
      // The list entry's OWN marker claims THIS run — but the comment's
      // actual, current marker (in its body) says otherRunId. A bug that
      // copies an index entry across runs would produce exactly this
      // mismatch.
      marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 },
    }],
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("foreign-evidence", {
    issues: [{ number: 117, pull_request: null }],
    comments: { "117": [idx, rr, foreignEv] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 117 },
  });
}

// --- Scenario 12.8: conflicting payloads under one marker still resolve
// by lowest id, UNCONDITIONALLY — the reverted round-1 regression
// (challenge round 3, "Honor the lowest-ID rule for conflicting
// duplicates") ---
{
  const runId = "run-conflicting-dup-1";
  const payloadA = { passes: [pass("codex-cli", [{ title: "snapshot-A" }])], adjudication: null };
  const payloadB = { passes: [pass("codex-cli", [{ title: "snapshot-B-different-content" }])], adjudication: null };
  const first = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, payloadA, "2026-09-01T00:02:00Z");
  // A genuinely CONCURRENT writer race — same marker, DIFFERENT payload
  // snapshot (not a resume re-posting the identical event).
  const second = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, payloadB, "2026-09-01T00:02:05Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null,
    // The writer's own resolution (after the race) lists the LOWER id —
    // "first" — with ITS OWN digest.
    evidence_comments: [evidenceIndexEntry(first, TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, payloadDigest(JSON.stringify(payloadA)))],
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("conflicting-dup", {
    issues: [{ number: 118, pull_request: null }],
    comments: { "118": [idx, rr, first, second] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 118 },
  });
}

// --- Scenario 12.9: a PROMOTED run whose challenge stage's latest round
// reviewed an EARLIER head than the final promotion (review/integration
// added commits afterward) — replay must use challenge's OWN head, not
// promotion.head, for the challenge stage (challenge round 3, "Replay
// each stage against its reviewed head") ---
{
  const runId = "run-stage-heads-1";
  const challengeHead = "a".repeat(40);
  const finalHead = "b".repeat(40);
  const challengePayload = { passes: [{ schema: 2, role: "reviewer", status: "completed", head: challengeHead, produced_at: "2026-09-01T00:01:00Z", producer: { harness: "codex-cli" }, run: { run_id: runId, initiated_by: "human" }, payload: { stage: "challenge", round: 1, reviewed_head: challengeHead, finder: "codex-cli", findings: [] } }], adjudication: { schema: 2, run_id: runId, stage: "challenge", round: 1, adjudications: [] } };
  const ev = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "challenge", "issue", 1, 1, challengePayload, "2026-09-01T00:02:00Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T00:10:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 506, url: "https://example.invalid/pr/506" },
    evidence_comments: [evidenceIndexEntry(ev, TRUSTED_ORCHESTRATOR, "orchestrator", runId, "challenge", "issue", 1, 1, payloadDigest(JSON.stringify(challengePayload)))],
    // Promoted at a LATER head than challenge's own reviewed_head.
    promotion: { head: finalHead, promoted_at: "2026-09-01T00:15:00Z", gate_fingerprint: "stu" },
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("stage-heads", {
    issues: [{ number: 119, pull_request: null }],
    comments: { "119": [idx, rr, ev] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 119, challengeHead, finalHead },
  });
}

// --- Scenario 13: post-ready fix with a cherry-picked (OLDER-timestamped)
// commit landing AFTER promotion.head positionally — proves detection is
// position-based, not timestamp-based (a timestamp-only check would miss
// this one entirely).
{
  const runId = "run-postfix-cherrypick-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T00:01:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 503, url: "https://example.invalid/pr/503" },
    evidence_comments: [],
    promotion: { head: "5".repeat(40), promoted_at: "2026-09-01T00:30:00Z", gate_fingerprint: "jkl" },
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  const promotedCommit = { sha: "5".repeat(40), commit: { committer: { date: "2026-09-01T00:30:00Z" } }, author: { id: TRUSTED_ORCHESTRATOR } };
  // Committer date predates promotion — a naive timestamp check would
  // classify this as pre-ready and miss it entirely.
  const cherryPicked = { sha: "6".repeat(40), commit: { committer: { date: "2026-08-01T00:00:00Z" } }, author: { id: 42 } };
  writeScenario("postfix-cherrypick", {
    issues: [{ number: 111, pull_request: null }],
    comments: { "111": [idx, rr] },
    commits: { "503": [promotedCommit, cherryPicked] },
    // first_seen (2026-09-01) is when this cherry-picked commit actually
    // became visible on GitHub — the committer.date above (2026-08-01) is
    // what its own author claims and is not used for visibility at all
    // anymore, only its role in proving position still decides whether a
    // commit is a post-promotion fix in the first place.
    ...mergedPrSeen(cherryPicked.sha, 503, "2026-09-01T00:31:00Z"),
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 111 },
  });
}

// --- Scenario 14: an evidence_registrations[] entry is EDITED in place
// (round 4 of #663, the maintainer's "edited registration ... fails
// closed" requirement) — mirrors scenario 6's digest-tampering test, but
// against the new chain: the registration's own recorded digest no longer
// matches its (now-changed) content, so verifyChain rejects it before
// verifyProjections is ever reached.
{
  const runId = "run-edited-registration-1";
  const ev = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, { passes: [] }, "2026-09-01T00:03:00Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null,
    evidence_comments: [{
      id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator",
      digest: payloadDigest(JSON.stringify({ passes: [] })),
      marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 },
    }],
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  // Tamper: change the (already-embedded, already-digested)
  // evidence_registrations[0].login without recomputing its chain digest —
  // the same in-place-edit shape scenario 6 uses for stage_transitions,
  // applied to the new chain.
  rr.body = rr.body.replace('"login":"orchestrator","payload_digest"', '"login":"someone-else","payload_digest"');
  writeScenario("edited-registration", {
    issues: [{ number: 116, pull_request: null }],
    comments: { "116": [idx, rr, ev] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 116 },
  });
}

// --- Scenario 15: evidence_comments[] (the flat projection) is edited to
// name a DIFFERENT comment id than its own evidence_registrations[] chain
// still names — the chain itself stays internally valid (untouched,
// correctly digested), but no longer matches the flat field it is supposed
// to authenticate. Round 4 of #663's "a swapped comment id ... fails
// closed" requirement: this is what verifyProjections exists to catch,
// distinct from scenario 14's verifyChain break.
{
  const runId = "run-swapped-comment-id-1";
  const ev = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, { passes: [] }, "2026-09-01T00:03:00Z");
  const decoyId = String(Number(ev.id) + 999);
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null,
    // The flat field names a comment id the chain below does NOT — as if
    // it were independently overwritten after the chain was built.
    evidence_comments: [{
      id: decoyId, author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator",
      digest: payloadDigest(JSON.stringify({ passes: [] })),
      marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 },
    }],
    evidence_registrations: chain([{
      id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator",
      payload_digest: payloadDigest(JSON.stringify({ passes: [] })),
      marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 },
      registered_at: "2026-09-01T00:00:00Z",
    }]),
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("swapped-comment-id", {
    issues: [{ number: 117, pull_request: null }],
    comments: { "117": [idx, rr, ev] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 117 },
  });
}

// --- Scenario 16: a failed first run, then a HUMAN-initiated second run
// that reaches ready-for-review with an empty interventions[] of its own —
// the re-kick itself must count as an intervention (specs/dev-flow-v2.md
// § Success metric: "a human re-kicking a failed run is itself an
// intervention"). Review round 1, confirmed P1: previously ignored,
// reporting unattended success.
{
  const issueNumber = 119;
  const runIdA = "run-multirun-human-A";
  const bodyA = {
    schema: 2, run_id: runIdA, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: "abandoned", pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idxA, record: rrA } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runIdA, bodyA, "2026-09-01T00:00:00Z");

  const runIdB = "run-multirun-human-B";
  const bodyB = {
    schema: 2, run_id: runIdB, initiated_by: "human", started_at: "2026-09-01T02:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T02:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T02:05:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 619, url: "https://example.invalid/pr/619" },
    evidence_comments: [], promotion: { head: "8".repeat(40), promoted_at: "2026-09-01T02:10:00Z", gate_fingerprint: "pqr" },
  };
  const { index: idxB, record: rrB } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runIdB, bodyB, "2026-09-01T02:00:00Z");

  writeScenario("multirun-human-rekick", {
    issues: [{ number: issueNumber, pull_request: null }],
    comments: { [String(issueNumber)]: [idxA, rrA, idxB, rrB] },
    commits: { "619": [] },
    meta: { trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber },
  });
}

// --- Scenario 17: the same shape as 16, but the second run is
// FOREMAN-initiated — specs/dev-flow-v2.md's explicit carve-out ("a
// Foreman automatic retry is not [an intervention]"). Negative control
// proving scenario 16's fix does not overreach.
{
  const issueNumber = 120;
  const FOREMAN_ID = 9099;
  const runIdA = "run-multirun-foreman-A";
  const bodyA = {
    schema: 2, run_id: runIdA, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: "abandoned", pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idxA, record: rrA } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runIdA, bodyA, "2026-09-01T00:00:00Z");

  const runIdB = "run-multirun-foreman-B";
  const bodyB = {
    schema: 2, run_id: runIdB, initiated_by: "foreman", started_at: "2026-09-01T02:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T02:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T02:05:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 620, url: "https://example.invalid/pr/620" },
    evidence_comments: [], promotion: { head: "9".repeat(40), promoted_at: "2026-09-01T02:10:00Z", gate_fingerprint: "stu" },
  };
  const { index: idxB, record: rrB } = runRecordComment(FOREMAN_ID, "foreman-bot", runIdB, bodyB, "2026-09-01T02:00:00Z");

  writeScenario("multirun-foreman-retry", {
    issues: [{ number: issueNumber, pull_request: null }],
    comments: { [String(issueNumber)]: [idxA, rrA, idxB, rrB] },
    commits: { "620": [] },
    meta: { trustedActorIds: [TRUSTED_ORCHESTRATOR, FOREMAN_ID], issueNumber },
  });
}

// --- Scenario 18: an --as-of cutoff BEFORE the run's PR ever existed must
// not report deleted-entry tampering for a PR-side evidence_comments[]
// entry the LIVE record later added — review round 1, confirmed P1: the
// harvester previously fetched PR comments using the AS-OF-FILTERED pr
// (correctly null before the cutoff), so it never even looked for that
// entry's comment, and the unconditional existence check then rejected
// the whole run as tampered. The as-of trajectory must still exclude the
// PR-side round (posted after the cutoff) — this proves both halves.
{
  const runId = "run-asof-pr-rollup-1";
  const stagePayload = { passes: [pass("codex-cli", [])], adjudication: { schema: 2, run_id: runId, stage: "review", round: 1, adjudications: [] } };
  const prRollup = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "pr", null, 1, stagePayload, "2026-09-01T02:20:00Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T02:00:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 621, url: "https://example.invalid/pr/621" },
    evidence_comments: [{
      id: String(prRollup.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator",
      digest: payloadDigest(JSON.stringify(stagePayload)),
      marker: { run_id: runId, stage: "review", destination: "pr", round: null, sequence: 1 },
    }],
    // Explicit override, not the auto-derived default (which would bind
    // at started_at — too early to exercise the bug this proves): the PR
    // is bound at 02:10, after the "before" cutoff below and before the
    // "after" one, so state.pr is genuinely null at "before" while
    // record.body.pr stays non-null throughout — exactly the state.pr-
    // vs-record.body.pr gap the fix closes.
    pr_bindings: chain([{ number: 621, url: "https://example.invalid/pr/621", bound_at: "2026-09-01T02:10:00Z" }]),
    promotion: { head: "b".repeat(40), promoted_at: "2026-09-01T02:15:00Z", gate_fingerprint: "vwx" },
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("asof-pr-rollup", {
    issues: [{ number: 121, pull_request: null }],
    comments: { "121": [idx, rr], "621": [prRollup] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 121 },
  });
}

// --- Scenario 19: an evidence_comments[] entry names a DIFFERENT trusted
// actor (OTHER_TRUSTED, also in the configured set, but not this run's own
// author) as author_actor_id, and a real comment exists matching that
// claim exactly (marker, digest, and actual author all agree with the
// entry) — review round 2, confirmed P1: self-consistency alone accepted
// this; trust must narrow to the run's OWN author specifically
// (ai/schemas/README.md "Trust: actor ID, never a payload claim").
{
  const runId = "run-forged-author-1";
  const stagePayload = { passes: [pass("codex-cli", [])], adjudication: { schema: 2, run_id: runId, stage: "review", round: 1, adjudications: [] } };
  const ev = evidenceComment(OTHER_TRUSTED, "other-orchestrator", runId, "review", "issue", 1, 1, stagePayload, "2026-09-01T00:03:00Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null,
    evidence_comments: [{
      id: String(ev.id), author_actor_id: OTHER_TRUSTED, login: "other-orchestrator",
      digest: payloadDigest(JSON.stringify(stagePayload)),
      marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 },
    }],
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("forged-author", {
    issues: [{ number: 122, pull_request: null }],
    comments: { "122": [idx, rr, ev] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR, OTHER_TRUSTED], issueNumber: 122 },
  });
}

// --- Scenario 20: a run sits in one stage for well past stale_after by
// stage_transitions alone, but keeps posting NEW round evidence (fresh
// evidence_registrations entries) throughout — review round 2, confirmed
// P1: staleness previously ignored evidence_registrations/pr_bindings/
// outcome_transitions entirely, so genuinely active runs were
// terminalized as abandoned.
{
  const runId = "run-active-not-stale-1";
  const stagePayload = { passes: [pass("codex-cli", [])], adjudication: { schema: 2, run_id: runId, stage: "review", round: 1, adjudications: [] } };
  const ev = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, stagePayload, "2026-09-08T12:00:00Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "review", entered_at: "2026-09-01T00:05:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null,
    evidence_comments: [{
      id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator",
      digest: payloadDigest(JSON.stringify(stagePayload)),
      marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 },
    }],
    // Explicit override: registered well within the stale window, days
    // after the last stage_transitions entry (2026-09-01), proving THIS
    // is what keeps the run active, not the stage transition.
    evidence_registrations: chain([{
      id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator",
      payload_digest: payloadDigest(JSON.stringify(stagePayload)),
      marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 },
      registered_at: "2026-09-08T12:00:00Z",
    }]),
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("active-not-stale", {
    issues: [{ number: 123, pull_request: null }],
    comments: { "123": [idx, rr, ev] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 123 },
  });
}

// --- Scenario 21: the run-record's MARKER line names one run_id, but its
// own JSON PAYLOAD declares a different run_id — review round 3, confirmed
// P1: these are two independent pieces of text in one comment body, and
// nothing previously required them to agree.
{
  const runId = "run-marker-payload-mismatch-1";
  const runBody = {
    schema: 2, run_id: "run-marker-payload-mismatch-DIFFERENT", initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("marker-payload-mismatch", {
    issues: [{ number: 124, pull_request: null }],
    comments: { "124": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 124 },
  });
}

// --- Scenario 22: two stage_transitions entries share seq/prev_digest/
// digest (what the OLD normalizeExactDuplicates compared), but have
// DIFFERENT semantic content — content was edited after landing WITHOUT
// recomputing the (now-stale) digest. review round 3, confirmed P1: the
// old comparison would have silently kept the FIRST one and discarded the
// tampered one before its digest was ever checked against ITS content —
// this fixture proves the fix instead reports it as a fork.
{
  const runId = "run-tampered-duplicate-1";
  const base = chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" }]);
  const validContent = { stage: "claim", entered_at: "2026-09-01T00:01:00Z" };
  const validDigest = entryDigest(validContent, base[0].digest);
  const validEntry = { ...validContent, seq: 1, digest: validDigest, prev_digest: base[0].digest };
  // Same seq/prev_digest/digest as validEntry, but different entered_at —
  // simulating an edit that changed content without recomputing digest.
  const tamperedEntry = { stage: "claim", entered_at: "2099-01-01T00:00:00Z", seq: 1, digest: validDigest, prev_digest: base[0].digest };
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: [...base, validEntry, tamperedEntry],
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("tampered-duplicate", {
    issues: [{ number: 125, pull_request: null }],
    comments: { "125": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 125 },
  });
}

// --- Scenario 23: registry-revision pinning (review round 4 of #663,
// piece 2 — issue #741's not-yet-existent trusted-orchestrator allowlist,
// resolved via resolveRegistryTrustedActorIds). One registry commit
// narrows the CLI-configured trust set; two issues straddle its
// first_seen, proving the revision applies to a run kicked off AFTER it
// took effect and does NOT retroactively apply to one kicked off BEFORE —
// #741's own acceptance criterion ("an actor removed after posting does
// not invalidate already-authenticated historical evidence").
{
  const narrowSha = "a".repeat(40);
  const registryCommits = [{ sha: narrowSha }];
  const registryContents = {
    [narrowSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [OTHER_TRUSTED] })).toString("base64"),
  };
  // Issue A: kicks off AFTER the narrowing commit's first_seen -> the
  // registry opinion is eligible and applies -> TRUSTED_ORCHESTRATOR (the
  // only CLI-trusted actor here) is narrowed OUT (the registry vouches
  // only for OTHER_TRUSTED) -> rejected, even though --trusted-actor-id
  // alone would have accepted it.
  const runIdNarrowed = "run-registry-narrowed-1";
  const bodyNarrowed = {
    schema: 2, run_id: runIdNarrowed, initiated_by: "human", started_at: "2026-09-01T00:10:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:10:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const narrowedPair = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runIdNarrowed, bodyNarrowed, "2026-09-01T00:10:00Z");
  // Issue B: kicks off BEFORE the narrowing commit's first_seen -> no
  // registry revision is eligible yet -> falls back to full CLI trust,
  // unchanged -> accepted normally.
  const runIdNotYet = "run-registry-not-yet-narrowed-1";
  const bodyNotYet = {
    schema: 2, run_id: runIdNotYet, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const notYetPair = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runIdNotYet, bodyNotYet, "2026-09-01T00:00:00Z");
  writeScenario("registry-revision-pin", {
    issues: [{ number: 126, pull_request: null }, { number: 127, pull_request: null }],
    comments: {
      "126": [narrowedPair.index, narrowedPair.record],
      "127": [notYetPair.index, notYetPair.record],
    },
    commits: {},
    registry_commits: registryCommits,
    registry_contents: registryContents,
    // first_seen for the narrowing commit sits BETWEEN the two kickoffs.
    ...mergedPrSeen(narrowSha, 601, "2026-09-01T00:05:00Z"),
    meta: {
      runIdNarrowed, runIdNotYet,
      trustedActorIds: [TRUSTED_ORCHESTRATOR],
      issueNumberNarrowed: 126, issueNumberNotYet: 127,
    },
  });
}

// --- Scenario 24: a cherry-picked registry commit that appears NEWEST in
// commits-by-path listing order is still correctly excluded when its own
// first_seen postdates the run's kickoff — selection is governed
// exclusively by first_seen, never by listing position (a real cherry-pick
// onto main typically appears newest in this listing despite carrying
// older-looking content) and never by any committer/author date (never
// even read here). An earlier, genuinely-eligible commit governs instead.
{
  const legitSha = "b".repeat(40);
  const cherrypickSha = "c".repeat(40);
  const registryCommits = [{ sha: cherrypickSha }, { sha: legitSha }]; // newest-first, as GitHub returns
  const registryContents = {
    [legitSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [TRUSTED_ORCHESTRATOR] })).toString("base64"),
    [cherrypickSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [OTHER_TRUSTED] })).toString("base64"),
  };
  const runId = "run-registry-cherrypick-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("registry-revision-cherrypick", {
    issues: [{ number: 128, pull_request: null }],
    comments: { "128": [idx, rr] },
    commits: {},
    registry_commits: registryCommits,
    registry_contents: registryContents,
    commit_pulls: {
      [legitSha]: [{ number: 602, merged_at: "2026-08-15T00:00:00Z" }],
      [cherrypickSha]: [{ number: 603, merged_at: "2026-09-01T00:10:00Z" }],
    },
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 128 },
  });
}

// --- Scenario 25: a schema-conformant record whose stage_transitions[]
// carries NO seq/digest/prev_digest at all (today's shipped run.schema.json
// forbids those fields via additionalProperties:false — #738, open) still
// harvests successfully (shepherd round 1, Codex-confirmed P1); a record
// with a MIXED shape (one entry chain-protected, one not) still fails
// closed as tampering, never silently accepted either way.
{
  const runIdPlain = "run-chain-pending-plain-1";
  const bodyPlain = {
    schema: 2, run_id: runIdPlain, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: [
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "claim", entered_at: "2026-09-01T00:01:00Z" },
    ],
    interventions: [], settlements: [],
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idxPlain, record: rrPlain } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runIdPlain, bodyPlain, "2026-09-01T00:00:00Z");

  const runIdMixed = "run-chain-pending-mixed-1";
  const protectedEntry = {
    stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed",
    seq: 0, digest: entryDigest({ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" }, GENESIS), prev_digest: GENESIS,
  };
  const bodyMixed = {
    schema: 2, run_id: runIdMixed, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: [protectedEntry, { stage: "claim", entered_at: "2026-09-01T00:01:00Z" }],
    interventions: [], settlements: [],
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idxMixed, record: rrMixed } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runIdMixed, bodyMixed, "2026-09-01T00:00:00Z");

  writeScenario("chain-pending-schema", {
    issues: [{ number: 129, pull_request: null }, { number: 130, pull_request: null }],
    comments: { "129": [idxPlain, rrPlain], "130": [idxMixed, rrMixed] },
    commits: {},
    meta: { runIdPlain, runIdMixed, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumberPlain: 129, issueNumberMixed: 130 },
  });
}

// --- Scenario 26: initiated_by is edited in place in the mutable record
// body, disagreeing with the run-index's own immutable copy — shepherd
// round 1, Codex-confirmed (P1). initiated_by is not chain-protected, so
// before this fix the edit passed every existing check;
// computeIssueVerdict's human-intervention counting depends on it being
// genuine. started_at's OWN tamper case (originally paired with this one
// in round 1) is now scenario 26.5 below: round 1's cross-check against
// the run-index comment's created_at turned out to be too strict for a
// legitimate writer (shepherd round 2, Codex-confirmed) and was replaced
// with never trusting body.started_at at all — so what scenario 26.5
// proves is that tampering it has NO EFFECT, not that it is rejected.
{
  const runIdInit = "run-initiated-by-tamper-1";
  const bodyInit = {
    schema: 2, run_id: runIdInit, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idxInit, record: rrInit } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runIdInit, bodyInit, "2026-09-01T00:00:00Z");
  rrInit.body = rrInit.body.replace('"initiated_by":"human"', '"initiated_by":"foreman"');

  writeScenario("mutable-field-tamper", {
    issues: [{ number: 137, pull_request: null }],
    comments: { "137": [idxInit, rrInit] },
    commits: {},
    meta: { runIdInit, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumberInit: 137 },
  });
}

// --- Scenario 26.5: a run record body claiming a DIFFERENT started_at
// than the comment's own created_at (an edit, or simply a writer that
// computed the timestamp before posting) has NO EFFECT — started_at is
// never read from the body at all. shepherd round 2, Codex-confirmed
// (P1): round 1's exact-equality cross-check against the run-index's
// created_at was itself too strict (the index cannot be posted until the
// record's own POST returns a comment id to name, so ordinary latency
// between the two posts could legitimately cross a second boundary and
// fail equality). The fix instead uses the run-record COMMENT's own
// created_at unconditionally — this fixture proves the run authenticates
// cleanly and --run reports the comment's real created_at, not the
// claimed value.
{
  const runId = "run-started-at-neutralized-1";
  const body = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2099-01-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, body, "2026-09-01T00:00:00Z");
  writeScenario("started-at-neutralized", {
    issues: [{ number: 147, pull_request: null }],
    comments: { "147": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 147 },
  });
}

// --- Scenario 27: a run_id containing path-traversal segments — schema-
// legal (run.schema.json's run_id is only {type:string, minLength:1}) —
// must not let --replay escape its own temp directory. shepherd round 1,
// Codex-confirmed (P1, severe): path.join(tmpRoot, run_id) with no
// containment check let such a run_id write files outside the mkdtempSync
// root entirely.
{
  const runIdEvil = "../../evil-replay-dir";
  const bodyEvil = {
    schema: 2, run_id: runIdEvil, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idxEvil, record: rrEvil } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runIdEvil, bodyEvil, "2026-09-01T00:00:00Z");
  writeScenario("replay-path-traversal", {
    issues: [{ number: 139, pull_request: null }],
    comments: { "139": [idxEvil, rrEvil] },
    commits: {},
    meta: { runId: runIdEvil, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 139 },
  });
}

// --- Scenario 28: firstSeen must take the EARLIEST of check-suite and
// merged_at, never merged_at unconditionally — shepherd round 1,
// Codex-confirmed (P2): a commit visible via check-suite well BEFORE its
// PR eventually merges flipped from visible to not-visible for the SAME
// --as-of cutoff once merged_at started being preferred unconditionally,
// breaking the immutable-cutoff property first_seen exists to guarantee.
{
  const runId = "run-postfix-early-checksuite-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T00:01:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 505, url: "https://example.invalid/pr/505" },
    evidence_comments: [],
    promotion: { head: "5".repeat(40), promoted_at: "2026-09-01T00:10:00Z", gate_fingerprint: "early" },
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  const promotedCommit = { sha: "5".repeat(40), commit: { committer: { date: "2026-09-01T00:10:00Z" } }, author: { id: TRUSTED_ORCHESTRATOR } };
  // Check-suite ran (visible) well before the eventual merge.
  const humanCommit = { sha: "9".repeat(40), commit: { committer: { date: "2026-09-01T00:20:00Z" } }, author: { id: 42 } };
  writeScenario("postfix-early-checksuite", {
    issues: [{ number: 140, pull_request: null }],
    comments: { "140": [idx, rr] },
    commits: { "505": [promotedCommit, humanCommit] },
    ...mergedPrSeen(humanCommit.sha, 507, "2026-09-01T01:00:00Z"),
    ...checkSuiteSeen(humanCommit.sha, ["2026-09-01T00:15:00Z"]),
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 140 },
  });
}

// --- Scenario 29: two stage_transitions entries share seq/prev_digest/
// CONTENT but disagree on their own digest field (one correct, one
// corrupted) — shepherd round 1, Codex-confirmed (P2): a content-only
// duplicate comparison still treated these as the same entry and silently
// discarded the corrupted one before verifyChain's per-entry digest check
// ever ran on it, hiding tampering evidence instead of reporting it.
{
  const runId = "run-digest-mismatch-duplicate-1";
  const base = chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" }]);
  const validContent = { stage: "claim", entered_at: "2026-09-01T00:01:00Z" };
  const validDigest = entryDigest(validContent, base[0].digest);
  const validEntry = { ...validContent, seq: 1, digest: validDigest, prev_digest: base[0].digest };
  const corruptEntry = { ...validContent, seq: 1, digest: "0".repeat(64), prev_digest: base[0].digest };
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: [...base, validEntry, corruptEntry],
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("digest-mismatch-duplicate", {
    issues: [{ number: 141, pull_request: null }],
    comments: { "141": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 141 },
  });
}

// --- Scenario 30: an evidence marker edited from round=1 to round=1junk —
// shepherd round 1, Codex-confirmed (P2): the payload digest never covers
// the marker line itself, and Number.parseInt("1junk",10)=1 silently
// accepted the edit as round:1 before the regex was tightened.
{
  const runId = "run-marker-round-tamper-1";
  const roundPayload = { passes: [pass("codex-cli", [])], adjudication: { schema: 2, run_id: runId, stage: "review", round: 1, adjudications: [] } };
  const ev = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, roundPayload, "2026-09-01T00:03:00Z");
  ev.body = ev.body.replace("round=1 seq=1", "round=1junk seq=1");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null,
    evidence_comments: [
      evidenceIndexEntry(ev, TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, payloadDigest(JSON.stringify(roundPayload))),
    ],
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("marker-round-tamper", {
    issues: [{ number: 142, pull_request: null }],
    comments: { "142": [idx, rr, ev] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 142 },
  });
}

// --- Scenario 31: a trusted run-index marker with a NON-canonical tuple
// (stage=claim instead of the grammar's reserved kickoff/issue/-/1) —
// shepherd round 1, Codex-confirmed (P2): discovery checked only the
// marker kind, accepting a shape the protocol never sanctions.
{
  const runId = "run-noncanonical-index-1";
  const bodyDoc = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const bodyDocFull = { ...bodyDoc, ...deriveDefaultChains(bodyDoc) };
  const recordText = JSON.stringify(bodyDocFull);
  const recordMarkerText = marker("run-record", runId, "kickoff", "issue", null, 1);
  const record = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${recordMarkerText}\n\${fence(recordText)}\`, "2026-09-01T00:00:00Z");
  const indexPayload = {
    run_id: runId, initiated_by: bodyDocFull.initiated_by, branch: null,
    run_record: { id: String(record.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator" },
  };
  const badIndexMarkerText = marker("run-index", runId, "claim", "issue", null, 1);
  const index = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${badIndexMarkerText}\n\${fence(JSON.stringify(indexPayload))}\`, "2026-09-01T00:00:00Z");
  writeScenario("noncanonical-index", {
    issues: [{ number: 143, pull_request: null }],
    comments: { "143": [index, record] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 143 },
  });
}

// --- Scenario 32: rounds posted challenge-r1, review-r1, challenge-r2 (in
// THAT chronological order) must render in that order — shepherd round 1,
// Codex-confirmed (P2): sorting by stage name alphabetically grouped both
// challenge rounds before review regardless of a remediation loop's real
// posting order.
{
  const runId = "run-chronological-rounds-1";
  const payload1 = { passes: [pass("codex-cli", [])], adjudication: { schema: 2, run_id: runId, stage: "challenge", round: 1, adjudications: [] } };
  const ev1 = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "challenge", "issue", 1, 1, payload1, "2026-09-01T00:01:00Z");
  const payload2 = { passes: [pass("codex-cli", [])], adjudication: { schema: 2, run_id: runId, stage: "review", round: 1, adjudications: [] } };
  const ev2 = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, payload2, "2026-09-01T00:02:00Z");
  const payload3 = { passes: [pass("codex-cli", [])], adjudication: { schema: 2, run_id: runId, stage: "challenge", round: 2, adjudications: [] } };
  const ev3 = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "challenge", "issue", 2, 1, payload3, "2026-09-01T00:03:00Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null,
    evidence_comments: [
      evidenceIndexEntry(ev1, TRUSTED_ORCHESTRATOR, "orchestrator", runId, "challenge", "issue", 1, 1, payloadDigest(JSON.stringify(payload1))),
      evidenceIndexEntry(ev2, TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, payloadDigest(JSON.stringify(payload2))),
      evidenceIndexEntry(ev3, TRUSTED_ORCHESTRATOR, "orchestrator", runId, "challenge", "issue", 2, 1, payloadDigest(JSON.stringify(payload3))),
    ],
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("chronological-rounds", {
    issues: [{ number: 144, pull_request: null }],
    comments: { "144": [idx, rr, ev1, ev2, ev3] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 144 },
  });
}

// --- Scenario 33: a bot-authored post-promotion commit must never count
// as a "post-ready HUMAN fix" — shepherd round 1, Codex-confirmed (P2):
// every post-promotion commit counted regardless of author.
{
  const runId = "run-postfix-bot-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T00:01:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 508, url: "https://example.invalid/pr/508" },
    evidence_comments: [],
    promotion: { head: "7".repeat(40), promoted_at: "2026-09-01T00:10:00Z", gate_fingerprint: "bot" },
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  const promotedCommit = { sha: "7".repeat(40), commit: { committer: { date: "2026-09-01T00:10:00Z" } }, author: { id: TRUSTED_ORCHESTRATOR } };
  const botCommit = { sha: "e".repeat(40), commit: { committer: { date: "2026-09-01T00:20:00Z" } }, author: { id: 99, type: "Bot" } };
  writeScenario("postfix-bot", {
    issues: [{ number: 145, pull_request: null }],
    comments: { "145": [idx, rr] },
    commits: { "508": [promotedCommit, botCommit] },
    ...mergedPrSeen(botCommit.sha, 509, "2026-09-01T00:20:00Z"),
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 145 },
  });
}

// --- Scenario 34: a comment physically posted on the PR (fetched via the
// PR's own comment list) whose marker falsely claims dest=issue —
// shepherd round 1, Codex-confirmed (P2): assembleListedEvidence checked
// only the marker's self-declared destination against the run record's
// listed destination, never against which endpoint actually returned the
// comment.
{
  const runId = "run-marker-dest-mismatch-1";
  const stagePayload = { passes: [pass("codex-cli", [])], adjudication: { schema: 2, run_id: runId, stage: "review", round: 1, adjudications: [] } };
  const misplacedComment = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, stagePayload, "2026-09-01T00:03:00Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null,
    pr: { number: 622, url: "https://example.invalid/pr/622" },
    evidence_comments: [{
      id: String(misplacedComment.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator",
      digest: payloadDigest(JSON.stringify(stagePayload)),
      marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 },
    }],
    pr_bindings: chain([{ number: 622, url: "https://example.invalid/pr/622", bound_at: "2026-09-01T00:00:00Z" }]),
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("marker-dest-mismatch", {
    issues: [{ number: 146, pull_request: null }],
    comments: { "146": [idx, rr], "622": [misplacedComment] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 146 },
  });
}

// --- Scenario 35: a registry commit whose check-suite ran EARLY (on its
// own feature branch, before merge) must not be treated as in-effect
// before it actually landed on the default branch — shepherd round 2,
// Codex-confirmed (P1): resolveRegistryTrustedActorIds previously reused
// firstSeen's MIN-of-(merged_at, any check-suite), so the pre-merge
// check-suite time backdated the revision's effective date. A run kicked
// off AFTER the check-suite time but BEFORE the merge must see NO
// registry opinion yet (falls back to full CLI trust), not the narrowed
// set the commit eventually establishes.
{
  const narrowSha = "f".repeat(40);
  const registryCommits = [{ sha: narrowSha }];
  const registryContents = {
    [narrowSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [OTHER_TRUSTED] })).toString("base64"),
  };
  const runId = "run-registry-premerge-checksuite-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:10:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:10:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:10:00Z");
  writeScenario("registry-premerge-checksuite", {
    issues: [{ number: 148, pull_request: null }],
    comments: { "148": [idx, rr] },
    commits: {},
    registry_commits: registryCommits,
    registry_contents: registryContents,
    // Check-suite ran on the feature branch well BEFORE kickoff (would
    // wrongly backdate under the old design); the actual merge lands
    // AFTER kickoff, so this revision is correctly not yet in effect.
    ...checkSuiteSeen(narrowSha, ["2026-09-01T00:00:00Z"]),
    ...mergedPrSeen(narrowSha, 610, "2026-09-01T00:20:00Z"),
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 148 },
  });
}

// --- Scenario 36: the registry-revision mechanism works against a
// default branch that isn't literally "main" — shepherd round 2,
// Codex-confirmed (P2): sha=main was hardcoded, so a repo using a
// different default branch name would silently fall back to full CLI
// trust via the unavailable-registry path instead of erroring OR working.
// Proves the narrowing still applies once the branch is resolved
// dynamically.
{
  const narrowSha = "9".repeat(40);
  const registryCommits = [{ sha: narrowSha }];
  const registryContents = {
    [narrowSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [OTHER_TRUSTED] })).toString("base64"),
  };
  const runId = "run-registry-nonmain-branch-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:10:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:10:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:10:00Z");
  writeScenario("registry-nonmain-branch", {
    issues: [{ number: 149, pull_request: null }],
    comments: { "149": [idx, rr] },
    commits: {},
    default_branch: "trunk",
    registry_commits: registryCommits,
    registry_contents: registryContents,
    ...mergedPrSeen(narrowSha, 611, "2026-09-01T00:05:00Z"),
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 149 },
  });
}

// --- Scenario 37: a forged-author evidence marker (matches this run, but
// posted by an actor who is not this run's own trusted author) is
// reported under forged_comments, not silently dropped — shepherd round
// 2, Codex-confirmed (P2), verified directly against ai/schemas/README.md:
// "a forged-author comment: reported, ignored". The run itself still
// authenticates cleanly (an unrelated forged comment on the same issue
// does not invalidate the real run record).
{
  const runId = "run-forged-marker-report-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  const forgedPayload = { passes: [], adjudication: null };
  const forged = evidenceComment(UNTRUSTED, "impersonator", runId, "review", "issue", 1, 1, forgedPayload, "2026-09-01T00:05:00Z");
  writeScenario("forged-marker-report", {
    issues: [{ number: 150, pull_request: null }],
    comments: { "150": [idx, rr, forged] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 150, forgedId: forged.id },
  });
}

// --- Scenario 38: two run_ids that would normalize to the SAME path
// under plain path.resolve (a vs a/.) must not collide or cross-
// contaminate during one --replay batch — shepherd round 2, Codex-
// confirmed (P2). Both bare kickoff-only runs replay independently.
{
  const runIdA = "a";
  const bodyA = {
    schema: 2, run_id: runIdA, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idxA, record: rrA } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runIdA, bodyA, "2026-09-01T00:00:00Z");

  const runIdB = "a/.";
  const bodyB = {
    schema: 2, run_id: runIdB, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idxB, record: rrB } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runIdB, bodyB, "2026-09-01T00:00:00Z");

  writeScenario("replay-dir-collision", {
    issues: [{ number: 151, pull_request: null }, { number: 152, pull_request: null }],
    comments: { "151": [idxA, rrA], "152": [idxB, rrB] },
    commits: {},
    meta: { runIdA, runIdB, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumberA: 151, issueNumberB: 152 },
  });
}

// --- Scenario 39: an issue whose EARLIEST run is chain-broken
// (indeterminate) but whose trusted run-index still fixes a real,
// old kickoff time, followed by a later valid run inside a requested
// --since window — shepherd round 2, Codex-confirmed (P2): before the
// fix, firstKickoffEpoch saw kickoff:null for this issue (indeterminate
// runs were invisible to it), which bypassed the --since filter entirely
// and admitted an issue that actually predates the window.
{
  const runIdBroken = "run-since-indeterminate-first-1";
  const base = chain([{ stage: "kickoff", entered_at: "2026-08-01T00:00:00Z", exit: "claimed" }]);
  const forkA = { stage: "claim", entered_at: "2026-08-01T00:01:00Z", exit: "implementing" };
  const forkB = { stage: "explore", entered_at: "2026-08-01T00:01:05Z", exit: "planning" };
  const digestA = entryDigest(forkA, base[0].digest);
  const digestB = entryDigest(forkB, base[0].digest);
  const forked = [
    ...base,
    { ...forkA, seq: 1, digest: digestA, prev_digest: base[0].digest },
    { ...forkB, seq: 1, digest: digestB, prev_digest: base[0].digest },
  ];
  const bodyBroken = {
    schema: 2, run_id: runIdBroken, initiated_by: "human", started_at: "2026-08-01T00:00:00Z",
    stage_transitions: forked, interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idxBroken, record: rrBroken } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runIdBroken, bodyBroken, "2026-08-01T00:00:00Z");

  const runIdLater = "run-since-indeterminate-later-1";
  const bodyLater = {
    schema: 2, run_id: runIdLater, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T00:01:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 623, url: "https://example.invalid/pr/623" },
    evidence_comments: [],
    promotion: { head: "c".repeat(40), promoted_at: "2026-09-01T00:05:00Z", gate_fingerprint: "since" },
  };
  const { index: idxLater, record: rrLater } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runIdLater, bodyLater, "2026-09-01T00:00:00Z");

  writeScenario("since-indeterminate-first", {
    issues: [{ number: 153, pull_request: null }],
    comments: { "153": [idxBroken, rrBroken, idxLater, rrLater] },
    commits: {},
    meta: { runIdBroken, runIdLater, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 153 },
  });
}

// --- Scenario 40: an outcome_transitions[] chain with TWO chain- and
// digest-valid entries (capped, then ready-for-review) — shepherd round
// 2, Codex-confirmed (P1, severe): the chain was unbounded and
// deriveProjections trusts only the LAST entry, so this laundered a real
// failure into a success without breaking chain or projection
// verification (the flat outcome field is set to match the last entry,
// exactly as a real attack would need it to). A run reaches exactly one
// terminal outcome; this must now be rejected outright.
{
  const runId = "run-outcome-transitions-unbounded-1";
  const cappedContent = { outcome: "capped", at: "2026-09-01T00:05:00Z" };
  const cappedDigest = entryDigest(cappedContent, GENESIS);
  const cappedEntry = { ...cappedContent, seq: 0, digest: cappedDigest, prev_digest: GENESIS };
  const readyContent = { outcome: "ready-for-review", at: "2026-09-01T00:10:00Z" };
  const readyDigest = entryDigest(readyContent, cappedDigest);
  const readyEntry = { ...readyContent, seq: 1, digest: readyDigest, prev_digest: cappedDigest };
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 624, url: "https://example.invalid/pr/624" },
    evidence_comments: [],
    outcome_transitions: [cappedEntry, readyEntry],
    promotion: { head: "d".repeat(40), promoted_at: "2026-09-01T00:10:00Z", gate_fingerprint: "laundered" },
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("outcome-transitions-unbounded", {
    issues: [{ number: 154, pull_request: null }],
    comments: { "154": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 154 },
  });
}

// --- Scenario 41: an evidence marker claims destination=pr with a
// non-null round — shepherd round 3, Codex-confirmed (P2), verified
// against ai/schemas/README.md "Comment kinds": destination=pr is
// reserved for the per-stage rollup (round=null); every per-round
// comment is destination=issue. This entry is otherwise fully
// self-consistent (correctly fetched from the PR, matches its listed
// entry) — only the destination/round COMBINATION is illegal.
{
  const runId = "run-pr-dest-with-round-1";
  const stagePayload = { passes: [pass("codex-cli", [])], adjudication: { schema: 2, run_id: runId, stage: "review", round: 1, adjudications: [] } };
  const prRoundComment = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "pr", 1, 1, stagePayload, "2026-09-01T00:03:00Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null,
    pr: { number: 625, url: "https://example.invalid/pr/625" },
    evidence_comments: [{
      id: String(prRoundComment.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator",
      digest: payloadDigest(JSON.stringify(stagePayload)),
      marker: { run_id: runId, stage: "review", destination: "pr", round: 1, sequence: 1 },
    }],
    pr_bindings: chain([{ number: 625, url: "https://example.invalid/pr/625", bound_at: "2026-09-01T00:00:00Z" }]),
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("pr-dest-with-round", {
    issues: [{ number: 155, pull_request: null }],
    comments: { "155": [idx, rr], "625": [prRoundComment] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 155 },
  });
}

// --- Scenario 42: a post-promotion commit with no resolvable first_seen
// (no merged PR, no check-suite) must surface as
// post_ready_fix_indeterminate_count, and shepherd round 3,
// Codex-confirmed (P2): the human-readable --repo output must show it,
// not just the JSON form.
{
  const runId = "run-postfix-unresolvable-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T00:01:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 626, url: "https://example.invalid/pr/626" },
    evidence_comments: [],
    promotion: { head: "6".repeat(40), promoted_at: "2026-09-01T00:10:00Z", gate_fingerprint: "unresolvable" },
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  const promotedCommit = { sha: "6".repeat(40), commit: { committer: { date: "2026-09-01T00:10:00Z" } }, author: { id: TRUSTED_ORCHESTRATOR } };
  // No mergedPrSeen/checkSuiteSeen for this commit at all — firstSeen
  // resolves to null, unresolvable.
  const unresolvableCommit = { sha: "d".repeat(40), commit: { committer: { date: "2026-09-01T00:20:00Z" } }, author: { id: 42 } };
  writeScenario("postfix-unresolvable", {
    issues: [{ number: 156, pull_request: null }],
    comments: { "156": [idx, rr] },
    commits: { "626": [promotedCommit, unresolvableCommit] },
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 156 },
  });
}

// --- Scenario 43: a registry revision GRANTS an actor trust between the
// run-record's own post and its dependent run-index's post — shepherd
// round 3, Codex-confirmed (P2): the record-author trust check must
// authenticate against the RECORD's own created_at, not the index's later
// one. Built by hand (not runRecordComment, which stamps both comments
// with one shared createdAt) so record and index genuinely straddle the
// registry revision:
//   T0  2026-09-01T00:00:00Z  narrow revision lands (trusts OTHER_TRUSTED only)
//   T1  2026-09-01T00:10:00Z  run-record posted (TRUSTED_ORCHESTRATOR NOT yet trusted)
//   T2  2026-09-01T00:15:00Z  widen revision lands (adds TRUSTED_ORCHESTRATOR)
//   T3  2026-09-01T00:20:00Z  run-index posted (TRUSTED_ORCHESTRATOR now trusted)
// Before the fix, evaluating at the index's T3 would find TRUSTED_ORCHESTRATOR
// trusted and wrongly accept a record whose own kickoff had no such trust.
{
  const narrowSha = "1".repeat(40);
  const widenSha = "2".repeat(40);
  const registryCommits = [{ sha: widenSha }, { sha: narrowSha }]; // newest-first, as GitHub returns
  const registryContents = {
    [narrowSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [OTHER_TRUSTED] })).toString("base64"),
    [widenSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [OTHER_TRUSTED, TRUSTED_ORCHESTRATOR] })).toString("base64"),
  };
  const runId = "run-registry-trust-timing-1";
  const recordCreatedAt = "2026-09-01T00:10:00Z";
  const indexCreatedAt = "2026-09-01T00:20:00Z";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: recordCreatedAt,
    stage_transitions: chain([{ stage: "kickoff", entered_at: recordCreatedAt }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const body = { ...runBody, ...deriveDefaultChains(runBody) };
  const rm = marker("run-record", runId, "kickoff", "issue", null, 1);
  const rr = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${rm}\n\${fence(JSON.stringify(body))}\`, recordCreatedAt);
  const indexPayload = {
    run_id: runId, initiated_by: body.initiated_by, branch: null,
    run_record: { id: String(rr.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator" },
  };
  const im = marker("run-index", runId, "kickoff", "issue", null, 1);
  const idx = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${im}\n\${fence(JSON.stringify(indexPayload))}\`, indexCreatedAt);
  writeScenario("registry-trust-record-before-index", {
    issues: [{ number: 158, pull_request: null }],
    comments: { "158": [idx, rr] },
    commits: {},
    registry_commits: registryCommits,
    registry_contents: registryContents,
    commit_pulls: {
      [narrowSha]: [{ number: 611, merged_at: "2026-09-01T00:00:00Z" }],
      [widenSha]: [{ number: 612, merged_at: "2026-09-01T00:15:00Z" }],
    },
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 158 },
  });
}

// --- Scenario 44: a registry-touching commit with NO merging PR (only
// possible when the target repo permits direct pushes to its default
// branch — this repo's own ruleset blocks that, but --repo is generic)
// must void the WHOLE repo's registry history, not be silently skipped —
// shepherd round 4, Codex-confirmed (P1). A narrowing revision that WOULD
// exclude TRUSTED_ORCHESTRATOR exists and is independently resolvable, but
// because a second, unresolvable (direct-push) commit also touches the
// registry, the mechanism must admit "no registry opinion" entirely and
// fall back to full CLI trust — TRUSTED_ORCHESTRATOR stays trusted, not
// narrowed out by the (still real, still resolvable) other revision.
{
  const narrowSha = "5".repeat(40);
  const directPushSha = "7".repeat(40);
  const registryCommits = [{ sha: directPushSha }, { sha: narrowSha }]; // newest-first, as GitHub returns
  const registryContents = {
    [narrowSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [OTHER_TRUSTED] })).toString("base64"),
    // directPushSha's own content is never read — resolution fails before
    // ever reaching it, since it has no resolvable landing time at all.
  };
  const runId = "run-registry-direct-push-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:30:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:30:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:30:00Z");
  writeScenario("registry-direct-push", {
    issues: [{ number: 159, pull_request: null }],
    comments: { "159": [idx, rr] },
    commits: {},
    registry_commits: registryCommits,
    registry_contents: registryContents,
    // narrowSha DOES have a merging PR (independently resolvable);
    // directPushSha deliberately has none: no commit_pulls entry for it at
    // all, so the fake gh stub's empty-array fallback matches a real
    // commits-sha-pulls response for a commit with no merging PR.
    commit_pulls: {
      [narrowSha]: [{ number: 613, merged_at: "2026-09-01T00:00:00Z" }],
    },
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 159 },
  });
}

// --- Scenario 45: a run's last activity is EXACTLY staleAfterDays before
// --as-of (to the millisecond) — shepherd round 4, Codex-confirmed (P2):
// specs/dev-flow-v2.md defines staleness as "no run-record update for
// [convergence].stale_after", a duration requirement already satisfied at
// exact equality, but the strict greater-than comparison this replaced
// left the run non-terminal for one extra millisecond at a reproducible
// boundary.
{
  const runId = "run-stale-boundary-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-08-25T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-08-25T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-08-25T00:00:00Z");
  writeScenario("stale-boundary", {
    issues: [{ number: 160, pull_request: null }],
    comments: { "160": [idx, rr] },
    commits: {},
    // Default --stale-after-days is 7; 2026-08-25T00:00:00Z + 7 days is
    // exactly 2026-09-01T00:00:00Z.
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 160, atBoundary: "2026-09-01T00:00:00Z", beforeBoundary: "2026-08-31T23:59:59.999Z" },
  });
}

// --- Scenario 46: --run --as-of C must cutoff-filter orphan/forged
// reports the same way it filters everything else historical — shepherd
// round 4, Codex-confirmed (P2): an orphan comment posted AFTER C
// previously still appeared in the "as of C" trajectory, so re-running the
// same --as-of C later (after the comment landed) could change the
// report even though nothing about the as-of-C observation should.
{
  const runId = "run-orphan-cutoff-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "claim", entered_at: "2026-09-01T00:01:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  // A trusted-author evidence-shaped comment, correctly marked for this
  // run, but never added to evidence_comments[] — an orphan by design.
  // Posted well AFTER the cutoff this scenario queries with.
  const orphan = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "claim", "issue", null, 1, { note: "posted late" }, "2026-09-05T00:00:00Z");
  writeScenario("orphan-cutoff", {
    issues: [{ number: 161, pull_request: null }],
    comments: { "161": [idx, rr, orphan] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 161 },
  });
}

// --- Scenario 47: a run-record comment's marker is edited to a
// non-reserved tuple (stage/dest/round/seq other than kickoff/issue/-/1)
// while keeping kind=run-record and the same run_id — shepherd round 4,
// Codex-confirmed (P2): checking only kind and run_id let this pass as
// the run's authenticated run-record, exactly the gap round 1 already
// closed for run-INDEX discovery but missed on this sibling check.
{
  const runId = "run-record-marker-tamper-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  // Rewrite the record comment's marker line only, keeping its JSON
  // payload (and the index's own pointer to this same comment id) intact.
  const tamperedMarker = marker("run-record", runId, "review", "pr", 1, 9);
  const payloadOnly = rr.body.slice(rr.body.indexOf("\n") + 1);
  rr.body = \`\${tamperedMarker}\n\${payloadOnly}\`;
  writeScenario("record-marker-tamper", {
    issues: [{ number: 162, pull_request: null }],
    comments: { "162": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 162 },
  });
}

// --- Scenario 48: the run-index's OWN author trust is now decided at the
// RECORD's kickoff time too, not just the record author's — shepherd
// round 5, Codex-confirmed (P2). Built with DIFFERENT actors for the
// index and the record (unlike runRecordComment()'s single-actor pair,
// which shadows this check behind the pre-existing record-author one) so
// this isolates the new check cleanly: the record's own author
// (TRUSTED_ORCHESTRATOR) stays registry-trusted throughout, but the
// index's own author (OTHER_TRUSTED) is narrowed out by a registry
// revision already in effect at the record's post time.
{
  const narrowSha = "8".repeat(40);
  const registryCommits = [{ sha: narrowSha }];
  const registryContents = {
    [narrowSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [TRUSTED_ORCHESTRATOR] })).toString("base64"),
  };
  const runId = "run-index-author-narrowed-1";
  const recordCreatedAt = "2026-09-01T00:10:00Z";
  const indexCreatedAt = "2026-09-01T00:10:30Z";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: recordCreatedAt,
    stage_transitions: chain([{ stage: "kickoff", entered_at: recordCreatedAt }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const body = { ...runBody, ...deriveDefaultChains(runBody) };
  const rm = marker("run-record", runId, "kickoff", "issue", null, 1);
  const rr = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${rm}\n\${fence(JSON.stringify(body))}\`, recordCreatedAt);
  const indexPayload = {
    run_id: runId, initiated_by: body.initiated_by, branch: null,
    run_record: { id: String(rr.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator" },
  };
  const im = marker("run-index", runId, "kickoff", "issue", null, 1);
  // Index posted by OTHER_TRUSTED, a genuinely different GitHub actor from
  // the record's own author — the index protocol never requires them to
  // match, only that the index's NAMED author_actor_id (checked above)
  // agrees with the record comment's own current author.
  const idx = comment(OTHER_TRUSTED, "other-orchestrator", \`\${im}\n\${fence(JSON.stringify(indexPayload))}\`, indexCreatedAt);
  writeScenario("index-author-narrowed", {
    issues: [{ number: 163, pull_request: null }],
    comments: { "163": [idx, rr] },
    commits: {},
    registry_commits: registryCommits,
    registry_contents: registryContents,
    commit_pulls: {
      [narrowSha]: [{ number: 614, merged_at: "2026-09-01T00:00:00Z" }],
    },
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR, OTHER_TRUSTED], issueNumber: 163 },
  });
}

// --- Scenario 49: a trusted run-index whose canonical marker survives but
// whose fenced payload is missing — shepherd round 5, Codex-confirmed
// (P1): markedComments() drops any marked comment with no parseable
// payload BEFORE this function ever sees it, so this previously looked
// identical to "no index ever existed" (issue silently absent from the
// cohort) instead of being reported as tampered evidence.
{
  const runId = "run-index-no-fence-1";
  const noFenceIndex = comment(TRUSTED_ORCHESTRATOR, "orchestrator", marker("run-index", runId, "kickoff", "issue", null, 1), "2026-09-01T00:00:00Z");
  writeScenario("index-no-fence", {
    issues: [{ number: 164, pull_request: null }],
    comments: { "164": [noFenceIndex] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 164 },
  });
}

// --- Scenario 50: with no --as-of given, discovery must use a FROZEN
// "now" cutoff (like an explicit --as-of would), not the unbounded
// cutoff=Infinity a null asOf previously produced — shepherd round 5,
// Codex-confirmed (P2). Proven directly rather than by racing a real
// scan: a run-record comment dated far in the future is exactly the case
// an Infinity cutoff would have admitted (nothing excluded) but any real,
// frozen "now" correctly excludes (it has not happened yet).
{
  const runId = "run-future-dated-1";
  const farFuture = "2099-01-01T00:00:00Z";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: farFuture,
    stage_transitions: chain([{ stage: "kickoff", entered_at: farFuture }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, farFuture);
  writeScenario("future-dated", {
    issues: [{ number: 165, pull_request: null }],
    comments: { "165": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 165 },
  });
}

// --- Scenario 51: a chain-consistent record claims ready-for-review with
// a promotion but NO reconstructed PR binding (pr_bindings: [], pr: null)
// — shepherd round 5, Codex-confirmed (P2): this previously passed
// reconstructAsOf's own consistency check (which required only
// promotion, not pr) and reached computePostReadyFix, which
// unconditionally reads readyRun.state.pr.number — an uncaught TypeError
// that aborted the ENTIRE --repo metric over this one malformed record.
{
  const runId = "run-ready-no-pr-binding-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T00:01:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: null,
    evidence_comments: [],
    promotion: { head: "9".repeat(40), promoted_at: "2026-09-01T00:10:00Z", gate_fingerprint: "no-pr-binding" },
    pr_bindings: [],
    outcome_transitions: chain([{ outcome: "ready-for-review", at: "2026-09-01T00:10:00Z" }]),
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("ready-no-pr-binding", {
    issues: [{ number: 166, pull_request: null }],
    comments: { "166": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 166 },
  });
}

// --- Scenario 52: challenge resolved to cap 0 (disabled) — a valid
// "capped: disabled" stage_transitions exit with legitimately ZERO round
// comments — shepherd round 5, Codex-confirmed (P1): replay's old
// round-evidence-only stage filter skipped this stage entirely, so a
// candidate policy that ENABLES challenge (cap > 0) never got compared
// against it at all, reporting a false policy-equivalence instead of the
// real disagreement.
{
  const runId = "run-challenge-capped-disabled-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "challenge", entered_at: "2026-09-01T00:01:00Z", exit: "capped: disabled" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("challenge-capped-disabled", {
    issues: [{ number: 167, pull_request: null }],
    comments: { "167": [idx, rr] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 167 },
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
duplicate_id="$(meta duplicate-marker .meta.duplicateId)"
echo "$after_cutoff" | jq -e --argjson id "$duplicate_id" '[.orphan_comments[].id] | index($id) != null' >/dev/null ||
    fail "duplicate-marker: expected the unlisted duplicate to surface as an orphan, not silently vanish"

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
echo "$out" | grep -qi "tamper" || fail "tamper: expected a tamper-shaped reason, got: $out"

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
import { readFileSync, writeFileSync, readdirSync, existsSync } from "node:fs";
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
// Records every --current-head this fake was invoked with, keyed by
// stage, so the bash test can assert on it afterward — proving
// dev-flow-stats.mjs derives a real head for a non-promoted (capped) run
// instead of an invented all-zero placeholder (challenge round 2, P1).
const headLogPath = process.env.FAKE_EXIT_HEAD_LOG;
if (headLogPath) {
  const prior = existsSync(headLogPath) ? JSON.parse(readFileSync(headLogPath, "utf8")) : {};
  prior[args.stage] = args["current-head"];
  // shepherd round 1, Codex-confirmed (P1): --repo-root was hardcoded to
  // process.cwd(), never threaded from a --repo-root CLI flag — logged
  // here the same way current-head already is, so the bash test can
  // assert dev-flow-stats.mjs actually passes an explicit value through.
  prior.repo_root = args["repo-root"];
  writeFileSync(headLogPath, JSON.stringify(prior));
}
const passesDir = path.join(args.run, "passes");
const files = existsSync(passesDir) ? readdirSync(passesDir) : [];
const rounds = new Set(
  files.filter((f) => f.startsWith(`${args.stage}-r`)).map((f) => f.match(/-r(\d+)-/)[1]),
);
const policyText = readFileSync(args.policy, "utf8");
const capMatch = policyText.match(new RegExp(`${args.stage}_cap\\s*=\\s*(\\d+)`));
const cap = capMatch ? Number(capMatch[1]) : 99;
// shepherd round 2: on-demand indeterminate verdict, matching
// dev-flow-exit.mjs's own real "could not verify" contract (JSON
// outcome:"indeterminate", exit 2) — proves dev-flow-stats.mjs
// propagates it instead of diffing it like an ordinary recomputed
// outcome.
if (process.env.FAKE_EXIT_INDETERMINATE) {
  const verdict = { stage: args.stage, outcome: "indeterminate", reason: "fake-cannot-verify" };
  if (args.json) console.log(JSON.stringify(verdict));
  process.exit(2);
}
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
export FAKE_EXIT_HEAD_LOG="$tmp/fake-exit-heads.json"
rm -f "$FAKE_EXIT_HEAD_LOG"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --replay --policy "$tmp/policy-matching.toml" --exit-script "$tmp/fake-exit-script.mjs" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.[0].diffs | length == 0' >/dev/null || fail "replay (matching policy): expected no diffs, got: $out"

echo "== replay derives a real current-head for a capped (never-promoted) run, not an all-zero placeholder =="
[ -f "$FAKE_EXIT_HEAD_LOG" ] || fail "replay head log was never written — the fake exit script was never invoked"
# Each stage's OWN latest round has its own reviewed_head in the real
# omator#397 data (the code moved between rounds) — challenge round 4 and
# review round 3 are genuinely different heads.
challenge_head="$(jq -r '.challenge' "$FAKE_EXIT_HEAD_LOG")"
review_head="$(jq -r '.review' "$FAKE_EXIT_HEAD_LOG")"
[ "$challenge_head" = "416d69fabeb3ad1589f706e9079ca87a12727950" ] || fail "expected challenge r4's real reviewed_head, got: $challenge_head"
[ "$review_head" = "cf2ab8402f14a0337ca6e905deae58ceb86a0785" ] || fail "expected review r3's real reviewed_head, got: $review_head"
unset FAKE_EXIT_HEAD_LOG

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

echo "== post-ready fix detection is position-based: catches a cherry-picked (older-timestamped) commit a timestamp check would miss =="
export DFSTATS_DB="$tmp/scenarios/postfix-cherrypick.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.unattended_success_count == 1 and .post_ready_fix_count == 1' >/dev/null || fail "postfix-cherrypick: expected the older-timestamped post-promotion commit to still be caught"

echo "== --as-of between a stage-exit and its later promotion reads as in-flight, never borrows the future ready-for-review outcome =="
export DFSTATS_DB="$tmp/scenarios/future-outcome.json"
between="$(node scripts/dev-flow-stats.mjs --repo o/r --run run-future-outcome-1 --trusted-actor-id 9001 --as-of 2026-09-01T00:10:00Z --json)"
echo "$between" | jq -e '.outcome == null' >/dev/null || fail "future-outcome: expected in-flight (null) outcome between the exit text and the actual promotion, got: $between"
after="$(node scripts/dev-flow-stats.mjs --repo o/r --run run-future-outcome-1 --trusted-actor-id 9001 --as-of 2026-09-01T00:25:00Z --json)"
echo "$after" | jq -e '.outcome == "ready-for-review"' >/dev/null || fail "future-outcome: expected ready-for-review once the actual promotion is within cutoff"

echo "== --since bounds cohort membership by first kickoff, matching the closed-cohort spec =="
export DFSTATS_DB="$tmp/scenarios/cohort.json"
before="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --since 2026-08-01T00:00:00Z --json)"
echo "$before" | jq -e '.cohort_size == 2' >/dev/null || fail "since (before both kickoffs): expected both issues still in the window"
after="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --since 2026-09-02T00:00:00Z --json)"
echo "$after" | jq -e '.cohort_size == 0' >/dev/null || fail "since (after both kickoffs): expected the window to exclude both issues"

echo "== deleted run-record comment (index survives): indeterminate, never silently 'no run happened' =="
export DFSTATS_DB="$tmp/scenarios/deleted-record.json"
metric_out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$metric_out" | jq -e '.indeterminate_count == 1' >/dev/null || fail "deleted-record: expected the issue to be reported indeterminate, not silently absent from the cohort"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run run-deleted-record-1 --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "deleted-record: expected exit 3 (indeterminate), got $rc: $out"
echo "$out" | grep -qi "deleted-entry tampering\|no longer exists" || fail "deleted-record: expected a deleted-entry-tampering reason, got: $out"

echo "== a legitimately edited run-record (content changed after the index was created) still authenticates — the P0 regression =="
export DFSTATS_DB="$tmp/scenarios/edited-record.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run run-edited-record-1 --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.stage_transitions | length == 2' >/dev/null || fail "edited-record: expected the post-edit chain (2 transitions) to be visible, got: $out"

echo "== terminal outcome derivation trusts body.outcome directly, not a magic-word prefix on the exit text =="
export DFSTATS_DB="$tmp/scenarios/freetext-exit.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run run-freetext-exit-1 --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.outcome == "escalated"' >/dev/null || fail "freetext-exit: expected escalated outcome despite non-magic-word exit text, got: $out"

echo "== post-ready fix is checked independently of pre-ready interventions (a second, separate failure measure) =="
export DFSTATS_DB="$tmp/scenarios/postfix-with-intervention.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.unattended_success_count == 0 and .post_ready_fix_count == 1' >/dev/null || fail "postfix-with-intervention: expected success=0 (intervention present) but post_ready_fix_count still 1, got: $out"

echo "== invalid --as-of / --since / --stale-after-days are usage errors, not silent NaN comparisons =="
export DFSTATS_DB="$tmp/scenarios/happy.json"
for flag_args in "--as-of not-a-date" "--since not-a-date" "--stale-after-days not-a-number" "--stale-after-days -5"; do
    set +e
    out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 $flag_args 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "invalid arg ($flag_args): expected exit 2, got $rc: $out"
done

echo "== shepherd round 3: a timestamp that Date.parse() accepts but is not the documented ISO-8601 (Z) form is still a usage error =="
for flag_args in "--as-of 0" "--as-of 09/03/2026" "--as-of 2026-09-03T12:00:00" "--since 2026-09-03T12:00:00+00:00"; do
    set +e
    out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 $flag_args 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "parseable-but-non-ISO-8601 arg ($flag_args): expected exit 2, got $rc: $out"
done

echo "== shepherd round 4: a syntactically-ISO but CALENDAR-invalid timestamp (Date.parse silently normalizes it to a different day) is still a usage error =="
for flag_args in "--as-of 2026-02-30T00:00:00Z" "--as-of 2026-13-01T00:00:00Z" "--as-of 2026-01-01T24:00:00Z" "--since 2026-02-30T00:00:00Z"; do
    set +e
    out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 $flag_args 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "calendar-invalid ISO-8601 arg ($flag_args): expected exit 2, got $rc: $out"
done
echo "== ...but a genuinely valid leap-day timestamp is still accepted =="
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --as-of 2024-02-29T00:00:00Z --json)"
echo "$out" | jq -e '.cohort_size == 0' >/dev/null || fail "leap-day --as-of: expected acceptance (empty cohort against an empty repo), got: $out"

echo "== review round 2: a value-taking flag followed by nothing (or another flag) is a usage error, not a silent default =="
for flag_args in "--as-of" "--since" "--stale-after-days"; do
    set +e
    out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 $flag_args --json 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "missing-value ($flag_args --json): expected exit 2, got $rc: $out"
    echo "$out" | grep -qi "requires a value" || fail "missing-value ($flag_args --json): expected a 'requires a value' reason, got: $out"
done

echo "== a listed evidence entry naming a foreign run_id in its own marker is rejected, not silently merged =="
export DFSTATS_DB="$tmp/scenarios/foreign-evidence.json"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run run-foreign-evidence-1 --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "foreign-evidence: expected exit 3 (indeterminate), got $rc: $out"
echo "$out" | grep -qi "does not bind to run\|tamper" || fail "foreign-evidence: expected a binding-mismatch reason, got: $out"

echo "== conflicting payloads under one marker resolve by lowest id, unconditionally (reverted round-1 regression) =="
export DFSTATS_DB="$tmp/scenarios/conflicting-dup.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run run-conflicting-dup-1 --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.rounds | length == 1' >/dev/null || fail "conflicting-dup: expected the round to resolve (not indeterminate), got: $out"
echo "$out" | jq -e '.rounds[0].finding_count == 1' >/dev/null || fail "conflicting-dup: expected the lowest-id (first) comment's own finding to win"

echo "== replay uses each stage's OWN reviewed head, even for a promoted run whose final head is later =="
export DFSTATS_DB="$tmp/scenarios/stage-heads.json"
export FAKE_EXIT_HEAD_LOG="$tmp/fake-exit-heads-2.json"
rm -f "$FAKE_EXIT_HEAD_LOG"
node scripts/dev-flow-stats.mjs --repo o/r --replay --policy "$tmp/policy-matching.toml" --exit-script "$tmp/fake-exit-script.mjs" --trusted-actor-id 9001 --json >/dev/null
recorded_challenge_head="$(jq -r '.challenge' "$FAKE_EXIT_HEAD_LOG")"
[ "$recorded_challenge_head" = "$(printf 'a%.0s' $(seq 1 40))" ] || fail "stage-heads: expected challenge's own reviewed_head, got: $recorded_challenge_head (not the later promotion.head)"
unset FAKE_EXIT_HEAD_LOG

echo "== post-ready fix count respects --as-of: a later commit does not retroactively change an earlier cutoff's result =="
export DFSTATS_DB="$tmp/scenarios/postfix.json"
early="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --as-of 2026-09-01T00:15:00Z --json)"
echo "$early" | jq -e '.post_ready_fix_count == 0' >/dev/null || fail "postfix as-of before the fix commit: expected post_ready_fix_count 0, got: $early"
late="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --as-of 2026-09-01T00:25:00Z --json)"
echo "$late" | jq -e '.post_ready_fix_count == 1' >/dev/null || fail "postfix as-of after the fix commit: expected post_ready_fix_count 1, got: $late"

echo "== review round 1: a resumed writer's byte-identical retry normalizes to one entry and validates cleanly (not a broken chain) =="
export DFSTATS_DB="$tmp/scenarios/dup-retry.json"
run_id="$(meta dup-retry .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.outcome == null' >/dev/null || fail "dup-retry: expected the run to harvest cleanly (in-flight), got: $out"

echo "== round 4 of #663: an edited evidence_registrations[] entry breaks its own chain, rejected like any other tampered entry =="
export DFSTATS_DB="$tmp/scenarios/edited-registration.json"
run_id="$(meta edited-registration .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "edited-registration: expected exit 3 (indeterminate), got $rc: $out"
echo "$out" | grep -qi "evidence_registrations.*chain broken\|tamper" || fail "edited-registration: expected an evidence_registrations chain-break reason, got: $out"

echo "== round 4 of #663: evidence_comments[] naming a different comment than its own (untouched, valid) chain fails closed =="
export DFSTATS_DB="$tmp/scenarios/swapped-comment-id.json"
run_id="$(meta swapped-comment-id .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "swapped-comment-id: expected exit 3 (indeterminate), got $rc: $out"
echo "$out" | grep -qi "evidence_comments.*does not match\|out-of-band edit" || fail "swapped-comment-id: expected an evidence_comments/evidence_registrations mismatch reason, got: $out"

echo "== review round 1: a human-initiated re-kick after a failed run is itself an intervention, even with empty interventions[] on both runs =="
export DFSTATS_DB="$tmp/scenarios/multirun-human-rekick.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.cohort_size == 1 and .unattended_success_count == 0' >/dev/null || fail "multirun-human-rekick: expected the human re-kick to count as an intervention (not unattended success), got: $out"

echo "== review round 1: a FOREMAN-initiated retry after a failed run is NOT an intervention (explicit spec carve-out, negative control) =="
export DFSTATS_DB="$tmp/scenarios/multirun-foreman-retry.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --trusted-actor-id 9099 --json)"
echo "$out" | jq -e '.cohort_size == 1 and .unattended_success_count == 1' >/dev/null || fail "multirun-foreman-retry: expected the Foreman retry to still count as unattended success, got: $out"

echo "== review round 1: an --as-of read does not falsely report a PR-side evidence_comments[] entry as deleted-entry tampering =="
export DFSTATS_DB="$tmp/scenarios/asof-pr-rollup.json"
run_id="$(meta asof-pr-rollup .meta.runId)"
# The prior bug fetched PR comments using the AS-OF-FILTERED pr (state.pr)
# rather than the live record.body.pr, so any cutoff still resolving a
# non-null pr should reproduce it once the run's own listed
# evidence_comments[] entry lives on the PR thread — before this fix, BOTH
# cutoffs below threw "deleted-entry tampering" (exit 3) rather than
# resolving cleanly, since the fake gh stub only serves PR comments when
# actually asked for them.
before="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --as-of 2026-09-01T01:00:00Z --json)"
echo "$before" | jq -e '.outcome == null' >/dev/null || fail "asof-pr-rollup: expected a clean, tampering-free in-flight reconstruction before the promotion cutoff, got: $before"
after="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --as-of 2026-09-01T02:25:00Z --json)"
echo "$after" | jq -e '.outcome == "ready-for-review"' >/dev/null || fail "asof-pr-rollup: expected a clean, tampering-free ready-for-review reconstruction after the promotion cutoff, got: $after"

echo "== review round 2: an evidence_comments[] entry naming a DIFFERENT trusted actor than the run's own author is a forged-author entry, not merely self-consistent =="
export DFSTATS_DB="$tmp/scenarios/forged-author.json"
run_id="$(meta forged-author .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --trusted-actor-id 9002 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "forged-author: expected exit 3 (indeterminate), got $rc: $out"
echo "$out" | grep -qi "not this run's own trusted author\|forged-author" || fail "forged-author: expected a forged-author reason, got: $out"

echo "== review round 2: fresh evidence_registrations activity keeps a long-in-one-stage run out of stale-abandoned terminalization =="
export DFSTATS_DB="$tmp/scenarios/active-not-stale.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --as-of 2026-09-09T00:00:00Z --stale-after-days 7 --json)"
echo "$out" | jq -e '.cohort_size == 0' >/dev/null || fail "active-not-stale: expected the run to stay open (not stale-terminalized, so not yet in the closed cohort), got: $out"

echo "== review round 3: a run-record whose marker and JSON payload declare different run_id values is rejected as an identity mismatch =="
export DFSTATS_DB="$tmp/scenarios/marker-payload-mismatch.json"
run_id="$(meta marker-payload-mismatch .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "marker-payload-mismatch: expected exit 3 (indeterminate), got $rc: $out"
echo "$out" | grep -qi "identity mismatch\|declares run_id" || fail "marker-payload-mismatch: expected an identity-mismatch reason, got: $out"

echo "== review round 3: a duplicate chain entry sharing seq/digest/prev_digest but different content is a fork, not a silently-discarded duplicate =="
export DFSTATS_DB="$tmp/scenarios/tampered-duplicate.json"
run_id="$(meta tampered-duplicate .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "tampered-duplicate: expected exit 3 (indeterminate), got $rc: $out"
echo "$out" | grep -qi "different content\|forked chain" || fail "tampered-duplicate: expected a forked-chain reason, got: $out"

echo "== review round 4 (piece 2 of #663): a registry revision eligible at kickoff time narrows a CLI-trusted actor out, even though --trusted-actor-id alone would have accepted it =="
export DFSTATS_DB="$tmp/scenarios/registry-revision-pin.json"
run_id_narrowed="$(meta registry-revision-pin .meta.runIdNarrowed)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id_narrowed" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
# shepherd round 5, Codex-confirmed (P2): the index author's own trust is
# now decided at the RECORD's kickoff time (same mechanism, same
# EvidenceError disposition, as the pre-existing record-author check) —
# both this run's record and index share the one narrowed-out author, so
# this now correctly reports indeterminate rather than the old silent
# not-found, exactly as the record-author check alone already did for the
# identical reason before this fix unified the two.
[ "$rc" -eq 3 ] || fail "registry-revision-pin: narrowed run should report indeterminate once the eligible registry revision excludes its only author, got rc=$rc: $out"
echo "$out" | grep -qi "not a registry-trusted actor as of this run's kickoff" || fail "registry-revision-pin: expected a registry-narrowing reason, got: $out"

echo "== review round 4 (piece 2 of #663): a registry revision landing AFTER kickoff is not applied retroactively — the run authenticates normally =="
run_id_not_yet="$(meta registry-revision-pin .meta.runIdNotYet)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id_not_yet" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.outcome == null' >/dev/null || fail "registry-revision-pin: pre-revision run should still authenticate cleanly"

echo "== review round 4 (piece 2 of #663): a cherry-picked registry commit newest in listing order is still excluded by its own (later) first_seen; an earlier eligible commit governs instead =="
export DFSTATS_DB="$tmp/scenarios/registry-revision-cherrypick.json"
run_id="$(meta registry-revision-cherrypick .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.outcome == null' >/dev/null || fail "registry-revision-cherrypick: run governed by the earlier eligible commit should still authenticate cleanly"

echo "== shepherd round 1: a schema-conformant record with NO chain fields at all on stage_transitions harvests cleanly (pre-#738 shape) =="
export DFSTATS_DB="$tmp/scenarios/chain-pending-schema.json"
run_id_plain="$(meta chain-pending-schema .meta.runIdPlain)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id_plain" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.outcome == null' >/dev/null || fail "chain-pending-schema: a plain (no seq/digest/prev_digest) record should still authenticate cleanly"

echo "== shepherd round 1: a MIXED record (one entry chain-protected, one not) still fails closed =="
run_id_mixed="$(meta chain-pending-schema .meta.runIdMixed)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id_mixed" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "chain-pending-schema: mixed chain shape should be indeterminate, got rc=$rc: $out"

echo "== shepherd round 1: initiated_by edited in the mutable record body, disagreeing with the run-index's own copy, fails closed =="
export DFSTATS_DB="$tmp/scenarios/mutable-field-tamper.json"
run_id_init="$(meta mutable-field-tamper .meta.runIdInit)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id_init" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "mutable-field-tamper (initiated_by): expected indeterminate, got rc=$rc: $out"
echo "$out" | grep -qi "initiated_by" || fail "mutable-field-tamper (initiated_by): expected an initiated_by mismatch reason, got: $out"

echo "== shepherd round 2: a claimed started_at in the mutable record body has no effect — the record comment's own created_at is always authoritative =="
export DFSTATS_DB="$tmp/scenarios/started-at-neutralized.json"
run_id="$(meta started-at-neutralized .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.outcome == null' >/dev/null || fail "started-at-neutralized: expected the run to authenticate cleanly despite the implausible claimed started_at"
echo "$out" | jq -e '.started_at == "2026-09-01T00:00:00Z"' >/dev/null || fail "started-at-neutralized: expected started_at to be the record comment's own created_at (2026-09-01), not the claimed 2099 value, got: $out"

echo "== shepherd round 1/2: a path-traversal run_id cannot escape --replay's temp directory, and is replayed normally (hashing neutralizes rather than rejects) =="
export DFSTATS_DB="$tmp/scenarios/replay-path-traversal.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --replay --policy "$tmp/policy-matching.toml" --exit-script "$tmp/fake-exit-script.mjs" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.[0].indeterminate // false | not' >/dev/null || fail "replay-path-traversal: expected the run to replay normally (hashing makes the id safe unconditionally), got: $out"
echo "$out" | jq -e '.[0].diffs == []' >/dev/null || fail "replay-path-traversal: expected no diffs for a bare kickoff-only run with no rounds, got: $out"

echo "== shepherd round 1: firstSeen takes the EARLIEST of check-suite and merged_at, never merged_at unconditionally =="
export DFSTATS_DB="$tmp/scenarios/postfix-early-checksuite.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --as-of 2026-09-01T00:30:00Z --json)"
echo "$out" | jq -e '.post_ready_fix_count == 1' >/dev/null || fail "postfix-early-checksuite: expected the check-suite's earlier visibility to count as of a cutoff between it and the eventual merge, got: $out"

echo "== shepherd round 1: two chain entries sharing content+prev_digest but disagreeing on their own digest field are a fork, not a silently-discarded duplicate =="
export DFSTATS_DB="$tmp/scenarios/digest-mismatch-duplicate.json"
run_id="$(meta digest-mismatch-duplicate .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "digest-mismatch-duplicate: expected indeterminate (forked chain), got rc=$rc: $out"
echo "$out" | grep -qi "forked chain" || fail "digest-mismatch-duplicate: expected a forked-chain reason, got: $out"

echo "== shepherd round 1: an evidence marker edited from round=1 to round=1junk is rejected, not silently parsed as round:1 =="
export DFSTATS_DB="$tmp/scenarios/marker-round-tamper.json"
run_id="$(meta marker-round-tamper .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "marker-round-tamper: expected indeterminate, got rc=$rc: $out"
echo "$out" | grep -qi "edited-entry tampering\|no longer matches" || fail "marker-round-tamper: expected an edited-marker reason, got: $out"

echo "== shepherd round 1: a trusted run-index marker with a non-canonical tuple is not recognized as a real index =="
export DFSTATS_DB="$tmp/scenarios/noncanonical-index.json"
run_id="$(meta noncanonical-index .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "noncanonical-index: expected not-found (non-canonical index ignored), got rc=$rc: $out"

echo "== shepherd round 1: rounds render in CHRONOLOGICAL (posting) order, not alphabetical-by-stage-name order =="
export DFSTATS_DB="$tmp/scenarios/chronological-rounds.json"
run_id="$(meta chronological-rounds .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.rounds[0].stage == "challenge" and .rounds[0].round == 1' >/dev/null || fail "chronological-rounds: expected rounds[0] = challenge r1, got: $out"
echo "$out" | jq -e '.rounds[1].stage == "review" and .rounds[1].round == 1' >/dev/null || fail "chronological-rounds: expected rounds[1] = review r1 (posted before challenge r2), got: $out"
echo "$out" | jq -e '.rounds[2].stage == "challenge" and .rounds[2].round == 2' >/dev/null || fail "chronological-rounds: expected rounds[2] = challenge r2, got: $out"

echo "== shepherd round 1: a bot-authored post-promotion commit never counts as a post-ready HUMAN fix =="
export DFSTATS_DB="$tmp/scenarios/postfix-bot.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.unattended_success_count == 1 and .post_ready_fix_count == 0' >/dev/null || fail "postfix-bot: expected the bot commit to be excluded from post_ready_fix_count, got: $out"

echo "== shepherd round 1: --repo-root is threaded to the exit script explicitly, not silently defaulted =="
export DFSTATS_DB="$tmp/scenarios/happy.json"
export FAKE_EXIT_HEAD_LOG="$tmp/fake-exit-heads-repo-root.json"
rm -f "$FAKE_EXIT_HEAD_LOG"
node scripts/dev-flow-stats.mjs --repo o/r --replay --policy "$tmp/policy-matching.toml" --exit-script "$tmp/fake-exit-script.mjs" --repo-root "$tmp" --trusted-actor-id 9001 --json >/dev/null
[ -f "$FAKE_EXIT_HEAD_LOG" ] || fail "--repo-root: fake exit script was never invoked"
logged_repo_root="$(jq -r '.repo_root' "$FAKE_EXIT_HEAD_LOG")"
[ "$logged_repo_root" = "$tmp" ] || fail "--repo-root: expected the exit script to receive the explicit --repo-root value ($tmp), got: $logged_repo_root"
unset FAKE_EXIT_HEAD_LOG

echo "== shepherd round 1: a comment physically posted on the PR but whose marker claims dest=issue fails closed =="
export DFSTATS_DB="$tmp/scenarios/marker-dest-mismatch.json"
run_id="$(meta marker-dest-mismatch .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "marker-dest-mismatch: expected indeterminate, got rc=$rc: $out"
echo "$out" | grep -qi "not actually fetched from\|edited-entry tampering" || fail "marker-dest-mismatch: expected a destination-mismatch reason, got: $out"

echo "== shepherd round 2: a registry commit's pre-merge (feature-branch) check-suite time does not backdate when its revision took effect =="
export DFSTATS_DB="$tmp/scenarios/registry-premerge-checksuite.json"
run_id="$(meta registry-premerge-checksuite .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.outcome == null' >/dev/null || fail "registry-premerge-checksuite: expected the run to authenticate cleanly (the revision is not yet in effect at kickoff), got: $out"

echo "== shepherd round 2: registry-revision narrowing still applies against a non-'main' default branch =="
export DFSTATS_DB="$tmp/scenarios/registry-nonmain-branch.json"
run_id="$(meta registry-nonmain-branch .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
# shepherd round 5: same reclassification as registry-revision-pin above —
# indeterminate, not silent not-found, now that the index author's own
# trust check runs through the same record-kickoff-time mechanism as the
# record author's.
[ "$rc" -eq 3 ] || fail "registry-nonmain-branch: expected indeterminate (narrowed by the in-effect registry revision on the trunk branch), got rc=$rc: $out"
echo "$out" | grep -qi "not a registry-trusted actor as of this run's kickoff" || fail "registry-nonmain-branch: expected a registry-narrowing reason, got: $out"

echo "== shepherd round 2: a forged-author evidence marker is reported under forged_comments, not silently dropped =="
export DFSTATS_DB="$tmp/scenarios/forged-marker-report.json"
run_id="$(meta forged-marker-report .meta.runId)"
forged_id="$(meta forged-marker-report .meta.forgedId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.outcome == null' >/dev/null || fail "forged-marker-report: expected the run itself to authenticate cleanly"
echo "$out" | jq -e --argjson id "$forged_id" '[.forged_comments[].id] | index($id) != null' >/dev/null || fail "forged-marker-report: expected the forged comment under forged_comments, got: $out"
echo "$out" | jq -e --argjson id "$forged_id" '[.orphan_comments[].id] | index($id) == null' >/dev/null || fail "forged-marker-report: forged comment must not also appear in orphan_comments, got: $out"

echo "== shepherd round 2: run_ids that normalize to the same path (a vs a/.) do not collide during one --replay batch =="
export DFSTATS_DB="$tmp/scenarios/replay-dir-collision.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --replay --policy "$tmp/policy-matching.toml" --exit-script "$tmp/fake-exit-script.mjs" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '[.[].runId] | sort == ["a", "a/."]' >/dev/null || fail "replay-dir-collision: expected both run_ids to appear independently, got: $out"
echo "$out" | jq -e '[.[].indeterminate] | all(. != true)' >/dev/null || fail "replay-dir-collision: expected neither run to be indeterminate, got: $out"

echo "== shepherd round 2: an unrecognized flag (a typo, e.g. --asof) is a usage error, not a silent no-op =="
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --asof 2026-09-01T00:00:00Z --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "unrecognized flag: expected usage error (exit 2), got rc=$rc: $out"
echo "$out" | grep -qi "unrecognized option" || fail "unrecognized flag: expected an unrecognized-option message, got: $out"

echo "== shepherd round 2: an indeterminate exit-script verdict is propagated, not diffed as a policy disagreement =="
export DFSTATS_DB="$tmp/scenarios/happy.json"
export FAKE_EXIT_INDETERMINATE=1
out="$(node scripts/dev-flow-stats.mjs --repo o/r --replay --policy "$tmp/policy-matching.toml" --exit-script "$tmp/fake-exit-script.mjs" --trusted-actor-id 9001 --json)"
unset FAKE_EXIT_INDETERMINATE
echo "$out" | jq -e '.[0].diffs[0].recomputed == null and (.[0].diffs[0].error | test("could not verify"))' >/dev/null || fail "indeterminate-exit-script: expected an error-shaped diff entry naming the verification failure, got: $out"
echo "$out" | jq -e '.[0].diffs[0] | has("reason") | not' >/dev/null || fail "indeterminate-exit-script: expected no policy-disagreement 'reason' field on an indeterminate diff entry, got: $out"
echo "== shepherd round 3: an indeterminate exit-script verdict marks the WHOLE replay result indeterminate, not just one diffs[] entry =="
echo "$out" | jq -e '.[0].indeterminate == true' >/dev/null || fail "indeterminate-exit-script: expected the top-level result marked indeterminate, got: $out"
echo "$out" | jq -e '.[0].reason | test("could not verify")' >/dev/null || fail "indeterminate-exit-script: expected the top-level reason to name the verification failure, got: $out"

echo "== shepherd round 2: --since correctly excludes an issue whose indeterminate FIRST run predates the window, using the trusted index's own kickoff time =="
export DFSTATS_DB="$tmp/scenarios/since-indeterminate-first.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --since 2026-08-15T00:00:00Z --json)"
echo "$out" | jq -e '.cohort_size == 0' >/dev/null || fail "since-indeterminate-first: expected the issue excluded by --since (predates the window via the broken run's own index time), got: $out"
without_since="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$without_since" | jq -e '.indeterminate_count == 1' >/dev/null || fail "since-indeterminate-first: without --since, expected the issue counted as indeterminate (the broken first run), got: $without_since"

echo "== shepherd round 2: a second chain- and digest-valid outcome_transitions entry (capped then ready-for-review) is rejected, not laundered into success =="
export DFSTATS_DB="$tmp/scenarios/outcome-transitions-unbounded.json"
run_id="$(meta outcome-transitions-unbounded .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "outcome-transitions-unbounded: expected indeterminate, got rc=$rc: $out"
echo "$out" | grep -qi "outcome_transitions has 2 entries\|one terminal outcome" || fail "outcome-transitions-unbounded: expected an at-most-one-terminal-outcome reason, got: $out"

echo "== shepherd round 3: a destination=pr marker with a non-null round is rejected, not silently dropped from the trajectory =="
export DFSTATS_DB="$tmp/scenarios/pr-dest-with-round.json"
run_id="$(meta pr-dest-with-round .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "pr-dest-with-round: expected indeterminate, got rc=$rc: $out"
echo "$out" | grep -qi "destination=pr with a non-null round" || fail "pr-dest-with-round: expected a destination/round grammar reason, got: $out"

echo "== shepherd round 3: post_ready_fix_indeterminate_count is shown in the human-readable --repo output, not just JSON =="
export DFSTATS_DB="$tmp/scenarios/postfix-unresolvable.json"
json_out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$json_out" | jq -e '.post_ready_fix_indeterminate_count == 1' >/dev/null || fail "postfix-unresolvable: expected post_ready_fix_indeterminate_count 1 in JSON, got: $json_out"
table_out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001)"
echo "$table_out" | grep -qi "post-ready human fixes indeterminate" || fail "postfix-unresolvable: expected the human-readable form to show post-ready-fix uncertainty, got: $table_out"

echo "== shepherd round 3: the run-record author's trust is evaluated at the RECORD's own kickoff time, not the later run-index post time =="
export DFSTATS_DB="$tmp/scenarios/registry-trust-record-before-index.json"
run_id="$(meta registry-trust-record-before-index .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "registry-trust-record-before-index: expected indeterminate (untrusted at record-post time, even though a later registry revision would trust it by index-post time), got rc=$rc: $out"
# shepherd round 5 added an index-author check using the SAME
# recordComment.created_at anchor, which runs first in code order and
# now shadows this fixture's original record-author-specific message
# (this fixture's index and record share one actor, so both checks fail
# for the identical reason) — either message proves the same underlying
# point: trust evaluated at the record's kickoff time, not the index's.
echo "$out" | grep -qi "not a configured trusted actor\|not a registry-trusted actor as of this run's kickoff" || fail "registry-trust-record-before-index: expected an untrusted-author reason, got: $out"

echo "== shepherd round 3: an indeterminate run's --since cohort time is the RECORD's own created_at, not the later run-index post time (same fixture, isolates the catch-block fallback from the trust check above) =="
since_excluded="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --since 2026-09-01T00:15:00Z --json)"
echo "$since_excluded" | jq -e '.indeterminate_count == 0 and (.per_issue | length) == 0' >/dev/null || fail "registry-trust-record-before-index: expected --since 00:15 to exclude the issue entirely (record posted 00:10, before the cutoff), got: $since_excluded"
since_included="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --since 2026-09-01T00:05:00Z --json)"
echo "$since_included" | jq -e '.indeterminate_count == 1 and (.per_issue | length) == 1' >/dev/null || fail "registry-trust-record-before-index: expected --since 00:05 to include the issue as indeterminate (record posted 00:10, on/after the cutoff), got: $since_included"

echo "== shepherd round 4: a registry-touching commit with no merging PR (direct push) voids the WHOLE repo's registry history, not just that commit =="
export DFSTATS_DB="$tmp/scenarios/registry-direct-push.json"
run_id="$(meta registry-direct-push .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001)"
echo "$out" | grep -qi "run $run_id (issue #159) — outcome: in-flight" || fail "registry-direct-push: expected the run to validate normally (full CLI trust fallback, not narrowed out by the still-real other revision), got: $out"

echo "== shepherd round 4: a run's last activity exactly staleAfterDays before --as-of terminalizes as abandoned; one ms earlier it does not =="
export DFSTATS_DB="$tmp/scenarios/stale-boundary.json"
at_boundary="$(meta stale-boundary .meta.atBoundary)"
before_boundary="$(meta stale-boundary .meta.beforeBoundary)"
at_out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --as-of "$at_boundary" --json)"
echo "$at_out" | jq -e '.cohort_size == 1 and .unattended_success_count == 0' >/dev/null || fail "stale-boundary: expected terminalized-abandoned at the exact boundary, got: $at_out"
before_out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --as-of "$before_boundary" --json)"
echo "$before_out" | jq -e '.cohort_size == 0' >/dev/null || fail "stale-boundary: expected the run still open (not yet stale) one ms before the boundary, got: $before_out"

echo "== shepherd round 4: --run --as-of C cutoff-filters orphan/forged reports the same as everything else historical =="
export DFSTATS_DB="$tmp/scenarios/orphan-cutoff.json"
run_id="$(meta orphan-cutoff .meta.runId)"
live_out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --json)"
echo "$live_out" | jq -e '(.orphan_comments | length) == 1' >/dev/null || fail "orphan-cutoff: expected the orphan visible with no --as-of, got: $live_out"
historical_out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --as-of 2026-09-02T00:00:00Z --json)"
echo "$historical_out" | jq -e '(.orphan_comments | length) == 0' >/dev/null || fail "orphan-cutoff: expected the orphan EXCLUDED at an --as-of before it was posted, got: $historical_out"

echo "== shepherd round 4: a run-record marker edited off the reserved kickoff/issue/-/1 tuple is rejected, not silently authenticated =="
export DFSTATS_DB="$tmp/scenarios/record-marker-tamper.json"
run_id="$(meta record-marker-tamper .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "record-marker-tamper: expected indeterminate, got rc=$rc: $out"
echo "$out" | grep -qi "no longer identifies it as this run's run-record" || fail "record-marker-tamper: expected an edited-entry tampering reason, got: $out"

echo "== shepherd round 5: the run-index's OWN author trust is decided at the record's kickoff time, isolated from the record-author check via a genuinely different index author =="
export DFSTATS_DB="$tmp/scenarios/index-author-narrowed.json"
run_id="$(meta index-author-narrowed .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --trusted-actor-id 9002 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "index-author-narrowed: expected indeterminate (index author narrowed out at the record's kickoff time), got rc=$rc: $out"
echo "$out" | grep -qi "author is not a registry-trusted actor as of this run's kickoff" || fail "index-author-narrowed: expected the index-author-specific reason, got: $out"

echo "== shepherd round 5: a trusted run-index with a canonical marker but no fenced payload is indeterminate, not silently absent from the cohort =="
export DFSTATS_DB="$tmp/scenarios/index-no-fence.json"
run_id="$(meta index-no-fence .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "index-no-fence: expected indeterminate (malformed trusted index), got rc=$rc: $out"
echo "$out" | grep -qi "canonical marker but no fenced payload" || fail "index-no-fence: expected a malformed-payload reason, got: $out"
repo_out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$repo_out" | jq -e '.indeterminate_count == 1' >/dev/null || fail "index-no-fence: expected the --repo scan to count this issue as indeterminate, not silently absent from the cohort, got: $repo_out"

echo "== shepherd round 5: with no --as-of given, discovery freezes a real 'now' cutoff instead of an unbounded one — a future-dated run-record is excluded, not admitted =="
export DFSTATS_DB="$tmp/scenarios/future-dated.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '(.per_issue | length) == 0' >/dev/null || fail "future-dated: expected the far-future run's issue completely undiscovered under the frozen 'now' cutoff (not merely open/non-terminal, which an unrelated Infinity cutoff would also show), got: $out"

echo "== shepherd round 5: a ready-for-review outcome with no reconstructed PR binding is rejected as inconsistent, not left to crash computePostReadyFix and abort the whole metric =="
export DFSTATS_DB="$tmp/scenarios/ready-no-pr-binding.json"
run_id="$(meta ready-no-pr-binding .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "ready-no-pr-binding: expected indeterminate, got rc=$rc: $out"
echo "$out" | grep -qi "ready-for-review without a corresponding PR binding" || fail "ready-no-pr-binding: expected a PR-binding-inconsistency reason, got: $out"
repo_out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$repo_out" | jq -e '.indeterminate_count == 1' >/dev/null || fail "ready-no-pr-binding: expected the --repo scan to complete and count this issue as indeterminate, not crash entirely, got: $repo_out"

echo "== shepherd round 5: replay selects a cap-0-disabled stage (recorded stage_transitions exit, zero rounds) for comparison instead of skipping it entirely =="
export DFSTATS_DB="$tmp/scenarios/challenge-capped-disabled.json"
cat >"$tmp/policy-disabled-matching.toml" <<'TOML'
challenge_cap = 0
review_cap = 3
TOML
matching_out="$(node scripts/dev-flow-stats.mjs --repo o/r --replay --policy "$tmp/policy-disabled-matching.toml" --exit-script "$tmp/fake-exit-script.mjs" --trusted-actor-id 9001 --json)"
echo "$matching_out" | jq -e '.[0].diffs | length == 0' >/dev/null || fail "challenge-capped-disabled (matching cap 0): expected no diff, got: $matching_out"
cat >"$tmp/policy-disabled-enabling.toml" <<'TOML'
challenge_cap = 4
review_cap = 3
TOML
enabling_out="$(node scripts/dev-flow-stats.mjs --repo o/r --replay --policy "$tmp/policy-disabled-enabling.toml" --exit-script "$tmp/fake-exit-script.mjs" --trusted-actor-id 9001 --json)"
echo "$enabling_out" | jq -e '(.[0].diffs | length) == 1 and .[0].diffs[0].stage == "challenge" and .[0].diffs[0].recorded == "capped: disabled" and .[0].diffs[0].recomputed == "continue"' >/dev/null || fail "challenge-capped-disabled (enabling cap 4): expected challenge to diff (recorded capped, recomputed continue for the zero-round trajectory), got: $enabling_out"

echo "TEST PASS: dev-flow-stats harvesting/trust/metric/replay behavior"
