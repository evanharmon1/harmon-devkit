#!/usr/bin/env node
// tier-inputs.mjs — the CONSUMER half of tier resolution (harmon-devkit#1248).
//
// devflow-policy.mjs owns the resolution ORDER (operator > pinned Tier >
// rigor:*/tier:<role>:* > derived Tier > default_rigor), the derive-on-read
// rule, the pin's two-part provenance check, and disclosure. It deliberately
// reads no labels and no issue fields: label parsing and label CONFLICTS are
// the consumer's to settle before it calls the reader (ADR 2026-09-30; the
// reference consumer is harmon-init's conformance runner, `v2_case_inputs`).
// This helper is that consumer for /orchestrate and /implement, so both stage
// skills translate an issue the same way and the translation is tested.
//
// `--policy <.devflow.toml>` is required: a rigor:/strategy: label naming no
// [rigor.*]/[strategy.*] table there is dropped with a `*-label-unknown`
// warning rather than forwarded (AGENTS.md: such a value "is ignored rather
// than guessed at"); a policy file that does not exist means the built-in
// fallback's standard rigor and plan strategy only.
//
// Input (JSON, on stdin or from --input <file>):
//   {
//     "labels":   ["tier:standard", "tier:pinned", "risk:high", ...],
//                 // every label on the issue; non-policy labels are ignored
//     "authorized_labels": ["rigor:deep", "tier:implementer:frontier", ...],
//                 // the execution-policy labels (rigor:*, strategy:*,
//                 // tier:<role>:*) whose provenance the consumer verified.
//                 // Fail-closed: one missing here is dropped with a
//                 // policy-label-unauthorized warning. risk:*, complexity:*
//                 // and the stored tier:<value> are never gated (ADR
//                 // 2026-09-30 D3).
//     "fields":   { "risk": "high", "complexity": "m" },
//                 // optional: org-repository issue fields. A present field is
//                 // the storage of record and wins over a same-axis label.
//     "operator": { "rigor": "deep", "strategy": "plan",
//                   "tiers": { "implementer": "frontier" } },
//                 // optional: attributable operator instructions only, never
//                 // anything read from issue or PR text
//     "pin_provenance": { "marker_trusted": true, "value_trusted": true }
//                 // optional: whether the consumer verified who applied the
//                 // tier:pinned marker and the pinned tier:<value> label
//   }
//
// Output (JSON on stdout): { "args": [...reader flags], "warnings": [...],
// "inputs": {...} } — append `args` to `devflow-policy.mjs resolve`, and carry
// every warning into the PR-body disclosure alongside the reader's own
// `warnings`/`disclosures`. Exit 0 on success, 2 on malformed input.
//
// `tier-inputs.mjs disclose --inputs <translation.json> --resolved <resolve.json>`
// renders the PR-body tier disclosure from that translation plus the reader's
// `resolve --json` output: the implementer's tier SOURCE (pinned, rigor,
// derived, default — or operator), any pin-caused invariant break, any
// overridden tier:<role>:* label, and every warning (disclosureLines()).
//
// What it decides, mirroring the runner and the issue's acceptance criteria:
//   - An unqualified tier:<value> is the issue's STORED Tier (a cache), never
//     a role override. Without tier:pinned it is passed as --stored-tier.
//   - tier:pinned + exactly one unqualified value: --pinned-tier <value>,
//     with --pin-marker-trusted/--pin-value-trusted only as verified.
//   - tier:pinned + MORE than one unqualified value: the pin is AMBIGUOUS —
//     no --pinned-tier, a warning naming the values, and the issue resolves
//     through its derived Tier (Risk × Complexity).
//   - tier:<role>:<value> labels: one per role; a conflict resolves to the
//     strongest on tier_order (a conflict only ever buys more capability).
//   - rigor:* label conflicts resolve to the strongest on rigor_order; two
//     different strategy:* labels are ambiguous and pass none (the policy
//     default applies, with a warning).
//   - risk:<v>/complexity:<v> labels (personal repositories) or fields (org
//     repositories) become --risk/--complexity; two different values for one
//     axis (or a non-slug value) pass the off-scale `conflict` sentinel, so
//     the READER reports the derived Tier indeterminate — never "absent",
//     which would silently resolve the default tier.
// Values are passed with the `--opt=value` spelling, so a label value can
// never be read by the reader as a flag of its own.

