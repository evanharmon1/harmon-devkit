#!/usr/bin/env bash
# Real writers/validators/exit engine in offline fixture repos; no model calls.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
node --input-type=module - "$asset_dir" "$test_tmp" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, cpSync, existsSync, readdirSync, renameSync, chmodSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
const [assets, tmp] = process.argv.slice(2);
const source = join(assets, '../../../../..');
const copied = join(tmp, 'skills');
cpSync(join(assets, '../../dev-flow-support'), join(copied, 'dev-flow-support'), { recursive: true });
cpSync(join(assets, '../../orchestrate'), join(copied, 'orchestrate'), { recursive: true });
mkdirSync(join(copied, 'review/assets'), { recursive: true });
cpSync(join(assets, 'record-pass.sh'), join(copied, 'review/assets/record-pass.sh'));
const support = join(copied, 'dev-flow-support/assets');
const recorder = join(copied, 'review/assets/record-pass.sh');
const writer = join(support, 'run-record.mjs');
const env = { ...process.env, GIT_CONFIG_GLOBAL: join(tmp, 'gitconfig'), GIT_CONFIG_NOSYSTEM: '1' };
for (const k of Object.keys(env)) if (/^GIT_(CONFIG|DIR|WORK_TREE|INDEX_FILE|COMMON_DIR|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|PREFIX)/.test(k) && !['GIT_CONFIG_GLOBAL','GIT_CONFIG_NOSYSTEM'].includes(k)) delete env[k];
const repo = join(tmp, 'repo');
mkdirSync(repo);
const sh = (cmd, argv, cwd = repo) => execFileSync(cmd, argv, { cwd, env, encoding: 'utf8', stdio: ['ignore','pipe','pipe'] }).trim();
const run = (cmd, argv, extra = {}) => spawnSync(cmd, argv, { cwd: repo, env: { ...env, ...extra }, encoding: 'utf8' });
const put = (p, v) => writeFileSync(p, JSON.stringify(v, null, 2) + '\n');
const read = (p) => JSON.parse(readFileSync(p, 'utf8'));
const hash = (dir) => {
  const entries = [];
  const walk = (path, prefix = '') => {
    for (const e of readdirSync(path, { withFileTypes: true }).sort((a,b) => a.name.localeCompare(b.name))) {
      const name = `${prefix}${e.name}`;
      if (e.isDirectory()) walk(join(path, e.name), `${name}/`);
      else entries.push([name, readFileSync(join(path, e.name)).toString('base64')]);
    }
  };
  walk(dir);
  return createHash('sha256').update(JSON.stringify(entries)).digest('hex');
};
sh('git', ['init','-q','-b','main']);
sh('git', ['config','user.name','Test']);
sh('git', ['config','user.email','test@example.invalid']);
sh('git', ['config','commit.gpgsign','false']);
const registry = read(join(source, 'agent-registry.json'));
registry.trusted_orchestrator_actor_ids = [12345];
put(join(repo,'agent-registry.json'), registry);
cpSync(join(source,'.devflow.toml'), join(repo,'.devflow.toml'));
sh('git',['add','.']); sh('git',['commit','-qm','initial']);
const base = sh('git',['rev-parse','HEAD']);
sh('git',['remote','add','origin','https://github.com/example/repo']);
sh('git',['update-ref','refs/remotes/origin/main',base]);
sh('git',['symbolic-ref','refs/remotes/origin/HEAD','refs/remotes/origin/main']);
sh('git',['switch','-qc','1-pass']);
writeFileSync(join(repo,'change.txt'),'change\n');
sh('git',['add','.']); sh('git',['commit','-qm','feat: fixture']);
const head = sh('git',['rev-parse','HEAD']);
const resolved = run(process.execPath,[join(support,'devflow-policy.mjs'),'resolve','--policy','.devflow.toml','--registry','agent-registry.json','--json']);
assert.ok([0,3].includes(resolved.status) && resolved.stdout.trim(), resolved.stderr);
const policyFile = join(tmp,'policy.json');
writeFileSync(policyFile,resolved.stdout);
const policy = read(policyFile);
const runId = 'run-1-pass', slate = `solo-${runId}`;
const token = sh(process.execPath,[writer,'lock','acquire','--slate',slate,'--session','fixture','--issues','1']);
const identity = JSON.parse(sh(process.execPath,[writer,'solo-init','--owner-token',token,'--session','fixture','--run-id',runId,'--issue','1','--title','fixture','--url','https://github.com/example/repo/issues/1','--branch','1-pass','--base',base,'--policy',policyFile,'--actor-id','12345','--strategy-source','default_strategy']));
const dir = identity.record_directory;
const write = (command,...a) => sh(process.execPath,[writer,command,'--owner-token',token,'--slate',slate,'--session','fixture','--run-id',runId,...a]);
write('transition','--stage','claim');
for (const stage of ['implement','verify','challenge']) write('transition','--stage',stage,'--exit','fixture done');
const envelope = (stage, findings = []) => ({schema:2,role:stage === 'challenge' ? 'challenger':'reviewer',status:'completed',head,
  produced_at:new Date().toISOString().replace(/\.\d{3}Z$/,'Z'),producer:{harness:'codex-cli',model:'fixture-model',tier:'apex'},run:{run_id:runId,initiated_by:'human'},
  payload:{stage,round:1,reviewed_head:head,finder:policy.stages[stage].finders[0],slot:policy.stages[stage].finders[0],findings,
    counts:{P0:0,P1:0,P2:findings.length,P3:0},...(stage === 'challenge' ? {attack_scenarios:[{id:'attack-1',description:'tried to break fixture',outcome:'held',finding_id:null}]}:{})}});
