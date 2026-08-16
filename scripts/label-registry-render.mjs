#!/usr/bin/env node
// label-registry-render.mjs — render GitHub label artifacts from the
// machine-readable label registry (label-registry.json). This is the SINGLE
// source of the provisioned label set and of the docs taxonomy table:
// setup-github-labels.sh provisions from `labels`, scripts/status.sh reads its
// expected-label inventory from the same mode, and the table between the
// label-taxonomy markers in docs/project-management.md is `docs-table` output —
// all gated together by test-label-registry.sh, so none of them can fork.
//
// Families with `source: "agent-registry"` do not restate the agent vocabulary:
// their records are obtained by RUNNING agent-registry-labels.mjs (the renderer
// test-registry-drift.sh already gates), then filtered to the family's prefix.
// Restating its three description templates here would be a second copy that
// could drift; spawning the one renderer keeps a single source. The family's
// manifest color is asserted against the spawned records, so the manifest
// cannot document one color while provisioning ships another.
//
// A family's `gate` names the opt-in it exists behind (foreman /
// release-please). Both modes honor it: `labels` emits a gated family only
// under the matching flag, and `docs-table` includes its rows only under the
// same flag — so a repo without the opt-in neither provisions nor documents
// the family. `--jinja` renders the docs table for the TEMPLATE twin instead:
// every family appears, with consecutive gated families wrapped in the copier
// conditional their gate maps to, so the generated document drops the same
// rows the flags would.
//
// Modes:
//   labels [--foreman] [--release-please]
//                       one `name|hex-color|description` record per
//                       provisioned label (the format setup-github-labels.sh
//                       consumes).
//   docs-table [--foreman] [--release-please] [--jinja]
//                       the complete-label-taxonomy markdown table for
//                       docs/project-management.md (between the
//                       label-taxonomy:begin/end markers).
//
// Usage: node label-registry-render.mjs <mode> [flags] [manifest-path]
// Manifest defaults to ../label-registry.json relative to this file;
// agent-registry.json is resolved from the manifest's directory.

import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const MODES = new Set(['labels', 'docs-table'])

const args = process.argv.slice(2)
const mode = args.shift()
let foreman = false
let releasePlease = false
let jinja = false
let manifestArg
for (const arg of args) {
  if (arg === '--foreman') foreman = true
  else if (arg === '--release-please') releasePlease = true
  else if (arg === '--jinja') jinja = true
  else if (manifestArg === undefined) manifestArg = arg
  else {
    console.error(`label-registry-render: unexpected argument ${arg}`)
    process.exit(2)
  }
}
if (!MODES.has(mode)) {
  console.error(
    `label-registry-render: mode must be one of ${[...MODES].join(', ')} (got ${mode ?? '<none>'})`
  )
  process.exit(2)
}
if (jinja && (mode !== 'docs-table' || foreman || releasePlease)) {
  console.error(
    'label-registry-render: --jinja is a docs-table mode that renders every family wrapped in its copier conditional — it does not combine with the profile flags'
  )
  process.exit(2)
}

const here = path.dirname(fileURLToPath(import.meta.url))
const manifestPath = path.resolve(manifestArg ?? path.join(here, '..', 'label-registry.json'))
const agentRegistryPath = path.join(path.dirname(manifestPath), 'agent-registry.json')
const agentRenderer = path.join(here, 'agent-registry-labels.mjs')

// Validate before rendering anything. This renderer is not only run by the
// test gate: `task setup:github-labels` renders and then drives sequential
// `gh label create --force` calls, so a consumer who edited the manifest and
// provisioned directly would otherwise half-apply schema-invalid metadata (a
// missing description silently clears the live one; a bad color aborts the
// loop midway). Fail closed here, before any record exists to consume.
try {
  execFileSync(process.execPath, [path.join(here, 'validate-label-registry.mjs'), manifestPath], {
    stdio: ['ignore', 'ignore', 'inherit']
  })
} catch {
  console.error(`label-registry-render: ${manifestPath} fails validation — nothing rendered`)
  process.exit(1)
}

let manifest
try {
  manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
} catch (error) {
  console.error(
    `label-registry-render: cannot read valid JSON from ${manifestPath}: ${error.message}`
  )
  process.exit(1)
}

// Same transport guard as agent-registry-labels.mjs: output is line-and-pipe
// records (labels) or markdown table cells (docs-table), and a newline or `|`
// in either would smuggle a record or split a row. Fail closed.
const field = (value, where) => {
  if (/[\n\r|]/.test(value)) {
    console.error(
      `label-registry-render: ${where} contains a newline or '|' (${JSON.stringify(value)}); ` +
        `it would corrupt the output — fix label-registry.json`
    )
    process.exit(1)
  }
  return value
}

