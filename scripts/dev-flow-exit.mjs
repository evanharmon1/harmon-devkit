#!/usr/bin/env node
// scripts/dev-flow-exit.mjs — deterministic confidence-stage exit computation.
//
// Implements openspec/changes/dev-flow-v2/specs/exit-computation/spec.md and
// specs/dev-flow-v2.md § "Convergence model v0" over a run directory (see
// ai/schemas/README.md "Dev flow v2 exit computation: run directory layout"
// for the exact shape) plus a resolved .devflow.toml policy
// (scripts/devflow-policy.mjs).
//
// CLI:
//   node scripts/dev-flow-exit.mjs --run <dir> --stage <challenge|review> \
//     --policy <file> [--rigor <level>] [--merge-base-policy <file>] \
//     [--current-head <sha>] [--history <file> | --repo-root <dir>] \
//     [--heads <file>] [--closure <dir>] [--validator <path>] [--json]
//
// No --registry / --merge-base-registry / --task-targets here on purpose:
// exit computation reads the RESOLVED policy shape (rounds, convergence,
// stages), which never depends on registry/Taskfile cross-validation to be
// structurally complete — that check belongs entirely to `devflow-policy.mjs
// resolve`, run once, before a caller ever invokes this script (see
// ai/schemas/README.md).
//
// Exit codes: 0 continue, 20 converged, 21 diverging, 22 capped,
// 2 indeterminate, 1 usage/parse error.

