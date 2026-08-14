#!/usr/bin/env node
// label-registry-labels.mjs — render the GitHub label set from the machine-
// readable label taxonomy (label-registry.json). This is the SINGLE source of
// the `name|hex-color|description` lines that setup-github-labels.sh provisions
// and status.sh reads its expected-label inventory from, so the script, the
// status board, and the manifest cannot fork.
//
// Usage: node label-registry-labels.mjs <mode> [registry-path] [agent-registry-path]
//   mode = provision | foreman | all
//     provision — every provisionable label EXCEPT the arming (foreman:*) axis
//     foreman   — the arming axis only; opt-in because those labels are inputs
//                 to a supervisor that most repos do not run
//     all       — provision followed by foreman (the full inventory)
//   registry defaults to ../label-registry.json relative to this file;
//   agent-registry defaults to ../agent-registry.json.
//
// What is deliberately NOT emitted: any value the manifest marks `tool-owned`
// (its owning tool creates it on demand — provisioning it would race the tool)
// or `github-default` (GitHub seeds it; restating its color/description here
// would fight the platform). Both are documented in the manifest and never
// provisioned, never deleted.
//
// Families whose values come from agent-registry.json (`suggest:*`, `claim:*`,
// and the `foreman:<adapter>` selectors) are composed by SPAWNING
// agent-registry-labels.mjs and keeping the lines that match the family prefix.
// The lines pass through verbatim, so this renderer is byte-identical to the
// existing one by construction rather than by a duplicated formatting rule —
// there is no second place for a color or a description template to drift.
//
// Offline and fail-closed: every field is checked against GitHub's limits and
// the record transport BEFORE anything can reach `gh label create`, because
// `gh` fails on the one bad label only after the earlier ones were already
// provisioned (a partial run).

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const MODES = new Set(['provision', 'foreman', 'all'])

const mode = process.argv[2]
if (!MODES.has(mode)) {
  console.error(
    `label-registry-labels: mode must be one of ${[...MODES].join(', ')} (got ${mode ?? '<none>'})`
  )
  process.exit(2)
}

const here = path.dirname(fileURLToPath(import.meta.url))
const registryPath = path.resolve(process.argv[3] ?? path.join(here, '..', 'label-registry.json'))
const agentRegistryPath = path.resolve(
  process.argv[4] ?? path.join(here, '..', 'agent-registry.json')
)
const agentRegistryHelper = path.join(here, 'agent-registry-labels.mjs')
const validator = path.join(here, 'validate-label-registry.mjs')
// The manifest's schema travels with the manifest, so a fixture copy validates
// against its own schema rather than the repo's.
const schemaPath = path.join(path.dirname(registryPath), 'label-registry.schema.json')

const die = (message) => {
  console.error(`label-registry-labels: ${message}`)
  process.exit(1)
}

// VALIDATE BEFORE RENDERING. `task verify` runs the validator, but `task verify`
// is not in the path of the person this protects: the documented way to extend
// the taxonomy is to hand-edit label-registry.json and then run
// `task setup:github-labels` (docs/CHECKLIST.md) or `task status`. Rendering an
// unvalidated manifest fails OPEN — an edit that drops a family's `values`
// renders a SHORTER set, provisioning then reports success, and status reports
// the repo fully seeded from the same reduced output. The labels are simply
// gone, with nothing on either side saying so. So the renderer refuses instead,
// and both consumers inherit the refusal: provisioning aborts before touching
// GitHub, and status reports `unknown` rather than a count it cannot trust.
if (!fs.existsSync(validator)) {
  die(
    `${validator} is missing, so the manifest cannot be validated — refusing to render a ` +
      `label set that nothing has checked`
  )
}
const validation = spawnSync(process.execPath, [validator, registryPath, schemaPath], {
  encoding: 'utf8'
})
if (validation.error) {
  die(`cannot run ${validator}: ${validation.error.message}`)
}
if (validation.status !== 0) {
  // The validator names every offender on stderr; pass that through unchanged
  // rather than summarizing it. Its stdout is its success line and is dropped.
  process.stderr.write(validation.stderr ?? '')
  die(
    `${registryPath} is not valid — refusing to render labels from it, because a reduced set ` +
      `would look like a complete one to both setup-github-labels.sh and status.sh`
  )
}

let registry
try {
  registry = JSON.parse(fs.readFileSync(registryPath, 'utf8'))
} catch (error) {
  die(`cannot read valid JSON from ${registryPath}: ${error.message}`)
}

// GitHub caps label NAMES at 50 characters and DESCRIPTIONS at 100. Lengths are
// counted in code points so an emoji counts once, matching GitHub's own report.
const GH_LABEL_NAME_MAX = 50
const GH_LABEL_DESC_MAX = 100
const COLOR_PATTERN = /^[0-9A-F]{6}$/

const codePointLength = (value) => {
  let length = 0
  for (const _ of value) length += 1
  return length
}

