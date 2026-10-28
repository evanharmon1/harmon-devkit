// Live, read-only authentication for a newly admitted integrator receipt.
// This intentionally lives below both the result validator and run-record
// writer: schema validation is the admission boundary, while later readers
// validate retained immutable bytes without re-querying an overwritten cycle.
import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { validateResolvedPolicy } from '../devflow-policy.mjs'
import { authorityForEnvelope, conservativeLegacyControls } from './integrator-review-authority.mjs'

const ASSET_DIR = dirname(fileURLToPath(import.meta.url))
const CHECKER = join(ASSET_DIR, '../../../integrate/assets/check-codex-cloud-review.sh')
const TRUSTED_REGISTRY = join(ASSET_DIR, '../../../integrate/assets/trusted-registry.sh')

// Fixed defaults of check-codex-cloud-review.sh before finder profiles were
// persisted in state. A finder-null legacy cycle is admissible only when the
// current trusted codex-cloud profile is exactly this classifier; otherwise a
// newer registry could silently change what the legacy checker accepted.
const LEGACY_CODEX_PROFILE = {
  slug: 'codex-cloud',
  actor_id: '199175422',
  actor_login: 'chatgpt-codex-connector[bot]',
  trigger_mechanism: 'review-comment',
  trigger_body: '@codex review',
  reviewer_login: null,
  surfaces: ['reaction', 'comment', 'review', 'inline'],
  head_binding: 'reviewed-commit-line',
  verdict_mode: 'clean-sentence',
  clean_verdict: "codex review: didn't find any major issues.",
  actionable_pattern: null,
  severity_marker: '\\bp[0-9]+\\b',
  metadata_line: '^\\*\\*reviewed commit:\\*\\*[[:space:]]*`[0-9a-f]{7,40}`[[:space:]]*$',
  about_summary: 'about codex',
  heading: '^#{1,6}[^a-z0-9]*codex review$',
  carrier_sentence: 'here are some automated review suggestions for this pull request.',
  success_reaction: '+1',
  pending_reaction: 'eyes'
}

function stable(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value)
  if (Array.isArray(value)) return `[${value.map(stable).join(',')}]`
  return `{${Object.keys(value).filter((key) => value[key] !== undefined).sort().map((key) => `${JSON.stringify(key)}:${stable(value[key])}`).join(',')}}`
}

function id(value) { return value === undefined || value === null ? null : String(value) }

