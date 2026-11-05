#!/usr/bin/env bash
# test-post-round.sh — behavioural test for review's post-round.sh, the one
# command that publishes an adjudicated round (harmon-devkit#1416).
#
# A real solo run is built with the shipped writers (solo-init, transition,
# receipt, adjudicate, ledger, the exit engine). post-round.sh then assembles
# the round's marker, projection and round table and hands them to
# post-evidence.sh against a fake `gh`. The test proves:
#   - one comment per round, with the canonical first-line marker, registered
#     in run.json; a re-post adopts it and posts nothing;
#   - retro-run-report.mjs --pr discovers the resulting marker (exit 0);
#   - the same asset runs from a consumer's flattened skills layout;
#   - an integration round whose pass is named `integrator` publishes;
#   - a missing adjudication and a renderer failure each fail visibly, with
#     the cause on stderr and no POST.
# Hermetic and offline: fake `gh` and `gitleaks` on PATH, no network.
# Run via `task test:post-round`.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
command -v node >/dev/null 2>&1 || {
    echo "TEST FAIL: node is required" >&2
    exit 1
}
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

source_root="$(git -C "$asset_dir" rev-parse --show-toplevel)"
# Execute tools from a current, isolated Git root, independent of the outer branch.
tool_root="${test_tmp}/tool-root"
mkdir -p "$tool_root"
cp -R "$source_root/ai" "$tool_root/ai"
cp "$source_root/.devflow.toml" "$source_root/agent-registry.json" "$source_root/.gitleaks.toml" "$tool_root/"
git init -q -b main "$tool_root"
git -C "$tool_root" add ai .devflow.toml agent-registry.json .gitleaks.toml
git -C "$tool_root" -c user.name=test -c user.email=test@example.test commit -qm 'controlled executing tools'
git -C "$tool_root" update-ref refs/remotes/origin/main HEAD
git -C "$tool_root" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
node --input-type=module - "$tool_root" "$test_tmp" <<'JS'
import assert from 'node:assert/strict'
import { readFileSync, writeFileSync, mkdirSync, chmodSync, cpSync, existsSync, readdirSync } from 'node:fs'
import { execFileSync, spawnSync } from 'node:child_process'
import { join } from 'node:path'

const [source, tmp] = process.argv.slice(2)
const skills = join(source, 'ai/skills/universal')
const support = join(skills, 'dev-flow-support/assets')
const runRecord = join(support, 'run-record.mjs')
const monitor = join(skills, 'orchestrate/assets/dev-flow-monitor.sh')
const postRound = join(skills, 'review/assets/post-round.sh')
const read = (p) => JSON.parse(readFileSync(p, 'utf8'))
const put = (p, v) => writeFileSync(p, `${JSON.stringify(v, null, 2)}\n`)
const pass = (message) => console.log(`PASS: ${message}`)

const env = { ...process.env, GIT_CONFIG_GLOBAL: join(tmp, 'gitconfig'), GIT_CONFIG_NOSYSTEM: '1' }
delete env.GIT_CONFIG_COUNT
delete env.GIT_CONFIG_PARAMETERS
for (const key of Object.keys(env)) if (/^GIT_CONFIG_(KEY|VALUE)_/.test(key)) delete env[key]
const repo = join(tmp, 'repo')
const sh = (cmd, args, opts = {}) => execFileSync(cmd, args, { cwd: repo, env, encoding: 'utf8', ...opts }).trim()
const run = (cmd, args, opts = {}) => spawnSync(cmd, args, { cwd: repo, env, encoding: 'utf8', ...opts })
const commitAll = (message) => {
  sh('git', ['add', '.'])
  sh('git', ['commit', '-q', '-m', message])
  return sh('git', ['rev-parse', 'HEAD'])
}