import { readFileSync, readdirSync, existsSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { parseToml, TomlError } from "./lib/toml-lite.mjs";
import { resolvePolicy, PolicyError } from "./devflow-policy.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_VALIDATOR = path.join(HERE, "validate-result-schemas.mjs");

const EXIT_CODES = { continue: 0, converged: 20, diverging: 21, capped: 22, indeterminate: 2 };

// Interim: result.challenger.schema.json does not exist yet (lands with
// lane #635). Until then, challenge-stage passes are authored with envelope
// role: "reviewer" (the shared finding core the two payloads carry) and
// validated as such — see ai/schemas/README.md's addendum for this issue.
const PASS_VALIDATION_KIND = "reviewer";

class ExitIndeterminate extends Error {}

// ---------------------------------------------------------------------------
// Run directory loading
// ---------------------------------------------------------------------------

function loadJson(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

function loadRunDir(dir) {
  const runRecordPath = path.join(dir, "run.json");
  if (!existsSync(runRecordPath)) throw new ExitIndeterminate(`run directory ${dir} has no run.json`);
  const runRecord = loadJson(runRecordPath);

  const passesDir = path.join(dir, "passes");
  const passes = existsSync(passesDir)
    ? readdirSync(passesDir)
      .filter((f) => f.endsWith(".json"))
      .map((f) => ({ name: f.replace(/\.json$/, ""), file: path.join(passesDir, f), envelope: loadJson(path.join(passesDir, f)) }))
    : [];

  const adjDir = path.join(dir, "adjudications");
  const adjudications = existsSync(adjDir)
    ? readdirSync(adjDir)
      .filter((f) => f.endsWith(".json"))
      .map((f) => ({ name: f.replace(/\.json$/, ""), file: path.join(adjDir, f), doc: loadJson(path.join(adjDir, f)) }))
    : [];

  return { runRecord, passes, adjudications };
}

// ---------------------------------------------------------------------------
// validate-result-schemas.mjs delegation
// ---------------------------------------------------------------------------

function runValidator(validatorPath, args) {
  const result = spawnSync(process.execPath, [validatorPath, ...args], { encoding: "utf8" });
  return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

function validatePassSchema(validatorPath, passFile, { runId, initiatedBy, knownIdsFile }) {
  const args = [PASS_VALIDATION_KIND, passFile];
  if (runId) args.push("--run-id", runId, "--initiated-by", initiatedBy);
  if (knownIdsFile) args.push("--known-ids", knownIdsFile);
  const { status, stdout, stderr } = runValidator(validatorPath, args);
  return { ok: status === 0, message: (stdout + stderr).trim() };
}

// passFiles binds the adjudication to the pass(es) it actually adjudicates
// (one per configured finder for its own stage/round) via the validator's
// own --pass cross-check, which proves — among other things — that the
// adjudication's run_id agrees with the (already run-id-verified) pass, so
// a stale adjudication document from a DIFFERENT run cannot supply a
// downgraded priority or disposition for a finding id that happens to
// collide. See ai/schemas/README.md "Adjudication ↔ source pass agreement".
function validateAdjudicationSchema(validatorPath, adjFile, passFiles) {
  const args = ["adjudication", adjFile];
  for (const p of passFiles) args.push("--pass", p);
  const { status, stdout, stderr } = runValidator(validatorPath, args);
  return { ok: status === 0, message: (stdout + stderr).trim() };
}

// ---------------------------------------------------------------------------
// Receipt validation: run binding, chronology, finding-id uniqueness
// ---------------------------------------------------------------------------

function validateReceipts(runRecord, passes, { validatorPath, tmpDir }) {
  // A run record with no trusted identity of its own cannot bind anything
  // to it — every pass's run/initiated_by check below would otherwise
  // silently short-circuit to "nothing to compare against, so accept",
  // which is exactly the untrusted-identity gap this check exists to close.
  if (typeof runRecord.run_id !== "string" || !runRecord.run_id) {
    throw new ExitIndeterminate("run.json has no run_id — cannot bind any pass to an active run identity");
  }
  if (typeof runRecord.initiated_by !== "string" || !runRecord.initiated_by) {
    throw new ExitIndeterminate("run.json has no initiated_by — cannot bind any pass to an active run identity");
  }
  const diagnostics = [];
  const receipts = Array.isArray(runRecord.receipts) ? runRecord.receipts : [];
  const passSeqByName = new Map();
  receipts.forEach((r, idx) => {
    if (r.kind === "pass") passSeqByName.set(r.file, idx);
  });
  // All transitions in receipt order, regardless of stage — used below to
  // find whichever stage was ACTIVE immediately before a given pass arrived
  // (not merely "some transition into this pass's stage happened earlier",
  // which a stale pass arriving after the run moved on to a later stage
  // would also satisfy).
  const transitionsInOrder = receipts
    .map((r, idx) => ({ ...r, seq: idx }))
    .filter((r) => r.kind === "transition");

  // Full lifecycle-edge legality (which stage-to-stage transitions are ever
  // structurally legal — matching run.schema.json's own ALLOWED_EDGES) is
  // deliberately NOT implemented here: this repo's own stage-regression
  // valve (AGENTS.md) makes review -> challenge a LEGITIMATE re-entry, so a
  // naive "no backward transition" rule would reject real trajectories, and
  // getting the full graph right needs docs/product/domain.md's exact
  // edges — out of scope for this pass; deferred as a P2 (see the PR's
  // deferred findings). What IS caught here, cheaply and unambiguously
  // regardless of which edges are legal: two transitions into the exact
  // same stage with nothing between them is never meaningful (there is
  // nothing a repeated "we are now in stage X" transition could legitimately
  // record that the first one did not already).
  for (let i = 1; i < transitionsInOrder.length; i++) {
    if (transitionsInOrder[i].stage === transitionsInOrder[i - 1].stage) {
      throw new ExitIndeterminate(
        `run.json receipts contain two consecutive transitions into stage "${transitionsInOrder[i].stage}" (seq ${transitionsInOrder[i - 1].seq}, ${transitionsInOrder[i].seq}) with no transition between them`,
      );
    }
  }

  function activeStageBefore(seq) {
    let active = null;
    for (const t of transitionsInOrder) {
      if (t.seq >= seq) break;
      active = t.stage;
    }
    return active;
  }

  const decorated = [];
  const seenIds = new Set();
  const knownIdsFile = tmpDir ? path.join(tmpDir, "known-ids.json") : null;

  // Process in trusted receipt order (passes without a receipt entry sort
  // last, in file-listing order, and are flagged).
  const ordered = [...passes].sort((a, b) => {
    const sa = passSeqByName.has(a.name) ? passSeqByName.get(a.name) : Infinity;
    const sb = passSeqByName.has(b.name) ? passSeqByName.get(b.name) : Infinity;
    return sa - sb;
  });

  for (const pass of ordered) {
    const env = pass.envelope;
    const payload = env.payload || {};
    const seq = passSeqByName.has(pass.name) ? passSeqByName.get(pass.name) : null;

    if (seq === null) {
      diagnostics.push({ pass: pass.name, level: "reject", reason: "no receipt entry for this pass in run.receipts" });
      continue;
    }
    if (runRecord.run_id && env.run && env.run.run_id !== runRecord.run_id) {
      diagnostics.push({ pass: pass.name, level: "reject", reason: `run_id "${env.run.run_id}" does not match the active run "${runRecord.run_id}"` });
      continue;
    }
    if (runRecord.initiated_by && env.run && env.run.initiated_by !== runRecord.initiated_by) {
      diagnostics.push({ pass: pass.name, level: "reject", reason: `initiated_by "${env.run.initiated_by}" does not match the active run "${runRecord.initiated_by}"` });
      continue;
    }
    // The pass's own stage must be whichever stage was ACTIVE immediately
    // before it arrived — not merely "entered at some earlier point" — so a
    // stale pass received after the run has already moved on to a later
    // stage is rejected rather than silently counted (exit-computation spec
    // "Results are validated before interpretation": "a pass from an
    // earlier stage SHALL NOT count in a later stage even when both name
    // the same head").
    const active = activeStageBefore(seq);
    if (active !== payload.stage) {
      diagnostics.push({
        pass: pass.name,
        level: "reject",
        reason: `stage "${payload.stage}" was not the active stage when this pass arrived (seq ${seq}; active stage was ${active ? `"${active}"` : "none"})`,
      });
      continue;
    }

    if (knownIdsFile) {
      writeFileSync(knownIdsFile, JSON.stringify([...seenIds]));
    }
    const { ok, message } = validatePassSchema(validatorPath, pass.file, {
      runId: runRecord.run_id,
      initiatedBy: runRecord.initiated_by,
      knownIdsFile,
    });
    if (!ok) {
      diagnostics.push({ pass: pass.name, level: "reject", reason: `schema/receipt validation failed: ${message}` });
      continue;
    }

    // A duplicate rejects the WHOLE pass, not just the colliding finding —
    // "receipt validation rejects the result and it contributes no pass or
    // finding" (specs/dev-flow-v2.md § Results). The schema validator's
    // --known-ids check above already catches this in practice (its
    // rejection reason differs and is what fixtures assert on); this loop
    // is defense in depth, never the only thing standing between a
    // duplicate id and being trusted.
    const duplicateIds = (payload.findings || []).filter((f) => seenIds.has(f.id)).map((f) => f.id);
    if (duplicateIds.length > 0) {
      diagnostics.push({
        pass: pass.name,
        level: "reject",
        reason: `duplicate finding id(s) already seen in this run: ${duplicateIds.join(", ")}`,
      });
      continue;
    }
    for (const f of payload.findings || []) seenIds.add(f.id);

    decorated.push({ ...pass, payload, receiptSeq: seq });
  }

  return { validPasses: decorated, diagnostics };
}

// ---------------------------------------------------------------------------
// Logical round assembly
// ---------------------------------------------------------------------------

function assembleLogicalRounds(stage, validPasses, adjudications, resolvedStage, runRecord) {
  const stagePasses = validPasses.filter((p) => p.payload.stage === stage);
  const adjByRound = new Map();
  for (const a of adjudications) {
    if (a.doc.stage === stage) adjByRound.set(a.doc.round, a.doc);
  }
  const slotFailures = Array.isArray(runRecord.slot_failures)
    ? runRecord.slot_failures.filter((s) => s.stage === stage)
    : [];

  const roundNumbers = new Set(stagePasses.map((p) => p.payload.round));
  for (const sf of slotFailures) roundNumbers.add(sf.round);
  const sorted = [...roundNumbers].sort((a, b) => a - b);

  // An empty resolvedStage.finders[] means no [stage.*] configuration
  // authority is available at all (the built-in default a merge-base
  // historical decode uses — devflow-policy.mjs, [stage.*] has no
  // legacy/v1 equivalent) rather than "this stage legitimately configures
  // zero primary finders." Falling back to trivial per-round completeness
  // in that case would silently mark every round complete regardless of
  // what actually ran, so instead the expected slot set is derived from
  // internal consistency: whichever slots the run's own passes actually
  // used, unioned across every round of this stage.
  let primarySlots = resolvedStage.finders;
  if (primarySlots.length === 0) {
    const observed = new Set();
    for (const p of stagePasses) observed.add(p.payload.slot || p.payload.finder);
    primarySlots = [...observed];
  }
  const rounds = [];

  for (const roundNumber of sorted) {
    const passesThisRound = stagePasses.filter((p) => p.payload.round === roundNumber);
    // A pass's claimed slot/substitutes_for is producer-asserted data, not
    // an authority — validate every invariant the spec requires before a
    // pass is allowed to fill a slot at all: a primary pass has finder ==
    // slot and no substitutes_for; a fallback pass's substitutes_for must
    // equal the slot it claims; the claimed slot must be one this stage
    // actually configures; at most one pass may claim a given slot per
    // round; and one finder cannot fill two slots in the same round.
    // Anything that fails these is dropped from bySlot (never silently
    // overwritten or trusted), which naturally falls through to
    // finder_unavailable/breadth_exhausted handling below exactly as if no
    // pass had arrived for that slot.
    // Pass 1: group every STRUCTURALLY valid claim by the slot it names
    // (finder == slot for a primary, substitutes_for == slot and
    // finder != slot for a fallback, and the slot must actually be
    // configured). A slot with more than one valid claim is exactly as
    // untrusted as one with zero — resolving the conflict by picking
    // whichever pass happened to be enumerated first would let a
    // duplicate claim silently win, so BOTH are dropped in pass 2 below.
    const validClaimsBySlot = new Map();
    for (const p of passesThisRound) {
      const slot = p.payload.slot || p.payload.finder;
      const finder = p.payload.finder;
      const isPrimaryClaim = !p.payload.substitutes_for;
      const validPrimary = isPrimaryClaim && finder === slot;
      const validFallback = !isPrimaryClaim && p.payload.substitutes_for === slot && finder !== slot;
      if (!primarySlots.includes(slot) || !(validPrimary || validFallback)) continue;
      const list = validClaimsBySlot.get(slot) || [];
      list.push(p);
      validClaimsBySlot.set(slot, list);
    }
    // Pass 2: a slot is filled only by a claim that is the SOLE valid claim
    // for that slot AND whose finder is not already filling another slot
    // this round (spec: "an actor already serving as a primary or
    // substitute in the round cannot satisfy a second slot"). Iterated in
    // primarySlots' own (configuration) order so a finder-reuse conflict
    // resolves deterministically rather than depending on pass enumeration
    // order.
    const bySlot = new Map();
    const claimedByFinder = new Set();
    for (const slot of primarySlots) {
      const claims = validClaimsBySlot.get(slot) || [];
      if (claims.length !== 1) continue; // zero or duplicate claims: slot unresolved either way
      const p = claims[0];
      if (claimedByFinder.has(p.payload.finder)) continue;
      bySlot.set(slot, p);
      claimedByFinder.add(p.payload.finder);
    }

    const substitutions = [];
    let unresolvedSlot = null;
    let unresolvedReason = null;
    for (const slot of primarySlots) {
      if (bySlot.has(slot)) {
        const p = bySlot.get(slot);
        if (p.payload.substitutes_for) {
          substitutions.push({ slot, ran: p.payload.finder, round: roundNumber });
        }
        continue;
      }
      const failure = slotFailures.find((s) => s.round === roundNumber && s.slot === slot);
      if (failure) {
        unresolvedSlot = slot;
        unresolvedReason = failure.reason === "breadth_exhausted" ? "breadth_exhausted" : "finder_unavailable";
      } else {
        unresolvedSlot = slot;
        unresolvedReason = "finder_unavailable";
      }
      break;
    }

    // Evidence (reviewedHead, findings) is drawn ONLY from the ACCEPTED
    // (bySlot) passes — a pass a slot claim rejected above (invalid slot,
    // duplicate claim, reused finder) contributes no pass or finding, per
    // "receipt validation rejects the result and it contributes no pass or
    // finding" (specs/dev-flow-v2.md § Results). Using passesThisRound
    // (every pass that merely NAMED this round, regardless of whether its
    // slot claim survived) here would let a rejected pass still inject
    // findings or invalidate an otherwise-clean shared head.
    const acceptedPasses = [...bySlot.values()];
    const reviewedHeads = new Set(acceptedPasses.map((p) => p.envelope.head));
    let reviewedHead = reviewedHeads.size === 1 ? [...reviewedHeads][0] : null;
    if (!reviewedHead && unresolvedSlot) {
      const failure = slotFailures.find((s) => s.round === roundNumber && s.slot === unresolvedSlot);
      if (failure && failure.head) reviewedHead = failure.head;
    }

    const adjudication = adjByRound.get(roundNumber) || null;
    const findings = [];
    for (const p of acceptedPasses) {
      for (const f of p.payload.findings || []) {
        const entry = adjudication ? adjudication.adjudications.find((a) => a.finding_id === f.id) : null;
        findings.push({
          ...f,
          round: roundNumber,
          stage,
          finder: p.payload.finder,
          reviewedHead: p.envelope.head,
          adjudicated_priority: entry ? entry.adjudicated_priority : null,
          disposition: entry ? entry.disposition : null,
        });
      }
    }

    rounds.push({
      round: roundNumber,
      reviewedHead,
      status: unresolvedSlot ? `capped/${unresolvedReason}` : "complete",
      unresolvedSlot,
      substitutions,
      findings,
    });
  }

  return rounds;
}

// ---------------------------------------------------------------------------
// Change ledger (provenance/fingerprint evidence) — see ai/schemas/README.md.
// ---------------------------------------------------------------------------

// Returns `null` (not `[]`) when no real change-ledger source is available —
// deliberately distinct from a real, legitimately EMPTY ledger (e.g. every
// fixture whose rounds simply haven't touched much yet). `null` means
// "nothing here can verify anything"; `[]` means "verified against real
// evidence, which happens to record no matching entries" — verifyProvenance/
// verifyFingerprint treat the two very differently: an empty-but-real ledger
// can legitimately confirm `original` provenance (no tracked fix touched
// this line), while an UNAVAILABLE ledger must never be silently treated as
// confirming evidence, since that would let every finding evade verification
// just by asserting the claim a missing ledger cannot contradict.
function loadLedger({ historyFile, repoRoot }) {
  if (historyFile) return loadJson(historyFile);
  if (repoRoot) return null; // git adapter deliberately not implemented yet — see ai/schemas/README.md / "## Deferred findings".
  return [];
}

function resolveOriginPath(pathName, beforeRound, ledger) {
  if (!ledger) return pathName; // no ledger available: no rename can be tracked, origin is the path itself
  let cur = pathName;
  let changed = true;
  while (changed) {
    changed = false;
    for (const entry of ledger) {
      if (entry.round < beforeRound && entry.path === cur && entry.renamed_from) {
        cur = entry.renamed_from;
        changed = true;
      }
    }
  }
  return cur;
}

function ledgerEntriesForOrigin(originPath, beforeRound, ledger) {
  // Entries whose (chain of renames back from entry.path) reaches originPath,
  // restricted to rounds < beforeRound, in round order.
  return ledger
    .filter((e) => e.round < beforeRound)
    .filter((e) => resolveOriginPath(e.path, e.round + 1, ledger) === originPath || e.path === originPath)
    .sort((a, b) => a.round - b.round);
}

function verifyProvenance(finding, ledger) {
  if (ledger === null) {
    return { status: "unverified", value: finding.provenance, reason: "no change ledger is available to verify against" };
  }
  if (finding.line === null || finding.line === undefined) {
    return { status: "unverified", value: finding.provenance, reason: "not line-anchored" };
  }
  const originPath = resolveOriginPath(finding.path, finding.round, ledger);
  const relevant = ledgerEntriesForOrigin(originPath, finding.round, ledger);

  let introducedAtRound = null;
  let ambiguousTouch = false;
  for (const entry of relevant) {
    if ((entry.added_lines || []).includes(finding.line)) introducedAtRound = entry.round;
    if ((entry.deleted_lines || []).includes(finding.line)) ambiguousTouch = true;
  }

  if (introducedAtRound !== null) {
    const computed = `round:${introducedAtRound}`;
    if (finding.provenance === computed) return { status: "verified", value: computed };
    return {
      status: "corrected",
      value: computed,
      reason: `asserted "${finding.provenance}" but line ${finding.line} at ${finding.path} was introduced by round ${introducedAtRound}'s fix`,
    };
  }

  if (finding.provenance === "original") {
    if (ambiguousTouch) {
      return { status: "unverified", value: "original", reason: "the anchor line's region was later modified; mechanical attribution is undecidable" };
    }
    return { status: "verified", value: "original" };
  }
  return { status: "unverified", value: finding.provenance, reason: "asserted round:N but no tracked round's fix added this line" };
}

function verifyFingerprint(finding, allByStageId, ledger) {
  const m = /^(repeat-of|supersedes):(.+)$/.exec(finding.fingerprint);
  if (!m) {
    if (finding.fingerprint !== "new") return { status: "unverified", value: finding.fingerprint, reason: "malformed fingerprint" };
    return { status: "verified", value: "new" };
  }
  const [, , targetId] = m;
  const target = allByStageId.get(targetId);
  if (!target) return { status: "unverified", value: finding.fingerprint, reason: `referenced id "${targetId}" is not a known earlier finding` };
  if (target.round >= finding.round) {
    return { status: "unverified", value: finding.fingerprint, reason: `referenced id "${targetId}" is not from an earlier round` };
  }
  const originA = resolveOriginPath(finding.path, finding.round, ledger);
  const originB = resolveOriginPath(target.path, target.round, ledger);
  if (originA !== originB && finding.path !== target.path) {
    return { status: "unverified", value: finding.fingerprint, reason: `no rename evidence connects "${finding.path}" back to "${target.path}"` };
  }
  return { status: "verified", value: finding.fingerprint, targetDisposition: target.disposition };
}

function applyVerification(rounds, ledger) {
  const corrections = [];
  const allByStageId = new Map();
  for (const r of rounds) for (const f of r.findings) allByStageId.set(f.id, f);

  for (const r of rounds) {
    for (const f of r.findings) {
      const pv = verifyProvenance(f, ledger);
      f.verifiedProvenance = pv.value;
      f.provenanceStatus = pv.status;
      if (pv.status === "corrected") {
        corrections.push({ finding_id: f.id, field: "provenance", asserted: f.provenance, corrected: pv.value, evidence: pv.reason });
      }

      const fv = verifyFingerprint(f, allByStageId, ledger);
      f.verifiedFingerprint = fv.value;
      f.fingerprintStatus = fv.status;
      f.fingerprintTargetDisposition = fv.targetDisposition || null;
      if (fv.status === "corrected") {
        corrections.push({ finding_id: f.id, field: "fingerprint", asserted: f.fingerprint, corrected: fv.value, evidence: fv.reason });
      }
    }
  }
  return corrections;
}

// ---------------------------------------------------------------------------
// Predicate catalog (specs/dev-flow-v2.md § Convergence model v0)
// ---------------------------------------------------------------------------

function gatingFindings(round) {
  return round.findings.filter((f) => f.adjudicated_priority === "P0" || f.adjudicated_priority === "P1");
}

function predicate_no_gating_findings(currentRound) {
  return gatingFindings(currentRound).length === 0;
}

function predicate_provenance_share(currentRound, params) {
  const excludeClasses = new Set(params.exclude_classes || []);
  const gating = gatingFindings(currentRound).filter((f) => !excludeClasses.has(f.class) && f.provenanceStatus !== "unverified");
  if (gating.length === 0) return false;
  const roundProvenance = gating.filter((f) => f.verifiedProvenance.startsWith("round:")).length;
  return roundProvenance / gating.length >= params.min;
}

function predicate_count_rising(retainedRoundsAsc, currentIndex, params) {
  const need = params.increases;
  if (currentIndex < need) return false;
  const window = retainedRoundsAsc.slice(currentIndex - need, currentIndex + 1);
  for (let i = 1; i < window.length; i++) {
    if (gatingFindings(window[i]).length <= gatingFindings(window[i - 1]).length) return false;
  }
  const currentRound = retainedRoundsAsc[currentIndex];
  const hasVerifiedRoundProvenance = gatingFindings(currentRound).some(
    (f) => f.provenanceStatus === "verified" && f.verifiedProvenance.startsWith("round:"),
  );
  return hasVerifiedRoundProvenance;
}

function predicate_repeat_after_fix(currentRound) {
  return gatingFindings(currentRound).some((f) => {
    if (f.fingerprintStatus === "unverified") return false;
    if (!f.verifiedFingerprint.startsWith("repeat-of:")) return false;
    return ["fix", "restructure", "delete"].includes(f.fingerprintTargetDisposition);
  });
}

function evalPredicate(name, params, ctx) {
  switch (name) {
    case "no_gating_findings":
      return predicate_no_gating_findings(ctx.currentRound);
    case "provenance_share":
      return predicate_provenance_share(ctx.currentRound, params);
    case "count_rising":
      return predicate_count_rising(ctx.retainedRoundsAsc, ctx.currentIndex, params);
    case "repeat_after_fix":
      return predicate_repeat_after_fix(ctx.currentRound);
    default:
      throw new ExitIndeterminate(`unknown predicate "${name}"`);
  }
}

function evalExpr(expr, ctx) {
  const results = expr.list.map((entry) => ({ name: entry.predicate, hit: evalPredicate(entry.predicate, entry, ctx) }));
  const overall = expr.kind === "all" ? results.every((r) => r.hit) : results.some((r) => r.hit);
  return { overall, results };
}

// ---------------------------------------------------------------------------
// Head ancestry
// ---------------------------------------------------------------------------

function loadHeadsMap(headsFile) {
  if (!headsFile) return null;
  return loadJson(headsFile);
}

function isAncestorOrEqual(candidate, currentHead, { headsMap, repoRoot }) {
  if (candidate === currentHead) return true;
  if (headsMap) {
    let cur = currentHead;
    const seen = new Set();
    while (cur && !seen.has(cur)) {
      seen.add(cur);
      if (cur === candidate) return true;
      cur = headsMap[cur] ? headsMap[cur].parent : null;
    }
    return false;
  }
  if (repoRoot) {
    const result = spawnSync("git", ["-C", repoRoot, "merge-base", "--is-ancestor", candidate, currentHead]);
    return result.status === 0;
  }
  return "unknown";
}

// ---------------------------------------------------------------------------
// Verdict computation
// ---------------------------------------------------------------------------

function effectiveMinRounds(roundsPolicy, cap) {
  return Math.min(roundsPolicy.min_rounds, cap);
}

function computeVerdict({ stage, rounds, convergence, cap, minRounds, currentHead, ancestryOpts }) {
  const withAncestry = rounds.map((r) => ({
    ...r,
    ancestry: r.reviewedHead ? isAncestorOrEqual(r.reviewedHead, currentHead, ancestryOpts) : "unknown",
  }));

  const retained = withAncestry.filter((r) => r.ancestry === true);
  retained.sort((a, b) => a.round - b.round);

  const maxRoundNumber = withAncestry.reduce((m, r) => Math.max(m, r.round), 0);
  const capReached = maxRoundNumber >= cap;
  const latest = retained.length > 0 ? retained[retained.length - 1] : null;
  const isCurrentHeadRound = !!latest && latest.reviewedHead === currentHead;

  // rounds_counted is the count of COMPLETE logical rounds only — an
  // incomplete attempt (finder_unavailable / breadth_exhausted) counts no
  // logical round at all (exit-computation spec: "no logical round is
  // counted"). `retained` (and `latest` from it) still needs to include an
  // incomplete round so the incomplete-current-head-round check above can
  // find it; only the REPORTED metric excludes it.
  const base = { stage, rounds_counted: retained.filter((r) => r.status === "complete").length, next_round: null };

  // An incomplete current-head round (finder_unavailable / breadth_exhausted)
  // is always capped: exhausting the finder or breadth resource for a slot
  // is a hard stop independent of whether the round-number ceiling was also
  // reached — re-dispatching the same round would not help, since retry and
  // the full fallback chain are already spent (exit-computation spec
  // "Logical rounds require every configured finder": "ends the run
  // capped/finder_unavailable, never silently one pass short").
  if (isCurrentHeadRound && latest.status !== "complete") {
    return { ...base, outcome: "capped", reason: latest.status.replace("capped/", ""), action: "escalate" };
  }

  if (capReached) {
    if (!latest || !isCurrentHeadRound) {
      return { ...base, outcome: "capped", reason: "invalidated", action: "escalate" };
    }
    if (gatingFindings(latest).length === 0) {
      return { ...base, outcome: "capped", reason: "clean", action: "advance" };
    }
    return { ...base, outcome: "capped", reason: "findings_remain", action: "escalate" };
  }

  if (isCurrentHeadRound && latest.status === "complete") {
    const currentIndex = retained.indexOf(latest);
    const ctx = { currentRound: latest, retainedRoundsAsc: retained, currentIndex };
    const divergingEval = evalExpr(convergence.diverging, ctx);
    if (divergingEval.overall) {
      const hitName = divergingEval.results.find((r) => r.hit)?.name;
      return { ...base, outcome: "diverging", reason: hitName, action: "fix-delete-or-restructure", next_round: maxRoundNumber + 1 };
    }

    if (retained.length >= minRounds && gatingFindings(latest).length === 0) {
      const convergedEval = evalExpr(convergence.converged, ctx);
      if (convergedEval.overall) {
        const isEmptyRound = latest.findings.length === 0;
        return { ...base, outcome: "converged", reason: isEmptyRound ? "empty_round" : "predicates_satisfied", action: "advance" };
      }
    }
  }

  if (!latest) return { ...base, outcome: "continue", reason: "no_rounds_yet", action: "dispatch", next_round: maxRoundNumber + 1 };
  if (!isCurrentHeadRound) return { ...base, outcome: "continue", reason: "invalidated", action: "dispatch", next_round: maxRoundNumber + 1 };
  return { ...base, outcome: "continue", reason: "below_threshold", action: "dispatch", next_round: maxRoundNumber + 1 };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) {
        args[key] = true;
      } else {
        args[key] = next;
        i++;
      }
    }
  }
  return args;
}

