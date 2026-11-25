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

# Activation checks the executing tools' checkout as well as the lane branch.
# Keep both in controlled repositories, independent of the outer branch's age.
source_root="$(git -C "$asset_dir" rev-parse --show-toplevel)"
tool_root="$tmp/tool-root"
mkdir -p "$tool_root"
cp -R "$source_root/ai" "$tool_root/ai"
cp "$source_root/.devflow.toml" "$source_root/agent-registry.json" "$tool_root/"
git init -q -b main "$tool_root"
git -C "$tool_root" add ai .devflow.toml agent-registry.json
git -C "$tool_root" -c user.name=test -c user.email=test@example.test commit -qm 'controlled executing tools'
git -C "$tool_root" update-ref refs/remotes/origin/main HEAD
git -C "$tool_root" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
asset_dir="$tool_root/ai/skills/universal/dev-flow-support/assets"
reviser="$asset_dir/plan-revise.mjs"
writer="$asset_dir/run-record.mjs"
validator="$asset_dir/validate-result-schemas.mjs"
# Exercise the plan writer's use of the established claim helper interfaces
# without making live GitHub writes. The helpers' own suites cover their API
# behavior; these stubs prove plan transitions call them in the right order.
cat >"$tool_root/ai/skills/universal/track-work/assets/release-claim.sh" <<'MOCK_RELEASE'
#!/usr/bin/env bash
printf 'release %s\n' "$*" >>"${CLAIM_HELPER_LOG:?}"
if [ "${MOCK_RELEASE_UNCLAIMED:-}" = yes ]; then
    echo 'example/repo#1 has no trusted claim comment — nothing to release' >&2
    exit 3
fi
if [ "${MOCK_RELEASE_WRONG_BRANCH:-}" = yes ]; then
    echo "example/repo#1: claim of record is for branch 'newer-branch', not 'issue-1' — this close does not own it" >&2
    exit 3
fi
if [ "${MOCK_RELEASE_FAIL:-}" = yes ]; then
    echo 'simulated claim release failure' >&2
    exit 5
fi
exit 0
MOCK_RELEASE
cat >"$tool_root/ai/skills/universal/claim/assets/claim-transaction.sh" <<'MOCK_CLAIM'
#!/usr/bin/env bash
printf 'restore %s\n' "$*" >>"${CLAIM_HELPER_LOG:?}"
if [ "${MOCK_CLAIM_FAIL:-}" = yes ]; then
    echo 'simulated claim restoration failure' >&2
    exit 6
fi
if [ "${MOCK_CLAIM_REQUIRE_APPROVAL:-}" = yes ] && [[ " $* " != *" --approve-review-pullback "* ]]; then
    echo 'needs-review requires --approve-review-pullback' >&2
    exit 7
fi
if [ "${MOCK_CLAIM_REQUIRE_PR:-}" = yes ] && [[ " $* " != *" --pr "* ]]; then
    echo 'claim-transaction reactivation requires --pr' >&2
    exit 8
fi
exit 0
MOCK_CLAIM
chmod +x "$tool_root/ai/skills/universal/track-work/assets/release-claim.sh" \
    "$tool_root/ai/skills/universal/claim/assets/claim-transaction.sh"
mkdir -p "$tool_root/ai/skills/universal/integrate/assets"
cat >"$tool_root/ai/skills/universal/integrate/assets/readiness-gate.sh" <<'MOCK_GATE'
#!/usr/bin/env bash
if [ "${MOCK_GATE_FAIL:-}" = yes ]; then
    echo 'simulated readiness-gate fingerprint failure' >&2
    exit 2
fi
printf '{"status":"fingerprint","fingerprint":"%s"}\n' "${MOCK_GATE_FINGERPRINT:-test-gate-pass}"
MOCK_GATE
chmod +x "$tool_root/ai/skills/universal/integrate/assets/readiness-gate.sh"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'MOCK_GH'
#!/usr/bin/env bash
if [ -n "${MEMBERSHIP_FIXTURE:-}" ]; then
    case "$1 $2" in
    'label list')
        if [ -n "${MEMBERSHIP_RELEASE:-}" ]; then
            touch "$MEMBERSHIP_RELEASE.ready"
            deadline=$((SECONDS + 10))
            while [ ! -e "$MEMBERSHIP_RELEASE" ]; do
                [ "$SECONDS" -lt "$deadline" ] || exit 1
                sleep 0.02
            done
        fi
        printf '[{"name":"slated"}]\n' ;;
    'issue view')
        if [ -e "$MEMBERSHIP_FIXTURE/slated" ]; then
            printf '{"labels":[{"name":"slated"}]}\n'
        else
            printf '{"labels":[]}\n'
        fi ;;
    'api user') printf '{"login":"fixture"}\n' ;;
    'api repos/'*) cat "$MEMBERSHIP_FIXTURE/comments" ;;
    'issue comment') jq -nc --arg body "$7" '{body: $body}' >>"$MEMBERSHIP_FIXTURE/comments" ;;
    'issue edit')
        case "$6" in
        --add-label) touch "$MEMBERSHIP_FIXTURE/slated" ;;
        --remove-label) rm "$MEMBERSHIP_FIXTURE/slated" ;;
        *) exit 1 ;;
        esac ;;
    *) exit 1 ;;
    esac
    exit $?
fi
if [ "$1" = api ]; then
    printf '%s\n' "$2" >>"${CLAIM_API_LOG:?}"
    [ "${MOCK_CLAIM_API_FAIL:-}" != yes ] || { echo 'simulated issue read failure' >&2; exit 1; }
    if [ "${MOCK_CLAIM_API_RESPONSE+x}" = x ]; then printf '%s\n' "$MOCK_CLAIM_API_RESPONSE"
    else printf '{"labels":[]}\n'; fi
    exit 0
fi
if [ "$1" = label ] && [ "$2" = list ]; then
    if [ -n "${SLOW_MEMBERSHIP_MARKER:-}" ]; then
        touch "$SLOW_MEMBERSHIP_MARKER"
        sleep 20
    fi
    printf '[]\n'
    exit 0
fi
if [ "$1" = issue ] && [ "$2" = view ]; then printf '{"state":"OPEN","labels":[]}\n'; exit 0; fi
if [ "$1" = pr ] && [ "$2" = view ]; then
    if [ "${MOCK_PR_VIEW_FAIL:-}" = yes ]; then echo 'simulated pr read failure' >&2; exit 1; fi
    if [ "${MOCK_MERGED_PR:-}" = "${3##*/}" ]; then state='MERGED'
    else state='OPEN'; fi
    draft="${MOCK_PR_DRAFT:-true}"
    head="${MOCK_PR_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
    if [ "${MOCK_PR_LABELS+x}" = x ]; then labels="$MOCK_PR_LABELS"
    else labels='[]'; fi
    if [ "${MOCK_PR_RESPONSE+x}" = x ]; then printf '%s\n' "$MOCK_PR_RESPONSE"
    else printf '{"state":"%s","isDraft":%s,"headRefOid":"%s","labels":%s}\n' "$state" "$draft" "$head" "$labels"; fi
    exit 0
fi
echo "unexpected gh call: $*" >&2
exit 1
MOCK_GH
chmod +x "$tmp/bin/gh"
cat >"$tmp/valid-gate.json" <<'GATE_JSON'
{"status":"pass","condition":"ready","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","fingerprint":"test-gate-pass"}
GATE_JSON
export CLAIM_HELPER_LOG="$tmp/claim-helper.log"
export CLAIM_API_LOG="$tmp/claim-api.log"
export PATH="$tmp/bin:$PATH"

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
        number, title: `Issue ${number}`, url: `https://github.com/example/repo/issues/${number}`,
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

# Base moves do not wait for dispatch admission's live GitHub reads.
lock_repo="$(new_repo lock-order)"
write_plan "$lock_repo" lock-order '[]'
lock_base="$(commit_touching "$lock_repo" unrelated.txt)"
lock_root="$lock_repo/.git/dev-flow-v2"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({pid: process.ppid, host: require("os").hostname()}))' "$lock_root/dispatch.wlock"
pr "$lock_repo" alice lock-order --new-base "$lock_base" --at 2026-01-01T01:00:00Z >"$tmp/lock-order.out" 2>&1 ||
    fail "base-move waited for dispatch mutex: $(cat "$tmp/lock-order.out")"
rm "$lock_root/dispatch.wlock"
pass "base-move succeeds while the dispatch mutex is held"

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
before_dry_run="$(cat "$plan")"
dry_rc=0
dry_output="$(pr "$repo" alice s1 --new-base "$new_base" --dry-run 2>&1)" || dry_rc=$?
[ "$dry_rc" -eq 2 ] || fail "revision dry-run expected exit 2, got $dry_rc: $dry_output"
[[ "$dry_output" == *"unknown flag --dry-run"* ]] || fail "revision dry-run missing unknown flag: $dry_output"
[ "$(cat "$plan")" = "$before_dry_run" ] || fail "revision dry-run modified plan"
revision_output="$(pr "$repo" alice s1 --new-base "$new_base" --done 1 --at 2026-01-01T01:00:00Z)"
[[ "$revision_output" == *"membership: example/repo has no slated label; skipped"* ]] || fail "base-move did not report skipped membership: $revision_output"
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

# -- explicit re-verification --------------------------------------------------
repo_r="$(new_repo reverified)"
write_plan "$repo_r" sr '[]'
plan_r="$repo_r/.git/dev-flow-v2/slates/sr/plan.json"
(cd "$repo_r" && node "$reviser" handoff --slate sr --session alice --owner-token "$(cat "$tmp/token-sr")" --issue 2 --pr 22 --check-result "$tmp/valid-gate.json" --reason handed --at 2026-01-01T00:30:00Z) >/dev/null
cp "$plan_r" "$tmp/reverified-before.json"
move_r="$(commit_touching "$repo_r" a.txt b.txt)"
expect_refused "unknown re-verification" "not a live issue" pr "$repo_r" alice sr --new-base "$move_r" --reverified 99 --at 2026-01-01T01:00:00Z
expect_refused "handed-off re-verification" "not a live issue" pr "$repo_r" alice sr --new-base "$move_r" --reverified 2 --at 2026-01-01T01:00:00Z
expect_refused "untouched re-verification" "no fence or candidate collision" pr "$repo_r" alice sr --new-base "$move_r" --reverified 3 --at 2026-01-01T01:00:00Z
mkdir -p "$repo_r/.git/dev-flow-v2/runs/run-1"
printf "{}\n" >"$repo_r/.git/dev-flow-v2/runs/run-1/run.json"
expect_refused "provisioned re-verification" "provisioned lane a (run run-1)" pr "$repo_r" alice sr --new-base "$move_r" --reverified 1 --at 2026-01-01T01:00:00Z
rm "$repo_r/.git/dev-flow-v2/runs/run-1/run.json"
expect_refused "run directory alone" "provisioned lane a" pr "$repo_r" alice sr --new-base "$move_r" --reverified 1 --at 2026-01-01T01:00:00Z
rmdir "$repo_r/.git/dev-flow-v2/runs/run-1"
expect_refused "older re-verification" "precedes revision" pr "$repo_r" alice sr --new-base "$move_r" --reverified 1 --at 2025-01-01T01:00:00Z
cmp -s "$plan_r" "$tmp/reverified-before.json" || fail "refused re-verification wrote plan"
output_r="$(pr "$repo_r" alice sr --new-base "$move_r" --reverified 1 --reverified 1 --at 2026-01-01T01:00:00Z)"
[[ "$output_r" == *'reverified #1'* && "$output_r" != *'reverified #1 #1'* ]] || fail "summary does not deduplicate re-verification"
jq -e '.revisions[-1].reason | endswith("reverified #1") and (contains("#1 #1") | not)' "$plan_r" >/dev/null || fail "reason omits decision"
[ "$(jq -c '.revisions[0].plan.lanes[] | select(.issue == 1) | .fence' "$plan_r")" = "$(jq -c '.revisions[-1].plan.lanes[] | select(.issue == 1) | .fence' "$plan_r")" ] || fail "fence changed"
[ "$(jq -c '.revisions[0].plan.issues[] | select(.number == 1) | .candidate_files' "$plan_r")" = "$(jq -c '.revisions[-1].plan.issues[] | select(.number == 1) | .candidate_files' "$plan_r")" ] || fail "candidates changed"
node "$validator" plan "$plan_r" >/dev/null
pass "re-verification accepts only a colliding unprovisioned live lane and records the decision"

repo_m="$(new_repo reverified-mixed)"
write_plan "$repo_m" sm '[]'
plan_m="$repo_m/.git/dev-flow-v2/slates/sm/plan.json"
cp "$plan_m" "$tmp/mixed-before.json"
move_m="$(commit_touching "$repo_m" a.txt b.txt)"
expect_refused "uncovered collision" "lane b (#2) fence" pr "$repo_m" alice sm --new-base "$move_m" --reverified 1 --at 2026-01-01T01:00:00Z
cmp -s "$plan_m" "$tmp/mixed-before.json" || fail "mixed collision wrote plan"
pr "$repo_m" alice sm --new-base "$move_m" --reverified 1 --reverified 2 --at 2026-01-01T01:00:00Z >/dev/null
pass "other collisions refuse atomically; repeatable decisions cover both"

# A merge's side parent predates oldBase and must not manufacture collisions.
repo_side="$(new_repo side-parent)"
git -C "$repo_side" branch side
commit_touching "$repo_side" a.txt >/dev/null
write_plan "$repo_side" ss '[]'
git -C "$repo_side" checkout -q side
commit_touching "$repo_side" unrelated.txt >/dev/null
git -C "$repo_side" checkout -q main
git -C "$repo_side" merge -q --no-ff side -m merge
merge_side="$(git -C "$repo_side" rev-parse HEAD)"
expect_refused "unchanged merge fence" "no fence or candidate collision" pr "$repo_side" alice ss --new-base "$merge_side" --reverified 1 --at 2026-01-01T01:00:00Z
pr "$repo_side" alice ss --new-base "$merge_side" --at 2026-01-01T01:00:00Z >/dev/null
pass "a side parent predating the base does not create a collision"

PLAN_REVISER="$reviser" PLAN_FILE="$plan_r" node --input-type=module -e '
  import assert from "node:assert/strict"
  import { readFileSync } from "node:fs"
  const { reviseForBaseMove } = await import(process.env.PLAN_REVISER)
  const plan = JSON.parse(readFileSync(process.env.PLAN_FILE)).revisions[0].plan
  assert.throws(() => reviseForBaseMove(plan, { newBase: plan.base_sha, done: [], changed: ["a.txt"], reverified: [1] }), /--reverified requires state root/)
