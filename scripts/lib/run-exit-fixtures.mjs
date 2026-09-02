#!/usr/bin/env node
// scripts/lib/run-exit-fixtures.mjs — drives the ai/schemas/fixtures/exit/
// conformance corpus against scripts/dev-flow-exit.mjs and
// scripts/devflow-policy.mjs, and checks each case's expected.json.
// Invoked by scripts/test-dev-flow-exit.sh; see ai/schemas/README.md for the
// fixture directory layout this reads.

import { readFileSync, existsSync, readdirSync, mkdtempSync, rmSync, mkdirSync, copyFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import os from "node:os";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SCRIPTS_DIR = path.dirname(HERE);
const REPO_ROOT = path.dirname(SCRIPTS_DIR);
const FIXTURES_DIR = path.join(REPO_ROOT, "ai/schemas/fixtures/exit");
const EXIT_SCRIPT = path.join(SCRIPTS_DIR, "dev-flow-exit.mjs");
const POLICY_SCRIPT = path.join(SCRIPTS_DIR, "devflow-policy.mjs");

let failures = 0;
let passes = 0;

function report(name, ok, detail) {
  if (ok) {
    passes++;
    console.log(`PASS: ${name}`);
  } else {
    failures++;
    console.log(`FAIL: ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

function readJsonIfExists(file) {
  if (!existsSync(file)) return null;
  return JSON.parse(readFileSync(file, "utf8"));
}

// Build a CLI argv from an invoke.json object. Any value naming a file that
// exists in `dir` resolves to its absolute path; everything else is passed
// as a literal string.
function buildArgs(invoke, dir) {
  const args = [];
  for (const [key, value] of Object.entries(invoke || {})) {
    args.push(`--${key}`);
    if (value === true) continue;
    const asPath = path.join(dir, String(value));
    args.push(existsSync(asPath) ? asPath : String(value));
  }
  return args;
}

function run(script, args) {
  const result = spawnSync(process.execPath, [script, ...args], { encoding: "utf8" });
  return { status: result.status, stdout: result.stdout, stderr: result.stderr };
}

// Every key checkVerdict knows how to assert on. Review round 1 (confirmed):
// four fixtures declared corrections_field/corrections_status/
// no_corrections_for/verified_provenance_for/no_repeat_relationship
// expectations that nothing here ever read, so those fixtures passed
// whether or not the behavior they claimed to cover actually held.
const VERDICT_EXPECTATION_KEYS = new Set([
  "outcome",
  "reason",
  "rounds_counted",
  "diagnostic_contains",
  "corrections_field",
  "corrections_status",
  "no_corrections_for",
  "verified_provenance_for",
  "no_repeat_relationship",
]);

function checkVerdict(expected, actual) {
  const unknown = Object.keys(expected).filter((k) => !VERDICT_EXPECTATION_KEYS.has(k));
  if (unknown.length > 0) return `expected.json has unsupported key(s): ${unknown.join(", ")}`;

  if (expected.outcome !== undefined && actual.outcome !== expected.outcome) {
    return `outcome: expected "${expected.outcome}", got "${actual.outcome}"`;
  }
  if (expected.reason !== undefined && actual.reason !== expected.reason) {
    return `reason: expected "${expected.reason}", got "${actual.reason}"`;
  }
  if (expected.rounds_counted !== undefined && actual.rounds_counted !== expected.rounds_counted) {
    return `rounds_counted: expected ${expected.rounds_counted}, got ${actual.rounds_counted}`;
  }
  if (expected.diagnostic_contains) {
    const found = (actual.diagnostics || []).some((d) => d.reason && d.reason.includes(expected.diagnostic_contains));
    if (!found) return `no diagnostic contains "${expected.diagnostic_contains}" (${JSON.stringify(actual.diagnostics)})`;
  }
  // corrections_field/corrections_status: at least one verified_findings
  // entry has that field's status — verdict.corrections[] only records a
  // MISMATCH (status "corrected"), never "unverified" or a plain
  // "verified" match, so these two read verified_findings instead.
  if (expected.corrections_field !== undefined || expected.corrections_status !== undefined) {
    const field = expected.corrections_field; // "provenance" | "fingerprint"
    const statusKey = field === "fingerprint" ? "fingerprint_status" : "provenance_status";
    const found = (actual.verified_findings || []).some((f) => f[statusKey] === expected.corrections_status);
    if (!found) {
      return `no verified_findings entry has ${statusKey} === "${expected.corrections_status}" (${JSON.stringify(actual.verified_findings)})`;
    }
  }
  if (expected.no_corrections_for !== undefined) {
    const found = (actual.corrections || []).some((c) => c.finding_id === expected.no_corrections_for);
    if (found) return `expected no correction for "${expected.no_corrections_for}", but one exists (${JSON.stringify(actual.corrections)})`;
  }
  if (expected.verified_provenance_for !== undefined) {
    const { id, value } = expected.verified_provenance_for;
    const entry = (actual.verified_findings || []).find((f) => f.id === id);
    if (!entry || entry.verified_provenance !== value) {
      return `verified_findings[id=${id}].verified_provenance: expected "${value}", got ${JSON.stringify(entry)}`;
    }
  }
  if (expected.no_repeat_relationship !== undefined) {
    // [originId, claimantId]: claimantId must NOT be a verified repeat-of
    // (or supersedes) originId — a fabricated same-file claim must stay
    // unverified, not silently confirmed by path coincidence alone.
    const [originId, claimantId] = expected.no_repeat_relationship;
    const entry = (actual.verified_findings || []).find((f) => f.id === claimantId);
    if (entry && entry.fingerprint_status === "verified" && entry.verified_fingerprint === `repeat-of:${originId}`) {
      return `expected "${claimantId}" to have no verified repeat relationship with "${originId}", but its fingerprint verified as repeat-of:${originId}`;
    }
  }
  return null;
}

// Recognized only once `resolve_fails` has been ruled out by the caller
// (runPolicyFixture never reaches this function for a resolve_fails case),
// so "resolve_fails"/"message_contains" are deliberately not members here.
const POLICY_EXPECTATION_KEYS = new Set([
  "rigor_level",
  "rounds",
  "gates",
  "decoded_from",
  "breadth",
  "convergence_json",
  "role_tiers",
  "stage_finders_empty",
  "cross_validation_error_contains",
]);

function checkPolicyResolution(expected, actual) {
  const unknown = Object.keys(expected).filter((k) => !POLICY_EXPECTATION_KEYS.has(k));
  if (unknown.length > 0) return `expected.json has unsupported key(s): ${unknown.join(", ")}`;

  if (expected.rigor_level !== undefined && actual.rigor?.level !== expected.rigor_level) {
    return `rigor.level: expected "${expected.rigor_level}", got "${actual.rigor?.level}"`;
  }
  if (expected.rounds !== undefined) {
    for (const [k, v] of Object.entries(expected.rounds)) {
      if (actual.rounds?.[k] !== v) return `rounds.${k}: expected ${v}, got ${actual.rounds?.[k]}`;
    }
  }
  if (expected.gates !== undefined) {
    for (const [k, v] of Object.entries(expected.gates)) {
      if (actual.gates?.[k] !== v) return `gates.${k}: expected "${v}", got "${actual.gates?.[k]}"`;
    }
  }
  if (expected.decoded_from !== undefined && actual.decodedFrom !== expected.decoded_from) {
    return `decodedFrom: expected "${expected.decoded_from}", got "${actual.decodedFrom}"`;
  }
  if (expected.breadth !== undefined) {
    for (const [k, v] of Object.entries(expected.breadth)) {
      if (actual.breadth?.[k] !== v) return `breadth.${k}: expected ${JSON.stringify(v)}, got ${JSON.stringify(actual.breadth?.[k])}`;
    }
  }
  if (expected.convergence_json !== undefined) {
    const got = JSON.stringify({ converged: actual.convergence?.converged, diverging: actual.convergence?.diverging });
    if (got !== expected.convergence_json) return `convergence: expected ${expected.convergence_json}, got ${got}`;
  }
  if (expected.role_tiers !== undefined) {
    for (const [role, tier] of Object.entries(expected.role_tiers)) {
      if (actual.roles?.[role]?.tier !== tier) return `roles.${role}.tier: expected "${tier}", got "${actual.roles?.[role]?.tier}"`;
    }
  }
  if (expected.stage_finders_empty !== undefined) {
    for (const stage of expected.stage_finders_empty) {
      const finders = actual.stages?.[stage]?.finders;
      if (!Array.isArray(finders) || finders.length !== 0) return `stages.${stage}.finders: expected [], got ${JSON.stringify(finders)}`;
    }
  }
  if (expected.cross_validation_error_contains) {
    const errs = (actual.cross_validation && actual.cross_validation.errors) || [];
    const found = errs.some((e) => e.includes(expected.cross_validation_error_contains));
    if (!found) return `no cross_validation error contains "${expected.cross_validation_error_contains}" (${JSON.stringify(errs)})`;
  }
  return null;
}

function runExitFixture(name, dir) {
  const invoke = readJsonIfExists(path.join(dir, "invoke.json")) || {};
  const expected = readJsonIfExists(path.join(dir, "expected.json"));
  if (!expected) return report(name, false, "missing expected.json");

  if (!invoke.stage) return report(name, false, "invoke.json has no stage");
  // dev-flow-exit.mjs deliberately takes no --registry/--task-targets — see
  // its own header comment: exit computation reads the already-resolved
  // policy shape, which never depends on registry/Taskfile cross-validation.
  const args = [
    "--run", path.join(dir, "run"),
    "--stage", invoke.stage,
    "--policy", path.join(dir, "policy.toml"),
    "--json",
  ];
  for (const [key, value] of Object.entries(invoke)) {
    if (key === "stage") continue;
    args.push(`--${key}`);
    const asPath = path.join(dir, String(value));
    args.push(existsSync(asPath) ? asPath : String(value));
  }

  const { status, stdout, stderr } = run(EXIT_SCRIPT, args);

  if (expected.indeterminate) {
    return report(name, status === 2, `expected exit 2 (indeterminate), got ${status}. stderr: ${stderr.trim()}`);
  }

  let actual;
  try {
    actual = JSON.parse(stdout);
  } catch {
    return report(name, false, `could not parse stdout as JSON (exit ${status}). stderr: ${stderr.trim()}`);
  }
  const problem = checkVerdict(expected, actual);
  report(name, !problem, problem);
}

// Builds the TRUSTED closure a --closure fixture re-execs into, from
// whatever scripts/devflow-policy.mjs + scripts/lib/toml-lite.mjs the
// repository currently ships — never a copy committed under
// ai/schemas/fixtures/, so a --closure fixture can never drift from the
// real reader (see reader-self-modification-boundary/README.md).
function buildTrustedClosure() {
  const tmp = mkdtempSync(path.join(os.tmpdir(), "devflow-closure-"));
  mkdirSync(path.join(tmp, "scripts", "lib"), { recursive: true });
  copyFileSync(path.join(SCRIPTS_DIR, "devflow-policy.mjs"), path.join(tmp, "scripts", "devflow-policy.mjs"));
  copyFileSync(path.join(SCRIPTS_DIR, "dev-flow-exit.mjs"), path.join(tmp, "scripts", "dev-flow-exit.mjs"));
  copyFileSync(path.join(SCRIPTS_DIR, "lib", "toml-lite.mjs"), path.join(tmp, "scripts", "lib", "toml-lite.mjs"));
  return tmp;
}

function runPolicyFixture(name, dir) {
  const invoke = readJsonIfExists(path.join(dir, "invoke.json")) || {};
  const expected = readJsonIfExists(path.join(dir, "expected.json"));
  if (!expected) return report(name, false, "missing expected.json");

  const { entry_script: entryScript, ...restInvoke } = invoke;
  const entryPath = entryScript ? path.join(dir, entryScript) : POLICY_SCRIPT;

  let closureDir = null;
  const args = ["resolve", "--json"];
  if (existsSync(path.join(dir, "policy.toml"))) args.push("--policy", path.join(dir, "policy.toml"));
  if (existsSync(path.join(dir, "registry.json"))) args.push("--registry", path.join(dir, "registry.json"));
  if (existsSync(path.join(dir, "task-targets.json"))) args.push("--task-targets", path.join(dir, "task-targets.json"));
  if (entryScript) {
    closureDir = buildTrustedClosure();
    args.push("--closure", closureDir);
  }
  args.push(...buildArgs(restInvoke, dir));

  let result;
  try {
    result = run(entryPath, args);
  } finally {
    if (closureDir) rmSync(closureDir, { recursive: true, force: true });
  }
  const { status, stdout, stderr } = result;

  if (expected.resolve_fails) {
    const ok = status === 1;
    const messageOk = expected.message_contains ? stderr.includes(expected.message_contains) : true;
    return report(name, ok && messageOk, ok ? `message did not contain "${expected.message_contains}": ${stderr.trim()}` : `expected exit 1, got ${status}: ${stderr.trim()}`);
  }

  let actual;
  try {
    actual = JSON.parse(stdout);
  } catch {
    return report(name, false, `could not parse stdout as JSON (exit ${status}). stderr: ${stderr.trim()}`);
  }
  const problem = checkPolicyResolution(expected, actual);
  report(name, !problem, problem);
}

function main() {
  if (!existsSync(FIXTURES_DIR)) {
    console.error(`no fixtures directory at ${FIXTURES_DIR}`);
    process.exit(1);
  }
  const names = readdirSync(FIXTURES_DIR).sort();
  for (const name of names) {
    const dir = path.join(FIXTURES_DIR, name);
    if (existsSync(path.join(dir, "run"))) {
      runExitFixture(name, dir);
    } else {
      runPolicyFixture(name, dir);
    }
  }
  console.log(`\n${passes} passed, ${failures} failed`);
  process.exit(failures > 0 ? 1 : 0);
}

main();
