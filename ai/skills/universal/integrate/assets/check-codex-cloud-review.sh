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
#   2  indeterminate — malformed, changed head, usage error, or a
#      current-head verdict whose shape cannot be classified
#
# `settle` records the disposition of a badged finding that lives OUTSIDE an
# inline thread — a top-level conversation comment or a review body — because
# those two surfaces carry no reply linkage, so the in-thread adjudication path
# can never reach them and `check` would report `findings` for them forever.
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
                                     [--previous-head SHA] [--run-id ID]
                                     [--integration-cap N] [--integration-exempt-cap N]
  check-codex-cloud-review.sh attach --state FILE --trigger-id N
  check-codex-cloud-review.sh attach --state FILE --requested-at ISO8601
  check-codex-cloud-review.sh check --state FILE [--actor-id N] [--actor-login LOGIN] [--timeout-min N] [--now ISO8601]
                                   [--run-id ID]
  check-codex-cloud-review.sh settle --state FILE --actor-id N --surface comment|review --id N --disposition declined|filed --note TEXT [--covers N] [--now ISO8601]
  check-codex-cloud-review.sh show --state FILE
  check-codex-cloud-review.sh reap --root DIR [--budget-sec N]

When --finder is given on reserve, actor identity and verdict classification
are driven by the finder's profile in the trusted registry (C1-C3).

`reserve` classifies each new cycle as charged or exempt against the two
ceilings (harmon-init#1326) and keeps the running totals in state as
`charged_cycles` / `exempt_cycles`. A cycle is exempt only when the previously
reviewed head is an ancestor of this one AND the new commits changed no file
the PR has under review — a base merge that re-reads identical code.
Everything else, including anything that cannot be established, is charged.

The previously reviewed head is taken from PERSISTED STATE, never from a
caller: a caller free to name any SHA could otherwise skip past a fix commit
and manufacture an exemption. `--previous-head` is therefore optional and
purely confirmatory — supply it to have the reservation refuse rather than
proceed if your idea of the last reviewed head disagrees with the record.

--integration-cap and --integration-exempt-cap make `reserve` REFUSE a cycle
that would exceed the ceiling it belongs to. A ceiling checked only by the
readiness gate is checked after the review has already run, since the trigger
is posted immediately after the reservation; this is the last point at which
the spend can still be prevented. Omit them and the reservation proceeds, with
the gate as the only backstop.

--run-id scopes the totals to one run. The state file outlives the run that
wrote it, so a second run against the same PR would otherwise inherit the
first run's spend; naming a different run starts the totals again.

`check` exits 0 clean, 10 findings, 11 pending, 12 retry, 13 escalate,
14 PR no longer open, 2 indeterminate. Exit 14 means GitHub answered and
the PR is MERGED or CLOSED: terminal for the whole shepherd stage — stop,
never wait, re-run, or re-trigger. A PR fetch that FAILS is still the
transient bounded-wait path (pending/retry/escalate); only a non-open
answer is 14. `reserve` and `attach` refuse a non-open PR outright,
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
previous_head=
run_id=
integration_cap=
integration_exempt_cap=
requested_at_arg=

while [ "$#" -gt 0 ]; do
    case "$1" in
    --state | --root | --repo | --pr | --head | --attempt | --trigger-id | --actor-id | --actor-login | --timeout-min | --budget-sec | --now | --surface | --id | --disposition | --note | --covers | --finder | --requested-at | --previous-head | --run-id | --integration-cap | --integration-exempt-cap)
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
        --previous-head) previous_head=$2 ;;
        --run-id) run_id=$2 ;;
        --integration-cap) integration_cap=$2 ;;
        --integration-exempt-cap) integration_exempt_cap=$2 ;;
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