// Output is one `name|color|desc` RECORD per line, consumed by a line-and-pipe
// splitting shell loop. A name or description carrying a newline or a `|` would
// split into extra/garbled records — "sec\nrogue|FFFFFF|x" would inject a whole
// label — so fail closed on any field that could break the transport rather
// than emitting a smuggled record.
// NUL is in the set for a different reason than the others: bash STRIPS it from
// a command substitution silently, so a description carrying one would reach
// `gh label create` shortened rather than failing closed — the one case where
// the transport mutates the record instead of splitting it.
const TRANSPORT_HOSTILE = /[\n\r|\u0000]/
const field = (value, where) => {
  if (typeof value !== 'string') die(`${where} is not a string (${JSON.stringify(value)})`)
  if (TRANSPORT_HOSTILE.test(value)) {
    die(
      `${where} contains a newline, a '|', or a NUL (${JSON.stringify(value)}); it would ` +
        `corrupt or silently truncate the label record stream — fix ${path.basename(registryPath)}`
    )
  }
  return value
}

const record = (name, color, description, where) => {
  field(name, `${where} name`)
  field(description, `${where} description`)
  // GitHub allows whitespace in a label name; the consumers of this stream do
  // not. status.sh word-splits the rendered inventory to count what a repo is
  // missing, so `foo bar` would be read as two labels, neither of which exists.
  // The only spaced names in the taxonomy are tool-owned (release-please's
  // `autorelease: pending`), and those are documented, never rendered.
  if (/\s/.test(name)) {
    die(
      `${where} renders '${name}', which contains whitespace — the rendered inventory is ` +
        `word-split by its consumers, so a spaced name would be counted as two labels that ` +
        `do not exist. Mark it tool-owned if another tool creates it.`
    )
  }
  if (codePointLength(name) > GH_LABEL_NAME_MAX) {
    die(
      `${where} renders '${name}' at ${codePointLength(name)} chars, over GitHub's ` +
        `${GH_LABEL_NAME_MAX}-char label-name limit — shorten the value or its prefix`
    )
  }
  if (codePointLength(description) > GH_LABEL_DESC_MAX) {
    die(
      `${where} description is ${codePointLength(description)} chars, over GitHub's ` +
        `${GH_LABEL_DESC_MAX}-char limit — shorten it in ${path.basename(registryPath)}`
    )
  }
  if (typeof color !== 'string' || !COLOR_PATTERN.test(color)) {
    die(
      `${where} resolves color ${JSON.stringify(color)}, which is not six uppercase hex ` +
        `digits — 'gh label create --color' would reject it`
    )
  }
  return `${name}|${color}|${description}`
}

// One spawn per agent-registry renderer mode, cached: `suggest` and `claim` are
// two families composed from the same `suggest-claim` run.
const composedCache = new Map()
const composedLines = (helperMode) => {
  if (composedCache.has(helperMode)) return composedCache.get(helperMode)

  if (!fs.existsSync(agentRegistryHelper)) {
    die(
      `${agentRegistryHelper} is missing, so the agent vocabulary cannot be composed — ` +
        `provisioning must fail closed rather than seed a partial label set`
    )
  }
  const result = spawnSync(process.execPath, [agentRegistryHelper, helperMode, agentRegistryPath], {
    encoding: 'utf8'
  })
  if (result.error) {
    die(`cannot run ${agentRegistryHelper}: ${result.error.message}`)
  }
  if (result.status !== 0) {
    const detail = (result.stderr ?? '').trim() || `exit ${result.status}`
    die(`${path.basename(agentRegistryHelper)} ${helperMode} failed: ${detail}`)
  }
  const lines = result.stdout.split('\n').filter((line) => line.length > 0)
  composedCache.set(helperMode, lines)
  return lines
}

const composeFamily = (family) => {
  const prefix = `${family.prefix}:`
  const kept = []
  for (const line of composedLines(family.registry.mode)) {
    const parts = line.split('|')
    if (parts.length !== 3) {
      die(
        `${path.basename(agentRegistryHelper)} ${family.registry.mode} emitted a line that is not ` +
          `name|color|description: ${JSON.stringify(line)}`
      )
    }
    if (!parts[0].startsWith(prefix)) continue
    // Composed lines pass through VERBATIM, which is what makes byte identity
    // with the other renderer structural rather than a duplicated template — so
    // they get checked rather than rewritten. Two things are checked.
    //
    // The transport: NUL specifically. A `|` or a newline cannot hide in a
    // composed record — an extra `|` already failed the three-part split above,
    // and a newline ended the line — but a NUL survives both and bash then
    // strips it silently on the way to `gh`.
    if (line.includes('\u0000')) {
      die(
        `${path.basename(agentRegistryHelper)} ${family.registry.mode} emitted a record ` +
          `containing a NUL: ${JSON.stringify(line)} — bash would strip it and provision a ` +
          `truncated description; fix ${path.basename(agentRegistryPath)}`
      )
    }
    // And the family COLOR. The manifest is the source of truth for the
    // taxonomy, but the composed record carries the other renderer's own
    // hard-coded color; if a maintainer re-colors this family in the manifest,
    // provisioning and status would keep the old color while every direct
    // manifest reader saw the new one. Refuse instead of silently preferring
    // one — recoloring a composed family means changing both files.
    if (family.color !== undefined && parts[1] !== family.color) {
      die(
        `family '${family.family}' declares color ${family.color} but ` +
          `${path.basename(agentRegistryHelper)} composed '${parts[0]}' with ${parts[1]} — the ` +
          `manifest and ${path.basename(agentRegistryPath)}'s renderer disagree about this ` +
          `family's color; change both or neither`
      )
    }
    kept.push(line)
  }
  if (kept.length === 0) {
    die(
      `family '${family.family}' composes from agent-registry.json with mode ` +
        `'${family.registry.mode}' but no rendered label carries the '${prefix}' prefix — ` +
        `the two manifests disagree about who owns that prefix`
    )
  }
  return kept
}

