#!/usr/bin/env bash
# Offline discovery tests: injected gh only, with a CLI subprocess using a fake gh.
set -euo pipefail
asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
node --input-type=module - "$asset_dir/slate-input.mjs" <<'NODE'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawnSync } from 'node:child_process'
import { pathToFileURL } from 'node:url'
const asset = process.argv[2]
const { resolveSlateInput } = await import(pathToFileURL(asset))
const repo = 'example/repo'
const url = (number, repository = repo) => `https://github.com/${repository}/issues/${number}`
const issue = (number, state = 'open', labels = [], repository = repo) => ({
  number, html_url: url(number, repository), repository_url: `https://api.github.com/repos/${repository}`,
  title: `Issue ${number}`, state, labels: labels.map((name) => ({ name })),
})
function fixture(children = [], overrides = {}) {
  const calls = []
  const data = {
    [`repos/${repo}/issues/1`]: issue(1, 'open', ['umbrella']),
    [`repos/${repo}/issues/1/sub_issues?per_page=100`]: children,
    ...overrides,
  }
  const gh = (argv) => {
    calls.push(argv)
    assert.deepEqual(argv.slice(0, 5), ['api', '--hostname', 'github.com', '--method', 'GET'])
    const endpoint = argv[5]
    assert.ok(Object.hasOwn(data, endpoint), `unexpected endpoint: ${endpoint}`)
    const paginated = argv.includes('--paginate')
    assert.deepEqual(argv.slice(6), paginated ? ['--paginate', '--slurp'] : [])
    return JSON.stringify(data[endpoint])
  }
  return { gh, calls }
}
// The outer array is gh --slurp's pagination; work on later pages must survive.
const mixed = fixture([[issue(2), issue(3, 'closed', ['human']), issue(4, 'open', ['human'])],
  [issue(5, 'open', ['umbrella']), issue(6)]])
