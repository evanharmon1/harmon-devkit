// Resolve whether the configured integration policy actually requires a
// Codex cycle. Both receipt authentication and pre-cycle recovery use this
// projection so an optional reviewer cannot become a recovery-only gate.
export function codexRequired(record, policy, integrationCap = policy?.rounds?.integration) {
  if (integrationCap === 0) return false
  const selections = (record.finder_selection ?? [])
    .filter((entry) => entry?.stage === 'integration')
    .flatMap((entry) => entry?.effective ?? [])
    .map((entry) => typeof entry === 'string' ? entry : entry?.finder)
  // A selection extends configuration; it does not replace it.
  const configured = policy?.stages?.integration?.finders ?? []
  const required = new Set([...configured, ...selections])
  if (!required.has('codex-cloud')) return false
  const entries = policy?.stages?.integration?.finder ?? []
  const profiles = entries.filter((entry) => entry?.id === 'codex-cloud')
  if (profiles.length > 1) return true
  const profile = profiles[0]
  return profile?.gates !== false && profile?.budget !== 0
}
