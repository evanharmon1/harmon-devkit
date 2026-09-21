#!/usr/bin/env bash
# Persist and classify current-head Codex cloud-review evidence.
#
# This helper never writes to GitHub. The caller owns the explicit
# `@codex review` comment between `reserve` and `attach`.
#
# Exit codes from `check`:
#   0  clean
#   10 findings
#   11 pending
#   12 retry (attempt 1 timed out)
#   13 escalate (attempt 2 timed out)
#   14 PR no longer open — GitHub answered and the PR is MERGED or CLOSED;
#      terminal for the whole shepherd stage, never a wait-and-retry
#   15 quota exhausted — the reviewer answered that it will NOT review this
#      head: the finder replied to the trigger that its code-review usage
#      limit is spent (harmon-devkit#573). Terminal non-result, never clean
#      and never findings. Stop and report the blocker, naming the reset time
#      where the reply carried one. Both `reserve --attempt 2` AND a fresh
#      `--attempt 1` on the same head are refused — the one bounded
#      re-trigger must not be spent on a reviewer that already said no, and
#      there is deliberately no second same-head reservation route. So this
#      head is not reviewable through this helper again: push a new commit,
#      or have an operator remove this state file. A safe recovery route is
#      carried in #1115.
#   16 transient read — an evidence READ failed (harmon-devkit#508). Distinct
#      from 12/13, which mean the reviewer's window elapsed with no verdict:
#      nothing here says anything about the reviewer, so the caller retries
#      the READ rather than the reviewer cycle, and a gate maps it to
#      indeterminate-with-reason rather than to a not-clean failure.
#   2  indeterminate — malformed, changed head, usage error, or a
#      current-head verdict whose shape cannot be classified
#
# 15 and 16 are ADDITIONS: 0/10/11/12/13/14/2 keep their exact meanings, so a
# caller pinned to the older contract still reads every code it knew.
#
# `settle` records the disposition of a finding that lives OUTSIDE an
# inline thread — a top-level conversation comment or a review body — because
# those two surfaces carry no reply linkage, so the in-thread adjudication path
# can never reach them and `check` would report `findings` for them forever.
# Its domain is everything `check` blocks on (`verdict_class == "findings"`),
# not only badged bodies: a body misread as a finding must stay answerable, or
# the misread strands the head instead of costing one recorded disposition.
#
# `reserve` creates the state a cycle runs on; `reap` is the other half of that
# lifecycle. Nothing else removes a state file — a shepherded PR is still open
# when its session stops, so a cycle can never reap its own state, and without
# a sweep the directory grows by one file per PR forever. `reap` exits 0 for a
# completed sweep whatever it found — kept and skipped entries are results, not
# failures, so a caller can run it unconditionally — and 2 only when it cannot
# complete a sweep at all (usage error, unusable root).

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage:
  check-codex-cloud-review.sh reserve --state FILE --repo OWNER/REPO --pr N --head SHA --attempt 1|2 [--finder SLUG]
  check-codex-cloud-review.sh attach --state FILE --trigger-id N
  check-codex-cloud-review.sh attach --state FILE --requested-at ISO8601
  check-codex-cloud-review.sh check --state FILE [--actor-id N] [--actor-login LOGIN] [--timeout-min N] [--now ISO8601]
  check-codex-cloud-review.sh settle --state FILE --actor-id N --surface comment|review --id N --disposition declined|filed --note TEXT [--covers N] [--now ISO8601]
  check-codex-cloud-review.sh show --state FILE
  check-codex-cloud-review.sh reap --root DIR [--budget-sec N]

When --finder is given on reserve, actor identity and verdict classification
are driven by the finder's profile in the trusted registry (C1-C3).

`check` exits 0 clean, 10 findings, 11 pending, 12 retry, 13 escalate,
14 PR no longer open, 15 quota exhausted, 16 transient read,
2 indeterminate. Exit 15 is terminal for the HEAD, not just the cycle: no
same-head reservation is accepted afterwards, so recovery is a new commit or
an operator removing the state file (see #1115). Exit 14 means GitHub answered and
the PR is MERGED or CLOSED: terminal for the whole shepherd stage — stop,
never wait, re-run, or re-trigger. A PR fetch that FAILS is exit 16, a
transient READ failure — retry the read, not the reviewer cycle; only a
non-open answer is 14. Exit 15 means the finder answered that its review
quota is spent. It is terminal for the HEAD, not just the cycle: `reserve
--attempt 2` is refused, and so is a fresh `--attempt 1` on the same head, so
nothing re-reviews that commit through this helper. Recover by pushing a new
commit, or have an operator remove the cycle state file
(`git rev-parse --git-path integrate-codex/<owner>/<repo>/<n>.json`).
A safe recovery route is carried in #1115.
`reserve` and `attach` refuse a non-open PR outright,
exit 2 with a reason naming the reported state.

State locks are never reclaimed automatically. On lock-held, inspect the
reported PID and age; removing a lock directory is an explicit human recovery
action performed outside this helper.
EOF
    exit 2
}

die() {
    printf 'codex-cloud-review: %s\n' "$*" >&2
    exit 2
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

need gh
need jq

timeout_bin=
if command -v timeout >/dev/null 2>&1; then
    timeout_bin=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=gtimeout
else
    die "GNU timeout is required (coreutils; gtimeout on macOS)"
fi

command_name="${1:-}"
[ -n "$command_name" ] || usage
shift

state_file=
root_dir=
repo=
pr=
head=
attempt=
trigger_id=
actor_id=
actor_login='chatgpt-codex-connector[bot]'
timeout_min=15
timeout_min_set=0
timeout_min_adopted=0
now=
surface=
target_id=
disposition=
note=
covers=
lock_dir=
reap_entries=
reap_lock=
reap_budget_sec=60
reap_deadline_epoch=
finder_slug=
requested_at_arg=
# harmon-devkit#573: the finder's usage-limit reply, once `check` has seen it.
# Empty until the comment surface has actually been fetched and scanned, which
# is what keeps the pre-evidence failure paths behaving exactly as before.
quota_comment_id=
quota_detected_at=
quota_reset_at=
# harmon-devkit#655: whether the current attempt's trigger still carries the
# finder's pending reaction (👀). Empty/0 until the reaction surface has been
# fetched, for the same reason.
pending_reaction_live=0
# harmon-devkit#573: the reset time a usage-limit reply may carry. Since
# challenge round 2 deleted the reset-time carve-out, NO CONTROL FLOW READS
# THIS — it is context for the human reading the blocker and nothing else, and
# it must stay that way: the head accepts no further reservation whatever the
# reset time says, so branching on it again would rebuild exactly the
# carve-out that round 2 removed (findings `challenge-r2-codex-adversarial-5`
# and `-6`). It is still extracted and persisted because "the quota resets at
# X" is genuinely useful to whoever decides when a fresh push is worth making.
# The recovery route itself is carried in #1115.
# harmon-devkit#655: the hard ceiling a live pending reaction may extend the
# attempt window to, measured from the trigger. A reviewer that is visibly
# working is not absent, but it cannot hold a PR open forever either.
eyes_ceiling_min=30

while [ "$#" -gt 0 ]; do
    case "$1" in
    --state | --root | --repo | --pr | --head | --attempt | --trigger-id | --actor-id | --actor-login | --timeout-min | --budget-sec | --now | --surface | --id | --disposition | --note | --covers | --finder | --requested-at)
        [ "$#" -ge 2 ] || usage
        case "$1" in
        --state) state_file=$2 ;;
        --root) root_dir=$2 ;;
        --repo) repo=$2 ;;
        --pr) pr=$2 ;;
        --head) head=$2 ;;
        --attempt) attempt=$2 ;;
        --trigger-id) trigger_id=$2 ;;
        --actor-id) actor_id=$2 ;;
        --actor-login) actor_login=$2 ;;
        --finder) finder_slug=$2 ;;
        --requested-at) requested_at_arg=$2 ;;
        --timeout-min)
            timeout_min=$2
            timeout_min_set=1
            ;;
        --budget-sec) reap_budget_sec=$2 ;;
        --now) now=$2 ;;
        --surface) surface=$2 ;;
        --id) target_id=$2 ;;
        --disposition) disposition=$2 ;;
        --covers) covers=$2 ;;
        --note) note=$2 ;;
        esac
        shift 2
        ;;
    *) usage ;;
    esac
done

# `reap` sweeps a directory rather than operating on one state file, so the
# required argument differs by subcommand. An unknown command falls through to
# the `*)` arm of the dispatch below, which is `usage` anyway.
case "$command_name" in
reap) [ -n "$root_dir" ] || usage ;;
*) [ -n "$state_file" ] || usage ;;
esac
valid_repo() {
    grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' <<<"$1"
}

valid_uint() {
    grep -Eq '^[1-9][0-9]*$' <<<"$1"
}

valid_sha() {
    grep -Eq '^[0-9a-fA-F]{40}$' <<<"$1"
}

