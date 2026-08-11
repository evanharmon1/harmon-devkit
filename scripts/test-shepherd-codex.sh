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
*/reactions?per_page=100)
    # Per-trigger routing when a case writes one, so a sweep that must read
    # BOTH the current and the previous attempt's trigger can be told apart
    # from one that reads only the current. Otherwise every trigger shares the
    # one fixture, exactly as before.
    reactions_id="${endpoint%/reactions?per_page=100}"
    reactions_id="${reactions_id##*/}"
    file="reactions-${reactions_id}.pages.json"
    [ -f "$GH_FIXTURES/$file" ] || file=reactions.pages.json
    ;;
# `settle` fetches one comment or one review by ID. A per-ID fixture answers
# it when the case under test wrote one; otherwise this stays the trigger
# comment, exactly as before settlement existed. `settle` against an ID with
# no fixture is the missing-target case and must fail the way GitHub would.
repos/*/issues/comments/*)
    # A `missing-<id>` marker makes that one comment 404 the way GitHub would.
    [ ! -f "$GH_FIXTURES/missing-${endpoint##*/}" ] || exit 95
    file="comment-${endpoint##*/}.json"
    [ -f "$GH_FIXTURES/$file" ] || file=trigger.json
    ;;
repos/*/issues/*/comments?per_page=100) file=comments.pages.json ;;
repos/*/pulls/*/reviews?per_page=100) file=reviews.pages.json ;;
repos/*/pulls/*/reviews/*)
    file="review-${endpoint##*/}.json"
    [ -f "$GH_FIXTURES/$file" ] || exit 95
    ;;
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
    rm -f "${fixtures}"/reactions-*.pages.json
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
    rm -f "${fixtures}"/comment-*.json "${fixtures}"/review-*.json
    rm -f "${fixtures}"/missing-*
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

# Same as run_check but omits --timeout-min entirely, for cases that need to
# exercise the flagless default/adoption path rather than an explicit 15
# that happens to equal the default (harmon-devkit#223 challenge round 2).
run_check_no_timeout_flag() {
    set +e
    check_out="$("$helper" check \
        --state "$state" --actor-id "$actor_id" \
        --actor-login "$actor_login" \
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

# GitHub auto-creates a body-less COMMENTED review shell to carry inline
# comments, and Codex posts one before its inline findings land. An empty body
# is no evidence: jq's `"" | split("\n")` is `[]`, so before the guard this
# crashed the classifier with jq's own exit 5 (harmon-devkit#392, hit live on
# harmon-init#766) — and classifying it instead would read the shell as
# `findings` and hard-block a cycle whose real review has not arrived.
echo "==> an empty-body review shell is no evidence, not a crash"
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
        body:""
      }
    ]]' >"${fixtures}/reviews.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 11 pending

echo "==> an empty-body shell does not mask a clean review on the same head"
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
        body:""
      },
      {
        id:105,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:05Z",
        commit_id:$head,
        body:"Codex Review: Didn\u0027t find any major issues."
      }
    ]]' >"${fixtures}/reviews.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 0 clean

# The inverse ordering is the race (devkit#392 challenge round 1): Codex posts
# the shell BEFORE its verdict or findings, so a shell NEWER than the clean
# evidence means the next review is already in flight and the older clean
# result cannot vouch for it. Time-ordered deliberately — a dangling shell
# older than the clean evidence (the previous case) ages out rather than
# deadlocking the cycle.
echo "==> a dangling shell newer than the clean evidence keeps the cycle pending"
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
        body:"Codex Review: Didn\u0027t find any major issues."
      },
      {
        id:105,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:06Z",
        commit_id:$head,
        body:""
      }
    ]]' >"${fixtures}/reviews.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 11 pending

echo "==> a dangling shell newer than the trigger thumbs-up keeps the cycle pending"
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:105,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:06Z",
        commit_id:$head,
        body:""
      }
    ]]' >"${fixtures}/reviews.pages.json"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    '[[
      {
        user:{id:$id,login:$login},
        content:"+1",
        created_at:"2026-07-31T08:00:05Z"
      }
    ]]' >"${fixtures}/reactions.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 11 pending

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

# The dangling-shell barrier at the adjudicated-clean exit reads ONLY the
# adjudication evidence — the bot's current-head findings and the in-thread
# replies to them (devkit#392 challenge round 2). An unrelated inline comment
# newer than the shell must not clear the barrier, or an in-flight review is
# vouched for by activity that adjudicated nothing.
echo "==> an unrelated inline comment does not clear the dangling-shell barrier"
new_cycle
codex_findings_review
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:120,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:("\n### 💡 Codex Review\n\nHere are some automated review suggestions for this pull request.\n\n**Reviewed commit:** `" + ($head[0:10]) + "`")
      },
      {
        id:121,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:40Z",
        commit_id:$head,
        body:""
      }
    ]]' >"${fixtures}/reviews.pages.json"
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
      },
      {
        id:90,user:{id:$owner,login:"repo-owner"},
        created_at:"2026-07-31T08:00:50Z",updated_at:"2026-07-31T08:00:50Z",
        author_association:"OWNER",
        body:"Unrelated note on another thread."
      }
    ]]' >"${fixtures}/inline.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 11 pending

# At the adjudicated-clean exit the shell barrier is UNCONDITIONAL — no
# timestamp comparison (devkit#392 challenge round 3). A shell still dangling
# once the clean-verdict paths above have all declined is a review in flight
# or an abandoned one, and both are pending; time-ordering it against inline
# activity was fail-open twice, because a shell is opaque and other threads'
# timestamps cannot be correlated against it. Bounded: the attempt machinery
# re-triggers and Codex posts strictly newer evidence that resolves the cycle.
echo "==> a dangling shell holds the adjudicated-clean exit at pending regardless of age"
new_cycle
codex_findings_review
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:120,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:("\n### 💡 Codex Review\n\nHere are some automated review suggestions for this pull request.\n\n**Reviewed commit:** `" + ($head[0:10]) + "`")
      },
      {
        id:121,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:10Z",
        commit_id:$head,
        body:""
      }
    ]]' >"${fixtures}/reviews.pages.json"
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
assert_status 11 pending

