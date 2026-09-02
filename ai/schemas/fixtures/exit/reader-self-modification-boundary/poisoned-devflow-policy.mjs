#!/usr/bin/env node
// scripts/devflow-policy.mjs — the shared v2 `.devflow.toml` reader.
//
// Every Dev flow v2 consumer (the exit script, the round-push broker, the
// integrator, the stage skills) resolves policy through this one module
// rather than parsing TOML itself, so shape refusal and resolution never
// drift between consumers (design.md decision 13). See
// openspec/changes/dev-flow-v2/specs/config/spec.md for the normative
// contract this implements, and AGENTS.md "Round caps are resolved, not
// stated here" / "Tier and strategy" for the legacy-repo policy this
// repository's OWN live .devflow.toml still uses (never operated under by
// this module — see "Shape detection" below).
//
// Usable as a CLI (`node scripts/devflow-policy.mjs resolve|detect ...`)
// or as a library (`import { resolvePolicy, detectShape } from
// "./devflow-policy.mjs"`), notably by scripts/dev-flow-exit.mjs.

import { readFileSync, existsSync } from "node:fs";
import { execFileSync, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { parseToml, TomlError } from "./lib/toml-lite.mjs";

export class PolicyError extends Error {}

const ROUND_KEYS = ["challenge", "review", "integration", "remediation", "min_rounds", "wall_clock_min"];
const BREADTH_KEYS = ["max_agent_runs", "max_parallel_agents"];
const GATE_KEYS = ["round_code", "round_docs", "secret_scan", "pre_pr"];
const ROLES = ["orchestrator", "implementer", "challenger", "reviewer", "integrator"];
const CONFIDENCE_STAGES = ["challenge", "review"];
const STAGES = ["implement", "challenge", "review", "integration"];
const PRE_PR_STAGES = new Set(["implement", "challenge", "review"]);
const PREDICATES = new Set(["no_gating_findings", "provenance_share", "count_rising", "repeat_after_fix"]);
// specs/config/spec.md "Rigor uses the revised six-level ladder": rigor_order
// SHALL be exactly this list, weakest to strongest — not merely a nonempty
// array containing the selected level (review round 3, confirmed).
const CANONICAL_RIGOR_ORDER = Object.freeze(["cursory", "light", "standard", "thorough", "deep", "forensic"]);
// specs/dev-flow-v2.md "Convergence model v0" § Finding fields: `class ∈
// design | correctness | consistency | hardening | nit` — the same enum
// ai/schemas/result*.schema.json ships for `finding.class`.
const FINDING_CLASSES = new Set(["design", "correctness", "consistency", "hardening", "nit"]);

// A cap, floor, or breadth ceiling is read from branch-controlled TOML and
// used directly as a loop bound (challenge round 3, confirmed): unvalidated
// it accepts negatives (a negative cap reads as "reached before any round
// ran"), fractions, NaN, and Infinity. Every numeric policy value that gates
// a round or a resource ceiling must be a plain non-negative integer.
function requireNonNegativeInt(value, label, errorPath) {
  if (!Number.isInteger(value) || value < 0) {
    throw new PolicyError(`${errorPath}: "${label}" must be a non-negative integer, got ${JSON.stringify(value)}`);
  }
}

// Built-in defaults supplied only on the historical merge-base decode path
// (legacy/v1 → v2), per the 2026-09-02 lane addenda: the decoder's scope is
// an INVARIANT, not a field list — every merge-base-protected value
// (defaults, rounds, breadth, convergence, gates, roles, stages, strategy,
// tier_order) resolves from the older copy's own semantics (only `rounds`
// and the rigor level name qualify) or from these built-in defaults, NEVER
// from the branch's v2 copy. Where the older shape has no equivalent
// concept at all (breadth, convergence predicates, roles, stages), the
// built-in default below is the only admissible source — decodeHistoricalPolicy()
// never reads those fields from `doc` (the branch copy) to fill the gap.
// These are this module's own documented choice, not a value copied from
// any spec text except where cited — see "## Deferred findings" in the
// shipping PR.
const BUILTIN_GATE_DEFAULTS = {
  round_code: "verify",
  round_docs: "check",
  secret_scan: "security:secrets",
  pre_pr: "security",
  docs_only_paths: ["**/*.md", "docs/**"],
};
// Legacy/v1 shapes have no [rounds].remediation or .wall_clock_min at all
// (remediation is a v2-only finer split of what legacy calls "shepherd";
// wall_clock_min is new in v2 outright). Built-in fallbacks, documented for
// the same reason as the gate defaults above.
const BUILTIN_REMEDIATION_FALLBACK = (integrationCap) => integrationCap;
const BUILTIN_WALL_CLOCK_MIN_FALLBACK = 240;
// No legacy/v1 equivalent of [breadth.*] exists at all (breadth is a v2-only
// axis separating horizontal scale from vertical round appetite —
// design.md decision 2). Matches this module's own SHARED test fixture
// "standard" breadth, chosen as a conservative, unremarkable default.
const BUILTIN_BREADTH_DEFAULT = Object.freeze({ policy: "builtin-default", max_agent_runs: 999999, max_parallel_agents: 999999 });
// tier_order is a spec-pinned constant (specs/dev-flow-v2.md § Configuration:
// "tier_order is local → economy → standard → frontier → apex and is the
// only definition of one-rung escalation"), not a per-repo choice — using it
// here is citing the spec, not inventing a default.
const BUILTIN_TIER_ORDER = Object.freeze(["local", "economy", "standard", "frontier", "apex"]);
// The v0 predicate catalog exactly as specs/dev-flow-v2.md § "Convergence
// model v0" ships it as its own worked example — legacy/v1 have no
// [convergence] table at all, so this is the built-in default rather than
// something decoded from either older shape.
const BUILTIN_CONVERGENCE_DEFAULT = Object.freeze({
  converged: { kind: "all", list: [{ predicate: "no_gating_findings" }] },
  diverging: {
    kind: "any",
    list: [
      { predicate: "count_rising", increases: 2 },
      { predicate: "repeat_after_fix" },
      { predicate: "provenance_share", min: 0.5, exclude_classes: ["design"] },
    ],
  },
  overridden: false,
});
// specs/dev-flow-v2.md § Configuration's own "shipped baselines" for the
// five roles' tiers ("orchestrator apex, implementer standard, challenger
// frontier, reviewer standard, and integrator economy") — legacy/v1 tier
// concepts ([tier.*] family maps, default_tier) are not structurally
// equivalent to v2's per-role [role.<slug>] baseline, so this is the
// built-in default rather than a decoded value. families/harnesses are
// empty: "finders" and "roles" are both named in the addenda as having no
// legacy/v1 equivalent, and no registry-independent default family exists —
// cross-validation against a registry (when supplied) reports the resulting
// unresolvable family honestly rather than inventing one.
const BUILTIN_ROLE_TIER_DEFAULTS = Object.freeze({
  orchestrator: "apex",
  implementer: "standard",
  challenger: "frontier",
  reviewer: "standard",
  integrator: "economy",
});
// No legacy/v1 equivalent of [stage.*] exists. An empty finder set is the
// built-in default; scripts/dev-flow-exit.mjs treats an empty resolved
// finders[] as "no configured authority" and falls back to the observed
// passes' own slots for logical-round assembly rather than trivially
// treating every round as complete.
function builtinStagesDefault() {
  const result = {};
  for (const stage of STAGES) result[stage] = { finders: [], finder_fallbacks: [], pool: null };
  return result;
}
function builtinRolesDefault() {
  const result = {};
  for (const [role, tier] of Object.entries(BUILTIN_ROLE_TIER_DEFAULTS)) {
    result[role] = { tier, source: "builtin-default", families: [], harnesses: [] };
  }
  return result;
}
// No legacy/v1 equivalent of [strategy.*] exists. The simplest, safest
// topology (a single accountable lead, no delegation) is the built-in
// default.
const BUILTIN_STRATEGY_DEFAULT = Object.freeze({
  name: "builtin-default",
  topology: "single-agent",
  planning: "inline",
  delegation: "none",
});

// ---------------------------------------------------------------------------
// Shape detection
// ---------------------------------------------------------------------------

/**
 * Detect which `.devflow.toml` shape a parsed document is, from controlling
 * markers only (never [tier.*], which can occur in either older shape).
 * Returns { shape: "v2"|"v1"|"legacy"|"mixed"|"unknown", markers: string[] }.
 */
export function detectShape(doc) {
  const hasV2 = doc.schema_version === 2;

  const rigorTable = doc.rigor && typeof doc.rigor === "object" ? doc.rigor : {};
  const rigorLevels = Object.keys(rigorTable);

  const hasRigorOrder = Array.isArray(doc.rigor_order);
  const hasReviewTables = !!(doc.review && typeof doc.review === "object" && Object.keys(doc.review).length > 0);
  const hasReviewPointer = rigorLevels.some((l) => typeof rigorTable[l]?.review === "string");
  const v1Markers = [];
  if (hasRigorOrder) v1Markers.push("rigor_order");
  if (hasReviewTables) v1Markers.push("[review.*]");
  if (hasReviewPointer) v1Markers.push("[rigor.<level>].review pointer");
  const hasV1 = hasRigorOrder && hasReviewTables && hasReviewPointer;

  const directCapFields = ["challenge", "review", "shepherd", "min_rounds"];
  const hasDirectCaps = rigorLevels.some((l) => {
    const level = rigorTable[l];
    return level && directCapFields.every((f) => typeof level[f] === "number");
  });
  // Any ONE direct-cap field — not only a complete four-field set — is
  // itself a legacy marker for the mixed-with-v2 check below. Shepherd-
  // stage cloud finding (round 2, about round 1's own single-stray-marker
  // fix), confirmed: hasDirectCaps requires all four fields together, so a
  // lone `challenge = 99` under a v2 [rigor.standard] registered as no
  // marker at all — an incomplete legacy marker set at the level of
  // individual fields, exactly what specs/config/spec.md's "incomplete"
  // text already covers, not only a complete alternate-shape table.
  const hasAnyDirectCapField = rigorLevels.some((l) => {
    const level = rigorTable[l];
    return level && directCapFields.some((f) => typeof level[f] === "number");
  });
  const hasDefaultMethod = typeof doc.default_method === "string";
  const hasMethodTable = !!(doc.method && typeof doc.method === "object");
  const legacyMarkers = [];
  if (hasAnyDirectCapField) legacyMarkers.push("[rigor.<level>] direct cap field(s) (challenge/review/shepherd/min_rounds)");
  if (hasDefaultMethod) legacyMarkers.push("default_method");
  if (hasMethodTable) legacyMarkers.push("[method]");
  const hasLegacy = hasDirectCaps && hasDefaultMethod && hasMethodTable;

  // specs/config/spec.md: "A mixed OR INCOMPLETE marker set SHALL be
  // rejected... not guessed into either shape" — review round 3 closed the
  // COMPLETE-old-shape-alongside-v2 case, but a single coexisting older
  // marker is exactly the spec's "incomplete" case too, not only "every
  // marker of some other complete shape." Shepherd-stage cloud finding,
  // confirmed: checking hasV1/hasLegacy (each requiring ALL of that
  // shape's own markers) let a lone stray marker — e.g. `default_method`
  // alone, with neither direct caps nor a `[method]` table — coexist with
  // `schema_version = 2` and still resolve as pure v2, even though the
  // file literally carries markers from two different shape vocabularies
  // at once. `rigor_order` is the one exception: v2 itself REQUIRES it
  // (resolveRigorLevel), so its mere presence can never signal v1 the way
  // `[review.*]`/the `.review` pointer genuinely do — counting it here
  // would make every valid v2 policy "mixed" (self-caught in this same
  // fix: the hand-rolled test-dev-flow-exit.sh breadth-shortfall check
  // constructs a v2 policy and immediately hit exactly this).
  const hasV1ExclusiveMarker = hasReviewTables || hasReviewPointer;
  if (hasV2 && (hasV1ExclusiveMarker || legacyMarkers.length > 0)) {
    return { shape: "mixed", markers: ["schema_version = 2", ...v1Markers, ...legacyMarkers] };
  }
  if (hasV2) return { shape: "v2", markers: ["schema_version = 2"] };
  if (hasV1 && hasLegacy) return { shape: "mixed", markers: [...v1Markers, ...legacyMarkers] };
  if (hasV1) return { shape: "v1", markers: v1Markers };
  if (hasLegacy) return { shape: "legacy", markers: legacyMarkers };

  const partial = [...v1Markers, ...legacyMarkers];
  return { shape: "unknown", markers: partial };
}

const MIGRATION_DIRECTION =
  "migrate to schema_version = 2 with [rounds.*], [breadth.*], [gates], [convergence], [role.*], and [stage.*] (harmon-init#1081 owns the template)";

export function shapeRefusalMessage(detection, { forOperating = true } = {}) {
  const markers = detection.markers.length > 0 ? detection.markers.join(", ") : "none";
  const scope = forOperating ? "the operating .devflow.toml" : "this .devflow.toml";
  return `${scope} is not schema_version 2 (detected shape: ${detection.shape}; markers found: ${markers}) — ${MIGRATION_DIRECTION}`;
}

/** Require a v2 shape for the *operating* policy; throws PolicyError otherwise. */
export function requireOperatingV2(doc) {
  const detection = detectShape(doc);
  if (detection.shape !== "v2") {
    throw new PolicyError(shapeRefusalMessage(detection, { forOperating: true }));
  }
  return detection;
}

// ---------------------------------------------------------------------------
// v2 resolution
// ---------------------------------------------------------------------------

function resolveRigorLevel(doc, requestedRigor) {
  const order = doc.rigor_order;
  if (!Array.isArray(order) || order.length === 0) {
    throw new PolicyError("policy has no rigor_order ranking");
  }
  // The ladder is a FIXED vocabulary and ordering (specs/config/spec.md),
  // not merely "any nonempty array containing the selected level" — review
  // round 3, confirmed: an arbitrary subset or reordering resolved
  // successfully as long as the requested/default level was present,
  // silently losing the contractually fixed strongest-wins ordering every
  // downstream tier/strategy/method resolution depends on.
  if (order.length !== CANONICAL_RIGOR_ORDER.length || order.some((v, i) => v !== CANONICAL_RIGOR_ORDER[i])) {
    throw new PolicyError(`policy's rigor_order must be exactly [${CANONICAL_RIGOR_ORDER.join(", ")}] (weakest to strongest), got [${order.join(", ")}]`);
  }
  const level = requestedRigor || doc.default_rigor;
  if (!level) throw new PolicyError("no rigor level given and policy has no default_rigor");
  if (!order.includes(level)) {
    throw new PolicyError(`rigor level "${level}" is not in rigor_order (${order.join(", ")})`);
  }
  const profile = doc.rigor?.[level];
  if (!profile || typeof profile !== "object") {
    throw new PolicyError(`rigor level "${level}" has no [rigor.${level}] table`);
  }
  return { level, profile, order };
}

function resolveRounds(doc, profile, levelName) {
  const policyName = profile.rounds;
  if (typeof policyName !== "string") {
    throw new PolicyError(`[rigor.${levelName}] has no "rounds" pointer`);
  }
  const table = doc.rounds?.[policyName];
  if (!table || typeof table !== "object") {
    throw new PolicyError(`[rounds.${policyName}] is missing (pointed to by [rigor.${levelName}])`);
  }
  const rounds = { policy: policyName };
  for (const key of ["challenge", "review", "integration", "min_rounds"]) {
    if (typeof table[key] !== "number") {
      throw new PolicyError(`[rounds.${policyName}] is missing numeric "${key}"`);
    }
    requireNonNegativeInt(table[key], key, `[rounds.${policyName}]`);
    rounds[key] = table[key];
  }
  rounds.remediation =
    typeof table.remediation === "number" ? table.remediation : BUILTIN_REMEDIATION_FALLBACK(rounds.integration);
  requireNonNegativeInt(rounds.remediation, "remediation", `[rounds.${policyName}]`);
  rounds.wall_clock_min = typeof table.wall_clock_min === "number" ? table.wall_clock_min : BUILTIN_WALL_CLOCK_MIN_FALLBACK;
  requireNonNegativeInt(rounds.wall_clock_min, "wall_clock_min", `[rounds.${policyName}]`);
  // specs/config/spec.md: "The forensic rounds policy SHALL require at
  // least two rounds before the empty-round shortcut can end a confidence
  // stage" — review round 3, confirmed: forensic accepted min_rounds 0 or
  // 1 like any other level, letting its first empty round exit through the
  // shortcut the ladder's strongest level is specifically meant to forbid.
  if (levelName === "forensic" && rounds.min_rounds < 2) {
    throw new PolicyError(`[rounds.${policyName}]: forensic rigor requires min_rounds >= 2 (got ${rounds.min_rounds})`);
  }
  return rounds;
}

function resolveBreadth(doc, profile, levelName) {
  const policyName = profile.breadth;
  if (typeof policyName !== "string") {
    throw new PolicyError(`[rigor.${levelName}] has no "breadth" pointer`);
  }
  const table = doc.breadth?.[policyName];
  if (!table || typeof table !== "object") {
    throw new PolicyError(`[breadth.${policyName}] is missing (pointed to by [rigor.${levelName}])`);
  }
  const breadth = { policy: policyName };
  for (const key of BREADTH_KEYS) {
    if (typeof table[key] !== "number") {
      throw new PolicyError(`[breadth.${policyName}] is missing numeric "${key}"`);
    }
    requireNonNegativeInt(table[key], key, `[breadth.${policyName}]`);
    breadth[key] = table[key];
  }
  return breadth;
}

function resolveSpend(doc, profile) {
  const policyName = profile.spend;
  if (typeof policyName !== "string") {
    return { policy: null, max_tokens: null, max_usd: null, status: "UNENFORCED" };
  }
  const table = doc.spend?.[policyName];
  if (!table || typeof table !== "object") {
    throw new PolicyError(`[spend.${policyName}] is missing (named by [rigor.*].spend)`);
  }
  // A present-but-invalid ceiling must not silently become `null` (read as
  // "absent") or be trusted as-is — shepherd-stage cloud finding (round 2,
  // about pre-existing code), confirmed: `status: "UNENFORCED"` today does
  // not make this a dead value; it is a shared resolved-policy field later
  // dispatchers already consume, so a negative/fractional/non-finite
  // max_tokens or a string-valued max_usd must be rejected, not disappear.
  if (table.max_tokens !== undefined) requireNonNegativeInt(table.max_tokens, "max_tokens", `[spend.${policyName}]`);
  if (table.max_usd !== undefined && !(typeof table.max_usd === "number" && Number.isFinite(table.max_usd) && table.max_usd >= 0)) {
    throw new PolicyError(`[spend.${policyName}]: "max_usd" must be a finite non-negative number, got ${JSON.stringify(table.max_usd)}`);
  }
  return {
    policy: policyName,
    max_tokens: typeof table.max_tokens === "number" ? table.max_tokens : null,
    max_usd: typeof table.max_usd === "number" ? table.max_usd : null,
    status: "UNENFORCED",
  };
}

const GATE_SLUG_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*(?::[a-z0-9]+(?:-[a-z0-9]+)*)*$/;

function resolveGates(doc, { allowMissing = false, fallback = null } = {}) {
  const gates = doc.gates;
  if (!gates || typeof gates !== "object") {
    if (allowMissing && fallback) return { ...fallback, source: "built-in-default" };
    throw new PolicyError("policy has no [gates] table");
  }
  const resolved = { source: "policy" };
  for (const key of GATE_KEYS) {
    const value = gates[key];
    if (typeof value !== "string" || value.length === 0) {
      throw new PolicyError(`[gates] is missing string "${key}"`);
    }
    if (!GATE_SLUG_RE.test(value)) {
      throw new PolicyError(
        `[gates].${key} = "${value}" is not a bare Taskfile target slug (no spaces, slashes, or arguments allowed)`,
      );
    }
    resolved[key] = value;
  }
  const docsOnly = gates.docs_only_paths;
  if (!Array.isArray(docsOnly) || docsOnly.length === 0 || docsOnly.some((p) => typeof p !== "string")) {
    throw new PolicyError("[gates].docs_only_paths must be a non-empty array of strings");
  }
  resolved.docs_only_paths = docsOnly;
  return resolved;
}

// specs/dev-flow-v2.md "Convergence model v0" example TOML: `count_rising`
// takes `increases`, `provenance_share` takes `min` (+ optional
// `exclude_classes`); `no_gating_findings`/`repeat_after_fix` take none.
// Unvalidated (challenge round 3, confirmed), a degenerate parameter — e.g.
// `provenance_share.min = 2` — parses cleanly but can never be satisfied,
// silently defeating a divergence predicate it was configured to catch, and
// `count_rising` with a non-positive `increases` drives undefined arithmetic
// in the evaluator.
const PREDICATE_PARAM_VALIDATORS = {
  count_rising(entry, errorPath) {
    if (!Number.isInteger(entry.increases) || entry.increases < 1) {
      throw new PolicyError(`${errorPath}: "increases" must be a positive integer, got ${JSON.stringify(entry.increases)}`);
    }
  },
  provenance_share(entry, errorPath) {
    if (typeof entry.min !== "number" || !Number.isFinite(entry.min) || entry.min < 0 || entry.min > 1) {
      throw new PolicyError(`${errorPath}: "min" must be a number in [0, 1], got ${JSON.stringify(entry.min)}`);
    }
    if (entry.exclude_classes !== undefined) {
      const bad = !Array.isArray(entry.exclude_classes) || entry.exclude_classes.some((c) => !FINDING_CLASSES.has(c));
      if (bad) {
        throw new PolicyError(
          `${errorPath}: "exclude_classes" must be an array drawn from (${[...FINDING_CLASSES].join(", ")}), got ${JSON.stringify(entry.exclude_classes)}`,
        );
      }
    }
  },
};
// Every catalog predicate's own allowed key set, `predicate` included —
// shepherd-stage cloud finding, confirmed: PREDICATE_PARAM_VALIDATORS only
// ever checked its OWN expected keys were present and valid, never that no
// OTHER keys were present, so e.g. `{predicate = "no_gating_findings",
// increases = 99}` resolved cleanly with `increases` silently ignored — a
// misspelled parameter (or one copied from the wrong predicate) can look
// like it tightens convergence while having no effect at all.
const PREDICATE_ALLOWED_KEYS = {
  no_gating_findings: new Set(["predicate"]),
  provenance_share: new Set(["predicate", "min", "exclude_classes"]),
  count_rising: new Set(["predicate", "increases"]),
  repeat_after_fix: new Set(["predicate"]),
};

// Recursive: a composition list entry is either a leaf (`{predicate, ...}`)
// or a nested `{any: [...]} | {all: [...]}` node — specs/dev-flow-v2.md
// normatively incorporates "nested any or all composition" (exit-computation
// spec.md "Scenario: A policy composes predicates from the anchor catalog").
// Round 3 (confirmed): the prior flat-only shape rejected every nested
// composition outright, so no policy could actually use the grammar the spec
// requires every implementation to accept.
function validatePredicateExpr(expr, errorPath) {
  if (!expr || typeof expr !== "object") throw new PolicyError(`${errorPath} must be an object`);
  const kinds = Object.keys(expr).filter((k) => k === "all" || k === "any");
  if (kinds.length !== 1) throw new PolicyError(`${errorPath} must have exactly one of "all"/"any"`);
  const kind = kinds[0];
  const list = expr[kind];
  if (!Array.isArray(list) || list.length === 0) throw new PolicyError(`${errorPath}.${kind} must be a non-empty array`);
  // A predicate name appearing twice in one composition list is rejected
  // outright, not silently collapsed. Shepherd-stage cloud finding (round
  // 2, about round 1's own checkTightenOnly rewrite — but the underlying
  // Map-based `new Map(list.map(e => [e.predicate, e]))` keying predates
  // it), confirmed: keying by predicate name silently kept only the LAST
  // occurrence of a repeated predicate, so checkTightenOnly's base/override
  // comparison never saw the earlier one at all — a base list carrying a
  // predicate twice with different parameters could have its override
  // compared against only one of them, hiding a genuine loosening in the
  // occurrence the comparison never looks at.
  const seenPredicates = new Set();
  for (const entry of list) {
    if (entry && typeof entry === "object" && typeof entry.predicate === "string") {
      if (seenPredicates.has(entry.predicate)) {
        throw new PolicyError(`${errorPath}.${kind} lists predicate "${entry.predicate}" more than once — each predicate may appear at most once per composition list`);
      }
      seenPredicates.add(entry.predicate);
    }
  }
  for (const [i, entry] of list.entries()) {
    const entryPath = `${errorPath}.${kind}[${i}]`;
    if (!entry || typeof entry !== "object") {
      throw new PolicyError(`${entryPath} must be an object`);
    }
    const nestedKinds = Object.keys(entry).filter((k) => k === "all" || k === "any");
    if (nestedKinds.length > 0) {
      if (typeof entry.predicate === "string") {
        throw new PolicyError(`${entryPath} must not mix "predicate" with nested "any"/"all" composition`);
      }
      validatePredicateExpr(entry, entryPath); // recurse; throws on any nested problem
      continue;
    }
    if (typeof entry.predicate !== "string") {
      throw new PolicyError(`${entryPath} must be an object with a "predicate" string, or a nested "any"/"all" composition`);
    }
    if (!PREDICATES.has(entry.predicate)) {
      throw new PolicyError(`${entryPath}.predicate "${entry.predicate}" is not in the v0 catalog (${[...PREDICATES].join(", ")})`);
    }
    PREDICATE_PARAM_VALIDATORS[entry.predicate]?.(entry, entryPath);
    const allowedKeys = PREDICATE_ALLOWED_KEYS[entry.predicate];
    const extraKeys = Object.keys(entry).filter((k) => !allowedKeys.has(k));
    if (extraKeys.length > 0) {
      throw new PolicyError(`${entryPath}: predicate "${entry.predicate}" does not accept parameter(s) ${extraKeys.join(", ")}`);
    }
  }
  return { kind, list };
}

function checkTightenOnly(base, over, stageName, errorPath) {
  if (base.kind !== over.kind) {
    throw new PolicyError(
      `${errorPath}: rigor override changes composition from "${base.kind}" to "${over.kind}", which is not a defined tightening move`,
    );
  }
  const kind = base.kind;
  // A nested any/all node has no `.predicate` identity to key a tighten-only
  // comparison by (every nested node would collide under the same
  // `undefined` key, and "which parameter moved which direction" has no
  // defined meaning across a whole subtree) — refuse rather than silently
  // comparing the wrong things, but ONLY when a nested subtree is itself
  // added, removed, or changed. Shepherd-stage cloud finding, confirmed:
  // the original check refused ANY list containing a nested entry
  // anywhere, in either base or override, even when the override left
  // every nested subtree byte-for-byte untouched and just added a new
  // flat leaf beside it — a well-defined, unambiguous tightening move by
  // the exact same rule already applied to flat-only lists. Nested
  // entries are matched between base and override by full structural
  // identity (no `.predicate` to key by): one present in both lists,
  // unchanged, contributes nothing to added/removed and is not
  // ambiguous; one that differs, or that only one side has, still has no
  // defined tightening direction and is refused exactly as before.
  const isNested = (e) => !e || typeof e !== "object" || typeof e.predicate !== "string";
  const baseFlat = base.list.filter((e) => !isNested(e));
  const overFlat = over.list.filter((e) => !isNested(e));
  const baseNested = base.list.filter(isNested);
  const overNested = over.list.filter(isNested);
  const baseNestedKeys = new Set(baseNested.map((e) => JSON.stringify(e)));
  const overNestedKeys = new Set(overNested.map((e) => JSON.stringify(e)));
  const nestedChanged = baseNested.some((e) => !overNestedKeys.has(JSON.stringify(e))) || overNested.some((e) => !baseNestedKeys.has(JSON.stringify(e)));
  if (nestedChanged) {
    throw new PolicyError(
      `${errorPath}: a nested any/all composition entry was added, removed, or changed by the override — not a supported tightening move`,
    );
  }
  const baseByName = new Map(baseFlat.map((e) => [e.predicate, e]));
  const overByName = new Map(overFlat.map((e) => [e.predicate, e]));
  const added = [...overByName.keys()].filter((k) => !baseByName.has(k));
  const removed = [...baseByName.keys()].filter((k) => !overByName.has(k));

  // converged: all-add / any-remove tightens. diverging: any-add / all-remove tightens.
  const addTightens = (stageName === "converged" && kind === "all") || (stageName === "diverging" && kind === "any");
  const removeTightens = (stageName === "converged" && kind === "any") || (stageName === "diverging" && kind === "all");

  if (added.length > 0 && !addTightens) {
    throw new PolicyError(`${errorPath}: adding ${added.join(", ")} to a "${kind}"-composed ${stageName} list loosens it`);
  }
  if (removed.length > 0 && !removeTightens) {
    throw new PolicyError(`${errorPath}: removing ${removed.join(", ")} from a "${kind}"-composed ${stageName} list loosens it`);
  }

  // Per-parameter comparison for entries present in BOTH lists. Only a
  // verified numeric raise (converged) or lower (diverging) is a
  // recognized tightening move; every other kind of change — dropping a
  // parameter the base declared, adding one the base never had, or
  // changing a non-numeric value (e.g. widening exclude_classes) — has no
  // provably-safe direction, and "anything else is loosening" (the anchor
  // spec's own rule) means it is refused rather than silently accepted.
  // The comparison walks the UNION of base and override keys, not just the
  // override's own — a dropped key is otherwise invisible to a loop that
  // only iterates what the override still declares.
  for (const [name, overEntry] of overByName) {
    const baseEntry = baseByName.get(name);
    if (!baseEntry) continue;
    const allKeys = new Set([...Object.keys(baseEntry), ...Object.keys(overEntry)]);
    for (const key of allKeys) {
      if (key === "predicate") continue;
      const bv = baseEntry[key];
      const ov = overEntry[key];
      if (JSON.stringify(bv) === JSON.stringify(ov)) continue;
      if (typeof bv === "number" && typeof ov === "number") {
        const raises = ov > bv;
        const wantsRaise = stageName === "converged";
        if (raises === wantsRaise) continue;
        throw new PolicyError(`${errorPath}: ${name}.${key} moved from ${bv} to ${ov}, which loosens ${stageName}`);
      }
      throw new PolicyError(
        `${errorPath}: ${name}.${key} changed from ${JSON.stringify(bv)} to ${JSON.stringify(ov)} — only a verified numeric ${
          stageName === "converged" ? "raise" : "lower"
        } is a recognized tightening move for a non-identical parameter`,
      );
    }
  }
}

function resolveConvergence(doc, levelName) {
  const base = doc.convergence;
  if (!base || typeof base !== "object" || !base.converged || !base.diverging) {
    throw new PolicyError("policy has no [convergence] table with converged/diverging");
  }
  const baseConverged = validatePredicateExpr(base.converged, "[convergence].converged");
  const baseDiverging = validatePredicateExpr(base.diverging, "[convergence].diverging");

  const overrideTable = doc.rigor?.[levelName]?.convergence;
  if (!overrideTable) {
    return { converged: baseConverged, diverging: baseDiverging, overridden: false };
  }
  const overConverged = overrideTable.converged
    ? validatePredicateExpr(overrideTable.converged, `[rigor.${levelName}.convergence].converged`)
    : baseConverged;
  const overDiverging = overrideTable.diverging
    ? validatePredicateExpr(overrideTable.diverging, `[rigor.${levelName}.convergence].diverging`)
    : baseDiverging;

  if (overrideTable.converged) checkTightenOnly(baseConverged, overConverged, "converged", `[rigor.${levelName}.convergence]`);
  if (overrideTable.diverging) checkTightenOnly(baseDiverging, overDiverging, "diverging", `[rigor.${levelName}.convergence]`);

  return { converged: overConverged, diverging: overDiverging, overridden: true };
}

function resolveRoles(doc, profile, levelName, tierOrder) {
  const result = {};
  for (const role of ROLES) {
    const profileKey = `${role}_tier`;
    const roleTable = doc.role?.[role] || {};
    const fromProfile = profile[profileKey];
    const tier = fromProfile !== undefined ? fromProfile : roleTable.tier;
    if (typeof tier !== "string") {
      throw new PolicyError(
        `role "${role}" has no resolvable tier: [rigor.${levelName}].${profileKey} and [role.${role}].tier are both absent`,
      );
    }
    if (tier !== "adaptive" && Array.isArray(tierOrder) && !tierOrder.includes(tier)) {
      throw new PolicyError(`role "${role}" tier "${tier}" is not in tier_order (${tierOrder.join(", ")})`);
    }
    result[role] = {
      tier,
      source: fromProfile !== undefined ? "rigor-profile" : "role-baseline",
      families: Array.isArray(roleTable.families) ? roleTable.families : [],
      harnesses: Array.isArray(roleTable.harnesses) ? roleTable.harnesses : [],
    };
  }
  return result;
}

// Present-but-wrong-type SHALL be rejected, never silently widened to the
// absent-key default — review round 3, confirmed: a malformed
// `[stage.implement].pool = "local"` (a string, not an array — a plausible
// typo for a single-entry allowlist) previously became `null` ("no
// restriction", i.e. every implementer-capable harness eligible), turning
// a mistaken narrow allowlist into the WIDEST possible one. Absent stays
// the documented default (`fallback`); present-and-wrong-type is a
// PolicyError.
function resolveStageArray(value, label, fallback) {
  if (value === undefined) return fallback;
  if (!Array.isArray(value)) {
    throw new PolicyError(`${label} must be an array, got ${JSON.stringify(value)}`);
  }
  return value;
}

function resolveStages(doc) {
  const result = {};
  for (const stage of STAGES) {
    const table = doc.stage?.[stage];
    const finders = resolveStageArray(table?.finders, `[stage.${stage}].finders`, []);
    // Each entry in `finders` is its own all-of primary slot (dev-flow-exit.mjs
    // keys logical-round assembly by slot name) — a duplicate slug collapses
    // two nominally distinct slots onto the same map key. Shepherd-stage
    // cloud finding, confirmed: `finders = ["codex-cli", "codex-cli"]`
    // resolved cleanly, let ONE real pass silently satisfy BOTH nominal
    // slots, and breadth's worst-case calculation (finders.length * ...)
    // charged for two slots a single pass could actually fill.
    const dup = finders.find((f, i) => finders.indexOf(f) !== i);
    if (dup !== undefined) {
      throw new PolicyError(`[stage.${stage}].finders contains duplicate primary slot "${dup}" — each finder may fill at most one primary slot`);
    }
    result[stage] = {
      finders,
      finder_fallbacks: resolveStageArray(table?.finder_fallbacks, `[stage.${stage}].finder_fallbacks`, []),
      pool: resolveStageArray(table?.pool, `[stage.${stage}].pool`, null),
    };
  }
  return result;
}

function resolveStrategy(doc, requestedStrategy) {
  const name = requestedStrategy || doc.default_strategy;
  if (!name) return null;
  const table = doc.strategy?.[name];
  if (!table) {
    throw new PolicyError(`strategy "${name}" has no [strategy.${name}] table`);
  }
  // `name` spread AFTER `table` (never before): the selected TOML section
  // key is the authoritative name. A `table` carrying its own `name` field
  // (e.g. `[strategy.council] name = "solo"`) must not be able to overwrite
  // it — spreading `table` first then `name` is what makes the outer
  // assignment win either way. Shepherd-stage cloud finding, confirmed: the
  // old `{ name, ...table }` let exactly that field silently relabel a
  // selected "council" as resolved.strategy.name === "solo", which made
  // crossValidate's council/orchestrate anchor-rule check skip entirely —
  // an incompatible council execution plan would then pass validation.
  return { ...table, name };
}

/**
 * Cross-file validation against the registry and the Taskfile's known
 * target names. `registryDoc` may be null (skip registry-dependent checks —
 * only legitimate when the caller has no registry to check against at all,
 * which is itself reported by the CLI as reduced-confidence, never silent).
 * `taskTargets` is a Set<string> of bare target names, or null.
 */
export function crossValidate(resolved, registryDoc, taskTargets) {
  const errors = [];

  for (const key of GATE_KEYS) {
    const target = resolved.gates[key];
    if (taskTargets && !taskTargets.has(target)) {
      errors.push(`[gates].${key} = "${target}" is not an existing Taskfile target`);
    }
  }
  if (!taskTargets) {
    errors.push("indeterminate: no Taskfile target list was supplied — gate slugs could not be checked");
  }

  // Breadth-sufficiency and stage-has-no-finders use only the
  // already-resolved policy shape (rounds, breadth, stages) — no registry
  // needed — so they run UNCONDITIONALLY, independent of whether a
  // registry was supplied. Review round 1 (confirmed): nesting these under
  // `if (registryDoc)` meant a caller that never supplies a registry
  // (dev-flow-exit.mjs, invoked without ever running `devflow-policy.mjs
  // resolve` first) got no breadth validation at all, letting a policy
  // whose breadth cannot cover its own configured fallback chain — which
  // `devflow-policy.mjs resolve` itself would refuse — silently compute
  // exits anyway (exit-computation spec.md's "Scenario: Breadth cannot
  // cover a configured fallback chain" requires this rejected "before any
  // finder is dispatched", not only when a registry happens to be present).
  for (const stage of CONFIDENCE_STAGES) {
    const s = resolved.stages[stage];
    const cap = resolved.rounds[stage];
    if (cap > 0 && s.finders.length > 0) {
      // "for every finder slot" (exit-computation spec) is a per-slot
      // requirement, not an aggregate one: prove the ceiling covers EACH
      // slot independently attempting its own full primary+retry+fallback
      // chain, not just one slot's chain plus a fallback list shared
      // across every slot — the fallback list is preference-ordered per
      // slot, so the true worst case is every slot separately exhausting
      // it (finders.length primary+retry pairs, each also paying the
      // full fallback chain), never the fallback chain amortized once.
      const worstCase = s.finders.length * (2 + s.finder_fallbacks.length);
      if (resolved.breadth.max_agent_runs < worstCase) {
        errors.push(
          `[breadth.${resolved.breadth.policy}].max_agent_runs (${resolved.breadth.max_agent_runs}) cannot cover ` +
            `stage "${stage}"'s worst-case primary+retry+fallback chain (${worstCase} attempts across ${s.finders.length} finder slot(s), ` +
            `${s.finder_fallbacks.length} fallback(s) each)`,
        );
      }
    }
    // A merge-base HISTORICAL DECODE (decodeHistoricalPolicy, the only
    // source that sets `decodedFrom`) always reports built-in-default empty
    // stage finders by construction — addendum 6 (registry-sourced finders/
    // roles/tiers for the decode path) is deliberately deferred, low
    // priority. That is a documented, deferred LIMITATION, not the kind of
    // genuine "[stage.*] misconfigured" mistake this check exists to catch
    // on the operating v2 path (or a v2-shaped merge-base, which resolves
    // its OWN real stages via resolveV2 and is not exempted here) — review
    // round 2, confirmed: without this exemption, the breadth/finders check
    // this same round's fix made unconditional (see the comment above) made
    // EVERY historical-decode resolution with a nonzero cap fail cross-
    // validation outright, a regression this fix introduced while closing
    // that gap.
    if (cap > 0 && s.finders.length === 0 && resolved.decodedFrom === undefined) {
      errors.push(`[stage.${stage}] has no finders configured but [rounds.${resolved.rounds.policy}].${stage} is ${cap} (> 0)`);
    }
  }

  // specs/dev-flow-v2.md § strategy (verbatim): "Orchestrate requires
  // max_agent_runs >= min_agents and, only under parallel coordination,
  // max_parallel_agents >= min_agents; sequential dispatch needs only the
  // run coverage... A council requiring N distinct families likewise
  // requires... max_agent_runs >= N, plus max_parallel_agents >= N only
  // under parallel coordination. A council with synthesis = true requires
  // max_agent_runs >= N + 1 for the fresh synthesis dispatch." Registry-
  // independent (only resolved.strategy/resolved.breadth), so — like the
  // checks above — this runs unconditionally. Shepherd-stage cloud finding
  // (round 2, about round 1's own anchor-rule check), confirmed: the
  // original formula — carrying a maintainer-relayed simplification, not
  // this spec's own precise text — required max_parallel_agents >=
  // min_agents and (for council) the +1 run UNCONDITIONALLY, rejecting a
  // valid sequential orchestrate or a non-synthesizing council that the
  // spec's own topology/synthesis-conditional rule permits. Other
  // strategies (solo, plan, plan-approved, human-led) declare no
  // min_agents and are unaffected.
  if (resolved.strategy && (resolved.strategy.name === "orchestrate" || resolved.strategy.name === "council")) {
    const { name, min_agents: minAgents, synthesis, coordination } = resolved.strategy;
    if (!Number.isInteger(minAgents) || minAgents < 1) {
      errors.push(`[strategy.${name}].min_agents must be a positive integer, got ${JSON.stringify(minAgents)}`);
    } else {
      const isParallel = coordination === "parallel-when-independent";
      const requiredRuns = name === "council" && synthesis === true ? minAgents + 1 : minAgents;
      const { max_parallel_agents: maxParallel, max_agent_runs: maxRuns, policy: breadthPolicy } = resolved.breadth;
      const unmet = [];
      if (maxRuns < requiredRuns) unmet.push(`max_agent_runs >= ${requiredRuns}`);
      if (isParallel && maxParallel < minAgents) unmet.push(`max_parallel_agents >= ${minAgents}`);
      if (unmet.length > 0) {
        errors.push(
          `strategy "${name}" (min_agents=${minAgents}, coordination=${coordination ?? "sequential"}` +
            `${name === "council" ? `, synthesis=${synthesis === true}` : ""}) is incompatible with ` +
            `[breadth.${breadthPolicy}] (max_parallel_agents=${maxParallel}, max_agent_runs=${maxRuns}): needs ${unmet.join(" and ")}`,
        );
      }
    }
  }

  if (registryDoc) {
    const familySlugs = new Set((registryDoc.families || []).map((f) => f.slug));
    const familyBySlug = new Map((registryDoc.families || []).map((f) => [f.slug, f]));
    const harnessSlugs = new Set((registryDoc.harnesses || []).map((h) => h.slug));
    const harnessBySlug = new Map((registryDoc.harnesses || []).map((h) => [h.slug, h]));
    const finderBySlug = new Map((registryDoc.finders || []).map((f) => [f.slug, f]));

    for (const [role, r] of Object.entries(resolved.roles)) {
      // Same historical-decode exemption as the stage-finders check above,
      // for the same reason: builtinRolesDefault() always reports empty
      // families on that path by construction (addendum 6's registry-
      // sourced roles is deferred) — a documented, deferred limitation,
      // not a genuine [role.*] misconfiguration on the operating path.
      if (r.families.length === 0 && resolved.decodedFrom === undefined) {
        errors.push(`[role.${role}] has no resolvable family: "families" is empty`);
      }
      for (const fam of r.families) {
        if (!familySlugs.has(fam)) errors.push(`[role.${role}].families references unknown family "${fam}"`);
      }
      // Family/harness/tier are checked jointly, not as independent slug
      // memberships — shepherd-stage cloud finding, confirmed: existence
      // checks alone let a role select a harness whose registry-declared
      // family_constraint excludes every family the role itself declared,
      // or a harness whose own `roles[]` list does not include this role
      // (e.g. an implementer-only harness assigned to `reviewer`), or a
      // tier no model in any of the role's families can ever provide —
      // every one of those resolves with no cross-validation error today.
      for (const h of r.harnesses) {
        const harness = harnessBySlug.get(h);
        if (!harness) {
          errors.push(`[role.${role}].harnesses references unknown harness "${h}"`);
          continue;
        }
        if (Array.isArray(harness.roles) && !harness.roles.includes(role)) {
          errors.push(`[role.${role}].harnesses includes "${h}", whose registry entry permits only role(s) ${harness.roles.join(", ")}`);
        }
        // "broker" family_constraint means the harness resolves its family
        // at runtime (no fixed family to check against); only "fixed"
        // constrains which of the role's own families can satisfy it.
        if (harness.family_constraint?.kind === "fixed") {
          const fixedFamily = harness.family_constraint.family;
          if (!r.families.includes(fixedFamily)) {
            errors.push(
              `[role.${role}].harnesses includes "${h}", whose family_constraint fixes family "${fixedFamily}", ` +
                `not among [role.${role}].families (${r.families.join(", ") || "none"})`,
            );
          }
        }
      }
      // A family's own `models[].tier` list is additive, like `finder.stages`
      // above: a registry that doesn't populate it (or doesn't populate it
      // for any family this role declares) carries no tier-achievability
      // evidence either way and is unrestricted, not an error. Only once at
      // least one declared family DOES carry model-tier data does an
      // unachievable tier become checkable — and, having that data, refused.
      if (r.tier !== "adaptive" && r.families.length > 0) {
        const tierAwareFamilies = r.families.filter((famSlug) => Array.isArray(familyBySlug.get(famSlug)?.models));
        if (tierAwareFamilies.length > 0) {
          const achievable = tierAwareFamilies.some((famSlug) => familyBySlug.get(famSlug).models.some((m) => m.tier === r.tier));
          if (!achievable) {
            errors.push(`[role.${role}] tier "${r.tier}" is not achievable by any model in its declared families (${r.families.join(", ")})`);
          }
        }
      }
    }

    for (const [stage, s] of Object.entries(resolved.stages)) {
      const allFinders = [...s.finders, ...s.finder_fallbacks];
      for (const slug of allFinders) {
        const finder = finderBySlug.get(slug);
        if (!finder) {
          errors.push(`[stage.${stage}] references unknown finder "${slug}"`);
          continue;
        }
        if (PRE_PR_STAGES.has(stage) && finder.surface === "pr-cloud") {
          errors.push(
            `[stage.${stage}] finders/finder_fallbacks includes "${slug}", whose surface is pr-cloud, on a pre-PR stage`,
          );
        }
        // A finder's own registry entry may restrict which stages it may
        // serve (agent-registry.json #635/PR #713's finder.stages) — review
        // round 2, confirmed: existence and the pr-cloud check alone let a
        // finder configured for a DIFFERENT stage (e.g. challenge-only) be
        // dispatched here anyway. Absent (registries predating this field)
        // means unrestricted, matching every other additive field in this
        // family.
        if (Array.isArray(finder.stages) && !finder.stages.includes(stage)) {
          errors.push(`[stage.${stage}] finders/finder_fallbacks includes "${slug}", whose registry entry permits only stage(s) ${finder.stages.join(", ")}`);
        }
      }
      if (s.pool) {
        for (const slug of s.pool) {
          if (!harnessSlugs.has(slug)) {
            errors.push(`[stage.${stage}].pool references unknown harness "${slug}"`);
          }
        }
      }
    }
  } else {
    errors.push("indeterminate: no registry was supplied — finders/pools/families/harnesses could not be checked");
  }

  return errors;
}

/**
 * Resolve a v2-shaped, already-detected-as-v2 document into the full policy
 * shape. Throws PolicyError on any structural problem. Does not run
 * crossValidate — callers that have a registry/task-target list call that
 * separately and decide whether "indeterminate" blocks them.
 */
export function resolveV2(doc, { rigor: requestedRigor, strategy: requestedStrategy } = {}) {
  const { level, profile, order } = resolveRigorLevel(doc, requestedRigor);
  const rounds = resolveRounds(doc, profile, level);
  const breadth = resolveBreadth(doc, profile, level);
  const spend = resolveSpend(doc, profile);
  const gates = resolveGates(doc);
  const convergence = resolveConvergence(doc, level);
  const tierOrder = doc.tier_order;
  if (!Array.isArray(tierOrder) || tierOrder.length === 0) {
    throw new PolicyError("policy has no tier_order ranking");
  }
  // tier_order is a spec-pinned constant (BUILTIN_TIER_ORDER's own comment:
  // "the ONLY definition of one-rung escalation"), not a per-repo choice —
  // exactly like rigor_order, it must equal the canonical ladder exactly,
  // not merely be nonempty. Shepherd-stage cloud finding, confirmed: a
  // reversed list, or one containing only `local`, resolved with no
  // cross-validation error, letting strongest-wins conflicts and one-rung
  // escalation silently select weaker tiers or lose required rungs.
  if (tierOrder.length !== BUILTIN_TIER_ORDER.length || tierOrder.some((v, i) => v !== BUILTIN_TIER_ORDER[i])) {
    throw new PolicyError(`policy's tier_order must be exactly [${BUILTIN_TIER_ORDER.join(", ")}] (weakest to strongest), got [${tierOrder.join(", ")}]`);
  }
  const roles = resolveRoles(doc, profile, level, tierOrder);
  const stages = resolveStages(doc);
  const strategy = resolveStrategy(doc, requestedStrategy);

  return {
    source: "operating",
    rigor: { level, order, tier_escalation: profile.tier_escalation === true },
    rounds,
    breadth,
    spend,
    gates,
    convergence,
    tier_order: tierOrder,
    roles,
    stages,
    strategy,
  };
}

// ---------------------------------------------------------------------------
// Historical merge-base decode (legacy/v1 → v2), reachable only from the
// merge-base path — see the "Merge-base rule" section of resolvePolicy()
// below. Never invoked for the operating policy.
// ---------------------------------------------------------------------------

function decodeLegacyRounds(doc, levelName) {
  const level = doc.rigor?.[levelName];
  if (!level || typeof level !== "object") {
    throw new PolicyError(`merge-base legacy policy has no [rigor.${levelName}] table`);
  }
  for (const key of ["challenge", "review", "shepherd", "min_rounds"]) {
    if (typeof level[key] !== "number") {
      throw new PolicyError(`merge-base legacy [rigor.${levelName}] is missing numeric "${key}"`);
    }
    requireNonNegativeInt(level[key], key, `merge-base legacy [rigor.${levelName}]`);
  }
  return {
    policy: `legacy:${levelName}`,
    challenge: level.challenge,
    review: level.review,
    integration: level.shepherd,
    remediation: BUILTIN_REMEDIATION_FALLBACK(level.shepherd),
    min_rounds: level.min_rounds,
    wall_clock_min: BUILTIN_WALL_CLOCK_MIN_FALLBACK,
    // Decoder-only marker (see decodeHistoricalPolicy's own comment): legacy
    // had ONE undifferentiated "shepherd" cap, never two independent ones,
    // so integration and remediation here are not separate budgets that
    // each independently allow N actions — together they must never permit
    // more than N total. The unit charged against that shared total is one
    // legacy ROUND: one fix push, or one no-change cycle where nothing
    // needed fixing (AGENTS.md's legacy shepherd definition, carried
    // forward unchanged by this decode). A Codex cycle that surfaces a
    // finding and the fix push that answers it are the SAME round, charged
    // once — never two separate charges for one cycle-then-fix sequence.
    shared_budget: true,
  };
}

function decodeV1Rounds(doc, levelName) {
  const level = doc.rigor?.[levelName];
  if (!level || typeof level !== "object" || typeof level.review !== "string") {
    throw new PolicyError(`merge-base v1 policy has no [rigor.${levelName}].review pointer`);
  }
  const policyName = level.review;
  const table = doc.review?.[policyName];
  if (!table || typeof table !== "object") {
    throw new PolicyError(`merge-base v1 policy has no [review.${policyName}] (pointed to by [rigor.${levelName}].review)`);
  }
  for (const key of ["challenge", "review", "shepherd", "min_rounds"]) {
    if (typeof table[key] !== "number") {
      throw new PolicyError(`merge-base v1 [review.${policyName}] is missing numeric "${key}"`);
    }
    requireNonNegativeInt(table[key], key, `merge-base v1 [review.${policyName}]`);
  }
  return {
    policy: `v1:${policyName}`,
    challenge: table.challenge,
    review: table.review,
    integration: table.shepherd,
    remediation: BUILTIN_REMEDIATION_FALLBACK(table.shepherd),
    min_rounds: table.min_rounds,
    wall_clock_min: BUILTIN_WALL_CLOCK_MIN_FALLBACK,
    // Decoder-only marker — see decodeLegacyRounds's comment; v1's
    // [review.<policy>] carried the identical single undifferentiated
    // "shepherd" cap legacy did.
    shared_budget: true,
  };
}

/**
 * Decode a merge-base `.devflow.toml` that is NOT v2 (legacy or v1) into a
 * COMPLETE v2-shaped resolution. Per the lane addenda, the decoder's scope
 * is an invariant, not a field list: every field is populated from either
 * the older shape's own semantics (rounds, the rigor level name) or a fixed
 * built-in default (breadth, convergence, gates, roles, stages, strategy,
 * tier_order) — this function never reads a field it cannot decode from
 * `doc` and falls back to reading the BRANCH copy instead; it uses the
 * BUILTIN_* constants above unconditionally. Only reachable via the
 * merge-base path in resolvePolicy(); never call this for an operating
 * policy (see requireOperatingV2 above).
 */
export function decodeHistoricalPolicy(doc, detection, { rigor: requestedRigor } = {}) {
  if (detection.shape !== "legacy" && detection.shape !== "v1") {
    throw new PolicyError(`cannot decode a "${detection.shape}"-shaped merge-base policy (only legacy and v1 are decodable)`);
  }
  const level = requestedRigor || doc.default_rigor;
  if (!level) throw new PolicyError("no rigor level given and merge-base policy has no default_rigor");

  const rounds = detection.shape === "legacy" ? decodeLegacyRounds(doc, level) : decodeV1Rounds(doc, level);
  const gates = resolveGates(doc, { allowMissing: true, fallback: BUILTIN_GATE_DEFAULTS });

  return {
    source: `merge-base-historical-decode:${detection.shape}`,
    rigor: { level, order: null, tier_escalation: false },
    rounds,
    breadth: { ...BUILTIN_BREADTH_DEFAULT },
    spend: { policy: null, max_tokens: null, max_usd: null, status: "UNENFORCED" },
    gates,
    convergence: {
      converged: { ...BUILTIN_CONVERGENCE_DEFAULT.converged },
      diverging: { ...BUILTIN_CONVERGENCE_DEFAULT.diverging },
      overridden: false,
    },
    tier_order: [...BUILTIN_TIER_ORDER],
    roles: builtinRolesDefault(),
    stages: builtinStagesDefault(),
    strategy: { ...BUILTIN_STRATEGY_DEFAULT },
    decodedFrom: detection.shape,
  };
}

// ---------------------------------------------------------------------------
// Top-level resolve(): operating-path shape gate + optional merge-base rule
// ---------------------------------------------------------------------------

/**
 * doc: the parsed operating (branch/working-tree) policy — MUST be v2.
 * opts:
 *   - rigor, strategy: requested overrides (else default_rigor/default_strategy)
 *   - mergeBaseDoc: parsed merge-base policy, when the diff under review
 *     touches .devflow.toml or agent-registry.json. When given, resolution
 *     uses ITS content instead of `doc`'s — v2-shaped merge-base content
 *     resolves normally; legacy/v1-shaped merge-base content is decoded
 *     via decodeHistoricalPolicy(). `doc` is still required to be v2 (the
 *     operating-path gate applies regardless of whether the merge-base
 *     rule also applies).
 */
export function resolvePolicy(doc, opts = {}) {
  requireOperatingV2(doc);

  if (!opts.mergeBaseDoc) {
    return resolveV2(doc, opts);
  }

  // requireOperatingV2 above only checks doc's SHAPE MARKER, never that it
  // actually resolves — the merge-base rule protects which VALUES govern
  // review, not whether the branch's own v2 content is well-formed. A
  // branch doc carrying nothing but `schema_version = 2` would otherwise
  // resolve successfully here (borrowing the merge-base's real values) and
  // then fail every future resolution the moment this PR merges and there
  // is no more merge-base to fall back to. Resolve doc for its own sake —
  // the result is discarded, this call exists only to throw if doc itself
  // is not independently well-formed. Shepherd-stage cloud finding (round
  // 2, about round 1's own fix), confirmed: this validation must run for
  // EVERY merge-base branch, not only the v2 one — a legacy/v1 merge-base
  // (the more common migration shape, since that is what this whole
  // decoder exists for) skipped it entirely.
  resolveV2(doc, opts);

  const mbDetection = detectShape(opts.mergeBaseDoc);
  if (mbDetection.shape === "v2") {
    return { ...resolveV2(opts.mergeBaseDoc, opts), source: "merge-base" };
  }
  if (mbDetection.shape === "legacy" || mbDetection.shape === "v1") {
    return decodeHistoricalPolicy(opts.mergeBaseDoc, mbDetection, opts);
  }
  throw new PolicyError(
    `merge-base .devflow.toml is ${shapeRefusalMessage(mbDetection, { forOperating: false })} and cannot be decoded`,
  );
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

// Deliberately never falls back to running `task --list --json` in the
// caller's own cwd: per the lane addenda, this reader must be runnable from
// a materialized merge-base tree and must not resolve anything relative to
// the worktree it happens to be invoked from. A caller either hands over a
// precomputed target list (--task-targets, e.g. from `task --list --json`
// run inside an extracted merge-base closure) or an explicit directory to
// run `task` against (--taskfile-dir, go-task's own `--dir`); with neither,
// gate-slug checking is indeterminate rather than silently cwd-scoped.
function readTaskTargets(explicitFile, taskfileDir) {
  if (explicitFile) {
    const list = JSON.parse(readFileSync(explicitFile, "utf8"));
    return new Set(list);
  }
  if (taskfileDir) {
    try {
      const out = execFileSync("task", ["--dir", taskfileDir, "--list", "--json"], { encoding: "utf8" });
      const parsed = JSON.parse(out);
      return new Set((parsed.tasks || []).map((t) => t.name));
    } catch {
      return null;
    }
  }
  return null;
}

function parseArgs(argv) {
  const args = { _: [] };
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
    } else {
      args._.push(a);
    }
  }
  return args;
}

