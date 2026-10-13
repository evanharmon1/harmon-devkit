#!/usr/bin/env bash
# test-inline-record.sh — behavioural test for the inline confidence-stage
# path's dev-flow-v2 run record (harmon-devkit#1183, the #973 decision).
#
# An interactive session with no orchestrator brief reserves a solo run with
# `run-record.mjs solo-init`, receipts each pass and adjudication through
# `run-record.mjs receipt|adjudicate`, materializes the exit engine's evidence
# with `run-record.mjs ledger`, advances with `transition`, publishes each
# round's evidence marker through review's `post-evidence.sh`, and ends the run
# with `promote` or `close` plus `lock release`. The consumers read that
# record unchanged: the exit engine, the readiness-input projection
# `/integrate`'s gate reads, and `/retro`'s retro-run-report.mjs, which must
# discover the trusted marker and render `## Run evidence`.
#
# Hermetic and offline: a scratch repository, the REAL writers, validator,
# monitor, exit engine, renderer, harvester and report, and a fake `gh` and
# `gitleaks` on PATH. The passes are what a challenger/reviewer role agent (or
# the session acting as that role) assembles from `task challenge` /
# `task review` output, so no model runs here.
# Run via `task test:inline-record`.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
command -v node >/dev/null 2>&1 || {
    echo "TEST FAIL: node is required" >&2
    exit 1
}
test_tmp="$(mktemp -d)"
trap 'chmod -R u+w "$test_tmp" 2>/dev/null || true; rm -rf "$test_tmp"' EXIT
node --input-type=module - "$repo_root" "$test_tmp" <<'JS'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdirSync, chmodSync, cpSync, existsSync, readdirSync } from 'node:fs'
import { execFileSync, spawnSync } from 'node:child_process'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const [source, tmp] = process.argv.slice(2)
const support = join(source, 'ai/skills/universal/dev-flow-support/assets')
const runRecord = join(support, 'run-record.mjs')
const read = (p) => JSON.parse(readFileSync(p, 'utf8'))
const put = (p, v) => writeFileSync(p, `${JSON.stringify(v, null, 2)}\n`)
const pass = (message) => console.log(`PASS: ${message}`)

const env = { ...process.env, GIT_CONFIG_GLOBAL: join(tmp, 'gitconfig'), GIT_CONFIG_NOSYSTEM: '1' }
delete env.GIT_CONFIG_COUNT
delete env.GIT_CONFIG_PARAMETERS
for (const key of Object.keys(env)) if (/^GIT_CONFIG_(KEY|VALUE)_/.test(key)) delete env[key]
const repo = join(tmp, 'repo')
const sh = (cmd, args, opts = {}) => execFileSync(cmd, args, { cwd: repo, env, encoding: 'utf8', ...opts }).trim()
const run = (cmd, args) => spawnSync(cmd, args, { cwd: repo, env, encoding: 'utf8' })
const commitAll = (message) => {
  sh('git', ['add', '.'])
  sh('git', ['commit', '-q', '-m', message])
  return sh('git', ['rev-parse', 'HEAD'])
}

// ---------------------------------------------------------------------------
// A scratch consumer: the real policy, registry and gitleaks config, a
// feature branch with one commit, and origin/HEAD pointing at main.
// ---------------------------------------------------------------------------
mkdirSync(repo)
sh('git', ['init', '-q', '-b', 'main', repo])
sh('git', ['config', 'user.name', 'Test'])
sh('git', ['config', 'user.email', 'test@example.invalid'])
sh('git', ['config', 'commit.gpgsign', 'false'])
const ACTOR = 12345
const registry = read(join(source, 'agent-registry.json'))
registry.trusted_orchestrator_actor_ids = [ACTOR]
put(join(repo, 'agent-registry.json'), registry)
cpSync(join(source, '.devflow.toml'), join(repo, '.devflow.toml'))
cpSync(join(source, '.gitleaks.toml'), join(repo, '.gitleaks.toml'))
const base = commitAll('chore: initial')
sh('git', ['remote', 'add', 'origin', 'https://github.com/example/repo'])
sh('git', ['update-ref', 'refs/remotes/origin/main', base])
sh('git', ['symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main'])
const BRANCH = '1-solo'
sh('git', ['switch', '-q', '-c', BRANCH])
writeFileSync(join(repo, 'change.txt'), 'the change under review\n')
const head = commitAll('feat: a change')
const policyFile = join(tmp, 'policy.json')
// Exit 3 is "resolved, but the gate slugs were not cross-checked": this
// scratch repository has no Taskfile, which the record does not depend on.
const resolved = spawnSync('node', [join(support, 'devflow-policy.mjs'), 'resolve', '--policy', '.devflow.toml', '--registry', 'agent-registry.json', '--json'], { cwd: repo, env, encoding: 'utf8' })
assert.ok([0, 3].includes(resolved.status), resolved.stderr)
writeFileSync(policyFile, resolved.stdout)
const policy = read(policyFile)
const common = sh('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'])
const state = join(common, 'dev-flow-v2')
const runsDir = join(state, 'runs')
const SESSION = 'solo-session'
const PIN = 'implementer: fixture pin (operator)'

