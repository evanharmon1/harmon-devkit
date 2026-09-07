#!/usr/bin/env bash
# test-dev-flow-exit.sh — behavioral test for scripts/devflow-policy.mjs and
# scripts/dev-flow-exit.mjs against the conformance fixture corpus under
# ai/schemas/fixtures/exit/ (see ai/schemas/README.md).
#
# Deliberately never touches this repository's own live .devflow.toml —
# every case here resolves a fixture policy under ai/schemas/fixtures/exit/,
# per AGENTS.md's "Round caps are resolved" / design.md decision 13: this
# repo's own config is still legacy-shaped (pending the harmon-init v2
# template migration), so a v2 consumer must refuse it, and this test must
# not make that refusal look like a test failure.
set -euo pipefail

repo="$(git rev-parse --show-toplevel)"
cd "${repo}"

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

# Every scratch file below lives in this per-run directory rather than in a
# shared-tmp `<name>-$$` path. `$$` is unique only among *live* processes: a
# crashed run leaves its files behind, and a later run whose PID has been
# recycled reads them. A private directory removed on exit cannot collide with
# a concurrent run or inherit a stale one's leftovers.
scratch="$(mktemp -d)"
trap 'rm -rf "${scratch}"' EXIT

command -v node >/dev/null 2>&1 || fail "node is required"
command -v task >/dev/null 2>&1 || fail "task is required"
[ -f scripts/devflow-policy.mjs ] || fail "missing required asset: scripts/devflow-policy.mjs"
[ -f scripts/dev-flow-exit.mjs ] || fail "missing required asset: scripts/dev-flow-exit.mjs"
[ -x scripts/dev-flow-exit.sh ] || fail "scripts/dev-flow-exit.sh must exist and be executable"
[ -f scripts/lib/toml-lite.mjs ] || fail "missing required asset: scripts/lib/toml-lite.mjs"

echo "== TOML parser smoke checks =="
node --input-type=module -e '
import { parseToml, TomlError } from "./scripts/lib/toml-lite.mjs";
import assert from "node:assert/strict";

// Round-trips the multi-line inline-table shape specs/dev-flow-v2.md ships
// for [convergence] — the one construct this hand-rolled parser exists to
// get right without a dependency.
const doc = parseToml(`
[convergence]
diverging = { any = [
  { predicate = "count_rising", increases = 2 },
  { predicate = "provenance_share", min = 0.5, exclude_classes = ["design"] },
] }
`);
assert.equal(doc.convergence.diverging.any.length, 2);
assert.equal(doc.convergence.diverging.any[1].min, 0.5);
assert.deepEqual(doc.convergence.diverging.any[1].exclude_classes, ["design"]);

// This repository'"'"'s own live legacy .devflow.toml must still parse
// structurally (shape REFUSAL is devflow-policy.mjs'"'"'s job, not the
// parser'"'"'s — the parser has no opinion on shape).
import { readFileSync } from "node:fs";
const legacy = parseToml(readFileSync(".devflow.toml", "utf8"));
assert.equal(legacy.default_rigor, "standard");
assert.equal(legacy.rigor.standard.shepherd, 4);

// array-of-tables and triple-quoted strings are explicitly unsupported —
// rejected loudly, never silently mis-parsed.
assert.throws(() => parseToml("[[a]]\nx = 1\n"), TomlError);
assert.throws(() => parseToml(`x = """multi\nline"""\n`), TomlError);

// .devflow.toml is branch-controlled, untrusted content: a table header or
// key named "__proto__"/"constructor"/"prototype" must never reach the
// shared Object.prototype (a plain {} object'"'"'s inherited accessors turn
// `"__proto__" in {}` true even on a fresh object, letting a hostile header
// walk `cur[key]` onto Object.prototype itself and corrupt every object in
// the process for the rest of its lifetime).
const before = ({}).polluted;
const evil = parseToml(`
[__proto__]
polluted = "yes"
`);
assert.equal(({}).polluted, before, "an ordinary object must not observe a property from parsing untrusted TOML");
assert.deepEqual(Object.keys(evil), ["__proto__"], "__proto__ must parse as an ordinary own key, not a prototype write");

console.log("TOML parser smoke checks OK");
'

echo "== dev-flow-exit.mjs: an unavailable ledger fails safe, distinct from a real-but-empty one =="
node --input-type=module -e '
import { loadLedger, verifyProvenance } from "./scripts/dev-flow-exit.mjs";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

// --repo-root names the (unimplemented) production git adapter, and passing
// NEITHER --history nor --repo-root is the advertised no-flags usage: both
// must return null (unavailable), never [] (a real ledger that happens to be
// empty) — the two must drive verifyProvenance to different, non-silent
// conclusions for the identical asserted claim, or an "original" assertion
// could evade provenance_share divergence just by there being no evidence
// source configured at all (challenge round 3, confirmed).
assert.equal(loadLedger({ repoRoot: "." }), null);
assert.equal(loadLedger({}), null);