// GitHub's hard limits, re-checked at render time even though the validator
// already enforces them: this renderer can be pointed at an unvalidated file,
// and a partial `gh label create` run is the failure both guards exist to stop.
const GH_LABEL_NAME_MAX = 50
const GH_LABEL_DESC_MAX = 100
const record = (name, color, description, where) => {
  // Code points, not UTF-16 units, so this guard and the validator's
  // maxLength agree on what "100 characters" means — a spread counts code
  // points the way the validator's iterator does.
  const nameLength = [...name].length
  const descriptionLength = [...description].length
  if (nameLength > GH_LABEL_NAME_MAX) {
    console.error(
      `label-registry-render: label '${name}' is ${nameLength} chars, over GitHub's ` +
        `${GH_LABEL_NAME_MAX}-char limit (${where})`
    )
    process.exit(1)
  }
  if (descriptionLength > GH_LABEL_DESC_MAX) {
    console.error(
      `label-registry-render: label '${name}' description is ${descriptionLength} chars, over ` +
        `GitHub's ${GH_LABEL_DESC_MAX}-char limit (${where})`
    )
    process.exit(1)
  }
  return `${field(name, where)}|${color}|${field(description, where)}`
}

// Run agent-registry-labels.mjs once per mode it feeds and keep the records.
const spawned = new Map()
function agentRecords(rendererMode) {
  if (!spawned.has(rendererMode)) {
    let out
    try {
      out = execFileSync(process.execPath, [agentRenderer, rendererMode, agentRegistryPath], {
        encoding: 'utf8'
      })
    } catch (error) {
      const detail = error.stderr ? `\n${error.stderr}` : ` (${error.message})`
      console.error(
        `label-registry-render: agent-registry-labels.mjs ${rendererMode} failed — the agent ` +
          `vocabulary cannot be rendered${detail}`
      )
      process.exit(1)
    }
    spawned.set(
      rendererMode,
      out.split('\n').filter((line) => line.length > 0)
    )
  }
  return spawned.get(rendererMode)
}

function registryFamilyRecords(family) {
  const rendererMode =
    family.registry_set === 'foreman-adapters' ? 'foreman-adapters' : 'suggest-claim'
  const lines = agentRecords(rendererMode).filter((line) => line.startsWith(`${family.prefix}:`))
  for (const line of lines) {
    const color = line.split('|')[1]
    if (family.color && color !== family.color) {
      console.error(
        `label-registry-render: family ${family.family} documents color ${family.color} but ` +
          `agent-registry-labels.mjs renders ${color} (${line.split('|')[0]}) — reconcile the two`
      )
      process.exit(1)
    }
  }
  return lines
}

const gateOpen = (family) =>
  family.gate === undefined ||
  (family.gate === 'foreman' && foreman) ||
  (family.gate === 'release-please' && releasePlease)

const provisioned = (family) =>
  family.provision === true && family.retired !== true && gateOpen(family)

const lines = []

if (mode === 'labels') {
  for (const family of manifest.families ?? []) {
    if (!provisioned(family)) continue
    if (family.source === 'agent-registry') {
      lines.push(...registryFamilyRecords(family))
      continue
    }
    for (const value of family.values ?? []) {
      if (value.retired === true || value.provision === false) continue
      const name = family.prefix === null ? value.value : `${family.prefix}:${value.value}`
      lines.push(
        record(
          name,
          value.color ?? family.color,
          value.description ?? '',
          `family ${family.family}`
        )
      )
    }
  }
  // The validator's uniqueness check sees only inline values — it cannot know
  // what the agent registry renders. This is the one place both sources meet,
  // and the consumer is a sequential `gh label create --force` loop, where a
  // duplicate silently overwrites the first record's metadata. Fail closed.
  const seen = new Set()
  for (const line of lines) {
    const name = line.split('|')[0]
    if (seen.has(name)) {
      console.error(
        `label-registry-render: label '${name}' is rendered twice — an inline value collides ` +
          `with another family (or with an agent-registry-rendered label); fix label-registry.json`
      )
      process.exit(1)
    }
    seen.add(name)
  }
}

