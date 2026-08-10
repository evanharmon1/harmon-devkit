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

# Resolve the REAL system timeout/gtimeout absolute paths before bin_dir
# (below) goes on PATH, so the timeout-args shim has something real to exec
# into instead of recursing into itself. Whichever of these exists is exactly
# what the helper's own `timeout_bin` resolution (same command -v probe,
# same two names) would have found on this machine — macOS ships only
# `gtimeout` (coreutils), Linux ships `timeout`.
real_timeout_bin="$(command -v timeout 2>/dev/null || true)"
real_gtimeout_bin="$(command -v gtimeout 2>/dev/null || true)"

# Watchdog for run_check/run_reap below (not a budget assertion — see those
# functions). Resolved the same way the helper itself resolves it, since the
# helper already requires GNU timeout to exist wherever this suite runs.
watchdog_bin=
if [ -n "$real_timeout_bin" ]; then
    watchdog_bin=timeout
elif [ -n "$real_gtimeout_bin" ]; then
    watchdog_bin=gtimeout
else
    fail "GNU timeout is required for the test suite's own hang watchdog (coreutils; gtimeout on macOS)"
fi
watchdog_sec=300

# A watchdog kill (rc 124, or 137 if -k's SIGKILL grace was needed) means the
# helper invocation itself never returned within a very generous window. That
# is a distinct failure mode from any budget/behavioral assertion below: it
# means the process is genuinely hung or the machine is pathologically
# starved, not that a case's expected values didn't match.
check_watchdog() {
    rc=$1
    label=$2
    output=$3
    [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] ||
        fail "$label: watchdog fired after ${watchdog_sec}s — genuinely hung or" \
            "pathologically starved, not a budget assertion: $output"
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
# The PR object, fetched only for its author identity when the head carries
# inline findings. It must sort AFTER the sub-resource patterns above, which it
# would otherwise shadow.
repos/*/pulls/*) file=pr.json ;;
repos/*/commits/*)
    jq -cn --arg sha "$(cat "$GH_FIXTURES/resolved-head")" '{sha:$sha}'
    exit 0
    ;;
*) exit 93 ;;
esac
cat "$GH_FIXTURES/$file"
STUB
chmod +x "${bin_dir}/gh"

# Timeout-args shim, same idiom as the `gh` stub above: intercept the binary
# on PATH, record what the caller invoked it with, then behave exactly like
# the real thing. This gives a couple of cases a deterministic, non-wall-clock
# way to observe the numeric budget the helper actually computed for a call
# (see the "recorded budget" assertions below), instead of inferring it from
# elapsed time.
#
# Shimmed by NAME, not by "whichever the helper would pick": the helper
# resolves `timeout_bin` with the identical command -v probe this harness just
# ran, so shimming every name that actually resolved to a real binary here
# reproduces the helper's own resolution exactly, on both platforms, without
# this harness needing to guess which one the helper will choose — a name
# that doesn't exist on this machine (e.g. `timeout` on a stock macOS) simply
# gets no shim and stays absent, matching the real environment. Each shim
# execs the one real absolute path resolved above (captured before bin_dir
# went on PATH), never a PATH-based lookup of its own name, so there is no
# risk of a shim invoking itself.
if [ -n "$real_timeout_bin" ]; then
    cat >"${bin_dir}/timeout" <<SHIM
#!/usr/bin/env bash
if [ -n "\${TIMEOUT_ARGS_LOG:-}" ]; then
    printf '%s\n' "\$*" >>"\$TIMEOUT_ARGS_LOG"
fi
exec "$real_timeout_bin" "\$@"
SHIM
    chmod +x "${bin_dir}/timeout"
fi
if [ -n "$real_gtimeout_bin" ]; then
    cat >"${bin_dir}/gtimeout" <<SHIM
#!/usr/bin/env bash
if [ -n "\${TIMEOUT_ARGS_LOG:-}" ]; then
    printf '%s\n' "\$*" >>"\$TIMEOUT_ARGS_LOG"
fi
exec "$real_gtimeout_bin" "\$@"
SHIM
    chmod +x "${bin_dir}/gtimeout"
fi

export PATH="${bin_dir}:$PATH"
export GH_FIXTURES="$fixtures"
export GH_LOG="$log"
# Where a recorded-budget assertion writes/reads if it opts in below by
# exporting TIMEOUT_ARGS_LOG=$timeout_args_log around its one run_check/
# run_reap call. Unexported and unset otherwise, so the shims above are a
# silent passthrough (no logging, no extra file I/O) for every other case in
# this suite — scoped to the couple of cases that are actually the point.
timeout_args_log="${test_tmp}/timeout-args.log"

head_sha="$(git rev-parse HEAD)"
actor_id=199175422
actor_login='chatgpt-codex-connector[bot]'
request_time='2026-07-31T08:00:00Z'
trigger_id=123
# The PR author, and a bystander who is neither the author nor an
# OWNER/MEMBER/COLLABORATOR — the two identities the adjudication partition
# has to tell apart.
pr_author_id=4242
# A repository OWNER who is NOT the PR author, so the association branch of the
# trust rule is pinned on its own rather than passing via the authorship
# fallback as well.
owner_id=6060
outsider_id=5150

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
    jq -cn --argjson author "$pr_author_id" --arg head "$head_sha" \
        '{number:493,user:{id:$author,login:"pr-author"},head:{sha:$head}}' \
        >"${fixtures}/pr.json"
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
    check_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$helper" check \
        --state "$state" --actor-id "$actor_id" \
        --actor-login "$actor_login" --timeout-min 15 \
        --now "$1" 2>&1)"
    check_rc=$?
    set -e
    check_watchdog "$check_rc" run_check "$check_out"
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

# ── adjudicated current-head findings (evanharmon1/harmon-devkit#275) ───────
#
# Counting current-head inline comments made the two-attempt contract
# unfinishable for a head carrying a declined P2: the settled finding
# re-blocked every later check until a new commit moved the head. The
# partition below is a strict relaxation — a finding is settled by a trusted
# in-thread reply, and by nothing else.

# The findings review that accompanies real inline findings. Codex posts both:
# a review body and the findings themselves as inline comments.
#
# The body is the REAL observed payload from evanharmon1/harmon-devkit#355 and
# #273, LEADING BLANK LINE INCLUDED: "\n### 💡 Codex Review\n\n…". That blank
# is load-bearing — a heading test anchored on the literal first line matches
# no genuine findings review at all, which makes the whole settlement path
# inert. A heading-first body is pinned separately below.
#
# Suppressing this review once its inline comments are adjudicated is the other
# half of the fix — without it the same settled findings block from the other
# side. So the body is CARRIER-ONLY: the heading, the boilerplate sentence
# observed on #355, and the Reviewed-commit metadata. It carries no severity
# badge, because the badges live on the inline comments it points at. A badged
# body, and an unbadged concern in the body, are each a finding attribution
# cannot reach; both are pinned separately below.
codex_findings_review() {
    jq -cn \
        --argjson id "$actor_id" \
        --arg login "$actor_login" \
        --arg head "$head_sha" \
        '[[
          {
            id:120,user:{id:$id,login:$login},
            submitted_at:"2026-07-31T08:00:04Z",
            commit_id:$head,
            body:("\n### \ud83d\udca1 Codex Review\n\nHere are some automated review suggestions for this pull request.\n\n**Reviewed commit:** `" + ($head[0:10]) + "`")
          }
        ]]' >"${fixtures}/reviews.pages.json"
}

echo "==> a trusted in-thread reply adjudicates a current-head inline finding"
# The replier is an OWNER who is NOT the PR author, so this pins the
# association branch of the trust rule by itself. The authorship branch is
# pinned separately by the CONTRIBUTOR case below.
new_cycle
codex_findings_review
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --argjson owner "$owner_id" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P2: consider hardening the retry path"
      },
      {
        id:89,user:{id:$owner,login:"repo-owner"},
        created_at:"2026-07-31T08:00:30Z",updated_at:"2026-07-31T08:00:30Z",
        author_association:"OWNER",in_reply_to_id:88,
        body:"Declined: the retry path is bounded by the attempt deadline."
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 0 clean
# The detail must distinguish this from a verdict Codex itself posted: only
# here did a human write the rationale that now stands on the PR.
printf '%s' "$check_out" | jq -e '.detail | test("adjudicated")' >/dev/null ||
    fail "adjudicated-clean did not report a distinct detail: $check_out"

echo "==> a reply trusted only by PR authorship adjudicates the finding"
# A shepherd driving a fork PR replies as the PR author with association
# CONTRIBUTOR. Refusing that would leave the contract unfinishable for exactly
# the sessions this helper exists to serve.
new_cycle
codex_findings_review
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --argjson author "$pr_author_id" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P2: consider hardening the retry path"
      },
      {
        id:89,user:{id:$author,login:"pr-author"},
        created_at:"2026-07-31T08:00:30Z",updated_at:"2026-07-31T08:00:30Z",
        author_association:"CONTRIBUTOR",in_reply_to_id:88,
        body:"Fixed in a follow-up commit on this branch."
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 0 clean
printf '%s' "$check_out" | jq -e '.detail | test("adjudicated")' >/dev/null ||
    fail "PR-author reply did not report adjudicated-clean: $check_out"

echo "==> an untrusted bystander reply does not adjudicate a finding"
new_cycle
codex_findings_review
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --argjson outsider "$outsider_id" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P1: confirmed issue"
      },
      {
        id:90,user:{id:$outsider,login:"passer-by"},
        created_at:"2026-07-31T08:00:30Z",updated_at:"2026-07-31T08:00:30Z",
        author_association:"NONE",in_reply_to_id:88,
        body:"Looks fine to me."
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> the bot cannot adjudicate its own finding"
new_cycle
codex_findings_review
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P1: confirmed issue"
      },
      {
        id:91,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:30Z",updated_at:"2026-07-31T08:00:30Z",
        author_association:"COLLABORATOR",in_reply_to_id:88,
        body:"Following up on my own comment."
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> a finding edited after its reply is unresolved again"
# Codex revises a finding in place, so a reply that predates the edit answered
# different text.
new_cycle
codex_findings_review
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --argjson author "$pr_author_id" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:45Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P1: revised — the retry path is unguarded on the second attempt"
      },
      {
        id:89,user:{id:$author,login:"pr-author"},
        created_at:"2026-07-31T08:00:30Z",updated_at:"2026-07-31T08:00:30Z",
        author_association:"OWNER",in_reply_to_id:88,
        body:"Declined: answered the pre-edit text."
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> a reply in the SAME second as the edit does not adjudicate"
# GitHub timestamps are second-precision, so a tie cannot prove the reply came
# after the edit — and resolving it in the reply's favour would adjudicate text
# the replier may never have seen.
new_cycle
codex_findings_review
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --argjson author "$pr_author_id" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:30Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P1: revised in the same second the reply landed"
      },
      {
        id:89,user:{id:$author,login:"pr-author"},
        created_at:"2026-07-31T08:00:30Z",updated_at:"2026-07-31T08:00:30Z",
        author_association:"OWNER",in_reply_to_id:88,
        body:"Declined: may have answered the pre-edit text."
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> one adjudicated finding does not settle its unanswered sibling"
new_cycle
codex_findings_review
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --argjson author "$pr_author_id" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P2: consider hardening the retry path"
      },
      {
        id:89,user:{id:$author,login:"pr-author"},
        created_at:"2026-07-31T08:00:30Z",updated_at:"2026-07-31T08:00:30Z",
        author_association:"OWNER",in_reply_to_id:88,
        body:"Declined: bounded by the attempt deadline."
      },
      {
        id:92,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:05Z",updated_at:"2026-07-31T08:00:05Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P1: data loss on rollback"
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> a findings review with no current-head inline comments still gates"
# Suppression is per review and requires at least one attributed current-head
# inline finding. A findings review standing alone has nothing attributed to
# it, so it keeps its old behaviour.
new_cycle
codex_findings_review
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> a second findings review is not settled by the first review's findings"
# The two-attempt contract makes two findings reviews on one head routine. When
# the second states its finding in the review BODY and has no inline comments
# of its own, a global "something was adjudicated" flag would suppress it too
# and report adjudicated-clean over an unanswered finding. Attribution by
# `pull_request_review_id` is what keeps them apart.
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:120,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:("\n### \ud83d\udca1 Codex Review\n\nHere are some automated review suggestions for this pull request.\n\n**Reviewed commit:** `" + ($head[0:10]) + "`")
      },
      {
        id:121,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:40Z",
        commit_id:$head,
        body:"### Codex Review\n\nP1: the second attempt still loses data on rollback."
      }
    ]]' >"${fixtures}/reviews.pages.json"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --argjson author "$pr_author_id" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P2: consider hardening the retry path"
      },
      {
        id:89,user:{id:$author,login:"pr-author"},
        created_at:"2026-07-31T08:00:30Z",updated_at:"2026-07-31T08:00:30Z",
        author_association:"OWNER",in_reply_to_id:88,
        body:"Declined: bounded by the attempt deadline."
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> a badged review body is not settled by its adjudicated inline findings"
# Codex states some findings in the review body itself, where attribution
# cannot reach them — there is no inline comment to reply to. Settling the
# review on the strength of its attributed comments would discard the badged
# one in silence. The test is the ABSENCE of a stable badge, not a reading of
# the prose.
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:120,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:"\n### \ud83d\udca1 Codex Review\n\nP1: the rollback path also loses data.\n\nMore in the inline comments."
      }
    ]]' >"${fixtures}/reviews.pages.json"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --argjson author "$pr_author_id" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P2: consider hardening the retry path"
      },
      {
        id:89,user:{id:$author,login:"pr-author"},
        created_at:"2026-07-31T08:00:30Z",updated_at:"2026-07-31T08:00:30Z",
        author_association:"OWNER",in_reply_to_id:88,
        body:"Declined: bounded by the attempt deadline."
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> an unbadged concern in a settled review's body survives adjudication"
# The badge test cannot see this one — an unbadged concern carries no marker —
# so the settled path also requires a CARRIER-ONLY body. Without that, the
# concern rides through on the strength of the adjudicated inline comment.
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:120,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:("\n### \ud83d\udca1 Codex Review\n\nHere are some automated review suggestions for this pull request.\n\nHowever, consider the race in the retry path.\n\n**Reviewed commit:** `" + ($head[0:10]) + "`")
      }
    ]]' >"${fixtures}/reviews.pages.json"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --argjson author "$pr_author_id" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P2: consider hardening the retry path"
      },
      {
        id:89,user:{id:$author,login:"pr-author"},
        created_at:"2026-07-31T08:00:30Z",updated_at:"2026-07-31T08:00:30Z",
        author_association:"OWNER",in_reply_to_id:88,
        body:"Declined: bounded by the attempt deadline."
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> a heading-first body with no leading blank still settles"
# Every other adjudication fixture runs the REAL shape through the shared
# helper: a leading blank line then "### 💡 Codex Review". This pins the other
# shape, so neither the leading-blank normalisation nor the loose heading match
# can be tightened into rejecting the plain heading Codex also emits.
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:120,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:("### Codex Review\n\nHere are some automated review suggestions for this pull request.\n\n**Reviewed commit:** `" + ($head[0:10]) + "`")
      }
    ]]' >"${fixtures}/reviews.pages.json"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --argjson author "$pr_author_id" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P2: consider hardening the retry path"
      },
      {
        id:89,user:{id:$author,login:"pr-author"},
        created_at:"2026-07-31T08:00:30Z",updated_at:"2026-07-31T08:00:30Z",
        author_association:"OWNER",in_reply_to_id:88,
        body:"Declined: bounded by the attempt deadline."
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 0 clean

echo "==> an adjudicated finding naming an unfetched review is indeterminate"
# The inline comment attributes itself to review 120, but no such current-head
# bot review came back from the reviews endpoint. The two endpoints disagree,
# which is neither "the finding is open" nor "the finding is settled".
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --argjson author "$pr_author_id" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P2: consider hardening the retry path"
      },
      {
        id:89,user:{id:$author,login:"pr-author"},
        created_at:"2026-07-31T08:00:30Z",updated_at:"2026-07-31T08:00:30Z",
        author_association:"OWNER",in_reply_to_id:88,
        body:"Declined: bounded by the attempt deadline."
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 2 indeterminate

echo "==> an inline finding attributed to no review settles nothing"
# Without a numeric `pull_request_review_id` the finding cannot be attributed,
# so it must not be counted toward any review's settlement.
new_cycle
codex_findings_review
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --argjson author "$pr_author_id" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$head,
        body:"P2: consider hardening the retry path"
      },
      {
        id:89,user:{id:$author,login:"pr-author"},
        created_at:"2026-07-31T08:00:30Z",updated_at:"2026-07-31T08:00:30Z",
        author_association:"OWNER",in_reply_to_id:88,
        body:"Declined: bounded by the attempt deadline."
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> a head that moved under the author fetch invalidates the snapshot"
# The author fetch lands after the evidence snapshot and after the head check
# that closes it, so its payload's own head.sha is the last chance to notice a
# push that arrived in between.
new_cycle
codex_findings_review
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --argjson author "$pr_author_id" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P2: consider hardening the retry path"
      },
      {
        id:89,user:{id:$author,login:"pr-author"},
        created_at:"2026-07-31T08:00:30Z",updated_at:"2026-07-31T08:00:30Z",
        author_association:"OWNER",in_reply_to_id:88,
        body:"Declined: bounded by the attempt deadline."
      }
    ]]' >"${fixtures}/inline.pages.json"
# `head` still reports the state head, so only the PR payload disagrees.
jq -cn --argjson author "$pr_author_id" --arg moved "$(git rev-parse HEAD^)" \
    '{number:493,user:{id:$author,login:"pr-author"},head:{sha:$moved}}' \
    >"${fixtures}/pr.json"
run_check '2026-07-31T08:01:00Z'
assert_status 2 head-changed

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
: >"$timeout_args_log"
export TIMEOUT_ARGS_LOG="$timeout_args_log"
run_check '2026-07-31T08:01:00Z'
unset TIMEOUT_ARGS_LOG
# No post-return wall-clock bound here — the status assertion below IS the
# regression signal, and it is a stronger one than timing ever was.
#
# This case's reservation clock ("2026-07-31") is far in the past relative to
# the machine's real clock, so the deadline math yields a deeply negative
# remaining budget and call_timeout collapses to ~1s: the /reviews sleep-5
# fixture is meant to be killed almost immediately. If that budget collapse
# regressed back to the flat 60s ceiling, the call would instead run to
# completion and return its (empty) reviews page with exit 0 — and
# `fetch_evidence` would fall through past the reviews fetch instead of
# hitting `bounded_wait "cannot fetch paginated PR reviews"`. With the
# reactions fixture above (`+1` from the actor at $head, created after the
# request), the walk would then reach the `exact_like` check and emit `clean`
# (exit 0), not `pending` (exit 11) — a regressed budget changes what this
# check *decides*, not just how long it takes to decide it. `assert_status 11
# pending` below already catches that flip, deterministically, at any speed.
#
# A wall-clock bound was here previously (widened 4s -> 20s in a prior pass
# to tolerate contention), but 20s was wide enough to let the very regression
# it existed to catch — the call completing the full 5s sleep instead of
# being killed at ~1s — pass silently (5s < 20s). Removing it loses nothing:
# the run's own hang protection is the watchdog wrapped around run_check
# itself (see its definition), which fires on a genuine hang regardless of
# which case triggered it.
assert_status 11 pending
# Second, independent regression signal for the exact same collapse, with no
# timing involved at all: the timeout-args shim (see harness setup), opted
# into above via TIMEOUT_ARGS_LOG, recorded every "-k N DURATION gh ..."
# invocation the helper actually made to $timeout_args_log before execing the
# real timeout unchanged. The reviews fetch's own recorded duration is the
# collapsed clamp itself — 1 — so a regression to the flat 60s ceiling (or any
# other value) changes a recorded number, deterministically, rather than
# something inferred from elapsed wall-clock.
reviews_budget="$(grep 'reviews?per_page=100' "$timeout_args_log" | awk '{print $3}')"
[ "$reviews_budget" = "1" ] ||
    fail "reviews fetch did not use the collapsed 1s clamp: '$reviews_budget' ($timeout_args_log: $(cat "$timeout_args_log"))"

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
# Behavioral signal, not timing: here the reservation clock is "now", so
# `remaining` stays large and call_timeout is the flat 60s ceiling — this
# call is meant to run the /reviews sleep-5 fixture to completion rather than
# being cut short. When it does, `fetch_evidence` falls all the way through
# empty reactions/comments/reviews/inline to the terminal
# `bounded_wait "no terminal current-head evidence yet"`. If the local vs.
# GitHub-clock precedence regressed and the budget was wrongly shortened
# instead (as in the case above), the reviews fetch would be killed early and
# emit `bounded_wait "cannot fetch paginated PR reviews"` — same `pending`
# status (11), but a different, checkable detail. Assert on that directly:
# it is immune to scheduler noise in a way wall-clock timing is not.
detail="$(printf '%s' "$check_out" | jq -r '.detail' 2>/dev/null || true)"
[ "$detail" = "no terminal current-head evidence yet" ] ||
    fail "reviews fetch did not run to completion under the local budget: $check_out"
# Lower bound: proves the sleep-5 fixture actually took real time rather than
# being short-circuited by a clock bug that mistakes GitHub's returned time
# for the local reservation clock (which would yield a ~1s call_timeout as in
# the case above and return almost instantly). Load only ever makes this
# slower, never faster, so contention cannot produce a false failure here —
# it is load-immune and needs no widening. Kept alongside the detail
# assertion above as a second, independent confirmation of the same "the
# call actually ran" fact.
[ "$elapsed_seconds" -ge 4 ] ||
    fail "GitHub time incorrectly shortened the local API budget (${elapsed_seconds}s)"
# Deliberately NO post-return upper bound here (or anywhere in this file):
# in this fixture the /reviews call can never take longer than its hardcoded
# 5s sleep regardless of whether call_timeout is computed correctly,
# generously, or even unboundedly large — so no regression in this helper
# can make elapsed here differ behaviorally; a "runs forever" bug is simply
# not representable by a fixture that always returns after 5s. A wall-clock
# ceiling here can only ever measure how long the PARENT shell (this test
# script) went unscheduled, not the helper's own budget: the child process
# can complete correctly, on time, under its own 1s/60s limits, while the
# calling shell itself sits off-CPU past any ceiling we'd pick, and
# `$SECONDS` counts that time too. That is the literal devkit#308 failure —
# two `task verify` invocations racing for CPU pushed elapsed to 938s while
# the call was correctly bounded the entire time — and it recurred at the
# previous 60s ceiling for the identical reason a wider number can't fix: the
# parent-scheduling gap has no finite bound in principle. The behavioral
# detail assertion above (regression signal) plus the `-ge 4` lower bound
# (load-immune, "the call actually ran") already prove everything a
# wall-clock check could, without ever being able to false-fail on scheduler
# noise. Real hang protection is the watchdog wrapped around run_check itself
# (see its definition): it bounds the whole invocation, including any
# parent-scheduling delay, and fails loudly with its own message instead of
# silently blowing a per-case budget.

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
    reap_out="$("$watchdog_bin" -k 5 "$watchdog_sec" "$helper" reap \
        --root "$reap_target" "$@" 2>&1)"
    reap_rc=$?
    set -e
    check_watchdog "$reap_rc" run_reap "$reap_out"
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
# The emptied directory is left in place on purpose. Pruning it raced
# `acquire_state_lock`, whose `mkdir -p "$parent"` and `mkdir "$lock_dir"` are
# not atomic — an rmdir between them fails a concurrent reservation for a
# DIFFERENT PR with a "locked by another shepherd" error naming no real lock.
[ -d "${reap_root}/example/alpha" ] ||
    fail "reap pruned an emptied directory — that races a concurrent reserve"

echo "==> a reservation still works in a directory the sweep just emptied"
write_defaults
rm -rf "$reap_root"
seed_state example/alpha 11
printf '%s\n' MERGED >"${fixtures}/pr-state-11"
run_reap "$reap_root"
assert_reap '.reaped' 1
# The concurrent case this guards cannot be scheduled deterministically, so pin
# the property instead: the repo directory outlives the sweep, and reserving a
# DIFFERENT PR in it succeeds. When reap pruned the directory, an interleaved
# reserve died with "state is locked by another shepherd" over a lock that
# never existed.
"$helper" reserve --state "${reap_root}/example/alpha/44.json" \
    --repo example/alpha --pr 44 --head "$head_sha" --attempt 1 >/dev/null ||
    fail "reserve failed in a directory the sweep had emptied"
[ -f "${reap_root}/example/alpha/44.json" ] ||
    fail "reserve wrote no state after a sweep emptied its directory"

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

echo "==> an open PR's lock is never taken, so a live cycle is not disturbed"
write_defaults
rm -rf "$reap_root"
seed_state example/alpha 11
# PR 11 stays OPEN and a live shepherd holds its lock. Reaping must not contend
# for that lock at all: `acquire_state_lock` is a bare `mkdir` that dies on
# contention with no retry, so a sweep holding it across a `gh pr view` sends a
# correct session for a DIFFERENT PR to maintainer reconciliation on exit 2.
# The discriminator is `kept`, not `skipped` — skipped would mean the sweep
# tried the lock and lost, which is the behaviour being fixed.
mkdir "${reap_root}/example/alpha/11.json.lock"
run_reap "$reap_root"
[ "$reap_rc" -eq 0 ] || fail "reap exited $reap_rc: $reap_out"
assert_reap '.kept' 1
assert_reap '.skipped' 0
assert_reap '[.entries[] | .detail] | first' "PR is still open"
[ -d "${reap_root}/example/alpha/11.json.lock" ] ||
    fail "reap released a lock it does not own"
rmdir "${reap_root}/example/alpha/11.json.lock"

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
run_reap "$reap_root" --budget-sec 1
[ "$reap_rc" -eq 0 ] || fail "a stalled sweep exited $reap_rc: $reap_out"
assert_reap '.scanned' 2
# These are the regression signal, not a wall-clock bound. With
# --budget-sec 1 the whole-sweep deadline expires almost immediately, so only
# the first entry's pr-view call is even attempted (at a ~1s call_timeout)
# before the second is fast-pathed as "kept" without a call at all. If that
# per-entry budget regressed back to the flat 60s ceiling instead, BOTH
# stalled pr-view calls (each fixture-capped at 5s, well under 60s) would
# complete normally and return their real MERGED state — and a completed
# MERGED lookup gets REAPED, not kept. A regressed budget therefore flips
# `.reaped`/`.kept` and deletes the state files below; a wall-clock bound
# adds nothing that these don't already prove deterministically, at any
# speed. The "budget exhausted" detail is the same signal from a different
# angle: it can only appear on an entry the budget check actually cut off.
assert_reap '.reaped' 0
assert_reap '.kept' 2
[ -f "${reap_root}/example/alpha/11.json" ] || fail "a stalled sweep deleted state"
[ -f "${reap_root}/example/beta/22.json" ] || fail "a stalled sweep deleted state"
printf '%s' "$reap_out" | jq -e \
    '[.entries[] | select(.detail | test("budget exhausted"))] | length >= 1' \
    >/dev/null || fail "no entry reported the exhausted budget: $reap_out"
# No post-return wall-clock bound: it was never load-sensitive by accident,
# it was redundant with the assertions above from the start, and — same as
# the API-budget case — any real "ran forever" regression is not
# representable by a fixture whose pr-view stall is hardcoded to 5s anyway.
# The suite's own hang protection is the watchdog wrapped around run_reap
# itself (see its definition).

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
