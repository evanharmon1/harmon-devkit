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
  /<!--\s*devflow:(run-index|run-record|evidence)\s+v2\s+run_id=(\S+)\s+stage=(\S+)\s+dest=(issue|pr)\s+round=(\S+)\s+seq=(\d+)\s*-->/;
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

// The schema-canonical payload-digest representation (ai/schemas/README.md
// "Digest" — "Payload digest"): sha256:<64 lowercase hex>, WITH the
// algorithm prefix. Distinct from a bare sha256() call, which every
// run.schema.json evidence_comments[].digest / evidence_registrations[].
// payload_digest field is NOT shaped like — comparing a bare hash against
// either field always fails for real, schema-valid evidence. review round 1,
// confirmed (P1): the prior bare comparison rejected every real
// evidence-bearing run as tampered, hidden by a matching bug in this
// file's own test fixtures (which built schema-invalid bare digests too).
function payloadDigest(text) {
  return `sha256:${sha256(text)}`;
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

// Evidence-comment trust narrows to the SPECIFIC actor who authored this
// run's own record — never the full configured set. "There is exactly one
// writer per run" (ai/schemas/README.md "Duplicate markers"): with more
// than one globally trusted actor id configured, falling back to "any of
// them" would let one trusted orchestrator's actor id inject rounds into
// a DIFFERENT orchestrator's run and alter its replay/metric results —
// challenge round 1, confirmed.
function isTrustedFor(comment, { runRecordAuthorId }) {
  const actorId = commentActorId(comment);
  return actorId !== null && runRecordAuthorId !== null && actorId === runRecordAuthorId;
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

// The lowest-id rule (ai/schemas/README.md "Duplicate markers") applies
// only to a duplicate post of the IDENTICAL event — content, not just
// marker, must agree. Two trusted comments sharing a marker but carrying
// DIFFERENT payload text are not a legitimate resume; the grammar's own
// text says so explicitly, but the prior code picked the lowest id
// regardless of content, silently resolving genuine inconsistent data as
// an ordinary retry — challenge round 1, confirmed (P2).
// Lowest-id wins UNCONDITIONALLY, even when concurrent duplicates carry
// different payload snapshots — the evidence spec's own text (§ "Evidence
// writes are reserve-first and idempotent") does not condition this on
// content agreement: "Harvesting SHALL resolve duplicate markers by this
// rule RATHER THAN report them as ambiguous." Requiring payload agreement
// (an earlier version of this function) was this lane's own
// over-generalization of the chain-fork rule (ai/schemas/README.md
// "Duplicate markers" — which is about the run record's OWN internal
// append-only arrays, a single-writer, single-comment, sequentially-edited
// context) onto SEPARATE GitHub comments, where the spec explicitly
// expects and tolerates a race between concurrent writers — challenge
// round 3, confirmed as a regression this lane introduced in round 1.
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
// Index-first discovery (ai/schemas/README.md "Comment kinds", run-index):
// a run-record comment is never trusted merely for existing and looking
// right — it must be the comment a trusted run-index entry names, by id,
// digest, and author. Deleting the run-record comment alone (leaving the
// index behind) is deleted-entry tampering, reported as such, never
// silently read as "this issue was never kicked off" — challenge round 1,
// confirmed (the prior version scanned only for run-record markers, with
// no independent anchor to notice the deletion at all).
function findRunRecord(issueComments, { trustedActorIds }) {
  const byId = new Map(issueComments.map((c) => [c.id, c]));
  const indexMarked = markedComments(issueComments).filter((e) => e.marker.kind === "run-index");
  const trustedIndex = indexMarked.filter((e) => trustedActorIds.has(e.actorId));
  const untrustedIndex = indexMarked.filter((e) => !trustedActorIds.has(e.actorId));

  if (trustedIndex.length === 0) {
    if (untrustedIndex.length > 0) {
      throw new EvidenceError(
        `run-index marker present but authored by an untrusted actor id (${untrustedIndex.map((e) => e.actorId).join(", ")}) — forged evidence, ignored`,
      );
    }
    return null;
  }

  // Multiple distinct run_ids with a trusted index on one issue is a
  // different run each time (a retry) — group by run_id and resolve
  // canonical duplicates (identical re-posts) within each; conflicting
  // content under one marker fails closed via resolveCanonical itself.
  const byRunId = new Map();
  for (const e of trustedIndex) {
    const list = byRunId.get(e.marker.runId) || [];
    list.push(e);
    byRunId.set(e.marker.runId, list);
  }

  // One run_id's tampered/malformed index or record must not lose track of
  // WHICH run_id it was about, and must not prevent discovering this
  // issue's OTHER runs — each run_id is isolated exactly the way
  // harvestOneRunRecord already isolates later per-run failures.
  const results = [];
  for (const [runId, entries] of byRunId) {
    try {
      const canonicalMap = resolveCanonical(entries);
      const indexEntry = [...canonicalMap.values()][0];
      let indexPayload;
      try {
        indexPayload = JSON.parse(indexEntry.payloadText);
      } catch (err) {
        throw new EvidenceError(`run-index ${runId} (comment ${indexEntry.comment.id}) is not valid JSON: ${err.message}`);
      }
      const named = indexPayload.run_record || {};
      const namedId = Number(named.id);
      const recordComment = byId.get(namedId);
      if (!recordComment) {
        throw new EvidenceError(`run-index ${runId} names run-record comment ${named.id}, which no longer exists — deleted-entry tampering`);
      }
      if (!trustedActorIds.has(named.author_actor_id)) {
        throw new EvidenceError(`run-index ${runId} names run-record author ${named.author_actor_id}, which is not a configured trusted actor`);
      }
      if (commentActorId(recordComment) !== named.author_actor_id) {
        throw new EvidenceError(`run-index ${runId} names run-record author ${named.author_actor_id}, but comment ${named.id}'s current author is ${commentActorId(recordComment)} — edited-entry tampering`);
      }
      // No digest check here: the run-record is explicitly edited in
      // place at every transition, so a digest captured once at kickoff
      // would stop matching after the run's very first legitimate edit —
      // challenge round 2, confirmed as a P0 in an earlier version of this
      // check. The index authenticates the comment's IDENTITY (id +
      // author, both checked above); the record's own CONTENT integrity
      // comes from its internal append-only chains (verifyRunRecordChains
      // below), not from an outer digest pinned to a moment its content
      // is designed to outgrow.
      const recordPayloadText = fencedPayloadText(recordComment.body || "");
      if (recordPayloadText === null) {
        throw new EvidenceError(`run-index ${runId} names run-record comment ${named.id}, which no longer carries a fenced payload — edited-entry tampering`);
      }
      const recordMarker = parseMarker(recordComment.body || "");
      if (!recordMarker || recordMarker.kind !== "run-record" || recordMarker.runId !== runId) {
        throw new EvidenceError(`run-index ${runId} names comment ${named.id}, whose current marker no longer identifies it as this run's run-record — edited-entry tampering`);
      }
      let body;
      try {
        body = JSON.parse(recordPayloadText);
      } catch (err) {
        throw new EvidenceError(`run record ${runId} (comment ${named.id}) is not valid JSON: ${err.message}`);
      }
      results.push({
        status: "ok",
        runId,
        commentId: recordComment.id,
        authorActorId: named.author_actor_id,
        authorLogin: named.login,
        body,
        rawText: recordPayloadText,
      });
    } catch (err) {
      if (err instanceof EvidenceError) {
        results.push({ status: "indeterminate", runId, reason: err.message });
        continue;
      }
      throw err;
    }
  }
  return results;
}

// The run record's own evidence_comments[] is the authoritative index of
// every evidence comment that exists — discovery is LIST-DRIVEN, not
// marker-scan-driven (evidence spec: "the harvester SHALL accept only
// comments named by the trusted run record"; "the issue-level index...
// SHALL anchor run discovery... SHALL reject deleted-entry tampering,
// never reinterpret it as a run that did not happen"). Scanning for
// matching markers and trusting anything the author's own actor id could
// have posted (the prior design) accepted an ORPHAN evidence comment the
// author posted but never indexed — challenge round 2, confirmed — which
// is exactly backwards from "accept only comments NAMED by the record".
// withinCutoff scopes which VERIFIED entries are assembled into rounds
// (an --as-of reconstruction should not see a round posted after the
// cutoff) — but every listed entry is still verified for tampering
// against the full, unfiltered comment set regardless of cutoff, for the
// same reason findRunRecord's own cutoff filtering only ever applies to
// discovery, never to whether a listed entry was deleted or edited.
function assembleListedEvidence(runRecord, allComments, withinCutoff) {
  const byId = new Map(allComments.map((c) => [c.id, c]));
  const verified = [];
  for (const entry of runRecord.evidence_comments || []) {
    const id = Number(entry.id);
    const comment = byId.get(id);
    if (!comment) {
      throw new EvidenceError(`evidence_comments[] names comment ${entry.id} (marker ${JSON.stringify(entry.marker)}), which no longer exists — deleted-entry tampering`);
    }
    if (commentActorId(comment) !== entry.author_actor_id) {
      throw new EvidenceError(`evidence_comments[] entry for comment ${entry.id} names author ${entry.author_actor_id} but the comment's current author is ${commentActorId(comment)}`);
    }
    // The payload can be untouched while only the marker line changes —
    // author agreement alone would miss that, and grouping-by-marker below
    // would then attribute this SAME indexed comment to a different
    // run/stage/round/destination/sequence than the one it was actually
    // indexed for, defeating the sequence the marker exists to
    // authenticate — challenge round 1, confirmed.
    const currentMarker = parseMarker(comment.body || "");
    const listed = entry.marker || {};
    // Bound to the run being harvested, not just internally self-consistent
    // with the list entry: a stale or buggy record could list an entry
    // whose OWN marker names a DIFFERENT run_id than runRecord.run_id
    // (e.g. copy-paste across a retry's two run records) and the check
    // above would still pass, since it only compares the comment's current
    // marker against the list entry — never against the run actually being
    // harvested. `kind` is checked for the same reason: nothing before this
    // point requires the referenced comment to BE an evidence comment at
    // all. Both — challenge round 3, confirmed.
    const markersAgree =
      currentMarker &&
      currentMarker.kind === "evidence" &&
      currentMarker.runId === runRecord.run_id &&
      currentMarker.runId === listed.run_id &&
      currentMarker.stage === listed.stage &&
      currentMarker.dest === listed.destination &&
      currentMarker.round === listed.round &&
      currentMarker.seq === listed.sequence;
    if (!markersAgree) {
      throw new EvidenceError(`evidence_comments[] entry for comment ${entry.id} no longer matches its recorded marker or does not bind to run ${runRecord.run_id} (listed ${JSON.stringify(listed)}, current ${JSON.stringify(currentMarker)}) — edited-entry tampering`);
    }
    const payloadText = fencedPayloadText(comment.body || "");
    if (payloadText === null) {
      throw new EvidenceError(`evidence_comments[] entry for comment ${entry.id} no longer carries a fenced payload — edited-entry tampering`);
    }
    verified.push({ marker: listed, entryDigest: entry.digest, comment, payloadText });
  }

  // Group by (stage, destination, round) — ignoring sequence, since a
  // split payload's segments share every marker field except that one
  // (ai/schemas/README.md "Segment reassembly"). Cutoff-filtered here,
  // AFTER every entry above was already verified unconditionally.
  const groups = new Map();
  for (const v of verified) {
    if (!withinCutoff(v.comment)) continue;
    const key = `${v.marker.stage} ${v.marker.destination} ${v.marker.round}`;
    const list = groups.get(key) || [];
    list.push(v);
    groups.set(key, list);
  }

  const rounds = [];
  for (const [key, entries] of groups) {
    entries.sort((a, b) => a.marker.sequence - b.marker.sequence);
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].marker.sequence !== i + 1) {
        throw new EvidenceError(`${key}: segment sequence has a gap or does not start at 1 (present: ${entries.map((e) => e.marker.sequence).join(",")})`);
      }
    }
    // Every segment in a split payload carries the digest of the FULL
    // reassembled text (ai/schemas/README.md "Digest") — not its own
    // individual segment text. Hashing each segment against its own
    // indexed digest (the prior code, inherited from the pre-list-driven
    // design) fails authentication for every real split payload even
    // though reassembly itself succeeds — challenge round 2, confirmed.
    const digests = new Set(entries.map((e) => e.entryDigest));
    if (digests.size > 1) {
      throw new EvidenceError(`${key}: segments disagree on the reassembled-payload digest they were indexed with — tampering`);
    }
    const fullText = entries.map((e) => e.payloadText).join("");
    if (payloadDigest(fullText) !== entries[0].entryDigest) {
      throw new EvidenceError(`${key}: reassembled payload does not match its indexed digest — edited-entry tampering`);
    }
    let payload;
    try {
      payload = JSON.parse(fullText);
    } catch (err) {
      throw new EvidenceError(`${key}: reassembled segments are not valid JSON: ${err.message}`);
    }
    const { stage, destination: dest, round } = entries[0].marker;
    rounds.push({ stage, dest, round, payload, commentIds: entries.map((e) => e.comment.id) });
  }
  return rounds;
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

