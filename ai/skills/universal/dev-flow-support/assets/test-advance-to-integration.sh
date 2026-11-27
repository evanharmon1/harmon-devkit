#!/usr/bin/env bash
# Behavioral test for advance-to-integration.sh: the real run-record writer,
# recorder, exit engine and validators in offline fixture repositories, with
# `gh` and `task` replaced by stubs on PATH. No network, no model calls.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
node --input-type=module - "$asset_dir" "$test_tmp" <<'JS'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdirSync, cpSync, chmodSync, rmSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { execFileSync, spawnSync } from 'node:child_process'
const [assets, tmp] = process.argv.slice(2)
const source = join(assets, '../../../../..')
const skills = join(tmp, 'skills')
for (const name of ['dev-flow-support', 'orchestrate', 'review', 'integrate']) cpSync(join(assets, '../..', name), join(skills, name), { recursive: true })
const support = join(skills, 'dev-flow-support/assets')
const command = join(support, 'advance-to-integration.sh')
const writer = join(support, 'run-record.mjs')
const recorder = join(skills, 'review/assets/record-pass.sh')
const validator = join(support, 'validate-result-schemas.mjs')

// Projection is an independent best-effort observer, covered by the real-path
// regressions in test-stage-labels.sh and test-run-record.sh. Isolate only that
// adapter here so the unchanged trace assertions measure publication control.
writeFileSync(join(support, 'stage-labels.mjs'), 'export function projectRecordBestEffort() { return null }\n')

// Stubs: `task` runs the named gate per STUB_<TARGET>; `gh` serves PRs from a JSON file.
const bin = join(tmp, 'bin'), stub = join(tmp, 'stub')
mkdirSync(bin); mkdirSync(stub)
writeFileSync(join(bin, 'task'), `#!/usr/bin/env bash
echo "task $*" >>"${stub}/calls.log"
case "$1" in security) mode="\${STUB_SECURITY:-0}" ;; guard:closing-keywords) mode="\${STUB_GUARD:-0}"; [ -n "\${PR_BODY:-}" ] || exit 7 ;; *) mode=missing ;; esac
case "$mode" in missing) echo "task: Task \\"$1\\" does not exist" >&2; exit 200 ;; sleep) sleep 30 ;; kill) kill -9 $$ ;; commit) git commit -q --allow-empty -m gate ;; *) exit "$mode" ;; esac
`)
writeFileSync(join(bin, 'gh'), `#!/usr/bin/env node
const fs = require('node:fs'), file = '${stub}/prs.json', args = process.argv.slice(2)
fs.appendFileSync('${stub}/calls.log', 'gh ' + args.join(' ') + '\\n')
const prs = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : []
if (args[1] === 'list') { console.log(JSON.stringify(prs.filter((p) => p.state === 'OPEN'))); process.exit(0) }
if (args[1] === 'create') {
  if (!args.includes('--draft')) process.exit(9)
  const pr = { number: 7, url: 'https://github.com/example/repo/pull/7', state: 'OPEN', isDraft: process.env.STUB_CREATE_DRAFT !== 'false', headRefOid: process.env.STUB_HEAD,
    headRepository: { name: 'repo' }, headRepositoryOwner: { login: 'example' } }
  fs.writeFileSync(file, JSON.stringify([pr]))
  if (process.env.STUB_CRASH_AFTER_CREATE) fs.writeFileSync('${stub}/crash', '')
  console.log(pr.url); process.exit(0)
}
if (args[1] === 'view') {
  if (fs.existsSync('${stub}/crash')) { fs.rmSync('${stub}/crash'); process.exit(1) }
  const ref = args[2], pr = prs.find((p) => String(p.number) === ref || p.url === ref)
  if (!pr) process.exit(1)
  console.log(JSON.stringify(pr)); process.exit(0)
}
process.exit(3)
`)
chmodSync(join(bin, 'task'), 0o755); chmodSync(join(bin, 'gh'), 0o755)
const baseEnv = { ...process.env, PATH: `${bin}:${process.env.PATH}`, GIT_CONFIG_GLOBAL: join(tmp, 'gitconfig'), GIT_CONFIG_NOSYSTEM: '1' }
for (const k of Object.keys(baseEnv)) if (/^(STUB_|RUN_RECORD_OWNER_TOKEN$)/.test(k)) delete baseEnv[k]
const read = (p) => JSON.parse(readFileSync(p, 'utf8'))
const put = (p, v) => writeFileSync(p, `${JSON.stringify(v, null, 2)}\n`)
const calls = () => existsSync(join(stub, 'calls.log')) ? readFileSync(join(stub, 'calls.log'), 'utf8') : ''
const resetStubs = (prs = []) => { put(join(stub, 'prs.json'), prs); rmSync(join(stub, 'calls.log'), { force: true }) }
const creates = () => calls().split('\n').filter((line) => line.startsWith('gh pr create ')).length
const prFor = (number, headRefOid, { isDraft = true, owner = 'example' } = {}) => ({ number, url: `https://github.com/${owner}/repo/pull/${number}`, state: 'OPEN', isDraft, headRefOid,
  headRepository: { name: 'repo' }, headRepositoryOwner: { login: owner } })

