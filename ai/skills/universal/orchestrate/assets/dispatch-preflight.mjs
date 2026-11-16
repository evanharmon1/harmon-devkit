#!/usr/bin/env node
import { execFileSync } from 'node:child_process'
import { realpathSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { preflightCapability } from './lib/preflight-capability.mjs'

export function dispatchPreflight({ repo, defaultRef, harness, role, effort }) {
  let registry
  try {
    const trustedRef = execFileSync('git', ['symbolic-ref', 'refs/remotes/origin/HEAD'], { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
    if (defaultRef !== trustedRef || !trustedRef.startsWith('refs/remotes/origin/')) return 'registry-snapshot-unavailable'
    registry = JSON.parse(execFileSync('git', ['--no-replace-objects', 'show', `${defaultRef}:agent-registry.json`], { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }))
  } catch {
    return 'registry-snapshot-unavailable'
  }
  const schemas = resolve(dirname(fileURLToPath(import.meta.url)), '../../dev-flow-support/assets/schemas')
  return preflightCapability(registry, { harness, role, effort }, schemas)
}

if (process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) {
  const [repo, defaultRef, harness, role, effort = ''] = process.argv.slice(2)
  if (!repo || !defaultRef || !harness || !role || process.argv.length > 7) {
    console.error('usage: dispatch-preflight.mjs REPO DEFAULT_REF HARNESS ROLE [EFFORT]')
    process.exitCode = 2
  } else {
    const refusal = dispatchPreflight({ repo, defaultRef, harness, role, effort })
    if (refusal) { console.error(`dispatch-preflight: ${refusal}`); process.exitCode = 1 } else console.log('ok')
  }
}