# GitHub timestamps to whole seconds, so a shell and the clean verdict can
# tie. A tie is undecidable — the verdict may belong to the shell's review or
# predate one now in flight — and the strict `>` reads it as pending: fail
# closed, self-healing via the attempt machinery's strictly newer evidence
# (devkit#392 challenge round 3).
echo "==> a clean verdict tying the shell's second stays pending, not clean"
new_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:104,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:06Z",
        commit_id:$head,
        body:"Codex Review: Didn\u0027t find any major issues."
      },
      {
        id:105,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:06Z",
        commit_id:$head,
        body:""
      }
    ]]' >"${fixtures}/reviews.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 11 pending

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

echo "==> a persisted non-default timeout governs attempt 2's window (harmon-devkit#223)"
# `reserve`'s attempt-1-window check has no --now: it always compares against
# the real wall clock (see the existing "attempt 2 cannot be reserved before
# attempt 1 expires" case above), so this test has to use real relative
# timestamps rather than the fixture's fixed 2026-07-31 dates. jq's
# to/fromdateiso8601 keep the epoch math portable across BSD and GNU date.
epoch_now="$(date -u '+%s')"
iso_from_offset() { jq -nr --argjson e "$((epoch_now + $1))" '$e | todateiso8601'; }

trigger_id=123
request_time="$(iso_from_offset 0)"
write_defaults
rm -f "$state"
"$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 1 --timeout-min 10 >/dev/null
[ "$(jq -r '.timeout_min' "$state")" = "10" ] ||
    fail "reserve did not persist a non-default --timeout-min"

# 5 minutes into a 10-minute persisted window: still short of either window,
# so attempt 2 must be refused regardless of which timeout is in force.
jq --arg reserved "$(iso_from_offset -300)" '.reserved_at = $reserved' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
"$helper" attach --state "$state" --trigger-id "$trigger_id" >/dev/null
set +e
early_attempt2_out="$("$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 2 2>&1)"
early_attempt2_rc=$?
set -e
[ "$early_attempt2_rc" -eq 2 ] ||
    fail "attempt 2 should still be refused before either window elapses: $early_attempt2_out"

# 11 minutes into a 10-minute persisted window: past the persisted timeout but
# short of the script's unmodified 15-minute default. Only a reserve that
# reads the persisted 10 minutes back out of state allows this — a reserve
# still enforcing the hardcoded default would refuse it for another 4 minutes,
# reproducing the #223 defect.
jq --arg reserved "$(iso_from_offset -660)" '.reserved_at = $reserved' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
trigger_id=124
request_time="$(iso_from_offset 1)"
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
[ "$(jq -r '.timeout_min' "$state")" = "10" ] ||
    fail "attempt-2 reservation did not carry the persisted timeout forward"
jq --arg reserved "$request_time" '.reserved_at = $reserved' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
"$helper" attach --state "$state" --trigger-id "$trigger_id" >/dev/null
printf '%s\n' '[[]]' >"${fixtures}/reactions.pages.json"
printf '%s\n' '[[]]' >"${fixtures}/comments.pages.json"
# `check` itself must also use the persisted 10-minute window (not the
# --now flag's proximity to the script's 15-minute default): 11 minutes after
# this attempt-2 reservation is past the persisted timeout.
check_now_epoch="$(jq -nr --arg t "$request_time" '$t | fromdateiso8601 + 660')"
run_check_no_timeout_flag "$(jq -nr --argjson e "$check_now_epoch" '$e | todateiso8601')"
assert_status 13 escalate

echo "==> check rejects an explicit --timeout-min that conflicts with the persisted value"
trigger_id=123
request_time='2026-07-31T08:00:00Z'
write_defaults
rm -f "$state"
"$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 1 --timeout-min 10 >/dev/null
jq --arg reserved "$request_time" '.reserved_at = $reserved' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
"$helper" attach --state "$state" --trigger-id "$trigger_id" >/dev/null
set +e
conflicting_out="$("$helper" check \
    --state "$state" --actor-id "$actor_id" \
    --actor-login "$actor_login" --timeout-min 15 \
    --now '2026-07-31T08:01:00Z' 2>&1)"
conflicting_rc=$?
set -e
[ "$conflicting_rc" -eq 2 ] ||
    fail "a conflicting --timeout-min should fail closed: $conflicting_out"
printf '%s' "$conflicting_out" | grep -Fq '10' ||
    fail "conflict message did not name the persisted value: $conflicting_out"
printf '%s' "$conflicting_out" | grep -Fq '15' ||
    fail "conflict message did not name the requested value: $conflicting_out"

echo "==> a legacy state without timeout_min keeps the 15-minute default (no --timeout-min flag)"
trigger_id=123
request_time='2026-07-31T08:00:00Z'
new_cycle
# Simulate state written before harmon-devkit#223: no timeout_min field at all.
jq 'del(.timeout_min)' "$state" >"${state}.next"
mv "${state}.next" "$state"
# Deliberately flagless: run_check always passes --timeout-min 15, which
# would exercise explicit adoption (an explicit 15 that happens to match the
# default) rather than the true no-flag default-fallback path this test is
# named for. run_check_no_timeout_flag omits the flag entirely.
run_check_no_timeout_flag '2026-07-31T08:14:00Z'
assert_status 11 pending
run_check_no_timeout_flag '2026-07-31T08:16:00Z'
assert_status 12 retry
[ "$(jq -r '.timeout_min' "$state")" = "null" ] ||
    fail "the flagless default path must not persist a choice: $(jq -c . "$state")"

echo "==> the documented convention — bare reserve, then check --timeout-min N — adopts and persists N (harmon-devkit#223 challenge round 1)"
# `reserve` with no --timeout-min leaves the cycle's timeout undecided
# (timeout_min: null): no command has chosen one yet. The FIRST explicit
# --timeout-min any later command supplies for that undecided cycle adopts —
# this is the pre-existing documented convention (reserve, then `check
# --timeout-min N`), and it must keep working, not be read as a conflict
# against an implicit 15-minute default that was never actually chosen.
epoch_now="$(date -u '+%s')"
iso_from_offset() { jq -nr --argjson e "$((epoch_now + $1))" '$e | todateiso8601'; }

trigger_id=123
request_time="$(iso_from_offset 0)"
write_defaults
rm -f "$state"
"$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 1 >/dev/null
[ "$(jq -r '.timeout_min' "$state")" = "null" ] ||
    fail "a bare reserve should leave timeout_min undecided (null), got: $(jq -c . "$state")"
