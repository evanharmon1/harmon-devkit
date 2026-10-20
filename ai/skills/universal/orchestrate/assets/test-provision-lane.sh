#!/usr/bin/env bash
# Exercise the composed lane provisioning command in disposable repositories.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/provision-lane-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

node --input-type=module - "$asset_dir" "$tmp" <<'NODE'
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs'
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
const { resolvePolicy } = await import(join(support, 'devflow-policy.mjs'))
const { parseToml } = await import(join(support, 'lib/toml-lite.mjs'))
const policySource = readFileSync(resolve(assets, '../../../../../.devflow.toml'), 'utf8')
const resolvedPolicy = resolvePolicy(parseToml(policySource), { rigor: 'thorough', rigorSource: 'operator', tierOverrides: { implementer: 'frontier' } })
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
function fixture() {
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
    base_sha: base, policy,
    lane_profiles: [{ lane: 'l1', policy: { ...policy, caps: { ...policy.caps, wall_clock_min: 90 } } }],
    dispatcher: { kind: 'interactive', parallel_cap: 4, foreman_max_parallel: null },
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
    full.breadth = { ...full.breadth, ...profile.breadth }
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
  assert.match(result.stderr, pattern)
  assert.deepEqual(snapshot(f.root), before, 'refusal changed durable record tree')
  assert.ok(!result.stdout.includes(f.token) && !result.stderr.includes(f.token), 'owner token leaked')
}

const f = fixture()
refusal(f, /unknown lane/, command, f.args('missing'))
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
const recorded = withOther(['src/one'], undefined, true)
node(recorded.repo, writer, ['lock', 'acquire', '--slate', 's', '--session', 'owner', '--owner-token', recorded.token, '--issues', '1,2'])
const sharedResult = JSON.parse(node(recorded.repo, command, recorded.args()))
const sharedBrief = readFileSync(sharedResult.brief_path, 'utf8')
assert.ok(sharedBrief.includes('lane `l2`') && sharedBrief.includes('resolution serialize; #1 merges before #2'))
console.log('PASS: recorded serialize overlap provisions and carries its merge dependency')
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

const { values } = buildBriefValues({ plan: added.plan, lane: second, facts: added.facts, nonce: 'a2', at,
  generation: 1, active: result.active_state_path, runDir: '/nonexistent/provision-fixture', defaultBranch: 'main' })
const template = join(temporary, 'template.md')
writeFileSync(template, readFileSync(join(assets, 'lane-brief.md'), 'utf8') + '\n{{unknown}}')
assert.throws(() => renderBrief(template, resolve(assets, '../SKILL.md'), values), /placeholder sets differ/)
const contaminated = { ...added.facts, live_lane_overlaps: ['copied prose'] }
assert.throws(() => buildBriefValues({ plan: added.plan, lane: second, facts: contaminated }), /unknown facts field/)
console.log('PASS: renderer checks catalog before insertion and facts cannot replace plan-owned values')
NODE
