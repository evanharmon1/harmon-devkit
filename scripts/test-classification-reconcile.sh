#!/usr/bin/env bash
# test-classification-reconcile.sh — hermetic test of the classification
# reconciler (scripts/classification-reconcile.mjs) and of the event
# workflow's job-level filter. No network, no gh. Run via
# `task test:classification-reconcile`.
#
# What it holds:
#   - decide(): pinned, ambiguous pin, missing inputs, drift, no-op, invalid
#     input, both input shapes (organization field and personal-account label),
#     needs-triage on a pinned issue, and the writer allowlist.
#   - The pin race (#1450 C1-F3): a human pins with two UI edits, in either
#     order, and no event of either sequence starts a job.
#   - loadDerivation(): a missing reader, a reader without deriveTier, and a
#     reader that throws while resolving the policy all leave the Tier
#     underivable and never throw; this repository's own reader, when it has
#     deriveTier, derives through it.
#   - The event workflow's `if`, evaluated as GitHub would against fixture
#     events — including CLASSIFICATION_AGENT_LOGINS unset (an unset vars.*
#     reads as the empty string) — and its input lists held equal to the
#     script's and to label-registry.json's.
#   - The reconcile workflow: one checkout of its own repository, the token
#     always GITHUB_TOKEN, no input or secret for a call from another
#     repository. run() from a foreign checkout (RECONCILE_CALLER_CHECKOUT=
#     false) reads every listed repository's files through the contents API
#     and refuses an empty list. The organization workflow documented in
#     docs/architecture/ci-cd.md has the properties that document states.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

node --input-type=module - "$PWD" "$tmp" <<'EOF'
import assert from 'node:assert/strict'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'

const [root, tmp] = process.argv.slice(2)
const m = await import(pathToFileURL(join(root, 'scripts/classification-reconcile.mjs')).href)
const registry = JSON.parse(readFileSync(join(root, 'label-registry.json'), 'utf8'))
const vocabulary = m.activeVocabulary(registry)
const workTypes = vocabulary.workTypes

let passed = 0
function check(name, fn) {
  try {
    fn()
    passed += 1
  } catch (err) {
    console.error(`TEST FAIL: ${name}\n${err.stack}`)
    process.exitCode = 1
  }
}

// A stand-in for the reader's deriveTier: the tests below are about the
// reconciler's decisions, not the matrix cells (the reader owns those).
const derive = (risk, complexity) => {
  if (risk === 'bogus') throw new Error('risk must be one of [...], got "bogus"')
  return `${risk}-${complexity}` === 'high-m' ? 'frontier' : 'standard'
}
const ctx = { vocabulary, derive, underivable: null }
const triaged = ['feature', 'area:ci', 'layer:none', 'domain:none', 'impact:low']
const issue = (labels, extra = {}) => ({ labels, issueType: null, fields: {}, ...extra })

// --- decide() ---------------------------------------------------------------

check('drift: a stale Tier is replaced, exclusively', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:standard', 'needs-triage']), ctx)
  assert.deepEqual(d.add, ['tier:frontier'])
  assert.deepEqual(d.remove.sort(), ['needs-triage', 'tier:standard'])
})
check('drift: an absent Tier is written', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m']), ctx)
  assert.deepEqual(d.add, ['tier:frontier'])
  assert.deepEqual(d.remove, [])
})
check('no-op: labels already match, nothing written', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:frontier']), ctx)
  assert.deepEqual([d.add, d.remove, d.reports], [[], [], []])
})
check('pinned: no Tier write, needs-triage still maintained', () => {
  const d = m.decide(issue(['risk:high', 'complexity:m', 'tier:local', 'tier:pinned']), ctx)
  assert.deepEqual(d.add, ['needs-triage'])
  assert.deepEqual(d.remove, [])
  const t = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:local', 'tier:pinned', 'needs-triage']), ctx)
  assert.deepEqual([t.add, t.remove], [[], ['needs-triage']])
})
check('ambiguous pin: reported, both tier labels left', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:local', 'tier:apex', 'tier:pinned']), ctx)
  assert.deepEqual([d.add, d.remove], [[], []])
  assert.equal(d.reports[0].code, 'ambiguous-pin')
})
check('missing inputs: no Tier write; a stale unpinned Tier is left and reported', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'tier:apex']), ctx)
  assert.deepEqual(d.add, ['needs-triage'])
  assert.deepEqual(d.remove, [])
  assert.equal(d.reports[0].code, 'cache-unverifiable')
})
check('missing inputs without a Tier: only needs-triage', () => {
  const d = m.decide(issue(['bug']), ctx)
  assert.deepEqual([d.add, d.remove, d.reports], [['needs-triage'], [], []])
})
check('an off-scale input is reported, not guessed', () => {
  const d = m.decide(issue([...triaged, 'risk:bogus', 'complexity:m', 'tier:apex']), ctx)
  assert.deepEqual(d.remove, [])
  // Not applied, so not derived: reported, and the stale Tier left as it is.
  assert.deepEqual(d.reports.map((r) => r.code), ['unrecognized-value', 'cache-unverifiable'])
})
check('a conflicted axis: no value read, not triaged, needs-triage kept (C1-F3)', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'risk:low', 'complexity:m', 'needs-triage']), ctx)
  assert.deepEqual([d.add, d.remove, d.triaged], [[], [], false])
  assert.equal(d.reports[0].code, 'conflicted-axis')
})
check('an unknown value does not classify its axis (C1-F3)', () => {
  const d = m.decide(issue(['feature', 'area:ci', 'layer:none', 'domain:none', 'impact:bogus', 'risk:high', 'complexity:m', 'needs-triage']), ctx)
  assert.equal(d.triaged, false)
  assert.ok(!d.remove.includes('needs-triage'))
  assert.equal(d.reports[0].code, 'unrecognized-value')
})
check('the Tier is derived only from applied inputs: a retired Risk writes no Tier', () => {
  const synthetic = structuredClone(registry)
  const risk = synthetic.families.find((f) => f.family === 'risk').values.find((v) => v.value === 'high')
  risk.retired = true
  const v = m.activeVocabulary(synthetic)
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:standard']), { ...ctx, vocabulary: v })
  assert.deepEqual([d.add.filter((l) => l.startsWith('tier:')), d.remove], [[], []])
  assert.ok(d.reports.some((r) => r.code === 'unrecognized-value'))
})
check('a retired value does not classify its axis (C1-F3)', () => {
  const synthetic = structuredClone(registry)
  synthetic.families.find((f) => f.family === 'area').values.push({ value: 'old-area', retired: true })
  const v = m.activeVocabulary(synthetic)
  assert.ok(!v.recognized.area.includes('old-area'))
  const d = m.decide(issue(['feature', 'area:old-area', 'layer:none', 'domain:none', 'impact:low', 'risk:high', 'complexity:m', 'needs-triage']), { ...ctx, vocabulary: v })
  assert.equal(d.triaged, false)
  assert.ok(!d.remove.includes('needs-triage'))
  assert.match(d.reports[0].message, /retired or unknown/)
})
check('an absent registry: every axis unverifiable, needs-triage left as it is (C1-F3)', () => {
  const noReg = { ...ctx, vocabulary: null }
  const a = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'needs-triage']), noReg)
  assert.deepEqual([a.add.includes('needs-triage'), a.remove.includes('needs-triage'), a.triaged], [false, false, null])
  const b = m.decide(issue(['bug']), noReg)
  assert.deepEqual([b.add, b.remove], [[], []])
})
check('exactly one work-type label types an issue; two are a conflicted axis', () => {
  const rest = ['area:ci', 'layer:none', 'domain:none', 'impact:low', 'risk:high', 'complexity:m', 'needs-triage']
  assert.equal(m.decide(issue(['feature', ...rest]), ctx).triaged, true)
  const two = m.decide(issue(['feature', 'bug', ...rest]), ctx)
  assert.equal(two.triaged, false)
  assert.ok(!two.remove.includes('needs-triage'))
  assert.ok(two.reports.some((r) => r.code === 'conflicted-axis' && /work-type/.test(r.message)))
  // A native Issue Type types the issue whatever its labels say.
  assert.equal(m.decide(issue(['feature', 'bug', ...rest], { issueType: 'Task' }), ctx).triaged, true)
})
check('a tool-only work-type value is never a Type: dependencies alone is untyped, with task it is typed', () => {
  assert.ok(!workTypes.includes('dependencies'), 'dependencies has writers [tool:renovate]')
  const rest = ['area:ci', 'layer:none', 'domain:none', 'impact:low', 'risk:high', 'complexity:m', 'needs-triage']
  const alone = m.decide(issue(['dependencies', ...rest]), ctx)
  assert.equal(alone.triaged, false)
  const withTask = m.decide(issue(['task', 'dependencies', ...rest]), ctx)
  assert.equal(withTask.triaged, true)
  assert.ok(!withTask.reports.some((r) => r.code === 'conflicted-axis'))
})
check('a retired work type does not type an issue (C1-F4)', () => {
  assert.ok(!workTypes.includes('enhancement'), 'enhancement is retired in label-registry.json')
  const d = m.decide(issue(['enhancement', 'area:ci', 'layer:none', 'domain:none', 'impact:low', 'risk:high', 'complexity:m', 'needs-triage']), ctx)
  assert.equal(d.triaged, false)
  assert.ok(!d.remove.includes('needs-triage'))
})
check('a truncated read is skipped and reported (C1-F6)', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:local'], { truncated: 'labels' }), ctx)
  assert.deepEqual([d.add, d.remove, d.reports[0].code], [[], [], 'truncated'])
})
check('organization shape: fields and the native Type count; a field wins over a label', () => {
  const org = issue(['area:ci', 'layer:none', 'domain:none', 'risk:low'], {
    issueType: 'Task',
    fields: { Impact: 'low', Risk: 'high', Complexity: 'm' }
  })
  const d = m.decide(org, ctx)
  assert.deepEqual(d.add, ['tier:frontier'])
  assert.equal(d.triaged, true)
  assert.equal(d.reports[0].code, 'field-label-conflict')
})
check('a family `none` value satisfies triage; a missing family does not', () => {
  assert.equal(m.decide(issue([...triaged, 'risk:high', 'complexity:m']), ctx).triaged, true)
  assert.equal(m.decide(issue(['feature', 'area:ci', 'layer:none', 'impact:low', 'risk:high', 'complexity:m']), ctx).triaged, false)
})
check('underivable: needs-triage maintained, no Tier write, reason reported', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:local', 'needs-triage']), {
    ...ctx,
    derive: null,
    underivable: 'the reader has no deriveTier'
  })
  assert.deepEqual([d.add, d.remove], [[], ['needs-triage']])
  assert.match(d.reports[0].message, /tier not derivable: the reader has no deriveTier/)
})
check('tier:adaptive is reported and never written', () => {
  const d = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:adaptive']), ctx)
  assert.deepEqual(d.add, ['tier:frontier'])
  assert.ok(!d.remove.includes('tier:adaptive'))
  assert.equal(d.reports[0].code, 'tier-retired')
})
check('writer allowlist: only tier:<value> and needs-triage', () => {
  for (const ok of ['needs-triage', 'tier:local', 'tier:apex']) assert.equal(m.assertWritable(ok), ok)
  for (const bad of ['tier:pinned', 'tier:adaptive', 'priority:high', 'priority-ai:p1', 'rigor:deep', 'strategy:plan', 'claim:claude', 'tier:implementer:apex', 'risk:high']) {
    assert.throws(() => m.assertWritable(bad), /refusing to write/)
  }
})
check('parseRepositories: list, fallback, and refusal', () => {
  assert.deepEqual(m.parseRepositories('a/b, c/d\ne/f', 'x/y'), ['a/b', 'c/d', 'e/f'])
  assert.deepEqual(m.parseRepositories('', 'x/y'), ['x/y'])
  assert.throws(() => m.parseRepositories('a/b/c', null), /not an owner\/name/)
})

