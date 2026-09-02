#!/usr/bin/env node
// scripts/dev-flow-stats.mjs — Dev flow v2 evidence harvesting, the closed-
// cohort unattended-success metric, per-run trajectory rendering, and
// convergence-policy replay (specs/dev-flow-v2.md § Evidence / § Success
// metric, openspec/changes/dev-flow-v2/specs/evidence/spec.md, issue #663).
//
// Evidence is read back from GitHub issue/PR comments via `gh api` (never
// written — posting is #638/#639's job). The marker/digest grammar this
// reads is documented in ai/schemas/README.md "Evidence marker and digest
// grammar" — read that first if this file is confusing on its own.
//
// Trust model: a comment counts as evidence only when its immutable GitHub
// actor id is the run record's own author (the run's root of trust for its
// own evidence) or a caller-configured --trusted-actor-id. Nothing inside a
// payload is ever trusted to name its own author — see "Trust" below and
// ai/schemas/README.md's "Trust: actor ID, never a payload claim".

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, mkdirSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

// ---------------------------------------------------------------------------
// gh api wrapper
// ---------------------------------------------------------------------------

class GhError extends Error {}

// Resolved via $PATH (never an absolute path) so a test's stub directory,
// prepended to PATH ahead of the real gh, transparently shadows it — the
// same shim pattern scripts/test-claim-transaction.sh already establishes.
function ghApiPaginated(endpoint) {
  const result = spawnSync("gh", ["api", "--paginate", "--slurp", endpoint], { encoding: "utf8" });
  if (result.error) throw new GhError(`gh api ${endpoint} failed to execute: ${result.error.message}`);
  if (result.status !== 0) throw new GhError(`gh api ${endpoint} exited ${result.status}: ${(result.stderr || "").trim()}`);
  let pages;
  try {
    pages = JSON.parse(result.stdout);
  } catch (err) {
    throw new GhError(`gh api ${endpoint} returned malformed JSON: ${err.message}`);
  }
  // --paginate --slurp yields one array per page; flatten.
  return pages.flat();
}

function ghApiOne(endpoint) {
  const result = spawnSync("gh", ["api", endpoint], { encoding: "utf8" });
  if (result.error) throw new GhError(`gh api ${endpoint} failed to execute: ${result.error.message}`);
  if (result.status !== 0) throw new GhError(`gh api ${endpoint} exited ${result.status}: ${(result.stderr || "").trim()}`);
  try {
    return JSON.parse(result.stdout);
  } catch (err) {
    throw new GhError(`gh api ${endpoint} returned malformed JSON: ${err.message}`);
  }
}

function fetchIssueList(repo) {
  // state=all: a closed (merged, capped, abandoned) issue's run still
  // belongs in the closed-cohort denominator — the metric explicitly
  // counts abandoned/capped runs as failures, not as absent.
  return ghApiPaginated(`repos/${repo}/issues?state=all&per_page=100`).filter((i) => !i.pull_request);
}

function fetchIssueComments(repo, issueNumber) {
  return ghApiPaginated(`repos/${repo}/issues/${issueNumber}/comments?per_page=100`);
}

function fetchPrComments(repo, prNumber) {
  return ghApiPaginated(`repos/${repo}/issues/${prNumber}/comments?per_page=100`);
}

// ---------------------------------------------------------------------------
// Marker grammar (ai/schemas/README.md "Evidence marker and digest grammar")
// ---------------------------------------------------------------------------

const RUN_STAGES = ["kickoff", "claim", "explore", "plan", "implement", "verify", "challenge", "review", "security", "integration"];

// <!-- devflow:<kind> v2 run_id=<id> stage=<stage> dest=<issue|pr> round=<n|-> seq=<n> -->
const MARKER_RE =
  /<!--\s*devflow:(run-record|evidence)\s+v2\s+run_id=(\S+)\s+stage=(\S+)\s+dest=(issue|pr)\s+round=(\S+)\s+seq=(\d+)\s*-->/;
const FENCE_RE = /```json\r?\n([\s\S]*?)\r?\n```/;

class EvidenceError extends Error {}

function parseMarker(body) {
  const m = MARKER_RE.exec(body);
  if (!m) return null;
  const [, kind, runId, stage, dest, roundRaw, seqRaw] = m;
  if (!RUN_STAGES.includes(stage)) return null;
  const round = roundRaw === "-" ? null : Number.parseInt(roundRaw, 10);
  if (roundRaw !== "-" && !Number.isInteger(round)) return null;
  const seq = Number.parseInt(seqRaw, 10);
  return { kind, runId, stage, dest, round, seq };
}

function fencedPayloadText(body) {
  const m = FENCE_RE.exec(body);
  return m ? m[1] : null;
}

function sha256(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

// Canonical digest of a parsed, already-trusted structured value — sorted
// keys, so it is reproducible across implementations (unlike the raw-text
// comment digest, which hashes exactly the bytes posted). See
// ai/schemas/README.md's distinction between the two digest kinds.
function canonicalDigest(value) {
  return sha256(canonicalJson(value));
}

function canonicalJson(value) {
  if (value === undefined) return undefined;
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map((v) => (v === undefined ? "null" : canonicalJson(v))).join(",")}]`;
  // Matches native JSON.stringify's own behavior for objects: a key whose
  // value is undefined is omitted entirely, not serialized as the literal
  // word "undefined" — required for optional content fields (e.g. a
  // stage_transitions entry's still-open `exit`) to hash identically
  // whether the key is explicitly absent or JS-undefined after a lookup.
  const keys = Object.keys(value)
    .filter((k) => value[k] !== undefined)
    .sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(",")}}`;
}

// ---------------------------------------------------------------------------
// Trust
// ---------------------------------------------------------------------------

// A comment's immutable actor id — never .login (renamable) and never
// anything the payload itself claims.
function commentActorId(comment) {
  return comment.user && typeof comment.user.id === "number" ? comment.user.id : null;
}

