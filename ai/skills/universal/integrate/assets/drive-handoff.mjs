#!/usr/bin/env node
// drive-handoff.mjs — the body of drive-handoff.sh (harmon-devkit#1919). The
// wrapper's header is the documented contract: usage, the ordered steps, the
// exit list the stage-outcome table maps, and the resume rules.
import { readFileSync, writeFileSync, existsSync, realpathSync, mkdtempSync, rmSync, renameSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { createHash } from 'node:crypto'
import { join, resolve, dirname } from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const support = join(here, '../../dev-flow-support/assets')
const tool = 'drive-handoff.sh'
const usage = `usage: ${tool} --repo OWNER/REPO --pr N --slate ID --session ID --run-id ID --result FILE --actor-id ID [--adjudication FILE] [--codex-state FILE --codex-repo-dir DIR] [--sections LIST] [--repo-root DIR] [--owner-token TOKEN]`
const EXIT = { rendered: 0, blocked: 2, judgment: 10, waiting: 11, retry: 12, notHandoff: 13, stale: 14 }

class Stop extends Error {
  constructor(code, message, fields = {}) { super(message); this.code = code; this.fields = fields }
}
const stop = (code, message, fields) => { throw new Stop(code, message, fields) }
let scratch

function parse(argv) {
  const values = ['repo', 'pr', 'slate', 'session', 'run-id', 'result', 'actor-id', 'adjudication', 'codex-state', 'codex-repo-dir', 'sections', 'repo-root', 'owner-token']
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
  return o
}

async function main(o, bind, note) {
  const root = realpathSync(o['repo-root'] ?? process.cwd())
  const run = (command, argv, options = {}) => spawnSync(command, argv, { cwd: root, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, ...options })
  const must = (what, r, code = EXIT.blocked) => {
    if (r.stderr) process.stderr.write(r.stderr)
    // The failed step's own last line is the reason: its refusals are prose.
    const said = (r.stderr ?? '').trim().split('\n').at(-1)
    if (r.error || r.status !== 0) stop(code, `${what} failed (exit ${r.status ?? r.signal ?? 'unknown'})${said ? `: ${said}` : ''}`)
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
  let lane
  try { lane = branchHead(directory, root) } catch (error) { stop(EXIT.blocked, error.message) }
  const pointerPath = join(common, 'dev-flow-v2/active', `${sha(Buffer.from(lane.branch, 'utf8'))}.json`)
  const pointer = existsSync(pointerPath) ? read(pointerPath) : null
  if (pointer?.run_id !== o['run-id'] || !Number.isInteger(pointer?.generation) || pointer.generation < 1) stop(EXIT.blocked, `run ${o['run-id']} is not the active run of branch ${lane.branch}`)
  bind({ run: { run_id: o['run-id'], generation: pointer.generation }, head: lane.head })
  const runPath = join(directory, 'run.json')
  const record = () => read(runPath)
  const entry = record()
  if (entry.outcome !== null) stop(EXIT.blocked, `run already ended with outcome ${entry.outcome}`)
  try {
    const { root: state } = stateRoot(root)
    assertRunOwner(state, o.slate, o['run-id'])
    checkSlateLock({ root: state, slate: o.slate, session: o.session, ownerToken: o.token })
  } catch (error) { stop(EXIT.blocked, error.message) }
  if (entry.stage_transitions.at(-1).stage !== 'integration') stop(EXIT.blocked, `the run's active stage is ${entry.stage_transitions.at(-1).stage}, not integration`)
  if (entry.pr?.number !== Number(o.pr)) stop(EXIT.blocked, `the run is bound to PR ${entry.pr ? `#${entry.pr.number}` : 'nothing'}, not #${o.pr}`)
  const writer = (command, ...a) => must(`run-record ${command}`, run(process.execPath, [join(support, 'run-record.mjs'), command, '--slate', o.slate, '--session', o.session, '--run-id', o['run-id'], ...a], { env: { ...process.env, RUN_RECORD_OWNER_TOKEN: o.token } }))

  // 2. The bounded integrator result, validated and consumed as is.
  const resultFile = resolve(root, o.result)
  let bytes
  try { bytes = readFileSync(resultFile) } catch { stop(EXIT.blocked, `result not found: ${o.result}`) }
  must('result validation', run(process.execPath, [validator, 'envelope', resultFile, '--run-id', o['run-id'], '--initiated-by', entry.initiated_by]))
  const result = JSON.parse(bytes.toString('utf8'))
  if (result.role !== 'integrator') stop(EXIT.blocked, `the result is a ${result.role} result, not an integrator result`)
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
  // The result's own next_action answers every result that is not a handoff:
  // only `continue` and `request-judgment` go on to the receipt, and only a
  // complete collection can end in progress (step 7).
  const implied = { wait: EXIT.waiting, retry: EXIT.retry, stop: EXIT.notHandoff }
  const asked = next.kind === 'request-judgment' ? { next_action: next } : {}
  const owed = collection.incomplete.length ? ` (incomplete: ${collection.incomplete.join(', ')})` : ''
  if (result.status === 'blocked') stop(EXIT.notHandoff, `the result is blocked${owed}`, next.kind === 'stop' ? { next_action: next } : {})
  if (next.kind !== 'continue' && next.kind !== 'request-judgment') {
    stop(implied[next.kind] ?? EXIT.notHandoff, `the result's next action is ${next.kind}${owed}`, implied[next.kind] ? { next_action: next } : {})
  }

  // 3. One commit on an open draft: the result's head, the branch head, the PR head.
  const prView = () => {
    const pr = JSON.parse(must('gh pr view', run('gh', ['pr', 'view', o.pr, '--repo', o.repo, '--json', 'state,isDraft,headRefOid'])).stdout)
    if (pr.headRefOid !== result.head) stop(EXIT.stale, `the PR head is ${pr.headRefOid}, not the result's head ${result.head}; a result is receipted before its head moves`)
    if (pr.state !== 'OPEN' || pr.isDraft !== true) stop(EXIT.blocked, `PR #${o.pr} is not an open draft (state ${pr.state}, isDraft ${pr.isDraft})`)
    return pr
  }
  if (result.head !== lane.head) stop(EXIT.stale, `the result reviewed ${result.head}, but ${lane.branch} is at ${lane.head}`)
  // Review activity is the readiness gate's five-surface fingerprint,
  // computed here from one read with the gate's own projections, so the value
  // this command's body edit must leave can be derived instead of read back.
  const gh = (...argv) => must(`gh ${argv[0]} ${argv.at(-1).slice(0, 60)}`, run('gh', argv)).stdout
  const surfaces = () => {
    const [owner, repository] = o.repo.split('/')
    const list = (path) => gh('api', '--paginate', '--slurp', `repos/${o.repo}/${path}`)
    const pr = JSON.parse(gh('api', `repos/${o.repo}/pulls/${o.pr}`))
    if (typeof pr.title !== 'string' || (pr.body !== null && typeof pr.body !== 'string')) stop(EXIT.blocked, 'the PR object carries no usable title and body')
    return { title: pr.title, body: pr.body ?? '', reviews: list(`pulls/${o.pr}/reviews`), top: list(`issues/${o.pr}/comments`), inline: list(`pulls/${o.pr}/comments`),
      threads: gh('api', 'graphql', '--paginate', '--slurp', '-F', `owner=${owner}`, '-F', `name=${repository}`, '-F', `pr=${o.pr}`, '-f',
        'query=query($owner:String!,$name:String!,$pr:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$pr){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{id isResolved comments(first:1){nodes{databaseId}}}}}}}') }
  }
  const project = (flags, filter, input) => must('jq', run('jq', [flags, filter], { input })).stdout.trimEnd()
  const comments = 'add // [] | map({id, u:.user.login, b:.body, t:.updated_at}) | sort_by(.id)'
  const activityOf = (seen, body = seen.body) => sha(Buffer.from([
    project('-cS', '.', JSON.stringify({ title: seen.title, body })),
    project('-c', 'add // [] | map({id, u:.user.login, s:.state, b:.body, t:.submitted_at}) | sort_by(.id)', seen.reviews),
    project('-c', comments, seen.top),
    project('-c', comments, seen.inline),
    project('-c', '[.[].data.repository.pullRequest.reviewThreads.nodes[]] | map({id, r:.isResolved}) | sort_by(.id)', seen.threads),
  ].map((line) => `${line}\n`).join(''), 'utf8'))
  const statePath = join(directory, 'drive-handoff.json')
  const digest = sha(bytes)
  // The PR body outside the managed sections this command publishes.
  const outside = (body) => o.sections.reduce((text, section) => text.replace(new RegExp(`<!-- dev-flow:begin:${section} -->[\\s\\S]*?<!-- dev-flow:end:${section} -->`, 'g'), ''), body)
  // The PR body can take this result's handoff when review activity is what
  // the result last saw, or the value derived for this command's own earlier
  // publish of this same result, and no section it publishes was also written
  // by hand outside the managed markers.
  const publishable = () => {
    prView()
    const seen = surfaces()
    const live = activityOf(seen)
    const own = existsSync(statePath) ? read(statePath) : null
    if (live !== collection.snapshot.activity && !(own?.result === digest && own.activity === live)) {
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
  const passPath = join(directory, 'passes', `${name}.json`)
  const retained = () => record().receipts.some((receipt) => receipt.kind === 'pass' && receipt.file === name) && existsSync(passPath) && readFileSync(passPath).equals(bytes)
  // A result not yet retained is checked first, so a stale one never is.
  if (retained()) prView()
  else publishable()

  // 4. Retain the result. The writer validates the whole run record on every
  // call, so an invalid record (a hand-written settlement, for one) stops here
  // and is never published from. An identical replay is a no-op; a duplicate
  // wakeup answers exit 0 and retains nothing, which is not a pass to hand off.
  writer('receipt', '--pass', resultFile, ...(o['codex-state'] ? ['--codex-state', resolve(root, o['codex-state']), '--codex-repo-dir', resolve(root, o['codex-repo-dir'])] : []))
  if (!retained()) stop(EXIT.notHandoff, 'the receipt retained no pass for this result (a duplicate wakeup over unchanged state): nothing new to hand off')
  note({ kind: 'receipt', ref: name })

  // 5. Adjudication is the owner's: record a supplied document, never write one.
  const adjudicationPath = join(directory, 'adjudications', `integration-r${round}.json`)
  if (o.adjudication) writer('adjudicate', '--file', resolve(root, o.adjudication))
  if (!existsSync(adjudicationPath) && payload.findings.length > 0) {
    stop(EXIT.judgment, `${payload.findings.length} finding(s) of ${name} have no adjudication; re-run with --adjudication FILE`, asked)
  }

  // 6. The adjudicated round's evidence, published once.
  const marker = { run_id: o['run-id'], stage: 'integration', round, sequence: 1, destination: 'issue' }
  const registered = () => record().evidence_comments.some((comment) => ['run_id', 'stage', 'round', 'destination'].every((key) => comment.marker?.[key] === marker[key]))
  if (existsSync(adjudicationPath) && !registered()) {
    const issue = /^run-([1-9][0-9]*)-/.exec(o['run-id'])?.[1]
    if (!issue) stop(EXIT.blocked, `run id ${o['run-id']} does not name its issue`)
    scratch = mkdtempSync(join(tmpdir(), 'drive-handoff-'))
    const table = must('render round-table', run('bash', [render, 'round-table', '--record', directory, '--stage', 'integration', '--round', String(round)])).stdout.trimEnd()
    const projection = { run_id: o['run-id'], stage: 'integration', round, reviewed_head: result.head, passes: [read(passPath)], adjudication: read(adjudicationPath).adjudications }
    writeFileSync(join(scratch, 'marker.json'), JSON.stringify(marker))
    writeFileSync(join(scratch, 'round.md'), `**Dev flow v2 — integration round ${round}** · run \`${o['run-id']}\`\n\n${table}\n\n\`\`\`json\n${JSON.stringify(projection, null, 2)}\n\`\`\`\n`)
    must('post-evidence', run('bash', [join(here, '../../review/assets/post-evidence.sh'), '--repo', o.repo, '--repo-root', root, '--run', runPath, '--branch', lane.branch,
      '--generation', String(pointer.generation), '--active-state', pointerPath, '--head', result.head, '--actor-id', o['actor-id'], '--role', 'integrator', '--finder', 'integrator',
      '--issue', issue, '--marker-file', join(scratch, 'marker.json'), '--body-file', join(scratch, 'round.md'), '--scratch-dir', scratch]))
    if (!registered()) stop(EXIT.blocked, `post-evidence returned without registering the integration round ${round} marker`)
  }

  // An incomplete collection is never a completed handoff. What it owes is the
  // result's own next_action, whatever this command has recorded for it.
  if (!collection.complete) {
    stop(next.kind === 'request-judgment' ? EXIT.judgment : EXIT.notHandoff,
      `${name} is ${existsSync(adjudicationPath) ? 'adjudicated and evidenced' : 'retained'}, but its collection is incomplete (${collection.incomplete.join(', ')}); finish what it owes, then collect again`, asked)
  }

  // 7. The PR body, once it can still take this result.
  const before = publishable()
  const published = run('bash', [render, 'publish', '--record', directory, '--repo', o.repo, '--pr', o.pr, '--head', result.head, '--sections', o.sections.join(',')])
  if (published.stderr) process.stderr.write(published.stderr)
  let answer
  try { answer = JSON.parse(published.stdout) } catch { stop(EXIT.blocked, `render-dev-flow publish printed no result (exit ${published.status ?? published.signal})`) }
  if (published.status !== 0 || answer.status !== 'published') {
    stop(['head-mismatch', 'head-changed-during-publish'].includes(answer.reason) ? EXIT.stale : EXIT.blocked, `render-dev-flow publish blocked: ${answer.reason}: ${answer.detail}`)
  }
  if (answer.changed) {
    // Never adopt a read taken after the write as this command's own activity.
    // What the edit must leave is derived: the pre-publish read, with the body
    // the publish verified it wrote, changed only inside the managed sections.
    // A later read that differs holds someone else's activity.
    const after = surfaces()
    if (sha(Buffer.from(after.body, 'utf8')) !== answer.fingerprint || outside(after.body).trimEnd() !== outside(before.body).trimEnd()) {
      stop(EXIT.stale, 'the PR body is not the pre-publish body with only this command\'s managed sections changed; collect again before the handoff continues')
    }
    const expected = activityOf(before, after.body)
    if (activityOf(after) !== expected) stop(EXIT.stale, 'review activity moved while the PR body was published; collect again before the handoff continues')
    const candidate = `${statePath}.tmp.${process.pid}`
    writeFileSync(candidate, `${JSON.stringify({ result: digest, activity: expected }, null, 2)}\n`)
    renameSync(candidate, statePath)
  }
  return { detail: `Handoff rendered for ${name}${existsSync(adjudicationPath) ? ', adjudicated and evidenced' : ' (no findings, no adjudication)'}. Run the integration exit (dev-flow-exit.sh --stage integration), then the handoff check.${answer.changed ? ' The PR body edit re-triggers the guard checks: read CI on this head again first.' : ''}` }
}

let context
let code = EXIT.rendered
let fields = {}
const evidence = []
try {
  fields = await main(parse(process.argv.slice(2)), (value) => { context = value },
    (item) => { if (!evidence.some((seen) => seen.kind === item.kind && seen.ref === item.ref)) evidence.push(item) })
} catch (error) {
  // Anything unanticipated (an unreadable record, unparsable tool output) is
  // indeterminate, and an indeterminate step never advances the handoff.
  process.stderr.write(`${tool}: ${error.message}\n`)
  code = error instanceof Stop ? error.code : EXIT.blocked
  // A waiting, retry or stop result keeps its own next_action; every other
  // stop names its reason, and a judgment stop says what the owner owes.
  fields = error instanceof Stop ? error.fields : {}
  if (code === EXIT.judgment) fields = { ...fields, detail: error.message }
  else if (!fields.next_action) fields = { next_action: { kind: 'stop', reason: error.message || `${tool} stopped` } }
} finally {
  if (scratch) rmSync(scratch, { recursive: true, force: true })
}
if (context) {
  const { mapStageExit } = await import(pathToFileURL(join(support, 'lib/stage-outcome.mjs')).href)
  const outcome = mapStageExit(tool, code, { ...context, attempt: 1 })
  process.stdout.write(`${JSON.stringify({ ...outcome, ...fields, evidence: [...outcome.evidence, ...evidence] })}\n`)
}
process.exitCode = code
