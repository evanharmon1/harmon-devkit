const STAGES = new Set(['implement', 'verify', 'challenge', 'review', 'security', 'integration'])

const own = (value, key) => Object.hasOwn(value, key) ? value[key] : undefined
const row = (outcome, fields = {}) => Object.freeze({ outcome, ...fields })

// The checker is the authoritative source for the driver rows. The driver
// consumes carry's 17 internally; it can otherwise propagate every documented
// checker exit, including pending/transient reads after a successful carry.
const driverExitCodes = [0, 2, 10, 11, 12, 13, 14, 15, 16, 18, 19]

// One authoritative row per documented primitive exit. A row owns every
// outcome-specific decision; callers only supply required run context and a
// retry attempt, never a global next stage or retry bound.
const table = {
  'record-pass.sh': Object.freeze({
    0: row('progress', { stageFromContext: true }),
    2: row('terminal-blocker'),
    20: row('progress', { stageFromContext: true }),
    21: row('judgment-needed', { question: 'record-pass diverged and needs adjudication', responsible: 'orchestrator' }),
    22: row('terminal-blocker'),
    23: row('judgment-needed', { question: 'record-pass awaits adjudication', responsible: 'orchestrator' }),
    24: row('waiting', { event: 'record-pass completion', responsible: 'stage owner', overdueAfterSeconds: 900 }),
  }),
  'push-fix-round.sh': Object.freeze({
    0: row('progress', { stageFromContext: true }),
    2: row('terminal-blocker'),
    3: row('terminal-blocker'),
    4: row('retryable', { maxAttempts: 2 }),
    5: row('terminal-blocker'),
  }),
  'promote.sh': Object.freeze({
    0: row('handoff-complete', { destination: 'orchestrator' }),
    10: row('terminal-blocker'),
    11: row('terminal-blocker'),
    12: row('progress', {
      stage: 'integration',
      detail: 'Run a fresh readiness audit of the already-promoted head before reporting handoff complete.',
    }),
    13: row('terminal-blocker'),
    14: row('terminal-blocker'),
    15: row('terminal-blocker'),
    16: row('terminal-blocker'),
    17: row('terminal-blocker'),
  }),
  'advance-to-integration.sh': Object.freeze({
    0: row('progress', {
      stage: 'integration',
      detail: 'Integration entered; run integrate/assets/drive-codex-cycle.sh, which waits for CI on this head before requesting the review.',
    }),
    2: row('terminal-blocker'),
    3: row('terminal-blocker'),
    4: row('judgment-needed', { question: 'The confidence stage has no advance verdict for this head', responsible: 'orchestrator' }),
    5: row('terminal-blocker'),
    10: row('progress', {
      stage: 'integration',
      detail: 'Integration entered; run integrate/assets/drive-codex-cycle.sh now: review_trigger requests the review with the push.',
    }),
    11: row('progress', {
      stage: 'integration',
      detail: 'Integration entered with no Codex review cycle owed (integration cap 0 or Codex not required); continue with the handoff check once CI concludes.',
    }),
  }),
  'check-codex-cloud-review.sh': Object.freeze({
    0: row('progress', { stage: 'integration' }),
    2: row('terminal-blocker'),
    10: row('judgment-needed', { question: 'Codex cloud review returned findings', responsible: 'orchestrator' }),
    11: row('waiting', { event: 'Codex cloud review completion', responsible: 'integrator', overdueAfterSeconds: 900 }),
    12: row('retryable', { maxAttempts: 2 }),
    13: row('terminal-blocker'),
    14: row('terminal-blocker'),
    15: row('terminal-blocker'),
    16: row('retryable', { maxAttempts: 2 }),
    17: row('progress', { stage: 'integration' }),
    18: row('retryable', { maxAttempts: 2 }),
    19: row('terminal-blocker'),
  }),
}

table['drive-codex-cycle.sh'] = Object.freeze(Object.fromEntries(
  driverExitCodes.map((code) => [code, own(table['check-codex-cloud-review.sh'], code)]),
))
Object.freeze(table)