function isTrustedFor(comment, { trustedActorIds, runRecordAuthorId }) {
  const actorId = commentActorId(comment);
  if (actorId === null) return false;
  if (runRecordAuthorId !== null && actorId === runRecordAuthorId) return true;
  return trustedActorIds.has(actorId);
}

// ---------------------------------------------------------------------------
// Evidence comment collection: parse every comment, keep the ones with a
// recognizable marker, and classify trust — but do NOT resolve duplicates
// or trust the run-record's declared authority yet (the run record itself
// must be found and trusted first; every other comment's trust may depend
// on it).
// ---------------------------------------------------------------------------

function markedComments(comments) {
  const out = [];
  for (const c of comments) {
    const marker = parseMarker(c.body || "");
    if (!marker) continue;
    const payloadText = fencedPayloadText(c.body || "");
    if (payloadText === null) continue;
    out.push({ comment: c, marker, payloadText, actorId: commentActorId(c) });
  }
  return out;
}

// Among comments sharing an identical marker key (kind/run_id/stage/dest/
// round/seq), the lowest comment id is canonical; every other trusted
// comment with the same key is a superseded duplicate. Untrusted comments
// never participate in this resolution — they are reported separately and
// never suppress a legitimate write (ai/schemas/README.md "Duplicate
// markers").
function markerKey(m) {
  return `${m.kind}|${m.runId}|${m.stage}|${m.dest}|${m.round}|${m.seq}`;
}

function resolveCanonical(markedTrusted) {
  const byKey = new Map();
  for (const entry of markedTrusted) {
    const key = markerKey(entry.marker);
    const existing = byKey.get(key);
    if (!existing || entry.comment.id < existing.comment.id) byKey.set(key, entry);
  }
  return byKey;
}

// ---------------------------------------------------------------------------
// Run record discovery and authentication
// ---------------------------------------------------------------------------

// Finds and authenticates the run record among an issue's comments. Returns
// null if no run-record marker exists at all (issue was never kicked off).
// Throws EvidenceError for anything that IS a run-record marker but fails
// authentication or digest verification — never silently reinterprets
// tampered/forged evidence as "no run happened" (evidence spec: "reject
// deleted-entry tampering ... never reinterpret it as a run that did not
// happen").
function findRunRecord(issueComments, { trustedActorIds }) {
  const marked = markedComments(issueComments).filter((e) => e.marker.kind === "run-record");
  if (marked.length === 0) return null;

  // The run record's own trust has no run-record author to defer to yet —
  // it is authenticated ONLY against the externally configured trusted
  // actor list (never against itself, which would let anyone author a
  // record vouching for their own authority).
  const trusted = marked.filter((e) => trustedActorIds.has(e.actorId));
  const untrusted = marked.filter((e) => !trustedActorIds.has(e.actorId));

  if (trusted.length === 0) {
    if (untrusted.length > 0) {
      throw new EvidenceError(
        `run record marker present but authored by an untrusted actor id (${untrusted.map((e) => e.actorId).join(", ")}) — forged evidence, ignored`,
      );
    }
    return null;
  }

  // Multiple distinct run_ids with trusted run-record markers on one issue
  // is a different run each time (a retry) — group by run_id and resolve
  // canonical duplicates within each.
  const byRunId = new Map();
  for (const e of trusted) {
    const list = byRunId.get(e.marker.runId) || [];
    list.push(e);
    byRunId.set(e.marker.runId, list);
  }

  const records = [];
  for (const [runId, entries] of byRunId) {
    entries.sort((a, b) => a.comment.id - b.comment.id);
    const canonical = entries[0];
    let payload;
    try {
      payload = JSON.parse(canonical.payloadText);
    } catch (err) {
      throw new EvidenceError(`run record ${runId} (comment ${canonical.comment.id}) is not valid JSON: ${err.message}`);
    }
    records.push({
      runId,
      commentId: canonical.comment.id,
      authorActorId: canonical.actorId,
      authorLogin: canonical.comment.user.login,
      body: payload,
      rawText: canonical.payloadText,
    });
  }
  return records;
}

// The run record's own evidence_comments[] is the authoritative index of
// every evidence comment that should exist (evidence spec: "the issue-level
// index... SHALL anchor run discovery... SHALL reject deleted-entry
// tampering, never reinterpret it as a run that did not happen"). Cross-
// checked here against the actual comments fetched (issue + PR merged) —
// a listed entry with no matching comment id, or one whose current digest
// no longer matches, is deleted-entry or edited-entry tampering: the whole
// run is untrustworthy, not just the one missing round, for the same
// reason a broken append-only chain untrusts the record past the break.
function verifyEvidenceCommentsListed(runRecord, allComments) {
  const byId = new Map(allComments.map((c) => [c.id, c]));
  for (const entry of runRecord.evidence_comments || []) {
    const id = Number(entry.id);
    const comment = byId.get(id);
    if (!comment) {
      throw new EvidenceError(`evidence_comments[] names comment ${entry.id} (marker ${JSON.stringify(entry.marker)}), which no longer exists — deleted-entry tampering`);
    }
    const payloadText = fencedPayloadText(comment.body || "");
    if (payloadText === null || sha256(payloadText) !== entry.digest) {
      throw new EvidenceError(`evidence_comments[] entry for comment ${entry.id} no longer matches its recorded digest — edited-entry tampering`);
    }
    if (commentActorId(comment) !== entry.author_actor_id) {
      throw new EvidenceError(`evidence_comments[] entry for comment ${entry.id} names author ${entry.author_actor_id} but the comment's current author is ${commentActorId(comment)}`);
    }
  }
}

