#!/usr/bin/env node
// scripts/classification-reconcile.mjs — materialize the derived Tier and
// `needs-triage` on open issues (ADR 2026-09-30 D4 "Reconcile drift" and D6,
// as amended by ADR 2026-10-01: the Tier is a `tier:<value>` label on every
// owner type).
//
// Run by .github/workflows/classification-reconcile.yml, on its schedule, on
// workflow_dispatch, and per issue from classification-event.yml; an
// organization-wide walk runs it from the standalone organization workflow in
// docs/architecture/ci-cd.md, from a foreign checkout. Agent
// writers (triage, track-work, breakdown) set the Tier and `needs-triage` in
// the same write that sets Risk or Complexity; this script repairs what they
// did not cover: a human editing an input in the GitHub UI, or drift from any
// other source.
//
// Inputs are read in both storage shapes. Impact, Risk and Complexity are
// organization issue fields on organization repositories and
// `impact:*`/`risk:*`/`complexity:*` labels on personal-account ones; a field
// wins over a label of the same axis, and a disagreement is reported.
//
// "Triaged" (D6) needs a Type (native, or exactly one non-retired work-type
// label) and exactly one recognized, non-retired value of each of impact,
// risk, complexity, area, layer and domain. A repository is judged by its own
// label-registry.json and .devflow.toml: the calling repository's from the
// checkout when it runs its own copy, any other's (every one, from a foreign
// checkout) from its default branch. A conflicted axis, a retired
// value, or an unknown one does not classify its axis. With the registry
// unreadable every axis is unverifiable, and `needs-triage` is left as it is.
//
// The derivation is the policy reader's `deriveTier` over the governing
// `.devflow.toml`'s [tier.matrix]. This script never re-implements the
// matrix: a reader that is missing, lacks `deriveTier`, or throws while
// resolving the policy (an older vendored reader meeting a [tier] table it
// does not know) leaves the Tier unwritten, `needs-triage` still maintained,
// and the reason reported. The job never fails on an old reader.
//
// Writers: ONLY `tier:<value>` (one of the five rungs) and `needs-triage`
// (assertWritable). Never over an issue carrying `tier:pinned`; an ambiguous
// pin (two or more tier values beside `tier:pinned`) is reported and left for
// a human. Never `tier:pinned`, `tier:adaptive`, `priority:*`,
// `priority-ai:*`, `rigor:*`, `strategy:*` or `claim:*`.
//
// Environment:
//   GH_TOKEN                   token for the GitHub API (required, a dry run
//                              included: it still reads)
//   RECONCILE_REPOSITORIES     newline/comma/space list of owner/name
//                              (default: GITHUB_REPOSITORY)
//   RECONCILE_ISSUE            one issue number (single-repository mode); 0 or
//                              empty walks every open issue
//   RECONCILE_DRY_RUN          "true" to report the plan and write nothing
//   RECONCILE_CALLER_CHECKOUT  unset, empty or "true": the checkout is
//                              GITHUB_REPOSITORY's own. "false": the checkout
//                              is not the repository this runs in (a foreign
//                              checkout, such as the organization workflow in
//                              ci-cd.md): every walked repository's files are
//                              then read through the contents API, and
//                              RECONCILE_REPOSITORIES is required. Any other
//                              value is refused before any API call
//   GITHUB_API_URL, GITHUB_GRAPHQL_URL, GITHUB_STEP_SUMMARY (Actions-provided)

import { existsSync, readFileSync, appendFileSync } from 'node:fs'
import { resolve as resolvePath } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

// The Tier ladder is vocabulary, not policy: specs/dev-flow-v2.md pins
// tier_order as local → economy → standard → frontier → apex. Only the
// [tier.matrix] cells are per-repository, and those come from the reader.
export const TIER_VALUES = Object.freeze(['local', 'economy', 'standard', 'frontier', 'apex'])
export const PIN_LABEL = 'tier:pinned'
export const RETIRED_TIER_LABEL = 'tier:adaptive'
export const NEEDS_TRIAGE = 'needs-triage'

