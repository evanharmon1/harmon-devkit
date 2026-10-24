// Live, read-only authentication for a newly admitted integrator receipt.
// This intentionally lives below both the result validator and run-record
// writer: schema validation is the admission boundary, while later readers
// validate retained immutable bytes without re-querying an overwritten cycle.
import { execFileSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ASSET_DIR = dirname(fileURLToPath(import.meta.url))
const CHECKER = join(ASSET_DIR, '../../../integrate/assets/check-codex-cloud-review.sh')
const TRUSTED_REGISTRY = join(ASSET_DIR, '../../../integrate/assets/trusted-registry.sh')

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

function trustedCodexProfile(repo, pr) {
  const script = 'source "$1"; d=$(mktemp -d -t integrator-profile-XXXXXX) || exit; ' +
    'resolve_trusted_registry "$2" "$3" "$d/registry.json" && ' +
    'resolve_finder_profile "$d/registry.json" codex-cloud "$d/profile.json" && ' +
    "jq -c '{slug:.slug,actor_id:(.trusted_actor_id|tostring),actor_login:.trusted_actor_login,trigger_mechanism:.collection.trigger.mechanism,trigger_body:.collection.trigger.body,reviewer_login:.collection.trigger.reviewer_login,surfaces:.collection.terminal_signals.surfaces,head_binding:.collection.terminal_signals.head_binding,verdict_mode:.collection.terminal_signals.verdict_mode,clean_verdict:.collection.terminal_signals.clean_verdict,actionable_pattern:.collection.terminal_signals.actionable_pattern,severity_marker:.collection.terminal_signals.severity_marker,metadata_line:.collection.terminal_signals.metadata_line,about_summary:.collection.terminal_signals.about_summary,heading:.collection.terminal_signals.heading,carrier_sentence:.collection.terminal_signals.carrier_sentence,success_reaction:.collection.terminal_signals.success_reaction,pending_reaction:.collection.terminal_signals.pending_reaction}' \"$d/profile.json\"; rc=$?; rm -rf \"$d\"; exit $rc"
  return JSON.parse(execFileSync('bash', ['-c', script, 'bash', TRUSTED_REGISTRY, repo, String(pr)], { encoding: 'utf8' }).trim())
}

// Returns diagnostics rather than throwing so validate-result-schemas can
// aggregate them with ordinary schema failures. `record` is the run.json
// source of truth and `policy` is its adjacent resolved projection.
export function authenticateIntegratorReceipt(envelope, { record, policy, stateFile, repoDir }) {
  const errors = []
  const cycle = envelope?.payload?.codex_cycle
  if (cycle === null) {
    if (codexRequired(record, policy)) errors.push('$result.payload.codex_cycle: null is allowed only when the recorded resolved integration/finder policy disables Codex')
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
  if (state?.finder) {
    try {
      const profile = trustedCodexProfile(state.repo, state.pr)
      if (stable(state.finder) !== stable(profile)) errors.push('$result.payload.codex_cycle: checker state finder does not exactly match the trusted codex-cloud registry profile')
    } catch (error) {
      errors.push(`$result.payload.codex_cycle: cannot resolve the trusted codex-cloud registry profile: ${error.stderr || error.message}`)
    }
  }
  if (record?.run_id !== envelope?.run?.run_id) errors.push('$result.run: integrator authentication record does not name this envelope run')
  if (errors.length) return errors
  let checkedResult
  let snapshotDir
  try {
    snapshotDir = mkdtempSync(join(tmpdir(), 'integrator-receipt-'))
    const snapshot = join(snapshotDir, 'state.json')
    writeFileSync(snapshot, stateText, { encoding: 'utf8', mode: 0o600 })
    checkedResult = checkerResult(snapshot, repoDir, record.run_id)
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
  if (cycle.cycle !== cycleTotal || cycle.charged !== state?.charged_cycles || cycle.exempt !== state?.exempt_cycles) errors.push('$result.payload.codex_cycle: cycle, charged, and exempt counters do not match checker state')
  if (cycle.attempt !== checked.attempt || id(cycle.trigger_comment_id) !== id(state?.trigger_comment_id)) errors.push('$result.payload.codex_cycle: attempt or trigger_comment_id does not match checker state')
  if (stable(cycle.accepted ?? null) !== stable(checked.accepted ?? null)) errors.push('$result.payload.codex_cycle.accepted: does not match the freshly checked accepted evidence')
  if (stable(cycle.carried ? { ...cycle.carried, origin_head: undefined } : null) !== stable(carried)) errors.push('$result.payload.codex_cycle.carried: does not match checker state')
  if (cycle.carried && cycle.carried.origin_head !== state?.head) errors.push('$result.payload.codex_cycle.carried.origin_head: does not match the checker cycle head')
  if (!cycle.carried && carried?.attests_head === envelope.head) errors.push('$result.payload.codex_cycle: omits the checker’s carried-forward provenance')
  return errors
}
