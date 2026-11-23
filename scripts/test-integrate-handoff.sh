#!/usr/bin/env bash
# Behavioral test for integrate/assets/drive-handoff.sh (harmon-devkit#1919):
# the real run-record writer, validators, renderer, evidence publisher and
# readiness gate in offline fixture repositories, with `gh` and `gitleaks`
# replaced by stubs on PATH. No network, no model calls.
#
# An interruption is modelled as the step failing at that point: the driver
# keeps no state in memory, so what a restart finds on disk and on the fake
# GitHub is the same whether the process died or the step returned non-zero.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/integrate-handoff-test.XXXXXX")"
test_tmp="$(cd "$test_tmp" && pwd -P)"
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin"

# A fake GitHub over one JSON file. STUB_GH_FAIL=before:<op> fails a write
# before it lands; after:<op> lands it and then fails (op: comment or edit).
# STUB_GH_INTERLEAVE lands someone else's activity with the body edit: a PR
# comment, or a change to the body outside the managed section.
cat >"$test_tmp/bin/gh" <<'STUB'
#!/usr/bin/env node
const fs = require('node:fs')
const file = process.env.HANDOFF_GH_DB
const d = JSON.parse(fs.readFileSync(file, 'utf8'))
const a = process.argv.slice(2)
fs.appendFileSync(`${file}.log`, `${a.join(' ')}\n`)
const save = () => fs.writeFileSync(file, JSON.stringify(d))
const out = (value) => { process.stdout.write(`${typeof value === 'string' ? value : JSON.stringify(value)}\n`); process.exit(0) }
const die = (code, message) => { process.stderr.write(`fake gh: ${message}\n`); process.exit(code) }
const write = (op, apply) => {
  if (process.env.STUB_GH_FAIL === `before:${op}`) die(1, `${op} failed before the write`)
  const value = apply()
  save()
  fs.appendFileSync(`${file}.writes`, `${op}\n`)
  if (process.env.STUB_GH_FAIL === `after:${op}`) die(1, `${op} failed after the write`)
  return value
}
if (a[0] === 'repo' && a[1] === 'view') out('https://github.com/example/repo')
if (a[0] === 'pr' && a[1] === 'view') {
  if (a.includes('baseRefOid') && a.includes('--jq')) out(d.asset_base)
  out(d.pr)
}
if (a[0] === 'pr' && a[1] === 'edit') {
  out(write('edit', () => {
    d.pr.body = fs.readFileSync(0, 'utf8')
    if (process.env.STUB_GH_INTERLEAVE === 'comment') (d.comments[d.pr.number] = d.comments[d.pr.number] || []).push({ id: d.next_id++, user: { id: 9, login: 'reviewer' }, body: 'landed during the publish', created_at: d.now, updated_at: d.now })
    if (process.env.STUB_GH_INTERLEAVE === 'body') d.pr.body = `Someone else wrote this.\n\n${d.pr.body}`
    return ''
  }))
}
if (a[0] !== 'api') die(90, `unsupported ${a.join(' ')}`)
const slurp = a.includes('--slurp')
const page = (value) => out(slurp ? [value] : value)
if (a[1] === 'user') out({ id: d.actor, login: d.login })
if (a[1] === 'graphql') out([{ data: { repository: { pullRequest: { reviewThreads: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [] } } } } }])
const endpoint = a.find((arg) => arg.startsWith('repos/')) || ''
const path = endpoint.split('?')[0].replace(/^repos\/example\/repo\/?/, '')
let m
if ((m = /^issues\/([0-9]+)\/comments$/.exec(path))) {
  if (a.includes('-F')) {
    out(write('comment', () => {
      const body = fs.readFileSync(a[a.indexOf('-F') + 1].slice('body=@'.length), 'utf8')
      const comment = { id: d.next_id++, user: { id: d.actor, login: d.login }, body, created_at: d.now, updated_at: d.now }
      ;(d.comments[m[1]] = d.comments[m[1]] || []).push(comment)
      return comment
    }))
  }
  const number = Number(new URLSearchParams(endpoint.split('?')[1] || '').get('page') || '1')
  page(number === 1 ? (d.comments[m[1]] || []) : [])
}
if ((m = /^issues\/([0-9]+)$/.exec(path))) out(Number(m[1]) === d.pr.number ? { number: d.pr.number, pull_request: {} } : { number: Number(m[1]) })
if (/^pulls\/[0-9]+$/.test(path)) out({ number: d.pr.number, title: d.pr.title, body: d.pr.body, head: { sha: d.pr.headRefOid }, user: { id: d.actor, login: d.login } })
if (/^rules\/branches\//.test(path)) page([{ type: 'required_status_checks', parameters: { required_status_checks: [{ context: 'build', integration_id: null }] } }])
if (/^branches\/.*\/protection\/required_status_checks$/.test(path)) out({ contexts: [], checks: [] })
if (/^commits\/[0-9a-f]+\/check-runs$/.test(path)) page({ total_count: 1, check_runs: [{ name: 'build', status: 'completed', conclusion: 'success' }] })
if (/^actions\/runs$/.test(path)) page({ total_count: 0, workflow_runs: [] })
if (/^git\/ref\/heads\//.test(path)) out({ object: { sha: d.pr.baseRefOid } })
if (/^compare\//.test(path)) out({ behind_by: 0, ahead_by: 1, status: 'ahead', base_commit: { sha: d.pr.baseRefOid } })
if (path === '') out({ default_branch: 'main' })
if (path === 'commits' && endpoint.includes('path=agent-registry.json')) page([{ sha: d.pr.baseRefOid }])
if (/^commits\/[0-9a-f]+\/pulls$/.test(path)) page([{ number: 1000, merged_at: '2026-01-01T00:00:00Z', base: { ref: 'main', repo: { full_name: 'example/repo' } } }])
if (path === 'contents/agent-registry.json') out({ type: 'file', encoding: 'base64', sha: 'a'.repeat(40), content: d.registry })
page([])
STUB
# post-evidence scans with `gitleaks stdin`; the renderer with `detect
# --report-format json`, which answers an empty finding list.
printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' '[ "$1" != detect ] || echo "[]"' 'exit 0' >"$test_tmp/bin/gitleaks"
chmod +x "$test_tmp/bin/gh" "$test_tmp/bin/gitleaks"

# The writer's command line, wrapped so a test can fail one command before or
# after its write (STUB_WRITER_FAIL=before:receipt, after:adjudicate, ...).
cat >"$test_tmp/run-record-shim.mjs" <<'SHIM'
import { spawnSync } from 'node:child_process'
import { existsSync, realpathSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
export * from './run-record.real.mjs'
const self = fileURLToPath(import.meta.url)
if (process.argv[1] && existsSync(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(self)) {
  const [command, ...rest] = process.argv.slice(2)
  const fail = process.env.STUB_WRITER_FAIL ?? ''
  if (fail === `before:${command}`) process.exit(1)
  const r = spawnSync(process.execPath, [fileURLToPath(new URL('./run-record.real.mjs', import.meta.url)), command, ...rest], { stdio: 'inherit' })
  process.exit(fail === `after:${command}` ? 1 : r.status ?? 1)
}
SHIM

node --input-type=module - "$repo_root" "$test_tmp" <<'JS'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdirSync, cpSync, renameSync, existsSync, readdirSync } from 'node:fs'
import { join } from 'node:path'
import { execFileSync, spawnSync } from 'node:child_process'
const [source, tmp] = process.argv.slice(2)
const read = (p) => JSON.parse(readFileSync(p, 'utf8'))
const put = (p, v) => writeFileSync(p, `${JSON.stringify(v, null, 2)}\n`)
const ACTOR = 12345
const baseEnv = { ...process.env, PATH: `${join(tmp, 'bin')}:${process.env.PATH}`, GIT_CONFIG_GLOBAL: join(tmp, 'gitconfig'), GIT_CONFIG_NOSYSTEM: '1' }
for (const k of Object.keys(baseEnv)) if (/^(STUB_|HANDOFF_|RUN_RECORD_OWNER_TOKEN$)/.test(k)) delete baseEnv[k]
const git = (cwd, ...argv) => execFileSync('git', argv, { cwd, env: baseEnv, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
const identify = (cwd) => { for (const [k, v] of [['user.name', 'Test'], ['user.email', 'test@example.invalid'], ['commit.gpgsign', 'false']]) git(cwd, 'config', k, v) }

// The tools under test: a committed copy of the skills tree, so the readiness
// gate's own freshness check has a checkout to read. Integration cap 0: an
// integrator result then carries no Codex cycle, and a receipt needs no live
// checker state.
const tool = join(tmp, 'tool')
mkdirSync(join(tool, 'ai/skills'), { recursive: true })
cpSync(join(source, 'ai/skills/universal'), join(tool, 'ai/skills/universal'), { recursive: true })
const toml = readFileSync(join(source, '.devflow.toml'), 'utf8')
  .replace(/(\[rounds\.thorough\][^[]*?integration\s*=\s*)5/, '$10')
assert.match(toml, /\[rounds\.thorough\][^[]*?integration\s*=\s*0/, 'fixture policy disables the Codex cycle')
const registry = read(join(source, 'agent-registry.json'))
registry.trusted_orchestrator_actor_ids = [ACTOR]
writeFileSync(join(tool, '.devflow.toml'), toml)
put(join(tool, 'agent-registry.json'), registry)
const support = join(tool, 'ai/skills/universal/dev-flow-support/assets')
const integrate = join(tool, 'ai/skills/universal/integrate/assets')
// Label projection is an independent best-effort observer with its own tests.
writeFileSync(join(support, 'stage-labels.mjs'), 'export function projectRecordBestEffort() { return null }\n')
renameSync(join(support, 'run-record.mjs'), join(support, 'run-record.real.mjs'))
cpSync(join(tmp, 'run-record-shim.mjs'), join(support, 'run-record.mjs'))
git(tool, 'init', '-q', '-b', 'main'); identify(tool)
git(tool, 'add', '.'); git(tool, 'commit', '-qm', 'tools under test')
const toolHead = git(tool, 'rev-parse', 'HEAD')
git(tool, 'update-ref', 'refs/remotes/origin/main', toolHead)
git(tool, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
const command = join(integrate, 'drive-handoff.sh')
const writer = join(support, 'run-record.mjs')
const validator = join(support, 'validate-result-schemas.mjs')
const valid = join(source, 'ai/schemas/fixtures/result.integrator.schema/valid')

let counter = 0
function fixture() {
  const n = ++counter, repo = join(tmp, `repo${n}`), branch = `${n}-handoff`, PR = 700 + n, db = join(tmp, `github${n}.json`)
  mkdirSync(repo)
  const env = { ...baseEnv, HANDOFF_GH_DB: db }
  const sh = (cmd, argv, extra = {}) => execFileSync(cmd, argv, { cwd: repo, env: { ...env, ...extra }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
  git(repo, 'init', '-q', '-b', 'main'); identify(repo)
  put(join(repo, 'agent-registry.json'), registry)
  writeFileSync(join(repo, '.devflow.toml'), toml)
  git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'initial')
  const base = git(repo, 'rev-parse', 'HEAD')
  git(repo, 'remote', 'add', 'origin', 'https://github.com/example/repo')
  git(repo, 'update-ref', 'refs/remotes/origin/main', base)
  git(repo, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
  git(repo, 'switch', '-qc', branch)
  writeFileSync(join(repo, 'change.txt'), 'change\n')
  git(repo, 'add', '.'); git(repo, 'commit', '-qm', 'feat: fixture')
  const head = git(repo, 'rev-parse', 'HEAD')
  const policyFile = join(tmp, `policy${n}.json`)
  const resolved = spawnSync(process.execPath, [join(support, 'devflow-policy.mjs'), 'resolve', '--policy', '.devflow.toml', '--registry', 'agent-registry.json', '--json', '--rigor', 'thorough'], { cwd: repo, env, encoding: 'utf8' })
  assert.ok([0, 3].includes(resolved.status) && resolved.stdout.trim(), resolved.stderr)
  writeFileSync(policyFile, resolved.stdout)
  const runId = `run-${n}-handoff`, slate = `solo-${runId}`
  const token = sh(process.execPath, [writer, 'lock', 'acquire', '--slate', slate, '--session', 'fixture', '--issues', String(n)])
  const identity = JSON.parse(sh(process.execPath, [writer, 'solo-init', '--owner-token', token, '--session', 'fixture', '--run-id', runId, '--issue', String(n), '--title', 'fixture', '--url', `https://github.com/example/repo/issues/${n}`, '--branch', branch, '--base', base, '--policy', policyFile, '--actor-id', String(ACTOR), '--strategy-source', 'default_strategy']))
  const dir = identity.record_directory
  const write = (cmd, ...a) => sh(process.execPath, [writer, cmd, '--owner-token', token, '--slate', slate, '--session', 'fixture', '--run-id', runId, ...a])
  write('transition', '--stage', 'claim')
  for (const stage of ['implement', 'verify', 'security', 'integration']) write('transition', '--stage', stage, '--exit', 'fixture done')
  write('bind-pr', '--number', String(PR), '--url', `https://github.com/example/repo/pull/${PR}`)
  put(db, { actor: ACTOR, login: 'solo-writer', next_id: 100, now: '2026-01-01T00:00:00Z', comments: {}, asset_base: toolHead, registry: Buffer.from(JSON.stringify(registry)).toString('base64'),
    pr: { number: PR, url: `https://github.com/example/repo/pull/${PR}`, title: 'feat: fixture', state: 'OPEN', isDraft: true, headRefOid: head, body: `Refs #${n}\n`,
      reviewDecision: 'REVIEW_REQUIRED', mergeStateStatus: 'BLOCKED', headRefName: branch, baseRefName: 'main', baseRefOid: base, closingIssuesReferences: [] } })
  const github = () => read(db)
  const edit = (fn) => { const d = github(); fn(d); writeFileSync(db, JSON.stringify(d)) }
  const calls = () => existsSync(`${db}.log`) ? readFileSync(`${db}.log`, 'utf8').split('\n').filter(Boolean) : []
  const activity = () => JSON.parse(sh('bash', [join(integrate, 'readiness-gate.sh'), 'fingerprint', '--repo', 'example/repo', '--pr', String(PR)]).split('\n').at(-1)).fingerprint
  // A result derived from a checked-in valid fixture: this run, this head, now.
  const result = (name, { round = 1, cycles = false, snapshot = {}, patch = (r) => r } = {}) => {
    const original = read(join(valid, `${name}.json`))
    const r = JSON.parse(JSON.stringify(original).replaceAll(original.head, head))
    const now = new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
    Object.assign(r, { produced_at: now, run: { run_id: runId, initiated_by: 'human' } })
    Object.assign(r.payload, { settled_at: now, integration_round: round })
    if (!cycles) { r.payload.codex_cycle = null; delete r.payload.finder_cycles }
    for (const finding of r.payload.findings) finding.id = finding.id.replace(/^integration-r\d+-/, `integration-r${round}-`)
    if (r.payload.collection.snapshot.activity) r.payload.collection.snapshot.activity = activity()
    Object.assign(r.payload.collection.snapshot, snapshot)
    const file = join(tmp, `result-${n}-${++counter}.json`)
    put(file, patch(r))
    return file
  }
  const adjudication = (round, findingIds) => {
    const file = join(tmp, `adjudication-${n}-${round}.json`)
    put(file, { schema: 2, run_id: runId, stage: 'integration', round, reviewed_head: head, adjudications: findingIds.map((finding_id) => ({ finding_id, reviewer_priority: null, adjudicated_priority: 'P2', disposition: 'decline', reason: 'fixture decline', evidence: 'change.txt:1 is a fixture', override: null })) })
    return file
  }
  const drive = (resultFile, extra = [], stubs = {}, { as = slate, ownerToken = token } = {}) => {
    const captured = git(repo, 'rev-parse', branch)
    const r = spawnSync('bash', [command, '--repo', 'example/repo', '--pr', String(PR), '--slate', as, '--session', 'fixture', '--run-id', runId, '--result', resultFile, '--actor-id', String(ACTOR), ...extra],
      { cwd: repo, env: { ...env, RUN_RECORD_OWNER_TOKEN: ownerToken, ...stubs }, encoding: 'utf8' })
    if (r.stdout.trim()) {
      const outcome = JSON.parse(r.stdout)
      assert.deepEqual([outcome.run, outcome.head], [{ run_id: runId, generation: 1 }, captured], 'outcome binds the run, generation and captured head')
      const file = join(tmp, `outcome-${n}.json`)
      writeFileSync(file, r.stdout)
      const checked = spawnSync(process.execPath, [validator, 'stage-outcome', file], { encoding: 'utf8' })
      assert.equal(checked.status, 0, `stage outcome invalid: ${checked.stderr}`)
      r.outcome = outcome
    }
    return r
  }
  const record = () => read(join(dir, 'run.json'))
  // What a restart must never duplicate or lose.
  const effects = () => ({
    receipts: record().receipts.filter((receipt) => receipt.kind === 'pass').length,
    adjudications: existsSync(join(dir, 'adjudications')) ? readdirSync(join(dir, 'adjudications')).length : 0,
    comments: (github().comments[n] ?? []).length,
    markers: record().evidence_comments.length,
    edits: existsSync(`${db}.writes`) ? readFileSync(`${db}.writes`, 'utf8').split('\n').filter((op) => op === 'edit').length : 0,
  })
  return { n, repo, dir, head, base, PR, runId, env, sh, write, github, edit, calls, activity, result, adjudication, drive, record, effects }
}
const expect = (r, code, outcome, label) => {
  assert.equal(r.status, code, `${label}: ${r.stdout}${r.stderr}`)
  assert.equal(r.outcome?.outcome, outcome, `${label}: outcome`)
  return r
}
const refs = (r, kind) => r.outcome.evidence.filter((item) => item.kind === kind).map((item) => item.ref)
const NONE = { receipts: 0, adjudications: 0, comments: 0, markers: 0, edits: 0 }

// 1. Stops that write nothing. Each row is one result or one live condition.
const f = fixture()
const entryCalls = f.calls().length
const pending = (predicate, change) => (r) => {
  change(r)
  Object.assign(r.payload.collection, { complete: false, incomplete: [predicate], next_action: { kind: 'wait', event: predicate, responsible: 'orchestrator', overdue_after_seconds: 900 } })
  return r
}
for (const [label, make, code, outcome, check = () => {}] of [
  ['incomplete, ci-pending', () => f.result('collection-read-failed', { snapshot: { activity: f.activity() }, patch: pending('ci-pending', (r) => { r.payload.checks[0].bucket = 'pending' }) }), 11, 'waiting'],
  ['incomplete, review-pending', () => f.result('collection-read-failed', { cycles: true, snapshot: { activity: f.activity() }, patch: pending('review-pending', (r) => { r.payload.codex_cycle.exit_code = 11 }) }), 11, 'waiting'],
  ['incomplete, read-failed', () => f.result('collection-read-failed', { cycles: true }), 11, 'waiting'],
  ['incomplete, activity-moved', () => f.result('collection-activity-moved', { cycles: true }), 12, 'retryable'],
  ['incomplete, head-moved', () => f.result('collection-head-moved', { cycles: true }), 13, 'terminal-blocker',
    (r) => assert.equal(r.outcome.next_action.reason, 'Collection stopped: head-moved')],
  ['the result is blocked', () => f.result('collection-blocked-findings', { cycles: true }), 13, 'terminal-blocker'],
  ['the result records no collection', () => f.result('collection-clean-stable-head', { patch: (r) => { delete r.payload.collection; return r } }), 13, 'terminal-blocker'],
  ['the result is not schema-valid', () => f.result('collection-clean-stable-head', { patch: (r) => { r.payload.collection.complete = false; return r } }), 2, 'terminal-blocker'],
  ['a carried cycle beside a later integrator pass', () => f.result('collection-carried-catch-up', { cycles: true, round: 3, patch: (r) => {
    Object.assign(r.payload, { verdict: 'pending' })
    Object.assign(r.payload.collection, { complete: false, incomplete: ['activity-moved'], next_action: { kind: 'retry', retry_key: 'integrator-collection', attempt: 1, max_attempts: 2 } })
    return r
  } }), 12, 'retryable',
    (r) => { assert.deepEqual(refs(r, 'record'), ['integrator-pass 3']); assert.deepEqual(refs(r, 'review'), ['codex-cloud cycle 1 (carried)']) }],
]) {
  const before = readFileSync(join(f.dir, 'run.json'), 'utf8')
  const file = make()
  const r = expect(f.drive(file), code, outcome, label)
  check(r)
  // The result's own next action is the answer, unchanged.
  const own = read(file).payload.collection?.next_action
  if (own && code !== 2) assert.deepEqual(r.outcome.next_action, own, `${label}: the result's own next_action is passed through`)
  assert.equal(readFileSync(join(f.dir, 'run.json'), 'utf8'), before, `${label}: run.json changed`)
  assert.deepEqual(f.effects(), NONE, `${label}: an effect was written`)
}
// Criterion 5: no evidence is collected again. The only reads so far are the
// fixtures' own fingerprint reads; no check, review or thread endpoint beyond them.
assert.ok(f.calls().slice(entryCalls).every((line) => !/check-runs|statuses|actions\/runs/.test(line)), 'a pre-receipt stop reads no CI evidence')
console.log('PASS: a pending, retry, stop, blocked, collection-less or invalid result stops before any write, with its own next action')

const clean = f.result('collection-clean-stable-head')
for (const [label, setup, teardown, code] of [
  ['the PR head moved', () => f.edit((d) => { d.pr.headRefOid = f.base }), () => f.edit((d) => { d.pr.headRefOid = f.head }), 14],
  ['the branch head moved', () => { writeFileSync(join(f.repo, 'later.txt'), 'later\n'); git(f.repo, 'add', '.'); git(f.repo, 'commit', '-qm', 'fix: later') }, () => git(f.repo, 'reset', '-q', '--hard', f.head), 14],
  ['the PR is no longer a draft', () => f.edit((d) => { d.pr.isDraft = false }), () => f.edit((d) => { d.pr.isDraft = true }), 2],
  ['the PR head read fails', () => f.edit((d) => { d.saved = d.pr; d.pr = 'not a PR' }), () => f.edit((d) => { d.pr = d.saved; delete d.saved }), 2],
]) {
  setup()
  const r = f.drive(clean)
  teardown()
  assert.equal(r.status, code, `${label}: ${r.stdout}${r.stderr}`)
  if (r.outcome) assert.equal(r.outcome.outcome, 'terminal-blocker', `${label}: outcome`)
  assert.deepEqual(f.effects(), NONE, `${label}: an effect was written`)
}
expect(f.drive(clean, [], { RUN_RECORD_OWNER_TOKEN: 'not-the-owner-token' }), 2, 'terminal-blocker', 'invalid owner token')
assert.deepEqual(f.effects(), NONE)
console.log('PASS: a stale head, a non-draft PR, a failed read or an unproven owner stops before the receipt')

// 2. A clean result: receipt, no adjudication, no evidence, body published.
const done = expect(f.drive(clean), 0, 'progress', 'clean handoff')
assert.equal(done.outcome.next_action.stage, 'integration')
assert.deepEqual(f.effects(), { receipts: 1, adjudications: 0, comments: 0, markers: 0, edits: 1 })
assert.deepEqual(refs(done, 'receipt'), ['integration-r1-integrator'])
assert.deepEqual([refs(done, 'record'), refs(done, 'review')], [['integrator-pass 1'], []], 'a pass with no review cycle reports none')
assert.match(f.github().pr.body, /<!-- dev-flow:begin:deferred-findings -->/)
assert.match(done.outcome.detail, /re-triggers the guard checks/)
const rerun = expect(f.drive(clean), 0, 'progress', 'rerun after a completed handoff')
assert.deepEqual(f.effects(), { receipts: 1, adjudications: 0, comments: 0, markers: 0, edits: 1 }, 'a rerun repeats no write')
assert.doesNotMatch(rerun.outcome.detail, /re-triggers/)
console.log('PASS: a clean result is receipted and rendered once, with no adjudication written; a rerun repeats nothing')

// The readiness gate over that record: one clean, un-adjudicated integration
// round with no evidence marker passes, so the driver owes neither.
const gate = spawnSync('bash', [join(integrate, 'readiness-gate.sh'), 'check', '--repo', 'example/repo', '--pr', String(f.PR), '--head', f.head, '--record', f.dir,
  '--integration-cap', '0', '--remediation-cap', '5', '--integrator-result', join(f.dir, 'passes/integration-r1-integrator.json')], { cwd: f.repo, env: f.env, encoding: 'utf8' })
assert.equal(gate.status, 0, `readiness gate over a clean un-adjudicated round: ${gate.stdout}${gate.stderr}`)
assert.equal(JSON.parse(gate.stdout.trim().split('\n').at(-1)).status, 'pass')
console.log('PASS: the readiness gate passes a clean integration round that has no adjudication and no evidence marker')

// The writer admits a later pass only once the earlier round has its
// adjudication document, so a second pass over an un-adjudicated clean round
// is refused; the owner's (empty) adjudication is recorded and evidenced.
const later = f.result('collection-clean-stable-head', { round: 2 })
const refused = expect(f.drive(later), 2, 'terminal-blocker', 'a later pass before the earlier round is adjudicated')
assert.match(refused.outcome.next_action.reason, /the next unadjudicated integration round is 1/, 'the stop names the writer\'s own refusal')
expect(f.drive(clean, ['--adjudication', f.adjudication(1, [])]), 0, 'progress', 'an owner-supplied empty adjudication')
assert.deepEqual(f.effects(), { receipts: 1, adjudications: 1, comments: 1, markers: 1, edits: 1 }, 'the supplied adjudication is recorded and evidenced once')
// Review activity that moved after the snapshot: the later result is not
// retained, nothing is published, and the outcome is never progress.
f.edit((d) => { d.comments[f.PR] = [{ id: 900, user: { id: 9, login: 'reviewer' }, body: 'late review', created_at: d.now, updated_at: d.now }] })
const moved = expect(f.drive(later), 14, 'terminal-blocker', 'review activity moved since the snapshot')
assert.match(moved.outcome.next_action.reason, /review activity is [0-9a-f]{64}, not the result's final snapshot/)
assert.deepEqual(f.effects(), { receipts: 1, adjudications: 1, comments: 1, markers: 1, edits: 1 }, 'a stale result is not retained and nothing is published')
assert.deepEqual([refs(moved, 'record'), refs(moved, 'receipt')], [['integrator-pass 2'], []])
// A result collected after that activity is current again: it is the handoff.
expect(f.drive(f.result('collection-clean-stable-head', { round: 2 })), 0, 'progress', 'a result collected after the late review')
assert.deepEqual(f.effects(), { receipts: 2, adjudications: 1, comments: 1, markers: 1, edits: 1 })
// The same observation submitted again (another wakeup) is a duplicate: nothing retained.
const replay = f.result('collection-clean-stable-head', { round: 2, patch: (r) => { r.payload.collection.trigger = 'pending-result'; return r } })
expect(f.drive(replay), 13, 'terminal-blocker', 'duplicate wakeup')
assert.equal(f.effects().receipts, 2, 'a duplicate wakeup adds no pass')
console.log('PASS: a duplicate wakeup hands off nothing; a later pass waits for the earlier adjudication; changed review activity is a blocker, never progress')

// 3. Findings, with an interruption before and after each write. Every row
// stops; the next row is the restart and must adopt what already landed.
const g = fixture()
const findings = g.result('collection-late-finding', { patch: (r) => {
  r.payload.unanswered_thread_roots = []
  Object.assign(r.payload.collection, { complete: true, incomplete: [] })
  return r
} })
const ids = read(findings).payload.findings.map((finding) => finding.id)
const adjudicated = ['--adjudication', g.adjudication(1, ids)]
let seen = { ...NONE }
for (const [label, extra, stubs, code, outcome, grows] of [
  ['interrupted before the receipt', [], { STUB_WRITER_FAIL: 'before:receipt' }, 2, 'terminal-blocker', {}],
  ['interrupted after the receipt', [], { STUB_WRITER_FAIL: 'after:receipt' }, 2, 'terminal-blocker', { receipts: 1 }],
  ['restart adopts the receipt and asks for judgment', [], {}, 10, 'judgment-needed', {}],
  ['interrupted before the adjudication', adjudicated, { STUB_WRITER_FAIL: 'before:adjudicate' }, 2, 'terminal-blocker', {}],
  ['interrupted after the adjudication', adjudicated, { STUB_WRITER_FAIL: 'after:adjudicate' }, 2, 'terminal-blocker', { adjudications: 1 }],
  ['interrupted before the evidence comment', adjudicated, { STUB_GH_FAIL: 'before:comment' }, 2, 'terminal-blocker', {}],
  ['interrupted after the evidence comment', adjudicated, { STUB_GH_FAIL: 'after:comment' }, 2, 'terminal-blocker', { comments: 1 }],
  ['interrupted before the body edit', adjudicated, { STUB_GH_FAIL: 'before:edit' }, 2, 'terminal-blocker', { markers: 1 }],
  ['restart completes the handoff', adjudicated, {}, 0, 'progress', { edits: 1 }],
  ['rerun without the adjudication file', [], {}, 0, 'progress', {}],
]) {
  const r = expect(g.drive(findings, extra, stubs), code, outcome, label)
  seen = { ...seen, ...Object.fromEntries(Object.entries(grows).map(([key, by]) => [key, seen[key] + by])) }
  assert.deepEqual(g.effects(), seen, `${label}: effects`)
  if (code === 10) {
    assert.deepEqual(refs(r, 'review'), ids, 'the judgment stop carries the finding set')
    assert.deepEqual(refs(r, 'receipt'), ['integration-r1-integrator'])
    assert.equal(r.outcome.next_action.kind, 'request-judgment')
  }
}
assert.equal(g.github().comments[g.n].length, 1, 'one evidence comment')
assert.ok(g.github().comments[g.n][0].body.startsWith(`<!-- dev-flow-v2-evidence: {"run_id":"${g.runId}","stage":"integration","round":1,`))
assert.ok(g.github().comments[g.n][0].body.includes(ids[0]), 'the evidence projection carries the finding')
assert.equal(g.github().pr.body.split('<!-- dev-flow:begin:deferred-findings -->').length, 2, 'one managed section')
expect(g.drive(findings, ['--adjudication', g.adjudication(1, [])]), 2, 'terminal-blocker', 'a different adjudication for an adjudicated round')
console.log('PASS: an interruption before or after the receipt, the adjudication, the evidence comment and the body edit is adopted on restart with no duplicate and no lost finding')

// An interruption after the body edit landed: the driver cannot tell its own
// edit from other activity, so the restart reads as stale. The next result
// (admitted once the owner's adjudication of the earlier round is recorded)
// completes the handoff without a second edit.
const h = fixture()
const first = h.result('collection-clean-stable-head')
expect(h.drive(first, [], { STUB_GH_FAIL: 'after:edit' }), 2, 'terminal-blocker', 'interrupted after the body edit')
expect(h.drive(first, ['--adjudication', h.adjudication(1, [])]), 14, 'terminal-blocker', 'restart after an unrecorded body edit')
expect(h.drive(h.result('collection-clean-stable-head', { round: 2 })), 0, 'progress', 'the next result completes the handoff')
assert.equal(h.github().pr.body.split('<!-- dev-flow:begin:deferred-findings -->').length, 2, 'one managed section')
assert.deepEqual(h.effects(), { receipts: 2, adjudications: 1, comments: 1, markers: 1, edits: 1 }, 'the body is edited once')
console.log('PASS: an interruption after the body edit is never read as unchanged activity, and the body is not edited twice')

// An incomplete collection that asks for judgment is retained, adjudicated and
// evidenced, and still never reaches progress or edits the PR body.
for (const owed of [['replies-owed'], ['replies-owed', 'activity-moved']]) {
  const m = fixture()
  const partial = m.result('collection-late-finding', { patch: (r) => { r.payload.collection.incomplete = owed; return r } })
  const own = read(partial).payload.collection.next_action
  const partialIds = read(partial).payload.findings.map((finding) => finding.id)
  const settled = { receipts: 1, adjudications: 1, comments: 1, markers: 1, edits: 0 }
  for (const [label, extra, effects] of [
    ['retained', [], { ...NONE, receipts: 1 }],
    ['adjudicated and evidenced', ['--adjudication', m.adjudication(1, partialIds)], settled],
    ['rerun', [], settled],
  ]) {
    const r = expect(m.drive(partial, extra), 10, 'judgment-needed', `incomplete ${owed.join('+')}, ${label}`)
    assert.deepEqual(r.outcome.next_action, own, 'the result\'s own request-judgment is passed through')
    assert.deepEqual(refs(r, 'review'), partialIds, 'the outcome carries the finding set')
    assert.deepEqual(m.effects(), effects, `incomplete ${owed.join('+')}, ${label}: effects`)
    if (effects === settled) assert.match(r.outcome.detail, new RegExp(`incomplete \\(${owed.join(', ')}\\)`))
  }
}
console.log('PASS: an incomplete collection never reaches progress, whichever predicate is open')

// Activity that lands while the body is published is never taken as the
// driver's own: the expected value is derived from the pre-publish read.
for (const [landing, reason] of [['comment', /review activity moved while the PR body was published/], ['body', /not the pre-publish body with only this command's managed sections changed/]]) {
  const p = fixture()
  const landed = p.result('collection-clean-stable-head')
  const caught = expect(p.drive(landed, [], { STUB_GH_INTERLEAVE: landing }), 14, 'terminal-blocker', `a ${landing} lands during the publish`)
  assert.match(caught.outcome.next_action.reason, reason)
  assert.equal(existsSync(join(p.dir, 'drive-handoff.json')), false, `${landing}: no own activity is recorded`)
  expect(p.drive(landed), 14, 'terminal-blocker', `restart after a ${landing} landed during the publish`)
  assert.equal(p.effects().edits, 1, `${landing}: the body is edited once`)
}
console.log('PASS: a review or a foreign body edit landing during the publish is a blocker, never recorded as own activity')

// A hand-written section (with or without a managed one beside it) and an
// invalid record stop before the result is retained or the body edited.
const k = fixture()
const heading = k.sh('bash', [join(support, 'render-dev-flow.sh'), 'deferred-findings', '--record', k.dir]).split('\n').find((line) => line.startsWith('## '))
const managed = `<!-- dev-flow:begin:deferred-findings -->\n${heading}\n\nNone.\n<!-- dev-flow:end:deferred-findings -->`
for (const [label, body] of [
  ['with no managed section', `Refs #${k.n}\n\n${heading}\n\n- [ ] by hand\n`],
  ['beside a managed section', `Refs #${k.n}\n\n${managed}\n\n${heading}\n\n- [ ] by hand\n`],
]) {
  k.edit((d) => { d.pr.body = body })
  const handWritten = expect(k.drive(k.result('collection-clean-stable-head')), 2, 'terminal-blocker', `hand-written section ${label}`)
  assert.match(handWritten.outcome.next_action.reason, /hand-written/)
  assert.deepEqual(k.effects(), NONE, `hand-written section ${label}: a result the body cannot take is not retained`)
}
k.edit((d) => { d.pr.body = `Refs #${k.n}\n` })
const repaired = k.result('collection-clean-stable-head')
const saved = readFileSync(join(k.dir, 'run.json'), 'utf8')
const broken = JSON.parse(saved)
broken.settlements = [{ finding_id: 'integration-r1-nobody-1', disposition: 'decline', settled_at: '2026-01-01T00:00:00Z', reference: { type: 'comment_id', value: '1' } }]
put(join(k.dir, 'run.json'), broken)
const invalid = expect(k.drive(repaired), 2, 'terminal-blocker', 'a settlement no adjudication holds')
assert.match(invalid.outcome.next_action.reason, /integration-r1-nobody-1/, 'the invalid record is refused, naming the orphan settlement, before anything is retained or published')
writeFileSync(join(k.dir, 'run.json'), saved)
assert.deepEqual(k.effects(), NONE, 'neither stop retains a pass or edits the body')
expect(k.drive(repaired), 0, 'progress', 'the handoff completes once both are repaired')
assert.deepEqual(k.effects(), { receipts: 1, adjudications: 0, comments: 0, markers: 0, edits: 1 })
console.log('PASS: a hand-written section and an invalid record stop before the PR body is edited')

const usage = spawnSync('bash', [command], { encoding: 'utf8' })
assert.equal(usage.status, 2); assert.equal(usage.stdout, ''); assert.match(usage.stderr, /usage: /)
console.log('PASS: usage errors exit 2 without an outcome')
JS
