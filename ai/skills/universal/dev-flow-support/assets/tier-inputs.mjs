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
//     "owner_type": "Organization",
//                 // `User` or `Organization`: the repository owner's type,
//                 // which picks where Risk and Complexity are stored
//                 // (triage's classification rubric). `User`: the
//                 // risk:*/complexity:* labels, and `fields` must be empty.
//                 // `Organization`: the issue fields ONLY — a same-axis
//                 // label is inert and never read, so an unset field leaves
//                 // its axis unset (harmon-devkit#1328). Required whenever
//                 // the issue carries a risk:*/complexity:* label or a set
//                 // field; omitted there, it is a usage error (exit 2).
//     "fields":   { "risk": "high", "complexity": "m" },
//                 // org-repository issue fields, the storage of record
//                 // there: REQUIRED with owner_type Organization, from a
//                 // complete field read ({} when none is set), and absent
//                 // with User. Within it, an unset, omitted, null or ""
//                 // field is an unset axis.
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
//     no --pinned-tier, a warning naming the values, and the pin rung is
//     dropped: resolution continues through the remaining rungs.
//   - tier:<role>:<value> labels: one per role; a conflict resolves to the
//     strongest on tier_order (a conflict only ever buys more capability).
//   - rigor:* label conflicts resolve to the strongest on rigor_order; two
//     different strategy:* labels are ambiguous and pass none (the policy
//     default applies, with a warning).
//   - risk:<v>/complexity:<v> labels (owner_type User) or fields (owner_type
//     Organization, never labels) become --risk/--complexity; two different
//     values for one axis (or a non-slug value) pass the off-scale
//     `conflict` sentinel, so the READER reports the derived Tier indeterminate — never "absent",
//     which would silently resolve the default tier.
// Values are passed with the `--opt=value` spelling, so a label value can
// never be read by the reader as a flag of its own.

import { lstatSync, readFileSync, realpathSync, statSync } from "node:fs";
import { dirname } from "node:path";
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
// What a dropped pin means, stated once for every pin warning. It claims no
// particular outcome: an operator tier, a tier:implementer:* label or a chosen
// rigor can still decide, and only without them does the derived Tier
// (integration remediation 2, thread 4178249123).
const PIN_DROPPED = "the pin rung is dropped and resolution continues through the remaining rungs (operator tier, tier:implementer:* label or chosen rigor, then the derived Tier, then the default)";

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
// The keys an input document may carry. An unknown key is refused, never
// ignored: a misspelled `operater` or `authorised_labels` would otherwise
// resolve the default with exit 0 — the silent-loss shape the reader's own
// option allowlist closes (integration remediation 1, thread 4176257545).
// `policy` is the CLI-injected summary (from --policy), not an input key.
export const INPUT_KEYS = Object.freeze(["labels", "authorized_labels", "owner_type", "fields", "operator", "pin_provenance"]);
// The repository owner types, spelled as GitHub's `owner.type` and triage's
// `owner_type`. The owner type is the classification's storage mode: labels
// on a personal-account repository, issue fields on an organization one
// (harmon-devkit#1328).
export const OWNER_TYPES = Object.freeze(["User", "Organization"]);
export const OPERATOR_KEYS = Object.freeze(["rigor", "strategy", "tiers"]);
// The classification issue fields; a misspelled `rsk` would otherwise read
// as an unclassified issue (integration remediation 2, thread 4178249112).
export const FIELD_KEYS = Object.freeze(["risk", "complexity"]);
// The pin's two provenance halves. A typo (`markerTrusted`) or a non-boolean
// (`"yes"`) used to read silently as untrusted: safe, but malformed input
// reported as valid (integration remediation 3, thread 4178487551).
export const PIN_PROVENANCE_KEYS = Object.freeze(["marker_trusted", "value_trusted"]);

