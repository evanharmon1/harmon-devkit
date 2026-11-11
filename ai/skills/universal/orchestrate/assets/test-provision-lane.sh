#!/usr/bin/env bash
# Exercise the composed lane provisioning command in disposable repositories.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/provision-lane-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

source_root="$(git -C "$asset_dir" rev-parse --show-toplevel)"
# Execute tools from a current, isolated Git root, independent of the outer branch.
tool_root="${tmp}/tool-root"
mkdir -p "$tool_root"
cp -R "${source_root}/ai" "$tool_root/ai"
cp "${source_root}/.devflow.toml" "${source_root}/agent-registry.json" "$tool_root/"
git init -q -b main "$tool_root"
git -C "$tool_root" add ai .devflow.toml agent-registry.json
git -C "$tool_root" -c user.name=test -c user.email=test@example.test commit -qm 'controlled executing tools'
git -C "$tool_root" update-ref refs/remotes/origin/main HEAD
git -C "$tool_root" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
asset_dir="$tool_root/ai/skills/universal/orchestrate/assets"

node --input-type=module - "$asset_dir" "$tmp" <<'NODE'
import assert from 'node:assert/strict'
import { execFileSync, spawn, spawnSync } from 'node:child_process'
import { cpSync, chmodSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
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
if (process.env.PROVISION_EVIDENCE_FIXTURE) {
  const file = process.env.PROVISION_EVIDENCE_FIXTURE
  const d = JSON.parse(fs.readFileSync(file))
  const a = process.argv.slice(2)
  if (a[0] === 'repo') console.log('https://github.com/owner/b')
  else if (a[1] === 'user') console.log(JSON.stringify({ id: 1, login: 'owner' }))
  else if (a.includes('-F')) {
    const body = fs.readFileSync(a[a.indexOf('-F') + 1].slice(6), 'utf8')
    d.push({ id: 77, user: { id: 1, login: 'owner' }, body })
    fs.writeFileSync(file, JSON.stringify(d))
    console.log(JSON.stringify(d.at(-1)))
  } else console.log(JSON.stringify(d))
  process.exit(0)
}
const [kind, operation, url] = process.argv.slice(2)
if (process.env.PROVISION_RELEASE_UNCLAIMED === '1' && process.argv[2] === 'api') {
  const endpoint = process.argv.slice(2).find((arg) => arg.startsWith('repos/owner/repo/issues/1'))
  if (endpoint === 'repos/owner/repo/issues/1') console.log(JSON.stringify({ state: 'open', labels: [], assignees: [] }))
  else if (endpoint === 'repos/owner/repo/issues/1/timeline' || endpoint === 'repos/owner/repo/issues/1/comments') console.log('[]')
  else process.exit(2)
  process.exit(0)
}
if (kind === 'label' && operation === 'list') { console.log('[]'); process.exit(0) }
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
function upstreamMerge(repo, branch) {
  try { return git(repo, 'config', '--get', `branch.${branch}.merge`) } catch { return '' }
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
function fixture(maxInFlight, parallel = 4, conductor, extraFence = [], originalFence, issueOneUrl) {
  const selectedPolicy = structuredClone(policy)
  selectedPolicy.breadth.max_parallel_agents = parallel
  if (maxInFlight !== undefined) selectedPolicy.breadth.max_in_flight = maxInFlight
  const repo = join(temporary, `repo-${++serial}`)
  mkdirSync(repo)
  git(repo, 'init', '-q', '-b', 'lane-one')
  if (conductor) git(repo, 'remote', 'add', 'origin', `https://github.com/${conductor}.git`)
  writeFileSync(join(repo, 'agent-registry.json'), JSON.stringify({ trusted_orchestrator_actor_ids: [1] }))
  mkdirSync(join(repo, 'src'))
  writeFileSync(join(repo, 'src/one'), 'fixture surface\n')
  writeFileSync(join(repo, 'src/two'), 'fixture surface\n')
  git(repo, 'add', 'agent-registry.json', 'src')
  git(repo, '-c', 'user.name=test', '-c', 'user.email=test@example.test', 'commit', '-qm', 'fixture')
  const base = git(repo, 'rev-parse', 'HEAD')
  git(repo, 'update-ref', 'refs/remotes/origin/main', base)
  git(repo, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
  const root = join(repo, '.git/dev-flow-v2')
  const token = node(repo, writer, ['lock', 'acquire', '--slate', 's', '--session', 'owner', '--issues', '1'])
  const lane = { lane: 'l1', issue: 1, wave: 1, branch: 'lane-one', run_id: 'run-one',
    fence: originalFence ?? [{ path: 'src/one', note: 'owned section' }, ...extraFence], expansions: [] }
  const plan = {
    ...(conductor ? { repo: conductor } : {}), base_sha: base, policy: selectedPolicy,
    lane_profiles: [{ lane: 'l1', policy: { ...selectedPolicy, caps: { ...selectedPolicy.caps, wall_clock_min: 90 } } }],
    dispatcher: { kind: 'interactive', parallel_cap: parallel, foreman_max_parallel: null },
    issues: [{ number: 1, title: 'Support {{branch}} and `quotes`', url: issueOneUrl ?? (conductor ? `https://github.com/${conductor}/issues/1` : 'https://example.test/issues/1'), verdict: 'valid', candidate_files: ['src/one'], blocked_by: [] }],
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
  function publish(reason) {
    const seq = revisions.length
    const prev_digest = revisions.at(-1)?.digest ?? 'genesis'
    const content = { seq, at, reason: reason ?? `fixture revision ${seq}`, plan: structuredClone(plan) }
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
    `unexpected refusal output (stdout=${JSON.stringify(result.stdout)}, stderr=${JSON.stringify(result.stderr)}, error=${result.error}, signal=${result.signal})`)
  assert.deepEqual(snapshot(f.root), before, 'refusal changed durable record tree')
  assert.ok(f.token.length > 0, 'fixture owner token must be non-empty')
  assert.ok(!result.stdout.includes(f.token) && !result.stderr.includes(f.token), 'owner token leaked')
}

// #1722: refusal precedes lane-init and every durable provisioning write.
{
  const f = fixture()
  cpSync(assets, join(f.repo, 'skills/orchestrate/assets'), { recursive: true })
  cpSync(support, join(f.repo, 'skills/dev-flow-support/assets'), { recursive: true })
  const localCommand = join(f.repo, 'skills/orchestrate/assets/provision-lane.mjs')
  writeFileSync(join(f.repo, '.skills-sync.yaml'), 'source:\n  ref: v1\n')
  git(f.repo, 'add', '.skills-sync.yaml', 'skills')
  git(f.repo, '-c', 'user.name=test', '-c', 'user.email=test@example.test', 'commit', '-qm', 'old pin')
  const old = git(f.repo, 'rev-parse', 'HEAD')
  writeFileSync(join(f.repo, '.skills-sync.yaml'), 'source:\n  ref: v2\n')
  git(f.repo, '-c', 'user.name=test', '-c', 'user.email=test@example.test', 'commit', '-qam', 'new pin')
  const tip = git(f.repo, 'rev-parse', 'HEAD')
  git(f.repo, 'update-ref', 'refs/remotes/origin/main', tip)
  git(f.repo, 'checkout', '-q', '--detach', old)
  refusal(f, new RegExp(`BLOCKER:.*${old}.*${tip}.*v1.*v2.*fetch origin.*merge --ff-only origin/main`), localCommand)
  git(f.repo, 'checkout', '-q', '--detach', tip)
  const checked = spawnSync('bash', [join(f.repo, 'skills/orchestrate/assets/dev-flow-monitor.sh'), 'check-assets'], { cwd: f.repo, encoding: 'utf8' })
  assert.equal(checked.status, 0, checked.stderr)
}


function capacityFixture(parallel, flight, issueOneUrl) {
  const f = fixture(flight, parallel, undefined, [], undefined, issueOneUrl)
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
{
  const f = fixture()
  f.lane.run_id = 'run-1-reserved'
  f.lane.expansions = []
  f.publish()
  f.args()
  refusal(f, /run run-1-reserved is reserved by slate s's plan history/, writer,
    ['solo-init', '--session', 'owner', '--run-id', 'run-1-reserved', '--issue', '1', '--title', 'fixture',
      '--url', 'https://github.com/owner/repo/issues/1', '--branch', 'lane-one', '--base', f.plan.base_sha,
      '--policy', f.policyFile, '--actor-id', '1', '--strategy-source', 'operator'])
  console.log('PASS: solo-init refuses a run reserved by a current slate plan')
}
// Historical lane reservations survive retirement, including in another slate.
for (const otherSlate of [false, true]) {
  const f = fixture(undefined, 4, undefined, [], undefined, 'https://github.com/owner/repo/issues/1')
  f.lane.run_id = 'run-1-reserved'
  f.lane.expansions = []
  f.publish()
  process.env.PROVISION_RELEASE_UNCLAIMED = '1'
  node(f.repo, join(support, 'plan-revise.mjs'), ['handoff', '--slate', 's', '--session', 'owner', '--owner-token', f.token, '--issue', '1', '--pr', '101', '--reason', 'fixture handoff', '--at', at])
  delete process.env.PROVISION_RELEASE_UNCLAIMED
  if (otherSlate) {
    const document = JSON.parse(readFileSync(f.planFile, 'utf8'))
    document.slate_id = 'second'
    mkdirSync(join(f.root, 'slates/second'), { recursive: true })
    writeFileSync(join(f.root, 'slates/second/plan.json'), JSON.stringify(document))
    // Remove the original slate so only the second slate holds the reservation.
    rmSync(join(f.root, 'slates/s/plan.json'))
  }
  f.args()
  refusal(f, new RegExp(`run run-1-reserved is reserved by slate ${otherSlate ? 'second' : 's'}'s plan history`), writer,
    ['solo-init', '--session', 'owner', '--run-id', 'run-1-reserved', '--issue', '1', '--title', 'fixture',
      '--url', 'https://github.com/owner/repo/issues/1', '--branch', 'lane-one', '--base', f.plan.base_sha,
      '--policy', f.policyFile, '--actor-id', '1', '--strategy-source', 'operator'])
}
console.log('PASS: solo-init refuses historical reservations across slates')
// Fence completeness is checked before any durable provisioning state exists.
function addFenceConsumer(f) {
  mkdirSync(join(f.repo, 'src'), { recursive: true })
  mkdirSync(join(f.repo, 'scripts'), { recursive: true })
  writeFileSync(join(f.repo, 'src/one'), 'fixture surface\n')
  writeFileSync(join(f.repo, 'scripts/test-one.sh'), 'assert src/one\n')
  git(f.repo, 'add', 'scripts/test-one.sh')
}
const incompleteFence = fixture()
addFenceConsumer(incompleteFence)
refusal(incompleteFence, /missing: scripts\/test-one\.sh/)
const mixedFailure = fixture(undefined, 4, undefined, ['src/planned'])
addFenceConsumer(mixedFailure)
refusal(mixedFailure, /(?=[\s\S]*missing: scripts\/test-one\.sh)(?=[\s\S]*incomplete: src\/planned)/)
const completeFence = fixture()
addFenceConsumer(completeFence)
completeFence.lane.expansions.push({ path: 'scripts/test-one.sh', at, reason: 'test coverage' })
completeFence.publish()
node(completeFence.repo, command, completeFence.args())
const recordedWaiver = fixture()
addFenceConsumer(recordedWaiver)
recordedWaiver.publish('fence-waiver: l1 scripts/test-one.sh: orchestrator accepts omission')
node(recordedWaiver.repo, command, recordedWaiver.args())
console.log('PASS: provisioning refuses missing fence consumers and accepts expansions or recorded waivers')

// #1799: fencing wiring does not pull in its test list or a second hop.
{
  const wiring = ['Taskfile.yml', 'Taskfile.yaml', 'Taskfile.dist.yml', 'Taskfile.dist.yaml', 'taskfiles/extra.yml', 'taskfiles/extra.yaml']
  const f = fixture(undefined, 4, undefined, [], [...wiring, 'src/one'])
  mkdirSync(join(f.repo, 'scripts'))
  mkdirSync(join(f.repo, 'taskfiles'))
  for (const path of wiring) writeFileSync(join(f.repo, path), 'scripts/test-wired.sh\n')
  writeFileSync(join(f.repo, 'scripts/test-wired.sh'), 'scripts/test-next.sh\n')
  writeFileSync(join(f.repo, 'scripts/test-next.sh'), 'fixture\n')
  writeFileSync(join(f.repo, 'scripts/test-asset.sh'), 'src/one\n')
  git(f.repo, 'add', ...wiring, 'scripts')
  refusal(f, /missing: scripts\/test-asset\.sh/)
  f.lane.expansions.push({ path: 'scripts/test-asset.sh', at, reason: 'asset validator' })
  f.publish()
  node(f.repo, command, f.args())
}
console.log('PASS: fenced wiring does not expand its test list during provisioning')

// #1792: lane-1734's original five paths reach a shared hub once. Adding
// that hub must not pull its own tests, consumers or documentation into scope.
{
  const original = [
    'ai/skills/universal/dev-flow-support/assets/run-record.mjs',
    'ai/skills/universal/dev-flow-support/assets/test-run-record.sh',
    'ai/skills/universal/orchestrate/assets/dev-flow-monitor.sh',
    'ai/skills/universal/orchestrate/assets/test-dev-flow-monitor.sh',
    'ai/skills/universal/orchestrate/SKILL.md',
  ]
  const f = fixture(undefined, 4, undefined, [], original)
  const files = new Map(original.map((path) => [path, 'fixture surface\n']))
  files.set('scripts/test-skills.sh', `${original.join('\n')}\nscripts/test-plan-revise.sh\n`)
  files.set('scripts/test-plan-revise.sh', 'fixture surface\n')
  files.set('scripts/validate-agent-registry.mjs', 'read("scripts/test-skills.sh")\n')
  files.set('ai/skills/README.md', `${original[4]}\nscripts/test-skills.sh\n`)
  files.set('Taskfile.yml', 'run: scripts/test-skills.sh\n')
  for (const [path, content] of files) {
    mkdirSync(resolve(f.repo, path, '..'), { recursive: true })
    writeFileSync(join(f.repo, path), content)
  }
  git(f.repo, 'add', ...files.keys())
  f.publish()
  const scan = () => spawnSync('bash', [join(assets, 'validator-dependency-scan.sh'),
    '--check-plan', f.planFile, '--lane', 'l1'], { cwd: f.repo, encoding: 'utf8' })
  const first = scan()
  assert.equal(first.status, 1, first.stderr)
  assert.deepEqual(first.stdout.split('\n').filter((line) => line.includes(': missing:'))
    .map((line) => line.split(': ')[2]), ['scripts/test-skills.sh'])
  f.lane.expansions.push({ path: 'scripts/test-skills.sh', at, reason: 'first-hop validator' })
  f.publish()
  const second = scan()
  assert.equal(second.status, 0, second.stdout + second.stderr)
  assert.ok(!second.stdout.includes('test-plan-revise.sh'), 'expansion became a new scan source')
  node(f.repo, command, f.args())
}

// A validator owned by another live lane asks for sequencing, never takeover.
{
  const f = fixture()
  addFenceConsumer(f)
  node(f.repo, writer, ['lock', 'acquire', '--slate', 's', '--session', 'owner', '--owner-token', f.token, '--issues', '1,2'])
  f.plan.issues.push({ number: 2, title: 'validator owner', url: 'https://example.test/issues/2', verdict: 'valid', candidate_files: ['scripts/test-one.sh'], blocked_by: [] })
  f.plan.lanes.push({ lane: 'l2', issue: 2, wave: 2, branch: 'lane-two', run_id: 'run-two', fence: ['scripts/test-*.sh'], expansions: [] })
  f.plan.lane_profiles.push({ lane: 'l2', policy: structuredClone(f.plan.policy) })
  f.plan.waves.push({ number: 2, issues: [2] })
  f.publish()
  refusal(f, /shared-validator overlap: scripts\/test-one\.sh: owned by live lane l2; merge-order decision required/)
  // An omission waiver cannot resolve ownership.
  f.publish('fence-waiver: l1 scripts/test-one.sh: omission accepted')
  refusal(f, /shared-validator overlap:/)
  // Once its owner is done, ordinary first-hop coverage suffices.
  f.plan.issues[1].verdict = 'done'
  f.plan.lanes.pop()
  f.plan.waves.pop()
  f.plan.lane_profiles.pop()
  f.lane.expansions.push({ path: 'scripts/test-one.sh', at, reason: 'owner finished' })
  f.publish()
  node(f.repo, command, f.args())
}
console.log('PASS: lane-1734 converges after one expansion and shared validators require merge ordering')

// The public overlap writer unblocks a validator held in an expansion.
{
  const shared = 'scripts/test-one.sh'
  const f = fixture()
  addFenceConsumer(f)
  writeFileSync(join(f.repo, 'src/two'), `${shared}\n`)
  node(f.repo, writer, ['lock', 'acquire', '--slate', 's', '--session', 'owner', '--owner-token', f.token, '--issues', '1,2'])
  f.lane.expansions.push({ path: shared, at, reason: 'accepted coverage' })
  f.plan.issues.push({ number: 2, title: 'validator owner', url: 'https://example.test/issues/2', verdict: 'valid', candidate_files: ['src/two'], blocked_by: [] })
  f.plan.lanes.push({ lane: 'l2', issue: 2, wave: 2, branch: 'lane-two', run_id: 'run-two', fence: ['src/two'], expansions: [] })
  f.plan.lane_profiles.push({ lane: 'l2', policy: structuredClone(f.plan.policy) })
  f.plan.waves.push({ number: 2, issues: [2] })
  f.facts.fence_notes = { [shared]: { l1: 'first section', l2: 'second section' } }
  git(f.repo, 'switch', '-c', 'lane-two')
  f.facts.claim_handoff.branch = 'lane-two'
  f.saveFacts(); f.publish()
  refusal(f, /shared-validator overlap:/, command, f.args('l2'))
  node(f.repo, join(support, 'plan-revise.mjs'), ['overlap', '--slate', 's', '--session', 'owner', '--owner-token', f.token, '--lane-a', 'l1', '--lane-b', 'l2', '--path', shared, '--resolution', 'serialize', '--before', '1', '--after', '2', '--reason', 'verified ordering', '--at', at])
  node(f.repo, command, f.args('l2'))
}
console.log('PASS: recorded expansion overlap unblocks provisioning')

// Challenge r1: an already approved merge order must unblock shared validators.
for (const resolution of ['serialize', 'split']) {
  const shared = 'scripts/test-one.sh'
  const f = fixture(undefined, 4, undefined, [shared])
  addFenceConsumer(f)
  writeFileSync(join(f.repo, 'src/one'), `${shared}\n`)
  node(f.repo, writer, ['lock', 'acquire', '--slate', 's', '--session', 'owner', '--owner-token', f.token, '--issues', '1,2'])
  f.plan.issues[0].candidate_files.push(shared)
  f.plan.issues.push({ number: 2, title: 'shared validator', url: 'https://example.test/issues/2', verdict: 'valid', candidate_files: [shared], blocked_by: [] })
  f.plan.lanes.push({ lane: 'l2', issue: 2, wave: 2, branch: 'lane-two', run_id: 'run-two', fence: [shared], expansions: [] })
  f.plan.lane_profiles.push({ lane: 'l2', policy: structuredClone(f.plan.policy) })
  f.plan.waves.push({ number: 2, issues: [2] })
  f.plan.overlaps.push({ issue_a: 1, issue_b: 2, paths: [shared], resolution, merge_dependency: { before: 1, after: 2 } })
  f.facts.fence_notes = { [shared]: { l1: 'first assertion section', l2: 'second assertion section' } }
  f.saveFacts(); f.publish()
  const result = JSON.parse(node(f.repo, command, f.args()))
  assert.ok(readFileSync(result.brief_path, 'utf8').includes(`resolution ${resolution}; #1 merges before #2`))
}
console.log('PASS: approved serialize and split resolutions provision shared validators')



// A claim remains Working even after a run ends, until the label is removed.
for (const outcome of ['ready-for-review', 'capped', 'escalated', 'abandoned']) {
  const f = capacityFixture(1, 1)
  node(f.repo, command, f.args())
  if (outcome === 'ready-for-review') {
    for (const stage of ['claim', 'implement', 'verify', 'challenge', 'review', 'security', 'integration']) {
      node(f.repo, writer, ['transition', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
        '--run-id', 'run-one', '--stage', stage, ...(stage === 'claim' ? [] : ['--exit', 'fixture gate passed']), '--at', at])
    }
    node(f.repo, writer, ['bind-pr', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
      '--run-id', 'run-one', '--number', '101', '--url', 'https://example.test/pull/101', '--at', at])
    node(f.repo, writer, ['promote', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
      '--run-id', 'run-one', '--head', f.plan.base_sha, '--fingerprint', 'fixture', '--gate', (writeFileSync(join(f.repo, 'readiness-pass.json'), JSON.stringify({status: 'pass', condition: 'ready', head: f.plan.base_sha, fingerprint: 'fixture'})), join(f.repo, 'readiness-pass.json')), '--at', at])
    live(f, { 'https://example.test/pull/101': { state: 'MERGED' } })
  } else {
    node(f.repo, writer, ['transition', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
      '--run-id', 'run-one', '--stage', 'claim', '--at', at])
    node(f.repo, writer, ['close', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
      '--run-id', 'run-one', '--outcome', outcome, '--exit', 'fixture terminal run', '--at', at])
  }
  addSecond(f)
  refusal(f, /max_parallel_agents 1/, command, f.args('l2'))
  live(f, { 'https://example.test/issues/1': { state: 'OPEN', labels: [] }, 'https://example.test/pull/101': { state: 'MERGED' } })
  node(f.repo, command, f.args('l2'))
}
console.log('PASS: terminal runs retain a claimed working slot until claim removal')

const closedIssue = capacityFixture(1, 1)
node(closedIssue.repo, command, closedIssue.args())
addSecond(closedIssue)
closedIssue.plan.issues[0].pr = 101
closedIssue.publish()
live(closedIssue, { 'https://example.test/issues/1': { state: 'CLOSED', labels: [{ name: 'claim:gpt' }] } })
node(closedIssue.repo, command, closedIssue.args('l2'))
console.log('PASS: a closed issue releases its working slot')

for (const ceiling of ['working', 'in-flight']) {
  const f = capacityFixture(1, 1)
  node(f.repo, command, f.args())
  const liveRun = JSON.parse(readFileSync(join(f.root, 'runs/run-one/run.json')))
  addSecond(f)
  if (ceiling === 'in-flight') {
    node(f.repo, writer, ['transition', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
      '--run-id', 'run-one', '--stage', 'claim', '--at', at])
    node(f.repo, writer, ['close', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
      '--run-id', 'run-one', '--outcome', 'abandoned', '--exit', 'fixture terminal run', '--at', at])
    f.plan.issues[0].pr = 101; f.publish()
    live(f, { 'https://example.test/issues/1': { state: 'OPEN', labels: [] } })
  }
  f.args('l2') // Materialize the candidate's resolved policy.
  const pattern = ceiling === 'working' ? /max_parallel_agents 1: working 2, in-flight 2/ : /max_in_flight 1: working 1, in-flight 2/
  refusal(f, pattern, writer, ['lane-init', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
    '--lane', 'l2', '--policy', f.policyFile, '--at', at])
  const monitor = join(assets, 'dev-flow-monitor.sh')
  const active = execFileSync('bash', [monitor, 'active-path', '--repo-root', f.repo, '--branch', 'lane-two'], { encoding: 'utf8' }).trim()
  const before = snapshot(f.root)
  const result = spawnSync('bash', [monitor, 'activate', '--repo-root', f.repo, '--active-state', active,
    '--run-id', 'run-two', '--branch', 'lane-two', '--expected-predecessor', 'absent', '--expected-generation', '0',
    '--registry-revision', f.plan.base_sha, '--writer', 'feature-owner'], { cwd: f.repo, encoding: 'utf8' })
  assert.equal(result.status, 2, result.stderr) // Monitor refusals use exit 2.
  assert.match(result.stderr, /dispatch admission/)
  assert.deepEqual(snapshot(f.root), before, 'refused monitor activation changed durable state')
  for (const name of ['run.json', 'owner-slate', 'policy.json']) {
    assert.ok(!existsSync(join(f.root, 'runs/run-two', name)), `${name} survived capacity refusal`)
  }
  // An older, valid run record is readable but cannot be newly activated without admission.
  const unadmitted = structuredClone(liveRun)
  unadmitted.run_id = 'run-two'
  delete unadmitted.dispatch_admission
  mkdirSync(join(f.root, 'runs/run-two'), { recursive: true })
  writeFileSync(join(f.root, 'runs/run-two/run.json'), JSON.stringify(unadmitted))
  const unadmittedBefore = snapshot(f.root)
  const unadmittedActivation = spawnSync('bash', [monitor, 'activate', '--repo-root', f.repo, '--active-state', active,
    '--run-id', 'run-two', '--branch', 'lane-two', '--expected-predecessor', 'absent', '--expected-generation', '0',
    '--registry-revision', f.plan.base_sha, '--writer', 'feature-owner'], { cwd: f.repo, encoding: 'utf8' })
  assert.equal(unadmittedActivation.status, 2, unadmittedActivation.stderr)
  assert.match(unadmittedActivation.stderr, /dispatch admission/)
  assert.deepEqual(snapshot(f.root), unadmittedBefore)
  rmSync(join(f.root, 'runs/run-two'), { recursive: true })
  if (ceiling === 'working') {
    node(f.repo, writer, ['transition', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
      '--run-id', 'run-one', '--stage', 'claim', '--at', at])
    node(f.repo, writer, ['close', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
      '--run-id', 'run-one', '--outcome', 'abandoned', '--exit', 'fixture terminal run', '--at', at])
  }
  live(f, { 'https://example.test/issues/1': { state: 'CLOSED', labels: [] } })
  node(f.repo, writer, ['lane-init', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
    '--lane', 'l2', '--policy', f.policyFile, '--at', at])
  const record = JSON.parse(readFileSync(join(f.root, 'runs/run-two/run.json')))
  assert.deepEqual(record.dispatch_admission, { slate: 's', working: 1, in_flight: 1, at })
  // Neither a missing plan nor unavailable GitHub may turn activation into a second admission.
  rmSync(f.planFile)
  live(f, { 'https://example.test/issues/2': 'unavailable' })
  execFileSync('bash', [monitor, 'activate', '--repo-root', f.repo, '--active-state', active,
    '--run-id', 'run-two', '--branch', 'lane-two', '--expected-predecessor', 'absent', '--expected-generation', '0',
    '--registry-revision', f.plan.base_sha, '--writer', 'feature-owner'], { cwd: f.repo, stdio: 'pipe' })
}
console.log('PASS: lane-init refuses without state, retries after capacity frees, and activation requires admission without capacity reads')

for (const damage of ['missing', 'unreadable', 'mismatched']) {
  const f = capacityFixture(1, 1)
  f.args()
  if (damage === 'missing') rmSync(f.planFile)
  else if (damage === 'unreadable') writeFileSync(f.planFile, '{')
  else {
    const document = JSON.parse(readFileSync(f.planFile))
    document.slate_id = 'another-slate'
    writeFileSync(f.planFile, JSON.stringify(document))
  }
  refusal(f, /owner plan|invalid|slate_id|cannot read valid JSON/, writer, ['lane-init', '--slate', 's',
    '--session', 'owner', '--owner-token', f.token, '--lane', 'l1', '--policy', f.policyFile, '--at', at])
}
console.log('PASS: missing, unreadable and mismatched owner plans refuse admission without writes')

const missingIssue = capacityFixture(1, 1)
node(missingIssue.repo, command, missingIssue.args())
addSecond(missingIssue)
// Simulate a retained historical lane with a missing issue identity, bypassing
// fixture validation to exercise the runtime refusal on a damaged revision.
const damaged = JSON.parse(readFileSync(missingIssue.planFile))
for (const revision of damaged.revisions) {
  if (!revision.plan.lanes.some((lane) => lane.run_id === 'run-one')) continue
  revision.plan.issues = revision.plan.issues.filter((issue) => issue.number !== 1)
}
// The shared counter accepts a supplied plan but reads historical bindings.
writeFileSync(missingIssue.planFile, JSON.stringify(damaged))
const { assertDispatchCapacity } = await import(writer)
assert.throws(() => assertDispatchCapacity(missingIssue.root, missingIssue.plan, missingIssue.plan.lanes[1], 's'),
  (error) => error.name !== 'TypeError' && /missing issue|validation/.test(error.message))
console.log('PASS: a missing historical issue refuses cleanly instead of throwing TypeError')

const cappedWorking = capacityFixture(1, 3)
node(cappedWorking.repo, command, cappedWorking.args())
addSecond(cappedWorking)
const duplicateSlate = JSON.parse(readFileSync(cappedWorking.planFile))
duplicateSlate.slate_id = 'another'
mkdirSync(join(cappedWorking.root, 'slates/another'))
writeFileSync(join(cappedWorking.root, 'slates/another/plan.json'), JSON.stringify(duplicateSlate))
refusal(cappedWorking, /max_parallel_agents 1: working 2, in-flight 2/, command, cappedWorking.args('l2'))
live(cappedWorking, { 'https://example.test/issues/1': { state: 'OPEN', labels: [{ name: 'slated' }] } })
refusal(cappedWorking, /max_parallel_agents 1: working 2, in-flight 1/, command, cappedWorking.args('l2'))
console.log('PASS: admitted unclaimed run retains its working slot')

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
  live(f, { 'https://example.test/issues/1': { state: 'OPEN', labels: [] }, 'https://example.test/issues/3': { state: 'OPEN', labels: [] } })
  refusal(f, binding === 'run' ? /max_in_flight 2: working 1, in-flight 3/ : /max_in_flight 2: working 2, in-flight 3/, command, f.args('l2'))
  live(f, { 'https://example.test/issues/1': { state: 'OPEN', labels: [] }, 'https://example.test/issues/3': { state: 'OPEN', labels: [] }, 'https://example.test/pull/101': { state: 'MERGED' } })
  node(f.repo, command, f.args('l2'))
  assert.ok(existsSync(join(first.record_directory, 'run.json')))
}
console.log('PASS: issue, queue-only and run PR bindings hold in-flight slots until closed/merged')

const remediating = capacityFixture(1, 2)
node(remediating.repo, command, remediating.args())
addSecond(remediating)
// addSecond moved the conductor to lane-two; retain lane-one's real worktree.
git(remediating.repo, 'worktree', 'add', '-q', join(temporary, 'remediation-lane-one'), 'lane-one')
for (const stage of ['claim', 'implement', 'verify', 'challenge', 'review', 'security', 'integration']) {
  node(remediating.repo, writer, ['transition', '--slate', 's', '--session', 'owner', '--owner-token', remediating.token,
    '--run-id', 'run-one', '--stage', stage, ...(stage === 'claim' ? [] : ['--exit', 'fixture gate passed']), '--at', at])
}
// Remediation requires its original PR even when no reviewer was reserved.
node(remediating.repo, writer, ['bind-pr', '--slate', 's', '--session', 'owner', '--owner-token', remediating.token,
  '--run-id', 'run-one', '--number', '101', '--url', 'https://github.com/example/repo/pull/101', '--at', at])
node(remediating.repo, writer, ['transition', '--slate', 's', '--session', 'owner', '--owner-token', remediating.token,
  '--run-id', 'run-one', '--stage', 'implement', '--exit', 'fixture gate passed', '--at', at])
live(remediating, { 'https://example.test/issues/1': { state: 'OPEN', labels: [{ name: 'claim:gpt' }] } })
refusal(remediating, /max_parallel_agents 1/, command, remediating.args('l2'))
console.log('PASS: remediation holds the working slot after integration')

const handedOff = capacityFixture(1, 2)
node(handedOff.repo, command, handedOff.args())
addSecond(handedOff)
for (const stage of ['claim', 'implement', 'verify', 'challenge', 'review', 'security', 'integration']) {
  node(handedOff.repo, writer, ['transition', '--slate', 's', '--session', 'owner', '--owner-token', handedOff.token,
    '--run-id', 'run-one', '--stage', stage, ...(stage === 'claim' ? [] : ['--exit', 'fixture gate passed']), '--at', at])
}
live(handedOff, { 'https://example.test/issues/1': { state: 'OPEN', labels: [{ name: 'claim:gpt' }] } })
refusal(handedOff, /max_parallel_agents 1/, command, handedOff.args('l2'))
live(handedOff, { 'https://example.test/issues/1': { state: 'OPEN', labels: [] } })
node(handedOff.repo, command, handedOff.args('l2'))
live(handedOff, { 'https://example.test/issues/1': { state: 'OPEN', labels: [{ name: 'claim:gpt' }] } })
assert.throws(() => assertDispatchCapacity(handedOff.root, handedOff.plan, handedOff.plan.lanes[1], 's'), /max_parallel_agents 1/)
console.log('PASS: integration claim counts, removal releases, and resumed claim counts again')

const equal = capacityFixture(1, 1, 'https://github.com/owner/repo/issues/1')
node(equal.repo, command, equal.args())
addSecond(equal)
live(equal, { 'https://github.com/owner/repo/issues/1': { state: 'OPEN', labels: [] } })
for (const stage of ['claim', 'implement', 'verify', 'challenge', 'review', 'security', 'integration']) {
  node(equal.repo, writer, ['transition', '--slate', 's', '--session', 'owner', '--owner-token', equal.token,
    '--run-id', 'run-one', '--stage', stage, ...(stage === 'claim' ? [] : ['--exit', 'fixture gate passed']), '--at', at])
}
process.env.PROVISION_RELEASE_UNCLAIMED = '1'
node(equal.repo, join(support, 'plan-revise.mjs'), ['handoff', '--slate', 's', '--session', 'owner', '--owner-token', equal.token, '--issue', '1', '--pr', '101', '--reason', 'verified boundary handoff', '--at', at])
delete process.env.PROVISION_RELEASE_UNCLAIMED
node(equal.repo, join(support, 'plan-revise.mjs'), ['wave-release', '--slate', 's', '--session', 'owner', '--owner-token', equal.token, '--wave', '2', '--reason', 'verified boundary handoff', '--at', at])
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

// A slow scan must not hold the plan mutex, and its plan must remain current.
{
  const scanner = join(assets, 'validator-dependency-scan.sh')
  const realScanner = join(assets, 'validator-dependency-scan-real.sh')
  cpSync(scanner, realScanner)
  writeFileSync(scanner, `#!/usr/bin/env bash
set -euo pipefail
if [ -n "\${TEST_SCAN_SIGNAL:-}" ]; then
  : > "$TEST_SCAN_SIGNAL"
  while [ ! -e "$TEST_SCAN_RELEASE" ]; do sleep 0.1; done
fi
exec bash "$(dirname "$0")/validator-dependency-scan-real.sh" "$@"
`)
  async function waitForScan(signal) {
    const deadline = Date.now() + 120000
    while (!existsSync(signal)) {
      if (Date.now() > deadline) throw new Error('slow scan did not reach its barrier')
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
  }
  function startSlow(f, args, signal, release) {
    return new Promise((resolve, reject) => {
      const child = spawn(process.execPath, [command, ...args], {
        cwd: f.repo, env: { ...process.env, TEST_SCAN_SIGNAL: signal, TEST_SCAN_RELEASE: release },
      })
      let stderr = ''
      child.stdout.resume()
      child.stderr.on('data', (data) => { stderr += data })
      child.on('error', reject)
      child.on('close', (status) => resolve({ status, stderr }))
    })
  }
  try {
    const slow = capacityFixture(1, 3)
    node(slow.repo, command, slow.args())
    addSecond(slow)
    const args = slow.args('l2')
    const before = snapshot(slow.root)
    const signal = join(temporary, 'slow-scan-started')
    const release = join(temporary, 'slow-scan-release')
    const pending = startSlow(slow, args, signal, release)
    await waitForScan(signal)
    const contender = spawnSync(process.execPath, [command, ...args], { cwd: slow.repo, encoding: 'utf8' })
    writeFileSync(release, '')
    const first = await pending
    assert.equal(contender.status, 1, contender.stderr)
    assert.match(contender.stderr, /max_parallel_agents 1: working 2/)
    assert.equal(first.status, 1, first.stderr)
    assert.match(first.stderr, /max_parallel_agents 1: working 2/)
    assert.deepEqual(snapshot(slow.root), before, 'slow scan refusal changed durable state')
    console.log('PASS: a slow scan does not hold the plan mutex against a capacity refusal')

    const revised = fixture()
    const revisedArgs = revised.args()
    const revisedSignal = join(temporary, 'revised-scan-started')
    const revisedRelease = join(temporary, 'revised-scan-release')
    const scanning = startSlow(revised, revisedArgs, revisedSignal, revisedRelease)
    await waitForScan(revisedSignal)
    revised.publish('plan changed during scan')
    const afterRevision = snapshot(revised.root)
    writeFileSync(revisedRelease, '')
    const result = await scanning
    assert.equal(result.status, 1, result.stderr)
    assert.match(result.stderr, /plan revised during the fence scan; retry/)
    assert.deepEqual(snapshot(revised.root), afterRevision, 'revised plan refusal changed durable state')
    console.log('PASS: a revision during the scan refuses before durable writes')
  } finally {
    cpSync(realScanner, scanner)
    rmSync(realScanner, { force: true })
  }
}

// #1802: a profile derived from --policy provisions without a copied projection.
for (const operation of ['add-issue', 'done']) {
  const derived = fixture(undefined, 4, 'example/repo')
  derived.args() // Materialize complete devflow-policy resolve JSON.
  const addition = {
    issue: { number: 2, title: 'Resolved-policy addition', url: 'https://github.com/example/repo/issues/2', verdict: 'valid', candidate_files: ['src/two'], blocked_by: [] },
    lane: { lane: 'l2', issue: 2, wave: 1, branch: 'lane-two', run_id: 'run-two', fence: [{ path: 'src/two' }], expansions: [] },
  }
  const inputFile = join(derived.repo, 'addition.json')
  writeFileSync(inputFile, JSON.stringify(operation === 'done' ? { addition } : addition))
  node(derived.repo, join(support, 'plan-revise.mjs'), [operation, '--slate', 's', '--session', 'owner',
    '--owner-token', derived.token, '--input', inputFile, '--policy', derived.policyFile,
    ...(operation === 'done' ? ['--issue', '1'] : []), '--reason', 'resolved addition', '--at', at])
  const revised = JSON.parse(readFileSync(derived.planFile)).revisions.at(-1).plan
  Object.assign(derived.plan, revised)
  git(derived.repo, 'switch', '-qc', addition.lane.branch)
  derived.facts.claim_handoff.branch = addition.lane.branch
  derived.saveFacts()
  const result = JSON.parse(node(derived.repo, command, derived.args('l2')))
  assert.equal(result.run_id, 'run-two')
  assert.ok(existsSync(join(result.record_directory, 'run.json')))
  assert.equal(JSON.parse(readFileSync(join(result.record_directory, 'policy.json'))).rigor.level,
    revised.lane_profiles.find((entry) => entry.lane === 'l2').policy.rigor)
  node(derived.repo, validator, ['brief', result.brief_path])
}
console.log('PASS: add-issue and done accept resolved-policy files and their derived profiles provision')

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
mkdirSync(join(deferredProvision.root, 'runs', deferredRun), { recursive: true })
writeFileSync(join(deferredProvision.root, 'runs', deferredRun, 'owner-slate'), 's\n')
writeFileSync(join(deferredProvision.root, 'runs', deferredRun, 'run.json'), JSON.stringify({
  schema: 2, run_id: deferredRun, outcome: null,
  dispatch_admission: { slate: 's', working: 1, in_flight: 1, at },
}))
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
// Real independent histories, equal issue numbers and fences, conductor-owned state.
for (const [mapped, retryPrepared] of [[false, false], [true, false], [false, true], [true, true]]) {
  const f = fixture(undefined, 4, 'owner/a')
  const clone = join(temporary, `foreign-${++serial}`)
  mkdirSync(clone)
  git(clone, 'init', '-q', '-b', 'main')
  git(clone, 'remote', 'add', 'origin', 'git@github.com:owner/b.git')
  writeFileSync(join(clone, 'foreign.txt'), 'different history\n')
  mkdirSync(join(clone, 'src'))
  mkdirSync(join(clone, 'scripts'))
  writeFileSync(join(clone, 'src/one'), 'foreign surface\n')
  writeFileSync(join(clone, 'scripts/test-foreign.sh'), 'assert src/one\n')
  if (mapped) {
    writeFileSync(join(clone, 'Taskfile.yml'), "version: '3'\ntasks:\n  worktree:new:\n    cmds:\n      - bash scripts/prepare.sh {{.CLI_ARGS}}\n")
    writeFileSync(join(clone, 'scripts/prepare.sh'), `set -eu
lane="$1"; shift
[ "$1" = --branch ]; branch="$2"; shift 2
[ "$1" = --base ]; base="$2"
git worktree add -b "$branch" ".worktrees/$lane" "$base"
git -C ".worktrees/$lane" branch --set-upstream-to=origin/main
printf prepared > ".worktrees/$lane/prepared.fixture"
`)
  }
  git(clone, 'add', '.')
  git(clone, '-c', 'user.name=test', '-c', 'user.email=test@example.test', 'commit', '-qm', 'foreign base')
  let base = git(clone, 'rev-parse', 'HEAD')
  git(clone, 'update-ref', 'refs/remotes/origin/main', base)
  git(clone, 'symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
  const lane = { ...structuredClone(f.lane), repo: 'owner/b', lane: 'foreign-lane', branch: 'feat/foreign', run_id: 'run-1-foreign', base_sha: base, expansions: [] }
  f.plan.issues.push({ ...structuredClone(f.plan.issues[0]), repo: 'owner/b', url: 'https://github.com/owner/b/issues/1' })
  f.plan.repository_bases = [{ repo: 'owner/b', base_sha: base }]
  f.plan.lanes.push(lane)
  f.plan.lane_profiles.push({ lane: lane.lane, policy: structuredClone(f.plan.lane_profiles[0].policy) })
  if (mapped) {
    lane.wave = 2
    f.plan.waves.push({ number: 2, issues: ['owner/b#1'] })
  } else f.plan.waves[0].issues.push('owner/b#1')
  f.facts.worktree_path = join(clone, '.worktrees', lane.lane)
  f.facts.claim_handoff.branch = lane.branch
  f.publish(); f.saveFacts()
  node(f.repo, writer, ['lock', 'acquire', '--slate', 's', '--session', 'owner', '--owner-token', f.token, '--issues', '1,owner/b#1'])
  // A missing repository and an explicitly wrong origin must fail before writes.
  const args = f.args(lane.lane)
  refusal(f, /no matching clone for owner\/b/, command, [...args, '--repo-root', `owner/b=${f.repo}`])
  const origin = 'git@github.com:owner/b.git'
  git(clone, 'remote', 'set-url', 'origin', 'git@github.com:owner/missing.git')
  refusal(f, /clone for owner\/b/, command, args)
  git(clone, 'remote', 'set-url', 'origin', origin)
  // Hide the test in the current checkout: the recorded base still contains
  // it, so an incomplete fence must still be rejected.
  git(clone, 'switch', '-qc', 'hide-validator')
  git(clone, 'rm', 'scripts/test-foreign.sh')
  git(clone, '-c', 'user.name=test', '-c', 'user.email=test@example.test', 'commit', '-qm', 'hide current-checkout validator')
  const foreignArgs = mapped ? [...args, '--repo-root', `owner/b=${clone}`] : args
  refusal(f, /missing: scripts\/test-foreign\.sh/, command, foreignArgs)
  assert.ok(existsSync(f.facts.worktree_path), 'scan must use the prepared lane worktree at base')
  assert.equal(git(f.facts.worktree_path, 'rev-parse', 'HEAD'), base)
  if (retryPrepared) {
    // Reuse the exact worktree retained by the failed scan. A successful
    // retry must not rerun worktree:new, which would fail on this existing tree.
    lane.expansions.push({ path: 'scripts/test-foreign.sh', at, reason: 'foreign repository consumer' })
    f.publish()
    if (!mapped) git(f.facts.worktree_path, 'branch', '--set-upstream-to=origin/main')
    assert.equal(upstreamMerge(f.facts.worktree_path, lane.branch), 'refs/heads/main', 'fixture must start with a default-branch upstream')
    const retried = JSON.parse(node(f.repo, command, foreignArgs))
    assert.equal(upstreamMerge(f.facts.worktree_path, lane.branch), '', 'retained worktree must lose its default-branch upstream')
    const retryBrief = readFileSync(retried.brief_path, 'utf8')
    assert.ok(retryBrief.includes(mapped ? 'task worktree:new prepared dependencies' : 'dependencies and hooks were NOT prepared'))
    assert.equal(retryBrief.includes('dependencies and hooks were NOT prepared'), !mapped)
    assert.equal(existsSync(join(f.facts.worktree_path, 'prepared.fixture')), mapped)
    assert.equal(git(f.facts.worktree_path, 'rev-parse', 'HEAD'), base)
    assert.equal(git(f.facts.worktree_path, 'branch', '--show-current'), lane.branch)
    git(clone, 'remote', 'set-url', 'origin', 'git@github.com:owner/retired-fixture.git')
    console.log(`PASS: retained ${mapped ? 'task-prepared' : 'unprepared'} worktree retry reports its preparation accurately`)
    continue
  }
  rmSync(join(f.facts.worktree_path, 'prepared.fixture'), { force: true })
  git(clone, 'worktree', 'remove', f.facts.worktree_path)
  git(clone, 'branch', '-D', lane.branch)
  lane.expansions.push({ path: 'scripts/test-foreign.sh', at, reason: 'foreign repository consumer' })
  f.publish()
  git(clone, 'switch', '-q', 'main')
  if (mapped) {
    const conductorLanes = structuredClone(f.plan.lanes.filter((entry) => !entry.repo))
    writeFileSync(join(clone, 'unrelated.txt'), 'new default head\n')
    git(clone, 'add', '.')
    git(clone, '-c', 'user.name=test', '-c', 'user.email=test@example.test', 'commit', '-qm', 'move foreign base')
    base = git(clone, 'rev-parse', 'HEAD')
    git(clone, 'update-ref', 'refs/remotes/origin/main', base)
    refusal(f, /tracking head differs/, command, [...args, '--repo-root', `owner/b=${clone}`])
    node(f.repo, join(support, 'plan-revise.mjs'), ['base-move', '--slate', 's', '--session', 'owner',
      '--owner-token', f.token, '--repo', 'owner/b', '--repo-root', clone,
      '--new-base', base, '--reason', 'foreign later-wave base moved'])
    const revised = JSON.parse(readFileSync(join(f.root, 'slates/s/plan.json'), 'utf8')).revisions.at(-1).plan
    assert.equal(revised.repository_bases.find((entry) => entry.repo === 'owner/b').base_sha, base)
    assert.equal(revised.base_sha, f.plan.base_sha)
    assert.deepEqual(revised.lanes.filter((entry) => !entry.repo), conductorLanes)
  }
  const result = JSON.parse(node(f.repo, command, mapped ? [...args, '--repo-root', `owner/b=${clone}`] : args))
  assert.equal(git(f.facts.worktree_path, 'rev-parse', 'HEAD'), base)
  assert.equal(git(f.facts.worktree_path, 'branch', '--show-current'), lane.branch)
  assert.equal(upstreamMerge(f.facts.worktree_path, lane.branch), '', 'a provisioned lane branch must not track the default branch')
  assert.ok(result.record_directory.startsWith(f.root + '/'))
  assert.ok(result.brief_path.startsWith(f.root + '/'))
  assert.ok(!existsSync(join(clone, '.git/dev-flow-v2')), 'foreign clone must not own slate state')
  const brief = readFileSync(result.brief_path, 'utf8')
  assert.ok(brief.includes('Repository: `owner/b`'))
  assert.ok(brief.includes(mapped ? 'task worktree:new prepared dependencies' : 'dependencies and hooks were NOT prepared'))
  assert.equal(existsSync(join(f.facts.worktree_path, 'prepared.fixture')), mapped)
  const binding = JSON.parse(readFileSync(join(result.record_directory, 'branch.json'), 'utf8'))
  assert.equal(binding.repo, 'owner/b')
  assert.equal(binding.repo_root, clone)
  assert.ok(brief.includes('owner/a#1'), 'same-number other lane must retain its repository')
  assert.ok(brief.includes('https://github.com/owner/b/issues/1'))
  assert.ok(brief.includes(`"base_sha":"${base}"`))
  // Real pass/adjudication/ledger writers run from the conductor, whose
  // object database contains neither the foreign history nor its branch.
  const write = (operation, ...extra) => node(f.repo, writer, [operation, '--slate', 's', '--session', 'owner',
    '--owner-token', f.token, '--run-id', lane.run_id, ...extra])
  write('transition', '--stage', 'claim')
  for (const stage of ['implement', 'verify', 'challenge']) write('transition', '--stage', stage, '--exit', 'fixture complete')
  const passFile = join(f.repo, 'foreign-pass.json'), adjFile = join(f.repo, 'foreign-adjudication.json')
  const slot = JSON.parse(readFileSync(join(result.record_directory, 'policy.json'), 'utf8')).stages.challenge.finders[0]
  const pass = { schema: 2, role: 'challenger', status: 'completed', head: base, produced_at: new Date().toISOString(),
    producer: { harness: 'codex-cli', model: 'fixture-model', tier: 'apex' }, run: { run_id: lane.run_id, initiated_by: 'human' },
    payload: { stage: 'challenge', round: 1, reviewed_head: base, finder: slot, slot, findings: [], counts: { P0: 0, P1: 0, P2: 0, P3: 0 },
      attack_scenarios: [{ id: 'foreign-branch', description: 'branch exists only in foreign clone', outcome: 'held', finding_id: null }] } }
  writeFileSync(passFile, JSON.stringify(pass))
  writeFileSync(adjFile, JSON.stringify({ schema: 2, run_id: lane.run_id, stage: 'challenge', round: 1, reviewed_head: base, adjudications: [] }))
  const recorder = resolve(assets, '../../review/assets/record-pass.sh')
  const recordArgs = [recorder, '--repo-root', f.repo, '--slate', 's', '--session', 'owner', '--owner-token', f.token,
    '--run-id', lane.run_id, '--pass', passFile, '--head', base, '--policy', resolve(assets, '../../../../../.devflow.toml'), '--adjudication', adjFile]
  const recorded = spawnSync('bash', recordArgs, { cwd: f.repo, encoding: 'utf8' })
  assert.equal(recorded.status, 20, recorded.stdout + recorded.stderr)
  assert.equal(JSON.parse(recorded.stdout).reason, 'empty_round')
  assert.ok(existsSync(join(result.record_directory, 'adjudications/challenge-r1.json')))
  assert.ok(JSON.parse(readFileSync(join(result.record_directory, 'heads.json'), 'utf8'))[base])
  const beforeMismatch = snapshot(result.record_directory)
  git(clone, 'remote', 'set-url', 'origin', 'https://github.com/owner/wrong')
  const refusedPass = spawnSync('bash', recordArgs, { cwd: f.repo, encoding: 'utf8' })
  assert.notEqual(refusedPass.status, 0)
  assert.match(refusedPass.stderr, /origin does not match/)
  assert.deepEqual(snapshot(result.record_directory), beforeMismatch)
  git(clone, 'remote', 'set-url', 'origin', origin)
  const evidenceData = join(f.repo, 'evidence-data.json')
  writeFileSync(evidenceData, '[]')
  const markerFile = join(f.repo, 'evidence-marker.json'), bodyFile = join(f.repo, 'evidence-body.md')
  writeFileSync(markerFile, JSON.stringify({ run_id: lane.run_id, stage: 'challenge', round: 1, sequence: 1, destination: 'issue' }))
  writeFileSync(bodyFile, 'Foreign lane round\n\n```json\n' + JSON.stringify({ run_id: lane.run_id, stage: 'challenge', round: 1,
    reviewed_head: base, passes: [pass], findingAttributions: null }) + '\n```\n')
  const scannerBin = join(f.repo, 'scan-bin')
  mkdirSync(scannerBin)
  writeFileSync(join(scannerBin, 'gitleaks'), '#!/bin/sh\ncat >/dev/null\n')
  chmodSync(join(scannerBin, 'gitleaks'), 0o755)
  const posted = spawnSync('bash', [resolve(assets, '../../review/assets/post-evidence.sh'), '--repo', 'owner/b', '--repo-root', f.repo,
    '--run', join(result.record_directory, 'run.json'), '--branch', lane.branch, '--generation', '1', '--active-state', result.active_state_path,
    '--head', base, '--actor-id', '1', '--role', 'challenger', '--finder', slot, '--issue', '1', '--marker-file', markerFile,
    '--body-file', bodyFile, '--scratch-dir', temporary], { cwd: clone, encoding: 'utf8',
    env: { ...process.env, PROVISION_EVIDENCE_FIXTURE: evidenceData, PATH: scannerBin + ':' + process.env.PATH } })
  assert.equal(posted.status, 0, posted.stdout + posted.stderr)
  assert.equal(JSON.parse(readFileSync(join(result.record_directory, 'run.json'), 'utf8')).evidence_comments[0].id, '77')
  // Remove only this disposable clone's origin identity before the next iteration,
  // so automatic discovery continues to have one matching candidate.
  git(clone, 'remote', 'set-url', 'origin', 'git@github.com:owner/retired-fixture.git')
}
console.log('PASS: two-repository provisioning selects verified clone origins, refuses missing/wrong mappings, keeps state under conductor, and unsets a default-branch upstream')

NODE