import { readFileSync, realpathSync } from "node:fs";
import { parseToml } from "./lib/toml-lite.mjs";
import { fileURLToPath } from "node:url";

// The same ladders devflow-policy.mjs requires a v2 policy to declare
// exactly (its CANONICAL_RIGOR_ORDER and BUILTIN_TIER_ORDER).
export const RIGOR_ORDER = Object.freeze(["cursory", "light", "standard", "thorough", "deep", "forensic"]);
export const TIER_ORDER = Object.freeze(["local", "economy", "standard", "frontier", "apex"]);
export const ROLES = Object.freeze(["orchestrator", "implementer", "challenger", "reviewer", "integrator"]);
// A label value is a slug. Anything else is reported and dropped rather than
// handed to a CLI.
const SLUG = /^[a-z0-9][a-z0-9_.-]*$/;
// Off both classification scales (RISK_SCALE, COMPLEXITY_SCALE in
// devflow-policy.mjs), so the reader reports any axis carrying it as an
// indeterminate derived Tier rather than as an unclassified issue.
export const CLASSIFICATION_CONFLICT = "conflict";

export class TierInputError extends Error {}

function warning(code, message) {
  return { code, message };
}

function uniq(values) {
  return [...new Set(values)];
}

function strongest(values, ladder) {
  let best = null;
  for (const value of values) {
    if (ladder.indexOf(value) > ladder.indexOf(best ?? "")) best = value;
  }
  return best;
}

/**
 * Translate an issue's labels, fields, and operator instructions into
 * devflow-policy.mjs resolve flags. Pure: no I/O, no GitHub reads.
 */
