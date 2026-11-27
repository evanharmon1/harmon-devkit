#!/usr/bin/env node
// drive-handoff.mjs — the body of drive-handoff.sh (harmon-devkit#1919). The
// wrapper's header is the documented contract: usage, the ordered steps, the
// exit list the stage-outcome table maps, and the resume rules.
import { readFileSync, writeFileSync, existsSync, realpathSync, mkdtempSync, rmSync, renameSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { createHash, randomBytes } from 'node:crypto'
import { basename, join, resolve, dirname } from 'node:path'
import { spawn } from 'node:child_process'
import { isMainThread, MessageChannel, parentPort, receiveMessageOnPort, Worker, workerData } from 'node:worker_threads'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const support = join(here, '../../dev-flow-support/assets')
const tool = 'drive-handoff.sh'
const usage = `usage: ${tool} --repo OWNER/REPO --pr N --slate ID --session ID --run-id ID --result FILE --actor-id ID [--adjudication FILE] [--codex-state FILE --codex-repo-dir DIR] [--sections LIST] [--repo-root DIR] [--owner-token TOKEN] [--command-timeout-ms N]`
const EXIT = { rendered: 0, blocked: 2, judgment: 10, waiting: 11, retry: 12, notHandoff: 13, stale: 14 }
const COMMAND_TIMEOUT_MS = 180_000
const COMMAND_GRACE_MS = 1000
const INTERRUPTS = ['SIGINT', 'SIGTERM', 'SIGHUP']

// The child leads its group. A timeout kills the group even if its leader
// has exited, and a separate deadline closes pipes held open outside it.
export function superviseCommand(command, argv, { timeout, maxBuffer, encoding, input, ...options }, reply) {
  const deadline = performance.now() + timeout
  const child = spawn(command, argv, { ...options, detached: true })
  let group = child.pid
  let status = null
  let signal = null
  let error
  let closed = false
  let finished = false
  let size = 0
  let timeoutTimer, escalationTimer, drainTimer

  const signalGroup = (name) => {
    if (group === undefined) return false
    try {
      return process.kill(-group, name)
    } catch (failure) {
      // Darwin can deny a signal-0 probe for a group with only zombies.
      if (failure.code === 'ESRCH' || (name === 0 && failure.code === 'EPERM')) {
        group = undefined
        return false
      }
      error = { code: failure.code, message: failure.message }
      return true
    }
  }
  const finish = () => {
    if (finished) return
    finished = true
    clearTimeout(timeoutTimer)
    clearTimeout(escalationTimer)
    clearTimeout(drainTimer)
    if (!closed) {
      for (const stream of child.stdio) stream?.destroy()
      child.unref()
    }
    reply({ status, signal, stdout: stdout(), stderr: stderr(), ...(error && { error }) })
  }
  const stopGroup = (name, code, stopAt = performance.now()) => {
    if (error) return
    clearTimeout(timeoutTimer)
    const message = { EINTR: `command interrupted by ${name}`, ETIMEDOUT: 'command timed out', ENOBUFS: 'command output exceeded maxBuffer' }
    error = { code, message: message[code] }
    const alive = signalGroup(name)
    if (alive && name !== 'SIGKILL') {
      // Leave time within the same grace period to observe the final exit.
      const killAt = Math.min(deadline, stopAt + COMMAND_GRACE_MS / 2)
      escalationTimer = setTimeout(() => {
        escalationTimer = undefined
        signalGroup('SIGKILL')
        if (closed) finish()
      }, Math.max(0, killAt - performance.now()))
    }
    drainTimer = setTimeout(finish, Math.max(0, stopAt + COMMAND_GRACE_MS - performance.now()))
  }
  const capture = (stream) => {
    if (!stream) return () => null
    const chunks = []
    stream.on('data', (chunk) => {
      if (size > maxBuffer) return
      size += chunk.length
      chunks.push(chunk)
      if (size > maxBuffer) stopGroup('SIGKILL', 'ENOBUFS')
    })
    return () => Buffer.concat(chunks).toString(encoding)
  }
  const stdout = capture(child.stdout)
  const stderr = capture(child.stderr)
  child.on('error', (failure) => { error ??= { code: failure.code, message: failure.message } })
  child.on('exit', (code, name) => {
    status = code
    signal = name
    // Retire an empty group while an escaped pipe holder can still delay close.
    signalGroup(0)
  })
  child.on('close', () => {
    closed = true
    // The leader can close its pipes while a descendant ignores an interrupt.
    if (!escalationTimer || !signalGroup(0)) finish()
  })
  child.stdin?.on('error', () => {}) // Commands may exit without consuming input.
  child.stdin?.end(input)
  const arm = () => {
    const remaining = deadline - performance.now()
    if (remaining <= 0) stopGroup('SIGKILL', 'ETIMEDOUT', deadline)
    else timeoutTimer = setTimeout(arm, Math.min(Math.ceil(remaining), 2_147_483_647))
  }
  arm()
  return (name) => stopGroup(name, 'EINTR')
}

// The handoff worker keeps run-record's synchronous execute contract. Only
// it waits on the rendezvous; the supervisor and the public PID stay live.
function runCommand(command, argv, options) {
  const ready = new Int32Array(new SharedArrayBuffer(4))
  workerData.port.postMessage({ command, argv, options, ready })
  Atomics.wait(ready, 0, 0)
  return receiveMessageOnPort(workerData.port).message
}

function superviseRequests({ port, interrupted }) {
  let interruptActive
  const interrupt = () => interruptActive?.(INTERRUPTS[Atomics.load(interrupted, 0) - 1])
  parentPort.on('message', interrupt)
  port.on('message', ({ command, argv, options, ready }) => {
    const reply = (result) => {
      interruptActive = undefined
      port.postMessage(result)
      Atomics.store(ready, 0, 1)
      Atomics.notify(ready, 0)
    }
    if (Atomics.load(interrupted, 0)) {
      reply({ status: null, signal: null, error: { code: 'EINTR', message: 'handoff interrupted' } })
      return
    }
    try {
      interruptActive = superviseCommand(command, argv, options, reply)
      if (Atomics.load(interrupted, 0)) interrupt()
    } catch (error) {
      reply({ status: null, signal: null, error: { code: error.code, message: error.message } })
    }
  })
  port.on('close', () => {
    interruptActive?.('SIGKILL')
    parentPort.close()
  })
}

class Stop extends Error {
  constructor(code, message, fields = {}) { super(message); this.code = code; this.fields = fields }
}
const stop = (code, message, fields) => { throw new Stop(code, message, fields) }
let scratch

function parse(argv) {
  const values = ['repo', 'pr', 'slate', 'session', 'run-id', 'result', 'actor-id', 'adjudication', 'codex-state', 'codex-repo-dir', 'sections', 'repo-root', 'owner-token', 'command-timeout-ms']
  const o = {}
  for (let i = 0; i < argv.length; i++) {
    const name = argv[i].replace(/^--/, '')
    if (!argv[i].startsWith('--') || !values.includes(name) || argv[i + 1] === undefined || o[name] !== undefined) stop(EXIT.blocked, usage)
    o[name] = argv[++i]
  }
  if (['repo', 'pr', 'slate', 'session', 'run-id', 'result', 'actor-id'].some((n) => !o[n])) stop(EXIT.blocked, usage)
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(o.repo) || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(o['run-id']) ||
      !/^[1-9][0-9]*$/.test(o.pr) || !/^[1-9][0-9]*$/.test(o['actor-id'])) stop(EXIT.blocked, 'invalid --repo, --run-id, --pr or --actor-id')
  if (Boolean(o['codex-state']) !== Boolean(o['codex-repo-dir'])) stop(EXIT.blocked, '--codex-state and --codex-repo-dir go together')
  o.sections = (o.sections ?? 'deferred-findings').split(',')
  if (!o.sections.every((section) => /^[a-z][a-z-]*$/.test(section))) stop(EXIT.blocked, 'invalid --sections')
  o.token = o['owner-token'] ?? process.env.RUN_RECORD_OWNER_TOKEN
  if (!o.token) stop(EXIT.blocked, 'owner token required; acquire the slate lock first')
  const timeout = o['command-timeout-ms']
  if (timeout !== undefined && (!/^[1-9][0-9]*$/.test(timeout) || !Number.isSafeInteger(Number(timeout)))) {
    stop(EXIT.blocked, '--command-timeout-ms must be a positive safe integer')
  }
  return o
}

