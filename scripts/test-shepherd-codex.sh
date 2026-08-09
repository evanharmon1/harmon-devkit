#!/usr/bin/env bash
# Hermetic regression tests for the shepherd Codex cloud-review classifier.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="${repo_root}/ai/skills/universal/shepherd/assets/check-codex-cloud-review.sh"
test_tmp="$(mktemp -d -t shepherd-codex-test-XXXXXX)"
trap 'rm -rf "$test_tmp"' EXIT

bin_dir="${test_tmp}/bin"
fixtures="${test_tmp}/fixtures"
state="${test_tmp}/state.json"
log="${test_tmp}/gh.log"
test_repo="${test_tmp}/repo"
mkdir -p "$bin_dir" "$fixtures"
git init -q "$test_repo"
git -C "$test_repo" config user.name "Shepherd Test"
git -C "$test_repo" config user.email "shepherd-test@example.invalid"
git -C "$test_repo" commit -q --allow-empty -m "previous head"
git -C "$test_repo" commit -q --allow-empty -m "current head"
cd "$test_repo"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cat >"${bin_dir}/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"

if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
    # PR state defaults to OPEN, so every classifier fixture behaves exactly as
    # it did before reaping existed. `reap` needs per-PR control, so a
    # pr-state-<n> file overrides one PR and fail-pr-<n> makes it unreadable.
    pr_number="${3:-}"
    [ ! -f "$GH_FIXTURES/fail-pr-$pr_number" ] || exit 94
    [ ! -f "$GH_FIXTURES/slow-pr" ] || sleep 5
    pr_state=OPEN
    if [ -f "$GH_FIXTURES/pr-state-$pr_number" ]; then
        pr_state="$(cat "$GH_FIXTURES/pr-state-$pr_number")"
    fi
    jq -cn --arg head "$(cat "$GH_FIXTURES/head")" --arg state "$pr_state" \
        '{headRefOid:$head,state:$state}'
    exit 0
fi

[ "${1:-}" = api ] || exit 90
shift
endpoint=
for arg in "$@"; do
    case "$arg" in --paginate | --slurp) ;; *) endpoint=$arg ;; esac
done
[ -n "$endpoint" ] || exit 91

if [ -f "$GH_FIXTURES/fail-endpoint" ] &&
    grep -Fq "$(cat "$GH_FIXTURES/fail-endpoint")" <<<"$endpoint"; then
    exit 92
fi
if [ -f "$GH_FIXTURES/slow-endpoint" ] &&
    grep -Fq "$(cat "$GH_FIXTURES/slow-endpoint")" <<<"$endpoint"; then
    sleep 5
fi