const soloArgs = ({ runId, issue, branch, session = SESSION, actor = ACTOR }) => ['solo-init', '--session', session,
  '--run-id', runId, '--issue', String(issue), '--title', 'A change', '--url', `https://github.com/example/repo/issues/${issue}`,
  '--branch', branch, '--base', base, '--policy', policyFile, '--actor-id', String(actor),
  '--strategy-source', 'default_strategy', '--operator-pin', PIN]
// Nothing a refused reservation could have created is left behind.
const nothingWritten = (runId) =>
  !existsSync(join(state, 'locks', `solo-${runId}.json`)) && !existsSync(join(state, 'slates', `solo-${runId}`)) &&
  !existsSync(join(runsDir, runId))

// ---------------------------------------------------------------------------
// 1. solo-init: every refusable precondition before the first write.
// ---------------------------------------------------------------------------
const RUN = 'run-1-solo'
const initArgs = soloArgs({ runId: RUN, issue: 1, branch: BRANCH })
let r = run('node', [runRecord, ...initArgs.map((a) => (a === RUN ? 'run-2-solo' : a))])
assert.equal(r.status, 2, r.stderr)
assert.match(r.stderr, /canonical run-1-<name>/)
r = run('node', [runRecord, ...initArgs.map((a) => (a === policyFile ? join(tmp, 'missing.json') : a))])
assert.equal(r.status, 1, r.stderr)
assert.match(r.stderr, /^refused: --policy not found/m)
r = run('node', [runRecord, ...soloArgs({ runId: RUN, issue: 1, branch: BRANCH, actor: 999 })])
assert.equal(r.status, 1, r.stderr)
assert.match(r.stderr, /actor 999 is not in agent-registry.json's trusted_orchestrator_actor_ids/)
sh('git', ['symbolic-ref', '--delete', 'refs/remotes/origin/HEAD'])
r = run('node', [runRecord, ...initArgs])
sh('git', ['symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main'])
assert.equal(r.status, 1, r.stderr)
assert.match(r.stderr, /refs\/remotes\/origin\/HEAD is unset/)
assert.equal(existsSync(state), false)
pass('solo-init refuses a non-canonical id, an unreadable policy, an untrusted actor or an unresolvable default branch before writing anything')

r = run('node', [runRecord, ...initArgs])
assert.equal(r.status, 0, r.stderr)
const identity = JSON.parse(r.stdout)
const record = identity.record_directory
const runJson = join(record, 'run.json')
assert.equal(identity.run_id, RUN)
assert.equal(identity.slate_id, `solo-${RUN}`)
assert.equal(identity.generation, 1)
assert.equal(identity.active_state_path, sh('bash', [join(source, 'ai/skills/universal/orchestrate/assets/dev-flow-monitor.sh'), 'active-path', '--branch', BRANCH, '--repo-root', repo]))
const pointer = read(identity.active_state_path)
assert.deepEqual([pointer.run_id, pointer.branch, pointer.generation], [RUN, BRANCH, 1])
assert.deepEqual(read(identity.policy_projection), { ...policy, rigor: { ...policy.rigor, source: 'default_rigor' } })
let runDoc = read(runJson)
assert.equal(runDoc.initiated_by, 'human')
assert.equal(runDoc.stage_transitions.length, 1)
assert.match(runDoc.stage_transitions[0].exit, /^resolved: rigor standard \(default_rigor\), strategy plan \(default_strategy\)/)
const planFile = join(state, 'slates', `solo-${RUN}`, 'plan.json')
sh('node', [join(support, 'validate-result-schemas.mjs'), 'run', runJson, '--receipts', runJson, '--no-adjudications'])
sh('node', [join(support, 'validate-result-schemas.mjs'), 'plan', planFile])
const plannedPolicy = read(planFile).revisions[0].plan.policy
assert.equal(plannedPolicy.strategy_source, 'default_strategy')
assert.deepEqual(plannedPolicy.operator_pins, [PIN])
assert.equal(read(join(state, 'locks', `solo-${RUN}.json`)).session, SESSION)
pass('solo-init writes a schema-valid kickoff run.json, policy.json, single-lane plan (operator strategy source and pins), slate lock and active pointer')

const before = readFileSync(runJson, 'utf8')
r = run('node', [runRecord, ...initArgs])
assert.equal(r.status, 0, r.stderr)
assert.equal(JSON.parse(r.stdout).generation, 1)
assert.equal(readFileSync(runJson, 'utf8'), before)
pass('solo-init re-arms idempotently: same generation, run.json untouched')

r = run('node', [runRecord, ...soloArgs({ runId: 'run-1-other', issue: 1, branch: BRANCH })])
assert.equal(r.status, 1)
assert.match(r.stderr, /already has live active run run-1-solo/)
assert.ok(nothingWritten('run-1-other'))
r = run('node', [runRecord, ...soloArgs({ runId: 'run-1-elsewhere', issue: 1, branch: '1-elsewhere', session: 'another-session' })])
assert.equal(r.status, 1)
assert.match(r.stderr, /issue\(s\) 1 are already locked by session solo-session/)
assert.ok(nothingWritten('run-1-elsewhere'))
pass('solo-init refuses a branch whose run is still live, and an issue another session holds, writing nothing')

if (process.getuid?.() !== 0) {
  // A failure after the writes began (here: activation, against an
  // unwritable pointer directory) undoes everything this call created.
  chmodSync(join(state, 'active'), 0o555)
  r = run('node', [runRecord, ...soloArgs({ runId: 'run-5-rollback', issue: 5, branch: '5-rollback' })])
  chmodSync(join(state, 'active'), 0o755)
  assert.equal(r.status, 1, r.stderr)
  assert.match(r.stderr, /activation refused/)
  assert.ok(nothingWritten('run-5-rollback'), readdirSync(state).join(','))
  pass('solo-init rolls back its lock, plan, owner binding, policy.json, run.json and branch binding when activation fails')
}

// ---------------------------------------------------------------------------
// 2. The inline stages, through the existing writer plus receipt/adjudicate.
// ---------------------------------------------------------------------------
const writer = (slateArgs) => (...args) => {
  const out = run('node', [runRecord, args[0], ...slateArgs, ...args.slice(1)])
  assert.equal(out.status, 0, `${args.join(' ')}: ${out.stderr}`)
  return out.stdout
}
const refused = (slateArgs, args, pattern) => {
  const out = run('node', [runRecord, args[0], ...slateArgs, ...args.slice(1)])
  assert.equal(out.status, 1, `${args.join(' ')} was not refused: ${out.stdout}${out.stderr}`)
  assert.match(out.stderr, pattern)
}
const slateArgs = ['--slate', identity.slate_id, '--session', SESSION, '--run-id', RUN]
const write = writer(slateArgs)
write('transition', '--stage', 'claim')
write('transition', '--stage', 'implement', '--exit', 'claimed by this session')
write('transition', '--stage', 'verify', '--exit', `committed ${head}`)
write('transition', '--stage', 'challenge', '--exit', 'task verify VERIFY-EXIT=0')

const scratch = join(tmp, 'scratch')
mkdirSync(scratch)
const now = () => new Date().toISOString().replace(/\.[0-9]{3}Z$/, 'Z')
const envelope = (role, stage, round, finder, findings, { runId = RUN, reviewed = head, ...overrides } = {}) => JSON.parse(JSON.stringify({
  schema: 2,
  role,
  status: 'completed',
  head: reviewed,
  produced_at: now(),
  producer: { harness: 'claude-code', model: 'claude-opus-5-5', tier: 'frontier' },
  run: { run_id: runId, initiated_by: 'human' },
  payload: {
    stage,
    round,
    reviewed_head: reviewed,
    finder,
    slot: finder,
    findings,
    counts: ['P0', 'P1', 'P2', 'P3'].reduce((c, p) => ({ ...c, [p]: findings.filter((f) => f.priority === p).length }), {}),
    attack_scenarios: role === 'challenger' ? [{ id: 'as-1', description: 'tried to break the change', outcome: 'held', finding_id: null }] : undefined,
  },
  ...overrides,
}))
const passFile = (name, value) => {
  const file = join(scratch, `${name}.json`)
  put(file, value)
  return file
}
const challengeFinder = policy.stages.challenge.finders[0]
const reviewFinder = policy.stages.review.finders[0]
const challengePass = passFile('challenge-r1', envelope('challenger', 'challenge', 1, challengeFinder, []))

// The receipt invariant: a completed pass for a configured slot of the
// active stage's next unadjudicated round, of the branch head, produced
// within the stage's span. Each refusal publishes nothing.
const inadmissible = [
  ['wrong stage', envelope('reviewer', 'review', 1, reviewFinder, []), /the run's active stage is challenge/],
  ['blocked', envelope('challenger', 'challenge', 1, challengeFinder, [], { status: 'blocked' }), /status is "blocked"/],
  ['unconfigured slot', envelope('challenger', 'challenge', 1, 'not-a-finder', []), /slot not-a-finder is not a configured challenge finder/],
  ['skipped round', envelope('challenger', 'challenge', 2, challengeFinder, []), /next unadjudicated challenge round is 1/],
  ['foreign head', envelope('challenger', 'challenge', 1, challengeFinder, [], { reviewed: base }), /reviewed [0-9a-f]{40}, not 1-solo's head/],
  ['future', envelope('challenger', 'challenge', 1, challengeFinder, [], { produced_at: '2999-01-01T00:00:00Z' }), /outside the stage's span/],
  ['stale', envelope('challenger', 'challenge', 1, challengeFinder, [], { produced_at: '2026-01-01T00:00:00Z' }), /outside the stage's span/],
]
for (const [name, value, pattern] of inadmissible) {
  refused(slateArgs, ['receipt', '--pass', passFile(`bad-${name.replace(/ /g, '-')}`, value)], new RegExp(`is not admissible: .*${pattern.source}`))
}
refused(slateArgs, ['receipt', '--pass', passFile('foreign-run', envelope('challenger', 'challenge', 1, challengeFinder, [], { runId: 'run-9-other' }))], /failed receipt validation/)
assert.equal(existsSync(join(record, 'passes')), false)
assert.deepEqual(read(runJson).receipts.filter((x) => x.kind === 'pass'), [])
pass('receipt refuses a pass for another stage, a blocked one, an unconfigured slot, a skipped round, a foreign head, a future or stale one, or another run, publishing nothing')

assert.match(write('receipt', '--pass', challengePass), /recorded pass receipt challenge-r1-/)
assert.equal(readFileSync(join(record, 'passes', `challenge-r1-${challengeFinder}.json`), 'utf8'), readFileSync(challengePass, 'utf8'))
assert.match(write('receipt', '--pass', challengePass), /no change/)
refused(slateArgs, ['receipt', '--pass', passFile('altered', envelope('challenger', 'challenge', 1, challengeFinder, [], { producer: { harness: 'codex-cli', model: 'other', tier: 'frontier' } }))], /immutable/)
assert.deepEqual(read(runJson).receipts.filter((x) => x.kind === 'pass'), [{ kind: 'pass', file: `challenge-r1-${challengeFinder}` }])
pass('receipt publishes the pass no-clobber and appends exactly one receipt; a re-receipt is a no-op, a changed one refused')

const adjudication = (stage, round, entries, { runId = RUN, reviewed = head } = {}) => ({ schema: 2, run_id: runId, stage, round, reviewed_head: reviewed, adjudications: entries })
const adjFile = (name, value) => {
  const file = join(scratch, `${name}.adj.json`)
  put(file, value)
  return file
}
refused(slateArgs, ['adjudicate', '--file', adjFile('challenge-r2-early', adjudication('challenge', 2, []))], /no receipted pass/)

// The confidence-stage exit, exactly as /review computes it: the change
// ledger and head map materialized by the writer, a verification-only call
// before adjudication, the final call after it, persisted as verdict.json.
const exitEngine = join(support, 'dev-flow-exit.sh')
const exitFor = (slate, rec, stage, current, verificationOnly) => {
  writer(slate)('ledger', '--stage', stage)
  const out = run('bash', [exitEngine, '--run', rec, '--stage', stage, '--policy', join(repo, '.devflow.toml'), '--current-head', current,
    '--history', join(rec, 'history.json'), '--heads', join(rec, 'heads.json'), '--repo-root', repo, '--json',
    ...(verificationOnly ? ['--verification-only'] : [])])
  const json = out.stdout ? JSON.parse(out.stdout) : null
  if (json !== null) put(join(rec, verificationOnly ? 'verification.json' : 'verdict.json'), json)
  return { status: out.status, json, stderr: out.stderr }
}
const adjudicateRound = (slate, rec, stage, round, current, doc) => {
  const verification = exitFor(slate, rec, stage, current, true)
  assert.equal(verification.json?.action, 'adjudicate', JSON.stringify(verification.json) + verification.stderr)
  writer(slate)('adjudicate', '--file', adjFile(`${rec.split('/').at(-1)}-${stage}-r${round}`, doc))
  const verdict = exitFor(slate, rec, stage, current, false)
  put(join(rec, `verdict-${stage}-r${round}.json`), verdict.json)
  return { verification: verification.json, ...verdict }
}
let v = adjudicateRound(slateArgs, record, 'challenge', 1, head, adjudication('challenge', 1, []))
assert.equal(v.status, 20, JSON.stringify(v.json) + v.stderr)
assert.equal(v.json.outcome, 'converged')
assert.deepEqual(read(join(record, 'verdict.json')), v.json)
assert.deepEqual(read(join(record, 'history.json')), [])
assert.equal(read(join(record, 'heads.json'))[head].parent, base)
assert.match(write('adjudicate', '--file', adjFile(`${RUN}-challenge-r1`, adjudication('challenge', 1, []))), /no change/)
refused(slateArgs, ['receipt', '--pass', passFile('challenge-r1-again', envelope('challenger', 'challenge', 1, challengeFinder, [], { producer: { harness: 'codex-cli', model: 'again', tier: 'frontier' } }))], /immutable/)
pass('adjudicate publishes once; ledger + verification-only + final exit converge the inline challenge stage (empty round) and persist verdict.json')

// ---------------------------------------------------------------------------
// 3. Evidence: each adjudicated round is published through review's own
//    post-evidence.sh against a fake GitHub, and registered in run.json.
// ---------------------------------------------------------------------------
const bin = join(tmp, 'bin')
mkdirSync(bin)
const db = join(tmp, 'github.json')
env.INLINE_GH_DB = db
env.PATH = `${bin}:${env.PATH}`
const ISSUE = 1
const PR = 2
const SKIP_ISSUE = 6
const SKIP_PR = 7
const prFixture = (number, issue) => ({ number, url: `https://github.com/example/repo/pull/${number}`, title: 'feat: a change',
  state: 'OPEN', isDraft: true, body: `Closes #${issue}\n`, closingIssuesReferences: [{ number: issue }] })
put(db, {
  login: 'solo-writer',
  actor: ACTOR,
  next_id: 100,
  comments: {},
  prs: { [PR]: prFixture(PR, ISSUE), [SKIP_PR]: prFixture(SKIP_PR, SKIP_ISSUE) },
  registry: Buffer.from(JSON.stringify(registry)).toString('base64'),
  base,
})
writeFileSync(join(bin, 'gh'), `#!/usr/bin/env node
const fs = require('node:fs')
const p = process.env.INLINE_GH_DB
const d = JSON.parse(fs.readFileSync(p, 'utf8'))
const a = process.argv.slice(2)
const out = (v) => { process.stdout.write(JSON.stringify(v) + '\\n'); process.exit(0) }
const slurp = a.includes('--slurp')
const page = (v) => out(slurp ? [v] : v)
if (a[0] === 'repo' && a[1] === 'view') { process.stdout.write('https://github.com/example/repo\\n'); process.exit(0) }
if (a[0] === 'pr' && a[1] === 'view') {
  if (!d.prs[a[2]]) { process.stderr.write('HTTP 404\\n'); process.exit(1) }
  out(d.prs[a[2]])
}
if (a[0] !== 'api') { process.stderr.write('fake gh: unsupported ' + a.join(' ') + '\\n'); process.exit(1) }
if (a[1] === 'user') out({ id: d.actor, login: d.login })
const endpoint = a.find((x) => x.startsWith('repos/')) || ''
const path = endpoint.split('?')[0]
let m
if ((m = /^repos\\/example\\/repo\\/issues\\/([0-9]+)\\/comments$/.exec(path))) {
  const n = m[1]
  if (a.includes('-F')) {
    const body = fs.readFileSync(a[a.indexOf('-F') + 1].slice('body=@'.length), 'utf8')
    const comment = { id: d.next_id++, user: { id: d.actor, login: d.login }, body, created_at: new Date().toISOString(), updated_at: new Date().toISOString() }
    ;(d.comments[n] = d.comments[n] || []).push(comment)
    fs.writeFileSync(p, JSON.stringify(d))
    out(comment)
  }
  const pageNo = Number(new URLSearchParams(endpoint.split('?')[1] || '').get('page') || '1')
  page(pageNo === 1 ? (d.comments[n] || []) : [])
}
if ((m = /^repos\\/example\\/repo\\/issues\\/([0-9]+)$/.exec(path))) {
  out(d.prs[m[1]] ? { number: Number(m[1]), pull_request: {} } : { number: Number(m[1]) })
}
if (path === 'repos/example/repo') out({ default_branch: 'main' })
if (path === 'repos/example/repo/commits' && endpoint.includes('path=agent-registry.json')) page([{ sha: d.base }])
// The registry revision landed on main through a merged PR before the run,
// so the trust history governs every evidence comment the run writes.
if (/^repos\\/example\\/repo\\/commits\\/[0-9a-f]+\\/pulls$/.test(path)) page([{ number: 1000, merged_at: '2026-01-01T00:00:00Z', base: { ref: 'main', repo: { full_name: 'example/repo' } } }])
if (path === 'repos/example/repo/contents/agent-registry.json') out({ type: 'file', encoding: 'base64', sha: 'a'.repeat(40), content: d.registry })
page([])
`)
chmodSync(join(bin, 'gh'), 0o755)
// post-evidence.sh scans with `gitleaks stdin`; the renderer with `detect
// --report-format json`, which answers an empty finding list.
writeFileSync(join(bin, 'gitleaks'), '#!/usr/bin/env bash\ncat >/dev/null\n[ "$1" != detect ] || echo "[]"\nexit 0\n')
chmodSync(join(bin, 'gitleaks'), 0o755)

const render = join(support, 'render-dev-flow.sh')
const postEvidence = join(source, 'ai/skills/universal/review/assets/post-evidence.sh')
const publishFor = ({ ident, branch, issue }) => (stage, round, role, finder) => {
  const rec = ident.record_directory
  const pass = read(join(rec, 'passes', `${stage}-r${round}-${finder}.json`))
  const verdictFile = join(rec, `verdict-${stage}-r${round}.json`)
  const table = sh('bash', [render, 'round-table', '--record', rec, '--stage', stage, '--round', String(round), '--verdict', verdictFile])
  const projection = {
    run_id: ident.run_id, stage, round, reviewed_head: pass.head,
    passes: [pass],
    adjudication: read(join(rec, 'adjudications', `${stage}-r${round}.json`)).adjudications,
    exit: read(verdictFile),
  }
  const bodyFile = join(scratch, `${ident.run_id}-${stage}-r${round}.md`)
  const markerFile = join(scratch, `${ident.run_id}-${stage}-r${round}.marker.json`)
  writeFileSync(bodyFile, `**Dev flow v2 — ${stage} round ${round}** · run \`${ident.run_id}\` (solo, inline path)\n\n${table}\n\n\`\`\`json\n${JSON.stringify(projection, null, 2)}\n\`\`\`\n`)
  put(markerFile, { run_id: ident.run_id, stage, round, sequence: 1, destination: 'issue' })
  const out = run('bash', [postEvidence, '--repo', 'example/repo', '--repo-root', repo, '--run', join(rec, 'run.json'), '--branch', branch,
    '--generation', String(ident.generation), '--active-state', ident.active_state_path, '--head', pass.head,
    '--actor-id', String(ACTOR), '--role', role, '--finder', finder, '--issue', String(issue),
    '--marker-file', markerFile, '--body-file', bodyFile, '--scratch-dir', scratch])
  assert.equal(out.status, 0, out.stderr)
  return out.stdout.trim()
}
const publish = publishFor({ ident: identity, branch: BRANCH, issue: ISSUE })
const challengeComment = publish('challenge', 1, 'challenger', challengeFinder)
runDoc = read(runJson)
assert.equal(runDoc.evidence_comments.length, 1)
assert.equal(runDoc.evidence_comments[0].id, challengeComment)
assert.ok(read(db).comments[ISSUE][0].body.startsWith(`<!-- dev-flow-v2-evidence: {"run_id":"${RUN}","stage":"challenge","round":1,`))
pass('the inline challenge round is published through post-evidence.sh and registered in run.json')

// Advance exactly as /review's stage-advance write does, then run review.
write('transition', '--stage', 'review', '--exit', 'converged: empty_round after challenge round 1/' + policy.rounds.challenge)
const reviewFinding = {
  id: `review-r1-${reviewFinder}-1`, path: 'change.txt', line: 1, class: 'hardening', provenance: 'original',
  fingerprint: 'new', priority: 'P2', recommended_disposition: 'defer', evidence: 'the change has no test',
}
write('receipt', '--pass', passFile('review-r1', envelope('reviewer', 'review', 1, reviewFinder, [reviewFinding])))
refused(slateArgs, ['adjudicate', '--file', adjFile('review-r1-bad', adjudication('review', 1, []))], /failed receipt validation/)
assert.equal(existsSync(join(record, 'adjudications', 'review-r1.json')), false)
pass('adjudicate refuses a document that leaves a receipted finding unadjudicated, publishing nothing')
v = adjudicateRound(slateArgs, record, 'review', 1, head, adjudication('review', 1, [{
  finding_id: reviewFinding.id, reviewer_priority: 'P2', adjudicated_priority: 'P2', disposition: 'defer',
  reason: 'worth a test, not merge-blocking', evidence: 'change.txt:1 is a fixture', override: null,
}]))
assert.equal(v.json.outcome, 'continue', JSON.stringify(v.json))
const verified = v.verification.rounds.find((round) => round.round === 1).findings[0]
assert.deepEqual([verified.provenance_status, verified.fingerprint_status], ['verified', 'verified'])
publish('review', 1, 'reviewer', reviewFinder)
write('receipt', '--pass', passFile('review-r2', envelope('reviewer', 'review', 2, reviewFinder, [])))
v = adjudicateRound(slateArgs, record, 'review', 2, head, adjudication('review', 2, []))
assert.equal(v.status, 20, JSON.stringify(v.json))
publish('review', 2, 'reviewer', reviewFinder)
assert.equal(read(runJson).evidence_comments.length, 3)
pass('review continues on a P2-only round (its provenance and fingerprint verified against the ledger) and converges on the empty round 2; every round carries its marker')

write('intervention', '--kind', 'asked', '--note', 'maintainer confirmed deferring the P2 to integration')
write('transition', '--stage', 'security', '--exit', 'converged: empty_round after review round 2/' + policy.rounds.review)
write('transition', '--stage', 'integration', '--exit', 'task security SECURITY-EXIT=0; draft PR opened')
write('bind-pr', '--number', String(PR), '--url', `https://github.com/example/repo/pull/${PR}`)
sh('node', [join(support, 'validate-result-schemas.mjs'), 'run', runJson, '--receipts', runJson,
  ...readdirSync(join(record, 'adjudications')).flatMap((f) => ['--adjudication', join(record, 'adjudications', f)])])
pass('the solo record reaches integration bound to its PR and validates strictly with every adjudication')

// ---------------------------------------------------------------------------
// 4. Consumers read the record unchanged.
// ---------------------------------------------------------------------------
const readiness = JSON.parse(sh('bash', [render, 'readiness-input', '--record', record, '--head', head], { stdio: ['ignore', 'pipe', 'ignore'] }))
assert.equal(readiness.head, head)
assert.deepEqual(readiness.deferred_findings.unsettled.map((f) => f.finding_id), [reviewFinding.id])
pass("the readiness gate's readiness-input projection reads the solo record: the deferred P2 is open until settled")

// /implement publishes the policy disclosure into the draft PR body
// (render-dev-flow.sh publish); the report reads its caps from there.
const disclosure = sh('bash', [render, 'policy-disclosure', '--record', record], { stdio: ['ignore', 'pipe', 'ignore'] })
const github = read(db)
github.prs[PR].body = `Closes #${ISSUE}\n\n<!-- dev-flow:begin:policy-disclosure -->\n${disclosure}\n<!-- dev-flow:end:policy-disclosure -->\n`
put(db, github)
const retro = (pr, trusted) => run('node', [join(source, 'ai/skills/universal/retro/assets/retro-run-report.mjs'), '--repo', 'example/repo',
  '--pr', String(pr), '--trusted-actor-id', String(trusted), '--record-dir', runsDir])
const report = retro(PR, ACTOR)
assert.equal(report.status, 0, `${report.stdout}\n${report.stderr}`)
const section = (name) => report.stdout.split(/^### /m).find((s) => s.startsWith(name)) ?? ''
assert.match(report.stdout, new RegExp(`^## Run evidence — run \`${RUN}\``, 'm'))
assert.match(report.stdout, new RegExp(`evidence marker on issue #${ISSUE} \\(closing reference\\)`))
assert.match(section('Stage `challenge`'), new RegExp(`Rounds spent: 1 / cap ${policy.rounds.challenge} `))
assert.match(section('Stage `challenge`'), /Findings: 0 across 1 pass\(es\)/)
assert.match(section('Stage `review`'), new RegExp(`Rounds spent: 2 / cap ${policy.rounds.review} `))
assert.match(section('Stage `review`'), /Findings: 1 across 2 pass\(es\)/)
assert.match(section('Stage `review`'), /Round 1 evidence: 1 pass\(es\), 0 blocked pass\(es\), 1 adjudication\(s\)/)
// The harvester re-runs the exit engine without the run's ledger, so it
// discloses provenance as unavailable for exactly the round with a finding —
// stated, never silently substituted — while the record itself verifies it
// (section 2's verification projection above).
assert.match(section('Stage `review`'), /Verified provenance\/fingerprint unavailable for round\(s\): 1$/m)
assert.match(report.stdout, /Interventions during this stage: asked at [0-9T:-]+Z \(maintainer confirmed deferring the P2 to integration\)/)
assert.match(report.stdout, /Forged-author comments: 0/)
pass('retro-run-report.mjs discovers the trusted marker on the linked issue and renders ## Run evidence (exit 0): rounds against caps, findings per stage, provenance disclosure, the intervention')

const untrusted = retro(PR, 999)
assert.equal(untrusted.status, 11, `${untrusted.stdout}\n${untrusted.stderr}`)
pass('the same markers under a different trust set are indeterminate (exit 11), never a clean report')

const skipped = retro(SKIP_PR, ACTOR)
assert.equal(skipped.status, 10, `${skipped.stdout}\n${skipped.stderr}`)
assert.match(skipped.stderr, /no-run-record/)
assert.deepEqual(readdirSync(runsDir).filter((name) => name.startsWith(`run-${SKIP_ISSUE}-`)), [])
pass('a PR whose session skipped the confidence stages has no record: /retro reports exit 10 no-run-record, the ordinary no-evidence outcome')

// ---------------------------------------------------------------------------
// 5. End of life: promotion, and a run stopped at a blocker.
// ---------------------------------------------------------------------------
// /integrate settles the deferred P2 through the shared validated writer
// (integrate/SKILL.md), which promotion requires.
const settle = join(scratch, 'settle.mjs')
writeFileSync(settle, `import { readFileSync } from 'node:fs'
const [writer, runJson, finding, at] = process.argv.slice(2)
const { withMutex, writeValidated } = await import(writer)
withMutex(runJson, () => {
  const record = JSON.parse(readFileSync(runJson, 'utf8'))
  record.settlements.push({ finding_id: finding, disposition: 'file', settled_at: at, reference: { type: 'issue_number', value: '4242' } })
  writeValidated('run', runJson, record)
})
`)
sh('node', [settle, pathToFileURL(runRecord).href, runJson, reviewFinding.id, now()])
write('promote', '--head', head, '--fingerprint', 'fixture-fingerprint')
const releaseLock = (slateId) => sh('node', [runRecord, 'lock', 'release', '--slate', slateId, '--session', SESSION])
assert.match(releaseLock(identity.slate_id), /released/)
assert.equal(existsSync(join(state, 'locks', `solo-${RUN}.json`)), false)
refused(slateArgs, ['transition', '--stage', 'implement', '--exit', 'late'], /run already ended/)
assert.equal(read(runJson).outcome, 'ready-for-review')
pass('a promoted solo run releases its slate lock and refuses every later write')

// A second run whose challenge stage diverges: round 2 repeats round 1's
// finding on the very line round 1's fix added, which only the ledger can
// verify, so repeat_after_fix fires.
const DRUN = 'run-3-diverge'
const DBRANCH = '3-diverge'
sh('git', ['switch', '-q', '-c', DBRANCH, base])
writeFileSync(join(repo, 'a.txt'), 'one\ntwo\nthree\n')
const d1 = commitAll('feat: a')
r = run('node', [runRecord, ...soloArgs({ runId: DRUN, issue: 3, branch: DBRANCH })])
assert.equal(r.status, 0, r.stderr)
const dIdentity = JSON.parse(r.stdout)
const dSlate = ['--slate', dIdentity.slate_id, '--session', SESSION, '--run-id', DRUN]
const dWrite = writer(dSlate)
dWrite('transition', '--stage', 'claim')
dWrite('transition', '--stage', 'implement', '--exit', 'claimed')
dWrite('transition', '--stage', 'verify', '--exit', `committed ${d1}`)
dWrite('transition', '--stage', 'challenge', '--exit', 'green')
const finding = (round, line, provenance, fingerprint) => ({
  id: `challenge-r${round}-${challengeFinder}-1`, path: 'a.txt', line, class: 'correctness', provenance, fingerprint,
  priority: 'P1', recommended_disposition: 'fix', evidence: 'line two mishandles the edge case',
})
const p1 = (round, id, at) => ({ finding_id: id, reviewer_priority: 'P1', adjudicated_priority: 'P1', disposition: 'fix',
  reason: 'confirmed', evidence: at, override: null })
dWrite('receipt', '--pass', passFile('diverge-r1', envelope('challenger', 'challenge', 1, challengeFinder, [finding(1, 2, 'original', 'new')], { runId: DRUN, reviewed: d1 })))
v = adjudicateRound(dSlate, dIdentity.record_directory, 'challenge', 1, d1, adjudication('challenge', 1, [p1(1, finding(1, 2).id, 'a.txt:2')], { runId: DRUN, reviewed: d1 }))
assert.equal(v.json.outcome, 'continue', JSON.stringify(v.json))
const dPublish = publishFor({ ident: dIdentity, branch: DBRANCH, issue: 3 })
dPublish('challenge', 1, 'challenger', challengeFinder)
writeFileSync(join(repo, 'a.txt'), 'one\ntwo, fixed\na new guard\nthree\n')
const d2 = commitAll('fix: a')
const repeat = finding(2, 3, 'round:1', `repeat-of:${finding(1, 2).id}`)
dWrite('receipt', '--pass', passFile('diverge-r2', envelope('challenger', 'challenge', 2, challengeFinder, [repeat], { runId: DRUN, reviewed: d2 })))
v = adjudicateRound(dSlate, dIdentity.record_directory, 'challenge', 2, d2, adjudication('challenge', 2, [p1(2, repeat.id, 'a.txt:3')], { runId: DRUN, reviewed: d2 }))
assert.deepEqual(read(join(dIdentity.record_directory, 'history.json')),
  [{ round: 1, path: 'a.txt', added_lines: [2, 3], deleted_lines: [2], renamed_from: null }])
const repeated = v.verification.rounds.find((round) => round.round === 2).findings[0]
assert.deepEqual([repeated.provenance_status, repeated.verified_provenance, repeated.fingerprint_status],
  ['verified', 'round:1', 'verified'])
assert.equal(v.status, 21, JSON.stringify(v.json))
assert.equal(v.json.outcome, 'diverging')
dPublish('challenge', 2, 'challenger', challengeFinder)
pass("the writer's ledger verifies a round-2 repeat-of finding on round 1's own fix, so repeat_after_fix fires (diverging)")

// Stopped at that blocker: close records the outcome, the lock is released,
// and the branch can take a fresh solo run, which supersedes the ended one.
dWrite('close', '--outcome', 'escalated', '--exit', 'diverging: repeat_after_fix after challenge round 2/' + policy.rounds.challenge)
releaseLock(dIdentity.slate_id)
assert.equal(read(join(dIdentity.record_directory, 'run.json')).outcome, 'escalated')
assert.equal(existsSync(join(state, 'locks', `solo-${DRUN}.json`)), false)
r = run('node', [runRecord, ...soloArgs({ runId: `${DRUN}-r2`, issue: 3, branch: DBRANCH })])
assert.equal(r.status, 0, r.stderr)
assert.equal(JSON.parse(r.stdout).generation, 2)
pass('a solo run stopped at a blocker is closed and its lock released; a fresh solo run then supersedes the ended one on the same branch')

JS
echo "PASS: test-inline-record.sh"
