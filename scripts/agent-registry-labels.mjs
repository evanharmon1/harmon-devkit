#!/usr/bin/env node
// agent-registry-labels.mjs — render the agent-vocabulary GitHub labels from the
// machine-readable agent registry (agent-registry.json). This is the SINGLE
// source of the `suggest:*`, `claim:*`, and `foreman:<adapter>` label lines:
// setup-github-labels.sh provisions them and test-registry-drift.sh checks them,
// both by calling this file, so the two can never disagree.
//
// Output: one `name|hex-color|description` line per label (the format
// setup-github-labels.sh consumes). Only FAMILY-LEVEL suggest/claim labels are
// emitted — model-level `suggest:<family>:<model>` / `claim:<family>:<model>`
// are created on demand, never seeded (an unbounded roster otherwise). Foreman
// adapter selectors are emitted only for adapters the registry marks
// `provision_label` (a selector without a production adapter can strand armed
// work — ADR 0005 D11), so `mock` never yields a `foreman:mock` label.
//
// Usage: node agent-registry-labels.mjs <mode> [registry-path]
//   mode = suggest-claim | foreman-adapters | all
// Registry defaults to ../agent-registry.json relative to this file.

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

// Colors mirror setup-github-labels.sh's family grouping: claim inherits the
// retired agent:* teal (it answers the same "who is working this" question);
// suggest is a softer advisory blue; foreman selectors share the arming blue.
const COLOR_SUGGEST = 'BFD4F2'
const COLOR_CLAIM = '006B75'
const COLOR_FOREMAN = '1D76DB'

const MODES = new Set(['suggest-claim', 'foreman-adapters', 'all'])

const mode = process.argv[2]
if (!MODES.has(mode)) {
  console.error(
    `agent-registry-labels: mode must be one of ${[...MODES].join(', ')} (got ${mode ?? '<none>'})`
  )
  process.exit(2)
}

const here = path.dirname(fileURLToPath(import.meta.url))
const registryPath = path.resolve(process.argv[3] ?? path.join(here, '..', 'agent-registry.json'))

let registry
try {
  registry = JSON.parse(fs.readFileSync(registryPath, 'utf8'))
} catch (error) {
  console.error(
    `agent-registry-labels: cannot read valid JSON from ${registryPath}: ${error.message}`
  )
  process.exit(1)
}

// Output is one `name|color|desc` label RECORD per line, consumed by a
// line-and-pipe-splitting shell loop. A slug or display_name carrying a newline
// or a `|` would split into extra/garbled records — a schema-valid display_name
// like "Claude\nrogue|FFFFFF|x" would inject a whole label. The slug pattern
// already forbids both, but display_name is a free string, so fail closed on any
// field that could break the transport rather than emitting a smuggled record.
const field = (value, where) => {
  if (/[\n\r|]/.test(value)) {
    console.error(
      `agent-registry-labels: ${where} contains a newline or '|' (${JSON.stringify(value)}); ` +
        `it would corrupt the label record stream — fix agent-registry.json`
    )
    process.exit(1)
  }
  return value
}

// GitHub caps label NAMES at 50 and DESCRIPTIONS at 100 characters. A schema-
// valid slug/display_name can render a longer name or description, and
// `gh label create` then fails ONLY on that label — after earlier ones were
// already provisioned (a partial run). Fail closed on BOTH limits here so the
// whole set is rejected before any of it reaches GitHub.
const GH_LABEL_NAME_MAX = 50
const GH_LABEL_DESC_MAX = 100
const labelName = (prefix, slug) => {
  const name = `${prefix}:${slug}`
  if (name.length > GH_LABEL_NAME_MAX) {
    console.error(
      `agent-registry-labels: label '${name}' is ${name.length} chars, over GitHub's ` +
        `${GH_LABEL_NAME_MAX}-char limit — shorten the slug in agent-registry.json`
    )
    process.exit(1)
  }
  return name
}
const record = (name, color, description) => {
  if (description.length > GH_LABEL_DESC_MAX) {
    console.error(
      `agent-registry-labels: label '${name}' description is ${description.length} chars, over ` +
        `GitHub's ${GH_LABEL_DESC_MAX}-char limit — shorten the display_name in agent-registry.json`
    )
    process.exit(1)
  }
  return `${name}|${color}|${description}`
}

const lines = []

if (mode === 'suggest-claim' || mode === 'all') {
  for (const family of registry.families ?? []) {
    const slug = field(family.slug, `family slug`)
    const name = field(family.display_name, `family '${slug}' display_name`)
    lines.push(
      record(
        labelName('suggest', slug),
        COLOR_SUGGEST,
        `Suggested for the ${name} family (advisory)`
      )
    )
    lines.push(record(labelName('claim', slug), COLOR_CLAIM, `Claimed by ${name}`))
  }
}

if (mode === 'foreman-adapters' || mode === 'all') {
  for (const adapter of registry.foreman_adapters ?? []) {
    if (adapter.provision_label !== true) continue
    const slug = field(adapter.slug, `foreman adapter slug`)
    const name = field(adapter.display_name, `foreman adapter '${slug}' display_name`)
    lines.push(
      record(
        labelName('foreman', slug),
        COLOR_FOREMAN,
        `Arm this issue for foreman dispatch with the ${name} backend`
      )
    )
  }
}

process.stdout.write(lines.join('\n') + (lines.length ? '\n' : ''))