const adjudication = (stage, findings = []) => ({schema:2,run_id:runId,stage,round:1,reviewed_head:head,adjudications:findings.map(f => ({finding_id:f.id,reviewer_priority:f.priority,adjudicated_priority:f.priority,disposition:'defer',reason:'follow-up hardening',evidence:'fixture proof',override:null}))});
const passFile = join(tmp,'pass.json'), adjFile = join(tmp,'adj.json');
put(passFile,envelope('challenge')); put(adjFile,adjudication('challenge'));
const argv = ['--repo-root',repo,'--slate',slate,'--session','fixture','--run-id',runId,'--pass',passFile,'--head',head,'--policy',join(repo,'.devflow.toml'),'--adjudication',adjFile];
const invoke = (a = argv, extra = {}) => run('bash',[recorder,...a],{RUN_RECORD_OWNER_TOKEN:token,...extra});
const refused = (label, fn) => {
  const before = hash(dir), r = fn();
  assert.notEqual(r.status,0,label);
  assert.equal(hash(dir),before,`${label}: run directory changed`);
};
refused('missing token',()=>invoke(argv,{RUN_RECORD_OWNER_TOKEN:''}));
put(passFile,{...envelope('challenge'),schema:99});
refused('invalid envelope',()=>invoke());
put(passFile,envelope('challenge'));
put(adjFile,{...adjudication('challenge'),reviewed_head:base});
refused('wrong adjudication head',()=>invoke());
put(adjFile,adjudication('challenge'));
refused('wrong captured head',()=>invoke(argv.map(a=>a===head?base:a)));
put(passFile,{...envelope('challenge'),role:'integrator'});
refused('integrator out of scope',()=>invoke());
put(passFile,envelope('challenge'));
refused('invalid finder flag',()=>invoke([...argv,'--add-finder','bad-shape']));
refused('invalid rigor',()=>invoke([...argv,'--rigor','nonexistent-profile']));
refused('missing exit engine',()=>invoke([...argv,'--exit-engine',join(tmp,'missing.mjs')]));
const badPolicy = join(tmp,'bad.toml');
writeFileSync(badPolicy,'this is not TOML');
refused('invalid policy',()=>invoke(argv.map(a=>a===join(repo,'.devflow.toml')?badPolicy:a)));
console.log('PASS: input refusals leave the entire run directory byte-identical');
// Swap the validator in the vendored fixture. The production command has no
// validator-disable switch. Fail only after ledger creation, proving that a
// later validation failure stops adjudication, including in an outer pipeline.
const validator = join(support,'validate-result-schemas.mjs');
renameSync(validator,join(support,'real-validator.mjs'));
const failure = join(tmp,'validator-failure');
writeFileSync(validator,`import {existsSync} from 'node:fs';
if(existsSync(${JSON.stringify(failure)}) && existsSync(${JSON.stringify(join(dir,'heads.json'))})) { console.error('fixture validator failed'); process.exit(45); }
await import('./real-validator.mjs');\n`);
writeFileSync(failure,'fail');
let r = run('bash',['-c','set -o pipefail; bash "$@" | tail -n 1','pipeline',recorder,...argv],{RUN_RECORD_OWNER_TOKEN:token});
assert.notEqual(r.status,0,r.stdout+r.stderr);
assert.match(r.stderr,/fixture validator failed/);
assert.ok(existsSync(join(dir,'passes',`challenge-r1-${policy.stages.challenge.finders[0]}.json`)));
assert.ok(existsSync(join(dir,'heads.json')));
assert.equal(existsSync(join(dir,'adjudications/challenge-r1.json')),false);
assert.equal(read(join(dir,'verdict.json')).outcome,'indeterminate');
assert.equal(read(join(dir,'verdict.json')).stage,'challenge');
assert.equal(read(join(dir,'verdict.json')).round,1);
console.log('PASS: validator failure inside a pipeline stops every later recording step');
// Removing only the injected failure permits a resume from the real receipt.
const { unlinkSync } = await import('node:fs');
unlinkSync(failure);
const firstPhase = invoke(argv.filter((a, i) => a !== '--adjudication' && argv[i - 1] !== '--adjudication'));
assert.equal(firstPhase.status,23,firstPhase.stdout+firstPhase.stderr);
assert.deepEqual(JSON.parse(firstPhase.stdout),{action:'adjudicate',projection_path:join(dir,'verdict.json')});
assert.equal(read(join(dir,'verdict.json')).action,'adjudicate');
assert.equal(existsSync(join(dir,'adjudications/challenge-r1.json')),false);
r = invoke();
assert.equal(r.status,20,r.stdout+r.stderr);
assert.equal(JSON.parse(r.stdout).reason,'empty_round');
assert.equal(read(join(dir,'verification.challenge.json')).action,'adjudicate');
assert.equal(read(join(dir,'run.json')).receipts.filter(r=>r.kind==='pass').length,1);
const passBytes = readFileSync(join(dir,'passes',`challenge-r1-${policy.stages.challenge.finders[0]}.json`));
const adjudBytes = readFileSync(join(dir,'adjudications/challenge-r1.json'));
r = invoke();
assert.equal(r.status,20,r.stdout+r.stderr);
assert.deepEqual(readFileSync(join(dir,'passes',`challenge-r1-${policy.stages.challenge.finders[0]}.json`)),passBytes);
assert.deepEqual(readFileSync(join(dir,'adjudications/challenge-r1.json')),adjudBytes);
console.log('PASS: resume and replay keep immutable receipts and adjudication and compute the empty-round exit');
write('transition','--stage','review','--exit','empty_round');
const finder = policy.stages.review.finders[0];
const finding = {id:`review-r1-${finder}-1`,path:'change.txt',line:1,class:'hardening',provenance:'original',fingerprint:'new',priority:'P2',recommended_disposition:'defer',evidence:'fixture finding'};
put(passFile,envelope('review',[finding])); put(adjFile,adjudication('review',[finding]));
// Verification dispatch/escalate must never consume the supplied adjudication.
const engine = join(support,'exit-fixture.mjs');
const engineCount = join(tmp,'exit-count');
writeFileSync(engine, "console.log(JSON.stringify({stage:'review',round:1,outcome:'indeterminate',action:'escalate',reason:'fixture indeterminate'}));process.exitCode=2;\n");
r = invoke([...argv,'--exit-engine',engine]);
assert.equal(r.status,2,r.stderr);
assert.equal(read(join(dir,'verdict.json')).outcome,'indeterminate');
assert.equal(read(join(dir,'verdict.json')).stage,'review');
assert.equal(read(join(dir,'verdict.json')).round,1);
assert.equal(existsSync(join(dir,'adjudications/review-r1.json')),false);
console.log('PASS: indeterminate verification replaces the previous stage verdict before exiting');
for (const [action,status] of [['dispatch',0],['escalate',22]]) {
  writeFileSync(engine, `import {appendFileSync} from 'node:fs';
if(!process.argv.includes('--verification-only')) process.exit(99);
appendFileSync(${JSON.stringify(engineCount)},'verification\\n');
console.log(JSON.stringify({stage:'review',round:1,action:${JSON.stringify(action)},reason:'fixture blocker'}));
process.exitCode=${status};\n`);
  r = invoke([...argv,'--exit-engine',engine]);
  assert.equal(r.status,status,r.stderr);
  assert.equal(JSON.parse(r.stdout).action,action);
  assert.deepEqual(read(join(dir,'verdict.json')),JSON.parse(r.stdout));
  assert.equal(read(join(dir,'verdict.json')).round,1);
  assert.equal(existsSync(join(dir,'adjudications/review-r1.json')),false);
}
assert.equal(readFileSync(engineCount,'utf8').trim().split('\n').length,2);
console.log('PASS: dispatch and escalation projections stop before adjudication or final computation');
// A final exit failure after adjudication is resumable as well as the earlier
// pre-adjudication failure: do not rewrite the accepted adjudication on retry.
writeFileSync(engine, `import {spawnSync} from 'node:child_process';
if(!process.argv.includes('--verification-only')) {console.error('fixture final-exit failure');process.exit(46);}
const r=spawnSync(process.execPath,[${JSON.stringify(join(support,'dev-flow-exit.mjs'))},...process.argv.slice(2)],{stdio:'inherit'});process.exitCode=r.status;\n`);
r = invoke([...argv,'--exit-engine',engine]);
assert.equal(r.status,2,r.stderr);
assert.match(r.stderr,/fixture final-exit failure/);
assert.equal(read(join(dir,'verdict.json')).stage,'review');
assert.equal(read(join(dir,'verdict.json')).action,'adjudicate');
assert.ok(existsSync(join(dir,'adjudications/review-r1.json')));
assert.equal(read(join(dir,'verification.review.json')).action,'adjudicate');
r = invoke();
assert.ok([0,20].includes(r.status),r.stdout+r.stderr);
assert.equal(read(join(dir,'adjudications/review-r1.json')).adjudications[0].finding_id,finding.id);
assert.equal(read(join(dir,'verification.review.json')).rounds[0].has_adjudication,true);
assert.deepEqual(read(join(dir,'verdict.json')),JSON.parse(r.stdout));
assert.ok(!JSON.stringify(readdirSync(dir)).includes(token));
for (const p of ['run.json','verdict.json','verification.review.json']) assert.ok(!readFileSync(join(dir,p),'utf8').includes(token));
console.log('PASS: a round with findings retains role evidence and orchestrator adjudication and computes its exit without storing the owner token');