export function tierInputs({
  labels = [],
  authorized_labels: authorizedLabels = [],
  fields = {},
  operator = {},
  pin_provenance: provenance = {},
  policy = null,
} = {}) {
  if (!Array.isArray(labels) || labels.some((l) => typeof l !== "string")) {
    throw new TierInputError("labels must be an array of strings");
  }
  if (!Array.isArray(authorizedLabels) || authorizedLabels.some((l) => typeof l !== "string")) {
    throw new TierInputError("authorized_labels must be an array of strings");
  }
  for (const [name, value] of [
    ["fields", fields],
    ["operator", operator],
    ["pin_provenance", provenance],
  ]) {
    if (value === null || typeof value !== "object" || Array.isArray(value)) {
      throw new TierInputError(`${name} must be an object`);
    }
  }
  if (policy !== null) {
    for (const key of ["rigors", "strategies"]) {
      if (!Array.isArray(policy[key]) || policy[key].some((v) => typeof v !== "string")) {
        throw new TierInputError(`policy.${key} must be an array of strings`);
      }
    }
  }
  const warnings = [];
  const args = [];
  const inputs = {};
  // A rigor:/strategy: label value that names nothing in the governing
  // policy is IGNORED rather than guessed at (AGENTS.md "Rigor and
  // Strategy") — forwarded, the reader would refuse the whole resolution
  // over a stale label (challenge round 1, C1-2). Without a policy summary
  // only the canonical rigor ladder can be checked. Operator values are
  // never filtered: an operator typo should fail loudly in the reader.
  const rigorNamed = (v) => RIGOR_ORDER.includes(v) && (policy === null || policy.rigors.includes(v));
  const strategyNamed = (v) => policy === null || policy.strategies.includes(v);
  const rigorOrder = policy?.rigor_order ?? RIGOR_ORDER;

  const rigorLabels = [];
  const strategyLabels = [];
  const storedTierLabels = [];
  const roleLabels = new Map();
  const axisLabels = { risk: [], complexity: [] };
  let pinned = false;

  // EXECUTION-POLICY labels (rigor:*, strategy:*, tier:<role>:*) are honored
  // only when the consumer verified their provenance and listed them in
  // `authorized_labels` — an interactive session from operator
  // confirmation, unattended automation from its own trusted-actor check
  // re-read immediately before acting (AGENTS.md "Nothing here arms
  // anything"). Fail-closed: an unlisted one is dropped with a warning and
  // the profile/default applies, so a label nobody vouched for can neither
  // spend money nor skip oversight by omission (challenge round 2, C2-1).
  // The CLASSIFICATION inputs — risk:*, complexity:*, and the unqualified
  // tier:<value> stored Tier — are deliberately ungated: ADR 2026-09-30 D3
  // lets an AI or a human set them with no safeguard, and the stored Tier is
  // only a cache of Risk × Complexity. The pin keeps its own two-part check
  // (`pin_provenance`).
  const authorized = new Set(authorizedLabels);
  const unauthorized = [];
  const policyLabel = (label) => {
    if (authorized.has(label)) return true;
    unauthorized.push(label);
    return false;
  };

  // No label is dropped here for being malformed: an empty value (`tier:`,
  // `risk:`) is recorded RAW in its family, so it still counts toward that
  // family's ambiguity and is refused only when a value is forwarded (the
  // property review round 2, R2-1, established — see the stored Tier below).
  for (const label of labels) {
    const parts = label.split(":");
    if (parts.length === 2 && parts[0] === "rigor") {
      if (policyLabel(label)) rigorLabels.push(parts[1]);
    } else if (parts.length === 2 && parts[0] === "strategy") {
      if (policyLabel(label)) strategyLabels.push(parts[1]);
    }
    else if (parts.length === 2 && (parts[0] === "risk" || parts[0] === "complexity")) axisLabels[parts[0]].push(parts[1]);
    else if (label === "tier:pinned") pinned = true;
    else if (parts.length === 2 && parts[0] === "tier") storedTierLabels.push(parts[1]);
    else if (parts.length === 3 && parts[0] === "tier" && ROLES.includes(parts[1])) {
      if (!policyLabel(label)) continue;
      if (!roleLabels.has(parts[1])) roleLabels.set(parts[1], []);
      roleLabels.get(parts[1]).push(parts[2]);
    }
  }
  if (unauthorized.length > 0) {
    warnings.push(
      warning(
        "policy-label-unauthorized",
        `execution-policy label(s) ${unauthorized.join(", ")} carry no verified provenance and are ignored; the profile/default applies — an interactive session confirms them with the operator and passes them in authorized_labels`,
      ),
    );
    inputs.unauthorized_labels = unauthorized;
  }

  const slugOrWarn = (value, what) => {
    if (typeof value === "string" && SLUG.test(value)) return value;
    warnings.push(warning("label-value-invalid", `${what} value ${JSON.stringify(value)} is not a slug and is ignored`));
    return null;
  };

  // ── rigor ────────────────────────────────────────────────────────────────
  // An operator instruction is never filtered or dropped: a malformed one is
  // a usage error, as operator.tiers already is, rather than a warning that
  // silently leaves the default in force (review round 2 property audit).
  const operatorSlug = (value, what) => {
    if (typeof value !== "string" || !SLUG.test(value)) {
      throw new TierInputError(`${what} must be a slug, got ${JSON.stringify(value)}`);
    }
    return value;
  };
  if (operator.rigor !== undefined) {
    const rigor = operatorSlug(operator.rigor, "operator.rigor");
    args.push(`--rigor`, rigor, `--rigor-source=operator`);
    inputs.rigor = { value: rigor, source: "operator" };
  } else {
    const known = uniq(rigorLabels).filter(rigorNamed);
    for (const v of uniq(rigorLabels).filter((v) => !rigorNamed(v))) {
      warnings.push(warning("rigor-label-unknown", `rigor:${v} names no rigor level in the governing policy and is ignored`));
    }
    if (known.length > 0) {
      const rigor = strongest(known, rigorOrder);
      if (known.length > 1) {
        warnings.push(warning("rigor-label-conflict", `rigor labels ${known.map((v) => `rigor:${v}`).join(", ")} conflict; the strongest, ${rigor}, applies`));
      }
      args.push(`--rigor`, rigor, `--rigor-source=label`);
      inputs.rigor = { value: rigor, source: "label" };
    }
  }

  // ── strategy ─────────────────────────────────────────────────────────────
  if (operator.strategy !== undefined) {
    const strategy = operatorSlug(operator.strategy, "operator.strategy");
    args.push(`--strategy`, strategy);
    inputs.strategy = { value: strategy, source: "operator" };
  } else {
    const slugs = uniq(strategyLabels).map((v) => slugOrWarn(v, "strategy label")).filter((v) => v !== null);
    for (const v of slugs.filter((v) => !strategyNamed(v))) {
      warnings.push(warning("strategy-label-unknown", `strategy:${v} names no [strategy.${v}] in the governing policy and is ignored`));
    }
    // Ignored labels do not count toward ambiguity: only labels that name a
    // real strategy can conflict.
    const values = slugs.filter(strategyNamed);
    if (values.length === 1) {
      args.push(`--strategy`, values[0]);
      inputs.strategy = { value: values[0], source: "label" };
    } else if (values.length > 1) {
      warnings.push(
        warning(
          "strategy-label-ambiguous",
          `strategy labels ${values.map((v) => `strategy:${v}`).join(", ")} are not orderable; none is passed and default_strategy applies — an interactive session asks the operator which one applies`,
        ),
      );
    }
  }

  // ── operator tier instructions ───────────────────────────────────────────
  if (operator.tiers !== undefined) {
    if (operator.tiers === null || typeof operator.tiers !== "object" || Array.isArray(operator.tiers)) {
      throw new TierInputError("operator.tiers must be a { role: tier } object");
    }
    const entries = [];
    for (const [role, tier] of Object.entries(operator.tiers)) {
      if (!ROLES.includes(role)) throw new TierInputError(`operator.tiers names unknown role ${JSON.stringify(role)}`);
      if (typeof tier !== "string" || !SLUG.test(tier)) {
        throw new TierInputError(`operator.tiers.${role} must be a tier slug, got ${JSON.stringify(tier)}`);
      }
      entries.push(`${role}=${tier}`);
    }
    if (entries.length > 0) {
      args.push(`--tier-overrides=${entries.join(",")}`);
      inputs.tier_overrides = Object.fromEntries(entries.map((e) => e.split("=")));
    }
  }

  // ── role-scoped tier labels ──────────────────────────────────────────────
  const roleEntries = [];
  for (const role of ROLES) {
    // The conflict is decided over the RAW distinct values; validation only
    // gates what may be forwarded (the R2-1 property). Selection stays
    // strongest-on-tier_order among valid ladder values, the reader's own
    // rule for role labels.
    const raw = uniq(roleLabels.get(role) ?? []);
    const values = raw.map((v) => slugOrWarn(v, `tier:${role}`)).filter((v) => v !== null);
    if (raw.length > 1) {
      const onLadderRaw = values.filter((v) => TIER_ORDER.includes(v));
      const pick = onLadderRaw.length > 0 ? strongest(onLadderRaw, TIER_ORDER) : null;
      warnings.push(
        warning(
          "tier-role-label-conflict",
          `tier labels ${raw.map((v) => `tier:${role}:${v}`).join(", ")} conflict; ${pick === null ? "none is on tier_order, so none applies" : `${pick} applies (strongest on tier_order)`}`,
        ),
      );
    }
    if (values.length === 0) continue;
    // Off-ladder values (a leftover `adaptive`, a typo) are passed through
    // only when nothing on the ladder competes, so the READER names them in
    // its own warning; a conflict resolves among ladder values alone.
    const onLadder = values.filter((v) => TIER_ORDER.includes(v));
    const chosen = onLadder.length > 0 ? strongest(onLadder, TIER_ORDER) : values[0];
    roleEntries.push(`${role}=${chosen}`);
  }
  if (roleEntries.length > 0) {
    args.push(`--tier-labels=${roleEntries.join(",")}`);
    inputs.tier_labels = Object.fromEntries(roleEntries.map((e) => e.split("=")));
  }

  // ── classification: Risk and Complexity ──────────────────────────────────
  const classification = {};
  for (const axis of ["risk", "complexity"]) {
    const field = fields[axis];
    const fromLabels = uniq(axisLabels[axis]);
    let value = null;
    if (field !== undefined && field !== null && field !== "") {
      if (typeof field !== "string") throw new TierInputError(`fields.${axis} must be a string`);
      value = field;
      const disagreeing = fromLabels.filter((v) => v !== field);
      if (disagreeing.length > 0) {
        warnings.push(
          warning(`${axis}-field-label-mismatch`, `the ${axis} field (${field}) disagrees with ${disagreeing.map((v) => `${axis}:${v}`).join(", ")}; the field is the storage of record and applies`),
        );
      }
    } else if (fromLabels.length === 1) {
      value = fromLabels[0];
    } else if (fromLabels.length > 1) {
      // A conflicting axis must reach the reader as UNKNOWABLE, not as
      // absent: passing nothing would let the reader see an unclassified
      // issue and resolve the default tier with exit 0 (review round 1,
      // R1-1). The off-scale sentinel goes through the reader's own tested
      // indeterminate path (corpus case off-scale-risk-is-indeterminate), so
      // the reader stays the single source of that verdict.
      value = CLASSIFICATION_CONFLICT;
      warnings.push(
        warning(
          `${axis}-label-ambiguous`,
          `${axis} labels ${fromLabels.map((v) => `${axis}:${v}`).join(", ")} conflict; the reader receives --${axis}=${CLASSIFICATION_CONFLICT} and reports the derived Tier indeterminate`,
        ),
      );
    }
    if (value !== null) {
      // A value that is not even a slug is unknowable the same way: send the
      // sentinel rather than dropping the axis, for the reason above.
      classification[axis] = slugOrWarn(value, axis) ?? CLASSIFICATION_CONFLICT;
    }
  }
  if (classification.risk !== undefined) args.push(`--risk=${classification.risk}`);
  if (classification.complexity !== undefined) args.push(`--complexity=${classification.complexity}`);
  inputs.classification = classification;

  // ── the stored Tier and the pin ──────────────────────────────────────────
  // Ambiguity is decided over the RAW distinct unqualified tier:<value>
  // labels — "more than one unqualified tier:<value> label" (acceptance
  // criterion 3) — and only then is a value validated for forwarding.
  // Filtering first let a malformed second label (`tier:APEX` beside
  // `tier:apex`) vanish and an ambiguous pin be honored (review round 2,
  // R2-1). A malformed value is never forwarded.
  const rawStored = uniq(storedTierLabels);
  const named = rawStored.map((v) => `tier:${v}`).join(", ");
  if (pinned) {
    if (rawStored.length === 1) {
      const value = slugOrWarn(rawStored[0], "tier");
      if (value === null) {
        warnings.push(warning("pin-value-invalid", `tier:pinned pins ${named}, which is not a Tier value; the issue resolves as unpinned, through its derived Tier`));
        inputs.pin = { invalid: rawStored };
      } else {
        args.push(`--pinned-tier=${value}`);
        if (provenance.marker_trusted === true) args.push("--pin-marker-trusted");
        if (provenance.value_trusted === true) args.push("--pin-value-trusted");
        inputs.pin = { tier: value, marker_trusted: provenance.marker_trusted === true, value_trusted: provenance.value_trusted === true };
      }
    } else if (rawStored.length > 1) {
      warnings.push(
        warning(
          "pin-ambiguous",
          `tier:pinned is present with more than one Tier label (${named}); the pin is ambiguous, no pinned Tier is passed, and the issue resolves through its derived Tier`,
        ),
      );
      inputs.pin = { ambiguous: rawStored };
    } else {
      warnings.push(warning("pin-without-tier", "tier:pinned is present without a tier:<value> label; there is nothing to pin, and the issue resolves through its derived Tier"));
      inputs.pin = { ambiguous: [] };
    }
  } else if (rawStored.length === 1) {
    // A malformed lone stored Tier is a cache value that cannot be compared;
    // it is dropped (with a warning) and the Tier is derived as usual.
    const value = slugOrWarn(rawStored[0], "tier");
    if (value !== null) {
      args.push(`--stored-tier=${value}`);
      inputs.stored_tier = value;
    }
  } else if (rawStored.length > 1) {
    warnings.push(
      warning(
        "stored-tier-ambiguous",
        `the issue carries more than one Tier label (${named}); none is passed as the stored Tier, which is recomputed from Risk × Complexity`,
      ),
    );
  }

  return { args, warnings, inputs };
}