valid_slug() {
    grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$' <<<"$1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

valid_time() {
    grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' <<<"$1"
}

# Challenge round 1, item A (2026-09-20, confirmed P1): `--now` is validated
# HERE, once, before any command runs — not inside the functions that consume
# it. Those validations happen only after the first GitHub read, and one of
# them (`clock_epoch`, for the harmon-devkit#737 fetch budget) is called from
# inside a command substitution, where `die` kills the subshell rather than the
# script: `current_epoch=$(clock_epoch) || return 1` then made `run_gh` fail,
# `provider_head` fail, and the caller report **exit 16** (a transient read).
# A permanent usage error therefore rendered as the one exit class with no
# escalation path — the gate repeats the read and the integrator poll loop
# treats it like `11`, so a malformed flag would be retried forever instead of
# being reported.
#
# `injected_now_epoch` is resolved once here too, so no consumer needs to shell
# out per call and no arithmetic path can fail mid-read. A parse failure at
# this point is a startup `die` (exit 2), which is what a bad argument deserves.
injected_now_epoch=
if [ -n "$now" ]; then
    valid_time "$now" || die "--now must be an ISO-8601 UTC second"
    injected_now_epoch=$(jq -nr --arg value "$now" '$value | fromdateiso8601') ||
        die "--now is not a resolvable instant: $now"
fi

# harmon-devkit#223: the timeout governing an attempt cycle used to live only
# in whatever `--timeout-min` a caller happened to pass, so `check
# --timeout-min 10` could return `retry` after ten minutes while the
# documented attempt-2 `reserve` — which takes no timeout of its own — was
# still enforcing the 15-minute default window for another five. The fix
# distinguishes ABSENCE (no command has ever chosen a timeout for this cycle)
# from a PERSISTED CHOICE (one has), and only the latter is authoritative:
#
#   - persisted is a number: that value governs. An explicit --timeout-min
#     that disagrees is a usage error (a second vote), not a silent switch.
#   - persisted is absent/null and --timeout-min was NOT passed: fall back to
#     the unmodified 15-minute default, unpersisted — still no choice made.
#   - persisted is absent/null and --timeout-min WAS passed: ADOPT it. This
#     is the documented convention itself — `reserve` (no flag) followed by
#     `check --timeout-min 10` must keep working, so the first explicit value
#     any command supplies for an otherwise-undecided cycle becomes that
#     cycle's timeout from here on. The caller persists the adoption
#     (`timeout_min_adopted=1` signals it must write `.timeout_min` back)
#     rather than this function, because writing state requires the caller's
#     already-held lock and read state file.
#
# Adopting is safe to do retroactively (not just before any `check` has run)
# because nothing about a `check` verdict is durable: every command
# re-derives `elapsed` from `requested_at` and `timeout_min` fresh, on its own
# invocation, against the real clock. There is no cached "attempt 1 timed
# out" decision anywhere in state for a later adoption to contradict — only
# `requested_at` (fixed at attachment) and `timeout_min` (this cycle's
# budget) are persisted, and adoption keeps those two mutually consistent for
# every command that reads them afterward. The one case that DOES get a
# second vote is two conflicting EXPLICIT flags — that is not absence
# resolving, it is genuine disagreement about the cycle's timeout, so it
# stays a `die`.
#
# `$1` is the raw `.timeout_min` from the state file: empty both for state
# written before this field existed (no key at all) and for a cycle that has
# never had an explicit choice adopted into it (the key is present as JSON
# `null`) — `jq -r '.timeout_min // empty'` collapses both to the empty
# string, and this function treats them identically, which is the point:
# neither has made a durable choice yet.
resolve_timeout_min() {
    persisted=$1
    timeout_min_adopted=0
    if [ -n "$persisted" ]; then
        valid_uint "$persisted" ||
            die "state has an invalid timeout_min: $persisted"
        # harmon-devkit#223: canonicalize both sides to base-10 before
        # comparing or persisting. `valid_uint`'s `[1-9][0-9]*` pattern
        # already forbids a leading zero on the EXPLICIT flag, and jq already
        # normalizes one out of a value it reads back from JSON, so neither
        # side can carry one into this function today — but a string
        # equality test comparing "10" against a differently-spelled-but-equal
        # value would falsely conflict if that ever changed (a looser regex,
        # a different jq, a hand-edited state file), and forcing `$((10#x))`
        # is cheap insurance against relying on that staying true. `10#` (not
        # a bare `-eq`) matters here specifically because bash arithmetic
        # treats an actual leading zero as OCTAL — `[ 010 -eq 8 ]` is true —
        # so an unguarded `-eq` would silently compare the wrong canonical
        # number instead of failing safe.
        persisted=$((10#$persisted))
        if [ "$timeout_min_set" = 1 ]; then
            explicit=$((10#$timeout_min))
            [ "$explicit" -eq "$persisted" ] ||
                die "--timeout-min $timeout_min conflicts with the ${persisted}-minute timeout already persisted for this attempt cycle"
        fi
        timeout_min=$persisted
    elif [ "$timeout_min_set" = 1 ]; then
        # $timeout_min already holds the explicit flag's value from arg
        # parsing; canonicalize it for the same reason as above before the
        # caller persists it.
        timeout_min=$((10#$timeout_min))
        timeout_min_adopted=1
    else
        timeout_min=15
    fi
}

# Persists an adoption `resolve_timeout_min` flagged via `timeout_min_adopted`.
# Must run inside the caller's existing state lock, after `resolve_timeout_min`
# and before any command relying on `timeout_min` returns — an adoption that
# is never written back would silently revert to "undecided" on the next
# invocation, reopening the inconsistent-windows bug this whole change exists
# to close.
persist_adopted_timeout() {
    [ "$timeout_min_adopted" = 1 ] || return 0
    payload=$(jq --argjson timeout_min "$timeout_min" \
        '.version = 2 | .timeout_min = $timeout_min' "$state_file")
    write_state "$state_file" "$payload"
}

now_utc() {
    if [ -n "$now" ]; then
        valid_time "$now" || die "--now must be an ISO-8601 UTC second"
        printf '%s' "$now"
    else
        date -u '+%Y-%m-%dT%H:%M:%SZ'
    fi
}

# harmon-devkit#737 defect 2: the per-call fetch budget is computed against
# the cycle's reservation, and it used the real wall clock for "now" while
# every other time comparison in this helper honours `--now`. After a long
# adjudication between `attach` and `check`, wall clock had already passed
# the window, so `run_gh` clamped every request to one second and a review
# that was unchanged and fully answered read as absent — `retry`/`pending`
# for evidence that was sitting right there. The lane's workaround was to
# reserve attempt 2 purely to buy a fresh budget, which posted a redundant
# trigger.
#
# One clock for the whole invocation is the fix: when `--now` is supplied it
# is authoritative for the budget exactly as it already is for `bounded_wait`
# and `require_latest_window_elapsed`, so an injected clock makes the budget
# reproducible instead of decaying in real time. Without `--now` this is the
# unchanged `date -u '+%s'`.
# Called from inside a command substitution, so it must never `die`: item A
# above resolved and validated the injected clock at startup precisely so this
# function is a pure echo with no failure mode of its own.
clock_epoch() {
    if [ -n "$injected_now_epoch" ]; then
        printf '%s' "$injected_now_epoch"
    else
        date -u '+%s'
    fi
}

# A disposition is recorded against the exact text it answered, so an edited
# finding stops being settled. The body is hashed in its JSON-ENCODED form:
# command substitution strips trailing newlines, and the encoded string keeps
# them (and every other whitespace edit) inside the value being hashed. The
# edit timestamp rides along where the surface exposes one — reviews expose
# only `submitted_at`, so for them the body hash is the whole of the evidence.
# `cksum` rather than a digest tool: it is POSIX, ships everywhere this helper
# already runs, and this is change detection between two co-operating reads of
# the same API, not a defence against a forged body.
content_fingerprint() {
    body_json=$1
    edited_at=$2
    body_sum=$(printf '%s' "$body_json" | cksum | tr ' ' '-') ||
        die "cannot fingerprint a review body"
    printf '%s|%s' "$edited_at" "$body_sum"
}

# Fetch the PR and print its head SHA, distinguishing three outcomes the
# callers must never conflate (harmon-devkit#389: piping the fetch into
# `jq 'select(.state == "OPEN")'` made "the PR merged mid-cycle" exit
# identically to "the fetch failed", so `check` routed an externally
# merged PR to `bounded_wait` and polled out the rest of its window on a
# dead PR):
#   0 — the PR is OPEN; its headRefOid is on stdout.
#   3 — GitHub answered and the PR is NOT open; the reported state
#       (MERGED/CLOSED) is on stdout. Terminal, never a wait-and-retry.
#   1 — the fetch failed or returned an unusable payload. Transient; `check`
#       routes this to `transient_read_failure` (exit 16, harmon-devkit#508),
#       `reserve`/`attach` still `die`. What it must never become is a
#       window-elapsed retry: the read said nothing about the reviewer.
# Always called via command substitution, so stdout carries the head (rc 0)
# or the non-open state (rc 3) and nothing leaks into the caller's scope.
provider_head() {
    provider_payload=$(run_gh pr view "$1" --repo "$2" \
        --json headRefOid,state) || return 1
    provider_state=$(printf '%s' "$provider_payload" |
        jq -er 'select(type == "object") | .state |
            select(type == "string" and . != "")') || return 1
    if [ "$provider_state" != "OPEN" ]; then
        printf '%s' "$provider_state"
        return 3
    fi
    printf '%s' "$provider_payload" |
        jq -er '.headRefOid | select(type == "string" and . != "")' ||
        return 1
}

run_gh() {
    call_timeout=60
    window_anchor=${state_requested:-${state_reserved:-}}
    if [ -n "$window_anchor" ] && valid_time "$window_anchor"; then
        anchor_epoch=$(jq -nr \
            --arg value "$window_anchor" '$value | fromdateiso8601') ||
            return 1
        current_epoch=$(clock_epoch) || return 1
        remaining=$((anchor_epoch + timeout_min * 60 - current_epoch))
        if [ "$remaining" -le 0 ]; then
            # A post-window check still owes one terminal evidence sweep. Give
            # that sweep an independent normal request budget; reducing every
            # call to one second here makes a completed remote review look
            # absent precisely when the checker is deciding its final result.
            if [ "$command_name" != "check" ]; then
                call_timeout=1
            fi
        elif [ "$remaining" -lt "$call_timeout" ]; then
            # Challenge round 3, finding `challenge-r3-codex-adversarial-9`
            # (confirmed P2): the carve-out above covered `remaining <= 0` but
            # not the last minute before it, so a `check` landing inside the
            # final 59 seconds of its window clamped every read to a
            # sub-second budget and reported readable evidence absent — the
            # same failure the carve-out exists to prevent, one minute
            # earlier. `check` keeps its full budget on both sides of the
            # boundary now; the clamp still applies to every other command,
            # which has no terminal sweep to owe.
            if [ "$command_name" != "check" ]; then
                call_timeout=$remaining
            fi
        fi
    elif [ -n "${reap_deadline_epoch:-}" ]; then
        # A sweep has no reservation to budget against, so without this every
        # call would get the flat 60s and a sequential sweep of N entries could
        # spend N minutes before the work that matters begins.
        remaining=$((reap_deadline_epoch - $(date -u '+%s')))
        if [ "$remaining" -le 0 ]; then
            call_timeout=1
        elif [ "$remaining" -lt "$call_timeout" ]; then
            call_timeout=$remaining
        fi
    fi
    "$timeout_bin" -k 1 "$call_timeout" gh "$@"
}

write_state() {
    destination=$1
    payload=$2
    parent=$(dirname "$destination")
    mkdir -p "$parent"
    temporary=$(mktemp "${destination}.tmp.XXXXXX") ||
        die "cannot create temporary state beside $destination"
    if printf '%s\n' "$payload" >"$temporary"; then
        chmod 600 "$temporary"
        mv "$temporary" "$destination"
    else
        rm -f "$temporary"
        die "cannot write $destination"
    fi
}

# Every field `settle` writes is validated here, not just the pair that
# identifies the target. A settlement is the record that a human adjudicated a
# finding, so an entry missing its disposition or its note is not a weaker
# record — it is no record at all, and honouring one would let `check` report
# clean with nothing behind it. Corrupted or hand-reconstructed state must
# reach the malformed-state refusal instead.
#
# Version 2 added `settled`. A version-1 file is read as if it were empty and
# is REWRITTEN as version 2 by the next command that writes it, so an in-flight
# cycle survives the upgrade. A version this helper has never heard of is
# refused outright rather than read optimistically: an unknown field could carry
# exactly the evidence a newer writer expects this one to honour.
read_state() {
    [ -f "$state_file" ] || die "state file does not exist: $state_file"
    state_version=$(jq -r 'select(type == "object") | .version | tostring' \
        "$state_file" 2>/dev/null) || die "malformed state file: $state_file"
    case "$state_version" in
    1 | 2) ;;
    *) die "state file is version $state_version, which this helper does not understand: $state_file" ;;
    esac
    jq -e '
      type == "object" and
      (.version == 1 or .version == 2) and
      (.settled == null or ((.settled | type == "array") and
        (.settled | all(type == "object" and
          ((.surface == "comment") or (.surface == "review")) and
          (.id | type == "number") and
          ((.disposition == "declined") or (.disposition == "filed")) and
          (.note | type == "string") and ((.note | length) > 0) and
          (.content_fingerprint | type == "string") and
          ((.content_fingerprint | length) > 0) and
          (.attempt == null or .attempt == 1 or .attempt == 2) and
          (.settled_at | type == "string"))))) and
      (.repo | type == "string") and
      (.pr | type == "number") and
      (.head | type == "string") and
      (.attempt == 1 or .attempt == 2) and
      (.phase == "reserved" or .phase == "attached") and
      (.requires_full_window == null or
        (.requires_full_window | type == "boolean")) and
      (.previous_trigger_comment_id == null or
        (.previous_trigger_comment_id | type == "number" and . > 0)) and
      (.timeout_min == null or (.timeout_min | type == "number")) and
      (.quota_exhausted_at == null or (.quota_exhausted_at | type == "string")) and
      (.quota_reset_at == null or (.quota_reset_at | type == "string")) and
      (.quota_comment_id == null or
        (.quota_comment_id | type == "number" and . > 0)) and
      (.boundary_source == null or
        (.boundary_source == "check-suite" or .boundary_source == "commit-date")) and
      (.commit_date_boundary == null or (.commit_date_boundary | type == "string")) and
      (.check_suite_boundary == null or (.check_suite_boundary | type == "string"))
    ' "$state_file" >/dev/null || die "malformed state file: $state_file"
}

acquire_state_lock() {
    parent=$(dirname "$state_file")
    mkdir -p "$parent"
    lock_dir="${state_file}.lock"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        lock_pid=$(cat "$lock_dir/pid" 2>/dev/null || true)
        lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null ||
            stat -f %m "$lock_dir" 2>/dev/null || true)
        lock_now=$(date -u '+%s')
        lock_age=unknown
        if grep -Eq '^[0-9]+$' <<<"$lock_mtime" &&
            [ "$lock_now" -ge "$lock_mtime" ]; then
            lock_age="$((lock_now - lock_mtime))s"
        fi
        lock_holder=${lock_pid:-unknown}
        die "lock-held: holder_pid=$lock_holder age=$lock_age; inspect and remove manually only when safe"
    fi
    printf '%s\n' "$$" >"$lock_dir/pid" || {
        rmdir "$lock_dir" 2>/dev/null || true
        die "cannot record the state-lock holder PID"
    }
    trap 'rm -f "$lock_dir/pid"; rmdir "$lock_dir" 2>/dev/null || true' EXIT
}

release_state_lock() {
    rm -f "$lock_dir/pid"
    rmdir "$lock_dir" 2>/dev/null || true
    lock_dir=
    trap - EXIT
}

# One ndjson line per swept candidate. Empty repo/pr/state become JSON null:
# a candidate this sweep declined to identify has no PR to report, and saying
# so is not the same as reporting it as PR 0 of the empty repository.
reap_record() {
    jq -cn \
        --arg path "$1" \
        --arg repo "$2" \
        --arg pr "$3" \
        --arg state "$4" \
        --arg action "$5" \
        --arg detail "$6" \
        '{
          path:$path,
          repo:(if $repo == "" then null else $repo end),
          pr:(if $pr == "" then null else (try ($pr | tonumber) catch null) end),
          state:(if $state == "" then null else $state end),
          action:$action,
          detail:$detail
        }' >>"$reap_entries"
}

# `$5`, when given, is a JSON OBJECT of extra fields merged into the result —
# additive only, so every existing key keeps its shape and a caller pinned to
# the older output reads exactly what it did before. harmon-devkit#737 uses it
# to enumerate every unanswered inline thread alongside the `findings` verdict,
# because one accepted review id cannot name findings that came from two.
emit() {
    result=$1
    detail=$2
    surface=${3:-}
    accepted_id=${4:-}
    extra=${5:-}
    jq -cn \
        --arg status "$result" \
        --arg detail "$detail" \
        --arg head "${state_head:-}" \
        --argjson attempt "${state_attempt:-0}" \
        --arg surface "$surface" \
        --arg accepted_id "$accepted_id" \
        --argjson extra "${extra:-null}" \
        '{status:$status,detail:$detail,head:$head,attempt:$attempt}
         + (if $surface != "" and $accepted_id != "" then
              {accepted:{surface:$surface,id:$accepted_id,reviewed_commit:$head}}
            else {} end)
         + (if ($extra | type) == "object" then $extra else {} end)'
}

# harmon-devkit#508: an evidence READ that failed says nothing about the
# reviewer. Routing it through `bounded_wait` conflated the two, and because
# `bounded_wait` compares against `requested_at` — always long past for a gate
# re-checking a settled cycle — one flaky GitHub read turned an
# adjudicated-clean cycle into a hard retry. This is its own terminal-shaped
# answer with its own exit code, and the caller's remedy is to repeat the
# READ, not to re-trigger a reviewer that was never absent.
#
# Deliberately NOT bounded by the attempt window: the window measures how long
# the reviewer has had, and this result is not about the reviewer at all.
transient_read_failure() {
    emit transient-read "$1"
    exit 16
}

# Records the usage-limit answer on the cycle's own state before reporting it,
# so `reserve --attempt 2` can refuse the one bounded re-trigger rather than
# spending it on a reviewer that has already said no. Runs under the caller's
# existing state lock, like `persist_adopted_timeout`.
persist_quota_evidence() {
    payload=$(jq \
        --argjson comment_id "$quota_comment_id" \
        --arg detected "$quota_detected_at" \
        --arg reset "$quota_reset_at" \
        '.version = 2 |
         .quota_comment_id = $comment_id |
         .quota_exhausted_at = $detected |
         .quota_reset_at = (if $reset == "" then null else $reset end)' \
        "$state_file") || die "cannot record the usage-limit answer"
    write_state "$state_file" "$payload"
}

bounded_wait() {
    detail=$1
    if [ -z "$now" ]; then
        now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    fi
    valid_time "$now" || die "--now must be an ISO-8601 UTC second"
    # harmon-devkit#573: the finder answering "I will not review this" is an
    # ANSWER, not silence, so it must never be reported as waiting. Every path
    # that would otherwise wait runs through here, which is exactly why the
    # check lives here rather than at one call site: the quota reply is
    # invisible to every classifier above (it carries no `Reviewed commit`
    # line, no verdict sentence and no badge), so absence of other evidence is
    # the only state it can ever be observed in. It is checked FIRST because
    # it is terminal — a live 👀 alongside an exhausted quota is still a
    # reviewer that is not going to answer.
    #
    # `$quota_comment_id` is empty on every pre-evidence failure path, so those
    # keep their previous behaviour (and #508 has already moved read failures
    # off this function entirely).
    if [ -n "$quota_comment_id" ]; then
        persist_quota_evidence
        quota_detail="$detail; the finder replied that its code-review usage limit is exhausted (comment $quota_comment_id)"
        if [ -n "$quota_reset_at" ]; then
            quota_detail="$quota_detail; limit resets at $quota_reset_at"
        else
            quota_detail="$quota_detail; the reply named no reset time"
        fi
        # Challenge round 3, finding `challenge-r3-codex-adversarial-11`
        # (confirmed P2): after the reset-time carve-out was deleted in round
        # 2, every operator-facing string still implied the reset time was
        # actionable and none named the route that actually exists. Name it.
        quota_detail="$quota_detail; this head cannot be re-reviewed here — push a new commit or have an operator remove this state file (recovery route carried in #1115)"
        emit quota-exhausted "$quota_detail"
        exit 15
    fi
    requested_epoch=$(jq -nr \
        --arg value "$state_requested" '$value | fromdateiso8601') ||
        die "cannot parse request time"
    now_epoch=$(jq -nr --arg value "$now" '$value | fromdateiso8601') ||
        die "cannot parse current time"
    [ "$now_epoch" -ge "$requested_epoch" ] ||
        die "--now predates the review request"
    elapsed=$((now_epoch - requested_epoch))
    timeout_seconds=$((timeout_min * 60))
    if [ "$elapsed" -lt "$timeout_seconds" ]; then
        emit pending "$detail"
        exit 11
    fi
    # harmon-devkit#655: the window must be bounded by evidence that the
    # reviewer is NOT working, never by wall clock alone. The finder signals
    # acceptance of a trigger with its pending reaction and replaces it with a
    # terminal result, so while that reaction is still on THIS attempt's
    # trigger the review is in progress and elapsing the window only forces a
    # redundant re-trigger — which the two-attempt contract then counts against
    # the head, turning a slow-but-live review into an escalation for a
    # reviewer that was never absent (observed on ponderousdev/omator#447).
    #
    # The extension is bounded by a hard ceiling from the trigger, because a
    # reaction that never resolves must not hold a PR open indefinitely: past
    # the ceiling this falls through to the unchanged retry/escalate below,
    # and so does a reaction that has VANISHED without a result (the caller
    # never set `pending_reaction_live`, so nothing extends).
    #
    # `max(ceiling, timeout)` so a caller that deliberately configured a
    # LONGER window than the ceiling is never cut short by it: the extension
    # may only ever add time.
    if [ "$pending_reaction_live" = "1" ]; then
        # Challenge round 5, finding `challenge-r5-codex-adversarial-8`
        # (confirmed P3): a `max(ceiling, timeout)` clamp used to sit here,
        # described by its own comment as stopping the ceiling from shortening
        # a longer configured window. It was dead code. Reaching this point
        # already requires `elapsed >= timeout_seconds`, so when the timeout
        # exceeds the ceiling the comparison below is false with or without
        # the clamp — it never changed an outcome. The property it claimed to
        # protect still holds; only the misleading code is gone.
        ceiling_seconds=$((eyes_ceiling_min * 60))
        if [ "$elapsed" -lt "$ceiling_seconds" ]; then
            emit pending "$detail; the finder's pending reaction is still live on this attempt's trigger, so the window is extended to ${eyes_ceiling_min} minutes from the trigger"
            exit 11
        fi
    fi
    if [ "$state_attempt" = "1" ]; then
        emit retry "$detail; attempt 1 window elapsed"
        exit 12
    fi
    emit escalate "$detail; both attempt windows elapsed"
    exit 13
}

require_latest_window_elapsed() {
    requires_full_window=$(jq -r '.requires_full_window // false' "$state_file")
    [ "$state_attempt" = "1" ] && [ "$requires_full_window" != "true" ] && return
    if [ -z "$now" ]; then
        now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    fi
    valid_time "$now" || die "--now must be an ISO-8601 UTC second"
    requested_epoch=$(jq -nr \
        --arg value "$state_requested" '$value | fromdateiso8601') ||
        die "cannot parse request time"
    now_epoch=$(jq -nr --arg value "$now" '$value | fromdateiso8601') ||
        die "cannot parse current time"
    [ "$now_epoch" -ge "$requested_epoch" ] ||
        die "--now predates the review request"
    elapsed=$((now_epoch - requested_epoch))
    timeout_seconds=$((timeout_min * 60))
    if [ "$elapsed" -lt "$timeout_seconds" ]; then
        emit pending "latest attempt window has not elapsed"
        exit 11
    fi
}

flatten_pages() {
    source_file=$1
    destination_file=$2
    jq -e '[.[] | if type == "array" then .[] else error("page is not an array") end]' \
        "$source_file" >"$destination_file"
}

fetch_pages() {
    endpoint=$1
    destination=$2
    raw="${destination}.pages"
    if ! run_gh api --paginate --slurp "$endpoint" >"$raw"; then
        return 1
    fi
    flatten_pages "$raw" "$destination" 2>/dev/null || return 2
}

fetch_evidence() {
    endpoint=$1
    destination=$2
    label=$3
    fetch_status=0
    fetch_pages "$endpoint" "$destination" || fetch_status=$?
    case "$fetch_status" in
    0) return ;;
    1) transient_read_failure "cannot fetch paginated $label" ;;
    *)
        emit indeterminate "paginated $label data is malformed"
        exit 2
        ;;
    esac
}

codex_verdict_defs=$(
    cat <<'JQDEFS'
          def clean_sentence:
            "codex review: didn't find any major issues.";
          def body_text: (.body // "");
          # `first // ""`, never `[0]`: jq's `"" | split("\n")` is `[]`, so an
          # empty body would pipe null into gsub and crash the whole program
          # with jq's own exit 5 — outside the documented code set
          # (harmon-devkit#392, hit live on harmon-init#766).
          def first_line:
            (body_text | split("\n") | first // "" |
              gsub("^[[:space:]]+|[[:space:]]+$"; "") | ascii_downcase);
          def has_severity_marker:
            (body_text | ascii_downcase | test("\\bp[0-9]+\\b"));
          # Integration remediation 1 (2026-09-14, Codex cloud review on
          # `a5bc99a`, confirmed finding `4010207997`): a bare `type ==
          # "number"` check on a provider-supplied id admits `0`, a negative
          # number, and a fraction like `1.5` — none of them a real GitHub
          # object id, all of them silently usable as the accepted evidence's
          # `accepted.id` once inside `newest_result_record`/
          # `comment_candidates`. Mirrors `valid_uint`'s bash-level shape
          # (positive, integral) inside jq. Deliberately not `% 1 == 0` as
          # the fractional-part test: jq's `%` truncates BOTH operands to
          # integers before dividing (`1.5 % 1` is `0`, not `0.5`), so it
          # would silently accept 1.5 as "integral" — comparing against
          # `floor` does not have that trap. `> 0` rejects zero and negative
          # values the same way `valid_uint`'s `[1-9][0-9]*` anchor does.
          def is_positive_integer:
            (type == "number") and (. == (. | floor)) and (. > 0);
          # Factored out of `rest_is_boilerplate` so the carrier defs below can
          # reuse the exact same removal and the exact same metadata pattern
          # instead of restating them. Same regexes, same flags, same order —
          # `rest_is_boilerplate` behaves identically to before the split.
          # Challenge round 3, finding `challenge-r3-codex-adversarial-1`
          # (confirmed P1, provenance ORIGINAL — this predates every round of
          # this change): the removal used to start at `<details`, so with one
          # benign collapsed section anywhere above the About block the match
          # ran from THAT tag through the About block's closing tag and deleted
          # every line in between — including a concern. It defeated the
          # clean-path safety net, `is_carrier_only`, and the round-2
          # whole-body self-report test, all three of which read the stripped
          # body.
          #
          # Anchored on the About SUMMARY instead, with `[^<]*` between the
          # tags so the match cannot span an intervening `<details` at all.
          # Same intent the original comment states — "removal is anchored on
          # the block's SUMMARY, not on `<details` alone" — now actually
          # enforced by the pattern.
          def strip_about_block:
            gsub("<details[^<]*<summary>[^<]*about codex[^<]*</summary>.*?</details>";
                 ""; "im");
          def is_reviewed_commit_line:
            test(
              "^\\*\\*reviewed commit:\\*\\*[[:space:]]*`[0-9a-f]{7,40}`[[:space:]]*$"
            );
          def rest_is_boilerplate:
            (body_text | split("\n") | .[1:] | join("\n") |
              strip_about_block |
              ascii_downcase | split("\n") |
              map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) |
              map(select(. != "")) |
              all(is_reviewed_commit_line));
          # The verdict line must OPEN with the clean sentence; whatever
          # Codex appends after it is stripped and plays no part in the
          # decision.
          #
          # Three earlier revisions tried to prove the trailing clause was
          # praise — by rejecting caveat shapes, then by requiring a praise
          # word, then by requiring every word to be recognised. Each looked
          # airtight and each was fail-OPEN within minutes of review
          # ("Tests fail on Windows.", "Nice work, tests crash on Windows.",
          # ":warning:", "Work on it."). The clause is free text that Codex
          # writes differently every time; it is not a channel that can be
          # parsed reliably, and the allowlist that preceded those attempts
          # could not converge either — seven distinct clauses, three inside
          # twenty-five minutes, and it deadlocked the PR that was fixing it.
          #
          # So the tail is not load-bearing. What decides the verdict is the
          # part of Codex's output that does NOT vary:
          #
          #   1. the verdict sentence itself, matched exactly;
          #   2. the absence of any severity badge ANYWHERE in the body —
          #      every finding Codex has ever posted here carried one,
          #      including the observed P3;
          #   3. every remaining line being Codex's own metadata.
          #
          # Inline comments on the current head are classified as findings
          # separately, before this runs.
          #
          # The residual, stated plainly: a concern that is unbadged, absent
          # from the inline comments, and appended to a sentence that says the
          # opposite would pass. That has never been observed — it requires
          # Codex to contradict itself mid-line — and this gate promotes a
          # draft to ready-for-review rather than merging, so a human still
          # reads the PR. That is a better trade than a parser that has been
          # wrong three times.
          # Used only by the review-settlement gate in `check`, but defined
          # here so they share `body_text`, the About-block removal, and the
          # Reviewed-commit pattern with `verdict_class` instead of growing a
          # parallel set of regexes that could drift apart. A findings review's
          # body is a CARRIER: a heading, one fixed sentence, and Codex's own
          # metadata, with the findings themselves in the inline comments.
          # Anything else in it is prose nobody has answered.
          #
          # These defs work off `carrier_lines`, NOT `first_line`, because a
          # real findings-review body begins with a BLANK LINE:
          # "\n### 💡 Codex Review\n\n…" is what #355 and #273 actually posted.
          # `first_line` is therefore empty for every genuine findings review,
          # and a heading test built on it can never match one — the gate would
          # be permanently inert, re-blocking every PR and reproducing the #275
          # deadlock from the fail-closed side.
          #
          # `first_line` itself is deliberately LEFT ALONE. It serves
          # `verdict_class`'s clean-verdict prefix test, and clean results are
          # top-level comments that open directly with the verdict sentence —
          # a different payload shape from these review bodies, with no leading
          # blank observed. Loosening the shared def to fix a review-body
          # problem would change what counts as a clean verdict too, for no
          # evidence that the clean path needs it.
          #
          # The heading match is loose about what sits between the hashes and
          # the words — "### Codex Review" and "### 💡 Codex Review" have both
          # been observed — and strict about the words themselves.
          #
          # The sentence is pinned as the literal observed on
          # evanharmon1/harmon-devkit#355. Pinning cuts the other way from the
          # verdict-line clause deliberately: this is the SETTLED path, so a
          # reworded sentence fails to match, the review is not settled, and
          # the check re-blocks. Drift in Codex's format costs a false block,
          # never a false green.
          def carrier_sentence:
            "here are some automated review suggestions for this pull request.";
          def drop_leading_blanks:
            if (length > 0) and (.[0] == "") then .[1:] | drop_leading_blanks
            else . end;
          def carrier_lines:
            (body_text | ascii_downcase | split("\n") |
              map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) |
              drop_leading_blanks);
          def carrier_heading:
            ((carrier_lines | first) // "" |
              test("^#{1,6}[^a-z0-9]*codex review$"));
          def is_carrier_only:
            carrier_heading and
            (carrier_lines | .[1:] | join("\n") |
              strip_about_block | split("\n") |
              map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) |
              map(select(. != "")) |
              all(is_reviewed_commit_line or (. == carrier_sentence)));
          # harmon-devkit#675: when a session replies "Fixed in <sha>" to an
          # inline finding, the connector sometimes reads the thread as an
          # instruction, runs a fix task of its own, and posts a report on what
          # IT did — as a thread follow-up, and (observed on harmon-devkit#710,
          # comment 5504087486) as a top-level comment that opens
          # "### Summary" and happens to contain "Reviewed commit `<sha>`".
          #
          # That top-level shape is the damaging one here: the Reviewed-commit
          # phrase makes it candidate verdict evidence, `verdict_class` calls it
          # `findings` because it does not open with the clean sentence, and
          # `settle` then refuses it precisely because it carries no badge — so
          # the cycle could never report clean for that head through this
          # checker whatever the real review said. It is neither: the bot is
          # describing work, not reporting a finding, so it is INFORMATIONAL
          # and contributes to no aggregate.
          #
          # The test is deliberately content-NEGATIVE on the part that decides
          # severity — no badge anywhere in the body, the same whole-body scan
          # everything else here uses — and structural on the part that
          # identifies the shape: a `Summary` heading, or the bot naming a
          # commit it made on a branch of its own. It reads no prose for
          # intent, so it does not reopen the failure family documented above
          # `verdict_class`.
          #
          # Both failure directions are safe. An unrecognised self-report shape
          # keeps today's behaviour exactly (`findings`, blocking) — that is a
          # false block, which is the direction this file always chooses. And
          # nothing badged can reach this class at all, so a real finding
          # stated in a self-report-shaped body still blocks.
          def trimmed_lines:
            (body_text | ascii_downcase | split("\n") |
              map(gsub("^[[:space:]]+|[[:space:]]+$"; "")));
          def has_summary_heading:
            (trimmed_lines |
              any(.[]; test("^#{1,6}[[:space:]]*summary[[:space:]]*$")));
          # Challenge round 1, finding `challenge-r1-codex-adversarial-1`
          # (2026-09-20, confirmed P1): a `Summary` HEADING IS NOT EVIDENCE OF
          # ANYTHING. The first version of this predicate was
          # `(no badge) and (has_summary_heading or claims_own_commit)`, so the
          # heading alone sufficed — and because `informational` is excluded
          # from all three blocking scans, an unbadged prose concern written
          # under that heading became invisible where it had previously been
          # `findings`/exit 10. AGENTS.md § Severity gating is explicit that a
          # finding "not badged at all, is adjudicated as at least a P2", so an
          # unbadged concern IS a finding; the original safety note here
          # ("nothing badged can reach this class") only ever covered the
          # badged half of the problem.
          #
          # Two conditions now, and both are POSITIVE evidence that the bot is
          # describing its own work rather than reporting on the code:
          #
          #   1. a recognized self-work marker — the bot naming a commit it
          #      made, a PR it could not open, or a review it performed that
          #      needed no change. These are the verbatim shapes observed on
          #      harmon-devkit#665 (follow-up 3886149775) and harmon-devkit#710
          #      (top-level 5504087486).
          #   2. no finding footer. "Useful? React with 👍 / 👎." is the
          #      machine-emitted line Codex appends to a finding, and it is the
          #      same class of stable signal as the badge — not prose whose
          #      meaning has to be read.
          #
          # This is an allowlist of observed phrasings, which the long comment
          # above `verdict_class` warns against for the CLEAN path — and the
          # distinction is the failure direction. There, a non-match deadlocked
          # genuinely clean PRs. Here a non-match is `findings`: the body
          # blocks and a human adjudicates it. Drift costs a false block, never
          # a false green, which is the trade this file takes everywhere.
          def self_work_marker:
            (body_text | ascii_downcase |
              (test("committed .*on `[^`]+` as `[0-9a-f]{7,40}`") or
               test("a pull request could not be created") or
               test("reviewed commit `[0-9a-f]{7,40}` and found no additional")));
          def has_finding_footer:
            (body_text | ascii_downcase | test("useful\\? react with"));
          # Challenge round 2, findings `challenge-r2-codex-adversarial-1` and
          # `-3` (confirmed P1, disposition RESTRUCTURE). Round 1 asked only
          # whether a self-work marker appeared ANYWHERE, so a body could
          # describe the bot's own work in one line and state an unanswered
          # concern in the next and still classify `informational` — the
          # concern then vanished from every blocking scan. The marker list
          # was simultaneously too tight: a self-report phrased outside the
          # three observed strings exited 10 with no way to answer it.
          #
          # The invariant, not the phrasing: **informational means the body
          # states nothing but the bot's own work.** So the test is now
          # whole-body and structural — every non-blank line outside the
          # About block must be a heading, a bold-only label (`**Testing**`,
          # which both observed reports use), or a list item. A free-standing
          # prose paragraph is exactly what a concern looks like and exactly
          # what a work report does not contain.
          #
          # The marker is kept as the positive half, because structure alone
          # would admit any bulleted list. Both halves are required.
          #
          # Residual, stated rather than papered over: a concern written AS a
          # bullet inside an otherwise-genuine report still classifies
          # informational. That is why this predicate is only half the
          # restructure — `settle` now accepts everything `check` blocks on,
          # so misreading in the other direction costs one recorded
          # disposition instead of a stranded head, and the classifier is free
          # to fail closed.
          # `is_reviewed_commit_line` rides along because it is Codex's OWN
          # whole-line metadata — the same line `rest_is_boilerplate` accepts
          # in a clean verdict — not prose a concern could hide in. Every other
          # shape here is structural: a heading, a bold-only label, a list
          # item.
          def self_report_line:
            (test("^#{1,6}[[:space:]]") or
             test("^\\*\\*[^*]+\\*\\*[[:space:][:punct:]]*$") or
             test("^[*+-][[:space:]]") or
             test("^[0-9]+\\.[[:space:]]") or
             is_reviewed_commit_line);
          def states_only_own_work:
            (body_text | ascii_downcase | strip_about_block | split("\n") |
              map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) |
              map(select(. != "")) |
              all(self_report_line));
          def is_self_report:
            (has_severity_marker | not) and
            (has_finding_footer | not) and
            has_summary_heading and
            self_work_marker and
            states_only_own_work;
          # harmon-devkit#718's rolling "Codex Review Summary" table was
          # accepted here as a verdict surface in round 1 and SPLIT OUT in
          # challenge round 3 (findings `challenge-r3-codex-adversarial-2`,
          # `-3`, `-4`, `-5`; carried in #1117). Reading a verdict out of that
          # table meant deriving a head from parsed markdown, and three
          # consecutive rounds reproduced a false-clean or stuck-head path
          # through it: the Completed-row arm, the header/column resolution,
          # the latest-row-per-commit keying, and the comment-level freshness
          # stamp are all gone, with `settle`'s summary binding.
          #
          # What replaces it is a REJECTION FORM rather than a parser: a
          # badged comment from the pinned actor, newer than the trigger, that
          # this checker cannot bind to a head BLOCKS until it is settled by
          # comment id (see the unbound-badged scan in `check`). The trigger
          # already scopes the cycle to one PR and head, so nothing has to be
          # derived from the body at all — which is what deletes the whole
          # unbindable class instead of hardening it a fourth time.
          # Restructured, not re-decided: a body that DOES open with the clean
          # sentence classifies exactly as before (badge -> findings, trailing
          # prose -> unrecognized, otherwise clean), and a body that does not
          # is still `findings` unless it is the unbadged self-report shape
          # above. The clean-template branch is checked first so a self-report
          # heading can never reclassify a genuine clean verdict.
          def verdict_class:
            if (first_line | startswith(clean_sentence)) then
              (if has_severity_marker then "findings"
               elif (rest_is_boilerplate | not) then "unrecognized"
               else "clean" end)
            elif is_self_report then "informational"
            else "findings" end;
