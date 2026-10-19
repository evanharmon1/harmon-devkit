#!/usr/bin/env node
// plan-revise.mjs — the mechanical half of a dispatch-plan recompute
// (`<git-common-dir>/dev-flow-v2/slates/<slate-id>/plan.json`,
// harmon-devkit#1296).
//
// Usage:
//   plan-revise.mjs base-move --slate ID --session ID --new-base SHA --reason TEXT
//                             [--done N]... [--at TS] [--milestone N] [--issues N,N,...]
//
// Writes require --owner-token TOKEN or RUN_RECORD_OWNER_TOKEN from a prior
// visible run-record.mjs lock acquire; pass its printed token literally.
//
// Appends one revision for a default-branch move: `base_sha` becomes the new
// base, every `--done` issue keeps its verified record as `verdict: "done"`
// (orchestrate § Planning step 2: never erase a verdict) and leaves every
// dispatch structure — waves, lanes, lane_profiles, overlaps — and a wave the
// removal empties is dropped with the later waves renumbered in order. The
// revision is chained (seq, prev_digest, digest over the canonical
// {seq, plan, at, reason, prev_digest}) and published through the candidate,
// `validate-result-schemas.mjs plan`, rename, readback sequence.
//
// Everything that is orchestrator judgment is refused, naming what needs it,
// rather than written:
//   - the commits between the old and new base touch a live lane's effective
//     fence (fence + expansions) or a live issue's candidate files — the lane
//     may need a rebase, a fence change, or a re-verification;
//   - a done issue releases a dependent — a live issue lists it in
//     `blocked_by`, or an overlap's merge dependency names it as `before` —
//     because releasing it is a wave/queue decision;
//   - a live fence or candidate pattern has a component combining a bracket
//     class with `*`/`?`, or holding a backslash — such a pattern is never
//     interpreted here, so any move needs judgment;
//   - the new base does not descend from the old one, or nothing moved;
//   - the repository has an info/grafts file (replace refs are ignored).
// The existing plan is validated before anything else, so a broken chain is
// refused too. Both writers take the slate lock (see run-record.mjs).
//
// Exit codes: 0 written, 1 refused, 2 usage.

import { execFileSync } from 'node:child_process'
import { existsSync, realpathSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  Refusal,
  UsageError,
  acquireSlateLock,
  chainDigest,
  isBefore,
  parseFlags,
  parseScopeFlags,
  readJson,
  requireId,
  resolveAt,
  runCli,
  stateRoot,
  validateFile,
  withMutex,
  writeValidated,
} from './run-record.mjs'

// Every git call reads the real objects: replace refs are disabled, so an
// overridden history cannot hide a moved path (a grafts file, which no flag
// disables, is refused in baseMove).
function git(args) {
  return execFileSync('git', ['--no-replace-objects', ...args], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, GIT_NO_REPLACE_OBJECTS: '1' },
  })
}

function resolveCommit(value, label) {
  try {
    return git(['rev-parse', '--verify', '--quiet', `${value}^{commit}`]).trim()
  } catch {
    throw new Refusal(`${label} ${value} is not a commit in this repository`)
  }
}

// Fence matching mirrors orchestrate/assets/fence-check.sh: per path
// component, literal first; a component holding `*` or `?` is a glob within
// that component (`{` and a bare `[x]` stay literal), and a `**` component
// matches any number of components. A component this matcher cannot
// interpret the same way never gets here (see uninterpretable).
function componentMatches(part, pattern) {
  if (part === pattern) return true
  if (!/[*?]/.test(pattern)) return false
  const source = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.')
  // s and u: `?`/`*` match any code point, line breaks included, as bash case does.
  return new RegExp(`^${source}$`, 'su').test(part)
}

function matchParts(pattern, path, pi = 0, qi = 0) {
  if (pi === pattern.length) return qi === path.length
  if (pattern[pi] === '**') {
    for (let next = qi; next <= path.length; next += 1) if (matchParts(pattern, path, pi + 1, next)) return true
    return false
  }
  return qi < path.length && componentMatches(path[qi], pattern[pi]) && matchParts(pattern, path, pi + 1, qi + 1)
}