// The PR-body tier source vocabulary (harmon-devkit#1248 criterion 4), from
// the reader's `roles.<role>.source`: which resolution rung set the tier.
//   operator — an operator tier instruction (rung 1)
//   pinned   — the honored pinned Tier (rung 2, implementer only)
//   rigor    — a tier:<role>:* label, or the profile of a rigor the operator
//              or a rigor:* label chose (rung 3)
//   derived  — Risk × Complexity over [tier.matrix] (rung 4, implementer only)
//   default  — default_rigor's profile, or the built-in fallback (rung 5)
export function tierSource(roleEntry, resolved) {
  switch (roleEntry.source) {
    case "operator":
    case "pinned":
    case "derived":
      return roleEntry.source;
    case "label":
      return "rigor";
    default:
      return resolved?.rigor?.chosen_by ? "rigor" : "default";
  }
}

/**
 * The PR-body tier disclosure for one resolution: the implementer's tier and
 * its source, every reader disclosure (an off-profile role tier, and a
 * companion left below the implementer — the invariant break a pin can
 * cause, named as pin-caused when the pin set the implementer), every
 * tier:<role>:* label a stronger rung overrode (disclosed, never silently
 * dropped), and every warning from this helper and from the reader.
 * `translation` is tierInputs()'s output; `resolved` is the reader's
 * `resolve --json` output for the same run.
 */
