#!/usr/bin/env bash
# Offline integration tests: real monitor + run validator, fake GitHub transport.
set -euo pipefail
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
exec_arg="$asset_dir"
node --input-type=module - "$exec_arg" "$test_tmp" <<'JS'
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync, chmodSync, cpSync, rmSync, readdirSync, symlinkSync, existsSync } from 'node:fs';
import { execFileSync, spawnSync, spawn } from 'node:child_process';
import { join, dirname } from 'node:path';
import { createHash } from 'node:crypto';
const [assets, tmp] = process.argv.slice(2);
const monitor = join(assets, '../../orchestrate/assets/dev-flow-monitor.sh');
const sha = (s) => createHash('sha256').update(s).digest('hex');
const canon = (v) => v === null || typeof v !== 'object' ? JSON.stringify(v)
  : Array.isArray(v) ? `[${v.map(canon).join(',')}]`
    : `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(',')}}`;
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
cpSync(join(assets,'../../../../..','.devflow.toml'),join(repo,'.devflow.toml'));
cpSync(join(assets,'../../../../..','.gitleaks.toml'),join(repo,'.gitleaks.toml'));
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
const endpoint = a.find((arg)=>arg.startsWith('repos/'));
const emit = (value) => { console.log(JSON.stringify(a.includes('--slurp') ? [value] : value)); process.exit(0); };
if(endpoint === 'repos/example/repo') emit({default_branch:'main'});
if(endpoint === 'repos/example/repo/issues/1') emit({number:1});
if(endpoint?.includes('commits?path=agent-registry.json')) emit([{sha:d.head}]);
if(endpoint?.endsWith('/pulls')) emit([{merged_at:'2026-08-01T00:00:00Z',base:{ref:'main',repo:{full_name:'example/repo'}}}]);
if(endpoint?.includes('contents/agent-registry.json')) emit({encoding:'base64',content:Buffer.from(JSON.stringify({trusted_orchestrator_actor_ids:[12345]})).toString('base64')});
if (a[0] === 'repo') { console.log('https://github.com/example/repo'); process.exit(0); }
if (a[1] === 'user') { console.log(JSON.stringify({id:12345,login:d.login})); process.exit(0); }
if (a.includes('-F')) {
  if(!fs.fstatSync(9).isFile()) process.exit(9);
  // An append-only transport audit cannot lose a POST through competing
  // read/modify/write updates of the fake GitHub JSON store.
  fs.appendFileSync(p+'.posts',process.pid+'\\n');
  if(d.delayMs) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,d.delayMs);
  d.posts++;
  if (!fs.existsSync(d.monitor) || !JSON.parse(fs.readFileSync(d.monitor)).actions.length) process.exit(9);
  const body = fs.readFileSync(a[a.indexOf('-F')+1].slice(6),'utf8');
  d.comments.push({id:200,user:{id:12345,login:d.login},body,created_at:'2026-08-20T09:01:00Z',updated_at:'2026-08-20T09:01:00Z'});
  fs.writeFileSync(p,JSON.stringify(d));
  if (d.ambiguous) process.exit(1);
  console.log(JSON.stringify(d.comments.at(-1))); process.exit(0);
}
if (d.fetchFailure) process.exit(1);
if (d.fullPages) { console.log(JSON.stringify(Array.from({length:100},()=>({id:1,user:{id:999},body:'unrelated'})))); process.exit(0); }
emit(d.comments);
`);
chmodSync(join(bin, 'gh'), 0o755);
writeFileSync(join(bin,'gitleaks'),`#!/usr/bin/env node
const fs=require('node:fs');
const p=process.env.POST_EVIDENCE_TEST_DATA;
const d=JSON.parse(fs.readFileSync(p,'utf8'));
const body=fs.readFileSync(0,'utf8');
const args=process.argv.slice(2);
if(args[0]!=='stdin'||!args.includes('--no-banner')||!args.includes('--redact')) process.exit(9);
fs.appendFileSync(p+'.scans',JSON.stringify({args,body})+'\\n');
if(d.scanDetection) { console.error('SYNTHETIC_DETECTED_VALUE'); process.exit(1); }
if(d.scanFailure) process.exit(2);
`);
chmodSync(join(bin,'gitleaks'),0o755);

const runID = 'run-1-evidence-test';
const active = command('bash', [monitor, 'active-path', '--branch', 'test', '--repo-root', repo]);
const state = command('bash', [monitor, 'state-path', '--run-id', runID, '--repo-root', repo]);
mkdirSync(dirname(state), { recursive: true });
writeFileSync(join(dirname(state), 'owner-slate'), 'fixture\n');
put(join(dirname(state), 'run.json'), { schema:2, run_id:runID, outcome:null,
  dispatch_admission:{slate:'fixture', working:1, in_flight:1, at:'2026-08-20T09:00:00Z'} });
command('bash', [monitor, 'activate', '--active-state', active, '--run-id', runID, '--branch', 'test',
  '--expected-predecessor', 'absent', '--expected-generation', '0', '--registry-revision', head,
  '--writer', 'feature-owner', '--repo-root', repo]);
const run = join(dirname(state), 'run.json');
mkdirSync(join(dirname(run), 'adjudications'));
mkdirSync(join(dirname(run), 'passes'));
put(join(dirname(run),'adjudications/challenge-r1.json'), {schema:2,run_id:runID,stage:'challenge',round:1,reviewed_head:head,adjudications:[]});
put(join(dirname(run),'passes/challenge-r1-codex.json'), {schema:2,role:'reviewer',status:'completed',head,produced_at:'2026-08-20T09:00:00Z',
  producer:{harness:'codex-adversarial',model:'fixture-model',tier:'local'},run:{run_id:runID,initiated_by:'human'},
  payload:{stage:'challenge',round:1,reviewed_head:head,finder:'codex-adversarial',findings:[],counts:{P0:0,P1:0,P2:0,P3:0}}});
const at = '2026-08-20T09:00:00Z';
const baseRun = { schema:2,run_id:runID,initiated_by:'human',started_at:at,
  stage_transitions:['kickoff','claim','plan','implement','verify','challenge'].map((stage,i)=>({stage,entered_at:at,...(i<5?{exit:'complete'}:{})})),
  receipts:[{kind:'transition',stage:'challenge',entered_at:at},{kind:'pass',file:'challenge-r1-codex'}],interventions:[],outcome:null,pr:null,
  evidence_comments:[],evidence_registrations:[],pr_bindings:[],outcome_transitions:[],settlements:[],promotion:null };
const markerFile = join(tmp, 'marker.json');
const bodyFile = join(tmp, 'summary.md');
const marker = {run_id:runID,stage:'challenge',round:1,sequence:1,destination:'issue'};
const projection = {run_id:runID,stage:'challenge',round:1,reviewed_head:head,
  passes:[{payload:{findings:[]}}],findingAttributions:null};
const payload = JSON.stringify(projection, null, 2);
const summary = `Round evidence\n\n\`\`\`json\n${payload}\n\`\`\`\n`;
const body = `<!-- dev-flow-v2-evidence: ${JSON.stringify(marker)} -->\n\n${summary}`;
function reset(extra={}) {
  rmSync(data+'.posts',{force:true});
  rmSync(data+'.scans',{force:true});
  rmSync(join(dirname(state),'evidence-issue-challenge-r1-s1.body.md'),{force:true});
  put(run,baseRun); put(state,{version:1,cursor:null,actions:[]}); put(markerFile,marker); writeFileSync(bodyFile,summary);
  put(data,{monitor:state,head,posts:0,comments:[],login:'writer',...extra});
}
const argv = ['--repo','example/repo','--repo-root',repo,'--run',run,'--branch','test','--generation','1','--active-state',active,'--head',head,'--actor-id','12345','--role','challenger','--finder','codex','--issue','1','--marker-file',markerFile,'--body-file',bodyFile,'--scratch-dir',tmp];
function invoke(expected=0, needle='', helper=join(assets,'post-evidence.sh'), invocationArgs=argv) {
  const r=spawnSync('bash',[helper,...invocationArgs],{env,encoding:'utf8'});
  assert.equal(r.status,expected,r.stderr);
  if(needle) assert.ok(r.stderr.includes(needle),r.stderr);
  return r;
}
reset();
invoke();
let d=read(data); assert.equal(d.posts,1); assert.equal(d.comments[0].body,body);
const scanned=JSON.parse(readFileSync(data+'.scans','utf8').trim());
assert.equal(scanned.body,body);
assert.equal(scanned.args[scanned.args.indexOf('--config')+1],join(repo,'.gitleaks.toml'));
console.log('PASS: clean gitleaks scan receives exact marker-inclusive body and repo config before publication');

