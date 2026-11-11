// Resolve which configured integration finders the resolved policy actually
// requires. Receipt authentication and pre-cycle recovery use the lenient
// codexRequired; the catch-up helper uses the strict classifyIntegrationFinders
// (readiness-gate.sh keeps its own). Both functions share selectedFinders and
// profileGates, so they agree on whether a finder gates: an optional reviewer
// cannot become a catch-up-only gate, and a required one cannot drop out.
import { readFileSync, realpathSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

function selectedFinders(record) {
  return (record?.finder_selection ?? [])
    .filter((entry) => entry?.stage === 'integration')
    .flatMap((entry) => entry?.effective ?? [])
    .map((entry) => typeof entry === 'string' ? entry : entry?.finder)
}

// Legacy ids default to gating; explicit gates=false or budget=0 opts a finder
// out. Two profiles for one id are ambiguous, and ambiguity gates.
function profileGates(entries, id) {
  const profiles = entries.filter((entry) => entry?.id === id)
  if (profiles.length > 1) return true
  const profile = profiles[0]
  return profile?.gates !== false && profile?.budget !== 0
}

export function codexRequired(record, policy, integrationCap = policy?.rounds?.integration) {
  if (integrationCap === 0) return false
  // A selection extends configuration; it does not replace it.
  const configured = policy?.stages?.integration?.finders ?? []
  const required = new Set([...configured, ...selectedFinders(record)])
  if (!required.has('codex-cloud')) return false
  return profileGates(policy?.stages?.integration?.finder ?? [], 'codex-cloud')
}

// Strict projection for a caller that relaxes a guard on the answer: every
// malformed input throws, so the caller can fail closed (treat as required).
// Returns { classes: { <id>: 'required' | 'advisory' }, required: [<id>...] }.
export function classifyIntegrationFinders(record, policy, finders, integrationCap = policy?.rounds?.integration) {
  const stage = policy?.stages?.integration
  if (!stage || !Array.isArray(stage.finders) || stage.finders.some((id) => typeof id !== 'string' || id.length === 0)) {
    throw new Error('invalid integration finder policy: stages.integration.finders')
  }
  const entries = stage.finder ?? []
  if (!Array.isArray(entries) || entries.some((entry) => entry === null || typeof entry !== 'object' || typeof entry.id !== 'string')) {
    throw new Error('invalid integration finder policy: stages.integration.finder')
  }
  if (!Number.isInteger(integrationCap) || integrationCap < 0) {
    throw new Error('invalid integration cap in the resolved policy')
  }
  const selected = selectedFinders(record)
  if (selected.some((id) => typeof id !== 'string' || id.length === 0)) {
    throw new Error('invalid integration finder selection in the run record')
  }
  const configured = new Set([...stage.finders, ...selected])
  const gates = (id) => integrationCap > 0 && profileGates(entries, id)
  const classes = {}
  for (const id of finders) {
    if (typeof id !== 'string' || !configured.has(id)) {
      throw new Error(`unknown integration finder: ${id} is not configured by the resolved policy`)
    }
    classes[id] = gates(id) ? 'required' : 'advisory'
  }
  return { classes, required: [...configured].filter(gates).sort() }
}

function isCliEntry() {
  if (!process.argv[1] || process.execArgv.some((arg) => arg === '-e' || arg.startsWith('--eval') || arg.startsWith('--input-type'))) return false
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))
  } catch {
    return false
  }
}

// classify --record RUN_DIRECTORY --repo OWNER/REPO --pr N FINDER...
// Reads only the run record's own run.json and policy.json — never a
// candidate branch's .devflow.toml — and requires the record's PR binding to
// name OWNER/REPO#N. Prints the projection as JSON; exits 1 on any doubt.
if (isCliEntry()) {
  try {
    const args = process.argv.slice(2)
    if (args[0] !== 'classify' || args[1] !== '--record' || args[3] !== '--repo' || args[5] !== '--pr' || args.length < 8) {
      throw new Error('usage: integration-finder-requirements.mjs classify --record RUN_DIRECTORY --repo OWNER/REPO --pr N FINDER...')
    }
    const [recordDir, repo, prText] = [args[2], args[4], args[6]]
    if (!/^[1-9][0-9]*$/.test(prText)) throw new Error('--pr must be a positive integer')
    const pr = Number(prText)
    const record = JSON.parse(readFileSync(join(recordDir, 'run.json'), 'utf8'))
    const policy = JSON.parse(readFileSync(join(recordDir, 'policy.json'), 'utf8'))
    const binding = record?.pr_bindings?.at?.(-1)
    let boundPath = null
    try {
      boundPath = new URL(binding?.url).pathname
    } catch {
      // A malformed bound URL binds nothing: fail closed below.
    }
    if (typeof record?.run_id !== 'string' || binding?.number !== pr ||
        boundPath !== `/${repo}/pull/${pr}`) {
      throw new Error(`the run record is not bound to ${repo}#${pr}`)
    }
    process.stdout.write(`${JSON.stringify(classifyIntegrationFinders(record, policy, args.slice(7)))}\n`)
  } catch (error) {
    process.stderr.write(`${error.message}\n`)
    process.exitCode = 1
  }
}