'
pass "direct re-verification requires a state root"

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
expect_refused "reverified bracket fence" "pattern needs orchestrator judgment (not matched here): src/[ab]*.js" \
    pr "$repo8" alice s8 --new-base "$moved" --reverified 3 --at 2026-01-01T01:00:00Z
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
import { execFileSync, spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync, unlinkSync } from 'node:fs'
import { join } from 'node:path'
import { hostname } from 'node:os'
const [assets, tmp] = process.argv.slice(2)
process.argv[1] = tmp
const reviser = join(assets, 'plan-revise.mjs'), writer = join(assets, 'run-record.mjs')
const { chainDigest } = await import(writer)
const { mayOverlap, effectiveFence } = await import(reviser)
assert.equal(mayOverlap('src/a.js', 'src/**'), true)
assert.equal(mayOverlap('src/a*.js', 'docs/**'), false)
assert.equal(mayOverlap('src/a*.js', 'src/b*.js'), true) // conservative
assert.deepEqual(effectiveFence({ fence: ['a'], expansions: [] }), [{ path: 'a' }])
const policy = {
  rigor: 'deep', rigor_source: 'fixture',
  caps: { challenge: 1, review: 1, integration: 1, remediation: 1, min_rounds: 1, wall_clock_min: 60 },
  breadth: { max_agent_runs: 10, max_parallel_agents: 3, max_in_flight: 5 }, strategy: 'plan', strategy_source: 'fixture',
  role_tiers: { orchestrator: 'apex', implementer: 'frontier', challenger: 'apex', reviewer: 'frontier', integrator: 'economy' }, operator_pins: [],
}
function addition(n, path = `area${n}/**`, wave = n) {
  return {
    issue: { number: n, title: `Issue ${n}`, url: `https://github.com/example/repo/issues/${n}`, verdict: 'valid', candidate_files: [path], blocked_by: [] },
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
  writeFileSync(join(repo, 'agent-registry.json'), JSON.stringify({ trusted_orchestrator_actor_ids: [12345] }))
  git('add', 'agent-registry.json')
  git('-c', 'user.name=t', '-c', 'user.email=t@example.test', 'commit', '--allow-empty', '-qm', 'base')
  const root = join(repo, '.git/dev-flow-v2'), canonical = join(root, 'slates/s/plan.json')
  const claimRecord = join(repo, 'claim-record.md'), registrySnapshot = join(repo, 'registry.json'), gateResult = join(repo, 'gate-result.json')
  writeFileSync(claimRecord, 'Claiming — starting implementation on branch issue-1 (session fixture).\n\nClaim record (for `/wrap` — undo only what this claim added):\n')
  writeFileSync(registrySnapshot, JSON.stringify({ families: [{ slug: 'gpt' }] }))
  writeFileSync(gateResult, JSON.stringify({ status: 'pass', condition: 'ready', head: 'a'.repeat(40), fingerprint: 'test-gate-pass' }))
  const token = execFileSync(process.execPath, [writer, 'lock', 'acquire', '--slate', 's', '--session', 'owner', '--issues', issues], { cwd: repo, encoding: 'utf8' }).trim()
  const plan = content(git('rev-parse', 'HEAD'), [addition(1)])
  let calls = 0
  function call(command, { input, flags = [], ownerToken = token, at = '2026-10-22T12:00:00Z', gate = true } = {}) {
    const inputArgs = []
    if (input !== undefined) {
      const file = join(repo, `input-${++calls}.json`)
      writeFileSync(file, JSON.stringify(input))
      inputArgs.push('--input', file)
    }
    if (command === 'reactivate' && !flags.includes('--claim-record-file')) {
      const issueIndex = flags.indexOf('--issue')
      const issue = issueIndex >= 0 ? flags[issueIndex + 1] : '1'
      const currentPlan = existsSync(canonical) ? JSON.parse(readFileSync(canonical)).revisions.at(-1).plan : null
      const retained = currentPlan?.retained_lanes?.find((entry) => String(entry.lane.issue) === issue)
      if (retained) {
        const branch = retained.lane.branch ?? `issue-${issue}`
        writeFileSync(claimRecord, `Claiming — starting implementation on branch ${branch} (session fixture).\n\nClaim record (for \`/wrap\` — undo only what this claim added):\n`)
      }
    }
    const isHandoffGateDefault = command === 'handoff' && gate !== false && !flags.includes('--check-result') && !flags.includes('--gate')
    const gateArgs = isHandoffGateDefault ? ['--check-result', gateResult] : []
    const claimArgs = command === 'reactivate' && !flags.includes('--claim-record-file') &&
      (existsSync(canonical) && JSON.parse(readFileSync(canonical)).revisions.at(-1).plan.retained_lanes?.some((entry) => String(entry.lane.issue) === (flags.includes('--issue') ? flags[flags.indexOf('--issue') + 1] : '1')))
      ? ['--claim-record-file', claimRecord, '--claim-label', 'claim:gpt', '--model-label', 'none',
        '--family', 'gpt', '--registry-snapshot', registrySnapshot]
      : []
    return spawnSync(process.execPath, [reviser, command, '--slate', 's', '--session', 'owner',
      ...(ownerToken === null ? [] : ['--owner-token', ownerToken]), '--reason', 'verified operator decision', '--at', at, ...inputArgs, ...gateArgs, ...flags, ...claimArgs], { cwd: repo, encoding: 'utf8' })
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
  return { repo, root, canonical, token, plan, call, ok, refuse }
}
{
// #1802: complete resolver JSON is projected by the same exported function as lane-init.
const { planPolicy, lanePolicyProjection } = await import(writer)
const { resolvePolicy } = await import(join(assets, 'devflow-policy.mjs'))
const { parseToml } = await import(join(assets, 'lib/toml-lite.mjs'))
const fullPolicy = JSON.parse(JSON.stringify(resolvePolicy(parseToml(readFileSync(join(assets, '../../../../../.devflow.toml'), 'utf8')))))
const projectedPolicy = planPolicy(fullPolicy)
// Real migration fixtures retain the historical shared integration budget.
// They remain valid inputs to solo-init's shared projection helper.
for (const name of ['merge-base-legacy-to-v2', 'merge-base-v1-mutation-invariant']) {
  const fixtureDir = join(assets, '../../../../schemas/fixtures/exit', name)
  const historical = resolvePolicy(parseToml(readFileSync(join(fixtureDir, 'policy.toml'), 'utf8')), {
    mergeBaseDoc: parseToml(readFileSync(join(fixtureDir, 'policy.merge-base.toml'), 'utf8')),
  })
  assert.equal(historical.rounds.integration_exempt, 0)
  assert.equal(historical.rounds.shared_budget, true)
  const projected = planPolicy(historical)
  assert.equal(projected.caps.integration, historical.rounds.integration)
  assert.equal(projected.rigor, historical.rigor.level)
  assert.deepEqual(projected.role_tiers, Object.fromEntries(Object.entries(historical.roles).map(([role, value]) => [role, value.tier])))
}
console.log('  PASS: shared policy projection accepts both historical merge-base migration fixtures')

// Pause the first writer immediately after taking dispatch. Start its rival
// and wait for that writer to reach the same lock before allowing publication.
const reservationBarrier = join(tmp, 'reservation-barrier.mjs')
writeFileSync(reservationBarrier, `
import fs from 'node:fs'
import { syncBuiltinESMExports } from 'node:module'
const { linkSync } = fs
fs.linkSync = (source, target) => {
  const { RESERVATION_ENTERED, RESERVATION_RELEASE, PLAN_LOCK_ATTEMPT } = process.env
  if (PLAN_LOCK_ATTEMPT && (target.endsWith('/plan.json.wlock') || target.endsWith('/dispatch.wlock')) && !fs.existsSync(PLAN_LOCK_ATTEMPT)) {
    let acquired = false
    try {
      linkSync(source, target)
      acquired = true
    } finally {
      if (acquired) fs.writeFileSync(PLAN_LOCK_ATTEMPT + '.acquired', '')
      fs.writeFileSync(PLAN_LOCK_ATTEMPT, '')
    }
    return
  }
  if (!RESERVATION_ENTERED) return linkSync(source, target)
  if (!target.endsWith('/dispatch.wlock')) return linkSync(source, target)
  if (!RESERVATION_RELEASE) {
    fs.writeFileSync(RESERVATION_ENTERED, '')
    return linkSync(source, target)
  }
  linkSync(source, target)
  fs.writeFileSync(RESERVATION_ENTERED, '')
  const deadline = Date.now() + 10000
  const pause = new Int32Array(new SharedArrayBuffer(4))
  while (!fs.existsSync(RESERVATION_RELEASE)) {
    if (Date.now() >= deadline) throw new Error('reservation barrier timed out')
    Atomics.wait(pause, 0, 0, 10)
  }
}
syncBuiltinESMExports()
`)
for (const first of ['solo', 'plan']) {
  const f = fixture('1')
  const base = f.plan.base_sha
  const runId = 'run-2-reservation'
  const soloSlate = `solo-${runId}`
  const git = (...args) => execFileSync('git', args, { cwd: f.repo, encoding: 'utf8' })
  git('update-ref', 'refs/remotes/origin/main', base)
  git('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
  git('branch', 'issue-2')
  const lock = (slate, issue) => execFileSync(process.execPath, [writer, 'lock', 'acquire',
    '--slate', slate, '--session', 'owner', '--issues', issue], { cwd: f.repo, encoding: 'utf8' }).trim()
  const token = lock(soloSlate, '2')
  const policyFile = join(f.repo, 'policy.json')
  const input = join(f.repo, 'genesis.json')
  writeFileSync(policyFile, JSON.stringify(fullPolicy))
  f.plan.lanes[0].run_id = runId
  writeFileSync(input, JSON.stringify(f.plan))
  const writers = {
    solo: [writer, 'solo-init', '--session', 'owner', '--owner-token', token, '--run-id', runId,
      '--issue', '2', '--title', 'Solo reservation', '--url', 'https://github.com/example/repo/issues/2',
      '--branch', 'issue-2', '--base', base, '--policy', policyFile, '--actor-id', '12345', '--strategy-source', 'default_strategy'],
    plan: [reviser, 'genesis', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
      '--input', input, '--reason', 'reserve the run', '--at', '2026-10-22T12:00:00Z'],
  }
  const release = join(f.repo, 'release')
  function start(kind) {
    const entered = join(f.repo, kind)
    const child = spawn(process.execPath, ['--import', reservationBarrier, ...writers[kind]], {
      cwd: f.repo, env: { ...process.env, RESERVATION_ENTERED: entered, RESERVATION_RELEASE: kind === first ? release : '' },
    })
    let stderr = ''
    let result
    child.stdout.resume()
    child.stderr.on('data', (data) => { stderr += data })
    const done = new Promise((resolve) => child.on('close', (status) => {
      result = { status, stderr }
      resolve(result)
    }))
    return { done, async waitForLock() {
      const deadline = Date.now() + 8000
      while (!existsSync(entered)) {
        assert.ok(!result && Date.now() < deadline, `${kind} did not reach dispatch: ${stderr}`)
        await new Promise((resolve) => setTimeout(resolve, 10))
      }
    } }
  }
  const winner = start(first)
  let loser
  try {
    await winner.waitForLock()
    loser = start(first === 'solo' ? 'plan' : 'solo')
    await loser.waitForLock()
  } finally {
    writeFileSync(release, '')
  }
  const accepted = await winner.done, refused = await loser.done
  assert.equal(accepted.status, 0, accepted.stderr)
  assert.equal(refused.status, 1, refused.stderr)
  assert.match(refused.stderr, first === 'solo' ? /owned by slate solo-run-2-reservation/ : /reserved by locked slate s \(lane l1\)/)
  assert.equal(existsSync(f.canonical), first === 'plan')
  assert.equal(existsSync(join(f.root, 'slates', soloSlate, 'plan.json')), first === 'solo')

  if (first === 'plan') {
    const another = content(base, [addition(3, 'area3/**', 1)])
    another.lanes[0].run_id = runId
    writeFileSync(input, JSON.stringify(another))
    const otherToken = lock('other', '3')
    const directory = join(f.root, 'runs', runId)
    const otherPlan = join(f.root, 'slates/other/plan.json')
    const runOther = (command, file) => spawnSync(process.execPath, [reviser, command, '--slate', 'other', '--session', 'owner',
      '--owner-token', otherToken, '--input', file, '--reason', 'reserve the same run'], { cwd: f.repo, encoding: 'utf8' })
    const rows = [
      { name: 'locked live lane', refusal: /reserved by locked slate s \(lane l1\)/ },
      {
        name: 'addition collides with a locked live lane', command: 'add-issue',
        refusal: /reserved by locked slate s \(lane l1\)/,
        setup() {
          const added = addition(4, 'area4/**', 2)
          const baselineInput = join(f.repo, 'other-baseline.json')
          writeFileSync(baselineInput, JSON.stringify(content(base, [addition(3, 'area3/**', 1)])))
          const baseline = runOther('genesis', baselineInput)
          assert.equal(baseline.status, 0, baseline.stderr)
          added.lane.run_id = runId
          const addInput = join(f.repo, 'other-addition.json')
          writeFileSync(addInput, JSON.stringify(added))
          return addInput
        },
      },
      {
        name: 'locked retained lane', refusal: /reserved by locked slate s \(lane l1\)/,
        setup() {
          const plan = f.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
          assert.equal(plan.lanes.length, 0)
          assert.equal(plan.retained_lanes[0].lane.run_id, runId)
        },
      },
      {
        name: 'ownerless run directory', refusal: /without an owner-slate record/,
        setup() {
          execFileSync(process.execPath, [writer, 'lock', 'release', '--slate', 's',
            '--session', 'owner', '--owner-token', f.token], { cwd: f.repo })
          mkdirSync(directory, { recursive: true })
        },
      },
      { name: 'unlocked retained lane', setup() { execFileSync('rmdir', [directory]) } },
    ]
    for (const { name, setup, refusal, command = 'genesis' } of rows) {
      const candidate = setup?.() ?? input
      const before = existsSync(otherPlan) ? readFileSync(otherPlan, 'utf8') : null
      const result = runOther(command, candidate)
      assert.equal(result.status, refusal ? 1 : 0, `${name}: ${result.stderr}`)
      if (refusal) assert.match(result.stderr, refusal, name)
      if (name === 'ownerless run directory') assert.ok(result.stderr.includes(directory), result.stderr)
      if (refusal) assert.equal(existsSync(otherPlan) ? readFileSync(otherPlan, 'utf8') : null, before, name)
      else assert.ok(existsSync(otherPlan), name)
      if (command === 'add-issue') unlinkSync(otherPlan)
    }
  }
}
console.log('  PASS: solo-init and plan genesis serialize reservations, honoring locked live and retained lanes and ownerless runs')

for (const scenario of ['slow membership', 'historical reservation']) {
  const f = fixture('1')
  const input = join(f.repo, 'genesis.json')
  const base = f.plan.base_sha
  writeFileSync(input, JSON.stringify(f.plan))
  const marker = join(f.repo, 'membership-started')
  let pending
  if (scenario === 'slow membership') {
    const child = spawn(process.execPath, [reviser, 'genesis', '--slate', 's', '--session', 'owner', '--owner-token', f.token,
      '--input', input, '--reason', 'publish before slow membership'], {
      cwd: f.repo, env: { ...process.env, SLOW_MEMBERSHIP_MARKER: marker },
    })
    child.stdout.resume()
    let stderr = ''
    child.stderr.on('data', (data) => { stderr += data })
    pending = new Promise((resolve) => child.on('close', (status) => resolve({ status, stderr })))
    const deadline = Date.now() + 10000
    while (!existsSync(marker) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20))
    assert.ok(existsSync(marker), 'genesis must reach the slow membership call')
  } else {
    f.ok('genesis', { input: f.plan })
    const retired = f.ok('done', { flags: ['--issue', '1'] })
    assert.equal(retired.lanes.length, 0)
    assert.ok(existsSync(join(f.root, 'locks/s.json')))
  }
  const inputLane = addition(3, 'area3/**', 1)
  if (scenario === 'historical reservation') inputLane.lane.run_id = 'run-1'
  const otherInput = join(f.repo, 'other.json')
  writeFileSync(otherInput, JSON.stringify(content(base, [inputLane])))
  const token = execFileSync(process.execPath, [writer, 'lock', 'acquire', '--slate', 'other',
    '--session', 'owner', '--issues', '3'], { cwd: f.repo, encoding: 'utf8' }).trim()
  const result = spawnSync(process.execPath, [reviser, 'genesis', '--slate', 'other', '--session', 'owner',
    '--owner-token', token, '--input', otherInput, '--reason', scenario], { cwd: f.repo, encoding: 'utf8' })
  assert.equal(result.status, 0, `${scenario}: ${result.stderr}`)
  if (pending) {
    const first = await pending
    assert.equal(first.status, 0, first.stderr)
  }
}
console.log('  PASS: unrelated admission completes during membership sync and old revisions do not reserve run IDs')

const planHolder = `
import { existsSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
const [writer, plan, root, release] = process.argv.slice(2)
const { withMutex } = await import(writer)
withMutex(plan, () => {
  writeFileSync(release + '.ready', '')
  const deadline = Date.now() + 10000
  const pause = new Int32Array(new SharedArrayBuffer(4))
  while (!existsSync(release)) {
    if (Date.now() >= deadline) throw new Error('plan holder barrier timed out')
    Atomics.wait(pause, 0, 0, 10)
  }
  // Attempt dispatch without waiting for a lock-order cycle to time out.
  withMutex(join(root, 'dispatch'), () => {}, { timeoutMs: 0 })
})
`
for (const scenario of ['same-slate lock order', 'same-slate membership order']) {
  const f = fixture('1,2')
  const release = join(f.repo, 'release')
  const attempt = join(f.repo, 'attempt')
  const input = join(f.repo, 'input.json')
  const flags = ['--slate', 's', '--session', 'owner', '--owner-token', f.token,
    '--at', '2026-10-22T12:00:00Z', '--reason', scenario]
  const membership = scenario === 'same-slate membership order'
  const env = { ...process.env }
  function start(args, extra = {}) {
    const child = spawn(process.execPath, args, { cwd: f.repo, env: { ...env, ...extra } })
    child.stdout.resume()
    let stderr = ''
    child.stderr.on('data', (data) => { stderr += data })
    return new Promise((resolve) => child.on('close', (status) => resolve({ status, stderr })))
  }
  async function waitFor(path) {
    const deadline = Date.now() + 10000
    while (!existsSync(path) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20))
    assert.ok(existsSync(path), `${scenario}: did not reach ${path}`)
  }
  let first, second
  try {
    if (membership) {
      env.MEMBERSHIP_FIXTURE = f.repo
      writeFileSync(join(f.repo, 'comments'), '')
      writeFileSync(input, JSON.stringify(f.plan))
      first = start([reviser, 'genesis', ...flags, '--input', input], { MEMBERSHIP_RELEASE: release })
    } else {
      f.ok('genesis', { input: f.plan })
      writeFileSync(input, JSON.stringify(addition(2)))
      first = start(['--input-type=module', '-e', planHolder, '-', writer, f.canonical, f.root, release])
    }
    await waitFor(`${release}.ready`)
    const command = membership ? ['done', '--issue', '1'] : ['add-issue', '--input', input]
    second = start(['--import', reservationBarrier, reviser, ...command, ...flags], { PLAN_LOCK_ATTEMPT: attempt })
    await waitFor(attempt)
    // If done took the plan mutex ahead of the paused sync, let it publish
    // its removal before releasing genesis, making the wrong order observable.
    if (membership && existsSync(`${attempt}.acquired`)) await second
  } finally {
    writeFileSync(release, '')
  }
  for (const result of await Promise.all([first, second])) {
    assert.equal(result.status, 0, `${scenario}: ${result.stderr}`)
  }
  if (membership) {
    const comments = readFileSync(join(f.repo, 'comments'), 'utf8').trim().split('\n').map(JSON.parse)
    assert.deepEqual(comments.map(({ body }) => /action: (\w+)/.exec(body)[1]), ['add', 'remove'])
    assert.equal(existsSync(join(f.repo, 'slated')), false)
  } else {
    const document = JSON.parse(readFileSync(f.canonical, 'utf8'))
    assert.deepEqual(document.revisions.at(-1).plan.lanes.map(({ lane }) => lane), ['l1', 'l2'])
  }
}
console.log('  PASS: same-slate admission takes plan before dispatch and membership sync follows revision order')

for (const scenario of ['started slate before done', 'unstarted slate after done', 'concurrent acquire']) {
  const f = fixture('1')
  const comments = join(f.repo, 'comments')
  const label = join(f.repo, 'slated')
  const input = join(f.repo, 'input.json')
  const env = { ...process.env, MEMBERSHIP_FIXTURE: f.repo }
  delete env.RUN_RECORD_OWNER_TOKEN
  const call = (script, args) => spawnSync(process.execPath, [script, ...args],
    { cwd: f.repo, encoding: 'utf8', env })
  const ok = (script, args) => {
    const result = call(script, args)
    assert.equal(result.status, 0, result.stderr)
    return result.stdout.trim()
  }
  const abandoned = ['--slate', 's', '--session', 'owner']
  const successor = ['--slate', 'successor', '--session', 'next']
  const close = ['membership', '--close']
  const retire = [...close, '--abandoned']
  function assertMembership(expected, slated) {
    const markers = new Map()
    for (const line of readFileSync(comments, 'utf8').trim().split('\n')) {
      const [, slate, action] = /- slate: (\S+)\n- action: (add|remove)/.exec(JSON.parse(line).body)
      markers.set(slate, action)
    }
    assert.deepEqual(Object.fromEntries(markers), expected)
    assert.equal(existsSync(label), slated)
  }
  writeFileSync(comments, '')
  writeFileSync(input, JSON.stringify(f.plan))
  ok(reviser, ['genesis', ...abandoned, '--owner-token', f.token, '--input', input, '--reason', 'original slate'])
  if (scenario === 'started slate before done') mkdirSync(join(f.root, 'runs', 'run-1'), { recursive: true })
  ok(writer, ['lock', 'release', ...abandoned, '--owner-token', f.token])
  const withoutFlag = call(reviser, [...close, ...abandoned])
  assert.equal(withoutFlag.status, 1)
  assert.match(withoutFlag.stderr, /slate s is unlocked/)
  const unknownSession = call(reviser, [...retire, '--slate', 's', '--session', 'unrecorded'])
  assert.equal(unknownSession.status, 1)
  assert.match(unknownSession.stderr, /no published session unrecorded/)
  assertMembership({ s: 'add' }, true)
  if (scenario === 'concurrent acquire') {
    const release = join(f.repo, 'close-release')
    const child = spawn(process.execPath, [reviser, ...retire, ...abandoned], {
      cwd: f.repo, env: { ...env, MEMBERSHIP_RELEASE: release },
    })
    child.stdout.resume()
    let stderr = ''
    child.stderr.on('data', (data) => { stderr += data })
    const closed = new Promise((resolve) => child.on('close', resolve))
    let acquired, closeStatus
    try {
      const deadline = Date.now() + 5000
      while (!existsSync(`${release}.ready`) && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 20))
      }
      if (existsSync(`${release}.ready`)) {
        acquired = spawnSync(process.execPath, [writer, 'lock', 'acquire', '--slate', 's',
          '--session', 'replacement', '--issues', '1'], { cwd: f.repo, encoding: 'utf8', env, timeout: 5000 })
      }
    } finally {
      writeFileSync(release, '')
      closeStatus = await closed
    }
    assert.equal(acquired?.status, 0, acquired?.error?.message ?? acquired?.stderr ?? 'close did not reach GitHub')
    assert.equal(closeStatus, 1, stderr)
    assert.match(stderr, /warning: slate s was acquired during --abandoned close/)
    assert.match(stderr, /https:\/\/github\.com\/example\/repo\/issues\/1 \(slate s, session owner\)/)
    assertMembership({ s: 'remove' }, false)
    continue
  }
  const token = ok(writer, ['lock', 'acquire', ...successor, '--issues', '1'])
  const next = addition(1)
  next.lane.run_id = 'successor-run-1'
  writeFileSync(input, JSON.stringify(content(f.plan.base_sha, [next])))
  ok(reviser, ['genesis', ...successor, '--owner-token', token, '--input', input, '--reason', 'successor slate'])
  assert.match(call(reviser, [...retire, ...successor, '--owner-token', token]).stderr, /requires an unlocked slate/)
  assertMembership({ s: 'add', successor: 'add' }, true)
  if (scenario === 'started slate before done') {
    ok(reviser, [...retire, ...abandoned])
    assertMembership({ s: 'remove', successor: 'add' }, true)
  }
  ok(reviser, ['done', ...successor, '--owner-token', token, '--issue', '1', '--reason', 'merged'])
  if (scenario === 'unstarted slate after done') {
    assertMembership({ s: 'add', successor: 'remove' }, true)
    ok(reviser, [...retire, ...abandoned])
  }
  assertMembership({ s: 'remove', successor: 'remove' }, false)
  const retired = readFileSync(comments, 'utf8')
  ok(reviser, [...retire, ...abandoned])
  assert.equal(readFileSync(comments, 'utf8'), retired, 'retirement is idempotent')
}
console.log('  PASS: abandoned-slate membership retires without touching the live successor')

