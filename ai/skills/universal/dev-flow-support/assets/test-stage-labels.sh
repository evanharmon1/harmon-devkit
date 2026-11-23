#!/usr/bin/env bash
# Behavioral projection tests. In-memory and CLI doubles; no live writes.
set -euo pipefail
asset_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
node --input-type=module - "$asset_dir/stage-labels.mjs" <<'JS'
import assert from 'node:assert/strict'
import { pathToFileURL } from 'node:url'
// Regression: importing from node's stdin entry point must not resolve '-' as a file
// or execute the reconcile CLI while loading the API.
assert.equal(process.argv[1], '-')
const api = await import(pathToFileURL(process.argv[2]))
assert.equal(typeof api.reconcileRecord, 'function')
console.log('PASS: stdin import loads the reconcile API without running the CLI')
const { desiredLabels, reconcileLabels } = api
const record = { outcome: null, pr: null, stage_transitions: [] }
const input = { record, issue: { number: 12, url: 'https://github.com/example/repo/issues/12' }, branch: 'feat/test' }
const objects = {
  issue: { state: 'OPEN', labels: [{ name: 'needs-review' }], closedByPullRequestsReferences: [] },
  '21': { state: 'OPEN', isCrossRepository: false, labels: [] },
  '22': { state: 'OPEN', isCrossRepository: false, labels: [] },
  '23': { state: 'OPEN', isCrossRepository: true, labels: [] },
  '24': { state: 'CLOSED', isCrossRepository: false, labels: [] }
}
let published = false
let fail = false
const gh = (argv) => {
  const [kind, command, target] = argv
  if (kind === 'pr' && command === 'list') return JSON.stringify(published ? [{ number: 21, headRefName: input.branch, isCrossRepository: false }] : [])
  const object = kind === 'issue' ? objects.issue : objects[target]
  assert.ok(object, `unexpected call ${argv}`)
  if (command === 'edit') {
    if (fail) throw new Error('simulated failed GitHub write')
    const add = argv.indexOf('--add-label')
    const remove = argv.indexOf('--remove-label')
    if (add > 0) object.labels.push({ name: argv[add + 1] })
    if (remove > 0) object.labels = object.labels.filter((label) => label.name !== argv[remove + 1])
  }
  return JSON.stringify(object)
}
function transition(stage, expected) {
  record.stage_transitions.push({ stage })
  assert.deepEqual(desiredLabels(record), expected)
  reconcileLabels(input, gh)
  for (const key of published ? ['issue', '21', '22'] : ['issue']) {
    assert.deepEqual(objects[key].labels.map((label) => label.name).filter((name) => name !== 'needs-review').sort(), [...expected].sort())
  }
  assert.ok(objects.issue.labels.some((label) => label.name === 'needs-review'))
}
transition('kickoff', [])
transition('claim', [])
transition('implement', ['stage:implement'])
transition('verify', ['stage:implement', 'verifying'])
transition('challenge', ['stage:challenge'])
transition('implement', ['stage:challenge', 'fixing'])
transition('verify', ['stage:challenge', 'verifying'])
transition('challenge', ['stage:challenge'])
transition('review', ['stage:review'])
transition('security', ['stage:security'])
published = true
objects.issue.closedByPullRequestsReferences = [22, 23, 24].map((number) => ({ number, repository: { owner: { login: 'example' }, name: 'repo' } }))
transition('integration', ['stage:integration'])
transition('implement', ['stage:integration', 'fixing'])
transition('verify', ['stage:integration', 'verifying'])
transition('integration', ['stage:integration'])
assert.deepEqual(objects['23'].labels, [])
assert.deepEqual(objects['24'].labels, [])
// The committed record is unchanged when the projection fails. Retrying repairs
// both a wrong label and a partial mirror without touching needs-review.
record.stage_transitions.push({ stage: 'implement' })
const committed = JSON.stringify(record)
fail = true
assert.throws(() => reconcileLabels(input, gh), /simulated failed/)
assert.equal(JSON.stringify(record), committed)
fail = false
objects['22'].labels.push({ name: 'stage:obsolete' })
reconcileLabels(input, gh)
assert.ok(objects['22'].labels.some((label) => label.name === 'fixing'))
assert.ok(!objects['22'].labels.some((label) => label.name === 'stage:obsolete'))
reconcileLabels({ ...input, handedOff: true }, gh)
assert.deepEqual(objects['21'].labels, [])
objects.issue.labels.push({ name: 'parked' })
reconcileLabels(input, gh)
assert.deepEqual(objects['22'].labels, [])
objects.issue.labels = objects.issue.labels.filter((label) => label.name !== 'parked')
record.outcome = 'abandoned'
reconcileLabels(input, gh)
assert.deepEqual(objects['21'].labels, [])
console.log('test-stage-labels: all cases passed')
JS