function loadTomlFile(filePath) {
  const text = readFileSync(filePath, "utf8");
  return parseToml(text);
}

function cliDetect(args) {
  const doc = loadTomlFile(args.policy);
  const detection = detectShape(doc);
  if (args.json) {
    console.log(JSON.stringify(detection));
  } else {
    console.log(`shape: ${detection.shape}`);
    console.log(`markers: ${detection.markers.join(", ") || "none"}`);
  }
  return detection.shape === "v2" ? 0 : 1;
}

function cliResolve(args) {
  if (!args.policy) {
    console.error("devflow-policy resolve: --policy <file> is required");
    return 2;
  }
  let doc;
  try {
    doc = loadTomlFile(args.policy);
  } catch (err) {
    console.error(`devflow-policy: could not read/parse --policy: ${err.message}`);
    return 2;
  }

  let mergeBaseDoc = null;
  if (args["merge-base-policy"]) {
    try {
      mergeBaseDoc = loadTomlFile(args["merge-base-policy"]);
    } catch (err) {
      console.error(`devflow-policy: could not read/parse --merge-base-policy: ${err.message}`);
      return 2;
    }
  }

  let resolved;
  try {
    resolved = resolvePolicy(doc, {
      rigor: args.rigor,
      strategy: args.strategy,
      mergeBaseDoc,
    });
  } catch (err) {
    if (err instanceof PolicyError || err instanceof TomlError) {
      console.error(`devflow-policy: ${err.message}`);
      return 1;
    }
    throw err;
  }

  // Runs even against a historical-decode result: its roles/stages are the
  // built-in defaults (empty families, empty finders), so cross-validation
  // honestly reports them as unresolvable rather than skipping the check.
  const registryPath = args["merge-base-registry"] || args.registry;
  let registryDoc = null;
  if (registryPath) {
    try {
      registryDoc = JSON.parse(readFileSync(registryPath, "utf8"));
    } catch (err) {
      console.error(`devflow-policy: could not read/parse --registry: ${err.message}`);
      return 2;
    }
  }
  const taskTargets = readTaskTargets(args["task-targets"], args["taskfile-dir"]);
  const crossErrors = crossValidate(resolved, registryDoc, taskTargets);

  const indeterminate = crossErrors.filter((e) => e.startsWith("indeterminate:"));
  const hardErrors = crossErrors.filter((e) => !e.startsWith("indeterminate:"));

  const output = { ...resolved, cross_validation: { errors: hardErrors, indeterminate } };

  if (args.json) {
    console.log(JSON.stringify(output, null, 2));
  } else {
    console.log(`rigor: ${resolved.rigor.level} (source: ${resolved.source})`);
    console.log(
      `rounds[${resolved.rounds.policy}]: challenge<=${resolved.rounds.challenge} review<=${resolved.rounds.review} ` +
        `integration<=${resolved.rounds.integration} remediation<=${resolved.rounds.remediation} ` +
        `min_rounds=${resolved.rounds.min_rounds} wall_clock_min=${resolved.rounds.wall_clock_min}`,
    );
    if (resolved.breadth) {
      console.log(`breadth[${resolved.breadth.policy}]: max_agent_runs=${resolved.breadth.max_agent_runs} max_parallel_agents=${resolved.breadth.max_parallel_agents}`);
    }
    console.log(`spend: ${resolved.spend.status}${resolved.spend.policy ? ` (${resolved.spend.policy})` : ""}`);
    console.log(`gates[${resolved.gates.source}]: round_code=${resolved.gates.round_code} round_docs=${resolved.gates.round_docs} secret_scan=${resolved.gates.secret_scan} pre_pr=${resolved.gates.pre_pr}`);
    if (hardErrors.length > 0) {
      console.log("cross-validation errors:");
      for (const e of hardErrors) console.log(`  - ${e}`);
    }
    if (indeterminate.length > 0) {
      console.log("cross-validation indeterminate:");
      for (const e of indeterminate) console.log(`  - ${e}`);
    }
  }

  if (hardErrors.length > 0) return 1;
  if (indeterminate.length > 0) return 3;
  return 0;
}