// The three classification axes with an issue field on organization
// repositories (setup-github-issue-fields.sh) and a label family everywhere.
export const FIELD_AXES = Object.freeze([
  { axis: 'impact', field: 'Impact', prefix: 'impact:' },
  { axis: 'risk', field: 'Risk', prefix: 'risk:' },
  { axis: 'complexity', field: 'Complexity', prefix: 'complexity:' }
])
// Label-only required families (D6): one each, or that family's `none`.
export const LABEL_FAMILY_PREFIXES = Object.freeze(['area:', 'layer:', 'domain:'])
// Every family "triaged" requires (D6). Each is exclusive in the registry, so
// an axis counts only with exactly one recognized, non-retired value.
export const REQUIRED_FAMILIES = Object.freeze([
  ...FIELD_AXES.map((a) => a.axis),
  ...LABEL_FAMILY_PREFIXES.map((p) => p.slice(0, -1))
])

// The label prefixes that are INPUTS to the Tier or to "triaged". The event
// workflow's job-level `if` lists exactly these (plus the work-type labels);
// test-classification-reconcile.sh holds the two together. `tier:*` and
// `needs-triage` are deliberately absent: a Tier or pin edit never starts a
// job, so the two-step UI pin cannot be overwritten mid-pin (#1450 C1-F3).
export const INPUT_LABEL_PREFIXES = Object.freeze([
  ...FIELD_AXES.map((a) => a.prefix),
  ...LABEL_FAMILY_PREFIXES
])

// The event types the event workflow starts on. `edited` is deliberately
// absent (a title or body edit is never an input), and so are
// `field_added`/`field_removed` until actionlint knows them (#1485): an
// organization-repository field edit is repaired by the schedule.
export const EVENT_TYPES = Object.freeze(['opened', 'labeled', 'unlabeled', 'typed', 'untyped'])

/**
 * The active vocabulary of a parsed label-registry.json: the non-retired work
 * types and the recognized, non-retired values of every required family.
 * Throws when the registry lacks one of them.
 */
export function activeVocabulary(registry) {
  const families = registry?.families
  if (!Array.isArray(families)) throw new Error('label-registry.json has no families array')
  const values = (name) => {
    const family = families.find((f) => f.family === name)
    if (!family || !Array.isArray(family.values)) {
      throw new Error(`label-registry.json has no ${name} family values`)
    }
    return family.values.filter((v) => !v.retired).map((v) => ({ v, family }))
  }
  const active = (name) => values(name).map(({ v }) => v.value.toLowerCase())
  const recognized = {}
  for (const name of REQUIRED_FAMILIES) recognized[name] = active(name)
  // The Type-bearing subset of the work-type family: a value whose effective
  // writers (its own, else the family's) include a human or agent writer is a
  // Type; one written only by a tool (`dependencies`, `tool:renovate`) is a
  // facet the tool manages, never the issue's Type.
  const workTypes = values('work-type')
    .filter(({ v, family }) =>
      (v.writers ?? family.writers ?? []).some((w) => !w.startsWith('tool:'))
    )
    .map(({ v }) => v.value.toLowerCase())
  return { workTypes, recognized }
}

/** The only labels this script may ever add or remove. */
export function assertWritable(label) {
  const ok = label === NEEDS_TRIAGE || TIER_VALUES.some((t) => label === `tier:${t}`)
  if (!ok)
    throw new Error(
      `refusing to write ${JSON.stringify(label)}: only tier:<value> and ${NEEDS_TRIAGE} are writable`
    )
  return label
}

// One required family's state. `value` is the single value read (a field wins
// over a same-axis label), or null when absent or conflicted; `applied` is true
// only when that value is in the active taxonomy. `recognized` null means the
// registry is unreadable, so nothing can be applied.
function axisState(issue, family, recognized, reports) {
  const prefix = `${family}:`
  const spec = FIELD_AXES.find((a) => a.axis === family)
  const fieldValue = spec ? ((issue.fields ?? {})[spec.field] ?? null) : null
  const labelValues = issue.labels
    .filter((l) => l.startsWith(prefix))
    .map((l) => l.slice(prefix.length))
  let value
  if (fieldValue !== null) {
    if (labelValues.some((v) => v !== fieldValue)) {
      reports.push({
        code: 'field-label-conflict',
        message: `${spec.field} field is ${fieldValue} but labels say ${labelValues.join(', ')}; the field wins`
      })
    }
    value = fieldValue
  } else if (labelValues.length === 0) {
    return { value: null, applied: false }
  } else if (labelValues.length > 1) {
    reports.push({
      code: 'conflicted-axis',
      message: `${labelValues.length} ${family} labels (${labelValues.join(', ')}); ${family} is not classified`
    })
    return { value: null, applied: false }
  } else {
    value = labelValues[0]
  }
  if (recognized === null) return { value, applied: false }
  if (!recognized[family].includes(value)) {
    reports.push({
      code: 'unrecognized-value',
      message: `${family} ${JSON.stringify(value)} is not in the active taxonomy (retired or unknown); ${family} is not classified`
    })
    return { value, applied: false }
  }
  return { value, applied: true }
}

