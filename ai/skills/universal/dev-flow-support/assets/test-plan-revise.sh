#!/usr/bin/env bash
# test-plan-revise.sh — behavioral tests for plan-revise.mjs, the mechanical
# dispatch-plan recompute for a default-branch move (harmon-devkit#1296).
#
# Covers a disjoint base move, a fence-touching move, a candidate-file move, a
# done issue releasing a dependent, a broken revision chain, a non-descendant
# base, an emptied wave, and the slate lock. Every case runs in a temporary
# fixture repository with the Git environment scrubbed, so the writer never
# reads, locks or writes a real clone's dev-flow-v2 tree.
#
# Run by task test:plan-revise (part of task test); scripts/test-skills.sh only
# checks that wiring.
set -euo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

asset_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
reviser="$asset_dir/plan-revise.mjs"
writer="$asset_dir/run-record.mjs"
validator="$asset_dir/validate-result-schemas.mjs"

fail() {
    # shell-robustness: ok — always exits, so its status is never read
    echo "TEST FAIL: $*" >&2
    exit 1
}

pass() {
    echo "  PASS: $1"
    return 0
}

command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v git >/dev/null 2>&1 || fail "git is required"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/plan-revise.XXXXXX")"
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

expect_refused() {
    local label="$1" pattern="$2"
    shift 2
    local output rc=0
    output="$("$@" 2>&1)" || rc=$?
    [ "$rc" -eq 1 ] || fail "$label: expected refusal (exit 1), got $rc: $output"
    grep -qF -- "$pattern" <<<"$output" || fail "$label: refusal did not mention '$pattern': $output"
}

# new_repo NAME — a fixture repository with one base commit; prints its path.
new_repo() {
    local repo="$tmp/$1"
    git init -q -b main "$repo"
    git -C "$repo" config user.name t
    git -C "$repo" config user.email t@t
    mkdir -p "$repo/c"
    printf 'a\n' >"$repo/a.txt"
    printf 'b\n' >"$repo/b.txt"
    printf 'c\n' >"$repo/c/one.txt"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m base
    resolved="$(cd "$repo" && git rev-parse --path-format=absolute --git-common-dir)"
    [ "$resolved" = "$repo/.git" ] || fail "fixture common dir resolved to $resolved"
    printf '%s\n' "$repo"
}

commit_touching() {
    local repo="$1"
    shift
    for path in "$@"; do
        mkdir -p "$repo/$(dirname "$path")"
        printf 'changed %s\n' "$RANDOM" >>"$repo/$path"
    done
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "touch $*"
    git -C "$repo" rev-parse HEAD
}

# write_plan REPO SLATE BLOCKER [FENCE_C] [OVERLAP] — revision 0 for issues
# #1 (wave 1, lane a, fence a.txt), #2 (wave 1, lane b, fence b.txt) and #3
# (wave 2, lane c, fence FENCE_C, default c/**). BLOCKER is #3's blocked_by
# list as JSON (e.g. [] or [1]). OVERLAP "A-B" gives issues A and B a shared
# candidate file and a serialized overlap with merge dependency A before B.
write_plan() {
    local repo="$1" slate="$2" blocked="$3"
    local base dir
    base="$(git -C "$repo" rev-parse HEAD)"
    dir="$repo/.git/dev-flow-v2/slates/$slate"
    mkdir -p "$dir"
    PLAN_BASE="$base" PLAN_SLATE="$slate" PLAN_BLOCKED="$blocked" PLAN_WRITER="$writer" PLAN_FENCE_C="${4:-c/**}" PLAN_OVERLAP="${5:-}" node --input-type=module -e '
      const { chainDigest } = await import(process.env.PLAN_WRITER)
      const policy = {
        rigor: "deep", rigor_source: "default",
        caps: { challenge: 1, review: 1, integration: 1, remediation: 1, min_rounds: 1, wall_clock_min: 60 },
        breadth: { max_agent_runs: 5, max_parallel_agents: 2 },
        strategy: "plan", strategy_source: "default",
        role_tiers: { orchestrator: "apex", implementer: "frontier", challenger: "apex", reviewer: "frontier", integrator: "economy" },
        operator_pins: [],
      }
      const issue = (number, files, blocked_by = []) => ({
        number, title: `Issue ${number}`, url: `https://example.test/issues/${number}`,
        verdict: "valid", candidate_files: files, blocked_by,
      })
      const lane = (name, number, wave, fence) => ({
        lane: name, issue: number, wave, branch: `${number}-${name}`, run_id: `run-${number}`,
        fence: fence.map((path) => ({ path })), expansions: [],
      })
      const plan = {
        base_sha: process.env.PLAN_BASE, policy,
        lane_profiles: [{ lane: "a", policy }, { lane: "b", policy }, { lane: "c", policy }],
        dispatcher: { kind: "interactive", parallel_cap: 2, foreman_max_parallel: null },
        issues: [issue(1, ["a.txt"]), issue(2, ["b.txt"]), issue(3, ["c/one.txt"], JSON.parse(process.env.PLAN_BLOCKED))],
        overlaps: [],
        waves: [{ number: 1, issues: [1, 2] }, { number: 2, issues: [3] }],
        lanes: [lane("a", 1, 1, ["a.txt"]), lane("b", 2, 1, ["b.txt"]), lane("c", 3, 2, [process.env.PLAN_FENCE_C])],
      }
      if (process.env.PLAN_OVERLAP) {
        const [before, after] = process.env.PLAN_OVERLAP.split("-").map(Number)
        for (const number of [before, after]) plan.issues[number - 1].candidate_files.push("shared.txt")
        plan.overlaps.push({ issue_a: before, issue_b: after, paths: ["shared.txt"], resolution: "serialize",
          merge_dependency: { before, after } })
      }
      const at = "2026-01-01T00:00:00Z", reason = "initial plan"
      const digest = chainDigest({ seq: 0, plan, at, reason }, "genesis")
      const document = { schema: 1, slate_id: process.env.PLAN_SLATE, revisions: [{ seq: 0, prev_digest: "genesis", digest, at, reason, plan }] }
      process.stdout.write(JSON.stringify(document, null, 2) + "\n")
    ' >"$dir/plan.json"
    node "$validator" plan "$dir/plan.json" >/dev/null || fail "fixture plan for $slate is invalid"
    (cd "$repo" && node "$writer" lock acquire --slate "$slate" --session alice) >"$tmp/token-$slate"
}

