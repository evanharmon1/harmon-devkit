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
# Run from scripts/test-skills.sh (task test:skills) and task test:plan-revise.
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

# write_plan REPO SLATE BLOCKER — revision 0 for issues #1 (wave 1, lane a,
# fence a.txt), #2 (wave 1, lane b, fence b.txt) and #3 (wave 2, lane c,
# fence c/**). BLOCKER is #3's blocked_by list as JSON (e.g. [] or [1]).
write_plan() {
    local repo="$1" slate="$2" blocked="$3"
    local base dir
    base="$(git -C "$repo" rev-parse HEAD)"
    dir="$repo/.git/dev-flow-v2/slates/$slate"
    mkdir -p "$dir"
    PLAN_BASE="$base" PLAN_SLATE="$slate" PLAN_BLOCKED="$blocked" PLAN_WRITER="$writer" node --input-type=module -e '
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
        lanes: [lane("a", 1, 1, ["a.txt"]), lane("b", 2, 1, ["b.txt"]), lane("c", 3, 2, ["c/**"])],
      }
      const at = "2026-01-01T00:00:00Z", reason = "initial plan"
      const digest = chainDigest({ seq: 0, plan, at, reason }, "genesis")
      const document = { schema: 1, slate_id: process.env.PLAN_SLATE, revisions: [{ seq: 0, prev_digest: "genesis", digest, at, reason, plan }] }
      process.stdout.write(JSON.stringify(document, null, 2) + "\n")
    ' >"$dir/plan.json"
    node "$validator" plan "$dir/plan.json" >/dev/null || fail "fixture plan for $slate is invalid"
}

# pr REPO SESSION SLATE ARGS... — run base-move from inside REPO.
pr() {
    local repo="$1" session="$2" slate="$3"
    shift 3
    (cd "$repo" && node "$reviser" base-move --slate "$slate" --session "$session" --reason "main moved" "$@")
}

# -- disjoint base move ------------------------------------------------------
repo="$(new_repo disjoint)"
write_plan "$repo" s1 '[]'
plan="$repo/.git/dev-flow-v2/slates/s1/plan.json"
new_base="$(commit_touching "$repo" a.txt unrelated.txt)"
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
(cd "$repo7" && node "$writer" lock acquire --slate other-slate --session bob --issues 2) >/dev/null
moved="$(commit_touching "$repo7" unrelated.txt)"
expect_refused "issue locked under another slate" "issue(s) 2 are already locked by session bob under slate other-slate" \
    pr "$repo7" alice s7 --new-base "$moved" --at 2026-01-01T01:00:00Z
(cd "$repo7" && node "$writer" lock release --slate other-slate --session bob) >/dev/null
pr "$repo7" alice s7 --new-base "$moved" --at 2026-01-01T01:00:00Z >/dev/null
[ "$(jq -r '.session' "$repo7/.git/dev-flow-v2/locks/s7.json")" = "alice" ] || fail "writer did not take the slate lock"
[ "$(jq -c '.issues' "$repo7/.git/dev-flow-v2/locks/s7.json")" = "[1,2,3]" ] || fail "lock scope not derived from the plan"
expect_refused "slate held by another session" "slate s7 is locked by session alice" \
    pr "$repo7" bob s7 --new-base "$moved" --at 2026-01-01T02:00:00Z
pass "plan writes take the slate lock and refuse while another session holds the work"

if find "$tmp" -name '*.candidate.*' | grep -q .; then fail "a candidate file was left behind"; fi
echo "test-plan-revise: all cases passed"