export function tierInputs(input = {}) {
  if (input === null || typeof input !== "object" || Array.isArray(input)) {
    throw new TierInputError("the input must be a JSON object");
  }
  const unknownKeys = Object.keys(input).filter((k) => !INPUT_KEYS.includes(k) && k !== "policy");
  if (unknownKeys.length > 0) {
    throw new TierInputError(`unknown input key(s) ${unknownKeys.join(", ")}; the keys are ${INPUT_KEYS.join(", ")}`);
  }
  const {
    labels = [],
    authorized_labels: authorizedLabels = [],
    owner_type: ownerType,
    fields = {},
    operator = {},
    pin_provenance: provenance = {},
    policy = null,
  } = input;
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
  if (ownerType !== undefined && !OWNER_TYPES.includes(ownerType)) {
    throw new TierInputError(`owner_type must be one of ${OWNER_TYPES.join(", ")}, got ${JSON.stringify(ownerType)}`);
  }
  // Issue fields exist only on organization repositories; a caller passing
  // them for a personal one has mixed up the storage modes.
  if (ownerType === "User" && Object.hasOwn(input, "fields")) {
    throw new TierInputError("fields are organization-repository storage; on owner_type User, Risk and Complexity are the risk:*/complexity:* labels");
  }
  // On an organization the fields are the only storage, so an unset axis must
  // come from a read that happened: `fields` is required ({} when none is
  // set). A caller whose field read failed, was unavailable or was truncated
  // has no fields object to pass and stops as indeterminate, rather than
  // having a failed read pass as "unset".
  if (ownerType === "Organization" && !Object.hasOwn(input, "fields")) {
    throw new TierInputError(
      'owner_type Organization requires "fields" from a complete issue-field read ({} when none is set); if the read failed or was truncated, tier resolution is indeterminate',
    );
  }
  const unknownOperator = Object.keys(operator).filter((k) => !OPERATOR_KEYS.includes(k));
  if (unknownOperator.length > 0) {
    throw new TierInputError(`unknown operator key(s) ${unknownOperator.join(", ")}; the keys are ${OPERATOR_KEYS.join(", ")}`);
  }
  const unknownFields = Object.keys(fields).filter((k) => !FIELD_KEYS.includes(k));
  if (unknownFields.length > 0) {
    throw new TierInputError(`unknown fields key(s) ${unknownFields.join(", ")}; the keys are ${FIELD_KEYS.join(", ")}`);
  }
  const unknownProvenance = Object.keys(provenance).filter((k) => !PIN_PROVENANCE_KEYS.includes(k));
  if (unknownProvenance.length > 0) {
    throw new TierInputError(`unknown pin_provenance key(s) ${unknownProvenance.join(", ")}; the keys are ${PIN_PROVENANCE_KEYS.join(", ")}`);
  }
  for (const [key, value] of Object.entries(provenance)) {
    if (typeof value !== "boolean") {
      throw new TierInputError(`pin_provenance.${key} must be a boolean, got ${JSON.stringify(value)}`);
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
  // resolution continues without it, so a label nobody vouched for can neither
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
  // A family is recognized by its PREFIX and the whole remainder is kept raw,
  // extra colons included: `risk:high:typo` or `tier:apex:old` used to match
  // no exact-arity branch and vanish, which is the filter-before-count shape
  // again (integration remediation 1, thread 4176257550). The remainder is
  // validated only where a value is forwarded.
  const remainder = (label, prefix) => (label.startsWith(prefix) ? label.slice(prefix.length) : null);
  for (const label of labels) {
    let rest;
    if ((rest = remainder(label, "rigor:")) !== null) {
      if (policyLabel(label)) rigorLabels.push(rest);
    } else if ((rest = remainder(label, "strategy:")) !== null) {
      if (policyLabel(label)) strategyLabels.push(rest);
    } else if ((rest = remainder(label, "risk:")) !== null) {
      axisLabels.risk.push(rest);
    } else if ((rest = remainder(label, "complexity:")) !== null) {
      axisLabels.complexity.push(rest);
    } else if (label === "tier:pinned") {
      pinned = true;
    } else if ((rest = remainder(label, "tier:")) !== null) {
      // `tier:<role>:<value>` when the first segment names a role; anything
      // else (`tier:apex`, `tier:apex:old`, `tier:foo:bar`) is an
      // unqualified stored-Tier value, counted raw.
      const sep = rest.indexOf(":");
      const head = sep === -1 ? null : rest.slice(0, sep);
      if (head !== null && ROLES.includes(head)) {
        if (!policyLabel(label)) continue;
        if (!roleLabels.has(head)) roleLabels.set(head, []);
        roleLabels.get(head).push(rest.slice(sep + 1));
      } else {
        storedTierLabels.push(rest);
      }
    }
  }
  if (unauthorized.length > 0) {
    warnings.push(
      warning(
        "policy-label-unauthorized",
        `execution-policy label(s) ${unauthorized.join(", ")} carry no verified provenance and are not passed; resolution continues without them — an interactive session confirms them with the operator and passes them in authorized_labels`,
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
  // Every path records a source, so the announcement and PR profile can name
  // it from this artifact (integration remediation 3, thread 4178487553). With
  // no rigor passed, the policy's default_rigor resolves.
  if (inputs.rigor === undefined) inputs.rigor = { value: null, source: "default" };

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
      inputs.strategy = { value: null, source: "default", ambiguous: values };
    }
  }
  // The reader receives a label-chosen and an operator-chosen strategy the
  // same way (`--strategy`), so THIS is where the source is known; every path
  // records one (thread 4178487553).
  if (inputs.strategy === undefined) inputs.strategy = { value: null, source: "default" };

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
          `tier labels ${raw.map((v) => `tier:${role}:${v}`).join(", ")} conflict; ${pick === null ? "none is on tier_order, so the reader rejects the one passed by name" : `${pick} is the one passed (strongest on tier_order; a stronger rung can still override it)`}`,
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
  // The owner type is the storage mode, and each mode reads exactly one
  // source (harmon-devkit#1328). On an organization repository Risk and
  // Complexity live only in issue fields and a same-named label is inert:
  // falling back to it when the field is unset would let a stale or
  // untrusted label select the derived Tier, where the classification must
  // read as incomplete. Without an owner type neither source can be read,
  // so an issue that carries any classification input is a usage error
  // (exit 2) rather than a warning: a silently unset axis would resolve the
  // default tier with exit 0, the silent-loss shape the key allowlists close.
  const fieldSet = (axis) => fields[axis] !== undefined && fields[axis] !== null && fields[axis] !== "";
  for (const axis of FIELD_KEYS) {
    if (fieldSet(axis) && typeof fields[axis] !== "string") throw new TierInputError(`fields.${axis} must be a string`);
  }
  const classification = {};
  if (ownerType === undefined) {
    const unread = [
      ...FIELD_KEYS.flatMap((axis) => uniq(axisLabels[axis]).map((v) => `${axis}:${v}`)),
      ...FIELD_KEYS.filter(fieldSet).map((axis) => `the ${axis} field`),
    ];
    if (unread.length > 0) {
      throw new TierInputError(
        `owner_type is required to read the classification (${unread.join(", ")}): User reads the risk:*/complexity:* labels, Organization only the issue fields`,
      );
    }
  }
  for (const axis of ownerType === undefined ? [] : FIELD_KEYS) {
    const fromLabels = uniq(axisLabels[axis]);
    let value = null;
    if (ownerType === "Organization") {
      if (fromLabels.length > 0) {
        warnings.push(
          warning(
            `${axis}-label-inert`,
            `${fromLabels.map((v) => `${axis}:${v}`).join(", ")} ${fromLabels.length === 1 ? "is" : "are"} inert on an organization repository and not read; ${axis === "risk" ? "Risk" : "Complexity"} comes only from its issue field${fieldSet(axis) ? "" : ", which is unset, so the axis stays unset"}`,
          ),
        );
      }
      // An organization's option names keep its own capitalization (`High`,
      // `XL`); compare them the way triage's field reader does, lowercased.
      if (fieldSet(axis)) value = fields[axis].toLowerCase();
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
      // sentinel rather than dropping the axis, for the reason above — and
      // say so, rather than slugOrWarn's "ignored", which would misstate it.
      if (typeof value === "string" && SLUG.test(value)) {
        classification[axis] = value;
      } else {
        classification[axis] = CLASSIFICATION_CONFLICT;
        warnings.push(
          warning(
            "label-value-invalid",
            `${axis} value ${JSON.stringify(value)} is not a slug; the reader receives --${axis}=${CLASSIFICATION_CONFLICT} and reports the derived Tier indeterminate`,
          ),
        );
      }
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
        warnings.push(warning("pin-value-invalid", `tier:pinned pins ${named}, which is not a Tier value; ${PIN_DROPPED}`));
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
          `tier:pinned is present with more than one Tier label (${named}); the pin is ambiguous and no pinned Tier is passed — ${PIN_DROPPED}`,
        ),
      );
      inputs.pin = { ambiguous: rawStored };
    } else {
      warnings.push(warning("pin-without-tier", `tier:pinned is present without a tier:<value> label; there is nothing to pin — ${PIN_DROPPED}`));
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
        `the issue carries more than one Tier label (${named}); none is passed as the stored Tier (only a cache; where Risk and Complexity exist, the Tier is derived from them)`,
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
  // The selections and their sources come from the translation artifact,
  // which is the only place a label- and an operator-chosen strategy differ;
  // the values themselves are what the reader resolved (thread 4178487553).
  const rigorSource = translation.inputs?.rigor?.source ?? "default";
  const strategyInput = translation.inputs?.strategy ?? { source: "default" };
  const ambiguity = Array.isArray(strategyInput.ambiguous) && strategyInput.ambiguous.length > 0
    ? `; ambiguous between ${strategyInput.ambiguous.join(", ")}`
    : "";
  lines.push(
    `Rigor: ${resolved.rigor?.level} (source: ${rigorSource}) · Strategy: ${resolved.strategy?.name} (source: ${strategyInput.source ?? "default"}${ambiguity})`,
  );
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
  // A passed role label is disclosed exactly once (integration remediation 2,
  // thread 4178249117): "overridden" only for a VALID ladder value that lost
  // to a stronger rung; a value the reader REJECTED (a retired `adaptive`, an
  // off-ladder typo) is disclosed as rejected with the reader's own reason,
  // and that reader warning is not repeated below.
  const consumed = new Set();
  for (const [role, value] of Object.entries(translation.inputs?.tier_labels ?? {})) {
    const entry = resolved.roles[role];
    if (!entry) continue;
    if (!TIER_ORDER.includes(value)) {
      const reason = (resolved.warnings ?? []).find((w) => w.subject === `tier:${role}` && (w.code === "tier-retired" || w.code === "tier-unknown"));
      if (reason) consumed.add(reason);
      lines.push(
        `rejected: tier:${role}:${value} — ${reason ? reason.message : `it names no tier_order rung and is ignored`}; ${role} keeps its ${tierSource(entry, resolved)} tier (${entry.tier})`,
      );
    } else if (entry.source !== "label") {
      lines.push(`overridden: tier:${role}:${value} was passed but ${role} resolved from ${tierSource(entry, resolved)} (${entry.tier})`);
    }
  }
  for (const w of [...(translation.warnings ?? []), ...(resolved.warnings ?? [])]) {
    if (consumed.has(w)) continue;
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
 * its [rigor.*] and [strategy.*] tables. Only a path with no final entry in
 * a resolvable directory takes the built-in fallback, which supports only
 * standard rigor and plan strategy (devflow-policy.mjs resolveAbsentPolicy).
 * A dangling symlink, an unresolvable or non-directory parent, or a file that
 * cannot be read or parsed throws — the caller reports it rather than guessing.
 */
export function policySummary(file) {
  let text;
  try {
    text = readFileSync(file, "utf8");
  } catch (err) {
    if (err?.code === "ENOENT") {
      try {
        lstatSync(file);
      } catch (statErr) {
        if (statErr?.code !== "ENOENT") throw statErr;
        if (!statSync(realpathSync(dirname(file))).isDirectory()) {
          throw new Error("parent is not a directory");
        }
        return { rigors: ["standard"], strategies: ["plan"], rigor_order: ["standard"] };
      }
    }
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
      // The parsed document must itself be an object — `null`, `[]` and a
      // bare string used to spread into an empty input and exit 0 with no
      // flags (integration remediation 1, thread 4176257533). A `policy` key
      // inside the document is refused too: only --policy supplies it.
      const doc = docs[0];
      if (doc === null || typeof doc !== "object" || Array.isArray(doc)) {
        throw new TierInputError("the input must be a JSON object");
      }
      if (Object.hasOwn(doc, "policy")) {
        throw new TierInputError(`unknown input key(s) policy; the keys are ${INPUT_KEYS.join(", ")} (the policy comes from --policy)`);
      }
      console.log(JSON.stringify(tierInputs({ ...doc, policy }), null, 2));
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
