#!/usr/bin/env node
// Dispatch a Codex challenger/reviewer through a tool-free ephemeral app-server thread.

import { spawn } from 'node:child_process'
import { lstatSync, readFileSync, realpathSync } from 'node:fs'
import { basename, resolve } from 'node:path'
import { tmpdir } from 'node:os'
import { createInterface } from 'node:readline'
import { pathToFileURL } from 'node:url'

const REFUSED = 20
const SUPPORTED_VERSION = '0.154.0'
const SAFE_ITEMS = new Set(['userMessage', 'agentMessage', 'reasoning'])
const RPC_TIMEOUT_MS = 30_000
const SHUTDOWN_TIMEOUT_MS = 5_000

export function judgmentConfig(mcpNames = []) {
  return {
    'features.apps': false,
    'features.code_mode': false,
    'features.code_mode_only': false,
    'features.goals': false,
    'features.image_generation': false,
    'features.memories': false,
    'features.multi_agent': false,
    'features.multi_agent_v2': false,
    'features.plugins': false,
    'features.request_permissions_tool': false,
    'features.shell_snapshot': false,
    'features.shell_tool': false,
    'features.standalone_web_search': false,
    'features.tool_suggest': false,
    'features.unified_exec': false,
    'features.view_image': false,
    web_search: 'disabled',
    mcp_servers: Object.fromEntries(mcpNames.map((name) => [name, { enabled: false }]))
  }
}

function configValue(config, dotted) {
  if (Object.hasOwn(config, dotted)) return config[dotted]
  return dotted.split('.').reduce((value, key) => value?.[key], config)
}

export function assertEffectiveJudgmentConfig(config) {
  if (!config || typeof config !== 'object' || Array.isArray(config)) {
    throw new Error('effective Codex config has an invalid shape')
  }
  for (const [key, expected] of Object.entries(judgmentConfig())) {
    if (key === 'mcp_servers') continue
    const actual = configValue(config, key)
    if (actual !== expected) {
      throw new Error(`effective Codex config did not preserve ${key}=${JSON.stringify(expected)}`)
    }
  }
}

function refuse(message, status = REFUSED) {
  const error = new Error(message)
  error.status = status
  throw error
}

function parseArgs(argv) {
  const values = {}
  while (argv.length) {
    const key = argv.shift()
    const value = argv.shift()
    const name = key?.startsWith('--') ? key.slice(2) : ''
    if (!['role', 'model', 'reasoning', 'prompt', 'snapshot', 'turn-timeout-seconds', 'mode-instruction', 'severity-instruction'].includes(name) || !value || values[name]) {
      refuse('usage: --role <challenger|reviewer> --model <model> --reasoning <level> --prompt <file> --snapshot <file> --turn-timeout-seconds <seconds>', 2)
    }
    values[name] = value
  }
  if (Object.keys(values).length !== 8) refuse('all dispatch arguments are required', 2)
  return values
}

function regularFile(path, label) {
  const absolute = resolve(path)
  let stat
  try {
    stat = lstatSync(absolute)
  } catch (error) {
    refuse(`${label} is unavailable: ${error.message}`)
  }
  if (!stat.isFile() || stat.isSymbolicLink()) refuse(`${label} must be a regular file, not a symlink`)
  return absolute
}

function send(child, message) {
  child.stdin.write(`${JSON.stringify(message)}\n`)
}