// --- The event workflow's job-level `if` -------------------------------------

// A small evaluator for the subset of GitHub expressions the filter uses:
// && || ! == != ( ) , string literals, context paths, and contains /
// startsWith / fromJSON. Semantics as GitHub documents them: && and || return
// an operand; null, false, 0 and '' are falsy; string comparison ignores case;
// a missing property is null; null coerces to '' in string functions.
function evaluate(expr, context) {
  return evaluateRaw(expr, context, true)
}
function evaluateValue(expr, context) {
  return evaluateRaw(expr, context, false)
}
function evaluateRaw(expr, context, asBool) {
  const tokens = expr.match(/'(?:[^']|'')*'|&&|\|\||==|!=|[!(),]|[A-Za-z_][\w.-]*/g)
  let i = 0
  const peek = () => tokens[i]
  const take = (t) => {
    if (t !== undefined && tokens[i] !== t) throw new Error(`expected ${t} at token ${i}, got ${tokens[i]}`)
    return tokens[i++]
  }
  const truthy = (v) => !(v === null || v === undefined || v === false || v === 0 || v === '')
  const str = (v) => (v === null || v === undefined ? '' : String(v)).toLowerCase()
  const fns = {
    contains: (hay, needle) =>
      Array.isArray(hay) ? hay.some((h) => str(h) === str(needle)) : str(hay).includes(str(needle)),
    startsWith: (s, p) => str(s).startsWith(str(p)),
    fromJSON: (s) => JSON.parse(s)
  }
  function primary() {
    const t = take()
    if (t === '(') {
      const v = or()
      take(')')
      return v
    }
    if (t === '!') return !truthy(primary())
    if (t.startsWith("'")) return t.slice(1, -1).replaceAll("''", "'")
    if (t === 'true' || t === 'false') return t === 'true'
    if (t === 'null') return null
    if (peek() === '(') {
      take('(')
      const args = [or()]
      while (peek() === ',') {
        take(',')
        args.push(or())
      }
      take(')')
      if (!fns[t]) throw new Error(`unsupported function ${t}`)
      return fns[t](...args)
    }
    return t.split('.').reduce((o, k) => (o === null || o === undefined ? null : (o[k] ?? null)), context)
  }
  function cmp() {
    let v = primary()
    while (peek() === '==' || peek() === '!=') {
      const op = take()
      const r = primary()
      const eq = typeof v === 'string' && typeof r === 'string' ? str(v) === str(r) : v === r
      v = op === '==' ? eq : !eq
    }
    return v
  }
  function and() {
    let v = cmp()
    while (peek() === '&&') {
      take('&&')
      const r = cmp()
      v = truthy(v) ? r : v
    }
    return v
  }
  function or() {
    let v = and()
    while (peek() === '||') {
      take('||')
      const r = and()
      v = truthy(v) ? v : r
    }
    return v
  }
  const v = or()
  if (i !== tokens.length) throw new Error(`trailing tokens from ${tokens[i]}`)
  return asBool ? truthy(v) : v
}

const wf = readFileSync(join(root, '.github/workflows/classification-event.yml'), 'utf8')
const ifMatch = wf.match(/^ {4}if: >-\n((?: {6}.*\n)+)/m)
assert.ok(ifMatch, 'classification-event.yml: no folded job-level `if: >-` block')
const gate = ifMatch[1].replace(/\s+/g, ' ').trim()
const runs = (event, vars = {}) => evaluate(gate, { github: { event }, vars })
const human = { type: 'User', login: 'a-human' }
const labelEvent = (action, name, sender = human) => ({ action, label: { name }, sender })