// ---------------------------------------------------------------------------
// Append-only entry chaining (ai/schemas/README.md "Append-only entry
// chaining") — draft extension pending #738, not yet enforced by
// run.schema.json itself. digest = canonicalDigest({...content, prev_digest}):
// binds each entry's own content AND its link to the previous entry, so
// tampering with an earlier entry is caught either at that entry itself
// (its digest no longer matches its content) or at the following entry
// (whose prev_digest no longer matches the retroactively-changed digest),
// from a single read of the current array — no comment edit history needed.
// ---------------------------------------------------------------------------

const GENESIS = "genesis";

function entryDigest(contentFields, prevDigest) {
  return canonicalDigest({ ...contentFields, prev_digest: prevDigest });
}

// contentKeys names the entry's semantic fields (excluding seq/digest/
// prev_digest themselves). Returns { ok: true, entries: [...sorted by seq] }
// or { ok: false, reason, brokenAtSeq }.
function verifyChain(rawEntries, contentKeys) {
  if (!Array.isArray(rawEntries)) return { ok: false, reason: "not an array", brokenAtSeq: null };
  const entries = [...rawEntries].sort((a, b) => (a.seq ?? -1) - (b.seq ?? -1));
  for (let i = 0; i < entries.length; i++) {
    if (entries[i].seq !== i) {
      return { ok: false, reason: `expected seq ${i}, got ${entries[i].seq}`, brokenAtSeq: i };
    }
  }
  let prevDigest = GENESIS;
  for (const entry of entries) {
    if (entry.prev_digest !== prevDigest) {
      return { ok: false, reason: `prev_digest at seq ${entry.seq} does not match the preceding entry's digest`, brokenAtSeq: entry.seq };
    }
    const content = {};
    for (const k of contentKeys) content[k] = entry[k];
    const expected = entryDigest(content, entry.prev_digest);
    if (entry.digest !== expected) {
      return { ok: false, reason: `digest at seq ${entry.seq} does not match its own content — tampered`, brokenAtSeq: entry.seq };
    }
    prevDigest = entry.digest;
  }
  return { ok: true, entries };
}

const CHAIN_FIELDS = {
  stage_transitions: ["stage", "entered_at", "exit"],
  interventions: ["kind", "at", "note"],
  settlements: ["finding_id", "disposition", "settled_at", "reference"],
};
const CHAIN_TIMESTAMP_FIELD = { stage_transitions: "entered_at", interventions: "at", settlements: "settled_at" };

// Validates all three append-only arrays in a run-record body. Throws
// EvidenceError on any broken chain — the record is not trusted past the
// break (evidence spec: "fail closed").
function verifyRunRecordChains(body) {
  const result = {};
  for (const [arrayName, contentKeys] of Object.entries(CHAIN_FIELDS)) {
    const outcome = verifyChain(body[arrayName] || [], contentKeys);
    if (!outcome.ok) {
      throw new EvidenceError(`run record ${arrayName} chain broken: ${outcome.reason}`);
    }
    result[arrayName] = outcome.entries;
  }
  return result;
}

// `--as-of` reconstruction: validate the COMPLETE chain first (a break
// after the cutoff still means nothing before it can be trusted, since the
// break could be a rewrite of earlier history too — ai/schemas/README.md),
// then keep only entries at or before the cutoff.
function reconstructAsOf(body, cutoffIso) {
  const chains = verifyRunRecordChains(body);
  const cutoff = cutoffIso ? Date.parse(cutoffIso) : Infinity;
  const filtered = {};
  for (const [arrayName, entries] of Object.entries(chains)) {
    const field = CHAIN_TIMESTAMP_FIELD[arrayName];
    filtered[arrayName] = entries.filter((e) => Date.parse(e[field]) <= cutoff);
  }
  // outcome/pr/promotion are point-in-time fields on the run record, not
  // append-only arrays — reconstructing them "as of" a cutoff means
  // deriving from the filtered chains rather than trusting the record's
  // current (possibly later-than-cutoff) top-level values directly.
  const lastTransition = filtered.stage_transitions[filtered.stage_transitions.length - 1];
  const promotion =
    body.promotion && Date.parse(body.promotion.promoted_at) <= cutoff ? body.promotion : null;
  // outcome is terminal-only in the live record; "as of" a cutoff before
  // the recorded outcome's own effective time, the run reads as still
  // in-flight (null) rather than inheriting a future terminal state.
  // The record does not carry an explicit outcome timestamp — the last
  // stage transition's exit (if any) or the promotion entry are the
  // closest available signals, so a run is reconstructed as terminal
  // "as of" cutoff only when the evidence available by then already
  // shows it ending (a promotion, or a last transition carrying `exit`
  // with no further transition after it).
  let outcome = null;
  if (promotion) outcome = "ready-for-review";
  else if (lastTransition && lastTransition.exit && filtered.stage_transitions.length === chains.stage_transitions.length) {
    // Only trust the live outcome field when every transition (including
    // any that exist strictly after this reconstruction's own filtered
    // set) is also within the cutoff — otherwise a later transition might
    // be the one that actually produced the recorded terminal outcome.
    outcome = body.outcome;
  }
  return {
    run_id: body.run_id,
    initiated_by: body.initiated_by,
    started_at: body.started_at,
    stage_transitions: filtered.stage_transitions,
    interventions: filtered.interventions,
    settlements: filtered.settlements,
    pr: body.pr,
    promotion,
    outcome,
  };
}

// ---------------------------------------------------------------------------
// Round evidence: segment reassembly, then the reassembled payload is
// {passes: [envelope...], adjudication: {...}} — one comment (or split
// sequence) per stage/round, posted to the issue (ai/schemas/README.md
// "Comment kinds"). Stage rollups on the PR are not consulted for replay:
// the issue's per-round comments are the spec's own source of truth
// ("each round's evidence is posted to the issue" unconditionally).
// ---------------------------------------------------------------------------