/**
 * The decision function. Pure: no I/O.
 *
 * issue:  { labels: string[], issueType: string|null, fields: { Impact?, Risk?, Complexity? },
 *           truncated?: string|null }
 * ctx:    { vocabulary: activeVocabulary(...) | null (registry unreadable),
 *           derive: ((risk, complexity) => tier) | null, underivable: string|null }
 *
 * Returns { add: string[], remove: string[], reports: {code, message}[], tier, triaged }.
 */
export function decide(issue, ctx) {
  const labels = issue.labels
  const reports = []
  const add = []
  const remove = []
  if (issue.truncated) {
    // A partial read could hide tier:pinned or an input: decide nothing.
    reports.push({
      code: 'truncated',
      message: `the issue's ${issue.truncated} exceed one page; skipped rather than decided on a partial read`
    })
    return { add, remove, reports, tier: null, triaged: null }
  }
  const vocabulary = ctx.vocabulary
  const states = {}
  for (const family of REQUIRED_FAMILIES) {
    states[family] = axisState(issue, family, vocabulary?.recognized ?? null, reports)
  }
  // The Tier is derived only from applied inputs: exactly one recognized,
  // non-retired value each (an unrecognized one is reported by axisState).
  const applied = (f) => (states[f].applied ? states[f].value : null)
  const values = { risk: applied('risk'), complexity: applied('complexity') }

  // needs-triage is derived (D6), pinned or not. With the registry unreadable
  // every axis is unverifiable, so needs-triage is left as it is.
  let triaged = null
  if (vocabulary) {
    // Typed: a native Issue Type, or exactly one recognized work-type label;
    // two or more is a conflicted axis, like any other.
    const workTypes = labels.filter((l) => vocabulary.workTypes.includes(l))
    if (!issue.issueType && workTypes.length > 1) {
      reports.push({
        code: 'conflicted-axis',
        message: `${workTypes.length} work-type labels (${workTypes.join(', ')}); the issue is not typed`
      })
    }
    const hasType = Boolean(issue.issueType) || workTypes.length === 1
    triaged = hasType && REQUIRED_FAMILIES.every((f) => states[f].applied)
    if (triaged && labels.includes(NEEDS_TRIAGE)) remove.push(NEEDS_TRIAGE)
    if (!triaged && !labels.includes(NEEDS_TRIAGE)) add.push(NEEDS_TRIAGE)
  }

  const tierLabels = labels.filter((l) => TIER_VALUES.some((t) => l === `tier:${t}`))
  if (labels.includes(RETIRED_TIER_LABEL)) {
    reports.push({
      code: 'tier-retired',
      message: `${RETIRED_TIER_LABEL} is retired and left for its migration (#1447)`
    })
  }

  let tier = null
  if (labels.includes(PIN_LABEL)) {
    // Nothing automated writes over a pinned Tier (D5).
    if (tierLabels.length > 1) {
      reports.push({
        code: 'ambiguous-pin',
        message: `${PIN_LABEL} with ${tierLabels.join(', ')}: left for a human, never resolved by picking one`
      })
    } else if (tierLabels.length === 0) {
      reports.push({
        code: 'pin-without-tier',
        message: `${PIN_LABEL} without a tier value: left for a human`
      })
    }
  } else if (values.risk === null || values.complexity === null) {
    if (tierLabels.length > 0) {
      reports.push({
        code: 'cache-unverifiable',
        message: `${tierLabels.join(', ')} without both Risk and Complexity: left in place, never used as an input`
      })
    }
  } else if (ctx.derive === null) {
    reports.push({ code: 'tier-not-derivable', message: `tier not derivable: ${ctx.underivable}` })
  } else {
    try {
      tier = ctx.derive(values.risk, values.complexity)
    } catch (err) {
      reports.push({ code: 'invalid-input', message: `tier not derived: ${err.message}` })
    }
    if (tier !== null) {
      const want = `tier:${tier}`
      if (!tierLabels.includes(want)) add.push(want)
      for (const l of tierLabels) if (l !== want) remove.push(l)
    }
  }
  for (const l of [...add, ...remove]) assertWritable(l)
  return { add, remove, reports, tier, triaged }
}

