#!/usr/bin/env node
// advance-to-integration.mjs — the body of advance-to-integration.sh
// (harmon-devkit#1920). The wrapper's header is the documented contract:
// usage, the exit list the stage-outcome table maps, and the resume rules.
import { readFileSync, existsSync, realpathSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { createHash } from 'node:crypto'
import { join, resolve, dirname } from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const tool = 'advance-to-integration.sh'
const usage = `usage: ${tool} --repo OWNER/REPO --slate ID --session ID --run-id ID --title TEXT --body-file FILE [--repo-root DIR] [--owner-token TOKEN] [--exit-engine FILE] [--merge-base-policy FILE|--merge-base-policy-absent] [--security-timeout-sec N]`
const EXIT = { afterCi: 0, withPush: 10, noCycle: 11, blocked: 2, security: 3, judgment: 4, draft: 5 }

class Stop extends Error {
  constructor(code, message) { super(message); this.code = code }
}
const stop = (code, message) => { throw new Stop(code, message) }
let scratch

function parse(argv) {
  const values = ['repo', 'slate', 'session', 'run-id', 'title', 'body-file', 'repo-root', 'owner-token', 'exit-engine', 'merge-base-policy', 'security-timeout-sec']
  const o = {}
  for (let i = 0; i < argv.length; i++) {
    const name = argv[i].replace(/^--/, '')
    if (argv[i] === '--merge-base-policy-absent' && o[name] === undefined) { o[name] = true; continue }
    if (!argv[i].startsWith('--') || !values.includes(name) || argv[i + 1] === undefined || o[name] !== undefined) stop(EXIT.blocked, usage)
    o[name] = argv[++i]
  }
  if (['repo', 'slate', 'session', 'run-id', 'title', 'body-file'].some((n) => !o[n])) stop(EXIT.blocked, usage)
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(o.repo) || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(o['run-id'])) stop(EXIT.blocked, 'invalid --repo or --run-id')
  if (o['merge-base-policy'] && o['merge-base-policy-absent']) stop(EXIT.blocked, 'conflicting merge-base policy arguments')
  o.timeout = Number(o['security-timeout-sec'] ?? 900)
  if (!Number.isInteger(o.timeout) || o.timeout < 1) stop(EXIT.blocked, '--security-timeout-sec must be a positive integer')
  o.token = o['owner-token'] ?? process.env.RUN_RECORD_OWNER_TOKEN
  if (!o.token) stop(EXIT.blocked, 'owner token required; acquire the slate lock first')
  return o
}

