#!/usr/bin/env node
// label-lifecycle-audit.mjs — read-only audit of lifecycle labels on open slated
// or claimed issues and their delivery PRs.
//
// Usage:
//   label-lifecycle-audit.mjs --repo OWNER/NAME [--slate SLATE] [--rules-asset PATH]
//
// Reads never-coexist pairs and mirrored/managed state labels dynamically from
// `lifecycle-labels.sh --rules-json` and queries GitHub using read-only `gh`
// commands (only gh issue/pr list/view and --method GET gh api).
//
// Exit codes:
//   0  clean (prints `[]`)
//   1  one or more violations found (prints JSON array of violation records)
//   2  usage error, rules-read error, or GitHub read error

import { execFileSync } from 'node:child_process'
import { existsSync, realpathSync } from 'node:fs'
import process from 'node:process'
import { fileURLToPath } from 'node:url'

const REPO_PATTERN = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/
const SLATE_PATTERN = /^[A-Za-z0-9._-]+$/
const GH_MAX_BUFFER = 64 * 1024 * 1024
const TRUSTED_ASSOC = new Set(['OWNER', 'MEMBER', 'COLLABORATOR'])
const SLATE_MEMBERSHIP_RE =
  /^Slate membership:\n- session: ([A-Za-z0-9._-]+)\n- slate: ([A-Za-z0-9._-]+)\n- action: (add|remove)\s*$/
const CLAIM_BRANCH_RE = /^Claiming — .*?\bon branch ([^\s]+)(?: \(session .*\))?\.?$/
const HANDOFF_RELEASE_RE = /handoff check passed|plan-revise handoff|parked in merge queue/i

const USAGE = `Usage: label-lifecycle-audit.mjs --repo OWNER/NAME [--slate SLATE] [--rules-asset PATH]

Read-only audit of lifecycle labels on open slated or claimed issues and their
delivery PRs. Reports a JSON array of violations:
  { repo, object: { type: "issue" | "pr", number }, labels, class }

Exit codes:
  0  clean
  1  violations found
  2  usage or read error`

export class AuditUsageError extends Error {}
export class AuditReadError extends Error {}

function defaultGh(argv) {
  const ghBin = process.env.LABEL_LIFECYCLE_AUDIT_GH || 'gh'
  try {
    return execFileSync(ghBin, argv, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      maxBuffer: GH_MAX_BUFFER,
    })
  } catch (error) {
    const stderr = String(error.stderr ?? '').trim()
    throw new AuditReadError(
      `gh ${argv.slice(0, 3).join(' ')} failed${stderr ? `: ${stderr}` : `: ${error.message}`}`,
    )
  }
}

function defaultReadRules(rulesAssetPath) {
  const assetPath =
    rulesAssetPath ||
    process.env.LABEL_LIFECYCLE_RULES_ASSET ||
    fileURLToPath(new URL('./lifecycle-labels.sh', import.meta.url))
  try {
    const raw = execFileSync('bash', [assetPath, '--rules-json'], {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
      maxBuffer: GH_MAX_BUFFER,
    })
    return JSON.parse(raw)
  } catch (error) {
    const stderr = String(error.stderr ?? '').trim()
    throw new AuditReadError(
      `could not load rules from ${assetPath} --rules-json${stderr ? `: ${stderr}` : `: ${error.message}`}`,
    )
  }
}

function parseJsonResponse(raw, description) {
  if (typeof raw !== 'string') return raw
  try {
    return JSON.parse(raw)
  } catch (error) {
    throw new AuditReadError(`${description} returned invalid JSON: ${error.message}`)
  }
}

function labelNames(obj) {
  if (!Array.isArray(obj?.labels)) {
    throw new AuditReadError('object labels field must be an array')
  }
  return obj.labels.map((entry) => {
    if (typeof entry === 'string') return entry
    if (entry && typeof entry.name === 'string') return entry.name
    throw new AuditReadError('malformed label entry')
  })
}