export function disclosureLines(translation, resolved) {
  const lines = [];
  const implementer = resolved.roles.implementer;
  const issue = resolved.issue_tier ?? { status: "absent" };
  const pin = resolved.pin ?? { status: "absent" };
  let line = `Implementer tier: ${implementer.tier} (source: ${tierSource(implementer, resolved)}; profile ${implementer.profile_tier ?? implementer.tier})`;
  if (issue.status !== "absent") line += ` · issue Tier: ${issue.status}${issue.tier ? ` ${issue.tier}` : ""}`;
  if (pin.status !== "absent") line += ` · pin: ${pin.status}${pin.reason ? ` (${pin.reason})` : ""}`;
  lines.push(line);
  for (const d of resolved.disclosures ?? []) {
    if (d.code === "role-tier-floor") {
      const cause = d.implementer_source === "pinned" ? "pin-caused invariant break" : "invariant break";
      lines.push(`${cause}: ${d.role} tier ${d.tier} is below the implementer's ${d.implementer_tier} (implementer source: ${d.implementer_source})`);
    } else if (d.code === "off-profile-tier") {
      lines.push(`off-profile: ${d.role} tier ${d.tier} (profile ${d.profile_tier}; source: ${tierSource(resolved.roles[d.role] ?? { source: d.source }, resolved)})`);
    }
  }
  for (const [role, value] of Object.entries(translation.inputs?.tier_labels ?? {})) {
    const entry = resolved.roles[role];
    if (entry && entry.source !== "label") {
      lines.push(`overridden: tier:${role}:${value} was passed but ${role} resolved from ${tierSource(entry, resolved)} (${entry.tier})`);
    }
  }
  for (const w of [...(translation.warnings ?? []), ...(resolved.warnings ?? [])]) {
    lines.push(`warning [${w.code}]: ${w.message}`);
  }
  if ((resolved.cross_validation?.indeterminate ?? []).some((i) => i.includes("derived Tier"))) {
    lines.push("indeterminate: the derived Tier could not be computed; the implementer keeps its profile tier (see the reader's indeterminate list)");
  }
  return lines;
}