function checkerResult(stateFile, repoDir, runId) {
  try {
    return { exit: 0, output: JSON.parse(execFileSync('bash', [CHECKER, 'check', '--state', stateFile,
      '--actor-id', '199175422', '--run-id', runId, '--repo-dir', repoDir, '--read-only'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()) }
  } catch (error) {
    // Terminal findings deliberately exit non-zero. Its JSON is still the
    // fresh, authoritative observation and can support a truthful receipt.
    const output = `${error.stdout ?? ''}`.trim()
    try { return { exit: error.status, output: JSON.parse(output) } } catch { throw new Error((error.stderr || output || error.message).trim()) }
  }
}

function settledCharge(stateFile, repoDir, runId) {
  try {
    return JSON.parse(execFileSync('bash', [CHECKER, 'ci-split', '--state', stateFile,
      '--run-id', runId, '--repo-dir', repoDir],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim())
  } catch (error) {
    throw new Error((error.stderr || error.stdout || error.message).trim())
  }
}

function codexRequired(record, policy) {
  if (policy?.rounds?.integration === 0) return false
  const selections = (record.finder_selection ?? [])
    .filter((entry) => entry?.stage === 'integration')
    .flatMap((entry) => entry?.effective ?? [])
    .map((entry) => typeof entry === 'string' ? entry : entry?.finder)
  // A selection extends the resolved stage configuration; it never replaces
  // it.  Keep this identical to run-record.mjs's resolvedSlots() rule: a
  // later selected finder must not turn a configured codex-cloud requirement
  // into permission to publish a null cycle.
  const configured = policy?.stages?.integration?.finders ?? []
  const required = new Set([...configured, ...selections])
  if (!required.has('codex-cloud')) return false
  // Match the integrator and readiness-gate required-finder projection: a
  // profile opts this finder out only when it says so explicitly.  Ids-only
  // legacy policies remain required, and selections add coverage rather than
  // replacing configured finders.
  const entries = policy?.stages?.integration?.finder ?? []
  const profiles = entries.filter((entry) => entry?.id === 'codex-cloud')
  if (profiles.length > 1) return true
  const profile = profiles[0]
  return profile?.gates !== false && profile?.budget !== 0
}

// `check-codex-cloud-review.sh check` documents these as the outcomes that
// have completed a review observation: clean (0), findings (10), terminal
// escalation (13), a PR that is no longer open (14), and quota exhaustion
// (15). Pending (11), retry (12), transient reads (16), indeterminate (2),
// and stale local assets (19) are not immutable evidence: a later observation
// can replace them without another integration round.
const COMPLETED_CHECKER_EXITS = new Set([0, 10, 13, 14, 15])

// Both strict schema validation and the public record writer admit immutable
// integrator receipts. Keep the completed-observation invariant here so those
// two boundaries cannot drift by accepting different in-flight diagnostics.
export function integratorReceiptObservationErrors(payload) {
  const errors = []
  if (Array.isArray(payload?.checks)) {
    const pending = payload.checks.filter((check) => check?.bucket === 'pending')
    if (pending.length > 0) {
      errors.push(`$result.payload.checks: pending checks cannot be admitted as an integrator receipt (${pending.map((check) => check.name ?? '?').join(', ')})`)
    }
  }
  if (payload?.verdict === 'pending') {
    errors.push('$result.payload: a pending review verdict cannot be admitted as an integrator receipt')
  }
  const cycles = []
  if (payload?.codex_cycle && typeof payload.codex_cycle === 'object') {
    cycles.push({ label: 'codex_cycle', exitCode: payload.codex_cycle.exit_code })
  }
  if (Array.isArray(payload?.finder_cycles)) {
    payload.finder_cycles.forEach((cycle, index) => {
      if (cycle && typeof cycle === 'object') cycles.push({ label: `finder_cycles[${index}] (${cycle.finder ?? '?'})`, exitCode: cycle.exit_code })
    })
  }
  for (const { label, exitCode } of cycles) {
    if (!COMPLETED_CHECKER_EXITS.has(exitCode)) {
      errors.push(`$result.payload.${label}: checker exit_code ${exitCode} is not a completed observation and cannot be admitted as an integrator receipt`)
    }
  }
  return errors
}

function cksum(value) {
  return execFileSync('cksum', [], { input: value, encoding: 'utf8' }).trim().replaceAll(' ', '-')
}

function readJson(file) {
  try { return JSON.parse(readFileSync(file, 'utf8')) } catch { return null }
}

function expectedSettlement(disposition) {
  return disposition === 'declined'
    ? { disposition: 'decline', referenceType: 'comment_id' }
    : disposition === 'filed'
      ? { disposition: 'file', referenceType: 'issue_number' }
      : null
}

function hasReference(entry, type) {
  return entry?.reference?.type === type && typeof entry.reference.value === 'string' && entry.reference.value.length > 0
}

// A carry keeps the checker cycle anchored at the original reviewed head,
// while a retained integration pass names the later head it attests.  The
// carry object is the immutable link between those two identities; comparing
// only pass.head to state.head would discard a legitimate settlement that a
// later live check must still honour.
export function passAttestsCheckerCycle(pass, state) {
  if (pass?.head === state?.head) return true
  const carried = pass?.payload?.codex_cycle?.carried
  if (!carried) return false
  return carried.origin_head === state.head &&
    carried.attests_head === pass.head
}

// A checker state belongs to the integrator and can be replaced after it was
// written.  It therefore supplies a live observation, never the authority to
// erase a finding.  Retained pass/adjudication/run bytes are the independent
// authority for every local non-thread settlement the checker is allowed to
// honour.  The checker still verifies the live source timestamp and body after
// this filter; a stale entry simply becomes inert rather than poisoning a
// later independently clean observation.
function trustedSettlements(state, record, recordDir) {
  if (!Array.isArray(state?.settled) || state.settled.length === 0 || !recordDir) return []
  const receiptNames = new Set(
    (record?.receipts ?? [])
      .filter((receipt) => receipt?.kind === 'pass' && /^integration-r[1-9][0-9]*-integrator$/.test(receipt?.file ?? ''))
      .map((receipt) => receipt.file)
  )
  const passes = [...receiptNames]
    .map((name) => ({ name, pass: readJson(join(recordDir, 'passes', `${name}.json`)) }))
    .filter(({ pass }) => pass?.run?.run_id === record?.run_id && passAttestsCheckerCycle(pass, state))
  const adjudicationDir = join(recordDir, 'adjudications')
  if (!existsSync(adjudicationDir)) return []
  const settlements = new Map((record?.settlements ?? []).map((entry) => [entry?.finding_id, entry]))
  return state.settled.filter((settled) => {
    const expected = expectedSettlement(settled?.disposition)
    if (!expected || typeof settled?.id !== 'number' || typeof settled?.content_fingerprint !== 'string') return false
    const fingerprint = settled.content_fingerprint.split('|').at(-1)
    for (const { name, pass } of passes) {
      const round = Number(/^integration-r([1-9][0-9]*)-integrator$/.exec(name)?.[1])
      const document = readJson(join(adjudicationDir, `integration-r${round}.json`))
      if (
        !Number.isSafeInteger(round) ||
        document?.run_id !== record?.run_id ||
        document?.stage !== 'integration' ||
        document?.round !== round ||
        document?.reviewed_head !== pass.head
      ) continue
      for (const finding of pass?.payload?.findings ?? []) {
        if (finding?.source_id !== String(settled.id) || typeof finding?.body !== 'string') continue
        if (cksum(JSON.stringify(finding.body)) !== fingerprint) continue
        const adjudication = (document.adjudications ?? []).find((entry) => entry?.finding_id === finding.id)
        if (
          adjudication?.disposition === expected.disposition &&
          (expected.disposition === 'decline' || hasReference(adjudication, expected.referenceType))
        ) return true
        const settlement = settlements.get(finding.id)
        if (adjudication?.disposition === 'defer' && settlement?.disposition === expected.disposition && hasReference(settlement, expected.referenceType)) return true
      }
    }
    return false
  })
}

function trustedCodexProfile(repo, pr) {
  // Resolve the two network leaves directly so each has a deadline.  A timeout
  // around a shell wrapper can leave its `gh` child retaining the wrapper's
  // pipes; profile extraction below remains the trusted-registry helper's
  // existing local parser.
  const options = { encoding: 'utf8', timeout: 10_000, stdio: ['ignore', 'pipe', 'pipe'] }
  const base = execFileSync('gh', ['pr', 'view', String(pr), '--repo', repo, '--json', 'baseRefOid', '--jq', '.baseRefOid'], options).trim()
  if (!/^[0-9a-f]{40}$/.test(base)) throw new Error(`trusted-registry: ${repo}#${pr} baseRefOid is not a 40-hex SHA`)
  const encoded = execFileSync('gh', ['api', `repos/${repo}/contents/agent-registry.json?ref=${base}`, '--jq', '.content'], options).trim()
  if (!encoded) throw new Error(`trusted-registry: agent-registry.json is empty at ${base} in ${repo}`)
  const directory = mkdtempSync(join(tmpdir(), 'integrator-profile-'))
  try {
    const registry = join(directory, 'registry.json')
    const profile = join(directory, 'profile.json')
    const decoded = Buffer.from(encoded, 'base64')
    if (decoded.length === 0) throw new Error(`trusted-registry: decoded registry at ${base} is empty`)
    writeFileSync(registry, decoded, { mode: 0o600 })
    // Keep resolve_trusted_registry's structural preflight: the extractor
    // below deliberately assumes a finder array, and its iteration alone
    // would otherwise accept a malformed registry shape.
    execFileSync('jq', ['-e', 'type == "object" and (.finders | type) == "array"', registry], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']
    })
    const script = 'source "$1"; resolve_finder_profile "$2" codex-cloud "$3" && ' +
      "jq -c '{slug:.slug,actor_id:(.trusted_actor_id|tostring),actor_login:.trusted_actor_login,trigger_mechanism:.collection.trigger.mechanism,trigger_body:.collection.trigger.body,reviewer_login:.collection.trigger.reviewer_login,surfaces:.collection.terminal_signals.surfaces,head_binding:.collection.terminal_signals.head_binding,verdict_mode:.collection.terminal_signals.verdict_mode,clean_verdict:.collection.terminal_signals.clean_verdict,actionable_pattern:.collection.terminal_signals.actionable_pattern,severity_marker:.collection.terminal_signals.severity_marker,metadata_line:.collection.terminal_signals.metadata_line,about_summary:.collection.terminal_signals.about_summary,heading:.collection.terminal_signals.heading,carrier_sentence:.collection.terminal_signals.carrier_sentence,success_reaction:.collection.terminal_signals.success_reaction,pending_reaction:.collection.terminal_signals.pending_reaction}' \"$3\""
    const codexProfile = JSON.parse(execFileSync('bash', ['-c', script, 'bash', TRUSTED_REGISTRY, registry, profile], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']
    }).trim())
    const trustedOrchestratorActorIds = JSON.parse(execFileSync('jq', ['-c',
      '(.trusted_orchestrator_actor_ids // []) | if type == "array" and all(.[]; type == "number" and . > 0) then . else error("invalid trusted orchestrator actors") end', registry], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe']
    }).trim())
    return { profile: codexProfile, trustedOrchestratorActorIds }
  } finally {
    rmSync(directory, { recursive: true, force: true })
  }
}