function labelMatchesPattern(labelName, pattern) {
  const lower = labelName.toLowerCase()
  const pat = pattern.toLowerCase()
  if (pat === 'claim:*') {
    return lower.startsWith('claim:') || lower.startsWith('agent:')
  }
  if (pat.endsWith(':*')) {
    return lower.startsWith(pat.slice(0, -1))
  }
  return lower === pat
}

function matchingLabels(labels, pattern) {
  return labels.filter((name) => labelMatchesPattern(name, pattern))
}

function normalizedSet(values) {
  return new Set(values.map((v) => v.toLowerCase()))
}

function setsEqual(a, b) {
  if (a.size !== b.size) return false
  for (const item of a) {
    if (!b.has(item)) return false
  }
  return true
}

function deriveRuleSets(rules) {
  const labels = rules?.labels
  if (!labels || typeof labels !== 'object' || Array.isArray(labels)) {
    throw new AuditReadError('rules-json is missing a labels map')
  }
  const neverCoexistPairs = []
  const seenPairs = new Set()
  const mirroredPatterns = []
  const stageMirroredPatterns = []
  const statePatterns = []
  const claimPatterns = []
  const handedOffOrBlockedPatterns = []
  const exactStateLabels = []

  for (const [pattern, info] of Object.entries(labels)) {
    if (!info || typeof info !== 'object') {
      throw new AuditReadError(`malformed rule entry for ${pattern}`)
    }
    const isManaged = info.managed === true
    const isStageProjected = info.outside_asset === 'dev-flow-support/assets/stage-labels.mjs'
    const isMirrored =
      isManaged ||
      (typeof info.object_scope === 'string' && info.object_scope.startsWith('issue_and_pr'))
    if (isManaged || isStageProjected) {
      statePatterns.push(pattern)
    }
    if (!isManaged && isStageProjected) exactStateLabels.push(pattern)
    if (isManaged) {
      if (pattern.includes('*')) {
        claimPatterns.push(pattern)
      } else {
        exactStateLabels.push(pattern)
        if (pattern.toLowerCase() !== 'needs-review') {
          handedOffOrBlockedPatterns.push(pattern)
        }
      }
    }
    if (isMirrored) {
      mirroredPatterns.push(pattern)
      if (isStageProjected) stageMirroredPatterns.push(pattern)
    }
    if (Array.isArray(info.never_coexists_with)) {
      for (const other of info.never_coexists_with) {
        const key = [pattern.toLowerCase(), other.toLowerCase()].sort().join('\0')
        if (!seenPairs.has(key)) {
          seenPairs.add(key)
          neverCoexistPairs.push([pattern, other])
        }
      }
    }
  }

  return {
    neverCoexistPairs,
    mirroredPatterns,
    stageMirroredPatterns,
    statePatterns,
    claimPatterns,
    handedOffOrBlockedPatterns,
    exactStateLabels,
  }
}

function isTrustedComment(comment, { allowActions = false } = {}) {
  const assoc = comment?.authorAssociation ?? comment?.author_association ?? ''
  const login = (comment?.author?.login ?? comment?.user?.login ?? '').toLowerCase()
  if (TRUSTED_ASSOC.has(assoc)) return true
  if (allowActions && login === 'github-actions[bot]') return true
  return false
}

