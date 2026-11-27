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
# comment, or a change to the body outside the managed section. Its `view`
# value lands a PR comment when render publish reads the body, for a publish
# that changes nothing. `push-after-write` and `push-after-read` move the PR
# head right after render publish's last read of it: its re-read after an
# edit, or its only read when it changes nothing. STUB_GH_FAIL=after-publish:fail
# fails the first read after render publish returns, and after-publish:kill
# holds that read so the fixture can kill the driver itself.
cat >"$test_tmp/bin/gh" <<'STUB'
#!/usr/bin/env node
const fs = require('node:fs')
const file = process.env.HANDOFF_GH_DB
const d = JSON.parse(fs.readFileSync(file, 'utf8'))
const a = process.argv.slice(2)
if (process.env.STUB_GH_HANG && a[0] === 'pr' && a[1] === 'view') {
  const probe = process.env.HANDOFF_PROBE_FILE
  if (probe) {
    fs.writeSync(2, 'diagnostic from the interrupted gh read\n')
    fs.writeFileSync(`${probe}.tmp`, JSON.stringify({ pid: process.pid }))
    fs.renameSync(`${probe}.tmp`, probe)
    setTimeout(() => process.exit(91), Number(process.env.HANDOFF_PROBE_MS))
  } else {
    process.on('SIGTERM', () => {})
    setInterval(() => {}, 1000)
  }
  return
}
fs.appendFileSync(`${file}.log`, `${a.join(' ')}\n`)
const save = () => fs.writeFileSync(file, JSON.stringify(d))
const out = (value) => {
  const raw = typeof value === 'string' ? value : JSON.stringify(value)
  const filter = a.includes('--jq') ? a[a.indexOf('--jq') + 1] : a.includes('-q') ? a[a.indexOf('-q') + 1] : null
  // gh applies --jq itself and prints strings raw; route it through the real jq.
  if (filter === null || typeof value === 'string') process.stdout.write(`${raw}\n`)
  else process.stdout.write(require('node:child_process').execFileSync('jq', ['-r', filter], { input: raw, encoding: 'utf8' }))
  process.exit(0)
}
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
  const pr = JSON.stringify(d.pr)
  const fields = a[a.indexOf('--json') + 1]
  const landing = process.env.STUB_GH_INTERLEAVE
  if ((process.env.STUB_GH_FAIL || '').startsWith('after-publish:') && fields.includes('body')) { d.published = true; save() }
  if (landing === 'view' && fields === 'number,url,headRefOid,isDraft,body,state') {
    ;(d.comments[d.pr.number] = d.comments[d.pr.number] || []).push({ id: d.next_id++, user: { id: 9, login: 'reviewer' }, body: 'landed during the publish', created_at: d.now, updated_at: d.now })
    save()
  }
  if ((landing === 'push-after-write' && fields === 'headRefOid,isDraft,body,state') || (landing === 'push-after-read' && fields === 'number,url,headRefOid,isDraft,body,state')) {
    d.pr.headRefOid = d.pr.baseRefOid
    save()
  }
  out(pr)
}
if (a[0] === 'pr' && a[1] === 'edit') {
  const edit = () => out(write('edit', () => {
    d.pr.body = fs.readFileSync(0, 'utf8')
    if (process.env.STUB_GH_INTERLEAVE === 'comment') (d.comments[d.pr.number] = d.comments[d.pr.number] || []).push({ id: d.next_id++, user: { id: 9, login: 'reviewer' }, body: 'landed during the publish', created_at: d.now, updated_at: d.now })
    if (process.env.STUB_GH_INTERLEAVE === 'body') d.pr.body = `Someone else wrote this.\n\n${d.pr.body}`
    return ''
  }))
  if (process.env.STUB_EDIT_RELEASE) {
    const probe = process.env.HANDOFF_PROBE_FILE
    fs.writeFileSync(`${probe}.tmp`, JSON.stringify({ pid: process.pid }))
    fs.renameSync(`${probe}.tmp`, probe)
    const timer = setInterval(() => {
      if (!fs.existsSync(process.env.STUB_EDIT_RELEASE)) return
      clearInterval(timer)
      edit()
    }, 25)
  } else if (process.env.STUB_DELAYED_EDIT) {
    const probe = process.env.STUB_DELAYED_EDIT
    const due = Date.now() + Number(process.env.HANDOFF_PROBE_MS)
    setTimeout(edit, Number(process.env.HANDOFF_PROBE_MS))
    fs.writeFileSync(`${probe}.tmp`, JSON.stringify({ pid: process.pid, due }))
    fs.renameSync(`${probe}.tmp`, probe)
  } else edit()
  return
}
if (a[0] !== 'api') die(90, `unsupported ${a.join(' ')}`)
const slurp = a.includes('--slurp')
const page = (value) => out(slurp ? [value] : value)
if (a[1] === 'user') out({ id: d.actor, login: d.login })
if (a[1].startsWith('users/')) out((d.users || {})[a[1].slice('users/'.length)] || die(1, 'HTTP 404'))
if (a[1] === 'graphql') out([{ data: { repository: { pullRequest: { reviewThreads: { pageInfo: { hasNextPage: false, endCursor: null }, nodes: [] } } } } }])
const endpoint = a.find((arg) => arg.startsWith('repos/')) || ''
const path = endpoint.split('?')[0].replace(/^repos\/example\/repo\/?/, '')
let m
if ((m = /^issues\/comments\/([0-9]+)\/reactions$/.exec(path))) page((d.reactions || {})[m[1]] || [])
if ((m = /^issues\/comments\/([0-9]+)$/.exec(path))) out(Object.values(d.comments).flat().find((comment) => String(comment.id) === m[1]) || die(1, 'HTTP 404'))
if ((m = /^commits\/([0-9a-f]{40})$/.exec(path))) out({ sha: m[1], commit: { author: { date: d.now }, committer: { date: d.now } } })
if (/^commits\/[0-9a-f]{40}\/check-suites$/.test(path)) page({ total_count: 0, check_suites: [] })
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
if (/^pulls\/[0-9]+$/.test(path) && d.published && (process.env.STUB_GH_FAIL || '').startsWith('after-publish:')) {
  delete d.published
  save()
  if (process.env.STUB_GH_FAIL === 'after-publish:kill') {
    const probe = process.env.HANDOFF_PROBE_FILE
    fs.writeFileSync(`${probe}.tmp`, JSON.stringify({ pid: process.pid }))
    fs.renameSync(`${probe}.tmp`, probe)
    setTimeout(() => die(1, 'the post-publish kill barrier was not reached'), Number(process.env.HANDOFF_PROBE_MS))
    return
  }
  die(1, 'the read after the publish failed')
}
if (/^pulls\/[0-9]+$/.test(path)) out({ number: d.pr.number, title: d.pr.title, body: d.pr.body, state: 'open', draft: d.pr.isDraft, head: { sha: d.pr.headRefOid, ref: d.pr.headRefName }, base: { sha: d.pr.baseRefOid, ref: d.pr.baseRefName }, user: { id: d.actor, login: d.login } })
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
# A scanner stub that knows one fixture credential, FIXTURE_SECRET: `detect`
# reports it as a finding, and `stdin` refuses input that contains it.
# post-evidence scans with `gitleaks stdin`; the renderer with `detect
# --report-format json`, which answers an empty finding list.
cat >"$test_tmp/bin/gitleaks" <<'STUB'
#!/usr/bin/env bash
input="$(cat)"
found=no
case "$input" in *"${FIXTURE_SECRET:?}"*) found=yes ;; esac
if [ "$1" = detect ]; then
    if [ "$found" = yes ]; then
        printf '[{"Secret":"%s","RuleID":"fixture-token"}]\n' "$FIXTURE_SECRET"
    else
        echo '[]'
    fi
    exit 0