// A genuinely real-but-empty ledger is still reachable — explicitly, via
// --history naming a file that legitimately contains no entries.
const dir = mkdtempSync(path.join(tmpdir(), "dfe-ledger-"));
const emptyHistoryFile = path.join(dir, "history.json");
writeFileSync(emptyHistoryFile, "[]");
assert.deepEqual(loadLedger({ historyFile: emptyHistoryFile }), []);
rmSync(dir, { recursive: true, force: true });

const originalClaim = { provenance: "original", line: 10, path: "scripts/example.mjs", round: 2 };

const withRealEmptyLedger = verifyProvenance(originalClaim, []);
assert.equal(withRealEmptyLedger.status, "verified", "a real, merely-empty ledger legitimately confirms an untouched original claim");

const withUnavailableLedger = verifyProvenance(originalClaim, null);
assert.equal(withUnavailableLedger.status, "unverified", "an UNAVAILABLE ledger must never verify a claim it never actually checked");

console.log("ledger-availability smoke check OK");
'

echo "== dev-flow-exit.mjs: split-candidate boundary cases (#747) =="
node --input-type=module -e '
import { computeSplitCandidate } from "./scripts/dev-flow-exit.mjs";
import assert from "node:assert/strict";

// Findings arrive at computeSplitCandidate already carrying the adjudicated
// priority and the VERIFIED provenance applyVerification computed — the same
// state computeVerdict sees. These fixtures build that state directly so the
// boundary cases stay readable; the end-to-end path is the
// omator-648-split-candidate-at-r9 conformance fixture.
const finding = (id, path, round, provenance, priority = "P1", provenanceStatus = "verified") => ({
  id,
  path,
  round,
  adjudicated_priority: priority,
  verifiedProvenance: provenance,
  provenanceStatus,
});
const complete = (round, findings) => ({ round, status: "complete", findings });

// A single round can never be a split candidate: "concentrating across
// consecutive rounds" needs a previous round to have concentrated in.
const loneRound = [complete(1, [finding("review-r1-f-1", "a.ts", 1, "round:0")])];
const lone = computeSplitCandidate(loneRound, 0, []);
assert.equal(lone.detected, false);
assert.equal(lone.reason, "not_consecutive");

// A round with no gating findings has nothing to concentrate, and says so
// distinctly rather than reporting a negative concentration verdict.
const cleanRound = [complete(1, [finding("review-r1-f-1", "a.ts", 1, "original", "P2")])];
const clean = computeSplitCandidate(cleanRound, 0, []);
assert.equal(clean.reason, "no_gating_findings");
assert.equal(clean.mechanism, null);
assert.equal(clean.concentration, 0);

// Two adjacent rounds concentrated in one mechanism, with the current round
// attributed to the previous round s own fix: the detected case.
const detectedRounds = [
  complete(1, [finding("review-r1-f-1", "m.ts", 1, "round:0")]),
  complete(2, [finding("review-r2-f-1", "m.ts", 2, "round:1"), finding("review-r2-f-2", "m.ts", 2, "round:1")]),
];
const detected = computeSplitCandidate(detectedRounds, 1, []);
assert.equal(detected.detected, true);
assert.equal(detected.mechanism, "m.ts");
assert.equal(detected.concentration, 1);
assert.deepEqual(detected.introduced_by_rounds, [1]);
assert.deepEqual(detected.consecutive_rounds, [1, 2]);
assert.deepEqual(detected.finding_ids, ["review-r2-f-1", "review-r2-f-2"]);

// One stray finding elsewhere breaks unanimity — the knob-free concentration
// test is ALL of the round s gating findings, never a tunable majority.
const strayRounds = [
  complete(1, [finding("review-r1-f-1", "m.ts", 1, "round:0")]),
  complete(2, [
    finding("review-r2-f-1", "m.ts", 2, "round:1"),
    finding("review-r2-f-2", "m.ts", 2, "round:1"),
    finding("review-r2-f-3", "other.ts", 2, "original"),
  ]),
];
const stray = computeSplitCandidate(strayRounds, 1, []);
assert.equal(stray.detected, false);
assert.equal(stray.reason, "not_concentrated");
assert.equal(stray.mechanism, "m.ts");
assert.ok(stray.concentration < 1);

// A rename between rounds is ONE mechanism, not two paths that never
// concentrate: the ledger s rename chain resolves both to the origin path.
const renameLedger = [
  { round: 1, path: "m.ts", added_lines: [10], deleted_lines: [], renamed_from: null },
  { round: 2, path: "renamed.ts", added_lines: [10], deleted_lines: [], renamed_from: "m.ts" },
];
const renamedRounds = [
  complete(2, [finding("review-r2-f-1", "m.ts", 2, "round:1")]),
  complete(3, [finding("review-r3-f-1", "renamed.ts", 3, "round:2")]),
];
const renamed = computeSplitCandidate(renamedRounds, 1, renameLedger);
assert.equal(renamed.mechanism, "m.ts", "a renamed mechanism resolves to its origin path");
assert.equal(renamed.detected, true);

