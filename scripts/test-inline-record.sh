#!/usr/bin/env bash
# test-inline-record.sh — behavioural test for the inline confidence-stage
# path's dev-flow-v2 run record (harmon-devkit#1183, the #973 decision).
#
# An interactive session with no orchestrator brief reserves a solo run with
# `run-record.mjs solo-init`, receipts each pass and adjudication through
# `run-record.mjs receipt|adjudicate`, advances with `transition`, publishes
# each round's evidence marker through review's `post-evidence.sh`, and the
# consumers read that record unchanged: the exit engine, the readiness-input
# projection `/integrate`'s gate reads, and `/retro`'s retro-run-report.mjs,
# which must discover the trusted marker and render `## Run evidence`.
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
trap 'rm -rf "$test_tmp"' EXIT
node --input-type=module - "$repo_root" "$test_tmp" <<'JS'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdirSync, chmodSync, cpSync, existsSync, readdirSync } from 'node:fs'
import { execFileSync, spawnSync } from 'node:child_process'
import { join } from 'node:path'

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
sh('git', ['add', '.'])
sh('git', ['commit', '-qm', 'initial'])
sh('git', ['remote', 'add', 'origin', 'https://github.com/example/repo'])
const base = sh('git', ['rev-parse', 'HEAD'])
sh('git', ['update-ref', 'refs/remotes/origin/main', base])
sh('git', ['symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main'])
const BRANCH = '1-solo'
sh('git', ['switch', '-q', '-c', BRANCH])
writeFileSync(join(repo, 'change.txt'), 'the change under review\n')
sh('git', ['add', 'change.txt'])
sh('git', ['commit', '-qm', 'feat: a change'])
const head = sh('git', ['rev-parse', 'HEAD'])
const policyFile = join(tmp, 'policy.json')
// Exit 3 is "resolved, but the gate slugs were not cross-checked": this
// scratch repository has no Taskfile, which the record does not depend on.
const resolved = spawnSync('node', [join(support, 'devflow-policy.mjs'), 'resolve', '--policy', '.devflow.toml', '--registry', 'agent-registry.json', '--json'], { cwd: repo, env, encoding: 'utf8' })
assert.ok([0, 3].includes(resolved.status), resolved.stderr)
writeFileSync(policyFile, resolved.stdout)
const policy = read(policyFile)
const common = sh('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'])
const runsDir = join(common, 'dev-flow-v2', 'runs')

// ---------------------------------------------------------------------------
// 1. A session that skips the confidence stages writes nothing.
// ---------------------------------------------------------------------------
assert.equal(existsSync(join(common, 'dev-flow-v2')), false)
pass('a session that never enters the confidence stages has no run record (nothing to treat as an error)')

// ---------------------------------------------------------------------------
// 2. solo-init reserves a real single-lane run.
// ---------------------------------------------------------------------------
const RUN = 'run-1-solo'
const SESSION = 'solo-session'
const initArgs = ['solo-init', '--session', SESSION, '--run-id', RUN, '--issue', '1', '--title', 'A change',
  '--url', 'https://github.com/example/repo/issues/1', '--branch', BRANCH, '--base', base, '--policy', policyFile]
