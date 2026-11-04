#!/usr/bin/env bash
# Enforce the update runbook's budget, ordered gates and step-reference links.
set -euo pipefail
node --input-type=module - "$(dirname "$0")/.." <<'JS'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

const skill = path.resolve(process.argv[2])
const budget = 250
const steps = ['basics', 'preflight', 'execution', 'conflicts', 'verification', 'handoff', 'github']
const headings = [
  '0. Branch from a clean tree',
  '1. Verify and freeze both template inputs',
  '2. Run the update',
  '3. Reconcile conflicts (in place — no special files)',
  '4. Verify comprehensively',
  '5. Hand off',
  '6. Reconcile live GitHub metadata (`project_management: github`) — post-merge'
]
const slug = heading => heading.toLowerCase().replace(/[`]/g, '').replace(/[^\p{L}\p{N}_\-\s]/gu, '').replace(/ /g, '-')

// Only actual headings count: shell comments and the sample PR body are fenced.
function anchors(markdown) {
  let fence
  const found = new Set()
  const counts = new Map()
  for (const line of markdown.split('\n')) {
    const marker = line.match(/^\s*(`{3,}|~{3,})/)
    if (marker) {
      if (!fence) fence = marker[1]
      else if (marker[1][0] === fence[0] && marker[1].length >= fence.length) fence = undefined
      continue
    }
    if (fence) continue
    const match = line.match(/^#{1,6} (.+)$/)
    if (!match) continue
    const base = slug(match[1])
    const count = counts.get(base) ?? 0
    found.add(count ? `${base}-${count}` : base)
    counts.set(base, count + 1)
  }
  return found
}

function validate(directory) {
  const refs = path.join(directory, 'references')
  const runbook = fs.readFileSync(path.join(refs, 'mode-update.md'), 'utf8')
  const lines = runbook.split('\n')
  if (lines.at(-1) === '') lines.pop()
  assert.ok(lines.length <= budget, `runbook exceeds ${budget}-line budget: ${lines.length}`)
  assert.ok(runbook.includes(`**${budget}-line budget**`), 'budget must be stated in runbook')
  const ordered = lines.filter(line => /^## [0-6]\. /.test(line)).map(line => line.slice(3))
  assert.deepEqual(ordered, headings, 'steps 0–6 must appear once, in order')
  assert.equal(lines.filter(line => line.startsWith('**Stop:** ')).length, 10, 'every gate needs a stop condition')
  const gates = lines.filter(line => line.startsWith('**Gate:** '))
  assert.equal(gates.length, 10, 'all ten update gates must remain explicit')
  const targets = new Set()
  for (const gate of gates) {
    const links = [...gate.matchAll(/\[([^\]]+)\]\(\.\/(mode-update-[a-z]+\.md)#([^\s)]+)\)/g)]
    assert.ok(links.length, `gate needs a step-reference anchor: ${gate}`)
    for (const [, , file, anchor] of links) {
      assert.ok(steps.some(step => file === `mode-update-${step}.md`), `unexpected gate reference: ${file}`)
      const text = fs.readFileSync(path.join(refs, file), 'utf8')
      assert.ok(anchors(text).has(anchor), `unresolved gate: ${file}#${anchor}`)
      targets.add(file)
    }
  }
  assert.deepEqual([...targets].sort(), steps.map(step => `mode-update-${step}.md`).sort(), 'gates must cover all seven references')
  // Check every step-local link, including navigation that is not a gate line.
  for (const [, file, anchor] of runbook.matchAll(/\]\(\.\/(mode-update-[a-z]+\.md)(?:#([^\s)]+))?\)/g)) {
    const text = fs.readFileSync(path.join(refs, file), 'utf8')
    if (anchor) assert.ok(anchors(text).has(anchor), `unresolved step link: ${file}#${anchor}`)
  }
  headings.forEach((heading, index) => {
    assert.ok(anchors(runbook).has(slug(heading)), `missing compatibility anchor: ${heading}`)
    const text = fs.readFileSync(path.join(refs, `mode-update-${steps[index]}.md`), 'utf8')
    assert.ok(anchors(text).has(slug(heading)), `missing detailed step: ${heading}`)
    assert.ok(text.includes('[Update runbook](./mode-update.md)'), 'references must link back to runbook')
  })
  const routing = fs.readFileSync(path.join(directory, 'SKILL.md'), 'utf8')
  assert.match(routing, /read the short \[update runbook\]\(references\/mode-update\.md\) first/,
    'SKILL.md must route update mode to the runbook first')
  return lines.length
}

console.log(`update runbook: ${validate(skill)}/${budget} lines; all ten gates resolve`)

// Reject real fixture damage, so an accidentally weakened checker cannot pass.
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'mode-update-runbook-'))
try {
  fs.mkdirSync(path.join(fixture, 'references'))
  fs.copyFileSync(path.join(skill, 'SKILL.md'), path.join(fixture, 'SKILL.md'))
  for (const name of ['mode-update.md', ...steps.map(step => `mode-update-${step}.md`)]) {
    fs.copyFileSync(path.join(skill, 'references', name), path.join(fixture, 'references', name))
  }
  const runbookPath = path.join(fixture, 'references', 'mode-update.md')
  const original = fs.readFileSync(runbookPath, 'utf8')
  const reject = (name, mutate, pattern) => {
    fs.writeFileSync(runbookPath, original)
    mutate()
    assert.throws(() => validate(fixture), pattern, name)
    console.log(`  rejects ${name}`)
  }
  reject('over-budget runbook', () => fs.appendFileSync(runbookPath, '\nextra'.repeat(budget)), /line budget/)
  reject('blank lines over budget', () => fs.appendFileSync(runbookPath, '\n'.repeat(budget)), /line budget/)
  reject('missing gate', () => fs.writeFileSync(runbookPath, original.replace(/^\*\*Gate:\*\* .*\n/m, '')), /ten update gates/)
  reject('broken gate anchor', () => fs.writeFileSync(runbookPath, original.replace('#0-branch-from-a-clean-tree', '#missing-gate')), /unresolved gate/)
  reject('missing reference', () => fs.unlinkSync(path.join(fixture, 'references', 'mode-update-basics.md')), /ENOENT/)
  fs.copyFileSync(path.join(skill, 'references', 'mode-update-basics.md'), path.join(fixture, 'references', 'mode-update-basics.md'))
  reject('reordered steps', () => fs.writeFileSync(runbookPath, original.replace('## 0. Branch', '## 1. Branch')), /steps 0–6/)
  reject('missing stop condition', () => fs.writeFileSync(runbookPath, original.replace(/^\*\*Stop:\*\* .*\n/m, '')), /stop condition/)
  reject('missing detailed heading', () => {
    const file = path.join(fixture, 'references', 'mode-update-basics.md')
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('## 0. Branch', 'Branch'))
  }, /unresolved gate/)
  fs.copyFileSync(path.join(skill, 'references', 'mode-update-basics.md'), path.join(fixture, 'references', 'mode-update-basics.md'))
  reject('routing bypasses runbook', () => {
    const file = path.join(fixture, 'SKILL.md')
    fs.writeFileSync(file, fs.readFileSync(file, 'utf8').replace('update runbook', 'entire procedure'))
  }, /route update mode/)
} finally {
  fs.rmSync(fixture, { recursive: true, force: true })
}
JS
