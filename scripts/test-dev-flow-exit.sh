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
    echo "TEST FAIL: $*" >&2
    exit 1
}

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

echo "== devflow-policy.mjs never operates under this repo'\''s live legacy .devflow.toml =="
if node scripts/devflow-policy.mjs resolve --policy .devflow.toml >/tmp/dfp-live-$$.out 2>/tmp/dfp-live-$$.err; then
    rm -f "/tmp/dfp-live-$$.out" "/tmp/dfp-live-$$.err"
    fail "resolve against the live .devflow.toml unexpectedly succeeded — it must refuse the legacy shape"
fi
grep -q "legacy" "/tmp/dfp-live-$$.err" || {
    cat "/tmp/dfp-live-$$.err" >&2
    rm -f "/tmp/dfp-live-$$.out" "/tmp/dfp-live-$$.err"
    fail "refusal message did not name the legacy shape"
}
rm -f "/tmp/dfp-live-$$.out" "/tmp/dfp-live-$$.err"
echo "OK: live .devflow.toml (legacy shape) is refused as the operating policy"

echo "== --closure refuses a merge base with no reader (never falls back to the branch copy) =="
empty_closure="$(mktemp -d)"
mkdir -p "${empty_closure}/scripts"
if node scripts/devflow-policy.mjs resolve --policy .devflow.toml --closure "${empty_closure}" \
    >/dev/null 2>"/tmp/dfp-closure-$$.err"; then
    rm -rf "${empty_closure}" "/tmp/dfp-closure-$$.err"
    fail "--closure with no reader in the closure directory unexpectedly succeeded"
fi
grep -q "reader must land" "/tmp/dfp-closure-$$.err" || {
    cat "/tmp/dfp-closure-$$.err" >&2
    rm -rf "${empty_closure}" "/tmp/dfp-closure-$$.err"
    fail "refusal message did not explain that the reader must land on the merge base first"
}
rm -rf "${empty_closure}" "/tmp/dfp-closure-$$.err"
echo "OK: a merge base predating the reader itself is refused, not silently satisfied by the branch copy"

echo "== devflow-policy.mjs usage errors =="
if node scripts/devflow-policy.mjs resolve >/dev/null 2>/tmp/dfp-usage-$$.err; then
    rm -f "/tmp/dfp-usage-$$.err"
    fail "resolve with no --policy unexpectedly succeeded"
fi
grep -q -- "--policy" "/tmp/dfp-usage-$$.err" || fail "usage error did not mention --policy"
rm -f "/tmp/dfp-usage-$$.err"
echo "OK: resolve without --policy is a usage error"

if node scripts/devflow-policy.mjs detect >/dev/null 2>/tmp/dfp-detect-usage-$$.err; then
    rm -f "/tmp/dfp-detect-usage-$$.err"
    fail "detect with no --policy unexpectedly succeeded"
fi
grep -q -- "--policy" "/tmp/dfp-detect-usage-$$.err" || fail "detect usage error did not mention --policy"
rm -f "/tmp/dfp-detect-usage-$$.err"
echo "OK: detect without --policy is a usage error, not an uncaught exception"

if node scripts/devflow-policy.mjs detect --policy /nonexistent-devflow-policy.toml \
    >/tmp/dfp-detect-missing-$$.out 2>/tmp/dfp-detect-missing-$$.err; then
    rm -f "/tmp/dfp-detect-missing-$$.out" "/tmp/dfp-detect-missing-$$.err"
    fail "detect with a missing --policy file unexpectedly succeeded"
fi
grep -q "ENOENT\|could not read/parse" "/tmp/dfp-detect-missing-$$.err" ||
    fail "detect on a missing --policy file did not report a clean read/parse error"
grep -q "at readFileSync\|at loadTomlFile" "/tmp/dfp-detect-missing-$$.err" &&
    fail "detect on a missing --policy file leaked a raw Node stack trace instead of a clean error"
rm -f "/tmp/dfp-detect-missing-$$.out" "/tmp/dfp-detect-missing-$$.err"
echo "OK: detect on a missing --policy file fails closed, no uncaught stack trace"