// ---------------------------------------------------------------------------
// The policy reader, located at runtime
// ---------------------------------------------------------------------------

// First match wins: harmon-init's own reader, then the vendored dev-flow-support
// copy in either skills destination, then harmon-devkit's native source copy.
export const READER_CANDIDATES = Object.freeze([
  'scripts/devflow-policy.mjs',
  '.agents/skills/dev-flow-support/assets/devflow-policy.mjs',
  '.claude/skills/dev-flow-support/assets/devflow-policy.mjs',
  'ai/skills/universal/dev-flow-support/assets/devflow-policy.mjs'
])

/**
 * Locate and load the policy reader in the checkout at `root`. The reader is
 * the caller's code whichever repository's policy it then judges. Never
 * throws: returns { reader, parseToml, path } or { underivable, path }.
 */
export async function loadReader(root, candidates = READER_CANDIDATES) {
  const path = candidates.map((c) => resolvePath(root, c)).find((p) => existsSync(p))
  if (!path) return { underivable: 'no policy reader found', path: null }
  try {
    const reader = await import(pathToFileURL(path).href)
    if (typeof reader.deriveTier !== 'function' || typeof reader.resolvePolicy !== 'function') {
      return { underivable: `the reader at ${path} has no deriveTier`, path }
    }
    // The parser ships beside every reader candidate, so it is imported
    // relative to the reader, not to this script.
    const { parseToml } = await import(new URL('./lib/toml-lite.mjs', pathToFileURL(path)).href)
    return { reader, parseToml, path }
  } catch (err) {
    return { underivable: `the reader at ${path} could not be loaded: ${err.message}`, path }
  }
}

/**
 * Derive with a loaded reader over one repository's policy text (null when
 * that repository has none). Never throws: returns { derive, underivable }.
 */
export function derivationFrom(bundle, policyText) {
  if (bundle.underivable) return { derive: null, underivable: bundle.underivable }
  if (policyText === null) return { derive: null, underivable: 'no .devflow.toml' }
  try {
    const resolved = bundle.reader.resolvePolicy(bundle.parseToml(policyText))
    const matrix = resolved?.tier_matrix ?? null
    if (matrix === null) return { derive: null, underivable: 'the policy has no [tier.matrix]' }
    return {
      derive: (risk, complexity) => bundle.reader.deriveTier(matrix, { risk, complexity }),
      underivable: null
    }
  } catch (err) {
    return {
      derive: null,
      underivable: `the reader at ${bundle.path} could not resolve the policy: ${err.message}`
    }
  }
}

/**
 * Load `deriveTier` and the [tier.matrix] of the checkout at `root`.
 * Never throws: returns { derive, underivable, reader }.
 */
export async function loadDerivation(root, candidates = READER_CANDIDATES) {
  const bundle = await loadReader(root, candidates)
  const policyPath = resolvePath(root, '.devflow.toml')
  const policyText = existsSync(policyPath) ? readFileSync(policyPath, 'utf8') : null
  return { ...derivationFrom(bundle, policyText), reader: bundle.path }
}

// ---------------------------------------------------------------------------
// GitHub I/O
// ---------------------------------------------------------------------------

const ISSUE_FIELDS = `
  number
  url
  issueType { name }
  labels(first: 100) { pageInfo { hasNextPage } nodes { name } }
  issueFieldValues(first: 50) {
    pageInfo { hasNextPage }
    nodes {
      ... on IssueFieldSingleSelectValue { name field { ... on IssueFieldSingleSelect { name } } }
    }
  }`