const resolvedAddition = (n, wave = n) => {
  const input = addition(n, `area${n}/**`, wave)
  delete input.profile
  return input
}
const resolved = fixture()
resolved.ok('genesis', { input: resolved.plan })
const policyFile = join(resolved.repo, 'policy.json')
writeFileSync(policyFile, JSON.stringify(fullPolicy))
const policyFlags = ['--policy', policyFile]
let resolvedPlan = resolved.ok('add-issue', { input: resolvedAddition(2), flags: policyFlags })
assert.deepEqual(resolvedPlan.lane_profiles.find((p) => p.lane === 'l2').policy, projectedPolicy)
assert.deepEqual(lanePolicyProjection(resolvedPlan, resolvedPlan.lanes[1], policyFile), {
  ...fullPolicy, rigor: { ...fullPolicy.rigor, source: projectedPolicy.rigor_source },
})
resolvedPlan = resolved.ok('done', { flags: ['--issue', '1', ...policyFlags], input: { addition: resolvedAddition(3, 2) } })
assert.deepEqual(resolvedPlan.lane_profiles.find((p) => p.lane === 'l3').policy, projectedPolicy)
const invalidAddition = resolvedAddition(4)
writeFileSync(policyFile, JSON.stringify({ ...fullPolicy, stages: undefined }))
resolved.refuse('add-issue', { input: invalidAddition, flags: policyFlags }, /not a complete resolved policy projection/)
resolved.refuse('done', { flags: ['--issue', '2', ...policyFlags], input: { addition: invalidAddition } }, /not a complete resolved policy projection/)
writeFileSync(policyFile, JSON.stringify(fullPolicy))
const ambiguousPolicy = resolvedAddition(4)
ambiguousPolicy.profile = addition(4).profile
resolved.refuse('add-issue', { input: ambiguousPolicy, flags: policyFlags }, /not both/)
console.log('  PASS: additions and done-with-addition project complete resolver JSON identically to lane-init')

// Run/profile replacement is one validated revision and is closed once provisioned.
const replacement = fixture()
const operatorPins = ['Do not terminate any process', 'Preserve the existing deployment configuration']
replacement.plan.lane_profiles[0].policy = { ...replacement.plan.lane_profiles[0].policy, operator_pins: operatorPins }
replacement.ok('genesis', { input: replacement.plan })
const replacementPolicy = join(replacement.repo, 'policy.json')
writeFileSync(replacementPolicy, JSON.stringify(fullPolicy))
const replacementFlags = ['--lane', 'l1', '--run-id', 'fresh-run', '--policy', replacementPolicy]
replacement.refuse('replace-unprovisioned', { flags: replacementFlags, ownerToken: 'wrong' }, /owner token/)
mkdirSync(join(replacement.root, 'runs/run-1'), { recursive: true })
replacement.refuse('replace-unprovisioned', { flags: replacementFlags }, /previous run directory exists/)
// Directory-only provisioning is sufficient; no run.json is required.
execFileSync('rmdir', [join(replacement.root, 'runs/run-1')])
mkdirSync(join(replacement.root, 'runs/fresh-run'))
replacement.refuse('replace-unprovisioned', { flags: replacementFlags }, /fresh unused run_id/)
execFileSync('rmdir', [join(replacement.root, 'runs/fresh-run')])
writeFileSync(replacementPolicy, JSON.stringify({ ...fullPolicy, stages: undefined }))
replacement.refuse('replace-unprovisioned', { flags: replacementFlags }, /not a complete resolved policy projection/)
writeFileSync(replacementPolicy, JSON.stringify(fullPolicy))
const replaced = replacement.ok('replace-unprovisioned', { flags: replacementFlags })
assert.equal(replaced.lanes[0].run_id, 'fresh-run')
assert.deepEqual(replaced.lanes[0].fence, replacement.plan.lanes[0].fence)
assert.deepEqual(replaced.lane_profiles[0].policy, { ...projectedPolicy, operator_pins: operatorPins })
assert.doesNotThrow(() => lanePolicyProjection(replaced, replaced.lanes[0], replacementPolicy))
const { buildBriefValues } = await import(join(assets, '../../orchestrate/assets/lane-brief-values.mjs'))
const facts = Object.fromEntries(['worktree_path', 'harness', 'harness_text', 'effort', 'codex_model_id', 'codex_launch_flags',
  'scratch_dir', 'gate_bounds_override', 'gate_commands', 'git_sandbox_note', 'known_environmental_failure',
  'pr_title', 'verified_facts_and_rulings'].map((name) => [name, 'fixture']))
const brief = buildBriefValues({ plan: replaced, lane: replaced.lanes[0],
  facts: { ...facts, repo_tier: 'standard', unit_kind: 'implementation', claim_handoff: {} },
  nonce: 'pins', at: '2026-10-22T12:00:00Z', generation: 1, active: 'active.json',
  runDir: join(replacement.root, 'runs/fresh-run'), defaultBranch: 'main' })
assert.deepEqual(brief.envelope.operator_pins, operatorPins)
assert.equal(brief.values['operator-pins'], `\n\n${operatorPins.map((pin) => `- ${pin}`).join('\n')}`)
const history = JSON.parse(readFileSync(replacement.canonical)).revisions
assert.equal(history.length, 2)
assert.equal(history[0].plan.lanes[0].run_id, 'run-1')
assert.deepEqual(history[0].plan.lane_profiles, replacement.plan.lane_profiles)
replacement.refuse('replace-unprovisioned', { flags: ['--lane', 'l1', '--run-id', 'run-1', '--policy', replacementPolicy] }, /fresh unused run_id/)
console.log('  PASS: unprovisioned run/profile replacement is atomic and refuses provisioned, reused and malformed inputs')

// Every touched provisioned lane needs its own explicit authenticated decision.
const moved = fixture()
moved.ok('genesis', { input: content(moved.plan.base_sha, [addition(1), addition(2)]) })
for (const n of [1, 2]) mkdirSync(join(moved.root, `runs/run-${n}`), { recursive: true })
for (const n of [1, 2]) {
  mkdirSync(join(moved.repo, `area${n}`))
  writeFileSync(join(moved.repo, `area${n}/file`), 'base change')
}
execFileSync('git', ['add', '.'], { cwd: moved.repo })
execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.test', 'commit', '-qm', 'base move'], { cwd: moved.repo })
const movedBase = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: moved.repo, encoding: 'utf8' }).trim()
const baseFlags = ['--new-base', movedBase]
const verifiedOne = { lane: 'l1', status: 'caught-up', sha: movedBase }
const verifiedTwo = { lane: 'l2', status: 'catch-up-owed' }
moved.refuse('base-move', { flags: baseFlags }, /touches lane/)
moved.refuse('base-move', { flags: baseFlags, input: { lanes: [verifiedOne] } }, /lane l2/)
for (const bad of [
  { lane: 'unknown', status: 'catch-up-owed' },
  { ...verifiedOne, sha: 'short' },
  { ...verifiedOne, sha: [movedBase] },
  { ...verifiedTwo, sha: movedBase },
  { ...verifiedOne, fence: [] },
]) moved.refuse('base-move', { flags: baseFlags, input: { lanes: [bad] } }, /verification|immutable/)
moved.refuse('base-move', { flags: baseFlags, input: { lanes: [verifiedOne, verifiedOne] } }, /duplicate/)
const verifiedPlan = moved.ok('base-move', { flags: baseFlags, input: { lanes: [verifiedOne, verifiedTwo] } })
assert.equal(verifiedPlan.base_sha, movedBase)
assert.deepEqual(verifiedPlan.lanes.map((lane) => lane.fence), [addition(1).lane.fence, addition(2).lane.fence])
assert.match(JSON.parse(readFileSync(moved.canonical)).revisions.at(-1).reason, /caught-up.*catch-up-owed/)
console.log('  PASS: base-move refuses unnamed provisioned collisions and records caught-up and catch-up-owed owner decisions')

}

// Two existing lanes can acquire an explicit decision for an expansion-held path.
for (const resolution of ['serialize', 'split']) {
  const f = fixture('1,2')
  f.ok('genesis', { input: f.plan })
  const doc = JSON.parse(readFileSync(f.canonical))
  const plan = structuredClone(doc.revisions.at(-1).plan)
  const second = addition(2)
  plan.issues.push(second.issue); plan.lanes.push(second.lane); plan.lane_profiles.push(second.profile)
  plan.waves.push({ number: 2, issues: [2] })
  plan.lanes[0].expansions.push({ path: 'shared/test.sh', at: '2026-10-22T12:00:00Z', reason: 'accepted earlier' }, { path: 'other/test.sh', at: '2026-10-22T12:00:00Z', reason: 'accepted earlier' }, { path: 'app/[id]/page.tsx', at: '2026-10-22T12:00:00Z', reason: 'accepted earlier' })
  plan.lanes[1].fence.push({ path: 'shared/**' })
  const { chainDigest } = await import(writer)
  const prev_digest = doc.revisions.at(-1).digest
  const revision = { seq: doc.revisions.length, plan, at: '2026-10-22T12:00:00Z', reason: 'fixture' }
  doc.revisions.push({ ...revision, prev_digest, digest: chainDigest(revision, prev_digest) })
  writeFileSync(f.canonical, JSON.stringify(doc))
  const flags = ['--lane-a', 'l1', '--lane-b', 'l2', '--path', 'shared/test.sh', '--resolution', resolution, '--before', '1', '--after', '2']
  f.refuse('overlap', { flags: [...flags.slice(0, 1), 'missing', ...flags.slice(2)] }, /live lanes/)
  f.refuse('overlap', { flags: flags.map((v) => v === 'shared/test.sh' ? 'missing' : v) }, /covered by a lane/)
  for (const path of ['shared/*.sh', 'shared/?.sh', 'shared/\\test.sh']) {
    f.refuse('overlap', { flags: flags.map((v) => v === 'shared/test.sh' ? path : v) }, /concrete path/)
  }
  f.refuse('overlap', { flags: flags.map((v, i) => i === 9 ? '2' : i === 11 ? '1' : v) }, /increasing waves/)
  let result = f.ok('overlap', { flags })
  assert.deepEqual(result.overlaps[0].paths, ['shared/test.sh'])
  f.refuse('overlap', { flags }, /duplicate overlap/)
  const additional = flags.map((value) => value === 'shared/test.sh' ? 'other/test.sh' : value)
  f.refuse('overlap', { flags: additional.map((value) => value === resolution ? (resolution === 'split' ? 'serialize' : 'split') : value) }, /different resolution/)
  result = f.ok('overlap', { flags: additional })
  assert.deepEqual(result.overlaps[0].paths, ['other/test.sh', 'shared/test.sh'])
  result = f.ok('overlap', { flags: flags.map((v) => v === 'shared/test.sh' ? 'app/[id]/page.tsx' : v) })
  assert.deepEqual(result.overlaps[0].paths, ['app/[id]/page.tsx', 'other/test.sh', 'shared/test.sh'])
  result = f.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
  assert.deepEqual(result.overlaps[0].paths, ['app/[id]/page.tsx', 'other/test.sh', 'shared/test.sh'])
  f.refuse('overlap', { flags }, /live lanes/)
}
console.log('  PASS: overlap decisions accept expansions, reject invalid requests, and survive revisions')
const notice = fixture('1')
const noticeResult = notice.call('genesis', { input: notice.plan })
assert.equal(noticeResult.status, 0, noticeResult.stderr)
assert.match(noticeResult.stdout, /membership: example\/repo has no slated label; skipped/)
const a = fixture('1')
a.refuse('genesis', { input: a.plan, ownerToken: null }, /requires --owner-token/)
a.refuse('genesis', { input: a.plan, ownerToken: 'wrong' }, /owner token does not match/)
a.refuse('genesis', { input: content(a.plan.base_sha, [addition(2)]) }, /outside the lock reservation/)
const unlocked = fixture()
execFileSync(process.execPath, [writer, 'lock', 'release', '--slate', 's', '--session', 'owner', '--owner-token', unlocked.token], { cwd: unlocked.repo })
unlocked.refuse('genesis', { input: unlocked.plan }, /lock acquire/)
assert.equal(existsSync(join(unlocked.root, 'locks/s.json')), false, 'genesis acquired a lock')
a.plan.input = { kind: 'epic', url: 'https://github.com/example/repo/issues/99' }
assert.deepEqual(a.ok('genesis', { input: a.plan }).input, a.plan.input)
a.refuse('genesis', { input: a.plan }, /already has a plan/)
a.refuse('done', { flags: ['--issue', '1', '--dry-run'] }, /unknown flag --dry-run/, 2)
a.refuse('add-issue', { input: { issue: addition(2).issue, lane: addition(2).lane } }, /complete resolved profile/)
let current = a.ok('add-issue', { input: addition(2) })
assert.deepEqual(current.input, a.plan.input, 'add-issue must preserve original slate provenance')
assert.deepEqual(current.lane_profiles.find((p) => p.lane === 'l2'), addition(2).profile)
assert.deepEqual(JSON.parse(readFileSync(join(a.root, 'locks/s.json'))).issues, [1, 2])
a.refuse('add-issue', { input: addition(2) }, /already exists/)
a.refuse('expand', { flags: ['--lane', 'missing', '--path', 'free.txt'] }, /unknown receiving live lane/)
a.refuse('expand', { flags: ['--lane', 'l1', '--path', 'area2/deep/file.js'] }, /another live lane l2/)
a.refuse('expand', { flags: ['--lane', 'l1', '--path', 'free.txt'], at: '2026-10-21T00:00:00Z' }, /precedes revision/)
current = a.ok('expand', { flags: ['--lane', 'l1', '--path', 'free.txt'] })
assert.deepEqual(current.input, a.plan.input, 'expand must preserve original slate provenance')
assert.deepEqual(current.lanes[0].fence, a.plan.lanes[0].fence)
assert.deepEqual(current.lanes[0].expansions, [{ path: 'free.txt', at: '2026-10-22T12:00:00Z', reason: 'verified operator decision' }])
a.refuse('expand', { flags: ['--lane', 'l1', '--path', 'free.txt'] }, /already covered/)
// A retirement input cannot smuggle replacement original fences.
a.refuse('done', { input: { plan: { lanes: [{ ...current.lanes[1], fence: ['replacement'] }] } }, flags: ['--issue', '1'] }, /original fences are immutable/)
a.refuse('release', { flags: ['--issue', '1', '--lane', 'l2', '--path', 'not-owned.txt'] }, /outside finished lane/)
current = a.ok('release', { flags: ['--issue', '1', '--lane', 'l2', '--path', 'free.txt'] })
assert.deepEqual(current.input, a.plan.input, 'release must preserve original slate provenance')
assert.equal(current.issues[0].verdict, 'done')
assert.equal(current.lanes.length, 1)
assert.deepEqual(current.lanes[0].fence, addition(2).lane.fence)
assert.equal(current.lanes[0].expansions[0].path, 'free.txt')
a.refuse('done', { flags: ['--issue', '1'] }, /no live source lane/)
current = a.ok('done', { flags: ['--issue', '2'] })
assert.deepEqual(current.input, a.plan.input, 'done must preserve original slate provenance')
assert.deepEqual(current.lanes, [])
assert.deepEqual(current.waves, [])
assert.deepEqual(current.lane_profiles, [])
execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.test', 'commit', '--allow-empty', '-qm', 'base moved'], { cwd: a.repo })
const provenanceBase = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: a.repo, encoding: 'utf8' }).trim()
current = a.ok('base-move', { flags: ['--new-base', provenanceBase] })
assert.deepEqual(current.input, a.plan.input, 'base-move must preserve original slate provenance')
console.log('  PASS: genesis, add-issue, expand, release, done and base-move publish validated chains preserving provenance and refuse invalid decisions')
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
c.ok('expand', { flags: ['--lane', 'l1', '--path', 'validator/test.sh'] })
current = c.ok('overlap', { flags: ['--lane-a', 'l1', '--lane-b', 'l2', '--path', 'validator/test.sh', '--resolution', 'serialize', '--before', '1', '--after', '2'] })
assert.deepEqual(current.overlaps[0].paths, ['shared.txt', 'validator/test.sh'])
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
// Review r1: retained done issues may have no candidate files; live issues may not.
const retainedDone = fixture('1,2')
const withDone = structuredClone(retainedDone.plan)
const doneIssue = { ...addition(2).issue, verdict: 'done', candidate_files: [] }
withDone.issues.push(doneIssue)
current = retainedDone.ok('genesis', { input: withDone })
assert.deepEqual(current.issues.find((issue) => issue.number === 2), doneIssue)
const interactivePlan = JSON.parse(readFileSync(join(assets, '../../../../schemas/fixtures/plan/valid/interactive.json'), 'utf8')).revisions[0].plan
const interactive = fixture(interactivePlan.issues.map((issue) => issue.number).join(','))
current = interactive.ok('genesis', { input: interactivePlan })
assert.deepEqual(current, interactivePlan)
for (const verdict of ['valid', 'partial']) {
  const emptyLive = fixture('1')
  const input = structuredClone(emptyLive.plan)
  input.issues[0].verdict = verdict
  input.issues[0].candidate_files = []
  emptyLive.refuse('genesis', { input }, /candidate_files/, 2)
}
console.log('  PASS: genesis preserves done issues with empty candidates and accepts the interactive fixture; live empty candidates still exit 2')

// Integration r1: a requested glob is not a concrete path for coverage checks.
const recursiveExpansion = fixture('1')
recursiveExpansion.ok('genesis', { input: content(recursiveExpansion.plan.base_sha, [addition(1, 'src/*')]) })
recursiveExpansion.refuse('expand', { flags: ['--lane', 'l1', '--path', 'src/a.js'] }, /already covered/)
recursiveExpansion.refuse('expand', { flags: ['--lane', 'l1', '--path', 'src/*'] }, /already covered/)
current = recursiveExpansion.ok('expand', { flags: ['--lane', 'l1', '--path', 'src/**'] })
assert.deepEqual(current.lanes[0].fence, [{ path: 'src/*' }])
assert.deepEqual(current.lanes[0].expansions, [{ path: 'src/**', at: '2026-10-22T12:00:00Z', reason: 'verified operator decision' }])
recursiveExpansion.refuse('expand', { flags: ['--lane', 'l1', '--path', 'src/**'] }, /already covered/)
console.log('  PASS: recursive glob expansion is accepted once; covered concrete paths and identical patterns are refused')