# pr REPO SESSION SLATE ARGS... — run base-move from inside REPO.
pr() {
    local repo="$1" session="$2" slate="$3"
    shift 3
    (cd "$repo" && node "$reviser" base-move --slate "$slate" --session "$session" --owner-token "$(cat "$tmp/token-$slate")" --reason "main moved" "$@")
}

# -- disjoint base move ------------------------------------------------------
repo="$(new_repo disjoint)"
write_plan "$repo" s1 '[]'
plan="$repo/.git/dev-flow-v2/slates/s1/plan.json"
new_base="$(commit_touching "$repo" a.txt unrelated.txt)"
expect_refused "base-move wrong owner token" "owner token does not match" \
    bash -c "cd '$repo' && node '$reviser' base-move --slate s1 --session alice --owner-token wrong --reason r --new-base '$new_base'"
(cd "$repo" && node "$writer" lock release --slate s1 --session alice --owner-token "$(cat "$tmp/token-s1")") >/dev/null
expect_refused "base-move without explicit acquire" "lock acquire" \
    pr "$repo" alice s1 --new-base "$new_base" --at 2026-01-01T01:00:00Z
(cd "$repo" && node "$writer" lock acquire --slate s1 --session alice) >"$tmp/token-s1"
pr "$repo" alice s1 --new-base "$new_base" --done 1 --at 2026-01-01T01:00:00Z >/dev/null
node "$validator" plan "$plan" >/dev/null || fail "revised plan does not validate"
current="$(jq -c '.revisions[-1]' "$plan")"
[ "$(jq -r '.seq' <<<"$current")" = "1" ] || fail "no revision appended"
[ "$(jq -r '.prev_digest' <<<"$current")" = "$(jq -r '.revisions[0].digest' "$plan")" ] || fail "chain not extended"
[ "$(jq -r '.plan.base_sha' <<<"$current")" = "$new_base" ] || fail "base_sha not bumped"
[ "$(jq -r '.plan.issues[] | select(.number == 1) | .verdict' <<<"$current")" = "done" ] || fail "done verdict not recorded"
[ "$(jq -r '.plan.lanes | map(.lane) | join(",")' <<<"$current")" = "b,c" ] || fail "done issue's lane not removed"
[ "$(jq -r '.plan.lane_profiles | map(.lane) | join(",")' <<<"$current")" = "b,c" ] || fail "done issue's profile not removed"
[ "$(jq -c '.plan.waves' <<<"$current")" = '[{"number":1,"issues":[2]},{"number":2,"issues":[3]}]' ] || fail "waves not revised"
pass "a disjoint base move bumps base_sha, retires the done issue's lane and extends the chain"

# The done issue's run left the current revision but is still s1's: it can be
# written and closed under s1 (a run belongs to the slate whose plan history
# names it).
mkdir -p "$repo/.git/dev-flow-v2/runs/run-1"
jq -n '{schema: 2, run_id: "run-1", initiated_by: "human", started_at: "2026-01-01T00:00:00Z",
  stage_transitions: [{stage: "kickoff", entered_at: "2026-01-01T00:00:00Z"}], interventions: [],
  outcome: null, pr: null, evidence_comments: [], evidence_registrations: [], pr_bindings: [],
  outcome_transitions: [], settlements: [], promotion: null, receipts: []}' >"$repo/.git/dev-flow-v2/runs/run-1/run.json"
(cd "$repo" && node "$writer" transition --slate s1 --session alice --owner-token "$(cat "$tmp/token-s1")" --run-id run-1 --stage claim --exit k --at 2026-01-01T01:01:00Z) >/dev/null ||
    fail "a run dropped by --done could not be written under its own slate"
(cd "$repo" && node "$writer" close --slate s1 --session alice --owner-token "$(cat "$tmp/token-s1")" --run-id run-1 --outcome abandoned --exit merged --at 2026-01-01T01:02:00Z) >/dev/null ||
    fail "a run dropped by --done could not be closed under its own slate"