// Execute the ACTUAL harvester regex, rather than maintaining a test copy.
const harvester = readFileSync(join(assets,'../../retro/assets/dev-flow-stats.mjs'),'utf8');
const literal = harvester.match(/^const EVIDENCE_SUMMARY_MARKER_RE = (\/.*\/);$/m)[1];
const regex = Function(`return ${literal}`)();
assert.deepEqual(JSON.parse(regex.exec(d.comments[0].body)[1]),marker);
let record=read(run); assert.equal(record.evidence_registrations.length,1);
assert.equal(record.evidence_comments[0].digest,`sha256:${sha(body)}`);
assert.equal(record.evidence_registrations[0].payload_digest,`sha256:${sha(body)}`);
assert.notEqual(record.evidence_comments[0].digest,`sha256:${sha(payload)}`);
const harvesterArgs=[join(assets,'../../retro/assets/dev-flow-stats.mjs'),'--repo','example/repo','--run',runID,
  '--record-dir',dirname(dirname(run)),'--repo-root',repo,'--trusted-actor-id','12345','--json'];
const harvested=spawnSync('node',harvesterArgs,{env,encoding:'utf8'});
assert.equal(harvested.status,0,harvested.stderr);
const trajectory=JSON.parse(harvested.stdout);
assert.equal(trajectory.run_id,runID);
assert.equal(trajectory.issue,1);
assert.deepEqual(trajectory.tampered_comments,[]);
// Negative control proves the same CLI read authenticates the body, rather
// than taking the marker-only/evidence-only discovery shortcut.
const registered=readFileSync(run,'utf8');
record.evidence_comments[0].digest=`sha256:${sha(payload)}`;
record.evidence_registrations[0].payload_digest=record.evidence_comments[0].digest;
const {seq:_seq,digest:_digest,...registrationContent}=record.evidence_registrations[0];
record.evidence_registrations[0].digest=sha(canon(registrationContent));
put(run,record);
const rejected=spawnSync('node',harvesterArgs,{env,encoding:'utf8'});
assert.equal(rejected.status,3,rejected.stderr);
assert.match(rejected.stderr,/does not authenticate/);
writeFileSync(run,registered);
console.log('PASS: real harvester --record-dir authenticates helper whole-body evidence and rejects a fenced-only digest');
const initial=readFileSync(run,'utf8');
d.login='renamed'; d.comments[0].user.login='renamed'; put(data,d);
invoke(); assert.equal(read(data).posts,1); assert.equal(readFileSync(run,'utf8'),initial);
console.log('PASS: canonical first line parses with harvester regex; whole-body digest, chain and exact re-arm survive login rename');
reset({ambiguous:true}); invoke(2,'Command failed'); assert.equal(read(data).posts,1); assert.equal(read(run).evidence_comments.length,0);
d=read(data); d.ambiguous=false; put(data,d); invoke(); assert.equal(read(data).posts,1); assert.equal(read(run).evidence_comments[0].id,'200');
console.log('PASS: crash after POST before reconciliation adopts without another write');
const bodyArg=argv.indexOf('--body-file');
const noBodyArgs=argv.filter((_,i)=>i!==bodyArg&&i!==bodyArg+1);
reset({ambiguous:true}); invoke(2,'Command failed');
assert.equal(readFileSync(join(dirname(state),'evidence-issue-challenge-r1-s1.body.md'),'utf8'),body);
const changedIssue=[...noBodyArgs]; changedIssue[changedIssue.indexOf('--issue')+1]='2';
invoke(2,'issue does not match',join(assets,'post-evidence.sh'),changedIssue); assert.equal(read(data).posts,1);
const changedRepo=[...noBodyArgs]; changedRepo[changedRepo.indexOf('--repo')+1]='example/other';
invoke(2,'repository does not match',join(assets,'post-evidence.sh'),changedRepo); assert.equal(read(data).posts,1);
d=read(data); d.ambiguous=false; put(data,d);
rmSync(bodyFile); invoke(0,'',join(assets,'post-evidence.sh'),noBodyArgs);
assert.equal(read(data).posts,1); assert.equal(read(run).evidence_comments.length,1);
writeFileSync(bodyFile,summary+'changed'); invoke(2,'caller body differs'); assert.equal(read(data).posts,1);
reset({fetchFailure:true}); invoke(2,'Command failed'); d=read(data); d.fetchFailure=false; put(data,d);
rmSync(bodyFile); invoke(0,'',join(assets,'post-evidence.sh'),noBodyArgs); assert.equal(read(data).posts,1);
reset(); rmSync(state); invoke(); assert.equal(read(data).posts,1);
reset(); const noAttributions={...projection}; delete noAttributions.findingAttributions;
writeFileSync(bodyFile,`\`\`\`json\n${JSON.stringify(noAttributions)}\n\`\`\`\n`);
invoke(); assert.equal(read(data).posts,1);
console.log('PASS: first reservation creates missing monitor state; null or absent attributions do not gate publication');
// Orphan persisted bytes are untrusted until the event is reserved.
reset(); writeFileSync(join(dirname(state),'evidence-issue-challenge-r1-s1.body.md'),'torn');
invoke(); assert.equal(readFileSync(join(dirname(state),'evidence-issue-challenge-r1-s1.body.md'),'utf8'),body);
assert.equal(read(data).posts,1);
reset(); writeFileSync(join(dirname(state),'evidence-issue-challenge-r1-s1.body.md'),'orphan');
const wrongGeneration=[...argv]; wrongGeneration[wrongGeneration.indexOf('--generation')+1]='2';
invoke(2,'Command failed',join(assets,'post-evidence.sh'),wrongGeneration);
assert.equal(read(state).actions.length,0); assert.equal(read(data).posts,0);
assert.throws(()=>readFileSync(join(dirname(state),'evidence-issue-challenge-r1-s1.body.md')),/ENOENT/);
// Reserve refusal cannot pin the next caller's body.
writeFileSync(bodyFile,summary+' revised'); invoke();
assert.equal(readFileSync(join(dirname(state),'evidence-issue-challenge-r1-s1.body.md'),'utf8'),body+' revised');
console.log('PASS: torn orphan body is replaced; reserve refusal leaves no pinned body');
console.log('PASS: crash recovery uses persisted bytes with no caller body; destination/body changes refuse before POST');
reset({delayMs:400});
const concurrent=()=>new Promise((resolve,reject)=>{
  const child=spawn('bash',[join(assets,'post-evidence.sh'),...argv],{env});
  let stdout='',stderr=''; child.stdout.on('data',(s)=>stdout+=s); child.stderr.on('data',(s)=>stderr+=s);
  child.on('error',reject); child.on('close',(status)=>resolve({status,stdout,stderr}));
});
const concurrentResults=await Promise.all([concurrent(),concurrent()]);
for(const result of concurrentResults) assert.equal(result.status,0,result.stderr);
assert.equal(read(data).posts,1); assert.equal(read(data).comments.length,1);
assert.equal(readFileSync(data+'.posts','utf8').trim().split('\n').length,1);
assert.equal(read(run).evidence_registrations.length,1); assert.equal(read(state).actions.length,1);
console.log('PASS: two concurrent invocations serialize the complete transaction: exactly one comment and registration');
// Queue the real transition CLI and helper behind the same run-record mutex.
// While it is held, even a completed POST cannot register; after release,
// both read/modify/writes must survive regardless of their acquisition order.
reset();
const runWriter=join(assets,'../../dev-flow-support/assets/run-record.mjs');
const ownerToken=execFileSync('node',[runWriter,'lock','acquire','--slate','test-slate','--session','test-session','--issues','1'],{env,cwd:repo,encoding:'utf8'}).trim();
writeFileSync(join(dirname(run),'owner-slate'),'test-slate\n');
const held=join(tmp,'run-mutex-held'), release=join(tmp,'run-mutex-release');
const launch=(args)=>{
  const child=spawn('node',args,{env,cwd:repo});
  let stderr=''; child.stderr.on('data',(chunk)=>stderr+=chunk);
  child.stdout.resume();
  return new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',(status)=>resolve({status,stderr}));});
};
const holding=launch(['--input-type=module','-e',`
  import {withMutex} from ${JSON.stringify(runWriter)};
  import {writeFileSync,existsSync} from 'node:fs';
  withMutex(${JSON.stringify(run)},()=>{
    writeFileSync(${JSON.stringify(held)},'held');
    const deadline=Date.now()+10000;
    while(!existsSync(${JSON.stringify(release)})) {
      if(Date.now()>deadline) throw new Error('test release deadline exceeded');
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)),0,0,20);
    }
  });
`,run]);
const waitFor=async(predicate)=>{
  const deadline=Date.now()+8000;
  while(!predicate()) {
    assert.ok(Date.now()<deadline,'concurrent fixture did not reach its barrier');
    await new Promise((resolve)=>setTimeout(resolve,20));
  }
};
let transitioning, publishing;
try {
  await waitFor(()=>{try{return readFileSync(held,'utf8')==='held';}catch{return false;}});
  transitioning=launch([runWriter,'transition','--slate','test-slate','--session','test-session','--owner-token',ownerToken,'--issues','1',
    '--run-id',runID,'--stage','implement','--exit','fixture remediation','--at','2026-08-20T09:02:00Z']);
  publishing=concurrent();
  await waitFor(()=>{try{return readFileSync(data+'.posts','utf8').trim().length>0;}catch{return false;}});
  await new Promise((resolve)=>setTimeout(resolve,700));
  assert.equal(read(run).evidence_registrations.length,0,'registration bypassed the shared writer mutex');
  assert.equal(read(run).stage_transitions.at(-1).stage,'challenge');
} finally {writeFileSync(release,'release');}
for(const result of await Promise.all([holding,transitioning,publishing])) assert.equal(result.status,0,result.stderr);
assert.equal(read(run).evidence_registrations.length,1);
assert.equal(read(run).stage_transitions.at(-1).stage,'implement');
assert.deepEqual(read(run).receipts.at(-1),{kind:'transition',stage:'implement',entered_at:'2026-08-20T09:02:00Z'});
console.log('PASS: real run-record transition and helper registration share the mutex and both land');
reset(); const otherIssue=[...argv]; otherIssue[otherIssue.indexOf('--issue')+1]='2';
invoke(2,'issue does not match',join(assets,'post-evidence.sh'),otherIssue);
assert.equal(read(data).posts,0); assert.equal(read(state).actions.length,0);
console.log('PASS: destination issue must match canonical run identity before reservation or POST');

