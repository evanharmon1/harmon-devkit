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
  check-codex-cloud-review.sh reserve --state FILE --repo OWNER/REPO --pr N --head SHA --attempt 1|2
  check-codex-cloud-review.sh attach --state FILE --trigger-id N
  check-codex-cloud-review.sh check --state FILE --actor-id N [--actor-login LOGIN] [--timeout-min N] [--now ISO8601]
  check-codex-cloud-review.sh settle --state FILE --actor-id N --surface comment|review --id N --disposition declined|filed --note TEXT [--covers N] [--now ISO8601]
  check-codex-cloud-review.sh show --state FILE
  check-codex-cloud-review.sh reap --root DIR [--budget-sec N]

`check` exits 0 clean, 10 findings, 11 pending, 12 retry, 13 escalate,
14 PR no longer open, 2 indeterminate. Exit 14 means GitHub answered and
the PR is MERGED or CLOSED: terminal for the whole shepherd stage — stop,
never wait, re-run, or re-trigger. A PR fetch that FAILS is still the
transient bounded-wait path (pending/retry/escalate); only a non-open
answer is 14. `reserve` and `attach` refuse a non-open PR outright,
exit 2 with a reason naming the reported state.
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

while [ "$#" -gt 0 ]; do
    case "$1" in
    --state | --root | --repo | --pr | --head | --attempt | --trigger-id | --actor-id | --actor-login | --timeout-min | --budget-sec | --now | --surface | --id | --disposition | --note | --covers)
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
    printf '%s' "$1" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
}

valid_uint() {
    printf '%s' "$1" | grep -Eq '^[1-9][0-9]*$'
}

valid_sha() {
    printf '%s' "$1" | grep -Eq '^[0-9a-fA-F]{40}$'
}

valid_time() {
    printf '%s' "$1" |
        grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
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
# re-derives `elapsed` from `reserved_at` and `timeout_min` fresh, on its own
# invocation, against the real clock. There is no cached "attempt 1 timed
# out" decision anywhere in state for a later adoption to contradict — only
# `reserved_at` (fixed at reservation) and `timeout_min` (this cycle's
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
    if [ -n "${state_reserved:-}" ] && valid_time "$state_reserved"; then
        reserved_epoch=$(jq -nr \
            --arg value "$state_reserved" '$value | fromdateiso8601') ||
            return 1
        current_epoch=$(date -u '+%s')
        remaining=$((reserved_epoch + timeout_min * 60 - current_epoch))
        if [ "$remaining" -le 0 ]; then
            call_timeout=1
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
          (.settled_at | type == "string"))))) and
      (.repo | type == "string") and
      (.pr | type == "number") and
      (.head | type == "string") and
      (.attempt == 1 or .attempt == 2) and
      (.phase == "reserved" or .phase == "attached") and
      (.cycle_requested_at == null or
        (.cycle_requested_at | type == "string")) and
      (.previous_trigger_comment_id == null or
        (.previous_trigger_comment_id | type == "number")) and
      (.timeout_min == null or (.timeout_min | type == "number"))
    ' "$state_file" >/dev/null || die "malformed state file: $state_file"
}

acquire_state_lock() {
    parent=$(dirname "$state_file")
    mkdir -p "$parent"
    lock_dir="${state_file}.lock"
    mkdir "$lock_dir" 2>/dev/null ||
        die "state is locked by another shepherd; inspect before retrying"
    trap 'rmdir "$lock_dir" 2>/dev/null || true' EXIT
}

release_state_lock() {
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
    jq -cn \
        --arg status "$result" \
        --arg detail "$detail" \
        --arg head "${state_head:-}" \
        --argjson attempt "${state_attempt:-0}" \
        '{status:$status,detail:$detail,head:$head,attempt:$attempt}'
}