// A value this repo provisions is one that declares no other creator: no
// per-value `source`, inside a family that is not wholly tool-owned.
const provisionable = (family, value) =>
  family.source !== 'tool-owned' && !Object.hasOwn(value, 'source')

// Names the manifest documents but this repo must NEVER create: tool-owned
// values their owning tool makes on demand, and GitHub's own defaults. They are
// skipped before any record is built, which is exactly why they need recording
// here — otherwise a composed label could quietly occupy one of these names and
// `gh label create --force` would rewrite a label Foreman or GitHub owns. Built
// from the WHOLE manifest, not the selected mode, so the reservation does not
// depend on which families this run happens to walk.
const reservedNames = new Map()
for (const family of registry.families ?? []) {
  for (const value of family.values ?? []) {
    if (provisionable(family, value)) continue
    const name = family.prefix === null ? value.name : `${family.prefix}:${value.name}`
    reservedNames.set(name.toLowerCase(), { name, family: family.family })
  }
}

const familyLines = (family) => {
  const lines = []
  for (const value of family.values ?? []) {
    if (!provisionable(family, value)) continue
    const name = family.prefix === null ? value.name : `${family.prefix}:${value.name}`
    lines.push(
      record(
        name,
        value.color ?? family.color,
        value.description,
        `family '${family.family}' value '${value.name}'`
      )
    )
  }
  if (Object.hasOwn(family, 'registry')) lines.push(...composeFamily(family))
  return lines
}

// The arming axis is what `--foreman` gates: those labels are inputs to a
// supervisor, so a repo that does not run foreman must not be told it is
// missing them (status.sh applies the same split).
const isArming = (family) => family.axis === 'arming'

// `all` is exactly `provision` followed by `foreman`, in manifest order within
// each half — so the three modes cannot disagree about a label's record.
const lines = []
if (mode !== 'foreman') {
  for (const family of registry.families ?? []) {
    if (!isArming(family)) lines.push(...familyLines(family))
  }
}
if (mode !== 'provision') {
  for (const family of registry.families ?? []) {
    if (isArming(family)) lines.push(...familyLines(family))
  }
}

// One label cannot have two records: `gh label create --force` would apply
// whichever came last, so the color and description a repo ends up with would
// depend on emission order. validate-label-registry.mjs catches collisions among
// the manifest's own values, but only here are the agent-registry-COMPOSED names
// visible alongside them — an adapter slug that matched a foreman protocol value
// would collide in exactly this spot and nowhere else.
//
// Keyed CASE-INSENSITIVELY, because that is GitHub's identity for a label name:
// `Task` and `task` are one label there, so a case-only difference is a
// collision, not two labels. Keying on the exact spelling would let both records
// through, `--force` would collapse them to whichever came last, and status
// would then expect two spellings and report permanent drift.
const seenNames = new Map()
for (const line of lines) {
  const name = line.slice(0, line.indexOf('|'))
  const key = name.toLowerCase()
  const reserved = reservedNames.get(key)
  if (reserved !== undefined) {
    die(
      `label '${name}' would be provisioned, but ${path.basename(registryPath)} documents ` +
        `'${reserved.name}' in family '${reserved.family}' as one this repo never creates ` +
        `(its owning tool or GitHub does) — provisioning it with --force would rewrite a ` +
        `label somebody else owns; rename one of them`
    )
  }
  const earlier = seenNames.get(key)
  if (earlier !== undefined) {
    const detail =
      earlier.slice(0, earlier.indexOf('|')) === name
        ? ''
        : ' (the two differ only in case, which GitHub treats as one label)'
    die(
      `label '${name}' is rendered twice${detail} (${JSON.stringify(earlier)} and ` +
        `${JSON.stringify(line)}) — a value in ${path.basename(registryPath)} collides with ` +
        `one composed from ${path.basename(agentRegistryPath)}; rename one of them`
    )
  }
  seenNames.set(key, line)
}

process.stdout.write(lines.join('\n') + (lines.length ? '\n' : ''))