function readJson(source) {
  return JSON.parse(readFileSync(source ?? 0, "utf8"));
}

/**
 * The names a rigor:/strategy: label may select under the policy at `file`:
 * its [rigor.*] and [strategy.*] tables. A file that does not exist is the
 * built-in fallback, which supports only standard rigor and plan strategy
 * (devflow-policy.mjs resolveAbsentPolicy). A present file that cannot be
 * read or parsed throws — the caller reports it rather than guessing.
 */
export function policySummary(file) {
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch (err) {
    if (err?.code === "ENOENT") return { rigors: ["standard"], strategies: ["plan"], rigor_order: ["standard"] };
    throw err;
  }
  const doc = parseToml(text);
  const tableNames = (t) => (t && typeof t === "object" && !Array.isArray(t) ? Object.keys(t) : []);
  return {
    rigors: tableNames(doc.rigor),
    strategies: tableNames(doc.strategy),
    rigor_order: Array.isArray(doc.rigor_order) ? doc.rigor_order.filter((v) => typeof v === "string") : RIGOR_ORDER,
  };
}

function main(argv) {
  const usage =
    "usage: tier-inputs.mjs --policy <.devflow.toml> [--input <file>]  translate (JSON on stdin otherwise)\n" +
    "       tier-inputs.mjs disclose --inputs <file> --resolved <file>  PR-body tier disclosure lines";
  const disclose = argv[0] === "disclose";
  const opts = {};
  for (let i = disclose ? 1 : 0; i < argv.length; i++) {
    const key = argv[i];
    const allowed = disclose ? ["--inputs", "--resolved"] : ["--input", "--policy"];
    if (!allowed.includes(key) || argv[i + 1] === undefined || Object.hasOwn(opts, key)) {
      console.error(usage);
      return 2;
    }
    opts[key] = argv[++i];
  }
  // --policy is required to translate: without it a label naming nothing in
  // the policy would be forwarded and refuse the whole resolution (C1-2).
  if (disclose ? !opts["--inputs"] || !opts["--resolved"] : !opts["--policy"]) {
    console.error(usage);
    return 2;
  }
  let policy = null;
  if (!disclose) {
    try {
      policy = policySummary(opts["--policy"]);
    } catch (err) {
      console.error(`tier-inputs: could not read/parse --policy: ${err.message}`);
      return 2;
    }
  }
  let docs;
  try {
    docs = disclose ? [readJson(opts["--inputs"]), readJson(opts["--resolved"])] : [readJson(opts["--input"])];
  } catch (err) {
    console.error(`tier-inputs: could not read/parse the input JSON: ${err.message}`);
    return 2;
  }
  try {
    if (disclose) {
      for (const l of disclosureLines(docs[0], docs[1])) console.log(`- ${l}`);
    } else {
      console.log(JSON.stringify(tierInputs({ ...docs[0], policy }), null, 2));
    }
  } catch (err) {
    if (err instanceof TierInputError || err instanceof TypeError) {
      console.error(`tier-inputs: ${err.message}`);
      return 2;
    }
    throw err;
  }
  return 0;
}

const isMain =
  process.argv[1] &&
  (() => {
    try {
      return realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1]);
    } catch {
      return fileURLToPath(import.meta.url) === process.argv[1];
    }
  })();
if (isMain) {
  process.exitCode = main(process.argv.slice(2));
}