function normalizeIssue(node) {
  const fields = {}
  for (const v of node.issueFieldValues?.nodes ?? []) {
    const spec = FIELD_AXES.find((a) => a.field.toLowerCase() === v?.field?.name?.toLowerCase())
    if (spec && typeof v.name === 'string') fields[spec.field] = v.name.toLowerCase()
  }
  return {
    number: node.number,
    url: node.url,
    issueType: node.issueType?.name ?? null,
    // GitHub label names are case-insensitive and the API returns the stored
    // case, so every name is canonicalized (lower-cased) here, once, where an
    // issue is read: decide(), the pin guard and the verify pass compare
    // canonical names, and every write uses one.
    labels: (node.labels?.nodes ?? []).map((l) => l.name.toLowerCase()),
    fields,
    // decide() skips an issue whose labels or field values span more than one
    // page: a partial read could hide tier:pinned or an input.
    truncated:
      [
        node.labels?.pageInfo?.hasNextPage ? 'labels' : null,
        node.issueFieldValues?.pageInfo?.hasNextPage ? 'issue field values' : null
      ]
        .filter(Boolean)
        .join(' and ') || null
  }
}

function makeClient(token, fetch, env) {
  const api = env.GITHUB_API_URL || 'https://api.github.com'
  const graphqlUrl = env.GITHUB_GRAPHQL_URL || `${api}/graphql`
  const headers = {
    authorization: `Bearer ${token}`,
    accept: 'application/vnd.github+json',
    'x-github-api-version': '2022-11-28',
    // Issue fields are behind a GraphQL feature flag.
    'graphql-features': 'issue_fields',
    'user-agent': 'classification-reconcile'
  }
  const diagnostic = (text) => (text.length > 2000 ? `${text.slice(0, 2000)}… (truncated)` : text)
  async function graphql(query, variables) {
    const res = await fetch(graphqlUrl, {
      method: 'POST',
      headers,
      body: JSON.stringify({ query, variables })
    })
    const text = await res.text()
    let body
    try {
      body = JSON.parse(text)
    } catch {
      throw new Error(`GraphQL ${res.status}: non-JSON response: ${diagnostic(text)}`)
    }
    if (!res.ok || body?.errors)
      throw new Error(`GraphQL ${res.status}: ${diagnostic(JSON.stringify(body?.errors ?? body))}`)
    const data = body?.data
    if (data === null || typeof data !== 'object' || Array.isArray(data))
      throw new Error(`GraphQL ${res.status}: invalid response body: ${diagnostic(text)}`)
    return data
  }
  async function rest(method, path, payload) {
    const res = await fetch(`${api}${path}`, {
      method,
      headers,
      body: payload === undefined ? undefined : JSON.stringify(payload)
    })
    if (method === 'DELETE' && res.status === 404) return null // already gone
    if (!res.ok) throw new Error(`${method} ${path}: ${res.status} ${diagnostic(await res.text())}`)
    return res.status === 204 ? null : res.json()
  }
  // A file's raw text from a repository's default branch; null when absent.
  async function raw(path) {
    const res = await fetch(`${api}${path}`, {
      headers: { ...headers, accept: 'application/vnd.github.raw' }
    })
    if (res.status === 404) return null
    if (!res.ok) throw new Error(`GET ${path}: ${res.status} ${diagnostic(await res.text())}`)
    return res.text()
  }
  return { graphql, rest, raw }
}

async function* openIssues(client, owner, name) {
  let after = null
  for (;;) {
    const data = await client.graphql(
      `query($owner: String!, $name: String!, $after: String) {
        repository(owner: $owner, name: $name) {
          issues(first: 50, after: $after, states: OPEN) {
            pageInfo { hasNextPage endCursor }
            nodes { ${ISSUE_FIELDS} }
          }
        }
      }`,
      { owner, name, after }
    )
    const conn = data.repository.issues
    for (const node of conn.nodes) yield normalizeIssue(node)
    if (!conn.pageInfo.hasNextPage) return
    after = conn.pageInfo.endCursor
  }
}

async function fetchIssue(client, owner, name, number) {
  const data = await client.graphql(
    `query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) { issue(number: $number) { state ${ISSUE_FIELDS} } }
    }`,
    { owner, name, number }
  )
  const node = data.repository.issue
  return node && node.state === 'OPEN' ? normalizeIssue(node) : null
}

export function parseRepositories(raw, fallback) {
  const list = String(raw ?? '')
    .split(/[\s,]+/)
    .map((s) => s.trim())
    .filter(Boolean)
  const repos = list.length > 0 ? list : fallback ? [fallback] : []
  for (const r of repos) {
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(r))
      throw new Error(`not an owner/name repository: ${JSON.stringify(r)}`)
  }
  return repos
}