// An unverified provenance claim leaves BOTH sides of the share, exactly as
// predicate_provenance_share treats it — evidence nobody could check must
// neither manufacture nor mask the signal.
const unverifiedRounds = [
  complete(1, [finding("review-r1-f-1", "m.ts", 1, "round:0")]),
  complete(2, [
    finding("review-r2-f-1", "m.ts", 2, "round:1"),
    finding("review-r2-f-2", "m.ts", 2, "original", "P1", "unverified"),
  ]),
];
const unverified = computeSplitCandidate(unverifiedRounds, 1, []);
assert.equal(unverified.provenance_share, 1, "the unverified finding leaves the denominator, not just the numerator");
assert.equal(unverified.concentration, 1, "concentration still counts every gating finding, verified or not");
assert.equal(unverified.detected, true);

// Concentration with no round attribution at all is an under-reviewed change,
// not a loop feeding on its own fixes.
const originalRounds = [
  complete(1, [finding("review-r1-f-1", "spec.md", 1, "original")]),
  complete(2, [finding("review-r2-f-1", "spec.md", 2, "original")]),
];
const originals = computeSplitCandidate(originalRounds, 1, []);
assert.equal(originals.detected, false);
assert.equal(originals.reason, "no_round_provenance");

console.log("split-candidate boundary checks OK");
'

echo "== devflow-policy.mjs never operates under this repo'\''s live legacy .devflow.toml =="
if node scripts/devflow-policy.mjs resolve --policy .devflow.toml >"${scratch}/dfp-live-$$.out" 2>"${scratch}/dfp-live-$$.err"; then
    rm -f "${scratch}/dfp-live-$$.out" "${scratch}/dfp-live-$$.err"
    fail "resolve against the live .devflow.toml unexpectedly succeeded — it must refuse the legacy shape"
fi
grep -q "legacy" "${scratch}/dfp-live-$$.err" || {
    cat "${scratch}/dfp-live-$$.err" >&2
    rm -f "${scratch}/dfp-live-$$.out" "${scratch}/dfp-live-$$.err"
    fail "refusal message did not name the legacy shape"
}
rm -f "${scratch}/dfp-live-$$.out" "${scratch}/dfp-live-$$.err"
echo "OK: live .devflow.toml (legacy shape) is refused as the operating policy"

echo "== --closure refuses a merge base with no reader (never falls back to the branch copy) =="
empty_closure="$(mktemp -d)"
mkdir -p "${empty_closure}/scripts"
if node scripts/devflow-policy.mjs resolve --policy .devflow.toml --closure "${empty_closure}" \
    >/dev/null 2>"${scratch}/dfp-closure-$$.err"; then
    rm -rf "${empty_closure}" "${scratch}/dfp-closure-$$.err"
    fail "--closure with no reader in the closure directory unexpectedly succeeded"
fi
grep -q "reader must land" "${scratch}/dfp-closure-$$.err" || {
    cat "${scratch}/dfp-closure-$$.err" >&2
    rm -rf "${empty_closure}" "${scratch}/dfp-closure-$$.err"
    fail "refusal message did not explain that the reader must land on the merge base first"
}
rm -rf "${empty_closure}" "${scratch}/dfp-closure-$$.err"
echo "OK: a merge base predating the reader itself is refused, not silently satisfied by the branch copy"

echo "== devflow-policy.mjs usage errors =="
if node scripts/devflow-policy.mjs resolve >/dev/null 2>"${scratch}/dfp-usage-$$.err"; then
    rm -f "${scratch}/dfp-usage-$$.err"
    fail "resolve with no --policy unexpectedly succeeded"
fi
grep -q -- "--policy" "${scratch}/dfp-usage-$$.err" || fail "usage error did not mention --policy"
rm -f "${scratch}/dfp-usage-$$.err"
echo "OK: resolve without --policy is a usage error"

if node scripts/devflow-policy.mjs detect >/dev/null 2>"${scratch}/dfp-detect-usage-$$.err"; then
    rm -f "${scratch}/dfp-detect-usage-$$.err"
    fail "detect with no --policy unexpectedly succeeded"
fi
grep -q -- "--policy" "${scratch}/dfp-detect-usage-$$.err" || fail "detect usage error did not mention --policy"
rm -f "${scratch}/dfp-detect-usage-$$.err"
echo "OK: detect without --policy is a usage error, not an uncaught exception"

if node scripts/devflow-policy.mjs detect --policy /nonexistent-devflow-policy.toml \
    >"${scratch}/dfp-detect-missing-$$.out" 2>"${scratch}/dfp-detect-missing-$$.err"; then
    rm -f "${scratch}/dfp-detect-missing-$$.out" "${scratch}/dfp-detect-missing-$$.err"
    fail "detect with a missing --policy file unexpectedly succeeded"