jq --arg reserved "$request_time" '.reserved_at = $reserved' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
"$helper" attach --state "$state" --trigger-id "$trigger_id" >/dev/null

run_check_with_timeout_flag() {
    set +e
    check_out="$("$helper" check \
        --state "$state" --actor-id "$actor_id" \
        --actor-login "$actor_login" --timeout-min "$1" \
        --now "$2" 2>&1)"
    check_rc=$?
    set -e
}
# 9 minutes elapsed — short of the 10-minute window this check adopts, so it
# must be pending, not retry (which the unmodified 15-minute default would
# also report as pending, so this alone isn't the differentiator — the
# persisted-field assertion right after it is).
run_check_with_timeout_flag 10 "$(iso_from_offset 540)"
assert_status 11 pending
[ "$(jq -r '.timeout_min' "$state")" = "10" ] ||
    fail "check --timeout-min 10 did not adopt and persist the timeout: $(jq -c . "$state")"

# A second check with NO flag must keep using the now-persisted 10 minutes:
# 11 minutes elapsed is past the adopted window.
run_check_no_timeout_flag "$(iso_from_offset 660)"
assert_status 12 retry

# attempt 2's window with no --timeout-min of its own must honor the adopted
# 10 minutes, not the unmodified 15-minute default. Uses real relative
# timestamps, like the reserve-window test above, since attempt-2 `reserve`
# has no --now and always compares to the real wall clock.
jq --arg reserved "$(iso_from_offset -660)" '.reserved_at = $reserved' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
trigger_id=124
request_time="$(iso_from_offset 1)"
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
[ "$(jq -r '.timeout_min' "$state")" = "10" ] ||
    fail "attempt-2 reservation dropped the adopted timeout: $(jq -c . "$state")"

echo "==> attach's GitHub calls are budgeted by the persisted timeout, not the default (harmon-devkit#223 challenge round 1)"
# `run_gh`'s per-call timeout budget is driven by \$timeout_min for every
# command, including attach — not just the commands that reference the flag
# by name. Persist a non-default 5-minute timeout, leave only ~2s of that
# window, and stall attach's trigger-comment fetch for 5s (the fixture's
# fixed artificial sleep). If attach threads the persisted 5 minutes through,
# run_gh's timeout wrapper cuts the stalled call off after ~2s. If it fell
# back to the unmodified 15-minute default (the #223 bug applied to attach),
# the remaining budget would be minutes wide, so the call would run its full
# 5s sleep uninterrupted and this assertion would fail.
trigger_id=123
request_time="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
write_defaults
rm -f "$state"
"$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 1 --timeout-min 5 >/dev/null
near_deadline_epoch=$(($(date -u '+%s') - (5 * 60 - 2)))
near_deadline="$(jq -nr --argjson e "$near_deadline_epoch" '$e | todateiso8601')"
jq --arg reserved "$near_deadline" '.reserved_at = $reserved' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
printf '%s\n' 'issues/comments' >"${fixtures}/slow-endpoint"
set +e
start_seconds=$SECONDS
"$helper" attach --state "$state" --trigger-id "$trigger_id" >/dev/null 2>&1
attach_rc=$?
elapsed_seconds=$((SECONDS - start_seconds))
set -e
rm -f "${fixtures}/slow-endpoint"
[ "$elapsed_seconds" -lt 4 ] ||
    fail "attach did not bound its call to the persisted 5-minute window (${elapsed_seconds}s, rc=$attach_rc)"

echo "==> a corrupted persisted timeout_min fails closed rather than blowing up shell arithmetic (harmon-devkit#223 challenge round 1)"
new_cycle
jq '.timeout_min = 0' "$state" >"${state}.next"
mv "${state}.next" "$state"
set +e
zero_out="$("$helper" check \
    --state "$state" --actor-id "$actor_id" \
    --actor-login "$actor_login" \
    --now '2026-07-31T08:01:00Z' 2>&1)"
zero_rc=$?
set -e
[ "$zero_rc" -eq 2 ] ||
    fail "a zero persisted timeout should fail closed, got rc=$zero_rc: $zero_out"
printf '%s' "$zero_out" | grep -Fq 'timeout_min' ||
    fail "corrupt timeout_min error did not name the field: $zero_out"

new_cycle
jq '.timeout_min = "abc"' "$state" >"${state}.next"
mv "${state}.next" "$state"
set +e
nonnumeric_out="$("$helper" check \
    --state "$state" --actor-id "$actor_id" \
    --actor-login "$actor_login" \
    --now '2026-07-31T08:01:00Z' 2>&1)"
nonnumeric_rc=$?
set -e
[ "$nonnumeric_rc" -eq 2 ] ||
    fail "a non-numeric persisted timeout should fail closed, got rc=$nonnumeric_rc: $nonnumeric_out"

echo "==> attach rejects a zero --timeout-min instead of adopting and bricking the cycle (harmon-devkit#223 challenge round 2)"
# Unlike reserve/check, attach had no valid_uint guard on the flag before
# resolve_timeout_min — an explicit --timeout-min 0 would adopt and persist
# 0, and every later check would then die on the corrupted-state path
# instead of the usage failing closed right where the bad input was given.
trigger_id=123
request_time='2026-07-31T08:00:00Z'
write_defaults
rm -f "$state"
"$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 1 >/dev/null
jq --arg reserved "$request_time" '.reserved_at = $reserved' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
set +e
zero_attach_out="$("$helper" attach \
    --state "$state" --trigger-id "$trigger_id" --timeout-min 0 2>&1)"
zero_attach_rc=$?
set -e
[ "$zero_attach_rc" -eq 2 ] ||
    fail "attach --timeout-min 0 should fail closed, got rc=$zero_attach_rc: $zero_attach_out"
[ "$(jq -r '.timeout_min' "$state")" = "null" ] ||
    fail "a rejected --timeout-min 0 must not be persisted: $(jq -c . "$state")"
[ "$(jq -r '.phase' "$state")" = "reserved" ] ||
    fail "a rejected attach must not attach: $(jq -c . "$state")"

