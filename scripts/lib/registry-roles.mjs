// registry-roles.mjs — pure, side-effect-free helpers over agent-registry.json's
// roles[] vocabulary. Extracted from scripts/validate-agent-registry.mjs (a
// top-level-executing CLI script, not an importable module: it reads argv and
// calls process.exit as soon as it loads) so this logic can be imported for a
// direct function-level test without also re-running the whole CLI's argv
// parsing and registry read as a side effect.
//
// TIER_ORDER is the shared model-stratum ladder (specs/dev-flow-v2.md, #635):
// local < economy < standard < frontier < apex. 'adaptive' is deliberately
// excluded — it is a .devflow.toml resolution INPUT (never a concrete tier to
// resolve TO), the same reasoning result.envelope.schema.json's producer.tier
// enum already excludes it for an executed fact.
export const TIER_ORDER = ['local', 'economy', 'standard', 'frontier', 'apex']

const ROLE_TIER_LABEL = /^tier:([a-z0-9-]+):([a-z0-9-]+)$/

// resolveRoleTierLabel LABEL REGISTRY — parses a `tier:<role>:<tier>`
// execution-control label (AGENTS.md's "tier:orchestrator:* / tier:implementer:*
// / tier:reviewer:*" family) and resolves both segments against the registry's
// own vocabulary: <role> against registry.roles[].slug, <tier> against
// TIER_ORDER. This implements ONLY specs/dev-flow-v2.md's registry delta
// spec Requirement "Labels resolve role names through the registry" (an
// unknown role or tier is rejected rather than silently accepted or guessed
// at) — a pure VOCABULARY lookup with no session, no actor, and no clock.
//
// It deliberately does NOT implement the spec's separate Requirement
// "Execution-control labels require attributable provenance" (interactive
// operator confirmation for an off-default resolution; an unattended
// consumer re-reading its trusted-actor configuration immediately before
// acting) — that requirement is about WHO is invoking the orchestrator and
// HOW that gets authenticated, which has no registry or vocabulary
// component and cannot be answered by a `(label, registry) => result`
// function with no session context to interrogate. `ok: true` here means
// "this label names a real role and tier," never "this label is authorized
// to act on." The provenance requirement belongs to `/orchestrator` (#638),
// the actual session-runtime consumer of a resolved label.
export function resolveRoleTierLabel(label, registry) {
  const match = ROLE_TIER_LABEL.exec(label)
  if (!match) return { ok: false, error: `not a tier:<role>:<tier> label: ${label}` }
  const [, role, tier] = match
  if (!(registry.roles ?? []).some((entry) => entry.slug === role)) {
    return { ok: false, error: `unknown role: ${role}` }
  }
  if (!TIER_ORDER.includes(tier)) {
    return { ok: false, error: `unknown tier: ${tier}` }
  }
  return { ok: true, role, tier }
}