fi
grep -q "ENOENT\|could not read/parse" "${scratch}/dfp-detect-missing-$$.err" ||
    fail "detect on a missing --policy file did not report a clean read/parse error"
grep -q "at readFileSync\|at loadTomlFile" "${scratch}/dfp-detect-missing-$$.err" &&
    fail "detect on a missing --policy file leaked a raw Node stack trace instead of a clean error"
rm -f "${scratch}/dfp-detect-missing-$$.out" "${scratch}/dfp-detect-missing-$$.err"
echo "OK: detect on a missing --policy file fails closed, no uncaught stack trace"

if node scripts/devflow-policy.mjs detect --policy /nonexistent-devflow-policy.toml --json \
    >"${scratch}/dfp-detect-json-$$.out" 2>"${scratch}/dfp-detect-json-$$.err"; then
    rm -f "${scratch}/dfp-detect-json-$$.out" "${scratch}/dfp-detect-json-$$.err"
    fail "detect --json with a missing --policy file unexpectedly succeeded"
fi
node -e '
const fs = require("fs");
const body = fs.readFileSync(process.argv[1], "utf8").trim();
if (!body) { console.error("detect --json emitted no stdout body for a read/parse failure"); process.exit(1); }
const parsed = JSON.parse(body);
if (parsed.shape !== null || !parsed.error) { console.error("detect --json body did not report a structured error: " + body); process.exit(1); }
' "${scratch}/dfp-detect-json-$$.out" || fail "detect --json did not emit a structured error body on a read/parse failure"
rm -f "${scratch}/dfp-detect-json-$$.out" "${scratch}/dfp-detect-json-$$.err"
echo "OK: detect --json emits a structured error body (not empty stdout) on a read/parse failure"

echo "== dev-flow-exit.mjs usage errors =="
if node scripts/dev-flow-exit.mjs --stage nonsense --run /nonexistent --policy /nonexistent >/dev/null 2>"${scratch}/dfe-usage-$$.err"; then
    rm -f "${scratch}/dfe-usage-$$.err"
    fail "dev-flow-exit with an invalid --stage unexpectedly succeeded"
fi
grep -q -- "--stage" "${scratch}/dfe-usage-$$.err" || fail "usage error did not mention --stage"
rm -f "${scratch}/dfe-usage-$$.err"
echo "OK: an invalid --stage is a usage error"

echo "== dev-flow-exit.mjs refuses a policy cross-validation would reject, even standalone (no --registry/--task-targets) =="
empty_run="$(mktemp -d)"
mkdir -p "${empty_run}/passes" "${empty_run}/adjudications"
printf '{"run_id":"run-crossval-check","initiated_by":"human","receipts":[]}' >"${empty_run}/run.json"
if node scripts/dev-flow-exit.mjs --run "${empty_run}" --stage review \
    --policy ai/schemas/fixtures/exit/breadth-insufficient-for-fallback-chain/policy.toml \
    --current-head deadbeef --json >/dev/null 2>"${scratch}/dfe-crossval-$$.err"; then
    rm -rf "${empty_run}" "${scratch}/dfe-crossval-$$.err"
    fail "dev-flow-exit against a breadth-insufficient policy unexpectedly succeeded"
fi
grep -q "cannot cover" "${scratch}/dfe-crossval-$$.err" || {
    cat "${scratch}/dfe-crossval-$$.err" >&2
    rm -rf "${empty_run}" "${scratch}/dfe-crossval-$$.err"
    fail "refusal message did not explain the breadth shortfall"
}
rm -rf "${empty_run}" "${scratch}/dfe-crossval-$$.err"
echo "OK: dev-flow-exit refuses a policy that fails cross-validation before ever reading --run"

echo "== task devflow:policy -- detect reports v2 for a v2 policy =="
if ! task devflow:policy -- detect --policy ai/schemas/fixtures/exit/single-round-clean-converge/policy.toml \
    >"${scratch}/dfp-detect-v2-$$.out" 2>"${scratch}/dfp-detect-v2-$$.err"; then
    cat "${scratch}/dfp-detect-v2-$$.out" "${scratch}/dfp-detect-v2-$$.err" >&2
    rm -f "${scratch}/dfp-detect-v2-$$.out" "${scratch}/dfp-detect-v2-$$.err"
    fail "task devflow:policy -- detect on a v2 policy unexpectedly failed (exit 0 means v2)"
fi
grep -q "shape: v2" "${scratch}/dfp-detect-v2-$$.out" || {
    cat "${scratch}/dfp-detect-v2-$$.out" >&2
    rm -f "${scratch}/dfp-detect-v2-$$.out" "${scratch}/dfp-detect-v2-$$.err"
    fail "detect did not report shape: v2"
}
rm -f "${scratch}/dfp-detect-v2-$$.out" "${scratch}/dfp-detect-v2-$$.err"
echo "OK: task devflow:policy -- detect reports v2 through the Taskfile wrapper"