echo "==> an early attempt-2 refusal still persists the timeout it adopted (harmon-devkit#223 challenge round 3)"
# resolve_timeout_min flags an adoption before the attempt-1 window check
# runs, but the window check can `die` and exit the process. If the
# reservation persists the adoption only on the SUCCESS path, an early
# attempt-2 that supplies the cycle's first explicit --timeout-min loses that
# choice on refusal — a later flagless retry would then fall back to the
# 15-minute default and get refused again, for a window nobody actually
# chose. Uses real relative timestamps: attempt-2 reserve compares against
# the real wall clock, not --now.
epoch_now="$(date -u '+%s')"
iso_from_offset() { jq -nr --argjson e "$((epoch_now + $1))" '$e | todateiso8601'; }

trigger_id=123
request_time="$(iso_from_offset 0)"
write_defaults
rm -f "$state"
"$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 1 >/dev/null
jq --arg reserved "$request_time" '.reserved_at = $reserved' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
"$helper" attach --state "$state" --trigger-id "$trigger_id" >/dev/null

# Attempt 1 was reserved moments ago — an attempt-2 reservation now is well
# inside any window and must be refused, whether the persisted timeout is 10
# minutes or the 15-minute default.
set +e
early_out="$("$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 2 --timeout-min 10 2>&1)"
early_rc=$?
set -e
[ "$early_rc" -eq 2 ] ||
    fail "an early attempt-2 reservation should still fail closed: $early_out"
[ "$(jq -r '.timeout_min' "$state")" = "10" ] ||
    fail "a refused attempt-2 reservation must still persist the timeout it adopted: $(jq -c . "$state")"
[ "$(jq -r '.phase' "$state")" = "attached" ] ||
    fail "a refused attempt-2 reservation must not otherwise mutate the state: $(jq -c . "$state")"

# 11 minutes after the ORIGINAL attempt-1 reservation, past the persisted
# 10-minute window (adopted above) but short of the unmodified 15-minute
# default. A flagless attempt-2 must now succeed — proving the adoption
# survived the earlier refusal instead of reverting to "undecided".
jq --arg reserved "$(iso_from_offset -660)" '.reserved_at = $reserved' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
"$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 2 >/dev/null
[ "$(jq -r '.timeout_min' "$state")" = "10" ] ||
    fail "the flagless attempt-2 reservation dropped the earlier-adopted timeout: $(jq -c . "$state")"

echo "==> reserve rejects a leading-zero --timeout-min outright (harmon-devkit#223 challenge round 3)"
# valid_uint's [1-9][0-9]* pattern forbids a leading zero on the explicit
# flag, so this never reaches the persisted-value comparison at all — the
# comparison's own base-10 canonicalization (guarding against bash
# reinterpreting a leading zero as OCTAL, e.g. \`[ 010 -eq 8 ]\`) is defense
# in depth for a value that cannot arrive this way today, not a fix for a
# reachable false conflict. This test pins that first gate in place.
trigger_id=123
write_defaults
rm -f "$state"
set +e
leading_zero_out="$("$helper" reserve \
    --state "$state" --repo example/repo --pr 493 \
    --head "$head_sha" --attempt 1 --timeout-min 010 2>&1)"
leading_zero_rc=$?
set -e
[ "$leading_zero_rc" -eq 2 ] ||
    fail "a leading-zero --timeout-min should fail closed, got rc=$leading_zero_rc: $leading_zero_out"
[ ! -f "$state" ] ||
    fail "a rejected leading-zero --timeout-min must not create state"

# --------------------------------------------------------------------------
# `settle` — dispositions for badged findings that live outside inline threads
# (harmon-devkit#391). Fixtures are built ONCE per case and the listing is
# derived from the single object with `[[.]]`, so the body and edit timestamp
# `settle` fingerprints are byte-identical to the ones `check` re-reads. A
# hand-written second copy would make a fingerprint mismatch look like a bug
# in the code under test.
# --------------------------------------------------------------------------

# The timeout cases above leave the harness clock wherever they needed it;
# everything below runs on the fixed 08:00 cycle clock again.
request_time='2026-07-31T08:00:00Z'
trigger_id=123

run_settle() {
    set +e
    settle_out="$("$helper" settle --state "$state" --actor-id "$actor_id" \
        "$@" 2>&1)"
    settle_rc=$?
    set -e
}

# A badged top-level conversation comment: a finding with no thread to reply
# to, which is the whole reason `settle` exists.
write_badged_comment() {
    comment_prefix=${2:-${head_sha:0:10}}
    jq -cn \
        --argjson id "$1" \
        --argjson actor "$actor_id" \
        --arg login "$actor_login" \
        --arg prefix "$comment_prefix" \
        --arg updated "${3:-2026-07-31T08:00:02Z}" \
        '{
          id:$id,user:{id:$actor,login:$login},
          created_at:"2026-07-31T08:00:02Z",updated_at:$updated,
          issue_url:"https://api.github.com/repos/example/repo/issues/493",
          body:("P1: the rollback path loses data.\n\n**Reviewed commit:** `" +
            $prefix + "`")
        }' >"${fixtures}/comment-${1}.json"
    jq -c '[[.]]' "${fixtures}/comment-${1}.json" \
        >"${fixtures}/comments.pages.json"
}

# A badged review BODY: the other unreachable surface — its finding is stated
# in the body itself, where no inline comment exists to carry a reply.
write_badged_review() {
    jq -cn \
        --argjson id "$1" \
        --argjson actor "$actor_id" \
        --arg login "$actor_login" \
        --arg head "${2:-$head_sha}" \
        '{
          id:$id,user:{id:$actor,login:$login},
          submitted_at:"2026-07-31T08:00:04Z",
          commit_id:$head,
          body:"### Codex Review\n\nP1: the rollback path also loses data."
        }' >"${fixtures}/review-${1}.json"
    jq -c '[[.]]' "${fixtures}/review-${1}.json" \
        >"${fixtures}/reviews.pages.json"
}

echo "==> a settled top-level finding stops blocking the cycle"
new_cycle
write_badged_comment 77
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings
run_settle --surface comment --id 77 --disposition declined \
    --note "bounded by the attempt deadline; reasoning posted on the PR"
[ "$settle_rc" -eq 0 ] || fail "settle should have recorded: $settle_out"
[ "$(jq -r '[.settled[] | select(.surface == "comment" and .id == 77)] | length' \
    "$state")" = "1" ] ||
    fail "the disposition was not recorded: $(jq -c .settled "$state")"