async function main(o, bind, note) {
  const root = realpathSync(o['repo-root'] ?? process.cwd())
  const timeout = Number(o['command-timeout-ms'] ?? COMMAND_TIMEOUT_MS)
  const run = (command, argv, options = {}) => runCommand(command, argv, {
    cwd: root, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, ...options, timeout,
  })
  const checkTimeout = (what, result, locks = [], publishLock) => {
    if (result.error?.code === 'EINTR') throw result.error
    if (result.error?.code !== 'ETIMEDOUT') return
    const stale = publishLock ? [publishLock] : locks.filter(existsSync)
    const recovery = stale.length === 0 ? '' : `. After confirming no owner is running, remove any stale lock at ${stale.join(', ')} and re-run`
    throw Object.assign(new Error(`${what} timed out after ${timeout} ms${recovery}`), { code: 'ETIMEDOUT' })
  }
  // Match the run-record helpers' synchronous execution contract.
  const execute = (command, argv, options) => {
    const result = run(command, argv, options)
    const operation = argv[0] === '--no-replace-objects' ? argv.slice(1) : argv
    checkTimeout([basename(command), ...operation.slice(0, 2).map((arg) => basename(arg))].join(' '), result)
    if (result.error) throw result.error
    if (result.status !== 0) throw Object.assign(new Error(`Command failed: ${command} ${argv.join(' ')}${result.stderr ? `\n${result.stderr}` : ''}`), result)
    return result.stdout
  }
  const must = (what, r, locks = []) => {
    checkTimeout(what, r, locks)
    if (r.stderr) process.stderr.write(r.stderr)
    // The failed step's own last line is the reason: its refusals are prose.
    const said = (r.stderr ?? '').trim().split('\n').at(-1)
    if (r.error || r.status !== 0) stop(EXIT.blocked, `${what} failed (exit ${r.status ?? r.signal ?? 'unknown'})${said ? `: ${said}` : ''}`)
    return r
  }
  const read = (p) => JSON.parse(readFileSync(p, 'utf8'))
  const sha = (bytes) => createHash('sha256').update(bytes).digest('hex')
  const { branchHead, assertRunOwner, checkSlateLock, stateRoot } = await import(pathToFileURL(join(support, 'run-record.mjs')).href)
  const validator = join(support, 'validate-result-schemas.mjs')
  const render = join(support, 'render-dev-flow.sh')

  // 1. The run identity every outcome is bound to, then owner authority.
  const common = must('git rev-parse', run('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'])).stdout.trim()
  const directory = join(common, 'dev-flow-v2/runs', o['run-id'])
  const lane = branchHead(directory, root, execute)
  const pointerPath = join(common, 'dev-flow-v2/active', `${sha(Buffer.from(lane.branch, 'utf8'))}.json`)
  const pointer = existsSync(pointerPath) ? read(pointerPath) : null
  if (pointer?.run_id !== o['run-id'] || !Number.isInteger(pointer?.generation) || pointer.generation < 1) stop(EXIT.blocked, `run ${o['run-id']} is not the active run of branch ${lane.branch}`)
  bind({ run: { run_id: o['run-id'], generation: pointer.generation }, head: lane.head })
  const runPath = join(directory, 'run.json')
  const recordLocks = [`${runPath}.wlock`, `${runPath}.wlock.break`]
  const registry = join(common, 'dev-flow-v2/locks/registry')
  const writerLocks = [...recordLocks, `${registry}.wlock`, `${registry}.wlock.break`]
  const record = () => read(runPath)
  const entry = record()
  if (entry.outcome !== null) stop(EXIT.blocked, `run already ended with outcome ${entry.outcome}`)
  const { root: state } = stateRoot(root, execute)
  assertRunOwner(state, o.slate, o['run-id'])
  checkSlateLock({ root: state, slate: o.slate, session: o.session, ownerToken: o.token }, execute)
  if (entry.stage_transitions.at(-1).stage !== 'integration') stop(EXIT.blocked, `the run's active stage is ${entry.stage_transitions.at(-1).stage}, not integration`)
  if (entry.pr?.number !== Number(o.pr)) stop(EXIT.blocked, `the run is bound to PR ${entry.pr ? `#${entry.pr.number}` : 'nothing'}, not #${o.pr}`)
  const writer = (command, ...a) => must(`run-record ${command}`, run(process.execPath, [join(support, 'run-record.mjs'), command, '--slate', o.slate, '--session', o.session, '--run-id', o['run-id'], ...a], { env: { ...process.env, RUN_RECORD_OWNER_TOKEN: o.token } }), writerLocks)

  // 2. The bounded integrator result, validated and consumed as is.
  const resultFile = resolve(root, o.result)
  let bytes
  try { bytes = readFileSync(resultFile) } catch { stop(EXIT.blocked, `result not found: ${o.result}`) }
  must('result validation', run(process.execPath, [validator, 'envelope', resultFile, '--run-id', o['run-id'], '--initiated-by', entry.initiated_by]))
  const result = JSON.parse(bytes.toString('utf8'))
  if (result.role !== 'integrator') stop(EXIT.blocked, `the result is a ${result.role} result, not an integrator result`)
  // One commit on an open draft: the result's head, the branch head and the
  // PR head. Read-only, and first: a result on a moved head, pending or not,
  // is answered by the head-moved stop.
  const prView = () => {
    const pr = JSON.parse(must('gh pr view', run('gh', ['pr', 'view', o.pr, '--repo', o.repo, '--json', 'state,isDraft,headRefOid'])).stdout)
    if (!/^[0-9a-f]{40}$/.test(pr?.headRefOid ?? '')) stop(EXIT.blocked, `the read of PR #${o.pr} returned no head`)
    if (pr.headRefOid !== result.head) stop(EXIT.stale, `the PR head is ${pr.headRefOid}, not the result's head ${result.head}; a result is receipted before its head moves`)
    if (pr.state !== 'OPEN' || pr.isDraft !== true) stop(EXIT.blocked, `PR #${o.pr} is not an open draft (state ${pr.state}, isDraft ${pr.isDraft})`)
    return pr
  }
  if (result.head !== lane.head) stop(EXIT.stale, `the result reviewed ${result.head}, but ${lane.branch} is at ${lane.head}`)
  prView()
  const payload = result.payload
  const round = payload.integration_round
  const name = `integration-r${round}-integrator`
  // Integrator passes and review cycles are counted by their own fields only.
  note({ kind: 'record', ref: `integrator-pass ${round}` })
  for (const cycle of [payload.codex_cycle && { finder: 'codex-cloud', ...payload.codex_cycle }, ...(payload.finder_cycles ?? [])].filter(Boolean)) {
    note({ kind: 'review', ref: `${cycle.finder} cycle ${cycle.cycle}${cycle.carried ? ' (carried)' : ''}` })
  }
  // Every outcome for a result with findings carries the finding set.
  for (const finding of payload.findings) note({ kind: 'review', ref: finding.id })
  const collection = payload.collection
  if (!collection) stop(EXIT.notHandoff, 'the result carries no payload.collection record, so it is not the bounded integrator result (harmon-devkit#1897)')
  const next = collection.next_action
  const open = collection.incomplete.join(', ')
  const named = (...predicates) => predicates.some((predicate) => collection.incomplete.includes(predicate))
  // The receipt admits no pending observation.
  const pending = named('ci-pending', 'review-pending', 'read-failed')
  // What an incomplete collection owes once no judgment is owed: the rule
  // ai/agents/integrator.md applies when it stamps a result with no findings.
  const owes = () => {
    if (!pending && named('head-moved')) return { kind: 'stop', reason: `Collection stopped: ${open}` }
    if (pending || !named('activity-moved')) return { kind: 'wait', event: open, responsible: 'orchestrator', overdue_after_seconds: 900 }
    if (collection.trigger === 'collection-retry') return { kind: 'stop', reason: `Collection retry spent: ${open}` }
    return { kind: 'retry', retry_key: 'integrator-collection', attempt: 1, max_attempts: 2 }
  }
  const passPath = join(directory, 'passes', `${name}.json`)
  const adjudicationPath = join(directory, 'adjudications', `integration-r${round}.json`)
  const retained = () => record().receipts.some((receipt) => receipt.kind === 'pass' && receipt.file === name) && existsSync(passPath) && readFileSync(passPath).equals(bytes)
  // One invariant: a judgment is requested in exactly one place, step 5, for
  // a retained result whose findings have no recorded adjudication, whatever
  // its next_action says. Every other stop that answers with the result's
  // next_action therefore never asks for a decision it could not record (a
  // result the receipt cannot admit) or one the record already holds: a
  // judgment request there becomes what the collection still owes.
  const exits = { wait: EXIT.waiting, retry: EXIT.retry, stop: EXIT.notHandoff }
  const respond = (message) => {
    const action = next.kind === 'request-judgment' ? owes() : next
    stop(exits[action.kind] ?? EXIT.notHandoff, message, exits[action.kind] ? { next_action: action } : {})
  }
  // Only a result the receipt can admit goes on: `continue`, or a judgment
  // request with nothing pending. Any other result is answered here, and
  // nothing is retained.
  if (result.status === 'blocked') stop(EXIT.notHandoff, `the result is blocked${open ? ` (incomplete: ${open})` : ''}`, next.kind === 'stop' ? { next_action: next } : {})
  if (pending || (next.kind !== 'continue' && next.kind !== 'request-judgment')) {
    respond(`the result's next action is ${next.kind}${open ? ` and its collection is incomplete (${open})` : ''}; nothing is retained`)
  }

  // 3. Review activity is the readiness gate's five-surface fingerprint,
  // computed here from one read with the gate's own projections, so the value
  // this command's body edit must leave can be derived instead of read back.
  const gh = (...argv) => must(`gh ${argv[0]} ${argv.at(-1).slice(0, 60)}`, run('gh', argv)).stdout
  const surfaces = () => {
    const [owner, repository] = o.repo.split('/')
    const list = (path) => gh('api', '--paginate', '--slurp', `repos/${o.repo}/${path}`)
    const pr = JSON.parse(gh('api', `repos/${o.repo}/pulls/${o.pr}`))
    if (typeof pr.title !== 'string' || (pr.body !== null && typeof pr.body !== 'string') || typeof pr.head?.sha !== 'string') stop(EXIT.blocked, 'the PR object carries no usable title, body and head')
    // Every read of the surfaces is a read of the head too: a push that lands
    // after the last head check, the publish's own included, stops here.
    if (pr.head.sha !== result.head) stop(EXIT.stale, `the PR head is ${pr.head.sha}, not the result's head ${result.head}; collect again on the new head`)
    const comments = 'add // [] | map({id, u:.user.login, b:.body, t:.updated_at}) | sort_by(.id)'
    // The four fingerprint lines that are not the title and body.
    return { title: pr.title, body: pr.body ?? '', lines: [
      project('-c', 'add // [] | map({id, u:.user.login, s:.state, b:.body, t:.submitted_at}) | sort_by(.id)', list(`pulls/${o.pr}/reviews`)),
      project('-c', comments, list(`issues/${o.pr}/comments`)),
      project('-c', comments, list(`pulls/${o.pr}/comments`)),
      project('-c', '[.[].data.repository.pullRequest.reviewThreads.nodes[]] | map({id, r:.isResolved}) | sort_by(.id)',
        gh('api', 'graphql', '--paginate', '--slurp', '-F', `owner=${owner}`, '-F', `name=${repository}`, '-F', `pr=${o.pr}`, '-f',
          'query=query($owner:String!,$name:String!,$pr:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$pr){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{id isResolved comments(first:1){nodes{databaseId}}}}}}}')),
    ] }
  }
  const project = (flags, filter, input) => must('jq', run('jq', [flags, filter], { input })).stdout.trimEnd()
  const text = (value) => sha(Buffer.from(value, 'utf8'))
  const activityOf = (seen, body = seen.body) => text([project('-cS', '.', JSON.stringify({ title: seen.title, body })), ...seen.lines].map((line) => `${line}\n`).join(''))
  // One invariant for every external effect of this result: this command
  // records the effect in drive-handoff.json the moment it is confirmed, and
  // before any further read: the retained receipt, the recorded adjudication,
  // the evidence comment, the published body. A restart adopts an effect
  // exactly when the live state matches that record or the renderer's
  // reservation or completion for this publish, and otherwise takes the stop.
  const statePath = join(directory, 'drive-handoff.json')
  const digest = sha(bytes)
  const recorded = () => {
    const stored = existsSync(statePath) ? read(statePath) : null
    return stored?.result === digest ? stored : {}
  }
  const confirm = (fields) => {
    const candidate = `${statePath}.tmp.${process.pid}`
    writeFileSync(candidate, `${JSON.stringify({ ...recorded(), result: digest, ...fields }, null, 2)}\n`)
    renameSync(candidate, statePath)
  }
  const lost = (what) => stop(EXIT.blocked, `this command recorded ${what} for this result, but the run record no longer shows it`)
  // The PR body outside the managed sections this command publishes.
  const outside = (body) => o.sections.reduce((text, section) => text.replace(new RegExp(`<!-- dev-flow:begin:${section} -->[\\s\\S]*?<!-- dev-flow:end:${section} -->`, 'g'), ''), body)
  // What a read shows apart from the managed sections of the body: the title,
  // the four non-body fingerprint lines, and the body text outside them.
  const around = (seen) => ({ title: seen.title, lines: text(seen.lines.join('\n')), outside: text(outside(seen.body).trimEnd()) })
  const samePublish = (proof) =>
    proof?.repo === o.repo && proof.pr === Number(o.pr) && proof.head === result.head &&
    JSON.stringify(proof.sections) === JSON.stringify(o.sections)
  const intended = (own) => {
    const file = join(directory, '.publish-state.json')
    const held = existsSync(file) ? read(file) : null
    const legacy = held?.run_id === undefined && own.publish_id === undefined
    const bound = own.publish_id !== undefined && held?.run_id === o['run-id'] && held.reservation_id === own.publish_id
    return samePublish(held) && (legacy || bound) ? held.intended_fingerprint : undefined
  }
  const completed = (own) => {
    if (!own.publish_id) return undefined
    let proof
    try {
      proof = read(join(directory, '.publish-completion.json'))
    } catch {
      return undefined
    }
    if (samePublish(proof) && proof.run_id === o['run-id'] && proof.reservation_id === own.publish_id) {
      return proof.body_fingerprint
    }
  }
  // The PR body can take this result's handoff when review activity is what
  // the result last saw, or when the only difference is this command's own
  // publish: nothing outside the managed sections moved since the read it
  // recorded before the edit, and the live body is exactly the body a
  // confirmed publish reported or the one the renderer reserved or completed.
  // Both must hold: the digest alone would adopt a body
  // the renderer merged over someone else's edit outside the sections. Any
  // other live body is the moved-activity stop: never adopted, never rendered
  // over. No section it publishes may also be written by hand outside the
  // managed markers.
  const publishable = () => {
    prView()
    const seen = surfaces()
    const live = activityOf(seen)
    const own = recorded()
    const mine = own.publishing !== undefined && JSON.stringify(own.publishing) === JSON.stringify(around(seen)) &&
      [own.body, intended(own), completed(own)].includes(text(seen.body))
    if (live !== collection.snapshot.activity && !mine) {
      stop(EXIT.stale, `review activity is ${live}, not the result's final snapshot ${collection.snapshot.activity}; collect again before the handoff continues`)
    }
    const lines = outside(seen.body).split(/\r?\n/)
    for (const section of o.sections) {
      const heading = must(`render ${section}`, run('bash', [render, section, '--record', directory])).stdout.split('\n').find((line) => line.startsWith('## '))
      if (heading && lines.includes(heading)) {
        stop(EXIT.blocked, `the PR body has a hand-written "${heading}" section outside the managed markers; publishing would leave two. Move its entries into the run record and remove it, then collect again`)
      }
    }
    return seen
  }
  // A result not yet retained is checked first, so a stale one never is.
  if (!retained()) publishable()

  // 4. Retain the result. The writer validates the whole run record on every
  // call, so an invalid record (a hand-written settlement, for one) stops here
  // and is never published from. An identical replay is a no-op; a duplicate
  // wakeup answers exit 0 and retains nothing, which is not a pass to hand off.
  if (recorded().receipt !== undefined) {
    if (!retained()) lost('a receipt')
  } else {
    writer('receipt', '--pass', resultFile, ...(o['codex-state'] ? ['--codex-state', resolve(root, o['codex-state']), '--codex-repo-dir', resolve(root, o['codex-repo-dir'])] : []))
    if (!retained()) stop(EXIT.notHandoff, 'the receipt retained no pass for this result (a duplicate wakeup over unchanged state): nothing new to hand off')
    confirm({ receipt: name })
  }
  note({ kind: 'receipt', ref: name })

  // 5. Adjudication is the owner's: record a supplied document, never write
  // one. A supplied file goes to the writer, which refuses a different one for
  // an adjudicated round, unless it is byte for byte the one already recorded.
  const adjudicated = () => existsSync(adjudicationPath) ? sha(readFileSync(adjudicationPath)) : undefined
  const supplied = o.adjudication ? resolve(root, o.adjudication) : undefined
  if (recorded().adjudication !== undefined && adjudicated() !== recorded().adjudication) lost('an adjudication')
  if (supplied && !(existsSync(supplied) && sha(readFileSync(supplied)) === recorded().adjudication)) writer('adjudicate', '--file', supplied)
  if (adjudicated() !== undefined && recorded().adjudication === undefined) confirm({ adjudication: adjudicated() })
  if (adjudicated() === undefined && payload.findings.length > 0) {
    // Findings owe an adjudication whatever the verdict: a clean result can
    // carry findings whose dispositions were already applied.
    stop(EXIT.judgment, `${payload.findings.length} finding(s) of ${name} have no adjudication; re-run with --adjudication FILE`, next.kind === 'request-judgment' ? { next_action: next } : {})
  }

  // 6. The adjudicated round's evidence, published once.
  const marker = { run_id: o['run-id'], stage: 'integration', round, sequence: 1, destination: 'issue' }
  const evidenced = () => record().evidence_comments.find((comment) => ['run_id', 'stage', 'round', 'destination'].every((key) => comment.marker?.[key] === marker[key]))?.id
  if (recorded().evidence !== undefined && evidenced() !== recorded().evidence) lost('an evidence comment')
  if (adjudicated() !== undefined && recorded().evidence === undefined && evidenced() !== undefined) confirm({ evidence: evidenced() })
  if (adjudicated() !== undefined && recorded().evidence === undefined) {
    const issue = /^run-([1-9][0-9]*)-/.exec(o['run-id'])?.[1]
    if (!issue) stop(EXIT.blocked, `run id ${o['run-id']} does not name its issue`)
    scratch = mkdtempSync(join(tmpdir(), 'drive-handoff-'))
    const table = must('render round-table', run('bash', [render, 'round-table', '--record', directory, '--stage', 'integration', '--round', String(round)])).stdout.trimEnd()
    const projection = { run_id: o['run-id'], stage: 'integration', round, reviewed_head: result.head, passes: [read(passPath)], adjudication: read(adjudicationPath).adjudications }
    writeFileSync(join(scratch, 'marker.json'), JSON.stringify(marker))
    // Scan and redact the complete comment, the JSON with the table, before
    // it is posted: each span the scanner detects becomes the placeholder
    // render-dev-flow.mjs uses for its own projections. post-evidence.sh scans
    // the same bytes with the same rules and refuses whatever is left.
    const rules = join(root, '.gitleaks.toml')
    const redact = (value) => JSON.parse(must('gitleaks detect', run('gitleaks', ['detect', '--pipe', '--no-banner', '--exit-code', '0', '--report-format', 'json', '--report-path', '-',
      ...(existsSync(rules) ? ['--config', rules] : [])], { input: value })).stdout).reduce((clean, found) => clean.split(found.Secret).join(`[REDACTED:${found.RuleID}]`), value)
    writeFileSync(join(scratch, 'round.md'), redact(`**Dev flow v2 — integration round ${round}** · run \`${o['run-id']}\`\n\n${table}\n\n\`\`\`json\n${JSON.stringify(projection, null, 2)}\n\`\`\`\n`))
    must('post-evidence', run('bash', [join(here, '../../review/assets/post-evidence.sh'), '--repo', o.repo, '--repo-root', root, '--run', runPath, '--branch', lane.branch,
      '--generation', String(pointer.generation), '--active-state', pointerPath, '--head', result.head, '--actor-id', o['actor-id'], '--role', 'integrator', '--finder', 'integrator',
      '--issue', issue, '--marker-file', join(scratch, 'marker.json'), '--body-file', join(scratch, 'round.md'), '--scratch-dir', scratch]), recordLocks)
    if (evidenced() === undefined) stop(EXIT.blocked, `post-evidence returned without registering the integration round ${round} marker`)
    confirm({ evidence: evidenced() })
  }

  // An incomplete collection is never a completed handoff. Its judgment, where
  // one was owed, is recorded by now, so the answer is what it still owes.
  if (!collection.complete) {
    respond(`${name} is ${adjudicated() !== undefined ? 'adjudicated and evidenced' : 'retained'}, and its collection still owes: ${open}. Collect again once that is settled`)
  }

  // 7. The PR body, once it can still take this result.
  const before = publishable()
  // Keep the reservation identity on retry so a no-op can finish the same
  // reservation. Bind it before calling the renderer, alongside the activity
  // from before the edit.
  const publishing = around(before)
  const own = recorded()
  const publishId = (JSON.stringify(own.publishing) === JSON.stringify(publishing) && own.publish_id) || randomBytes(16).toString('hex')
  confirm({ publishing, publish_id: publishId })
  const published = run('bash', [render, 'publish', '--record', directory, '--repo', o.repo, '--pr', o.pr, '--head', result.head,
    '--sections', o.sections.join(','), '--reservation-id', publishId])
  checkTimeout('render publish', published, [], join(directory, '.publish-lock'))
  if (published.stderr) process.stderr.write(published.stderr)
  let answer
  try { answer = JSON.parse(published.stdout) } catch { stop(EXIT.blocked, `render-dev-flow publish printed no result (exit ${published.status ?? published.signal})`) }
  if (published.status !== 0 || answer.status !== 'published') {
    stop(['head-mismatch', 'head-changed-during-publish'].includes(answer.reason) ? EXIT.stale : EXIT.blocked, `render-dev-flow publish blocked: ${answer.reason}: ${answer.detail}`)
  }
  // The published body, recorded as the publish reports it and before any
  // further read: a death or a failed read below leaves it to adopt.
  confirm({ body: answer.fingerprint, publish_id: undefined })
  // Never adopt a read taken after the publish as this command's own activity,
  // whether or not the publish changed the body. What the publish must leave
  // is derived: the pre-publish read, with the body the publish verified,
  // changed only inside the managed sections. A later read that differs holds
  // someone else's activity, and the published body is no longer this
  // command's to adopt.
  const after = surfaces()
  const refuse = (message) => { confirm({ body: undefined }); stop(EXIT.stale, message) }
  if (text(after.body) !== answer.fingerprint || outside(after.body).trimEnd() !== outside(before.body).trimEnd()) {
    refuse('the PR body is not the pre-publish body with only this command\'s managed sections changed; collect again before the handoff continues')
  }
  if (activityOf(after) !== activityOf(before, after.body)) refuse('review activity moved while the PR body was published; collect again before the handoff continues')
  return { detail: `Handoff rendered for ${name}${adjudicated() !== undefined ? ', adjudicated and evidenced' : ' (no findings, no adjudication)'}. Run the integration exit (dev-flow-exit.sh --stage integration), then the handoff check.${answer.changed ? ' The PR body edit re-triggers the guard checks: read CI on this head again first.' : ''}` }
}