function isPositiveInteger(value) { return Number.isSafeInteger(value) && value > 0 }

function ghJson(args) {
  return JSON.parse(execFileSync('gh', args, {
    encoding: 'utf8', timeout: 10_000, stdio: ['ignore', 'pipe', 'pipe']
  }).trim())
}

// Owner captures carry the full cycle tuple. Legacy evidence predates that
// capture and cannot reconstruct writable floors, counters, or retry history.
function conservativeLegacyState(state) {
  // Share the same pure conservative projection that carry later combines
  // with its separate admitted-receipt authorization.
  // The live state remains evidence for the canonical checker, but it cannot
  // choose its own request controls during old-r1 compatibility recovery.
  return { ...state, ...conservativeLegacyControls(state) }
}

function headFromReviewedCommit(body, repo, head) {
  const match = /^\*\*reviewed commit:\*\*\s*`([0-9a-f]{7,40})`\s*$/im.exec(body ?? '')
  if (!match) throw new Error('legacy terminal source does not explicitly name a reviewed commit')
  const commit = ghJson(['api', `repos/${repo}/commits/${match[1]}`])
  if (commit?.sha !== head) throw new Error('legacy terminal source names a different immutable commit')
}

function verifyLegacyTerminal(accepted, state, head) {
  if (!['comment', 'review'].includes(accepted?.surface) || !isPositiveInteger(Number(accepted?.id))) {
    throw new Error('legacy reaction-only evidence cannot bootstrap a review cycle')
  }
  const endpoint = accepted.surface === 'comment'
    ? `repos/${state.repo}/issues/comments/${accepted.id}`
    : `repos/${state.repo}/pulls/${state.pr}/reviews/${accepted.id}`
  const source = ghJson(['api', endpoint])
  if (Number(source?.id) !== Number(accepted.id) || Number(source?.user?.id) !== Number(LEGACY_CODEX_PROFILE.actor_id)) {
    throw new Error('legacy terminal source identity is not the trusted Codex actor')
  }
  headFromReviewedCommit(source.body, state.repo, head)
}