function collectEvidenceEntries(comments, { runId, trustedActorIds, runRecordAuthorId }) {
  const marked = markedComments(comments).filter((e) => e.marker.kind === "evidence" && e.marker.runId === runId);
  const trusted = marked.filter((e) => isTrustedFor(e.comment, { trustedActorIds, runRecordAuthorId }));
  const untrusted = marked.filter((e) => !isTrustedFor(e.comment, { trustedActorIds, runRecordAuthorId }));
  const canonical = resolveCanonical(trusted);
  return { canonical, untrusted };
}

// Groups canonical evidence entries by (stage, dest, round), reassembles
// each group's segments in seq order (requiring 1..N with no gap), and
// parses the concatenated text once.
function reassembleRoundEvidence(canonicalMap) {
  const groups = new Map();
  for (const entry of canonicalMap.values()) {
    const key = `${entry.marker.stage} ${entry.marker.dest} ${entry.marker.round}`;
    const list = groups.get(key) || [];
    list.push(entry);
    groups.set(key, list);
  }
  const rounds = [];
  const errors = [];
  for (const [key, entries] of groups) {
    entries.sort((a, b) => a.marker.seq - b.marker.seq);
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].marker.seq !== i + 1) {
        errors.push({ key, reason: `segment sequence has a gap or does not start at 1 (present: ${entries.map((e) => e.marker.seq).join(",")})` });
        continue;
      }
    }
    if (errors.some((e) => e.key === key)) continue;
    const text = entries.map((e) => e.payloadText).join("");
    let payload;
    try {
      payload = JSON.parse(text);
    } catch (err) {
      errors.push({ key, reason: `reassembled segments are not valid JSON: ${err.message}` });
      continue;
    }
    const { stage, dest, round } = entries[0].marker;
    rounds.push({ stage, dest, round, payload, commentIds: entries.map((e) => e.comment.id) });
  }
  return { rounds, errors };
}

// ---------------------------------------------------------------------------
// Run directory reconstruction — the shape scripts/dev-flow-exit.mjs's
// loadRunDir() reads (run.json + passes/*.json + adjudications/*.json).
// receipts[] and slot_failures[] are DERIVED here from harvested evidence,
// entirely as an implementation detail of this harvester: dev-flow-exit.mjs
// already expects them (evanharmon1/harmon-devkit#727 tracks giving them a
// canonical durable schema of their own; this reconstruction does not wait
// on that). Chronology comes directly from ascending comment id order,
// which IS creation order on GitHub.
// ---------------------------------------------------------------------------

function buildRunDirectory(runRecord, roundEvidence, destDir) {
  const passesDir = path.join(destDir, "passes");
  const adjDir = path.join(destDir, "adjudications");
  mkdirSync(passesDir, { recursive: true });
  mkdirSync(adjDir, { recursive: true });

  // Chronological order across every issue-side round comment, by comment
  // id (ascending == creation order on GitHub).
  const issueRounds = roundEvidence.filter((r) => r.dest === "issue" && r.round !== null);
  issueRounds.sort((a, b) => Math.min(...a.commentIds) - Math.min(...b.commentIds));

  const receipts = [];
  let currentStage = null;
  let passIndex = 0;
  for (const round of issueRounds) {
    if (round.stage !== currentStage) {
      receipts.push({ kind: "transition", stage: round.stage });
      currentStage = round.stage;
    }
    const passes = Array.isArray(round.payload.passes) ? round.payload.passes : [];
    for (const envelope of passes) {
      const name = `${round.stage}-r${round.round}-${passIndex++}`;
      writeFileSync(path.join(passesDir, `${name}.json`), JSON.stringify(envelope, null, 2));
      receipts.push({ kind: "pass", stage: round.stage, file: name });
    }
    if (round.payload.adjudication) {
      writeFileSync(
        path.join(adjDir, `${round.stage}-r${round.round}.json`),
        JSON.stringify(round.payload.adjudication, null, 2),
      );
    }
  }

  const runJson = {
    run_id: runRecord.run_id,
    initiated_by: runRecord.initiated_by,
    receipts,
    slot_failures: [],
  };
  writeFileSync(path.join(destDir, "run.json"), JSON.stringify(runJson, null, 2));
  return destDir;
}

// ---------------------------------------------------------------------------
// Harvest one run in full: run record, --as-of state, and every retained
// round's evidence, cutoff-filtered by comment creation time so that a
// comment posted after the cutoff (a concurrent writer racing the
// reconstruction) never affects it — the same stability the marker/digest
// grammar's lowest-id rule gives duplicate resolution.
// ---------------------------------------------------------------------------

// A broken chain (evidence-spec "reject deleted-entry tampering, never
// reinterpret it as a run that did not happen") or a forged-author run
// record disqualifies only THAT one run — never the whole harvest. Every
// return here carries `status: "ok" | "indeterminate"`; a caller iterating
// many issues keeps going past an indeterminate one rather than aborting.
function harvestOneRunRecord(repo, issueNumber, record, { trustedActorIds, asOf, issueComments, withinCutoff }) {
  try {
    const state = reconstructAsOf(record.body, asOf);
    // evidence_comments[] is checked against every comment that exists NOW
    // (unfiltered by --as-of) — a listed entry either genuinely exists or
    // it was deleted; whether it also happens to predate a requested
    // cutoff is a SEPARATE question, decided below by the same withinCutoff
    // filter every other round-discovery input already goes through. Using
    // the cutoff-filtered set here would misreport a comment that is only
    // temporally out of scope as tampering.
    const allPrComments = state.pr ? fetchPrComments(repo, state.pr.number) : [];
    verifyEvidenceCommentsListed(record.body, [...issueComments, ...allPrComments]);

    const { canonical: issueCanonical, untrusted: issueUntrusted } = collectEvidenceEntries(
      issueComments.filter(withinCutoff),
      { runId: record.runId, trustedActorIds, runRecordAuthorId: record.authorActorId },
    );
    const { canonical: prCanonical, untrusted: prUntrusted } = collectEvidenceEntries(
      allPrComments.filter(withinCutoff),
      { runId: record.runId, trustedActorIds, runRecordAuthorId: record.authorActorId },
    );
    const merged = new Map([...issueCanonical, ...prCanonical]);
    const { rounds, errors } = reassembleRoundEvidence(merged);
    return {
      status: "ok",
      runId: record.runId,
      issueNumber,
      record,
      state,
      rounds,
      errors,
      untrusted: [...issueUntrusted, ...prUntrusted],
    };
  } catch (err) {
    if (err instanceof EvidenceError) {
      return { status: "indeterminate", runId: record.runId, issueNumber, reason: err.message };
    }
    throw err;
  }
}