// Handoff retires dispatch ownership but preserves merge-order evidence.
const queued = fixture('1,2,3')
const queuePlan = content(queued.plan.base_sha, [addition(1, 'shared.txt'), addition(2, 'shared.txt'), addition(3)])
queuePlan.overlaps = [{ issue_a: 1, issue_b: 2, paths: ['shared.txt'], resolution: 'serialize', merge_dependency: { before: 1, after: 2 } }]
queued.ok('genesis', { input: queuePlan })
queued.refuse('handoff', { flags: ['--issue', '1', '--pr', '101'], ownerToken: 'wrong' }, /owner token does not match/)
queued.refuse('handoff', { flags: ['--issue', '1', '--pr', '0'] }, /positive PR number/, 2)
queued.refuse('handoff', { flags: ['--issue', '99', '--pr', '101'] }, /no live source lane/)
current = queued.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
assert.equal(current.issues[0].verdict, 'handed-off')
assert.deepEqual(current.merge_queue, [{ issue: 1, pr: 101 }])
assert.deepEqual(current.overlaps, queuePlan.overlaps)
assert.deepEqual(current.lanes.map((lane) => [lane.issue, lane.wave]), [[2, 2], [3, 3]])
assert.deepEqual(current.lane_profiles.map((entry) => entry.lane), ['l2', 'l3'])
assert.deepEqual(current.waves, queuePlan.waves)
queued.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
queued.refuse('handoff', { flags: ['--issue', '2', '--pr', '101'] }, /duplicate PR/)
current = queued.ok('handoff', { flags: ['--issue', '2', '--pr', '102'] })
assert.deepEqual(current.overlaps, queuePlan.overlaps)
current = queued.ok('handoff', { flags: ['--issue', '3', '--pr', '103'] })
assert.deepEqual(current.lanes, [])
assert.deepEqual(current.waves, queuePlan.waves)
assert.deepEqual(current.lane_profiles, [])
queued.refuse('queue-order', { input: { issues: [2, 1, 3] } }, /merge dependency requires issue 1 before 2/)
for (const issues of [[1, 2], [1, 2, 2], [1, 2, 99], ['1', 2, 3]]) {
  queued.refuse('queue-order', { input: { issues } }, /permutation/)
}
queued.refuse('queue-order', { input: { issues: [1, 2, 3] }, ownerToken: 'wrong' }, /owner token does not match/)
current = queued.ok('queue-order', { input: { issues: [3, 1, 2] } })
assert.deepEqual(current.merge_queue, [{ issue: 3, pr: 103 }, { issue: 1, pr: 101 }, { issue: 2, pr: 102 }])
const queueBeforeMove = structuredClone(current.merge_queue)
execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.test', 'commit', '--allow-empty', '-qm', 'new base'], { cwd: queued.repo })
const newBase = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: queued.repo, encoding: 'utf8' }).trim()
current = queued.ok('base-move', { flags: ['--new-base', newBase] })
assert.equal(current.base_sha, newBase)
assert.deepEqual(current.merge_queue, queueBeforeMove)
assert.deepEqual(current.overlaps, queuePlan.overlaps)
queued.refuse('done', { flags: ['--issue', '1'], input: { releases: [{ lane: 'l2', paths: ['shared.txt'] }] } }, /no source fence/)
current = queued.ok('done', { flags: ['--issue', '1'] })
assert.equal(current.issues[0].verdict, 'done')
assert.deepEqual(current.merge_queue, [{ issue: 3, pr: 103 }, { issue: 2, pr: 102 }])
assert.deepEqual(current.overlaps, [])
console.log('  PASS: handoff preserves overlaps and releases Working slots; queue-order validates a permutation and dependencies; base-move preserves the queue; done removes queued issues')

// Claim lifecycle writes are part of the supported handoff/reactivation paths.
writeFileSync(process.env.CLAIM_HELPER_LOG, '')
const lifecycle = fixture('1,2')
lifecycle.ok('genesis', { input: content(lifecycle.plan.base_sha, [addition(1), addition(2)]) })
const preHandoff = readFileSync(lifecycle.canonical, 'utf8')
process.env.MOCK_RELEASE_FAIL = 'yes'
lifecycle.refuse('handoff', { flags: ['--issue', '1', '--pr', '101'] }, /handoff claim release failed/)
delete process.env.MOCK_RELEASE_FAIL
assert.equal(readFileSync(lifecycle.canonical, 'utf8'), preHandoff, 'a failed claim release must not record handoff')
let lifecyclePlan = lifecycle.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
const helperLog = () => readFileSync(process.env.CLAIM_HELPER_LOG, 'utf8')
assert.match(helperLog(), /release .*--repo example\/repo --issue 1 .*--branch issue-1 --pr 101 --idempotency-key [a-f0-9]{64}/)
const { assertDispatchCapacity: capacityForHandoff } = await import(writer)
assert.deepEqual(capacityForHandoff(lifecycle.root, lifecyclePlan, lifecyclePlan.lanes.find((lane) => lane.issue === 2), 's'),
  { working: 1, in_flight: 2 }, 'a handed-off issue with an open PR remains in flight but no longer consumes Working capacity')
// A plan-write retry after a successful release uses the same deterministic key.
lifecyclePlan = lifecycle.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
assert.equal((helperLog().match(/release /g) ?? []).length, 3, 'failed call, successful release, and idempotent retry all route through release helper')
assert.equal((helperLog().match(/--idempotency-key ([a-f0-9]{64})/g) ?? []).length, 3)
lifecycle.ok('fix-request', { flags: ['--issue', '1'] })
const beforeFailedReactivation = readFileSync(lifecycle.canonical, 'utf8')
process.env.MOCK_CLAIM_REQUIRE_APPROVAL = 'yes'
lifecycle.refuse('reactivate', { flags: ['--issue', '1'] }, /reactivation claim restoration failed.*needs-review requires/)
assert.equal((helperLog().match(/restore /g) ?? []).length, 1, 'default reactivation reaches helper without approval and is refused')
delete process.env.MOCK_CLAIM_REQUIRE_APPROVAL
process.env.MOCK_CLAIM_FAIL = 'yes'
lifecycle.refuse('reactivate', { flags: ['--issue', '1'] }, /reactivation claim restoration failed/)
delete process.env.MOCK_CLAIM_FAIL
assert.equal(readFileSync(lifecycle.canonical, 'utf8'), beforeFailedReactivation,
  'a failed claim restoration must not publish a plan transition')
const matchingRecord = readFileSync(join(lifecycle.repo, 'claim-record.md'), 'utf8')
const mismatchedRecordPath = join(lifecycle.repo, 'mismatched-claim-record.md')
writeFileSync(mismatchedRecordPath, matchingRecord.replace('branch issue-1 ', 'branch other-branch '))
const helperCallsBeforeMismatch = helperLog()
const mismatchedFlags = ['--issue', '1', '--claim-record-file', mismatchedRecordPath, '--claim-label', 'claim:gpt', '--model-label', 'none', '--family', 'gpt', '--registry-snapshot', join(lifecycle.repo, 'registry.json')]
lifecycle.refuse('reactivate', { flags: mismatchedFlags }, /claim record branch other-branch does not match retained lane branch issue-1/)
lifecycle.refuse('reactivate', { flags: [...mismatchedFlags, '--approve-review-pullback'] }, /claim record branch other-branch does not match retained lane branch issue-1/)
const laterLineRecordPath = join(lifecycle.repo, 'later-line-claim-record.md')
writeFileSync(laterLineRecordPath, `not a claim record\n${matchingRecord}`)
lifecycle.refuse('reactivate', { flags: [...mismatchedFlags.slice(0, 3), laterLineRecordPath, ...mismatchedFlags.slice(4)] }, /claim record branch \(unreadable\) does not match retained lane branch issue-1/)
assert.equal(helperLog(), helperCallsBeforeMismatch,
  'wrong or malformed first-line claim records must be refused before any external claim helper write')
lifecyclePlan = lifecycle.ok('reactivate', { flags: ['--issue', '1', '--approve-review-pullback'] })
assert.equal(lifecyclePlan.retained_lanes.find((entry) => entry.lane.issue === 1).state, 'working')
assert.match(helperLog(), /restore .*--record-file .*claim-record\.md --claim-label claim:gpt --model-label none --family gpt .*--registry-snapshot .*registry\.json/)
assert.match(helperLog(), /restore .*--pr 101\b/, 'reactivation of a PR-bound retained lane must forward --pr 101')
assert.match(helperLog(), /restore .*--approve-review-pullback/, 'explicit review-pullback approval is forwarded to the claim transaction')
console.log('  PASS: handoff releases claims before recording, retries use a deterministic key, reactivation restores only after admission, and handed-off claims free Working capacity')

// Fix round 3 (H1): dedicated reactivation case where stub records argv and fails unless --pr is supplied.
const reactivatePr = fixture('1,2')
reactivatePr.ok('genesis', { input: content(reactivatePr.plan.base_sha, [addition(1), addition(2)]) })
reactivatePr.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
reactivatePr.ok('fix-request', { flags: ['--issue', '1'] })
writeFileSync(process.env.CLAIM_HELPER_LOG, '')
process.env.MOCK_CLAIM_REQUIRE_PR = 'yes'
try {
  const reactivatedPrPlan = reactivatePr.ok('reactivate', { flags: ['--issue', '1'] })
  assert.equal(reactivatedPrPlan.retained_lanes.find((entry) => entry.lane.issue === 1).state, 'working')
  assert.match(helperLog(), /restore .*--pr 101\b/, 'reactivation claim helper argv must include --pr 101')
} finally {
  delete process.env.MOCK_CLAIM_REQUIRE_PR
}
console.log('  PASS: H1 reactivation forwards --pr <bound pr> to claim-transaction.sh')

// A retained lane whose new working fence overlaps a current lane is refused
// before invoking the external claim helper.
const overlapReactivation = fixture('1,2')
overlapReactivation.ok('genesis', { input: content(overlapReactivation.plan.base_sha, [addition(1), addition(2)]) })
overlapReactivation.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
overlapReactivation.ok('fix-request', { flags: ['--issue', '1'] })
overlapReactivation.ok('expand', { flags: ['--lane', 'l2', '--path', 'area1/sub/file.js'] })
const helperCallsBeforeOverlap = (helperLog().match(/restore /g) ?? []).length
overlapReactivation.refuse('reactivate', { flags: ['--issue', '1'] }, /unresolved effective fence overlap/)
assert.equal((helperLog().match(/restore /g) ?? []).length, helperCallsBeforeOverlap,
  'an overlap refusal must happen before invoking the claim helper')

// Only release-helper exit 3 with its exact no-claim diagnostic is a no-op.
const unclaimed = fixture('1')
unclaimed.ok('genesis', { input: unclaimed.plan })
process.env.MOCK_RELEASE_UNCLAIMED = 'yes'
const unclaimedPlan = unclaimed.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
delete process.env.MOCK_RELEASE_UNCLAIMED
assert.equal(unclaimedPlan.issues[0].verdict, 'handed-off')
assert.match(readFileSync(process.env.CLAIM_API_LOG, 'utf8'), /repos\/example\/repo\/issues\/1/,
  'handoff verifies the canonical issue repository and issue number')
const inherited = fixture('1')
inherited.ok('genesis', { input: inherited.plan })
const inheritedBefore = readFileSync(inherited.canonical, 'utf8')
process.env.MOCK_CLAIM_API_RESPONSE = '{"labels":[{"name":"claim:unowned"}]}'
inherited.refuse('handoff', { flags: ['--issue', '1', '--pr', '101'] }, /claim:unowned remains/)
assert.equal(readFileSync(inherited.canonical, 'utf8'), inheritedBefore,
  'a successful release helper must not publish handoff while any Working marker remains')
process.env.MOCK_CLAIM_API_RESPONSE = '{"labels":[]}'
const unreadable = fixture('1')
unreadable.ok('genesis', { input: unreadable.plan })
process.env.MOCK_CLAIM_API_FAIL = 'yes'
unreadable.refuse('handoff', { flags: ['--issue', '1', '--pr', '101'] }, /claim verification failed.*simulated issue read failure/)
delete process.env.MOCK_CLAIM_API_FAIL
process.env.MOCK_CLAIM_API_RESPONSE = '{"labels":[{}]}'
const malformedLabels = fixture('1')
malformedLabels.ok('genesis', { input: malformedLabels.plan })
malformedLabels.refuse('handoff', { flags: ['--issue', '1', '--pr', '101'] }, /malformed issue labels response/)
delete process.env.MOCK_CLAIM_API_RESPONSE
const wrongBranch = fixture('1')
wrongBranch.ok('genesis', { input: wrongBranch.plan })
process.env.MOCK_RELEASE_WRONG_BRANCH = 'yes'
wrongBranch.refuse('handoff', { flags: ['--issue', '1', '--pr', '101'] }, /handoff claim release failed.*newer-branch/)
delete process.env.MOCK_RELEASE_WRONG_BRANCH
const unsupportedIdentity = fixture('1')
unsupportedIdentity.ok('genesis', { input: unsupportedIdentity.plan })
const unsupportedDoc = JSON.parse(readFileSync(unsupportedIdentity.canonical, 'utf8'))
const unsupportedPlan = structuredClone(unsupportedDoc.revisions.at(-1).plan)
unsupportedPlan.issues[0].url = 'https://example.test/issues/1'
const unsupportedPrevious = unsupportedDoc.revisions.at(-1).digest
const unsupportedRevision = {
  seq: unsupportedDoc.revisions.length,
  at: '2026-10-22T12:00:00Z',
  reason: 'fixture unsupported issue identity',
  plan: unsupportedPlan,
}
unsupportedDoc.revisions.push({
  ...unsupportedRevision,
  prev_digest: unsupportedPrevious,
  digest: chainDigest(unsupportedRevision, unsupportedPrevious),
})
writeFileSync(unsupportedIdentity.canonical, JSON.stringify(unsupportedDoc))
const helperLogBeforeUnsupported = helperLog()
unsupportedIdentity.refuse('handoff', { flags: ['--issue', '1', '--pr', '101'] }, /unsupported issue identity/)
assert.equal(helperLog(), helperLogBeforeUnsupported, 'unsupported issue identities must refuse before calling the release helper')
console.log('  PASS: genuinely unclaimed handoffs accept the helper no-op; wrong-branch and unsupported identities remain refusals')

// Retained sessions and queued fixes share the dispatch admission boundary.
const retained = fixture('1,2,3,4,5')
retained.ok('genesis', { input: content(retained.plan.base_sha, [1,2,3,4,5].map((n) => addition(n))) })
for (const n of [1,2,3,4]) retained.ok('handoff', { flags: ['--issue', String(n), '--pr', String(100+n)] })
for (const n of [2,3,4]) {
  retained.ok('fix-request', { flags: ['--issue', String(n)] })
  retained.ok('reactivate', { flags: ['--issue', String(n)] })
}
// Both handoff-before-request and request-before-repeated-handoff retain priority.
current = retained.ok('fix-request', { flags: ['--issue', '1'] })
assert.equal(current.retained_lanes.find((entry) => entry.lane.issue === 1).state, 'pending')
current = retained.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
assert.equal(current.retained_lanes.find((entry) => entry.lane.issue === 1).state, 'pending')
retained.refuse('reactivate', { flags: ['--issue', '1'] }, /max_parallel_agents 3/)
const { assertDispatchCapacity } = await import(writer)
assert.throws(() => assertDispatchCapacity(retained.root, current, current.lanes[0], 's'), /pending fix/)
// An old initial handoff or a stale completion cannot release a working slot.
const handoffRevision = () => String(JSON.parse(readFileSync(retained.canonical)).revisions.at(-1).seq)
retained.refuse('handoff', { flags: ['--issue', '2', '--pr', '102'] }, /working retained lane requires handoff --expected-revision/)
retained.refuse('handoff', { flags: ['--issue', '2', '--pr', '102', '--expected-revision', '0'] }, /does not match the current plan revision/)
// The matching completion works even at capacity, without capacity admission.
const previousCompletion = handoffRevision()
current = retained.ok('handoff', { flags: ['--issue', '2', '--pr', '102', '--expected-revision', previousCompletion] })
retained.ok('fix-request', { flags: ['--issue', '2'] })
retained.ok('reactivate', { flags: ['--issue', '2'] })
retained.refuse('handoff', { flags: ['--issue', '2', '--pr', '102', '--expected-revision', previousCompletion] }, /does not match the current plan revision/)
current = retained.ok('handoff', { flags: ['--issue', '2', '--pr', '102', '--expected-revision', handoffRevision()] })
assert.equal(current.retained_lanes.find((entry) => entry.lane.issue === 2).state, 'idle')
current = retained.ok('reactivate', { flags: ['--issue', '1'] })
assert.deepEqual(assertDispatchCapacity(retained.root, current, current.retained_lanes[0].lane, 's'), { working: 3, in_flight: 4 })
process.env.MOCK_MERGED_PR = '104'
assert.deepEqual(assertDispatchCapacity(retained.root, current, current.retained_lanes[0].lane, 's'), { working: 2, in_flight: 3 })
retained.refuse('fix-request', { flags: ['--issue', '4'] }, /open delivery PR/)
current = retained.ok('done', { flags: ['--issue', '4'] })
assert.equal(current.retained_lanes.some((entry) => entry.lane.issue === 4), false)
delete process.env.MOCK_MERGED_PR
// Working retained lanes accept expansions and releases, including while dispatch is locked.
writeFileSync(join(retained.root, 'dispatch.wlock'), JSON.stringify({ pid: process.pid, host: hostname() }))
current = retained.ok('expand', { flags: ['--lane', 'l1', '--path', 'fix-regression.txt'] })
unlinkSync(join(retained.root, 'dispatch.wlock'))
assert.equal(current.retained_lanes.find((entry) => entry.lane.issue === 1).lane.expansions[0].path, 'fix-regression.txt')
retained.refuse('expand', { flags: ['--lane', 'l1', '--path', 'area3/sub/file.js'] }, /another live lane l3/)
const collidingAddition = addition(6, 'area6/**', 4)
collidingAddition.lane.fence = [{ path: 'area1/sub/**' }]
retained.refuse('add-issue', { input: collidingAddition }, /effective fence overlap/)
current = retained.ok('release', { flags: ['--issue', '5', '--lane', 'l1', '--path', 'area5/released.js'] })
assert.equal(current.retained_lanes.find((entry) => entry.lane.issue === 1).lane.expansions[1].path, 'area5/released.js')
// A fresh fix run retains lane/session identity without rewriting the terminal run.
retained.ok('handoff', { flags: ['--issue', '1', '--pr', '101', '--expected-revision', handoffRevision()] })
const oldDir = join(retained.root, 'runs/run-1')
mkdirSync(oldDir, { recursive: true })
const oldFile = join(oldDir, 'run.json')
writeFileSync(oldFile, JSON.stringify({ schema: 2, run_id: 'run-1', initiated_by: 'human',
  started_at: '2026-10-22T12:00:00Z', stage_transitions: [{stage:'kickoff', entered_at:'2026-10-22T12:00:00Z'}],
  receipts: [], interventions: [], outcome: null, pr: null, evidence_comments: [], evidence_registrations: [],
  pr_bindings: [], outcome_transitions: [], settlements: [], promotion: null }))
