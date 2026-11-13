const blocker = (tool, code, context) => ({
  schema: 'stage-outcome.v1', outcome: 'terminal-blocker',
  next_action: { kind: 'stop', reason: `Unmapped or indeterminate ${tool} exit code ${code}` },
  run: context.run, head: context.head,
  evidence: [{ kind: 'exit-code', ref: `${tool}:${code}` }],
})

const progress = (tool, code, context, stage = 'verify') => ({
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

const table = {
  'record-pass.sh': { 0: 'progress' },
  'push-fix-round.sh': { 0: 'progress', 2: 'terminal-blocker' },
  // The driver propagates checker statuses. Keeping its row derived prevents
  // reserve/check exit additions from silently diverging.
  'drive-codex-cycle.sh': { ...checkerExitKinds, ...driverExitKinds },
  'promote.sh': {
    0: 'handoff-complete', 10: 'terminal-blocker', 11: 'terminal-blocker',
    12: 'progress', 13: 'terminal-blocker', 14: 'terminal-blocker',
    15: 'retryable', 16: 'terminal-blocker', 17: 'terminal-blocker',
  },
  'check-codex-cloud-review.sh': { ...checkerExitKinds },
}

function shape(kind, tool, code, context) {
  const common = { schema: 'stage-outcome.v1', run: context.run, head: context.head,
    evidence: [{ kind: 'exit-code', ref: `${tool}:${code}` }] }
  switch (kind) {
    case 'progress': return progress(tool, code, context, context.nextStage ?? (tool === 'check-codex-cloud-review.sh' && code === 0 ? 'integration' : 'verify'))
    case 'waiting': return { ...common, outcome: kind, next_action: { kind: 'wait', event: context.event ?? `${tool} completion`, responsible: context.responsible ?? 'stage owner', overdue_after_seconds: context.overdueAfterSeconds ?? 900 } }
    case 'judgment-needed': return { ...common, outcome: kind, next_action: { kind: 'request-judgment', question: context.question ?? `${tool} returned findings`, responsible: context.responsible ?? 'orchestrator' } }
    case 'approval-blocked': return { ...common, outcome: kind, next_action: { kind: 'request-approval', approval: context.approval ?? `${tool} gate approval`, responsible: context.responsible ?? 'maintainer' } }
    case 'retryable': return { ...common, outcome: kind, next_action: { kind: 'retry', retry_key: context.retryKey ?? `${tool}:${code}`, attempt: context.attempt ?? 1, max_attempts: context.maxAttempts ?? 2 } }
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
  const kind = table[name]?.[code]
  if (name === 'promote.sh' && code === 12) {
    return { ...progress(name, code, context, 'integration'), detail: 'Run a fresh readiness audit of the already-promoted head before reporting handoff complete.' }
  }
  if (name === 'promote.sh' && code === 10) {
    return { ...blocker(name, code, context), detail: 'Readiness gate failed; repair the failed condition before retrying promotion.' }
  }
  return kind ? shape(kind, name, code, context) : blocker(name, code, context)
}

export function laneStateForOutcome(outcome) {
  return ({ progress: 'working', waiting: 'working', 'judgment-needed': 'decision-request',
    'approval-blocked': 'blocked', retryable: 'working', 'terminal-blocker': 'blocked',
    'handoff-complete': 'handoff' })[outcome] ?? 'blocked'
}
