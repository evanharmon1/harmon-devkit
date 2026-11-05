#!/usr/bin/env bash
# Publish one adjudicated round: assemble its marker, verification-bound
# projection and round table from the run record, then hand them to the one
# publisher, post-evidence.sh. Adds no marker writer and no second write path.
set -euo pipefail
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
node --input-type=module - "$asset_dir" "$@" <<'JS'
import { readFileSync, writeFileSync, existsSync, realpathSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
const [assets, ...args] = process.argv.slice(2);
process.argv[1] = assets;
const usage = 'usage: post-round.sh --repo OWNER/REPO --run RUN_ID --issue N --branch NAME --stage challenge|review|integration --round N --head SHA --role challenger|reviewer|integrator --finder SLUG [--repo-root DIR] [--actor-id ID] [--scratch-dir DIR]';
const fail = (message) => { throw new Error(message); };
let scratch;
let keepScratch = false;
try {
  const o = {};
  const names = ['repo', 'run', 'issue', 'branch', 'stage', 'round', 'head', 'role', 'finder', 'repo-root', 'actor-id', 'scratch-dir'];
  for (let i = 0; i < args.length; i += 2) {
    const name = (args[i] ?? '').replace(/^--/, '');
    if (!args[i]?.startsWith('--') || !names.includes(name) || !args[i + 1] || o[name] !== undefined) fail(usage);
    o[name] = args[i + 1];
  }
  if (['repo', 'run', 'issue', 'branch', 'stage', 'round', 'head', 'role', 'finder'].some((n) => !o[n])) fail(usage);
  const roleFor = { challenge: 'challenger', review: 'reviewer', integration: 'integrator' };
  if (!/^[^/\s]+\/[^/\s]+$/.test(o.repo)) fail(`invalid --repo ${o.repo}; expected OWNER/REPO`);
  if (!/^run-[1-9][0-9]*-[A-Za-z0-9._-]+$/.test(o.run)) fail(`invalid --run ${o.run}; expected the canonical run-<issue>-<name> identity`);
  if (!/^[1-9][0-9]*$/.test(o.issue)) fail(`invalid --issue ${o.issue}`);
  if (o.run.split('-')[1] !== o.issue) fail(`--issue ${o.issue} does not match run identity ${o.run}`);
  if (!roleFor[o.stage]) fail(`invalid --stage ${o.stage}; rounds exist for challenge, review and integration`);
  if (!/^[1-9][0-9]*$/.test(o.round)) fail(`invalid --round ${o.round}; expected a positive integer`);
  if (!/^[0-9a-f]{40}$/.test(o.head)) fail(`invalid --head ${o.head}; expected a full lowercase 40-hex sha`);
  if (o.role !== roleFor[o.stage]) fail(`--role ${o.role} does not fill stage ${o.stage}; expected ${roleFor[o.stage]}`);
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(o.finder)) fail(`invalid --finder ${o.finder}`);
  if (o['actor-id'] !== undefined && !/^[1-9][0-9]*$/.test(o['actor-id'])) fail(`invalid --actor-id ${o['actor-id']}`);
  const round = Number(o.round);

  // Sibling packages resolve from this asset's PHYSICAL directory, so the
  // same path works in harmon-devkit's source tree and in a consumer's
  // flattened .claude/skills tree (dev-flow-support/SKILL.md, "Calling it
  // from another skill"). A missing sibling is named, never inferred.
  const sibling = (relative) => {
    const file = join(assets, relative);
    if (!existsSync(file)) fail(`sibling asset missing: ${file} (vendor dev-flow-support and orchestrate beside review)`);
    return realpathSync(file);
  };
  const render = sibling('../../dev-flow-support/assets/render-dev-flow.sh');
  const monitor = sibling('../../orchestrate/assets/dev-flow-monitor.sh');
  const postEvidence = sibling('post-evidence.sh');

  // Every subprocess surfaces its own stderr and its exit status; nothing
  // here discards either, so a renderer or publisher failure is visible.
  const execute = (label, command, argv, options = {}) => {
    const r = spawnSync(command, argv, { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, stdio: ['ignore', 'pipe', 'inherit'], ...options });
    if (r.error) fail(`${label} could not start: ${r.error.message}`);
    if (r.status !== 0) fail(`${label} failed (exit ${r.status ?? `signal ${r.signal}`})`);
    return r.stdout;
  };
  const read = (file, label) => {
    if (!existsSync(file)) fail(`${label} missing: ${file}`);
    try { return JSON.parse(readFileSync(file, 'utf8')); } catch (error) { fail(`${label} is not valid JSON (${file}): ${error.message}`); }
  };

  const root = realpathSync(o['repo-root'] ?? execute('git rev-parse --show-toplevel', 'git', ['rev-parse', '--show-toplevel']).trim());
  const state = execute('dev-flow-monitor.sh state-path', 'bash', [monitor, 'state-path', '--run-id', o.run, '--repo-root', root]).trim();
  const record = join(state, '..');
  const runPath = join(record, 'run.json');
  const run = read(runPath, 'run record');
  if (run.run_id !== o.run) fail(`run record ${runPath} names run ${run.run_id}, not ${o.run}`);
  if (!(run.stage_transitions ?? []).some((t) => t.stage === o.stage)) fail(`run ${o.run} never entered stage ${o.stage}; nothing to publish`);
  const roundName = `${o.stage}-r${round}`;
  const adjudicationPath = join(record, 'adjudications', `${roundName}.json`);
  if (!existsSync(adjudicationPath)) fail(`round ${roundName} has no retained adjudication (${adjudicationPath}); record it with run-record.mjs adjudicate before publishing`);
  const adjudication = read(adjudicationPath, 'adjudication');
  if (adjudication.run_id !== o.run || adjudication.stage !== o.stage || adjudication.round !== round) fail(`adjudication ${adjudicationPath} is for ${adjudication.run_id}/${adjudication.stage}-r${adjudication.round}, not ${o.run}/${roundName}`);
  if (adjudication.reviewed_head !== o.head) fail(`adjudication ${roundName} reviewed head ${adjudication.reviewed_head}; --head ${o.head} is not this round's head`);
  const receipted = (run.receipts ?? []).filter((r) => r.kind === 'pass' && typeof r.file === 'string' && r.file.startsWith(`${roundName}-`)).map((r) => r.file).sort();
  if (!receipted.length) fail(`round ${roundName} has no receipted pass in ${runPath}`);
  if (!receipted.includes(`${roundName}-${o.finder}`)) fail(`round ${roundName} has no receipted pass for finder ${o.finder}; receipted: ${receipted.join(', ')}`);
  const passes = receipted.map((file) => read(join(record, 'passes', `${file}.json`), `receipted pass ${file}`));
  // A confidence round publishes the exit the stage computed for it
  // (<record>/verdict.json, persisted by /review or /implement § 6a). An
  // integration round has no such file: the readiness gate is its exit, and
  // a verdict.json left behind by the last confidence stage is not published
  // under an integration marker.
  const verdictPath = join(record, 'verdict.json');
  let verdict = null;
  if (o.stage !== 'integration') {
    if (!existsSync(verdictPath)) fail(`${verdictPath} missing; compute the round's exit (dev-flow-exit.sh) and persist it before publishing`);
    verdict = read(verdictPath, 'exit verdict');
    if (verdict.stage !== undefined && verdict.stage !== o.stage) fail(`${verdictPath} is the exit for stage ${verdict.stage}, not ${o.stage}; recompute this round's exit before publishing`);
  }

  const pointerPath = execute('dev-flow-monitor.sh active-path', 'bash', [monitor, 'active-path', '--branch', o.branch, '--repo-root', root]).trim();
  const pointer = read(pointerPath, 'active pointer');
  if (pointer.run_id !== o.run) fail(`active pointer ${pointerPath} names run ${pointer.run_id}, not ${o.run}`);
  if (!Number.isSafeInteger(pointer.generation) || pointer.generation < 1) fail(`active pointer ${pointerPath} has no generation`);
  const actorId = o['actor-id'] ?? execute('gh api user', 'gh', ['api', 'user', '--jq', '.id']).trim();
  if (!/^[1-9][0-9]*$/.test(actorId)) fail(`could not resolve the authenticated actor id (got ${JSON.stringify(actorId)}); pass --actor-id "$(gh api user --jq .id)"`);

  if (o['scratch-dir']) { scratch = realpathSync(o['scratch-dir']); keepScratch = true; }
  else scratch = mkdtempSync(join(tmpdir(), 'post-round-'));
  const markerFile = join(scratch, `${o.run}-${roundName}.marker.json`);
  writeFileSync(markerFile, JSON.stringify({ run_id: o.run, stage: o.stage, round, sequence: 1, destination: 'issue' }));
  const common = ['--repo', o.repo, '--repo-root', root, '--run', runPath, '--branch', o.branch, '--generation', String(pointer.generation),
    '--active-state', pointerPath, '--head', o.head, '--actor-id', actorId, '--role', o.role, '--finder', o.finder, '--issue', o.issue,
    '--marker-file', markerFile, '--scratch-dir', scratch];

  // post-evidence.sh persists the exact reserved bytes beside the monitor
  // state and adopts an already-landed comment instead of posting again. A
  // re-post therefore republishes those bytes rather than a re-rendered body,
  // which a later round's verdict.json would otherwise have changed.
  const event = `evidence-issue-${roundName}-s1`;
  let reserved = false;
  if (existsSync(state)) {
    try { reserved = (JSON.parse(readFileSync(state, 'utf8')).actions ?? []).some((a) => a.event === event); } catch { reserved = false; }
  }
  if (reserved && existsSync(join(state, '..', `${event}.body.md`))) {
    process.stderr.write(`post-round: ${roundName} is already reserved; re-arming with the persisted body\n`);
  } else {
    const table = execute('render-dev-flow.sh round-table', 'bash', [render, 'round-table', '--record', record, '--stage', o.stage, '--round', String(round)]);
    const projection = { run_id: o.run, stage: o.stage, round, reviewed_head: o.head, passes, adjudication, exit: verdict };
    const body = `**Dev flow v2 — ${o.stage} round ${round}** · run \`${o.run}\` · head \`${o.head}\`\n\n\`\`\`json\n${JSON.stringify(projection, null, 2)}\n\`\`\`\n\n${table.replace(/\s+$/, '')}\n`;
    const bodyFile = join(scratch, `${o.run}-${roundName}.md`);
    writeFileSync(bodyFile, body);
    common.push('--body-file', bodyFile);
  }
  const id = execute('post-evidence.sh', 'bash', [postEvidence, ...common], { cwd: root }).trim();
  if (!/^[1-9][0-9]*$/.test(id)) fail(`post-evidence.sh returned no comment id (got ${JSON.stringify(id)})`);
  process.stdout.write(`${id}\n`);
} catch (error) {
  process.stderr.write(`post-round: ${error.message}\n`);
  process.exitCode = 2;
} finally {
  if (scratch && !keepScratch) rmSync(scratch, { recursive: true, force: true });
}
JS
