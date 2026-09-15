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
    # shell-robustness: ok — always exits, so its status is never read
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
printf '%s\n' "$*" >>"${DFSTATS_GH_LOG:-/dev/null}"

if [ "${1:-}" != api ]; then
    echo "fake gh: unsupported subcommand: ${1:-}" >&2
    exit 1
fi
shift
# Drop --paginate/--slurp flags; find the endpoint (first non-flag arg).
endpoint=""
api_args="$*"
for a in "$@"; do
    case "$a" in
    --paginate | --slurp) ;;
    *) endpoint="$a"; break ;;
    esac
done

case "$endpoint" in
repos/*/issues\?state=all\&per_page=100)
    if [[ "$api_args" == *'--jq map(.[] | {number, pull_request})'* ]]; then
        jq '[[.issues[] | {number, pull_request}]]' "$db"
    else
        jq '[.issues]' "$db"
    fi
    ;;
repos/*/issues/*/comments\?per_page=100)
    n="$(echo "$endpoint" | sed -E 's#.*/issues/([0-9]+)/comments.*#\1#')"
    jq --arg n "$n" '[(.comments[$n] // [])]' "$db"
    ;;
repos/*/issues/[0-9]*)
    n="$(echo "$endpoint" | sed -E 's#.*/issues/([0-9]+).*#\1#')"
    if ! jq -e --argjson n "$n" '.issues[] | select(.number == $n)' "$db"; then
        echo "gh: Not Found (HTTP 404)" >&2
        exit 1
    fi
    ;;
repos/*/pulls/*/commits\?per_page=100)
    n="$(echo "$endpoint" | sed -E 's#.*/pulls/([0-9]+)/commits.*#\1#')"
    # A literal "FAIL" (instead of an array) simulates a transient API,
    # permission, or rate-limit error from this endpoint — shepherd round
    # 6, proving computePostReadyFix isolates such a failure to its own
    # issue instead of it escaping as an uncaught GhError.
    if [ "$(jq --arg n "$n" -r '.commits[$n] // empty' "$db")" = "FAIL" ]; then
        echo "fake gh: simulated API failure for pulls/$n/commits" >&2
        exit 1
    fi
    jq --arg n "$n" '[(.commits[$n] // [])]' "$db"
    ;;
repos/*/commits/*/pulls)
    sha="$(echo "$endpoint" | sed -E 's#.*/commits/([0-9a-f]+)/pulls.*#\1#')"
    # A PR entry without an explicit base is a PR into the default branch
    # (the common fixture case); a scenario that needs a PR into some other
    # branch — challenge round 1 of #741: a staging merge must NOT count as
    # landing on the default branch — states `base: {ref: ...}` itself.
    jq --arg sha "$sha" '(.default_branch // "main") as $default | [((.commit_pulls[$sha] // []) | map(. + {base: (.base // {ref: $default})}))]' "$db"
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
import { writeFileSync, mkdirSync, readFileSync, readdirSync } from "node:fs";
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

