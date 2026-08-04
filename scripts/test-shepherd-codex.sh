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
    jq -cn --arg head "$(cat "$GH_FIXTURES/head")" \
        '{headRefOid:$head,state:"OPEN"}'
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
# clause varies. "Keep it up!" (#239), "Nice work!" (#225), "Chef's kiss."
# (#239, a later run), "Bravo." (#268) and "Swish!" (#269) are all verbatim
# from this repo's own history.
#
# Note the rate. "Bravo." and "Swish!" were both first observed within twenty
# minutes of each other, on consecutive PRs, which is not the shape of a small
# fixed vocabulary being enumerated — it reads as a clause sampled per review.
# If that holds, this list cannot converge and every unlisted clause costs a
# shepherd escalation. Do NOT respond by loosening the match; the reason for
# equality is in the helper and still stands. The alternative worth costing out
# is dropping the praise test entirely and resting the clean verdict on the
# signals that are already checked and not free-text: the opening sentence, the
# absence of any P0/P1/P2 marker, and the requirement that every remaining line
# be Codex's own boilerplate. That is a design change, not a list edit, so it
# wants its own issue and its own argument — weigh it before adding a sixth
# string here.
# The
# fixture above uses the bare form, so on its own it pinned a phrasing Codex
# has never actually produced: the classifier compared for equality, every real
# clean verdict fell through to "findings", and the cloud gate could not go
# green for any PR.
#
# "Chef's kiss." is why the accepted shape is not just a short exclamation —
# it carries an apostrophe and ends in a full stop. Pin the shapes that occur.
for suffix in "Keep it up!" "Nice work!" "Chef's kiss." "Bravo." "Swish!"; do
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

echo "==> an UNOBSERVED praise phrasing escalates rather than passing"
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
# Deliberately NOT clean. No pattern over characters separates "Great job
# everyone!" from "but a race remains." — both are short and alphabetic — so
# the tail is matched against observed strings only, and anything else asks a
# human. Being unlisted costs one escalation; being wrong costs a false green.
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

# The trailing clause is recognised by PRAISE STRUCTURE, not merely screened
# for suspicious characters: a short all-alphabetic exclamation. A character
# blacklist (no colon, no digit) let "However a race remains" through — a
# qualifier that smuggles a finding onto the clean sentence's own line, which
# would promote a PR Codex actually flagged. Anything unrecognised fails
# closed into `findings`, costing an escalation rather than a false green.
# A severity marker anywhere in the body is a finding outright, whatever the
# verdict line says.
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

# Everything else that opens with the verdict but does not read as praise is
# INDETERMINATE, not `findings`. Reporting "Codex found something" about a
# verdict that says the opposite is a lie, and it is the lie that cost a clean
# PR its gate when the rule was a praise-shape whitelist. Escalating instead
# puts a human on the one case a pattern cannot settle — and it keeps a
# qualifier smuggled onto the verdict line from passing as clean.
for tail in "However a race remains" "However a race remains." \
    "but see the note below" "See item 3" "However, 2 concerns:" \
    "an unusually long and effusive compliment" \
    "but a race remains." "one concern."; do
    echo "==> a verdict line trailed by '${tail}' is indeterminate, not clean"
    new_cycle
    jq -cn \
        --argjson id "$actor_id" \
        --arg login "$actor_login" \
        --arg head "$head_sha" \
        --arg tail "$tail" \
        '[[
      {
        id:105,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:("Codex Review: Didn\u0027t find any major issues. " + $tail)
      }
    ]]' >"${fixtures}/reviews.pages.json"
    run_check '2026-07-31T08:01:00Z'
    assert_status 2 indeterminate
done

echo "==> a concern parked on a LATER line is not clean"
# The verdict line can be allowlisted praise while a warning sits further down,
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

echo "shepherd Codex cloud-review classifier: PASS"
