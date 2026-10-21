#!/usr/bin/env bash
# Record a role-produced local finder envelope; never parse CLI prose.
set -euo pipefail
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
node --input-type=module - "$asset_dir" "$@" <<'JS'
import { readFileSync, readdirSync, existsSync, realpathSync, writeFileSync, renameSync, rmSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { pathToFileURL } from 'node:url';
import { join, resolve, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
const [assets, ...args] = process.argv.slice(2);
const usage = 'usage: record-pass.sh --repo-root DIR --slate ID --session ID --run-id ID --pass FILE --head SHA --policy FILE [--adjudication FILE] [--owner-token TOKEN] [--rigor LEVEL] [--exit-engine FILE] [--merge-base-policy FILE|--merge-base-policy-absent] [--add-finder STAGE:SLUG] [--select-finder STAGE:SLUG]';
const fail = (message) => { throw new Error(message); };
let scratch;
try {
  const o = {}, extra = [];
  const names = ['repo-root', 'slate', 'session', 'run-id', 'pass', 'head', 'policy', 'adjudication', 'owner-token', 'rigor', 'exit-engine', 'merge-base-policy'];
  for (let i = 0; i < args.length; i++) {
    const name = args[i].replace(/^--/, '');
    if (args[i] === '--merge-base-policy-absent' && !o[name]) { o[name] = true; continue; }
    if (['add-finder', 'select-finder'].includes(name) && args[i + 1]) { extra.push(args[i], args[++i]); continue; }
    if (!args[i].startsWith('--') || !names.includes(name) || !args[i + 1] || o[name] !== undefined) fail(usage);
    o[name] = args[++i];
  }
  if (['repo-root', 'slate', 'session', 'run-id', 'pass', 'head', 'policy'].some((n) => !o[n])) fail(usage);
  if (!/^[0-9a-f]{40}$/.test(o.head) || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(o['run-id'])) fail('invalid head or run id');
  if (o['merge-base-policy'] && o['merge-base-policy-absent']) fail('conflicting merge-base policy arguments');
  const token = o['owner-token'] ?? process.env.RUN_RECORD_OWNER_TOKEN;
  if (!token) fail('owner token required; acquire the slate lock first');
  const root = realpathSync(o['repo-root']);
  const support = realpathSync(join(assets, '../../dev-flow-support/assets'));
  const execute = (command, argv, accepted = [0], env = process.env) => {
    const r = spawnSync(command, argv, { cwd: root, env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 });
    if (r.error || !accepted.includes(r.status)) {
      // Never include argv in diagnostics: writer calls carry owner authority.
      if (r.stderr) process.stderr.write(r.stderr);
      fail(`${command === process.execPath ? 'validator/writer/exit command' : command} failed (exit ${r.status ?? 'unknown'})`);
    }
    return r;
  };
  const git = (...a) => execute('git', a).stdout.trim();
  const read = (p) => JSON.parse(readFileSync(p, 'utf8'));
  const common = git('rev-parse', '--path-format=absolute', '--git-common-dir');
  const directory = join(common, 'dev-flow-v2/runs', o['run-id']);
  const runPath = join(directory, 'run.json');
  const record = read(runPath);
  scratch = mkdtempSync(join(tmpdir(), 'record-pass-'));
  const envelopePath = join(scratch, 'pass.json');
  writeFileSync(envelopePath, readFileSync(realpathSync(resolve(root, o.pass))));
  const envelope = read(envelopePath);
  const { stage, round, reviewed_head: head } = envelope.payload ?? {};
  if (!['challenge', 'review'].includes(stage) || envelope.role !== (stage === 'challenge' ? 'challenger' : 'reviewer') || envelope.status !== 'completed') fail('only completed local challenger/reviewer passes are supported');
  if (envelope.run?.run_id !== o['run-id'] || record.run_id !== o['run-id'] || envelope.head !== o.head || head !== o.head) fail('pass scope does not match requested run/head');
  const branch = read(join(directory, 'branch.json')).branch;
  if (git('rev-parse', '--verify', `refs/heads/${branch}^{commit}`) !== o.head) fail('requested head is not the run branch head');
  if (record.stage_transitions.at(-1)?.stage !== stage) fail('pass stage is not active');
  const validator = join(support, 'validate-result-schemas.mjs');
  const validate = (...a) => execute(process.execPath, [validator, ...a]);
  const context = ['--run-id', record.run_id, '--initiated-by', record.initiated_by, '--receipt'];
  const adjudicationsDir = join(directory, 'adjudications');
  const existingAdjudications = existsSync(adjudicationsDir) ? readdirSync(adjudicationsDir).filter((n) => n.endsWith('.json')).map((n) => join(adjudicationsDir, n)) : [];
  validate('run', runPath, '--receipts', runPath, ...(existingAdjudications.length ? existingAdjudications.flatMap((p) => ['--adjudication', p]) : ['--no-adjudications']));
  const slot = envelope.payload.slot ?? envelope.payload.finder;
  const name = `${stage}-r${round}-${slot}`;
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(name)) fail('unsafe pass name');
  const canonical = join(directory, 'passes', `${name}.json`);
  if (existsSync(canonical) && !readFileSync(canonical).equals(readFileSync(envelopePath))) fail('immutable pass already exists with different bytes');
  const knownIds = (record.receipts ?? []).filter((r) => r.kind === 'pass' && r.file !== name)
    .flatMap((r) => read(join(directory, 'passes', `${r.file}.json`)).payload.findings.map((f) => f.id));
  const knownFile = join(scratch, 'known-ids.json');
  writeFileSync(knownFile, JSON.stringify(knownIds));
  validate('envelope', envelopePath, ...context, '--known-ids', knownFile);
  const knownAdjudicated = existingAdjudications.filter((p) => p !== join(adjudicationsDir, `${stage}-r${round}.json`))
    .flatMap((p) => read(p).adjudications.map((a) => a.finding_id));
  const adjudicatedFile = join(scratch, 'known-adjudicated.json');
  writeFileSync(adjudicatedFile, JSON.stringify(knownAdjudicated));
  const roundPasses = (record.receipts ?? []).filter((r) => r.kind === 'pass' && r.file.startsWith(`${stage}-r${round}-`) && r.file !== name).map((r) => join(directory, 'passes', `${r.file}.json`));
  let adjudicationPath;
  if (o.adjudication) {
    adjudicationPath = join(scratch, 'adjudication.json');
    writeFileSync(adjudicationPath, readFileSync(realpathSync(resolve(root, o.adjudication))));
    const a = read(adjudicationPath);
    if (a.run_id !== record.run_id || a.stage !== stage || a.round !== round || a.reviewed_head !== head) fail('adjudication scope does not match pass');
    validate('adjudication', adjudicationPath, ...[...roundPasses, envelopePath].flatMap((p) => ['--pass', p]), ...context, '--known-adjudicated', adjudicatedFile);
    const target = join(adjudicationsDir, `${stage}-r${round}.json`);
    if (existsSync(target) && !readFileSync(target).equals(readFileSync(adjudicationPath))) fail('immutable adjudication already exists with different bytes');
  }
  // Preflight policy/engine inputs with that engine's own sibling reader,
  // before any receipt. A supplied governing closure governs this read too.
  const engine = o['exit-engine'] ? realpathSync(resolve(root, o['exit-engine'])) : join(support, 'dev-flow-exit.mjs');
  const reader = await import(pathToFileURL(join(dirname(engine), 'devflow-policy.mjs')).href);
  const rigor = o.rigor ?? read(join(directory, 'policy.json')).rigor.level;
  const policyDoc = reader.readBranchPolicy(resolve(root, o.policy));
  const mergeBaseDoc = o['merge-base-policy'] ? reader.readBranchPolicy(realpathSync(resolve(root, o['merge-base-policy']))) : undefined;
  const resolution = reader.resolvePolicy(policyDoc, { rigor, mergeBaseDoc, mergeBasePolicyAbsent: Boolean(o['merge-base-policy-absent']) });
  const errors = reader.crossValidate(resolution, null, null).filter((e) => !e.startsWith('indeterminate:'));
  if (errors.length) fail(`policy fails cross-validation: ${errors[0]}`);
  const requests = (flag) => extra.filter((_, i) => i % 2 === 1 && extra[i - 1] === flag);
  const selection = reader.applyFinderSelection(resolution, requests('--add-finder'), requests('--select-finder'));
  if (selection.error) fail(`invalid finder selection: ${selection.error}`);
  // All input refusals above precede the first writer invocation. Receipt and
  // adjudication publication, including replay, belong to the shared writer.
  const writer = (command, ...a) => execute(process.execPath, [join(support, 'run-record.mjs'), command, '--slate', o.slate, '--session', o.session, '--run-id', record.run_id, ...a], [0], { ...process.env, RUN_RECORD_OWNER_TOKEN: token });
  writer('receipt', '--pass', envelopePath);
  writer('ledger', '--stage', stage);
  const exitArgs = ['--run', directory, '--stage', stage, '--policy', resolve(root, o.policy), '--rigor', rigor, '--current-head', head, '--repo-root', root, '--history', join(directory, `history.${stage}.json`), '--heads', join(directory, 'heads.json'), '--json', ...extra];
  if (o['merge-base-policy']) exitArgs.push('--merge-base-policy', resolve(root, o['merge-base-policy']));
  if (o['merge-base-policy-absent']) exitArgs.push('--merge-base-policy-absent');
  const compute = (verification) => {
    const r = execute(process.execPath, [engine, ...exitArgs, ...(verification ? ['--verification-only'] : [])], [0, 20, 21, 22]);
    const projection = JSON.parse(r.stdout);
    if (projection.stage !== stage || typeof projection.reason !== 'string' || !['adjudicate', 'dispatch', 'escalate', 'advance', 'fix-delete-restructure-or-split'].includes(projection.action)) fail('invalid exit projection');
    const rejected = (projection.diagnostics ?? []).filter((d) => d.level === 'reject');
    if (rejected.length) fail(`exit verification rejected retained evidence: ${rejected.map((d) => d.reason).join('; ')}`);
    return { r, projection };
  };
  const persist = (name, bytes) => {
    const path = join(directory, name), temporary = `${path}.tmp.${process.pid}`;
    try { writeFileSync(temporary, bytes, { flag: 'wx' }); renameSync(temporary, path); }
    finally { rmSync(temporary, { force: true }); }
  };
  const verified = compute(true);
  persist(`verification.${stage}.json`, verified.r.stdout);
  // A replay of an already adjudicated round needs no new authorization to
  // write adjudication: skip that write and finish its computed-exit read.
  const replay = existsSync(join(adjudicationsDir, `${stage}-r${round}.json`))
    && verified.projection.rounds?.some((r) => r.round === round && r.has_adjudication && r.reviewed_head === head);
  if (verified.projection.action !== 'adjudicate' && !replay) {
    process.stdout.write(verified.r.stdout);
    process.exitCode = verified.r.status;
  } else {
    if (!replay) {
      if (!adjudicationPath) fail('verification authorizes adjudication; supply the orchestrator adjudication file to resume');
      writer('adjudicate', '--file', adjudicationPath);
    }
    const verdict = compute(false);
    persist('verdict.json', verdict.r.stdout);
    process.stdout.write(verdict.r.stdout);
    process.exitCode = verdict.r.status;
  }
} catch (error) {
  process.stderr.write(`record-pass: ${error.message}\n`);
  process.exitCode = 2;
} finally {
  if (scratch) rmSync(scratch, { recursive: true, force: true });
}
JS