function lifecycleTo(destination, at) {
  const stages = ["kickoff", "claim", "implement", "verify"];
  if (destination === "review" || destination === "integration") stages.push("review");
  if (destination === "integration") stages.push("security", "integration");
  return chain(stages.map((stage, index) => ({
    stage,
    entered_at: at,
    ...(index < stages.length - 1 ? { exit: "fixture transition to " + stages[index + 1] } : {}),
  })));
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

function evidenceSummaryComment(actorId, login, runId, stage, dest, round, seq, createdAt) {
  const markerPayload = JSON.stringify({ run_id: runId, stage, round, sequence: seq, destination: dest });
  return comment(
    actorId,
    login,
    \`<!-- dev-flow-v2-evidence: \${markerPayload} -->\n## \${stage} round \${round} — \${runId}\n\`,
    createdAt,
  );
}

function writeZeroFindingAdjudication(runDir, runId, stage = "review", round = 1) {
  mkdirSync(path.join(runDir, "adjudications"), { recursive: true });
  writeFileSync(path.join(runDir, "adjudications", stage + "-r" + round + ".json"), JSON.stringify({
    schema: 2, run_id: runId, stage, round,
    reviewed_head: "0".repeat(40), adjudications: [],
  }, null, 2));
}

function writeCompletedZeroFindingPass(runDir, runId, stage = "review", round = 1) {
  // The resolved policy's configured primary finder differs by stage
  // (challenge -> codex-adversarial, review -> codex-verification); every
  // existing caller passes/defaults to "review", so this preserves their
  // exact prior output while making a "challenge" pass fill its own
  // stage's actual primary slot instead of a review-only finder no
  // challenge round configures.
  const finder = stage === "challenge" ? "codex-adversarial" : "codex-verification";
  const envelope = pass(finder, []);
  envelope.run.run_id = runId;
  envelope.payload.stage = stage;
  envelope.payload.round = round;
  envelope.payload.reviewed_head = envelope.head;
  mkdirSync(path.join(runDir, "passes"), { recursive: true });
  const file = stage + "-r" + round;
  writeFileSync(path.join(runDir, "passes", file + ".json"), JSON.stringify(envelope, null, 2));
  const runFile = path.join(runDir, "run.json");
  const run = JSON.parse(readFileSync(runFile, "utf8"));
  run.receipts = [...(run.receipts || []), { kind: "transition", stage }, { kind: "pass", file }];
  writeFileSync(runFile, JSON.stringify(run, null, 2));
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
  const normalized = findings.map((finding, index) => {
    const priority = finding.priority || finding.severity || "P2";
    return {
      id: finding.id || \`review-r1-\${finder}-\${index + 1}\`,
      path: finding.path || "scripts/dev-flow-stats.mjs",
      line: finding.line === undefined ? 1 : finding.line,
      class: finding.class || "correctness",
      provenance: finding.provenance || "original",
      fingerprint: finding.fingerprint || "new",
      priority,
      recommended_disposition: finding.recommended_disposition || "fix",
      evidence: finding.evidence || finding.summary || "fixture evidence",
    };
  });
  const counts = { P0: 0, P1: 0, P2: 0, P3: 0 };
  for (const finding of normalized) counts[finding.priority] += 1;
  return {
    schema: 2, role: "reviewer", status: "completed", head: "0".repeat(40),
    produced_at: "2026-09-01T00:00:00Z",
    producer: { harness: finder, model: "fixture-model", tier: "local" },
    run: { run_id: "placeholder", initiated_by: "human" },
    payload: { stage: "review", round: 1, reviewed_head: "0".repeat(40), finder, findings: normalized, counts },
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

// #741: the registry allowlist is the ROOT of trust and the harvester fails
// closed when no revision is in effect for a write, so every scenario needs
// SOME registry history. A scenario that declares none (the common case —
// it is testing something other than registry binding) gets a baseline
// revision that landed long before any fixture timestamp and trusts exactly
// the ids its meta.trustedActorIds names (TRUSTED_ORCHESTRATOR when it
// names none), so the CLI selection and the registry agree and the
// scenario's own subject stays isolated. A scenario that declares
// registry_commits controls the whole history itself.
const BASELINE_REGISTRY_SHA = "0123456789abcdef0123456789abcdef01234567";
const BASELINE_REGISTRY_LANDED_AT = "2000-01-01T00:00:00Z";
function registryDoc(ids) {
  return Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: ids })).toString("base64");
}
function writeScenario(name, db) {
  if (!("registry_commits" in db)) {
    const ids = db.meta && Array.isArray(db.meta.trustedActorIds) && db.meta.trustedActorIds.length > 0
      ? db.meta.trustedActorIds
      : [TRUSTED_ORCHESTRATOR];
    db = {
      ...db,
      registry_commits: [{ sha: BASELINE_REGISTRY_SHA }],
      registry_contents: { [BASELINE_REGISTRY_SHA]: registryDoc(ids) },
      commit_pulls: { ...(db.commit_pulls || {}), [BASELINE_REGISTRY_SHA]: [{ number: 1, merged_at: BASELINE_REGISTRY_LANDED_AT }] },
    };
  }
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
// piece 2, now #741's shipped allowlist, resolved via
// resolveRegistryTrustedActorIds). A baseline revision trusts
// TRUSTED_ORCHESTRATOR; a later registry commit REMOVES it (trusts only
// OTHER_TRUSTED). Two issues straddle that commit's landing time, proving
// the revision applies to a run kicked off AFTER it took effect and does
// NOT retroactively apply to one kicked off BEFORE — #741's own acceptance
// criterion ("an actor removed after posting does not invalidate
// already-authenticated historical evidence").
{
  const baselineSha = "d".repeat(40);
  const narrowSha = "a".repeat(40);
  const registryCommits = [{ sha: narrowSha }, { sha: baselineSha }]; // newest-first, as GitHub returns
  const registryContents = {
    [baselineSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [TRUSTED_ORCHESTRATOR] })).toString("base64"),
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
  // Issue B: kicks off BEFORE the narrowing commit landed -> the baseline
  // revision governs (it still trusts TRUSTED_ORCHESTRATOR) -> accepted
  // normally, and the later removal never reaches back to it.
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
    // The narrowing commit lands BETWEEN the two kickoffs; the baseline
    // long before either.
    commit_pulls: {
      [baselineSha]: [{ number: 600, merged_at: "2026-08-01T00:00:00Z" }],
      [narrowSha]: [{ number: 601, merged_at: "2026-09-01T00:05:00Z" }],
    },
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
// off AFTER the check-suite time but BEFORE the merge must still be
// governed by the earlier baseline revision (which trusts
// TRUSTED_ORCHESTRATOR), not by the narrowed set the commit eventually
// establishes.
{
  const baselineSha = "e".repeat(40);
  const narrowSha = "f".repeat(40);
  const registryCommits = [{ sha: narrowSha }, { sha: baselineSha }]; // newest-first, as GitHub returns
  const registryContents = {
    [baselineSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [TRUSTED_ORCHESTRATOR] })).toString("base64"),
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
    commit_pulls: {
      [baselineSha]: [{ number: 609, merged_at: "2026-08-01T00:00:00Z" }],
      [narrowSha]: [{ number: 610, merged_at: "2026-09-01T00:20:00Z" }],
    },
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
// shepherd round 4, Codex-confirmed (P1). A revision that trusts
// TRUSTED_ORCHESTRATOR exists and is independently resolvable, but because
// a second, unresolvable (direct-push) commit also touches the registry,
// the mechanism must admit that it cannot prove which revision governs —
// and under #741 (maintainer ruling 2026-09-03: an unresolvable governing
// revision "is indeterminate (fail closed)") that means the run is
// INDETERMINATE, never trusted on the strength of the still-resolvable
// older revision and never on CLI configuration alone.
{
  const narrowSha = "5".repeat(40);
  const directPushSha = "7".repeat(40);
  const registryCommits = [{ sha: directPushSha }, { sha: narrowSha }]; // newest-first, as GitHub returns
  const registryContents = {
    [narrowSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [TRUSTED_ORCHESTRATOR] })).toString("base64"),
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

// --- Scenario 53: a malformed (no-fence) run-index posted FIRST, then a
// later well-formed duplicate for the SAME run_id posted second (a
// simulated "someone re-posted a corrected index") — shepherd round 6,
// Codex-confirmed (P1 + P2): the round-5 malformed-index fix treated
// malformed and well-formed candidates as two SEPARATE pools, so the
// later well-formed one silently won canonical status regardless of
// comment id, instead of the evidence contract's lowest-id-wins rule
// applying across both. The malformed (lower-id) one must stay
// canonical — indeterminate, using ITS OWN created_at as kickoffCreatedAt
// (not null, not the later duplicate's).
{
  const runId = "run-malformed-index-canonical-1";
  const recordCreatedAt = "2026-08-20T00:00:00Z";
  const malformedIndexCreatedAt = "2026-08-20T00:01:00Z";
  const laterValidIndexCreatedAt = "2026-09-01T00:00:00Z";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: recordCreatedAt,
    stage_transitions: chain([{ stage: "kickoff", entered_at: recordCreatedAt }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const body = { ...runBody, ...deriveDefaultChains(runBody) };
  const rm = marker("run-record", runId, "kickoff", "issue", null, 1);
  const rr = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${rm}\n\${fence(JSON.stringify(body))}\`, recordCreatedAt);
  // Malformed: canonical marker, no fenced payload — posted right after
  // the record, so it gets the LOWER comment id of the two indices.
  const malformedIm = marker("run-index", runId, "kickoff", "issue", null, 1);
  const malformedIdx = comment(TRUSTED_ORCHESTRATOR, "orchestrator", malformedIm, malformedIndexCreatedAt);
  // A later, well-formed duplicate for the SAME run_id — higher comment
  // id, posted well after.
  const indexPayload = {
    run_id: runId, initiated_by: body.initiated_by, branch: null,
    run_record: { id: String(rr.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator" },
  };
  const validIm = marker("run-index", runId, "kickoff", "issue", null, 1);
  const laterValidIdx = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${validIm}\n\${fence(JSON.stringify(indexPayload))}\`, laterValidIndexCreatedAt);
  writeScenario("malformed-index-stays-canonical", {
    issues: [{ number: 168, pull_request: null }],
    comments: { "168": [rr, malformedIdx, laterValidIdx] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 168, malformedIndexCreatedAt },
  });
}

// --- Scenario 54: a correctly indexed, digested, trusted evidence
// comment whose reassembled payload is valid JSON but not an object
// (bare null) — shepherd round 6, Codex-confirmed (P1): JSON.parse
// accepts null as a value, so this previously reached round.payload
// unchecked, and every downstream reader (--run's rendering, --replay's
// buildRunDirectory) unconditionally dereferences round.payload.passes —
// an uncaught TypeError, not an EvidenceError, aborting the entire batch
// instead of making only this run indeterminate.
{
  const runId = "run-null-round-payload-1";
  const ev = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "challenge", "issue", 1, 1, null, "2026-09-01T00:01:00Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null,
    evidence_comments: [evidenceIndexEntry(ev, TRUSTED_ORCHESTRATOR, "orchestrator", runId, "challenge", "issue", 1, 1, payloadDigest(JSON.stringify(null)))],
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("null-round-payload", {
    issues: [{ number: 169, pull_request: null }],
    comments: { "169": [idx, rr, ev] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 169 },
  });
}

// --- Scenario 55: a confirmed post-ready human fix alongside a SEPARATE,
// unresolvable post-promotion commit on the SAME issue — shepherd round
// 6, Codex-confirmed (P2): once any commit confirms the fix, the
// issue-level boolean is conclusively true; a different, still-
// unresolved commit must not ALSO mark the issue indeterminate,
// double-counting it in both output buckets.
{
  const runId = "run-postfix-mixed-1";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T00:01:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 622, url: "https://example.invalid/pr/622" },
    evidence_comments: [],
    promotion: { head: "a".repeat(40), promoted_at: "2026-09-01T00:10:00Z", gate_fingerprint: "mixed" },
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  const promotedCommit = { sha: "a".repeat(40), commit: { committer: { date: "2026-09-01T00:10:00Z" } }, author: { id: TRUSTED_ORCHESTRATOR } };
  const resolvedFixCommit = { sha: "b".repeat(40), commit: { committer: { date: "2026-09-01T00:20:00Z" } }, author: { id: 42 } };
  const unresolvableCommit = { sha: "c".repeat(40), commit: { committer: { date: "2026-09-01T00:21:00Z" } }, author: { id: 43 } };
  writeScenario("postfix-mixed", {
    issues: [{ number: 170, pull_request: null }],
    comments: { "170": [idx, rr] },
    commits: { "622": [promotedCommit, resolvedFixCommit, unresolvableCommit] },
    ...mergedPrSeen(resolvedFixCommit.sha, 622, "2026-09-01T00:20:00Z"),
    // unresolvableCommit has no mergedPrSeen/checkSuiteSeen at all —
    // first_seen resolves to null.
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 170 },
  });
}

// --- Scenario 56: computePostReadyFix's own PR-commits request fails
// transiently (simulated via the fake gh stub's "FAIL" sentinel) on ONE
// issue — shepherd round 6, Codex-confirmed (P1): this must isolate to
// that issue's own post_ready_fix_indeterminate_count, never escape and
// abort the primary closed-cohort result for the --repo scan's OTHER
// issue.
{
  const failRunId = "run-postfix-api-fail-1";
  const failRunBody = {
    schema: 2, run_id: failRunId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T00:01:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 623, url: "https://example.invalid/pr/623" },
    evidence_comments: [],
    promotion: { head: "d".repeat(40), promoted_at: "2026-09-01T00:10:00Z", gate_fingerprint: "api-fail" },
  };
  const failPair = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", failRunId, failRunBody, "2026-09-01T00:00:00Z");

  const okRunId = "run-postfix-api-fail-ok-sibling-1";
  const okRunBody = {
    schema: 2, run_id: okRunId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "integration", entered_at: "2026-09-01T00:01:00Z" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: "ready-for-review",
    pr: { number: 624, url: "https://example.invalid/pr/624" },
    evidence_comments: [],
    promotion: { head: "e".repeat(40), promoted_at: "2026-09-01T00:10:00Z", gate_fingerprint: "api-fail-sibling" },
  };
  const okPair = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", okRunId, okRunBody, "2026-09-01T00:00:00Z");

  writeScenario("postfix-api-fail", {
    issues: [{ number: 171, pull_request: null }, { number: 172, pull_request: null }],
    comments: { "171": [failPair.index, failPair.record], "172": [okPair.index, okPair.record] },
    // "FAIL" (a string, not an array) trips the fake gh stub's simulated
    // API-failure path for issue 171's PR commits specifically; issue
    // 172's PR (624) has ordinary, empty commits — a ready run with no
    // post-promotion activity at all, a genuinely clean "no fix" result.
    commits: { "623": "FAIL", "624": [] },
    meta: { failRunId, okRunId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumberFail: 171, issueNumberOk: 172 },
  });
}

// --- Scenario 57: a stage_transitions exit carries trailing free-form
// prose after its machine-relevant leading word ("continue, more rounds
// needed") — shepherd round 6, Codex-confirmed (P1): recordedOutcome's
// old split-on-whitespace-or-colon approach kept the comma, so
// "continue," never matched OUTCOME_ENUM and this recorded=null instead
// of recorded=continue, reporting a false --replay policy difference
// against a candidate policy that genuinely still agrees.
{
  const runId = "run-outcome-trailing-prose-1";
  const challengePayload = { passes: [pass("codex-cli", [])], adjudication: { schema: 2, run_id: runId, stage: "challenge", round: 1, adjudications: [] } };
  const ev = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "challenge", "issue", 1, 1, challengePayload, "2026-09-01T00:01:00Z");
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([
      { stage: "kickoff", entered_at: "2026-09-01T00:00:00Z", exit: "claimed" },
      { stage: "challenge", entered_at: "2026-09-01T00:00:30Z", exit: "continue, more rounds needed" },
    ]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null,
    evidence_comments: [evidenceIndexEntry(ev, TRUSTED_ORCHESTRATOR, "orchestrator", runId, "challenge", "issue", 1, 1, payloadDigest(JSON.stringify(challengePayload)))],
    promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z");
  writeScenario("outcome-trailing-prose", {
    issues: [{ number: 173, pull_request: null }],
    comments: { "173": [idx, rr, ev] },
    commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 173 },
  });
}

// --- #741 fixture corpus: ai/schemas/fixtures/registry-trust/<case>/scenario.json
// Each fixture is a declarative timeline (registry revisions with their
// default-branch landing times and allowlists; one run's kickoff, evidence
// writes, and optional record edit; the operator's CLI selection; the
// expected harvest verdict) rendered here into the same fake-gh database
// shape every hand-built scenario above uses, so the corpus exercises the
// real resolver end to end rather than a re-implementation. Documented in
// ai/schemas/README.md "Fixture layout". Issue numbers 900+ are reserved
// for it.
{
  const corpusDir = "${repo}/ai/schemas/fixtures/registry-trust";
  const cases = readdirSync(corpusDir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name).sort();
  cases.forEach((name, i) => {
    const fixture = JSON.parse(readFileSync(path.join(corpusDir, name, "scenario.json"), "utf8"));
    const issueNumber = 900 + i;
    const runId = \`run-registry-trust-\${name}\`;
    const author = fixture.run.author_actor_id;
    const evidence = [];
    const evidenceIndex = [];
    for (const w of fixture.run.evidence_writes) {
      const payload = { passes: [] };
      const ev = evidenceComment(author, "orchestrator", runId, w.stage, "issue", w.round, 1, payload, w.posted_at);
      evidence.push(ev);
      evidenceIndex.push(evidenceIndexEntry(ev, author, "orchestrator", runId, w.stage, "issue", w.round, 1, payloadDigest(JSON.stringify(payload))));
    }
    // Unindexed writes (challenge round 3 of #741): evidence-shaped comments
    // by the run's own author that the record never lists — reported, never
    // assembled; the fixture says whether each is an orphan (trusted at its
    // write time) or forged-class (not trusted at its write time).
    const unindexed = (fixture.run.unindexed_writes || []).map((w) => {
      const c = evidenceComment(author, "orchestrator", runId, w.stage, "issue", w.round, 1, { passes: [] }, w.posted_at);
      if (w.edited_at) c.updated_at = w.edited_at;
      return c;
    });
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: fixture.run.kickoff_at,
      stage_transitions: chain([{ stage: "kickoff", entered_at: fixture.run.kickoff_at }]),
      interventions: chain([]), settlements: chain([]),
      outcome: null, pr: null, evidence_comments: evidenceIndex, promotion: null,
    };
    const { index: idx, record: rr } = runRecordComment(author, "orchestrator", runId, runBody, fixture.run.kickoff_at);
    if (fixture.run.record_edited_at) rr.updated_at = fixture.run.record_edited_at;
    // The index is a separate, later write (challenge round 2 of #741):
    // a fixture may post it after the record, and may edit it afterwards.
    if (fixture.run.index_posted_at) idx.created_at = fixture.run.index_posted_at;
    if (fixture.run.index_edited_at) idx.updated_at = fixture.run.index_edited_at;
    // The fixture's array IS the commits?path= listing order (newest
    // first, as GitHub returns the default branch's history) — it is not
    // re-sorted, because listing position is what decides whether an
    // unresolvable (landed_at: null) revision voids the history (newest)
    // or only the interval before a later resolvable landing (older).
    // Such a revision has no commit_pulls entry at all, matching a real
    // no-merging-PR response.
    const revisions = [...fixture.registry_revisions];
    const registryContents = {};
    const commitPulls = {};
    revisions.forEach((r, n) => {
      registryContents[r.sha] = Buffer.from(JSON.stringify(r.document)).toString("base64");
      const pulls = [];
      // An optional earlier merge into a NON-default branch, listed FIRST
      // (as a naive "first merged PR" reader would pick it): it must never
      // count as the revision landing on the default branch.
      if (r.staging_merged_at) pulls.push({ number: 800 + n, merged_at: r.staging_merged_at, base: { ref: "staging" } });
      if (r.landed_at) pulls.push({ number: 700 + n, merged_at: r.landed_at, base: { ref: "main" } });
      if (pulls.length > 0) commitPulls[r.sha] = pulls;
    });
    writeScenario(\`registry-trust-\${name}\`, {
      issues: [{ number: issueNumber, pull_request: null }],
      comments: { [String(issueNumber)]: [idx, rr, ...evidence, ...unindexed] },
      commits: {},
      registry_commits: revisions.map((r) => ({ sha: r.sha })),
      registry_contents: registryContents,
      commit_pulls: commitPulls,
      meta: { runId, trustedActorIds: fixture.cli_trusted_actor_ids, issueNumber, expect: fixture.expect, description: fixture.description },
    });
  });
}

// --- #741 shepherd round 1 (Codex-confirmed P2): a CLI-selected but
// registry-unauthorized actor posts a LOWER-id index for the run; the
// legitimate author posts the same marker later. Canonical selection must
// run among candidates authenticated at their own write time, so the
// forged index never shadows the legitimate one and the run harvests.
{
  const trustSha = "4".repeat(40);
  const registryCommits = [{ sha: trustSha }];
  const registryContents = {
    [trustSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [TRUSTED_ORCHESTRATOR] })).toString("base64"),
  };
  const runId = "run-forged-index-shadow-1";
  const at = "2026-09-01T00:00:00Z";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: at,
    stage_transitions: chain([{ stage: "kickoff", entered_at: at }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const body = { ...runBody, ...deriveDefaultChains(runBody) };
  const rm = marker("run-record", runId, "kickoff", "issue", null, 1);
  const rr = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${rm}\n\${fence(JSON.stringify(body))}\`, at);
  const im = marker("run-index", runId, "kickoff", "issue", null, 1);
  const forgedPayload = { run_id: runId, initiated_by: "human", branch: null, run_record: { id: String(rr.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator" } };
  // Forged index FIRST (lower comment id) by OTHER_TRUSTED, who is in the
  // operator's CLI selection but NOT in the registry allowlist.
  const forgedIdx = comment(OTHER_TRUSTED, "impostor", \`\${im}\n\${fence(JSON.stringify(forgedPayload))}\`, "2026-09-01T00:00:30Z");
  const legitIdx = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${im}\n\${fence(JSON.stringify(forgedPayload))}\`, "2026-09-01T00:01:00Z");
  writeScenario("forged-index-shadow", {
    issues: [{ number: 180, pull_request: null }],
    comments: { "180": [rr, forgedIdx, legitIdx] },
    commits: {},
    registry_commits: registryCommits,
    registry_contents: registryContents,
    commit_pulls: { [trustSha]: [{ number: 620, merged_at: "2026-08-01T00:00:00Z" }] },
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR, OTHER_TRUSTED], issueNumber: 180, legitIdxId: legitIdx.id },
  });
}

// --- #741 shepherd round 2 (Codex-confirmed P2): a lower-id index posted
// while its author was listed but EDITED after that author's removal is a
// post-removal write; pre-selection must authenticate the edit too, so
// the later legitimate index by a still-trusted orchestrator wins.
{
  const trustBothSha = "6".repeat(40);
  const removeSha = "7".repeat(40);
  const registryCommits = [{ sha: removeSha }, { sha: trustBothSha }];
  const registryContents = {
    [trustBothSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [TRUSTED_ORCHESTRATOR, OTHER_TRUSTED] })).toString("base64"),
    [removeSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [OTHER_TRUSTED] })).toString("base64"),
  };
  const runId = "run-edited-index-shadow-1";
  const at = "2026-09-01T00:00:00Z";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: at,
    stage_transitions: chain([{ stage: "kickoff", entered_at: at }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const body = { ...runBody, ...deriveDefaultChains(runBody) };
  const rm = marker("run-record", runId, "kickoff", "issue", null, 1);
  const rr = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${rm}\n\${fence(JSON.stringify(body))}\`, at);
  const im = marker("run-index", runId, "kickoff", "issue", null, 1);
  const payload = { run_id: runId, initiated_by: "human", branch: null, run_record: { id: String(rr.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator" } };
  // TRUSTED_ORCHESTRATOR's own index, posted while listed (00:00:30) and
  // edited after the 00:10 removal.
  const editedIdx = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${im}\n\${fence(JSON.stringify(payload))}\`, "2026-09-01T00:00:30Z");
  editedIdx.updated_at = "2026-09-01T00:20:00Z";
  // A legitimate later duplicate by OTHER_TRUSTED, still listed.
  const legitIdx = comment(OTHER_TRUSTED, "other-orchestrator", \`\${im}\n\${fence(JSON.stringify(payload))}\`, "2026-09-01T00:25:00Z");
  writeScenario("edited-index-shadow", {
    issues: [{ number: 181, pull_request: null }],
    comments: { "181": [rr, editedIdx, legitIdx] },
    commits: {},
    registry_commits: registryCommits,
    registry_contents: registryContents,
    commit_pulls: {
      [trustBothSha]: [{ number: 621, merged_at: "2026-08-01T00:00:00Z" }],
      [removeSha]: [{ number: 622, merged_at: "2026-09-01T00:10:00Z" }],
    },
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR, OTHER_TRUSTED], issueNumber: 181 },
  });
}

// --- #741 shepherd round 3 (Codex-confirmed P2): a direct-push registry
// commit OLDER than a resolvable PR-landed revision no longer voids the
// whole history — the later revision governs writes after its landing;
// writes before it still find no revision and are indeterminate.
{
  const scaffoldSha = "9".repeat(40); // direct push, no merging PR
  const laterSha = "a".repeat(40);    // PR-landed 2026-08-15
  const registryCommits = [{ sha: laterSha }, { sha: scaffoldSha }]; // newest-first
  const registryContents = {
    [laterSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [TRUSTED_ORCHESTRATOR] })).toString("base64"),
    [scaffoldSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [TRUSTED_ORCHESTRATOR] })).toString("base64"),
  };
  const mk = (runId, at) => {
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: chain([{ stage: "kickoff", entered_at: at }]),
      interventions: chain([]), settlements: chain([]),
      outcome: null, pr: null, evidence_comments: [], promotion: null,
    };
    return runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, at);
  };
  const after = mk("run-older-direct-push-after-1", "2026-09-01T00:00:00Z");
  const before = mk("run-older-direct-push-before-1", "2026-08-01T00:00:00Z");
  writeScenario("older-direct-push", {
    issues: [{ number: 182, pull_request: null }, { number: 183, pull_request: null }],
    comments: { "182": [after.index, after.record], "183": [before.index, before.record] },
    commits: {},
    registry_commits: registryCommits,
    registry_contents: registryContents,
    commit_pulls: { [laterSha]: [{ number: 623, merged_at: "2026-08-15T00:00:00Z" }] },
    meta: { runIdAfter: "run-older-direct-push-after-1", runIdBefore: "run-older-direct-push-before-1", trustedActorIds: [TRUSTED_ORCHESTRATOR] },
  });
}

// --- #741 shepherd round 4 (Codex-confirmed P2): a higher-id duplicate
// index whose write time cannot be evaluated (posted in the far future
// relative to the history snapshot) must not sink a run whose lower-id
// index is already authenticated.
{
  const trustSha = "b".repeat(40);
  const registryCommits = [{ sha: trustSha }];
  const registryContents = {
    [trustSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [TRUSTED_ORCHESTRATOR] })).toString("base64"),
  };
  const runId = "run-later-duplicate-unresolvable-1";
  const at = "2026-09-01T00:00:00Z";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: at,
    stage_transitions: chain([{ stage: "kickoff", entered_at: at }]),
    interventions: chain([]), settlements: chain([]),
    outcome: null, pr: null, evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, at);
  const im = marker("run-index", runId, "kickoff", "issue", null, 1);
  const payload = { run_id: runId, initiated_by: "human", branch: null, run_record: { id: String(rr.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator" } };
  const laterDup = comment(TRUSTED_ORCHESTRATOR, "orchestrator", \`\${im}\n\${fence(JSON.stringify(payload))}\`, "2099-01-01T00:00:00Z");
  writeScenario("later-duplicate-unresolvable", {
    issues: [{ number: 184, pull_request: null }],
    comments: { "184": [idx, rr, laterDup] },
    commits: {},
    registry_commits: registryCommits,
    registry_contents: registryContents,
    commit_pulls: { [trustSha]: [{ number: 624, merged_at: "2026-08-01T00:00:00Z" }] },
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 184 },
  });
}

// --- #952: canonical --run lookup bypasses the full issue listing, while
// both the direct issue read and discovery tolerate output above Node's
// default 1 MiB synchronous-child buffer.
{
  const runId = "run-185-large-buffer";
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: "2026-09-01T00:00:00Z",
    stage_transitions: chain([{ stage: "kickoff", entered_at: "2026-09-01T00:00:00Z" }]),
    interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
    evidence_comments: [], promotion: null,
  };
  const { index: idx, record: rr } = runRecordComment(
    TRUSTED_ORCHESTRATOR, "orchestrator", runId, runBody, "2026-09-01T00:00:00Z",
  );
  writeScenario("large-buffer", {
    issues: [{ number: 185, pull_request: null, padding: "x".repeat(2 * 1024 * 1024) }],
    comments: { "185": [idx, rr] }, commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 185 },
  });
}

// --- #962: the grammar emitted by the review skill authenticates a local record.
{
  const runId = "run-186-evidence-grammar";
  const at = "2026-09-01T00:00:00Z";
  const ev = evidenceSummaryComment(
    OTHER_TRUSTED, "other-orchestrator", runId, "review", "issue", 1, 1, "2026-09-01T00:25:00Z",
  );
  const prEv = evidenceSummaryComment(
    OTHER_TRUSTED, "other-orchestrator", runId, "integration", "pr", null, 1, "2026-09-01T00:26:00Z",
  );
  const revoked = evidenceSummaryComment(
    TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, "2026-09-01T00:00:30Z",
  );
  revoked.updated_at = "2026-09-01T00:20:00Z";
  const wrongDestination = evidenceSummaryComment(
    OTHER_TRUSTED, "other-orchestrator", runId, "integration", "pr", null, 1, "2026-09-01T00:24:00Z",
  );
  const markerShape = { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 };
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: at,
    stage_transitions: lifecycleTo("review", at),
    interventions: chain([]), settlements: chain([]), outcome: null,
    evidence_comments: [
      {
        id: String(ev.id), author_actor_id: OTHER_TRUSTED, login: "other-orchestrator",
        digest: payloadDigest(ev.body), marker: markerShape,
      },
    ],
    receipts: [
      { kind: "transition", stage: "review", entered_at: at },
      { kind: "pass", file: "review-r1" },
    ],
    pr: null, promotion: null,
  };
  const localRunDir = path.join("${tmp}", "local-records", runId);
  mkdirSync(path.join(localRunDir, "passes"), { recursive: true });
  mkdirSync(path.join(localRunDir, "adjudications"), { recursive: true });
  writeFileSync(path.join(localRunDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
  const localPass = pass("codex-verification", []);
  localPass.run.run_id = runId;
  localPass.payload.stage = "review";
  localPass.payload.round = 1;
  writeFileSync(path.join(localRunDir, "passes", "review-r1.json"), JSON.stringify(localPass, null, 2));
  const stalePass = pass("codex-verification", [{ priority: "P1", summary: "must not be counted" }]);
  stalePass.run.run_id = runId;
  writeFileSync(path.join(localRunDir, "passes", "stale.json"), JSON.stringify(stalePass, null, 2));
  writeFileSync(path.join(localRunDir, "adjudications", "review-r1.json"), JSON.stringify({
    schema: 2, run_id: runId, stage: "review", round: 1,
    reviewed_head: "0".repeat(40), adjudications: [],
  }, null, 2));
  const legacyRunId = "run-186-legacy";
  const legacyBody = {
    schema: 2, run_id: legacyRunId, initiated_by: "human", started_at: at,
    stage_transitions: chain([{ stage: "kickoff", entered_at: at }]),
    interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
    evidence_comments: [], promotion: null,
  };
  const legacy = runRecordComment(OTHER_TRUSTED, "other-orchestrator", legacyRunId, legacyBody, at);
  const migratedLegacy = runRecordComment(OTHER_TRUSTED, "other-orchestrator", runId, runBody, at);
  const trustBothSha = "8".repeat(40);
  const removeSha = "9".repeat(40);
  writeScenario("evidence-grammar", {
    issues: [{ number: 186, pull_request: null }], comments: { "186": [legacy.index, legacy.record, migratedLegacy.index, migratedLegacy.record, revoked, wrongDestination, prEv, ev] }, commits: {},
    registry_commits: [{ sha: removeSha }, { sha: trustBothSha }],
    registry_contents: {
      [trustBothSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [TRUSTED_ORCHESTRATOR, OTHER_TRUSTED] })).toString("base64"),
      [removeSha]: Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [OTHER_TRUSTED] })).toString("base64"),
    },
    commit_pulls: {
      [trustBothSha]: [{ number: 625, merged_at: "2026-08-01T00:00:00Z" }],
      [removeSha]: [{ number: 626, merged_at: "2026-09-01T00:10:00Z" }],
    },
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 186, wrongDestinationId: wrongDestination.id, unvisitedStageId: prEv.id },
  });
}

// --- #962: schema-valid run ids that do not encode an issue still use current-marker discovery.
{
  const runId = "evidence-run-arbitrary";
  const at = "2026-09-01T00:00:00Z";
  const ev = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
  const markerShape = { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 };
  const runBody = {
    schema: 2, run_id: runId, initiated_by: "human", started_at: at,
    stage_transitions: lifecycleTo("review", at),
    interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
    slot_failures: [{ stage: "review", round: 2, slot: "codex-verification", reason: "finder_unavailable" }],
    evidence_comments: [{ id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(ev.body), marker: markerShape }],
    promotion: null,
  };
  const localRunDir = path.join("${tmp}", "local-records", runId);
  mkdirSync(localRunDir, { recursive: true });
  writeFileSync(path.join(localRunDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
  writeZeroFindingAdjudication(localRunDir, runId);
  writeCompletedZeroFindingPass(localRunDir, runId);
  writeScenario("arbitrary-evidence-run", {
    issues: [{ number: 187, pull_request: null }], comments: { "187": [ev] }, commits: {},
    meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 187 },
  });
}

// --- #962 challenge r3: destination-scoped presence and current-first migration.
{
  const at = "2026-09-01T00:00:00Z";

  const prOnlyRunId = "run-188-pr-only";
  const prOnly = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", prOnlyRunId, "integration", "pr", null, 1, at);
  const prOnlyBody = {
    schema: 2, run_id: prOnlyRunId, initiated_by: "human", started_at: at,
    stage_transitions: lifecycleTo("integration", at),
    interventions: chain([]), settlements: chain([]), outcome: null,
    pr: { number: 9188, url: "https://github.com/o/r/pull/9188" },
    evidence_comments: [{ id: String(prOnly.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(prOnly.body), marker: { run_id: prOnlyRunId, stage: "integration", destination: "pr", round: null, sequence: 1 } }],
    promotion: null,
  };
  const prOnlyDir = path.join("${tmp}", "local-records", prOnlyRunId);
  mkdirSync(prOnlyDir, { recursive: true });
  writeFileSync(path.join(prOnlyDir, "run.json"), JSON.stringify({ ...prOnlyBody, ...deriveDefaultChains(prOnlyBody) }, null, 2));
  writeScenario("evidence-pr-only", {
    issues: [{ number: 188, pull_request: null }, { number: 9188, pull_request: { url: "https://github.com/o/r/pulls/9188" } }], comments: { "188": [], "9188": [prOnly] }, commits: {},
    meta: { runId: prOnlyRunId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 188 },
  });

  const unverifiedRunId = "run-189-unverified-pr";
  const issueMarker = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", unverifiedRunId, "review", "issue", 1, 1, at);
  const unverifiedBody = {
    schema: 2, run_id: unverifiedRunId, initiated_by: "human", started_at: at,
    stage_transitions: lifecycleTo("review", at),
    interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
    evidence_comments: [
      { id: String(issueMarker.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(issueMarker.body), marker: { run_id: unverifiedRunId, stage: "review", destination: "issue", round: 1, sequence: 1 } },
      { id: "999998", author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: "not-fetched", marker: { run_id: unverifiedRunId, stage: "integration", destination: "pr", round: null, sequence: 1 } },
    ],
    promotion: null,
  };
  const unverifiedDir = path.join("${tmp}", "local-records", unverifiedRunId);
  mkdirSync(unverifiedDir, { recursive: true });
  writeFileSync(path.join(unverifiedDir, "run.json"), JSON.stringify({ ...unverifiedBody, ...deriveDefaultChains(unverifiedBody) }, null, 2));
  writeZeroFindingAdjudication(unverifiedDir, unverifiedRunId);
  writeCompletedZeroFindingPass(unverifiedDir, unverifiedRunId);
  writeScenario("evidence-unverified-pr", {
    issues: [{ number: 189, pull_request: null }], comments: { "189": [issueMarker] }, commits: {},
    meta: { runId: unverifiedRunId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 189 },
  });

  const malformedRunId = "run-190-current-first";
  const current = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", malformedRunId, "review", "issue", 1, 1, at);
  const malformedLegacy = comment(TRUSTED_ORCHESTRATOR, "orchestrator", marker("run-index", malformedRunId, "kickoff", "issue", null, 1), at);
  const currentBody = {
    schema: 2, run_id: malformedRunId, initiated_by: "human", started_at: at,
    stage_transitions: lifecycleTo("review", at),
    interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
    evidence_comments: [{ id: String(current.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(current.body), marker: { run_id: malformedRunId, stage: "review", destination: "issue", round: 1, sequence: 1 } }],
    promotion: null,
  };
  const currentDir = path.join("${tmp}", "local-records", malformedRunId);
  mkdirSync(currentDir, { recursive: true });
  writeFileSync(path.join(currentDir, "run.json"), JSON.stringify({ ...currentBody, ...deriveDefaultChains(currentBody) }, null, 2));
  writeZeroFindingAdjudication(currentDir, malformedRunId);
  writeCompletedZeroFindingPass(currentDir, malformedRunId);
  writeScenario("evidence-current-first", {
    issues: [{ number: 190, pull_request: null }], comments: { "190": [malformedLegacy, current] }, commits: {},
    meta: { runId: malformedRunId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber: 190 },
  });

  const arbitraryPrRunId = "evidence-pr-only-arbitrary";
  const arbitraryPr = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", arbitraryPrRunId, "integration", "pr", null, 1, at);
  const arbitraryIssue = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", arbitraryPrRunId, "review", "issue", 1, 1, at);
  const arbitraryPrBody = {
    schema: 2, run_id: arbitraryPrRunId, initiated_by: "human", started_at: at,
    stage_transitions: lifecycleTo("integration", at),
    interventions: chain([]), settlements: chain([]), outcome: null,
    pr: { number: 9191, url: "https://github.com/o/r/pull/9191" },
    evidence_comments: [
      { id: String(arbitraryPr.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(arbitraryPr.body), marker: { run_id: arbitraryPrRunId, stage: "integration", destination: "pr", round: null, sequence: 1 } },
      { id: String(arbitraryIssue.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(arbitraryIssue.body), marker: { run_id: arbitraryPrRunId, stage: "review", destination: "issue", round: 1, sequence: 1 } },
    ],
    promotion: null,
  };
  const arbitraryPrDir = path.join("${tmp}", "local-records", arbitraryPrRunId);
  mkdirSync(arbitraryPrDir, { recursive: true });
  writeFileSync(path.join(arbitraryPrDir, "run.json"), JSON.stringify({ ...arbitraryPrBody, ...deriveDefaultChains(arbitraryPrBody) }, null, 2));
  writeZeroFindingAdjudication(arbitraryPrDir, arbitraryPrRunId);
  writeCompletedZeroFindingPass(arbitraryPrDir, arbitraryPrRunId);
  writeScenario("evidence-pr-only-arbitrary", {
    issues: [{ number: 191, pull_request: null }, { number: 192, pull_request: null }, { number: 9191, pull_request: { url: "https://github.com/o/r/pulls/9191" } }], comments: { "191": [], "192": [arbitraryIssue], "9191": [arbitraryPr] }, commits: {},
    meta: { runId: arbitraryPrRunId, trustedActorIds: [TRUSTED_ORCHESTRATOR] },
  });

  const unboundRunId = "evidence-pr-only-unbound";
  const unboundPr = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", unboundRunId, "integration", "pr", null, 1, at);
  const unboundBody = {
    schema: 2, run_id: unboundRunId, initiated_by: "human", started_at: at,
    stage_transitions: lifecycleTo("integration", at),
    interventions: chain([]), settlements: chain([]), outcome: null,
    pr: { number: 9193, url: "https://github.com/o/r/pull/9193" },
    evidence_comments: [{ id: String(unboundPr.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(unboundPr.body), marker: { run_id: unboundRunId, stage: "integration", destination: "pr", round: null, sequence: 1 } }],
    promotion: null,
  };
  const unboundDir = path.join("${tmp}", "local-records", unboundRunId);
  mkdirSync(unboundDir, { recursive: true });
  writeFileSync(path.join(unboundDir, "run.json"), JSON.stringify({ ...unboundBody, ...deriveDefaultChains(unboundBody) }, null, 2));
  writeScenario("evidence-pr-only-unbound", {
    issues: [{ number: 193, pull_request: null }, { number: 194, pull_request: null }, { number: 9193, pull_request: { url: "https://github.com/o/r/pulls/9193" } }], comments: { "193": [], "194": [], "9193": [unboundPr] }, commits: {},
    meta: { runId: unboundRunId, trustedActorIds: [TRUSTED_ORCHESTRATOR] },
  });

  const writeSegmentScenario = (name, issueNumber, sequences, withAdjudication) => {
    const runId = "run-" + issueNumber + "-" + name;
    const comments = sequences.map((sequence) => evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, sequence, at));
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: comments.map((item, index) => ({
        id: String(item.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(item.body),
        marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: sequences[index] },
      })),
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    if (withAdjudication) writeZeroFindingAdjudication(runDir, runId);
    if (name === "evidence-sequence-valid" || name === "evidence-adjudication-clean") writeCompletedZeroFindingPass(runDir, runId);
    writeScenario(name, {
      issues: [{ number: issueNumber, pull_request: null }], comments: { [String(issueNumber)]: comments }, commits: {},
      meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR], issueNumber },
    });
  };
  writeSegmentScenario("evidence-sequence-two-only", 195, [2], true);
  writeSegmentScenario("evidence-sequence-gap", 196, [1, 3], true);
  writeSegmentScenario("evidence-sequence-valid", 197, [1, 2], true);
  writeSegmentScenario("evidence-adjudication-missing", 198, [1], false);
  writeSegmentScenario("evidence-adjudication-clean", 199, [1], true);

  // Integration envelopes use role + integration_round rather than the
  // confidence-pass payload's stage + round coordinates.
  {
    const runId = "run-200-integration-envelope";
    const at = "2026-09-01T00:00:00Z";
    const ev = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "integration", "issue", 1, 1, at);
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("integration", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [{ id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(ev.body), marker: { run_id: runId, stage: "integration", destination: "issue", round: 1, sequence: 1 } }],
      receipts: [{ kind: "transition", stage: "integration" }, { kind: "pass", file: "integration-r1" }], promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(path.join(runDir, "passes"), { recursive: true });
    mkdirSync(path.join(runDir, "adjudications"), { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    const envelope = JSON.parse(readFileSync(path.join("${repo}", "ai/schemas/fixtures/result.integrator.schema/valid/verdict-findings.json"), "utf8"));
    envelope.run.run_id = runId;
    writeFileSync(path.join(runDir, "passes", "integration-r1.json"), JSON.stringify(envelope, null, 2));
    writeFileSync(path.join(runDir, "adjudications", "integration-r1.json"), JSON.stringify({ schema: 2, run_id: runId, stage: "integration", round: 1, reviewed_head: envelope.head, adjudications: [] }, null, 2));
    writeScenario("integration-envelope", { issues: [{ number: 200, pull_request: null }], comments: { "200": [ev] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // A historical cutoff retains only round 1 while disclosing round 2's
  // adjudication as future evidence.
  {
    const runId = "run-201-future-adjudication";
    const at = "2026-09-01T00:00:00Z";
    const first = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, "2026-09-01T00:10:00Z");
    const second = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 2, 1, "2026-09-01T01:00:00Z");
    const entries = [first, second].map((comment, index) => ({ id: String(comment.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(comment.body), marker: { run_id: runId, stage: "review", destination: "issue", round: index + 1, sequence: 1 } }));
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null, evidence_comments: entries,
      receipts: [{ kind: "transition", stage: "review" }, { kind: "pass", file: "review-r1" }, { kind: "pass", file: "review-r2" }], promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId, "review", 1);
    writeZeroFindingAdjudication(runDir, runId, "review", 2);
    const firstPass = pass("codex-verification", []);
    firstPass.run.run_id = runId;
    const secondPass = structuredClone(firstPass);
    secondPass.payload.round = 2;
    mkdirSync(path.join(runDir, "passes"), { recursive: true });
    writeFileSync(path.join(runDir, "passes", "review-r1.json"), JSON.stringify(firstPass, null, 2));
    writeFileSync(path.join(runDir, "passes", "review-r2.json"), JSON.stringify(secondPass, null, 2));
    writeScenario("future-adjudication", { issues: [{ number: 201, pull_request: null }], comments: { "201": [first, second] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // Two trusted issues claiming the same arbitrary run id are ambiguous.
  {
    const runId = "duplicate-authoritative-binding";
    const first = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, "2026-09-01T00:00:00Z");
    const second = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, "2026-09-01T00:00:00Z");
    writeScenario("duplicate-authoritative-binding", { issues: [{ number: 202, pull_request: null }, { number: 203, pull_request: null }], comments: { "202": [first], "203": [second] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // A selected local record can retain one current marker and one legacy
  // evidence registration without calling the legacy comment deleted.
  {
    const runId = "run-204-mixed-registration";
    const at = "2026-09-01T00:00:00Z";
    const current = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
    const legacyPayload = JSON.stringify({ note: "legacy segment" });
    const legacy = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 2, { note: "legacy segment" }, at);
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [
        { id: String(current.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(current.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 } },
        { id: String(legacy.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(legacyPayload), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 2 } },
      ], promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId);
    writeCompletedZeroFindingPass(runDir, runId);
    writeScenario("mixed-registration", { issues: [{ number: 204, pull_request: null }], comments: { "204": [current, legacy] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // harmon-devkit#1001 item 9: author_actor_id must be a strict positive
  // integer, never loosely coerced (Number("9001") === 9001 would otherwise
  // authenticate a string).
  {
    const runId = "run-210-strict-actor-id";
    const at = "2026-09-01T00:00:00Z";
    const ev = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [{ id: String(ev.id), author_actor_id: String(TRUSTED_ORCHESTRATOR), login: "orchestrator", digest: payloadDigest(ev.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 } }],
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId);
    writeCompletedZeroFindingPass(runDir, runId);
    writeScenario("strict-actor-id", { issues: [{ number: 210, pull_request: null }], comments: { "210": [ev] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // harmon-devkit#1001 item 5: a marker created before an --as-of cutoff
  // but edited (updated_at) after it must not be admitted from its present
  // (edited) body.
  {
    const runId = "run-211-edited-after-cutoff";
    const first = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, "2026-09-01T00:10:00Z");
    const second = { ...evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 2, 1, "2026-09-01T00:15:00Z"), updated_at: "2026-09-01T01:00:00Z" };
    const entries = [first, second].map((c, index) => ({ id: String(c.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(c.body), marker: { run_id: runId, stage: "review", destination: "issue", round: index + 1, sequence: 1 } }));
    const at = "2026-09-01T00:00:00Z";
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null, evidence_comments: entries,
      receipts: [{ kind: "transition", stage: "review" }, { kind: "pass", file: "review-r1" }, { kind: "pass", file: "review-r2" }], promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId, "review", 1);
    writeZeroFindingAdjudication(runDir, runId, "review", 2);
    const firstPass = pass("codex-verification", []);
    firstPass.run.run_id = runId;
    const secondPass = structuredClone(firstPass);
    secondPass.payload.round = 2;
    mkdirSync(path.join(runDir, "passes"), { recursive: true });
    writeFileSync(path.join(runDir, "passes", "review-r1.json"), JSON.stringify(firstPass, null, 2));
    writeFileSync(path.join(runDir, "passes", "review-r2.json"), JSON.stringify(secondPass, null, 2));
    writeScenario("edited-after-cutoff", { issues: [{ number: 211, pull_request: null }], comments: { "211": [first, second] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // harmon-devkit#1001 item 6: an unregistered LEGACY-grammar comment from
  // the run's own trusted author is a trusted orphan and must be reported
  // under orphan_comments, not silently absent — findOrphanEvidence must
  // run over the local path too, not just the GitHub-comment harvest path.
  {
    const runId = "run-212-legacy-orphan";
    const at = "2026-09-01T00:00:00Z";
    const current = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
    const orphanLegacy = evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 2, { note: "never registered" }, at);
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [{ id: String(current.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(current.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 } }],
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId);
    writeCompletedZeroFindingPass(runDir, runId);
    writeScenario("legacy-orphan", { issues: [{ number: 212, pull_request: null }], comments: { "212": [current, orphanLegacy] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // harmon-devkit#1001 challenge round 5/7 (P2), confirmed and fixed round
  // 6/7: mirrors run-211-edited-after-cutoff's current-grammar case, but for
  // the LEGACY orphan-detection path (findOrphanEvidence) — this previously
  // checked only created_at, unlike visibleMarkers, so a legacy comment
  // edited after an --as-of cutoff could leak a post-cutoff orphan finding
  // into a historical read.
  {
    const runId = "run-220-legacy-orphan-edited-after-cutoff";
    const at = "2026-09-01T00:00:00Z";
    const current = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
    const orphanLegacy = { ...evidenceComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 2, { note: "edited after cutoff" }, "2026-09-01T00:05:00Z"), updated_at: "2026-09-01T01:00:00Z" };
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [{ id: String(current.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(current.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 } }],
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId);
    writeCompletedZeroFindingPass(runDir, runId);
    writeScenario("legacy-orphan-edited-after-cutoff", { issues: [{ number: 220, pull_request: null }], comments: { "220": [current, orphanLegacy] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // harmon-devkit#1001 item 10: a blocked envelope on disk with no matching
  // "pass" receipt must not inflate the blocked-pass count.
  {
    const runId = "run-213-unreceipted-blocked";
    const at = "2026-09-01T00:00:00Z";
    const ev = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [{ id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(ev.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 } }],
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId);
    writeCompletedZeroFindingPass(runDir, runId);
    // A blocked envelope for the same round, written directly and never
    // receipted — simulates a dispatch attempt that crashed before its
    // receipt was recorded.
    const blocked = pass("codex-verification", []);
    blocked.run.run_id = runId;
    blocked.status = "blocked";
    blocked.payload.stage = "review";
    blocked.payload.round = 1;
    mkdirSync(path.join(runDir, "passes"), { recursive: true });
    writeFileSync(path.join(runDir, "passes", "review-r1-blocked.json"), JSON.stringify(blocked, null, 2));
    writeScenario("unreceipted-blocked", { issues: [{ number: 213, pull_request: null }], comments: { "213": [ev] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // harmon-devkit#1001 item 3: a local run record's pr.number that does not
  // actually name a pull request must not be silently trusted as PR
  // evidence via the generic issue-comments endpoint.
  {
    const runId = "run-214-pr-not-a-pr";
    const at = "2026-09-01T00:00:00Z";
    const ev = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null,
      pr: { number: 9214, url: "https://github.com/o/r/pull/9214" },
      evidence_comments: [{ id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(ev.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 } }],
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId);
    writeCompletedZeroFindingPass(runDir, runId);
    // Issue 9214 exists in the fixture DB but is a plain issue
    // (pull_request: null) — the generic issue-comments endpoint would
    // otherwise succeed for it exactly as it does for a real PR.
    writeScenario("pr-not-a-pr", { issues: [{ number: 214, pull_request: null }, { number: 9214, pull_request: null }], comments: { "214": [ev], "9214": [] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // harmon-devkit#1001 item 12: a local record whose rounds are not
  // contiguous from 1 must be indeterminate — the engine's own
  // contiguous-from-1 guard, now reached via the CLI on every invocation
  // (previously unreachable on the imported-helper path).
  {
    const runId = "run-215-round-gap";
    const at = "2026-09-01T00:00:00Z";
    const r1 = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
    const r3 = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 3, 1, at);
    const entries = [
      { id: String(r1.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(r1.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 } },
      { id: String(r3.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(r3.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 3, sequence: 1 } },
    ];
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null, evidence_comments: entries,
      receipts: [{ kind: "transition", stage: "review" }, { kind: "pass", file: "review-r1" }, { kind: "pass", file: "review-r3" }], promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId, "review", 1);
    writeZeroFindingAdjudication(runDir, runId, "review", 3);
    const p1 = pass("codex-verification", []);
    p1.run.run_id = runId;
    const p3 = structuredClone(p1);
    p3.payload.round = 3;
    mkdirSync(path.join(runDir, "passes"), { recursive: true });
    writeFileSync(path.join(runDir, "passes", "review-r1.json"), JSON.stringify(p1, null, 2));
    writeFileSync(path.join(runDir, "passes", "review-r3.json"), JSON.stringify(p3, null, 2));
    writeScenario("round-gap", { issues: [{ number: 215, pull_request: null }], comments: { "215": [r1, r3] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // harmon-devkit#1001 item 3 (challenge round 3): a run whose only "review"
  // evidence is a truncated/malformed pass file, with no other confidence
  // evidence at all, must not silently report success — neither confidence
  // stage would otherwise invoke the engine, so nothing would ever open the
  // malformed file to reject it.
  {
    const runId = "run-216-malformed-only-evidence";
    const at = "2026-09-01T00:00:00Z";
    const ev = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [{ id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(ev.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 } }],
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    // No receipts, no valid pass/adjudication/slot-failure for "review" at
    // all — only a truncated file that will never parse.
    mkdirSync(path.join(runDir, "passes"), { recursive: true });
    writeFileSync(path.join(runDir, "passes", "review-r1.json"), '{"schema": 2, "role":');
    writeScenario("malformed-only-evidence", { issues: [{ number: 216, pull_request: null }], comments: { "216": [ev] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // harmon-devkit#1001 round 2's deferred finding #3, now fixed as a side
  // effect of challenge round 4's restructure: a run whose only evidence is
  // integration (no challenge/review pass at all) still has every one of
  // its passes schema/receipt-validated, because the engine is now invoked
  // for both confidence stages unconditionally — validateReceipts (inside
  // either invocation) checks every pass on disk regardless of --stage.
  {
    const runId = "run-217-integration-only-unreceipted";
    const at = "2026-09-01T00:00:00Z";
    const ev = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "integration", "issue", 1, 1, at);
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("integration", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [{ id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(ev.body), marker: { run_id: runId, stage: "integration", destination: "issue", round: 1, sequence: 1 } }],
      // Deliberately no receipts array at all — this integrator pass is
      // never receipted, matching exactly what the deferred finding
      // described disappearing: "the previous unconditional receipt/schema
      // validation of every pass".
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(path.join(runDir, "passes"), { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    const envelope = JSON.parse(readFileSync(path.join("${repo}", "ai/schemas/fixtures/result.integrator.schema/valid/verdict-findings.json"), "utf8"));
    envelope.run.run_id = runId;
    writeFileSync(path.join(runDir, "passes", "integration-r1.json"), JSON.stringify(envelope, null, 2));
    writeScenario("integration-only-unreceipted", { issues: [{ number: 217, pull_request: null }], comments: { "217": [ev] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // harmon-devkit#1001 challenge round 5/7 (P1), confirmed and fixed round
  // 6/7: the more representative shape than run-200's integration-only
  // record — a run with GENUINE review evidence (a real, receipted,
  // completed pass and its adjudication) that has ALSO reached and
  // completed integration. Before the fix, the mere presence of the
  // integration-round adjudication made every confidence-stage engine
  // invocation indeterminate regardless of what real evidence sat beside
  // it; per-stage adjudication filtering must let this real review round
  // compute exactly as it would without the integration adjudication
  // present at all.
  {
    const runId = "run-218-review-and-integration-complete";
    const at = "2026-09-01T00:00:00Z";
    const ev = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("integration", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [{ id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(ev.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 } }],
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId, "review", 1);
    writeCompletedZeroFindingPass(runDir, runId, "review", 1);
    const envelope = JSON.parse(readFileSync(path.join("${repo}", "ai/schemas/fixtures/result.integrator.schema/valid/verdict-findings.json"), "utf8"));
    envelope.run.run_id = runId;
    writeFileSync(path.join(runDir, "passes", "integration-r1.json"), JSON.stringify(envelope, null, 2));
    writeFileSync(path.join(runDir, "adjudications", "integration-r1.json"), JSON.stringify({ schema: 2, run_id: runId, stage: "integration", round: 1, reviewed_head: envelope.head, adjudications: [] }, null, 2));
    const run2 = JSON.parse(readFileSync(path.join(runDir, "run.json"), "utf8"));
    run2.receipts = [...(run2.receipts || []), { kind: "transition", stage: "integration" }, { kind: "pass", file: "integration-r1" }];
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify(run2, null, 2));
    writeScenario("review-and-integration-complete", { issues: [{ number: 218, pull_request: null }], comments: { "218": [ev] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // A clean review round plus a SECOND, receipted, initially-valid blocked
  // envelope for the same round — reused by the shell harness below, which
  // races a live corruption of that exact file against the frozen snapshot
  // (harmon-devkit#1001 challenge round 5/7, finding #2). localPassFileByName
  // must resolve to the snapshot's copy, not this live path, or the later
  // blocked-pass schema re-validation would see the corrupted bytes instead
  // of what the engine actually classified as blocked.
  {
    const runId = "run-219-freeze-race";
    const at = "2026-09-01T00:00:00Z";
    const ev = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [{ id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(ev.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 } }],
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId, "review", 1);
    writeCompletedZeroFindingPass(runDir, runId, "review", 1);
    const blocked = pass("codex-verification", []);
    blocked.run.run_id = runId;
    blocked.status = "blocked";
    blocked.payload.stage = "review";
    blocked.payload.round = 1;
    writeFileSync(path.join(runDir, "passes", "review-r1-blocked.json"), JSON.stringify(blocked, null, 2));
    const run2 = JSON.parse(readFileSync(path.join(runDir, "run.json"), "utf8"));
    run2.receipts = [...(run2.receipts || []), { kind: "pass", file: "review-r1-blocked" }];
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify(run2, null, 2));
    writeScenario("freeze-race", { issues: [{ number: 219, pull_request: null }], comments: { "219": [ev] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // harmon-devkit#1001 review round 1 (P1): a run genuinely still IN
  // PROGRESS on challenge — real evidence for challenge round 1, no review
  // evidence at all yet, no "transition: review" receipt — is the ordinary,
  // common shape for any run harvested mid-flight, not an edge case.
  {
    const runId = "run-221-challenge-still-active";
    const at = "2026-09-01T00:00:00Z";
    const ev = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "challenge", "issue", 1, 1, at);
    // lifecycleTo has no "challenge" destination (only "review"/"integration"
    // ever push it) — built inline here rather than extending a helper 200+
    // other fixtures share.
    const challengeStages = ["kickoff", "claim", "implement", "verify", "challenge"];
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: chain(challengeStages.map((stage, index) => ({
        stage, entered_at: at,
        ...(index < challengeStages.length - 1 ? { exit: "fixture transition to " + challengeStages[index + 1] } : {}),
      }))),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [{ id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(ev.body), marker: { run_id: runId, stage: "challenge", destination: "issue", round: 1, sequence: 1 } }],
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId, "challenge", 1);
    writeCompletedZeroFindingPass(runDir, runId, "challenge", 1);
    writeScenario("challenge-still-active", { issues: [{ number: 221, pull_request: null }], comments: { "221": [ev] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // harmon-devkit#1001 review round 2 (P1), confirmed and fixed: round 1's
  // reviewed_head ("1" x 40) is neither equal to nor a real git ancestor of
  // round 2's ("0" x 40, the standard fixture placeholder, auto-selected as
  // --current-head since round 2 is the highest round) — ancestry
  // computes false/unknown either way, so round 1 is excluded from the
  // engine's ancestry-retained set and its finding's provenance/fingerprint
  // never go through applyVerification at all, landing on "not-measured".
  {
    const runId = "run-222-not-measured-provenance";
    const at = "2026-09-01T00:00:00Z";
    const ev1 = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
    const ev2 = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 2, 1, at);
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [
        { id: String(ev1.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(ev1.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 } },
        { id: String(ev2.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(ev2.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 2, sequence: 1 } },
      ],
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    const round1Pass = pass("codex-verification", [{ priority: "P2", class: "correctness" }]);
    round1Pass.run.run_id = runId;
    round1Pass.head = "1".repeat(40);
    round1Pass.payload.round = 1;
    round1Pass.payload.reviewed_head = "1".repeat(40);
    mkdirSync(path.join(runDir, "passes"), { recursive: true });
    writeFileSync(path.join(runDir, "passes", "review-r1.json"), JSON.stringify(round1Pass, null, 2));
    mkdirSync(path.join(runDir, "adjudications"), { recursive: true });
    writeFileSync(path.join(runDir, "adjudications", "review-r1.json"), JSON.stringify({
      schema: 2, run_id: runId, stage: "review", round: 1, reviewed_head: "1".repeat(40),
      adjudications: [{
        finding_id: round1Pass.payload.findings[0].id, reviewer_priority: "P2", adjudicated_priority: "P2",
        disposition: "fix", reason: "confirmed", evidence: "fixture evidence", override: null,
      }],
    }, null, 2));
    writeZeroFindingAdjudication(runDir, runId, "review", 2);
    const round2Pass = pass("codex-verification", []);
    round2Pass.run.run_id = runId;
    round2Pass.payload.round = 2;
    writeFileSync(path.join(runDir, "passes", "review-r2.json"), JSON.stringify(round2Pass, null, 2));
    const run2 = JSON.parse(readFileSync(path.join(runDir, "run.json"), "utf8"));
    run2.receipts = [
      ...(run2.receipts || []),
      { kind: "transition", stage: "review" },
      { kind: "pass", file: "review-r1" },
      { kind: "pass", file: "review-r2" },
    ];
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify(run2, null, 2));
    writeScenario("not-measured-provenance", { issues: [{ number: 222, pull_request: null }], comments: { "222": [ev1, ev2] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // Integration Codex cycle 1 (P2), confirmed and fixed: a receipted blocked
  // envelope for a round with no other artifact previously received no
  // validation at all (the engine never emits a round object for a round
  // whose only pass is blocked, and blockedPassesToValidate used to be
  // sourced only from the engine's own rounds). A wrong-run_id blocked
  // envelope is deliberately malformed evidence — a run whose harvester
  // still reports "ok" over it is the regression this proves closed.
  {
    const runId = "run-224-blocked-wrong-runid";
    const at = "2026-09-01T00:00:00Z";
    const ev = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [{ id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(ev.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 } }],
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId, "review", 1);
    writeCompletedZeroFindingPass(runDir, runId, "review", 1);
    // Round 2's ONLY artifact: a receipted, blocked envelope naming a
    // DIFFERENT run_id than this run's own — the engine emits no round 2 at
    // all for a blocked-only round, so this is only ever caught by scanning
    // the local pass files directly.
    const blocked = pass("codex-verification", []);
    blocked.run.run_id = "some-other-run-entirely";
    blocked.status = "blocked";
    blocked.payload.stage = "review";
    blocked.payload.round = 2;
    writeFileSync(path.join(runDir, "passes", "review-r2-blocked.json"), JSON.stringify(blocked, null, 2));
    const run2 = JSON.parse(readFileSync(path.join(runDir, "run.json"), "utf8"));
    run2.receipts = [...(run2.receipts || []), { kind: "pass", file: "review-r2-blocked" }];
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify(run2, null, 2));
    writeScenario("blocked-wrong-runid", { issues: [{ number: 224, pull_request: null }], comments: { "224": [ev] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // Integration Codex cycle 1 (P2), confirmed and fixed: --repo-root now
  // defaults to the resolved git toplevel instead of process.cwd(), so a
  // --run invocation launched from a repository subdirectory (no explicit
  // --repo-root) resolves the same .devflow.toml the root would.
  {
    const runId = "run-225-subdirectory-repo-root";
    const at = "2026-09-01T00:00:00Z";
    const ev = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: lifecycleTo("review", at),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [{ id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(ev.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 } }],
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId, "review", 1);
    writeCompletedZeroFindingPass(runDir, runId, "review", 1);
    writeScenario("subdirectory-repo-root", { issues: [{ number: 225, pull_request: null }], comments: { "225": [ev] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }

  // Integration Codex cycle 2 (P2), confirmed and fixed: the engine's
  // "review cannot be active until challenge exits" guard used to fire for
  // EVERY --stage review query while challenge was the latest active stage
  // — including a --verification-only read of review's own already-retained
  // round after a legitimate remediation loop (review ran, converged, then
  // challenge was re-entered), silently discarding review's real
  // trajectory. The engine now recognizes that retrospective shape via the
  // trusted receipts' own earlier "transition into review" and returns
  // review's retained round instead.
  {
    const runId = "run-226-review-then-challenge-reentry";
    const at = "2026-09-01T00:00:00Z";
    const ev = evidenceSummaryComment(TRUSTED_ORCHESTRATOR, "orchestrator", runId, "review", "issue", 1, 1, at);
    // lifecycleTo has no "review -> challenge re-entry" destination — built
    // inline here rather than extending a helper 200+ other fixtures share,
    // same reasoning as run-221-challenge-still-active above. Unlike the
    // engine's own receipts (no edge-legality check at all — see
    // dev-flow-exit.mjs's own comment on that), stage_transitions IS
    // checked against validate-result-schemas.mjs's ALLOWED_EDGES, which
    // has no direct review->challenge edge — only review->implement, then
    // implement->verify, then verify->challenge (the exact "review ->
    // implement -> verify -> challenge" shape Codex's own finding named).
    const reentryStages = ["kickoff", "claim", "implement", "verify", "review", "implement", "verify", "challenge"];
    const runBody = {
      schema: 2, run_id: runId, initiated_by: "human", started_at: at,
      stage_transitions: chain(reentryStages.map((stage, index) => ({
        stage, entered_at: at,
        ...(index < reentryStages.length - 1 ? { exit: "fixture transition to " + reentryStages[index + 1] } : {}),
      }))),
      interventions: chain([]), settlements: chain([]), outcome: null, pr: null,
      evidence_comments: [{ id: String(ev.id), author_actor_id: TRUSTED_ORCHESTRATOR, login: "orchestrator", digest: payloadDigest(ev.body), marker: { run_id: runId, stage: "review", destination: "issue", round: 1, sequence: 1 } }],
      promotion: null,
    };
    const runDir = path.join("${tmp}", "local-records", runId);
    mkdirSync(runDir, { recursive: true });
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify({ ...runBody, ...deriveDefaultChains(runBody) }, null, 2));
    writeZeroFindingAdjudication(runDir, runId, "review", 1);
    writeCompletedZeroFindingPass(runDir, runId, "review", 1);
    // The re-entry itself: a bare transition receipt into "challenge", no
    // pass of its own — the minimal shape that exercises the engine's fix,
    // mirroring exactly how scripts/test-dev-flow-exit.sh proves it there.
    const run2 = JSON.parse(readFileSync(path.join(runDir, "run.json"), "utf8"));
    run2.receipts = [...(run2.receipts || []), { kind: "transition", stage: "challenge" }];
    writeFileSync(path.join(runDir, "run.json"), JSON.stringify(run2, null, 2));
    writeScenario("review-then-challenge-reentry", { issues: [{ number: 226, pull_request: null }], comments: { "226": [ev] }, commits: {}, meta: { runId, trustedActorIds: [TRUSTED_ORCHESTRATOR] } });
  }
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

echo "== issue discovery tolerates >1 MiB output and projects paginated fields =="
export DFSTATS_DB="$tmp/scenarios/large-buffer.json"
export DFSTATS_GH_LOG="$tmp/large-buffer-discovery-gh.log"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.cohort_size == 1 and .per_issue[0].issueNumber == 185' >/dev/null ||
    fail "large-buffer discovery: expected the oversized issue to be harvested"
grep -Fq 'api --paginate --slurp repos/o/r/issues?state=all&per_page=100 --jq map(.[] | {number, pull_request})' "$DFSTATS_GH_LOG" ||
    fail "large-buffer discovery: issue listing was not paginated and projected"

echo "== canonical --run reads only its issue and succeeds with >1 MiB gh output =="
export DFSTATS_GH_LOG="$tmp/large-buffer-run-gh.log"
run_id="$(meta large-buffer .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e --arg run "$run_id" '.run_id == $run and .issue == 185' >/dev/null ||
    fail "large-buffer --run: expected the canonical run from issue #185"
grep -Fq 'api repos/o/r/issues/185' "$DFSTATS_GH_LOG" ||
    fail "large-buffer --run: direct issue lookup was not used"
if grep -Fq 'issues?state=all' "$DFSTATS_GH_LOG"; then
    fail "large-buffer --run: unexpectedly listed every issue"
fi

echo "== canonical --run maps a missing inferred issue to run-not-found =="
if node scripts/dev-flow-stats.mjs --repo o/r --run run-999-missing --trusted-actor-id 9001 --json >"$tmp/missing-run.out" 2>"$tmp/missing-run.err"; then
    fail "missing canonical run: expected run-not-found"
else
    rc=$?
    [ "$rc" -eq 1 ] || fail "missing canonical run: expected exit 1, got $rc"
fi
grep -Fq 'run "run-999-missing" not found (searched issue #999 in o/r)' "$tmp/missing-run.err" ||
    fail "missing canonical run: expected targeted run-not-found diagnostic"
unset DFSTATS_GH_LOG

echo "== review evidence grammar reconstructs its authenticated local record beside a legacy run =="
export DFSTATS_DB="$tmp/scenarios/evidence-grammar.json"
run_id="$(meta evidence-grammar .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9002 --json)"
# harmon-devkit#1001 item 7: a trusted actor's marker naming the wrong
# destination or a stage never visited is a structural anomaly in the
# MARKER, not a forged-author claim — it belongs in tampered_comments, not
# forged_comments (which is reserved for a genuinely untrusted actor).
echo "$out" | jq -e --arg run "$run_id" --argjson wrong "$(meta evidence-grammar .meta.wrongDestinationId)" --argjson stage "$(meta evidence-grammar .meta.unvisitedStageId)" '.run_id == $run and .issue == 186 and .rounds == [{stage:"review",round:1,pass_count:1,blocked_passes:0,adjudication_count:1,finding_count:0,has_adjudication:true,provenance_measurement:"not-applicable"}] and .provenance_unavailable_rounds == [] and .unreceipted_pass_files == ["stale"] and ([.tampered_comments[].id] | index($wrong) != null and index($stage) != null) and ([.forged_comments[].id] | index($wrong) == null and index($stage) == null) and .legacy_also_present == true' >/dev/null ||
    fail "evidence grammar: expected the local run and its authenticated review round, got: $out"

echo "== --as-of authenticates remote markers but discloses the local trajectory as current-state =="
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9002 --as-of 2026-09-01T00:25:30Z --json)"
echo "$out" | jq -e --argjson future "$(meta evidence-grammar .meta.unvisitedStageId)" '.rounds == [{stage:"review",round:1,pass_count:1,blocked_passes:0,adjudication_count:1,finding_count:0,has_adjudication:true,provenance_measurement:"not-applicable"}] and .slot_failures == [] and .slot_failures_unavailable == false and .future_adjudication_files == [] and .local_record_current_state == true and ([.tampered_comments[].id] | index($future) != null)' >/dev/null ||
    fail "evidence grammar as-of: local evidence was not disclosed as current-state: $out"
text_out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9002 --as-of 2026-09-01T00:25:30Z)"
grep -Fq 'local record read at current state; not reconstructable to the cutoff' <<<"$text_out" ||
    fail "evidence grammar as-of: missing current-state disclosure: $text_out"

echo "== current evidence wins when legacy evidence names the same run, with migration disclosed =="
text_out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9002)"
grep -Fq 'legacy-also-present: true' <<<"$text_out" ||
    fail "evidence grammar: expected the text report to disclose legacy-also-present, got: $text_out"

echo "== a local current record fails closed when a registered comment is no longer observed =="
cp "$tmp/local-records/$run_id/run.json" "$tmp/local-records/$run_id/run.json.saved"
node --input-type=module - "$tmp/local-records/$run_id/run.json.saved" "$tmp/local-records/$run_id/run.json" <<'NODE'
import { readFileSync, writeFileSync } from "node:fs";
import { entryDigest, GENESIS } from "./scripts/dev-flow-stats.mjs";
const [source, destination] = process.argv.slice(2);
const body = JSON.parse(readFileSync(source, "utf8"));
body.evidence_comments.push({ id: "999999", author_actor_id: 9002, login: "other-orchestrator", digest: "missing", marker: { run_id: body.run_id, stage: "review", destination: "issue", round: 2, sequence: 2 } });
let previous = GENESIS;
body.evidence_registrations = body.evidence_comments.map((entry, seq) => {
    const content = { id: entry.id, author_actor_id: entry.author_actor_id, login: entry.login, payload_digest: entry.digest, marker: entry.marker, registered_at: body.started_at };
    const digest = entryDigest(content, previous);
    const result = { ...content, seq, digest, prev_digest: previous };
    previous = digest;
    return result;
});
writeFileSync(destination, JSON.stringify(body, null, 2));
NODE
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9002 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq '999999' <<<"$out" && grep -Fq 'deleted-entry tampering' <<<"$out" ||
    fail "evidence grammar: expected missing registered comment 999999 to be indeterminate, got rc=$rc: $out"
mv "$tmp/local-records/$run_id/run.json.saved" "$tmp/local-records/$run_id/run.json"

echo "== receipt sequence requires the pass to follow a transition into its stage =="
cp "$tmp/local-records/$run_id/run.json" "$tmp/local-records/$run_id/run.json.saved"
for receipt_case in before-transition wrong-stage; do
    if [ "$receipt_case" = before-transition ]; then
        jq '.receipts = [{kind:"pass",file:"review-r1"},{kind:"transition",stage:"review",entered_at:.started_at}]' \
            "$tmp/local-records/$run_id/run.json.saved" >"$tmp/local-records/$run_id/run.json"
    else
        jq '.receipts = [{kind:"transition",stage:"challenge",entered_at:.started_at},{kind:"pass",file:"review-r1"}]' \
            "$tmp/local-records/$run_id/run.json.saved" >"$tmp/local-records/$run_id/run.json"
    fi
    set +e
    out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9002 --json 2>&1)"
    rc=$?
    set -e
    if [ "$receipt_case" = before-transition ]; then
        # harmon-devkit#1001 challenge round 1 (P1), confirmed: a marker
        # whose only backing pass the engine rejects (stage not active when
        # it arrived) must fail closed (record-missing), not silently
        # succeed with an empty rounds array — the marker still authenticates
        # that a review round 1 exists, and the trusted evidence chain
        # cannot actually back it.
        [ "$rc" -eq 3 ] && grep -Fq 'record-missing: authenticated review round 1 marker group has no retained pass, adjudication, or slot failure' <<<"$out" ||
            fail "evidence grammar: exit engine did not fail closed for the pass arriving before its transition, rc=$rc: $out"
    else
        [ "$rc" -eq 3 ] && grep -Fq 'failed exit-engine validation: FAIL:' <<<"$out" ||
            fail "evidence grammar: complete validation did not reject the wrong-stage receipt sequence, rc=$rc: $out"
    fi
done
mv "$tmp/local-records/$run_id/run.json.saved" "$tmp/local-records/$run_id/run.json"

echo "== every local-record read target stays beneath --record-dir =="
mkdir -p "$tmp/symlink-records"
ln -s "$tmp/local-records/$run_id" "$tmp/symlink-records/$run_id"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/symlink-records" --trusted-actor-id 9002 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'symbolic link' <<<"$out" ||
    fail "evidence grammar: expected run-directory symlink escape to be indeterminate, got rc=$rc: $out"

echo "== review evidence grammar without a local input reports evidence-only marker facts =="
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9002 --json)"
echo "$out" | jq -e --arg run "$run_id" '.status == "evidence-only" and .run_id == $run and .pr_binding == null and .marker_facts == [{stage:"review",destination:"issue",round:1,sequence:1}] and (.untrusted_marker_facts | length) == 3 and .legacy_also_present == true' >/dev/null ||
    fail "evidence grammar: expected evidence-only marker facts, got: $out"

echo "== current-marker trust uses the configured read-time set without registry history =="
export DFSTATS_DB="$tmp/scenarios/arbitrary-evidence-run.json"
run_id="$(meta arbitrary-evidence-run .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.status == "evidence-only" and (.marker_facts | length) == 1' >/dev/null ||
    fail "current configured-set trust: expected evidence without registry history, got: $out"

echo "== a PR-only current marker is fetched and authenticated through the local PR binding =="
export DFSTATS_DB="$tmp/scenarios/evidence-pr-only.json"
run_id="$(meta evidence-pr-only .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e --arg run "$run_id" '.run_id == $run and .issue == 188 and .rounds == [] and .unverified_evidence_destinations == []' >/dev/null ||
    fail "PR-only current marker: expected authenticated local trajectory, got: $out"

echo "== malformed trusted PR evidence propagates beyond the local binding probe =="
cp "$tmp/scenarios/evidence-pr-only.json" "$tmp/scenarios/evidence-pr-only.json.saved"
jq '.comments["9188"][0].body = "<!-- dev-flow-v2-evidence: malformed -->"' "$tmp/scenarios/evidence-pr-only.json.saved" >"$tmp/scenarios/evidence-pr-only.json"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'trusted evidence comment' <<<"$out" && grep -Fq 'malformed dev-flow-v2-evidence marker' <<<"$out" ||
    fail "PR-only current marker: malformed trusted evidence was swallowed by the probe, rc=$rc: $out"
mv "$tmp/scenarios/evidence-pr-only.json.saved" "$tmp/scenarios/evidence-pr-only.json"

echo "== a later authoritative issue marker wins over an earlier PR-only rejection =="
export DFSTATS_DB="$tmp/scenarios/evidence-pr-only-arbitrary.json"
run_id="$(meta evidence-pr-only-arbitrary .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e --arg run "$run_id" '.run_id == $run and .issue == 192' >/dev/null ||
    fail "arbitrary PR-only binding: later authoritative issue marker did not win: $out"

echo "== arbitrary-id PR-only evidence remains unverified when no issue authenticates it =="
export DFSTATS_DB="$tmp/scenarios/evidence-pr-only-unbound.json"
run_id="$(meta evidence-pr-only-unbound .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'unverified for issue #193' <<<"$out" && grep -Fq 'issue marker or canonical run-id issue binding' <<<"$out" ||
    fail "arbitrary PR-only binding: expected an unverified issue-binding refusal, got rc=$rc: $out"

echo "== complete validation rejects malformed retained registrations =="
export DFSTATS_DB="$tmp/scenarios/evidence-unverified-pr.json"
run_id="$(meta evidence-unverified-pr .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'evidence_comments[1].digest' <<<"$out" ||
    fail "malformed retained registration: expected complete-validator refusal, rc=$rc: $out"

echo "== malformed legacy evidence cannot suppress an authenticated current marker =="
export DFSTATS_DB="$tmp/scenarios/evidence-current-first.json"
run_id="$(meta evidence-current-first .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e --arg run "$run_id" '.run_id == $run and .issue == 190 and (.rounds | length) == 1' >/dev/null ||
    fail "current-first migration: malformed legacy evidence suppressed the current run: $out"

echo "== malformed unselected local bytes cannot suppress authenticated legacy evidence =="
export DFSTATS_DB="$tmp/scenarios/happy.json"
run_id="$(meta happy .meta.runId)"
mkdir -p "$tmp/local-records/$run_id"
printf '%s\n' '{not-json' >"$tmp/local-records/$run_id/run.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.outcome == "ready-for-review" and .issue == 101' >/dev/null ||
    fail "current selection: unselected malformed local bytes suppressed the legacy run: $out"
rm -rf "$tmp/local-records/$run_id"

echo "== a marker whose named local record is absent reports record-missing =="
export DFSTATS_DB="$tmp/scenarios/evidence-grammar.json"
run_id="$(meta evidence-grammar .meta.runId)"
mkdir -p "$tmp/empty-records"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/empty-records" --trusted-actor-id 9002 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] && grep -Fq 'record-missing' <<<"$out" ||
    fail "evidence grammar: expected exit 1 record-missing, got rc=$rc: $out"

echo "== current-marker discovery supports schema-valid run ids without an encoded issue number =="
export DFSTATS_DB="$tmp/scenarios/arbitrary-evidence-run.json"
run_id="$(meta arbitrary-evidence-run .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e --arg run "$run_id" '.run_id == $run and .issue == 187 and .rounds == [{stage:"review",round:1,pass_count:1,blocked_passes:0,adjudication_count:1,finding_count:0,has_adjudication:true,provenance_measurement:"not-applicable"}] and .slot_failures == [{stage:"review",round:2,slot:"codex-verification",reason:"finder_unavailable"}]' >/dev/null ||
    fail "evidence grammar: expected all-issue lookup to find the arbitrary run id, got: $out"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --as-of 2026-09-01T00:30:00Z --json)"
echo "$out" | jq -e '.slot_failures == [{stage:"review",round:2,slot:"codex-verification",reason:"finder_unavailable"}] and .slot_failures_unavailable == false and .local_record_current_state == true' >/dev/null ||
    fail "evidence grammar as-of: current local slot failures were cutoff-filtered: $out"

for scenario in evidence-sequence-two-only evidence-sequence-gap; do
    echo "== current-marker groups reject a non-contiguous sequence: $scenario =="
    export DFSTATS_DB="$tmp/scenarios/$scenario.json"
    run_id="$(meta "$scenario" .meta.runId)"
    set +e
    out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 3 ] && grep -Fq 'unique contiguous sequences starting at 1' <<<"$out" ||
        fail "evidence sequence: expected indeterminate contiguous-sequence refusal, got rc=$rc: $out"
    set +e
    out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --json 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 3 ] && grep -Fq 'unique contiguous sequences starting at 1' <<<"$out" ||
        fail "evidence-only sequence: expected indeterminate contiguous-sequence refusal, got rc=$rc: $out"
done

echo "== a valid multi-segment current-marker group projects one retained round =="
export DFSTATS_DB="$tmp/scenarios/evidence-sequence-valid.json"
run_id="$(meta evidence-sequence-valid .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.rounds == [{stage:"review",round:1,pass_count:1,blocked_passes:0,adjudication_count:1,finding_count:0,has_adjudication:true,provenance_measurement:"not-applicable"}]' >/dev/null ||
    fail "evidence sequence: valid multi-segment group did not reconstruct: $out"

echo "== an authenticated marker with no retained artifact is record-missing =="
export DFSTATS_DB="$tmp/scenarios/evidence-adjudication-missing.json"
run_id="$(meta evidence-adjudication-missing .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'record-missing: authenticated review round 1 marker group' <<<"$out" ||
    fail "evidence adjudication: marker-only evidence was silently omitted, rc=$rc: $out"

echo "== a completed zero-finding pass and adjudication are projected without deriving an exit =="
export DFSTATS_DB="$tmp/scenarios/evidence-adjudication-clean.json"
run_id="$(meta evidence-adjudication-clean .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.rounds == [{stage:"review",round:1,pass_count:1,blocked_passes:0,adjudication_count:1,finding_count:0,has_adjudication:true,provenance_measurement:"not-applicable"}]' >/dev/null ||
    fail "evidence adjudication: completed zero-finding pass and adjudication were not projected: $out"

echo "== the complete run-record validator rejects an invalid first transition =="
cp "$tmp/local-records/$run_id/run.json" "$tmp/local-records/$run_id/run.json.saved"
node --input-type=module - "$tmp/local-records/$run_id/run.json.saved" "$tmp/local-records/$run_id/run.json" <<'NODE'
import { readFileSync, writeFileSync } from "node:fs";
import { entryDigest, GENESIS } from "./scripts/dev-flow-stats.mjs";
const [source, destination] = process.argv.slice(2);
const body = JSON.parse(readFileSync(source, "utf8"));
body.stage_transitions[0].stage = "review";
let previous = GENESIS;
body.stage_transitions = body.stage_transitions.map((entry, seq) => {
  const { digest: _digest, prev_digest: _previous, seq: _seq, ...content } = entry;
  const digest = entryDigest(content, previous);
  const result = { ...content, seq, digest, prev_digest: previous };
  previous = digest;
  return result;
});
writeFileSync(destination, JSON.stringify(body, null, 2));
NODE
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'failed exit-engine validation: FAIL:' <<<"$out" && grep -Fq 'stage_transitions' <<<"$out" ||
    fail "run-record validation: invalid first transition was accepted, rc=$rc: $out"
mv "$tmp/local-records/$run_id/run.json.saved" "$tmp/local-records/$run_id/run.json"

# harmon-devkit#1001 challenge round 3/4 briefly regressed this fixture (the
# per-stage "does this stage have evidence" gate was deleted, so the engine
# was invoked for both confidence stages unconditionally, and its
# orphan-adjudication guard — not itself stage-scoped, since an integrator
# envelope's payload has no stage/round fields shaped like a confidence
# pass's — read this run's own "integration-r1" adjudication as orphaned the
# moment the engine was invoked at all). Round 5/7 confirmed that was a real
# regression, not a stricter-and-correct behavior change: it made every
# genuinely completed, integrated run indeterminate, not merely this
# fixture. Round 6/7 restored per-stage adjudication filtering (each
# confidence-stage engine snapshot carries only that stage's own
# adjudications; passes and run.json are unaffected), so this integration-
# only record is back to its original expectation below.
echo "== the exit-engine trajectory does not synthesize integration rounds, and discloses integration as not measured from local evidence =="
export DFSTATS_DB="$tmp/scenarios/integration-envelope.json"
run_id="$(meta integration-envelope .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.rounds == [] and .integration_evidence == "not-measured" and (has("integration_passes") | not)' >/dev/null ||
    fail "integration envelope coordinates: harvester did not disclose integration as not measured from local evidence (never a count, never zero): $out"
out_table="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001)"
grep -Fq 'integration: not measured from local evidence' <<<"$out_table" ||
    fail "integration envelope coordinates: the table renderer did not disclose integration as not measured: $out_table"

echo "== a completed integration adjudication does not block harvesting real review evidence (harmon-devkit#1001 challenge round 5/7, fixed round 6/7) =="
export DFSTATS_DB="$tmp/scenarios/review-and-integration-complete.json"
run_id="$(meta review-and-integration-complete .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '(.rounds | length) == 1 and .rounds[0].stage == "review" and .rounds[0].round == 1 and .rounds[0].pass_count == 1 and .rounds[0].finding_count == 0 and .rounds[0].has_adjudication == true' >/dev/null ||
    fail "review+integration complete: expected the review round to compute cleanly alongside the completed integration adjudication: $out"

echo "== a live-directory corruption after the freeze does not affect the harvested output (harmon-devkit#1001 challenge round 5/7, finding #2, fixed round 6/7) =="
# Races a corruption of the live review-r1-blocked.json against the frozen
# snapshot: localPassFileByName must resolve to the SNAPSHOT's copy, not
# this live path, or the later blocked-pass schema re-validation would read
# the corrupted bytes instead of what the engine actually classified as
# blocked when it ran. Synchronized on the per-stage engine snapshot
# directory appearing under the temp root — that directory is built FROM
# the frozen copy, so its existence proves the initial freeze has already
# completed and the live file is safe to corrupt without affecting a
# correctly-fixed harvester.
export DFSTATS_DB="$tmp/scenarios/freeze-race.json"
run_id="$(meta freeze-race .meta.runId)"
race_run_dir="$tmp/local-records/$run_id"
race_out="$tmp/freeze-race-out.json"
race_err="$tmp/freeze-race-err.log"
# harmon-devkit#1001 review round 2 (P2), confirmed and fixed: watching a
# system-wide ${TMPDIR:-/tmp} glob could match an unrelated concurrent
# process's own dev-flow-stats-stage-* directory (another session, a
# parallel CI run) and return early, corrupting the live file before this
# test's own child actually finished freezing it — nondeterministic, not a
# real test of the invariant. Node's os.tmpdir() honors TMPDIR, so giving
# the child its own isolated one and watching only that directory removes
# the collision entirely; no production-code change needed.
race_tmp_base="$tmp/freeze-race-tmpdir"
mkdir -p "$race_tmp_base"
TMPDIR="$race_tmp_base" node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json >"$race_out" 2>"$race_err" &
race_pid=$!
observed_freeze=""
race_deadline=$((SECONDS + 20))
while [ "$SECONDS" -lt "$race_deadline" ]; do
    if compgen -G "$race_tmp_base/dev-flow-stats-stage-*" >/dev/null; then
        observed_freeze=1
        break
    fi
    sleep 0.01
done
if [ -n "$observed_freeze" ]; then
    printf '{"corrupted' >"$race_run_dir/passes/review-r1-blocked.json"
fi
set +e
wait "$race_pid"
race_rc=$?
set -e
[ -n "$observed_freeze" ] ||
    fail "freeze race: the per-stage engine snapshot directory was never observed — this test did not exercise the race"
[ "$race_rc" -eq 0 ] ||
    fail "freeze race: harvester failed after a post-freeze live corruption, rc=$race_rc: $(cat "$race_err")"
race_result="$(cat "$race_out")"
echo "$race_result" | jq -e '(.rounds | length) == 1 and .rounds[0].stage == "review" and .rounds[0].round == 1' >/dev/null ||
    fail "freeze race: expected the review round to still compute after the live corruption: $race_result"

echo "== --as-of excludes a round whose marker was posted after the cutoff (harmon-devkit#1001 item 11) =="
# Round 2's marker was posted at 01:00, after this --as-of cutoff of 00:30 —
# byRound must be built from the cutoff-VISIBLE marker set, not merely the
# authenticated one, or round 2 leaks into what is supposed to be a
# historical read (harmon-devkit#1001 item 11). Round 1's own marker (posted
# at 00:10) is visible, so it still renders — and reads from the local
# record's CURRENT-STATE files exactly as any other round would.
export DFSTATS_DB="$tmp/scenarios/future-adjudication.json"
run_id="$(meta future-adjudication .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --as-of 2026-09-01T00:30:00Z --json)"
echo "$out" | jq -e '(.rounds | length) == 1 and .rounds[0].round == 1 and .future_adjudication_files == [] and .local_record_current_state == true' >/dev/null ||
    fail "future adjudication cutoff: a post-cutoff round leaked into the historical read: $out"

echo "== author_actor_id must be a strict positive integer, never coerced (harmon-devkit#1001 item 9) =="
export DFSTATS_DB="$tmp/scenarios/strict-actor-id.json"
run_id="$(meta strict-actor-id .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'does not authenticate evidence comment' <<<"$out" ||
    fail "strict actor id: a string author_actor_id was coerced into authenticating, rc=$rc: $out"

echo "== a marker edited (updated_at) after an --as-of cutoff is not admitted from its present body (harmon-devkit#1001 item 5) =="
export DFSTATS_DB="$tmp/scenarios/edited-after-cutoff.json"
run_id="$(meta edited-after-cutoff .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --as-of 2026-09-01T00:30:00Z --json)"
echo "$out" | jq -e '(.rounds | length) == 1 and .rounds[0].round == 1' >/dev/null ||
    fail "edited after cutoff: round 2 (edited after the cutoff) leaked into the historical read: $out"

echo "== an unregistered legacy comment from the trusted author surfaces as a local orphan (harmon-devkit#1001 item 6) =="
export DFSTATS_DB="$tmp/scenarios/legacy-orphan.json"
run_id="$(meta legacy-orphan .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '(.orphan_comments | length) == 1' >/dev/null ||
    fail "legacy orphan: expected exactly one orphan comment, got: $out"

echo "== a legacy orphan comment edited (updated_at) after an --as-of cutoff is not admitted from its present body (harmon-devkit#1001 challenge round 5/7, fixed round 6/7) =="
export DFSTATS_DB="$tmp/scenarios/legacy-orphan-edited-after-cutoff.json"
run_id="$(meta legacy-orphan-edited-after-cutoff .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --as-of 2026-09-01T00:30:00Z --json)"
echo "$out" | jq -e '(.orphan_comments | length) == 0' >/dev/null ||
    fail "legacy orphan edited after cutoff: a legacy comment edited after the cutoff leaked into a historical orphan read: $out"

echo "== an unreceipted blocked envelope does not inflate blocked_passes (harmon-devkit#1001 item 10) =="
export DFSTATS_DB="$tmp/scenarios/unreceipted-blocked.json"
run_id="$(meta unreceipted-blocked .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.rounds == [{stage:"review",round:1,pass_count:1,blocked_passes:0,adjudication_count:1,finding_count:0,has_adjudication:true,provenance_measurement:"not-applicable"}]' >/dev/null ||
    fail "unreceipted blocked: expected blocked_passes to stay 0, got: $out"

echo "== a local run record's pr.number that is not a real pull request is rejected (harmon-devkit#1001 item 3) =="
export DFSTATS_DB="$tmp/scenarios/pr-not-a-pr.json"
run_id="$(meta pr-not-a-pr .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'does not name a pull request' <<<"$out" ||
    fail "pr-not-a-pr: expected indeterminate rejection, got rc=$rc: $out"

echo "== a round gap (round 1 then round 3, no round 2) is indeterminate (harmon-devkit#1001 item 12) =="
export DFSTATS_DB="$tmp/scenarios/round-gap.json"
run_id="$(meta round-gap .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'not contiguous from 1' <<<"$out" ||
    fail "round gap: expected indeterminate rejection, got rc=$rc: $out"

# harmon-devkit#1001 challenge round 4: the per-stage evidence gate this
# regression originally targeted was deleted (challenge round 3 found a real
# gap in it; the disposition restructured further rather than patching the
# gate again) — the engine is now invoked unconditionally, so "challenge"
# (evaluated first) reads this run directory's malformed review-r1.json via
# its own loadRunDir before either stage's own evidence is even considered,
# and fails there directly.
echo "== a malformed pass that is the only confidence evidence is indeterminate, not silently absent (harmon-devkit#1001 challenge round 3/4) =="
export DFSTATS_DB="$tmp/scenarios/malformed-only-evidence.json"
run_id="$(meta malformed-only-evidence .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'local-record trajectory for challenge:' <<<"$out" ||
    fail "malformed-only evidence: expected indeterminate rejection, got rc=$rc: $out"

# harmon-devkit#1001 round 2's deferred finding #3, settled fixed as a side
# effect of challenge round 4's restructure: an integration-only run (no
# challenge/review pass or adjudication at all) still gets its integrator
# pass receipt-validated, because the engine is now invoked once per
# confidence stage unconditionally and validateReceipts checks every pass on
# disk regardless of --stage — there is no longer a separate "does this run
# have any confidence-stage evidence" gate standing in front of it.
echo "== an integration-only run's unreceipted pass is still caught by the engine's receipt validation (harmon-devkit#1001 round 2 deferred #3, fixed round 4) =="
export DFSTATS_DB="$tmp/scenarios/integration-only-unreceipted.json"
run_id="$(meta integration-only-unreceipted .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.unreceipted_pass_files == ["integration-r1"] and .rounds == []' >/dev/null ||
    fail "integration-only unreceipted: expected the integrator pass to be reported unreceipted with no confidence rounds: $out"

echo "== two authoritative issue bindings for one arbitrary run are indeterminate =="
export DFSTATS_DB="$tmp/scenarios/duplicate-authoritative-binding.json"
run_id="$(meta duplicate-authoritative-binding .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'more than one authoritative issue binding (#202, #203)' <<<"$out" ||
    fail "authoritative issue binding: expected both issues to be named, got rc=$rc: $out"

echo "== mixed current and legacy registrations are both observed =="
export DFSTATS_DB="$tmp/scenarios/mixed-registration.json"
run_id="$(meta mixed-registration .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.rounds[0].pass_count == 1 and .unverified_evidence_destinations == []' >/dev/null ||
    fail "mixed registrations: legacy evidence was not observed beside current evidence: $out"

echo "== mixed legacy evidence is narrowed to the authenticated run-record author =="
cp "$tmp/scenarios/mixed-registration.json" "$tmp/scenarios/mixed-registration.json.saved"
cp "$tmp/local-records/$run_id/run.json" "$tmp/local-records/$run_id/run.json.saved"
node --input-type=module - "$tmp/scenarios/mixed-registration.json.saved" "$tmp/scenarios/mixed-registration.json" "$tmp/local-records/$run_id/run.json.saved" "$tmp/local-records/$run_id/run.json" <<'NODE'
import { readFileSync, writeFileSync } from "node:fs";
import { entryDigest, GENESIS } from "./scripts/dev-flow-stats.mjs";
const [dbSource, dbTarget, runSource, runTarget] = process.argv.slice(2);
const db = JSON.parse(readFileSync(dbSource, "utf8"));
const run = JSON.parse(readFileSync(runSource, "utf8"));
const legacyId = Number(run.evidence_comments[1].id);
for (const comments of Object.values(db.comments)) {
    const legacy = comments.find((comment) => comment.id === legacyId);
    if (legacy) legacy.user = { id: 9002, login: "other-orchestrator" };
}
const registrySha = db.registry_commits[0].sha;
db.registry_contents[registrySha] = Buffer.from(JSON.stringify({ trusted_orchestrator_actor_ids: [9001, 9002] })).toString("base64");
run.evidence_comments[1].author_actor_id = 9002;
run.evidence_comments[1].login = "other-orchestrator";
let previous = GENESIS;
run.evidence_registrations = run.evidence_comments.map((entry, seq) => {
    const content = { id: entry.id, author_actor_id: entry.author_actor_id, login: entry.login, payload_digest: entry.digest, marker: entry.marker, registered_at: run.started_at };
    const digest = entryDigest(content, previous);
    const result = { ...content, seq, digest, prev_digest: previous };
    previous = digest;
    return result;
});
writeFileSync(dbTarget, JSON.stringify(db, null, 2));
writeFileSync(runTarget, JSON.stringify(run, null, 2));
NODE
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --trusted-actor-id 9002 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'does not authenticate evidence comment' <<<"$out" ||
    fail "mixed registrations: a different trusted actor supplied legacy evidence, rc=$rc: $out"
mv "$tmp/scenarios/mixed-registration.json.saved" "$tmp/scenarios/mixed-registration.json"
mv "$tmp/local-records/$run_id/run.json.saved" "$tmp/local-records/$run_id/run.json"

echo "== registered legacy evidence must keep its marker on the first line =="
cp "$tmp/scenarios/mixed-registration.json" "$tmp/scenarios/mixed-registration.json.saved"
jq '(.comments["204"][] | select(.body | startswith("<!-- devflow:evidence")) | .body) |= ("quoted marker\n" + .)' "$tmp/scenarios/mixed-registration.json.saved" >"$tmp/scenarios/mixed-registration.json"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'does not authenticate evidence comment' <<<"$out" ||
    fail "mixed registrations: moved legacy marker was accepted, rc=$rc: $out"
mv "$tmp/scenarios/mixed-registration.json.saved" "$tmp/scenarios/mixed-registration.json"

echo "== the exit engine rejects a slot failure that contradicts an accepted pass =="
export DFSTATS_DB="$tmp/scenarios/evidence-adjudication-clean.json"
run_id="$(meta evidence-adjudication-clean .meta.runId)"
cp "$tmp/local-records/$run_id/run.json" "$tmp/local-records/$run_id/run.json.saved"
mv "$tmp/local-records/$run_id/adjudications/review-r1.json" "$tmp/local-records/$run_id/adjudications/review-r1.json.saved"
jq '.slot_failures = [{stage:"review",round:1,slot:"codex-verification",reason:"finder_unavailable"}]' "$tmp/local-records/$run_id/run.json.saved" >"$tmp/local-records/$run_id/run.json"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'both an accepted pass and a slot_failures record' <<<"$out" ||
    fail "slot-failure contradiction: expected exit-engine refusal, got rc=$rc: $out"
mv "$tmp/local-records/$run_id/adjudications/review-r1.json.saved" "$tmp/local-records/$run_id/adjudications/review-r1.json"
mv "$tmp/local-records/$run_id/run.json.saved" "$tmp/local-records/$run_id/run.json"

echo "== schema-invalid retained passes fail closed and name their file =="
cp "$tmp/local-records/$run_id/passes/review-r1.json" "$tmp/local-records/$run_id/passes/review-r1.json.saved"
for invalid_case in missing-identity duplicate-finding-id; do
    if [ "$invalid_case" = missing-identity ]; then
        jq 'del(.run.initiated_by)' "$tmp/local-records/$run_id/passes/review-r1.json.saved" >"$tmp/local-records/$run_id/passes/review-r1.json"
    else
        jq '.payload.findings = [{id:"review-r1-codex-verification-1",path:"scripts/dev-flow-stats.mjs",line:1,class:"correctness",provenance:"original",fingerprint:"new",priority:"P2",recommended_disposition:"fix",evidence:"one"},{id:"review-r1-codex-verification-1",path:"scripts/dev-flow-stats.mjs",line:2,class:"correctness",provenance:"original",fingerprint:"new",priority:"P2",recommended_disposition:"fix",evidence:"two"}] | .payload.counts = {P0:0,P1:0,P2:2,P3:0}' "$tmp/local-records/$run_id/passes/review-r1.json.saved" >"$tmp/local-records/$run_id/passes/review-r1.json"
    fi
    # harmon-devkit#1001 challenge round 1 (P1), confirmed: a marker whose
    # only backing pass is schema/receipt-invalid must fail closed
    # (record-missing), not silently succeed with an empty rounds array —
    # same fix as the before-transition case above, for a different
    # rejection cause.
    set +e
    out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 3 ] && grep -Fq 'record-missing: authenticated review round 1 marker group has no retained pass, adjudication, or slot failure' <<<"$out" ||
        fail "retained pass validation ($invalid_case): exit engine did not fail closed for invalid evidence, rc=$rc: $out"
done
mv "$tmp/local-records/$run_id/passes/review-r1.json.saved" "$tmp/local-records/$run_id/passes/review-r1.json"

echo "== a JSON-malformed retained artifact reaches the engine and fails closed (harmon-devkit#1001 challenge round 2) =="
# The engine snapshot must copy every file's raw bytes verbatim, not just the
# entries the harvester's own best-effort scan could parse — otherwise a
# truncated/malformed file is silently absent from what the engine ever
# reads, and the engine can never apply its own fail-closed rejection to
# evidence it never saw.
cp "$tmp/local-records/$run_id/adjudications/review-r1.json" "$tmp/local-records/$run_id/adjudications/review-r1.json.saved"
printf '{"schema": 2, "run_id":' >"$tmp/local-records/$run_id/adjudications/review-r1.json"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
# harmon-devkit#1001 challenge round 4: the engine is now invoked
# unconditionally for "challenge" before "review", and loadRunDir loads
# every file under adjudications/ regardless of --stage, so the malformed
# file is now caught by the FIRST invocation rather than specifically by
# "review"'s own.
[ "$rc" -eq 3 ] && grep -Fq 'local-record trajectory for challenge' <<<"$out" ||
    fail "malformed artifact snapshot: a truncated adjudication file was not rejected by the engine, rc=$rc: $out"
mv "$tmp/local-records/$run_id/adjudications/review-r1.json.saved" "$tmp/local-records/$run_id/adjudications/review-r1.json"

echo "== an adjudication with no completed pass or slot failure is indeterminate =="
cp "$tmp/local-records/$run_id/run.json" "$tmp/local-records/$run_id/run.json.saved"
mv "$tmp/local-records/$run_id/passes/review-r1.json" "$tmp/local-records/$run_id/passes/review-r1.json.saved"
jq '.receipts |= map(select(.kind != "pass" or .file != "review-r1"))' "$tmp/local-records/$run_id/run.json.saved" >"$tmp/local-records/$run_id/run.json"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'adjudication document "review-r1"' <<<"$out" ||
    fail "evidence adjudication source: expected indeterminate, got rc=$rc: $out"
mv "$tmp/local-records/$run_id/passes/review-r1.json.saved" "$tmp/local-records/$run_id/passes/review-r1.json"
mv "$tmp/local-records/$run_id/run.json.saved" "$tmp/local-records/$run_id/run.json"

echo "== the exit engine excludes blocked envelopes from retained round evidence =="
cp "$tmp/local-records/$run_id/run.json" "$tmp/local-records/$run_id/run.json.saved"
cp "$tmp/local-records/$run_id/passes/review-r1.json" "$tmp/local-records/$run_id/passes/review-r1.json.saved"
jq '.slot_failures = [{stage:"review",round:1,slot:"codex-verification",reason:"finder_unavailable"}]' "$tmp/local-records/$run_id/run.json.saved" >"$tmp/local-records/$run_id/run.json"
jq '.status = "blocked" | .payload.findings = [] | .payload.counts = {P0:0,P1:0,P2:0,P3:0}' "$tmp/local-records/$run_id/passes/review-r1.json.saved" >"$tmp/local-records/$run_id/passes/review-r1.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.rounds[0].pass_count == 0 and .rounds[0].blocked_passes == 1 and .rounds[0].status == "capped" and .rounds[0].finding_count == 0' >/dev/null ||
    fail "blocked pass projection: blocked envelope counted as completed evidence: $out"
mv "$tmp/local-records/$run_id/run.json.saved" "$tmp/local-records/$run_id/run.json"
mv "$tmp/local-records/$run_id/passes/review-r1.json.saved" "$tmp/local-records/$run_id/passes/review-r1.json"

echo "== engine attribution stays unverified when no verification ledger exists =="
export DFSTATS_DB="$tmp/scenarios/evidence-grammar.json"
run_id="$(meta evidence-grammar .meta.runId)"
cp "$tmp/local-records/$run_id/passes/review-r1.json" "$tmp/local-records/$run_id/passes/review-r1.json.saved"
cp "$tmp/local-records/$run_id/adjudications/review-r1.json" "$tmp/local-records/$run_id/adjudications/review-r1.json.saved"
jq '.payload.findings = [{id:"review-r1-codex-verification-1",path:"scripts/dev-flow-stats.mjs",line:1,class:"correctness",provenance:"original",fingerprint:"repeat-of:review-r1-codex-verification-1",priority:"P2",recommended_disposition:"fix",evidence:"fixture evidence"}] | .payload.counts = {P0:0,P1:0,P2:1,P3:0}' "$tmp/local-records/$run_id/passes/review-r1.json.saved" >"$tmp/local-records/$run_id/passes/review-r1.json"
jq '.adjudications = [{finding_id:"review-r1-codex-verification-1",reviewer_priority:"P2",adjudicated_priority:"P2",disposition:"defer",reason:"fixture reason",evidence:"fixture evidence",override:null}]' "$tmp/local-records/$run_id/adjudications/review-r1.json.saved" >"$tmp/local-records/$run_id/adjudications/review-r1.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9002 --json)"
echo "$out" | jq -e '.rounds[0].provenance_measurement == "unverified" and .rounds[0].finding_attributions == [{id:"review-r1-codex-verification-1",provenance:"original",provenance_status:"unverified",fingerprint:"repeat-of:review-r1-codex-verification-1",fingerprint_status:"unverified"}] and .findings_by_class_and_provenance == {} and .findings_by_verified_fingerprint == {} and .provenance_unavailable_rounds == [{stage:"review",round:1}]' >/dev/null ||
    fail "unverified finding projection: attribution was mislabeled or counted as verified: $out"
mv "$tmp/local-records/$run_id/passes/review-r1.json.saved" "$tmp/local-records/$run_id/passes/review-r1.json"
mv "$tmp/local-records/$run_id/adjudications/review-r1.json.saved" "$tmp/local-records/$run_id/adjudications/review-r1.json"

echo "== duplicate evidence-comment ids are indeterminate before registration indexing =="
cp "$tmp/local-records/$run_id/run.json" "$tmp/local-records/$run_id/run.json.saved"
node --input-type=module - "$tmp/local-records/$run_id/run.json.saved" "$tmp/local-records/$run_id/run.json" <<'NODE'
import { readFileSync, writeFileSync } from "node:fs";
import { entryDigest, GENESIS } from "./scripts/dev-flow-stats.mjs";
const [source, destination] = process.argv.slice(2);
const body = JSON.parse(readFileSync(source, "utf8"));
body.evidence_comments.push({ ...body.evidence_comments[0] });
let previous = GENESIS;
body.evidence_registrations = body.evidence_comments.map((entry, seq) => {
  const content = { id: entry.id, author_actor_id: entry.author_actor_id, login: entry.login, payload_digest: entry.digest, marker: entry.marker, registered_at: body.started_at };
  const digest = entryDigest(content, previous);
  const result = { ...content, seq, digest, prev_digest: previous };
  previous = digest;
  return result;
});
writeFileSync(destination, JSON.stringify(body, null, 2));
NODE
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9002 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'repeats evidence comment id' <<<"$out" ||
    fail "duplicate evidence-comment id: expected indeterminate, got rc=$rc: $out"
mv "$tmp/local-records/$run_id/run.json.saved" "$tmp/local-records/$run_id/run.json"

echo "== current-marker parsing rejects trailing content and invalid destination/round pairs =="
node --input-type=module -e 'import { parseMarker } from "./scripts/dev-flow-stats.mjs"; const body = (destination, round, tail = "") => `<!-- dev-flow-v2-evidence: {"run_id":"r","stage":"review","round":${round},"sequence":1,"destination":"${destination}"} -->${tail}`; if ([body("issue", 1, " trailing"), body("issue", "null"), body("pr", 1)].some((value) => parseMarker(value) !== null)) process.exit(1)'

echo "== chain fork: two entries claiming the same prev_digest -> indeterminate, never silently resolved =="
export DFSTATS_DB="$tmp/scenarios/fork.json"
run_id="$(meta fork .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "fork: expected exit 3 (indeterminate), got $rc: $out"
grep -qi "chain broken\|indeterminate" <<<"$out" || fail "fork: expected a chain-break/indeterminate reason, got: $out"

echo "== chain fork does not abort the whole --repo scan: other issues still count =="
python3 - "$tmp/scenarios/fork.json" "$tmp/scenarios/happy.json" "$tmp/scenarios/fork-plus-happy.json" <<'PY'
import json, sys
fork = json.load(open(sys.argv[1]))
happy = json.load(open(sys.argv[2]))
combined = {"issues": fork["issues"] + happy["issues"], "comments": {**fork["comments"], **happy["comments"]}, "commits": {**fork.get("commits", {}), **happy.get("commits", {})}}
# #741: the registry history (baseline revision + its landing PR) must ride
# along, or the merged repo has no allowlist in effect and every run is
# indeterminate for the wrong reason.
for key in ("registry_commits", "registry_contents", "commit_pulls", "commit_check_suites"):
    merged = {}
    for db in (fork, happy):
        value = db.get(key)
        if isinstance(value, dict):
            merged.update(value)
    if key == "registry_commits":
        seen, rows = set(), []
        for db in (fork, happy):
            for row in db.get(key, []):
                if row["sha"] not in seen:
                    seen.add(row["sha"]); rows.append(row)
        combined[key] = rows
    else:
        combined[key] = merged
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
grep -qi "tamper" <<<"$out" || fail "tamper: expected a tamper-shaped reason, got: $out"

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

echo "== shepherd round 6: a JSON boolean in --trusted-actors-file is a usage error, never silently coerced to actor id 1 =="
for bad_value in 'true' '"9001"' 'null' '{}'; do
    echo "{\"trusted_actor_ids\":[$bad_value]}" >"$tmp/trusted-bad.json"
    set +e
    out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actors-file "$tmp/trusted-bad.json" --json 2>&1)"
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "trusted-actors-file (bad value $bad_value): expected a usage error, got rc=$rc: $out"
done

echo "== missing --trusted-actor-id/--trusted-actors-file is a usage error, never a silent open-trust default =="
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r 2>&1)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "missing trust config: expected exit 2, got $rc"
grep -qi "trusted-actor" <<<"$out" || fail "missing trust config: expected an explanatory error"

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
grep -qi "deleted-entry tampering\|no longer exists" <<<"$out" || fail "deleted-evidence: expected a deleted-entry-tampering reason, got: $out"

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
grep -qi "deleted-entry tampering\|no longer exists" <<<"$out" || fail "deleted-record: expected a deleted-entry-tampering reason, got: $out"

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
    grep -qi "requires a value" <<<"$out" || fail "missing-value ($flag_args --json): expected a 'requires a value' reason, got: $out"
done

echo "== a listed evidence entry naming a foreign run_id in its own marker is rejected, not silently merged =="
export DFSTATS_DB="$tmp/scenarios/foreign-evidence.json"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run run-foreign-evidence-1 --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "foreign-evidence: expected exit 3 (indeterminate), got $rc: $out"
grep -qi "does not bind to run\|tamper" <<<"$out" || fail "foreign-evidence: expected a binding-mismatch reason, got: $out"

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
grep -qi "evidence_registrations.*chain broken\|tamper" <<<"$out" || fail "edited-registration: expected an evidence_registrations chain-break reason, got: $out"

echo "== round 4 of #663: evidence_comments[] naming a different comment than its own (untouched, valid) chain fails closed =="
export DFSTATS_DB="$tmp/scenarios/swapped-comment-id.json"
run_id="$(meta swapped-comment-id .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "swapped-comment-id: expected exit 3 (indeterminate), got $rc: $out"
grep -qi "evidence_comments.*does not match\|out-of-band edit" <<<"$out" || fail "swapped-comment-id: expected an evidence_comments/evidence_registrations mismatch reason, got: $out"

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
grep -qi "not this run's own trusted author\|forged-author" <<<"$out" || fail "forged-author: expected a forged-author reason, got: $out"

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
grep -qi "identity mismatch\|declares run_id" <<<"$out" || fail "marker-payload-mismatch: expected an identity-mismatch reason, got: $out"

echo "== review round 3: a duplicate chain entry sharing seq/digest/prev_digest but different content is a fork, not a silently-discarded duplicate =="
export DFSTATS_DB="$tmp/scenarios/tampered-duplicate.json"
run_id="$(meta tampered-duplicate .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "tampered-duplicate: expected exit 3 (indeterminate), got $rc: $out"
grep -qi "different content\|forked chain" <<<"$out" || fail "tampered-duplicate: expected a forked-chain reason, got: $out"

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
grep -qi "not a registry-trusted actor as of this run's kickoff" <<<"$out" || fail "registry-revision-pin: expected a registry-narrowing reason, got: $out"

echo "== review round 4 (piece 2 of #663) / #741: a registry revision REMOVING the author that lands AFTER kickoff is not applied retroactively — the run stays authenticated under the baseline revision in effect at kickoff =="
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
grep -qi "initiated_by" <<<"$out" || fail "mutable-field-tamper (initiated_by): expected an initiated_by mismatch reason, got: $out"

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
grep -qi "forked chain" <<<"$out" || fail "digest-mismatch-duplicate: expected a forked-chain reason, got: $out"

echo "== shepherd round 1: an evidence marker edited from round=1 to round=1junk is rejected, not silently parsed as round:1 =="
export DFSTATS_DB="$tmp/scenarios/marker-round-tamper.json"
run_id="$(meta marker-round-tamper .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "marker-round-tamper: expected indeterminate, got rc=$rc: $out"
grep -qi "edited-entry tampering\|no longer matches" <<<"$out" || fail "marker-round-tamper: expected an edited-marker reason, got: $out"

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

echo "== harmon-devkit#1001 challenge round 6/7: --repo-root is honored on the --run (local-record) path too, not hardcoded to cwd (fixed round 7/7) =="
# The --run path has no --policy escape hatch (unlike --replay above) — it
# always resolves <repo-root>/.devflow.toml, so proving the flag is honored
# needs a genuine, valid policy file at an alternate root, not a fake script.
export DFSTATS_DB="$tmp/scenarios/arbitrary-evidence-run.json"
run_id="$(meta arbitrary-evidence-run .meta.runId)"
mkdir -p "$tmp/altroot-repo-root"
cp "$repo/.devflow.toml" "$tmp/altroot-repo-root/.devflow.toml"
# Invoked from a cwd with no .devflow.toml and no --repo-root at all: fails
# closed (indeterminate), rather than silently resolving the real repo's
# policy via a lucky cwd.
set +e
out="$(cd "$tmp" && node "$repo/scripts/dev-flow-stats.mjs" --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] && grep -Fq 'requires the exit engine' <<<"$out" && grep -Fq 'does not exist' <<<"$out" ||
    fail "repo-root (run path): expected a missing-policy indeterminate when invoked from a directory with no .devflow.toml and no --repo-root, got rc=$rc: $out"
# An explicit --repo-root naming a directory that DOES have .devflow.toml,
# invoked from that same unrelated cwd, must reproduce the real repo root's
# output exactly.
baseline_out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
altroot_out="$(cd "$tmp" && node "$repo/scripts/dev-flow-stats.mjs" --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --repo-root "$tmp/altroot-repo-root" --json)"
[ "$baseline_out" = "$altroot_out" ] ||
    fail "repo-root (run path): explicit --repo-root from another cwd did not reproduce the baseline output. baseline=$baseline_out altroot=$altroot_out"

echo "== harmon-devkit#1001 review round 2: a not-measured finding (its round could not be ancestry-retained) is never counted as verified (fixed round 3/5) =="
export DFSTATS_DB="$tmp/scenarios/not-measured-provenance.json"
run_id="$(meta not-measured-provenance .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '
  (.rounds[0].provenance_measurement == "unverified") and
  (.rounds[0].finding_attributions[0].provenance_status == "not-measured") and
  (.rounds[0].finding_attributions[0].fingerprint_status == "not-measured") and
  (.findings_by_class_and_provenance == {}) and
  (.findings_by_verified_fingerprint == {}) and
  ([.provenance_unavailable_rounds[] | select(.stage == "review" and .round == 1)] | length == 1)
' >/dev/null ||
    fail "not-measured provenance: a finding whose round could not be ancestry-retained was counted as verified: $out"

echo "== integration Codex cycle 1: a receipted blocked envelope for a round the engine never emits is still validated (fixed remediation 1/6) =="
export DFSTATS_DB="$tmp/scenarios/blocked-wrong-runid.json"
run_id="$(meta blocked-wrong-runid .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] && ! grep -Fq '"status": "ok"' <<<"$out" ||
    fail "blocked wrong run_id: a wrong-run_id blocked envelope for an engine-invisible round was not caught, rc=$rc: $out"

echo "== integration Codex cycle 1: --run from a repository subdirectory resolves the same .devflow.toml without --repo-root (fixed remediation 1/6) =="
# cwd must be an actual subdirectory OF THIS GIT CHECKOUT (not $tmp, which is
# outside any repository and would make `git rev-parse --show-toplevel`
# itself fail) for this to exercise the toplevel-resolution fix at all.
export DFSTATS_DB="$tmp/scenarios/subdirectory-repo-root.json"
run_id="$(meta subdirectory-repo-root .meta.runId)"
subdir_out="$(cd "$repo/scripts" && node "$repo/scripts/dev-flow-stats.mjs" --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
root_out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
[ "$subdir_out" = "$root_out" ] ||
    fail "subdirectory repo-root: --run from a subdirectory without --repo-root did not resolve the same policy as the root. subdir=$subdir_out root=$root_out"

echo "== integration Codex cycle 2: review round 1 survives a legitimate challenge re-entry instead of being discarded as stage-not-active (fixed remediation 2/6) =="
export DFSTATS_DB="$tmp/scenarios/review-then-challenge-reentry.json"
run_id="$(meta review-then-challenge-reentry .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.rounds == [{stage:"review",round:1,pass_count:1,blocked_passes:0,adjudication_count:1,finding_count:0,has_adjudication:true,provenance_measurement:"not-applicable"}]' >/dev/null ||
    fail "review-then-challenge-reentry: expected review round 1 to survive the later challenge re-entry: $out"

echo "== harmon-devkit#1001 review round 1: a run still in progress on challenge reports challenge's own trajectory, review not-started (fixed round 2/5) =="
export DFSTATS_DB="$tmp/scenarios/challenge-still-active.json"
run_id="$(meta challenge-still-active .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --record-dir "$tmp/local-records" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.rounds == [{stage:"challenge",round:1,pass_count:1,blocked_passes:0,adjudication_count:1,finding_count:0,has_adjudication:true,provenance_measurement:"not-applicable"}]' >/dev/null ||
    fail "challenge-still-active: expected only challenge round 1, review not yet started: $out"

echo "== shepherd round 1: a comment physically posted on the PR but whose marker claims dest=issue fails closed =="
export DFSTATS_DB="$tmp/scenarios/marker-dest-mismatch.json"
run_id="$(meta marker-dest-mismatch .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "marker-dest-mismatch: expected indeterminate, got rc=$rc: $out"
grep -qi "not actually fetched from\|edited-entry tampering" <<<"$out" || fail "marker-dest-mismatch: expected a destination-mismatch reason, got: $out"

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
grep -qi "not a registry-trusted actor as of this run's kickoff" <<<"$out" || fail "registry-nonmain-branch: expected a registry-narrowing reason, got: $out"

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
grep -qi "unrecognized option" <<<"$out" || fail "unrecognized flag: expected an unrecognized-option message, got: $out"

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
grep -qi "outcome_transitions has 2 entries\|one terminal outcome" <<<"$out" || fail "outcome-transitions-unbounded: expected an at-most-one-terminal-outcome reason, got: $out"

echo "== shepherd round 3: a destination=pr marker with a non-null round is rejected, not silently dropped from the trajectory =="
export DFSTATS_DB="$tmp/scenarios/pr-dest-with-round.json"
run_id="$(meta pr-dest-with-round .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "pr-dest-with-round: expected indeterminate, got rc=$rc: $out"
grep -qi "destination=pr with a non-null round" <<<"$out" || fail "pr-dest-with-round: expected a destination/round grammar reason, got: $out"

echo "== shepherd round 3: post_ready_fix_indeterminate_count is shown in the human-readable --repo output, not just JSON =="
export DFSTATS_DB="$tmp/scenarios/postfix-unresolvable.json"
json_out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$json_out" | jq -e '.post_ready_fix_indeterminate_count == 1' >/dev/null || fail "postfix-unresolvable: expected post_ready_fix_indeterminate_count 1 in JSON, got: $json_out"
table_out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001)"
grep -qi "post-ready human fixes indeterminate" <<<"$table_out" || fail "postfix-unresolvable: expected the human-readable form to show post-ready-fix uncertainty, got: $table_out"

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
grep -qi "not a configured trusted actor\|not a registry-trusted actor as of this run's kickoff" <<<"$out" || fail "registry-trust-record-before-index: expected an untrusted-author reason, got: $out"

echo "== shepherd round 3: an indeterminate run's --since cohort time is the RECORD's own created_at, not the later run-index post time (same fixture, isolates the catch-block fallback from the trust check above) =="
since_excluded="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --since 2026-09-01T00:15:00Z --json)"
echo "$since_excluded" | jq -e '.indeterminate_count == 0 and (.per_issue | length) == 0' >/dev/null || fail "registry-trust-record-before-index: expected --since 00:15 to exclude the issue entirely (record posted 00:10, before the cutoff), got: $since_excluded"
since_included="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --since 2026-09-01T00:05:00Z --json)"
echo "$since_included" | jq -e '.indeterminate_count == 1 and (.per_issue | length) == 1' >/dev/null || fail "registry-trust-record-before-index: expected --since 00:05 to include the issue as indeterminate (record posted 00:10, on/after the cutoff), got: $since_included"

echo "== shepherd round 4 / #741: a registry-touching commit with no merging PR (direct push) voids the WHOLE repo's registry history, and a void history is indeterminate (fail closed), never CLI-only trust =="
export DFSTATS_DB="$tmp/scenarios/registry-direct-push.json"
run_id="$(meta registry-direct-push .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "registry-direct-push: expected indeterminate (unresolvable registry history fails closed), got rc=$rc: $out"
grep -qi "revision history could not be resolved" <<<"$out" || fail "registry-direct-push: expected an unresolvable-history reason, got: $out"

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
grep -qi "no longer identifies it as this run's run-record" <<<"$out" || fail "record-marker-tamper: expected an edited-entry tampering reason, got: $out"

echo "== shepherd round 5: the run-index's OWN author trust is decided at the record's kickoff time, isolated from the record-author check via a genuinely different index author =="
export DFSTATS_DB="$tmp/scenarios/index-author-narrowed.json"
run_id="$(meta index-author-narrowed .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --trusted-actor-id 9002 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "index-author-narrowed: expected indeterminate (index author narrowed out at the record's kickoff time), got rc=$rc: $out"
grep -qi "author is not a registry-trusted actor as of this run's kickoff" <<<"$out" || fail "index-author-narrowed: expected the index-author-specific reason, got: $out"

echo "== shepherd round 5: a trusted run-index with a canonical marker but no fenced payload is indeterminate, not silently absent from the cohort =="
export DFSTATS_DB="$tmp/scenarios/index-no-fence.json"
run_id="$(meta index-no-fence .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "index-no-fence: expected indeterminate (malformed trusted index), got rc=$rc: $out"
grep -qi "canonical marker but no fenced payload" <<<"$out" || fail "index-no-fence: expected a malformed-payload reason, got: $out"
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
grep -qi "ready-for-review without a corresponding PR binding" <<<"$out" || fail "ready-no-pr-binding: expected a PR-binding-inconsistency reason, got: $out"
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

echo "== shepherd round 6: a malformed (no-fence) run-index with the LOWER comment id stays canonical over a later well-formed duplicate for the same run_id, using its own created_at as kickoffCreatedAt =="
export DFSTATS_DB="$tmp/scenarios/malformed-index-stays-canonical.json"
run_id="$(meta malformed-index-stays-canonical .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "malformed-index-stays-canonical: expected the malformed (lower-id) index to stay canonical (indeterminate), got rc=$rc: $out"
grep -qi "canonical marker but no fenced payload" <<<"$out" || fail "malformed-index-stays-canonical: expected the malformed-payload reason (not authenticating via the later well-formed duplicate), got: $out"
# kickoffCreatedAt must be the malformed index's OWN created_at
# (2026-08-20T00:01:00Z), not null and not the later duplicate's
# (2026-09-01) — proven via --since: a cutoff of 2026-08-21 (after the
# malformed index, before the later duplicate) must EXCLUDE this issue.
# A null kickoffCreatedAt bug would instead admit it unconditionally.
since_out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --since 2026-08-21T00:00:00Z --json)"
echo "$since_out" | jq -e '.indeterminate_count == 0 and (.per_issue | length) == 0' >/dev/null || fail "malformed-index-stays-canonical: expected --since 08-21 to exclude the issue (malformed index's own kickoff predates it), got: $since_out"

echo "== shepherd round 6: a correctly authenticated evidence comment whose reassembled payload is valid JSON but not an object (bare null) makes its run indeterminate, never crashes --run or --replay =="
export DFSTATS_DB="$tmp/scenarios/null-round-payload.json"
run_id="$(meta null-round-payload .meta.runId)"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "null-round-payload: expected indeterminate (not a crash), got rc=$rc: $out"
grep -qi "valid JSON but not an object" <<<"$out" || fail "null-round-payload: expected a malformed-round-payload reason, got: $out"
set +e
replay_out="$(node scripts/dev-flow-stats.mjs --repo o/r --replay --policy "$tmp/policy-matching.toml" --exit-script "$tmp/fake-exit-script.mjs" --trusted-actor-id 9001 --json 2>&1)"
replay_rc=$?
set -e
[ "$replay_rc" -eq 0 ] || fail "null-round-payload: expected --replay to complete without crashing, got rc=$replay_rc: $replay_out"

echo "== shepherd round 6: a confirmed post-ready fix and a separate unresolved commit on the same issue count only as fixed, never also indeterminate =="
export DFSTATS_DB="$tmp/scenarios/postfix-mixed.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.post_ready_fix_count == 1 and .post_ready_fix_indeterminate_count == 0' >/dev/null || fail "postfix-mixed: expected fixed=1, indeterminate=0 (a confirmed fix settles the issue), got: $out"

echo "== shepherd round 6: computePostReadyFix's own API failure isolates to one issue's indeterminate count, never aborts the --repo scan =="
export DFSTATS_DB="$tmp/scenarios/postfix-api-fail.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '.cohort_size == 2 and .post_ready_fix_indeterminate_count == 1 and .post_ready_fix_count == 0' >/dev/null || fail "postfix-api-fail: expected both issues reported (cohort_size 2), the failing one counted indeterminate, the sibling unaffected, got: $out"

echo "== shepherd round 6: a stage exit with trailing free-form prose ('continue, more rounds needed') is still parsed as its leading machine token, not null =="
export DFSTATS_DB="$tmp/scenarios/outcome-trailing-prose.json"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --replay --policy "$tmp/policy-matching.toml" --exit-script "$tmp/fake-exit-script.mjs" --trusted-actor-id 9001 --json)"
echo "$out" | jq -e '(.[0].diffs | length) == 0' >/dev/null || fail "outcome-trailing-prose: expected no diff (recorded 'continue,...' correctly parses as continue, matching the fake script's recomputed continue with 1 round under cap 4), got: $out"

# ---------------------------------------------------------------------------
# #741 fixture corpus (ai/schemas/fixtures/registry-trust): every case is a
# declarative timeline rendered by the builder above; the expected verdict
# lives in the fixture itself (expect.status / expect.reason_contains /
# expect.rounds), so adding a case is one directory, never a bash edit.
# ---------------------------------------------------------------------------
echo "== #741 shepherd round 1: a registry-unauthorized lower-id index never shadows the legitimate later one =="
export DFSTATS_DB="$tmp/scenarios/forged-index-shadow.json"
run_id="$(meta forged-index-shadow .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --trusted-actor-id 9002 --json 2>&1)" || fail "forged-index-shadow: expected the run to harvest via the legitimate index, got: $out"
echo "$out" | jq -e '.outcome == null' >/dev/null || fail "forged-index-shadow: expected a clean in-flight run, got: $out"

echo "== #741 shepherd round 2: an index edited after its author's removal never shadows a legitimate later index =="
export DFSTATS_DB="$tmp/scenarios/edited-index-shadow.json"
run_id="$(meta edited-index-shadow .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --trusted-actor-id 9002 --json 2>&1)" || fail "edited-index-shadow: expected the run to harvest via the legitimate index, got: $out"
echo "$out" | jq -e '.outcome == null' >/dev/null || fail "edited-index-shadow: expected a clean in-flight run, got: $out"

echo "== #741 shepherd round 3: a direct-push registry commit older than a PR-landed revision voids only the interval before that landing =="
export DFSTATS_DB="$tmp/scenarios/older-direct-push.json"
run_after="$(meta older-direct-push .meta.runIdAfter)"
run_before="$(meta older-direct-push .meta.runIdBefore)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_after" --trusted-actor-id 9001 --json 2>&1)" || fail "older-direct-push: run after the resolvable landing should authenticate, got: $out"
echo "$out" | jq -e '.outcome == null' >/dev/null || fail "older-direct-push: expected a clean in-flight run after the landing, got: $out"
set +e
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_before" --trusted-actor-id 9001 2>&1)"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "older-direct-push: run before the resolvable landing should be indeterminate, got rc=$rc: $out"
grep -qi "no agent-registry.json revision had landed" <<<"$out" || fail "older-direct-push: expected the no-revision reason, got: $out"

echo "== #741 shepherd round 4: a higher-id duplicate index with an unanswerable write time does not sink a run whose lower-id index is authenticated =="
export DFSTATS_DB="$tmp/scenarios/later-duplicate-unresolvable.json"
run_id="$(meta later-duplicate-unresolvable .meta.runId)"
out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" --trusted-actor-id 9001 --as-of 2099-06-01T00:00:00Z --json 2>&1)" || fail "later-duplicate-unresolvable: expected the run to harvest via its lower-id index, got: $out"
echo "$out" | jq -e '.outcome == null' >/dev/null || fail "later-duplicate-unresolvable: expected a clean in-flight run, got: $out"

echo "== #741: registry allowlist fixture corpus (fail closed on missing/empty/malformed; per-write revision binding) =="
corpus_count=0
for dir in "$repo"/ai/schemas/fixtures/registry-trust/*/; do
    name="$(basename "$dir")"
    [ -f "$dir/scenario.json" ] || fail "registry-trust/$name: no scenario.json"
    scenario="registry-trust-$name"
    export DFSTATS_DB="$tmp/scenarios/$scenario.json"
    run_id="$(meta "$scenario" .meta.runId)"
    expect_status="$(meta "$scenario" .meta.expect.status)"
    expect_reason="$(meta "$scenario" '.meta.expect.reason_contains // ""')"
    expect_rounds="$(meta "$scenario" '.meta.expect.rounds // ""')"
    trust_args=()
    while IFS= read -r id; do
        trust_args+=(--trusted-actor-id "$id")
    done < <(meta "$scenario" '.meta.trustedActorIds[]')
    case "$expect_status" in
    ok)
        set +e
        out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" "${trust_args[@]}" --json 2>&1)"
        rc=$?
        set -e
        [ "$rc" -eq 0 ] || fail "registry-trust/$name: expected the run to authenticate (rc 0), got rc=$rc: $out"
        if [ -n "$expect_rounds" ]; then
            echo "$out" | jq -e --argjson n "$expect_rounds" '.rounds | length == $n' >/dev/null ||
                fail "registry-trust/$name: expected $expect_rounds assembled round(s), got: $out"
        fi
        expect_orphans="$(meta "$scenario" '.meta.expect.orphan_count // ""')"
        expect_forged="$(meta "$scenario" '.meta.expect.forged_count // ""')"
        if [ -n "$expect_orphans" ]; then
            echo "$out" | jq -e --argjson n "$expect_orphans" '.orphan_comments | length == $n' >/dev/null ||
                fail "registry-trust/$name: expected $expect_orphans orphan comment(s), got: $out"
        fi
        if [ -n "$expect_forged" ]; then
            echo "$out" | jq -e --argjson n "$expect_forged" '.forged_comments | length == $n' >/dev/null ||
                fail "registry-trust/$name: expected $expect_forged forged comment(s), got: $out"
        fi
        ;;
    indeterminate)
        set +e
        out="$(node scripts/dev-flow-stats.mjs --repo o/r --run "$run_id" "${trust_args[@]}" 2>&1)"
        rc=$?
        set -e
        [ "$rc" -eq 3 ] || fail "registry-trust/$name: expected indeterminate (rc 3), got rc=$rc: $out"
        ;;
    *) fail "registry-trust/$name: unknown expect.status $expect_status" ;;
    esac
    if [ -n "$expect_reason" ]; then
        grep -qiF -- "$expect_reason" <<<"$out" || fail "registry-trust/$name: expected the reason to contain '$expect_reason', got: $out"
    fi
    echo "PASS: registry-trust/$name"
    corpus_count=$((corpus_count + 1))
done
[ "$corpus_count" -ge 18 ] || fail "registry-trust corpus: expected at least 18 cases, found $corpus_count"

echo "TEST PASS: dev-flow-stats harvesting/trust/metric/replay behavior"