reset({scanDetection:true}); const detected=invoke(2,'gitleaks secret scan refused');
assert.equal(read(state).actions.length,0); assert.equal(read(data).posts,0);
assert.ok(!detected.stderr.includes('SYNTHETIC_DETECTED_VALUE')); assert.ok(!detected.stdout.includes('SYNTHETIC_DETECTED_VALUE'));
reset({scanFailure:true}); invoke(2,'gitleaks secret scan refused'); assert.equal(read(state).actions.length,0); assert.equal(read(data).posts,0);
// Retain every required command except gitleaks, including the fake gh.
const scannerMissingBin=join(tmp,'scanner-missing-bin'); mkdirSync(scannerMissingBin);
for(const dir of env.PATH.split(':')) {
  if(!dir||!existsSync(dir)) continue;
  for(const name of readdirSync(dir)) {
    if(name==='gitleaks'||existsSync(join(scannerMissingBin,name))) continue;
    try { symlinkSync(join(dir,name),join(scannerMissingBin,name)); } catch(error) { if(error.code!=='EEXIST') throw error; }
  }
}
reset(); const scanPath=env.PATH;
try {env.PATH=scannerMissingBin; invoke(2,'gitleaks is required on PATH');}
finally {env.PATH=scanPath;}
assert.equal(read(state).actions.length,0); assert.equal(read(data).posts,0);
console.log('PASS: detections, scanner failures and missing gitleaks refuse before reserve/POST without printing matched values');
reset({comments:[{id:40,user:null,body},{id:41,user:{login:'deleted'},body}]}); invoke();
assert.equal(read(data).posts,1); assert.equal(read(run).evidence_comments[0].id,'200');
console.log('PASS: null or missing author IDs are unauthenticated candidates, never adopted');
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
// Quoting marker text is valid data; only another marker-form line conflicts.
reset(); const quoted={...projection,quoted:'<!-- dev-flow-v2-evidence: example -->'};
writeFileSync(bodyFile,`Quoted marker text: \`<!-- dev-flow-v2-evidence: example -->\`\n\n\`\`\`json\n${JSON.stringify(quoted,null,2)}\n\`\`\`\n`);
invoke(); assert.equal(read(data).posts,1);
reset(); writeFileSync(bodyFile,summary+'  <!-- dev-flow-v2-evidence: example -->\n');
invoke(2,'no evidence marker'); assert.equal(read(state).actions.length,0); assert.equal(read(data).posts,0);
console.log('PASS: marker text quoted in JSON/prose is accepted; a second marker-form line refuses before reserve or POST');
// The named round must exist locally before any publication reservation.
reset(); put(markerFile,{...marker,round:2});
writeFileSync(bodyFile,`\`\`\`json\n${JSON.stringify({...projection,round:2})}\n\`\`\`\n`);
invoke(2,'round challenge-r2 has no retained adjudication'); assert.equal(read(state).actions.length,0); assert.equal(read(data).posts,0);
const passFile=join(dirname(run),'passes/challenge-r1-codex.json');
const retainedPass=readFileSync(passFile,'utf8');
reset(); rmSync(passFile); invoke(2,'no retained pass with a run receipt');
assert.equal(read(state).actions.length,0); assert.equal(read(data).posts,0); writeFileSync(passFile,retainedPass);
reset(); const unreceipted=read(run); unreceipted.receipts=unreceipted.receipts.filter((r)=>r.kind!=='pass'); put(run,unreceipted);
invoke(2,'no retained pass with a run receipt'); assert.equal(read(state).actions.length,0); assert.equal(read(data).posts,0);
const adjudicationFile=join(dirname(run),'adjudications/challenge-r1.json');
const retainedAdjudication=readFileSync(adjudicationFile,'utf8');
reset(); put(adjudicationFile,{...read(adjudicationFile),round:0}); invoke(2,'validation');
assert.equal(read(state).actions.length,0); assert.equal(read(data).posts,0); writeFileSync(adjudicationFile,retainedAdjudication);
reset(); put(adjudicationFile,{...read(adjudicationFile),round:2}); invoke(2,'round evidence binding mismatch');
assert.equal(read(state).actions.length,0); assert.equal(read(data).posts,0); writeFileSync(adjudicationFile,retainedAdjudication);
console.log('PASS: a round-1-only run refuses round 2; invalid or misbound adjudications and absent/unreceipted passes refuse before reserve or POST');
// All retained heads must equal the projection and the requested head.
const otherHead='b'.repeat(40);
reset(); const headBArgs=[...argv]; headBArgs[headBArgs.indexOf('--head')+1]=otherHead;
writeFileSync(bodyFile,`\`\`\`json\n${JSON.stringify({...projection,reviewed_head:otherHead})}\n\`\`\`\n`);
const oldRound=invoke(2,'adjudication head '+head,join(assets,'post-evidence.sh'),headBArgs);
assert.ok(oldRound.stderr.includes('expected --head '+otherHead));
assert.equal(read(state).actions.length,0); assert.equal(read(data).posts,0);
// A matching first pass cannot hide a mismatched later receipted pass.
reset(); const secondPass=join(dirname(run),'passes/challenge-r1-second.json');
put(secondPass,{...read(passFile),head:otherHead});
const twoPasses=read(run); twoPasses.receipts.push({kind:'pass',file:'challenge-r1-second'}); put(run,twoPasses);
const divergentPass=invoke(2,'challenge-r1-second.json head '+otherHead);
assert.ok(divergentPass.stderr.includes('expected --head '+head));
assert.equal(read(state).actions.length,0); assert.equal(read(data).posts,0); rmSync(secondPass);
invoke(2,'challenge-r1-second.json head missing'); assert.equal(read(state).actions.length,0); assert.equal(read(data).posts,0);
console.log('PASS: head-A round cannot publish as head B; every receipted pass must share the adjudication/projection head before reserve or POST');

