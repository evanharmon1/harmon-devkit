import { existsSync } from 'node:fs'
import { basename, join } from 'node:path'

export function preflightCapability(registry, { harness, role, effort }, schemasDir) {
  const selected = Array.isArray(registry?.harnesses) ? registry.harnesses.find((entry) => entry.slug === harness) : undefined
  if (!selected) return 'unsupported-harness'
  if (!Array.isArray(selected.roles) || !selected.roles.includes(role)) return 'unsupported-role'
  if (!Array.isArray(selected.efforts) || (selected.efforts.length ? !selected.efforts.includes(effort) : Boolean(effort))) return 'unsupported-effort'
  const schema = Array.isArray(registry?.roles) ? registry.roles.find((entry) => entry.slug === role)?.result_schema : undefined
  if (typeof schema !== 'string' || !/^ai\/schemas\/result\.[a-z]+\.schema\.json$/.test(schema) || !existsSync(join(schemasDir, basename(schema)))) return 'missing-result-schema'
  return null
}