// A resumed writer's own retry re-appends an entry that already landed,
// byte-identical to the one already there — same seq, same prev_digest,
// same digest (the digest is computed FROM content+prev_digest, so
// identical content necessarily produces an identical digest). The
// evidence spec requires collapsing that harmless case to one entry
// BEFORE raw sequence validation runs, since the un-normalized array
// otherwise has two entries claiming the same seq and the strict
// `entries[i].seq === i` check below rejects it as broken — review round
// 1, confirmed (P1): this normalization was never implemented, so any
// writer retry broke the whole chain. Two entries sharing a seq but
// carrying DIFFERENT digests are the opposite case — a genuine FORK — and
// must still fail closed rather than have either one silently picked
// (scenario "fork" in scripts/test-dev-flow-stats.sh proves this).
function normalizeExactDuplicates(rawEntries) {
  const bySeq = new Map();
  for (const entry of rawEntries) {
    const list = bySeq.get(entry.seq) || [];
    list.push(entry);
    bySeq.set(entry.seq, list);
  }
  const normalized = [];
  for (const [seq, group] of bySeq) {
    const first = group[0];
    const allIdentical = group.every((e) => e.digest === first.digest && e.prev_digest === first.prev_digest);
    if (!allIdentical) {
      return { ok: false, reason: `two entries at seq ${seq} share a predecessor but carry different content — forked chain`, brokenAtSeq: seq };
    }
    normalized.push(first);
  }
  return { ok: true, entries: normalized };
}