check('the filter: inputs start a job for a human', () => {
  for (const name of ['risk:high', 'complexity:m', 'impact:low', 'area:ci', 'layer:ui', 'domain:none', ...workTypes]) {
    assert.ok(runs(labelEvent('labeled', name)), `labeled ${name}`)
    assert.ok(runs(labelEvent('unlabeled', name)), `unlabeled ${name}`)
  }
  for (const action of ['opened', 'typed', 'untyped']) assert.ok(runs({ action, sender: human }), action)
})
check('the filter: tier:*, needs-triage and other labels never start a job', () => {
  for (const name of ['tier:standard', 'tier:pinned', 'tier:adaptive', 'tier:implementer:apex', 'needs-triage', 'priority:high', 'priority-ai:p1', 'claim:claude', 'rigor:deep', 'blocked']) {
    assert.ok(!runs(labelEvent('labeled', name)), `labeled ${name}`)
    assert.ok(!runs(labelEvent('unlabeled', name)), `unlabeled ${name}`)
  }
})
check('the filter: bots never start a job', () => {
  assert.ok(!runs(labelEvent('labeled', 'risk:high', { type: 'Bot', login: 'my-ci-app[bot]' })))
  assert.ok(!runs({ action: 'opened', sender: { type: 'Bot', login: 'claude[bot]' } }))
})
check('the filter: CLASSIFICATION_AGENT_LOGINS unset reads as an empty allowlist', () => {
  assert.ok(runs(labelEvent('labeled', 'risk:high'), {}))
  assert.ok(runs(labelEvent('labeled', 'risk:high'), { CLASSIFICATION_AGENT_LOGINS: '' }))
})
check('the filter: an allowlisted agent login never starts a job', () => {
  const vars = { CLASSIFICATION_AGENT_LOGINS: '["an-agent","another"]' }
  assert.ok(!runs(labelEvent('labeled', 'risk:high', { type: 'User', login: 'an-agent' }), vars))
  assert.ok(!runs({ action: 'opened', sender: { type: 'User', login: 'Another' } }, vars))
  assert.ok(runs(labelEvent('labeled', 'risk:high'), vars))
})
check('pin race, Tier first: set the Tier, then add tier:pinned — no job starts', () => {
  const seq = [labelEvent('unlabeled', 'tier:standard'), labelEvent('labeled', 'tier:frontier'), labelEvent('labeled', 'tier:pinned')]
  assert.deepEqual(seq.map((e) => runs(e)), [false, false, false])
  const final = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:frontier', 'tier:pinned']), ctx)
  assert.deepEqual([final.add, final.remove], [[], []])
})
check('pin race, pin first: add tier:pinned, then swap the Tier — no job starts', () => {
  const seq = [labelEvent('labeled', 'tier:pinned'), labelEvent('labeled', 'tier:apex'), labelEvent('unlabeled', 'tier:frontier')]
  assert.deepEqual(seq.map((e) => runs(e)), [false, false, false])
  // The gap holds two tier values beside the pin: a run there (the schedule)
  // reports it and leaves both, never picking one.
  const gap = m.decide(issue([...triaged, 'risk:high', 'complexity:m', 'tier:frontier', 'tier:apex', 'tier:pinned']), ctx)
  assert.deepEqual([gap.add, gap.remove, gap.reports[0].code], [[], [], 'ambiguous-pin'])
})
check('the filter and the script name the same inputs and event types', () => {
  const prefixes = [...gate.matchAll(/startsWith\(github\.event\.label\.name, '([^']+)'\)/g)].map((x) => x[1])
  assert.deepEqual(prefixes.sort(), [...m.INPUT_LABEL_PREFIXES].sort())
  const lists = [...gate.matchAll(/fromJSON\('(\[[^']*\])'\), github\.event\.label\.name\)/g)].map((x) => JSON.parse(x[1]))
  assert.equal(lists.length, 1, 'one work-type list')
  assert.deepEqual(lists[0].sort(), [...workTypes].sort(), 'the work-type list matches label-registry.json')
  const types = wf.match(/^ {4}types: \[([^\]]*)\]/m)[1].split(',').map((s) => s.trim())
  assert.deepEqual(types, [...m.EVENT_TYPES])
  for (const absent of ['edited', 'field_added', 'field_removed']) assert.ok(!types.includes(absent), absent)
})

// --- applyPlan(): every Tier write is guarded by a pin-free read (C1-F5, C2-F1),
// and the result is verified and repaired once (C1-F7, C3-F1) --------------------