// Apply one issue's plan, re-read first (a human may have pinned or
// re-classified since the walk read the issue).
//
// Invariant: every Tier mutation is preceded by a read, made after the
// previous mutation, that shows no tier:pinned. On a pin, every remaining
// Tier write stops and the issue is reported. GitHub's label API has no
// compare-and-swap, so one round trip between that read and its write is the
// irreducible residual. `needs-triage` is maintained on pinned issues too, so
// its writes are unguarded and run after the Tier writes.
//
// Verify and repair (C1-F7, C3-F1): after the Tier writes, the issue is
// re-read once. Unpinned, it must carry exactly one rung, the Tier derived
// from the inputs on that read; a failed delete or a concurrent run's write
// breaks that. One bounded repair pass runs under the same guard, then a
// last re-read; if the invariant still fails the issue is reported
// (`tier-not-exclusive`) and the walk moves on.
export async function applyPlan(client, owner, name, number, ctx) {
  // Every write, Tier or needs-triage, is decided from the most recent read:
  // `last` is that read, and `stale` says a write has happened since it.
  let last = null
  let stale = false
  const read = async () => {
    last = await fetchIssue(client, owner, name, number)
    stale = false
    return last
  }
  const fresh = await read()
  if (!fresh) return { add: [], remove: [], reports: [] }
  const plan = decide(fresh, ctx)
  const path = `/repos/${owner}/${name}/issues/${number}/labels`
  const write = async (method, label) => {
    stale = true
    return method === 'POST'
      ? client.rest('POST', path, { labels: [assertWritable(label)] })
      : client.rest('DELETE', `${path}/${encodeURIComponent(assertWritable(label))}`)
  }
  const isTier = (l) => l !== NEEDS_TRIAGE
  const tierOps = (p) => [
    ...p.add.filter(isTier).map((l) => ['POST', l]),
    ...p.remove.filter(isTier).map((l) => ['DELETE', l])
  ]
  const applied = { add: [], remove: [] }
  const record = (method, label) => (method === 'POST' ? applied.add : applied.remove).push(label)
  const report = (code, message) => plan.reports.push({ code, message })
  const describe = (ops) =>
    ops.map(([m, l]) => `${m === 'POST' ? 'add' : 'remove'} ${l}`).join(', ')

  // Returns 'done', 'stopped' (a pin, or a guard read that cannot rule one
  // out), 'failed' (a write errored), or 'closed'.
  async function guardedTierWrites(ops, firstRead) {
    let guard = firstRead
    for (const [i, [method, label]] of ops.entries()) {
      if (i > 0) guard = await read()
      if (!guard) return 'closed'
      if (guard.truncated) {
        // A partial read can rule out neither a pin nor a second rung, so the
        // Tier is left unverified, and that fails the run.
        report(
          'pin-guard-indeterminate',
          `the guard read's ${guard.truncated} exceed one page; ${describe(ops.slice(i))} not applied`
        )
        plan.unrepaired = true
        return 'stopped'
      }
      if (guard.labels.includes(PIN_LABEL)) {
        report(
          'pin-appeared',
          `${PIN_LABEL} appeared during the write; ${describe(ops.slice(i))} not applied, left for a human`
        )
        return 'stopped'
      }
      try {
        await write(method, label)
      } catch (err) {
        report('write-failed', `${describe([[method, label]])} failed: ${err.message}`)
        return 'failed'
      }
      record(method, label)
    }
    return 'done'
  }

  const tierWrites = tierOps(plan)
  let outcome = await guardedTierWrites(tierWrites, fresh)
  if (outcome === 'closed') return { ...plan, ...applied }
  if (tierWrites.length > 0 && outcome !== 'stopped') {
    for (let pass = 0; pass < 2; pass++) {
      const check = await read()
      if (!check) return { ...plan, ...applied }
      if (check.truncated) {
        report(
          'pin-guard-indeterminate',
          `the verify read's ${check.truncated} exceed one page; the Tier could not be verified`
        )
        plan.unrepaired = true
        break
      }
      // decide() plans no Tier write for a pinned or truncated read, so a pin
      // seen here ends the pass like a holding invariant does.
      const verification = decide(check, ctx)
      for (const r of verification.reports) {
        if (!plan.reports.some((p) => p.code === r.code && p.message === r.message))
          plan.reports.push(r)
      }
      const fix = tierOps(verification)
      if (fix.length === 0) break
      if (pass === 1) {
        report(
          'tier-not-exclusive',
          `the Tier is still not exclusive after one repair pass (${describe(fix)} outstanding)`
        )
        plan.unrepaired = true
        break
      }
      outcome = await guardedTierWrites(fix, check)
      if (outcome === 'closed') return { ...plan, ...applied }
      if (outcome === 'stopped') break
    }
  }
  // needs-triage is decided from the most recent read, re-reading once only
  // when a Tier write has happened since it.
  if (stale && !(await read())) return { ...plan, ...applied }
  const triage = decide(last, ctx)
  for (const label of triage.add.filter((l) => !isTier(l))) {
    await write('POST', label)
    record('POST', label)
  }
  for (const label of triage.remove.filter((l) => !isTier(l))) {
    await write('DELETE', label)
    record('DELETE', label)
  }
  return { ...plan, ...applied }
}