// A fixture: its own repo and policy, walked to verify, then through each
// confidence stage the caller names, each converged on one empty round.
// `edit` changes the policy on main and the branch alike; `branchEdit` only on
// the branch, so the merge base keeps the original.
let counter = 0
function fixture({ edit = (toml) => toml, branchEdit, converge = [] }) {
  const n = ++counter, repo = join(tmp, `repo${n}`), remote = join(tmp, `remote${n}.git`), branch = `${n}-advance`
  mkdirSync(repo)
  const sh = (cmd, argv) => execFileSync(cmd, argv, { cwd: repo, env: baseEnv, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
  sh('git', ['init', '-q', '-b', 'main'])
  for (const [k, v] of [['user.name', 'Test'], ['user.email', 'test@example.invalid'], ['commit.gpgsign', 'false']]) sh('git', ['config', k, v])
  const registry = read(join(source, 'agent-registry.json'))
  registry.trusted_orchestrator_actor_ids = [12345]
  put(join(repo, 'agent-registry.json'), registry)
  const toml = edit(readFileSync(join(source, '.devflow.toml'), 'utf8'))
  writeFileSync(join(repo, '.devflow.toml'), toml)
  sh('git', ['add', '.']); sh('git', ['commit', '-qm', 'initial'])
  const base = sh('git', ['rev-parse', 'HEAD'])
  sh('git', ['remote', 'add', 'origin', 'https://github.com/example/repo'])
  sh('git', ['update-ref', 'refs/remotes/origin/main', base])
  sh('git', ['symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main'])
  execFileSync('git', ['init', '-q', '--bare', remote], { env: baseEnv })
  sh('git', ['switch', '-qc', branch])
  writeFileSync(join(repo, 'change.txt'), 'change\n')
  if (branchEdit) writeFileSync(join(repo, '.devflow.toml'), branchEdit(toml))
  sh('git', ['add', '.']); sh('git', ['commit', '-qm', 'feat: fixture'])
  const head = sh('git', ['rev-parse', 'HEAD'])
  const publish = (sha) => sh('git', ['push', '-qf', remote, `${sha}:refs/heads/${branch}`])
  // Only the command's own git calls reach origin through the bare remote.
  const originEnv = { GIT_CONFIG_COUNT: '1', GIT_CONFIG_KEY_0: `url.${remote}.insteadOf`, GIT_CONFIG_VALUE_0: 'https://github.com/example/repo' }
  publish(head)
  // The retained projection is the merge base's resolution, as the owner
  // resolves it for a branch that edits its own policy.
  const mainToml = join(tmp, `main${n}.toml`)
  writeFileSync(mainToml, toml)
  const resolved = spawnSync(process.execPath, [join(support, 'devflow-policy.mjs'), 'resolve', '--policy', mainToml, '--registry', 'agent-registry.json', '--json', '--rigor', 'thorough'], { cwd: repo, env: baseEnv, encoding: 'utf8' })
  assert.ok([0, 3].includes(resolved.status) && resolved.stdout.trim(), resolved.stderr)
  const policyFile = join(tmp, `policy${n}.json`)
  writeFileSync(policyFile, resolved.stdout)
  const policy = read(policyFile)
  const runId = `run-${n}-advance`, slate = `solo-${runId}`
  const token = sh(process.execPath, [writer, 'lock', 'acquire', '--slate', slate, '--session', 'fixture', '--issues', String(n)])
  const identity = JSON.parse(sh(process.execPath, [writer, 'solo-init', '--owner-token', token, '--session', 'fixture', '--run-id', runId, '--issue', String(n), '--title', 'fixture', '--url', `https://github.com/example/repo/issues/${n}`, '--branch', branch, '--base', base, '--policy', policyFile, '--actor-id', '12345', '--strategy-source', 'default_strategy']))
  const dir = identity.record_directory
  const write = (cmd, ...a) => sh(process.execPath, [writer, cmd, '--owner-token', token, '--slate', slate, '--session', 'fixture', '--run-id', runId, ...a])
  write('transition', '--stage', 'claim')
  for (const stage of ['implement', 'verify']) write('transition', '--stage', stage, '--exit', 'fixture done')
  const passFile = join(tmp, `pass${n}.json`), adjFile = join(tmp, `adj${n}.json`)
  const recordRound = (stage, { p2 = false, status = 20 } = {}) => {
    const finder = policy.stages[stage].finders[0]
    const findings = p2 ? [{ id: `${stage}-r1-${finder}-1`, path: 'change.txt', line: 1, class: 'hardening', provenance: 'original', fingerprint: 'new', priority: 'P2', recommended_disposition: 'defer', evidence: 'fixture finding' }] : []
    put(passFile, { schema: 2, role: stage === 'challenge' ? 'challenger' : 'reviewer', status: 'completed', head,
      produced_at: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'), producer: { harness: 'codex-cli', model: 'fixture-model', tier: 'apex' }, run: { run_id: runId, initiated_by: 'human' },
      payload: { stage, round: 1, reviewed_head: head, finder, slot: finder, findings, counts: { P0: 0, P1: 0, P2: findings.length, P3: 0 },
        ...(stage === 'challenge' ? { attack_scenarios: [{ id: 'attack-1', description: 'tried to break fixture', outcome: 'held', finding_id: null }] } : {}) } })
    put(adjFile, { schema: 2, run_id: runId, stage, round: 1, reviewed_head: head, adjudications: findings.map((f) => ({ finding_id: f.id, reviewer_priority: 'P2', adjudicated_priority: 'P2', disposition: 'defer', reason: 'follow-up hardening', evidence: 'fixture proof', override: null })) })
    const r = spawnSync('bash', [recorder, '--repo-root', repo, '--slate', slate, '--session', 'fixture', '--run-id', runId, '--pass', passFile, '--head', head, '--policy', join(repo, '.devflow.toml'), '--adjudication', adjFile], { cwd: repo, env: { ...baseEnv, RUN_RECORD_OWNER_TOKEN: token }, encoding: 'utf8' })
    assert.equal(r.status, status, `fixture ${stage} round 1 exit: ${r.stdout}${r.stderr}`)
  }
  for (const stage of converge) { write('transition', '--stage', stage, '--exit', 'fixture done'); recordRound(stage) }
  const body = join(tmp, `body${n}.md`)
  writeFileSync(body, `Refs #${n}\n`)
  const advance = (env = {}, extra = [], { as = slate } = {}) => {
    const captured = sh('git', ['rev-parse', branch])
    const r = spawnSync('bash', [command, '--repo', 'example/repo', '--slate', as, '--session', 'fixture', '--run-id', runId, '--title', 'feat: fixture', '--body-file', body, ...extra],
      { cwd: repo, env: { ...baseEnv, ...originEnv, RUN_RECORD_OWNER_TOKEN: token, STUB_HEAD: head, ...env }, encoding: 'utf8' })
    if (r.stdout.trim()) {
      const outcome = JSON.parse(r.stdout)
      assert.deepEqual([outcome.run, outcome.head], [{ run_id: runId, generation: 1 }, captured], 'outcome binds the run, generation and captured head')
      const file = join(tmp, `outcome-${n}.json`)
      writeFileSync(file, r.stdout)
      const valid = spawnSync(process.execPath, [validator, 'stage-outcome', file], { encoding: 'utf8' })
      assert.equal(valid.status, 0, `stage outcome invalid: ${valid.stderr}`)
      r.outcome = outcome
    }
    return r
  }
  const record = () => read(join(dir, 'run.json'))
  const stages = () => record().stage_transitions.map((t) => t.stage)
  return { repo, dir, head, base, sh, write, publish, advance, stages, recordRound, record }
}
const expect = (r, code, outcome, label) => {
  assert.equal(r.status, code, `${label}: ${r.stdout}${r.stderr}`)
  assert.equal(r.outcome?.outcome, outcome, `${label}: outcome`)
}

// 1. Default policy: challenge, then review, each capped at 4; review_trigger after-ci.
const f = fixture({ converge: ['challenge'] })
const runBytes = () => readFileSync(join(f.dir, 'run.json'), 'utf8')
const unchanged = (label, fn) => { const before = runBytes(); fn(); assert.equal(runBytes(), before, `${label}: run.json changed`) }
resetStubs()
unchanged('review owed', () => expect(f.advance(), 4, 'judgment-needed', 'challenge advance while review is owed'))
f.write('transition', '--stage', 'review', '--exit', 'converged: fixture')
unchanged('not converged', () => expect(f.advance(), 4, 'judgment-needed', 'review has no advance verdict'))
f.recordRound('review')
writeFileSync(join(f.repo, 'later.txt'), 'later\n')
f.sh('git', ['add', '.']); f.sh('git', ['commit', '-qm', 'fix: later'])
unchanged('head moved', () => expect(f.advance(), 4, 'judgment-needed', 'head moved past the converged round'))
f.sh('git', ['reset', '-q', '--hard', f.head])
// The shipped engine never advances past a moved head, but a supplied
// (merge-base) engine is not this one: an advance whose last round reviewed
// another head is refused by the command's own reviewed-head guard.
mkdirSync(join(tmp, 'stale/lib'), { recursive: true })
cpSync(join(support, 'lib/merge-base-policy.sh'), join(tmp, 'stale/lib/merge-base-policy.sh'))
const staleEngine = join(tmp, 'stale/stale-engine.mjs')
const { challenge, review, integration, remediation, min_rounds } = read(join(f.dir, 'policy.json')).rounds
const resolvedRounds = JSON.stringify({ challenge, review, integration, remediation, min_rounds })
writeFileSync(staleEngine, `const verification = process.argv.includes('--verification-only')
console.log(JSON.stringify({ stage: 'review', outcome: 'converged', reason: 'empty_round', action: 'advance', diagnostics: [], ...(verification ? { rounds: [{ round: 1, reviewed_head: '${f.base}' }], resolved_rounds: ${resolvedRounds} } : {}) }))
process.exitCode = 20
`)
unchanged('reviewed head differs', () => {
  const stale = f.advance({}, ['--exit-engine', staleEngine])
  expect(stale, 4, 'judgment-needed', 'last round reviewed another head')
  assert.match(stale.stderr, new RegExp(`review round 1 reviewed ${f.base}, but the branch head is ${f.head}`), 'the reviewed-head guard refuses it')
})
writeFileSync(join(f.repo, '.devflow.toml'), `${readFileSync(join(f.repo, '.devflow.toml'), 'utf8')}# uncommitted\n`)
unchanged('dirty policy', () => expect(f.advance(), 3, 'terminal-blocker', 'uncommitted policy edit before the verdict'))
f.sh('git', ['checkout', '--', '.devflow.toml'])
assert.equal(calls(), '', 'no gate or GitHub call before an advance verdict')
console.log('PASS: only an advance verdict on the captured head starts the chain')

for (const [label, env, extra = []] of [
  ['gate exits non-zero', { STUB_SECURITY: '1' }],
  ['gate target missing', { STUB_SECURITY: 'missing' }],
  ['gate times out', { STUB_SECURITY: 'sleep' }, ['--security-timeout-sec', '1']],
  ['gate is killed', { STUB_SECURITY: 'kill' }],
  ['gate commits during the run', { STUB_SECURITY: 'commit' }],
]) {
  resetStubs()
  expect(f.advance(env, extra), 3, 'terminal-blocker', label)
  f.sh('git', ['reset', '-q', '--hard', f.head])
  assert.equal(f.stages().at(-1), 'security', `${label}: run stays in security`)
  assert.ok(!calls().includes('gh '), `${label}: no PR work after a failed gate`)
}
writeFileSync(join(f.repo, 'stray.txt'), 'untracked\n')
resetStubs()
expect(f.advance(), 3, 'terminal-blocker', 'dirty worktree')
assert.ok(!calls().includes('task security'), 'a dirty worktree never runs the gate')
rmSync(join(f.repo, 'stray.txt'))
resetStubs()
expect(f.advance({ RUN_RECORD_OWNER_TOKEN: 'not-the-owner-token' }), 2, 'terminal-blocker', 'invalid owner token on a security rerun')
assert.equal(calls(), '', 'an unproven owner runs no gate and publishes nothing')
const otherToken = f.sh(process.execPath, [writer, 'lock', 'acquire', '--slate', 'other-slate', '--session', 'fixture', '--issues', '99'])
expect(f.advance({ RUN_RECORD_OWNER_TOKEN: otherToken }, [], { as: 'other-slate' }), 2, 'terminal-blocker', 'valid token for a slate that does not own the run')
assert.equal(calls(), '', 'another slate runs no gate and publishes nothing')
assert.equal(f.stages().filter((s) => s === 'security').length, 1, 'resume never re-enters security')
assert.match(f.record().stage_transitions.at(-2).exit, new RegExp(`^converged: [a-z_]+, round 1 at ${f.head}$`))
console.log('PASS: a failed or indeterminate pre_pr gate blocks the transition')

const otherHead = prFor(3, f.base)
const notDraft = prFor(4, f.head, { isDraft: false })
for (const [label, env, prs = [], setup = () => {}, teardown = () => {}] of [
  ['closing-keywords preflight fails', { STUB_GUARD: '1' }],
  ['remote branch is not at the head', {}, [], () => f.publish(f.base), () => f.publish(f.head)],
  ['open PR at another head', {}, [otherHead]],
  ['open PR that is not a draft', {}, [notDraft]],
  ['created PR is not a draft', { STUB_CREATE_DRAFT: 'false' }],
]) {
  resetStubs(prs); setup()
  expect(f.advance(env), 5, 'terminal-blocker', label)
  teardown()
  assert.equal(f.record().pr, null, `${label}: nothing bound`)
  assert.equal(f.stages().at(-1), 'security', `${label}: integration not entered`)
}
console.log('PASS: the draft is published, adopted and verified, or the chain stops')

resetStubs()
expect(f.advance({ STUB_CRASH_AFTER_CREATE: '1' }), 5, 'terminal-blocker', 'crash after the PR exists')
assert.equal(f.record().pr, null)
const resumed = f.advance()
expect(resumed, 0, 'progress', 'restart adopts the PR')
assert.equal(creates(), 1, 'no second PR is opened')
assert.match(calls(), /gh pr create --draft /)
assert.deepEqual(f.record().pr, { number: 7, url: 'https://github.com/example/repo/pull/7' })
assert.deepEqual(f.stages().slice(-3), ['review', 'security', 'integration'])
assert.equal(resumed.outcome.next_action.stage, 'integration')
assert.match(resumed.outcome.detail, /drive-codex-cycle\.sh, which waits for CI/)
expect(f.advance(), 0, 'progress', 'rerun after integration entry')
assert.equal(f.stages().filter((s) => s === 'integration').length, 1, 'a rerun enters integration once')
assert.equal(creates(), 1)
console.log('PASS: a crash after the PR exists adopts it on restart; reruns are idempotent')

// 2. Review cap 0 lets challenge advance; a with-push trigger names the driver now.
const g = fixture({
  edit: (toml) => toml.replace(/(\[rounds\.thorough\][^[]*?review\s*=\s*)4/, '$10').replace(/^review_trigger = "after-ci"$/m, 'review_trigger = "with-push"'),
  converge: ['challenge'],
})
// A same-named fork PR is never adopted, and a missing trigger-timing checker
// blocks before integration is entered.
const checker = join(skills, 'integrate/assets/check-codex-cloud-review.sh')
resetStubs([prFor(5, g.head, { owner: 'someone' })])
cpSync(checker, `${checker}.saved`); rmSync(checker)
expect(g.advance(), 2, 'terminal-blocker', 'trigger-timing checker missing')
cpSync(`${checker}.saved`, checker); rmSync(`${checker}.saved`)
assert.equal(creates(), 1, 'the fork PR was ignored and the lane opened its own')
assert.equal(g.stages().at(-1), 'security', 'a missing checker blocks before integration')
assert.equal(g.record().pr, null)
const pushed = g.advance()
expect(pushed, 10, 'progress', 'challenge advance under review cap 0')
assert.deepEqual(g.stages().slice(-3), ['challenge', 'security', 'integration'])
assert.match(pushed.outcome.detail, /drive-codex-cycle\.sh now/)
assert.equal(creates(), 1)
assert.deepEqual(g.record().pr, { number: 7, url: 'https://github.com/example/repo/pull/7' })
console.log('PASS: review cap 0 advances from challenge; with-push names the driver now; fork PRs and a missing checker never enter integration')

// A crash between the integration transition and bind-pr: the rerun binds the
// verified draft without opening another one; a non-draft is never bound, and a
// branch that moved after the gates is never bound either.
const k = fixture({ converge: ['challenge', 'review'] })
k.write('transition', '--stage', 'security', '--exit', 'converged: fixture')
k.write('transition', '--stage', 'integration', '--exit', `security: security exit 0 at ${k.head}; draft PR #9`)
writeFileSync(join(k.repo, 'later.txt'), 'later\n')
k.sh('git', ['add', '.']); k.sh('git', ['commit', '-qm', 'fix: later'])
resetStubs([prFor(9, k.sh('git', ['rev-parse', 'HEAD']))])
expect(k.advance(), 4, 'judgment-needed', 'branch moved after integration entry')
assert.equal(k.record().pr, null, 'a moved head binds nothing')
k.sh('git', ['reset', '-q', '--hard', k.head])
resetStubs([{ ...notDraft, headRefOid: k.head }])
expect(k.advance(), 5, 'terminal-blocker', 'unbound integration entry with a non-draft PR')
assert.equal(k.record().pr, null)
resetStubs([prFor(9, k.head)])
expect(k.advance(), 0, 'progress', 'unbound integration entry')
assert.deepEqual(k.record().pr, { number: 9, url: 'https://github.com/example/repo/pull/9' })
assert.equal(creates(), 0, 'binding after integration entry opens no PR')
assert.ok(!calls().includes('task security'), 'an entered integration does not re-run the gate')
console.log('PASS: a crash before bind-pr binds the existing draft on restart')

// A branch that lowers its own review cap cannot advance on it: with no
// merge-base flag the merge base's cap of 4 governs, and one P2-only round is
// not convergence there, although the branch's cap of 1 calls it a clean cap.
const m = fixture({ branchEdit: (toml) => toml.replace(/(\[rounds\.thorough\][^[]*?review\s*=\s*)4/, '$11'), converge: ['challenge'] })
m.write('transition', '--stage', 'review', '--exit', 'converged: fixture')
m.recordRound('review', { p2: true, status: 25 })
resetStubs()
expect(m.advance(), 4, 'judgment-needed', 'self-lowered review cap')
assert.equal(m.stages().at(-1), 'review', 'the branch policy never advances its own run')
assert.equal(calls(), '')
console.log('PASS: the merge-base policy governs when no merge-base flag is passed')

// A retained policy.json that drifted from the policy the engine resolves
// (review 0 retained, 4 resolved) would pick challenge as the stage to leave:
// the drift blocks before any gate, PR or record write.
const d = fixture({ converge: ['challenge'] })
const retained = read(join(d.dir, 'policy.json'))
retained.rounds.review = 0
put(join(d.dir, 'policy.json'), retained)
const driftBefore = readFileSync(join(d.dir, 'run.json'), 'utf8')
resetStubs()
expect(d.advance(), 2, 'terminal-blocker', 'retained rounds drift from the resolved policy')
assert.equal(readFileSync(join(d.dir, 'run.json'), 'utf8'), driftBefore, 'drift writes no record')
assert.equal(calls(), '', 'drift runs no gate and publishes nothing')
console.log('PASS: retained-policy drift from the engine resolution blocks')

// 3. Both confidence caps 0 and no integration cycle: the cap-0 verdict advances verify.
const h = fixture({
  edit: (toml) => toml.replace(/(\[rounds\.thorough\][^[]*?)challenge\s*=\s*4([^[]*?)review\s*=\s*4([^[]*?)integration\s*=\s*5([^[]*?)min_rounds\s*=\s*1/, '$1challenge = 0$2review = 0$3integration = 0$4min_rounds = 0'),
})
resetStubs()
const capped = h.advance()
expect(capped, 11, 'progress', 'cap-0 advance from verify')
assert.deepEqual(h.stages().slice(-3), ['verify', 'security', 'integration'])
assert.match(h.record().stage_transitions.at(-3).exit, new RegExp(`^capped: disabled at ${h.head}$`))
assert.match(h.record().stage_transitions.at(-2).exit, new RegExp(`^security: security exit 0 at ${h.head}; draft PR #7$`))
console.log('PASS: a cap-0 stage advances; integration cap 0 owes no cycle')

// An integration cap above 0 with codex-cloud not gating owes no Codex cycle
// either: the command agrees with the shared codexRequired.
const ungated = (toml) => {
  const edited = toml.replace(/(\{ id = "codex-cloud",.*?gates = )true/, '$1false')
  assert.notEqual(edited, toml, 'fixture disables codex-cloud gating')
  return edited
}
const q = fixture({ edit: ungated, converge: ['challenge', 'review'] })
assert.ok(read(join(q.dir, 'policy.json')).rounds.integration > 0)
resetStubs()
expect(q.advance(), 11, 'progress', 'Codex not required under a positive integration cap')
assert.equal(q.stages().at(-1), 'integration')
console.log('PASS: Codex not required owes no cycle under a positive integration cap')

const usage = spawnSync('bash', [command], { encoding: 'utf8' })
assert.equal(usage.status, 2); assert.equal(usage.stdout, ''); assert.match(usage.stderr, /usage: /)
assert.doesNotMatch(usage.stderr, /--remote/, 'origin is the only remote checked')
console.log('PASS: usage errors exit 2 without an outcome')
JS