[ "$(jq -r '.outcome' "$repo/.git/dev-flow-v2/runs/run-1/run.json")" = "abandoned" ] || fail "close outcome not recorded"
pass "a run dropped from the current revision by --done is still written and closed under its own slate"

# -- fence-touching base move ------------------------------------------------
cp "$plan" "$tmp/disjoint-plan.json"
touching="$(commit_touching "$repo" c/two.txt)"
expect_refused "fence-touching move" "lane c (#3) fence: c/two.txt" \
    pr "$repo" alice s1 --new-base "$touching" --at 2026-01-01T02:00:00Z
cmp -s "$plan" "$tmp/disjoint-plan.json" || fail "a refused move changed plan.json"
pass "a base move touching a live lane's fence is refused, naming the path"

candidate="$(commit_touching "$repo" b.txt)"
expect_refused "candidate-touching move" "issue #2 candidate file: b.txt" \
    pr "$repo" alice s1 --new-base "$candidate" --at 2026-01-01T02:00:00Z
pass "a base move touching a live issue's candidate files is refused, naming the path"

# -- a second revision chains onto the first ------------------------------
git -C "$repo" reset -q --hard "$new_base"
moved="$(commit_touching "$repo" docs.txt)"
pr "$repo" alice s1 --new-base "$moved" --at 2026-01-01T03:00:00Z >/dev/null
node "$validator" plan "$plan" >/dev/null || fail "second revision does not validate"
[ "$(jq -r '.revisions | length' "$plan")" = "3" ] || fail "second revision not appended"
[ "$(jq -r '.revisions[2].prev_digest' "$plan")" = "$(jq -r '.revisions[1].digest' "$plan")" ] || fail "second revision not chained"
pass "a later base move chains onto the previous revision"

# -- patterns this helper does not interpret ------------------------------------
repo8="$(new_repo bracket)"
write_plan "$repo8" s8 '[]' 'src/[ab]*.js'
plan8="$repo8/.git/dev-flow-v2/slates/s8/plan.json"
cp "$plan8" "$tmp/bracket-plan.json"
moved="$(commit_touching "$repo8" src/a1.js)"
expect_refused "bracket fence" "pattern needs orchestrator judgment (not matched here): src/[ab]*.js" \
    pr "$repo8" alice s8 --new-base "$moved" --at 2026-01-01T01:00:00Z
cmp -s "$plan8" "$tmp/bracket-plan.json" || fail "a refused bracket move changed plan.json"
pass "a fence combining a bracket class with a wildcard makes a base move refuse instead of being matched"

repo9="$(new_repo literal)"
write_plan "$repo9" s9 '[]' 'app/[id]/page.tsx'
moved="$(commit_touching "$repo9" unrelated.txt)"
pr "$repo9" alice s9 --new-base "$moved" --at 2026-01-01T01:00:00Z >/dev/null ||
    fail "a literal [id] fence blocked an untouched base move"
pass "a literal [id] fence segment passes a base move that touches nothing in it"

repo10="$(new_repo question)"
write_plan "$repo10" s10 '[]' 'a?.js'
moved="$(commit_touching "$repo10" ab.js)"
expect_refused "? wildcard" "lane c (#3) fence: ab.js" \
    pr "$repo10" alice s10 --new-base "$moved" --at 2026-01-01T01:00:00Z
pass "a ? in a fence matches one character (a?.js matches ab.js)"

repo11="$(new_repo relative)"
write_plan "$repo11" s11 '[]'
git -C "$repo11" config diff.relative true
mkdir -p "$repo11/sub"
printf 'x\n' >"$repo11/sub/keep.txt"
git -C "$repo11" add -A
git -C "$repo11" commit -q -m sub
moved="$(commit_touching "$repo11" c/two.txt)"
expect_refused "diff.relative from a subdirectory" "lane c (#3) fence: c/two.txt" \
    bash -c "cd '$repo11/sub' && node '$reviser' base-move --slate s11 --session alice --owner-token \"$(cat "$tmp/token-s11")\" --reason r --new-base '$moved' --at 2026-01-01T01:00:00Z"
pass "diff.relative=true and a subdirectory cwd do not hide moved paths"

expect_refused "GIT_LITERAL_PATHSPECS" "lane c (#3) fence: c/two.txt" \
    bash -c "cd '$repo11/sub' && GIT_LITERAL_PATHSPECS=1 node '$reviser' base-move --slate s11 --session alice --owner-token \"$(cat "$tmp/token-s11")\" --reason r --new-base '$moved' --at 2026-01-01T01:00:00Z"
pass "GIT_LITERAL_PATHSPECS=1 does not hide moved paths"

# -- overridden history ----------------------------------------------------------
repo14="$(new_repo replaced)"
write_plan "$repo14" s14 '[]'
base14="$(git -C "$repo14" rev-parse HEAD)"
moved="$(commit_touching "$repo14" c/two.txt)"
git -C "$repo14" replace "$moved" "$base14"
expect_refused "replace ref hiding a fence move" "lane c (#3) fence: c/two.txt" \
    pr "$repo14" alice s14 --new-base "$moved" --at 2026-01-01T01:00:00Z