export function pathMatches(path, pattern) {
  return matchParts(pattern.split('/'), path.split('/'))
}

// uninterpretable — a component combining a bracket class with `*`/`?`, or
// holding a backslash, means something to fence-check.sh this matcher does
// not reproduce.
function uninterpretable(pattern) {
  return pattern.split('/').some((part) => part.includes('\\') || (part.includes('[') && /[*?]/.test(part)))
}

function fencePaths(lane) {
  return [
    ...(lane.fence ?? []).map((item) => (typeof item === 'string' ? item : item?.path)).filter(Boolean),
    ...(lane.expansions ?? []).map((entry) => entry.path).filter(Boolean),
  ]
}

export function reviseForBaseMove(previous, { newBase, done, changed }) {
  const plan = structuredClone(previous)
  const doneSet = new Set(done)
  const known = new Set(plan.issues.map((issue) => issue.number))
  const unknown = done.filter((number) => !known.has(number))
  if (unknown.length > 0) throw new Refusal(`--done names issue(s) not in the plan: ${unknown.join(', ')}`)

  const live = plan.issues.filter((issue) => issue.verdict !== 'done' && !doneSet.has(issue.number))
  const refusals = []
  for (const issue of live) {
    for (const blocker of issue.blocked_by ?? []) {
      if (doneSet.has(blocker)) refusals.push(`done issue #${blocker} releases dependent #${issue.number} (blocked_by)`)
    }
  }
  for (const overlap of plan.overlaps) {
    const dependency = overlap.merge_dependency
    if (dependency && doneSet.has(dependency.before) && !doneSet.has(dependency.after)) {
      refusals.push(`done issue #${dependency.before} releases dependent #${dependency.after} (merge dependency)`)
    }
  }
  // A pattern this helper cannot interpret makes any move need judgment
  // instead of being matched by a second glob engine.
  if (changed.length > 0) {
    const liveLanes = plan.lanes.filter((lane) => !doneSet.has(lane.issue))
    for (const pattern of [...liveLanes.flatMap(fencePaths), ...live.flatMap((issue) => issue.candidate_files ?? [])]) {
      if (uninterpretable(pattern)) refusals.push(`pattern needs orchestrator judgment (not matched here): ${pattern}`)
    }
  }
  for (const lane of plan.lanes.filter((lane) => !doneSet.has(lane.issue))) {
    const patterns = fencePaths(lane)
    for (const path of changed) {
      if (patterns.some((pattern) => pathMatches(path, pattern))) {
        refusals.push(`base move touches lane ${lane.lane} (#${lane.issue}) fence: ${path}`)
      }
    }
  }
  for (const issue of live) {
    for (const path of changed) {
      if ((issue.candidate_files ?? []).some((pattern) => pathMatches(path, pattern))) {
        refusals.push(`base move touches issue #${issue.number} candidate file: ${path}`)
      }
    }
  }
  if (refusals.length > 0) {
    throw new Refusal(`this recompute needs orchestrator judgment; nothing was written:\n  - ${refusals.join('\n  - ')}`)
  }

  plan.base_sha = newBase
  for (const issue of plan.issues) if (doneSet.has(issue.number)) issue.verdict = 'done'
  const renumber = new Map()
  plan.waves = plan.waves
    .map((wave) => ({ ...wave, issues: wave.issues.filter((number) => !doneSet.has(number)) }))
    .filter((wave) => wave.issues.length > 0)
    .sort((a, b) => a.number - b.number)
    .map((wave, index) => {
      renumber.set(wave.number, index + 1)
      return { ...wave, number: index + 1 }
    })
  plan.lanes = plan.lanes
    .filter((lane) => !doneSet.has(lane.issue))
    .map((lane) => ({ ...lane, wave: renumber.get(lane.wave) ?? lane.wave }))
  if (plan.lane_profiles !== undefined) {
    const lanes = new Set(plan.lanes.map((lane) => lane.lane))
    plan.lane_profiles = plan.lane_profiles.filter((entry) => lanes.has(entry.lane))
  }
  plan.overlaps = plan.overlaps.filter((overlap) => !doneSet.has(overlap.issue_a) && !doneSet.has(overlap.issue_b))
  return plan
}