// contentKeys names the entry's semantic fields (excluding seq/digest/
// prev_digest themselves). Returns { ok: true, entries: [...sorted by seq] }
// or { ok: false, reason, brokenAtSeq }.
function verifyChain(rawEntries, contentKeys) {
  if (!Array.isArray(rawEntries)) return { ok: false, reason: "not an array", brokenAtSeq: null };
  const deduped = normalizeExactDuplicates(rawEntries);
  if (!deduped.ok) return deduped;
  const entries = deduped.entries.sort((a, b) => (a.seq ?? -1) - (b.seq ?? -1));
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
  // The three chains below protect evidence_comments[]/pr/outcome — round 4
  // of #663, closing the gap ai/schemas/README.md documented as an open
  // design question after challenge round 3. Unlike the three above, these
  // three ARE part of the shipped run.schema.json (not blocked on #738):
  // the flat fields stay in the schema for existing direct consumers
  // (scripts/render-dev-flow.mjs reads record.run.pr.number/.url), but are
  // now DERIVED and cross-checked against their chain rather than trusted
  // as bare mutable fields — see deriveProjections/verifyProjections below.
  evidence_registrations: ["id", "author_actor_id", "login", "payload_digest", "marker", "registered_at"],
  pr_bindings: ["number", "url", "bound_at"],
  outcome_transitions: ["outcome", "at"],
};
const CHAIN_TIMESTAMP_FIELD = {
  stage_transitions: "entered_at",
  interventions: "at",
  settlements: "settled_at",
  evidence_registrations: "registered_at",
  pr_bindings: "bound_at",
  outcome_transitions: "at",
};

