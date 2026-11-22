import { existsSync } from 'node:fs'
import { basename, join } from 'node:path'

export function preflightCapability(registry, { harness, role, effort }, schemasDir) {
  const selected = Array.isArray(registry?.harnesses) ? registry.harnesses.find((entry) => entry?.slug === harness) : undefined
  if (!selected) return 'unsupported-harness'
  if (!Array.isArray(selected.roles) || !selected.roles.includes(role)) return 'unsupported-role'
  if (typeof effort !== 'string' || !Array.isArray(selected.efforts) || (selected.efforts.length ? !selected.efforts.includes(effort) : Boolean(effort))) return 'unsupported-effort'
  const schema = Array.isArray(registry?.roles) ? registry.roles.find((entry) => entry?.slug === role)?.result_schema : undefined
  if (typeof schema !== 'string' || !/^ai\/schemas\/result\.[a-z]+\.schema\.json$/.test(schema) || !existsSync(join(schemasDir, basename(schema)))) return 'missing-result-schema'
  return null
}

// The one-rung escalation option a resolved policy allows for a role. Report
// only: callers disclose it and never apply it. The ladder and the switch are
// the resolved policy's own (tier_order, rigor.tier_escalation).
export function escalationOption(policy, role) {
  const ladder = policy?.tier_order
  if (policy?.rigor?.tier_escalation !== true || !Array.isArray(ladder) || !Object.hasOwn(policy.roles ?? {}, role)) return null
  const from = policy.roles[role]?.tier
  const at = ladder.indexOf(from)
  if (at < 0 || at === ladder.length - 1) return null
  return { role, rigor: policy.rigor.level, tier_escalation: true, from, to: ladder[at + 1] }
}
