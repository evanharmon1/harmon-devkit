// Build the complete brief render contract from a validated plan and bounded
// dispatch facts. No copied brief, policy override, fence override or overlap
// prose is accepted as an input.
import { readFileSync } from 'node:fs'
import { Refusal, requireId } from '../../dev-flow-support/assets/run-record.mjs'
import { pathMatches, effectiveFence, mayOverlap } from '../../dev-flow-support/assets/plan-revise.mjs'

export { effectiveFence } from '../../dev-flow-support/assets/plan-revise.mjs'

const FACT_TEXT = ['worktree_path', 'harness', 'harness_text', 'effort', 'codex_model_id', 'codex_launch_flags',
  'scratch_dir', 'repo_tier', 'gate_bounds_override', 'gate_commands', 'git_sandbox_note',
  'known_environmental_failure', 'unit_kind', 'pr_title', 'verified_facts_and_rulings']

export function validateFacts(facts) {
  if (!facts || typeof facts !== 'object' || Array.isArray(facts)) throw new Refusal('facts must be an object')
  const allowed = new Set([...FACT_TEXT, 'claim_handoff', 'fence_notes'])
  for (const key of Object.keys(facts)) if (!allowed.has(key)) throw new Refusal(`unknown facts field ${key}`)
  for (const key of FACT_TEXT) {
    if (typeof facts[key] !== 'string' || !facts[key].trim()) throw new Refusal(`facts.${key} must be nonempty text`)
  }
  if (!['light', 'standard', 'heavy'].includes(facts.repo_tier)) throw new Refusal('facts.repo_tier must be light, standard or heavy')
  if (!['implementation', 'proposal-only'].includes(facts.unit_kind)) throw new Refusal('invalid facts.unit_kind')
  if (facts.fence_notes !== undefined) {
    if (!facts.fence_notes || typeof facts.fence_notes !== 'object' || Array.isArray(facts.fence_notes)) {
      throw new Refusal('facts.fence_notes must map shared paths to per-lane section notes')
    }
    for (const [path, notes] of Object.entries(facts.fence_notes)) {
      if (!path.trim() || !notes || typeof notes !== 'object' || Array.isArray(notes) ||
          Object.values(notes).some((note) => typeof note !== 'string' || !note.trim() || /[\r\n]/.test(note))) {
        throw new Refusal('facts.fence_notes must contain nonempty single-line per-lane section notes')
      }
    }
  }
}

export function assertDisjointFences(plan, lane) {
  const live = new Set(plan.issues.filter((issue) => issue.verdict !== 'done').map((issue) => issue.number))
  for (const other of plan.lanes.filter((entry) => entry.lane !== lane.lane && live.has(entry.issue))) {
    for (const left of effectiveFence(lane)) for (const right of effectiveFence(other)) {
      if (mayOverlap(left.path, right.path)) {
        const recorded = plan.overlaps.find((entry) =>
          [entry.issue_a, entry.issue_b].includes(lane.issue) &&
          [entry.issue_a, entry.issue_b].includes(other.issue) &&
          ['serialize', 'split'].includes(entry.resolution) &&
          entry.paths.some((path) =>
            (left.path === right.path && path === left.path) ||
            (!/[*?]/.test(left.path) && pathMatches(left.path, path)) ||
            (!/[*?]/.test(right.path) && pathMatches(right.path, path))))
        if (!recorded) throw new Refusal(`effective fence overlaps live lane ${other.lane}: ${left.path} / ${right.path}; no plan-recorded overlap covers this path`)
      }
    }
  }
}