pass "a refs/replace override cannot hide a fence-touching move"

repo15="$(new_repo grafted)"
write_plan "$repo15" s15 '[]'
moved="$(commit_touching "$repo15" unrelated.txt)"
mkdir -p "$repo15/.git/info"
printf '%s\n' "$moved" >"$repo15/.git/info/grafts"
expect_refused "grafted history" "info/grafts exists" \
    pr "$repo15" alice s15 --new-base "$moved" --at 2026-01-01T01:00:00Z
pass "a repository with an info/grafts file is refused"

PLAN_REVISER="$reviser" node --input-type=module -e '
  const { pathMatches } = await import(process.env.PLAN_REVISER)
  const cases = [["a\u{1F600}.js", "a?.js"], ["n\nx.txt", "n*.txt"], ["d/a\u{1F600}\nb.js", "d/a*.js"]]
  for (const [path, pattern] of cases) {
    if (!pathMatches(path, pattern)) { console.error(`no match: ${JSON.stringify(path)} vs ${pattern}`); process.exit(1) }
  }
' || fail "? and * do not match an emoji or a line break as fence-check.sh does"
pass "? and * match any single code point, line breaks included, as in fence-check.sh"

# -- merge dependencies and overlaps ------------------------------------------
repo12="$(new_repo mergedep)"
write_plan "$repo12" s12 '[]' 'c/**' 1-3
plan12="$repo12/.git/dev-flow-v2/slates/s12/plan.json"
cp "$plan12" "$tmp/mergedep-plan.json"
moved="$(commit_touching "$repo12" a.txt)"
expect_refused "merge-dependency release" "done issue #1 releases dependent #3 (merge dependency)" \
    pr "$repo12" alice s12 --new-base "$moved" --done 1 --at 2026-01-01T01:00:00Z
cmp -s "$plan12" "$tmp/mergedep-plan.json" || fail "a refused merge-dependency release changed plan.json"
pass "a done issue that releases a merge-dependent issue is refused, naming the dependent"

repo13="$(new_repo prune)"
write_plan "$repo13" s13 '[]' 'c/**' 2-3
plan13="$repo13/.git/dev-flow-v2/slates/s13/plan.json"
[ "$(jq '.revisions[0].plan.overlaps | length' "$plan13")" = "1" ] || fail "fixture overlap missing"
moved="$(commit_touching "$repo13" c/one.txt)"
pr "$repo13" alice s13 --new-base "$moved" --done 3 --at 2026-01-01T01:00:00Z >/dev/null
node "$validator" plan "$plan13" >/dev/null || fail "plan with a pruned overlap does not validate"
[ "$(jq -c '.revisions[-1].plan.overlaps' "$plan13")" = "[]" ] || fail "the done issue's overlap was not pruned"
pass "an overlap with a done issue is pruned when its dependent side is the done one"

# -- dependent release -------------------------------------------------------
repo3="$(new_repo dependent)"
write_plan "$repo3" s3 '[1]'
plan3="$repo3/.git/dev-flow-v2/slates/s3/plan.json"
cp "$plan3" "$tmp/dependent-plan.json"
moved="$(commit_touching "$repo3" a.txt)"
expect_refused "dependent release" "done issue #1 releases dependent #3 (blocked_by)" \
    pr "$repo3" alice s3 --new-base "$moved" --done 1 --at 2026-01-01T01:00:00Z
cmp -s "$plan3" "$tmp/dependent-plan.json" || fail "a refused release changed plan.json"
pass "a done issue that releases a dependent is refused, naming the dependent"

# -- wave emptied ------------------------------------------------------------
repo4="$(new_repo wave)"
write_plan "$repo4" s4 '[]'
plan4="$repo4/.git/dev-flow-v2/slates/s4/plan.json"
moved="$(commit_touching "$repo4" a.txt b.txt)"
pr "$repo4" alice s4 --new-base "$moved" --done 1 --done 2 --at 2026-01-01T01:00:00Z >/dev/null
node "$validator" plan "$plan4" >/dev/null || fail "plan with an emptied wave does not validate"
[ "$(jq -c '.revisions[-1].plan.waves' "$plan4")" = '[{"number":1,"issues":[3]}]' ] || fail "emptied wave not dropped"
[ "$(jq -r '.revisions[-1].plan.lanes[0].wave' "$plan4")" = "1" ] || fail "lane wave not renumbered"
pass "an emptied wave is dropped and the later waves are renumbered in order"

# -- broken chain --------------------------------------------------------------
repo5="$(new_repo broken)"
write_plan "$repo5" s5 '[]'
plan5="$repo5/.git/dev-flow-v2/slates/s5/plan.json"
jq '.revisions[0].reason = "rewritten"' "$plan5" >"$tmp/broken.json"
cp "$tmp/broken.json" "$plan5"
moved="$(commit_touching "$repo5" unrelated.txt)"
expect_refused "broken chain" "tampered" \
    pr "$repo5" alice s5 --new-base "$moved" --at 2026-01-01T01:00:00Z