// A stateful fake issue: writes really change its labels. `onRead[n]` edits
// the labels just before the n-th read (a human pinning, a concurrent run
// writing); `failWrites` lists `METHOD label` writes that error once each.
const TRUNCATED = Symbol('truncated')
function fakeClient(initial, { onRead = {}, failWrites = [] } = {}) {
  let labels = [...initial]
  let reads = 0
  const fails = [...failWrites]
  const calls = []
  const node = () => ({
    state: 'OPEN',
    number: 7,
    url: 'u',
    issueType: null,
    labels: {
      pageInfo: { hasNextPage: labels.at(-1) === TRUNCATED },
      nodes: labels.filter((l) => l !== TRUNCATED).map((name) => ({ name }))
    },
    issueFieldValues: { pageInfo: { hasNextPage: false }, nodes: [] }
  })
  return {
    calls,
    reads: () => reads,
    labels: () => labels.filter((l) => l !== TRUNCATED),
    async graphql() {
      reads += 1
      if (onRead[reads]) labels = onRead[reads](labels)
      return { repository: { issue: node() } }
    },
    async rest(method, path, payload) {
      const label = method === 'POST' ? payload.labels[0] : decodeURIComponent(path.split('/').at(-1))
      calls.push([method, label])
      const i = fails.indexOf(`${method} ${label}`)
      if (i >= 0) {
        fails.splice(i, 1)
        throw new Error(`${method} ${path}: 502 bad gateway`)
      }
      // GitHub matches label names case-insensitively; so does this fake.
      const same = (l) => typeof l === 'string' && l.toLowerCase() === label.toLowerCase()
      if (method === 'POST' && !labels.some(same)) labels = [...labels, label]
      if (method === 'DELETE') labels = labels.filter((l) => !same(l))
      return null
    }
  }
}
const tiers = (c) => c.labels().filter((l) => /^tier:/.test(l)).sort()
const codes = (plan) => plan.reports.map((r) => r.code)
const stale = [...triaged, 'risk:high', 'complexity:m', 'tier:standard']
const addPin = (labels) => [...labels, 'tier:pinned']
{
  const client = fakeClient(stale)
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: an unpinned drift adds the derived Tier, deletes the stale one, and verifies', () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier'], ['DELETE', 'tier:standard']])
    assert.deepEqual(tiers(client), ['tier:frontier'])
    assert.deepEqual(codes(plan), [])
  })
}
{
  const client = fakeClient(stale, { onRead: { 2: addPin } })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a pin landing after the add stops the stale-Tier delete', () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier']])
    assert.deepEqual([plan.add, plan.remove], [['tier:frontier'], []])
    assert.deepEqual(codes(plan), ['pin-appeared'])
    assert.ok(!plan.unrepaired, 'a pin stop is not a failure')
  })
}
{
  // The pin is already on the decision read: no Tier write at all, and
  // needs-triage is still maintained (it is never guarded).
  const client = fakeClient(['risk:high', 'complexity:m', 'tier:standard', 'tier:pinned'])
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a pin before the add means no Tier write; needs-triage still written', () => {
    assert.deepEqual(client.calls, [['POST', 'needs-triage']])
    assert.deepEqual([plan.add, plan.remove], [['needs-triage'], []])
  })
}
{
  // A delete-only plan (two stale tiers beside the derived one): the second
  // delete re-reads and sees the pin.
  const twoStale = [...triaged, 'risk:high', 'complexity:m', 'tier:frontier', 'tier:standard', 'tier:local']
  const client = fakeClient(twoStale, {
    onRead: { 2: (l) => addPin(l.filter((x) => x !== 'tier:standard')) }
  })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a delete-only plan stops at the first read that shows a pin', () => {
    assert.deepEqual(client.calls, [['DELETE', 'tier:standard']])
    assert.deepEqual([plan.add, plan.remove], [[], ['tier:standard']])
    assert.match(plan.reports.at(-1).message, /remove tier:local not applied/)
  })
}
{
  // A guard re-read that spans more than one page cannot prove "unpinned".
  const client = fakeClient(stale, { onRead: { 2: (l) => [...l, TRUNCATED] } })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a truncated guard read stops the remaining Tier writes (C3-F2)', () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier']])
    assert.deepEqual([plan.add, plan.remove], [['tier:frontier'], []])
    assert.deepEqual(codes(plan), ['pin-guard-indeterminate'])
    assert.equal(plan.unrepaired, true, 'a Tier left half-written and unverified fails the run')
  })
}
{
  const client = fakeClient(stale, { failWrites: ['DELETE tier:standard'] })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a failed delete is healed by the one repair pass (C1-F7)', () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier'], ['DELETE', 'tier:standard'], ['DELETE', 'tier:standard']])
    assert.deepEqual(tiers(client), ['tier:frontier'])
    assert.deepEqual(codes(plan), ['write-failed'])
  })
}
{
  // Reads: 1 decision, 2 guard before the delete, 3 verify — a concurrent run
  // has added another rung by then.
  const client = fakeClient(stale, { onRead: { 3: (l) => [...l, 'tier:apex'] } })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check("applyPlan: a concurrent run's extra rung is healed by the repair pass (C3-F1)", () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier'], ['DELETE', 'tier:standard'], ['DELETE', 'tier:apex']])
    assert.deepEqual(tiers(client), ['tier:frontier'])
    assert.deepEqual(codes(plan), [])
  })
}
{
  const client = fakeClient(stale, { failWrites: ['DELETE tier:standard', 'DELETE tier:standard'] })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a repair that also fails is reported as tier-not-exclusive, with no further pass', () => {
    assert.deepEqual(client.calls.filter(([meth]) => meth === 'DELETE').length, 2)
    assert.deepEqual(tiers(client), ['tier:frontier', 'tier:standard'])
    assert.deepEqual(codes(plan), ['write-failed', 'write-failed', 'tier-not-exclusive'])
    assert.equal(plan.unrepaired, true)
  })
}
{
  // GitHub returns the stored case: a pin stored as `Tier:Pinned` is still a
  // pin, and mixed-case inputs still classify (names are canonicalized once).
  const client = fakeClient(['Feature', 'Area:CI', 'layer:none', 'domain:none', 'impact:low', 'Risk:High', 'complexity:m', 'Tier:Standard', 'Tier:Pinned'])
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: label names are compared case-insensitively (a `Tier:Pinned` pin holds)', () => {
    assert.deepEqual(client.calls, [])
    assert.deepEqual([plan.add, plan.remove], [[], []])
  })
}
{
  const client = fakeClient(['Feature', 'Area:CI', 'layer:none', 'domain:none', 'impact:low', 'Risk:High', 'complexity:m', 'Tier:Standard', 'needs-triage'])
  await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: mixed-case inputs classify, and writes use canonical names', () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier'], ['DELETE', 'tier:standard'], ['DELETE', 'needs-triage']])
  })
}
{
  // Reads: 1 decision, 2 guard, 3 verify — the verify read is truncated, so
  // the invariant cannot be checked: reported, and the Tier left unverified.
  const client = fakeClient(stale, { onRead: { 3: (l) => [...l, TRUNCATED] } })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a truncated verify read leaves the Tier unverified, which fails the run', () => {
    assert.ok(codes(plan).includes('pin-guard-indeterminate'))
    assert.equal(plan.unrepaired, true)
  })
}
{
  // Impact is missing on the decision read, so needs-triage would be added;
  // a human completes the classification before the verify read (read 3).
  // needs-triage is decided from that latest read, so it is not added.
  const partial = ['feature', 'area:ci', 'layer:none', 'domain:none', 'risk:high', 'complexity:m', 'tier:standard']
  const client = fakeClient(partial, { onRead: { 3: (l) => [...l, 'impact:low'] } })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: needs-triage is decided from the latest read, not the first', () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier'], ['DELETE', 'tier:standard']])
    assert.deepEqual([plan.add, plan.remove], [['tier:frontier'], ['tier:standard']])
    assert.equal(client.reads(), 3)
  })
}
{
  const client = fakeClient(['bug'])
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: with no Tier write, needs-triage uses the decision read (no extra read)', () => {
    assert.deepEqual(client.calls, [['POST', 'needs-triage']])
    assert.equal(client.reads(), 1)
    assert.deepEqual(plan.add, ['needs-triage'])
  })
}
{
  // The delete fails; by the verify read (read 3) a human has pinned.
  const client = fakeClient(stale, { failWrites: ['DELETE tier:standard'], onRead: { 3: addPin } })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a pin seen on the verify read stops the repair and reports ambiguity', () => {
    assert.deepEqual(client.calls, [['POST', 'tier:frontier'], ['DELETE', 'tier:standard']])
    assert.deepEqual(codes(plan), ['write-failed', 'ambiguous-pin'])
    assert.match(plan.reports.at(-1).message, /tier:pinned with tier:standard, tier:frontier/)
  })
}
{
  const client = fakeClient(stale, {
    onRead: { 3: (labels) => addPin(labels.filter((l) => !l.startsWith('tier:'))) }
  })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a pin without a Tier on the verify read is reported', () => {
    assert.deepEqual(codes(plan), ['pin-without-tier'])
    assert.deepEqual(client.calls, [['POST', 'tier:frontier'], ['DELETE', 'tier:standard']])
  })
}

{
  const client = fakeClient([...stale, 'tier:adaptive'], { failWrites: ['DELETE tier:standard'] })
  const plan = await m.applyPlan(client, 'o', 'r', 7, ctx)
  check('applyPlan: a persistent condition is reported once across both verification passes', () => {
    assert.deepEqual(codes(plan), ['tier-retired', 'write-failed'])
    assert.equal(client.reads(), 4)
  })
}

// --- run(): the driver, against a stubbed fetch (R1-F1; integration 1–2) -------

