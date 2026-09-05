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

// A field a pusher fully controls (committer/author date) cannot prove
// when a commit became visible on GitHub — a cherry-pick can carry any
// date its author chooses. `Commit.pushedDate` (an earlier version of
// this fix) turned out not to be a working substitute — verified directly
// against six real commits spanning two weeks in this repo, every one
// null, so it is not an occasional gap here but a value this repo's
// commits never carry. first_seen(sha) instead uses whichever of two
// REST endpoints actually returns real, server-recorded data for a given
// commit: the merging PR's own `merged_at` for a commit already on the
// default branch (direct pushes to main are ruleset-blocked, so a commit
// there has exactly one merging PR), or the earliest check-suite's
// `created_at` for a commit not yet merged — both independently verified
// against this branch's own history before use. review round 4 of #663,
// maintainer-directed (twice-revised) fix for the two P1s deferred at
// review's own cap. Resolves to null (indeterminate) when neither source
// has data — every caller treats that as indeterminate, never a silent
// "not yet visible".
function firstSeen(repo, sha) {
  const prs = ghApiPaginated(`repos/${repo}/commits/${sha}/pulls`);
  const merged = prs.find((pr) => pr.merged_at);
  const suites = ghApiPaginated(`repos/${repo}/commits/${sha}/check-suites`);
  // The check-suites endpoint wraps its array in a `check_suites` object
  // per page rather than returning a bare array — ghApiPaginated's
  // --slurp flattening only flattens the page array itself, not this
  // endpoint's own nested field.
  const flatSuites = suites.flatMap((page) => (Array.isArray(page.check_suites) ? page.check_suites : []));
  const timestamps = flatSuites.map((s) => Date.parse(s.created_at)).filter((t) => Number.isFinite(t));
  // Take the EARLIEST of every available signal, never merged_at alone —
  // shepherd round 1, Codex-confirmed (P2): a commit's check-suites can run
  // (and be visible) well before its PR merges, so preferring merged_at
  // unconditionally let the SAME immutable --as-of cutoff flip a commit
  // from visible to not-visible depending on whether the query ran before
  // or after the eventual merge, defeating the exact reproducibility
  // first_seen exists to guarantee.
  if (merged) timestamps.push(Date.parse(merged.merged_at));
  if (timestamps.length > 0) return new Date(Math.min(...timestamps)).toISOString();
  return null;
}

const defaultBranchCache = new Map();

// shepherd round 2, Codex-confirmed (P2): sha=main was hardcoded — a
// target repo whose default branch is not literally "main" would search
// the wrong (or a nonexistent) ref, hit the catch below, and silently
// fall back to full CLI trust. The CLI is explicitly repository-generic
// (--repo <owner/repo>, any repo), so this resolves and caches the real
// default branch instead of assuming.
function resolveDefaultBranch(repo) {
  if (!defaultBranchCache.has(repo)) {
    defaultBranchCache.set(repo, ghApiOne(`repos/${repo}`).default_branch);
  }
  return defaultBranchCache.get(repo);
}

// "When did this commit land on the default branch" — narrower than
// firstSeen(sha)'s "when did this commit first become visible anywhere in
// the repo". shepherd round 2, Codex-confirmed (P1): reusing firstSeen's
// MIN-of-(merged_at, any check-suite) for registry-revision selection was
// wrong — a registry commit's check suite can run on its OWN feature
// branch, before it ever merges, and that pre-merge time is not when the
// revision actually took effect on the default branch. Every commit
// reachable via the default-branch path listing (resolveRegistryTrustedActorIds's
// own commits?path=...&sha=<default> call) has exactly one merging PR
// (direct pushes to the default branch are ruleset-blocked), so merged_at
// alone is always available here and is the only correct signal — no
// check-suite fallback, unlike firstSeen.
function defaultBranchLandedAt(repo, sha) {
  const prs = ghApiPaginated(`repos/${repo}/commits/${sha}/pulls`);
  const merged = prs.find((pr) => pr.merged_at);
  return merged ? merged.merged_at : null;
}

// Repo-committed trust narrowing: issue #741 proposes a trusted-orchestrator
// actor allowlist in agent-registry.json, pinned to the revision in effect
// at evidence-write time — never the latest, which a later edit could
// otherwise retroactively (re)grant trust to an actor a run's own evidence
// never actually had. #741's acceptance criteria (the allowlist field
// itself, historical pinning, fixtures) are all still unchecked as of this
// writing: the field this resolves toward does not exist at any commit
// yet. This function is the revision-SELECTION mechanism, ready the moment
// #741 lands the field — every caller treats a still-absent field (or an
// unreadable/unlisted revision) as "no registry opinion," falling back
// unchanged to the --trusted-actor-id/--trusted-actors-file trust
// requireTrustedActorIds already establishes. It only ever NARROWS that
// trust, never widens it — the same direction assembleListedEvidence
// already narrows evidence-comment trust to one run's own author rather
// than the whole configured set.
//
// "Revision in effect" is selected by defaultBranchLandedAt(sha) — its own
// merged_at, never a committer/author date (the same spoofable-by-cherry-
// pick field review round 4 already closed once for post-ready-fix
// detection above) and never firstSeen's broader "visible anywhere"
// signal (shepherd round 2, Codex-confirmed — see defaultBranchLandedAt's
// own comment) — so a hostile or merely pre-merge-visible revision cannot
// be backdated into looking like it predates the write it is meant to
// govern. Among commits whose landing time is on or before atIso, the one
// with the LATEST landing time wins (the newest registry state actually
// in effect on the default branch by that moment).
//
// The full per-repo revision history (every agent-registry.json-touching
// commit reachable from the default branch, each with its own landed-at
// time) is resolved and cached ONCE per repo, not once per (issue,
// timestamp) pair — shepherd round 4, Codex-confirmed (P2): a --repo scan
// of R runs against C registry revisions previously re-walked the full
// commit list AND re-issued a commits/{sha}/pulls request per revision on
// EVERY call (each run's kickoff typically needing at least two — its
// record and its index), roughly 2×R×C synchronous API calls; a moderate
// history could exhaust GitHub's rate limit before ordinary issue
// harvesting even finished. History resolution is now O(C) once; every
// subsequent atIso lookup is an O(C) in-memory scan.
//
// A commit with no merging PR (defaultBranchLandedAt returns null) is only
// possible when the target --repo permits direct pushes to its default
// branch — this repo's own ruleset blocks that (see defaultBranchLandedAt's
// comment), but the CLI is explicitly repository-generic, so a permissive
// target repo cannot be assumed away — shepherd round 4, Codex-confirmed
// (P1). The unresolvable commit's OWN committer/author date is deliberately
// never used as a fallback: this file's firstSeen already established that
// a pusher-controlled date cannot prove when a commit became visible (see
// firstSeen's own comment) and a cherry-picked commit can carry any date
// its author chooses. Silently SKIPPING the unresolvable commit instead
// (continuing the scan past it, as an earlier version of this function
// did) is worse than either: a newer revision that happens to be a direct
// push could be silently invisible forever, so the scan would keep
// selecting a stale, resolvable, older revision as if it were current —
// confidently wrong rather than admittedly unknown. Since this mechanism
// only ever NARROWS trust (never widens it — see the block comment above),
// admitting "unknown" costs nothing beyond the narrowing itself: the
// caller's existing null-means-full-CLI-trust fallback is exactly the
// pre-registry baseline, never a security downgrade. So: any unresolvable
// commit voids the WHOLE repo's history (cached as null, same as an
// unreadable registry file) rather than being skipped in isolation.
const registryRevisionHistoryCache = new Map();

function resolveRegistryRevisionHistory(repo) {
  if (registryRevisionHistoryCache.has(repo)) return registryRevisionHistoryCache.get(repo);
  let history;
  try {
    const defaultBranch = resolveDefaultBranch(repo);
    const commits = ghApiPaginated(`repos/${repo}/commits?path=agent-registry.json&sha=${defaultBranch}`);
    const resolved = [];
    let unresolvable = false;
    for (const c of commits) {
      const seen = defaultBranchLandedAt(repo, c.sha);
      if (seen === null) {
        unresolvable = true;
        break;
      }
      resolved.push({ sha: c.sha, landedAtEpoch: Date.parse(seen) });
    }
    history = unresolvable ? null : resolved;
  } catch {
    history = null;
  }
  registryRevisionHistoryCache.set(repo, history);
  return history;
}