async function main(o, bind) {
  const root = realpathSync(o['repo-root'] ?? process.cwd())
  const run = (command, argv, options = {}) => spawnSync(command, argv, { cwd: root, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024, ...options })
  const must = (code, what, r, accepted = [0]) => {
    if (r.error || !accepted.includes(r.status)) {
      if (r.stderr) process.stderr.write(r.stderr)
      stop(code, `${what} failed (exit ${r.status ?? r.signal ?? 'unknown'})`)
    }
    return r
  }
  const git = (...a) => must(EXIT.blocked, `git ${a[0]}`, run('git', a)).stdout.trim()
  const read = (p) => JSON.parse(readFileSync(p, 'utf8'))
  const support = here
  const { branchHead, assertRunOwner, checkSlateLock, stateRoot } = await import(pathToFileURL(join(support, 'run-record.mjs')).href)
  const { codexRequired } = await import(pathToFileURL(join(support, 'lib/integration-finder-requirements.mjs')).href)

  // 1. Capture the head and the run identity every later outcome is bound to.
  const common = git('rev-parse', '--path-format=absolute', '--git-common-dir')
  const directory = join(common, 'dev-flow-v2/runs', o['run-id'])
  let lane
  try { lane = branchHead(directory, root) } catch (error) { stop(EXIT.blocked, error.message) }
  const pointerPath = join(common, 'dev-flow-v2/active', `${createHash('sha256').update(lane.branch, 'utf8').digest('hex')}.json`)
  const pointer = existsSync(pointerPath) ? read(pointerPath) : null
  if (pointer?.run_id !== o['run-id'] || !Number.isInteger(pointer?.generation) || pointer.generation < 1) stop(EXIT.blocked, `run ${o['run-id']} is not the active run of branch ${lane.branch}`)
  bind({ run: { run_id: o['run-id'], generation: pointer.generation }, head: lane.head })
  const head = lane.head
  const record = read(join(directory, 'run.json'))
  const policy = read(join(directory, 'policy.json'))
  if (record.outcome !== null) stop(EXIT.blocked, `run already ended with outcome ${record.outcome}`)
  // Prove owner authority over this run before any gate, PR or record write:
  // the slate owns the run, and the token owns that slate's lock (in process,
  // so the token stays off argv).
  try {
    const { root: state } = stateRoot(root)
    assertRunOwner(state, o.slate, o['run-id'])
    checkSlateLock({ root: state, slate: o.slate, session: o.session, ownerToken: o.token })
  } catch (error) { stop(EXIT.blocked, error.message) }
  const writer = (command, ...a) => must(EXIT.blocked, `run-record ${command}`, run(process.execPath, [join(support, 'run-record.mjs'), command, '--slate', o.slate, '--session', o.session, '--run-id', o['run-id'], ...a], { env: { ...process.env, RUN_RECORD_OWNER_TOKEN: o.token } }))
  const prJson = (ref) => JSON.parse(must(EXIT.draft, 'gh pr view', run('gh', ['pr', 'view', ref, '--repo', o.repo, '--json', 'number,url,state,isDraft,headRefOid'])).stdout)

  const transitions = record.stage_transitions
  const active = transitions.at(-1).stage
  const caps = policy.rounds

  // An open draft at exactly this head, or the chain stops.
  const verified = (ref) => {
    const pr = prJson(ref)
    if (pr.state !== 'OPEN' || pr.isDraft !== true || pr.headRefOid !== head) stop(EXIT.draft, `PR #${pr.number} is not an open draft at ${head} (isDraft ${pr.isDraft}, head ${pr.headRefOid})`)
    return pr
  }
  // Same-repository PRs only: `--head` matches a fork's same-named branch too.
  const openPr = () => {
    const listed = JSON.parse(must(EXIT.draft, 'gh pr list', run('gh', ['pr', 'list', '--repo', o.repo, '--head', lane.branch, '--state', 'open', '--json', 'number,url,isDraft,headRefOid,headRepository,headRepositoryOwner'])).stdout)
      .filter((p) => `${p.headRepositoryOwner?.login}/${p.headRepository?.name}`.toLowerCase() === o.repo.toLowerCase())
    if (listed.length > 1) stop(EXIT.draft, `branch ${lane.branch} has ${listed.length} open PRs`)
    return listed[0]
  }

  // 2. Integration already entered: bind the draft if a crash preceded it, then
  // re-confirm the bound draft and re-emit the next action.
  if (active === 'integration') {
    if (transitions.filter((t) => t.stage === 'integration').length !== 1 || transitions.at(-2)?.stage !== 'security') stop(EXIT.blocked, 'integration was not entered by this command; nothing to advance')
    // The head the gates ran on is the one this command wrote into the
    // security exit; a branch that moved since then is not that head.
    const gated = / at ([0-9a-f]{40});/.exec(transitions.at(-2).exit ?? '')?.[1]
    if (gated !== head) stop(EXIT.judgment, `integration was entered at ${gated ?? 'an unrecorded head'}, but the branch head is ${head}`)
    if (record.pr) verified(String(record.pr.number))
    else {
      const found = openPr()
      if (!found) stop(EXIT.draft, `integration was entered but branch ${lane.branch} has no open PR to bind`)
      const pr = verified(String(found.number))
      writer('bind-pr', '--number', String(pr.number), '--url', pr.url)
    }
    return nextAction()
  }

  // 3. The confidence stage being left, and its advance verdict on this head.
  const leaving = active === 'security' ? transitions.at(-2)?.stage : active
  let stage
  if (leaving === 'review') stage = 'review'
  else if (leaving === 'challenge') {
    if (caps.review > 0) stop(EXIT.judgment, `challenge advanced but review's cap is ${caps.review}: review is owed before integration`)
    stage = 'challenge'
  } else if (leaving === 'verify') {
    if (caps.challenge > 0 || caps.review > 0) stop(EXIT.judgment, `verify is active but a confidence stage with a positive cap is owed (challenge ${caps.challenge}, review ${caps.review})`)
    stage = 'review'
  } else stop(EXIT.blocked, `active stage ${active} is not a confidence stage or its security handoff`)
  // A clean checkout of the head before the verdict: an uncommitted policy edit
  // must never decide a verdict, record a transition or reach the gate.
  const cleanCheckout = (when) => {
    if (git('rev-parse', 'HEAD') !== head || git('status', '--porcelain') !== '') stop(EXIT.security, `worktree ${root} is not a clean checkout of ${head} ${when}`)
  }
  cleanCheckout('before the verdict')
  if (active === stage && caps[stage] > 0) writer('ledger', '--stage', stage)
  const engine = o['exit-engine'] ? realpathSync(resolve(root, o['exit-engine'])) : join(support, 'dev-flow-exit.mjs')
  const engineArgs = ['--run', directory, '--stage', stage, '--policy', join(root, '.devflow.toml'), '--rigor', policy.rigor.level, '--current-head', head, '--repo-root', lane.repoRoot, '--json']
  for (const [flag, file] of [['--history', `history.${stage}.json`], ['--heads', 'heads.json']]) if (existsSync(join(directory, file))) engineArgs.push(flag, join(directory, file))
  if (o['merge-base-policy']) engineArgs.push('--merge-base-policy', resolve(root, o['merge-base-policy']))
  else if (o['merge-base-policy-absent']) engineArgs.push('--merge-base-policy-absent')
  else {
    // A branch never chooses the policy that governs its own advance: derive
    // the merge base's with the engine's sibling helper, mapped as integrate's
    // mb_args maps it. Any other answer, or a failed derivation, blocks.
    const base = git('merge-base', git('symbolic-ref', 'refs/remotes/origin/HEAD'), head)
    scratch = mkdtempSync(join(tmpdir(), 'advance-to-integration-'))
    const materialized = join(scratch, 'devflow.toml')
    const answer = must(EXIT.blocked, 'merge-base policy derivation', run('bash', [join(dirname(engine), 'lib/merge-base-policy.sh'), base, engine, materialized, join(root, '.devflow.toml')])).stdout.trim()
    if (answer === 'present') engineArgs.push('--merge-base-policy', materialized)
    else if (answer === 'absent') engineArgs.push('--merge-base-policy-absent')
    else if (answer !== 'none') stop(EXIT.blocked, `merge-base policy derivation answered ${JSON.stringify(answer)}`)
  }
  const compute = (...extra) => {
    const r = must(EXIT.blocked, 'exit engine', run(process.execPath, [engine, ...engineArgs, ...extra]), [0, 20, 21, 22])
    const projection = JSON.parse(r.stdout)
    const rejected = (projection.diagnostics ?? []).filter((d) => d.level === 'reject')
    if (projection.stage !== stage || rejected.length) stop(EXIT.blocked, `exit engine evidence rejected: ${rejected.map((d) => d.reason).join('; ') || 'stage mismatch'}`)
    return projection
  }
  const verdict = compute()
  if (verdict.action !== 'advance') stop(EXIT.judgment, `${stage} verdict is ${verdict.outcome}/${verdict.reason} (action ${verdict.action}), not advance`)
  const last = (compute('--verification-only').rounds ?? []).at(-1)
  if (last && last.reviewed_head !== head) stop(EXIT.judgment, `${stage} round ${last.round} reviewed ${last.reviewed_head}, but the branch head is ${head}`)
  if (active !== 'security') writer('transition', '--stage', 'security', '--exit', `${verdict.outcome}: ${verdict.reason}${last ? `, round ${last.round}` : ''} at ${head}`)

  // 4. The configured pre-PR gate on exactly this head. Only exit 0 passes.
  const target = policy.gates?.pre_pr
  if (typeof target !== 'string' || target === '') stop(EXIT.security, 'the run policy names no pre_pr gate')
  const gate = run('task', [target], { stdio: ['ignore', 2, 2], timeout: o.timeout * 1000, killSignal: 'SIGKILL' })
  if (gate.error || gate.status !== 0) stop(EXIT.security, `pre_pr gate task ${target} did not pass (${gate.error?.code ?? (gate.status === null ? `signal ${gate.signal}` : `exit ${gate.status}`)})`)
  cleanCheckout('after the pre_pr gate')

  // 5. The draft: adopt one already opened for this head, else publish it.
  let pr = openPr()
  if (!pr) {
    const body = readFileSync(resolve(root, o['body-file']), 'utf8')
    const guard = run('task', ['guard:closing-keywords'], { stdio: ['ignore', 2, 2], env: { ...process.env, PR_TITLE: o.title, PR_BODY: body } })
    if (guard.error || guard.status !== 0) stop(EXIT.draft, `closing-keywords preflight did not pass (exit ${guard.status ?? guard.signal})`)
    // The supported topology: origin is the repository the PR targets.
    const remote = git('ls-remote', 'origin', `refs/heads/${lane.branch}`).split(/\s+/)[0]
    if (remote !== head) stop(EXIT.draft, `remote branch ${lane.branch} is at ${remote || 'nothing'}, not ${head}; push it first`)
    const created = must(EXIT.draft, 'gh pr create', run('gh', ['pr', 'create', '--draft', '--repo', o.repo, '--head', lane.branch, '--title', o.title, '--body-file', resolve(root, o['body-file'])])).stdout.trim().split('\n').at(-1)
    pr = { number: created }
  }
  pr = verified(String(pr.number))

  // 6. Resolve the next action, enter integration, then bind (the run schema
  // binds a PR only once integration is recorded; a crash between the two
  // resumes at step 2). A missing checker or trigger blocks before entry.
  const next = nextAction()
  writer('transition', '--stage', 'integration', '--exit', `security: ${target} exit 0 at ${head}; draft PR #${pr.number}`)
  writer('bind-pr', '--number', String(pr.number), '--url', pr.url)
  return next

  // 7. The next action: this command posts no review request itself.
  function nextAction() {
    if (!codexRequired(record, policy)) return EXIT.noCycle
    const checker = join(support, '../../integrate/assets/check-codex-cloud-review.sh')
    const timing = JSON.parse(must(EXIT.blocked, 'trigger-timing', run('bash', [checker, 'trigger-timing', '--review-trigger', policy.stages.integration.review_trigger, '--remediation', '0'])).stdout)
    return timing.order === 'with-push' ? EXIT.withPush : EXIT.afterCi
  }
}

let context
let code
try {
  code = await main(parse(process.argv.slice(2)), (value) => { context = value })
} catch (error) {
  // Anything unanticipated (an unreadable record, unparsable tool output) is
  // indeterminate, and an indeterminate step never advances the run.
  process.stderr.write(`${tool}: ${error.message}\n`)
  code = error instanceof Stop ? error.code : EXIT.blocked
} finally {
  if (scratch) rmSync(scratch, { recursive: true, force: true })
}
if (context) {
  const { mapStageExit } = await import(pathToFileURL(join(here, 'lib/stage-outcome.mjs')).href)
  process.stdout.write(`${JSON.stringify(mapStageExit(tool, code, context))}\n`)
}
process.exitCode = code