# A cycle counter is legitimately 0 before anything is spent, so it needs the
# zero-permitting form rather than valid_uint's positive one.
valid_uint_or_zero() {
    grep -Eq '^(0|[1-9][0-9]*)$' <<<"$1"
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
#   1 — the fetch failed or returned an unusable payload. Transient;
#       callers route this to their bounded wait exactly as before.
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
        current_epoch=$(date -u '+%s')
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
            call_timeout=$remaining
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

emit() {
    result=$1
    detail=$2
    surface=${3:-}
    accepted_id=${4:-}
    jq -cn \
        --arg status "$result" \
        --arg detail "$detail" \
        --arg head "${state_head:-}" \
        --argjson attempt "${state_attempt:-0}" \
        --arg surface "$surface" \
        --arg accepted_id "$accepted_id" \
        '{status:$status,detail:$detail,head:$head,attempt:$attempt}
         + (if $surface != "" and $accepted_id != "" then
              {accepted:{surface:$surface,id:$accepted_id,reviewed_commit:$head}}
            else {} end)'
}

bounded_wait() {
    detail=$1
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
        emit pending "$detail"
        exit 11
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
    1) bounded_wait "cannot fetch paginated $label" ;;
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
          def strip_about_block:
            gsub("<details.*?<summary>.*?about codex.*?</summary>.*?</details>";
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
          def verdict_class:
            if (first_line | startswith(clean_sentence) | not) then "findings"
            elif has_severity_marker then "findings"
            elif (rest_is_boilerplate | not) then "unrecognized"
            else "clean" end;
JQDEFS
)

# harmon-init#1326: classify a cycle as CHARGED or EXEMPT against the
# integration cap.
#
# The cap exists to bound how many times a reviewer is asked to look at work
# that changed. A cycle whose head differs from the last reviewed head ONLY by
# a base merge that touched nothing under review re-reads identical code by
# construction — it cannot find anything the previous cycle did not — so
# charging it measures the base branch's traffic rather than the change's
# difficulty.
#
# The test is deliberately narrow, and it is a set intersection rather than a
# judgement about merge commits:
#
#   exempt  <=>  previous_head is an ANCESTOR of head (the base was merged in,
#                nothing was rewritten), AND no file the PR has under review
#                appears among the files the new commits changed.
#
# "Under review" is computed from the CURRENT head, which is what makes the
# rule self-correcting rather than a loophole:
#   - a conflict resolution edits a file under review        -> intersects -> CHARGED
#   - the author slips a real fix into the merge push        -> that file is
#     under review at the new head                           -> intersects -> CHARGED
#   - a clean merge of base commits touching other files     -> disjoint    -> EXEMPT
#
# THE INVARIANT: exempt only on positive proof. Every other outcome charges.
#
# Challenge rounds 1-3 each found a different way to be wrong about this, and
# they all shared one shape — some input the classifier could not fully
# establish, treated as if it had been. So the rule is stated once here and
# every branch below obeys it: an uncertain compare, a truncated file list, a
# state file that does not belong to this run, an unreadable patch, an
# unexpected status — each charges. Under-exempting costs one cycle, which is
# exactly the status quo this change improves on and never worse than it.
# Over-exempting spends budget the reviewer never sanctioned, and no error in
# that direction is recoverable once the cycle is gone.
classify_cycle_charge() {
    classify_prev=$1
    classify_head=$2
    classify_repo=$3
    classify_pr=$4

    if [ "$classify_prev" = "$classify_head" ]; then
        charge_class=charged
        charge_reason="head is unchanged from the last reviewed head"
        return 0
    fi

    moved_payload=$(run_gh api "repos/$classify_repo/compare/$classify_prev...$classify_head") || {
        charge_class=charged
        charge_reason="cannot compare $classify_prev...$classify_head; charging"
        return 0
    }
    # The compare API caps `files` at 300 with no truncation flag of its own,
    # so a list at the cap may be incomplete and cannot prove that nothing
    # under review moved. Per the invariant, that charges.
    if [ "$(jq -r '(.files // []) | length' <<<"$moved_payload")" -ge 300 ]; then
        charge_class=charged
        charge_reason="the compare file list is at the API's 300-file cap and may be truncated; charging"
        return 0
    fi
    moved_status=$(jq -r '.status // "unknown"' <<<"$moved_payload")
    # "ahead" is the only status meaning the previously reviewed head is an
    # ancestor of this one. "diverged" means history was rewritten under the
    # cycle; "behind"/"identical" mean the head did not move forward. None is
    # a base merge, and each charges.
    if [ "$moved_status" != "ahead" ]; then
        charge_class=charged
        charge_reason="compare status is $moved_status, not a fast-forward base merge"
        return 0
    fi

    # Parse locally rather than with `gh --jq`: the value is needed as a ref
    # string either way, and one fewer flag on the read-only wrapper keeps its
    # surface exactly as narrow as it documents.
    classify_pr_payload=$(run_gh api "repos/$classify_repo/pulls/$classify_pr") ||
        classify_pr_payload=
    base_ref=$(jq -r '.base.ref // empty' <<<"$classify_pr_payload" 2>/dev/null) || base_ref=
    if [ -z "$base_ref" ] || [ "$base_ref" = "null" ]; then
        charge_class=charged
        charge_reason="cannot read the PR base ref; charging"
        return 0
    fi

    # Challenge round 1, P1 (confirmed): "under review" cannot be read from the
    # CURRENT patch alone. A base merge that makes a reviewed file identical to
    # base — or a conflict resolution that drops the branch's edit — removes
    # that file from the current patch while it still shows up among the moved
    # files. Intersecting against only the current set then finds nothing and
    # exempts a cycle in which reviewed code really did change, or was lost.
    #
    # So compare against the union of the patch as it stood at the PREVIOUS
    # reviewed head and as it stands now. A file that leaves the patch is still
    # under review for this decision, which is the direction that matters: it
    # is exactly the case where the merge silently rewrote the change.
    # A ref may legally contain a slash (`release/2.x`), which would otherwise
    # be read as extra path segments and 404 the compare.
    base_ref_encoded=$(jq -rn --arg s "$base_ref" '$s | @uri')
    prev_patch=$(run_gh api "repos/$classify_repo/compare/$base_ref_encoded...$classify_prev") || {
        charge_class=charged
        charge_reason="cannot read the reviewed patch at $classify_prev; charging"
        return 0
    }
    head_patch=$(run_gh api "repos/$classify_repo/compare/$base_ref_encoded...$classify_head") || {
        charge_class=charged
        charge_reason="cannot read the reviewed patch at $classify_head; charging"
        return 0
    }

    for truncation_check in "$prev_patch" "$head_patch"; do
        [ "$(jq -r '(.files // []) | length' <<<"$truncation_check")" -lt 300 ] || {
            charge_class=charged
            charge_reason="a reviewed-patch file list is at the API's 300-file cap and may be truncated; charging"
            return 0
        }
    done

    overlap=$(jq -r -n --argjson moved "$moved_payload" --argjson prev "$prev_patch" --argjson head "$head_patch" '
          # Challenge round 2, P1 (confirmed): a rename is reported under the
          # NEW name plus `previous_filename`. Matching only `filename` lets a
          # merge that renames a reviewed file miss on both sides at once —
          # the moved entry names the new path, the reviewed patch the old —
          # and a file under review changes while the intersection stays
          # empty. Both names count, on both sides.
          def names: (.files // []) | map(.filename, .previous_filename) | map(select(. != null));
          ($moved | names | unique) as $changed
          | (($prev | names) + ($head | names) | unique) as $under_review
          | ($changed - ($changed - $under_review)) | join(", ")
        ') || {
        charge_class=charged
        charge_reason="cannot intersect the moved files with the reviewed patch; charging"
        return 0
    }

    if [ -n "$overlap" ]; then
        charge_class=charged
        charge_reason="the merge changed file(s) under review: $overlap"
    else
        charge_class=exempt
        charge_reason="base merge touched no file under review"
    fi
    return 0
}

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
        # Review round 3, P1 (confirmed): `check` refuses to resume state owned
        # by another run and tells the caller to reserve fresh — but every
        # guard below is written for state belonging to THIS run, so the same
        # head would then be refused as a duplicate trigger and an unresolved
        # reservation. The caller had no move left. State from a different run
        # is this run's history of nothing at all, so treat it as absent: a
        # fresh attempt-1 reservation, with the totals restarting (they are
        # already reset by the run-scope branch further down).
        foreign_run_state=0
        if [ -n "$run_id" ]; then
            old_run_id=$(jq -r '.run_id // empty' "$state_file")
            if [ -n "$old_run_id" ] && [ "$old_run_id" != "$run_id" ]; then
                foreign_run_state=1
            fi
        fi
        # Duplicate round-3 pass, P1 (confirmed): foreign ATTACHED state is
        # replaceable, foreign RESERVED state is not. `reserved` is the
        # write-ahead record taken before the trigger is posted, so another
        # run sitting in it may already have a live `@codex review` out.
        # Overwriting that record loses the only reconciliation for it, and
        # the other run can then attach its trigger to this run's state —
        # duplicate or misattributed cycles. The run-scope bypass below must
        # therefore not extend to it: an unresolved reservation stays blocked
        # whoever owns it, which is what the reserve-before-write contract
        # requires.
        if [ "$old_phase" = "reserved" ]; then
            die "an unresolved reservation must be reconciled before replacing its head"
        fi
        if [ "$foreign_run_state" = "1" ]; then
            [ "$attempt" = "1" ] ||
                die "a reservation replacing another run's state must begin at attempt 1"
        fi
        if [ "$foreign_run_state" = "1" ]; then
            :
        elif [ "$old_head" = "$head" ]; then
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
    # Settlements are statements about a HEAD, not about an attempt, so attempt
    # 2 of the same head keeps them — discarding them would make every attempt-2
    # cycle re-block on findings a human already disposed of. A different head
    # invalidates them, and this payload starts them empty.
    carried_settled='[]'
    if [ -f "$state_file" ] && [ "$(jq -r '.head' "$state_file")" = "$head" ]; then
        carried_settled=$(jq -c '.settled // []' "$state_file")
    fi

    # harmon-init#1326: the two cycle counters this stage spends. They persist
    # across heads in this same state file, because the ceilings they answer to
    # bound the STAGE, not a single cycle.
    carried_charged=0
    carried_exempt=0
    if [ -f "$state_file" ]; then
        # Challenge round 2, P1 (confirmed): these totals bound a RUN, not a
        # PR, and the state file outlives the run that wrote it. A second run
        # against the same PR would otherwise inherit the first run's spend and
        # start already over budget — or, worse, have its own honest counters
        # read as a mismatch by the gate. When the caller names a run and it is
        # not the run the totals were accumulated for, the totals start again.
        state_run_id=$(jq -r '.run_id // empty' "$state_file")
        if [ -n "$run_id" ] && [ -n "$state_run_id" ] && [ "$run_id" != "$state_run_id" ]; then
            carried_charged=0
            carried_exempt=0
        else
            carried_charged=$(jq -r '.charged_cycles // 0' "$state_file")
            carried_exempt=$(jq -r '.exempt_cycles // 0' "$state_file")
            # These are read back and used as arithmetic against a ceiling, so
            # a hand-edited or truncated state file must not silently become a
            # budget. Refuse rather than coerce: a state whose counters cannot
            # be read is a state whose spend is unknown, and per the governing
            # invariant unknown spend is never treated as room to spend more.
            valid_uint_or_zero "$carried_charged" && valid_uint_or_zero "$carried_exempt" ||
                die "persisted cycle counters are not non-negative integers (charged=$carried_charged exempt=$carried_exempt)"
        fi
    fi
    charge_class=charged
    charge_reason="no persisted prior reviewed head; charging"
    if [ "$attempt" = "1" ]; then
        # Attempt 1 of a head is a NEW cycle, and the only thing that spends a
        # ceiling. Classify it, then charge whichever counter it belongs to.
        # Challenge round 1, P1 (confirmed): the previous reviewed head is
        # DERIVED from persisted state, never taken on a caller's word. The
        # state already records it, and a caller free to name any SHA can
        # manufacture an exemption: given reviewed head A, a fix commit B and
        # a base merge C, passing B classifies only B...C and exempts a cycle
        # in which A...C changed reviewed code. `--previous-head` may now only
        # RESTATE what state already says, so a caller that disagrees with the
        # record is refused rather than believed.
        classify_prev_head=
        if [ -f "$state_file" ]; then
            classify_prev_head=$(jq -r '.head // empty' "$state_file")
            [ "$classify_prev_head" != "$head" ] || classify_prev_head=
        fi
        if [ -n "$previous_head" ]; then
            valid_sha "$previous_head" ||
                die "--previous-head must be a full 40-hex commit"
            [ -n "$classify_prev_head" ] ||
                die "--previous-head was supplied but no persisted prior head exists to confirm it against"
            [ "$previous_head" = "$classify_prev_head" ] ||
                die "--previous-head $previous_head disagrees with the persisted last-reviewed head $classify_prev_head"
        fi
        # Per the invariant: an exemption rests on the persisted record of what
        # the last cycle reviewed, so that record must belong to THIS run. When
        # the caller names a run and state carries a different one — or none at
        # all — the prior head is not this run's history and cannot license an
        # exemption, whatever it says.
        if [ -n "$run_id" ] && [ "$(jq -r '.run_id // empty' "$state_file" 2>/dev/null)" != "$run_id" ]; then
            classify_prev_head=
            charge_reason="the persisted state belongs to a different run; charging"
        fi
        if [ -n "$classify_prev_head" ]; then
            classify_cycle_charge "$classify_prev_head" "$head" "$repo" "$pr"
        fi
        # Review round 1, P1 (confirmed): a cap is a CEILING, and a ceiling
        # enforced only by the readiness gate is enforced after the money is
        # spent — the prescribed sequence posts the trigger immediately after
        # this reservation, so the review has already run by the time the gate
        # objects. Refuse the reservation instead, at the one point where the
        # spend is still preventable.
        if [ "$charge_class" = "exempt" ]; then
            [ -z "$integration_exempt_cap" ] ||
                [ "$((carried_exempt + 1))" -le "$integration_exempt_cap" ] ||
                die "this cycle is exempt but the exempt ceiling ($integration_exempt_cap) is already spent; no cycle remains to reserve"
            carried_exempt=$((carried_exempt + 1))
        else
            [ -z "$integration_cap" ] ||
                [ "$((carried_charged + 1))" -le "$integration_cap" ] ||
                die "the integration cap ($integration_cap) is already spent; no charged cycle remains to reserve"
            carried_charged=$((carried_charged + 1))
        fi
    else
        # Attempt 2 re-triggers the SAME cycle after an incomplete first
        # attempt. Re-classifying would be wrong twice over: the head has not
        # moved, and charging again would make a flaky reviewer cost budget
        # that the change never asked for. Carry attempt 1's verdict.
        charge_class=$(jq -r '.charge // "charged"' "$state_file")
        charge_reason=$(jq -r '.charge_reason // ""' "$state_file")
    fi
    if [ "$attempt" = "2" ]; then
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
        --arg charge "$charge_class" \
        --arg charge_reason "$charge_reason" \
        --argjson charged_cycles "$carried_charged" \
        --argjson exempt_cycles "$carried_exempt" \
        --arg run_id "$run_id" \
        '{
          version:2,repo:$repo,pr:$pr,head:$head,attempt:$attempt,
          phase:"reserved",reserved_at:$reserved_at,
          trigger_comment_id:null,requested_at:null,
          previous_trigger_comment_id:$previous_trigger_comment_id,
          requires_full_window:false,
          timeout_min:$timeout_min,
          settled:$settled,
          finder:$finder,
          charge:$charge,
          charge_reason:$charge_reason,
          charged_cycles:$charged_cycles,
          exempt_cycles:$exempt_cycles,
          run_id:(if $run_id == "" then null else $run_id end)
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
    # Review round 2, P1 (confirmed): a new run that starts on the SAME head as
    # a prior one finds that run's `attached` state and resumes it, skipping
    # `reserve` — and with it the run-scope reset that lives there. The prior
    # run's spend is then silently attributed to this one, and its cycle
    # ordinal disagrees with the inherited totals. `reserve` cannot catch this
    # because it is never called; the resume path has to, so the guard lives
    # here where the resume actually happens.
    if [ -n "$run_id" ]; then
        state_run_id=$(jq -r '.run_id // empty' "$state_file")
        if [ -n "$state_run_id" ] && [ "$state_run_id" != "$run_id" ]; then
            emit indeterminate "this cycle state belongs to run $state_run_id, not $run_id — reserve a fresh cycle rather than resuming another run's spend"
            exit 2
        fi
    fi
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
        bounded_wait "cannot fetch the current open PR head"
    fi
    [ "$first_head" = "$state_head" ] || {
        emit head-changed "recorded evidence belongs to an older PR head"
        exit 2
    }

    workdir=$(mktemp -d -t codex-cloud-review-XXXXXX)
    trap 'rm -rf "$workdir"; rm -f "$lock_dir/pid"; rmdir "$lock_dir" 2>/dev/null || true' EXIT

    actor=$(run_gh api "users/$actor_login") || {
        bounded_wait "cannot authenticate the configured finder actor"
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
            bounded_wait "cannot re-fetch the exact trigger comment"
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
        bounded_wait "cannot re-fetch the PR head before verdict"
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
            bounded_wait "cannot fetch the pull request author identity"
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

        inline_partition=$(jq -c \
            --argjson id "$actor_id" \
            --argjson author "$pr_author_id" \
            --arg head "$state_head" '
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
              )] as $bot |
              [$bot[] |
                . as $comment |
                ts($comment.created_at) as $posted |
                ($comment | edited_at) as $edited |
                [$all[] | select(
                  (($comment.id? | type) == "number") and
                  (.in_reply_to_id? == $comment.id) and
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
            emit findings "current-head inline review findings are unanswered by a trusted in-thread reply" \
                review "$inline_findings_review_id"
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
    malformed_top_level=$(jq -r \
        --argjson id "$actor_id" \
        --arg head "$state_head" \
        "$codex_verdict_defs"'
          [.[] | select(.user.id? == $id) |
            ((.body // "") |
              try match(
                "Reviewed commit[^0-9a-fA-F]+([0-9a-fA-F]{7,40})";
                "i"
              ).captures[0].string catch "") as $prefix |
            select($prefix != "") |
            select(($head | ascii_downcase) | startswith($prefix | ascii_downcase)) |
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
            bounded_wait "cannot resolve a reviewed commit prefix through GitHub"
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
    # deliberately narrow: it refuses anything it cannot prove is a badged
    # finding, from the pinned actor, about the state's own head.
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
        settle_prefix=$(printf '%s' "$target" | jq -r '
              (.body // "") |
              try match(
                "Reviewed commit[^0-9a-fA-F]+([0-9a-fA-F]{7,40})";
                "i"
              ).captures[0].string catch ""
            ')
        grep -Eq '^[0-9a-fA-F]{7,40}$' <<<"$settle_prefix" ||
            die "comment $target_id does not identify a reviewed commit"
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
    # The badge is the only machine-emitted signal that this is a finding at
    # all. Requiring it keeps settlement off every other shape the surfaces
    # carry — a clean verdict, a carrier body, an unrecognized one — none of
    # which a disposition would mean anything about.
    printf '%s' "$target" |
        jq -e "$codex_verdict_defs"' has_severity_marker' >/dev/null ||
        die "target $target_id carries no severity badge, so it is not a finding to settle"

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
    # correct for it; `has_severity_marker` above has already established that
    # at least one finding is present either way.
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