if (mode === 'docs-table') {
  const cell = (value, where) => field(value, where)
  const code = (value) => '`' + value + '`'

  const WRITER_TEXT = {
    human: 'humans',
    'trusted-human': 'a trusted human',
    agent: 'agents'
  }
  const LIFECYCLE_TEXT = {
    durable: 'durable',
    transient: 'transient — removed as soon as the state clears',
    'claim-release': 'added at claim, removed at release',
    'tool-managed': 'applied and removed by the owning tool'
  }

  // Per-value SEMANTIC overrides outrank family prose: a value that overrides
  // `writers` without restating a writer_note must render its own writers, not
  // the family's note — the note is a fallback for the field it describes,
  // never for a field the value overrode. Same for lifecycle, and trust must
  // see a per-value provision off-switch.
  const writersText = (writers) =>
    writers
      .map((writer) => WRITER_TEXT[writer] ?? writer.replace(/^tool:/, '') + ' (tool)')
      .join(' or ')
  const writerCell = (family, value) =>
    value?.writer_note ??
    (value?.writers
      ? writersText(value.writers)
      : (family.writer_note ?? writersText(family.writers)))
  const readerCell = (family, value) => value?.readers ?? family.readers
  const trustCell = (family, value) =>
    value?.trust_note ??
    (value?.provision === false || value?.retired === true
      ? 'not provisioned'
      : (family.trust_note ??
        (family.provision
          ? 'provisioned; inert'
          : family.source === 'tool-owned'
            ? '**tool-owned, created on demand**'
            : 'not provisioned')))
  const lifecycleCell = (family, value) =>
    value?.lifecycle_note ??
    (value?.lifecycle
      ? LIFECYCLE_TEXT[value.lifecycle]
      : (family.lifecycle_note ?? LIFECYCLE_TEXT[family.lifecycle]))

  const composedName = (family, raw) => (family.prefix === null ? raw : `${family.prefix}:${raw}`)
  // A value renders as its own row when it overrides anything a row SHOWS
  // (writer, reader, trust, lifecycle) — color and description are label
  // metadata, not table columns, so they never split a family row.
  const splits = (value) =>
    [
      'writers',
      'writer_note',
      'readers',
      'trust_note',
      'lifecycle',
      'lifecycle_note',
      'arming',
      'provision',
      'retired'
    ].some((key) => Object.hasOwn(value, key))

  const row = (label, family, value) =>
    `| ${label} | ${cell(writerCell(family, value), `family ${family.family} writer`)} | ` +
    `${cell(readerCell(family, value), `family ${family.family} reader`)} | ` +
    `${cell(trustCell(family, value), `family ${family.family} trust`)} | ` +
    `${cell(lifecycleCell(family, value), `family ${family.family} lifecycle`)} |`

  lines.push(
    '<!-- Generated from label-registry.json by `node scripts/label-registry-render.mjs docs-table`. Do not edit by hand — `task test:label-registry` fails on drift. -->',
    '',
    '| Label / family | Writer | Reader | Trust class | Lifecycle |',
    '|---|---|---|---|---|'
  )

  // In --jinja output, consecutive families behind the same gate share one
  // copier conditional, so the template twin drops exactly the rows the
  // profile flags would exclude. copier's block trimming removes the
  // conditional lines themselves, keeping the rendered table contiguous.
  const GATE_ANSWER = {
    foreman: 'use_foreman',
    'release-please': 'use_release_please'
  }
  let openGate = null
  const setGate = (gate) => {
    const next = gate ?? null
    if (next === openGate) return
    if (openGate !== null) lines.push('[% endif %]')
    if (next !== null) lines.push(`[% if ${GATE_ANSWER[next]} %]`)
    openGate = next
  }

  for (const family of manifest.families ?? []) {
    if (jinja) setGate(family.gate)
    else if (!gateOpen(family)) continue
    const retiredSuffix = family.retired === true ? ' (**retired**)' : ''

    if (family.source === 'agent-registry' || (family.values.length === 0 && family.open_values)) {
      const label =
        code(
          cell(composedName(family, family.placeholder), `family ${family.family} placeholder`)
        ) + retiredSuffix
      lines.push(row(label, family, undefined))
      continue
    }

    // Emit grouped and per-value rows in value order: overriding values get
    // their own row; a contiguous run of plain values collapses into one.
    let run = []
    const flush = () => {
      if (run.length === 0) return
      const label =
        family.prefix === null
          ? run.map((value) => code(cell(value.value, `family ${family.family} value`))).join(', ')
          : code(
              run.length === 1
                ? composedName(family, run[0].value)
                : `${family.prefix}:{${run.map((value) => cell(value.value, `family ${family.family} value`)).join(',')}}`
            )
      lines.push(row(label + retiredSuffix, family, undefined))
      run = []
    }
    for (const value of family.values) {
      if (splits(value)) {
        flush()
        const label =
          code(cell(composedName(family, value.value), `family ${family.family} value`)) +
          (value.retired === true ? ' (**retired**)' : retiredSuffix)
        lines.push(row(label, family, value))
      } else {
        run.push(value)
      }
    }
    flush()
    if (family.open_values && family.values.length > 0) {
      lines.push(
        row(
          code(
            cell(composedName(family, family.placeholder), `family ${family.family} placeholder`)
          ) + retiredSuffix,
          family,
          undefined
        )
      )
    }
  }
  if (jinja) setGate(undefined)
}

process.stdout.write(lines.join('\n') + (lines.length ? '\n' : ''))