let r = run('node', [runRecord, ...initArgs.map((a) => (a === RUN ? 'run-2-solo' : a))])
assert.equal(r.status, 2, r.stderr)
assert.match(r.stderr, /canonical run-1-<name>/)
r = run('node', [runRecord, ...initArgs.map((a) => (a === policyFile ? join(tmp, 'missing.json') : a))])
assert.equal(r.status, 1, r.stderr)
assert.match(r.stderr, /^refused: --policy not found/m)
assert.equal(existsSync(join(common, 'dev-flow-v2')), false)
pass('solo-init refuses a non-canonical run id or an unreadable policy before writing anything')
r = run('node', [runRecord, ...initArgs])
assert.equal(r.status, 0, r.stderr)
const identity = JSON.parse(r.stdout)
const record = identity.record_directory
const runJson = join(record, 'run.json')
assert.equal(identity.run_id, RUN)
assert.equal(identity.slate_id, `solo-${RUN}`)
assert.equal(identity.generation, 1)
assert.equal(identity.active_state_path, sh('bash', [join(source, 'ai/skills/universal/orchestrate/assets/dev-flow-monitor.sh'), 'active-path', '--branch', BRANCH, '--repo-root', repo]))
assert.deepEqual(read(identity.active_state_path), { ...read(identity.active_state_path), run_id: RUN, branch: BRANCH, generation: 1 })
assert.deepEqual(read(identity.policy_projection), { ...policy, rigor: { ...policy.rigor, source: 'default_rigor' } })
let runDoc = read(runJson)
assert.equal(runDoc.initiated_by, 'human')
assert.equal(runDoc.stage_transitions.length, 1)
assert.match(runDoc.stage_transitions[0].exit, /^resolved: rigor standard \(default_rigor\), strategy /)
sh('node', [join(support, 'validate-result-schemas.mjs'), 'run', runJson, '--receipts', runJson, '--no-adjudications'])
sh('node', [join(support, 'validate-result-schemas.mjs'), 'plan', join(common, 'dev-flow-v2', 'slates', `solo-${RUN}`, 'plan.json')])
assert.equal(read(join(common, 'dev-flow-v2', 'locks', `solo-${RUN}.json`)).session, SESSION)
pass('solo-init writes a schema-valid kickoff run.json, policy.json, single-lane plan, slate lock and active pointer')

const before = readFileSync(runJson, 'utf8')
r = run('node', [runRecord, ...initArgs])
assert.equal(r.status, 0, r.stderr)
assert.equal(JSON.parse(r.stdout).generation, 1)
assert.equal(readFileSync(runJson, 'utf8'), before)
pass('solo-init re-arms idempotently: same generation, run.json untouched')

r = run('node', [runRecord, 'solo-init', '--session', SESSION, '--run-id', 'run-1-other', '--issue', '1', '--title', 'A change',
  '--url', 'https://github.com/example/repo/issues/1', '--branch', BRANCH, '--base', base, '--policy', policyFile])
assert.equal(r.status, 1)
assert.match(r.stderr, /already has active run run-1-solo/)
assert.equal(existsSync(join(runsDir, 'run-1-other')), false)
pass('solo-init refuses to supersede a branch that already has an active run, writing nothing')

r = run('node', [runRecord, 'solo-init', '--session', 'another-session', '--run-id', 'run-1-elsewhere', '--issue', '1', '--title', 'A change',
  '--url', 'https://github.com/example/repo/issues/1', '--branch', '1-elsewhere', '--base', base, '--policy', policyFile])
assert.equal(r.status, 1)
assert.match(r.stderr, /issue\(s\) 1 are already locked by session solo-session/)
pass('solo-init refuses an issue another session holds')

// ---------------------------------------------------------------------------
// 3. The inline stages, through the existing writer plus receipt/adjudicate.
// ---------------------------------------------------------------------------
const slateArgs = ['--slate', identity.slate_id, '--session', SESSION, '--run-id', RUN]
const write = (...args) => {
  const out = run('node', [runRecord, ...args.slice(0, 1), ...slateArgs, ...args.slice(1)])
  assert.equal(out.status, 0, `${args.join(' ')}: ${out.stderr}`)
  return out.stdout
}
write('transition', '--stage', 'claim')
write('transition', '--stage', 'implement', '--exit', 'claimed by this session')
write('transition', '--stage', 'verify', '--exit', `committed ${head}`)
write('transition', '--stage', 'challenge', '--exit', 'task verify VERIFY-EXIT=0')

const scratch = join(tmp, 'scratch')
mkdirSync(scratch)
const now = () => new Date().toISOString().replace(/\.[0-9]{3}Z$/, 'Z')
const envelope = (role, stage, round, finder, findings) => ({
  schema: 2,
  role,
  status: 'completed',
  head,
  produced_at: now(),
  producer: { harness: 'claude-code', model: 'claude-opus-5-5', tier: 'frontier' },
  run: { run_id: RUN, initiated_by: 'human' },
  payload: {
    stage,
    round,
    reviewed_head: head,
    finder,
    slot: finder,
    findings,
    counts: ['P0', 'P1', 'P2', 'P3'].reduce((c, p) => ({ ...c, [p]: findings.filter((f) => f.priority === p).length }), {}),
    attack_scenarios: role === 'challenger' ? [{ id: 'as-1', description: 'tried to break the change', outcome: 'held', finding_id: null }] : undefined,
  },
})
const strip = (value) => JSON.parse(JSON.stringify(value))
const challengeFinder = policy.stages.challenge.finders[0]
const reviewFinder = policy.stages.review.finders[0]
const challengePass = join(scratch, 'challenge-r1.json')
put(challengePass, strip(envelope('challenger', 'challenge', 1, challengeFinder, [])))