[ "$(jq -r '.settled[0].disposition' "$state")" = "declined" ] ||
    fail "the disposition was not preserved: $(jq -c .settled "$state")"
[ -n "$(jq -r '.settled[0].content_fingerprint // empty' "$state")" ] ||
    fail "the disposition carries no fingerprint: $(jq -c .settled "$state")"
run_check '2026-07-31T08:01:00Z'
assert_status 11 pending

echo "==> a settled review body stops blocking the cycle"
new_cycle
write_badged_review 120
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings
run_settle --surface review --id 120 --disposition filed \
    --note "filed as follow-up example/repo#900"
[ "$settle_rc" -eq 0 ] || fail "settle should have recorded: $settle_out"
# The 👍 proves the settled body is out of the way of a real clean verdict,
# not merely that the review stopped reporting findings.
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    '[[
      {
        user:{id:$id,login:$login},
        content:"+1",created_at:"2026-07-31T08:00:30Z"
      }
    ]]' >"${fixtures}/reactions.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 0 clean

echo "==> settling a finding edited since the disposition blocks again"
# Codex edits a finding in place when it revises it. The disposition answered
# the earlier text, so it stops applying — and the entry is kept, not deleted,
# because what was decided about that text is still a record worth having.
new_cycle
write_badged_comment 77
run_settle --surface comment --id 77 --disposition declined --note "declined"
[ "$settle_rc" -eq 0 ] || fail "settle should have recorded: $settle_out"
run_check '2026-07-31T08:01:00Z'
assert_status 11 pending
jq -c '[[.[0][0] | .updated_at = "2026-07-31T08:00:45Z"]]' \
    "${fixtures}/comments.pages.json" >"${fixtures}/comments.next"
mv "${fixtures}/comments.next" "${fixtures}/comments.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings
[ "$(jq -r '.settled | length' "$state")" = "1" ] ||
    fail "an invalidated disposition must be kept, not deleted: $(jq -c .settled "$state")"

echo "==> a settled review body does not settle its own inline findings"
# The two sets compose. Settling the body says nothing about the inline
# comments hanging off the same review, which keep the reply-based path.
new_cycle
write_badged_review 120
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$head_sha" \
    '[[
      {
        id:88,user:{id:$id,login:$login},
        created_at:"2026-07-31T08:00:03Z",updated_at:"2026-07-31T08:00:03Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:120,
        body:"P2: consider hardening the retry path"
      }
    ]]' >"${fixtures}/inline.pages.json"
run_settle --surface review --id 120 --disposition declined --note "declined"
[ "$settle_rc" -eq 0 ] || fail "settle should have recorded: $settle_out"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> settle refuses a finding about another head"
new_cycle
previous_head="$(git rev-parse HEAD~1)"
write_badged_comment 77 "${previous_head:0:10}"
run_settle --surface comment --id 77 --disposition declined --note "declined"
[ "$settle_rc" -eq 2 ] ||
    fail "a wrong-head disposition should fail closed, got rc=$settle_rc: $settle_out"
new_cycle
write_badged_review 120 "$previous_head"
run_settle --surface review --id 120 --disposition declined --note "declined"
[ "$settle_rc" -eq 2 ] ||
    fail "a wrong-head review disposition should fail closed, got rc=$settle_rc: $settle_out"

echo "==> settle refuses an unbadged target"
# Without a badge there is no finding to dispose of, and settling whatever
# else the surface carries would suppress a verdict rather than answer one.
new_cycle
jq -cn \
    --argjson actor "$actor_id" \
    --arg login "$actor_login" \
    --arg prefix "${head_sha:0:10}" \
    '{
      id:77,user:{id:$actor,login:$login},
      created_at:"2026-07-31T08:00:02Z",updated_at:"2026-07-31T08:00:02Z",
      issue_url:"https://api.github.com/repos/example/repo/issues/493",
      body:("Codex Review: Didn\u0027t find any major issues.\n\n**Reviewed commit:** `" + $prefix + "`")
    }' >"${fixtures}/comment-77.json"
run_settle --surface comment --id 77 --disposition declined --note "declined"
[ "$settle_rc" -eq 2 ] ||
    fail "an unbadged disposition should fail closed, got rc=$settle_rc: $settle_out"

echo "==> settle refuses a target the pinned actor did not write"
new_cycle
jq -cn \
    --argjson outsider "$outsider_id" \
    --arg prefix "${head_sha:0:10}" \
    '{
      id:77,user:{id:$outsider,login:"bystander"},
      created_at:"2026-07-31T08:00:02Z",updated_at:"2026-07-31T08:00:02Z",
      issue_url:"https://api.github.com/repos/example/repo/issues/493",
      body:("P1: the rollback path loses data.\n\n**Reviewed commit:** `" + $prefix + "`")
    }' >"${fixtures}/comment-77.json"
run_settle --surface comment --id 77 --disposition declined --note "declined"
[ "$settle_rc" -eq 2 ] ||
    fail "a foreign-author disposition should fail closed, got rc=$settle_rc: $settle_out"

echo "==> settle refuses a target that does not exist"
new_cycle
: >"${fixtures}/missing-77"
run_settle --surface comment --id 77 --disposition declined --note "declined"
[ "$settle_rc" -eq 2 ] ||
    fail "a missing comment should fail closed, got rc=$settle_rc: $settle_out"
rm -f "${fixtures}/missing-77"
new_cycle
run_settle --surface review --id 999 --disposition declined --note "declined"
[ "$settle_rc" -eq 2 ] ||
    fail "a missing review should fail closed, got rc=$settle_rc: $settle_out"

echo "==> settle rejects an unknown surface or disposition"
new_cycle
write_badged_comment 77
run_settle --surface issue --id 77 --disposition declined --note "declined"
[ "$settle_rc" -eq 2 ] ||
    fail "an unknown surface should fail closed, got rc=$settle_rc: $settle_out"
run_settle --surface comment --id 77 --disposition ignored --note "declined"
[ "$settle_rc" -eq 2 ] ||
    fail "an unknown disposition should fail closed, got rc=$settle_rc: $settle_out"