async function run(args) {
  const serverArgs = [
    'app-server', '--strict-config', '--listen', 'stdio://',
    '-c', 'approval_policy="never"',
    '-c', 'sandbox_mode="read-only"'
  ]
  for (const [key, value] of Object.entries(judgmentConfig())) {
    if (key !== 'mcp_servers') serverArgs.push('-c', `${key}=${JSON.stringify(value)}`)
  }
  const child = spawn('codex', serverArgs, {
    stdio: ['pipe', 'pipe', 'inherit']
  })
  const closed = new Promise((resolveClosed) => child.once('close', resolveClosed))
  const pending = new Map()
  const notifications = []
  let wake = null
  let failure = null
  const rejectPending = (error) => {
    failure ??= error
    for (const waiter of pending.values()) waiter.reject(error)
    pending.clear()
    wake?.()
  }
  child.on('error', (error) => rejectPending(new Error(`app-server failed: ${error.message}`)))
  child.stdin.on('error', (error) => rejectPending(new Error(`app-server input failed: ${error.message}`)))
  child.on('exit', (code, signal) => {
    rejectPending(new Error(`app-server exited before completion (${signal || `status ${code}`})`))
  })
  createInterface({ input: child.stdout }).on('line', (line) => {
    let message
    try {
      message = JSON.parse(line)
    } catch {
      rejectPending(new Error('app-server emitted non-JSON output'))
      return
    }
    if (message.id !== undefined && !message.method) {
      const waiter = pending.get(String(message.id))
      if (waiter) {
        pending.delete(String(message.id))
        message.error ? waiter.reject(new Error(message.error.message)) : waiter.resolve(message.result)
      }
    } else {
      if (message.id !== undefined) rejectPending(new Error(`unexpected app-server request: ${message.method}`))
      notifications.push(message)
      wake?.()
    }
  })
  let id = 0
  const request = (method, params) => {
    id += 1
    const requestId = String(id)
    const promise = new Promise((resolvePromise, reject) => {
      const timer = setTimeout(() => {
        pending.delete(requestId)
        reject(new Error(`${method} timed out`))
      }, RPC_TIMEOUT_MS)
      pending.set(requestId, {
        resolve: (value) => {
          clearTimeout(timer)
          resolvePromise(value)
        },
        reject: (error) => {
          clearTimeout(timer)
          reject(error)
        }
      })
    })
    send(child, { id: requestId, method, params })
    return promise
  }
  const nextNotification = async (timeoutMs = RPC_TIMEOUT_MS) => {
    while (!notifications.length && !failure) {
      await new Promise((resolvePromise, reject) => {
        const timer = setTimeout(() => {
          wake = null
          reject(new Error('turn notification timed out'))
        }, timeoutMs)
        wake = () => {
          clearTimeout(timer)
          resolvePromise()
        }
      })
    }
    wake = null
    if (failure) throw failure
    return notifications.shift()
  }
  try {
    const initialized = await request('initialize', {
      clientInfo: { name: 'harmon-devkit-judgment', version: '1' },
      capabilities: { experimentalApi: true }
    })
    const runtimeVersion = /^harmon-devkit-judgment\/([^ ]+) /.exec(initialized?.userAgent ?? '')?.[1]
    if (runtimeVersion !== SUPPORTED_VERSION) {
      refuse(`unsupported Codex CLI version: ${runtimeVersion || 'unknown'}`)
    }
    send(child, { method: 'initialized' })
    const effective = await request('config/read', { cwd: tmpdir(), includeLayers: false })
    assertEffectiveJudgmentConfig(effective?.config)
    const servers = effective?.config?.mcp_servers ?? effective?.config?.mcpServers ?? {}
    if (!servers || typeof servers !== 'object' || Array.isArray(servers)) refuse('effective MCP inventory has an invalid shape')
    const started = await request('thread/start', {
      model: args.model,
      cwd: tmpdir(),
      approvalPolicy: 'never',
      sandbox: 'read-only',
      runtimeWorkspaceRoots: [],
      ephemeral: true,
      environments: [],
      dynamicTools: [],
      selectedCapabilityRoots: [],
      developerInstructions: `${args.prompt.trimEnd()}\n\n${args.modeInstruction.trimEnd()}\n\n${args.severityInstruction.trimEnd()}\n`,
      config: judgmentConfig(Object.keys(servers))
    })
    if (!['never', 'on-request'].includes(started?.approvalPolicy)) refuse('runtime returned an unknown approval policy')
    if (started?.model !== args.model) refuse(`runtime changed the requested model to ${started?.model || 'unknown'}`)
    if (started?.thread?.ephemeral !== true || started.thread.path !== null) refuse('runtime did not preserve ephemeral execution')
    if ((started?.instructionSources ?? []).length) refuse('runtime loaded ambient instruction sources')
    const turnDeadline = Date.now() + args.turnTimeoutSeconds * 1000
    const turn = await request('turn/start', {
      threadId: started.thread.id,
      input: [{ type: 'text', text: args.snapshot, textElements: [] }],
      effort: args.reasoning
    })
    let response
    for (;;) {
      const remaining = turnDeadline - Date.now()
      if (remaining <= 0) refuse('judgment turn exceeded its caller-supplied deadline')
      const event = await nextNotification(remaining)
      const item = event?.params?.item
      // Defense in depth only: request-inventory tests prove prevention before dispatch.
      if (item?.type && !SAFE_ITEMS.has(item.type)) refuse(`runtime exposed unexpected capability: ${item.type}`)
      if (event.method === 'item/completed' && item?.type === 'agentMessage') response = item.text
      if (event.method === 'turn/completed' && event.params?.turn?.id === turn?.turn?.id) {
        if (event.params.turn.status !== 'completed') refuse(`turn ended ${event.params.turn.status}`)
        if (!response?.trim()) refuse('runtime returned no judgment result')
        process.stdout.write(`${response.trim()}\n`)
        break
      }
    }
  } finally {
    child.stdin.end()
    await Promise.race([
      closed,
      new Promise((resolveTimeout) => setTimeout(resolveTimeout, SHUTDOWN_TIMEOUT_MS))
    ])
    child.unref()
    child.stdout.destroy()
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  try {
    const args = parseArgs(process.argv.slice(2))
    if (!['challenger', 'reviewer'].includes(args.role)) refuse(`role ${args.role} has no result-only Codex profile`)
    if (!['low', 'medium', 'high', 'xhigh'].includes(args.reasoning)) refuse(`unsupported reasoning level: ${args.reasoning}`)
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(args.model)) refuse(`invalid model name: ${args.model}`)
    if (!/^[1-9][0-9]*$/.test(args['turn-timeout-seconds']) || Number(args['turn-timeout-seconds']) > 43_200) {
      refuse('turn-timeout-seconds must be an integer from 1 through 43200', 2)
    }
    args.turnTimeoutSeconds = Number(args['turn-timeout-seconds'])
    const prompt = regularFile(args.prompt, 'prompt')
    const snapshot = regularFile(args.snapshot, 'snapshot')
    const modeInstruction = regularFile(args['mode-instruction'], 'mode instruction')
    const severityInstruction = regularFile(args['severity-instruction'], 'severity instruction')
    if (basename(snapshot) === 'auth.json') refuse('credential files cannot be judgment snapshots')
    args.prompt = readFileSync(prompt, 'utf8')
    args.snapshot = readFileSync(snapshot, 'utf8')
    args.modeInstruction = readFileSync(modeInstruction, 'utf8')
    args.severityInstruction = readFileSync(severityInstruction, 'utf8')
    if (!args.prompt.trim() || !args.snapshot.trim() || !args.modeInstruction.trim() || !args.severityInstruction.trim()) {
      refuse('prompt, snapshot, and instructions must be nonempty')
    }
    await run(args)
  } catch (error) {
    console.error(`codex-judgment-dispatch: refusing dispatch: ${error.message}`)
    process.exit(error.status || REFUSED)
  }
}