// A pass for a stage the run is not in is refused, and publishes nothing.
const earlyReview = join(scratch, 'early-review.json')
put(earlyReview, strip(envelope('reviewer', 'review', 1, reviewFinder, [])))
r = run('node', [runRecord, 'receipt', ...slateArgs, '--pass', earlyReview])
assert.equal(r.status, 1)
assert.match(r.stderr, /active stage is challenge/)
assert.equal(existsSync(join(record, 'passes', `review-r1-${reviewFinder}.json`)), false)
// A pass bound to another run fails the validator, and publishes nothing.
const foreign = join(scratch, 'foreign.json')
put(foreign, strip({ ...envelope('challenger', 'challenge', 1, challengeFinder, []), run: { run_id: 'run-9-other', initiated_by: 'human' } }))
r = run('node', [runRecord, 'receipt', ...slateArgs, '--pass', foreign])
assert.equal(r.status, 1)
assert.match(r.stderr, /failed receipt validation/)
assert.equal(existsSync(join(record, 'passes', `challenge-r1-${challengeFinder}.json`)), false)
pass('receipt refuses a pass for the wrong stage or another run, publishing nothing')

assert.match(write('receipt', '--pass', challengePass), /recorded pass receipt challenge-r1-/)
assert.equal(readFileSync(join(record, 'passes', `challenge-r1-${challengeFinder}.json`), 'utf8'), readFileSync(challengePass, 'utf8'))
assert.match(write('receipt', '--pass', challengePass), /no change/)
const altered = join(scratch, 'altered.json')
put(altered, strip({ ...envelope('challenger', 'challenge', 1, challengeFinder, []), producer: { harness: 'codex-cli', model: 'other', tier: 'frontier' } }))
r = run('node', [runRecord, 'receipt', ...slateArgs, '--pass', altered])
assert.equal(r.status, 1)
assert.match(r.stderr, /immutable/)
assert.deepEqual(read(runJson).receipts.filter((x) => x.kind === 'pass'), [{ kind: 'pass', file: `challenge-r1-${challengeFinder}` }])
pass('receipt publishes the pass no-clobber and appends exactly one receipt; a re-receipt is a no-op, a changed one refused')

const adjudication = (stage, round, entries) => ({ schema: 2, run_id: RUN, stage, round, reviewed_head: head, adjudications: entries })
const missingRound = join(scratch, 'challenge-r2-adj.json')
put(missingRound, adjudication('challenge', 2, []))
r = run('node', [runRecord, 'adjudicate', ...slateArgs, '--file', missingRound])
assert.equal(r.status, 1)
assert.match(r.stderr, /no receipted pass/)
const challengeAdj = join(scratch, 'challenge-r1-adj.json')
put(challengeAdj, adjudication('challenge', 1, []))
assert.match(write('adjudicate', '--file', challengeAdj), /recorded adjudication challenge-r1/)
assert.match(write('adjudicate', '--file', challengeAdj), /no change/)

const exitEngine = join(support, 'dev-flow-exit.sh')
const verdict = (stage) => {
  const out = run('bash', [exitEngine, '--run', record, '--stage', stage, '--policy', join(repo, '.devflow.toml'), '--current-head', head, '--repo-root', repo, '--json'])
  return { status: out.status, json: out.stdout ? JSON.parse(out.stdout) : null, stderr: out.stderr }
}
let v = verdict('challenge')
assert.equal(v.status, 20, JSON.stringify(v.json) + v.stderr)
assert.equal(v.json.outcome, 'converged')
put(join(record, 'verdict-challenge-r1.json'), v.json)
pass('adjudicate publishes once; the exit engine converges the inline challenge stage from the record (empty round)')