// Validates all six append-only arrays in a run-record body. Throws
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

// Recomputes the flat evidence_comments[]/pr/outcome fields from their
// verified chains — the projection deriveProjections/verifyProjections
// compare the live record against, so an edited or deleted registration is
// caught the same way an edited transition already is (round 4's ask).
function deriveProjections(chains) {
  const evidence_comments = chains.evidence_registrations.map((r) => ({
    id: r.id,
    author_actor_id: r.author_actor_id,
    login: r.login,
    digest: r.payload_digest,
    marker: r.marker,
  }));
  const lastPr = chains.pr_bindings[chains.pr_bindings.length - 1];
  const pr = lastPr ? { number: lastPr.number, url: lastPr.url } : null;
  const lastOutcome = chains.outcome_transitions[chains.outcome_transitions.length - 1];
  const outcome = lastOutcome ? lastOutcome.outcome : null;
  return { evidence_comments, pr, outcome };
}

// Throws EvidenceError when a flat field has drifted from its chain-derived
// value — this is what makes the chain actually PROTECT the flat field,
// rather than merely existing alongside it unread. A drift means either the
// chain was tampered (caught above, before this ever runs) or the flat
// field was overwritten out-of-band; either way the record is untrustworthy
// past this point.
function verifyProjections(body, chains) {
  const derived = deriveProjections(chains);
  if (canonicalJson(body.evidence_comments || []) !== canonicalJson(derived.evidence_comments)) {
    throw new EvidenceError("run record evidence_comments[] does not match its evidence_registrations[] chain — out-of-band edit");
  }
  if (canonicalJson(body.pr ?? null) !== canonicalJson(derived.pr)) {
    throw new EvidenceError("run record pr does not match its pr_bindings[] chain — out-of-band edit");
  }
  if (canonicalJson(body.outcome ?? null) !== canonicalJson(derived.outcome)) {
    throw new EvidenceError("run record outcome does not match its outcome_transitions[] chain — out-of-band edit");
  }
}