JQDEFS
)

case "$command_name" in
reserve)
    [ -n "$repo" ] && [ -n "$pr" ] && [ -n "$head" ] && [ -n "$attempt" ] ||
        usage
    valid_repo "$repo" || die "invalid repository: $repo"
    valid_uint "$pr" || die "invalid PR number: $pr"
    valid_sha "$head" || die "head must be a full 40-hex commit"
    valid_uint "$timeout_min" || die "timeout must be a positive integer"
    case "$attempt" in 1 | 2) ;; *) die "attempt must be 1 or 2" ;; esac
    acquire_state_lock

    provider_status=0
    live_head=$(provider_head "$pr" "$repo") || provider_status=$?
    if [ "$provider_status" -eq 3 ]; then
        die "PR is ${live_head:-not open} — a closed or merged PR has no review cycle to reserve"
    elif [ "$provider_status" -ne 0 ]; then
        die "cannot confirm the open PR head"
    fi
    [ "$live_head" = "$head" ] || die "PR head changed before reservation"

    replaced_trigger_comment_id=
    if [ -f "$state_file" ]; then
        read_state
        old_repo=$(jq -r '.repo' "$state_file")
        old_pr=$(jq -r '.pr' "$state_file")
        old_head=$(jq -r '.head' "$state_file")
        old_attempt=$(jq -r '.attempt' "$state_file")
        old_phase=$(jq -r '.phase' "$state_file")
        [ "$old_repo" = "$repo" ] && [ "$old_pr" = "$pr" ] ||
            die "state belongs to a different PR"
        [ "$old_phase" != "reserved" ] ||
            die "an unresolved reservation must be reconciled before replacing its head"
        # Challenge round 2, findings `challenge-r2-codex-adversarial-5`
        # and `-6` (2026-09-20, both confirmed P2, disposition DELETE):
        # round 1's item-B carve-out — a fresh attempt-1 reservation once a
        # recorded reset time had passed — is gone, and its round-1
        # disposition is reversed by the orchestrator on the round-2 record.
        # It opened on any past timestamp scraped from the body (so a reply
        # naming an old date re-triggered a reviewer that had just refused,
        # the exact waste harmon-devkit#573 measured), it could never open in
        # the observed case (no observed reply carries a reset time), and it
        # could not open even when one did, because the extractor accepted
        # minute resolution while `valid_time` requires seconds. It also gave
        # a guard whose whole value is having exactly one same-head
        # reservation route a second one.
        #
        # The underlying concern is real and is NOT dropped: giving a
        # quota-exhausted head a safe recovery route is carried in #1115. Until
        # then the documented behaviour stands — report the blocker, and let a
        # push or an operator clear the state.
        if [ "$old_head" = "$head" ]; then
            [ "$old_attempt" = "1" ] && [ "$attempt" = "2" ] &&
                [ "$old_phase" = "attached" ] ||
                die "refusing an uncontrolled duplicate trigger for this head"
            # harmon-devkit#1014 ruling 2: this reservation is about to
            # overwrite an attached attempt-1 state that itself carried a
            # trigger comment — that trigger is real same-head history, not
            # nothing, so the fresh reserved payload below must carry it
            # forward as `previous_trigger_comment_id` rather than the
            # attempt-1 shape's hardcoded `null`. `attach` (above) still owns
            # recomputing this field from live GitHub evidence once a new
            # trigger is attached; this is only the value in between.
            replaced_trigger_comment_id=$(jq -r '.trigger_comment_id // empty' "$state_file")
        else
            [ "$attempt" = "1" ] ||
                die "a new head must begin at attempt 1"
        fi
    elif [ "$attempt" != "1" ]; then
        die "attempt 2 requires an attached attempt-1 state"
    fi

    reserved_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    # Settlements PERSIST as head-level statements for the record, but they
    # never CERTIFY a later attempt. Attempt 2 of the same head keeps them so
    # the cycle does not re-block on a finding a human already disposed of, and
    # so the record of what was decided survives the reservation; a different
    # head invalidates them and this payload starts empty.
    #
    # What persistence does not buy is a verdict. The `disposed_applied` exit
    # still requires a disposed result NEWER than the latest trigger
    # (`> $requested` there), because re-triggering asks for a new review and
    # an older settlement says nothing about what that review found — the case
    # `an earlier settled finding cannot make a re-trigger clean without new
    # evidence` pins exactly that. Challenge round 3's finding
    # `challenge-r3-codex-adversarial-10` proposed removing the filter and was
    # adjudicated DECLINED as a false positive against this invariant: the
    # change is a fail-open, and it makes that pinned case fail.
    carried_settled='[]'
    if [ -f "$state_file" ] && [ "$(jq -r '.head' "$state_file")" = "$head" ]; then
        carried_settled=$(jq -c '.settled // []' "$state_file")
    fi
    if [ "$attempt" = "2" ]; then
        # harmon-devkit#573: the one bounded re-trigger exists for a reviewer
        # that did not answer. A reviewer that answered "my code-review usage
        # limit is exhausted" DID answer, so spending attempt 2 on it buys a
        # second window on a known-blocked reviewer and then escalates for the
        # wrong reason — the ~30 minutes the original issue measured. `check`
        # recorded that answer on this state when it reported exit 15; refuse
        # here rather than re-deriving it from GitHub, so the refusal is as
        # deterministic as the reservation it guards.
        recorded_quota_at=$(jq -r '.quota_exhausted_at // empty' "$state_file")
        if [ -n "$recorded_quota_at" ]; then
            recorded_quota_reset=$(jq -r '.quota_reset_at // empty' "$state_file")
            quota_refusal="attempt 1 ended with the finder reporting an exhausted code-review usage limit at $recorded_quota_at"
            if [ -n "$recorded_quota_reset" ]; then
                quota_refusal="$quota_refusal (resets at $recorded_quota_reset)"
            fi
            die "$quota_refusal — re-triggering cannot produce a review; report the blocker, and recover by pushing a new commit or removing this state file (route carried in #1115)"
        fi
        previous_requested_at=$(jq -r '.requested_at' "$state_file")
        valid_time "$previous_requested_at" ||
            die "attempt 1 state has an invalid request time"
        previous_requested_epoch=$(jq -nr \
            --arg value "$previous_requested_at" '$value | fromdateiso8601') ||
            die "cannot parse attempt 1 request time"
        # harmon-devkit#223: attempt 2 has no --timeout-min of its own in the
        # documented flow, and even when one is passed it must not silently
        # open a second window — a timeout already persisted on the attempt-1
        # state is authoritative, and an explicit flag may only restate it
        # (resolve_timeout_min dies on a mismatch). If attempt 1 never had a
        # timeout chosen for it, this reserve's own flag (or the 15-minute
        # default, if none) decides the cycle's timeout from here.
        persisted_timeout_min=$(jq -r '.timeout_min // empty' "$state_file")
        resolve_timeout_min "$persisted_timeout_min"
        # harmon-devkit#223: persist an adoption BEFORE the window check can
        # `die` and exit this process. An early attempt-2 that supplies the
        # cycle's first explicit --timeout-min still decided that timeout —
        # refusing the reservation for arriving too soon must not also
        # discard the choice, or a later flagless retry falls back to the
        # 15-minute default and gets refused again for the wrong reason.
        persist_adopted_timeout
        current_epoch=$(date -u '+%s')
        [ "$current_epoch" -ge \
            "$((previous_requested_epoch + timeout_min * 60))" ] ||
            die "attempt 1 window has not elapsed"
    fi
    # harmon-devkit#223: attempt 1 of a fresh cycle persists a CHOICE only
    # when one was actually made (`--timeout-min` passed) — writing the
    # runtime default here would make it indistinguishable from a real
    # choice, and a later `check --timeout-min 10` on an unmodified default
    # would then read as a conflict instead of the adoption the documented
    # `reserve` (no flag) -> `check --timeout-min N` convention depends on.
    # Attempt 2 always has a concrete decided value by this point (either
    # read back from attempt 1 above, or just adopted/defaulted into
    # `timeout_min` by resolve_timeout_min) and locks it in explicitly, since
    # there is no attempt 3 left to adopt anything later.
    if [ "$attempt" = "1" ] && [ "$timeout_min_set" != 1 ]; then
        payload_timeout_min=null
    else
        payload_timeout_min=$timeout_min
    fi

    # Per-finder profile resolution (#804 C1-C3): when --finder is set,
    # resolve the trusted registry at the PR's merge-base commit and extract
    # the finder's profile. The caller names only a slug; the actor identity,
    # trigger shape, and terminal signals all come from the registry.
    finder_payload=null
    if [ -n "$finder_slug" ]; then
        valid_slug "$finder_slug" || die "invalid finder slug: $finder_slug"
        # shellcheck source=trusted-registry.sh
        . "$SCRIPT_DIR/trusted-registry.sh"
        finder_tmpdir=$(mktemp -d -t codex-finder-XXXXXX)
        resolve_trusted_registry "$repo" "$pr" "$finder_tmpdir/registry.json" ||
            die "cannot resolve trusted registry for $repo#$pr"
        resolve_finder_profile "$finder_tmpdir/registry.json" "$finder_slug" \
            "$finder_tmpdir/profile.json" ||
            die "cannot resolve finder profile for slug '$finder_slug'"
        finder_payload=$(jq -c '{
            slug: .slug,
            actor_id: (.trusted_actor_id | tostring),
            actor_login: .trusted_actor_login,
            trigger_mechanism: .collection.trigger.mechanism,
            trigger_body: .collection.trigger.body,
            reviewer_login: .collection.trigger.reviewer_login,
            surfaces: .collection.terminal_signals.surfaces,
            head_binding: .collection.terminal_signals.head_binding,
            verdict_mode: .collection.terminal_signals.verdict_mode,
            clean_verdict: .collection.terminal_signals.clean_verdict,
            actionable_pattern: .collection.terminal_signals.actionable_pattern,
            severity_marker: .collection.terminal_signals.severity_marker,
            metadata_line: .collection.terminal_signals.metadata_line,
            about_summary: .collection.terminal_signals.about_summary,
            heading: .collection.terminal_signals.heading,
            carrier_sentence: .collection.terminal_signals.carrier_sentence,
            success_reaction: .collection.terminal_signals.success_reaction,
            pending_reaction: .collection.terminal_signals.pending_reaction
          }' "$finder_tmpdir/profile.json")
        rm -rf "$finder_tmpdir"
    fi

    if [ -n "$replaced_trigger_comment_id" ]; then
        valid_uint "$replaced_trigger_comment_id" ||
            die "attempt 1 state has an invalid trigger id to carry forward"
        payload_previous_trigger_comment_id=$replaced_trigger_comment_id
    else
        payload_previous_trigger_comment_id=null
    fi

    payload=$(jq -cn \
        --arg repo "$repo" \
        --argjson pr "$pr" \
        --arg head "$head" \
        --argjson attempt "$attempt" \
        --arg reserved_at "$reserved_at" \
        --argjson timeout_min "$payload_timeout_min" \
        --argjson settled "$carried_settled" \
        --argjson finder "$finder_payload" \
        --argjson previous_trigger_comment_id "$payload_previous_trigger_comment_id" \
        '{
          version:2,repo:$repo,pr:$pr,head:$head,attempt:$attempt,
          phase:"reserved",reserved_at:$reserved_at,
          trigger_comment_id:null,requested_at:null,
          previous_trigger_comment_id:$previous_trigger_comment_id,
          requires_full_window:false,
          timeout_min:$timeout_min,
          settled:$settled,
          finder:$finder
        }')
    write_state "$state_file" "$payload"
    release_state_lock
    printf '%s\n' "$payload"
    ;;