function resolveRegistryTrustedActorIds(repo, atIso) {
  const cutoff = Date.parse(atIso);
  const history = resolveRegistryRevisionHistory(repo);
  if (history === null) return null;
  let bestSha = null;
  let bestSeen = -Infinity;
  for (const { sha, landedAtEpoch } of history) {
    if (landedAtEpoch <= cutoff && landedAtEpoch > bestSeen) {
      bestSeen = landedAtEpoch;
      bestSha = sha;
    }
  }
  if (bestSha === null) return null;
  let doc;
  try {
    const file = ghApiOne(`repos/${repo}/contents/agent-registry.json?ref=${bestSha}`);
    doc = JSON.parse(Buffer.from(file.content, "base64").toString("utf8"));
  } catch {
    return null;
  }
  if (!Array.isArray(doc.trusted_orchestrator_actor_ids)) return null;
  const ids = doc.trusted_orchestrator_actor_ids.map(Number).filter((n) => Number.isInteger(n) && n >= 1);
  return new Set(ids);
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
// round=(-|\d+): the literal "-" or a plain digit run — never a bare \S+.
// shepherd round 1, Codex-confirmed (P2): \S+ let round=1junk parse as
// round:1 (Number.parseInt ignores trailing garbage), silently accepting
// an edited marker the payload digest doesn't cover (it protects only the
// fenced JSON, never the marker comment line itself).
const MARKER_RE =
  /<!--\s*devflow:(run-index|run-record|evidence)\s+v2\s+run_id=(\S+)\s+stage=(\S+)\s+dest=(issue|pr)\s+round=(-|\d+)\s+seq=(\d+)\s*-->/;
const FENCE_RE = /```json\r?\n([\s\S]*?)\r?\n```/;

class EvidenceError extends Error {}

function parseMarker(body) {
  const m = MARKER_RE.exec(body);
  if (!m) return null;
  const [, kind, runId, stage, dest, roundRaw, seqRaw] = m;
  if (!RUN_STAGES.includes(stage)) return null;
  const round = roundRaw === "-" ? null : Number.parseInt(roundRaw, 10);
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
function findRunRecord(issueComments, { trustedActorIds, repo }) {
  const byId = new Map(issueComments.map((c) => [c.id, c]));
  // The grammar reserves exactly ONE tuple for a run-index marker
  // (kickoff/issue/-/1) — shepherd round 1, Codex-confirmed (P2): checking
  // only `kind` accepted a trusted-but-noncanonical index (a stray
  // stage/dest/round/seq) that the protocol does not actually sanction.
  const canonicalIndexShape = (marker) =>
    marker !== null &&
    marker.kind === "run-index" &&
    marker.stage === "kickoff" &&
    marker.dest === "issue" &&
    marker.round === null &&
    marker.seq === 1;

  // Registry-revision pinning (issue #741, review round 4 of #663): narrows
  // trustedActorIds to whichever ids the repo-committed registry also
  // trusted AS OF each entry's own kickoff time — see
  // resolveRegistryTrustedActorIds for why, and why it no-ops entirely
  // until #741 lands its allowlist field. Evaluated per comment/run rather
  // than once for the whole issue, because two runs on the same issue can
  // kick off under two different registry revisions; cached by timestamp
  // since the same kickoff time is looked up again below for the
  // run-record author check.
  const registryTrustCache = new Map();
  const effectiveTrustAt = (atIso) => {
    if (!registryTrustCache.has(atIso)) {
      const registryIds = resolveRegistryTrustedActorIds(repo, atIso);
      registryTrustCache.set(atIso, registryIds ? new Set([...trustedActorIds].filter((id) => registryIds.has(id))) : trustedActorIds);
    }
    return registryTrustCache.get(atIso);
  };

  // ONE unified candidate list for run-index discovery — every trusted,
  // canonical-marker comment for this issue, well-formed or not — shepherd
  // round 6, Codex-confirmed (P1): the round-5 malformed-index fix treated
  // malformed and well-formed candidates as two SEPARATE pools, each
  // independently narrowed to its own "best" candidate, so a well-formed
  // duplicate posted AFTER a malformed original silently won canonical
  // status regardless of comment id. The evidence contract's lowest-id-
  // wins rule (ai/schemas/README.md "Duplicate markers") applies to every
  // trusted candidate sharing this run's one reserved index marker, not
  // only the ones that still happen to carry a payload — the invariant is
  // canonical selection, not "canonical selection among comments a
  // parser could fully read." canonicalIndexShape's own single reserved
  // tuple (kickoff/issue/-/1) means every candidate for one run_id already
  // shares the identical marker key, so resolveCanonical's ordinary
  // lowest-id resolution (below, used unchanged — no special-casing
  // needed) picks the one true canonical entry across a mix of both kinds
  // at once. Loosely, TIME-INDEPENDENTLY pre-filtered to the raw
  // CLI-configured set (never registry-narrowed): the real,
  // registry-narrowed decision for this index's own author can only be
  // evaluated once the named run-record — and so its authoritative
  // created_at — is known, inside the per-run_id loop below.
  const indexCandidates = [];
  for (const c of issueComments) {
    const marker = parseMarker(c.body || "");
    if (!canonicalIndexShape(marker)) continue;
    if (!trustedActorIds.has(commentActorId(c))) continue;
    indexCandidates.push({ comment: c, marker, actorId: commentActorId(c), payloadText: fencedPayloadText(c.body || "") });
  }

  // An untrusted-authored (or entirely absent) index is forged noise, not
  // evidence of tampering with a real run — never a trusted index to begin
  // with, so there is nothing here that WAS real Dev Flow activity.
  // Returning null (matching the "no index at all" case) rather than
  // throwing keeps a random commenter's marker-shaped paste out of
  // indeterminate_count — shepherd round 1, Codex-confirmed (P2): the
  // prior throw's own message said "ignored" but the code did not
  // actually ignore it, letting --repo's noise floor scale with how many
  // issues an untrusted party happens to paste a marker-shaped comment on.
  if (indexCandidates.length === 0) {
    return null;
  }

  // One run_id's tampered/malformed index or record must not lose track of
  // WHICH run_id it was about, and must not prevent discovering this
  // issue's OTHER runs — each run_id is isolated exactly the way
  // harvestOneRunRecord already isolates later per-run failures.
  const results = [];
  for (const indexEntry of resolveCanonical(indexCandidates).values()) {
    const runId = indexEntry.marker.runId;
    // Declared outside the try so the catch below can still read it —
    // shepherd round 2/3, Codex-confirmed (P2): see the catch block's own
    // comment for why.
    let recordComment;
    try {
      // A trusted-by-marker run-index whose canonical shape survives but
      // whose fenced payload is missing or malformed previously vanished
      // entirely: an earlier discovery pass required a parseable payload
      // before the comment was even considered, so a corrupted anchor was
      // indistinguishable from "this issue was never kicked off" instead
      // of being reported as tampered evidence — shepherd round 5,
      // Codex-confirmed (P1), the same silent-erasure challenge round 1
      // already closed for a fully DELETED comment, reopened here for a
      // payload-only corruption of a comment that is still physically
      // present. Routed through the SAME EvidenceError/indeterminate path
      // as every other tampering case below (rather than a separate,
      // hand-assembled result) so it automatically inherits the catch
      // block's own kickoffCreatedAt fallback — shepherd round 6,
      // Codex-confirmed (P2): a hand-rolled result the round-5 fix pushed
      // directly hardcoded kickoffCreatedAt to null instead of this
      // comment's own GitHub-assigned created_at, inflating
      // indeterminate_count for --since windows that should have excluded
      // it.
      if (indexEntry.payloadText === null) {
        throw new EvidenceError(`run-index ${runId} (comment ${indexEntry.comment.id}) has a canonical marker but no fenced payload — edited-entry tampering`);
      }
      let indexPayload;
      try {
        indexPayload = JSON.parse(indexEntry.payloadText);
      } catch (err) {
        throw new EvidenceError(`run-index ${runId} (comment ${indexEntry.comment.id}) is not valid JSON: ${err.message}`);
      }
      const named = indexPayload.run_record || {};
      const namedId = Number(named.id);
      recordComment = byId.get(namedId);
      if (!recordComment) {
        throw new EvidenceError(`run-index ${runId} names run-record comment ${named.id}, which no longer exists — deleted-entry tampering`);
      }
      // The INDEX's own author, evaluated at the RECORD's created_at — the
      // true kickoff moment, never the index's own later one — shepherd
      // round 5, Codex-confirmed (P2): looselyTrustedIndex above only
      // proved CLI-raw membership; this is the real, registry-narrowed
      // decision, deferred to here because only now is the named record
      // (and so its authoritative timestamp) known. See looselyTrustedIndex's
      // own comment for the full reasoning.
      if (!effectiveTrustAt(recordComment.created_at).has(indexEntry.actorId)) {
        throw new EvidenceError(`run-index ${runId} (comment ${indexEntry.comment.id}) author is not a registry-trusted actor as of this run's kickoff`);
      }
      // The record's OWN created_at, never the index's — shepherd round 3,
      // Codex-confirmed (P2): the record must exist (and so has already
      // been posted) before the index can name its comment id, so the
      // record's timestamp is always the earlier, truer kickoff moment;
      // the index's is later by however long that round-trip took. A
      // registry revision landing in that gap must be evaluated as of
      // when the record's author actually posted, not as of the index's
      // later timestamp, or a not-yet-trusted author could be admitted
      // retroactively.
      if (!effectiveTrustAt(recordComment.created_at).has(named.author_actor_id)) {
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
      // The run-record comment's reserved tuple (ai/schemas/README.md
      // "run-record": "stage is always kickoff... and round/seq are
      // always -/1 — the run record has exactly one comment, never split,
      // never duplicated by sequence") — the same rigor indexMarked's own
      // filter already applies to run-index above, mirrored here — shepherd
      // round 4, Codex-confirmed (P2): checking only kind and runId let an
      // edited marker claim any stage/dest/round/seq (e.g. a comment
      // physically on the issue claiming stage=review dest=pr round=1
      // seq=9) and still authenticate as this run's one true run-record.
      const recordMarker = parseMarker(recordComment.body || "");
      if (
        !recordMarker ||
        recordMarker.kind !== "run-record" ||
        recordMarker.runId !== runId ||
        recordMarker.stage !== "kickoff" ||
        recordMarker.dest !== "issue" ||
        recordMarker.round !== null ||
        recordMarker.seq !== 1
      ) {
        throw new EvidenceError(`run-index ${runId} names comment ${named.id}, whose current marker no longer identifies it as this run's run-record — edited-entry tampering`);
      }
      let body;
      try {
        body = JSON.parse(recordPayloadText);
      } catch (err) {
        throw new EvidenceError(`run record ${runId} (comment ${named.id}) is not valid JSON: ${err.message}`);
      }
      // The MARKER line's run_id (checked above, recordMarker.runId) and
      // the JSON PAYLOAD's own run_id field are two independent pieces of
      // text in the same comment — nothing before this point requires
      // them to agree. review round 3, confirmed (P1): a record whose
      // payload names a different run_id than its own marker/index was
      // accepted, processed, and rendered/replayed under the WRONG
      // identity for its actual content.
      if (body.run_id !== runId) {
        throw new EvidenceError(`run-index ${runId} names comment ${named.id}, whose parsed payload declares run_id ${JSON.stringify(body.run_id)} — identity mismatch`);
      }
      // initiated_by lives in the MUTABLE record body, edited in place
      // throughout the run, and is not chain-protected — shepherd round 1,
      // Codex-confirmed (P1): a valid-looking in-place edit passes every
      // other check. The run-index payload carries its own copy, fixed
      // once at kickoff and never edited again, so cross-checking the
      // mutable body against it closes the gap the same way the run_id
      // check above does. initiated_by directly gates whether
      // computeIssueVerdict counts a human re-kick as an intervention — an
      // edit from human to foreman here would launder a real failure into
      // unattended success, the primary metric this tool exists to
      // compute.
      if (body.initiated_by !== indexPayload.initiated_by) {
        throw new EvidenceError(`run-index ${runId} names comment ${named.id}, whose parsed payload declares initiated_by ${JSON.stringify(body.initiated_by)} but the run-index recorded ${JSON.stringify(indexPayload.initiated_by)} — edited-entry tampering`);
      }
      // started_at is NEVER read from the body at all (see reconstructAsOf)
      // — shepherd round 2, Codex-confirmed (P1): round 1's cross-check
      // against the run-INDEX comment's created_at was too strict for a
      // legitimate writer. The index cannot be posted until the record's
      // own POST returns a comment id to name, so an index posted even
      // moments after the record — ordinary network latency, not
      // tampering — could cross a second boundary and fail exact
      // equality. recordComment.created_at (this SAME comment, GitHub-
      // assigned, available the instant it posts, no round-trip
      // dependency) is the authoritative kickoff time everywhere
      // instead; body.started_at becomes purely decorative payload text,
      // never trusted for cohort/staleness/display logic.
      results.push({
        status: "ok",
        runId,
        commentId: recordComment.id,
        recordCreatedAt: recordComment.created_at,
        authorActorId: named.author_actor_id,
        authorLogin: named.login,
        body,
        rawText: recordPayloadText,
      });
    } catch (err) {
      if (err instanceof EvidenceError) {
        // Prefer recordComment.created_at over indexEntry's — shepherd
        // round 3, Codex-confirmed (P2): the record is always posted
        // first (the index cannot name a comment id that doesn't exist
        // yet), so once the record's OWN identity is confirmed to exist,
        // its timestamp is the truer, earlier kickoff moment; the index's
        // is later by however long that round-trip took, and using it
        // instead could admit an issue whose real kickoff (the record's
        // own time) actually predates a --since window. Falls back to the
        // index's timestamp only when no record was ever identified (a
        // deleted-entry case has nothing else to anchor to). shepherd
        // round 2, Codex-confirmed (P2): firstKickoffEpoch only ever
        // looked at status:"ok" runs, so an issue whose EARLIEST run
        // turned out indeterminate reported kickoff:null, which the
        // --since filter's `kickoff !== null` guard reads as "always
        // inside the window" — inflating indeterminate_count for issues
        // that actually predate the requested window. Recording this
        // fallback whenever an identity was already confirmed closes that
        // gap without trusting anything the failed verification didn't
        // already establish.
        const kickoffCreatedAt = recordComment ? recordComment.created_at : indexEntry ? indexEntry.comment.created_at : null;
        results.push({ status: "indeterminate", runId, reason: err.message, kickoffCreatedAt });
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
function assembleListedEvidence(runRecord, allComments, withinCutoff, runRecordAuthorId) {
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
    // Self-consistency (the check above) is not trust: entry.author_actor_id
    // is itself just a claim the run record makes about who posted this
    // comment, so it must ALSO be the run's own already-validated author —
    // never merely equal to whatever the entry claims, and never any other
    // member of the broader configured trust set. ai/schemas/README.md
    // "Trust: actor ID, never a payload claim" is explicit that
    // evidence_comments[]'s author_actor_id "narrows the same root to the
    // SPECIFIC already-trusted actor" — an evidence comment authored by
    // anyone else is never trusted, run record or no. review round 2,
    // confirmed (P1): this narrowing (already applied to the
    // marker-scanning path via isTrustedFor) was never applied to this
    // list-driven path at all — the function did not even receive the run
    // record's own author id to check against.
    if (entry.author_actor_id !== runRecordAuthorId) {
      throw new EvidenceError(`evidence_comments[] entry for comment ${entry.id} names author ${entry.author_actor_id}, which is not this run's own trusted author ${runRecordAuthorId} — forged-author entry`);
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
    // currentMarker.dest is the comment's OWN claim; comment._fetchedFrom
    // is which API endpoint actually returned it — shepherd round 1,
    // Codex-confirmed (P2): checking the claim against the listed entry
    // alone let a PR-posted comment claim dest=issue (or vice versa) and
    // still pass, since nothing tied either side to physical reality.
    const markersAgree =
      currentMarker &&
      currentMarker.kind === "evidence" &&
      currentMarker.runId === runRecord.run_id &&
      currentMarker.runId === listed.run_id &&
      currentMarker.stage === listed.stage &&
      currentMarker.dest === listed.destination &&
      currentMarker.dest === comment._fetchedFrom &&
      currentMarker.round === listed.round &&
      currentMarker.seq === listed.sequence;
    if (!markersAgree) {
      throw new EvidenceError(`evidence_comments[] entry for comment ${entry.id} no longer matches its recorded marker, does not bind to run ${runRecord.run_id}, or claims a destination its comment was not actually fetched from (listed ${JSON.stringify(listed)}, current ${JSON.stringify(currentMarker)}, fetched from ${JSON.stringify(comment._fetchedFrom)}) — edited-entry tampering`);
    }
    // ai/schemas/README.md "Comment kinds": destination=pr is reserved for
    // the per-STAGE rollup (round=null); every per-round comment is
    // destination=issue. shepherd round 3, Codex-confirmed (P2): a
    // dest=pr entry with a non-null round passed every check above (self-
    // consistent, correctly fetched from the PR) yet is grammatically
    // illegal — renderTrajectory's own rounds filter (dest === "issue")
    // would then silently drop it from the trajectory entirely, an
    // incomplete result rather than a reported one.
    if (currentMarker.dest === "pr" && currentMarker.round !== null) {
      throw new EvidenceError(`evidence_comments[] entry for comment ${entry.id} claims destination=pr with a non-null round (${currentMarker.round}) — pr is reserved for stage rollups (round=null), never a per-round comment`);
    }
    const payloadText = fencedPayloadText(comment.body || "");
    if (payloadText === null) {
      throw new EvidenceError(`evidence_comments[] entry for comment ${entry.id} no longer carries a fenced payload — edited-entry tampering`);
    }
    verified.push({ marker: listed, entryDigest: entry.digest, comment, payloadText });
  }

  // Duplicate markers resolve by lowest comment id, unconditionally
  // (ai/schemas/README.md "Duplicate markers") — a resumed writer that
  // registered BOTH its original post and a retry under the identical
  // marker (same stage/destination/round/sequence) is a harmless
  // duplicate, not two segments. review round 3, confirmed (P1): this
  // list-driven path had no duplicate resolution at all (resolveCanonical
  // exists only for the marker-scanning path), so two verified entries
  // sharing every marker field including sequence reached the
  // sequence-gap check below as literal duplicate sequence numbers and
  // were misreported as a gap instead of resolved.
  const byFullMarkerKey = new Map();
  for (const v of verified) {
    const key = `${v.marker.stage} ${v.marker.destination} ${v.marker.round} ${v.marker.sequence}`;
    const existing = byFullMarkerKey.get(key);
    if (!existing || v.comment.id < existing.comment.id) byFullMarkerKey.set(key, v);
  }
  const deduped = [...byFullMarkerKey.values()];

  // Group by (stage, destination, round) — ignoring sequence, since a
  // split payload's segments share every marker field except that one
  // (ai/schemas/README.md "Segment reassembly"). Cutoff-filtered here,
  // AFTER every entry above was already verified unconditionally.
  const groups = new Map();
  for (const v of deduped) {
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
    // JSON.parse succeeds for any valid JSON VALUE, not only objects —
    // shepherd round 6, Codex-confirmed (P1): a digest- and marker-
    // authenticated round whose reassembled text is legitimately valid
    // JSON but not an object (bare `null`, a string, a number, an array)
    // parsed cleanly here and was retained as this round's payload; every
    // downstream reader (`--run`'s own rendering, --replay's
    // buildRunDirectory) unconditionally dereferences `round.payload.
    // passes`, so one such round threw an uncaught TypeError instead of
    // an EvidenceError — aborting the entire replay batch or --run
    // invocation over one run, rather than making only that run
    // indeterminate. Validate the shape every real consumer actually
    // requires immediately after parsing, at the one place this payload
    // is reassembled.
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
      throw new EvidenceError(`${key}: reassembled payload is valid JSON but not an object (got ${JSON.stringify(payload)}) — malformed round payload`);
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
function normalizeExactDuplicates(rawEntries, contentKeys) {
  const bySeq = new Map();
  for (const entry of rawEntries) {
    const list = bySeq.get(entry.seq) || [];
    list.push(entry);
    bySeq.set(entry.seq, list);
  }
  const normalized = [];
  for (const [seq, group] of bySeq) {
    const first = group[0];
    // Compare full canonical CONTENT (plus prev_digest AND digest itself),
    // never content alone — review round 3, confirmed (P1): an entry edited
    // after being appended, whose content no longer matches its own
    // (now-stale) digest, would still equal a genuine original sharing
    // that same stale digest, so the edited copy could be silently
    // discarded here — DISCARDED, before verifyChain's own per-entry
    // digest-vs-content check ever runs on it — hiding exactly the
    // tampering that check exists to catch. Comparing content directly
    // means an edited copy no longer equals the original at all, so it
    // falls through to the fork branch below instead. digest is ALSO
    // compared — shepherd round 1, Codex-confirmed (P2): two entries
    // sharing identical content+prev_digest but disagreeing on their own
    // digest field (one right, one corrupted) still equaled each other
    // under a content-only comparison, so the corrupted one could be
    // silently discarded as a "duplicate" instead of surfacing as the
    // tampering evidence it actually is.
    const canonicalOf = (e) => {
      const content = {};
      for (const k of contentKeys) content[k] = e[k];
      return canonicalJson({ content, prev_digest: e.prev_digest, digest: e.digest });
    };
    const firstKey = canonicalOf(first);
    const allIdentical = group.every((e) => canonicalOf(e) === firstKey);
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
  const deduped = normalizeExactDuplicates(rawEntries, contentKeys);
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

// #738 (open, unimplemented as of this writing): these three arrays are
// not yet schema-enforced to carry seq/digest/prev_digest at all — a
// genuinely schema-conformant record from today's shipped run.schema.json
// legitimately has NONE of them. shepherd round 1, Codex-confirmed (P1):
// requiring the chain fields unconditionally rejected every such record
// outright ("expected seq 0, got undefined"), including the schema's own
// committed valid fixtures — this file's entire test suite masked the gap
// because every fixture builds these arrays via the chain() helper, which
// always adds the fields.
const CHAINS_PENDING_SCHEMA = new Set(["stage_transitions", "interventions", "settlements"]);

// Validates all six append-only arrays in a run-record body. Throws
// EvidenceError on any broken chain — the record is not trusted past the
// break (evidence spec: "fail closed"). For the three CHAINS_PENDING_SCHEMA
// arrays specifically, an array whose entries ALL lack seq is treated as
// pre-#738 and passed through unprotected (natural array order, no digest
// check) rather than rejected — this is exactly what today's schema
// allows, no more. An array with SOME but not all entries carrying seq is
// a mixed, suspicious shape with no legitimate writer behind it (only an
// attempt to look chain-protected) and still fails closed via the normal
// path below.
function verifyRunRecordChains(body) {
  const result = {};
  for (const [arrayName, contentKeys] of Object.entries(CHAIN_FIELDS)) {
    const rawEntries = body[arrayName] || [];
    if (CHAINS_PENDING_SCHEMA.has(arrayName) && rawEntries.length > 0 && rawEntries.every((e) => e.seq === undefined)) {
      result[arrayName] = rawEntries;
      continue;
    }
    const outcome = verifyChain(rawEntries, contentKeys);
    if (!outcome.ok) {
      throw new EvidenceError(`run record ${arrayName} chain broken: ${outcome.reason}`);
    }
    // outcome_transitions[]'s own enum (ready-for-review/capped/escalated/
    // abandoned) is the FULL terminal set — every entry it could ever hold
    // is by definition a terminal outcome, so more than one entry means a
    // second terminal value was appended after the run already ended.
    // shepherd round 2, Codex-confirmed (P1, severe): a chain- and
    // digest-valid second entry (e.g. capped then ready-for-review) passed
    // every existing check and laundered a real failure into a success via
    // deriveProjections' own last-entry-wins rule — directly corrupting
    // the primary unattended-success metric. A retry after a terminal
    // outcome is a NEW run_id (the run-index/findRunRecord grouping
    // already treats it that way); it is never another entry on this
    // chain.
    if (arrayName === "outcome_transitions" && outcome.entries.length > 1) {
      throw new EvidenceError(`run record outcome_transitions has ${outcome.entries.length} entries — a run may reach only one terminal outcome, any retry is a new run_id`);
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
// then keep only entries at or before the cutoff. recordCreatedAt is the
// run-record COMMENT's own (GitHub-assigned) created_at, the authoritative
// kickoff time — never body.started_at, a mutable, unprotected payload
// field (see the caller, findRunRecord, for why round 1's cross-check
// against it was itself too strict and was replaced with this instead).
function reconstructAsOf(body, cutoffIso, recordCreatedAt) {
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
  // "Ready-for-review" is itself a PR state (AGENTS.md: "Ready-for-review
  // PR — non-draft"), so a promotion with no reconstructed PR binding is
  // just as inconsistent as one with no promotion at all — shepherd round
  // 5, Codex-confirmed (P2): this check previously required only
  // promotion, so a chain-consistent record claiming ready-for-review
  // with an empty pr_bindings[] (pr: null) passed here and reached
  // computePostReadyFix, which unconditionally reads
  // readyRun.state.pr.number — a TypeError that aborted the ENTIRE
  // --repo metric over one malformed record, not just that one run.
  if (outcome === "ready-for-review" && !pr) {
    throw new EvidenceError("run record outcome_transitions[] claims ready-for-review without a corresponding PR binding — inconsistent record");
  }
  return {
    run_id: body.run_id,
    initiated_by: body.initiated_by,
    started_at: recordCreatedAt,
    stage_transitions: filtered.stage_transitions,
    interventions: filtered.interventions,
    settlements: filtered.settlements,
    // Raw, cutoff-filtered — carried through so isStale can treat these as
    // activity too (an actively-updated run posting new round evidence
    // within one stage, with no NEW stage_transitions entry yet, is not
    // stale) — review round 2, confirmed (P1): lastActivity previously
    // could not see this at all, since it was never part of this return
    // value in the first place.
    evidence_registrations: filtered.evidence_registrations,
    pr_bindings: filtered.pr_bindings,
    outcome_transitions: filtered.outcome_transitions,
    pr,
    promotion,
    outcome,
  };
}

// ---------------------------------------------------------------------------
// Orphan and forged-marker detection (reporting only — neither is ever
// trusted or assembled; assembleListedEvidence above never accepts either
// regardless). Two DIFFERENT signals, previously conflated into one
// "untrusted_comments" field that actually only ever held the first kind
// — shepherd round 2, Codex-confirmed (P2), verified directly against
// ai/schemas/README.md's own "Trust: actor ID, never a payload claim":
// "A comment whose marker matches but whose author fails this check is a
// forged-author comment: reported, ignored" — this file previously just
// dropped forged markers silently instead.
//   - trusted orphan: a comment shaped like evidence for this run, posted
//     by an actor who could legitimately author it, but never added to
//     evidence_comments[] — a signal something may have failed to index
//     (a crash between posting and updating the list).
//   - forged marker: a comment shaped like evidence for this run, posted
//     by an actor who is NOT this run's trusted author — noise or an
//     attempted forgery, reported so it is visible, never treated as
//     evidence.
// ---------------------------------------------------------------------------

function findOrphanEvidence(comments, { runId, runRecordAuthorId, listedIds }) {
  const marked = markedComments(comments).filter((e) => e.marker.kind === "evidence" && e.marker.runId === runId);
  const trusted = [];
  const forged = [];
  for (const e of marked) {
    if (isTrustedFor(e.comment, { runRecordAuthorId })) {
      if (!listedIds.has(e.comment.id)) trusted.push(e);
    } else {
      forged.push(e);
    }
  }
  return { trusted, forged };
}

// ---------------------------------------------------------------------------
// Run directory reconstruction — the shape scripts/dev-flow-exit.mjs's
// loadRunDir() reads (run.json + passes/*.json + adjudications/*.json).
// receipts[] IS derived here from harvested evidence, entirely as an
// implementation detail of this harvester: dev-flow-exit.mjs already
// expects it (evanharmon1/harmon-devkit#727 tracks giving it a canonical
// durable schema of its own; this reconstruction does not wait on that).
// Chronology comes directly from ascending comment id order, which IS
// creation order on GitHub. slot_failures[] is NOT derived — always []
// below — shepherd round 1, Codex-confirmed (P1): a finder_unavailable or
// breadth_exhausted slot has no pass and is indistinguishable from a
// still-pending one without it, so a capped/finder-unavailable round can
// replay to the wrong exit. Left unimplemented here rather than guessed at:
// deriving the FAILURE REASON needs a settled writer-side evidence contract
// for what gets posted (if anything) for a failed slot, which does not
// exist yet (the writer, #638/#639, is itself unbuilt) — filed as a
// follow-up once that contract is settled, the same "blocked on a
// capability this file doesn't have" category as the registry-trust gap.
// --history is similarly never passed to dev-flow-exit.mjs, so
// provenance_share/repeat_after_fix convergence predicates cannot replay
// correctly either — same follow-up.
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
    const state = reconstructAsOf(record.body, asOf, record.recordCreatedAt);
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
    // Tagged with the API endpoint each comment actually came from —
    // shepherd round 1, Codex-confirmed (P2): assembleListedEvidence below
    // only checked the marker's OWN self-declared dest against the run
    // record's listed destination, never against which endpoint physically
    // returned the comment, so a comment posted on the PR could claim
    // dest=issue and pass every self-consistency check.
    const allComments = [
      ...issueComments.map((c) => ({ ...c, _fetchedFrom: "issue" })),
      ...allPrComments.map((c) => ({ ...c, _fetchedFrom: "pr" })),
    ];
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
    const rounds = assembleListedEvidence(record.body, allComments, withinCutoff, record.authorActorId);
    const listedIds = new Set((record.body.evidence_comments || []).map((e) => Number(e.id)));
    // Cutoff-filtered — shepherd round 4, Codex-confirmed (P2): unlike
    // assembleListedEvidence just above (which verifies every LIVE
    // evidence_comments[] entry unconditionally, by design — see its own
    // comment), orphan/forged detection is reporting-only, never a trust
    // decision (see this function's own block comment), so for a --run
    // --as-of C read it must reflect only what existed AS OF C — otherwise
    // a comment posted after C could appear in a supposedly historical
    // trajectory, and re-running the SAME --as-of C later (after more
    // comments land) could change its orphan/forged report even though
    // nothing about "as of C" should change.
    const { trusted: orphans, forged: forgedMarkers } = findOrphanEvidence(allComments.filter(withinCutoff), { runId: record.runId, runRecordAuthorId: record.authorActorId, listedIds });
    return {
      status: "ok",
      runId: record.runId,
      issueNumber,
      record,
      state,
      rounds,
      untrusted: orphans,
      forged: forgedMarkers,
    };
  } catch (err) {
    if (err instanceof EvidenceError) {
      // record itself was already fully authenticated by findRunRecord
      // (its author/identity checks passed) — only the LATER chain/
      // projection verification failed here, so record.recordCreatedAt
      // is still a genuine kickoff-time fallback. shepherd round 2,
      // Codex-confirmed (P2) — see findRunRecord's own kickoffCreatedAt
      // for the general reasoning; this is the same fallback, one level up.
      return { status: "indeterminate", runId: record.runId, issueNumber, reason: err.message, kickoffCreatedAt: record.recordCreatedAt };
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
    records = findRunRecord(issueComments.filter(withinCutoff), { trustedActorIds, repo });
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
      ? { status: "indeterminate", runId: record.runId, issueNumber, reason: record.reason, kickoffCreatedAt: record.kickoffCreatedAt }
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
  // Every timestamped run-record update counts as activity (specs/
  // dev-flow-v2.md § Success metric: "no run-record update for
  // [convergence].stale_after"), not just stage/intervention/settlement
  // entries — review round 2, confirmed (P1): a run posting new round
  // evidence for days within a single stage, with no fresh
  // stage_transitions entry, was previously terminalized as abandoned
  // regardless of that activity, since these three arrays were not in
  // the union at all.
  const allEntries = [
    ...state.stage_transitions, ...state.interventions, ...state.settlements,
    ...state.evidence_registrations, ...state.pr_bindings, ...state.outcome_transitions,
  ];
  const lastActivity = allEntries.reduce((max, e) => {
    const t = Date.parse(e.entered_at || e.at || e.settled_at || e.registered_at || e.bound_at);
    return t > max ? t : max;
  }, Date.parse(state.started_at));
  // >= , not > — shepherd round 4, Codex-confirmed (P2): specs/dev-flow-v2.md
  // defines staleness as "no run-record update for [convergence].stale_after"
  // (a duration REQUIREMENT, satisfied once that much time has elapsed with
  // no update), which is already true at exact equality; the strict `>`
  // this replaced left a run non-terminal for one extra millisecond at a
  // reproducible, exact --as-of boundary.
  return asOfEpoch - lastActivity >= staleAfterDays * 24 * 60 * 60 * 1000;
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

// Returns { fixed, indeterminate } rather than a bare boolean: this is
// explicitly a secondary, P2 signal (never the primary closed-cohort
// determination), so an unresolvable first_seen must not make the WHOLE
// run indeterminate the way a broken evidence chain does — it is reported
// as its own separate count instead (the same "report separately, never
// silently drop or silently count" shape this file already uses for
// asked/interventions), fail-closed only for THIS signal.
// first_seen design invariant, restated once here rather than patched per
// symptom (shepherd round 6): post-ready fix detection is explicitly a
// SECONDARY failure measure (specs/dev-flow-v2.md § Success metric), so
// (1) any signal this function cannot resolve — an API failure, an
// unresolvable commit visibility — must be ISOLATED to this one issue's
// own uncertainty bucket (post_ready_fix_indeterminate_count), never
// escape and take down the primary closed-cohort result or any other
// issue; and (2) once a qualifying fix IS confirmed for an issue, that
// issue-level boolean question is conclusively answered — a separate,
// still-unresolved commit cannot retroactively make it uncertain again.
function computePostReadyFix(repo, readyRun, cutoffEpoch) {
  const promotion = readyRun.state.promotion;
  if (!promotion) return { fixed: false, indeterminate: false };
  try {
    const commits = ghApiPaginated(`repos/${repo}/pulls/${readyRun.state.pr.number}/commits?per_page=100`);
    // Commit POSITION relative to promotion.head, not a self-reported
    // timestamp — challenge round 1, confirmed: a cherry-picked human fix
    // can carry an older timestamp than the promotion, and a rebase can
    // carry a newer one for a commit that predates it; only "does it come
    // after promotion.head in the PR's own commit sequence" answers the
    // actual question. A head that no longer appears (a force-push rewrote
    // it) has no sequence to measure against, so this reports no fix rather
    // than guessing — a known simplification for this P2 signal, not the
    // primary cohort determination.
    const headIndex = commits.findIndex((c) => c.sha === promotion.head);
    if (headIndex === -1) return { fixed: false, indeterminate: false };
    // The commits API is always live — fetching "now" and never checking
    // --as-of meant re-running the SAME historical cutoff could report a
    // DIFFERENT post_ready_fix_count as new commits landed later, violating
    // the closed immutable cohort requirement (the same window and cutoff
    // must always report the same share) — challenge round 3, confirmed.
    // Position still decides WHETHER a commit is a genuine post-promotion
    // fix (unaffected by rebases/cherry-picks); first_seen additionally
    // bounds WHICH of those were already visible as of the requested
    // cutoff — review round 4, confirmed (P1, twice-revised): committer/
    // author date is fully pusher-controlled and does not answer that,
    // and Commit.pushedDate (an earlier attempted fix) turned out to never
    // populate for this repo's commits at all.
    // Bot-authored commits (author.type === "Bot" — a GitHub App or Actions
    // identity, distinct from computeIssueVerdict's own initiated_by-based
    // human/Foreman distinction, which has no equivalent signal at the git
    // commit level) never count as a "post-ready HUMAN fix" — shepherd round
    // 1, Codex-confirmed (P2): every post-promotion commit counted
    // regardless of author, inflating a metric explicitly defined as human
    // fixes after readiness. Conservative on purpose: only a POSITIVELY
    // bot-identified commit is excluded; a human's git identity unlinked
    // from a GitHub account (author null/absent) is never false-excluded.
    const postPromotion = commits.slice(headIndex + 1).filter((c) => c.author?.type !== "Bot");
    let fixed = false;
    let anyUnresolved = false;
    for (const c of postPromotion) {
      const seen = firstSeen(repo, c.sha);
      if (seen === null) {
        anyUnresolved = true;
        continue;
      }
      if (Date.parse(seen) <= cutoffEpoch) fixed = true;
    }
    // shepherd round 6, Codex-confirmed (P2): a fixed commit and a
    // SEPARATE unresolved commit previously set both fixed and
    // indeterminate together, double-counting one issue in both output
    // buckets. Once any commit confirms the fix, the boolean is settled;
    // an unresolved OTHER commit reserves indeterminate for the case
    // nothing confirmed a fix AND something could not be ruled out.
    return { fixed, indeterminate: !fixed && anyUnresolved };
  } catch (err) {
    // shepherd round 6, Codex-confirmed (P1): a transient API, permission,
    // or rate-limit GhError from either request above previously escaped
    // this function entirely, aborting computeClosedCohortMetric — and so
    // the whole --repo invocation — over one issue's secondary signal.
    if (err instanceof GhError) return { fixed: false, indeterminate: true };
    throw err;
  }
}

// First kickoff = the earliest started_at among an issue's successfully
// harvested runs. An indeterminate run's started_at cannot be trusted the
// same way (its chain never passed verification), so it never EXCLUDES an
// issue from the window — only a verified "ok" run's timestamp can.
// shepherd round 2, Codex-confirmed (P2): only status:"ok" runs were ever
// considered, so an issue whose EARLIEST run turned out indeterminate
// (chain broken, deleted record, ...) reported kickoff:null — which the
// --since caller's `kickoff !== null` guard reads as "always inside the
// window", inflating indeterminate_count for issues that actually predate
// the window. kickoffCreatedAt (see findRunRecord/harvestOneRunRecord) is a
// genuine fallback whenever it survives an indeterminate result: it comes
// from the run's own trusted index/record identity, established before
// whatever LATER check failed — preferring the record's own created_at
// over the index's when both are available (shepherd round 3,
// Codex-confirmed: the record posts first, so its timestamp is always
// the truer, earlier kickoff moment).
function firstKickoffEpoch(issueRuns) {
  const started = issueRuns
    .map((r) => (r.status === "ok" ? r.state.started_at : r.kickoffCreatedAt))
    .filter((t) => t != null)
    .map((t) => Date.parse(t));
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
  let postReadyFixIndeterminateCount = 0;
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
    if (readyRun) {
      const { fixed, indeterminate } = computePostReadyFix(repo, readyRun, asOfEpoch);
      if (fixed) postReadyFixCount++;
      if (indeterminate) postReadyFixIndeterminateCount++;
    }
    perIssue.push({ issueNumber, closed: true, success: verdict.success, interventions: verdict.interventions, asked: verdict.asked });
  }
  return {
    cohort_size: closedCount,
    unattended_success_count: successCount,
    unattended_success_rate: closedCount > 0 ? successCount / closedCount : null,
    asked_count: askedTotal,
    post_ready_fix_count: postReadyFixCount,
    post_ready_fix_indeterminate_count: postReadyFixIndeterminateCount,
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
  // Chronological (by comment id — ascending id IS creation order on
  // GitHub, the same fact buildRunDirectory's own chronology already
  // relies on), never alphabetical by stage name — shepherd round 1,
  // Codex-confirmed (P2): a remediation loop re-entering an earlier stage
  // (e.g. review, then challenge again) rendered every challenge round
  // before every review round regardless of when each actually happened.
  const rounds = run.rounds
    .filter((r) => r.dest === "issue" && r.round !== null)
    .sort((a, b) => Math.min(...a.commentIds) - Math.min(...b.commentIds));
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
    // Renamed from the misleading untrusted_comments — shepherd round 2,
    // Codex-confirmed (P2): this field has only ever held TRUSTED-but-
    // unlisted orphans, never untrusted ones. forged_comments is the new,
    // genuinely-untrusted counterpart (ai/schemas/README.md: "a
    // forged-author comment: reported, ignored").
    orphan_comments: run.untrusted.map((u) => ({ id: u.comment.id, actor_id: u.actorId })),
    forged_comments: run.forged.map((f) => ({ id: f.comment.id, actor_id: f.actorId })),
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

function invokeExitScript(exitScriptPath, { runDir, stage, policyPath, currentHead, repoRoot }) {
  // --repo-root lets dev-flow-exit.mjs resolve real ancestry via
  // `git merge-base --is-ancestor` for any pass whose reviewed_head
  // differs from currentHead — without it, every such pass is marked
  // unknown-ancestry and dropped, so multi-round predicates (consecutive
  // rounds, rising counts, repeat-after-fix) are recomputed from only the
  // latest round. review round 3, confirmed (P1): this production path
  // supplied neither --heads nor --repo-root at all. --heads would need a
  // real commit-parent map this file has no way to build (no git graph
  // traversal exists anywhere here) — --repo-root alone is sufficient,
  // since dev-flow-exit.mjs's own ancestry check does a direct git query
  // and never requires the heads-map to be present.
  // Caller-overridable (default process.cwd()) — shepherd round 1,
  // Codex-confirmed (P1): hardcoding process.cwd() silently produced wrong
  // ancestry whenever --repo names a repository other than the current
  // checkout (or a checkout missing the retained remote commits). Fetching
  // a mismatched repo's history automatically is out of scope (this tool
  // is otherwise gh-api-only, no other local-git network dependency); the
  // flag gives the caller an explicit, correct escape hatch instead of a
  // silent wrong answer.
  const result = spawnSync(
    process.execPath,
    [exitScriptPath, "--run", runDir, "--stage", stage, "--policy", policyPath, "--current-head", currentHead, "--repo-root", repoRoot, "--json"],
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
// stage_transitions[].exit is documented, unconstrained free-form prose
// (run.schema.json has no format/pattern on it) — a human- or
// tool-written summary that may carry ANY trailing commentary after the
// machine-relevant leading word, not only the small set of separators
// (whitespace, colon) an earlier version of this split on. shepherd
// round 6, Codex-confirmed (P1): the committed valid fixture
// further-along.json already uses "converged, one deferred" — splitting
// on `[\s:]` alone keeps the comma, so "converged," never matches
// OUTCOME_ENUM and this returned null for a genuinely converged stage,
// reporting recorded=null vs a candidate policy's recomputed=converged
// as a false --replay policy difference. Matching the enum word at the
// START, followed by a word boundary, is correct for ANY trailing
// punctuation or prose — not a special case for one more separator
// character, the same class of fragile-parsing bug this file has
// hardened against elsewhere (recordedOutcome exists specifically
// because there is no machine-readable verdict FIELD to read instead;
// see this function's own callers).
const OUTCOME_TOKEN_RE = new RegExp(`^(${OUTCOME_ENUM.join("|")})\\b`);
function recordedOutcome(exitText) {
  if (!exitText) return null;
  const m = OUTCOME_TOKEN_RE.exec(exitText);
  return m ? m[1] : null;
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

// run.schema.json's run_id is `{type: "string", minLength: 1}` — no
// format/pattern restriction, so it may legitimately (per schema) contain
// path separators or ".." segments. shepherd round 1, Codex-confirmed
// (P1, severe): path.join(tmpRoot, run.runId) let a run_id like
// "../../somewhere" escape the mkdtempSync'd temp root entirely, after
// which buildRunDirectory's mkdirSync/writeFileSync calls create
// directories and overwrite fixed filenames (run.json, passes/*,
// adjudications/*) at that external location — this is the only place
// this otherwise read-only (gh-api-only) tool writes to the local
// filesystem at all.
//
// A resolve-and-check-prefix guard (round 1's first attempt) stops the
// escape but not collision: shepherd round 2, Codex-confirmed (P2) —
// distinct schema-valid ids like "a" and "a/." both normalize to the same
// joined path, and buildRunDirectory never clears a directory before
// writing into it, so a second run in the same --replay batch could
// silently inherit and be scored against the first run's files. Hashing
// the id into the directory name fixes both concerns in one step: a hex
// digest can never contain a path separator (containment) and collides
// only as often as SHA-256 does (uniqueness) — simpler than a
// resolve-and-check guard on the raw value.
function runReplayDir(base, runId) {
  return path.join(path.resolve(base), sha256(runId).slice(0, 16));
}

function replayOneRun(run, { policyPath, exitScriptPath, tmpRoot, repoRoot }) {
  const runDir = runReplayDir(tmpRoot, run.runId);
  buildRunDirectory(run.record.body, run.rounds, runDir);
  const diffs = [];
  // A stage that could not be recomputed at all (exec failure, or
  // dev-flow-exit.mjs's own outcome:"indeterminate") makes the WHOLE run's
  // replay result indeterminate, not merely one more diffs[] entry to
  // compare against a recorded exit — shepherd round 3, Codex-confirmed
  // (P1): round 2's fix pushed an error-shaped diffs[] entry for the
  // indeterminate case but never set indeterminate on the RETURNED
  // result, so cliReplay's own classification (results.filter(r =>
  // !r.indeterminate && r.diffs.length > 0)) still counted the run among
  // ordinary policy disagreements and reported zero indeterminate runs.
  // The pre-existing exec-failure branch had the exact same gap; both are
  // fixed together here rather than patching only the newer one.
  let indeterminateReason = null;
  for (const stage of ["challenge", "review"]) {
    // A stage is in scope for replay if it has round evidence OR a
    // recorded stage_transitions entry — shepherd round 5, Codex-confirmed
    // (P1): requiring round evidence ALONE skipped a stage resolved to cap
    // 0 (disabled), which has a valid "capped: disabled" stage_transitions
    // entry and legitimately zero round comments — even when the
    // CANDIDATE policy under replay would enable it (cap > 0), which
    // should recompute "continue" for that zero-round trajectory.
    // Skipping instead of comparing reported a false policy-equivalence:
    // no diff, when the candidate policy genuinely disagrees with what
    // was recorded. Round evidence alone (no stage_transitions entry) must
    // still qualify too — a stage_transitions entry is not guaranteed to
    // exist for every stage a real record's own tests exercise via round
    // evidence directly. recordedExitFor (below) already reads
    // stage_transitions directly and needs no round evidence either.
    const hasRounds = run.rounds.some((r) => r.stage === stage && r.dest === "issue" && r.round !== null);
    const wasVisited = hasRounds || run.state.stage_transitions.some((t) => t.stage === stage);
    if (!wasVisited) continue;
    const currentHead = currentHeadForStage(run, stage);
    const { verdict, error } = invokeExitScript(exitScriptPath, { runDir, stage, policyPath, currentHead, repoRoot });
    const recordedText = recordedExitFor(run.state, stage);
    const recorded = recordedOutcome(recordedText);
    if (error) {
      diffs.push({ stage, recorded: recordedText, recomputed: null, error });
      indeterminateReason = indeterminateReason || `${stage}: ${error}`;
      continue;
    }
    // dev-flow-exit.mjs deliberately emits outcome:"indeterminate" (exit
    // 2) when it cannot verify a reconstructed trajectory — shepherd
    // round 2, Codex-confirmed (P1): this was never distinguished from an
    // ordinary recomputed outcome, so an indeterminate verdict was
    // compared against the recorded exit like any other and reported as
    // a POLICY DISAGREEMENT, when the actual failure mode is "could not
    // verify at all", unrelated to the candidate policy under test.
    if (verdict.outcome === "indeterminate") {
      const reason = `exit script could not verify this trajectory: ${verdict.reason || "indeterminate"}`;
      diffs.push({ stage, recorded: recordedText, recomputed: null, error: reason });
      indeterminateReason = indeterminateReason || `${stage}: ${reason}`;
      continue;
    }
    if (verdict.outcome !== recorded) {
      diffs.push({ stage, recorded: recordedText, recomputed: verdict.outcome, reason: verdict.reason });
    }
  }
  if (indeterminateReason !== null) {
    return { runId: run.runId, issue: run.issueNumber, diffs, indeterminate: true, reason: indeterminateReason };
  }
  return { runId: run.runId, issue: run.issueNumber, diffs };
}

function replayAll(runs, { policyPath, exitScriptPath, repoRoot }) {
  const tmpRoot = mkdtempSync(path.join(tmpdir(), "dev-flow-stats-replay-"));
  try {
    return runs.map((run) => {
      if (run.status === "indeterminate") {
        return { runId: run.runId, issue: run.issueNumber, diffs: [], indeterminate: true, reason: run.reason };
      }
      // One run's own EvidenceError (e.g. an indeterminate exit-script
      // result) must not abort the whole batch — the same per-run
      // isolation this file applies everywhere else (harvestOneRunRecord,
      // findRunRecord's per-run_id grouping).
      try {
        return replayOneRun(run, { policyPath, exitScriptPath: exitScriptPath || DEFAULT_EXIT_SCRIPT, tmpRoot, repoRoot: repoRoot || process.cwd() });
      } catch (err) {
        if (err instanceof EvidenceError) {
          return { runId: run.runId, issue: run.issueNumber, diffs: [], indeterminate: true, reason: err.message };
        }
        throw err;
      }
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
  firstSeen,
  resolveRegistryTrustedActorIds,
};

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

// shepherd round 2, Codex-confirmed (P2): every --key was accepted and
// stored regardless of whether anything ever reads it, so a typo (--asof
// instead of --as-of) silently no-opped — the mistyped flag's own check
// (requiredArgValue et al.) never runs because nothing asks for
// args["asof"], and the command exits 0 with live data mislabeled as the
// requested historical cutoff. Especially hazardous for reproducibility:
// the output stays plausible, nothing signals the mistake.
const KNOWN_FLAGS = new Set([
  "as-of", "config", "exit-script", "json", "policy", "replay", "repo",
  "repo-root", "run", "since", "stale-after-days", "trusted-actor-id",
  "trusted-actors-file",
]);

function parseArgs(argv) {
  const args = { "trusted-actor-id": [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    if (!KNOWN_FLAGS.has(key)) {
      console.error(`dev-flow-stats: unrecognized option --${key}`);
      return null;
    }
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
    // JSON values are already typed — shepherd round 6, Codex-confirmed
    // (P2): coercing every entry with Number() (originally added for
    // --trusted-actor-id's own CLI strings, always strings from argv)
    // also silently coerced a boolean/string/null/object entry from this
    // FILE, e.g. Number(true) === 1, converting a malformed
    // security-sensitive config entry into a real, trusted actor id
    // instead of rejecting it. File entries are validated by their OWN
    // declared type; only command-line strings are ever coerced.
    if (!doc.trusted_actor_ids.every((v) => typeof v === "number")) {
      console.error('dev-flow-stats: --trusted-actors-file "trusted_actor_ids" entries must be JSON numbers — a boolean, string, null, or object is never silently converted to an actor id');
      return null;
    }
    fromFile = doc.trusted_actor_ids;
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
// parseArgs stores `true` (not a string) for a value-taking flag with no
// following value (e.g. `--as-of --json` or `--as-of` at the end of argv)
// — review round 2, confirmed (P2): callers were narrowing that case with
// `typeof x === "string" ? x : null`, which reads `true` exactly like
// "flag omitted" and silently falls back to the default instead of
// reporting a usage error, despite the CLI documenting these as
// value-required options.
function requiredArgValue(flagName, rawValue) {
  if (rawValue === undefined) return { ok: true, value: null };
  if (rawValue === true) {
    return { ok: false, error: `dev-flow-stats: --${flagName} requires a value` };
  }
  return { ok: true, value: rawValue };
}

// Same grammar as run.schema.json's own timestamp fields (UTC "Z" form
// only, no other offset spelling) — shepherd round 3, Codex-confirmed
// (P2): Date.parse() alone accepts values that are not the documented
// ISO-8601 form at all (a bare "0", a US-style "09/03/2026") and, worse,
// a timezone-less "2026-09-03T12:00:00" parses as LOCAL time — an
// environment-dependent cutoff for a tool whose whole point is
// reproducible historical scoping. Reject anything that doesn't match
// the grammar before ever calling Date.parse on it.
const ISO_TIMESTAMP_RE = /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?Z$/;

// The regex above only proves DIGIT SHAPE, not calendar validity —
// shepherd round 4, Codex-confirmed (P2): Date.parse("2026-02-30T00:00:00Z")
// (calendar-invalid: February has no 30th) does not return NaN, it
// silently NORMALIZES to 2026-03-02T00:00:00.000Z, so the regex-only check
// let a mistyped cutoff silently scope a historical query to a different
// day than the one requested. A round-trip string comparison against
// toISOString() cannot detect this either without ALSO rejecting every
// ordinary caller that omits fractional seconds (toISOString() always
// emits exactly ".000", so "...T12:00:00Z" round-trips to
// "...T12:00:00.000Z" — a real, common, valid input that never string-
// matches its own round trip). Comparing each captured calendar component
// against the PARSED date's own UTC getters sidesteps both problems: it
// rejects an out-of-range date (JS Date arithmetic "fixes" it into a
// different one instead of failing) while still accepting any valid
// fractional-seconds spelling.
function isCalendarValid(match, epoch) {
  const d = new Date(epoch);
  return (
    d.getUTCFullYear() === Number(match[1]) &&
    d.getUTCMonth() + 1 === Number(match[2]) &&
    d.getUTCDate() === Number(match[3]) &&
    d.getUTCHours() === Number(match[4]) &&
    d.getUTCMinutes() === Number(match[5]) &&
    d.getUTCSeconds() === Number(match[6])
  );
}

function parseIsoDateArg(flagName, value) {
  if (value === null) return { ok: true, value: null };
  const match = ISO_TIMESTAMP_RE.exec(value);
  const epoch = match ? Date.parse(value) : NaN;
  if (!match || Number.isNaN(epoch) || !isCalendarValid(match, epoch)) {
    return { ok: false, error: `dev-flow-stats: --${flagName} is not a valid ISO-8601 timestamp: ${JSON.stringify(value)}` };
  }
  return { ok: true, value };
}

function cliMetrics(args) {
  const trustedActorIds = requireTrustedActorIds(args);
  if (!trustedActorIds) return 2;
  const asOfRequired = requiredArgValue("as-of", args["as-of"]);
  if (!asOfRequired.ok) {
    console.error(asOfRequired.error);
    return 2;
  }
  const asOfArg = parseIsoDateArg("as-of", asOfRequired.value);
  if (!asOfArg.ok) {
    console.error(asOfArg.error);
    return 2;
  }
  const sinceRequired = requiredArgValue("since", args.since);
  if (!sinceRequired.ok) {
    console.error(sinceRequired.error);
    return 2;
  }
  const sinceArg = parseIsoDateArg("since", sinceRequired.value);
  if (!sinceArg.ok) {
    console.error(sinceArg.error);
    return 2;
  }
  const asOf = asOfArg.value;
  const since = sinceArg.value;
  let staleAfterDays = DEFAULT_STALE_AFTER_DAYS;
  const staleRequired = requiredArgValue("stale-after-days", args["stale-after-days"]);
  if (!staleRequired.ok) {
    console.error(staleRequired.error);
    return 2;
  }
  if (staleRequired.value !== null) {
    staleAfterDays = Number(staleRequired.value);
    if (!Number.isFinite(staleAfterDays) || staleAfterDays <= 0) {
      console.error(`dev-flow-stats: --stale-after-days must be a positive number, got ${JSON.stringify(staleRequired.value)}`);
      return 2;
    }
  }

  // Freeze one observation instant before discovery starts, rather than
  // letting each issue's own gh api call implicitly use whatever GitHub
  // returns at ITS OWN moment (no --as-of means cutoffEpoch=Infinity per
  // issue — nothing filtered, so each issue sees "now" as of when its own
  // request happened) while computeClosedCohortMetric separately computes
  // Date.now() only after the full scan finishes — shepherd round 5,
  // Codex-confirmed (P2): a --repo scan spans real wall-clock time across
  // many issues, so evidence landing mid-scan could be visible to an
  // early-scanned issue's own request but excluded from the LATER "now"
  // computeClosedCohortMetric uses for staleness, or vice versa — the
  // cohort would then depend on scan order/timing rather than one
  // observation instant, the same reproducibility guarantee an EXPLICIT
  // --as-of already provides. An explicit --as-of is untouched; this only
  // fills in the otherwise-implicit default, once, before either call.
  const effectiveAsOf = asOf ?? new Date().toISOString();
  let runs;
  try {
    runs = discoverAllRuns(args.repo, { trustedActorIds, asOf: effectiveAsOf });
  } catch (err) {
    console.error(`dev-flow-stats: ${err.message}`);
    return err instanceof EvidenceError ? 3 : 2;
  }
  const metric = computeClosedCohortMetric(args.repo, groupRunsByIssue(runs), { staleAfterDays, asOf: effectiveAsOf, since });

  if (args.json) {
    console.log(JSON.stringify(metric, null, 2));
  } else {
    const pct = metric.unattended_success_rate === null ? "n/a" : `${(metric.unattended_success_rate * 100).toFixed(1)}%`;
    console.log(`unattended-success: ${metric.unattended_success_count}/${metric.cohort_size} (${pct})`);
    console.log(`asked: ${metric.asked_count}`);
    console.log(`post-ready human fixes: ${metric.post_ready_fix_count}`);
    // shepherd round 3, Codex-confirmed (P2): computeClosedCohortMetric
    // explicitly preserves post-ready-fix uncertainty as its own count
    // (a commit whose first_seen could not be resolved), but the
    // human-readable form printed only the confirmed count — a reader
    // saw "post-ready human fixes: 0" with no hint that some commits
    // could not be determined at all.
    if (metric.post_ready_fix_indeterminate_count > 0) console.log(`post-ready human fixes indeterminate (could not resolve commit visibility): ${metric.post_ready_fix_indeterminate_count}`);
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
  const asOfRequired = requiredArgValue("as-of", args["as-of"]);
  if (!asOfRequired.ok) {
    console.error(asOfRequired.error);
    return 2;
  }
  const asOfArg = parseIsoDateArg("as-of", asOfRequired.value);
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
  // Defaults to process.cwd() (unchanged behavior) — only needed when
  // --repo names a repository other than the current checkout, or a
  // checkout missing the retained remote commits. See invokeExitScript.
  const repoRoot = args["repo-root"] || process.cwd();
  if (typeof repoRoot !== "string" || !existsSync(repoRoot)) {
    console.error(`dev-flow-stats: --repo-root path does not exist: ${repoRoot}`);
    return 2;
  }

  let runs;
  try {
    runs = discoverAllRuns(args.repo, { trustedActorIds, asOf: null });
  } catch (err) {
    console.error(`dev-flow-stats: ${err.message}`);
    return err instanceof EvidenceError ? 3 : 2;
  }
  const results = replayAll(runs, { policyPath, exitScriptPath, repoRoot });
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