function harvestRunsForIssue(repo, issueNumber, { trustedActorIds, asOf }) {
  const issueComments = fetchIssueComments(repo, issueNumber);
  let records;
  try {
    records = findRunRecord(issueComments, { trustedActorIds });
  } catch (err) {
    if (err instanceof EvidenceError) {
      return [{ status: "indeterminate", runId: null, issueNumber, reason: err.message }];
    }
    throw err;
  }
  if (!records) return [];

  const cutoffEpoch = asOf ? Date.parse(asOf) : Infinity;
  const withinCutoff = (comment) => Date.parse(comment.created_at) <= cutoffEpoch;

  return records.map((record) =>
    harvestOneRunRecord(repo, issueNumber, record, { trustedActorIds, asOf, issueComments, withinCutoff }),
  );
}

function discoverAllRuns(repo, { trustedActorIds, asOf }) {
  const issues = fetchIssueList(repo);
  const runs = [];
  for (const issue of issues) {
    for (const run of harvestRunsForIssue(repo, issue.number, { trustedActorIds, asOf })) {
      runs.push(run);
    }
  }
  return runs;
}

// ---------------------------------------------------------------------------
// Closed-cohort unattended-success metric (specs/dev-flow-v2.md § Success
// metric). "Reached ready-for-review" requires the run record's own
// promotion entry, never a PR's isDraft==false alone (AGENTS.md's
// unexplained-promotion signature is exactly this gap: a flip with no
// promotion entry is never counted as success).
// ---------------------------------------------------------------------------

function isStale(state, staleAfterDays, asOfEpoch) {
  if (state.outcome !== null) return false; // already terminal
  const allEntries = [...state.stage_transitions, ...state.interventions, ...state.settlements];
  const lastActivity = allEntries.reduce((max, e) => {
    const t = Date.parse(e.entered_at || e.at || e.settled_at);
    return t > max ? t : max;
  }, Date.parse(state.started_at));
  return asOfEpoch - lastActivity > staleAfterDays * 24 * 60 * 60 * 1000;
}

function runInterventionCount(state) {
  return state.interventions.filter((i) => i.kind === "other").length;
}

function runAskedCount(state) {
  return state.interventions.filter((i) => i.kind === "asked").length;
}

// One issue's cohort verdict: "unattended success" only if the run that
// reached ready-for-review has zero interventions AND every earlier run on
// the same issue also had zero interventions (a human re-kick is itself an
// intervention on the issue's overall trajectory, per spec).
function computeIssueVerdict(issueRuns, { staleAfterDays, asOfEpoch }) {
  // A run whose own chain is broken or forged (status: "indeterminate")
  // makes the WHOLE issue's membership indeterminate too — never silently
  // dropped from the denominator (that would read as "no run happened")
  // and never counted as a plain failure either (that would assert
  // something about a trajectory this harvester could not actually
  // verify). Reported as its own category by the caller.
  const indeterminate = issueRuns.filter((r) => r.status === "indeterminate");
  if (indeterminate.length > 0) {
    return { closed: false, indeterminate: true, reasons: indeterminate.map((r) => r.reason) };
  }
  const terminalized = issueRuns.map((run) => {
    let state = run.state;
    if (state.outcome === null && isStale(state, staleAfterDays, asOfEpoch)) {
      state = { ...state, outcome: "abandoned" };
    }
    return { ...run, state };
  });
  // Not yet terminal (and not stale enough to terminalize) — excluded from
  // a CLOSED cohort; the caller filters these out of the denominator.
  if (terminalized.some((r) => r.state.outcome === null)) {
    return { closed: false };
  }
  const totalInterventions = terminalized.reduce((n, r) => n + runInterventionCount(r.state), 0);
  const totalAsked = terminalized.reduce((n, r) => n + runAskedCount(r.state), 0);
  const readyRun = terminalized.find((r) => r.state.outcome === "ready-for-review");
  const success = Boolean(readyRun) && totalInterventions === 0;
  return { closed: true, success, interventions: totalInterventions, asked: totalAsked, runs: terminalized };
}

function computePostReadyFix(repo, readyRun) {
  const promotion = readyRun.state.promotion;
  if (!promotion) return false;
  const commits = ghApiPaginated(`repos/${repo}/pulls/${readyRun.state.pr.number}/commits?per_page=100`);
  const afterPromotion = commits.filter((c) => Date.parse(c.commit.committer.date) > Date.parse(promotion.promoted_at));
  // A commit whose author differs from the run's own trusted authorship is
  // a human fix landing after the gate passed — the readiness gate's own
  // job was to make this unnecessary, so its presence is a second, distinct
  // failure measure (specs/dev-flow-v2.md § Evidence: "derived at read
  // time"), never folded into the primary rate.
  return afterPromotion.length > 0;
}