attach)
    # For review-comment finders (or legacy codex): --trigger-id is required.
    # For requested-reviewer finders: --requested-at replaces --trigger-id.
    if [ -n "$trigger_id" ]; then
        valid_uint "$trigger_id" || die "invalid trigger comment ID"
    elif [ -n "$requested_at_arg" ]; then
        valid_time "$requested_at_arg" || die "invalid --requested-at timestamp"
    else
        usage
    fi
    valid_uint "$timeout_min" || die "timeout must be a positive integer"
    acquire_state_lock
    read_state
    # harmon-devkit#223: every `run_gh` call below (the head re-check and the
    # trigger-comment fetch) is budgeted off `$timeout_min` via the
    # `state_reserved` arithmetic in `run_gh` itself — it is not just the
    # commands that reference the flag by name. A persisted non-default
    # timeout has to reach that arithmetic here exactly as it does in
    # `check`, or attach's own GitHub calls run on the wrong window.
    persisted_timeout_min=$(jq -r '.timeout_min // empty' "$state_file")
    resolve_timeout_min "$persisted_timeout_min"
    persist_adopted_timeout
    state_repo=$(jq -r '.repo' "$state_file")
    state_pr=$(jq -r '.pr' "$state_file")
    state_head=$(jq -r '.head' "$state_file")
    state_reserved=$(jq -r '.reserved_at' "$state_file")
    valid_time "$state_reserved" || die "state has an invalid reservation time"
    # The liveness re-check runs before the attached fast path below: a
    # resumed attach must refuse a since-closed/merged PR (or a moved head)
    # rather than answer success from local state alone.
    provider_status=0
    live_head=$(provider_head "$state_pr" "$state_repo") || provider_status=$?
    if [ "$provider_status" -eq 3 ]; then
        die "PR is ${live_head:-not open} — a closed or merged PR has no trigger to attach"
    elif [ "$provider_status" -ne 0 ]; then
        die "cannot re-confirm the open PR head"
    fi
    [ "$live_head" = "$state_head" ] ||
        die "PR head changed before trigger attachment"
    phase=$(jq -r '.phase' "$state_file")

    if [ -n "$requested_at_arg" ]; then
        # Requested-reviewer finders: no trigger comment to verify; the
        # caller recorded when the reviewer was requested.
        finder_mechanism=$(jq -r '.finder.trigger_mechanism // "review-comment"' "$state_file")
        [ "$finder_mechanism" = "requested-reviewer" ] ||
            die "--requested-at is only valid for requested-reviewer finders"
        if [ "$phase" = "attached" ]; then
            cat "$state_file"
            exit 0
        fi
        payload=$(jq \
            --arg requested_at "$requested_at_arg" '
              .version = 2 |
              .phase = "attached" |
              .trigger_comment_id = null |
              .requested_at = $requested_at
            ' "$state_file")
        write_state "$state_file" "$payload"
        release_state_lock
        printf '%s\n' "$payload"
        exit 0
    fi

    if [ "$phase" = "attached" ]; then
        existing_id=$(jq -r '.trigger_comment_id' "$state_file")
        [ "$existing_id" = "$trigger_id" ] ||
            die "state is already attached to a different trigger"
        cat "$state_file"
        exit 0
    fi

    # Review-comment finders: verify the trigger comment matches the
    # finder's trigger body (or the hardcoded "@codex review" for legacy).
    expected_trigger_body=$(jq -r '.finder.trigger_body // "@codex review"' "$state_file")
    comment=$(run_gh api "repos/$state_repo/issues/comments/$trigger_id") ||
        die "cannot fetch exact trigger comment $trigger_id"
    printf '%s' "$comment" | jq -e \
        --argjson id "$trigger_id" \
        --arg suffix "/issues/$state_pr" \
        --arg expected "$expected_trigger_body" '
          (.id == $id) and
          ((.body // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "") == $expected) and
          ((.issue_url // "") | endswith($suffix)) and
          (.created_at | type == "string")
        ' >/dev/null || die "comment $trigger_id is not this PR's exact review trigger"
    requested_at=$(printf '%s' "$comment" | jq -er '.created_at')
    valid_time "$requested_at" || die "trigger has a malformed creation time"

    requires_full_window=false
    previous_trigger_comment_id=null

    # A reconstructed reservation can be newer than the trigger attached to
    # it even though an earlier trigger already exists for this head. Detect
    # that history from one issue-comment read.
    #
    # The lower boundary for "same-head history" needs a timestamp GitHub
    # itself assigned, not one the committer wrote. Trigger comments carry no
    # head field, so harmon-devkit#1014's original version fell back to the
    # current commit's author/committer dates as a "conservative" boundary —
    # but those are client-controlled: a commit dated at or after a real
    # prior trigger hides that trigger from reconstruction entirely.
    #
    # The head's earliest check-suite `created_at` is server time,
    # un-spoofable by the committer — but challenge round 1 (2026-09-14,
    # confirmed harmon-devkit#1014 finding challenge-r1-codex-adversarial-1)
    # found that PREFERRING a check-run's `started_at` outright whenever any
    # check run exists — replacing the commit-date boundary rather than
    # combining the two — reopens the exact regression class this boundary
    # exists to close, via ordinary CI timing rather than a spoofed date.
    # Fixed with `min(commit-date boundary, earliest check-run started_at)`.
    #
    # Integration remediation 1 (2026-09-14, Codex cloud review on `a5bc99a`,
    # confirmed finding `4010207979`) found a COMBINED case that `min()` over
    # check-run `started_at` still does not close: when the commit dates are
    # ALSO future-dated (spoofed later than reality) AND a trusted trigger is
    # posted before CI has started its first RUN, `min()` still picks the
    # check-run boundary (since it is earlier than the inflated commit
    # dates) — but that boundary is itself later than the genuine trigger,
    # because a check RUN's `started_at` carries real CI-queue/startup
    # latency on top of when GitHub actually received the push. A check
    # SUITE (the envelope check runs belong to) is created essentially the
    # instant GitHub processes the push, before any run inside it has had a
    # chance to start — a tighter, still-unspoofable proxy for "when this
    # commit became the head" than any individual run's start time. Using
    # the earliest check-suite `created_at` instead of the earliest
    # check-run `started_at` closes this combined gap while keeping the same
    # `min()` structure (still defeats a plain commit-date spoof) and the
    # same fallback (commit dates alone, when no check suite exists at all).
    # `commit_date_boundary`/`check_suite_boundary` name both compared inputs
    # in state (the latter `null` when no check suite exists), and
    # `boundary_source` names only which one actually won the comparison — a
    # later reader can audit the comparison itself rather than trust a
    # single opaque label.
    #
    # KNOWN RESIDUAL (harmon-devkit#1030, Codex cycle 2 on `30b613c`,
    # confirmed finding `4010671547`, adjudicated P2 — a residual of the
    # timestamp approach itself, not a defect in this change): when the
    # commit dates are ALSO future-dated AND the trusted trigger is posted
    # before the first check SUITE exists (not merely before the first
    # run), every available lower bound — commit dates and check-suite
    # creation alike — postdates the trigger, so it is filtered out and
    # `requires_full_window` stays false. No further timestamp refinement
    # closes this: the trigger genuinely precedes every server-side signal
    # available at reconstruction time. #1030 tracks the structural fix —
    # on a reservation with no prior local state for the head, treat any
    # other trusted `@codex review` comment on the PR, posted after the
    # previous head's last accepted result (or, absent such a record, any
    # at all), as a prior trigger regardless of its timestamp ordering
    # against commit or check-suite creation.
    head_payload=$(run_gh api "repos/$state_repo/commits/$state_head") ||
        die "cannot fetch the current head commit for trigger reconstruction"
    printf '%s' "$head_payload" | jq -e --arg head "$state_head" \
        '.sha == $head' >/dev/null ||
        die "GitHub returned the wrong head commit during trigger reconstruction"
    head_authored_at=$(printf '%s' "$head_payload" |
        jq -er '.commit.author.date | select(type == "string")') ||
        die "current head commit has no usable author timestamp"
    valid_time "$head_authored_at" ||
        die "current head commit has a malformed author timestamp"
    head_committed_at=$(printf '%s' "$head_payload" |
        jq -er '.commit.committer.date | select(type == "string")') ||
        die "current head commit has no usable committer timestamp"
    valid_time "$head_committed_at" ||
        die "current head commit has a malformed committer timestamp"
    commit_date_boundary=$head_committed_at
    if [ "$head_authored_at" \< "$commit_date_boundary" ]; then
        commit_date_boundary=$head_authored_at
    fi
    check_suite_pages=$(run_gh api --paginate --slurp \
        "repos/$state_repo/commits/$state_head/check-suites?per_page=100") ||
        die "cannot fetch check suites for trigger reconstruction"
    check_suite_boundary=$(printf '%s' "$check_suite_pages" | jq -r '
          [.[] | (.check_suites // [])[] | .created_at |
            select(type == "string")] | sort | first // empty
        ') || die "cannot classify check-suite creation times"
    if [ -n "$check_suite_boundary" ]; then
        valid_time "$check_suite_boundary" ||
            die "GitHub returned a malformed check-suite creation time"
    fi
    head_trigger_boundary=$commit_date_boundary
    boundary_source=commit-date
    if [ -n "$check_suite_boundary" ] &&
        [ "$check_suite_boundary" \< "$head_trigger_boundary" ]; then
        head_trigger_boundary=$check_suite_boundary
        boundary_source=check-suite
    fi
    issue_comments=$(run_gh api --paginate --slurp \
        "repos/$state_repo/issues/$state_pr/comments?per_page=100") ||
        die "cannot fetch PR comments for trigger reconstruction"
    # A candidate created in the SAME SECOND as the attached trigger cannot be
    # excluded by a strict `<` on `created_at` alone (harmon-devkit#1014
    # ruling 3, Codex cycle-1 finding `4007296525`): GitHub timestamps these
    # to whole seconds, so a genuinely prior trigger posted in the same
    # second as the one just attached would otherwise be discarded. Comment
    # ids are monotonically assigned within the same resource type, so a
    # same-second candidate whose id precedes the attached trigger's id is
    # still provably prior; this is a same-surface (comment-vs-comment) id
    # comparison, unlike the cross-surface case in `check` below, which never
    # tie-breaks by id.
    prior_trigger_candidates=$(printf '%s' "$issue_comments" | jq -c \
        --argjson attached "$trigger_id" \
        --arg expected "$expected_trigger_body" \
        --arg after "$head_trigger_boundary" \
        --arg before "$requested_at" '
          [flatten[] | select(
            ((.id? | type) == "number") and .id != $attached and
            ((.user.id? | type) == "number") and
            (((.body // "") |
              gsub("^[[:space:]]+|[[:space:]]+$"; "")) == $expected) and
            ((.created_at? | type) == "string") and
            (.created_at >= $after) and
            ((.created_at < $before) or
             ((.created_at == $before) and (.id < $attached)))
          )]
        ') || die "cannot classify prior review triggers"

    if [ "$requested_at" \< "$state_reserved" ] ||
        [ "$(printf '%s' "$prior_trigger_candidates" | jq 'length')" -gt 0 ]; then
        # A trigger that predates this local reservation is state-recovery
        # evidence, not a newly posted first attempt. A distinct same-head
        # trigger is reconstruction evidence even when this attached trigger
        # is newer than the reservation. Authenticate either inference only
        # against the merge-base registry's orchestrator actor set.
        # shellcheck source=trusted-registry.sh
        . "$SCRIPT_DIR/trusted-registry.sh"
        trigger_registry_dir=$(mktemp -d -t codex-trigger-registry-XXXXXX)
        resolve_trusted_registry "$state_repo" "$state_pr" \
            "$trigger_registry_dir/registry.json" || {
            rm -rf "$trigger_registry_dir"
            die "cannot authenticate a pre-existing trigger against the trusted actor set"
        }

        if [ "$requested_at" \< "$state_reserved" ]; then
            trigger_author_id=$(printf '%s' "$comment" |
                jq -er '.user.id | select(type == "number" and . > 0)') || {
                rm -rf "$trigger_registry_dir"
                die "pre-existing trigger has no usable author identity"
            }
            jq -e --argjson id "$trigger_author_id" '
              (.trusted_orchestrator_actor_ids // []) | index($id) != null
            ' "$trigger_registry_dir/registry.json" >/dev/null || {
                rm -rf "$trigger_registry_dir"
                die "pre-existing trigger author is not in the trusted actor set"
            }
            requires_full_window=true
        fi

        previous_trigger_comment_id=$(jq -nr \
            --argjson candidates "$prior_trigger_candidates" \
            --slurpfile registry "$trigger_registry_dir/registry.json" '
              ($registry[0].trusted_orchestrator_actor_ids // []) as $trusted |
              [$candidates[] | select(.user.id as $id | $trusted | index($id))] |
              sort_by(.created_at, .id) | last // null | .id // null
            ')
        rm -rf "$trigger_registry_dir"
        [ "$previous_trigger_comment_id" = null ] || requires_full_window=true
    fi

    payload=$(jq \
        --argjson id "$trigger_id" \
        --arg requested_at "$requested_at" \
        --argjson previous_trigger_comment_id "$previous_trigger_comment_id" \
        --argjson requires_full_window "$requires_full_window" \
        --arg boundary_source "$boundary_source" \
        --arg commit_date_boundary "$commit_date_boundary" \
        --arg check_suite_boundary "$check_suite_boundary" '
          .version = 2 |
          .phase = "attached" |
          .trigger_comment_id = $id |
          .requested_at = $requested_at |
          .previous_trigger_comment_id = $previous_trigger_comment_id |
          .requires_full_window = $requires_full_window |
          .boundary_source = $boundary_source |
          .commit_date_boundary = $commit_date_boundary |
          .check_suite_boundary = (if $check_suite_boundary == ""
            then null else $check_suite_boundary end)
        ' "$state_file")
    write_state "$state_file" "$payload"
    release_state_lock
    printf '%s\n' "$payload"
    ;;

show)
    read_state
    cat "$state_file"
    ;;

reap)
    # A checkout that has never shepherded has no state directory. That is a
    # sweep of an empty set, not an error — the caller runs this
    # unconditionally, so "nothing here" must not be a failure.
    if [ ! -e "$root_dir" ]; then
        jq -cn --arg root "$root_dir" '{
          status:"swept",root:$root,
          scanned:0,reaped:0,kept:0,skipped:0,entries:[]
        }'
        exit 0
    fi
    [ -d "$root_dir" ] || die "state root is not a directory: $root_dir"
    valid_uint "$reap_budget_sec" || die "budget must be a positive integer"
    # Reaping is best-effort cleanup that runs ahead of the work that matters,
    # so it gets a whole-sweep deadline rather than only a per-call one.
    # Sequential entries each carrying their own timeout is how a slow or
    # unreachable GitHub turns a stale backlog into minutes of delay before the
    # current PR is even reserved. Past the deadline the remaining entries are
    # KEPT unexamined — the same answer as any other unreadable state, and the
    # next sweep will try again.
    reap_deadline_epoch=$(($(date -u '+%s') + reap_budget_sec))

    reap_workdir=$(mktemp -d -t codex-cloud-review-reap-XXXXXX) ||
        die "cannot create a temporary sweep directory"
    trap 'rm -rf "$reap_workdir"; rmdir "$reap_lock" 2>/dev/null || true' EXIT
    reap_entries="$reap_workdir/entries.ndjson"
    : >"$reap_entries"

    # Only the layout `reserve` writes — <root>/<owner>/<repo>/<pr>.json — is
    # a candidate. Depth is pinned rather than recursed, and non-`.json`
    # siblings are excluded, so `write_state`'s `.tmp.XXXXXX` leftovers and a
    # leaked `.lock` directory are passed over instead of deleted. This sweep
    # removes state it can positively identify as its own; it is not a
    # general-purpose cleaner for whatever sits under the path it was handed.
    # NUL-delimited: a newline in a path would otherwise split one candidate
    # into two, and a half-path that no longer resolves is a confusing way to
    # discover an unreadable directory. A find that could not complete is a
    # sweep that did not happen, so it fails rather than under-reporting.
    find "$root_dir" -mindepth 3 -maxdepth 3 -type f -name '*.json' -print0 \
        >"$reap_workdir/candidates" ||
        die "cannot enumerate state under $root_dir"

    while IFS= read -r -d '' candidate; do
        [ -n "$candidate" ] || continue
        # Derived from the path itself rather than by stripping $root_dir, so
        # a trailing slash in the argument cannot skew the components.
        candidate_parent=${candidate%/*}
        candidate_grandparent=${candidate_parent%/*}
        path_repo="${candidate_grandparent##*/}/${candidate_parent##*/}"
        path_pr=${candidate##*/}
        path_pr=${path_pr%.json}

        state_repo=$(jq -er '
              select(
                type == "object" and (.version == 1 or .version == 2) and
                (.repo | type == "string") and (.pr | type == "number")
              ) | .repo
            ' "$candidate" 2>/dev/null) || {
            reap_record "$candidate" "" "" "" skipped \
                "not a recognizable state file"
            continue
        }
        state_pr=$(jq -er '.pr | tostring' "$candidate" 2>/dev/null) || {
            reap_record "$candidate" "" "" "" skipped \
                "not a recognizable state file"
            continue
        }

        # The same shape `reserve` enforces before it writes. The schema check
        # above proves `.repo` is a string and `.pr` a number, not that either
        # names a repository — and these two become arguments to `gh`.
        if ! valid_repo "$state_repo" || ! valid_uint "$state_pr"; then
            reap_record "$candidate" "$state_repo" "" "" skipped \
                "state does not name a well-formed repository and PR"
            continue
        fi

        # The file says which PR it belongs to and so does its path. Requiring
        # them to agree means a state file that was moved, hand-edited, or
        # dropped in from elsewhere is left alone rather than driving a delete
        # against whatever PR its contents happen to name.
        if [ "$state_repo" != "$path_repo" ] || [ "$state_pr" != "$path_pr" ]; then
            reap_record "$candidate" "$state_repo" "$state_pr" "" skipped \
                "state contents disagree with the path they are stored under"
            continue
        fi

        if [ "$(date -u '+%s')" -ge "$reap_deadline_epoch" ]; then
            reap_record "$candidate" "$state_repo" "$state_pr" "" kept \
                "sweep budget exhausted before this entry was checked"
            continue
        fi

        # Snapshot the state BEFORE the query, so the delete below can prove
        # nothing rewrote it while GitHub was being asked.
        state_snapshot=$(cat "$candidate" 2>/dev/null) || {
            reap_record "$candidate" "$state_repo" "$state_pr" "" skipped \
                "state vanished before it could be examined"
            continue
        }

        # Query FIRST, unlocked. The lock below is the same one
        # `reserve`/`attach`/`check` take, and `acquire_state_lock` is a bare
        # `mkdir` that dies on contention with no retry — so holding it across
        # a network call would abort a live cycle for a DIFFERENT PR that
        # merely shares this git directory, sending a correct session to
        # maintainer reconciliation on exit 2. An open PR's lock is therefore
        # never taken at all: reaping has no business claiming state it has
        # already decided to keep.
        pr_state=
        if pr_payload=$(run_gh pr view "$state_pr" --repo "$state_repo" \
            --json state 2>/dev/null); then
            pr_state=$(printf '%s' "$pr_payload" |
                jq -r 'select(type == "object") | .state // empty' 2>/dev/null) ||
                pr_state=
        fi

        case "$pr_state" in
        CLOSED | MERGED)
            # Only a candidate proven dead is worth locking, and only for the
            # unlink itself.
            reap_lock="${candidate}.lock"
            if ! mkdir "$reap_lock" 2>/dev/null; then
                reap_lock=
                action=skipped
                detail="state is locked by another shepherd"
            elif [ "$(cat "$candidate" 2>/dev/null)" != "$state_snapshot" ]; then
                # Rewritten (or removed) while we were asking GitHub — the
                # answer we hold describes a file that no longer exists.
                rmdir "$reap_lock" 2>/dev/null || true
                reap_lock=
                action=skipped
                detail="state changed while its PR was being checked"
            elif rm -f "$candidate"; then
                rmdir "$reap_lock" 2>/dev/null || true
                reap_lock=
                action=reaped
                detail="PR is $pr_state"
            else
                rmdir "$reap_lock" 2>/dev/null || true
                reap_lock=
                action=kept
                detail="PR is $pr_state but the state file could not be removed"
            fi
            ;;
        OPEN)
            action=kept
            detail="PR is still open"
            ;;
        '')
            # Unreadable is not closed. A rate limit, an expired token, a
            # network blip, or a repository that has become inaccessible all
            # land here, and deleting on any of them would discard live state
            # for a PR still in flight. Keeping costs one stale file until the
            # next sweep; deleting costs a cycle that cannot be resumed.
            action=kept
            detail="PR state is unreadable"
            ;;
        *)
            action=kept
            detail="unrecognized PR state: $pr_state"
            ;;
        esac

        # No release here on purpose: the CLOSED/MERGED arm is the only one
        # that ever takes the lock, and it releases on every path out. The
        # EXIT trap still covers an abort mid-arm.

        # The emptied <owner>/ and <owner>/<repo>/ directories are deliberately
        # LEFT BEHIND. Pruning them read as tidiness and was a race:
        # `acquire_state_lock` does `mkdir -p "$parent"` and then
        # `mkdir "$lock_dir"` non-atomically, so an rmdir landing between the
        # two makes the second call fail ENOENT — and its error says "state is
        # locked by another shepherd", naming a lock that does not exist, for a
        # reservation of a different PR that was entitled to proceed. An empty
        # directory costs an inode inside the git directory, is invisible to
        # `git status`, is never pushed, and is reused verbatim by the next
        # `reserve`. Best-effort cleanup must not be able to abort a concurrent
        # reservation, so the cosmetic half of it is simply not done.

        reap_record "$candidate" "$state_repo" "$state_pr" "$pr_state" \
            "$action" "$detail"
    done <"$reap_workdir/candidates"

    jq -s -c --arg root "$root_dir" '{
      status:"swept",
      root:$root,
      scanned:length,
      reaped:([.[] | select(.action == "reaped")] | length),
      kept:([.[] | select(.action == "kept")] | length),
      skipped:([.[] | select(.action == "skipped")] | length),
      entries:.
    }' "$reap_entries"
    ;;

check)
    valid_uint "$timeout_min" || die "timeout must be a positive integer"
    acquire_state_lock
    read_state

    state_repo=$(jq -r '.repo' "$state_file")
    state_pr=$(jq -r '.pr' "$state_file")
    state_head=$(jq -r '.head' "$state_file")
    state_attempt=$(jq -r '.attempt' "$state_file")
    state_phase=$(jq -r '.phase' "$state_file")
    [ "$state_phase" = "attached" ] || {
        emit indeterminate "review request was reserved but its exact trigger is not attached"
        exit 2
    }

    # Per-finder parameters (#804): when state carries a finder profile,
    # actor identity and classification are driven by it.
    finder_verdict_mode=$(jq -r '.finder.verdict_mode // "clean-sentence"' "$state_file")
    finder_has_surface() {
        jq -e --arg s "$1" '(.finder.surfaces // ["reaction","comment","review","inline"]) | index($s) != null' "$state_file" >/dev/null 2>&1
    }
    finder_trigger_mechanism=$(jq -r '.finder.trigger_mechanism // "review-comment"' "$state_file")
    finder_success_reaction=$(jq -r '.finder.success_reaction // "+1"' "$state_file")
    finder_pending_reaction=$(jq -r '.finder.pending_reaction // "eyes"' "$state_file")
    finder_actionable_pattern=$(jq -r '.finder.actionable_pattern // ""' "$state_file")
    finder_head_binding=$(jq -r '.finder.head_binding // "reviewed-commit-line"' "$state_file")
    state_finder_actor_id=$(jq -r '.finder.actor_id // empty' "$state_file")
    state_finder_actor_login=$(jq -r '.finder.actor_login // empty' "$state_file")
    if [ -n "$state_finder_actor_id" ]; then
        actor_id=$state_finder_actor_id
        actor_login=${state_finder_actor_login:-$actor_login}
    fi
    [ -n "$actor_id" ] || die "no actor identity: supply --actor-id or use --finder on reserve"
    valid_uint "$actor_id" || die "invalid actor ID"

    state_trigger=$(jq -r '.trigger_comment_id // empty' "$state_file")
    state_reserved=$(jq -r '.reserved_at' "$state_file")
    state_requested=$(jq -r '.requested_at' "$state_file")
    # trigger_comment_id is null for requested-reviewer finders
    if [ "$finder_trigger_mechanism" = "review-comment" ]; then
        valid_uint "$state_trigger" || die "state has an invalid trigger ID"
    fi
    valid_time "$state_reserved" || die "state has an invalid reservation time"
    valid_time "$state_requested" || die "state has an invalid request time"
    # harmon-devkit#223: the window `bounded_wait` and `run_gh`'s per-call
    # budget measure against `state_reserved` must be the one this cycle was
    # actually reserved under, not whatever `--timeout-min` this particular
    # invocation happened to pass — otherwise a shorter flag here and the
    # unmodified 15-minute default in attempt-2 `reserve` disagree about when
    # the window closes.
    persisted_timeout_min=$(jq -r '.timeout_min // empty' "$state_file")
    resolve_timeout_min "$persisted_timeout_min"
    persist_adopted_timeout

    provider_status=0
    first_head=$(provider_head "$state_pr" "$state_repo") || provider_status=$?
    if [ "$provider_status" -eq 3 ]; then
        # Not a transient failure: GitHub answered and the PR is dead. The
        # whole stage is over, so this must not consume the bounded window —
        # routing it to bounded_wait is exactly the harmon-devkit#389 bug.
        emit pr-not-open \
            "PR is ${first_head:-no longer open} — the stage is over; stop, do not re-trigger or keep polling"
        exit 14
    elif [ "$provider_status" -ne 0 ]; then
        transient_read_failure "cannot fetch the current open PR head"
    fi
    [ "$first_head" = "$state_head" ] || {
        emit head-changed "recorded evidence belongs to an older PR head"
        exit 2
    }

    workdir=$(mktemp -d -t codex-cloud-review-XXXXXX)
    trap 'rm -rf "$workdir"; rm -f "$lock_dir/pid"; rmdir "$lock_dir" 2>/dev/null || true' EXIT

    actor=$(run_gh api "users/$actor_login") || {
        transient_read_failure "cannot authenticate the configured finder actor"
    }
    printf '%s' "$actor" | jq -e \
        --argjson id "$actor_id" \
        --arg login "$actor_login" '
          (.id == $id) and (.login == $login) and (.type == "Bot")
        ' >/dev/null || {
        emit indeterminate "configured finder login does not resolve to the pinned Bot actor ID"
        exit 2
    }

    # Trigger verification: review-comment finders re-fetch and verify the
    # trigger comment; requested-reviewer finders skip this (no trigger
    # comment exists).
    if [ "$finder_trigger_mechanism" = "review-comment" ] && [ -n "$state_trigger" ]; then
        expected_trigger_body=$(jq -r '.finder.trigger_body // "@codex review"' "$state_file")
        trigger=$(run_gh api "repos/$state_repo/issues/comments/$state_trigger") || {
            transient_read_failure "cannot re-fetch the exact trigger comment"
        }
        printf '%s' "$trigger" | jq -e \
            --argjson id "$state_trigger" \
            --arg created "$state_requested" \
            --arg suffix "/issues/$state_pr" \
            --arg expected "$expected_trigger_body" '
              (.id == $id) and (.created_at == $created) and
              ((.body // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "") == $expected) and
              ((.issue_url // "") | endswith($suffix))
            ' >/dev/null || {
            emit indeterminate "exact trigger metadata changed or is malformed"
            exit 2
        }
    fi

    # Fetch only the surfaces this finder uses.
    printf '%s\n' '[]' >"$workdir/reactions.json"
    if finder_has_surface reaction && [ "$finder_trigger_mechanism" = "review-comment" ] && [ -n "$state_trigger" ]; then
        fetch_evidence \
            "repos/$state_repo/issues/comments/$state_trigger/reactions?per_page=100" \
            "$workdir/reactions.json" \
            "exact-trigger reactions"
    fi
    printf '%s\n' '[]' >"$workdir/comments.json"
    if finder_has_surface comment; then
        fetch_evidence \
            "repos/$state_repo/issues/$state_pr/comments?per_page=100" \
            "$workdir/comments.json" "PR conversation comments"
    fi
    printf '%s\n' '[]' >"$workdir/reviews.json"
    if finder_has_surface review; then
        fetch_evidence \
            "repos/$state_repo/pulls/$state_pr/reviews?per_page=100" \
            "$workdir/reviews.json" "PR reviews"
    fi
    printf '%s\n' '[]' >"$workdir/inline.json"
    if finder_has_surface inline; then
        fetch_evidence \
            "repos/$state_repo/pulls/$state_pr/comments?per_page=100" \
            "$workdir/inline.json" "inline comments"
    fi

    provider_status=0
    second_head=$(provider_head "$state_pr" "$state_repo") || provider_status=$?
    if [ "$provider_status" -eq 3 ]; then
        emit pr-not-open \
            "PR was closed or merged (${second_head:-state unknown}) while evidence was being fetched — the stage is over"
        exit 14
    elif [ "$provider_status" -ne 0 ]; then
        transient_read_failure "cannot re-fetch the PR head before verdict"
    fi
    [ "$second_head" = "$state_head" ] || {
        emit head-changed "PR head changed while evidence was being fetched"
        exit 2
    }

    for evidence in reactions comments reviews inline; do
        case "$evidence" in
        reactions) finder_has_surface reaction || continue ;;
        comments) finder_has_surface comment || continue ;;
        reviews) finder_has_surface review || continue ;;
        inline) finder_has_surface inline || continue ;;
        esac
        jq -e \
            --argjson id "$actor_id" \
            --arg login "$actor_login" '
              all(.[];
                ((.user.id? == $id) | not) or (.user.login? == $login)
              ) and
              all(.[];
                ((.user.login? == $login) | not) or (.user.id? == $id)
              )
            ' "$workdir/$evidence.json" >/dev/null || {
            emit indeterminate "finder-looking activity has an unexpected immutable actor identity"
            exit 2
        }
    done

    while IFS=$'\t' read -r review_id review_time; do
        [ -n "$review_id" ] || review_id=unknown
        valid_time "$review_time" || {
            emit indeterminate "current-head review $review_id carries a malformed submitted_at timestamp"
            exit 2
        }
    done < <(jq -r \
        --argjson id "$actor_id" \
        --arg head "$state_head" '
          .[] | select(.user.id? == $id and .commit_id? == $head) |
          [(.id? // "" | tostring), (.submitted_at? // "")] | @tsv
        ' "$workdir/reviews.json")

    # harmon-devkit#573: the usage-limit reply. When the connector's
    # code-review quota is spent it answers the trigger with a top-level
    # comment — observed verbatim on evanharmon1/harmon-init#1020, comment
    # 5380551548: "You have reached your Codex usage limits for code reviews.
    # You can see your limits in the [Codex usage dashboard](…)". It carries no
    # verdict sentence, no `Reviewed commit` line and no badge, so every
    # classifier below is blind to it and the cycle sat `pending` for the whole
    # window, then spent attempt 2 on the same answer before escalating: ~30
    # minutes to learn something the bot said in five seconds, and a blocker
    # report that could not name the reset time.
    #
    # Matched on the one phrase the message is built around, case-insensitively,
    # and only from the pinned actor after this attempt's own trigger. The match
    # is deliberately narrow: a reworded message simply is not recognised, which
    # restores exactly today's behaviour (wait out the window) rather than
    # inventing a terminal answer — the same fail-closed direction the rest of
    # this file takes.
    #
    # `bounded_wait` acts on this, not the code here, because absence of other
    # evidence is the only state a quota reply can ever be observed in, and
    # every waiting path funnels through there.
    if finder_has_surface comment; then
        # Same boundary as the unbound-badge scan above, same reason
        # (`challenge-r5-codex-adversarial-4`, second site): a usage-limit
        # reply posted in the triggers own second was missed by the strict
        # bound, so the cycle waited out its window and reported 12 instead of
        # the terminal 15 the reply had already given it. Inclusive bound with
        # the monotonic comment-id tiebreak, exactly as above.
        quota_record=$(jq -r \
            --argjson id "$actor_id" \
            --arg requested "$state_requested" \
            --argjson trigger "${state_trigger:-0}" '
              [.[] | select(
                .user.id? == $id and
                (((.created_at? // "") > $requested) or
                 (((.created_at? // "") == $requested) and
                  ((.id? | type) == "number") and (.id > $trigger))) and
                ((.body // "") | ascii_downcase |
                  test("reached your codex usage limit"))
              ) | select((.id? | type) == "number" and .id > 0)] |
              sort_by(.created_at, .id) | last // null |
              if . == null then ""
              else
                [(.id | tostring), (.created_at // ""),
                 # A reset time where the reply carries one. No observed
                 # instance does, so this stays empty rather than guessing;
                 # the detail then says so explicitly instead of implying a
                 # time nobody was told.
                 ((((.body // "") | [match(
                      "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z";
                      "i"
                    ).string] | first) // ""))] | join(",")
              end
            ' "$workdir/comments.json") || {
            emit indeterminate "conversation comments could not be scanned for a usage-limit reply"
            exit 2
        }
        if [ -n "$quota_record" ]; then
            IFS=, read -r quota_comment_id quota_detected_at quota_reset_at \
                <<<"$quota_record"
            valid_time "$quota_detected_at" || {
                emit indeterminate "the finder's usage-limit reply carries a malformed creation time"
                exit 2
            }
        fi
    fi

    # harmon-devkit#655: is the finder's pending reaction still on THIS
    # attempt's trigger? `reactions.json` is fetched for the exact trigger
    # comment and nothing else, so presence here is exactly the "current
    # attempt's trigger" the issue asks about — and a reaction that has since
    # been removed is simply absent from the fetch, which is how the
    # vanished-without-result case keeps its existing retry behaviour.
    #
    # Read here rather than in `bounded_wait` so the extension can never be
    # decided from an unfetched surface: a finder with no reaction surface, or
    # a read that failed earlier (now exit 16), leaves this at 0.
    if finder_has_surface reaction; then
        pending_reaction_live=$(jq -r \
            --argjson id "$actor_id" \
            --arg pending "$finder_pending_reaction" '
              if any(.[]; .user.id? == $id and .content? == $pending)
              then "1" else "0" end
            ' "$workdir/reactions.json") || {
            emit indeterminate "exact-trigger reactions could not be scanned for the pending signal"
            exit 2
        }
    fi

    # Success reactions must carry usable evidence metadata just like review
    # and comment results. Only the exact latest trigger is consulted.
    while IFS= read -r reaction_time; do
        valid_time "$reaction_time" || {
            emit indeterminate "trigger success reaction carries a malformed timestamp"
            exit 2
        }
    done < <(jq -r \
        --argjson id "$actor_id" \
        --arg success "$finder_success_reaction" '
          .[] | select(.user.id? == $id and .content? == $success) |
          (.created_at? // "")
        ' "$workdir/reactions.json")

    # Settled dispositions are re-verified against the evidence just fetched,
    # never trusted from the state file alone. An entry is honoured only while
    # the target still reads exactly as it did when the disposition was
    # written; an edited finding is a different finding, and its stale entry is
    # ignored (not deleted — the operator settles it again, and the record of
    # what was decided about the earlier text stays put). A target that has
    # since vanished from the evidence settles nothing, which costs nothing:
    # there is no finding left to suppress.
    disposed_comments='[]'
    disposed_reviews='[]'
    settled_list="$workdir/settled.tsv"
    jq -r '
          (.settled // [])[] |
          select((.id | type) == "number") |
          [(.surface // ""), (.id | tostring), (.content_fingerprint // ""),
           (.disposition // "")] |
          @tsv
        ' "$state_file" >"$settled_list"
    applied_dispositions=""
    while IFS='	' read -r settled_surface settled_id settled_fingerprint \
        settled_disposition; do
        [ -n "$settled_surface" ] || continue
        case "$settled_surface" in
        comment) settled_evidence="$workdir/comments.json" ;;
        review) settled_evidence="$workdir/reviews.json" ;;
        *) continue ;;
        esac
        settled_target=$(jq -c \
            --argjson id "$settled_id" '
              [.[] | select(.id? == $id)] | first // empty
            ' "$settled_evidence")
        [ -n "$settled_target" ] || continue
        settled_body=$(printf '%s' "$settled_target" |
            jq -r '(.body // "") | @json')
        settled_edited=$(printf '%s' "$settled_target" |
            jq -r '.updated_at // .submitted_at // ""')
        [ "$(content_fingerprint "$settled_body" "$settled_edited")" = \
            "$settled_fingerprint" ] || continue
        case "$applied_dispositions" in
        *"$settled_disposition"*) ;;
        "") applied_dispositions=$settled_disposition ;;
        *) applied_dispositions="$applied_dispositions and $settled_disposition" ;;
        esac
        case "$settled_surface" in
        comment)
            disposed_comments=$(printf '%s' "$disposed_comments" |
                jq -c --argjson id "$settled_id" '. + [$id] | unique')
            ;;
        review)
            disposed_reviews=$(printf '%s' "$disposed_reviews" |
                jq -c --argjson id "$settled_id" '. + [$id] | unique')
            ;;
        esac
    done <"$settled_list"

    # Current-head inline findings are PARTITIONED, not counted
    # (evanharmon1/harmon-devkit#275). Counting them made the two-attempt
    # contract unfinishable for any head carrying a declined P2: the settled
    # finding re-blocked every later check until a new commit moved the head,
    # which is the opposite of what the shepherd stage asks for — a finding is
    # settled by fixing it OR by declining it with reasoning in its thread.
    #
    # A bot inline comment on this head is ADJUDICATED when its own thread
    # carries a trusted reply posted after it. The replies come from the SAME
    # `pulls/<n>/comments` listing already fetched, because a reply to a review
    # comment IS an inline comment — it is the same resource with
    # `in_reply_to_id` set to the comment it answers. There is no second
    # endpoint to fetch and no GraphQL thread walk needed.
    #
    # Trust is `author_association` in {OWNER, MEMBER, COLLABORATOR} OR the
    # reply's immutable numeric user ID equalling the PR author's. The
    # association alone is not enough: a shepherd driving a fork PR replies as
    # the PR author with association CONTRIBUTOR, and refusing that would make
    # the contract unfinishable again for exactly the sessions this helper
    # exists to serve. The bot may never adjudicate itself.
    #
    # What a reply SAYS is deliberately not examined, and that is a knowingly
    # accepted residual: a content-free trusted reply — "looking into it" —
    # adjudicates the finding just as a reasoned decline does. Requiring an
    # explicit disposition would mean parsing reply prose for intent, which is
    # the exact failure family documented at length above `verdict_class`, and
    # issue #275's acceptance criterion is reply-from-a-trusted-actor, not
    # reply-content. It also matches what SKILL.md §2 already says about the
    # main thread check: it measures whether a thread has been answered, never
    # who thought about it. The cost is bounded because this gate promotes a
    # draft to ready-for-review rather than merging, so a human still reads the
    # disposition that now stands on the PR.
    #
    # Malformed or missing fields on a would-be trusted reply — no numeric user
    # ID, no association, an unparseable timestamp — make that reply untrusted,
    # so the comment stays UNADJUDICATED and the check reports `findings`. That
    # is the opposite of `verdict_class`, where unparseable means indeterminate,
    # and deliberately so: an unreadable verdict says nothing about whether the
    # PR is clean, but an unreadable reply is simply not proof that a human
    # answered the finding. Fail-closed here points at `findings`.
    #
    # The edited-since-reply rule compares the bot comment's `updated_at`
    # against the LATEST trusted reply's `created_at`. Codex edits a finding in
    # place when it revises it, and a reply that predates the edit answered
    # different text — so an edited comment whose replies are all older is
    # unresolved again. `updated_at` absent means never edited and falls back to
    # `created_at`; present but unparseable fails closed, like every other
    # malformed field here.
    #
    # That comparison is STRICT. GitHub timestamps are second-precision, so a
    # reply stamped the same second as an edit cannot prove it came after the
    # edit — and a tie resolved in the reply's favour would silently adjudicate
    # text the replier may never have seen. The never-edited case is unaffected:
    # `updated_at` then equals `created_at`, and a trusted reply is already
    # required to be strictly later than that.
    #
    # The partition also records which REVIEW each finding belongs to, via the
    # inline comment's `pull_request_review_id`. A review is settled only by its
    # OWN findings — see the correlation comment above the review gate below.
    # A current-head bot inline comment carrying no numeric
    # `pull_request_review_id` cannot be attributed to anything, so it settles
    # nothing at all: the whole settled set collapses to empty rather than
    # letting an unattributable finding be counted against some other review.
    inline_head_findings=$(jq \
        --argjson id "$actor_id" \
        --arg head "$state_head" '
          [.[] | select(
            .user.id? == $id and
            (.original_commit_id? == $head)
          )] | length
        ' "$workdir/inline.json")

    adjudicated_findings=0
    settled_reviews='[]'
    attributed_reviews='[]'
    unattributed_findings=0
    if [ "$inline_head_findings" -gt 0 ]; then
        # Fetched lazily and only once: the PR author identity is needed solely
        # to judge replies, so a head with no inline findings — the ordinary
        # case — spends no call on it. `gh pr view`'s author `id` is a GraphQL
        # node ID and could never compare against the REST `user.id` on a
        # comment, hence the REST pull object rather than the payload
        # `provider_head` already reads.
        #
        # This call lands AFTER the evidence snapshot and after the head check
        # that closes it, so it is also the last chance to notice a push that
        # arrived in between — and the payload already carries `head.sha`, so
        # noticing costs nothing. Without it, the window in which the snapshot
        # is believed would be longer than the window it was verified over,
        # which is exactly the failure the second head check exists to prevent.
        #
        # Accepted residual, unchanged by any of this: a NEW finding arriving on
        # the SAME head after the evidence was fetched is invisible to any
        # single-snapshot design. Only the next check sees it, which is why the
        # caller re-reads the four surfaces immediately before accepting a
        # result.
        pr_payload=$(run_gh api "repos/$state_repo/pulls/$state_pr") || {
            transient_read_failure "cannot fetch the pull request author identity"
        }
        pr_author_id=$(printf '%s' "$pr_payload" |
            jq -er 'select(.user.id | type == "number") | .user.id') || {
            emit indeterminate "pull request payload carries no usable author identity"
            exit 2
        }
        pr_head=$(printf '%s' "$pr_payload" |
            jq -er 'select(.head.sha | type == "string") | .head.sha') || {
            emit indeterminate "pull request payload carries no usable head commit"
            exit 2
        }
        valid_sha "$pr_head" || {
            emit indeterminate "pull request payload reports a malformed head commit"
            exit 2
        }
        [ "$pr_head" = "$state_head" ] || {
            emit head-changed "PR head changed while findings were being adjudicated"
            exit 2
        }

        # The shared verdict defs are loaded here because the round-5 `-5`
        # exemption below needs `is_self_report`, which lives in them. This is
        # the same definition the top-level classifier and `readiness-gate.sh`
        # use, which is the point: one predicate, three consumers.
        inline_partition=$(jq -c \
            --argjson id "$actor_id" \
            --argjson author "$pr_author_id" \
            --arg head "$state_head" \
            "$codex_verdict_defs"'
              def ts($value):
                if ($value | type) == "string" and
                   ($value | test(
                     "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
                   ))
                then $value else null end;
              def edited_at:
                if (.updated_at // null) == null then ts(.created_at)
                else ts(.updated_at) end;
              . as $all |
              [$all[] | select(
                .user.id? == $id and (.original_commit_id? == $head)
              )] as $bot_all |
              # Challenge round 5, finding `challenge-r5-codex-adversarial-5`
              # (confirmed P1, a CONTRACT BREAK against the governing file):
              # AGENTS.md says a self-fix summary — an unbadged report from
              # this bot describing a fix IT made, **in a thread** or as a
              # top-level comment — is informational and owed no second reply.
              # The top-level half was implemented in `verdict_class`, and
              # `readiness-gate.sh` implements the thread half, but THIS
              # partition selected every bot comment on the head with no
              # exemption at all. So the bot own unbadged summary, posted
              # after a session replied "Fixed in <sha>", held the cycle open
              # and was named as the accepted finding evidence.
              #
              # It survived five rounds because every #675 fixture in this
              # suite is top-level; the inline half of that sentence had no
              # case, which is exactly how the two implementations diverged
              # unnoticed. Same predicate as the other two consumers, so all
              # three now answer the same question the same way.
              [$bot_all[] | select(is_self_report | not)] as $bot |
              [$bot[] |
                . as $comment |
                ts($comment.created_at) as $posted |
                ($comment | edited_at) as $edited |
                # Challenge round 3, finding `challenge-r3-codex-adversarial-8`
                # (confirmed P2): GitHub sets `in_reply_to_id` to the THREAD
                # ROOT on every reply, not to the comment being answered, so
                # matching `in_reply_to_id == $comment.id` only ever
                # adjudicated a bot comment that was itself the root. A bot
                # comment posted INTO an existing thread could never be
                # answered — no reply names it — while `readiness-gate.sh` and
                # `ai/agents/integrator.md` both group by root and reported the
                # thread answered. Three implementations, two answers, and
                # `settle` refuses inline targets, so the head could not be
                # cleared. Grouping by root here makes all three agree.
                ($comment.in_reply_to_id // $comment.id) as $root |
                [$all[] | select(
                  (($root | type) == "number") and
                  ((.in_reply_to_id // .id) == $root) and
                  ((.id? // null) != $comment.id) and
                  ((.user.id? | type) == "number") and
                  (.user.id != $id) and
                  ((((.author_association? // "") |
                      (. == "OWNER" or . == "MEMBER" or . == "COLLABORATOR"))) or
                    (.user.id == $author)) and
                  ($posted != null) and
                  (ts(.created_at) != null) and
                  (ts(.created_at) > $posted)
                ) | ts(.created_at)] as $replies |
                {
                  comment: (
                    if ($comment.id? | type) == "number"
                    then $comment.id else null end
                  ),
                  # Challenge round 5, finding `challenge-r5-codex-adversarial-6`
                  # (confirmed P2): `unanswered[]` emitted the per-comment id
                  # while `ai/agents/integrator.md` tells the agent to feed it
                  # into `unanswered_thread_roots`, and the schema defines
                  # those as THREAD ids. A bot comment posted into an existing
                  # thread is not its own root, so the agent was handed a value
                  # the field does not accept. The root is what the reply
                  # endpoint takes too, so it is the useful id either way.
                  root: $root,
                  path: (
                    if ($comment.path? | type) == "string"
                    then $comment.path else null end
                  ),
                  review: (
                    if ($comment.pull_request_review_id? | type) == "number"
                    then $comment.pull_request_review_id else null end
                  ),
                  adjudicated: (
                    ($replies | length) > 0 and $edited != null and
                    (($replies | max) > $edited)
                  )
                }
              ] as $classified |
              {
                unadjudicated:
                  ([$classified[] | select(.adjudicated | not)] | length),
                # harmon-devkit#737 defect 1: every unanswered bot thread on
                # this head, from EVERY review that posted one. The partition
                # was already head-scoped rather than review-scoped, so the
                # count was right; what a caller got back was one accepted
                # review id, which cannot name findings that came from two
                # reviews 18 minutes apart (observed on harmon-devkit#720, where
                # the 14 inline findings of the second review went unanswered
                # until the readiness gate caught them after every integration
                # round was spent). Enumerating them is what lets the caller
                # answer all of them in the round that surfaced them.
                unanswered:
                  ([$classified[] | select(.adjudicated | not) |
                    {thread_root: .root, comment_id: .comment,
                     review_id: .review, path: .path}]),
                unattributed:
                  ([$classified[] | select(.review == null)] | length),
                attributed:
                  ([$classified[] | select(.review != null) | .review] | unique),
                settled: (
                  if ([$classified[] | select(.review == null)] | length) > 0
                  then []
                  else
                    [$classified[] | .review] | unique |
                    map(select(. as $review |
                      [$classified[] | select(.review == $review)] |
                      all(.adjudicated)))
                  end
                )
              }
            ' "$workdir/inline.json")
        inline_unadjudicated=$(printf '%s' "$inline_partition" |
            jq -er '.unadjudicated | select(type == "number")') || {
            emit indeterminate "current-head inline findings could not be partitioned"
            exit 2
        }
        settled_reviews=$(printf '%s' "$inline_partition" |
            jq -ce '.settled | select(type == "array")') || {
            emit indeterminate "current-head inline findings could not be partitioned"
            exit 2
        }
        unattributed_findings=$(printf '%s' "$inline_partition" |
            jq -er '.unattributed | select(type == "number")') || {
            emit indeterminate "current-head inline findings could not be partitioned"
            exit 2
        }
        attributed_reviews=$(printf '%s' "$inline_partition" |
            jq -ce '.attributed | select(type == "array")') || {
            emit indeterminate "current-head inline findings could not be partitioned"
            exit 2
        }
        if [ "$inline_unadjudicated" -gt 0 ]; then
            inline_findings_review_id=$(printf '%s' "$inline_partition" | jq -r '
              (.settled // []) as $s |
              [(.attributed // [])[] |
               select(. as $r | $s | index($r) | not)] |
              first // null | tostring | if . == "null" then "" else . end
            ')
            if [ -z "$inline_findings_review_id" ]; then
                inline_findings_review_id=$(jq -r \
                    --argjson id "$actor_id" \
                    --arg head "$state_head" '
                      [.[] | select(
                        .user.id? == $id and .commit_id? == $head and
                        ((.id? | type) == "number")
                      ) | .id | tostring] | last // ""
                    ' "$workdir/reviews.json")
            fi
            inline_unanswered_extra=$(printf '%s' "$inline_partition" |
                jq -c '{unanswered: (.unanswered // [])}') || {
                emit indeterminate "unanswered current-head inline threads could not be enumerated"
                exit 2
            }
            # Challenge round 3, finding `challenge-r3-codex-adversarial-7`
            # (confirmed P2): `emit` omits `accepted` when the id is empty,
            # but BOTH schemas require `accepted` on exit 10, so an exit 10
            # with no citable review produced a result the validator rejects —
            # the caller could not report the finding at all.
            #
            # A review is not the only thing that can be cited, and the
            # finding is real either way: an inline comment with no fetchable
            # review behind it (no review by the actor on this head, or one
            # this check never saw) is still an unanswered finding, and the
            # COMMENT is perfectly good accepted evidence for it. Cite that
            # rather than downgrading a real finding to indeterminate.
            inline_findings_surface=review
            inline_findings_id=$inline_findings_review_id
            if [ -z "$inline_findings_id" ]; then
                inline_findings_surface=comment
                inline_findings_id=$(printf '%s' "$inline_partition" | jq -r '
                  [(.unanswered // [])[] |
                   select((.comment_id | type) == "number") | .comment_id] |
                  first // "" | tostring
                ')
            fi
            [ -n "$inline_findings_id" ] || {
                emit indeterminate "current-head inline findings are unanswered but carry no citable comment or review id"
                exit 2
            }
            emit findings "current-head inline review findings are unanswered by a trusted in-thread reply" \
                "$inline_findings_surface" "$inline_findings_id" "$inline_unanswered_extra"
            exit 10
        fi
        adjudicated_findings=1
    fi

    # Pick the newest accepted current-head result after the latest trigger.
    # This is ordering, not attempt attribution: earlier attempts and pending
    # acknowledgements have no bearing on the decision. An empty review is an
    # ordering result only when current-head inline findings attribute to its
    # exact ID; an unattributed shell remains pending evidence below.
    #
    # Each candidate is tagged with its `surface` (review/comment/reaction).
    # Ids from different GitHub resource types are not chronologically
    # comparable — a review id and a comment id are drawn from unrelated
    # sequences — so when the newest timestamp is shared by candidates from
    # more than one surface, that tie is unresolvable here and `tie:true`
    # says so (harmon-devkit#1014 ruling 4, Codex cycle-1 finding
    # `4007296539`); a same-surface tie is still broken by id, same as
    # before. The bash `tie` check below acts on this only once every
    # non-codex finder mode has already exited, so this flag never changes
    # CodeRabbit/Copilot behavior.
    #
    # Integration remediation 1 (2026-09-14, Codex cloud review on `a5bc99a`,
    # confirmed finding `4010207991`) found two compounding problems with the
    # tie exit as it stood: (1) a `settle`d review/comment is never excluded
    # from tie consideration, so once a human disposes of the finding behind
    # a cross-surface tie, the exact same tie recurs on every later check —
    # an immutable indeterminate result the settlement can never clear,
    # reopening the #275 deadlock class this file works hard everywhere else
    # to avoid; (2) a tie where one side carries an actual badged finding
    # exited indeterminate before the review/comment classifiers below ever
    # got a chance to surface it as `findings`, discarding a concrete result
    # in favor of a shrug.
    #
    # Fixed by tagging each candidate `disposed` (its id is in
    # `disposed_reviews`/`disposed_comments`) rather than dropping it from
    # the array outright: a disposed candidate is answered, not a live
    # contender for "which surface is newest," but it must still be able to
    # BE `newest_result` on its own — the pre-existing `disposed_applied`
    # terminal-clean exit further below depends on a solo disposed finding
    # (nothing else posted on this head) still resolving to its own
    # time/id, exactly as before this fix. So disposed candidates are
    # excluded only from the *diversity* check that decides whether a tie is
    # genuinely live (`$top_live`), never from the candidate pool itself:
    # when nothing live ties with it, a disposed candidate (or several
    # disposed candidates sharing one surface) still resolves normally,
    # same-surface id-tiebreak included; when it ties with something live
    # from a different surface, only the live side counts toward "is this
    # ambiguous," and an `actionable` (severity-badged) live candidate is
    # preferred over declaring an unresolvable tie — findings dominate an
    # ambiguous ordering the same way they already dominate everywhere else
    # in this file. This flag does not itself have to name the single
    # correct finding — not declaring `tie:true` is enough for control to
    # reach the independent `review_result`/`comment_result` classifiers
    # below, which detect and cite the real finding on their own regardless
    # of what `newest_result` pointed at. A live tie with no actionable side
    # is still genuinely unresolvable and still exits indeterminate exactly
    # as before.
    newest_result_record=$(jq -nr \
        --argjson id "$actor_id" \
        --arg head "$state_head" \
        --arg requested "$state_requested" \
        --arg success "$finder_success_reaction" \
        --argjson attributed "$attributed_reviews" \
        --argjson disposed_reviews "$disposed_reviews" \
        --argjson disposed_comments "$disposed_comments" \
        --slurpfile reviews "$workdir/reviews.json" \
        --slurpfile comments "$workdir/comments.json" \
        --slurpfile reactions "$workdir/reactions.json" \
        "$codex_verdict_defs"'
          ([
            $reviews[0][] | select(
              .user.id? == $id and .commit_id? == $head and
              (((.body? // "") != "") or
               (((.id? | type) == "number") and
                (.id as $rid | $attributed | index($rid) != null))) and
              ((.submitted_at? // "") > $requested) and
              ((.id? | type) == "number")
            ) | {time: .submitted_at, id: .id, surface: "review",
                 actionable: has_severity_marker,
                 disposed: ((.id as $rid | $disposed_reviews | index($rid)) != null)}
          ] + [
            $comments[0][] | select(.user.id? == $id) |
            # harmon-devkit#675: an unbadged self-report body is not evidence
            # about the review at all, so it must not be able to win "newest
            # result" and hold a genuinely clean cycle at pending.
            select(verdict_class != "informational") |
            ((.body // "") |
              try match(
                "Reviewed commit[^0-9a-fA-F]+([0-9a-fA-F]{7,40})";
                "i"
              ).captures[0].string catch "") as $prefix |
            select($prefix != "") |
            select(($head | ascii_downcase) | startswith($prefix | ascii_downcase)) |
            select((.created_at? // "") > $requested) |
            select(.id? | is_positive_integer) |
            {time: .created_at, id: .id, surface: "comment",
             actionable: has_severity_marker,
             disposed: ((.id as $cid | $disposed_comments | index($cid)) != null)}
          ] + [
            $reactions[0][] | select(
              .user.id? == $id and .content? == $success and
              ((.created_at? // "") >= $requested) and
              ((.id? | type) == "number")
            ) | {time: .created_at, id: .id, surface: "reaction",
                 actionable: false, disposed: false}
          ]) as $candidates |
          (if ($candidates | length) == 0 then {time:"",id:"",tie:false}
           else
             ($candidates | max_by(.time) | .time) as $max_time |
             ($candidates | map(select(.time == $max_time))) as $top |
             ($top | map(select(.disposed | not))) as $top_live |
             if ($top_live | length) == 0 then
               ($top | sort_by(.surface, .id) | last) as $winner |
               {time: $winner.time, id: $winner.id, tie:false}
             elif ($top_live | map(.surface) | unique | length) > 1 then
               ($top_live | map(select(.actionable))) as $actionable_top |
               if ($actionable_top | length) > 0 then
                 ($actionable_top | sort_by(.surface, .id) | last) as $winner |
                 {time: $winner.time, id: $winner.id, tie: false}
               else
                 {time: $max_time, id:"", tie:true}
               end
             else
               ($top_live[0].surface) as $live_surface |
               ($top | map(select(.surface == $live_surface)) | sort_by(.id) | last) as $winner |
               {time: $winner.time, id: $winner.id, tie:false}
             end
           end) |
          [.time, (.id | tostring), (.tie | tostring)] | join(",")
        ')
    # `@tsv` (and any IFS made only of tab/space/newline) collapses a run of
    # empty fields on read: bash read treats those three characters as IFS
    # whitespace and strips/merges them regardless of how many are
    # consecutive, which would silently reshuffle a row with an empty middle
    # field (id:"" on the tie branch above) into the wrong variables. A comma
    # is not in that class and cannot appear in any of these three fields (an
    # ISO-8601 second, a bare integer, or true/false), so read below splits on
    # it literally and every empty field stays exactly where it is.
    IFS=, read -r newest_result_time newest_result_id newest_result_tie \
        <<<"$newest_result_record"

    # --- Per-finder verdict classification (#804) ---
    # Non-codex verdict modes exit here. The codex clean-sentence classification
    # (the massive block below) only runs for clean-sentence mode.
    if [ "$finder_verdict_mode" = "actionable-count" ]; then
        # CodeRabbit: parse review bodies for "actionable comments posted: N".
        # N=0 means clean; N>0 means findings; no match means pending.
        actionable_review_id=""
        actionable_review_time=""
        actionable_count=-1
        while IFS='	' read -r rid rtime rbody_count; do
            [ -n "$rid" ] || continue
            actionable_count=$rbody_count
            actionable_review_id=$rid
            actionable_review_time=$rtime
        done < <(jq -r \
            --argjson id "$actor_id" \
            --arg head "$state_head" \
            --arg pattern "$finder_actionable_pattern" '
              [.[] | select(
                .user.id? == $id and
                (.commit_id? == $head) and
                ((.body // "") != "")
              ) | {
                id: (if (.id? | type) == "number" then (.id | tostring) else "" end),
                time: (.submitted_at // ""),
                count: ((.body // "") | (try (match($pattern; "i").captures[0].string | tonumber) catch -1))
              }] | sort_by(.time) | .[] |
              [.id, .time, (.count | tostring)] | @tsv
            ' "$workdir/reviews.json" 2>/dev/null)

        if [ "$adjudicated_findings" = "1" ] && [ -n "$actionable_review_id" ]; then
            [ "$actionable_review_time" \> "$state_requested" ] ||
                bounded_wait "adjudicated findings have no accepted review result after the latest trigger"
            require_latest_window_elapsed
            emit clean "current-head findings are all adjudicated by trusted in-thread replies" \
                review "$actionable_review_id"
            exit 0
        fi

        if [ "$actionable_count" -gt 0 ]; then
            emit findings "actionable review comments reported by finder" \
                review "$actionable_review_id"
            exit 10
        elif [ "$actionable_count" -eq 0 ]; then
            [ -n "$actionable_review_id" ] &&
                [ "$actionable_review_time" \> "$state_requested" ] ||
                bounded_wait "clean evidence was not created after the latest trigger"
            require_latest_window_elapsed
            emit clean "finder reported zero actionable comments" \
                review "$actionable_review_id"
            exit 0
        fi
        bounded_wait "no terminal current-head evidence from actionable-count finder yet"
    fi

    if [ "$finder_verdict_mode" = "inline-comment-count" ]; then
        # Copilot: verdict is purely inline-comment-driven. If we got here,
        # any unadjudicated inline findings already exited at 10 above.
        # Check for a submitted review (evidence the finder ran).
        copilot_review_id=$(jq -r \
            --argjson id "$actor_id" \
            --arg head "$state_head" \
            --arg after "$state_requested" '
              [.[] | select(
                .user.id? == $id and
                (.commit_id? == $head) and
                ((.submitted_at // "") > $after) and
                ((.id? | type) == "number")
              ) | .id | tostring] | last // ""
            ' "$workdir/reviews.json")

        if [ -n "$copilot_review_id" ]; then
            if [ "$adjudicated_findings" = "1" ] || [ "$inline_head_findings" -eq 0 ]; then
                require_latest_window_elapsed
                emit clean "requested-reviewer finder submitted a review with no unadjudicated findings" \
                    review "$copilot_review_id"
                exit 0
            fi
        fi
        bounded_wait "no terminal current-head evidence from inline-comment-count finder yet"
    fi

    # Both non-codex finder modes above always exit internally (a terminal
    # `emit`/`exit` on every branch, `bounded_wait` on falling through), so
    # everything from here down runs only for the clean-sentence/codex path
    # this issue scopes to.
    #
    # harmon-devkit#1014 ruling 4: act on the cross-surface tie flagged above.
    if [ "$newest_result_tie" = "true" ]; then
        emit indeterminate "the newest current-head result is tied across surfaces at $newest_result_time and cannot be ordered"
        exit 2
    fi

    # harmon-devkit#1014 ruling 6 (Codex cycle-1 finding `4007296552`): a
    # `Reviewed commit` top-level comment from the actor, naming this exact
    # head, is candidate verdict evidence. The numeric-id filter both
    # `newest_result_record` above and `comment_candidates` below apply
    # exists so `.id` can be used as a tiebreak and as `accepted.id` — it is
    # not a statement that a comment without one doesn't count. Silently
    # dropping one let the checker fall back to older or absent evidence
    # while real, unclassifiable evidence about this head sat right there;
    # fail closed instead.
    #
    # Integration remediation 2 (2026-09-15, Codex cloud review on `30b613c`,
    # confirmed finding `4010671551`) found this scan itself used a looser
    # `type == "number"` check than the `is_positive_integer` predicate the
    # candidate filters use, so a fractional or non-positive id (JSON type
    # still "number") slid past THIS scan while being silently excluded from
    # candidacy elsewhere — an older, unrelated clean result could then be
    # accepted instead of failing closed on the newer, unclassifiable
    # comment. Matching the predicate here closes that gap.
    # Informational self-reports (harmon-devkit#675) are deliberately NOT in
    # this scan: the whole point of that class is that such a body is not
    # evidence about the review, so an unusable id on one loses nothing there
    # is to lose.
    malformed_top_level=$(jq -r \
        --argjson id "$actor_id" \
        --arg head "$state_head" \
        "$codex_verdict_defs"'
          [.[] | select(.user.id? == $id) |
            select(verdict_class != "informational") |
            select(
              ((.body // "") |
                try match(
                  "Reviewed commit[^0-9a-fA-F]+([0-9a-fA-F]{7,40})";
                  "i"
                ).captures[0].string catch "") as $prefix |
              ($prefix != "") and
              (($head | ascii_downcase) | startswith($prefix | ascii_downcase))
            ) |
            select((.id? | is_positive_integer) | not)
          ] | length
        ' "$workdir/comments.json") || {
        emit indeterminate "current-head conversation comments could not be scanned for malformed ids"
        exit 2
    }
    if [ "$malformed_top_level" -gt 0 ]; then
        emit indeterminate "a Reviewed-commit top-level comment from the finder has no usable numeric id"
        exit 2
    fi

    # THE REJECTION FORM (challenge round 3, findings
    # `challenge-r3-codex-adversarial-2` and `-3`, both P1, disposition SPLIT;
    # the summary-table verdict surface it replaces is carried in #1117).
    #
    # Rounds 1 to 3 each tried to bind a badged comment to a head by PARSING
    # its body, and each attempt reproduced a way to lose the badge: the
    # Completed-row arm, then the header-driven columns, then a guard that
    # asked whether the table named *any* commit when the question was whether
    # it named *this* one — and whose `indeterminate` exit was unsettleable by
    # construction, because it fired exactly when the binding it needed was
    # unavailable.
    #
    # Nothing here derives a head any more. The reservation already pins one
    # repo, one PR and one head, and the trigger already scopes the cycle, so a
    # badged comment from the pinned actor posted after that trigger is either
    # bound by its own `Reviewed commit` line — handled by the ordinary
    # candidate path below, with its GitHub-verified prefix resolve — or it is
    # not bound at all, and then it BLOCKS until a human settles it by comment
    # id. `settle` accepts exactly that shape (see its own comment), so the
    # block is always answerable: no parse, no unbindable class, and no way for
    # a badge to be silently dropped.
    #
    # Fail direction: a badged comment about some OTHER head that names no
    # commit also blocks here. That is one recorded disposition, which is the
    # cheap side of this trade — the expensive side is the false clean this
    # whole family of bugs produced.
    # Challenge round 4, findings `challenge-r4-codex-adversarial-1` and `-2`
    # (both confirmed P1). Two independent ways this scan dropped a live badge:
    #
    #   -1  It ended `sort_by(...) | last`, so only the NEWEST unbound badge
    #       was ever considered and the disposed check tested only that one.
    #       Settling the newest made every OLDER undisposed badge invisible —
    #       reproduced as exit 0 with a live unsettled P0. Every undisposed
    #       badge blocks now, and the OLDEST is cited so repeated settling
    #       walks the list instead of clearing it in one go.
    #
    #   -2  The rejection form narrowed the stamp to `.created_at`, while the
    #       guard it replaced used `(.updated_at // .created_at)`. A badge
    #       ADDED BY AN EDIT after the trigger then vanished. One stamp policy
    #       had been applied to three sites whose safety directions are
    #       opposite: the CLEAN path wants the conservative `created_at` (that
    #       is round 3's own `-4`), and this BLOCKING path wants the generous
    #       one. Generous here, conservative there — they are different
    #       questions, not one setting.
    #
    # Disposed ids are filtered inside the query so "is anything still
    # unanswered" is one decision rather than a check against a single id.
    # Challenge round 5, finding `challenge-r5-codex-adversarial-4` (confirmed
    # P1, and a reproduced FALSE CLEAN over a live P0): this bound was strict
    # while the clean-by-reaction path it races is inclusive
    # (`.created_at? >= $requested`, pinned by the suite case
    # `exact-trigger current-request +1 is clean`). So a badge stamped in the
    # TRIGGERS OWN SECOND was dropped while a reaction in that same second
    # certified the cycle clean — one second was the whole difference, and the
    # result carried no `unbound_badged` key at all, so the caller was never
    # told the finding existed.
    #
    # Same hazard this file already ruled on for trigger reconstruction
    # (harmon-devkit#1014 ruling 3, quoted above `prior_trigger_candidates`):
    # GitHub stamps these to whole seconds, and comment ids are monotonic
    # within one resource type, so a same-second comment whose id EXCEEDS the
    # trigger comment id is provably after it. Inclusive bound plus that
    # tiebreak, applied here at last. Conservative direction on a blocking
    # scan: admitting one extra badge costs a recorded disposition, dropping
    # one costs the invariant this whole form exists to hold.
    unbound_badged_ids=$(jq -c \
        --argjson id "$actor_id" \
        --arg requested "$state_requested" \
        --argjson trigger "${state_trigger:-0}" \
        --argjson disposed "$disposed_comments" \
        "$codex_verdict_defs"'
          # Review round 1, finding `review-r1-codex-verification-1` (confirmed
          # P1): round 5 made the stamp `(.updated_at // .created_at)` but left
          # the same-second tiebreak as `.id > $trigger` — TWO DIFFERENT CLOCKS,
          # ONE TIEBREAK.
          #
          # The id tiebreak is only meaningful for a stamp that came from
          # `created_at`: a comment created in the triggers own second was
          # assigned a HIGHER id than the trigger if it came after it. A
          # comment that PRE-EXISTS the trigger and is EDITED in that second
          # has an equal stamp and necessarily a LOWER id, so the tiebreak
          # rejected it and the badge was dropped — with the inclusive
          # clean-by-reaction path free to exit 0 over it.
          #
          # Split by provenance: an equal stamp sourced from an EDIT is
          # admitted outright (an edit in the triggers second is
          # indistinguishable from one just after it, and admitting costs one
          # recorded disposition while dropping costs the invariant), while an
          # equal stamp sourced from `created_at` keeps the id tiebreak that
          # can actually order it.
          [.[] | select(.user.id? == $id) |
            . as $c |
            ((($c.updated_at // "") != "") and
             (($c.updated_at // "") != ($c.created_at // ""))) as $edited |
            (((.updated_at // .created_at) // "")) as $stamp |
            select(($stamp > $requested) or
                   (($stamp == $requested) and
                    ($edited or
                     (((.id? | type) == "number") and (.id > $trigger))))) |
            select(has_severity_marker) |
            select(((.body // "") |
              test("Reviewed commit[^0-9a-fA-F]+[0-9a-fA-F]{7,40}"; "i")) | not) |
            select(.id? | is_positive_integer) |
            # `. as $comment` first: jq evaluates `index(f)` with `.` bound to
            # the ARRAY being searched, so a bare `index(.id)` resolves `.id`
            # against `$disposed` and dies "Cannot index array with string id"
            # the moment anything IS disposed. Found by the round-4 fixture
            # `challenge-r4-codex-adversarial-1` at its settle step.
            . as $comment |
            select(($disposed | index($comment.id)) == null) |
            {id: $comment.id, time: $stamp}
          ] | sort_by(.time, .id) | map(.id)
        ' "$workdir/comments.json") || {
        emit indeterminate "conversation comments could not be scanned for unbound badged findings"
        exit 2
    }
    unbound_badged_count=$(printf '%s' "$unbound_badged_ids" |
        jq -er 'length') || {
        emit indeterminate "unbound badged findings could not be counted"
        exit 2
    }
    if [ "$unbound_badged_count" -gt 0 ]; then
        unbound_badged_oldest=$(printf '%s' "$unbound_badged_ids" |
            jq -er 'first | tostring')
        unbound_badged_extra=$(jq -cn \
            --argjson ids "$unbound_badged_ids" '{unbound_badged: $ids}')
        # Challenge round 4, finding `challenge-r4-codex-adversarial-8` (P3):
        # the earlier wording said the comment "cannot be bound to a head"
        # while `accepted.reviewed_commit` sat beside it carrying this cycle's
        # head. Both are true of different things and the phrasing hid that:
        # the COMMENT names no commit, and the CYCLE is pinned to this head by
        # its reservation — which is exactly why settling by comment id is
        # sound. The schema requires `accepted`, so the field stays; the
        # sentence now says which one is which.
        emit findings "$unbound_badged_count badged finding(s) from the finder name no reviewed commit of their own; this cycle is pinned to its reserved head, so settle each by comment id" \
            comment "$unbound_badged_oldest" "$unbound_badged_extra"
        exit 10
    fi

    # Classifying a current-head result is three-way, not binary, because
    # "I cannot tell" is a real answer and reporting it as `findings` is a lie
    # that costs a clean PR its gate.
    #
    # The two Codex formats are structurally disjoint. A clean verdict is a
    # top-level comment whose first line is "Codex Review: Didn't find any
    # major issues." plus a praise clause. Findings are a review body opening
    # "### Codex Review", and the findings themselves are INLINE comments
    # carrying a severity badge — which are rejected before this point. So the
    # prefix is the real signal, and the trailing clause is decoration.
    #
    # Equality on the whole line was the original bug: Codex always appends
    # praise, so it never matched and no PR could satisfy the gate. Screening
    # the tail for "no colon, no digit" replaced it and was not a boundary
    # either — it admitted "… issues. However a race remains". Narrowing to a
    # short exclamation then rejected the real reply "… issues. Chef's kiss."
    # Each rule traded one failure direction for the other because it was
    # trying to read intent out of free text.
    #
    #   * does not open with the verdict sentence   -> findings
    #   * carries a severity marker anywhere        -> findings
    #   * a later line is not Codex's own metadata  -> INDETERMINATE
    #   * otherwise                                 -> clean
    #
    # The trailing clause is NOT one of those tests, and there is no list of
    # praise strings here to extend. Two families of rule were tried in that
    # position and both shipped broken. An allowlist of observed praise could
    # not converge — eight distinct clauses, three of them inside twenty-five
    # minutes — and it deadlocked the PR that was extending it, because that
    # PR's own clause was unlisted. The shape test that replaced it was
    # revised three times and was fail-OPEN each time within minutes of
    # review ("Tests fail on Windows.", "Nice work, tests crash on Windows.",
    # ":warning:", "Work on it."). Length separates nothing in either
    # direction: the longest observed praise, "already looking forward to the
    # next diff.", is 41 characters, and the caveat "But a race remains." is
    # 19.
    #
    # So the decision rests only on the parts of Codex's output that do not
    # vary. The full reasoning, and the residual this knowingly accepts, are
    # in the comment above `verdict_class`. Do not add a fourth attempt at
    # parsing the clause here — the residual is tracked as
    # evanharmon1/harmon-devkit#285.
    #
    # The verdict LINE is not the whole story either: a concern parked further
    # down the body carries no badge, so constraining only the first line let
    # "…issues. Keep it up!\n\nHowever a race remains." read as clean.
    # Everything after the verdict line must therefore be Codex's own metadata
    # — the "Reviewed commit" line and its collapsed About block — and any
    # other prose makes the result indeterminate.
    #
    # The About block is REMOVED rather than truncated at. Cutting the body at
    # the first "<details" validated only the text before it, so a concern
    # appended after the closing tag was invisible. An unterminated block does
    # not match the removal and its contents then fail the check, which is the
    # right direction.
    #
    # Removal is anchored on the block's SUMMARY, not on "<details" alone.
    # Discarding any collapsed block would let a concern hide inside one. The
    # summary is a stable identifier; the block's body is Codex's prose and is
    # deliberately not asserted on, because a reworded boilerplate would then
    # fail the gate on every PR. Residual, accepted knowingly: unbadged text
    # inside the genuine About block passes. A BADGED finding does not —
    # has_severity_marker scans the whole body, block included.
    #
    # And the metadata line is matched WHOLE. `startswith` on the label
    # accepted "**Reviewed commit:** `sha` However a race remains.", which is
    # the same trailing-text hole as the verdict line had, one line lower.
    # A Codex findings review is a body opening "### Codex Review" whose actual
    # findings ARE the inline comments partitioned above — `verdict_class` calls
    # that body `findings` because it does not open with the clean sentence. So
    # once a review's own findings are adjudicated, re-blocking on the review
    # that carried them would make the relaxation pointless: the same settled
    # findings, counted a second time from the other side.
    #
    # The correlation is PER REVIEW, via the `pull_request_review_id` each
    # inline comment carries. Same-head aggregation is not enough, and the
    # two-attempt contract makes the counterexample routine rather than exotic:
    # two findings reviews on one head, the first with adjudicated inline
    # comments and the second stating its finding in the review body alone. A
    # global "something was adjudicated" flag suppresses BOTH, and the check
    # reports adjudicated-clean over an unanswered finding.
    #
    # So a findings-classified current-head review is settled only when it has
    # at least one current-head bot inline comment attributed to it AND every
    # such comment is adjudicated. A findings review with nothing attributed to
    # it is never in the settled set, which subsumes the earlier rule about a
    # findings review with no inline comments at all. A settled review
    # contributes neither `findings` nor `clean` to the aggregate below — it is
    # answered, not a verdict — so an `unrecognized` sibling is still seen.
    #
    # One more condition, and it is not optional: a review whose BODY carries a
    # severity badge is never settled by its inline comments, however well
    # adjudicated those are. Codex states some findings in the review body
    # itself, and attribution cannot reach them — there is no inline comment to
    # reply to — so reclassifying the whole review on the strength of its
    # attributed comments would discard the badged one in silence.
    #
    # That test is `has_severity_marker`, the same whole-body scan
    # `verdict_class` uses, and it is deliberately content-NEGATIVE: it asks
    # whether a stable, machine-emitted badge is ABSENT, never what the prose
    # means. It therefore does not reopen the free-text failure family
    # documented above `verdict_class` — nothing here reads a clause, ranks a
    # phrasing, or maintains a corpus of observed wording.
    #
    # The badge test alone is not enough, for the reason the residual above
    # `verdict_class` records: an UNBADGED concern carries no marker. So a
    # settled review's body must additionally be CARRIER-ONLY — heading, the
    # pinned boilerplate sentence, whole-line Reviewed-commit metadata, the
    # About block, and nothing else non-blank (`is_carrier_only`). Between the
    # two tests the settled path has no free-text surface at all: a badge makes
    # it `findings`, and any other prose makes it not-settled, which is also
    # `findings`.
    #
    # Both failure directions therefore RE-BLOCK. If Codex rewords its
    # boilerplate or restyles its heading, settlement stops matching and the
    # check gates a PR it could have released; it never releases one it should
    # have gated. That is the opposite trade from the verdict line, where
    # pinning the tail deadlocked real PRs — there the strict reading was
    # fail-closed toward *blocking clean work*, here it is fail-closed toward
    # blocking work that still has an open finding.
    # `body_text != ""` drops EMPTY-BODY reviews from verdict classification,
    # and only from verdict classification. GitHub auto-creates a body-less
    # COMMENTED review
    # shell to carry inline comments (reply shells, and Codex's own shell
    # posted before its inline findings land), and an empty body is no
    # evidence in either direction: it has no verdict to be clean and no
    # free-text surface where an unanswered concern could hide — anything it
    # carries is inline comments, which the inline gate above already
    # classifies on their own. Once those comments attribute to its exact
    # review ID, the review timestamp orders their adjudicated result; an
    # unattributed shell remains no result at all. Classifying the shell itself
    # would read it as
    # `findings` (no clean opening sentence) and hard-block a cycle whose
    # real review has not arrived yet. `fetched_reviews` below deliberately
    # still includes shells: inline comments attribute to them by review ID,
    # and dropping the ID would make those comments read as naming a review
    # nobody fetched.
    # A DANGLING shell — an empty-body current-head review by the actor with
    # no inline comment attributed to it — is a review still in flight:
    # Codex posts the shell first and its verdict or findings only after, so
    # clean evidence OLDER than the newest dangling shell may be about to be
    # contradicted and is not accepted, while evidence NEWER than the shell
    # stands (that is the normal shell -> verdict order, so an abandoned
    # shell ages out instead of deadlocking the cycle). Every clean exit
    # below compares its own evidence timestamp against this barrier;
    # GitHub's ISO-8601 UTC strings compare correctly as strings.
    shell_barrier=$(jq -r \
        --argjson id "$actor_id" \
        --arg head "$state_head" \
        --arg requested "$state_requested" \
        --argjson attributed "$attributed_reviews" '
          [.[] | select(
            .user.id? == $id and
            (.commit_id? == $head) and
            ((.submitted_at? // "") > $requested) and
            ((.body // "") == "") and
            ((.id? | type) == "number")
          ) |
          select(.id as $rid | ($attributed | index($rid)) | not) |
          .submitted_at? | select(type == "string")] | max // ""
        ' "$workdir/reviews.json")

    # Did any recorded disposition actually apply on this head? A disposed
    # finding contributes neither `findings` nor `clean` to the aggregates, so
    # without this the settle path could only ever reach a terminal state by
    # borrowing an unrelated clean verdict or reaction — and on its own it fell
    # through to the bounded wait and escalated, which is the deadlock `settle`
    # exists to end.
    disposed_applied=0
    disposed_review_hits=$(jq -r \
        --argjson id "$actor_id" \
        --arg head "$state_head" \
        --argjson disposed "$disposed_reviews" \
        "$codex_verdict_defs"'
          [.[] | select(
            .user.id? == $id and
            (.commit_id? == $head) and
            (body_text != "")
          ) | . as $review |
          select(verdict_class == "findings") |
          select((($review.id? | type) == "number") and
                 (($disposed | index($review.id)) != null))
          ] | length
        ' "$workdir/reviews.json") || die "cannot evaluate recorded dispositions"
    [ "$disposed_review_hits" -eq 0 ] || disposed_applied=1
    review_result_record=$(jq -r \
        --argjson id "$actor_id" \
        --arg head "$state_head" \
        --arg requested "$state_requested" \
        --argjson settled "$settled_reviews" \
        --argjson disposed "$disposed_reviews" \
        "$codex_verdict_defs"'
          [.[] | select(
            .user.id? == $id and
            (.commit_id? == $head) and
            (body_text != "")
          ) |
          . as $review | verdict_class as $class |
          if ($review.submitted_at > $requested) or $class == "findings" then
           if $class == "findings" then
            # A recorded disposition settles the review BODY on its own,
            # badge and prose included — that is what was disposed of. It
            # says nothing about the inline comments hanging off that same
            # review, which keep their own reply-based path above.
            (if (($review.id? | type) == "number") and
                ($disposed | index($review.id))
             then {class:"settled",time:$review.submitted_at,id:$review.id}
             elif (($review.id? | type) == "number") and
                ($settled | index($review.id)) and
                ((has_severity_marker) | not) and
                is_carrier_only
             then {class:"settled",time:$review.submitted_at,id:$review.id}
             else {class:"findings",time:$review.submitted_at,id:$review.id} end)
           else {class:$class,time:$review.submitted_at,id:$review.id} end
          else {class:"none",time:$review.submitted_at,id:$review.id} end
          ] as $classified |
          if any($classified[]; .class == "findings") then
            ([$classified[] | select(.class == "findings")] |
             sort_by(.time, .id) | last)
          else ([$classified[] |
                  select(.class == "unrecognized" or .class == "clean")] |
                sort_by(.time, .id) | last // {class:"none",time:"",id:""}) end |
          [.class, .time, (.id | tostring)] | @tsv
        ' "$workdir/reviews.json")
    IFS=$'\t' read -r review_result review_result_time review_result_id <<<"$review_result_record"
    # The reviews this check actually saw for the current head, by ID. The
    # adjudicated-clean fallback below reconciles the two endpoints against
    # each other with it: an inline comment naming a review nobody fetched is
    # incomplete evidence, not a settled finding.
    fetched_reviews=$(jq -c \
        --argjson id "$actor_id" \
        --arg head "$state_head" '
          [.[] | select(
            .user.id? == $id and
            (.commit_id? == $head) and
            ((.id? | type) == "number")
          ) | .id] | unique
        ' "$workdir/reviews.json")
    findings_review_id=""
    if [ "$review_result" = "findings" ]; then
        findings_review_id=$(jq -r \
            --argjson id "$actor_id" \
            --arg head "$state_head" \
            --argjson disposed "$disposed_reviews" \
            --argjson settled "$settled_reviews" \
            "$codex_verdict_defs"'
              [.[] | select(
                .user.id? == $id and
                (.commit_id? == $head) and
                (body_text != "")
              ) | . as $review | verdict_class as $class |
              select($class == "findings") |
              select(
                (($review.id? | type) != "number") or
                (($disposed | index($review.id)) == null)
              ) |
              select(
                (($review.id? | type) != "number") or
                (($settled | index($review.id)) == null) or
                has_severity_marker or (is_carrier_only | not)
              ) |
              .id | tostring] | first // ""
            ' "$workdir/reviews.json")
        emit findings "current-head review requires adjudication" \
            review "$findings_review_id"
        exit 10
    fi
    comment_candidates="$workdir/comment-candidates.tsv"
    jq -r \
        --argjson id "$actor_id" \
        "$codex_verdict_defs"'
          .[] | select(.user.id? == $id) |
          # An unbadged self-report (harmon-devkit#675) is informational
          # rather than a finding, and contributes to no aggregate.
          select(verdict_class != "informational") |
          ((.body // "") |
            try match(
              "Reviewed commit[^0-9a-fA-F]+([0-9a-fA-F]{7,40})";
              "i"
            ).captures[0].string catch "") as $prefix |
          select($prefix != "") |
          select(.id? | is_positive_integer) |
          [
            $prefix,
            verdict_class,
            (.id | tostring),
            (.created_at // "")
          ] | @tsv
        ' "$workdir/comments.json" >"$comment_candidates"

    comment_result=none
    comment_result_time=""
    comment_result_id=""
    clean_comment_time=""
    clean_comment_id=""
    findings_comment_id=""
    while IFS='	' read -r prefix classification comment_id comment_created; do
        [ -n "$prefix" ] || continue
        valid_time "$comment_created" || {
            emit indeterminate "bot review comment carries a malformed creation time"
            exit 2
        }
        if [ "$classification" != "findings" ] &&
            ! [ "$comment_created" \> "$state_requested" ]; then
            continue
        fi
        grep -Eq '^[0-9a-fA-F]{7,40}$' <<<"$prefix" || {
            emit indeterminate "bot review comment contains a malformed commit prefix"
            exit 2
        }
        prefix_lower=$(printf '%s' "$prefix" | tr '[:upper:]' '[:lower:]')
        head_lower=$(printf '%s' "$state_head" | tr '[:upper:]' '[:lower:]')
        case "$head_lower" in "$prefix_lower"*) ;; *) continue ;; esac
        # A disposed finding contributes neither `findings` nor `clean`: it is
        # answered, not a verdict. Skipping it here rather than after the
        # resolve is deliberate — `settle` already resolved this exact prefix
        # against this exact head, and the head cannot have moved since (both
        # head checks above pin it), so the call would re-prove a fact the
        # disposition already carries.
        if [ "$classification" = "findings" ] && valid_uint "$comment_id" &&
            printf '%s' "$disposed_comments" |
            jq -e --argjson id "$comment_id" 'index($id) != null' >/dev/null; then
            disposed_applied=1
            continue
        fi
        resolved_payload=$(run_gh api "repos/$state_repo/commits/$prefix") ||
            transient_read_failure "cannot resolve a reviewed commit prefix through GitHub"
        resolved=$(printf '%s' "$resolved_payload" | jq -er '.sha') || {
            emit indeterminate "GitHub returned malformed commit-prefix data"
            exit 2
        }
        valid_sha "$resolved" || {
            emit indeterminate "GitHub returned an invalid resolved commit"
            exit 2
        }
        [ "$resolved" = "$state_head" ] || {
            emit indeterminate "reviewed commit prefix does not resolve to the current head"
            exit 2
        }
        if [ "$classification" = "findings" ]; then
            comment_result=findings
            [ -n "$findings_comment_id" ] || findings_comment_id=$comment_id
        elif [ "$comment_result" != "findings" ] && {
            [ "$comment_created" \> "$comment_result_time" ] || {
                [ "$comment_created" = "$comment_result_time" ] &&
                    [ "$comment_id" -gt "${comment_result_id:-0}" ]
            }
        }; then
            # Findings dominate. Non-finding classifications use provider
            # order, matching review bodies: a newer valid clean result may
            # supersede an older unrecognized one, but never vice versa.
            comment_result=$classification
            comment_result_time=$comment_created
            comment_result_id=$comment_id
        fi
        if [ "$classification" = "clean" ] && {
            [ "$comment_created" \> "$clean_comment_time" ] || {
                [ "$comment_created" = "$clean_comment_time" ] &&
                    [ "$comment_id" -gt "${clean_comment_id:-0}" ]
            }
        }; then
            clean_comment_time=$comment_created
            clean_comment_id=$comment_id
        fi
    done <"$comment_candidates"

    if [ "$comment_result" = "findings" ]; then
        emit findings "current-head conversation finding requires adjudication" \
            comment "$findings_comment_id"
        exit 10
    fi
    if [ "$comment_result" = "unrecognized" ] &&
        [ "$comment_result_time" = "$newest_result_time" ] &&
        [ "$comment_result_id" = "$newest_result_id" ]; then
        emit indeterminate "current-head result opens with the clean verdict but carries prose beyond Codex's own metadata"
        exit 2
    fi
    if [ "$review_result" = "unrecognized" ] &&
        [ "$review_result_time" = "$newest_result_time" ] &&
        [ "$review_result_id" = "$newest_result_id" ]; then
        emit indeterminate "current-head review opens with the clean verdict but carries prose beyond Codex's own metadata"
        exit 2
    fi

    # A positive reaction on this exact latest trigger is the one immediate
    # re-trigger terminal: its causal binding is unambiguous, so it need not
    # wait out the window. Findings have already exited above.
    like_evidence=$(jq -c \
        --argjson id "$actor_id" \
        --arg requested "$state_requested" '
          [.[] | select(
            .user.id? == $id and .content? == "+1" and
            (.created_at? >= $requested) and
            ((.created_at? | type) == "string") and
            ((.id? | type) == "number")
          )] | sort_by(.created_at, .id) | last // null
        ' "$workdir/reactions.json")
    like_time=$(printf '%s' "$like_evidence" | jq -r '.created_at? // ""')
    like_id=$(printf '%s' "$like_evidence" | jq -r '.id? // "" | tostring')
    if [ -n "$like_id" ]; then
        if [ -n "$shell_barrier" ] && ! [ "$like_time" \> "$shell_barrier" ]; then
            emit pending "a newer empty review shell is still in flight for this head"
            exit 11
        fi
        emit clean "authenticated bot reacted positively on the exact latest trigger" \
            reaction "$like_id"
        exit 0
    fi

    # harmon-devkit#1014 ruling 5 (Codex cycle-1 finding `4007296546`):
    # `review_result` above is computed only from reviews with a non-empty
    # body — `verdict_class` needs body text — so an EMPTY-body review whose
    # inline findings are fully adjudicated never appears in it at all, even
    # though `newest_result_record` above already orders such a review ahead
    # of an older non-empty one (see its own "ordering, not attempt
    # attribution" comment). When that happens, `review_result` can read
    # "clean" from the older review while `newest_result` correctly points at
    # the newer, adjudicated one; forcing the clean branch below to match
    # `newest_result` against the OLDER review's evidence then bounded-waits
    # forever, because the older review can never become the newest one it
    # already lost to. The same shape applies to a NON-empty review too: a
    # findings review whose inline findings are fully adjudicated is
    # reclassified to "settled" (not "clean") by `review_result_record`
    # above, so it likewise falls out of `review_result` while still being
    # able to win `newest_result` on the strength of its non-empty body.
    # Detect either case directly — `newest_result` names a review that is a
    # member of `$settled_reviews`, the inline-reply-adjudication set — and
    # skip the clean branch so control reaches the existing
    # `adjudicated_findings` branch below instead. This is a pure exclusion:
    # it can only prevent entering the clean branch, never cause it to fire
    # when it wouldn't have otherwise.
    newest_is_settled_review=false
    if [ "$adjudicated_findings" = "1" ]; then
        newest_is_settled_review=$(jq -r \
            --arg time "$newest_result_time" \
            --arg id "$newest_result_id" \
            --argjson settled "$settled_reviews" '
              ([.[] | select(
                ((.id? | type) == "number") and ((.id | tostring) == $id) and
                ((.submitted_at? // "") == $time) and
                (.id as $rid | ($settled | index($rid)) != null)
              )] | length) > 0
            ' "$workdir/reviews.json")
    fi
    if { [ "$review_result" = "clean" ] || [ "$comment_result" = "clean" ]; } &&
        [ "$newest_is_settled_review" != "true" ]; then
        # The newest clean evidence must be NEWER than the dangling-shell
        # barrier above: an older clean result cannot vouch for a head whose
        # next review is already in flight.
        #
        # Strictly newer, deliberately. GitHub timestamps these resources to
        # whole seconds, so a shell and the verdict can tie, and a tie is
        # undecidable — the verdict may belong to the shell's review or
        # predate a review that is now in flight. `>` reads a tie as pending:
        # fail closed.
        clean_review_time=""
        clean_review_id=""
        if [ "$review_result" = "clean" ]; then
            # One query for both the timestamp and the review id it belongs
            # to (harmon-devkit#639 gauntlet challenge round 4, orchestrator-
            # authorized: expose which review result.integrator's schema-
            # required accepted.{surface,id} should report) — sort_by/last
            # rather than two separate `max` queries, so the id can never
            # drift from the timestamp that selected it.
            clean_review_evidence=$(jq -c \
                --argjson id "$actor_id" \
                --arg head "$state_head" \
                --arg requested "$state_requested" \
                "$codex_verdict_defs"'
                  [.[] | select(
                    .user.id? == $id and
                    (.commit_id? == $head) and
                    ((.submitted_at? // "") > $requested) and
                    (body_text != "")
                  ) | select(verdict_class == "clean") |
                  select((.submitted_at? | type) == "string" and (.id? | type) == "number")] |
                  sort_by(.submitted_at, .id) | last // null
                ' "$workdir/reviews.json")
            clean_review_time=$(printf '%s' "$clean_review_evidence" | jq -r '.submitted_at? // ""')
            clean_review_id=$(printf '%s' "$clean_review_evidence" | jq -r '.id? // "" | tostring')
        fi
        newest_clean=$clean_review_time
        newest_clean_surface=review
        newest_clean_id=$clean_review_id
        if [ "$clean_comment_time" \> "$newest_clean" ] || {
            [ "$clean_comment_time" = "$newest_clean" ] &&
                [ "${clean_comment_id:-0}" -gt "${newest_clean_id:-0}" ]
        }; then
            newest_clean=$clean_comment_time
            newest_clean_surface=comment
            newest_clean_id=$clean_comment_id
        fi
        if [ -n "$shell_barrier" ] && ! [ "$newest_clean" \> "$shell_barrier" ]; then
            emit pending "a newer empty review shell is still in flight for this head"
            exit 11
        fi
        [ -n "$newest_clean" ] || bounded_wait "the cycle has no terminal current-head evidence yet"
        [ -n "$newest_clean_id" ] || bounded_wait "clean evidence has no accepted object ID"
        [ "$newest_clean" = "$newest_result_time" ] &&
            [ "$newest_clean_id" = "$newest_result_id" ] ||
            bounded_wait "the newest current-head result is not clean"
        require_latest_window_elapsed
        emit clean "authenticated bot posted the newest current-head result after the latest trigger" \
            "$newest_clean_surface" "$newest_clean_id"
        exit 0
    fi

    # Last of the clean paths, deliberately after the three above: a verdict
    # Codex itself posted for this head is stronger evidence than findings the
    # session answered, so it is reported as such. The detail differs from the
    # others on purpose — the caller must be able to tell "Codex said clean"
    # from "the findings were all answered", because only the second one means
    # a human wrote the rationale that now stands on the PR.
    #
    # Reaching it requires the two endpoints to AGREE, not merely for the
    # replies to check out. `unadjudicated == 0` is a statement about inline
    # comments alone, and on its own it can be true while the attribution that
    # justifies suppressing the findings review is missing: a comment with no
    # `pull_request_review_id` belongs to a review this check cannot name, and
    # an attributed ID absent from the fetched current-head reviews names one
    # it never saw. Either way the settled-review reasoning above rests on
    # evidence that is not there.
    #
    # That is `indeterminate`, deliberately — not `findings` and not `clean`.
    # Nothing here says the findings are open (every reply checked out) and
    # nothing says they are settled (the review side is unaccounted for). It is
    # the same three-way discipline `verdict_class` uses: incomplete evidence
    # is its own answer, and the caller escalates rather than acting on a
    # verdict this check cannot support.
    if [ "$adjudicated_findings" = "1" ]; then
        jq -ne \
            --argjson unattributed "$unattributed_findings" \
            --argjson attributed "$attributed_reviews" \
            --argjson settled "$settled_reviews" \
            --argjson fetched "$fetched_reviews" '
              ($unattributed == 0) and
              (($attributed | length) > 0) and
              all($attributed[]; . as $review | $settled | index($review)) and
              all($settled[]; . as $review | $fetched | index($review))
            ' >/dev/null || {
            emit indeterminate "current-head findings are adjudicated but their review attribution is incomplete across the comment and review endpoints"
            exit 2
        }
        # Here the barrier is UNCONDITIONAL: any dangling shell holds this
        # exit at pending, with no timestamp comparison at all. Two earlier
        # revisions tried to time-order the shell against inline activity —
        # first the whole endpoint (an unrelated comment cleared it), then
        # the adjudication evidence (a reply to an EARLIER finding cleared a
        # NEWER shell, and a reply's author needs no trust to move the max) —
        # and both were fail-open, because a shell is opaque: nothing in it
        # says which future content it carries, so no other thread's
        # timestamps can be correlated against it. What CAN be said is where
        # a dangling shell at this exit can still be headed. The legitimate
        # shell-then-verdict flow never arrives here — a clean verdict is a
        # review body, a top-level comment, or a reaction, and each exits
        # above through its own time-ordered gate — so a shell that is still
        # dangling at this point is a review in flight or an abandoned one,
        # and both are pending: fail closed, bounded by the attempt window.
        # If an abandoned shell still dangles, this exit stays pending after
        # findings are adjudicated and the bounded window escalates.
        # Deliberate, not a gap: an actor shell nobody can
        # explain plus adjudicated findings is incomplete evidence, and the
        # checker's discipline for incomplete evidence is a human hand-off,
        # never a green it cannot support.
        if [ -n "$shell_barrier" ]; then
            emit pending "an empty review shell is still unresolved for this head"
            exit 11
        fi
        adjudicated_review_id=$(jq -r \
            --argjson settled "$settled_reviews" '
              [.[] | select((.id? | type) == "number") |
               . as $r | select($settled | index($r.id)) |
               {id: ($r.id | tostring), time: ($r.submitted_at // "")}] |
              sort_by(.time, (.id | tonumber)) | last // null | .id // ""
            ' "$workdir/reviews.json")
        adjudicated_review_time=$(jq -r \
            --argjson id "$adjudicated_review_id" '
              [.[] | select(.id? == $id)] | first | .submitted_at? // ""
            ' "$workdir/reviews.json")
        [ -n "$adjudicated_review_id" ] || bounded_wait "adjudicated findings have no accepted review result after the latest trigger"
        [ "$adjudicated_review_time" = "$newest_result_time" ] &&
            [ "$adjudicated_review_id" = "$newest_result_id" ] ||
            bounded_wait "the newest current-head result is not the adjudicated review"
        require_latest_window_elapsed
        emit clean "newest current-head findings after the latest trigger are adjudicated by trusted in-thread replies" \
            review "$adjudicated_review_id"
        exit 0
    fi

    # Every non-thread finding on this head carries a recorded disposition and
    # nothing on any surface contradicts it (findings and unrecognized results
    # exited above). That is terminal, and it is reported with its own detail:
    # a human wrote these dispositions, exactly as with the inline
    # adjudicated-clean path, and the caller must be able to tell that from a
    # verdict Codex itself posted.
    if [ "$disposed_applied" = "1" ]; then
        if [ -n "$shell_barrier" ]; then
            emit pending "an empty review shell is still unresolved for this head"
            exit 11
        fi
        # The detail names the DISPOSITIONS actually applied, not just that
        # some existed: "declined" and "filed" mean different things to
        # whoever reads this result, and a mixture means both happened.
        disposed_surface=""
        disposed_id=""
        disposed_review_latest=$(jq -r \
            --argjson disposed "$disposed_reviews" \
            --arg requested "$state_requested" '
              [.[] | select((.id? | type) == "number") |
               . as $r | select($disposed | index($r.id)) |
               select((.submitted_at // "") > $requested) |
               {id: ($r.id | tostring), time: ($r.submitted_at // "")}] |
              sort_by(.time, (.id | tonumber)) | last // null | .id // ""
            ' "$workdir/reviews.json")
        # `created_at` throughout. The summary comment's edit-time stamp went
        # out with the #718 verdict surface in challenge round 3 (carried in
        # #1117); every comment this block can now see is dated once, when it
        # was posted.
        # `> $requested` is DELIBERATE and stays: a settlement recorded before
        # the latest trigger cannot certify the re-review that trigger asked
        # for. `an earlier settled finding cannot make a re-trigger clean
        # without new evidence` pins it, and the reservation comment above
        # states the same rule from the other side — settlements persist for
        # the record, they do not certify a later attempt. Challenge round 3's
        # finding `challenge-r3-codex-adversarial-10` proposed removing this
        # filter and was adjudicated DECLINED as a false positive: removing it
        # is a fail-open and makes that pinned case fail.
        disposed_comment_latest=$(jq -r \
            --argjson disposed "$disposed_comments" \
            --arg requested "$state_requested" '
              [.[] | select((.id? | type) == "number") |
               . as $r | select($disposed | index($r.id)) |
               select((.created_at // "") > $requested) |
               {id: ($r.id | tostring), time: ($r.created_at // "")}] |
              sort_by(.time, (.id | tonumber)) | last // null | .id // ""
            ' "$workdir/comments.json")
        if [ -n "$disposed_review_latest" ]; then
            disposed_surface=review
            disposed_id=$disposed_review_latest
        fi
        if [ -n "$disposed_comment_latest" ]; then
            disposed_comment_time=$(jq -r \
                --argjson id "$disposed_comment_latest" '
                  [.[] | select(.id? == $id)] | first | .created_at? // ""
                ' "$workdir/comments.json")
            disposed_review_time=""
            if [ -n "$disposed_review_latest" ]; then
                disposed_review_time=$(jq -r \
                    --argjson id "$disposed_review_latest" '
                      [.[] | select(.id? == $id)] | first | .submitted_at? // ""
                    ' "$workdir/reviews.json")
            fi
            if [ -z "$disposed_surface" ] ||
                [ "$disposed_comment_time" \> "$disposed_review_time" ] || {
                [ "$disposed_comment_time" = "$disposed_review_time" ] &&
                    [ "$disposed_comment_latest" -gt "$disposed_review_latest" ]
            }; then
                disposed_surface=comment
                disposed_id=$disposed_comment_latest
            fi
        fi
        case "$disposed_surface" in
        review) disposed_latest_time=${disposed_review_time:-$(jq -r --argjson id "$disposed_id" '[.[] | select(.id? == $id)] | first | .submitted_at? // ""' "$workdir/reviews.json")} ;;
        comment) disposed_latest_time=$disposed_comment_time ;;
        *) disposed_latest_time= ;;
        esac
        [ -n "$disposed_id" ] || bounded_wait "settled findings have no accepted result after the latest trigger"
        [ "$disposed_latest_time" = "$newest_result_time" ] &&
            [ "$disposed_id" = "$newest_result_id" ] ||
            bounded_wait "the newest current-head result is not the settled finding"
        require_latest_window_elapsed
        emit clean "newest current-head non-thread findings after the latest trigger are settled: ${applied_dispositions:-recorded dispositions}" \
            "$disposed_surface" "$disposed_id"
        exit 0
    fi

    bounded_wait "no terminal current-head evidence yet"
    ;;

settle)
    # Inline findings are settled by a trusted reply in their own thread. A
    # badged finding stated in a top-level comment or in a review BODY has no
    # thread to reply to, so nothing on GitHub can ever record that a human
    # answered it and `check` reports `findings` for that head forever — the
    # #275 deadlock, reappearing on the two surfaces the reply rule cannot
    # reach. This command is the local record of that answer, and it is
    # deliberately narrow, and its DOMAIN IS WHAT `check` BLOCKS ON — every
    # body whose `verdict_class` is `findings`, badged or not — never "what
    # carries a badge" (challenge round 2, findings `-1`/`-3`; the pre-round-2
    # badge-only wording was still stated here and in the file header, which
    # is challenge round 5 finding `challenge-r5-codex-adversarial-3`). A
    # target must still come from the pinned actor and resolve to this state's
    # own head, or bind to it by comment id where the body names no commit of
    # its own.
    [ -n "$surface" ] && [ -n "$target_id" ] && [ -n "$disposition" ] &&
        [ -n "$note" ] && [ -n "$actor_id" ] || usage
    valid_uint "$actor_id" || die "invalid actor ID"
    valid_uint "$target_id" || die "invalid target ID"
    case "$surface" in
    comment | review) ;;
    *) die "surface must be comment or review" ;;
    esac
    case "$disposition" in
    declined | filed) ;;
    *) die "disposition must be declined or filed" ;;
    esac
    settled_at=$(now_utc)
    acquire_state_lock
    read_state

    state_repo=$(jq -r '.repo' "$state_file")
    state_pr=$(jq -r '.pr' "$state_file")
    state_head=$(jq -r '.head' "$state_file")
    state_attempt=$(jq -r '.attempt' "$state_file")
    state_requested=$(jq -r '.requested_at // empty' "$state_file")
    valid_repo "$state_repo" || die "state has an invalid repository"
    valid_uint "$state_pr" || die "state has an invalid PR number"
    valid_sha "$state_head" || die "state has an invalid head"
    valid_time "$state_requested" || die "state has an invalid request time"
    # `state_reserved` is deliberately left unset, which gives `run_gh` its flat
    # per-call budget: settlement is a human act that lands after the cycle
    # reported findings, often long after the attempt window closed, and
    # budgeting these reads against an elapsed reservation would leave them one
    # second to complete.

    case "$surface" in
    comment)
        target=$(run_gh api "repos/$state_repo/issues/comments/$target_id") ||
            die "cannot fetch conversation comment $target_id"
        printf '%s' "$target" | jq -e \
            --argjson id "$actor_id" \
            --argjson target "$target_id" \
            --arg suffix "/issues/$state_pr" '
              (.id == $target) and (.user.id? == $id) and
              ((.issue_url // "") | endswith($suffix))
            ' >/dev/null ||
            die "comment $target_id is not a Codex comment on this PR"
        # Same discipline `check` applies to a top-level result: the comment
        # must name a commit prefix that GitHub resolves to this head. A
        # disposition recorded against some other head answers nothing.
        # THE REJECTION FORM's other half (challenge round 3, findings
        # `challenge-r3-codex-adversarial-2`/`-3`; the summary-table binding
        # this replaces is carried in #1117).
        #
        # A comment binds itself to a head with a `Reviewed commit` line, and
        # when it carries one that binding is verified against GitHub exactly
        # as before — a disposition recorded against another head answers
        # nothing. What changed is the case with NO such line: `check` now
        # blocks on a badged comment it cannot bind, so `settle` has to be able
        # to answer it, or the block would be another stuck head. It can,
        # because the head does not need to come from the body at all: THIS
        # STATE already pins the repo, the PR and the head, and the caller is
        # naming one comment id on that reserved cycle.
        settle_prefix=$(printf '%s' "$target" | jq -r '
              (((.body // "") | [match(
                "Reviewed commit[^0-9a-fA-F]+([0-9a-fA-F]{7,40})";
                "i"
              ).captures[0].string] | first) // "")
            ')
        if [ -z "$settle_prefix" ]; then
            # Unbound: settled by comment id against this cycle's own head.
            # The actor, the PR and the `verdict_class == "findings"` domain
            # above have all already been checked, so nothing here is taken on
            # trust from the body.
            settle_resolved=$state_head
        else
            grep -Eq '^[0-9a-fA-F]{7,40}$' <<<"$settle_prefix" ||
                die "comment $target_id names a malformed reviewed commit"
            settle_prefix_lower=$(printf '%s' "$settle_prefix" |
                tr '[:upper:]' '[:lower:]')
            settle_head_lower=$(printf '%s' "$state_head" |
                tr '[:upper:]' '[:lower:]')
            case "$settle_head_lower" in
            "$settle_prefix_lower"*) ;;
            *) die "comment $target_id reviews a commit that is not this head" ;;
            esac
            settle_resolved_payload=$(run_gh api \
                "repos/$state_repo/commits/$settle_prefix") ||
                die "cannot resolve the reviewed commit prefix through GitHub"
            settle_resolved=$(printf '%s' "$settle_resolved_payload" |
                jq -er '.sha') ||
                die "GitHub returned malformed commit-prefix data"
            valid_sha "$settle_resolved" ||
                die "GitHub returned an invalid resolved commit"
            [ "$settle_resolved" = "$state_head" ] ||
                die "comment $target_id reviews a commit that is not this head"
        fi
        ;;
    review)
        target=$(run_gh api \
            "repos/$state_repo/pulls/$state_pr/reviews/$target_id") ||
            die "cannot fetch review $target_id"
        printf '%s' "$target" | jq -e \
            --argjson id "$actor_id" \
            --argjson target "$target_id" \
            --arg head "$state_head" '
              (.id == $target) and (.user.id? == $id) and (.commit_id? == $head)
            ' >/dev/null ||
            die "review $target_id is not a current-head Codex review"
        ;;
    esac

    case "$surface" in
    comment) target_result_time=$(printf '%s' "$target" | jq -r '.created_at // ""') ;;
    review) target_result_time=$(printf '%s' "$target" | jq -r '.submitted_at // ""') ;;
    esac
    valid_time "$target_result_time" ||
        die "target $target_id has no usable result timestamp"
    # Challenge round 2, findings `challenge-r2-codex-adversarial-1` and `-3`
    # (confirmed P1, disposition RESTRUCTURE): settle's domain is WHAT `check`
    # BLOCKS ON, not "what carries a badge".
    #
    # The badge-only rule was the second half of round 1's mistake. A bot
    # comment that `check` classifies `findings` but that carries no badge —
    # a self-report whose wording the `informational` test does not recognize,
    # say — exits 10 with no way to be answered: `settle` refused it for
    # having no badge, and there is no thread to reply in. The head was then
    # un-reviewable through this helper, which is strictly worse than the
    # "false block, recoverable by a human" the round-1 comment promised.
    #
    # Tying the domain to `verdict_class == "findings"` makes every blocking
    # shape answerable, which is what lets the classifier above fail CLOSED
    # safely: a body wrongly read as a finding now costs one recorded
    # disposition instead of stranding the commit. It still keeps settlement
    # off everything `check` does NOT block on — a clean verdict, a carrier
    # body, an unrecognized one, an informational self-report — because none
    # of those reaches `findings`.
    printf '%s' "$target" |
        jq -e "$codex_verdict_defs"' verdict_class == "findings"' >/dev/null ||
        die "target $target_id is not a finding this checker blocks on, so there is nothing to settle"

    # A disposition settles the TARGET, and a target can hold more than one
    # finding: Codex sometimes states several in one body. Since the entry is
    # keyed by object ID, settling any one of them would otherwise mark the
    # whole body answered and let the rest reach a clean verdict unaddressed —
    # and re-settling the same ID replaces the entry rather than adding to it,
    # so there is no way to represent the others.
    #
    # The fingerprint already binds the disposition to the exact body text, so
    # what is missing is not integrity but INTENT: nothing made the operator
    # say they had read all of it. `--covers N` is that statement, required
    # only where it is ambiguous. It is not a claim this command can verify —
    # no mechanism can judge whether an adjudication is any good — but it
    # cannot be satisfied by accident, which is the whole difference between
    # settling a body and settling the one finding you happened to notice.
    # Count RENDERED badges, not severity tokens. Codex writes a finding as
    # `![P2 Badge](https://img.shields.io/badge/P2-yellow…)`, which carries the
    # severity twice — alt text and URL — so a token scan reports two findings
    # for one and demands `--covers 2` for the ordinary single-finding case,
    # breaking the documented invocation. Matching the alt-text form counts
    # each badge once. A body that states findings as plain prose renders no
    # badge at all, so that shape falls back to the token scan, which is
    # correct for it.
    #
    # Since round 2 widened the domain above from "carries a badge" to "is
    # what `check` blocks on", a target can legitimately count ZERO: an
    # unbadged body that classifies `findings`. That needs no `--covers` —
    # there are no separately-badged findings to under-answer — and the
    # `> 1` guard below already says so without a special case.
    badge_count=$(printf '%s' "$target" |
        jq -r '((.body // "") | ascii_downcase) as $body |
               ([$body | scan("!\\[p[0-9]+ badge\\]")] | length) as $rendered |
               if $rendered > 0 then $rendered
               else ([$body | scan("\\bp[0-9]+\\b")] | length) end') ||
        die "cannot count the findings in target $target_id"
    if [ "$badge_count" -gt 1 ]; then
        [ -n "$covers" ] ||
            die "target $target_id carries $badge_count findings; pass --covers $badge_count to state that this disposition answers all of them"
        valid_uint "$covers" || die "--covers must be a positive integer"
        [ "$covers" -eq "$badge_count" ] ||
            die "--covers $covers does not match the $badge_count findings in target $target_id"
    fi

    settle_body=$(printf '%s' "$target" | jq -r '(.body // "") | @json')
    settle_edited=$(printf '%s' "$target" |
        jq -r '.updated_at // .submitted_at // ""')
    settle_fingerprint=$(content_fingerprint "$settle_body" "$settle_edited")

    # Re-settling the same target REPLACES its entry rather than appending: the
    # ordinary reason to settle twice is that Codex edited the finding and the
    # first disposition no longer applies to the text on the PR.
    payload=$(jq \
        --arg surface "$surface" \
        --argjson id "$target_id" \
        --arg disposition "$disposition" \
        --arg note "$note" \
        --arg fingerprint "$settle_fingerprint" \
        --arg settled_at "$settled_at" '
          .version = 2 |
          # Keyed by (surface, id, FINGERPRINT). Re-settling the same text
          # replaces its entry — a retry after a lost result must not leave
          # two contradictory current decisions, nor grow the list on every
          # attempt. Re-settling text Codex has since EDITED appends, because
          # the old entry has a different fingerprint: it goes inert (`check`
          # honours only the entry matching the body as it stands) while
          # surviving as the record of what was decided about the earlier
          # text, which is what SKILL.md promises is kept.
          .settled = (
            ((.settled // []) |
              map(select((.surface != $surface) or (.id != $id) or
                         (.content_fingerprint != $fingerprint)))) +
            [{
              surface:$surface,id:$id,disposition:$disposition,note:$note,
              content_fingerprint:$fingerprint,
              settled_at:$settled_at
            }]
          )
        ' "$state_file")
    write_state "$state_file" "$payload"
    release_state_lock
    printf '%s\n' "$payload"
    ;;

*) usage ;;
esac