/**
 * Run the reconciler as the workflow does, from an environment (see the
 * header). Returns the exit code: 1 when any repository failed, else 0.
 * `fetch`, `root` and `print` are injectable so the driver can be tested.
 */
export async function run(
  env,
  { fetch = globalThis.fetch, root = process.cwd(), print = console.log } = {}
) {
  const dryRun = env.RECONCILE_DRY_RUN === 'true'
  const issueValue = env.RECONCILE_ISSUE || '0'
  const issueNumber = Number(issueValue)
  if (!/^\d+$/.test(issueValue) || !Number.isSafeInteger(issueNumber) || issueNumber > 2147483647)
    throw new Error(
      `RECONCILE_ISSUE must be an integer greater than or equal to zero and at most 2147483647, not ${JSON.stringify(issueValue)}`
    )
  // A foreign checkout holds no file of the repository this runs in, so that
  // repository is walked only when it is on the list, which such a run must
  // therefore pass. The switch is the safety for that case, so a value it
  // does not know is refused rather than read as the default.
  const callerCheckoutValue = env.RECONCILE_CALLER_CHECKOUT ?? ''
  if (!['', 'true', 'false'].includes(callerCheckoutValue))
    throw new Error(
      `RECONCILE_CALLER_CHECKOUT must be unset, "true" or "false", not ${JSON.stringify(callerCheckoutValue)}`
    )
  const callerCheckout = callerCheckoutValue !== 'false'
  const repos = parseRepositories(
    env.RECONCILE_REPOSITORIES,
    callerCheckout ? env.GITHUB_REPOSITORY : null
  )
  if (repos.length === 0 && !callerCheckout)
    throw new Error(
      'RECONCILE_CALLER_CHECKOUT=false needs RECONCILE_REPOSITORIES: a run from a foreign checkout walks only the repositories it lists'
    )
  if (repos.length === 0)
    throw new Error('no repository: set RECONCILE_REPOSITORIES or GITHUB_REPOSITORY')
  if (issueNumber > 0 && repos.length !== 1)
    throw new Error('RECONCILE_ISSUE needs exactly one repository')
  const token = env.GH_TOKEN
  if (!token) throw new Error('GH_TOKEN is not set')

  const commandData = (text) =>
    text.replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A')
  const summary = []
  const log = (line) => {
    print(line)
    summary.push(line)
  }
  // Repository warnings and failures are collected apart from the table and
  // appended after it, so a blockquote never splits the Markdown table.
  const notes = []
  const warnRepo = (repo, message) => {
    print(`::warning title=classification reconcile ${repo}::${commandData(message)}`)
    notes.push(`> **${repo}:** ${message}`, '')
  }

  const client = makeClient(token, fetch, env)
  const bundle = await loadReader(root)
  // The repository whose files the checkout holds: the one this runs in, or
  // none at all from a foreign checkout.
  const caller = callerCheckout ? String(env.GITHUB_REPOSITORY ?? '').toLowerCase() : null
  const localText = (file) => {
    const p = resolvePath(root, file)
    return existsSync(p) ? readFileSync(p, 'utf8') : null
  }
  // A repository is only ever judged by its own registry and its own policy:
  // the calling repository by its checkout when it runs its own copy, any
  // other by the files on its default branch (the token then needs
  // `contents: read` there). The reader is the checkout's code either way.
  async function contextFor(repo) {
    const local = repo.toLowerCase() === caller
    const fetchText = (file) =>
      local ? localText(file) : client.raw(`/repos/${repo}/contents/${file}`)
    const [registryText, policyText] = await Promise.all([
      fetchText('label-registry.json'),
      fetchText('.devflow.toml')
    ])
    let vocabulary = null
    try {
      if (registryText === null) throw new Error('not found')
      vocabulary = activeVocabulary(JSON.parse(registryText))
    } catch (err) {
      warnRepo(
        repo,
        `label-registry.json is unreadable (${err.message}); every axis is unverifiable and ${NEEDS_TRIAGE} is left as it is`
      )
    }
    const derivation = derivationFrom(bundle, policyText)
    if (derivation.derive === null) {
      warnRepo(repo, `tier not derivable: ${derivation.underivable}; no Tier is written`)
    }
    return { vocabulary, derive: derivation.derive, underivable: derivation.underivable }
  }
  log(`| Issue | Added | Removed | Reports |`)
  log(`|---|---|---|---|`)

  let changed = 0
  let seen = 0
  const failed = []
  // One repository's failure (renamed, inaccessible, rate-limited) never
  // stops the rest of the list; the run fails after the whole list.
  for (const repo of repos) {
    const [owner, name] = repo.split('/')
    try {
      const ctx = await contextFor(repo)
      const issues =
        issueNumber > 0
          ? [await fetchIssue(client, owner, name, issueNumber)].filter(Boolean)
          : openIssues(client, owner, name)
      for await (const issue of issues) {
        seen += 1
        let plan
        // One issue's failure (an API error mid-write) never stops the rest
        // of the repository's walk; the repository still counts as failed.
        try {
          plan = decide(issue, ctx)
          if (!dryRun && (plan.add.length > 0 || plan.remove.length > 0)) {
            plan = await applyPlan(client, owner, name, issue.number, ctx)
          }
        } catch (err) {
          if (!failed.includes(repo)) failed.push(repo)
          print(
            `::error title=classification reconcile ${repo}#${issue.number}::${commandData(err.message)}`
          )
          notes.push(`> **${repo}#${issue.number} failed:** ${err.message}`, '')
          continue
        }
        // An issue whose Tier the bounded repair could not make exclusive
        // fails its repository; the walk goes on.
        if (plan.unrepaired) {
          if (!failed.includes(repo)) failed.push(repo)
          print(
            `::error title=classification reconcile ${repo}#${issue.number}::the Tier could not be made, or verified, exclusive`
          )
        }
        // The not-derivable reason is reported once per repository.
        const reports = plan.reports.filter((r) => r.code !== 'tier-not-derivable')
        for (const r of reports) {
          print(`::warning title=${repo}#${issue.number} ${r.code}::${commandData(r.message)}`)
        }
        if (plan.add.length > 0 || plan.remove.length > 0 || reports.length > 0) {
          if (plan.add.length > 0 || plan.remove.length > 0) changed += 1
          const cell = (xs) => xs.map((x) => `\`${x}\``).join(' ') || '—'
          log(
            `| ${repo}#${issue.number} | ${cell(plan.add)} | ${cell(plan.remove)} | ${reports.map((r) => `${r.code}: ${r.message}`).join('<br>') || '—'} |`
          )
        }
      }
    } catch (err) {
      if (!failed.includes(repo)) failed.push(repo)
      print(`::error title=classification reconcile ${repo}::${commandData(err.message)}`)
      notes.push(`> **${repo} failed:** ${err.message}`, '')
    }
  }
  log('')
  log(
    `${dryRun ? 'Dry run: would change' : 'Changed'} ${changed} of ${seen} open issue(s) in ${repos.join(', ')}.`
  )
  if (failed.length > 0) log(`Failed: ${failed.join(', ')}.`)
  if (notes.length > 0) summary.push('', ...notes)
  if (env.GITHUB_STEP_SUMMARY) {
    appendFileSync(
      env.GITHUB_STEP_SUMMARY,
      `## Classification reconcile\n\n${summary.join('\n')}\n`
    )
  }
  return failed.length > 0 ? 1 : 0
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === resolvePath(process.argv[1])
if (isMain) {
  run(process.env).then(
    (code) => {
      process.exitCode = code
    },
    (err) => {
      console.error(`classification-reconcile: ${err.message}`)
      process.exitCode = 1
    }
  )
}