// The checkout command uses a real local origin and real hooks. Main and
// candidate carry different finders/libraries in refusal cases.
const remote = join(tmp,'remote');
mkdirSync(remote);
const rg = (...a) => sh('git',a,remote);
rg('init','-q','-b','main'); rg('config','user.name','Test'); rg('config','user.email','test@example.invalid'); rg('config','commit.gpgsign','false');
mkdirSync(join(remote,'scripts/lib'),{recursive:true});
writeFileSync(join(remote,'.gitignore'),'.worktrees/\n');
writeFileSync(join(remote,'scripts/lib/helper.sh'),'# trusted library\n');
writeFileSync(join(remote,'scripts/codex-review.sh'),`#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(git rev-parse HEAD)" = "$EXPECTED_REVIEW_HEAD" ]
[ -z "$(git status --porcelain)" ]
[ "$(git symbolic-ref -q HEAD || true)" = "" ]
printf 'DEFAULT-FINDER:%s:%s\\n' "$(git rev-parse HEAD)" "$1"
exit "\${FINDER_FIXTURE_STATUS:-0}"
`);
rg('add','.'); rg('commit','-qm','trusted finder');
const defaultHead = rg('rev-parse','HEAD');
const consumer = join(tmp,'consumer');
sh('git',['clone','-q',remote,consumer]);
const cg = (...a) => sh('git',a,consumer);
cg('config','user.name','Test'); cg('config','user.email','test@example.invalid'); cg('config','commit.gpgsign','false'); cg('switch','-qc','feature');
writeFileSync(join(consumer,'feature.txt'),'head change\n'); cg('add','.'); cg('commit','-qm','feature');
const reviewHead = cg('rev-parse','HEAD');
const checkoutTool = join(assets,'prepare-review-checkout.sh');
const check = (h=reviewHead, extra={}) => run('bash',[checkoutTool,'--repo-root',consumer,'--head',h,'--','review'],{EXPECTED_REVIEW_HEAD:h,...extra});
const noCheckout = () => {
  assert.equal(cg('worktree','list','--porcelain').split('\n').filter(l=>l.startsWith('worktree ')).length,1);
  if(existsSync(join(consumer,'.worktrees'))) assert.deepEqual(readdirSync(join(consumer,'.worktrees')),[]);
};
r = check(); assert.equal(r.status,0,r.stderr); assert.match(r.stdout,new RegExp(`DEFAULT-FINDER:${reviewHead}:review`)); noCheckout();
const destination = join(consumer,'.worktrees',`review-${reviewHead}`);
cg('-c','core.hooksPath=/dev/null','worktree','add','--detach',destination,reviewHead);
const checkoutGit = sh('git',['rev-parse','--absolute-git-dir'],destination);
writeFileSync(join(checkoutGit,'review-checkout-owner'),`prepare-review-checkout:${consumer}:${reviewHead}\n`);
writeFileSync(join(destination,'stale.txt'),'interrupted finder dirt');
r = check(); assert.equal(r.status,0,r.stderr); noCheckout();
mkdirSync(destination); writeFileSync(join(destination,'unowned.txt'),'retain me');
r = check(); assert.equal(r.status,2); assert.match(r.stderr,/unowned/);
assert.equal(readFileSync(join(destination,'unowned.txt'),'utf8'),'retain me');
rmSync(destination,{recursive:true}); noCheckout();
console.log('PASS: owned stale checkout is reaped and recreated; unmarked path is retained and refused');
r = check(reviewHead,{FINDER_FIXTURE_STATUS:'9'}); assert.equal(r.status,9,r.stderr); noCheckout();
r = check('f'.repeat(40)); assert.notEqual(r.status,0); noCheckout();
writeFileSync(join(consumer,'scripts/codex-review.sh'),'echo HEAD-FINDER\n'); cg('add','.'); cg('commit','-qm','changed finder');
r = check(cg('rev-parse','HEAD')); assert.notEqual(r.status,0); assert.match(r.stderr,/scripts\/codex-review.sh/); assert.doesNotMatch(r.stdout,/HEAD-FINDER/); noCheckout();
cg('restore','--source',defaultHead,'scripts/codex-review.sh');
writeFileSync(join(consumer,'scripts/lib/helper.sh'),'# head library\n'); cg('add','.'); cg('commit','-qm','changed library');
r = check(cg('rev-parse','HEAD')); assert.notEqual(r.status,0); assert.match(r.stderr,/scripts\/lib\/helper.sh/); noCheckout();
// A head-relative hook must never execute, even with matching finder blobs.
cg('restore','--source',defaultHead,'scripts/lib/helper.sh');
const sentinel = join(tmp,'hook-sentinel');
mkdirSync(join(consumer,'.githooks'));
writeFileSync(join(consumer,'.githooks/post-checkout'),`#!/bin/sh\ntouch '${sentinel}'\n`);
chmodSync(join(consumer,'.githooks/post-checkout'),0o755);
cg('add','.'); cg('commit','-qm','head-relative hook');
cg('config','core.hooksPath','.githooks');
r = check(cg('rev-parse','HEAD')); assert.equal(r.status,0,r.stderr);
assert.equal(existsSync(sentinel),false); noCheckout();
cg('config','--unset','core.hooksPath');
// Simulate materialization corruption while status hides dirt: the physical
// proof must still reject changed, extra, missing, and index-hidden files.
const shim = join(tmp,'git-shim'); mkdirSync(shim);
const realGit = sh('bash',['-c','command -v git']);
for (const [mutation,diagnostic] of [
  ["printf '# hidden bytes\\n' > scripts/lib/helper.sh", /finder bytes differ/],
  ["printf '# extra\\n' > scripts/lib/extra.sh", /finder bytes differ/],
  ['rm scripts/lib/helper.sh', /finder bytes differ/],
  ['git update-index --skip-worktree scripts/lib/helper.sh', /skip-worktree or assume-unchanged/],
  ['git update-index --assume-unchanged scripts/lib/helper.sh', /skip-worktree or assume-unchanged/],
]) {
  writeFileSync(join(shim,'git'),`#!/bin/sh\nif [ "$1" = status ]; then exit 0; fi\nif [ "$3" = worktree ] && [ "$4" = add ]; then\n  '${realGit}' "$@" || exit $?\n  cd "$6" || exit 1\n  ${mutation}\n  exit $?\nfi\nexec '${realGit}' "$@"\n`);
  chmodSync(join(shim,'git'),0o755);
  r = check(reviewHead,{PATH:`${shim}:${env.PATH}`});
  assert.equal(r.status,2,r.stderr); assert.match(r.stderr,diagnostic); noCheckout();
}
// Fresh origin changes invalidate a once-identical head despite stale local main.
writeFileSync(join(remote,'scripts/lib/helper.sh'),'# new trusted library\n'); rg('add','.'); rg('commit','-qm','updated trusted finder');
r = check(); assert.notEqual(r.status,0); assert.match(r.stderr,/scripts\/lib\/helper.sh/); noCheckout();
rg('rm','scripts/codex-review.sh'); rg('commit','-qm','remove finder');
r = check(); assert.notEqual(r.status,0); assert.match(r.stderr,/ships no scripts\/codex-review.sh/); noCheckout();
console.log('PASS: detached exact-head default-identical finder execution, fresh-origin identity, missing head/finder, library changes, disabled hooks, physical bytes, finder status, and cleanup');
JS