bounded_wait() {
    detail=$1
    if [ -z "$now" ]; then
        now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    fi
    valid_time "$now" || die "--now must be an ISO-8601 UTC second"
    reserved_epoch=$(jq -nr \
        --arg value "$state_reserved" '$value | fromdateiso8601') ||
        die "cannot parse reservation time"
    now_epoch=$(jq -nr --arg value "$now" '$value | fromdateiso8601') ||
        die "cannot parse current time"
    [ "$now_epoch" -ge "$reserved_epoch" ] ||
        die "--now predates the local reservation"
    elapsed=$((now_epoch - reserved_epoch))
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
        if [ "$old_head" = "$head" ]; then
            [ "$old_attempt" = "1" ] && [ "$attempt" = "2" ] &&
                [ "$old_phase" = "attached" ] ||
                die "refusing an uncontrolled duplicate trigger for this head"
        else
            [ "$attempt" = "1" ] ||
                die "a new head must begin at attempt 1"
        fi
    elif [ "$attempt" != "1" ]; then
        die "attempt 2 requires an attached attempt-1 state"
    fi

    reserved_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    cycle_requested_at=
    previous_trigger_id=null
    # Settlements are statements about a HEAD, not about an attempt, so attempt
    # 2 of the same head keeps them — discarding them would make every attempt-2
    # cycle re-block on findings a human already disposed of. A different head
    # invalidates them, and this payload starts them empty.
    carried_settled='[]'
    if [ -f "$state_file" ] && [ "$(jq -r '.head' "$state_file")" = "$head" ]; then
        carried_settled=$(jq -c '.settled // []' "$state_file")
    fi
    if [ "$attempt" = "2" ]; then
        cycle_requested_at=$(jq -r '.cycle_requested_at' "$state_file")
        previous_reserved_at=$(jq -r '.reserved_at' "$state_file")
        previous_trigger_id=$(jq -r '.trigger_comment_id' "$state_file")
        valid_time "$cycle_requested_at" ||
            die "attempt 1 state has an invalid cycle request time"
        valid_time "$previous_reserved_at" ||
            die "attempt 1 state has an invalid reservation time"
        valid_uint "$previous_trigger_id" ||
            die "attempt 1 state has an invalid trigger ID"
        previous_reserved_epoch=$(jq -nr \
            --arg value "$previous_reserved_at" '$value | fromdateiso8601') ||
            die "cannot parse attempt 1 reservation time"
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
            "$((previous_reserved_epoch + timeout_min * 60))" ] ||
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
    payload=$(jq -cn \
        --arg repo "$repo" \
        --argjson pr "$pr" \
        --arg head "$head" \
        --argjson attempt "$attempt" \
        --arg reserved_at "$reserved_at" \
        --arg cycle_requested_at "$cycle_requested_at" \
        --argjson previous_trigger_id "$previous_trigger_id" \
        --argjson timeout_min "$payload_timeout_min" \
        --argjson settled "$carried_settled" \
        '{
          version:2,repo:$repo,pr:$pr,head:$head,attempt:$attempt,
          phase:"reserved",reserved_at:$reserved_at,
          trigger_comment_id:null,requested_at:null,
          cycle_requested_at:
            (if $cycle_requested_at == "" then null else $cycle_requested_at end),
          previous_trigger_comment_id:$previous_trigger_id,
          timeout_min:$timeout_min,
          settled:$settled
        }')
    write_state "$state_file" "$payload"
    release_state_lock
    printf '%s\n' "$payload"
    ;;

