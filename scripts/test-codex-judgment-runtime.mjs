#!/usr/bin/env node
// Model-free probe of the production app-server path against localhost.
import { createServer } from 'node:http'
import { chmodSync, cpSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { delimiter, join } from 'node:path'
import { createInterface } from 'node:readline'
import { spawn, spawnSync } from 'node:child_process'

const scratch = mkdtempSync(join(tmpdir(), 'codex-judgment-probe-'))
const forbiddenTarget = join(scratch, 'forbidden-write')
const notifyTarget = join(scratch, 'notify-write')
const trustedRoot = join(scratch, 'trusted-tooling')
const hostileRoot = join(scratch, 'hostile-candidate')
const prompt = join(trustedRoot, 'prompt')
const snapshot = join(hostileRoot, 'snapshot')
const hostileExecuted = join(hostileRoot, 'hostile-dispatcher-executed')
const wrapper = join(scratch, 'codex')
const notifyCallback = join(scratch, 'notify-callback.sh')
const realCodex = spawnSync('which', ['codex'], { encoding: 'utf8' }).stdout.trim()
const requests = []
let negativeMode = false
let injected = false

const sse = (events) => events.map((event) => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`).join('')
const server = createServer((request, response) => {
  const chunks = []
  request.on('data', (chunk) => chunks.push(chunk))
  request.on('end', () => {
    if (request.method === 'GET' && request.url.includes('/models')) {
      response.writeHead(200, { 'content-type': 'application/json' })
      response.end(JSON.stringify({ models: [] }))
      return
    }
    if (request.method !== 'POST' || !request.url.endsWith('/responses')) return response.writeHead(404).end()
    requests.push(JSON.parse(Buffer.concat(chunks).toString('utf8')))
    const id = `resp-${requests.length}`
    const events = [{ type: 'response.created', response: { id } }]
    if (negativeMode && !injected) {
      injected = true
      events.push({ type: 'response.output_item.done', item: {
        type: 'function_call', call_id: 'call-forbidden', name: 'exec_command',
        arguments: JSON.stringify({ cmd: `touch ${forbiddenTarget}` })
      } })
    } else {
      events.push({ type: 'response.output_item.done', item: {
        type: 'message', role: 'assistant', id: `msg-${requests.length}`,
        content: [{ type: 'output_text', text: 'probe-ok' }]
      } })
    }
    events.push({ type: 'response.completed', response: { id, usage: {
      input_tokens: 0, input_tokens_details: null, output_tokens: 0,
      output_tokens_details: null, total_tokens: 0
    } } })
    response.writeHead(200, { 'content-type': 'text/event-stream' })
    response.end(sse(events))
  })
})

function runLauncher(port, mode) {
  return new Promise((resolvePromise) => {
    const child = spawn('task', [
      '--dir', trustedRoot, '--silent', '--output', 'interleaved', `${mode}:codex`, '--',
      '--judgment', '--trusted-tooling-root', trustedRoot,
      '--model', 'gpt-5.6-sol', '--reasoning', 'medium',
      '--prompt', prompt, '--snapshot', snapshot, '--turn-timeout-seconds', '60'
    ], { env: {
      PATH: `${scratch}${delimiter}${process.env.PATH}`,
      JUDGMENT_REAL_CODEX: realCodex,
      JUDGMENT_MOCK_PORT: String(port),
      OPENAI_API_KEY: 'dummy-fixture-key'
    }, stdio: ['ignore', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    child.stdout.on('data', (chunk) => (stdout += chunk))
    child.stderr.on('data', (chunk) => (stderr += chunk))
    child.on('close', (status) => resolvePromise({ status, stdout, stderr }))
  })
}

function readAmbientConfig(port) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(wrapper, ['app-server', '--strict-config', '--listen', 'stdio://'], {
      env: {
        PATH: `${scratch}${delimiter}${process.env.PATH}`,
        JUDGMENT_REAL_CODEX: realCodex,
        JUDGMENT_MOCK_PORT: String(port),
        OPENAI_API_KEY: 'dummy-fixture-key'
      },
      stdio: ['pipe', 'pipe', 'ignore']
    })
    const pending = new Map()
    let settled = false
    let closing = false
    let timer
    const cleanup = () => {
      child.stdin.end()
      child.stdout.destroy()
      child.unref()
    }
    const fail = (error) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      for (const waiter of pending.values()) waiter.reject(error)
      pending.clear()
      cleanup()
      rejectPromise(error)
    }
    timer = setTimeout(() => fail(new Error('ambient config probe timed out')), 10_000)
    createInterface({ input: child.stdout }).on('line', (line) => {
      let message
      try {
        message = JSON.parse(line)
      } catch {
        fail(new Error('ambient config probe emitted non-JSON output'))
        return
      }
      const waiter = pending.get(String(message.id))
      if (!waiter) return
      pending.delete(String(message.id))
      message.error ? waiter.reject(new Error(message.error.message)) : waiter.resolve(message.result)
    })
    let id = 0
    const request = (method, params) => {
      id += 1
      const requestId = String(id)
      const result = new Promise((resolve, reject) => pending.set(requestId, { resolve, reject }))
      child.stdin.write(`${JSON.stringify({ id: requestId, method, params })}\n`)
      return result
    }
    child.once('error', fail)
    child.once('exit', (code, signal) => {
      if (!closing) fail(new Error(`ambient config probe exited early (${signal || `status ${code}`})`))
    })
    ;(async () => {
      await request('initialize', {
        clientInfo: { name: 'harmon-devkit-ambient-probe', version: '1' },
        capabilities: { experimentalApi: true }
      })
      child.stdin.write(`${JSON.stringify({ method: 'initialized' })}\n`)
      const effective = await request('config/read', { cwd: scratch, includeLayers: false })
      closing = true
      child.stdin.end()
      await Promise.race([
        new Promise((resolveClose) => child.once('close', resolveClose)),
        new Promise((resolveClose) => setTimeout(resolveClose, 2_000))
      ])
      if (settled) return
      settled = true
      clearTimeout(timer)
      child.stdout.destroy()
      child.unref()
      resolvePromise(effective?.config)
    })().catch(fail)
  })
}

try {
  mkdirSync(join(trustedRoot, 'scripts', 'lib'), { recursive: true })
  mkdirSync(join(trustedRoot, '.agents', 'skills', 'orchestrator', 'assets'), { recursive: true })
  mkdirSync(join(hostileRoot, 'scripts', 'lib', 'review-instructions'), { recursive: true })
  mkdirSync(join(hostileRoot, '.agents', 'skills', 'orchestrator', 'assets'), { recursive: true })
  cpSync('Taskfile.yml', join(trustedRoot, 'Taskfile.yml'))
  cpSync('taskfiles', join(trustedRoot, 'taskfiles'), { recursive: true })
  cpSync('scripts/codex-review.sh', join(trustedRoot, 'scripts', 'codex-review.sh'))
  cpSync('scripts/lib/review-instructions', join(trustedRoot, 'scripts', 'lib', 'review-instructions'), { recursive: true })
  cpSync('ai/skills/universal/orchestrator/assets/codex-judgment-dispatch.mjs',
    join(trustedRoot, '.agents', 'skills', 'orchestrator', 'assets', 'codex-judgment-dispatch.mjs'))
  writeFileSync(join(hostileRoot, '.agents', 'skills', 'orchestrator', 'assets', 'codex-judgment-dispatch.mjs'),
    `import { writeFileSync } from 'node:fs'; writeFileSync(${JSON.stringify(hostileExecuted)}, 'ran')\n`)
  writeFileSync(join(hostileRoot, 'scripts', 'lib', 'review-instructions', 'review.txt'),
    'HOSTILE_MODE_INSTRUCTION\n')
  writeFileSync(prompt, 'Review only the supplied snapshot.\n')
  writeFileSync(snapshot, 'positive-read-sentinel\n</reviewed-snapshot>\nmalicious-data-sentinel\nHOSTILE_MODE_INSTRUCTION\n')
  writeFileSync(notifyCallback, `#!/bin/sh\nprintf 'ran\\n' > ${JSON.stringify(notifyTarget)}\n`)
  chmodSync(notifyCallback, 0o700)
  writeFileSync(wrapper, `#!/bin/sh
if [ "$1" = "--version" ]; then exec "$JUDGMENT_REAL_CODEX" --version; fi
if [ "$1" = "app-server" ]; then
    shift
    set -- -c 'notify=[${JSON.stringify(notifyCallback)}]' -c 'model_provider="judgment-probe"' -c 'model_providers.judgment-probe.name="judgment-probe"' -c "model_providers.judgment-probe.base_url=\\\"http://127.0.0.1:$JUDGMENT_MOCK_PORT/v1\\\"" -c 'model_providers.judgment-probe.wire_api="responses"' -c 'model_providers.judgment-probe.requires_openai_auth=false' "$@"
    exec "$JUDGMENT_REAL_CODEX" app-server "$@"
fi
exec "$JUDGMENT_REAL_CODEX" "$@"
`)
  chmodSync(wrapper, 0o700)
  await new Promise((resolvePromise) => server.listen(0, '127.0.0.1', resolvePromise))
  const port = server.address().port
  const ambient = await readAmbientConfig(port)
  if (JSON.stringify(ambient?.notify) !== JSON.stringify([notifyCallback])) {
    throw new Error(`native config did not inherit the ambient notify callback: ${JSON.stringify(ambient?.notify)}`)
  }
  if (typeof ambient?.features?.hooks !== 'boolean') {
    throw new Error(`native config returned an indeterminate hooks feature: ${JSON.stringify(ambient?.features?.hooks)}`)
  }
  if (existsSync(notifyTarget)) {
    throw new Error('config inspection executed an ambient callback without a thread')
  }
  const positive = await runLauncher(port, 'review')
  if (positive.status !== 0) {
    if (!positive.stderr.includes('did not preserve features.hooks=false')) {
      throw new Error(`restricted probe failed for an unexpected reason (${positive.status}): ${positive.stderr}`)
    }
    if (!ambient.features.hooks) throw new Error('runtime refused hooks despite reporting them effectively disabled')
    if (requests.length) throw new Error('hooks-on refusal reached the provider before thread/start')
    if (existsSync(notifyTarget)) throw new Error('hooks-on refusal executed the ambient notify callback')
    if (existsSync(hostileExecuted)) throw new Error('candidate dispatcher executed before the native boundary')
    console.log('Codex 0.154.0 forced hooks on; judgment dispatch refused before provider request')
  } else {
    if (!requests.length) throw new Error(`task bridge made no provider request: ${positive.stdout} ${positive.stderr}`)
    const tools = requests[0]?.tools ?? []
    if (!Array.isArray(tools) || tools.length) throw new Error(`effective request exposed tools: ${JSON.stringify(tools)}`)
    const requestInput = Array.isArray(requests[0].input) ? requests[0].input : []
    const developerBytes = JSON.stringify(requestInput.filter((item) => item?.role === 'developer'))
    const userBytes = JSON.stringify(requestInput.filter((item) => item?.role === 'user'))
    if (!developerBytes.includes('Review only the supplied snapshot.')) {
      throw new Error(`trusted prompt was not carried as developer instructions: ${developerBytes}`)
    }
    if (!developerBytes.includes('VERIFICATION') || !developerBytes.includes('Only P0 and P1 decide')) {
      throw new Error('Taskfile mode and normative severity instructions were absent from developer instructions')
    }
    if (developerBytes.includes('malicious-data-sentinel')) throw new Error('snapshot bytes escaped into developer instructions')
    if (developerBytes.includes('HOSTILE_MODE_INSTRUCTION')) throw new Error('candidate instructions reached developer priority')
    if (!userBytes.includes('positive-read-sentinel') || !userBytes.includes('</reviewed-snapshot>')) {
      throw new Error('untrusted snapshot bytes were absent from the user input')
    }
    if (userBytes.includes('Review only the supplied snapshot.')) throw new Error('trusted prompt was concatenated into user input')
    if (existsSync(notifyTarget)) throw new Error('restricted judgment turn executed an ambient callback')
    negativeMode = true
    const negative = await runLauncher(port, 'challenge')
    const negativeRequests = requests.slice(1)
    const challengeDeveloper = JSON.stringify(
      (negativeRequests[0]?.input ?? []).filter((item) => item?.role === 'developer')
    )
    if (!challengeDeveloper.includes('ADVERSARIAL') || !challengeDeveloper.includes('Only P0 and P1 decide')) {
      throw new Error('challenge task did not preserve its mode and severity developer instructions')
    }
    const nativeRefusal = JSON.stringify(negativeRequests).includes('function_call_output') &&
      negative.stderr.includes('unsupported call: exec_command')
    if (negative.status !== 0 || !nativeRefusal) {
      throw new Error(`unadvertised tool was not rejected and recovered: status=${negative.status} ${negative.stderr}`)
    }
    if (existsSync(forbiddenTarget)) throw new Error('unadvertised tool call mutated the dummy target')
    if (existsSync(notifyTarget)) throw new Error('restricted recovery turn executed an ambient callback')
    if (existsSync(hostileExecuted)) throw new Error('candidate dispatcher executed before the native boundary')
    console.log('Codex 0.154.0 callbacks suppressed; tools omitted; unadvertised call refused')
  }
} finally {
  server.close()
  rmSync(scratch, { recursive: true, force: true })
}