// The self-modification boundary protects the READER itself, not only the
// TOML/JSON data it reads: a change touching devflow-policy.mjs, .devflow.toml,
// or agent-registry.json must resolve under the merge-base copy of ALL
// three, because a branch could otherwise lower its own gate by editing the
// resolution CODE instead of the config data (the identical concern the
// merge-base rule already applies to .devflow.toml/agent-registry.json —
// see AGENTS.md's "Self-modified policy is read from the merge base"). This
// is the one thing running this SAME (possibly branch-modified) file cannot
// prove about itself, so `--closure <dir>` re-execs the TRUSTED copy at
// `<dir>/scripts/devflow-policy.mjs` — materialized outside the worktree by
// the caller (e.g. `git show <merge-base>:scripts/devflow-policy.mjs`, the
// same closure that supplies the merge-base .devflow.toml/agent-registry.json)
// — before this file's own (possibly untrusted) code has done anything else
// with the arguments. Checked first, ahead of every other line of main().
function tryDelegateToClosure(argv) {
  const idx = argv.indexOf("--closure");
  if (idx === -1) return null;
  const closureDir = argv[idx + 1];
  if (!closureDir) {
    console.error("devflow-policy: --closure requires a directory argument");
    return 1;
  }
  const trustedScript = path.join(closureDir, "scripts", "devflow-policy.mjs");
  if (!existsSync(trustedScript)) {
    // A merge base that predates this reader's own existence (this change
    // may be the one introducing it) has no trusted copy to delegate to at
    // all — refuse outright rather than falling through to the untrusted
    // branch copy, which is exactly the gate a missing merge-base reader
    // would otherwise let a self-modifying branch bypass.
    console.error(
      `devflow-policy: --closure directory has no scripts/devflow-policy.mjs (${closureDir}) — the reader must land on the merge base before a self-referential check can run; never falling back to the branch copy`,
    );
    return 1;
  }
  const passthrough = [...argv.slice(0, idx), ...argv.slice(idx + 2)];
  const result = spawnSync(process.execPath, [trustedScript, ...passthrough], { stdio: "inherit" });
  if (result.error) {
    console.error(`devflow-policy: could not exec the --closure reader: ${result.error.message}`);
    return 1;
  }
  return result.status === null ? 1 : result.status;
}

function main() {
  const argv = process.argv.slice(2);
  const delegated = tryDelegateToClosure(argv);
  if (delegated !== null) return delegated;

  const cmd = argv[0];
  const args = parseArgs(argv.slice(1));
  if (cmd === "detect") return cliDetect(args);
  if (cmd === "resolve") return cliResolve(args);
  console.error("usage: devflow-policy.mjs <detect|resolve> --policy <file> [options]");
  return 2;
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isMain) {
  process.exitCode = main();
}