cmp -s "$plan5" "$tmp/broken.json" || fail "a broken chain was rewritten"
[ -e "$repo5/.git/dev-flow-v2/locks/s5.json" ] || fail "a refused broken-chain plan released the existing lock"
pass "a plan whose revision chain is broken is refused"

# -- non-descendant base -----------------------------------------------------------
repo6="$(new_repo sideways)"
write_plan "$repo6" s6 '[]'
git -C "$repo6" checkout -q --orphan other
git -C "$repo6" rm -rq --cached .
git -C "$repo6" commit -q --allow-empty -m other
other="$(git -C "$repo6" rev-parse HEAD)"
expect_refused "non-descendant base" "does not descend from the plan base" \
    pr "$repo6" alice s6 --new-base "$other" --at 2026-01-01T01:00:00Z
pass "a new base that does not descend from the plan base is refused"

# -- slate lock ----------------------------------------------------------------
repo7="$(new_repo locked)"
write_plan "$repo7" s7 '[]'
(cd "$repo7" && node "$writer" lock release --slate s7 --session alice --owner-token "$(cat "$tmp/token-s7")") >/dev/null
(cd "$repo7" && node "$writer" lock acquire --slate other-slate --session bob --issues 2) >"$tmp/token-other"
moved="$(commit_touching "$repo7" unrelated.txt)"
expect_refused "issue locked under another slate" "issue(s) 2 are already locked by session bob under slate other-slate" \
    bash -c "cd '$repo7' && node '$writer' lock acquire --slate s7 --session alice"
(cd "$repo7" && node "$writer" lock release --slate other-slate --session bob --owner-token "$(cat "$tmp/token-other")") >/dev/null
(cd "$repo7" && node "$writer" lock acquire --slate s7 --session alice) >"$tmp/token-s7"
pr "$repo7" alice s7 --new-base "$moved" --at 2026-01-01T01:00:00Z >/dev/null
[ "$(jq -r '.session' "$repo7/.git/dev-flow-v2/locks/s7.json")" = "alice" ] || fail "writer did not take the slate lock"
[ "$(jq -c '.issues' "$repo7/.git/dev-flow-v2/locks/s7.json")" = "[1,2,3]" ] || fail "lock scope not derived from the plan"
expect_refused "slate held by another session" "slate s7 is locked by session alice" \
    pr "$repo7" bob s7 --new-base "$moved" --at 2026-01-01T02:00:00Z
pass "plan writes take the slate lock and refuse while another session holds the work"

