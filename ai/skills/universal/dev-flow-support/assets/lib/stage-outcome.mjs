/** Project an immutable stage outcome onto the mutable lane-status vocabulary. */
export function laneStateForOutcome(outcome) {
  return ({ progress: 'working', waiting: 'working', 'judgment-needed': 'decision-request',
    'approval-blocked': 'blocked', retryable: 'working', 'terminal-blocker': 'blocked',
    'handoff-complete': 'handoff' })[outcome] ?? 'blocked'
}
