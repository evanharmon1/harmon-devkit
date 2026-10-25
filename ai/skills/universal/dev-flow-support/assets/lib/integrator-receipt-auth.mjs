// Live, read-only authentication for a newly admitted integrator receipt.
// This intentionally lives below both the result validator and run-record
// writer: schema validation is the admission boundary, while later readers
// validate retained immutable bytes without re-querying an overwritten cycle.
import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

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
  return [...configured, ...selections].includes('codex-cloud')
}

function effectiveReviewOrder(record, policy) {
  const trigger = policy?.stages?.integration?.review_trigger ?? 'after-ci'
  if (trigger !== 'after-ci-first') return trigger
  const integrationEntries = (record?.stage_transitions ?? [])
    .filter((transition) => transition?.stage === 'integration')
    .length
  const remediationCount = Math.max(0, integrationEntries - 1)
  return remediationCount === 0 ? 'after-ci' : 'with-push'
}

function completedAfterCiFailure(envelope, record, policy) {
  const payload = envelope?.payload
  if (envelope?.status !== 'completed') return false
  if (!['findings', 'escalate'].includes(payload?.verdict)) return false
  if (!Array.isArray(payload?.checks) || payload.checks.some((check) => check?.bucket === 'pending')) return false
  if (!payload.checks.some((check) => check?.required === true && ['fail', 'cancel'].includes(check?.bucket))) return false
  return effectiveReviewOrder(record, policy) === 'after-ci'
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

function isSha(value) { return typeof value === 'string' && /^[0-9a-f]{40}$/.test(value) }
function isTimestamp(value) { return typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(value) }
function isPositiveInteger(value) { return Number.isSafeInteger(value) && value > 0 }

function ghJson(args) {
  return JSON.parse(execFileSync('gh', args, {
    encoding: 'utf8', timeout: 10_000, stdio: ['ignore', 'pipe', 'pipe']
  }).trim())
}

function priorClosedCycleTriggerCeiling(record, recordDir, state) {
  if (!recordDir) return null
  const currentCycle = Number(state?.charged_cycles) + Number(state?.exempt_cycles)
  if (!Number.isSafeInteger(currentCycle) || currentCycle < 1) return null
  const ids = []
  for (const receipt of record?.receipts ?? []) {
    if (receipt?.kind !== 'pass' || !/^integration-r[1-9][0-9]*-integrator$/.test(receipt.file ?? '')) continue
    const pass = readJson(join(recordDir, 'passes', `${receipt.file}.json`))
    const trigger = Number(pass?.payload?.codex_cycle?.trigger_comment_id)
    const passCycle = Number(pass?.payload?.codex_cycle?.cycle)
    if (pass?.run?.run_id === record?.run_id && passAttestsCheckerCycle(pass, state) &&
      Number.isSafeInteger(passCycle) && passCycle < currentCycle && isPositiveInteger(trigger)) {
      ids.push(trigger)
    }
  }
  return ids.length === 0 ? null : Math.max(...ids)
}

// The checker state is writable by the integrator, so it may describe a
// narrower review window than the evidence it asks the checker to classify.
// Rebuild only the review-comment tuple from GitHub's immutable actor/comment
// data and the recorded receipt chain, then let the unchanged checker consume
// that conservative snapshot.  The state head remains the reviewed origin on
// a carry; the later attested head has no trigger history of its own.
export function authenticatedReviewCommentSnapshot(state, profile, trustedActorIds, record, recordDir) {
  const mechanism = state?.finder?.trigger_mechanism ?? profile.trigger_mechanism
  if (mechanism !== 'review-comment') return { state, independentlyProvesTwoAttempts: false }
  const triggerId = Number(state?.trigger_comment_id)
  if (!isPositiveInteger(triggerId) || !isSha(state?.head)) throw new Error('review-comment state has no usable origin head or trigger id')
  const expectedBody = state?.finder?.trigger_body ?? profile.trigger_body
  if (typeof expectedBody !== 'string' || expectedBody.length === 0) throw new Error('review-comment state has no trusted trigger body')
  const repo = state.repo
  const pr = Number(state.pr)
  if (typeof repo !== 'string' || !isPositiveInteger(pr)) throw new Error('review-comment state has invalid repository binding')
  const actorIds = new Set(trustedActorIds)
  if (actorIds.size === 0) throw new Error('trusted registry has no orchestrator actors for review trigger authentication')
  const trigger = ghJson(['api', `repos/${repo}/issues/comments/${triggerId}`])
  const isExactTrigger = (comment) =>
    Number(comment?.id) === triggerId &&
    typeof comment?.body === 'string' && comment.body.trim() === expectedBody &&
    typeof comment?.issue_url === 'string' && comment.issue_url.endsWith(`/issues/${pr}`) &&
    isTimestamp(comment?.created_at) && actorIds.has(comment?.user?.id)
  if (!isExactTrigger(trigger)) throw new Error('checker trigger is not an exact trusted orchestrator review request')

  const commit = ghJson(['api', `repos/${repo}/commits/${state.head}`])
  const dates = [commit?.commit?.author?.date, commit?.commit?.committer?.date]
  if (!dates.every(isTimestamp)) throw new Error('origin commit has no canonical timestamps')
  const checkSuitePages = ghJson(['api', '--paginate', '--slurp', `repos/${repo}/commits/${state.head}/check-suites?per_page=100`])
  const suites = (Array.isArray(checkSuitePages) ? checkSuitePages : []).flatMap((page) => Array.isArray(page?.check_suites) ? page.check_suites : [])
  const suiteDates = suites.map((suite) => suite?.created_at).filter(isTimestamp)
  if (suiteDates.length === 0) throw new Error('origin head has no readable check-suite timestamp')
  const lowerTime = [...dates, ...suiteDates].sort()[0]

  const commentPages = ghJson(['api', '--paginate', '--slurp', `repos/${repo}/issues/${pr}/comments?per_page=100`])
  const comments = (Array.isArray(commentPages) ? commentPages : []).flat()
  const candidates = comments.filter((comment) =>
    isPositiveInteger(comment?.id) &&
    typeof comment?.body === 'string' && comment.body.trim() === expectedBody &&
    typeof comment?.issue_url === 'string' && comment.issue_url.endsWith(`/issues/${pr}`) &&
    isTimestamp(comment?.created_at) && actorIds.has(comment?.user?.id) &&
    comment.created_at >= lowerTime,
  )
  if (!candidates.some((comment) => comment.id === triggerId)) throw new Error('checker trigger cannot be bound to its reviewed origin head')
  const firstTriggerId = Math.min(...candidates.map((comment) => comment.id))
  const recordedFirst = Number(state.first_trigger_comment_id ?? state.trigger_comment_id)
  if (recordedFirst !== firstTriggerId) throw new Error('checker first-trigger boundary does not match live trusted trigger history')
  // The documented default is 15 minutes, while an explicit profile may use
  // the supported 10-minute minimum.  A writable state can ask for more wait,
  // never less than that contractual floor.
  const persistedTimeout = state.timeout_min === null || state.timeout_min === undefined ? 15 : Number(state.timeout_min)
  if (!isPositiveInteger(persistedTimeout)) throw new Error('checker state has an invalid timeout_min')
  const isLaterTrustedTrigger = triggerId > firstTriggerId
  const snapshot = {
    ...state,
    trigger_comment_id: triggerId,
    requested_at: trigger.created_at,
    first_trigger_comment_id: firstTriggerId,
    // Honour an existing full-window obligation and conservatively add one
    // where live history proves an earlier trusted request.  Do not infer the
    // retry ordinal: separate cycles can legitimately start at attempt 1.
    requires_full_window: state.requires_full_window === true || isLaterTrustedTrigger,
    timeout_min: Math.max(10, persistedTimeout)
  }
  // A completed earlier cycle is not this cycle's first attempt.  Its receipt
  // establishes that boundary only for exit-13's two-attempt proof; it must
  // never alter the checker's trusted first-trigger history or exclude an
  // idempotently re-read current-cycle trigger from the snapshot.
  const closedCeiling = priorClosedCycleTriggerCeiling(record, recordDir, state)
  const attemptCandidates = closedCeiling === null
    ? candidates
    : candidates.filter((comment) => comment.id > closedCeiling)
  const first = attemptCandidates.reduce((earliest, comment) =>
    earliest === null || comment.id < earliest.id ? comment : earliest, null)
  const independentlyProvesTwoAttempts =
    snapshot.attempt === 2 &&
    first !== null && triggerId > first.id &&
    Date.parse(trigger.created_at) - Date.parse(first.created_at) >= snapshot.timeout_min * 60_000
  return { state: snapshot, independentlyProvesTwoAttempts }
}

// Returns diagnostics rather than throwing so validate-result-schemas can
// aggregate them with ordinary schema failures. `record` is the run.json
// source of truth and `policy` is its adjacent resolved projection.
export function authenticateIntegratorReceipt(envelope, { record, policy, stateFile, repoDir, recordDir }) {
  const errors = []
  const cycle = envelope?.payload?.codex_cycle
  if (record?.run_id !== envelope?.run?.run_id) errors.push('$result.run: integrator authentication record does not name this envelope run')
  if (errors.length) return errors
  if (cycle === null) {
    if (codexRequired(record, policy) && !completedAfterCiFailure(envelope, record, policy)) {
      errors.push('$result.payload.codex_cycle: null is allowed only when the recorded resolved integration/finder policy disables Codex or a completed after-ci required-check failure prevented a review request')
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
  const binding = record?.pr_bindings?.at(-1)
  let bound = false
  try {
    const url = new URL(binding?.url)
    bound = Number(binding?.number) === Number(state?.pr) &&
      url.pathname.replace(/^\/+|\/+$/g, '') === `${state?.repo}/pull/${state?.pr}`
  } catch { /* malformed binding cannot authenticate a cycle */ }
  if (!bound) errors.push('$result.payload.codex_cycle: checker state repo/PR is not bound to the run’s trusted PR binding')
  let trusted
  try {
    trusted = trustedCodexProfile(state.repo, state.pr)
    const profile = trusted.profile
    if (
      profile.actor_id !== LEGACY_CODEX_PROFILE.actor_id ||
      profile.actor_login !== LEGACY_CODEX_PROFILE.actor_login ||
      !profile.surfaces?.includes('comment') ||
      !profile.surfaces?.includes('review')
    ) {
      errors.push('$result.payload.codex_cycle: trusted codex-cloud registry profile must require the fixed Codex actor and comment/review terminal surfaces')
    }
    if (state?.finder) {
      if (stable(state.finder) !== stable(profile)) errors.push('$result.payload.codex_cycle: checker state finder does not exactly match the trusted codex-cloud registry profile')
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
    const authentication = authenticatedReviewCommentSnapshot(state, trusted.profile, trusted.trustedOrchestratorActorIds, record, recordDir)
    const authenticatedState = authentication.state
    writeFileSync(snapshot, JSON.stringify({ ...authenticatedState, settled: trustedSettlements(authenticatedState, record, recordDir) }), { encoding: 'utf8', mode: 0o600 })
    checkedResult = checkerResult(snapshot, repoDir, record.run_id)
    checkedResult.independentlyProvesTwoAttempts = authentication.independentlyProvesTwoAttempts
  } catch (error) {
    errors.push(`$result.payload.codex_cycle: live checker authentication failed: ${error.message}`)
    return errors
  } finally {
    if (snapshotDir) rmSync(snapshotDir, { recursive: true, force: true })
  }
  const checked = checkedResult.output
  const carried = state?.carry ?? null
  const attested = carried?.attests_head ?? state?.head
  const cycleTotal = Number(state?.charged_cycles) + Number(state?.exempt_cycles)
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
    if (cycle.cycle !== cycleTotal || reportedCharged !== state?.charged_cycles || reportedExempt !== state?.exempt_cycles) {
      errors.push('$result.payload.codex_cycle: cycle, charged, and exempt counters do not match checker state')
    }
  }
  if (cycle.attempt !== checked.attempt || id(cycle.trigger_comment_id) !== id(state?.trigger_comment_id)) errors.push('$result.payload.codex_cycle: attempt or trigger_comment_id does not match checker state')
  if (stable(cycle.accepted ?? null) !== stable(checked.accepted ?? null)) errors.push('$result.payload.codex_cycle.accepted: does not match the freshly checked accepted evidence')
  if (stable(cycle.carried ? { ...cycle.carried, origin_head: undefined } : null) !== stable(carried)) errors.push('$result.payload.codex_cycle.carried: does not match checker state')
  if (cycle.carried && cycle.carried.origin_head !== state?.head) errors.push('$result.payload.codex_cycle.carried.origin_head: does not match the checker cycle head')
  if (!cycle.carried && carried?.attests_head === envelope.head) errors.push('$result.payload.codex_cycle: omits the checker’s carried-forward provenance')
  return errors
}