echo "==> a version-1 state is read and rewritten as version 2"
new_cycle
[ "$(jq -r .version "$state")" = "2" ] ||
    fail "reserve must write version 2: $(jq -c . "$state")"
jq 'del(.settled,.carries,.last_result,.last_result_at) | .version = 1' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    '[[
      {
        user:{id:$id,login:$login},
        content:"+1",created_at:"2026-07-31T08:00:00Z"
      }
    ]]' >"${fixtures}/reactions.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 0 clean
[ "$(jq -r .version "$state")" = "2" ] ||
    fail "a terminal check must rewrite the state as version 2: $(jq -c . "$state")"
[ "$(jq -r .last_result "$state")" = "clean" ] ||
    fail "a terminal check must record its result: $(jq -c . "$state")"

echo "==> a state version this helper does not understand fails closed"
new_cycle
jq '.version = 3' "$state" >"${state}.next"
mv "${state}.next" "$state"
set +e
future_out="$("$helper" show --state "$state" 2>&1)"
future_rc=$?
set -e
[ "$future_rc" -eq 2 ] ||
    fail "a version-3 state should fail closed, got rc=$future_rc: $future_out"
set +e
"$helper" check --state "$state" --actor-id "$actor_id" \
    --now '2026-07-31T08:01:00Z' >/dev/null 2>&1
future_check_rc=$?
set -e
[ "$future_check_rc" -eq 2 ] ||
    fail "check on a version-3 state should fail closed, got rc=$future_check_rc"

# --------------------------------------------------------------------------
# `carry` — moving a terminal-clean verdict across a pure base catch-up merge
# (harmon-init#752). These cases need real commits, so they build their own
# branches in the harness repo and run last.
# --------------------------------------------------------------------------

run_carry() {
    set +e
    carry_out="$("$helper" carry --state "$state" --actor-id "$actor_id" "$@" 2>&1)"
    carry_rc=$?
    set -e
}

# Reserve and attach a cycle whose head is an arbitrary commit, so the carry
# cases can drive the real git graph below instead of the harness's original
# two empty commits.
new_cycle_at() {
    write_defaults
    printf '%s\n' "$1" >"${fixtures}/head"
    printf '%s\n' "$1" >"${fixtures}/resolved-head"
    jq -cn --argjson author "$pr_author_id" --arg head "$1" \
        '{number:493,user:{id:$author,login:"pr-author"},head:{sha:$head}}' \
        >"${fixtures}/pr.json"
    rm -f "$state"
    "$helper" reserve \
        --state "$state" --repo example/repo --pr 493 \
        --head "$1" --attempt 1 >/dev/null
    jq --arg reserved "$request_time" '.reserved_at = $reserved' \
        "$state" >"${state}.next"
    mv "${state}.next" "$state"
    "$helper" attach --state "$state" --trigger-id "$trigger_id" >/dev/null
}

# The graph every carry case starts from: a PR branch carrying one change, a
# base that has since advanced, and the catch-up merge of that base into the
# PR branch. The merge changes the head and leaves the three-dot diff exactly
# as it was, which is the only situation a carry is for.
carry_setup() {
    git checkout -q -B carry-base "$head_sha"
    printf 'base\n' >base.txt
    git add base.txt
    git commit -q -m "base: initial"
    git checkout -q -B carry-pr
    printf 'feature\n' >feature.txt
    git add feature.txt
    git commit -q -m "feat: the proposed change"
    carry_old_head="$(git rev-parse HEAD)"
    git checkout -q carry-base
    printf 'more base\n' >>base.txt
    git add base.txt
    git commit -q -m "base: advance"
    git checkout -q carry-pr
    git merge -q --no-edit carry-base
    carry_new_head="$(git rev-parse HEAD)"
}

# A cycle whose old head is genuinely clean: the 👍 path runs for real, so the
# `last_result` a carry depends on is written by `check` rather than injected.
carry_clean_cycle() {
    new_cycle_at "$carry_old_head"
    jq -cn \
        --argjson id "$actor_id" \
        --arg login "$actor_login" \
        '[[
          {
            user:{id:$id,login:$login},
            content:"+1",created_at:"2026-07-31T08:00:00Z"
          }
        ]]' >"${fixtures}/reactions.pages.json"
    run_check '2026-07-31T08:01:00Z'
    assert_status 0 clean
    # The reaction is dropped afterwards so nothing but the carry itself can
    # produce a clean result on the new head.
    printf '%s\n' '[[]]' >"${fixtures}/reactions.pages.json"
    printf '%s\n' "$carry_new_head" >"${fixtures}/head"
    printf '%s\n' "$carry_new_head" >"${fixtures}/resolved-head"
    jq -cn --argjson author "$pr_author_id" --arg head "$carry_new_head" \
        '{number:493,user:{id:$author,login:"pr-author"},head:{sha:$head}}' \
        >"${fixtures}/pr.json"
}

echo "==> an identical exact diff carries the clean verdict onto the merged head"
carry_setup
carry_clean_cycle
run_carry --new-head "$carry_new_head" --base-ref carry-base
[ "$carry_rc" -eq 0 ] || fail "carry should have succeeded: $carry_out"
[ "$(jq -r .head "$state")" = "$carry_new_head" ] ||
    fail "carry must move the state head: $(jq -c . "$state")"
[ "$(jq -r '.carries | length' "$state")" = "1" ] ||
    fail "carry must record its provenance: $(jq -c .carries "$state")"
[ "$(jq -r '.carries[0].carried_from' "$state")" = "$carry_old_head" ] ||
    fail "carry recorded the wrong origin: $(jq -c .carries "$state")"
[ -n "$(jq -r '.carries[0].diff_fingerprint // empty' "$state")" ] ||
    fail "carry recorded no patch id: $(jq -c .carries "$state")"
[ "$(jq -r .last_result "$state")" = "clean" ] ||
    fail "carry must preserve the terminal-clean provenance: $(jq -c . "$state")"
run_check '2026-07-31T08:01:00Z'
assert_status 0 clean
printf '%s' "$check_out" | grep -Fq "carried from $carry_old_head" ||
    fail "a carried clean must name the carry in its detail: $check_out"