function computeClosedCohortMetric(repo, runsByIssue, { staleAfterDays, asOf }) {
  const asOfEpoch = asOf ? Date.parse(asOf) : Date.now();
  let closedCount = 0;
  let successCount = 0;
  let askedTotal = 0;
  let postReadyFixCount = 0;
  let indeterminateCount = 0;
  const perIssue = [];
  for (const [issueNumber, issueRuns] of runsByIssue) {
    const verdict = computeIssueVerdict(issueRuns, { staleAfterDays, asOfEpoch });
    if (verdict.indeterminate) {
      indeterminateCount++;
      perIssue.push({ issueNumber, closed: false, indeterminate: true, reasons: verdict.reasons });
      continue;
    }
    if (!verdict.closed) {
      perIssue.push({ issueNumber, closed: false });
      continue;
    }
    closedCount++;
    askedTotal += verdict.asked;
    if (verdict.success) {
      successCount++;
      const readyRun = verdict.runs.find((r) => r.state.outcome === "ready-for-review");
      if (computePostReadyFix(repo, readyRun)) postReadyFixCount++;
    }
    perIssue.push({ issueNumber, closed: true, success: verdict.success, interventions: verdict.interventions, asked: verdict.asked });
  }
  return {
    cohort_size: closedCount,
    unattended_success_count: successCount,
    unattended_success_rate: closedCount > 0 ? successCount / closedCount : null,
    asked_count: askedTotal,
    post_ready_fix_count: postReadyFixCount,
    indeterminate_count: indeterminateCount,
    per_issue: perIssue,
  };
}

// ---------------------------------------------------------------------------
// Per-run trajectory rendering
// ---------------------------------------------------------------------------

function findingCountsByClassAndProvenance(rounds) {
  const counts = {};
  for (const round of rounds) {
    const passes = Array.isArray(round.payload.passes) ? round.payload.passes : [];
    for (const pass of passes) {
      const findings = (pass.payload && pass.payload.findings) || [];
      for (const f of findings) {
        const cls = f.class || "unclassified";
        const prov = f.provenance || "unspecified";
        const key = `${cls}/${prov}`;
        counts[key] = (counts[key] || 0) + 1;
      }
    }
  }
  return counts;
}

function renderTrajectory(run) {
  const rounds = run.rounds
    .filter((r) => r.dest === "issue" && r.round !== null)
    .sort((a, b) => a.stage.localeCompare(b.stage) || a.round - b.round);
  return {
    run_id: run.runId,
    issue: run.issueNumber,
    initiated_by: run.state.initiated_by,
    started_at: run.state.started_at,
    outcome: run.state.outcome,
    pr: run.state.pr,
    promotion: run.state.promotion,
    stage_transitions: run.state.stage_transitions,
    interventions: run.state.interventions,
    settlements: run.state.settlements,
    rounds: rounds.map((r) => ({
      stage: r.stage,
      round: r.round,
      pass_count: Array.isArray(r.payload.passes) ? r.payload.passes.length : 0,
      finding_count: Array.isArray(r.payload.passes)
        ? r.payload.passes.reduce((n, p) => n + ((p.payload && p.payload.findings && p.payload.findings.length) || 0), 0)
        : 0,
      has_adjudication: Boolean(r.payload.adjudication),
    })),
    findings_by_class_and_provenance: findingCountsByClassAndProvenance(rounds),
    evidence_errors: run.errors,
    untrusted_comments: run.untrusted.map((u) => ({ id: u.comment.id, actor_id: u.actorId })),
  };
}

