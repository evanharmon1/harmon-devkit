#!/usr/bin/env node
// Model-free probe of the production app-server path against localhost.
import { createServer } from 'node:http'
import { chmodSync, existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { delimiter, join } from 'node:path'
import { spawn, spawnSync } from 'node:child_process'

const scratch = mkdtempSync(join(tmpdir(), 'codex-judgment-probe-'))
const forbiddenTarget = join(scratch, 'forbidden-write')
const prompt = join(scratch, 'prompt')
const snapshot = join(scratch, 'snapshot')
const wrapper = join(scratch, 'codex')
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

function runLauncher(port) {
  return new Promise((resolvePromise) => {
    const child = spawn('node', [
      'ai/skills/universal/orchestrator/assets/codex-judgment-dispatch.mjs',
      '--role', 'reviewer', '--model', 'gpt-5.6-sol', '--reasoning', 'medium',
      '--prompt', prompt, '--snapshot', snapshot
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

try {
  writeFileSync(prompt, 'Review only the supplied snapshot.\n')
  writeFileSync(snapshot, 'positive-read-sentinel\n')
  writeFileSync(wrapper, `#!/bin/sh
if [ "$1" = "--version" ]; then exec "$JUDGMENT_REAL_CODEX" --version; fi
exec "$JUDGMENT_REAL_CODEX" "$@" -c 'model_provider="judgment-probe"' -c 'model_providers.judgment-probe.name="judgment-probe"' -c "model_providers.judgment-probe.base_url=\\\"http://127.0.0.1:$JUDGMENT_MOCK_PORT/v1\\\"" -c 'model_providers.judgment-probe.wire_api="responses"' -c 'model_providers.judgment-probe.requires_openai_auth=false'
`)
  chmodSync(wrapper, 0o700)
  await new Promise((resolvePromise) => server.listen(0, '127.0.0.1', resolvePromise))
  const port = server.address().port
  const positive = await runLauncher(port)
  if (positive.status !== 0) throw new Error(`positive probe exited ${positive.status}: ${positive.stderr}`)
  const tools = requests[0]?.tools ?? []
  if (!Array.isArray(tools) || tools.length) throw new Error(`effective request exposed tools: ${JSON.stringify(tools)}`)
  if (!JSON.stringify(requests[0].input).includes('positive-read-sentinel')) throw new Error('permitted snapshot sentinel was absent')
  negativeMode = true
  const negative = await runLauncher(port)
  const negativeRequests = requests.slice(1)
  const nativeRefusal = JSON.stringify(negativeRequests).includes('function_call_output') &&
    negative.stderr.includes('unsupported call: exec_command')
  if (negative.status !== 0 || !nativeRefusal) {
    throw new Error(`unadvertised tool was not rejected and recovered: status=${negative.status} ${negative.stderr}`)
  }
  if (existsSync(forbiddenTarget)) throw new Error('unadvertised tool call mutated the dummy target')
  console.log('Codex 0.154.0 app-server tools omitted; snapshot present; unadvertised call refused')
} finally {
  server.close()
  rmSync(scratch, { recursive: true, force: true })
}