const stale = join(scratch, 'stale.json')
put(stale, strip({ ...envelope('challenger', 'challenge', 2, challengeFinder, []), produced_at: '2026-01-01T00:00:00Z' }))
r = run('node', [runRecord, 'receipt', ...slateArgs, '--pass', stale])
assert.equal(r.status, 1)
assert.match(r.stderr, /before stage challenge began/)
pass('receipt refuses a pass produced before its stage began (the exit engine would reject it as out-of-span)')

// ---------------------------------------------------------------------------
// 4. Evidence: each adjudicated round is published through review's own
//    post-evidence.sh against a fake GitHub, and registered in run.json.
// ---------------------------------------------------------------------------
const bin = join(tmp, 'bin')
mkdirSync(bin)
const db = join(tmp, 'github.json')
env.INLINE_GH_DB = db
env.PATH = `${bin}:${env.PATH}`
const ISSUE = 1
const PR = 2
put(db, {
  login: 'solo-writer',
  actor: ACTOR,
  next_id: 100,
  comments: { [ISSUE]: [], [PR]: [] },
  pr: { number: PR, url: `https://github.com/example/repo/pull/${PR}`, title: 'feat: a change', state: 'OPEN', isDraft: true,
    body: `Closes #${ISSUE}\n`, closingIssuesReferences: [{ number: ISSUE }] },
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
  if (Number(a[2]) !== d.pr.number) { process.stderr.write('HTTP 404\\n'); process.exit(1) }
  out(d.pr)
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
  out(Number(m[1]) === d.pr.number ? { number: d.pr.number, pull_request: {} } : { number: Number(m[1]) })
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
const publish = (stage, round, role, finder) => {
  const verdictFile = join(record, `verdict-${stage}-r${round}.json`)
  const table = sh('bash', [render, 'round-table', '--record', record, '--stage', stage, '--round', String(round), '--verdict', verdictFile])
  const projection = {
    run_id: RUN, stage, round, reviewed_head: head,
    passes: [read(join(record, 'passes', `${stage}-r${round}-${finder}.json`))],
    adjudication: read(join(record, 'adjudications', `${stage}-r${round}.json`)).adjudications,
    exit: read(verdictFile),
  }
  const bodyFile = join(scratch, `${stage}-r${round}.md`)
  const markerFile = join(scratch, `${stage}-r${round}.marker.json`)
  writeFileSync(bodyFile, `**Dev flow v2 — ${stage} round ${round}** · run \`${RUN}\` (solo, inline path)\n\n${table}\n\n\`\`\`json\n${JSON.stringify(projection, null, 2)}\n\`\`\`\n`)
  put(markerFile, { run_id: RUN, stage, round, sequence: 1, destination: 'issue' })
  const out = run('bash', [postEvidence, '--repo', 'example/repo', '--repo-root', repo, '--run', runJson, '--branch', BRANCH,
    '--generation', String(identity.generation), '--active-state', identity.active_state_path, '--head', head,
    '--actor-id', String(ACTOR), '--role', role, '--finder', finder, '--issue', String(ISSUE),
    '--marker-file', markerFile, '--body-file', bodyFile, '--scratch-dir', scratch])
  assert.equal(out.status, 0, out.stderr)
  return out.stdout.trim()
}
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
const reviewR1 = join(scratch, 'review-r1.json')
put(reviewR1, strip(envelope('reviewer', 'review', 1, reviewFinder, [reviewFinding])))
write('receipt', '--pass', reviewR1)
const badAdj = join(scratch, 'review-r1-bad.json')
put(badAdj, adjudication('review', 1, []))
r = run('node', [runRecord, 'adjudicate', ...slateArgs, '--file', badAdj])
assert.equal(r.status, 1)
assert.match(r.stderr, /failed receipt validation/)
assert.equal(existsSync(join(record, 'adjudications', 'review-r1.json')), false)
pass('adjudicate refuses a document that leaves a receipted finding unadjudicated, publishing nothing')
const reviewAdj = join(scratch, 'review-r1-adj.json')
put(reviewAdj, adjudication('review', 1, [{
  finding_id: reviewFinding.id, reviewer_priority: 'P2', adjudicated_priority: 'P2', disposition: 'defer',
  reason: 'worth a test, not merge-blocking', evidence: 'change.txt:1 is a fixture', override: null,
}]))
write('adjudicate', '--file', reviewAdj)
v = verdict('review')
assert.equal(v.json.outcome, 'continue', JSON.stringify(v.json))
put(join(record, 'verdict-review-r1.json'), v.json)
publish('review', 1, 'reviewer', reviewFinder)
const reviewR2 = join(scratch, 'review-r2.json')
put(reviewR2, strip(envelope('reviewer', 'review', 2, reviewFinder, [])))
write('receipt', '--pass', reviewR2)
const reviewAdj2 = join(scratch, 'review-r2-adj.json')
put(reviewAdj2, adjudication('review', 2, []))
write('adjudicate', '--file', reviewAdj2)
v = verdict('review')
assert.equal(v.status, 20, JSON.stringify(v.json))
put(join(record, 'verdict-review-r2.json'), v.json)
publish('review', 2, 'reviewer', reviewFinder)
assert.equal(read(runJson).evidence_comments.length, 3)
pass('review continues on a P2-only round and converges on the empty round 2; every round carries its marker')

write('intervention', '--kind', 'asked', '--note', 'maintainer confirmed deferring the P2 to integration')
write('transition', '--stage', 'security', '--exit', 'converged: empty_round after review round 2/' + policy.rounds.review)
write('transition', '--stage', 'integration', '--exit', 'task security SECURITY-EXIT=0; draft PR opened')
write('bind-pr', '--number', String(PR), '--url', `https://github.com/example/repo/pull/${PR}`)
sh('node', [join(support, 'validate-result-schemas.mjs'), 'run', runJson, '--receipts', runJson,
  ...readdirSync(join(record, 'adjudications')).flatMap((f) => ['--adjudication', join(record, 'adjudications', f)])])
pass('the solo record reaches integration bound to its PR and validates strictly with every adjudication')

// ---------------------------------------------------------------------------
// 5. Consumers read the record unchanged.
// ---------------------------------------------------------------------------
const readiness = JSON.parse(sh('bash', [render, 'readiness-input', '--record', record, '--head', head], { stdio: ['ignore', 'pipe', 'ignore'] }))
assert.equal(readiness.head, head)
assert.deepEqual(readiness.deferred_findings.unsettled.map((f) => f.finding_id), [reviewFinding.id])
pass("the readiness gate's readiness-input projection reads the solo record: the deferred P2 is open until settled")

// /implement publishes the policy disclosure into the draft PR body
// (render-dev-flow.sh publish); the report reads its caps from there.
const disclosure = sh('bash', [render, 'policy-disclosure', '--record', record], { stdio: ['ignore', 'pipe', 'ignore'] })
const github = read(db)
github.pr.body = `Closes #${ISSUE}\n\n<!-- dev-flow:begin:policy-disclosure -->\n${disclosure}\n<!-- dev-flow:end:policy-disclosure -->\n`
put(db, github)
const report = run('node', [join(source, 'ai/skills/universal/retro/assets/retro-run-report.mjs'), '--repo', 'example/repo',
  '--pr', String(PR), '--trusted-actor-id', String(ACTOR), '--record-dir', runsDir])
assert.equal(report.status, 0, `${report.stdout}\n${report.stderr}`)
assert.match(report.stdout, /^## Run evidence/m)
assert.ok(report.stdout.includes(RUN), report.stdout)
assert.ok(report.stdout.includes(`Rounds spent: 1 / cap ${policy.rounds.challenge}`), report.stdout)
assert.ok(report.stdout.includes(`Rounds spent: 2 / cap ${policy.rounds.review}`), report.stdout)
assert.ok(report.stdout.includes('### Findings by class and provenance'), report.stdout)
assert.ok(report.stdout.includes('maintainer confirmed deferring the P2 to integration'), report.stdout)
assert.ok(report.stdout.includes('Forged-author comments: 0'), report.stdout)
pass('retro-run-report.mjs discovers the trusted marker on the linked issue and renders ## Run evidence (exit 0): rounds against caps, findings by provenance, interventions')

const untrusted = run('node', [join(source, 'ai/skills/universal/retro/assets/retro-run-report.mjs'), '--repo', 'example/repo',
  '--pr', String(PR), '--trusted-actor-id', '999', '--record-dir', runsDir])
assert.equal(untrusted.status, 11, `${untrusted.stdout}\n${untrusted.stderr}`)
pass('the same markers under a different trust set are indeterminate (exit 11), never a clean report')

JS
echo "PASS: test-inline-record.sh"
