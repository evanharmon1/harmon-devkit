#!/usr/bin/env node
// One writer per lane/attempt. Validate a sibling candidate before publishing it.
import fs from 'node:fs'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const validator = fileURLToPath(new URL('./validate-result-schemas.mjs', import.meta.url))

function main() {
  const [command, ...args] = process.argv.slice(2)
  const allowed = new Set(['file', 'state', 'seq', 'request-id', 'stage', 'round', 'head', 'summary'])
  const options = {}
  if (command !== 'set') throw new Error('usage: lane-status.mjs set --file PATH --state STATE --stage STAGE --round N --head SHA --summary TEXT [--request-id ID] [--seq N]')
  for (let i = 0; i < args.length; i += 2) {
    const key = args[i].replace(/^--/, '')
    if (!args[i].startsWith('--') || !allowed.has(key) || args[i + 1] === undefined || key in options) {
      throw new Error(`invalid or duplicate option: ${args[i]}`)
    }
    options[key] = args[i + 1]
  }
  for (const key of ['file', 'state', 'stage', 'round', 'head', 'summary']) {
    if (!options[key]) throw new Error(`--${key} is required`)
  }
  const file = path.resolve(options.file)
  // Exclusive creation refuses a concurrent publisher instead of losing a seq.
  // A crash may leave this lock; the operator reconciles it before retrying.
  const lock = `${file}.lock`
  const fd = fs.openSync(lock, 'wx', 0o600)
  const candidate = path.join(path.dirname(file), `.${path.basename(file)}.${randomUUID()}.tmp`)
  try {
    let previous
    try {
      previous = JSON.parse(fs.readFileSync(file, 'utf8'))
    } catch (error) {
      if (error.code !== 'ENOENT') throw error
    }
    const seq = options.seq === undefined ? (previous === undefined ? 1 : previous.seq + 1) : Number(options.seq)
    if (previous === undefined && seq !== 1) throw new Error('first seq must be 1')
    const document = {
      state: options.state,
      seq,
      stage: options.stage,
      round: Number(options.round),
      head: options.head,
      updated_at: new Date().toISOString(),
      summary: options.summary
    }
    if (options['request-id'] !== undefined) document.request_id = options['request-id']
    fs.writeFileSync(candidate, `${JSON.stringify(document, null, 2)}\n`, { flag: 'wx', mode: 0o600 })
    const validation = spawnSync(process.execPath, [validator, 'lane-status', candidate,
      ...(previous === undefined ? [] : ['--prev', file])], { encoding: 'utf8' })
    if (validation.error) throw validation.error
    if (validation.status !== 0) throw new Error(validation.stderr || 'lane status validation failed')
    fs.renameSync(candidate, file)
    console.log(`lane status: ${document.state} seq=${document.seq}`)
  } finally {
    fs.rmSync(candidate, { force: true })
    fs.closeSync(fd)
    fs.unlinkSync(lock)
  }
}

try {
  main()
} catch (error) {
  console.error(`lane-status: ${error.message}`)
  process.exitCode = 1
}
