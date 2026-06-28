#!/usr/bin/env node
// Parse a gitleaks JSON report and emit a secrets-scan summary.
//
// Usage: node scripts/summarize-gitleaks.mjs <report.json>
//
// gitleaks writes a JSON array of findings (or no file at all when nothing
// is found, depending on version). Treat both as "no findings".
//
// - Always prints a one-line human summary to stdout.
// - When $GITHUB_STEP_SUMMARY is set, also appends a markdown card.
// - Never throws — summary failures must not break CI.

import { readFileSync, appendFileSync, existsSync } from 'node:fs'
import { argv, env, exit } from 'node:process'

const file = argv[2]
if (!file) {
  console.error('usage: summarize-gitleaks.mjs <report.json>')
  exit(2)
}

let findings = []
if (existsSync(file)) {
  try {
    const raw = readFileSync(file, 'utf8').trim()
    findings = raw ? JSON.parse(raw) : []
    if (!Array.isArray(findings)) findings = []
  } catch (e) {
    console.error(`summarize-gitleaks: failed to parse ${file}: ${e.message}`)
    exit(0)
  }
}

const status = findings.length === 0 ? 'PASS' : 'FAIL'
console.log(`Secrets: ${status} — ${findings.length} finding(s)`)

const summaryPath = env.GITHUB_STEP_SUMMARY
if (!summaryPath) exit(0)

let md = '### Secrets Scan (gitleaks)\n\n'
md += `**${status}** — ${findings.length} finding(s)\n\n`

if (findings.length > 0) {
  md += '| Rule | File | Line | Commit |\n'
  md += '|---|---|---|---|\n'
  for (const f of findings.slice(0, 20)) {
    const rule = f.RuleID || f.ruleID || '?'
    const fp = f.File || f.file || '?'
    const line = f.StartLine || f.startLine || '?'
    const commit = (f.Commit || f.commit || '').slice(0, 7) || '?'
    md += `| \`${rule}\` | \`${fp}\` | ${line} | \`${commit}\` |\n`
  }
  if (findings.length > 20) {
    md += `\n_(showing first 20 of ${findings.length})_\n`
  }
  md += '\n'
}

try {
  appendFileSync(summaryPath, md)
} catch (e) {
  console.error(`summarize-gitleaks: cannot append to summary: ${e.message}`)
}
