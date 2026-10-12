#!/usr/bin/env bash
# Offline integration tests: real monitor + run validator, fake GitHub transport.
set -euo pipefail
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
exec_arg="$asset_dir"
node --input-type=module - "$exec_arg" "$test_tmp" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, chmodSync, cpSync } from 'node:fs';
import { execFileSync, spawnSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { createHash } from 'node:crypto';
const [assets, tmp] = process.argv.slice(2);
const monitor = join(assets, '../../orchestrate/assets/dev-flow-monitor.sh');
const sha = (s) => createHash('sha256').update(s).digest('hex');
const read = (p) => JSON.parse(readFileSync(p, 'utf8'));
const put = (p, v) => writeFileSync(p, JSON.stringify(v));
const env = { ...process.env, GIT_CONFIG_GLOBAL: join(tmp, 'gitconfig'), GIT_CONFIG_NOSYSTEM: '1' };
delete env.GIT_CONFIG_COUNT;
delete env.GIT_CONFIG_PARAMETERS;
for (const key of Object.keys(env)) if (/^GIT_CONFIG_(KEY|VALUE)_/.test(key)) delete env[key];
const command = (cmd, args) => execFileSync(cmd, args, { env, encoding: 'utf8' }).trim();
const repo = join(tmp, 'repo');
mkdirSync(repo);
command('git', ['init', '-q', '-b', 'main', repo]);
command('git', ['-C', repo, 'config', 'user.name', 'Test']);
command('git', ['-C', repo, 'config', 'user.email', 'test@example.invalid']);
command('git', ['-C', repo, 'config', 'commit.gpgsign', 'false']);
put(join(repo, 'agent-registry.json'), { trusted_orchestrator_actor_ids: [12345] });
command('git', ['-C', repo, 'add', 'agent-registry.json']);
command('git', ['-C', repo, 'commit', '-qm', 'initial registry']);
command('git', ['-C', repo, 'remote', 'add', 'origin', 'https://github.com/example/repo']);
const head = command('git', ['-C', repo, 'rev-parse', 'HEAD']);
command('git', ['-C', repo, 'update-ref', 'refs/remotes/origin/main', head]);
command('git', ['-C', repo, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main']);
const bin = join(tmp, 'bin');
mkdirSync(bin);
const data = join(tmp, 'github.json');
env.POST_EVIDENCE_TEST_DATA = data;
env.PATH = `${bin}:${env.PATH}`;
writeFileSync(join(bin, 'gh'), `#!/usr/bin/env node
const fs = require('node:fs');
const p = process.env.POST_EVIDENCE_TEST_DATA;
const d = JSON.parse(fs.readFileSync(p, 'utf8'));
const a = process.argv.slice(2);
if (a[0] === 'repo') { console.log('https://github.com/example/repo'); process.exit(0); }
if (a[1] === 'user') { console.log(JSON.stringify({id:12345,login:d.login})); process.exit(0); }
if (a.includes('-F')) {
  d.posts++;
  if (!fs.existsSync(d.monitor) || !JSON.parse(fs.readFileSync(d.monitor)).actions.length) process.exit(9);
  const body = fs.readFileSync(a[a.indexOf('-F')+1].slice(6),'utf8');
  d.comments.push({id:200,user:{id:12345,login:d.login},body});
  fs.writeFileSync(p,JSON.stringify(d));
  if (d.ambiguous) process.exit(1);
  console.log(JSON.stringify(d.comments.at(-1))); process.exit(0);
}
if (d.fetchFailure) process.exit(1);
if (d.fullPages) { console.log(JSON.stringify(Array.from({length:100},()=>({id:1,user:{id:999},body:'unrelated'})))); process.exit(0); }
console.log(JSON.stringify(d.comments));
`);
chmodSync(join(bin, 'gh'), 0o755);
const runID = 'run-evidence-test';
const active = command('bash', [monitor, 'active-path', '--branch', 'test', '--repo-root', repo]);
const state = command('bash', [monitor, 'state-path', '--run-id', runID, '--repo-root', repo]);
command('bash', [monitor, 'activate', '--active-state', active, '--run-id', runID, '--branch', 'test', '--expected-generation', '0', '--registry-revision', head, '--writer', 'feature-owner', '--repo-root', repo]);
const run = join(dirname(state), 'run.json');
mkdirSync(join(dirname(run), 'adjudications'));
const at = '2026-08-20T09:00:00Z';
const baseRun = { schema:2,run_id:runID,initiated_by:'human',started_at:at,
  stage_transitions:['kickoff','claim','plan','implement','verify','challenge'].map((stage,i)=>({stage,entered_at:at,...(i<5?{exit:'complete'}:{})})),
  receipts:[{kind:'transition',stage:'challenge',entered_at:at}],interventions:[],outcome:null,pr:null,
  evidence_comments:[],evidence_registrations:[],pr_bindings:[],outcome_transitions:[],settlements:[],promotion:null };
const markerFile = join(tmp, 'marker.json');
const bodyFile = join(tmp, 'summary.md');
const marker = {run_id:runID,stage:'challenge',round:1,sequence:1,destination:'issue'};
const payload = JSON.stringify({run_id:runID,stage:'challenge',round:1,reviewed_head:head,findings:[]}, null, 2);
const summary = `Round evidence\n\n\`\`\`json\n${payload}\n\`\`\`\n`;
const body = `<!-- dev-flow-v2-evidence: ${JSON.stringify(marker)} -->\n\n${summary}`;
function reset(extra={}) {
  put(run,baseRun); put(state,{version:1,cursor:null,actions:[]}); put(markerFile,marker); writeFileSync(bodyFile,summary);
  put(data,{monitor:state,posts:0,comments:[],login:'writer',...extra});
}
const argv = ['--repo','example/repo','--repo-root',repo,'--run',run,'--branch','test','--generation','1','--active-state',active,'--head',head,'--actor-id','12345','--role','challenger','--finder','codex','--issue','1','--marker-file',markerFile,'--body-file',bodyFile,'--scratch-dir',tmp];
function invoke(expected=0, needle='', helper=join(assets,'post-evidence.sh')) {
  const r=spawnSync('bash',[helper,...argv],{env,encoding:'utf8'});
  assert.equal(r.status,expected,r.stderr);
  if(needle) assert.ok(r.stderr.includes(needle),r.stderr);
  return r;
}
reset();
invoke();
let d=read(data); assert.equal(d.posts,1); assert.equal(d.comments[0].body,body);
// Execute the ACTUAL harvester regex, rather than maintaining a test copy.
const harvester = readFileSync(join(assets,'../../retro/assets/dev-flow-stats.mjs'),'utf8');
const literal = harvester.match(/^const EVIDENCE_SUMMARY_MARKER_RE = (\/.*\/);$/m)[1];
const regex = Function(`return ${literal}`)();
assert.deepEqual(JSON.parse(regex.exec(d.comments[0].body)[1]),marker);
let record=read(run); assert.equal(record.evidence_registrations.length,1);
assert.equal(record.evidence_comments[0].digest,`sha256:${sha(payload)}`);
assert.notEqual(record.evidence_comments[0].digest,`sha256:${sha(body)}`);
const initial=readFileSync(run,'utf8');
d.login='renamed'; d.comments[0].user.login='renamed'; put(data,d);
invoke(); assert.equal(read(data).posts,1); assert.equal(readFileSync(run,'utf8'),initial);
console.log('PASS: canonical first line parses with harvester regex; fenced digest, chain and exact re-arm survive login rename');
reset({ambiguous:true}); invoke(2,'Command failed'); assert.equal(read(data).posts,1); assert.equal(read(run).evidence_comments.length,0);
d=read(data); d.ambiguous=false; put(data,d); invoke(); assert.equal(read(data).posts,1); assert.equal(read(run).evidence_comments[0].id,'200');
console.log('PASS: crash after POST before reconciliation adopts without another write');
reset({comments:[{id:50,user:{id:999,login:'untrusted'},body}]}); invoke(); assert.equal(read(data).posts,1); assert.equal(read(run).evidence_comments[0].id,'200');
reset({comments:[{id:90,user:{id:12345,login:'writer'},body},{id:70,user:{id:12345,login:'writer'},body}]}); invoke(); assert.equal(read(data).posts,0); assert.equal(read(run).evidence_comments[0].id,'70');
console.log('PASS: untrusted marker cannot suppress post; lowest authenticated duplicate is registered');
reset({comments:[{id:70,user:{id:12345,login:'writer'},body:body+'edited'}]}); invoke(2,'Command failed'); assert.equal(read(data).posts,0);
reset(); invoke(); d=read(data); d.comments[0].body+='edited'; put(data,d); invoke(2,'Command failed'); assert.equal(read(data).posts,1);
reset(); invoke(); d=read(data); d.comments=[]; put(data,d); invoke(2,'Command failed'); assert.equal(read(data).posts,1);
console.log('PASS: conflicting, edited and deleted authenticated comments block re-arm');
for(const bad of [{...marker,extra:1},{...marker,round:null},{...marker,destination:'pr'},{...marker,sequence:0},{...marker,stage:'retro'}]) {
 reset(); put(markerFile,bad); invoke(2,'marker grammar'); assert.equal(read(data).posts,0); assert.equal(read(state).actions.length,0);
}
reset(); writeFileSync(bodyFile,summary.replace(head,'0'.repeat(40))); invoke(2,'projection does not bind');
reset(); writeFileSync(bodyFile,'x'.repeat(60001)+summary); invoke(2,'single-segment budget');
reset({fetchFailure:true}); invoke(2,'Command failed'); assert.equal(read(data).posts,0);
reset({fullPages:true}); invoke(2,'bounded destination read'); assert.equal(read(data).posts,0);
console.log('PASS: invalid marker/payload, oversized comment, failed and incomplete fetch never post');
reset(); invoke(); record=read(run); record.evidence_comments[0].digest='sha256:'+'0'.repeat(64); put(run,record); invoke(2,'Command failed'); assert.equal(read(data).posts,1);
reset(); invoke(); const changed=read(markerFile); changed.round=2; put(markerFile,changed); invoke(2,'projection does not bind');
console.log('PASS: invalid run registration and changed projection refuse');
// Consumer layout, no repository-root runtime dependencies; source sibling
// assets are copied physically, like sync:skills' flattened package tree.
const consumer=join(tmp,'consumer'); mkdirSync(consumer);
for(const name of ['review','orchestrate','dev-flow-support']) cpSync(join(assets,'../..',name),join(consumer,name),{recursive:true});
reset(); invoke(0,'',join(consumer,'review/assets/post-evidence.sh'));
console.log('PASS: helper runs with only flattened vendored sibling packages');
JS