async function handoff({ args, port, interrupted }) {
  let context
  let code = EXIT.rendered
  let fields = {}
  const evidence = []
  try {
    fields = await main(parse(args), (value) => { context = value },
      (item) => { if (!evidence.some((seen) => seen.kind === item.kind && seen.ref === item.ref)) evidence.push(item) })
  } catch (error) {
    if (Atomics.load(interrupted, 0)) return
    // Anything unanticipated (an unreadable record, unparsable tool output) is
    // indeterminate, and an indeterminate step never advances the handoff.
    process.stderr.write(`${tool}: ${error.message}\n`)
    const timedOut = error.code === 'ETIMEDOUT'
    code = timedOut ? EXIT.retry : error instanceof Stop ? error.code : EXIT.blocked
    // A waiting, retry or stop result keeps its own next_action; every other
    // stop names its reason, and a judgment stop says what the owner owes.
    fields = error instanceof Stop ? error.fields : {}
    if (timedOut || code === EXIT.judgment) fields = { ...fields, detail: error.message }
    else if (code !== EXIT.retry && !fields.next_action) fields = { next_action: { kind: 'stop', reason: error.message || `${tool} stopped` } }
  } finally {
    if (scratch) rmSync(scratch, { recursive: true, force: true })
    port.close()
  }
  if (context) {
    const { mapStageExit } = await import(pathToFileURL(join(support, 'lib/stage-outcome.mjs')).href)
    if (Atomics.load(interrupted, 0)) return
    const outcome = mapStageExit(tool, code, { ...context, attempt: 1 })
    parentPort.postMessage({ ...outcome, ...fields, evidence: [...outcome.evidence, ...evidence] })
  }
  process.exitCode = code
}