echo "==> a carried head still loses to findings on the new head"
# The carry substitutes for the ABSENCE of evidence, never for evidence that
# contradicts it.
carry_setup
carry_clean_cycle
run_carry --new-head "$carry_new_head" --base-ref carry-base
[ "$carry_rc" -eq 0 ] || fail "carry should have succeeded: $carry_out"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$carry_new_head" \
    '[[
      {
        id:130,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:40Z",
        commit_id:$head,
        body:"### Codex Review\n\nP1: the merge reopened the rollback path."
      }
    ]]' >"${fixtures}/reviews.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings

echo "==> a changed diff refuses the carry and leaves the state alone"
carry_setup
carry_clean_cycle
printf 'feature changed\n' >feature.txt
git add feature.txt
git commit -q -m "feat: one more byte"
carry_changed_head="$(git rev-parse HEAD)"
run_carry --new-head "$carry_changed_head" --base-ref carry-base
[ "$carry_rc" -eq 2 ] ||
    fail "a changed diff must refuse the carry, got rc=$carry_rc: $carry_out"
[ "$(jq -r .head "$state")" = "$carry_old_head" ] ||
    fail "a refused carry must not touch the state: $(jq -c . "$state")"
[ "$(jq -r '.carries | length' "$state")" = "0" ] ||
    fail "a refused carry must record nothing: $(jq -c .carries "$state")"

# `git patch-id` would have carried this: patch-ids normalize whitespace, and
# a whitespace-only change is semantic in Python or YAML. The exact-diff
# fingerprint sees the changed bytes and refuses (devkit challenge round 1).
echo "==> a whitespace-only change still refuses the carry"
carry_setup
carry_clean_cycle
printf 'feature \n' >feature.txt
git add feature.txt
git commit -q -m "style: trailing space only"
carry_ws_head="$(git rev-parse HEAD)"
run_carry --new-head "$carry_ws_head" --base-ref carry-base
[ "$carry_rc" -eq 2 ] ||
    fail "a whitespace-only change must refuse the carry, got rc=$carry_rc: $carry_out"
[ "$(jq -r .head "$state")" = "$carry_old_head" ] ||
    fail "a refused whitespace carry must not touch the state: $(jq -c . "$state")"

# The old cycle's trigger — and its 👍 — survive a carry in the state file.
# That reaction is OLD-head evidence: the direct reaction path must not
# report it as an authenticated current-head result; the carry branch owns
# the verdict and names its provenance (devkit challenge round 1).
echo "==> a carried head reports the carry, not the old trigger's reaction"
carry_setup
carry_clean_cycle
# Restore the old cycle's reaction instead of leaving it dropped: the direct
# path must decline it on provenance, not on absence.
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    '[[
      {
        user:{id:$id,login:$login},
        content:"+1",created_at:"2026-07-31T08:00:00Z"
      }
    ]]' >"${fixtures}/reactions.pages.json"
run_carry --new-head "$carry_new_head" --base-ref carry-base
[ "$carry_rc" -eq 0 ] || fail "carry should have succeeded: $carry_out"
run_check '2026-07-31T08:01:00Z'
assert_status 0 clean
printf '%s' "$check_out" | grep -Fq "carried from $carry_old_head" ||
    fail "a carried head must report the carry, not the stale reaction: $check_out"

echo "==> a dirty tree refuses the carry"
carry_setup
carry_clean_cycle
printf 'uncommitted\n' >>feature.txt
run_carry --new-head "$carry_new_head" --base-ref carry-base
[ "$carry_rc" -eq 2 ] ||
    fail "a dirty tree must refuse the carry, got rc=$carry_rc: $carry_out"
[ "$(jq -r .head "$state")" = "$carry_old_head" ] ||
    fail "a refused carry must not touch the state: $(jq -c . "$state")"
git checkout -q -- feature.txt

echo "==> a rebased head refuses the carry"
# The rewritten commits carry the same content, but the objects the review was
# attributed to are no longer on the branch. #752 specifies merge-only.
carry_setup
carry_clean_cycle
git checkout -q -B carry-rebase carry-base
printf 'feature\n' >feature.txt
git add feature.txt
git commit -q -m "feat: the proposed change"
carry_rebased_head="$(git rev-parse HEAD)"
git checkout -q carry-pr
run_carry --new-head "$carry_rebased_head" --base-ref carry-base
[ "$carry_rc" -eq 2 ] ||
    fail "a rebase must refuse the carry, got rc=$carry_rc: $carry_out"
[ "$(jq -r .head "$state")" = "$carry_old_head" ] ||
    fail "a refused carry must not touch the state: $(jq -c . "$state")"

echo "==> a head with no terminal-clean result refuses the carry"
carry_setup
new_cycle_at "$carry_old_head"
run_carry --new-head "$carry_new_head" --base-ref carry-base
[ "$carry_rc" -eq 2 ] ||
    fail "an unproven head must refuse the carry, got rc=$carry_rc: $carry_out"
[ "$(jq -r .head "$state")" = "$carry_old_head" ] ||
    fail "a refused carry must not touch the state: $(jq -c . "$state")"

echo "==> a findings result cannot be carried as if it were clean"
carry_setup
new_cycle_at "$carry_old_head"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$carry_old_head" \
    '[[
      {
        id:140,user:{id:$id,login:$login},
        submitted_at:"2026-07-31T08:00:04Z",
        commit_id:$head,
        body:"### Codex Review\n\nP1: the rollback path loses data."
      }
    ]]' >"${fixtures}/reviews.pages.json"
run_check '2026-07-31T08:01:00Z'
assert_status 10 findings
[ "$(jq -r .last_result "$state")" = "findings" ] ||
    fail "a findings verdict must be recorded: $(jq -c . "$state")"
run_carry --new-head "$carry_new_head" --base-ref carry-base
[ "$carry_rc" -eq 2 ] ||
    fail "a findings verdict must refuse the carry, got rc=$carry_rc: $carry_out"

echo "shepherd Codex cloud-review classifier: PASS"

# The recorded clean result is a cache; Codex can post after it. A delayed
# old-head finding would become unreachable the moment the head moves, so any
# bot activity newer than the recorded result refuses the carry
# (devkit challenge round 2).
echo "==> bot activity newer than the recorded clean result refuses the carry"
carry_setup
carry_clean_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$carry_old_head" \
    '[[
      {
        id:140,user:{id:$id,login:$login},
        created_at:"2026-07-31T09:30:00Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:150,
        body:"P1: a delayed finding on the old head"
      }
    ]]' >"${fixtures}/inline.pages.json"