// A stateful fake GitHub. Each repository holds issues (labels really change
// on POST/DELETE), the files its contents API serves (`null` → 404), an
// optional `down` (every call 502s), `failPaths` (REST paths that always 502)
// and `afterWrite(issue, method, label)` (a human or another run acting
// between our calls).
function fakeGitHub(repos) {
  const rest = []
  const queries = []
  // Every repository a call named, and every contents path read.
  const touched = new Set()
  const contents = []
  const json = (body, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
  const node = (number, issue) => ({
    state: 'OPEN',
    number,
    url: `https://github.test/issues/${number}`,
    issueType: issue.issueType ? { name: issue.issueType } : null,
    labels: { pageInfo: { hasNextPage: false }, nodes: issue.labels.map((name) => ({ name })) },
    issueFieldValues: {
      pageInfo: { hasNextPage: false },
      nodes: [
        ...Object.entries(issue.fields ?? {}).map(([field, value]) => ({ name: value, field: { name: field } })),
        { name: 'p1', field: { name: 'Priority (AI)' } },
        {}
      ]
    }
  })
  async function fetch(url, init = {}) {
    const { pathname } = new URL(url)
    if (pathname === '/graphql') {
      const { query, variables } = JSON.parse(init.body)
      queries.push({ query, variables })
      touched.add(`${variables.owner}/${variables.name}`)
      const repo = repos[`${variables.owner}/${variables.name}`]
      if (!repo || repo.down) return json({ message: 'bad gateway' }, 502)
      if (query.includes('issue(number:')) {
        const issue = repo.issues[variables.number]
        return json({ data: { repository: { issue: issue ? node(variables.number, issue) : null } } })
      }
      // One issue per page, so pagination is always exercised.
      const numbers = Object.keys(repo.issues).map(Number)
      const at = variables.after ? Number(variables.after) : 0
      return json({
        data: {
          repository: {
            issues: {
              pageInfo: { hasNextPage: at + 1 < numbers.length, endCursor: String(at + 1) },
              nodes: [node(numbers[at], repo.issues[numbers[at]])]
            }
          }
        }
      })
    }
    const [, , owner, name, kind, ...rest_] = pathname.split('/')
    touched.add(`${owner}/${name}`)
    const repo = repos[`${owner}/${name}`]
    if (!repo || repo.down) return json({ message: 'bad gateway' }, 502)
    if (kind === 'contents') {
      contents.push(pathname)
      const text = repo.files?.[rest_.join('/')] ?? null
      return text === null ? json({ message: 'Not Found' }, 404) : new Response(text, { status: 200 })
    }
    rest.push([init.method, pathname, init.body ? JSON.parse(init.body) : null])
    if ((repo.failPaths ?? []).includes(pathname)) return json({ message: 'bad gateway' }, 502)
    const issue = repo.issues[Number(rest_[0])]
    const label = init.method === 'POST' ? JSON.parse(init.body).labels[0] : decodeURIComponent(rest_.at(-1))
    if (init.method === 'POST' && !issue.labels.includes(label)) issue.labels.push(label)
    if (init.method === 'DELETE') issue.labels = issue.labels.filter((l) => l !== label)
    repo.afterWrite?.(issue, init.method, label)
    return init.method === 'DELETE' ? new Response(null, { status: 204 }) : json([])
  }
  return { fetch, rest, touched, contents, queries }
}
const ownText = (file) => readFileSync(join(root, file), 'utf8')
const canDerive = (await m.loadDerivation(root)).derive !== null
const classified = () => ({
  issueType: 'Task',
  labels: ['area:ci', 'layer:none', 'domain:none', 'needs-triage'],
  fields: { Impact: 'low', Risk: 'high', Complexity: 'm' }
})
async function runWith(repos, env) {
  const gh = fakeGitHub(repos)
  const summaryFile = join(tmp, `summary-${Object.keys(repos).join('-').replaceAll('/', '_')}-${Math.random()}.md`)
  const printed = []
  const code = await m.run(
    { GH_TOKEN: 't', GITHUB_REPOSITORY: 'a/two', GITHUB_STEP_SUMMARY: summaryFile, ...env },
    { fetch: gh.fetch, root, print: (l) => printed.push(l) }
  )
  return { code, gh, printed, summary: readFileSync(summaryFile, 'utf8') }
}
const writes = (gh, prefix) => gh.rest.filter(([, path]) => path.startsWith(prefix)).map(([meth, path, body]) => `${meth} ${body?.labels?.[0] ?? decodeURIComponent(path.split('/').at(-1))}`)
// Invalid selectors must fail before even the first fetch, regardless of dry-run.
for (const value of ['-1', '1.5', 'abc', '1junk', '1e3', ' 1', '1 ', '+1', '0x1', '2147483648', '9007199254740993']) {
  for (const dryRun of ['true', 'false']) {
    let calls = 0
    let refusal = null
    try {
      await m.run(
        { GH_TOKEN: 't', GITHUB_REPOSITORY: 'a/two', RECONCILE_ISSUE: value, RECONCILE_DRY_RUN: dryRun },
        { root, print: () => {}, fetch: async () => { calls += 1; throw new Error('unexpected fetch') } }
      )
    } catch (err) {
      refusal = err
    }
    check(`run(): issue ${value} is refused before any API call (dry-run ${dryRun})`, () => {
      assert.match(refusal?.message ?? '', /^RECONCILE_ISSUE must be an integer greater than or equal to zero/)
      assert.equal(calls, 0)
    })
  }
}
for (const [value, expected] of [['', 0], ['0', 0], ['2', 2], ['2147483647', 2147483647], ['007', 7]]) {
  const numbers = [1, 2, 7, 2147483647]
  const r = await runWith(
    { 'a/two': { issues: Object.fromEntries(numbers.map((n) => [n, { labels: ['bug'] }])) } },
    { RECONCILE_ISSUE: value, RECONCILE_DRY_RUN: 'true' }
  )
  check(`run(): issue selector ${JSON.stringify(value)} walks the expected issues`, () => {
    assert.equal(r.code, 0)
    for (const number of numbers) {
      assert.equal(r.summary.includes(`a/two#${number} |`), expected === 0 || expected === number)
    }
    if (expected > 0) assert.deepEqual(r.gh.queries.map((q) => q.variables.number), [expected])
    else assert.ok(r.gh.queries.every((q) => q.query.includes('issues(first:')))
    assert.deepEqual(r.gh.rest, [])
  })
}
for (const responseText of ['<html><body>Bad Gateway</body></html>', '<html>' + 'x'.repeat(3000) + '</html>']) {
  const printed = []
  const code = await m.run(
    { GH_TOKEN: 't', GITHUB_REPOSITORY: 'a/two', RECONCILE_DRY_RUN: 'true' },
    { root, print: (line) => printed.push(line), fetch: async () => new Response(responseText, { status: 502 }) }
  )
  check(`run(): an HTML 502 includes status and bounded response text (${responseText.length} characters)`, () => {
    assert.equal(code, 1)
    const error = printed.find((line) => line.startsWith('::error '))
    assert.ok(error.includes(`GraphQL 502: non-JSON response: ${responseText.slice(0, 2000)}`))
    assert.equal(error.includes('(truncated)'), responseText.length > 2000)
    assert.ok(error.length < 2200)
  })
}
for (const body of [null, [], {}, { data: null }, { data: [] }, { data: 1 }]) {
  const printed = []
  const responseText = JSON.stringify(body)
  const code = await m.run(
    { GH_TOKEN: 't', GITHUB_REPOSITORY: 'a/two' },
    { root, print: (line) => printed.push(line), fetch: async () => new Response(responseText, { status: 200 }) }
  )
  check(`run(): invalid GraphQL data envelope ${responseText} retains status and excerpt`, () => {
    assert.equal(code, 1)
    const error = printed.find((line) => line.startsWith('::error '))
    assert.ok(error.includes(`GraphQL 200: invalid response body: ${responseText.slice(0, 2000)}`))
    assert.ok(error.length < 2200)
  })
}
{
  const printed = []
  const code = await m.run(
    { GH_TOKEN: 't', GITHUB_REPOSITORY: 'a/two' },
    { root, print: (line) => printed.push(line), fetch: async () => new Response('null', { status: 502 }) }
  )
  check('run(): a JSON null GraphQL body retains status 502 and excerpt', () => {
    assert.equal(code, 1)
    assert.ok(printed.some((line) => line.startsWith('::error ') && line.includes('GraphQL 502:') && line.includes('null')))
  })
}
{
  const printed = []
  const responseText = '50% unavailable\r\n::warning::proxy detail'
  const gh = fakeGitHub({ 'a/two': { issues: { 1: { labels: [...stale] } } } })
  await m.run(
    { GH_TOKEN: 't', GITHUB_REPOSITORY: 'a/two' },
    {
      root,
      print: (line) => printed.push(line),
      fetch: async (url, init) => {
        if (init.method === 'POST' && new URL(url).pathname.endsWith('/labels'))
          return new Response(responseText, { status: 502 })
        return gh.fetch(url, init)
      }
    }
  )
  check('run(): failed Tier writes escape percent, CR and LF in report warnings', () => {
    const warnings = printed.filter((line) => line.startsWith('::warning ') && line.includes('write-failed'))
    assert.ok(warnings.length > 0, 'a failed Tier REST write produces a report')
    for (const warning of warnings) {
      assert.ok(warning.includes('502 50%25 unavailable%0D%0A::warning::proxy detail'))
      assert.ok(!/[\r\n]/.test(warning))
    }
  })
}
for (const kind of ['rest', 'raw']) {
  const printed = []
  const responseText = '50% unavailable\r\n' + 'x'.repeat(3000)
  const gh = fakeGitHub({ 'a/two': { issues: { 1: { labels: ['bug'] } } } })
  const code = await m.run(
    { GH_TOKEN: 't', GITHUB_REPOSITORY: 'a/two', RECONCILE_CALLER_CHECKOUT: kind === 'raw' ? 'false' : 'true', RECONCILE_REPOSITORIES: 'a/two' },
    {
      root,
      print: (line) => printed.push(line),
      fetch: async (url, init) => {
        if (new URL(url).pathname !== '/graphql') return new Response(responseText, { status: 502 })
        return gh.fetch(url, init)
      }
    }
  )
  check(`run(): long multiline ${kind} errors are bounded and escaped`, () => {
    assert.equal(code, 1)
    const error = printed.find((line) => line.startsWith('::error '))
    assert.ok(error.includes('502 50%25 unavailable%0D%0A'))
    assert.ok(error.includes('… (truncated)'))
    assert.ok(error.length < 2300)
    assert.ok(!/[\r\n]/.test(error))
  })
}
{
  const persisted = classified()
  persisted.labels.push('tier:adaptive')
  const r = await runWith({ 'a/two': { issues: { 1: persisted } } })
  check('run(): a persistent report occurs once in warnings and once in the summary', () => {
    assert.equal(r.code, 0)
    assert.equal(r.printed.filter((line) => line.startsWith('::warning ') && line.includes('tier-retired')).length, 1)
    assert.equal(r.summary.match(/tier-retired:/g)?.length, 1)
    assert.ok(r.gh.rest.length > 0, 'the report persists across a Tier write')
  })
}
for (const [status, body] of [
  [502, { message: 'x'.repeat(3000) }],
  [200, { errors: [{ message: 'x'.repeat(3000) }] }]
]) {
  const printed = []
  const code = await m.run(
    { GH_TOKEN: 't', GITHUB_REPOSITORY: 'a/two', RECONCILE_DRY_RUN: 'true' },
    { root, print: (line) => printed.push(line), fetch: async () => new Response(JSON.stringify(body), { status }) }
  )
  check(`run(): GraphQL ${status} JSON error diagnostics are bounded`, () => {
    assert.equal(code, 1)
    const error = printed.find((line) => line.startsWith('::error '))
    assert.ok(error.includes(`GraphQL ${status}: ${JSON.stringify(body.errors ?? body).slice(0, 2000)}… (truncated)`))
    assert.ok(error.length < 2200)
  })
}
{
  const printed = []
  const responseText = '<html>50% unavailable\r\n::error::proxy detail\n</html>'
  const code = await m.run(
    { GH_TOKEN: 't', GITHUB_REPOSITORY: 'a/two', RECONCILE_DRY_RUN: 'true' },
    { root, print: (line) => printed.push(line), fetch: async () => new Response(responseText, { status: 502 }) }
  )
  check('run(): a multiline response escapes percent, CR and LF in workflow error data', () => {
    assert.equal(code, 1)
    const error = printed.find((line) => line.startsWith('::error '))
    assert.ok(error.includes('<html>50%25 unavailable%0D%0A::error::proxy detail%0A</html>'))
    assert.ok(!/[\r\n]/.test(error))
  })
}
{
  const r = await runWith(
    { 'a/one': { down: true, issues: {} }, 'a/two': { issues: { 1: { labels: ['bug'] }, 2: classified() } } },
    { RECONCILE_REPOSITORIES: 'a/one a/two' }
  )
  check('run(): a failing repository does not stop the next one; the run exits 1', () => {
    assert.equal(r.code, 1)
    assert.match(r.summary, /^Failed: a\/one\.$/m)
    assert.match(r.summary, /\*\*a\/one failed:\*\* /)
    assert.ok(r.printed.some((l) => l.startsWith('::error title=classification reconcile a/one::')))
    assert.deepEqual(writes(r.gh, '/repos/a/one/'), [])
  })
  check('run(): failure and warning lines follow the summary table, never inside it', () => {
    const lines = r.summary.split('\n')
    const head = lines.indexOf('| Issue | Added | Removed | Reports |')
    const end = lines.indexOf('', head)
    assert.ok(lines.slice(head, end).every((l) => l.startsWith('|')), 'the table rows are contiguous')
    const note = lines.findIndex((l) => l.startsWith('> **a/one failed:**'))
    assert.ok(note > lines.findIndex((l) => l.startsWith('Changed ')), 'the failure note follows the totals')
  })
  check('run(): the issues connection is paginated and both pages are decided', () => {
    assert.match(r.summary, /of 2 open issue\(s\) in a\/one, a\/two\.$/m)
  })
  check('run(): issue-field values are normalized (Impact/Risk/Complexity read, others ignored)', () => {
    assert.ok(writes(r.gh, '/repos/a/two/issues/1/').includes('POST needs-triage'))
    assert.ok(writes(r.gh, '/repos/a/two/issues/2/').includes('DELETE needs-triage'))
  })
}
{
  const r = await runWith({ 'a/two': { issues: { 1: { labels: ['bug'] }, 2: classified() } } }, { RECONCILE_DRY_RUN: 'true' })
  check('run(): a dry run makes no REST call and reports what it would change', () => {
    assert.equal(r.code, 0)
    assert.deepEqual(r.gh.rest, [])
    assert.match(r.summary, /^Dry run: would change 2 of 2 open issue\(s\) in a\/two\.$/m)
  })
}
{
  const r = await runWith({
    'a/two': { issues: { 1: { labels: ['bug'] }, 2: classified() }, failPaths: ['/repos/a/two/issues/1/labels'] }
  })
  check("run(): one issue's failure does not stop the next issue; the run exits 1", () => {
    assert.equal(r.code, 1)
    assert.match(r.summary, /\*\*a\/two#1 failed:\*\* POST \/repos\/a\/two\/issues\/1\/labels: 502/)
    assert.match(r.summary, /^Failed: a\/two\.$/m)
    assert.ok(r.printed.some((l) => l.startsWith('::error title=classification reconcile a/two#1::')))
    assert.ok(writes(r.gh, '/repos/a/two/issues/2/').includes('DELETE needs-triage'))
  })
}
if (canDerive) {
  const stuck = { ...classified(), labels: ['area:ci', 'layer:none', 'domain:none', 'tier:standard'] }
  const r = await runWith({
    'a/two': {
      issues: { 1: stuck, 2: { labels: ['bug'] } },
      failPaths: ['/repos/a/two/issues/1/labels/tier%3Astandard']
    }
  })
  check('run(): a Tier still not exclusive after the repair fails the run, and the walk completes', () => {
    assert.equal(r.code, 1)
    assert.match(r.summary, /tier-not-exclusive/)
    assert.match(r.summary, /^Failed: a\/two\.$/m)
    assert.ok(writes(r.gh, '/repos/a/two/issues/2/').includes('POST needs-triage'))
  })
  const pinned = { ...classified(), labels: ['area:ci', 'layer:none', 'domain:none', 'tier:standard'] }
  const p = await runWith({
    'a/two': {
      issues: { 1: pinned },
      // A human pins right after our add, before the stale-Tier delete.
      afterWrite: (issue, meth, label) => meth === 'POST' && label.startsWith('tier:') && issue.labels.push('tier:pinned')
    }
  })
  check('run(): a pin that stops the Tier writes is reported, not a failure', () => {
    assert.equal(p.code, 0)
    assert.match(p.summary, /pin-appeared/)
    assert.doesNotMatch(p.summary, /^Failed:/m)
  })
}
{
  // b/three's own registry knows area:zzz and its own matrix maps m × high to
  // apex; the caller (a/two) knows neither. c/four has no registry; d/five
  // has no policy.
  const foreignRegistry = structuredClone(registry)
  foreignRegistry.families.find((f) => f.family === 'area').values = [{ value: 'zzz' }]
  const ownPolicy = ownText('.devflow.toml')
  const foreignPolicy = ownPolicy.replace(/^(m\s*=\s*\{.*high = )"[a-z]+"/m, '$1"apex"')
  assert.notEqual(foreignPolicy, ownPolicy, 'the foreign matrix differs')
  const zzz = () => ({ labels: ['feature', 'area:zzz', 'layer:none', 'domain:none', 'impact:low', 'risk:high', 'complexity:m', 'needs-triage'] })
  const r = await runWith(
    {
      'a/two': { issues: { 1: zzz() } },
      'b/three': { issues: { 1: zzz() }, files: { 'label-registry.json': JSON.stringify(foreignRegistry), '.devflow.toml': foreignPolicy } },
      'c/four': { issues: { 1: { labels: ['bug'] } }, files: { 'label-registry.json': null, '.devflow.toml': ownPolicy } },
      'd/five': {
        issues: { 1: { ...classified(), labels: ['area:ci', 'layer:none', 'domain:none', 'needs-triage', 'tier:local'] } },
        files: { 'label-registry.json': JSON.stringify(registry), '.devflow.toml': null }
      }
    },
    { RECONCILE_REPOSITORIES: 'a/two b/three c/four d/five' }
  )
  check("run(): another repository is judged by its own registry and its own matrix", () => {
    assert.equal(r.code, 0)
    assert.ok(!writes(r.gh, '/repos/a/two/').includes('DELETE needs-triage'), 'area:zzz is unknown to the caller')
    assert.ok(writes(r.gh, '/repos/b/three/').includes('DELETE needs-triage'), 'area:zzz is known to b/three')
    if (canDerive) {
      assert.ok(writes(r.gh, '/repos/a/two/').includes('POST tier:frontier'))
      assert.ok(writes(r.gh, '/repos/b/three/').includes('POST tier:apex'))
    }
  })
  check('run(): per-repository warnings follow the summary table, never inside it', () => {
    const lines = r.summary.split('\n')
    const head = lines.indexOf('| Issue | Added | Removed | Reports |')
    const end = lines.indexOf('', head)
    assert.ok(lines.slice(head, end).every((l) => l.startsWith('|')), 'the table rows are contiguous')
    assert.ok(lines.slice(end).some((l) => l.startsWith('> **c/four:**')), 'the warning follows the table')
  })
  check('run(): a repository without a registry gets no needs-triage write, reported once', () => {
    assert.deepEqual(writes(r.gh, '/repos/c/four/').filter((w) => w.endsWith('needs-triage')), [])
    assert.equal(r.summary.match(/c\/four:\*\* label-registry\.json is unreadable/g)?.length, 1)
  })
  check('run(): a repository without a policy gets no Tier write, reported once', () => {
    assert.deepEqual(writes(r.gh, '/repos/d/five/').filter((w) => /tier:/.test(w)), [])
    // Without a deriving reader (a generated repo before harmon-devkit#1248),
    // the reader is the reason reported; with one, the missing policy is.
    const reason = canDerive ? 'no \\.devflow\\.toml' : '(no policy reader found|has no deriveTier)'
    assert.equal(r.summary.match(new RegExp(`d/five:\\*\\* tier not derivable: ${reason}`, 'g'))?.length, 1)
    assert.ok(writes(r.gh, '/repos/d/five/').includes('DELETE needs-triage'))
  })
  check("run(): an own-copy run judges the caller by its checkout and never reads the caller's contents", () => {
    assert.deepEqual(r.gh.contents.filter((p) => p.startsWith('/repos/a/two/')), [])
  })
  // A foreign checkout (the organization workflow in ci-cd.md): the checkout
  // is not the repository the run is in, so RECONCILE_CALLER_CHECKOUT=false.
  // That repository, when listed, is judged by the files on its own default
  // branch; any other listed repository is read as before.
  const foreignFiles = { 'label-registry.json': JSON.stringify(foreignRegistry), '.devflow.toml': foreignPolicy }
  const foreign = await runWith(
    {
      'a/two': { issues: { 1: zzz() }, files: foreignFiles },
      'b/three': { issues: { 1: zzz() }, files: foreignFiles }
    },
    { RECONCILE_REPOSITORIES: 'a/two b/three', RECONCILE_CALLER_CHECKOUT: 'false' }
  )
  check('run(): from a foreign checkout, the running repository is judged by its own files, read through the contents API', () => {
    assert.equal(foreign.code, 0)
    assert.deepEqual(
      foreign.gh.contents.filter((p) => p.startsWith('/repos/a/two/')).sort(),
      ['/repos/a/two/contents/.devflow.toml', '/repos/a/two/contents/label-registry.json']
    )
    assert.ok(writes(foreign.gh, '/repos/a/two/').includes('DELETE needs-triage'), "area:zzz is known to a/two's own registry")
    for (const repo of ['a/two', 'b/three']) {
      assert.deepEqual(writes(foreign.gh, `/repos/${repo}/`), writes(r.gh, '/repos/b/three/'), `${repo} is judged as b/three was`)
    }
  })
  const unlisted = await runWith(
    { 'b/three': { issues: { 1: zzz() }, files: foreignFiles } },
    { RECONCILE_REPOSITORIES: 'b/three', RECONCILE_CALLER_CHECKOUT: 'false' }
  )
  check('run(): from a foreign checkout, the running repository is never walked or read unless listed', () => {
    assert.equal(unlisted.code, 0)
    assert.deepEqual([...unlisted.gh.touched], ['b/three'])
  })
  // An empty list from a foreign checkout fails fast rather than walking the
  // running repository; an own-copy run keeps defaulting to itself.
  const empty = fakeGitHub({ 'a/two': { issues: { 1: zzz() }, files: foreignFiles } })
  let refusal = null
  try {
    await m.run(
      { GH_TOKEN: 't', GITHUB_REPOSITORY: 'a/two', RECONCILE_REPOSITORIES: '', RECONCILE_CALLER_CHECKOUT: 'false' },
      { fetch: empty.fetch, root, print: () => {} }
    )
  } catch (err) {
    refusal = err
  }
  check('run(): a foreign checkout with no repositories list is refused before any call', () => {
    assert.match(refusal?.message ?? '', /^RECONCILE_CALLER_CHECKOUT=false needs RECONCILE_REPOSITORIES: /)
    assert.deepEqual([...empty.touched], [])
  })
  // The switch is the safety for that case: a value it does not know is
  // refused, never read as the own-checkout default.
  for (const value of ['False', '0', 'no']) {
    const gh = fakeGitHub({ 'a/two': { issues: { 1: zzz() }, files: foreignFiles } })
    let err = null
    try {
      await m.run(
        { GH_TOKEN: 't', GITHUB_REPOSITORY: 'a/two', RECONCILE_REPOSITORIES: 'a/two', RECONCILE_CALLER_CHECKOUT: value },
        { fetch: gh.fetch, root, print: () => {} }
      )
    } catch (e) {
      err = e
    }
    check(`run(): RECONCILE_CALLER_CHECKOUT=${value} is refused before any call`, () => {
      assert.equal(err?.message, `RECONCILE_CALLER_CHECKOUT must be unset, "true" or "false", not ${JSON.stringify(value)}`)
      assert.deepEqual([...gh.touched], [])
    })
  }
  const ownDefault = await runWith({ 'a/two': { issues: { 1: zzz() } } }, { RECONCILE_REPOSITORIES: '' })
  check('run(): an own-copy run with no repositories list still walks the caller', () => {
    assert.equal(ownDefault.code, 0)
    assert.deepEqual([...ownDefault.gh.touched], ['a/two'])
    assert.deepEqual(ownDefault.gh.contents, [])
  })
  const ownExplicit = await runWith(
    { 'a/two': { issues: { 1: zzz() } } },
    { RECONCILE_REPOSITORIES: '', RECONCILE_CALLER_CHECKOUT: 'true' }
  )
  check('run(): RECONCILE_CALLER_CHECKOUT=true behaves as the unset default', () => {
    assert.equal(ownExplicit.code, 0)
    assert.deepEqual([...ownExplicit.gh.touched], ['a/two'])
    assert.deepEqual(ownExplicit.gh.contents, [])
    assert.deepEqual(writes(ownExplicit.gh, '/repos/a/two/'), writes(ownDefault.gh, '/repos/a/two/'))
  })
}

// --- The reconcile workflow: its own repository, its own token (C1-F1) -------

const rwf = readFileSync(join(root, '.github/workflows/classification-reconcile.yml'), 'utf8')
const pinOf = (text, action) =>
  text.match(new RegExp(`uses: ${action}@([0-9a-f]{40}) # v\\d+\\.\\d+\\.\\d+$`, 'm'))?.[1]
check('the workflow: the token is always GITHUB_TOKEN, and no input or secret could carry another', () => {
  const tokenExpr = rwf.match(/^ {10}GH_TOKEN: \$\{\{ (.*) \}\}$/m)?.[1]
  assert.equal(tokenExpr, 'github.token')
  const ctx = { secrets: { CLASSIFICATION_TOKEN: 'stored' }, github: { token: 'GITHUB_TOKEN' } }
  assert.equal(evaluateValue(tokenExpr, ctx), 'GITHUB_TOKEN', 'whatever secrets exist')
  assert.doesNotMatch(rwf, /\bsecrets[.:]|use-token|CLASSIFICATION_TOKEN/)
  // workflow_call is for this repository's own classification-event.yml.
  const call = rwf.slice(rwf.indexOf('  workflow_call:'), rwf.indexOf('\npermissions:'))
  assert.deepEqual([...call.matchAll(/^ {6}([\w-]+):$/gm)].map((x) => x[1]), ['issue', 'dry-run'])
})
check('the workflow: one checkout, of the repository it runs in, persisting no credentials', () => {
  assert.equal(rwf.match(/^ {6}- uses: actions\/checkout@/gm)?.length, 1)
  assert.ok(pinOf(rwf, 'actions/checkout'), 'pinned by SHA with the version')
  assert.doesNotMatch(rwf, /^ +(?:repository|ref|token):/m)
  assert.match(rwf, /^ {10}persist-credentials: false$/m)
})

// --- The organization workflow documented in ci-cd.md (#1500) ---------------

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
const doc = readFileSync(join(root, 'docs/architecture/ci-cd.md'), 'utf8')
const orgWorkflow =
  doc.slice(doc.indexOf('**Organization-wide walk.**')).match(/^```yaml\n([\s\S]*?)^```$/m)?.[1] ?? ''
const orgSteps = orgWorkflow.slice(orgWorkflow.indexOf('\n    steps:\n')).split(/\n {6}- /).slice(1)
const [mint, source, setupNode, reconcile] = orgSteps
check('the organization workflow: a schedule only, contents: read, one job, no reusable-workflow call', () => {
  assert.ok(orgWorkflow, 'ci-cd.md carries the organization workflow example')
  assert.match(orgWorkflow, /^on:\n {2}schedule:\n {4}- cron: "[^"]+"\n\n/m)
  // A dispatch would run the selected ref's definition, token-minting step
  // included, so an App-token workflow never offers one.
  assert.doesNotMatch(orgWorkflow, /workflow_dispatch/)
  assert.match(orgWorkflow, /^permissions:\n {2}contents: read\n\n/m)
  assert.equal(orgWorkflow.match(/^ {2}[\w-]+:\n {4}runs-on:/gm)?.length, 1, 'one job')
  assert.doesNotMatch(orgWorkflow, /workflow_call|^ {4}uses:|\.ya?ml@/m)
  assert.deepEqual(
    orgSteps.map((s) => s.match(/uses: ([\w-]+\/[\w-]+)@/)?.[1] ?? 'run'),
    ['actions/create-github-app-token', 'actions/checkout', 'actions/setup-node', 'run']
  )
})
check('the organization workflow: the token is minted in the job that uses it, and used only for the walk', () => {
  assert.match(mint, /^id: app-token\n/)
  for (const line of [
    'client-id: ${{ vars.CI_APP_CLIENT_ID }}',
    'private-key: ${{ secrets.CI_APP_PRIVATE_KEY }}',
    'owner: ${{ github.repository_owner }}',
    'repositories: |',
    'permission-contents: read',
    'permission-issues: write'
  ]) {
    assert.match(mint, new RegExp(`^ {10}${esc(line)}$`, 'm'), line)
  }
  // The token reaches exactly the repositories the walk lists: bare names
  // under `owner`, the same ones RECONCILE_REPOSITORIES names as owner/name.
  const block = (text, key) => text.match(new RegExp(`^ {10}${key}: [|>]-?\\n((?: {12}\\S+\\n?)+)`, 'm'))?.[1].split(/\s+/).filter(Boolean)
  const scoped = block(mint, 'repositories')
  assert.ok(scoped?.length > 0 && scoped.every((n) => !n.includes('/')), 'bare repository names')
  assert.deepEqual(block(reconcile, 'RECONCILE_REPOSITORIES')?.map((r) => r.split('/')[1]), scoped)
  // The App key is the only secret and only the mint step reads it; the
  // token reaches only the reconcile step.
  assert.deepEqual(orgSteps.filter((s) => /secrets\./.test(s)), [mint])
  assert.deepEqual(orgSteps.filter((s) => s.includes('steps.app-token.outputs.token')), [reconcile])
  assert.match(reconcile, /^ {10}GH_TOKEN: \$\{\{ steps\.app-token\.outputs\.token \}\}$/m)
  // Pinned by full SHA with the version. Not held equal to the live
  // workflows' pins: Renovate does not update Markdown, and the copy in
  // <org>/.github is maintained by that repository's own Renovate.
  assert.ok(pinOf(mint, 'actions/create-github-app-token'), 'pinned by SHA with the version')
})
check('the organization workflow: the script source is checked out at a full commit SHA, with no secret and no persisted credentials', () => {
  assert.ok(pinOf(source, 'actions/checkout'), 'pinned by SHA with the version')
  assert.match(source, /^ {10}repository: <[\w-]+>\/<[\w-]+>$/m, 'a placeholder, never a fixed owner repository')
  assert.match(source, /^ {10}ref: <full-commit-sha> # <release-tag>$/m)
  assert.match(source, /^ {10}persist-credentials: false$/m)
  assert.doesNotMatch(source, /^ {10}token:|secrets\.|steps\./m)
  assert.ok(pinOf(setupNode, 'actions/setup-node'), 'pinned by SHA with the version')
})
check('the organization workflow: the script runs from the foreign checkout over an explicit repository list', () => {
  assert.match(reconcile, /^ {8}run: node scripts\/classification-reconcile\.mjs$/m)
  assert.match(reconcile, /^ {10}RECONCILE_CALLER_CHECKOUT: "false"$/m)
  assert.match(reconcile, /^ {10}RECONCILE_REPOSITORIES: >-\n {12}\S+/m)
})

// --- loadDerivation() --------------------------------------------------------

function fakeRepo(name, readerSource, { policy = true } = {}) {
  const dir = join(tmp, name)
  mkdirSync(join(dir, 'scripts/lib'), { recursive: true })
  if (readerSource !== null) writeFileSync(join(dir, 'scripts/devflow-policy.mjs'), readerSource)
  writeFileSync(join(dir, 'scripts/lib/toml-lite.mjs'), 'export function parseToml() { return { tier: {} } }\n')
  if (policy) writeFileSync(join(dir, '.devflow.toml'), '[tier.matrix]\n')
  return dir
}
{
  const message = '50% unavailable\r\n::warning::reader detail'
  const dir = fakeRepo('multiline-reader', `export function deriveTier() {}\nexport function resolvePolicy() { throw new Error(${JSON.stringify(message)}) }\n`)
  const printed = []
  const gh = fakeGitHub({ 'a/two': { issues: { 1: { labels: ['bug'] } } } })
  const code = await m.run(
    { GH_TOKEN: 't', GITHUB_REPOSITORY: 'a/two' },
    { root: dir, print: (line) => printed.push(line), fetch: gh.fetch }
  )
  check('run(): repository warnings escape a multiline policy-reader message', () => {
    assert.equal(code, 0)
    const warning = printed.find((line) => line.startsWith('::warning title=classification reconcile a/two::') && line.includes('tier not derivable'))
    assert.ok(warning.includes('50%25 unavailable%0D%0A::warning::reader detail'))
    assert.ok(!/[\r\n]/.test(warning))
  })
}
const cases = [
  ['no reader', fakeRepo('none', null), /no policy reader found/],
  [
    'no policy file',
    fakeRepo('nopolicy', 'export function deriveTier() {}\nexport function resolvePolicy() { return {} }\n', { policy: false }),
    /no \.devflow\.toml/
  ],
  ['a reader without deriveTier', fakeRepo('old', 'export function resolvePolicy() { return {} }\n'), /has no deriveTier/],
  [
    'a reader that throws on the policy',
    fakeRepo('throws', 'export function deriveTier() {}\nexport function resolvePolicy() { throw new Error("[tier] is not a known table") }\n'),
    /could not resolve the policy: \[tier\] is not a known table/
  ],
  ['a reader whose policy has no matrix', fakeRepo('nomatrix', 'export function deriveTier() {}\nexport function resolvePolicy() { return {} }\n'), /no \[tier\.matrix\]/]
]
for (const [name, dir, reason] of cases) {
  const d = await m.loadDerivation(dir)
  check(`loadDerivation: ${name} leaves the Tier underivable`, () => {
    assert.equal(d.derive, null)
    assert.match(d.underivable, reason)
  })
}
const own = await m.loadDerivation(root)
const reader = own.reader ? await import(pathToFileURL(own.reader).href) : {}
if (typeof reader.deriveTier === 'function') {
  check("loadDerivation: this repository's reader derives through deriveTier", () => {
    assert.equal(own.underivable, null)
    assert.ok(m.TIER_VALUES.includes(own.derive('high', 'm')))
    assert.throws(() => own.derive('bogus', 'm'))
  })
} else {
  check('loadDerivation: a reader without deriveTier is reported, not fatal', () => {
    assert.equal(own.derive, null)
    assert.ok(own.underivable)
  })
}

if (process.exitCode) process.exit(process.exitCode)
console.log(`classification-reconcile tests OK: ${passed} checks`)
EOF