echo "== task devflow:policy -- detect reports legacy for this repo's own .devflow.toml =="
if task devflow:policy -- detect --policy .devflow.toml \
    >"${scratch}/dfp-detect-legacy-$$.out" 2>"${scratch}/dfp-detect-legacy-$$.err"; then
    cat "${scratch}/dfp-detect-legacy-$$.out" "${scratch}/dfp-detect-legacy-$$.err" >&2
    rm -f "${scratch}/dfp-detect-legacy-$$.out" "${scratch}/dfp-detect-legacy-$$.err"
    fail "task devflow:policy -- detect on this repo's own legacy policy unexpectedly reported v2 (exit 0)"
fi
grep -q "shape: legacy" "${scratch}/dfp-detect-legacy-$$.out" || {
    cat "${scratch}/dfp-detect-legacy-$$.out" >&2
    rm -f "${scratch}/dfp-detect-legacy-$$.out" "${scratch}/dfp-detect-legacy-$$.err"
    fail "detect did not report shape: legacy for this repo's own .devflow.toml"
}
rm -f "${scratch}/dfp-detect-legacy-$$.out" "${scratch}/dfp-detect-legacy-$$.err"
echo "OK: task devflow:policy -- detect reports legacy through the Taskfile wrapper"
echo "   (detect only classifies shape — it never resolves — so reading the live"
echo "   .devflow.toml here is the same sanctioned exception as the refusal check above)"

echo "== task devflow:policy -- resolve works through the Taskfile wrapper, not just the bare script =="
if ! task devflow:policy -- resolve --policy ai/schemas/fixtures/exit/single-round-clean-converge/policy.toml \
    --registry ai/schemas/fixtures/exit/single-round-clean-converge/registry.json \
    --task-targets ai/schemas/fixtures/exit/single-round-clean-converge/task-targets.json --json \
    >"${scratch}/dfp-task-resolve-$$.out" 2>"${scratch}/dfp-task-resolve-$$.err"; then
    cat "${scratch}/dfp-task-resolve-$$.out" "${scratch}/dfp-task-resolve-$$.err" >&2
    rm -f "${scratch}/dfp-task-resolve-$$.out" "${scratch}/dfp-task-resolve-$$.err"
    fail "task devflow:policy -- resolve unexpectedly failed"
fi
grep -v -e '^::group::' -e '^::endgroup::' "${scratch}/dfp-task-resolve-$$.out" |
    node -e 'JSON.parse(require("node:fs").readFileSync(0, "utf8"))' || {
    cat "${scratch}/dfp-task-resolve-$$.out" >&2
    rm -f "${scratch}/dfp-task-resolve-$$.out" "${scratch}/dfp-task-resolve-$$.err"
    fail "task devflow:policy -- resolve --json (its Taskfile ::group::/::endgroup:: wrapper stripped) did not produce valid JSON"
}
rm -f "${scratch}/dfp-task-resolve-$$.out" "${scratch}/dfp-task-resolve-$$.err"
echo "OK: task devflow:policy -- resolve produces valid JSON through the Taskfile wrapper"
echo "   (Taskfile.yml's global output: group wraps every task's stdout in"
echo "   ::group::<task>/::endgroup:: markers — a caller parsing --json through"
echo "   'task ... --' must strip those two lines first, or call the bare script)"

echo "== task devflow:exit works through the Taskfile wrapper, not just the bare script =="
# dev-flow-exit.mjs's exit code IS its verdict (0 continue, 20 converged, 21
# diverging, 22 capped) — this fixture converges, so a non-zero exit here is
# expected. Task itself does not propagate that exact code (observed 201
# regardless of the underlying script's real 20) — a caller wanting the
# precise verdict code, not just its JSON, should call the bare script/
# dev-flow-exit.sh directly, so this checks the JSON content instead of any
# particular shell exit status.
task devflow:exit -- --run ai/schemas/fixtures/exit/single-round-clean-converge/run --stage review \
    --policy ai/schemas/fixtures/exit/single-round-clean-converge/policy.toml \
    --current-head 0101010101010101010101010101010101010101 --json \
    >"${scratch}/dfe-task-$$.out" 2>"${scratch}/dfe-task-$$.err" || true
outcome="$(grep -v -e '^::group::' -e '^::endgroup::' "${scratch}/dfe-task-$$.out" | node -e '
  const body = require("node:fs").readFileSync(0, "utf8");
  console.log(JSON.parse(body).outcome);
')" || {
    cat "${scratch}/dfe-task-$$.out" "${scratch}/dfe-task-$$.err" >&2
    rm -f "${scratch}/dfe-task-$$.out" "${scratch}/dfe-task-$$.err"
    fail "task devflow:exit --json (its Taskfile ::group::/::endgroup:: wrapper stripped) did not produce valid JSON"
}
[ "${outcome}" = "converged" ] || {
    cat "${scratch}/dfe-task-$$.out" >&2
    rm -f "${scratch}/dfe-task-$$.out" "${scratch}/dfe-task-$$.err"
    fail "task devflow:exit: expected outcome \"converged\" for this fixture, got \"${outcome}\""
}
rm -f "${scratch}/dfe-task-$$.out" "${scratch}/dfe-task-$$.err"
echo "OK: task devflow:exit produces the correct verdict JSON through the Taskfile wrapper"