function inspectIssueComments(comments, targetSlate) {
  const slateMemberships = new Map()
  let claimBranch = null
  let claimActive = false
  const handoffPassedPrs = new Set()
  const handoffPassedBranches = new Set()
  let handoffPassedGeneric = false

  for (const comment of Array.isArray(comments) ? comments : []) {
    const body = typeof comment?.body === 'string' ? comment.body : ''
    if (!body) continue

    if (targetSlate && isTrustedComment(comment)) {
      const m = SLATE_MEMBERSHIP_RE.exec(body)
      if (m && m[2] === targetSlate) {
        slateMemberships.set(m[1], m[3] === 'add')
      }
    }

    const firstLine = body.split(/\r?\n/, 1)[0].trim()
    if (firstLine.startsWith('Claiming —') && isTrustedComment(comment)) {
      const branchMatch = CLAIM_BRANCH_RE.exec(firstLine)
      if (branchMatch) {
        claimBranch = branchMatch[1]
      }
      claimActive = true
      handoffPassedPrs.clear()
      handoffPassedBranches.clear()
      handoffPassedGeneric = false
      continue
    }

    if (firstLine.startsWith('Claim released —') && isTrustedComment(comment, { allowActions: true })) {
      claimActive = false
      if (HANDOFF_RELEASE_RE.test(firstLine)) {
        const prMatch = /\bPR #([1-9][0-9]*)\b/i.exec(firstLine)
        const branchMatch = /\bbranch ([^\s;]+)/.exec(firstLine)
        if (prMatch) handoffPassedPrs.add(Number(prMatch[1]))
        else if (branchMatch) handoffPassedBranches.add(branchMatch[1])
        else handoffPassedGeneric = true
      }
    }
  }

  const inTargetSlate = targetSlate
    ? [...slateMemberships.values()].some((active) => active === true)
    : true

  return {
    inTargetSlate,
    claimBranch,
    claimActive,
    handoffPassedForPr(pr) {
      if (claimActive) return false
      if (handoffPassedPrs.has(pr.number)) return true
      if (pr.headRefName && handoffPassedBranches.has(pr.headRefName)) return true
      return handoffPassedGeneric
    },
  }
}

function hasNeverCoexist(labels, neverCoexistPairs) {
  for (const [patA, patB] of neverCoexistPairs) {
    const matchesA = matchingLabels(labels, patA)
    if (matchesA.length === 0) continue
    const matchesB = matchingLabels(labels, patB)
    if (matchesB.length === 0) continue
    for (const a of matchesA) {
      for (const b of matchesB) {
        if (a.toLowerCase() !== b.toLowerCase()) return true
      }
    }
  }
  return false
}

