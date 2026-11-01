#!/usr/bin/env node
// Read-only slate discovery. No claims, membership writes, graph or lane decisions.
// Usage: slate-input.mjs --repo OWNER/REPO (--issue N|URL | --issues N,URL,... | --milestone N)
// --issue expands native sub-issues when present; --issues is always a literal list.
// Prints JSON on success and refusal; exit 0 usable, 1 refused/read failed, 2 usage.
// Tests may inject gh(argv) into resolveSlateInput; only GET requests are emitted.
import { execFileSync } from 'node:child_process'
import { existsSync, realpathSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const repositoryPattern = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/
const ghMaxBuffer = 64 * 1024 * 1024

function positive(value) {
  if (!/^[1-9][0-9]*$/.test(String(value)) || !Number.isSafeInteger(Number(value))) {
    throw new Error(`expected a positive issue or milestone number: ${value}`)
  }
  return Number(value)
}

function issueRef(value, repository, allowPullRequest = false) {
  const match = /^https:\/\/github\.com\/([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\/(issues|pull)\/([1-9][0-9]*)\/?$/.exec(String(value))
  if (match?.[2] === 'pull' && !allowPullRequest) throw new Error(`expected an issue URL or number: ${value}`)
  const repo = match ? match[1] : repository
  const number = positive(match ? match[3] : value)
  return { repository: repo, number, url: `https://github.com/${repo}/issues/${number}` }
}

function runGh(argv) {
  return execFileSync('gh', argv, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: ghMaxBuffer })
}

function validateOptions(options) {
  if (!options || typeof options.repo !== 'string' || !repositoryPattern.test(options.repo)) {
    throw new Error('--repo must be OWNER/REPO (github.com)')
  }
  const selectors = ['issue', 'issues', 'milestone'].filter((key) => options[key] !== undefined)
  if (selectors.length !== 1) throw new Error('supply exactly one of --issue, --issues, --milestone')
  if (options.milestone !== undefined) return { kind: 'milestone', number: positive(options.milestone) }
  if (options.issue !== undefined) return { kind: 'single', url: issueRef(options.issue, options.repo).url }
  if (typeof options.issues !== 'string' || !options.issues.trim()) throw new Error('--issues must be a nonempty comma-separated list')
  return { kind: 'list', urls: [...new Set(options.issues.split(',').map((value) => issueRef(value.trim(), options.repo).url))] }
}

export async function resolveSlateInput(options, { gh = runGh } = {}) {
  const input = validateOptions(options)
  const result = { ok: true, repository: options.repo, input, candidates: [], done: [], excluded: [], refused: [], errors: [] }
  async function get(endpoint, paginated = false) {
    const argv = ['api', '--hostname', 'github.com', '--method', 'GET', endpoint]
    if (paginated) argv.push('--paginate', '--slurp')
    const response = await gh(argv)
    const data = typeof response === 'string' ? JSON.parse(response) : response
    if (!paginated) return data
    if (!Array.isArray(data) || data.some((page) => !Array.isArray(page))) {
      throw new Error(`expected paginated arrays from ${endpoint}`)
    }
    return data.flat()
  }
  function refuse(ref) {
    result.refused.push({ ...ref, reason: `Cross-repository issue ${ref.repository}#${ref.number} refused: slate repository is ${options.repo}; multi-repo slates are not supported yet.` })
    result.ok = false
  }
  const seen = new Set()
  function record(raw) {
    // Bind identity to GitHub's issue URL, never to the slate's repo + child number.
    const ref = issueRef(raw.html_url, options.repo, true)
    if (ref.number !== raw.number) throw new Error(`issue identity mismatch: ${ref.url}`)
    if (raw.repository_url?.toLowerCase() !== `https://api.github.com/repos/${ref.repository}`.toLowerCase()) {
      throw new Error(`missing or inconsistent repository identity: ${ref.url}`)
    }
    const key = ref.url.toLowerCase()
    if (seen.has(key)) return
    seen.add(key)
    if (ref.repository.toLowerCase() !== options.repo.toLowerCase()) { refuse(ref); return }
    if (raw.pull_request) return // milestone /issues also returns pull requests
    if (!['open', 'closed'].includes(raw.state) || typeof raw.title !== 'string' || !raw.title.trim() ||
        !Array.isArray(raw.labels) || raw.labels.some((label) => typeof label?.name !== 'string')) {
      throw new Error(`incomplete issue data: ${ref.url}`)
    }
    const issue = { ...ref, title: raw.title, labels: raw.labels.map((label) => label.name), state: raw.state }
    if (issue.state === 'closed') { result.done.push(issue); return }
    const excluded = issue.labels.filter((label) => ['human', 'umbrella'].includes(label.toLowerCase()))
    if (excluded.length) result.excluded.push({ ...issue, reason: `excluded labels: ${excluded.join(', ')}` })
    else result.candidates.push(issue)
  }
  try {
    if (input.kind === 'milestone') {
      // Fetch the milestone too: a missing milestone must not look like an empty slate.
      const milestone = await get(`repos/${options.repo}/milestones/${input.number}`)
      if (milestone.number !== input.number) throw new Error('milestone identity mismatch')
      for (const raw of await get(`repos/${options.repo}/issues?milestone=${input.number}&state=all&per_page=100`, true)) record(raw)
    } else {
      const refs = (input.kind === 'list' ? input.urls : [input.url]).map((url) => issueRef(url, options.repo))
      for (const ref of refs) {
        if (ref.repository.toLowerCase() !== options.repo.toLowerCase()) { refuse(ref); continue }
        const raw = await get(`repos/${ref.repository}/issues/${ref.number}`)
        if (raw.number !== ref.number || raw.html_url?.toLowerCase() !== ref.url.toLowerCase()) throw new Error(`issue identity mismatch: ${ref.url}`)
        if (raw.pull_request) throw new Error(`${ref.url} is a pull request, not an issue`)
        if (input.kind === 'single') {
          const children = await get(`repos/${ref.repository}/issues/${ref.number}/sub_issues?per_page=100`, true)
          if (children.length) {
            result.input.kind = 'epic'
            for (const child of children) record(child)
            continue // The epic itself is context, never dispatchable work.
          }
        }
        record(raw)
      }
    }
  } catch (error) {
    result.ok = false
    result.errors.push(`Slate discovery failed: ${error.message}`)
  }
  return result
}

async function main(argv) {
  try {
    const options = {}
    for (let i = 0; i < argv.length; i += 2) {
      const key = argv[i].replace(/^--/, '')
      if (!argv[i].startsWith('--') || !['repo', 'issue', 'issues', 'milestone'].includes(key) ||
          argv[i + 1] === undefined || Object.hasOwn(options, key)) throw new Error(`invalid or duplicate option: ${argv[i]}`)
      options[key] = argv[i + 1]
    }
    validateOptions(options)
    const result = await resolveSlateInput(options)
    console.log(JSON.stringify(result, null, 2))
    process.exitCode = result.ok ? 0 : 1
  } catch (error) {
    console.log(JSON.stringify({ ok: false, errors: [error.message] }))
    process.exitCode = 2
  }
}

if (process.argv[1] && existsSync(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))) await main(process.argv.slice(2))