function assertContext(context) {
  if (!context || typeof context !== 'object' || !context.run || typeof context.run !== 'object' ||
      typeof context.run.run_id !== 'string' || context.run.run_id.length === 0 ||
      !Number.isInteger(context.run.generation) || context.run.generation < 1 ||
      !/^[0-9a-f]{40}$/.test(typeof context.head === 'string' ? context.head : '')) {
    throw new TypeError('context.run with run_id and positive generation, and a lowercase 40-character context.head are required')
  }
}

function blocker(tool, code, context, reason) {
  return {
    schema: 'stage-outcome.v1',
    outcome: 'terminal-blocker',
    next_action: { kind: 'stop', reason: reason === undefined ? `Unmapped or indeterminate ${tool} exit code ${code}` : reason },
    run: { run_id: context.run.run_id, generation: context.run.generation },
    head: context.head,
    evidence: [{ kind: 'exit-code', ref: `${tool}:${code}` }],
  }
}

function common(tool, code, context) {
  return {
    schema: 'stage-outcome.v1',
    run: { run_id: context.run.run_id, generation: context.run.generation },
    head: context.head,
    evidence: [{ kind: 'exit-code', ref: `${tool}:${code}` }],
  }
}

function shape(tool, code, context, rowSpec) {
  const { outcome } = rowSpec
  const base = common(tool, code, context)
  switch (outcome) {
    case 'progress': {
      const stage = rowSpec.stageFromContext ? context.nextStage : rowSpec.stage
      if (!STAGES.has(stage)) throw new TypeError('progress row requires a schema-valid stage')
      return { ...base, outcome, next_action: { kind: 'continue', stage } }
    }
    case 'waiting':
      return { ...base, outcome, next_action: {
        kind: 'wait',
        event: rowSpec.event,
        responsible: rowSpec.responsible,
        overdue_after_seconds: rowSpec.overdueAfterSeconds,
      } }
    case 'judgment-needed':
      return { ...base, outcome, next_action: {
        kind: 'request-judgment',
        question: rowSpec.question,
        responsible: rowSpec.responsible,
      } }
    case 'retryable': {
      const attempt = context.attempt
      const maxAttempts = rowSpec.maxAttempts
      if (!Number.isInteger(attempt) || attempt < 1 || attempt > maxAttempts) {
        throw new TypeError('retry rows require a caller-supplied integer attempt from 1 through max_attempts')
      }
      if (attempt === maxAttempts) {
        return blocker(tool, code, context, `Retry budget exhausted for ${tool} exit code ${code} after ${attempt} attempts`)
      }
      return { ...base, outcome, next_action: {
        kind: 'retry',
        retry_key: `${tool}:${code}`,
        attempt,
        max_attempts: maxAttempts,
      } }
    }
    case 'handoff-complete':
      return { ...base, outcome, next_action: { kind: 'handoff', destination: rowSpec.destination } }
    default:
      return blocker(tool, code, context, `${tool} returned terminal exit ${code}`)
  }
}

/** Convert a documented primitive exit into a schema-shaped, run/head-bound outcome. */
export function mapStageExit(tool, code, context) {
  assertContext(context)
  if (typeof tool !== 'string') throw new TypeError('tool must be a string')
  const name = tool.split('/').at(-1)
  const primitive = own(table, name)
  const rowSpec = Number.isInteger(code) && primitive ? own(primitive, code) : undefined
  const mapped = rowSpec ? shape(name, code, context, rowSpec) : blocker(name, code, context)
  return rowSpec?.detail ? { ...mapped, detail: rowSpec.detail } : mapped
}

export function stageExitTable() { return structuredClone(table) }

/** Project an immutable stage outcome onto the mutable lane-status vocabulary. */
export function laneStateForOutcome(outcome) {
  const states = { progress: 'working', waiting: 'working', 'judgment-needed': 'decision-request',
    'approval-blocked': 'blocked', retryable: 'working', 'terminal-blocker': 'blocked',
    'handoff-complete': 'handoff' }
  return typeof outcome === 'string' && Object.hasOwn(states, outcome) ? states[outcome] : 'blocked'
}