if node scripts/devflow-policy.mjs detect --policy /nonexistent-devflow-policy.toml --json \
    >/tmp/dfp-detect-json-$$.out 2>/tmp/dfp-detect-json-$$.err; then
    rm -f "/tmp/dfp-detect-json-$$.out" "/tmp/dfp-detect-json-$$.err"
    fail "detect --json with a missing --policy file unexpectedly succeeded"
fi
node -e '
const fs = require("fs");
const body = fs.readFileSync(process.argv[1], "utf8").trim();
if (!body) { console.error("detect --json emitted no stdout body for a read/parse failure"); process.exit(1); }
const parsed = JSON.parse(body);
if (parsed.shape !== null || !parsed.error) { console.error("detect --json body did not report a structured error: " + body); process.exit(1); }
' "/tmp/dfp-detect-json-$$.out" || fail "detect --json did not emit a structured error body on a read/parse failure"
rm -f "/tmp/dfp-detect-json-$$.out" "/tmp/dfp-detect-json-$$.err"
echo "OK: detect --json emits a structured error body (not empty stdout) on a read/parse failure"

echo "== dev-flow-exit.mjs usage errors =="
if node scripts/dev-flow-exit.mjs --stage nonsense --run /nonexistent --policy /nonexistent >/dev/null 2>/tmp/dfe-usage-$$.err; then
    rm -f "/tmp/dfe-usage-$$.err"
    fail "dev-flow-exit with an invalid --stage unexpectedly succeeded"
fi
grep -q -- "--stage" "/tmp/dfe-usage-$$.err" || fail "usage error did not mention --stage"
rm -f "/tmp/dfe-usage-$$.err"
echo "OK: an invalid --stage is a usage error"

echo "== dev-flow-exit.mjs refuses a policy cross-validation would reject, even standalone (no --registry/--task-targets) =="
empty_run="$(mktemp -d)"
mkdir -p "${empty_run}/passes" "${empty_run}/adjudications"
printf '{"run_id":"run-crossval-check","initiated_by":"human","receipts":[]}' >"${empty_run}/run.json"
if node scripts/dev-flow-exit.mjs --run "${empty_run}" --stage review \
    --policy ai/schemas/fixtures/exit/breadth-insufficient-for-fallback-chain/policy.toml \
    --current-head deadbeef --json >/dev/null 2>"/tmp/dfe-crossval-$$.err"; then
    rm -rf "${empty_run}" "/tmp/dfe-crossval-$$.err"
    fail "dev-flow-exit against a breadth-insufficient policy unexpectedly succeeded"
fi
grep -q "cannot cover" "/tmp/dfe-crossval-$$.err" || {
    cat "/tmp/dfe-crossval-$$.err" >&2
    rm -rf "${empty_run}" "/tmp/dfe-crossval-$$.err"
    fail "refusal message did not explain the breadth shortfall"
}
rm -rf "${empty_run}" "/tmp/dfe-crossval-$$.err"
echo "OK: dev-flow-exit refuses a policy that fails cross-validation before ever reading --run"

echo "== task devflow:policy -- detect reports v2 for a v2 policy =="
if ! task devflow:policy -- detect --policy ai/schemas/fixtures/exit/single-round-clean-converge/policy.toml \
    >"/tmp/dfp-detect-v2-$$.out" 2>"/tmp/dfp-detect-v2-$$.err"; then
    cat "/tmp/dfp-detect-v2-$$.out" "/tmp/dfp-detect-v2-$$.err" >&2
    rm -f "/tmp/dfp-detect-v2-$$.out" "/tmp/dfp-detect-v2-$$.err"
    fail "task devflow:policy -- detect on a v2 policy unexpectedly failed (exit 0 means v2)"
fi
grep -q "shape: v2" "/tmp/dfp-detect-v2-$$.out" || {
    cat "/tmp/dfp-detect-v2-$$.out" >&2
    rm -f "/tmp/dfp-detect-v2-$$.out" "/tmp/dfp-detect-v2-$$.err"
    fail "detect did not report shape: v2"
}
rm -f "/tmp/dfp-detect-v2-$$.out" "/tmp/dfp-detect-v2-$$.err"
echo "OK: task devflow:policy -- detect reports v2 through the Taskfile wrapper"

