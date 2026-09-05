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
//     [--heads <file>] [--closure <dir>] [--validator <path>]
//     [--verification-only] [--json]
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
// devflow-policy.mjs and lib/toml-lite.mjs are DELIBERATELY NOT imported
// here at module top level, even though they are only ever used inside
// main() below. A static top-level import is hoisted and evaluated before
// ANY of this module's own code runs — including tryDelegateToClosure's
// own --closure check — so if this file is invoked from a branch checkout
// where either sibling has been modified, that branch-controlled top-level
// code would already have run (arbitrary side effects, up to and including
// process.exit() before any output is even produced) before delegation to
// a trusted --closure copy ever got a chance to happen. Post-merge cloud
// review, confirmed real: the existing reader-self-modification-boundary
// fixture only proved a poisoned CONSTANT never leaks into the resolved
// output once execution reaches that point cleanly — it never proved the
// poisoned module's top-level code doesn't run at all. Every use of these
// two modules is confined to main(), after tryDelegateToClosure's own
// early return, and pulled in via dynamic import() there instead — see
// main() below.

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_VALIDATOR = path.join(HERE, "validate-result-schemas.mjs");

const EXIT_CODES = { continue: 0, converged: 20, diverging: 21, capped: 22, indeterminate: 2 };

// Every indeterminate exit previously only ever wrote prose to stderr —
// under --json this left stdout completely EMPTY, unlike every other exit
// path (the success printer below always emits a structured verdict), even
// though the machine contract requires a structured indeterminate outcome
// too and a caller reading only stdout could not distinguish "the run is
// indeterminate" from "nothing happened, check stderr" without also
// capturing stderr and hoping the exit code survived the caller's own
// wrapper. Shepherd-stage cloud finding, confirmed. Centralized here rather
// than duplicated at each of the nine indeterminate call sites in main().
function indeterminate(args, reason) {
  console.error(`dev-flow-exit: indeterminate: ${reason}`);
  if (args && args.json) {
    console.log(JSON.stringify({ outcome: "indeterminate", reason, rounds_counted: null, next_round: null }, null, 2));
  }
  return EXIT_CODES.indeterminate;
}

// Seam closed (lane #635, PR #713): result.challenger.schema.json now
// exists, and challenge-stage/review-stage passes are no longer validated
// under one hardcoded kind. "envelope" self-dispatches on each pass's own
// declared `role` (validate-result-schemas.mjs: "runs exactly the same
// payload + receipt checks as invoking the role's own kind name directly"),
// so a challenger-shaped challenge pass and a reviewer-shaped review pass
// each validate against their own schema without dev-flow-exit.mjs having
// to know or assume which role produced a given pass.
const PASS_VALIDATION_KIND = "envelope";

class ExitIndeterminate extends Error {}

// ---------------------------------------------------------------------------
// Run directory loading
// ---------------------------------------------------------------------------

function loadJson(file) {
  return JSON.parse(readFileSync(file, "utf8"));
}