export async function auditLifecycleLabels(
  options,
  { gh = defaultGh, readRules = defaultReadRules } = {},
) {
  if (!options || typeof options.repo !== 'string' || !REPO_PATTERN.test(options.repo)) {
    throw new AuditUsageError('--repo must be OWNER/NAME')
  }
  if (
    options.slate !== undefined &&
    (typeof options.slate !== 'string' || !SLATE_PATTERN.test(options.slate))
  ) {
    throw new AuditUsageError('--slate must be a valid slate identifier')
  }

  const repo = options.repo
  const slate = options.slate
  const rules = readRules(options.rulesAsset)
  const {
    neverCoexistPairs,
    mirroredPatterns,
    stageMirroredPatterns,
    statePatterns,
    claimPatterns,
    handedOffOrBlockedPatterns,
    exactStateLabels,
  } = deriveRuleSets(rules)

  async function ghJson(argv, description) {
    const raw = await gh(argv)
    return parseJsonResponse(raw, description)
  }

  async function ghListJson(argv, limit, description) {
    const items = await ghJson([...argv, '--limit', String(limit)], description)
    if (!Array.isArray(items)) {
      throw new AuditReadError(`${description} returned non-array`)
    }
    if (items.length >= limit) {
      throw new AuditReadError(
        `${description} reached --limit ${limit}; coverage is indeterminate`,
      )
    }
    return items
  }

  const openIssuesRaw = await ghListJson(
    [
      'issue',
      'list',
      '--repo',
      repo,
      '--state',
      'open',
      '--json',
      'number,state,labels',
    ],
    1000,
    'open issue listing',
  )

  const candidateIssues = openIssuesRaw.filter((issue) => {
    const labels = labelNames(issue)
    return labels.some(
      (name) =>
        labelMatchesPattern(name, 'slated') ||
        statePatterns.some((pat) => labelMatchesPattern(name, pat)),
    )
  })

  const openPrsRaw = await ghListJson(
    [
      'pr',
      'list',
      '--repo',
      repo,
      '--state',
      'open',
      '--json',
      'number,state,isDraft,isCrossRepository,headRefName,headRefOid,baseRefName,labels',
    ],
    1000,
    'open PR listing',
  )

  const prsByNumber = new Map()
  const openPrsByBranch = new Map()
  for (const pr of openPrsRaw) {
    if (!pr || typeof pr.number !== 'number') continue
    prsByNumber.set(pr.number, pr)
    if (pr.isCrossRepository === false && typeof pr.headRefName === 'string' && pr.headRefName) {
      const list = openPrsByBranch.get(pr.headRefName) ?? []
      list.push(pr)
      openPrsByBranch.set(pr.headRefName, list)
    }
  }

  async function ensurePr(number) {
    if (prsByNumber.has(number)) return prsByNumber.get(number)
    const pr = await ghJson(
      [
        'pr',
        'view',
        String(number),
        '--repo',
        repo,
        '--json',
        'number,state,isDraft,isCrossRepository,headRefName,headRefOid,baseRefName,labels',
      ],
      `viewing PR #${number}`,
    )
    if (!pr || typeof pr.number !== 'number') {
      throw new AuditReadError(`malformed PR #${number} payload`)
    }
    prsByNumber.set(pr.number, pr)
    return pr
  }

  const scannedIssues = []
  const deliveryPrIssueMap = new Map()
  const closedBranchQueries = new Set()

  for (const summary of candidateIssues) {
    const issue = await ghJson(
      [
        'issue',
        'view',
        String(summary.number),
        '--repo',
        repo,
        '--json',
        'number,state,labels,assignees,closedByPullRequestsReferences,comments',
      ],
      `viewing issue #${summary.number}`,
    )
    const labels = labelNames(issue)
    const commentMeta = inspectIssueComments(issue.comments, slate)
    if (slate) {
      const hasSlated = labels.some((name) => labelMatchesPattern(name, 'slated'))
      if (!hasSlated || !commentMeta.inTargetSlate) continue
    }

    const closingRefs = Array.isArray(issue.closedByPullRequestsReferences)
      ? issue.closedByPullRequestsReferences
      : []
    const closingPrs = []
    for (const ref of closingRefs) {
      const refRepo = ref?.repository
      if (refRepo?.owner?.login && refRepo?.name) {
        const full = `${refRepo.owner.login}/${refRepo.name}`.toLowerCase()
        if (full !== repo.toLowerCase()) continue
      }
      if (typeof ref?.number !== 'number') continue
      const pr = await ensurePr(ref.number)
      if (pr.isCrossRepository === false) closingPrs.push(pr)
    }

    const claimBranchPrs = []
    if (commentMeta.claimBranch) {
      for (const pr of openPrsByBranch.get(commentMeta.claimBranch) ?? []) {
        claimBranchPrs.push(pr)
      }
      if (!closedBranchQueries.has(commentMeta.claimBranch)) {
        closedBranchQueries.add(commentMeta.claimBranch)
        const closedBranchRaw = await ghListJson(
          [
            'pr',
            'list',
            '--repo',
            repo,
            '--state',
            'closed',
            '--head',
            commentMeta.claimBranch,
            '--json',
            'number,state,isDraft,isCrossRepository,headRefName,headRefOid,baseRefName,labels',
          ],
          1000,
          `closed PR listing for branch ${commentMeta.claimBranch}`,
        )
        for (const pr of closedBranchRaw) {
          if (pr && typeof pr.number === 'number') {
            prsByNumber.set(pr.number, pr)
            if (pr.isCrossRepository === false) claimBranchPrs.push(pr)
          }
        }
      } else {
        for (const pr of prsByNumber.values()) {
          if (
            pr.state !== 'OPEN' &&
            pr.isCrossRepository === false &&
            pr.headRefName === commentMeta.claimBranch
          ) {
            claimBranchPrs.push(pr)
          }
        }
      }
    }

    const allDeliveryMap = new Map()
    for (const pr of [...closingPrs, ...claimBranchPrs]) {
      allDeliveryMap.set(pr.number, pr)
      const list = deliveryPrIssueMap.get(pr.number) ?? []
      list.push({ issue, labels, commentMeta })
      deliveryPrIssueMap.set(pr.number, list)
    }

    scannedIssues.push({
      issue,
      labels,
      commentMeta,
      allDeliveryPrs: [...allDeliveryMap.values()],
    })
  }

  const candidatePrs = new Map()
  for (const entry of scannedIssues) {
    for (const pr of entry.allDeliveryPrs) {
      candidatePrs.set(pr.number, pr)
    }
  }

  if (!slate) {
    for (const pr of openPrsRaw) {
      if (pr.isCrossRepository !== false) continue
      const prLabels = labelNames(pr)
      if (prLabels.some((name) => statePatterns.some((pat) => labelMatchesPattern(name, pat)))) {
        candidatePrs.set(pr.number, pr)
      }
    }
    for (const stateLabel of exactStateLabels) {
      const closedWithLabel = await ghListJson(
        [
          'pr',
          'list',
          '--repo',
          repo,
          '--state',
          'closed',
          '--label',
          stateLabel,
          '--json',
          'number,state,isDraft,isCrossRepository,headRefName,headRefOid,baseRefName,labels',
        ],
        1000,
        `closed PR listing for label ${stateLabel}`,
      )
      for (const pr of closedWithLabel) {
        if (pr && typeof pr.number === 'number' && pr.isCrossRepository === false) {
          prsByNumber.set(pr.number, pr)
          candidatePrs.set(pr.number, pr)
        }
      }
    }
  }

  const violations = []
  const seenViolations = new Set()

  function recordViolation(type, number, labels, violationClass) {
    const key = `${type}:${number}:${violationClass}`
    if (seenViolations.has(key)) return
    seenViolations.add(key)
    violations.push({
      repo,
      object: { type, number },
      labels,
      class: violationClass,
    })
  }

  for (const { issue, labels, commentMeta, allDeliveryPrs } of scannedIssues) {
    if (hasNeverCoexist(labels, neverCoexistPairs)) {
      recordViolation('issue', issue.number, labels, 'never-coexist')
    }

    for (const pr of allDeliveryPrs) {
      if (pr.state !== 'OPEN') continue
      const patterns = commentMeta.claimBranch && pr.headRefName === commentMeta.claimBranch
        ? mirroredPatterns
        : stageMirroredPatterns
      const prLabels = labelNames(pr)
      let mismatch = false
      for (const pattern of patterns) {
        const issueMatches = normalizedSet(matchingLabels(labels, pattern))
        const prMatches = normalizedSet(matchingLabels(prLabels, pattern))
        if (setsEqual(issueMatches, prMatches)) continue
        if (
          pattern.toLowerCase() === 'needs-review' &&
          issueMatches.size > 0 &&
          prMatches.size === 0
        ) {
          const siblingHoldsNeedsReview = allDeliveryPrs.some(
            (other) =>
              other.number !== pr.number &&
              other.state === 'OPEN' &&
              matchingLabels(labelNames(other), 'needs-review').length > 0,
          )
          if (siblingHoldsNeedsReview) continue
        }
        mismatch = true
        break
      }
      if (mismatch) {
        recordViolation('pr', pr.number, prLabels, 'mirror-mismatch')
      }
    }
  }

  const sortedPrs = [...candidatePrs.values()].sort((a, b) => a.number - b.number)
  for (const pr of sortedPrs) {
    const prLabels = labelNames(pr)
    if (hasNeverCoexist(prLabels, neverCoexistPairs)) {
      recordViolation('pr', pr.number, prLabels, 'never-coexist')
    }

    if (pr.state === 'CLOSED' || pr.state === 'MERGED') {
      const hasStateLabel = prLabels.some((name) =>
        statePatterns.some((pat) => labelMatchesPattern(name, pat)),
      )
      if (hasStateLabel) {
        recordViolation('pr', pr.number, prLabels, 'closed-with-state-label')
      }
      continue
    }

    if (pr.state !== 'OPEN') continue

    const hasMergeReady = matchingLabels(prLabels, 'merge-ready').length > 0
    if (pr.isDraft === true) {
      if (hasMergeReady) {
        recordViolation('pr', pr.number, prLabels, 'merge-ready-draft')
      }

      const linkedIssues = deliveryPrIssueMap.get(pr.number) ?? []
      if (linkedIssues.length > 0) {
        const issueHasClaim = linkedIssues.some((entry) =>
          entry.labels.some((name) => claimPatterns.some((pat) => labelMatchesPattern(name, pat))),
        )
        const prHasHandedOffOrBlocked = prLabels.some((name) =>
          handedOffOrBlockedPatterns.some((pat) => labelMatchesPattern(name, pat)),
        )
        const issueHasHandedOffOrBlocked = linkedIssues.some((entry) =>
          entry.labels.some((name) =>
            handedOffOrBlockedPatterns.some((pat) => labelMatchesPattern(name, pat)),
          ),
        )
        if (!issueHasClaim && !prHasHandedOffOrBlocked && !issueHasHandedOffOrBlocked) {
          const passedHandoff = linkedIssues.some((entry) => entry.commentMeta.handoffPassedForPr(pr))
          recordViolation(
            'pr',
            pr.number,
            prLabels,
            passedHandoff ? 'passed-draft-unparked' : 'draft-in-integration-unclaimed',
          )
        }
      }
    } else if (hasMergeReady) {
      if (typeof pr.baseRefName !== 'string' || !pr.baseRefName || typeof pr.headRefOid !== 'string' || !pr.headRefOid) {
        throw new AuditReadError(`PR #${pr.number} is missing baseRefName or headRefOid`)
      }
      const encodedBase = encodeURIComponent(pr.baseRefName).replaceAll('%2F', '/')
      const compare = await ghJson(
        [
          'api',
          '--method',
          'GET',
          `repos/${repo}/compare/${encodedBase}...${pr.headRefOid}`,
        ],
        `comparing ${pr.baseRefName}...${pr.headRefOid} for PR #${pr.number}`,
      )
      if (
        !compare ||
        typeof compare.behind_by !== 'number' ||
        !Number.isInteger(compare.behind_by) ||
        compare.behind_by < 0
      ) {
        throw new AuditReadError(
          `compare for PR #${pr.number} returned invalid behind_by: ${compare?.behind_by}`,
        )
      }
      if (compare.behind_by > 0) {
        recordViolation('pr', pr.number, prLabels, 'merge-ready-behind-base')
      }
    }
  }

  return violations
}

function parseCliArgs(argv) {
  const options = {}
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i]
    if (arg === '--help' || arg === '-h') {
      return { help: true }
    }
    if (arg === '--repo' || arg === '--slate' || arg === '--rules-asset') {
      const key = arg === '--rules-asset' ? 'rulesAsset' : arg.slice(2)
      const val = argv[i + 1]
      if (val === undefined || Object.hasOwn(options, key)) {
        throw new AuditUsageError(`missing or duplicate value for ${arg}`)
      }
      options[key] = val
      i += 1
      continue
    }
    throw new AuditUsageError(`unexpected argument: ${arg}`)
  }
  return options
}

async function main(argv) {
  try {
    const options = parseCliArgs(argv)
    if (options.help) {
      console.log(USAGE)
      process.exitCode = 0
      return
    }
    const violations = await auditLifecycleLabels(options)
    console.log(JSON.stringify(violations, null, 2))
    process.exitCode = violations.length === 0 ? 0 : 1
  } catch (error) {
    console.error(`label-lifecycle-audit: ${error.message}`)
    process.exitCode = 2
  }
}

if (
  process.argv[1] &&
  existsSync(process.argv[1]) &&
  realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))
) {
  await main(process.argv.slice(2))
}