function renderTrajectoryTable(trajectory) {
  const lines = [];
  lines.push(`run ${trajectory.run_id} (issue #${trajectory.issue}) — outcome: ${trajectory.outcome ?? "in-flight"}`);
  lines.push(`initiated_by=${trajectory.initiated_by} started_at=${trajectory.started_at}`);
  if (trajectory.pr) lines.push(`pr: #${trajectory.pr.number}`);
  lines.push("");
  lines.push("stage_transitions:");
  for (const t of trajectory.stage_transitions) lines.push(`  ${t.entered_at}  ${t.stage}${t.exit ? ` -> ${t.exit}` : ""}`);
  lines.push("");
  lines.push("rounds:");
  for (const r of trajectory.rounds) {
    lines.push(`  ${r.stage} r${r.round}: ${r.pass_count} pass(es), ${r.finding_count} finding(s), adjudication=${r.has_adjudication}`);
  }
  if (Object.keys(trajectory.findings_by_class_and_provenance).length > 0) {
    lines.push("");
    lines.push("findings by class/provenance:");
    for (const [k, v] of Object.entries(trajectory.findings_by_class_and_provenance)) lines.push(`  ${k}: ${v}`);
  }
  if (trajectory.interventions.length > 0) {
    lines.push("");
    lines.push("interventions:");
    for (const i of trajectory.interventions) lines.push(`  ${i.at}  ${i.kind}: ${i.note}`);
  }
  if (trajectory.evidence_errors.length > 0) {
    lines.push("");
    lines.push("evidence errors:");
    for (const e of trajectory.evidence_errors) lines.push(`  ${e.key}: ${e.reason}`);
  }
  return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Replay: recompute every retained trajectory's exits under a candidate
// policy via dev-flow-exit.mjs (or --exit-script, for test injection —
// #663 branches from main before #636/dev-flow-exit.mjs has merged there;
// production always uses the sibling script at its stable relative path).
// ---------------------------------------------------------------------------

const DEFAULT_EXIT_SCRIPT = path.join(path.dirname(fileURLToPath(import.meta.url)), "dev-flow-exit.mjs");

function invokeExitScript(exitScriptPath, { runDir, stage, policyPath, currentHead }) {
  const result = spawnSync(
    process.execPath,
    [exitScriptPath, "--run", runDir, "--stage", stage, "--policy", policyPath, "--current-head", currentHead, "--json"],
    { encoding: "utf8" },
  );
  if (result.error) {
    return { error: `could not exec exit script: ${result.error.message}` };
  }
  try {
    return { verdict: JSON.parse(result.stdout) };
  } catch {
    return { error: (result.stderr || result.stdout || `exit script exited ${result.status} with no parseable output`).trim() };
  }
}

// Recorded exit for a stage is read off the run's own stage_transitions
// exit text (the last transition INTO this stage names its exit reason) —
// the human-readable record of what actually happened, independent of
// replay recomputing it fresh. run.schema.json's own exit examples
// ("converged", "capped: 1 adjudicated P1 remaining") show this is
// free-text, not the exit script's own outcome enum
// (continue|converged|diverging|capped) — recordedOutcome extracts just
// the leading enum word a human writer is expected to have started with,
// so the diff below compares like with like instead of two representations
// of the same fact that can never be string-equal.
function recordedExitFor(state, stage) {
  const transitions = state.stage_transitions.filter((t) => t.stage === stage);
  const last = transitions[transitions.length - 1];
  return last ? last.exit ?? null : null;
}

const OUTCOME_ENUM = ["continue", "converged", "diverging", "capped"];
function recordedOutcome(exitText) {
  if (!exitText) return null;
  const word = exitText.split(/[\s:]/, 1)[0];
  return OUTCOME_ENUM.includes(word) ? word : null;
}

function replayOneRun(run, { policyPath, exitScriptPath, tmpRoot }) {
  const runDir = path.join(tmpRoot, run.runId);
  buildRunDirectory(run.record.body, run.rounds, runDir);
  const currentHead = run.state.promotion ? run.state.promotion.head : "0".repeat(40);
  const diffs = [];
  for (const stage of ["challenge", "review"]) {
    const hasRounds = run.rounds.some((r) => r.stage === stage && r.dest === "issue" && r.round !== null);
    if (!hasRounds) continue;
    const { verdict, error } = invokeExitScript(exitScriptPath, { runDir, stage, policyPath, currentHead });
    const recordedText = recordedExitFor(run.state, stage);
    const recorded = recordedOutcome(recordedText);
    if (error) {
      diffs.push({ stage, recorded: recordedText, recomputed: null, error });
      continue;
    }
    if (verdict.outcome !== recorded) {
      diffs.push({ stage, recorded: recordedText, recomputed: verdict.outcome, reason: verdict.reason });
    }
  }
  return { runId: run.runId, issue: run.issueNumber, diffs };
}

function replayAll(runs, { policyPath, exitScriptPath }) {
  const tmpRoot = mkdtempSync(path.join(tmpdir(), "dev-flow-stats-replay-"));
  try {
    return runs.map((run) => {
      if (run.status === "indeterminate") {
        return { runId: run.runId, issue: run.issueNumber, diffs: [], indeterminate: true, reason: run.reason };
      }
      return replayOneRun(run, { policyPath, exitScriptPath: exitScriptPath || DEFAULT_EXIT_SCRIPT, tmpRoot });
    });
  } finally {
    rmSync(tmpRoot, { recursive: true, force: true });
  }
}

export {
  harvestRunsForIssue,
  discoverAllRuns,
  computeClosedCohortMetric,
  computeIssueVerdict,
  isStale,
  renderTrajectory,
  renderTrajectoryTable,
  replayAll,
  replayOneRun,
  DEFAULT_EXIT_SCRIPT,
  entryDigest,
  verifyChain,
  verifyRunRecordChains,
  reconstructAsOf,
  collectEvidenceEntries,
  reassembleRoundEvidence,
  buildRunDirectory,
  CHAIN_FIELDS,
  GENESIS,
  ghApiPaginated,
  ghApiOne,
  fetchIssueList,
  fetchIssueComments,
  fetchPrComments,
  GhError,
  parseMarker,
  fencedPayloadText,
  sha256,
  canonicalDigest,
  canonicalJson,
  commentActorId,
  isTrustedFor,
  markedComments,
  markerKey,
  resolveCanonical,
  findRunRecord,
  verifyEvidenceCommentsListed,
  EvidenceError,
  RUN_STAGES,
};

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = { "trusted-actor-id": [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    const takesValue = next !== undefined && !next.startsWith("--");
    if (key === "trusted-actor-id") {
      if (!takesValue) {
        console.error("dev-flow-stats: --trusted-actor-id requires a value");
        return null;
      }
      args["trusted-actor-id"].push(next);
      i++;
      continue;
    }
    if (takesValue) {
      args[key] = next;
      i++;
    } else {
      args[key] = true;
    }
  }
  return args;
}

// The configured trust root (ai/schemas/README.md "Trust: actor ID, never
// a payload claim") — the ONLY source of authority. --trusted-actor-id is
// direct/repeatable; --trusted-actors-file names a JSON
// {"trusted_actor_ids": [...]} document (a registry-style config file, for
// a caller that keeps this list alongside other deployment config rather
// than passing it flag-by-flag). Both are unioned; at least one id from
// either source is required.
function requireTrustedActorIds(args) {
  const fromFlags = (args["trusted-actor-id"] || []).map(Number);
  let fromFile = [];
  if (args["trusted-actors-file"]) {
    let doc;
    try {
      doc = JSON.parse(readFileSync(args["trusted-actors-file"], "utf8"));
    } catch (err) {
      console.error(`dev-flow-stats: could not read/parse --trusted-actors-file: ${err.message}`);
      return null;
    }
    if (!Array.isArray(doc.trusted_actor_ids)) {
      console.error('dev-flow-stats: --trusted-actors-file must contain {"trusted_actor_ids": [...]}');
      return null;
    }
    fromFile = doc.trusted_actor_ids.map(Number);
  }
  const all = [...fromFlags, ...fromFile];
  if (all.length === 0) {
    console.error(
      "dev-flow-stats: at least one --trusted-actor-id or --trusted-actors-file entry is required — evidence authored by anyone else is never trusted (ai/schemas/README.md \"Trust: actor ID, never a payload claim\")",
    );
    return null;
  }
  if (all.some((n) => !Number.isInteger(n) || n < 1)) {
    console.error("dev-flow-stats: every trusted actor id must be a positive integer");
    return null;
  }
  return new Set(all);
}

function groupRunsByIssue(runs) {
  const byIssue = new Map();
  for (const run of runs) {
    const list = byIssue.get(run.issueNumber) || [];
    list.push(run);
    byIssue.set(run.issueNumber, list);
  }
  return byIssue;
}

const DEFAULT_STALE_AFTER_DAYS = 7;

function cliMetrics(args) {
  const trustedActorIds = requireTrustedActorIds(args);
  if (!trustedActorIds) return 2;
  const asOf = typeof args["as-of"] === "string" ? args["as-of"] : null;
  const staleAfterDays = args["stale-after-days"] ? Number(args["stale-after-days"]) : DEFAULT_STALE_AFTER_DAYS;

  let runs;
  try {
    runs = discoverAllRuns(args.repo, { trustedActorIds, asOf });
  } catch (err) {
    console.error(`dev-flow-stats: ${err.message}`);
    return err instanceof EvidenceError ? 3 : 2;
  }
  const metric = computeClosedCohortMetric(args.repo, groupRunsByIssue(runs), { staleAfterDays, asOf });

  if (args.json) {
    console.log(JSON.stringify(metric, null, 2));
  } else {
    const pct = metric.unattended_success_rate === null ? "n/a" : `${(metric.unattended_success_rate * 100).toFixed(1)}%`;
    console.log(`unattended-success: ${metric.unattended_success_count}/${metric.cohort_size} (${pct})`);
    console.log(`asked: ${metric.asked_count}`);
    console.log(`post-ready human fixes: ${metric.post_ready_fix_count}`);
    if (metric.indeterminate_count > 0) console.log(`indeterminate (broken/forged evidence, excluded above): ${metric.indeterminate_count}`);
    console.log("");
    console.log("issue  closed  success  interventions  asked");
    for (const row of metric.per_issue) {
      if (row.indeterminate) {
        console.log(`#${row.issueNumber}  INDETERMINATE — ${row.reasons.join("; ")}`);
        continue;
      }
      if (!row.closed) {
        console.log(`#${row.issueNumber}  no (not yet terminal / not stale)`);
        continue;
      }
      console.log(`#${row.issueNumber}  yes  ${row.success}  ${row.interventions}  ${row.asked}`);
    }
  }
  return 0;
}

function cliRun(args) {
  const trustedActorIds = requireTrustedActorIds(args);
  if (!trustedActorIds) return 2;
  const asOf = typeof args["as-of"] === "string" ? args["as-of"] : null;

  let runs;
  try {
    runs = discoverAllRuns(args.repo, { trustedActorIds, asOf });
  } catch (err) {
    console.error(`dev-flow-stats: ${err.message}`);
    return err instanceof EvidenceError ? 3 : 2;
  }
  const run = runs.find((r) => r.runId === args.run);
  if (!run) {
    console.error(`dev-flow-stats: run "${args.run}" not found (searched every issue's run record in ${args.repo})`);
    return 1;
  }
  if (run.status === "indeterminate") {
    console.error(`dev-flow-stats: indeterminate: run "${args.run}" — ${run.reason}`);
    return 3;
  }
  const trajectory = renderTrajectory(run);
  console.log(args.json ? JSON.stringify(trajectory, null, 2) : renderTrajectoryTable(trajectory));
  return 0;
}

function cliReplay(args) {
  const trustedActorIds = requireTrustedActorIds(args);
  if (!trustedActorIds) return 2;
  const policyPath = args.policy || args.config;
  if (!policyPath) {
    console.error("dev-flow-stats: --replay requires --policy <file> (--config is accepted as an alias)");
    return 2;
  }
  if (!existsSync(policyPath)) {
    console.error(`dev-flow-stats: --policy path does not exist: ${policyPath}`);
    return 2;
  }
  const exitScriptPath = args["exit-script"] || DEFAULT_EXIT_SCRIPT;
  if (!existsSync(exitScriptPath)) {
    console.error(`dev-flow-stats: exit script does not exist: ${exitScriptPath}`);
    return 2;
  }

  let runs;
  try {
    runs = discoverAllRuns(args.repo, { trustedActorIds, asOf: null });
  } catch (err) {
    console.error(`dev-flow-stats: ${err.message}`);
    return err instanceof EvidenceError ? 3 : 2;
  }
  const results = replayAll(runs, { policyPath, exitScriptPath });
  const indeterminate = results.filter((r) => r.indeterminate);
  const withDiffs = results.filter((r) => !r.indeterminate && r.diffs.length > 0);

  if (args.json) {
    console.log(JSON.stringify(results, null, 2));
  } else {
    console.log(`replayed ${results.length} run(s), ${withDiffs.length} differ from their recorded exit, ${indeterminate.length} indeterminate`);
    for (const r of indeterminate) console.log(`run ${r.runId} (issue #${r.issue}): INDETERMINATE — ${r.reason}`);
    for (const r of withDiffs) {
      console.log(`run ${r.runId} (issue #${r.issue}):`);
      for (const d of r.diffs) {
        if (d.error) console.log(`  ${d.stage}: could not recompute — ${d.error}`);
        else console.log(`  ${d.stage}: recorded=${d.recorded} recomputed=${d.recomputed} (${d.reason})`);
      }
    }
  }
  return 0;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args) return 2;
  if (!args.repo || typeof args.repo !== "string") {
    console.error(
      "usage: dev-flow-stats.mjs --repo <owner/repo> --trusted-actor-id <id> [--as-of <iso8601>] [--json]\n" +
        "       dev-flow-stats.mjs --repo <owner/repo> --run <run_id> --trusted-actor-id <id> [--as-of <iso8601>] [--json]\n" +
        "       dev-flow-stats.mjs --repo <owner/repo> --replay --policy <file> --trusted-actor-id <id> [--exit-script <path>] [--json]",
    );
    return 2;
  }
  if (args.replay) return cliReplay(args);
  if (args.run) return cliRun(args);
  return cliMetrics(args);
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  process.exitCode = main();
}