// The stage named by the LAST transition receipt, or null if none exists
// yet. dev-flow-exit.mjs only ever computes challenge or review's exit
// (args.stage is validated to one of those two), so this is used solely to
// refuse computing review's exit while challenge is still active — see
// main()'s use below.
function latestActiveStage(receipts) {
  let active = null;
  for (const r of receipts || []) {
    if (r.kind === "transition") active = r.stage;
  }
  return active;
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
    if (r.kind !== "pass") return;
    // A repeated pass filename silently overwrote its earlier sequence
    // number here (challenge round 3, confirmed): if the duplicate receipt
    // sits after a later transition back into the pass's claimed stage,
    // activeStageBefore(seq) below would use the LATER position and accept
    // a pass that actually arrived under a different active stage,
    // defeating the chronology boundary. A receipt filename must be unique;
    // a duplicate makes the whole trajectory untrustworthy rather than
    // relocating the pass.
    if (passSeqByName.has(r.file)) {
      throw new ExitIndeterminate(`run.json receipts contain more than one "pass" entry for file "${r.file}" (seq ${passSeqByName.get(r.file)}, ${idx})`);
    }
    passSeqByName.set(r.file, idx);
  });
  // A receipt names a pass whose JSON artifact is absent from passes/ —
  // deleted, never written, or simply stale. Everything below this point
  // iterates only files actually DISCOVERED under passes/ (`passes`, the
  // parameter), so a receipt-only entry with no backing file was
  // previously invisible in that direction — shepherd-stage cloud finding,
  // confirmed: deleting a pass while its receipt survives let the trusted
  // sequence still claim the slot was filled, silently authorizing
  // redispatch (continue/no_rounds_yet) despite the receipt saying
  // otherwise. The opposite direction (a pass with no receipt entry) was
  // already caught below at "no receipt entry for this pass in run.receipts".
  const passNamesOnDisk = new Set(passes.map((p) => p.name));
  for (const [name, seq] of passSeqByName) {
    if (!passNamesOnDisk.has(name)) {
      throw new ExitIndeterminate(`run.json receipts name pass "${name}" (seq ${seq}) but no matching file exists under passes/ — receipt without evidence`);
    }
  }
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
    // result.schema.json's own status enum ("completed"|"blocked") documents
    // blocked as "the role could not [produce its full payload] (e.g. ... a
    // finder that failed and will be retried once)" — schema-valid is not
    // the same as semantically complete. Shepherd-stage cloud finding
    // (round 4), confirmed: nothing here checked env.status at all, so a
    // blocked envelope entered validPasses/logical-round assembly exactly
    // like a genuine completed contribution — in the retry/fallback path,
    // retaining a blocked primary alongside a successful fallback creates
    // two claims for one slot; if the chain instead exhausts, the blocked
    // result can suppress the terminal capped/finder_unavailable outcome
    // that should fire. Confidence-stage assembly only ever wants completed
    // envelopes; a blocked one is evidence the retry/fallback path must
    // continue, not itself a claim on a slot.
    if (env.status !== "completed") {
      diagnostics.push({ pass: pass.name, level: "reject", reason: `envelope status is "${env.status}", not "completed" — a blocked result is not a completed slot claim` });
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
  // Two individually-valid adjudication files naming the same (stage, round)
  // may assign conflicting adjudicated priorities — silently keeping
  // whichever readdirSync happened to list last let filesystem order decide
  // whether a P1 gates the stage (challenge round 3, confirmed). Reject the
  // ambiguity outright rather than picking one.
  const adjByRound = new Map();
  const adjFileByRound = new Map();
  for (const a of adjudications) {
    if (a.doc.stage !== stage) continue;
    const prior = adjFileByRound.get(a.doc.round);
    if (prior) {
      throw new ExitIndeterminate(
        `two adjudication documents both name stage "${stage}" round ${a.doc.round}: "${prior}" and "${a.file}" — ambiguous, cannot trust either`,
      );
    }
    adjByRound.set(a.doc.round, a.doc);
    adjFileByRound.set(a.doc.round, a.file);
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
    // Post-merge cloud review, confirmed: this observed-slot fallback only
    // ever looked at stagePasses, so a slot that was exhausted with ONLY a
    // slot_failures record and never produced any pass at all (blocked or
    // complete) was invisible to the derived slot set — a round missing
    // that slot entirely then had nothing to check it against and read as
    // trivially complete (continue/no_rounds_yet) instead of the terminal
    // capped/finder_unavailable its own recorded failure demands. Union in
    // slotFailures' own slot names alongside stagePasses'.
    const observed = new Set();
    for (const p of stagePasses) observed.add(p.payload.slot || p.payload.finder);
    for (const sf of slotFailures) observed.add(sf.slot);
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
      // A fallback claim's finder must be one this slot's OWN configured
      // finder_fallbacks chain actually names — review round 2, confirmed:
      // checking only substitutes_for === slot && finder !== slot let any
      // arbitrary, unauthorized finder fill a slot by merely claiming to
      // substitute for it, bypassing the configured fallback chain entirely
      // (exit-computation spec: only "the configured finder_fallbacks chain
      // for that slot" may fill it after the primary's retry).
      const validFallback =
        !isPrimaryClaim && p.payload.substitutes_for === slot && finder !== slot && resolvedStage.finder_fallbacks.includes(finder);
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
        // An accepted pass AND a slot_failures record for the SAME
        // (round, slot) directly contradict each other — one says the
        // slot was filled, the other says the finder was unavailable/
        // exhausted for it — even when their heads agree, unlike the
        // reviewedHead-disagreement check below which only fires across
        // DIFFERENT slots. Shepherd-stage cloud finding, confirmed: this
        // branch previously never consulted slotFailures at all once a
        // slot had a valid claim, silently letting the failure record
        // disappear rather than flagging the trajectory as
        // internally inconsistent.
        const contradiction = slotFailures.find((s) => s.round === roundNumber && s.slot === slot);
        if (contradiction) {
          throw new ExitIndeterminate(
            `round ${roundNumber} of stage "${stage}" has both an accepted pass and a slot_failures record for slot "${slot}" — these directly contradict each other`,
          );
        }
        if (p.payload.substitutes_for) {
          substitutions.push({ slot, ran: p.payload.finder, round: roundNumber });
        }
        continue;
      }
      const failure = slotFailures.find((s) => s.round === roundNumber && s.slot === slot);
      if (failure) {
        unresolvedSlot = slot;
        unresolvedReason = failure.reason === "breadth_exhausted" ? "breadth_exhausted" : "finder_unavailable";
        break;
      }
      // No accepted pass AND no matching slot_failures record for this
      // slot — shepherd-stage cloud finding (round 3), confirmed:
      // synthesizing finder_unavailable here has no actual evidence of
      // exhaustion behind it; it is equally consistent with "still
      // pending" (another finder in this round has not reported back
      // either) or "a pass was rejected but no failure record was ever
      // written." Neither is a confirmed terminal outcome, so this round
      // cannot be safely assembled at all rather than confidently
      // escalated on synthesized evidence.
      throw new ExitIndeterminate(
        `round ${roundNumber} of stage "${stage}" has no accepted pass and no slot_failures record for slot "${slot}" — cannot determine whether it is still pending or genuinely exhausted`,
      );
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
    // Every primary slot filled but the accepted passes disagree on which
    // head they reviewed is an internally-inconsistent trajectory, not an
    // ordinary unresolved slot — review round 1, confirmed: this previously
    // still marked the round "complete" with reviewedHead null, letting it
    // silently spend the numeric cap (maxRoundNumber counts every round
    // number regardless of ancestry/retention) rather than being refused
    // outright as untrustworthy, matching every other internal-consistency
    // violation in this file (duplicate transitions, duplicate receipts,
    // duplicate adjudications).
    if (!unresolvedSlot && reviewedHeads.size > 1) {
      throw new ExitIndeterminate(
        `round ${roundNumber} of stage "${stage}" has every primary slot filled but its accepted passes disagree on reviewed_head (${[...reviewedHeads].join(", ")}) — trajectory inconsistent with itself`,
      );
    }
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
      hasAdjudication: !!adjudication,
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
  // Neither an explicit history file nor a repo root was given — including
  // the advertised no-flags `task devflow:exit` usage — or repoRoot was
  // given but the git adapter is deliberately not implemented yet (see
  // ai/schemas/README.md / "## Deferred findings"). Both are "no evidence
  // source configured", not "a real ledger that happens to be empty"
  // (challenge round 3, confirmed): returning [] here let verifyProvenance
  // certify every producer-asserted `original` claim by default, silently
  // defeating provenance_share divergence detection. A fixture that wants a
  // genuinely empty-but-real ledger supplies an explicit --history file
  // containing `[]`.
  return null;
}