# `|| true` on every dev-flow-exit.mjs invocation below: its exit code IS
# its verdict (0 continue, 2 indeterminate, 20 converged, 21 diverging,
# 22 capped), so under this file's `set -e` a converged control run would
# abort the suite. Each assertion reads the JSON body instead, exactly as
# the corpus runner and the Taskfile-wrapper cases above do.
#
# harmon-devkit#685 — the two run-span chronology bounds and the second
# stage-skip edge, which the fixture corpus does not reach: a fixture
# exercises exactly one pass timestamp and one --stage, while these are
# variations on the SAME run directory. The stage-entry bound and the
# verify -> review edge are fixtures
# (pass-produced-before-stage-entry-rejected,
# stage-skip-to-review-under-nonzero-challenge-cap-rejected); these are
# their siblings.
echo "== #685: produced_at outside the run's own span rejects the pass; inside it does not =="
span_fixture="ai/schemas/fixtures/exit/pass-produced-within-run-span-accepted"
span_dir="$(mktemp -d)"
cp -r "${span_fixture}/." "${span_dir}/"
span_head=0101010101010101010101010101010101010101

# The unmodified copy is the control: it must still converge, so a failure
# below is the timestamp under test and never the copy itself.
node scripts/dev-flow-exit.mjs --run "${span_dir}/run" --stage review \
    --policy "${span_dir}/policy.toml" --current-head "${span_head}" --json \
    >"${scratch}/dfe-span-control-$$.out" 2>/dev/null || true
[ "$(node -e 'console.log(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).outcome)' "${scratch}/dfe-span-control-$$.out")" = converged ] || {
    cat "${scratch}/dfe-span-control-$$.out" >&2
    rm -rf "${span_dir}" "${scratch}/dfe-span-control-$$.out"
    fail "the unmodified run-span fixture no longer converges — the control for the two bounds below is broken"
}
rm -f "${scratch}/dfe-span-control-$$.out"

# $1 = produced_at to plant, $2 = the phrase the diagnostic must carry.
assert_span_rejection() {
    node -e '
      const fs = require("node:fs");
      const file = process.argv[1];
      const pass = JSON.parse(fs.readFileSync(file, "utf8"));
      pass.produced_at = process.argv[2];
      fs.writeFileSync(file, JSON.stringify(pass, null, 2) + "\n");
    ' "${span_dir}/run/passes/review-r1-codex-cli.json" "$1"
    node scripts/dev-flow-exit.mjs --run "${span_dir}/run" --stage review \
        --policy "${span_dir}/policy.toml" --current-head "${span_head}" --json \
        >"${scratch}/dfe-span-$$.out" 2>/dev/null || true
    node -e '
      const body = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
      const phrase = process.argv[2];
      const hit = (body.diagnostics || []).some((d) => d.reason && d.reason.includes(phrase));
      if (!hit) {
        console.error(`no diagnostic contains "${phrase}": ${JSON.stringify(body.diagnostics)}`);
        process.exit(1);
      }
      if (body.outcome === "converged") {
        console.error("the pass was rejected but the stage still converged on it");
        process.exit(1);
      }
    ' "${scratch}/dfe-span-$$.out" "$2" || {
        cat "${scratch}/dfe-span-$$.out" >&2
        rm -rf "${span_dir}" "${scratch}/dfe-span-$$.out"
        fail "#685: produced_at $1 was not rejected as $2"
    }
    rm -f "${scratch}/dfe-span-$$.out"
}

assert_span_rejection "2026-08-29T08:00:00Z" "is before the run's own started_at"
assert_span_rejection "2026-08-29T19:00:00Z" "is after the run's promotion.promoted_at"
rm -rf "${span_dir}"
echo "OK: a pass produced before the run started, or after it was promoted, contributes nothing"