export function buildBriefValues({ plan, lane, facts, nonce, at, generation, active, runDir, defaultBranch }) {
  validateFacts(facts)
  requireId('lane', lane.lane)
  requireId('nonce', nonce)
  const profile = plan.lane_profiles?.find((entry) => entry.lane === lane.lane)?.policy ?? plan.policy
  const issue = plan.issues.find((entry) => entry.number === lane.issue)
  const overlaps = plan.lanes.filter((entry) => entry.lane !== lane.lane &&
    plan.issues.find((item) => item.number === entry.issue)?.verdict !== 'done').map((other) => {
    const overlap = plan.overlaps.find((entry) => [entry.issue_a, entry.issue_b].includes(lane.issue) &&
      [entry.issue_a, entry.issue_b].includes(other.issue))
    const detail = overlap
      ? `shares ${overlap.paths.map((path) => {
        const notes = facts.fence_notes?.[path]
        if (![lane.lane, other.lane].every((name) => typeof notes?.[name] === 'string' && notes[name].trim())) {
          throw new Refusal(`missing section notes for shared path ${path}: facts.fence_notes must name ${lane.lane} and ${other.lane}`)
        }
        return `\`${path}\` (${lane.lane}: ${notes[lane.lane]}; ${other.lane}: ${notes[other.lane]})`
      }).join(', ')} — resolution ${overlap.resolution}; #${overlap.merge_dependency.before} merges before #${overlap.merge_dependency.after}`
      : 'has a disjoint effective fence'
    return `lane \`${other.lane}\` (#${other.issue}, branch \`${other.branch}\`, wave ${other.wave}) ${detail}.`
  })
  const report = `${runDir}/lane-report-${nonce}.md`
  const fence = effectiveFence(lane).map((entry) => {
    const note = facts.fence_notes?.[entry.path]?.[lane.lane]
    return note ? { ...entry, note: [entry.note, note].filter(Boolean).join(' — ') } : entry
  })
  const deadline = new Date(Date.parse(at) + profile.caps.wall_clock_min * 60000).toISOString().replace(/\.000Z$/, 'Z')
  const projection = `rigor ${profile.rigor} (${profile.rigor_source}); caps ${JSON.stringify(profile.caps)}; breadth ${JSON.stringify(profile.breadth)}; tiers ${JSON.stringify(profile.role_tiers)}; strategy ${profile.strategy} (${profile.strategy_source}); projection file ${runDir}/policy.json`
  const sentinels = Object.fromEntries(['ready', 'handoff', 'blocked'].map((name) => [name, `${name.toUpperCase()}-${lane.lane}`]))
  const envelope = {
    run_id: lane.run_id, branch: lane.branch, generation, active_state_path: active, record_directory: runDir,
    policy_projection: projection, default_branch: defaultBranch, base_sha: plan.base_sha,
    worktree_path: facts.worktree_path, report_path: report, harness: facts.harness, fence,
    live_lane_overlaps: overlaps, rigor: profile.rigor, rigor_source: profile.rigor_source,
    caps: profile.caps, deadline, breadth: profile.breadth, strategy: profile.strategy,
    strategy_source: profile.strategy_source, role_tiers: profile.role_tiers, operator_pins: profile.operator_pins,
    issue: { number: issue.number, title: issue.title, url: issue.url }, claim_handoff: facts.claim_handoff,
    sentinels: { ...Object.fromEntries(Object.entries(sentinels).map(([k, v]) => [k, `${v}-${nonce}`])), attempt_nonce: nonce },
  }
  const values = {
    // Escape literal opening braces inside JSON strings without changing the
    // decoded fact. The envelope's raw-wire placeholder guard remains strict.
    'brief-envelope-json': JSON.stringify(envelope).replace(/\{\{/g, '\\u007b\\u007b'), 'lane-name': lane.lane, 'run-id': lane.run_id,
    branch: lane.branch, 'default-branch': defaultBranch, 'base-sha': plan.base_sha,
    'worktree-path': facts.worktree_path, harness: facts.harness_text, effort: facts.effort,
    'codex-model-id': facts.codex_model_id, 'codex-launch-flags': facts.codex_launch_flags,
    'report-path': report, 'scratch-dir': facts.scratch_dir, 'repo-tier': facts.repo_tier,
    'gate-bounds-override': facts.gate_bounds_override, 'gate-commands': facts.gate_commands,
    generation: String(generation), 'active-state-path': active, 'record-directory': runDir,
    'policy-projection': projection,
    'file-scope-fence': fence.map((item) => `- \`${item.path}\`${item.note ? ` — ${item.note}` : ''}`).join('\n'),
    'live-lane-overlaps': overlaps.length ? `\n\n${overlaps.map((line) => `- ${line}`).join('\n')}` : 'None.',
    'issue-number': String(issue.number), 'issue-title': issue.title.replace(/`/g, "'"), 'issue-url': issue.url,
    'unit-kind': facts.unit_kind, 'claim-handoff': `\`\`\`json\n${JSON.stringify(facts.claim_handoff, null, 2)}\n\`\`\``,
    'verified-facts-and-rulings': facts.verified_facts_and_rulings,
    'git-sandbox-note': facts.git_sandbox_note, 'known-environmental-failure': facts.known_environmental_failure,
    rigor: profile.rigor, 'rigor-source': profile.rigor_source,
    ...Object.fromEntries(['challenge', 'review', 'integration', 'remediation'].map((key) => [`${key}-cap`, String(profile.caps[key])])),
    'min-rounds': String(profile.caps.min_rounds), 'wall-clock-min': String(profile.caps.wall_clock_min), deadline,
    'max-agent-runs': String(profile.breadth.max_agent_runs), 'max-parallel-agents': String(profile.breadth.max_parallel_agents),
    strategy: profile.strategy, 'strategy-source': profile.strategy_source,
    'role-tiers': Object.entries(profile.role_tiers).map(([role, tier]) => `${role} **${tier}** (source: validated plan)`).join(', '),
    'operator-pins': profile.operator_pins.length ? `\n\n${profile.operator_pins.map((pin) => `- ${pin}`).join('\n')}` : 'None.',
    'pr-title': facts.pr_title, 'attempt-nonce': nonce,
    ...Object.fromEntries(Object.entries(sentinels).map(([key, value]) => [`${key}-sentinel`, value])),
  }
  return { values, envelope }
}

export function renderBrief(templateFile, skillFile, values) {
  const template = readFileSync(templateFile, 'utf8')
  const skill = readFileSync(skillFile, 'utf8')
  const section = skill.split('## Lane briefs\n')[1]?.split('\n## ')[0] ?? ''
  const catalog = new Set([...section.matchAll(/^\| `\{\{([^}]+)\}\}` \|/gm)].map((match) => match[1]))
  const tokens = [...template.matchAll(/\{\{([^}]*)\}\}/g)]
  const names = new Set(tokens.map((match) => match[1]))
  const equal = (a, b) => a.size === b.size && [...a].every((key) => b.has(key))
  if (!equal(names, catalog) || !equal(names, new Set(Object.keys(values)))) {
    throw new Refusal('template, source catalog and brief values placeholder sets differ')
  }
  // Values that contain a token remain literal; never scan inserted values.
  return template.replace(/\{\{([^}]*)\}\}/g, (_, key) => values[key])
}