function baseMove(args) {
  const { root } = stateRoot()
  const slate = requireId('slate', args.slate)
  const session = requireId('session', args.session)
  if (typeof args.reason !== 'string' || args.reason.trim() === '') throw new UsageError('--reason is required')
  if (typeof args['new-base'] !== 'string') throw new UsageError('--new-base is required')
  const done = (args.done ?? []).map((value) => {
    const number = Number(value)
    if (!Number.isInteger(number) || number < 1) throw new UsageError(`--done must be an issue number, got ${value}`)
    return number
  })
  const at = resolveAt(args.at)
  const canonical = join(root, 'slates', slate, 'plan.json')
  if (!existsSync(canonical)) throw new Refusal(`no plan for slate ${slate}: ${canonical}`)
  // Validated before the lock is taken, so a broken plan leaves no lock.
  validateFile('plan', canonical, `existing ${canonical}`)
  acquireSlateLock({ root, slate, session, ownerToken: args['owner-token'], milestone: args.milestone, issues: args.issues })

  return withMutex(canonical, () => {
    const document = readJson(canonical, 'plan')
    if (document.slate_id !== slate) throw new Refusal(`${canonical} records slate_id ${JSON.stringify(document.slate_id)}, not ${slate}`)
    const last = document.revisions.at(-1)
    const oldBase = last.plan.base_sha
    const grafts = git(['rev-parse', '--path-format=absolute', '--git-path', 'info/grafts']).trim()
    if (existsSync(grafts)) {
      throw new Refusal(`${grafts} exists; a grafted history cannot prove what a base move changed, refusing`)
    }
    const newBase = resolveCommit(args['new-base'], '--new-base')
    resolveCommit(oldBase, 'the plan base')
    if (newBase === oldBase) throw new Refusal(`base ${oldBase} did not move; nothing to revise`)
    try {
      git(['merge-base', '--is-ancestor', oldBase, newBase])
    } catch {
      throw new Refusal(`new base ${newBase} does not descend from the plan base ${oldBase}`)
    }
    if (isBefore(at, last.at)) throw new Refusal(`${at} precedes revision ${last.seq} (${last.at})`)
    const changed = git(['diff', '--no-relative', '--name-only', '--no-renames', '-z', oldBase, newBase]).split('\0').filter(Boolean)
    const plan = reviseForBaseMove(last.plan, { newBase, done, changed })
    const seq = document.revisions.length
    const entry = { seq, prev_digest: last.digest, at, reason: args.reason, plan }
    entry.digest = chainDigest({ seq, plan, at, reason: args.reason }, last.digest)
    document.revisions.push(entry)
    writeValidated('plan', canonical, document)
    return `appended revision ${seq}: base ${oldBase.slice(0, 12)} → ${newBase.slice(0, 12)}${done.length ? `, done ${done.map((n) => `#${n}`).join(' ')}` : ''}`
  })
}

function main(argv) {
  const [command, ...rest] = argv
  if (command !== 'base-move') throw new UsageError('plan-revise.mjs base-move … (see the header)')
  const args = parseScopeFlags(
    parseFlags(
      rest,
      new Set(['slate', 'session', 'owner-token', 'new-base', 'reason', 'done', 'at', 'milestone', 'issues']),
      new Set(),
      new Set(['done']),
    ),
  )
  return baseMove(args)
}

if (realpathSync(process.argv[1] ?? '') === realpathSync(fileURLToPath(import.meta.url))) runCli(main)