// `--as-of` reconstruction: validate the COMPLETE chain first (a break
// after the cutoff still means nothing before it can be trusted, since the
// break could be a rewrite of earlier history too — ai/schemas/README.md),
// then keep only entries at or before the cutoff.
function reconstructAsOf(body, cutoffIso) {
  const chains = verifyRunRecordChains(body);
  // Tamper check against CURRENT (unfiltered) state, once, regardless of
  // cutoff — a chain broken or drifted from its flat projection right now
  // means the record is untrustworthy at any --as-of, the same reasoning
  // the complete-chain-first rule already applies below (round 4 of #663).
  verifyProjections(body, chains);
  const cutoff = cutoffIso ? Date.parse(cutoffIso) : Infinity;
  // evidence_registrations[]'s own registered_at is never actually
  // consumed below (this function's return value carries no
  // evidence_comments[] projection — assembleListedEvidence separately
  // governs which evidence a --as-of read assembles, using each comment's
  // own authoritative created_at, never registration time), but the
  // filtering runs uniformly across every chain anyway for consistency —
  // review round 1, confirmed: leaving it out of this loop as a special
  // case was itself only possible because the field did not exist yet.
  const filtered = {};
  for (const [arrayName, entries] of Object.entries(chains)) {
    const field = CHAIN_TIMESTAMP_FIELD[arrayName];
    filtered[arrayName] = entries.filter((e) => Date.parse(e[field]) <= cutoff);
  }
  const promotion =
    body.promotion && Date.parse(body.promotion.promoted_at) <= cutoff ? body.promotion : null;
  // pr/outcome now have their own timestamped, chain-verified history
  // (pr_bindings[]/outcome_transitions[] — round 4 of #663), so "as of a
  // cutoff" is simply the last filtered entry in each, replacing the
  // fragile transition-exit-text heuristic this function used before that
  // chain existed (it had no outcome timestamp to reconstruct from at all).
  const lastPr = filtered.pr_bindings[filtered.pr_bindings.length - 1];
  const pr = lastPr ? { number: lastPr.number, url: lastPr.url } : null;
  const lastOutcome = filtered.outcome_transitions[filtered.outcome_transitions.length - 1];
  const outcome = lastOutcome ? lastOutcome.outcome : null;
  // A transition's own claim is never sufficient for "ready-for-review" —
  // that specific value requires promotion (itself cutoff-checked above),
  // the same invariant challenge round 1 established when this was the
  // only way to derive outcome at all: an integration-stage exit does not
  // mean ready-for-review by itself if promotion never landed (or, for an
  // --as-of read, had not yet landed by the cutoff). A chain-verified entry
  // claiming otherwise is an inconsistent record, not a quiet downgrade.
  if (outcome === "ready-for-review" && !promotion) {
    throw new EvidenceError("run record outcome_transitions[] claims ready-for-review without a corresponding promotion — inconsistent record");
  }
  return {
    run_id: body.run_id,
    initiated_by: body.initiated_by,
    started_at: body.started_at,
    stage_transitions: filtered.stage_transitions,
    interventions: filtered.interventions,
    settlements: filtered.settlements,
    pr,
    promotion,
    outcome,
  };
}

// ---------------------------------------------------------------------------
// Orphan detection (reporting only — never trusted, never assembled): a
// comment shaped like evidence for this run, posted by an actor who could
// legitimately author it, but never added to evidence_comments[]. Kept
// visible in trajectory output as a signal something may have failed to
// index (a crash between posting and updating the list) — assembleListedEvidence
// above never accepts it regardless.
// ---------------------------------------------------------------------------