reset(); writeFileSync(bodyFile,summary.replace(head,'0'.repeat(40))); invoke(2,'round evidence binding mismatch');
for(const field of ['passes']) {
  reset(); const incomplete={...projection}; delete incomplete[field];
  writeFileSync(bodyFile,`\`\`\`json\n${JSON.stringify(incomplete)}\n\`\`\`\n`);
  invoke(2,'projection requires'); assert.equal(read(state).actions.length,0); assert.equal(read(data).posts,0);
}
reset(); writeFileSync(bodyFile,'x'.repeat(60001)+summary); invoke(2,'60,000-byte single-comment budget');
reset({fetchFailure:true}); invoke(2,'Command failed'); assert.equal(read(data).posts,0);
reset({fullPages:true}); invoke(2,'bounded destination read'); assert.equal(read(data).posts,0);
console.log('PASS: invalid marker/payload, oversized comment, failed and incomplete fetch never post');
reset(); invoke(); record=read(run); record.evidence_comments[0].digest='sha256:'+'0'.repeat(64); put(run,record); invoke(2,'validation'); assert.equal(read(data).posts,1);
reset(); invoke(); const changed=read(markerFile); changed.round=2; put(markerFile,changed); invoke(2,'round challenge-r2 has no retained adjudication');
console.log('PASS: invalid run registration and changed projection refuse');
// Consumer layout, no repository-root runtime dependencies; source sibling
// assets are copied physically, like sync:skills' flattened package tree.
const consumer=join(tmp,'consumer'); mkdirSync(consumer);
for(const name of ['review','orchestrate','dev-flow-support']) cpSync(join(assets,'../..',name),join(consumer,name),{recursive:true});
reset(); invoke(0,'',join(consumer,'review/assets/post-evidence.sh'));
console.log('PASS: helper runs with only flattened vendored sibling packages');
JS