async function drive(args) {
  const interrupted = new Int32Array(new SharedArrayBuffer(4))
  const { port1, port2 } = new MessageChannel()
  const worker = (role, port, data) => new Worker(new URL(import.meta.url), { workerData: { role, port, ...data }, transferList: [port] })
  const supervisor = worker('supervisor', port1, { interrupted })
  const forward = (signal) => {
    if (Atomics.compareExchange(interrupted, 0, 0, INTERRUPTS.indexOf(signal) + 1) === 0) supervisor.postMessage(signal)
  }
  for (const signal of INTERRUPTS) process.on(signal, forward)
  const driver = worker('handoff', port2, { args, interrupted })
  let outcome
  driver.once('message', (value) => { outcome = value })
  const exited = (thread) => new Promise((resolve, reject) => {
    thread.once('error', reject)
    thread.once('exit', resolve)
  })
  const supervisorExit = exited(supervisor)
  try {
    const [code] = await Promise.all([exited(driver), supervisorExit.then((status) => {
      if (status !== 0) throw new Error(`command supervisor exited with status ${status}`)
    })])
    process.exitCode = code
  } catch (error) {
    await driver.terminate()
    // Closing the driver's port gives the supervisor time to kill active work.
    await supervisorExit.catch(() => {})
    process.stderr.write(`${tool}: ${error.message}\n`)
    process.exitCode = EXIT.blocked
  } finally {
    for (const signal of INTERRUPTS) process.off(signal, forward)
  }
  const signal = INTERRUPTS[Atomics.load(interrupted, 0) - 1]
  if (signal) process.kill(process.pid, signal)
  else if (outcome) process.stdout.write(`${JSON.stringify(outcome)}\n`)
}

if (!isMainThread && workerData?.role === 'supervisor') superviseRequests(workerData)
else if (!isMainThread && workerData?.role === 'handoff') await handoff(workerData)
else if (isMainThread && process.argv[1] && existsSync(process.argv[1]) && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) await drive(process.argv.slice(2))