function resolveOriginPath(pathName, beforeRound, ledger) {
  if (!ledger) return pathName; // no ledger available: no rename can be tracked, origin is the path itself
  let cur = pathName;
  // Walk rounds strictly descending from beforeRound - 1, consulting each
  // round at most once, rather than re-scanning the whole ledger until
  // nothing changes. Shepherd-stage cloud finding, confirmed: a legitimate
  // rename-back history (round 1: a.js -> b.js, round 2: b.js -> a.js)
  // made the old scan-to-fixpoint loop bounce between the two paths
  // forever — a real rename-back trajectory hung exit computation entirely
  // rather than computing a wrong-but-terminating answer. Descending
  // through each distinct earlier round exactly once still finds the same
  // chain for a genuine (non-cyclic) rename history, and is bounded by
  // construction.
  const roundsDesc = [...new Set(ledger.filter((e) => e.round < beforeRound).map((e) => e.round))].sort((a, b) => b - a);
  for (const round of roundsDesc) {
    const entry = ledger.find((e) => e.round === round && e.path === cur && e.renamed_from);
    if (entry) cur = entry.renamed_from;
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
  for (const entry of relevant) {
    if ((entry.added_lines || []).includes(finding.line)) introducedAtRound = entry.round;
  }

  // A later round's insertion or deletion AT OR ABOVE this line shifts
  // every subsequent line number, so the ledger's recorded coordinate for
  // an EARLIER round's add no longer equals where that content now sits
  // (review round 2, confirmed) — a direct `=== finding.line` comparison
  // would then find no match, fall through, and wrongly verify "original"
  // for code that actually came from the earlier round, just renumbered.
  // Only entries STRICTLY AFTER the one that introduced this line (or,
  // when there is no introducing round at all — an "original" claim,
  // which predates every tracked round — any entry in `relevant`) can have
  // shifted ITS coordinate; an entry at or before the introducing round
  // cannot retroactively shift a position recorded after it. Shepherd-
  // stage cloud finding (round 2, about pre-existing code), confirmed: the
  // prior single-pass version considered EVERY entry regardless of
  // chronological relationship to `introducedAtRound`, so an earlier
  // round's own unrelated add at a lower line number falsely flagged
  // ambiguity for a line a LATER round introduced — the earlier add
  // predates and has no bearing on it.
  let ambiguousTouch = false;
  for (const entry of relevant) {
    if (introducedAtRound !== null && entry.round <= introducedAtRound) continue;
    const touchedAtOrAbove = [...(entry.added_lines || []), ...(entry.deleted_lines || [])].some((l) => l <= finding.line);
    if (touchedAtOrAbove) ambiguousTouch = true;
  }

  if (introducedAtRound !== null) {
    // Shepherd-stage cloud finding (round 2, about pre-existing code),
    // confirmed: this branch returned "verified"/"corrected" unconditionally,
    // never consulting `ambiguousTouch` the way the "original" branch below
    // already does. A later round's edit at-or-above this line can shift
    // what the ledger's round-N coordinate now actually points at — the
    // SAME reasoning that motivated ambiguousTouch in the first place — so
    // a round:N match found under an ambiguous touch is not safe to
    // confidently verify or correct either; report it undecidable instead.
    if (ambiguousTouch) {
      return {
        status: "unverified",
        value: finding.provenance,
        reason: `line ${finding.line} at ${finding.path} matches round ${introducedAtRound}'s own add, but its region was later modified; mechanical attribution is undecidable`,
      };
    }
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
  // No tracked round's fix added this line, so it predates every round —
  // the SAME positive conclusion the "original" branch above reaches via
  // introducedAtRound === null, just arriving here because the finding
  // asserted round:N instead of original. Post-merge cloud review,
  // confirmed: this previously stayed merely "unverified" rather than
  // being corrected, even though the ledger rules out every round
  // attribution — and provenance_share drops unverified findings from
  // both its numerator and denominator, so a wrongly-unverified claim can
  // silently produce a false diverging. Mirrors the "original" branch's
  // own ambiguousTouch handling: an ambiguous region stays undecidable,
  // otherwise the claim is corrected to what the ledger actually shows.
  if (ambiguousTouch) {
    return {
      status: "unverified",
      value: finding.provenance,
      reason: "asserted round:N but no tracked round's fix added this line, and the anchor line's region was later modified; mechanical attribution is undecidable",
    };
  }
  return {
    status: "corrected",
    value: "original",
    reason: `asserted "${finding.provenance}" but no tracked round's fix added line ${finding.line} at ${finding.path} — it predates every tracked round`,
  };
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
  // Path (or rename-tracked path) evidence alone connects two DIFFERENT
  // lines in the same file, which two genuinely unrelated findings in that
  // file would also satisfy — review round 1, confirmed: two unrelated
  // findings could be marked a verified repeat merely by sharing a path,
  // letting a fabricated repeat-of claim falsely trigger repeat_after_fix.
  // Require the current finding's own line to be one round target.round's
  // OWN fix actually added at the resolved origin path — the same ledger
  // entries verifyProvenance's round:N attribution already uses, so a
  // genuine repeat (the same defect resurfacing on the line the fix
  // touched) still verifies while a same-file coincidence does not.
  if (!ledger) {
    return { status: "unverified", value: finding.fingerprint, reason: "no change ledger is available to verify against" };
  }
  const targetsFixEntries = ledgerEntriesForOrigin(originA, finding.round, ledger).filter((e) => e.round === target.round);
  const lineTracesToTargetsFix = targetsFixEntries.some((e) => (e.added_lines || []).includes(finding.line));
  if (!lineTracesToTargetsFix) {
    return {
      status: "unverified",
      value: finding.fingerprint,
      reason: `no ledger evidence connects line ${finding.line} at "${finding.path}" to round ${target.round}'s own fix`,
    };
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
  // "corrected" is evidence-backed exactly like "verified" — it is what a
  // producer's own "original" claim becomes once the ledger PROVES the line
  // was actually introduced by an earlier round's fix (verifyProvenance);
  // excluding it here (review round 2, confirmed) let a strictly-rising,
  // evidence-corrected self-feeding trajectory evade count_rising's guard
  // merely because the producer itself never asserted round:N.
  const hasVerifiedRoundProvenance = gatingFindings(currentRound).some(
    (f) => (f.provenanceStatus === "verified" || f.provenanceStatus === "corrected") && f.verifiedProvenance.startsWith("round:"),
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

// Mirrors devflow-policy.mjs's validatePredicateExpr recursion: a list entry
// is either a leaf (`predicate` string) or a nested `{any:[...]}|{all:[...]}`
// composition node, evaluated by recursing into evalExpr itself. The resolved
// policy already validated this shape at resolve time; this only interprets
// it, matching "every implementation accepts and evaluates the expression
// with exactly the catalog semantics" (exit-computation spec.md).
function evalExpr(expr, ctx) {
  const results = expr.list.map((entry) => {
    if (typeof entry.predicate === "string") {
      return { name: entry.predicate, hit: evalPredicate(entry.predicate, entry, ctx) };
    }
    // A nested list entry is stored in its raw `{any:[...]}|{all:[...]}`
    // TOML/JSON shape (devflow-policy.mjs's validatePredicateExpr leaves
    // list entries untouched) — normalize to the same {kind, list} shape
    // evalExpr itself takes before recursing.
    const nestedKind = entry.all ? "all" : "any";
    const nested = evalExpr({ kind: nestedKind, list: entry[nestedKind] }, ctx);
    // For the diverging/converged "reason" field, surface an actual
    // triggering leaf predicate's name rather than just the composition
    // operator, when one hit.
    const innerHit = nested.results.find((r) => r.hit);
    return { name: innerHit ? innerHit.name : `(${nestedKind})`, hit: nested.overall, nested: nested.results };
  });
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
    // `git merge-base --is-ancestor` documents exactly two meaningful exit
    // statuses: 0 (is an ancestor) and 1 (is not — a genuine, valid "no").
    // Any other status (128 for a missing/unreachable object in a shallow
    // or incomplete checkout, among others) or a spawn failure (`.error`)
    // is an execution error, not a valid "no" — shepherd-stage cloud
    // finding (round 2, about pre-existing code), confirmed: collapsing
    // every nonzero status to `false` mislabeled unavailable ancestry
    // evidence as definitively invalidated, which could dispatch another
    // round or escalate at the cap instead of correctly reporting
    // "unknown".
    const result = spawnSync("git", ["-C", repoRoot, "merge-base", "--is-ancestor", candidate, currentHead]);
    if (result.error || result.status === null) return "unknown";
    if (result.status === 0) return true;
    if (result.status === 1) return false;
    return "unknown";
  }
  return "unknown";
}

// ---------------------------------------------------------------------------
// Verdict computation
// ---------------------------------------------------------------------------

function effectiveMinRounds(roundsPolicy, cap) {
  return Math.min(roundsPolicy.min_rounds, cap);
}

// Computes ancestry for every round and filters to the RETAINED subset — a
// round whose reviewedHead is a true ancestor-or-equal of currentHead, or
// an incomplete round with no reviewedHead at all (slot_failures may omit
// `head`; its terminal nature is inherent to the exhausted slot, never
// contingent on comparing a head that does not exist — see computeVerdict's
// own use of this below). Shared with applyVerification/verifyFingerprint
// (post-merge cloud review, confirmed): they previously built their
// repeat-of lookup map from the FULL unfiltered rounds list, so a
// current-head finding could verify `repeat-of:<id>` against a finding
// from an ancestry-incomparable/excluded round that computeVerdict itself
// would never retain — both call sites now agree on exactly one retained
// set instead of computing it independently and risking drift.
function ancestryRetainedRounds(rounds, currentHead, ancestryOpts) {
  const withAncestry = rounds.map((r) => ({
    ...r,
    ancestry: r.reviewedHead ? isAncestorOrEqual(r.reviewedHead, currentHead, ancestryOpts) : "unknown",
  }));
  const retained = withAncestry.filter((r) => r.ancestry === true || (r.status !== "complete" && r.reviewedHead === null));
  retained.sort((a, b) => a.round - b.round);
  return { withAncestry, retained };
}

function computeVerdict({ stage, rounds, convergence, cap, minRounds, currentHead, ancestryOpts }) {
  const { withAncestry, retained } = ancestryRetainedRounds(rounds, currentHead, ancestryOpts);

  // An incomplete round (capped/finder_unavailable or
  // capped/breadth_exhausted) with NO recorded reviewedHead at all — a
  // slot_failures entry is permitted to omit `head` — must still be
  // retained: its terminal nature is inherent to the exhausted slot
  // itself, never contingent on comparing a head that does not exist.
  // Shepherd-stage cloud finding (round 3), confirmed: `ancestry === true`
  // alone excluded it (reviewedHead null always computes ancestry
  // "unknown"), so the round-2 "any incomplete round anywhere in retained
  // is immediately terminal" check never even saw it, and the trajectory
  // fell through to continue/no_rounds_yet below the cap instead of the
  // recorded terminal outcome. Scoped narrowly to reviewedHead === null
  // specifically (not "any unknown ancestry") — a round that DOES carry a
  // head but whose ancestry could not be verified (no --heads/--repo-root
  // supplied at all) stays correctly excluded, unchanged from before.
  // (retained/withAncestry now come from the shared ancestryRetainedRounds
  // helper above, which already applies exactly this rule.)

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
  //
  // "Every substitution SHALL be recorded and disclosed" is unconditional
  // (exit-computation spec "Logical rounds require every configured
  // finder") — the "fallback substitutes for a blocked primary" scenario
  // explicitly covers a round that COMPLETES via a substitution, not only
  // a terminal/incomplete one. Post-merge cloud review, confirmed: only
  // the capped/finder_unavailable|breadth_exhausted branch below ever
  // carried `substitutions` on the returned verdict; every ordinary
  // continue/converged/capped-clean verdict dropped it entirely, even
  // though `fallback-substitutes-for-primary`'s own fixture exercises
  // exactly this case. Aggregated onto `base` once so every verdict below
  // inherits it via `...base`.
  const base = {
    stage,
    rounds_counted: retained.filter((r) => r.status === "complete").length,
    next_round: null,
    substitutions: retained.flatMap((r) => r.substitutions || []),
  };

  // ANY incomplete round (finder_unavailable / breadth_exhausted) among the
  // retained trajectory is always terminal — "no later round is legal" once
  // a slot's retry and full fallback chain are exhausted (exit-computation
  // spec "Logical rounds require every configured finder"), independent of
  // whether the round-number ceiling was also reached, and independent of
  // whether it happens to be `latest` by round number. Checking only
  // `latest` (review round 2, confirmed) let a malformed or resumed
  // trajectory bypass an earlier exhaustion entirely whenever a LATER,
  // complete round also exists — re-dispatching a round at all after an
  // exhaustion is itself illegal, so its presence must never let the
  // exhaustion be silently overridden.
  const firstIncomplete = retained.find((r) => r.status !== "complete");
  if (firstIncomplete) {
    // The blocker report a human escalation needs names WHICH slot and
    // what was already tried, not just the generic reason — review round
    // 3 (P2, confirmed): this terminal verdict previously dropped
    // `unresolvedSlot`/`substitutions` entirely.
    return {
      ...base,
      outcome: "capped",
      reason: firstIncomplete.status.replace("capped/", ""),
      action: "escalate",
      unresolved_slot: firstIncomplete.unresolvedSlot,
      incomplete_round: firstIncomplete.round,
      substitutions: firstIncomplete.substitutions,
    };
  }

  if (capReached) {
    // The spec requires the FINAL PERMITTED ROUND ITSELF to review the
    // current head — not merely "some retained round does." If the round
    // actually at/beyond the cap (maxRoundNumber) got excluded from
    // `retained` (ancestry false/unknown) while an EARLIER round coincides
    // with currentHead, `latest` would point at that earlier round instead
    // — review round 2, confirmed: this must be invalidated/escalate, never
    // treated as if the earlier round were the qualifying final one.
    if (!latest || !isCurrentHeadRound || latest.round !== maxRoundNumber) {
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
      // No next_round: `diverging` is an escalating outcome exactly like
      // `capped`/`converged` (neither of which sets one either, both
      // inheriting base.next_round === null) — a session must choose
      // delete/restructure/genuinely-in-scope before any further round is
      // legitimate, per AGENTS.md's round-2 checkpoint discipline; which of
      // those a fix disposition actually satisfies is the session's
      // judgement to record (issue #636's own "Out of scope" section), not
      // this script's to arbitrate from a free-text adjudication reason.
      // Shepherd-stage cloud finding, confirmed: handing back a concrete
      // next_round here, alongside an action string that names "fix" as one
      // of three options, reads as authorizing an automated continue —
      // exactly the self-feeding loop `diverging` exists to interrupt.
      return { ...base, outcome: "diverging", reason: hitName, action: "fix-delete-or-restructure" };
    }

    // base.rounds_counted (COMPLETE rounds only), not retained.length (which
    // still includes an incomplete finder_unavailable/breadth_exhausted
    // attempt kept in `retained` so the incomplete-current-head check above
    // can find it) — challenge round 3, confirmed: using the raw retained
    // count let one real complete round plus one stale incomplete attempt
    // satisfy min_rounds = 2.
    if (gatingFindings(latest).length === 0) {
      const convergedEval = evalExpr(convergence.converged, ctx);
      if (convergedEval.overall) {
        const isEmptyRound = latest.findings.length === 0;
        if (isEmptyRound) {
          // The empty-round shortcut: a round with NO findings at all ends
          // the stage by itself, but only once min_rounds has been met —
          // min_rounds constrains this exit alone (AGENTS.md "min_rounds
          // constrains the empty-round exit alone and needs no separate
          // check on the other two").
          if (base.rounds_counted >= minRounds) {
            return { ...base, outcome: "converged", reason: "empty_round", action: "advance" };
          }
        } else {
          // A NONEMPTY clean round (findings exist but none are gating)
          // needs a SECOND CONSECUTIVE clean round to converge — AGENTS.md
          // "ends when two consecutive rounds adjudicate to zero P0 and
          // zero P1 findings", and explicitly NOT via min_rounds ("min_rounds
          // only governs the empty-round shortcut"). Post-merge cloud
          // review, confirmed: this branch previously let ANY round satisfy
          // convergence the moment rounds_counted >= minRounds, so with the
          // common min_rounds = 1, a single nonempty all-P2 round converged
          // immediately — never checking whether an earlier round was also
          // clean.
          // Array-adjacent, not round-number-adjacent, was wrong: if an
          // intervening round was excluded from `retained` (ancestry
          // incomparable/unknown), the array's previous ELEMENT is an
          // earlier, non-consecutive round — e.g. retained = [round 1,
          // round 3] with round 2 excluded, where round 1 is clean but is
          // not round 3's immediate predecessor. That still let round 3
          // converge on a confirmation that never actually happened.
          // Shepherd-stage cloud finding, confirmed: require the array
          // neighbor's OWN round number to be exactly one less, not merely
          // its array position.
          const previous = currentIndex > 0 ? retained[currentIndex - 1] : null;
          const previousClean = previous && previous.round === latest.round - 1 && previous.status === "complete" && gatingFindings(previous).length === 0;
          if (previousClean) {
            return { ...base, outcome: "converged", reason: "predicates_satisfied", action: "advance" };
          }
        }
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

async function main() {
  const argv = process.argv.slice(2);
  const delegated = tryDelegateToClosure(argv);
  if (delegated !== null) return delegated;

  // Deferred until here — see the comment where these used to be static
  // top-level imports, above. Resolves relative to THIS file, same as a
  // static import would; the only difference that matters is WHEN it runs.
  const { parseToml, TomlError } = await import("./lib/toml-lite.mjs");
  const { resolvePolicy, crossValidate, PolicyError } = await import("./devflow-policy.mjs");

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

  // No --registry/--task-targets here on purpose (see this file's header
  // comment) — but the registry/task-target-INDEPENDENT half of
  // cross-validation (breadth sufficiency, a confidence stage with a
  // nonzero cap but no configured finders) still has to run here too.
  // Without it, a policy `devflow-policy.mjs resolve` would refuse (e.g.
  // breadth too small for its own configured fallback chain) could still
  // compute exits when this script is invoked directly — review round 1,
  // confirmed.
  const crossErrors = crossValidate(resolved, null, null).filter((e) => !e.startsWith("indeterminate:"));
  if (crossErrors.length > 0) {
    console.error(`dev-flow-exit: policy fails cross-validation: ${crossErrors[0]}`);
    return 1;
  }

  let runDir;
  try {
    runDir = loadRunDir(args.run);
  } catch (err) {
    if (err instanceof ExitIndeterminate) {
      return indeterminate(args, err.message);
    }
    console.error(`dev-flow-exit: could not read --run: ${err.message}`);
    return 1;
  }

  // Stage-skipping (computing REVIEW's exit while challenge is the trusted
  // receipt sequence's EXPLICITLY active stage) is only legal when
  // challenge is fully disabled — post-merge cloud review, confirmed:
  // nothing previously compared the requested --stage against the receipt
  // sequence's own active stage at all, so `--stage review` computed a
  // valid continue/no_rounds_yet verdict (authorizing review's first
  // dispatch) even while a transition into "challenge" was the latest one
  // recorded and its cap was nonzero. Scoped specifically to
  // activeStage === "challenge" (not "no transition recorded at all"): the
  // no-transition case already has its own considered, fixture-proven
  // behavior below (a pass that arrived before any transition is rejected
  // as invalid on its own terms, naturally yielding continue/no_rounds_yet
  // with zero valid rounds) — this check must not relitigate that.
  //
  // The BACKWARD direction (--stage challenge while review is active) is
  // handled separately, below verdict computation, rather than as an
  // equally-unconditional early gate here — a second, later cloud finding
  // confirmed that a blanket symmetric gate at this point wrongly refuses
  // a legitimate retrospective query (challenge's OWN already-converged
  // result, computed after the run moved on to review — see the
  // stale-pass-after-stage-moved-on fixture, which exercises exactly this
  // and expects `converged/empty_round` to still compute correctly). What
  // must never happen is a backward query resolving to `continue`/dispatch
  // (implying more challenge work should be authorized after review has
  // already begun) — see the post-verdict guard below.
  const activeStage = latestActiveStage(runDir.runRecord.receipts);
  if (args.stage === "review" && activeStage === "challenge" && resolved.rounds.challenge !== 0) {
    return indeterminate(
      args,
      `--stage review was requested but the trusted receipt sequence's active stage is still "challenge" (cap ${resolved.rounds.challenge}, not disabled) — review cannot be active until challenge exits`,
    );
  }

  const validatorPath = args.validator || DEFAULT_VALIDATOR;
  // Preflight the validator's own existence before ever spawning it.
  // Shepherd-stage cloud finding (round 2, about pre-existing code),
  // confirmed: runValidator's `status === 0` check cannot distinguish "the
  // validator ran and rejected this pass" from "the validator process
  // itself couldn't even load" (a missing/broken --validator path spawns
  // node successfully but node then exits non-zero on its own
  // MODULE_NOT_FOUND) — every pass in the run would fail identically,
  // silently degrading a valid completed round into what reads as "no
  // passes at all" (continue/no_rounds_yet) instead of the indeterminate
  // dependency failure it actually is. Preflighting here, once, before any
  // pass is validated, closes the gap without needing to sniff error text
  // per invocation.
  if (!existsSync(validatorPath)) {
    return indeterminate(args, `--validator path does not exist: ${validatorPath}`);
  }
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
      return indeterminate(args, err.message);
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

  let rounds;
  try {
    rounds = assembleLogicalRounds(args.stage, validPasses, validAdjudications, resolved.stages[args.stage], runDir.runRecord);
  } catch (err) {
    if (err instanceof ExitIndeterminate) {
      return indeterminate(args, err.message);
    }
    throw err;
  }

  const cap = resolved.rounds[args.stage];
  const minRounds = effectiveMinRounds(resolved.rounds, cap);

  // Cap integrity applies before BOTH output modes. --verification-only is a
  // pre-adjudication projection, not permission to create/adjudicate a round
  // the resolved policy forbids. Check retained and raw evidence here, before
  // that mode can return successfully.
  const overCapRound = rounds.find((r) => r.round > cap);
  if (overCapRound) {
    return indeterminate(args, `round ${overCapRound.round} exceeds the resolved ${args.stage} cap (${cap}) — trajectory inconsistent with its own policy`);
  }
  if (cap === 0 && rounds.length > 0) {
    return indeterminate(args, `${args.stage} cap is 0 (disabled) but the trajectory contains round ${rounds[0].round} — trajectory inconsistent with its own policy`);
  }
  const rawOverCapPassRound = runDir.passes
    .map((p) => p.envelope.payload)
    .find((p) => p && p.stage === args.stage && typeof p.round === "number" && p.round > cap);
  if (rawOverCapPassRound) {
    return indeterminate(args, `a ${args.stage} pass names round ${rawOverCapPassRound.round}, exceeding the resolved cap (${cap}), even though it did not survive receipt validation — trajectory inconsistent with its own policy`);
  }
  const rawOverCapAdjRound = runDir.adjudications.find((a) => a.doc.stage === args.stage && a.doc.round > cap);
  if (rawOverCapAdjRound) {
    return indeterminate(args, `a ${args.stage} adjudication names round ${rawOverCapAdjRound.doc.round}, exceeding the resolved cap (${cap}), even though it did not survive validation — trajectory inconsistent with its own policy`);
  }
  const presentRoundNumbers = [...new Set(rounds.map((r) => r.round))].sort((a, b) => a - b);
  for (let i = 0; i < presentRoundNumbers.length; i++) {
    if (presentRoundNumbers[i] !== i + 1) {
      return indeterminate(args, `${args.stage} rounds are not contiguous from 1 (present: ${presentRoundNumbers.join(", ")}) — trajectory inconsistent with its own policy`);
    }
  }

  // Every retained COMPLETE round needs its own adjudication document,
  // including a clean, zero-finding one — review round 2, confirmed: the
  // prior `findings.length > 0` guard meant a completed round with no
  // findings at all bypassed this check entirely, so a clean round could
  // certify convergence with no adjudication document ever having existed
  // for it (exit-computation spec: "every retained pass to have exactly
  // one adjudication document").
  const missingAdjudication = rounds.some(
    (r) => r.status === "complete" && (!r.hasAdjudication || r.findings.some((f) => f.adjudicated_priority === null)),
  );
  if (missingAdjudication && !args["verification-only"]) {
    return indeterminate(args, "a completed round has no adjudication document, or a finding in it has no matching adjudication entry");
  }

  // --current-head must be an INDEPENDENTLY captured value (the caller's own
  // `git rev-parse HEAD`), never derived from the evidence being certified —
  // falling back to "whichever round is latest" would make that round
  // trivially "the current head round" by construction, defeating head
  // ancestry verification entirely (a stale round could certify convergence
  // simply by being the last one recorded). Moved ahead of
  // applyVerification (post-merge cloud review fix, see
  // ancestryRetainedRounds above): fingerprint verification needs the same
  // ancestry-retained set computeVerdict uses, so currentHead/ancestryOpts
  // must exist before it runs, not after.
  const currentHead = args["current-head"];
  if (!currentHead) {
    return indeterminate(args, "--current-head is required (an independently captured value, never derived from a round's own reviewed_head)");
  }
  // A typo'd --current-head (e.g. "typo") was accepted outright, so every
  // real round's reviewed_head silently failed to match it and the
  // trajectory was treated as fully invalidated instead of flagging the
  // malformed input itself. Shepherd-stage cloud finding, confirmed. Same
  // 40-hex-char full-SHA contract this schema family uses elsewhere
  // (ai/schemas/run.schema.json's promotion.head pattern).
  if (!/^[0-9a-f]{40}$/.test(currentHead)) {
    return indeterminate(args, `--current-head must be a full 40-character commit SHA, got ${JSON.stringify(currentHead)}`);
  }

  // --heads and --history are optional evidence dependencies; an unreadable
  // or malformed file should produce the same structured indeterminate
  // result as other failures that prevent exit computation, not an
  // uncaught exception with an empty --json stdout. Shepherd-stage cloud
  // finding, confirmed.
  let headsMap;
  try {
    headsMap = loadHeadsMap(args.heads);
  } catch (err) {
    return indeterminate(args, `--heads could not be read as JSON: ${err.message}`);
  }
  const ancestryOpts = { headsMap, repoRoot: args["repo-root"] };

  let ledger;
  try {
    ledger = loadLedger({ historyFile: args.history, repoRoot: args["repo-root"] });
  } catch (err) {
    return indeterminate(args, `--history could not be read as JSON: ${err.message}`);
  }
  // Fingerprint verification (verifyFingerprint's repeat-of check) must
  // never resolve a target finding from a round computeVerdict would
  // exclude — an ancestry-incomparable or otherwise non-retained round is
  // not part of the trajectory being certified, so a claim referencing one
  // has no legitimate target to verify against, retained or not.
  const { retained: ancestryRetainedForVerification } = ancestryRetainedRounds(rounds, currentHead, ancestryOpts);
  const corrections = applyVerification(ancestryRetainedForVerification, ledger);
  const retainedCompleteRounds = ancestryRetainedForVerification.filter((r) => r.status === "complete");
  const retainedRoundNumbers = retainedCompleteRounds.map((r) => r.round);
  const allCompleteRoundNumbers = rounds.filter((r) => r.status === "complete").map((r) => r.round);
  const retentionChanged =
    retainedRoundNumbers.length !== allCompleteRoundNumbers.length ||
    retainedRoundNumbers.some((round, index) => round !== allCompleteRoundNumbers[index]);
  const verifiedFindings = retainedCompleteRounds.flatMap((r) =>
    r.findings.map((f) => ({
      id: f.id,
      provenance_status: f.provenanceStatus,
      verified_provenance: f.verifiedProvenance,
      fingerprint_status: f.fingerprintStatus,
      verified_fingerprint: f.verifiedFingerprint,
    })),
  );

  // A stage needs verified provenance and fingerprint facts before it can
  // author this round's adjudication. This read-only projection never grants
  // an exit; ordinary computation above still rejects a complete round that
  // lacks an adjudication document.
  if (args["verification-only"]) {
    const incompleteRound = ancestryRetainedForVerification.find((r) => r.status !== "complete");
    const verification = incompleteRound
      ? {
          stage: args.stage,
          outcome: "capped",
          reason: incompleteRound.status.replace("capped/", ""),
          action: "escalate",
          rounds_counted: retainedCompleteRounds.length,
          next_round: null,
          incomplete_round: incompleteRound.round,
          unresolved_slot: incompleteRound.unresolvedSlot,
          substitutions: incompleteRound.substitutions,
          corrections,
          diagnostics,
          verified_findings: verifiedFindings,
        }
      : {
          stage: args.stage,
          outcome: "verification",
          reason: "pre_adjudication",
          action: "adjudicate",
          corrections,
          // Do not offer an adjudication target from an ancestry-invalidated
          // round. applyVerification still receives the full retained
          // ancestry above so repeat/fingerprint facts can be checked, while
          // this projection exposes only the trajectory the caller may now
          // adjudicate.
          verified_findings: verifiedFindings,
        };
    if (retentionChanged) verification.retained_rounds = retainedRoundNumbers;
    if (args.json) console.log(JSON.stringify(verification, null, 2));
    else console.log(`${args.stage}: verification (pre_adjudication)`);
    return incompleteRound ? EXIT_CODES.capped : 0;
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

  // A BACKWARD stage request (--stage challenge while review is already
  // the active transition) resolving to `continue`/dispatch would
  // authorize more challenge work after the run has moved past it — no
  // legitimate exception exists for this direction; a real challenge
  // re-entry must first record its own new transition, at which point
  // activeStage would already read "challenge" again. Scoped to `continue`
  // specifically (not every mismatch) because a backward query correctly
  // reporting an already-settled converged/capped/diverging verdict for a
  // superseded stage is a legitimate retrospective read, not an
  // authorization to dispatch — see stale-pass-after-stage-moved-on.
  // Shepherd-stage cloud finding, confirmed.
  if (activeStage !== null && args.stage !== activeStage && activeStage !== "challenge" && verdict.outcome === "continue") {
    return indeterminate(
      args,
      `--stage ${args.stage} was requested but the trusted receipt sequence's active stage is "${activeStage}" — a backward stage request cannot be authorized to dispatch more work`,
    );
  }

  verdict.corrections = corrections;
  verdict.diagnostics = diagnostics;
  // applyVerification() already computed these per finding; corrections[]
  // only records a MISMATCH (asserted != evidence-derived), so a claim that
  // was simply confirmed as asserted — or left "unverified" because no
  // evidence could decide it — has no other way to reach a caller (or the
  // conformance corpus) short of exposing the full verified state here.
  // The final confidence projection has the same evidence boundary as the
  // pre-adjudication projection above: only complete logical rounds can
  // contribute adjudicated, verified findings. A partial round can still
  // contain a successful finder's raw findings when another configured
  // slot exhausts its fallbacks, but those findings intentionally have no
  // adjudication. They remain in passes/ for the blocker renderer; putting
  // them here would falsely present them as verified adjudication evidence
  // and make the blocker record internally inconsistent.
  verdict.verified_findings = verifiedFindings;
  if (retentionChanged) verdict.retained_rounds = retainedRoundNumbers;

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
  main().then((code) => {
    process.exitCode = code;
  });
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
