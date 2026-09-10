#!/usr/bin/env node
// Materialize and inspect harness-local projections of portable role agents.
//
// The portable ai/agents sources deliberately carry no harness-specific tool
// policy. A projection adds the policy only to a local copy. Verification is
// deliberately byte-exact: a registry capability boolean or an instruction in
// the prompt is not a harness tool restriction. This helper prepares and
// validates configuration; it does not authorize a dispatch.

import { execFileSync } from 'node:child_process'
import {
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync
} from 'node:fs'
import { basename, dirname, join, resolve } from 'node:path'
import { tmpdir } from 'node:os'

const REFUSED = 20
const SUPPORTED_HARNESS = 'claude-code'
const PROFILES = new Map([
  ['challenger', ['Read', 'Grep', 'Glob']],
  ['reviewer', ['Read', 'Grep', 'Glob']]
])

function fail(message, status = 2) {
  console.error(`role-capability-projection: ${message}`)
  process.exit(status)
}

function usage() {
  fail(
    'usage: role-capability-projection.mjs <project|validate-projection> --harness <slug> ' +
      '--role <role> --source <portable-agent.md> --projected <local-agent.md>'
  )
}

function parseArgs(argv) {
  const command = argv.shift()
  if (!['project', 'validate-projection'].includes(command)) usage()
  const values = { command }
  while (argv.length > 0) {
    const key = argv.shift()
    const value = argv.shift()
    if (!key?.startsWith('--') || value === undefined) usage()
    const name = key.slice(2)
    if (!['harness', 'role', 'source', 'projected'].includes(name) || values[name]) usage()
    values[name] = value
  }
  for (const key of ['harness', 'role', 'source', 'projected']) {
    if (!values[key]) usage()
  }
  return values
}

function profileFor(harness, role) {
  if (harness !== SUPPORTED_HARNESS) {
    fail(
      `refusing ${role} dispatch on harness ${harness}: no verified role projection is implemented`,
      REFUSED
    )
  }
  const tools = PROFILES.get(role)
  if (!tools) {
    const reason =
      role === 'integrator'
        ? 'the integrator needs shell and GitHub access, and a tools allowlist cannot constrain Bash to its brokers'
        : 'no write-restricted projection profile exists for that role'
    fail(`refusing ${role} dispatch on harness ${harness}: ${reason}`, REFUSED)
  }
  return tools
}

function readPortableSource(path, role) {
  let stat
  try {
    stat = lstatSync(path)
  } catch (error) {
    fail(`cannot read portable source ${path}: ${error.message}`, REFUSED)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) {
    fail(`portable source must be a regular file, not a symlink: ${path}`, REFUSED)
  }
  const source = readFileSync(path, 'utf8')
  const lines = source.split('\n')
  if (lines[0] !== '---') fail(`portable source has no leading frontmatter: ${path}`, REFUSED)
  const close = lines.indexOf('---', 1)
  if (close < 0) fail(`portable source has unterminated frontmatter: ${path}`, REFUSED)
  const frontmatter = lines.slice(1, close)
  const keys = frontmatter
    .filter((line) => /^[A-Za-z_][A-Za-z0-9_-]*:/.test(line))
    .map((line) => line.slice(0, line.indexOf(':')))
  if (keys.join(',') !== 'name,description') {
    fail(`portable source frontmatter must contain only name,description: ${path}`, REFUSED)
  }
  const nameLine = frontmatter.find((line) => line.startsWith('name:'))
  const name = nameLine?.slice('name:'.length).trim()
  if (name !== role || basename(path) !== `${role}.md`) {
    fail(`portable source identity does not match role ${role}: ${path}`, REFUSED)
  }
  return { lines, close }
}

function renderProjection(sourcePath, harness, role, tools) {
  const { lines, close } = readPortableSource(sourcePath, role)
  const marker = `<!-- managed role projection: ${harness}/${role}/read-only-v1 -->`
  return [
    ...lines.slice(0, close),
    `tools: ${tools.join(', ')}`,
    lines[close],
    marker,
    ...lines.slice(close + 1)
  ].join('\n')
}

function assertProjectedFile(path, expected) {
  let stat
  try {
    stat = lstatSync(path)
  } catch (error) {
    fail(`refusing dispatch: projected agent is absent (${path}): ${error.message}`, REFUSED)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) {
    fail(`refusing dispatch: projected agent must be a regular local copy, not a symlink (${path})`, REFUSED)
  }
  if (readFileSync(path, 'utf8') !== expected) {
    fail(`refusing dispatch: projected agent differs from the verified projection (${path})`, REFUSED)
  }
}

function validateWithClaude(projectedPath) {
  const scratch = mkdtempSync(join(tmpdir(), 'role-projection-'))
  let refusal = null
  try {
    const agents = join(scratch, 'agents')
    mkdirSync(agents)
    const copy = join(agents, basename(projectedPath))
    writeFileSync(copy, readFileSync(projectedPath))
    const output = execFileSync('claude', ['plugin', 'validate', agents], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    })
    if (!output.includes('Validation passed')) {
      refusal = 'Claude Code did not confirm the projected frontmatter'
    }
  } catch (error) {
    const detail =
      error.stderr?.toString().trim() || error.stdout?.toString().trim() || error.message
    refusal = `Claude Code could not validate the projected agent: ${detail}`
  } finally {
    rmSync(scratch, { recursive: true, force: true })
  }
  if (refusal) fail(`refusing dispatch: ${refusal}`, REFUSED)
}

const args = parseArgs(process.argv.slice(2))
const tools = profileFor(args.harness, args.role)
const source = resolve(args.source)
const projected = resolve(args.projected)
if (source === projected) fail('portable source and projected copy must be different files', REFUSED)
const expected = renderProjection(source, args.harness, args.role, tools)

if (args.command === 'project') {
  let existing = null
  try {
    const stat = lstatSync(projected)
    if (stat.isSymbolicLink() || !stat.isFile()) {
      fail(`refusing to replace a non-regular projection target: ${projected}`, REFUSED)
    }
    existing = readFileSync(projected, 'utf8')
  } catch (error) {
    if (error.code !== 'ENOENT') fail(`cannot inspect projection target ${projected}: ${error.message}`)
  }
  if (existing !== null && existing !== expected) {
    fail(`refusing to overwrite a divergent local agent projection: ${projected}`, REFUSED)
  }
  if (existing === expected) {
    console.log(`projection already current: ${args.harness}/${args.role} -> ${projected}`)
    process.exit(0)
  }
  mkdirSync(dirname(projected), { recursive: true })
  const temporary = `${projected}.tmp-${process.pid}`
  writeFileSync(temporary, expected, { flag: 'wx' })
  renameSync(temporary, projected)
  console.log(`projected ${args.role} for ${args.harness} -> ${projected}`)
} else {
  assertProjectedFile(projected, expected)
  validateWithClaude(projected)
  console.log(
    `validated preparatory projection ${args.harness}/${args.role}: tools=${tools.join(',')}`
  )
}