// ---------------------------------------------------------------------------
// A scratch consumer repository with a real policy, registry and a branch.
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
// Integration cap 0 keeps the integrator fixture independent of a paid
// review service (codex_cycle may be null only under a disabled cap), exactly
// as test-post-evidence.sh's integration lifecycle does.
writeFileSync(join(repo, '.devflow.toml'), readFileSync(join(source, '.devflow.toml'), 'utf8').replace(
  /(\[rounds\.standard\]\n)([\s\S]*?)(?=\n\[|$)/,
  (_, heading, table) => heading + table.replace(/^integration\s*=\s*\d+/m, 'integration = 0')))
cpSync(join(source, '.gitleaks.toml'), join(repo, '.gitleaks.toml'))
const base = commitAll('chore: initial')
sh('git', ['remote', 'add', 'origin', 'https://github.com/example/repo'])
sh('git', ['update-ref', 'refs/remotes/origin/main', base])
sh('git', ['symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main'])
const ISSUE = 1
const PR = 2
const BRANCH = '1-round'
const RUN = 'run-1-round'
sh('git', ['switch', '-q', '-c', BRANCH])
writeFileSync(join(repo, 'change.txt'), 'the change under review\n')
const head = commitAll('feat: a change')

const policyFile = join(tmp, 'policy.json')
const resolved = spawnSync('node', [join(support, 'devflow-policy.mjs'), 'resolve', '--policy', '.devflow.toml', '--registry', 'agent-registry.json', '--json'], { cwd: repo, env, encoding: 'utf8' })
assert.ok([0, 3].includes(resolved.status), resolved.stderr)
writeFileSync(policyFile, resolved.stdout)
const policy = read(policyFile)
const SESSION = 'post-round-session'
const slate = `solo-${RUN}`
const token = sh('node', [runRecord, 'lock', 'acquire', '--slate', slate, '--session', SESSION, '--issues', String(ISSUE)])
const init = run('node', [runRecord, 'solo-init', '--owner-token', token, '--session', SESSION, '--run-id', RUN, '--issue', String(ISSUE),
  '--title', 'A change', '--url', `https://github.com/example/repo/issues/${ISSUE}`, '--branch', BRANCH, '--base', base,
  '--policy', policyFile, '--actor-id', String(ACTOR), '--strategy-source', 'default_strategy'])
assert.equal(init.status, 0, init.stderr)
const identity = JSON.parse(init.stdout)
const record = identity.record_directory
const runJson = join(record, 'run.json')
const slateArgs = ['--slate', slate, '--session', SESSION, '--owner-token', token, '--run-id', RUN]
const write = (...args) => {
  const out = run('node', [runRecord, args[0], ...slateArgs, ...args.slice(1)])
  assert.equal(out.status, 0, `${args.join(' ')}: ${out.stderr}`)
  return out.stdout
}
write('transition', '--stage', 'claim')
write('transition', '--stage', 'implement', '--exit', 'claimed')
write('transition', '--stage', 'verify', '--exit', `committed ${head}`)
write('transition', '--stage', 'challenge', '--exit', 'task verify VERIFY-EXIT=0')

const scratch = join(tmp, 'scratch')
mkdirSync(scratch)
const now = () => new Date().toISOString().replace(/\.[0-9]{3}Z$/, 'Z')
const envelope = (role, stage, round, finder, findings) => ({
  schema: 2, role, status: 'completed', head, produced_at: now(),
  producer: { harness: 'claude-code', model: 'claude-opus-5-5', tier: 'frontier' },
  run: { run_id: RUN, initiated_by: 'human' },
  payload: {
    stage, round, reviewed_head: head, finder, slot: finder, findings,
    counts: ['P0', 'P1', 'P2', 'P3'].reduce((c, p) => ({ ...c, [p]: findings.filter((f) => f.priority === p).length }), {}),
    ...(role === 'challenger' ? { attack_scenarios: [{ id: 'as-1', description: 'tried to break the change', outcome: 'held', finding_id: null }] } : {}),
  },
})
const file = (name, value) => { const f = join(scratch, name); put(f, value); return f }
const adjudication = (stage, round, entries) => ({ schema: 2, run_id: RUN, stage, round, reviewed_head: head, adjudications: entries })
const exitEngine = join(support, 'dev-flow-exit.sh')
const computeExit = (stage, verificationOnly) => {
  write('ledger', '--stage', stage)
  const out = run('bash', [exitEngine, '--run', record, '--stage', stage, '--policy', join(repo, '.devflow.toml'),
    '--rigor', read(join(record, 'policy.json')).rigor.level, '--current-head', head,
    '--history', join(record, `history.${stage}.json`), '--heads', join(record, 'heads.json'), '--repo-root', repo, '--json',
    ...(verificationOnly ? ['--verification-only'] : [])])
  assert.ok(out.stdout, out.stderr)
  const json = JSON.parse(out.stdout)
  if (!verificationOnly) put(join(record, 'verdict.json'), json)
  return json
}
const adjudicateRound = (stage, round, doc) => {
  assert.equal(computeExit(stage, true).action, 'adjudicate')
  write('adjudicate', '--file', file(`${stage}-r${round}.adj.json`, doc))
  return computeExit(stage, false)
}
const challengeFinder = policy.stages.challenge.finders[0]
const reviewFinder = policy.stages.review.finders[0]
write('receipt', '--pass', file('challenge-r1.json', envelope('challenger', 'challenge', 1, challengeFinder, [])))
assert.equal(adjudicateRound('challenge', 1, adjudication('challenge', 1, [])).outcome, 'converged')

// ---------------------------------------------------------------------------
// Fake GitHub: the issue, its closing PR, comments, and the registry history.
// ---------------------------------------------------------------------------
const bin = join(tmp, 'bin')
mkdirSync(bin)
const db = join(tmp, 'github.json')
env.POST_ROUND_GH_DB = db
env.PATH = `${bin}:${env.PATH}`
put(db, {
  login: 'writer', actor: ACTOR, next_id: 100, posts: 0, comments: {},
  prs: { [PR]: { number: PR, url: `https://github.com/example/repo/pull/${PR}`, title: 'feat: a change', state: 'OPEN', isDraft: true,
    body: `Closes #${ISSUE}\n`, closingIssuesReferences: [{ number: ISSUE }] } },
  registry: Buffer.from(JSON.stringify(registry)).toString('base64'),
  base,
})
writeFileSync(join(bin, 'gh'), `#!/usr/bin/env node
const fs = require('node:fs')
const p = process.env.POST_ROUND_GH_DB
const d = JSON.parse(fs.readFileSync(p, 'utf8'))
const a = process.argv.slice(2)
const out = (v) => { process.stdout.write(JSON.stringify(v) + '\\n'); process.exit(0) }
const page = (v) => out(a.includes('--slurp') ? [v] : v)
if (a[0] === 'repo' && a[1] === 'view') { process.stdout.write('https://github.com/example/repo\\n'); process.exit(0) }
if (a[0] === 'pr' && a[1] === 'view') {
  if (!d.prs[a[2]]) { process.stderr.write('HTTP 404\\n'); process.exit(1) }
  out(d.prs[a[2]])
}
if (a[0] !== 'api') { process.stderr.write('fake gh: unsupported ' + a.join(' ') + '\\n'); process.exit(1) }
if (a[1] === 'user') {
  if (a.includes('--jq')) { process.stdout.write(String(d.actor) + '\\n'); process.exit(0) }
  out({ id: d.actor, login: d.login })
}
const endpoint = a.find((x) => x.startsWith('repos/')) || ''
const path = endpoint.split('?')[0]
let m
if ((m = /^repos\\/example\\/repo\\/issues\\/([0-9]+)\\/comments$/.exec(path))) {
  const n = m[1]
  if (a.includes('-F')) {
    const body = fs.readFileSync(a[a.indexOf('-F') + 1].slice('body=@'.length), 'utf8')
    const comment = { id: d.next_id++, user: { id: d.actor, login: d.login }, body, created_at: new Date().toISOString(), updated_at: new Date().toISOString() }
    ;(d.comments[n] = d.comments[n] || []).push(comment)
    d.posts++
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
if (/^repos\\/example\\/repo\\/commits\\/[0-9a-f]+\\/pulls$/.test(path)) page([{ number: 1000, merged_at: '2026-01-01T00:00:00Z', base: { ref: 'main', repo: { full_name: 'example/repo' } } }])
if (path === 'repos/example/repo/contents/agent-registry.json') out({ type: 'file', encoding: 'base64', sha: 'a'.repeat(40), content: d.registry })
page([])
`)
chmodSync(join(bin, 'gh'), 0o755)
writeFileSync(join(bin, 'gitleaks'), '#!/usr/bin/env bash\ncat >/dev/null\n[ "$1" != detect ] || echo "[]"\nexit 0\n')
chmodSync(join(bin, 'gitleaks'), 0o755)

// ---------------------------------------------------------------------------
// 1. One command publishes the round; the publisher's guarantees hold.
// ---------------------------------------------------------------------------
const roundArgs = (stage, round, role, finder, extra = []) => ['--repo', 'example/repo', '--run', RUN, '--issue', String(ISSUE), '--branch', BRANCH,
  '--stage', stage, '--round', String(round), '--head', head, '--role', role, '--finder', finder, ...extra]
const markerRe = (stage, round) => new RegExp(`^<!-- dev-flow-v2-evidence: ${JSON.stringify({ run_id: RUN, stage, round, sequence: 1, destination: 'issue' }).replace(/[{}[\]().*+?^$|\\]/g, '\\$&')} -->\\n\\n`)
// --repo-root is omitted: the current checkout is the run's repository, and
// --actor-id is omitted: the authenticated actor is resolved through gh.
let r = run('bash', [postRound, ...roundArgs('challenge', 1, 'challenger', challengeFinder)])
assert.equal(r.status, 0, r.stderr)
const challengeComment = r.stdout.trim()
let github = read(db)
assert.equal(github.posts, 1)
assert.equal(github.comments[ISSUE].length, 1)
assert.equal(String(github.comments[ISSUE][0].id), challengeComment)
const challengeBody = github.comments[ISSUE][0].body
assert.match(challengeBody, markerRe('challenge', 1))
assert.match(challengeBody, /\*\*Dev flow v2 — challenge round 1\*\*/)
const fences = [...challengeBody.matchAll(/```json\n([\s\S]*?)\n```/g)]
assert.equal(fences.length, 1)
const projection = JSON.parse(fences[0][1])
assert.deepEqual([projection.run_id, projection.stage, projection.round, projection.reviewed_head], [RUN, 'challenge', 1, head])
assert.equal(projection.passes.length, 1)
assert.equal(projection.passes[0].payload.finder, challengeFinder)
assert.deepEqual(projection.adjudication, read(join(record, 'adjudications/challenge-r1.json')))
assert.equal(projection.exit.outcome, 'converged')
assert.match(challengeBody, /### Round/)
let runDoc = read(runJson)
assert.equal(runDoc.evidence_comments.length, 1)
assert.equal(runDoc.evidence_comments[0].id, challengeComment)
assert.deepEqual(runDoc.evidence_comments[0].marker, { run_id: RUN, stage: 'challenge', round: 1, sequence: 1, destination: 'issue' })
pass('post-round.sh assembles marker, projection (passes, adjudication, exit) and round table from the record and publishes once through post-evidence.sh')

// A re-post adopts the landed comment: same id, no second POST, no second
// registration — the guarantee post-evidence.sh already provides.
r = run('bash', [postRound, ...roundArgs('challenge', 1, 'challenger', challengeFinder, ['--repo-root', repo, '--actor-id', String(ACTOR)])])
assert.equal(r.status, 0, r.stderr)
assert.equal(r.stdout.trim(), challengeComment)
assert.match(r.stderr, /already reserved; re-arming with the persisted body/)
github = read(db)
assert.equal(github.posts, 1)
assert.equal(github.comments[ISSUE].length, 1)
assert.equal(read(runJson).evidence_comments.length, 1)
pass('re-posting the same round adopts the existing comment: no duplicate comment, no duplicate registration')

// ---------------------------------------------------------------------------
// 2. Failures are visible: a missing adjudication and a renderer failure.
// ---------------------------------------------------------------------------
r = run('bash', [postRound, ...roundArgs('challenge', 2, 'challenger', challengeFinder)])
assert.equal(r.status, 2)
assert.match(r.stderr, /post-round: round challenge-r2 has no retained adjudication \(.*adjudications\/challenge-r2\.json\)/)
assert.equal(read(db).posts, 1)
pass('a round with no retained adjudication fails with exit 2, names the missing file on stderr, and posts nothing')

// A consumer's flattened layout: the three packages side by side under one
// skills directory, no ai/skills/universal/ prefix and no repository root.
const consumer = join(tmp, 'consumer/.claude/skills')
mkdirSync(consumer, { recursive: true })
for (const name of ['review', 'orchestrate', 'dev-flow-support']) cpSync(join(skills, name), join(consumer, name), { recursive: true })
const consumerRender = join(consumer, 'dev-flow-support/assets/render-dev-flow.sh')
const goodRender = readFileSync(consumerRender, 'utf8')
writeFileSync(consumerRender, '#!/usr/bin/env bash\necho "render-dev-flow: synthetic renderer failure" >&2\nexit 7\n')
// Round 1 of review: receipt, adjudicate, then try to publish through a
// renderer that fails.
write('transition', '--stage', 'review', '--exit', `converged: empty_round after challenge round 1/${policy.rounds.challenge}`)
write('receipt', '--pass', file('review-r1.json', envelope('reviewer', 'review', 1, reviewFinder, [])))
assert.equal(adjudicateRound('review', 1, adjudication('review', 1, [])).outcome, 'converged')
r = run('bash', [join(consumer, 'review/assets/post-round.sh'), ...roundArgs('review', 1, 'reviewer', reviewFinder)])
assert.equal(r.status, 2)
assert.match(r.stderr, /render-dev-flow: synthetic renderer failure/)
assert.match(r.stderr, /post-round: render-dev-flow\.sh round-table failed \(exit 7\)/)
assert.equal(read(db).posts, 1)
assert.equal(read(runJson).evidence_comments.length, 1)
assert.equal(existsSync(join(record, 'evidence-issue-review-r1-s1.body.md')), false)
pass('a renderer failure surfaces the renderer\'s own stderr and exit status, reserves nothing and posts nothing')

// Restore the renderer: the same flattened layout now publishes the round.
writeFileSync(consumerRender, goodRender)
r = run('bash', [join(consumer, 'review/assets/post-round.sh'), ...roundArgs('review', 1, 'reviewer', reviewFinder)])
assert.equal(r.status, 0, r.stderr)
github = read(db)
assert.equal(github.posts, 2)
assert.match(github.comments[ISSUE][1].body, markerRe('review', 1))
assert.equal(read(runJson).evidence_comments.length, 2)
pass('the asset runs from a flattened consumer skills layout with only its vendored sibling packages')

// A verdict.json left by another stage is refused rather than published.
const verdictFile = join(record, 'verdict.json')
const reviewVerdict = readFileSync(verdictFile, 'utf8')
put(verdictFile, { ...read(verdictFile), stage: 'challenge' })
write('receipt', '--pass', file('review-r2.json', envelope('reviewer', 'review', 2, reviewFinder, [])))
write('adjudicate', '--file', file('review-r2.adj.json', adjudication('review', 2, [])))
r = run('bash', [postRound, ...roundArgs('review', 2, 'reviewer', reviewFinder)])
assert.equal(r.status, 2)
assert.match(r.stderr, /verdict\.json is the exit for stage challenge, not review/)
assert.equal(read(db).posts, 2)
writeFileSync(verdictFile, reviewVerdict)
r = run('bash', [postRound, ...roundArgs('review', 2, 'reviewer', 'not-a-finder')])
assert.equal(r.status, 2)
assert.match(r.stderr, new RegExp(`no receipted pass for finder not-a-finder; receipted: review-r2-${reviewFinder}`))
assert.equal(read(db).posts, 2)
pass('a verdict for another stage and an unreceipted finder are refused before any reservation or POST')
computeExit('review', false)
r = run('bash', [postRound, ...roundArgs('review', 2, 'reviewer', reviewFinder)])
assert.equal(r.status, 0, r.stderr)
assert.equal(read(runJson).evidence_comments.length, 3)

// ---------------------------------------------------------------------------
// 3. An integration round whose receipted pass is named `integrator`.
// ---------------------------------------------------------------------------
write('transition', '--stage', 'security', '--exit', `converged: empty_round after review round 2/${policy.rounds.review}`)
write('transition', '--stage', 'integration', '--exit', 'task security SECURITY-EXIT=0; draft PR opened')
write('bind-pr', '--number', String(PR), '--url', `https://github.com/example/repo/pull/${PR}`)
const produced = now()
write('receipt', '--pass', file('integration-r1.json', { schema: 2, role: 'integrator', status: 'completed', head, produced_at: produced,
  producer: { harness: 'codex-cli', model: 'fixture-model', tier: 'economy' }, run: { run_id: RUN, initiated_by: 'human' },
  payload: { checks: [{ name: 'verify', bucket: 'pass', run_id: '1', required: true }], codex_cycle: null, integration_round: 1,
    findings: [], unanswered_thread_roots: [], settled_at: produced, verdict: 'clean', applied_dispositions: [] } }))
assert.ok(existsSync(join(record, 'passes/integration-r1-integrator.json')))
write('adjudicate', '--file', file('integration-r1.adj.json', adjudication('integration', 1, [])))
r = run('bash', [postRound, ...roundArgs('integration', 1, 'integrator', 'integrator')])
assert.equal(r.status, 0, r.stderr)
github = read(db)
assert.equal(github.posts, 4)
assert.match(github.comments[ISSUE][3].body, markerRe('integration', 1))
const integrationProjection = JSON.parse(/```json\n([\s\S]*?)\n```/.exec(github.comments[ISSUE][3].body)[1])
assert.equal(integrationProjection.passes[0].role, 'integrator')
assert.equal(integrationProjection.passes[0].payload.integration_round, 1)
assert.equal(read(runJson).evidence_comments.length, 4)
pass('an integration round publishes from its integrator-named pass, with the integration adjudication and no confidence-stage verdict required')

// ---------------------------------------------------------------------------
// 4. /retro discovers what post-round.sh published.
// ---------------------------------------------------------------------------
const runsDir = join(record, '..')
const retro = run('node', [join(skills, 'retro/assets/retro-run-report.mjs'), '--repo', 'example/repo', '--pr', String(PR),
  '--trusted-actor-id', String(ACTOR), '--record-dir', runsDir])
assert.equal(retro.status, 0, `${retro.stdout}\n${retro.stderr}`)
assert.match(retro.stdout, new RegExp(`^## Run evidence — run \`${RUN}\``, 'm'))
assert.match(retro.stdout, new RegExp(`evidence marker on issue #${ISSUE} \\(closing reference\\)`))
const section = (name) => retro.stdout.split(/^### /m).find((s) => s.startsWith(name)) ?? ''
assert.match(section('Stage `challenge`'), /Rounds spent: 1 \//)
assert.match(section('Stage `review`'), /Rounds spent: 2 \//)
assert.match(section('Stage `review`'), /2 pass\(es\)/)
pass('retro-run-report.mjs --pr discovers the published markers through the PR\'s closing issue and reports the measured stages (exit 0)')

sh('node', [join(support, 'validate-result-schemas.mjs'), 'run', runJson, '--receipts', runJson,
  ...readdirSync(join(record, 'adjudications')).flatMap((f) => ['--adjudication', join(record, 'adjudications', f)])])
pass('the run record with four registered evidence comments still validates strictly')
JS