echo "== task devflow:policy -- detect reports legacy for this repo's own .devflow.toml =="
if task devflow:policy -- detect --policy .devflow.toml \
    >"/tmp/dfp-detect-legacy-$$.out" 2>"/tmp/dfp-detect-legacy-$$.err"; then
    cat "/tmp/dfp-detect-legacy-$$.out" "/tmp/dfp-detect-legacy-$$.err" >&2
    rm -f "/tmp/dfp-detect-legacy-$$.out" "/tmp/dfp-detect-legacy-$$.err"
    fail "task devflow:policy -- detect on this repo's own legacy policy unexpectedly reported v2 (exit 0)"
fi
grep -q "shape: legacy" "/tmp/dfp-detect-legacy-$$.out" || {
    cat "/tmp/dfp-detect-legacy-$$.out" >&2
    rm -f "/tmp/dfp-detect-legacy-$$.out" "/tmp/dfp-detect-legacy-$$.err"
    fail "detect did not report shape: legacy for this repo's own .devflow.toml"
}
rm -f "/tmp/dfp-detect-legacy-$$.out" "/tmp/dfp-detect-legacy-$$.err"
echo "OK: task devflow:policy -- detect reports legacy through the Taskfile wrapper"
echo "   (detect only classifies shape — it never resolves — so reading the live"
echo "   .devflow.toml here is the same sanctioned exception as the refusal check above)"

echo "== task devflow:policy -- resolve works through the Taskfile wrapper, not just the bare script =="
if ! task devflow:policy -- resolve --policy ai/schemas/fixtures/exit/single-round-clean-converge/policy.toml \
    --registry ai/schemas/fixtures/exit/single-round-clean-converge/registry.json \
    --task-targets ai/schemas/fixtures/exit/single-round-clean-converge/task-targets.json --json \
    >"/tmp/dfp-task-resolve-$$.out" 2>"/tmp/dfp-task-resolve-$$.err"; then
    cat "/tmp/dfp-task-resolve-$$.out" "/tmp/dfp-task-resolve-$$.err" >&2
    rm -f "/tmp/dfp-task-resolve-$$.out" "/tmp/dfp-task-resolve-$$.err"
    fail "task devflow:policy -- resolve unexpectedly failed"
fi
grep -v -e '^::group::' -e '^::endgroup::' "/tmp/dfp-task-resolve-$$.out" |
    node -e 'JSON.parse(require("node:fs").readFileSync(0, "utf8"))' || {
    cat "/tmp/dfp-task-resolve-$$.out" >&2
    rm -f "/tmp/dfp-task-resolve-$$.out" "/tmp/dfp-task-resolve-$$.err"
    fail "task devflow:policy -- resolve --json (its Taskfile ::group::/::endgroup:: wrapper stripped) did not produce valid JSON"
}
rm -f "/tmp/dfp-task-resolve-$$.out" "/tmp/dfp-task-resolve-$$.err"
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
    >"/tmp/dfe-task-$$.out" 2>"/tmp/dfe-task-$$.err" || true
outcome="$(grep -v -e '^::group::' -e '^::endgroup::' "/tmp/dfe-task-$$.out" | node -e '
  const body = require("node:fs").readFileSync(0, "utf8");
  console.log(JSON.parse(body).outcome);
')" || {
    cat "/tmp/dfe-task-$$.out" "/tmp/dfe-task-$$.err" >&2
    rm -f "/tmp/dfe-task-$$.out" "/tmp/dfe-task-$$.err"
    fail "task devflow:exit --json (its Taskfile ::group::/::endgroup:: wrapper stripped) did not produce valid JSON"
}
[ "${outcome}" = "converged" ] || {
    cat "/tmp/dfe-task-$$.out" >&2
    rm -f "/tmp/dfe-task-$$.out" "/tmp/dfe-task-$$.err"
    fail "task devflow:exit: expected outcome \"converged\" for this fixture, got \"${outcome}\""
}
rm -f "/tmp/dfe-task-$$.out" "/tmp/dfe-task-$$.err"
echo "OK: task devflow:exit produces the correct verdict JSON through the Taskfile wrapper"

echo "== conformance fixture corpus (ai/schemas/fixtures/exit/) =="
[ -d ai/schemas/fixtures/exit ] || fail "missing ai/schemas/fixtures/exit/"
node scripts/lib/run-exit-fixtures.mjs

echo "dev-flow-exit conformance OK"