run_carry --new-head "$carry_new_head" --base-ref carry-base
[ "$carry_rc" -eq 2 ] ||
    fail "newer bot activity must refuse the carry, got rc=$carry_rc: $carry_out"
[ "$(jq -r .head "$state")" = "$carry_old_head" ] ||
    fail "a refused stale carry must not touch the state: $(jq -c . "$state")"
printf '%s\n' '[[]]' >"${fixtures}/inline.pages.json"

# cksum hashes empty input to a perfectly good value, so two empty diffs would
# have compared equal and carried a verdict onto a PR that proposes nothing
# (devkit challenge round 2).
echo "==> an empty diff refuses the carry instead of hashing to a match"
carry_setup
carry_clean_cycle
git checkout -q carry-base
git merge -q --no-edit carry-pr
git checkout -q carry-pr
git merge -q --no-edit carry-base
carry_empty_head="$(git rev-parse HEAD)"
run_carry --new-head "$carry_empty_head" --base-ref carry-base
[ "$carry_rc" -eq 2 ] ||
    fail "an empty diff must refuse the carry, got rc=$carry_rc: $carry_out"
printf '%s' "$carry_out" | grep -Fq "empty diff" ||
    fail "an empty-diff refusal must say so: $carry_out"

# A carried head is a new cycle and gets a new clock: inheriting a spent
# reservation would leave the mandatory post-merge check seconds of budget
# (devkit challenge round 2).
echo "==> a carry resets the reservation clock for the new head"
carry_setup
carry_clean_cycle
run_carry --new-head "$carry_new_head" --base-ref carry-base
[ "$carry_rc" -eq 0 ] || fail "carry should have succeeded: $carry_out"
[ "$(jq -r .attempt "$state")" = "1" ] ||
    fail "a carry must reset the attempt: $(jq -c . "$state")"
[ "$(jq -r '.timeout_min // "null"' "$state")" = "null" ] ||
    fail "a carry must clear an adopted timeout: $(jq -c . "$state")"
[ "$(jq -r .reserved_at "$state")" != "$request_time" ] ||
    fail "a carry must restart the reservation clock: $(jq -c . "$state")"

# The carry cutoff is the check's SNAPSHOT time, not its record time: evidence
# that arrives mid-fetch is absent from what was classified yet timestamped
# before any post-verdict clock (devkit challenge round 3).
echo "==> an edited old-head finding refuses the carry"
carry_setup
carry_clean_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$carry_old_head" \
    '[[
      {
        id:141,user:{id:$id,login:$login},
        created_at:"2026-07-31T07:00:00Z",updated_at:"2026-07-31T09:45:00Z",
        commit_id:$head,original_commit_id:$head,pull_request_review_id:151,
        body:"P1: edited in place after the clean check"
      }
    ]]' >"${fixtures}/inline.pages.json"
run_carry --new-head "$carry_new_head" --base-ref carry-base
[ "$carry_rc" -eq 2 ] ||
    fail "an edited old-head finding must refuse the carry, got rc=$carry_rc: $carry_out"
printf '%s\n' '[[]]' >"${fixtures}/inline.pages.json"

# A 👀 from an overlapping attempt means a review is still running against the
# old head; carrying past it would put its findings out of reach.
echo "==> a newer trigger reaction refuses the carry"
carry_setup
carry_clean_cycle
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    '[[
      {
        user:{id:$id,login:$login},
        content:"eyes",created_at:"2026-07-31T09:50:00Z"
      }
    ]]' >"${fixtures}/reactions.pages.json"
run_carry --new-head "$carry_new_head" --base-ref carry-base
[ "$carry_rc" -eq 2 ] ||
    fail "a newer trigger reaction must refuse the carry, got rc=$carry_rc: $carry_out"
printf '%s\n' '[[]]' >"${fixtures}/reactions.pages.json"

echo "==> a state without a recorded snapshot refuses the carry"
carry_setup
carry_clean_cycle
jq 'del(.last_snapshot_at)' "$state" >"${state}.next"
mv "${state}.next" "$state"
run_carry --new-head "$carry_new_head" --base-ref carry-base
[ "$carry_rc" -eq 2 ] ||
    fail "a snapshotless state must refuse the carry, got rc=$carry_rc: $carry_out"

# Attempt 2 keeps attempt 1's trigger live, and `check` reads both — so a late
# reaction on the FIRST trigger means that review is still running
# (devkit review round 1).
echo "==> a newer reaction on the previous attempt's trigger refuses the carry"
carry_setup
carry_clean_cycle
jq --arg prev "9911" '.previous_trigger_comment_id = ($prev | tonumber)' \
    "$state" >"${state}.next"
mv "${state}.next" "$state"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    '[[
      {
        user:{id:$id,login:$login},
        content:"eyes",created_at:"2026-07-31T09:55:00Z"
      }
    ]]' >"${fixtures}/reactions-9911.pages.json"
run_carry --new-head "$carry_new_head" --base-ref carry-base
[ "$carry_rc" -eq 2 ] ||
    fail "a newer previous-trigger reaction must refuse the carry, got rc=$carry_rc: $carry_out"
rm -f "${fixtures}/reactions-9911.pages.json"

# One-second GitHub precision plus clock skew makes an equal timestamp
# ambiguous; ambiguity refuses (devkit review round 1).
echo "==> activity inside the snapshot's own second refuses the carry"
carry_setup
carry_clean_cycle
carry_snapshot="$(jq -r .last_snapshot_at "$state")"
jq -cn \
    --argjson id "$actor_id" \
    --arg login "$actor_login" \
    --arg head "$carry_old_head" \
    --arg at "$carry_snapshot" \
    '[[
      {
        id:142,user:{id:$id,login:$login},
        created_at:$at,updated_at:$at,
        commit_id:$head,original_commit_id:$head,pull_request_review_id:152,
        body:"P1: landed inside the snapshot second"
      }
    ]]' >"${fixtures}/inline.pages.json"
run_carry --new-head "$carry_new_head" --base-ref carry-base
[ "$carry_rc" -eq 2 ] ||
    fail "same-second activity must refuse the carry, got rc=$carry_rc: $carry_out"
printf '%s\n' '[[]]' >"${fixtures}/inline.pages.json"