const epic = await resolveSlateInput({ repo, issue: url(1) }, mixed)
assert.equal(epic.ok, true)
assert.deepEqual(epic.input, { kind: 'epic', url: url(1) })
assert.deepEqual(epic.candidates.map((i) => i.number), [2, 6])
assert.deepEqual(epic.done.map((i) => i.number), [3])
assert.deepEqual(epic.excluded.map((i) => i.number), [4, 5])
assert.match(epic.excluded[0].reason, /human/)
assert.match(epic.excluded[1].reason, /umbrella/)
assert.ok(!epic.candidates.some((i) => i.number === 1))
const uppercaseEpic = await resolveSlateInput({ repo, issue: 1 }, fixture([[issue(2, 'open', ['UMBRELLA'])]]))
assert.equal(uppercaseEpic.ok, true)
assert.deepEqual(uppercaseEpic.candidates, [])
assert.deepEqual(uppercaseEpic.excluded.map((i) => i.number), [2])
assert.deepEqual(uppercaseEpic.excluded[0].labels, ['UMBRELLA'])
assert.equal(uppercaseEpic.excluded[0].reason, 'excluded labels: UMBRELLA')
const mixedCaseSingle = await resolveSlateInput({ repo, issue: 2 }, fixture([], {
  [`repos/${repo}/issues/2`]: issue(2, 'open', ['Human']),
  [`repos/${repo}/issues/2/sub_issues?per_page=100`]: [[]],
}))
assert.equal(mixedCaseSingle.ok, true)
assert.deepEqual(mixedCaseSingle.candidates, [])
assert.deepEqual(mixedCaseSingle.excluded.map((i) => i.number), [2])
assert.deepEqual(mixedCaseSingle.excluded[0].labels, ['Human'])
assert.equal(mixedCaseSingle.excluded[0].reason, 'excluded labels: Human')
const cross = await resolveSlateInput({ repo, issue: 1 }, fixture([[issue(2)], [issue(3, 'open', [], 'other/project')]]))
assert.equal(cross.ok, false)
assert.equal(cross.refused[0].repository, 'other/project')
assert.match(cross.refused[0].reason, /other\/project#3.*refused.*example\/repo.*multi-repo/)
const closedCross = await resolveSlateInput({ repo, issue: 1 }, fixture([[issue(3, 'closed', ['human'], 'other/project')]]))
assert.equal(closedCross.ok, false)
const single = await resolveSlateInput({ repo, issue: 2 }, fixture([], {
  [`repos/${repo}/issues/2`]: issue(2), [`repos/${repo}/issues/2/sub_issues?per_page=100`]: [[]],
}))
assert.deepEqual(single.input, { kind: 'single', url: url(2) })
assert.deepEqual(single.candidates.map((i) => i.number), [2])
const listFake = fixture([], {
  [`repos/${repo}/issues/2`]: issue(2), [`repos/${repo}/issues/3`]: issue(3, 'closed'),
})
const list = await resolveSlateInput({ repo, issues: `2,${url(3)},2` }, listFake)
assert.equal(list.ok, true)
assert.deepEqual(list.input, { kind: 'list', urls: [url(2), url(3)] })
assert.equal(listFake.calls.length, 2, 'list must not expand children')
assert.deepEqual(list.done.map((i) => i.number), [3])
const oneList = await resolveSlateInput({ repo, issues: '1' }, fixture())
assert.equal(oneList.input.kind, 'list', 'explicit list remains a list even with one issue')
assert.equal(oneList.excluded.length, 1, 'umbrella list entry is excluded')
const milestone = await resolveSlateInput({ repo, milestone: 4 }, fixture([], {
  [`repos/${repo}/milestones/4`]: { number: 4 },
  [`repos/${repo}/issues?milestone=4&state=all&per_page=100`]: [[issue(2), { ...issue(8), pull_request: {} }], [issue(3, 'closed'), issue(4, 'open', ['human'])]],
}))
assert.equal(milestone.ok, true)
assert.deepEqual(milestone.input, { kind: 'milestone', number: 4 })
assert.deepEqual(milestone.candidates.map((i) => i.number), [2])
assert.deepEqual(milestone.done.map((i) => i.number), [3])
assert.equal(milestone.excluded.length, 1)
const failedRead = await resolveSlateInput({ repo, issue: 1 }, { gh: () => { throw new Error('permission denied') } })
assert.equal(failedRead.ok, false)
assert.match(failedRead.errors[0], /permission denied/)
const badPages = await resolveSlateInput({ repo, issue: 1 }, fixture([issue(2)]))
assert.equal(badPages.ok, false, 'missing slurp page boundaries must fail')
const badIdentity = await resolveSlateInput({ repo, issue: 1 }, fixture([[{ ...issue(2), repository_url: 'https://api.github.com/repos/other/project' }]]))
assert.equal(badIdentity.ok, false)
const badState = await resolveSlateInput({ repo, issue: 1 }, fixture([[issue(2, 'unknown')]]))
assert.equal(badState.ok, false)
const crossList = fixture()
const refusedList = await resolveSlateInput({ repo, issues: url(2, 'other/project') }, crossList)
assert.equal(refusedList.ok, false)
assert.equal(crossList.calls.length, 0, 'must refuse cross-repo input before reads')
for (const options of [{ repo, issue: 0 }, { repo, issue: '1;touch nope' }, { repo, issues: '1,' },
  { repo, milestone: -1 }, { repo, milestone: 1, issue: 2 }, { repo: '--help', issue: 1 },
  { repo, issue: 'https://elsewhere.test/example/repo/issues/1' }]) {
  await assert.rejects(() => resolveSlateInput(options), /number|repo|exactly/)
}
// Verify the executable boundary, read-only argv, JSON output and refusal exit.
const scratch = mkdtempSync(join(tmpdir(), 'slate-input-'))
try {
  mkdirSync(join(scratch, 'bin'))
  const data = {
    [`repos/${repo}/issues/1`]: issue(1),
    [`repos/${repo}/issues/1/sub_issues?per_page=100`]: [[issue(2)], [issue(3, 'open', [], 'other/project')]],
  }
  writeFileSync(join(scratch, 'data.json'), JSON.stringify(data))
  writeFileSync(join(scratch, 'bin/gh'), `#!/usr/bin/env node
const fs = require('node:fs')
const a = process.argv.slice(2)
if (JSON.stringify(a.slice(0,5)) !== JSON.stringify(['api','--hostname','github.com','--method','GET'])) process.exit(99)
const data = JSON.parse(fs.readFileSync(process.env.SLATE_TEST_DATA))
if (!(a[5] in data)) process.exit(98)
if (a[5].includes('sub_issues') && JSON.stringify(a.slice(6)) !== JSON.stringify(['--paginate','--slurp'])) process.exit(97)
console.log(JSON.stringify(data[a[5]]))
`, { mode: 0o755 })
  const env = { ...process.env, PATH: `${join(scratch, 'bin')}:${process.env.PATH}`, SLATE_TEST_DATA: join(scratch, 'data.json') }
  const child = spawnSync(process.execPath, [asset, '--repo', repo, '--issue', '1'], { env, encoding: 'utf8' })
  assert.equal(child.status, 1, child.stderr)
  const result = JSON.parse(child.stdout)
  assert.equal(result.refused[0].repository, 'other/project')
  data[`repos/${repo}/issues/1/sub_issues?per_page=100`] = [[]]
  writeFileSync(join(scratch, 'data.json'), JSON.stringify(data))
  const success = spawnSync(process.execPath, [asset, '--repo', repo, '--issue', '1'], { env, encoding: 'utf8' })
  assert.equal(success.status, 0, success.stderr)
  assert.equal(JSON.parse(success.stdout).input.kind, 'single')
  // Exercise runGh's real pipe with paginated JSON larger than Node's default 1 MiB.
  // An ignored API field keeps the resolver's own JSON output small.
  const largePages = [[{ ...issue(2), body: 'x'.repeat(1024 * 1024) }], [issue(3)]]
  assert.ok(Buffer.byteLength(JSON.stringify(largePages)) > 1024 * 1024)
  data[`repos/${repo}/issues/1/sub_issues?per_page=100`] = largePages
  writeFileSync(join(scratch, 'data.json'), JSON.stringify(data))
  const large = spawnSync(process.execPath, [asset, '--repo', repo, '--issue', '1'], { env, encoding: 'utf8' })
  assert.equal(large.status, 0, large.stderr || large.stdout)
  const largeResult = JSON.parse(large.stdout)
  assert.equal(largeResult.ok, true)
  assert.deepEqual(largeResult.candidates.map((i) => i.number), [2, 3])
  const invalid = spawnSync(process.execPath, [asset, '--repo', repo, '--issue', '1', '--milestone', '2'], { env, encoding: 'utf8' })
  assert.equal(invalid.status, 2)
  assert.equal(JSON.parse(invalid.stdout).ok, false)
} finally { rmSync(scratch, { recursive: true, force: true }) }
console.log('PASS: slate inputs, epic pagination, exclusions, cross-repo refusals, read failures and CLI exits')
NODE