fi
[ "$found" = no ]
STUB
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
  if (process.env.STUB_WRITER_HANG === command) await new Promise(() => setInterval(() => {}, 1000))
  const fail = process.env.STUB_WRITER_FAIL ?? ''
  if (fail === `before:${command}`) process.exit(1)
  const r = spawnSync(process.execPath, [fileURLToPath(new URL('./run-record.real.mjs', import.meta.url)), command, ...rest], { stdio: 'inherit' })
  process.exit(fail === `after:${command}` ? 1 : r.status ?? 1)
}
SHIM

node --input-type=module - "$repo_root" "$test_tmp" <<'JS'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdirSync, cpSync, renameSync, existsSync, readdirSync, rmSync } from 'node:fs'
import { join } from 'node:path'
import { execFileSync, spawn, spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { setTimeout as delay } from 'node:timers/promises'
import { pathToFileURL } from 'node:url'
const [source, tmp] = process.argv.slice(2)
const read = (p) => JSON.parse(readFileSync(p, 'utf8'))
const put = (p, v) => writeFileSync(p, `${JSON.stringify(v, null, 2)}\n`)
const ACTOR = 12345
// Credential-shaped, and assembled here so the literal never appears in a file.
const SECRET = `${'gh'}p_${'Fx7'.repeat(12)}`
const baseEnv = { ...process.env, PATH: `${join(tmp, 'bin')}:${process.env.PATH}`, GIT_CONFIG_GLOBAL: join(tmp, 'gitconfig'), GIT_CONFIG_NOSYSTEM: '1', TMPDIR: tmp, FIXTURE_SECRET: SECRET }
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
function fixture({ policy = toml } = {}) {
  const n = ++counter, repo = join(tmp, `repo${n}`), branch = `${n}-handoff`, PR = 700 + n, db = join(tmp, `github${n}.json`)
  mkdirSync(repo)
  const env = { ...baseEnv, HANDOFF_GH_DB: db }
  const sh = (cmd, argv, extra = {}) => execFileSync(cmd, argv, { cwd: repo, env: { ...env, ...extra }, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
  git(repo, 'init', '-q', '-b', 'main'); identify(repo)
  put(join(repo, 'agent-registry.json'), registry)
  writeFileSync(join(repo, '.devflow.toml'), policy)
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
  const driverArgs = (resultFile, extra = [], stubs = {}, { as = slate, ownerToken = token, timeout } = {}) => [
    'bash', [command, '--repo', 'example/repo', '--pr', String(PR), '--slate', as, '--session', 'fixture', '--run-id', runId, '--result', resultFile, '--actor-id', String(ACTOR), ...extra],
    { cwd: repo, env: { ...env, RUN_RECORD_OWNER_TOKEN: ownerToken, ...stubs }, encoding: 'utf8', timeout, killSignal: 'SIGKILL' },
  ]
  const drive = (resultFile, extra, stubs, options) => {
    const captured = git(repo, 'rev-parse', branch)
    const r = spawnSync(...driverArgs(resultFile, extra, stubs, options))
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
  return { n, repo, dir, head, base, PR, runId, env, sh, write, github, edit, calls, activity, result, adjudication, driverArgs, drive, record, effects }
}
const expect = (r, code, outcome, label) => {
  assert.equal(r.status, code, `${label}: ${r.stdout}${r.stderr}`)
  assert.equal(r.outcome?.outcome, outcome, `${label}: outcome`)
  return r
}
const refs = (r, kind) => r.outcome.evidence.filter((item) => item.kind === kind).map((item) => item.ref)
const NONE = { receipts: 0, adjudications: 0, comments: 0, markers: 0, edits: 0 }

// 0. A result that carries a real recorded Codex cycle: the shipped policy
// (integration cap above 0), the real checker's reservation, the owner's
// reserve and attach captures, then the handoff with --codex-state.
const y = fixture({ policy: readFileSync(join(source, '.devflow.toml'), 'utf8') })
const checker = join(integrate, 'check-codex-cloud-review.sh')
const codexState = join(git(y.repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'), 'integrate-codex/example/repo', `${y.PR}.json`)
mkdirSync(join(codexState, '..'), { recursive: true })
const stamp = () => new Date().toISOString().replace(/\.\d{3}Z$/, 'Z')
const codex = { id: 199175422, login: 'chatgpt-codex-connector[bot]', type: 'Bot' }
y.edit((d) => { d.users = { [codex.login]: codex } })
y.sh('bash', [checker, 'reserve', '--state', codexState, '--repo', 'example/repo', '--pr', String(y.PR), '--head', y.head, '--attempt', '1', '--run-id', y.runId, '--timeout-min', '10', '--finder', 'codex-cloud'])
y.write('integration-review-capture', '--state', codexState, '--authority-kind', 'reserve')
y.edit((d) => { d.comments[y.PR] = [{ id: 200, body: '@codex review', issue_url: `https://api.github.com/repos/example/repo/issues/${y.PR}`, created_at: stamp(), updated_at: stamp(), user: { id: ACTOR, login: 'solo-writer', type: 'User' } }] })
y.sh('bash', [checker, 'attach', '--state', codexState, '--trigger-id', '200'])
y.edit((d) => { d.reactions = { 200: [{ id: 901, content: '+1', created_at: stamp(), user: codex }] } })
y.write('integration-review-capture', '--state', codexState, '--authority-kind', 'attach')
const cycled = y.result('collection-clean-stable-head', { cycles: true, patch: (r) => {
  r.payload.codex_cycle = { head: y.head, cycle: 1, attempt: 1, trigger_comment_id: '200', exit_code: 0, accepted: { surface: 'reaction', id: '901', reviewed_commit: y.head } }
  return r
} })
const unauthenticated = expect(y.drive(cycled), 2, 'terminal-blocker', 'a Codex cycle with no --codex-state')
assert.match(unauthenticated.outcome.next_action.reason, /--codex-state and --codex-repo-dir/, 'the receipt refuses a cycle it cannot authenticate')
assert.deepEqual(y.effects(), NONE)
const receiptedCycle = expect(y.drive(cycled, ['--codex-state', codexState, '--codex-repo-dir', y.repo]), 0, 'progress', 'a result with a real recorded Codex cycle')
assert.deepEqual([refs(receiptedCycle, 'record'), refs(receiptedCycle, 'review'), refs(receiptedCycle, 'receipt')], [['integrator-pass 1'], ['codex-cloud cycle 1'], ['integration-r1-integrator']])
assert.deepEqual(y.effects(), { ...NONE, receipts: 1, edits: 1 })
console.log('PASS: a result with a real recorded Codex cycle is receipted through --codex-state and reaches progress')

// 1. Stops that write nothing. Each row is one result or one live condition.
const f = fixture()
const stalled = f.result('collection-clean-stable-head')
// Give ordinary subprocesses room on loaded runners. The finite stubs outlast
// the driver's bound, but still exit on their own if a test removes the bound.
const hangTimeoutMs = 10_000
const stubExitMs = 2 * hangTimeoutMs
const hungGitBin = join(tmp, 'hung-git')
mkdirSync(hungGitBin)
writeFileSync(join(hungGitBin, 'git'), `#!/usr/bin/env bash
if [[ "$*" == "$HANDOFF_HUNG_GIT_ARGS"* ]]; then
  count=0
  if [[ -f "$HANDOFF_GIT_COUNT" ]]; then read -r count < "$HANDOFF_GIT_COUNT"; fi
  count=$((count + 1))
  printf '%s\\n' "$count" > "$HANDOFF_GIT_COUNT"
  if [[ "$count" == "$HANDOFF_GIT_HANG_AT" ]]; then
    if [[ -n "\${HANDOFF_PROBE_FILE:-}" ]]; then
      exec node "$HANDOFF_TREE" interrupt "$HANDOFF_PROBE_FILE" "$HANDOFF_PROBE_MS"
    fi
    exec node -e 'setTimeout(() => process.exit(91), ${stubExitMs})'
  fi
fi
PATH="$HANDOFF_REAL_PATH" exec git "$@"
`, { mode: 0o755 })
const hangGit = (args, nth = 1) => ({
  PATH: `${hungGitBin}:${f.env.PATH}`, HANDOFF_REAL_PATH: f.env.PATH, HANDOFF_HUNG_GIT_ARGS: args,
  HANDOFF_GIT_HANG_AT: String(nth), HANDOFF_GIT_COUNT: join(hungGitBin, `count-${nth}-${args.split(' ')[0]}`),
})

const preload = join(tmp, 'timeout-fixture.cjs')
writeFileSync(preload, `
const fs = require('node:fs')
const [script, operation] = process.argv.slice(1)
const hang = () => {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ${stubExitMs})
  process.exit(91)
}
if (script?.endsWith('/validate-result-schemas.mjs') && operation === 'plan' && process.env.STUB_PLAN_HANG_AT) {
  const file = process.env.STUB_PLAN_COUNT
  const count = 1 + (fs.existsSync(file) ? Number(fs.readFileSync(file, 'utf8')) : 0)
  fs.writeFileSync(file, String(count))
  if (count === Number(process.env.STUB_PLAN_HANG_AT)) hang()
}
if (script?.endsWith('/render-dev-flow.mjs') && operation === 'publish' && process.env.STUB_PUBLISH_HANG) {
  const write = fs.writeFileSync
  fs.writeFileSync = (file, ...args) => {
    write(file, ...args)
    if (file === require('node:path').join(require('node:path').dirname(process.env.STUB_PUBLISH_HANG), '.publish-lock')) {
      const run = process.env.STUB_PUBLISH_HANG
      fs.copyFileSync(run, run + '.before-timeout')
      hang()
    }
  }
}
`)
const preloadTimeout = { NODE_OPTIONS: `--require=${JSON.stringify(preload)}` }
const hangPlan = (nth) => ({
  ...preloadTimeout, STUB_PLAN_HANG_AT: String(nth), STUB_PLAN_COUNT: join(tmp, `plan-count-${nth}`),
})
const publish = fixture()
const publishRun = join(publish.dir, 'run.json')
for (const [label, stubs, expected, bound = true, target = f] of [
  ['initial Git lookup', hangGit('rev-parse --path-format=absolute --git-common-dir'), /git rev-parse timed out/, false],
  ['bound branch lookup', hangGit('--no-replace-objects rev-parse --verify --quiet refs/heads/'), /git rev-parse --verify timed out/, false],
  ['second Git common-directory lookup', hangGit('rev-parse --path-format=absolute --git-common-dir', 2), /git rev-parse .* timed out/, false],
  ['repository plan validator', hangPlan(1), /validate-result-schemas\.mjs plan timed out/, false],
  ['lock plan validator', hangPlan(2), /validate-result-schemas\.mjs plan timed out/],
  ['later Git common-directory lookup', hangGit('rev-parse --path-format=absolute --git-common-dir', 3), /git rev-parse .* timed out/],
  ['GitHub read', { STUB_GH_HANG: '1' }, /gh pr view timed out/],
  ['receipt write', { STUB_WRITER_HANG: 'receipt' }, /run-record receipt timed out/],
  ['publish holding a lock', { ...preloadTimeout, STUB_PUBLISH_HANG: publishRun }, /render publish timed out/, true, publish],
]) {
  const recordPath = join(target.dir, 'run.json')
  const before = readFileSync(recordPath, 'utf8')
  const result = target === f ? stalled : target.result('collection-clean-stable-head')
  const r = target.drive(result, ['--command-timeout-ms', String(hangTimeoutMs)], stubs, { timeout: 60_000 })
  if (bound) {
    expect(r, 12, 'retryable', label)
    assert.match(r.outcome.detail, expected)
    assert.equal(r.outcome.next_action.kind, 'retry')
  } else {
    assert.equal(r.status, 12, r.stderr)
    assert.equal(r.stdout, '', `${label}: the run and head are not yet known`)
    assert.match(r.stderr, expected)
  }
  if (target === publish) {
    const lock = join(target.dir, '.publish-lock')
    assert.ok(existsSync(lock), 'publish reached the lock before timing out')
    assert.ok(r.outcome.detail.includes(lock))
    assert.match(r.outcome.detail, /confirming no owner is running.*remove.*re-run/)
    assert.equal(target.effects().edits, 0, 'the stalled edit never landed')
  }
  const expectedRecord = target === publish ? readFileSync(`${recordPath}.before-timeout`, 'utf8') : before
  assert.equal(readFileSync(recordPath, 'utf8'), expectedRecord, label)
}
console.log('PASS: command timeouts retry without recording progress; a stalled publish names the stale lock')

// Keep the test processes finite even if the driver's cleanup regresses.
// Readiness markers prove the subprocesses were running before an interrupt.
const treeBin = join(tmp, 'tree-bin')
mkdirSync(treeBin)
writeFileSync(join(treeBin, 'git'), `#!/usr/bin/env bash
exec node "$HANDOFF_TREE" "$HANDOFF_PROBE_KIND" "$HANDOFF_PROBE_FILE" "$HANDOFF_PROBE_MS"
`, { mode: 0o755 })
const tree = join(tmp, 'command-tree.cjs')
writeFileSync(tree, `
const fs = require('node:fs')
const { spawn } = require('node:child_process')
const [kind, file, lifetime] = process.argv.slice(2)
const due = Date.now() + Number(lifetime)
const mark = (path, data) => {
  fs.writeFileSync(path + '.tmp', JSON.stringify(data))
  fs.renameSync(path + '.tmp', path)
}
if (kind === 'interrupt' || kind === 'leaf') {
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(signal, () => {
      fs.appendFileSync(file + '.signals', kind + ' ' + signal + '\\n')
      if (kind !== 'leaf' || process.env.HANDOFF_IGNORE !== signal) process.exit(0)
    })
  }
}
if (kind === 'leaf') {
  if (process.env.HANDOFF_WAIT_RELEASE) {
    const timer = setInterval(() => {
      if (!fs.existsSync(file + '.release')) return
      mark(file + '.late', {})
      process.exit(0)
    }, 25)
    setTimeout(() => clearInterval(timer), Number(lifetime))
  } else setTimeout(() => mark(file + '.late', {}), Number(lifetime))
  mark(file + '.leaf', { pid: process.pid })
} else if (kind === 'completed') {
  mark(file, { pid: process.pid })
  setTimeout(() => process.exit(91), Number(lifetime))
} else {
  const child = kind === 'interrupt'
    ? spawn(process.execPath, [__filename, 'leaf', file, lifetime], { stdio: 'ignore' })
    : spawn('sleep', [String(Number(lifetime) / 1000)], {
      detached: kind === 'escape', stdio: ['ignore', kind === 'escape' ? 'inherit' : 'ignore', 'ignore'],
    })
  const arm = () => {
    if (kind === 'interrupt' && !fs.existsSync(file + '.leaf')) setTimeout(arm, 25)
    else mark(file, { pid: process.pid, child: child.pid, watchdog: process.ppid, due })
  }
  arm()
  if (kind === 'sleep') child.on('exit', (code) => { if (code === 0) mark(file + '.late', {}) })
  else setTimeout(() => {}, Number(lifetime))
}
`)
const probeStubs = (kind, file, extra = {}) => ({
  PATH: `${treeBin}:${f.env.PATH}`, HANDOFF_TREE: tree, HANDOFF_PROBE_KIND: kind, HANDOFF_PROBE_FILE: file,
  HANDOFF_PROBE_MS: String(stubExitMs), ...extra,
})
const running = (pid) => {
  const result = spawnSync('ps', ['-o', 'state=', '-p', String(pid)], { encoding: 'utf8' })
  assert.ifError(result.error)
  assert.equal(result.stderr, '')
  const state = result.stdout.trim()
  return Boolean(state && !state.startsWith('Z'))
}
const cleanup = (pid) => {
  if (!pid || !running(pid)) return
  try { process.kill(pid, 'SIGKILL') } catch (error) { if (error.code !== 'ESRCH') throw error }
}
const waitFor = async (test, reason) => {
  const limit = Date.now() + 60_000
  while (!test() && Date.now() < limit) await delay(25)
  assert.ok(test(), reason)
}
async function probeDriver(target, result, file, stubs, verify, { extra = [], commandTimeout = hangTimeoutMs } = {}) {
  const [program, args, options] = target.driverArgs(result, [...extra, '--command-timeout-ms', String(commandTimeout)], stubs, { timeout: 60_000 })
  const driver = spawn(program, args, { ...options, detached: true })
  let stdout = '', stderr = ''
  driver.stdout.setEncoding('utf8').on('data', (chunk) => { stdout += chunk })
  driver.stderr.setEncoding('utf8').on('data', (chunk) => { stderr += chunk })
  driver.stdin.end()
  const exited = new Promise((resolve) => driver.on('close', (status, signal) => resolve({ status, signal, stdout, stderr })))
  let ready
  try {
    const limit = Date.now() + 30_000
    while (!existsSync(file) && driver.exitCode === null && driver.signalCode === null && Date.now() < limit) await delay(25)
    assert.ok(existsSync(file), `probe did not arm: ${file}\n${stderr}`)
    ready = read(file)
    return await verify({ ready, driver, exited })
  } finally {
    cleanup(ready?.child)
    cleanup(ready?.pid)
    if (driver.exitCode === null && driver.signalCode === null) cleanup(driver.pid)
    await exited
  }
}

const pausedWatchdog = join(tmp, 'pause-watchdog-timers.mjs')
writeFileSync(pausedWatchdog, `import { mock } from 'node:test'
if (process.argv[2] === '--watchdog') mock.timers.enable({ apis: ['setTimeout'] })
`)
const pauseWatchdogTimers = `--import=${pathToFileURL(pausedWatchdog).href}`

function killAtPublishedRead(target, result, extra, stubs = {}) {
  const file = join(tmp, `post-publish-${target.n}`)
  return probeDriver(target, result, file, {
    ...stubs, STUB_GH_FAIL: 'after-publish:kill', HANDOFF_PROBE_FILE: file, HANDOFF_PROBE_MS: '60000',
  }, async ({ ready, driver, exited }) => {
    process.kill(driver.pid, 'SIGKILL')
    const reply = await exited
    await waitFor(() => !running(ready.pid), 'the post-publish read stopped')
    return reply
  }, { extra, commandTimeout: 60_000 })
}

const delayedPublish = fixture()
const lateResult = delayedPublish.result('collection-clean-stable-head')
const sleepProbe = join(tmp, 'sleep-probe')
const editProbe = join(tmp, 'edit-probe')
const processRows = [
  ['timeout kills a sleep grandchild and a delayed edit under publish', async () => {
    const dueDates = await Promise.all([
      probeDriver(f, stalled, sleepProbe, probeStubs('sleep', sleepProbe), async ({ ready, exited }) => {
        const r = await exited
        assert.deepEqual([r.status, r.stdout], [12, ''])
        assert.match(r.stderr, /git rev-parse timed out/)
        assert.ok(!running(ready.pid) && !running(ready.child), 'the timed-out Git tree cannot still run')
        return ready.due
      }),
      probeDriver(delayedPublish, lateResult, editProbe, { STUB_DELAYED_EDIT: editProbe, HANDOFF_PROBE_MS: String(stubExitMs) }, async ({ ready, exited }) => {
        const r = await exited
        assert.equal(r.status, 12, r.stderr)
        const outcome = JSON.parse(r.stdout)
        assert.equal(outcome.next_action.retry_key, 'drive-handoff.sh:12')
        assert.ok(outcome.detail.includes(join(delayedPublish.dir, '.publish-lock')))
        assert.ok(!running(ready.pid), 'the delayed fake gh edit cannot still run')
        return ready.due
      }),
    ])
    await delay(Math.max(0, Math.max(...dueDates) - Date.now()) + 250)
    assert.ok(!existsSync(`${sleepProbe}.late`))
    assert.equal(delayedPublish.effects().edits, 0, 'no PR-body edit survives the timeout')
  }],
  ['interrupts sent to the driver PID or group reach its command tree', async () => {
    const cases = [['SIGINT', 'pid'], ['SIGINT', 'group'], ['SIGTERM', 'pid'], ['SIGTERM', 'group'], ['SIGHUP', 'pid']]
    for (const [signal, destination] of cases) {
      const file = join(tmp, `interrupt-${signal}-${destination}`)
      const stubs = probeStubs('interrupt', file, { HANDOFF_IGNORE: signal === 'SIGTERM' ? signal : '' })
      await probeDriver(f, stalled, file, stubs, async ({ ready, driver, exited }) => {
        process.kill(destination === 'group' ? -driver.pid : driver.pid, signal)
        const r = await exited
        assert.deepEqual([r.status, r.signal, r.stdout], [null, signal, ''], `${signal} via ${destination}: ${r.stderr}`)
        assert.deepEqual(readFileSync(`${file}.signals`, 'utf8').trim().split('\n').sort(), [`interrupt ${signal}`, `leaf ${signal}`])
        assert.ok(!running(ready.pid) && !running(ready.child), 'the interrupted tree cannot still run')
        assert.ok(!existsSync(`${file}.late`), 'no interrupted writer landed')
      })
    }
  }],
  ['the watchdog kills gated writers after fatal driver signals', async () => {
    const cases = [
      ['kill-pid', 'SIGKILL', false],
      ['kill-group', 'SIGKILL', true],
      ['quit', 'SIGQUIT', false],
      ['term-then-kill', 'SIGKILL', false],
    ]
    for (const [label, signal, group] of cases) {
      const file = join(tmp, `fatal-${label}`)
      const termFirst = label === 'term-then-kill'
      const stubs = probeStubs('interrupt', file, {
        HANDOFF_WAIT_RELEASE: '1', HANDOFF_PROBE_MS: '180000', HANDOFF_IGNORE: 'SIGTERM',
        // The watchdog handles TERM and sees the stubborn child, but only EOF
        // can force-kill it. Mock time only in this watchdog process.
        ...(termFirst && { NODE_OPTIONS: `${f.env.NODE_OPTIONS ?? ''} ${pauseWatchdogTimers}`.trim() }),
      })
      await probeDriver(f, stalled, file, stubs, async ({ ready, driver, exited }) => {
        if (termFirst) {
          process.kill(driver.pid, 'SIGTERM')
          const signals = `${file}.signals`
          await waitFor(() => existsSync(signals) && readFileSync(signals, 'utf8').includes('leaf SIGTERM\n'), 'the writer received and ignored forwarded SIGTERM')
        }
        process.kill(group ? -driver.pid : driver.pid, signal)
        const r = await exited
        assert.deepEqual([r.status, r.signal, r.stdout], [null, signal, ''], `${label}: ${r.stderr}`)
        await waitFor(() => [ready.pid, ready.child, ready.watchdog].every((pid) => !running(pid)), `${label}: the watchdog ended the command and its writer and exited`)
        writeFileSync(`${file}.release`, '')
        assert.ok(!running(ready.child) && !existsSync(`${file}.late`), `${label}: releasing the write gate left zero writes`)
      }, { commandTimeout: 120_000 })
    }
  }],
  ['an interrupted bound command exits by signal without writing an outcome or diagnostic', async () => {
    const cases = [
      // The third common-directory lookup runs in stateRoot after binding and
      // rewraps the command error before it reaches the driver's catch.
      ['state-root', (file) => probeStubs('interrupt', file, {
        ...hangGit('rev-parse --path-format=absolute --git-common-dir', 3), HANDOFF_GIT_COUNT: `${file}.count`,
      })],
      // A direct bound read has captured stderr that the driver discards on EINTR.
      ['pr-view', (file) => ({ STUB_GH_HANG: '1', HANDOFF_PROBE_FILE: file, HANDOFF_PROBE_MS: String(stubExitMs) })],
    ]
    for (const [label, stubs] of cases) {
      const file = join(tmp, `bound-interrupt-${label}`)
      await probeDriver(f, stalled, file, stubs(file), async ({ driver, exited }) => {
        process.kill(driver.pid, 'SIGINT')
        const result = await exited
        assert.deepEqual(result, { status: null, signal: 'SIGINT', stdout: '', stderr: '' }, label)
      })
    }
  }],
  ['an escaped stdout holder cannot extend the command deadline', async () => {
    const file = join(tmp, 'escaped-stdout')
    await probeDriver(f, stalled, file, probeStubs('escape', file), async ({ ready, exited }) => {
      const r = await exited
      assert.equal(r.status, 12, r.stderr)
      assert.match(r.stderr, /git rev-parse timed out/)
      const elapsed = Date.now() - (ready.due - stubExitMs)
      const grace = 1000, runnerTolerance = 5000
      assert.ok(elapsed <= hangTimeoutMs + grace + runnerTolerance, `return took ${elapsed} ms`)
      assert.ok(running(ready.child), 'the escaped sleep is still holding stdout when the driver returns')
    })
  }],
  ['untimed results match spawnSync for stdio, status, signals, env and cwd', async () => {
    const { superviseCommand } = await import(pathToFileURL(join(integrate, 'drive-handoff.mjs')).href)
    const program = `const fs = require('node:fs');
      fs.writeSync(1, fs.readFileSync(0).toString('hex') + '\\n' + process.cwd() + '\\n' + process.env.PARITY);
      fs.writeSync(2, 'fixture stderr\\n');
      if (process.argv[1] === 'signal') process.kill(process.pid, 'SIGTERM');
      else process.exitCode = 23;`
    for (const [label, input] of [['status', Buffer.from([0, 65, 255])], ['signal', undefined]]) {
      const args = ['-e', program, label]
      const options = { cwd: f.repo, env: { PATH: baseEnv.PATH, PARITY: 'custom value' }, encoding: 'utf8', input, timeout: hangTimeoutMs, maxBuffer: 1024 * 1024 }
      const plain = spawnSync(process.execPath, args, options)
      assert.ifError(plain.error)
      const expected = { status: plain.status, signal: plain.signal, stdout: plain.stdout, stderr: plain.stderr }
      const supervised = await new Promise((resolve) => superviseCommand(process.execPath, args, options, resolve))
      assert.deepEqual(supervised, expected, label)
    }
  }],
  ['EPERM from a signal-0 group probe preserves successful spawnSync results', async () => {
    const { superviseCommand } = await import(pathToFileURL(join(integrate, 'drive-handoff.mjs')).href)
    const args = ['-e', "process.stdout.write('stdout'); process.stderr.write('stderr')"]
    const options = { cwd: f.repo, encoding: 'utf8', timeout: hangTimeoutMs, maxBuffer: 1024 * 1024 }
    const plain = spawnSync(process.execPath, args, options)
    assert.ifError(plain.error)
    assert.equal(plain.status, 0)
    const kill = process.kill
    let probes = 0
    process.kill = (pid, signal) => {
      if (pid < 0 && signal === 0) {
        probes++
        throw Object.assign(new Error('signal-0 probe denied'), { code: 'EPERM' })
      }
      return kill(pid, signal)
    }
    try {
      const supervised = await new Promise((resolve) => superviseCommand(process.execPath, args, options, resolve))
      assert.equal(probes, 1, 'the exit-time group probe encountered EPERM')
      assert.deepEqual(supervised, { status: plain.status, signal: plain.signal, stdout: plain.stdout, stderr: plain.stderr })
    } finally {
      process.kill = kill
    }
  }],
]
for (const [label, verify] of processRows) {
  await verify()
  console.log(`PASS: ${label}`)
}

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
  // The receipt cannot admit these, so no judgment is requested for them: a
  // supplied adjudication could never be recorded. They answer what they owe.
  ['findings beside ci-pending', () => f.result('collection-late-finding', { patch: (r) => {
    r.payload.checks[0].bucket = 'pending'
    r.payload.collection.incomplete = ['ci-pending', 'replies-owed']
    return r
  } }), 11, 'waiting', (r, file) => {
    assert.deepEqual(r.outcome.next_action, { kind: 'wait', event: 'ci-pending, replies-owed', responsible: 'orchestrator', overdue_after_seconds: 900 })
    assert.equal(refs(r, 'review').length, 1, 'the outcome still carries the finding')
    const ids = read(file).payload.findings.map((finding) => finding.id)
    const again = expect(f.drive(file, ['--adjudication', f.adjudication(1, ids)]), 11, 'waiting', 'a supplied adjudication for a result that cannot be receipted')
    assert.deepEqual(again.outcome.next_action, r.outcome.next_action, 'the re-run asks for no judgment either')
  }],
  ['findings beside review-pending', () => f.result('collection-late-finding', { cycles: true, patch: (r) => {
    r.payload.codex_cycle.exit_code = 11
    delete r.payload.codex_cycle.accepted
    r.payload.collection.incomplete = ['review-pending', 'replies-owed']
    return r
  } }), 11, 'waiting', (r) => assert.deepEqual(r.outcome.next_action, { kind: 'wait', event: 'review-pending, replies-owed', responsible: 'orchestrator', overdue_after_seconds: 900 })],
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
  check(r, file)
  // The result's own next action is the answer, unchanged. The one exception
  // is a judgment request the driver cannot receipt, checked by its own row.
  const own = read(file).payload.collection?.next_action
  if (own && code !== 2 && own.kind !== 'request-judgment') assert.deepEqual(r.outcome.next_action, own, `${label}: the result's own next_action is passed through`)
  assert.notEqual(r.outcome.outcome, 'judgment-needed', `${label}: no judgment is requested for a result that is not retained`)
  assert.equal(readFileSync(join(f.dir, 'run.json'), 'utf8'), before, `${label}: run.json changed`)
  assert.deepEqual(f.effects(), NONE, `${label}: an effect was written`)
}
// Criterion 5: no evidence is collected again. The only reads so far are the
// fixtures' own fingerprint reads; no check, review or thread endpoint beyond them.
assert.ok(f.calls().slice(entryCalls).every((line) => !/check-runs|statuses|actions\/runs/.test(line)), 'a pre-receipt stop reads no CI evidence')
console.log('PASS: a pending, retry, stop, blocked, collection-less or invalid result stops before any write with its own next action; findings beside a pending predicate wait and are never asked for a judgment')

const clean = f.result('collection-clean-stable-head')
const waiting = f.result('collection-read-failed', { cycles: true })
for (const [label, setup, teardown, code, file = clean] of [
  ['a pending result on a moved PR head', () => f.edit((d) => { d.pr.headRefOid = f.base }), () => f.edit((d) => { d.pr.headRefOid = f.head }), 14, waiting],
  ['a pending result on a moved branch head', () => { writeFileSync(join(f.repo, 'later.txt'), 'later\n'); git(f.repo, 'add', '.'); git(f.repo, 'commit', '-qm', 'fix: later') }, () => git(f.repo, 'reset', '-q', '--hard', f.head), 14, waiting],
  ['the PR head moved', () => f.edit((d) => { d.pr.headRefOid = f.base }), () => f.edit((d) => { d.pr.headRefOid = f.head }), 14],
  ['the branch head moved', () => { writeFileSync(join(f.repo, 'later.txt'), 'later\n'); git(f.repo, 'add', '.'); git(f.repo, 'commit', '-qm', 'fix: later') }, () => git(f.repo, 'reset', '-q', '--hard', f.head), 14],
  ['the PR is no longer a draft', () => f.edit((d) => { d.pr.isDraft = false }), () => f.edit((d) => { d.pr.isDraft = true }), 2],
  ['the PR head read fails', () => f.edit((d) => { d.saved = d.pr; d.pr = 'not a PR' }), () => f.edit((d) => { d.pr = d.saved; delete d.saved }), 2],
]) {
  setup()
  const r = f.drive(file)
  teardown()
  assert.equal(r.status, code, `${label}: ${r.stdout}${r.stderr}`)
  if (r.outcome) assert.equal(r.outcome.outcome, 'terminal-blocker', `${label}: outcome`)
  assert.deepEqual(f.effects(), NONE, `${label}: an effect was written`)
}
expect(f.drive(clean, [], { RUN_RECORD_OWNER_TOKEN: 'not-the-owner-token' }), 2, 'terminal-blocker', 'invalid owner token')
assert.deepEqual(f.effects(), NONE)
console.log('PASS: a stale head (under a pending result too), a non-draft PR, a failed read or an unproven owner stops before the receipt')

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

// A clean, complete result can carry findings whose dispositions were already
// applied. They still owe an adjudication: judgment, then the handoff.
const c = fixture()
const applied = c.result('collection-clean-stable-head', { patch: (r) => {
  r.payload.findings = [{ id: 'integration-r1-human-1', body: 'declined in an earlier pass', source_id: '1' }]
  r.payload.applied_dispositions = [{ finding_id: 'integration-r1-human-1', disposition: 'decline' }]
  return r
} })
const owedJudgment = expect(c.drive(applied), 10, 'judgment-needed', 'a clean result with findings and no adjudication')
assert.equal(owedJudgment.outcome.next_action.kind, 'request-judgment')
assert.deepEqual(refs(owedJudgment, 'review'), ['integration-r1-human-1'])
assert.deepEqual(c.effects(), { ...NONE, receipts: 1 })
expect(c.drive(applied, ['--adjudication', c.adjudication(1, ['integration-r1-human-1'])]), 0, 'progress', 'a clean result with findings, adjudicated')
assert.deepEqual(c.effects(), { receipts: 1, adjudications: 1, comments: 1, markers: 1, edits: 1 })
console.log('PASS: a clean result whose findings carry applied dispositions asks for judgment, then completes')

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
  ['interrupted after the body edit', adjudicated, { STUB_GH_FAIL: 'after:edit' }, 2, 'terminal-blocker', { edits: 1 }],
  ['restart adopts its own body edit and completes', adjudicated, {}, 0, 'progress', {}],
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
console.log('PASS: an interruption before or after the receipt, the adjudication, the evidence comment and the body edit is adopted on restart, reaching progress with one evidence comment and one body edit')

// The other half of adoption: an effect this command recorded that the live
// state no longer shows is a stop, never silently redone.
const settledRecord = readFileSync(join(g.dir, 'run.json'), 'utf8')
const settledPass = join(g.dir, 'passes/integration-r1-integrator.json')
const settledAdjudication = join(g.dir, 'adjudications/integration-r1.json')
for (const [what, remove, restore] of [
  ['a receipt', () => renameSync(settledPass, `${settledPass}.gone`), () => renameSync(`${settledPass}.gone`, settledPass)],
  ['an adjudication', () => renameSync(settledAdjudication, `${settledAdjudication}.gone`), () => renameSync(`${settledAdjudication}.gone`, settledAdjudication)],
  ['an evidence comment', () => put(join(g.dir, 'run.json'), { ...JSON.parse(settledRecord), evidence_comments: [] }), () => writeFileSync(join(g.dir, 'run.json'), settledRecord)],
]) {
  remove()
  const gone = expect(g.drive(findings), 2, 'terminal-blocker', `${what} this command recorded is gone`)
  restore()
  assert.match(gone.outcome.next_action.reason, new RegExp(`recorded ${what} for this result, but the run record no longer shows it`))
  assert.deepEqual(g.effects(), seen, `${what} gone: nothing is redone`)
}
expect(g.drive(findings), 0, 'progress', 'the record restored')
console.log('PASS: a recorded receipt, adjudication or evidence comment that the live state no longer shows stops the handoff and redoes nothing')

// The published body is recorded the moment render publish reports it, before
// any further read. A failed read right after the publish, or the driver dying
// there, leaves an effect the restart adopts: progress, with one evidence
// comment and one body edit in total.
for (const how of ['fail', 'kill']) {
  const t = fixture()
  const cut = t.result('collection-late-finding', { patch: (r) => {
    r.payload.unanswered_thread_roots = []
    Object.assign(r.payload.collection, { complete: true, incomplete: [] })
    return r
  } })
  const judged = ['--adjudication', t.adjudication(1, read(cut).payload.findings.map((finding) => finding.id))]
  const once = { receipts: 1, adjudications: 1, comments: 1, markers: 1, edits: 1 }
  expect(t.drive(cut), 10, 'judgment-needed', `${how}: judgment before the handoff`)
  const interrupted = how === 'kill' ? await killAtPublishedRead(t, cut, judged) : t.drive(cut, judged, { STUB_GH_FAIL: 'after-publish:fail' })
  if (how === 'kill') assert.deepEqual([interrupted.status, interrupted.signal, interrupted.stdout], [null, 'SIGKILL', ''], 'the driver died at the first read after the publish')
  else expect(interrupted, 2, 'terminal-blocker', 'the first read after the publish failed')
  assert.deepEqual(t.effects(), once, `${how}: the publish had completed`)
  assert.match(read(join(t.dir, 'drive-handoff.json')).body, /^[0-9a-f]{64}$/, `${how}: the published body was recorded before that read`)
  expect(t.drive(cut, judged), 0, 'progress', `${how}: the restart adopts the published body`)
  assert.deepEqual(t.effects(), once, `${how}: one evidence comment and one body edit in total`)
}
console.log('PASS: a failed read or a death right after a successful publish is adopted on restart, with one evidence comment and one body edit')

const handAdded = '- [ ] added by hand after the interrupted publish'
// Hold the publish command after the real renderer has finished, so SIGKILL
// prevents the driver from recording success while preserving the completion.
const realBash = execFileSync('sh', ['-c', 'command -v bash'], { env: baseEnv, encoding: 'utf8' }).trim()
const renderBin = join(tmp, 'render-bin')
mkdirSync(renderBin)
writeFileSync(join(renderBin, 'bash'), `#!/bin/sh
if [ "$1" = "$HANDOFF_RENDER_ASSET" ] && [ "$2" = publish ]; then
  "$HANDOFF_REAL_BASH" "$@" || exit "$?"
  exec node "$HANDOFF_TREE" completed "$HANDOFF_RENDER_COMPLETE" "$HANDOFF_PROBE_MS"
fi
exec "$HANDOFF_REAL_BASH" "$@"
`, { mode: 0o755 })
{
  const t = fixture()
  const cut = t.result('collection-late-finding', { patch: (r) => {
    r.payload.unanswered_thread_roots = []
    Object.assign(r.payload.collection, { complete: true, incomplete: [] })
    return r
  } })
  const judged = ['--adjudication', t.adjudication(1, read(cut).payload.findings.map((finding) => finding.id))]
  const probe = join(tmp, 'kill-before-driver-records-publish')
  const release = `${probe}.release`
  const rendered = `${probe}.rendered`
  const lock = join(t.dir, '.publish-lock')
  const reservation = join(t.dir, '.publish-state.json')
  const completion = join(t.dir, '.publish-completion.json')
  const driverState = join(t.dir, 'drive-handoff.json')
  const once = { receipts: 1, adjudications: 1, comments: 1, markers: 1, edits: 1 }
  let pending
  await probeDriver(t, cut, probe, {
    PATH: `${renderBin}:${t.env.PATH}`, HANDOFF_PROBE_FILE: probe, HANDOFF_PROBE_MS: '60000', HANDOFF_TREE: tree,
    STUB_EDIT_RELEASE: release, HANDOFF_REAL_BASH: realBash, HANDOFF_RENDER_ASSET: join(support, 'render-dev-flow.sh'), HANDOFF_RENDER_COMPLETE: rendered,
  }, async ({ driver, exited }) => {
    let held
    try {
      assert.equal(t.effects().edits, 0, 'the edit is in flight and has not landed')
      pending = read(reservation)
      assert.equal(pending.reservation_id, read(driverState).publish_id)
      writeFileSync(release, '')
      await waitFor(() => existsSync(rendered), 'the real renderer exited successfully')
      held = read(rendered).pid
      assert.ok(existsSync(completion) && !existsSync(lock) && !existsSync(reservation), 'the renderer published its completion and retired its pending state')
      assert.equal(read(driverState).body, undefined, 'the driver is still waiting for the command to return')
      process.kill(driver.pid, 'SIGKILL')
      const interrupted = await exited
      assert.deepEqual([interrupted.status, interrupted.signal, interrupted.stdout], [null, 'SIGKILL', ''])
      await waitFor(() => !running(held), 'the watchdog stopped the held publish command')
    } finally {
      cleanup(held)
    }
  }, { extra: judged, commandTimeout: 60_000 })
  const interruptedState = read(driverState)
  assert.equal(interruptedState.body, undefined, 'the driver never recorded renderer success')
  assert.deepEqual(t.effects(), once)
  const proof = read(completion)
  for (const [label, replacement] of [
    ['no completion', null],
    ['another run', { run_id: 'run-999-other' }],
    ['another reservation', { reservation_id: 'f'.repeat(32) }],
    ['another head', { head: t.base }],
    ['another body digest', { body_fingerprint: '0'.repeat(64) }],
  ]) {
    if (replacement) put(completion, { ...proof, ...replacement })
    else rmSync(completion)
    expect(t.drive(cut, judged), 14, 'terminal-blocker', `kill-during-render restart with ${label}`)
    assert.deepEqual(t.effects(), once, `${label}: no further write`)
  }
  // With no completion, each reservation describes the exact live body but
  // lacks the interrupted driver's run or reservation identity.
  rmSync(completion)
  for (const [label, replacement] of [
    ['a pending reservation from another run', { run_id: 'run-999-other' }],
    ['a pending reservation with another id', { reservation_id: 'f'.repeat(32) }],
    ['a pending reservation without an id', { reservation_id: undefined }],
  ]) {
    put(reservation, { ...pending, ...replacement })
    expect(t.drive(cut, judged), 14, 'terminal-blocker', `kill-during-render restart with ${label}`)
    assert.deepEqual(t.effects(), once, `${label}: no further write`)
  }
  rmSync(reservation)

  put(completion, proof)
  for (const [label, hasReservation] of [
    ['matching completion alone', false],
    ['matching completion and pending reservation', true],
  ]) {
    put(driverState, interruptedState)
    if (hasReservation) put(reservation, pending)
    expect(t.drive(cut, judged), 0, 'progress', `kill-during-render restart with ${label}`)
    assert.ok(!existsSync(reservation), `${label}: the reservation is retired after progress`)
    assert.equal(read(driverState).publish_id, undefined, `${label}: the driver retires its publish id after success`)
    assert.deepEqual(t.effects(), once, `${label}: one edit and one evidence comment`)
  }

  // The finished driver has no pending ID. A standalone same-run publish
  // can leave an ID-less reservation, but its digest is not the driver's.
  t.edit((d) => { d.pr.body = d.pr.body.replace('<!-- dev-flow:end:deferred-findings -->', `${handAdded}\n<!-- dev-flow:end:deferred-findings -->`) })
  const foreignBody = t.github().pr.body
  assert.ok(foreignBody.includes(handAdded))
  put(reservation, { ...pending, reservation_id: undefined, intended_fingerprint: createHash('sha256').update(foreignBody, 'utf8').digest('hex') })
  expect(t.drive(cut, judged), 14, 'terminal-blocker', 'completed driver refuses a same-run reservation without an id')
  assert.equal(t.github().pr.body, foreignBody, 'the hand-added line is preserved')
  assert.deepEqual(t.effects(), once, 'the foreign reservation cannot cause a second edit')
}
console.log('PASS: kill-during-render restart adopts only the matching completion, with one evidence comment and one edit')

// An old pin could have landed the edit and left a reservation before the
// driver and renderer recorded their run and reservation identities.
{
  const t = fixture()
  const cut = t.result('collection-clean-stable-head')
  const reservation = join(t.dir, '.publish-state.json')
  const lock = join(t.dir, '.publish-lock')
  const driverState = join(t.dir, 'drive-handoff.json')
  const once = { ...NONE, receipts: 1, edits: 1 }
  expect(t.drive(cut, [], { STUB_GH_FAIL: 'after:edit' }), 2, 'terminal-blocker', 'the old publish stopped after landing its edit')
  put(reservation, { ...read(reservation), run_id: undefined, reservation_id: undefined })
  put(driverState, { ...read(driverState), publish_id: undefined })
  const legacy = read(reservation)
  let publishId
  writeFileSync(lock, 'other renderer')
  try {
    const blocked = expect(t.drive(cut), 2, 'terminal-blocker', 'the first upgraded publish encounters a held lock')
    assert.match(blocked.outcome.next_action.reason, /concurrent-publish/)
    publishId = read(driverState).publish_id
    assert.match(publishId, /^[0-9a-f]{32}$/)
    assert.deepEqual(read(reservation), legacy, 'the blocked renderer leaves the old reservation')
    assert.deepEqual(t.effects(), once, 'the blocked retry does not edit the PR')
  } finally {
    rmSync(lock)
  }
  expect(t.drive(cut), 0, 'progress', 'legacy reservation survives a failed renderer call and a recorded driver id')
  assert.ok(!existsSync(reservation), 'the successful retry retires the old reservation')
  const completion = read(join(t.dir, '.publish-completion.json'))
  assert.deepEqual(completion, { ...legacy, run_id: t.runId, reservation_id: publishId, body_fingerprint: legacy.intended_fingerprint },
    'legacy completion binds to the saved driver id')
  assert.deepEqual(t.effects(), once, 'one edit across the interruption and both retries')
}
console.log('PASS: a legacy reservation survives a failed upgraded renderer call and is retired on retry with one edit')

// The same interruption after a publish that merged over someone else's edit
// outside the managed sections: the recorded body digest matches the live
// body, but the text outside the sections is not what was read before the
// edit, so the restart is the stale stop and the foreign text is kept.
for (const how of ['fail', 'kill']) {
  const u = fixture()
  const merged = u.result('collection-clean-stable-head')
  const stubs = { STUB_GH_INTERLEAVE: 'body' }
  const interrupted = how === 'kill' ? await killAtPublishedRead(u, merged, [], stubs) : u.drive(merged, [], { ...stubs, STUB_GH_FAIL: 'after-publish:fail' })
  if (how === 'kill') assert.deepEqual([interrupted.status, interrupted.signal], [null, 'SIGKILL'])
  else expect(interrupted, 2, 'terminal-blocker', 'the read after a publish that merged over a foreign edit failed')
  const body = u.github().pr.body
  assert.match(body, /^Someone else wrote this\./, 'the foreign text is in the live body')
  assert.equal(createHash('sha256').update(body, 'utf8').digest('hex'), read(join(u.dir, 'drive-handoff.json')).body, `${how}: the recorded digest is the live body's`)
  const kept = expect(u.drive(merged), 14, 'terminal-blocker', `${how}: restart over a body merged with a foreign edit`)
  assert.match(kept.outcome.next_action.reason, /review activity is [0-9a-f]{64}, not the result's final snapshot/)
  assert.equal(u.github().pr.body, body, `${how}: the foreign text is kept`)
  assert.equal(u.effects().edits, 1, `${how}: no second edit`)
}
console.log('PASS: a restart never adopts a body the publish merged over a foreign edit outside the managed sections')

// A credential-shaped string quoted in a finding and in its adjudication is
// redacted in the evidence comment, the JSON as well as the table, so the
// publication scanner does not refuse the round.
const v = fixture()
const quoted = v.result('collection-late-finding', { patch: (r) => {
  r.payload.unanswered_thread_roots = []
  r.payload.findings[0].body = `the log prints ${SECRET} in clear`
  Object.assign(r.payload.collection, { complete: true, incomplete: [] })
  return r
} })
const quotedIds = read(quoted).payload.findings.map((finding) => finding.id)
const quotedAdjudication = v.adjudication(1, quotedIds)
put(quotedAdjudication, { ...read(quotedAdjudication), adjudications: read(quotedAdjudication).adjudications.map((entry) => ({ ...entry, evidence: `change.txt:1 echoes ${SECRET}` })) })
expect(v.drive(quoted), 10, 'judgment-needed', 'a finding that quotes a credential-shaped string')
expect(v.drive(quoted, ['--adjudication', quotedAdjudication]), 0, 'progress', 'evidence with a credential-shaped string')
const posted = v.github().comments[v.n][0].body
assert.ok(!posted.includes(SECRET), 'the posted evidence does not contain the string')
assert.ok(posted.split('```json')[1].includes('[REDACTED:fixture-token]'), 'the evidence JSON carries the placeholder')
assert.ok(JSON.parse(posted.split('```json\n')[1].split('\n```')[0]).passes[0].payload.findings.length === 1, 'the redacted JSON still parses and keeps the finding')
console.log('PASS: a credential-shaped string in a finding is redacted in the evidence comment before it is posted')

// The restart adopts an interrupted body edit only when the live body is
// exactly the body that publish intended and nothing else moved. A comment
// that landed in between, or a line someone added inside the managed markers,
// is the stale stop: the body is not adopted, not rendered over, not edited
// again.
for (const [label, land] of [
  ['someone else\'s comment', (d, s) => { d.comments[s.PR] = [{ id: 901, user: { id: 9, login: 'reviewer' }, body: 'landed before the restart', created_at: d.now, updated_at: d.now }] }],
  ['a line hand-added inside the managed markers', (d) => { d.pr.body = d.pr.body.replace('<!-- dev-flow:end:deferred-findings -->', `${handAdded}\n<!-- dev-flow:end:deferred-findings -->`) }],
]) {
  const h = fixture()
  const first = h.result('collection-clean-stable-head')
  expect(h.drive(first, [], { STUB_GH_FAIL: 'after:edit' }), 2, 'terminal-blocker', 'interrupted after the body edit')
  h.edit((d) => land(d, h))
  const body = h.github().pr.body
  const notOwn = expect(h.drive(first), 14, 'terminal-blocker', `restart after an interrupted edit and ${label}`)
  assert.match(notOwn.outcome.next_action.reason, /review activity is [0-9a-f]{64}, not the result's final snapshot/)
  assert.equal(h.github().pr.body, body, `${label}: the live body is left exactly as it was`)
  assert.equal(body.split('<!-- dev-flow:begin:deferred-findings -->').length, 2, 'one managed section')
  assert.deepEqual(h.effects(), { ...NONE, receipts: 1, edits: 1 }, `${label}: the body is edited once`)
}
console.log('PASS: a restart adopts only the exact body its interrupted publish intended; a comment or a hand-added line inside the markers is a blocker and the body is left intact')

// An incomplete collection that asks for judgment is retained, adjudicated and
// evidenced, never reaches progress, and never edits the PR body. Once its
// adjudication is recorded, no outcome asks for that decision again: the
// answer is what the collection still owes.
const waitOn = (event) => ({ kind: 'wait', event, responsible: 'orchestrator', overdue_after_seconds: 900 })
for (const [owed, trigger, snapshot, code, outcome, rest] of [
  [['replies-owed'], 'late-review', {}, 11, 'waiting', waitOn('replies-owed')],
  [['replies-owed', 'activity-moved'], 'late-review', {}, 12, 'retryable', { kind: 'retry', retry_key: 'integrator-collection', attempt: 1, max_attempts: 2 }],
  [['replies-owed', 'activity-moved'], 'collection-retry', {}, 13, 'terminal-blocker', { kind: 'stop', reason: 'Collection retry spent: replies-owed, activity-moved' }],
  [['replies-owed', 'head-moved'], 'late-review', { head: 'a'.repeat(40) }, 13, 'terminal-blocker', { kind: 'stop', reason: 'Collection stopped: replies-owed, head-moved' }],
]) {
  const m = fixture()
  const partial = m.result('collection-late-finding', { snapshot, patch: (r) => { Object.assign(r.payload.collection, { incomplete: owed, trigger }); return r } })
  const own = read(partial).payload.collection.next_action
  const partialIds = read(partial).payload.findings.map((finding) => finding.id)
  const settled = { receipts: 1, adjudications: 1, comments: 1, markers: 1, edits: 0 }
  for (const [label, extra, expected, expectedOutcome, action, effects] of [
    ['retained, judgment owed', [], 10, 'judgment-needed', own, { ...NONE, receipts: 1 }],
    ['adjudicated and evidenced', ['--adjudication', m.adjudication(1, partialIds)], code, outcome, rest, settled],
    ['rerun', [], code, outcome, rest, settled],
  ]) {
    const title = `incomplete ${owed.join('+')} (${trigger}), ${label}`
    const r = expect(m.drive(partial, extra), expected, expectedOutcome, title)
    assert.deepEqual(r.outcome.next_action, action, `${title}: next_action`)
    assert.deepEqual(refs(r, 'review'), partialIds, `${title}: the outcome carries the finding set`)
    assert.deepEqual(m.effects(), effects, `${title}: effects`)
  }
}
console.log('PASS: an incomplete collection never reaches progress, and once adjudicated is never asked for that judgment again')

// Activity that lands while the body is published is never taken as the
// driver's own: the expected value is derived from the pre-publish read.
for (const [landing, reason] of [['comment', /review activity moved while the PR body was published/], ['body', /not the pre-publish body with only this command's managed sections changed/]]) {
  const p = fixture()
  const landed = p.result('collection-clean-stable-head')
  const caught = expect(p.drive(landed, [], { STUB_GH_INTERLEAVE: landing }), 14, 'terminal-blocker', `a ${landing} lands during the publish`)
  assert.match(caught.outcome.next_action.reason, reason)
  assert.equal(read(join(p.dir, 'drive-handoff.json')).body, undefined, `${landing}: no published body stays recorded as this command's own`)
  expect(p.drive(landed), 14, 'terminal-blocker', `restart after a ${landing} landed during the publish`)
  assert.equal(p.effects().edits, 1, `${landing}: the body is edited once`)
}
// The same holds when the body is already current and the publish changes nothing.
const q = fixture()
const current = q.result('collection-clean-stable-head')
expect(q.drive(current), 0, 'progress', 'a handoff that leaves the body current')
const probe = expect(q.drive(current, [], { STUB_GH_INTERLEAVE: 'view' }), 14, 'terminal-blocker', 'a review lands during a publish that changes nothing')
assert.match(probe.outcome.next_action.reason, /review activity moved while the PR body was published/)
assert.equal(q.effects().edits, 1, 'the unchanged publish edits nothing')
// A push that lands after render publish's last head check, on either branch,
// is a moved head: never progress on a stale head.
for (const [landing, prepare] of [['push-after-write', () => {}], ['push-after-read', (s, file) => expect(s.drive(file), 0, 'progress', 'a handoff that leaves the body current')]]) {
  const s = fixture()
  const pushed = s.result('collection-clean-stable-head')
  prepare(s, pushed)
  const stale = expect(s.drive(pushed, [], { STUB_GH_INTERLEAVE: landing }), 14, 'terminal-blocker', `${landing}: a push lands after the publish's last head check`)
  assert.match(stale.outcome.next_action.reason, new RegExp(`the PR head is ${s.base}, not the result's head ${s.head}`))
  assert.equal(s.effects().edits, 1, `${landing}: the body is edited once`)
}
console.log('PASS: a review, a foreign body edit or a push landing during the publish is a blocker, never progress or own activity, whether or not the publish changes the body')

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