function findOrphanEvidence(comments, { runId, runRecordAuthorId, listedIds }) {
  const marked = markedComments(comments).filter((e) => e.marker.kind === "evidence" && e.marker.runId === runId);
  return marked.filter((e) => isTrustedFor(e.comment, { runRecordAuthorId }) && !listedIds.has(e.comment.id));
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
function harvestOneRunRecord(repo, issueNumber, record, { asOf, issueComments, withinCutoff }) {
  try {
    const state = reconstructAsOf(record.body, asOf);
    // The LIVE pr (record.body.pr), never the as-of-filtered state.pr:
    // assembleListedEvidence below verifies every LIVE evidence_comments[]
    // entry unconditionally (existence/author/marker, regardless of
    // --as-of — see its own comment), so it needs every comment that
    // entry list could name, including PR-side rollups posted after a
    // requested historical cutoff. Fetching by state.pr instead — review
    // round 1, confirmed (P1) — made an as-of read taken before the run's
    // PR existed skip fetching PR comments entirely (state.pr correctly
    // null), so any evidence_comments[] entry the LIVE record later added
    // for a PR rollup could never be found and was reported as
    // deleted-entry tampering, even though nothing was deleted. The
    // as-of exclusion of those later entries from the ASSEMBLED
    // trajectory still happens correctly downstream, via withinCutoff.
    const allPrComments = record.body.pr ? fetchPrComments(repo, record.body.pr.number) : [];
    const allComments = [...issueComments, ...allPrComments];
    // List-driven: verifies every evidence_comments[] entry (unconditionally
    // — a listed comment either genuinely exists, unedited, or it's
    // tampering, regardless of --as-of) and assembles only the entries
    // whose own comment predates the cutoff into rounds. A reassembly-time
    // error (missing segment, malformed JSON, digest mismatch) throws —
    // the evidence spec requires "indeterminate rather than a partial
    // trajectory" (§ "Split evidence reassembles deterministically");
    // silently keeping whatever DID reassemble (an earlier version of this
    // function) let metrics and replay operate on a trajectory the
    // producer never actually emitted — challenge round 1, confirmed.
    const rounds = assembleListedEvidence(record.body, allComments, withinCutoff);
    const listedIds = new Set((record.body.evidence_comments || []).map((e) => Number(e.id)));
    const orphans = findOrphanEvidence(allComments, { runId: record.runId, runRecordAuthorId: record.authorActorId, listedIds });
    return {
      status: "ok",
      runId: record.runId,
      issueNumber,
      record,
      state,
      rounds,
      untrusted: orphans,
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
  const cutoffEpoch = asOf ? Date.parse(asOf) : Infinity;
  const withinCutoff = (comment) => Date.parse(comment.created_at) <= cutoffEpoch;

  // A run-record comment created AFTER the cutoff must not even be
  // discovered — the evidence spec's own scenario ("a new retry starts
  // after the cutoff... neither removes the issue from the earlier cohort
  // nor changes its earlier score") requires it to be as if it did not
  // exist yet, not merely to reconstruct in-flight. Discovery itself, not
  // just round evidence, needs the cutoff filter — challenge round 1,
  // confirmed.
  let records;
  try {
    records = findRunRecord(issueComments.filter(withinCutoff), { trustedActorIds });
  } catch (err) {
    if (err instanceof EvidenceError) {
      return [{ status: "indeterminate", runId: null, issueNumber, reason: err.message }];
    }
    throw err;
  }
  if (!records) return [];

  // findRunRecord already isolates per-run_id failures (status:
  // "indeterminate", with the runId it actually failed on) — pass those
  // straight through with issueNumber attached; only "ok" entries still
  // need harvestOneRunRecord's further (evidence-level) processing.
  return records.map((record) =>
    record.status === "indeterminate"
      ? { status: "indeterminate", runId: record.runId, issueNumber, reason: record.reason }
      : harvestOneRunRecord(repo, issueNumber, record, { asOf, issueComments, withinCutoff }),
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
  // A human re-kicking a failed run is itself an intervention on the
  // issue's trajectory, while a Foreman automatic retry is not (specs/
  // dev-flow-v2.md § Success metric, verbatim) — review round 1, confirmed
  // (P1): this was documented in this function's own comment above but
  // never actually implemented; totalInterventions summed each run's OWN
  // interventions[] and never inspected initiated_by at all, so two
  // interventions-free runs (a failed Foreman-visible run, then a
  // human-initiated retry that reaches ready-for-review) reported success.
  // The FIRST run (earliest started_at) is the original kickoff, never
  // itself a "re-kick" regardless of who initiated it; every run after
  // that is a re-kick, counted here only when a human did it.
  const byStart = [...terminalized].sort((a, b) => Date.parse(a.state.started_at) - Date.parse(b.state.started_at));
  const rekickInterventions = byStart.slice(1).filter((r) => r.state.initiated_by === "human").length;
  const totalInterventions = terminalized.reduce((n, r) => n + runInterventionCount(r.state), 0) + rekickInterventions;
  const totalAsked = terminalized.reduce((n, r) => n + runAskedCount(r.state), 0);
  const readyRun = terminalized.find((r) => r.state.outcome === "ready-for-review");
  const success = Boolean(readyRun) && totalInterventions === 0;
  return { closed: true, success, interventions: totalInterventions, asked: totalAsked, runs: terminalized };
}

function computePostReadyFix(repo, readyRun, cutoffEpoch) {
  const promotion = readyRun.state.promotion;
  if (!promotion) return false;
  const commits = ghApiPaginated(`repos/${repo}/pulls/${readyRun.state.pr.number}/commits?per_page=100`);
  // Commit POSITION relative to promotion.head, not committer timestamp —
  // challenge round 1, confirmed: a cherry-picked human fix can carry an
  // older timestamp than the promotion, and a rebase can carry a newer one
  // for a commit that predates it; only "does it come after promotion.head
  // in the PR's own commit sequence" answers the actual question. A head
  // that no longer appears (a force-push rewrote it) has no sequence to
  // measure against, so this reports no fix rather than guessing — a
  // known simplification for this P2 signal, not the primary cohort
  // determination.
  const headIndex = commits.findIndex((c) => c.sha === promotion.head);
  if (headIndex === -1) return false;
  // The commits API is always live — fetching "now" and never checking
  // --as-of meant re-running the SAME historical cutoff could report a
  // DIFFERENT post_ready_fix_count as new commits landed later, violating
  // the closed immutable cohort requirement (the same window and cutoff
  // must always report the same share) — challenge round 3, confirmed.
  // Position still decides WHETHER a commit is a genuine post-promotion
  // fix (unaffected by rebases/cherry-picks); committer date additionally
  // bounds WHICH of those were already visible as of the requested cutoff.
  return commits
    .slice(headIndex + 1)
    .some((c) => Date.parse(c.commit.committer.date) <= cutoffEpoch);
}

// First kickoff = the earliest started_at among an issue's successfully
// harvested runs. An indeterminate run's started_at cannot be trusted the
// same way (its chain never passed verification), so it never EXCLUDES an
// issue from the window — only a verified "ok" run's timestamp can.
function firstKickoffEpoch(issueRuns) {
  const started = issueRuns.filter((r) => r.status === "ok").map((r) => Date.parse(r.state.started_at));
  return started.length > 0 ? Math.min(...started) : null;
}

function computeClosedCohortMetric(repo, runsByIssue, { staleAfterDays, asOf, since }) {
  const asOfEpoch = asOf ? Date.parse(asOf) : Date.now();
  // Membership is fixed by first kickoff INSIDE the reporting window
  // (specs/dev-flow-v2.md § Success metric) — --as-of already bounds the
  // upper end at discovery time (a run-record created after the cutoff is
  // never even discovered); --since bounds the lower end here. Challenge
  // round 1, confirmed: without it the denominator was unbounded lifetime
  // data rather than a closed window.
  const sinceEpoch = since ? Date.parse(since) : -Infinity;
  let closedCount = 0;
  let successCount = 0;
  let askedTotal = 0;
  let postReadyFixCount = 0;
  let indeterminateCount = 0;
  const perIssue = [];
  for (const [issueNumber, issueRuns] of runsByIssue) {
    const kickoff = firstKickoffEpoch(issueRuns);
    if (kickoff !== null && kickoff < sinceEpoch) continue;
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
    if (verdict.success) successCount++;
    // Post-ready fixes are a SECOND, independent failure measure
    // (specs/dev-flow-v2.md § Success metric) — evaluated for any issue
    // that reached ready-for-review at all, not only ones that also had
    // zero pre-ready interventions. Gating this on verdict.success (the
    // prior code) meant an issue with a pre-ready intervention that still
    // reached ready-for-review, then needed a post-ready fix too, was
    // never even checked — challenge round 2, confirmed.
    const readyRun = verdict.runs.find((r) => r.state.outcome === "ready-for-review");
    if (readyRun && computePostReadyFix(repo, readyRun, asOfEpoch)) postReadyFixCount++;
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

// dev-flow-exit.mjs's --current-head must be "an independently captured
// value" of the head actually under evaluation. A promoted run has one
// (promotion.head), but a capped/escalated run — the trajectory replay
// most needs (specs/dev-flow-v2.md § Evidence) — never got promoted, so
// there is no promotion to read. Using an invented all-zero placeholder
// (the prior code) fails dev-flow-exit.mjs's own head-ancestry checks and
// misclassifies exactly the rounds replay exists to re-examine — challenge
// round 2, confirmed. The stage's own latest retained round already
// carries the real reviewed head on every pass envelope; use that.
function currentHeadForStage(run, stage) {
  // Always prefer THIS stage's own latest round — even for a promoted run.
  // Using promotion.head unconditionally for every stage (an earlier
  // version of this function) is wrong whenever review or integration
  // added commits after challenge's own final round: challenge's real
  // reviewed head is then an ANCESTOR of promotion.head, and replaying
  // challenge against the later head can misreport an unchanged policy as
  // invalidated or different — challenge round 3, confirmed. promotion.head
  // is only the right fallback when a stage genuinely has no retained
  // round of its own to read a head from.
  const stageRounds = run.rounds
    .filter((r) => r.stage === stage && r.dest === "issue" && r.round !== null)
    .sort((a, b) => b.round - a.round);
  for (const round of stageRounds) {
    const passes = Array.isArray(round.payload.passes) ? round.payload.passes : [];
    for (const pass of passes) {
      const head = pass.payload && pass.payload.reviewed_head;
      if (head) return head;
    }
  }
  if (run.state.promotion) return run.state.promotion.head;
  return "0".repeat(40);
}

function replayOneRun(run, { policyPath, exitScriptPath, tmpRoot }) {
  const runDir = path.join(tmpRoot, run.runId);
  buildRunDirectory(run.record.body, run.rounds, runDir);
  const diffs = [];
  for (const stage of ["challenge", "review"]) {
    const hasRounds = run.rounds.some((r) => r.stage === stage && r.dest === "issue" && r.round !== null);
    if (!hasRounds) continue;
    const currentHead = currentHeadForStage(run, stage);
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
  assembleListedEvidence,
  findOrphanEvidence,
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
  payloadDigest,
  canonicalDigest,
  canonicalJson,
  commentActorId,
  isTrustedFor,
  markedComments,
  markerKey,
  resolveCanonical,
  findRunRecord,
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

// An invalid date string silently becomes NaN through Date.parse, which
// every cutoff/window comparison in this file treats as "excludes
// everything" rather than an error — the command would exit 0 with a
// plausible-looking, silently wrong empty metric instead of refusing bad
// input. Challenge round 2, confirmed (P2).
function parseIsoDateArg(flagName, value) {
  if (value === null) return { ok: true, value: null };
  if (Number.isNaN(Date.parse(value))) {
    return { ok: false, error: `dev-flow-stats: --${flagName} is not a valid ISO-8601 timestamp: ${JSON.stringify(value)}` };
  }
  return { ok: true, value };
}

function cliMetrics(args) {
  const trustedActorIds = requireTrustedActorIds(args);
  if (!trustedActorIds) return 2;
  const asOfArg = parseIsoDateArg("as-of", typeof args["as-of"] === "string" ? args["as-of"] : null);
  if (!asOfArg.ok) {
    console.error(asOfArg.error);
    return 2;
  }
  const sinceArg = parseIsoDateArg("since", typeof args.since === "string" ? args.since : null);
  if (!sinceArg.ok) {
    console.error(sinceArg.error);
    return 2;
  }
  const asOf = asOfArg.value;
  const since = sinceArg.value;
  let staleAfterDays = DEFAULT_STALE_AFTER_DAYS;
  if (args["stale-after-days"]) {
    staleAfterDays = Number(args["stale-after-days"]);
    if (!Number.isFinite(staleAfterDays) || staleAfterDays <= 0) {
      console.error(`dev-flow-stats: --stale-after-days must be a positive number, got ${JSON.stringify(args["stale-after-days"])}`);
      return 2;
    }
  }

  let runs;
  try {
    runs = discoverAllRuns(args.repo, { trustedActorIds, asOf });
  } catch (err) {
    console.error(`dev-flow-stats: ${err.message}`);
    return err instanceof EvidenceError ? 3 : 2;
  }
  const metric = computeClosedCohortMetric(args.repo, groupRunsByIssue(runs), { staleAfterDays, asOf, since });

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
  const asOfArg = parseIsoDateArg("as-of", typeof args["as-of"] === "string" ? args["as-of"] : null);
  if (!asOfArg.ok) {
    console.error(asOfArg.error);
    return 2;
  }
  const asOf = asOfArg.value;

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
      "usage: dev-flow-stats.mjs --repo <owner/repo> --trusted-actor-id <id> [--since <iso8601>] [--as-of <iso8601>] [--json]\n" +
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