execFileSync(process.execPath, [writer, 'close', '--slate', 's', '--session', 'owner', '--owner-token', retained.token,
  '--run-id', 'run-1', '--outcome', 'abandoned', '--exit', 'fixture terminal run', '--at', '2026-10-22T12:00:00Z'], {cwd: retained.repo, stdio: 'pipe'})
const terminalBytes = readFileSync(oldFile, 'utf8')
retained.ok('fix-request', { flags: ['--issue', '1'] })
retained.refuse('reactivate', { flags: ['--issue', '1'] }, /terminal previous run requires reactivate --run-id/)
current = retained.ok('reactivate', { flags: ['--issue', '1', '--run-id', 'run-1-fix'] })
const resumed = current.retained_lanes.find((entry) => entry.lane.issue === 1)
assert.equal(resumed.lane.run_id, 'run-1-fix')
assert.equal(resumed.lane.lane, 'l1')
assert.equal(resumed.lane.branch, 'issue-1')
assert.equal(resumed.state, 'working')
assert.deepEqual(resumed.lane.expansions, [])
assert.deepEqual(resumed.lane.fence.map(({path}) => path), ['area1/**', 'fix-regression.txt', 'area5/released.js'])
// Complete the fresh-run admission with a full matching resolver projection.
assert.match(readFileSync(join(assets, 'devflow-policy.mjs'), 'utf8'), /Default to 8 runs, 3 Working lanes and 9 in-flight/, 'fallback comment must describe the actual 8/3/9 allowance')
const { resolveAbsentPolicy } = await import(join(assets, 'devflow-policy.mjs'))
const full = resolveAbsentPolicy()
full.rigor = { ...full.rigor, level: policy.rigor, source: policy.rigor_source }
full.rounds = { ...full.rounds, ...policy.caps, integration_exempt: policy.caps.integration }
full.breadth = { ...full.breadth, ...policy.breadth }
full.strategy.name = policy.strategy
for (const [role, tier] of Object.entries(policy.role_tiers)) full.roles[role].tier = tier
for (const args of [['update-ref', 'refs/remotes/origin/main', retained.plan.base_sha],
  ['symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main'], ['branch', 'issue-1', retained.plan.base_sha]]) {
  execFileSync('git', args, { cwd: retained.repo, stdio: 'pipe' })
}
const policyFile = join(retained.repo, 'policy.json')
writeFileSync(policyFile, JSON.stringify(full))
execFileSync(process.execPath, [writer, 'lane-init', '--slate', 's', '--session', 'owner', '--owner-token', retained.token,
  '--lane', 'l1', '--policy', policyFile, '--at', '2026-10-22T12:00:00Z'], {cwd: retained.repo, stdio: 'pipe'})
assert.equal(JSON.parse(readFileSync(join(retained.root, 'runs/run-1-fix/run.json'))).run_id, 'run-1-fix')
assert.equal(readFileSync(oldFile, 'utf8'), terminalBytes)
console.log('  PASS: retained idle counts only in flight; queued fixes precede new dispatch, full-cap reactivation holds, re-handoff frees capacity, merged counts neither')

// R1 invariant: successors may finish first, retaining a PR outside the queue.
const waiting = fixture('1,2,3')
const waitingPlan = content(waiting.plan.base_sha, [addition(1, 'shared.txt'), addition(2, 'shared.txt'), addition(3, 'shared.txt')])
waitingPlan.overlaps = [[1, 2], [2, 3]].map(([before, after]) => ({ issue_a: before, issue_b: after,
  paths: ['shared.txt'], resolution: 'serialize', merge_dependency: { before, after } }))
// All pairwise candidate intersections must be recorded, including 1 -> 3.
waitingPlan.overlaps.push({ issue_a: 1, issue_b: 3, paths: ['shared.txt'], resolution: 'serialize', merge_dependency: { before: 1, after: 3 } })
waiting.ok('genesis', { input: waitingPlan })
current = waiting.ok('handoff', { flags: ['--issue', '3', '--pr', '103'] })
assert.deepEqual(current.merge_queue ?? [], [])
assert.equal(current.issues[2].verdict, 'handed-off')
assert.equal(current.issues[2].pr, 103)
assert.equal(current.lanes.some((lane) => lane.issue === 3), false)
waiting.refuse('handoff', { flags: ['--issue', '2', '--pr', '103'] }, /duplicate PR/)
current = waiting.ok('handoff', { flags: ['--issue', '2', '--pr', '102'] })
assert.deepEqual(current.merge_queue ?? [], [])
current = waiting.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
assert.deepEqual(current.merge_queue, [{ issue: 1, pr: 101 }, { issue: 2, pr: 102 }, { issue: 3, pr: 103 }])
// done also releases waiting handoffs without requiring a second handoff call.
const completedBefore = fixture('1,2')
const pairPlan = content(completedBefore.plan.base_sha, [addition(1, 'shared.txt'), addition(2, 'shared.txt')])
pairPlan.overlaps = [waitingPlan.overlaps[0]]
completedBefore.ok('genesis', { input: pairPlan })
completedBefore.ok('handoff', { flags: ['--issue', '2', '--pr', '102'] })
current = completedBefore.ok('done', { flags: ['--issue', '1'] })
assert.deepEqual(current.merge_queue, [{ issue: 2, pr: 102 }])
// R2/R3: merging the overlapping head must not pin the slate's old base.
function mergedBase(f) {
  writeFileSync(join(f.repo, 'shared.txt'), 'merged head content\n')
  execFileSync('git', ['add', 'shared.txt'], { cwd: f.repo })
  execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.test', 'commit', '-qm', 'merged head'], { cwd: f.repo })
  return execFileSync('git', ['rev-parse', 'HEAD'], { cwd: f.repo, encoding: 'utf8' }).trim()
}
const mergedAfterDone = mergedBase(completedBefore)
current = completedBefore.ok('base-move', { flags: ['--new-base', mergedAfterDone] })
assert.equal(current.base_sha, mergedAfterDone)
assert.deepEqual(current.merge_queue, [{ issue: 2, pr: 102 }])
const combined = fixture('1,2')
combined.ok('genesis', { input: { ...pairPlan, base_sha: combined.plan.base_sha } })
combined.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
combined.ok('handoff', { flags: ['--issue', '2', '--pr', '102'] })
const mergedCombined = mergedBase(combined)
current = combined.ok('base-move', { flags: ['--new-base', mergedCombined, '--done', '1'] })
assert.equal(current.issues[0].verdict, 'done')
assert.deepEqual(current.merge_queue, [{ issue: 2, pr: 102 }])
const completeWaiting = fixture('1,2')
completeWaiting.ok('genesis', { input: { ...pairPlan, base_sha: completeWaiting.plan.base_sha } })
completeWaiting.ok('handoff', { flags: ['--issue', '2', '--pr', '102'] })
current = completeWaiting.ok('base-move', { flags: ['--new-base', mergedBase(completeWaiting), '--done', '1'] })
assert.deepEqual(current.merge_queue, [{ issue: 2, pr: 102 }])
console.log('  PASS: reverse handoff order releases dependency chains; done and base-move release waiting handoffs and advance past overlapping queued files')


// Challenge r2: independent handoffs are FIFO; a later handoff preserves an
// operator's queue-order instead of displacing its selected head.
const fifo = fixture('1,2,3,4')
fifo.ok('genesis', { input: content(fifo.plan.base_sha, [addition(1), addition(2), addition(3), addition(4)]) })
for (const number of [1, 2, 3]) {
  current = fifo.ok('handoff', { flags: ['--issue', String(number), '--pr', String(100 + number)] })
  assert.deepEqual(current.merge_queue.map((entry) => entry.issue), [1, 2, 3].slice(0, number))
}
fifo.ok('queue-order', { input: { issues: [2, 1, 3] } })
current = fifo.ok('handoff', { flags: ['--issue', '4', '--pr', '104'] })
assert.deepEqual(current.merge_queue, [{ issue: 2, pr: 102 }, { issue: 1, pr: 101 }, { issue: 3, pr: 103 }, { issue: 4, pr: 104 }])
// M3: issue iteration visits successors before predecessors, so more than one
// pass is required to release this 3 -> 2 -> 1 chain.
const reverse = fixture('1,2,3')
const reversePlan = structuredClone(waitingPlan)
reversePlan.base_sha = reverse.plan.base_sha
for (const overlap of reversePlan.overlaps) {
  const { before, after } = overlap.merge_dependency
  overlap.merge_dependency = { before: after, after: before }
}
for (const wave of reversePlan.waves) wave.number = 4 - wave.number
for (const lane of reversePlan.lanes) lane.wave = 4 - lane.wave
reverse.ok('genesis', { input: reversePlan })
for (const number of [1, 2]) {
  current = reverse.ok('handoff', { flags: ['--issue', String(number), '--pr', String(100 + number)] })
  assert.deepEqual(current.merge_queue ?? [], [])
}
current = reverse.ok('handoff', { flags: ['--issue', '3', '--pr', '103'] })
assert.deepEqual(current.merge_queue, [{ issue: 3, pr: 103 }, { issue: 2, pr: 102 }, { issue: 1, pr: 101 }])
console.log('  PASS: FIFO handoffs preserve operator queue order; reverse-numbered dependency chains require repeat passes')

// B2/B3: blocked_by on disjoint files is the same queue predecessor relation.
const blockedQueue = fixture('1,2')
const blockedPlan = content(blockedQueue.plan.base_sha, [addition(1), addition(2)])
blockedPlan.issues[1].blocked_by = [1]
blockedQueue.ok('genesis', { input: blockedPlan })
current = blockedQueue.ok('handoff', { flags: ['--issue', '2', '--pr', '102'] })
assert.deepEqual(current.merge_queue ?? [], [])
current = blockedQueue.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
assert.deepEqual(current.merge_queue, [{ issue: 1, pr: 101 }, { issue: 2, pr: 102 }])
blockedQueue.refuse('queue-order', { input: { issues: [2, 1] } }, /merge dependency requires issue 1 before 2/)
// B1/B4: handoff releases the Working slot, not the blocker's dispatch-order slot.
const dispatchBlock = fixture('1,2')
dispatchBlock.ok('genesis', { input: { ...blockedPlan, base_sha: dispatchBlock.plan.base_sha } })
current = dispatchBlock.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
assert.deepEqual(current.waves, [{ number: 1, issues: [1] }, { number: 2, issues: [2] }])
assert.deepEqual(current.lanes.map((lane) => [lane.issue, lane.wave]), [[2, 2]])
assert.equal(current.lanes.some((lane) => lane.issue === 1), false)
current = dispatchBlock.ok('done', { flags: ['--issue', '1'] })
assert.deepEqual(current.waves, [{ number: 1, issues: [2] }])
assert.deepEqual(current.lanes.map((lane) => [lane.issue, lane.wave]), [[2, 1]])
// R1 / M17: release must queue a handed-off successor as it retires the blocker.
const releaseWaiting = fixture('1,2,3')
const releasePlan = content(releaseWaiting.plan.base_sha, [addition(1), addition(2), addition(3)])
releasePlan.issues[1].blocked_by = [1]
releaseWaiting.ok('genesis', { input: releasePlan })
releaseWaiting.ok('handoff', { flags: ['--issue', '2', '--pr', '102'] })
current = releaseWaiting.ok('release', { flags: ['--issue', '1', '--lane', 'l3', '--path', 'area1/x.txt'] })
assert.deepEqual(current.merge_queue, [{ issue: 2, pr: 102 }])
assert.equal(current.lanes.find((lane) => lane.issue === 3).expansions[0].path, 'area1/x.txt')
console.log('  PASS: blocked_by orders queue and dispatch across handoff/done; release queues waiting successors')

