#!/usr/bin/env bash
# Exercise the composed lane provisioning command in disposable repositories.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/provision-lane-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

node --input-type=module - "$asset_dir" "$tmp" <<'NODE'
import assert from 'node:assert/strict'
import { execFileSync, spawn, spawnSync } from 'node:child_process'
import { chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const [assets, temporary] = process.argv.slice(2)
// Imported CLI guards expect argv[1] to name a real path, unlike stdin's '-'.
process.argv[1] = temporary
const support = resolve(assets, '../../dev-flow-support/assets')
const writer = join(support, 'run-record.mjs')
const validator = join(support, 'validate-result-schemas.mjs')
const command = join(assets, 'provision-lane.mjs')
const { chainDigest } = await import(writer)
const { buildBriefValues, renderBrief, assertDisjointFences } = await import(join(assets, 'lane-brief-values.mjs'))
const { resolvePolicy, validateResolvedPolicy } = await import(join(support, 'devflow-policy.mjs'))
const { parseToml } = await import(join(support, 'lib/toml-lite.mjs'))
const policySource = readFileSync(resolve(assets, '../../../../../.devflow.toml'), 'utf8')
const resolvedPolicy = resolvePolicy(parseToml(policySource), { rigor: 'thorough', rigorSource: 'operator', tierOverrides: { implementer: 'frontier' } })
for (const ceiling of [{ max_tokens: 100 }, { max_usd: 1 }]) {
  const configured = parseToml(policySource)
  configured.rigor.thorough.spend = 'fixture'
  configured.spend = { fixture: ceiling }
  assert.doesNotThrow(() => validateResolvedPolicy(resolvePolicy(configured, { rigor: 'thorough' })))
}
// Live GitHub state is a controlled external boundary in these disposable repos.
const bin = join(temporary, 'bin')
mkdirSync(bin)
const gh = join(bin, 'gh')
writeFileSync(gh, `#!/usr/bin/env node
const fs = require('node:fs')
const path = require('node:path')
let cwd = process.cwd()
while (!fs.existsSync(path.join(cwd, '.git'))) cwd = path.dirname(cwd)
const file = path.join(cwd, 'github.json')
const states = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file)) : {}
const [kind, , url] = process.argv.slice(2)
if (states[url] === 'unavailable') process.exit(1)
console.log(JSON.stringify(states[url] ?? (kind === 'issue' ? { state: 'OPEN', labels: [{ name: 'claim:gpt' }] } : { state: 'OPEN' })))
`)
chmodSync(gh, 0o755)
process.env.PATH = bin + ':' + process.env.PATH
const at = '2026-10-20T06:00:00Z'
const policy = {
  rigor: 'thorough', rigor_source: 'explicit operator input (fixture maintainer)',
  caps: { challenge: 4, review: 4, integration: 5, remediation: 5, min_rounds: 1, wall_clock_min: 60 },
  breadth: { max_agent_runs: 12, max_parallel_agents: 4 },
  strategy: 'plan', strategy_source: 'default_strategy',
  role_tiers: { orchestrator: 'apex', implementer: 'frontier', challenger: 'apex', reviewer: 'frontier', integrator: 'economy' },
  operator_pins: ['maintainer fixture pin'],
}
function git(repo, ...args) {
  return execFileSync('git', args, { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
}
function node(repo, file, args) {
  return execFileSync(process.execPath, [file, ...args], { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
}
function snapshot(root) {
  const entries = []
  const walk = (dir, prefix = '') => {
    if (!existsSync(dir)) return
    for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const name = `${prefix}${entry.name}`
      entries.push(entry.isDirectory() ? `${name}/` : `${name}:${readFileSync(join(dir, entry.name)).toString('base64')}`)
      if (entry.isDirectory()) walk(join(dir, entry.name), `${name}/`)
    }
  }
  walk(root)
  return entries
}
let serial = 0
function fixture(maxInFlight, parallel = 4) {
  const selectedPolicy = structuredClone(policy)
  selectedPolicy.breadth.max_parallel_agents = parallel
  if (maxInFlight !== undefined) selectedPolicy.breadth.max_in_flight = maxInFlight
  const repo = join(temporary, `repo-${++serial}`)
  mkdirSync(repo)
  git(repo, 'init', '-q', '-b', 'lane-one')
  writeFileSync(join(repo, 'agent-registry.json'), JSON.stringify({ trusted_orchestrator_actor_ids: [1] }))
  git(repo, 'add', 'agent-registry.json')
  git(repo, '-c', 'user.name=test', '-c', 'user.email=test@example.test', 'commit', '-qm', 'fixture')
  const base = git(repo, 'rev-parse', 'HEAD')
  git(repo, 'update-ref', 'refs/remotes/origin/main', base)
  git(repo, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
  const root = join(repo, '.git/dev-flow-v2')
  const token = node(repo, writer, ['lock', 'acquire', '--slate', 's', '--session', 'owner', '--issues', '1'])
  const lane = { lane: 'l1', issue: 1, wave: 1, branch: 'lane-one', run_id: 'run-one',
    fence: [{ path: 'src/one', note: 'owned section' }], expansions: [] }
  const plan = {
    base_sha: base, policy: selectedPolicy,
    lane_profiles: [{ lane: 'l1', policy: { ...selectedPolicy, caps: { ...selectedPolicy.caps, wall_clock_min: 90 } } }],
    dispatcher: { kind: 'interactive', parallel_cap: parallel, foreman_max_parallel: null },
    issues: [{ number: 1, title: 'Support {{branch}} and `quotes`', url: 'https://example.test/issues/1', verdict: 'valid', candidate_files: ['src/one'], blocked_by: [] }],
    overlaps: [], waves: [{ number: 1, issues: [1] }], lanes: [lane],
  }
  const facts = {
    worktree_path: repo, harness: 'codex-cli', harness_text: 'Codex CLI', effort: 'high',
    codex_model_id: 'fixture-model', codex_launch_flags: '-s workspace-write', scratch_dir: temporary,
    repo_tier: 'heavy', gate_bounds_override: 'None.', gate_commands: 'task check; task verify',
    git_sandbox_note: 'Fixture only.', known_environmental_failure: 'None.', unit_kind: 'implementation',
    pr_title: 'feat(orchestrate): fixture', verified_facts_and_rulings: 'An inserted {{branch}} remains literal.',
    claim_handoff: { comment_id: 1, author_id: 1, updated_at: at, assignees: ['owner'], labels: [], branch: lane.branch },
  }
  const planFile = join(root, 'slates/s/plan.json')
  const factsFile = join(repo, 'facts.json')
  const policyFile = join(repo, 'resolved-policy.json')
  mkdirSync(join(root, 'slates/s'), { recursive: true })
  const revisions = []
  function publish() {
    const seq = revisions.length
    const prev_digest = revisions.at(-1)?.digest ?? 'genesis'
    const content = { seq, at, reason: `fixture revision ${seq}`, plan: structuredClone(plan) }
    revisions.push({ ...content, prev_digest, digest: chainDigest(content, prev_digest) })
    writeFileSync(planFile, JSON.stringify({ schema: 1, slate_id: 's', revisions }))
    execFileSync(process.execPath, [validator, 'plan', planFile], { cwd: repo, stdio: 'inherit' })
  }
  function saveFacts() { writeFileSync(factsFile, JSON.stringify(facts)) }
  publish()
  lane.expansions.push({ path: 'tests/one', at, reason: 'regression test' })
  publish(); saveFacts()
  const args = (name = 'l1') => {
    const profile = plan.lane_profiles?.find((entry) => entry.lane === name)?.policy ?? plan.policy
    const full = structuredClone(resolvedPolicy)
    full.rigor = { ...full.rigor, level: profile.rigor, source: 'operator' }
    full.rounds = { ...full.rounds, ...profile.caps }
    full.breadth = { ...full.breadth, ...profile.breadth, max_in_flight: profile.breadth.max_in_flight ?? profile.breadth.max_parallel_agents }
    full.strategy.name = profile.strategy
    for (const [role, tier] of Object.entries(profile.role_tiers)) full.roles[role].tier = tier
    writeFileSync(policyFile, JSON.stringify(full))
    return ['--slate', 's', '--session', 'owner', '--owner-token', token, '--lane', name,
      '--facts', factsFile, '--policy', policyFile, '--nonce', 'a1', '--at', at]
  }
  return { repo, root, token, lane, plan, facts, planFile, factsFile, policyFile, publish, saveFacts, args }
}
function refusal(f, pattern, file = command, args = f.args()) {
  const before = snapshot(f.root)
  const result = spawnSync(process.execPath, [file, ...args], { cwd: f.repo, encoding: 'utf8' })
  assert.equal(result.status, 1, `expected refusal, got ${result.status}: ${result.stderr}`)
  assert.match(result.stderr, pattern,
    `unexpected refusal output (stdout=${JSON.stringify(result.stdout)}, stderr=${JSON.stringify(result.stderr)})`)
  assert.deepEqual(snapshot(f.root), before, 'refusal changed durable record tree')
  assert.ok(f.token.length > 0, 'fixture owner token must be non-empty')
  assert.ok(!result.stdout.includes(f.token) && !result.stderr.includes(f.token), 'owner token leaked')
}

function capacityFixture(parallel, flight) {
  const f = fixture(flight, parallel)
  f.plan.policy.breadth.max_parallel_agents = parallel
  f.plan.lane_profiles[0].policy.breadth.max_parallel_agents = parallel
  f.plan.dispatcher.parallel_cap = parallel
  f.publish()
  return f
}
function addSecond(f) {
  node(f.repo, writer, ['lock', 'acquire', '--slate', 's', '--session', 'owner', '--owner-token', f.token, '--issues', '1,2'])
  f.plan.issues.push({ number: 2, title: 'second', url: 'https://example.test/issues/2', verdict: 'valid', candidate_files: ['src/two'], blocked_by: [] })
  f.plan.lanes.push({ lane: 'l2', issue: 2, wave: 2, branch: 'lane-two', run_id: 'run-two', fence: ['src/two'], expansions: [] })
  f.plan.lane_profiles.push({ lane: 'l2', policy: structuredClone(f.plan.policy) })
  f.plan.waves.push({ number: 2, issues: [2] })
  f.publish()
  git(f.repo, 'switch', '-q', '-c', 'lane-two')
  f.facts.claim_handoff.branch = 'lane-two'; f.saveFacts()
}
function live(f, state) { writeFileSync(join(f.repo, 'github.json'), JSON.stringify(state)) }
const cappedWorking = capacityFixture(1, 3)
node(cappedWorking.repo, command, cappedWorking.args())
addSecond(cappedWorking)
const duplicateSlate = JSON.parse(readFileSync(cappedWorking.planFile))
duplicateSlate.slate_id = 'another'
mkdirSync(join(cappedWorking.root, 'slates/another'))
writeFileSync(join(cappedWorking.root, 'slates/another/plan.json'), JSON.stringify(duplicateSlate))
refusal(cappedWorking, /max_parallel_agents 1: working 2, in-flight 2/, command, cappedWorking.args('l2'))
live(cappedWorking, { 'https://example.test/issues/1': { state: 'OPEN', labels: [{ name: 'slated' }] } })
node(cappedWorking.repo, command, cappedWorking.args('l2'))
console.log('PASS: working cap refuses independently of in-flight room; released claim frees working slot')

for (const binding of ['issue', 'queue', 'run']) {
  const f = capacityFixture(2, 2)
  const first = JSON.parse(node(f.repo, command, f.args()))
  addSecond(f)
  // A second handed-off delivery occupies the other in-flight slot, but no
  // working slot. The planned second lane is still undispatched.
  node(f.repo, writer, ['lock', 'acquire', '--slate', 's', '--session', 'owner', '--owner-token', f.token, '--issues', '1,2,3'])
  f.plan.issues.push({ number: 3, title: 'delivery', url: 'https://example.test/issues/3', verdict: 'handed-off', candidate_files: [], blocked_by: [], pr: 103 })
  f.plan.merge_queue = [{ issue: 3, pr: 103 }]
  if (binding === 'issue') f.plan.issues[0].pr = 101
  else if (binding === 'queue') {
    f.plan.issues[0].verdict = 'handed-off'
    f.plan.lanes.shift(); f.plan.lane_profiles.shift()
    f.plan.merge_queue.unshift({ issue: 1, pr: 101 })
  } else {
    for (const stage of ['claim', 'implement', 'verify', 'challenge', 'review', 'security', 'integration']) {
      node(f.repo, writer, ['transition', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
        '--run-id', 'run-one', '--stage', stage, ...(stage === 'claim' ? [] : ['--exit', 'fixture gate passed']), '--at', at])
    }
    node(f.repo, writer, ['bind-pr', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
      '--run-id', 'run-one', '--number', '101', '--url', 'https://example.test/pull/101', '--at', at])
  }
  f.publish()
  live(f, { 'https://example.test/issues/1': { state: 'OPEN', labels: [] } })
  refusal(f, /max_in_flight 2: working 1, in-flight 3/, command, f.args('l2'))
  live(f, { 'https://example.test/issues/1': { state: 'OPEN', labels: [] }, 'https://example.test/pull/101': { state: 'MERGED' } })
  node(f.repo, command, f.args('l2'))
  assert.ok(existsSync(join(first.record_directory, 'run.json')))
}
console.log('PASS: issue, queue-only and run PR bindings hold in-flight slots until closed/merged; handoff does not hold a working slot')

const equal = capacityFixture(1, 1)
node(equal.repo, command, equal.args())
addSecond(equal)
node(equal.repo, join(support, 'plan-revise.mjs'), ['handoff', '--slate', 's', '--session', 'owner', '--owner-token', equal.token, '--issue', '1', '--pr', '101', '--reason', 'verified boundary handoff', '--at', at])
node(equal.repo, join(support, 'plan-revise.mjs'), ['wave-release', '--slate', 's', '--session', 'owner', '--owner-token', equal.token, '--wave', '2', '--reason', 'verified boundary handoff', '--at', at])
live(equal, { 'https://example.test/issues/1': { state: 'OPEN', labels: [] } })
refusal(equal, /max_in_flight 1: working 1, in-flight 2/, command, equal.args('l2'))
console.log('PASS: equal-ceiling boundary handoff and released plan validate; only next dispatch refuses')

const legacyCapacity = capacityFixture(1)
node(legacyCapacity.repo, command, legacyCapacity.args())
addSecond(legacyCapacity)
refusal(legacyCapacity, /max_parallel_agents 1/, command, legacyCapacity.args('l2'))
console.log('PASS: legacy profiles remain readable and use the parallel ceiling at dispatch')

const unavailable = fixture()
live(unavailable, { 'https://example.test/issues/1': 'unavailable' })
refusal(unavailable, /indeterminate.*could not read issue/)
live(unavailable, { 'https://example.test/issues/1': { labels: [] } })
refusal(unavailable, /invalid issue state/)
console.log('PASS: failed and incomplete live reads refuse without durable writes')

const racing = capacityFixture(1, 3)
addSecond(racing)
git(racing.repo, 'switch', '-q', 'lane-one')
const secondTree = join(temporary, 'race-second-tree')
git(racing.repo, 'worktree', 'add', '-q', secondTree, 'lane-two')
const firstArgs = racing.args().map((arg) => arg === racing.policyFile ? join(racing.repo, 'first-policy.json') : arg)
writeFileSync(join(racing.repo, 'first-policy.json'), readFileSync(racing.policyFile))
racing.facts.claim_handoff.branch = 'lane-one'; racing.saveFacts()
writeFileSync(join(racing.repo, 'first-facts.json'), readFileSync(racing.factsFile))
firstArgs[firstArgs.indexOf('--facts') + 1] = join(racing.repo, 'first-facts.json')
const secondArgs = racing.args('l2')
racing.facts.worktree_path = secondTree; racing.facts.claim_handoff.branch = 'lane-two'; racing.saveFacts()
function dispatch(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [command, ...args], { cwd: racing.repo })
    let stderr = ''
    child.stdout.resume()
    child.stderr.on('data', (data) => { stderr += data })
    child.on('error', reject)
    child.on('close', (status) => resolve({ status, stderr }))
  })
}
const raced = await Promise.all([dispatch(firstArgs), dispatch(secondArgs)])
assert.deepEqual(raced.map((result) => result.status).sort(), [0, 1])
assert.match(raced.find((result) => result.status === 1).stderr, /max_parallel_agents 1: working 2/)
console.log('PASS: simultaneous provisioners in separate worktrees share one capacity slot')

const f = fixture()
for (const maxInFlight of [undefined, 15]) {
  const plan = structuredClone(f.plan)
  if (maxInFlight !== undefined) plan.lane_profiles[0].policy.breadth.max_in_flight = maxInFlight
  const { values, envelope } = buildBriefValues({ plan, lane: f.lane, facts: f.facts,
    nonce: 'breadth', at, generation: 1, active: '/tmp/active.json', runDir: '/tmp/run', defaultBranch: 'main' })
  assert.equal(envelope.breadth.max_in_flight, maxInFlight ?? 4)
  assert.equal(values['max-in-flight'], String(maxInFlight ?? 4))
  assert.ok(values['policy-projection'].includes(`"max_in_flight":${maxInFlight ?? 4}`))
}
const explicitBreadth = fixture(15)
const explicitArgs = explicitBreadth.args()
const explicitMismatch = JSON.parse(readFileSync(explicitBreadth.policyFile))
explicitMismatch.breadth.max_in_flight = 14
writeFileSync(explicitBreadth.policyFile, JSON.stringify(explicitMismatch))
refusal(explicitBreadth, /does not match the lane profile/, command, explicitArgs)
const explicitResult = JSON.parse(node(explicitBreadth.repo, command, explicitBreadth.args()))
assert.equal(JSON.parse(readFileSync(join(explicitResult.record_directory, 'policy.json'))).breadth.max_in_flight, 15)
const explicitBrief = readFileSync(explicitResult.brief_path, 'utf8')
assert.ok(explicitBrief.includes('"max_in_flight":15'))
node(explicitBreadth.repo, validator, ['brief', explicitResult.brief_path])
console.log('PASS: explicit in-flight ceiling provisions, is rendered and retained; mismatches refuse without writes')

refusal(f, /unknown lane/, command, f.args('missing'))
for (const mutate of [
  (full) => { delete full.tier_order },
  (full) => { full.tier_order.reverse() },
  (full) => { delete full.stages },
  (full) => { delete full.gates },
]) {
  const invalidArgs = f.args()
  const full = JSON.parse(readFileSync(f.policyFile))
  mutate(full)
  writeFileSync(f.policyFile, JSON.stringify(full))
  const initArgs = ['lane-init', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
    '--lane', 'l1', '--policy', f.policyFile, '--at', at]
  refusal(f, /not a complete resolved policy projection/, writer, initArgs)
  refusal(f, /not a complete resolved policy projection/, command, invalidArgs)
}
console.log('PASS: missing/reordered tier order and incomplete stages/gates are refused by lane-init and provisioning with no writes')
const mismatched = f.args()
const badPolicy = JSON.parse(readFileSync(f.policyFile))
badPolicy.roles.challenger.tier = 'economy'
writeFileSync(f.policyFile, JSON.stringify(badPolicy))
refusal(f, /does not match the lane profile/, command, mismatched)
f.facts.claim_handoff.branch = 'wrong-branch'; f.saveFacts()
refusal(f, /rendered lane brief failed/)
f.facts.claim_handoff.branch = f.lane.branch; f.saveFacts()
refusal(f, /owner token does not match/, command, f.args().map((v) => v === f.token ? 'wrong-token' : v))
refusal(f, /candidate refused by.*run.*validation/, command, f.args().map((v) => v === at ? '2026-02-30T06:00:00Z' : v))
const first = JSON.parse(node(f.repo, command, f.args()))
assert.equal(first.generation, 1)
assert.equal(first.record_directory, join(f.root, 'runs/run-one'))
assert.equal(first.brief_path, join(f.root, 'slates/s/orchestrator/run-one/a1/lane-brief.md'))
node(f.repo, validator, ['run', join(first.record_directory, 'run.json'), '--receipts', join(first.record_directory, 'run.json'), '--no-adjudications'])
node(f.repo, validator, ['brief', first.brief_path])
const run = JSON.parse(readFileSync(join(first.record_directory, 'run.json')))
assert.deepEqual(run.receipts, [])
assert.equal(readFileSync(join(first.record_directory, 'owner-slate'), 'utf8').trim(), 's')
const brief = readFileSync(first.brief_path, 'utf8')
assert.ok(brief.includes('An inserted {{branch}} remains literal.'))
assert.ok(brief.includes('Support {{branch}} and'))
assert.ok(brief.includes('2026-10-20T07:30:00Z'), 'lane profile must override slate profile')
assert.ok(brief.includes('tests/one') && brief.includes('owned section'))
const pointer = JSON.parse(readFileSync(first.active_state_path))
assert.equal(pointer.run_id, 'run-one')
const budget = JSON.parse(readFileSync(join(first.record_directory, 'monitor.json'))).agent_run_budget
assert.equal(budget.max_agent_runs, 12)
assert.equal(budget.reservations.length, 1)
assert.equal(budget.reservations[0].event, 'dispatch-l1-a1')
assert.deepEqual(JSON.parse(readFileSync(join(first.record_directory, 'policy.json'))), JSON.parse(readFileSync(f.policyFile)))
for (const stage of ['claim', 'implement', 'verify', 'challenge']) {
  node(f.repo, writer, ['transition', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
    '--run-id', 'run-one', '--stage', stage, ...(stage === 'claim' ? [] : ['--exit', 'fixture gate passed']), '--at', at])
}
const passFile = join(f.repo, 'challenge-pass.json')
const pass = {
  schema: 2, role: 'challenger', status: 'completed', head: f.plan.base_sha,
  produced_at: at, producer: { harness: 'codex-cli', model: 'gpt-6-astra', tier: 'apex' },
  run: { run_id: 'run-one', initiated_by: 'human' },
  payload: { stage: 'challenge', round: 1, reviewed_head: f.plan.base_sha,
    finder: 'codex-adversarial', slot: 'codex-adversarial', findings: [],
    counts: { P0: 0, P1: 0, P2: 0, P3: 0 },
    attack_scenarios: [{ id: 'as-1', description: 'fixture invariant check', outcome: 'held', finding_id: null }] },
}
const receiptArgs = ['receipt', '--slate', 's', '--session', 'owner', '--owner-token', f.token, '--run-id', 'run-one', '--pass', passFile]
writeFileSync(passFile, JSON.stringify({ ...pass, producer: { harness: 'codex-cli', model: 'gpt-6-luna', tier: 'economy' } }))
refusal(f, /producer tier "economy" is below/, writer, receiptArgs)
writeFileSync(passFile, JSON.stringify(pass))
assert.match(node(f.repo, writer, receiptArgs), /recorded pass receipt challenge-r1-codex-adversarial/)
console.log('PASS: provisioned lane accepts its configured challenge receipt and enforces producer tier')
refusal(f, /run.json already exists/)
console.log('PASS: complete provisioning, lane profile, literal substitution, all required input refusals preserve state')

const unwidened = fixture()
node(unwidened.repo, command, unwidened.args())
unwidened.plan.issues.push({ number: 2, title: 'unreserved lane', url: 'https://example.test/issues/2', verdict: 'valid', candidate_files: ['src/two'], blocked_by: [] })
unwidened.plan.lanes.push({ lane: 'l2', issue: 2, wave: 2, branch: 'lane-two', run_id: 'run-two', fence: ['src/two'], expansions: [] })
unwidened.plan.lane_profiles.push({ lane: 'l2', policy })
unwidened.plan.waves.push({ number: 2, issues: [2] })
unwidened.publish()
git(unwidened.repo, 'switch', '-q', '-c', 'lane-two')
unwidened.facts.claim_handoff.branch = 'lane-two'; unwidened.saveFacts()
refusal(unwidened, /outside the reserved scope/, command, unwidened.args('l2'))
console.log('PASS: unreserved added lane is refused with byte-unchanged durable record tree')

const deferredProvision = fixture()
const monitor = join(assets, 'dev-flow-monitor.sh')
const deferredRun = 'run-deferred-provision'
const deferredBranch = 'lane-one'
const deferredHead = git(deferredProvision.repo, 'rev-parse', 'HEAD')
const activeState = execFileSync('bash', [monitor, 'active-path', '--branch', deferredBranch,
  '--repo-root', deferredProvision.repo], { encoding: 'utf8' }).trim()
execFileSync('bash', [monitor, 'activate', '--active-state', activeState,
  '--run-id', deferredRun, '--branch', deferredBranch, '--expected-predecessor', 'absent',
  '--expected-generation', '0',
  '--registry-revision', deferredHead, '--writer', 'feature-owner', '--repo-root', deferredProvision.repo],
{ stdio: 'ignore' })
const monitorState = execFileSync('bash', [monitor, 'state-path', '--run-id', deferredRun,
  '--repo-root', deferredProvision.repo], { encoding: 'utf8' }).trim()
execFileSync('bash', [monitor, 'reserve', '--state', monitorState, '--event', 'evt-provision',
  '--action', 'push', '--expected-head', deferredHead, '--writer', 'feature-owner',
  '--active-state', activeState, '--run-id', deferredRun, '--branch', deferredBranch,
  '--generation', '1', '--repo-root', deferredProvision.repo], { stdio: 'ignore' })
writeFileSync(join(monitorState, '..', 'run.json'),
  JSON.stringify({ schema: 2, run_id: deferredRun, outcome: 'abandoned' }))
refusal(deferredProvision, /activation refused:.*run-deferred-provision.*evt-provision.*cancel --state/)
console.log('PASS: provision-lane uses the shared activation guard for a deferred terminal reservation')

// Reservation widening precedes publishing the added-lane revision (#1410).
node(f.repo, writer, ['lock', 'acquire', '--slate', 'other', '--session', 'other', '--issues', '2'])
const widen = ['lock', 'acquire', '--slate', 's', '--session', 'owner', '--owner-token', f.token, '--issues', '1,2']
refusal(f, /already locked/, writer, widen)
const added = fixture()
node(added.repo, command, added.args())
const priorRun = readFileSync(join(added.root, 'runs/run-one/run.json'), 'utf8')
const widened = node(added.repo, writer, ['lock', 'acquire', '--slate', 's', '--session', 'owner', '--owner-token', added.token, '--issues', '1,2'])
assert.equal(widened, '', 'widening must not mint or print another token')
const second = { lane: 'l2', issue: 2, wave: 2, branch: 'lane-two', run_id: 'run-two', fence: ['src/two'], expansions: [] }
added.plan.issues.push({ number: 2, title: 'added lane', url: 'https://example.test/issues/2', verdict: 'valid', candidate_files: ['src/two'], blocked_by: [] })
added.plan.lanes.push(second)
added.plan.lane_profiles.push({ lane: 'l2', policy })
added.plan.waves.push({ number: 2, issues: [2] })
// Direct fixture publication models #1410; provisioning does not write plans.
added.publish()
git(added.repo, 'switch', '-q', '-c', 'lane-two')
added.facts.claim_handoff.branch = 'lane-two'; added.saveFacts()
added.facts.claim_handoff.comment_id = 0; added.saveFacts()
refusal(added, /rendered lane brief failed/, command, added.args('l2'))
added.facts.claim_handoff.comment_id = 1; added.saveFacts()
const planBefore = readFileSync(added.planFile, 'utf8')
const result = JSON.parse(node(added.repo, command, added.args('l2')))
node(added.repo, writer, ['intervention', '--slate', 's', '--session', 'owner', '--owner-token', added.token,
  '--run-id', 'run-two', '--kind', 'asked', '--note', 'added lane provisioned through supported writers', '--at', at])
const addedRun = JSON.parse(readFileSync(join(result.record_directory, 'run.json')))
assert.equal(addedRun.interventions.length, 1)
assert.deepEqual(addedRun.receipts, [])
assert.equal(readFileSync(added.planFile, 'utf8'), planBefore)
assert.equal(readFileSync(join(added.root, 'runs/run-one/run.json'), 'utf8'), priorRun)
const addedBrief = readFileSync(result.brief_path, 'utf8')
assert.ok(addedBrief.includes('lane `l1`'))
assert.ok(!JSON.parse(addedBrief.match(/```json\n([^\n]+)\n```/)[1]).live_lane_overlaps.some((line) => line.includes('lane `l2`')))
console.log('PASS: nonempty slate, widen → fixture plan revision → added-lane provision → intervention')

function withOther(fence, expansion, recorded = false) {
  const overlap = fixture()
  overlap.plan.issues.push({ number: 2, title: 'other', url: 'u', verdict: 'valid', candidate_files: recorded ? ['src/one'] : ['src/two'], blocked_by: [] })
  overlap.plan.lanes.push({ ...second, fence, expansions: [] })
  overlap.plan.lane_profiles.push({ lane: 'l2', policy })
  if (recorded) overlap.plan.overlaps.push({ issue_a: 1, issue_b: 2, paths: ['src/one'], resolution: 'serialize', merge_dependency: { before: 1, after: 2 } })
  overlap.plan.waves.push({ number: 2, issues: [2] }); overlap.publish()
  if (expansion) {
    overlap.plan.lanes[1].expansions.push({ path: expansion, at, reason: 'expansion overlaps l1' })
    overlap.publish()
  }
  return overlap
}
refusal(withOther(['src/one']), /effective fence overlaps live lane l2/)
refusal(withOther(['src/two'], 'src/one'), /effective fence overlaps live lane l2/)
refusal(withOther(['src/**']), /effective fence overlaps live lane l2/)
const overlap = withOther(['src/two'], 'tests/one')
refusal(overlap, /effective fence overlaps live lane l2/)
refusal(withOther(['src/one'], 'tests/one', true), /tests\/one \/ tests\/one; no plan-recorded overlap/)
console.log('PASS: an overlap recording path A does not authorize shared path B, with no writes')
const recorded = withOther(['src/one'], undefined, true)
recorded.facts.fence_notes = { 'src/one': { l1: 'Section One', l2: 'Section Two' } }; recorded.saveFacts()
node(recorded.repo, writer, ['lock', 'acquire', '--slate', 's', '--session', 'owner', '--owner-token', recorded.token, '--issues', '1,2'])
const sharedResult = JSON.parse(node(recorded.repo, command, recorded.args()))
const sharedBrief = readFileSync(sharedResult.brief_path, 'utf8')
assert.ok(sharedBrief.includes('lane `l2`') && sharedBrief.includes('resolution serialize; #1 merges before #2'))
console.log('PASS: recorded serialize overlap provisions and carries its merge dependency')
assert.ok(sharedBrief.includes('src/one` (l1: Section One; l2: Section Two)'))
const split = withOther(['src/one'], undefined, true)
split.plan.overlaps[0].resolution = 'split'; split.publish()
node(split.repo, writer, ['lock', 'acquire', '--slate', 's', '--session', 'owner', '--owner-token', split.token, '--issues', '1,2'])
refusal(split, /missing section notes for shared path src\/one/)
split.facts.fence_notes = { 'src/one': { l1: 'Lane one owns the First section' } }; split.saveFacts()
refusal(split, /missing section notes for shared path src\/one/)
split.facts.fence_notes['src/one'].l2 = 'Lane two owns the Second section'; split.saveFacts()
const splitFirst = JSON.parse(node(split.repo, command, split.args()))
git(split.repo, 'switch', '-q', '-c', 'lane-two')
split.facts.claim_handoff.branch = 'lane-two'; split.saveFacts()
const splitSecond = JSON.parse(node(split.repo, command, split.args('l2')))
for (const result of [splitFirst, splitSecond]) {
  const rendered = readFileSync(result.brief_path, 'utf8')
  assert.ok(rendered.includes('src/one` (') && rendered.includes('resolution split'))
  assert.ok(rendered.includes('l1: Lane one owns the First section'))
  assert.ok(rendered.includes('l2: Lane two owns the Second section'))
}
console.log('PASS: split overlap without both section notes refuses without writes; both briefs carry both shared-path boundaries')
assert.throws(() => assertDisjointFences({ ...overlap.plan, lanes: [
  { ...overlap.lane, fence: ['src/a*'] }, { ...second, fence: ['src/*b'] },
] }, { ...overlap.lane, fence: ['src/a*'] }), /effective fence overlaps/)
console.log('PASS: effective-fence overlap refusals include expansions and unmaterialized globs')

const invalid = fixture()
const doc = JSON.parse(readFileSync(invalid.planFile))
doc.revisions[0].digest = '0'.repeat(64)
writeFileSync(invalid.planFile, JSON.stringify(doc))
refusal(invalid, /failed.*validation/)
console.log('PASS: invalid plan chain preserves prior durable state')

const nested = fixture()
const subdir = join(nested.repo, 'nested')
mkdirSync(subdir)
const nestedResult = JSON.parse(node(subdir, command, nested.args()))
assert.equal(nestedResult.record_directory, join(nested.root, 'runs/run-one'))
node(nested.repo, validator, ['brief', nestedResult.brief_path])
console.log('PASS: invoking provisioning from a subdirectory finds the root registry and publishes a valid brief')

const { values } = buildBriefValues({ plan: added.plan, lane: second, facts: added.facts, nonce: 'a2', at,
  generation: 1, active: result.active_state_path, runDir: '/nonexistent/provision-fixture', defaultBranch: 'main' })
const template = join(temporary, 'template.md')
writeFileSync(template, readFileSync(join(assets, 'lane-brief.md'), 'utf8') + '\n{{unknown}}')
assert.throws(() => renderBrief(template, resolve(assets, '../SKILL.md'), values), /placeholder sets differ/)
const contaminated = { ...added.facts, live_lane_overlaps: ['copied prose'] }
assert.throws(() => buildBriefValues({ plan: added.plan, lane: second, facts: contaminated }), /unknown facts field/)
console.log('PASS: renderer checks catalog before insertion and facts cannot replace plan-owned values')
NODE