# Decision writers exercise the public CLI and canonical bytes in isolated repos.
node --input-type=module - "$asset_dir" "$tmp" <<'NODE'
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
const [assets, tmp] = process.argv.slice(2)
process.argv[1] = tmp
const reviser = join(assets, 'plan-revise.mjs'), writer = join(assets, 'run-record.mjs')
const { mayOverlap, effectiveFence } = await import(reviser)
assert.equal(mayOverlap('src/a.js', 'src/**'), true)
assert.equal(mayOverlap('src/a*.js', 'docs/**'), false)
assert.equal(mayOverlap('src/a*.js', 'src/b*.js'), true) // conservative
assert.deepEqual(effectiveFence({ fence: ['a'], expansions: [] }), [{ path: 'a' }])
const policy = {
  rigor: 'deep', rigor_source: 'fixture',
  caps: { challenge: 1, review: 1, integration: 1, remediation: 1, min_rounds: 1, wall_clock_min: 60 },
  breadth: { max_agent_runs: 10, max_parallel_agents: 3 }, strategy: 'plan', strategy_source: 'fixture',
  role_tiers: { orchestrator: 'apex', implementer: 'frontier', challenger: 'apex', reviewer: 'frontier', integrator: 'economy' }, operator_pins: [],
}
function addition(n, path = `area${n}/**`, wave = n) {
  return {
    issue: { number: n, title: `Issue ${n}`, url: `https://example.test/issues/${n}`, verdict: 'valid', candidate_files: [path], blocked_by: [] },
    lane: { lane: `l${n}`, issue: n, wave, branch: `issue-${n}`, run_id: `run-${n}`, fence: [{ path }], expansions: [] },
    profile: { lane: `l${n}`, policy },
  }
}
function content(base, additions) {
  return { base_sha: base, policy, dispatcher: { kind: 'interactive', parallel_cap: 3, foreman_max_parallel: null },
    issues: additions.map((a) => a.issue), lanes: additions.map((a) => a.lane), lane_profiles: additions.map((a) => a.profile),
    waves: additions.map((a) => ({ number: a.lane.wave, issues: [a.issue.number] })), overlaps: [] }
}
let serial = 0
function fixture(issues = '1,2,3,4,5') {
  const repo = join(tmp, `decisions-${++serial}`)
  mkdirSync(repo)
  const git = (...args) => execFileSync('git', args, { cwd: repo, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
  git('init', '-q', '-b', 'main')
  git('-c', 'user.name=t', '-c', 'user.email=t@example.test', 'commit', '--allow-empty', '-qm', 'base')
  const root = join(repo, '.git/dev-flow-v2'), canonical = join(root, 'slates/s/plan.json')
  const token = execFileSync(process.execPath, [writer, 'lock', 'acquire', '--slate', 's', '--session', 'owner', '--issues', issues], { cwd: repo, encoding: 'utf8' }).trim()
  const plan = content(git('rev-parse', 'HEAD'), [addition(1)])
  let calls = 0
  function call(command, { input, flags = [], ownerToken = token, at = '2026-10-22T12:00:00Z' } = {}) {
    const inputArgs = []
    if (input !== undefined) {
      const file = join(repo, `input-${++calls}.json`)
      writeFileSync(file, JSON.stringify(input))
      inputArgs.push('--input', file)
    }
    return spawnSync(process.execPath, [reviser, command, '--slate', 's', '--session', 'owner',
      ...(ownerToken === null ? [] : ['--owner-token', ownerToken]), '--reason', 'verified operator decision', '--at', at, ...inputArgs, ...flags], { cwd: repo, encoding: 'utf8' })
  }
  function ok(command, options) {
    const r = call(command, options)
    assert.equal(r.status, 0, `${command}: ${r.stderr}`)
    const doc = JSON.parse(readFileSync(canonical))
    const validation = spawnSync(process.execPath, [join(assets, 'validate-result-schemas.mjs'), 'plan', canonical], { encoding: 'utf8' })
    assert.equal(validation.status, 0, validation.stderr)
    return doc.revisions.at(-1).plan
  }
  function refuse(command, options, message, expectedStatus = 1) {
    const before = existsSync(canonical) ? readFileSync(canonical, 'utf8') : null
    const r = call(command, options)
    assert.equal(r.status, expectedStatus, `${command} expected exit ${expectedStatus}: ${r.stderr}`)
    assert.doesNotMatch(r.stderr, /TypeError|\n\s+at /, 'input error leaked a stack trace')
    assert.match(r.stderr, message)
    assert.equal(existsSync(canonical) ? readFileSync(canonical, 'utf8') : null, before, 'refusal mutated canonical plan')
  }
  return { repo, root, canonical, token, plan, ok, refuse }
}
const a = fixture('1')
a.refuse('genesis', { input: a.plan, ownerToken: null }, /requires --owner-token/)
a.refuse('genesis', { input: a.plan, ownerToken: 'wrong' }, /owner token does not match/)
a.refuse('genesis', { input: content(a.plan.base_sha, [addition(2)]) }, /outside the lock reservation/)
const unlocked = fixture()
execFileSync(process.execPath, [writer, 'lock', 'release', '--slate', 's', '--session', 'owner', '--owner-token', unlocked.token], { cwd: unlocked.repo })
unlocked.refuse('genesis', { input: unlocked.plan }, /lock acquire/)
assert.equal(existsSync(join(unlocked.root, 'locks/s.json')), false, 'genesis acquired a lock')
a.ok('genesis', { input: a.plan })
a.refuse('genesis', { input: a.plan }, /already has a plan/)
a.refuse('add-issue', { input: { issue: addition(2).issue, lane: addition(2).lane } }, /complete resolved profile/)
let current = a.ok('add-issue', { input: addition(2) })
assert.deepEqual(current.lane_profiles.find((p) => p.lane === 'l2'), addition(2).profile)
assert.deepEqual(JSON.parse(readFileSync(join(a.root, 'locks/s.json'))).issues, [1, 2])
a.refuse('add-issue', { input: addition(2) }, /already exists/)
a.refuse('expand', { flags: ['--lane', 'missing', '--path', 'free.txt'] }, /unknown receiving live lane/)
a.refuse('expand', { flags: ['--lane', 'l1', '--path', 'area2/deep/file.js'] }, /another live lane l2/)
a.refuse('expand', { flags: ['--lane', 'l1', '--path', 'free.txt'], at: '2026-10-21T00:00:00Z' }, /precedes revision/)
current = a.ok('expand', { flags: ['--lane', 'l1', '--path', 'free.txt'] })
assert.deepEqual(current.lanes[0].fence, a.plan.lanes[0].fence)
assert.deepEqual(current.lanes[0].expansions, [{ path: 'free.txt', at: '2026-10-22T12:00:00Z', reason: 'verified operator decision' }])
a.refuse('expand', { flags: ['--lane', 'l1', '--path', 'free.txt'] }, /already covered/)
// A retirement input cannot smuggle replacement original fences.
a.refuse('done', { input: { plan: { lanes: [{ ...current.lanes[1], fence: ['replacement'] }] } }, flags: ['--issue', '1'] }, /original fences are immutable/)
a.refuse('release', { flags: ['--issue', '1', '--lane', 'l2', '--path', 'not-owned.txt'] }, /outside finished lane/)
current = a.ok('release', { flags: ['--issue', '1', '--lane', 'l2', '--path', 'free.txt'] })
assert.equal(current.issues[0].verdict, 'done')
assert.equal(current.lanes.length, 1)
assert.deepEqual(current.lanes[0].fence, addition(2).lane.fence)
assert.equal(current.lanes[0].expansions[0].path, 'free.txt')
a.refuse('done', { flags: ['--issue', '1'] }, /no live source lane/)
current = a.ok('done', { flags: ['--issue', '2'] })
assert.deepEqual(current.lanes, [])
assert.deepEqual(current.waves, [])
assert.deepEqual(current.lane_profiles, [])
console.log('  PASS: genesis, add-issue, expand, release and done publish validated chains and refuse invalid decisions')
// Both genesis and add-issue refuse cross-wave glob intersections without a
// recorded decision; exact-string schema validation alone would accept these.
const b = fixture()
const glob = addition(2, 'area1/deep/file.js')
b.refuse('genesis', { input: content(b.plan.base_sha, [addition(1), glob]) }, /unresolved overlap/)
b.ok('genesis', { input: b.plan })
b.refuse('add-issue', { input: glob }, /unresolved overlap/)
const fenceOnly = addition(2)
fenceOnly.lane.fence = [{ path: 'area1/deep/file.js' }]
b.refuse('add-issue', { input: fenceOnly }, /unresolved effective fence overlap/)
const ambiguous = addition(2, 'area1/*.js')
b.refuse('add-issue', { input: ambiguous }, /unresolved overlap/)
const recorded = addition(2, 'area1/deep/file.js')
recorded.overlaps = [{ issue_a: 2, issue_b: 1, resolution: 'serialize', merge_dependency: { before: 1, after: 2 } }]
b.refuse('add-issue', { input: recorded }, /needs a shared candidate entry/)
console.log('  PASS: glob-covered and cross-wave collisions fail closed beyond exact schema comparisons')
// Resolutions provide choices; the writer computes all intersection paths and
// canonical issue ordering even when input issues/decisions are reversed.
const c = fixture()
const one = addition(1, 'shared.txt', 1), two = addition(2, 'shared.txt', 2)
const shared = content(c.plan.base_sha, [two, one])
shared.overlaps = [{ issue_a: 2, issue_b: 1, paths: ['invented.txt'], resolution: 'serialize', merge_dependency: { before: 1, after: 2 } }]
current = c.ok('genesis', { input: shared })
assert.deepEqual(current.overlaps, [{ issue_a: 1, issue_b: 2, paths: ['shared.txt'], resolution: 'serialize', merge_dependency: { before: 1, after: 2 } }])
const three = addition(3, 'shared.txt', 3)
three.overlaps = [1, 2].map((n) => ({ issue_a: 3, issue_b: n, resolution: 'split', merge_dependency: { before: n, after: 3 } }))
current = c.ok('add-issue', { input: three })
assert.equal(current.overlaps.length, 3)
c.refuse('release', { flags: ['--issue', '1', '--lane', 'l2', '--path', 'shared.txt'] }, /another live lane l3/)
current = c.ok('done', { flags: ['--issue', '1'], input: { waves: [{ number: 1, issues: [2] }, { number: 2, issues: [3] }] } })
assert.equal(current.issues.find((i) => i.number === 1).verdict, 'done')
console.log('  PASS: complete pairwise intersections, canonical pairs and wave decisions are recorded')
const d = fixture()
d.ok('genesis', { input: d.plan })
current = d.ok('done', { flags: ['--issue', '1'], input: { addition: addition(2), releases: [{ lane: 'l2', paths: ['area1/file.js'] }], waves: [{ number: 1, issues: [2] }] } })
assert.equal(current.lanes[0].expansions.length, 0)
assert.equal(current.lanes[0].fence.at(-1).path, 'area1/file.js')
const e = fixture()
e.ok('genesis', { input: content(e.plan.base_sha, [addition(1), addition(2)]) })
current = e.ok('done', { flags: ['--issue', '1'], input: { releases: [{ lane: 'l2', paths: ['area1/file.js'] }] } })
assert.equal(current.lanes[0].expansions[0].path, 'area1/file.js')
console.log('  PASS: retirement releases to an existing receiver append expansions; a new receiver gets its original fence')
// Try to introduce a lane reusing an existing run with a changed original
// fence. The candidate validator must reject without changing canonical bytes.
const f = fixture()
f.ok('genesis', { input: f.plan })
const reuse = addition(2)
reuse.lane.run_id = 'run-1'
f.refuse('add-issue', { input: reuse }, /immutable|duplicate run_id|remain bound/)
console.log('  PASS: immutable original fences and run bindings survive candidate publication')
// R1: schema rejection must not widen a live lock or strand issue 2.
const narrow = fixture('1')
narrow.ok('genesis', { input: narrow.plan })
const lockFile = join(narrow.root, 'locks/s.json')
const lockBefore = readFileSync(lockFile, 'utf8')
const badRun = addition(2)
badRun.lane.run_id = 'run-1'
narrow.refuse('add-issue', { input: badRun }, /duplicate run_id|remain bound|immutable/)
assert.equal(readFileSync(lockFile, 'utf8'), lockBefore, 'refused addition widened reservation')
// The same prevalidation covers a done/release decision adding a receiver.
const badProfile = addition(2)
badProfile.profile.policy = { ...policy, extra: true }
narrow.refuse('done', { flags: ['--issue', '1'], input: { addition: badProfile } }, /additional property|extra/)
assert.equal(readFileSync(lockFile, 'utf8'), lockBefore, 'refused receiver addition widened reservation')
const other = spawnSync(process.execPath, [writer, 'lock', 'acquire', '--slate', 'other', '--session', 'other', '--issues', '2'], { cwd: narrow.repo, encoding: 'utf8' })
assert.equal(other.status, 0, other.stderr)
console.log('  PASS: validation refuses additions before lock widening, leaving other slates free to reserve the issue')
// R2: valid unsorted input is normalized by wave number, not array order.
const unsorted = fixture('1,2,3')
const unsortedPlan = content(unsorted.plan.base_sha, [addition(1), addition(2), addition(3)])
unsortedPlan.waves = [unsortedPlan.waves[1], unsortedPlan.waves[0], unsortedPlan.waves[2]]
unsorted.ok('genesis', { input: unsortedPlan })
current = unsorted.ok('done', { flags: ['--issue', '3'] })
assert.deepEqual(current.lanes.map((lane) => [lane.lane, lane.wave]), [['l1', 1], ['l2', 2]])
assert.deepEqual(current.waves, [{ number: 1, issues: [1] }, { number: 2, issues: [2] }])
console.log('  PASS: retirement sorts unsorted waves before renumbering, preserving dispatch order')
// R3: legacy plans name the documented manual backfill path, while unrelated
// keys are rejected without implying a fence violation.
const legacy = fixture('1')
const legacyPlan = structuredClone(legacy.plan)
delete legacyPlan.lane_profiles
legacy.ok('genesis', { input: legacyPlan })
legacy.refuse('add-issue', { input: addition(2) }, /hand-append a validated revision recording complete lane_profiles, per orchestrate SKILL.md § Planning/)
legacy.refuse('add-issue', { input: { ...addition(2), lane_profiles: [] } }, /^refused: addition\.lane_profiles is not accepted by this writer\s*$/)
legacy.refuse('done', { flags: ['--issue', '1'], input: { fence: ['replacement'] } }, /is not accepted by this writer; existing original fences are immutable/)
console.log('  PASS: refusal messages distinguish unsupported keys, immutable fences and manual profile backfill')
// R4: missing, scalar, empty and non-string path inputs are usage errors,
// never TypeErrors; the canonical plan and lock remain unchanged.
const malformed = fixture('1')
malformed.ok('genesis', { input: malformed.plan })
for (const [field, values] of [['candidate_files', [undefined, null, 'file.js', [], [17], ['']]],
  ['fence', [undefined, null, 'file.js', [], [17], [''], [{}], [{ path: 17 }]]]]) {
  for (const value of values) {
    const bad = addition(2)
    const target = field === 'fence' ? bad.lane : bad.issue
    if (value === undefined) delete target[field]
    else target[field] = value
    const before = readFileSync(join(malformed.root, 'locks/s.json'), 'utf8')
    malformed.refuse('add-issue', { input: bad }, new RegExp(field), 2)
    assert.equal(readFileSync(join(malformed.root, 'locks/s.json'), 'utf8'), before)
  }
}
const invalidGenesis = fixture('1')
const missingCandidates = structuredClone(invalidGenesis.plan)
delete missingCandidates.issues[0].candidate_files
invalidGenesis.refuse('genesis', { input: missingCandidates }, /candidate_files/, 2)
const missingFence = structuredClone(invalidGenesis.plan)
delete missingFence.lanes[0].fence
invalidGenesis.refuse('genesis', { input: missingFence }, /fence/, 2)
const strings = addition(2)
strings.lane.fence = ['area2/**']
current = malformed.ok('add-issue', { input: strings })
assert.deepEqual(current.lanes[1].fence, ['area2/**'])
console.log('  PASS: malformed decision paths exit 2 with the named field, preserving string and object fence support')
// Challenge r2: source ownership must never interpret a bracket-class glob.
for (const command of ['release', 'done']) {
  for (const [source, path] of [['src/[ab]*.js', 'src/[ab]evil.js'], ['src/**', 'src/[ab]*.js']]) {
    const guarded = fixture('1')
    guarded.ok('genesis', { input: content(guarded.plan.base_sha, [addition(1, source)]) })
    const before = readFileSync(join(guarded.root, 'locks/s.json'), 'utf8')
    const input = { addition: addition(2, 'other/**', 1) }
    const flags = ['--issue', '1']
    if (command === 'release') flags.push('--lane', 'l2', '--path', path)
    else input.releases = [{ lane: 'l2', paths: [path] }]
    guarded.refuse(command, { input, flags }, /needs orchestrator judgment/)
    assert.equal(readFileSync(join(guarded.root, 'locks/s.json'), 'utf8'), before, 'uninterpretable release changed the lock')
  }
}
const literalBracket = fixture('1')
literalBracket.ok('genesis', { input: content(literalBracket.plan.base_sha, [addition(1, 'src/**')]) })
current = literalBracket.ok('release', { input: { addition: addition(2, 'other/**', 1) },
  flags: ['--issue', '1', '--lane', 'l2', '--path', 'src/[id]/page.js'] })
assert.equal(current.lanes[0].fence.at(-1).path, 'src/[id]/page.js')
console.log('  PASS: release and done refuse uninterpretable source/request patterns without plan or lock changes; literal brackets remain supported')


NODE

[ -z "$(find "$tmp" -name '*.candidate.*')" ] || fail "a candidate file was left behind"
echo "test-plan-revise: all cases passed"