// Same self-modification boundary as devflow-policy.mjs's own --closure
// (see its tryDelegateToClosure for the full rationale): this script's own
// exit computation is exactly as gate-able as the policy it resolves, so a
// change touching dev-flow-exit.mjs itself must also resolve under its
// merge-base copy. Checked first, ahead of every other argument.
function tryDelegateToClosure(argv) {
  const idx = argv.indexOf("--closure");
  if (idx === -1) return null;
  const closureDir = argv[idx + 1];
  if (!closureDir) {
    console.error("dev-flow-exit: --closure requires a directory argument");
    return 1;
  }
  const trustedScript = path.join(closureDir, "scripts", "dev-flow-exit.mjs");
  if (!existsSync(trustedScript)) {
    // Same reasoning as devflow-policy.mjs's tryDelegateToClosure: a merge
    // base that predates this reader's own existence has no trusted copy to
    // delegate to — refuse outright, never fall back to the branch copy.
    console.error(
      `dev-flow-exit: --closure directory has no scripts/dev-flow-exit.mjs (${closureDir}) — the reader must land on the merge base before a self-referential check can run; never falling back to the branch copy`,
    );
    return 1;
  }
  const passthrough = [...argv.slice(0, idx), ...argv.slice(idx + 2)];
  const result = spawnSync(process.execPath, [trustedScript, ...passthrough], { stdio: "inherit" });
  if (result.error) {
    console.error(`dev-flow-exit: could not exec the --closure reader: ${result.error.message}`);
    return 1;
  }
  return result.status === null ? 1 : result.status;
}