attach)
    [ -n "$trigger_id" ] || usage
    valid_uint "$trigger_id" || die "invalid trigger comment ID"
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
    if [ "$phase" = "attached" ]; then
        existing_id=$(jq -r '.trigger_comment_id' "$state_file")
        [ "$existing_id" = "$trigger_id" ] ||
            die "state is already attached to a different trigger"
        cat "$state_file"
        exit 0
    fi

    comment=$(run_gh api "repos/$state_repo/issues/comments/$trigger_id") ||
        die "cannot fetch exact trigger comment $trigger_id"
    printf '%s' "$comment" | jq -e \
        --argjson id "$trigger_id" \
        --arg suffix "/issues/$state_pr" '
          (.id == $id) and
          ((.body // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "") == "@codex review") and
          ((.issue_url // "") | endswith($suffix)) and
          (.created_at | type == "string")
        ' >/dev/null || die "comment $trigger_id is not this PR's exact review trigger"
    requested_at=$(printf '%s' "$comment" | jq -er '.created_at')
    valid_time "$requested_at" || die "trigger has a malformed creation time"

    payload=$(jq \
        --argjson id "$trigger_id" \
        --arg requested_at "$requested_at" '
          .version = 2 |
          .phase = "attached" |
          .trigger_comment_id = $id |
          .requested_at = $requested_at |
          .cycle_requested_at = (.cycle_requested_at // $requested_at)
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
    [ -n "$actor_id" ] || usage
    valid_uint "$actor_id" || die "invalid actor ID"
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
    state_trigger=$(jq -r '.trigger_comment_id' "$state_file")
    state_reserved=$(jq -r '.reserved_at' "$state_file")
    state_requested=$(jq -r '.requested_at' "$state_file")
    cycle_requested=$(jq -r '.cycle_requested_at' "$state_file")
    previous_trigger=$(jq -r '.previous_trigger_comment_id // empty' "$state_file")
    valid_uint "$state_trigger" || die "state has an invalid trigger ID"
    valid_time "$state_reserved" || die "state has an invalid reservation time"
    valid_time "$state_requested" || die "state has an invalid request time"
    valid_time "$cycle_requested" || die "state has an invalid cycle request time"
    [ -z "$previous_trigger" ] || valid_uint "$previous_trigger" ||
        die "state has an invalid previous trigger ID"
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
    trap 'rm -rf "$workdir"; rmdir "$lock_dir" 2>/dev/null || true' EXIT

    actor=$(run_gh api "users/$actor_login") || {
        bounded_wait "cannot authenticate the configured Codex actor"
    }
    printf '%s' "$actor" | jq -e \
        --argjson id "$actor_id" \
        --arg login "$actor_login" '
          (.id == $id) and (.login == $login) and (.type == "Bot")
        ' >/dev/null || {
        emit indeterminate "configured Codex login does not resolve to the pinned Bot actor ID"
        exit 2
    }

    trigger=$(run_gh api "repos/$state_repo/issues/comments/$state_trigger") || {
        bounded_wait "cannot re-fetch the exact trigger comment"
    }
    printf '%s' "$trigger" | jq -e \
        --argjson id "$state_trigger" \
        --arg created "$state_requested" \
        --arg suffix "/issues/$state_pr" '
          (.id == $id) and (.created_at == $created) and
          ((.body // "") | gsub("^[[:space:]]+|[[:space:]]+$"; "") == "@codex review") and
          ((.issue_url // "") | endswith($suffix))
        ' >/dev/null || {
        emit indeterminate "exact trigger metadata changed or is malformed"
        exit 2
    }

    fetch_evidence \
        "repos/$state_repo/issues/comments/$state_trigger/reactions?per_page=100" \
        "$workdir/current-reactions.json" \
        "exact-trigger reactions"
    printf '%s\n' '[]' >"$workdir/previous-reactions.json"
    if [ -n "$previous_trigger" ]; then
        fetch_evidence \
            "repos/$state_repo/issues/comments/$previous_trigger/reactions?per_page=100" \
            "$workdir/previous-reactions.json" \
            "previous-trigger reactions"
    fi
    jq -s 'add' \
        "$workdir/current-reactions.json" \
        "$workdir/previous-reactions.json" >"$workdir/reactions.json"
    fetch_evidence \
        "repos/$state_repo/issues/$state_pr/comments?per_page=100" \
        "$workdir/comments.json" "PR conversation comments"
    fetch_evidence \
        "repos/$state_repo/pulls/$state_pr/reviews?per_page=100" \
        "$workdir/reviews.json" "PR reviews"
    fetch_evidence \
        "repos/$state_repo/pulls/$state_pr/comments?per_page=100" \
        "$workdir/inline.json" "inline comments"

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
            emit indeterminate "Codex-looking activity has an unexpected immutable actor identity"
            exit 2
        }
    done

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
            emit findings "authenticated current-head inline review findings are unanswered by a trusted in-thread reply"
            exit 10
        fi
        adjudicated_findings=1
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
    # `body_text != ""` drops EMPTY-BODY reviews from classification, and only
    # from classification. GitHub auto-creates a body-less COMMENTED review
    # shell to carry inline comments (reply shells, and Codex's own shell
    # posted before its inline findings land), and an empty body is no
    # evidence in either direction: it has no verdict to be clean and no
    # free-text surface where an unanswered concern could hide — anything it
    # carries is inline comments, which the inline gate above already
    # classifies on their own. Classifying the shell instead would read it as
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
        --argjson attributed "$attributed_reviews" '
          [.[] | select(
            .user.id? == $id and
            (.commit_id? == $head) and
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

    review_result=$(jq -r \
        --argjson id "$actor_id" \
        --arg head "$state_head" \
        --argjson settled "$settled_reviews" \
        --argjson disposed "$disposed_reviews" \
        "$codex_verdict_defs"'
          [.[] | select(
            .user.id? == $id and
            (.commit_id? == $head) and
            (body_text != "")
          ) |
          . as $review | verdict_class as $class |
          if $class == "findings" then
            # A recorded disposition settles the review BODY on its own,
            # badge and prose included — that is what was disposed of. It
            # says nothing about the inline comments hanging off that same
            # review, which keep their own reply-based path above.
            (if (($review.id? | type) == "number") and
                ($disposed | index($review.id))
             then "settled"
             elif (($review.id? | type) == "number") and
                ($settled | index($review.id)) and
                ((has_severity_marker) | not) and
                is_carrier_only
             then "settled" else "findings" end)
          else $class end
          ] |
          if index("findings") then "findings"
          elif index("unrecognized") then "unrecognized"
          elif index("clean") then "clean"
          else "none" end
        ' "$workdir/reviews.json")
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
    if [ "$review_result" = "findings" ]; then
        emit findings "authenticated current-head review requires adjudication"
        exit 10
    fi
    if [ "$review_result" = "unrecognized" ]; then
        emit indeterminate "current-head review opens with the clean verdict but carries prose beyond Codex's own metadata"
        exit 2
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
          [
            $prefix,
            verdict_class,
            (.id | tostring),
            (.created_at // "")
          ] | @tsv
        ' "$workdir/comments.json" >"$comment_candidates"

    comment_result=none
    clean_comment_time=""
    while IFS='	' read -r prefix classification comment_id comment_created; do
        [ -n "$prefix" ] || continue
        printf '%s' "$prefix" | grep -Eq '^[0-9a-fA-F]{7,40}$' || {
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
        elif [ "$classification" = "unrecognized" ]; then
            # findings outranks unrecognized outranks clean, so a single
            # unclassifiable verdict is never masked by a clean sibling.
            [ "$comment_result" = "findings" ] || comment_result=unrecognized
        elif [ "$comment_result" = "none" ]; then
            comment_result=clean
        fi
        if [ "$classification" = "clean" ] &&
            [ "$comment_created" \> "$clean_comment_time" ]; then
            clean_comment_time=$comment_created
        fi
        : "$comment_id"
    done <"$comment_candidates"

    if [ "$comment_result" = "findings" ]; then
        emit findings "authenticated current-head conversation finding requires adjudication"
        exit 10
    fi
    if [ "$comment_result" = "unrecognized" ]; then
        emit indeterminate "current-head result opens with the clean verdict but carries prose beyond Codex's own metadata"
        exit 2
    fi
    if [ "$review_result" = "clean" ] || [ "$comment_result" = "clean" ]; then
        # The newest clean evidence must be NEWER than the dangling-shell
        # barrier above: an older clean result cannot vouch for a head whose
        # next review is already in flight.
        #
        # Strictly newer, deliberately. GitHub timestamps these resources to
        # whole seconds, so a shell and the verdict can tie, and a tie is
        # undecidable — the verdict may belong to the shell's review or
        # predate a review that is now in flight. `>` reads a tie as pending:
        # fail closed, and not permanent, because the attempt machinery
        # re-triggers and Codex then posts strictly newer evidence for this
        # head that resolves the cycle either way. `>=` would trade that
        # bounded delay for a promote-during-the-gap race inside the
        # coincidence second.
        #
        # Accepted residual, stated so nobody rediscovers it: attempt 2 can
        # post a clean verdict while attempt 1's review — same head, same
        # diff, declared dead a full window ago — is somehow still running,
        # and that newer verdict clears attempt 1's shell. Timestamps cannot
        # correlate a verdict with a shell, so no comparison closes this
        # without reopening the abandoned-shell deadlock on the other side.
        # The exposure requires Codex to contradict itself on identical
        # input, is caught by the caller's mandatory pre-promotion re-check
        # when the late findings land before promotion, and beyond that a
        # reviewer that may post arbitrarily late defeats any polling design
        # — which is why the gate promotes to ready-for-review, not merge.
        clean_review_time=""
        if [ "$review_result" = "clean" ]; then
            clean_review_time=$(jq -r \
                --argjson id "$actor_id" \
                --arg head "$state_head" \
                "$codex_verdict_defs"'
                  [.[] | select(
                    .user.id? == $id and
                    (.commit_id? == $head) and
                    (body_text != "")
                  ) | select(verdict_class == "clean") |
                  .submitted_at? | select(type == "string")] | max // ""
                ' "$workdir/reviews.json")
        fi
        newest_clean=$clean_review_time
        if [ "$clean_comment_time" \> "$newest_clean" ]; then
            newest_clean=$clean_comment_time
        fi
        if [ -n "$shell_barrier" ] && ! [ "$newest_clean" \> "$shell_barrier" ]; then
            emit pending "a newer empty review shell is still in flight for this head"
            exit 11
        fi
        emit clean "authenticated bot posted a current-head clean result"
        exit 0
    fi

    like_time=$(jq -r \
        --argjson id "$actor_id" \
        --arg requested "$cycle_requested" '
          [.[] | select(
            .user.id? == $id and
            .content? == "+1" and
            (.created_at? >= $requested)
          ) | .created_at? | select(type == "string")] | max // ""
        ' "$workdir/reactions.json")
    exact_like=$(jq \
        --argjson id "$actor_id" \
        --arg requested "$cycle_requested" '
          [.[] | select(
            .user.id? == $id and
            .content? == "+1" and
            (.created_at? >= $requested)
          )] | length
        ' "$workdir/reactions.json")
    if [ "$exact_like" -gt 0 ]; then
        if [ -n "$shell_barrier" ] && ! [ "$like_time" \> "$shell_barrier" ]; then
            emit pending "a newer empty review shell is still in flight for this head"
            exit 11
        fi
        emit clean "authenticated bot reacted +1 on the exact current-head trigger"
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
        # Attempt 2's newer evidence resolves the cycle when it is a clean
        # verdict or reaction (the time-ordered exits above accept it). When
        # attempt 2 instead returns findings and an ABANDONED attempt-1
        # shell still dangles, this exit stays pending after those findings
        # are adjudicated, and the cycle ends in the attempt machinery's
        # escalation. Deliberate, not a gap: an actor shell nobody can
        # explain plus adjudicated findings is incomplete evidence, and the
        # checker's discipline for incomplete evidence is a human hand-off,
        # never a green it cannot support.
        if [ -n "$shell_barrier" ]; then
            emit pending "an empty review shell is still unresolved for this head"
            exit 11
        fi
        emit clean "current-head findings are all adjudicated by trusted in-thread replies"
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
        emit clean "current-head non-thread findings are all settled: ${applied_dispositions:-recorded dispositions}"
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
    valid_repo "$state_repo" || die "state has an invalid repository"
    valid_uint "$state_pr" || die "state has an invalid PR number"
    valid_sha "$state_head" || die "state has an invalid head"
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
        printf '%s' "$settle_prefix" | grep -Eq '^[0-9a-fA-F]{7,40}$' ||
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
              content_fingerprint:$fingerprint,settled_at:$settled_at
            }]
          )
        ' "$state_file")
    write_state "$state_file" "$payload"
    release_state_lock
    printf '%s\n' "$payload"
    ;;

*) usage ;;
esac
