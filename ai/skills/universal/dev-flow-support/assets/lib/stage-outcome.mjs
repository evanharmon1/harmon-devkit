const blocker = (tool, code, context) => ({
  schema: 'stage-outcome.v1', outcome: 'terminal-blocker',
  next_action: { kind: 'stop', reason: `Unmapped or indeterminate ${tool} exit code ${code}` },
  run: context.run, head: context.head,
  evidence: [{ kind: 'exit-code', ref: `${tool}:${code}` }],
})

const progress = (tool, code, context, stage) => ({
  schema: 'stage-outcome.v1', outcome: 'progress',
  next_action: { kind: 'continue', stage }, run: context.run, head: context.head,
  evidence: [{ kind: 'exit-code', ref: `${tool}:${code}` }],
  ...(context.detail ? { detail: context.detail } : {}),
})

const checkerExitKinds = {
  0: 'progress', 2: 'terminal-blocker', 10: 'judgment-needed', 11: 'waiting',
  12: 'retryable', 13: 'terminal-blocker', 14: 'terminal-blocker',
  15: 'approval-blocked', 16: 'retryable', 17: 'progress', 18: 'retryable',
  19: 'terminal-blocker',
}

// The wrapper itself can refuse an invalid invocation before reaching the
// checker; exit 2 is also the checker's indeterminate result.
const driverExitKinds = { 2: 'terminal-blocker' }

const row = (outcome, fields = {}) => ({ outcome, ...fields })
// One authoritative row per documented primitive exit. Progress rows own
// their stage; run-dependent stages explicitly require caller context.
const table = {
  'record-pass.sh': {
    0: row('progress', { stageFromContext: true }),
    2: row('terminal-blocker'), 20: row('progress', { stage: 'challenge' }),
    21: row('progress', { stage: 'challenge' }), 22: row('progress', { stage: 'challenge' }),
    23: row('judgment-needed'), 24: row('waiting'),
  },
  'push-fix-round.sh': {
    0: row('progress', { stage: 'implement' }), 2: row('terminal-blocker'),
    3: row('terminal-blocker'), 4: row('retryable', { attempt: 1, maxAttempts: 2 }), 5: row('terminal-blocker'),
  },
  'drive-codex-cycle.sh': Object.fromEntries(Object.entries({ ...checkerExitKinds, ...driverExitKinds })
    .map(([code, outcome]) => [code, row(outcome, outcome === 'progress' ? { stage: 'integration' } : outcome === 'retryable' ? { attempt: 1, maxAttempts: 2 } : {})])),
  'promote.sh': {
    0: row('handoff-complete'), 10: row('terminal-blocker'), 11: row('terminal-blocker'),
    12: row('progress', { stage: 'integration', detail: 'Run a fresh readiness audit of the already-promoted head before reporting handoff complete.' }),
    13: row('terminal-blocker'), 14: row('terminal-blocker'), 15: row('retryable', { attempt: 1, maxAttempts: 2 }),
    16: row('terminal-blocker'), 17: row('terminal-blocker'),
  },
  'check-codex-cloud-review.sh': Object.fromEntries(Object.entries(checkerExitKinds)
    .map(([code, outcome]) => [code, row(outcome, outcome === 'progress' ? { stage: 'integration' } : outcome === 'retryable' ? { attempt: 1, maxAttempts: 2 } : {})])),
}

function shape(kind, tool, code, context, rowSpec) {
  const common = { schema: 'stage-outcome.v1', run: context.run, head: context.head,
    evidence: [{ kind: 'exit-code', ref: `${tool}:${code}` }] }
  switch (kind) {
    case 'progress': {
      const stage = rowSpec.stageFromContext ? context.nextStage : rowSpec.stage
      if (!['implement', 'verify', 'challenge', 'review', 'security', 'integration'].includes(stage)) throw new TypeError('progress row requires a schema-valid stage')
      return progress(tool, code, context, stage)
    }
    case 'waiting': return { ...common, outcome: kind, next_action: { kind: 'wait', event: context.event ?? `${tool} completion`, responsible: context.responsible ?? 'stage owner', overdue_after_seconds: context.overdueAfterSeconds ?? 900 } }
    case 'judgment-needed': return { ...common, outcome: kind, next_action: { kind: 'request-judgment', question: context.question ?? `${tool} returned findings`, responsible: context.responsible ?? 'orchestrator' } }
    case 'approval-blocked': return { ...common, outcome: kind, next_action: { kind: 'request-approval', approval: context.approval ?? `${tool} gate approval`, responsible: context.responsible ?? 'maintainer' } }
    case 'retryable': {
      const attempt = rowSpec.attempt
      const maxAttempts = rowSpec.maxAttempts
      if (!Number.isInteger(attempt) || !Number.isInteger(maxAttempts) || attempt < 1 || maxAttempts < 1 || attempt > maxAttempts) throw new TypeError('retry row has invalid attempt bounds')
      return { ...common, outcome: kind, next_action: { kind: 'retry', retry_key: context.retryKey ?? `${tool}:${code}`, attempt, max_attempts: maxAttempts } }
    }
    case 'handoff-complete': return { ...common, outcome: kind, next_action: { kind: 'handoff', destination: context.destination ?? 'orchestrator' } }
    default: return { ...common, outcome: 'terminal-blocker', next_action: { kind: 'stop', reason: context.reason ?? `${tool} returned terminal exit ${code}` } }
  }
}

/** Convert a documented primitive exit into a schema-shaped, run/head-bound outcome. */
export function mapStageExit(tool, code, context) {
  if (!context || typeof context !== 'object' || !context.run || typeof context.run !== 'object' ||
      typeof context.run.run_id !== 'string' || context.run.run_id.length === 0 ||
      !Number.isInteger(context.run.generation) || context.run.generation < 1 ||
      !/^[0-9a-f]{40}$/.test(context.head ?? '')) {
    throw new TypeError('context.run with run_id and positive generation, and a lowercase 40-character context.head are required')
  }
  const name = tool.split('/').at(-1)
  const rowSpec = table[name]?.[code]
  const kind = rowSpec?.outcome
  if (name === 'promote.sh' && code === 10) {
    return { ...blocker(name, code, context), detail: 'Readiness gate failed; repair the failed condition before retrying promotion.' }
  }
  return kind ? { ...shape(kind, name, code, context, rowSpec), ...(rowSpec.detail ? { detail: rowSpec.detail } : {}) } : blocker(name, code, context)
}

export function stageExitTable() { return structuredClone(table) }

export function laneStateForOutcome(outcome) {
  return ({ progress: 'working', waiting: 'working', 'judgment-needed': 'decision-request',
    'approval-blocked': 'blocked', retryable: 'working', 'terminal-blocker': 'blocked',
    'handoff-complete': 'handoff' })[outcome] ?? 'blocked'
}