// Returns diagnostics rather than throwing so validate-result-schemas can
// aggregate them with ordinary schema failures. `record` is the run.json
// source of truth and `policy` is its adjacent resolved projection.
export function authenticateIntegratorReceipt(envelope, { record, policy, stateFile, repoDir, recordDir }) {
  const errors = []
  const cycle = envelope?.payload?.codex_cycle
  if (record?.run_id !== envelope?.run?.run_id) errors.push('$result.run: integrator authentication record does not name this envelope run')
  if (errors.length) return errors
  // Every admission path consumes this projection. Validate it before choosing
  // between a policy-disabled null cycle and a live checker cycle so a damaged
  // policy cannot turn a non-null receipt into permission to omit its cap,
  // finder, ordering, or tier constraints.
  try { validateResolvedPolicy(policy) } catch (error) {
    errors.push(`$result.payload.codex_cycle: recorded resolved policy is incomplete or invalid: ${error.message}`)
    return errors
  }
  if (cycle === null) {
    if (codexRequired(record, policy)) {
      errors.push('$result.payload.codex_cycle: null is allowed only when the recorded resolved integration/finder policy disables Codex; required-Codex failures remain blocked diagnostics, not completed receipts')
    }
    return errors
  }
  if (!stateFile || !repoDir) {
    errors.push('$result.payload.codex_cycle: non-null cycles require --codex-state and --codex-repo-dir for read-only live authentication')
    return errors
  }
  let stateText
  let state
  try {
    // The check must consume the exact state the admission code validated.
    // A checker-state writer uses atomic replacement, so opening the original
    // pathname again after this read could mix trusted counters and bindings
    // from one generation with fresh evidence parsed under another finder.
    stateText = readFileSync(stateFile, 'utf8')
    state = JSON.parse(stateText)
  } catch (error) {
    errors.push(`$result.payload.codex_cycle: cannot read checker state ${stateFile}: ${error.message}`)
    return errors
  }
  let authority = null
  try {
    if (recordDir) authority = authorityForEnvelope(record, envelope, { common: resolve(recordDir, '../../..'), runId: record.run_id })
  } catch (error) {
    errors.push(`$result.payload.codex_cycle: retained owner authority is invalid: ${error.message}`)
    return errors
  }
  const authoritativeState = authority?.authority.snapshot ?? conservativeLegacyState(state)
  const binding = record?.pr_bindings?.at(-1)
  let bound = false
  try {
    const url = new URL(binding?.url)
    bound = Number(binding?.number) === Number(authoritativeState?.pr) &&
      url.pathname.replace(/^\/+|\/+$/g, '') === `${authoritativeState?.repo}/pull/${authoritativeState?.pr}`
  } catch { /* malformed binding cannot authenticate a cycle */ }
  if (!bound) errors.push('$result.payload.codex_cycle: checker state repo/PR is not bound to the run’s trusted PR binding')
  let trusted
  try {
    trusted = trustedCodexProfile(authoritativeState.repo, authoritativeState.pr)
    const profile = trusted.profile
    if (
      profile.actor_id !== LEGACY_CODEX_PROFILE.actor_id ||
      profile.actor_login !== LEGACY_CODEX_PROFILE.actor_login ||
      !profile.surfaces?.includes('comment') ||
      !profile.surfaces?.includes('review')
    ) {
      errors.push('$result.payload.codex_cycle: trusted codex-cloud registry profile must require the fixed Codex actor and comment/review terminal surfaces')
    }
    if (authoritativeState?.finder) {
      if (stable(authoritativeState.finder) !== stable(profile)) errors.push('$result.payload.codex_cycle: checker state finder does not exactly match the trusted codex-cloud registry profile')
    } else if (stable(profile) !== stable(LEGACY_CODEX_PROFILE)) {
      errors.push('$result.payload.codex_cycle: legacy checker defaults do not exactly match the trusted codex-cloud registry profile')
    }
  } catch (error) {
    errors.push(`$result.payload.codex_cycle: cannot resolve the trusted codex-cloud registry profile: ${error.stderr || error.message}`)
  }
  if (errors.length) return errors
  let checkedResult
  let snapshotDir
  try {
    snapshotDir = mkdtempSync(join(tmpdir(), 'integrator-receipt-'))
    const snapshot = join(snapshotDir, 'state.json')
    // The retained authority supplies request controls; current state supplies
    // only settlement candidates, each independently tied back to receipted
    // passes and adjudications by trustedSettlements.
    const authenticatedState = { ...authoritativeState, settled: trustedSettlements(state, record, recordDir) }
    writeFileSync(snapshot, JSON.stringify(authenticatedState), { encoding: 'utf8', mode: 0o600 })
    checkedResult = checkerResult(snapshot, repoDir, record.run_id)
    checkedResult.settledCharge = settledCharge(snapshot, repoDir, record.run_id)
    checkedResult.independentlyProvesTwoAttempts = Boolean(authority)
  } catch (error) {
    errors.push(`$result.payload.codex_cycle: live checker authentication failed: ${error.message}`)
    return errors
  } finally {
    if (snapshotDir) rmSync(snapshotDir, { recursive: true, force: true })
  }
  const checked = checkedResult.output
  const carried = authoritativeState?.carry ?? null
  const attested = carried?.attests_head ?? authoritativeState?.head
  const cycleTotal = Number(authoritativeState?.charged_cycles) + Number(authoritativeState?.exempt_cycles)
  if (attested !== envelope.head || cycle.head !== envelope.head) errors.push('$result.payload.codex_cycle: live checker state does not attest the envelope head')
  if (cycle.exit_code !== checkedResult.exit) errors.push('$result.payload.codex_cycle.exit_code: does not match the live checker process exit')
  // Exit 13 is terminal only after a separate trusted request establishes the
  // first full window.  The checker state's ordinal alone remains writable.
  if (checkedResult.exit === 13 && !checkedResult.independentlyProvesTwoAttempts) {
    errors.push('$result.payload.codex_cycle: terminal escalation needs two trusted same-origin requests separated by the full review window')
  }
  const hasCharged = Object.hasOwn(cycle, 'charged')
  const hasExempt = Object.hasOwn(cycle, 'exempt')
  if (hasCharged !== hasExempt) {
    errors.push('$result.payload.codex_cycle: charged and exempt counters must be supplied together')
  } else {
    // Older producers reported only the cycle ordinal.  That is the original
    // single-counter contract: all cycles were charged and none exempt.
    const reportedCharged = hasCharged ? cycle.charged : cycle.cycle
    const reportedExempt = hasExempt ? cycle.exempt : 0
    const settled = checkedResult.settledCharge?.settled
    if (cycle.cycle !== cycleTotal || reportedCharged !== settled?.charged || reportedExempt !== settled?.exempt) {
      errors.push('$result.payload.codex_cycle: cycle, charged, and exempt counters do not match checker state (canonical CI-settled split)')
    }
  }
  if (cycle.attempt !== checked.attempt || id(cycle.trigger_comment_id) !== id(authoritativeState?.trigger_comment_id)) errors.push('$result.payload.codex_cycle: attempt or trigger_comment_id does not match checker state')
  if (stable(cycle.accepted ?? null) !== stable(checked.accepted ?? null)) errors.push('$result.payload.codex_cycle.accepted: does not match the freshly checked accepted evidence')
  if (!authority) {
    try { verifyLegacyTerminal(checked.accepted, authoritativeState, envelope.head) } catch (error) {
      errors.push(`$result.payload.codex_cycle: ${error.message}`)
    }
  }
  if (stable(cycle.carried ? { ...cycle.carried, origin_head: undefined } : null) !== stable(carried)) errors.push('$result.payload.codex_cycle.carried: does not match checker state')
  if (cycle.carried && cycle.carried.origin_head !== authoritativeState?.head) errors.push('$result.payload.codex_cycle.carried.origin_head: does not match the checker cycle head')
  if (!cycle.carried && carried?.attests_head === envelope.head) errors.push('$result.payload.codex_cycle: omits the checker’s carried-forward provenance')
  return errors
}
