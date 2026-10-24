#!/usr/bin/env bash
# Independent reviewer fixtures; no mutations to the blob-pinned conformance corpus.
set -euo pipefail
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo="$(git -C "$asset_dir" rev-parse --show-toplevel)"
reader="${1:-$asset_dir/devflow-policy.mjs}"
node --input-type=module - "$reader" "$repo/ai/schemas/fixtures/devflow-finders" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { spawnSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
const { readBranchPolicy, resolvePolicy, validateResolvedPolicy } = await import(pathToFileURL(process.argv[2]));
const fixture = process.argv[3];
const doc = readBranchPolicy(`${fixture}/policy.toml`);
const override = JSON.parse(readFileSync(`${fixture}/operator.json`, 'utf8'));
const repo = resolvePolicy(doc);
const entries = repo.stages.integration.finder;
assert.deepEqual(repo.stages.integration.finders, ['codex-cloud', 'claude', 'greptile', 'coderabbit-cloud', 'gemini']);
assert.equal(entries[0].gates, true);
assert.equal(entries[0].completion.actor_id, 199175422);
assert.equal(entries[1].budget, 2);
assert.equal(entries[1].rounds, 2);
assert.equal(entries[2].budget, 1);
assert.equal(entries[2].rounds, 1);
assert.equal(entries[3].budget, 3);
assert.deepEqual(entries[3].rounds, {full: [1], incremental: [2, 3]});
assert.equal(entries[3].trigger_incremental, 'coderabbit incremental');
assert.equal(entries[3].carry, 'identity-or-incremental');
assert.equal(Object.hasOwn(entries[4], 'budget'), false);
assert.equal(entries[4].completion.kind, 'workflow');
validateResolvedPolicy(repo);
const pr = resolvePolicy(doc, {runId: 'fixture-run', finderOverrides: override});
for (const [i, entry] of pr.stages.integration.finder.entries()) {
  assert.equal(entry.budget, override.finders[i].budget);
  assert.equal(entry.gates, !entries[i].gates);
  assert.equal(entry.trigger, entries[i].trigger);
  assert.deepEqual(entry.completion, entries[i].completion);
}
assert.deepEqual(pr.finder_overrides, {...override,
  instruction_sha256: createHash('sha256').update(override.instruction).digest('hex')});
assert.equal(pr.run_id, 'fixture-run');
assert.throws(() => resolvePolicy(doc, {runId: 'another-run', finderOverrides: override}), /run_id must match/);
assert.throws(() => resolvePolicy(doc, {finderOverrides: override}), /run_id must match/);
const stripped = structuredClone(pr);
delete stripped.finder_overrides;
assert.throws(() => validateResolvedPolicy(stripped), /must disclose every difference/);
const incomplete = structuredClone(pr);
incomplete.finder_overrides.finders.pop();
assert.throws(() => validateResolvedPolicy(incomplete), /must disclose every difference/);
const changedHash = structuredClone(pr);
changedHash.finder_overrides.instruction += ' edited';
assert.throws(() => validateResolvedPolicy(changedHash), /instruction_sha256/);
const wrongRun = structuredClone(pr);
wrongRun.run_id = 'another-run';
assert.throws(() => validateResolvedPolicy(wrongRun), /run_id must match/);
const noBaseline = structuredClone(pr);
delete noBaseline.finder_repository;
assert.throws(() => validateResolvedPolicy(noBaseline), /missing finder_repository/);
const fields = {trigger: 'operator full', trigger_incremental: 'operator incremental',
  rounds: {incremental: [4]}, completion: {kind: 'review', actor_id: 987}, carry: 'fresh'};
const changed = resolvePolicy(doc, {runId: 'fixture-run', finderOverrides: {...override, finders: [{id: 'coderabbit-cloud', ...fields}]}});
for (const [key, value] of Object.entries(fields)) assert.deepEqual(changed.stages.integration.finder[3][key], value);
validateResolvedPolicy(pr);
assert.equal(Object.hasOwn(doc.stage.integration.finder[4], 'budget'), false);
assert.equal(Object.hasOwn(repo.stages.integration.finder[4], 'budget'), false);
const legacy = structuredClone(doc);
delete legacy.stage.integration.finder;
legacy.stage.integration.finders = ['codex-cloud'];
assert.deepEqual(resolvePolicy(legacy).stages.integration, {
  finders: ['codex-cloud'], finder_fallbacks: [], pool: null, review_trigger: 'after-ci',
});
// A new branch cannot replace the governing merge-base reviewer settings.
const branch = structuredClone(doc);
branch.stage.integration.finder[1].budget = 99;
assert.equal(resolvePolicy(branch, {mergeBaseDoc: doc}).stages.integration.finder[1].budget, 2);
assert.equal(resolvePolicy(branch, {mergeBaseDoc: doc, runId: 'fixture-run', finderOverrides: override}).stages.integration.finder[1].budget, 3);
for (const patch of [
  {budget: -1}, {budget: 1.5}, {gates: 'false'}, {carry: 'maybe'}, {trigger: ''},
  {trigger_incremental: false}, {rounds: 0}, {rounds: {full: [1], incremental: [1]}},
  {rounds: {first: 2}}, {completion: {kind: 'review', actor_id: '123'}},
  {completion: {kind: 'unknown', actor_id: 1}}, {typo: true},
]) {
  const invalid = structuredClone(doc);
  Object.assign(invalid.stage.integration.finder[0], patch);
  assert.throws(() => resolvePolicy(invalid));
}
// Each kind rejects both missing required fields and fields from other kinds.
for (const [kind, required, foreign] of [
  ['review', {actor_id: 1}, {body: 'foreign'}],
  ['comment', {actor_id: 1, body: 'done'}, {reaction: '+1'}],
  ['reaction', {actor_id: 1, reaction: '+1'}, {workflow: 'foreign'}],
  ['workflow', {actor_id: 1, workflow: 'review', conclusion: 'success'}, {body: 'foreign'}],
]) {
  for (const missing of Object.keys(required)) {
    const invalid = structuredClone(doc);
    invalid.stage.integration.finder[0].completion = {kind, ...required};
    delete invalid.stage.integration.finder[0].completion[missing];
    assert.throws(() => resolvePolicy(invalid), new RegExp(`completion.${kind} requires ${missing}`));
  }
  const invalid = structuredClone(doc);
  invalid.stage.integration.finder[0].completion = {kind, ...required, ...foreign};
  assert.throws(() => resolvePolicy(invalid), /unsupported/);
}
for (const [patch, error] of [
  [{budget: 0, gates: true}, /gates=true contradicts budget=0/],
  [{rounds: {incremental: [1]}}, /requires trigger_incremental/],
  [{carry: 'identity-or-incremental'}, /requires trigger_incremental/],
  [{budget: 1, rounds: 2}, /budget is below the declared rounds/],
  [{budget: 1, rounds: {full: [1], incremental: [2]}, trigger_incremental: 'incremental'}, /budget is below the declared rounds/],
  [{rounds: {unexpected: [1]}}, /rounds has invalid keys/],
  [{rounds: {}}, /rounds must name/],
  [{completion: {kind: 'review', actor_id: 1, unexpected: 'value'}}, /completion.review has invalid keys/],
]) {
  const invalid = structuredClone(doc);
  Object.assign(invalid.stage.integration.finder[0], patch);
  assert.throws(() => resolvePolicy(invalid), error);
}
assert.throws(() => resolvePolicy(doc, {runId: 'fixture-run', finderOverrides: {...override, finders: []}}), /finders must be a nonempty array/);
const disabled = structuredClone(doc);
Object.assign(disabled.stage.integration.finder[0], {gates: false, budget: 0});
assert.equal(resolvePolicy(disabled).stages.integration.finder[0].budget, 0);
assert.throws(() => resolvePolicy(doc, {runId: 'fixture-run', finderOverrides: {...override,
  finders: [{id: 'claude', budget: 1}]}}), /budget is below the declared rounds/);
const duplicate = structuredClone(doc);
duplicate.stage.integration.finder.push(duplicate.stage.integration.finder[0]);
assert.throws(() => resolvePolicy(duplicate), /duplicate/);
for (const invalid of [
  {...override, instruction: ''}, {...override, run_id: ''}, {...override, source: 'label'},
  {...override, finders: [{id: 'unknown', budget: 1}]},
  {...override, finders: [{id: 'claude', budget: -1}]},
]) assert.throws(() => resolvePolicy(doc, {runId: 'fixture-run', finderOverrides: invalid}));
// Exercise the actual CLI, including the trust boundary to an older closure.
const scratch = mkdtempSync(`${tmpdir()}/devflow-finders.`);
try {
  const registry = JSON.parse(readFileSync(`${fixture}/../devflow-conformance/agent-registry.json`, 'utf8'));
  for (const id of ['claude', 'greptile', 'coderabbit-cloud', 'gemini']) registry.finders.push({slug: id, surface: 'pr-cloud', stages: ['integration']});
  writeFileSync(`${scratch}/registry.json`, JSON.stringify(registry));
  const args = [process.argv[2], 'resolve', '--policy', `${fixture}/policy.toml`,
    '--registry', `${scratch}/registry.json`, '--task-targets', `${fixture}/../devflow-conformance/task-targets.json`,
    '--finder-overrides', `${fixture}/operator.json`, '--run-id', 'fixture-run', '--json'];
  const cli = spawnSync(process.execPath, args, {encoding: 'utf8'});
  assert.equal(cli.status, 0, cli.stderr || cli.stdout);
  assert.deepEqual(JSON.parse(cli.stdout).stages.integration.finder, pr.stages.integration.finder);
  const text = spawnSync(process.execPath, args.filter((arg) => arg !== '--json'), {encoding: 'utf8'});
  assert.equal(text.status, 0, text.stderr || text.stdout);
  const disclosures = text.stdout.split('disclosures (for the PR body):\n')[1];
  assert.ok(disclosures, 'text mode must include PR-body disclosures for finder overrides');
  for (const entry of override.finders) {
    const line = disclosures.split('\n').find((line) => line.includes(`finder ${entry.id} per-PR override:`));
    assert.ok(line, `text disclosure must name finder ${entry.id}`);
    assert.ok(line.includes(`"budget":${entry.budget}`), 'text disclosure must include the changed budget');
    assert.ok(line.includes(`"gates":${entry.gates}`), 'text disclosure must include the changed gating field');
    assert.ok(line.includes(`instruction_sha256=${pr.finder_overrides.instruction_sha256}`), 'text disclosure must include the instruction digest');
  }
  // An operator can configure a reviewer added to this run before overrides.
  registry.finders.push({slug: 'extra-reviewer', surface: 'pr-cloud', stages: ['integration']});
  writeFileSync(`${scratch}/registry.json`, JSON.stringify(registry));
  writeFileSync(`${scratch}/extra.json`, JSON.stringify({...override,
    finders: [{id: 'extra-reviewer', budget: 1, gates: false}]}));
  const addedArgs = args.map((arg) => arg === `${fixture}/operator.json` ? `${scratch}/extra.json` : arg);
  const added = spawnSync(process.execPath, [...addedArgs, '--add-finder', 'integration:extra-reviewer'], {encoding: 'utf8'});
  assert.equal(added.status, 0, added.stderr || added.stdout);
  const addedPolicy = JSON.parse(added.stdout);
  assert.equal(addedPolicy.stages.integration.finder.find((entry) => entry.id === 'extra-reviewer').budget, 1);
  validateResolvedPolicy(addedPolicy);
  writeFileSync(`${scratch}/devflow-policy.mjs`, 'console.log("old reader should never run")');
  const old = spawnSync(process.execPath, [...args, '--closure', scratch], {encoding: 'utf8'});
  assert.notEqual(old.status, 0);
  assert.match(old.stderr, /predates --finder-overrides/);
  const malformed = spawnSync(process.execPath, [...args.slice(0, -1), '--finder-overrides'], {encoding: 'utf8'});
  assert.equal(malformed.status, 2);
} finally { rmSync(scratch, {recursive: true, force: true}); }
console.log('devflow-finders: repository, PR operator overrides, compatibility and refusals passed');
JS
