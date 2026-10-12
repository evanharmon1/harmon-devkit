#!/usr/bin/env bash
# Post one sanitized, verification-bound round projection and register it.
# Node handles byte-exact JSON/digests; sibling assets remain portable when vendored.
set -euo pipefail
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# Use the POSIX advisory lock from Python's standard library on Linux/macOS.
# The inherited descriptor stays open for the WHOLE Node transaction and the
# kernel releases it on exit/crash; there is no stale PID lock to reclaim.
# No-argument usage still comes from the Node argument validator below.
run_file=""
arguments=("$@")
for ((i = 0; i + 1 < ${#arguments[@]}; i++)); do
    if [ "${arguments[$i]}" = "--run" ]; then
        run_file="${arguments[$((i + 1))]}"
        break
    fi
done
runner=(node --input-type=module - "$asset_dir" "$@")
if [ -n "$run_file" ]; then
    command -v python3 >/dev/null 2>&1 || {
        echo 'post-evidence: python3 is required for the publication lock' >&2
        exit 2
    }
    runner=(python3 -c '
import fcntl, os, sys, time
run = os.path.realpath(sys.argv[1])
if not os.path.isfile(run):
    sys.exit("post-evidence: run file does not exist")
fd = os.open(os.path.join(os.path.dirname(run), "post-evidence.lock"), os.O_CREAT | os.O_RDWR, 0o600)
if fd != 9:
    os.dup2(fd, 9)
    os.close(fd)
os.set_inheritable(9, True)
deadline = time.monotonic() + 30
while True:
    try:
        fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        if time.monotonic() >= deadline:
            sys.stderr.write("post-evidence: publication lock unavailable after 30 seconds\n")
            sys.exit(2)
        time.sleep(0.1)
os.execvp(sys.argv[2], sys.argv[2:])
' "$run_file" "${runner[@]}")
fi
exec "${runner[@]}" <<'JS'
import { readFileSync, writeFileSync, readdirSync, renameSync, rmSync, mkdtempSync, realpathSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { join, dirname } from 'node:path';
const [assetDir, ...args] = process.argv.slice(2);
const fail = (message) => { throw new Error(message); };
const options = {};
const names = ['repo', 'repo-root', 'run', 'branch', 'generation', 'active-state', 'head', 'actor-id', 'role', 'finder', 'issue', 'marker-file', 'body-file', 'scratch-dir'];
try {
  for (let i = 0; i < args.length; i += 2) {
    const name = args[i].replace(/^--/, '');
    if (!args[i].startsWith('--') || !names.includes(name) || !args[i + 1] || options[name]) fail('invalid or duplicate argument');
    options[name] = args[i + 1];
  }
  if (names.filter((name) => name !== 'body-file').some((name) => !options[name])) fail('usage: post-evidence.sh --repo OWNER/REPO --repo-root DIR --run FILE --branch NAME --generation N --active-state FILE --head SHA --actor-id ID --role ROLE --finder FINDER --issue N --marker-file FILE [--body-file FILE] --scratch-dir DIR');
  const o = options;
  const sha = (text) => createHash('sha256').update(text, 'utf8').digest('hex');
  const canon = (v) => v === null || typeof v !== 'object' ? JSON.stringify(v)
    : Array.isArray(v) ? `[${v.map(canon).join(',')}]`
      : `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(',')}}`;
  const read = (file) => JSON.parse(readFileSync(file, 'utf8'));
  // The monitor proves re-arm authority through the same open description.
  // The POST transport retains it too: if Node crashes while HTTP is still
  // in flight, that mutator must finish before another caller can publish.
  const sh = (cmd, argv) => execFileSync(cmd, argv, { cwd: o['repo-root'], encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
    stdio: (cmd === 'bash' && argv[0] === monitor) || (cmd === 'gh' && argv.includes('-F'))
      ? ['pipe', 'pipe', 'pipe', 'ignore', 'ignore', 'ignore', 'ignore', 'ignore', 'ignore', 9]
      : ['pipe', 'pipe', 'pipe'] }).trim();
  const monitor = join(assetDir, '../../orchestrate/assets/dev-flow-monitor.sh');
  const validator = join(assetDir, '../../dev-flow-support/assets/validate-result-schemas.mjs');
  const marker = read(o['marker-file']);
  const stages = ['kickoff', 'claim', 'explore', 'plan', 'implement', 'verify', 'challenge', 'review', 'security', 'integration'];
  if (!marker || typeof marker !== 'object' || Array.isArray(marker)
      || canon(Object.keys(marker).sort()) !== canon(['destination', 'round', 'run_id', 'sequence', 'stage'])
      || typeof marker.run_id !== 'string' || !/^[A-Za-z0-9._-]+$/.test(marker.run_id)
      || ['.', '..'].includes(marker.run_id) || !stages.includes(marker.stage)
      || marker.destination !== 'issue' || !Number.isSafeInteger(marker.round) || marker.round < 1
      || marker.sequence !== 1) fail('marker grammar: expected one issue round, positive round, sequence 1 and exactly five fields');
  // This helper publishes a single round comment. Oversized/split projections
  // remain a caller-side projection operation, never a partial registration.
  const markerLine = `<!-- dev-flow-v2-evidence: ${JSON.stringify({ run_id: marker.run_id, stage: marker.stage, round: marker.round, sequence: marker.sequence, destination: marker.destination })} -->`;
  if (!/^[^/\s]+\/[^/\s]+$/.test(o.repo) || !/^[0-9a-f]{40}$/.test(o.head)
      || !/^[1-9][0-9]*$/.test(o['actor-id']) || !Number.isSafeInteger(Number(o['actor-id']))
      || !/^[1-9][0-9]*$/.test(o.issue)) fail('invalid repository, head, actor or issue');
  const runPath = realpathSync(o.run);
  const state = sh('bash', [monitor, 'state-path', '--repo-root', o['repo-root'], '--run-id', marker.run_id]);
  if (runPath !== join(dirname(state), 'run.json')) fail('run path is not canonical for the monitor');
  const adjDir = join(dirname(runPath), 'adjudications');
  const adjudications = readdirSync(adjDir).filter((f) => f.endsWith('.json')).sort().flatMap((f) => ['--adjudication', join(adjDir, f)]);
  const validate = (file) => sh('node', [validator, 'run', file, '--receipts', file, ...adjudications]);
  validate(runPath);
  let run = read(runPath);
  if (run.run_id !== marker.run_id || !run.stage_transitions.some((t) => t.stage === marker.stage)) fail('marker is not bound to run stage');
  const event = `evidence-${marker.destination}-${marker.stage}-r${marker.round}-s${marker.sequence}`;
  const persistedFile = join(dirname(state), `${event}.body.md`);
  let persistedBody;
  let reserved = false;
  try { reserved = read(state).actions.some((action) => action.event === event); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  // An orphan body has no reservation authority, including a torn write.
  if (reserved) {
    try { persistedBody = readFileSync(persistedFile, 'utf8'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
  } else {
    rmSync(persistedFile, { force: true });
  }
  const suppliedBody = o['body-file'] ? `${markerLine}\n\n${readFileSync(o['body-file'], 'utf8')}` : undefined;
  if (persistedBody !== undefined && suppliedBody !== undefined && persistedBody !== suppliedBody) fail('caller body differs from persisted reserved body');
  const body = persistedBody ?? suppliedBody;
  if (body === undefined) fail('body-file is required for a new publication');
  if (!body.startsWith(`${markerLine}\n\n`)) fail('persisted body does not bind the canonical marker');
  const summary = body.slice(markerLine.length + 2);
  const fences = [...summary.matchAll(/```json\r?\n([\s\S]*?)\r?\n```/g)];
  if (fences.length !== 1 || summary.includes('dev-flow-v2-evidence:')) fail('body must contain exactly one fenced JSON projection and no evidence marker');
  const payload = fences[0][1];
  const projection = JSON.parse(payload);
  if (projection.run_id !== marker.run_id || projection.stage !== marker.stage || projection.round !== marker.round || projection.reviewed_head !== o.head) fail('projection does not bind marker and reviewed head');
  // Caller contract; the harvester authenticates the whole body and reads
  // retained local evidence rather than parsing this current-grammar fence.
  if (!Array.isArray(projection.passes) || !projection.passes.every((pass) => Array.isArray(pass?.payload?.findings))) fail('projection requires passes with payload.findings arrays');
  if (Buffer.byteLength(body, 'utf8') > 60000) fail('comment exceeds single-segment budget; split the projection before publication');
  const origin = sh('git', ['remote', 'get-url', 'origin']);
  const repoURL = sh('gh', ['repo', 'view', origin, '--json', 'url', '-q', '.url']);
  if (repoURL.toLowerCase() !== `https://github.com/${o.repo}`.toLowerCase()) fail('repository does not match origin');
  const actor = JSON.parse(sh('gh', ['api', 'user']));
  if (actor.id !== Number(o['actor-id'])) fail('authenticated actor does not match requested actor');
  const common = ['--active-state', o['active-state'], '--run-id', marker.run_id, '--branch', o.branch, '--generation', o.generation, '--repo-root', o['repo-root']];
  const digest = sha(body);
  sh('bash', [monitor, 'reserve', '--state', state, '--event', event, '--action', 'comment', '--expected-head', o.head, '--writer', 'feature-owner', ...common, '--trusted-actor-id', o['actor-id'], '--evidence-role', o.role, '--evidence-finder', o.finder, '--marker', markerLine, '--payload-digest', digest,
    '--destination-repo', o.repo, '--destination-issue', o.issue, '--comment-lock-fd', '9']);
  // Only a successful reservation makes these bytes authoritative. Publish
  // the complete copy atomically before any external POST can begin.
  if (persistedBody === undefined) {
    const candidate = `${persistedFile}.candidate-${process.pid}`;
    try {
      writeFileSync(candidate, body, { flag: 'wx', mode: 0o600 });
      renameSync(candidate, persistedFile);
    } finally { rmSync(candidate, { force: true }); }
  }
  const scratch = mkdtempSync(join(realpathSync(o['scratch-dir']), 'post-evidence-'));
  try {
    const bodyFile = join(scratch, 'body.md');
    const observed = join(scratch, 'observed.json');
    writeFileSync(bodyFile, body);
    const endpoint = `repos/${o.repo}/issues/${o.issue}/comments`;
    const fetchCandidates = () => {
      // Bound the complete destination read to 1000 comments. A full tenth
      // page is indeterminate, never permission to post from a partial set.
      const comments = [];
      for (let page = 1; page <= 10; page++) {
        const batch = JSON.parse(sh('gh', ['api', `${endpoint}?per_page=100&page=${page}`]));
        if (!Array.isArray(batch)) fail('comment fetch did not return an array');
        comments.push(...batch);
        if (batch.length < 100) return comments;
      }
      fail('candidate set exceeds bounded destination read');
    };
    const reconcile = (comments) => {
      const candidates = comments.filter((c) => typeof c.body === 'string' && c.body.split(/\r?\n/, 1)[0] === markerLine)
        .map((c) => ({ comment_id: c.id, actor_id: c.user.id, run_id: marker.run_id, head: o.head, role: o.role, finder: o.finder, marker: markerLine, payload_digest: sha(c.body), body: c.body }));
      const matched = candidates.some((c) => c.actor_id === actor.id);
      if (candidates.some((c) => c.actor_id !== actor.id)) process.stderr.write('post-evidence: untrusted matching marker ignored\n');
      writeFileSync(observed, JSON.stringify({ status: matched ? 'landed' : 'absent', event, action: 'comment', head: o.head, comments: candidates }));
      return sh('bash', [monitor, 'reconcile', '--state', state, '--event', event, '--observed', observed, ...common]);
    };
    let comments = fetchCandidates();
    let decision = reconcile(comments);
    if (decision === `retry ${event}`) {
      // On an ambiguous POST failure, stop; a re-arm fetches and adopts it.
      sh('gh', ['api', endpoint, '-F', `body=@${bodyFile}`]);
      comments = fetchCandidates();
      decision = reconcile(comments);
    }
    if (decision !== `adopt ${event}`) fail(`comment not adopted: ${decision}`);
    const action = read(state).actions.find((a) => a.event === event);
    const id = action?.postcondition?.comment_id;
    const comment = comments.find((c) => String(c.id) === id);
    if (!comment || comment.user.id !== actor.id || comment.body !== body) fail('adopted comment readback conflicts with reservation');
    // Current-grammar evidence authentication covers the exact posted body,
    // including its marker, prose and fenced JSON.
    const payloadDigest = `sha256:${sha(comment.body)}`;
    validate(runPath);
    const before = readFileSync(runPath, 'utf8');
    run = JSON.parse(before);
    const existing = run.evidence_comments.filter((c) => c.id === id || canon(c.marker) === canon(marker));
    if (existing.length) {
      if (existing.length !== 1 || existing[0].id !== id || existing[0].author_actor_id !== actor.id || existing[0].digest !== payloadDigest || canon(existing[0].marker) !== canon(marker)) fail('registration identity conflicts with adopted comment');
      // Login is display metadata: do not mutate the immutable chain on rename.
    } else {
      const prev = run.evidence_registrations.at(-1)?.digest ?? 'genesis';
      const content = { id, author_actor_id: actor.id, login: comment.user.login, payload_digest: payloadDigest, marker, registered_at: new Date().toISOString() };
      run.evidence_registrations.push({ seq: run.evidence_registrations.length, prev_digest: prev, digest: sha(canon({ ...content, prev_digest: prev })), ...content });
      run.evidence_comments.push({ id, author_actor_id: actor.id, login: content.login, digest: payloadDigest, marker });
      const candidate = `${runPath}.candidate-${process.pid}`;
      try {
        writeFileSync(candidate, `${JSON.stringify(run, null, 2)}\n`, { flag: 'wx' });
        validate(candidate);
        if (readFileSync(runPath, 'utf8') !== before) fail('run record changed during registration');
        renameSync(candidate, runPath);
      } finally { rmSync(candidate, { force: true }); }
    }
    validate(runPath);
    process.stdout.write(`${id}\n`);
  } finally { rmSync(scratch, { recursive: true, force: true }); }
} catch (error) {
  process.stderr.write(`post-evidence: ${error.message}\n`);
  process.exitCode = 2;
}
JS