case "$endpoint" in
users/*) file=actor.json ;;
*/reactions?per_page=100) file=reactions.pages.json ;;
repos/*/issues/comments/*) file=trigger.json ;;
repos/*/issues/*/comments?per_page=100) file=comments.pages.json ;;
repos/*/pulls/*/reviews?per_page=100) file=reviews.pages.json ;;
repos/*/pulls/*/comments?per_page=100) file=inline.pages.json ;;
repos/*/commits/*)
    jq -cn --arg sha "$(cat "$GH_FIXTURES/resolved-head")" '{sha:$sha}'
    exit 0
    ;;
*) exit 93 ;;
esac
cat "$GH_FIXTURES/$file"
STUB
chmod +x "${bin_dir}/gh"

export PATH="${bin_dir}:$PATH"
export GH_FIXTURES="$fixtures"
export GH_LOG="$log"

head_sha="$(git rev-parse HEAD)"
actor_id=199175422
actor_login='chatgpt-codex-connector[bot]'
request_time='2026-07-31T08:00:00Z'
trigger_id=123

write_defaults() {
    printf '%s\n' "$head_sha" >"${fixtures}/head"
    printf '%s\n' "$head_sha" >"${fixtures}/resolved-head"
    jq -cn \
        --argjson id "$actor_id" \
        --arg login "$actor_login" \
        '{id:$id,login:$login,type:"Bot"}' >"${fixtures}/actor.json"
    jq -cn \
        --argjson id "$trigger_id" \
        --arg created "$request_time" \
        '{
          id:$id,body:"@codex review",created_at:$created,
          issue_url:"https://api.github.com/repos/example/repo/issues/493"
        }' >"${fixtures}/trigger.json"
    printf '%s\n' '[[]]' >"${fixtures}/reactions.pages.json"
    printf '%s\n' '[[]]' >"${fixtures}/comments.pages.json"
    printf '%s\n' '[[]]' >"${fixtures}/reviews.pages.json"
    printf '%s\n' '[[]]' >"${fixtures}/inline.pages.json"
    rm -f "${fixtures}/fail-endpoint"
    rm -f "${fixtures}/slow-endpoint"
    rm -f "${fixtures}"/pr-state-* "${fixtures}"/fail-pr-*
    rm -f "${fixtures}/slow-pr"
    : >"$log"
}

new_cycle() {
    write_defaults
    rm -f "$state"
    "$helper" reserve \
        --state "$state" --repo example/repo --pr 493 \
        --head "$head_sha" --attempt 1 >/dev/null
    jq --arg reserved "$request_time" '.reserved_at = $reserved' \
        "$state" >"${state}.next"
    mv "${state}.next" "$state"
    "$helper" attach --state "$state" --trigger-id "$trigger_id" >/dev/null
}

run_check() {
    set +e
    check_out="$("$helper" check \
        --state "$state" --actor-id "$actor_id" \
        --actor-login "$actor_login" --timeout-min 15 \
        --now "$1" 2>&1)"
    check_rc=$?
    set -e
}

assert_status() {
    expected_rc=$1
    expected_status=$2
    [ "$check_rc" -eq "$expected_rc" ] ||
        fail "expected rc $expected_rc, got $check_rc: $check_out"
    actual="$(printf '%s' "$check_out" | jq -r '.status' 2>/dev/null || true)"
    [ "$actual" = "$expected_status" ] ||
        fail "expected status $expected_status, got '$actual': $check_out"
}

echo "==> exact-trigger current-request +1 is clean"
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    '[[
      {
        user:{id:$id,login:$login,type:"User"},
        content:"+1",created_at:"2026-07-31T08:00:00Z"
      }
    ]]' >"${fixtures}/reactions.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 0 clean

echo "==> stale +1 and PR-level reactions cannot satisfy the cycle"
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    '[[
      {
        user:{id:$id,login:$login},
        content:"+1",created_at:"2026-07-31T07:59:59Z"
      }
    ]]' >"${fixtures}/reactions.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 11 pending
if grep -Fq 'issues/493/reactions' "$log"; then
    fail "classifier queried PR-level reactions"
fi

echo "==> paginated current-head clean top-level comment is clean"
new_cycle
prefix="${head_sha:0:10}"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg prefix "$prefix" \
    '[[],[
      {
        id:77,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:02Z",
        body:("Codex Review: Didn\u0027t find any major issues.\n\n**Reviewed commit:** `" + $prefix + "`")
      }
    ]]' >"${fixtures}/comments.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 0 clean

# Codex does not emit the bare sentence — it appends a praise clause, and the
# clause varies. "Keep it up!" (#239), "Nice work!" (#225) and "Chef's kiss."
# (#239, a later run) are all verbatim from this repo's own history. The
# fixture above uses the bare form, so on its own it pinned a phrasing Codex
# has never actually produced: the classifier compared for equality, every real
# clean verdict fell through to "findings", and the cloud gate could not go
# green for any PR.
#
# Every clause below was observed in the wild, and together they show why no
# list and no pattern could have held: they run from a bare emoji shortcode
# (":+1:") to a 41-character sentence, and three of the eight turned up inside
# twenty-five minutes.
#
# They are pinned as regression fixtures, NOT as an allowlist. The classifier
# consults neither a list nor a shape — it does not read the tail at all — so a
# clause absent from here passes just the same. What these guard is that the
# tail stays out of the decision.
for suffix in "Keep it up!" "Nice work!" "Chef's kiss." "Bravo." "Swish!" \
    "You're on a roll." ":+1:" "Already looking forward to the next diff."; do
    echo "==> a clean verdict with the trailing '${suffix}' is still clean"
    new_cycle
    prefix="${head_sha:0:10}"
    jq -cn \
        --argjson id "$actor_id" \
        --arg login "$actor_login" \
        --arg prefix "$prefix" \
        --arg suffix "$suffix" \
        '[[],[
      {
        id:78,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:02Z",
        body:("Codex Review: Didn\u0027t find any major issues. " + $suffix +
          "\n\n**Reviewed commit:** `" + $prefix + "`")
      }
    ]]' >"${fixtures}/comments.pages.json"
    run_check '2026-07-31T08:01:00Z'
    assert_status 0 clean
done

# An UNOBSERVED clause is clean. That is the point of the change: the allowlist
# could not converge — eight clauses, three of them inside twenty-five minutes —
# so every unlisted one was a false blocker on a clean review, and one
# deadlocked the very PR that was fixing it.
echo "==> an UNOBSERVED trailing clause is clean"
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:104,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:"Codex Review: Didn\u0027t find any major issues. Great job everyone!"
      }
    ]]' >"${fixtures}/reviews.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 0 clean

# The tail is NOT consulted. Everything above the "Reviewed commit" line after
# the verdict sentence is stripped, so no corpus of caveat phrasings belongs
# here any more — three revisions of that corpus each passed while the
# classifier they guarded was fail-open, which is what retired the approach.
#
# What replaces it is the ACCEPTED RESIDUAL, pinned deliberately below so it is
# visible rather than discovered: an unbadged concern appended to the verdict
# sentence classifies clean. That is the known cost of not parsing the tail.
echo "==> ACCEPTED RESIDUAL: an unbadged concern on the verdict line is clean"
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:104,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:"Codex Review: Didn\u0027t find any major issues. But a race remains."
      }
    ]]' >"${fixtures}/reviews.pages.json"
run_check '2026-07-31T08:01:00Z'
# Deliberate. Codex has never posted an unbadged concern — every finding it has
# made in this repo carried a P0/P1/P2 badge — and this would require it to
# contradict itself inside one sentence. The gate promotes a draft to
# ready-for-review rather than merging, so a human still reads the PR.
# If this ever fires in the wild, do NOT resume parsing the clause: raise it
# with the maintainer, because the assumption behind the design has broken.
assert_status 0 clean

# A concern on its OWN line is still caught, by the boilerplate rule — the tail
# exemption is confined to the verdict line and does not extend down the body.
echo "==> a concern on its own line is still indeterminate"
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:104,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:"Codex Review: Didn\u0027t find any major issues.\n\nBut a race remains.\n\n**Reviewed commit:** `abc1234`"
      }
    ]]' >"${fixtures}/reviews.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 2 indeterminate

echo "==> a clean-shaped review body with a praise clause is clean"
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:101,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:"Codex Review: Didn\u0027t find any major issues. Keep it up!"
      }
    ]]' >"${fixtures}/reviews.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 0 clean

# A severity marker anywhere in the body is a finding outright, whatever the
# verdict line says. This is the protection that still covers the verdict
# line's own tail: the classifier does not parse that tail, so a badge is what
# catches a finding parked there. An UNBADGED qualifier on that line is the
# residual documented above `verdict_class` and tracked as evanharmon1/harmon-devkit#285.
for tail in "P1: the retry path is unguarded" "P0: data loss on rollback"; do
    echo "==> a verdict line carrying '${tail}' is a finding"
    new_cycle
    jq -cn \
        --argjson id "$actor_id" \
        --arg login "$actor_login" \
        --arg head "$head_sha" \
        --arg tail "$tail" \
        '[[
      {
        id:103,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:("Codex Review: Didn\u0027t find any major issues. " + $tail)
      }
    ]]' >"${fixtures}/reviews.pages.json"
    run_check '2026-07-31T08:01:00Z'
    assert_status 10 findings
done

# The "trailing clause that does not read as praise" corpus that used to live
# here — "However a race remains", "See item 3", "However, 2 concerns:" — is
# gone with the parser it guarded. All of those now classify clean, which is
# the same accepted residual pinned above, and repeating it per phrasing would
# only imply the tail is being inspected when it is not.
#
# The protections that do NOT depend on the tail are exercised above and below:
# a P0/P1/P2 badge anywhere in the body, a non-clean verdict sentence, any
# non-boilerplate line, and inline comments on the current head.

echo "==> a concern parked on a LATER line is not clean"
# The verdict line can read perfectly clean while a warning sits further down,
# where no badge marks it. Only the first line was ever constrained, so nothing
# else would catch this.
new_cycle
prefix="${head_sha:0:10}"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg prefix "$prefix" \
    '[[],[
      {
        id:106,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:02Z",
        body:("Codex Review: Didn\u0027t find any major issues. Keep it up!\n\n" +
          "However a race remains.\n\n**Reviewed commit:** `" + $prefix + "`")
      }
    ]]' >"${fixtures}/comments.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 2 indeterminate

echo "==> a concern appended AFTER the About block is not clean"
# Cutting the body at the first "<details" validates only what precedes it, so
# anything after the closing tag was invisible.
new_cycle
prefix="${head_sha:0:10}"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg prefix "$prefix" \
    '[[],[
      {
        id:108,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:02Z",
        body:("Codex Review: Didn\u0027t find any major issues. Keep it up!\n\n" +
          "**Reviewed commit:** `" + $prefix + "`\n\n" +
          "<details> <summary>About Codex in GitHub</summary>\nblah\n</details>\n\n" +
          "However a race remains.")
      }
    ]]' >"${fixtures}/comments.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 2 indeterminate

echo "==> a concern appended to the Reviewed commit LINE is not clean"
# startswith on the label accepted trailing text — the same hole the verdict
# line had, one line lower.
new_cycle
prefix="${head_sha:0:10}"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg prefix "$prefix" \
    '[[],[
      {
        id:110,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:02Z",
        body:("Codex Review: Didn\u0027t find any major issues. Keep it up!\n\n" +
          "**Reviewed commit:** `" + $prefix + "` However a race remains.")
      }
    ]]' >"${fixtures}/comments.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 2 indeterminate

echo "==> a concern hidden in a NON-About collapsed block is not clean"
# Removal is anchored on the summary, so an arbitrary <details> is not a
# hiding place.
new_cycle
prefix="${head_sha:0:10}"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg prefix "$prefix" \
    '[[],[
      {
        id:111,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:02Z",
        body:("Codex Review: Didn\u0027t find any major issues. Keep it up!\n\n" +
          "**Reviewed commit:** `" + $prefix + "`\n\n" +
          "<details><summary>Notes</summary>\nHowever a race remains.\n</details>")
      }
    ]]' >"${fixtures}/comments.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 2 indeterminate

echo "==> an unterminated About block fails closed"
new_cycle
prefix="${head_sha:0:10}"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg prefix "$prefix" \
    '[[],[
      {
        id:109,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:02Z",
        body:("Codex Review: Didn\u0027t find any major issues. Keep it up!\n\n" +
          "**Reviewed commit:** `" + $prefix + "`\n\n" +
          "<details> never closed\nHowever a race remains.")
      }
    ]]' >"${fixtures}/comments.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 2 indeterminate

echo "==> the real clean layout — verdict, Reviewed commit, About block — is clean"
new_cycle
prefix="${head_sha:0:10}"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg prefix "$prefix" \
    '[[],[
      {
        id:107,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:02Z",
        body:("Codex Review: Didn\u0027t find any major issues. Keep it up!\n\n" +
          "**Reviewed commit:** `" + $prefix + "`\n\n" +
          "<details> <summary>About Codex in GitHub</summary>\n" +
          "Reviews are triggered when you open a pull request.\n</details>")
      }
    ]]' >"${fixtures}/comments.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 0 clean

echo "==> a finding whose body merely CONTAINS the verdict is still a finding"
# The guard on prefix matching: the sentence has to START the line. Without
# this, relaxing equality to a prefix could be relaxed further by accident.
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:102,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:"Unlike the clean case, Codex Review: Didn\u0027t find any major issues. is quoted here as P1 evidence."
      }
    ]]' >"${fixtures}/reviews.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> exact-head evidence remains valid after local state loss"
new_cycle
prefix="${head_sha:0:10}"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg prefix "$prefix" \
    '[[
      {
        id:76,user:{id:$id,login:$login},
        created_at:"2026-07-31T07:00:00Z",
        body:("Codex Review: Didn\u0027t find any major issues.\n\n**Reviewed commit:** `" +
          $prefix + "`")
      }
    ]]' >"${fixtures}/comments.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 0 clean

echo "==> paginated current-head inline comment is a finding"
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[],[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$head,
        body:"P1: confirmed issue"
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> a remapped previous-head inline comment stays stale"
new_cycle
previous_head="$(git rev-parse HEAD^)"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    --arg previous "$previous_head" \
    '[[
      {
        id:89,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$previous,
        body:"P1: fixed on a previous head"
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 11 pending

echo "==> current-head review with findings remains non-clean"
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:99,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,body:"Automated review suggestions"
      }
    ]]' >"${fixtures}/reviews.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> a finding that quotes clean-result text remains a finding"
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:100,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:"P1: code can emit Codex Review: Didn\u0027t find any major issues."
      }
    ]]' >"${fixtures}/reviews.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> incomplete attempt retries once, then escalates"
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    '[[
      {
        user:{id:$id,login:$login},
        content:"eyes",created_at:"2026-07-31T08:00:01Z"
      }
    ]]' >"${fixtures}/reactions.pages.json"
run_check '2026-07-31T08:16:00Z'
assert_status 12 retry

echo "==> attempt 2 cannot be reserved before attempt 1 expires"
request_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
new_cycle
set +e
early_retry_out="$("$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 2 2>&1)"
early_retry_rc=$?
set -e
[ "$early_retry_rc" -eq 2 ] ||
    fail "early attempt-2 reservation should fail closed: $early_retry_out"

trigger_id=124
request_time='2026-07-31T08:16:01Z'
new_cycle
jq -cn \
    --argjson id "$trigger_id" \
    --arg created "$request_time" \
    '{
      id:$id,body:"@codex review",created_at:$created,
      issue_url:"https://api.github.com/repos/example/repo/issues/493"
    }' >"${fixtures}/trigger.json"
"$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 2 >/dev/null
jq --arg reserved "$request_time" '.reserved_at = $reserved' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
"$helper" attach --state "$state" --trigger-id "$trigger_id" >/dev/null
printf '%s\n' '[[]]' >"${fixtures}/reactions.pages.json"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:78,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:10:00Z",
        body:("P1: late attempt-one finding\n\n**Reviewed commit:** `" +
          ($head[0:10]) + "`")
      }
    ]]' >"${fixtures}/comments.pages.json"
run_check '2026-07-31T08:17:00Z'
assert_status 10 findings
printf '%s\n' '[[]]' >"${fixtures}/comments.pages.json"
run_check '2026-07-31T08:32:01Z'
assert_status 13 escalate

echo "==> attached head refuses uncontrolled duplicate reservation"
set +e
duplicate_out="$("$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 2 2>&1)"
duplicate_rc=$?
set -e
[ "$duplicate_rc" -eq 2 ] ||
    fail "duplicate reservation should fail closed: $duplicate_out"

echo "==> reserved head refuses an ambiguous resumed write"
new_cycle
jq '.phase = "reserved" | .trigger_comment_id = null | .requested_at = null' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
set +e
reserved_out="$("$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 1 2>&1)"
reserved_rc=$?
set -e
[ "$reserved_rc" -eq 2 ] ||
    fail "ambiguous reserved attempt should fail closed: $reserved_out"

echo "==> a head change cannot overwrite an unresolved reservation"
old_recorded_head="$(jq -r '.head' "$state")"
new_live_head="$(printf '%040d' 0)"
printf '%s\n' "$new_live_head" >"${fixtures}/head"
set +e
changed_reserve_out="$("$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$new_live_head" --attempt 1 2>&1)"
changed_reserve_rc=$?
set -e
[ "$changed_reserve_rc" -eq 2 ] ||
    fail "head-change reservation should fail closed: $changed_reserve_out"
[ "$(jq -r '.head' "$state")" = "$old_recorded_head" ] ||
    fail "head-change reservation overwrote unresolved state"

echo "==> server clock skew does not reject the exact trigger"
trigger_id=123
request_time='2026-07-31T08:00:00Z'
write_defaults
rm -f "$state"
"$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 1 >/dev/null
jq '.reserved_at = "2026-07-31T08:01:01Z"' "$state" >"${state}.next"
mv "${state}.next" "$state"
"$helper" attach \
    --state "$state" --trigger-id "$trigger_id" >/dev/null
[ "$(jq -r '.trigger_comment_id' "$state")" = "$trigger_id" ] ||
    fail "clock-skewed exact trigger was not attached"

echo "==> pending window uses the local reservation clock"
request_time='2026-07-31T08:01:01Z'
write_defaults
rm -f "$state"
"$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 1 >/dev/null
jq '.reserved_at = "2026-07-31T08:00:00Z"' "$state" >"${state}.next"
mv "${state}.next" "$state"
"$helper" attach --state "$state" --trigger-id "$trigger_id" >/dev/null
run_check '2026-07-31T08:00:01Z'
assert_status 11 pending

echo "==> an existing state lock serializes reservations"
write_defaults
rm -f "$state"
mkdir "${state}.lock"
set +e
locked_out="$("$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 1 2>&1)"
locked_rc=$?
set -e
rmdir "${state}.lock"
[ "$locked_rc" -eq 2 ] ||
    fail "locked reservation should fail closed: $locked_out"

echo "==> state lock serializes checks with reservations"
new_cycle
mkdir "${state}.lock"
set +e
locked_check_out="$("$helper" check \
    --state "$state" --actor-id "$actor_id" \
    --actor-login "$actor_login" --timeout-min 15 \
    --now '2026-07-31T08:01:00Z' 2>&1)"
locked_check_rc=$?
set -e
rmdir "${state}.lock"
[ "$locked_check_rc" -eq 2 ] ||
    fail "locked check should fail closed: $locked_check_out"

echo "==> transient API failure stays within the attempt budget"
trigger_id=123
request_time='2026-07-31T08:00:00Z'
new_cycle
printf '%s\n' '/reviews' >"${fixtures}/fail-endpoint"
run_check '2026-07-31T08:01:00Z'
assert_status 11 pending
run_check '2026-07-31T08:16:00Z'
assert_status 12 retry

echo "==> a stalled GitHub call is bounded by the attempt deadline"
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    '[[
      {
        user:{id:$id,login:$login},
        content:"+1",created_at:"2026-07-31T08:00:01Z"
      }
    ]]' >"${fixtures}/reactions.pages.json"
printf '%s\n' '/reviews' >"${fixtures}/slow-endpoint"
start_seconds=$SECONDS
run_check '2026-07-31T08:01:00Z'
elapsed_seconds=$((SECONDS - start_seconds))
assert_status 11 pending
[ "$elapsed_seconds" -lt 4 ] ||
    fail "stalled descendant outlived the call deadline (${elapsed_seconds}s)"

echo "==> API budget uses the local reservation clock"
new_cycle
local_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
jq --arg reserved "$local_time" '.reserved_at = $reserved' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
printf '%s\n' '/reviews' >"${fixtures}/slow-endpoint"
start_seconds=$SECONDS
run_check "$local_time"
elapsed_seconds=$((SECONDS - start_seconds))
assert_status 11 pending
[ "$elapsed_seconds" -ge 4 ] ||
    fail "GitHub time incorrectly shortened the local API budget (${elapsed_seconds}s)"
[ "$elapsed_seconds" -lt 15 ] ||
    fail "slow API fixture exceeded its expected budget (${elapsed_seconds}s)"

echo "==> unexpected actor identity is indeterminate"
new_cycle
jq -cn \
    --arg login "$actor_login" \
    '[[
      {
        user:{id:999,login:$login},
        content:"+1",created_at:"2026-07-31T08:00:01Z"
      }
    ]]' >"${fixtures}/reactions.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 2 indeterminate

echo "==> malformed paginated evidence is indeterminate"
new_cycle
printf '%s\n' '{"not":"pages"}' >"${fixtures}/comments.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 2 indeterminate

echo "==> changed head invalidates all evidence"
new_cycle
printf '%040d\n' 0 >"${fixtures}/head"
run_check '2026-07-31T08:01:00Z'
assert_status 2 head-changed

echo "==> a delayed previous-head Reviewed commit is ignored"
new_cycle
old_head="$(git rev-parse HEAD^)"
bad_prefix="${old_head:0:10}"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg prefix "$bad_prefix" \
    '[[
      {
        id:101,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:02Z",
        body:("Codex Review: no major issues\n\n**Reviewed commit:** `" + $prefix + "`")
      }
    ]]' >"${fixtures}/comments.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 11 pending

echo "==> an unresolvable clearly stale Reviewed commit prefix is ignored"
new_cycle
bad_prefix=deadbeef00
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg prefix "$bad_prefix" \
    '[[
      {
        id:102,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:02Z",
        body:("Codex Review: no major issues\n\n**Reviewed commit:** `" + $prefix + "`")
      }
    ]]' >"${fixtures}/comments.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 11 pending

echo "==> GitHub must resolve a matching prefix to the current head"
new_cycle
prefix="${head_sha:0:10}"
old_head="$(git rev-parse HEAD^)"
printf '%s\n' "$old_head" >"${fixtures}/resolved-head"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg prefix "$prefix" \
    '[[
      {
        id:103,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:02Z",
        body:("Codex Review: Didn\u0027t find any major issues.\n\n**Reviewed commit:** `" +
          $prefix + "`")
      }
    ]]' >"${fixtures}/comments.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 2 indeterminate

# ── reap: the other half of the state lifecycle ────────────────────────────
#
# `reserve` is the only thing that creates state and, until `reap`, nothing
# removed it. A shepherded PR is still open when its session stops, so a cycle
# can never reap its own state — every case below is therefore a LATER sweep
# observing a PR that has since closed, which is the only way state is ever
# collected.

reap_root="${test_tmp}/reap-root"
reap_out=

seed_state() {
    seed_slug=$1
    seed_pr=$2
    rm -f "${fixtures}/pr-state-${seed_pr}" "${fixtures}/fail-pr-${seed_pr}"
    "$helper" reserve \
        --state "${reap_root}/${seed_slug}/${seed_pr}.json" \
        --repo "$seed_slug" --pr "$seed_pr" \
        --head "$head_sha" --attempt 1 >/dev/null
}

run_reap() {
    reap_target=$1
    shift
    set +e
    reap_out="$("$helper" reap --root "$reap_target" "$@" 2>&1)"
    reap_rc=$?
    set -e
}

assert_reap() {
    reap_actual="$(printf '%s' "$reap_out" | jq -r "$1" 2>/dev/null || true)"
    [ "$reap_actual" = "$2" ] ||
        fail "reap: expected ($1) = '$2', got '$reap_actual': $reap_out"
}

echo "==> reap collects merged and closed PRs and keeps open ones"
write_defaults
rm -rf "$reap_root"
seed_state example/alpha 11
seed_state example/beta 22
seed_state example/gamma 33
printf '%s\n' MERGED >"${fixtures}/pr-state-11"
printf '%s\n' CLOSED >"${fixtures}/pr-state-22"
run_reap "$reap_root"
[ "$reap_rc" -eq 0 ] || fail "reap exited $reap_rc: $reap_out"
assert_reap '.status' swept
assert_reap '.scanned' 3
assert_reap '.reaped' 2
assert_reap '.kept' 1
assert_reap '.skipped' 0
[ ! -f "${reap_root}/example/alpha/11.json" ] || fail "merged state survived"
[ ! -f "${reap_root}/example/beta/22.json" ] || fail "closed state survived"
[ -f "${reap_root}/example/gamma/33.json" ] || fail "open state was reaped"
assert_reap '[.entries[] | select(.pr == 33) | .action] | first' kept
[ ! -d "${reap_root}/example/alpha" ] ||
    fail "an emptied state directory was left behind"

echo "==> an unreadable PR state keeps its file rather than deleting it"
write_defaults
rm -rf "$reap_root"
seed_state example/alpha 11
: >"${fixtures}/fail-pr-11"
run_reap "$reap_root"
[ "$reap_rc" -eq 0 ] || fail "reap exited $reap_rc: $reap_out"
assert_reap '.reaped' 0
assert_reap '.kept' 1
assert_reap '[.entries[] | .detail] | first' "PR state is unreadable"
[ -f "${reap_root}/example/alpha/11.json" ] ||
    fail "unreadable PR state was deleted — it must be kept"

echo "==> an unrecognized PR state keeps its file"
write_defaults
rm -rf "$reap_root"
seed_state example/alpha 11
printf '%s\n' WITHDRAWN >"${fixtures}/pr-state-11"
run_reap "$reap_root"
assert_reap '.reaped' 0
assert_reap '.kept' 1
[ -f "${reap_root}/example/alpha/11.json" ] ||
    fail "an unrecognized PR state was treated as closed"

echo "==> a file reap cannot identify is skipped, never deleted"
write_defaults
rm -rf "$reap_root"
mkdir -p "${reap_root}/example/alpha"
printf '%s\n' 'not json at all' >"${reap_root}/example/alpha/11.json"
run_reap "$reap_root"
[ "$reap_rc" -eq 0 ] || fail "reap exited $reap_rc: $reap_out"
assert_reap '.skipped' 1
assert_reap '.reaped' 0
[ -f "${reap_root}/example/alpha/11.json" ] ||
    fail "an unidentifiable file was deleted"
if grep -Fq 'pr view' "$log"; then
    fail "reap queried GitHub for a file it could not identify"
fi

echo "==> state whose contents disagree with its path is skipped"
write_defaults
rm -rf "$reap_root"
seed_state example/alpha 11
printf '%s\n' MERGED >"${fixtures}/pr-state-11"
mkdir -p "${reap_root}/example/impostor"
mv "${reap_root}/example/alpha/11.json" "${reap_root}/example/impostor/11.json"
run_reap "$reap_root"
assert_reap '.skipped' 1
assert_reap '.reaped' 0
[ -f "${reap_root}/example/impostor/11.json" ] ||
    fail "a relocated state file was deleted on the strength of its contents"

echo "==> state naming a malformed repo is skipped without querying GitHub"
write_defaults
rm -rf "$reap_root"
seed_state example/alpha 11
# Schema-valid — .repo is still a string — but not a repository slug. The
# schema check cannot catch this, and both fields become `gh` arguments.
jq '.repo = "not-a-slug"' "${reap_root}/example/alpha/11.json" \
    >"${reap_root}/example/alpha/11.json.next"
mv "${reap_root}/example/alpha/11.json.next" "${reap_root}/example/alpha/11.json"
: >"$log"
run_reap "$reap_root"
[ "$reap_rc" -eq 0 ] || fail "reap exited $reap_rc: $reap_out"
assert_reap '.skipped' 1
assert_reap '.reaped' 0
[ -f "${reap_root}/example/alpha/11.json" ] || fail "a malformed slug was deleted"
if grep -Fq 'pr view' "$log"; then
    fail "reap queried GitHub with a malformed repository slug"
fi

echo "==> a locked state file is skipped and does not abort the sweep"
write_defaults
rm -rf "$reap_root"
seed_state example/alpha 11
seed_state example/beta 22
printf '%s\n' MERGED >"${fixtures}/pr-state-11"
printf '%s\n' MERGED >"${fixtures}/pr-state-22"
mkdir "${reap_root}/example/alpha/11.json.lock"
run_reap "$reap_root"
[ "$reap_rc" -eq 0 ] || fail "a locked entry aborted the sweep: $reap_out"
assert_reap '.skipped' 1
assert_reap '.reaped' 1
[ -f "${reap_root}/example/alpha/11.json" ] ||
    fail "state locked by a live shepherd was deleted"
[ ! -f "${reap_root}/example/beta/22.json" ] ||
    fail "one locked entry stopped the rest of the sweep"

echo "==> non-state siblings are left alone"
write_defaults
rm -rf "$reap_root"
seed_state example/alpha 11
printf '%s\n' MERGED >"${fixtures}/pr-state-11"
printf '%s\n' 'leftover' >"${reap_root}/example/alpha/11.json.tmp.abcdef"
run_reap "$reap_root"
assert_reap '.scanned' 1
assert_reap '.reaped' 1
[ -f "${reap_root}/example/alpha/11.json.tmp.abcdef" ] ||
    fail "reap deleted a file outside the layout reserve writes"

echo "==> a stalled sweep is bounded and keeps what it never examined"
write_defaults
rm -rf "$reap_root"
seed_state example/alpha 11
seed_state example/beta 22
printf '%s\n' MERGED >"${fixtures}/pr-state-11"
printf '%s\n' MERGED >"${fixtures}/pr-state-22"
# Every pr view now stalls past the whole-sweep budget. Reaping runs ahead of
# the work that matters, so it must give up rather than spend one timeout per
# entry — and giving up means KEEPING, never deleting on an answer it lacks.
: >"${fixtures}/slow-pr"
reap_started="$(date -u '+%s')"
run_reap "$reap_root" --budget-sec 1
reap_elapsed=$(($(date -u '+%s') - reap_started))
[ "$reap_rc" -eq 0 ] || fail "a stalled sweep exited $reap_rc: $reap_out"
assert_reap '.scanned' 2
assert_reap '.reaped' 0
assert_reap '.kept' 2
[ -f "${reap_root}/example/alpha/11.json" ] || fail "a stalled sweep deleted state"
[ -f "${reap_root}/example/beta/22.json" ] || fail "a stalled sweep deleted state"
# Two entries x the flat 60s per-call timeout is the unbounded behaviour; the
# budget has to hold this well under even one of them.
[ "$reap_elapsed" -lt 30 ] ||
    fail "sweep ran ${reap_elapsed}s — the budget did not bound it"
printf '%s' "$reap_out" | jq -e \
    '[.entries[] | select(.detail | test("budget exhausted"))] | length >= 1' \
    >/dev/null || fail "no entry reported the exhausted budget: $reap_out"

echo "==> reap rejects a non-numeric budget"
set +e
"$helper" reap --root "$reap_root" --budget-sec zero >/dev/null 2>&1
reap_rc=$?
set -e
[ "$reap_rc" -eq 2 ] || fail "a bad budget should exit 2, got $reap_rc"

echo "==> a checkout that has never shepherded sweeps cleanly"
write_defaults
run_reap "${test_tmp}/never-shepherded"
[ "$reap_rc" -eq 0 ] || fail "a missing state root is not a failure"
assert_reap '.scanned' 0
assert_reap '.reaped' 0

echo "==> reap requires a root"
set +e
"$helper" reap >/dev/null 2>&1
reap_rc=$?
set -e
[ "$reap_rc" -eq 2 ] || fail "reap without --root should exit 2, got $reap_rc"

echo "shepherd Codex cloud-review classifier: PASS"