# Exercise the real writer and successful advance chain with the real observer.
# Only the external GitHub and gate commands are doubled; no adapter is replaced.
real_path_tmp="$(mktemp -d "${TMPDIR:-/tmp}/stage-labels-real.XXXXXX")"
trap 'rm -rf "$real_path_tmp"' EXIT
node --input-type=module - "$asset_dir" "$real_path_tmp" <<'JS'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdirSync, chmodSync, cpSync } from 'node:fs'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
const [originalAssets, tmp] = process.argv.slice(2)
const source = join(originalAssets, '../../../../..')
// Use the real portable consumer layout, keeping freshness checks intact.
const skills = join(tmp, 'skills')
for (const name of ['dev-flow-support', 'orchestrate', 'review', 'integrate']) cpSync(join(originalAssets, '../..', name), join(skills, name), { recursive: true })
const assets = join(skills, 'dev-flow-support/assets')
assert.equal(readFileSync(join(assets, 'stage-labels.mjs'), 'utf8'), readFileSync(join(originalAssets, 'stage-labels.mjs'), 'utf8'), 'the real-path regression uses the actual projection adapter')
const writer = join(assets, 'run-record.mjs')
const advance = join(assets, 'advance-to-integration.sh')
const bin = join(tmp, 'bin')
mkdirSync(bin)
writeFileSync(join(tmp, 'gitconfig'), '')
writeFileSync(join(bin, 'task'), '#!/usr/bin/env bash\ncase "$1" in security) exit "${STAGE_LABEL_TEST_SECURITY:-0}" ;; guard:closing-keywords) exit 0 ;; *) exit 200 ;; esac\n')
writeFileSync(join(bin, 'gh'), `#!/usr/bin/env node
const fs = require('node:fs'), args = process.argv.slice(2)
const file = process.env.STAGE_LABEL_TEST_STATE
fs.appendFileSync(file + '.calls', JSON.stringify(args) + '\\n')
const state = JSON.parse(fs.readFileSync(file, 'utf8'))
const [kind, command, target] = args
const fail = (code) => { fs.appendFileSync(file + '.failures', JSON.stringify({ args, code }) + '\\n'); process.exit(code) }
if (kind === 'issue' && command === 'view') {
  if (process.env.STAGE_LABEL_TEST_MODE === 'unavailable') {
    console.error('projection endpoint unavailable'); fail(127)
  }
  console.log(JSON.stringify(state.issue)); process.exit(0)
}
if (kind === 'pr' && command === 'list') { console.log(JSON.stringify(state.prs)); process.exit(0) }
if (kind === 'pr' && command === 'create') {
  if (!args.includes('--draft')) process.exit(9)
  const pr = { number: 7, url: 'https://github.com/example/repo/pull/7', state: 'OPEN', isDraft: true,
    headRefOid: process.env.STAGE_LABEL_TEST_HEAD, headRefName: process.env.STAGE_LABEL_TEST_BRANCH,
    headRepository: { name: 'repo' }, headRepositoryOwner: { login: 'example' }, isCrossRepository: false, labels: [] }
  state.prs.push(pr); fs.writeFileSync(file, JSON.stringify(state)); console.log(pr.url); process.exit(0)
}
const object = kind === 'issue' ? state.issue : state.prs.find((pr) => String(pr.number) === target || pr.url === target)
if (!object) process.exit(3)
if (command === 'edit') {
  if (process.env.STAGE_LABEL_TEST_MODE === 'failed') {
    console.error('projection write failed'); fail(42)
  }
  const add = args.indexOf('--add-label'), remove = args.indexOf('--remove-label')
  if (add > 0) object.labels.push({ name: args[add + 1] })
  if (remove > 0) object.labels = object.labels.filter((label) => label.name !== args[remove + 1])
  fs.writeFileSync(file, JSON.stringify(state))
}
console.log(JSON.stringify(object))
`)
for (const name of ['task', 'gh']) chmodSync(join(bin, name), 0o755)
const baseEnv = { ...process.env, PATH: `${bin}:${process.env.PATH}`, GIT_CONFIG_GLOBAL: join(tmp, 'gitconfig'), GIT_CONFIG_NOSYSTEM: '1' }
for (const key of Object.keys(baseEnv)) {
  if (key === 'RUN_RECORD_OWNER_TOKEN' || /^GIT_(DIR|WORK_TREE|INDEX_FILE|COMMON_DIR|OBJECT_DIRECTORY|ALTERNATE_OBJECT_DIRECTORIES|PREFIX|CONFIG_(COUNT|PARAMETERS|KEY_.*|VALUE_.*))$/.test(key)) delete baseEnv[key]
}
const read = (file) => JSON.parse(readFileSync(file, 'utf8'))
const put = (file, value) => writeFileSync(file, `${JSON.stringify(value)}\n`)
const results = []
for (const [index, mode] of ['available', 'failed', 'unavailable'].entries()) {
  const number = index + 1, repo = join(tmp, `repo${number}`), remote = join(tmp, `remote${number}.git`)
  const branch = `projection-${mode}`, runId = `run-${number}-projection`, slate = `solo-${runId}`
  const stateFile = join(tmp, `github${number}.json`)
  put(stateFile, { issue: { state: 'OPEN', labels: [], closedByPullRequestsReferences: [] }, prs: [] })
  writeFileSync(`${stateFile}.failures`, '')
  const env = { ...baseEnv, STAGE_LABEL_TEST_MODE: mode, STAGE_LABEL_TEST_STATE: stateFile, STAGE_LABEL_TEST_BRANCH: branch }
  mkdirSync(repo)
  const run = (cmd, args, extraEnv = {}) => spawnSync(cmd, args, { cwd: repo, env: { ...env, ...extraEnv }, encoding: 'utf8' })
  const ok = (cmd, args, extraEnv) => {
    const result = run(cmd, args, extraEnv)
    assert.equal(result.status, 0, `${mode}: ${cmd} failed: ${result.stdout}${result.stderr}`)
    return result.stdout.trim()
  }
  const git = (...args) => ok('git', args)
  git('init', '-q', '-b', 'main')
  for (const [key, value] of [['user.name', 'Test'], ['user.email', 'test@example.invalid'], ['commit.gpgsign', 'false']]) git('config', key, value)
  const registry = read(join(source, 'agent-registry.json'))
  registry.trusted_orchestrator_actor_ids = [12345]
  put(join(repo, 'agent-registry.json'), registry)
  // A real disabled-confidence fixture exercises the successful advance path
  // without inventing model receipts or invoking any model.
  const original = readFileSync(join(source, '.devflow.toml'), 'utf8')
  const policy = original.replace(/(\[rounds\.thorough\][^[]*?)challenge\s*=\s*4([^[]*?)review\s*=\s*4([^[]*?)integration\s*=\s*5([^[]*?)min_rounds\s*=\s*1/, '$1challenge = 0$2review = 0$3integration = 0$4min_rounds = 0')
  assert.notEqual(policy, original)
  writeFileSync(join(repo, '.devflow.toml'), policy)
  git('add', '.'); git('commit', '-qm', 'initial')
  const base = git('rev-parse', 'HEAD')
  git('remote', 'add', 'origin', 'https://github.com/example/repo')
  git('update-ref', 'refs/remotes/origin/main', base)
  git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
  git('init', '-q', '--bare', remote)
  git('switch', '-qc', branch)
  writeFileSync(join(repo, 'change.txt'), 'fixture\n')
  git('add', '.'); git('commit', '-qm', 'feat: fixture')
  const head = git('rev-parse', 'HEAD')
  env.STAGE_LABEL_TEST_HEAD = head
  git('push', '-q', remote, `HEAD:refs/heads/${branch}`)
  const resolved = run(process.execPath, [join(assets, 'devflow-policy.mjs'), 'resolve', '--policy', join(repo, '.devflow.toml'), '--registry', join(repo, 'agent-registry.json'), '--json', '--rigor', 'thorough'])
  assert.ok([0, 3].includes(resolved.status) && resolved.stdout.trim(), resolved.stderr)
  const policyFile = join(tmp, `policy${number}.json`)
  writeFileSync(policyFile, resolved.stdout)
  assert.deepEqual(['challenge', 'review', 'integration'].map((stage) => read(policyFile).rounds[stage]), [0, 0, 0])
  const token = ok(process.execPath, [writer, 'lock', 'acquire', '--slate', slate, '--session', 'fixture', '--issues', String(number)])
  const owner = { RUN_RECORD_OWNER_TOKEN: token }
  const identity = JSON.parse(ok(process.execPath, [writer, 'solo-init', '--session', 'fixture', '--run-id', runId, '--issue', String(number), '--title', 'fixture', '--url', `https://github.com/example/repo/issues/${number}`, '--branch', branch, '--base', base, '--policy', policyFile, '--actor-id', '12345', '--strategy-source', 'default_strategy'], owner))
  const args = ['--slate', slate, '--session', 'fixture', '--run-id', runId]
  ok(process.execPath, [writer, 'transition', ...args, '--stage', 'claim'], owner)
  ok(process.execPath, [writer, 'transition', ...args, '--stage', 'implement', '--exit', 'fixture done'], owner)
  const verified = run(process.execPath, [writer, 'transition', ...args, '--stage', 'verify', '--exit', 'fixture done'], owner)
  assert.equal(verified.status, 0, `${mode}: observer must not change transition result: ${verified.stderr}`)
  const recordFile = join(identity.record_directory, 'run.json')
  const before = read(recordFile)
  assert.equal(before.stage_transitions.at(-1).stage, 'verify', 'the real transition committed despite projection failure')
  const transition = before.stage_transitions.slice(-3).map(({ entered_at, ...entry }) => entry)
  const calls = () => readFileSync(`${stateFile}.calls`, 'utf8').trim().split('\n').map((line) => JSON.parse(line))
  const failures = () => readFileSync(`${stateFile}.failures`, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line))
  const body = join(tmp, `body${number}.md`)
  writeFileSync(body, `Refs #${number}\n`)
  const advanceEnv = {
    ...owner, GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: `url.${remote}.insteadOf`, GIT_CONFIG_VALUE_0: 'https://github.com/example/repo',
  }
  const advanceArgs = [advance, '--repo', 'example/repo', ...args, '--title', 'feat: fixture', '--body-file', body]
  const blocked = run('bash', advanceArgs, { ...advanceEnv, STAGE_LABEL_TEST_SECURITY: '9' })
  assert.equal(blocked.status, 3, `${mode}: failed security must still block advance: ${blocked.stdout}${blocked.stderr}`)
  const blockedOutcome = JSON.parse(blocked.stdout)
  assert.equal(blockedOutcome.outcome, 'terminal-blocker')
  assert.equal(read(recordFile).stage_transitions.at(-1).stage, 'security')
  assert.equal(read(recordFile).pr, null, 'a failing security gate never binds a PR')
  assert.equal(read(stateFile).prs.length, 0, 'a failing security gate never publishes a PR')
  const count = calls().length, failedCount = failures().length
  const advanced = run('bash', advanceArgs, advanceEnv)
  assert.equal(advanced.status, 11, `${mode}: real advance must enter integration: ${advanced.stdout}${advanced.stderr}`)
  const outcome = JSON.parse(advanced.stdout)
  assert.equal(outcome.outcome, 'progress')
  assert.equal(outcome.head, head)
  const after = read(recordFile)
  assert.deepEqual(after.stage_transitions.map((entry) => entry.stage), ['kickoff', 'claim', 'implement', 'verify', 'security', 'integration'])
  assert.deepEqual(after.pr, { number: 7, url: 'https://github.com/example/repo/pull/7' })
  const duringAdvance = calls().slice(count)
  if (mode === 'available') {
    assert.doesNotMatch(`${verified.stderr}${advanced.stderr}`, /stage-labels: record committed; projection failed/)
  } else {
    assert.match(verified.stderr, /stage-labels: record committed; projection failed/)
    const operation = mode === 'failed' ? 'edit' : 'view'
    assert.ok(duringAdvance.some(([kind, command]) => kind === 'issue' && command === operation), `${mode}: the real adapter ran inside advance`)
    assert.ok(failures().length > failedCount, `${mode}: the real adapter encountered an external failure inside successful advance`)
    assert.ok(failures().slice(failedCount).every(({ code }) => code === (mode === 'failed' ? 42 : 127)))
  }
  const { run: binding, head: capturedHead, ...semanticOutcome } = outcome
  assert.equal(binding.run_id, runId)
  assert.equal(capturedHead, head)
  const { run: blockedBinding, head: blockedHead, ...semanticBlockedOutcome } = blockedOutcome
  assert.equal(blockedBinding.run_id, runId)
  assert.equal(blockedHead, head)
  results.push({ transition, semanticBlockedOutcome, semanticOutcome })
  console.log(`PASS: real writer, blocked advance, and successful advance preserve their result with ${mode} projection`)
}
assert.deepEqual(results[1], results[0], 'failed projection changes neither committed transition nor advance outcome')
assert.deepEqual(results[2], results[0], 'unavailable projection changes neither committed transition nor advance outcome')
JS
