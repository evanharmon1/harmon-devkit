#!/usr/bin/env node
import { execFileSync } from 'node:child_process'
import { realpathSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { resolveAbsentPolicy, resolvePolicy } from '../../dev-flow-support/assets/devflow-policy.mjs'
import { parseToml } from '../../dev-flow-support/assets/lib/toml-lite.mjs'
import { escalationOption, preflightCapability } from './lib/preflight-capability.mjs'

const git = (repo, args) => execFileSync('git', ['--no-replace-objects', ...args], { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] })

// Only the fetched default ref is a trusted snapshot; a branch never supplies it.
function trustedRef(repo, defaultRef) {
  const ref = git(repo, ['symbolic-ref', 'refs/remotes/origin/HEAD']).trim()
  if (defaultRef !== ref || !ref.startsWith('refs/remotes/origin/')) throw new Error(`default ref ${defaultRef} is not the trusted ${ref}`)
  return ref
}

export function dispatchPreflight({ repo, defaultRef, harness, role, effort }) {
  let registry
  try {
    registry = JSON.parse(git(repo, ['show', `${trustedRef(repo, defaultRef)}:agent-registry.json`]))
  } catch {
    return 'registry-snapshot-unavailable'
  }
  const schemas = resolve(dirname(fileURLToPath(import.meta.url)), '../../dev-flow-support/assets/schemas')
  return preflightCapability(registry, { harness, role, effort }, schemas)
}

// Resolve the trusted default ref's policy and report the escalation option
// for a refused role: { option } (null when none) or { unavailable }.
export function escalationReport({ repo, defaultRef, role, rigor }) {
  try {
    const ref = trustedRef(repo, defaultRef)
    const selection = rigor === undefined ? {} : { rigor }
    const present = git(repo, ['ls-tree', '--full-tree', '--name-only', ref, '--', '.devflow.toml']).trim() !== ''
    const policy = present ? resolvePolicy(parseToml(git(repo, ['show', `${ref}:.devflow.toml`])), selection) : resolveAbsentPolicy(selection)
    return { option: escalationOption(policy, role) }
  } catch (error) {
    return { unavailable: String(error?.message ?? error).replace(/\s+/g, ' ').trim() }
  }
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  const args = process.argv.slice(2)
  const rigor = args[0] === '--rigor' ? args.splice(0, 2)[1] : undefined
  const [repo, defaultRef, harness, role, effort = ''] = args
  if (!repo || !defaultRef || !harness || !role || args.length > 5 || rigor === '') {
    console.error('usage: dispatch-preflight.mjs [--rigor LEVEL] REPO DEFAULT_REF HARNESS ROLE [EFFORT]')
    process.exitCode = 2
  } else {
    const refusal = dispatchPreflight({ repo, defaultRef, harness, role, effort })
    if (refusal) {
      console.error(`dispatch-preflight: ${refusal}`)
      const { option, unavailable } = escalationReport({ repo, defaultRef, role, rigor })
      if (unavailable) console.error(`dispatch-preflight: escalation-unavailable: ${unavailable}`)
      else if (option) console.error(`dispatch-preflight: escalation-option role=${option.role} rigor=${option.rigor} tier_escalation=${option.tier_escalation} from=${option.from} to=${option.to}`)
      process.exitCode = 1
    } else console.log('ok')
  }
}