// Preference waves advance on authenticated recorded handoff, without merges.
const preference = fixture('1,2,3')
const preferencePlan = content(preference.plan.base_sha, [addition(1), addition(2), addition(3)])
preference.ok('genesis', { input: preferencePlan })
preference.refuse('wave-release', { flags: ['--wave', '2'], ownerToken: 'wrong' }, /owner token does not match/)
for (const value of ['0', 'no', '1.5']) preference.refuse('wave-release', { flags: ['--wave', value] }, /positive wave number/, 2)
preference.refuse('wave-release', { flags: ['--wave', '99'] }, /unknown wave/)
preference.refuse('wave-release', { flags: ['--wave', '1'] }, /already released/)
preference.refuse('wave-release', { flags: ['--wave', '3'] }, /next wave in order/)
preference.refuse('wave-release', { flags: ['--wave', '2'] }, /issue #1.*done or handed-off with a bound PR/)
preference.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
const beforeRelease = JSON.parse(readFileSync(preference.canonical))
current = preference.ok('wave-release', { flags: ['--wave', '2'] })
assert.equal(current.waves[1].released, true)
assert.deepEqual(current.issues, beforeRelease.revisions.at(-1).plan.issues)
assert.deepEqual(current.lanes, beforeRelease.revisions.at(-1).plan.lanes)
assert.deepEqual(current.merge_queue, [{ issue: 1, pr: 101 }])
assert.equal(current.base_sha, preferencePlan.base_sha)
const afterRelease = JSON.parse(readFileSync(preference.canonical))
assert.deepEqual(afterRelease.revisions.slice(0, -1), beforeRelease.revisions)
assert.equal(afterRelease.revisions.at(-1).reason, 'wave-release: verified operator decision')
preference.refuse('wave-release', { flags: ['--wave', '2'] }, /already released/)
preference.refuse('wave-release', { flags: ['--wave', '3'] }, /issue #2/)
preference.ok('handoff', { flags: ['--issue', '2', '--pr', '102'] })
current = preference.ok('wave-release', { flags: ['--wave', '3'] })
assert.equal(current.waves[2].released, true)
console.log('  PASS: preference waves release sequentially on handoff, retaining bindings, fences, base and revision reason')

// Capacity belongs to dispatch, even under equal ceilings and an accumulated
// delivery queue. Fact writers must remain usable before the queue drains.
for (const legacy of [false, true]) {
  const facts = fixture('1,2,3')
  const plan = content(facts.plan.base_sha, [addition(1), addition(2), addition(3)])
  plan.policy = structuredClone(policy)
  plan.policy.breadth.max_parallel_agents = 1
  if (legacy) delete plan.policy.breadth.max_in_flight
  else plan.policy.breadth.max_in_flight = 1
  plan.dispatcher.parallel_cap = 1
  for (const profile of plan.lane_profiles) profile.policy = structuredClone(plan.policy)
  facts.ok('genesis', { input: plan })
  facts.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
  facts.ok('wave-release', { flags: ['--wave', '2'] })
  facts.ok('handoff', { flags: ['--issue', '2', '--pr', '102'] })
  facts.ok('wave-release', { flags: ['--wave', '3'] })
  execFileSync('git', ['-c', 'user.name=t', '-c', 'user.email=t@example.test', 'commit', '--allow-empty', '-qm', 'base moves at capacity'], { cwd: facts.repo })
  const base = execFileSync('git', ['rev-parse', 'HEAD'], { cwd: facts.repo, encoding: 'utf8' }).trim()
  facts.ok('base-move', { flags: ['--new-base', base] })
  facts.ok('done', { flags: ['--issue', '1'] })
}
console.log('  PASS: equal and legacy ceilings never block handoff, release, done or base movement')

const oversized = fixture('1,2,3')
const oversizedPlan = content(oversized.plan.base_sha, [addition(1), addition(2), addition(3, 'area3/**', 2)])
oversizedPlan.policy = structuredClone(policy)
oversizedPlan.policy.breadth.max_parallel_agents = 1
oversizedPlan.dispatcher.parallel_cap = 1
for (const profile of oversizedPlan.lane_profiles) profile.policy = structuredClone(oversizedPlan.policy)
oversizedPlan.waves = [{ number: 1, issues: [1] }, { number: 2, issues: [2, 3] }]
oversized.refuse('genesis', { input: oversizedPlan }, /wave 2 has 2 issues, exceeding dispatcher cap 1/)
console.log('  PASS: oversized later wave is rejected before any dispatch or handoff')

// Placement decisions cannot forge or erase a release, including nested input.
const protectedRelease = fixture()
protectedRelease.ok('genesis', { input: content(protectedRelease.plan.base_sha, [addition(1), addition(2)]) })
protectedRelease.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
const placements = [{ number: 1, issues: [1] }, { number: 2, issues: [2] }, { number: 3, issues: [3] }]
protectedRelease.refuse('add-issue', { input: { ...addition(3), waves: placements.map((wave) => ({ ...wave, ...(wave.number === 2 ? { released: true } : {}) })) } }, /wave 2.*wave-release/)
protectedRelease.ok('wave-release', { flags: ['--wave', '2'] })
protectedRelease.refuse('add-issue', { input: { ...addition(3), waves: [
  { number: 1, issues: [1] }, { number: 2, issues: [3] }, { number: 3, issues: [2] },
] } }, /wave 2.*wave-release/)
protectedRelease.refuse('add-issue', { input: { ...addition(3), waves: [
  { number: 1, issues: [1] }, { number: 2, issues: [2, 3] },
] } }, /wave 2.*wave-release/)
protectedRelease.refuse('add-issue', { input: { ...addition(3), waves: placements.map((wave) => ({ ...wave, ...(wave.number === 2 ? { released: false } : {}) })) } }, /wave 2.*wave-release/)
protectedRelease.refuse('add-issue', { input: { ...addition(3), waves: placements.map((wave) => ({ ...wave, ...(wave.number === 3 ? { released: true } : {}) })) } }, /wave 3.*wave-release/)
current = protectedRelease.ok('add-issue', { input: { ...addition(3), waves: placements } })
assert.equal(current.waves[1].released, true, 'omitted marker must carry forward')
protectedRelease.refuse('done', { flags: ['--issue', '1'], input: { waves: [{ number: 1, issues: [2], released: false }, { number: 2, issues: [3] }] } }, /wave 1.*wave-release/)
protectedRelease.refuse('done', { flags: ['--issue', '1'], input: {
  addition: { ...addition(4), waves: [{ number: 1, issues: [2], released: false }, { number: 2, issues: [3] }, { number: 3, issues: [4] }] },
  waves: [{ number: 1, issues: [2] }, { number: 2, issues: [3] }, { number: 3, issues: [4] }],
} }, /wave 1.*wave-release/)
current = protectedRelease.ok('done', { flags: ['--issue', '1'], input: { waves: [{ number: 1, issues: [2] }, { number: 2, issues: [3] }] } })
assert.equal(current.waves[0].released, true, 'retirement must carry release through renumbering')
current = protectedRelease.ok('done', { flags: ['--issue', '2'] })
assert.equal(current.waves[0].released, undefined, 'retiring a released wave must not release its successor')
console.log('  PASS: only wave-release changes release markers; placement and retirement preserve surviving releases')

// Every issue of a previous wave must finish, not merely its first PR.
const multiple = fixture('1,2,3')
const multiplePlan = content(multiple.plan.base_sha, [addition(1), addition(2, 'area2/**', 1), addition(3, 'area3/**', 2)])
multiplePlan.waves = [{ number: 1, issues: [1, 2] }, { number: 2, issues: [3] }]
multiple.ok('genesis', { input: multiplePlan })
multiple.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
multiple.refuse('wave-release', { flags: ['--wave', '2'] }, /issue #2/)
multiple.ok('done', { flags: ['--issue', '2'] })
current = multiple.ok('wave-release', { flags: ['--wave', '2'] })
assert.equal(current.waves[1].released, true)
console.log('  PASS: mixed done and handed-off predecessors release only after every previous-wave issue qualifies')

// Both historical PR-binding shapes count; an unmerged code edge never does.
for (const binding of ['issue', 'queue']) {
  const legacyBinding = fixture('1,2')
  const legacyPlan = content(legacyBinding.plan.base_sha, [addition(1), addition(2)])
  legacyPlan.issues[0].verdict = 'handed-off'
  legacyPlan.lanes.shift()
  legacyPlan.lane_profiles.shift()
  legacyPlan.merge_queue = [{ issue: 1, pr: 101 }]
  if (binding === 'issue') legacyPlan.issues[0].pr = 101
  legacyBinding.ok('genesis', { input: legacyPlan })
  current = legacyBinding.ok('wave-release', { flags: ['--wave', '2'] })
  assert.equal(current.waves[1].released, true)
}
for (const edge of ['blocked_by', 'overlap']) {
  const dependency = fixture('1,2,3')
  const deps = content(dependency.plan.base_sha, [addition(1), addition(2), addition(3)])
  if (edge === 'blocked_by') deps.issues[1].blocked_by = [1]
  else {
    deps.issues[0].candidate_files.push('shared.txt')
    deps.issues[1].candidate_files.push('shared.txt')
    deps.overlaps = [{ issue_a: 1, issue_b: 2, paths: ['shared.txt'], resolution: 'serialize', merge_dependency: { before: 1, after: 2 } }]
  }
  dependency.ok('genesis', { input: deps })
  dependency.ok('handoff', { flags: ['--issue', '1', '--pr', '101'] })
  dependency.refuse('wave-release', { flags: ['--wave', '2'] }, /merge prerequisite #1.*done/)
  current = dependency.ok('done', { flags: ['--issue', '1'] })
  assert.equal(current.waves[0].issues[0], 2) // first wave now implicitly eligible
  dependency.ok('handoff', { flags: ['--issue', '2', '--pr', '102'] })
  current = dependency.ok('wave-release', { flags: ['--wave', '2'] })
  assert.equal(current.waves[1].released, true)
}
console.log('  PASS: issue and queue PR bindings release preferences; blocked_by and overlap dependencies wait for merge')

NODE

[ -z "$(find "$tmp" -name '*.candidate.*')" ] || fail "a candidate file was left behind"
REVISER="$reviser" WRITER="$writer" TEST_ROOT="$tmp" node --input-type=module <<'MEMBERSHIP_TEST'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { chmodSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { hostname } from 'node:os'
const { reconcileMembership, membershipActions } = await import(process.env.REVISER)
const { acquireSlateLock, releaseSlateLock } = await import(process.env.WRITER)
const issue = { number: 42, url: 'https://github.com/example/repo/issues/42' }
const state = { labels: [], comments: [] }
let concurrent = false
// Emulate `gh api --paginate --jq`: apply the caller's real filter to one page.
const jqPage = (args, page) => execFileSync('jq', ['-c', args[args.indexOf('--jq') + 1]], { input: JSON.stringify(page), encoding: 'utf8' })
const github = (args) => {
  if (args[0] === 'label') return JSON.stringify([{ name: 'slated' }])
  if (args[0] === 'api') return args.includes('--jq') ? jqPage(args, state.comments) : JSON.stringify([state.comments])
  if (args[1] === 'view') return JSON.stringify({ labels: state.labels })
  if (args[1] === 'comment') state.comments.push({ body: args.at(-1) })
  if (args.includes('--add-label')) state.labels = [{ name: 'slated' }]
  if (args.includes('--remove-label')) {
    state.labels = []
    if (concurrent) state.comments.push({ body: 'Slate membership:\n- session: other\n- slate: other\n- action: add' })
  }
  return ''
}
const run = (session, slate, action) => reconcileMembership({ root: process.env.TEST_ROOT, session, slate, issue, action, github })
run('one', 'first', 'add')
run('one', 'first', 'add')
assert.equal(state.comments.length, 1)
assert.equal(state.labels[0].name, 'slated')
run('two', 'second', 'add')
run('one', 'first', 'remove')
assert.equal(state.labels[0].name, 'slated')
run('two', 'second', 'remove')
assert.deepEqual(state.labels, [])
run('one', 'first', 'add')
concurrent = true
run('one', 'first', 'remove')
assert.equal(state.labels[0].name, 'slated')
// Dotted identifiers round-trip, and a foreign duplicate cannot take ownership.
concurrent = false
state.labels = []
state.comments = []
run('session.1', 'slate.1', 'add')
state.comments[0].user = { login: 'original' }
state.comments.push({ body: state.comments[0].body, user: { login: 'foreign' } })
// The mock publishes the removal as the original author.
const originalGithub = (args) => {
  const result = github(args)
  if (args[1] === 'comment') state.comments.at(-1).user = { login: 'original' }
  return result
}
reconcileMembership({ root: process.env.TEST_ROOT, session: 'session.1', slate: 'slate.1', issue, action: 'remove', github: originalGithub })
assert.deepEqual(state.labels, [])
// Force-release recovery follows the recorded transfer chain, but leaves other slates alone.
const recoveryRoot = join(process.env.TEST_ROOT, 'recovery-test')
const locked = acquireSlateLock({ root: recoveryRoot, slate: 'recovered', session: 'old', issues: [42], create: true })
releaseSlateLock({ root: recoveryRoot, slate: 'recovered', session: 'middle', force: true, reason: 'recovery' })
acquireSlateLock({ root: recoveryRoot, slate: 'recovered', session: 'middle', issues: [42], create: true })
releaseSlateLock({ root: recoveryRoot, slate: 'recovered', session: 'new', force: true, reason: 'recovery again' })
acquireSlateLock({ root: recoveryRoot, slate: 'recovered', session: 'new', issues: [42], create: true })
assert.ok(locked.mintedToken)
state.comments = []
state.labels = []
const recover = (session, slate, action) => reconcileMembership({ root: recoveryRoot, session, slate, issue, action, github })
recover('old', 'recovered', 'add')
state.comments.at(-1).user = { login: 'alice' }
state.comments.at(-1).author_association = 'COLLABORATOR'
recover('other', 'unrelated', 'add')
const bobGithub = (args) => {
  const result = github(args)
  if (args[1] === 'comment') {
    state.comments.at(-1).user = { login: 'bob' }
    state.comments.at(-1).author_association = 'OWNER'
  }
  return result
}
reconcileMembership({ root: recoveryRoot, session: 'new', slate: 'recovered', issue, action: 'remove', github: bobGithub })
assert.equal(state.labels[0].name, 'slated')
assert.ok(state.comments.some((comment) => comment.body.includes('session: old\n- slate: recovered\n- action: remove')))
recover('other', 'unrelated', 'remove')
assert.deepEqual(state.labels, [])

// An outsider cannot preseed ownership, including for login-only test mocks.
state.comments = [{ body: 'Slate membership:\n- session: original\n- slate: secure\n- action: add',
  user: { login: 'outsider' }, author_association: 'NONE' }]
state.labels = []
const ownerGithub = (args) => {
  const result = github(args)
  if (args[1] === 'comment') state.comments.at(-1).user = { login: 'owner' }
  return result
}
const ownerRun = (action) => reconcileMembership({ root: recoveryRoot, session: 'original', slate: 'secure', issue, action, github: ownerGithub })
ownerRun('add')
ownerRun('remove')
assert.equal(state.comments.filter((comment) => comment.user?.login === 'owner').length, 2)
assert.deepEqual(state.labels, [])

// An authenticated publisher with author_association NONE and an unlisted actor id is trusted for its own comments,
// and an ordinary non-force lock release followed by re-acquisition retires the prior session on that slate.
const normalRoot = join(process.env.TEST_ROOT, 'normal-transfer-test')
const normalLock = acquireSlateLock({ root: normalRoot, slate: 'normal-transfer', session: 'prior-session', issues: [42], create: true })
const botGithub = (args) => {
  const result = github(args)
  if (args[1] === 'comment') {
    state.comments.at(-1).user = { id: 999999999, login: 'unlisted-bot[bot]' }
    state.comments.at(-1).author_association = 'NONE'
  }
  return result
}
state.comments = []
state.labels = []
reconcileMembership({ root: normalRoot, session: 'prior-session', slate: 'normal-transfer', issue, action: 'add', github: botGithub })
assert.equal(state.labels[0]?.name, 'slated')
releaseSlateLock({ root: normalRoot, slate: 'normal-transfer', session: 'prior-session', ownerToken: normalLock.mintedToken })
acquireSlateLock({ root: normalRoot, slate: 'normal-transfer', session: 'next-session', issues: [42], create: true })
reconcileMembership({ root: normalRoot, session: 'next-session', slate: 'normal-transfer', issue, action: 'remove', github: botGithub })
assert.ok(state.comments.some((comment) => comment.body.includes('session: prior-session\n- slate: normal-transfer\n- action: remove')))
assert.deepEqual(state.labels, [])

// Two independent clones sharing a slate name do not retire each other's active membership.
const cloneA = join(process.env.TEST_ROOT, 'clone-a')
const cloneB = join(process.env.TEST_ROOT, 'clone-b')
acquireSlateLock({ root: cloneA, slate: 'sprint', session: 'alice', issues: [42], create: true })
acquireSlateLock({ root: cloneB, slate: 'sprint', session: 'bob', issues: [42], create: true })
reconcileMembership({ root: cloneA, session: 'alice', slate: 'sprint', issue, action: 'add', github: bobGithub })
reconcileMembership({ root: cloneB, session: 'bob', slate: 'sprint', issue, action: 'add', github: bobGithub })
reconcileMembership({ root: cloneB, session: 'bob', slate: 'sprint', issue, action: 'remove', github: bobGithub })
assert.equal(state.labels[0]?.name, 'slated')
reconcileMembership({ root: cloneA, session: 'alice', slate: 'sprint', issue, action: 'remove', github: bobGithub })
assert.deepEqual(state.labels, [])

// A malformed comment read still refuses rather than reading as "no membership".
for (const output of ['[]\n', '"text"\n', 'null\n', '{"body":\n']) {
  const malformed = (args) => args[0] === 'api' && args.includes('--jq') ? output : github(args)
  assert.throws(() => reconcileMembership({ root: process.env.TEST_ROOT, session: 'bad', slate: 'bad', issue, action: 'add', github: malformed }),
    /membership: invalid paginated comments/, JSON.stringify(output))
}

// Through the real gh wrapper, more than 1 MiB of unrelated comments stays under
// execFileSync's default buffer because each page is projected before output.
const bin = join(process.env.TEST_ROOT, 'large-gh-bin')
mkdirSync(bin, { recursive: true })
const ghState = join(bin, 'state.json')
writeFileSync(ghState, JSON.stringify({ labels: [], pages: [[{ body: 'x'.repeat(1200000), user: { id: 7, login: 'chatty' }, author_association: 'NONE' }],
  [{ body: 'Slate membership:\n- session: big\n- slate: big\n- action: add', user: { id: 8, login: 'outsider' }, author_association: 'NONE' }]] }))
writeFileSync(join(bin, 'gh'), `#!/usr/bin/env node
const fs = require('fs')
const { execFileSync } = require('child_process')
const args = process.argv.slice(2)
const s = JSON.parse(fs.readFileSync(process.env.LARGE_GH_STATE, 'utf8'))
const save = () => fs.writeFileSync(process.env.LARGE_GH_STATE, JSON.stringify(s))
// Return rather than process.exit(): exiting can truncate a large write to a pipe.
const main = () => {
  if (args[0] === 'label') return JSON.stringify([{ name: 'slated' }])
  if (args[0] === 'issue' && args[1] === 'view') return JSON.stringify({ labels: s.labels })
  if (args[0] === 'issue' && args[1] === 'comment') {
    s.pages.push([{ body: args.at(-1), user: { id: 9, login: 'owner' }, author_association: 'OWNER' }]); save(); return ''
  }
  if (args[0] === 'issue' && args[1] === 'edit') { s.labels = args.includes('--add-label') ? [{ name: 'slated' }] : []; save(); return '' }
  if (args[0] === 'api' && args[1] === 'user') return JSON.stringify({ login: 'owner' })
  if (args[0] === 'api' && args[1].includes('/issues/42/comments')) {
    const jq = args.indexOf('--jq')
    if (jq < 0) return JSON.stringify(args.includes('--slurp') ? s.pages : s.pages.flat())
    return s.pages.map((page) => execFileSync('jq', ['-c', args[jq + 1]], { input: JSON.stringify(page), encoding: 'utf8', maxBuffer: Infinity })).join('')
  }
  return null
}
const output = main()
if (output === null) process.exitCode = 1
else process.stdout.write(output)
`)
chmodSync(join(bin, 'gh'), 0o755)
process.env.PATH = `${bin}:${process.env.PATH}`
process.env.LARGE_GH_STATE = ghState
reconcileMembership({ root: join(process.env.TEST_ROOT, 'large-test'), session: 'big', slate: 'big', issue, action: 'add' })
let large = JSON.parse(readFileSync(ghState, 'utf8'))
// The outsider's preseeded add is not trusted, so the owner's own add is posted.
assert.equal(large.pages.length, 3)
assert.deepEqual(large.labels, [{ name: 'slated' }])
reconcileMembership({ root: join(process.env.TEST_ROOT, 'large-test'), session: 'big', slate: 'big', issue, action: 'remove' })
large = JSON.parse(readFileSync(ghState, 'utf8'))
assert.match(large.pages.at(-1)[0].body, /action: remove$/)
assert.deepEqual(large.labels, [])
// Prefix-shaped bodies padded with garbage past 1 MiB in total are dropped by the
// length cap: the read still reconciles, and the trusted padded add is not counted.
writeFileSync(ghState, JSON.stringify({ labels: [], pages: [[0, 1].map(() => ({
  body: `Slate membership:\n- session: pad\n- slate: pad\n- action: add${'x'.repeat(600000)}`,
  user: { id: 9, login: 'owner' }, author_association: 'OWNER' }))] }))
reconcileMembership({ root: join(process.env.TEST_ROOT, 'padded-test'), session: 'pad', slate: 'pad', issue, action: 'add' })
large = JSON.parse(readFileSync(ghState, 'utf8'))
assert.equal(large.pages.length, 2, 'the padded add was counted as a membership')
assert.equal(large.pages[1][0].body, 'Slate membership:\n- session: pad\n- slate: pad\n- action: add')
// A valid membership followed by trailing whitespace past the cap is stripped
// before the cap, so it still counts: re-adding it posts nothing.
writeFileSync(ghState, JSON.stringify({ labels: [{ name: 'slated' }], pages: [[{
  body: `Slate membership:\n- session: trail\n- slate: trail\n- action: add${' '.repeat(1100)}`,
  user: { id: 9, login: 'owner' }, author_association: 'OWNER' }]] }))
reconcileMembership({ root: join(process.env.TEST_ROOT, 'trailing-test'), session: 'trail', slate: 'trail', issue, action: 'add' })
large = JSON.parse(readFileSync(ghState, 'utf8'))
assert.equal(large.pages.length, 1, 'a whitespace-padded valid membership was not counted')
assert.deepEqual(large.labels, [{ name: 'slated' }])
console.log('  PASS: membership reads project >1 MiB of unrelated comments and refuse malformed pages')
const unstarted = { number: 43, url: 'https://github.com/example/repo/issues/43', verdict: 'valid' }
const started = { ...issue, verdict: 'valid' }
const document = { revisions: [{ plan: { issues: [started, unstarted], lanes: [
  { issue: 42, run_id: 'started' }, { issue: 43, run_id: 'unstarted' },
] } }] }
mkdirSync(join(process.env.TEST_ROOT, 'runs', 'started'), { recursive: true })
assert.deepEqual(membershipActions(document, process.env.TEST_ROOT, true).map((entry) => entry.action), ['add', 'remove'])
console.log('  PASS: membership add, drop, close and concurrent add reconciliation')
MEMBERSHIP_TEST

# Two repositories share issue and PR numbers, paths, and a wave without overlap.
repo="$(new_repo multi-repo)"
git -C "$repo" remote add origin https://github.com/owner/a.git
write_plan "$repo" seed '[]'
jq '.revisions[0].plan | .repo = "owner/a" |
  .issues = [.issues[0], .issues[1]] |
  .issues[0] |= (.number = 7 | .url = "https://github.com/owner/a/issues/7" | .candidate_files = ["same.txt"]) |
  .issues[1] |= (.repo = "owner/b" | .number = 7 | .url = "https://github.com/owner/b/issues/7" | .candidate_files = ["same.txt"]) |
  .lanes = [.lanes[0], .lanes[1]] |
  .lanes[0] |= (.issue = 7 | .run_id = "run-fleet-a7" | .fence = ["same.txt"]) |
  .lanes[1] |= (.repo = "owner/b" | .issue = 7 | .run_id = "run-fleet-b7" | .fence = ["same.txt"]) |
  .waves = [{number: 1, issues: [7, "owner/b#7"]}] | .overlaps = [] |
  .lane_profiles = [.lanes[] | {lane: .lane, policy: null}] |
  . as $p | .lane_profiles |= map(.policy = $p.policy)' \
    "$repo/.git/dev-flow-v2/slates/seed/plan.json" >"$tmp/multi-plan.json"
foreign_repo="$(new_repo multi-foreign)"
git -C "$foreign_repo" remote add origin https://github.com/owner/b.git
foreign_base="$(git -C "$foreign_repo" rev-parse HEAD)"
jq --arg base "$foreign_base" '.repository_bases = [{repo:"owner/b",base_sha:$base}] | .lanes[1].base_sha = $base' "$tmp/multi-plan.json" >"$tmp/multi-with-base.json"
mv "$tmp/multi-with-base.json" "$tmp/multi-plan.json"
multi_token="$(cd "$repo" && node "$writer" lock acquire --slate fleet --session owner --issues '7,owner/b#7')"
jq 'del(.repository_bases)' "$tmp/multi-plan.json" >"$tmp/missing-base.json"
if (cd "$repo" && node "$reviser" genesis --slate fleet --session owner --owner-token "$multi_token" --input "$tmp/missing-base.json" --reason invalid) >"$tmp/multi-refusal" 2>&1; then
    fail 'genesis accepted a foreign repository without its base'
fi
grep -qF 'requires a repository_bases entry' "$tmp/multi-refusal" || fail 'missing genesis base diagnostic'
(cd "$repo" && node "$reviser" genesis --slate fleet --session owner --owner-token "$multi_token" --input "$tmp/multi-plan.json" --reason 'two repositories')
multi_plan="$repo/.git/dev-flow-v2/slates/fleet/plan.json"
a_lane="$(jq -r '.revisions[-1].plan.lanes[0].lane' "$multi_plan")"
b_lane="$(jq -r '.revisions[-1].plan.lanes[1].lane' "$multi_plan")"
b_branch="$(jq -r '.revisions[-1].plan.lanes[1].branch' "$multi_plan")"
(cd "$repo" && node "$reviser" expand --slate fleet --session owner --owner-token "$multi_token" --repo owner/b --lane "$b_lane" --path extra.txt --reason 'B expansion')
jq -e '.revisions[-1].plan | (.lanes[0].expansions | length == 0) and (.lanes[1].expansions[0].path == "extra.txt")' "$multi_plan" >/dev/null || fail 'expansion selected the wrong repository'
if (cd "$repo" && node "$reviser" expand --slate fleet --session owner --owner-token "$multi_token" --repo owner/a --lane "$b_lane" --path other.txt --reason wrong) >"$tmp/multi-refusal" 2>&1; then
    fail 'expand accepted mismatched repository'
fi
if (cd "$repo" && node "$reviser" release --slate fleet --session owner --owner-token "$multi_token" --repo owner/b --issue 7 --lane "$a_lane" --path same.txt --reason wrong) >"$tmp/multi-refusal" 2>&1; then
    fail 'release crossed repository boundary'
fi
grep -qF 'cannot release a fence across repositories' "$tmp/multi-refusal" || fail 'release selected wrong same-number source'
(cd "$repo" && node "$reviser" handoff --slate fleet --session owner --owner-token "$multi_token" --repo owner/b --issue 7 --pr 9 --check-result "$tmp/valid-gate.json" --reason 'B handed off')
multi_plan="$repo/.git/dev-flow-v2/slates/fleet/plan.json"
jq -e '.revisions[-1].plan | .issues[0].verdict == "valid" and .issues[1].verdict == "handed-off" and .merge_queue == [{repo:"owner/b",issue:7,pr:9}]' "$multi_plan" >/dev/null || fail 'foreign handoff selected the conductor issue'
printf 'Claiming — starting implementation on branch %s (session test-session).\n\n' "$b_branch" >"$tmp/foreign-claim-record.md"
cat >>"$tmp/foreign-claim-record.md" <<'EOF'
Claim record (for `/wrap` — undo only what this claim added):
- assignee added by this claim: no
- `claim:` label added by this claim: claim:gpt
- `claim:` model label added by this claim: n/a
- `claim:` label displaced by this claim: none
- assignee logins owned by this claim chain: none
- `claim:` label owned by this claim chain: claim:gpt
- `claim:` model label owned by this claim chain: n/a
- `claim:` label displaced by this claim chain: none
EOF
printf '%s\n' '{"families":[{"slug":"gpt"}]}' >"$tmp/foreign-registry.json"
(cd "$repo" && node "$reviser" fix-request --slate fleet --session owner --owner-token "$multi_token" --repo owner/b --issue 7 --reason 'foreign PR finding')
(cd "$repo" && node "$reviser" reactivate --slate fleet --session owner --owner-token "$multi_token" --repo owner/b --issue 7 --reason 'foreign PR finding' \
    --claim-record-file "$tmp/foreign-claim-record.md" --claim-label claim:gpt --model-label none --family gpt --registry-snapshot "$tmp/foreign-registry.json")
jq -e '.revisions[-1].plan.retained_lanes[] | select(.lane.issue == 7 and .lane.repo == "owner/b") | .state == "working"' "$multi_plan" >/dev/null || fail 'foreign reactivation selected the conductor issue'
(cd "$repo" && node "$reviser" handoff --slate fleet --session owner --owner-token "$multi_token" --issue 7 --pr 9 --check-result "$tmp/valid-gate.json" --reason 'A handed off')
jq -e '.revisions[-1].plan.merge_queue | length == 2' "$multi_plan" >/dev/null || fail 'equal PR numbers across repositories collided'
printf '%s\n' '{"issues":[7,"owner/b#7"]}' >"$tmp/multi-order.json"
(cd "$repo" && node "$reviser" queue-order --slate fleet --session owner --owner-token "$multi_token" --input "$tmp/multi-order.json" --reason 'A first')
printf 'foreign moved\n' >"$foreign_repo/unrelated.txt"
git -C "$foreign_repo" add unrelated.txt
git -C "$foreign_repo" commit -qm 'move B base'
foreign_moved="$(git -C "$foreign_repo" rev-parse HEAD)"
(cd "$repo" && node "$reviser" base-move --slate fleet --session owner --owner-token "$multi_token" --repo owner/b --repo-root "$foreign_repo" --new-base "$foreign_moved" --done 7 --reason 'B merged')
jq -e --arg base "$foreign_moved" '.revisions[-1].plan.repository_bases == [{repo:"owner/b",base_sha:$base}]' "$multi_plan" >/dev/null || fail 'foreign base did not move'

jq -e '.revisions[-1].plan | .issues[0].verdict == "handed-off" and .issues[1].verdict == "done" and .merge_queue == [{issue:7,pr:9}]' "$multi_plan" >/dev/null || fail 'foreign done removed conductor queue entry'
pass 'multi-repo schema, handoff, done and queue selectors preserve same-number identities'

# First entry owns the repository base; subsequent issues reuse it.
jq --arg base "$foreign_base" '{
  issue: (.issues[1] | .repo = "owner/c" | .number = 8 | .url = "https://github.com/owner/c/issues/8" | .candidate_files = ["c8.txt"]),
  lane: (.lanes[1] | .repo = "owner/c" | .issue = 8 | .lane = "c8" | .branch = "feat/c8" | .run_id = "run-c8" | .fence = ["c8.txt"] | .base_sha = $base),
  profile: {lane: "c8", policy: .policy},
  repository_base: {repo: "owner/c", base_sha: $base}
}' "$tmp/multi-plan.json" >"$tmp/add-c8.json"
jq 'del(.repository_base)' "$tmp/add-c8.json" >"$tmp/add-no-base.json"
if (cd "$repo" && node "$reviser" add-issue --slate fleet --session owner --owner-token "$multi_token" --input "$tmp/add-no-base.json" --reason invalid) >"$tmp/multi-refusal" 2>&1; then
    fail 'addition accepted first foreign issue without a base'
fi
grep -qF 'requires repository_base' "$tmp/multi-refusal" || fail 'missing addition base diagnostic'
(cd "$repo" && node "$reviser" add-issue --slate fleet --session owner --owner-token "$multi_token" --input "$tmp/add-c8.json" --reason 'first C issue')
jq 'del(.repository_base) | .issue.number = 9 | .issue.url = "https://github.com/owner/c/issues/9" | .issue.candidate_files = ["c9.txt"] | .lane.issue = 9 | .lane.wave = 2 | .lane.lane = "c9" | .lane.branch = "feat/c9" | .lane.run_id = "run-c9" | .lane.fence = ["c9.txt"] | .profile.lane = "c9"' "$tmp/add-c8.json" >"$tmp/add-c9.json"
(cd "$repo" && node "$reviser" add-issue --slate fleet --session owner --owner-token "$multi_token" --input "$tmp/add-c9.json" --reason 'second C issue')
jq -e --arg base "$foreign_base" '[.revisions[-1].plan.repository_bases[] | select(.repo == "owner/c")] == [{repo:"owner/c",base_sha:$base}]' "$multi_plan" >/dev/null || fail 'addition did not preserve exactly one C base'
pass 'foreign additions require an initial base and reuse the recorded entry'

REVISER="$reviser" PLAN="$tmp/multi-plan.json" node --input-type=module <<'BASE_MOVE_TEST'
import assert from 'node:assert/strict'
import { readFileSync, mkdtempSync, mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { hostname } from 'node:os'
const { reviseForBaseMove } = await import(process.env.REVISER)
const plan = JSON.parse(readFileSync(process.env.PLAN, 'utf8'))
const newBase = 'b'.repeat(40)
const options = { newBase, repo: 'owner/b', done: [7], changed: ['same.txt'] }
const revised = reviseForBaseMove(plan, options)
assert.equal(revised.issues[0].verdict, 'valid')
assert.equal(revised.issues[1].verdict, 'done')
assert.deepEqual(revised.lanes, [plan.lanes[0]])
assert.deepEqual(revised.waves[0].issues, [7])
assert.equal(revised.base_sha, plan.base_sha)
assert.equal(revised.repository_bases.find((entry) => entry.repo === 'owner/b').base_sha, newBase)
assert.throws(() => reviseForBaseMove(plan, { ...options, done: [8] }), /not in the plan/)
assert.throws(() => reviseForBaseMove(plan, { ...options, done: [] }), /touches lane/)
const root = mkdtempSync(join(tmpdir(), 'base-move-selectors-'))
mkdirSync(join(root, 'runs', plan.lanes[0].run_id), { recursive: true })
const reverified = reviseForBaseMove(plan, { ...options, done: [], reverified: [7], root })
assert.equal(reverified.lanes[1].base_sha, newBase)
assert.deepEqual(reverified.lanes[0], plan.lanes[0])
mkdirSync(join(root, 'runs', plan.lanes[1].run_id), { recursive: true })
assert.throws(() => reviseForBaseMove(plan, { ...options, done: [], reverified: [7], root }), /provisioned lane/)
const conductor = reviseForBaseMove(plan, { newBase, done: [7], changed: ['same.txt'] })
assert.equal(conductor.base_sha, newBase)
assert.equal(conductor.issues[1].verdict, 'valid')
assert.deepEqual(conductor.waves[0].issues, ['owner/b#7'])
console.log('PASS: base-move scopes done, reverified, waves and fences to repository identities')
BASE_MOVE_TEST

REVISER="$reviser" WRITER="$writer" node --input-type=module <<'BIND_PR_AND_GATE_TEST'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const reviser = process.env.REVISER
const writer = process.env.WRITER
const { assertDispatchCapacity } = await import(writer)

function makeSlate(issuesList = [1, 2]) {
  const dir = mkdtempSync(join(tmpdir(), 'plan-revise-1950-'))
  const git = (...args) => execFileSync('git', args, { cwd: dir, encoding: 'utf8' }).trim()
  git('init', '-q', '-b', 'main')
  git('config', 'user.email', 'test@example.com')
  git('config', 'user.name', 'Test User')
  git('remote', 'add', 'origin', 'https://github.com/example/repo.git')
  writeFileSync(join(dir, 'README.md'), 'init\n')
  git('add', 'README.md')
  git('commit', '-q', '-m', 'init')
  const baseSha = git('rev-parse', 'HEAD')
  const token = execFileSync(process.execPath, [
    writer, 'lock', 'acquire', '--slate', 's', '--session', 'owner', '--issues', issuesList.join(','),
  ], { cwd: dir, encoding: 'utf8' }).trim()
  const canonical = join(dir, '.git/dev-flow-v2/slates/s/plan.json')
  const root = join(dir, '.git/dev-flow-v2')
  const gateFile = join(dir, 'gate.json')
  const validGate = {
    status: 'pass',
    condition: 'ready',
    head: 'a'.repeat(40),
    fingerprint: 'test-gate-pass',
  }
  writeFileSync(gateFile, JSON.stringify(validGate))
  let seq = 0
  function run(cmd, { input, flags = [], env = {} } = {}) {
    const extra = []
    if (input !== undefined) {
      const p = join(dir, `in-${++seq}.json`)
      writeFileSync(p, JSON.stringify(input))
      extra.push('--input', p)
    }
    return spawnSync(process.execPath, [
      reviser, cmd, '--slate', 's', '--session', 'owner', '--owner-token', token,
      '--reason', '1950 test', '--at', `2026-10-23T00:${String(seq++).padStart(2, '0')}:00Z`,
      ...extra, ...flags,
    ], { cwd: dir, encoding: 'utf8', env: { ...process.env, ...env } })
  }
  function ok(cmd, opts) {
    const r = run(cmd, opts)
    assert.equal(r.status, 0, `${cmd} failed: ${r.stderr}`)
    return JSON.parse(readFileSync(canonical, 'utf8')).revisions.at(-1).plan
  }
  function refuse(cmd, opts, pattern) {
    const before = existsSync(canonical) ? readFileSync(canonical, 'utf8') : null
    const r = run(cmd, opts)
    assert.notEqual(r.status, 0, `${cmd} unexpectedly succeeded`)
    assert.match(r.stderr, pattern)
    assert.equal(existsSync(canonical) ? readFileSync(canonical, 'utf8') : null, before)
  }
  const policy = {
    rigor: 'deep', rigor_source: 'fixture',
    caps: { challenge: 1, review: 1, integration: 1, remediation: 1, min_rounds: 1, wall_clock_min: 60 },
    breadth: { max_agent_runs: 10, max_parallel_agents: 1, max_in_flight: 3 }, strategy: 'plan', strategy_source: 'fixture',
    role_tiers: { orchestrator: 'apex', implementer: 'frontier', challenger: 'apex', reviewer: 'frontier', integrator: 'economy' }, operator_pins: [],
  }
  const initialPlan = {
    base_sha: baseSha,
    policy,
    dispatcher: { kind: 'interactive', parallel_cap: 1, foreman_max_parallel: null },
    issues: [
      { number: 1, title: 'Issue 1', url: 'https://github.com/example/repo/issues/1', candidate_files: ['a.txt'], verdict: 'valid', blocked_by: [] },
      { number: 2, title: 'Issue 2', url: 'https://github.com/example/repo/issues/2', candidate_files: ['b.txt'], verdict: 'valid', blocked_by: [] },
    ],
    lanes: [
      { issue: 1, lane: 'l1', branch: 'issue-1', run_id: 'run-1', fence: [{ path: 'a.txt' }], expansions: [], wave: 1 },
      { issue: 2, lane: 'l2', branch: 'issue-2', run_id: 'run-2', fence: [{ path: 'b.txt' }], expansions: [], wave: 2 },
    ],
    lane_profiles: [
      { lane: 'l1', policy },
      { lane: 'l2', policy },
    ],
    waves: [
      { number: 1, issues: [1] },
      { number: 2, issues: [2] },
    ],
    overlaps: [],
  }
  ok('genesis', { input: initialPlan })
  return { dir, root, canonical, gateFile, validGate, ok, refuse, cleanup: () => rmSync(dir, { recursive: true, force: true }) }
}

const s = makeSlate([1, 2])
try {
  // (a) bind-pr binds PR while keeping Working slot and claim intact
  writeFileSync(process.env.CLAIM_HELPER_LOG, '')
  let plan = s.ok('bind-pr', { flags: ['--issue', '1', '--pr', '101'] })
  assert.equal(plan.issues.find((i) => i.number === 1).pr, 101)
  assert.equal(plan.issues.find((i) => i.number === 1).verdict, 'valid')
  assert.equal(plan.lanes.some((l) => l.issue === 1), true, 'bind-pr must retain lane in plan.lanes')
  assert.deepEqual(plan.merge_queue ?? [], [], 'bind-pr must not enqueue PR in merge_queue')
  assert.equal(readFileSync(process.env.CLAIM_HELPER_LOG, 'utf8'), '', 'bind-pr must not call release-claim.sh')
  assert.deepEqual(assertDispatchCapacity(s.root, plan, plan.lanes[1], 's'), { working: 1, in_flight: 2 }, 'bound pre-handoff lane retains Working capacity')

  // Idempotent re-bind works; conflicting re-bind or duplicate PR or wave-release refuses
  plan = s.ok('bind-pr', { flags: ['--issue', '1', '--pr', '101'] })
  s.refuse('bind-pr', { flags: ['--issue', '1', '--pr', '102'] }, /already bound to PR #101/)
  s.refuse('bind-pr', { flags: ['--issue', '2', '--pr', '101'] }, /duplicate PR 101/)
  s.refuse('bind-pr', { flags: ['--issue', '99', '--pr', '109'] }, /no live pre-handoff lane/)
  s.refuse('wave-release', { flags: ['--wave', '2'] }, /done or handed-off with a bound PR/)

  // (b) fix-request & reactivate work on bound draft PR without releasing/requiring restore flags
  s.refuse('fix-request', { flags: ['--issue', '1'], env: { MOCK_PR_DRAFT: 'false' } }, /fix round requires a draft delivery PR/)
  s.refuse('fix-request', { flags: ['--issue', '1'], env: { MOCK_MERGED_PR: '101' } }, /fix round requires an open delivery PR/)
  plan = s.ok('fix-request', { flags: ['--issue', '1'] })
  assert.equal(plan.lanes.some((l) => l.issue === 1), true)
  plan = s.ok('reactivate', { flags: ['--issue', '1'] })
  assert.equal(plan.lanes.some((l) => l.issue === 1), true)
  assert.equal(readFileSync(process.env.CLAIM_HELPER_LOG, 'utf8'), '', 'bound live reactivate without claim flags keeps live claim cleanly')

  // (c) handoff PR binding + gate evidence checks run BEFORE release-claim.sh
  s.refuse('handoff', { flags: ['--issue', '1', '--pr', '102', '--check-result', s.gateFile] }, /handoff must retain the delivery PR binding/)
  s.refuse('handoff', { flags: ['--issue', '1', '--pr', '101'] }, /requires current handoff-check gate evidence/)

  const badGate = join(s.dir, 'bad-gate.json')
  for (const [label, payload, pattern, extraEnv] of [
    ['fail status', { ...s.validGate, status: 'fail' }, /handoff gate status must be pass/, {}],
    ['parked condition', { ...s.validGate, condition: 'parked' }, /handoff gate condition must be ready or promoted/, {}],
    ['bad head', { ...s.validGate, head: 'not-a-sha' }, /requires a 40-hex head SHA/, {}],
    ['empty fingerprint', { ...s.validGate, fingerprint: '  ' }, /requires a non-empty fingerprint/, {}],
    ['live head mismatch', { ...s.validGate, head: 'b'.repeat(40) }, /does not match live PR #101 head/, {}],
    ['pr mismatch', { ...s.validGate, pr: 999 }, /does not match --pr 101/, {}],
    ['repo mismatch', { ...s.validGate, repository: 'other/repo' }, /does not match example\/repo/, {}],
    ['pr read fail', s.validGate, /handoff PR state is indeterminate/, { MOCK_PR_VIEW_FAIL: 'yes' }],
    ['fingerprint mismatch', { ...s.validGate, fingerprint: 'stale-fingerprint' }, /does not match live PR #101 fingerprint/, {}],
    ['fingerprint helper fail', s.validGate, /handoff live fingerprint check failed or indeterminate/, { MOCK_GATE_FAIL: 'yes' }],
    ['fingerprint helper missing', s.validGate, /handoff readiness-gate helper is missing/, { PLAN_REVISE_READINESS_GATE: join(s.dir, 'missing-readiness-gate.sh') }],
  ]) {
    writeFileSync(badGate, JSON.stringify(payload))
    s.refuse('handoff', { flags: ['--issue', '1', '--pr', '101', '--check-result', badGate], env: extraEnv }, pattern)
    assert.equal(readFileSync(process.env.CLAIM_HELPER_LOG, 'utf8'), '', `gate refusal (${label}) must precede release-claim.sh`)
  }
  s.refuse('handoff', { flags: ['--issue', '1', '--pr', '101', '--check-result', s.gateFile, '--head', 'c'.repeat(40)] }, /does not match --head/)
  assert.equal(readFileSync(process.env.CLAIM_HELPER_LOG, 'utf8'), '')

  // (c2) PR-side claim verification refuses if claim: or agent: survives on PR #101
  s.refuse('handoff', {
    flags: ['--issue', '1', '--pr', '101', '--check-result', s.gateFile],
    env: { MOCK_PR_LABELS: '[{"name":"claim:gpt"}]' },
  }, /PR #101: claim:gpt remains/)

  // (d) Valid gate handoff accepts case-insensitive matching fingerprint and runs release-claim.sh with canonical key
  writeFileSync(process.env.CLAIM_HELPER_LOG, '')
  plan = s.ok('handoff', { flags: ['--issue', '1', '--pr', '101', '--check-result', s.gateFile], env: { MOCK_GATE_FINGERPRINT: 'TEST-GATE-PASS' } })
  assert.equal(plan.issues[0].verdict, 'handed-off')
  assert.deepEqual(plan.merge_queue, [{ issue: 1, pr: 101 }])
  const expectedKey = createHash('sha256')
    .update(JSON.stringify({ repo: 'example/repo', issue: 1, branch: 'issue-1' }))
    .digest('hex')
  assert.match(readFileSync(process.env.CLAIM_HELPER_LOG, 'utf8'), new RegExp(`--pr 101 --idempotency-key ${expectedKey}`))
  console.log('  PASS: bind-pr retains Working slot, draft fix-request/reactivate work without release, handoff gate checks fail closed before release, and canonical key matches')
} finally {
  s.cleanup()
}
BIND_PR_AND_GATE_TEST

# AC5 end-to-end test: wire real lifecycle-labels.sh, claim-transaction.sh, release-claim.sh, and plan-revise.mjs
echo "==> AC5: end-to-end claim -> bind-pr/review-entry -> fix-round/reactivate -> handoff -> park -> promote"
ac5="$tmp/ac5"
mkdir -p "$ac5/bin" "$ac5/repo"
git -C "$ac5/repo" init -q -b main
git -C "$ac5/repo" config user.email "ac5@example.com"
git -C "$ac5/repo" config user.name "AC5 Tester"
git -C "$ac5/repo" remote add origin "https://github.com/evanharmon1/ac5.git"
printf 'base\n' >"$ac5/repo/a.txt"
git -C "$ac5/repo" add a.txt
git -C "$ac5/repo" commit -qm "base"
ac5_base="$(git -C "$ac5/repo" rev-parse HEAD)"
ac5_head="1234567890abcdef1234567890abcdef12345678"

cat >"$ac5/state.json" <<JSON
{
  "viewer": "evanharmon1",
  "repo_labels": ["claim:gpt", "needs-review", "parked", "merge-ready", "blocked", "feature"],
  "issues": {
    "1": {
      "number": 1,
      "state": "OPEN",
      "labels": [{"name": "feature"}],
      "assignees": [],
      "closedByPullRequestsReferences": []
    }
  },
  "prs": {},
  "comments": []
}
JSON

cat >"$ac5/bin/gh" <<'AC5_GH'
#!/usr/bin/env python3
import json
import sys

state_path = sys.argv[0]
import os
import time
state_path = os.environ["AC5_STATE"]
with open(state_path, "r", encoding="utf-8") as fh:
    state = json.load(fh)

def save():
    with open(state_path, "w", encoding="utf-8") as fh:
        json.dump(state, fh, indent=2)

args = sys.argv[1:]
cmd = args[0] if args else ""
sub = args[1] if len(args) > 1 else ""

if cmd == "api":
    endpoint = next((a for a in args[1:] if not a.startswith("-")), "")
    if endpoint == "user":
        if "--jq" in args:
            print(state["viewer"])
        else:
            print(json.dumps({"login": state["viewer"]}))
        sys.exit(0)
    if "/issues/1/comments" in endpoint:
        print(json.dumps([state["comments"]] if "--slurp" in args else state["comments"]))
        sys.exit(0)
    if "/issues/1/timeline" in endpoint or "/issues/1/events" in endpoint:
        print(json.dumps([[]] if "--slurp" in args else []))
        sys.exit(0)
    if endpoint == "repos/evanharmon1/ac5/issues/1":
        print(json.dumps(state["issues"]["1"]))
        sys.exit(0)
    sys.stderr.write(f"unexpected gh api: {args}\n")
    sys.exit(1)

if cmd == "label" and sub == "list":
    print(json.dumps([{"name": n} for n in state["repo_labels"]]))
    sys.exit(0)

if cmd == "issue" and sub == "view":
    if os.environ.get("AC5_SLOW_PROJECTION") and "--json" in args and args[args.index("--json") + 1] == "state,labels,closedByPullRequestsReferences":
        open(state_path + ".slow", "w").close()
        time.sleep(20)
        sys.stderr.write("slow projection unavailable\n")
        sys.exit(42)
    print(json.dumps(state["issues"]["1"]))
    sys.exit(0)

if cmd == "issue" and sub == "edit":
    i = 3
    iss = state["issues"]["1"]
    while i < len(args):
        if args[i] == "--add-label":
            lbl = args[i + 1]
            if not any(x["name"] == lbl for x in iss["labels"]):
                iss["labels"].append({"name": lbl})
            i += 2
        elif args[i] == "--remove-label":
            lbl = args[i + 1]
            iss["labels"] = [x for x in iss["labels"] if x["name"] != lbl]
            i += 2
        elif args[i] == "--add-assignee":
            login = args[i + 1]
            if not any(x["login"] == login for x in iss["assignees"]):
                iss["assignees"].append({"login": login})
            i += 2
        elif args[i] == "--remove-assignee":
            login = args[i + 1]
            iss["assignees"] = [x for x in iss["assignees"] if x["login"] != login]
            i += 2
        else:
            i += 1
    save()
    sys.exit(0)

if cmd == "issue" and sub == "comment":
    body = ""
    if "--body-file" in args:
        bf_path = args[args.index("--body-file") + 1]
        if bf_path == "-":
            body = sys.stdin.read()
        else:
            with open(bf_path, "r", encoding="utf-8") as bf:
                body = bf.read()
    elif "--body" in args:
        body = args[args.index("--body") + 1]
    state["comments"].append({
        "id": len(state["comments"]) + 100,
        "user": {"login": state["viewer"]},
        "author_association": "OWNER",
        "created_at": f"2026-10-23T00:{10 + len(state['comments']):02d}:00Z",
        "body": body,
    })
    save()
    sys.exit(0)

if cmd == "pr" and sub == "list":
    head = args[args.index("--head") + 1] if "--head" in args else ""
    out = [p for p in state["prs"].values() if p["state"] == "OPEN" and (not head or p["headRefName"] == head)]
    print(json.dumps(out))
    sys.exit(0)

if cmd == "pr" and sub == "view":
    num = args[2].rsplit("/", 1)[-1]
    print(json.dumps(state["prs"][num]))
    sys.exit(0)

if cmd == "pr" and sub == "edit":
    num = args[2].rsplit("/", 1)[-1]
    pr = state["prs"][num]
    i = 3
    while i < len(args):
        if args[i] == "--add-label":
            lbl = args[i + 1]
            if not any(x["name"] == lbl for x in pr["labels"]):
                pr["labels"].append({"name": lbl})
            i += 2
        elif args[i] == "--remove-label":
            lbl = args[i + 1]
            pr["labels"] = [x for x in pr["labels"] if x["name"] != lbl]
            i += 2
        else:
            i += 1
    save()
    sys.exit(0)

sys.stderr.write(f"unexpected gh call: {args}\n")
sys.exit(1)
AC5_GH
chmod +x "$ac5/bin/gh"
cat >"$ac5/bin/readiness-gate" <<'AC5_GATE'
#!/usr/bin/env bash
printf '{"status":"fingerprint","fingerprint":"ac5-pass"}\n'
AC5_GATE
chmod +x "$ac5/bin/readiness-gate"

ac5_labels() {
    python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); t=s["issues"][sys.argv[3]] if sys.argv[2]=="issue" else s["prs"][sys.argv[3]]; print(",".join(sorted(l["name"] for l in t["labels"])))' "$ac5/state.json" "$1" "$2"
}

cat >"$ac5/claim.md" <<'EOF'
Claiming — starting implementation on branch issue-1 (session s-ac5).

Claim record (for `/wrap` — undo only what this claim added):
- harness: Codex
- model: gpt-5
- family: gpt
- runtime environment: coder
- session: s-ac5
- assignee added by this claim: yes
- `claim:` label added by this claim: claim:gpt
- `claim:` model label added by this claim: n/a
- `claim:` label displaced by this claim: none
- assignee logins owned by this claim chain: evanharmon1
- `claim:` label owned by this claim chain: claim:gpt
- `claim:` model label owned by this claim chain: n/a
- `claim:` label displaced by this claim chain: none
EOF
printf '%s\n' '{"families":[{"slug":"gpt"}]}' >"$ac5/registry.json"
cat >"$ac5/gate.json" <<JSON
{"status":"pass","condition":"ready","head":"$ac5_head","pr":101,"repository":"evanharmon1/ac5","fingerprint":"ac5-pass"}
JSON

ac5_reviser="$source_root/ai/skills/universal/dev-flow-support/assets/plan-revise.mjs"
ac5_lc="$source_root/ai/skills/universal/track-work/assets/lifecycle-labels.sh"
ac5_token="$(cd "$ac5/repo" && node "$writer" lock acquire --slate s --session owner --issues 1)"
cat >"$ac5/plan-input.json" <<JSON
{
  "base_sha": "$ac5_base",
  "policy": {
    "rigor": "deep",
    "rigor_source": "fixture",
    "caps": {"challenge": 1, "review": 1, "integration": 1, "remediation": 1, "min_rounds": 1, "wall_clock_min": 60},
    "breadth": {"max_agent_runs": 10, "max_parallel_agents": 1, "max_in_flight": 2},
    "strategy": "plan",
    "strategy_source": "fixture",
    "role_tiers": {"orchestrator": "apex", "implementer": "frontier", "challenger": "apex", "reviewer": "frontier", "integrator": "economy"},
    "operator_pins": []
  },
  "dispatcher": {"kind": "interactive", "parallel_cap": 1, "foreman_max_parallel": null},
  "issues": [{"number": 1, "title": "AC5", "url": "https://github.com/evanharmon1/ac5/issues/1", "candidate_files": ["a.txt"], "verdict": "valid", "blocked_by": []}],
  "lanes": [{"issue": 1, "lane": "l1", "branch": "issue-1", "run_id": "run-ac5", "fence": [{"path": "a.txt"}], "expansions": [], "wave": 1}],
  "lane_profiles": [{"lane": "l1", "policy": {
    "rigor": "deep",
    "rigor_source": "fixture",
    "caps": {"challenge": 1, "review": 1, "integration": 1, "remediation": 1, "min_rounds": 1, "wall_clock_min": 60},
    "breadth": {"max_agent_runs": 10, "max_parallel_agents": 1, "max_in_flight": 2},
    "strategy": "plan",
    "strategy_source": "fixture",
    "role_tiers": {"orchestrator": "apex", "implementer": "frontier", "challenger": "apex", "reviewer": "frontier", "integrator": "economy"},
    "operator_pins": []
  }}],
  "waves": [{"number": 1, "issues": [1]}],
  "overlaps": []
}
JSON

(
    export PATH="$ac5/bin:$PATH" AC5_STATE="$ac5/state.json" PLAN_REVISE_READINESS_GATE="$ac5/bin/readiness-gate"
    cd "$ac5/repo"
    node "$ac5_reviser" genesis --slate s --session owner --owner-token "$ac5_token" --input "$ac5/plan-input.json" --reason 'ac5 start' >/dev/null
    "$ac5_lc" claim --repo evanharmon1/ac5 --issue 1 --branch issue-1 --record-file "$ac5/claim.md" --claim-label claim:gpt --family gpt --runtime-environment coder --registry-snapshot "$ac5/registry.json" >/dev/null
    [ "$(ac5_labels issue 1)" = "claim:gpt,feature" ] || fail "AC5 step 1 issue labels wrong: $(ac5_labels issue 1)"

    # Open draft PR #101, bind PR in plan-revise, run the publication-time mirror step (idempotent claim --pr), and enter review
    python3 - "$ac5/state.json" "$ac5_head" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
s["issues"]["1"]["closedByPullRequestsReferences"] = [{"number": 101, "repository": {"owner": {"login": "evanharmon1"}, "name": "ac5"}}]
s["prs"]["101"] = {"number": 101, "state": "OPEN", "isDraft": True, "isCrossRepository": False, "headRefName": "issue-1", "headRefOid": sys.argv[2], "labels": []}
json.dump(s, open(sys.argv[1], "w"), indent=2)
PY
    node "$ac5_reviser" bind-pr --slate s --session owner --owner-token "$ac5_token" --issue 1 --pr 101 --reason 'draft published' >/dev/null
    # Publication-time mirror step: claim-transaction takes resume_exact and mirrors active claim labels onto PR #101 without writing a duplicate claim record.
    "$ac5_lc" claim --repo evanharmon1/ac5 --issue 1 --pr 101 --branch issue-1 --record-file "$ac5/claim.md" --claim-label claim:gpt --family gpt --runtime-environment coder --registry-snapshot "$ac5/registry.json" >/dev/null
    "$ac5_lc" review-entry --repo evanharmon1/ac5 --issue 1 --pr 101 --branch issue-1 >/dev/null
    [ "$(ac5_labels issue 1)" = "claim:gpt,feature,needs-review" ] || fail "AC5 step 2 issue labels wrong: $(ac5_labels issue 1)"
    [ "$(ac5_labels pr 101)" = "claim:gpt,needs-review" ] || fail "AC5 step 2 PR labels wrong: $(ac5_labels pr 101)"
    jq -e '.revisions[-1].plan | (.lanes | length == 1) and (.issues[0].verdict == "valid") and (.issues[0].pr == 101) and ((.merge_queue // []) | length == 0)' "$ac5/repo/.git/dev-flow-v2/slates/s/plan.json" >/dev/null || fail "AC5 step 2 plan must retain Working slot"

    # Integration fix round keeps claim and Working slot
    node "$ac5_reviser" fix-request --slate s --session owner --owner-token "$ac5_token" --issue 1 --reason 'codex finding' >/dev/null
    "$ac5_lc" fix-round --repo evanharmon1/ac5 --issue 1 --pr 101 --branch issue-1 >/dev/null
    node "$ac5_reviser" reactivate --slate s --session owner --owner-token "$ac5_token" --issue 1 --reason 'fixing finding' >/dev/null
    [ "$(ac5_labels issue 1)" = "claim:gpt,feature" ] || fail "AC5 step 3 issue labels wrong: $(ac5_labels issue 1)"
    [ "$(ac5_labels pr 101)" = "claim:gpt" ] || fail "AC5 step 3 PR labels wrong: $(ac5_labels pr 101)"
    jq -e '.revisions[-1].plan | (.lanes | length == 1) and (.issues[0].verdict == "valid")' "$ac5/repo/.git/dev-flow-v2/slates/s/plan.json" >/dev/null || fail "AC5 step 3 plan must keep Working slot"

    # Passing gate handoff releases claim on issue + PR, parks idempotently, and promotes cleanly
    # Exercise the actual handoff CLI, including its real best-effort observer.
    # Independent plan/dispatch acquirers must finish while GitHub is still slow.
    node --input-type=module - "$ac5_reviser" "$writer" "$ac5_token" "$ac5/gate.json" "$ac5/repo" <<'JS'
import assert from 'node:assert/strict'
import { mkdirSync, writeFileSync, existsSync } from 'node:fs'
import { join } from 'node:path'
import { spawn, spawnSync } from 'node:child_process'
const [reviser, writer, token, gate, repo] = process.argv.slice(2)
const root = join(repo, '.git/dev-flow-v2'), runDir = join(root, 'runs/run-ac5')
mkdirSync(runDir, { recursive: true })
writeFileSync(join(runDir, 'owner-slate'), 's')
writeFileSync(join(runDir, 'run.json'), JSON.stringify({ run_id: 'run-ac5', outcome: null, pr: null, stage_transitions: [{ stage: 'integration' }] }))
const child = spawn(process.execPath, [reviser, 'handoff', '--slate', 's', '--session', 'owner', '--owner-token', token, '--issue', '1', '--pr', '101', '--check-result', gate, '--reason', 'handoff check passed'], { env: { ...process.env, AC5_SLOW_PROJECTION: '1' } })
let stderr = ''
child.stdout.resume(); child.stderr.on('data', (data) => { stderr += data })
const done = new Promise((resolve) => child.on('close', resolve))
const deadline = Date.now() + 60000
while (!existsSync(`${process.env.AC5_STATE}.slow`) && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 20))
assert.ok(existsSync(`${process.env.AC5_STATE}.slow`), 'handoff must reach real network projection outside every mutex callback')
const started = Date.now()
const acquired = spawnSync(process.execPath, ['--input-type=module', '-e', `
  import { pathToFileURL } from 'node:url'
  const { withMutex } = await import(pathToFileURL(process.argv[2]))
  withMutex(process.argv[3], () => withMutex(process.argv[4], () => console.log('both acquired')))
`, '-', writer, join(root, 'slates/s/plan.json'), join(root, 'dispatch')], { encoding: 'utf8' })
assert.equal(acquired.status, 0, acquired.stderr)
assert.match(acquired.stdout, /both acquired/)
assert.ok(Date.now() - started < 15000, 'slow projection cannot block plan or global dispatch mutex acquisition')
assert.equal(await done, 0, stderr)
assert.match(stderr, /record committed; projection failed:.*retry stage-labels\.mjs reconcile/s)
console.log('  PASS: real handoff projects after plan and dispatch mutex release, even with a 20-second failing GitHub read')
JS
    [ "$(ac5_labels issue 1)" = "feature" ] || fail "AC5 step 4 issue should have claim cleared: $(ac5_labels issue 1)"
    [ "$(ac5_labels pr 101)" = "" ] || fail "AC5 step 4 PR should have claim cleared: $(ac5_labels pr 101)"
    jq -e '.revisions[-1].plan | (.lanes | length == 0) and (.issues[0].verdict == "handed-off") and (.merge_queue == [{issue:1,pr:101}])' "$ac5/repo/.git/dev-flow-v2/slates/s/plan.json" >/dev/null || fail "AC5 step 4 plan handoff wrong"

    "$ac5_lc" park --repo evanharmon1/ac5 --issue 1 --pr 101 --branch issue-1 >/dev/null
    [ "$(ac5_labels issue 1)" = "feature,parked" ] || fail "AC5 park issue labels wrong: $(ac5_labels issue 1)"
    [ "$(ac5_labels pr 101)" = "parked" ] || fail "AC5 park PR labels wrong: $(ac5_labels pr 101)"

    python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); s["prs"]["101"]["isDraft"]=False; json.dump(s,open(sys.argv[1],"w"),indent=2)' "$ac5/state.json"
    "$ac5_lc" promote --repo evanharmon1/ac5 --issue 1 --pr 101 --branch issue-1 --check-result "$ac5/gate.json" >/dev/null
    [ "$(ac5_labels issue 1)" = "feature,merge-ready" ] || fail "AC5 promote issue labels wrong: $(ac5_labels issue 1)"
    [ "$(ac5_labels pr 101)" = "merge-ready" ] || fail "AC5 promote PR labels wrong: $(ac5_labels pr 101)"
)
pass 'AC5 end-to-end keep-claim-through-integration lifecycle verified'

echo "test-plan-revise: all cases passed"