function main() {
  const argv = process.argv.slice(2);
  const delegated = tryDelegateToClosure(argv);
  if (delegated !== null) return delegated;

  const args = parseArgs(argv);
  if (!args.run || !args.stage || !args.policy) {
    console.error("usage: dev-flow-exit.mjs --run <dir> --stage <challenge|review> --policy <file> [options]");
    return 1;
  }
  if (args.stage !== "challenge" && args.stage !== "review") {
    console.error(`dev-flow-exit: --stage must be "challenge" or "review", got "${args.stage}"`);
    return 1;
  }

  let policyDoc, mergeBaseDoc;
  try {
    policyDoc = parseToml(readFileSync(args.policy, "utf8"));
    if (args["merge-base-policy"]) mergeBaseDoc = parseToml(readFileSync(args["merge-base-policy"], "utf8"));
  } catch (err) {
    console.error(`dev-flow-exit: could not read/parse policy inputs: ${err.message}`);
    return 1;
  }

  let resolved;
  try {
    resolved = resolvePolicy(policyDoc, { rigor: args.rigor, mergeBaseDoc });
  } catch (err) {
    if (err instanceof PolicyError || err instanceof TomlError) {
      console.error(`dev-flow-exit: ${err.message}`);
      return 1;
    }
    throw err;
  }

  let runDir;
  try {
    runDir = loadRunDir(args.run);
  } catch (err) {
    if (err instanceof ExitIndeterminate) {
      console.error(`dev-flow-exit: indeterminate: ${err.message}`);
      return EXIT_CODES.indeterminate;
    }
    console.error(`dev-flow-exit: could not read --run: ${err.message}`);
    return 1;
  }

  const validatorPath = args.validator || DEFAULT_VALIDATOR;
  // Scratch space for the --known-ids file validateReceipts() feeds to
  // validate-result-schemas.mjs — deliberately OUTSIDE --run (never written
  // into the run directory, which may be a committed fixture) and cleaned
  // up unconditionally.
  const tmpDir = args.tmp || mkdtempSync(path.join(os.tmpdir(), "dev-flow-exit-"));

  let validPasses, diagnostics;
  try {
    ({ validPasses, diagnostics } = validateReceipts(runDir.runRecord, runDir.passes, {
      validatorPath,
      tmpDir,
    }));
  } catch (err) {
    if (err instanceof ExitIndeterminate) {
      console.error(`dev-flow-exit: indeterminate: ${err.message}`);
      return EXIT_CODES.indeterminate;
    }
    throw err;
  } finally {
    if (!args.tmp) rmSync(tmpDir, { recursive: true, force: true });
  }

  // Adjudications must be validated BEFORE assembleLogicalRounds joins them
  // to findings and reads their adjudicated_priority for gating — an
  // invalid adjudication (wrong run/head, schema violation) that were
  // merely logged here and still consumed downstream could silently
  // downgrade a real P0/P1 into an exit-computation result that trusts it.
  const validAdjudications = [];
  for (const adj of runDir.adjudications) {
    if (adj.doc.stage !== args.stage) {
      validAdjudications.push(adj);
      continue;
    }
    // Manual run_id check as a floor even when no matching pass survives
    // to bind --pass against below (every pass for this round rejected,
    // or genuinely none exists yet) — --pass's own cross-check covers the
    // common case more thoroughly (reviewed_head and finding-completeness
    // too), but only when at least one pass is available to supply it.
    if (adj.doc.run_id !== runDir.runRecord.run_id) {
      diagnostics.push({
        pass: adj.name,
        level: "reject",
        reason: `adjudication run_id "${adj.doc.run_id}" does not match the active run "${runDir.runRecord.run_id}"`,
      });
      continue;
    }
    const matchingPasses = validPasses
      .filter((p) => p.payload.stage === adj.doc.stage && p.payload.round === adj.doc.round)
      .map((p) => p.file);
    const { ok, message } = validateAdjudicationSchema(validatorPath, adj.file, matchingPasses);
    if (ok) {
      validAdjudications.push(adj);
    } else {
      diagnostics.push({ pass: adj.name, level: "reject", reason: `adjudication schema validation failed: ${message}` });
    }
  }

  const rounds = assembleLogicalRounds(args.stage, validPasses, validAdjudications, resolved.stages[args.stage], runDir.runRecord);

  const missingAdjudication = rounds.some((r) => r.status === "complete" && r.findings.length > 0 && r.findings.some((f) => f.adjudicated_priority === null));
  if (missingAdjudication) {
    console.error("dev-flow-exit: indeterminate: at least one finding in a completed round has no matching adjudication entry");
    return EXIT_CODES.indeterminate;
  }

  const ledger = loadLedger({ historyFile: args.history, repoRoot: args["repo-root"] });
  const corrections = applyVerification(rounds, ledger);

  // --current-head must be an INDEPENDENTLY captured value (the caller's own
  // `git rev-parse HEAD`), never derived from the evidence being certified —
  // falling back to "whichever round is latest" would make that round
  // trivially "the current head round" by construction, defeating head
  // ancestry verification entirely (a stale round could certify convergence
  // simply by being the last one recorded).
  const currentHead = args["current-head"];
  if (!currentHead) {
    console.error("dev-flow-exit: indeterminate: --current-head is required (an independently captured value, never derived from a round's own reviewed_head)");
    return EXIT_CODES.indeterminate;
  }

  const ancestryOpts = { headsMap: loadHeadsMap(args.heads), repoRoot: args["repo-root"] };
  const cap = resolved.rounds[args.stage];
  const minRounds = effectiveMinRounds(resolved.rounds, cap);

  // "No confidence pass or adjudication round number SHALL exceed its
  // resolved stage cap, and a cap-zero confidence stage SHALL contain no
  // rounds" (exit-computation spec, "Caps constrain retained trajectory
  // records"). A trajectory that violates this is corrupt/inconsistent
  // with its own resolved policy and must be rejected outright, never
  // silently treated as "the round conveniently at the cap" or "disabled
  // with 0 rounds" while ignoring rounds that actually exist.
  const overCapRound = rounds.find((r) => r.round > cap);
  if (overCapRound) {
    console.error(
      `dev-flow-exit: indeterminate: round ${overCapRound.round} exceeds the resolved ${args.stage} cap (${cap}) — trajectory inconsistent with its own policy`,
    );
    return EXIT_CODES.indeterminate;
  }
  if (cap === 0 && rounds.length > 0) {
    console.error(
      `dev-flow-exit: indeterminate: ${args.stage} cap is 0 (disabled) but the trajectory contains round ${rounds[0].round} — trajectory inconsistent with its own policy`,
    );
    return EXIT_CODES.indeterminate;
  }
  // Round numbers must be exactly 1..max with no gaps — trusting the
  // largest producer-supplied round number alone (as capReached/capped-clean
  // do) would let a missing earlier round (never received, or rejected by
  // receipt validation) silently spend the cap as if every round up to it
  // had actually happened. A gap of any kind — including one created by an
  // earlier round's pass being rejected above — means the trajectory cannot
  // be trusted to represent what it claims.
  const presentRoundNumbers = [...new Set(rounds.map((r) => r.round))].sort((a, b) => a - b);
  for (let i = 0; i < presentRoundNumbers.length; i++) {
    if (presentRoundNumbers[i] !== i + 1) {
      console.error(
        `dev-flow-exit: indeterminate: ${args.stage} rounds are not contiguous from 1 (present: ${presentRoundNumbers.join(", ")}) — trajectory inconsistent with its own policy`,
      );
      return EXIT_CODES.indeterminate;
    }
  }

  let verdict;
  if (cap === 0) {
    verdict = { stage: args.stage, outcome: "capped", reason: "disabled", action: "advance", rounds_counted: 0, next_round: null };
  } else {
    verdict = computeVerdict({
      stage: args.stage,
      rounds,
      convergence: resolved.convergence,
      cap,
      minRounds,
      currentHead,
      ancestryOpts,
    });
  }

  verdict.corrections = corrections;
  verdict.diagnostics = diagnostics;

  if (args.json) {
    console.log(JSON.stringify(verdict, null, 2));
  } else {
    console.log(`${args.stage}: ${verdict.outcome} (${verdict.reason}) rounds_counted=${verdict.rounds_counted} next_round=${verdict.next_round ?? "-"}`);
    if (corrections.length > 0) {
      console.log("corrections:");
      for (const c of corrections) console.log(`  - ${c.finding_id} ${c.field}: ${c.asserted} -> ${c.corrected} (${c.evidence})`);
    }
    if (diagnostics.length > 0) {
      console.log("diagnostics:");
      for (const d of diagnostics) console.log(`  - ${d.pass}: ${d.reason}`);
    }
  }

  return EXIT_CODES[verdict.outcome];
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  process.exitCode = main();
}

export {
  loadRunDir,
  validateReceipts,
  assembleLogicalRounds,
  loadLedger,
  verifyProvenance,
  verifyFingerprint,
  applyVerification,
  evalPredicate,
  evalExpr,
  computeVerdict,
  isAncestorOrEqual,
  EXIT_CODES,
};