echo "== #685: a bound that is PRESENT but malformed refuses the trajectory, never silently disabling itself =="
# Challenge round 1, confirmed: the first version of this check treated any
# non-string as absent, so `started_at: 12345` in a run directory that is not
# schema-validated on this path quietly turned the bound off. Absent stays
# absent (the fixture above proves that); present-and-wrong is terminal.
bound_dir="$(mktemp -d)"
# $1 = a jq program mutating run.json, $2 = the phrase the refusal must carry.
assert_bound_refusal() {
    rm -rf "${bound_dir:?}/"*
    cp -r "${span_fixture}/." "${bound_dir}/"
    jq "$1" "${bound_dir}/run/run.json" >"${bound_dir}/run/run.json.tmp"
    mv "${bound_dir}/run/run.json.tmp" "${bound_dir}/run/run.json"
    node scripts/dev-flow-exit.mjs --run "${bound_dir}/run" --stage review \
        --policy "${bound_dir}/policy.toml" --current-head "${span_head}" --json \
        >"${scratch}/dfe-bound-$$.out" 2>/dev/null || true
    node -e '
      const body = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
      if (body.outcome !== "indeterminate") { console.error(`expected indeterminate, got ${body.outcome}`); process.exit(1); }
      if (!body.reason.includes(process.argv[2])) { console.error(`reason did not name the malformed bound: ${body.reason}`); process.exit(1); }
    ' "${scratch}/dfe-bound-$$.out" "$2" || {
        cat "${scratch}/dfe-bound-$$.out" >&2
        rm -rf "${bound_dir}" "${scratch}/dfe-bound-$$.out"
        fail "#685: a malformed bound ($1) did not refuse the trajectory"
    }
    rm -f "${scratch}/dfe-bound-$$.out"
}

assert_bound_refusal '.started_at = 12345' "started_at is present but not a string"
assert_bound_refusal '.promotion = "nope"' "promotion is present but not an object"
assert_bound_refusal '.promotion = {}' "promotion has no promoted_at"
assert_bound_refusal '.receipts[0].entered_at = 7' "entered_at is present but not a string"
# A null promotion is the schema's own "not promoted yet", not malformed.
rm -rf "${bound_dir:?}/"*
cp -r "${span_fixture}/." "${bound_dir}/"
jq '.promotion = null' "${bound_dir}/run/run.json" >"${bound_dir}/run/run.json.tmp"
mv "${bound_dir}/run/run.json.tmp" "${bound_dir}/run/run.json"
node scripts/dev-flow-exit.mjs --run "${bound_dir}/run" --stage review \
    --policy "${bound_dir}/policy.toml" --current-head "${span_head}" --json \
    >"${scratch}/dfe-bound-null-$$.out" 2>/dev/null || true
[ "$(node -e 'console.log(JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8")).outcome)' "${scratch}/dfe-bound-null-$$.out")" = converged ] || {
    cat "${scratch}/dfe-bound-null-$$.out" >&2
    rm -rf "${bound_dir}" "${scratch}/dfe-bound-null-$$.out"
    fail "#685: a null promotion is the not-promoted-yet case and must not refuse the trajectory"
}
rm -rf "${bound_dir}" "${scratch}/dfe-bound-null-$$.out"
echo "OK: a present-but-malformed bound is terminal; a null promotion is not"

echo "== #685: a present-but-non-array receipts/slot_failures is a structured indeterminate, never a stack trace =="
# Review round 1 (P2), confirmed and reproduced: `receipts` is read before
# validateReceipts applies its own Array.isArray guard, so a non-array value
# threw a raw TypeError — exit 1, EMPTY stdout under --json — exactly where
# the machine contract promises a structured body on every exit.
array_dir="$(mktemp -d)"
# $1 = jq program poisoning run.json, $2 = the phrase the refusal must carry.
assert_array_refusal() {
    rm -rf "${array_dir:?}/"*
    cp -r "${span_fixture}/." "${array_dir}/"
    jq "$1" "${array_dir}/run/run.json" >"${array_dir}/run/run.json.tmp"
    mv "${array_dir}/run/run.json.tmp" "${array_dir}/run/run.json"
    node scripts/dev-flow-exit.mjs --run "${array_dir}/run" --stage review \
        --policy "${array_dir}/policy.toml" --current-head "${span_head}" --json \
        >"${scratch}/dfe-array-$$.out" 2>/dev/null || true
    node -e '
      const fs = require("node:fs");
      const raw = fs.readFileSync(process.argv[1], "utf8");
      if (raw.trim() === "") { console.error("--json produced NO stdout body at all"); process.exit(1); }
      const body = JSON.parse(raw);
      if (body.outcome !== "indeterminate") { console.error(`expected indeterminate, got ${body.outcome}`); process.exit(1); }
      if (!body.reason.includes(process.argv[2])) { console.error(`reason did not name the malformed field: ${body.reason}`); process.exit(1); }
    ' "${scratch}/dfe-array-$$.out" "$2" || {
        cat "${scratch}/dfe-array-$$.out" >&2
        rm -rf "${array_dir}" "${scratch}/dfe-array-$$.out"
        fail "#685: a non-array collection ($1) did not produce a structured indeterminate"
    }
    rm -f "${scratch}/dfe-array-$$.out"
}

assert_array_refusal '.receipts = {"kind":"transition"}' "receipts is present but not an array"
assert_array_refusal '.slot_failures = "none"' "slot_failures is present but not an array"
rm -rf "${array_dir}"
echo "OK: a malformed receipts/slot_failures collection exits with a verdict body, not a stack trace"

echo "== #685: a pass file holding JSON null is a structured indeterminate, not a stack trace =="
# Integrate cycle 3 on PR #800 (P2), confirmed: the cross-stage cap-0 scan
# dereferences every pass's envelope before receipt validation runs, so a
# pass file containing valid JSON `null` threw a raw TypeError — exit 1,
# EMPTY stdout under --json — where the machine contract promises a body.
null_pass_dir="$(mktemp -d)"
cp -r "${span_fixture}/." "${null_pass_dir}/"
printf 'null\n' >"${null_pass_dir}/run/passes/review-r1-codex-cli.json"
node scripts/dev-flow-exit.mjs --run "${null_pass_dir}/run" --stage review \
    --policy "${null_pass_dir}/policy.toml" --current-head "${span_head}" --json \
    >"${scratch}/dfe-nullpass-$$.out" 2>/dev/null || true
node -e '
  const fs = require("node:fs");
  const raw = fs.readFileSync(process.argv[1], "utf8");
  if (raw.trim() === "") { console.error("--json produced NO stdout body at all"); process.exit(1); }
  const body = JSON.parse(raw);
  if (body.outcome !== "indeterminate") { console.error(`expected indeterminate, got ${body.outcome}`); process.exit(1); }
  if (!body.reason.includes("does not contain a JSON object")) { console.error(`reason did not name the malformed pass: ${body.reason}`); process.exit(1); }
' "${scratch}/dfe-nullpass-$$.out" || {
    cat "${scratch}/dfe-nullpass-$$.out" >&2
    rm -rf "${null_pass_dir}" "${scratch}/dfe-nullpass-$$.out"
    fail "#685: a JSON-null pass file did not produce a structured indeterminate"
}
rm -rf "${null_pass_dir}" "${scratch}/dfe-nullpass-$$.out"
echo "OK: a malformed pass envelope exits with a verdict body, not a stack trace"

echo "== #685: a recorded verify -> security edge needs a cap-0 review policy, exactly like verify -> review =="
skip_fixture="ai/schemas/fixtures/exit/stage-skip-to-review-under-nonzero-challenge-cap-rejected"
skip_dir="$(mktemp -d)"
cp -r "${skip_fixture}/." "${skip_dir}/"
# Disable challenge in this copy so the assertion isolates the REVIEW half:
# a verify -> security edge bypasses both confidence stages (integrate cycle 4
# on PR #800), and with challenge still capped the refusal would name
# challenge first — correct, but not what this case is about.
node -e '
  const fs = require("node:fs");
  const file = process.argv[1];
  fs.writeFileSync(file, fs.readFileSync(file, "utf8")
    .replace(/^challenge = 3$/m, "challenge = 0")
    .replace(/\[stage\.challenge\]\nfinders = \["codex-cli"\]\nfinder_fallbacks = \["gemini-cli"\]/,
             "[stage.challenge]\nfinders = []\nfinder_fallbacks = []"));
' "${skip_dir}/policy.toml"
node -e '
  const fs = require("node:fs");
  const file = process.argv[1];
  const run = JSON.parse(fs.readFileSync(file, "utf8"));
  // Record verify -> security instead of verify -> review, and drop the
  // review pass with it: the point is the recorded EDGE, not the round.
  run.receipts = [
    { kind: "transition", stage: "verify" },
    { kind: "transition", stage: "security" },
  ];
  delete run.slot_failures;
  fs.writeFileSync(file, JSON.stringify(run, null, 2) + "\n");
' "${skip_dir}/run/run.json"
rm -f "${skip_dir}"/run/passes/*.json "${skip_dir}"/run/adjudications/*.json
node scripts/dev-flow-exit.mjs --run "${skip_dir}/run" --stage review \
    --policy "${skip_dir}/policy.toml" --current-head 0101010101010101010101010101010101010101 --json \
    >"${scratch}/dfe-skip-sec-$$.out" 2>/dev/null || true
node -e '
  const body = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (body.outcome !== "indeterminate") { console.error(`expected indeterminate, got ${body.outcome}`); process.exit(1); }
  if (!body.reason.includes(process.argv[2])) {
    console.error(`reason did not name the skipped review stage and its cap: ${body.reason}`);
    process.exit(1);
  }
' "${scratch}/dfe-skip-sec-$$.out" 'with no earlier transition into "review", but the resolved review cap is 3' || {
    cat "${scratch}/dfe-skip-sec-$$.out" >&2
    rm -rf "${skip_dir}" "${scratch}/dfe-skip-sec-$$.out"
    fail "#685: a recorded verify -> security edge under a nonzero review cap was not refused"
}
rm -rf "${skip_dir}" "${scratch}/dfe-skip-sec-$$.out"
echo "OK: verify -> security is refused under a nonzero review cap"

echo "== conformance fixture corpus (ai/schemas/fixtures/exit/) =="
[ -d ai/schemas/fixtures/exit ] || fail "missing ai/schemas/fixtures/exit/"
node scripts/lib/run-exit-fixtures.mjs

echo "dev-flow-exit conformance OK"
